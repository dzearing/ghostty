//! Pure per-pixel math for the tab strip's tab SHAPE and surface (T206).
//! No OS imports, so these unit tests run in every app-runtime lane.
//!
//! `tab_strip_layout.zig` decides WHERE the tabs go; this decides what one
//! looks like. The split exists because the two change for different reasons
//! — geometry moves when the window resizes, appearance moves when the theme
//! or the design does.
//!
//! Why per-pixel instead of GDI. The user's report, 2026-07-30:
//!
//! > "don't you see how the edge of the banner has this gradient highlight
//! >  border? tabs should too, and inactive tabs should be visible somewhat
//! >  and tabs should have gaps in between. And the bottom corners of the
//! >  selected tab should curve into the edge. Why are you making the ux
//! >  unpolished on windows? Make this as good as mac."
//!
//! Every one of those needs something GDI does not have:
//!
//!   * A **gradient rim** — `FrameRgn`/`CreatePen` stroke ONE flat color.
//!     The banner card's rim fades 0.28 → 0.04 down its height, and matching
//!     it means computing the alpha per scanline.
//!   * **Flared bottom corners** that curve OUT into the strip baseline (the
//!     Chrome/Safari/macOS tab silhouette). That is not a rounded rect at
//!     all, so `CreateRoundRectRgn` cannot express it.
//!   * **Antialiasing.** GDI regions and paths are hard-edged. An aliased
//!     curve sitting next to the banner's antialiased card is exactly the
//!     "unpolished" the report names — the flaw is visible precisely BECAUSE
//!     the banner next to it is smooth.
//!
//! So the strip's back buffer is a DIB section and the tabs are composited
//! into it here, the same way `banner_card.zig` composites the banner. The
//! rim constants are IMPORTED from that module rather than copied: the ask
//! was for the tabs to match the banner, and a copied 0.28 is a number that
//! silently stops matching the first time either side is tuned.

const std = @import("std");
const testing = std.testing;
const card = @import("banner_card.zig");
const color_math = @import("color_math.zig");

/// Re-exported so `Window.zig` can name the color type without importing
/// `color_math` just for one struct literal.
pub const Rgb = color_math.Rgb;

/// Negative control for `test/win32/tab-strip.ps1`. Flip to `true`, rebuild
/// `-Dapp-runtime=win32`, and re-run: tabs lose the rim, the flare and the
/// inactive surface, restoring the flat pre-T206 look — so the rim,
/// bottom-flare and inactive-visibility assertions must fail, and the
/// geometry ones (T202's) must NOT.
pub const T206_NEUTERED = false;

/// Top-corner radius, unscaled px. The tab's own rounding, kept smaller than
/// the banner card's 14 because a tab is a third of the card's height and the
/// same radius on a short shape reads as a lozenge.
pub const CORNER_TOP: f32 = 7.0;

/// Bottom-corner FLARE radius, unscaled px — the outward curve that carries
/// the tab's side into the strip baseline instead of stopping dead at it.
/// This is the "curve into the edge" half of the report, and it is what makes
/// a selected tab read as continuous with the pane below rather than as a
/// rectangle parked on top of it.
pub const CORNER_BOTTOM: f32 = 7.0;

/// Hairline rim width, unscaled px. One device pixel at 100%, and it must
/// stay a hairline as DPI rises — a rim that scales becomes a border.
pub const RIM_W: f32 = 1.0;

/// Surface lift for a tab that is NOT selected, as an alpha of white over the
/// strip background. The report's "inactive tabs should be visible somewhat":
/// they used to be fully transparent, so an unselected tab was literally not
/// drawn and the strip read as one bar with text on it.
///
/// Deliberately the banner card's own `FILL_LIGHTEN` — an inactive tab and
/// the banner card are both "a surface floating on the background", so they
/// should be the same surface.
pub const INACTIVE_LIFT: f32 = card.FILL_LIGHTEN;

