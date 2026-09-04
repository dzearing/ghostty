//! Shared helpers for cross-thread TEST waits (imported only from test code).
//!
//! This is the T346/T258 discipline, hoisted out of the agent lane (T498) so
//! every lane can use it: the two `zig build test` lanes analyze this file via
//! the remote modules' test sections, and the agent test binaries (both rooted
//! at `src/`) reach it through `agent/test_util.zig`'s re-export.
//!
//! The rules these helpers encode:
//! - A cross-thread test wait is a WALL-CLOCK deadline, never an iteration
//!   count: 10k `Thread.yield()`s is a duration only when the scheduler
//!   cooperates, and on a loaded box a spin budget burns through before the
//!   watched thread has run once (T346).
//! - The deadline is a LIVENESS bound, not a performance assertion: generous
//!   enough that a busy box cannot spend it, so it only fires when the awaited
//!   effect NEVER happens. 10s proved spendable under acceptance-script load
//!   (T183) — hence 60s.
//! - A wait that cannot time out is a wedge waiting to happen: the T258 hang
//!   was a test blocked ~11 minutes in an untimed wait with no failure text.
//!   Bounding the wait turns the wedge into a red assert that names the test.
//! - A wait that times out SAYS WHAT IT WAS WAITING FOR (T436). Every wait
//!   carries a plain-words label and prints it, with the elapsed time, when it
//!   gives up: `expected true, found false` names neither the condition nor
//!   the minute the lane just spent on it.

const std = @import("std");

/// The shared liveness bound for every test wait: how long an awaited
/// cross-thread effect may take before the test calls it a hang.
pub const liveness_ns: u64 = 60 * std.time.ns_per_s;

/// Poll `pred(args...)` until it returns true or the liveness deadline
/// expires; returns whether the predicate ever held.
///
/// A predicate that errors counts as "not yet", and callers must
/// `try testing.expect(waitUntil(...))` rather than discard the bool, so a
/// timeout fails AT the wait, named, instead of falling through to a later
/// `.?` panic (T183).
///
/// `what` names the condition in plain words ("the session left the store").
/// A timeout PRINTS it along with how long it waited (T436): the bool alone
/// reaches the caller as `expected true, found false`, which says neither what
/// the test was waiting for nor that it waited a full minute for it.
pub fn waitUntil(comptime what: []const u8, comptime pred: anytype, args: anytype) bool {
    return waitUntilFor(what, liveness_ns, pred, args);
}

/// `waitUntil` with an explicit deadline. Only the shared `liveness_ns` bound
/// belongs in a test body — this exists so the timeout path itself is testable
/// without spending that bound.
pub fn waitUntilFor(
    comptime what: []const u8,
    deadline_ns: u64,
    comptime pred: anytype,
    args: anytype,
) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        const r = @call(.auto, pred, args);
        const ok = if (comptime @typeInfo(@TypeOf(r)) == .error_union)
            (r catch false)
        else
            r;
        if (ok) return true;
        const waited = timer.read();
        if (waited >= deadline_ns) {
            std.debug.print(
                "\nwaitUntil TIMEOUT after {d} ms waiting for: {s}\n",
                .{ waited / std.time.ns_per_ms, what },
            );
            return false;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Wait on a `ResetEvent` another thread will set, bounded by the liveness
/// deadline. Use this in test bodies instead of the untimed `.wait()`, whose
/// failure mode is the T258 wedge (a lane hung with no failure text).
pub fn waitEvent(ev: *std.Thread.ResetEvent) error{Timeout}!void {
    ev.timedWait(liveness_ns) catch return error.Timeout;
}

/// Drain a pane ring (`inbound_ring.Channel`-shaped: `pop` returns a struct
/// with a `read` count) until `want` bytes have accumulated into `buf`, or
/// the liveness deadline expires with no progress. Returns the total byte
/// count collected. The deadline resets on progress: it bounds a STALL, not
/// the whole transfer, so a slow loaded box cannot spend it while bytes are
/// still flowing.
pub fn drainRing(ring: anytype, buf: []u8, want: usize) error{Timeout}!usize {
    var total: usize = 0;
    var timer = std.time.Timer.start() catch unreachable;
    while (total < want) {
        const r = ring.pop(buf[total..]);
        if (r.read > 0) {
            total += r.read;
            timer.reset();
            continue;
        }
        if (timer.read() >= liveness_ns) return error.Timeout;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return total;
}

test "waitUntil: an already-true predicate returns immediately" {
    const Pred = struct {
        fn yes() bool {
            return true;
        }
    };
    try std.testing.expect(waitUntil("the predicate that is already true", Pred.yes, .{}));
}

test "waitUntil: a predicate that never holds gives up at the deadline" {
    const Pred = struct {
        fn no() bool {
            return false;
        }
    };
    var timer = std.time.Timer.start() catch unreachable;
    // Prints the "waitUntil TIMEOUT after N ms waiting for: ..." line this
    // test cannot capture; what it asserts is the giving-up itself, bounded,
    // rather than spinning to the 60s liveness deadline.
    try std.testing.expect(!waitUntilFor("the deliberately unsatisfiable condition in test_util's own timeout test", 5 * std.time.ns_per_ms, Pred.no, .{}));
    try std.testing.expect(timer.read() >= 5 * std.time.ns_per_ms);
}

test "waitEvent: a pre-set event returns without waiting; args pass through" {
    var ev: std.Thread.ResetEvent = .{};
    ev.set();
    try waitEvent(&ev);
}

test "drainRing: bytes already present are collected without waiting" {
    // A minimal ring stand-in with the `pop -> .{ .read }` shape.
    const FakeRing = struct {
        data: []const u8,
        off: usize = 0,
        const Res = struct { read: usize };
        fn pop(self: *@This(), dst: []u8) Res {
            const n = @min(dst.len, self.data.len - self.off);
            @memcpy(dst[0..n], self.data[self.off..][0..n]);
            self.off += n;
            return .{ .read = n };
        }
    };
    var ring = FakeRing{ .data = "ping" };
    var buf: [8]u8 = undefined;
    const total = try drainRing(&ring, &buf, 4);
    try std.testing.expectEqualStrings("ping", buf[0..total]);
}
