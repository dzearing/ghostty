//! Ghoztty's dedicated hook file for Copilot CLI (T868, the win32 half of
//! Mac's `CopilotHookSpec.swift`). Copilot auto-loads every JSON in
//! `~/.copilot/hooks/`, so Ghoztty owns a dedicated file: version-1
//! envelope, `_comment` carrying the ownership marker, camelCase event
//! names, `"bash"` command key, `"timeoutSec"` timeouts.
//!
//! The activity-state machine (idle/busy/needs_input) is deliberately only
//! PARTIALLY wired here, and the missing half is a known gap rather than an
//! oversight. Claude registers six more events for it — PreToolUse,
//! PostToolUse, Notification, PermissionRequest, SubagentStart,
//! SubagentStop — and Copilot's equivalents (if any) are not known: its
//! event vocabulary is not documented in `copilot help config`, and the CLI
//! ships as a compressed single-file executable, so the three names below
//! are the ones empirically verified against a live Copilot hook (on the Mac
//! seat). Guessing at the rest would write events that silently never fire,
//! which is worse than not writing them: the pane would look wired up while
//! reporting stale state.
//!
//! What IS wired: `sessionStart` sweeps leaked agent markers, and
//! `agentStop` settles the pane. Without the subagent events there is
//! nothing to track, so settle resolves to idle, and without a pause event
//! needs_input is never raised here. Both are correct-if-incomplete rather
//! than wrong.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

const hook_spec = @import("hook_spec.zig");
const stable_json = @import("stable_json.zig");
const marker_mod = @import("managed_marker.zig");

/// The ownership marker embedded as `_comment`, which is what makes the
/// rendered file pass the managed-file guard.
pub const marker = marker_mod.token;

/// Home-relative path of the dedicated hook file.
pub const hook_file_sub_path = ".copilot/hooks/ghoztty.json";

/// The whole rendered hook file, deterministically serialized (sorted keys,
/// pretty) so reinstall is byte-stable and the install-state compare works.
pub fn renderedFile(
    arena: Allocator,
    banner_script_path: []const u8,
) Allocator.Error![]u8 {
    var hooks = std.json.ObjectMap.init(arena);
    try hooks.put("sessionStart", try eventArray(arena, &.{
        .session_start, .activity_session_start,
    }, banner_script_path));
    try hooks.put("userPromptSubmitted", try eventArray(arena, &.{
        .prompt_submit,
    }, banner_script_path));
    try hooks.put("agentStop", try eventArray(arena, &.{
        .stop, .activity_settle,
    }, banner_script_path));

    var root = std.json.ObjectMap.init(arena);
    try root.put("version", .{ .integer = 1 });
    try root.put("_comment", .{ .string = marker });
    try root.put("hooks", .{ .object = hooks });

    return stable_json.prettyAlloc(arena, .{ .object = root });
}

/// Copilot's event arrays hold command objects DIRECTLY (no Claude-style
/// `{"hooks": […]}` wrapper elements and no matchers).
fn eventArray(
    arena: Allocator,
    purposes: []const hook_spec.HookPurpose,
    banner_script_path: []const u8,
) Allocator.Error!std.json.Value {
    var arr = std.json.Array.init(arena);
    for (purposes) |purpose| {
        var command = std.json.ObjectMap.init(arena);
        try command.put("type", .{ .string = "command" });
        try command.put("bash", .{
            .string = try hook_spec.perEventCommand(arena, purpose, banner_script_path, .copilot),
        });
        try command.put("timeoutSec", .{ .integer = 10 });
        try arr.append(.{ .object = command });
    }
    return .{ .array = arr };
}

// -----------------------------------------------------------------------------
// Tests — mirroring Mac's CopilotHookSpecTests.
// -----------------------------------------------------------------------------

const testing = std.testing;

const test_banner = "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh";

test "renders camelCase events, the marker, and no jq or pipes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try renderedFile(alloc, test_banner);
    try testing.expect(std.mem.indexOf(u8, file, "\"sessionStart\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"userPromptSubmitted\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"agentStop\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"version\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, marker) != null);
    // No embedded payload normalizer: the script parses stdin itself.
    try testing.expect(std.mem.indexOf(u8, file, "jq ") == null);
    try testing.expect(std.mem.indexOf(u8, file, "awk") == null);
    try testing.expect(std.mem.indexOf(u8, file, " | ") == null);
}

test "golden: the rendered file matches the Mac schema exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try renderedFile(alloc, "/x/hooks/ghoztty-banner.sh");
    try testing.expectEqualStrings(
        \\{
        \\  "_comment": "ghoztty-managed",
        \\  "hooks": {
        \\    "agentStop": [
        \\      {
        \\        "bash": "bash '/x/hooks/ghoztty-banner.sh' stop-hook --runtime=copilot",
        \\        "timeoutSec": 10,
        \\        "type": "command"
        \\      },
        \\      {
        \\        "bash": "bash '/x/hooks/ghoztty-activity-state.sh' settle --runtime=copilot",
        \\        "timeoutSec": 10,
        \\        "type": "command"
        \\      }
        \\    ],
        \\    "sessionStart": [
        \\      {
        \\        "bash": "bash '/x/hooks/ghoztty-banner.sh' session-start-hook --runtime=copilot",
        \\        "timeoutSec": 10,
        \\        "type": "command"
        \\      },
        \\      {
        \\        "bash": "bash '/x/hooks/ghoztty-activity-state.sh' session-start --runtime=copilot",
        \\        "timeoutSec": 10,
        \\        "type": "command"
        \\      }
        \\    ],
        \\    "userPromptSubmitted": [
        \\      {
        \\        "bash": "bash '/x/hooks/ghoztty-banner.sh' prompt-hook --runtime=copilot",
        \\        "timeoutSec": 10,
        \\        "type": "command"
        \\      }
        \\    ]
        \\  },
        \\  "version": 1
        \\}
        \\
    , file);
}

test "rendered file is valid JSON that round-trips to the expected structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = try renderedFile(alloc, test_banner);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, file, .{});
    try testing.expectEqual(@as(i64, 1), root.object.get("version").?.integer);
    try testing.expectEqualStrings(marker, root.object.get("_comment").?.string);

    const hooks = root.object.get("hooks").?.object;
    const prompt = hooks.get("userPromptSubmitted").?.array;
    try testing.expectEqual(@as(usize, 1), prompt.items.len);
    const expected_command = try hook_spec.perEventCommand(alloc, .prompt_submit, test_banner, .copilot);
    try testing.expectEqualStrings(expected_command, prompt.items[0].object.get("bash").?.string);
    try testing.expectEqual(@as(i64, 10), prompt.items[0].object.get("timeoutSec").?.integer);
}

test "rendering twice is byte-identical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try renderedFile(alloc, test_banner);
    const b = try renderedFile(alloc, test_banner);
    try testing.expectEqualStrings(a, b);
}
