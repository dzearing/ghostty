//! Pure pixel math for the viewer pane's ERROR CARD (T373, T90a design §2):
//! the native, owner-painted card a viewer shows instead of web content when
//! there is no WebView2 runtime, when the controller fails to come up, and —
//! from T90e on — when the file it was asked to show is missing or unreadable.
//!
//! It is a pure module for the reason every other win32 geometry module is: the
//! numbers are the thing that goes wrong, and they go wrong at scales nobody
//! runs the GUI at. `docs/design/win32-design-system.md` is the rulebook, and
//! the tests below assert its rules at 1.0, 1.25, 1.5 and 2.0 rather than
//! restating them in prose:
//!
//!   * every constant sits on the **4 DIP spacing scale** (§1);
//!   * **nothing touches anything** — the card clears the pane edge by a full
//!     margin, and the text clears the card edge by a full padding (§2);
//!   * the card is **sized to its content**, not the pane: it takes the width
//!     it needs up to a readable maximum and then centers (§4);
//!   * a pane too small for the card does not paint a broken one — the card
//!     degrades to the pane's usable area and the caller stops when even that
//!     is gone.
//!
//! Rounding is `@round` (half away from zero), the same as every other module
//! here. `test/win32/lib/ChromeGeometry.ps1` exists because PowerShell's
//! `[math]::Round` is banker's rounding and the two disagree at 112.5% — any
//! script that re-derives these numbers must use that helper, not its own.

const std = @import("std");

/// Gap between the card and the pane edges, DIP. The same 12 as
/// `banner_card.MARGIN` and the viewer TOC card, deliberately: docs/claude/viewers.md's
/// "margins are one number" rule is what makes a card in one pane line up with
/// a card in the pane next door.
pub const MARGIN_DIP: f32 = 12;

/// Inner padding between the card edge and its text, DIP.
pub const PADDING_DIP: f32 = 16;

/// Corner radius, DIP. The design system's card radius (§6).
pub const RADIUS_DIP: f32 = 8;

/// Gap between the message line and the hint line, DIP.
pub const LINE_GAP_DIP: f32 = 8;

/// The widest the card is allowed to get, DIP. A message line set across a
/// 3000 px ultrawide pane is unreadable; past this the card stops growing and
/// centers instead.
pub const MAX_WIDTH_DIP: f32 = 420;

/// The narrowest card worth painting, DIP. Below this the caller paints the
/// pane background alone — a card with no room for a word in it is noise.
pub const MIN_WIDTH_DIP: f32 = 160;

/// Line heights, DIP. Body for the message, caption for the hint — the
/// `type_ramp` sizes, kept here as HEIGHTS because the card reserves space
/// before it has a device context to measure with.
pub const MESSAGE_LINE_DIP: f32 = 20;
pub const HINT_LINE_DIP: f32 = 16;

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

/// Scaled-pixel geometry of one card inside a pane's client area. All values
/// are physical pixels relative to the pane's client origin.
pub const Metrics = struct {
    /// The card itself.
    card: Rect,
    /// The message line, inside the card.
    message: Rect,
    /// The hint line, below the message.
    hint: Rect,
    /// Corner radius in px, for `RoundRect`.
    radius: i32,
    /// Scaled margin/padding, exposed so the painter and the tests share one
    /// source for the numbers they check.
    margin: i32,
    padding: i32,
};

fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

