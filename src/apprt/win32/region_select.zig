//! The region selector's rect math (T647), the pure half of the feedback
//! composer's screenshot capture.
//!
//! A drag has two corners and no order: the user may pull the rectangle out of
//! any of its four corners, and the one they started from is whichever they
//! pressed on. Everything downstream — the crop out of the screen snapshot, the
//! bright window painted over the dim, the PNG's width and height — wants a
//! NORMALIZED rect instead: a top-left origin and a non-negative size. Getting
//! that wrong is invisible in a right-and-down drag, which is the one a
//! developer tries first, and produces an empty or inverted crop in the other
//! three.
//!
//! It is also where "a click is not a screenshot" lives. A zero-area drag —
//! press and release without moving, or a drag along a single row or column —
//! is a CANCEL, not an empty image: a 0x0 PNG is not something anybody asked
//! for, and a 200x0 one is worse because it looks like it worked.
//!
//! No OS imports, so this asserts in every app-runtime lane.

const std = @import("std");

pub const Point = struct { x: i32, y: i32 };

/// A rectangle in virtual-screen (physical pixel) coordinates. `x`/`y` may be
/// negative — a monitor left of or above the primary one lives there, and the
/// capture path must not assume the desktop starts at the origin.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x < self.right() and
            p.y >= self.y and p.y < self.bottom();
    }
};

/// The rectangle a drag from `a` to `b` selects, normalized — or null when it
/// has no area.
///
/// The two points are treated as PIXEL CORNERS the way a marquee is: the
/// selection spans from the smaller coordinate up to (not including) the
/// larger, so dragging from x=10 to x=14 selects four columns, not five. That
/// is the convention every crop in this path already uses, and it is what makes
/// a press-with-no-motion fall out as zero rather than as one stray pixel.
pub fn dragRect(a: Point, b: Point) ?Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const w = @max(a.x, b.x) - x0;
    const h = @max(a.y, b.y) - y0;
    if (w <= 0 or h <= 0) return null;
    return .{ .x = x0, .y = y0, .w = w, .h = h };
}

