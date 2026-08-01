//! Pure trend-chart geometry for the win32 Activity Monitor's CPU and memory
//! gauges (T284, with `activity_layout.zig`).
//!
//! Mac draws these with Swift Charts (`TrendGaugeView`, with a non-Charts
//! fallback for < macOS 13). Win32 has no chart framework at all, so the chart
//! is a polyline plus the polygon under it, and this module is the mapping:
//! samples in, points out. No OS imports, so its unit tests run in every
//! app-runtime lane; `ActivityMonitor.zig` (T285) does the `Polyline` /
//! `Polygon` calls.
//!
//! Conventions, all of which the tests pin:
//!
//!   * Samples are percentages in 0..100, **oldest first**, so the newest
//!     lands on the right edge — a chart that grows leftward reads backwards.
//!   * `0` maps to the rect's last row and `100` to its first, so a full-scale
//!     sample paints ON the rect rather than one pixel outside it.
//!   * A partly-filled ring is drawn across the FULL width rather than
//!     bunched at one end: the gauge is a shape, and a shape that slides
//!     sideways for the first minute of every panel reads as a bug.

const std = @import("std");

pub const Rect = @import("activity_layout.zig").Rect;

/// Points retained in the trend ring, matching Mac's `maxSamples` (60 samples
/// at the 1.5s poll ~= 90 seconds of history).
pub const ring_capacity: usize = 60;

/// The poll interval the ring is sized for, in milliseconds.
pub const sample_interval_ms: u64 = 1500;

pub const Point = struct {
    x: i32,
    y: i32,
};

/// The percentages the horizontal gridlines are drawn at.
pub const gridline_values = [_]f32{ 0, 25, 50, 75, 100 };

fn clampPct(v: f32) f32 {
    if (std.math.isNan(v)) return 0;
    return std.math.clamp(v, 0, 100);
}

/// The y inside `r` for a percentage. `0` is the bottom row of the rect and
/// `100` the top one, so both extremes are painted rather than clipped.
pub fn valueToY(r: Rect, value: f32) i32 {
    const h = r.height();
    if (h <= 0) return r.top;
    const span: f32 = @floatFromInt(h - 1);
    const frac = clampPct(value) / 100.0;
    return r.bottom - 1 - @as(i32, @intFromFloat(@round(frac * span)));
}

/// The x of sample `i` of `count`, oldest at the left edge and newest at the
/// right. A single sample sits on the right edge, where the next one will
/// arrive.
pub fn sampleX(r: Rect, count: usize, i: usize) i32 {
    const w = r.width();
    if (w <= 0 or count == 0) return r.left;
    if (count == 1) return r.right - 1;
    const last: i64 = @intCast(count - 1);
    const idx: i64 = @intCast(@min(i, count - 1));
    const span: i64 = @intCast(w - 1);
    return r.left + @as(i32, @intCast(@divTrunc(idx * span + @divTrunc(last, 2), last)));
}

/// Map `samples` (oldest first) onto `out`, returning the used slice. `out`
/// must hold at least `samples.len` points; samples past its length are
/// dropped from the OLD end, so the newest data always survives.
pub fn polyline(r: Rect, samples: []const f32, out: []Point) []Point {
    if (samples.len == 0 or out.len == 0) return out[0..0];
    const start = if (samples.len > out.len) samples.len - out.len else 0;
    const used = samples[start..];
    for (used, 0..) |v, i| {
        out[i] = .{ .x = sampleX(r, used.len, i), .y = valueToY(r, v) };
    }
    return out[0..used.len];
}

/// The two points that close a polyline into the filled area beneath it: down
/// to the rect's floor under the newest sample, then back under the oldest.
/// Returns null for a line with nothing to fill under.
pub fn fillClose(r: Rect, line: []const Point) ?[2]Point {
    if (line.len == 0) return null;
    return .{
        .{ .x = line[line.len - 1].x, .y = r.bottom - 1 },
        .{ .x = line[0].x, .y = r.bottom - 1 },
    };
}

