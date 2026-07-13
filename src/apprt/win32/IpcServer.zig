//! IPC server for the win32 apprt: a named-pipe listener owned by the App
//! (docs/design/windows-parity-spec.md, "Architecture decisions"). The pipe
//! is created with an owner-only DACL and FILE_FLAG_FIRST_PIPE_INSTANCE, so
//! binding doubles as the single-instance lock: a second GUI launch fails to
//! bind, forwards a `new-window` request as a client, and exits.
//!
//! Connections are short-lived request/response (4-byte BE length + JSON,
//! both directions — the exact Mac wire protocol). Requests are serviced
//! serially on one listener thread; each request is marshaled to the GUI
//! thread via the App's message-only window (WM_APP_IPC + ResetEvent),
//! because all registry/window operations must run on the GUI thread.
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

/// The single pipe instance. Owning the name (first-instance flag) is the
/// single-instance lock for the whole app.
pipe: windows.HANDLE,

/// UTF-16 pipe path, kept for the shutdown dummy-connect.
path_w: [:0]u16,

thread: ?std.Thread = null,
shutdown: std.atomic.Value(bool) = .{ .raw = false },

/// Set by the listener as its very last statement, after which it can no
/// longer post marshal messages. deinit spins on this while draining
/// WM_APP_IPC so an in-flight request can't deadlock the join.
listener_exited: std.atomic.Value(bool) = .{ .raw = false },

/// One request in flight from the listener thread to the GUI thread.
pub const Pending = struct {
    server: *IpcServer,
    request_json: []const u8,
    /// Set by the GUI thread (allocated with server.alloc; listener frees).
    response: ?[]u8 = null,
    done: std.Thread.ResetEvent = .{},
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

    const pipe = windows.kernel32.CreateNamedPipeW(
        path_w.ptr,
        windows.PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
        windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE |
            windows.PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, // single instance; clients retry on PIPE_BUSY
        64 * 1024,
        64 * 1024,
        0,
        if (sd != null) &sa else null,
    );
    if (pipe == windows.INVALID_HANDLE_VALUE) {
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
    errdefer windows.CloseHandle(pipe);

    self.* = .{
        .app = app,
        .alloc = alloc,
        .pipe = pipe,
        .path_w = path_w,
    };

    self.thread = std.Thread.spawn(.{}, listen, .{self}) catch |err| {
        log.warn("IPC listener thread spawn failed err={}", .{err});
        return error.BindFailed;
    };
    log.info("IPC server listening on {s}", .{path});
}

/// Stop the listener and release the pipe. Runs on the GUI thread, before
/// the App destroys its message-only window.
pub fn deinit(self: *IpcServer) void {
    self.shutdown.store(true, .release);
    if (self.thread) |thread| {
        // Unblock a parked ConnectNamedPipe with a throwaway client connect.
        // If the listener is mid-request instead, this connect fails with
        // PIPE_BUSY, which is fine: the listener re-checks the flag between
        // requests.
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

        // The listener may be blocked on `Pending.done` for a request whose
        // WM_APP_IPC is sitting in our (no longer pumped) queue: keep
        // draining those until the listener provably can't post any more.
        while (!self.listener_exited.load(.acquire)) {
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
        thread.join();
        self.thread = null;
    }
    windows.CloseHandle(self.pipe);
    self.alloc.free(self.path_w);
}

/// Listener thread body: serve one framed request per connection, serially.
fn listen(self: *IpcServer) void {
    defer self.listener_exited.store(true, .release);
    while (true) {
        if (self.shutdown.load(.acquire)) return;
        if (ConnectNamedPipe(self.pipe, null) == 0) {
            switch (windows.GetLastError()) {
                // Client connected between CreateNamedPipe/Disconnect and
                // ConnectNamedPipe: the connection is fine, serve it.
                .PIPE_CONNECTED => {},
                else => |err| {
                    if (self.shutdown.load(.acquire)) return;
                    log.warn("ConnectNamedPipe failed err={}", .{err});
                    return;
                },
            }
        }
        if (self.shutdown.load(.acquire)) return;
        self.serveOne();
        _ = FlushAndDisconnect(self.pipe);
    }
}

fn FlushAndDisconnect(pipe: windows.HANDLE) bool {
    _ = windows.kernel32.FlushFileBuffers(pipe);
    return DisconnectNamedPipe(pipe) != 0;
}

/// Read one framed request from the connected client, marshal it to the GUI
/// thread, write the framed response. All failures are answered on the wire
/// when possible (matching the Mac server's error strings).
fn serveOne(self: *IpcServer) void {
    const conn: ipc_client.Conn = .{ .handle = self.pipe };

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
    pending.done.wait();

    const response = pending.response orelse {
        self.respondError(conn, "internal error");
        return;
    };
    defer self.alloc.free(response);
    self.writeFramed(conn, response);
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
