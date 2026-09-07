//! Relay account sign-in / sign-out as a reusable flow (T141).
//!
//! This is the machinery that used to live inside the `+relay-login` /
//! `+relay-logout` CLI actions. Those verbs were **deleted** (T141): the Mac
//! client never had them — it signs in from the machine chooser's account row —
//! and the user's rule is that the CLI surface must not diverge per platform.
//! The flow itself is unchanged (T21a origin, T93 brokered model); only its
//! caller moved, from a short-lived CLI process to the win32 GUI, which drives
//! it on a detached thread and posts the outcome back to the message loop
//! (`MachineChooser.signInAsync`).
//!
//! ## The brokered flow (T93)
//! 1. PKCE verifier/challenge + a loopback listener (its port is the redirect).
//! 2. Open the system browser at Google's authorize endpoint; the user consents.
//! 3. The redirect lands on the loopback listener → authorization `code`.
//! 4. `POST {relay}/oauth/exchange {code, code_verifier, redirect_uri}` — the
//!    RELAY holds the client secret and redeems the code with Google
//!    server-side, then mints an opaque relay **session token**.
//! 5. Persist `{session_token, expiry, email, relay_base, picture?}` via
//!    `relay_account` (DPAPI-encrypted, owner-only DACL on Windows).
//!
//! No Google token and no client secret ever touches this machine. The client
//! id is public (it appears in the browser URL).
//!
//! Sign-out is the mirror, plus a revocation (T1421): it de-enrolls THIS
//! machine when the device credential in relay.env belongs to the account
//! signing out, then fires `POST {relay}/oauth/signout` at the relay that
//! minted the session and deletes the local store. A revocation that was
//! required and did not happen ABORTS the sign-out and leaves the account
//! signed in — see `signOut` and the pure rule in `relay_revoke.zig`.
//!
//! And it SUSPENDS rather than discards (T1425): the machine's name and relay
//! are remembered, so signing back in with the same account re-enrolls this
//! machine and writes the fresh credential to relay.env instead of leaving the
//! user to re-run browser enrollment by hand. `relay_suspend.zig` owns that
//! record and the rules for redeeming it; `signIn` calls into it rather than
//! blindly clearing the pending revocation it used to.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const google_oauth = @import("google_oauth.zig");
const relay_account = @import("relay_account.zig");
const relay_directory = @import("relay_directory.zig");
const relay_session = @import("relay_session.zig");
const enroll = @import("agent/enroll.zig");
const relay_revoke = @import("relay_revoke.zig");
const pending_revoke = @import("relay_revoke_pending.zig");
const relay_suspend = @import("relay_suspend.zig");

const log = std.log.scoped(.relay_signin);

/// How long to wait for the browser redirect before giving up. The user has to
/// complete a consent screen in there, so this is minutes, not seconds.
pub const default_timeout_ms: u32 = 300_000;

pub const Options = struct {
    /// The Google OAuth client id (public). Null ⇒ resolve from
    /// `GHOSTTY_GOOGLE_CLIENT_ID`, then the `-Dgoogle-client-id` bake.
    client_id: ?[]const u8 = null,
    /// The relay to sign in to. Null ⇒ `relay_directory.resolveBase`
    /// (`GHOSTTY_RELAY_BASE`, then the built-in default).
    relay_base: ?[]const u8 = null,
    /// Milliseconds to wait for the browser redirect.
    timeout_ms: u32 = default_timeout_ms,
};

pub const Error = error{
    /// This build carries no `-Dgoogle-client-id` and none was supplied.
    NoClientId,
    /// The loopback listener (the redirect target) could not be opened.
    LoopbackFailed,
    /// The user denied consent, or the redirect carried an error.
    Denied,
    /// The redirect did not belong to this attempt (CSRF guard tripped).
    StateMismatch,
    /// No redirect arrived within `timeout_ms`.
    Timeout,
    /// The relay refused the code (allowlist / revoked).
    Unauthorized,
    /// The relay has no brokered sign-in configured.
    RelayUnavailable,
    /// Any other exchange failure (transport, bad response).
    ExchangeFailed,
    /// The account store could not be written.
    StoreFailed,
    OutOfMemory,
};

