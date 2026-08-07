//! Pure geometry + color math for the READ-ONLY pane badge (T445), the
//! Windows port of Mac's `Ghostty.SurfaceView.ReadonlyBadge`
//! (`macos/Sources/Ghostty/Surface View/SurfaceView.swift`): a small card in
//! the pane's top-right corner that appears while the pane is in read-only
//! mode and disappears when it leaves.
//!
//! Why the badge exists at all: read-only silently drops every keystroke, so
//! without a mark a read-only pane and a wedged pane look identical. The
//! `.readonly` apprt action was an acknowledged no-op on win32 until this
//! landed, which meant the ONLY way to find out was to open a menu and look
//! for a checkmark.
//!
//! Per-pane, not per-tab (decision D30): a tab holds a whole split tree, so a
//! tab-title glyph cannot answer "which pane", and read-only is a per-pane
//! mode.
//!
//! No OS imports, so every number below is asserted at 1.0 / 1.25 / 1.5 / 2.0
//! in every app-runtime lane (the `banner_card`/`dim_math` pattern). The
//! windowing and GDI half is `ReadonlyBadge.zig`.

const std = @import("std");
const color_math = @import("color_math.zig");
const card = @import("banner_card.zig");

const Rgb = color_math.Rgb;

/// Gap between the badge card and the pane's top/right edges, unscaled px.
/// On the design system's 4 DIP spacing scale and comfortably past its
/// ">= 4 DIP from the container edge" floor. Mac uses 8pt for the same inset.
pub const INSET: f32 = 8.0;

/// Card corner radius, unscaled px. Design system §3.1: 8 DIP for cards and
/// overlays. Deliberately NOT Mac's 6 — the radius scale is the Windows
/// rulebook's, and a 6 DIP card here would read as a mistake next to the
/// banner and TOC cards.
pub const RADIUS: f32 = 8.0;

/// Inner padding between the card edge and its content, unscaled px. The
/// horizontal one is larger because the card is a pill-ish chip: content
/// needs more breathing room along the long axis to not look pinched.
pub const PAD_X: f32 = 8.0;
pub const PAD_Y: f32 = 4.0;

/// Gap between the eye glyph and the "Read-only" label, unscaled px.
pub const GAP: f32 = 4.0;

/// Eye glyph em box, unscaled px. 12 is what `icon_button_paint` renders the
/// strip/banner marks at, so the badge's glyph is the same optical weight as
/// every other chrome glyph.
pub const GLYPH: f32 = 12.0;

/// Label font size, unscaled px. Mac's badge is a 12pt medium system font.
pub const FONT_PX: f32 = 12.0;

/// Border thickness, unscaled px, floored at one physical pixel. Design
/// system §3.2 elevation 1 is a 1 px border; the badge's is orange rather
/// than a luminance step because the color IS the mode signal (Mac uses a
/// 1.5pt orange stroke for the same reason).
pub const BORDER: f32 = 1.0;

/// Elevation-1 drop shade: blur and downward offset, unscaled px. Smaller
/// than the banner card's (8/4) because this card is a chip resting on
/// content, not a band floating over it.
pub const SHADOW_BLUR: f32 = 4.0;
pub const SHADOW_DY: f32 = 2.0;
pub const SHADOW_ALPHA: f32 = 0.28;

/// The badge accent — Apple systemOrange, the same source Mac's
/// `Color.orange` resolves to, and the same convention `BannerOverlay.GREEN`
/// already follows. It is a BASE: both users of it run it through a contrast
/// search against the card fill first, so the floor is met on every theme
/// rather than on the two the author happened to look at.
pub const ACCENT = Rgb{ .r = 255, .g = 149, .b = 0 };

/// WCAG floors from the design system: 4.5:1 for text, 3:1 for a meaningful
/// boundary (1.4.11).
pub const TEXT_CONTRAST: f64 = 4.5;
pub const BORDER_CONTRAST: f64 = 3.0;

/// The card's own fill: the glass wash over the pane background, exactly the
/// banner card's. Sharing it is the point — two cards on the same pane
/// resolving to two different fills is the inconsistency the design system
/// calls a defect.
pub fn fillColor(pane_bg: Rgb) Rgb {
    return card.fillColor(pane_bg);
}

