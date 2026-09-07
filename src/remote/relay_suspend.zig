//! Signing out SUSPENDS this machine's enrollment; signing back in restores it
//! (T1425 — the other half of main's `0c3a19764` / `f3b1e5fb5`).
//!
//! ## Why this exists
//!
//! T1421 made sign-out revoke this machine's device enrollment, which is the
//! security half and was the urgent one. What it left behind is the half a
//! user actually meets: their own computer vanished from the machine list on
//! every one of their other devices, and signing back in with the same account
//! did not bring it back. The only way home was to re-run the browser
//! enrollment by hand — a thing most people do not know exists. Sign-out was a
//! one-way door.
//!
//! So sign-out **suspends** rather than discards: it remembers the machine's
//! name and the relay it was enrolled at (`Record` — no secret; by the time it
//! is written the credential is dead or about to be), and a later sign-in with
//! the SAME account re-enrolls this machine through
//! `POST /v1/client/devices` and writes the fresh credential back to relay.env.
//! A running `ghoztty-agent` adopts a rewritten relay.env within one watcher
//! tick (`agent/relay_creds.zig`) and reconnects, so nothing has to be
//! restarted. That mirrors what sign-out/sign-in already do to the account's
//! remote WINDOWS, and it is what makes signing out a safe thing to do.
//!
//! ## The four refusals, and why each one is a refusal
//!
//!   - **A different account never inherits the machine.** The suspended
//!     record names its owner; anybody else signing in drops it unread rather
//!     than silently taking over the host.
//!   - **Restore is refused across relays.** A session on relay A cannot mint a
//!     device on relay B, and enrolling the machine somewhere new is the
//!     opposite of what sign-out promised. (Revocation makes the opposite
//!     trade — it acts on whatever relay the credential names — because
//!     failing safe there means revoking more, not less.)
//!   - **A credential that arrived meanwhile is never overwritten.** Somebody
//!     may have run `ghoztty-agent --enroll` while signed out; the machine is
//!     already enrolled and the record is simply dropped.
//!   - **A pending revocation is not cancelled on an email match alone.** This
//!     is `f3b1e5fb5`'s correction, and it is subtle: a revocation whose
//!     RESPONSE was lost is indistinguishable from one that failed, so an
//!     email-only cancel can leave a dead token in relay.env, the machine out
//!     of the account, and nothing left to notice. `pendingAction` re-asks the
//!     relay whose credential this is — confirmed alive cancels, confirmed dead
//!     drops the file and re-enrolls, and an unanswerable relay stays ARMED
//!     rather than guessing.
//!
//! ## Why the restore is retried at every launch, not only at sign-in
//!
//! A re-enroll can fail transiently (relay 5xx, the account at its device
//! limit, offline at that moment), and a machine that never comes back is not
//! something a user would think to fix by signing out and in again. So the
//! record survives the failure and `launchAsync` re-attempts it on every start
//! while signed in — which is why the Mac seat renamed its own
//! `restoreForSignIn` to `restoreEnrollment`. Idempotent and cheap: with
//! nothing suspended and nothing pending it is two small local reads and no
//! network.
//!
//! ## What is pure here
//!
//! The rules. `pendingAction` turns a credential probe into an obligation and
//! `restoreAction` decides whether a suspended record may be redeemed; both are
//! unit-tested in the `none` lane without a network or a real credential. The
//! record is JSON beside relay.env, exactly where `pending-revoke.json` lives
//! and for the same reason: `GHOSTTY_RELAY_ENV` carries the whole set into a
//! test's sandbox, so the two can never end up in different ones.

const std = @import("std");
const Allocator = std.mem.Allocator;
const enroll = @import("agent/enroll.zig");
const relay_account = @import("relay_account.zig");
const relay_directory = @import("relay_directory.zig");
const relay_revoke = @import("relay_revoke.zig");
const pending_revoke = @import("relay_revoke_pending.zig");
const atomic_write = @import("agent/atomic_write.zig");

const log = std.log.scoped(.relay_suspend);

