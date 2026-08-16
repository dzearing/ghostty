//! Ghoztty's hook fragment for Claude Code (T868, the win32 half of Mac's
//! `ClaudeHookSpec.swift`). Claude stores hooks in the SHARED
//! `~/.claude/settings.json` (no auto-loaded hooks dir), so Ghoztty merges a
//! fragment under the `hooks` key and tracks ownership by the banner-script
//! invocation signature — never a whole-file marker, because the file is the
//! user's.
//!
//! Ownership signature: any hook element whose deterministic serialization
//! contains our owned hooks DIRECTORY. Deliberately the directory rather
//! than the banner script path — Ghoztty installs a second script there
//! (`ghoztty-activity-state.sh`), and a banner-path signature would leave
//! every activity-state element unrecognized, so uninstall would strand them
//! and `fragmentState` would never report installed. An older banner-only
//! install still matches, since its path is inside this directory.
//!
//! External-plugin detection (`installed_plugins.json`) is deliberately NOT
//! here: it belongs to the registry/factory slice (T869), which is where
//! Mac's factory consumes it.
//!
//! All JSON is `std.json` over `std.json.Value` with the deterministic
//! serializer in `stable_json.zig`; functions expect an ARENA allocator (the
//! parsed/merged values freely alias each other and the input). No OS
//! imports, so the unit tests run in every app-runtime lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

const hook_scripts = @import("hook_scripts.zig");
const hook_spec = @import("hook_spec.zig");
const stable_json = @import("stable_json.zig");
const marker_mod = @import("managed_marker.zig");

pub const InstallState = marker_mod.InstallState;

/// Home-relative path of Claude's shared settings file (forward slashes:
/// `std.fs` accepts them on Windows and the spelling stays platform-neutral).
pub const settings_sub_path = ".claude/settings.json";

/// The ownership signature for a given banner-script path (see module doc).
pub fn signature(banner_script_path: []const u8) []const u8 {
    return hook_scripts.directory(banner_script_path);
}

/// Ghoztty's contribution to the shared `hooks` map: event name → the array
/// of hook elements Ghoztty appends for that event. Each command carries a
/// `timeout` (seconds) so a hook can never stall the agent's turn (Claude
/// reads `timeout`; Copilot uses `timeoutSec`).
pub fn hooksBlock(
    arena: Allocator,
    banner_script_path: []const u8,
) Allocator.Error!std.json.ObjectMap {
    var block = std.json.ObjectMap.init(arena);

    // Banner: the sticky per-pane overlay.
    // Activity: the idle/busy/needs_input state machine. Both run on
    // SessionStart and Stop, in that order, as separate elements — the
    // banner's own matcher is `startup|clear` (a resume keeps its banner),
    // while the activity sweep must run on EVERY session start so a killed
    // session's leaked agent markers are always reaped.
    try block.put("SessionStart", try eventArray(arena, &.{
        .{ .matcher = "startup|clear", .purpose = .session_start },
        .{ .purpose = .activity_session_start },
    }, banner_script_path));
    try block.put("UserPromptSubmit", try eventArray(arena, &.{
        .{ .purpose = .prompt_submit },
    }, banner_script_path));
    // Anything that blocks on the user outranks everything else.
    try block.put("PreToolUse", try eventArray(arena, &.{
        .{ .matcher = "AskUserQuestion|ExitPlanMode", .purpose = .activity_pause },
    }, banner_script_path));
    try block.put("Notification", try eventArray(arena, &.{
        .{ .purpose = .activity_pause },
    }, banner_script_path));
    try block.put("PermissionRequest", try eventArray(arena, &.{
        .{ .purpose = .activity_pause },
    }, banner_script_path));
    // Catch-all: on the main thread this undoes a pause; inside a subagent
    // it only beats that agent's liveness marker.
    try block.put("PostToolUse", try eventArray(arena, &.{
        .{ .purpose = .activity_tool_tick },
    }, banner_script_path));
    try block.put("SubagentStart", try eventArray(arena, &.{
        .{ .purpose = .activity_agent_start },
    }, banner_script_path));
    try block.put("SubagentStop", try eventArray(arena, &.{
        .{ .purpose = .activity_agent_stop },
    }, banner_script_path));
    try block.put("Stop", try eventArray(arena, &.{
        .{ .purpose = .stop },
        .{ .purpose = .activity_settle },
    }, banner_script_path));

    return block;
}

const ElementSpec = struct {
    matcher: ?[]const u8 = null,
    purpose: hook_spec.HookPurpose,
};

