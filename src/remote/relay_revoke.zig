//! Sign-out revokes THIS machine (T1421 — the Windows half of main's
//! `0c3a19764` / `f3b1e5fb5`).
//!
//! ## Why this exists
//!
//! An account's **user session** and a machine's **device enrollment** are two
//! independent relay credentials, and `POST /oauth/signout` revokes only the
//! session. That is deliberate at the relay — an account may own headless hosts
//! that no app is signed in on — but it left a hole in the client: signing out
//! in the app running ON an enrolled machine left the machine listed, online and
//! bridgeable from every other client on the account, with live sessions still
//! visible through "See Activity". Sign-out looked like "this machine is no
//! longer mine" and wasn't.
//!
//! The rule, same as the Mac client's: **app sign-out is a hard revocation of
//! the machine the app runs on, when — and only when — that enrollment belongs
//! to the account signing out.**
//!
//! ## What is pure here
//!
//! Everything that decides. The network calls live in `relay_signin.signOut`,
//! which asks this module what to do with the answers it got. The decision has
//! four outcomes and each one is a different obligation:
//!
//!   - `.none` — this machine holds no device credential. Nothing to revoke;
//!     sign out locally and be done.
//!   - `.revoke` — the credential is bound to the account signing out.
//!     De-enroll it, then delete the local credential.
//!   - `.foreign` — the credential is bound to a DIFFERENT account. Leave it
//!     completely alone: it is somebody else's machine registration and this
//!     sign-out has no authority over it.
//!   - `.unknown` — there is a credential and the relay could not say whose it
//!     is. This is the one that must not be guessed. Treating it as `.none`
//!     silently reproduces the original bug; treating it as `.revoke` risks
//!     deleting a machine that belongs to another account. The caller reports a
//!     failure and STAYS SIGNED IN, because reporting "signed out" while the
//!     machine is still reachable is the bug itself.
//!
//! Identifying the enrollment by hostname was rejected on the Mac seat for the
//! same reason it is rejected here: hostnames collide, and the failure mode is
//! deleting somebody's other machine. The only identity that counts is what the
//! relay says the device token is bound to.

const std = @import("std");

/// What sign-out should do about this machine's device enrollment.
pub const Decision = enum {
    /// No local device credential — nothing to revoke.
    none,
    /// The credential belongs to the account signing out: de-enroll it.
    revoke,
    /// The credential belongs to a different account: leave it untouched.
    foreign,
    /// A credential exists and the relay could not say whose it is. Never
    /// guessed — the caller surfaces a failure and stays signed in.
    unknown,
};

/// The relay's answer about the local device credential, as the caller
/// obtained it. `null` means the question could not be answered at all
/// (`GET /v1/agent/whoami` failed, timed out, or returned a non-200).
pub const WhoamiAnswer = ?[]const u8;

/// The revocation rule, pure and testable.
///
/// - `credential_token`: the `DEVICE_TOKEN` line from relay.env, or null when
///   the file is missing, unreadable or carries no token.
/// - `whoami_email`: the account the relay says that token is bound to, or
///   null when the relay could not be asked.
/// - `account_email`: the account currently signing out.
///
/// Email comparison is ASCII case-insensitive: the relay echoes back whatever
/// spelling the identity provider used, and the account store holds whatever
/// spelling the sign-in returned. Those differ in practice, and a case
/// mismatch reading as `.foreign` would silently skip the revocation — the
/// exact failure this module exists to prevent.
pub fn decide(
    credential_token: ?[]const u8,
    whoami_email: WhoamiAnswer,
    account_email: []const u8,
) Decision {
    const token = credential_token orelse return .none;
    if (token.len == 0) return .none;

    const owner = whoami_email orelse return .unknown;
    // An empty email is an answer that names nobody, which tells us as little
    // as no answer at all. Do not let it read as a mismatch.
    if (owner.len == 0 or account_email.len == 0) return .unknown;

    return if (std.ascii.eqlIgnoreCase(owner, account_email)) .revoke else .foreign;
}

