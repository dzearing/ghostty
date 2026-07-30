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

/// Width (horizontal split) or height (vertical split) of the divider band
/// in physical pixels, for a given DPI scale. Mac's divider is 1pt; 1 DIP
/// scaled is the direct analog (1px at 100%/125%, 2px at 150%/200%), and it
/// is never zero.
pub fn bandPx(scale: f32) i32 {
    return @max(@as(i32, @intFromFloat(@round(1.0 * scale))), 1);
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

test "bandPx: 1 DIP, never zero, Mac-equivalent at each common scale" {
    try testing.expectEqual(@as(i32, 1), bandPx(1.0));
    try testing.expectEqual(@as(i32, 1), bandPx(1.25));
    try testing.expectEqual(@as(i32, 2), bandPx(1.5));
    try testing.expectEqual(@as(i32, 2), bandPx(2.0));
    // Absurdly small scales still leave a visible divider.
    try testing.expectEqual(@as(i32, 1), bandPx(0.1));
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
    try testing.expectEqual(@as(i32, 200), a.band_lo);
    try testing.expectEqual(@as(i32, 201), a.band_hi);
    try testing.expectEqual(@as(i32, 1), a.bandWidth());

    // At 2x the band is 2px and still straddles the split position.
    const b = axis(100, 300, 0.5, 2.0);
    try testing.expectEqual(@as(i32, 200), b.split_pos);
    try testing.expectEqual(@as(i32, 199), b.band_lo);
    try testing.expectEqual(@as(i32, 201), b.band_hi);
    try testing.expectEqual(@as(i32, 2), b.bandWidth());
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
