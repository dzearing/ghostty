//! Pure action model for the win32 Activity Monitor's process control (T286):
//! the Kill button's label, the confirmation wording, the aggregated failure
//! text, the error banner's dismissal state, the empty-state/badge choice, and
//! the selection pruning that keeps the Kill count honest. No OS imports and no
//! GDI, so it runs in every app-runtime test lane — the same split that keeps
//! `activity_rows.zig` testable while `ActivityMonitor.zig` owns the HWNDs.
//!
//! The Mac original is `RemoteActivityMonitorView.swift`: the Kill button and
//! its label at :940-952, `killConfirmTitle` at :740-746, the confirmation
//! message at :777-779, the aggregated failure strings in `killSelected` at
//! :587-596, the spawn failure at :627, the "Couldn't connect" empty state at
//! :1034-1045, the "Refresh failed" badge at :919-923, and the selection prune
//! at :1050-1056. Every derivation cites the line it mirrors, because a parity
//! claim that is not anchored to a Mac source line is a guess (the T240 lesson).
//!
//! ## The one deliberate divergence: the confirmation wording
//! Mac says "This sends a termination signal to the process." Windows has no
//! such signal — `proc_control.killWindows` is `TerminateProcess`, which is
//! immediate and ungraceful (that module's own "TERM==KILL" caveat). Repeating
//! Mac's sentence here would MISREPRESENT what the button does, so the Windows
//! body says what actually happens. The task file calls this out by name.

const std = @import("std");
const rows_mod = @import("activity_rows.zig");

/// One process the user asked to kill. `name` is borrowed from the snapshot the
/// row came from, so a marshaled target must not outlive that snapshot — which
/// it does not: the whole kill runs inside one message handler.
pub const Target = struct {
    pid: i64,
    name: []const u8 = "",
};

/// The Kill button's caption: "Kill" for one row, "Kill N" for many
/// (`RemoteActivityMonitorView.swift:946-947`). Never returns an empty string;
/// a formatting failure falls back to the bare verb.
pub fn killButtonLabel(buf: []u8, count: usize) []const u8 {
    if (count <= 1) return "Kill";
    return std.fmt.bufPrint(buf, "Kill {d}", .{count}) catch "Kill";
}

/// How a target is named in prose: its process name, or "process" when the
/// sampler gave us none (Mac's `name.isEmpty ? "process" : name`, :742).
fn displayName(t: Target) []const u8 {
    return if (t.name.len == 0) "process" else t.name;
}

/// How a target is named in a LIST of failures, where the pid is the only thing
/// that disambiguates a nameless row (Mac's `"PID \(pid)"`, :592).
fn listName(buf: []u8, t: Target) []const u8 {
    if (t.name.len > 0) return t.name;
    return std.fmt.bufPrint(buf, "PID {d}", .{t.pid}) catch "process";
}

/// The confirmation dialog's title: one process names it with its pid, many
/// give a count (Mac's `killConfirmTitle`, :740-746).
pub fn killConfirmTitle(buf: []u8, targets: []const Target) []const u8 {
    if (targets.len == 0) return "Kill process?";
    if (targets.len == 1) {
        return std.fmt.bufPrint(buf, "Kill {s} (PID {d})?", .{
            displayName(targets[0]),
            targets[0].pid,
        }) catch "Kill process?";
    }
    return std.fmt.bufPrint(buf, "Kill {d} processes?", .{targets.len}) catch "Kill processes?";
}

/// The confirmation dialog's body. See the module header for why this does NOT
/// repeat Mac's "sends a termination signal" — on Windows there is no signal to
/// send, and a confirmation that misdescribes its own action is worse than no
/// confirmation at all.
pub fn killConfirmBody(count: usize) []const u8 {
    if (count > 1) {
        return "Windows cannot ask a process to exit: each one is terminated " ++
            "immediately and any unsaved work in it is lost.";
    }
    return "Windows cannot ask a process to exit: it is terminated immediately " ++
        "and any unsaved work in it is lost.";
}

