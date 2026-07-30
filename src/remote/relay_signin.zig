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
//! Sign-out is the mirror: best-effort `POST {relay}/oauth/signout` at the
//! relay that minted the session, then delete the local store. An unreachable
//! relay never blocks the local sign-out.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const google_oauth = @import("google_oauth.zig");
const relay_account = @import("relay_account.zig");
const relay_directory = @import("relay_directory.zig");
const relay_session = @import("relay_session.zig");
const enroll = @import("agent/enroll.zig");

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

/// Resolve the OAuth client id: explicit, then `GHOSTTY_GOOGLE_CLIENT_ID`,
/// then the id baked into this build. Null when the build carries none and
/// nothing was supplied. The returned slice may be allocated on `alloc` (env
/// case) or static (bake case) — arena-allocate and free everything at once.
pub fn resolveClientId(alloc: Allocator, explicit: ?[]const u8) ?[]const u8 {
    if (nonEmpty(explicit)) |v| return v;
    if (envNonEmpty(alloc, "GHOSTTY_GOOGLE_CLIENT_ID")) |v| return v;
    return nonEmpty(build_config.google_client_id);
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

    return .{ .email = try alloc.dupe(u8, session.value.email) };
}

/// Sign out: best-effort revoke the session at the relay that minted it, then
/// delete the local store. Returns whether an account was actually signed in
/// (so the caller can say "Signed out" vs "Already signed out"). Never fails —
/// an unreachable relay or a legacy/corrupt store still signs out locally.
///
/// Network-bound (the revoke POST): call from a background thread when the
/// caller is the GUI.
pub fn signOut(alloc: Allocator) bool {
    const path = relay_account.accountPath(alloc) catch return false;
    const was_signed_in = relay_account.isSignedIn(alloc, path);

    if (relay_account.load(alloc, path)) |acct| {
        var account = acct;
        defer account.deinit(alloc);
        if (account.relay_base.len > 0) {
            relay_session.signout(alloc, account.relay_base, account.session_token);
        }
    } else |_| {}

    relay_account.delete(path);
    return was_signed_in;
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
    try testing.expect(signOut(alloc) == false);
}
