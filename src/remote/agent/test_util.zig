//! Shared helpers for the agent's test suites (imported only from test code).

const std = @import("std");

/// Poll `pred(args...)` until it returns true or a wall-clock deadline expires;
/// returns whether the predicate ever held.
///
/// Cross-thread test waits must be deadlines, never iteration counts: 10k
/// `Thread.yield()`s is a duration only when the scheduler cooperates. On a
/// loaded box every yield returns almost immediately, so a fixed spin budget
/// can burn through before the watched thread has run once — which is how the
/// test-agent floor lane went red under a concurrent `zig build` (T346).
///
/// The deadline is deliberately generous: it is a liveness bound, not a
/// performance assertion, so it only fires when the awaited effect NEVER
/// happens — and a busy box must not be able to spend it. 10s proved
/// spendable: with acceptance scripts saturating the box, a lane timed this
/// wait out and (the bool being discarded) panicked on a null instead of
/// failing red (T183) — hence 60s. A predicate that errors counts as "not
/// yet", and callers must `try testing.expect(waitUntil(...))` rather than
/// discard the bool, so a timeout fails AT the wait, named, instead of
/// falling through to a later `.?` panic.
pub fn waitUntil(comptime pred: anytype, args: anytype) bool {
    const deadline_ns: u64 = 60 * std.time.ns_per_s;
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        const r = @call(.auto, pred, args);
        const ok = if (comptime @typeInfo(@TypeOf(r)) == .error_union)
            (r catch false)
        else
            r;
        if (ok) return true;
        if (timer.read() >= deadline_ns) return false;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}
