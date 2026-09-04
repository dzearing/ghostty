//! T412: what one session-layout sync COST, and whether that cost is worth
//! saying out loud.
//!
//! `App.syncSessionLayout` runs entirely on the UI thread, and since T109 the
//! capture half of it takes each pane's renderer mutex to dump up to 600 rows of
//! structured VT. Two of its triggers are not rare: a window drag or a
//! maximize/restore writes it synchronously at the end of the gesture (T220),
//! and the T922 refresh writes it up to every two seconds while panes are
//! printing. Nothing measured said whether either was affordable, and a cost
//! paid on the UI thread that nobody measures is how a terminal acquires a
//! stutter that no single change is to blame for.
//!
//! So every sync now records a `Sample`, and this module owns the two judgement
//! calls that sit on top of it — what the total is, and whether it crossed the
//! frame budget — so they are asserted in a test lane rather than only ever
//! observed by watching a window drag. The caller owns the clock and the log.
//!
//! Same split as `layout_refresh.zig` beside it: pure arithmetic here, the
//! Windows-facing half in `App.zig`.

const std = @import("std");
const testing = std.testing;

/// One display frame at 60 Hz, in microseconds.
///
/// The budget is a frame rather than a round number because that is the unit
/// the cost is actually spent in: `syncSessionLayout` blocks the message pump,
/// so a sync that fits inside one frame cannot produce a dropped frame no
/// matter when it lands, and one that does not is visible as a hitch at the end
/// of the gesture that triggered it.
pub const frame_budget_us: u64 = 16_667;

/// The measured cost of one `App.syncSessionLayout`, in the three parts that
/// can move independently.
///
/// `capture_us` is the interesting one: it is the part that scales with the
/// pane count and takes the renderer mutexes. `write_us` is the serialize +
/// atomic file replace, which scales with the manifest's size but not with how
/// busy the panes are. `push_us` is the agent blob mirror, which enqueues
/// without waiting (`setLayoutNoWait`) and should therefore stay small — a
/// large one means the non-blocking promise in `pushLayoutBlobs` has quietly
/// stopped being true.
pub const Sample = struct {
    capture_us: u64 = 0,
    write_us: u64 = 0,
    push_us: u64 = 0,
    /// Terminal + viewer leaves visited by this capture.
    panes: usize = 0,
    /// Base64'd screen-snapshot bytes this capture spent (`SnapshotBudget.used`).
    snapshot_bytes: usize = 0,
    /// False ⇒ the manifest serialized to the bytes already on disk, so
    /// `writeIfChanged` did no file I/O. The capture was still paid for.
    wrote: bool = false,
    /// Whether this capture re-dumped the panes' screens or carried the last
    /// ones forward. Recorded because it is the single biggest determinant of
    /// what the sample says, so a cost line read without it is unreadable.
    fresh_screens: bool = false,

    pub fn totalUs(self: Sample) u64 {
        return self.capture_us + self.write_us + self.push_us;
    }

    /// True ⇒ this sync could not fit in a display frame, so the gesture that
    /// triggered it was observably delayed. This is the condition that earns a
    /// line in the release log; everything else is debug-only, because a sync
    /// happens often enough that logging all of them would be its own defect
    /// (T410 bounded that file for a reason).
    pub fn overBudget(self: Sample) bool {
        return self.totalUs() > frame_budget_us;
    }
};

test "an empty sample costs nothing and is under budget" {
    const s: Sample = .{};
    try testing.expectEqual(@as(u64, 0), s.totalUs());
    try testing.expect(!s.overBudget());
}

test "the total is the three parts" {
    const s: Sample = .{ .capture_us = 100, .write_us = 20, .push_us = 3 };
    try testing.expectEqual(@as(u64, 123), s.totalUs());
}

test "the budget is one frame, exclusive" {
    // Exactly a frame is not over it: the boundary case must not report a
    // hitch that did not happen.
    try testing.expect(!(Sample{ .capture_us = frame_budget_us }).overBudget());
    try testing.expect((Sample{ .capture_us = frame_budget_us + 1 }).overBudget());
}

test "a cheap capture plus a slow write is still over budget" {
    // The parts are summed rather than judged individually, because what the
    // user feels is the message pump being blocked, not which half blocked it.
    const s: Sample = .{ .capture_us = 9_000, .write_us = 9_000 };
    try testing.expect(s.overBudget());
}