/// `[{"matcher": …, "hooks": [{"type":"command", …}]}, …]` for one event.
fn eventArray(
    arena: Allocator,
    specs: []const ElementSpec,
    banner_script_path: []const u8,
) Allocator.Error!std.json.Value {
    var arr = std.json.Array.init(arena);
    for (specs) |spec| {
        var command = std.json.ObjectMap.init(arena);
        try command.put("type", .{ .string = "command" });
        try command.put("command", .{
            .string = try hook_spec.perEventCommand(arena, spec.purpose, banner_script_path, .claude),
        });
        try command.put("timeout", .{ .integer = 10 });

        var hooks_arr = std.json.Array.init(arena);
        try hooks_arr.append(.{ .object = command });

        var element = std.json.ObjectMap.init(arena);
        if (spec.matcher) |m| try element.put("matcher", .{ .string = m });
        try element.put("hooks", .{ .array = hooks_arr });
        try arr.append(.{ .object = element });
    }
    return .{ .array = arr };
}

/// Whether a hook element is one of ours: its deterministic serialization
/// contains the hooks-directory signature.
fn isOurs(arena: Allocator, element: std.json.Value, sig: []const u8) Allocator.Error!bool {
    const serialized = try stable_json.compactAlloc(arena, element);
    return std.mem.indexOf(u8, serialized, sig) != null;
}

/// Merge Ghoztty's hooks into the user's shared settings WITHOUT clobbering
/// their own hooks. Only Ghoztty's events are touched, and within each only
/// prior Ghoztty elements (matched by the signature) are replaced — every
/// other event and every non-Ghoztty element is preserved. Returns the
/// updated root value (arena semantics: input and output alias freely).
pub fn merge(
    arena: Allocator,
    base: std.json.Value,
    banner_script_path: []const u8,
) Allocator.Error!std.json.Value {
    var root = switch (base) {
        .object => |o| o,
        // The component refuses non-object files before calling; a fresh
        // object here keeps the function total for tests.
        else => std.json.ObjectMap.init(arena),
    };
    var hooks: std.json.ObjectMap = hooks: {
        if (root.get("hooks")) |existing| switch (existing) {
            .object => |o| break :hooks o,
            else => {},
        };
        break :hooks std.json.ObjectMap.init(arena);
    };

    const sig = signature(banner_script_path);
    var block = try hooksBlock(arena, banner_script_path);
    for (block.keys(), block.values()) |event, want| {
        var arr = std.json.Array.init(arena);
        if (hooks.get(event)) |existing| switch (existing) {
            .array => |a| for (a.items) |element| {
                if (!try isOurs(arena, element, sig)) try arr.append(element);
            },
            else => {},
        };
        for (want.array.items) |element| try arr.append(element);
        try hooks.put(event, .{ .array = arr });
    }

    try root.put("hooks", .{ .object = hooks });
    return .{ .object = root };
}

/// Remove ONLY Ghoztty's own elements (matched by signature) from every
/// event, pruning an event key that becomes empty and the whole `hooks` map
/// if it becomes empty. The user's other events and elements are left intact.
pub fn removeFragment(
    arena: Allocator,
    base: std.json.Value,
    banner_script_path: []const u8,
) Allocator.Error!std.json.Value {
    var root = switch (base) {
        .object => |o| o,
        else => return base,
    };
    var hooks: std.json.ObjectMap = hooks: {
        if (root.get("hooks")) |existing| switch (existing) {
            .object => |o| break :hooks o,
            else => return .{ .object = root },
        };
        return .{ .object = root };
    };

    const sig = signature(banner_script_path);
    // Snapshot the key list: removal mutates the map we would be iterating.
    const events = try arena.dupe([]const u8, hooks.keys());
    for (events) |event| {
        const value = hooks.get(event) orelse continue;
        const a = switch (value) {
            .array => |a| a,
            else => continue,
        };
        var kept = std.json.Array.init(arena);
        for (a.items) |element| {
            if (!try isOurs(arena, element, sig)) try kept.append(element);
        }
        if (kept.items.len == 0) {
            _ = hooks.orderedRemove(event);
        } else {
            try hooks.put(event, .{ .array = kept });
        }
    }

    if (hooks.count() == 0) {
        _ = root.orderedRemove("hooks");
    } else {
        try root.put("hooks", .{ .object = hooks });
    }
    return .{ .object = root };
}