/// A completed sign-in. `email` is allocated with the allocator passed to
/// `signIn` and owned by the caller.
pub const Outcome = struct {
    email: []const u8,
};

/// Makes this build resolve NO client id at all, exactly as if it had been
/// built without `-Dgoogle-client-id` and launched with no
/// `GHOSTTY_GOOGLE_CLIENT_ID` — so the unconfigured experience (T747: no
/// sign-in button, a sentence saying why) is measurable on a seat that HAS a
/// client id set up. Tests and automation only; same shape and spirit as
/// `GHOZTTY_ENROLL_NO_OPEN` below.
///
/// It exists because the alternative — a test that skips itself when the
/// checkout has a client id — is the reason T747 shipped: the unconfigured
/// path was unmeasured on every seat that had ever configured sign-in, which
/// is every seat that runs the rest of the suite. Windows cannot hold a
/// present-but-empty environment variable (setting one to "" deletes it), so
/// "no id" cannot be expressed through `GHOSTTY_GOOGLE_CLIENT_ID` itself.
pub const env_force_unconfigured = "GHOZTTY_RELAY_NO_CLIENT_ID";

/// Resolve the OAuth client id: explicit, then `GHOSTTY_GOOGLE_CLIENT_ID`,
/// then the id baked into this build. Null when the build carries none and
/// nothing was supplied. The returned slice may be allocated on `alloc` (env
/// case) or static (bake case) — arena-allocate and free everything at once.
pub fn resolveClientId(alloc: Allocator, explicit: ?[]const u8) ?[]const u8 {
    return resolveClientIdFrom(
        explicit,
        envNonEmpty(alloc, "GHOSTTY_GOOGLE_CLIENT_ID"),
        envFlag(alloc, env_force_unconfigured),
        build_config.google_client_id,
    );
}

/// The resolution order as pure logic, so every branch — the force-unconfigured
/// knob included — is testable in the `none` lane without mutating the process
/// environment (which the tests in this file must not do).
///
/// `force_unconfigured` suppresses the two AMBIENT sources (env id, bake) and
/// not an `explicit` argument: a caller that hands over an id has stated one,
/// and an environment variable silently overruling a function argument is a
/// worse surprise than the knob is worth. Nothing in the app passes one — the
/// GUI calls `signIn(.{})` — so the knob is total in practice.
fn resolveClientIdFrom(
    explicit: ?[]const u8,
    env_id: ?[]const u8,
    force_unconfigured: bool,
    baked: []const u8,
) ?[]const u8 {
    if (nonEmpty(explicit)) |v| return v;
    if (force_unconfigured) return null;
    if (nonEmpty(env_id)) |v| return v;
    return nonEmpty(baked);
}

/// Whether a sign-in can be STARTED at all: true when a client id resolves
/// (`GHOSTTY_GOOGLE_CLIENT_ID`, then the `-Dgoogle-client-id` bake). Mac's
/// `RelayAccount.isConfigured` (RelayAccount.swift:103), and the GUI asks it
/// for the same reason: a build carrying no client id can only ever answer
/// `Error.NoClientId`, so the chooser must say so instead of offering a button
/// whose every press fails (T747). Cheap — one env read, no network.
pub fn isConfigured(alloc: Allocator) bool {
    return resolveClientId(alloc, null) != null;
}

