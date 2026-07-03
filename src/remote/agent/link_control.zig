//! User-controlled relay-link state (tray "Disconnect"/"Reconnect") + the
//! reconnect-loop driver that obeys it.
//!
//! ## Why this exists
//! `--relay` mode holds one control WebSocket to the relay and redials it
//! forever (3s backoff). The Windows tray needs to let the human take that
//! link DOWN on demand — the agent goes offline on the relay, but LOCAL
//! sessions stay alive (a control drop only ever DETACHes sessions, never
//! terminates them — see `main.zig` §7.1), so bringing the link back UP
//! re-exposes them — and bring it back UP without waiting out a backoff.
//!
//! The tray runs on its own Win32 message-pump thread, so the toggle must be
//! thread-safe and must take effect promptly in BOTH directions:
//!
//!   - **Disconnect** (`disconnect`): store desired=offline, close the LIVE
//!     control connection (the exact teardown contract `keepalive.zig` relies
//!     on: `WsClient.close` is idempotent and unblocks a concurrently blocked
//!     `readMessage` with EOF), and set the wake event so the loop parks
//!     instead of redialing.
//!   - **Reconnect** (`reconnect`): store desired=online and set the wake
//!     event — the parked loop redials IMMEDIATELY (and a loop mid-backoff
//!     after a dial failure is woken early too; every wait in the loop is
//!     interruptible, mirroring the keepalive stop event).
//!
//! ## Pieces
//!   - `LinkControl`: the shared state — an atomic desired-state enum, a
//!     `ResetEvent` making every loop wait interruptible, and a mutex-guarded
//!     registration of the live connection so `disconnect` closes it exactly
//!     once (take-and-clear under the mutex).
//!   - `Transport`: a tiny vtable (dial/serve/close/deinit) abstracting the
//!     relay connection so the loop is unit-testable without a network.
//!   - `runLoop`: THE connect loop — park while offline, dial, serve, back
//!     off, repeat — extracted from `main.zig`'s relay mode so its transitions
//!     are testable on any host (the tray itself only runs on Windows).
//!
//! `main.zig` wires a real-WsClient `Transport` (dial = control WS + keepalive
//! thread; serve = `serveControl`); `tray.zig` calls `disconnect`/`reconnect`/
//! `display` from the message-pump thread. `--listen` TCP mode has no relay
//! link and never constructs one of these (the tray gets a null and shows no
//! Disconnect/Reconnect items).

const std = @import("std");

/// What the user wants the relay link to be doing.
pub const Desired = enum(u8) {
    /// Keep a control connection up (dial, serve, back off, redial).
    online,
    /// User chose Disconnect: no connection, no redialing; park until told
    /// otherwise. Local sessions stay alive in the store.
    offline,
    /// Terminate the loop (tests / clean shutdown). `runLoop` returns.
    stop,
};

/// The user-facing link status (tray tooltip / menu status line).
pub const Display = enum(u8) {
    /// A control connection is up.
    connected,
    /// Desired online but not currently connected (dialing / backing off).
    reconnecting,
    /// Disconnected by the user (or stopping).
    offline,
};

/// The minimal connection surface `runLoop` needs. A vtable (rather than
/// `*WsClient` directly) so the loop is unit-testable with a fake transport.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Dial one connection. Returns an opaque connection handle, or null
        /// on failure (the loop backs off and retries).
        dial: *const fn (ctx: *anyopaque) ?*anyopaque,
        /// Serve the connection, BLOCKING until it ends (EOF/error/closed).
        serve: *const fn (ctx: *anyopaque, conn: *anyopaque) void,
        /// Close the connection: thread-safe, idempotent, and MUST unblock a
        /// concurrently blocked `serve` (the `WsClient.close` contract).
        close: *const fn (ctx: *anyopaque, conn: *anyopaque) void,
        /// Final teardown/free after `serve` returned. Called exactly once
        /// per successful dial, from the loop thread.
        deinit: *const fn (ctx: *anyopaque, conn: *anyopaque) void,
    };
};