/// State of ONLY Ghoztty's fragment: collect the Ghoztty elements (by
/// signature) from our events and compare them as sets against what we would
/// install. The user's other hooks vary and are never part of the compare.
pub fn fragmentState(
    arena: Allocator,
    base: std.json.Value,
    banner_script_path: []const u8,
) Allocator.Error!InstallState {
    const root = switch (base) {
        .object => |o| o,
        else => return .not_installed,
    };
    const hooks: ?std.json.ObjectMap = hooks: {
        if (root.get("hooks")) |existing| switch (existing) {
            .object => |o| break :hooks o,
            else => {},
        };
        break :hooks null;
    };

    const sig = signature(banner_script_path);
    var found = false;
    var matches = true;
    var block = try hooksBlock(arena, banner_script_path);
    for (block.keys(), block.values()) |event, want| {
        var have: std.ArrayList([]const u8) = .empty;
        if (hooks) |h| if (h.get(event)) |existing| switch (existing) {
            .array => |a| for (a.items) |element| {
                const serialized = try stable_json.compactAlloc(arena, element);
                if (std.mem.indexOf(u8, serialized, sig) != null)
                    try have.append(arena, serialized);
            },
            else => {},
        };
        if (have.items.len > 0) found = true;

        var want_serialized: std.ArrayList([]const u8) = .empty;
        for (want.array.items) |element| {
            try want_serialized.append(arena, try stable_json.compactAlloc(arena, element));
        }
        if (!setEqual(want_serialized.items, have.items)) matches = false;
    }

    if (!found) return .not_installed;
    return if (matches) .installed else .outdated;
}

/// Set equality over serialized elements (duplicates collapse, order
/// irrelevant), matching Mac's `Set` compare.
fn setEqual(a: []const []const u8, b: []const []const u8) bool {
    return subset(a, b) and subset(b, a);
}

fn subset(a: []const []const u8, b: []const []const u8) bool {
    outer: for (a) |needle| {
        for (b) |candidate| {
            if (std.mem.eql(u8, needle, candidate)) continue :outer;
        }
        return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// Tests — mirroring Mac's ClaudeHookSpecTests (minus the external-plugin
// coverage, which moves to T869 with the code it tests).
// -----------------------------------------------------------------------------

const testing = std.testing;

const test_banner = "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh";

fn parse(alloc: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
}

fn emptyObject(alloc: Allocator) std.json.Value {
    return .{ .object = std.json.ObjectMap.init(alloc) };
}

fn hooksOf(v: std.json.Value) ?std.json.ObjectMap {
    const root = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const h = root.get("hooks") orelse return null;
    return switch (h) {
        .object => |o| o,
        else => null,
    };
}

test "merged fragment carries a 10s timeout on every command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, emptyObject(alloc), test_banner);
    const hooks = hooksOf(merged).?;
    for (hooks.keys(), hooks.values()) |event, value| {
        _ = event;
        var commands: usize = 0;
        for (value.array.items) |element| {
            const inner = element.object.get("hooks").?.array;
            for (inner.items) |command| {
                commands += 1;
                try testing.expectEqual(@as(i64, 10), command.object.get("timeout").?.integer);
            }
        }
        try testing.expect(commands > 0);
    }
}

test "merged fragment registers every activity-state event with its verb" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, emptyObject(alloc), test_banner);
    const hooks = hooksOf(merged).?;
    const activity_path = try hook_scripts.activityStatePath(alloc, test_banner);

    const cases = [_]struct { event: []const u8, verb: []const u8 }{
        .{ .event = "SessionStart", .verb = "session-start" },
        .{ .event = "PreToolUse", .verb = "pause" },
        .{ .event = "Notification", .verb = "pause" },
        .{ .event = "PermissionRequest", .verb = "pause" },
        .{ .event = "PostToolUse", .verb = "tool-tick" },
        .{ .event = "SubagentStart", .verb = "agent-start" },
        .{ .event = "SubagentStop", .verb = "agent-stop" },
        .{ .event = "Stop", .verb = "settle" },
    };
    for (cases) |case| {
        const text = try stable_json.compactAlloc(alloc, hooks.get(case.event).?);
        try testing.expect(std.mem.indexOf(u8, text, activity_path) != null);
        const with_runtime = try std.fmt.allocPrint(alloc, "{s} --runtime=claude", .{case.verb});
        try testing.expect(std.mem.indexOf(u8, text, with_runtime) != null);
    }
}

test "PreToolUse pauses only for user-blocking tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, emptyObject(alloc), test_banner);
    const elements = hooksOf(merged).?.get("PreToolUse").?.array;
    try testing.expectEqual(@as(usize, 1), elements.items.len);
    try testing.expectEqualStrings(
        "AskUserQuestion|ExitPlanMode",
        elements.items[0].object.get("matcher").?.string,
    );
}

test "activity-state elements are owned by the directory signature and fully removed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, emptyObject(alloc), test_banner);
    try testing.expectEqual(InstallState.installed, try fragmentState(alloc, merged, test_banner));

    const removed = try removeFragment(alloc, merged, test_banner);
    const text = try stable_json.compactAlloc(alloc, removed);
    try testing.expect(std.mem.indexOf(u8, text, "ghoztty-activity-state.sh") == null);
    try testing.expect(removed.object.get("hooks") == null);
}