/// A hovered inactive tab lifts further, so hover is a change of surface
/// rather than a change of color.
pub const HOVER_LIFT: f32 = card.FILL_LIGHTEN * 2.0;

/// What a tab is doing, which decides its fill.
pub const Surface = enum {
    /// Selected. Filled with the CONTENT background so it merges into the
    /// pane below — the WinUI TabView selection cue.
    active,
    inactive,
    /// Unselected, pointer over it.
    hovered,
};

/// One tab to composite, in physical pixels relative to the strip buffer.
pub const Tab = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    surface: Surface,
};

/// The scaled constants for one DPI.
pub const Metrics = struct {
    corner_top: f32,
    corner_bottom: f32,
    rim_w: f32,

    pub fn init(scale: f32) Metrics {
        return .{
            .corner_top = CORNER_TOP * scale,
            .corner_bottom = CORNER_BOTTOM * scale,
            // A hairline stays a hairline: never thinner than a device pixel,
            // and never allowed to grow into a border at high DPI.
            .rim_w = @max(RIM_W, @min(RIM_W * scale, 2.0)),
        };
    }
};

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Antialiased coverage from a signed distance: 1 well inside, 0 well
/// outside, a linear ramp across the boundary pixel. Same formulation as
/// `banner_card.zig` so the two shapes' edges resolve identically.
fn coverage(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0.0, 1.0);
}

/// Signed distance to an axis-aligned box: negative inside.
fn sdBox(x: f32, y: f32, left: f32, top: f32, right: f32, bottom: f32) f32 {
    const dx = @max(left - x, x - right);
    const dy = @max(top - y, y - bottom);
    // Exact outside distance, and the usual max() approximation inside.
    const ax = @max(dx, 0.0);
    const ay = @max(dy, 0.0);
    return @sqrt(ax * ax + ay * ay) + @min(@max(dx, dy), 0.0);
}

/// Signed distance to ONE bottom flare — the little concave foot that carries
/// the tab's side out to the baseline.
///
/// It is the corner square beside the tab MINUS a disc tucked into that
/// square: the leftover sliver between the straight side and the disc is the
/// outward curve. Subtracting a disc (rather than adding a rounded corner) is
/// what makes the curve concave, which is the whole difference between a
/// Chrome-style tab and a rounded rectangle.
fn sdFlare(x: f32, y: f32, cx: f32, cy: f32, r: f32, box_l: f32, box_r: f32, box_t: f32, box_b: f32) f32 {
    const in_box = sdBox(x, y, box_l, box_t, box_r, box_b);
    const dx = x - cx;
    const dy = y - cy;
    // Negative when OUTSIDE the disc, which is the half we keep.
    const outside_disc = r - @sqrt(dx * dx + dy * dy);
    return @max(in_box, outside_disc);
}

/// Signed distance to the whole tab silhouette: a top-rounded body plus a
/// flare at each bottom corner.
pub fn sdTab(x: f32, y: f32, t: Tab, m: Metrics) f32 {
    const l: f32 = @floatFromInt(t.left);
    const tp: f32 = @floatFromInt(t.top);
    const r: f32 = @floatFromInt(t.right);
    const b: f32 = @floatFromInt(t.bottom);

    // Body: round the TOP corners only. Extending the rounded rect below the
    // baseline puts its bottom corners' rounding out of view, then the
    // half-plane clip cuts it off square at the baseline — which is where the
    // flares take over.
    const rt = m.corner_top;
    const body_round = card.sdRoundRect(x, y, .{
        .left = l,
        .top = tp,
        .right = r,
        .bottom = b + rt,
    }, rt);
    const body = @max(body_round, y - b);

    // Flares, outboard of each bottom corner — on the SELECTED tab only.
    //
    // The report asks for them by name on that tab ("the bottom corners of
    // the selected tab should curve into the edge"), and restricting them
    // there is also what lets the tabs have real GAPS between them: a flare
    // reaches `corner_bottom` past its own side, so flaring every tab would
    // have neighbouring feet meeting in the middle of every gap and closing
    // it back up. The selected tab flares into the empty space beside it; the
    // others stay clear of each other.
    if (t.surface != .active) return body;

    const rb = m.corner_bottom;
    const left_flare = sdFlare(x, y, l - rb, b - rb, rb, l - rb, l, b - rb, b);
    const right_flare = sdFlare(x, y, r + rb, b - rb, rb, r, r + rb, b - rb, b);

    return @min(body, @min(left_flare, right_flare));
}

