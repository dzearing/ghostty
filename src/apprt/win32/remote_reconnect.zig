//! Per-window remote reconnect ladder — the DECISIONS (T365, WP-D1 spec §5.1).
//!
//! When the agent behind a cross-machine window dies, win32 today degrades to a
//! clean dead pane: no hang, no crash, and no way back. The Mac has the full
//! WP-D1 ladder (`BaseTerminalController.swift`, `MARK: Remote Reconnect`):
//! drop → bounded redial with backoff → re-ATTACH by session id → live again,
//! with a coloured pill saying which of those is happening.
//!
//! That Mac code is ~400 lines welded to AppKit notifications, dispatch queues
//! and the surface tree. Porting it wholesale into `Window.zig` (already 5.6k
//! lines) would be a mega file and untestable off-box, so the policy comes out
//! first — the same split `agent_recovery.zig` makes for local in-place
//! recovery. Everything here is pure: no sockets, no threads, no wall clock
//! except the `now_ms` the caller passes in. The moving half is T366.
//!
//! Three decisions carry the ladder, and each exists because getting it wrong
//! was observed on the Mac:
//!
//!  1. **What counts as a drop.** `degraded` is a live link with missed
//!     heartbeats, not a disconnect (§5.1: any authentic packet returns it to
//!     `connected`), and a self-healable `disconnected` window must come back
//!     on a genuine link-up — its surfaces still ride that same connection, so
//!     a frozen agent thawing means the window works again.
//!  2. **When to stop.** The fast ladder is five attempts (~30s). Exhausting it
//!     is NOT terminal: the window is kept, the state is truthfully
//!     self-healable, and a slow background re-dial keeps trying. Terminal is
//!     reserved for verdicts retrying cannot change — session gone, evicted,
//!     signed out.
//!  3. **When the session itself is the problem.** A stale session can probe
//!     ALIVE and then kill the link on every ATTACH; the observed shape was
//!     dial → probe → swap → die every ~2.4s, forever. The breaker counts
//!     swaps that die inside `poison_window_ms` and stops the fast ladder at
//!     `poison_limit`.
//!
//! Local-agent (session-persistence) windows are explicitly NOT this ladder's
//! business — they recover through `agent_recovery.zig`, which re-dials once
//! for every window and rebuilds each split tree in place. Mac excludes them
//! the same way (`connection.machine.isLocalMachine`).

const std = @import("std");
const connection = @import("../../remote/connection.zig");

// =============================================================================
// Schedule
// =============================================================================

/// Backoff before each fast-ladder attempt, 1-based (attempt 1 waits
/// `delays_ms[0]`). ~30s across five attempts — Mac's `remoteReconnectDelays`.
/// The transport FSM's own full-jitter schedule (`LinkState.nextBackoffMs`)
/// is not reused here: that one protects a fleet from thundering-herd, and a
/// single GUI client retrying one host has no herd to protect.
pub const delays_ms = [_]u64{ 1_000, 2_000, 4_000, 8_000, 15_000 };

/// Fast-ladder budget. One attempt per delay.
pub const max_attempts: u32 = delays_ms.len;

/// Cadence of the slow background re-dial that runs after the fast ladder is
/// exhausted (window kept, red pill), until the window closes, the link
/// self-heals, a probe succeeds, or the session is confirmed gone.
pub const redial_interval_ms: u64 = 45_000;

/// A post-swap link death inside this window counts as a quick-death cycle for
/// the poisoned-session breaker. Well above the observed ~300ms death, and
/// short enough that a swap which survives it is a genuine recovery.
pub const poison_window_ms: i64 = 10_000;

/// Consecutive quick deaths that condemn the session and stop the fast ladder.
pub const poison_limit: u32 = 3;

/// Backoff before `attempt` (1-based). `immediate` skips only the FIRST wait —
/// a user clicking Reconnect should dial now, but the retries behind that click
/// still pace themselves. Attempts past the schedule reuse its last delay
/// rather than reading out of bounds; `retriesExhausted` is what ends the
/// ladder, and this must not be a second, disagreeing opinion about that.
pub fn backoffMs(attempt: u32, immediate: bool) u64 {
    if (immediate and attempt <= 1) return 0;
    const idx = @min(@max(attempt, 1), max_attempts) - 1;
    return delays_ms[idx];
}

