//! Pure geometry for split-pane dividers (T155). No OS imports so these
//! unit tests run in every app-runtime lane (the hero_math.zig pattern).
//! The windowing half lives in Window.zig (layoutNode / paintDividerNode /
//! hitTestDividerNode), all three of which used to carry their own copy of
//! this arithmetic.
//!
//! Mac parity (`SplitView.swift`): the divider is a filled rectangle of
//! `splitterVisibleSize` = 1pt, and the panes are inset by exactly half of
//! it on each side — so the panes and the divider TILE the split rect with
//! no leftover parent background between them. The win32 port used to leave
//! a 5 DIP gap and stroke a 1px hairline down the middle of it, which
//! rendered as three visible edges (pane | parent bg | line | parent bg |
//! pane) and, because the parent never erases that gap, accumulated a stale
//! line every time the ratio changed.

const std = @import("std");
const testing = std.testing;
const color_math = @import("color_math.zig");
const icon_button = @import("icon_button.zig");

/// Width (horizontal split) or height (vertical split) of the divider band
/// in physical pixels, for a given DPI scale (design system §5).
///
/// **2 DIP, and a deliberate divergence from Mac's 1 pt** (T233). Windows'
/// common fractional scales round 1 DIP down to a SINGLE physical pixel at
/// both 100% and 125% — the two scales most users run — and a one-pixel line
/// against a dark pane reads as a rendering artifact rather than as a control
/// you can grab. macOS has no 125% and composites its 1 pt line differently,
/// so the number that is right there is wrong here. Recorded in
/// `docs/design/win32-design-system.md` §5 so a later parity sweep does not
/// "fix" it back.
pub fn bandPx(scale: f32) i32 {
    return @max(@as(i32, @intFromFloat(@round(2.0 * scale))), 2);
}

/// What a divider is painted with when the user set no `split-divider-color`
/// (Mac's `Ghostty.Config.swift` fallback, mid-gray). Lives here rather than at
/// a paint site because more than one divider reads it — the split dividers and
/// the hero/carousel divider — and a fallback that differs between them is the
/// same defect as ignoring the config outright.
pub const FALLBACK_COLOR: color_math.Rgb = .{ .r = 0x80, .g = 0x80, .b = 0x80 };

/// Per-channel shade applied to the divider while its grab band is hovered
/// or being dragged (design system §5).
///
/// The SIGN convention is `icon_button.fillDelta`'s and is asserted against
/// it below: shade toward the foreground in dark themes, away from it in
/// light ones. The MAGNITUDE is deliberately larger than a button's 15 —
/// a button fill is a 28 DIP square, while this is a 2 DIP mark, and the
/// same delta spread over ~1/20th of the area does not read as a state
/// change at a glance.
pub const HOVER_DELTA: i32 = 25;

/// Signed per-channel delta for the divider's hover/drag state.
pub fn hoverDelta(dark: bool) i32 {
    return if (dark) HOVER_DELTA else -HOVER_DELTA;
}

/// The contrast floor a divider must clear against the panes it separates:
/// WCAG 1.4.11's 3:1 for "chrome glyphs and meaningful boundaries" (design
/// system §2.3/§5). A divider IS a meaningful boundary — it is the control you
/// grab to resize a split.
pub const CONTRAST_FLOOR: f64 = 3.0;

/// The smallest per-channel separation that still comfortably reads as a state
/// change between the rest mark and the hover mark — the number the T233 test
/// already asserted for the fallback gray. `HOVER_DELTA` is what we aim for;
/// this is the point below which `dividerPaint` stops honoring the shade
/// DIRECTION convention and looks the other way for a more visible mark.
///
/// It is a preference, not a guarantee: a color squeezed between the contrast
/// floor and the end of the channel range can afford less, and the floor wins.
pub const HOVER_DELTA_MIN: i32 = 20;