test "a banner-only install is outdated, not installed and not absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const banner_only = try parse(alloc,
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command",
        \\"command":"bash '/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh' stop-hook --runtime=claude",
        \\"timeout":10}]}]}}
    );
    try testing.expectEqual(InstallState.outdated, try fragmentState(alloc, banner_only, test_banner));
}

test "merge preserves unrelated keys and is detectable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, try parse(alloc,
        \\{"theme":"dark","model":"opus"}
    ), test_banner);
    try testing.expectEqualStrings("dark", merged.object.get("theme").?.string);
    try testing.expectEqualStrings("opus", merged.object.get("model").?.string);
    try testing.expectEqual(InstallState.installed, try fragmentState(alloc, merged, test_banner));
}

test "removeFragment leaves the rest and reads not_installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, try parse(alloc,
        \\{"theme":"dark"}
    ), test_banner);
    const removed = try removeFragment(alloc, merged, test_banner);
    try testing.expectEqualStrings("dark", removed.object.get("theme").?.string);
    try testing.expectEqual(InstallState.not_installed, try fragmentState(alloc, removed, test_banner));
}

test "merge preserves the user's own PreToolUse hooks alongside ours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, try parse(alloc,
        \\{"theme":"dark","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}
    ), test_banner);
    const hooks = hooksOf(merged).?;
    const pretool = try stable_json.compactAlloc(alloc, hooks.get("PreToolUse").?);
    try testing.expect(std.mem.indexOf(u8, pretool, "echo mine") != null);
    try testing.expect(hooks.get("SessionStart") != null);
    try testing.expect(hooks.get("UserPromptSubmit") != null);
    try testing.expect(hooks.get("Stop") != null);
    try testing.expectEqual(InstallState.installed, try fragmentState(alloc, merged, test_banner));
}

test "removeFragment drops only Ghoztty's entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, try parse(alloc,
        \\{"theme":"dark","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}
    ), test_banner);
    const removed = try removeFragment(alloc, merged, test_banner);
    try testing.expectEqualStrings("dark", removed.object.get("theme").?.string);
    const hooks = hooksOf(removed).?;
    const pretool = try stable_json.compactAlloc(alloc, hooks.get("PreToolUse").?);
    try testing.expect(std.mem.indexOf(u8, pretool, "echo mine") != null);
    try testing.expect(hooks.get("SessionStart") == null);
    try testing.expect(hooks.get("UserPromptSubmit") == null);
    try testing.expect(hooks.get("Stop") == null);
    try testing.expectEqual(InstallState.not_installed, try fragmentState(alloc, removed, test_banner));
}

test "a user's own SessionStart element survives install and uninstall" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try merge(alloc, try parse(alloc,
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user-start"}]}]}}
    ), test_banner);
    const merged_ss = hooksOf(merged).?.get("SessionStart").?.array;
    // The user's one element, plus Ghoztty's two: the banner (matched to
    // `startup|clear`) and the activity-state sweep (every session start).
    try testing.expectEqual(@as(usize, 3), merged_ss.items.len);
    const merged_text = try stable_json.compactAlloc(alloc, .{ .array = merged_ss });
    try testing.expect(std.mem.indexOf(u8, merged_text, "echo user-start") != null);
    try testing.expect(std.mem.indexOf(u8, merged_text, test_banner) != null);
    try testing.expectEqual(InstallState.installed, try fragmentState(alloc, merged, test_banner));

    const removed = try removeFragment(alloc, merged, test_banner);
    const removed_ss = hooksOf(removed).?.get("SessionStart").?.array;
    try testing.expectEqual(@as(usize, 1), removed_ss.items.len);
    const removed_text = try stable_json.compactAlloc(alloc, .{ .array = removed_ss });
    try testing.expect(std.mem.indexOf(u8, removed_text, "echo user-start") != null);
    try testing.expect(std.mem.indexOf(u8, removed_text, test_banner) == null);
}

test "reinstall over a stale fragment replaces rather than duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // An older install whose Stop event carried only the banner command.
    const stale = try parse(alloc,
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command",
        \\"command":"bash '/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh' stop-hook --runtime=claude",
        \\"timeout":10}]}]}}
    );
    const merged = try merge(alloc, stale, test_banner);
    // Stop holds exactly the CURRENT two elements — the stale one is gone.
    try testing.expectEqual(@as(usize, 2), hooksOf(merged).?.get("Stop").?.array.items.len);
    try testing.expectEqual(InstallState.installed, try fragmentState(alloc, merged, test_banner));
}
