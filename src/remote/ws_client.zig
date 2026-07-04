//! WebSocket-over-TLS client (RFC 6455 client + `std.crypto.tls`) — the native
//! Zig replacement for the Go `relay-connect`/`relay-agent` sidecars. It dials a
//! `wss://host[:port]/path` relay endpoint, performs the HTTP/1.1 WebSocket
//! upgrade, and then carries an opaque inner byte stream as **binary** WebSocket
//! frames. The relay bridges those bytes verbatim to the target device, so as far
//! as the inner protocol (`connection.zig`'s framed mux) is concerned this is just
//! a bidirectional byte pipe.
//!
//! It hands out the SAME `connection.Stream` vtable shape as
//! `socket_stream.SocketStream` / `ssh_transport.ChildStream`, so it can drop into
//! `ClientMux`/`Connection` unchanged: `read`→pull frames, `write`→emit a masked
//! binary frame, `close`→tear down. Both vtable flavours are exposed
//! (`connectionStream()` client side, `serverStream()` agent side); the byte ops
//! are shared.
//!
//! ## Threading contract (mirrors SocketStream)
//! One reader thread calls `read`, one writer thread calls `write`, and `close`
//! may be called concurrently with a blocked `read`. We honor this exactly like
//! `SocketStream`:
//!   - `read` is only ever touched by the reader thread (plus it may *send* a pong
//!     / close reply, which it does under `write_mtx`).
//!   - `write` is serialized with `write_mtx` because the TLS writer is a single
//!     stateful encryptor — a data frame from the writer thread and a pong from
//!     the reader thread must never interleave on the wire.
//!   - `close` does `shutdown(.both)` on the raw socket fd, which makes the
//!     reader thread's blocked `recv` (down inside TLS) return EOF immediately,
//!     then closes the fd. Idempotent (atomic flag).
//!
//! ## EOF mapping (mirrors SocketStream)
//! A clean server close (0x8), a TLS close_notify / truncation, or a peer reset
//! all surface to the inner pump as `read => 0` (EOF), never an error, so the pump
//! exits cleanly. A dead write lane surfaces as `write => 0` (→ `error.WriteZero`
//! in `writeAll`).
//!
//! ## WebSocket framing notes (RFC 6455)
//! - We send opcode 0x2 (binary), FIN set, and **client frames MUST be masked**:
//!   each frame gets a fresh random 32-bit key XORed over the payload, with the
//!   correct 7/16/64-bit length encoding.
//! - Server→client frames are UNMASKED (we still defensively un-mask if the mask
//!   bit is set). Because the relay is an opaque *byte* bridge, we do NOT need to
//!   preserve message boundaries: binary (0x2) and continuation (0x0) frames are
//!   delivered identically as raw bytes, regardless of FIN. We only special-case
//!   control frames: ping (0x9) → reply masked pong, pong (0xA) → ignore, close
//!   (0x8) → reply close + EOF.
//! - Frames can span multiple TLS reads; the buffered `std.Io.Reader` from the TLS
//!   client handles re-assembly of headers, and data payloads are streamed
//!   directly into the caller's buffer across `read` calls (no whole-frame
//!   buffering, so a multi-MiB frame costs no extra memory).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Certificate = std.crypto.Certificate;
const tls = std.crypto.tls;

const connection = @import("connection.zig");
const server = @import("agent/server.zig");

const log = std.log.scoped(.remote_ws);

/// The WebSocket magic GUID concatenated to the client key for the accept hash
/// (RFC 6455 §1.3).
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// TLS record buffers must be at least `tls.max_ciphertext_record_len` (~16645);
/// 32 KiB gives headroom for a full record plus the parser's working set.
const tls_buf_len = 32 * 1024;

/// Opcodes we care about (RFC 6455 §5.2).
const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

/// A single extra request header (e.g. `Authorization: Bearer <token>`).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Dial parameters. Nothing here is retained past `connect` (strings are only
/// borrowed for the duration of the handshake).
pub const Options = struct {
    /// Host to TCP-connect to, use as the TLS SNI/verification name, and put in
    /// the HTTP `Host:` header. Required.
    host: []const u8,
    /// TCP port. Defaults to the standard TLS/wss port.
    port: u16 = 443,
    /// Request path (with any query string), e.g.
    /// `"/v1/client/connect?device=<id>"`. Required, must start with `/`.
    path: []const u8,
    /// Extra request headers (e.g. the bearer token). Borrowed.
    headers: []const Header = &.{},
    /// TLS on (the production default). `false` gives a PLAINTEXT `ws://`
    /// connection — use ONLY for loopback test servers (mirrors
    /// `http_client.zig`'s `http://` support); real relays are always `wss://`.
    tls: bool = true,
};