/// `r` clipped to `bounds`, or null when nothing of it survives.
///
/// The selector's window covers the whole virtual screen, so in practice a drag
/// cannot leave it — but a captured pointer keeps reporting coordinates after it
/// has been dragged past the edge (and off the desktop entirely, on a
/// non-rectangular multi-monitor arrangement), and those coordinates would index
/// outside the snapshot's pixels.
pub fn clampTo(r: Rect, bounds: Rect) ?Rect {
    const x0 = @max(r.x, bounds.x);
    const y0 = @max(r.y, bounds.y);
    const x1 = @min(r.right(), bounds.right());
    const y1 = @min(r.bottom(), bounds.bottom());
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// The selection a drag produces against a bounded desktop: normalized, then
/// clipped. Null when either step leaves nothing — which is the single
/// "nothing was captured" answer the selector acts on.
pub fn selection(a: Point, b: Point, bounds: Rect) ?Rect {
    const r = dragRect(a, b) orelse return null;
    return clampTo(r, bounds);
}

/// A rect expressed relative to `bounds`'s origin — the offset into the
/// snapshot's own pixel buffer, whose (0,0) is the virtual screen's top-left
/// corner rather than the desktop origin.
pub fn relativeTo(r: Rect, bounds: Rect) Rect {
    return .{ .x = r.x - bounds.x, .y = r.y - bounds.y, .w = r.w, .h = r.h };
}

// -------------------------------------------------------------------- chrome

/// The selection's outline. 2 DIP is the design system's divider weight, and
/// this is the same kind of thing: a meaningful boundary, which must clear the
/// 3:1 contrast floor against BOTH the dimmed desktop outside it and the bright
/// one inside.
pub const border_dip: f32 = 2.0;

/// The hint card's distance from the top of the monitor the capture started on.
/// `24` — the largest step on the 4 DIP scale, because this floats over
/// arbitrary content and needs to read as detached from it.
pub const hint_margin_dip: f32 = 24.0;

/// The hint card's inner padding. `12` across and `8` down: the same
/// text-inside-a-card pair the banner and composer use.
pub const hint_pad_x_dip: f32 = 12.0;
pub const hint_pad_y_dip: f32 = 8.0;

/// Card radius (design system §3.1's `8`). The hint is a floating card, not a
/// button and not a capsule.
pub const hint_radius_dip: f32 = 8.0;

/// How dark the un-selected desktop is painted, out of 255. Dark enough that
/// the bright selection is unmistakable, light enough that the user can still
/// see what they are about to drag over — a dim that hides the content defeats
/// the point of dragging over it.
pub const dim_numerator: u32 = 110;

pub fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

/// Where the "drag to capture" card sits: horizontally centered on `home` (the
/// monitor the pointer was on when the capture began, NOT the virtual screen,
/// whose center can be a bezel), one margin below its top edge.
///
/// `text_w`/`text_h` are the measured text extent in physical pixels; the card
/// is that plus padding. A card wider than the monitor is pinned to the
/// monitor's left edge rather than allowed to start off-screen.
pub fn hintBox(home: Rect, scale: f32, text_w: i32, text_h: i32) Rect {
    const w = text_w + 2 * px(hint_pad_x_dip, scale);
    const h = text_h + 2 * px(hint_pad_y_dip, scale);
    const x = home.x + @max(0, @divTrunc(home.w - w, 2));
    return .{ .x = x, .y = home.y + px(hint_margin_dip, scale), .w = w, .h = h };
}

// -------------------------------------------------------------- chrome tests

const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "hintBox: centered on the home monitor, one margin down, at every scale" {
    // Two monitors: the primary, and a second one to its LEFT. The card must
    // follow the monitor it was asked for, not the virtual screen's middle,
    // which here is the bezel between them.
    const left: Rect = .{ .x = -1920, .y = 0, .w = 1920, .h = 1080 };
    const primary: Rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 };

    for (scales) |s| {
        const text_w = px(300, s);
        const text_h = px(18, s);

        for ([_]Rect{ left, primary }) |home| {
            const card = hintBox(home, s, text_w, text_h);

            // Inside its own monitor, and nowhere near the other one.
            try testing.expect(card.x >= home.x);
            try testing.expect(card.right() <= home.right());
            try testing.expect(card.y > home.y);
            try testing.expect(card.bottom() < home.bottom());

            // Centered: the slack on the two sides differs by at most the one
            // pixel an odd width cannot split.
            const lead = card.x - home.x;
            const trail = home.right() - card.right();
            try testing.expect(@abs(lead - trail) <= 1);

            // The padding is the padding, on both axes.
            try testing.expectEqual(text_w + 2 * px(hint_pad_x_dip, s), card.w);
            try testing.expectEqual(text_h + 2 * px(hint_pad_y_dip, s), card.h);

            // And it clears the monitor's top edge by the whole margin — 24
            // DIP is 24 physical pixels at 1.0 and 48 at 2.0, which is the
            // scaling bug that only shows up off 1.0.
            try testing.expectEqual(px(hint_margin_dip, s), card.y - home.y);
        }
    }
}

test "hintBox: text wider than the monitor pins to its left edge" {
    const home: Rect = .{ .x = 100, .y = 100, .w = 200, .h = 200 };
    const card = hintBox(home, 1.0, 500, 18);
    // Never starts left of the monitor, which is what a bare `(w - card.w)/2`
    // would do — the text is then clipped on the right, where a reader can at
    // least tell something is cut off.
    try testing.expectEqual(home.x, card.x);
}

