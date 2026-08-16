//! The UI-facing surface over the runtime integrations (T869, the win32
//! half of Mac's `AgentIntegrationService.swift`): install/uninstall one
//! agent and get back an outcome in Mac's vocabulary, plus per-agent status
//! snapshots for the Agent Integrations dialog (T871).
//!
//! Mac's `jqAvailable` has no counterpart here on purpose: the T866 hook
//! scripts parse their payloads with `ghoztty +json`, so nothing on Windows
//! depends on jq and there is nothing to report.
//!
//! Blocking: the real binary probe walks the filesystem per runtime. Callers
//! on the GUI thread run these off-thread and marshal back (the
//! `ClaudeIntegration.zig` detached-thread + WM_APP pattern), exactly like
//! Mac's `AgentIntegrationsViewModel.refresh`.
//!
//! Plain `std.fs` + the T869 registry, no direct OS imports, so the tempdir
//! tests run in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
const claude_plugin_manifest = @import("claude_plugin_manifest.zig");
const RuntimeIntegration = @import("RuntimeIntegration.zig");

pub const RuntimeAgent = RuntimeIntegration.RuntimeAgent;
pub const RuntimeProbe = RuntimeIntegration.RuntimeProbe;
pub const InstallState = marker_mod.InstallState;

pub const agent_count = std.meta.tags(RuntimeAgent).len;

/// A UI-facing snapshot of one runtime's Ghoztty-integration state.
pub const AgentStatus = struct {
    agent: RuntimeAgent,
    /// The runtime's CLI is installed (a binary probe — NOT "its config dir
    /// exists", which Ghoztty itself creates; see `runtime_probe`).
    detected: bool,
    state: InstallState,
    /// Claude only: an external `ghoztty` plugin already owns the hooks.
    plugin_managed: bool,
    /// Another installed agent's hooks also reference the shared banner
    /// scripts, so uninstalling THIS agent will leave them in place. Drives
    /// honest uninstall copy.
    banner_shared_with_other: bool,
};

/// Mac's outcome vocabulary. `failed` carries a STATIC detail string (an
/// error name or a literal), so no outcome ever owns memory.
pub const IntegrationOutcome = union(enum) {
    installed,
    up_to_date,
    upgraded,
    not_found,
    plugin_present,
    uninstalled,
    failed: []const u8,

    /// The fixed half of the label; `labelAlloc` appends the failure detail.
    pub fn label(self: IntegrationOutcome) []const u8 {
        return switch (self) {
            .installed => "installed",
            .up_to_date => "already up to date",
            .upgraded => "upgraded",
            .not_found => "not found",
            .plugin_present => "plugin already present",
            .uninstalled => "removed",
            .failed => "failed",
        };
    }

    pub fn labelAlloc(self: IntegrationOutcome, alloc: Allocator) Allocator.Error![]u8 {
        return switch (self) {
            .failed => |detail| std.fmt.allocPrint(alloc, "failed — {s}", .{detail}),
            else => alloc.dupe(u8, self.label()),
        };
    }
};

pub fn install(
    alloc: Allocator,
    agent: RuntimeAgent,
    home: std.fs.Dir,
    home_path: []const u8,
    probe: RuntimeProbe,
) Allocator.Error!IntegrationOutcome {
    const integ = try RuntimeIntegration.make(alloc, agent, home, home_path, probe);
    const prior = integ.state(alloc);
    integ.install(alloc) catch |err| switch (err) {
        error.NotInstalled => return .not_found,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = @errorName(err) },
    };
    if (agent == .claude and
        try claude_plugin_manifest.isExternalPluginInstalled(alloc, home))
        return .plugin_present;
    const now = integ.state(alloc);
    return switch (now) {
        .installed => switch (prior) {
            .installed => .up_to_date,
            .outdated => .upgraded,
            .not_installed => .installed,
        },
        // install() returned success, so this is drift mid-call — name it
        // rather than claiming success (Mac's `post-install state` guard).
        .not_installed => .{ .failed = "post-install state not_installed" },
        .outdated => .{ .failed = "post-install state outdated" },
    };
}

pub fn uninstall(
    alloc: Allocator,
    agent: RuntimeAgent,
    home: std.fs.Dir,
    home_path: []const u8,
    probe: RuntimeProbe,
) Allocator.Error!IntegrationOutcome {
    // The shared banner is refcounted inside its own component (see
    // `RuntimeIntegration.Component.uninstall`), so the guarantee holds for
    // ANY caller — including the install() rollback path.
    const integ = try RuntimeIntegration.make(alloc, agent, home, home_path, probe);
    integ.uninstall(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = @errorName(err) },
    };
    return .uninstalled;
}

/// One status per runtime, in `RuntimeAgent` declaration order.
pub fn allAgentStatuses(
    alloc: Allocator,
    home: std.fs.Dir,
    home_path: []const u8,
    probe: RuntimeProbe,
) Allocator.Error![agent_count]AgentStatus {
    var out: [agent_count]AgentStatus = undefined;
    inline for (std.meta.tags(RuntimeAgent), 0..) |agent, i| {
        const integ = try RuntimeIntegration.make(alloc, agent, home, home_path, probe);
        out[i] = .{
            .agent = agent,
            .detected = probe.isInstalled(alloc, agent),
            .state = integ.state(alloc),
            .plugin_managed = agent == .claude and
                try claude_plugin_manifest.isExternalPluginInstalled(alloc, home),
            .banner_shared_with_other = try RuntimeIntegration.anyHooksReferenceBanner(
                alloc,
                home,
                home_path,
                agent,
            ),
        };
    }
    return out;
}

