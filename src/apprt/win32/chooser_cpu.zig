//! Pure model + geometry for the machine chooser's per-session CPU METER
//! (T462), the win32 half of Mac's `cpuMeterColumn`
//! (`MachineChooserView.swift:780-865`).
//!
//! The agent pushes one `session_cpu` frame per cadence it chose; this module
//! owns everything about how one reading is TURNED INTO a meter — the column's
//! geometry, the bar's fill fraction, which tone it is drawn in, and how the
//! number is spelled. `SessionCpuProbe.zig` owns the subscription and
//! `SessionRoster.zig` the GDI calls, so all of this runs in the `none` lane.
//!
//! Three rules shape it, and each one is Mac's for a reason worth keeping:
//!
//! - **The bar saturates at ONE core, the number carries the rest.** A bar
//!   scaled to the machine's core count leaves the common one-busy-core case a
//!   sliver, which is exactly the case the meter exists to make obvious. Past
//!   100% the bar is full and the digits say how full.
//! - **The column is reserved, never per-row.** Every row's title starts at the
//!   same x, so the meters stack into a scannable vertical strip — a column that
//!   collapses on some rows is not a column (design system §1.2). Reserving it
//!   is a decision about the MACHINE (does its agent serve the stream), never
//!   about the row.
//! - **0% is shown, not hidden.** Hiding idle rows makes "idle" and "the meter
//!   is broken" look identical, and it removes the baseline that makes a busy
//!   row obvious — 400% only reads as alarming next to neighbours at 0. A
//!   missing meter therefore means exactly one thing: no reading for this
//!   session.

const std = @import("std");

const chrome_theme = @import("chrome_theme.zig");
const color_math = @import("color_math.zig");
const type_ramp = @import("type_ramp.zig");

pub const Rgb = color_math.Rgb;
pub const Tone = chrome_theme.Tone;

// ---------------------------------------------------------------------
// The reading
// ---------------------------------------------------------------------

/// Per-core CPU% over a session's WHOLE process tree — top(1)'s convention, so
/// four busy threads read ~400%. `protocol.SessionCpuRow.cpu_pct`'s units,
/// carried through unchanged: the meter never re-normalizes by core count,
/// because "is this session eating cores" is precisely a question about cores.
pub const one_core: f32 = 100;

/// Where the bar stops growing. Mac's `min(pct / 100, 1)`.
pub fn barFill(cpu_pct: f32) f32 {
    if (!(cpu_pct > 0)) return 0; // also catches NaN
    return @min(cpu_pct / one_core, 1);
}

/// Above this the meter goes WARN. Mac's 40%: high enough that a shell echoing
/// a prompt never trips it, low enough that a build shows up before it pins a
/// core.
pub const warn_pct: f32 = 40;

/// The tone a reading is drawn in — the MEANING, never a literal color. Every
/// consumer resolves it against the surface it lands on (`chrome_theme.toneInk`),
/// so the same meaning clears the 3:1 chrome floor on light and dark alike.
///
/// Note this is not the only channel: an idle row still draws a full-width
/// TRACK with a short fill, so "quiet" and "busy" differ in bar length as well
/// as in hue (§2.4).
pub fn tone(cpu_pct: f32) Tone {
    if (cpu_pct >= one_core) return .danger;
    if (cpu_pct >= warn_pct) return .warn;
    return .neutral;
}

/// The meter's number: whole percent, Mac's `Int(pct.rounded())`. A negative or
/// NaN reading — which the wire cannot produce but a malformed frame could —
/// spells 0% rather than a minus sign in a column that has no room for one.
pub fn formatPct(buf: []u8, cpu_pct: f32) []const u8 {
    const v: f32 = if (cpu_pct > 0) cpu_pct else 0;
    return std.fmt.bufPrint(buf, "{d:.0}%", .{@round(v)}) catch "";
}