/// The label color against a card of `fill`: the accent, moved only as far as
/// the 4.5:1 text floor requires.
pub fn labelColor(fill: Rgb) Rgb {
    return atLeast(ACCENT, fill, TEXT_CONTRAST);
}

/// The border color against a card of `fill`: the accent at the 3:1
/// chrome-boundary floor, so it stays recognizably orange where the text
/// color would have been pushed further.
pub fn borderColor(fill: Rgb) Rgb {
    return atLeast(ACCENT, fill, BORDER_CONTRAST);
}

/// `contrastAdjustedTo`, then VERIFIED against the color that will actually
/// be painted.
///
/// The shared search evaluates its candidates in continuous sRGB and returns
/// an 8-bit color, so a result that sat exactly on the floor mid-search can
/// land a hair under it once quantized. That is invisible on a palette entry
/// and not invisible here: this is the one control whose color is the whole
/// message. Plain black/white always clears both floors (the worst case of
/// "the better of black and white" is 4.58:1, at a mid-tone background), so
/// the fallback is a real guarantee rather than another approximation.
fn atLeast(base: Rgb, fill: Rgb, target: f64) Rgb {
    const c = color_math.contrastAdjustedTo(base, fill, target);
    if (ratio(c, fill) >= target) return c;
    return color_math.contrastForeground(fill);
}

/// WCAG contrast between two concrete colors.
pub fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

/// An integer rect, right/bottom exclusive.
pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
    pub fn isEmpty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }
    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }
    fn offset(self: Rect, dx: i32, dy: i32) Rect {
        return .{
            .left = self.left + dx,
            .top = self.top + dy,
            .right = self.right + dx,
            .bottom = self.bottom + dy,
        };
    }
};

