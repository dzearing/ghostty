//! Pure logic for the agent-integration setup flow (T71, rewired by T870):
//! the persisted one-time-answer grammar shared by the first-run and
//! plugin-migration prompts, and the failure-detail tail for CLI output. No
//! OS imports, so the unit tests run in every app-runtime lane (the
//! hero_math/dim_math pattern). Process spawning, the prompts, and the
//! state files live in AgentIntegration.zig.
//!
//! The T71 plugin-install vocabulary (marketplace/plugin ids, step parsing,
//! outcome merge, registry sniffing) was retired with the flow it served:
//! the app installs its own integration now (`agent_integration_service`),
//! and the only remaining `claude` invocation is the migration's uninstall.
const std = @import("std");

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

/// A persisted one-time answer. `declined` is written just before a prompt
/// is shown (so a crash mid-dialog never re-nags) and overwritten with
/// `accepted` when the user says yes — Mac's promptAnswered/installAccepted
/// pair collapsed into one file.
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

test "detailTail: trims, caps, respects UTF-8 boundaries" {
    const testing = std.testing;
    try testing.expectEqualStrings("short", detailTail("  short \r\n", 300));
    try testing.expectEqualStrings("cdef", detailTail("abcdef", 4));

    // A 2-byte codepoint straddling the cap is dropped, not split.
    const s = "aé"; // 'a' + 0xC3 0xA9
    try testing.expectEqualStrings("\xC3\xA9", detailTail(s, 2));
    try testing.expectEqualStrings("", detailTail("é", 1));
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
