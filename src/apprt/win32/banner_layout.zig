//! Pure layout math for the sticky pane banner (T101/T123). Two jobs:
//!
//! - How much of a pane's layout slot the banner reserves ABOVE the
//!   terminal surface. The window layout shrinks/offsets the terminal
//!   HWND by this inset so the grid genuinely starts below the strip (Mac
//!   VStack parity — the banner sits above the terminal, never over it).
//! - How a table's columns divide the width the PANE has (T123), so the
//!   banner reflows live with the pane instead of wrapping at a fixed cap,
//!   plus the tail-truncation and UTF-16 break math that keeps one long
//!   cell from blowing up the banner height or overflowing its column.
//!
//! Unit tested in every app-runtime lane (the hero_math/dim_math pattern).

const std = @import("std");

/// Height reserved above the terminal for a banner strip of `strip_h` px
/// in a pane slot `slot_h` px tall. The full strip height when it fits;
/// in degenerate short panes the reservation is capped at 3/4 of the slot
/// so the terminal always keeps at least a quarter (the strip overlay
/// bottom-clips its content instead of squeezing the grid to nothing).
pub fn clampInset(strip_h: i32, slot_h: i32) i32 {
    if (strip_h <= 0 or slot_h <= 0) return 0;
    return @min(strip_h, @divTrunc(slot_h * 3, 4));
}

/// Total height of the banner BAND for a card `card_h` px tall that floats
/// `margin` px inside it (T131). The margin counts on the top AND the
/// bottom, so the terminal content below the band always starts a breath
/// under the card instead of hard against it — Mac parity, where the card's
/// bottom margin is part of the measured banner height that pads the
/// terminal down.
pub fn bandHeight(card_h: i32, margin: i32) i32 {
    if (card_h <= 0) return 0;
    return card_h + @max(margin, 0) * 2;
}

/// A table cell's fallback max width before the pane width is known
/// (Mac `maxCellWidth`). Only used on a measuring pass that runs before
/// any layout pass has fed a pane width down; every real paint sizes
/// columns from the pane instead (T123).
pub const FALLBACK_CELL_W: f32 = 360.0;

/// Max display lines a wrapped run may occupy before it tail-truncates
/// with an ellipsis (Mac `maxCellWrapLines`), so one nasty cell — or one
/// nasty paragraph, heading or list row (T377) — cannot blow up the
/// banner height at a skinny pane width. ONE number for all of them on
/// purpose: a list row and a table cell wrapping by different rules is
/// the same class of defect as not wrapping at all.
pub const MAX_CELL_LINES: usize = 3;

/// Clear space the design system requires between two painted elements
/// (win32-design-system.md: "nothing touches anything", >= 4 DIP),
/// unscaled. The gap between the content column and the reserved chevron
/// column below.
pub const CHEVRON_GAP: f32 = 4.0;

/// Width available to banner CONTENT inside the card, with the collapse
/// chevron's column reserved (T377).
///
/// Content starts `inner` px in from the band's left edge (the card's
/// margin plus its padding) and, with no chevron, stops the same `inner`
/// in from the right. When the banner is collapsible the chevron button
/// sits in the card's top-right corner — a `chevron_side` px square whose
/// right edge is `margin` px from the band edge — and the whole strip it
/// occupies belongs to it: content stops `gap` px short of the chevron's
/// left edge, for EVERY block, so no paragraph, heading, list row or
/// table cell can ever paint under it (user, 2026-08-04: "the whole right
/// side should be dedicated to the chevron column so that text never
/// overlaps the chevron").
///
/// The reservation applies to the whole content column, not just the
/// first line: reserving only the chevron's own row would make the
/// content width depend on which line you are on, which no wrap pass can
/// act on and no test can pin.
///
/// Never returns less than 1 — a pane squeezed narrower than its own
/// chrome still has to lay out rather than divide by zero.
pub fn contentWidth(
    client_w: i32,
    inner: i32,
    margin: i32,
    chevron_side: i32,
    gap: i32,
) i32 {
    const plain = client_w - inner;
    const right = if (chevron_side > 0)
        @min(plain, client_w - margin - chevron_side - @max(gap, 0))
    else
        plain;
    return @max(right - inner, 1);
}

