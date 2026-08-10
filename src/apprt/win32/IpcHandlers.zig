//! IPC verb handlers for the win32 apprt: everything that runs on the GUI
//! thread once IpcServer has marshaled a request over. Split from
//! IpcServer.zig (transport) so each file has one job. Handlers byte-match
//! the Mac server's semantics and error strings where the cases overlap
//! (macos/Sources/Features/IPC/IPCServer.swift).
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const App = @import("App.zig");
const agent_recovery = @import("agent_recovery.zig");
const ProcessTree = @import("ProcessTree.zig");
const provenance = @import("provenance.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const remote_connection = @import("../../remote/connection.zig");
const relay_account = @import("../../remote/relay_account.zig");
const Surface = @import("Surface.zig");
const CoreSurface = @import("../../Surface.zig");
const PaneView = @import("PaneView.zig");
const ViewerPane = @import("ViewerPane.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree(PaneView);
const w32 = @import("win32.zig");
const color_math = @import("color_math.zig");
const apprt = @import("../../apprt.zig");
const termio = @import("../../termio.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.win32_ipc);

/// What a handler needs from the server: the app (GUI-thread state) and
/// the response allocator (the listener thread frees responses with it).
pub const Context = struct {
    app: *App,
    alloc: Allocator,
};

const Request = struct {
    action: []const u8,
    arguments: ?[]const []const u8 = null,
};

/// Dispatch one request on the GUI thread. Returns the response JSON
/// (allocated; the listener frees it). Error strings byte-match the Mac
/// server where the cases overlap.
pub fn dispatch(ctx: Context, request_json: []const u8) Allocator.Error!?[]u8 {
    const parsed = std.json.parseFromSlice(
        Request,
        ctx.alloc,
        request_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return try errorResponse(ctx.alloc, "malformed JSON", .{});
    };
    defer parsed.deinit();
    const request = parsed.value;

    log.info("IPC: received action '{s}'", .{request.action});

    if (std.mem.eql(u8, request.action, "new-window")) {
        return try handleNewWindow(ctx, request);
    } else if (std.mem.eql(u8, request.action, "list")) {
        return try handleList(ctx, request);
    } else if (std.mem.eql(u8, request.action, "close")) {
        return try handleClose(ctx, request);
    } else if (std.mem.eql(u8, request.action, "split")) {
        return try handleSplit(ctx, request);
    } else if (std.mem.eql(u8, request.action, "rename")) {
        return try handleRename(ctx, request);
    } else if (std.mem.eql(u8, request.action, "send-keys")) {
        return try handleSendKeys(ctx, request);
    } else if (std.mem.eql(u8, request.action, "read")) {
        return try handleRead(ctx, request);
    } else if (std.mem.eql(u8, request.action, "set-state")) {
        return try handleSetState(ctx, request);
    } else if (std.mem.eql(u8, request.action, "rearrange")) {
        return try handleRearrange(ctx, request);
    } else if (std.mem.eql(u8, request.action, "new-remote-window")) {
        return try handleNewRemoteWindow(ctx, request);
    } else if (std.mem.eql(u8, request.action, "version")) {
        return try handleVersion(ctx);
    } else if (std.mem.eql(u8, request.action, "set-banner")) {
        return try handleSetBanner(ctx, request);
    } else if (std.mem.eql(u8, request.action, "reload")) {
        return try handleReload(ctx, request);
    }

    return try errorResponse(ctx.alloc, "unknown action: {s}", .{request.action});
}

// Pure verb-argument logic (flag parsing, shell wrap table, ConPTY input
// normalization, layout validation) lives in apprt/ipc/args.zig where it
// is unit tested in the none-runtime build.
const verb_args = apprt.ipc.args;

// The `+send-keys` `--segments=` wire format, shared with the CLI that
// writes it (src/cli/send_keys.zig) so encoder and decoder cannot drift.
const verb_segments = apprt.ipc.segments;
const VerbArgs = verb_args.VerbArgs;
const parseVerbArgs = verb_args.parseVerbArgs;
const dropPrefix = verb_args.dropPrefix;

/// `--view` on `+new-window`/`+split`. One answer left, and it is permanent:
/// an ambiguous `--view` + command is rejected the same way on both platforms.
/// The interim "file viewers are not supported here" refusal that used to sit
/// beside it is gone — T90e renders files, so both modes build a real pane.
///
/// Returns the error response to send, or null to carry on.
fn viewArgResponse(ctx: Context, args: VerbArgs) Allocator.Error!?[]u8 {
    if (verb_args.viewConflictsWithCommand(args))
        return try errorResponse(ctx.alloc, "{s}", .{verb_args.view_command_conflict_error});
    return null;
}

/// Shell resolution (`--shell` flag → `command-shell` config → cmd.exe),
/// then the pure per-flavor wrap table.
fn wrapCommandArgv(
    ctx: Context,
    arena: Allocator,
    shell_flag: ?[]const u8,
    command: []const u8,
) Allocator.Error![]const [:0]const u8 {
    const shell = shell_flag orelse
        (ctx.app.config.@"command-shell" orelse "cmd.exe");
    return verb_args.wrapShellCommandArgv(arena, shell, command);
}

/// The LOCAL-agent half of `wrapCommandArgv` (T468): the same per-flavor
/// keep-alive invocation, sent to the agent as `OPEN.argv` so it execs it
/// verbatim instead of synthesizing `<shell> /c <cmd>` — which exits the moment
/// the command returns, leaving "Process exited. Press any key" and a pane that
/// `+send-keys` cannot drive.
///
/// The keep-alive convention is argv-shaped on Windows (`cmd /K`, `pwsh -NoExit
/// -Command`), and argv cannot ride a command string the way POSIX's `<cmd>;
/// exec <shell> -li` does — so the agent-backed path cannot get it for free from
/// `OPEN.command` the way the Mac one does. Applying the LOCAL table here is
/// only correct because the session-persistence agent IS this machine; a
/// cross-machine agent keeps applying its own (those call sites pass no
/// `command_argv`).
///
/// Null for `-e` (verbatim argv is the whole point of `-e`; it is not a
/// `--command`) and for a pane with no command at all.
fn keepAliveArgv(
    ctx: Context,
    arena: Allocator,
    shell_flag: ?[]const u8,
    command: ?[]const u8,
) Allocator.Error!?[]const []const u8 {
    const cmd = nonEmpty(command orelse return null) orelse return null;
    const argv = try wrapCommandArgv(ctx, arena, shell_flag, cmd);
    // `[]const [:0]const u8` → `[]const []const u8`: the wire type is not
    // sentinel-terminated (the agent re-dupes every element anyway).
    const out = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| out[i] = a;
    return out;
}

extern "user32" fn IsIconic(hWnd: w32.HWND) callconv(.winapi) windows.BOOL;

/// The pane a target names: the pane itself, or a window's focused pane.
/// Null when the window has no tabs left.
fn targetPane(entry: App.IpcTarget) ?*PaneView {
    return switch (entry) {
        .pane => |p| p,
        .window => |w| if (w.tab_count == 0) null else w.tab_active_pane[w.active_tab],
    };
}

/// Raise and focus the window that owns `entry` (and the pane itself for
/// pane targets).
fn focusTarget(entry: App.IpcTarget) void {
    const window = switch (entry) {
        .window => |w| w,
        .pane => |p| p.parentWindow(),
    };
    if (window.hwnd) |hwnd| {
        if (IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
        _ = w32.SetForegroundWindow(hwnd);
    }
    switch (entry) {
        .window => {},
        .pane => |p| if (p.hwnd()) |h| {
            App.deferSetFocus(h); // T48
        },
    }
}

/// Resolve a `--color`/`--split-color` value to a color: `#rgb`/`#rrggbb`
/// hex or `random` (a dark muted color). Unparseable values are silently
/// ignored (Mac rule: `NSColor(hex:)` failing just skips the tint).
fn resolveColor(value: ?[]const u8) ?color_math.Rgb {
    const v = value orelse return null;
    if (std.mem.eql(u8, v, "random")) return color_math.randomDark(std.crypto.random);
    return color_math.parseHex(v);
}

fn handleNewWindow(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try parseVerbArgs(arena, request.arguments);

    // Before anything is created or focused (Mac checks here too,
    // IPCServer.swift:386 — ahead of its idempotent target focus).
    if (try viewArgResponse(ctx, args)) |response| return response;

    // `--from-focused` (T68): mirror the keyboard "New Window" action on the
    // focused window so a REMOTE parent's machine is inherited (the Mac
    // newWindowInheritingRemote analog — win32 re-dials the same agent).
    // Like the Mac, this path ignores `--target`/`--name` registration and
    // the inline-split flags.
    if (args.from_focused) {
        if (frontWindow(app)) |front| {
            if (front.remote_machine != null) {
                _ = app.openRemoteWindowFrom(front, .{
                    .working_directory = nonEmpty(args.working_directory),
                    .shell = nonEmpty(args.shell),
                    .command = nonEmpty(args.command),
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.DialFailed => return try errorResponse(
                        ctx.alloc,
                        "failed to reach the focused window's remote machine: the agent is not running or not reachable",
                        .{},
                    ),
                    error.CreateFailed => return try errorResponse(ctx.alloc, "failed to create window", .{}),
                };
                return try successResponse(ctx.alloc, "created", null);
            }
        }
        // Local (or no) parent: a normal local window; drop the flags the
        // Mac ignores for the inheriting case and fall through.
        args.target = null;
        args.name = null;
        args.split_direction = null;
        args.title = null;
    }

    // Idempotent: an existing live target is focused, not recreated. T135:
    // the reply says so (`outcome: focused` vs `created`), and when the
    // caller passed flags that only a create would honor, a `note` names
    // them — the CLI prints it to stderr so the drop is loud. Exit stays 0:
    // idempotency is the contract, silence was the defect.
    if (args.target) |target| {
        if (app.ipcLookup(target)) |entry| {
            if (!args.no_activate) focusTarget(entry);
            if (try verb_args.droppedOnExistingTarget(arena, args)) |dropped| {
                const note = try std.fmt.allocPrint(
                    arena,
                    "target '{s}' already exists; focused it. Ignored: {s}. +close it first to recreate.",
                    .{ target, dropped },
                );
                return try successResponse(ctx.alloc, "focused", note);
            }
            return try successResponse(ctx.alloc, "focused", null);
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

    // T374: `--view` makes the window's one pane a VIEWER, so none of the shell
    // plumbing below applies to it — no command to wrap, no agent session to
    // open, nothing to bake into an environment. It stays here rather than
    // returning early because everything AFTER the create is kind-agnostic:
    // `--title`, `--no-activate`, and the inline split (whose own pane is still
    // a terminal) all mean the same thing for a viewer window.
    // `--working-directory` rides along as the pane's ORIGIN DIRECTORY (T90h):
    // for a viewer it is not a spawn's cwd — there is no spawn — but the
    // provenance fallback for a pane whose location names no directory of its
    // own, and `+new-window` seeds it with the caller's cwd unconditionally.
    const viewer_open: ?ViewerPane.Open = if (args.view) |v|
        if (nonEmpty(v)) |location| .{
            .location = location,
            .origin_directory = nonEmpty(args.working_directory),
        } else null
    else
        null;

    // T99: with `session-persistence` on, route the first pane through the
    // local agent so its process survives this app (quit/crash/upgrade) and can
    // re-attach — exactly like the startup window. Resolve the shared
    // connection up-front (bounded + cached; the same call createWindow makes to
    // set `window.local_agent_conn` for later tabs/splits). A null result
    // (persistence off, or an unreachable/unspawnable agent) falls back to a
    // plain exec pane, so window creation never hangs on a broken agent.
    //
    // Resolved for a viewer window too: its FIRST pane needs no agent, but its
    // later tabs and splits are ordinary terminals and inherit the connection
    // `createWindow` records from this same call.
    const agent_conn: ?*remote_connection.Connection = if (app.config.@"session-persistence")
        app.local_agent.sharedConnection()
    else
        null;

    const overrides: Surface.Overrides = if (agent_conn) |conn| ov: {
        // Agent-backed: the command is a REMOTE-native string the agent's shell
        // runs (never locally shell-wrapped), and the cwd is a local path the
        // same-machine agent honors. The window/pane-name env rides the OPEN.
        const remote_command: ?[]const u8 = if (args.e_args.len > 0)
            try joinArgv(arena, args.e_args)
        else
            nonEmpty(args.command);
        break :ov .{
            .remote = .{
                .connection = conn,
                .working_directory = nonEmpty(args.working_directory),
                .shell = nonEmpty(args.shell),
                .command = remote_command,
                .command_argv = try keepAliveArgv(ctx, arena, args.shell, args.command),
                .local_agent = true,
            },
            .env = env.items,
        };
    } else .{
        .command_argv = if (args.e_args.len > 0)
            args.e_args
        else if (args.command) |cmd|
            try wrapCommandArgv(ctx, arena, args.shell, cmd)
        else
            null,
        .working_directory = args.working_directory,
        .env = env.items,
    };

    const window = app.createWindow(.{
        // A viewer first pane has no shell for these to configure; passing them
        // anyway would describe a spawn that is not happening.
        .surface_overrides = if (viewer_open != null) null else &overrides,
        .viewer_open = viewer_open,
        .ipc_name = args.target,
    }) catch |err| {
        log.warn("IPC new-window failed err={}", .{err});
        return try errorResponse(ctx.alloc, "failed to create window", .{});
    };

    // T92: an empty `--title=` means "no pin", not "pin empty".
    if (args.title) |title| {
        if (title.len > 0) window.setTitleOverride(title);
    }

    // `--color` (T67): tint the window's first surface — background +
    // contrast foreground + WCAG-adjusted palette (Mac applyColorScheme).
    if (resolveColor(args.color)) |tint| {
        if (window.tab_count > 0) {
            if (window.tab_active_pane[window.active_tab].surface()) |s|
                s.applyBackgroundTint(tint, true);
        }
    }

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
            return try errorResponse(ctx.alloc, "invalid split direction: {s}", .{dir_str});

        var split_env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
        if (args.target) |t| {
            try split_env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = t });
        }
        if (args.name) |n| {
            try split_env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = n });
        }
        // T99: the inline split inherits the window's agent-backing. Mirror
        // handleSplit — no explicit `--split-command` ⇒ a null baton so
        // newSplit's `buildRemoteInherit` injects the agent and inherits the
        // first pane's cwd; otherwise a `.remote{local_agent}` override carrying
        // the agent-native command plus the pane-name env.
        const split_cmd = nonEmpty(args.split_command);
        const split_overrides: ?Surface.Overrides = if (window.local_agent_conn) |conn| ov: {
            if (split_cmd == null) break :ov null;
            break :ov .{
                .remote = .{
                    .connection = conn,
                    .command = split_cmd,
                    .command_argv = try keepAliveArgv(ctx, arena, args.shell, args.split_command),
                    .local_agent = true,
                },
                .env = split_env.items,
            };
        } else .{
            .command_argv = if (args.split_command) |cmd|
                try wrapCommandArgv(ctx, arena, args.shell, cmd)
            else
                null,
            .env = split_env.items,
        };
        if (split_overrides) |*ov| window.pending_surface_overrides = ov;
        defer window.pending_surface_overrides = null;
        const new_surface = window.newSplit(dir) catch |err| blk: {
            log.warn("IPC inline split failed err={}", .{err});
            break :blk null;
        };
        if (new_surface) |s| {
            // `--split-color` (T67): explicit tint for the inline split
            // (overwrites the auto-shifted inheritance newSplitAt applied).
            if (resolveColor(args.split_color)) |tint| s.applyBackgroundTint(tint, true);
            if (args.name) |n| if (s.pane_view) |pv| app.ipcRegister(n, .{ .pane = pv }) catch {};
        }
    }

    return try successResponse(ctx.alloc, "created", null);
}

/// Open a remote-machine window, dialing the agent at `--host=<h> --port=<p>`
/// over TCP (T20 / Phase G) or through a rendezvous relay at
/// `--relay=<base> --device=<id> [--token=<tok>]` (T21b). Semantics mirror
/// the Mac server's handleNewRemoteWindow: validation error strings
/// byte-match; the relay path takes precedence when both are present; the
/// dial is synchronous ON THE GUI THREAD (bounded by the 10s HELLO handshake
/// deadline), exactly like the Mac menu/IPC path; `--name` registers the
/// window for later targeting.
///
/// Relay token tiers (T21a/T21b/T93): explicit `--token` wins (the CLI
/// already forwards its own GHOSTTY_RELAY_TOKEN env as `--token`), then the
/// signed-in account (its relay session token, renewed as needed — Mac
/// `RelayAccount.resolveToken()` parity), then this GUI process's
/// GHOSTTY_RELAY_TOKEN.
///
/// `--working-directory`/`--shell`/`--command` are REMOTE-native values
/// forwarded verbatim in the agent OPEN (empty ⇒ absent, like the Mac);
/// they are never wrapped by the local shell table — the agent applies its
/// own shell's convention.
fn handleNewRemoteWindow(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);

    // Relay path: --relay + --device dial through a rendezvous relay. Takes
    // precedence over the direct host:port path when both are present (Mac
    // rule; empty values are absent).
    const relay = nonEmpty(args.relay);
    const device = nonEmpty(args.device);
    const use_relay = relay != null and device != null;
    if (!use_relay) {
        const host = args.host orelse "";
        if (host.len == 0) {
            return try errorResponse(
                ctx.alloc,
                "--host is required (or use --relay + --device) for +new-remote-window",
                .{},
            );
        }
        if (args.port == 0) {
            return try errorResponse(
                ctx.alloc,
                "--port is required (or use --relay + --device) for +new-remote-window",
                .{},
            );
        }
    }

    // Dial the agent (TCP or relay) and open the window through the shared
    // open path (App.openRelayWindow / openDialedWindow — T22c decision 6, the
    // same path the machine chooser uses). The dial blocks on the GUI thread
    // until connected (≤10s HELLO deadline). Empty string ⇒ absent (the Mac
    // treats `--shell=` as nil so an empty value can never forward "").
    const opts: App.RemoteOpenOptions = .{
        .working_directory = nonEmpty(args.working_directory),
        .shell = nonEmpty(args.shell),
        .command = nonEmpty(args.command),
        .ipc_name = args.name,
        .title = args.title,
        .activate = !args.no_activate,
    };

    if (use_relay) {
        // Token tiers: explicit --token, then the signed-in account (relay
        // session token), then the GUI's env. A tokenless relay dial is a
        // guaranteed 401 — refuse BEFORE dialing (Mac rule).
        const token = nonEmpty(args.token) orelse resolveAccountToken(arena) orelse resolveEnvToken(arena) orelse {
            return try errorResponse(
                ctx.alloc,
                "not signed in: sign in from the machine chooser (ctrl+shift+n), pass --token=, or set GHOSTTY_RELAY_TOKEN to open relay windows",
                .{},
            );
        };
        _ = app.openRelayWindow(relay.?, device.?, token, opts) catch |err| switch (err) {
            error.DialFailed => return try errorResponse(
                ctx.alloc,
                "failed to reach {s} via relay {s}: the agent is not running or not reachable",
                .{ device.?, relay.? },
            ),
            error.CreateFailed => return try errorResponse(ctx.alloc, "failed to create window", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        };
    } else {
        const alloc = app.core_app.alloc;
        const host = args.host.?;
        const dialed = try alloc.create(tcp_dial.Dialed);
        dialed.* = tcp_dial.dial(alloc, host, args.port, .raw) catch |err| {
            log.warn(
                "IPC new-remote-window: dial failed host={s} port={d} err={}",
                .{ host, args.port, err },
            );
            alloc.destroy(dialed);
            return try errorResponse(
                ctx.alloc,
                "failed to reach {s}:{d}: the agent is not running or not reachable",
                .{ host, args.port },
            );
        };
        var tcp_opts = opts;
        tcp_opts.machine = .{ .tcp = .{ .host = host, .port = args.port } };
        _ = app.openDialedWindow(.{ .tcp = dialed }, tcp_opts) catch |err| switch (err) {
            error.CreateFailed => return try errorResponse(ctx.alloc, "failed to create window", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

/// Empty ⇒ null, so blank flag values are treated as absent.
fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len > 0) s else null;
}

/// Join a `-e arg...` argv into a single command line for a remote/agent shell,
/// which runs ONE command string rather than an argv (the agent applies its own
/// shell's convention). Space-separated; the values never contain embedded
/// quotes in practice. Null ⇒ no `-e` argv was given. Allocated in `arena`.
fn joinArgv(arena: Allocator, argv: []const []const u8) Allocator.Error!?[]const u8 {
    if (argv.len == 0) return null;
    var joined: std.ArrayList(u8) = .empty;
    for (argv, 0..) |a, i| {
        if (i > 0) try joined.append(arena, ' ');
        try joined.appendSlice(arena, a);
    }
    return joined.items;
}

/// The account tier of relay token resolution (T21a; brokered per T93): if an
/// account is signed in (`account.dat` exists), return its relay session
/// token — renewed (and rotated) at the stored relay when it nears expiry. A
/// missing account, a legacy pre-T93 store, or a refused renewal returns null
/// so resolution falls through to the env token (graceful — Mac
/// `resolveToken` behavior). Allocated on `arena`.
pub fn resolveAccountToken(arena: Allocator) ?[]const u8 {
    const path = relay_account.accountPath(arena) catch return null;
    if (!relay_account.isSignedIn(arena, path)) return null;

    return relay_account.resolveSessionToken(arena, path) catch |err| {
        switch (err) {
            error.Legacy => log.warn(
                "account store predates the brokered sign-in — sign in once from the machine chooser (ctrl+shift+n) to migrate",
                .{},
            ),
            else => log.warn("IPC new-remote-window: account session renew failed err={}", .{err}),
        }
        return null;
    };
}

/// The env tier of relay token resolution: `GHOSTTY_RELAY_TOKEN` (empty ⇒
/// null). Allocated on `arena`.
pub fn resolveEnvToken(arena: Allocator) ?[]const u8 {
    const tok = std.process.getEnvVarOwned(arena, "GHOSTTY_RELAY_TOKEN") catch return null;
    return nonEmpty(tok);
}

/// Combined relay bearer-token resolution shared by the `+new-remote-window`
/// verb and the machine chooser (T22c): the signed-in account first (its
/// relay session token, renewed as needed), then `GHOSTTY_RELAY_TOKEN`.
/// Null ⇒ no credential — the chooser shows an empty list + a sign-in hint,
/// never an error. (`--token` is a per-call override the IPC verb applies
/// ahead of this.) Allocated on `arena`.
pub fn resolveToken(arena: Allocator) ?[]const u8 {
    return resolveAccountToken(arena) orelse resolveEnvToken(arena);
}

fn handleSplit(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);

    // First thing, as on the Mac (IPCServer.swift:572).
    if (try viewArgResponse(ctx, args)) |response| return response;

    // Idempotent: an existing live pane under --name is focused, not
    // recreated.
    if (args.name) |name| {
        if (app.ipcLookup(name)) |entry| {
            switch (entry) {
                .pane => {
                    focusTarget(entry);
                    return try ctx.alloc.dupe(u8, "{\"success\":true}");
                },
                // A window under this name: fall through and let the later
                // registration no-op (existing registration wins).
                .window => {},
            }
        }
    }

    const ratio: f16 = if (args.percent) |percent| ratio: {
        if (percent < 1 or percent > 99) {
            return try errorResponse(
                ctx.alloc,
                "percent must be between 1 and 99, got {d}",
                .{percent},
            );
        }
        const r = @as(f16, @floatFromInt(100 - percent)) / 100.0;
        break :ratio @min(0.9, @max(0.1, r));
    } else 0.5;

    const dir_str = args.split_direction orelse "right";
    const direction = parseSplitDirection(dir_str) orelse
        return try errorResponse(ctx.alloc, "invalid direction: {s}", .{dir_str});

    // `--from-focused` (T68): mirror the keyboard split on the focused
    // window's active pane, passing NO overrides so remote inheritance
    // (same connection + parent command/cwd) is never suppressed (Mac
    // rule). Like the Mac, `--name`/tint plumbing is skipped — this
    // trigger is the inheriting case.
    if (args.from_focused) {
        const window = frontWindow(app) orelse
            return try errorResponse(ctx.alloc, "no window found for split", .{});
        if (window.tab_count == 0)
            return try errorResponse(ctx.alloc, "no surface to split", .{});
        const at = window.tab_active_pane[window.active_tab];
        _ = window.newSplitAt(at, direction, ratio) catch |err| {
            log.warn("IPC split --from-focused failed err={}", .{err});
            return try errorResponse(ctx.alloc, "failed to create split", .{});
        } orelse return try errorResponse(ctx.alloc, "failed to create split", .{});
        return try ctx.alloc.dupe(u8, "{\"success\":true}");
    }

    // Resolve where to split: --pane names the exact surface; --target
    // names a window (or a pane, whose window is used) and splits at its
    // active surface; neither → the foreground (else most recent) window.
    var window: *Window = undefined;
    var at: *PaneView = undefined;
    if (args.pane) |pane_name| {
        const entry = app.ipcLookup(pane_name) orelse
            return try errorResponse(ctx.alloc, "pane '{s}' not found", .{pane_name});
        switch (entry) {
            .pane => |pane| {
                at = pane;
                window = pane.parentWindow();
            },
            .window => return try errorResponse(ctx.alloc, "pane '{s}' not found", .{pane_name}),
        }
    } else if (args.target) |target| {
        const entry = app.ipcLookup(target) orelse
            return try errorResponse(ctx.alloc, "target '{s}' not found in registry", .{target});
        window = switch (entry) {
            .window => |w| w,
            .pane => |pane| pane.parentWindow(),
        };
        if (window.tab_count == 0)
            return try errorResponse(ctx.alloc, "target '{s}' has no surface to split", .{target});
        at = window.tab_active_pane[window.active_tab];
    } else {
        window = frontWindow(app) orelse
            return try errorResponse(ctx.alloc, "no window found for split", .{});
        if (window.tab_count == 0)
            return try errorResponse(ctx.alloc, "no surface to split", .{});
        at = window.tab_active_pane[window.active_tab];
    }

    // `--view` (T374): a VIEWER split. Returns here rather than falling through
    // like `+new-window` does, because everything below this line describes a
    // shell — the overrides, the remote/agent inheritance, the background tint
    // a terminal reads against — and a viewer has none of it.
    if (args.view) |view| {
        if (nonEmpty(view)) |location| {
            // `--working-directory` is the ORIGIN DIRECTORY here, not a cwd:
            // `+split --view=` seeds it with the caller's cwd for exactly this
            // (`cli/split.zig:seedViewWorkingDirectory`), and a viewer has no
            // shell to hand a cwd to.
            const pane = window.newViewerSplitAt(at, direction, ratio, .{
                .location = location,
                .origin_directory = nonEmpty(args.working_directory),
            }) catch |err| {
                log.warn("IPC viewer split failed err={}", .{err});
                return try errorResponse(ctx.alloc, "failed to create split", .{});
            } orelse return try errorResponse(ctx.alloc, "failed to create split", .{});
            if (args.name) |name| app.ipcRegister(name, .{ .pane = pane }) catch {};
            return try ctx.alloc.dupe(u8, "{\"success\":true}");
        }
    }

    // Surface overrides for the new pane.
    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    try env.appendSlice(arena, args.env);
    if (window.ipc_name) |wn| {
        try env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = wn });
    }
    if (args.name) |n| {
        try env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = n });
    }
    const command = args.split_command orelse args.command;

    // T68: a split in a REMOTE window opens a fresh session on the same
    // machine/connection, never a local ConPTY pane. Explicit
    // `--command`/`--working-directory` are REMOTE-native (never wrapped by
    // the local shell table — the agent applies its own shell's convention);
    // a `-e` argv is joined into one command line for the agent's shell.
    // With no explicit values we pass NO overrides at all, so newSplitAt's
    // inheritance (parent pane's command + cwd) applies, like the Mac.
    const remote_command: ?[]const u8 = if (args.e_args.len > 0)
        try joinArgv(arena, args.e_args)
    else
        nonEmpty(command);

    const overrides: ?Surface.Overrides = if (window.remote_dialed) |dialed| ov: {
        if (remote_command == null and nonEmpty(args.working_directory) == null)
            break :ov null; // full inheritance in newSplitAt
        break :ov .{
            .remote = .{
                .connection = dialed.conn(),
                .working_directory = nonEmpty(args.working_directory),
                .shell = nonEmpty(args.shell),
                .command = remote_command,
            },
            .env = env.items,
        };
    } else if (window.local_agent_conn) |conn| ov: {
        // T99: a split in a LOCAL persistence window opens a fresh AGENT session
        // (survives the app), never a plain ConPTY — mirrors the remote_dialed
        // branch. No explicit command/cwd ⇒ a null baton so newSplitAt's
        // `buildRemoteInherit` injects the agent and inherits the split-parent
        // pane's cwd; otherwise a `.remote{local_agent}` override carrying the
        // agent-native command + the name env.
        if (remote_command == null and nonEmpty(args.working_directory) == null)
            break :ov null;
        break :ov .{
            .remote = .{
                .connection = conn,
                .working_directory = nonEmpty(args.working_directory),
                .shell = nonEmpty(args.shell),
                .command = remote_command,
                .command_argv = try keepAliveArgv(ctx, arena, args.shell, command),
                .local_agent = true,
            },
            .env = env.items,
        };
    } else .{
        .command_argv = if (args.e_args.len > 0)
            args.e_args
        else if (command) |cmd|
            try wrapCommandArgv(ctx, arena, args.shell, cmd)
        else
            null,
        .working_directory = args.working_directory,
        .env = env.items,
    };

    if (overrides) |*ov| window.pending_surface_overrides = ov;
    defer window.pending_surface_overrides = null;
    const new_surface = window.newSplitAt(at, direction, ratio) catch |err| {
        log.warn("IPC split failed err={}", .{err});
        return try errorResponse(ctx.alloc, "failed to create split", .{});
    } orelse return try errorResponse(ctx.alloc, "failed to create split", .{});

    // `--color` (T67): explicit tint for the new pane — bg + contrast fg +
    // adjusted palette (overwrites newSplitAt's auto-shifted inheritance).
    if (resolveColor(args.color)) |tint| new_surface.applyBackgroundTint(tint, true);

    if (args.name) |name| {
        if (new_surface.pane_view) |pv| app.ipcRegister(name, .{ .pane = pv }) catch {};
    }

    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