/// The rim's alpha at height `y` within a tab: brightest along the top edge,
/// nearly gone at the baseline. Mac's card rim is an elliptical gradient
/// 0.28 → 0.04; a tab is short enough that a linear ramp between the same two
/// endpoints is indistinguishable, and it is one multiply.
pub fn rimAlpha(y: f32, t: Tab, active: bool) f32 {
    const tp: f32 = @floatFromInt(t.top);
    const b: f32 = @floatFromInt(t.bottom);
    const h = @max(b - tp, 1.0);
    const k = std.math.clamp((y - tp) / h, 0.0, 1.0);
    const a = mix(card.RIM_TOP, card.RIM_BOT, k);
    // An unselected tab's rim is softer — at full strength every tab would
    // shout as loudly as the selected one and the selection cue would be lost.
    return if (active) a else a * 0.6;
}

/// The fill a surface takes, already composited over the strip background.
/// Exposed so the acceptance script and the GDI text path can ask for the
/// exact color a tab is painted rather than re-deriving it.
pub fn fillColor(surface: Surface, strip_bg: Rgb, content_bg: Rgb) Rgb {
    if (T206_NEUTERED) {
        return switch (surface) {
            .active => content_bg,
            // The pre-T206 world: an unselected tab painted nothing at all.
            .inactive, .hovered => strip_bg,
        };
    }
    return switch (surface) {
        .active => content_bg,
        .inactive => lift(strip_bg, INACTIVE_LIFT),
        .hovered => lift(strip_bg, HOVER_LIFT),
    };
}

/// Composite white (dark background) or black (light background) at `a` over
/// `bg`. The same alpha composite `banner_card.fillColor` uses — NOT an HSB
/// brightness lift, which keeps saturation and lands on a different color.
fn lift(bg: Rgb, a: f32) Rgb {
    const toward: f32 = if (color_math.isLight(bg)) 0.0 else 255.0;
    return .{
        .r = ch(bg.r, toward, a),
        .g = ch(bg.g, toward, a),
        .b = ch(bg.b, toward, a),
    };
}

fn ch(c: u8, toward: f32, a: f32) u8 {
    const v: f32 = @floatFromInt(c);
    return @intFromFloat(std.math.clamp(@round(v + (toward - v) * a), 0.0, 255.0));
}

