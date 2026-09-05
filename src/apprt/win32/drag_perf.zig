//! T1343: what one splitter-drag motion tick COSTS, and whether the drag the
//! user is watching is smooth or steppy.
//!
//! A divider drag is one `WM_MOUSEMOVE` → `updateDividerDrag` →
//! `layoutSplitsLive` per motion tick, and the whole chain runs on the UI
//! thread, so the tick's wall clock IS the drag's frame time: a tick that
//! costs 60 ms is a drag that moves four times a second no matter how fast the
//! mouse is reporting. The user's 2026-09-04 report ("resizing panes is janky
//! and slow ... it feels so unpolished") was about exactly that number, and
//! nothing had ever measured it.
//!
//! The cost that dominates it is a WAIT, not work: each resized pane blocks
//! the UI thread on its renderer presenting a frame at the new size, so the
//! anti-flicker guarantee is bought once per pane. `serialWaitCeilingUs` and
//! `batchedWaitCeilingUs` below are the two shapes of that bill — the first is
//! what the code did until T1343, the second is what it does now — and the
//! whole point of the fix is that only one of them grows with the pane count.
//!
//! Same split as `layout_cost.zig` beside it: pure arithmetic here, the
//! Windows-facing half (the clock, the event handles, the log line) in
//! `Window.zig`.

const std = @import("std");
const testing = std.testing;

/// One display frame at 60 Hz, in microseconds. A motion tick that fits inside
/// this cannot drop a frame; one that does not is a step the user sees.
pub const frame_budget_us: u64 = 16_667;

/// The per-pane frame wait, in microseconds — `WaitForSingleObject(event, 16)`
/// as `Surface.handleResize` spells it.
pub const frame_wait_ms: u64 = 16;

/// What the frame wait can cost a motion tick when it is paid PER PANE: the
/// pre-T1343 shape, where every resized surface waits its own 16 ms in turn.
/// Linear in the pane count, which is why the drag got worse the more panes
/// were open — the complaint the task was filed from.
pub fn serialWaitCeilingUs(panes: usize) u64 {
    return @as(u64, panes) * frame_wait_ms * std.time.us_per_ms;
}

/// What the same wait costs when the whole layout pass waits ONCE for every
/// pane's frame together (`WaitForMultipleObjects(bWaitAll)`): flat in the
/// pane count, because the panes render in parallel on their own threads and
/// only the serialization of the waiting was ever ours.
pub fn batchedWaitCeilingUs(panes: usize) u64 {
    return if (panes == 0) 0 else frame_wait_ms * std.time.us_per_ms;
}

/// One motion tick of a divider drag.
pub const Sample = struct {
    /// The whole `updateDividerDrag` call: ratio solve + layout pass + frame
    /// wait. This is the number the drag's smoothness is made of.
    tick_us: u64 = 0,
    /// The part of `tick_us` spent blocked on renderer frames.
    wait_us: u64 = 0,
    /// Panes resized by this tick — the multiplier on the serial shape.
    panes: usize = 0,
    /// How many separate frame WAITS this tick performed. One per resized pane
    /// on the serial shape, exactly one for the whole pass on the batched one.
    ///
    /// This is the observable that does not depend on the machine: whether a
    /// wait actually costs 16 ms is up to whether the compositor is throttling
    /// presents (on a hidden test desktop it usually is not), but how many
    /// times the UI thread agreed to stop and wait is a property of the code.
    waits: usize = 0,
    /// Panes that took a `WM_SIZE` in this tick. Zero waits with zero resizes
    /// means the tick did no layout work; zero waits with several resizes would
    /// mean the synchronous-present path has quietly stopped running.
    resizes: usize = 0,
    /// The dim-overlay refresh at the end of the layout pass, and the panes'
    /// own `sizeCallback` (grid reflow + renderer viewport + PTY SIGWINCH),
    /// summed over the tick. Together with `wait_us` these are the three parts
    /// a motion tick is made of — measured, because the task this module was
    /// written for assumed the wait was the whole bill and it is not.
    overlay_us: u64 = 0,
    resize_us: u64 = 0,
    /// The layout pass itself, which contains the wait, the overlays and the
    /// panes' resizes. `tick_us - layout_us` is the ratio solve on top of it.
    layout_us: u64 = 0,
    /// The two halves of that pass which are neither the wait nor the
    /// overlays: placing the panes (which dispatches their `WM_SIZE`) and
    /// repainting the divider bands.
    place_us: u64 = 0,
    paint_us: u64 = 0,
    /// How many of those waits ran out the full timeout rather than being woken
    /// by a presented frame — the shape that costs the drag a whole frame each.
    timeouts: usize = 0,

    /// Work the UI thread actually did, as opposed to waited for.
    pub fn workUs(self: Sample) u64 {
        return self.tick_us -| self.wait_us;
    }

    pub fn overBudget(self: Sample) bool {
        return self.tick_us > frame_budget_us;
    }
};