/// Run a full sign-in, blocking until the browser redirect lands (or
/// `timeout_ms` elapses), and persist the account store on success. Returns the
/// signed-in email, allocated on `alloc`.
///
/// BLOCKING and network-bound: never call this on the GUI thread — see
/// `MachineChooser.signInAsync`, which runs it on a detached thread.
///
/// `alloc` should be an arena: intermediate allocations (URL, redirect uri,
/// state, verifier) are not individually freed.
pub fn signIn(alloc: Allocator, opts: Options) Error!Outcome {
    const client_id = resolveClientId(alloc, opts.client_id) orelse return Error.NoClientId;
    const relay_base = nonEmpty(opts.relay_base) orelse
        (relay_directory.resolveBase(alloc) catch return Error.OutOfMemory);

    // The loopback listener must exist BEFORE the URL is built: its port is
    // the redirect target baked into the URL.
    var state_buf: [google_oauth.PKCE.base64UrlLen(16)]u8 = undefined;
    google_oauth.PKCE.randomToken(16, &state_buf);
    const state = try alloc.dupe(u8, &state_buf);

    var receiver = google_oauth.LoopbackReceiver.start(alloc, state) catch
        return Error.LoopbackFailed;
    defer receiver.deinit();
    const redirect_uri = try receiver.redirectUri(alloc);

    var verifier_buf: [google_oauth.PKCE.verifier_len]u8 = undefined;
    google_oauth.PKCE.generateVerifier(&verifier_buf);
    const verifier = try alloc.dupe(u8, &verifier_buf);
    var challenge_buf: [google_oauth.PKCE.challenge_len]u8 = undefined;
    google_oauth.PKCE.challenge(verifier, &challenge_buf);

    const auth_endpoint = envNonEmpty(alloc, "GHOSTTY_OAUTH_AUTH_ENDPOINT") orelse
        google_oauth.google_authorization_endpoint;
    const url = try google_oauth.authorizationURL(
        alloc,
        auth_endpoint,
        client_id,
        redirect_uri,
        state,
        &challenge_buf,
    );

    // Always log the URL, whether or not the browser opened: it is the only
    // recovery path when the default-browser launch fails, and it is what an
    // automated run (GHOZTTY_ENROLL_NO_OPEN) drives the redirect from. The URL
    // carries no secret — the PKCE verifier never leaves this process.
    log.info("relay sign-in: open this URL to sign in: {s}", .{url});
    _ = openBrowser(alloc, url);

    const code = receiver.waitForCode(opts.timeout_ms) catch |err| return switch (err) {
        error.Denied => Error.Denied,
        error.StateMismatch => Error.StateMismatch,
        error.Timeout => Error.Timeout,
        else => Error.ExchangeFailed,
    };

    var session = relay_session.exchange(alloc, relay_base, code, verifier, redirect_uri) catch |err| {
        log.warn("relay sign-in: exchange failed relay={s} err={}", .{ relay_base, err });
        return switch (err) {
            error.Unauthorized => Error.Unauthorized,
            error.Unavailable => Error.RelayUnavailable,
            error.OutOfMemory => Error.OutOfMemory,
            else => Error.ExchangeFailed,
        };
    };
    defer session.deinit();

    const path = relay_account.accountPath(alloc) catch return Error.StoreFailed;
    relay_account.save(alloc, path, .{
        .session_token = session.value.session_token,
        .expiry = session.value.expiry,
        .email = session.value.email,
        .relay_base = relay_base,
        .picture = session.value.picture,
    }) catch |err| {
        log.warn("relay sign-in: could not save the account err={}", .{err});
        return Error.StoreFailed;
    };

    // Signing in on this machine RE-ADOPTS it: any revocation still waiting to
    // be retried (T1424) is settled, and the enrollment this account suspended
    // when it signed out is restored (T1425), so the machine comes back to the
    // list on their other devices under its old name.
    //
    // Deliberately NOT a blind `pending_revoke.clear`, which is what this was.
    // A revocation whose response was lost is indistinguishable from one that
    // failed, so cancelling on the sign-in alone can leave a dead token in
    // relay.env, the machine out of the account, and nothing left to notice
    // (`f3b1e5fb5`). `restoreFor` re-asks the relay whose credential this is
    // and acts on the answer.
    //
    // Blocking and network-bound, which is fine here: `signIn` is already the
    // long, off-thread call this whole module is documented as.
    _ = relay_suspend.restoreFor(
        alloc,
        session.value.email,
        session.value.session_token,
        relay_base,
    );

    return .{ .email = try alloc.dupe(u8, session.value.email) };
}

