//! Client-side transport for driving a running Ghoztty instance over IPC:
//! connect to the instance's endpoint, send one length-prefixed JSON
//! request, read the length-prefixed JSON response. The endpoint is a Unix
//! domain socket on posix systems and a named pipe on Windows; everything
//! above the connect/read/write layer is identical on both, so ALL CLI
//! commands and apprt `performIpc` implementations must go through this one
//! helper (docs/design/windows-parity-spec.md, "Architecture decisions").
//!
//! Framing, both directions: 4-byte big-endian length + JSON body.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const build_config = @import("../build_config.zig");

pub const timeout = @import("ipc_timeout.zig");

/// The build identity a LAUNCH carries when it hands its window to the
/// instance already running, and the notice shown when the two differ (T1022).
pub const handoff = @import("ipc_handoff.zig");

const is_windows = builtin.os.tag == .windows;

pub const Error = error{
    /// No running instance was found (socket/pipe does not exist or refuses
    /// connections). Callers print their own context-appropriate message.
    NoRunningInstance,

    /// The IPC failed after a connection was established. A specific
    /// diagnostic has already been written to the stderr writer.
    IPCFailed,
} || Allocator.Error;

/// Not in std's kernel32 bindings: blocks until an instance of the named
/// pipe is available to connect to, or the timeout (ms) elapses.
extern "kernel32" fn WaitNamedPipeW(
    lpNamedPipeName: [*:0]const u16,
    nTimeOut: u32,
) callconv(.winapi) windows.BOOL;

