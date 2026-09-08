//! Non-destructive local-agent upgrade policy (T147) — the win32 port of the
//! Mac `LocalAgentManager` staleness detection + lazy refresh (`c6ad0fc07`).
//!
//! The `ghoztty-agent` outlives the app on purpose: the upgrade script swaps
//! `ghoztty-agent.exe` on disk WITHOUT killing the running agent (T89h), because
//! killing it is exactly the silent session reset docs/claude/sessions.md's "Agent contract &
//! upgrade compatibility" section forbids. The consequence is the defect this
//! module exists to close: the app never compares the RUNNING agent's build to
//! the one it now ships beside, so an agent-side fix reaches the user only after
//! a reboot. A user who upgraded through several releases kept an agent from
//! weeks ago.
//!
//! The decisions are pure and live here so both app-runtime lanes can test them
//! without an agent, a registry, or a window; the mechanism (probe the bundled
//! binary, terminate + respawn, confirm) lives in `LocalAgent` and `App`.
//!
//! Three rules, each of which is destructive to get wrong:
//!
//!  1. **Unknown means "don't judge".** A bundled stamp we could not read (no
//!     binary, `--version` failed) yields `.none` — never a restart on a guess.
//!  2. **Never downgrade.** A running agent whose stamp is NEWER than the
//!     bundled one is left alone: a debug/dev agent, or an app rolled back
//!     under a newer agent, must not have its sessions killed to install an
//!     older binary.
//!  3. **Live sessions are never ended for a build-stamp gap at all** (T1056).
//!     Zero live sessions ⇒ refresh immediately (nothing to lose). One or more
//!     ⇒ the agent is left strictly alone and adopted at the next quiet moment
//!     — which is why the check is re-run when the last persistent window
//!     closes, not just at launch.
//!
//!     A newer bundled build is NOT an incompatibility. `proto_version` is
//!     negotiated in HELLO and a mismatch is fatal there, so an agent we can
//!     talk to has already agreed the wire contract, and every capability since
//!     rides an additive, intersection-negotiated list that degrades on its own.
//!     Ending live sessions to pick up a fresher binary therefore buys nothing
//!     and costs the user every running process — which is exactly what Mac's
//!     1.33.0 update did (95 sessions tombstoned by a restart nothing required).
//!     The mandatory-update confirmation still exists, reserved for the case it
//!     was written for: a skew the handshake actually flags as INCOMPATIBLE
//!     (`evaluateSkew`), which by construction cannot be this one.

const std = @import("std");
const agent_build = @import("../../remote/agent_build.zig");

/// The stamp primitives are SHARED with the CLI (`+sessions --agent`, T662) and
/// live in `remote/agent_build.zig`, so "stale" has exactly one definition on
/// both platforms rather than a second spelling here that can drift. Re-exported
/// under their original names because this module's rules are written in terms
/// of them and every caller already spells them this way.
pub const parseVersionOutput = agent_build.parseVersionOutput;
pub const stampIsNewer = agent_build.stampIsNewer;
pub const isStale = agent_build.isStale;

/// What the app should do about the agent it is connected to.
pub const Action = enum {
    /// Nothing: current, newer, or not knowable.
    none,
    /// Restart the agent now, silently (no live sessions to lose). Logged, but
    /// never a modal — there is nothing for the user to decide.
    refresh_now,
    /// Restart only after a mandatory confirmation: live sessions WILL close.
    ///
    /// Since T1056 this comes from `evaluateSkew` ALONE — a protocol skew, where
    /// the app cannot reach the agent's sessions to save them and there is no
    /// other way back to a working terminal. A merely older BUILD never reaches
    /// here: see rule 3 above.
    confirm_first,
    /// Stand down: the agent replaces ITSELF (T907). Not "nothing is wrong" —
    /// the running agent IS stale — but nothing for the app to do about it, and
    /// specifically nothing destructive. The agent spawns the newer on-disk
    /// build, hands it the per-session PTY holders and exits; the app sees a
    /// link drop and runs the recovery it already has.
    ///
    /// Distinct from `.none` because the two are opposite states to find a box
    /// in ("current" vs "mid-upgrade") and the log line is the only place anyone
    /// can tell them apart afterwards.
    handoff_now,
};

/// WHY the policy reached its `Action`. Exists because three of the five
/// outcomes below map to the same `.none`, and a log line that says only
/// "nothing to do" cannot be audited afterwards: "current", "newer, leave it
/// alone", and "we couldn't read the binary we ship" are very different states
/// to find a user's box in (T201).
///
/// The `skew_*` variants share this enum with the staleness ones deliberately:
/// they end in the same dialog and the same log line, and one vocabulary is what
/// makes "why did Ghoztty restart my agent?" answerable from a single grep.
pub const Reason = enum {
    /// Rule 1: no readable bundled stamp, so there is nothing to judge against.
    bundled_unknown,
    /// The running agent is exactly the build we ship beside. The steady state.
    current,
    /// Rule 2: the running agent is NEWER than ours — a dev/debug agent, or an
    /// app rolled back under a newer agent. Never downgraded.
    running_newer,
    /// Stale with nothing to lose: restart silently.
    stale_idle,
    /// Stale with live sessions, and protocol-compatible (T1056): the app does
    /// nothing at all. The bundled build is adopted at the next quiet moment —
    /// the last persistent window closing, or the next cold start — because the
    /// agent's argv is stable and the newer binary sits at the path it respawns
    /// from. Never a dialog, and never a restart: see rule 3.
    stale_live_deferred,

    /// Stale, and the agent replaces itself without losing anything (T907):
    /// every live session is holder-backed and both peers negotiated
    /// `capability.agent_handoff`. Nobody is asked and nothing is restarted from
    /// here.
    stale_handoff,
    /// Stale and handoff-capable, but sessions the agent owns DIRECTLY are still
    /// live and cannot be carried across a process boundary. The handoff drains
    /// lazily — each one that closes brings it closer — and nobody is asked to
    /// hurry it along: since T1056 forcing it early would mean ending live
    /// sessions for a build-stamp gap, which is the act rule 3 forbids.
    stale_handoff_draining,

    /// Protocol skew, and the AGENT is the older side: the mandatory-update path
    /// applies, so confirm and restart it onto the bundled build.
    skew_agent_older,
    /// Protocol skew, and the agent is the NEWER side: the APP is what is out of
    /// date. Rule 2 applies with more force than usual here — restarting would
    /// replace a newer agent with an older one AND end its sessions to do it.
    skew_app_older,
    /// A skew we cannot orient: no HELLO version was captured. Rule 1 — nothing
    /// destructive on a guess.
    skew_unknown,

    /// A confirmation WAS required (stale build or agent-older skew), but an
    /// unattended refresh is in progress, so nobody is here to answer it. Not
    /// the same as a decline: the next quiet moment still asks (T525).
    confirm_deferred,

    /// One clause, written to be read in a log line after "agent upgrade
    /// check:".
    pub fn description(self: Reason) []const u8 {
        return switch (self) {
            .bundled_unknown => "no action, bundled agent build unknown (nothing to compare against)",
            .current => "no action, running agent is the bundled build",
            .running_newer => "no action, running agent is NEWER than bundled (never downgrade)",
            .stale_idle => "stale and idle, refreshing now",
            .stale_live_deferred => "stale with live sessions, but protocol-compatible; leaving it alone and adopting at the next quiet moment",
            .stale_handoff => "stale, but the agent is replacing itself without losing any session (standing down)",
            .stale_handoff_draining => "stale and self-replacing, but sessions the agent owns directly must close first; waiting for them",
            .skew_agent_older => "protocol skew, running agent speaks an OLDER protocol, confirmation required",
            .skew_app_older => "no action, running agent speaks a NEWER protocol — this app is the out-of-date side (never downgrade)",
            .skew_unknown => "no action, protocol skew of unknown direction (no peer version captured)",
            .confirm_deferred => "no action, confirmation required but an unattended refresh is in progress (will ask at the next quiet moment)",
        };
    }
};

