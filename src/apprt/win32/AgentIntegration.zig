//! T870: agent-integration first-run offer + Claude plugin migration — the
//! Windows port of Mac's new-flow `AppDelegate+Setup.swift`. On first launch
//! the app detects which coding-agent CLIs are installed (the T869 probe)
//! and offers to set up Ghoztty's integration for each — skills, hooks and
//! the status banner, installed by `agent_integration_service` — with a
//! checkbox per agent. A box still running the OLD standalone Claude plugin
//! gets a separate one-time offer to switch over (`claude_plugin_migration`,
//! Mac's `ClaudePluginMigration.swift`), which removes the plugin through
//! Claude's own CLI and carries the banner state across.
//!
//! This replaced the T71 flow (`claude plugin marketplace add` +
//! `claude plugin install`): the app now ships the skills itself, tied to
//! the installed Ghoztty rather than to a separately-versioned marketplace
//! release. The only `claude` invocation left is the migration's uninstall.
//!
//! Threading: detection, installs and the migration run on detached
//! background threads (probes walk the filesystem; a `claude` run can take
//! seconds); results are marshalled to the GUI thread via WM_APP_* posted to
//! the message-only window, where the T80 ConfirmDialog shows the prompt or
//! outcome. First-run and migration success stay SILENT (Mac parity);
//! failures report once, actionably.
//!
//! First-run gating mirrors PathInstaller (T70): only the canonical install
//! (%LOCALAPPDATA%\Programs\Ghoztty) prompts, so dev builds and portable
//! unpacks never nag. Test hooks: GHOZTTY_CLAUDE_SETUP (`0`/`off` disables,
//! `force` skips the location gate), GHOZTTY_AGENT_HOME (sandbox home for
//! the probe, the installs and the migration — when set, the probe consults
//! ONLY that home so the box's real installs cannot leak in),
//! GHOZTTY_CLAUDE_EXE (claude path override for the migration's uninstall),
//! GHOZTTY_CLAUDE_STATE_DIR (answer-file dir). The answers persist in
//! <state dir>\claude_setup and <state dir>\claude_plugin_migration as
//! "accepted"/"declined" — declining is remembered, and both are written
//! BEFORE the work so a crash mid-dialog can never turn into a nag.
const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const setup = @import("claude_setup.zig");
const service = @import("agent_integration_service.zig");
const runtime_probe = @import("runtime_probe.zig");
const RuntimeIntegration = @import("RuntimeIntegration.zig");
const migration = @import("claude_plugin_migration.zig");
const path_env = @import("../../os/path_env.zig");

const log = std.log.scoped(.win32_claude);

pub const RuntimeAgent = service.RuntimeAgent;
pub const RuntimeProbe = service.RuntimeProbe;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// The two long prompt texts, converted at comptime with a raised branch
/// quota (utf8→utf16 of a ~300-char literal blows the default 1000).
const first_run_text: [:0]const u16 = blk: {
    @setEvalBranchQuota(20_000);
    break :blk L(
        "Ghoztty can set up its integration for the coding agents on\n" ++
            "this PC — skills, hooks, and a status banner — so agents can\n" ++
            "open windows, create splits, and read terminal output.\n\n" ++
            "Choose which agents to set up:",
    );
};

/// The agent-config-write disclosure under the checkboxes (T600, Mac's
/// d839b3f4a): what ticking a box writes and where, and that it is
/// reversible — said BEFORE anything is written.
const first_run_note: [:0]const u16 = blk: {
    @setEvalBranchQuota(20_000);
    break :blk L(
        "Integrations add Ghoztty's status banner, skills, and hooks\n" ++
            "under each agent's configuration folder (such as .claude).\n" ++
            "You can remove them anytime from Set Up Agent Integrations…\n" ++
            "in the command palette.",
    );
};