fn handleRead(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const name = args.name orelse
        return try errorResponse(ctx.alloc, "--name is required for +read", .{});
    const line_count: usize = if (args.lines) |l|
        (if (l > 0) @intCast(l) else 50)
    else
        50;

    const entry = ctx.app.ipcLookup(name) orelse
        return try errorResponse(ctx.alloc, "pane '{s}' not found in registry", .{name});
    const pane = targetPane(entry) orelse
        return try errorResponse(ctx.alloc, "pane '{s}' is no longer alive", .{name});
    const surface = pane.surface() orelse
        return try errorResponse(ctx.alloc, "{s} is a viewer pane, not a terminal", .{name});
    // T181: each remaining failure names a DIFFERENT state, because a caller
    // that cannot tell them apart cannot react to any of them. `core_surface_
    // ready` covers two: a surface that once worked and is being torn down,
    // and one whose terminal never came up at all (`core_surface_initialized`
    // is set together with `ready` at the end of init, so it stays false when
    // init failed). "It died" and "it never started" are different bugs.
    if (!surface.core_surface_ready) {
        return if (surface.core_surface_initialized)
            try errorResponse(ctx.alloc, "pane '{s}' is no longer alive", .{name})
        else
            try errorResponse(
                ctx.alloc,
                "pane '{s}' is not readable: its terminal never finished starting up",
                .{name},
            );
    }

    // Dump the whole screen (scrollback + active) as plain text, matching
    // the Mac's full-SCREEN ghostty_surface_read_text selection.
    const core = &surface.core_surface;
    // GHOZTTY_PERF (T111b): split the handler into LOCK WAIT vs work under the
    // lock. `+read` of a flooded pane is the sharpest probe of contention on
    // that pane's renderer mutex, and the two halves have opposite fixes.
    const perf = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
    const t_enter: ?std.time.Instant =
        if (perf) (std.time.Instant.now() catch null) else null;
    var t_locked: ?std.time.Instant = null;
    const dump: ?[]const u8 = dump: {
        // PRIORITY (T114): this runs ON the GUI thread, so losing races here
        // freezes the window. Measured at 23628 ms of lock wait for 45 ms of
        // work before the fairness ticket existed.
        core.renderer_state.lockPriority();
        if (perf) t_locked = std.time.Instant.now() catch null;
        defer core.renderer_state.unlockPriority();
        const pages = &core.io.terminal.screens.active.pages;
        const tl = pages.getTopLeft(.screen);
        const br = pages.getBottomRight(.screen) orelse break :dump null;
        const sel = terminal.Selection.init(tl, br, false);
        const text = core.dumpTextLocked(arena, sel) catch break :dump null;
        break :dump text.text;
    };
    if (perf) perf: {
        const now = std.time.Instant.now() catch break :perf;
        const enter = t_enter orelse break :perf;
        const locked = t_locked orelse break :perf;
        log.info("ipcperf read pane={s} lockwait={d}ms dump={d}ms", .{
            name,
            locked.since(enter) / std.time.ns_per_ms,
            now.since(locked) / std.time.ns_per_ms,
        });
    }

    // A null dump is a genuine internal failure — the screen could not be
    // serialized at all (OOM, or no pages, which should not happen). An EMPTY
    // dump is not: see below.
    const full = dump orelse
        return try errorResponse(ctx.alloc, "failed to read terminal content from '{s}'", .{name});

    // Last N lines, by the shared rule (T181). An empty result is returned as
    // success with empty text: a pane that has printed nothing yet — the
    // normal state of every pane for the first fraction of a second of its
    // life, and the permanent state of a pane running something silent — is
    // readable, and "" is the truthful answer. Reporting it as a failure made
    // a lost race indistinguishable from a missing or wedged pane, which is
    // how an agent ends up recording "no output" as a verdict.
    const result = apprt.ipc.read_tail.tail(full, line_count);

    // {"success":true,"data":{"text":<result>}}
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("text") catch break :write;
        jws.write(result) catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

fn handleRearrange(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const layout_json = args.layout orelse
        return try errorResponse(ctx.alloc, "--layout is required for +rearrange", .{});

    const layout = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        layout_json,
        .{},
    ) catch return try errorResponse(ctx.alloc, "invalid layout JSON", .{});

    // Validate shape + collect pane names (Mac collectPaneNames semantics).
    var names: std.ArrayList([]const u8) = .empty;
    if (try verb_args.validateLayout(arena, layout, &names)) |msg|
        return try errorResponse(ctx.alloc, "{s}", .{msg});
    if (names.items.len == 0)
        return try errorResponse(ctx.alloc, "layout must contain at least one pane", .{});
    if (verb_args.firstDuplicate(names.items)) |dupe|
        return try errorResponse(ctx.alloc, "duplicate pane name in layout: '{s}'", .{dupe});

    // Resolve the window, then every pane against its ACTIVE tab's tree.
    const window: *Window = if (args.target) |target| window: {
        const entry = app.ipcLookup(target) orelse
            return try errorResponse(ctx.alloc, "target window '{s}' not found", .{target});
        break :window switch (entry) {
            .window => |w| w,
            .pane => |pane| pane.parentWindow(),
        };
    } else frontWindow(app) orelse
        return try errorResponse(ctx.alloc, "no focused window found", .{});
    if (window.tab_count == 0)
        return try errorResponse(ctx.alloc, "no focused window found", .{});
    const tab = window.active_tab;
    const tree = &window.tab_trees[tab];

    var surfaces: std.StringHashMapUnmanaged(*PaneView) = .empty;
    for (names.items) |name| {
        const entry = app.ipcLookup(name) orelse
            return try errorResponse(ctx.alloc, "pane '{s}' not found in registry", .{name});
        const pane = switch (entry) {
            .pane => |p| p,
            .window => return try errorResponse(ctx.alloc, "pane '{s}' not found in registry", .{name}),
        };
        const in_tree = in_tree: {
            var it = tree.iterator();
            while (it.next()) |view_entry| {
                if (view_entry.view == pane) break :in_tree true;
            }
            break :in_tree false;
        };
        if (!in_tree)
            return try errorResponse(ctx.alloc, "pane '{s}' is not in the target window", .{name});
        try surfaces.put(arena, name, pane);
    }

    // T128: the session ids the NEW layout still references. Collected here,
    // where allocating is still free to fail, and consumed below in the
    // infallible stretch around the swap. Read-only — nothing is marked yet.
    var surviving_ids: std.ArrayList([]const u8) = .empty;
    {
        var kept = surfaces.valueIterator();
        while (kept.next()) |pane_ptr| {
            const s = pane_ptr.*.surface() orelse continue;
            if (!s.core_surface_ready) continue;
            if (s.core_surface.remoteSessionId()) |sid| try surviving_ids.append(arena, sid);
        }
    }

    // Build the replacement tree in its own arena (SplitTree owns it).
    const gpa = ctx.alloc;
    var tree_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer tree_arena.deinit();
    var nodes: std.ArrayList(SplitTree.Node) = .empty;
    _ = try buildLayoutNode(tree_arena.allocator(), &nodes, layout, &surfaces);
    const final_nodes = try tree_arena.allocator().dupe(SplitTree.Node, nodes.items);

    // Allocate the success response up front: past this point the swap
    // must not hit a fallible path while errdefer would free the arena the
    // new tree now owns.
    const response = try ctx.alloc.dupe(u8, "{\"success\":true}");

    // Take ownership references on the kept panes BEFORE dropping the
    // old tree, so they can't hit refcount 0 during the swap.
    var kept_it = surfaces.valueIterator();
    while (kept_it.next()) |pane_ptr| {
        _ = pane_ptr.*.ref(gpa) catch {};
    }

    // T128: a pane the new layout OMITS is destroyed by the swap below — a
    // close written as a layout — so its agent session must END rather than
    // detach, exactly as `+close` on that pane would. Without this the child
    // kept running under the agent forever, pinned and unreachable, with no
    // pane anywhere that could reach it.
    //
    // Marked per leaf through `agent_recovery.closesDepartingLeaf`, so the
    // `e65cfa4d5` invariant holds: a session the new tree still references is
    // never ended. Nothing here can fail, and it runs after the response has
    // been allocated, so no error path can leave a still-in-tree pane wearing a
    // close intent it never earned.
    {
        var it = tree.iterator();
        while (it.next()) |view_entry| {
            const view = view_entry.view;
            const in_new_tree = in_new_tree: {
                var kept = surfaces.valueIterator();
                while (kept.next()) |pane_ptr| {
                    if (pane_ptr.* == view) break :in_new_tree true;
                }
                break :in_new_tree false;
            };
            const sid: ?[]const u8 = if (view.surface()) |s|
                (if (s.core_surface_ready) s.core_surface.remoteSessionId() else null)
            else
                null;
            if (agent_recovery.closesDepartingLeaf(in_new_tree, sid, surviving_ids.items))
                view.setSessionCloseIntent(true);
        }
    }

    // Swap trees. Old-tree deinit unrefs every old view: panes not in the
    // new layout reach refcount 0 and are destroyed (their registry names
    // drop via ipcForget in Surface.deinit).
    const current_focus = window.tab_active_pane[tab];
    var old_tree = window.tab_trees[tab];
    window.tab_trees[tab] = .{
        .arena = tree_arena,
        .nodes = final_nodes,
        .zoomed = null,
    };
    old_tree.deinit();

    // Focus: keep the focused pane if it survived, else the first leaf.
    const focus: *PaneView = focus: {
        var it = window.tab_trees[tab].iterator();
        var first: ?*PaneView = null;
        while (it.next()) |view_entry| {
            if (first == null) first = view_entry.view;
            if (view_entry.view == current_focus) break :focus current_focus;
        }
        break :focus first.?; // validated non-empty layout above
    };
    window.tab_active_pane[tab] = focus;
    window.heroOnTreeChanged(tab);
    window.layoutSplits();
    if (focus.hwnd()) |h| App.deferSetFocus(h); // T48
    window.updateWindowTitle();
    // T110: the whole tree (topology AND every split ratio) just changed —
    // re-persist, else a restore rebuilds the PRE-rearrange shape.
    app.markLayoutDirty();

    return response;
}