/// The divider's PAINTED color for one state, with the chrome contrast floor
/// applied against the pane background (T251).
///
/// `configured` is the user's `split-divider-color` (or the fallback gray);
/// `bg` is the pane background the divider has to read against. The config
/// value itself is never rewritten — the floor is applied here, at paint time,
/// so the color round-trips through the config unchanged the way `min-contrast`
/// treats terminal text.
///
/// **A deliberate divergence from Mac**, which fills the divider with the raw
/// `split-divider-color` and checks nothing (`Ghostty.Config.swift`
/// `splitDividerColor`). Recorded in `docs/design/win32-design-system.md` §5,
/// the same treatment T233's 2 DIP band got. `split-divider-color = #0a0a0a`
/// on a black terminal is otherwise an invisible control whose hover shade
/// (#232323) is invisible too — the control and its feedback both disappear.
///
/// Both states are floored, and the hover mark additionally has to stay
/// DISTINGUISHABLE from rest: a hover that satisfies the contrast floor by
/// landing on the rest color is no feedback at all. The floor is absolute; the
/// hover MAGNITUDE is what gives way when a color leaves no room for both (see
/// `hoverShade`).
pub fn dividerPaint(configured: color_math.Rgb, bg: color_math.Rgb, hot: bool) color_math.Rgb {
    const bg_lum = color_math.wcagLuminance(bg);
    const rest = floored(configured, bg, bg_lum);
    if (!hot) return rest;

    // Which way to shade is decided by the PANE background, not the OS theme
    // (T233) — the divider has to read against the two panes it separates.
    const dark = !color_math.isLight(bg);
    const conventional = hoverShade(rest, bg_lum, hoverDelta(dark));
    if (channelDelta(conventional, rest) >= HOVER_DELTA_MIN) return conventional;

    // The conventional direction (icon_button's sign convention) has run out
    // of room. Two ways that happens, and only two: a rest color already
    // clamped at the end of the channel range, where the shade is a no-op, and
    // a background the shade moves TOWARD, where the floor bites first. Re-aim
    // rather than paint an invisible hover — legibility of the control
    // outranks the direction convention — but keep the conventional direction
    // when it is the more visible of the two anyway.
    const reaimed = hoverShade(rest, bg_lum, -hoverDelta(dark));
    return if (channelDelta(reaimed, rest) > channelDelta(conventional, rest))
        reaimed
    else
        conventional;
}

/// `rest` shaded by up to `d` per channel in `d`'s direction — the LARGEST
/// magnitude that still clears the contrast floor against `bg_lum`.
///
/// `HOVER_DELTA` is the design system's number and is what this returns
/// whenever the color has room for it. It gives way rather than the floor
/// because a hover 10 units short still reads as a state change, while a
/// hover under 3:1 has stopped reading as a divider at all. A color can be
/// genuinely squeezed — `split-divider-color = #f0f0f0` on a `#808080`
/// background sits at 3.47:1 with 15 units of headroom to white and only 14
/// before the darker side drops through the floor — and then a 15-step hover
/// is the whole truthful answer.
fn hoverShade(rest: color_math.Rgb, bg_lum: f64, d: i32) color_math.Rgb {
    const step: i32 = if (d < 0) -1 else 1;
    var m: i32 = @as(i32, @intCast(@abs(d)));
    while (m > 0) : (m -= 1) {
        const c = shade(rest, step * m);
        if (channelDelta(c, rest) == 0) continue; // clamped: no change to test
        if (contrastAgainst(c, bg_lum) >= CONTRAST_FLOOR) return c;
    }
    return rest;
}

/// The largest per-channel difference between two colors — "how much did the
/// mark visibly move".
fn channelDelta(a: color_math.Rgb, b: color_math.Rgb) i32 {
    const dr: i32 = @intCast(@abs(@as(i32, a.r) - @as(i32, b.r)));
    const dg: i32 = @intCast(@abs(@as(i32, a.g) - @as(i32, b.g)));
    const db: i32 = @intCast(@abs(@as(i32, a.b) - @as(i32, b.b)));
    return @max(dr, @max(dg, db));
}


/// `base` lifted to the chrome contrast floor against `bg`, hue preserved
/// where that is reachable. A color already clearing the floor is returned
/// untouched — this is a floor, not a restyle.
fn floored(base: color_math.Rgb, bg: color_math.Rgb, bg_lum: f64) color_math.Rgb {
    if (contrastAgainst(base, bg_lum) >= CONTRAST_FLOOR) return base;
    // No margin on the floor. This used to aim 0.15 PAST it, because the
    // search quantized only at the end and could answer a hair under the ratio
    // it searched for (~0.04 against a black background) — which also dragged
    // the boundary further from the color it started as than the floor needed.
    // T325 moved the search's acceptance test onto the color it returns; the
    // re-measure below stays as the local statement of the floor.
    const adjusted = color_math.contrastAdjustedTo(base, bg, CONTRAST_FLOOR);
    if (contrastAgainst(adjusted, bg_lum) >= CONTRAST_FLOOR) return adjusted;
    // A saturated color can clamp against the sRGB gamut before its luminance
    // gets where it needs to be, on BOTH sides of a mid-tone background. Plain
    // black or white always clears the floor, and losing the hue beats losing
    // the control.
    return color_math.contrastForeground(bg);
}