const migration_text: [:0]const u16 = blk: {
    @setEvalBranchQuota(20_000);
    break :blk L(
        "The ghoztty Claude Code plugin is installed. Ghoztty now ships\n" ++
            "these skills itself, tied to the version you have installed, so\n" ++
            "they can never describe a command your Ghoztty does not have.\n\n" ++
            "Switching removes the plugin with Claude's own uninstaller and\n" ++
            "installs Ghoztty's copy. Your banners keep working.",
    );
};

/// Posted by the first-run check thread when the prompt should be shown.
/// wparam carries the detected-agent bits (see `bitsOf`).
pub const WM_APP_CLAUDE_PROMPT: u32 = w32.WM_APP + 7;

/// Posted by an install thread when the installs finished. wparam is a
/// heap *Done owned by the handler.
pub const WM_APP_CLAUDE_DONE: u32 = w32.WM_APP + 8;

/// Posted by the launch check thread when the plugin-migration offer should
/// be shown. No payload.
pub const WM_APP_MIGRATION_PROMPT: u32 = w32.WM_APP + 30;

/// Posted by the migration thread when it finished. wparam is a heap
/// *MigrationDone owned by the handler.
pub const WM_APP_MIGRATION_DONE: u32 = w32.WM_APP + 31;

pub const Done = struct {
    /// Outcomes carry only static detail strings (see the service), so this
    /// struct owns no memory beyond itself.
    results: [service.agent_count]service.AgentResult,
    n: usize,
};

pub const MigrationDone = struct {
    outcome: enum { ok, uninstall_failed, install_attention },
    /// Failure detail, owned by this struct (may be empty).
    detail: []const u8,
};

const setup_state_name = "claude_setup";
const migration_state_name = "claude_plugin_migration";

/// At most one install batch runs at a time; a second request while one is
/// in flight is dropped (the flow is idempotent, re-running from the
/// palette afterwards reports "already up to date").
var install_running: std.atomic.Value(bool) = .init(false);
var migration_running: std.atomic.Value(bool) = .init(false);

/// Launch-time check on a detached thread: decide whether to show the
/// one-time first-run prompt, and — only once that prompt has been answered
/// on some earlier launch, so two modals can never stack — whether to show
/// the one-time plugin-migration offer. Never blocks startup.
pub fn checkOnLaunchAsync(app: *App) void {
    const thread = std.Thread.spawn(.{}, launchCheck, .{app}) catch |err| {
        log.warn("agent setup: check thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn launchCheck(app: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (!setupEnabled(arena)) return;

    if (readState(arena, setup_state_name) == .unanswered) {
        const detected = detectAgents(arena);
        if (detected.count() == 0) {
            // No agent CLI on this box: leave the prompt unburned so
            // installing one later still gets the one-time offer.
            log.debug("agent setup: no agent CLIs found; not prompting", .{});
            return;
        }
        // Let the first window appear and settle before dialoging over it
        // (the Mac flow waits 2s after launch).
        std.Thread.sleep(1 * std.time.ns_per_s);
        const hwnd = app.msg_hwnd orelse return;
        _ = w32.PostMessageW(hwnd, WM_APP_CLAUDE_PROMPT, bitsOf(detected), 0);
        return;
    }

    // First-run answered on an earlier launch: consider the migration.
    if (readState(arena, migration_state_name) != .unanswered) return;
    const home = openAgentHome(arena) orelse return;
    var home_dir = home.dir;
    defer home_dir.close();
    const needed = migration.isNeeded(arena, home_dir) catch false;
    if (!needed) return;

    std.Thread.sleep(3 * std.time.ns_per_s);
    const hwnd = app.msg_hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_MIGRATION_PROMPT, 0, 0);
}

/// GUI thread (msgWndProc): show the one-time first-run prompt for the
/// detected agents.
pub fn showFirstRunPrompt(app: *App, agent_bits: usize) void {
    var arena_state = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // T1120: not during the morning delivery's relaunch. Returning BEFORE the
    // state write below is the whole point — this is a one-time offer, and
    // burning it on an empty desk would mean the user is never asked at all.
    if (app.unattendedRefreshActive()) {
        log.info("agent setup: unattended refresh in progress; the first-run offer waits for a launch with someone in front of it", .{});
        return;
    }

    // The palette flow may have answered while the check thread slept.
    if (readState(arena, setup_state_name) != .unanswered) return;

    // Mark answered BEFORE showing so a crash mid-dialog can never turn
    // into a nag on every launch (Mac sets promptAnswered pre-runModal).
    writeState(arena, setup_state_name, .declined);

    const detected = setOf(agent_bits);
    var checks_buf: [service.agent_count]ConfirmDialog.Check = undefined;
    var agents_buf: [service.agent_count]RuntimeAgent = undefined;
    var n: usize = 0;
    inline for (std.meta.tags(RuntimeAgent)) |agent| {
        if (detected.contains(agent)) {
            checks_buf[n] = .{ .label = checkLabelFor(agent), .checked = true };
            agents_buf[n] = agent;
            n += 1;
        }
    }
    if (n == 0) return;

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
            .title = L("Set Up Agent Integrations?"),
            .text = first_run_text,
            .icon = .info,
            .default_cancel = false,
            .ok_label = L("Set Up"),
            .cancel_label = L("Not Now"),
            .checks = checks_buf[0..n],
            .note = first_run_note,
        },
    );
    if (result != .ok) return;

    writeState(arena, setup_state_name, .accepted);

    var chosen = std.EnumSet(RuntimeAgent).initEmpty();
    for (checks_buf[0..n], 0..) |check, i| {
        if (check.checked) chosen.insert(agents_buf[i]);
    }
    if (chosen.count() == 0) return;
    installAsync(app, chosen);
}

