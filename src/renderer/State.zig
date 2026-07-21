//! This is the render state that is given to a renderer.

const State = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Thread.Mutex,

/// Fairness ticket for `mutex` (T114/T115). Counts the threads that are
/// currently BLOCKED in `lockPriority` — i.e. latency-sensitive waiters (the
/// renderer thread's frame update, GUI-thread input, an IPC `+read`) as
/// opposed to a background bulk producer feeding terminal output.
///
/// `std.Thread.Mutex` is a futex with no fairness promise, and that is fine
/// for every lock in the app EXCEPT this one, where a producer re-takes the
/// lock in a tight loop: it unlocks, bumps a slice pointer, and re-locks in
/// nanoseconds, so a just-woken waiter loses race after race. Measured on the
/// agent data path under a storm: the renderer thread waited **65392 ms** for
/// one frame (so `+close`'s renderer-thread join blocked the GUI for 33 s —
/// T115) and an IPC `+read` waited 23628 ms to do 45 ms of work (T114). Both
/// are the same defect: ~190 consecutive lost races, not one long hold.
///
/// The producer side calls `yieldToPriorityWaiters` between lock cycles, which
/// simply keeps the mutex UNLOCKED until the waiter gets in (the count drops
/// on acquisition, not release). Bounded, so a stream of waiters can never
/// stall the producer indefinitely.
priority_waiters: std.atomic.Value(u32) = .{ .raw = 0 },

/// The terminal data.
terminal: *terminalpkg.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// How long a bulk producer keeps the mutex free for a priority waiter before
/// it gives up and takes the lock anyway. The handoff normally completes in
/// microseconds — the waiter is already awake on another core and only needs
/// the lock to be free for a moment — and this cap is what keeps a
/// pathological stream of waiters from starving the producer in turn.
///
/// The budget is a DURATION, not a spin count: `SwitchToThread` returns
/// immediately when no peer is runnable on this core, so 512 of them elapse in
/// microseconds and can expire before a waiter on another core is scheduled at
/// all (caught by the unit test below, which is why this is not a spin cap).
const max_handoff_ns = 2 * std.time.ns_per_ms;

/// Lock `mutex` as a latency-sensitive waiter. Identical to `mutex.lock()`
/// except that a bulk producer calling `yieldToPriorityWaiters` will step
/// aside for us instead of winning every race. See `priority_waiters`.
pub fn lockPriority(self: *State) void {
    _ = self.priority_waiters.fetchAdd(1, .acq_rel);
    self.mutex.lock();
    // Decrement on ACQUISITION, not on release: the producer's handoff loop
    // ends the moment we are actually inside, and then blocks on the mutex
    // normally (which is the correct order — we got there first).
    _ = self.priority_waiters.fetchSub(1, .acq_rel);
}

/// Release a `lockPriority`. Only a distinct name for symmetry at call sites;
/// the unlock itself is ordinary.
pub fn unlockPriority(self: *State) void {
    self.mutex.unlock();
}

/// Called by a background bulk producer BETWEEN two lock cycles (i.e. while it
/// holds nothing) to let any priority waiter in first. Returns as soon as the
/// waiters drain, or after a bounded number of yields.
///
/// The producer must not be holding `mutex` here — this is a handoff window,
/// not a lock upgrade.
pub fn yieldToPriorityWaiters(self: *State) void {
    self.yieldToPriorityWaitersFor(max_handoff_ns);
}

/// `yieldToPriorityWaiters` with an explicit time budget, so the bound itself
/// is testable without depending on how fast this machine schedules threads.
fn yieldToPriorityWaitersFor(self: *State, budget_ns: u64) void {
    if (self.priority_waiters.load(.acquire) == 0) {
        // Uncontended: still give up the rest of our slice, which costs
        // nothing when there is no other runnable thread and preserves the
        // pre-existing (T111b) behavior on this path.
        std.Thread.yield() catch {};
        return;
    }

    // No clock: fall back to a bounded spin rather than waiting forever.
    var timer = std.time.Timer.start() catch {
        for (0..512) |_| {
            std.Thread.yield() catch return;
            if (self.priority_waiters.load(.acquire) == 0) return;
        }
        return;
    };

    while (self.priority_waiters.load(.acquire) != 0) {
        std.Thread.yield() catch return;
        if (timer.read() >= budget_ns) return;
    }
}

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

// --- fairness ticket (T114/T115) -------------------------------------------
//
// The starvation these guard against only shows up under a live flood, so the
// on-box proof is `session-persistence.ps1` section E. What IS testable here
// is the protocol the fix rests on: the count must return to zero (a leaked
// waiter would make the producer step aside forever), and the handoff loop
// must be bounded (an unbounded one would trade a starved GUI for a starved
// drain — a worse bug, and an invisible one).

test "priority ticket: lock/unlock leaves no residual waiters" {
    const testing = std.testing;

    var mutex: std.Thread.Mutex = .{};
    var state: State = .{ .mutex = &mutex, .terminal = undefined };
    try testing.expectEqual(@as(u32, 0), state.priority_waiters.load(.acquire));

    state.lockPriority();
    // Decremented on ACQUISITION, so an uncontended holder announces nothing.
    try testing.expectEqual(@as(u32, 0), state.priority_waiters.load(.acquire));
    state.unlockPriority();
    try testing.expectEqual(@as(u32, 0), state.priority_waiters.load(.acquire));

    // Still lockable afterwards (i.e. `unlockPriority` really unlocked).
    try testing.expect(mutex.tryLock());
    mutex.unlock();
}

test "priority ticket: handoff waits for the waiter to get in" {
    const testing = std.testing;

    var mutex: std.Thread.Mutex = .{};
    var state: State = .{ .mutex = &mutex, .terminal = undefined };

    // Stand in for a waiter that has announced itself but not yet acquired.
    state.priority_waiters.store(1, .release);
    const clearer = try std.Thread.spawn(.{}, struct {
        fn f(s: *State) void {
            std.Thread.sleep(2 * std.time.ns_per_ms);
            s.priority_waiters.store(0, .release);
        }
    }.f, .{&state});
    defer clearer.join();

    // Budget generously above the clearer's delay: the property under test is
    // "keeps stepping aside until the waiter is in", not the wall clock.
    state.yieldToPriorityWaitersFor(2 * std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 0), state.priority_waiters.load(.acquire));
}

test "priority ticket: handoff is bounded when waiters never drain" {
    const testing = std.testing;

    var mutex: std.Thread.Mutex = .{};
    var state: State = .{ .mutex = &mutex, .terminal = undefined };

    // A waiter that never acquires (nobody clears it). The producer must give
    // up and get on with its work rather than step aside forever — otherwise
    // this fix would just move the starvation onto the drain.
    state.priority_waiters.store(1, .release);
    var timer = try std.time.Timer.start();
    state.yieldToPriorityWaitersFor(std.time.ns_per_ms);
    const waited = timer.read();
    try testing.expectEqual(@as(u32, 1), state.priority_waiters.load(.acquire));
    // Loose upper bound: proves it returned on the budget, not on a spin count
    // that could have expired in microseconds (or worse, never).
    try testing.expect(waited < std.time.ns_per_s);

    // And the mutex is still free for us to take — the handoff window never
    // holds the lock.
    try testing.expect(mutex.tryLock());
    mutex.unlock();
}

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}