/// Composite one tab into a top-down `w * h` buffer of `0x00RRGGBB`.
///
/// Only the pixels the tab can reach are touched — its rect grown by the
/// flare radius — so painting N tabs costs their own area, not N full strip
/// passes.
pub fn renderTab(
    pixels: []u32,
    w: i32,
    h: i32,
    t: Tab,
    m: Metrics,
    strip_bg: Rgb,
    content_bg: Rgb,
) void {
    if (w <= 0 or h <= 0) return;
    if (pixels.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return;
    if (t.right <= t.left or t.bottom <= t.top) return;

    const fill = fillColor(t.surface, strip_bg, content_bg);
    const fr: f32 = @floatFromInt(fill.r);
    const fg: f32 = @floatFromInt(fill.g);
    const fb: f32 = @floatFromInt(fill.b);
    const active = (t.surface == .active);

    // White rim on a dark background, black on a light one — a specular
    // highlight is the light source reflecting off the surface's edge, so it
    // has to go the other way when the surface is already bright.
    const rim_toward: f32 = if (color_math.isLight(strip_bg)) 0.0 else 255.0;

    const pad: i32 = @intFromFloat(@ceil(m.corner_bottom) + 2.0);
    const x0 = @max(t.left - pad, 0);
    const x1 = @min(t.right + pad, w);
    const y0 = @max(t.top - pad, 0);
    const y1 = @min(t.bottom + pad, h);

    var y = y0;
    while (y < y1) : (y += 1) {
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        const rim_a = if (T206_NEUTERED) 0.0 else rimAlpha(fy, t, active);
        const row = @as(usize, @intCast(y)) * @as(usize, @intCast(w));
        var x = x0;
        while (x < x1) : (x += 1) {
            const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            const sd = sdTab(fx, fy, t, m);
            const cov = coverage(sd);
            if (cov <= 0.0) continue;

            // The rim is the ring just INSIDE the silhouette: the shape minus
            // the shape shrunk by one hairline. Doing it as a difference of
            // coverages keeps it antialiased on both of its own edges, which
            // a stroked outline never is.
            const rim = if (T206_NEUTERED) 0.0 else (cov - coverage(sd + m.rim_w)) * rim_a;

            const i = row + @as(usize, @intCast(x));
            const dst = pixels[i];
            var r: f32 = @floatFromInt((dst >> 16) & 0xFF);
            var g: f32 = @floatFromInt((dst >> 8) & 0xFF);
            var b: f32 = @floatFromInt(dst & 0xFF);

            r = mix(r, fr, cov);
            g = mix(g, fg, cov);
            b = mix(b, fb, cov);

            if (rim > 0.0) {
                r = mix(r, rim_toward, rim);
                g = mix(g, rim_toward, rim);
                b = mix(b, rim_toward, rim);
            }

            pixels[i] = (@as(u32, @intFromFloat(std.math.clamp(@round(r), 0.0, 255.0))) << 16) |
                (@as(u32, @intFromFloat(std.math.clamp(@round(g), 0.0, 255.0))) << 8) |
                @as(u32, @intFromFloat(std.math.clamp(@round(b), 0.0, 255.0)));
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const DARK = Rgb{ .r = 30, .g = 32, .b = 40 };
const STRIP = Rgb{ .r = 50, .g = 52, .b = 60 };

fn testTab(surface: Surface) Tab {
    return .{ .left = 20, .top = 3, .right = 120, .bottom = 32, .surface = surface };
}

fn px(pixels: []const u32, w: i32, x: i32, y: i32) u32 {
    return pixels[@as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x))];
}

fn lumOf(p: u32) u32 {
    return ((p >> 16) & 0xFF) + ((p >> 8) & 0xFF) + (p & 0xFF);
}

test "an inactive tab is VISIBLE against the strip" {
    // The report: "inactive tabs should be visible somewhat". Pre-T206 an
    // unselected tab painted nothing, so this difference was exactly zero.
    const c = fillColor(.inactive, STRIP, DARK);
    try testing.expect(!std.meta.eql(c, STRIP));
    try testing.expect(lumOf(@as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b) >
        lumOf(@as(u32, STRIP.r) << 16 | @as(u32, STRIP.g) << 8 | STRIP.b));
}

test "hover lifts further than inactive, and active is the content background" {
    const inact = fillColor(.inactive, STRIP, DARK);
    const hov = fillColor(.hovered, STRIP, DARK);
    try testing.expect(hov.r > inact.r);
    try testing.expectEqual(DARK, fillColor(.active, STRIP, DARK));
}

test "the inactive lift is the banner card's own, not a second opinion" {
    // "tabs should have similar borders to the banner. It should feel
    // cohesive" — cohesion by construction, not by two numbers that happen to
    // match today.
    try testing.expectEqual(card.FILL_LIGHTEN, INACTIVE_LIFT);
    try testing.expectEqual(card.fillColor(STRIP), fillColor(.inactive, STRIP, DARK));
}

test "the rim fades from top to bottom, like the card's" {
    const t = testTab(.active);
    const top = rimAlpha(@floatFromInt(t.top), t, true);
    const mid = rimAlpha(@as(f32, @floatFromInt(t.top + t.bottom)) / 2.0, t, true);
    const bot = rimAlpha(@floatFromInt(t.bottom), t, true);
    try testing.expect(top > mid);
    try testing.expect(mid > bot);
    try testing.expectApproxEqAbs(card.RIM_TOP, top, 0.001);
    try testing.expectApproxEqAbs(card.RIM_BOT, bot, 0.001);
}

test "an unselected tab's rim is softer than the selected one's" {
    const t = testTab(.inactive);
    try testing.expect(rimAlpha(10.0, t, false) < rimAlpha(10.0, t, true));
}

test "the silhouette contains its interior and excludes the strip above it" {
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    // Well inside.
    try testing.expect(sdTab(70.0, 20.0, t, m) < 0);
    // Above the tab.
    try testing.expect(sdTab(70.0, 1.0, t, m) > 0);
    // Far to the left, clear of the flare.
    try testing.expect(sdTab(5.0, 20.0, t, m) > 0);
}

test "the bottom corners FLARE outward instead of stopping at the side" {
    // The report's "the bottom corners of the selected tab should curve into
    // the edge", as an assertion: just outside the tab's left edge and just
    // above the baseline is OUTSIDE the shape, but the same x at the baseline
    // is INSIDE it — that widening is the flare.
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    const x_outside: f32 = @as(f32, @floatFromInt(t.left)) - 3.0;
    const y_baseline: f32 = @as(f32, @floatFromInt(t.bottom)) - 0.5;
    const y_middle: f32 = @as(f32, @floatFromInt(t.top + t.bottom)) / 2.0;

    try testing.expect(sdTab(x_outside, y_middle, t, m) > 0); // not yet
    try testing.expect(sdTab(x_outside, y_baseline, t, m) < 0); // flared out
    // Symmetric on the right.
    const x_right: f32 = @as(f32, @floatFromInt(t.right)) + 3.0;
    try testing.expect(sdTab(x_right, y_middle, t, m) > 0);
    try testing.expect(sdTab(x_right, y_baseline, t, m) < 0);
}

test "the flare is CONCAVE - it hugs the baseline, not a rounded corner" {
    // A rounded bottom corner would make the tab NARROWER as y approaches the
    // baseline. The flare makes it WIDER, monotonically. That is the whole
    // visual difference, so pin the direction.
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    var last_width: f32 = -1;
    var y: f32 = @as(f32, @floatFromInt(t.bottom)) - m.corner_bottom + 0.5;
    while (y < @as(f32, @floatFromInt(t.bottom))) : (y += 1.0) {
        // Walk left from the tab edge until we leave the shape.
        var x: f32 = @floatFromInt(t.left);
        var width: f32 = 0;
        while (x > @as(f32, @floatFromInt(t.left)) - m.corner_bottom - 2.0) : (x -= 0.25) {
            if (sdTab(x, y, t, m) > 0) break;
            width += 0.25;
        }
        try testing.expect(width >= last_width);
        last_width = width;
    }
    try testing.expect(last_width > 0);
}

test "the top corners are rounded" {
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    // The very corner pixel is outside a rounded shape and inside a square one.
    try testing.expect(sdTab(
        @as(f32, @floatFromInt(t.left)) + 0.5,
        @as(f32, @floatFromInt(t.top)) + 0.5,
        t,
        m,
    ) > 0);
    // ...while a pixel one radius in is inside.
    try testing.expect(sdTab(
        @as(f32, @floatFromInt(t.left)) + m.corner_top,
        @as(f32, @floatFromInt(t.top)) + m.corner_top,
        t,
        m,
    ) < 0);
}

test "renderTab paints a rim brighter than both the fill and the strip" {
    const w: i32 = 200;
    const h: i32 = 32;
    var pixels = [_]u32{0} ** (200 * 32);
    const strip_packed: u32 = (@as(u32, STRIP.r) << 16) | (@as(u32, STRIP.g) << 8) | STRIP.b;
    for (&pixels) |*p| p.* = strip_packed;

    const t = testTab(.active);
    renderTab(&pixels, w, h, t, Metrics.init(1.0), STRIP, DARK);

    // Interior is the content background.
    const inside = px(&pixels, w, 70, 20);
    try testing.expectEqual(@as(u32, (@as(u32, DARK.r) << 16) | (@as(u32, DARK.g) << 8) | DARK.b), inside);

    // Somewhere along the top edge there is a pixel brighter than BOTH the
    // strip and the fill — that is the specular rim, and its absence is what
    // "you haven't added the border outline to the tabs" meant.
    var brightest: u32 = 0;
    var x: i32 = t.left;
    while (x < t.right) : (x += 1) {
        var y: i32 = t.top;
        while (y < t.top + 3) : (y += 1) {
            brightest = @max(brightest, lumOf(px(&pixels, w, x, y)));
        }
    }
    try testing.expect(brightest > lumOf(strip_packed));
    try testing.expect(brightest > lumOf(inside));
}

test "renderTab antialiases its curves instead of hard-stepping" {
    const w: i32 = 200;
    const h: i32 = 32;
    var pixels = [_]u32{0} ** (200 * 32);
    const strip_packed: u32 = (@as(u32, STRIP.r) << 16) | (@as(u32, STRIP.g) << 8) | STRIP.b;
    for (&pixels) |*p| p.* = strip_packed;

    const t = testTab(.active);
    renderTab(&pixels, w, h, t, Metrics.init(1.0), STRIP, DARK);

    // Across the top-left corner arc there must be at least one pixel that is
    // neither the strip nor the fill nor the rim's extreme — a partial
    // coverage value. A GDI region produces none.
    const fill_l = lumOf((@as(u32, DARK.r) << 16) | (@as(u32, DARK.g) << 8) | DARK.b);
    const strip_l = lumOf(strip_packed);
    var partials: usize = 0;
    var x: i32 = t.left;
    while (x < t.left + 8) : (x += 1) {
        var y: i32 = t.top;
        while (y < t.top + 8) : (y += 1) {
            const l = lumOf(px(&pixels, w, x, y));
            if (l != strip_l and l != fill_l) partials += 1;
        }
    }
    try testing.expect(partials > 0);
}

test "renderTab stays inside the buffer for tabs at its edges" {
    const w: i32 = 60;
    const h: i32 = 32;
    var pixels = [_]u32{0} ** (60 * 32);
    const m = Metrics.init(1.0);
    // Flush left, flush right, and taller than the buffer: none may trap.
    renderTab(&pixels, w, h, .{ .left = 0, .top = 3, .right = 30, .bottom = 32, .surface = .active }, m, STRIP, DARK);
    renderTab(&pixels, w, h, .{ .left = 30, .top = 3, .right = 60, .bottom = 40, .surface = .inactive }, m, STRIP, DARK);
    renderTab(&pixels, w, h, .{ .left = -10, .top = -5, .right = 20, .bottom = 32, .surface = .hovered }, m, STRIP, DARK);
    // Degenerate rects are ignored rather than wrapping.
    renderTab(&pixels, w, h, .{ .left = 10, .top = 3, .right = 10, .bottom = 32, .surface = .active }, m, STRIP, DARK);
}

test "the rim stays a hairline as DPI rises" {
    // A rim that scaled with DPI would be a 2-3px BORDER on a 200% display,
    // which is a different design, not the same one bigger.
    try testing.expectApproxEqAbs(@as(f32, 1.0), Metrics.init(1.0).rim_w, 0.001);
    try testing.expect(Metrics.init(3.0).rim_w <= 2.0);
    try testing.expect(Metrics.init(1.0).rim_w >= 1.0);
}

test "corners scale with DPI" {
    const m = Metrics.init(2.0);
    try testing.expectApproxEqAbs(CORNER_TOP * 2.0, m.corner_top, 0.001);
    try testing.expectApproxEqAbs(CORNER_BOTTOM * 2.0, m.corner_bottom, 0.001);
}

test "the shipped build is not neutered" {
    try testing.expect(!T206_NEUTERED);
}