/// Kick off the first-run integration installs on a detached thread for the
/// agents the user checked. Safe to call from the GUI thread. (Managing
/// integrations afterwards is the Agent Integrations dialog, T871 — the
/// palette no longer blind-installs.)
pub fn installAsync(app: *App, agents: std.EnumSet(RuntimeAgent)) void {
    if (install_running.swap(true, .acq_rel)) {
        log.info("agent setup: install already running; ignoring", .{});
        return;
    }
    const thread = std.Thread.spawn(.{}, installThread, .{ app, agents }) catch |err| {
        install_running.store(false, .release);
        log.warn("agent setup: install thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn installThread(app: *App, agents: std.EnumSet(RuntimeAgent)) void {
    defer install_running.store(false, .release);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const alloc = app.core_app.alloc;
    const done = alloc.create(Done) catch return;
    done.* = .{
        .results = undefined,
        .n = 0,
    };

    if (openAgentHome(arena)) |home| {
        var home_dir = home.dir;
        defer home_dir.close();
        const probe = probeFor(arena);
        var it = agents.iterator();
        while (it.next()) |agent| {
            const outcome = service.install(arena, agent, home_dir, home.path, probe) catch
                service.IntegrationOutcome{ .failed = "out of memory" };
            done.results[done.n] = .{ .agent = agent, .outcome = outcome };
            done.n += 1;
            log.info("agent setup: {s}: {s}", .{ @tagName(agent), outcome.label() });
        }
    } else {
        // The chosen installs never ran; report them failed rather than
        // reporting a silent success over nothing.
        var it = agents.iterator();
        while (it.next()) |agent| {
            done.results[done.n] = .{ .agent = agent, .outcome = .{ .failed = "HomeUnavailable" } };
            done.n += 1;
        }
    }

    const hwnd = app.msg_hwnd orelse {
        alloc.destroy(done);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_CLAUDE_DONE, @intFromPtr(done), 0) == 0) {
        alloc.destroy(done);
    }
}

/// GUI thread (msgWndProc): report a first-run install outcome. Owns
/// `done`. Success stays SILENT so the first launch is quiet (Mac parity);
/// any failure is reported once, actionably.
pub fn onDone(app: *App, done: *Done) void {
    const alloc = app.core_app.alloc;
    defer alloc.destroy(done);

    var any_failed = false;
    for (done.results[0..done.n]) |r| {
        if (r.outcome == .failed) any_failed = true;
    }
    if (!any_failed) return;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text_w: [:0]const u16 = blk: {
        const summary_text = service.summary(arena, done.results[0..done.n]) catch
            break :blk L("The integration run did not finish.");
        const text = std.mem.concat(arena, u8, &.{
            summary_text,
            "\n\nRe-run Set Up Agent Integrations… to try again.",
        }) catch summary_text;
        break :blk std.unicode.utf8ToUtf16LeAllocZ(arena, text) catch
            L("The integration run did not finish.");
    };

    showAlert(app, L("Some Integrations Failed"), text_w, .warning);
}

/// GUI thread (msgWndProc): show the one-time plugin-migration offer.
pub fn showMigrationPrompt(app: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // T1120: same as the first-run offer — a one-time prompt raised by the
    // unattended relaunch is one the user never gets to answer.
    if (app.unattendedRefreshActive()) {
        log.info("agent setup: unattended refresh in progress; the migration offer waits for a launch with someone in front of it", .{});
        return;
    }

    if (readState(arena, migration_state_name) != .unanswered) return;

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
            .title = L("Ghoztty Now Manages Its Claude Integration"),
            .text = migration_text,
            .icon = .info,
            .default_cancel = false,
            .ok_label = L("Switch Over"),
            .cancel_label = L("Keep Plugin"),
        },
    );

    // Recorded either way, and BEFORE the work: answering is what retires
    // the prompt, not succeeding at it (Mac's exact rule).
    writeState(arena, migration_state_name, if (result == .ok) .accepted else .declined);
    if (result != .ok) return;

    if (migration_running.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, migrateThread, .{app}) catch |err| {
        migration_running.store(false, .release);
        log.warn("plugin migration: thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

/// The migration's `claude plugin uninstall` runner (see
/// `claude_plugin_migration.Runner`).
const UninstallCtx = struct {
    arena: std.mem.Allocator,
    claude: []const u8,
    detail: []const u8 = "",
};

fn uninstallRun(ctx_ptr: ?*anyopaque, registration: []const u8) migration.UninstallError!void {
    const ctx: *UninstallCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const r = runClaude(ctx.arena, ctx.claude, &.{ "plugin", "uninstall", registration });
    if (!r.ok) {
        ctx.detail = if (r.detail.len > 0) r.detail else std.fmt.allocPrint(
            ctx.arena,
            "`claude plugin uninstall {s}` failed.",
            .{registration},
        ) catch "";
        return error.UninstallFailed;
    }
    log.info("plugin migration: uninstalled {s}", .{registration});
}

fn migrateThread(app: *App) void {
    defer migration_running.store(false, .release);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const alloc = app.core_app.alloc;
    const done = alloc.create(MigrationDone) catch return;
    done.* = .{ .outcome = .ok, .detail = "" };

    run: {
        const home = openAgentHome(arena) orelse {
            done.outcome = .uninstall_failed;
            done.detail = alloc.dupe(u8, "The home directory could not be opened.") catch "";
            break :run;
        };
        var home_dir = home.dir;
        defer home_dir.close();

        const claude = findClaude(arena) orelse {
            done.outcome = .uninstall_failed;
            done.detail = alloc.dupe(u8, "Could not run the claude command.") catch "";
            break :run;
        };
        var ctx: UninstallCtx = .{ .arena = arena, .claude = claude };
        migration.run(arena, home_dir, .{ .ctx = &ctx, .runFn = &uninstallRun }) catch {
            // Uninstall failed: nothing was migrated (see migration.run).
            done.outcome = .uninstall_failed;
            done.detail = alloc.dupe(
                u8,
                if (ctx.detail.len > 0) ctx.detail else "The plugin could not be removed.",
            ) catch "";
            break :run;
        };

        // The plugin is gone: install the app's own Claude integration.
        const outcome = service.install(arena, .claude, home_dir, home.path, probeFor(arena)) catch
            service.IntegrationOutcome{ .failed = "out of memory" };
        switch (outcome) {
            .installed, .upgraded, .up_to_date => {}, // Silent: the user already said do it.
            else => {
                done.outcome = .install_attention;
                const label = outcome.labelAlloc(arena) catch outcome.label();
                done.detail = alloc.dupe(u8, label) catch "";
            },
        }
        log.info("plugin migration: done; claude install: {s}", .{outcome.label()});
    }

    const hwnd = app.msg_hwnd orelse {
        freeMigrationDone(app, done);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_MIGRATION_DONE, @intFromPtr(done), 0) == 0) {
        freeMigrationDone(app, done);
    }
}

fn freeMigrationDone(app: *App, done: *MigrationDone) void {
    const alloc = app.core_app.alloc;
    if (done.detail.len > 0) alloc.free(done.detail);
    alloc.destroy(done);
}

/// GUI thread (msgWndProc): report the migration outcome. Owns `done`.
/// Success is silent — the user already approved the switch.
pub fn onMigrationDone(app: *App, done: *MigrationDone) void {
    defer freeMigrationDone(app, done);
    if (done.outcome == .ok) return;

    var arena_state = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text: []const u8 = switch (done.outcome) {
        .uninstall_failed => std.mem.concat(arena, u8, &.{
            done.detail,
            "\n\nNothing was changed — the plugin still manages Claude.\n" ++
                "You can try again on the next launch.",
        }) catch done.detail,
        .install_attention => std.mem.concat(arena, u8, &.{
            "The plugin was removed, but installing Ghoztty's copy reported:\n",
            done.detail,
            "\n\nRun Set Up Agent Integrations to finish setting it up.",
        }) catch done.detail,
        .ok => unreachable,
    };
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(arena, text) catch
        L("The migration did not finish.");
    const title: [*:0]const u16 = switch (done.outcome) {
        .uninstall_failed => L("Could Not Remove the Plugin"),
        .install_attention => L("Claude Integration Needs Attention"),
        .ok => unreachable,
    };
    showAlert(app, title, text_w, .warning);
}

fn showAlert(app: *App, title: [*:0]const u16, text: [:0]const u16, icon: ConfirmDialog.Icon) void {
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
        .{ .title = title, .text = text, .style = .ok_only, .icon = icon },
    );
}