/// True once the fast ladder's budget is spent. `attempt` is the 1-based
/// attempt that just failed.
pub fn retriesExhausted(attempt: u32) bool {
    return attempt >= max_attempts;
}

// =============================================================================
// Window state
// =============================================================================

/// This window's connection status — the ladder's output, and what the T367
/// status pill paints. Distinct from the transport's `LinkState.State`: the
/// transport describes one socket, this describes the window across the
/// socket's replacement.
pub const WindowState = union(enum) {
    /// Live. The pill is green.
    connected,

    /// A drop was seen and the fast ladder is running; `attempt` is 1-based and
    /// is what the yellow pill counts out.
    reconnecting: struct { attempt: u32 },

    /// Not live. `self_healable` is the difference between "we ran out of fast
    /// attempts, the link may still come back" (red, background re-dial armed)
    /// and a terminal verdict (red, user action required). It is a field rather
    /// than two cases because the pill treats them identically and only the
    /// recovery paths care.
    disconnected: struct { self_healable: bool },

    pub fn isConnected(self: WindowState) bool {
        return self == .connected;
    }
};

/// How a transport state reads to the ladder. Collapsing five FSM states to
/// three is the point: `connected`/`degraded` are both live (see §5.1), and
/// `reconnecting`/`reattaching` are both "the socket is gone, go get another".
pub const LinkClass = enum { live, dropped, terminal };

pub fn classify(state: connection.LinkState.State) LinkClass {
    return switch (state) {
        .connected, .degraded => .live,
        .reconnecting, .reattaching => .dropped,
        .dead => .terminal,
    };
}

/// What a link-state change means for the window.
pub const LinkAction = enum {
    /// Nothing to do (already in the right state).
    none,
    /// Back to `connected`: cancel any in-flight ladder and reset the breaker.
    recovered,
    /// Start the fast ladder (subject to `beginReconnect`).
    begin_reconnect,
    /// Evicted (§5.3) or the session is gone: keep the window, mark it, stop.
    go_terminal,
};

/// Map a link-state change onto the window ladder. `state` is the window's
/// CURRENT state; `link` is what the transport now reads as.
pub fn onLinkChange(state: WindowState, link: LinkClass) LinkAction {
    return switch (link) {
        .live => switch (state) {
            // The link came back on its own: a heartbeat blip, or a frozen
            // agent thawing after the ladder gave up. Either way the surfaces
            // ride this connection, so the window works again.
            .reconnecting => .recovered,
            .disconnected => |d| if (d.self_healable) .recovered else .none,
            .connected => .none,
        },
        // Only a live window starts a ladder. A window already reconnecting has
        // one running (its generation owns the retries), and a disconnected one
        // is either waiting on the slow re-dial or terminal.
        .dropped => if (state.isConnected()) .begin_reconnect else .none,
        // Unconditional: `dead` is terminal from any state.
        .terminal => .go_terminal,
    };
}

// =============================================================================
// Poisoned-session breaker
// =============================================================================

/// Detects a session that probes alive and then kills every link ATTACHed to
/// it. Owned by the window; judged once per swap.
pub const Breaker = struct {
    /// Consecutive swaps that completed and then died inside the window.
    quick_deaths: u32 = 0,
    /// When the most recent swap completed, if one is still awaiting judgment.
    swap_completed_at_ms: ?i64 = null,

    /// A reconnect swap just completed. It is not judged yet — whether it was a
    /// recovery or another quick death is only knowable if/when its link dies.
    pub fn onSwapCompleted(self: *Breaker, now_ms: i64) void {
        self.swap_completed_at_ms = now_ms;
    }

    /// A genuine link recovery (no swap involved): unrelated future wobbles
    /// start from a clean slate.
    pub fn reset(self: *Breaker) void {
        self.quick_deaths = 0;
        self.swap_completed_at_ms = null;
    }

    /// Judge the pending swap, if any, as a new ladder is about to start.
    /// Returns true when the session is condemned — stop the fast ladder and go
    /// terminal. Each swap is judged at most once, so a single completion can
    /// never be counted twice by two drops.
    pub fn judge(self: *Breaker, now_ms: i64) bool {
        if (self.swap_completed_at_ms) |at| {
            self.swap_completed_at_ms = null;
            if (now_ms -| at < poison_window_ms) {
                self.quick_deaths += 1;
            } else {
                self.quick_deaths = 0;
            }
        }
        if (self.quick_deaths >= poison_limit) {
            self.quick_deaths = 0;
            return true;
        }
        return false;
    }
};

