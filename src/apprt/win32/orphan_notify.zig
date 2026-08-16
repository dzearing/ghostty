//! Long-unattached ("forgotten") session notification policy — T534, pure.
//!
//! The agent keeps a live session forever once it is pinned, and since T520 the
//! chooser marks the ones no window holds — but both are pull: the user has to
//! go looking. This module decides when the app should PUSH: a live session
//! continuously unattached past a generous threshold earns one tray balloon
//! naming it, whose click opens the machine chooser where the resolve verbs
//! (Resume, Kill) already live. Ignoring or dismissing the balloon IS the
//! "Keep" resolution: nothing is ever unpinned, reaped or altered here — the
//! only output of this policy is whether to say something.
//!
//! Suppression is per EPISODE, not per session: an episode is (session id,
//! the `unattached_since` instant the agent reported). The agent clears
//! `unattached_since` on every ATTACH, so a session the user resumed and later
//! lost again is a NEW episode and may be announced again; the same episode is
//! re-announced only after a long re-notify interval. The stamps are persisted
//! by the caller (`orphan-notify[-debug].json`) so an app restart does not
//! re-nag about an episode the user already dismissed.
//!
//! No OS imports, no clock reads, no IO — the caller feeds the roster, the
//! stamps and "now", and asserts everything here in the `none` lane.

const std = @import("std");

/// How long a session must be continuously unattached before it is worth a
/// notification. Generous on purpose: the point is discovering a forgotten
/// session, not policing a briefly-detached one (D18: no config knob — a
/// hard-coded threshold with a test-only env override).
pub const default_notify_after_ms: i64 = 24 * std.time.ms_per_hour;

/// How long a dismissed ("kept") episode stays quiet before it may be
/// mentioned again. A week: long enough to not nag, short enough that a
/// genuinely forgotten session resurfaces.
pub const default_renotify_after_ms: i64 = 7 * 24 * std.time.ms_per_hour;

/// How often the app re-reads the local roster to evaluate this policy.
pub const default_check_interval_ms: u32 = 15 * std.time.ms_per_min;

/// One roster row, reduced to what the policy reads. `unattached_since` is the
/// agent's additive T534 field: null from an attached row, a dead row, or an
/// OLDER AGENT that never heard of it — and null is always "not eligible", so
/// the old-agent skew degrades to exactly the pre-T534 silence.
pub const Row = struct {
    id: []const u8,
    alive: bool = true,
    attached: bool = false,
    unattached_since: ?i64 = null,
};

/// One "the user was told" receipt, keyed by episode.
pub const Stamp = struct {
    id: []const u8,
    unattached_since: i64,
    notified_at: i64,
};

/// The persisted stamp file's shape (JSON). Kept here so the reader, the
/// writer and the tests cannot drift.
pub const StampFile = struct {
    stamps: []const Stamp = &.{},
};

/// What one evaluation of the roster concluded.
pub const Decision = struct {
    /// Index (into the rows given) of the session to announce — the
    /// LONGEST-unattached eligible one — or null for "say nothing".
    announce: ?usize = null,
    /// Total eligible sessions this pass (the announced one included), for
    /// an "…and N more" suffix.
    eligible: usize = 0,
};

fn findStamp(stamps: []const Stamp, id: []const u8) ?Stamp {
    for (stamps) |st| if (std.mem.eql(u8, st.id, id)) return st;
    return null;
}

/// Is `row` an orphan episode the user has not been told about (or whose
/// telling has aged out)?
pub fn eligible(
    row: Row,
    stamps: []const Stamp,
    now_ms: i64,
    notify_after_ms: i64,
    renotify_after_ms: i64,
) bool {
    if (!row.alive or row.attached) return false;
    const since = row.unattached_since orelse return false;
    if (now_ms - since < notify_after_ms) return false;
    const st = findStamp(stamps, row.id) orelse return true;
    // A different `unattached_since` is a different episode: the session was
    // attached (which cleared the clock) and lost again since the stamp.
    if (st.unattached_since != since) return true;
    return now_ms - st.notified_at >= renotify_after_ms;
}

/// Evaluate the whole roster. Never mutates anything — the caller stamps the
/// announced episode itself once the notification was actually shown.
pub fn decide(
    rows: []const Row,
    stamps: []const Stamp,
    now_ms: i64,
    notify_after_ms: i64,
    renotify_after_ms: i64,
) Decision {
    var d: Decision = .{};
    var oldest: ?i64 = null;
    for (rows, 0..) |row, i| {
        if (!eligible(row, stamps, now_ms, notify_after_ms, renotify_after_ms)) continue;
        d.eligible += 1;
        const since = row.unattached_since.?;
        if (oldest == null or since < oldest.?) {
            oldest = since;
            d.announce = i;
        }
    }
    return d;
}

