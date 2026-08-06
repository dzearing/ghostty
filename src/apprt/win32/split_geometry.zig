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

/// The divider's painted color. `rest` is the configured (or fallback)
/// divider color; `dark` says which way to shade — take it from the pane
/// background the divider separates (`!color_math.isLight(bg)`), not from
/// the OS theme: the divider has to read against the panes it sits between.
///
/// Hover and drag paint identically — a drag is a held hover, so the mark
/// must not change under the pointer at the moment it is grabbed.
pub fn dividerColor(rest: color_math.Rgb, dark: bool, hot: bool) color_math.Rgb {
    if (!hot) return rest;
    const d = hoverDelta(dark);
    return .{
        .r = icon_button.shadeChannel(rest.r, d),
        .g = icon_button.shadeChannel(rest.g, d),
        .b = icon_button.shadeChannel(rest.b, d),
    };
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
pub fn dragRatio(region_start: i32, region_end: i32, pos: i32) f32 {
    const total: f32 = @floatFromInt(@max(region_end - region_start, 1));
    const p: f32 = @floatFromInt(pos - region_start);
    return std.math.clamp(p / total, 0.1, 0.9);
}

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
