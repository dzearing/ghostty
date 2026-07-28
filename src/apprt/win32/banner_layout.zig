//! Pure layout math for the sticky pane banner strip (T101): how much of
//! a pane's layout slot the banner reserves ABOVE the terminal surface.
//! The window layout shrinks/offsets the terminal HWND by this inset so
//! the grid genuinely starts below the strip (Mac VStack parity — the
//! banner sits above the terminal, never over it). Unit tested in every
//! app-runtime lane (the hero_math/dim_math pattern).

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