/// Spell a duration the way a person would say it in a balloon: whole days
/// past 48h, else whole hours (the threshold guarantees at least one). Never
/// minutes — a threshold short enough for minutes only exists under the test
/// override, and the phrase still reads fine as "0 hours".
pub fn durationPhrase(buf: []u8, ms: i64) []const u8 {
    const hours = @divTrunc(ms, std.time.ms_per_hour);
    if (hours >= 48) {
        const days = @divTrunc(hours, 24);
        return std.fmt.bufPrint(buf, "{d} days", .{days}) catch buf[0..0];
    }
    if (hours == 1) return std.fmt.bufPrint(buf, "1 hour", .{}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d} hours", .{hours}) catch buf[0..0];
}

/// Compose the balloon body. NOTIFYICONDATAW.szInfo holds 256 UTF-16 units, so
/// the working-directory line is the part that gets elided (keeping its TAIL —
/// the leaf directory is the recognizable half of a long path) rather than the
/// call to action. `extra` is `eligible - 1`; when positive the body says so.
pub fn formatBody(
    buf: []u8,
    cwd: ?[]const u8,
    argv: ?[]const u8,
    unattached_ms: i64,
    extra: usize,
) []const u8 {
    var dur_buf: [32]u8 = undefined;
    const dur = durationPhrase(&dur_buf, unattached_ms);

    // What the session IS: "cmd — in dir", either half optional.
    var what_buf: [120]u8 = undefined;
    const what: []const u8 = blk: {
        const cmd = argv orelse "";
        const dir = cwd orelse "";
        if (cmd.len > 0 and dir.len > 0) {
            break :blk std.fmt.bufPrint(&what_buf, "{s} — in {s}", .{
                tail(cmd, 40),
                tail(dir, 60),
            }) catch tail(cmd, 40);
        }
        if (cmd.len > 0) break :blk tail(cmd, 100);
        if (dir.len > 0) break :blk tail(dir, 100);
        break :blk "a terminal session";
    };

    if (extra > 0) {
        return std.fmt.bufPrint(
            buf,
            "{s}\nhas run unseen for {s} ({d} more like it).\nClick to review, reopen, or end it.",
            .{ what, dur, extra },
        ) catch buf[0..0];
    }
    return std.fmt.bufPrint(
        buf,
        "{s}\nhas run unseen for {s}.\nClick to review, reopen, or end it.",
        .{ what, dur },
    ) catch buf[0..0];
}