/// A machine whose enrollment a sign-out revoked, remembered so the same
/// account signing back in gets its machine back.
///
/// It holds NO secret: the credential it describes is dead (or about to be),
/// and the retry that might still need a live one keeps it in relay.env where
/// it already was. That is why this file is not ACL-hardened the way
/// `pending-revoke.json` is — hardening it would imply it carries something
/// worth protecting, which would be a lie about its contents.
pub const Record = struct {
    /// The relay the machine was enrolled with (relay.env's `RELAY_BASE`).
    relay_base: []const u8,
    /// The device's display name, so the re-enrollment keeps its identity in
    /// the machine chooser rather than arriving as a stranger.
    ///
    /// Empty when the relay never told us — a sign-out forced through without
    /// a reachable relay knows the machine is enrolled and not what it is
    /// called. The restore falls back to this machine's hostname there, which
    /// is the name a fresh enrollment would have given it anyway.
    machine_name: []const u8 = "",
    /// The account that owned it. Only this account may restore it.
    owner_email: []const u8 = "",
    /// Unix seconds the record was written, for logging and support questions.
    suspended_at: i64 = 0,
};

/// A loaded record and the memory it points into.
pub const Loaded = struct {
    parsed: std.json.Parsed(Record),

    pub fn value(self: Loaded) Record {
        return self.parsed.value;
    }

    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
    }
};

// -----------------------------------------------------------------------------
// The rules (pure)
// -----------------------------------------------------------------------------

/// What the relay says about the device credential sitting in relay.env.
pub const CredentialState = enum {
    /// There is no local credential at all.
    absent,
    /// The relay confirms it, and it belongs to the account in hand.
    alive_ours,
    /// The relay confirms it, and it belongs to somebody else.
    alive_foreign,
    /// The relay says the credential is no longer a device (401).
    dead,
    /// The relay could not be asked, or answered nothing usable.
    unknown,
};

/// What a sign-in should do about a revocation that is still armed.
pub const PendingAction = enum {
    /// Nothing is armed. Carry on to the suspended-enrollment restore.
    proceed,
    /// The same account came back and its credential is confirmed ALIVE: the
    /// revocation is moot and so is the suspension. Clear both and stop — the
    /// machine never left.
    keep_machine,
    /// The same account came back and the revocation had in fact landed. Clear
    /// the record, drop the dead credential, and go on to re-enroll.
    reenroll,
    /// The same account came back and nothing is enrolled here. Clear the
    /// record and go on to restore.
    clear_and_restore,
    /// The answer is not knowable right now (unreachable relay), or the
    /// credential is somebody else's now. Stay armed and do nothing this pass;
    /// the launch and backoff retries settle it.
    stay_armed,
    /// A DIFFERENT account is signing in. The previous account's machine must
    /// go away before this one takes over the host — finish that revocation
    /// first, then restore.
    revoke_first,
};

/// The pending-revocation rule, pure.
///
/// `pending_email` is the account named by an armed record, or null when none
/// is armed. `state` is what a probe of relay.env's credential just learned.
///
/// The one branch worth reading twice is `.dead` on a same-account sign-in:
/// that is a revocation whose POST landed and whose response was lost, so the
/// user IS off the account and the honest repair is to re-enroll them, not to
/// pretend the machine was never revoked.
pub fn pendingAction(
    pending_email: ?[]const u8,
    account_email: []const u8,
    state: CredentialState,
) PendingAction {
    const pending = pending_email orelse return .proceed;
    if (pending.len == 0) return .proceed;
    if (!sameAccount(pending, account_email)) return .revoke_first;

    return switch (state) {
        .alive_ours => .keep_machine,
        .dead => .reenroll,
        .absent => .clear_and_restore,
        .alive_foreign, .unknown => .stay_armed,
    };
}

/// What a sign-in should do about a suspended enrollment.
pub const RestoreAction = enum {
    /// Nothing recorded — nothing to do.
    none,
    /// The record belongs to another account: drop it unread.
    wrong_account,
    /// The record was minted at a relay this app does not talk to: drop it
    /// rather than enrolling the machine somewhere new.
    wrong_relay,
    /// A credential is already on disk (a manual `--enroll` while signed out).
    /// The machine is enrolled; drop the record and leave it alone.
    already_enrolled,
    /// Re-enroll this machine and write the fresh credential.
    enroll,
};