/// A whole drag, accumulated tick by tick. Fixed size, no allocator: this runs
/// inside the motion path it is measuring.
pub const Stats = struct {
    ticks: u64 = 0,
    total_us: u64 = 0,
    max_us: u64 = 0,
    wait_us: u64 = 0,
    over_budget: u64 = 0,
    panes_max: usize = 0,
    /// The most frame waits any single tick performed. The number the fix is
    /// about: 1 whatever the pane count, instead of one per pane.
    waits_max: usize = 0,
    resizes_max: usize = 0,
    waits_total: u64 = 0,
    timeouts_total: u64 = 0,
    overlay_us: u64 = 0,
    resize_us: u64 = 0,
    layout_us: u64 = 0,
    place_us: u64 = 0,
    paint_us: u64 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn record(self: *Stats, s: Sample) void {
        self.ticks += 1;
        self.total_us += s.tick_us;
        self.wait_us += s.wait_us;
        if (s.tick_us > self.max_us) self.max_us = s.tick_us;
        if (s.panes > self.panes_max) self.panes_max = s.panes;
        if (s.waits > self.waits_max) self.waits_max = s.waits;
        if (s.resizes > self.resizes_max) self.resizes_max = s.resizes;
        self.overlay_us += s.overlay_us;
        self.layout_us += s.layout_us;
        self.place_us += s.place_us;
        self.paint_us += s.paint_us;
        self.resize_us += s.resize_us;
        self.waits_total += s.waits;
        self.timeouts_total += s.timeouts;
        if (s.overBudget()) self.over_budget += 1;
    }

    pub fn meanUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.total_us / self.ticks;
    }

    pub fn meanWaitUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.wait_us / self.ticks;
    }

    pub fn meanLayoutUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.layout_us / self.ticks;
    }

    pub fn meanPlaceUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.place_us / self.ticks;
    }

    pub fn meanPaintUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.paint_us / self.ticks;
    }

    pub fn meanOverlayUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.overlay_us / self.ticks;
    }

    pub fn meanResizeUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.resize_us / self.ticks;
    }

    /// Drag frames per second implied by the mean tick — the number a watching
    /// human is actually judging. 0 ticks reads as 0 rather than infinity.
    pub fn fps(self: Stats) u64 {
        const mean = self.meanUs();
        if (mean == 0) return 0;
        return std.time.us_per_s / mean;
    }

    /// The verdict a harness can assert on. `smooth` means the average tick
    /// fits in a frame; `steppy` means the drag is visibly behind the mouse.
    pub fn verdict(self: Stats) Verdict {
        if (self.ticks == 0) return .no_data;
        return if (self.meanUs() <= frame_budget_us) .smooth else .steppy;
    }
};

pub const Verdict = enum { no_data, smooth, steppy };

test "serial wait grows with pane count, batched does not" {
    // The whole claim the fix rests on, in one assertion pair.
    try testing.expectEqual(@as(u64, 16_000), serialWaitCeilingUs(1));
    try testing.expectEqual(@as(u64, 64_000), serialWaitCeilingUs(4));
    try testing.expectEqual(@as(u64, 128_000), serialWaitCeilingUs(8));

    try testing.expectEqual(@as(u64, 16_000), batchedWaitCeilingUs(1));
    try testing.expectEqual(@as(u64, 16_000), batchedWaitCeilingUs(4));
    try testing.expectEqual(@as(u64, 16_000), batchedWaitCeilingUs(8));

    // Nothing resized, nothing waited for.
    try testing.expectEqual(@as(u64, 0), serialWaitCeilingUs(0));
    try testing.expectEqual(@as(u64, 0), batchedWaitCeilingUs(0));
}