/// The error-banner text after a kill batch in which `failed` of `total` did not
/// die. Returns null when nothing failed — the banner is absent, not empty
/// (Mac only sets `actionError` on failure, :585-597).
///
/// One failure names it; several report the tally and list up to three, so the
/// cause stays concrete without the banner becoming a paragraph.
pub fn killFailureText(buf: []u8, total: usize, failed: []const Target) ?[]const u8 {
    if (failed.len == 0) return null;
    if (total == 1) {
        return std.fmt.bufPrint(
            buf,
            "Couldn't kill {s} (PID {d}). It may require elevated privileges.",
            .{ displayName(failed[0]), failed[0].pid },
        ) catch "Couldn't kill the process.";
    }

    // Build the "a, b, c, …" list into the tail of `buf` first, then format the
    // sentence into the head — one buffer, no allocator.
    const split = buf.len / 2;
    var list_buf = buf[split..];
    var list_len: usize = 0;
    var listed: usize = 0;
    for (failed) |f| {
        if (listed == 3) break;
        var name_buf: [32]u8 = undefined;
        const name = listName(&name_buf, f);
        const sep: []const u8 = if (listed == 0) "" else ", ";
        if (list_len + sep.len + name.len > list_buf.len) break;
        @memcpy(list_buf[list_len..][0..sep.len], sep);
        list_len += sep.len;
        @memcpy(list_buf[list_len..][0..name.len], name);
        list_len += name.len;
        listed += 1;
    }
    if (failed.len > listed and list_len + 3 <= list_buf.len) {
        const more = ", \u{2026}";
        if (list_len + more.len <= list_buf.len) {
            @memcpy(list_buf[list_len..][0..more.len], more);
            list_len += more.len;
        }
    }

    const killed = total - failed.len;
    return std.fmt.bufPrint(
        buf[0..split],
        "Killed {d} of {d} ({d} failed: {s}). Some may require elevated privileges.",
        .{ killed, total, failed.len, list_buf[0..list_len] },
    ) catch "Some processes could not be killed.";
}

/// The error-banner text when a spawn fails (Mac's :627). The command is
/// truncated so a pasted 400-character command line cannot push the sentence out
/// of the banner.
pub fn spawnFailureText(buf: []u8, cmd: []const u8) []const u8 {
    const max_cmd = 80;
    if (cmd.len <= max_cmd) {
        return std.fmt.bufPrint(buf, "Couldn't start \u{201c}{s}\u{201d}.", .{cmd}) catch
            "Couldn't start the process.";
    }
    return std.fmt.bufPrint(buf, "Couldn't start \u{201c}{s}\u{2026}\u{201d}.", .{cmd[0..max_cmd]}) catch
        "Couldn't start the process.";
}

/// What the table's overlay says when it has no rows to draw
/// (`RemoteActivityMonitorView.swift:1030-1045`).
pub const EmptyState = enum {
    /// The first sample has not landed yet.
    loading,
    /// The source could not be reached AND we have nothing from it.
    unreachable_source,
    /// We have a table; the filter simply matches none of it.
    no_match,
};

/// Which empty state the overlay shows. `total_rows` is the SNAPSHOT's row
/// count, not the filtered count: a filter that hides everything is
/// `no_match`, and only a source that produced nothing at all is
/// `unreachable_source` (Mac gates its "Couldn't connect" on
/// `model.procs.isEmpty`, :1034).
pub fn emptyState(loading: bool, refresh_failed: bool, total_rows: usize) EmptyState {
    if (loading) return .loading;
    if (refresh_failed and total_rows == 0) return .unreachable_source;
    return .no_match;
}

/// The control bar's status badge, or null when there is nothing to say. A
/// refresh failure outranks a truncated list: a stale table is a stronger claim
/// about what the user is looking at than a long one
/// (`RemoteActivityMonitorView.swift:912-923`, where "Refresh failed" is the
/// badge that appears while rows are still on screen).
pub fn badgeText(refresh_failed: bool, truncated: bool, total_rows: usize) ?[]const u8 {
    if (refresh_failed and total_rows > 0) return "\u{26A0} Refresh failed";
    if (truncated) return "\u{26A0} List truncated";
    return null;
}

