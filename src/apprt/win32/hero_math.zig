//! Pure geometry for the win32 hero-mode carousel (T58 design, T59a).
//! No OS imports so this compiles (and its tests run) in every app-runtime
//! lane. All numbers mirror the Mac HeroCarouselView/HeroModeState:
//!   - hero pane fills (1 - ratio) of the content width, full height, left
//!   - carousel column on the right; divider band between them
//!   - thumb width <= 88% of carousel width (6% padding each side)
//!   - thumb height = width / heroAR, capped at 70% of carousel height
//!     (width shrinks to preserve AR when the cap binds)
//!   - 8px gap between tiles; selected tile centered vertically
const std = @import("std");

/// Same field layout as w32.RECT so the win32 side can convert trivially.
pub const Rect = extern struct {
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
    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }
};

/// Mac clamps the user-adjustable carousel ratio to 0.1–0.6.
pub const RATIO_MIN: f32 = 0.1;
pub const RATIO_MAX: f32 = 0.6;
pub const RATIO_DEFAULT: f32 = 0.25;

pub fn clampRatio(ratio: f32) f32 {
    return @min(RATIO_MAX, @max(RATIO_MIN, ratio));
}

/// The hero/divider/carousel split of the content rect. The divider is a
/// 6px (scaled) hit band whose right edge sits at `ratio * width` from the
/// right; the visible line is thinner and painted centered in the band.
pub const Split = struct {
    hero: Rect,
    divider: Rect,
    carousel: Rect,
};

pub fn splitRects(content: Rect, ratio: f32, scale: f32) Split {
    const w = content.width();
    const carousel_w: i32 = @intFromFloat(@round(clampRatio(ratio) * @as(f32, @floatFromInt(w))));
    const band_w: i32 = @max(@as(i32, @intFromFloat(@round(6.0 * scale))), 2);
    var div_left = content.right - carousel_w - band_w;
    // Degenerate content (tiny window): keep rects ordered and non-negative.
    if (div_left < content.left) div_left = content.left;
    const div_right = @min(div_left + band_w, content.right);
    return .{
        .hero = .{
            .left = content.left,
            .top = content.top,
            .right = div_left,
            .bottom = content.bottom,
        },
        .divider = .{
            .left = div_left,
            .top = content.top,
            .right = div_right,
            .bottom = content.bottom,
        },
        .carousel = .{
            .left = div_right,
            .top = content.top,
            .right = content.right,
            .bottom = content.bottom,
        },
    };
}

/// Tile dimensions inside a carousel column, honoring the hero pane's
/// aspect ratio (hero_ar = hero width / hero height).
pub const TileLayout = struct {
    thumb_w: i32,
    thumb_h: i32,
    gap: i32,
};

pub fn tileLayout(carousel: Rect, hero_ar: f32, scale: f32) TileLayout {
    const cw: f32 = @floatFromInt(@max(carousel.width(), 1));
    const ch: f32 = @floatFromInt(@max(carousel.height(), 1));
    const ar = if (hero_ar > 0.01) hero_ar else 1.0;
    var tw = 0.88 * cw;
    var th = tw / ar;
    const cap = 0.70 * ch;
    if (th > cap) {
        th = cap;
        tw = th * ar;
        // The width cap still binds if the AR is extremely wide.
        if (tw > 0.88 * cw) {
            tw = 0.88 * cw;
            th = tw / ar;
        }
    }
    return .{
        .thumb_w = @max(@as(i32, @intFromFloat(@round(tw))), 1),
        .thumb_h = @max(@as(i32, @intFromFloat(@round(th))), 1),
        .gap = @max(@as(i32, @intFromFloat(@round(8.0 * scale))), 1),
    };
}

/// Y of tile 0's top edge such that the selected tile is centered
/// vertically in the carousel (Mac behavior), plus a scroll offset
/// (0 until T59b wheel scrolling).
pub fn stripTop(
    carousel: Rect,
    layout: TileLayout,
    selected: usize,
    scroll: i32,
) i32 {
    const mid = carousel.top + @divTrunc(carousel.height(), 2);
    const sel: i32 = @intCast(selected);
    const sel_center = sel * (layout.thumb_h + layout.gap) + @divTrunc(layout.thumb_h, 2);
    return mid - sel_center + scroll;
}

