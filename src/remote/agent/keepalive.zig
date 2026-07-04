//! Control-channel keepalive / dead-link detection for the relay daemon.
//!
//! ## The bug this fixes
//! `--relay` mode holds one control WebSocket to the relay. The relay pings it
//! every 15s server-side (`relay/handlers.go: heartbeatInterval`) and marks the
//! device offline when its ping fails. When THIS machine sleeps, the relay's
//! heartbeat fails and the relay closes its end — but on wake the agent is still
//! parked in a blocking `readMessage` on a TCP connection whose peer is long
//! gone. Nothing ever arrives, nothing ever errors, so the agent believes it is
//! connected forever and the device never comes back online until the process
//! is restarted.
//!
//! ## The fix: an agent-side liveness clock + probe
//! A healthy control link ALWAYS carries inbound traffic: the relay's 15s
//! server pings (auto-answered by the read path) and pongs to our own pings.
//! `WsClient` timestamps every successfully parsed inbound frame
//! (`lastRxMillis`, wall clock so system sleep counts). This module adds the
//! other half:
//!
//!   - every `ping_interval_ms` (20s) send a masked WS ping, and
//!   - if NO inbound frame has arrived within `stale_after_ms` (50s — more than
//!     3 relay heartbeat intervals, so jitter can't false-positive), declare
//!     the link stale: log, `close()` it, and return.
//!
//! Closing does `shutdown(.both)` on the socket, which unblocks the control
//! loop's blocked `readMessage` with EOF → `serveControl` returns → the
//! existing reconnect loop (3s backoff) redials. After a sleep/wake, the wall
//! clock gap alone exceeds the window, so the FIRST tick after wake (≤20s)
//! detects the dead link and the agent is back online seconds later.
//!
//! ## Why a (tiny) dedicated thread, not a read timeout
//! The control read blocks inside `std.crypto.tls.Client`'s buffered reader.
//! A socket-level timeout (SO_RCVTIMEO / pre-read poll) was considered and
//! rejected:
//!   - `readMessage` handles ping/pong INTERNALLY and re-blocks, so a poll
//!     before the call cannot bound the block (the only traffic on an idle
//!     healthy link IS those control frames);
//!   - a timeout would surface as `error.ReadFailed` from inside the TLS
//!     stream, potentially mid-record, and `std.crypto.tls`'s reader is not
//!     documented to be resumable after an underlying read error — turning a
//!     benign quiet spell into a torn session;
//!   - `WsClient`'s threading contract ALREADY guarantees `close()` may race a
//!     blocked read (that is how every other teardown path works), and
//!     `sendFrame` is `write_mtx`-serialized, so a side thread that only calls
//!     `sendPing` + `close` rides existing, proven contracts.
//! Everything used here (`std.Thread`, `ResetEvent.timedWait`, atomics,
//! `milliTimestamp`) is portable std — the same binary ships to Windows.
//!
//! The decision logic is a pure function (`evaluate`) and the loop runs over a
//! small `Link` vtable, so both are unit-testable without a network; an
//! integration test below runs the REAL `WsClient` against a local WS server
//! that goes silent and proves detection + redial.

const std = @import("std");
const ws_client = @import("../ws_client.zig");

/// Timing knobs. Defaults are the production values; tests shrink them.
pub const Config = struct {
    /// How often to wake up: send a ping + check for staleness. Also the upper
    /// bound on how long after system wake the first check happens.
    ping_interval_ms: i64 = 20_000,
    /// No inbound frame for this long ⇒ the link is dead. Must comfortably
    /// exceed the relay's 15s server-ping interval (this is > 3×) and be well
    /// under "annoying" (detection worst case ≈ interval + this ≈ 70s).
    stale_after_ms: i64 = 50_000,
};

/// What one keepalive tick should do.
pub const Action = enum { ping, stale };

/// Pure staleness arithmetic: given "now" and the last-inbound-traffic
/// timestamp (both wall-clock ms), decide whether to probe or give up. A
/// backwards clock step (negative age) is treated as fresh — worst case that
/// delays detection by one window, and never false-positives.
pub fn evaluate(cfg: Config, now_ms: i64, last_rx_ms: i64) Action {
    const age = now_ms - last_rx_ms;
    if (age >= cfg.stale_after_ms) return .stale;
    return .ping;
}