/// Every unscaled metric above, in physical pixels at one DPI scale.
pub const Metrics = struct {
    scale: f32,
    inset: i32,
    radius: i32,
    pad_x: i32,
    pad_y: i32,
    gap: i32,
    glyph: i32,
    font_px: i32,
    border: i32,
    shadow_blur: i32,
    shadow_dy: i32,

    pub fn init(scale: f32) Metrics {
        const s = @max(scale, 0.1);
        return .{
            .scale = s,
            .inset = px(INSET, s),
            .radius = px(RADIUS, s),
            .pad_x = px(PAD_X, s),
            .pad_y = px(PAD_Y, s),
            .gap = px(GAP, s),
            .glyph = px(GLYPH, s),
            .font_px = px(FONT_PX, s),
            // A hairline that rounds to 0 is an invisible border, and an
            // invisible border on the one control whose color carries the
            // meaning is a missing feature.
            .border = @max(px(BORDER, s), 1),
            .shadow_blur = px(SHADOW_BLUR, s),
            .shadow_dy = px(SHADOW_DY, s),
        };
    }

    /// Extra room the popup window needs around the card for the drop shade
    /// to actually paint. Uniform, and taller below by the offset.
    pub fn shadowPad(self: Metrics) i32 {
        return self.shadow_blur + self.shadow_dy;
    }
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// The badge's natural card size for a label `text_w` px wide and
/// `text_h` px tall (both GDI-measured by the caller at `m.font_px`).
/// A label that measured to nothing (no icon font is not the case here — a
/// missing FONT is) takes no gap with it: the gap separates two things, and
/// there is only one.
pub fn cardSize(m: Metrics, text_w: i32, text_h: i32) struct { w: i32, h: i32 } {
    const tw = @max(text_w, 0);
    const content_w = m.glyph + (if (tw > 0) m.gap + tw else 0);
    const content_h = @max(m.glyph, @max(text_h, 0));
    return .{
        .w = content_w + m.pad_x * 2,
        .h = content_h + m.pad_y * 2,
    };
}

/// Everything the painter needs, resolved against a pane of `pane_w` x
/// `pane_h` px. All rects are in the POPUP WINDOW's client coordinates
/// except `win`, which is the window rect in the pane's client coordinates.
pub const Layout = struct {
    /// The popup window's rect inside the pane client area. Includes the
    /// shadow allowance, so the card sits `shadowPad` in from its edges.
    win: Rect,
    /// The card inside the window.
    card: Rect,
    /// The eye glyph's em box inside the window.
    glyph: Rect,
    /// The label's box inside the window (drawn vertically centered).
    text: Rect,
    /// True when the pane is too small to hold a badge at all; the caller
    /// hides rather than painting a degenerate chip.
    hidden: bool,
};

/// Place the badge in the pane's top-right corner. `text_w`/`text_h` are the
/// GDI-measured label extents.
///
/// The card's right edge lands exactly `m.inset` from the pane's right edge
/// and its top exactly `m.inset` from the pane's top — that pair is what the
/// scale sweep asserts, because a shadow allowance folded into the anchor is
/// precisely how a "8pt inset" quietly becomes 14 at 2.0.
///
/// A pane too narrow for the whole label shrinks the card down to its
/// content minimum (glyph + padding) rather than overflowing; the caller
/// tail-ellipsizes the label into `text`. A pane too small even for that
/// gets `hidden`.
pub fn layout(m: Metrics, pane_w: i32, pane_h: i32, text_w: i32, text_h: i32) Layout {
    const natural = cardSize(m, text_w, text_h);
    const hidden: Layout = .{
        .win = .{},
        .card = .{},
        .glyph = .{},
        .text = .{},
        .hidden = true,
    };

    // Widest card the pane can hold with its inset intact on both sides.
    const max_w = pane_w - m.inset * 2;
    // The card must still fit its glyph and padding, or there is nothing
    // worth drawing.
    const min_w = m.glyph + m.pad_x * 2;
    if (max_w < min_w) return hidden;
    if (pane_h < natural.h + m.inset * 2) return hidden;

    const card_w = @min(natural.w, max_w);
    const card_h = natural.h;

    // Card rect in PANE coordinates, anchored top-right.
    const card_pane: Rect = .{
        .left = pane_w - m.inset - card_w,
        .top = m.inset,
        .right = pane_w - m.inset,
        .bottom = m.inset + card_h,
    };

    // The window is the card plus the shadow allowance, clipped to the pane
    // so a popup never hangs outside the surface it decorates. Clipping the
    // WINDOW never moves the card: the pad is decoration, the anchor is not.
    const pad = m.shadowPad();
    const win: Rect = .{
        .left = @max(card_pane.left - pad, 0),
        .top = @max(card_pane.top - pad, 0),
        .right = @min(card_pane.right + pad, pane_w),
        .bottom = @min(card_pane.bottom + pad + m.shadow_dy, pane_h),
    };

    // Everything else is window-relative.
    const c = card_pane.offset(-win.left, -win.top);
    const glyph: Rect = .{
        .left = c.left + m.pad_x,
        .top = c.top + @divTrunc(c.height() - m.glyph, 2),
        .right = c.left + m.pad_x + m.glyph,
        .bottom = c.top + @divTrunc(c.height() - m.glyph, 2) + m.glyph,
    };
    const text: Rect = .{
        .left = glyph.right + m.gap,
        .top = c.top + m.pad_y,
        .right = c.right - m.pad_x,
        .bottom = c.bottom - m.pad_y,
    };

    return .{ .win = win, .card = c, .glyph = glyph, .text = text, .hidden = false };
}

/// Paint the badge's card into a per-pixel-alpha surface: `bgr` gets the
/// STRAIGHT (un-premultiplied) `0x00RRGGBB` color, `mask` the coverage alpha.
/// Both are `l.win.width() * l.win.height()` top-down.
///
/// Straight, not premultiplied, and in two buffers on purpose: the caller
/// draws the glyph and the label into the same DIB with GDI afterwards, and
/// GDI text has no notion of alpha — it writes zero into the byte. Keeping
/// the mask lets the caller re-apply the real coverage and premultiply once,
/// AFTER the text lands, instead of trying to protect an alpha channel from
/// `DrawTextW`.
///
/// Unlike the banner card, this one is composited against an UNKNOWN backdrop
/// (live terminal content), so it carries its own alpha: the card interior is
/// fully opaque — which is what guarantees the label stays readable over
/// whatever the pane happens to be drawing — and only the drop shade and the
/// antialiased edge are translucent.
pub fn render(bgr: []u32, mask: []u8, m: Metrics, l: Layout, pane_bg: Rgb) void {
    if (l.hidden) return;
    const w: usize = @intCast(@max(l.win.width(), 0));
    const h: usize = @intCast(@max(l.win.height(), 0));
    if (w == 0 or h == 0) return;
    if (bgr.len < w * h or mask.len < w * h) return;

    const fill = fillColor(pane_bg);
    const border = borderColor(fill);
    const radius: f32 = @floatFromInt(m.radius);
    const bw: f32 = @floatFromInt(m.border);
    const blur: f32 = @floatFromInt(@max(m.shadow_blur, 1));
    const dy: f32 = @floatFromInt(m.shadow_dy);

    const cr = card.Rect{
        .left = @floatFromInt(l.card.left),
        .top = @floatFromInt(l.card.top),
        .right = @floatFromInt(l.card.right),
        .bottom = @floatFromInt(l.card.bottom),
    };
    const shadow = card.Rect{
        .left = cr.left,
        .top = cr.top + dy,
        .right = cr.right,
        .bottom = cr.bottom + dy,
    };

    for (0..h) |row| {
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        for (0..w) |col| {
            const x = @as(f32, @floatFromInt(col)) + 0.5;
            const i = row * w + col;

            const sd = card.sdRoundRect(x, y, cr, radius);
            const cov = cov1(sd);
            // The border is the outer edge minus the same shape inset by the
            // border width, so it hugs the antialiased boundary instead of
            // being a second rounded rect that can disagree with it.
            const rim = @max(cov - cov1(sd + bw), 0.0);

            var shade: f32 = 0.0;
            if (cov < 1.0) {
                const sds = card.sdRoundRect(x, y, shadow, radius);
                shade = SHADOW_ALPHA * (1.0 - smooth(-blur, blur, sds)) * (1.0 - cov);
            }

            const a = std.math.clamp(cov + shade * (1.0 - cov), 0.0, 1.0);
            mask[i] = @intFromFloat(@round(a * 255.0));
            if (a <= 0.0) {
                bgr[i] = 0;
                continue;
            }
            // Straight color: the card's own color weighted by its coverage,
            // divided back out by the composite alpha. The shadow is black,
            // so it contributes nothing to the hue — only to the alpha.
            const c = mixRgb(fill, border, rim);
            const k = cov / a;
            bgr[i] = pack(
                scaleCh(c.r, k),
                scaleCh(c.g, k),
                scaleCh(c.b, k),
            );
        }
    }
}

fn cov1(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0.0, 1.0);
}

