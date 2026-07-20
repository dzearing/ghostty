//! The browser-facing half of the Google OAuth 2.0 authorization-code + PKCE
//! flow (T21a origin; slimmed by T93 — the Zig analog of
//! `macos/Sources/Features/Remote/GoogleOAuth.swift`).
//!
//! This is the headlessly-testable machinery a `+relay-login` CLI drives:
//!
//! - PKCE verifier/challenge generation (RFC 7636, S256)
//! - the authorization URL builder (the browser still goes to Google)
//! - a loopback redirect receiver (`http://127.0.0.1:<random port>` — the
//!   redirect style Google supports for **Desktop app** OAuth clients, no
//!   registered redirect URI needed)
//!
//! Since T93 (relay-brokered OAuth) the flow STOPS at the authorization code:
//! the code + PKCE verifier go to the relay's `/oauth/exchange`
//! (`relay_session.zig`), which holds the client secret, talks to Google's
//! token endpoint server-side, and mints an opaque relay session token. No
//! Google token ever reaches this client.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Google's authorization endpoint — where the sign-in browser tab goes. The
/// E2E injects a fake via `GHOSTTY_OAUTH_AUTH_ENDPOINT` (resolved by the CLI,
/// not here).
pub const google_authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth";

// =============================================================================
// PKCE (RFC 7636)
// =============================================================================

pub const PKCE = struct {
    /// The `code_verifier` length once base64url-encoded (32 random bytes →
    /// 43 chars, within the RFC's 43–128 bound, all unreserved characters).
    pub const verifier_len = base64UrlLen(32);
    /// The `code_challenge` length (SHA-256 → 32 bytes → 43 chars).
    pub const challenge_len = base64UrlLen(32);

    /// A fresh, high-entropy `code_verifier` written into `out`
    /// (`out.len == verifier_len`). 32 CSPRNG bytes, unpadded base64url.
    pub fn generateVerifier(out: *[verifier_len]u8) void {
        var raw: [32]u8 = undefined;
        std.crypto.random.bytes(&raw);
        _ = base64UrlEncode(out, &raw);
    }

    /// `n` CSPRNG bytes as unpadded base64url, written into `out`
    /// (`out.len == base64UrlLen(n)`). Also used for the OAuth `state` value.
    pub fn randomToken(comptime n: usize, out: *[base64UrlLen(n)]u8) void {
        var raw: [n]u8 = undefined;
        std.crypto.random.bytes(&raw);
        _ = base64UrlEncode(out, &raw);
    }

    /// The S256 `code_challenge` for `verifier`:
    /// `base64url(SHA256(ASCII(verifier)))`, unpadded. Written into `out`.
    pub fn challenge(verifier: []const u8, out: *[challenge_len]u8) void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        _ = base64UrlEncode(out, &digest);
    }

    /// Unpadded base64url length for `n` input bytes.
    pub fn base64UrlLen(n: usize) usize {
        return std.base64.url_safe_no_pad.Encoder.calcSize(n);
    }
};

/// Encode `src` as unpadded base64url into `dst`, returning the written slice.
/// `dst` must be at least `PKCE.base64UrlLen(src.len)` bytes.
pub fn base64UrlEncode(dst: []u8, src: []const u8) []const u8 {
    return std.base64.url_safe_no_pad.Encoder.encode(dst, src);
}

// =============================================================================
// Authorization URL
// =============================================================================

/// Build the browser sign-in URL: the authorization endpoint (Google's, or a
/// test fake) with the code+PKCE parameters. `access_type=offline` +
/// `prompt=consent` guarantee the RELAY receives a refresh token on every
/// (re-)sign-in exchange. Scope is the fixed `openid email profile`. Caller
/// frees.
pub fn authorizationURL(
    alloc: Allocator,
    authorization_endpoint: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    code_challenge: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll(authorization_endpoint);
    // The authorization endpoint may already carry a query (test fakes do not,
    // but be safe): pick '?' or '&' for the first param.
    try w.writeByte(if (std.mem.indexOfScalar(u8, authorization_endpoint, '?') == null) '?' else '&');

    try writeParam(w, "client_id", client_id, false);
    try writeParam(w, "redirect_uri", redirect_uri, true);
    try writeParam(w, "response_type", "code", true);
    try writeParam(w, "scope", "openid email profile", true);
    try writeParam(w, "code_challenge", code_challenge, true);
    try writeParam(w, "code_challenge_method", "S256", true);
    try writeParam(w, "state", state, true);
    try writeParam(w, "access_type", "offline", true);
    try writeParam(w, "prompt", "consent", true);

    return buf.toOwnedSlice(alloc);
}