/// The index of the sample nearest `x`, for the hover readout. Null when there
/// are no samples or `x` is outside the rect — hovering the panel's padding
/// must not light up the last point.
pub fn sampleIndexAt(r: Rect, count: usize, x: i32) ?usize {
    if (count == 0) return null;
    if (x < r.left or x >= r.right) return null;
    if (count == 1) return 0;
    const w = r.width();
    if (w <= 1) return count - 1;
    const last: i64 = @intCast(count - 1);
    const span: i64 = @intCast(w - 1);
    const dx: i64 = @intCast(x - r.left);
    const idx = @divTrunc(dx * last + @divTrunc(span, 2), span);
    return @intCast(std.math.clamp(idx, 0, last));
}

/// Fill `out` with the y of each gridline, top to bottom.
pub fn gridlines(r: Rect, out: *[gridline_values.len]i32) void {
    for (gridline_values, 0..) |v, i| out[i] = valueToY(r, v);
}

/// The memory gauge plots a fraction of total RAM; CPU plots a percentage
/// already. This is the one conversion both call sites would otherwise
/// duplicate.
pub fn memoryPercent(used: u64, total: u64) f32 {
    if (total == 0) return 0;
    const u: f64 = @floatFromInt(used);
    const t: f64 = @floatFromInt(total);
    return clampPct(@floatCast(u / t * 100.0));
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

const chart: Rect = .{ .left = 20, .top = 100, .right = 220, .bottom = 164 };

test "gauge: 0 and 100 land on the rect's floor and ceiling" {
    try testing.expectEqual(chart.bottom - 1, valueToY(chart, 0));
    try testing.expectEqual(chart.top, valueToY(chart, 100));
    // Out-of-range and NaN samples clamp instead of painting outside.
    try testing.expectEqual(chart.bottom - 1, valueToY(chart, -40));
    try testing.expectEqual(chart.top, valueToY(chart, 250));
    try testing.expectEqual(chart.bottom - 1, valueToY(chart, std.math.nan(f32)));
}

test "gauge: y decreases monotonically as the value rises" {
    var prev = valueToY(chart, 0);
    var v: f32 = 1;
    while (v <= 100) : (v += 1) {
        const y = valueToY(chart, v);
        try testing.expect(y <= prev);
        try testing.expect(y >= chart.top);
        try testing.expect(y < chart.bottom);
        prev = y;
    }
    // Half scale is the middle row, within rounding.
    const mid = valueToY(chart, 50);
    const expect_mid = chart.top + @divTrunc(chart.height() - 1, 2);
    try testing.expect(@abs(mid - expect_mid) <= 1);
}

test "gauge: a degenerate rect never produces points outside it" {
    const flat: Rect = .{ .left = 10, .top = 10, .right = 10, .bottom = 10 };
    try testing.expectEqual(@as(i32, 10), valueToY(flat, 50));
    try testing.expectEqual(@as(i32, 10), sampleX(flat, 4, 2));
    try testing.expectEqual(@as(?usize, null), sampleIndexAt(flat, 4, 10));
}

test "gauge: samples run oldest-left to newest-right across the full width" {
    const n = 12;
    try testing.expectEqual(chart.left, sampleX(chart, n, 0));
    try testing.expectEqual(chart.right - 1, sampleX(chart, n, n - 1));
    // Monotonic, and never off the rect.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        try testing.expect(sampleX(chart, n, i) > sampleX(chart, n, i - 1));
        try testing.expect(sampleX(chart, n, i) < chart.right);
    }
    // A partly-filled ring still spans the width rather than bunching left.
    try testing.expectEqual(chart.left, sampleX(chart, 2, 0));
    try testing.expectEqual(chart.right - 1, sampleX(chart, 2, 1));
    // ...and the very first sample sits where the next one will arrive.
    try testing.expectEqual(chart.right - 1, sampleX(chart, 1, 0));
}