pub const ConnectError = error{
    /// The server did not return `101 Switching Protocols`.
    WebSocketUpgradeFailed,
    /// `Sec-WebSocket-Accept` was missing or did not match our key.
    WebSocketBadAccept,
    /// The HTTP response was malformed / too large for the handshake buffer.
    WebSocketBadResponse,
};

/// A `connection.Stream` over an authenticated `wss://` connection. Heap-allocate
/// via `connect` (its address must be stable: the embedded TLS client's
/// reader/writer use `@fieldParentPtr`, and the vtable `ctx` is `*WsClient`).
pub const WsClient = struct {
    alloc: Allocator,

    /// Underlying TCP socket. We keep the handle so `close` can `shutdown` it to
    /// unblock a blocked reader thread.
    socket: std.net.Stream,

    /// CA bundle (system roots) — owned, freed on deinit.
    ca_bundle: Certificate.Bundle,

    /// The TCP-side ciphertext Reader/Writer the TLS client pulls/pushes through.
    /// Heap-pinned: the TLS client stores raw `*Io.Reader`/`*Io.Writer` pointers
    /// into these, and their interfaces use `@fieldParentPtr`.
    tcp_reader: *std.net.Stream.Reader,
    tcp_writer: *std.net.Stream.Writer,

    /// The TLS client, or null for a plaintext (`tls: false`, loopback-test-only)
    /// connection. When present, app data goes through `tls_client.reader` /
    /// `tls_client.writer`. Heap-pinned (its reader/writer use `@fieldParentPtr`).
    tls_client: ?*tls.Client,

    /// Serializes all writes to the single TLS encryptor (writer thread data
    /// frames vs. reader thread pong/close replies).
    write_mtx: std.Thread.Mutex = .{},

    /// Set once on close; makes both read and write fast-path to EOF/closed-lane.
    closed: std.atomic.Value(bool) = .{ .raw = false },

    /// Wall-clock ms timestamp of the last successfully parsed INBOUND frame
    /// (any opcode: data, ping, pong, close — all prove the link is alive).
    /// Wall clock on purpose: monotonic clocks pause during system sleep on
    /// macOS/Windows, but wall time keeps counting, so a keepalive comparing
    /// `now - lastRxMillis()` sees the whole sleep gap immediately on wake and
    /// declares the link stale on its first post-wake tick. Written by the
    /// reader thread, read by the keepalive thread (see `agent/keepalive.zig`).
    last_rx_ms: std.atomic.Value(i64) = .{ .raw = 0 },

    // --- In-flight inbound data-frame state (carried across `read` calls) ------
    /// Bytes still unread in the current binary/continuation frame's payload.
    frame_remaining: u64 = 0,
    /// Whether the in-flight frame was masked (servers normally don't mask, but
    /// we handle it defensively).
    frame_masked: bool = false,
    /// The in-flight frame's mask key (valid iff `frame_masked`).
    frame_mask: [4]u8 = .{ 0, 0, 0, 0 },
    /// How many payload bytes of the in-flight frame we've already consumed (for
    /// the rolling mask index).
    frame_consumed: u64 = 0,

    // Heap-pinned scratch buffers for the TLS record machinery.
    tcp_read_buf: *[tls_buf_len]u8,
    tcp_write_buf: *[tls_buf_len]u8,
    tls_read_buf: *[tls_buf_len]u8,
    tls_write_buf: *[tls_buf_len]u8,

    /// Dial `host:port`, TLS-handshake (verifying the cert against system roots
    /// with host verification ON), and perform the RFC 6455 upgrade for `path`.
    /// On success returns a heap `*WsClient` the caller owns (free via `deinit`).
    pub fn connect(alloc: Allocator, options: Options) !*WsClient {
        std.debug.assert(options.path.len > 0 and options.path[0] == '/');

        const self = try alloc.create(WsClient);
        errdefer alloc.destroy(self);

        // --- TCP connect -----------------------------------------------------
        const socket = try std.net.tcpConnectToHost(alloc, options.host, options.port);
        errdefer socket.close();

        // --- System CA roots (TLS only; stays empty for plaintext) ------------
        var ca_bundle: Certificate.Bundle = .{};
        if (options.tls) try ca_bundle.rescan(alloc);
        errdefer ca_bundle.deinit(alloc);

        // --- Allocate the pinned buffers + IO wrappers -----------------------
        const tcp_read_buf = try alloc.create([tls_buf_len]u8);
        errdefer alloc.destroy(tcp_read_buf);
        const tcp_write_buf = try alloc.create([tls_buf_len]u8);
        errdefer alloc.destroy(tcp_write_buf);
        const tls_read_buf = try alloc.create([tls_buf_len]u8);
        errdefer alloc.destroy(tls_read_buf);
        const tls_write_buf = try alloc.create([tls_buf_len]u8);
        errdefer alloc.destroy(tls_write_buf);

        const tcp_reader = try alloc.create(std.net.Stream.Reader);
        errdefer alloc.destroy(tcp_reader);
        tcp_reader.* = socket.reader(tcp_read_buf);

        const tcp_writer = try alloc.create(std.net.Stream.Writer);
        errdefer alloc.destroy(tcp_writer);
        tcp_writer.* = socket.writer(tcp_write_buf);

        // --- TLS handshake (host verification ON), skipped for plaintext ------
        const tls_client: ?*tls.Client = if (options.tls) blk: {
            const t = try alloc.create(tls.Client);
            errdefer alloc.destroy(t);
            t.* = try tls.Client.init(tcp_reader.interface(), &tcp_writer.interface, .{
                .host = .{ .explicit = options.host },
                .ca = .{ .bundle = ca_bundle },
                .read_buffer = tls_read_buf,
                .write_buffer = tls_write_buf,
            });
            break :blk t;
        } else null;
        errdefer if (tls_client) |t| alloc.destroy(t);

        self.* = .{
            .alloc = alloc,
            .socket = socket,
            .ca_bundle = ca_bundle,
            .tcp_reader = tcp_reader,
            .tcp_writer = tcp_writer,
            .tls_client = tls_client,
            .tcp_read_buf = tcp_read_buf,
            .tcp_write_buf = tcp_write_buf,
            .tls_read_buf = tls_read_buf,
            .tls_write_buf = tls_write_buf,
        };

        // --- WebSocket upgrade over the (possibly encrypted) channel ---------
        try self.handshake(options);
        // The 101 response counts as first inbound traffic: staleness windows
        // start "now", not at epoch.
        self.noteRx();
        return self;
    }

    /// Parse a `wss://host[:port]/path` (or `https://...`) URL and connect.
    /// `ws://`/`http://` yield a PLAINTEXT connection — loopback test servers
    /// only (same rule as `http_client.zig`); real relays are always TLS.
    pub fn connectUrl(alloc: Allocator, url: []const u8, headers: []const Header) !*WsClient {
        var rest = url;
        var use_tls = true;
        var port: u16 = 443;
        if (std.mem.startsWith(u8, rest, "wss://")) {
            rest = rest["wss://".len..];
        } else if (std.mem.startsWith(u8, rest, "https://")) {
            rest = rest["https://".len..];
        } else if (std.mem.startsWith(u8, rest, "ws://")) {
            use_tls = false;
            port = 80;
            rest = rest["ws://".len..];
        } else if (std.mem.startsWith(u8, rest, "http://")) {
            use_tls = false;
            port = 80;
            rest = rest["http://".len..];
        } else {
            return error.WebSocketBadResponse; // not a ws(s)/http(s) URL
        }

        // Split authority from path.
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash];
        const path = if (slash < rest.len) rest[slash..] else "/";

        // Split host from optional :port.
        var host = authority;
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port = try std.fmt.parseInt(u16, authority[colon + 1 ..], 10);
        }

        return connect(alloc, .{ .host = host, .port = port, .path = path, .headers = headers, .tls = use_tls });
    }

    /// Tear down: best-effort close frame, then close the socket + free all owned
    /// memory. Not safe to call concurrently with read/write (it frees); call it
    /// only after the using `Connection` has been shut down (which calls `close`).
    pub fn deinit(self: *WsClient) void {
        self.close();
        self.ca_bundle.deinit(self.alloc);
        if (self.tls_client) |t| self.alloc.destroy(t);
        self.alloc.destroy(self.tcp_reader);
        self.alloc.destroy(self.tcp_writer);
        self.alloc.destroy(self.tcp_read_buf);
        self.alloc.destroy(self.tcp_write_buf);
        self.alloc.destroy(self.tls_read_buf);
        self.alloc.destroy(self.tls_write_buf);
        self.alloc.destroy(self);
    }

    // =========================================================================
    // WebSocket handshake (RFC 6455 §4)
    // =========================================================================

    fn handshake(self: *WsClient, options: Options) !void {
        // 16 random bytes, base64'd, become Sec-WebSocket-Key.
        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key_b64: [24]u8 = undefined; // base64 of 16 bytes = 24 chars (with pad)
        const key = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

        // Build + send the upgrade request through the app-data writer.
        const w = self.appWriter();
        try w.print(
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n",
            .{ options.path, options.host, key },
        );
        for (options.headers) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try w.writeAll("\r\n");
        try self.flushOut();

        // Compute the expected Sec-WebSocket-Accept = base64(sha1(key ++ GUID)).
        var expected_accept_buf: [28]u8 = undefined; // base64 of 20-byte sha1 = 28
        const expected_accept = computeAccept(key, &expected_accept_buf);

        // Read the response status line + headers from the app-data reader.
        // Anything buffered past the final CRLFCRLF (e.g. the first WS frame)
        // stays in the reader for `read` to consume.
        const r = self.appReader();

        // Status line: require "HTTP/1.1 101".
        const status = try r.takeDelimiterInclusive('\n');
        if (!is101(status)) {
            log.warn("ws upgrade rejected: {s}", .{std.mem.trimRight(u8, status, "\r\n")});
            return ConnectError.WebSocketUpgradeFailed;
        }

        // Header lines until the blank line. Validate Sec-WebSocket-Accept.
        var saw_accept = false;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimRight(u8, line, "\r\n");
            if (trimmed.len == 0) break; // end of headers
            if (splitHeader(trimmed)) |hv| {
                if (std.ascii.eqlIgnoreCase(hv.name, "sec-websocket-accept")) {
                    const got = std.mem.trim(u8, hv.value, " \t");
                    if (!std.mem.eql(u8, got, expected_accept)) {
                        log.warn("ws bad accept: got={s} want={s}", .{ got, expected_accept });
                        return ConnectError.WebSocketBadAccept;
                    }
                    saw_accept = true;
                }
            }
        }
        if (!saw_accept) return ConnectError.WebSocketBadAccept;
    }

    /// `base64(sha1(key ++ ws_guid))` into `out` (must be >= 28 bytes).
    fn computeAccept(key: []const u8, out: []u8) []const u8 {
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key);
        sha1.update(ws_guid);
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        sha1.final(&digest);
        return std.base64.standard.Encoder.encode(out, &digest);
    }

    fn is101(status_line: []const u8) bool {
        // e.g. "HTTP/1.1 101 Switching Protocols\r\n"
        const s = std.mem.trimRight(u8, status_line, "\r\n");
        var it = std.mem.tokenizeScalar(u8, s, ' ');
        _ = it.next() orelse return false; // HTTP/1.1
        const code = it.next() orelse return false;
        return std.mem.eql(u8, code, "101");
    }

    fn splitHeader(line: []const u8) ?struct { name: []const u8, value: []const u8 } {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        return .{ .name = line[0..colon], .value = line[colon + 1 ..] };
    }

    // =========================================================================
    // Byte ops shared by both vtable flavours
    // =========================================================================

    /// The app-data reader: TLS plaintext when encrypted, the raw TCP reader
    /// for a plaintext (loopback-test) connection.
    fn appReader(self: *WsClient) *std.Io.Reader {
        return if (self.tls_client) |t| &t.reader else self.tcp_reader.interface();
    }

    /// The app-data writer (counterpart of `appReader`).
    fn appWriter(self: *WsClient) *std.Io.Writer {
        return if (self.tls_client) |t| &t.writer else &self.tcp_writer.interface;
    }

    /// Flush the TLS writer (encrypt buffered plaintext into the TCP write buffer)
    /// AND the underlying TCP writer (push the ciphertext onto the socket). The
    /// TLS `flush` only stages ciphertext; the socket isn't written until the TCP
    /// writer is flushed too. For plaintext connections only the TCP flush applies.
    fn flushOut(self: *WsClient) !void {
        if (self.tls_client) |t| try t.writer.flush();
        try self.tcp_writer.interface.flush();
    }

    /// Record "inbound traffic seen now" (any successfully parsed frame header).
    fn noteRx(self: *WsClient) void {
        self.last_rx_ms.store(std.time.milliTimestamp(), .monotonic);
    }

    /// Wall-clock ms timestamp of the last inbound frame (see `last_rx_ms`).
    /// Safe to call from any thread.
    pub fn lastRxMillis(self: *WsClient) i64 {
        return self.last_rx_ms.load(.monotonic);
    }

    /// Send a masked, empty WS ping (RFC 6455 §5.5.2). Thread-safe with the
    /// writer thread and the reader thread's pong replies (all frame emission is
    /// serialized by `write_mtx`). The peer must answer with a pong, which the
    /// read path counts as inbound traffic — this is the keepalive probe.
    pub fn sendPing(self: *WsClient) !void {
        try self.sendFrame(.ping, "");
    }

    /// Read up to `buf.len` bytes of inner payload, parsing/handling WS frames as
    /// needed. Returns 0 on EOF/close. Control frames are handled transparently.
    fn readImpl(self: *WsClient, buf: []u8) anyerror!usize {
        if (self.closed.load(.acquire)) return 0;
        if (buf.len == 0) return 0;

        while (true) {
            // Serve bytes from an in-flight data frame first.
            if (self.frame_remaining > 0) {
                const want: usize = @intCast(@min(@as(u64, buf.len), self.frame_remaining));
                const n = self.appReader().readSliceShort(buf[0..want]) catch |err|
                    return self.mapReadErr(err);
                if (n == 0) return 0; // EOF mid-frame
                self.noteRx();
                if (self.frame_masked) {
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        const mi: usize = @intCast((self.frame_consumed + i) & 3);
                        buf[i] ^= self.frame_mask[mi];
                    }
                }
                self.frame_remaining -= n;
                self.frame_consumed += n;
                return n;
            }

            // No in-flight data; parse the next frame header.
            const frame = parseFrameHeader(self.appReader()) catch |err| return self.mapReadErr(err);
            self.noteRx();
            switch (frame.opcode) {
                .binary, .continuation, .text => {
                    // Begin (or continue) delivering a data frame. Empty frames
                    // (len 0) just loop to the next frame.
                    self.frame_remaining = frame.len;
                    self.frame_masked = frame.masked;
                    self.frame_mask = frame.mask;
                    self.frame_consumed = 0;
                    continue;
                },
                .ping => {
                    // Reply with a masked pong echoing the (small) payload.
                    const payload = readControlPayload(self.appReader(), frame) catch |err|
                        return self.mapReadErr(err);
                    self.sendFrame(.pong, payload) catch {};
                    continue;
                },
                .pong => {
                    _ = readControlPayload(self.appReader(), frame) catch |err| return self.mapReadErr(err);
                    continue;
                },
                .close => {
                    _ = readControlPayload(self.appReader(), frame) catch {};
                    // Best-effort close reply, then EOF.
                    self.sendFrame(.close, "") catch {};
                    return 0;
                },
                else => {
                    // Unknown opcode: discard its payload and keep going.
                    _ = readControlPayload(self.appReader(), frame) catch |err| return self.mapReadErr(err);
                    continue;
                },
            }
        }
    }

    /// Read ONE full WebSocket message (text 0x1 OR binary 0x2, plus any 0x0
    /// continuation frames) into `buf`, reassembling across continuation frames
    /// and TLS reads. Returns the message length, or 0 on a clean close/EOF.
    /// Ping→pong and close are handled internally exactly like the streaming
    /// `read` path. Text and binary are treated identically (payload bytes only).
    ///
    /// This is for the dedicated CONTROL connection, where the relay delivers one
    /// discrete JSON command per WS message and message boundaries matter; the
    /// data connections keep using the byte-flattening `read` path. Errors if a
    /// single message exceeds `buf.len` (`error.MessageTooLarge`).
    pub fn readMessage(self: *WsClient, buf: []u8) anyerror!usize {
        if (self.closed.load(.acquire)) return 0;
        return messageFromReader(self.appReader(), buf, self);
    }

    /// The reassembly core, factored out so it can be unit-tested over a synthetic
    /// frame buffer (pass `self = null`; then control replies are skipped and EOF
    /// surfaces as 0). When `self` is non-null, ping→pong / close replies are sent
    /// and read errors are EOF-mapped via `mapReadErr`.
    fn messageFromReader(r: *std.Io.Reader, buf: []u8, self: ?*WsClient) anyerror!usize {
        var total: usize = 0;
        while (true) {
            const frame = parseFrameHeader(r) catch |err| {
                if (self) |s| return s.mapReadErr(err);
                if (err == error.EndOfStream) return 0;
                return err;
            };
            // Any parseable inbound frame — ping, pong, data, even close —
            // counts as link-liveness traffic for the keepalive.
            if (self) |s| s.noteRx();
            switch (frame.opcode) {
                .text, .binary, .continuation => {
                    if (frame.len > 0) {
                        const want: usize = @intCast(frame.len);
                        if (total + want > buf.len) return error.MessageTooLarge;
                        readFramePayload(r, buf[total .. total + want], frame) catch |err| {
                            if (self) |s| return s.mapReadErr(err);
                            if (err == error.EndOfStream) return 0;
                            return err;
                        };
                        total += want;
                    }
                    if (frame.fin) return total;
                    continue; // more continuation frames to come
                },
                .ping => {
                    const payload = readControlPayload(r, frame) catch |err| {
                        if (self) |s| return s.mapReadErr(err);
                        if (err == error.EndOfStream) return 0;
                        return err;
                    };
                    if (self) |s| s.sendFrame(.pong, payload) catch {};
                    continue;
                },
                .pong => {
                    _ = readControlPayload(r, frame) catch |err| {
                        if (self) |s| return s.mapReadErr(err);
                        if (err == error.EndOfStream) return 0;
                        return err;
                    };
                    continue;
                },
                .close => {
                    _ = readControlPayload(r, frame) catch {};
                    if (self) |s| s.sendFrame(.close, "") catch {};
                    return 0;
                },
                else => {
                    _ = readControlPayload(r, frame) catch |err| {
                        if (self) |s| return s.mapReadErr(err);
                        if (err == error.EndOfStream) return 0;
                        return err;
                    };
                    continue;
                },
            }
        }
    }

    const FrameHeader = struct {
        opcode: Opcode,
        len: u64,
        masked: bool,
        mask: [4]u8,
        /// FIN bit. Ignored by the byte-bridge `read` path (boundaries don't
        /// matter there); honored by `readMessage` to delimit a message.
        fin: bool,
    };

    /// Parse a frame header (everything up to but not including the payload) from
    /// a buffered reader. Free function so both `read` and `readMessage` (and the
    /// unit tests) can use it over any `*std.Io.Reader`.
    fn parseFrameHeader(r: *std.Io.Reader) !FrameHeader {
        const b0 = try r.takeByte();
        const b1 = try r.takeByte();
        const fin = (b0 & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0f)));
        const masked = (b1 & 0x80) != 0;
        var len: u64 = b1 & 0x7f;
        if (len == 126) {
            const ext = try r.takeArray(2);
            len = std.mem.readInt(u16, ext, .big);
        } else if (len == 127) {
            const ext = try r.takeArray(8);
            len = std.mem.readInt(u64, ext, .big);
        }
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) mask = (try r.takeArray(4)).*;
        return .{ .opcode = opcode, .len = len, .masked = masked, .mask = mask, .fin = fin };
    }

    /// Read (and un-mask) a control frame's payload fully. Control frames are
    /// capped at 125 bytes by RFC 6455, so this fits in the reader buffer.
    fn readControlPayload(r: *std.Io.Reader, frame: FrameHeader) ![]const u8 {
        if (frame.len == 0) return "";
        const n: usize = @intCast(@min(frame.len, @as(u64, 125)));
        const slice = try r.take(n);
        if (frame.masked) {
            for (slice, 0..) |*c, i| c.* ^= frame.mask[i & 3];
        }
        return slice;
    }

    /// Read exactly `dst.len` payload bytes of a data frame into `dst`, un-masking
    /// if needed. Streams in reader-sized chunks so a multi-MiB frame needs no
    /// extra buffering. `error.EndOfStream` if the stream ends mid-payload.
    fn readFramePayload(r: *std.Io.Reader, dst: []u8, frame: FrameHeader) !void {
        var off: usize = 0;
        while (off < dst.len) {
            const n = try r.readSliceShort(dst[off..]);
            if (n == 0) return error.EndOfStream;
            if (frame.masked) {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    dst[off + i] ^= frame.mask[(off + i) & 3];
                }
            }
            off += n;
        }
    }

    /// Map read-path errors to the EOF/closed-lane convention. A clean EOF, a TLS
    /// truncation/close_notify, or a peer reset all become `read => 0`.
    fn mapReadErr(self: *WsClient, err: anyerror) anyerror!usize {
        if (self.closed.load(.acquire)) return 0;
        switch (err) {
            error.EndOfStream => return 0,
            error.ReadFailed => {
                // Inspect the underlying socket error; reset/closed → EOF.
                if (self.tcp_reader.getError()) |e| switch (e) {
                    error.ConnectionResetByPeer,
                    error.SocketNotConnected,
                    error.ConnectionTimedOut,
                    error.Canceled,
                    => return 0,
                    else => {},
                };
                // TLS-level truncation is a (benign) end-of-stream for us.
                return 0;
            },
            else => return err,
        }
    }

    /// Emit one masked frame `(opcode, payload)`. Serialized by `write_mtx`. The
    /// payload is masked in bounded chunks (no full copy) so a multi-MiB write
    /// costs no extra memory.
    fn sendFrame(self: *WsClient, opcode: Opcode, payload: []const u8) !void {
        self.write_mtx.lock();
        defer self.write_mtx.unlock();
        if (self.closed.load(.acquire)) return error.BrokenPipe;

        const w = self.appWriter();

        // Header: FIN=1, opcode; MASK=1, 7/16/64-bit length.
        var hdr: [14]u8 = undefined;
        hdr[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        var hdr_len: usize = 2;
        const plen = payload.len;
        if (plen < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(plen));
        } else if (plen <= 0xffff) {
            hdr[1] = 0x80 | 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(plen), .big);
            hdr_len = 4;
        } else {
            hdr[1] = 0x80 | 127;
            std.mem.writeInt(u64, hdr[2..10], plen, .big);
            hdr_len = 10;
        }
        // Fresh 32-bit mask key.
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(hdr[hdr_len .. hdr_len + 4], &mask);
        hdr_len += 4;

        try w.writeAll(hdr[0..hdr_len]);

        // Mask the payload in chunks and write each.
        var chunk: [4096]u8 = undefined;
        var off: usize = 0;
        while (off < plen) {
            const take_n = @min(chunk.len, plen - off);
            var i: usize = 0;
            while (i < take_n) : (i += 1) {
                chunk[i] = payload[off + i] ^ mask[(off + i) & 3];
            }
            try w.writeAll(chunk[0..take_n]);
            off += take_n;
        }

        try self.flushOut();
    }

    /// Emit `bytes` as a single binary frame. Returns `bytes.len` on success, or
    /// 0 on a dead lane (→ `writeAll` yields `error.WriteZero`).
    fn writeImpl(self: *WsClient, bytes: []const u8) anyerror!usize {
        if (self.closed.load(.acquire)) return 0;
        self.sendFrame(.binary, bytes) catch return 0;
        return bytes.len;
    }

    /// Idempotent. Best-effort masked close frame, then `shutdown(.both)` (unblocks
    /// a blocked reader thread inside TLS) + `close` the socket fd.
    fn closeImpl(self: *WsClient) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // Best-effort close frame (under the write mutex). Ignore errors — the
        // socket may already be gone. We set `closed=true` above first, so
        // `sendFrame`'s own guard would bail; do the frame write directly here
        // instead, bypassing that guard, before tearing the socket down.
        self.sendCloseDuringShutdown();
        // shutdown wakes a blocked recv with EOF; then close the fd.
        posix.shutdown(self.socket.handle, .both) catch {};
        self.socket.close();
    }

    /// Like `sendFrame(.close, "")` but callable after `closed` is set (used only
    /// from `closeImpl`). Still takes the write mutex so it can't interleave with
    /// an in-flight writer-thread frame.
    fn sendCloseDuringShutdown(self: *WsClient) void {
        self.write_mtx.lock();
        defer self.write_mtx.unlock();
        const w = self.appWriter();
        var frame: [6]u8 = undefined;
        frame[0] = 0x80 | @as(u8, @intFromEnum(Opcode.close));
        frame[1] = 0x80 | 0; // masked, zero-length payload
        std.crypto.random.bytes(frame[2..6]); // mask key (no payload to mask)
        w.writeAll(&frame) catch return;
        self.flushOut() catch {};
    }

    /// Public idempotent close (the `Stream` contract entry point).
    pub fn close(self: *WsClient) void {
        self.closeImpl();
    }

    // =========================================================================
    // connection.Stream adapter (client side)
    // =========================================================================

    pub fn connectionStream(self: *WsClient) connection.Stream {
        return .{ .ctx = self, .vtable = &connection_vtable };
    }

    const connection_vtable: connection.Stream.VTable = .{
        .read = connRead,
        .write = connWrite,
        .close = closeFn,
    };
    fn connRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        return readImpl(@ptrCast(@alignCast(ctx)), buf);
    }
    fn connWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        return writeImpl(@ptrCast(@alignCast(ctx)), bytes);
    }

    // =========================================================================
    // server.Stream adapter (agent side)
    // =========================================================================

    pub fn serverStream(self: *WsClient) server.Stream {
        return .{ .ctx = self, .vtable = &server_vtable };
    }

    const server_vtable: server.Stream.VTable = .{
        .read = serverRead,
        .write = serverWrite,
        .close = closeFn,
    };
    fn serverRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        return readImpl(@ptrCast(@alignCast(ctx)), buf);
    }
    fn serverWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        return writeImpl(@ptrCast(@alignCast(ctx)), bytes);
    }

    /// Shared close for both vtables.
    fn closeFn(ctx: *anyopaque) void {
        closeImpl(@ptrCast(@alignCast(ctx)));
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "computeAccept: RFC 6455 §1.3 example" {
    // The canonical example from RFC 6455: key "dGhlIHNhbXBsZSBub25jZQ==" →
    // accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
    var buf: [28]u8 = undefined;
    const got = WsClient.computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &buf);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}