fn shade(c: color_math.Rgb, d: i32) color_math.Rgb {
    return .{
        .r = icon_button.shadeChannel(c.r, d),
        .g = icon_button.shadeChannel(c.g, d),
        .b = icon_button.shadeChannel(c.b, d),
    };
}

fn contrastAgainst(c: color_math.Rgb, bg_lum: f64) f64 {
    return color_math.wcagContrastRatio(color_math.wcagLuminance(c), bg_lum);
}

/// The divider's painted color. `rest` is the configured (or fallback)
/// divider color; `dark` says which way to shade — take it from the pane
/// background the divider separates (`!color_math.isLight(bg)`), not from
/// the OS theme: the divider has to read against the panes it sits between.
///
/// Hover and drag paint identically — a drag is a held hover, so the mark
/// must not change under the pointer at the moment it is grabbed.
///
/// This is the SHADE RULE alone. Painting goes through `dividerPaint`, which
/// wraps it in the 3:1 chrome contrast floor (T251); this stays public because
/// the rule — direction, magnitude, and rest-is-untouched — is worth stating
/// and asserting on its own.
pub fn dividerColor(rest: color_math.Rgb, dark: bool, hot: bool) color_math.Rgb {
    if (!hot) return rest;
    return shade(rest, hoverDelta(dark));
}

/// Half-width of the invisible grab band around the divider (T94, Mac's
/// `splitterInvisibleSize` = 8pt around the line). Deliberately much wider
/// than the visible band, which is why surface children must fall through
/// via WM_NCHITTEST/HTTRANSPARENT for the outer edges to be reachable.
pub fn grabHalfPx(scale: f32) i32 {
    return @max(@as(i32, @intFromFloat(@round(4.5 * scale))), 4);
}

/// One split resolved along its axis, in physical pixels. `lo` is the
/// left/top child, `hi` is the right/bottom child, and [`band_lo`,
/// `band_hi`) is the divider itself.
///
/// The three ranges tile [`lo_start`, `hi_end`) exactly:
/// `lo` = [lo_start, band_lo), divider = [band_lo, band_hi), `hi` =
/// [band_hi, hi_end). That is the property that makes stale divider pixels
/// impossible — every pixel the parent owns in the content area IS the
/// divider, so a ratio change repaints all of it and the old position is
/// covered by a child window.
pub const Axis = struct {
    /// Start of the low child (== the split rect's own start).
    lo_start: i32,
    /// Divider band start (== end of the low child, exclusive).
    band_lo: i32,
    /// Divider band end, exclusive (== start of the high child).
    band_hi: i32,
    /// End of the high child, exclusive (== the split rect's own end).
    hi_end: i32,
    /// The nominal split position the ratio asked for. The band is centered
    /// on it; the hit test measures distance from it.
    split_pos: i32,

    pub fn bandWidth(self: Axis) i32 {
        return self.band_hi - self.band_lo;
    }
};

/// Resolve a split along one axis. `start`/`end` are the split rect's
/// bounds on that axis (end exclusive), `ratio` is the child's share of it.
pub fn axis(start: i32, end: i32, ratio: f64, scale: f32) Axis {
    const total = end - start;
    const pos = start + @as(i32, @intFromFloat(
        @as(f32, @floatCast(ratio)) * @as(f32, @floatFromInt(total)),
    ));
    const band = bandPx(scale);
    return .{
        .lo_start = start,
        .band_lo = pos - @divTrunc(band, 2),
        .band_hi = pos + @divTrunc(band + 1, 2),
        .hi_end = end,
        .split_pos = pos,
    };
}

/// Whether a coordinate on the split's axis is inside the grab band.
pub fn inGrabBand(a: Axis, coord: i32, scale: f32) bool {
    const half = grabHalfPx(scale);
    return coord >= a.split_pos - half and coord <= a.split_pos + half;
}

/// Which way a split arranges its two children. A local mirror of
/// `SplitTree(View).Node.Split.Layout`, which is nested inside a generic and so
/// has no importable spelling; `Window.zig` converts with an exhaustive switch,
/// which is what makes a new variant over there a compile error over here.
pub const Layout = enum { horizontal, vertical };

