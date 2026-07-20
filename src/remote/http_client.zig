//! Minimal HTTP/1.1 JSON POST helper over the SAME native stacks the relay
//! transport already uses: plain TCP for `http://` targets (loopback test
//! relays, e.g. a Go `httptest` server) and `std.crypto.tls` with system-root
//! certificate verification for `https://` (the real relay behind Caddy) —
//! exactly the TLS plumbing `ws_client.zig` proved out, minus the WebSocket
//! upgrade. No new dependencies.
//!
//! This exists for the agent's device-code self-enroll flow (WP-B3):
//! `POST /v1/enroll/start` and `POST /v1/enroll/poll` are ordinary JSON
//! request/response calls, not WebSockets — plus the agent self-updater's
//! `GET /dl/version.json` manifest fetch and binary download (`get`). Scope is
//! intentionally tiny: one request per connection (`Connection: close`), and
//! the three body framings a Go/Caddy stack actually produces (Content-Length,
//! chunked, close-delimited). It is NOT a general HTTP client.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Certificate = std.crypto.Certificate;
const tls = std.crypto.tls;
const socket_rw = @import("socket_rw.zig");

/// TLS record buffers must be at least `tls.max_ciphertext_record_len` (~16645);
/// 32 KiB gives headroom (mirrors `ws_client.zig`). Also used as the plain-TCP
/// buffered reader/writer size, which comfortably holds any response headers.
const buf_len = 32 * 1024;

/// Upper bound on an accepted response body. Enroll responses are tiny; this
/// only guards against a misbehaving server growing our allocation.
const max_body_len = 1 << 20;

pub const Scheme = enum { http, https };

/// A parsed `http(s)://host[:port][/path...]` URL. All slices borrow the input.
pub const Url = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
    /// Request path including any query string; `"/"` when the URL has none.
    path: []const u8,
};

pub const UrlError = error{ UnsupportedScheme, BadUrl };

/// Parse an absolute `http://` / `https://` URL. Default ports 80/443.
pub fn parseUrl(url: []const u8) UrlError!Url {
    var scheme: Scheme = undefined;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, "http://")) {
        scheme = .http;
        rest = url["http://".len..];
    } else if (std.mem.startsWith(u8, url, "https://")) {
        scheme = .https;
        rest = url["https://".len..];
    } else return error.UnsupportedScheme;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";

    var host = authority;
    var port: u16 = if (scheme == .http) 80 else 443;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.BadUrl;
    }
    if (host.len == 0) return error.BadUrl;
    return .{ .scheme = scheme, .host = host, .port = port, .path = path };
}

/// One HTTP response: status code + owned body bytes.
pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

/// POST `json_body` (as `application/json`) to the absolute `url`, returning
/// the status + body. One connection per call (`Connection: close`). For
/// `https://` the certificate is verified against the system roots with host
/// verification ON; `http://` is plaintext (use only for loopback test relays).
pub fn postJson(alloc: Allocator, url: []const u8, json_body: []const u8) !Response {
    return request(alloc, url, "POST", .{ .json = json_body }, null, max_body_len);
}

/// POST an `application/x-www-form-urlencoded` body to the absolute `url`.
/// Same connection-per-call and TLS semantics as `postJson`. Added for the
/// Google OAuth token endpoint (code exchange + refresh grant, T21a).
pub fn postForm(alloc: Allocator, url: []const u8, form_body: []const u8) !Response {
    return request(alloc, url, "POST", .{ .form = form_body }, null, max_body_len);
}

/// GET with a bearer token (`Authorization: Bearer <token>`). For the agent's
/// device-authenticated relay endpoints (`/v1/agent/whoami`).
pub fn getAuth(alloc: Allocator, url: []const u8, bearer: []const u8, max_len: usize) !Response {
    return request(alloc, url, "GET", .none, bearer, max_len);
}

/// Bearer-authenticated POST with an OPTIONAL body. Used by the agent's self
/// de-enroll (`/v1/agent/deenroll`, no body). Pass `null` for a body-less POST.
pub fn postAuth(alloc: Allocator, url: []const u8, bearer: []const u8, json_body: ?[]const u8) !Response {
    return request(alloc, url, "POST", if (json_body) |b| .{ .json = b } else .none, bearer, max_body_len);
}

/// GET the absolute `url` into memory, returning the status + owned body
/// (rejected past `max_len` — the caller knows whether it expects a small JSON
/// manifest or a multi-megabyte binary). Same connection-per-call semantics
/// and TLS/plaintext scheme split as `postJson`. Added for the agent
/// self-updater (version manifest + binary download).
pub fn get(alloc: Allocator, url: []const u8, max_len: usize) !Response {
    return request(alloc, url, "GET", .none, null, max_len);
}

/// A request body with its Content-Type (or none, for GETs and body-less
/// POSTs).
const Body = union(enum) {
    none,
    json: []const u8,
    form: []const u8,

    fn contentType(self: Body) []const u8 {
        return switch (self) {
            .none => unreachable,
            .json => "application/json",
            .form => "application/x-www-form-urlencoded",
        };
    }

    fn bytes(self: Body) ?[]const u8 {
        return switch (self) {
            .none => null,
            .json, .form => |b| b,
        };
    }
};