// =============================================================================
// Ladder entry
// =============================================================================

/// What `beginReconnect` decided.
pub const BeginDecision = union(enum) {
    /// Not a live window (a ladder is already running, or it is already down).
    ignore,
    /// Nothing to re-ATTACH to: the session id never resolved. Terminal — a
    /// dial with no target cannot bring this window back.
    terminal_no_session,
    /// The breaker condemned the session.
    terminal_poisoned,
    /// Run the ladder from this 1-based attempt.
    start: struct { attempt: u32 },
};

/// Decide whether a drop starts a ladder. `poisoned` is `Breaker.judge`'s
/// verdict — taken by the caller so this stays pure and the breaker is
/// advanced exactly once per drop.
pub fn beginReconnect(state: WindowState, has_session: bool, poisoned: bool) BeginDecision {
    if (!state.isConnected()) return .ignore;
    if (!has_session) return .terminal_no_session;
    if (poisoned) return .terminal_poisoned;
    return .{ .start = .{ .attempt = 1 } };
}

/// A manual reconnect (the T367 pill's button) starts from ANY disconnected
/// tier, terminal included — the user explicitly asked — and dials without
/// waiting out a backoff. It is a no-op on a window that is fine or already
/// retrying. The caller resets the breaker first: a click is fresh evidence.
pub fn beginManualReconnect(state: WindowState) BeginDecision {
    return switch (state) {
        .disconnected => .{ .start = .{ .attempt = 1 } },
        .connected, .reconnecting => .ignore,
    };
}

// =============================================================================
// Attempt outcomes
// =============================================================================

/// The result of one dial + liveness-probe cycle.
pub const ProbeOutcome = enum {
    /// The agent answered and the session is alive (or there was nothing to
    /// probe — a bare dial for the fresh-shell path).
    session_alive,
    /// The agent answered but the session is gone (agent restart, idle-TTL).
    session_gone,
    /// The dial failed: unreachable, handshake timeout, 401.
    unreachable_agent,
    /// Relay machine with no bearer token. Terminal until sign-in.
    signed_out,
};

/// What to do with a probe outcome.
pub const OutcomeAction = union(enum) {
    /// Commit the reconnect onto the freshly dialed connection. `fresh_session`
    /// means re-ATTACH is impossible and this opens a NEW shell instead — only
    /// ever reached from a manual reconnect, because replacing a user's dead
    /// grid with an empty shell is a surprise unless they asked for it.
    swap: struct { fresh_session: bool },
    /// No verdict: treat as a failed attempt and let the ladder retry.
    retry,
    /// Retrying cannot change this. Keep the window, mark it terminal.
    terminal,
};

pub fn onProbeOutcome(outcome: ProbeOutcome, fresh_session_on_gone: bool) OutcomeAction {
    return switch (outcome) {
        .session_alive => .{ .swap = .{ .fresh_session = false } },
        .session_gone => if (fresh_session_on_gone)
            .{ .swap = .{ .fresh_session = true } }
        else
            .terminal,
        .unreachable_agent => .retry,
        .signed_out => .terminal,
    };
}

/// What a failed attempt (unreachable, or a swap that could not build its
/// replacement surface) does next.
pub const FailureAction = union(enum) {
    /// Wait `delay_ms`, then run attempt `attempt`.
    retry: struct { attempt: u32, delay_ms: u64 },
    /// Budget spent. The window is kept and stays self-healable; the slow
    /// background re-dial is armed only when there is a session to re-ATTACH
    /// (a bare re-dial has nothing to come back to).
    exhausted: struct { arm_background_redial: bool },
};