/// Thread-safe desired-state + live-connection registry shared between the
/// control loop (one thread) and the tray (another). All public methods are
/// callable from any thread; only `runLoop` may wait on `wake`.
pub const LinkControl = struct {
    /// Relay host for display ("Connected to <host>"). Borrowed; must outlive
    /// the tray + loop (daemon lifetime in practice).
    host: []const u8 = "",

    desired: std.atomic.Value(Desired) = .{ .raw = .online },
    /// True while a dialed connection is being served (for `display`).
    connected: std.atomic.Value(bool) = .{ .raw = false },
    /// Wakes the loop out of ANY wait (backoff sleep or offline park) so a
    /// state change takes effect promptly. Only the loop thread waits/resets.
    wake: std.Thread.ResetEvent = .{},

    /// Guards `live`. Registration is take-and-clear so the live connection
    /// is closed through here AT MOST once.
    mutex: std.Thread.Mutex = .{},
    live: ?Live = null,

    const Live = struct { transport: Transport, conn: *anyopaque };

    // --- Tray-side API (any thread) -----------------------------------------

    /// User chose Disconnect: suspend redialing and close the live connection
    /// (if any) to unblock the loop's blocked serve/read. Idempotent.
    pub fn disconnect(self: *LinkControl) void {
        self.desired.store(.offline, .release);
        self.closeLive();
        self.wake.set();
    }

    /// User chose Reconnect: resume the loop immediately (no waiting out a
    /// backoff). Only flips offline→online — never resurrects a stopping link.
    pub fn reconnect(self: *LinkControl) void {
        _ = self.desired.cmpxchgStrong(.offline, .online, .acq_rel, .acquire);
        self.wake.set();
    }

    /// Credentials changed (relay.env reload — see `relay_creds.zig`): close
    /// the LIVE connection (if any) so the loop redials promptly with fresh
    /// credentials. Unlike `disconnect` this leaves the desired state alone:
    /// an online link drops and redials after one backoff, while a
    /// user-chosen Disconnect stays parked (the next user Reconnect dials
    /// with the new credentials anyway). Idempotent, any thread.
    pub fn bounce(self: *LinkControl) void {
        self.closeLive();
    }

    /// Terminate the loop from either state (closes a live connection first).
    pub fn stopLoop(self: *LinkControl) void {
        self.desired.store(.stop, .release);
        self.closeLive();
        self.wake.set();
    }

    /// Current user-facing status (tray tooltip / menu text / status line).
    pub fn display(self: *const LinkControl) Display {
        if (self.desired.load(.acquire) != .online) return .offline;
        return if (self.connected.load(.acquire)) .connected else .reconnecting;
    }

    // --- Loop-side API (the `runLoop` thread) --------------------------------

    /// Park while desired == offline. Returns the (non-offline) desired state
    /// to act on: `.online` → dial, `.stop` → return.
    pub fn awaitOnline(self: *LinkControl) Desired {
        while (true) {
            const d = self.desired.load(.acquire);
            if (d != .offline) return d;
            // Wait for a toggle. The event may be stale-set from the toggle
            // that put us offline — one extra spin re-checks and re-parks.
            self.wake.wait();
            self.wake.reset();
        }
    }

    /// Sleep up to `ms`, waking early if the tray toggles state. Every reset
    /// here is followed by a desired-state re-check in the loop, so a
    /// "swallowed" set can never lose a transition.
    pub fn interruptibleSleep(self: *LinkControl, ms: u64) void {
        if (self.wake.timedWait(ms * std.time.ns_per_ms)) {
            self.wake.reset(); // woken by a state change; consume the wake
        } else |_| {} // full sleep elapsed
    }

    /// Register the freshly dialed connection so `disconnect` can close it.
    /// Closes it IMMEDIATELY if a disconnect/stop landed during the dial
    /// (that toggle found nothing registered to close — honor it now).
    pub fn registerLive(self: *LinkControl, transport: Transport, conn: *anyopaque) void {
        self.mutex.lock();
        self.live = .{ .transport = transport, .conn = conn };
        self.mutex.unlock();
        if (self.desired.load(.acquire) != .online) self.closeLive();
    }

    /// Unregister after `serve` returned (before the loop deinits the
    /// connection, so a late `disconnect` can never close a freed handle).
    pub fn clearLive(self: *LinkControl) void {
        self.mutex.lock();
        self.live = null;
        self.mutex.unlock();
    }

    /// Take-and-close the registered connection (at most once — the entry is
    /// cleared under the mutex before `close` runs, outside the lock).
    fn closeLive(self: *LinkControl) void {
        self.mutex.lock();
        const live = self.live;
        self.live = null;
        self.mutex.unlock();
        if (live) |l| l.transport.vtable.close(l.transport.ctx, l.conn);
    }
};

