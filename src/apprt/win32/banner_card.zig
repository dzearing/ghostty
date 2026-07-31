//! Pure pixel math for the pane banner's floating glass CARD (T131), the
//! Windows port of the Mac `GlassCard` / `GlassCardBackground`
//! (`macos/Sources/Helpers/GlassCard.swift`): a rounded, shadowed card that
//! floats inside the reserved banner band instead of a flat edge-to-edge
//! strip.
//!
//! Two things make this a pure module rather than GDI calls:
//!
//! 1. GDI has no antialiased rounded rectangle and no soft shadow. Both are
//!    computed here per pixel — an analytic rounded-rect SDF for the card
//!    (coverage = the pixel's overlap with the shape) and a smoothstep of
//!    the same SDF for the shadow, which approximates a gaussian blur of the
//!    shape without an actual blur pass.
//! 2. The card is composited against the pane background ONCE, here, so the
//!    overlay window can stay fully opaque. The old strip was a translucent
//!    layered window, which let stale terminal pixels behind the band show
//!    through — that see-through IS the user-reported "text scrolling behind
//!    the banner" (T131). A card composited over a known backdrop looks the
//!    same as Mac's translucent glass without ever letting content through.
//!
//! Output is plain 32-bit `0x00RRGGBB` for a BI_RGB DIB section that gets
//! BitBlt'd (not AlphaBlend'd) — no premultiplied alpha anywhere.
//! Unit tested in every app-runtime lane (the hero_math/dim_math pattern).

const std = @import("std");
const color_math = @import("color_math.zig");

const Rgb = color_math.Rgb;

/// Margin between the card and the band edges, unscaled px. Mac:
/// `GlassCard.outerMargin` — UNIFORM on all four sides, deliberately (a
/// per-side fudge is what makes a banner and a viewer TOC card fail to line
/// up at their corners).
pub const MARGIN: f32 = 12.0;

/// Card corner radius, unscaled px. Mac: `GlassCard.cornerRadius` (14, with
/// a continuous squircle; GDI has no squircle, so a plain rounded rect).
pub const RADIUS: f32 = 14.0;

/// Uniform inner padding between the card edge and its content, unscaled px.
/// Mac: `GlassCard.innerPadding`.
pub const PADDING: f32 = 12.0;

/// Elevation shadow: blur radius and downward offset, unscaled px, and the
/// black alpha at full coverage. Mac: `.blur(radius: 8).offset(y: 4)` over
/// `Color.black.opacity(0.3)`.
pub const SHADOW_BLUR: f32 = 8.0;
pub const SHADOW_DY: f32 = 4.0;
pub const SHADOW_ALPHA: f32 = 0.30;

/// Card fill: a wash over the backdrop — white at 6% on a dark background,
/// black at 4% on a light one. Mac: `GlassCard.fill(isLightBackground:)`.
/// Compositing white at 6% is exactly `lighten(0.06)` of the color behind.
pub const FILL_LIGHTEN: f32 = 0.06;
pub const FILL_DARKEN: f32 = 0.04;

/// Specular rim (hairline border) alpha, brightest at the top and nearly
/// gone along the bottom. Mac: elliptical gradient 0.28 → 0.10 → 0.04.
/// Public because the tab strip's rim is the SAME rim (T206 — "tabs should
/// have similar borders to the banner. It should feel cohesive"). Importing
/// these beats copying them: a copy stops matching the first time either side
/// is tuned, and nobody notices until the user does.
pub const RIM_TOP: f32 = 0.28;
pub const RIM_BOT: f32 = 0.04;

/// Specular sheen: white at 10% bulging down into the top of the card and
/// falling away, plus a faint darkening along the bottom edge to ground it.
/// Mac: an elliptical gradient centered above the card + a linear one below.
const SHEEN_TOP: f32 = 0.10;
const SHEEN_BOTTOM_DARK: f32 = 0.05;

/// The card's fill color: the wash already composited over `bg`, so callers
/// that need a solid color (text antialiasing backdrop, harness oracles)
/// have the exact same value the card paints.
///
/// This is an ALPHA COMPOSITE of white (or black), not `color_math.lighten`
/// — that one is an HSB-brightness lift, which keeps saturation and so
/// lands on a different color than Mac's `Color.white.opacity(0.06)` over
/// the same backdrop.
pub fn fillColor(bg: Rgb) Rgb {
    const q = struct {
        fn ch(c: u8, toward: f32, a: f32) u8 {
            const v: f32 = @floatFromInt(c);
            return @intFromFloat(std.math.clamp(@round(v + (toward - v) * a), 0.0, 255.0));
        }
    };
    if (color_math.isLight(bg)) return .{
        .r = q.ch(bg.r, 0, FILL_DARKEN),
        .g = q.ch(bg.g, 0, FILL_DARKEN),
        .b = q.ch(bg.b, 0, FILL_DARKEN),
    };
    return .{
        .r = q.ch(bg.r, 255, FILL_LIGHTEN),
        .g = q.ch(bg.g, 255, FILL_LIGHTEN),
        .b = q.ch(bg.b, 255, FILL_LIGHTEN),
    };
}