/// The rect of tile `index`, horizontally centered in the carousel.
pub fn tileRect(
    carousel: Rect,
    layout: TileLayout,
    top0: i32,
    index: usize,
) Rect {
    const i: i32 = @intCast(index);
    const x = carousel.left + @divTrunc(carousel.width() - layout.thumb_w, 2);
    const y = top0 + i * (layout.thumb_h + layout.gap);
    return .{
        .left = x,
        .top = y,
        .right = x + layout.thumb_w,
        .bottom = y + layout.thumb_h,
    };
}

/// Total height of the tile strip (`count` tiles + gaps between them).
pub fn stripHeight(layout: TileLayout, count: usize) i32 {
    if (count == 0) return 0;
    const n: i32 = @intCast(count);
    return n * layout.thumb_h + (n - 1) * layout.gap;
}

/// Clamp a wheel-scroll offset. Mac behavior: the strip scrolls at most
/// half the overflow either way (the selected tile stays centered at
/// scroll 0, so ±half-overflow reaches both strip ends); a strip that
/// fits entirely does not scroll at all.
pub fn clampScroll(
    scroll: i32,
    carousel: Rect,
    layout: TileLayout,
    count: usize,
) i32 {
    const overflow = stripHeight(layout, count) - carousel.height();
    if (overflow <= 0) return 0;
    const limit = @divTrunc(overflow + 1, 2);
    return @min(limit, @max(-limit, scroll));
}

/// Ease-in-out cubic (Mac's easeInEaseOut curve, close enough for GDI
/// animation parity). Input clamped to [0, 1].
pub fn easeInOutCubic(t: f32) f32 {
    const c = @min(@as(f32, 1.0), @max(@as(f32, 0.0), t));
    if (c < 0.5) return 4.0 * c * c * c;
    const u = -2.0 * c + 2.0;
    return 1.0 - (u * u * u) / 2.0;
}

/// Which tile (if any) contains the point. Mac selects on mouse-up
/// inside a tile.
pub fn hitTest(
    carousel: Rect,
    layout: TileLayout,
    top0: i32,
    count: usize,
    x: i32,
    y: i32,
) ?usize {
    if (!carousel.contains(x, y)) return null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (tileRect(carousel, layout, top0, i).contains(x, y)) return i;
    }
    return null;
}

test "splitRects basic 0.25 ratio" {
    const content: Rect = .{ .left = 0, .top = 32, .right = 1000, .bottom = 832 };
    const s = splitRects(content, 0.25, 1.0);
    // Carousel column is 250 wide; the 6px band sits to its left.
    try std.testing.expectEqual(@as(i32, 744), s.hero.right);
    try std.testing.expectEqual(@as(i32, 744), s.divider.left);
    try std.testing.expectEqual(@as(i32, 750), s.divider.right);
    try std.testing.expectEqual(@as(i32, 750), s.carousel.left);
    try std.testing.expectEqual(@as(i32, 1000), s.carousel.right);
    // Full height everywhere.
    try std.testing.expectEqual(@as(i32, 32), s.hero.top);
    try std.testing.expectEqual(@as(i32, 832), s.carousel.bottom);
}

test "splitRects clamps ratio to Mac bounds" {
    const content: Rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 };
    const lo = splitRects(content, 0.01, 1.0);
    try std.testing.expectEqual(@as(i32, 100), content.right - lo.carousel.left);
    const hi = splitRects(content, 0.99, 1.0);
    try std.testing.expectEqual(@as(i32, 600), content.right - hi.carousel.left);
}

test "splitRects degenerate tiny content stays ordered" {
    const content: Rect = .{ .left = 0, .top = 0, .right = 4, .bottom = 4 };
    const s = splitRects(content, 0.6, 2.0);
    try std.testing.expect(s.hero.left <= s.hero.right);
    try std.testing.expect(s.divider.left <= s.divider.right);
    try std.testing.expect(s.carousel.left <= s.carousel.right);
    try std.testing.expect(s.carousel.right == 4);
}

test "tileLayout uncapped follows width" {
    // Tall carousel: 70% height cap (560) does not bind.
    const carousel: Rect = .{ .left = 750, .top = 32, .right = 1000, .bottom = 832 };
    const l = tileLayout(carousel, 2.0, 1.0);
    try std.testing.expectEqual(@as(i32, 220), l.thumb_w); // 0.88 * 250
    try std.testing.expectEqual(@as(i32, 110), l.thumb_h); // AR 2.0
    try std.testing.expectEqual(@as(i32, 8), l.gap);
}

