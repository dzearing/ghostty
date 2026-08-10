//! The `ghoztty-agent` LINEAGE suffix — one env var that gives a sandboxed
//! agent an identity of its own everywhere the lineage is spelled out.
//!
//! ## Why (T167)
//! The agent takes a per-user, per-lineage single-instance guard (a named
//! mutex; `single_instance.zig`), and the lineage is a COMPILE-TIME fact:
//! `local` for a release build, `local-debug` for a debug one. So a debug
//! agent already running on the box refuses every other debug agent — exit 183,
//! "another instance is already running" — no matter how isolated the second
//! one's state is. A test sandbox with its own `LOCALAPPDATA`, its own agent
//! binary and even its own `USERNAME`-derived pipe name still ends up with **no
//! agent at all**, and the app then falls back to non-persistent panes silently
//! (`sharedConnection` answers null on a failed resolve, by design). Measured
//! 2026-07-29 building `upgrade-no-fork.ps1`: every sandbox run came up with an
//! empty `local-agent-debug\` until the box's leftover zig-out agent was
//! killed. The failure is the dangerous kind — a suite that does not kill the
//! incumbent does not go red, it quietly exercises the NON-persistent path
//! while reporting on persistence.
//!
//! `GHOZTTY_AGENT_INSTANCE=<suffix>` names a distinct lineage:
//!
//!   - the agent's single-instance mutex / lock file / heartbeat file
//!     (`single_instance.composeInstanceKey`),
//!   - the app's local-agent state dir (`local-agent-debug-<suffix>`) and pipe
//!     name (`\\.\pipe\ghoztty-agent-debug-<suffix>-<user>`),
//!   - the HKCU Run autostart value name, so a forced-autostart sandbox can
//!     never clobber the real entry,
//!   - and `+sessions`, so the CLI inside a sandbox reads that sandbox's agent.
//!
//! ONE knob, every derivation — because the trap this exists to remove is
//! precisely a sandbox that is half isolated. Two sandboxes with different
//! suffixes coexist with each other AND with the user's real agents; unset (the
//! only production value) reproduces every legacy name byte for byte.
//!
//! ## Not a security boundary
//! The suffix is a NAMING device for test isolation. The owner-only pipe DACL
//! and the per-user mutex/SID suffix are what keep users apart, and neither is
//! affected by this. A hostile value can at worst name an odd-looking object
//! inside the caller's own namespace — `sanitize` still whitelists, so it can
//! never smuggle a path separator into a filename or a `\` into a mutex name.

const std = @import("std");

/// The env var. Read by the agent (its guard), by the win32 app (state dir,
/// pipe, autostart value) and by `+sessions` (state dir).
pub const env_var = "GHOZTTY_AGENT_INSTANCE";

/// Longest suffix honored. Everything downstream is a fixed-size buffer (a
/// mutex name next to a SID, a filename, a pipe path), and a caller who needs
/// more than this is naming something else. Over-long values are REJECTED
/// rather than truncated: two sandboxes whose suffixes differ only past the cap
/// would silently share one lineage, which is the exact bug this module exists
/// to remove.
pub const max_len: usize = 24;

/// Sanitize a raw suffix into `buf`. Whitelist: ASCII alphanumerics plus
/// `-`, `.` and `_`; every other byte becomes `_`. Leading/trailing ASCII
/// whitespace is trimmed first (a value that arrived from a shell script is
/// routinely padded).
///
/// Returns null — meaning "no suffix, use the legacy names" — when the value is
/// empty/whitespace or longer than `max_len`. `buf` must be at least `max_len`
/// bytes.
pub fn sanitize(buf: []u8, raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_len) return null;
    if (buf.len < trimmed.len) return null;
    for (trimmed, 0..) |c, i| {
        buf[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_' => c,
            else => '_',
        };
    }
    return buf[0..trimmed.len];
}

/// `sanitize` of the process environment's `GHOZTTY_AGENT_INSTANCE`. Null when
/// unset, empty, or unusable — i.e. in every production run. `buf` must be at
/// least `max_len` bytes.
///
/// Deliberately env-var based rather than a flag: the suffix has to reach a
/// process nobody on the harness side spawns directly (the app spawns the
/// agent, and the agent is what takes the guard), and an inherited environment
/// block is the one channel that already spans that hop.
pub fn fromEnv(buf: []u8) ?[]const u8 {
    var raw_buf: [max_len + 64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&raw_buf);
    const raw = std.process.getEnvVarOwned(fba.allocator(), env_var) catch return null;
    return sanitize(buf, raw);
}