fn checkLabelFor(agent: RuntimeAgent) [:0]const u16 {
    return switch (agent) {
        .claude => L("Set up Claude Code integration"),
        .copilot => L("Set up Copilot CLI integration"),
    };
}

/// Detected-agent set <-> the WM_APP_CLAUDE_PROMPT wparam bits.
fn bitsOf(set: std.EnumSet(RuntimeAgent)) usize {
    var bits: usize = 0;
    inline for (std.meta.tags(RuntimeAgent), 0..) |agent, i| {
        if (set.contains(agent)) bits |= @as(usize, 1) << @intCast(i);
    }
    return bits;
}

fn setOf(bits: usize) std.EnumSet(RuntimeAgent) {
    var set = std.EnumSet(RuntimeAgent).initEmpty();
    inline for (std.meta.tags(RuntimeAgent), 0..) |agent, i| {
        if (bits & (@as(usize, 1) << @intCast(i)) != 0) set.insert(agent);
    }
    return set;
}

/// The home the integrations install into: `GHOZTTY_AGENT_HOME` (sandbox
/// override for tests), else the user's profile. `path` is arena-owned.
/// Pub: the Agent Integrations dialog's workers (T871) resolve the same
/// home and probe, so the sandbox override governs every entry point.
pub const AgentHome = struct {
    dir: std.fs.Dir,
    path: []const u8,
};