/// The ink for the bar's fill and its number.
pub fn meterInk(surface: Rgb, cpu_pct: f32) Rgb {
    return chrome_theme.toneInk(surface, tone(cpu_pct));
}

/// The bar's TRACK: the neutral ink at the chip alpha over the card, so an idle
/// meter is a drawn-but-empty gauge rather than nothing. One definition of "a
/// tint of a tone" for the whole chrome (`chrome_theme.toneFill`) — the track is
/// a container, not a boundary that carries meaning, so it is not held to 3:1;
/// what carries the meaning is the FILL, which is.
pub fn trackFill(surface: Rgb) Rgb {
    return chrome_theme.toneFill(surface, .neutral);
}

// ---------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Every number the meter column is built from, in physical pixels. All on the
/// 4 DIP scale (§1).
pub const Metrics = struct {
    /// The track's painted width. Mac's 26 rounded onto the scale.
    bar_w: i32,
    bar_h: i32,
    /// Capsule ends, so a 2-pixel fill is still a bar and not a square.
    bar_radius: i32,
    /// Bar -> number.
    gap: i32,
    /// The number's slot. FIXED, so a session getting busy can never resize its
    /// own number and shove the titles: the list must not twitch. Sized for
    /// three digits ("999%"), not for the theoretical maximum — reserving for
    /// "1600%" bought a guarantee nobody exercises and left a visible gap on
    /// every row, since the common reading is "0%". Past that the value runs
    /// into its own slack, which is the right thing to degrade.
    value_w: i32,
    /// The whole column: bar + gap + value. What `rowLayout` reserves.
    col_w: i32,
    /// Column -> the text column beside it.
    col_gap: i32,
};

pub const bar_dip: f32 = 24;
pub const bar_h_dip: f32 = 4;
pub const gap_dip: f32 = 4;
pub const value_dip: f32 = 28;
pub const col_gap_dip: f32 = 8;

pub fn metrics(scale: f32) Metrics {
    const bar_w = px(bar_dip, scale);
    const bar_h = px(bar_h_dip, scale);
    const gap = px(gap_dip, scale);
    const value_w = px(value_dip, scale);
    return .{
        .bar_w = bar_w,
        .bar_h = bar_h,
        .bar_radius = @max(@divTrunc(bar_h, 2), 1),
        .gap = gap,
        .value_w = value_w,
        .col_w = bar_w + gap + value_w,
        .col_gap = px(col_gap_dip, scale),
    };
}

/// The column's total width at `scale` — what a row reserves for it. A caller
/// that is not drawing a meter (an agent that cannot serve the stream) reserves
/// nothing, which is why this is asked for rather than folded into the row's own
/// metrics.
pub fn columnWidth(scale: f32) i32 {
    const m = metrics(scale);
    return m.col_w;
}

pub const Rect = struct {
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
};

/// Where the meter's pieces sit inside the column rect `col`, whose height is
/// the title's line box (the meter belongs beside the NAME, not floating in the
/// middle of a three-line card).
pub const MeterLayout = struct {
    /// The full-width track.
    track: Rect,
    /// The filled prefix of the track. Zero-width at 0%, which is a rect the
    /// caller must not paint — `fill.width() > 0` is the test.
    fill: Rect,
    /// The number's slot, left-aligned in it: the number belongs to the bar, so
    /// it sits right after it and the slack falls on its right, against the
    /// title. Pushed to the trailing edge instead, it parks against the title
    /// and reads as if it belonged to the title.
    value: Rect,
};

pub fn meterLayout(m: Metrics, col: Rect, cpu_pct: f32) MeterLayout {
    // Vertically centered on the line box the column was given.
    const bar_top = col.top + @divTrunc(col.height() - m.bar_h, 2);
    const track: Rect = .{
        .left = col.left,
        .top = bar_top,
        .right = col.left + m.bar_w,
        .bottom = bar_top + m.bar_h,
    };
    const filled: i32 = @intFromFloat(@round(barFill(cpu_pct) * @as(f32, @floatFromInt(m.bar_w))));
    return .{
        .track = track,
        .fill = .{
            .left = track.left,
            .top = track.top,
            .right = track.left + @min(filled, m.bar_w),
            .bottom = track.bottom,
        },
        .value = .{
            .left = track.right + m.gap,
            .top = col.top,
            .right = track.right + m.gap + m.value_w,
            .bottom = col.bottom,
        },
    };
}