/// The restore rule, pure.
///
/// `app_relay_base` is the relay THIS app is signed in to. `has_credential`
/// says whether relay.env already carries a device token.
pub fn restoreAction(
    rec: ?Record,
    account_email: []const u8,
    app_relay_base: []const u8,
    has_credential: bool,
) RestoreAction {
    const r = rec orelse return .none;
    if (!sameAccount(r.owner_email, account_email)) return .wrong_account;
    // An empty base on either side names no relay, and `sameRelay` would read
    // two empties as a match — which would enroll the machine at whatever the
    // app happens to be pointed at.
    if (r.relay_base.len == 0 or app_relay_base.len == 0) return .wrong_relay;
    if (!relay_revoke.sameRelay(r.relay_base, app_relay_base)) return .wrong_relay;
    if (has_credential) return .already_enrolled;
    return .enroll;
}

/// The name to enroll under: what the relay called this machine, falling back
/// to the hostname when the record never learned it. Pure; `host` is the
/// caller's already-read hostname (or null when even that is unavailable).
pub fn enrollName(rec: Record, host: ?[]const u8) ?[]const u8 {
    if (rec.machine_name.len > 0) return rec.machine_name;
    const h = host orelse return null;
    return if (h.len == 0) null else h;
}

/// Account comparison, ASCII case-insensitive for the same reason
/// `relay_revoke.decide` is: the relay echoes the identity provider's spelling
/// and the account store holds the sign-in's, and those differ in practice. A
/// case mismatch here would hand the user's own machine to the `wrong_account`
/// branch and delete the record.
fn sameAccount(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

// -----------------------------------------------------------------------------
// The record on disk
// -----------------------------------------------------------------------------

/// Where the record lives: beside relay.env, so `GHOSTTY_RELAY_ENV` carries it
/// into the same sandbox as the credential it describes. Owned by the caller.
pub fn recordPath(alloc: Allocator) ![]u8 {
    const env_path = try enroll.relayEnvPath(alloc);
    defer alloc.free(env_path);
    const dir = std.fs.path.dirname(env_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, "suspended-enrollment.json" });
}

/// Record a suspension. Atomic — a half-written record is a machine that can
/// never be restored.
pub fn record(alloc: Allocator, rec: Record) !void {
    const path = try recordPath(alloc);
    defer alloc.free(path);
    return recordAt(alloc, path, rec);
}

/// `record` at an explicit path. The path-taking form is what the tests drive:
/// the location derives from `GHOSTTY_RELAY_ENV`, and a test that mutated the
/// process environment to reach it would change the answer for every other
/// test in the lane.
pub fn recordAt(alloc: Allocator, path: []const u8, rec: Record) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, rec, .{});
    defer alloc.free(json);
    try atomic_write.writeChunks(alloc, path, &.{json}, .{});
    atomic_write.cleanStaging(path);
    log.info("suspended this machine's enrollment at {s}", .{rec.relay_base});
}

/// The recorded suspension, or null when there is none (or one that cannot be
/// read).
pub fn load(alloc: Allocator) ?Loaded {
    const path = recordPath(alloc) catch return null;
    defer alloc.free(path);
    return loadAt(alloc, path);
}

/// `load` from an explicit path.
pub fn loadAt(alloc: Allocator, path: []const u8) ?Loaded {
    const content = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return null;
    defer alloc.free(content);

    // `alloc_always` for the same reason the pending record uses it: std.json
    // hands back slices pointing INTO the source buffer, and `content` is
    // freed on the way out of this function.
    const parsed = std.json.parseFromSlice(Record, alloc, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        log.warn("the suspended-enrollment record is unreadable err={}", .{err});
        return null;
    };
    return .{ .parsed = parsed };
}