fn smooth(e0: f32, e1: f32, x: f32) f32 {
    if (e1 <= e0) return if (x < e0) 0.0 else 1.0;
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn mixRgb(a: Rgb, b: Rgb, t: f32) Rgb {
    const f = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = lerpCh(a.r, b.r, f),
        .g = lerpCh(a.g, b.g, f),
        .b = lerpCh(a.b, b.b, f),
    };
}

fn lerpCh(a: u8, b: u8, t: f32) u8 {
    const av: f32 = @floatFromInt(a);
    const bv: f32 = @floatFromInt(b);
    return @intFromFloat(std.math.clamp(@round(av + (bv - av) * t), 0.0, 255.0));
}

fn scaleCh(v: u8, k: f32) u32 {
    const f: f32 = @floatFromInt(v);
    return @intFromFloat(std.math.clamp(@round(f * k), 0.0, 255.0));
}

fn pack(r: u32, g: u32, b: u32) u32 {
    return (r << 16) | (g << 8) | b;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The four scales the design system requires every chrome number to be
/// asserted at. Most of these defects are invisible at 1.0 and obvious at
/// 1.25.
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

/// A plausible GDI measurement of "Read-only" at `font_px`, and of its
/// height. Only the relationship matters to the layout, so an approximation
/// keeps the geometry assertions honest without a device context.
fn measured(m: Metrics) struct { w: i32, h: i32 } {
    return .{ .w = @divTrunc(m.font_px * 9 * 55, 100), .h = m.font_px + 3 };
}

test "the card is anchored exactly INSET from the pane's top and right" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const t = measured(m);
        const l = layout(m, 1200, 800, t.w, t.h);
        try testing.expect(!l.hidden);
        // Card edges back in pane coordinates.
        const right_gap = 1200 - (l.win.left + l.card.right);
        const top_gap = l.win.top + l.card.top;
        try testing.expectEqual(m.inset, right_gap);
        try testing.expectEqual(m.inset, top_gap);
    }
}