/// How hard sign-out tries to revoke this machine's device enrollment (T1421).
pub const SignOutMode = enum {
    /// The normal path: revoke this machine's enrollment first, and ABORT the
    /// sign-out if a revocation that was required did not happen.
    revoke,
    /// "Sign Out Anyway": the user has been told the machine could not be
    /// revoked and chose to sign out regardless. No revocation is attempted —
    /// re-running the whole thing only makes them wait out the same timeouts
    /// twice (the Mac seat's `f3b1e5fb5` removed exactly that second pass).
    force,
};

/// What became of this machine's device enrollment during a sign-out.
pub const MachineOutcome = enum {
    /// There was nothing to revoke: no local device credential, or one that
    /// belongs to a different account and is therefore none of our business.
    nothing_to_revoke,
    /// The enrollment was revoked at the relay and the local credential
    /// deleted. The machine is gone from every other client on the account.
    revoked,
    /// A revocation was REQUIRED and did not happen. The local account store is
    /// untouched, so the user is still signed in — reporting "signed out" while
    /// the machine is still reachable is the bug this whole path exists to fix.
    not_revoked,
    /// The user signed out knowing the machine is still enrolled (`.force`).
    /// The revocation is ARMED, not abandoned (T1424): it is retried on a
    /// backoff and at every launch until the relay confirms it.
    left_enrolled,
};

pub const SignOutResult = struct {
    /// Whether an account was signed in when the sign-out started, so the
    /// caller can say "Signed out" vs "Already signed out".
    was_signed_in: bool,
    /// What happened to this machine's enrollment.
    machine: MachineOutcome,

    /// Whether the local account store was actually cleared. False only for
    /// `.not_revoked`, which deliberately leaves the user signed in.
    pub fn signedOut(self: SignOutResult) bool {
        return self.machine != .not_revoked;
    }
};

/// Sign out — and revoke THIS machine's device enrollment on the way (T1421).
///
/// An account's user session and a machine's device enrollment are two
/// independent relay credentials, and `POST /oauth/signout` revokes only the
/// session. Before this, signing out here left the machine listed, online and
/// bridgeable from every other client on the account, with live sessions still
/// visible through "See Activity". The rule now, matching the Mac client: app
/// sign-out is a hard revocation of the machine the app runs on, when — and
/// only when — that enrollment belongs to the account signing out.
/// `relay_revoke.decide` is that rule, and it is pure.
///
/// **Failure is never silent.** When a required revocation does not happen the
/// account stays SIGNED IN and the caller surfaces it; the user's way past that
/// is `.force`, which says so rather than pretending.
///
/// Network-bound (whoami + de-enroll + the session revoke): call from a
/// background thread when the caller is the GUI.
pub fn signOut(alloc: Allocator, mode: SignOutMode) SignOutResult {
    const path = relay_account.accountPath(alloc) catch
        return .{ .was_signed_in = false, .machine = .nothing_to_revoke };
    const was_signed_in = relay_account.isSignedIn(alloc, path);

    // A store that will not load (missing, corrupt, or a pre-T93 legacy one)
    // names no account, so there is nobody to match an enrollment against.
    // Sign out locally and leave the machine alone.
    var account = relay_account.load(alloc, path) catch {
        relay_account.delete(path);
        return .{ .was_signed_in = was_signed_in, .machine = .nothing_to_revoke };
    };
    defer account.deinit(alloc);

    const machine = switch (mode) {
        .force => forceOutcome(alloc, account),
        .revoke => revokeThisMachine(alloc, account) catch |err| blk: {
            log.warn("sign-out: could not revoke this machine err={}", .{err});
            break :blk .not_revoked;
        },
    };

    // The one outcome that must not complete the sign-out.
    if (machine == .not_revoked) {
        return .{ .was_signed_in = was_signed_in, .machine = machine };
    }

    // Fire-and-forget, deliberately (`f3b1e5fb5`): awaiting it makes a
    // signed-out-while-offline user wait out a request timeout for a call whose
    // failure is ignored either way.
    if (account.relay_base.len > 0) {
        relay_session.signout(alloc, account.relay_base, account.session_token);
    }
    relay_account.delete(path);

    // The unfinished revocation starts trying immediately, so a user who was
    // offline for a moment does not have to relaunch the app for their
    // sign-out to take effect (T1424).
    if (machine == .left_enrolled) pending_revoke.retryAsync(alloc);

    return .{ .was_signed_in = was_signed_in, .machine = machine };
}