fn request(
    alloc: Allocator,
    url: []const u8,
    method: []const u8,
    body: Body,
    auth_bearer: ?[]const u8,
    max_len: usize,
) !Response {
    const u = try parseUrl(url);

    const socket = try std.net.tcpConnectToHost(alloc, u.host, u.port);
    defer socket.close();

    const tcp_read_buf = try alloc.alloc(u8, buf_len);
    defer alloc.free(tcp_read_buf);
    const tcp_write_buf = try alloc.alloc(u8, buf_len);
    defer alloc.free(tcp_write_buf);

    // socket_rw, not `socket.reader`/`.writer` (T89b): std's Stream I/O uses
    // ReadFile/WriteFile on Windows, which fail with ERROR_INVALID_PARAMETER
    // on the overlapped sockets std creates — every plain-http request (and
    // the TCP layer under TLS) died on first read. Same swap ws_client made
    // in T81; socket_rw's Reader/Writer are shape-compatible stand-ins.
    socket_rw.disableSigpipe(socket.handle);
    var tcp_reader = socket_rw.Reader.init(socket.handle, tcp_read_buf);
    var tcp_writer = socket_rw.Writer.init(socket.handle, tcp_write_buf);

    switch (u.scheme) {
        .http => {
            try writeRequest(&tcp_writer.interface, method, u, body, auth_bearer);
            try tcp_writer.interface.flush();
            return readResponse(alloc, tcp_reader.interface(), max_len);
        },
        .https => {
            var ca_bundle: Certificate.Bundle = .{};
            try ca_bundle.rescan(alloc);
            defer ca_bundle.deinit(alloc);

            const tls_read_buf = try alloc.alloc(u8, buf_len);
            defer alloc.free(tls_read_buf);
            const tls_write_buf = try alloc.alloc(u8, buf_len);
            defer alloc.free(tls_write_buf);

            var tls_client = try tls.Client.init(tcp_reader.interface(), &tcp_writer.interface, .{
                .host = .{ .explicit = u.host },
                .ca = .{ .bundle = ca_bundle },
                .read_buffer = tls_read_buf,
                .write_buffer = tls_write_buf,
            });
            try writeRequest(&tls_client.writer, method, u, body, auth_bearer);
            // The TLS flush only stages ciphertext; the socket isn't written
            // until the TCP writer flushes too (same dance as ws_client).
            try tls_client.writer.flush();
            try tcp_writer.interface.flush();
            return readResponse(alloc, &tls_client.reader, max_len);
        },
    }
}

/// Emit the full request (headers + optional body) into `w`. Caller
/// flushes. A `.none` body is a body-less request (GET).
fn writeRequest(w: *std.Io.Writer, method: []const u8, u: Url, body: Body, auth_bearer: ?[]const u8) !void {
    try w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\n", .{ method, u.path, u.host });
    if (auth_bearer) |tok| try w.print("Authorization: Bearer {s}\r\n", .{tok});
    if (body.bytes()) |b| try w.print(
        "Content-Type: {s}\r\nContent-Length: {d}\r\n",
        .{ body.contentType(), b.len },
    );
    try w.writeAll("Connection: close\r\n\r\n");
    if (body.bytes()) |b| try w.writeAll(b);
}

/// Parse a full HTTP/1.1 response from `r`: status line, headers (we only care
/// about the body framing), then the body via Content-Length, chunked
/// transfer-encoding, or read-to-EOF (we sent `Connection: close`). The body
/// is rejected past `max_len`. Factored over `*std.Io.Reader` so it unit-tests
/// against fixed buffers.
fn readResponse(alloc: Allocator, r: *std.Io.Reader, max_len: usize) !Response {
    const status_line = try r.takeDelimiterInclusive('\n');
    const status = parseStatusLine(status_line) orelse return error.BadHttpResponse;

    var content_length: ?usize = null;
    var chunked = false;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) break; // end of headers
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..colon];
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadHttpResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked = true;
        }
    }

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);

    if (chunked) {
        try readChunkedBody(alloc, r, &body, max_len);
    } else if (content_length) |len| {
        if (len > max_len) return error.BodyTooLarge;
        try body.resize(alloc, len);
        try readExact(r, body.items);
    } else {
        try readToEof(alloc, r, &body, max_len);
    }

    return .{ .status = status, .body = try body.toOwnedSlice(alloc) };
}