test "gauge: polyline maps every sample and keeps the newest under pressure" {
    var buf: [ring_capacity]Point = undefined;
    const samples = [_]f32{ 0, 25, 50, 75, 100 };
    const line = polyline(chart, &samples, &buf);
    try testing.expectEqual(@as(usize, samples.len), line.len);
    try testing.expectEqual(chart.left, line[0].x);
    try testing.expectEqual(chart.bottom - 1, line[0].y);
    try testing.expectEqual(chart.right - 1, line[line.len - 1].x);
    try testing.expectEqual(chart.top, line[line.len - 1].y);

    // An output buffer smaller than the ring drops from the OLD end.
    var small: [3]Point = undefined;
    const clipped = polyline(chart, &samples, &small);
    try testing.expectEqual(@as(usize, 3), clipped.len);
    try testing.expectEqual(valueToY(chart, 50), clipped[0].y);
    try testing.expectEqual(valueToY(chart, 100), clipped[2].y);

    // Nothing in, nothing out.
    try testing.expectEqual(@as(usize, 0), polyline(chart, &.{}, &buf).len);
}

test "gauge: the fill closes down to the floor under the first and last point" {
    var buf: [ring_capacity]Point = undefined;
    const samples = [_]f32{ 10, 90, 40 };
    const line = polyline(chart, &samples, &buf);
    const close = fillClose(chart, line).?;
    try testing.expectEqual(line[line.len - 1].x, close[0].x);
    try testing.expectEqual(chart.bottom - 1, close[0].y);
    try testing.expectEqual(line[0].x, close[1].x);
    try testing.expectEqual(chart.bottom - 1, close[1].y);
    try testing.expectEqual(@as(?[2]Point, null), fillClose(chart, &.{}));
}

test "gauge: hover hit test is the inverse of sampleX, and rejects the outside" {
    const n = 8;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(@as(?usize, i), sampleIndexAt(chart, n, sampleX(chart, n, i)));
    }
    try testing.expectEqual(@as(?usize, 0), sampleIndexAt(chart, n, chart.left));
    try testing.expectEqual(@as(?usize, n - 1), sampleIndexAt(chart, n, chart.right - 1));
    try testing.expectEqual(@as(?usize, null), sampleIndexAt(chart, n, chart.left - 1));
    try testing.expectEqual(@as(?usize, null), sampleIndexAt(chart, n, chart.right));
    try testing.expectEqual(@as(?usize, null), sampleIndexAt(chart, 0, chart.left + 5));
    // A single sample answers for the whole chart.
    try testing.expectEqual(@as(?usize, 0), sampleIndexAt(chart, 1, chart.left + 5));
}

test "gauge: gridlines span the rect, top to bottom, in order" {
    var lines: [gridline_values.len]i32 = undefined;
    gridlines(chart, &lines);
    try testing.expectEqual(chart.bottom - 1, lines[0]);
    try testing.expectEqual(chart.top, lines[lines.len - 1]);
    var i: usize = 1;
    while (i < lines.len) : (i += 1) try testing.expect(lines[i] <= lines[i - 1]);
}

test "gauge: memory percent is a clamped fraction of total" {
    try testing.expectEqual(@as(f32, 0), memoryPercent(0, 16 * 1024));
    try testing.expectEqual(@as(f32, 50), memoryPercent(8 * 1024, 16 * 1024));
    try testing.expectEqual(@as(f32, 100), memoryPercent(16 * 1024, 16 * 1024));
    // A total of zero is "unknown", not a divide by zero.
    try testing.expectEqual(@as(f32, 0), memoryPercent(4096, 0));
    // More used than total (a stale sample) clamps rather than overshooting.
    try testing.expectEqual(@as(f32, 100), memoryPercent(32 * 1024, 16 * 1024));
}

test "gauge: the ring matches Mac's retention" {
    // Mac: `maxSamples = 60` at a 1.5s poll (~90s of history).
    try testing.expectEqual(@as(usize, 60), ring_capacity);
    try testing.expectEqual(@as(u64, 1500), sample_interval_ms);
    try testing.expectEqual(@as(u64, 90_000), ring_capacity * sample_interval_ms);
}
