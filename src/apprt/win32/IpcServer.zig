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
const Surface = @import("Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree(Surface);
const w32 = @import("win32.zig");
const apprt = @import("../../apprt.zig");
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
    pending.response = self.dispatch(pending.request_json) catch |err| response: {
        log.warn("IPC dispatch failed err={}", .{err});
        break :response null;
    };
}

const Request = struct {
    action: []const u8,
    arguments: ?[]const []const u8 = null,
};

/// Dispatch one request on the GUI thread. Returns the response JSON
/// (allocated; the listener frees it). Error strings byte-match the Mac
/// server where the cases overlap.
fn dispatch(self: *IpcServer, request_json: []const u8) Allocator.Error!?[]u8 {
    const parsed = std.json.parseFromSlice(
        Request,
        self.alloc,
        request_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return try self.errorResponse("malformed JSON", .{});
    };
    defer parsed.deinit();
    const request = parsed.value;

    log.info("IPC: received action '{s}'", .{request.action});

    if (std.mem.eql(u8, request.action, "new-window")) {
        return try self.handleNewWindow(request);
    } else if (std.mem.eql(u8, request.action, "list")) {
        return try self.handleList(request);
    } else if (std.mem.eql(u8, request.action, "close")) {
        return try self.handleClose(request);
    }

    // Verbs the Mac server implements that are still pending on Windows
    // (each is its own task in the parity tracker).
    const known = [_][]const u8{
        "split",             "rename",    "rearrange",
        "read",              "send-keys", "set-state",
        "new-remote-window",
    };
    for (known) |k| {
        if (std.mem.eql(u8, request.action, k)) {
            return try self.errorResponse(
                "unimplemented action on Windows: {s}",
                .{request.action},
            );
        }
    }
    return try self.errorResponse("unknown action: {s}", .{request.action});
}

/// Flags shared by the window/pane verbs, parsed with the same prefix table
/// as the Mac server (unknown flags are ignored there too).
const VerbArgs = struct {
    target: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    title: ?[]const u8 = null,
    split_direction: ?[]const u8 = null,
    split_command: ?[]const u8 = null,
    name: ?[]const u8 = null,
    state: ?[]const u8 = null,
    no_activate: bool = false,
    env: []const Surface.Overrides.EnvVar = &.{},
    /// Trailing `-e` arguments: exec this argv directly, no shell wrap.
    e_args: []const [:0]const u8 = &.{},
};

