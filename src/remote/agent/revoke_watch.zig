//! The AGENT's half of a pending revocation (T1427).
//!
//! ## Why this exists
//!
//! T1424 made a forced sign-out ARM a pending revocation and retry it — at
//! app launch, and on a backoff while the app runs. That fixed the record
//! keeping half. It did not fix the machine.
//!
//! The app is not what keeps this machine on the account. The AGENT is: it
//! holds the same `relay.env` device credential, and it keeps a control
//! WebSocket up to the relay so the machine is listed, reachable and
//! streamable from every other computer on the account. The agent outlives
//! every window; it is running when no Ghoztty window is open at all. So
//! between "Sign Out Anyway" and the next time the user happens to launch the
//! app, the machine the user has just disowned is still there — and for the
//! ordinary case that produced the sign-out ("I am done with this box"), the
//! app is never launched again and it stays there forever.
//!
//! ## What this does, in the order that matters
//!
//!   1. **Take the machine offline first.** The moment an armed record is
//!      seen, the relay uplink is PARKED (`LinkControl.disconnect`). That
//!      needs no network and no relay, so the window during which a disowned
//!      machine is reachable ends at the next 5-second tick rather than at
//!      the next successful de-enroll. Local sessions are untouched — a
//!      control drop only ever DETACHes them (`main.zig` §7.1).
//!   2. **Then finish the revocation**, by handing off to T1424's
//!      `relay_revoke_pending.retryAsync`. The rules stay in exactly one
//!      place: `nextAfter` (204/200 done, 401 narrowly "stop, and conclude
//!      nothing else", everything else stays armed), `backoffMs`, and the
//!      one-loop-per-process guard. Nothing about the retry is re-decided
//!      here, which is the point — a second implementation of "what does a
//!      401 mean" is how the Mac seat lost a machine's suspension record
//!      (`f3b1e5fb5`, T1425).
//!
//! ### The trade in step 1, made deliberately
//!
//! T1427 was filed noting that the agent "already knows when the relay came
//! back, which is the signal the app has to approximate with a backoff".
//! Parking the link gives that signal up: a parked link never dials, so it
//! never observes the relay returning. That is the right way round, because
//! the link being up IS the defect this task exists to close. A reachable
//! disowned machine is not an acceptable price for a faster retry, and the
//! capped backoff already bounds "still enrolled" to minutes.
//!
//! ## Two processes may retry the same record, and that is safe
//!
//! The app retries too, and both may POST `/v1/agent/deenroll` with the same
//! bearer. One of them gets 204 and the other gets 401 — which
//! `nextAfter` already maps to `clear_token_dead`: stop retrying, conclude
//! nothing else. The record delete is idempotent (`clearAt` treats a missing
//! file as success, which its own test asserts), and so is the credential
//! delete inside `deEnrollStatus`. So "exactly once" holds where it must —
//! the relay deletes the device once, and the local files end up gone once —
//! without any cross-process lock.
//!
//! ## When the machine comes back
//!
//! Not every armed record ends in a revocation. If the user signs back in on
//! this machine, `relay_suspend.settlePending` clears the record and KEEPS the
//! credential — the machine is theirs again and the uplink must come back up.
//! `verdict` tells that apart from a completed revocation by one observation:
//! after a revocation the credential is gone (`deEnrollStatus` deletes
//! relay.env), and after a sign-in or a re-enroll it is present. So a
//! disarmed record plus a live credential releases the hold, and a disarmed
//! record with no credential keeps it — a redial loop against a dead token
//! helps nobody.

const std = @import("std");
const Allocator = std.mem.Allocator;
const enroll = @import("enroll.zig");
const link_control = @import("link_control.zig");
const pending_revoke = @import("../relay_revoke_pending.zig");

/// What the uplink should be doing, given what the local files say.
pub const Verdict = enum {
    /// Nothing armed and nothing this agent has held: the uplink is not this
    /// module's business.
    idle,
    /// A revocation is armed, or one completed and this machine has not been
    /// enrolled again. The uplink must be DOWN.
    hold_offline,
    /// A held machine is legitimately on the account again (signed back in,
    /// or re-enrolled). Let the uplink come back.
    release,
};

/// The rule, pure.
///
/// `armed` — a usable pending-revocation record exists.
/// `held` — this agent has already parked the uplink over one.
/// `env_token` — the device token relay.env currently holds, if any.
///
/// The two release cases (the user signed back in on this machine; the
/// machine was enrolled again under a new token) deliberately collapse into
/// one: both leave a usable credential, and in both the machine is the
/// account's again. Comparing the token against the revoked one would buy no
/// decision, only a way to get it wrong.
pub fn verdict(armed: bool, held: bool, env_token: ?[]const u8) Verdict {
    if (armed) return .hold_offline;
    if (!held) return .idle;
    const tok = env_token orelse return .hold_offline;
    return if (tok.len == 0) .hold_offline else .release;
}