/// Size table columns to the width the pane can actually give them (T123,
/// the port of Mac's `columnWidths(natural:available:)`). `natural[i]` is
/// column i's single-line content width; results land in `out` (same
/// length). `col_gap` is the space between adjacent columns.
///
/// - Everything fits: each column gets its exact natural width, so a wide
///   pane is used instead of wrapping at a fixed cap.
/// - Overflow: max-min fair share. Narrow columns (the bold labels) keep
///   their natural width and hand their slack to the wider columns, which
///   split what is left — so each column wraps only at the width the pane
///   really has, and the banner can never act as a minimum pane width.
/// - Pane width not known yet (`available <= 0`): the old fixed cap, so
///   the first paint is never absurdly wide.
pub fn columnWidths(
    natural: []const f32,
    out: []f32,
    available: f32,
    col_gap: f32,
) void {
    const columns = @min(natural.len, out.len);
    if (columns == 0) return;

    // Budget for cell CONTENT: the inter-column gaps are not negotiable.
    const gaps = col_gap * @as(f32, @floatFromInt(columns - 1));
    const budget = available - gaps;

    if (budget <= 0) {
        if (available > 0) {
            // Known but tiny width: stay bounded (equal shares) so the
            // pane is never blocked from shrinking further.
            const share = @max(1.0, available / @as(f32, @floatFromInt(columns)));
            for (out[0..columns]) |*o| o.* = share;
        } else {
            for (0..columns) |i| out[i] = @min(natural[i], FALLBACK_CELL_W);
        }
        return;
    }

    var total: f32 = 0;
    for (natural[0..columns]) |n| total += n;
    if (total <= budget) {
        for (0..columns) |i| out[i] = natural[i];
        return;
    }

    // Max-min fair share, narrowest column first. A column that fits its
    // equal share of the remaining budget takes its natural width and
    // gives the slack to the wider columns still to be sized; the first
    // column that does not fit takes its share — and so does every
    // column after it, since all of them are at least as wide.
    for (out[0..columns]) |*o| o.* = -1; // -1 marks "not yet sized"
    var remaining = budget;
    var left: usize = columns;
    while (left > 0) {
        const share = remaining / @as(f32, @floatFromInt(left));
        var min_i: ?usize = null;
        for (0..columns) |i| {
            if (out[i] >= 0) continue;
            if (min_i == null or natural[i] < natural[min_i.?]) min_i = i;
        }
        const i = min_i orelse break;
        if (natural[i] > share) {
            // Everything unsized is at least this wide: all take the share.
            for (0..columns) |j| if (out[j] < 0) {
                out[j] = share;
            };
            return;
        }
        out[i] = natural[i];
        remaining -= natural[i];
        left -= 1;
    }
}

/// How many leading tokens of a wrapped line still fit once an ellipsis
/// `ell_w` px wide must sit at its end within `max_w` (T123 tail
/// truncation). Always allows at least the ellipsis itself (0 tokens).
pub fn fitWithEllipsis(widths: []const f32, ell_w: f32, max_w: f32) usize {
    var x: f32 = 0;
    for (widths, 0..) |w, i| {
        if (x + w + ell_w > max_w) return i;
        x += w;
    }
    return widths.len;
}

/// Byte length of the longest prefix of UTF-8 `text` that encodes at most
/// `units` UTF-16 code units — the bridge from what GDI counts (UTF-16)
/// back to the byte slices the banner tokens hold, so a mid-string break
/// can never land inside a codepoint or split a surrogate pair (T123).
pub fn utf16PrefixBytes(text: []const u8, units: usize) usize {
    if (units == 0) return 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var u: usize = 0;
    while (true) {
        const start = it.i;
        const cp = it.nextCodepoint() orelse return it.i;
        const need: usize = if (cp >= 0x10000) 2 else 1;
        if (u + need > units) return start;
        u += need;
        if (u == units) return it.i;
    }
}