fn parseVerbArgs(
    arena: Allocator,
    arguments: ?[]const []const u8,
) Allocator.Error!VerbArgs {
    var result: VerbArgs = .{};
    const args = arguments orelse return result;

    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    var e_args: std.ArrayList([:0]const u8) = .empty;
    var e_flag = false;

    for (args) |arg| {
        if (e_flag) {
            try e_args.append(arena, try arena.dupeZ(u8, arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "-e")) {
            e_flag = true;
        } else if (std.mem.eql(u8, arg, "--no-activate")) {
            result.no_activate = true;
        } else if (dropPrefix(arg, "--working-directory=")) |v| {
            result.working_directory = v;
        } else if (dropPrefix(arg, "--command=")) |v| {
            result.command = v;
        } else if (dropPrefix(arg, "--shell=")) |v| {
            result.shell = v;
        } else if (dropPrefix(arg, "--title=")) |v| {
            result.title = v;
        } else if (dropPrefix(arg, "--split=")) |v| {
            result.split_direction = v;
        } else if (dropPrefix(arg, "--direction=")) |v| {
            result.split_direction = v;
        } else if (dropPrefix(arg, "--split-command=")) |v| {
            result.split_command = v;
        } else if (dropPrefix(arg, "--target=")) |v| {
            result.target = v;
        } else if (dropPrefix(arg, "--name=")) |v| {
            result.name = v;
        } else if (dropPrefix(arg, "--state=")) |v| {
            result.state = v;
        } else if (dropPrefix(arg, "--env=")) |v| {
            if (std.mem.indexOfScalar(u8, v, '=')) |eq| {
                try env.append(arena, .{
                    .key = v[0..eq],
                    .value = v[eq + 1 ..],
                });
            }
        }
        // Remaining Mac flags (--color, --percent, --pane, --from-focused)
        // are accepted-and-ignored until their features land.
    }

    result.env = env.items;
    result.e_args = e_args.items;
    return result;
}

fn dropPrefix(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

/// Build the argv that runs `command` inside a shell, per the pinned
/// Windows table: pwsh/powershell → `-NoExit -Command`, cmd → `/K`,
/// anything else (git-bash etc.) → `-lic` (Mac behavior). Shell resolution:
/// `--shell` flag → `command-shell` config → cmd.exe.
fn wrapCommandArgv(
    self: *IpcServer,
    arena: Allocator,
    shell_flag: ?[]const u8,
    command: []const u8,
) Allocator.Error![]const [:0]const u8 {
    const shell = shell_flag orelse
        (self.app.config.@"command-shell" orelse "cmd.exe");

    var base = std.fs.path.basename(shell);
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];

    var argv: std.ArrayList([:0]const u8) = .empty;
    try argv.append(arena, try arena.dupeZ(u8, shell));
    if (std.ascii.eqlIgnoreCase(base, "pwsh") or
        std.ascii.eqlIgnoreCase(base, "powershell"))
    {
        try argv.append(arena, "-NoExit");
        try argv.append(arena, "-Command");
    } else if (std.ascii.eqlIgnoreCase(base, "cmd")) {
        try argv.append(arena, "/K");
    } else {
        try argv.append(arena, "-lic");
    }
    try argv.append(arena, try arena.dupeZ(u8, command));
    return argv.items;
}

extern "user32" fn IsIconic(hWnd: w32.HWND) callconv(.winapi) windows.BOOL;

/// Raise and focus the window that owns `entry` (and the pane itself for
/// pane targets).
fn focusTarget(entry: App.IpcTarget) void {
    const window = switch (entry) {
        .window => |w| w,
        .pane => |s| s.parent_window,
    };
    if (window.hwnd) |hwnd| {
        if (IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
        _ = w32.SetForegroundWindow(hwnd);
    }
    switch (entry) {
        .window => {},
        .pane => |s| if (s.hwnd) |h| {
            _ = w32.SetFocus(h);
        },
    }
}

fn handleNewWindow(self: *IpcServer, request: Request) Allocator.Error!?[]u8 {
    const app = self.app;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);

    // Idempotent: an existing live target is focused, not recreated.
    if (args.target) |target| {
        if (app.ipcLookup(target)) |entry| {
            if (!args.no_activate) focusTarget(entry);
            return try self.alloc.dupe(u8, "{\"success\":true}");
        }
    }

    // Environment for the first surface: --env flags plus the window/pane
    // name vars the Mac injects for named windows.
    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    try env.appendSlice(arena, args.env);
    if (args.target) |t| {
        try env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = t });
        try env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = t });
    }

    const overrides: Surface.Overrides = .{
        .command_argv = if (args.e_args.len > 0)
            args.e_args
        else if (args.command) |cmd|
            try self.wrapCommandArgv(arena, args.shell, cmd)
        else
            null,
        .working_directory = args.working_directory,
        .env = env.items,
    };

    const window = app.createWindow(.{
        .surface_overrides = &overrides,
        .ipc_name = args.target,
    }) catch |err| {
        log.warn("IPC new-window failed err={}", .{err});
        return try self.errorResponse("failed to create window", .{});
    };

    if (args.title) |title| window.setTitleOverride(title);
    if (args.no_activate) {
        // Window creation focused it within our app; at least don't keep it
        // raised over the previously-active window.
        if (window.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
        }
    } else if (window.hwnd) |hwnd| {
        _ = w32.SetForegroundWindow(hwnd);
    }

    // Inline split (`--split=<dir>`, `--split-command`, `--name`).
    if (args.split_direction) |dir_str| {
        const dir = parseSplitDirection(dir_str) orelse
            return try self.errorResponse("invalid split direction: {s}", .{dir_str});

        var split_env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
        if (args.target) |t| {
            try split_env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = t });
        }
        if (args.name) |n| {
            try split_env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = n });
        }
        const split_overrides: Surface.Overrides = .{
            .command_argv = if (args.split_command) |cmd|
                try self.wrapCommandArgv(arena, args.shell, cmd)
            else
                null,
            .env = split_env.items,
        };
        window.pending_surface_overrides = &split_overrides;
        defer window.pending_surface_overrides = null;
        const new_surface = window.newSplit(dir) catch |err| blk: {
            log.warn("IPC inline split failed err={}", .{err});
            break :blk null;
        };
        if (new_surface) |s| {
            if (args.name) |n| app.ipcRegister(n, .{ .pane = s }) catch {};
        }
    }

    return try self.alloc.dupe(u8, "{\"success\":true}");
}