/// An `Action` and the `Reason` that produced it. Returned together so the
/// caller logs the decision it is about to act on, rather than reconstructing
/// it from which branch happened to run.
pub const Decision = struct {
    action: Action,
    reason: Reason,
};

/// What the running agent can do for itself (T907), as this app can see it.
///
/// Both fields default to the pre-T907 world, and that is load-bearing: every
/// caller that does not know about handoffs — and every existing test — gets
/// exactly the old policy, so the new arm can only ever be reached deliberately.
pub const Handoff = struct {
    /// BOTH peers advertised `capability.agent_handoff`, i.e. the running agent
    /// replaces itself when a newer build lands beside it AND this build knows
    /// that. False for an older agent, for an un-negotiated link, and for a
    /// non-Windows agent (the Mac half is increment 5 of the T705 split) — in
    /// every one of which cases standing down would mean waiting forever.
    capable: bool = false,
    /// How many LIVE sessions the agent still owns directly (`holder_backed ==
    /// false` in its roster). Each one holds the handoff back, because a ConPTY
    /// cannot be carried across a process boundary at all.
    legacy_live: usize = 0,
};

/// The whole policy in one pure function. `bundled == null` is "we could not
/// read the binary we ship" (rule 1).
///
/// `isStale` stays the single authority on staleness; this only classifies WHY
/// a not-stale agent was left alone, so the two can never disagree.
pub fn evaluate(
    running: ?[]const u8,
    bundled: ?[]const u8,
    live_sessions: usize,
    handoff: Handoff,
) Decision {
    const b = bundled orelse return .{ .action = .none, .reason = .bundled_unknown };
    if (b.len == 0) return .{ .action = .none, .reason = .bundled_unknown };
    if (!isStale(running, b)) {
        // Not stale ⇒ `running` is non-null, non-empty, and either equal to
        // `b` or newer than it. Those are the only two ways to get here.
        const r = running orelse "";
        return .{
            .action = .none,
            .reason = if (std.mem.eql(u8, r, b)) .current else .running_newer,
        };
    }
    // Idle stays FIRST, ahead of the handoff arm. With nothing live, a restart
    // costs nothing and completes at once, whereas a handoff waits for the
    // agent's own poll interval — and rule 3's "nothing to lose ⇒ do it now" is
    // the older, simpler guarantee. The two never disagree about outcome, only
    // about how long it takes.
    if (live_sessions == 0) return .{ .action = .refresh_now, .reason = .stale_idle };

    // Every live session is holder-backed ⇒ the agent carries them all across on
    // its own. Standing down IS the action.
    if (handoff.capable and handoff.legacy_live == 0) {
        return .{ .action = .handoff_now, .reason = .stale_handoff };
    }

    // Everything left is "stale, compatible, and something is live". Since T1056
    // that is not an action at all — see rule 3. The two reasons differ only in
    // WHEN the newer build gets adopted, which is what an operator reading the
    // log needs to know: a handoff-capable agent installs it as its own legacy
    // sessions close, whereas a pre-T907 one waits for the next cold start.
    // Neither is worth ending a session over, so neither asks.
    return .{
        .action = .none,
        .reason = if (handoff.capable) .stale_handoff_draining else .stale_live_deferred,
    };
}

/// The action alone, for callers that don't log (and every existing test).
/// Assumes no handoff — the pre-T907 policy.
pub fn decide(running: ?[]const u8, bundled: ?[]const u8, live_sessions: usize) Action {
    return evaluate(running, bundled, live_sessions, .{}).action;
}

// =============================================================================
// Unattended deferral (T525)
// =============================================================================

/// The morning client refresh restarts the app with nobody sitting in front of
/// it, and the FIRST thing the fresh app does is run the check above. On a box
/// that has taken several deliveries the on-disk agent is already newer than the
/// running one, so that check lands on `confirm_first` and puts a modal on an
/// empty desk — the "interruption by another name" T525 exists to remove. The
/// user's directive is explicit that the agent must not be touched by the
/// morning flow at all ("avoid an agent update because that will shut down the
/// loop"), so the honest answer is not to ask.
///
/// The signal is a small marker file the delivery writes just before it starts
/// the app: one line holding a UTC unix-seconds DEADLINE. A deadline rather than
/// a flag, because the failure mode of a flag is permanent silence — a marker
/// nobody cleaned up would suppress the confirmation forever, on a machine whose
/// agent then never updates again. This expires on its own.
///
/// The file is named for the confirmation it was written for, but since T1120
/// it means the wider thing the delivery actually needs: an unattended relaunch
/// is in progress, so the app raises NO prompt of its own. `App` reads it for
/// the protocol-skew confirmation below, the different-build handoff prompt and
/// the one-time agent-integration offers; each one would otherwise sit on an
/// empty desk until the user found it in the morning.
///
/// Deferral is deliberately NOT the same as the user pressing "Later": it does
/// not set `agent_upgrade_declined`, so the check that runs when the last
/// persistent window closes still fires. By then the marker has expired and
/// there are no live sessions anyway, which is `refresh_now` — the quiet moment
/// rule 3 always promised.
pub const defer_marker_name = "agent-upgrade-defer";