// The metrics `BannerOverlay` feeds `contentWidth`, recomputed here the
// same way it does (`px` = round(v * scale)) so the reservation can be
// asserted at every scaling the design system requires.
const TestChrome = struct {
    inner: i32,
    margin: i32,
    chevron: i32,
    gap: i32,

    fn px(v: f32, scale: f32) i32 {
        return @intFromFloat(@round(v * scale));
    }

    fn init(scale: f32) TestChrome {
        return .{
            // card.MARGIN + card.PADDING, both 12 unscaled.
            .inner = px(12.0, scale) + px(12.0, scale),
            .margin = px(12.0, scale),
            // icon_button.Metrics.init(scale).target — 28 unscaled.
            .chevron = px(28.0, scale),
            .gap = px(CHEVRON_GAP, scale),
        };
    }
};

const TEST_SCALES = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "contentWidth: no chevron — symmetric inner margins at every scale" {
    for (TEST_SCALES) |s| {
        const c = TestChrome.init(s);
        const w = 800;
        try std.testing.expectEqual(w - c.inner * 2, contentWidth(w, c.inner, c.margin, 0, c.gap));
    }
}

test "contentWidth: the chevron column is reserved, and never overlapped" {
    for (TEST_SCALES) |s| {
        const c = TestChrome.init(s);
        const w = 800;
        const got = contentWidth(w, c.inner, c.margin, c.chevron, c.gap);
        // The content column ends at least `gap` px left of the chevron's
        // painted left edge — the assertion the user's report reduces to.
        const chevron_left = w - c.margin - c.chevron;
        try std.testing.expect(c.inner + got + c.gap <= chevron_left);
        // ...and it is narrower than the un-reserved width, i.e. the
        // reservation actually engaged (28 + 4 > 12 padding at every scale).
        try std.testing.expect(got < w - c.inner * 2);
    }
}

test "contentWidth: reservation is exactly the chevron strip, no more" {
    // 1.0: inner 24, margin 12, chevron 28, gap 4.
    // right = min(800-24, 800-12-28-4) = 756; width = 756-24 = 732.
    try std.testing.expectEqual(@as(i32, 732), contentWidth(800, 24, 12, 28, 4));
    // 2.0: inner 48, margin 24, chevron 56, gap 8.
    // right = min(1600-48, 1600-24-56-8) = 1512; width = 1512-48 = 1464.
    try std.testing.expectEqual(@as(i32, 1464), contentWidth(1600, 48, 24, 56, 8));
}

test "contentWidth: a banner never blocks the pane from shrinking" {
    for (TEST_SCALES) |s| {
        const c = TestChrome.init(s);
        // Narrower than the chrome itself: still positive and finite.
        for ([_]i32{ 0, 1, 40, 80 }) |w| {
            const got = contentWidth(w, c.inner, c.margin, c.chevron, c.gap);
            try std.testing.expect(got >= 1);
        }
    }
}

test "contentWidth: a negative gap is treated as none, not as slack" {
    try std.testing.expectEqual(
        contentWidth(800, 24, 12, 28, 0),
        contentWidth(800, 24, 12, 28, -10),
    );
}

test "columnWidths: everything fits — exact natural widths, no cap" {
    // The T123 bug: 500 used to be clipped to 360 on a pane with room.
    var out: [2]f32 = undefined;
    columnWidths(&.{ 80, 500 }, &out, 900, 18);
    try std.testing.expectEqual(@as(f32, 80), out[0]);
    try std.testing.expectEqual(@as(f32, 500), out[1]);
}

test "columnWidths: overflow — narrow label keeps its width, wide cell takes the rest" {
    var out: [2]f32 = undefined;
    // budget = 400 - 18 = 382; share = 191, the 80 label fits it.
    columnWidths(&.{ 80, 900 }, &out, 400, 18);
    try std.testing.expectEqual(@as(f32, 80), out[0]);
    try std.testing.expectEqual(@as(f32, 302), out[1]);
}

test "columnWidths: every column too wide — equal shares" {
    var out: [3]f32 = undefined;
    // budget = 336 - 36 = 300; share = 100, none of the naturals fit it.
    columnWidths(&.{ 400, 500, 600 }, &out, 336, 18);
    for (out) |w| try std.testing.expectEqual(@as(f32, 100), w);
}

test "columnWidths: a banner never blocks the pane from shrinking" {
    // Squeezed past the gaps: bounded equal shares, not the naturals.
    var out: [3]f32 = undefined;
    columnWidths(&.{ 400, 500, 600 }, &out, 30, 18);
    for (out) |w| try std.testing.expectEqual(@as(f32, 10), w);
    // And at an absurd squeeze it still stays positive and finite.
    columnWidths(&.{ 400, 500, 600 }, &out, 1, 18);
    for (out) |w| try std.testing.expectEqual(@as(f32, 1), w);
}