/// The system resize cursor a divider shows while the pointer is in its grab
/// band, carrying the Windows `IDC_*` NUMBER rather than importing `win32.zig`
/// — this module has no OS imports, which is what lets its tests run in every
/// lane. `Window.zig` asserts the numbers still equal `w32.IDC_SIZEWE` /
/// `w32.IDC_SIZENS` in the win32 lane, so the two halves cannot drift apart.
///
/// **This is a named decision because no on-box test can see it** (T228).
/// `WM_SETCURSOR` carries no coordinates, so the handler has to read
/// `GetCursorPos` — which returns `-1,-1` on a background desktop, taking the
/// whole path through to `DefWindowProcW`. `split-divider.ps1` covers the
/// band's EXTENT with `WM_NCHITTEST` probes and its AXIS with drags along both
/// axes; the GLYPH is covered here and nowhere else.
pub const DividerCursor = enum {
    /// East–west double arrow (`IDC_SIZEWE`).
    size_we,
    /// North–south double arrow (`IDC_SIZENS`).
    size_ns,

    pub fn idc(self: DividerCursor) usize {
        return switch (self) {
            .size_we => 32644,
            .size_ns => 32645,
        };
    }
};

/// The cursor for a split divider, from the split's layout.
///
/// The arrow points along the axis the divider MOVES on, which is perpendicular
/// to the line the user sees: a `horizontal` split puts its children side by
/// side, so its divider is a vertical line dragged left and right — east–west.
/// A build that swapped these would hit-test the band correctly, drag
/// correctly, and show the wrong glyph the whole time.
pub fn dividerCursor(layout: Layout) DividerCursor {
    return switch (layout) {
        .horizontal => .size_we,
        .vertical => .size_ns,
    };
}

/// The hero/carousel divider's cursor. The carousel is a COLUMN beside the hero
/// pane (`HeroCarousel.splitRects`), so its divider is always a vertical line —
/// there is no layout to consult.
pub const HERO_DIVIDER_CURSOR: DividerCursor = .size_we;

/// Map a dragged pointer position to a split's new ratio (T495).
///
/// `region_start`/`region_end` are the DRAGGED NODE's own layout rect on the
/// drag axis — NEVER the whole surface. A split's ratio is relative to its own
/// sub-rectangle, and only the ROOT split's sub-rectangle is the surface. For
/// three equal columns the second divider rests at 2/3·W; mapping the pointer
/// against the full width hands the nested split 0.667 as its ratio, which
/// re-lays the divider out at 1/3·W + 0.667·(2/3·W) = 0.778·W — a rightward
/// leap of 0.111·W (~200px on the user's window) on the first motion tick,
/// after which the divider tracks OFFSET from the pointer instead of under it.
/// Mapping against the node's own region makes a grabbed-but-unmoved divider
/// reproduce its current ratio, and makes the [0.1, 0.9] clamp per-node.
///
/// This answers where the DRAGGED divider goes. What the rest of the tree does
/// about it — every other boundary holds its absolute position, so a drag
/// exchanges space between two panes and no others — is `split_resize.plan`
/// (T533), which is this function's sibling and lives next door.
pub fn dragRatio(region_start: i32, region_end: i32, pos: i32) f32 {
    const total: f32 = @floatFromInt(@max(region_end - region_start, 1));
    const p: f32 = @floatFromInt(pos - region_start);
    return std.math.clamp(p / total, MIN_RATIO, MAX_RATIO);
}

/// The band a split's ratio is held in: neither child of a split may be
/// squeezed below a tenth of the region they share. Named because a SECOND
/// caller now obeys it — `split_resize.holdRatio`, which pins the OTHER
/// boundaries during a drag (T533) and must give way at the same floor a
/// dragged divider does, or a compensated pane could vanish where a dragged
/// one cannot.
pub const MIN_RATIO: f32 = 0.1;
pub const MAX_RATIO: f32 = 0.9;

test "bandPx: 2 DIP, and never a single physical pixel at any scale" {
    try testing.expectEqual(@as(i32, 2), bandPx(1.0));
    try testing.expectEqual(@as(i32, 3), bandPx(1.25));
    try testing.expectEqual(@as(i32, 3), bandPx(1.5));
    try testing.expectEqual(@as(i32, 4), bandPx(2.0));
    // THE regression T233 fixes: at the two scales most users run, the old
    // 1 DIP band rounded to one pixel and read as an artifact.
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        try testing.expect(bandPx(scale) >= 2);
    }
    // Absurdly small scales still leave a grabbable divider.
    try testing.expectEqual(@as(i32, 2), bandPx(0.1));
}

test "hoverDelta: icon_button's sign convention, a divider's magnitude" {
    // Same DIRECTION as every other chrome hover, so the whole UI reacts the
    // same way to the pointer.
    try testing.expect(hoverDelta(true) > 0);
    try testing.expect(hoverDelta(false) < 0);
    try testing.expectEqual(
        std.math.sign(icon_button.fillDelta(.hover, true)),
        std.math.sign(hoverDelta(true)),
    );
    try testing.expectEqual(
        std.math.sign(icon_button.fillDelta(.hover, false)),
        std.math.sign(hoverDelta(false)),
    );
    // Bigger than a button's, on purpose (see HOVER_DELTA).
    try testing.expect(@abs(hoverDelta(true)) > @abs(icon_button.fillDelta(.hover, true)));
}

