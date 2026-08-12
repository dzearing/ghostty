//! The per-line prefix of the shared Windows log sink
//! (`%LOCALAPPDATA%\ghoztty\ghoztty.log`).
//!
//! That file is written by the GUI app, the agent, and every one-shot
//! `ghoztty +…` CLI invocation, all appending concurrently — several a second on
//! a box driving Ghoztty from scripts. T229's fix (`FILE_APPEND_DATA`) stopped
//! those writers from clobbering each other's bytes, but the surviving lines
//! carried a level, a scope and a message and nothing else: no way to tell one
//! process's lines from another's, and no way to place any of them in time. So
//! "did the app die, or did it sit there for twenty minutes?" was not a question
//! the log could answer, and pairing a line to the one ~6,500 lines earlier that
//! caused it was guesswork (T270).
//!
//! The prefix is `<iso-8601-utc-millis> <pid> `, e.g.
//!
//!     2026-08-01T14:22:31.104Z 13060 warning(win32): user confirmed …
//!
//! The pid is what makes the sink demultiplexable — `Select-String ' 13060 '` is
//! one process's log — and the millisecond timestamp is what orders two
//! processes' lines against each other.

const std = @import("std");

/// The longest prefix `format` can produce, so a caller can size a buffer for it
/// and treat the format as infallible: a 5-digit year (`year` is a `u16`, and
/// `format` clamps above that), the rest of the timestamp, and a 10-digit pid,
/// each followed by its separator.
pub const max_len = "-00-00T00:00:00.000Z".len + 5 + 1 + 10 + 1;

/// The last instant `format` will render, rather than looping in
/// `calculateYearDay` for a clock reading centuries out: 9999-12-31T23:59:59Z.
const max_secs: u64 = 253402300799;

/// Write `<timestamp> <pid> ` into `buf` and return it.
///
/// `ms` is a Unix millisecond timestamp (`std.time.milliTimestamp`). A clock
/// reading before the epoch or past year 9999 is CLAMPED rather than rejected —
/// a log line is still worth having when the machine's clock is wrong, and the
/// caller has nowhere to report a failure to anyway.
pub fn format(buf: *[max_len]u8, ms: i64, pid: u32) []const u8 {
    const ms_pos: u64 = if (ms < 0) 0 else @intCast(ms);
    var secs = ms_pos / 1000;
    var millis = ms_pos % 1000;
    if (secs > max_secs) {
        secs = max_secs;
        millis = 999;
    }

    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const time = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z {d} ",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
            millis,
            pid,
        },
    ) catch unreachable;
}

test "format: the epoch itself" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z 1 ",
        format(&buf, 0, 1),
    );
}

test "format: a real instant, to the millisecond" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2026-08-01T14:22:31.104Z 13060 ",
        format(&buf, 1785594151104, 13060),
    );
}

test "format: every field is zero padded to a fixed width" {
    // 2001-02-03T04:05:06.007Z — every component a single digit, which is the
    // shape that makes a lexical sort of the file a chronological one.
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2001-02-03T04:05:06.007Z 7 ",
        format(&buf, 981173106007, 7),
    );
}

test "format: a clock before the epoch clamps rather than wrapping" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z 42 ",
        format(&buf, -1, 42),
    );
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z 42 ",
        format(&buf, std.math.minInt(i64), 42),
    );
}

test "format: a clock past year 9999 clamps rather than hanging" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "9999-12-31T23:59:59.999Z 42 ",
        format(&buf, std.math.maxInt(i64), 42),
    );
}

test "format: never exceeds max_len, at either extreme" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expect(format(&buf, std.math.maxInt(i64), std.math.maxInt(u32)).len <= max_len);
    try std.testing.expect(format(&buf, 0, 0).len <= max_len);
}

test "format: the shape the acceptance script matches" {
    // ^\d{4}-\d\d-\d\dT[\d:.]+Z \d+ — asserted here in the same terms
    // test\win32\log-append.ps1 uses, so the two cannot drift apart silently.
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, 1785594151104, 13060);
    try std.testing.expect(out[out.len - 1] == ' ');

    var it = std.mem.splitScalar(u8, out[0 .. out.len - 1], ' ');
    const stamp = it.next().?;
    const pid = it.next().?;
    try std.testing.expect(it.next() == null);

    try std.testing.expectEqual(@as(usize, 24), stamp.len);
    try std.testing.expect(stamp[stamp.len - 1] == 'Z');
    try std.testing.expect(stamp[4] == '-' and stamp[7] == '-' and stamp[10] == 'T');
    for (pid) |c| try std.testing.expect(std.ascii.isDigit(c));
}
