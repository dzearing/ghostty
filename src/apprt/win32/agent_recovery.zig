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