fn writeParam(w: anytype, key: []const u8, value: []const u8, leading_amp: bool) !void {
    if (leading_amp) try w.writeByte('&');
    try formEscapeWrite(w, key);
    try w.writeByte('=');
    try formEscapeWrite(w, value);
}

/// Percent-encode `s`, passing the RFC 3986 unreserved set through unescaped.
fn formEscapeWrite(w: anytype, s: []const u8) !void {
    for (s) |c| {
        if (isUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

// =============================================================================
// Query-string parsing (redirect handling)
// =============================================================================

/// The OAuth-relevant params extracted from the redirect request's target.
pub const RedirectParams = struct {
    /// The authorization code (present on success).
    code: ?[]const u8 = null,
    /// The OAuth `error` param (present on denial).
    err: ?[]const u8 = null,
    /// The `state` param (must match what we sent).
    state: ?[]const u8 = null,
};

/// Parse the request target of the loopback redirect (e.g.
/// `/?code=abc&state=xyz`) into its OAuth params. Values are percent-decoded
/// into `arena`. A target with neither `code` nor `error` returns all-null
/// (the caller treats that as "not the OAuth redirect", e.g. `/favicon.ico`).
pub fn parseRedirectTarget(arena: Allocator, target: []const u8) !RedirectParams {
    var out: RedirectParams = .{};
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return out;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const raw = pair[eq + 1 ..];
        const value = try percentDecode(arena, raw);
        if (std.mem.eql(u8, key, "code")) {
            out.code = value;
        } else if (std.mem.eql(u8, key, "error")) {
            out.err = value;
        } else if (std.mem.eql(u8, key, "state")) {
            out.state = value;
        }
    }
    return out;
}

/// Percent-decode `s` (also turning `+` into a space, per form encoding) into
/// a freshly allocated buffer. Malformed `%` escapes pass through literally.
pub fn percentDecode(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(alloc, c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(alloc, c);
                i += 1;
                continue;
            };
            try out.append(alloc, @intCast(hi * 16 + lo));
            i += 3;
        } else if (c == '+') {
            try out.append(alloc, ' ');
            i += 1;
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

// =============================================================================
// Loopback redirect receiver
// =============================================================================

/// A one-shot mini HTTP listener on `127.0.0.1:<random port>` that catches
/// Google's redirect (`GET /?code=...&state=...`), shows a "you can close
/// this tab" page, and hands back the authorization code. Google Desktop
/// clients accept any loopback port without prior registration.
///
/// Synchronous (the CLI process is single-purpose): `start` binds and reports
/// the port, `waitForCode` blocks on `accept` until the redirect lands (or the
/// deadline passes). Stray requests (e.g. `/favicon.ico`) get a 404 and don't
/// consume the flow.
pub const LoopbackReceiver = struct {
    alloc: Allocator,
    expected_state: []const u8,
    server: std.net.Server,
    port: u16,

    pub const Failure = error{
        Timeout,
        Denied,
        StateMismatch,
        ListenFailed,
    };

    /// Bind the loopback listener on a kernel-assigned port. Caller frees via
    /// `deinit`. `expected_state` is borrowed (must outlive the receiver).
    pub fn start(alloc: Allocator, expected_state: []const u8) !LoopbackReceiver {
        const addr = std.net.Address.parseIp4("127.0.0.1", 0) catch unreachable;
        var server = addr.listen(.{ .reuse_address = true }) catch return Failure.ListenFailed;
        errdefer server.deinit();
        const bound = server.listen_address;
        return .{
            .alloc = alloc,
            .expected_state = expected_state,
            .server = server,
            .port = bound.getPort(),
        };
    }

    pub fn deinit(self: *LoopbackReceiver) void {
        self.server.deinit();
        self.* = undefined;
    }

    /// The `http://127.0.0.1:<port>` redirect URI to hand Google. Caller frees.
    pub fn redirectUri(self: LoopbackReceiver, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{self.port});
    }

    /// Block until the browser redirect lands, returning the authorization
    /// code (freshly allocated; caller frees). Enforces `timeout_ms` via a
    /// socket receive timeout on each accepted connection; stray non-OAuth
    /// requests keep the flow open.
    pub fn waitForCode(self: *LoopbackReceiver, timeout_ms: u32) ![]u8 {
        // Bound the total wait: `accept` itself has no timeout in std, so we
        // set a receive timeout and, if a connection stalls, treat repeated
        // idleness as the overall deadline. In practice the browser connects
        // within a second or two, so a single accept usually suffices.
        var remaining_ms = timeout_ms;
        while (true) {
            var conn = self.server.accept() catch return Failure.Timeout;
            defer conn.stream.close();

            const result = self.handleConnection(&conn, &remaining_ms) catch |err| switch (err) {
                // Not the OAuth redirect (favicon, etc.) — keep waiting.
                error.NotRedirect => continue,
                else => return err,
            };
            return result;
        }
    }

    const HandleError = Failure || Allocator.Error || error{NotRedirect};

    fn handleConnection(self: *LoopbackReceiver, conn: *std.net.Server.Connection, remaining_ms: *u32) HandleError![]u8 {
        var buf: [16 * 1024]u8 = undefined;
        // Raw recv, not `Stream.read`: on Windows the socket is created
        // WSA_FLAG_OVERLAPPED, and `Stream.read`'s `ReadFile` on an overlapped
        // handle fails with ERROR_INVALID_PARAMETER — the same reason
        // `socket_stream.zig` uses `ws2_32.recv` directly.
        const n = sockRecv(conn.stream.handle, &buf) catch return error.NotRedirect;
        if (n == 0) return error.NotRedirect;
        const request = buf[0..n];

        // Request line: "GET /?code=…&state=… HTTP/1.1"
        const line_end = std.mem.indexOfAny(u8, request, "\r\n") orelse request.len;
        const line = request[0..line_end];
        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next() orelse return error.NotRedirect; // method
        const target = parts.next() orelse return error.NotRedirect;

        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const params = try parseRedirectTarget(arena, target);
        if (params.code == null and params.err == null) {
            // Stray request — 404 and keep waiting.
            self.respond(conn, 404, "Not found", "text/plain");
            _ = remaining_ms;
            return error.NotRedirect;
        }

        if (params.err) |e| {
            self.respondPage(conn, "Sign-in not completed", "You can close this tab and try again from Ghoztty.");
            std.log.warn("google_oauth: redirect carried error={s}", .{e});
            return Failure.Denied;
        }
        const got_state = params.state orelse "";
        if (!std.mem.eql(u8, got_state, self.expected_state)) {
            self.respond(conn, 400, "State mismatch", "text/plain");
            return Failure.StateMismatch;
        }
        const code = params.code.?;
        if (code.len == 0) {
            self.respond(conn, 400, "Missing code", "text/plain");
            return error.NotRedirect;
        }
        self.respondPage(conn, "Signed in to Ghoztty", "You can close this tab and return to Ghoztty.");
        // Copy the code out of the arena before it is torn down.
        return self.alloc.dupe(u8, code);
    }

    fn respondPage(self: *LoopbackReceiver, conn: *std.net.Server.Connection, title: []const u8, detail: []const u8) void {
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>{s}</title></head>" ++
                "<body style=\"font-family:sans-serif;text-align:center;margin-top:20vh\">" ++
                "<h2>{s}</h2><p>{s}</p></body></html>",
            .{ title, title, detail },
        ) catch return;
        self.respond(conn, 200, body, "text/html; charset=utf-8");
    }

    fn respond(self: *LoopbackReceiver, conn: *std.net.Server.Connection, status: u16, body: []const u8, content_type: []const u8) void {
        _ = self;
        const reason = switch (status) {
            200 => "OK",
            404 => "Not Found",
            else => "Bad Request",
        };
        var head_buf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(
            &head_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ status, reason, content_type, body.len },
        ) catch return;
        // Raw send for the same overlapped-socket reason as `sockRecv`.
        sockSendAll(conn.stream.handle, head) catch return;
        sockSendAll(conn.stream.handle, body) catch return;
    }
};