test "is101: status-line parsing" {
    try testing.expect(WsClient.is101("HTTP/1.1 101 Switching Protocols\r\n"));
    try testing.expect(WsClient.is101("HTTP/1.1 101\r\n"));
    try testing.expect(!WsClient.is101("HTTP/1.1 200 OK\r\n"));
    try testing.expect(!WsClient.is101("HTTP/1.1 401 Unauthorized\r\n"));
    try testing.expect(!WsClient.is101("garbage"));
}

test "splitHeader: name/value split" {
    const hv = WsClient.splitHeader("Sec-WebSocket-Accept: abc123").?;
    try testing.expectEqualStrings("Sec-WebSocket-Accept", hv.name);
    try testing.expectEqualStrings(" abc123", hv.value);
    try testing.expect(WsClient.splitHeader("no-colon-here") == null);
}

// --- Live relay round-trip (gated on env vars) -------------------------------
//
// Proves the whole stack end-to-end against the PUBLIC relay: TLS handshake +
// cert verification, WebSocket upgrade, masked client write / unmasked server
// read framing. The test device bridges to sshd, so the first bytes we read back
// are an SSH banner — we assert it starts with "SSH-2.0".
//
// Skipped (passes trivially) unless all three env vars are set:
//   GHOSTTY_WS_TEST_BASE    e.g. wss://relay.example.com   (or https://)
//   GHOSTTY_WS_TEST_DEVICE  the target device id
//   GHOSTTY_WS_TEST_TOKEN   the client bearer token