// ---------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------

/// How many sessions one frame can carry into the store. A machine with more
/// live sessions than the roster can render (`SessionRoster.max_rows`) is
/// already past what the chooser shows; the extra readings are dropped rather
/// than growing state for rows nobody can see.
pub const max_rows: usize = 128;
/// Session ids are 32 hex chars on the wire; the buffer is this store's cap, not
/// a protocol constant.
pub const max_id: usize = 64;

/// The newest pushed sample, keyed by session id.
///
/// Written from the connection's control-reader thread and read from the GUI
/// thread, so every field is behind `mutex` — the same discipline
/// `ActivityMonitor`'s probe readings follow. Fixed storage: a push handler must
/// not allocate, and a bounded copy is what makes the borrowed frame safe to
/// walk away from (the rows die the moment the handler returns).
pub const Store = struct {
    mutex: std.Thread.Mutex = .{},
    ids: [max_rows][max_id]u8 = undefined,
    id_len: [max_rows]usize = @splat(0),
    pct: [max_rows]f32 = @splat(0),
    count: usize = 0,
    /// The cadence the AGENT reported in the last frame — it floors what we ask
    /// for and stretches it under its own load, so a slow meter is a throttled
    /// one and not a stalled one. Zero until the first frame lands.
    interval_ms: u32 = 0,
    /// How many frames have landed. The FIRST frame of a stream is a baseline
    /// with no delta behind it, so every reading in it is 0 — which is why
    /// "has a reading arrived" is not the same question as "is this number
    /// meaningful", and why the acceptance harness waits for two.
    frames: u64 = 0,

    /// Take one pushed frame. `rows` borrows the decoder's arena; everything
    /// kept is copied here.
    pub fn ingest(self: *Store, ids: []const []const u8, pcts: []const f32, interval_ms: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (ids, 0..) |id, i| {
            if (n >= max_rows) break;
            if (id.len == 0 or id.len > max_id) continue;
            @memcpy(self.ids[n][0..id.len], id);
            self.id_len[n] = id.len;
            self.pct[n] = if (i < pcts.len) pcts[i] else 0;
            n += 1;
        }
        self.count = n;
        self.interval_ms = interval_ms;
        self.frames +%= 1;
    }

    /// This session's newest reading, or null when the frame did not name it —
    /// a session the agent considers dead has no tree to roll up, and reporting
    /// 0 for it would be indistinguishable from an idle live one.
    pub fn get(self: *Store, id: []const u8) ?f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.ids[i][0..self.id_len[i]], id)) return self.pct[i];
        }
        return null;
    }

    pub fn intervalMs(self: *Store) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.interval_ms;
    }

    pub fn frameCount(self: *Store) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.frames;
    }

    /// Forget everything. Called when the subscription moves to another machine
    /// or goes away: a reading is a statement about ONE agent, and holding the
    /// last one across a target change would put machine A's numbers on machine
    /// B's rows — the same rule the roster's own `clear` follows.
    pub fn reset(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count = 0;
        self.interval_ms = 0;
        self.frames = 0;
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn contrast(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(color_math.wcagLuminance(a), color_math.wcagLuminance(b));
}

test "barFill saturates at one core" {
    try testing.expectEqual(@as(f32, 0), barFill(0));
    try testing.expectEqual(@as(f32, 0.5), barFill(50));
    try testing.expectEqual(@as(f32, 1), barFill(100));
    // Past one core the bar is full and the NUMBER carries the magnitude.
    try testing.expectEqual(@as(f32, 1), barFill(400));
    // Garbage in a frame must not produce a negative-width rect.
    try testing.expectEqual(@as(f32, 0), barFill(-5));
    try testing.expectEqual(@as(f32, 0), barFill(std.math.nan(f32)));
}

test "tone escalates with the reading" {
    try testing.expectEqual(Tone.neutral, tone(0));
    try testing.expectEqual(Tone.neutral, tone(39.9));
    try testing.expectEqual(Tone.warn, tone(40));
    try testing.expectEqual(Tone.warn, tone(99.9));
    try testing.expectEqual(Tone.danger, tone(100));
    try testing.expectEqual(Tone.danger, tone(412));
}

test "formatPct is whole percent, and never negative" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0%", formatPct(&buf, 0));
    try testing.expectEqualStrings("1%", formatPct(&buf, 0.6));
    try testing.expectEqualStrings("57%", formatPct(&buf, 57.3));
    try testing.expectEqualStrings("100%", formatPct(&buf, 99.7));
    try testing.expectEqualStrings("412%", formatPct(&buf, 412.4));
    try testing.expectEqualStrings("0%", formatPct(&buf, -3));
}