/// The last `max` bytes of `s`, whole string when it fits. Byte-based on
/// purpose: paths and argv here are ASCII-heavy, and a rune split at worst
/// costs one mangled leading glyph in a balloon, never anything load-bearing.
fn tail(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[s.len - max ..];
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

const hour = std.time.ms_per_hour;

test "eligible: only a live, unattached row past the threshold qualifies" {
    const now: i64 = 100 * hour;
    const old_enough: i64 = now - 25 * hour;
    // The qualifying shape.
    try testing.expect(eligible(
        .{ .id = "a", .unattached_since = old_enough },
        &.{},
        now,
        default_notify_after_ms,
        default_renotify_after_ms,
    ));
    // Attached, dead, too recent, and field-absent (OLD AGENT) all stay quiet.
    try testing.expect(!eligible(
        .{ .id = "a", .attached = true, .unattached_since = old_enough },
        &.{},
        now,
        default_notify_after_ms,
        default_renotify_after_ms,
    ));
    try testing.expect(!eligible(
        .{ .id = "a", .alive = false, .unattached_since = old_enough },
        &.{},
        now,
        default_notify_after_ms,
        default_renotify_after_ms,
    ));
    try testing.expect(!eligible(
        .{ .id = "a", .unattached_since = now - 1 * hour },
        &.{},
        now,
        default_notify_after_ms,
        default_renotify_after_ms,
    ));
    try testing.expect(!eligible(
        .{ .id = "a", .unattached_since = null },
        &.{},
        now,
        default_notify_after_ms,
        default_renotify_after_ms,
    ));
}

test "eligible: a stamped episode stays quiet; a NEW episode or an aged stamp re-arms" {
    const now: i64 = 1000 * hour;
    const since: i64 = now - 30 * hour;
    const row: Row = .{ .id = "s1", .unattached_since = since };

    // Same episode, fresh stamp → suppressed (this is "Keep").
    const kept = [_]Stamp{.{ .id = "s1", .unattached_since = since, .notified_at = now - 1 * hour }};
    try testing.expect(!eligible(row, &kept, now, default_notify_after_ms, default_renotify_after_ms));

    // Same episode, stamp older than the re-notify interval → speaks again.
    const aged = [_]Stamp{.{ .id = "s1", .unattached_since = since, .notified_at = now - 8 * 24 * hour }};
    try testing.expect(eligible(row, &aged, now, default_notify_after_ms, default_renotify_after_ms));

    // DIFFERENT `unattached_since` (the session was attached in between —
    // the agent reset the clock) → new episode, fresh stamp is no shield.
    const other_episode = [_]Stamp{.{ .id = "s1", .unattached_since = since - 500 * hour, .notified_at = now - 1 * hour }};
    try testing.expect(eligible(row, &other_episode, now, default_notify_after_ms, default_renotify_after_ms));

    // A stamp for some other session is irrelevant.
    const other_id = [_]Stamp{.{ .id = "s2", .unattached_since = since, .notified_at = now - 1 * hour }};
    try testing.expect(eligible(row, &other_id, now, default_notify_after_ms, default_renotify_after_ms));
}

test "decide: announces the LONGEST-unattached eligible session and counts the rest" {
    const now: i64 = 1000 * hour;
    const rows = [_]Row{
        .{ .id = "recent", .unattached_since = now - 2 * hour }, // under threshold
        .{ .id = "older", .unattached_since = now - 40 * hour },
        .{ .id = "oldest", .unattached_since = now - 90 * hour },
        .{ .id = "held", .attached = true },
    };
    const d = decide(&rows, &.{}, now, default_notify_after_ms, default_renotify_after_ms);
    try testing.expectEqual(@as(?usize, 2), d.announce); // "oldest"
    try testing.expectEqual(@as(usize, 2), d.eligible); // oldest + older

    // Nothing eligible → nothing announced, and the caller can tell.
    const quiet = decide(rows[0..1], &.{}, now, default_notify_after_ms, default_renotify_after_ms);
    try testing.expectEqual(@as(?usize, null), quiet.announce);
    try testing.expectEqual(@as(usize, 0), quiet.eligible);
}

test "durationPhrase: hours under two days, whole days after" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1 hour", durationPhrase(&buf, 1 * hour + 100));
    try testing.expectEqualStrings("30 hours", durationPhrase(&buf, 30 * hour));
    try testing.expectEqualStrings("3 days", durationPhrase(&buf, 3 * 24 * hour + 5));
    try testing.expectEqualStrings("0 hours", durationPhrase(&buf, 1234));
}

test "formatBody: names the command and directory, says the duration, fits the balloon" {
    var buf: [256]u8 = undefined;
    const body = formatBody(&buf, "D:\\git\\ghoztty", "claude", 26 * hour, 0);
    try testing.expect(std.mem.indexOf(u8, body, "claude") != null);
    try testing.expect(std.mem.indexOf(u8, body, "D:\\git\\ghoztty") != null);
    try testing.expect(std.mem.indexOf(u8, body, "26 hours") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Click to review") != null);
    try testing.expect(body.len < 256);

    // The "and N more" suffix appears exactly when there are more.
    const more = formatBody(&buf, null, "top", 50 * 24 * hour, 2);
    try testing.expect(std.mem.indexOf(u8, more, "2 more like it") != null);
    try testing.expect(std.mem.indexOf(u8, more, "50 days") != null);

    // A pathological path is elided from the FRONT, keeping the leaf, and the
    // whole body still fits NOTIFYICONDATAW.szInfo.
    const long = "C:\\Users\\somebody\\some\\extremely\\deep\\projects\\tree\\that\\keeps\\going\\and\\going\\workspace\\repo";
    const elided = formatBody(&buf, long, "npm run dev", 30 * hour, 0);
    try testing.expect(std.mem.indexOf(u8, elided, "workspace\\repo") != null);
    try testing.expect(elided.len < 256);

    // Nothing known about the session still produces a sentence.
    const bare = formatBody(&buf, null, null, 30 * hour, 0);
    try testing.expect(std.mem.indexOf(u8, bare, "a terminal session") != null);
}

test "StampFile: stamps round-trip through JSON" {
    const alloc = testing.allocator;
    const file: StampFile = .{ .stamps = &.{
        .{ .id = "aaaa", .unattached_since = 123, .notified_at = 456 },
    } };
    const j = try std.json.Stringify.valueAlloc(alloc, file, .{});
    defer alloc.free(j);
    const parsed = try std.json.parseFromSlice(StampFile, alloc, j, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.stamps.len);
    try testing.expectEqualStrings("aaaa", parsed.value.stamps[0].id);
    try testing.expectEqual(@as(i64, 123), parsed.value.stamps[0].unattached_since);
    try testing.expectEqual(@as(i64, 456), parsed.value.stamps[0].notified_at);
}