test "live relay: SSH banner round-trip (gated)" {
    const alloc = testing.allocator;

    const base = std.process.getEnvVarOwned(alloc, "GHOSTTY_WS_TEST_BASE") catch return;
    defer alloc.free(base);
    const device = std.process.getEnvVarOwned(alloc, "GHOSTTY_WS_TEST_DEVICE") catch return;
    defer alloc.free(device);
    const token = std.process.getEnvVarOwned(alloc, "GHOSTTY_WS_TEST_TOKEN") catch return;
    defer alloc.free(token);

    const url = try std.fmt.allocPrint(alloc, "{s}/v1/client/connect?device={s}", .{
        std.mem.trimRight(u8, base, "/"),
        device,
    });
    defer alloc.free(url);

    const authz = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(authz);

    const headers = [_]Header{.{ .name = "Authorization", .value = authz }};

    const ws = try WsClient.connectUrl(alloc, url, &headers);
    defer ws.deinit();

    const stream = ws.connectionStream();

    // Read until we have at least the banner prefix, or EOF.
    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (total < "SSH-2.0".len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) break; // EOF before banner
        total += n;
    }
    std.debug.print("\n[live] first {d} bytes: {s}\n", .{ total, std.mem.trimRight(u8, buf[0..total], "\r\n") });
    try testing.expect(total >= "SSH-2.0".len);
    try testing.expectEqualStrings("SSH-2.0", buf[0.."SSH-2.0".len]);
}