/// Parse a marker's contents into its UTC unix-seconds deadline.
///
/// One decimal integer, leading/trailing whitespace ignored, everything from the
/// first newline on ignored (so a future writer can add a human-readable comment
/// line without breaking older apps). Anything else is null — an unreadable
/// marker must never be read as "suppress", because that is the direction that
/// fails silently.
pub fn parseDeferDeadline(contents: []const u8) ?i64 {
    const first_line = blk: {
        const nl = std.mem.indexOfAny(u8, contents, "\r\n") orelse break :blk contents;
        break :blk contents[0..nl];
    };
    const trimmed = std.mem.trim(u8, first_line, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

/// Is an unattended refresh in progress right now?
///
/// `contents == null` is "no marker file" — the overwhelmingly common case, and
/// the one that must cost nothing. A deadline at or before `now_s` has expired.
pub fn deferralActive(contents: ?[]const u8, now_s: i64) bool {
    const c = contents orelse return false;
    const deadline = parseDeferDeadline(c) orelse return false;
    return now_s < deadline;
}

/// Fold an active deferral into a decision.
///
/// Only `confirm_first` is affected, and that is the whole point: `refresh_now`
/// has no live session to lose and no dialog to show, so suppressing it would
/// trade a free upgrade for nothing, and `none` has nothing to suppress. Both
/// paths that reach `confirm_first` — a stale build and a protocol skew — are
/// the same modal with the same outcome, so both defer.
pub fn applyDeferral(d: Decision, deferred: bool) Decision {
    if (!deferred) return d;
    if (d.action != .confirm_first) return d;
    return .{ .action = .none, .reason = .confirm_deferred };
}

// =============================================================================
// Protocol skew (T125)
// =============================================================================

/// What to do about an agent whose HELLO could not be negotiated — the second
/// trigger for the same mandatory-update dialog `evaluate` feeds.
///
/// `evaluate` above answers "is the running agent an older BUILD?". This answers
/// the question it deliberately did not: "did the handshake fail because the two
/// ends speak DIFFERENT PROTOCOLS?" the agent contract (docs/claude/sessions.md) requires that on
/// an incompatible skew the app must not replay across it and must take the
/// mandatory-update path instead — which, on Windows, means this decision.
///
/// The direction is everything, and it is why the peer's version is plumbed all
/// the way out of a failed dial (`tcp_dial.DialReport`):
///
///  - **Agent older** ⇒ restart it, after the same consent the stale path asks
///    for. Sessions it still holds WILL be lost — the app cannot reach them to
///    save them, which is the whole problem — so this is never silent, and
///    (unlike `stale_idle`) there is no idle arm: "no live sessions" is not
///    knowable across a skew, and an unknown count is never grounds for a silent
///    destructive act.
///  - **Agent newer** ⇒ do nothing. The app is the out-of-date side; killing the
///    agent would be a downgrade AND would end sessions a NEWER app could still
///    have attached to. Rule 2, at its most load-bearing.
///  - **Unknown** ⇒ do nothing. Rule 1.
///
/// `local` is this build's `protocol.proto_version`; `peer` is what the agent
/// advertised, or null when no HELLO was parsed at all.
pub fn evaluateSkew(peer: ?u16, local: u16) Decision {
    const p = peer orelse return .{ .action = .none, .reason = .skew_unknown };
    if (p > local) return .{ .action = .none, .reason = .skew_app_older };
    if (p < local) return .{ .action = .confirm_first, .reason = .skew_agent_older };
    // Same version, still incompatible: the disagreement was over the transfer
    // encoding, which the CLIENT proposes and the agent echoes. An agent that
    // echoes something else is one that does not understand what we asked for,
    // i.e. the older side, and restarting it is the same cure.
    return .{ .action = .confirm_first, .reason = .skew_agent_older };
}

/// The mandatory-confirmation body for a protocol skew — since T1056 the ONLY
/// confirmation this policy raises, because it is the only state in which a
/// restart is the difference between working and not working. The agent is
/// already unreachable, so the honest promise is not "you keep working" but
/// "this is how you get working again"; a merely older BUILD keeps working and
/// is therefore never offered up for one.
///
/// It states the cost without inventing a number — the session count lives
/// inside the agent we cannot talk to, and a dialog that guessed at it would be
/// making up the very fact the user is being asked to weigh.
pub fn formatSkewConfirmText(buf: []u8, peer: ?u16, local: u16) ![]const u8 {
    const lead =
        "Ghoztty can no longer talk to the background process that keeps your " ++
        "terminal sessions running: it is from a different version of Ghoztty " ++
        "and no longer speaks the same protocol";
    const tail =
        ".\n\nRestarting it now updates it to the version shipped with this app. " ++
        "Any sessions it is still holding will close, and they cannot be " ++
        "carried across — Ghoztty cannot reach them to save them.\n\n" ++
        "If you do nothing, new windows keep working but without session " ++
        "persistence.";
    // The version pair is a parenthetical, not a sentence, so an unknown peer
    // simply drops it rather than printing a placeholder the user has to decode.
    return if (peer) |p|
        std.fmt.bufPrint(buf, lead ++ " (it speaks version {d}, this app speaks {d})" ++ tail, .{ p, local })
    else
        std.fmt.bufPrint(buf, lead ++ tail, .{});
}

/// The other direction's notice (T626), as a title/body pair sized for a tray
/// balloon.
///
/// `evaluateSkew` answers `.none` when the agent is the NEWER side, and it is
/// right to: restarting would downgrade a newer binary and end the sessions it
/// holds. But `.none` used to mean the user was told nothing at all — new
/// windows simply stopped keeping their sessions, with the reason only in a log
/// file. That is the same invisible degradation T125 fixed for the other
/// direction.
///
/// The text names the ACT, not the protocol. There is nothing to consent to
/// here and nothing this app can repair from inside a dialog: the cure is a
/// newer Ghoztty, so the notice says so and a click goes looking for one. The
/// version pair belongs in the log line beside it, not in front of the user.
pub const app_older_notice_title = "Ghoztty Is Out of Date";
pub const app_older_notice_body =
    "The background process holding your terminal sessions is newer than " ++
    "this copy, so sessions are not being kept.\nClick to update Ghoztty.";

/// Title for the skew confirmation. Deliberately the SAME title as the staleness
/// one: it is one dialog with one outcome (the background process restarts),
/// reached two ways, and giving each trigger its own title would make the app
/// look like it has two unrelated features.
pub const skew_confirm_title = confirm_title;

/// What to print for a stamp that may be absent. `running == null` is an agent
/// too old to advertise one; `bundled == null` is an unreadable binary.
pub const stampForLog = agent_build.stampForLog;

/// Title for the mandatory-update dialog.
///
/// There used to be two bodies to go with it — `formatConfirmText` and
/// `formatDrainConfirmText` — for the two ways a merely STALE agent could be
/// offered up for a restart. T1056 removed both along with the policy that
/// reached them: a build-stamp gap is not a reason to end a session, so there is
/// nothing there to ask the user, and a dialog offering to do it anyway is a
/// hazard rather than a courtesy. `formatSkewConfirmText` is the one body left,
/// for the one case that genuinely cannot be recovered any other way.
pub const confirm_title = "Restart the Ghoztty background terminal process?";

/// The image name a pid must carry before the destructive refresh is allowed to
/// terminate it (T421).
pub const default_agent_image = "ghoztty-agent.exe";

/// Last path component of `path`, accepting either separator. `""` when the
/// path ends in one.
pub fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| if (c == '\\' or c == '/') {
        start = i + 1;
    };
    return path[start..];
}

/// The name up to the first `.` — `ghoztty-agent.exe` ⇒ `ghoztty-agent`.
fn stem(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

/// Is `image` (the full path `QueryFullProcessImageNameW` reported for a pid)
/// the local agent we are about to kill?
///
/// The pid comes out of `port.json`, a FILE — nothing about it is guaranteed to
/// still name the agent. Windows recycles pids, a stale info file outlives its
/// writer, and `TerminateProcess` on the wrong pid is unrecoverable and silent.
/// T421's app died inside that call with no crash record and no further log
/// line, which is exactly the signature a self-terminate leaves, so the kill is
/// gated on identity rather than on the file being trustworthy.
///
/// Matched on the BASE NAME's STEM, as a prefix, case-insensitively — NOT on the
/// full name, and this is load-bearing rather than sloppy. **Every delivery
/// renames the running agent's own image**: `upgrade-ghoztty-windows.ps1` cannot
/// delete a running exe, so it does `Move-Item ghoztty-agent.exe
/// ghoztty-agent.exe.bak` and copies the new build into place. By the time the
/// app decides that agent is stale, `QueryFullProcessImageNameW` reports the
/// `.bak` path — a full-name match would refuse to kill the very agent this
/// whole feature exists to replace. (Measured: `agent-upgrade.ps1` arm I, which
/// reproduces that rename, failed exactly that way.)
///
/// `expected` is the path this build would spawn (`GHOSTTY_LOCAL_AGENT_BIN` can
/// move or rename it); null falls back to `default_agent_image`.
pub fn imageIsAgent(image: []const u8, expected: ?[]const u8) bool {
    const want = stem(baseName(expected orelse default_agent_image));
    const got = baseName(image);
    if (want.len == 0 or got.len < want.len) return false;
    return std.ascii.eqlIgnoreCase(got[0..want.len], want);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the shared stamp primitives are the ones this policy is written against" {
    // Re-exports, not copies (T662): a second spelling of "stale" is exactly the
    // drift `remote/agent_build.zig` exists to prevent. Pinned here so a later
    // edit that re-inlines one of them has to come through this test — the
    // behavior itself is asserted in that module, in the `none` lane.
    try testing.expect(isStale("20260719-574fe0805", "20260730-e69d41755"));
    try testing.expect(!isStale("20260731-aaa", "20260730-e69d41755"));
    try testing.expect(stampIsNewer("20260730-aaa", "20260719-zzz"));
    try testing.expectEqualStrings(
        "20260730-e69d41755",
        parseVersionOutput("ghoztty-agent 20260730-e69d41755\r\n").?,
    );
    try testing.expectEqualStrings("<pre-versioned>", stampForLog(null));
}

test "decide: unknown never restarts, idle refreshes, live is left alone" {
    const bundled = "20260730-e69d41755";
    const old = "20260719-574fe0805";

    // Rule 1: an unreadable bundled binary is never grounds for a restart, no
    // matter how old the running agent looks.
    try testing.expectEqual(Action.none, decide(old, null, 0));
    try testing.expectEqual(Action.none, decide(null, null, 3));
    try testing.expectEqual(Action.none, decide(old, "", 0));

    // Current ⇒ nothing, at any session count.
    try testing.expectEqual(Action.none, decide(bundled, bundled, 0));
    try testing.expectEqual(Action.none, decide(bundled, bundled, 7));

    // Rule 2: newer running agent is left alone even when idle.
    try testing.expectEqual(Action.none, decide("20260801-zzz", bundled, 0));

    // Rule 3: idle refreshes, and ANY live session means hands off (T1056).
    // A single live session is the whole difference between a free upgrade and
    // destroying the user's work, and it is never worth a build-stamp gap.
    try testing.expectEqual(Action.refresh_now, decide(old, bundled, 0));
    try testing.expectEqual(Action.none, decide(old, bundled, 1));
    try testing.expectEqual(Action.none, decide(old, bundled, 12));

    // A pre-versioned agent takes the same two arms.
    try testing.expectEqual(Action.refresh_now, decide(null, bundled, 0));
    try testing.expectEqual(Action.none, decide(null, bundled, 2));
}

test "no build-stamp gap can ever produce a destructive restart of a live agent" {
    // THE T1056 invariant, enumerated rather than argued: whatever the stamps,
    // whatever the roster, whatever the generation — if the agent still owns a
    // live session, `evaluate` never asks for anything that ends it. The only
    // action it may reach there is `handoff_now`, which is the agent replacing
    // ITSELF with nothing lost.
    //
    // Mac reached this state through `agentIsStale` and tombstoned 95 sessions
    // on the 1.33.0 update. A test that pins the two arms individually would not
    // have caught a third arm being added; this one does.
    const stamps = [_]?[]const u8{ null, "", "dev", "20260719-aaa", "20260730-e69d41755", "20260801-zzz" };
    const bundles = [_]?[]const u8{ null, "", "dev", "20260730-e69d41755" };
    for (stamps) |r| for (bundles) |b| for ([_]usize{ 1, 2, 95 }) |live| {
        for ([_]bool{ false, true }) |capable| for ([_]usize{ 0, 1, live }) |legacy| {
            const d = evaluate(r, b, live, .{ .capable = capable, .legacy_live = legacy });
            try testing.expect(d.action == .none or d.action == .handoff_now);
        };
    };
}

test "evaluate: every .none carries the reason that produced it" {
    const bundled = "20260730-e69d41755";
    const old = "20260719-574fe0805";

    // The three states that all collapse to `.none` are told apart. This is the
    // whole point of T201: a log line saying only "nothing to do" cannot
    // distinguish "we couldn't read our own binary" from "all is well".
    const none: Handoff = .{};
    try testing.expectEqual(Reason.bundled_unknown, evaluate(old, null, 0, none).reason);
    try testing.expectEqual(Reason.bundled_unknown, evaluate(old, "", 0, none).reason);
    try testing.expectEqual(Reason.bundled_unknown, evaluate(null, null, 3, none).reason);
    try testing.expectEqual(Reason.current, evaluate(bundled, bundled, 0, none).reason);
    try testing.expectEqual(Reason.current, evaluate(bundled, bundled, 7, none).reason);
    try testing.expectEqual(Reason.running_newer, evaluate("20260801-zzz", bundled, 0, none).reason);
    try testing.expectEqual(Reason.running_newer, evaluate("20260801-zzz", bundled, 4, none).reason);

    // The two stale arms, including the pre-versioned peer. `stale_live_deferred`
    // is a `.none` like the three above it and must still be told apart from
    // them: "we are deliberately not touching a stale agent" and "there was
    // nothing wrong" are the two states an operator has to distinguish after
    // T1056, because only one of them means an update is still pending.
    try testing.expectEqual(Reason.stale_idle, evaluate(old, bundled, 0, none).reason);
    try testing.expectEqual(Reason.stale_live_deferred, evaluate(old, bundled, 1, none).reason);
    try testing.expectEqual(Action.none, evaluate(old, bundled, 1, none).action);
    try testing.expectEqual(Reason.stale_idle, evaluate(null, bundled, 0, none).reason);
    try testing.expectEqual(Reason.stale_live_deferred, evaluate(null, bundled, 9, none).reason);
    try testing.expectEqual(Reason.stale_live_deferred, evaluate("", bundled, 2, none).reason);
}

test "evaluate: a handoff-capable agent is never restarted out from under its sessions" {
    const bundled = "20260730-e69d41755";
    const old = "20260719-574fe0805";

    // THE arm this feature exists for (T907): stale, sessions live, and every
    // one of them holder-backed. The app does nothing — the agent replaces
    // itself and carries them across — and the reason says so, because "no
    // action" and "no action, mid-upgrade" are very different states to find a
    // box in.
    const ready: Handoff = .{ .capable = true, .legacy_live = 0 };
    try testing.expectEqual(Action.handoff_now, evaluate(old, bundled, 3, ready).action);
    try testing.expectEqual(Reason.stale_handoff, evaluate(old, bundled, 3, ready).reason);
    // A pre-versioned agent cannot be handoff-capable in practice, but the
    // policy must not depend on that: the capability is what decides.
    try testing.expectEqual(Action.handoff_now, evaluate(null, bundled, 1, ready).action);

    // Mixed generations: the handoff waits for the sessions the agent owns
    // directly, and nobody is asked to hurry it along (T1056 — the only way to
    // force it early was to end those sessions).
    const draining: Handoff = .{ .capable = true, .legacy_live = 2 };
    try testing.expectEqual(Action.none, evaluate(old, bundled, 5, draining).action);
    try testing.expectEqual(Reason.stale_handoff_draining, evaluate(old, bundled, 5, draining).reason);

    // Not capable ⇒ nothing happens either, and for the same reason: the agent
    // is compatible, so the gap costs nothing until the next cold start, and
    // closing it early would cost every live session.
    const incapable: Handoff = .{ .capable = false, .legacy_live = 0 };
    try testing.expectEqual(Action.none, evaluate(old, bundled, 3, incapable).action);
    try testing.expectEqual(Reason.stale_live_deferred, evaluate(old, bundled, 3, incapable).reason);

    // Idle still wins: nothing to lose, and a restart completes now rather than
    // at the agent's next poll.
    try testing.expectEqual(Action.refresh_now, evaluate(old, bundled, 0, ready).action);
    try testing.expectEqual(Reason.stale_idle, evaluate(old, bundled, 0, ready).reason);

    // And a current or newer agent is still left alone — the capability never
    // manufactures an upgrade there is no reason for.
    try testing.expectEqual(Action.none, evaluate(bundled, bundled, 3, ready).action);
    try testing.expectEqual(Action.none, evaluate("20260801-zzz", bundled, 3, ready).action);
}

test "decide is the pre-T907 policy, exactly" {
    // Every caller that has not been taught about handoffs — and every test
    // written before them — must get the old answers. The default `Handoff` is
    // what guarantees that, so it is pinned here rather than assumed.
    const bundled = "20260730-e69d41755";
    const old = "20260719-574fe0805";
    for ([_]usize{ 0, 1, 9 }) |live| {
        try testing.expectEqual(evaluate(old, bundled, live, .{}).action, decide(old, bundled, live));
    }
    try testing.expectEqual(Action.none, decide(old, bundled, 3));
}

test "evaluate and decide can never disagree" {
    // `decide` is a projection of `evaluate`, and the reasons map onto exactly
    // one action each — so a future edit that changes one without the other
    // fails here rather than in the field.
    const stamps = [_]?[]const u8{ null, "", "dev", "20260719-aaa", "20260730-e69d41755", "20260801-zzz" };
    const bundles = [_]?[]const u8{ null, "", "dev", "20260730-e69d41755" };
    const handoffs = [_]Handoff{
        .{},
        .{ .capable = true, .legacy_live = 0 },
        .{ .capable = true, .legacy_live = 3 },
        .{ .capable = false, .legacy_live = 3 },
    };
    for (stamps) |r| for (bundles) |b| for ([_]usize{ 0, 1, 5 }) |live| for (handoffs) |h| {
        const d = evaluate(r, b, live, h);
        if (!h.capable) try testing.expectEqual(decide(r, b, live), d.action);
        const expected: Action = switch (d.reason) {
            .bundled_unknown, .current, .running_newer => .none,
            .stale_idle => .refresh_now,
            .stale_live_deferred, .stale_handoff_draining => .none,
            .stale_handoff => .handoff_now,
            // `evaluate` is the STALENESS policy; a skew reason coming out of it
            // would mean the two policies had been crossed. `confirm_deferred`
            // is `applyDeferral`'s, applied on top afterwards — never produced
            // here.
            .skew_agent_older, .skew_app_older, .skew_unknown, .confirm_deferred => unreachable,
        };
        try testing.expectEqual(expected, d.action);
        // Staleness now decides the REASON, not the action: since T1056 three of
        // the stale reasons are themselves `.none`, so the old
        // "stale ⟺ something happens" equivalence would read the fix as a bug.
        // The equivalence that still has to hold is the one an operator relies
        // on — a stale agent is always REPORTED as stale, and a current one
        // never is.
        if (b) |bb| if (bb.len > 0) {
            const reported_stale = switch (d.reason) {
                .stale_idle, .stale_live_deferred, .stale_handoff, .stale_handoff_draining => true,
                else => false,
            };
            try testing.expectEqual(isStale(r, bb), reported_stale);
        };
    };
}

test "Reason.description is a distinct non-empty clause for every reason" {
    // Logged verbatim, so an empty or duplicated clause would silently make two
    // different box states read identically — the defect T201 exists to fix.
    // Enumerated from the type rather than by hand, so a reason added later
    // cannot slip past this without a clause of its own (T907 added two).
    const all = std.enums.values(Reason);
    for (all, 0..) |a, i| {
        try testing.expect(a.description().len > 0);
        for (all[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.description(), b.description()));
        }
    }
    // The two arms an operator greps for must say what they mean. T1056 changed
    // what the live-session arm means, so the clause has to change with it: it
    // is the "we are leaving it alone" line now, not a "confirmation required"
    // one, and a description still promising a dialog would send whoever greps
    // it looking for a modal that is never shown.
    try testing.expect(std.mem.indexOf(u8, Reason.stale_live_deferred.description(), "leaving it alone") != null);
    try testing.expect(std.mem.indexOf(u8, Reason.stale_live_deferred.description(), "confirmation") == null);
    try testing.expect(std.mem.indexOf(u8, Reason.running_newer.description(), "NEWER") != null);
    // A stale agent that the app is deliberately NOT touching must be
    // distinguishable in the log from one it found nothing wrong with (T907).
    try testing.expect(std.mem.indexOf(u8, Reason.stale_handoff.description(), "replacing itself") != null);
    try testing.expect(std.mem.indexOf(u8, Reason.stale_handoff_draining.description(), "close first") != null);
    try testing.expect(std.mem.indexOf(u8, Reason.stale_handoff_draining.description(), "confirmation") == null);
}

test "applyDeferral never suppresses a handoff" {
    // `handoff_now` asks nobody and loses nothing — exactly like `refresh_now`,
    // and for exactly the same reason. Deferring it during an unattended refresh
    // would suppress the one upgrade path that was designed to run unattended
    // (T525's directive is that the agent must not be RESTARTED, not that it
    // must not be upgraded).
    const d = Decision{ .action = .handoff_now, .reason = .stale_handoff };
    try testing.expectEqual(Action.handoff_now, applyDeferral(d, true).action);
    try testing.expectEqual(Reason.stale_handoff, applyDeferral(d, true).reason);

    // The draining arm is no longer a modal either (T1056), so there is nothing
    // left for the unattended deferral to suppress. Pinned so a re-introduced
    // dialog has to come through this test rather than appearing on an empty
    // desk during the morning refresh.
    const draining = Decision{ .action = .none, .reason = .stale_handoff_draining };
    try testing.expectEqual(Action.none, applyDeferral(draining, true).action);
    try testing.expectEqual(Reason.stale_handoff_draining, applyDeferral(draining, true).reason);
}

test "no staleness decision is left for the unattended deferral to suppress" {
    // T525 deferred the modal that a stale agent raised on a box nobody was
    // sitting at. T1056 removed the modal itself, so the deferral is now the
    // SKEW path's alone — and every decision `evaluate` can produce passes
    // through `applyDeferral` untouched, deferred or not. That is the property
    // worth pinning: it is what makes the morning refresh silent by
    // construction rather than by a marker file being present.
    const stamps = [_]?[]const u8{ null, "20260719-aaa", "20260801-zzz", "20260730-e69d41755" };
    const handoffs = [_]Handoff{
        .{},
        .{ .capable = true, .legacy_live = 0 },
        .{ .capable = true, .legacy_live = 3 },
    };
    for (stamps) |r| for ([_]usize{ 0, 1, 5 }) |live| for (handoffs) |h| {
        const d = evaluate(r, "20260730-e69d41755", live, h);
        try testing.expectEqual(d.action, applyDeferral(d, true).action);
        try testing.expectEqual(d.reason, applyDeferral(d, true).reason);
    };
}

test "evaluateSkew: the agent is only restarted when IT is the older side" {
    const local: u16 = 3;

    // The case the feature exists for: an agent left behind by an app upgrade.
    // Never silent — an unknown session count is not "no sessions".
    try testing.expectEqual(Action.confirm_first, evaluateSkew(2, local).action);
    try testing.expectEqual(Reason.skew_agent_older, evaluateSkew(2, local).reason);
    try testing.expectEqual(Action.confirm_first, evaluateSkew(0, local).action);

    // Rule 2 at its strongest: a NEWER agent is never killed to install an older
    // one, and the sessions a newer app could still attach to are never ended.
    try testing.expectEqual(Action.none, evaluateSkew(4, local).action);
    try testing.expectEqual(Reason.skew_app_older, evaluateSkew(4, local).reason);
    try testing.expectEqual(Action.none, evaluateSkew(std.math.maxInt(u16), local).action);

    // Rule 1: no HELLO parsed ⇒ no direction ⇒ nothing destructive.
    try testing.expectEqual(Action.none, evaluateSkew(null, local).action);
    try testing.expectEqual(Reason.skew_unknown, evaluateSkew(null, local).reason);

    // Equal versions still reached the skew path, so the disagreement was over
    // the transfer encoding the client proposed — the agent is the side that did
    // not understand it, and the restart is the same cure.
    try testing.expectEqual(Action.confirm_first, evaluateSkew(local, local).action);
    try testing.expectEqual(Reason.skew_agent_older, evaluateSkew(local, local).reason);
}

test "an app-older skew never acts, at any distance, deferred or not" {
    // The invariant the whole T626 notice rests on: this path is a REPORT.
    // A future policy edit that made it destructive would have to delete this
    // test to ship, which is the point of writing it as a sweep rather than a
    // single case.
    const local: u16 = 3;
    for ([_]u16{ 4, 5, 9, 99, 9999, 65535 }) |peer| {
        const d = evaluateSkew(peer, local);
        try testing.expectEqual(Action.none, d.action);
        try testing.expectEqual(Reason.skew_app_older, d.reason);
        // Deferral only ever suppresses a confirmation; it cannot promote a
        // `.none` into an act.
        try testing.expectEqual(Action.none, applyDeferral(d, true).action);
        try testing.expectEqual(Reason.skew_app_older, applyDeferral(d, true).reason);
    }
}

test "the app-older notice fits a tray balloon and names the act" {
    // NOTIFYICONDATAW caps the title at 64 UTF-16 units and the body at 256,
    // nul included, and `App.showTrayBalloon` DROPS anything longer rather than
    // truncating mid-rune — so text that overruns is a notice nobody ever sees.
    try testing.expect(app_older_notice_title.len < 64);
    try testing.expect(app_older_notice_body.len < 256);
    // The step the user can actually take, in the words they would use.
    try testing.expect(std.mem.indexOf(u8, app_older_notice_body, "update Ghoztty") != null);
    // And NOT the mechanism: a protocol number tells the user nothing they can
    // act on, which is the whole complaint this task was filed about.
    try testing.expect(std.mem.indexOf(u8, app_older_notice_body, "protocol") == null);
}

test "evaluateSkew never returns refresh_now" {
    // A skew has no idle arm on purpose: liveness lives inside the agent we
    // cannot talk to, so there is no state in which a silent destructive restart
    // is justified. Enumerated rather than argued, so a later edit that adds one
    // has to come through this test.
    var peer: u17 = 0;
    while (peer <= std.math.maxInt(u16)) : (peer += 1) {
        const d = evaluateSkew(@intCast(peer), 3);
        try testing.expect(d.action != .refresh_now);
    }
    try testing.expect(evaluateSkew(null, 3).action != .refresh_now);
}

test "formatSkewConfirmText names both versions, and drops the pair when unknown" {
    var buf: [1024]u8 = undefined;
    const known = try formatSkewConfirmText(&buf, 2, 3);
    try testing.expect(std.mem.indexOf(u8, known, "it speaks version 2, this app speaks 3") != null);

    var buf2: [1024]u8 = undefined;
    const unknown = try formatSkewConfirmText(&buf2, null, 3);
    // No parenthetical at all rather than a placeholder to decode.
    try testing.expect(std.mem.indexOf(u8, unknown, "(") == null);

    // Both arms must carry the cost AND the do-nothing outcome: the sessions are
    // unrecoverable either way, and the user is entitled to know that declining
    // is a real option before they agree to lose them.
    for ([_][]const u8{ known, unknown }) |text| {
        try testing.expect(std.mem.indexOf(u8, text, "cannot be carried across") != null);
        try testing.expect(std.mem.indexOf(u8, text, "If you do nothing") != null);
    }
}

test "the skew dialog keeps the mandatory-update title" {
    // The staleness path that shared it is gone (T1056), so this is now the only
    // caller — but the title stays put rather than being folded into the skew
    // module, because it is the string the acceptance harness identifies the
    // mandatory-update dialog by on screen.
    try testing.expectEqualStrings(confirm_title, skew_confirm_title);
}

test "parseDeferDeadline reads one integer and refuses everything else" {
    try testing.expectEqual(@as(?i64, 1786000000), parseDeferDeadline("1786000000"));
    // The writer is PowerShell's Set-Content, which appends a newline; CRLF too.
    try testing.expectEqual(@as(?i64, 1786000000), parseDeferDeadline("1786000000\n"));
    try testing.expectEqual(@as(?i64, 1786000000), parseDeferDeadline("1786000000\r\n"));
    try testing.expectEqual(@as(?i64, 1786000000), parseDeferDeadline("  1786000000  \r\n"));
    // A trailing human-readable line is ignored, so a future writer can explain
    // itself in the file without an older app misreading the deadline.
    try testing.expectEqual(
        @as(?i64, 1786000000),
        parseDeferDeadline("1786000000\n# written by upgrade-ghoztty-windows.ps1 -AppOnly\n"),
    );

    // Everything unreadable is null, NEVER a deadline: the direction that fails
    // silently is the one that suppresses the confirmation.
    try testing.expectEqual(@as(?i64, null), parseDeferDeadline(""));
    try testing.expectEqual(@as(?i64, null), parseDeferDeadline("   \r\n"));
    try testing.expectEqual(@as(?i64, null), parseDeferDeadline("later"));
    try testing.expectEqual(@as(?i64, null), parseDeferDeadline("17860000000000000000000"));
    // A BOM is the classic PowerShell 5.1 write; it must not read as a number.
    try testing.expectEqual(@as(?i64, null), parseDeferDeadline("\xEF\xBB\xBF1786000000"));
}

test "deferralActive: absent, malformed and expired markers never suppress" {
    const now: i64 = 1_786_000_000;
    // The steady state on every box that has never run an unattended refresh.
    try testing.expect(!deferralActive(null, now));
    try testing.expect(!deferralActive("", now));
    try testing.expect(!deferralActive("garbage", now));

    // Live: the delivery wrote a deadline a few minutes out.
    try testing.expect(deferralActive("1786000900", now));
    try testing.expect(deferralActive("1786000001", now));

    // Expired, including the exact boundary — a deadline that has arrived is
    // over, so a stopped clock cannot hold the confirmation off forever.
    try testing.expect(!deferralActive("1786000000", now));
    try testing.expect(!deferralActive("1785999999", now));
    // A marker left behind by a delivery days ago.
    try testing.expect(!deferralActive("1785000000", now));
}

test "applyDeferral suppresses only the modal, never the free upgrade" {
    const deferred_stale = Decision{ .action = .none, .reason = .stale_live_deferred };
    const skew_older = Decision{ .action = .confirm_first, .reason = .skew_agent_older };
    const idle = Decision{ .action = .refresh_now, .reason = .stale_idle };
    const nothing = Decision{ .action = .none, .reason = .current };

    // Not deferred ⇒ the decision is returned untouched, whatever it is.
    for ([_]Decision{ deferred_stale, skew_older, idle, nothing }) |d| {
        const out = applyDeferral(d, false);
        try testing.expectEqual(d.action, out.action);
        try testing.expectEqual(d.reason, out.reason);
    }

    // Deferred ⇒ the one remaining modal is suppressed, with a reason that says
    // so rather than pretending nothing was wrong. (Before T1056 a stale build
    // was a second route to the same dialog; it no longer raises one, so its
    // decision passes through untouched.)
    {
        const out = applyDeferral(skew_older, true);
        try testing.expectEqual(Action.none, out.action);
        try testing.expectEqual(Reason.confirm_deferred, out.reason);
    }
    try testing.expectEqual(Reason.stale_live_deferred, applyDeferral(deferred_stale, true).reason);

    // `refresh_now` asks nobody and loses nothing, so deferring it would trade a
    // free upgrade for no benefit at all. `none` has nothing to suppress.
    try testing.expectEqual(Action.refresh_now, applyDeferral(idle, true).action);
    try testing.expectEqual(Reason.stale_idle, applyDeferral(idle, true).reason);
    try testing.expectEqual(Action.none, applyDeferral(nothing, true).action);
    try testing.expectEqual(Reason.current, applyDeferral(nothing, true).reason);
}

test "applyDeferral is idempotent" {
    // The app composes it once, but a re-check on the same live marker must not
    // walk the decision somewhere else.
    const d = applyDeferral(.{ .action = .confirm_first, .reason = .skew_agent_older }, true);
    const again = applyDeferral(d, true);
    try testing.expectEqual(d.action, again.action);
    try testing.expectEqual(d.reason, again.reason);
}

test "baseName takes the last component with either separator" {
    try testing.expectEqualStrings("ghoztty-agent.exe", baseName("C:\\a b\\ghoztty-agent.exe"));
    try testing.expectEqualStrings("ghoztty-agent.exe", baseName("/tmp/ghoztty-agent.exe"));
    try testing.expectEqualStrings("ghoztty-agent.exe", baseName("ghoztty-agent.exe"));
    try testing.expectEqualStrings("", baseName("C:\\a\\"));
    try testing.expectEqualStrings("", baseName(""));
}

test "imageIsAgent accepts the agent by base name, case-insensitively" {
    try testing.expect(imageIsAgent(
        "C:\\Users\\d\\AppData\\Local\\Programs\\Ghoztty\\ghoztty-agent.exe",
        null,
    ));
    // Windows paths are case-insensitive and the loader reports whatever case
    // the caller used; a case difference must not read as a different program.
    try testing.expect(imageIsAgent("C:\\X\\GHOZTTY-AGENT.EXE", null));
    // A copy somewhere else is still the agent: the test harness runs one from
    // a temp dir, and the delivery runs one from the install dir.
    try testing.expect(imageIsAgent("D:\\tmp\\ghoztty-agent.exe", "C:\\p\\ghoztty-agent.exe"));
}

test "imageIsAgent accepts the agent the delivery renamed out of the way" {
    // THE production shape, not an edge case: `upgrade-ghoztty-windows.ps1`
    // renames the running agent's own image on every upgrade, because a running
    // exe cannot be deleted. A gate that missed this would refuse to replace any
    // agent that had ever been upgraded past — i.e. all of them.
    try testing.expect(imageIsAgent("C:\\p\\Ghoztty\\ghoztty-agent.exe.bak", null));
    try testing.expect(imageIsAgent("C:\\p\\Ghoztty\\ghoztty-agent.exe.bak-20260803-090358", null));
    // The acceptance harness's own rename (agent-upgrade.ps1 arm I).
    try testing.expect(imageIsAgent("C:\\t\\agentcopy\\ghoztty-agent.bak", null));
}

test "imageIsAgent refuses anything that is not the agent" {
    // The app itself. This is the one that matters: a stale pid that has been
    // recycled onto ghoztty.exe turns the refresh into a silent self-kill.
    try testing.expect(!imageIsAgent("C:\\p\\Ghoztty\\ghoztty.exe", null));
    try testing.expect(!imageIsAgent("C:\\Windows\\System32\\svchost.exe", null));
    // A PREFIX of the stem, not a substring of the name: a program that merely
    // ends in the agent's name is a different program.
    try testing.expect(!imageIsAgent("C:\\p\\my-ghoztty-agent.exe", null));
    try testing.expect(!imageIsAgent("C:\\p\\ghoztty-age.exe", null));
    // Nothing to compare against on either side.
    try testing.expect(!imageIsAgent("", null));
    try testing.expect(!imageIsAgent("C:\\p\\ghoztty-agent.exe", "C:\\p\\"));
}

test "imageIsAgent honors a relocated expected binary (GHOSTTY_LOCAL_AGENT_BIN)" {
    const expected = "D:\\build\\old-agent.exe";
    try testing.expect(imageIsAgent("D:\\build\\old-agent.exe", expected));
    try testing.expect(imageIsAgent("D:\\build\\old-agent.exe.bak", expected));
    try testing.expect(!imageIsAgent("D:\\build\\ghoztty-agent.exe", expected));
}