/// `.force`: no revocation attempt right now — the user has already waited out
/// the failure once and re-running it only makes them wait again — but the
/// unfinished revocation is REMEMBERED so it completes itself later (T1424),
/// and the outcome still says honestly that a live enrollment is being left
/// behind for now.
///
/// Before T1424 this only reported. "Sign Out Anyway" told the user the machine
/// was still connected to the account and then never tried again, so the
/// machine stayed listed and reachable until they remembered to remove it by
/// hand from another computer — a security decision they had already made,
/// left depending on a chore nobody performs.
fn forceOutcome(alloc: Allocator, account: relay_account.Account) MachineOutcome {
    const env_path = enroll.relayEnvPath(alloc) catch return .nothing_to_revoke;
    defer alloc.free(env_path);
    var env = enroll.loadRelayEnv(alloc, env_path) catch return .nothing_to_revoke;
    defer env.deinit(alloc);
    const tok = env.device_token orelse return .nothing_to_revoke;
    if (tok.len == 0) return .nothing_to_revoke;

    // Aim the retry the same way the live revocation would have (relay.env's
    // base, falling back to the account's own relay), and store it normalized
    // so the retry never re-reads a relay.env the user may edit meanwhile.
    if (relay_revoke.revocationBase(env.relay_base orelse "", account.relay_base)) |raw_base| {
        if (relay_revoke.normalizeBase(alloc, raw_base)) |base| {
            defer alloc.free(base);
            pending_revoke.arm(alloc, .{
                .relay_base = base,
                .device_token = tok,
                .account_email = account.email,
                .armed_at = std.time.timestamp(),
            }) catch |err| log.warn("sign-out: could not arm the pending revocation err={}", .{err});
        } else |err| log.warn("sign-out: no dialable relay to retry the revocation at err={}", .{err});
    } else {
        log.warn("sign-out: no usable relay base to retry the revocation at", .{});
    }

    // A machine signed out of must come BACK when its owner signs back in
    // (T1425). The `.revoke` attempt that preceded this may already have
    // recorded a suspension from the relay's own answer, which names the
    // machine properly; this only covers the case where the relay never
    // answered at all, and it leaves the name empty rather than guessing —
    // the restore falls back to the hostname there.
    relay_suspend.recordIfAbsent(alloc, .{
        .relay_base = env.relay_base orelse account.relay_base,
        .owner_email = account.email,
        .suspended_at = std.time.timestamp(),
    });

    return .left_enrolled;
}