test "dividerColor: rest is untouched, hover lightens in dark and darkens in light" {
    const gray: color_math.Rgb = .{ .r = 128, .g = 128, .b = 128 };
    try testing.expect(gray.eql(dividerColor(gray, true, false)));
    try testing.expect(gray.eql(dividerColor(gray, false, false)));

    const on_dark = dividerColor(gray, true, true);
    try testing.expectEqual(@as(u8, 153), on_dark.r);
    try testing.expect(on_dark.r > gray.r and on_dark.g > gray.g and on_dark.b > gray.b);

    const on_light = dividerColor(gray, false, true);
    try testing.expectEqual(@as(u8, 103), on_light.r);
    try testing.expect(on_light.r < gray.r and on_light.g < gray.g and on_light.b < gray.b);

    // Channels clamp rather than wrap — a near-white divider on a light
    // theme must not roll over to black.
    const white: color_math.Rgb = .{ .r = 255, .g = 255, .b = 250 };
    const w_hot = dividerColor(white, true, true);
    try testing.expectEqual(@as(u8, 255), w_hot.r);
    const black: color_math.Rgb = .{ .r = 0, .g = 0, .b = 5 };
    const b_hot = dividerColor(black, false, true);
    try testing.expectEqual(@as(u8, 0), b_hot.r);
}

test "dividerColor: rest AND hover clear the 3:1 chrome floor on both themes" {
    // Design system §2.3/§5: a divider is a meaningful boundary, so 3:1
    // against BOTH panes it separates, in every state. Asserted rather than
    // eyeballed — the hover delta moves the mark toward the background it
    // has to stay legible against in one of the two themes.
    const fallback: color_math.Rgb = .{ .r = 128, .g = 128, .b = 128 };
    const dark_bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const light_bg: color_math.Rgb = .{ .r = 255, .g = 255, .b = 255 };

    inline for (.{
        .{ dark_bg, true },
        .{ light_bg, false },
    }) |case| {
        const bg: color_math.Rgb = case[0];
        const dark: bool = case[1];
        const bg_lum = color_math.wcagLuminance(bg);
        for ([_]bool{ false, true }) |hot| {
            const c = dividerColor(fallback, dark, hot);
            const ratio = color_math.wcagContrastRatio(color_math.wcagLuminance(c), bg_lum);
            try testing.expect(ratio >= 3.0);
        }
    }

    // And the hover state must be DISTINGUISHABLE from rest, not merely
    // legible: a hover nobody can see is the defect T233 exists to fix.
    for ([_]bool{ true, false }) |dark| {
        const rest = dividerColor(fallback, dark, false);
        const hot = dividerColor(fallback, dark, true);
        try testing.expect(!rest.eql(hot));
        const delta = @abs(@as(i32, hot.r) - @as(i32, rest.r));
        try testing.expect(delta >= 20);
    }
}