/// Polls for an armed revocation and reconciles the relay uplink with it.
/// Runs on its own thread (`run`) for the daemon's lifetime; `checkOnce` is
/// the tick, and `apply` is the part that decides, so both are testable
/// without a relay.
pub const Watcher = struct {
    alloc: Allocator,
    link: *link_control.LinkControl,
    /// Whether this watcher may bring the uplink back up on release.
    ///
    /// True in `--relay` mode, where nothing else writes the desired link
    /// state. False under `SharingUplink`, which reconciles the link against
    /// sharing.json every tick and would otherwise fight this: there the
    /// watcher only ever parks, publishes `isHolding`, and lets the
    /// reconciler resume once its own veto clears.
    owns_resume: bool = true,
    poll_interval_ms: u64 = poll_interval_default_ms,
    /// Set by `requestStop` (tests); `run` returns promptly.
    stop: std.Thread.ResetEvent = .{},

    /// Published for `SharingUplink.reconcile` to veto on. Read from another
    /// thread, hence the atomic.
    holding: std.atomic.Value(bool) = .init(false),

    /// A sign-out is a rare event; one line per transition, not one per tick.
    said_hold: bool = false,

    /// A revocation is a human-paced event and this tick is two small local
    /// reads, so the same 5s cadence the credential watcher uses keeps the
    /// disowned-machine window short at no measurable cost.
    const poll_interval_default_ms: u64 = 5_000;

    pub fn init(alloc: Allocator, link: *link_control.LinkControl, owns_resume: bool) Watcher {
        return .{ .alloc = alloc, .link = link, .owns_resume = owns_resume };
    }

    /// Whether the uplink is being held down for a revocation. The veto
    /// `SharingUplink.reconcile` consults before it decides anything else.
    pub fn isHolding(self: *const Watcher) bool {
        return self.holding.load(.acquire);
    }

    /// Thread entry: tick every `poll_interval_ms` until `requestStop`.
    ///
    /// The FIRST tick runs immediately rather than after a full interval: a
    /// daemon that starts up with a revocation already armed (the machine was
    /// signed out, then rebooted) must not spend its first five seconds
    /// advertising a machine that is not on the account any more.
    pub fn run(self: *Watcher) void {
        const interval_ns = self.poll_interval_ms * std.time.ns_per_ms;
        self.checkOnce();
        while (true) {
            if (self.stop.timedWait(interval_ns)) {
                return; // stop requested
            } else |_| {} // interval elapsed — tick
            self.checkOnce();
        }
    }

    pub fn requestStop(self: *Watcher) void {
        self.stop.set();
    }

    /// One tick: read the world, then `apply` what it says.
    pub fn checkOnce(self: *Watcher) void {
        const armed = pending_revoke.isArmed(self.alloc);

        // relay.env is only read when its answer can change anything: while
        // nothing is armed and nothing is held, the steady state of every
        // machine that has never been signed out, this tick is one failed
        // open of a file that is not there.
        var token: ?[]u8 = null;
        defer if (token) |t| self.alloc.free(t);
        if (!armed and self.isHolding()) token = enroll.loadDeviceToken(self.alloc);

        self.apply(armed, token);
    }

    /// The decision half of a tick, split out so a test can drive the state
    /// machine over a real `LinkControl` without a relay, a record, or a
    /// credential file.
    pub fn apply(self: *Watcher, armed: bool, env_token: ?[]const u8) void {
        switch (verdict(armed, self.isHolding(), env_token)) {
            .idle => {},
            .hold_offline => {
                if (!self.holding.swap(true, .acq_rel)) {
                    self.said_hold = true;
                    std.debug.print(
                        "ghoztty-agent: this machine has been signed out of its account; taking the relay uplink down until the revocation completes (local sessions unaffected)\n",
                        .{},
                    );
                }
                // Park unconditionally on the hold edge, and on any later tick
                // that still finds the uplink up: `SharingUplink` may have
                // raised it between ticks, and the hold has to win.
                if (self.link.display() != .offline) self.link.disconnect();
            },
            .release => {
                self.holding.store(false, .release);
                self.said_hold = false;
                std.debug.print(
                    "ghoztty-agent: this machine is on an account again; the relay uplink may come back up\n",
                    .{},
                );
                if (self.owns_resume) self.link.reconnect();
            },
        }

        // Hand the completion itself to T1424's retry — one loop per process,
        // started only when there is something to finish, and it ends when the
        // record does. Done AFTER the park so the machine is off the relay
        // before the first POST rather than after it.
        if (armed) pending_revoke.retryAsync(self.alloc);
    }
};

