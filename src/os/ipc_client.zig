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

    pub const Handle = if (is_windows) windows.HANDLE else std.posix.fd_t;

    pub fn close(self: Conn) void {
        if (comptime is_windows) {
            windows.CloseHandle(self.handle);
        } else {
            std.posix.close(self.handle);
        }
    }

    pub fn writeAll(self: Conn, bytes: []const u8) !void {
        var total: usize = 0;
        while (total < bytes.len) {
            const n = if (comptime is_windows)
                try windows.WriteFile(self.handle, bytes[total..], null)
            else
                try std.posix.write(self.handle, bytes[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    pub fn readFull(self: Conn, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            // On Windows, std's ReadFile maps BROKEN_PIPE/EOF to 0 already.
            const n = if (comptime is_windows)
                try windows.ReadFile(self.handle, buffer[total..], null)
            else
                try std.posix.read(self.handle, buffer[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }
};

/// Build the endpoint path of the running instance's IPC server. Debug
/// builds get a distinct endpoint so a debug instance can run beside the
/// release app. Note the historical spelling split: the Unix socket kept
/// the upstream `ghostty` name, while the Windows pipe uses the fork's
/// `ghoztty` name (pinned in the parity spec).
pub fn endpointPath(alloc: Allocator) Allocator.Error![:0]u8 {
    // Test hook: GHOZTTY_PIPE_SUFFIX overrides the debug/release endpoint
    // suffix so an instrumented release build (and its CLI invocations,
    // which inherit the env) can run beside the installed instance.
    // Used by the perf/acceptance harnesses in test/win32/.
    const env_suffix: ?[]u8 = std.process.getEnvVarOwned(
        alloc,
        "GHOZTTY_PIPE_SUFFIX",
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
    const path = try endpointPath(alloc);
    defer alloc.free(path);
    return connectPath(alloc, path);
}

/// Connect like `connect`, but if the endpoint exists and refuses
/// connections, ask the running instance to rebind and retry with backoff.
/// On posix this drops a `<socket>.reset` sentinel file that the server
/// watches for (the Mac server's recovery protocol). On Windows a dead pipe
/// simply stops existing, so a plain connect is equivalent.
pub fn connectWithReset(alloc: Allocator, stderr: *std.Io.Writer) Error!Conn {
    const path = try endpointPath(alloc);
    defer alloc.free(path);

    if (comptime is_windows) return connectPath(alloc, path);

    if (connectUnixSocket(path)) |fd| return .{ .handle = fd } else |_| {}

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
            return .{ .handle = connected_fd };
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

fn connectPath(alloc: Allocator, path: [:0]const u8) Error!Conn {
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
                0,
                null,
            );
            if (handle != windows.INVALID_HANDLE_VALUE) return .{ .handle = handle };
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
    return .{ .handle = fd };
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
        jws.endObject() catch break :write;
        return json_buf.toOwnedSlice();
    }
    return error.OutOfMemory;
}

pub const ExchangeOptions = struct {
    /// Upper bound accepted for the response body length.
    max_response: u32 = 1_048_576,
};

/// Send one framed request over `conn` and return the framed response body,
/// allocated from `alloc` (caller frees). Failure diagnostics are written
/// to `stderr` before IPCFailed is returned.
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
        stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    conn.writeAll(json_bytes) catch |err| {
        stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    var resp_len_bytes: [4]u8 = undefined;
    conn.readFull(&resp_len_bytes) catch {
        stderr.print("Failed to read IPC response length\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    const resp_len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp_len_bytes).*);
    if (resp_len == 0 or resp_len > opts.max_response) {
        stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    }

    const resp_buf = try alloc.alloc(u8, resp_len);
    errdefer alloc.free(resp_buf);

    conn.readFull(resp_buf) catch {
        stderr.print("Failed to read IPC response\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    return resp_buf;
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
    var buf: [256]u8 = undefined;
    // Streaming (not positional) writer: the CLI command that called us
    // has its own buffered stderr writer, and mixing a positional writer
    // with it corrupts/reorders output when stderr is a file or pipe.
    var stderr_writer = std.fs.File.stderr().writerStreaming(&buf);
    const stderr = &stderr_writer.interface;

    const conn = try connectWithReset(alloc, stderr);
    defer conn.close();

    const json_bytes = try buildRequest(alloc, action_name, arguments);
    defer alloc.free(json_bytes);

    const resp_buf = try exchange(alloc, conn, json_bytes, .{}, stderr);
    defer alloc.free(resp_buf);

    const parsed = std.json.parseFromSlice(
        struct { success: bool = false, @"error": ?[]const u8 = null },
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

    return true;
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