test "dividerPaint: an adversarial user color still clears the 3:1 floor in BOTH states" {
    // T251. T233 could only assert the floor for the FALLBACK gray, because
    // that was the only divider color the product controlled. `dividerPaint`
    // makes the floor a property of the paint, so a user's
    // `split-divider-color` cannot hide the control it names.
    const backgrounds = [_]color_math.Rgb{
        .{ .r = 0, .g = 0, .b = 0 }, // black terminal
        .{ .r = 0x0a, .g = 0x0a, .b = 0x0a }, // near-black
        .{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, // a typical dark theme
        .{ .r = 0x77, .g = 0x77, .b = 0x77 }, // isLight vs WCAG disagree here
        .{ .r = 0x80, .g = 0x80, .b = 0x80 }, // mid gray
        .{ .r = 0xfa, .g = 0xf8, .b = 0xf0 }, // near-white
        .{ .r = 255, .g = 255, .b = 255 }, // white terminal
    };
    const dividers = [_]color_math.Rgb{
        .{ .r = 0, .g = 0, .b = 0 }, // THE report: black on black
        .{ .r = 0x0a, .g = 0x0a, .b = 0x0a },
        .{ .r = 0x12, .g = 0x12, .b = 0x18 },
        .{ .r = 0x80, .g = 0x80, .b = 0x80 }, // the fallback
        .{ .r = 0, .g = 0, .b = 255 }, // pure blue: 2.44:1 on black
        .{ .r = 0xf0, .g = 0xf0, .b = 0xf0 },
        .{ .r = 255, .g = 255, .b = 255 }, // white on white
        .{ .r = 0xfe, .g = 0xfd, .b = 0xfa },
    };

    for (backgrounds) |bg| {
        const bg_lum = color_math.wcagLuminance(bg);
        for (dividers) |configured| {
            const rest = dividerPaint(configured, bg, false);
            const hot = dividerPaint(configured, bg, true);

            const rest_ratio = color_math.wcagContrastRatio(color_math.wcagLuminance(rest), bg_lum);
            const hot_ratio = color_math.wcagContrastRatio(color_math.wcagLuminance(hot), bg_lum);
            try testing.expect(rest_ratio >= CONTRAST_FLOOR);
            try testing.expect(hot_ratio >= CONTRAST_FLOOR);

            // And the hover has to be SEEN as a change, not merely be legible.
            try testing.expect(!rest.eql(hot));
            // The full HOVER_DELTA wherever the color has room for it. The one
            // squeezed pair in this sweep (#f0f0f0 on #808080) is pinned with
            // its numbers in its own test below.
            const moved = channelDelta(hot, rest);
            const squeezed = bg.eql(.{ .r = 128, .g = 128, .b = 128 }) and
                configured.eql(.{ .r = 0xf0, .g = 0xf0, .b = 0xf0 });
            try testing.expect(moved >= if (squeezed) 8 else HOVER_DELTA_MIN);
        }
    }
}

test "dividerPaint: a squeezed color spends the hover magnitude, never the floor" {
    // `split-divider-color = #f0f0f0` on a `#808080` background: 3.47:1 at
    // rest, 15 units of headroom to white, and only ~14 before the darker
    // (conventional, light-theme) side drops through 3:1. There is no shade
    // here that is both a full 25 and legal, so the magnitude gives way — the
    // floor does not.
    const bg: color_math.Rgb = .{ .r = 128, .g = 128, .b = 128 };
    const cfg: color_math.Rgb = .{ .r = 0xf0, .g = 0xf0, .b = 0xf0 };
    const bg_lum = color_math.wcagLuminance(bg);

    const rest = dividerPaint(cfg, bg, false);
    try testing.expect(cfg.eql(rest)); // legible already: untouched
    const hot = dividerPaint(cfg, bg, true);
    try testing.expect(contrastAgainst(hot, bg_lum) >= CONTRAST_FLOOR);
    try testing.expect(channelDelta(hot, rest) >= 8);
    try testing.expect(channelDelta(hot, rest) < HOVER_DELTA);

    // The full conventional shade IS what a floor-blind build would paint,
    // and it is under the floor — that is the trade being made here.
    try testing.expect(contrastAgainst(shade(rest, -HOVER_DELTA), bg_lum) < CONTRAST_FLOOR);
}

test "dividerPaint: a color that already clears the floor is painted verbatim" {
    // The floor is a floor, not a restyle: `split-divider-color` that is
    // legible arrives at the brush unchanged, hue and all. This is what makes
    // the adjustment defensible — it only fires where the alternative is a
    // control the user cannot see.
    const black: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: color_math.Rgb = .{ .r = 255, .g = 255, .b = 255 };

    const red: color_math.Rgb = .{ .r = 255, .g = 0, .b = 0 }; // 5.25:1 on black
    try testing.expect(red.eql(dividerPaint(red, black, false)));
    const green: color_math.Rgb = .{ .r = 0, .g = 255, .b = 0 };
    try testing.expect(green.eql(dividerPaint(green, black, false)));
    const gray: color_math.Rgb = .{ .r = 128, .g = 128, .b = 128 };
    try testing.expect(gray.eql(dividerPaint(gray, black, false)));
    try testing.expect(gray.eql(dividerPaint(gray, white, false)));

    // ... and the hover shade on top of it is still the plain T233 rule, so
    // the acceptance script's 128 -> 153 oracle keeps meaning what it says.
    try testing.expect(dividerColor(gray, true, true).eql(dividerPaint(gray, black, true)));
    try testing.expect(dividerColor(gray, false, true).eql(dividerPaint(gray, white, true)));
}

test "dividerPaint: THE T251 report - near-black divider on a black terminal" {
    // `split-divider-color = #0a0a0a` on `background = #000000`: 1.10:1 at
    // rest, and T233's hover shade takes it to #232323, which is 1.42:1. Both
    // states invisible — the control disappears and its feedback with it.
    const bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const configured: color_math.Rgb = .{ .r = 0x0a, .g = 0x0a, .b = 0x0a };
    const bg_lum = color_math.wcagLuminance(bg);

    // Pin the defect itself, so the numbers above are not just a comment.
    const unfloored_rest = dividerColor(configured, true, false);
    const unfloored_hot = dividerColor(configured, true, true);
    try testing.expect(color_math.wcagContrastRatio(color_math.wcagLuminance(unfloored_rest), bg_lum) < 1.2);
    try testing.expect(color_math.wcagContrastRatio(color_math.wcagLuminance(unfloored_hot), bg_lum) < 1.5);

    const rest = dividerPaint(configured, bg, false);
    const hot = dividerPaint(configured, bg, true);
    try testing.expect(rest.r > 0x0a); // lifted off the background
    try testing.expect(color_math.wcagContrastRatio(color_math.wcagLuminance(rest), bg_lum) >= CONTRAST_FLOOR);
    try testing.expect(color_math.wcagContrastRatio(color_math.wcagLuminance(hot), bg_lum) >= CONTRAST_FLOOR);
    try testing.expect(!rest.eql(hot));
}

test "dividerPaint: a clamped rest color still gets a visible hover" {
    // White divider on a black terminal: the conventional dark-theme shade
    // (lighten) is a no-op at 255, so the hover would land ON the rest color.
    // Re-aiming is what keeps the grab feedback; the contrast floor is not in
    // danger on either side here.
    const black: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: color_math.Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const rest = dividerPaint(white, black, false);
    const hot = dividerPaint(white, black, true);
    try testing.expect(white.eql(rest));
    try testing.expect(hot.r <= 255 - HOVER_DELTA_MIN);
    try testing.expect(color_math.wcagContrastRatio(
        color_math.wcagLuminance(hot),
        color_math.wcagLuminance(black),
    ) >= CONTRAST_FLOOR);

    // The mirror case: black divider on a white terminal.
    const rest2 = dividerPaint(black, white, false);
    const hot2 = dividerPaint(black, white, true);
    try testing.expect(black.eql(rest2));
    try testing.expect(hot2.r >= HOVER_DELTA_MIN);
}

test "axis: panes and divider tile the rect with no leftover gap" {
    // THE regression this module exists for: any leftover parent-owned
    // pixel between the panes is a place a stale divider line can survive.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0, 3.0 }) |scale| {
        for ([_]f64{ 0.1, 0.25, 0.5, 0.5001, 0.75, 0.9 }) |ratio| {
            const a = axis(0, 1000, ratio, scale);
            try testing.expectEqual(a.lo_start, 0);
            try testing.expectEqual(a.hi_end, 1000);
            // No gap on either side of the band, and no overlap.
            try testing.expect(a.band_lo <= a.band_hi);
            try testing.expectEqual(bandPx(scale), a.bandWidth());
            // The band straddles the requested split position.
            try testing.expect(a.split_pos >= a.band_lo);
            try testing.expect(a.split_pos <= a.band_hi);
        }
    }
}