test "columnWidths: width unknown — the old fixed cap" {
    var out: [2]f32 = undefined;
    columnWidths(&.{ 80, 900 }, &out, 0, 18);
    try std.testing.expectEqual(@as(f32, 80), out[0]);
    try std.testing.expectEqual(FALLBACK_CELL_W, out[1]);
}

test "columnWidths: single column takes the whole width" {
    var out: [1]f32 = undefined;
    columnWidths(&.{900}, &out, 500, 18);
    try std.testing.expectEqual(@as(f32, 500), out[0]);
    columnWidths(&.{300}, &out, 500, 18);
    try std.testing.expectEqual(@as(f32, 300), out[0]);
}

test "columnWidths: zero columns is a no-op" {
    var out: [0]f32 = undefined;
    columnWidths(&.{}, &out, 500, 18);
}

test "fitWithEllipsis" {
    const w = [_]f32{ 40, 30, 30, 30 };
    // 40+30 = 70, +10 ellipsis = 80 <= 100; adding the third would be 110.
    try std.testing.expectEqual(@as(usize, 2), fitWithEllipsis(&w, 10, 100));
    try std.testing.expectEqual(@as(usize, 4), fitWithEllipsis(&w, 10, 1000));
    // Not even one token fits beside the ellipsis.
    try std.testing.expectEqual(@as(usize, 0), fitWithEllipsis(&w, 10, 20));
}

test "utf16PrefixBytes: ascii is one unit per byte" {
    try std.testing.expectEqual(@as(usize, 0), utf16PrefixBytes("hello", 0));
    try std.testing.expectEqual(@as(usize, 3), utf16PrefixBytes("hello", 3));
    try std.testing.expectEqual(@as(usize, 5), utf16PrefixBytes("hello", 9));
}

test "utf16PrefixBytes: never splits a codepoint or a surrogate pair" {
    // "é" (2 bytes, 1 unit) then "😀" (4 bytes, a surrogate PAIR).
    const s = "aé😀b";
    try std.testing.expectEqual(@as(usize, 1), utf16PrefixBytes(s, 1));
    try std.testing.expectEqual(@as(usize, 3), utf16PrefixBytes(s, 2));
    // 3 units would land INSIDE the surrogate pair — stop before it.
    try std.testing.expectEqual(@as(usize, 3), utf16PrefixBytes(s, 3));
    try std.testing.expectEqual(@as(usize, 7), utf16PrefixBytes(s, 4));
    try std.testing.expectEqual(@as(usize, 8), utf16PrefixBytes(s, 5));
}

test "bandHeight: a margin on both sides of the card" {
    try std.testing.expectEqual(@as(i32, 79), bandHeight(55, 12));
    // 2x DPI: the margin scales with the card.
    try std.testing.expectEqual(@as(i32, 158), bandHeight(110, 24));
}

test "bandHeight: degenerate inputs" {
    try std.testing.expectEqual(@as(i32, 0), bandHeight(0, 12));
    try std.testing.expectEqual(@as(i32, 0), bandHeight(-4, 12));
    try std.testing.expectEqual(@as(i32, 30), bandHeight(30, 0));
    try std.testing.expectEqual(@as(i32, 30), bandHeight(30, -5));
}

test "clampInset: strip fits — full reservation" {
    try std.testing.expectEqual(@as(i32, 31), clampInset(31, 400));
    try std.testing.expectEqual(@as(i32, 251), clampInset(251, 1000));
}

test "clampInset: short pane — capped at 3/4 of the slot" {
    try std.testing.expectEqual(@as(i32, 75), clampInset(251, 100));
    try std.testing.expectEqual(@as(i32, 0), clampInset(251, 1));
}

test "clampInset: degenerate inputs" {
    try std.testing.expectEqual(@as(i32, 0), clampInset(0, 400));
    try std.testing.expectEqual(@as(i32, 0), clampInset(-5, 400));
    try std.testing.expectEqual(@as(i32, 0), clampInset(31, 0));
    try std.testing.expectEqual(@as(i32, 0), clampInset(31, -10));
}