test "px rounds rather than truncates" {
    // 2 DIP at 1.25 is 2.5 -> 3, not 2. A truncating scale is how a 2 DIP
    // divider disappears entirely at some scales and not others.
    try testing.expectEqual(@as(i32, 3), px(border_dip, 1.25));
    try testing.expectEqual(@as(i32, 2), px(border_dip, 1.0));
    try testing.expectEqual(@as(i32, 3), px(border_dip, 1.5));
    try testing.expectEqual(@as(i32, 4), px(border_dip, 2.0));
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "dragRect normalizes a drag pulled in any of the four directions" {
    const expected: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const tl: Point = .{ .x = 10, .y = 20 };
    const br: Point = .{ .x = 40, .y = 60 };
    const tr: Point = .{ .x = 40, .y = 20 };
    const bl: Point = .{ .x = 10, .y = 60 };

    // Down-right, the one a developer tries first.
    try testing.expectEqual(expected, dragRect(tl, br).?);
    // Up-left, which an unnormalized rect renders as a negative size.
    try testing.expectEqual(expected, dragRect(br, tl).?);
    // The two mixed directions, where only ONE axis is inverted — the pair a
    // "swap if x1 < x0" fix that forgot the other axis still gets wrong.
    try testing.expectEqual(expected, dragRect(tr, bl).?);
    try testing.expectEqual(expected, dragRect(bl, tr).?);
}

test "dragRect: a zero-area drag is nothing, not an empty picture" {
    // A click: press and release without moving.
    try testing.expect(dragRect(.{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }) == null);
    // A drag along one row, and one along one column. Both have a real extent
    // on one axis, which is exactly what makes them look like a capture until
    // the PNG comes out 200x0.
    try testing.expect(dragRect(.{ .x = 5, .y = 5 }, .{ .x = 205, .y = 5 }) == null);
    try testing.expect(dragRect(.{ .x = 5, .y = 5 }, .{ .x = 5, .y = 205 }) == null);
    // One pixel of motion on both axes IS a capture, however silly.
    try testing.expectEqual(
        Rect{ .x = 5, .y = 5, .w = 1, .h = 1 },
        dragRect(.{ .x = 5, .y = 5 }, .{ .x = 6, .y = 6 }).?,
    );
}

test "dragRect works in negative coordinates" {
    // A monitor left of and above the primary one. Nothing here may assume the
    // desktop starts at (0,0).
    try testing.expectEqual(
        Rect{ .x = -1920, .y = -300, .w = 400, .h = 200 },
        dragRect(.{ .x = -1520, .y = -100 }, .{ .x = -1920, .y = -300 }).?,
    );
}

test "clampTo clips to the desktop and rejects what falls off it" {
    const bounds: Rect = .{ .x = -100, .y = -50, .w = 1000, .h = 800 };

    // Wholly inside: untouched.
    const inside: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try testing.expectEqual(inside, clampTo(inside, bounds).?);

    // Hanging off the top-left and the bottom-right corners.
    try testing.expectEqual(
        Rect{ .x = -100, .y = -50, .w = 150, .h = 100 },
        clampTo(.{ .x = -500, .y = -400, .w = 550, .h = 450 }, bounds).?,
    );
    try testing.expectEqual(
        Rect{ .x = 800, .y = 700, .w = 100, .h = 50 },
        clampTo(.{ .x = 800, .y = 700, .w = 500, .h = 500 }, bounds).?,
    );

    // Entirely outside, and exactly touching the far edge: both are nothing.
    try testing.expect(clampTo(.{ .x = 900, .y = 0, .w = 100, .h = 100 }, bounds) == null);
    try testing.expect(clampTo(.{ .x = -600, .y = 0, .w = 100, .h = 100 }, bounds) == null);
}

test "selection: normalize then clip, in one answer" {
    const bounds: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };

    // Dragged up-left AND off the desktop's top-left corner.
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .w = 20, .h = 30 },
        selection(.{ .x = 20, .y = 30 }, .{ .x = -40, .y = -60 }, bounds).?,
    );
    // A click is still nothing after clipping.
    try testing.expect(selection(.{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }, bounds) == null);
    // A real drag entirely off the desktop is nothing too — normalization
    // succeeds and the clip is what rejects it.
    try testing.expect(selection(.{ .x = 200, .y = 200 }, .{ .x = 300, .y = 300 }, bounds) == null);
}

test "relativeTo rebases onto the snapshot's own buffer" {
    const bounds: Rect = .{ .x = -1920, .y = -180, .w = 3840, .h = 1260 };
    // The primary monitor's origin is 1920 pixels into the snapshot, not 0.
    try testing.expectEqual(
        Rect{ .x = 1920, .y = 180, .w = 200, .h = 100 },
        relativeTo(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, bounds),
    );
    // A rect at the snapshot's own origin rebases to (0,0).
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .w = 5, .h = 5 },
        relativeTo(.{ .x = -1920, .y = -180, .w = 5, .h = 5 }, bounds),
    );
}

test "Rect edges and containment" {
    const r: Rect = .{ .x = -10, .y = -10, .w = 20, .h = 20 };
    try testing.expectEqual(@as(i32, 10), r.right());
    try testing.expectEqual(@as(i32, 10), r.bottom());
    try testing.expect(r.contains(.{ .x = -10, .y = -10 }));
    try testing.expect(r.contains(.{ .x = 9, .y = 9 }));
    // The far edge is exclusive, the same convention `dragRect` spans.
    try testing.expect(!r.contains(.{ .x = 10, .y = 0 }));
    try testing.expect(!r.contains(.{ .x = 0, .y = 10 }));
}
