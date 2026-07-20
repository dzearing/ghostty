//! Relay-brokered OAuth session client (T93 — the Zig counterpart to the
//! session client inside `macos/Sources/Features/Remote/GoogleOAuth.swift`,
//! wire contract in `relay/oauth.go`).
//!
//! In the brokered (BFF) model the app never talks to Google's token endpoint
//! and never sees the client secret or any Google token. It obtains the
//! authorization `code` locally (PKCE + loopback, `google_oauth.zig`), then:
//!
//! - `POST {base}/oauth/exchange` `{code, code_verifier, redirect_uri}` —
//!   the relay redeems the code with Google server-side, verifies + allowlists
//!   the id_token, stores the Google refresh token encrypted, and mints an
//!   opaque **relay session token** → `{session_token, expiry, email,
//!   picture?}`.
//! - `POST {base}/oauth/renew` (Bearer = session token) — the relay refreshes
//!   with Google behind the scenes, re-checks the allowlist, and ROTATES the
//!   session token → same response shape.
//! - `POST {base}/oauth/signout` (Bearer) — revokes the session and destroys
//!   the stored Google refresh token. Idempotent, best-effort from the app.
//!
//! The JSON parse and status→error mapping are pure and unit-tested in both
//! lanes; the live POSTs go through the shared `http_client.zig` (system-root
//! TLS for `https://`, plaintext for the loopback fake relay the E2E uses).

const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("http_client.zig");
const relay_directory = @import("relay_directory.zig");

const log = std.log.scoped(.relay_session);

/// Upper bound on an accepted session-response body (a few short strings).
const max_body_len = 1 << 16;

/// `{session_token, expiry, email, picture?}` as returned by the relay's
/// `/oauth/exchange` and `/oauth/renew` (Go `sessionResponse`). `expiry` is
/// unix seconds; `picture` is omitted when Google supplied none.
pub const Session = struct {
    session_token: []const u8,
    expiry: i64,
    email: []const u8,
    picture: ?[]const u8 = null,
};

pub const Parsed = std.json.Parsed(Session);

pub const Error = error{
    /// 401/403: the code/session was rejected (allowlist, revoked, expired
    /// past renewal, or the Google grant died). Remedy: sign in again.
    Unauthorized,
    /// 503: the relay has no brokered-oauth config (fail-closed server-side).
    Unavailable,
    /// Any other non-2xx.
    Http,
    /// A 2xx whose body was not a session response.
    BadResponse,
};

/// Map a session-endpoint HTTP status to `Error` (null = success). Pure.
pub fn classifyStatus(status: u16) ?Error {
    if (status >= 200 and status < 300) return null;
    return switch (status) {
        401, 403 => Error.Unauthorized,
        503 => Error.Unavailable,
        else => Error.Http,
    };
}

/// Parse a session-response body into an owned `Session` (strings copied into
/// the returned arena; caller `.deinit()`s). Malformed → `BadResponse`. Pure.
pub fn parseSession(alloc: Allocator, body: []const u8) error{ BadResponse, OutOfMemory }!Parsed {
    return std.json.parseFromSlice(Session, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadResponse,
    };
}

/// The JSON body for `/oauth/exchange`. Caller frees.
pub fn exchangeBody(
    alloc: Allocator,
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .code = code,
        .code_verifier = code_verifier,
        .redirect_uri = redirect_uri,
    }, .{});
}

/// `POST {base}/oauth/exchange`: redeem a locally-obtained authorization code
/// (+ PKCE verifier) for a relay session. Returns an owned parsed `Session`
/// (caller `.deinit()`s).
pub fn exchange(
    alloc: Allocator,
    relay_base: []const u8,
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
) !Parsed {
    const url = try relay_directory.joinUrl(alloc, relay_base, "oauth/exchange");
    defer alloc.free(url);
    const body = try exchangeBody(alloc, code, code_verifier, redirect_uri);
    defer alloc.free(body);

    var resp = try http_client.postJson(alloc, url, body);
    defer resp.deinit(alloc);
    if (classifyStatus(resp.status)) |err| {
        log.warn("oauth exchange: relay returned HTTP {d}: {s}", .{ resp.status, resp.body });
        return err;
    }
    return parseSession(alloc, resp.body);
}