/// The minimal surface the keepalive needs from a connection. A vtable (rather
/// than `*WsClient` directly) so the loop is unit-testable with a fake link.
pub const Link = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Wall-clock ms of the last inbound frame.
        lastRxMillis: *const fn (ctx: *anyopaque) i64,
        /// Send a keepalive ping; false if the write failed (dead write lane).
        sendPing: *const fn (ctx: *anyopaque) bool,
        /// Tear the link down (must unblock a concurrently blocked read).
        close: *const fn (ctx: *anyopaque) void,
    };
};

/// Adapt a `*WsClient` to a `Link` (the production wiring).
pub fn wsLink(ws: *ws_client.WsClient) Link {
    return .{ .ctx = ws, .vtable = &ws_vtable };
}

const ws_vtable: Link.VTable = .{
    .lastRxMillis = wsLastRx,
    .sendPing = wsSendPing,
    .close = wsClose,
};

fn wsLastRx(ctx: *anyopaque) i64 {
    const ws: *ws_client.WsClient = @ptrCast(@alignCast(ctx));
    return ws.lastRxMillis();
}
fn wsSendPing(ctx: *anyopaque) bool {
    const ws: *ws_client.WsClient = @ptrCast(@alignCast(ctx));
    ws.sendPing() catch return false;
    return true;
}
fn wsClose(ctx: *anyopaque) void {
    const ws: *ws_client.WsClient = @ptrCast(@alignCast(ctx));
    ws.close();
}