pub fn onAttemptFailed(attempt: u32, has_session: bool) FailureAction {
    if (retriesExhausted(attempt))
        return .{ .exhausted = .{ .arm_background_redial = has_session } };
    return .{ .retry = .{
        .attempt = attempt + 1,
        .delay_ms = backoffMs(attempt + 1, false),
    } };
}

/// The window state a `FailureAction.exhausted` lands in.
pub const exhausted_state: WindowState = .{ .disconnected = .{ .self_healable = true } };

/// The window state every terminal verdict lands in.
pub const terminal_state: WindowState = .{ .disconnected = .{ .self_healable = false } };

// =============================================================================
// Cancellation
// =============================================================================

/// Monotonic generation guarding the retry loop. Every event that invalidates
/// in-flight work — window closed, link recovered, a newer ladder, a manual
/// click — bumps it, and any stage holding a stale value must free what it
/// dialed and return without touching the window. Cancellation cannot be done
/// by a bool: two ladders can overlap, and the older one must lose.
pub const Generation = struct {
    value: u64 = 0,

    pub fn bump(self: *Generation) u64 {
        self.value +%= 1;
        return self.value;
    }

    pub fn isCurrent(self: Generation, gen: u64) bool {
        return self.value == gen;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const S = connection.LinkState.State;

test "classify: degraded is a live link, not a drop" {
    // §5.1: DEGRADED is ~2 missed heartbeats and returns to CONNECTED on any
    // authentic packet. Treating it as a drop would start a ladder on every
    // busy moment.
    try testing.expectEqual(LinkClass.live, classify(.connected));
    try testing.expectEqual(LinkClass.live, classify(.degraded));
    try testing.expectEqual(LinkClass.dropped, classify(.reconnecting));
    try testing.expectEqual(LinkClass.dropped, classify(.reattaching));
    try testing.expectEqual(LinkClass.terminal, classify(.dead));
}

test "classify covers every LinkState state" {
    // A new FSM state must be classified deliberately, not defaulted. This
    // fails to compile (not at runtime) if `classify`'s switch grows an else.
    inline for (@typeInfo(S).@"enum".fields) |f| {
        _ = classify(@field(S, f.name));
    }
}

test "onLinkChange: a drop only starts a ladder from a live window" {
    try testing.expectEqual(LinkAction.begin_reconnect, onLinkChange(.connected, .dropped));
    // A ladder is already running; its generation owns the retries.
    try testing.expectEqual(
        LinkAction.none,
        onLinkChange(.{ .reconnecting = .{ .attempt = 2 } }, .dropped),
    );
    // Down already: either the slow re-dial has it, or it is terminal.
    try testing.expectEqual(
        LinkAction.none,
        onLinkChange(.{ .disconnected = .{ .self_healable = true } }, .dropped),
    );
    try testing.expectEqual(
        LinkAction.none,
        onLinkChange(.{ .disconnected = .{ .self_healable = false } }, .dropped),
    );
}

test "onLinkChange: a live link recovers a reconnecting or self-healable window" {
    try testing.expectEqual(
        LinkAction.recovered,
        onLinkChange(.{ .reconnecting = .{ .attempt = 3 } }, .live),
    );
    // Exhausted-but-self-healable: the surfaces still ride this connection, so
    // a genuine link-up means the window works again (a frozen agent thawed).
    try testing.expectEqual(
        LinkAction.recovered,
        onLinkChange(.{ .disconnected = .{ .self_healable = true } }, .live),
    );
    // Terminal is terminal: the session is gone / we were evicted, so a live
    // socket does not bring the pane's contents back.
    try testing.expectEqual(
        LinkAction.none,
        onLinkChange(.{ .disconnected = .{ .self_healable = false } }, .live),
    );
    try testing.expectEqual(LinkAction.none, onLinkChange(.connected, .live));
    // Degraded is live: a window mid-ladder still recovers on it.
    try testing.expectEqual(
        LinkAction.recovered,
        onLinkChange(.{ .reconnecting = .{ .attempt = 1 } }, classify(.degraded)),
    );
}

test "onLinkChange: dead is terminal from every window state" {
    try testing.expectEqual(LinkAction.go_terminal, onLinkChange(.connected, .terminal));
    try testing.expectEqual(
        LinkAction.go_terminal,
        onLinkChange(.{ .reconnecting = .{ .attempt = 5 } }, .terminal),
    );
    try testing.expectEqual(
        LinkAction.go_terminal,
        onLinkChange(.{ .disconnected = .{ .self_healable = true } }, .terminal),
    );
}

test "backoffMs: the schedule, and what immediate actually skips" {
    try testing.expectEqual(@as(u64, 1_000), backoffMs(1, false));
    try testing.expectEqual(@as(u64, 2_000), backoffMs(2, false));
    try testing.expectEqual(@as(u64, 4_000), backoffMs(3, false));
    try testing.expectEqual(@as(u64, 8_000), backoffMs(4, false));
    try testing.expectEqual(@as(u64, 15_000), backoffMs(5, false));

    // A click dials NOW...
    try testing.expectEqual(@as(u64, 0), backoffMs(1, true));
    // ...but the retries behind it still pace themselves.
    try testing.expectEqual(@as(u64, 2_000), backoffMs(2, true));

    // Out-of-range attempts clamp instead of reading past the schedule.
    try testing.expectEqual(@as(u64, 15_000), backoffMs(99, false));
    try testing.expectEqual(@as(u64, 1_000), backoffMs(0, false));
}

test "the ladder is ~30s across five attempts" {
    // The budget is a promise to the user: a window is not left saying
    // "reconnecting" for minutes before it admits defeat.
    var total: u64 = 0;
    for (delays_ms) |d| total += d;
    try testing.expectEqual(@as(u64, 30_000), total);
    try testing.expectEqual(@as(u32, 5), max_attempts);
}

test "onAttemptFailed: walks the schedule, then keeps the window self-healable" {
    var attempt: u32 = 1;
    var seen: [4]u64 = undefined;
    var i: usize = 0;
    while (true) {
        switch (onAttemptFailed(attempt, true)) {
            .retry => |r| {
                seen[i] = r.delay_ms;
                i += 1;
                attempt = r.attempt;
            },
            .exhausted => |e| {
                try testing.expect(e.arm_background_redial);
                break;
            },
        }
    }
    try testing.expectEqual(@as(usize, 4), i);
    try testing.expectEqualSlices(u64, &.{ 2_000, 4_000, 8_000, 15_000 }, &seen);
    try testing.expectEqual(@as(u32, 5), attempt);

    // Exhaustion is NOT terminal — the transport underneath may still heal.
    try testing.expect(exhausted_state.disconnected.self_healable);
    try testing.expect(!terminal_state.disconnected.self_healable);
}

test "onAttemptFailed: no session means no background re-dial to arm" {
    switch (onAttemptFailed(max_attempts, false)) {
        .exhausted => |e| try testing.expect(!e.arm_background_redial),
        .retry => return error.TestUnexpectedResult,
    }
}

test "onProbeOutcome: only a manual reconnect may open a fresh shell" {
    try testing.expectEqual(
        OutcomeAction{ .swap = .{ .fresh_session = false } },
        onProbeOutcome(.session_alive, false),
    );
    // Automatic ladder, session gone: retrying cannot bring it back, and
    // silently replacing the user's dead grid with an empty shell is not a
    // recovery. Terminal — the pill's button is the way back.
    try testing.expectEqual(OutcomeAction.terminal, onProbeOutcome(.session_gone, false));
    // The user clicked: they asked for this window back.
    try testing.expectEqual(
        OutcomeAction{ .swap = .{ .fresh_session = true } },
        onProbeOutcome(.session_gone, true),
    );
    // Unreachable is the only retryable outcome.
    try testing.expectEqual(OutcomeAction.retry, onProbeOutcome(.unreachable_agent, false));
    try testing.expectEqual(OutcomeAction.retry, onProbeOutcome(.unreachable_agent, true));
    // Signed out: retrying a 401 forever is noise, and a click cannot fix it
    // either — sign-in restores the window.
    try testing.expectEqual(OutcomeAction.terminal, onProbeOutcome(.signed_out, true));
}

test "beginReconnect: guards, in order" {
    try testing.expectEqual(
        BeginDecision{ .start = .{ .attempt = 1 } },
        beginReconnect(.connected, true, false),
    );
    // Already laddering / already down: no second ladder.
    try testing.expectEqual(
        BeginDecision.ignore,
        beginReconnect(.{ .reconnecting = .{ .attempt = 1 } }, true, false),
    );
    try testing.expectEqual(
        BeginDecision.ignore,
        beginReconnect(.{ .disconnected = .{ .self_healable = true } }, true, false),
    );
    // No re-ATTACH target: dialing would succeed and still leave a dead pane.
    try testing.expectEqual(
        BeginDecision.terminal_no_session,
        beginReconnect(.connected, false, false),
    );
    // The missing-session check outranks the breaker, so a condemned session
    // with no id reports the reason the user can act on.
    try testing.expectEqual(
        BeginDecision.terminal_no_session,
        beginReconnect(.connected, false, true),
    );
    try testing.expectEqual(
        BeginDecision.terminal_poisoned,
        beginReconnect(.connected, true, true),
    );
}

test "beginManualReconnect: works from terminal, no-op on a healthy window" {
    try testing.expectEqual(
        BeginDecision{ .start = .{ .attempt = 1 } },
        beginManualReconnect(.{ .disconnected = .{ .self_healable = false } }),
    );
    try testing.expectEqual(
        BeginDecision{ .start = .{ .attempt = 1 } },
        beginManualReconnect(.{ .disconnected = .{ .self_healable = true } }),
    );
    try testing.expectEqual(BeginDecision.ignore, beginManualReconnect(.connected));
    try testing.expectEqual(
        BeginDecision.ignore,
        beginManualReconnect(.{ .reconnecting = .{ .attempt = 2 } }),
    );
}

test "Breaker: three swaps that die fast condemn the session" {
    // The observed shape: dial → probe alive → swap → link dead ~300ms later,
    // looping every ~2.4s forever.
    var b: Breaker = .{};
    var now: i64 = 0;

    try testing.expect(!b.judge(now)); // first drop, nothing swapped yet

    var cycle: u32 = 0;
    while (cycle < 2) : (cycle += 1) {
        b.onSwapCompleted(now);
        now += 300;
        try testing.expect(!b.judge(now));
        now += 2_100;
    }
    // Third quick death trips it.
    b.onSwapCompleted(now);
    now += 300;
    try testing.expect(b.judge(now));
    // ...and the count is cleared, so the next click starts from evidence
    // gathered after it rather than tripping immediately.
    try testing.expectEqual(@as(u32, 0), b.quick_deaths);
}

test "Breaker: a swap that survives the window clears the count" {
    var b: Breaker = .{};
    var now: i64 = 0;
    b.onSwapCompleted(now);
    now += 300;
    try testing.expect(!b.judge(now));
    b.onSwapCompleted(now);
    now += 300;
    try testing.expect(!b.judge(now));
    try testing.expectEqual(@as(u32, 2), b.quick_deaths);

    // A swap whose link lasted longer than the window is a genuine recovery.
    b.onSwapCompleted(now);
    now += poison_window_ms + 1;
    try testing.expect(!b.judge(now));
    try testing.expectEqual(@as(u32, 0), b.quick_deaths);
}

test "Breaker: each swap is judged at most once" {
    // Two drops arriving for one completed swap must not count twice, or a
    // chatty link condemns a healthy session in a third of the evidence.
    var b: Breaker = .{};
    b.onSwapCompleted(0);
    try testing.expect(!b.judge(100));
    try testing.expectEqual(@as(u32, 1), b.quick_deaths);
    try testing.expect(!b.judge(200));
    try testing.expectEqual(@as(u32, 1), b.quick_deaths);
}

test "Breaker: a genuine link recovery resets it" {
    var b: Breaker = .{};
    b.onSwapCompleted(0);
    try testing.expect(!b.judge(100));
    b.onSwapCompleted(200);
    b.reset();
    try testing.expectEqual(@as(u32, 0), b.quick_deaths);
    try testing.expectEqual(@as(?i64, null), b.swap_completed_at_ms);
    // Post-reset the breaker judges only new evidence.
    b.onSwapCompleted(300);
    try testing.expect(!b.judge(400));
    try testing.expectEqual(@as(u32, 1), b.quick_deaths);
}

test "Breaker: a clock that goes backwards is not a quick death storm" {
    // now_ms is whatever the caller's monotonic source says; a non-monotonic
    // one must not saturate-underflow into a huge elapsed time.
    var b: Breaker = .{};
    b.onSwapCompleted(5_000);
    try testing.expect(!b.judge(4_000)); // 0 elapsed, counts as quick
    try testing.expectEqual(@as(u32, 1), b.quick_deaths);
}

test "Generation: only the newest ladder is current" {
    var g: Generation = .{};
    const first = g.bump();
    try testing.expect(g.isCurrent(first));
    const second = g.bump();
    try testing.expect(g.isCurrent(second));
    // The older ladder loses; every stage it reaches must no-op.
    try testing.expect(!g.isCurrent(first));
    try testing.expect(!g.isCurrent(0));
}

test "a full drop-to-recovery pass" {
    // The happy path the ladder exists for: link drops, attempt 2 finds the
    // agent, the swap re-ATTACHes, and the window is live again.
    var state: WindowState = .connected;
    var breaker: Breaker = .{};
    var gen: Generation = .{};
    var now: i64 = 0;

    try testing.expectEqual(LinkAction.begin_reconnect, onLinkChange(state, classify(.reconnecting)));
    switch (beginReconnect(state, true, breaker.judge(now))) {
        .start => |s| state = .{ .reconnecting = .{ .attempt = s.attempt } },
        else => return error.TestUnexpectedResult,
    }
    _ = gen.bump();
    try testing.expectEqual(@as(u32, 1), state.reconnecting.attempt);

    // Attempt 1: agent unreachable.
    switch (onProbeOutcome(.unreachable_agent, false)) {
        .retry => {},
        else => return error.TestUnexpectedResult,
    }
    switch (onAttemptFailed(state.reconnecting.attempt, true)) {
        .retry => |r| {
            now += @intCast(r.delay_ms);
            state = .{ .reconnecting = .{ .attempt = r.attempt } };
        },
        .exhausted => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 2), state.reconnecting.attempt);

    // Attempt 2: alive. Swap, and the link reads live again.
    switch (onProbeOutcome(.session_alive, false)) {
        .swap => |s| try testing.expect(!s.fresh_session),
        else => return error.TestUnexpectedResult,
    }
    breaker.onSwapCompleted(now);
    try testing.expectEqual(LinkAction.recovered, onLinkChange(state, classify(.connected)));
    state = .connected;
    breaker.reset();
    try testing.expectEqual(@as(u32, 0), breaker.quick_deaths);
}

test "a full drop-to-exhaustion pass keeps the window self-healable" {
    var state: WindowState = .connected;
    var breaker: Breaker = .{};

    switch (beginReconnect(state, true, breaker.judge(0))) {
        .start => |s| state = .{ .reconnecting = .{ .attempt = s.attempt } },
        else => return error.TestUnexpectedResult,
    }
    while (true) {
        switch (onAttemptFailed(state.reconnecting.attempt, true)) {
            .retry => |r| state = .{ .reconnecting = .{ .attempt = r.attempt } },
            .exhausted => |e| {
                try testing.expect(e.arm_background_redial);
                state = exhausted_state;
                break;
            },
        }
    }
    try testing.expect(!state.isConnected());
    try testing.expect(state.disconnected.self_healable);
    // The agent thaws minutes later: the window comes back with no click.
    try testing.expectEqual(LinkAction.recovered, onLinkChange(state, classify(.connected)));
}