test "metrics sit on the 4 DIP scale at every scale factor" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        const m = metrics(s);
        // Every painted number is the DIP value scaled and rounded — no
        // per-scale fudges, which is what keeps the column identical to what
        // the design system says it is.
        try testing.expectEqual(@as(i32, @intFromFloat(@round(bar_dip * s))), m.bar_w);
        try testing.expectEqual(@as(i32, @intFromFloat(@round(bar_h_dip * s))), m.bar_h);
        try testing.expectEqual(@as(i32, @intFromFloat(@round(value_dip * s))), m.value_w);
        try testing.expectEqual(m.bar_w + m.gap + m.value_w, m.col_w);
        try testing.expectEqual(m.col_w, columnWidth(s));
        // The bar keeps its capsule ends and never degenerates to 0 radius.
        try testing.expect(m.bar_radius >= 1);
        try testing.expect(m.bar_radius * 2 <= m.bar_h + 1);
        // The column grows with the scale, monotonically.
        try testing.expect(m.col_w >= columnWidth(1.0));
    }
}

test "meterLayout: the bar is centered, the number follows it" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        const m = metrics(s);
        const col: Rect = .{ .left = 100, .top = 40, .right = 100 + m.col_w, .bottom = 40 + 20 };
        const l = meterLayout(m, col, 50);

        // The track occupies exactly the bar's width at the column's left edge.
        try testing.expectEqual(col.left, l.track.left);
        try testing.expectEqual(m.bar_w, l.track.width());
        try testing.expectEqual(m.bar_h, l.track.height());
        // Centered on the line box, within the rounding of an odd remainder.
        const above = l.track.top - col.top;
        const below = col.bottom - l.track.bottom;
        try testing.expect(@abs(above - below) <= 1);
        // The fill is a prefix of the track, never wider than it.
        try testing.expectEqual(l.track.left, l.fill.left);
        try testing.expect(l.fill.right <= l.track.right);
        // Half a core fills about half the bar.
        try testing.expect(@abs(l.fill.width() - @divTrunc(m.bar_w, 2)) <= 1);
        // The number sits after the bar with the gap, in its fixed slot, and
        // the whole thing fits the column it was given.
        try testing.expectEqual(l.track.right + m.gap, l.value.left);
        try testing.expectEqual(m.value_w, l.value.width());
        try testing.expectEqual(col.right, l.value.right);
    }
}

test "meterLayout: 0% draws a track and no fill; over 100% fills it" {
    const m = metrics(1.0);
    const col: Rect = .{ .left = 0, .top = 0, .right = m.col_w, .bottom = 20 };

    const idle = meterLayout(m, col, 0);
    try testing.expectEqual(@as(i32, 0), idle.fill.width());
    try testing.expect(idle.track.width() > 0);

    const pinned = meterLayout(m, col, 400);
    try testing.expectEqual(m.bar_w, pinned.fill.width());
}