test "the inset clears the design system's 4 DIP floor at every scale" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const floor: i32 = @intFromFloat(@round(4.0 * scale));
        try testing.expect(m.inset >= floor);
    }
}

test "content sits inside the card with its full padding, and never overlaps" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const t = measured(m);
        const l = layout(m, 1200, 800, t.w, t.h);
        // Glyph: one pad_x in from the left, vertically inside.
        try testing.expectEqual(l.card.left + m.pad_x, l.glyph.left);
        try testing.expect(l.glyph.top >= l.card.top);
        try testing.expect(l.glyph.bottom <= l.card.bottom);
        // Label: a full gap after the glyph, one pad_x short of the right.
        try testing.expectEqual(l.glyph.right + m.gap, l.text.left);
        try testing.expectEqual(l.card.right - m.pad_x, l.text.right);
        try testing.expect(l.text.left < l.text.right);
        // Nothing touches: glyph and label are separated by the gap.
        try testing.expect(l.text.left > l.glyph.right);
    }
}

test "the glyph is vertically centered in the card, with equal clearance" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const t = measured(m);
        const l = layout(m, 1200, 800, t.w, t.h);
        const above = l.glyph.top - l.card.top;
        const below = l.card.bottom - l.glyph.bottom;
        // Off by at most one on an odd leftover — never more, and never
        // biased by a whole pixel step.
        try testing.expect(@abs(above - below) <= 1);
        try testing.expect(above > 0);
    }
}

test "the window holds the card plus the shadow allowance" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const t = measured(m);
        const l = layout(m, 1200, 800, t.w, t.h);
        // The card is strictly inside the window on every side, so the drop
        // shade has pixels to paint into.
        try testing.expect(l.card.left > 0);
        try testing.expect(l.card.top > 0);
        try testing.expect(l.card.right < l.win.width());
        try testing.expect(l.card.bottom < l.win.height());
        // ...and the window itself stays inside the pane.
        try testing.expect(l.win.left >= 0);
        try testing.expect(l.win.top >= 0);
        try testing.expect(l.win.right <= 1200);
        try testing.expect(l.win.bottom <= 800);
    }
}

test "a narrow pane shrinks the card instead of overflowing it" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const t = measured(m);
        const full = layout(m, 1200, 800, t.w, t.h);
        const full_w = full.card.width();
        // A pane just wide enough for a clipped card.
        const pane_w = m.glyph + m.pad_x * 2 + m.inset * 2 + 6;
        const l = layout(m, pane_w, 800, t.w, t.h);
        try testing.expect(!l.hidden);
        try testing.expect(l.card.width() < full_w);
        // The inset survives the shrink on both sides.
        try testing.expectEqual(m.inset, pane_w - (l.win.left + l.card.right));
        try testing.expect(l.win.left + l.card.left >= m.inset);
    }
}

test "a pane too small for a badge hides it rather than drawing a stub" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const t = measured(m);
        // Narrower than glyph + padding + two insets.
        try testing.expect(layout(m, m.glyph, 800, t.w, t.h).hidden);
        // Shorter than the card plus its own insets.
        try testing.expect(layout(m, 1200, m.pad_y * 2, t.w, t.h).hidden);
        // Degenerate.
        try testing.expect(layout(m, 0, 0, t.w, t.h).hidden);
        try testing.expect(layout(m, -10, -10, t.w, t.h).hidden);
    }
}

test "metrics scale with DPI and never round a border out of existence" {
    var scale: f32 = 0.5;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        try testing.expect(m.border >= 1);
        try testing.expect(m.glyph >= 1);
        try testing.expect(m.inset >= 1);
        try testing.expect(m.shadowPad() >= 1);
    }
    // The unscaled numbers are the ones in the doc comment.
    const one = Metrics.init(1.0);
    try testing.expectEqual(@as(i32, 8), one.inset);
    try testing.expectEqual(@as(i32, 8), one.radius);
    try testing.expectEqual(@as(i32, 12), one.glyph);
    const two = Metrics.init(2.0);
    try testing.expectEqual(@as(i32, 16), two.inset);
    try testing.expectEqual(@as(i32, 16), two.radius);
    try testing.expectEqual(@as(i32, 24), two.glyph);
}

