//! Pure presentation logic for the Agent Integrations dialog (T871, the
//! win32 half of Mac's `AgentIntegrationsViewModel.swift` row derivation):
//! given one runtime's `AgentStatus` plus the dialog's transient per-row
//! state (busy, error), decide every user-visible fact about the row — the
//! labels, which action buttons it offers, and which honest uninstall copy
//! its confirm dialog shows.
//!
//! Mac's jq footnote has no counterpart here on purpose: the T866 hook
//! scripts parse with `ghoztty +json`, so no row ever reports an inactive
//! banner over a missing jq.
//!
//! No OS imports — the tests run in every app-runtime lane on both seats.
const std = @import("std");
const service = @import("agent_integration_service.zig");

pub const AgentStatus = service.AgentStatus;
pub const RuntimeAgent = service.RuntimeAgent;
pub const InstallState = service.InstallState;

/// Which action buttons a row offers (Mac's `actions` @ViewBuilder table).
pub const Actions = enum {
    /// Not detected, still probing, or mid-action: no buttons.
    none,
    set_up,
    uninstall,
    update_and_uninstall,
};

/// The row's optional third line. The error wins over the plugin note when
/// both apply — it is transient and actionable, and the plugin fact is
/// repeated by the uninstall confirm copy where it matters.
pub const Detail = enum { none, plugin_note, error_text };

/// Which honest uninstall copy the confirm dialog shows (Mac's
/// `uninstallMessage(for:)` precedence: plugin-managed wins over shared).
pub const UninstallVariant = enum { plain, plugin_managed, banner_shared };

pub const Row = struct {
    name: []const u8,
    /// The name de-emphasizes when the runtime's CLI is absent.
    name_secondary: bool,
    status_label: []const u8,
    detail: Detail,
    actions: Actions,
};

/// The status line while the first probe has not answered yet — the window
/// opens instantly and fills in (Mac's fire-and-forget `refresh`).
pub const checking_label = "Checking…";

/// One row, derived. `busy` is "an action for THIS agent is in flight";
/// `has_error` is "the last action for this agent failed" (the caller owns
/// the error text — it carries a runtime detail this pure module cannot).
pub fn derive(status: AgentStatus, busy: bool, has_error: bool) Row {
    const name = status.agent.displayName();
    if (!status.detected) return .{
        .name = name,
        .name_secondary = true,
        .status_label = switch (status.agent) {
            .claude => "Not detected — install Claude Code to enable",
            .copilot => "Not detected — install Copilot CLI to enable",
        },
        .detail = .none,
        .actions = .none,
    };
    if (busy) return .{
        .name = name,
        .name_secondary = false,
        .status_label = "Working…",
        .detail = .none,
        .actions = .none,
    };
    return .{
        .name = name,
        .name_secondary = false,
        .status_label = switch (status.state) {
            .not_installed => "Not set up",
            .installed => "Installed",
            .outdated => "Update available",
        },
        .detail = if (has_error)
            .error_text
        else if (status.plugin_managed)
            .plugin_note
        else
            .none,
        .actions = switch (status.state) {
            .not_installed => .set_up,
            .installed => .uninstall,
            .outdated => .update_and_uninstall,
        },
    };
}

/// The plugin-managed note line (Mac's exact copy).
pub const plugin_note_text = "Hooks managed by Claude plugin";

pub fn uninstallVariant(status: AgentStatus) UninstallVariant {
    if (status.plugin_managed) return .plugin_managed;
    if (status.banner_shared_with_other) return .banner_shared;
    return .plain;
}

/// `Remove Ghoztty integration from <name>?` — the confirm dialog's title.
pub fn confirmTitle(agent: RuntimeAgent) []const u8 {
    return switch (agent) {
        .claude => "Remove Ghoztty integration from Claude Code?",
        .copilot => "Remove Ghoztty integration from Copilot CLI?",
    };
}

/// The honest, per-situation uninstall copy — Mac's `uninstallMessage(for:)`
/// word for word: the shared banner is kept when another agent still uses
/// it, and plugin-managed hooks are never touched.
pub fn uninstallMessage(agent: RuntimeAgent, variant: UninstallVariant) []const u8 {
    return switch (agent) {
        inline else => |a| blk: {
            const name = comptime a.displayName();
            break :blk switch (variant) {
                .plugin_managed => "This removes the skills Ghoztty added for " ++
                    name ++ ". Its hooks are managed by the Claude plugin and " ++
                    "won't be changed. Your " ++ name ++
                    " configuration is otherwise untouched.",
                .banner_shared => "This removes the skills and hooks Ghoztty " ++
                    "added for " ++ name ++ ". The shared status-banner script " ++
                    "stays because another agent still uses it. Your " ++ name ++
                    " configuration is otherwise untouched.",
                .plain => "This removes the banner script, skills, and hooks " ++
                    "Ghoztty installed. Your " ++ name ++
                    " configuration is otherwise untouched.",
            };
        },
    };
}

