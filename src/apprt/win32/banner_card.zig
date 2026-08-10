//! Pure pixel math for the pane banner's floating glass CARD (T131), the
//! Windows port of the Mac `GlassCard` / `GlassCardBackground`
//! (`macos/Sources/Helpers/GlassCard.swift`): a rounded, shadowed card that
//! floats inside the reserved banner band instead of a flat edge-to-edge
//! strip.
//!
//! Two things make this a pure module rather than GDI calls:
//!
//! 1. GDI has no antialiased rounded rectangle, no soft shadow, and no
//!    elliptical gradient. All three are computed here per pixel — an
//!    analytic rounded-rect SDF for the card (coverage = the pixel's overlap
//!    with the shape), a smoothstep of the same SDF for the shadow, which
//!    approximates a gaussian blur of the shape without an actual blur pass,
//!    and an `Ellipse` for each specular gradient (T124), which is what makes
//!    the highlight read as a lit object rather than a stripe laid across the
//!    card's top edge.
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

/// Specular rim (hairline border) alpha stops, along the same overhead
/// ellipse the sheen uses: brightest toward the top-center, softening around
/// the upper corners, nearly gone along the bottom. Mac: `EllipticalGradient`
/// 0.28 @ 0 → 0.10 @ 0.7 → 0.04 @ 1.
///
/// `RIM_TOP`/`RIM_BOT` are public because the tab strip's rim is the SAME rim
/// (T206 — "tabs should have similar borders to the banner. It should feel
/// cohesive"). Importing these beats copying them: a copy stops matching the
/// first time either side is tuned, and nobody notices until the user does.
/// Note the tab reads them as the endpoints of a straight vertical ramp
/// (`tab_shape.rimAlpha`) — these are the GRADIENT's stops, and the ellipse's
/// bright center sits above the card, so no pixel of a card is ever lit at
/// the full `RIM_TOP`. See T679.
pub const RIM_TOP: f32 = 0.28;
pub const RIM_MID: f32 = 0.10;
pub const RIM_BOT: f32 = 0.04;
const RIM_MID_AT: f32 = 0.7;

/// Specular sheen: white bulging down into the top of the card and falling
/// away, plus a faint darkening along the bottom edge to ground it. Mac: an
/// elliptical gradient centered above the card + a linear one below.
const SHEEN_TOP: f32 = 0.10;
const SHEEN_MID: f32 = 0.03;
const SHEEN_MID_AT: f32 = 0.6;
const SHEEN_BOTTOM_DARK: f32 = 0.05;
/// Where the bottom darkening starts, as a fraction of the card's height.
/// Mac: a `LinearGradient` stop, so the ramp from there is LINEAR — an eased
/// one would ground the card a shade later than the Mac card does.
const BOTTOM_DARK_AT: f32 = 0.75;

/// The specular ellipse's center, in fractions of the card's own size: half a
/// card-height ABOVE the top edge, horizontally centered. Mac:
/// `UnitPoint(x: 0.5, y: -0.5)` on both the sheen and the rim gradient.
///
/// This is the whole reason the highlight reads as a lit object rather than a
/// band: a vertical-only ramp lights the card's far ends exactly as brightly
/// as its middle, which on a banner spanning a wide pane is a flat stripe.
const SPECULAR_CX: f32 = 0.5;
const SPECULAR_CY: f32 = -0.5;

/// End radius of each gradient, as a fraction of the card's size. Mac:
/// `endRadiusFraction` 1.15 (sheen) and 1.3 (rim).
const SHEEN_RADIUS: f32 = 1.15;
const RIM_RADIUS: f32 = 1.3;