/// `"HTTP/1.1 200 OK"` → 200, or null if malformed.
fn parseStatusLine(line: []const u8) ?u16 {
    const s = std.mem.trimRight(u8, line, "\r\n");
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    const version = it.next() orelse return null;
    if (!std.mem.startsWith(u8, version, "HTTP/")) return null;
    const code = it.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

/// Fill `dst` exactly; `error.EndOfStream` if the stream ends short.
fn readExact(r: *std.Io.Reader, dst: []u8) !void {
    var off: usize = 0;
    while (off < dst.len) {
        const n = try r.readSliceShort(dst[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

/// Decode a chunked body (`<hex-size>\r\n<data>\r\n ... 0\r\n[trailers]\r\n`).
fn readChunkedBody(alloc: Allocator, r: *std.Io.Reader, body: *std.ArrayList(u8), max_len: usize) !void {
    while (true) {
        const size_line = try r.takeDelimiterInclusive('\n');
        const size_str = std.mem.trimRight(u8, size_line, "\r\n");
        // Ignore any chunk extension (";...").
        const semi = std.mem.indexOfScalar(u8, size_str, ';') orelse size_str.len;
        const size = std.fmt.parseInt(usize, size_str[0..semi], 16) catch return error.BadHttpResponse;
        if (size == 0) {
            // Consume optional trailers up to the final blank line (or EOF —
            // some stacks just close after `0\r\n\r\n`).
            while (true) {
                const line = r.takeDelimiterInclusive('\n') catch break;
                if (std.mem.trimRight(u8, line, "\r\n").len == 0) break;
            }
            return;
        }
        if (body.items.len + size > max_len) return error.BodyTooLarge;
        const start = body.items.len;
        try body.resize(alloc, start + size);
        try readExact(r, body.items[start..]);
        // Trailing CRLF after the chunk data.
        _ = r.takeDelimiterInclusive('\n') catch return error.BadHttpResponse;
    }
}

/// Read until EOF (bounded by `max_len`). A TLS truncation / reset at the
/// end of a `Connection: close` body is treated as EOF, not an error.
fn readToEof(alloc: Allocator, r: *std.Io.Reader, body: *std.ArrayList(u8), max_len: usize) !void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        // `readSliceShort` reports EOF as a short/zero count; a TLS truncation
        // or peer reset surfaces as ReadFailed — both end the body here.
        const n = r.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return,
        };
        if (n == 0) return;
        if (body.items.len + n > max_len) return error.BodyTooLarge;
        try body.appendSlice(alloc, chunk[0..n]);
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "parseUrl: http with port and path" {
    const u = try parseUrl("http://127.0.0.1:8080/v1/enroll/start");
    try testing.expectEqual(Scheme.http, u.scheme);
    try testing.expectEqualStrings("127.0.0.1", u.host);
    try testing.expectEqual(@as(u16, 8080), u.port);
    try testing.expectEqualStrings("/v1/enroll/start", u.path);
}

test "parseUrl: https defaults, bare host" {
    const u = try parseUrl("https://relay.example.com");
    try testing.expectEqual(Scheme.https, u.scheme);
    try testing.expectEqualStrings("relay.example.com", u.host);
    try testing.expectEqual(@as(u16, 443), u.port);
    try testing.expectEqualStrings("/", u.path);
}

test "parseUrl: rejects other schemes and empty hosts" {
    try testing.expectError(error.UnsupportedScheme, parseUrl("ftp://x/"));
    try testing.expectError(error.UnsupportedScheme, parseUrl("relay.example.com"));
    try testing.expectError(error.BadUrl, parseUrl("http://:8080/x"));
    try testing.expectError(error.BadUrl, parseUrl("http://host:notaport/x"));
}

test "readResponse: content-length body" {
    const raw = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 17\r\n" ++
        "\r\n" ++
        "{\"status\":\"okay\"}";
    var r: std.Io.Reader = .fixed(raw);
    var resp = try readResponse(testing.allocator, &r, max_body_len);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualStrings("{\"status\":\"okay\"}", resp.body);
}

test "readResponse: chunked body" {
    const raw = "HTTP/1.1 429 Too Many Requests\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "b\r\n{\"status\":\"\r\n" ++
        "b\r\nslow_down\"}\r\n" ++
        "0\r\n\r\n";
    var r: std.Io.Reader = .fixed(raw);
    var resp = try readResponse(testing.allocator, &r, max_body_len);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 429), resp.status);
    try testing.expectEqualStrings("{\"status\":\"slow_down\"}", resp.body);
}

test "readResponse: close-delimited body (no framing headers)" {
    const raw = "HTTP/1.1 503 Service Unavailable\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "enrollment unavailable";
    var r: std.Io.Reader = .fixed(raw);
    var resp = try readResponse(testing.allocator, &r, max_body_len);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 503), resp.status);
    try testing.expectEqualStrings("enrollment unavailable", resp.body);
}

test "readResponse: malformed status line rejected" {
    var r: std.Io.Reader = .fixed("garbage\r\n\r\n");
    try testing.expectError(error.BadHttpResponse, readResponse(testing.allocator, &r, max_body_len));
}

test "readResponse: truncated content-length body errors" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort";
    var r: std.Io.Reader = .fixed(raw);
    try testing.expectError(error.EndOfStream, readResponse(testing.allocator, &r, max_body_len));
}

test {
    testing.refAllDecls(@This());
}