/// Whether a suspension is recorded.
pub fn isRecorded(alloc: Allocator) bool {
    var rec = load(alloc) orelse return false;
    defer rec.deinit();
    return true;
}

/// Delete the record. Best-effort — a missing one is success.
pub fn clear(alloc: Allocator) void {
    const path = recordPath(alloc) catch return;
    defer alloc.free(path);
    clearAt(path);
}

/// `clear` at an explicit path.
pub fn clearAt(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    atomic_write.cleanStaging(path);
}

/// Record a suspension only when nothing is recorded yet.
///
/// The forced sign-out path uses this: by the time the user reaches "Sign Out
/// Anyway" the `.revoke` attempt may already have written a record from the
/// relay's own answer, which names the machine properly. Overwriting that with
/// a hostname guess would lose the better name for no gain.
pub fn recordIfAbsent(alloc: Allocator, rec: Record) void {
    if (isRecorded(alloc)) return;
    record(alloc, rec) catch |err|
        log.warn("could not record the suspended enrollment err={}", .{err});
}

// -----------------------------------------------------------------------------
// The restore itself (network)
// -----------------------------------------------------------------------------

/// What one restore pass did.
pub const Outcome = enum {
    /// Nothing was pending and nothing was suspended.
    idle,
    /// A pending revocation is still unsettled; nothing else was attempted.
    still_armed,
    /// The machine never left the account — the pending revocation was moot.
    kept,
    /// The record was dropped without enrolling (wrong account, wrong relay,
    /// or a credential already on disk).
    dropped,
    /// This machine is enrolled again and relay.env carries the fresh
    /// credential.
    restored,
    /// The re-enroll was attempted and failed. The record stays for the next
    /// launch.
    enroll_failed,
};

/// Give this machine back to the signed-in account: settle any pending
/// revocation, then redeem a suspended enrollment. Network-bound — call it off
/// the GUI thread (`restoreAsync` is the app's entry point).
///
/// Best-effort in the safe direction: every failure leaves the machine
/// unenrolled and the record in place, so the next launch tries again.
pub fn restoreOnce(alloc: Allocator) Outcome {
    const path = relay_account.accountPath(alloc) catch return .idle;
    var account = relay_account.load(alloc, path) catch return .idle;
    defer account.deinit(alloc);
    if (account.email.len == 0) return .idle;

    return restoreFor(alloc, account.email, account.session_token, account.relay_base);
}

/// `restoreOnce` for an account already in hand — what `signIn` calls, so the
/// restore runs on the session it just minted rather than re-reading the store
/// it just wrote.
pub fn restoreFor(
    alloc: Allocator,
    account_email: []const u8,
    session_token: []const u8,
    account_relay_base: []const u8,
) Outcome {
    switch (settlePending(alloc, account_email)) {
        .keep => return .kept,
        .stop => return .still_armed,
        .carry_on => {},
    }
    return redeem(alloc, account_email, session_token, account_relay_base);
}

const PendingStep = enum { carry_on, keep, stop };

/// The pending-revocation half: probe the credential, ask `pendingAction`, act.
fn settlePending(alloc: Allocator, account_email: []const u8) PendingStep {
    var pending = pending_revoke.load(alloc) orelse return .carry_on;
    defer pending.deinit();
    const rec = pending.value();

    const state = probeCredential(alloc, account_email);
    switch (pendingAction(rec.account_email, account_email, state)) {
        .proceed => return .carry_on,
        .keep_machine => {
            pending_revoke.clear(alloc);
            clear(alloc);
            log.info("signed back in on this machine: the pending revocation is moot", .{});
            return .keep;
        },
        .reenroll => {
            // The revocation did land after all. Drop the dead credential and
            // fall through to the re-enroll below.
            pending_revoke.clear(alloc);
            enroll.clearLocalCredential(alloc);
            return .carry_on;
        },
        .clear_and_restore => {
            pending_revoke.clear(alloc);
            return .carry_on;
        },
        .stay_armed => {
            // Armed, and deliberately NOT retried from here. The retry is a
            // bare de-enroll of whatever relay.env holds, so racing it against
            // a user who has just signed back in on this machine can revoke the
            // machine they are sitting at - and nothing would restore it until
            // the next launch. Signing back in is the strongest evidence there
            // is that this machine is still theirs; the record survives, and
            // the next launch asks the question again with the relay reachable
            // (`launchAsync`: signed out, it retries; signed in, it probes).
            log.info("a pending revocation could not be settled at sign-in; leaving it armed", .{});
            return .stop;
        },
        .revoke_first => {
            // A different account is signing in: the previous account's
            // machine must go before this one takes over the host.
            _ = pending_revoke.retryOnce(alloc);
            return .carry_on;
        },
    }
}