// =============================================================================
// Tests (pure — the agent lane)
// =============================================================================

const testing = std.testing;

test "verdict: an armed revocation always holds the uplink down" {
    try testing.expectEqual(Verdict.hold_offline, verdict(true, false, null));
    try testing.expectEqual(Verdict.hold_offline, verdict(true, true, "still-a-token"));
}

test "verdict: nothing armed and nothing held is not this module's business" {
    // The steady state of every machine that has never been signed out.
    try testing.expectEqual(Verdict.idle, verdict(false, false, "tok"));
    try testing.expectEqual(Verdict.idle, verdict(false, false, null));
}

test "verdict: a completed revocation keeps the uplink down" {
    // The record is gone and so is the credential (`deEnrollStatus` deletes
    // relay.env on 204 and on 401). Redialing a relay with a dead token helps
    // nobody, and the machine is not on the account any more.
    try testing.expectEqual(Verdict.hold_offline, verdict(false, true, null));
    try testing.expectEqual(Verdict.hold_offline, verdict(false, true, ""));
}

test "verdict: signing back in on this machine releases the hold" {
    // `relay_suspend.settlePending`'s `keep_machine` path: the record is
    // cleared and the credential is KEPT, because the machine is theirs
    // again. It has to come back online — the user did not sign out after
    // all, and nothing else would ever un-park it.
    try testing.expectEqual(Verdict.release, verdict(false, true, "the-same-token"));
}

test "verdict: a re-enrollment releases the hold too" {
    // Indistinguishable from the sign-in case by design: both leave a usable
    // credential, and in both this machine is legitimately on an account.
    try testing.expectEqual(Verdict.release, verdict(false, true, "a-brand-new-token"));
}

test "apply: the uplink is parked while a revocation is armed and comes back after" {
    var link: link_control.LinkControl = .{};
    var w = Watcher.init(testing.allocator, &link, true);

    // An online link with a revocation armed is the defect: park it.
    try testing.expectEqual(link_control.Display.reconnecting, link.display());
    w.apply(true, null);
    try testing.expect(w.isHolding());
    try testing.expectEqual(link_control.Display.offline, link.display());

    // Still armed on the next tick: still down, and no flapping.
    w.apply(true, null);
    try testing.expectEqual(link_control.Display.offline, link.display());

    // The revocation completed — the credential is gone with it. The hold
    // stays: this machine is off the account.
    w.apply(false, null);
    try testing.expect(w.isHolding());
    try testing.expectEqual(link_control.Display.offline, link.display());

    // Enrolled again: released, and (owning the resume, as `--relay` mode
    // does) brought back up.
    w.apply(false, "fresh-token");
    try testing.expect(!w.isHolding());
    try testing.expectEqual(link_control.Display.reconnecting, link.display());
}

test "apply: a raise that lands between ticks is parked again by the next one" {
    // `SharingUplink` reconciles on its own 5s tick and can call `reconnect`
    // before it has seen the veto. The hold must win on every tick, not only
    // on the edge — otherwise the two reconcilers alternate and the machine
    // is online half the time.
    var link: link_control.LinkControl = .{};
    var w = Watcher.init(testing.allocator, &link, false);

    w.apply(true, null);
    try testing.expectEqual(link_control.Display.offline, link.display());

    link.reconnect(); // the other reconciler, mid-tick
    try testing.expectEqual(link_control.Display.reconnecting, link.display());

    w.apply(true, null);
    try testing.expectEqual(link_control.Display.offline, link.display());
}

test "apply: under SharingUplink the watcher parks but never resumes" {
    // `owns_resume = false`: the reconciler owns the desired state and will
    // bring the link back on its next tick once `isHolding` clears. A
    // watcher that resumed here would un-park a link the USER had turned off
    // ("Share this machine" unchecked), for up to a whole tick.
    var link: link_control.LinkControl = .{};
    var w = Watcher.init(testing.allocator, &link, false);

    w.apply(true, null);
    try testing.expectEqual(link_control.Display.offline, link.display());

    w.apply(false, "fresh-token");
    try testing.expect(!w.isHolding());
    try testing.expectEqual(link_control.Display.offline, link.display());
}

test "apply: a machine that was never signed out is left completely alone" {
    var link: link_control.LinkControl = .{};
    var w = Watcher.init(testing.allocator, &link, true);
    for (0..3) |_| w.apply(false, "tok");
    try testing.expect(!w.isHolding());
    try testing.expectEqual(link_control.Display.reconnecting, link.display());
}