/// Which relay to aim the revocation at.
///
/// relay.env's `RELAY_BASE` is authoritative — it is the base the enrollment
/// was minted against and the one the agent dials — but it is a plain text
/// line a human can break. When it is missing or unusable, fall back to the
/// signing-out account's own relay rather than giving up: destroying the only
/// credential that could revoke the machine, or reporting the machine secured
/// because a line was malformed, are both worse than aiming at the relay this
/// app is talking to (`f3b1e5fb5` paid for that lesson on the Mac seat).
///
/// Returns null only when neither base is usable, which is the caller's cue to
/// report a failure rather than a success.
pub fn revocationBase(env_base: []const u8, account_base: []const u8) ?[]const u8 {
    if (isUsableBase(env_base)) return env_base;
    if (isUsableBase(account_base)) return account_base;
    return null;
}

/// Whether a base URL is one `http_client` can actually dial. relay.env
/// legitimately carries a `ws://` / `wss://` spelling (see
/// `relay_creds.baseMatches`, which strips all four schemes for exactly this
/// reason), and an HTTP client handed one of those fails every request in a
/// way that reads as "the relay is down" forever. Those two spellings are
/// usable — `normalizeBase` rewrites them — and anything else is not.
pub fn isUsableBase(base: []const u8) bool {
    const b = std.mem.trim(u8, base, " \t\r\n");
    if (b.len == 0) return false;
    inline for (.{ "https://", "http://", "wss://", "ws://" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(b, prefix)) {
            return b.len > prefix.len;
        }
    }
    return false;
}

/// Rewrite a relay base into a scheme `http_client` can dial: `wss://` becomes
/// `https://`, `ws://` becomes `http://`, and the http(s) spellings pass
/// through. Trailing slashes are trimmed so the caller can join a path onto it.
/// Allocates; caller frees.
pub fn normalizeBase(alloc: std.mem.Allocator, base: []const u8) ![]u8 {
    const b = std.mem.trim(u8, base, " \t\r\n");
    const rest, const scheme = blk: {
        if (std.ascii.startsWithIgnoreCase(b, "wss://")) break :blk .{ b["wss://".len..], "https://" };
        if (std.ascii.startsWithIgnoreCase(b, "ws://")) break :blk .{ b["ws://".len..], "http://" };
        if (std.ascii.startsWithIgnoreCase(b, "https://")) break :blk .{ b["https://".len..], "https://" };
        if (std.ascii.startsWithIgnoreCase(b, "http://")) break :blk .{ b["http://".len..], "http://" };
        return error.UnsupportedScheme;
    };
    const trimmed = std.mem.trimRight(u8, rest, "/");
    if (trimmed.len == 0) return error.UnsupportedScheme;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ scheme, trimmed });
}

/// The host part of a relay base for comparison: scheme stripped, surrounding
/// whitespace and trailing slashes trimmed. Accepts all four spellings, the
/// same set `relay_creds.baseMatches` strips — that helper lives in the agent
/// module, which drags the control-link machinery in with it, and this module
/// is on the app side.
fn hostPart(s: []const u8) []const u8 {
    var v = std.mem.trim(u8, s, " \t\r\n");
    inline for (.{ "wss://", "https://", "ws://", "http://" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(v, prefix)) v = v[prefix.len..];
    }
    return std.mem.trimRight(u8, v, "/");
}