test "the meter's ink clears the chrome contrast floor on both themes" {
    const dark: Rgb = .{ .r = 0x2B, .g = 0x2B, .b = 0x2B };
    const light: Rgb = .{ .r = 0xFA, .g = 0xFA, .b = 0xFA };
    for ([_]Rgb{ dark, light }) |bg| {
        for ([_]f32{ 0, 55, 250 }) |pct| {
            const ink = meterInk(bg, pct);
            // The same 0.05 slack `chooser_sessions` allows its badge inks: the
            // shared search runs in Lab and lands a hair under the target on
            // some surfaces.
            try testing.expect(contrast(ink, bg) >= chrome_theme.ui_contrast_target - 0.05);
        }
        // The track is a container, not a boundary: it only has to be VISIBLE
        // against the card it sits on.
        const track = trackFill(bg);
        try testing.expect(!std.meta.eql(track, bg));
    }
}

test "Store: newest frame wins, unknown ids report nothing" {
    var s: Store = .{};
    try testing.expectEqual(@as(?f32, null), s.get("a"));
    try testing.expectEqual(@as(u64, 0), s.frameCount());

    s.ingest(&.{ "aaa", "bbb" }, &.{ 12.5, 0 }, 2000);
    try testing.expectEqual(@as(?f32, 12.5), s.get("aaa"));
    try testing.expectEqual(@as(?f32, 0), s.get("bbb"));
    try testing.expectEqual(@as(?f32, null), s.get("ccc"));
    try testing.expectEqual(@as(u32, 2000), s.intervalMs());
    try testing.expectEqual(@as(u64, 1), s.frameCount());

    // A session the agent stops naming loses its reading rather than freezing
    // at the last one it had.
    s.ingest(&.{"aaa"}, &.{300}, 4000);
    try testing.expectEqual(@as(?f32, 300), s.get("aaa"));
    try testing.expectEqual(@as(?f32, null), s.get("bbb"));
    try testing.expectEqual(@as(u32, 4000), s.intervalMs());
    try testing.expectEqual(@as(u64, 2), s.frameCount());

    s.reset();
    try testing.expectEqual(@as(?f32, null), s.get("aaa"));
    try testing.expectEqual(@as(u32, 0), s.intervalMs());
    try testing.expectEqual(@as(u64, 0), s.frameCount());
}

test "Store: a frame bigger than the store is truncated, not overrun" {
    var s: Store = .{};
    var ids: [max_rows + 8][]const u8 = undefined;
    var pcts: [max_rows + 8]f32 = undefined;
    var bufs: [max_rows + 8][8]u8 = undefined;
    for (0..ids.len) |i| {
        ids[i] = std.fmt.bufPrint(&bufs[i], "s{d}", .{i}) catch unreachable;
        pcts[i] = @floatFromInt(i);
    }
    s.ingest(&ids, &pcts, 500);
    try testing.expectEqual(@as(?f32, 0), s.get("s0"));
    try testing.expectEqual(@as(?f32, null), s.get(ids[max_rows]));

    // An over-long id is skipped, not truncated into a different session's key.
    const long = "x" ** (max_id + 1);
    s.ingest(&.{ long, "ok" }, &.{ 99, 1 }, 500);
    try testing.expectEqual(@as(?f32, null), s.get(long));
    try testing.expectEqual(@as(?f32, 1), s.get("ok"));
}

test "Store: a short pct list leaves the extra rows at zero, not garbage" {
    var s: Store = .{};
    s.ingest(&.{ "a", "b" }, &.{7}, 1000);
    try testing.expectEqual(@as(?f32, 7), s.get("a"));
    try testing.expectEqual(@as(?f32, 0), s.get("b"));
}
