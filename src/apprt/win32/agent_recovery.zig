//! In-place local-agent crash recovery policy (T145) — the win32 port of the
//! Mac `LocalAgentManager.SharedLinkDropVerdict` / `SessionCloseIntentPolicy`
//! pair (`03f0f1f30` + `e65cfa4d5`).
//!
//! When the local `ghoztty-agent` dies while the GUI stays up, every persistent
//! pane is frozen: its PTY went with the agent and the app's shared connection
//! is a dead pointer. Recovery re-dials (spawning a fresh agent if needed) and
//! rebuilds each local-agent window's split topology in place — no app relaunch.
//! The mechanism lives in `App.zig`; the DECISIONS live here, pure, so they are
//! unit-testable in both app-runtime lanes without a live agent.
//!
//! Two decisions, and both exist because getting them wrong is destructive:
//!
//!  1. **When is a dropped link real?** Recovery replaces every local window's
//!     surface tree, so it must never run on a blip. The Mac shipped this
//!     without a settle window and the 2026-07-21 incident (`e65cfa4d5`) had
//!     in-place recovery destroying the sessions it had just re-attached, fired
//!     by a link that healed 27ms later. The transport FSM
//!     (`remote/connection.zig` §5.1) enters `reconnecting` after three missed
//!     heartbeats and returns to `connected` on the very next authentic packet,
//!     so a down edge is NOT proof of death — only a link that STAYS down
//!     through `settle_ms` is.
//!  2. **Whose session may be ended?** The swap replaces live surfaces with
//!     fresh ones that re-ATTACH the SAME agent sessions. A departing leaf is
//!     therefore not a user close, and marking it close-intent would terminate
//!     the child of a session an on-screen pane is using. The invariant is
//!     stated in terms of session ids (`sessionSpared`), not in terms of "is
//!     this a swap?", so it holds for any future tree-replacing caller.
//!  3. **Which LEAVES does recovery touch at all?** Only the ones that rode the
//!     dropped connection (`rebuildsLeaf`), and only while the live tree still
//!     matches what was captured from it (`shapesCorrespond`).

const std = @import("std");
const connection = @import("../../remote/connection.zig");

/// How long the shared link must stay down before a drop counts as real.
/// Sized past one full `heartbeat_interval_ms` (3s) so a link that only heals
/// on its next heartbeat round-trip still gets to, plus margin. A truly dead
/// agent leaves those panes frozen either way, so waiting to be sure costs
/// nothing that was not already lost.
pub const settle_ms: i64 = 5000;

/// How often the link is sampled — both while healthy (cheap: one atomic read
/// of the FSM state) and during a settle window.
pub const poll_ms: u32 = 250;

/// Backoff schedule for RE-TRYING a recovery that aborted because no agent
/// could be re-dialed (T723). One entry per retry, in order; running off the end
/// is the give-up point.
///
/// Why a retry is needed at all: the settle watch only opens on a link DOWN
/// EDGE, and `Connection` fires its observer only when the state actually
/// CHANGES. Once the shared link is `reconnecting` the sole remaining transition
/// is to `dead`, which only a server-sent DETACHED frame produces — and a wedged
/// or killed agent never sends one. So the abort was terminal: no second edge
/// ever arrived, nothing re-armed the watch, and the panes stayed frozen until
/// the user relaunched the app. The exact failure in-place recovery exists to
/// remove.
///
/// The shape is short-then-patient: a wedged agent that is going to come back
/// usually does so in seconds (a swapped-out process, a disk stall), and a dead
/// one needs only enough time for a fresh agent to be spawnable. Past ~90s the
/// cause is not transient and re-dialing forever is noise, so we stop and SAY
/// so — a silent frozen pane is the thing being fixed, and an infinite quiet
/// retry loop is only a slower version of it.
pub const retry_delays_ms = [_]u32{ 2_000, 4_000, 8_000, 15_000, 30_000, 30_000 };

/// The delay before retry number `attempts_made` (0-based), or null once the
/// schedule is spent.
pub fn retryDelayMs(attempts_made: usize) ?u32 {
    if (attempts_made >= retry_delays_ms.len) return null;
    return retry_delays_ms[attempts_made];
}