/// Whether the local device credential was minted at the same relay this app's
/// account lives on. A mismatch is not an error — an account may legitimately
/// hold a machine enrolled elsewhere — but it is worth logging, and it is the
/// same host comparison `relay_creds.baseMatches` makes for the agent.
pub fn sameRelay(env_base: []const u8, account_base: []const u8) bool {
    return std.ascii.eqlIgnoreCase(hostPart(env_base), hostPart(account_base));
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

test "decide: no credential is nothing to revoke" {
    try testing.expectEqual(Decision.none, decide(null, "a@b.com", "a@b.com"));
    try testing.expectEqual(Decision.none, decide("", "a@b.com", "a@b.com"));
}

test "decide: the account's own machine is revoked" {
    try testing.expectEqual(Decision.revoke, decide("tok", "a@b.com", "a@b.com"));
}

test "decide: email case does not decide ownership" {
    // The relay echoes the identity provider's spelling; the account store
    // holds the sign-in's. A case mismatch reading as `.foreign` would silently
    // skip the revocation.
    try testing.expectEqual(Decision.revoke, decide("tok", "A@B.com", "a@b.COM"));
}

test "decide: another account's machine is left alone" {
    try testing.expectEqual(Decision.foreign, decide("tok", "other@b.com", "a@b.com"));
}

test "decide: an unanswerable relay is never guessed" {
    try testing.expectEqual(Decision.unknown, decide("tok", null, "a@b.com"));
}

test "decide: an answer naming nobody is not a mismatch" {
    // An empty email tells us as little as no answer at all. Reading it as
    // `.foreign` would skip the revocation on a relay that merely answered
    // badly.
    try testing.expectEqual(Decision.unknown, decide("tok", "", "a@b.com"));
    try testing.expectEqual(Decision.unknown, decide("tok", "a@b.com", ""));
}

test "isUsableBase: the four spellings relay.env legitimately carries" {
    try testing.expect(isUsableBase("https://relay.example"));
    try testing.expect(isUsableBase("http://127.0.0.1:8080"));
    try testing.expect(isUsableBase("wss://relay.example"));
    try testing.expect(isUsableBase("ws://127.0.0.1:8080"));
    try testing.expect(isUsableBase("  https://relay.example  "));
}

test "isUsableBase: rejects what cannot be dialed" {
    try testing.expect(!isUsableBase(""));
    try testing.expect(!isUsableBase("   "));
    try testing.expect(!isUsableBase("relay.example"));
    try testing.expect(!isUsableBase("ftp://relay.example"));
    try testing.expect(!isUsableBase("https://"));
}

test "revocationBase: relay.env wins when it is usable" {
    const got = revocationBase("wss://enrolled.example", "https://account.example");
    try testing.expectEqualStrings("wss://enrolled.example", got.?);
}

test "revocationBase: a broken RELAY_BASE falls back, it does not give up" {
    // f3b1e5fb5: an unparseable RELAY_BASE used to delete the credential and
    // report the machine secured. It isn't — the agent dials the base it was
    // STARTED with, so the machine stays perfectly reachable.
    const got = revocationBase("not-a-url", "https://account.example");
    try testing.expectEqualStrings("https://account.example", got.?);
    try testing.expectEqualStrings("https://account.example", revocationBase("", "https://account.example").?);
}

test "revocationBase: null only when neither base can be dialed" {
    try testing.expectEqual(@as(?[]const u8, null), revocationBase("nope", ""));
}

test "normalizeBase: the websocket spellings become dialable" {
    const alloc = testing.allocator;
    {
        const got = try normalizeBase(alloc, "wss://relay.example/");
        defer alloc.free(got);
        try testing.expectEqualStrings("https://relay.example", got);
    }
    {
        const got = try normalizeBase(alloc, "ws://127.0.0.1:8080");
        defer alloc.free(got);
        try testing.expectEqualStrings("http://127.0.0.1:8080", got);
    }
    {
        const got = try normalizeBase(alloc, "  https://relay.example//  ");
        defer alloc.free(got);
        try testing.expectEqualStrings("https://relay.example", got);
    }
}

test "normalizeBase: an undialable scheme is an error, not a guess" {
    try testing.expectError(error.UnsupportedScheme, normalizeBase(testing.allocator, "ftp://relay.example"));
    try testing.expectError(error.UnsupportedScheme, normalizeBase(testing.allocator, "relay.example"));
    try testing.expectError(error.UnsupportedScheme, normalizeBase(testing.allocator, "wss://"));
}

test "sameRelay: scheme spellings do not make two relays different" {
    try testing.expect(sameRelay("wss://relay.example", "https://relay.example/"));
    try testing.expect(!sameRelay("wss://relay.example", "https://other.example"));
}