/// Drop selected pids that the newest snapshot no longer contains, in place.
/// Returns the surviving count.
///
/// Without this the Kill button counts processes that already exited and the
/// confirmation names them — Mac prunes on every `procs` change for exactly that
/// reason (:1050-1056). Order among survivors is preserved, because the LAST
/// entry is the shift-click anchor.
pub fn pruneSelection(sel: []i64, len: usize, rows: []const rows_mod.Row) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        for (rows) |r| {
            if (r.pid == sel[i]) {
                sel[out] = sel[i];
                out += 1;
                break;
            }
        }
    }
    return out;
}

/// Marshal the selected pids into `out` as kill targets, resolving each pid's
/// name against `rows`. A pid with no row left is still a target — the user
/// asked for it, and the kill will simply report "no such process" — but it
/// cannot be named. Returns the slice actually filled.
pub fn targetsFor(sel: []const i64, rows: []const rows_mod.Row, out: []Target) []Target {
    var n: usize = 0;
    for (sel) |pid| {
        if (n == out.len) break;
        var name: []const u8 = "";
        for (rows) |r| {
            if (r.pid == pid) {
                name = r.name;
                break;
            }
        }
        out[n] = .{ .pid = pid, .name = name };
        n += 1;
    }
    return out[0..n];
}

/// Whether the New Process dialog's Start button may commit: Mac disables it
/// while the command field is blank (:1160), so a dialog can never spawn "".
pub fn spawnCommandValid(cmd: []const u8) bool {
    return rows_mod.trim(cmd).len > 0;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "killButtonLabel: singular verb for one, counted for many" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Kill", killButtonLabel(&buf, 0));
    try testing.expectEqualStrings("Kill", killButtonLabel(&buf, 1));
    try testing.expectEqualStrings("Kill 2", killButtonLabel(&buf, 2));
    try testing.expectEqualStrings("Kill 17", killButtonLabel(&buf, 17));
}

test "killConfirmTitle: one names the process and its pid, many count" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "Kill notepad.exe (PID 4312)?",
        killConfirmTitle(&buf, &.{.{ .pid = 4312, .name = "notepad.exe" }}),
    );
    // A nameless row still gets a sentence the user can act on.
    try testing.expectEqualStrings(
        "Kill process (PID 9)?",
        killConfirmTitle(&buf, &.{.{ .pid = 9 }}),
    );
    try testing.expectEqualStrings(
        "Kill 3 processes?",
        killConfirmTitle(&buf, &.{
            .{ .pid = 1, .name = "a" },
            .{ .pid = 2, .name = "b" },
            .{ .pid = 3, .name = "c" },
        }),
    );
}

test "killConfirmBody: never claims a graceful signal Windows does not have" {
    for ([_]usize{ 1, 5 }) |n| {
        const body = killConfirmBody(n);
        try testing.expect(std.mem.indexOf(u8, body, "signal") == null);
        try testing.expect(std.mem.indexOf(u8, body, "immediately") != null);
    }
    // The plural body speaks of more than one process.
    try testing.expect(std.mem.indexOf(u8, killConfirmBody(3), "each one") != null);
}

test "killFailureText: null on full success, named on a single failure" {
    var buf: [256]u8 = undefined;
    try testing.expect(killFailureText(&buf, 3, &.{}) == null);
    try testing.expectEqualStrings(
        "Couldn't kill notepad.exe (PID 4312). It may require elevated privileges.",
        killFailureText(&buf, 1, &.{.{ .pid = 4312, .name = "notepad.exe" }}).?,
    );
}