// --- Message framing (readMessage) over synthetic server frames --------------
//
// Drives the reassembly core (`messageFromReader`) directly over a fixed buffer
// of hand-built UNMASKED server frames (self = null, so no control replies are
// sent — we only assert the data reassembly + boundary behavior).

/// Append one unmasked server frame `(fin, opcode, payload)` to `list`.
fn appendFrame(
    list: *std.ArrayList(u8),
    alloc: Allocator,
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
) !void {
    var b0: u8 = @intFromEnum(opcode);
    if (fin) b0 |= 0x80;
    try list.append(alloc, b0);
    // Test payloads are all < 126, so the 7-bit length form suffices (unmasked).
    try list.append(alloc, @intCast(payload.len));
    try list.appendSlice(alloc, payload);
}

test "readMessage: single binary message" {
    const alloc = testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);
    try appendFrame(&frames, alloc, true, .binary, "hello");

    var r: std.Io.Reader = .fixed(frames.items);
    var buf: [64]u8 = undefined;
    const n = try WsClient.messageFromReader(&r, &buf, null);
    try testing.expectEqualStrings("hello", buf[0..n]);

    // Next read hits EOF → 0.
    try testing.expectEqual(@as(usize, 0), try WsClient.messageFromReader(&r, &buf, null));
}