/// THE connect loop: park while offline, dial, serve until the connection
/// ends, back off, repeat. Every wait is interruptible by the tray's
/// `disconnect`/`reconnect`/`stopLoop`. Returns only on `.stop`.
///
/// This is `main.zig`'s relay control loop with the transport abstracted out,
/// so the suspend/resume transitions are unit-testable on any host.
pub fn runLoop(link: *LinkControl, transport: Transport, backoff_ms: u64) void {
    while (true) {
        switch (link.awaitOnline()) {
            .stop => return,
            .online => {},
            .offline => unreachable, // awaitOnline never returns offline
        }

        const conn = transport.vtable.dial(transport.ctx) orelse {
            // Dial failed: back off, but wake early on any tray toggle so a
            // user Disconnect parks (and a Reconnect-after-Disconnect redials)
            // without waiting out the backoff.
            link.interruptibleSleep(backoff_ms);
            continue;
        };

        link.connected.store(true, .release);
        link.registerLive(transport, conn);

        transport.vtable.serve(transport.ctx, conn);

        link.connected.store(false, .release);
        link.clearLive();
        transport.vtable.deinit(transport.ctx, conn);

        // Connection ended (peer drop, keepalive stale-close, or user
        // disconnect). Back off before redialing; a user disconnect has
        // already set the wake event, so this returns immediately and the
        // next awaitOnline parks.
        link.interruptibleSleep(backoff_ms);
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Poll `pred(ctx)` every 2ms until true or `timeout_ms` elapses.
fn poll(timeout_ms: i64, ctx: anytype, pred: anytype) !void {
    var waited: i64 = 0;
    while (!pred(ctx)) {
        if (waited > timeout_ms) return error.ConditionTimedOut;
        std.Thread.sleep(2 * std.time.ns_per_ms);
        waited += 2;
    }
}

/// A fake `Transport` for driving `runLoop` without a network. Each dialed
/// connection blocks in `serve` until `close`d (like a healthy quiet control
/// WS blocks in readMessage until the socket is shut down).
const FakeTransport = struct {
    dials: std.atomic.Value(u32) = .{ .raw = 0 },
    closes: std.atomic.Value(u32) = .{ .raw = 0 },
    deinits: std.atomic.Value(u32) = .{ .raw = 0 },
    /// When false, `dial` fails (the loop backs off).
    dial_ok: std.atomic.Value(bool) = .{ .raw = true },
    /// When set, `dial` invokes `disconnect` on this link BEFORE returning the
    /// connection — the dial/disconnect race (toggle lands mid-dial).
    disconnect_in_dial: ?*LinkControl = null,

    const Conn = struct { done: std.Thread.ResetEvent = .{} };

    fn transport(self: *FakeTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{
        .dial = dial,
        .serve = serve,
        .close = close,
        .deinit = deinit,
    };

    fn dial(ctx: *anyopaque) ?*anyopaque {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        _ = self.dials.fetchAdd(1, .monotonic);
        if (!self.dial_ok.load(.monotonic)) return null;
        const conn = testing.allocator.create(Conn) catch return null;
        conn.* = .{};
        if (self.disconnect_in_dial) |link| link.disconnect();
        return conn;
    }
    fn serve(_: *anyopaque, connp: *anyopaque) void {
        const conn: *Conn = @ptrCast(@alignCast(connp));
        conn.done.wait(); // blocks until close() — the blocked-read stand-in
    }
    fn close(ctx: *anyopaque, connp: *anyopaque) void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        const conn: *Conn = @ptrCast(@alignCast(connp));
        _ = self.closes.fetchAdd(1, .monotonic);
        conn.done.set(); // unblock serve, like shutdown() unblocks readMessage
    }
    fn deinit(ctx: *anyopaque, connp: *anyopaque) void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        const conn: *Conn = @ptrCast(@alignCast(connp));
        _ = self.deinits.fetchAdd(1, .monotonic);
        testing.allocator.destroy(conn);
    }

    // poll predicates
    fn dialed1(self: *FakeTransport) bool {
        return self.dials.load(.monotonic) >= 1;
    }
    fn dialed2(self: *FakeTransport) bool {
        return self.dials.load(.monotonic) >= 2;
    }
};

fn isOffline(link: *LinkControl) bool {
    return link.display() == .offline;
}
fn isConnected(link: *LinkControl) bool {
    return link.display() == .connected;
}

test "disconnect closes the live link exactly once and suspends redial" {
    var fake = FakeTransport{};
    var link = LinkControl{ .host = "test" };
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 5 });

    try poll(5_000, &link, isConnected);
    try testing.expectEqual(@as(u32, 1), fake.dials.load(.monotonic));

    link.disconnect();
    try poll(5_000, &link, isOffline);
    link.disconnect(); // double-click: must be a no-op

    // Many 5ms backoff windows pass; a suspended loop must NOT redial.
    std.Thread.sleep(100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), fake.dials.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), fake.closes.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), fake.deinits.load(.monotonic));

    link.stopLoop();
    t.join(); // exit clean from the suspended state
}