test "tileLayout height cap binds and preserves AR" {
    // Short carousel: cap = 0.7 * 100 = 70 < 220/2.
    const carousel: Rect = .{ .left = 750, .top = 0, .right = 1000, .bottom = 100 };
    const l = tileLayout(carousel, 2.0, 1.0);
    try std.testing.expectEqual(@as(i32, 70), l.thumb_h);
    try std.testing.expectEqual(@as(i32, 140), l.thumb_w); // 70 * 2.0
}

test "stripTop centers the selected tile" {
    const carousel: Rect = .{ .left = 750, .top = 0, .right = 1000, .bottom = 800 };
    const l: TileLayout = .{ .thumb_w = 220, .thumb_h = 110, .gap = 8 };
    // Selected tile 0: its center (top0 + 55) must be at carousel mid (400).
    try std.testing.expectEqual(@as(i32, 345), stripTop(carousel, l, 0, 0));
    // Selected tile 2: top0 + 2*118 + 55 == 400.
    try std.testing.expectEqual(@as(i32, 109), stripTop(carousel, l, 2, 0));
    // Scroll shifts linearly.
    try std.testing.expectEqual(@as(i32, 129), stripTop(carousel, l, 2, 20));
}

test "tileRect horizontal centering and stacking" {
    const carousel: Rect = .{ .left = 750, .top = 0, .right = 1000, .bottom = 800 };
    const l: TileLayout = .{ .thumb_w = 220, .thumb_h = 110, .gap = 8 };
    const r0 = tileRect(carousel, l, 100, 0);
    try std.testing.expectEqual(@as(i32, 765), r0.left); // 750 + (250-220)/2
    try std.testing.expectEqual(@as(i32, 100), r0.top);
    try std.testing.expectEqual(@as(i32, 210), r0.bottom);
    const r1 = tileRect(carousel, l, 100, 1);
    try std.testing.expectEqual(@as(i32, 218), r1.top); // 100 + 110 + 8
}

test "clampScroll: strip that fits does not scroll" {
    const carousel: Rect = .{ .left = 750, .top = 0, .right = 1000, .bottom = 800 };
    const l: TileLayout = .{ .thumb_w = 220, .thumb_h = 110, .gap = 8 };
    // 3 tiles: strip = 3*110 + 2*8 = 346 < 800 → overflow 0 → pinned to 0.
    try std.testing.expectEqual(@as(i32, 0), clampScroll(500, carousel, l, 3));
    try std.testing.expectEqual(@as(i32, 0), clampScroll(-500, carousel, l, 3));
}

test "clampScroll: overflow clamps to half either way" {
    const carousel: Rect = .{ .left = 750, .top = 0, .right = 1000, .bottom = 400 };
    const l: TileLayout = .{ .thumb_w = 220, .thumb_h = 110, .gap = 8 };
    // 5 tiles: strip = 5*110 + 4*8 = 582; overflow = 182; limit = 91.
    try std.testing.expectEqual(@as(i32, 91), clampScroll(500, carousel, l, 5));
    try std.testing.expectEqual(@as(i32, -91), clampScroll(-500, carousel, l, 5));
    try std.testing.expectEqual(@as(i32, 40), clampScroll(40, carousel, l, 5));
}

test "easeInOutCubic endpoints, midpoint, monotonic" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOutCubic(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), easeInOutCubic(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOutCubic(1.0), 1e-6);
    // Clamps outside [0,1].
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOutCubic(-2.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOutCubic(3.0), 1e-6);
    var prev: f32 = 0.0;
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        const v = easeInOutCubic(@as(f32, @floatFromInt(i)) / 20.0);
        try std.testing.expect(v >= prev);
        prev = v;
    }
}

test "hitTest finds tiles and rejects gaps/outside" {
    const carousel: Rect = .{ .left = 750, .top = 0, .right = 1000, .bottom = 800 };
    const l: TileLayout = .{ .thumb_w = 220, .thumb_h = 110, .gap = 8 };
    const top0 = 100;
    try std.testing.expectEqual(@as(?usize, 0), hitTest(carousel, l, top0, 3, 800, 150));
    try std.testing.expectEqual(@as(?usize, 1), hitTest(carousel, l, top0, 3, 800, 250));
    // In the gap between tiles 0 and 1.
    try std.testing.expectEqual(@as(?usize, null), hitTest(carousel, l, top0, 3, 800, 213));
    // Left of the carousel (hero region).
    try std.testing.expectEqual(@as(?usize, null), hitTest(carousel, l, top0, 3, 700, 150));
    // Beyond the last tile.
    try std.testing.expectEqual(@as(?usize, null), hitTest(carousel, l, top0, 3, 800, 700));
}