test "readMessage: text reassembled across continuation frames" {
    const alloc = testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);
    try appendFrame(&frames, alloc, false, .text, "Hel");
    try appendFrame(&frames, alloc, false, .continuation, "lo, ");
    try appendFrame(&frames, alloc, true, .continuation, "world");

    var r: std.Io.Reader = .fixed(frames.items);
    var buf: [64]u8 = undefined;
    const n = try WsClient.messageFromReader(&r, &buf, null);
    try testing.expectEqualStrings("Hello, world", buf[0..n]);
}

test "readMessage: interleaved ping/pong are skipped (self=null)" {
    const alloc = testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);
    try appendFrame(&frames, alloc, true, .ping, "pingdata");
    try appendFrame(&frames, alloc, true, .pong, "");
    try appendFrame(&frames, alloc, true, .binary, "ok");

    var r: std.Io.Reader = .fixed(frames.items);
    var buf: [64]u8 = undefined;
    const n = try WsClient.messageFromReader(&r, &buf, null);
    try testing.expectEqualStrings("ok", buf[0..n]);
}

test "readMessage: close frame returns 0 (clean EOF)" {
    const alloc = testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);
    try appendFrame(&frames, alloc, true, .close, "");

    var r: std.Io.Reader = .fixed(frames.items);
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try WsClient.messageFromReader(&r, &buf, null));
}

test "readMessage: message larger than buffer errors" {
    const alloc = testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);
    try appendFrame(&frames, alloc, true, .binary, "0123456789");

    var r: std.Io.Reader = .fixed(frames.items);
    var buf: [4]u8 = undefined;
    try testing.expectError(error.MessageTooLarge, WsClient.messageFromReader(&r, &buf, null));
}

test {
    testing.refAllDecls(@This());
}
