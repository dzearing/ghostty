//! T71: Claude Code integration setup — the Windows port of
//! macos/Sources/Features/Setup/ClaudeCodeIntegration.swift +
//! AppDelegate+Setup.swift. Detects the `claude` CLI, and on first run
//! offers to install the ghoztty plugin (`claude plugin marketplace add`
//! + `claude plugin install`); the command palette's "Install Claude Code
//! Integration" entry runs the same flow on demand.
//!
//! Threading: detection and the CLI runs happen on detached background
//! threads (each `claude` invocation can take seconds); results are
//! marshalled to the GUI thread via WM_APP_CLAUDE_* posted to the
//! message-only window, where the T80 ConfirmDialog shows the prompt or
//! outcome. Pure decision logic (step parsing, outcome merge, state file
//! grammar) lives in claude_setup.zig with unit tests in both lanes.
//!
//! First-run gating mirrors PathInstaller (T70): only the canonical
//! install (%LOCALAPPDATA%\Programs\Ghoztty) prompts, so dev builds and
//! portable unpacks never nag. Test hooks: GHOZTTY_CLAUDE_SETUP
//! (`0`/`off` disables, `force` skips the location gate),
//! GHOZTTY_CLAUDE_EXE (claude path override; a nonexistent path
//! simulates "not installed"), GHOZTTY_CLAUDE_STATE_DIR (answer-file
//! dir), GHOZTTY_CLAUDE_PLUGINS_JSON (installed-plugins registry
//! override). The answer persists in <state dir>\claude_setup as
//! "accepted"/"declined" — declining is remembered.
const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const setup = @import("claude_setup.zig");
const path_env = @import("../../os/path_env.zig");

const log = std.log.scoped(.win32_claude);

/// Posted by the first-run check thread when the prompt should be shown.
/// No payload.
pub const WM_APP_CLAUDE_PROMPT: u32 = w32.WM_APP + 7;

/// Posted by an install thread when the CLI runs finished. wparam is a
/// heap *Done owned by the handler.
pub const WM_APP_CLAUDE_DONE: u32 = w32.WM_APP + 8;

/// Who kicked off the install: the first-run prompt stays silent on
/// success (Mac parity — first launch stays quiet), the palette always
/// reports the outcome.
pub const Source = enum { first_run, palette };

pub const Done = struct {
    outcome: setup.Outcome,
    source: Source,
    /// Failure detail (tail of the CLI output), owned by this struct.
    detail: []const u8,
};

/// At most one install runs at a time; a second request while one is in
/// flight is dropped (the CLI flow is idempotent, re-running from the
/// palette after it finishes reports "Already Set Up").
var install_running: std.atomic.Value(bool) = .init(false);

