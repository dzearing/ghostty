//! IPC server for the win32 apprt: a named-pipe listener owned by the App
//! (docs/design/windows-parity-spec.md, "Architecture decisions"). The pipe
//! is created with an owner-only DACL and FILE_FLAG_FIRST_PIPE_INSTANCE, so
//! binding doubles as the single-instance lock: a second GUI launch fails to
//! bind, forwards a `new-window` request as a client, and exits.
//!
//! Connections are short-lived request/response (4-byte BE length + JSON,
//! both directions — the exact Mac wire protocol). Each request is marshaled
//! to the GUI thread via the App's message-only window (WM_APP_IPC +
//! ResetEvent), because all registry/window operations must run on the GUI
//! thread — so verbs still EXECUTE serially no matter how many arrive.
//!
//! ACCEPTING, however, is pooled across `instance_count` pipe instances, one
//! listener thread each (T111b). With a single instance the listener could
//! only accept while no request was outstanding, so ANY slow handler stopped
//! the server from accepting at all — and a client that cannot connect does
//! not report "busy", it exhausts its PIPE_BUSY retries and prints "No
//! running Ghoztty instance found." Measured: with the one instance occupied,
//! every other `+list` failed with that string after ~9.2 s, which is the
//! whole of T111's "the GUI-thread pipe listener has stopped ACCEPTING" and
//! the 9227 ms `+read` that looked like a read-latency regression but never
//! reached the handler at all. Pooling degrades a slow handler to SLOW
//! instead of ABSENT.
const IpcServer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const App = @import("App.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const w32 = @import("win32.zig");
const internal_os = @import("../../os/main.zig");
const ipc_client = internal_os.ipc_client;

const log = std.log.scoped(.win32_ipc);

/// Same bound the Mac server enforces on request payloads.
const max_request_len: u32 = 1_048_576;

/// How many pipe instances accept concurrently (one listener thread each).
/// Handlers still run one at a time on the GUI thread, so this buys no
/// throughput — it buys the ability to ACCEPT a client while another request
/// is in flight, which is the difference between a slow answer and "No
/// running Ghoztty instance found." Kept small deliberately: the real cure
/// for a slow handler is a fast handler, and a deep pool would only hide it.
const instance_count = 4;

// --- Win32 declarations missing from std / win32.zig -----------------------

const FILE_FLAG_FIRST_PIPE_INSTANCE: windows.DWORD = 0x00080000;
const PIPE_REJECT_REMOTE_CLIENTS: windows.DWORD = 0x00000008;
const TOKEN_QUERY: windows.DWORD = 0x0008;
const TokenUser: c_int = 1;
const SDDL_REVISION_1: windows.DWORD = 1;

const SID_AND_ATTRIBUTES = extern struct {
    Sid: *anyopaque,
    Attributes: windows.DWORD,
};
const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: windows.HANDLE,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn OpenProcessToken(
    ProcessHandle: windows.HANDLE,
    DesiredAccess: windows.DWORD,
    TokenHandle: *windows.HANDLE,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn GetTokenInformation(
    TokenHandle: windows.HANDLE,
    TokenInformationClass: c_int,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: windows.DWORD,
    ReturnLength: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn ConvertSidToStringSidW(
    Sid: *anyopaque,
    StringSid: *?[*:0]u16,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: [*:0]const u16,
    StringSDRevision: windows.DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

// ----------------------------------------------------------------------------

app: *App,
alloc: Allocator,

/// The accepting pipe instances. `pipes[0]` owns the name (first-instance
/// flag) and is the single-instance lock for the whole app; the rest are
/// extra instances of the same name. Unavailable slots hold
/// INVALID_HANDLE_VALUE — a failure to create an EXTRA instance is degraded
/// service, never a failure to start.
pipes: [instance_count]windows.HANDLE,

/// UTF-16 pipe path, kept for the shutdown dummy-connect.
path_w: [:0]u16,

threads: [instance_count]?std.Thread = @splat(null),
shutdown: std.atomic.Value(bool) = .{ .raw = false },

/// Env-gated (`GHOZTTY_PERF`) request timing. T111a proved that this boundary
/// has to be MEASURED, not reasoned about: its filed prime suspect was refuted
/// only because the round trip was split into queue vs handler time. Keep the
/// split available so the next regression on this path is diagnosed the same
/// way instead of guessed at.
perf: bool = false,

/// How many listener threads are still able to post marshal messages.
/// Each decrements this as its very last statement; deinit spins until it
/// reaches zero, draining WM_APP_IPC meanwhile so an in-flight request
/// can't deadlock the join.
listeners_live: std.atomic.Value(u32) = .{ .raw = 0 },

/// One request in flight from the listener thread to the GUI thread.
pub const Pending = struct {
    server: *IpcServer,
    request_json: []const u8,
    /// Set by the GUI thread (allocated with server.alloc; listener frees).
    response: ?[]u8 = null,
    done: std.Thread.ResetEvent = .{},
    /// GHOZTTY_PERF: stamped by the GUI thread the instant it picks the
    /// request up, so the listener can split its wait into queue latency
    /// (post → pickup) and handler time (pickup → done).
    gui_start: ?std.time.Instant = null,
};

pub const BindError = error{
    /// Another process already owns the pipe name: a Ghoztty instance is
    /// running. The caller forwards its request and exits.
    AlreadyRunning,
    /// Pipe creation failed for any other reason. The app can still run,
    /// just without an IPC server.
    BindFailed,
} || Allocator.Error;

/// Bind the pipe and start the listener thread. On AlreadyRunning the caller
/// is the second instance (see module docs).
pub fn init(self: *IpcServer, app: *App) BindError!void {
    const alloc = app.core_app.alloc;

    const path = try ipc_client.endpointPath(alloc);
    defer alloc.free(path);
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BindFailed,
    };
    errdefer alloc.free(path_w);

    const sd = ownerOnlyDescriptor(alloc) catch |err| sd: {
        // Fall back to the default DACL rather than refusing to serve; the
        // default still limits write access to the creator.
        log.warn("owner-only DACL construction failed err={}; using default", .{err});
        break :sd null;
    };
    defer if (sd) |p| {
        _ = LocalFree(p);
    };
    var sa: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = sd,
        .bInheritHandle = windows.FALSE,
    };

    // Instance 0 carries FIRST_PIPE_INSTANCE: creating it IS the
    // single-instance lock, so it must be the one whose failure means
    // "another Ghoztty owns this name".
    const first = windows.kernel32.CreateNamedPipeW(
        path_w.ptr,
        windows.PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
        windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE |
            windows.PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        instance_count,
        64 * 1024,
        64 * 1024,
        0,
        if (sd != null) &sa else null,
    );
    if (first == windows.INVALID_HANDLE_VALUE) {
        return switch (windows.GetLastError()) {
            // With FIRST_PIPE_INSTANCE, a taken name comes back as
            // ACCESS_DENIED (or PIPE_BUSY on some paths).
            .ACCESS_DENIED, .PIPE_BUSY => error.AlreadyRunning,
            else => |err| err: {
                log.warn("CreateNamedPipeW failed err={}", .{err});
                break :err error.BindFailed;
            },
        };
    }
    errdefer windows.CloseHandle(first);

    self.* = .{
        .app = app,
        .alloc = alloc,
        .pipes = @splat(windows.INVALID_HANDLE_VALUE),
        .path_w = path_w,
        .perf = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF"),
    };
    self.pipes[0] = first;

    // The extra instances. Same name, no first-instance flag. Each failure
    // costs concurrency only, so log and serve with what we got rather than
    // refusing to start an app over it.
    for (1..instance_count) |i| {
        const extra = windows.kernel32.CreateNamedPipeW(
            path_w.ptr,
            windows.PIPE_ACCESS_DUPLEX,
            windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE |
                windows.PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            instance_count,
            64 * 1024,
            64 * 1024,
            0,
            if (sd != null) &sa else null,
        );
        if (extra == windows.INVALID_HANDLE_VALUE) {
            log.warn("extra IPC pipe instance {d} failed err={}", .{ i, windows.GetLastError() });
            break;
        }
        self.pipes[i] = extra;
    }

    var listening: usize = 0;
    for (&self.pipes, 0..) |pipe, i| {
        if (pipe == windows.INVALID_HANDLE_VALUE) continue;
        _ = self.listeners_live.fetchAdd(1, .acq_rel);
        self.threads[i] = std.Thread.spawn(.{}, listen, .{ self, i }) catch |err| {
            _ = self.listeners_live.fetchSub(1, .acq_rel);
            log.warn("IPC listener thread {d} spawn failed err={}", .{ i, err });
            continue;
        };
        listening += 1;
    }
    if (listening == 0) {
        for (&self.pipes) |*p| {
            if (p.* != windows.INVALID_HANDLE_VALUE and p.* != first) windows.CloseHandle(p.*);
            p.* = windows.INVALID_HANDLE_VALUE;
        }
        return error.BindFailed;
    }
    log.info("IPC server listening on {s} ({d} instances)", .{ path, listening });
}

/// Stop the listener and release the pipe. Runs on the GUI thread, before
/// the App destroys its message-only window.
pub fn deinit(self: *IpcServer) void {
    self.shutdown.store(true, .release);

    // Every listener parked in ConnectNamedPipe needs a throwaway client
    // connect to wake it, and one connect wakes exactly ONE instance — so
    // keep connecting until none are live rather than firing a fixed number
    // (a listener still mid-request refuses with PIPE_BUSY and re-checks the
    // shutdown flag when it finishes, so the loop must also keep spinning).
    // Meanwhile a listener may be blocked on `Pending.done` for a request
    // whose WM_APP_IPC is sitting in our no-longer-pumped queue, so drain
    // those in the same loop or the join below deadlocks.
    while (self.listeners_live.load(.acquire) > 0) {
        const dummy = windows.kernel32.CreateFileW(
            self.path_w.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            0,
            null,
        );
        if (dummy != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(dummy);

        if (self.app.msg_hwnd) |hwnd| {
            var msg: w32.MSG = undefined;
            while (w32.PeekMessageW(&msg, hwnd, App.WM_APP_IPC, App.WM_APP_IPC, w32.PM_REMOVE) != 0) {
                if (msg.wParam != 0) {
                    const pending: *Pending = @ptrFromInt(msg.wParam);
                    serveOnGuiThread(pending);
                }
            }
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    for (&self.threads) |*slot| {
        if (slot.*) |thread| thread.join();
        slot.* = null;
    }
    for (&self.pipes) |*pipe| {
        if (pipe.* != windows.INVALID_HANDLE_VALUE) windows.CloseHandle(pipe.*);
        pipe.* = windows.INVALID_HANDLE_VALUE;
    }
    self.alloc.free(self.path_w);
}

/// Listener thread body for one pipe instance: serve one framed request per
/// connection. Instances accept in parallel; the requests they marshal are
/// still executed one at a time by the GUI thread.
fn listen(self: *IpcServer, idx: usize) void {
    const pipe = self.pipes[idx];
    defer _ = self.listeners_live.fetchSub(1, .acq_rel);
    const max_accept_failures = 8;
    var consecutive_failures: usize = 0;
    while (true) {
        if (self.shutdown.load(.acquire)) return;
        // GHOZTTY_PERF: how long this instance sat LISTENING before a client
        // arrived. A long idle here means clients were not even trying; a
        // near-zero idle under load means they were queued at PIPE_BUSY,
        // which is the difference between "GUI slow" and "server serial".
        const accept_start: ?std.time.Instant =
            if (self.perf) (std.time.Instant.now() catch null) else null;
        if (ConnectNamedPipe(pipe, null) == 0) {
            switch (windows.GetLastError()) {
                // Client connected between CreateNamedPipe/Disconnect and
                // ConnectNamedPipe: the connection is fine, serve it.
                .PIPE_CONNECTED => {},
                else => |err| {
                    if (self.shutdown.load(.acquire)) return;
                    // A failed accept used to END this thread, which meant one
                    // transient error retired the instance for the life of the
                    // app — indistinguishable, from a client, from "Ghoztty is
                    // not running". Reset the instance and keep accepting;
                    // only a stuck-failing instance (which would otherwise hot
                    // spin) gives up.
                    log.warn("ConnectNamedPipe instance {d} failed err={}", .{ idx, err });
                    consecutive_failures += 1;
                    if (consecutive_failures >= max_accept_failures) {
                        log.err("IPC instance {d} retiring after {d} failed accepts", .{
                            idx, consecutive_failures,
                        });
                        return;
                    }
                    _ = DisconnectNamedPipe(pipe);
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
            }
        }
        consecutive_failures = 0;
        if (self.shutdown.load(.acquire)) return;
        self.serveOne(pipe, accept_start);
        _ = FlushAndDisconnect(pipe);
    }
}

fn FlushAndDisconnect(pipe: windows.HANDLE) bool {
    _ = windows.kernel32.FlushFileBuffers(pipe);
    return DisconnectNamedPipe(pipe) != 0;
}

/// Read one framed request from the connected client, marshal it to the GUI
/// thread, write the framed response. All failures are answered on the wire
/// when possible (matching the Mac server's error strings).
fn serveOne(self: *IpcServer, pipe: windows.HANDLE, accept_start: ?std.time.Instant) void {
    const conn: ipc_client.Conn = .{ .handle = pipe };
    const connected: ?std.time.Instant =
        if (self.perf) (std.time.Instant.now() catch null) else null;

    var len_bytes: [4]u8 = undefined;
    conn.readFull(&len_bytes) catch {
        self.respondError(conn, "invalid message");
        return;
    };
    const len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &len_bytes).*);
    if (len == 0 or len >= max_request_len) {
        self.respondError(conn, "invalid length");
        return;
    }

    const body = self.alloc.alloc(u8, len) catch {
        self.respondError(conn, "out of memory");
        return;
    };
    defer self.alloc.free(body);
    conn.readFull(body) catch {
        self.respondError(conn, "incomplete message");
        return;
    };

    // Marshal to the GUI thread and wait. No timeout: request/response is
    // serial and the GUI thread owns every operation the verbs need (the Mac
    // server behaves the same way).
    var pending: Pending = .{ .server = self, .request_json = body };
    if (w32.PostMessageW(
        self.app.msg_hwnd orelse {
            self.respondError(conn, "server not ready");
            return;
        },
        App.WM_APP_IPC,
        @intFromPtr(&pending),
        0,
    ) == 0) {
        self.respondError(conn, "server not ready");
        return;
    }
    const posted: ?std.time.Instant =
        if (self.perf) (std.time.Instant.now() catch null) else null;
    pending.done.wait();
    if (self.perf) self.logPerf(body, accept_start, connected, posted, pending.gui_start);

    const response = pending.response orelse {
        self.respondError(conn, "internal error");
        return;
    };
    defer self.alloc.free(response);
    self.writeFramed(conn, response);
}

/// GHOZTTY_PERF: one line per served request, splitting the wall clock the
/// client sees into the four segments that have distinct causes —
///   accept  listener idle in ConnectNamedPipe before this client arrived
///   read    framed request read off the wire
///   queue   PostMessage → GUI thread picked the request up (message-loop
///           starvation shows up here, and only here)
///   handler GUI thread inside the verb (terminal-lock waits show up here)
fn logPerf(
    self: *IpcServer,
    body: []const u8,
    accept_start: ?std.time.Instant,
    connected: ?std.time.Instant,
    posted: ?std.time.Instant,
    gui_start: ?std.time.Instant,
) void {
    _ = self;
    const now = std.time.Instant.now() catch return;
    const c = connected orelse return;
    const p = posted orelse return;
    const ms = struct {
        fn f(later: std.time.Instant, earlier: ?std.time.Instant) u64 {
            const e = earlier orelse return 0;
            return later.since(e) / std.time.ns_per_ms;
        }
    }.f;
    log.info(
        "ipcperf action={s} accept={d}ms read={d}ms queue={d}ms handler={d}ms",
        .{
            actionOf(body),
            ms(c, accept_start),
            ms(p, connected),
            if (gui_start) |g| ms(g, posted) else ms(now, posted),
            if (gui_start) |g| ms(now, g) else 0,
        },
    );
}

/// Cheap `"action":"<verb>"` scan for the perf line — the real parse happens
/// on the GUI thread and this must not allocate or duplicate it.
fn actionOf(body: []const u8) []const u8 {
    const key = "\"action\":\"";
    const start = std.mem.indexOf(u8, body, key) orelse return "?";
    const rest = body[start + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "?";
    return rest[0..end];
}

fn respondError(self: *IpcServer, conn: ipc_client.Conn, msg: []const u8) void {
    const json = std.fmt.allocPrint(
        self.alloc,
        "{{\"success\":false,\"error\":\"{s}\"}}",
        .{msg},
    ) catch return;
    defer self.alloc.free(json);
    self.writeFramed(conn, json);
}

fn writeFramed(self: *IpcServer, conn: ipc_client.Conn, json: []const u8) void {
    _ = self;
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @as(u32, @intCast(json.len))));
    conn.writeAll(&len_bytes) catch return;
    conn.writeAll(json) catch return;
}

// --- GUI-thread side ---------------------------------------------------------

/// Entered from msgWndProc (WM_APP_IPC): parse, dispatch, publish response.
/// Never leaves `pending.done` unset — the listener thread waits on it.
pub fn serveOnGuiThread(pending: *Pending) void {
    const self = pending.server;
    if (self.perf) pending.gui_start = std.time.Instant.now() catch null;
    defer pending.done.set();
    pending.response = IpcHandlers.dispatch(
        .{ .app = self.app, .alloc = self.alloc },
        pending.request_json,
    ) catch |err| response: {
        log.warn("IPC dispatch failed err={}", .{err});
        break :response null;
    };
}

/// Build an owner-only security descriptor via SDDL: protected DACL with a
/// single GENERIC_ALL ACE for the current user's SID. Caller LocalFrees the
/// result.
fn ownerOnlyDescriptor(alloc: Allocator) !*anyopaque {
    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) == 0)
        return error.TokenOpenFailed;
    defer windows.CloseHandle(token);

    var needed: windows.DWORD = 0;
    _ = GetTokenInformation(token, TokenUser, null, 0, &needed);
    if (needed == 0) return error.TokenInfoFailed;
    const buf = try alloc.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(@alignOf(TOKEN_USER)),
        needed,
    );
    defer alloc.free(buf);
    if (GetTokenInformation(token, TokenUser, buf.ptr, needed, &needed) == 0)
        return error.TokenInfoFailed;
    const user: *const TOKEN_USER = @ptrCast(buf.ptr);

    var sid_str: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(user.User.Sid, &sid_str) == 0)
        return error.SidConversionFailed;
    defer _ = LocalFree(sid_str);
    const sid = std.mem.span(sid_str.?);

    // D: DACL, P: protected (no inheritance), A: allow, GA: GENERIC_ALL.
    var sddl_buf: [128]u16 = undefined;
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(")");
    if (prefix.len + sid.len + suffix.len + 1 > sddl_buf.len)
        return error.SidConversionFailed;
    @memcpy(sddl_buf[0..prefix.len], prefix);
    @memcpy(sddl_buf[prefix.len..][0..sid.len], sid);
    @memcpy(sddl_buf[prefix.len + sid.len ..][0..suffix.len], suffix);
    sddl_buf[prefix.len + sid.len + suffix.len] = 0;
    const sddl: [*:0]const u16 = @ptrCast(&sddl_buf);

    var sd: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl,
        SDDL_REVISION_1,
        &sd,
        null,
    ) == 0) return error.DescriptorConversionFailed;
    return sd.?;
}