/// Ask the relay who the local device credential belongs to.
///
/// `whoamiAnswer` rather than `whoami` on purpose: a nullable result collapses
/// "the relay says this bearer is not a device" into "the relay said nothing",
/// and those two must not be confused here. The first means the revocation
/// landed and the machine should be re-enrolled; the second means we know
/// nothing and must leave the record armed. Nothing in this path may MUTATE
/// the credential to find out - a de-enroll used as a probe would revoke the
/// machine of a user who is signing back in.
fn probeCredential(alloc: Allocator, account_email: []const u8) CredentialState {
    const env_path = enroll.relayEnvPath(alloc) catch return .unknown;
    defer alloc.free(env_path);
    var env = enroll.loadRelayEnv(alloc, env_path) catch return .unknown;
    defer env.deinit(alloc);

    const token = env.device_token orelse return .absent;
    if (token.len == 0) return .absent;

    const raw_base = env.relay_base orelse return .unknown;
    const base = relay_revoke.normalizeBase(alloc, raw_base) catch return .unknown;
    defer alloc.free(base);

    switch (enroll.whoamiAnswer(alloc, base, token)) {
        .dead => return .dead,
        .unknown => return .unknown,
        .ok => |w| {
            var who = w;
            defer who.deinit(alloc);
            if (who.email.len == 0) return .unknown;
            return if (sameAccount(who.email, account_email)) .alive_ours else .alive_foreign;
        },
    }
}

/// The suspended-enrollment half: decide, then re-enroll.
fn redeem(
    alloc: Allocator,
    account_email: []const u8,
    session_token: []const u8,
    account_relay_base: []const u8,
) Outcome {
    var loaded = load(alloc) orelse return .idle;
    defer loaded.deinit();
    const rec = loaded.value();

    const has_credential = blk: {
        const env_path = enroll.relayEnvPath(alloc) catch break :blk false;
        defer alloc.free(env_path);
        var env = enroll.loadRelayEnv(alloc, env_path) catch break :blk false;
        defer env.deinit(alloc);
        const tok = env.device_token orelse break :blk false;
        break :blk tok.len > 0;
    };

    switch (restoreAction(rec, account_email, account_relay_base, has_credential)) {
        .none => return .idle,
        .wrong_account => {
            log.info("a suspended enrollment belongs to another account; dropping it", .{});
            clear(alloc);
            return .dropped;
        },
        .wrong_relay => {
            log.info("the suspended enrollment is on another relay; not restoring it", .{});
            clear(alloc);
            return .dropped;
        },
        .already_enrolled => {
            log.info("this machine is already enrolled; dropping the suspension", .{});
            clear(alloc);
            return .dropped;
        },
        .enroll => {},
    }

    var host_buf: [256]u8 = undefined;
    const name = enrollName(rec, enroll.hostName(&host_buf)) orelse {
        log.warn("no name to restore this machine's enrollment under; dropping it", .{});
        clear(alloc);
        return .dropped;
    };

    const base = relay_revoke.normalizeBase(alloc, account_relay_base) catch {
        log.warn("the account's relay base is not dialable; leaving the suspension armed", .{});
        return .enroll_failed;
    };
    defer alloc.free(base);

    var enrolled = relay_directory.enrollDevice(alloc, base, session_token, name) catch |err| {
        // Deliberately kept: a 5xx, a device-limit refusal or a moment offline
        // must not cost the user their machine. The next launch retries.
        log.warn("could not restore this machine's enrollment err={}", .{err});
        return .enroll_failed;
    };
    defer enrolled.deinit();

    const env_path = enroll.relayEnvPath(alloc) catch return .enroll_failed;
    defer alloc.free(env_path);
    enroll.saveRelayEnv(alloc, env_path, rec.relay_base, enrolled.value.token) catch |err| {
        log.warn("re-enrolled but could not write relay.env err={}", .{err});
        return .enroll_failed;
    };

    clear(alloc);
    log.info("restored this machine's enrollment (device {s}) on sign-in", .{enrolled.value.id});
    return .restored;
}