/// Launch-time check on a detached thread: decide whether to show the
/// one-time first-run prompt. Never blocks startup.
pub fn checkOnLaunchAsync(app: *App) void {
    const thread = std.Thread.spawn(.{}, firstRunCheck, .{app}) catch |err| {
        log.warn("claude setup: check thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn firstRunCheck(app: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (!setupEnabled(arena)) return;
    if (readState(arena) != .unanswered) return;
    if (findClaude(arena) == null) {
        // No claude on this box: leave the prompt unburned so installing
        // claude later still gets the one-time offer.
        log.debug("claude setup: claude CLI not found; not prompting", .{});
        return;
    }

    // A ghoztty plugin already installed (any marketplace) means there is
    // nothing to offer; remember that silently.
    if (pluginsRegistryText(arena)) |json| {
        if (setup.hasGhozttyPlugin(json)) {
            writeState(arena, .accepted);
            return;
        }
    }

    // Let the first window appear and settle before dialoging over it
    // (the Mac flow waits 2s after launch).
    std.Thread.sleep(1 * std.time.ns_per_s);

    const hwnd = app.msg_hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_CLAUDE_PROMPT, 0, 0);
}

/// GUI thread (msgWndProc): show the one-time first-run prompt.
pub fn showFirstRunPrompt(app: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The palette flow may have answered while the check thread slept.
    if (readState(arena) != .unanswered) return;

    // Mark answered BEFORE showing so a crash mid-dialog can never turn
    // into a nag on every launch (Mac sets promptAnswered pre-runModal).
    writeState(arena, .declined);

    const owner: ?*@import("Window.zig") = if (app.windows.items.len > 0)
        app.windows.items[0]
    else
        null;
    const refocus: ?w32.HWND = if (owner) |win|
        (if (win.getActiveSurface()) |s| s.hwnd else null)
    else
        null;

    const result = ConfirmDialog.show(
        app,
        if (owner) |win| win.hwnd else null,
        if (owner) |win| win.scale else 1.0,
        refocus,
        .{
            .title = std.unicode.utf8ToUtf16LeStringLiteral("Set Up Claude Code Integration?"),
            .text = std.unicode.utf8ToUtf16LeStringLiteral(
                "Ghoztty can install its Claude Code plugin so agents can\n" ++
                    "open windows, create splits, and read terminal output.\n\n" ++
                    "This runs: claude plugin install " ++ setup.plugin,
            ),
            .icon = .info,
            .default_cancel = false,
            .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Set Up"),
            .cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Not Now"),
        },
    );
    if (result != .ok) return;

    writeState(arena, .accepted);
    installAsync(app, .first_run);
}

/// Kick off the marketplace-add + plugin-install CLI flow on a detached
/// thread. Safe to call from the GUI thread (palette entry) or the
/// first-run prompt.
pub fn installAsync(app: *App, source: Source) void {
    if (install_running.swap(true, .acq_rel)) {
        log.info("claude setup: install already running; ignoring", .{});
        return;
    }
    const thread = std.Thread.spawn(.{}, installThread, .{ app, source }) catch |err| {
        install_running.store(false, .release);
        log.warn("claude setup: install thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn installThread(app: *App, source: Source) void {
    defer install_running.store(false, .release);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = install(arena);

    const alloc = app.core_app.alloc;
    const done = alloc.create(Done) catch return;
    done.* = .{
        .outcome = result.outcome,
        .source = source,
        .detail = alloc.dupe(u8, result.detail) catch "",
    };

    const hwnd = app.msg_hwnd orelse {
        freeDone(app, done);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_CLAUDE_DONE, @intFromPtr(done), 0) == 0) {
        freeDone(app, done);
    }
}

fn freeDone(app: *App, done: *Done) void {
    const alloc = app.core_app.alloc;
    if (done.detail.len > 0) alloc.free(done.detail);
    alloc.destroy(done);
}

/// GUI thread (msgWndProc): report an install outcome. Owns `done`.
pub fn onDone(app: *App, done: *Done) void {
    defer freeDone(app, done);

    var arena_state = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (done.outcome) {
        .installed, .already_installed => {
            // However the install was reached, the question is settled.
            writeState(arena, .accepted);
        },
        .claude_not_found, .failed => {},
    }

    // First-run success stays silent so the first launch is quiet; every
    // palette outcome and any failure is reported (Mac parity).
    const report = switch (done.outcome) {
        .installed, .already_installed => done.source == .palette,
        .claude_not_found => done.source == .palette,
        .failed => true,
    };
    if (!report) return;

    const title: [*:0]const u16 = switch (done.outcome) {
        .installed => std.unicode.utf8ToUtf16LeStringLiteral("Claude Code Integration Ready"),
        .already_installed => std.unicode.utf8ToUtf16LeStringLiteral("Already Set Up"),
        .claude_not_found => std.unicode.utf8ToUtf16LeStringLiteral("Claude Code Not Found"),
        .failed => std.unicode.utf8ToUtf16LeStringLiteral("Claude Code Setup Failed"),
    };
    const icon: ConfirmDialog.Icon = if (done.outcome == .failed) .warning else .info;
    const text_w: [:0]const u16 = switch (done.outcome) {
        .installed => std.unicode.utf8ToUtf16LeStringLiteral(
            "The Ghoztty plugin is installed in Claude Code.",
        ),
        .already_installed => std.unicode.utf8ToUtf16LeStringLiteral(
            "The Ghoztty plugin is already installed in Claude Code.",
        ),
        .claude_not_found => std.unicode.utf8ToUtf16LeStringLiteral(
            "This sets up the Ghoztty plugin for Claude Code.\n" ++
                "Install Claude Code on this PC, then run this again.",
        ),
        .failed => blk: {
            const detail = if (done.detail.len > 0)
                done.detail
            else
                "Claude Code did not respond.";
            break :blk std.unicode.utf8ToUtf16LeAllocZ(arena, detail) catch
                std.unicode.utf8ToUtf16LeStringLiteral("Claude Code did not respond.");
        },
    };

    const owner: ?*@import("Window.zig") = if (app.windows.items.len > 0)
        app.windows.items[0]
    else
        null;
    const refocus: ?w32.HWND = if (owner) |win|
        (if (win.getActiveSurface()) |s| s.hwnd else null)
    else
        null;
    _ = ConfirmDialog.show(
        app,
        if (owner) |win| win.hwnd else null,
        if (owner) |win| win.scale else 1.0,
        refocus,
        .{
            .title = title,
            .text = text_w,
            .style = .ok_only,
            .icon = icon,
        },
    );
}

const InstallResult = struct {
    outcome: setup.Outcome,
    detail: []const u8 = "",
};

/// Blocking: runs the two `claude plugin` commands. Background thread only.
fn install(arena: std.mem.Allocator) InstallResult {
    const claude = findClaude(arena) orelse
        return .{ .outcome = .claude_not_found };

    const add = runClaude(
        arena,
        claude,
        &.{ "plugin", "marketplace", "add", setup.marketplace },
    );
    if (!add.step.ok) return .{ .outcome = .failed, .detail = add.detail };

    const inst = runClaude(
        arena,
        claude,
        &.{ "plugin", "install", setup.plugin },
    );
    if (!inst.step.ok) return .{ .outcome = .failed, .detail = inst.detail };

    return .{ .outcome = setup.mergeOutcome(add.step.already, inst.step.already) };
}

const RunResult = struct {
    step: setup.Step,
    detail: []const u8,
};

/// Run `claude <args...>` hidden (no console flash from the GUI process)
/// and classify the result. Zig's Child spawns .cmd/.bat shims via
/// cmd.exe itself, so npm installs work as well as the native claude.exe.
fn runClaude(
    arena: std.mem.Allocator,
    claude: []const u8,
    args: []const []const u8,
) RunResult {
    var argv = std.ArrayList([]const u8).initCapacity(arena, args.len + 1) catch
        return .{ .step = .{ .ok = false, .already = false }, .detail = "out of memory" };
    argv.appendAssumeCapacity(claude);
    argv.appendSliceAssumeCapacity(args);

    var child = std.process.Child.init(argv.items, arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;

    child.spawn() catch |err| {
        log.warn("claude setup: spawn failed: {}", .{err});
        return .{
            .step = .{ .ok = false, .already = false },
            .detail = "Claude Code could not be started.",
        };
    };
    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    child.collectOutput(arena, &stdout, &stderr, 512 * 1024) catch |err| {
        _ = child.kill() catch {};
        log.warn("claude setup: output collection failed: {}", .{err});
        return .{
            .step = .{ .ok = false, .already = false },
            .detail = "Claude Code did not respond.",
        };
    };
    const term = child.wait() catch |err| {
        log.warn("claude setup: wait failed: {}", .{err});
        return .{
            .step = .{ .ok = false, .already = false },
            .detail = "Claude Code did not respond.",
        };
    };

    const exit_ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    const combined = std.mem.concat(
        arena,
        u8,
        &.{ stdout.items, "\n", stderr.items },
    ) catch stdout.items;
    const step = setup.stepResult(exit_ok, combined);
    log.info("claude {s}: exit_ok={} already={}", .{
        args[args.len - 1],
        exit_ok,
        step.already,
    });
    return .{ .step = step, .detail = setup.detailTail(combined, 300) };
}

/// Find the claude CLI: env override, then the process PATH, then the
/// well-known install locations (the Mac findClaude, Windows-flavored).
pub fn findClaude(arena: std.mem.Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(arena, "GHOZTTY_CLAUDE_EXE") catch null) |override| {
        if (override.len == 0) return null;
        return if (fileExists(override)) override else null;
    }

    const exts = [_][]const u8{ ".exe", ".cmd", ".bat" };

    if (std.process.getEnvVarOwned(arena, "PATH") catch null) |path_value| {
        var it = std.mem.splitScalar(u8, path_value, ';');
        while (it.next()) |entry| {
            const dir = path_env.normalize(entry);
            if (dir.len == 0) continue;
            for (exts) |ext| {
                const candidate = std.mem.concat(
                    arena,
                    u8,
                    &.{ dir, "\\claude", ext },
                ) catch continue;
                if (fileExists(candidate)) return candidate;
            }
        }
    }

    // Common install locations in case the process PATH misses them:
    // the native installer and an npm global install.
    if (std.process.getEnvVarOwned(arena, "USERPROFILE") catch null) |home| {
        for ([_][]const u8{ "\\.local\\bin\\claude.exe", "\\.claude\\local\\claude.exe" }) |rel| {
            const candidate = std.mem.concat(arena, u8, &.{ home, rel }) catch continue;
            if (fileExists(candidate)) return candidate;
        }
    }
    if (std.process.getEnvVarOwned(arena, "APPDATA") catch null) |appdata| {
        const candidate = std.mem.concat(arena, u8, &.{ appdata, "\\npm\\claude.cmd" }) catch
            return null;
        if (fileExists(candidate)) return candidate;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// GHOZTTY_CLAUDE_SETUP + install-location gate (see module docs).
fn setupEnabled(arena: std.mem.Allocator) bool {
    const env: ?[]const u8 =
        std.process.getEnvVarOwned(arena, "GHOZTTY_CLAUDE_SETUP") catch null;
    if (env) |v| {
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return false;
        if (std.ascii.eqlIgnoreCase(v, "force")) return true;
    }

    const exe_dir = std.fs.selfExeDirPathAlloc(arena) catch return false;
    const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return false;
    const canonical = std.fs.path.join(
        arena,
        &.{ local, "Programs", "Ghoztty" },
    ) catch return false;
    return path_env.eqlDir(exe_dir, canonical);
}

fn statePath(arena: std.mem.Allocator) ?[]const u8 {
    const dir = std.process.getEnvVarOwned(arena, "GHOZTTY_CLAUDE_STATE_DIR") catch
        blk: {
            const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return null;
            break :blk std.fs.path.join(arena, &.{ local, "ghoztty" }) catch return null;
        };
    return std.fs.path.join(arena, &.{ dir, "claude_setup" }) catch null;
}

fn readState(arena: std.mem.Allocator) setup.State {
    const path = statePath(arena) orelse return .unanswered;
    const f = std.fs.cwd().openFile(path, .{}) catch return .unanswered;
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = f.readAll(&buf) catch 0;
    return setup.parseState(buf[0..n]);
}

fn writeState(arena: std.mem.Allocator, state: setup.State) void {
    const path = statePath(arena) orelse return;
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        log.warn("claude setup: state write failed: {}", .{err});
        return;
    };
    defer f.close();
    f.writeAll(setup.stateText(state)) catch {};
}

/// The installed-plugins registry JSON, or null if unreadable (treated as
/// "nothing installed" — worst case the idempotent prompt shows once).
fn pluginsRegistryText(arena: std.mem.Allocator) ?[]const u8 {
    const path = std.process.getEnvVarOwned(arena, "GHOZTTY_CLAUDE_PLUGINS_JSON") catch
        blk: {
            const home = std.process.getEnvVarOwned(arena, "USERPROFILE") catch return null;
            break :blk std.fs.path.join(
                arena,
                &.{ home, ".claude", "plugins", "installed_plugins.json" },
            ) catch return null;
        };
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(arena, 1024 * 1024) catch null;
}