/// Scaled-pixel geometry of one card inside its band.
pub const Metrics = struct {
    /// Band size in px (the overlay window's client area).
    w: i32,
    h: i32,
    /// Scaled margin, radius, shadow blur/offset.
    margin: f32,
    radius: f32,
    shadow_blur: f32 = SHADOW_BLUR,
    shadow_dy: f32 = SHADOW_DY,

    /// Metrics for a band of `w` × `h` px at DPI `scale`.
    pub fn init(w: i32, h: i32, scale: f32) Metrics {
        return .{
            .w = w,
            .h = h,
            .margin = MARGIN * scale,
            .radius = RADIUS * scale,
            .shadow_blur = SHADOW_BLUR * scale,
            .shadow_dy = SHADOW_DY * scale,
        };
    }

    /// The card rect inside the band (floats, pixel edges). Degenerate
    /// bands (shorter than two margins) keep a 1px card rather than
    /// inverting.
    pub fn card(self: Metrics) Rect {
        const w: f32 = @floatFromInt(self.w);
        const h: f32 = @floatFromInt(self.h);
        return .{
            .left = @min(self.margin, @max(w - 1, 0)),
            .top = @min(self.margin, @max(h - 1, 0)),
            .right = @max(w - self.margin, @min(self.margin, w) + 1),
            .bottom = @max(h - self.margin, @min(self.margin, h) + 1),
        };
    }
};

pub const Rect = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    pub fn width(self: Rect) f32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) f32 {
        return self.bottom - self.top;
    }
};

/// Signed distance from (`x`, `y`) to a rounded rect: negative inside,
/// positive outside, in px. The standard IQ formulation.
pub fn sdRoundRect(x: f32, y: f32, r: Rect, radius: f32) f32 {
    const cx = (r.left + r.right) * 0.5;
    const cy = (r.top + r.bottom) * 0.5;
    const hw = r.width() * 0.5;
    const hh = r.height() * 0.5;
    const rad = @min(radius, @min(hw, hh));
    const qx = @abs(x - cx) - (hw - rad);
    const qy = @abs(y - cy) - (hh - rad);
    const ax = @max(qx, 0.0);
    const ay = @max(qy, 0.0);
    return @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0.0) - rad;
}

/// Antialiased coverage of a shape from its signed distance: 1 well inside,
/// 0 well outside, a linear ramp across the boundary pixel.
fn coverage(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0.0, 1.0);
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge1 <= edge0) return if (x < edge0) 0.0 else 1.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

const Frgb = struct {
    r: f32,
    g: f32,
    b: f32,

    fn from(c: Rgb) Frgb {
        return .{
            .r = @floatFromInt(c.r),
            .g = @floatFromInt(c.g),
            .b = @floatFromInt(c.b),
        };
    }

    fn over(self: Frgb, top: Frgb, alpha: f32) Frgb {
        return .{
            .r = mix(self.r, top.r, alpha),
            .g = mix(self.g, top.g, alpha),
            .b = mix(self.b, top.b, alpha),
        };
    }

    fn pack(self: Frgb) u32 {
        const q = struct {
            fn ch(v: f32) u32 {
                return @intFromFloat(std.math.clamp(@round(v), 0.0, 255.0));
            }
        };
        return (q.ch(self.r) << 16) | (q.ch(self.g) << 8) | q.ch(self.b);
    }
};

const WHITE = Frgb{ .r = 255, .g = 255, .b = 255 };
const BLACK = Frgb{ .r = 0, .g = 0, .b = 0 };

