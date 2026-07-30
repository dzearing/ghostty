//! Non-destructive local-agent upgrade policy (T147) — the win32 port of the
//! Mac `LocalAgentManager` staleness detection + lazy refresh (`c6ad0fc07`).
//!
//! The `ghoztty-agent` outlives the app on purpose: the upgrade script swaps
//! `ghoztty-agent.exe` on disk WITHOUT killing the running agent (T89h), because
//! killing it is exactly the silent session reset CLAUDE.md's "Agent contract &
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
//!  3. **Live sessions are never reset silently.** Zero live panes ⇒ refresh
//!     immediately (nothing to lose). One or more ⇒ a mandatory confirmation
//!     first, and a decline means the agent refreshes at the next quiet moment
//!     instead — which is why the check is re-run when the last persistent
//!     window closes, not just at launch.

const std = @import("std");

/// The build stamp the agent bakes and prints: `YYYYMMDD-<git short hash>`, or
/// the literal `dev` when git was unavailable at build time.
///
/// Parses `ghoztty-agent --version` output ("ghoztty-agent 20260730-e69d41755")
/// into just the stamp: the LAST whitespace-separated token of the first
/// non-empty line. Returns a slice INTO `out` (no allocation), or null when
/// there is no such token — an empty or whitespace-only output is "unknown",
/// which rule 1 turns into "don't judge".
pub fn parseVersionOutput(out: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        var last: ?[]const u8 = null;
        while (it.next()) |tok| last = tok;
        return last;
    }
    return null;
}

/// The `YYYYMMDD` date prefix of a stamp as a number, or 0 when it has none
/// (`dev`, or any stamp shape we don't recognize). 0 compares as "no opinion".
fn datePrefix(stamp: []const u8) u64 {
    var n: u64 = 0;
    var digits: usize = 0;
    for (stamp) |c| {
        if (!std.ascii.isDigit(c)) break;
        // A stamp with an absurd digit run is not a date; stop rather than
        // overflow.
        if (digits >= 18) break;
        n = n * 10 + (c - '0');
        digits += 1;
    }
    return if (digits == 0) 0 else n;
}

/// True iff stamp `a` is a NEWER build than `b`, ordered by the `YYYYMMDD`
/// prefix. Equal (or unparseable) dates ⇒ false, so an equal or unknown date
/// never *blocks* a refresh — stamp equality decides that — while a genuinely
/// newer running agent is never downgraded (rule 2).
pub fn stampIsNewer(a: []const u8, b: []const u8) bool {
    return datePrefix(a) > datePrefix(b);
}

/// Is the connected agent an OLDER build than the one this app ships beside?
///
/// `running == null` ⇒ an agent too old to advertise a stamp in its HELLO ⇒
/// stale (it predates the whole feature). Exact match ⇒ current. Newer than
/// bundled ⇒ NOT stale (rule 2).
pub fn isStale(running: ?[]const u8, bundled: []const u8) bool {
    const r = running orelse return true;
    if (r.len == 0) return true;
    if (std.mem.eql(u8, r, bundled)) return false;
    if (stampIsNewer(r, bundled)) return false;
    return true;
}

/// What the app should do about the agent it is connected to.
pub const Action = enum {
    /// Nothing: current, newer, or not knowable.
    none,
    /// Restart the agent now, silently (no live sessions to lose). Logged, but
    /// never a modal — there is nothing for the user to decide.
    refresh_now,
    /// Restart only after a mandatory confirmation: live sessions WILL close.
    confirm_first,
};

/// The whole policy in one pure function. `bundled == null` is "we could not
/// read the binary we ship" (rule 1).
pub fn decide(running: ?[]const u8, bundled: ?[]const u8, live_sessions: usize) Action {
    const b = bundled orelse return .none;
    if (b.len == 0) return .none;
    if (!isStale(running, b)) return .none;
    return if (live_sessions == 0) .refresh_now else .confirm_first;
}

/// The mandatory-confirmation body, Mac's wording (`makeUpgradeAlert`) with the
/// session count pluralized. Written into `buf`; the caller widens it to UTF-16
/// for the dialog.
pub fn formatConfirmText(buf: []u8, live_sessions: usize) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty keeps your terminal sessions running in the background. " ++
            "Finishing this update restarts that background process, which will " ++
            "close your {d} open terminal session{s} — they can't be carried " ++
            "across the update.\n\n" ++
            "You can keep working instead: Ghoztty updates automatically the " ++
            "next time no sessions are open.",
        .{ live_sessions, if (live_sessions == 1) "" else "s" },
    );
}

