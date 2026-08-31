//! Is the window you are looking at running the build that is on disk? (T1205)
//!
//! Windows cannot replace a running image, so every open Ghoztty keeps the
//! executable it was launched with for as long as it lives. An upgrade
//! replaces the FILE; the running PROCESS carries on being the old build.
//! That is normal, expected, and — until this module — completely invisible:
//! on 2026-08-31 the user installed 1.35.0, opened About to check it had
//! worked, and read `1.4.0-…` (the process) next to today's date (the file).
//! Two different builds in one box, and no surface anywhere said so.
//!
//! The comparison is deliberately between two RUNTIME facts rather than two
//! version strings:
//!
//! - **When this process started** (`GetProcessTimes`), and
//! - **when the file it was launched from was last written** (its mtime).
//!
//! A file written after we started is, by definition, not the image we are
//! running — whoever wrote it (msiexec, the upgrade script, a `zig build`)
//! and whatever version it claims. Reading the version out of the on-disk PE
//! instead would answer a weaker question: an equal version string does not
//! mean an equal build (this branch ships many builds per version), and a
//! version resource is stamped by the packaging pipeline rather than by the
//! thing that replaced the file.
//!
//! No OS calls live here, so the logic is asserted in every lane; the two
//! timestamps are collected in `provenance.zig`.

const std = @import("std");

/// Windows FILETIME ticks are 100ns; the epoch is 1601-01-01 UTC. This is the
/// number of those ticks between 1601-01-01 and 1970-01-01.
pub const filetime_unix_epoch_ticks: u64 = 116_444_736_000_000_000;

/// Slack absorbed before a newer file counts as a newer build.
///
/// The two clocks are the same clock, so this is not for drift — it is for
/// the ordinary case where an installer finishes writing the exe and starts
/// it in the same breath, and the file's mtime lands a hair after the
/// process's creation time. Two seconds is far under the gap that matters (a
/// window running since yesterday) and far over that race.
pub const tolerance_ns: i128 = 2 * std.time.ns_per_s;

/// Convert a Windows FILETIME (as a u64 of 100ns ticks since 1601) to
/// nanoseconds since the Unix epoch, which is what `std.fs.File.Stat.mtime`
/// speaks and therefore the one unit this module compares in.
pub fn filetimeToUnixNs(ticks: u64) i128 {
    const rel: i128 = @as(i128, ticks) - @as(i128, filetime_unix_epoch_ticks);
    return rel * 100;
}

/// True when the executable on disk was written after this process started —
/// i.e. a newer build is installed and this window is not running it.
///
/// Unknown inputs (either timestamp zero or negative, which is how the
/// collectors report "could not tell") are never stale: an unanswerable
/// question must not produce a notification telling the user to restart.
pub fn isStale(on_disk_ns: i128, started_ns: i128) bool {
    if (on_disk_ns <= 0 or started_ns <= 0) return false;
    return on_disk_ns > started_ns + tolerance_ns;
}

test "isStale: a file written after we started is a newer build" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    // Replaced a minute later — the upgrade case.
    try testing.expect(isStale(start + 60 * std.time.ns_per_s, start));
}

test "isStale: the file we launched from is not stale" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    // Written before we started, which is every normal launch.
    try testing.expect(!isStale(start - 5 * std.time.ns_per_s, start));
    // Written in the same breath as the launch: inside the tolerance.
    try testing.expect(!isStale(start + std.time.ns_per_s, start));
    try testing.expect(!isStale(start, start));
}

test "isStale: the tolerance is exclusive at its edge" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    try testing.expect(!isStale(start + tolerance_ns, start));
    try testing.expect(isStale(start + tolerance_ns + 1, start));
}

test "isStale: an unknown timestamp never nags" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    try testing.expect(!isStale(0, start));
    try testing.expect(!isStale(start + 60 * std.time.ns_per_s, 0));
    try testing.expect(!isStale(-1, -1));
}

test "filetimeToUnixNs: the epoch constant lands on 1970" {
    const testing = std.testing;
    try testing.expectEqual(@as(i128, 0), filetimeToUnixNs(filetime_unix_epoch_ticks));
}

test "filetimeToUnixNs: a known instant round-trips to seconds" {
    const testing = std.testing;
    // 2026-07-17 09:31:40 UTC == 1784280700 unix seconds.
    const ticks = filetime_unix_epoch_ticks + 1_784_280_700 * 10_000_000;
    const ns = filetimeToUnixNs(ticks);
    try testing.expectEqual(@as(i128, 1_784_280_700), @divFloor(ns, std.time.ns_per_s));
}

test "filetimeToUnixNs: a pre-1970 FILETIME is negative, not enormous" {
    const testing = std.testing;
    // One second before the Unix epoch. An unsigned subtraction here would
    // wrap to ~5.8e11 seconds in the future and make every window "stale".
    const ns = filetimeToUnixNs(filetime_unix_epoch_ticks - 10_000_000);
    try testing.expectEqual(@as(i128, -1 * std.time.ns_per_s), ns);
}