/// The keepalive loop state. Construct, `std.Thread.spawn(.., run, .{&ka})`,
/// and on normal connection teardown call `requestStop()` then join. `run`
/// also returns by itself after declaring the link stale (having `close`d it).
pub const Keepalive = struct {
    cfg: Config = .{},
    link: Link,
    /// Set by `requestStop` to make `run` return promptly (no full-interval
    /// sleep on teardown).
    stop: std.Thread.ResetEvent = .{},
    /// True iff `run` declared the link dead (stale or ping-write failure) and
    /// closed it. For observability + tests.
    went_stale: std.atomic.Value(bool) = .{ .raw = false },

    /// Thread entry. Ticks every `ping_interval_ms`: stale-check, then ping.
    /// Returns when `requestStop` is called or when the link is declared dead
    /// (after closing it, which unblocks the control read loop).
    pub fn run(self: *Keepalive) void {
        const interval_ns: u64 =
            @as(u64, @intCast(self.cfg.ping_interval_ms)) * std.time.ns_per_ms;
        while (true) {
            // Sleep one interval, but wake immediately on requestStop.
            if (self.stop.timedWait(interval_ns)) {
                return; // stop requested: clean teardown, link not ours to close
            } else |_| {} // timeout — take a tick
            if (self.stop.isSet()) return;

            const now = std.time.milliTimestamp();
            const last = self.link.vtable.lastRxMillis(self.link.ctx);
            switch (evaluate(self.cfg, now, last)) {
                .stale => {
                    self.went_stale.store(true, .monotonic);
                    std.debug.print(
                        "ghoztty-agent: relay control stale ({d}ms without inbound traffic); reconnecting\n",
                        .{now - last},
                    );
                    self.link.vtable.close(self.link.ctx);
                    return;
                },
                .ping => {
                    if (!self.link.vtable.sendPing(self.link.ctx)) {
                        self.went_stale.store(true, .monotonic);
                        std.debug.print(
                            "ghoztty-agent: relay control ping write failed; reconnecting\n",
                            .{},
                        );
                        self.link.vtable.close(self.link.ctx);
                        return;
                    }
                },
            }
        }
    }

    /// Ask `run` to return promptly (idempotent). Call before joining.
    pub fn requestStop(self: *Keepalive) void {
        self.stop.set();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "evaluate: fresh traffic pings, old traffic is stale" {
    const cfg: Config = .{ .ping_interval_ms = 20_000, .stale_after_ms = 50_000 };
    // Traffic just now → probe.
    try testing.expectEqual(Action.ping, evaluate(cfg, 1_000_000, 1_000_000));
    // Inside the window → probe.
    try testing.expectEqual(Action.ping, evaluate(cfg, 1_000_000, 1_000_000 - 49_999));
    // Exactly at the window → stale.
    try testing.expectEqual(Action.stale, evaluate(cfg, 1_000_000, 1_000_000 - 50_000));
    // Way past (the wake-from-sleep case: hours of wall-clock gap) → stale.
    try testing.expectEqual(Action.stale, evaluate(cfg, 10_000_000, 1_000_000));
    // Clock stepped backwards → treated as fresh, never a false positive.
    try testing.expectEqual(Action.ping, evaluate(cfg, 1_000_000, 1_000_500));
}

/// A fake `Link` for driving `Keepalive.run` without a network.
const FakeLink = struct {
    /// What `lastRxMillis` reports. Tests either freeze it (silent peer) or
    /// refresh it from `sendPing` (live peer answering pongs instantly).
    last_rx: std.atomic.Value(i64),
    pings: std.atomic.Value(u32) = .{ .raw = 0 },
    closes: std.atomic.Value(u32) = .{ .raw = 0 },
    /// When false, `sendPing` reports a write failure.
    ping_ok: bool = true,
    /// When true, each ping "elicits a pong": last_rx snaps to now.
    refresh_on_ping: bool = false,

    fn init() FakeLink {
        return .{ .last_rx = .{ .raw = std.time.milliTimestamp() } };
    }

    fn link(self: *FakeLink) Link {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Link.VTable = .{
        .lastRxMillis = lastRx,
        .sendPing = sendPing,
        .close = close,
    };
    fn lastRx(ctx: *anyopaque) i64 {
        const self: *FakeLink = @ptrCast(@alignCast(ctx));
        return self.last_rx.load(.monotonic);
    }
    fn sendPing(ctx: *anyopaque) bool {
        const self: *FakeLink = @ptrCast(@alignCast(ctx));
        _ = self.pings.fetchAdd(1, .monotonic);
        if (self.refresh_on_ping)
            self.last_rx.store(std.time.milliTimestamp(), .monotonic);
        return self.ping_ok;
    }
    fn close(ctx: *anyopaque) void {
        const self: *FakeLink = @ptrCast(@alignCast(ctx));
        _ = self.closes.fetchAdd(1, .monotonic);
    }
};

test "keepalive: silent link is declared stale and closed within the window" {
    var fake = FakeLink.init(); // last_rx frozen at start — a peer gone silent
    var ka = Keepalive{
        .cfg = .{ .ping_interval_ms = 10, .stale_after_ms = 40 },
        .link = fake.link(),
    };
    const started = std.time.milliTimestamp();
    ka.run(); // returns by itself on stale
    const elapsed = std.time.milliTimestamp() - started;

    try testing.expect(ka.went_stale.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), fake.closes.load(.monotonic));
    // Not before the window (no premature disconnects)...
    try testing.expect(elapsed >= 40);
    // ...and within a couple of windows even on a loaded CI box.
    try testing.expect(elapsed < 5_000);
}

test "keepalive: live link keeps getting pinged and is never closed" {
    var fake = FakeLink.init();
    fake.refresh_on_ping = true; // every probe is answered
    var ka = Keepalive{
        .cfg = .{ .ping_interval_ms = 5, .stale_after_ms = 25 },
        .link = fake.link(),
    };
    const t = try std.Thread.spawn(.{}, Keepalive.run, .{&ka});
    std.Thread.sleep(120 * std.time.ns_per_ms); // ~24 intervals ≈ many windows
    ka.requestStop();
    t.join();

    try testing.expect(!ka.went_stale.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), fake.closes.load(.monotonic));
    try testing.expect(fake.pings.load(.monotonic) >= 3);
}

test "keepalive: ping write failure closes the link immediately" {
    var fake = FakeLink.init();
    fake.ping_ok = false; // dead write lane
    var ka = Keepalive{
        .cfg = .{ .ping_interval_ms = 5, .stale_after_ms = 10_000 },
        .link = fake.link(),
    };
    ka.run(); // first tick pings, ping fails, run returns
    try testing.expect(ka.went_stale.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), fake.closes.load(.monotonic));
}

test "keepalive: requestStop wakes a long sleep promptly" {
    var fake = FakeLink.init();
    var ka = Keepalive{
        .cfg = .{ .ping_interval_ms = 60_000, .stale_after_ms = 120_000 },
        .link = fake.link(),
    };
    const t = try std.Thread.spawn(.{}, Keepalive.run, .{&ka});
    ka.requestStop();
    const started = std.time.milliTimestamp();
    t.join();
    // Joined in far less than the 60s interval — teardown is not delayed.
    try testing.expect(std.time.milliTimestamp() - started < 5_000);
    try testing.expectEqual(@as(u32, 0), fake.closes.load(.monotonic));
}

// -----------------------------------------------------------------------------
// Integration: the REAL WsClient + Keepalive against a local WS server
// (mimics the wp4-e2e "drive the real code against a local peer" pattern).
// Plaintext `ws://` per `WsClient.Options.tls` — loopback only.
// -----------------------------------------------------------------------------