/// `POST {base}/oauth/renew` with the current session token as Bearer. On
/// success the relay ROTATED the token — the caller must persist the returned
/// session (the old token is dead). Returns an owned parsed `Session`.
pub fn renew(alloc: Allocator, relay_base: []const u8, session_token: []const u8) !Parsed {
    const url = try relay_directory.joinUrl(alloc, relay_base, "oauth/renew");
    defer alloc.free(url);

    var resp = try http_client.postAuth(alloc, url, session_token, null);
    defer resp.deinit(alloc);
    if (classifyStatus(resp.status)) |err| {
        log.warn("oauth renew: relay returned HTTP {d}", .{resp.status});
        return err;
    }
    return parseSession(alloc, resp.body);
}

/// `POST {base}/oauth/signout` with the session token as Bearer. Best-effort:
/// all failures are swallowed (the server side is idempotent and revokes on
/// its own timeline; local sign-out must never be blocked by the network).
pub fn signout(alloc: Allocator, relay_base: []const u8, session_token: []const u8) void {
    const url = relay_directory.joinUrl(alloc, relay_base, "oauth/signout") catch return;
    defer alloc.free(url);
    var resp = http_client.postAuth(alloc, url, session_token, null) catch |err| {
        log.warn("oauth signout: unreachable ({}); local sign-out proceeds", .{err});
        return;
    };
    defer resp.deinit(alloc);
    if (classifyStatus(resp.status)) |_| {
        log.warn("oauth signout: relay returned HTTP {d}; local sign-out proceeds", .{resp.status});
    }
}

// =============================================================================
// Tests (pure layer — both lanes)
// =============================================================================

const testing = std.testing;

test "classifyStatus: 2xx success, 401/403 unauthorized, 503 unavailable, else http" {
    try testing.expect(classifyStatus(200) == null);
    try testing.expect(classifyStatus(204) == null);
    try testing.expectEqual(Error.Unauthorized, classifyStatus(401).?);
    try testing.expectEqual(Error.Unauthorized, classifyStatus(403).?);
    try testing.expectEqual(Error.Unavailable, classifyStatus(503).?);
    try testing.expectEqual(Error.Http, classifyStatus(400).?);
    try testing.expectEqual(Error.Http, classifyStatus(500).?);
}

test "parseSession: full response incl picture" {
    var parsed = try parseSession(testing.allocator,
        \\{"session_token":"tok-1","expiry":1893456000,"email":"a@b.com","picture":"https://x/y.png"}
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("tok-1", parsed.value.session_token);
    try testing.expectEqual(@as(i64, 1893456000), parsed.value.expiry);
    try testing.expectEqualStrings("a@b.com", parsed.value.email);
    try testing.expectEqualStrings("https://x/y.png", parsed.value.picture.?);
}

test "parseSession: picture omitted, unknown fields tolerated" {
    var parsed = try parseSession(testing.allocator,
        \\{"session_token":"tok-2","expiry":1,"email":"e","extra":true}
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.picture == null);
}

test "parseSession: malformed body is BadResponse" {
    try testing.expectError(error.BadResponse, parseSession(testing.allocator, "not json"));
    try testing.expectError(error.BadResponse, parseSession(testing.allocator,
        \\{"expiry":1,"email":"e"}
    ));
}

test "exchangeBody: exact wire shape" {
    const body = try exchangeBody(testing.allocator, "c0de", "veri-fier", "http://127.0.0.1:1234");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        \\{"code":"c0de","code_verifier":"veri-fier","redirect_uri":"http://127.0.0.1:1234"}
    , body);
}

test {
    testing.refAllDecls(@This());
}
