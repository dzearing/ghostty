//! T666: parking a restored screen into scrollback.
//!
//! A session-persistence pane comes back by painting the app's own persisted VT
//! repaint of the screen it had when it was last saved (WP-D3, see
//! `Remote.restore_snapshot`). That paint lands on the pane's VISIBLE SCREEN —
//! it is a repaint, so its rows sit at rows 0..N with nothing scrolling — and
//! the very next thing on the wire is a full-viewport repaint that homes to row
//! 1: the agent's own `grid_snapshot` (which opens with `ESC[H ESC[2J`) and,
//! behind it, ConPTY's post-attach fresh paint (`ESC[?25l ESC[H` + per-line
//! `ESC[K`). Both overwrite exactly the rows the restore just painted, so every
//! re-attach left the pane holding one screen and nothing above it — the whole
//! history gone, with no warning and no way back.
//!
//! That is the same invariant T106 named for the full-ring replay path: on
//! Windows, content only survives an attach if it is in SCROLLBACK before the
//! repaint lands. The full-ring path gets there by replaying at the capture
//! geometry so the recorded line feeds actually scroll; a structured repaint has
//! no line feeds to lean on, so it has to be parked deliberately.
//!
//! Parking is: put the cursor on the LAST row and emit one line feed per
//! occupied row. A line feed on the bottom row scrolls the screen, which is the
//! one operation that moves a row into scrollback, so the restored history ends
//! up above the viewport and the repaint gets a blank screen to draw on.
//!
//! Pure arithmetic + one CUP string, so it is asserted in the `none` lane; the
//! caller (`Remote.parkRestoredScreen`) owns the terminal reads and the write.

const std = @import("std");
const testing = std.testing;

/// What one park costs on the wire: the CUP that moves to the bottom row, then
/// `newlines` line feeds. Split rather than one blob because `newlines` is
/// bounded only by the pane's row count — the caller streams the line feeds from
/// a small fixed buffer instead of anyone allocating a row-sized one.
pub const Plan = struct {
    /// `ESC[<rows>;1H` — move to the bottom-left. Points into the caller's buffer.
    cup: []const u8,
    /// How many line feeds to write after it. Always >= 1.
    newlines: u16,
};

/// The longest `cup` this can produce: `ESC[65535;1H`.
pub const cup_max_len: usize = 11;

/// Plan the park for a screen `rows` tall whose lowest occupied row is
/// `cursor_y` (0-based — where the restore paint left the cursor).
///
/// Null when there is nothing to park: a screen with no rows at all. A screen
/// whose cursor is still on row 0 DOES park (one row): the restore painted
/// something there, and leaving a single row for the repaint to overwrite is the
/// same defect in miniature. `cursor_y` at or past the last row is clamped, so a
/// stale cursor from a resize race parks the whole screen rather than
/// overflowing.
pub fn plan(buf: []u8, rows: u16, cursor_y: u16) ?Plan {
    if (rows == 0) return null;
    const last: u16 = rows - 1;
    const y: u16 = @min(cursor_y, last);
    const cup = std.fmt.bufPrint(buf, "\x1b[{d};1H", .{rows}) catch return null;
    return .{ .cup = cup, .newlines = y + 1 };
}

test "plan: a part-full screen parks exactly its occupied rows" {
    var buf: [cup_max_len]u8 = undefined;
    const p = plan(&buf, 24, 7).?;
    try testing.expectEqualStrings("\x1b[24;1H", p.cup);
    try testing.expectEqual(@as(u16, 8), p.newlines);
}

test "plan: a full screen parks every row" {
    var buf: [cup_max_len]u8 = undefined;
    const p = plan(&buf, 24, 23).?;
    try testing.expectEqualStrings("\x1b[24;1H", p.cup);
    try testing.expectEqual(@as(u16, 24), p.newlines);
}

test "plan: a cursor past the last row is clamped, never overflowed" {
    var buf: [cup_max_len]u8 = undefined;
    const p = plan(&buf, 10, 900).?;
    try testing.expectEqual(@as(u16, 10), p.newlines);
}

test "plan: a single-row screen still parks its one row" {
    var buf: [cup_max_len]u8 = undefined;
    const p = plan(&buf, 1, 0).?;
    try testing.expectEqualStrings("\x1b[1;1H", p.cup);
    try testing.expectEqual(@as(u16, 1), p.newlines);
}

test "plan: a zero-row screen has nothing to park" {
    var buf: [cup_max_len]u8 = undefined;
    try testing.expect(plan(&buf, 0, 0) == null);
}

test "plan: the widest geometry still fits cup_max_len" {
    var buf: [cup_max_len]u8 = undefined;
    const p = plan(&buf, std.math.maxInt(u16), std.math.maxInt(u16)).?;
    try testing.expectEqualStrings("\x1b[65535;1H", p.cup);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), p.newlines);
}