/// Title for the same dialog.
pub const confirm_title = "Restart the Ghoztty background terminal process?";

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "parseVersionOutput: the stamp is the last token of the first real line" {
    try testing.expectEqualStrings(
        "20260730-e69d41755",
        parseVersionOutput("ghoztty-agent 20260730-e69d41755\n").?,
    );
    // CRLF is the norm when the child writes through a Windows console.
    try testing.expectEqualStrings(
        "20260730-e69d41755",
        parseVersionOutput("ghoztty-agent 20260730-e69d41755\r\n").?,
    );
    // A leading blank line (or leading spaces) doesn't hide the stamp.
    try testing.expectEqualStrings("dev", parseVersionOutput("\n\n  ghoztty-agent dev  \n").?);
    // Trailing noise lines never win over the first real one.
    try testing.expectEqualStrings(
        "20260101-abcdef012",
        parseVersionOutput("ghoztty-agent 20260101-abcdef012\nsome warning\n").?,
    );
    // No output at all ⇒ unknown, not a crash and not an empty stamp.
    try testing.expect(parseVersionOutput("") == null);
    try testing.expect(parseVersionOutput("   \r\n\t\n") == null);
}

test "stampIsNewer orders by the date prefix only" {
    try testing.expect(stampIsNewer("20260730-aaa", "20260719-zzz"));
    try testing.expect(!stampIsNewer("20260719-zzz", "20260730-aaa"));
    // Same date, different hash ⇒ not newer (equality is the caller's business).
    try testing.expect(!stampIsNewer("20260730-aaa", "20260730-bbb"));
    // A dateless stamp has no opinion in either direction against another
    // dateless one, and always loses to a dated one.
    try testing.expect(!stampIsNewer("dev", "dev"));
    try testing.expect(!stampIsNewer("dev", "20260101-a"));
    try testing.expect(stampIsNewer("20260101-a", "dev"));
}

test "isStale: pre-versioned is stale, newer is not, exact match is current" {
    // An agent too old to advertise a stamp predates this feature ⇒ stale.
    try testing.expect(isStale(null, "20260730-e69d41755"));
    try testing.expect(isStale("", "20260730-e69d41755"));
    // Exact match: the common steady state.
    try testing.expect(!isStale("20260730-e69d41755", "20260730-e69d41755"));
    // The defect T147 exists for: an agent from an earlier delivery.
    try testing.expect(isStale("20260719-574fe0805", "20260730-e69d41755"));
    // Same day, different build ⇒ still stale (any agent-side change counts,
    // including fixes that bump no protocol version).
    try testing.expect(isStale("20260730-aaaaaaaaa", "20260730-e69d41755"));
    // Rule 2: never downgrade a newer running agent.
    try testing.expect(!isStale("20260731-aaaaaaaaa", "20260730-e69d41755"));
}

test "decide: unknown never restarts, idle refreshes, live always confirms" {
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

    // Rule 3: the two stale arms.
    try testing.expectEqual(Action.refresh_now, decide(old, bundled, 0));
    try testing.expectEqual(Action.confirm_first, decide(old, bundled, 1));
    try testing.expectEqual(Action.confirm_first, decide(old, bundled, 12));

    // A pre-versioned agent takes the same two arms.
    try testing.expectEqual(Action.refresh_now, decide(null, bundled, 0));
    try testing.expectEqual(Action.confirm_first, decide(null, bundled, 2));
}

test "formatConfirmText pluralizes and names the count" {
    var buf: [512]u8 = undefined;
    const one = try formatConfirmText(&buf, 1);
    try testing.expect(std.mem.indexOf(u8, one, "your 1 open terminal session —") != null);
    try testing.expect(std.mem.indexOf(u8, one, "sessions —") == null);

    var buf2: [512]u8 = undefined;
    const many = try formatConfirmText(&buf2, 4);
    try testing.expect(std.mem.indexOf(u8, many, "your 4 open terminal sessions —") != null);

    // The "you can defer" half is what makes the dialog honest about the
    // decline path; it must never be dropped.
    try testing.expect(std.mem.indexOf(u8, many, "next time no sessions are open") != null);
}