/// `Claude Code: installed · Copilot CLI: not found` — the one-line summary
/// dialogs show after a batch action (Mac's `summary`).
pub fn summary(
    alloc: Allocator,
    results: []const struct { agent: RuntimeAgent, outcome: IntegrationOutcome },
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (results, 0..) |r, i| {
        if (i > 0) w.writeAll(" · ") catch return error.OutOfMemory;
        const l = try r.outcome.labelAlloc(alloc);
        defer alloc.free(l);
        w.print("{s}: {s}", .{ r.agent.displayName(), l }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

// -----------------------------------------------------------------------------
// Tests — the outcome vocabulary walk plus the status snapshot.
// -----------------------------------------------------------------------------

const testing = std.testing;
const hook_scripts = @import("hook_scripts.zig");
const CopilotHookSpec = @import("CopilotHookSpec.zig");

const test_home_path = "C:\\Users\\tester";
const all_probe = RuntimeProbe.stubOf(&.{ .claude, .copilot });

test "install outcomes: installed, then up_to_date, then upgraded after drift" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(
        IntegrationOutcome.installed,
        try install(alloc, .copilot, tmp.dir, test_home_path, all_probe),
    );
    try testing.expectEqual(
        IntegrationOutcome.up_to_date,
        try install(alloc, .copilot, tmp.dir, test_home_path, all_probe),
    );

    // Ours-but-stale (marked, different bytes) → the retry reports upgraded.
    try tmp.dir.writeFile(.{
        .sub_path = hook_scripts.banner_sub_path,
        .data = "#!/bin/sh\n" ++ marker_mod.shell_comment ++ "\necho old\n",
    });
    try testing.expectEqual(
        IntegrationOutcome.upgraded,
        try install(alloc, .copilot, tmp.dir, test_home_path, all_probe),
    );
}

test "install outcome: not_found when the probe says absent" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(
        IntegrationOutcome.not_found,
        try install(alloc, .copilot, tmp.dir, test_home_path, RuntimeProbe.stubOf(&.{})),
    );
}

test "install outcome: plugin_present for a plugin-managed claude" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{
        .sub_path = claude_plugin_manifest.manifest_sub_path,
        .data =
        \\{"version": 2, "plugins": {"ghoztty@m": [{}]}}
        ,
    });
    try testing.expectEqual(
        IntegrationOutcome.plugin_present,
        try install(alloc, .claude, tmp.dir, test_home_path, all_probe),
    );
}

test "install outcome: failed carries the error name" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".copilot/hooks");
    try tmp.dir.writeFile(.{ .sub_path = CopilotHookSpec.hook_file_sub_path, .data = "{}" });

    const outcome = try install(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try testing.expect(outcome == .failed);
    try testing.expectEqualStrings("NotManaged", outcome.failed);

    const l = try outcome.labelAlloc(alloc);
    defer alloc.free(l);
    try testing.expectEqualStrings("failed — NotManaged", l);
}

test "uninstall outcome: uninstalled, idempotently" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try install(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try testing.expectEqual(
        IntegrationOutcome.uninstalled,
        try uninstall(alloc, .copilot, tmp.dir, test_home_path, all_probe),
    );
    // Nothing left → still a clean uninstall, not an error.
    try testing.expectEqual(
        IntegrationOutcome.uninstalled,
        try uninstall(alloc, .copilot, tmp.dir, test_home_path, all_probe),
    );
}

test "allAgentStatuses: detection, state and the shared-banner flag" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const probe = RuntimeProbe.stubOf(&.{.claude});
    _ = try install(alloc, .claude, tmp.dir, test_home_path, probe);

    const statuses = try allAgentStatuses(alloc, tmp.dir, test_home_path, probe);
    try testing.expectEqual(RuntimeAgent.claude, statuses[0].agent);
    try testing.expect(statuses[0].detected);
    try testing.expectEqual(InstallState.installed, statuses[0].state);
    try testing.expect(!statuses[0].plugin_managed);
    // Claude is the ONLY agent with hooks, so nothing else shares the banner.
    try testing.expect(!statuses[0].banner_shared_with_other);

    try testing.expectEqual(RuntimeAgent.copilot, statuses[1].agent);
    try testing.expect(!statuses[1].detected);
    try testing.expectEqual(InstallState.not_installed, statuses[1].state);
    // Claude's hooks DO reference the banner, so copilot's uninstall copy
    // must say the scripts stay.
    try testing.expect(statuses[1].banner_shared_with_other);
}

test "summary joins display names and labels" {
    const alloc = testing.allocator;
    const got = try summary(alloc, &.{
        .{ .agent = .claude, .outcome = .installed },
        .{ .agent = .copilot, .outcome = .not_found },
    });
    defer alloc.free(got);
    try testing.expectEqualStrings("Claude Code: installed · Copilot CLI: not found", got);
}