/// What a retry tick should do.
pub const RetryVerdict = enum {
    /// Re-run in-place recovery now.
    retry,
    /// The old link came back on its own while we were waiting. Nothing to do:
    /// the panes were never rebuilt, so they are still riding the very
    /// connection that just healed, and their sessions are the agent's own.
    link_recovered,
    /// There is no shared connection to recover — a racing re-dial replaced it,
    /// or the app is tearing down. Stand down.
    no_owner,
    /// The schedule is spent. Give up and tell the user.
    exhausted,
};

/// Decide one retry tick. `state` is the CURRENT shared link state (null when
/// there is no shared connection at all) and `attempts_made` counts the retries
/// already run.
pub fn evaluateRetry(
    state: ?connection.LinkState.State,
    attempts_made: usize,
) RetryVerdict {
    const s = state orelse return .no_owner;
    if (!isDown(s)) return .link_recovered;
    if (retryDelayMs(attempts_made) == null) return .exhausted;
    return .retry;
}

/// Whether a transport state counts as DOWN (Mac `LinkState.isDown`).
/// `degraded` is a live link with missed heartbeats, not a drop.
pub fn isDown(state: connection.LinkState.State) bool {
    return switch (state) {
        .connected, .degraded => false,
        .reconnecting, .reattaching, .dead => true,
    };
}

/// What a down shared link means once re-checked.
pub const Verdict = union(enum) {
    /// The link came back on its own. Do nothing at all.
    link_recovered,

    /// A different shared connection has been installed meanwhile (a racing
    /// re-dial), so this owner is nobody's transport now. Do nothing.
    owner_replaced,

    /// Still down, but the settle window has not elapsed. Keep watching.
    keep_watching,

    /// Still down after the settle window, and the agent we were talking to is
    /// no longer the agent on disk (it restarted, or it is gone). `current_pid`
    /// is null when no live agent could be found at all.
    agent_restarted: struct { previous_pid: i64, current_pid: ?i64 },

    /// Still down after the settle window, but the SAME agent process is alive:
    /// the transport failed, not the agent. Rebuilding is still the cure
    /// (re-dial + re-ATTACH), but nothing here restarted — saying so in the log
    /// is what made the 2026-07-21 incident hard to diagnose.
    transport_down: struct { pid: i64 },

    /// Whether this verdict means "rebuild the local windows in place".
    pub fn triggersRecovery(self: Verdict) bool {
        return switch (self) {
            .agent_restarted, .transport_down => true,
            .link_recovered, .owner_replaced, .keep_watching => false,
        };
    }
};

/// Decide what a down shared link means. `settle_remaining_ms` is the settle
/// time left AFTER this check; `live_agent_pid` is the pid recorded in the
/// agent's info file (null when no live agent is there) and is only consulted
/// once the window has elapsed — the caller must not pay for that read on every
/// tick.
pub fn evaluate(
    state: connection.LinkState.State,
    owner_is_current_shared: bool,
    settle_remaining_ms: i64,
    previous_agent_pid: i64,
    live_agent_pid: ?i64,
) Verdict {
    if (!owner_is_current_shared) return .owner_replaced;
    if (!isDown(state)) return .link_recovered;
    if (settle_remaining_ms > 0) return .keep_watching;
    if (live_agent_pid) |live| {
        if (previous_agent_pid > 0 and live == previous_agent_pid)
            return .{ .transport_down = .{ .pid = live } };
    }
    return .{ .agent_restarted = .{
        .previous_pid = previous_agent_pid,
        .current_pid = live_agent_pid,
    } };
}

/// Whether a DEPARTING leaf's agent session must be spared — i.e. left with its
/// default DETACH (keep-alive) teardown rather than marked close-intent.
///
/// The invariant (`e65cfa4d5` defect 1): a leaf that leaves the tree because we
/// REPLACED the tree is not a user close. If the replacement tree still
/// references its session id, ending that session would kill the child of a
/// pane the user is looking at. Stated over session ids so it covers every
/// tree-swapping caller, present and future — being an invariant rather than a
/// special case is the whole point.
///
/// A leaf with no session id (a plain exec pane) has nothing to spare, so it is
/// not covered here; its child dies with the surface either way.
pub fn sessionSpared(session_id: ?[]const u8, surviving_ids: []const []const u8) bool {
    const sid = session_id orelse return false;
    for (surviving_ids) |other| {
        if (std.mem.eql(u8, sid, other)) return true;
    }
    return false;
}