test "reconnect redials immediately — no waiting out the backoff" {
    var fake = FakeTransport{};
    var link = LinkControl{ .host = "test" };
    // A 60s backoff: if reconnect waited out a backoff sleep, poll would
    // time out. Immediate redial is the requirement.
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 60_000 });

    try poll(5_000, &link, isConnected);
    link.disconnect();
    try poll(5_000, &link, isOffline);

    link.reconnect();
    try poll(5_000, &fake, FakeTransport.dialed2);
    try poll(5_000, &link, isConnected);

    link.stopLoop();
    t.join(); // exit clean from the connected state
    try testing.expectEqual(@as(u32, 2), fake.deinits.load(.monotonic));
}

test "disconnect interrupts a dial-failure backoff promptly" {
    var fake = FakeTransport{};
    fake.dial_ok.store(false, .monotonic);
    var link = LinkControl{ .host = "test" };
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 60_000 });

    // First dial fails; the loop is now parked in a 60s backoff sleep.
    try poll(5_000, &fake, FakeTransport.dialed1);
    link.disconnect();
    // The backoff wait must be interrupted — offline shows up promptly, not
    // after 60s (poll's own timeout enforces this).
    try poll(5_000, &link, isOffline);
    try testing.expectEqual(@as(u32, 1), fake.dials.load(.monotonic));

    // Resume with a working dialer: redial is immediate despite the backoff.
    fake.dial_ok.store(true, .monotonic);
    link.reconnect();
    try poll(5_000, &link, isConnected);

    link.stopLoop();
    t.join();
}

test "disconnect landing mid-dial closes the fresh connection immediately" {
    var fake = FakeTransport{};
    var link = LinkControl{ .host = "test" };
    fake.disconnect_in_dial = &link; // toggle fires between dial and register

    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 60_000 });
    // registerLive must notice desired!=online and close the connection it
    // just registered — unblocking serve and parking the loop.
    try poll(5_000, &link, isOffline);
    try testing.expectEqual(@as(u32, 1), fake.dials.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), fake.closes.load(.monotonic));

    link.stopLoop();
    t.join();
    try testing.expectEqual(@as(u32, 1), fake.deinits.load(.monotonic));
}

test "bounce drops the live link but stays online (redials)" {
    var fake = FakeTransport{};
    var link = LinkControl{ .host = "test" };
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 5 });

    try poll(5_000, &link, isConnected);
    link.bounce();
    // The connection was closed and — unlike disconnect — the loop redials.
    try poll(5_000, &fake, FakeTransport.dialed2);
    try poll(5_000, &link, isConnected);
    try testing.expectEqual(@as(u32, 1), fake.closes.load(.monotonic));

    link.stopLoop();
    t.join();
}

test "bounce while user-disconnected is a no-op (stays parked)" {
    var fake = FakeTransport{};
    var link = LinkControl{ .host = "test" };
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 5 });

    try poll(5_000, &link, isConnected);
    link.disconnect();
    try poll(5_000, &link, isOffline);

    link.bounce(); // creds changed while parked: nothing to close, no redial
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), fake.dials.load(.monotonic));
    try testing.expectEqual(Display.offline, link.display());

    link.stopLoop();
    t.join();
}

test "stopLoop exits cleanly while connected" {
    var fake = FakeTransport{};
    var link = LinkControl{ .host = "test" };
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 60_000 });
    try poll(5_000, &link, isConnected);

    link.stopLoop();
    const started = std.time.milliTimestamp();
    t.join();
    // Joined far faster than the 60s backoff — stop interrupted everything.
    try testing.expect(std.time.milliTimestamp() - started < 5_000);
    try testing.expectEqual(@as(u32, 1), fake.closes.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), fake.deinits.load(.monotonic));
}

// -----------------------------------------------------------------------------
// Integration: the REAL WsClient as the transport against a local loopback WS
// server — proves `disconnect` (the exact call the tray makes) closes the live
// WebSocket and unblocks its blocked `readMessage`, and `reconnect` redials.
// Plaintext `ws://` per `WsClient.Options.tls` — loopback only. (Same pattern
// as keepalive.zig's integration tests.)
// -----------------------------------------------------------------------------

const ws_client = @import("../ws_client.zig");