/// Append the nodes for `layout` (validated by verb_args.validateLayout)
/// preorder, so the root lands at index 0. Returns the node's handle.
fn buildLayoutNode(
    arena: Allocator,
    nodes: *std.ArrayList(SplitTree.Node),
    node: std.json.Value,
    surfaces: *const std.StringHashMapUnmanaged(*PaneView),
) Allocator.Error!SplitTree.Node.Handle {
    const handle: SplitTree.Node.Handle = @enumFromInt(nodes.items.len);
    try nodes.append(arena, undefined);
    const obj = node.object;

    if (obj.get("pane")) |pane| {
        nodes.items[handle.idx()] = .{ .leaf = surfaces.get(pane.string).? };
        return handle;
    }

    // Ratio arrives as a percent (default 50), clamped like the Mac.
    const ratio_percent: f64 = switch (obj.get("ratio") orelse std.json.Value{ .float = 50 }) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => 50,
    };
    const ratio: f16 = @floatCast(@min(0.9, @max(0.1, ratio_percent / 100.0)));
    const layout: SplitTree.Split.Layout = if (std.ascii.eqlIgnoreCase(
        obj.get("direction").?.string,
        "horizontal",
    )) .horizontal else .vertical;

    const left = try buildLayoutNode(arena, nodes, obj.get("left").?, surfaces);
    const right = try buildLayoutNode(arena, nodes, obj.get("right").?, surfaces);
    nodes.items[handle.idx()] = .{ .split = .{
        .layout = layout,
        .ratio = ratio,
        .left = left,
        .right = right,
    } };
    return handle;
}