/// One request/response connection to the running instance.
pub const Conn = struct {
    handle: Handle,

    /// Whether this module OPENED the handle, and may therefore bound the I/O
    /// on it (T755). On Windows that means it was created with
    /// `FILE_FLAG_OVERLAPPED` and every read/write must carry an OVERLAPPED;
    /// on posix it means the socket is ours to `setsockopt`.
    ///
    /// It is a separate fact from `timeout_ms` and must stay one. A client
    /// that opted out of the bound (`GHOZTTY_IPC_TIMEOUT_MS=0`) still holds an
    /// overlapped handle, and handing such a handle to a synchronous
    /// `ReadFile` is documented as unpredictable — which is exactly what one
    /// combined field produced: the opt-out wedged on a read that neither
    /// completed nor timed out. The default `false` is what keeps a Conn built
    /// around somebody else's handle — the win32 IPC SERVER wraps each
    /// accepted pipe instance this way — on the blocking path it always had.
    owned: bool = false,

    /// Bound on a single read or write, in milliseconds; 0 means wait forever.
    /// Only consulted when `owned`.
    timeout_ms: u32 = 0,

    pub const Handle = if (is_windows) windows.HANDLE else std.posix.fd_t;

    pub fn close(self: Conn) void {
        if (comptime is_windows) {
            windows.CloseHandle(self.handle);
        } else {
            std.posix.close(self.handle);
        }
    }

    /// Write every byte, bounded by this connection's timeout. A timeout here
    /// means the peer is not draining the pipe at all.
    pub fn writeAll(self: Conn, bytes: []const u8) !void {
        var total: usize = 0;
        while (total < bytes.len) {
            const n = try self.writeSlice(bytes[total..], self.boundOrForever());
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    /// Read exactly `buffer.len` bytes, bounded by this connection's timeout.
    pub fn readFull(self: Conn, buffer: []u8) !void {
        var done: usize = 0;
        return self.readFullWithin(buffer, &done, self.boundOrForever());
    }

    /// `readFull` with an explicit bound and a caller-owned progress cursor.
    ///
    /// The cursor is what makes a two-stage wait possible: a call that gives up
    /// leaves `done.*` at the bytes it did read, so the caller can print a
    /// "still waiting" notice and resume the SAME read with the rest of the
    /// budget instead of losing a partial frame. `wait_ms` of null waits
    /// forever; expiry is `error.Timeout`.
    pub fn readFullWithin(
        self: Conn,
        buffer: []u8,
        done: *usize,
        wait_ms: ?u32,
    ) !void {
        while (done.* < buffer.len) {
            const n = self.readSlice(buffer[done.*..], wait_ms) catch |err| switch (err) {
                error.WouldBlock => return error.Timeout,
                else => return err,
            };
            if (n == 0) return error.EndOfStream;
            done.* += n;
        }
    }

    /// This connection's bound as the `?u32` the slice helpers take: null when
    /// there is none (`timeout_ms == 0`, or a handle we do not own).
    fn boundOrForever(self: Conn) ?u32 {
        if (!self.owned or self.timeout_ms == 0) return null;
        return self.timeout_ms;
    }

    fn readSlice(self: Conn, buffer: []u8, wait_ms: ?u32) !usize {
        if (comptime is_windows) {
            // A Conn wrapping a handle we did not open (the win32 IPC server
            // wraps each accepted pipe instance) is synchronous and cannot do
            // overlapped I/O; it keeps the blocking path it always had.
            if (!self.owned) return windows.ReadFile(self.handle, buffer, null);
            return self.overlappedIo(.read, buffer, wait_ms);
        }

        if (self.owned) self.setPosixTimeout(std.posix.SO.RCVTIMEO, wait_ms);
        return std.posix.read(self.handle, buffer);
    }

    fn writeSlice(self: Conn, bytes: []const u8, wait_ms: ?u32) !usize {
        if (comptime is_windows) {
            if (!self.owned) return windows.WriteFile(self.handle, bytes, null);
            return self.overlappedIo(.write, @constCast(bytes), wait_ms) catch |err| switch (err) {
                error.WouldBlock => error.Timeout,
                else => err,
            };
        }

        if (self.owned) self.setPosixTimeout(std.posix.SO.SNDTIMEO, wait_ms);
        return std.posix.write(self.handle, bytes) catch |err| switch (err) {
            error.WouldBlock => error.Timeout,
            else => err,
        };
    }

    /// Windows: one bounded read or write over an overlapped handle.
    ///
    /// A synchronous `ReadFile` on a named pipe cannot be interrupted, which
    /// is the whole of T755 — a client whose peer never answered blocked for
    /// 34 minutes. So the client's handle is opened `FILE_FLAG_OVERLAPPED`
    /// and every operation waits on its own event with a bound. On timeout the
    /// I/O is cancelled and then WAITED FOR: the OVERLAPPED and the buffer are
    /// on this stack frame, and the kernel may still be writing to them until
    /// the cancelled operation actually completes.
    fn overlappedIo(
        self: Conn,
        comptime op: enum { read, write },
        buffer: []u8,
        wait_ms: ?u32,
    ) !usize {
        if (comptime !is_windows) unreachable;

        const event = windows.kernel32.CreateEventExW(
            null,
            null,
            windows.CREATE_EVENT_MANUAL_RESET,
            windows.EVENT_ALL_ACCESS,
        ) orelse return error.Unexpected;
        defer windows.CloseHandle(event);

        var ov: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        ov.hEvent = event;

        const len: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
        const started = switch (op) {
            .read => windows.kernel32.ReadFile(self.handle, buffer.ptr, len, null, &ov),
            .write => windows.kernel32.WriteFile(self.handle, buffer.ptr, len, null, &ov),
        };

        if (started == 0) switch (windows.GetLastError()) {
            .IO_PENDING => {
                const ms: windows.DWORD = if (wait_ms) |w| w else windows.INFINITE;
                if (windows.kernel32.WaitForSingleObject(event, ms) != windows.WAIT_OBJECT_0) {
                    // Cancel, then block until the operation is really done —
                    // see the note above about the stack frame.
                    _ = windows.kernel32.CancelIoEx(self.handle, &ov);
                    _ = windows.kernel32.WaitForSingleObject(event, windows.INFINITE);
                    return error.WouldBlock;
                }
            },
            // The peer hung up. Both spellings mean "no more bytes", which the
            // callers already read as end-of-stream.
            .BROKEN_PIPE, .HANDLE_EOF, .PIPE_NOT_CONNECTED => return 0,
            else => return error.Unexpected,
        };

        var transferred: windows.DWORD = 0;
        if (windows.kernel32.GetOverlappedResult(self.handle, &ov, &transferred, 0) == 0) {
            switch (windows.GetLastError()) {
                .BROKEN_PIPE, .HANDLE_EOF, .PIPE_NOT_CONNECTED => return 0,
                .OPERATION_ABORTED => return error.WouldBlock,
                else => return error.Unexpected,
            }
        }
        return transferred;
    }

    /// posix: bound the next blocking read/write with `SO_RCVTIMEO` /
    /// `SO_SNDTIMEO`, which expire as `EAGAIN` (`error.WouldBlock`). A zero
    /// timeval is the kernel's own spelling of "no timeout", so the
    /// wait-forever case needs no special path. Best-effort: a socket that
    /// refuses the option keeps the blocking behavior it had before T755
    /// rather than failing the command outright.
    fn setPosixTimeout(self: Conn, optname: u32, wait_ms: ?u32) void {
        if (comptime is_windows) return;
        const ms = wait_ms orelse 0;
        const tv: std.posix.timeval = .{
            .sec = @intCast(ms / 1000),
            .usec = @intCast((ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            self.handle,
            std.posix.SOL.SOCKET,
            optname,
            std.mem.asBytes(&tv),
        ) catch {};
    }
};

/// Environment variable naming the IPC endpoint of the app instance that owns
/// the calling process's pane, baked into every pane's environment by the app
/// that created it. See `apprt.ipc.socket_env` (which aliases this constant so
/// there is exactly one spelling) and docs/claude/cli.md "Instance addressability".
///
/// T118: the same name is used on Windows even though the value there is a
/// PIPE NAME (`\\.\pipe\ghoztty[-debug]-<user>`), not a socket path. One
/// spelling was chosen deliberately over a Windows-only sibling: the var is
/// baked into long-lived panes that outlive the app, both platforms resolve it
/// through the same rule, and a second name would be one more thing to keep in
/// sync for a value neither side ever parses.
pub const endpoint_env = "GHOZTTY_IPC_SOCKET";

/// Test hook naming the endpoint SUFFIX to derive (see `endpointPath`). When
/// it is set the caller is aiming at a specific instance on purpose, so it
/// beats the baked value — see `clientEndpointPathFrom`.
pub const suffix_env = "GHOZTTY_PIPE_SUFFIX";

/// The endpoint a CLIENT should dial. Precedence: an explicit
/// `$GHOZTTY_PIPE_SUFFIX` (a caller aiming on purpose) → the pane's baked
/// endpoint → this build's own derivation (`endpointPath`).
///
/// The SERVER must never use this. An app launched from ANOTHER instance's
/// pane inherits that instance's value, so binding it would make the new app
/// try to own the other app's endpoint; the server binds `endpointPath`, and
/// the win32 App drops the inherited value from its own environment at startup
/// so nothing it spawns or dials picks it up by accident.
pub fn clientEndpointPath(alloc: Allocator) Allocator.Error![:0]u8 {
    const baked: ?[]u8 = std.process.getEnvVarOwned(alloc, endpoint_env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (baked) |b| alloc.free(b);

    const suffix: ?[]u8 = std.process.getEnvVarOwned(alloc, suffix_env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (suffix) |s| alloc.free(s);

    return clientEndpointPathFrom(alloc, baked, suffix != null);
}

/// `clientEndpointPath` with the environment injected, so the preference rule
/// is testable without mutating the process environment.
fn clientEndpointPathFrom(
    alloc: Allocator,
    baked: ?[]const u8,
    suffix_set: bool,
) Allocator.Error![:0]u8 {
    // An explicit `GHOZTTY_PIPE_SUFFIX` OUTRANKS the baked value, and this is
    // load-bearing rather than a nicety: the suffix is the test hook that says
    // "aim at THIS instance", and an acceptance script inherits the env of the
    // pane it was started from. Once the installed release bakes an endpoint,
    // every `test\win32\*.ps1` launched from one of the user's own panes would
    // otherwise inherit the USER'S endpoint and drive their terminal instead of
    // the build under test — precisely the T116 accident, arriving through the
    // fix for it. Most explicit wins; the suffix is set by a caller, the baked
    // value by the app.
    if (!suffix_set) {
        // Empty means the same as absent: derive it. (A pane baked by an app or
        // agent that predates this var leaves it absent entirely, and overriding
        // it to "" is how a caller asks for the derivation explicitly.)
        if (baked) |path| {
            if (path.len > 0) return alloc.dupeZ(u8, path);
        }
    }
    return endpointPath(alloc);
}

/// Build the endpoint path of the running instance's IPC server. Debug
/// builds get a distinct endpoint so a debug instance can run beside the
/// release app. Note the historical spelling split: the Unix socket kept
/// the upstream `ghostty` name, while the Windows pipe uses the fork's
/// `ghoztty` name (pinned in the parity spec).
///
/// This is the DERIVATION only: it never reads `$GHOZTTY_IPC_SOCKET`. The
/// server binds this; clients go through `clientEndpointPath`.
pub fn endpointPath(alloc: Allocator) Allocator.Error![:0]u8 {
    // Test hook: GHOZTTY_PIPE_SUFFIX overrides the debug/release endpoint
    // suffix so an instrumented release build (and its CLI invocations,
    // which inherit the env) can run beside the installed instance.
    // Used by the perf/acceptance harnesses in test/win32/.
    const env_suffix: ?[]u8 = std.process.getEnvVarOwned(
        alloc,
        suffix_env,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (env_suffix) |s| alloc.free(s);

    const suffix: []const u8 = if (env_suffix) |s| s else if (build_config.is_debug) "-debug" else "";
    if (comptime is_windows) {
        // USERNAME is set for every interactive session; the fallback only
        // matters for exotic service contexts.
        const user: ?[]u8 = std.process.getEnvVarOwned(alloc, "USERNAME") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        defer if (user) |u| alloc.free(u);
        return std.fmt.allocPrintSentinel(
            alloc,
            "\\\\.\\pipe\\ghoztty{s}-{s}",
            .{ suffix, user orelse "default" },
            0,
        );
    }

    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const uid = std.c.getuid();
    return std.fmt.allocPrintSentinel(
        alloc,
        "{s}ghostty{s}-{d}.sock",
        .{ tmpdir, suffix, uid },
        0,
    );
}

/// Connect to the running instance. Fails with NoRunningInstance if nothing
/// is listening; emits no diagnostics (callers own the messaging).
pub fn connect(alloc: Allocator) Error!Conn {
    const path = try clientEndpointPath(alloc);
    defer alloc.free(path);
    return connectPath(alloc, path);
}

/// Connect like `connect`, but if the endpoint exists and refuses
/// connections, ask the running instance to rebind and retry with backoff.
/// On posix this drops a `<socket>.reset` sentinel file that the server
/// watches for (the Mac server's recovery protocol). On Windows a dead pipe
/// simply stops existing, so a plain connect is equivalent.
pub fn connectWithReset(alloc: Allocator, stderr: *std.Io.Writer) Error!Conn {
    const path = try clientEndpointPath(alloc);
    defer alloc.free(path);

    if (comptime is_windows) return connectPath(alloc, path);

    const bound = resolvedTimeoutMs(alloc);
    if (connectUnixSocket(path)) |fd| return .{
        .handle = fd,
        .owned = true,
        .timeout_ms = bound,
    } else |_| {}

    // Connection failed. Drop a sentinel file to signal the main process to
    // rebind its socket, then retry with backoff.
    const sentinel_path = std.fmt.allocPrintSentinel(alloc, "{s}.reset", .{path}, 0) catch {
        stderr.print("Could not connect to running Ghoztty instance.\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    defer alloc.free(sentinel_path);

    if (std.fs.cwd().createFile(sentinel_path, .{})) |f| {
        f.close();
    } else |_| {}

    const max_retries = 8;
    var attempt: usize = 0;
    while (attempt < max_retries) : (attempt += 1) {
        std.Thread.sleep(300 * std.time.ns_per_ms);
        if (connectUnixSocket(path)) |connected_fd| {
            std.fs.cwd().deleteFile(sentinel_path) catch {};
            return .{ .handle = connected_fd, .owned = true, .timeout_ms = bound };
        } else |_| {}

        // If the sentinel file still exists after several attempts, no
        // server is watching for it — bail early.
        if (attempt >= 2) {
            if (std.fs.accessAbsolute(sentinel_path, .{})) |_| {
                break;
            } else |_| {}
        }
    }

    std.fs.cwd().deleteFile(sentinel_path) catch {};
    return error.NoRunningInstance;
}

/// The bound every connection this module opens carries, resolved once from
/// the environment (`GHOZTTY_IPC_TIMEOUT_MS`; see `ipc_timeout.zig`).
fn resolvedTimeoutMs(alloc: Allocator) u32 {
    const raw: ?[]u8 = std.process.getEnvVarOwned(alloc, timeout.env_var) catch null;
    defer if (raw) |r| alloc.free(r);
    return timeout.resolve(raw);
}

fn connectPath(alloc: Allocator, path: [:0]const u8) Error!Conn {
    const bound = resolvedTimeoutMs(alloc);

    if (comptime is_windows) {
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoRunningInstance,
        };
        defer alloc.free(path_w);

        // The server hands out one pipe instance per connection; PIPE_BUSY
        // means all instances are mid-request, so wait for a free one.
        var attempts: u8 = 0;
        while (true) {
            const handle = windows.kernel32.CreateFileW(
                path_w.ptr,
                windows.GENERIC_READ | windows.GENERIC_WRITE,
                0,
                null,
                windows.OPEN_EXISTING,
                // T755: overlapped, so a read that the peer never answers can
                // be cancelled instead of blocking this process forever. A
                // synchronous ReadFile on a named pipe is uninterruptible, and
                // that is exactly how a `+list` came to wait 34 minutes.
                windows.FILE_FLAG_OVERLAPPED,
                null,
            );
            if (handle != windows.INVALID_HANDLE_VALUE) return .{
                .handle = handle,
                .owned = true,
                .timeout_ms = bound,
            };
            switch (windows.GetLastError()) {
                .PIPE_BUSY => {
                    attempts += 1;
                    if (attempts >= 10) return error.NoRunningInstance;
                    _ = WaitNamedPipeW(path_w.ptr, 1000);
                },
                else => return error.NoRunningInstance,
            }
        }
    }

    const fd = connectUnixSocket(path) catch return error.NoRunningInstance;
    return .{ .handle = fd, .owned = true, .timeout_ms = bound };
}

fn connectUnixSocket(path: [:0]const u8) !std.posix.fd_t {
    const fd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
    );
    errdefer std.posix.close(fd);

    var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;

    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
    return fd;
}

/// Serialize the request JSON `{"action":<name>,"arguments":[...]}`. A null
/// `arguments` omits the field entirely; an empty slice writes an empty
/// array (some verbs always send the field — preserve their wire shape).
pub fn buildRequest(
    alloc: Allocator,
    action: []const u8,
    arguments: ?[]const [:0]const u8,
) Allocator.Error![]u8 {
    return buildRequestWithHandoff(alloc, action, arguments, null);
}

/// `buildRequest` plus the optional `handoff` object a LAUNCH attaches when it
/// hands its window to the instance that already owns the endpoint (T1022).
///
/// Additive by construction and in both directions: an older server parses
/// with `ignore_unknown_fields` and behaves exactly as it did, and a server
/// that understands the field treats its absence as "an older launcher, say
/// nothing". Nothing else on the wire moves.
pub fn buildRequestWithHandoff(
    alloc: Allocator,
    action: []const u8,
    arguments: ?[]const [:0]const u8,
    handoff_id: ?handoff.Identity,
) Allocator.Error![]u8 {
    var json_buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer json_buf.deinit();
    var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

    // The Allocating writer only fails on OOM.
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("action") catch break :write;
        jws.write(action) catch break :write;
        if (arguments) |args| {
            jws.objectField("arguments") catch break :write;
            jws.beginArray() catch break :write;
            for (args) |arg| jws.write(arg) catch break :write;
            jws.endArray() catch break :write;
        }
        if (handoff_id) |id| {
            jws.objectField("handoff") catch break :write;
            jws.beginObject() catch break :write;
            jws.objectField("version") catch break :write;
            jws.write(id.version) catch break :write;
            jws.objectField("commit") catch break :write;
            jws.write(id.commit) catch break :write;
            jws.objectField("exe") catch break :write;
            jws.write(id.exe) catch break :write;
            jws.endObject() catch break :write;
        }
        jws.endObject() catch break :write;
        return json_buf.toOwnedSlice();
    }
    return error.OutOfMemory;
}

pub const ExchangeOptions = struct {
    /// Upper bound accepted for the response body length.
    max_response: u32 = 1_048_576,

    /// The verb this exchange belongs to, as a user would type it. It appears
    /// in the waiting notice and the timeout message (T755) — "Ghoztty is not
    /// answering" is not an actionable sentence unless it says which command
    /// was asking. The default only shows up if a caller forgets.
    action: []const u8 = "the request",
};

/// Send one framed request over `conn` and return the framed response body,
/// allocated from `alloc` (caller frees). Failure diagnostics are written
/// to `stderr` before IPCFailed is returned.
///
/// The response read is bounded (T755): the peer marshals every request to its
/// GUI thread, and that thread can be busy — or wedged — with no way for this
/// side to tell. A slow peer gets a "still waiting" line at `timeout.notice_ms`
/// and the rest of the budget; a peer that never answers gets a sentence and a
/// nonzero exit instead of an indefinite block.
pub fn exchange(
    alloc: Allocator,
    conn: Conn,
    json_bytes: []const u8,
    opts: ExchangeOptions,
    stderr: *std.Io.Writer,
) Error![]u8 {
    const len: u32 = @intCast(json_bytes.len);
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, len));
    conn.writeAll(&len_bytes) catch |err| {
        reportSendFailure(stderr, opts.action, conn.timeout_ms, err);
        return error.IPCFailed;
    };
    conn.writeAll(json_bytes) catch |err| {
        reportSendFailure(stderr, opts.action, conn.timeout_ms, err);
        return error.IPCFailed;
    };

    // Whether the "still waiting" line has already been printed. It is per
    // EXCHANGE, not per read: a peer slow enough to trip the notice on the
    // length is the same peer still being slow on the body, and saying so
    // twice about one command reads as a stutter.
    var noticed = false;

    var resp_len_bytes: [4]u8 = undefined;
    readFramed(conn, &resp_len_bytes, &noticed, opts.action, stderr) catch |err| switch (err) {
        error.Timeout => return error.IPCFailed,
        else => {
            stderr.print("Failed to read IPC response length\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        },
    };

    const resp_len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp_len_bytes).*);
    if (resp_len == 0 or resp_len > opts.max_response) {
        stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    }

    const resp_buf = try alloc.alloc(u8, resp_len);
    errdefer alloc.free(resp_buf);

    readFramed(conn, resp_buf, &noticed, opts.action, stderr) catch |err| switch (err) {
        error.Timeout => return error.IPCFailed,
        else => {
            stderr.print("Failed to read IPC response\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        },
    };

    return resp_buf;
}

/// One bounded read of a whole frame, in the two stages `ipc_timeout`
/// describes: wait quietly up to the notice, say we are still waiting, then
/// wait out the rest of the budget. The progress cursor is what lets the
/// second stage resume the first stage's partial read rather than restart it.
fn readFramed(
    conn: Conn,
    buffer: []u8,
    noticed: *bool,
    action: []const u8,
    stderr: *std.Io.Writer,
) !void {
    var done: usize = 0;

    if (!noticed.*) {
        conn.readFullWithin(
            buffer,
            &done,
            timeout.firstWaitMs(conn.timeout_ms),
        ) catch |err| switch (err) {
            error.Timeout => {
                noticed.* = true;
                timeout.writeNotice(stderr, action);
            },
            else => return err,
        };
        if (done == buffer.len) return;
    }

    conn.readFullWithin(
        buffer,
        &done,
        timeout.remainingWaitMs(conn.timeout_ms),
    ) catch |err| switch (err) {
        error.Timeout => {
            timeout.writeTimeout(stderr, action, .response, conn.timeout_ms);
            return error.Timeout;
        },
        else => return err,
    };
}

fn reportSendFailure(
    stderr: *std.Io.Writer,
    action: []const u8,
    timeout_ms: u32,
    err: anyerror,
) void {
    if (err == error.Timeout) {
        timeout.writeTimeout(stderr, action, .request, timeout_ms);
        return;
    }
    stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
    stderr.flush() catch {};
}

/// The complete client side of the simple action verbs (`+new-window`,
/// `+split`, `+close`, ...): connect (with reset-retry), send the action,
/// interpret the standard `{success, error}` response. On failure the
/// server's human-readable reason is printed to stderr so EVERY CLI action
/// surfaces the real cause instead of a generic fallback. Returns whether
/// the server reported success.
pub fn sendAction(
    alloc: Allocator,
    action_name: []const u8,
    arguments: ?[]const [:0]const u8,
) Error!bool {
    return sendActionWithHandoff(alloc, action_name, arguments, null);
}

/// `sendAction` for the LAUNCH HANDOFF (T1022): the same exchange, plus this
/// process's build identity so the instance that already owns the endpoint can
/// tell whether the window it is about to open belongs to the build the user
/// actually started. Only `App.init`'s `AlreadyRunning` branch passes one — a
/// CLI verb is not a launch and has nothing to hand over.
pub fn sendActionWithHandoff(
    alloc: Allocator,
    action_name: []const u8,
    arguments: ?[]const [:0]const u8,
    handoff_id: ?handoff.Identity,
) Error!bool {
    var buf: [256]u8 = undefined;
    // Streaming (not positional) writer: the CLI command that called us
    // has its own buffered stderr writer, and mixing a positional writer
    // with it corrupts/reorders output when stderr is a file or pipe.
    var stderr_writer = std.fs.File.stderr().writerStreaming(&buf);
    const stderr = &stderr_writer.interface;

    const conn = try connectWithReset(alloc, stderr);
    defer conn.close();

    const json_bytes = try buildRequestWithHandoff(alloc, action_name, arguments, handoff_id);
    defer alloc.free(json_bytes);

    var action_buf: [64]u8 = undefined;
    const resp_buf = try exchange(alloc, conn, json_bytes, .{
        .action = std.fmt.bufPrint(&action_buf, "+{s}", .{action_name}) catch action_name,
    }, stderr);
    defer alloc.free(resp_buf);

    const parsed = std.json.parseFromSlice(
        struct {
            success: bool = false,
            @"error": ?[]const u8 = null,
            // T135: a non-fatal caveat about a successful action (e.g.
            // `+new-window --target=` focusing an existing window and
            // dropping the create-only flags). Absent from older servers.
            note: ?[]const u8 = null,
        },
        alloc,
        resp_buf,
        .{ .ignore_unknown_fields = true },
    ) catch {
        stderr.print("IPC response is not valid JSON\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    defer parsed.deinit();

    if (!parsed.value.success) {
        if (parsed.value.@"error") |msg| {
            stderr.print("{s}\n", .{msg}) catch {};
            stderr.flush() catch {};
        }
        return false;
    }

    // A note is success with a caveat: surface it, keep exit code 0.
    if (parsed.value.note) |msg| {
        stderr.print("{s}\n", .{msg}) catch {};
        stderr.flush() catch {};
    }

    return true;
}

test "buildRequest: no handoff object unless a launch supplies one (T1022)" {
    const testing = std.testing;
    const json = try buildRequest(testing.allocator, "new-window", null);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"action\":\"new-window\"}", json);
    try testing.expect(std.mem.indexOf(u8, json, "handoff") == null);
}

test "buildRequestWithHandoff: the launch's build rides beside the arguments (T1022)" {
    const testing = std.testing;
    const args = [_][:0]const u8{"--working-directory=D:\\proj"};
    const json = try buildRequestWithHandoff(
        testing.allocator,
        "new-window",
        &args,
        .{ .version = "1.4.0", .commit = "abc1234", .exe = "D:\\a\\ghoztty.exe" },
    );
    defer testing.allocator.free(json);

    // The pre-existing shape is untouched — an older server parsing this with
    // `ignore_unknown_fields` sees exactly the request it saw before.
    try testing.expect(std.mem.indexOf(u8, json, "\"action\":\"new-window\"") != null);
    // JSON-escaped: one source backslash arrives on the wire as two.
    try testing.expect(std.mem.indexOf(u8, json, "--working-directory=D:\\\\proj") != null);
    // ...and the new object is a sibling of it, not nested in the arguments.
    try testing.expect(std.mem.indexOf(u8, json, "\"handoff\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"commit\":\"abc1234\"") != null);

    // It round-trips through a parser that ignores what it does not know.
    const parsed = try std.json.parseFromSlice(
        struct { action: []const u8, handoff: handoff.Identity = .{} },
        testing.allocator,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("1.4.0", parsed.value.handoff.version);
    try testing.expectEqualStrings("D:\\a\\ghoztty.exe", parsed.value.handoff.exe);
}

test "clientEndpointPath: the pane's baked endpoint beats the derivation" {
    const testing = std.testing;
    const baked = if (comptime is_windows)
        "\\\\.\\pipe\\ghoztty-debug-someone-else"
    else
        "/tmp/gz-test/ghostty-debug-501.sock";

    const path = try clientEndpointPathFrom(testing.allocator, baked, false);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(baked, path);

    // ...and it must NOT be what the server binds, or an app launched from
    // another instance's pane would try to own that instance's endpoint.
    const derived = try endpointPath(testing.allocator);
    defer testing.allocator.free(derived);
    try testing.expect(!std.mem.eql(u8, derived, baked));
}

test "clientEndpointPath: unset and empty both mean derive it" {
    const testing = std.testing;
    const derived = try endpointPath(testing.allocator);
    defer testing.allocator.free(derived);

    const unset = try clientEndpointPathFrom(testing.allocator, null, false);
    defer testing.allocator.free(unset);
    const empty = try clientEndpointPathFrom(testing.allocator, "", false);
    defer testing.allocator.free(empty);

    try testing.expectEqualStrings(derived, unset);
    try testing.expectEqualStrings(derived, empty);
}

test "clientEndpointPath: an explicit suffix outranks the baked endpoint" {
    // A test harness sets GHOZTTY_PIPE_SUFFIX to aim at the instance it just
    // launched, and it inherits the env of the pane it was started from. If
    // the pane's baked endpoint won, the harness would drive the USER'S app.
    const testing = std.testing;
    const baked = if (comptime is_windows)
        "\\\\.\\pipe\\ghoztty-the-users-instance"
    else
        "/tmp/gz-test/ghostty-the-users-instance.sock";

    const derived = try endpointPath(testing.allocator);
    defer testing.allocator.free(derived);
    const aimed = try clientEndpointPathFrom(testing.allocator, baked, true);
    defer testing.allocator.free(aimed);

    try testing.expectEqualStrings(derived, aimed);
}

test "buildRequest: action only omits arguments" {
    const testing = std.testing;
    const json = try buildRequest(testing.allocator, "list", null);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"action\":\"list\"}", json);
}

test "buildRequest: arguments array" {
    const testing = std.testing;
    var args_buf = [_][:0]const u8{ "--name=logs", "--lines=5" };
    const json = try buildRequest(testing.allocator, "read", &args_buf);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"action\":\"read\",\"arguments\":[\"--name=logs\",\"--lines=5\"]}",
        json,
    );
}

test "buildRequest: empty arguments still writes the field" {
    const testing = std.testing;
    const json = try buildRequest(testing.allocator, "new-remote-window", &.{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"action\":\"new-remote-window\",\"arguments\":[]}",
        json,
    );
}