/// The `.revoke` path: ask relay.env what credential this machine holds, ask
/// the relay whose it is, and act on `relay_revoke.decide`'s answer.
fn revokeThisMachine(alloc: Allocator, account: relay_account.Account) !MachineOutcome {
    const env_path = try enroll.relayEnvPath(alloc);
    defer alloc.free(env_path);
    var env = enroll.loadRelayEnv(alloc, env_path) catch |err| {
        // The file exists and cannot be read. That is not "no enrollment" —
        // treating it as one is the original bug — so refuse to complete.
        log.warn("sign-out: relay.env unreadable err={}", .{err});
        return .not_revoked;
    };
    defer env.deinit(alloc);

    const token = env.device_token orelse return .nothing_to_revoke;
    if (token.len == 0) return .nothing_to_revoke;

    // Aim at relay.env's base; fall back to the account's own relay when that
    // line is missing or unusable, rather than destroying the one credential
    // that could revoke the machine.
    const raw_base = relay_revoke.revocationBase(
        env.relay_base orelse "",
        account.relay_base,
    ) orelse {
        log.warn("sign-out: no usable relay base to revoke this machine at", .{});
        return .not_revoked;
    };
    const base = relay_revoke.normalizeBase(alloc, raw_base) catch return .not_revoked;
    defer alloc.free(base);

    if (env.relay_base) |eb| {
        if (!relay_revoke.sameRelay(eb, account.relay_base)) {
            log.info("sign-out: this machine is enrolled at a different relay than the account", .{});
        }
    }

    var who = enroll.whoami(alloc, base, token);
    defer if (who) |*w| w.deinit(alloc);

    const decision = relay_revoke.decide(
        token,
        if (who) |w| w.email else null,
        account.email,
    );
    switch (decision) {
        .none => return .nothing_to_revoke,
        .foreign => {
            log.info("sign-out: this machine is enrolled to another account; leaving it alone", .{});
            return .nothing_to_revoke;
        },
        .unknown => {
            log.warn("sign-out: the relay could not say who this machine belongs to", .{});
            return .not_revoked;
        },
        .revoke => {
            // Record the suspension BEFORE the POST, not after (T1425). The
            // relay is about to delete the only record of this machine's name,
            // and if the response is lost we can never learn it again — the
            // retry sees a bare 401. Writing it first costs nothing when the
            // revocation fails: a suspension sitting beside a live credential
            // is self-healing, because the restore drops a record whose
            // machine turns out to be enrolled already.
            relay_suspend.record(alloc, .{
                .relay_base = env.relay_base orelse base,
                .machine_name = if (who) |w| w.name else "",
                .owner_email = account.email,
                .suspended_at = std.time.timestamp(),
            }) catch |err|
                log.warn("sign-out: could not record the suspended enrollment err={}", .{err});

            // Deletes the device row server-side and severs every live
            // connection — control and in-flight bridged data — then clears
            // the local credential so a restart cannot dial with it.
            enroll.deEnroll(alloc, base, token) catch |err| {
                log.warn("sign-out: de-enroll failed err={}", .{err});
                return .not_revoked;
            };
            // A revocation that completed makes any earlier armed retry moot —
            // and leaving one armed would keep a dead credential on disk.
            pending_revoke.clear(alloc);
            return .revoked;
        },
    }
}

/// The signed-in account's email, or null when signed out / legacy / corrupt.
/// Allocated on `alloc`. Cheap enough for the GUI thread: a decrypt + parse of
/// one small local file, no network.
pub fn signedInEmail(alloc: Allocator) ?[]const u8 {
    const path = relay_account.accountPath(alloc) catch return null;
    var account = relay_account.load(alloc, path) catch return null;
    defer account.deinit(alloc);
    return alloc.dupe(u8, account.email) catch null;
}

/// A short, user-facing sentence for a failed sign-in. Pure — unit-tested, and
/// the win32 chooser's footer hint renders it verbatim.
pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        Error.NoClientId => "This build has no Google sign-in configured.",
        Error.LoopbackFailed => "Couldn't open the local port the sign-in redirect needs.",
        Error.Denied => "Sign-in was not completed.",
        Error.StateMismatch => "That sign-in redirect didn't match this attempt.",
        Error.Timeout => "Timed out waiting for the browser sign-in.",
        Error.Unauthorized => "The relay rejected the sign-in (not on the allowlist?).",
        Error.RelayUnavailable => "That relay has no brokered sign-in configured.",
        Error.ExchangeFailed => "Sign-in failed — couldn't reach the relay.",
        Error.StoreFailed => "Signed in, but the account couldn't be saved.",
        Error.OutOfMemory => "Out of memory.",
    };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

fn envNonEmpty(alloc: Allocator, name: []const u8) ?[]const u8 {
    const v = std.process.getEnvVarOwned(alloc, name) catch return null;
    return if (v.len == 0) null else v;
}