/// Append `[-<suffix>]` to a lineage base name, into `buf`. An absent suffix
/// reproduces `base` verbatim (no trailing separator) — the production path.
/// An EMPTY base yields the bare suffix, so the legacy empty-key instance
/// (relay) still composes a single clean segment.
pub fn appendSuffix(buf: []u8, base: []const u8, suffix: ?[]const u8) error{NameTooLong}![]const u8 {
    const s = suffix orelse {
        if (buf.len < base.len) return error.NameTooLong;
        @memcpy(buf[0..base.len], base);
        return buf[0..base.len];
    };
    const sep: usize = if (base.len == 0 or s.len == 0) 0 else 1;
    const total = base.len + sep + s.len;
    if (buf.len < total) return error.NameTooLong;
    @memcpy(buf[0..base.len], base);
    if (sep == 1) buf[base.len] = '-';
    @memcpy(buf[base.len + sep ..][0..s.len], s);
    return buf[0..total];
}

test "sanitize: whitelist keeps safe names verbatim" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings("sbx1", sanitize(&buf, "sbx1").?);
    try std.testing.expectEqualStrings("no-fork.2_A", sanitize(&buf, "no-fork.2_A").?);
    try std.testing.expectEqualStrings("12345", sanitize(&buf, "  12345\r\n").?);
}

test "sanitize: a hostile value can never smuggle a separator" {
    // The suffix lands in a FILENAME, a mutex name and a pipe path. Any of
    // '\\', '/', ':' would redirect one of those somewhere else entirely.
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings("a_b_c_d", sanitize(&buf, "a\\b/c:d").?);
    // Dots survive (they are legal in every target namespace); the separator
    // and the control bytes do not, so `..\` can never climb a directory.
    try std.testing.expectEqualStrings(".._evil__", sanitize(&buf, "..\\evil\x01\x02").?);
    const s = sanitize(&buf, "x*?\"<>|y").?;
    try std.testing.expectEqualStrings("x______y", s);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfAny(u8, s, "\\/:*?\"<>|"));
}

test "sanitize: empty and over-long are rejected (never truncated)" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), sanitize(&buf, ""));
    try std.testing.expectEqual(@as(?[]const u8, null), sanitize(&buf, "   \t "));
    // Truncation would silently merge two distinct sandboxes into one lineage.
    const long = "a" ** (max_len + 1);
    try std.testing.expectEqual(@as(?[]const u8, null), sanitize(&buf, long));
    const at_cap = "b" ** max_len;
    try std.testing.expectEqualStrings(at_cap, sanitize(&buf, at_cap).?);
}

test "appendSuffix: absent suffix reproduces the legacy name byte for byte" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("local-agent", try appendSuffix(&buf, "local-agent", null));
    try std.testing.expectEqualStrings("local-debug", try appendSuffix(&buf, "local-debug", null));
    try std.testing.expectEqualStrings("", try appendSuffix(&buf, "", null));
}

test "appendSuffix: a suffix adds exactly one separated segment" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("local-debug-sbx1", try appendSuffix(&buf, "local-debug", "sbx1"));
    try std.testing.expectEqualStrings("local-agent-sbx1", try appendSuffix(&buf, "local-agent", "sbx1"));
    // Empty base (the relay instance's legacy empty key) stays one segment.
    try std.testing.expectEqualStrings("sbx1", try appendSuffix(&buf, "", "sbx1"));
}

test "appendSuffix: overflow errors instead of truncating" {
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, appendSuffix(&tiny, "local-debug", "sbx1"));
    try std.testing.expectError(error.NameTooLong, appendSuffix(&tiny, "local-debug", null));
}

test "distinct suffixes yield distinct names (the whole point)" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const one = try appendSuffix(&a, "local-debug", "sbx1");
    const two = try appendSuffix(&b, "local-debug", "sbx2");
    try std.testing.expect(!std.mem.eql(u8, one, two));
}