/// Whether a departing leaf's agent session must be ENDED (marked close-intent)
/// when a tree swap is a partial CLOSE rather than a rebuild — `+rearrange`
/// (T128).
///
/// `sessionSpared` above answers the recovery half of the question: which
/// departing leaves must NOT be ended. This answers the other half, for the one
/// caller whose swap genuinely destroys panes. A `+rearrange` layout that omits
/// a pane is a close of that pane written as a layout, so its session must end
/// the way `+close` ends one; a pane the new layout still names is only being
/// moved, and ending its session would kill the child of a pane the user is
/// looking at. That is why the answer runs through `sessionSpared` rather than
/// stopping at "did this leaf leave the tree" — the id check is the invariant,
/// and it is what makes this safe for any future partially-destructive swap.
///
/// `in_new_tree` is the caller's own membership answer (pointer identity for
/// `+rearrange`); `surviving_ids` are the session ids the new tree references.
///
/// A leaf with no session id (a plain exec pane, a viewer) reads as "end it",
/// which is correct and inert: `setSessionCloseIntent` is a no-op for both, and
/// an exec child dies with its surface regardless.
pub fn closesDepartingLeaf(
    in_new_tree: bool,
    session_id: ?[]const u8,
    surviving_ids: []const []const u8,
) bool {
    if (in_new_tree) return false;
    return !sessionSpared(session_id, surviving_ids);
}

/// One node of a tab, reduced to the only thing recovery needs to know about
/// it. Both the live `SplitTree` and the captured manifest tab project down to
/// this, which is what lets the correspondence rule below be pure.
pub const NodeShape = enum { split, terminal, viewer };

/// Whether in-place recovery REBUILDS a leaf of this kind.
///
/// Only terminals. A terminal pane's shell runs under the agent, so a dropped
/// link genuinely invalidated it and the only cure is a fresh surface
/// re-ATTACHed on the new connection. A VIEWER holds no agent session at all —
/// its content came from a file, a URL or a git command — so there is nothing
/// for recovery to re-bind, and destroying it would tear down its WebView2 host,
/// reload the page, and lose the user's scroll position and in-page state for an
/// event that never touched it (T399).
pub fn rebuildsLeaf(shape: NodeShape) bool {
    return shape == .terminal;
}