/// The card's fill color: the wash already composited over `bg`, so callers
/// that need a solid color (text antialiasing backdrop, harness oracles)
/// have the exact same value the card paints.
///
/// This is an ALPHA COMPOSITE of white (or black), not `color_math.lighten`
/// — that one is an HSB-brightness lift, which keeps saturation and so
/// lands on a different color than Mac's `Color.white.opacity(0.06)` over
/// the same backdrop.
pub fn fillColor(bg: Rgb) Rgb {
    // `color_math.wash` IS this composite (T304 hoisted it out of here, out of
    // `tab_shape.lift`, and out of the tab bar's `bg + 20`). The two alphas
    // stay here because they are the card's own design constants; only the
    // arithmetic is shared.
    return color_math.wash(bg, if (color_math.isLight(bg)) FILL_DARKEN else FILL_LIGHTEN);
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

/// One of the two overhead specular gradients, in its own parameter space:
/// `t` is 0 at the ellipse's center and 1 on its boundary.
///
/// The radii are fractions of the CARD's width and height separately, which
/// is how SwiftUI's `EllipticalGradient` normalizes — and it is the property
/// that matters here: the falloff across the card is the same whether the
/// banner is 200px wide or 2000, so a wide pane's banner does not end up with
/// a uniformly lit top edge.
pub const Ellipse = struct {
    cx: f32,
    cy: f32,
    /// Reciprocal radii, so evaluating is multiplies rather than divides.
    inv_rx: f32,
    inv_ry: f32,

    pub fn init(c: Rect, radius: f32) Ellipse {
        const w = @max(c.width(), 1.0);
        const h = @max(c.height(), 1.0);
        return .{
            .cx = c.left + w * SPECULAR_CX,
            .cy = c.top + h * SPECULAR_CY,
            .inv_rx = 1.0 / (w * radius),
            .inv_ry = 1.0 / (h * radius),
        };
    }

    /// The row-constant half of `t`: the squared vertical term. Hoisted out
    /// of the inner loop — every pixel of a row shares it.
    pub fn rowTerm(self: Ellipse, y: f32) f32 {
        const dy = (y - self.cy) * self.inv_ry;
        return dy * dy;
    }

    /// `t` at `x` given a row term from `rowTerm`.
    pub fn atRow(self: Ellipse, x: f32, row_term: f32) f32 {
        const dx = (x - self.cx) * self.inv_rx;
        return @sqrt(dx * dx + row_term);
    }

    pub fn at(self: Ellipse, x: f32, y: f32) f32 {
        return self.atRow(x, self.rowTerm(y));
    }
};

/// One stop of a gradient: alpha `a` at parameter `t`.
const Stop = struct { t: f32, a: f32 };

/// Piecewise-linear gradient lookup, clamped at both ends the way SwiftUI's
/// gradients are — past the last stop the last color continues, which is why
/// the sheen's final stop is explicitly clear and the rim's is not.
fn gradient(stops: []const Stop, t: f32) f32 {
    if (t <= stops[0].t) return stops[0].a;
    for (stops[1..], 1..) |s1, i| {
        if (t > s1.t) continue;
        const s0 = stops[i - 1];
        const span = s1.t - s0.t;
        if (span <= 0.0) return s1.a;
        return mix(s0.a, s1.a, (t - s0.t) / span);
    }
    return stops[stops.len - 1].a;
}

const SHEEN_STOPS = [_]Stop{
    .{ .t = 0.0, .a = SHEEN_TOP },
    .{ .t = SHEEN_MID_AT, .a = SHEEN_MID },
    .{ .t = 1.0, .a = 0.0 },
};

const RIM_STOPS = [_]Stop{
    .{ .t = 0.0, .a = RIM_TOP },
    .{ .t = RIM_MID_AT, .a = RIM_MID },
    .{ .t = 1.0, .a = RIM_BOT },
};

/// White alpha of the specular sheen at (`x`, `y`) on card `c`.
pub fn sheenAlpha(x: f32, y: f32, c: Rect) f32 {
    return gradient(&SHEEN_STOPS, Ellipse.init(c, SHEEN_RADIUS).at(x, y));
}

/// White alpha of the hairline rim at (`x`, `y`) on card `c`.
pub fn rimAlpha(x: f32, y: f32, c: Rect) f32 {
    return gradient(&RIM_STOPS, Ellipse.init(c, RIM_RADIUS).at(x, y));
}

/// Black alpha of the linear darkening that grounds the card's bottom edge.
/// Row-constant: it depends only on height within the card.
pub fn bottomShadeAlpha(y: f32, c: Rect) f32 {
    const h = c.height();
    if (h <= 0.0) return 0.0;
    const t = std.math.clamp((y - c.top) / h, 0.0, 1.0);
    if (t <= BOTTOM_DARK_AT) return 0.0;
    return SHEEN_BOTTOM_DARK * (t - BOTTOM_DARK_AT) / (1.0 - BOTTOM_DARK_AT);
}

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

    // The two overhead specular gradients. Built once — only their row and
    // column terms vary per pixel.
    const sheen_e = Ellipse.init(card, SHEEN_RADIUS);
    const rim_e = Ellipse.init(card, RIM_RADIUS);

    for (0..h) |row| {
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        const y_inside = y >= card.top + inner and y <= card.bottom - inner;
        const sheen_row = sheen_e.rowTerm(y);
        const rim_row = rim_e.rowTerm(y);
        const sheen_dark = bottomShadeAlpha(y, card);
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
                const sheen_a = gradient(&SHEEN_STOPS, sheen_e.atRow(x, sheen_row));
                if (sheen_a > 0.0) c = c.over(WHITE, sheen_a * cov_card);
                if (sheen_dark > 0.0) c = c.over(BLACK, sheen_dark * cov_card);
                if (cov_rim > 0.0) {
                    const rim_a = gradient(&RIM_STOPS, rim_e.atRow(x, rim_row));
                    c = c.over(WHITE, rim_a * cov_rim);
                }
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

test "Ellipse: the specular center sits half a card-height above the top" {
    const c = Rect{ .left = 12, .top = 12, .right = 188, .bottom = 68 };
    const e = Ellipse.init(c, SHEEN_RADIUS);
    try testing.expectApproxEqAbs(@as(f32, 100), e.cx, 0.001);
    // 12 - 56/2: above the card, which is what curves the highlight down
    // into the top edge instead of laying a band across it.
    try testing.expectApproxEqAbs(@as(f32, -16), e.cy, 0.001);
    try testing.expect(e.cy < c.top);
    // t == 1 exactly on the ellipse's own boundary, straight down from the
    // center: cy + h * radius.
    try testing.expectApproxEqAbs(@as(f32, 1), e.at(100, -16 + 56 * SHEEN_RADIUS), 0.001);
    // ...and 0 at the center itself.
    try testing.expectApproxEqAbs(@as(f32, 0), e.at(100, -16), 0.001);
}

test "Ellipse: falloff is aspect-independent, so a wide banner is not a stripe" {
    // The same point in card-relative terms lands at the same t whether the
    // card is 200px wide or 2000. Per-axis normalization is what buys this;
    // a screen-space circle would light a wide banner's whole top edge.
    const narrow = Rect{ .left = 0, .top = 0, .right = 200, .bottom = 60 };
    const wide = Rect{ .left = 0, .top = 0, .right = 2000, .bottom = 60 };
    const tn = Ellipse.init(narrow, SHEEN_RADIUS).at(200 * 0.9, 30);
    const tw = Ellipse.init(wide, SHEEN_RADIUS).at(2000 * 0.9, 30);
    try testing.expectApproxEqAbs(tn, tw, 0.001);
}

test "gradient: linear between stops, clamped past both ends" {
    const stops = [_]Stop{
        .{ .t = 0.0, .a = 1.0 },
        .{ .t = 0.5, .a = 0.2 },
        .{ .t = 1.0, .a = 0.0 },
    };
    try testing.expectApproxEqAbs(@as(f32, 1.0), gradient(&stops, -1.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), gradient(&stops, 0.25), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), gradient(&stops, 0.5), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.1), gradient(&stops, 0.75), 0.001);
    // Past the last stop the last value continues — SwiftUI's clamp, and the
    // reason the sheen's final stop must be an explicit zero.
    try testing.expectApproxEqAbs(@as(f32, 0.0), gradient(&stops, 4.0), 0.001);
}