/// Minimal loopback WebSocket server: accept serially, perform the RFC 6455
/// upgrade, then go SILENT (read-and-discard until the client goes away) —
/// so the client's control read blocks exactly like a quiet healthy relay.
const LoopbackWs = struct {
    listener: std.net.Server,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .{ .raw = false },
    upgrades: std.atomic.Value(u32) = .{ .raw = 0 },

    fn start() !*LoopbackWs {
        const self = try testing.allocator.create(LoopbackWs);
        errdefer testing.allocator.destroy(self);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{ .listener = try addr.listen(.{ .reuse_address = true }) };
        self.thread = try std.Thread.spawn(.{}, LoopbackWs.serve, .{self});
        return self;
    }

    fn port(self: *LoopbackWs) u16 {
        return self.listener.listen_address.in.getPort();
    }

    /// Stop accepting and join (wakes a blocked accept by dialing ourselves).
    fn stop(self: *LoopbackWs) void {
        self.stopping.store(true, .monotonic);
        if (std.net.tcpConnectToAddress(self.listener.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.listener.deinit();
        testing.allocator.destroy(self);
    }

    fn serve(self: *LoopbackWs) void {
        while (!self.stopping.load(.monotonic)) {
            const conn = self.listener.accept() catch return;
            self.handleConn(conn.stream);
            conn.stream.close();
        }
    }

    fn handleConn(self: *LoopbackWs, stream: std.net.Stream) void {
        // Read the upgrade request until CRLFCRLF.
        var req_buf: [4096]u8 = undefined;
        var req_len: usize = 0;
        while (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") == null) {
            if (req_len == req_buf.len) return;
            const n = stream.read(req_buf[req_len..]) catch return;
            if (n == 0) return; // includes the stop() wake-up connection
            req_len += n;
        }
        const key = headerValue(req_buf[0..req_len], "sec-websocket-key") orelse return;

        // 101 with the accept hash.
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
        // Count BEFORE writing: the client's connect returns on reading the
        // 101 and tests assert on this counter right after.
        _ = self.upgrades.fetchAdd(1, .monotonic);
        stream.writeAll(resp) catch return;

        // SILENT: read-and-discard until the client goes away (never writes).
        var sink: [512]u8 = undefined;
        while (true) {
            const n = stream.read(&sink) catch break;
            if (n == 0) break;
        }
    }

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

/// Real-WsClient transport: dial = `connectUrl`, serve = a blocking
/// readMessage loop (serveControl's shape), close/deinit = the WsClient's own.
const WsTransport = struct {
    url: []const u8,

    fn transport(self: *WsTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{
        .dial = dial,
        .serve = serve,
        .close = close,
        .deinit = deinit,
    };

    fn dial(ctx: *anyopaque) ?*anyopaque {
        const self: *WsTransport = @ptrCast(@alignCast(ctx));
        return ws_client.WsClient.connectUrl(testing.allocator, self.url, &.{}) catch null;
    }
    fn serve(_: *anyopaque, connp: *anyopaque) void {
        const ws: *ws_client.WsClient = @ptrCast(@alignCast(connp));
        var buf: [512]u8 = undefined;
        while (true) {
            const n = ws.readMessage(&buf) catch return;
            if (n == 0) return; // EOF — close() unblocked us
        }
    }
    fn close(_: *anyopaque, connp: *anyopaque) void {
        const ws: *ws_client.WsClient = @ptrCast(@alignCast(connp));
        ws.close();
    }
    fn deinit(_: *anyopaque, connp: *anyopaque) void {
        const ws: *ws_client.WsClient = @ptrCast(@alignCast(connp));
        ws.deinit();
    }
};

test "integration: disconnect closes the real WsClient (unblocking its read); reconnect redials" {
    const alloc = testing.allocator;

    var srv = try LoopbackWs.start();
    defer srv.stop();

    const url = try std.fmt.allocPrint(alloc, "ws://127.0.0.1:{d}/v1/agent/control", .{srv.port()});
    defer alloc.free(url);

    var tr = WsTransport{ .url = url };
    var link = LinkControl{ .host = "127.0.0.1" };
    // 60s backoff: any post-disconnect promptness below is REAL, not a lucky
    // backoff expiry.
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, tr.transport(), 60_000 });

    try poll(10_000, &link, isConnected);
    try testing.expectEqual(@as(u32, 1), srv.upgrades.load(.monotonic));

    // The tray's Disconnect: must close the live WebSocket, which unblocks
    // the loop's blocked readMessage (the keepalive teardown contract), and
    // park the loop offline.
    link.disconnect();
    try poll(10_000, &link, isOffline);

    // The tray's Reconnect: redials immediately (well inside the 60s backoff).
    link.reconnect();
    try poll(10_000, &link, isConnected);
    try testing.expectEqual(@as(u32, 2), srv.upgrades.load(.monotonic));

    link.stopLoop();
    t.join();
}

test {
    testing.refAllDecls(@This());
}