/// Whether a captured manifest tab and the live tree it was captured FROM still
/// describe the same tab, node for node.
///
/// This is what licenses the surgical path: `captureSessionLayout` writes the
/// manifest node array as a 1:1 copy of the live `SplitTree` node array, so when
/// the two still correspond, index `i` names the same pane in both and a leaf
/// can be replaced in the slot it already occupies. When they do NOT — the tree
/// moved between the capture and the rebuild — no index means anything and the
/// caller must fall back to replacing the whole root, which is correct for any
/// tree at the cost of the churn the surgical path exists to avoid.
///
/// An empty pair corresponds to nothing: there is no tab there to rebuild.
pub fn shapesCorrespond(captured: []const NodeShape, live: []const NodeShape) bool {
    if (captured.len == 0 or captured.len != live.len) return false;
    for (captured, live) |c, l| {
        if (c != l) return false;
    }
    return true;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const S = connection.LinkState.State;

test "isDown: only a live link is up" {
    try testing.expect(!isDown(.connected));
    try testing.expect(!isDown(.degraded));
    try testing.expect(isDown(.reconnecting));
    try testing.expect(isDown(.reattaching));
    try testing.expect(isDown(.dead));
}

test "a link that heals inside the settle window never triggers recovery" {
    // The 2026-07-21 incident shape: down edge, then `connected` again 27ms
    // later. Every tick before the window elapses must keep watching, and the
    // heal must end the watch with no recovery.
    try testing.expectEqual(Verdict.keep_watching, evaluate(.reconnecting, true, 4000, 42, null));
    try testing.expect(!evaluate(.reconnecting, true, 4000, 42, null).triggersRecovery());

    const healed = evaluate(.connected, true, 4000, 42, null);
    try testing.expectEqual(Verdict.link_recovered, healed);
    try testing.expect(!healed.triggersRecovery());

    // Even AT the deciding tick, a healed link is a heal — the state is checked
    // before the deadline.
    try testing.expectEqual(Verdict.link_recovered, evaluate(.degraded, true, 0, 42, 99));
}

test "a racing re-dial retires the watch without recovering" {
    const v = evaluate(.dead, false, 0, 42, null);
    try testing.expectEqual(Verdict.owner_replaced, v);
    try testing.expect(!v.triggersRecovery());
    // owner_replaced outranks everything, including a definitively dead link
    // with a settle window long elapsed.
    try testing.expectEqual(Verdict.owner_replaced, evaluate(.dead, false, -10_000, 42, 7));
}

test "same agent pid after the window ⇒ transport_down, not a restart" {
    const v = evaluate(.dead, true, 0, 4242, 4242);
    try testing.expect(v.triggersRecovery());
    switch (v) {
        .transport_down => |d| try testing.expectEqual(@as(i64, 4242), d.pid),
        else => return error.TestUnexpectedResult,
    }
}

test "a different (or absent) agent pid after the window ⇒ agent_restarted" {
    const restarted = evaluate(.dead, true, 0, 4242, 5555);
    try testing.expect(restarted.triggersRecovery());
    switch (restarted) {
        .agent_restarted => |d| {
            try testing.expectEqual(@as(i64, 4242), d.previous_pid);
            try testing.expectEqual(@as(?i64, 5555), d.current_pid);
        },
        else => return error.TestUnexpectedResult,
    }

    // No agent on disk at all: still a restart verdict, with a null current pid
    // so the log can say "gone" rather than inventing a process.
    const gone = evaluate(.dead, true, -1, 4242, null);
    try testing.expect(gone.triggersRecovery());
    switch (gone) {
        .agent_restarted => |d| try testing.expectEqual(@as(?i64, null), d.current_pid),
        else => return error.TestUnexpectedResult,
    }

    // An unknown previous pid (never recorded) can never match, so a live agent
    // still reads as a restart rather than falsely claiming transport-only.
    const unknown_prev = evaluate(.dead, true, 0, 0, 5555);
    switch (unknown_prev) {
        .agent_restarted => {},
        else => return error.TestUnexpectedResult,
    }
}

test "T723 retry schedule: bounded, monotonic, and it runs out" {
    // Every retry must wait longer than (or as long as) the one before it: a
    // flat schedule spends the whole budget in the first few seconds, which is
    // exactly when a wedged agent is least likely to have come back.
    var prev: u32 = 0;
    for (retry_delays_ms) |d| {
        try testing.expect(d >= prev);
        prev = d;
    }
    // The first retry is soon enough to catch a brief wedge…
    try testing.expectEqual(@as(?u32, 2_000), retryDelayMs(0));
    // …and the schedule is spent rather than looping forever.
    try testing.expectEqual(@as(?u32, null), retryDelayMs(retry_delays_ms.len));
    try testing.expectEqual(@as(?u32, null), retryDelayMs(retry_delays_ms.len + 100));

    // The total budget is the number that matters to a user staring at a frozen
    // pane: long enough for a swapped-out agent or a respawn, short enough that
    // the honest "I gave up" notice is not half a working day away.
    var total: u64 = 0;
    for (retry_delays_ms) |d| total += d;
    try testing.expect(total >= 60_000);
    try testing.expect(total <= 180_000);
}

test "T723 evaluateRetry: a link that healed on its own cancels the retry" {
    // The wedge-then-unwedge case. The abort left the panes on the OLD
    // connection (recovery retires it only on success), so a heal there is the
    // whole cure — rebuilding on top of it would replace working panes.
    try testing.expectEqual(RetryVerdict.link_recovered, evaluateRetry(.connected, 0));
    // `degraded` is a live link with missed heartbeats, not a drop.
    try testing.expectEqual(RetryVerdict.link_recovered, evaluateRetry(.degraded, 3));

    // Still down ⇒ retry, for every state `isDown` covers.
    try testing.expectEqual(RetryVerdict.retry, evaluateRetry(.reconnecting, 0));
    try testing.expectEqual(RetryVerdict.retry, evaluateRetry(.reattaching, 0));
    try testing.expectEqual(RetryVerdict.retry, evaluateRetry(.dead, 0));
    // …and right up to the last scheduled attempt.
    try testing.expectEqual(RetryVerdict.retry, evaluateRetry(.dead, retry_delays_ms.len - 1));

    // No shared connection at all: a racing re-dial (or teardown) owns this now.
    try testing.expectEqual(RetryVerdict.no_owner, evaluateRetry(null, 0));
    // A missing owner outranks exhaustion — there is nobody to tell, and no
    // frozen pane to blame on us.
    try testing.expectEqual(RetryVerdict.no_owner, evaluateRetry(null, 99));

    // The give-up point, which is what makes the notice honest rather than a
    // pane that is still silently waiting.
    try testing.expectEqual(RetryVerdict.exhausted, evaluateRetry(.dead, retry_delays_ms.len));
    try testing.expectEqual(RetryVerdict.exhausted, evaluateRetry(.reconnecting, retry_delays_ms.len + 1));
}

test "sessionSpared: a session the new tree still uses is never close-intented" {
    const surviving = [_][]const u8{
        "0123456789abcdef0123456789abcdef",
        "fedcba9876543210fedcba9876543210",
    };
    // The defining case: the swap's departing leaf and its replacement share a
    // session id. Marking it would terminate the child of a live pane.
    try testing.expect(sessionSpared("fedcba9876543210fedcba9876543210", &surviving));
    // A session nothing references any more is not spared BY THIS RULE (the
    // caller decides; the swap path marks nothing at all).
    try testing.expect(!sessionSpared("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &surviving));
    // A plain exec pane has no session to spare.
    try testing.expect(!sessionSpared(null, &surviving));
    // An empty surviving set cannot spare anything.
    try testing.expect(!sessionSpared("0123456789abcdef0123456789abcdef", &.{}));
}

test "closesDepartingLeaf: a dropped pane's session ends, a kept one's never does" {
    const surviving = [_][]const u8{
        "0123456789abcdef0123456789abcdef",
        "fedcba9876543210fedcba9876543210",
    };
    // The T128 defect: a leaf the new layout omits, whose session nothing else
    // references, must be ENDED — it detached and lingered forever before.
    try testing.expect(closesDepartingLeaf(false, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &surviving));
    // A leaf the new tree still holds is not departing at all.
    try testing.expect(!closesDepartingLeaf(true, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &surviving));
    // And the invariant: even a leaf that LEFT is spared when the new tree
    // still references its session (a rebuild-style swap, `e65cfa4d5`).
    try testing.expect(!closesDepartingLeaf(false, "fedcba9876543210fedcba9876543210", &surviving));
    // An id-less leaf (exec pane / viewer) reads as "end it" and is inert.
    try testing.expect(closesDepartingLeaf(false, null, &surviving));
    try testing.expect(!closesDepartingLeaf(true, null, &surviving));
}

test "rebuildsLeaf: only terminals ride the connection that dropped" {
    try testing.expect(rebuildsLeaf(.terminal));
    // T399, the whole point: a viewer is not the agent's, so recovery is not
    // entitled to reload it.
    try testing.expect(!rebuildsLeaf(.viewer));
    try testing.expect(!rebuildsLeaf(.split));
}

test "shapesCorrespond: index i means the same pane in both, or nothing does" {
    const tree = [_]NodeShape{ .split, .terminal, .split, .viewer, .terminal };
    try testing.expect(shapesCorrespond(&tree, &tree));

    // A leaf that changed KIND between capture and rebuild: replacing by index
    // would put a terminal where the user has a viewer.
    const kind_moved = [_]NodeShape{ .split, .terminal, .split, .terminal, .terminal };
    try testing.expect(!shapesCorrespond(&tree, &kind_moved));

    // A leaf that became a split (someone split a pane mid-recovery), and a
    // tree that grew or shrank.
    const split_moved = [_]NodeShape{ .split, .split, .split, .viewer, .terminal };
    try testing.expect(!shapesCorrespond(&tree, &split_moved));
    try testing.expect(!shapesCorrespond(&tree, tree[0..4]));

    // Nothing corresponds to nothing.
    try testing.expect(!shapesCorrespond(&.{}, &.{}));
    try testing.expect(!shapesCorrespond(&tree, &.{}));

    // The single-leaf tab, which is the common case.
    const lone = [_]NodeShape{.terminal};
    try testing.expect(shapesCorrespond(&lone, &lone));
    try testing.expect(!shapesCorrespond(&lone, &[_]NodeShape{.viewer}));
}