test "sheenAlpha: bulges into the top-center and falls away toward the ends" {
    const c = Rect{ .left = 0, .top = 0, .right = 400, .bottom = 80 };
    const top_center = sheenAlpha(200, 1, c);
    const top_end = sheenAlpha(4, 1, c);
    const middle = sheenAlpha(200, 40, c);
    // Brightest at the top-center...
    try testing.expect(top_center > top_end);
    try testing.expect(top_center > middle);
    // ...and gone well before the bottom edge (the ellipse's t passes 1).
    try testing.expectApproxEqAbs(@as(f32, 0), sheenAlpha(200, 79, c), 0.0001);
    // Never brighter than the gradient's own first stop, which sits above
    // the card and so is never reached.
    try testing.expect(top_center < SHEEN_TOP);
}

test "rimAlpha: lit from the same overhead ellipse as the sheen" {
    const c = Rect{ .left = 0, .top = 0, .right = 400, .bottom = 80 };
    const top_center = rimAlpha(200, 0.5, c);
    const top_corner = rimAlpha(0.5, 0.5, c);
    const bottom = rimAlpha(200, 79.5, c);
    try testing.expect(top_center > top_corner);
    try testing.expect(top_corner > bottom);
    // The bottom has run past the ellipse, so it holds the last stop.
    try testing.expectApproxEqAbs(RIM_BOT, bottom, 0.001);
    // No pixel of the card reaches RIM_TOP: that stop is at the ellipse's
    // center, which is above the card. This is the difference the tab strip's
    // straight ramp does NOT model (T679).
    try testing.expect(top_center < RIM_TOP);
    try testing.expect(top_center > RIM_MID);
}