/// One `recv` on a connected socket fd. Windows uses `ws2_32.recv` (the
/// overlapped-socket-safe path, mirroring `socket_stream.zig`); other OSes use
/// the posix syscall. Returns bytes read (0 = peer closed).
fn sockRecv(fd: std.posix.socket_t, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
        const rc = w.ws2_32.recv(fd, buf.ptr, len, 0);
        if (rc == w.ws2_32.SOCKET_ERROR) return error.RecvFailed;
        return @intCast(rc);
    }
    return std.posix.recv(fd, buf, 0);
}

/// Send all of `bytes` on a connected socket fd (see `sockRecv`).
fn sockSendAll(fd: std.posix.socket_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        if (builtin.os.tag == .windows) {
            const w = std.os.windows;
            const len: i32 = @intCast(@min(bytes.len - off, std.math.maxInt(i32)));
            const rc = w.ws2_32.send(fd, bytes.ptr + off, len, 0);
            if (rc == w.ws2_32.SOCKET_ERROR) return error.SendFailed;
            off += @intCast(rc);
        } else {
            off += try std.posix.send(fd, bytes[off..], 0);
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "PKCE: verifier is 43 chars of the unreserved set" {
    var v: [PKCE.verifier_len]u8 = undefined;
    PKCE.generateVerifier(&v);
    try testing.expectEqual(@as(usize, 43), v.len);
    for (v) |c| try testing.expect(isUnreserved(c));
}

test "PKCE: challenge matches a known S256 vector" {
    // RFC 7636 Appendix B verifier/challenge pair.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    var c: [PKCE.challenge_len]u8 = undefined;
    PKCE.challenge(verifier, &c);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &c);
}

test "base64url encodes without padding" {
    const raw = [_]u8{ 0xff, 0x00, 0x10, 0xab, 0xcd };
    var enc_buf: [PKCE.base64UrlLen(raw.len)]u8 = undefined;
    const enc = base64UrlEncode(&enc_buf, &raw);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '=') == null);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '+') == null);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '/') == null);
}