test "four panes on the serial shape cannot hold a frame; batched can" {
    try testing.expect(serialWaitCeilingUs(4) > frame_budget_us);
    try testing.expect(batchedWaitCeilingUs(4) <= frame_budget_us + 1);
}

test "sample splits work from waiting and never underflows" {
    const s: Sample = .{ .tick_us = 20_000, .wait_us = 16_000, .panes = 4 };
    try testing.expectEqual(@as(u64, 4_000), s.workUs());
    try testing.expect(s.overBudget());

    // A wait that outlasts the tick is a clock artifact, not a negative.
    const odd: Sample = .{ .tick_us = 100, .wait_us = 900 };
    try testing.expectEqual(@as(u64, 0), odd.workUs());
}

test "stats accumulate mean, max, fps and the over-budget count" {
    var st: Stats = .{};
    try testing.expectEqual(Verdict.no_data, st.verdict());
    try testing.expectEqual(@as(u64, 0), st.fps());

    st.record(.{
        .tick_us = 10_000,
        .wait_us = 8_000,
        .panes = 2,
        .waits = 2,
        .timeouts = 1,
        .resizes = 2,
        .overlay_us = 1_000,
        .resize_us = 3_000,
        .layout_us = 9_000,
        .place_us = 5_000,
        .paint_us = 100,
    });
    st.record(.{
        .tick_us = 30_000,
        .wait_us = 28_000,
        .panes = 4,
        .waits = 4,
        .timeouts = 4,
        .resizes = 4,
        .overlay_us = 2_000,
        .resize_us = 1_000,
        .layout_us = 29_000,
        .place_us = 25_000,
        .paint_us = 300,
    });

    // The wait COUNT is the machine-independent half of the measurement: how
    // long a wait takes depends on whether the compositor is throttling
    // presents, how many the tick agreed to perform does not.
    try testing.expectEqual(@as(usize, 4), st.waits_max);
    try testing.expectEqual(@as(u64, 6), st.waits_total);
    try testing.expectEqual(@as(u64, 5), st.timeouts_total);
    try testing.expectEqual(@as(usize, 4), st.resizes_max);
    try testing.expectEqual(@as(u64, 1_500), st.meanOverlayUs());
    try testing.expectEqual(@as(u64, 2_000), st.meanResizeUs());
    try testing.expectEqual(@as(u64, 19_000), st.meanLayoutUs());
    try testing.expectEqual(@as(u64, 15_000), st.meanPlaceUs());
    try testing.expectEqual(@as(u64, 200), st.meanPaintUs());

    try testing.expectEqual(@as(u64, 2), st.ticks);
    try testing.expectEqual(@as(u64, 20_000), st.meanUs());
    try testing.expectEqual(@as(u64, 30_000), st.max_us);
    try testing.expectEqual(@as(u64, 18_000), st.meanWaitUs());
    try testing.expectEqual(@as(u64, 1), st.over_budget);
    try testing.expectEqual(@as(usize, 4), st.panes_max);
    try testing.expectEqual(@as(u64, 50), st.fps());
    try testing.expectEqual(Verdict.steppy, st.verdict());

    // A drag that stays inside the frame budget reads smooth, and the batched
    // shape waits once no matter how many panes moved.
    var fast: Stats = .{};
    fast.record(.{ .tick_us = 4_000, .panes = 8, .waits = 1, .resizes = 8 });
    // The batched shape's whole claim, in the units the log line reports.
    try testing.expectEqual(@as(u64, 0), fast.meanWaitUs());
    try testing.expectEqual(@as(usize, 1), fast.waits_max);
    try testing.expectEqual(Verdict.smooth, fast.verdict());
    try testing.expectEqual(@as(u64, 250), fast.fps());
    try testing.expectEqual(@as(u64, 0), fast.over_budget);

    fast.reset();
    try testing.expectEqual(@as(u64, 0), fast.ticks);
    try testing.expectEqual(Verdict.no_data, fast.verdict());
}