test "bottomShadeAlpha: nothing until 75%, then a straight ramp" {
    const c = Rect{ .left = 0, .top = 0, .right = 400, .bottom = 80 };
    try testing.expectApproxEqAbs(@as(f32, 0), bottomShadeAlpha(0, c), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), bottomShadeAlpha(60, c), 0.0001);
    // Halfway through the ramp is half the darkening — linear, not eased.
    try testing.expectApproxEqAbs(SHEEN_BOTTOM_DARK * 0.5, bottomShadeAlpha(70, c), 0.001);
    try testing.expectApproxEqAbs(SHEEN_BOTTOM_DARK, bottomShadeAlpha(80, c), 0.001);
}

test "specular gradients are scale-invariant at 1.0/1.25/1.5/2.0" {
    // The design system asks every piece of win32 chrome to be asserted at
    // these four scales. The gradients are normalized to the card's own rect
    // rather than to DIPs, so the CLAIM here is that a given relative point
    // on the card takes the same alpha at every DPI — a highlight that
    // drifted with scale would read as a different material at 150%.
    const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };
    var want_sheen: f32 = 0;
    var want_rim: f32 = 0;
    for (scales, 0..) |s, i| {
        const m = Metrics.init(
            @intFromFloat(@round(400 * s)),
            @intFromFloat(@round(90 * s)),
            s,
        );
        const c = m.card();
        const x = c.left + c.width() * 0.5;
        const y = c.top + c.height() * 0.02;
        const sheen = sheenAlpha(x, y, c);
        const rim = rimAlpha(x, y, c);
        if (i == 0) {
            want_sheen = sheen;
            want_rim = rim;
            continue;
        }
        try testing.expectApproxEqAbs(want_sheen, sheen, 0.002);
        try testing.expectApproxEqAbs(want_rim, rim, 0.002);
    }
}

test "render: a wide card's top edge is a highlight, not a stripe" {
    // The regression this whole gradient exists to prevent: with a
    // vertical-only ramp, the far ends of a wide banner's top edge are lit
    // exactly as brightly as its middle.
    const m = Metrics.init(800, 90, 1.0);
    var px: [800 * 90]u32 = undefined;
    render(&px, m, DARK);
    const center = lum(at(&px, m, 400, 20));
    const near_end = lum(at(&px, m, 30, 20));
    try testing.expect(center > near_end);
    // ...and the same row well below the card's top is dimmer than both.
    try testing.expect(near_end > lum(at(&px, m, 400, 60)));
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
