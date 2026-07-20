//! User-controlled relay-link state (tray "Disconnect"/"Reconnect") + the
//! reconnect-loop driver that obeys it.
//!
//! ## Why this exists
//! `--relay` mode holds one control WebSocket to the relay and redials it
//! forever (3s base backoff, escalating on repeated fast drops — see
//! `ReconnectBackoff`). The Windows tray needs to let the human take that
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

/// The redial-delay schedule: fixed base cadence normally, exponential with a
/// cap when connections keep dying young ("fast drops").
///
/// ## Why
/// Live incident: two same-user daemons (a `Local\` mutex hole — see
/// `single_instance.zig`) fought over ONE relay device token. The relay
/// dup-control-kicks the older connection on every connect, so each loser
/// redialed after a FIXED 3s forever → ~1100 reconnects/hour pegging the
/// relay. Any "my connection comes up and then immediately dies, every time"
/// pathology (dup token, relay-side auth flapping) has the same signature:
/// the connection SUCCEEDS but never survives. Escalating only on that
/// signature converges the fight to a slow heartbeat (capped delay) while
/// leaving every healthy pattern at the base cadence:
///
///   - dial FAILURES (relay down/unreachable) keep the base delay — an outage
///     shouldn't be slower to recover from than today;
///   - a connection that survived `fast_drop_threshold_ms` resets the
///     schedule — one-off drops and sleep/wake redial at the base delay
///     (wall-clock lifetime: a machine that slept for hours counts as a
///     long-lived connection, which is exactly right);
///   - NEUTRAL drops (credential-change `bounce`, user Disconnect/stop) never
///     count as fast drops — a re-enroll must redial with fresh credentials
///     at the base delay, not inherit a fight's penalty (it may well END the
///     fight).
///
/// Deterministic decision logic (this struct) is kept separate from the
/// ±20% jitter (`jittered`) so the schedule is unit-testable; the jitter
/// de-synchronizes multiple losers so they don't thundering-herd the relay.
pub const ReconnectBackoff = struct {
    /// Delay used for dial failures, for post-long-lived-connection redials,
    /// and as the first fast-drop delay (`runLoop`'s `backoff_ms` argument;
    /// 3s in production).
    base_ms: u64,
    /// Ceiling for the escalated delay (40× base = 120s in production).
    cap_ms: u64,
    /// A served connection that lived less than this is a fast drop.
    fast_drop_threshold_ms: u64 = 30_000,
    /// The un-jittered delay the NEXT fast drop will be told to sleep.
    delay_ms: u64,

    pub fn init(base_ms: u64, cap_ms: u64) ReconnectBackoff {
        return .{ .base_ms = base_ms, .cap_ms = cap_ms, .delay_ms = base_ms };
    }

    /// Dial failed (never connected): retry at the base cadence. Leaves the
    /// escalation state alone — only a SURVIVING connection earns a reset, so
    /// a transient dial failure mid-fight doesn't unwind the backoff.
    pub fn onDialFailed(self: *ReconnectBackoff) u64 {
        return self.base_ms;
    }

    /// A served connection ended after `lifetime_ms`. `neutral` marks drops
    /// that must not count as fast drops (credential bounce, user
    /// Disconnect, stop). Returns the un-jittered delay to sleep before the
    /// redial: base → 2×base → 4×base → … → cap on successive fast drops.
    pub fn onConnectionEnded(self: *ReconnectBackoff, lifetime_ms: u64, neutral: bool) u64 {
        if (neutral or lifetime_ms >= self.fast_drop_threshold_ms) {
            self.delay_ms = self.base_ms;
            return self.base_ms;
        }
        const delay = self.delay_ms;
        self.delay_ms = @min(self.delay_ms *| 2, self.cap_ms);
        return delay;
    }

    /// Apply ±20% uniform jitter. Kept out of the schedule methods so those
    /// stay deterministic under test.
    pub fn jittered(delay_ms: u64, rand: std.Random) u64 {
        const span = delay_ms / 5; // 20%
        if (span == 0) return delay_ms;
        return delay_ms - span + rand.uintAtMost(u64, 2 * span);
    }
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
    /// Set by `bounce` when it closes a LIVE connection; consumed (swap) by
    /// the loop when classifying why serve returned, so a credential-change
    /// bounce is never mistaken for a fast drop (see `ReconnectBackoff`).
    cred_bounce: std.atomic.Value(bool) = .{ .raw = false },

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
        _ = self.closeLive();
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
        // Mark BEFORE closing: the close is what unblocks the loop's serve,
        // so the marker must already be visible when the loop classifies the
        // drop (a marker set after could lose the race and get the bounce
        // penalized as a fast drop).
        self.cred_bounce.store(true, .release);
        if (!self.closeLive()) {
            // Nothing was live (parked offline / mid-backoff): clear the
            // marker so it can't mislabel a LATER, unrelated drop.
            self.cred_bounce.store(false, .release);
        }
    }

    /// Terminate the loop from either state (closes a live connection first).
    pub fn stopLoop(self: *LinkControl) void {
        self.desired.store(.stop, .release);
        _ = self.closeLive();
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
        if (self.desired.load(.acquire) != .online) _ = self.closeLive();
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
    /// Returns whether there WAS a live connection to close.
    fn closeLive(self: *LinkControl) bool {
        self.mutex.lock();
        const live = self.live;
        self.live = null;
        self.mutex.unlock();
        if (live) |l| {
            l.transport.vtable.close(l.transport.ctx, l.conn);
            return true;
        }
        return false;
    }
};