fn handleSetState(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try errorResponse(ctx.alloc, "--target is required for +set-state", .{});
    const state_str = args.state orelse
        return try errorResponse(ctx.alloc, "--state is required for +set-state", .{});

    const state: terminal.osc.Command.ActivityState = state: {
        if (std.mem.eql(u8, state_str, "idle")) break :state .idle;
        if (std.mem.eql(u8, state_str, "busy")) break :state .busy;
        if (std.mem.eql(u8, state_str, "needs_input")) break :state .needs_input;
        return try errorResponse(
            ctx.alloc,
            "invalid state '{s}': must be idle, busy, or needs_input",
            .{state_str},
        );
    };

    const entry = ctx.app.ipcLookup(target) orelse
        return try errorResponse(ctx.alloc, "target '{s}' not found in registry", .{target});

    // Pane targets set just that pane; window targets set every pane in
    // the window (Mac handleSetState semantics).
    switch (entry) {
        .pane => |pane| {
            const surface = pane.surface() orelse
                return try errorResponse(ctx.alloc, "{s} is a viewer pane, not a terminal", .{target});
            surface.activity_state = state;
            surface.parent_window.updateWindowTitle();
        },
        .window => |window| {
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |view_entry| {
                    const surface = view_entry.view.surface() orelse continue;
                    surface.activity_state = state;
                }
            }
            window.updateWindowTitle();
        },
    }

    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

