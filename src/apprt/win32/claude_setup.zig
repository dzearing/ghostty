//! Pure logic for the Claude Code integration setup (T71): interpreting
//! `claude plugin ...` step output, merging the two steps into an outcome,
//! deciding whether the plugin is already installed from the plugins
//! registry JSON, and parsing the persisted first-run answer. No OS
//! imports, so the unit tests run in every app-runtime lane (the
//! hero_math/dim_math pattern). Process spawning, the first-run prompt,
//! and the state file live in ClaudeIntegration.zig.
const std = @import("std");

/// The plugin marketplace and plugin id, shared with the Mac flow
/// (macos/Sources/Features/Setup/ClaudeCodeIntegration.swift).
pub const marketplace = "dzearing/ghoztty-claude-plugin";
pub const plugin = "ghoztty@ghoztty-claude-plugin";

/// Result of one `claude plugin ...` invocation. Claude reports
/// "already installed"/"already exists" with a nonzero exit on some
/// versions, so "already" in the output counts as success — the Mac
/// flow's exact rule.
pub const Step = struct {
    ok: bool,
    already: bool,
};

pub fn stepResult(exit_ok: bool, output: []const u8) Step {
    const already = std.ascii.indexOfIgnoreCase(output, "already") != null;
    return .{ .ok = exit_ok or already, .already = already };
}

pub const Outcome = enum {
    installed,
    already_installed,
    claude_not_found,
    failed,
};

/// Both steps succeeded; installed fresh unless both were already done.
pub fn mergeOutcome(add_already: bool, install_already: bool) Outcome {
    return if (add_already and install_already) .already_installed else .installed;
}

/// The last `max` bytes of the trimmed output, snapped forward past UTF-8
/// continuation bytes so the slice never starts mid-codepoint (the Mac
/// flow's suffix(300) for failure detail).
pub fn detailTail(output: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len <= max) return trimmed;
    var start = trimmed.len - max;
    while (start < trimmed.len and trimmed[start] & 0xC0 == 0x80) start += 1;
    return trimmed[start..];
}

/// Whether a ghoztty plugin from ANY marketplace is already installed,
/// judged from `~/.claude/plugins/installed_plugins.json`. Key-prefix
/// containment is deliberate: a box with `ghoztty@dzearing-claude-
/// marketplace` (a dev checkout) must not be prompted to install the
/// public `ghoztty@ghoztty-claude-plugin` on top of it.
pub fn hasGhozttyPlugin(installed_json: []const u8) bool {
    return std.mem.indexOf(u8, installed_json, "\"ghoztty@") != null;
}

/// The persisted first-run answer. `declined` is written just before the
/// prompt is shown (so a crash mid-dialog never re-nags) and overwritten
/// with `accepted` when the user says yes — Mac's promptAnswered/
/// installAccepted pair collapsed into one file.
pub const State = enum {
    unanswered,
    accepted,
    declined,
};

pub fn parseState(text: []const u8) State {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "accepted")) return .accepted;
    if (std.mem.eql(u8, trimmed, "declined")) return .declined;
    return .unanswered;
}

pub fn stateText(state: State) []const u8 {
    return switch (state) {
        .unanswered => "",
        .accepted => "accepted",
        .declined => "declined",
    };
}

test "stepResult: exit code and already-done detection" {
    const testing = std.testing;
    try testing.expect(stepResult(true, "Installed plugin").ok);
    try testing.expect(!stepResult(true, "Installed plugin").already);
    try testing.expect(stepResult(false, "Error: boom").ok == false);

    // "already" rescues a nonzero exit, case-insensitively.
    const s = stepResult(false, "Marketplace ALREADY exists");
    try testing.expect(s.ok);
    try testing.expect(s.already);
}

test "mergeOutcome" {
    const testing = std.testing;
    try testing.expectEqual(Outcome.already_installed, mergeOutcome(true, true));
    try testing.expectEqual(Outcome.installed, mergeOutcome(true, false));
    try testing.expectEqual(Outcome.installed, mergeOutcome(false, true));
    try testing.expectEqual(Outcome.installed, mergeOutcome(false, false));
}

test "detailTail: trims, caps, respects UTF-8 boundaries" {
    const testing = std.testing;
    try testing.expectEqualStrings("short", detailTail("  short \r\n", 300));
    try testing.expectEqualStrings("cdef", detailTail("abcdef", 4));

    // A 2-byte codepoint straddling the cap is dropped, not split.
    const s = "aé"; // 'a' + 0xC3 0xA9
    try testing.expectEqualStrings("\xC3\xA9", detailTail(s, 2));
    try testing.expectEqualStrings("", detailTail("é", 1));
}

test "hasGhozttyPlugin" {
    const testing = std.testing;
    try testing.expect(hasGhozttyPlugin(
        \\{"plugins":{"ghoztty@dzearing-claude-marketplace":[{}]}}
    ));
    try testing.expect(hasGhozttyPlugin(
        \\{"plugins":{"ghoztty@ghoztty-claude-plugin":[{}]}}
    ));
    try testing.expect(!hasGhozttyPlugin(
        \\{"plugins":{"superpowers@superpowers-dev":[{}]}}
    ));
    try testing.expect(!hasGhozttyPlugin(""));
}

test "parseState round-trips" {
    const testing = std.testing;
    try testing.expectEqual(State.accepted, parseState("accepted\r\n"));
    try testing.expectEqual(State.declined, parseState(" declined "));
    try testing.expectEqual(State.unanswered, parseState(""));
    try testing.expectEqual(State.unanswered, parseState("garbage"));
    inline for (.{ State.accepted, State.declined }) |s| {
        try testing.expectEqual(s, parseState(stateText(s)));
    }
}