/// Paint the band: the pane background everywhere, the elevation shadow,
/// then the card (wash fill + specular sheen + hairline rim) floating
/// `margin` px inside every edge. `pixels` is a top-down `w * h` buffer of
/// `0x00RRGGBB`; `bg` is the pane's own background (what the band would
/// otherwise show).
pub fn render(pixels: []u32, m: Metrics, bg: Rgb) void {
    if (m.w <= 0 or m.h <= 0) return;
    const w: usize = @intCast(m.w);
    const h: usize = @intCast(m.h);
    if (pixels.len < w * h) return;

    const bg_f = Frgb.from(bg);
    const bg_packed = bg_f.pack();
    const fill_f = Frgb.from(fillColor(bg));
    const card = m.card();
    const ch = card.height();

    // Shadow shape: the card, pushed down. Blurred by a smoothstep of its
    // own SDF, which is what a gaussian of a large rounded shape looks like
    // everywhere except very tight corners.
    const shadow = Rect{
        .left = card.left,
        .top = card.top + m.shadow_dy,
        .right = card.right,
        .bottom = card.bottom + m.shadow_dy,
    };

    // Rows/columns this far inside the card need no SDF at all: full card
    // coverage, no rim, no shadow. That is the bulk of a wide banner.
    const inner = m.radius + 1.0;

    for (0..h) |row| {
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        const y_inside = y >= card.top + inner and y <= card.bottom - inner;
        // Vertical position within the card, for the sheen and rim ramps.
        const t = if (ch > 0) std.math.clamp((y - card.top) / ch, 0.0, 1.0) else 0.0;
        const sheen_a = SHEEN_TOP * (1.0 - t) * (1.0 - t);
        const sheen_dark = SHEEN_BOTTOM_DARK * smoothstep(0.75, 1.0, t);
        const rim_a = mix(RIM_TOP, RIM_BOT, smoothstep(0.0, 1.0, t));
        const line = pixels[row * w ..][0..w];

        for (line, 0..) |*p, col| {
            const x = @as(f32, @floatFromInt(col)) + 0.5;

            var cov_card: f32 = undefined;
            var cov_rim: f32 = 0.0;
            var cov_shadow: f32 = 0.0;
            if (y_inside and x >= card.left + inner and x <= card.right - inner) {
                cov_card = 1.0;
            } else {
                const sd = sdRoundRect(x, y, card, m.radius);
                cov_card = coverage(sd);
                // Hairline rim: the outer edge minus the same shape inset
                // by one px, so it hugs the antialiased boundary.
                cov_rim = @max(cov_card - coverage(sd + 1.0), 0.0);
                if (cov_card < 1.0) {
                    const sds = sdRoundRect(x, y, shadow, m.radius);
                    cov_shadow = 1.0 - smoothstep(-m.shadow_blur, m.shadow_blur, sds);
                }
            }

            var c = bg_f;
            // Shadow, with the card's own interior masked out of it (Mac
            // masks the shape out of its blurred copy so the translucent
            // wash is not darkened from behind).
            if (cov_shadow > 0.0) {
                c = c.over(BLACK, SHADOW_ALPHA * cov_shadow * (1.0 - cov_card));
            }
            if (cov_card > 0.0) {
                c = c.over(fill_f, cov_card);
                if (sheen_a > 0.0) c = c.over(WHITE, sheen_a * cov_card);
                if (sheen_dark > 0.0) c = c.over(BLACK, sheen_dark * cov_card);
                if (cov_rim > 0.0) c = c.over(WHITE, rim_a * cov_rim);
            }
            p.* = if (cov_card == 0.0 and cov_shadow == 0.0) bg_packed else c.pack();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const DARK = Rgb{ .r = 16, .g = 16, .b = 20 };

fn at(pixels: []const u32, m: Metrics, x: i32, y: i32) u32 {
    return pixels[@intCast(y * m.w + x)];
}

fn lum(p: u32) u32 {
    return ((p >> 16) & 0xFF) + ((p >> 8) & 0xFF) + (p & 0xFF);
}

test "fillColor: Mac's wash formula, both polarities" {
    // Dark backdrop → white at 6% over it, per channel.
    try testing.expectEqual(Rgb{ .r = 30, .g = 30, .b = 34 }, fillColor(DARK));
    // Light backdrop → black at 4% over it.
    const light = Rgb{ .r = 250, .g = 250, .b = 248 };
    try testing.expectEqual(Rgb{ .r = 240, .g = 240, .b = 238 }, fillColor(light));
    // ...which is NOT the HSB-brightness lift: keeping saturation lands
    // somewhere else, and the card must match Mac's alpha composite.
    try testing.expect(!std.meta.eql(color_math.lighten(DARK, FILL_LIGHTEN), fillColor(DARK)));
}

test "Metrics.card: uniform margin on all four sides" {
    const m = Metrics.init(400, 100, 1.0);
    const c = m.card();
    try testing.expectEqual(@as(f32, 12), c.left);
    try testing.expectEqual(@as(f32, 12), c.top);
    try testing.expectEqual(@as(f32, 388), c.right);
    try testing.expectEqual(@as(f32, 88), c.bottom);
    // Same margin left/right and top/bottom — no per-side fudge.
    try testing.expectEqual(c.left, @as(f32, 400) - c.right);
    try testing.expectEqual(c.top, @as(f32, 100) - c.bottom);
}

test "Metrics.card: DPI scale multiplies the margin" {
    const m = Metrics.init(400, 100, 2.0);
    const c = m.card();
    try testing.expectEqual(@as(f32, 24), c.left);
    try testing.expectEqual(@as(f32, 376), c.right);
    try testing.expectEqual(@as(f32, 28), m.radius);
}

test "Metrics.card: degenerate band never inverts" {
    const m = Metrics.init(10, 6, 1.0);
    const c = m.card();
    try testing.expect(c.right > c.left);
    try testing.expect(c.bottom > c.top);
}

test "sdRoundRect: inside negative, outside positive, corner clipped" {
    const r = Rect{ .left = 10, .top = 10, .right = 110, .bottom = 60 };
    try testing.expect(sdRoundRect(60, 35, r, 14) < 0); // center
    try testing.expect(sdRoundRect(5, 35, r, 14) > 0); // left of it
    // The rounded corner cuts the square corner off.
    try testing.expect(sdRoundRect(10.5, 10.5, r, 14) > 0);
    // ...while the same point on a square rect is inside.
    try testing.expect(sdRoundRect(10.5, 10.5, r, 0) < 0);
}

test "render: the band's own corners stay the pane background" {
    const m = Metrics.init(200, 80, 1.0);
    var px: [200 * 80]u32 = undefined;
    render(&px, m, DARK);
    const bg = Frgb.from(DARK).pack();
    try testing.expectEqual(bg, at(&px, m, 0, 0));
    try testing.expectEqual(bg, at(&px, m, 199, 0));
    // Mid-height, hard against the left edge: outside the shadow's reach.
    try testing.expectEqual(bg, at(&px, m, 0, 40));
}

test "render: the card's rounded corner is cut away" {
    const m = Metrics.init(200, 80, 1.0);
    var px: [200 * 80]u32 = undefined;
    render(&px, m, DARK);
    // Just inside the card's bounding box at the top-left, but outside the
    // 14px radius: still (shadow-darkened) background, not card fill.
    const corner = at(&px, m, 13, 13);
    const center = at(&px, m, 100, 40);
    try testing.expect(corner != center);
    try testing.expect(lum(corner) < lum(center));
}

test "render: the card interior is the wash fill over the backdrop" {
    const m = Metrics.init(200, 80, 1.0);
    var px: [200 * 80]u32 = undefined;
    render(&px, m, DARK);
    const fill = fillColor(DARK);
    // Sample where neither specular ramp is meaningfully in play: the sheen
    // has faded out and the bottom darkening has not started (it ramps in
    // from 75% of the card's height).
    const p = at(&px, m, 100, 12 + @as(i32, @intFromFloat(0.72 * 56.0)));
    const dr = @abs(@as(i32, @intCast((p >> 16) & 0xFF)) - @as(i32, fill.r));
    const dg = @abs(@as(i32, @intCast((p >> 8) & 0xFF)) - @as(i32, fill.g));
    const db = @abs(@as(i32, @intCast(p & 0xFF)) - @as(i32, fill.b));
    try testing.expect(dr <= 4 and dg <= 4 and db <= 4);
}

test "render: a soft shadow falls below the card" {
    const m = Metrics.init(200, 80, 1.0);
    var px: [200 * 80]u32 = undefined;
    render(&px, m, DARK);
    const bg = lum(Frgb.from(DARK).pack());
    // Two px under the card's bottom edge, mid-width: darker than the bare
    // background...
    const near = lum(at(&px, m, 100, 70));
    try testing.expect(near < bg);
    // ...and the darkening fades out toward the band edge.
    const far = lum(at(&px, m, 100, 79));
    try testing.expect(far >= near);
}

test "render: the rim lights the card's top edge" {
    const m = Metrics.init(200, 80, 1.0);
    var px: [200 * 80]u32 = undefined;
    render(&px, m, DARK);
    const top_edge = lum(at(&px, m, 100, 12));
    const interior = lum(at(&px, m, 100, 30));
    try testing.expect(top_edge > interior);
}

test "render: light backdrop darkens instead of lightening" {
    const light = Rgb{ .r = 250, .g = 250, .b = 248 };
    const m = Metrics.init(200, 80, 1.0);
    var px: [200 * 80]u32 = undefined;
    render(&px, m, light);
    const bg = lum(Frgb.from(light).pack());
    const interior = lum(at(&px, m, 100, 40));
    try testing.expect(interior < bg);
}

test "render: degenerate sizes do not write out of bounds" {
    var px: [64]u32 = @splat(0);
    render(&px, Metrics.init(0, 0, 1.0), DARK);
    render(&px, Metrics.init(-4, 10, 1.0), DARK);
    // Buffer too small for the claimed size: refuse rather than overrun.
    render(&px, Metrics.init(100, 100, 1.0), DARK);
    try testing.expectEqual(@as(u32, 0), px[0]);
    // A tiny but valid band paints.
    render(&px, Metrics.init(8, 8, 1.0), DARK);
    try testing.expect(px[0] != 0);
}