test "authorizationURL carries the expected params" {
    const alloc = testing.allocator;
    const url = try authorizationURL(
        alloc,
        google_authorization_endpoint,
        "client-abc",
        "http://127.0.0.1:54321",
        "state-xyz",
        "chal-123",
    );
    defer alloc.free(url);
    try testing.expect(std.mem.startsWith(u8, url, "https://accounts.google.com/o/oauth2/v2/auth?"));
    try testing.expect(std.mem.indexOf(u8, url, "client_id=client-abc") != null);
    // redirect_uri is percent-encoded (":" and "/" are reserved).
    try testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A54321") != null);
    try testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try testing.expect(std.mem.indexOf(u8, url, "scope=openid%20email%20profile") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge=chal-123") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.indexOf(u8, url, "state=state-xyz") != null);
    try testing.expect(std.mem.indexOf(u8, url, "access_type=offline") != null);
    try testing.expect(std.mem.indexOf(u8, url, "prompt=consent") != null);
}

test "parseRedirectTarget: extracts + percent-decodes code/state/error" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try parseRedirectTarget(a, "/?code=abc%2F123&state=xy%20z&scope=openid");
    try testing.expectEqualStrings("abc/123", ok.code.?);
    try testing.expectEqualStrings("xy z", ok.state.?);
    try testing.expect(ok.err == null);

    const denied = try parseRedirectTarget(a, "/?error=access_denied&state=s");
    try testing.expectEqualStrings("access_denied", denied.err.?);

    // Not the OAuth redirect: no code, no error.
    const favicon = try parseRedirectTarget(a, "/favicon.ico");
    try testing.expect(favicon.code == null and favicon.err == null);
}

test "loopback receiver binds a port and yields a usable redirect URI" {
    const alloc = testing.allocator;
    var recv = try LoopbackReceiver.start(alloc, "state-1");
    defer recv.deinit();
    try testing.expect(recv.port != 0);
    const uri = try recv.redirectUri(alloc);
    defer alloc.free(uri);
    var expect_buf: [64]u8 = undefined;
    const expect = try std.fmt.bufPrint(&expect_buf, "http://127.0.0.1:{d}", .{recv.port});
    try testing.expectEqualStrings(expect, uri);
}

test {
    testing.refAllDecls(@This());
}