test "every metric lands on the 4 DIP spacing scale" {
    // Design system §0: one 4 DIP scale (2/4/8/12/16/24), no value off it.
    for ([_]f32{ INSET, PAD_X, PAD_Y, GAP, GLYPH, RADIUS, SHADOW_BLUR, SHADOW_DY }) |v| {
        const on_scale = v == 2.0 or v == 4.0 or v == 8.0 or v == 12.0 or
            v == 16.0 or v == 24.0;
        try testing.expect(on_scale);
    }
}

test "the label clears 4.5:1 and the border 3:1 on any pane background" {
    // Sweep the whole gray ramp plus a few saturated themes: the floors have
    // to hold on the user's background, not on the author's.
    // No tolerance: the floors are asserted against the colors that will
    // actually be painted, which is what `atLeast` exists to guarantee.
    var v: u8 = 0;
    while (true) : (v +|= 1) {
        const fill = fillColor(.{ .r = v, .g = v, .b = v });
        try testing.expect(ratio(labelColor(fill), fill) >= TEXT_CONTRAST);
        try testing.expect(ratio(borderColor(fill), fill) >= BORDER_CONTRAST);
        if (v == 255) break;
    }

    for ([_]Rgb{
        .{ .r = 16, .g = 16, .b = 20 }, // the usual dark terminal
        .{ .r = 253, .g = 246, .b = 227 }, // solarized light
        .{ .r = 0, .g = 43, .b = 54 }, // solarized dark
        .{ .r = 255, .g = 149, .b = 0 }, // the accent itself, worst case
        .{ .r = 128, .g = 96, .b = 32 }, // a mid-tone brown, no room either way
        .{ .r = 40, .g = 42, .b = 54 }, // dracula
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },
    }) |bg| {
        const fill = fillColor(bg);
        try testing.expect(ratio(labelColor(fill), fill) >= TEXT_CONTRAST);
        try testing.expect(ratio(borderColor(fill), fill) >= BORDER_CONTRAST);
    }
}

test "the accent survives where it can: an unmodified orange on a dark card" {
    // The border floor is the looser one precisely so the badge still reads
    // as ORANGE on a normal dark terminal rather than as a bleached outline.
    const fill = fillColor(.{ .r = 16, .g = 16, .b = 20 });
    try testing.expectEqual(ACCENT, borderColor(fill));
}

test "cardSize grows with the label and never below its content" {
    const m = Metrics.init(1.0);
    const small = cardSize(m, 10, 15);
    const big = cardSize(m, 100, 15);
    try testing.expect(big.w > small.w);
    try testing.expectEqual(small.h, big.h);
    // A zero/negative measurement still leaves room for the glyph — and
    // drops the gap with the label it was separating.
    const none = cardSize(m, -5, -5);
    try testing.expectEqual(m.glyph + m.pad_x * 2, none.w);
    try testing.expectEqual(m.glyph + m.pad_y * 2, none.h);
}

const DARK = Rgb{ .r = 16, .g = 16, .b = 20 };

/// Render at 1.0 into caller-sized buffers, returning the layout.
fn renderAt(bgr: []u32, mask: []u8, scale: f32) Layout {
    const m = Metrics.init(scale);
    const t = measured(m);
    const l = layout(m, 1200, 800, t.w, t.h);
    render(bgr, mask, m, l, DARK);
    return l;
}

test "render: the card interior is fully opaque, in the card's own fill" {
    var bgr: [400 * 200]u32 = @splat(0);
    var mask: [400 * 200]u8 = @splat(0);
    const l = renderAt(&bgr, &mask, 1.0);
    const w: usize = @intCast(l.win.width());
    const cx: usize = @intCast(@divTrunc(l.card.left + l.card.right, 2));
    const cy: usize = @intCast(@divTrunc(l.card.top + l.card.bottom, 2));
    const i = cy * w + cx;
    // Opaque: this is what keeps the label legible over live terminal text,
    // which is the one thing a translucent chip could not promise.
    try testing.expectEqual(@as(u8, 255), mask[i]);
    const fill = fillColor(DARK);
    try testing.expectEqual(pack(fill.r, fill.g, fill.b), bgr[i]);
}