fn handleClose(self: *IpcServer, request: Request) Allocator.Error!?[]u8 {
    const app = self.app;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try self.errorResponse("--target is required for +close", .{});

    // Idempotent: closing a target that's already gone succeeds silently.
    const entry = app.ipcLookup(target) orelse
        return try self.alloc.dupe(u8, "{\"success\":true}");

    switch (entry) {
        // Both paths close without confirmation (the CLI drives teardown;
        // matching the Mac server's withConfirmation:false /
        // closeWindowImmediately). Registry entries drop via ipcForget in
        // the destroy paths.
        .pane => |surface| surface.parent_window.closeSplitSurface(surface),
        .window => |window| window.close(),
    }

    return try self.alloc.dupe(u8, "{\"success\":true}");
}

fn parseSplitDirection(s: []const u8) ?SplitTree.Split.Direction {
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "up")) return .up;
    return null;
}

fn handleList(self: *IpcServer, request: Request) Allocator.Error!?[]u8 {
    _ = request;
    const app = self.app;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foreground = w32.GetForegroundWindow();

    var window_list: std.ArrayList(apprt.ipc.List.Window) = .empty;
    for (app.windows.items) |window| {
        // Quick terminals are not listable/addressable targets.
        if (window.is_quick_terminal) continue;
        const hwnd = window.hwnd orelse continue;

        var tabs: std.ArrayList(apprt.ipc.List.Tab) = .empty;
        for (0..window.tab_count) |i| {
            const tab_title = try utf16ToUtf8Arena(
                arena,
                window.tab_titles[i][0..window.tab_title_lens[i]],
            );
            const node = try self.buildNode(
                arena,
                &window.tab_trees[i],
                .root,
                window.tab_active_surface[i],
            );
            try tabs.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
                .title = tab_title,
                .index = @intCast(i),
                .selected = i == window.active_tab,
                .splits = node,
            });
        }

        var title_buf: [512]u16 = undefined;
        const title_len = w32.GetWindowTextW(hwnd, &title_buf, title_buf.len);
        const win_title = try utf16ToUtf8Arena(
            arena,
            title_buf[0..@intCast(@max(title_len, 0))],
        );

        try window_list.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{@intFromPtr(hwnd)}),
            .title = win_title,
            .target = window.ipc_name,
            .focused = foreground != null and foreground.? == hwnd,
            .tabs = tabs.items,
        });
    }

    const json = (apprt.ipc.List{ .windows = window_list.items }).serializeResponse(arena) catch
        return error.OutOfMemory;
    return try self.alloc.dupe(u8, json);
}

/// Recursively build the split-node model for one tree node. Every leaf is
/// auto-registered under its fallback name (the surface id), matching the
/// Mac server.
fn buildNode(
    self: *IpcServer,
    arena: Allocator,
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    active_surface: *Surface,
) Allocator.Error!*const apprt.ipc.List.Node {
    const node = try arena.create(apprt.ipc.List.Node);

    // An empty tree renders as the Mac server's placeholder leaf.
    if (tree.isEmpty()) {
        node.* = .{ .leaf = apprt.ipc.List.empty_terminal };
        return node;
    }

    switch (tree.nodes[handle.idx()]) {
        .leaf => |surface| {
            const id = try std.fmt.allocPrint(arena, "{d}", .{surface.core_surface.id});
            const name = self.app.ipcNameOf(.{ .pane = surface }) orelse name: {
                self.app.ipcRegister(id, .{ .pane = surface }) catch {};
                break :name id;
            };
            const pwd: []const u8 = pwd: {
                const copy = surface.core_surface.pwd(arena) catch break :pwd "";
                break :pwd copy orelse "";
            };
            node.* = .{
                .leaf = .{
                    .id = id,
                    .title = surface.getTitle() orelse "",
                    .working_directory = pwd,
                    // Foreground pid / tty name are not surfaced by the ConPTY
                    // backend yet; the Mac fills these from the surface model.
                    .pid = 0,
                    .tty = "",
                    .name = name,
                    .focused = surface == active_surface,
                    .exit_code = null,
                },
            };
        },
        .split => |split| {
            node.* = .{ .split = .{
                .direction = switch (split.layout) {
                    .horizontal => "horizontal",
                    .vertical => "vertical",
                },
                .ratio = @floatCast(split.ratio),
                .left = try self.buildNode(arena, tree, split.left, active_surface),
                .right = try self.buildNode(arena, tree, split.right, active_surface),
            } };
        },
    }
    return node;
}

fn utf16ToUtf8Arena(arena: Allocator, utf16: []const u16) Allocator.Error![]const u8 {
    return std.unicode.utf16LeToUtf8Alloc(arena, utf16) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "",
    };
}

fn errorResponse(
    self: *IpcServer,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
    defer self.alloc.free(msg);

    var out: std.Io.Writer.Allocating = .init(self.alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(false) catch break :write;
        jws.objectField("error") catch break :write;
        jws.write(msg) catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
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