test "killFailureText: a batch reports the tally and lists at most three" {
    var buf: [256]u8 = undefined;
    const text = killFailureText(&buf, 5, &.{
        .{ .pid = 1, .name = "aa.exe" },
        .{ .pid = 2, .name = "bb.exe" },
        .{ .pid = 3, .name = "cc.exe" },
        .{ .pid = 4, .name = "dd.exe" },
    }).?;
    try testing.expect(std.mem.indexOf(u8, text, "Killed 1 of 5") != null);
    // The list is asserted whole — the fourth name is ELIDED, not listed, and a
    // substring probe for "dd.exe" alone would also have to prove the sentence
    // around it is the one we meant.
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "(4 failed: aa.exe, bb.exe, cc.exe, \u{2026})",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, text, "dd.exe") == null);
}

test "killFailureText: a nameless failure is listed by pid" {
    var buf: [256]u8 = undefined;
    const text = killFailureText(&buf, 3, &.{
        .{ .pid = 77 },
        .{ .pid = 88, .name = "b" },
    }).?;
    try testing.expect(std.mem.indexOf(u8, text, "PID 77") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Killed 1 of 3") != null);
}

test "spawnFailureText: quotes the command and truncates a huge one" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "Couldn't start \u{201c}notepad\u{201d}.",
        spawnFailureText(&buf, "notepad"),
    );
    const long = "x" ** 300;
    const text = spawnFailureText(&buf, long);
    try testing.expect(text.len < 140);
    try testing.expect(std.mem.indexOf(u8, text, "\u{2026}") != null);
}

test "emptyState: loading wins, then unreachable, then no-match" {
    try testing.expectEqual(EmptyState.loading, emptyState(true, true, 0));
    try testing.expectEqual(EmptyState.unreachable_source, emptyState(false, true, 0));
    // A failed refresh over rows we already have is NOT "couldn't connect" —
    // the table is stale, not empty.
    try testing.expectEqual(EmptyState.no_match, emptyState(false, true, 42));
    try testing.expectEqual(EmptyState.no_match, emptyState(false, false, 0));
}

test "badgeText: a failed refresh outranks a truncated list" {
    try testing.expect(badgeText(false, false, 10) == null);
    try testing.expectEqualStrings("\u{26A0} List truncated", badgeText(false, true, 10).?);
    try testing.expectEqualStrings("\u{26A0} Refresh failed", badgeText(true, true, 10).?);
    // With nothing on screen the overlay says "Couldn't connect"; a badge over
    // an empty table would say it twice.
    try testing.expect(badgeText(true, false, 0) == null);
}

test "pruneSelection: exited pids drop out and the anchor stays last" {
    const rows = [_]rows_mod.Row{
        .{ .pid = 10, .name = "a" },
        .{ .pid = 30, .name = "c" },
    };
    var sel = [_]i64{ 10, 20, 30 };
    const n = pruneSelection(&sel, 3, &rows);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 10), sel[0]);
    try testing.expectEqual(@as(i64, 30), sel[1]);
}

test "pruneSelection: an empty table clears the selection" {
    var sel = [_]i64{ 1, 2 };
    try testing.expectEqual(@as(usize, 0), pruneSelection(&sel, 2, &.{}));
}

test "targetsFor: pids resolve to names, a vanished pid stays a target" {
    const rows = [_]rows_mod.Row{
        .{ .pid = 10, .name = "a.exe" },
    };
    var out: [4]Target = undefined;
    const t = targetsFor(&.{ 10, 99 }, &rows, &out);
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqualStrings("a.exe", t[0].name);
    try testing.expectEqual(@as(i64, 99), t[1].pid);
    try testing.expectEqualStrings("", t[1].name);
}

test "targetsFor: never writes past the caller's buffer" {
    const rows = [_]rows_mod.Row{};
    var out: [2]Target = undefined;
    const t = targetsFor(&.{ 1, 2, 3, 4 }, &rows, &out);
    try testing.expectEqual(@as(usize, 2), t.len);
}

test "spawnCommandValid: whitespace is not a command" {
    try testing.expect(!spawnCommandValid(""));
    try testing.expect(!spawnCommandValid("   \t "));
    try testing.expect(spawnCommandValid("notepad"));
    try testing.expect(spawnCommandValid("  notepad  "));
}