// -----------------------------------------------------------------------------
// The driver
// -----------------------------------------------------------------------------

/// One restore at a time, however many times the app asks.
var running: std.atomic.Value(bool) = .init(false);

/// True while a restore is in flight.
pub fn isRestoring() bool {
    return running.load(.acquire);
}

/// Run `restoreOnce` on a detached thread. Safe to call from the GUI thread:
/// it asks two small local questions first and spawns nothing when the answer
/// to both is "nothing to do", which is every launch of a machine that has
/// never been signed out of.
pub fn restoreAsync(alloc: Allocator) void {
    if (!isRecorded(alloc) and !pending_revoke.isArmed(alloc)) return;
    if (running.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, restoreThread, .{}) catch |err| {
        running.store(false, .release);
        log.warn("could not start the enrollment restore err={}", .{err});
        return;
    };
    thread.detach();
}

fn restoreThread() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    _ = restoreOnce(arena_state.allocator());
    running.store(false, .release);
}

/// The launch entry point, and the ONE place that decides between the two
/// halves of this state machine.
///
/// Signed in, it restores (which settles a pending revocation itself, on the
/// probe rather than on an email match). Signed out, it is the T1424 retry.
/// They must not both run: a pending retry racing a restore could revoke the
/// very machine the user is signed in on, which is the failure `f3b1e5fb5`
/// describes as "signed back in and the machine was simply gone".
pub fn launchAsync(alloc: Allocator) void {
    const path = relay_account.accountPath(alloc) catch return;
    if (relay_account.isSignedIn(alloc, path)) {
        restoreAsync(alloc);
    } else {
        pending_revoke.retryAsync(alloc);
    }
}

// -----------------------------------------------------------------------------
// Tests (pure — the `none` lane)
// -----------------------------------------------------------------------------

const testing = std.testing;

test "pendingAction: nothing armed just proceeds" {
    try testing.expectEqual(PendingAction.proceed, pendingAction(null, "a@b.com", .absent));
    try testing.expectEqual(PendingAction.proceed, pendingAction("", "a@b.com", .absent));
}

test "pendingAction: the same account with a live credential keeps its machine" {
    try testing.expectEqual(
        PendingAction.keep_machine,
        pendingAction("a@b.com", "A@B.COM", .alive_ours),
    );
}

test "pendingAction: an email match alone does not cancel a revocation" {
    // `f3b1e5fb5`'s correction. The revocation may have LANDED with its
    // response lost, in which case cancelling on the email would leave a dead
    // token in relay.env, the machine out of the account, and nothing left to
    // notice it. A confirmed-dead credential is re-enrolled instead.
    try testing.expectEqual(
        PendingAction.reenroll,
        pendingAction("a@b.com", "a@b.com", .dead),
    );
}

test "pendingAction: an unanswerable relay stays armed rather than guessing" {
    try testing.expectEqual(
        PendingAction.stay_armed,
        pendingAction("a@b.com", "a@b.com", .unknown),
    );
    // Somebody else's credential now: not ours to conclude anything from.
    try testing.expectEqual(
        PendingAction.stay_armed,
        pendingAction("a@b.com", "a@b.com", .alive_foreign),
    );
}

test "pendingAction: nothing enrolled clears the record and restores" {
    try testing.expectEqual(
        PendingAction.clear_and_restore,
        pendingAction("a@b.com", "a@b.com", .absent),
    );
}