/// A boolean environment knob, read the way the agent's kill switches are
/// (`handoff.zig`): set and not `"0"` is on.
fn envFlag(alloc: Allocator, name: []const u8) bool {
    const v = std.process.getEnvVarOwned(alloc, name) catch return false;
    defer alloc.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Open `url` in the default browser (best-effort). `GHOZTTY_ENROLL_NO_OPEN`
/// suppresses it for tests/automation, which then drive the loopback redirect
/// themselves from the logged URL.
fn openBrowser(alloc: Allocator, url: []const u8) bool {
    if (std.process.getEnvVarOwned(alloc, "GHOZTTY_ENROLL_NO_OPEN")) |v| {
        if (v.len > 0) return false;
    } else |_| {}

    const cmd = enroll.browserOpenCmd(builtin.os.tag, url);
    var child = std.process.Child.init(cmd.argv(), alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    // Deliberately NOT waited (same reasoning as `enroll.openBrowser`): the
    // opener normally returns immediately, but a misconfigured one can block
    // until the browser closes — which would stall the sign-in thread past the
    // redirect it is waiting for. One unreaped opener per sign-in is the
    // cheaper leak, and sign-in is a once-per-token-lifetime user action.
    return true;
}

// ---------------------------------------------------------------------
// Tests (pure logic — both lanes)
// ---------------------------------------------------------------------

const testing = std.testing;

test "resolveClientId: explicit wins, empty is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("cid-x", resolveClientId(alloc, "cid-x").?);
    // An empty explicit id is treated as absent, so it falls through to
    // env/bake. Whatever that resolves to on this machine, it must NOT be the
    // empty string masquerading as an id.
    if (resolveClientId(alloc, "")) |v| try testing.expect(v.len > 0);
}

test "resolveClientIdFrom: env id beats the bake, bake is the fallback" {
    try testing.expectEqualStrings("cid-env", resolveClientIdFrom(null, "cid-env", false, "cid-bake").?);
    try testing.expectEqualStrings("cid-bake", resolveClientIdFrom(null, null, false, "cid-bake").?);
    try testing.expectEqualStrings("cid-bake", resolveClientIdFrom(null, "", false, "cid-bake").?);
    try testing.expect(resolveClientIdFrom(null, null, false, "") == null);
}

test "resolveClientIdFrom: force-unconfigured hides env id AND bake" {
    // The point of the knob (T918): a seat WITH a client id configured both
    // ways must still be able to observe the no-client-id experience.
    try testing.expect(resolveClientIdFrom(null, "cid-env", true, "cid-bake") == null);
    try testing.expect(resolveClientIdFrom(null, null, true, "cid-bake") == null);
    try testing.expect(resolveClientIdFrom(null, "cid-env", true, "") == null);

    // An explicit id is a caller's statement, not an ambient source, so the
    // knob leaves it alone (documented on `resolveClientIdFrom`).
    try testing.expectEqualStrings("cid-x", resolveClientIdFrom("cid-x", null, true, "cid-bake").?);
}

test "errorMessage: every error has a distinct non-empty sentence" {
    const errs = [_]Error{
        Error.NoClientId,       Error.LoopbackFailed, Error.Denied,
        Error.StateMismatch,    Error.Timeout,        Error.Unauthorized,
        Error.RelayUnavailable, Error.ExchangeFailed, Error.StoreFailed,
        Error.OutOfMemory,
    };
    for (errs, 0..) |a, i| {
        const msg_a = errorMessage(a);
        try testing.expect(msg_a.len > 0);
        for (errs[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, msg_a, errorMessage(b)));
        }
    }
}

test "signOut: signed out already reports false and leaves no store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Point the store at a path that does not exist. `accountPath` honors
    // GHOSTTY_ACCOUNT_STORE, but tests must not mutate the process env, so
    // this only asserts the no-store branch of the real resolved path when the
    // machine has no account — skip when the box IS signed in.
    const path = relay_account.accountPath(alloc) catch return;
    if (relay_account.isSignedIn(alloc, path)) return;
    const res = signOut(alloc, .revoke);
    try testing.expect(res.was_signed_in == false);
    try testing.expect(res.signedOut());
}
