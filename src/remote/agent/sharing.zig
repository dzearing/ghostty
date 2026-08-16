//! Sharing (relay-uplink) state for the consolidated local agent (T546).
//!
//! The one-installer plan (docs/design/one-installer-agent-consolidation.md)
//! folds the relay uplink into the session-persistence agent: ONE process
//! serves the local pipe/unix socket AND, when the user has flipped "Share
//! this machine", the relay — over the same persisted `SessionStore`.
//!
//! Whether the uplink should be up is PERSISTED AGENT-SIDE, in a small
//! `sharing.json` next to the agent's `sessions.json` (the agent state dir):
//! the app's Run-key / LaunchAgent command line stays exactly the local
//! composition (`--listen-pipe`/`--listen-unix`), and the agent decides at
//! startup — and hot, via the same poll-the-file pattern `relay_creds.zig`
//! already uses — whether to raise the uplink. Enabling sharing never needs a
//! Run-key rewrite, and the config's location inherits the agent state dir's
//! debug/release isolation (a debug agent never reads the release box's flag
//! and fights it for the device token).
//!
//! The relay credential is NOT here: `relay.env` (RELAY_BASE + DEVICE_TOKEN,
//! see `enroll.zig`) stays the single source for where to dial and as whom.
//! This file is only the per-machine "should the local agent serve" switch —
//! kept separate precisely so signing in to REACH other machines never
//! implies serving this one (decision 3, D22: sharing is opt-in).
//!
//! Everything here is pure config logic (path resolution, lenient parse,
//! atomic save, the raise/park decision) so it unit-tests in the `test-agent`
//! lane on any host; the thread that acts on it lives in `main.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic_write = @import("atomic_write.zig");

/// File name, beside `sessions.json` in the agent state dir.
pub const file_name = "sharing.json";

/// Parsed sharing state. Additive evolution only (agent-contract rules): new
/// fields get defaults, unknown fields are ignored on read.
pub const Config = struct {
    enabled: bool = false,
};

/// Resolve the sharing config path:
///   1. `GHOSTTY_SHARING_CONFIG` (explicit full-path override; tests use this),
///   2. beside the agent's `--sessions-file` (the agent state dir),
///   3. null — no persistence dir means no sharing (a bare dev invocation).
/// Owned by the caller (or null).
pub fn pathFor(alloc: Allocator, sessions_file: ?[]const u8) ?[]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_SHARING_CONFIG")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}
    const sf = sessions_file orelse return null;
    const dir = std.fs.path.dirname(sf) orelse return null;
    return std.fs.path.join(alloc, &.{ dir, file_name }) catch null;
}

/// Parse `sharing.json` content. LENIENT by design: any malformed content
/// reads as the safe default (disabled) — a corrupt flag file must never
/// raise an uplink the user did not ask for, and never kill the daemon.
pub fn parse(alloc: Allocator, content: []const u8) Config {
    const parsed = std.json.parseFromSlice(
        Config,
        alloc,
        content,
        .{ .ignore_unknown_fields = true },
    ) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

/// Load the config at `path`. Absent or unreadable → default (disabled).
pub fn load(alloc: Allocator, path: []const u8) Config {
    const content = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return .{};
    defer alloc.free(content);
    return parse(alloc, content);
}

/// Persist `cfg` at `path`, atomically (tmp + rename via `atomic_write`, the
/// same durability rules as sessions.json). The app-side toggle (T547/T548)
/// writes the same shape.
pub fn save(alloc: Allocator, path: []const u8, cfg: Config) !void {
    var buf: [64]u8 = undefined;
    const content = try std.fmt.bufPrint(
        &buf,
        "{{\"version\":1,\"enabled\":{s}}}\n",
        .{if (cfg.enabled) "true" else "false"},
    );
    try atomic_write.writeChunks(alloc, path, &.{content}, .{});
}

/// What the uplink controller should do about the current state. Pure, so the
/// policy is unit-testable apart from the threads that act on it.
pub const Action = enum {
    /// Sharing is on and a credential exists: the uplink should be up.
    raise,
    /// Sharing is off: the uplink should be down (parked if already built).
    park,
    /// Sharing is on but there is no relay credential to dial with: stay
    /// down and say why once — the enrollment (chooser toggle, T547/T548)
    /// writes relay.env first, so this is the "hand-edited flag" case.
    unavailable,
};

pub fn decide(enabled: bool, has_credential: bool) Action {
    if (!enabled) return .park;
    return if (has_credential) .raise else .unavailable;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "decide: disabled parks regardless of credential" {
    try testing.expectEqual(Action.park, decide(false, false));
    try testing.expectEqual(Action.park, decide(false, true));
}

test "decide: enabled raises only with a credential" {
    try testing.expectEqual(Action.raise, decide(true, true));
    try testing.expectEqual(Action.unavailable, decide(true, false));
}

test "parse: round-trips enabled and disabled" {
    try testing.expect(parse(testing.allocator, "{\"version\":1,\"enabled\":true}").enabled);
    try testing.expect(!parse(testing.allocator, "{\"version\":1,\"enabled\":false}").enabled);
}

test "parse: malformed or empty content is the safe default" {
    try testing.expect(!parse(testing.allocator, "").enabled);
    try testing.expect(!parse(testing.allocator, "not json at all").enabled);
    try testing.expect(!parse(testing.allocator, "{\"enabled\":\"yes\"}").enabled);
    try testing.expect(!parse(testing.allocator, "[]").enabled);
}

test "parse: unknown fields are ignored (additive evolution)" {
    try testing.expect(parse(
        testing.allocator,
        "{\"version\":9,\"enabled\":true,\"future\":{\"nested\":1}}",
    ).enabled);
}

test "parse: missing enabled field defaults to disabled" {
    try testing.expect(!parse(testing.allocator, "{\"version\":1}").enabled);
}

test "pathFor: beside the sessions file" {
    const p = pathFor(testing.allocator, "/state/dir/sessions.json") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(p);
    try testing.expect(std.mem.endsWith(u8, p, file_name));
    try testing.expect(std.mem.indexOf(u8, p, "dir") != null);
}

test "pathFor: no sessions file means no sharing" {
    try testing.expectEqual(@as(?[]u8, null), pathFor(testing.allocator, null));
}

test "save + load: round-trip through a real file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);
    const cfg_path = try std.fs.path.join(testing.allocator, &.{ path, file_name });
    defer testing.allocator.free(cfg_path);

    try save(testing.allocator, cfg_path, .{ .enabled = true });
    try testing.expect(load(testing.allocator, cfg_path).enabled);

    try save(testing.allocator, cfg_path, .{ .enabled = false });
    try testing.expect(!load(testing.allocator, cfg_path).enabled);
}

test "load: absent file is the safe default" {
    try testing.expect(!load(testing.allocator, "/definitely/not/a/real/dir/sharing.json").enabled);
}