fn agentHomePath(arena: std.mem.Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(arena, "GHOZTTY_AGENT_HOME") catch null) |override| {
        if (override.len > 0) return override;
    }
    return std.process.getEnvVarOwned(arena, "USERPROFILE") catch null;
}

pub fn openAgentHome(arena: std.mem.Allocator) ?AgentHome {
    const path = agentHomePath(arena) orelse return null;
    const dir = std.fs.cwd().openDir(path, .{}) catch |err| {
        log.warn("agent setup: home open failed ({s}): {}", .{ path, err });
        return null;
    };
    return .{ .dir = dir, .path = path };
}

/// The runtime probe: the process environment normally; ONLY the sandbox
/// home when `GHOZTTY_AGENT_HOME` is set, so a test's detection cannot be
/// polluted by whatever the box really has installed.
pub fn probeFor(arena: std.mem.Allocator) RuntimeProbe {
    if (std.process.getEnvVarOwned(arena, "GHOZTTY_AGENT_HOME") catch null) |override| {
        if (override.len > 0) return .{ .env = .{ .home = override } };
    }
    return .binary;
}

fn detectAgents(arena: std.mem.Allocator) std.EnumSet(RuntimeAgent) {
    return RuntimeIntegration.availableAgents(arena, probeFor(arena));
}