/// THE connect loop: park while offline, dial, serve until the connection
/// ends, back off (`ReconnectBackoff`: `backoff_ms` base cadence normally,
/// escalating with jitter on repeated fast drops), repeat. Every wait is
/// interruptible by the tray's `disconnect`/`reconnect`/`stopLoop`. Returns
/// only on `.stop`.
///
/// This is `main.zig`'s relay control loop with the transport abstracted out,
/// so the suspend/resume transitions are unit-testable on any host.
pub fn runLoop(link: *LinkControl, transport: Transport, backoff_ms: u64) void {
    var backoff = ReconnectBackoff.init(backoff_ms, backoff_ms *| 40);
    var prng = std.Random.DefaultPrng.init(seed: {
        var s: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :seed s;
    });
    const rand = prng.random();

    while (true) {
        switch (link.awaitOnline()) {
            .stop => return,
            .online => {},
            .offline => unreachable, // awaitOnline never returns offline
        }

        const conn = transport.vtable.dial(transport.ctx) orelse {
            // Dial failed: back off (base cadence — see ReconnectBackoff),
            // but wake early on any tray toggle so a user Disconnect parks
            // (and a Reconnect-after-Disconnect redials) without waiting out
            // the backoff.
            link.interruptibleSleep(ReconnectBackoff.jittered(backoff.onDialFailed(), rand));
            continue;
        };

        link.connected.store(true, .release);
        link.registerLive(transport, conn);

        const served_from_ms = std.time.milliTimestamp();
        transport.vtable.serve(transport.ctx, conn);
        const lifetime_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - served_from_ms));

        link.connected.store(false, .release);
        link.clearLive();
        transport.vtable.deinit(transport.ctx, conn);

        // Connection ended (peer drop, keepalive stale-close, credential
        // bounce, or user disconnect). Classify it for the backoff schedule:
        // bounce and not-desired-online drops are neutral (never fast drops).
        const was_bounce = link.cred_bounce.swap(false, .acq_rel);
        const neutral = was_bounce or link.desired.load(.acquire) != .online;
        const delay_ms = backoff.onConnectionEnded(lifetime_ms, neutral);
        if (delay_ms > backoff.base_ms) {
            // Only above base — i.e. an actual fast-drop streak (dup-token
            // fight signature). Visible in the agent log for on-box diagnosis.
            std.debug.print(
                "ghoztty-agent: relay control dropped after {d}ms (fast-drop streak); backing off {d}ms (cap {d}ms)\n",
                .{ lifetime_ms, delay_ms, backoff.cap_ms },
            );
        }
        // Back off before redialing; a user disconnect has already set the
        // wake event, so this returns immediately and the next awaitOnline
        // parks.
        link.interruptibleSleep(ReconnectBackoff.jittered(delay_ms, rand));
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
/// The loop has OBSERVED the connection end (not just the desired-state flip
/// that `isOffline` reports) — see the disconnect/reconnect race note (T89b).
fn isDisconnected(link: *LinkControl) bool {
    return !link.connected.load(.acquire);
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
const socket_rw = @import("../socket_rw.zig");

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
        // Read the upgrade request until CRLFCRLF. Reads/writes go through
        // socket_rw (T89b): std's Stream.read/writeAll fail with error 87 on
        // Windows' overlapped sockets (see keepalive.zig's TestWsServer).
        var req_buf: [4096]u8 = undefined;
        var req_len: usize = 0;
        while (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") == null) {
            if (req_len == req_buf.len) return;
            const n = socket_rw.readStream(stream, req_buf[req_len..]) catch return;
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
        socket_rw.writeAllStream(stream, resp) catch return;

        // SILENT: read-and-discard until the client goes away (never writes).
        var sink: [512]u8 = undefined;
        while (true) {
            const n = socket_rw.readStream(stream, &sink) catch break;
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
    // Stop the loop + join even when an assertion below fails: without this a
    // FAILED run leaked the loop thread, which kept redialing a freed `url`
    // and segfaulted the whole test binary minutes later — attributed to
    // whatever unrelated test was then executing (T89b).
    defer {
        link.stopLoop();
        t.join();
    }

    try poll(10_000, &link, isConnected);
    try testing.expectEqual(@as(u32, 1), srv.upgrades.load(.monotonic));

    // The tray's Disconnect: must close the live WebSocket, which unblocks
    // the loop's blocked readMessage (the keepalive teardown contract), and
    // park the loop offline.
    link.disconnect();
    try poll(10_000, &link, isOffline);
    // `display()` reports .offline from `desired` ALONE, so the poll above
    // passes before the loop thread has necessarily observed the close. Wait
    // for the loop to actually clear `connected` too: on Windows the aborted
    // recv wakes a few ms later, and an immediate reconnect() below would
    // otherwise see the STALE connected=true and pass its poll without any
    // second dial ("expected 2, found 1", T89b).
    try poll(10_000, &link, isDisconnected);

    // The tray's Reconnect: redials immediately (well inside the 60s backoff).
    link.reconnect();
    try poll(10_000, &link, isConnected);
    try testing.expectEqual(@as(u32, 2), srv.upgrades.load(.monotonic));
}

// -----------------------------------------------------------------------------
// ReconnectBackoff: pure schedule tests (the incident math)
// -----------------------------------------------------------------------------

test "backoff: successive fast drops escalate base → 2x → 4x → … → cap, and stay capped" {
    var b = ReconnectBackoff.init(3_000, 120_000);
    // The production schedule from the incident fix: 3s, 6s, 12s, 24s, 48s,
    // 96s, then capped at 120s forever.
    const expected = [_]u64{ 3_000, 6_000, 12_000, 24_000, 48_000, 96_000, 120_000, 120_000, 120_000 };
    for (expected) |want| {
        try testing.expectEqual(want, b.onConnectionEnded(0, false));
    }
}

test "backoff: a connection surviving the threshold resets the schedule to base" {
    var b = ReconnectBackoff.init(3_000, 120_000);
    // Escalate a few steps into a fight…
    _ = b.onConnectionEnded(5_000, false); // → 3s (streak starts)
    _ = b.onConnectionEnded(100, false); // → 6s
    try testing.expectEqual(@as(u64, 12_000), b.onConnectionEnded(29_999, false));
    // …then one connection survives ≥ 30s: full reset.
    try testing.expectEqual(@as(u64, 3_000), b.onConnectionEnded(30_000, false));
    // And the NEXT fast drop starts the schedule over from base.
    try testing.expectEqual(@as(u64, 3_000), b.onConnectionEnded(0, false));
    try testing.expectEqual(@as(u64, 6_000), b.onConnectionEnded(0, false));
}

test "backoff: neutral drops (credential bounce / user disconnect) never escalate and reset the streak" {
    var b = ReconnectBackoff.init(3_000, 120_000);
    // Deep in a fight…
    for (0..6) |_| _ = b.onConnectionEnded(0, false);
    try testing.expectEqual(@as(u64, 120_000), b.delay_ms);
    // …a credential-change bounce (lifetime tiny, but neutral) gets the base
    // delay — the redial with FRESH credentials may end the fight, so it
    // must not inherit the penalty.
    try testing.expectEqual(@as(u64, 3_000), b.onConnectionEnded(50, true));
    try testing.expectEqual(@as(u64, 3_000), b.delay_ms);
}

test "backoff: dial failures use the base delay and leave the streak alone" {
    var b = ReconnectBackoff.init(3_000, 120_000);
    // Never-connected failures (relay down) stay at today's base cadence…
    try testing.expectEqual(@as(u64, 3_000), b.onDialFailed());
    try testing.expectEqual(@as(u64, 3_000), b.onDialFailed());
    // …and mid-fight, a stray dial failure neither unwinds nor advances the
    // escalation (only a surviving connection resets it).
    _ = b.onConnectionEnded(0, false); // → 3s, next = 6s
    _ = b.onConnectionEnded(0, false); // → 6s, next = 12s
    try testing.expectEqual(@as(u64, 3_000), b.onDialFailed());
    try testing.expectEqual(@as(u64, 12_000), b.onConnectionEnded(0, false));
}

test "backoff: jitter stays within ±20% and passes tiny delays through" {
    var prng = std.Random.DefaultPrng.init(0x6f2a_9c1d_5e3b_8840);
    const rand = prng.random();
    for ([_]u64{ 3_000, 6_000, 120_000 }) |d| {
        var lo: u64 = std.math.maxInt(u64);
        var hi: u64 = 0;
        for (0..2_000) |_| {
            const j = ReconnectBackoff.jittered(d, rand);
            try testing.expect(j >= d - d / 5);
            try testing.expect(j <= d + d / 5);
            lo = @min(lo, j);
            hi = @max(hi, j);
        }
        try testing.expect(lo < hi); // it actually jitters
    }
    // Delays too small to jitter (span == 0) come back unchanged — the unit
    // tests drive runLoop with millisecond backoffs.
    try testing.expectEqual(@as(u64, 4), ReconnectBackoff.jittered(4, rand));
}

test "bounce marker: consumed by the drop it caused, absent otherwise" {
    var fake = FakeTransport{};
    var link = LinkControl{ .host = "test" };
    const t = try std.Thread.spawn(.{}, runLoop, .{ &link, fake.transport(), 5 });

    try poll(5_000, &link, isConnected);
    link.bounce();
    try poll(5_000, &fake, FakeTransport.dialed2);
    // The marker was consumed classifying the bounce-drop — it must not
    // linger to mislabel the next drop.
    try testing.expect(!link.cred_bounce.load(.acquire));

    link.stopLoop();
    t.join();

    // bounce with nothing live clears its own marker (parked link).
    var parked = LinkControl{ .host = "test" };
    parked.bounce();
    try testing.expect(!parked.cred_bounce.load(.acquire));
}

test {
    testing.refAllDecls(@This());
}