// -----------------------------------------------------------------------------
// Tests — the Mac row table, action gating, and the copy precedence.
// -----------------------------------------------------------------------------

const testing = std.testing;

fn mkStatus(agent: RuntimeAgent, detected: bool, state: InstallState) AgentStatus {
    return .{
        .agent = agent,
        .detected = detected,
        .state = state,
        .plugin_managed = false,
        .banner_shared_with_other = false,
    };
}

test "undetected runtime: secondary name, install hint, no actions" {
    const row = derive(mkStatus(.claude, false, .not_installed), false, false);
    try testing.expect(row.name_secondary);
    try testing.expectEqualStrings("Claude Code", row.name);
    try testing.expectEqualStrings("Not detected — install Claude Code to enable", row.status_label);
    try testing.expectEqual(Actions.none, row.actions);
    try testing.expectEqual(Detail.none, row.detail);

    const cop = derive(mkStatus(.copilot, false, .installed), false, false);
    try testing.expectEqualStrings("Not detected — install Copilot CLI to enable", cop.status_label);
}

test "detected states map to the Mac labels and action sets" {
    const not_set_up = derive(mkStatus(.copilot, true, .not_installed), false, false);
    try testing.expect(!not_set_up.name_secondary);
    try testing.expectEqualStrings("Not set up", not_set_up.status_label);
    try testing.expectEqual(Actions.set_up, not_set_up.actions);

    const installed = derive(mkStatus(.copilot, true, .installed), false, false);
    try testing.expectEqualStrings("Installed", installed.status_label);
    try testing.expectEqual(Actions.uninstall, installed.actions);

    const outdated = derive(mkStatus(.copilot, true, .outdated), false, false);
    try testing.expectEqualStrings("Update available", outdated.status_label);
    try testing.expectEqual(Actions.update_and_uninstall, outdated.actions);
}

test "busy row: Working label, no buttons, whatever the state" {
    inline for ([_]InstallState{ .not_installed, .installed, .outdated }) |st| {
        const row = derive(mkStatus(.claude, true, st), true, false);
        try testing.expectEqualStrings("Working…", row.status_label);
        try testing.expectEqual(Actions.none, row.actions);
        try testing.expectEqual(Detail.none, row.detail);
    }
}

test "detail precedence: error over plugin note over none" {
    var s = mkStatus(.claude, true, .installed);
    try testing.expectEqual(Detail.none, derive(s, false, false).detail);

    s.plugin_managed = true;
    try testing.expectEqual(Detail.plugin_note, derive(s, false, false).detail);
    try testing.expectEqual(Detail.error_text, derive(s, false, true).detail);

    s.plugin_managed = false;
    try testing.expectEqual(Detail.error_text, derive(s, false, true).detail);
}

test "plugin-managed row still offers uninstall (Mac: skills-only removal)" {
    var s = mkStatus(.claude, true, .installed);
    s.plugin_managed = true;
    try testing.expectEqual(Actions.uninstall, derive(s, false, false).actions);
}

test "uninstall variant precedence: plugin-managed wins over shared banner" {
    var s = mkStatus(.claude, true, .installed);
    try testing.expectEqual(UninstallVariant.plain, uninstallVariant(s));
    s.banner_shared_with_other = true;
    try testing.expectEqual(UninstallVariant.banner_shared, uninstallVariant(s));
    s.plugin_managed = true;
    try testing.expectEqual(UninstallVariant.plugin_managed, uninstallVariant(s));
}

test "uninstall copy names the agent and states what stays" {
    const plain = uninstallMessage(.claude, .plain);
    try testing.expect(std.mem.indexOf(u8, plain, "banner script, skills, and hooks") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "Claude Code configuration is otherwise untouched") != null);

    const plugin = uninstallMessage(.claude, .plugin_managed);
    try testing.expect(std.mem.indexOf(u8, plugin, "managed by the Claude plugin") != null);

    const shared = uninstallMessage(.copilot, .banner_shared);
    try testing.expect(std.mem.indexOf(u8, shared, "shared status-banner script stays") != null);
    try testing.expect(std.mem.indexOf(u8, shared, "Copilot CLI") != null);

    try testing.expectEqualStrings(
        "Remove Ghoztty integration from Copilot CLI?",
        confirmTitle(.copilot),
    );
}