const RunResult = struct {
    ok: bool,
    detail: []const u8,
};

/// Run `claude <args...>` hidden (no console flash from the GUI process)
/// and report success plus the output tail. Zig's Child spawns .cmd/.bat
/// shims via cmd.exe itself, so npm installs work as well as the native
/// claude.exe. Background thread only.
fn runClaude(
    arena: std.mem.Allocator,
    claude: []const u8,
    args: []const []const u8,
) RunResult {
    var argv = std.ArrayList([]const u8).initCapacity(arena, args.len + 1) catch
        return .{ .ok = false, .detail = "out of memory" };
    argv.appendAssumeCapacity(claude);
    argv.appendSliceAssumeCapacity(args);

    var child = std.process.Child.init(argv.items, arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;

    child.spawn() catch |err| {
        log.warn("agent setup: claude spawn failed: {}", .{err});
        return .{ .ok = false, .detail = "Claude Code could not be started." };
    };
    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    child.collectOutput(arena, &stdout, &stderr, 512 * 1024) catch |err| {
        _ = child.kill() catch {};
        log.warn("agent setup: claude output collection failed: {}", .{err});
        return .{ .ok = false, .detail = "Claude Code did not respond." };
    };
    const term = child.wait() catch |err| {
        log.warn("agent setup: claude wait failed: {}", .{err});
        return .{ .ok = false, .detail = "Claude Code did not respond." };
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
    log.info("claude {s}: exit_ok={}", .{ args[args.len - 1], exit_ok });
    return .{ .ok = exit_ok, .detail = setup.detailTail(combined, 300) };
}

/// Find the claude CLI for the migration's uninstall: env override, then
/// the process PATH, then the well-known install locations (the Mac
/// findClaude, Windows-flavored).
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

fn statePath(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const dir = std.process.getEnvVarOwned(arena, "GHOZTTY_CLAUDE_STATE_DIR") catch
        blk: {
            const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return null;
            break :blk std.fs.path.join(arena, &.{ local, "ghoztty" }) catch return null;
        };
    return std.fs.path.join(arena, &.{ dir, name }) catch null;
}

fn readState(arena: std.mem.Allocator, name: []const u8) setup.State {
    const path = statePath(arena, name) orelse return .unanswered;
    const f = std.fs.cwd().openFile(path, .{}) catch return .unanswered;
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = f.readAll(&buf) catch 0;
    return setup.parseState(buf[0..n]);
}

fn writeState(arena: std.mem.Allocator, name: []const u8, state: setup.State) void {
    const path = statePath(arena, name) orelse return;
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        log.warn("agent setup: state write failed: {}", .{err});
        return;
    };
    defer f.close();
    f.writeAll(setup.stateText(state)) catch {};
}