test "axis: band is centered and respects a non-zero rect origin" {
    const a = axis(100, 300, 0.5, 1.0);
    try testing.expectEqual(@as(i32, 200), a.split_pos);
    try testing.expectEqual(@as(i32, 199), a.band_lo);
    try testing.expectEqual(@as(i32, 201), a.band_hi);
    try testing.expectEqual(@as(i32, 2), a.bandWidth());

    // At 2x the band is 4px and still straddles the split position.
    const b = axis(100, 300, 0.5, 2.0);
    try testing.expectEqual(@as(i32, 200), b.split_pos);
    try testing.expectEqual(@as(i32, 198), b.band_lo);
    try testing.expectEqual(@as(i32, 202), b.band_hi);
    try testing.expectEqual(@as(i32, 4), b.bandWidth());
}

test "axis: a small ratio change moves the band by more than its width" {
    // Two dragged positions must not produce two SEPARATE bands that both
    // look like dividers; the old one has to be covered by a child. This
    // holds as long as the band is only as wide as the inset, which the
    // tiling test above pins.
    const before = axis(0, 1000, 0.50, 1.0);
    const after = axis(0, 1000, 0.55, 1.0);
    try testing.expect(after.band_lo >= before.band_hi);
    // The old band's pixels now belong to the LOW child of the new layout.
    try testing.expect(before.band_lo >= after.lo_start);
    try testing.expect(before.band_hi <= after.band_lo);
}

test "dragRatio: root divider keeps the old math" {
    // For the root split the node's region IS the surface, so nothing moves.
    try testing.expectApproxEqAbs(@as(f32, 0.5), dragRatio(0, 1000, 500), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), dragRatio(0, 1000, 250), 0.001);
    // Clamp, both ends, including positions outside the region entirely.
    try testing.expectApproxEqAbs(@as(f32, 0.1), dragRatio(0, 1000, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.1), dragRatio(0, 1000, -400), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.9), dragRatio(0, 1000, 1000), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.9), dragRatio(0, 1000, 5000), 0.001);
}