test "render: the window's own corner is fully transparent" {
    var bgr: [400 * 200]u32 = @splat(0);
    var mask: [400 * 200]u8 = @splat(0);
    _ = renderAt(&bgr, &mask, 1.0);
    // Top-left of the window sits outside both the card and its downward
    // shade — nothing of the pane behind it may be tinted.
    try testing.expectEqual(@as(u8, 0), mask[0]);
}

test "render: a drop shade falls below the card and fades out" {
    var bgr: [400 * 200]u32 = @splat(0);
    var mask: [400 * 200]u8 = @splat(0);
    const l = renderAt(&bgr, &mask, 1.0);
    const w: usize = @intCast(l.win.width());
    const cx: usize = @intCast(@divTrunc(l.card.left + l.card.right, 2));
    const just_below: usize = @intCast(l.card.bottom + 1);
    const further: usize = @intCast(@min(l.card.bottom + 4, l.win.height() - 1));
    const near = mask[just_below * w + cx];
    const far = mask[further * w + cx];
    try testing.expect(near > 0);
    try testing.expect(far <= near);
    // Shade only — it never reaches the card's own opacity.
    try testing.expect(near < 255);
}

test "render: the border ring is the accent, not the fill" {
    var bgr: [400 * 200]u32 = @splat(0);
    var mask: [400 * 200]u8 = @splat(0);
    const l = renderAt(&bgr, &mask, 1.0);
    const w: usize = @intCast(l.win.width());
    const cx: usize = @intCast(@divTrunc(l.card.left + l.card.right, 2));
    const fill = fillColor(DARK);
    const border = borderColor(fill);
    // The topmost fully-covered row of the card is the ring.
    const edge: usize = @intCast(l.card.top);
    const p = bgr[edge * w + cx];
    try testing.expect(p != pack(fill.r, fill.g, fill.b));
    // And it is closer to the border color than to the fill.
    const dr = @abs(@as(i32, @intCast((p >> 16) & 0xFF)) - @as(i32, border.r));
    try testing.expect(dr < @abs(@as(i32, @intCast((p >> 16) & 0xFF)) - @as(i32, fill.r)));
}

test "render: every scale paints, and none writes out of bounds" {
    for (scales) |scale| {
        var bgr: [800 * 400]u32 = @splat(0xDEAD);
        var mask: [800 * 400]u8 = @splat(7);
        const l = renderAt(&bgr, &mask, scale);
        const n: usize = @intCast(l.win.width() * l.win.height());
        try testing.expect(n > 0);
        // Wrote exactly the claimed area: the first byte past it is untouched.
        try testing.expectEqual(@as(u8, 7), mask[n]);
        // Something opaque got painted.
        var opaque_px: usize = 0;
        for (mask[0..n]) |a| {
            if (a == 255) opaque_px += 1;
        }
        try testing.expect(opaque_px > 0);
    }
}

test "render: a hidden layout and undersized buffers paint nothing" {
    var bgr: [64]u32 = @splat(0);
    var mask: [64]u8 = @splat(0);
    const m = Metrics.init(1.0);
    render(&bgr, &mask, m, .{ .win = .{}, .card = .{}, .glyph = .{}, .text = .{}, .hidden = true }, DARK);
    try testing.expectEqual(@as(u32, 0), bgr[0]);
    // A real layout that does not fit the buffers refuses rather than
    // overrunning them.
    const t = measured(m);
    render(&bgr, &mask, m, layout(m, 1200, 800, t.w, t.h), DARK);
    try testing.expectEqual(@as(u32, 0), bgr[0]);
}

test "containsPoint follows the card, which is what a click has to hit" {
    const m = Metrics.init(1.0);
    const t = measured(m);
    const l = layout(m, 1200, 800, t.w, t.h);
    try testing.expect(l.card.containsPoint(l.card.left, l.card.top));
    try testing.expect(!l.card.containsPoint(l.card.right, l.card.top));
    try testing.expect(!l.card.containsPoint(l.card.left - 1, l.card.top));
    try testing.expect(l.card.containsPoint(
        @divTrunc(l.card.left + l.card.right, 2),
        @divTrunc(l.card.top + l.card.bottom, 2),
    ));
}