/// Lay out the card for a pane of `w` x `h` physical pixels at `scale`.
///
/// Returns null when the pane cannot hold a card that clears its own margins —
/// the caller paints just the background then. Null rather than a degenerate
/// rect on purpose: a card 3 px wide is a smear, and "should I paint one" is a
/// question with an answer, not a rectangle to be clamped into meaninglessness.
pub fn layout(w: i32, h: i32, scale: f32) ?Metrics {
    const margin = px(MARGIN_DIP, scale);
    const padding = px(PADDING_DIP, scale);
    const gap = px(LINE_GAP_DIP, scale);
    const msg_h = px(MESSAGE_LINE_DIP, scale);
    const hint_h = px(HINT_LINE_DIP, scale);

    // Content sizes the card; the pane only ever CAPS it (design system §4:
    // size the container to the control, not the reverse).
    const avail_w = w - 2 * margin;
    const avail_h = h - 2 * margin;
    const card_h = 2 * padding + msg_h + gap + hint_h;
    if (avail_w < px(MIN_WIDTH_DIP, scale)) return null;
    if (avail_h < card_h) return null;

    const card_w = @min(avail_w, px(MAX_WIDTH_DIP, scale));

    // Centered in the pane, with any odd pixel of slack going below/right —
    // `@divFloor`, so the result is identical for a negative origin (a pane
    // laid out at a negative left never happens, but a rule that only holds
    // for positives is a rule waiting to be broken).
    const left = @divFloor(w - card_w, 2);
    const top = @divFloor(h - card_h, 2);

    const card: Rect = .{
        .left = left,
        .top = top,
        .right = left + card_w,
        .bottom = top + card_h,
    };
    const text_left = card.left + padding;
    const text_right = card.right - padding;
    const message: Rect = .{
        .left = text_left,
        .top = card.top + padding,
        .right = text_right,
        .bottom = card.top + padding + msg_h,
    };
    const hint: Rect = .{
        .left = text_left,
        .top = message.bottom + gap,
        .right = text_right,
        .bottom = message.bottom + gap + hint_h,
    };

    return .{
        .card = card,
        .message = message,
        .hint = hint,
        .radius = px(RADIUS_DIP, scale),
        .margin = margin,
        .padding = padding,
    };
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

/// The scales the design system requires every geometry module to be asserted
/// at: most of these defects are invisible at 1.0 and obvious at 1.25.
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "every constant sits on the 4 DIP spacing scale" {
    // Design system §1. An off-scale value is a defect even when it looks fine
    // in isolation, so it is checked here rather than eyeballed.
    const spacing = [_]f32{ MARGIN_DIP, PADDING_DIP, RADIUS_DIP, LINE_GAP_DIP };
    for (spacing) |v| try testing.expectEqual(@as(f32, 0), @mod(v, 4));
}

test "the card clears the pane edge, and the text clears the card edge" {
    // Design system §2: nothing touches anything, and gaps are measured
    // between PAINTED edges.
    for (scales) |scale| {
        const m = layout(1200, 800, scale).?;
        try testing.expect(m.card.left >= m.margin);
        try testing.expect(m.card.top >= m.margin);
        try testing.expect(1200 - m.card.right >= m.margin);
        try testing.expect(800 - m.card.bottom >= m.margin);

        try testing.expectEqual(m.card.left + m.padding, m.message.left);
        try testing.expectEqual(m.card.right - m.padding, m.message.right);
        try testing.expectEqual(m.card.top + m.padding, m.message.top);
        try testing.expectEqual(m.card.bottom - m.padding, m.hint.bottom);
        try testing.expect(m.hint.top > m.message.bottom); // the lines never touch
    }
}

test "the card is sized to its content and capped, never stretched to the pane" {
    for (scales) |scale| {
        const wide = layout(3000, 900, scale).?;
        try testing.expectEqual(px(MAX_WIDTH_DIP, scale), wide.card.width());

        // Below the cap it takes what the pane allows, minus its margins.
        const narrow_w = px(MAX_WIDTH_DIP, scale) - px(40, scale);
        const narrow = layout(narrow_w, 900, scale).?;
        try testing.expectEqual(narrow_w - 2 * narrow.margin, narrow.card.width());
    }
}

test "the card is centered, and its height is the sum of its parts" {
    for (scales) |scale| {
        const m = layout(1000, 700, scale).?;
        const left_gap = m.card.left;
        const right_gap = 1000 - m.card.right;
        // Centered to within the odd pixel that cannot be split.
        try testing.expect(@abs(left_gap - right_gap) <= 1);
        const top_gap = m.card.top;
        const bottom_gap = 700 - m.card.bottom;
        try testing.expect(@abs(top_gap - bottom_gap) <= 1);

        const expect_h = 2 * m.padding +
            px(MESSAGE_LINE_DIP, scale) +
            px(LINE_GAP_DIP, scale) +
            px(HINT_LINE_DIP, scale);
        try testing.expectEqual(expect_h, m.card.height());
    }
}

test "a pane too small for a card gets none instead of a broken one" {
    for (scales) |scale| {
        // Too narrow: below the minimum readable width plus its margins.
        try testing.expectEqual(@as(?Metrics, null), layout(px(MIN_WIDTH_DIP, scale), 600, scale));
        // Too short: not even the card's own height fits between the margins.
        try testing.expectEqual(@as(?Metrics, null), layout(1200, px(24, scale), scale));
        // Degenerate panes (a split dragged to nothing) must not trap.
        try testing.expectEqual(@as(?Metrics, null), layout(0, 0, scale));
        try testing.expectEqual(@as(?Metrics, null), layout(1, 1, scale));
    }
}

test "the smallest pane that DOES get a card is a whole one" {
    // The boundary case in both directions: one pixel under the threshold is
    // null, and the threshold itself produces a card that still obeys every
    // rule above. A layout module whose edge case is only tested from the
    // comfortable side is untested at its edge.
    for (scales) |scale| {
        const margin = px(MARGIN_DIP, scale);
        const min_w = px(MIN_WIDTH_DIP, scale) + 2 * margin;
        const card_h = 2 * px(PADDING_DIP, scale) +
            px(MESSAGE_LINE_DIP, scale) +
            px(LINE_GAP_DIP, scale) +
            px(HINT_LINE_DIP, scale);
        const min_h = card_h + 2 * margin;

        try testing.expectEqual(@as(?Metrics, null), layout(min_w - 1, min_h, scale));
        try testing.expectEqual(@as(?Metrics, null), layout(min_w, min_h - 1, scale));

        const m = layout(min_w, min_h, scale).?;
        try testing.expect(m.card.width() >= px(MIN_WIDTH_DIP, scale));
        try testing.expect(m.message.right > m.message.left);
        try testing.expect(m.hint.right > m.hint.left);
        try testing.expectEqual(card_h, m.card.height());
    }
}

test "scaling is @round, not truncation" {
    // 1.25 is where truncation and rounding disagree for these numbers, and it
    // is the scale this box runs at. Asserting the values rather than the
    // formula is what catches a copy of it drifting elsewhere.
    try testing.expectEqual(@as(i32, 15), px(MARGIN_DIP, 1.25)); // 12 * 1.25
    try testing.expectEqual(@as(i32, 20), px(PADDING_DIP, 1.25)); // 16 * 1.25
    try testing.expectEqual(@as(i32, 10), px(RADIUS_DIP, 1.25)); // 8 * 1.25
    try testing.expectEqual(@as(i32, 18), px(MARGIN_DIP, 1.5)); // 12 * 1.5
    // 12 * 1.125 = 13.5 -> 14 half-away-from-zero; banker's rounding says 14
    // too, but 20 * 1.125 = 22.5 -> 23 here and 22 in PowerShell. That is the
    // divergence ChromeGeometry.ps1 exists for.
    try testing.expectEqual(@as(i32, 23), px(MESSAGE_LINE_DIP, 1.125));
}