test "dragRatio: a grabbed nested divider that has not moved stays put (T495)" {
    // The user's geometry: three side-by-side columns on a ~3110px surface,
    // tree = split(1/3) -> [pane, split(1/2) -> [pane, pane]]. The second
    // divider's region is the right split's own rect, NOT the surface.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const w: i32 = 3110;
        const root = axis(0, w, 1.0 / 3.0, scale);
        // The nested split subdivides the right child's rect.
        const nested = axis(root.band_hi, w, 0.5, scale);

        // Grabbing the divider at its RESTING position and computing against
        // the node's own region reproduces the current ratio — the divider
        // does not move until the pointer does.
        const kept = dragRatio(root.band_hi, w, nested.split_pos);
        const region_w: f32 = @floatFromInt(w - root.band_hi);
        try testing.expectApproxEqAbs(@as(f32, 0.5), kept, 1.5 / region_w);

        // THE BUG, pinned so it cannot come back unnamed: the same pointer
        // mapped against the WHOLE surface reads ~0.667 — which re-lays the
        // divider out at ~0.778·W, a leap of ~0.111·W (~345px here).
        const wrong = dragRatio(0, w, nested.split_pos);
        try testing.expect(wrong > 0.66 and wrong < 0.68);
        const relaid = axis(root.band_hi, w, wrong, scale);
        const jump = relaid.split_pos - nested.split_pos;
        try testing.expect(jump > @divTrunc(w, 10)); // > ~311px of teleport

        // Pointer at the region's midpoint means HALF, exactly.
        const mid = root.band_hi + @divTrunc(w - root.band_hi, 2);
        try testing.expectApproxEqAbs(@as(f32, 0.5), dragRatio(root.band_hi, w, mid), 1.5 / region_w);
    }
}

test "dragRatio: vertical analog (same function, rows for columns)" {
    // The axis is abstract: a 3-row layout maps y against the node's own
    // vertical region the same way.
    const h: i32 = 1200;
    const root = axis(0, h, 1.0 / 3.0, 1.0);
    const nested = axis(root.band_hi, h, 0.5, 1.0);
    const kept = dragRatio(root.band_hi, h, nested.split_pos);
    const region_h: f32 = @floatFromInt(h - root.band_hi);
    try testing.expectApproxEqAbs(@as(f32, 0.5), kept, 1.5 / region_h);
}

test "dividerCursor: the arrow points along the DRAG axis, not along the line" {
    // T228, and the whole content of the rule: a `horizontal` split puts its
    // children side by side, so what the user sees is a VERTICAL line and what
    // they do to it is drag left/right.
    try testing.expectEqual(DividerCursor.size_we, dividerCursor(.horizontal));
    try testing.expectEqual(DividerCursor.size_ns, dividerCursor(.vertical));

    // The hero/carousel divider is a column boundary, always east–west.
    try testing.expectEqual(DividerCursor.size_we, HERO_DIVIDER_CURSOR);

    // A mapping that answered the SAME cursor for both axes passes every probe
    // `split-divider.ps1` can still run on a background desktop — the hit test,
    // the drags, the band extent. Pin the distinction itself.
    try testing.expect(dividerCursor(.horizontal) != dividerCursor(.vertical));
}

test "DividerCursor.idc: the OS cursor ids, pinned by number" {
    // Here rather than only in the win32 lane so the none lane catches a swap
    // too; `Window.zig` checks these against `w32.IDC_*` where those exist.
    try testing.expectEqual(@as(usize, 32644), DividerCursor.size_we.idc());
    try testing.expectEqual(@as(usize, 32645), DividerCursor.size_ns.idc());
    try testing.expect(DividerCursor.size_we.idc() != DividerCursor.size_ns.idc());
}

test "grab band is wider than the visible band on both sides" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const a = axis(0, 1000, 0.5, scale);
        try testing.expect(grabHalfPx(scale) > a.bandWidth());
        // Reachable from a few DIP into either pane (T94's whole point).
        try testing.expect(inGrabBand(a, a.split_pos - grabHalfPx(scale), scale));
        try testing.expect(inGrabBand(a, a.split_pos + grabHalfPx(scale), scale));
        try testing.expect(!inGrabBand(a, a.split_pos - grabHalfPx(scale) - 1, scale));
        try testing.expect(!inGrabBand(a, a.split_pos + grabHalfPx(scale) + 1, scale));
    }
}