/// A minimal loopback WebSocket server: accepts connections serially, performs
/// the RFC 6455 upgrade (validating nothing, but recording whether the
/// `X-Ghoztty-Hostname` header was present), then either goes SILENT (the
/// sleep/wake repro: reads and discards but never writes) or, when
/// `ping_every_ms` is set, sends unmasked server pings on that cadence (the
/// healthy-relay heartbeat, `relay/handlers.go`).
const TestWsServer = struct {
    listener: std.net.Server,
    thread: std.Thread = undefined,
    ping_every_ms: ?u64,
    stopping: std.atomic.Value(bool) = .{ .raw = false },
    saw_hostname_header: std.atomic.Value(bool) = .{ .raw = false },
    upgrades: std.atomic.Value(u32) = .{ .raw = 0 },

    fn start(ping_every_ms: ?u64) !*TestWsServer {
        const self = try testing.allocator.create(TestWsServer);
        errdefer testing.allocator.destroy(self);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .ping_every_ms = ping_every_ms,
        };
        self.thread = try std.Thread.spawn(.{}, TestWsServer.serve, .{self});
        return self;
    }

    fn port(self: *TestWsServer) u16 {
        return self.listener.listen_address.in.getPort();
    }

    /// Stop accepting and join. Wakes a blocked `accept` portably by dialing
    /// (and immediately closing) a throwaway connection to ourselves.
    fn stop(self: *TestWsServer) void {
        self.stopping.store(true, .monotonic);
        if (std.net.tcpConnectToAddress(self.listener.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.listener.deinit();
        testing.allocator.destroy(self);
    }

    fn serve(self: *TestWsServer) void {
        while (!self.stopping.load(.monotonic)) {
            const conn = self.listener.accept() catch return;
            self.handleConn(conn.stream);
            conn.stream.close();
        }
    }

    fn handleConn(self: *TestWsServer, stream: std.net.Stream) void {
        // --- Read the upgrade request until CRLFCRLF -------------------------
        var req_buf: [4096]u8 = undefined;
        var req_len: usize = 0;
        while (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") == null) {
            if (req_len == req_buf.len) return;
            const n = stream.read(req_buf[req_len..]) catch return;
            if (n == 0) return; // includes the stop() wake-up connection
            req_len += n;
        }
        const req = req_buf[0..req_len];

        // --- Extract Sec-WebSocket-Key + note the hostname header ------------
        const key = headerValue(req, "sec-websocket-key") orelse return;
        if (headerValue(req, "x-ghoztty-hostname") != null)
            self.saw_hostname_header.store(true, .monotonic);

        // --- 101 response with the accept hash --------------------------------
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key);
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        sha1.final(&digest);
        var accept_buf: [28]u8 = undefined;
        const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

        var resp_buf: [256]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return;
        // Count the upgrade BEFORE writing the response: the client's connect
        // returns as soon as it reads the 101, and the test asserts on this
        // counter right after — incrementing after the write would race it.
        _ = self.upgrades.fetchAdd(1, .monotonic);
        stream.writeAll(resp) catch return;

        // --- Optional heartbeat writer (the healthy-relay case) ---------------
        var writer_thread: ?std.Thread = null;
        var conn_done = std.atomic.Value(bool){ .raw = false };
        if (self.ping_every_ms) |every| {
            writer_thread = std.Thread.spawn(.{}, pingLoop, .{ stream, every, &conn_done }) catch null;
        }

        // --- Read-and-discard until the client goes away ----------------------
        // (Never writes on its own: with ping_every_ms == null this is the
        // relay whose peer state died while we slept — total inbound silence.)
        var sink: [512]u8 = undefined;
        while (true) {
            const n = stream.read(&sink) catch break;
            if (n == 0) break;
        }
        conn_done.store(true, .monotonic);
        if (writer_thread) |t| t.join();
    }

    fn pingLoop(stream: std.net.Stream, every_ms: u64, done: *std.atomic.Value(bool)) void {
        // Unmasked, empty server ping: FIN|opcode 0x9, len 0.
        const ping_frame = [_]u8{ 0x89, 0x00 };
        while (!done.load(.monotonic)) {
            stream.writeAll(&ping_frame) catch return;
            std.Thread.sleep(every_ms * std.time.ns_per_ms);
        }
    }

    /// Case-insensitive `Name: value` lookup in a raw HTTP request.
    fn headerValue(req: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, req, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

/// Mimics `serveControl`'s blocking control read on its own thread, reporting
/// the terminal `readMessage` result and signalling completion.
const BlockingReader = struct {
    ws: *ws_client.WsClient,
    done: std.Thread.ResetEvent = .{},
    /// Final readMessage result: byte count, or -1 for an error.
    result: std.atomic.Value(i64) = .{ .raw = -2 },

    fn run(self: *BlockingReader) void {
        var buf: [512]u8 = undefined;
        // Loop like serveControl: control frames are consumed internally, so a
        // healthy silent link never returns; only EOF (0) or an error does.
        const n = self.ws.readMessage(&buf) catch {
            self.result.store(-1, .monotonic);
            self.done.set();
            return;
        };
        self.result.store(@intCast(n), .monotonic);
        self.done.set();
    }
};

test "integration: silent server → keepalive detects stale, unblocks read, redial works" {
    const alloc = testing.allocator;

    var srv = try TestWsServer.start(null); // SILENT after upgrade — the repro
    defer srv.stop();

    const url = try std.fmt.allocPrint(alloc, "ws://127.0.0.1:{d}/v1/agent/control", .{srv.port()});
    defer alloc.free(url);
    const headers = [_]ws_client.Header{
        .{ .name = "Authorization", .value = "Bearer test-token" },
        .{ .name = "X-Ghoztty-Hostname", .value = "test-host" },
    };

    // Dial #1 — the connection that will die of silence.
    const ctrl = try ws_client.WsClient.connectUrl(alloc, url, &headers);

    var ka = Keepalive{
        .cfg = .{ .ping_interval_ms = 40, .stale_after_ms = 150 },
        .link = wsLink(ctrl),
    };
    const ka_thread = try std.Thread.spawn(.{}, Keepalive.run, .{&ka});

    var reader = BlockingReader{ .ws = ctrl };
    const rd_thread = try std.Thread.spawn(.{}, BlockingReader.run, .{&reader});

    // The keepalive must declare the link stale AND release the blocked read
    // well within a few windows (window = 150ms; give CI 5s of slack).
    reader.done.timedWait(5 * std.time.ns_per_s) catch {
        // Unstick everything so the test fails rather than hangs.
        ctrl.close();
        rd_thread.join();
        ka.requestStop();
        ka_thread.join();
        ctrl.deinit();
        return error.StaleDetectionTimedOut;
    };
    rd_thread.join();
    ka_thread.join();

    try testing.expect(ka.went_stale.load(.monotonic));
    // The blocked control read surfaced as clean EOF (0) → serveControl
    // returns → relayLoop's existing 3s-backoff reconnect runs.
    try testing.expectEqual(@as(i64, 0), reader.result.load(.monotonic));
    ctrl.deinit();

    // Redial (#2): the reconnect the relay loop performs succeeds against the
    // same server — the agent is back, no process restart needed.
    const ctrl2 = try ws_client.WsClient.connectUrl(alloc, url, &headers);
    ctrl2.deinit();

    try testing.expectEqual(@as(u32, 2), srv.upgrades.load(.monotonic));
    // The dial carried the hostname header (relay-side pill support).
    try testing.expect(srv.saw_hostname_header.load(.monotonic));
}

test "integration: server heartbeat pings keep the link alive (no false stale)" {
    const alloc = testing.allocator;

    var srv = try TestWsServer.start(30); // server ping every 30ms (the relay heartbeat)
    defer srv.stop();

    const url = try std.fmt.allocPrint(alloc, "ws://127.0.0.1:{d}/v1/agent/control", .{srv.port()});
    defer alloc.free(url);
    const headers = [_]ws_client.Header{.{ .name = "Authorization", .value = "Bearer test-token" }};

    const ctrl = try ws_client.WsClient.connectUrl(alloc, url, &headers);

    var ka = Keepalive{
        .cfg = .{ .ping_interval_ms = 40, .stale_after_ms = 150 },
        .link = wsLink(ctrl),
    };
    const ka_thread = try std.Thread.spawn(.{}, Keepalive.run, .{&ka});

    var reader = BlockingReader{ .ws = ctrl };
    const rd_thread = try std.Thread.spawn(.{}, BlockingReader.run, .{&reader});

    // Several stale windows pass; the server's pings are counted as inbound
    // traffic (readMessage consumes them internally, WsClient timestamps them),
    // so the keepalive never trips and the read stays blocked.
    std.Thread.sleep(600 * std.time.ns_per_ms);
    try testing.expect(!ka.went_stale.load(.monotonic));
    try testing.expect(!reader.done.isSet());

    // Clean teardown: stop the keepalive, then close to release the reader.
    ka.requestStop();
    ka_thread.join();
    ctrl.close();
    rd_thread.join();
    try testing.expectEqual(@as(i64, 0), reader.result.load(.monotonic));
    ctrl.deinit();
}

test {
    testing.refAllDecls(@This());
}