test "pendingAction: a different account revokes the old machine first" {
    for ([_]CredentialState{ .absent, .alive_ours, .alive_foreign, .dead, .unknown }) |s| {
        try testing.expectEqual(
            PendingAction.revoke_first,
            pendingAction("old@b.com", "new@b.com", s),
        );
    }
}

test "restoreAction: the same account gets its machine back" {
    const rec: Record = .{
        .relay_base = "wss://relay.example",
        .machine_name = "Winbox",
        .owner_email = "a@b.com",
    };
    try testing.expectEqual(
        RestoreAction.enroll,
        restoreAction(rec, "A@B.com", "https://relay.example", false),
    );
}

test "restoreAction: a different account never inherits the machine" {
    const rec: Record = .{ .relay_base = "https://relay.example", .owner_email = "a@b.com" };
    try testing.expectEqual(
        RestoreAction.wrong_account,
        restoreAction(rec, "other@b.com", "https://relay.example", false),
    );
    // An owner-less record names nobody, which is not a match for anybody.
    const anon: Record = .{ .relay_base = "https://relay.example" };
    try testing.expectEqual(
        RestoreAction.wrong_account,
        restoreAction(anon, "a@b.com", "https://relay.example", false),
    );
}

test "restoreAction: restore is refused across relays" {
    const rec: Record = .{ .relay_base = "https://relay-a.example", .owner_email = "a@b.com" };
    try testing.expectEqual(
        RestoreAction.wrong_relay,
        restoreAction(rec, "a@b.com", "https://relay-b.example", false),
    );
    // And two empty bases are not "the same relay": that would enroll the
    // machine at whatever this app happens to be pointed at.
    const empty: Record = .{ .relay_base = "", .owner_email = "a@b.com" };
    try testing.expectEqual(
        RestoreAction.wrong_relay,
        restoreAction(empty, "a@b.com", "", false),
    );
}

test "restoreAction: a credential that arrived meanwhile is never overwritten" {
    const rec: Record = .{ .relay_base = "https://relay.example", .owner_email = "a@b.com" };
    try testing.expectEqual(
        RestoreAction.already_enrolled,
        restoreAction(rec, "a@b.com", "https://relay.example", true),
    );
}

test "restoreAction: nothing recorded is nothing to do" {
    try testing.expectEqual(
        RestoreAction.none,
        restoreAction(null, "a@b.com", "https://relay.example", false),
    );
}

test "enrollName: the relay's name wins, the hostname is the fallback" {
    const named: Record = .{ .relay_base = "x", .machine_name = "Studio" };
    try testing.expectEqualStrings("Studio", enrollName(named, "winbox").?);

    const unnamed: Record = .{ .relay_base = "x" };
    try testing.expectEqualStrings("winbox", enrollName(unnamed, "winbox").?);
    try testing.expect(enrollName(unnamed, null) == null);
    try testing.expect(enrollName(unnamed, "") == null);
}

test "the record round-trips through disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "suspended-enrollment.json" });
    defer testing.allocator.free(path);

    try recordAt(testing.allocator, path, .{
        .relay_base = "wss://relay.example",
        .machine_name = "E2E Box",
        .owner_email = "a@b.com",
        .suspended_at = 1234,
    });

    var loaded = loadAt(testing.allocator, path).?;
    defer loaded.deinit();
    try testing.expectEqualStrings("wss://relay.example", loaded.value().relay_base);
    try testing.expectEqualStrings("E2E Box", loaded.value().machine_name);
    try testing.expectEqualStrings("a@b.com", loaded.value().owner_email);
    try testing.expectEqual(@as(i64, 1234), loaded.value().suspended_at);

    clearAt(path);
    try testing.expect(loadAt(testing.allocator, path) == null);
}

test "a record holds no credential" {
    // The point of the type, asserted rather than promised: nothing here is a
    // bearer token, which is why the file is not ACL-hardened.
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Record{
        .relay_base = "https://relay.example",
        .machine_name = "Winbox",
        .owner_email = "a@b.com",
    }, .{});
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "token") == null);
}

test {
    testing.refAllDecls(@This());
}