/// `+set-banner` (T35): set or clear the sticky banner of a named pane or
/// window. Banners are per-pane; a window target applies to its focused
/// pane (Mac handleSetBanner semantics).
fn handleSetBanner(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseSetBannerArgs(arena, request.arguments);
    const target = args.target orelse
        return try errorResponse(ctx.alloc, "--target is required for +set-banner", .{});

    const entry = ctx.app.ipcLookup(target) orelse
        return try errorResponse(ctx.alloc, "target '{s}' not found in registry", .{target});

    const pane = targetPane(entry) orelse
        return try errorResponse(ctx.alloc, "target '{s}' has no focused pane", .{target});
    const surface = pane.surface() orelse
        return try errorResponse(ctx.alloc, "{s} is a viewer pane, not a terminal", .{target});

    surface.setPaneBanner(if (args.clear) null else args.text);
    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

/// `+reload` (T390): reload a named VIEWER pane's content in place. Website
/// viewers re-fetch from origin bypassing caches; file viewers re-render
/// preserving scroll. A window target reloads its focused pane.
///
/// The two terminal refusals are Mac's `handleReload` strings and they are
/// DIFFERENT from each other on purpose: naming a terminal pane is a mistake
/// about that pane, while naming a window whose focused pane happens to be a
/// terminal is a mistake about which pane has focus, and the fix for each is
/// not the same. Neither is the `is a viewer pane, not a terminal` string the
/// terminal-only verbs use — that one points the opposite way.
fn handleReload(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try errorResponse(ctx.alloc, "--target is required for +reload", .{});

    const entry = ctx.app.ipcLookup(target) orelse
        return try errorResponse(ctx.alloc, "target '{s}' not found in registry", .{target});

    const view = switch (entry) {
        .pane => |pane| pane.viewer() orelse return try errorResponse(
            ctx.alloc,
            "target '{s}' is a terminal pane, nothing to reload",
            .{target},
        ),
        .window => w: {
            const pane = targetPane(entry) orelse return try errorResponse(
                ctx.alloc,
                "target '{s}' is no longer alive",
                .{target},
            );
            break :w pane.viewer() orelse return try errorResponse(
                ctx.alloc,
                "focused pane of '{s}' is a terminal pane, nothing to reload",
                .{target},
            );
        },
    };

    view.reloadContent();
    log.info("IPC: reloaded viewer '{s}'", .{target});
    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

fn handleRename(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try errorResponse(ctx.alloc, "--target is required for +rename", .{});
    const title = args.title orelse
        return try errorResponse(ctx.alloc, "--title is required for +rename", .{});

    const entry = ctx.app.ipcLookup(target) orelse
        return try errorResponse(ctx.alloc, "target '{s}' not found in registry", .{target});
    const window = switch (entry) {
        .window => |w| w,
        .pane => |pane| pane.parentWindow(),
    };

    // titleOverride semantics: the override wins over terminal-reported
    // titles until cleared (Mac BaseTerminalController.titleOverride).
    // T92: `--title=""` CLEARS the pin (Mac fixed the same in 9c7665354)
    // instead of pinning an empty string.
    window.setTitleOverride(if (title.len == 0) null else title);
    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

/// The bytes of one `+send-keys` run as they should reach the ConPTY, owned by
/// the caller (T661).
///
/// Three cases, and the shape of the answer is the whole point:
///
///   * NOT resolved — a CLI old enough that a bare `\n` meant Enter. Rewrite
///     every newline to CR exactly as this server always did, whatever the
///     pane is running. Nothing else can be inferred about those bytes.
///   * a `.key` run — a keypress the CLI already spelled as its terminal byte.
///     Verbatim; there is no newline in it to decide about.
///   * a `.text` run — pasted content, so it follows the terminal-wide paste
///     convention `input.paste.encode` implements: a program that asked for
///     bracketed paste understands a newline as a line break in the content
///     and gets it verbatim, while one that did not gets LF mapped to CR the
///     way xterm has always done it.
///
/// That last split is what makes this parity rather than a Windows quirk. On a
/// POSIX pty an unframed LF is a line terminator for a shell, so macOS needs
/// no mapping to run `a` then `b`; conhost's VT input translation SWALLOWS a
/// bare LF, so without the mapping `+send-keys "echo A\necho B\n"` reaches
/// cmd.exe as `echo Aecho B` — measured, 2026-08-10. Mapping it restores the
/// behavior a Mac user sees, while a TUI's composer still receives the literal
/// line break main's contract promises it.
fn prepareSendKeysRun(
    alloc: Allocator,
    surface: *CoreSurface,
    bytes: []const u8,
    kind: verb_segments.Kind,
    resolved: bool,
) Allocator.Error![]u8 {
    if (!resolved) return try verb_args.normalizeConptyInput(alloc, bytes);
    if (kind == .text and !surface.pasteIsBracketed())
        return try verb_args.normalizeConptyInput(alloc, bytes);
    return try alloc.dupe(u8, bytes);
}

fn handleSendKeys(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    // The CLI resolves all key notation (C-x, Enter, \n escapes) before
    // sending; the server receives `--target=` and raw `--keys=` bytes and
    // just writes them to the pane's PTY (Mac writePtyRaw semantics).
    //
    // `--segments=` rides ALONGSIDE `--keys=` when the send mixes text with
    // keys, carrying where the argument boundaries were. With it we can frame
    // the text runs as a bracketed paste and write the key runs bare, which
    // is what makes the trailing `Enter` of `"some message" Enter` submit
    // instead of landing in the composer as a pasted newline (T428). Without
    // it — an older CLI, or a send with nothing to disambiguate — the flat
    // payload is written exactly as it always was.
    //
    // `--keys-resolved=1` (T661) says the CLI already spelled every keypress
    // as the byte a terminal sends for it, so every LF still in a text run is
    // CONTENT — an interior line break, or a `--keys-file=`'s own trailing
    // newline — and only the paste convention may touch it. Absent, the
    // request came from a CLI old enough that a bare `\n` did mean Enter and
    // is normalized exactly as it always was. `prepareSendKeysRun` above owns
    // both cases; nothing here writes bytes it did not return.
    var target: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var segments_value: ?[]const u8 = null;
    var resolved = false;
    if (request.arguments) |arguments| {
        for (arguments) |arg| {
            if (dropPrefix(arg, "--target=")) |v| {
                target = v;
            } else if (dropPrefix(arg, verb_segments.prefix)) |v| {
                segments_value = v;
            } else if (dropPrefix(arg, verb_args.keys_resolved_prefix)) |v| {
                resolved = verb_args.keysResolvedValue(v);
            } else if (dropPrefix(arg, "--keys=")) |v| {
                text = v;
            }
        }
    }
    const target_name = target orelse
        return try errorResponse(ctx.alloc, "--target is required for +send-keys", .{});
    const bytes = text orelse
        return try errorResponse(ctx.alloc, "text is required for +send-keys", .{});
    if (bytes.len == 0)
        return try errorResponse(ctx.alloc, "text is required for +send-keys", .{});

    const entry = ctx.app.ipcLookup(target_name) orelse
        return try errorResponse(ctx.alloc, "target '{s}' not found", .{target_name});
    const pane = targetPane(entry) orelse
        return try errorResponse(ctx.alloc, "target '{s}' is no longer alive", .{target_name});
    const surface = pane.surface() orelse
        return try errorResponse(ctx.alloc, "{s} is a viewer pane, not a terminal", .{target_name});
    // T181: same split as `+read` — a pane that died and a pane whose terminal
    // never came up are different bugs, and the `/reset-context` helper aims
    // `+send-keys` at a freshly created pane, so it is a caller that cares.
    if (!surface.core_surface_ready) {
        return if (surface.core_surface_initialized)
            try errorResponse(ctx.alloc, "target '{s}' is no longer alive", .{target_name})
        else
            try errorResponse(
                ctx.alloc,
                "target '{s}' is not writable: its terminal never finished starting up",
                .{target_name},
            );
    }

    // Segmented send: one write per run, framed by kind. A `--segments=` we
    // cannot parse is not a reason to fail the request — the same bytes are
    // in `--keys=`, so fall through and lose only the framing.
    if (segments_value) |value| decode: {
        const runs = verb_segments.decode(ctx.alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => {
                log.warn("+send-keys: ignoring malformed --segments=, sending flat", .{});
                break :decode;
            },
        };
        defer verb_segments.freeSegments(ctx.alloc, runs);
        if (runs.len == 0) break :decode;

        for (runs) |run| {
            if (run.bytes.len == 0) continue;
            const run_bytes = try prepareSendKeysRun(
                ctx.alloc,
                &surface.core_surface,
                run.bytes,
                run.kind,
                resolved,
            );
            defer ctx.alloc.free(run_bytes);
            const written = switch (run.kind) {
                .text => surface.core_surface.writePtyBracketed(run_bytes),
                .key => surface.core_surface.writePtyRaw(run_bytes),
            };
            written catch return try errorResponse(ctx.alloc, "failed to queue input", .{});
        }

        return try ctx.alloc.dupe(u8, "{\"success\":true}");
    }

    // No `--segments=`, so the kind is unknown — but the rule above does not
    // need it. A flat payload is all text or all keys, and a key run from a
    // resolved CLI is already CR with no LF for either branch to touch, so
    // calling it text is right for both of the things it can be.
    const normalized = try prepareSendKeysRun(
        ctx.alloc,
        &surface.core_surface,
        bytes,
        .text,
        resolved,
    );
    defer ctx.alloc.free(normalized);

    const write_req = termio.Message.WriteReq.init(ctx.alloc, normalized) catch
        return try errorResponse(ctx.alloc, "failed to queue input", .{});
    surface.core_surface.io.queueMessage(switch (write_req) {
        .small => |v| .{ .write_small = v },
        .stable => |v| .{ .write_stable = v },
        .alloc => |v| .{ .write_alloc = v },
    }, .unlocked);

    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

/// The window the user is most plausibly working in: the foreground window
/// if it is one of ours, else the most recently created one.
fn frontWindow(app: *App) ?*Window {
    const foreground = w32.GetForegroundWindow();
    for (app.windows.items) |window| {
        if (window.is_quick_terminal) continue;
        if (window.hwnd != null and foreground != null and window.hwnd.? == foreground.?)
            return window;
    }
    var i = app.windows.items.len;
    while (i > 0) {
        i -= 1;
        const window = app.windows.items[i];
        if (!window.is_quick_terminal) return window;
    }
    return null;
}

fn handleClose(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try errorResponse(ctx.alloc, "--target is required for +close", .{});

    // Idempotent: closing a target that's already gone succeeds silently.
    const entry = app.ipcLookup(target) orelse
        return try ctx.alloc.dupe(u8, "{\"success\":true}");

    switch (entry) {
        // Both paths close without confirmation (the CLI drives teardown;
        // matching the Mac server's withConfirmation:false /
        // closeWindowImmediately). Registry entries drop via ipcForget in
        // the destroy paths.
        .pane => |pane| pane.parentWindow().closeSplitPane(pane),
        .window => |window| window.close(),
    }

    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

fn parseSplitDirection(s: []const u8) ?SplitTree.Split.Direction {
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "up")) return .up;
    return null;
}

/// `version` (T52): build provenance of THIS instance, so any pane can
/// answer "which build is this window running?" (`ghoztty +version` shows
/// it as the "Running Instance" section).
fn handleVersion(ctx: Context) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prov = try provenance.collect(arena);

    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("version") catch break :write;
        jws.write(prov.version) catch break :write;
        jws.objectField("commit") catch break :write;
        jws.write(prov.commit) catch break :write;
        jws.objectField("mode") catch break :write;
        jws.write(prov.mode) catch break :write;
        jws.objectField("runtime") catch break :write;
        jws.write(prov.runtime) catch break :write;
        jws.objectField("update_check") catch break :write;
        jws.write(prov.update_check) catch break :write;
        jws.objectField("exe") catch break :write;
        jws.write(prov.exe) catch break :write;
        jws.objectField("exe_modified") catch break :write;
        jws.write(prov.exe_modified) catch break :write;
        jws.objectField("pid") catch break :write;
        jws.write(prov.pid) catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

fn handleList(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);

    // `--pid=<pid>`: resolve the pane whose shell is an ancestor of the
    // given process (the Windows equivalent of the Mac's `--tty` — panes
    // have no tty here). Answers with data.match = the pane's name.
    if (args.pid) |query_pid| {
        var pid_map = try ProcessTree.snapshot(arena);
        for (app.windows.items) |window| {
            if (window.is_quick_terminal) continue;
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    // A viewer runs no shell, so it can never be the pane a
                    // pid lives in.
                    const surface = entry.view.surface() orelse continue;
                    const shell_pid = surfaceShellPid(surface);
                    if (shell_pid == 0) continue;
                    if (!ProcessTree.isAncestor(&pid_map, shell_pid, query_pid)) continue;
                    const name = app.ipcNameOf(.{ .pane = entry.view }) orelse name: {
                        // Register the fallback name so the returned value is
                        // immediately usable as a target, matching buildNode.
                        const id = try arena.dupe(u8, entry.view.paneId());
                        app.ipcRegister(id, .{ .pane = entry.view }) catch {};
                        break :name id;
                    };
                    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
                    errdefer out.deinit();
                    var jws: std.json.Stringify = .{ .writer = &out.writer };
                    write: {
                        jws.beginObject() catch break :write;
                        jws.objectField("success") catch break :write;
                        jws.write(true) catch break :write;
                        jws.objectField("data") catch break :write;
                        jws.beginObject() catch break :write;
                        jws.objectField("match") catch break :write;
                        jws.write(name) catch break :write;
                        jws.endObject() catch break :write;
                        jws.endObject() catch break :write;
                        return try out.toOwnedSlice();
                    }
                    return error.OutOfMemory;
                }
            }
        }
        // T153: name the better route in the failure. A pane whose shell pid
        // is unknown (a cross-machine pane, a surface still starting up) can
        // never match, so a process inside one gets this error through no
        // fault of its own — and $GHOZTTY_PANE_ID is baked into every pane's
        // env precisely so it never needs pid ancestry to name itself.
        return try errorResponse(
            ctx.alloc,
            "no pane found for pid {d}: no pane's shell is an ancestor of that " ++
                "process (panes with no known shell pid cannot match). From inside " ++
                "a pane, $GHOZTTY_PANE_ID names the pane directly.",
            .{query_pid},
        );
    }

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
            const node = try buildNode(
                ctx,
                arena,
                &window.tab_trees[i],
                .root,
                window.tab_active_pane[i],
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

    const prov = try provenance.collect(arena);
    const json = (apprt.ipc.List{
        .windows = window_list.items,
        .build = .{
            .version = prov.version,
            .commit = prov.commit,
            .mode = prov.mode,
            .runtime = prov.runtime,
            .update_check = prov.update_check,
            .exe = prov.exe,
            .exe_modified = prov.exe_modified,
            .pid = prov.pid,
        },
    }).serializeResponse(arena) catch
        return error.OutOfMemory;
    return try ctx.alloc.dupe(u8, json);
}

/// Recursively build the split-node model for one tree node. Every leaf is
/// auto-registered under its fallback name (the surface id), matching the
/// Mac server.
fn buildNode(
    ctx: Context,
    arena: Allocator,
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    active_pane: *PaneView,
) Allocator.Error!*const apprt.ipc.List.Node {
    const node = try arena.create(apprt.ipc.List.Node);

    // An empty tree renders as the Mac server's placeholder leaf.
    if (tree.isEmpty()) {
        node.* = .{ .leaf = apprt.ipc.List.empty_terminal };
        return node;
    }

    switch (tree.nodes[handle.idx()]) {
        .leaf => |pane| {
            // A viewer leaf reports the Mac's additive `type`/`url` shape and
            // none of the terminal fields — it has no shell, no pwd, and no
            // banner (CLAUDE.md: `+list` marks viewer panes with a `view:`
            // prefix; JSON `"type": "viewer"` plus `"url"`).
            const surface = pane.surface() orelse {
                const vid = try arena.dupe(u8, pane.paneId());
                const vname = ctx.app.ipcNameOf(.{ .pane = pane }) orelse name: {
                    ctx.app.ipcRegister(vid, .{ .pane = pane }) catch {};
                    break :name vid;
                };
                const viewer = pane.viewer().?;
                node.* = .{ .leaf = .{
                    .id = vid,
                    .title = viewer.title orelse "",
                    .working_directory = "",
                    .pid = 0,
                    .tty = "",
                    .name = vname,
                    .focused = pane == active_pane,
                    .exit_code = null,
                    .pane_type = "viewer",
                    .url = if (viewer.location) |loc| try arena.dupe(u8, loc) else null,
                } };
                return node;
            };
            // T113: the leaf `id` is the pane's stable ghoztty-owned id, the
            // same value its processes see as `$GHOZTTY_PANE_ID` and the same
            // shape the Mac reports (`pane.id.uuidString`). It used to be the
            // decimal `core_surface.id`, which changed on every re-attach and
            // matched nothing in the pane's environment.
            const id = try arena.dupe(u8, surface.paneId());
            const name = ctx.app.ipcNameOf(.{ .pane = pane }) orelse name: {
                ctx.app.ipcRegister(id, .{ .pane = pane }) catch {};
                break :name id;
            };
            // T111b: read the pane's CACHED working directory. This used to
            // call `core_surface.pwd()`, which takes that pane's renderer
            // mutex — under a flood the IO thread holds it nearly
            // continuously, so `+list`, the liveness probe every automation
            // bar here is written against, was the one call that queued
            // behind the flood (one handler measured at 29.3 s). Core pushes
            // every change to the cache as a `.pwd` action, so the only
            // value the cache can miss is the initial cwd termio sets at
            // startup with no action: the first `+list` to see a pane seeds
            // that, and no `+list` after it takes a terminal lock at all.
            const pwd: []const u8 = pwd: {
                // T185: a shell that never reports OSC 7 (cmd.exe) leaves
                // the cache frozen at its STARTING directory — ask the OS
                // for the shell process's real cwd instead, which tracks
                // the user's `cd`s. Null (shell reports OSC 7, no pid, or
                // read failure) falls through to the cached path. This is
                // two bounded syscall reads with no ghoztty lock, so the
                // T111b "no terminal mutex in +list" rule holds.
                if (surface.livePwd(arena)) |live| break :pwd live;
                if (surface.pwd) |cached| break :pwd cached;
                // Cache miss: this is the ONLY path in `+list` that can touch
                // a terminal lock, so GHOZTTY_PERF names the leaf and times
                // it — a miss that repeats every call is the whole bug back.
                const perf = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
                const t0: ?std.time.Instant =
                    if (perf) (std.time.Instant.now() catch null) else null;
                const copy = surface.core_surface.pwd(arena) catch null;
                if (perf) perf: {
                    const now = std.time.Instant.now() catch break :perf;
                    const start = t0 orelse break :perf;
                    log.info("ipcperf list pwd-miss name={s} ms={d} got={s}", .{
                        name,
                        now.since(start) / std.time.ns_per_ms,
                        if (copy != null) "yes" else "no",
                    });
                }
                // Seed even when the terminal has NO pwd, or the miss repeats
                // forever: a pane launched without a working directory (every
                // `+split` that doesn't pass one) never gets a terminal pwd,
                // and re-asking put `+list` right back on that pane's mutex —
                // measured at 183/298/535/584 ms per call on a flooded pane
                // and, under the section-E double storm, a 68 s handler.
                // "No pwd" is a permanent answer, not a not-yet: the initial
                // pwd is set synchronously by `Termio.init` →
                // `backend.initTerminal`, so it is already there (or already
                // absent) before `core_surface_ready`, and every later change
                // arrives as a `.pwd` action.
                surface.setPwd(copy orelse "");
                break :pwd surface.pwd orelse "";
            };
            node.* = .{
                .leaf = .{
                    .id = id,
                    .title = surface.getTitle() orelse "",
                    .working_directory = pwd,
                    // The shell's process id. There is no tty name on
                    // Windows (ConPTY); the Mac reports /dev/ttysNNN here.
                    .pid = @intCast(surfaceShellPid(surface)),
                    .tty = "",
                    .name = name,
                    .focused = pane == active_pane,
                    .exit_code = null,
                    .background_tint = if (surface.background_tint) |tint| tint: {
                        const buf = try arena.alloc(u8, 7);
                        break :tint color_math.hexString(tint, buf[0..7]);
                    } else null,
                    .banner = if (surface.banner_text) |t|
                        try arena.dupe(u8, t)
                    else
                        null,
                    // T332: the agent session this pane is bound to — the join
                    // key against `+sessions --json`. Lock-free read (the
                    // backend publishes the id atomically), duped because the
                    // borrow must not outlive the call; null for a plain
                    // local ConPTY pane, so the field is omitted there.
                    .session_id = if (surface.core_surface.remoteSessionId()) |sid|
                        try arena.dupe(u8, sid)
                    else
                        null,
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
                .left = try buildNode(ctx, arena, tree, split.left, active_pane),
                .right = try buildNode(ctx, arena, tree, split.right, active_pane),
            } };
        },
    }
    return node;
}

/// The pane's shell process id, or 0 when unavailable. Lives on the Surface
/// (`Surface.shellPid`) because the close-confirmation path needs the same
/// answer; this used to be a private copy here that returned 0 for EVERY
/// remote pane, which with session-persistence on (the default) is every local
/// pane — so `+list --pid` could not find a pane it was run from inside.
fn surfaceShellPid(surface: *Surface) u32 {
    return surface.shellPid();
}

test {
    _ = ProcessTree;
}

fn utf16ToUtf8Arena(arena: Allocator, utf16: []const u16) Allocator.Error![]const u8 {
    return std.unicode.utf16LeToUtf8Alloc(arena, utf16) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "",
    };
}

/// T135: `+new-window`'s success reply carries an `outcome` ("created" or
/// "focused") and, when the idempotent focus dropped caller flags, a `note`
/// the CLI prints to stderr. Both fields are additive: an older CLI parses
/// with ignore_unknown_fields and sees the same `success` it always did.
fn successResponse(
    alloc: Allocator,
    outcome: []const u8,
    note: ?[]const u8,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("outcome") catch break :write;
        jws.write(outcome) catch break :write;
        if (note) |n| {
            jws.objectField("note") catch break :write;
            jws.write(n) catch break :write;
        }
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

fn errorResponse(
    alloc: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);

    var out: std.Io.Writer.Allocating = .init(alloc);
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
