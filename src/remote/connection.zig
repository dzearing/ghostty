//! Client-side `RemoteConnection` transport core (WP3, increments 1 + 2).
//!
//! Increment 2 layers **health & link-state tracking** on top of the increment-1
//! transport (§5.1/§5.2/§6.4): a heartbeat driver thread (PING/PONG with RTT
//! sampling per RFC 6298), a pure `LinkState` FSM that *decides* when to
//! reconnect (with full-jitter backoff), a pure `RttEstimator`, internal
//! handling of `.ping`/`.pong`/`.detached` control frames, a reader-exit
//! signal that drives the FSM on a non-deliberate EOF, and observability
//! (`state`/`latencyMs`/`setStateHandler`). It does NOT perform a real
//! reconnect (re-dialing streams + re-handshake + re-ATTACH) — that is the next
//! increment; the FSM only computes the decision and the backoff delay.
//!
//! This is the byte-pump that sits between the two SSH channels of one remote
//! connection (§4.3: a *control* channel and a *data* channel, each a separate
//! SSH-level lane riding the shared `ControlMaster` TCP connection) and the
//! per-pane inbound rings (`inbound_ring.zig`, §3.4). It owns the §3.4 thread
//! topology *minus* the per-pane IO threads:
//!
//!   - **One MPSC writer thread** owns both sockets. N pane IO threads (and the
//!     control plane) concurrently `enqueue` frames; the writer drains them,
//!     assigns the per-connection frame `seq` (§4.2), transfer-encodes via
//!     `protocol.writeFrame`, and writes each to its channel's stream. Preserves
//!     the §3.4 "mux thread owns the socket" invariant.
//!   - **Two reader threads**, one per SSH channel. Each owns its own
//!     `protocol.Reader` and scratch buffer. The *data* reader demuxes inbound
//!     `DATA` into the per-channel rings via `ring.ChannelTable.pushTo` (a
//!     non-blocking push under the table lock — the §3.4 use-after-free guard).
//!     The *control* reader performs the HELLO handshake first, then dispatches
//!     control frames to a registered handler.
//!
//! What this increment does NOT do (deferred to later increments, §5.1): the
//! reconnect/attach state machine, heartbeat/RTT tracking (PING/PONG timing),
//! the steal epoch, `FLOW{pause/resume}` emission on backpressure, and any
//! session/channel *ownership* validation. It is purely the transport: frames
//! in, frames out, demuxed correctly, with a clean handshake and a deadlock-free
//! shutdown.
//!
//! ## Transfer-encoding decision (§4.2)
//! The transfer encoding is **fixed at `create` from `local_hello.transfer_encoding`
//! and used for EVERY frame, including the HELLO itself**. The client picks the
//! encoding (it is the side that knows whether the hop is a CR/LF-mangling Windows
//! hop, §4.2); the agent echoes the same encoding in its HELLO. `protocol.negotiate`
//! therefore only *confirms* agreement — it never switches an in-flight stream to a
//! different encoding. Both `protocol.Reader`s and the writer use this one encoding.
//!
//! Standalone-testable: `zig test src/remote/connection.zig` drives the whole
//! transport over an in-memory loopback (no real ssh) with a mock agent thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const protocol = @import("protocol.zig");
const ring = @import("inbound_ring.zig");

/// Scratch read buffer size for each reader thread's blocking `Stream.read`.
/// 16 KiB matches the small-DATA-chunk guidance (§4.3) so a single read rarely
/// holds more than a couple of frames.
const read_buf_size: usize = 16 * 1024;

// -----------------------------------------------------------------------------
// Stream — an abstract bidirectional byte stream for ONE SSH channel
// -----------------------------------------------------------------------------

/// A blocking, bidirectional byte stream abstracting one SSH channel. Modeling it
/// as a vtable keeps the `Connection` testable without a real ssh subprocess: the
/// production impl wraps the channel's pipe fds; the tests wrap an in-memory FIFO.
///
/// Threading: at most one reader thread calls `read` and at most one writer thread
/// calls `writeAll` per stream (the §3.4 topology guarantees this), so an impl need
/// not make `read`/`write` mutually thread-safe — only `close` must be safe to call
/// concurrently with a blocked `read` (it unblocks it) and idempotent.
pub const Stream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Blocking read of up to `buf.len` bytes; returns the count read. A
        /// return of `0` means EOF/closed. Any error is fatal to the connection.
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        /// Write some of `bytes`; returns the count written (writeAll loops over
        /// this). An impl may write all of `bytes` in one call.
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        /// Unblock any pending `read` and mark the stream EOF. Idempotent and safe
        /// to call concurrently with a blocked `read`.
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn read(self: Stream, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ctx, buf);
    }

    /// Write the entirety of `bytes`, looping over partial writes.
    pub fn writeAll(self: Stream, bytes: []const u8) anyerror!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try self.vtable.write(self.ctx, bytes[off..]);
            if (n == 0) return error.WriteZero; // closed mid-write
            off += n;
        }
    }

    pub fn close(self: Stream) void {
        self.vtable.close(self.ctx);
    }
};

// -----------------------------------------------------------------------------
// Connection
// -----------------------------------------------------------------------------

/// Which of the two SSH channels a queued frame is destined for.
const StreamId = enum { control, data };

/// A control-frame handler invoked by the control reader for every inbound
/// control frame AFTER the handshake. `frame.payload` borrows the reader's buffer
/// and is valid ONLY for the duration of the call — copy it out to retain it.
pub const ControlHandler = *const fn (ctx: *anyopaque, conn: *Connection, frame: protocol.Frame) void;

/// A dedicated handler for the pushed host-metrics stream (§9.3). Registered by
/// `subscribeMetrics`, invoked by the control reader for every inbound `.metrics`
/// frame, and cleared by `unsubscribeMetrics`. It is a SEPARATE slot from
/// `ControlHandler` so the metrics subscriber never clobbers an unrelated control
/// handler (and vice versa).
///
/// IMPORTANT (threading): the handler fires on the connection's control-reader
/// thread, NOT the caller's thread. The caller MUST call `unsubscribeMetrics`
/// (which clears the slot under the write mutex) before freeing any context the
/// handler captures, or the reader could invoke a dangling pointer. `host` is a
/// by-value snapshot (no borrowed storage), so it is safe to copy out.
pub const MetricsHandler = *const fn (ctx: *anyopaque, host: protocol.HostMetrics) void;

/// One queued outbound frame, owned by the writer queue until the writer emits it.
/// `payload` is a private heap copy the queue owns and frees; the caller's slice is
/// not retained past `enqueue`.
const OutFrame = struct {
    stream: StreamId,
    ftype: protocol.FrameType,
    channel: u128,
    payload: []u8,
};

// -----------------------------------------------------------------------------
// Heartbeat payload (PING / PONG, §6.4)
// -----------------------------------------------------------------------------

/// The binary payload of a `.ping`/`.pong` control frame (§6.4 "control frames
/// carry dwell-adjusted timestamp/timestamp_reply + frame seq"). We keep a tiny
/// fixed binary form (no JSON) so heartbeats are cheap on the hot control lane:
///
///   `hb_seq u64 BE | send_ms u64 BE | reply_ms u64 BE`
///
/// - `hb_seq`   — a heartbeat sequence the heartbeat driver owns (NOT the wire
///   `frame_seq`, which is owned solely by the writer thread). PONGs echo it so
///   we can match a reply to its outstanding PING and ignore stale/duplicate ones.
/// - `send_ms`  — the client clock (ms) when the PING was stamped. Echoed in the
///   PONG so RTT = now − send_ms is computed without per-ping bookkeeping of the
///   send time (the agent reflects it back verbatim).
/// - `reply_ms` — set in a PONG to the responder's clock when it replied (unused
///   by the v1 one-way RTT calc; reserved for dwell adjustment, §6.4). 0 in a PING.
const Heartbeat = struct {
    hb_seq: u64,
    send_ms: u64,
    reply_ms: u64 = 0,

    const encoded_len = 8 + 8 + 8;

    fn encodeInto(self: Heartbeat, dst: []u8) []u8 {
        assert(dst.len >= encoded_len);
        std.mem.writeInt(u64, dst[0..8], self.hb_seq, .big);
        std.mem.writeInt(u64, dst[8..16], self.send_ms, .big);
        std.mem.writeInt(u64, dst[16..24], self.reply_ms, .big);
        return dst[0..encoded_len];
    }

    fn decode(payload: []const u8) protocol.ProtocolError!Heartbeat {
        if (payload.len < encoded_len) return error.MalformedPayload;
        return .{
            .hb_seq = std.mem.readInt(u64, payload[0..8], .big),
            .send_ms = std.mem.readInt(u64, payload[8..16], .big),
            .reply_ms = std.mem.readInt(u64, payload[16..24], .big),
        };
    }
};

// -----------------------------------------------------------------------------
// RttEstimator (RFC 6298, §6.4) — pure
// -----------------------------------------------------------------------------

/// Smoothed round-trip-time estimator per RFC 6298 (§6.4). Units are
/// **milliseconds** throughout (samples in, SRTT/RTTVAR/RTO out). Pure: no
/// threads, no clock — feed it measured RTT samples and read the smoothed values.
///
/// First sample seeds `SRTT = R`, `RTTVAR = R/2`. Subsequent samples apply the
/// standard α=1/8, β=1/4 EWMA updates; RTO = SRTT + K·RTTVAR with K=4, clamped
/// to a 1 ms floor (we have no 1 s minimum like TCP — this is an app heartbeat,
/// not a retransmit timer).
pub const RttEstimator = struct {
    /// α = 1/8, β = 1/4, K = 4 (RFC 6298 §2). Held as f64 for the EWMA math.
    const alpha: f64 = 1.0 / 8.0;
    const beta: f64 = 1.0 / 4.0;
    const k: f64 = 4.0;

    /// Health buckets (§6.4): green <~80 ms SRTT, yellow up to ~250 ms, red above.
    /// `unknown` until the first sample lands.
    pub const Health = enum { unknown, green, yellow, red };
    const green_max_ms: f64 = 80.0;
    const yellow_max_ms: f64 = 250.0;

    srtt: f64 = 0,
    rttvar: f64 = 0,
    /// False until the first `addSample`, so seeding vs. update is unambiguous.
    seeded: bool = false,

    /// Feed one measured RTT sample (ms). Applies the RFC 6298 seed-or-update.
    pub fn addSample(self: *RttEstimator, rtt_ms: f64) void {
        const r = if (rtt_ms < 0) 0 else rtt_ms;
        if (!self.seeded) {
            self.srtt = r;
            self.rttvar = r / 2.0;
            self.seeded = true;
            return;
        }
        // RTTVAR ← (1−β)·RTTVAR + β·|SRTT − R|   (uses the OLD SRTT, per RFC 6298)
        self.rttvar = (1.0 - beta) * self.rttvar + beta * @abs(self.srtt - r);
        // SRTT   ← (1−α)·SRTT + α·R
        self.srtt = (1.0 - alpha) * self.srtt + alpha * r;
    }

    /// Smoothed RTT (ms), rounded. 0 before the first sample.
    pub fn srttMs(self: RttEstimator) u32 {
        if (!self.seeded) return 0;
        return @intFromFloat(@round(self.srtt));
    }

    /// Retransmit-style timeout (ms) = SRTT + K·RTTVAR, floored at 1 ms. The
    /// heartbeat driver uses this only as an advisory; missed-ack counting is the
    /// authoritative loss signal.
    pub fn rtoMs(self: RttEstimator) u32 {
        if (!self.seeded) return 0;
        const rto = self.srtt + k * self.rttvar;
        return @intFromFloat(@round(@max(rto, 1.0)));
    }

    /// Health badge bucket from the current SRTT (§6.4).
    pub fn health(self: RttEstimator) Health {
        if (!self.seeded) return .unknown;
        if (self.srtt < green_max_ms) return .green;
        if (self.srtt < yellow_max_ms) return .yellow;
        return .red;
    }
};

// -----------------------------------------------------------------------------
// LinkState FSM (§5.1/§5.2) — pure
// -----------------------------------------------------------------------------

/// The connection-lifecycle state machine (§5.1), driven by explicit events. Pure
/// and side-effect-free: it owns no threads and reads no wall clock except through
/// the injected `nowMs` (defaults to real monotonic). It *decides* state and
/// computes the reconnect backoff; it does NOT actually reconnect (next increment).
///
/// Threading: `LinkState` is NOT internally synchronized. `Connection` owns one and
/// guards every access with `state_mutex` (the same lock that guards the thread
/// handles), so all transitions are serialized.
pub const LinkState = struct {
    /// §5.1 states. `reattaching` is entered only by `onResyncDone`'s precondition
    /// in the real flow; this increment exposes the transition but never drives a
    /// real resync (so `reconnecting → reattaching` is a future-increment edge that
    /// `markReattaching` makes available for tests/next increment).
    pub const State = enum { connected, degraded, reconnecting, reattaching, dead };

    /// §5.1 thresholds (missed heartbeat counts). ~2 missed → degraded; 3 missed
    /// (or any transport error) → reconnecting.
    pub const degraded_misses: u32 = 2;
    pub const reconnect_misses: u32 = 3;

    /// Full-jitter backoff schedule (§5.1): base 500 ms, cap 30 s, reset on success.
    pub const backoff_base_ms: u64 = 500;
    pub const backoff_cap_ms: u64 = 30_000;
    /// Attempts beyond which we give up and declare the session DEAD (§5.1 "backoff
    /// cap exceeded"). The delay caps well before this; this bounds total wall time.
    pub const max_attempts: u32 = 10;

    state: State = .connected,
    /// Reconnect attempt counter; index into the (capped) backoff schedule. Reset to
    /// 0 on any success (`onHeartbeatAck`/`onResyncDone`).
    attempt: u32 = 0,
    /// Injected PRNG for full-jitter backoff (deterministic in tests via a seed).
    rand: std.Random,

    pub fn init(rand: std.Random) LinkState {
        return .{ .rand = rand };
    }

    /// A heartbeat PONG (or any authentic packet) arrived: §5.1 "any authentic pkt
    /// → CONNECTED". Clears the reconnect attempt counter. No-op if already dead.
    pub fn onHeartbeatAck(self: *LinkState) void {
        if (self.state == .dead) return;
        self.state = .connected;
        self.attempt = 0;
    }

    /// `missed` heartbeats in a row with no ack (§5.1). 2 → degraded, 3+ → reconnecting.
    /// Monotonic w.r.t. the running count; never downgrades dead.
    pub fn onHeartbeatMissed(self: *LinkState, missed: u32) void {
        if (self.state == .dead) return;
        if (missed >= reconnect_misses) {
            self.toReconnecting();
        } else if (missed >= degraded_misses) {
            // Only slide *into* degraded from a healthier state; don't pull
            // reconnecting back to degraded on a still-missing tick.
            if (self.state == .connected) self.state = .degraded;
        }
    }

    /// A transport-level error (reader EOF / write failure, §5.2): jump straight to
    /// reconnecting regardless of the missed count.
    pub fn onTransportError(self: *LinkState) void {
        if (self.state == .dead) return;
        self.toReconnecting();
    }

    /// The sequence-anchored resync finished (§5.4/§7.3): REATTACHING → CONNECTED.
    /// Only meaningful from `reattaching`; clears the attempt counter on success.
    pub fn onResyncDone(self: *LinkState) void {
        if (self.state == .dead) return;
        self.state = .connected;
        self.attempt = 0;
    }

    /// The agent evicted us (DETACHED, §5.3) or the session is gone: terminal DEAD.
    pub fn onSessionGone(self: *LinkState) void {
        self.state = .dead;
    }

    /// Mark that the (future) reconnect succeeded in re-dialing and we are applying
    /// the snapshot. RECONNECTING → REATTACHING. Exposed for the next increment.
    pub fn markReattaching(self: *LinkState) void {
        if (self.state == .reconnecting) self.state = .reattaching;
    }

    fn toReconnecting(self: *LinkState) void {
        // Entering reconnecting from a live state starts a fresh backoff schedule.
        if (self.state == .connected or self.state == .degraded) self.attempt = 0;
        self.state = .reconnecting;
    }

    /// Compute the next full-jitter backoff delay (ms) and advance the attempt
    /// counter (§5.1). The uncapped ceiling is `base · 2^attempt`; we clamp it to
    /// `cap`, then pick a uniform random delay in `[0, ceiling]` (AWS "full jitter").
    /// When `attempt` exceeds `max_attempts` the caller should treat the link as
    /// DEAD; `nextBackoffMs` still returns the capped delay so callers that ignore
    /// the cap don't get UB. `onHeartbeatAck`/`onResyncDone` reset `attempt`.
    pub fn nextBackoffMs(self: *LinkState) u64 {
        const attempt = self.attempt;
        self.attempt +%= 1;
        // ceiling = base << attempt, saturating at the cap (avoid u64 shift UB).
        const shift: u6 = @intCast(@min(attempt, 40));
        const raw_ceiling = backoff_base_ms *| (@as(u64, 1) << shift);
        const ceiling = @min(raw_ceiling, backoff_cap_ms);
        return self.rand.intRangeAtMost(u64, 0, ceiling);
    }

    /// True once we've exhausted the reconnect budget (§5.1 "backoff cap exceeded").
    pub fn attemptsExhausted(self: LinkState) bool {
        return self.attempt >= max_attempts;
    }
};

/// Injected millisecond clock. Defaults to a real monotonic-ish source; tests
/// inject a fake so heartbeat/RTT logic is deterministic without wall-clock sleeps.
pub const Clock = struct {
    ctx: *anyopaque,
    nowMs: *const fn (ctx: *anyopaque) u64,

    fn now(self: Clock) u64 {
        return self.nowMs(self.ctx);
    }

    /// The default real clock: a monotonic millisecond counter. `ctx` is unused.
    pub fn real() Clock {
        return .{ .ctx = undefined, .nowMs = realNowMs };
    }
    fn realNowMs(_: *anyopaque) u64 {
        // Monotonic on darwin/linux (UPTIME_RAW / BOOTTIME); falls back to wall
        // clock only if the monotonic clock is unavailable.
        const inst = std.time.Instant.now() catch {
            return @intCast(@max(std.time.milliTimestamp(), 0));
        };
        // Convert the platform Instant to ms via its ns-since an epoch-ish zero.
        // `since` needs an earlier instant; use a process-lifetime anchor.
        return @intCast(@divFloor(instantNs(inst), std.time.ns_per_ms));
    }
    fn instantNs(inst: std.time.Instant) u128 {
        if (@TypeOf(inst.timestamp) == u64) return inst.timestamp;
        const ts = inst.timestamp;
        return @as(u128, @intCast(ts.sec)) * std.time.ns_per_s + @as(u128, @intCast(ts.nsec));
    }
};

/// State-change observer (§6.4 health badge / §5.x banners). Fired by the
/// `Connection` AFTER a transition, with the old and new state. Invoked while
/// holding `state_mutex` — the handler must NOT call back into `Connection`
/// methods that take `state_mutex` (it would deadlock); copy what it needs and
/// return promptly.
pub const StateHandler = *const fn (ctx: *anyopaque, conn: *Connection, old: LinkState.State, new: LinkState.State) void;

// -----------------------------------------------------------------------------
// Channel / session lifecycle (increment 3, §3.3/§4.2/§7.3)
// -----------------------------------------------------------------------------

/// A request/response correlation slot for a control-channel RPC that has a reply
/// (OPEN→OPENED, ATTACH→ATTACHED, §4.2). The caller parks on `done`; the control
/// reader, when it sees the matching reply frame, fills `result` and sets `done`.
/// Keyed by the request/reply `Frame.channel` in `Connection.pending` (one
/// outstanding RPC per channel id — OPEN and ATTACH never race on the same fresh
/// channel id).
///
/// `result` is one of:
///   - `error.ConnectionClosed` — set by `shutdown` to unblock a parked caller.
///   - `error.MalformedReply`   — the reply payload failed to parse.
///   - a duped, caller-owned payload slice (`[]u8`) — the raw JSON of the reply,
///     which the waking caller parses (and frees) on its own thread so no parsing
///     happens on the control reader.
const PendingRpc = struct {
    done: std.Thread.ResetEvent = .{},
    /// Filled by the responder (control reader) before `done.set()`. The expected
    /// reply frame type, so a wrong-type reply on the channel is rejected.
    want: protocol.FrameType,
    /// The result. `null` until filled. The payload bytes are heap-owned by the
    /// connection allocator and become the caller's to free on success.
    result: PendingError![]u8 = error.ConnectionClosed,
    /// The channel the reply frame actually arrived on (filled by `deliverRpcReply`
    /// before `done.set()`). For OPEN/ATTACH the agent is **channel-authoritative**:
    /// it mints its OWN session channel and replies OPENED/ATTACHED on THAT channel
    /// (not the channel the request was sent on). The caller adopts this as the
    /// pane's data-channel id. For a same-channel reply it simply equals the request
    /// channel.
    reply_channel: u128 = 0,
    /// The cancellation token this RPC was issued with (or null). Lets
    /// `cancelRpcsFor` wake exactly the callers owned by one tearing-down pane
    /// without touching other panes' in-flight RPCs on the shared connection.
    canceller: ?*const RpcCanceller = null,

    const PendingError = error{ ConnectionClosed, MalformedReply, WrongReply, Timeout, Cancelled };
};

/// A cancellation token for session-establishing RPCs (OPEN/ATTACH). One lives
/// on each `termio.Remote` backend so the GUI thread can abort that pane's
/// blocking RPC BEFORE joining the pane's IO thread (`Surface.deinit`).
///
/// Why: an ATTACH/OPEN sent onto a link that silently died (a WSS transport
/// that will never deliver another byte does NOT error the readers, so nothing
/// fails the parked slot) waits out the full `rpc_open_timeout_ns`. Freeing
/// such a surface joins its IO thread, which is parked inside that wait — the
/// GUI thread beachballed for the whole timeout, and during reconnect churn
/// (a new doomed ATTACH every cycle) that is effectively a permanent hang.
/// This token is the remote analogue of local Exec's quit pipe: signal first,
/// then join.
///
/// Usage: the canceller thread calls `cancel()` then `Connection.cancelRpcsFor`.
/// `rpcCall` checks the flag after registering its slot, so the pair is
/// race-free: a slot registered before the cancel walk is woken by the walk; a
/// slot registered after it observes the flag and fails fast.
pub const RpcCanceller = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *RpcCanceller) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const RpcCanceller) bool {
        return self.cancelled.load(.acquire);
    }
};

/// Default timeout for a session-establishing RPC (OPEN / ATTACH). If the agent
/// never replies — e.g. the requested remote command fails to spawn so the agent
/// sends no OPENED — the RPC MUST NOT block its caller (the pane's IO thread)
/// forever: that wedges the surface (blank, never drains) and the app's quit
/// (the IO thread can't join). We bound the wait so a failed OPEN surfaces as an
/// error the backend handles (DETACH + give up) instead of a deadlock.
const rpc_open_timeout_ns: u64 = 10 * std.time.ns_per_s;

/// A remote pane handle (§3.3): one opened/attached session's client-side state.
/// Heap-allocated and owned by the `Connection` (created by `openChannel`/
/// `attachChannel`, freed by `closeChannel`/`detachChannel`). A future
/// `termio.Remote` pane drives input through `writeInput` and drains output from
/// `ring`.
///
/// ## Ownership / teardown contract (§3.4)
/// The connection's data reader pushes inbound DATA into `ring` under the channel
/// table lock. The pane's consumer (the future `termio.Remote` IO thread) drains
/// `ring`. Teardown order is strict (mirrors §3.4 and `ChannelTable`'s invariant):
///   1. The consumer STOPS draining `ring` (and is joined by its owner).
///   2. The owner calls `closeChannel`/`detachChannel`, which deregisters the
///      channel under the table lock — after which no in-flight `pushTo` can touch
///      the ring — then frees the ring and the `Pane`.
/// Calling `closeChannel`/`detachChannel` while the consumer is still draining is a
/// use-after-free hazard and a programmer error.
pub const Pane = struct {
    /// The cryptographically-random channel id (§7.1) minted at open/attach. Never
    /// reused for another session.
    id: u128,
    /// The agent-assigned session id (duped, connection-owned). Empty for a pane
    /// whose attach did not yield one (e.g. `not_found`).
    session_id: []u8,
    /// The child pid reported by OPENED (0 for an attach, which doesn't report it).
    pid: i64,
    /// The inbound ring the pane's consumer drains. Connection-owned; registered in
    /// the channel table for the pane's lifetime.
    ring: *ring.Channel,
    /// Outbound byte offset (§4.2): advanced by `writeInput` per DATA frame so the
    /// agent can resync the *client→agent* stream. The pane owns this counter.
    out_offset: protocol.ByteOffset = .{},

    /// Inbound resync watermark (§7.3): DATA with absolute `byte_offset <=
    /// discard_below` is dropped; only the suffix with offset `> discard_below`
    /// lands in `ring`. 0 (the open-new default) discards nothing. Set by
    /// `attachChannel` to `last_byte_offset - 1` (the last byte the client
    /// already applied) so the agent's `[last_byte_offset, S)` gap-fill replay
    /// is KEPT — it is the missing terminal content — while overlapping
    /// already-applied bytes are dropped. Read by the data reader under
    /// `resync_mutex`; cleared (set to 0 conceptually "passed") once the watermark
    /// is crossed so the steady state takes the fast path.
    discard_below: u64 = 0,
    /// True until the inbound stream has advanced past `discard_below` (so the
    /// data reader can shortcut to "route normally" without per-frame compares).
    /// Guarded by `resync_mutex`.
    resync_active: bool = false,
};

/// The outcome of `attachChannel` (§3.3/§5.3/§7.3). Surfaces everything the caller
/// needs to decide recovery tier (§7.4) or to retry a steal with `force=true`.
pub const AttachOutcome = struct {
    /// The pane handle. Non-null on `.alive` (the channel is registered and live);
    /// null on `.dead`/`.not_found`/`attached_elsewhere` (nothing was registered —
    /// the caller cleans up by retrying or giving up; no `closeChannel` needed).
    pane: ?*Pane,
    /// Liveness tier from the agent (§7.4).
    status: protocol.Attached.AttachStatus,
    /// The byte offset the agent's replay anchor was captured at (§7.3; the
    /// gap-fill replay covers `[last_byte_offset, snapshot_at_offset)`).
    snapshot_at_offset: u64,
    /// The session already had an attached bridge (§5.3). When true with
    /// `force=false`, the caller may retry `attachChannel(..., force=true)` to steal.
    attached_elsewhere: bool,
    /// Present iff `status == .dead` (tombstone exit code, §7.1/§7.4).
    exit_code: ?i64,
    rows: u16,
    cols: u16,
    /// Duped from the reply and owned here (null when the reply omitted them).
    cwd: ?[]u8,
    title: ?[]u8,
    alloc: Allocator,

    /// Free any owned strings (`cwd`/`title`). Does NOT free `pane` — a live pane is
    /// torn down via `closeChannel`/`detachChannel`.
    pub fn deinit(self: *AttachOutcome) void {
        if (self.cwd) |c| self.alloc.free(c);
        if (self.title) |t| self.alloc.free(t);
        self.* = undefined;
    }
};

/// A caller-owned, deep copy of a `PROC_SNAPSHOT` reply (§9.3 process view). The
/// parsed JSON arena that backed the reply is freed inside `requestProcSnapshot`
/// before it returns, so every `Proc` and its `name`/`user`/`cmd` strings are duped
/// into the connection allocator and owned here. Free with `deinit`.
pub const OwnedProcSnapshot = struct {
    /// Host metrics sampled by the agent at snapshot time. `cpu_pct` may be 0 (a
    /// one-shot host read with no prior baseline — subscribe to live metrics for an
    /// accurate host CPU%); the rest (mem/ncpu/uptime) are instantaneous.
    host: protocol.HostMetrics,
    /// The process rows. Owned; `procs[i].name` is always set, `user`/`cmd` may be
    /// null. cpu_pct is per-core (see `agent/proc.zig`).
    procs: []protocol.Proc,
    /// The agent clipped the table to the requested limit.
    truncated: bool,
    /// The agent's own pid (root of the "ghoztty-spawned" descendant tree). 0 =
    /// unknown (agent pre-dates this field).
    agent_pid: i64 = 0,
    alloc: Allocator,

    /// Free the owned process slice and every string it owns.
    pub fn deinit(self: *OwnedProcSnapshot) void {
        for (self.procs) |p| {
            self.alloc.free(@constCast(p.name));
            if (p.user) |u| self.alloc.free(@constCast(u));
            if (p.cmd) |c| self.alloc.free(@constCast(c));
        }
        self.alloc.free(self.procs);
        self.* = undefined;
    }
};

/// One session row from a `LIST_SESSIONS` RPC (T10), deep-copied out of the
/// transient parsed-JSON arena into caller memory. Mirrors `protocol.SessionInfo`
/// but owns every string (freed by `OwnedSessions.deinit`).
pub const OwnedSession = struct {
    id: []const u8,
    alive: bool,
    exit_code: ?i64,
    attached: bool,
    /// idle | busy | needs_input (owned).
    activity: []const u8,
    pid: i64,
    /// Owned; null when the agent had no title/cwd/argv for the session.
    title: ?[]const u8,
    cwd: ?[]const u8,
    argv: ?[]const u8,
    created_at: i64,
    last_activity: i64,
};

/// Caller-owned result of a `LIST_SESSIONS` RPC (T10). Every `OwnedSession` + its
/// strings are duped into `alloc` so the roster outlives the parsed-JSON arena.
/// Free with `deinit`.
pub const OwnedSessions = struct {
    sessions: []OwnedSession,
    alloc: Allocator,

    pub fn deinit(self: *OwnedSessions) void {
        for (self.sessions) |s| {
            self.alloc.free(@constCast(s.id));
            self.alloc.free(@constCast(s.activity));
            if (s.title) |t| self.alloc.free(@constCast(t));
            if (s.cwd) |c| self.alloc.free(@constCast(c));
            if (s.argv) |a| self.alloc.free(@constCast(a));
        }
        self.alloc.free(self.sessions);
        self.* = undefined;
    }
};

/// A caller-owned result of a `PROC_KILL` RPC (§9.3 process control, inc 4). The
/// optional `error_msg` is duped into `alloc` (the parsed JSON arena is freed
/// before `killProc` returns), so free with `deinit`.
pub const ProcKillOutcome = struct {
    pid: i64,
    ok: bool,
    /// Agent-reported failure reason (e.g. "permission denied", "no such
    /// process"), or null on success. Owned; freed by `deinit`.
    error_msg: ?[]const u8 = null,
    alloc: Allocator,

    pub fn deinit(self: *ProcKillOutcome) void {
        if (self.error_msg) |m| self.alloc.free(@constCast(m));
        self.* = undefined;
    }
};

/// A caller-owned result of a `PROC_SPAWN` RPC (§9.3 process control, inc 5).
/// `pid` is set iff `ok`. `error_msg` is duped into `alloc`; free with `deinit`.
pub const ProcSpawnOutcome = struct {
    ok: bool,
    pid: ?i64 = null,
    /// Agent-reported spawn failure reason, or null on success. Owned.
    error_msg: ?[]const u8 = null,
    alloc: Allocator,

    pub fn deinit(self: *ProcSpawnOutcome) void {
        if (self.error_msg) |m| self.alloc.free(@constCast(m));
        self.* = undefined;
    }
};

/// The client side of one remote connection's transport. Heap-allocated because
/// the writer and the two reader threads all reference it for their lifetime.
pub const Connection = struct {
    alloc: Allocator,

    /// The two SSH channels (§4.3). `control` carries HELLO/PING/PONG/SIGNAL/
    /// FLOW/RPC/lifecycle; `data` carries the muxed per-channel DATA.
    control: Stream,
    data: Stream,

    /// The local client HELLO; its `transfer_encoding` is the one encoding used
    /// for every frame in both directions (see the module doc).
    local_hello: protocol.Hello,
    /// The encoding pinned at `create` from `local_hello`. Used by the writer and
    /// both readers. Never changes for the life of the connection.
    encoding: protocol.TransferEncoding,

    /// The peer's self-reported hostname from its HELLO (null if the peer did not
    /// send one). Written once by the control reader BEFORE the handshake gate is
    /// set; readers must only look after `waitHandshake` returns (the gate's
    /// set/wait pair orders the write). Sentinel-terminated so the C API can hand
    /// it out directly. Owned by the connection, freed in `destroy`.
    peer_hostname: ?[:0]u8 = null,

    /// Per-connection frame sequence (§4.2). Assigned by the writer thread at send
    /// time so seq order matches wire order, single-writer (no atomics needed).
    frame_seq: protocol.FrameSeq = .{},

    /// Inbound DATA routing table (§3.4). The data reader pushes into it under its
    /// lock; the caller registers/deregisters the per-pane channels.
    channels: ring.ChannelTable,

    // --- Channel/session lifecycle (increment 3) ------------------------------
    /// `channel id → *Pane` for every pane this connection opened/attached. Guarded
    /// by `panes_mutex`. The data reader consults it (separately from the channel
    /// table) to apply the per-channel resync discard (§7.3) before routing; the
    /// lifecycle methods insert/remove. Never locked while the channel-table lock is
    /// held (and vice-versa) — the two locks are always taken independently, so
    /// there is no lock-ordering inversion with the §3.4 push path.
    panes_mutex: std.Thread.Mutex = .{},
    panes: std.AutoHashMapUnmanaged(u128, *Pane) = .empty,

    /// Pending control-channel RPCs awaiting their reply (OPEN→OPENED,
    /// ATTACH→ATTACHED), keyed by request `Frame.channel`. Guarded by `rpc_mutex`.
    /// The control reader fills + wakes the matching slot; `shutdown` fails them all.
    rpc_mutex: std.Thread.Mutex = .{},
    pending: std.AutoHashMapUnmanaged(u128, *PendingRpc) = .empty,
    /// Secondary correlation for the **channel-authoritative** OPEN/ATTACH replies
    /// (§4.2/§7.1). The agent mints its own session channel and sends OPENED/ATTACHED
    /// on it, so the reply's `Frame.channel` does NOT match the channel the client
    /// sent OPEN/ATTACH on — `pending` (keyed by request channel) can't find the
    /// waiter. These two single slots (one per reply type, since a surface has at
    /// most one OPEN and one ATTACH in flight) let `deliverRpcReply` rendezvous by
    /// reply *type* when the channel lookup misses, and hand the caller the
    /// agent-chosen channel via `PendingRpc.reply_channel`. Guarded by `rpc_mutex`.
    pending_opened: ?*PendingRpc = null,
    pending_attached: ?*PendingRpc = null,
    /// Serializes by-type (OPEN→OPENED / ATTACH→ATTACHED) RPCs so the SINGLE
    /// `pending_opened`/`pending_attached` slot is never contended. Each remote
    /// pane runs on its OWN IO thread and opens a session on this SHARED
    /// Connection; rapidly creating splits/tabs/windows fires several OPENs at
    /// once. Without serialization the second concurrent OPEN found the slot
    /// occupied and failed with `error.RpcInFlight`, leaving that pane dead (and,
    /// downstream, crashing the GUI bring-up). A thread takes this lock for the
    /// FULL duration of its by-type `rpcCall` (send → await reply → slot cleanup),
    /// so concurrent OPENs queue and each completes in turn. Lock ordering: this
    /// is acquired OUTSIDE `rpc_mutex` (never the reverse) — `deliverRpcReply`,
    /// the writer, and shutdown only ever take `rpc_mutex`, so there is no
    /// inversion. Same-channel RPCs (GET_CWD etc.) do NOT take this lock; they
    /// already correlate by their own fresh request channel.
    open_rpc_mutex: std.Thread.Mutex = .{},
    /// Set by `failPendingRpcs` (shutdown) under `rpc_mutex`. Once set, no new RPC
    /// may park — `rpcCall` fails immediately — closing the register-then-shutdown
    /// race where a slot is inserted just after `failPendingRpcs` already iterated.
    rpc_closed: bool = false,

    // --- MPSC writer queue ----------------------------------------------------
    write_mutex: std.Thread.Mutex = .{},
    write_cond: std.Thread.Condition = .{},
    /// FIFO of frames awaiting the writer. Guarded by `write_mutex`.
    write_queue: std.ArrayList(OutFrame) = .empty,

    // --- Handshake ------------------------------------------------------------
    /// Set by the control reader once the peer HELLO has been read and negotiated.
    handshake_done: std.Thread.ResetEvent = .{},
    /// Negotiation outcome, valid once `handshake_done` is set. Either result.
    negotiated: protocol.ProtocolError!protocol.Negotiated = error.Incompatible,

    // --- Control dispatch -----------------------------------------------------
    /// Registered post-handshake control-frame handler (optional).
    ctrl_handler: ?ControlHandler = null,
    ctrl_handler_ctx: *anyopaque = undefined,

    /// Dedicated handler slot for the pushed host-metrics stream (§9.3), separate
    /// from `ctrl_handler` so the two never clobber each other. Set by
    /// `subscribeMetrics`, read on the control-reader hot path, cleared by
    /// `unsubscribeMetrics` — all stores/loads ordered by `write_mutex` exactly
    /// like `ctrl_handler` (publish discipline; see `setControlHandler`).
    metrics_handler: ?MetricsHandler = null,
    metrics_handler_ctx: *anyopaque = undefined,

    // --- Health & link state (increment 2) ------------------------------------
    /// Injected millisecond clock (real by default, fake in tests).
    clock: Clock = Clock.real(),
    /// Heartbeat interval (ms). Injectable; default 3000 (§5.1 interactive).
    heartbeat_interval_ms: u64 = 3000,
    /// Timeout (ns) for a session-establishing RPC (OPEN/ATTACH). Injectable so
    /// tests can use a tiny bound; production default is `rpc_open_timeout_ns`.
    rpc_open_timeout_ns: u64 = rpc_open_timeout_ns,

    /// The link-state FSM (§5.1) and the RTT estimator (§6.4). BOTH are guarded by
    /// `state_mutex` — every read/write goes through it so transitions serialize and
    /// the observer fires exactly once per change.
    link: LinkState = undefined,
    rtt: RttEstimator = .{},
    /// Storage for the default-seeded PRNG when the caller doesn't inject one. Lives
    /// inside the `Connection` so the `std.Random` interface stays valid for life.
    default_prng: std.Random.DefaultPrng = undefined,
    /// Cached SRTT (ms) published for the lock-free `latencyMs` read path. Stored
    /// under `state_mutex`; read atomically (monotonic) without the lock. 0 = none.
    latency_ms: std.atomic.Value(u32) = .{ .raw = 0 },

    /// Set once a `.detached` (steal/eviction, §5.3) lands; surfaced to callers and
    /// drives the FSM to DEAD. Read atomically.
    evicted: std.atomic.Value(bool) = .{ .raw = false },

    /// State-change observer (optional), invoked under `state_mutex` after a change.
    state_handler: ?StateHandler = null,
    state_handler_ctx: *anyopaque = undefined,

    // --- Heartbeat driver (increment 2) ---------------------------------------
    /// Heartbeat sequence the driver owns (NOT `frame_seq`; see `Heartbeat`).
    hb_seq: u64 = 0,
    /// The hb_seq of the most recent PING for which we are still awaiting a PONG,
    /// and whether one is outstanding. Guarded by `hb_mutex`.
    hb_mutex: std.Thread.Mutex = .{},
    hb_outstanding: bool = false,
    hb_pending_seq: u64 = 0,
    hb_pending_send_ms: u64 = 0,
    /// Consecutive missed heartbeat intervals (no PONG before the next tick).
    /// Guarded by `hb_mutex`.
    hb_missed: u32 = 0,
    /// Wakes the heartbeat thread out of its interval sleep on shutdown.
    hb_wake: std.Thread.ResetEvent = .{},
    heartbeat_thread: ?std.Thread = null,

    // --- Lifecycle ------------------------------------------------------------
    /// Set by `shutdown`; observed by the writer to drain-and-exit. Guarded by
    /// `write_mutex` for the writer's condition wait.
    closed: bool = false,
    /// Guards `started`/the thread handles so `shutdown` is idempotent.
    state_mutex: std.Thread.Mutex = .{},
    started: bool = false,
    writer_thread: ?std.Thread = null,
    control_thread: ?std.Thread = null,
    data_thread: ?std.Thread = null,

    /// Tunables for health/heartbeat behavior (increment 2). All have production
    /// defaults; tests inject a fake clock, a tiny interval, and a seeded PRNG to
    /// stay deterministic and fast.
    pub const Options = struct {
        /// Millisecond clock (default: real monotonic).
        clock: Clock = Clock.real(),
        /// Heartbeat interval in ms (default 3000, §5.1).
        heartbeat_interval_ms: u64 = 3000,
        /// PRNG for the full-jitter reconnect backoff. Defaults to a seed derived
        /// from the real clock; tests pass a fixed-seed PRNG for determinism.
        rand: ?std.Random = null,
        /// OPEN/ATTACH RPC timeout in ns (default `rpc_open_timeout_ns`). Tests
        /// pass a tiny value to assert the no-deadlock-on-silent-agent path fast.
        rpc_open_timeout_ns: u64 = rpc_open_timeout_ns,
    };

    /// Allocate and initialize a connection over the two given channel streams.
    /// Does not spawn any thread or touch the wire — call `start` for that.
    pub fn create(
        alloc: Allocator,
        control: Stream,
        data: Stream,
        local_hello: protocol.Hello,
    ) !*Connection {
        return createOpts(alloc, control, data, local_hello, .{});
    }

    /// `create` with explicit health/heartbeat tunables (increment 2).
    pub fn createOpts(
        alloc: Allocator,
        control: Stream,
        data: Stream,
        local_hello: protocol.Hello,
        opts: Options,
    ) !*Connection {
        const self = try alloc.create(Connection);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .control = control,
            .data = data,
            .local_hello = local_hello,
            .encoding = local_hello.transfer_encoding,
            .channels = ring.ChannelTable.init(alloc),
            .clock = opts.clock,
            .heartbeat_interval_ms = opts.heartbeat_interval_ms,
            .rpc_open_timeout_ns = opts.rpc_open_timeout_ns,
        };
        // Seed the embedded PRNG (used only when no PRNG was injected).
        self.default_prng = std.Random.DefaultPrng.init(blk: {
            const t = std.time.milliTimestamp();
            break :blk @bitCast(t);
        });
        self.link = LinkState.init(opts.rand orelse self.default_prng.random());
        return self;
    }

    /// Enqueue the client HELLO and spawn the writer + two reader threads. The
    /// control reader's first action is the handshake (read peer HELLO, negotiate,
    /// signal `handshake_done`). Idempotent guard: calling twice is a programmer
    /// error and asserts in debug.
    pub fn start(self: *Connection) !void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        assert(!self.started);

        // Queue our HELLO before any reader/writer runs so it is the first frame
        // on the control wire (the §4.2 "HELLO first in each direction" rule).
        const hello_json = try self.local_hello.encode(self.alloc);
        defer self.alloc.free(hello_json);
        try self.enqueue(.control, .hello, protocol.control_channel, hello_json);

        // Spawn the writer first so the HELLO can flush even if a reader races.
        self.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{self});
        errdefer {
            // If a later spawn fails, tear the writer down cleanly.
            self.signalClose();
            if (self.writer_thread) |t| t.join();
            self.writer_thread = null;
        }
        self.control_thread = try std.Thread.spawn(.{}, controlReaderLoop, .{self});
        errdefer {
            self.control.close();
            if (self.control_thread) |t| t.join();
            self.control_thread = null;
        }
        self.data_thread = try std.Thread.spawn(.{}, dataReaderLoop, .{self});
        errdefer {
            self.data.close();
            if (self.data_thread) |t| t.join();
            self.data_thread = null;
        }

        // The heartbeat driver (increment 2). It waits for the handshake itself, so
        // it can be spawned now; it ticks only once the link is up. Shutdown wakes it
        // via `hb_wake` and joins it in the same safe (claim-then-join-unlocked) path.
        self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeatLoop, .{self});

        self.started = true;
    }

    /// Block until the handshake completes; return the negotiated parameters or
    /// the negotiation error (version/encoding mismatch, or a malformed peer
    /// HELLO / dropped control stream surfaced as `error.Incompatible`).
    pub fn waitHandshake(self: *Connection) !protocol.Negotiated {
        self.handshake_done.wait();
        return self.negotiated;
    }

    /// Bounded `waitHandshake` (WP-D1 reconnect hardening): block at most
    /// `timeout_ns` for the handshake, then fail with `error.HandshakeTimeout`.
    ///
    /// Why this exists: a peer that TCP-accepts but never speaks (e.g. a
    /// SIGSTOPped agent whose listener still completes connects from the
    /// kernel backlog) would otherwise park the dialer FOREVER — the GUI's
    /// reconnect attempt never fails, so its backoff/attempt counter freezes.
    /// On timeout the connection is NOT torn down here; the caller owns the
    /// teardown (`shutdown` unblocks the reader that is still waiting for the
    /// HELLO and completes the handshake gate with an error).
    pub fn waitHandshakeTimeout(
        self: *Connection,
        timeout_ns: u64,
    ) !protocol.Negotiated {
        self.handshake_done.timedWait(timeout_ns) catch
            return error.HandshakeTimeout;
        return self.negotiated;
    }

    // --- Channel registry (thin wrappers over the table, §3.4) ---------------

    /// Register a pane's inbound channel. The caller owns `ch`'s storage and must
    /// keep it alive until `deregisterChannel` returns (the §3.4 teardown order:
    /// stop consumer → join pane IO thread → deregister → free ring).
    pub fn registerChannel(self: *Connection, ch: *ring.Channel) !void {
        try self.channels.register(ch);
    }

    /// Deregister a pane's inbound channel by id. After this returns, no in-flight
    /// `pushTo` can be touching it (both take the table lock), so the caller may
    /// free its `ring.Channel` storage.
    pub fn deregisterChannel(self: *Connection, id: u128) void {
        self.channels.deregister(id);
    }

    // --- Outbound -------------------------------------------------------------

    /// Enqueue a DATA frame for `channel` onto the data stream. The caller (a
    /// future `Termio.Remote` pane) owns its outbound `protocol.ByteOffset` and
    /// passes the offset in; the connection does NOT track outbound offsets.
    pub fn writeData(
        self: *Connection,
        channel: u128,
        byte_offset: u64,
        bytes: []const u8,
    ) !void {
        // Build the DATA payload (8-byte byte_offset header + bytes) into a temp
        // buffer; `enqueue` dups it into queue-owned memory, so this is freed here.
        const payload = try self.alloc.alloc(u8, protocol.DataPayload.encodedLen(bytes.len));
        defer self.alloc.free(payload);
        const dp: protocol.DataPayload = .{ .byte_offset = byte_offset, .bytes = bytes };
        _ = dp.encodeInto(payload);
        try self.enqueue(.data, .data, channel, payload);
    }

    /// Enqueue a control frame (any non-DATA frame type) onto the control stream.
    pub fn writeControl(
        self: *Connection,
        ftype: protocol.FrameType,
        channel: u128,
        payload: []const u8,
    ) !void {
        try self.enqueue(.control, ftype, channel, payload);
    }

    /// Register the post-handshake control-frame handler. Single-slot; the last
    /// registration wins. `frame.payload` passed to the handler is valid only for
    /// the duration of the call (it borrows the control reader's buffer).
    pub fn setControlHandler(self: *Connection, ctx: *anyopaque, handler: ControlHandler) void {
        self.ctrl_handler_ctx = ctx;
        // Publish the handler under the write mutex so it's visible to the reader;
        // the reader reads it without a lock on the hot path but the store here is
        // ordered before threads observe it via the queue/handshake machinery.
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.ctrl_handler = handler;
    }

    // --- Host-metrics subscription (§9.3, activity monitor) ------------------

    /// Subscribe to the agent's pushed host-metrics stream. Publishes the
    /// dedicated `metrics_handler` slot (under `write_mutex`, same publish
    /// discipline as `setControlHandler`) and sends `METRICS_SUB{interval_ms}`;
    /// the agent then pushes a `.metrics` frame on the control channel every
    /// `interval_ms` until `unsubscribeMetrics`.
    ///
    /// The handler fires on the control-reader thread (see `MetricsHandler`). The
    /// caller MUST call `unsubscribeMetrics` before freeing `ctx`.
    pub fn subscribeMetrics(
        self: *Connection,
        interval_ms: u32,
        ctx: *anyopaque,
        handler: MetricsHandler,
    ) !void {
        // Publish the handler slot BEFORE sending the subscription so the first
        // pushed frame is never dropped for lack of a handler.
        {
            self.metrics_handler_ctx = ctx;
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            self.metrics_handler = handler;
        }

        const sub: protocol.MetricsSub = .{ .interval_ms = interval_ms };
        const json = try protocol.encodeJson(self.alloc, sub);
        defer self.alloc.free(json);
        try self.writeControl(.metrics_sub, protocol.control_channel, json);
    }

    /// Unsubscribe from the pushed host-metrics stream. Sends `METRICS_UNSUB{}`
    /// (best-effort — a send failure on a closing connection is ignored) and then
    /// clears the `metrics_handler` slot under `write_mutex`, so no further
    /// callback fires after this returns. Safe to call when not subscribed (the
    /// unsub send is harmless and the slot is already null).
    pub fn unsubscribeMetrics(self: *Connection) void {
        const json = protocol.encodeJson(self.alloc, protocol.MetricsUnsub{}) catch null;
        if (json) |j| {
            defer self.alloc.free(j);
            self.writeControl(.metrics_unsub, protocol.control_channel, j) catch {};
        }

        // Clear the handler slot under the same lock the reader's publish/observe
        // is ordered by, so a concurrent control-reader either sees the handler
        // (before this) or null (after) — never a torn value, and never a stale
        // handler after we return.
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.metrics_handler = null;
    }

    // --- Observability (increment 2, §6.4) -----------------------------------

    /// Register the link-state observer, fired on every FSM transition (§5.1). See
    /// `StateHandler`: it runs under `state_mutex`, so it must not re-enter
    /// `Connection` methods that take that lock.
    pub fn setStateHandler(self: *Connection, ctx: *anyopaque, handler: StateHandler) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        self.state_handler_ctx = ctx;
        self.state_handler = handler;
    }

    /// Clear the link-state observer. Takes `state_mutex`, so on return any
    /// in-flight handler invocation has completed and no further one can fire —
    /// the caller may then free whatever `ctx` pointed at (the teardown-safety
    /// counterpart to `setStateHandler`, used by the C-API handle destroy path).
    pub fn clearStateHandler(self: *Connection) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        self.state_handler = null;
    }

    /// The current link state (§5.1). Thread-safe (takes `state_mutex`).
    pub fn state(self: *Connection) LinkState.State {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.link.state;
    }

    /// The current smoothed RTT in ms (§6.4), or null before the first PONG.
    /// Lock-free read of the published cache.
    pub fn latencyMs(self: *Connection) ?u32 {
        const v = self.latency_ms.load(.monotonic);
        return if (v == 0) null else v;
    }

    /// The current RTT health badge bucket (§6.4). Thread-safe.
    pub fn health(self: *Connection) RttEstimator.Health {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.rtt.health();
    }

    /// True once the agent evicted us (DETACHED steal, §5.3). Lock-free.
    pub fn isEvicted(self: *Connection) bool {
        return self.evicted.load(.monotonic);
    }

    /// Apply `f` to `self.link` under `state_mutex`, then fire the observer if the
    /// state changed and republish the cached SRTT. Centralizes the
    /// "transition + notify" so every state-mutating event path is consistent.
    /// `f` must take `*LinkState` and is given the lock-held FSM.
    fn withLink(self: *Connection, comptime f: fn (*LinkState) void) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const old = self.link.state;
        f(&self.link);
        const new = self.link.state;
        if (new != old) {
            if (self.state_handler) |h| {
                // Fired UNDER `state_mutex` (see `StateHandler` doc) so notifications
                // are strictly serialized and ordered. The handler must not re-enter
                // a `state_mutex`-taking method.
                h(self.state_handler_ctx, self, old, new);
            }
        }
    }

    /// Copy `payload` into queue-owned memory, append the record, and wake the
    /// writer. Safe to call from any thread (MPSC). On a closed connection the
    /// frame is dropped (the writer is gone / draining).
    fn enqueue(
        self: *Connection,
        stream: StreamId,
        ftype: protocol.FrameType,
        channel: u128,
        payload: []const u8,
    ) !void {
        const owned = try self.alloc.dupe(u8, payload);
        errdefer self.alloc.free(owned);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.closed) {
            // Drop: nothing will ever send it. Free here, not in the writer.
            self.alloc.free(owned);
            return;
        }
        try self.write_queue.append(self.alloc, .{
            .stream = stream,
            .ftype = ftype,
            .channel = channel,
            .payload = owned,
        });
        self.write_cond.signal();
    }

    /// Mark the connection closed and wake the writer so it drains and exits.
    fn signalClose(self: *Connection) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.closed = true;
        self.write_cond.signal();
    }

    /// Idempotent teardown: mark closed, close both streams (unblocking the
    /// readers' blocking `read`s), wake the writer, and join all three threads.
    /// Any frames still queued are dropped and freed (by the writer on its way
    /// out, or here if the writer never started). Safe to call multiple times.
    ///
    /// We must NOT hold `state_mutex` while joining: the control reader takes
    /// `state_mutex` inside `completeHandshake`, so holding it across the join
    /// would deadlock against a reader still finishing its handshake. Instead we
    /// claim the threads under a brief lock, release it, then join unlocked.
    pub fn shutdown(self: *Connection) void {
        self.state_mutex.lock();
        const writer = self.writer_thread;
        const control = self.control_thread;
        const data = self.data_thread;
        const heartbeat = self.heartbeat_thread;
        self.writer_thread = null;
        self.control_thread = null;
        self.data_thread = null;
        self.heartbeat_thread = null;
        self.state_mutex.unlock();

        // Wake the writer to drain-and-exit, unblock both reader reads, and wake the
        // heartbeat thread out of its interval sleep so it exits promptly.
        self.signalClose();
        self.control.close();
        self.data.close();
        self.hb_wake.set();

        // Unblock the heartbeat thread if it is still parked on the handshake event
        // (shutdown before the handshake completed): publish a failed handshake here
        // BEFORE joining, mirroring the post-join unblock below. (The post-join block
        // remains for the reader-completes-handshake race.)
        if (heartbeat != null and !self.handshake_done.isSet()) {
            self.completeHandshake(error.Incompatible);
        }

        // Fail every parked RPC caller BEFORE joining so an OPEN/ATTACH blocked on
        // `done.wait()` wakes promptly (its caller may be the thread joining nothing
        // here, but in general it is a separate caller thread). After the readers
        // join, no new slot can be filled, so do it once here; callers remove their
        // own slot, but mark+set unblocks them regardless. (Filling under the lock,
        // setting after — same claim-then-act discipline as the handshake unblock.)
        self.failPendingRpcs();

        if (writer) |t| t.join();
        if (control) |t| t.join();
        if (data) |t| t.join();
        if (heartbeat) |t| t.join();

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        // If the writer never ran (start failed before spawning it), free any
        // payloads it would have freed. After a normal run the queue is empty.
        for (self.write_queue.items) |f| self.alloc.free(f.payload);
        self.write_queue.clearRetainingCapacity();

        // Unblock anyone still waiting on the handshake (e.g. shutdown before the
        // peer HELLO arrived) so they don't hang. Leaves a prior result intact.
        if (!self.handshake_done.isSet()) {
            self.negotiated = error.Incompatible;
            self.handshake_done.set();
        }
    }

    /// Free the connection. Must be called after `shutdown` has joined the threads.
    pub fn destroy(self: *Connection, alloc: Allocator) void {
        // Defensive: ensure no thread is still live and the queue is drained.
        assert(self.writer_thread == null);
        assert(self.control_thread == null);
        assert(self.data_thread == null);
        assert(self.heartbeat_thread == null);
        self.write_queue.deinit(alloc);
        self.channels.deinit();
        if (self.peer_hostname) |h| alloc.free(h);
        // Any panes still registered at destroy (the caller didn't close/detach
        // them) are freed here so the connection owns no leaks. Their channels were
        // already deregistered-or-irrelevant since all threads have joined.
        var it = self.panes.iterator();
        while (it.next()) |entry| {
            const pane = entry.value_ptr.*;
            pane.ring.deinit(alloc);
            alloc.destroy(pane.ring);
            alloc.free(pane.session_id);
            alloc.destroy(pane);
        }
        self.panes.deinit(alloc);
        // The pending map must be empty after `shutdown` (it fails+removes all).
        assert(self.pending.count() == 0);
        self.pending.deinit(alloc);
        alloc.destroy(self);
    }

    // --- Channel / session lifecycle (increment 3, §3.3/§4.2/§7.3) -----------

    /// Open a brand-new remote session (§3.3 open-new). Mints a fresh
    /// cryptographically-random channel id (§7.1 — NEVER reused), registers an
    /// inbound ring for it, sends `OPEN` (JSON) on that channel, awaits
    /// `OPENED{session_id, pid}`, and returns the owned `*Pane`. On any failure
    /// nothing is left registered and the pane is not created (caller owns nothing).
    ///
    /// `open` is the §4.2 payload (cwd/command/shell/term/env/rows/cols/...). The
    /// caller need not set a channel — this method owns channel-id minting.
    pub fn openChannel(self: *Connection, open: protocol.Open) !*Pane {
        return self.openChannelCancellable(open, null);
    }

    /// `openChannel` with an optional cancellation token (see `RpcCanceller`):
    /// `cancelRpcsFor(canceller)` from another thread aborts the parked OPEN with
    /// `error.Cancelled`. Used by the remote termio backend so surface teardown
    /// can wake a pane's IO thread out of a doomed OPEN before joining it.
    pub fn openChannelCancellable(
        self: *Connection,
        open: protocol.Open,
        canceller: ?*const RpcCanceller,
    ) !*Pane {
        // Mint a fresh channel id for the OUTBOUND OPEN frame (§7.1). The agent is
        // **channel-authoritative**: it mints its OWN session channel and replies
        // OPENED on it (see `deliverRpcReply`/`rpcCall`). So we send OPEN on our
        // minted channel but adopt the channel the OPENED reply arrives on as the
        // pane's real data channel. (When the peer echoes on our channel — the
        // loopback mock agents — the adopted channel equals `req_channel`, so this is
        // a no-op there. The real agent gives us its own channel.)
        const req_channel = std.crypto.random.int(u128);

        // Send OPEN and await OPENED; learn the agent's data channel from the reply.
        // We register the inbound ring AFTER OPENED on the agent-chosen channel — the
        // agent streams DATA only after it has sent OPENED, so nothing is lost (this
        // matches the proven frame-level path in `test_client.zig`).
        const open_json = try protocol.encodeJson(self.alloc, open);
        defer self.alloc.free(open_json);
        const rpc = try self.rpcCall(req_channel, .open, .opened, open_json, self.rpc_open_timeout_ns, canceller);
        defer self.alloc.free(rpc.payload);
        const id = rpc.channel; // agent-authoritative data channel

        var parsed = protocol.parseJson(protocol.Opened, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();

        // Register the inbound ring on the agent's channel so output DATA lands.
        const ch = try self.alloc.create(ring.Channel);
        errdefer self.alloc.destroy(ch);
        ch.* = try ring.Channel.init(self.alloc, id, .{});
        errdefer ch.deinit(self.alloc);
        try self.registerChannel(ch);
        errdefer self.deregisterChannel(id);

        const session_id = try self.alloc.dupe(u8, parsed.value.session_id);
        errdefer self.alloc.free(session_id);

        const pane = try self.alloc.create(Pane);
        errdefer self.alloc.destroy(pane);
        pane.* = .{
            .id = id,
            .session_id = session_id,
            .pid = parsed.value.pid,
            .ring = ch,
        };
        try self.trackPane(pane);
        return pane;
    }

    /// On-demand query for a remote session's child working directory (§WP4).
    /// Sends `GET_CWD{session_id}` and awaits `CWD{session_id, path?, ok}`, then
    /// returns a NEW caller-owned copy of the path (caller frees with `self.alloc`),
    /// or null if the agent reported failure (`ok == false`) or returned an empty
    /// path.
    ///
    /// This is a same-channel RPC: we mint a fresh request channel, send GET_CWD on
    /// it, and the agent echoes CWD on that channel — correlated by the `pending`
    /// map (NOT the by-type slot, which is reserved for OPEN/ATTACH). It uses the
    /// same bounded `rpc_open_timeout_ns` + parked-slot mechanism as `openChannel`,
    /// so a missing/late reply returns `error.Timeout` rather than hanging.
    pub fn queryCwd(self: *Connection, session_id: []const u8) ![]u8 {
        return self.queryCwdTimeout(session_id, self.rpc_open_timeout_ns);
    }

    /// `queryCwd` with an explicit RPC timeout (ns). Used by the GUI so a cwd
    /// query for a new split/tab/window can be bounded tightly (it runs off the
    /// main thread but a tight bound keeps a fresh frame from waiting on a slow
    /// or wedged agent). `error.Timeout` on no reply within `timeout_ns`.
    pub fn queryCwdTimeout(self: *Connection, session_id: []const u8, timeout_ns: u64) ![]u8 {
        const req_channel = std.crypto.random.int(u128);
        const get: protocol.GetCwd = .{ .session_id = session_id };
        const json = try protocol.encodeJson(self.alloc, get);
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .get_cwd, .cwd, json, timeout_ns, null);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.Cwd, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();

        if (!parsed.value.ok) return error.CwdUnavailable;
        const path = parsed.value.path orelse return error.CwdUnavailable;
        if (path.len == 0) return error.CwdUnavailable;
        return self.alloc.dupe(u8, path);
    }

    /// Tri-state result of a session liveness probe (T06b). The distinction
    /// matters for session-restore drop policy: only `.dead` (the agent
    /// POSITIVELY reported the id absent from its table) may forget a persisted
    /// layout entry; `.unknown` (RPC failure/timeout, malformed reply, or an
    /// older agent that can't disambiguate) must keep it.
    pub const SessionProbe = enum { alive, dead, unknown };

    /// Probe whether the agent still knows `session_id` (T06b). Rides the same
    /// GET_CWD/CWD same-channel RPC as `queryCwdTimeout` but interprets the
    /// reply's existence signal instead of its path:
    ///   - `ok == true`  ⇒ `.alive` (session exists; cwd even resolved)
    ///   - `found == true`  ⇒ `.alive` (exists/attachable; cwd read failed —
    ///     e.g. the child exited but the session ring is retained)
    ///   - `found == false` ⇒ `.dead` (positively absent from the table)
    ///   - anything else (timeout, transport error, malformed reply, older
    ///     agent without `found`) ⇒ `.unknown`
    /// Never returns an error: probe failures are themselves a result.
    pub fn probeSessionTimeout(
        self: *Connection,
        session_id: []const u8,
        timeout_ns: u64,
    ) SessionProbe {
        const req_channel = std.crypto.random.int(u128);
        const get: protocol.GetCwd = .{ .session_id = session_id };
        const json = protocol.encodeJson(self.alloc, get) catch return .unknown;
        defer self.alloc.free(json);

        const rpc = self.rpcCall(req_channel, .get_cwd, .cwd, json, timeout_ns, null) catch
            return .unknown;
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.Cwd, self.alloc, rpc.payload) catch
            return .unknown;
        defer parsed.deinit();

        if (parsed.value.ok) return .alive;
        const found = parsed.value.found orelse return .unknown;
        return if (found) .alive else .dead;
    }

    /// Request the remote host's process table (§9.3 process view). Sends
    /// `PROC_LIST{sort, limit}` and awaits `PROC_SNAPSHOT{ok, host, procs,
    /// truncated}`, returning a caller-owned DEEP COPY (`OwnedProcSnapshot`): every
    /// `Proc` + its strings are duped into `self.alloc` so the result outlives the
    /// transient parsed-JSON arena (freed before this returns). Free with
    /// `OwnedProcSnapshot.deinit`.
    ///
    /// Same-channel RPC (mirrors `queryCwdTimeout`): a fresh request channel, the
    /// agent echoes `PROC_SNAPSHOT` on it, correlated via the `pending` map. Bounded
    /// by `timeout_ns` — a missing/late reply returns `error.Timeout` rather than
    /// hanging. `error.ProcUnavailable` if the agent reported `ok == false`. `limit`
    /// of 0 asks for the agent's default cap.
    pub fn requestProcSnapshot(
        self: *Connection,
        sort: ?[]const u8,
        limit: u32,
        timeout_ns: u64,
    ) !OwnedProcSnapshot {
        const req_channel = std.crypto.random.int(u128);
        const req: protocol.ProcList = .{
            .sort = sort,
            .limit = if (limit == 0) null else limit,
        };
        const json = try protocol.encodeJson(self.alloc, req);
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .proc_list, .proc_snapshot, json, timeout_ns, null);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.ProcSnapshot, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();

        if (!parsed.value.ok) return error.ProcUnavailable;

        // Deep-copy the procs out of the parsed arena into caller-owned memory.
        const src = parsed.value.procs;
        var procs = try self.alloc.alloc(protocol.Proc, src.len);
        // On a mid-copy failure, free what we've duped so far (no leak).
        var filled: usize = 0;
        errdefer {
            for (procs[0..filled]) |p| {
                self.alloc.free(@constCast(p.name));
                if (p.user) |u| self.alloc.free(@constCast(u));
                if (p.cmd) |c| self.alloc.free(@constCast(c));
            }
            self.alloc.free(procs);
        }
        for (src, 0..) |p, i| {
            const name = try self.alloc.dupe(u8, p.name);
            errdefer self.alloc.free(name);
            const user: ?[]const u8 = if (p.user) |u| try self.alloc.dupe(u8, u) else null;
            errdefer if (user) |u| self.alloc.free(u);
            const cmd: ?[]const u8 = if (p.cmd) |c| try self.alloc.dupe(u8, c) else null;
            procs[i] = .{
                .pid = p.pid,
                .ppid = p.ppid,
                .name = name,
                .cpu_pct = p.cpu_pct,
                .mem_bytes = p.mem_bytes,
                .user = user,
                .cmd = cmd,
            };
            filled = i + 1;
        }

        return .{
            .host = parsed.value.host,
            .procs = procs,
            .truncated = parsed.value.truncated,
            .agent_pid = parsed.value.agent_pid,
            .alloc = self.alloc,
        };
    }

    /// Enumerate the agent's sessions (T10). Sends `LIST_SESSIONS{}` and awaits
    /// `SESSIONS{sessions:[...]}`, returning a caller-owned DEEP COPY
    /// (`OwnedSessions`): every row + its strings are duped into `self.alloc` so the
    /// result outlives the transient parsed-JSON arena (freed before this returns).
    /// Free with `OwnedSessions.deinit`.
    ///
    /// Same-channel RPC (mirrors `requestProcSnapshot`): a fresh request channel, the
    /// agent echoes `SESSIONS` on it, correlated via the `pending` map. Bounded by
    /// `timeout_ns` — a missing/late reply returns `error.Timeout` rather than
    /// hanging.
    pub fn requestSessions(self: *Connection, timeout_ns: u64) !OwnedSessions {
        const req_channel = std.crypto.random.int(u128);
        const json = try protocol.encodeJson(self.alloc, protocol.ListSessions{});
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .list_sessions, .sessions, json, timeout_ns, null);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.Sessions, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();

        const src = parsed.value.sessions;
        var out = try self.alloc.alloc(OwnedSession, src.len);
        // On a mid-copy failure, free everything duped so far (no leak).
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |s| {
                self.alloc.free(@constCast(s.id));
                self.alloc.free(@constCast(s.activity));
                if (s.title) |t| self.alloc.free(@constCast(t));
                if (s.cwd) |c| self.alloc.free(@constCast(c));
                if (s.argv) |a| self.alloc.free(@constCast(a));
            }
            self.alloc.free(out);
        }
        for (src, 0..) |s, i| {
            const id = try self.alloc.dupe(u8, s.id);
            errdefer self.alloc.free(id);
            const activity = try self.alloc.dupe(u8, s.activity);
            errdefer self.alloc.free(activity);
            const title: ?[]const u8 = if (s.title) |t| try self.alloc.dupe(u8, t) else null;
            errdefer if (title) |t| self.alloc.free(t);
            const cwd: ?[]const u8 = if (s.cwd) |c| try self.alloc.dupe(u8, c) else null;
            errdefer if (cwd) |c| self.alloc.free(c);
            const argv: ?[]const u8 = if (s.argv) |a| try self.alloc.dupe(u8, a) else null;
            out[i] = .{
                .id = id,
                .alive = s.alive,
                .exit_code = s.exit_code,
                .attached = s.attached,
                .activity = activity,
                .pid = s.pid,
                .title = title,
                .cwd = cwd,
                .argv = argv,
                .created_at = s.created_at,
                .last_activity = s.last_activity,
            };
            filled = i + 1;
        }

        return .{ .sessions = out, .alloc = self.alloc };
    }

    /// Kill a remote process by pid (§9.3 process control, inc 4). Sends
    /// `PROC_KILL{pid, signal}` and awaits `PROC_KILL_RESULT{pid, ok, error?}`,
    /// returning a caller-owned `ProcKillOutcome` (any error string is duped into
    /// `self.alloc`). `signal` of null ⇒ the agent's default terminate; "TERM" /
    /// "KILL" select the POSIX signal (on Windows both map to TerminateProcess).
    /// Same-channel RPC (mirrors `requestProcSnapshot`), bounded by `timeout_ns`
    /// (`error.Timeout` on no reply). Free the result with `.deinit`.
    pub fn killProc(
        self: *Connection,
        pid: i64,
        signal: ?[]const u8,
        timeout_ns: u64,
    ) !ProcKillOutcome {
        const req_channel = std.crypto.random.int(u128);
        const req: protocol.ProcKill = .{ .pid = pid, .signal = signal };
        const json = try protocol.encodeJson(self.alloc, req);
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .proc_kill, .proc_kill_result, json, timeout_ns, null);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.ProcKillResult, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();

        const err_copy: ?[]const u8 = if (parsed.value.@"error") |m|
            try self.alloc.dupe(u8, m)
        else
            null;
        return .{
            .pid = parsed.value.pid,
            .ok = parsed.value.ok,
            .error_msg = err_copy,
            .alloc = self.alloc,
        };
    }

    /// Spawn a detached process on the remote host (§9.3 process control, inc 5).
    /// Sends `PROC_SPAWN{cmd, cwd}` and awaits `PROC_SPAWN_RESULT{ok, pid?,
    /// error?}`, returning a caller-owned `ProcSpawnOutcome` (any error string is
    /// duped into `self.alloc`). The agent runs `cmd` through its platform shell,
    /// detached, with no pty. Same-channel RPC, bounded by `timeout_ns`. Free with
    /// `.deinit`.
    pub fn spawnProc(
        self: *Connection,
        cmd: []const u8,
        cwd: ?[]const u8,
        timeout_ns: u64,
    ) !ProcSpawnOutcome {
        const req_channel = std.crypto.random.int(u128);
        const req: protocol.ProcSpawn = .{ .cmd = cmd, .cwd = cwd };
        const json = try protocol.encodeJson(self.alloc, req);
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .proc_spawn, .proc_spawn_result, json, timeout_ns, null);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.ProcSpawnResult, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();

        const err_copy: ?[]const u8 = if (parsed.value.@"error") |m|
            try self.alloc.dupe(u8, m)
        else
            null;
        return .{
            .ok = parsed.value.ok,
            .pid = parsed.value.pid,
            .error_msg = err_copy,
            .alloc = self.alloc,
        };
    }

    /// Re-attach to an existing session (§3.3 attach / §7.3 sequence-anchored
    /// resync / §5.3 steal). Mints a fresh channel id (§7.1), registers an inbound
    /// ring, sends `ATTACH{session_id, rows, cols, last_byte_offset, force}`, and
    /// awaits `ATTACHED`. Returns an `AttachOutcome`:
    ///   - `.alive`: a live `*Pane` is returned (registered + tracked) with
    ///     `discard_below = snapshot_at_offset` so the data reader drops already-
    ///     applied DATA (§7.3).
    ///   - `.dead` / `.not_found`: no pane; the channel is deregistered/freed here.
    ///   - `attached_elsewhere && !force`: no pane; the caller may retry with
    ///     `force=true` to steal (§5.3). We do NOT auto-steal.
    ///
    /// The caller frees the outcome's `cwd`/`title` via `AttachOutcome.deinit`.
    pub fn attachChannel(
        self: *Connection,
        session_id: []const u8,
        rows: u16,
        cols: u16,
        last_byte_offset: u64,
        force: bool,
    ) !AttachOutcome {
        return self.attachChannelCancellable(session_id, rows, cols, last_byte_offset, force, null);
    }

    /// `attachChannel` with an optional cancellation token (see `RpcCanceller`):
    /// `cancelRpcsFor(canceller)` from another thread aborts the parked ATTACH
    /// with `error.Cancelled`. Used by the remote termio backend so surface
    /// teardown can wake a pane's IO thread out of a doomed ATTACH (e.g. sent
    /// onto a silently-dead link during reconnect churn) before joining it.
    pub fn attachChannelCancellable(
        self: *Connection,
        session_id: []const u8,
        rows: u16,
        cols: u16,
        last_byte_offset: u64,
        force: bool,
        canceller: ?*const RpcCanceller,
    ) !AttachOutcome {
        // Mint a fresh channel id for the OUTBOUND ATTACH frame (§7.1). As with
        // OPEN, the agent is **channel-authoritative**: it replies ATTACHED on the
        // session's own channel (or on `control_channel` for `not_found`), so we
        // adopt the channel the ATTACHED reply arrives on and register the inbound
        // ring on THAT channel only once the session is confirmed alive.
        //
        // NOTE (§7.3): the agent emits gap-fill/replay DATA right after ATTACHED. We
        // register the ring as soon as ATTACHED is parsed; the brief window between
        // the control-lane ATTACHED and the first data-lane replay frame is covered
        // because both ride the agent's single writer (ATTACHED enqueued first) — but
        // since control/data are separate lanes, deep-scrollback resume should prefer
        // the frame-level path (`test_client.zig`'s `Attach`) which pre-registers on
        // the known stable channel. For a fresh attach (`last_byte_offset == 0`,
        // §7.3 snapshot-from-head) there is nothing earlier than the snapshot to miss.
        const req_channel = std.crypto.random.int(u128);

        const attach: protocol.Attach = .{
            .session_id = session_id,
            .rows = rows,
            .cols = cols,
            .last_byte_offset = last_byte_offset,
            .force = force,
        };
        const attach_json = try protocol.encodeJson(self.alloc, attach);
        defer self.alloc.free(attach_json);
        const rpc = try self.rpcCall(req_channel, .attach, .attached, attach_json, self.rpc_open_timeout_ns, canceller);
        defer self.alloc.free(rpc.payload);
        const id = rpc.channel; // agent-authoritative session channel

        var parsed = protocol.parseJson(protocol.Attached, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();
        const a = parsed.value;

        // Register the inbound ring on the agent's channel. On any early return
        // (dead/not_found, or a non-forced steal) we tear it back down; only a kept
        // pane disarms this by flipping `keep_channel`.
        const ch = try self.alloc.create(ring.Channel);
        errdefer self.alloc.destroy(ch);
        ch.* = try ring.Channel.init(self.alloc, id, .{});
        errdefer ch.deinit(self.alloc);
        try self.registerChannel(ch);
        var keep_channel = false;
        errdefer if (!keep_channel) self.deregisterChannel(id);

        const cwd = if (a.cwd) |c| try self.alloc.dupe(u8, c) else null;
        errdefer if (cwd) |c| self.alloc.free(c);
        const title = if (a.title) |t| try self.alloc.dupe(u8, t) else null;
        errdefer if (title) |t| self.alloc.free(t);

        var outcome: AttachOutcome = .{
            .pane = null,
            .status = a.status,
            .snapshot_at_offset = a.snapshot_at_offset,
            .attached_elsewhere = a.attached_elsewhere,
            .exit_code = a.exit_code,
            .rows = a.rows,
            .cols = a.cols,
            .cwd = cwd,
            .title = title,
            .alloc = self.alloc,
        };

        // Only a live, non-stolen attach yields a pane. For everything else
        // (.dead/.not_found, or a non-forced steal) we keep no pane and explicitly
        // tear the channel back down here (a value return doesn't fire `errdefer`).
        const keep = a.status == .alive and !(a.attached_elsewhere and !force);
        if (!keep) {
            self.deregisterChannel(id);
            ch.deinit(self.alloc);
            self.alloc.destroy(ch);
            return outcome; // value return: no errdefer fires
        }

        const sid = try self.alloc.dupe(u8, session_id);
        errdefer self.alloc.free(sid);
        const pane = try self.alloc.create(Pane);
        errdefer self.alloc.destroy(pane);
        pane.* = .{
            .id = id,
            .session_id = sid,
            .pid = 0, // an attach does not report a pid (OPENED does)
            .ring = ch,
            // §7.3 resync discard, anchored at what THIS CLIENT already applied
            // (`last_byte_offset` = next byte we expect), NOT at the agent's
            // snapshot head. The agent's gap-fill replays `[last_byte_offset,
            // snapshot_at)` — those bytes ARE the missing terminal content (no
            // grid snapshot is transferred yet, `TODO(snapshot)` agent-side), so
            // a discard watermark at `snapshot_at_offset` silently erased the
            // entire replay and every reconnect/restore attach came up BLANK
            // (the WP-D1 wedged-window bug). A fresh attach (offset 0) keeps
            // everything; a resumed surface drops only the bytes it already has.
            .discard_below = if (last_byte_offset > 0) last_byte_offset - 1 else 0,
            .resync_active = last_byte_offset > 0,
        };
        try self.trackPane(pane);
        keep_channel = true; // the pane now owns the registered ring
        outcome.pane = pane;
        return outcome;
    }

    /// Close a pane's session (§3.3): send `CLOSE` (terminate + free the remote
    /// session), then deregister and free the pane locally. The caller MUST have
    /// stopped its consumer from draining `pane.ring` first (teardown order §3.4).
    /// Closing is best-effort on the wire (a dead link drops the frame); the local
    /// teardown always completes.
    pub fn closeChannel(self: *Connection, pane: *Pane) void {
        self.writeControl(.close, pane.id, "") catch {};
        self.teardownPane(pane);
    }

    /// Detach a pane (§3.3 / `Exec.deinit` analogue): send `DETACH` (stop streaming
    /// but KEEP the remote session alive for a later re-attach), then deregister and
    /// free the pane locally. Same teardown-order precondition as `closeChannel`.
    pub fn detachChannel(self: *Connection, pane: *Pane) void {
        self.writeControl(.detach, pane.id, "") catch {};
        self.teardownPane(pane);
    }

    /// Frame `bytes` as DATA with the pane's monotonic outbound `byte_offset` (§4.2)
    /// and enqueue it on the data stream. The offset advances by `bytes.len` so the
    /// agent can resync the client→agent stream. Safe to call from the pane's IO
    /// thread (the only writer of `pane.out_offset`).
    pub fn writeInput(self: *Connection, pane: *Pane, bytes: []const u8) !void {
        const offset = pane.out_offset.advance(bytes.len);
        try self.writeData(pane.id, offset, bytes);
    }

    /// Emit `FLOW{resume}` for `channel` (§3.4 consumer-side counterpart to the
    /// producer-side `FLOW{pause}`). The pane's IO thread calls this once its
    /// inbound ring drain crosses back under the low-water mark (the
    /// `inbound_ring.PopResult.send_resume` edge), telling the agent it may resume
    /// draining that session's PTY. The target channel is carried in the FLOW
    /// payload; the frame itself rides the control channel (§4.2). Best-effort: a
    /// dead link silently drops it (the resync re-establishes flow on reconnect).
    pub fn sendFlowResume(self: *Connection, channel: u128) !void {
        const flow: protocol.Flow = .{ .channel = channel, .op = .@"resume" };
        var buf: [protocol.Flow.encoded_len]u8 = undefined;
        _ = flow.encodeInto(&buf);
        try self.writeControl(.flow, protocol.control_channel, &buf);
    }

    /// Emit `RESIZE{rows, cols, px_w, px_h}` for `pane`'s channel (§3.3/§6.5). The
    /// pane's IO thread calls this on a grid/screen size change; the agent applies
    /// it to the remote PTY (TIOCSWINSZ / ConPTY). Best-effort on a dead link.
    pub fn sendResize(
        self: *Connection,
        pane: *Pane,
        rows: u16,
        cols: u16,
        px_w: u16,
        px_h: u16,
    ) !void {
        const resize: protocol.Resize = .{
            .rows = rows,
            .cols = cols,
            .px_w = px_w,
            .px_h = px_h,
        };
        const json = try protocol.encodeJson(self.alloc, resize);
        defer self.alloc.free(json);
        try self.writeControl(.resize, pane.id, json);
    }

    /// Insert `pane` into the `panes` map under `panes_mutex`.
    fn trackPane(self: *Connection, pane: *Pane) !void {
        self.panes_mutex.lock();
        defer self.panes_mutex.unlock();
        try self.panes.put(self.alloc, pane.id, pane);
    }

    /// Common local teardown for `closeChannel`/`detachChannel`: remove the pane
    /// from the resync map, deregister its channel under the table lock (after which
    /// no `pushTo` can touch the ring), then free the ring, session id, and pane.
    fn teardownPane(self: *Connection, pane: *Pane) void {
        self.panes_mutex.lock();
        _ = self.panes.remove(pane.id);
        self.panes_mutex.unlock();

        // Deregister under the table lock: any in-flight `pushTo` has finished and no
        // new one can find the channel, so the ring is safe to free (§3.4 invariant).
        self.deregisterChannel(pane.id);
        pane.ring.deinit(self.alloc);
        self.alloc.destroy(pane.ring);
        self.alloc.free(pane.session_id);
        self.alloc.destroy(pane);
    }

    /// The result of an `rpcCall`: the duped reply payload (caller frees) plus the
    /// channel the reply actually arrived on (the agent-authoritative session channel
    /// for OPEN/ATTACH; equal to the request channel otherwise).
    const RpcResult = struct { payload: []u8, channel: u128 };

    /// Issue a control-channel RPC and block until the matching reply (`want`)
    /// arrives, or the link closes. Parks a stack-owned `PendingRpc` and waits on its
    /// event.
    ///
    /// Correlation (§4.2): OPEN/ATTACH replies are **channel-authoritative** — the
    /// agent mints its own session channel and sends OPENED/ATTACHED on it, so the
    /// reply does NOT come back on `channel`. For those we register a single
    /// by-reply-type slot (`pending_opened`/`pending_attached`) that
    /// `deliverRpcReply` matches by reply type and stamps with the agent's channel.
    /// Every other RPC correlates by the request `channel` via `pending` (the
    /// same-channel case, used by the loopback mock agents). On return,
    /// `RpcResult.channel` is the channel the caller should adopt.
    /// `timeout_ns` bounds how long we park on the reply (null ⇒ wait forever).
    /// A timeout returns `error.Timeout`; the slot is removed by the trailing
    /// `defer` exactly as on the success path, so a late reply is safely dropped.
    /// `canceller` (optional) lets another thread abort this call early via
    /// `cancelRpcsFor` — `error.Cancelled` — used by surface teardown so a
    /// parked OPEN/ATTACH never wedges the join of the pane's IO thread.
    fn rpcCall(
        self: *Connection,
        channel: u128,
        req: protocol.FrameType,
        want: protocol.FrameType,
        payload: []const u8,
        timeout_ns: ?u64,
        canceller: ?*const RpcCanceller,
    ) !RpcResult {
        var slot: PendingRpc = .{
            .want = want,
            .reply_channel = channel,
            .canceller = canceller,
        };

        // Fail fast if our owner was already cancelled (the surface is being
        // freed) so we don't queue behind another pane's in-flight by-type RPC
        // on `open_rpc_mutex` below just to be cancelled afterward.
        if (canceller) |c| if (c.isCancelled()) return error.Cancelled;

        // OPEN/ATTACH correlate by reply type (the agent picks the reply channel);
        // all other RPCs correlate by the request channel.
        const by_type = want == .opened or want == .attached;

        // Serialize by-type RPCs so the single `pending_opened`/`pending_attached`
        // slot is never contended. Rapid splits/tabs/windows on a remote machine
        // fire several OPENs concurrently (each pane on its own IO thread); they
        // now queue here and each completes in turn instead of the loser failing
        // with `error.RpcInFlight`. Acquired OUTSIDE `rpc_mutex` (see field doc).
        if (by_type) self.open_rpc_mutex.lock();
        defer if (by_type) self.open_rpc_mutex.unlock();

        self.rpc_mutex.lock();
        if (self.rpc_closed) {
            // Already shutting down: don't park (we'd hang — `failPendingRpcs` has
            // run). Fail fast under the same lock that gates registration.
            self.rpc_mutex.unlock();
            return error.ConnectionClosed;
        }
        if (by_type) {
            // `open_rpc_mutex` guarantees exclusivity here, so the slot is free.
            // (Assert rather than fail: a non-null slot would be a serialization
            // bug, not a recoverable in-flight collision.)
            assert(if (want == .opened) self.pending_opened == null else self.pending_attached == null);
            if (want == .opened) self.pending_opened = &slot else self.pending_attached = &slot;
        } else {
            if (self.pending.contains(channel)) {
                self.rpc_mutex.unlock();
                return error.RpcInFlight;
            }
            self.pending.put(self.alloc, channel, &slot) catch |e| {
                self.rpc_mutex.unlock();
                return e;
            };
        }
        self.rpc_mutex.unlock();
        // From here, always remove our slot before returning.
        defer {
            self.rpc_mutex.lock();
            if (by_type) {
                if (want == .opened) {
                    if (self.pending_opened == &slot) self.pending_opened = null;
                } else {
                    if (self.pending_attached == &slot) self.pending_attached = null;
                }
            } else {
                _ = self.pending.remove(channel);
            }
            self.rpc_mutex.unlock();
        }

        // Re-check cancellation now that the slot is registered. This closes the
        // register-vs-cancel race: `cancelRpcsFor` walks the slots under
        // `rpc_mutex`, so either it ran BEFORE our registration (then the flag —
        // stored before the walk — is visible here and we bail) or it runs after
        // (then it finds our slot and sets `done`). Either way we never park
        // uncancellably. The trailing `defer` removes the slot.
        if (canceller) |c| if (c.isCancelled()) return error.Cancelled;

        try self.writeControl(req, channel, payload);
        if (timeout_ns) |ns| {
            slot.done.timedWait(ns) catch {
                // The agent never replied in time (e.g. the remote command
                // failed to spawn, so no OPENED is coming). Fail rather than
                // wedge the caller. The trailing `defer` removes our slot under
                // `rpc_mutex`, so a reply that lands after this is dropped by
                // `deliverRpcReply` (no waiter found) — no use-after-free.
                return error.Timeout;
            };
        } else {
            slot.done.wait();
        }
        const owned = try slot.result; // []u8 (caller-owned) or a PendingError
        return .{ .payload = owned, .channel = slot.reply_channel };
    }

    /// Deliver a reply frame to a parked RPC caller. Called by the control reader's
    /// internal handler. Correlation order (§4.2):
    ///   1. By the reply's `Frame.channel` via `pending` (same-channel RPCs — the
    ///      loopback mock agents echo OPENED/ATTACHED on the request channel).
    ///   2. If that misses and the frame is OPENED/ATTACHED, by reply *type* via the
    ///      single by-type slot — this is the **channel-authoritative** real-agent
    ///      path: the agent minted its own session channel and replied on it. We
    ///      stamp the agent's channel into `slot.reply_channel` so the caller adopts
    ///      it as the pane's data channel.
    /// Dupes the payload into the slot (the caller frees it), or stores `WrongReply`
    /// on a type mismatch, then sets the slot's event. Returns true if it consumed a
    /// waiter.
    fn deliverRpcReply(self: *Connection, frame: protocol.Frame) bool {
        self.rpc_mutex.lock();
        const slot = self.pending.get(frame.channel) orelse blk: {
            // Channel miss: try the by-reply-type slot for the agent-authoritative
            // OPEN/ATTACH reply. The agent chose `frame.channel`; record it so the
            // caller registers its inbound ring on the right (agent) channel.
            const by_type: ?*PendingRpc = switch (frame.type) {
                .opened => self.pending_opened,
                .attached => self.pending_attached,
                else => null,
            };
            if (by_type) |s| {
                s.reply_channel = frame.channel;
                break :blk s;
            }
            self.rpc_mutex.unlock();
            return false;
        };
        // Fill the result under the lock so it is published before `done.set()`.
        if (frame.type != slot.want) {
            slot.result = error.WrongReply;
        } else if (self.alloc.dupe(u8, frame.payload)) |owned| {
            slot.result = owned;
        } else |_| {
            slot.result = error.MalformedReply;
        }
        const done = &slot.done;
        self.rpc_mutex.unlock();
        done.set();
        return true;
    }

    /// Fail every still-parked RPC caller registered with `canceller` with
    /// `error.Cancelled`, leaving all other panes' in-flight RPCs on this shared
    /// connection untouched. Safe to call from any thread (typically the GUI
    /// thread tearing down one surface). The canceller must call
    /// `canceller.cancel()` FIRST so an RPC racing its registration observes the
    /// flag (see `rpcCall`); we only set the result + event here — the parked
    /// caller removes its own slot.
    pub fn cancelRpcsFor(self: *Connection, canceller: *const RpcCanceller) void {
        self.rpc_mutex.lock();
        defer self.rpc_mutex.unlock();
        var it = self.pending.valueIterator();
        while (it.next()) |slot_ptr| cancelSlot(slot_ptr.*, canceller);
        if (self.pending_opened) |slot| cancelSlot(slot, canceller);
        if (self.pending_attached) |slot| cancelSlot(slot, canceller);
    }

    /// Cancel one parked slot if it belongs to `canceller`. Must be called under
    /// `rpc_mutex` (same publish discipline as `failPendingRpcs`).
    fn cancelSlot(slot: *PendingRpc, canceller: *const RpcCanceller) void {
        if (slot.canceller != canceller) return;
        if (slot.done.isSet()) return;
        slot.result = error.Cancelled;
        slot.done.set();
    }

    /// Fail every still-parked RPC caller with `ConnectionClosed` (called by
    /// `shutdown`). We only set the result + event; the caller removes its own slot.
    fn failPendingRpcs(self: *Connection) void {
        self.rpc_mutex.lock();
        // Latch closed so any RPC that registers AFTER this iteration fails fast in
        // `rpcCall` rather than parking forever (the register-vs-shutdown race).
        self.rpc_closed = true;
        var it = self.pending.valueIterator();
        while (it.next()) |slot_ptr| {
            const slot = slot_ptr.*;
            if (!slot.done.isSet()) {
                slot.result = error.ConnectionClosed;
                slot.done.set();
            }
        }
        // Also fail any parked OPEN/ATTACH waiter correlated by reply type.
        for ([_]?*PendingRpc{ self.pending_opened, self.pending_attached }) |maybe| {
            if (maybe) |slot| {
                if (!slot.done.isSet()) {
                    slot.result = error.ConnectionClosed;
                    slot.done.set();
                }
            }
        }
        self.rpc_mutex.unlock();
    }

    // --- Writer thread (MPSC drain) ------------------------------------------

    /// The single writer thread. Waits on the condition, drains the WHOLE queue
    /// under the lock into a local batch (matching `blocking_queue.zig`'s
    /// drain-everything pattern), releases the lock, then for each record assigns
    /// the next frame seq, encodes with the pinned transfer encoding, and writes
    /// it to its stream. Exits once `closed` and the queue is empty.
    fn writerLoop(self: *Connection) void {
        // Reusable encode buffer (cleared, not freed, between frames) and a local
        // batch we swap the shared queue into so we hold the lock minimally.
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);
        var batch: std.ArrayList(OutFrame) = .empty;
        defer batch.deinit(self.alloc);

        while (true) {
            self.write_mutex.lock();
            while (self.write_queue.items.len == 0 and !self.closed) {
                self.write_cond.wait(&self.write_mutex);
            }
            // Take the whole pending queue; swap so the shared one keeps capacity.
            const pending = self.write_queue;
            self.write_queue = batch;
            batch = pending;
            const done = self.closed and batch.items.len == 0;
            self.write_mutex.unlock();

            for (batch.items) |f| {
                // Assign seq at send time (single writer ⇒ seq order == wire order).
                const frame: protocol.Frame = .{
                    .type = f.ftype,
                    .channel = f.channel,
                    .seq = self.frame_seq.next(),
                    .payload = f.payload,
                };
                wire.clearRetainingCapacity();
                // Encode; on OOM there's nothing useful to do but drop the frame.
                protocol.writeFrame(self.alloc, self.encoding, frame, &wire) catch {
                    self.alloc.free(f.payload);
                    continue;
                };
                const stream = switch (f.stream) {
                    .control => self.control,
                    .data => self.data,
                };
                // A write error means the channel is dead; stop writing it but keep
                // draining/freeing so we don't leak. The readers will see EOF too.
                stream.writeAll(wire.items) catch {};
                self.alloc.free(f.payload);
            }
            batch.clearRetainingCapacity();

            if (done) break;
        }
    }

    // --- Reader threads -------------------------------------------------------

    /// The control reader. First does the handshake: read frames until the peer
    /// HELLO arrives, parse + negotiate it, store the result, and signal
    /// `handshake_done`. Then loops, dispatching each control frame to the handler.
    fn controlReaderLoop(self: *Connection) void {
        // Once this thread exits — for ANY reason (EOF, transport error, protocol
        // error, shutdown) — no RPC reply can ever be delivered again: replies
        // only arrive through this loop and it never restarts on a Connection
        // (reconnect dials a NEW Connection). So on the way out, fail every
        // parked RPC caller and latch `rpc_closed` so future callers fail fast
        // instead of waiting out their full timeout on a dead link. Idempotent
        // with the same call in `shutdown`.
        defer self.failPendingRpcs();

        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;

        // --- Handshake phase: consume frames until we get the peer HELLO. ---
        handshake: while (!self.handshake_done.isSet()) {
            // Drain any already-buffered frames before reading more.
            while (reader.next() catch {
                self.completeHandshake(error.Incompatible);
                break :handshake;
            }) |frame| {
                if (frame.type != .hello) continue; // ignore pre-HELLO noise
                self.completeHandshake(self.negotiatePeerHello(frame.payload));
                break :handshake;
            }
            const n = self.control.read(&scratch) catch 0;
            if (n == 0) {
                // EOF/closed before a HELLO: fail the handshake and stop.
                self.completeHandshake(error.Incompatible);
                return;
            }
            reader.push(scratch[0..n]) catch {
                self.completeHandshake(error.Incompatible);
                break :handshake;
            };
        }
        // If the handshake failed, there is nothing more to route.
        if (std.meta.isError(self.negotiated)) return;

        // --- Routing phase: internally handle health frames, then dispatch. ---
        while (true) {
            while (reader.next() catch {
                // A protocol error on the control lane is a transport failure, not a
                // clean shutdown: drive the FSM toward reconnecting (§5.2).
                self.signalTransportError();
                return;
            }) |frame| {
                // Internal handling first (PONG/PING/DETACHED, §6.4/§5.3); the user
                // handler is then ALWAYS invoked so callers can observe every frame
                // (the simpler, consistent policy — internal handling is additive).
                self.handleControlInternal(frame);
                if (self.ctrl_handler) |handler| {
                    handler(self.ctrl_handler_ctx, self, frame);
                }
            }
            const n = self.control.read(&scratch) catch {
                self.signalTransportError();
                return;
            };
            if (n == 0) {
                // EOF on the control lane. If this is a deliberate shutdown the FSM
                // change is irrelevant (we're tearing down); otherwise it signals a
                // dropped link (§5.2).
                self.signalTransportError();
                return; // EOF
            }
            reader.push(scratch[0..n]) catch {
                self.signalTransportError();
                return;
            };
        }
    }

    /// Internal control-frame handling done by the control reader BEFORE the user
    /// handler (increment 2 + 3). Consumes health/lifecycle semantics additively:
    ///   - `.opened`/`.attached` → wake the parked RPC caller for that channel (§4.2).
    ///   - `.pong`  → match by hb_seq, sample RTT, reset misses, FSM → connected.
    ///   - `.ping`  → reply with a `.pong` echoing the timestamp (bidirectional).
    ///   - `.detached` → record eviction (§5.3) and drive the FSM to DEAD.
    /// Other frame types are ignored here (the user handler still sees them).
    fn handleControlInternal(self: *Connection, frame: protocol.Frame) void {
        switch (frame.type) {
            .opened, .attached => {
                // Reply to an OPEN/ATTACH RPC: hand the payload to the parked caller
                // keyed by this channel id. If no caller is waiting (stale/duplicate
                // reply), it's dropped here; the user handler still observes it.
                _ = self.deliverRpcReply(frame);
            },
            .cwd => {
                // Reply to a GET_CWD RPC (§WP4). Same-channel correlation: the agent
                // echoes CWD on the request channel, so `deliverRpcReply` matches it
                // via the `pending` map keyed by `frame.channel`. Dropped if no
                // caller is parked (a late reply after a timeout).
                _ = self.deliverRpcReply(frame);
            },
            .proc_snapshot => {
                // Reply to a PROC_LIST RPC (§9.3 process view). Same-channel
                // correlation, exactly like CWD: the agent echoes PROC_SNAPSHOT on the
                // request channel. Dropped if no caller is parked (late reply).
                _ = self.deliverRpcReply(frame);
            },
            .sessions => {
                // Reply to a LIST_SESSIONS RPC (T10). Same-channel correlation, like
                // CWD/PROC_SNAPSHOT: the agent echoes SESSIONS on the request channel.
                // Dropped if no caller is parked (a late reply after a timeout).
                _ = self.deliverRpcReply(frame);
            },
            .proc_kill_result, .proc_spawn_result => {
                // Replies to PROC_KILL / PROC_SPAWN RPCs (§9.3 process control, inc
                // 4+5). Same-channel correlation, like PROC_SNAPSHOT. Dropped if no
                // caller is parked (a late reply after a timeout).
                _ = self.deliverRpcReply(frame);
            },
            .pong => {
                const hb = Heartbeat.decode(frame.payload) catch return;
                self.onPong(hb);
            },
            .ping => {
                const hb = Heartbeat.decode(frame.payload) catch return;
                // Reply echoing the sender's timestamp; stamp our clock as reply_ms.
                var buf: [Heartbeat.encoded_len]u8 = undefined;
                const reply: Heartbeat = .{
                    .hb_seq = hb.hb_seq,
                    .send_ms = hb.send_ms,
                    .reply_ms = self.clock.now(),
                };
                _ = reply.encodeInto(&buf);
                // Best-effort; a write failure surfaces via the reader's EOF path.
                self.writeControl(.pong, protocol.control_channel, &buf) catch {};
            },
            .exit => {
                // The remote child reaped: the agent frames `EXIT{code,runtime_ms}`
                // on the per-session control channel, ordered AFTER the session's
                // final DATA (§6.4). Signal it on the pane's inbound ring so the
                // Remote backend's drain, running on the pane's IO thread, turns it
                // into the surface `.child_exited` close — the SAME path local Exec
                // uses (`Exec.zig` → `Surface.childExited`), so remote panes honor
                // the same close / `wait-after-command` behavior. The signal is
                // delivered under the channel-table lock (`withChannel`) so the ring
                // can't be freed mid-call (§3.4 teardown invariant). An unknown
                // channel (late/duplicate EXIT after teardown, or hostile id) is
                // dropped silently — never a crash. Additive: the user `ctrl_handler`
                // still observes the frame afterward in `controlReaderLoop`.
                var parsed = protocol.parseJson(protocol.Exit, self.alloc, frame.payload) catch return;
                defer parsed.deinit();
                const ExitSig = struct {
                    code: i64,
                    runtime_ms: u64,
                    fn apply(self_sig: @This(), ch: *ring.Channel) void {
                        ch.signalExit(self_sig.code, self_sig.runtime_ms);
                    }
                };
                _ = self.channels.withChannel(
                    frame.channel,
                    ExitSig{ .code = parsed.value.code, .runtime_ms = parsed.value.runtime_ms },
                    ExitSig.apply,
                );
            },
            .detached => {
                // Server-initiated eviction / steal (§5.3): terminal DEAD.
                self.evicted.store(true, .monotonic);
                self.withLink(LinkState.onSessionGone);
            },
            .metrics => {
                // Pushed host-metrics sample (§9.3). Decode and hand the by-value
                // snapshot to the dedicated metrics handler if one is registered.
                // Decode failures are dropped silently (hostile-input discipline,
                // mirroring `.pong`). This is additive: the user `ctrl_handler`
                // still observes the frame afterward in `controlReaderLoop`.
                var parsed = protocol.parseJson(protocol.Metrics, self.alloc, frame.payload) catch return;
                defer parsed.deinit();
                // Read the slot under the same lock its publish is ordered by, so
                // we never observe a torn pointer vs. subscribe/unsubscribe.
                self.write_mutex.lock();
                const handler = self.metrics_handler;
                const ctx = self.metrics_handler_ctx;
                self.write_mutex.unlock();
                if (handler) |h| h(ctx, parsed.value.host);
            },
            else => {},
        }
    }

    /// Process a matched PONG: compute RTT, feed the estimator, publish latency, and
    /// drive the FSM back to connected (§6.4/§5.1). Ignores stale/duplicate PONGs
    /// (a hb_seq that isn't the outstanding one).
    fn onPong(self: *Connection, hb: Heartbeat) void {
        self.hb_mutex.lock();
        const matched = self.hb_outstanding and hb.hb_seq == self.hb_pending_seq;
        if (matched) {
            self.hb_outstanding = false;
            self.hb_missed = 0;
        }
        self.hb_mutex.unlock();
        if (!matched) return;

        // RTT = now − send_ms (the agent reflected send_ms back verbatim). Guard
        // against a non-monotonic / clock-skewed sample (now < send_ms → 0).
        const now = self.clock.now();
        const rtt_ms: f64 = if (now >= hb.send_ms) @floatFromInt(now - hb.send_ms) else 0;

        self.state_mutex.lock();
        self.rtt.addSample(rtt_ms);
        const srtt = self.rtt.srttMs();
        self.state_mutex.unlock();
        // Publish for the lock-free `latencyMs` reader (clamp 0→1 so 0 still means
        // "no sample yet" while a real ~0 ms RTT reports 1 ms).
        self.latency_ms.store(if (srtt == 0) 1 else srtt, .monotonic);

        // Any authentic packet → CONNECTED (§5.1).
        self.withLink(LinkState.onHeartbeatAck);
    }

    /// Drive the FSM on a non-deliberate reader exit / write failure (§5.2). Safe to
    /// call during shutdown too: the state move is harmless when we're tearing down.
    fn signalTransportError(self: *Connection) void {
        self.withLink(LinkState.onTransportError);
    }

    /// Parse a peer HELLO payload and negotiate it against our local HELLO.
    fn negotiatePeerHello(self: *Connection, payload: []const u8) protocol.ProtocolError!protocol.Negotiated {
        var parsed = protocol.Hello.parse(self.alloc, payload) catch return error.Incompatible;
        defer parsed.deinit();
        // Capture the peer's display hostname before the parse arena is freed.
        // Single write by the control reader, published to other threads by the
        // handshake gate (completeHandshake's set). Best-effort: OOM just leaves
        // it null, it is display-only.
        if (parsed.value.hostname) |h| {
            if (h.len > 0 and self.peer_hostname == null) {
                self.peer_hostname = self.alloc.dupeZ(u8, h) catch null;
            }
        }
        return protocol.negotiate(self.local_hello, parsed.value);
    }

    /// The peer's self-reported hostname (display-only), or null. Only valid
    /// after `waitHandshake` has returned successfully.
    pub fn peerHostname(self: *const Connection) ?[:0]const u8 {
        return self.peer_hostname;
    }

    /// Store the handshake outcome and wake `waitHandshake`. First writer wins so
    /// a racing `shutdown` doesn't clobber a real result.
    fn completeHandshake(self: *Connection, result: protocol.ProtocolError!protocol.Negotiated) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (self.handshake_done.isSet()) return;
        self.negotiated = result;
        self.handshake_done.set();
    }

    /// Route one inbound DATA chunk for `channel` into its ring, applying the §7.3
    /// sequence-anchored resync discard and §4.3 FLOW{pause} emission.
    ///
    /// Resync (§7.3): if the channel's pane has `resync_active` with a `discard_below`
    /// watermark `W`, we push only the bytes whose ABSOLUTE offset is `> W`. The chunk
    /// spans `[byte_offset, byte_offset + len)`:
    ///   - ends at/below `W` (`byte_offset + len <= W`) → drop the whole chunk;
    ///   - straddles `W` → drop the prefix, push the suffix `(W - byte_offset ..]`;
    ///   - starts above `W` → push whole (and we can disarm resync — watermark passed).
    /// This is byte-accurate, not whole-frame-approximate. We track no separate
    /// `applied_offset` beyond `discard_below` because the watermark fully determines
    /// the cut and the agent guarantees in-order, gap-free DATA after the snapshot.
    ///
    /// FLOW (§4.3): when the channel-table push reports `send_pause` (ring crossed
    /// high-water), emit one `FLOW{channel, pause}` on the control lane. FLOW{resume}
    /// is emitted by the pane's CONSUMER thread once it drains back under low-water
    /// (a later increment, in `termio.Remote`) — NOT here.
    fn routeInboundData(self: *Connection, channel: u128, byte_offset: u64, bytes: []const u8) void {
        var to_push = bytes;

        // Consult the per-channel resync watermark (separate lock from the table).
        self.panes_mutex.lock();
        if (self.panes.get(channel)) |pane| {
            if (pane.resync_active) {
                // §7.3: discard every byte whose ABSOLUTE offset is <= W; keep offset
                // > W. The first absolute offset we keep is `keep_from = W + 1`.
                const keep_from = pane.discard_below + 1;
                const chunk_end = byte_offset +% bytes.len; // exclusive
                if (chunk_end <= keep_from) {
                    // Last byte's offset (chunk_end-1) is still <= W: drop it all,
                    // stay armed for the next chunk.
                    self.panes_mutex.unlock();
                    return;
                } else if (byte_offset < keep_from) {
                    // Straddles: drop the prefix below `keep_from`, push the suffix.
                    const drop: usize = @intCast(keep_from - byte_offset);
                    to_push = bytes[drop..];
                    pane.resync_active = false; // watermark crossed
                } else {
                    // Starts at/above `keep_from`: keep whole, disarm.
                    pane.resync_active = false;
                }
            }
        }
        self.panes_mutex.unlock();

        // Route the (possibly trimmed) bytes; `.unknown` (stale/hostile channel) is
        // dropped. On a high-water crossing, emit a single FLOW{pause}.
        const res = self.channels.pushTo(channel, to_push);
        switch (res) {
            // `.unknown` (dropped) can no longer occur for a live-but-unregistered
            // channel: `pushTo` buffers those in the pre-registration buffer
            // (`.buffered`) and `register` flushes them (T06c). Both need no FLOW.
            .unknown, .buffered => {},
            .routed => |push| {
                if (push.send_pause) {
                    var buf: [protocol.Flow.encoded_len]u8 = undefined;
                    const flow: protocol.Flow = .{ .channel = channel, .op = .pause };
                    _ = flow.encodeInto(&buf);
                    // Best-effort: a dead link surfaces via the readers' EOF path.
                    self.writeControl(.flow, protocol.control_channel, &buf) catch {};
                }
            },
        }
    }

    /// The data reader. Loops read → push → drain. For each DATA frame, decode the
    /// payload and route the raw child bytes via `routeInboundData` (resync discard
    /// §7.3 + FLOW{pause} §4.3). An unknown channel id is dropped (§15 M3 — never
    /// crash). Non-DATA frames on the data stream are ignored. Exits on EOF/error.
    fn dataReaderLoop(self: *Connection) void {
        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;

        while (true) {
            while (reader.next() catch {
                self.signalTransportError();
                return;
            }) |frame| {
                if (frame.type != .data) continue; // ignore non-DATA on this lane
                const dp = protocol.DataPayload.decode(frame.payload) catch continue;
                self.routeInboundData(frame.channel, dp.byte_offset, dp.bytes);
            }
            const n = self.data.read(&scratch) catch {
                self.signalTransportError();
                return;
            };
            if (n == 0) {
                self.signalTransportError();
                return; // EOF
            }
            reader.push(scratch[0..n]) catch {
                self.signalTransportError();
                return;
            };
        }
    }

    // --- Heartbeat driver (increment 2, §6.4) --------------------------------

    /// The heartbeat thread. Waits for the handshake, then every `interval_ms`:
    ///   1. If a prior PING is still outstanding (no PONG arrived since), count it as
    ///      a missed interval and drive `LinkState.onHeartbeatMissed`.
    ///   2. Stamp and send a fresh PING (new hb_seq + send_ms) on the control lane.
    ///   3. Sleep on `hb_wake.timedWait(interval)` so `shutdown` wakes it immediately.
    /// Exits when `closed` (woken via `hb_wake`).
    fn heartbeatLoop(self: *Connection) void {
        // Don't heartbeat until the link is actually up. `waitHandshake` is unblocked
        // by `shutdown` too (with an error), so this also exits cleanly on an early
        // teardown.
        _ = self.waitHandshake() catch {
            return; // handshake failed or we're shutting down: nothing to ping.
        };

        const interval_ns = self.heartbeat_interval_ms *| std.time.ns_per_ms;
        while (true) {
            if (self.isClosed()) return;

            // (1) Account for an unanswered prior PING as a missed interval.
            self.hb_mutex.lock();
            if (self.hb_outstanding) {
                self.hb_missed +|= 1;
            }
            const missed = self.hb_missed;
            self.hb_mutex.unlock();
            if (missed > 0) {
                // Drive the FSM with the running missed count (§5.1 thresholds).
                self.onMissed(missed);
            }

            // (2) Stamp and send a fresh PING. hb_seq is OWNED here (not frame_seq).
            const send_ms = self.clock.now();
            self.hb_mutex.lock();
            self.hb_seq +%= 1;
            const seq = self.hb_seq;
            self.hb_pending_seq = seq;
            self.hb_pending_send_ms = send_ms;
            self.hb_outstanding = true;
            self.hb_mutex.unlock();

            var buf: [Heartbeat.encoded_len]u8 = undefined;
            const ping: Heartbeat = .{ .hb_seq = seq, .send_ms = send_ms };
            _ = ping.encodeInto(&buf);
            // A write failure here is observed by the readers' EOF/error path which
            // drives the FSM; the heartbeat just keeps its bookkeeping consistent.
            self.writeControl(.ping, protocol.control_channel, &buf) catch {};

            // (3) Sleep until the next tick or an immediate shutdown wake.
            self.hb_wake.timedWait(interval_ns) catch {
                // Timed out → next interval. (A set event means shutdown: loop top
                // sees `closed` and exits.)
                continue;
            };
            // Event was set (shutdown). Exit promptly.
            return;
        }
    }

    /// Apply a running missed-count to the FSM via the serialized transition path.
    /// Wrapped because `withLink` needs a `fn(*LinkState)` and we must close over the
    /// count — a tiny per-call closure struct does that.
    fn onMissed(self: *Connection, missed: u32) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const old = self.link.state;
        self.link.onHeartbeatMissed(missed);
        const new = self.link.state;
        if (new != old) {
            if (self.state_handler) |h| h(self.state_handler_ctx, self, old, new);
        }
    }

    /// Lock-free-ish read of the closed flag (under `write_mutex`, like the writer).
    fn isClosed(self: *Connection) bool {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        return self.closed;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// All three encodings, iterated by the transport tests.
const all_encodings = [_]protocol.TransferEncoding{ .raw, .cobs, .base64 };

// --- ByteFifo: a thread-safe blocking byte queue with EOF ---------------------

/// A thread-safe blocking byte pipe. `write` appends and signals; `read` blocks
/// until data is available or the pipe is closed (returns 0 on closed+empty);
/// `close` sets EOF and broadcasts. Models one direction of an SSH channel.
const ByteFifo = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,
    closed: bool = false,
    alloc: Allocator,

    fn init(alloc: Allocator) ByteFifo {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *ByteFifo) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    fn write(self: *ByteFifo, bytes: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        try self.buf.appendSlice(self.alloc, bytes);
        self.cond.signal();
        return bytes.len;
    }

    fn read(self: *ByteFifo, dst: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.head == self.buf.items.len and !self.closed) {
            self.cond.wait(&self.mutex);
        }
        const avail = self.buf.items[self.head..];
        if (avail.len == 0) return 0; // closed + drained → EOF
        const n = @min(avail.len, dst.len);
        @memcpy(dst[0..n], avail[0..n]);
        self.head += n;
        // Compact once fully drained to keep memory bounded.
        if (self.head == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
        }
        return n;
    }

    fn close(self: *ByteFifo) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

// --- Loopback: a client Stream + agent Stream over two ByteFifos --------------

/// A bidirectional in-memory pipe pair. `client_to_agent` carries bytes the client
/// writes (and the agent reads); `agent_to_client` the reverse. `clientStream`/
/// `agentStream` hand out the two `Stream` views.
const Loopback = struct {
    client_to_agent: ByteFifo,
    agent_to_client: ByteFifo,

    fn init(alloc: Allocator) Loopback {
        return .{
            .client_to_agent = ByteFifo.init(alloc),
            .agent_to_client = ByteFifo.init(alloc),
        };
    }

    fn deinit(self: *Loopback) void {
        self.client_to_agent.deinit();
        self.agent_to_client.deinit();
    }

    /// The client's view: writes go to `client_to_agent`, reads from `agent_to_client`.
    fn clientStream(self: *Loopback) Stream {
        return .{ .ctx = self, .vtable = &client_vtable };
    }

    /// The agent's view: writes go to `agent_to_client`, reads from `client_to_agent`.
    fn agentStream(self: *Loopback) Stream {
        return .{ .ctx = self, .vtable = &agent_vtable };
    }

    const client_vtable: Stream.VTable = .{
        .read = clientRead,
        .write = clientWrite,
        .close = closeBoth,
    };
    const agent_vtable: Stream.VTable = .{
        .read = agentRead,
        .write = agentWrite,
        .close = closeBoth,
    };

    fn clientRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.agent_to_client.read(buf);
    }
    fn clientWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.client_to_agent.write(bytes);
    }
    fn agentRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.client_to_agent.read(buf);
    }
    fn agentWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.agent_to_client.write(bytes);
    }
    /// Closing either end tears down both directions (EOFs the reader threads).
    fn closeBoth(ctx: *anyopaque) void {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        self.client_to_agent.close();
        self.agent_to_client.close();
    }
};

/// A mock agent's stream-side `protocol.Reader` + writer helpers, sharing the
/// pinned encoding. Reads frames from a stream blocking until one is available.
const MockAgent = struct {
    stream: Stream,
    encoding: protocol.TransferEncoding,
    reader: protocol.Reader,
    scratch: [read_buf_size]u8 = undefined,
    alloc: Allocator,

    fn init(alloc: Allocator, stream: Stream, encoding: protocol.TransferEncoding) MockAgent {
        return .{
            .stream = stream,
            .encoding = encoding,
            .reader = protocol.Reader.init(alloc, encoding),
            .alloc = alloc,
        };
    }

    fn deinit(self: *MockAgent) void {
        self.reader.deinit();
    }

    /// Block until one complete frame arrives; null on EOF before a full frame.
    /// The returned `payload` borrows the reader buffer (valid until next call).
    fn nextFrame(self: *MockAgent) !?protocol.Frame {
        while (true) {
            if (try self.reader.next()) |frame| return frame;
            const n = try self.stream.read(&self.scratch);
            if (n == 0) return null;
            try self.reader.push(self.scratch[0..n]);
        }
    }

    /// Encode and send a frame (seq is arbitrary for the agent side).
    fn sendFrame(self: *MockAgent, frame: protocol.Frame) !void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);
        try protocol.writeFrame(self.alloc, self.encoding, frame, &wire);
        try self.stream.writeAll(wire.items);
    }

    /// Send a JSON control frame (OPENED/ATTACHED/...) on `channel`.
    fn sendJson(self: *MockAgent, ftype: protocol.FrameType, channel: u128, value: anytype) !void {
        const json = try protocol.encodeJson(self.alloc, value);
        defer self.alloc.free(json);
        try self.sendFrame(.{ .type = ftype, .channel = channel, .seq = 0, .payload = json });
    }

    /// Read the client HELLO and reply with an agent HELLO in the same encoding.
    /// Returns the parsed client HELLO's encoding for assertions.
    fn handshake(self: *MockAgent) !protocol.TransferEncoding {
        const frame = (try self.nextFrame()) orelse return error.NoHello;
        try testing.expectEqual(protocol.FrameType.hello, frame.type);
        var parsed = try protocol.Hello.parse(self.alloc, frame.payload);
        defer parsed.deinit();
        const enc = parsed.value.transfer_encoding;

        const reply: protocol.Hello = .{ .transfer_encoding = enc };
        const json = try reply.encode(self.alloc);
        defer self.alloc.free(json);
        try self.sendFrame(.{
            .type = .hello,
            .channel = protocol.control_channel,
            .seq = 0,
            .payload = json,
        });
        return enc;
    }
};

// --- Test 1: handshake --------------------------------------------------------

const HandshakeAgentCtx = struct {
    agent: *MockAgent,
    saw_encoding: protocol.TransferEncoding = undefined,
    err: ?anyerror = null,
    fn run(self: *HandshakeAgentCtx) void {
        self.saw_encoding = self.agent.handshake() catch |e| {
            self.err = e;
            return;
        };
    }
};

test "handshake: client negotiates encoding/version, agent sees client HELLO" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var ctrl_lb = Loopback.init(alloc);
        defer ctrl_lb.deinit();
        var data_lb = Loopback.init(alloc);
        defer data_lb.deinit();

        const hello: protocol.Hello = .{ .transfer_encoding = enc };
        const conn = try Connection.create(
            alloc,
            ctrl_lb.clientStream(),
            data_lb.clientStream(),
            hello,
        );
        defer conn.destroy(alloc);

        var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), enc);
        defer agent.deinit();
        var actx: HandshakeAgentCtx = .{ .agent = &agent };
        const ath = try std.Thread.spawn(.{}, HandshakeAgentCtx.run, .{&actx});

        try conn.start();
        const neg = try conn.waitHandshake();
        ath.join();

        try testing.expectEqual(enc, neg.transfer_encoding);
        try testing.expectEqual(protocol.proto_version, neg.proto_version);
        try testing.expect(actx.err == null);
        try testing.expectEqual(enc, actx.saw_encoding);

        conn.shutdown();
    }
}

// --- Test 2: inbound DATA routing --------------------------------------------

const InboundAgentCtx = struct {
    agent: *MockAgent,
    channel: u128,
    err: ?anyerror = null,
    fn run(self: *InboundAgentCtx) void {
        self.body() catch |e| {
            self.err = e;
        };
    }
    fn body(self: *InboundAgentCtx) !void {
        _ = try self.agent.handshake();
    }
};

/// Send a DATA frame on the agent's data stream.
fn agentSendData(agent: *MockAgent, channel: u128, byte_offset: u64, bytes: []const u8) !void {
    const payload = try agent.alloc.alloc(u8, protocol.DataPayload.encodedLen(bytes.len));
    defer agent.alloc.free(payload);
    const dp: protocol.DataPayload = .{ .byte_offset = byte_offset, .bytes = bytes };
    _ = dp.encodeInto(payload);
    try agent.sendFrame(.{ .type = .data, .channel = channel, .seq = 0, .payload = payload });
}

/// Drain a channel's ring until `want` bytes have been collected into `out`.
fn drainChannel(ch: *ring.Channel, out: *std.ArrayList(u8), alloc: Allocator, want: usize) !void {
    var dst: [256]u8 = undefined;
    var spins: usize = 0;
    while (out.items.len < want) {
        const r = ch.pop(&dst);
        if (r.read == 0) {
            spins += 1;
            if (spins > 100_000) return error.Timeout;
            std.Thread.yield() catch {};
            continue;
        }
        spins = 0;
        try out.appendSlice(alloc, dst[0..r.read]);
    }
}

test "inbound DATA routing: bytes land in the right channel; unknown is dropped" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var ctrl_lb = Loopback.init(alloc);
        defer ctrl_lb.deinit();
        var data_lb = Loopback.init(alloc);
        defer data_lb.deinit();

        const conn = try Connection.create(
            alloc,
            ctrl_lb.clientStream(),
            data_lb.clientStream(),
            .{ .transfer_encoding = enc },
        );
        defer conn.destroy(alloc);

        const ch_id: u128 = 0x1234_5678;
        var ch = try ring.Channel.init(alloc, ch_id, .{ .capacity = 4096 });
        defer ch.deinit(alloc);
        try conn.registerChannel(&ch);

        // Agent handshakes on control, then sends DATA on the data stream.
        var ctrl_agent = MockAgent.init(alloc, ctrl_lb.agentStream(), enc);
        defer ctrl_agent.deinit();
        var ictx: InboundAgentCtx = .{ .agent = &ctrl_agent, .channel = ch_id };
        const ath = try std.Thread.spawn(.{}, InboundAgentCtx.run, .{&ictx});

        try conn.start();
        _ = try conn.waitHandshake();
        ath.join();
        try testing.expect(ictx.err == null);

        var data_agent = MockAgent.init(alloc, data_lb.agentStream(), enc);
        defer data_agent.deinit();

        // One frame to the known channel.
        try agentSendData(&data_agent, ch_id, 0, "hello world");
        // A frame to an UNKNOWN channel — must be dropped, never crash.
        try agentSendData(&data_agent, 0xDEAD_BEEF, 0, "ignored");
        // Several more frames to the known channel; verify concatenation.
        try agentSendData(&data_agent, ch_id, 11, " more");
        try agentSendData(&data_agent, ch_id, 16, " bytes");

        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(alloc);
        try drainChannel(&ch, &got, alloc, "hello world more bytes".len);
        try testing.expectEqualStrings("hello world more bytes", got.items);

        conn.shutdown();
        // Deregister only after shutdown (data reader joined) so the ring is safe.
        conn.deregisterChannel(ch_id);
    }
}

// --- Test 3: outbound DATA ----------------------------------------------------

const OutboundAgentCtx = struct {
    ctrl_agent: *MockAgent,
    data_agent: *MockAgent,
    alloc: Allocator,
    got_channel: u128 = 0,
    got_offset: u64 = 0,
    got_bytes: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
    fn run(self: *OutboundAgentCtx) void {
        self.body() catch |e| {
            self.err = e;
        };
    }
    fn body(self: *OutboundAgentCtx) !void {
        _ = try self.ctrl_agent.handshake();
        // Read one DATA frame off the data stream.
        const frame = (try self.data_agent.nextFrame()) orelse return error.NoData;
        try testing.expectEqual(protocol.FrameType.data, frame.type);
        const dp = try protocol.DataPayload.decode(frame.payload);
        self.got_channel = frame.channel;
        self.got_offset = dp.byte_offset;
        try self.got_bytes.appendSlice(self.alloc, dp.bytes);
    }
};

test "outbound DATA: writeData reaches the agent's data stream verbatim" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var ctrl_lb = Loopback.init(alloc);
        defer ctrl_lb.deinit();
        var data_lb = Loopback.init(alloc);
        defer data_lb.deinit();

        const conn = try Connection.create(
            alloc,
            ctrl_lb.clientStream(),
            data_lb.clientStream(),
            .{ .transfer_encoding = enc },
        );
        defer conn.destroy(alloc);

        var ctrl_agent = MockAgent.init(alloc, ctrl_lb.agentStream(), enc);
        defer ctrl_agent.deinit();
        var data_agent = MockAgent.init(alloc, data_lb.agentStream(), enc);
        defer data_agent.deinit();

        var octx: OutboundAgentCtx = .{
            .ctrl_agent = &ctrl_agent,
            .data_agent = &data_agent,
            .alloc = alloc,
        };
        defer octx.got_bytes.deinit(alloc);
        const ath = try std.Thread.spawn(.{}, OutboundAgentCtx.run, .{&octx});

        try conn.start();
        _ = try conn.waitHandshake();

        const ch_id: u128 = 0xCAFE;
        try conn.writeData(ch_id, 4242, "keystrokes");

        ath.join();
        try testing.expect(octx.err == null);
        try testing.expectEqual(ch_id, octx.got_channel);
        try testing.expectEqual(@as(u64, 4242), octx.got_offset);
        try testing.expectEqualStrings("keystrokes", octx.got_bytes.items);

        conn.shutdown();
    }
}

// --- Test 4: control frame dispatch ------------------------------------------

const CtrlDispatchAgentCtx = struct {
    agent: *MockAgent,
    payload: []const u8,
    err: ?anyerror = null,
    fn run(self: *CtrlDispatchAgentCtx) void {
        self.body() catch |e| {
            self.err = e;
        };
    }
    fn body(self: *CtrlDispatchAgentCtx) !void {
        _ = try self.agent.handshake();
        try self.agent.sendFrame(.{
            .type = .meta,
            .channel = protocol.control_channel,
            .seq = 1,
            .payload = self.payload,
        });
    }
};

const CtrlSink = struct {
    alloc: Allocator,
    got_type: ?protocol.FrameType = null,
    got_payload: std.ArrayList(u8) = .empty,
    done: std.Thread.ResetEvent = .{},

    fn handler(ctx: *anyopaque, _: *Connection, frame: protocol.Frame) void {
        const self: *CtrlSink = @ptrCast(@alignCast(ctx));
        if (self.got_type != null) return; // capture only the first
        self.got_type = frame.type;
        // Copy the payload out inside the call — it borrows the reader buffer.
        self.got_payload.appendSlice(self.alloc, frame.payload) catch {};
        self.done.set();
    }
};

test "control dispatch: agent control frame invokes the handler with payload" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var ctrl_lb = Loopback.init(alloc);
        defer ctrl_lb.deinit();
        var data_lb = Loopback.init(alloc);
        defer data_lb.deinit();

        const conn = try Connection.create(
            alloc,
            ctrl_lb.clientStream(),
            data_lb.clientStream(),
            .{ .transfer_encoding = enc },
        );
        defer conn.destroy(alloc);

        var sink: CtrlSink = .{ .alloc = alloc };
        defer sink.got_payload.deinit(alloc);
        conn.setControlHandler(&sink, CtrlSink.handler);

        const json = "{\"title\":\"hi\"}";
        var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), enc);
        defer agent.deinit();
        var cctx: CtrlDispatchAgentCtx = .{ .agent = &agent, .payload = json };
        const ath = try std.Thread.spawn(.{}, CtrlDispatchAgentCtx.run, .{&cctx});

        try conn.start();
        _ = try conn.waitHandshake();

        // Wait for the handler to fire (deterministic; no sleep-as-sync).
        sink.done.wait();
        ath.join();
        try testing.expect(cctx.err == null);
        try testing.expectEqual(protocol.FrameType.meta, sink.got_type.?);
        try testing.expectEqualStrings(json, sink.got_payload.items);

        conn.shutdown();
    }
}

// --- Test 5: clean shutdown (no deadlock, no leaks) --------------------------

test "clean shutdown joins all threads without hanging" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var ctrl_lb = Loopback.init(alloc);
        defer ctrl_lb.deinit();
        var data_lb = Loopback.init(alloc);
        defer data_lb.deinit();

        const conn = try Connection.create(
            alloc,
            ctrl_lb.clientStream(),
            data_lb.clientStream(),
            .{ .transfer_encoding = enc },
        );
        defer conn.destroy(alloc);

        var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), enc);
        defer agent.deinit();
        var actx: HandshakeAgentCtx = .{ .agent = &agent };
        const ath = try std.Thread.spawn(.{}, HandshakeAgentCtx.run, .{&actx});

        try conn.start();
        _ = try conn.waitHandshake();
        ath.join();

        // Enqueue a couple of frames that may or may not flush before shutdown;
        // shutdown must free any unsent payloads under the testing allocator.
        try conn.writeData(0x1, 0, "a");
        try conn.writeControl(.ping, protocol.control_channel, "");

        conn.shutdown();
        // Idempotent: a second shutdown is a no-op and must not hang or double-free.
        conn.shutdown();
    }
}

// Shutdown before the handshake ever completes must not hang `waitHandshake`.
test "shutdown before handshake unblocks waiters" {
    const alloc = testing.allocator;
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    const conn = try Connection.create(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
    );
    defer conn.destroy(alloc);

    // No agent replies, so the handshake never completes on its own.
    try conn.start();
    conn.shutdown();
    try testing.expectError(error.Incompatible, conn.waitHandshake());
}

// =============================================================================
// Increment 2 tests: RTT estimator, link-state FSM, heartbeat/health integration
// =============================================================================

// --- RttEstimator (RFC 6298) -------------------------------------------------

test "RttEstimator: RFC 6298 seed + EWMA convergence and health buckets" {
    var est: RttEstimator = .{};
    try testing.expectEqual(RttEstimator.Health.unknown, est.health());
    try testing.expectEqual(@as(u32, 0), est.srttMs());

    // First sample R=100 seeds SRTT=R, RTTVAR=R/2 (RFC 6298 §2.2).
    est.addSample(100);
    try testing.expectEqual(@as(u32, 100), est.srttMs());
    try testing.expectApproxEqAbs(@as(f64, 50), est.rttvar, 1e-9);
    // RTO = SRTT + K·RTTVAR = 100 + 4·50 = 300.
    try testing.expectEqual(@as(u32, 300), est.rtoMs());

    // Second sample R=100 (no change): RTTVAR ← 0.75·50 + 0.25·0 = 37.5;
    // SRTT ← 0.875·100 + 0.125·100 = 100.
    est.addSample(100);
    try testing.expectApproxEqAbs(@as(f64, 100), est.srtt, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 37.5), est.rttvar, 1e-9);

    // A spike to R=200: RTTVAR ← 0.75·37.5 + 0.25·|100−200| = 28.125 + 25 = 53.125;
    // SRTT ← 0.875·100 + 0.125·200 = 112.5.
    est.addSample(200);
    try testing.expectApproxEqAbs(@as(f64, 112.5), est.srtt, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 53.125), est.rttvar, 1e-9);

    // SRTT 112.5 ms is in the yellow band (80 ≤ x < 250).
    try testing.expectEqual(RttEstimator.Health.yellow, est.health());

    // Feed many low samples; SRTT converges toward green (<80).
    var i: usize = 0;
    while (i < 50) : (i += 1) est.addSample(10);
    try testing.expect(est.srtt < RttEstimator.green_max_ms);
    try testing.expectEqual(RttEstimator.Health.green, est.health());

    // Feed many high samples; SRTT climbs into red (≥250).
    i = 0;
    while (i < 100) : (i += 1) est.addSample(400);
    try testing.expect(est.srtt >= 250);
    try testing.expectEqual(RttEstimator.Health.red, est.health());
}

// --- LinkState FSM -----------------------------------------------------------

test "LinkState: full transition table" {
    var prng = std.Random.DefaultPrng.init(1);
    const S = LinkState.State;

    // connected → degraded at 2 missed, → reconnecting at 3 missed.
    {
        var ls = LinkState.init(prng.random());
        try testing.expectEqual(S.connected, ls.state);
        ls.onHeartbeatMissed(1);
        try testing.expectEqual(S.connected, ls.state); // 1 miss: still connected
        ls.onHeartbeatMissed(2);
        try testing.expectEqual(S.degraded, ls.state);
        ls.onHeartbeatMissed(3);
        try testing.expectEqual(S.reconnecting, ls.state);
        // Any authentic packet → connected, resets attempt.
        _ = ls.nextBackoffMs();
        ls.onHeartbeatAck();
        try testing.expectEqual(S.connected, ls.state);
        try testing.expectEqual(@as(u32, 0), ls.attempt);
    }

    // degraded → connected on ack.
    {
        var ls = LinkState.init(prng.random());
        ls.onHeartbeatMissed(2);
        try testing.expectEqual(S.degraded, ls.state);
        ls.onHeartbeatAck();
        try testing.expectEqual(S.connected, ls.state);
    }

    // transport error from any live state → reconnecting.
    {
        var ls = LinkState.init(prng.random());
        ls.onTransportError();
        try testing.expectEqual(S.reconnecting, ls.state);
        ls = LinkState.init(prng.random());
        ls.onHeartbeatMissed(2); // degraded
        ls.onTransportError();
        try testing.expectEqual(S.reconnecting, ls.state);
    }

    // reconnecting → reattaching → connected (resync done).
    {
        var ls = LinkState.init(prng.random());
        ls.onTransportError();
        ls.markReattaching();
        try testing.expectEqual(S.reattaching, ls.state);
        ls.onResyncDone();
        try testing.expectEqual(S.connected, ls.state);
        try testing.expectEqual(@as(u32, 0), ls.attempt);
    }

    // session gone / eviction → dead, and dead is terminal.
    {
        var ls = LinkState.init(prng.random());
        ls.onSessionGone();
        try testing.expectEqual(S.dead, ls.state);
        ls.onHeartbeatAck(); // ignored once dead
        try testing.expectEqual(S.dead, ls.state);
        ls.onHeartbeatMissed(5);
        try testing.expectEqual(S.dead, ls.state);
        ls.onTransportError();
        try testing.expectEqual(S.dead, ls.state);
    }

    // A still-missing tick must not drag reconnecting back to degraded.
    {
        var ls = LinkState.init(prng.random());
        ls.onHeartbeatMissed(3); // reconnecting
        ls.onHeartbeatMissed(2); // still missing — stays reconnecting
        try testing.expectEqual(S.reconnecting, ls.state);
    }
}

test "LinkState: full-jitter backoff grows, caps, and resets (fixed seed)" {
    var prng = std.Random.DefaultPrng.init(0xABCD);
    var ls = LinkState.init(prng.random());

    // Every delay must lie within [0, capped ceiling]. Track the max we see at each
    // attempt; the ceiling grows geometrically until it pins at the cap.
    var max_seen: u64 = 0;
    var attempt: u32 = 0;
    while (attempt < 20) : (attempt += 1) {
        const expected_shift: u6 = @intCast(@min(attempt, 40));
        const raw = LinkState.backoff_base_ms *| (@as(u64, 1) << expected_shift);
        const ceiling = @min(raw, LinkState.backoff_cap_ms);
        const d = ls.nextBackoffMs();
        try testing.expect(d <= ceiling);
        if (d > max_seen) max_seen = d;
    }
    // Once attempts are large the ceiling is the cap; no delay ever exceeds it.
    try testing.expect(max_seen <= LinkState.backoff_cap_ms);
    // Attempt counter advanced once per call.
    try testing.expectEqual(@as(u32, 20), ls.attempt);
    try testing.expect(ls.attemptsExhausted());

    // A success resets the schedule: the next ceiling is the base again.
    ls.onHeartbeatAck();
    try testing.expectEqual(@as(u32, 0), ls.attempt);
    const d0 = ls.nextBackoffMs();
    try testing.expect(d0 <= LinkState.backoff_base_ms); // attempt 0 ceiling == base
    try testing.expect(!ls.attemptsExhausted());

    // Demonstrate growth: collect the ceiling-bound at low attempts is monotonic.
    var ls2 = LinkState.init(prng.random());
    var prev_ceiling: u64 = 0;
    var a: u32 = 0;
    while (a < 6) : (a += 1) {
        const raw = LinkState.backoff_base_ms *| (@as(u64, 1) << @as(u6, @intCast(a)));
        const ceiling = @min(raw, LinkState.backoff_cap_ms);
        try testing.expect(ceiling >= prev_ceiling);
        prev_ceiling = ceiling;
        _ = ls2.nextBackoffMs();
    }
}

// --- Integration: a heartbeat-aware mock agent over the loopback -------------

/// A deterministic, injectable millisecond clock for the integration tests. Each
/// `advance` bumps the value; `Clock` reads it lock-free under an atomic.
const FakeClock = struct {
    now_ms: std.atomic.Value(u64) = .{ .raw = 1000 },

    fn clock(self: *FakeClock) Clock {
        return .{ .ctx = self, .nowMs = nowMs };
    }
    fn nowMs(ctx: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ctx));
        return self.now_ms.load(.monotonic);
    }
    fn advance(self: *FakeClock, by: u64) void {
        _ = self.now_ms.fetchAdd(by, .monotonic);
    }
};

/// An agent thread that handshakes, then services control frames: by default it
/// replies to each PING with a matching PONG (so the client computes RTT and stays
/// CONNECTED). It can be told to stop replying, to send a DETACHED, or to close.
const HealthAgentCtx = struct {
    agent: *MockAgent,
    /// When false, PINGs are read but NOT answered (drives missed acks).
    reply_to_pings: std.atomic.Value(bool) = .{ .raw = true },
    /// When set, the agent sends a DETACHED then keeps servicing.
    send_detached: std.atomic.Value(bool) = .{ .raw = false },
    detached_sent: std.Thread.ResetEvent = .{},
    /// Count of PONGs we've sent (observable by the test).
    pongs_sent: std.atomic.Value(u32) = .{ .raw = 0 },
    /// Optional reply RTT to bake into the echoed PONG by advancing a shared clock.
    err: ?anyerror = null,

    fn run(self: *HealthAgentCtx) void {
        self.body() catch |e| {
            // EOF on shutdown surfaces as a benign error; only record real ones.
            self.err = e;
        };
    }
    fn body(self: *HealthAgentCtx) !void {
        _ = try self.agent.handshake();
        while (true) {
            if (self.send_detached.swap(false, .monotonic)) {
                try self.agent.sendFrame(.{
                    .type = .detached,
                    .channel = protocol.control_channel,
                    .seq = 0,
                    .payload = "",
                });
                self.detached_sent.set();
            }
            const frame = (try self.agent.nextFrame()) orelse return; // EOF: done
            switch (frame.type) {
                .ping => {
                    if (!self.reply_to_pings.load(.monotonic)) continue;
                    // Echo the PING's heartbeat payload back as a PONG verbatim.
                    var buf: [Heartbeat.encoded_len]u8 = undefined;
                    const hb = try Heartbeat.decode(frame.payload);
                    _ = hb.encodeInto(&buf);
                    try self.agent.sendFrame(.{
                        .type = .pong,
                        .channel = protocol.control_channel,
                        .seq = 0,
                        .payload = &buf,
                    });
                    _ = self.pongs_sent.fetchAdd(1, .monotonic);
                },
                else => {},
            }
        }
    }
};

/// Spin until `cond()` is true or we exceed a generous spin budget (deterministic;
/// no fixed sleeps — the agent thread makes progress on its own).
fn spinUntil(comptime ctx_t: type, ctx: *ctx_t, cond: *const fn (*ctx_t) bool) !void {
    var spins: usize = 0;
    while (!cond(ctx)) {
        spins += 1;
        if (spins > 5_000_000) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

const StateRec = struct {
    conn: *Connection,
    last_old: std.atomic.Value(u32) = .{ .raw = 0 },
    last_new: std.atomic.Value(u32) = .{ .raw = 0 },
    transitions: std.atomic.Value(u32) = .{ .raw = 0 },
    saw_dead: std.atomic.Value(bool) = .{ .raw = false },
    saw_reconnecting: std.atomic.Value(bool) = .{ .raw = false },

    fn handler(ctx: *anyopaque, _: *Connection, old: LinkState.State, new: LinkState.State) void {
        const self: *StateRec = @ptrCast(@alignCast(ctx));
        self.last_old.store(@intFromEnum(old), .monotonic);
        self.last_new.store(@intFromEnum(new), .monotonic);
        _ = self.transitions.fetchAdd(1, .monotonic);
        if (new == .dead) self.saw_dead.store(true, .monotonic);
        if (new == .reconnecting) self.saw_reconnecting.store(true, .monotonic);
    }
};

test "heartbeat integration: PONG → latency computed, link stays connected" {
    const alloc = testing.allocator;
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    var fake = FakeClock{};
    const conn = try Connection.createOpts(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
        .{ .clock = fake.clock(), .heartbeat_interval_ms = 2 }, // tiny interval
    );
    defer conn.destroy(alloc);

    var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer agent.deinit();
    var hctx = HealthAgentCtx{ .agent = &agent };
    const ath = try std.Thread.spawn(.{}, HealthAgentCtx.run, .{&hctx});

    try conn.start();
    _ = try conn.waitHandshake();

    // Wait until at least one PONG has been answered.
    try spinUntil(HealthAgentCtx, &hctx, struct {
        fn f(c: *HealthAgentCtx) bool {
            return c.pongs_sent.load(.monotonic) >= 1;
        }
    }.f);

    // The client should have a latency sample and be CONNECTED.
    try spinUntil(Connection, conn, struct {
        fn f(c: *Connection) bool {
            return c.latencyMs() != null;
        }
    }.f);
    try testing.expectEqual(LinkState.State.connected, conn.state());
    try testing.expect(conn.latencyMs() != null);

    conn.shutdown();
    ath.join();
}

test "heartbeat integration: silent agent → missed acks → degraded → reconnecting" {
    const alloc = testing.allocator;
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    var fake = FakeClock{};
    const conn = try Connection.createOpts(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
        .{ .clock = fake.clock(), .heartbeat_interval_ms = 1 },
    );
    defer conn.destroy(alloc);

    var rec = StateRec{ .conn = conn };
    conn.setStateHandler(&rec, StateRec.handler);

    var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer agent.deinit();
    // Agent reads PINGs but never answers → the client racks up missed acks.
    var hctx = HealthAgentCtx{ .agent = &agent };
    hctx.reply_to_pings.store(false, .monotonic);
    const ath = try std.Thread.spawn(.{}, HealthAgentCtx.run, .{&hctx});

    try conn.start();
    _ = try conn.waitHandshake();

    // With a 1 ms interval and no replies, the missed count climbs; the FSM passes
    // through degraded (2 missed) and reaches reconnecting (3 missed).
    try spinUntil(StateRec, &rec, struct {
        fn f(c: *StateRec) bool {
            return c.saw_reconnecting.load(.monotonic);
        }
    }.f);
    try testing.expect(rec.saw_reconnecting.load(.monotonic));

    conn.shutdown();
    ath.join();
}

test "DETACHED steal: client is evicted and the FSM goes DEAD with a notification" {
    const alloc = testing.allocator;
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    var fake = FakeClock{};
    const conn = try Connection.createOpts(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
        .{ .clock = fake.clock(), .heartbeat_interval_ms = 50 },
    );
    defer conn.destroy(alloc);

    var rec = StateRec{ .conn = conn };
    conn.setStateHandler(&rec, StateRec.handler);

    var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer agent.deinit();
    var hctx = HealthAgentCtx{ .agent = &agent };
    const ath = try std.Thread.spawn(.{}, HealthAgentCtx.run, .{&hctx});

    try conn.start();
    _ = try conn.waitHandshake();

    // Trigger the agent to send a DETACHED (steal/eviction, §5.3).
    hctx.send_detached.store(true, .monotonic);
    // Nudge the agent loop: send a PING so it cycles and emits the DETACHED. We do
    // this by waiting for the agent to flag it sent.
    hctx.detached_sent.wait();

    // The client must observe eviction and a DEAD link, and the observer must fire.
    try spinUntil(Connection, conn, struct {
        fn f(c: *Connection) bool {
            return c.isEvicted() and c.state() == .dead;
        }
    }.f);
    try testing.expect(conn.isEvicted());
    try testing.expectEqual(LinkState.State.dead, conn.state());
    try spinUntil(StateRec, &rec, struct {
        fn f(c: *StateRec) bool {
            return c.saw_dead.load(.monotonic);
        }
    }.f);
    try testing.expect(rec.saw_dead.load(.monotonic));

    conn.shutdown();
    ath.join();
}

test "reader EOF (agent closes) drives onTransportError → reconnecting" {
    const alloc = testing.allocator;
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    var fake = FakeClock{};
    const conn = try Connection.createOpts(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
        .{ .clock = fake.clock(), .heartbeat_interval_ms = 1000 },
    );
    defer conn.destroy(alloc);

    var rec = StateRec{ .conn = conn };
    conn.setStateHandler(&rec, StateRec.handler);

    var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer agent.deinit();
    var hctx = HealthAgentCtx{ .agent = &agent };
    const ath = try std.Thread.spawn(.{}, HealthAgentCtx.run, .{&hctx});

    try conn.start();
    _ = try conn.waitHandshake();

    // Close BOTH directions of the control loopback → the client's control reader
    // sees EOF (NOT a deliberate shutdown, so the FSM moves to reconnecting) and the
    // agent's reader also EOFs so its thread can exit cleanly.
    ctrl_lb.agent_to_client.close();
    ctrl_lb.client_to_agent.close();

    try spinUntil(StateRec, &rec, struct {
        fn f(c: *StateRec) bool {
            return c.saw_reconnecting.load(.monotonic);
        }
    }.f);
    try testing.expect(rec.saw_reconnecting.load(.monotonic));

    ath.join();
    conn.shutdown();
}

// =============================================================================
// Increment 3 tests: channel/session lifecycle, resync (§7.3), steal (§5.3),
// FLOW{pause} (§4.3)
// =============================================================================

/// A lifecycle-aware mock agent. Handshakes on the control stream, then services
/// control frames on its own thread:
///   - `OPEN`   → reply `OPENED{session_id, pid}` on the same channel.
///   - `ATTACH` → reply `ATTACHED{...}` (configurable) on the same channel.
///   - `CLOSE`  / `DETACH` → record which arrived (and the channel).
///   - `PING`   → reply `PONG` (so the link stays healthy during a test).
/// The channel id the client minted is observed from the OPEN/ATTACH frame and
/// published via `seen_channel` + `saw_request` so the test can send DATA on it.
const LifecycleAgent = struct {
    ctrl: *MockAgent,
    alloc: Allocator,

    // OPENED reply contents.
    session_id: []const u8 = "sess-1",
    pid: i64 = 4242,
    /// When true, each OPEN gets a fresh, unique session id (so N concurrent
    /// OPENs produce N distinct panes). The id buffers are owned by the agent and
    /// freed on `deinit` via `session_buf`.
    unique_sessions: bool = false,
    open_count: std.atomic.Value(u32) = .{ .raw = 0 },
    session_bufs: std.ArrayList([]u8) = .empty,

    // ATTACHED reply contents (only used when an ATTACH arrives).
    attach_status: protocol.Attached.AttachStatus = .alive,
    snapshot_at_offset: u64 = 0,
    attached_elsewhere_first: bool = false, // true → first ATTACH reports stolen
    exit_code: ?i64 = null,
    /// When true the agent receives OPEN but NEVER replies OPENED (models a remote
    /// session whose command/cwd failed to spawn). Exercises the RPC timeout so a
    /// silent agent can't wedge the caller (the pane IO thread) forever.
    silent_open: bool = false,

    // GET_CWD reply contents. `cwd_reply == null` ⇒ reply CWD{ok=false}; else
    // reply CWD{ok=true, path}. When `silent_cwd` is true the agent receives
    // GET_CWD but never replies (exercises the queryCwd RPC timeout).
    // `cwd_found` is the CWD reply's existence signal (T06b): null models an
    // OLDER agent that predates the field.
    cwd_reply: ?[]const u8 = "/private/tmp",
    cwd_found: ?bool = null,
    silent_cwd: bool = false,

    // METRICS push contents. On `.metrics_sub` the agent pushes `metrics_push_count`
    // `.metrics` frames on the control channel (the first reporting `cpu_pct = 0`,
    // the rest a non-zero delta) so a subscriber can assert it receives decodable
    // `HostMetrics`. `.metrics_unsub` is recorded via `saw_metrics_unsub`.
    metrics_push_count: u32 = 2,
    saw_metrics_sub: std.atomic.Value(bool) = .{ .raw = false },
    saw_metrics_unsub: std.atomic.Value(bool) = .{ .raw = false },
    saw_proc_list: std.atomic.Value(bool) = .{ .raw = false },

    // PROC_KILL / PROC_SPAWN reply config (inc 4+5). A PROC_KILL for `kill_fail_pid`
    // replies ok=false (models no-such-pid); any other pid succeeds. PROC_SPAWN
    // always replies ok=true with `spawn_pid`.
    saw_proc_kill: std.atomic.Value(bool) = .{ .raw = false },
    saw_proc_spawn: std.atomic.Value(bool) = .{ .raw = false },
    kill_fail_pid: i64 = -424242, // a sentinel no real test pid uses
    spawn_pid: i64 = 99001,

    // Observations (atomics / events so the test thread can read them safely).
    seen_channel: std.atomic.Value(u128) = .{ .raw = 0 },
    saw_request: std.Thread.ResetEvent = .{},
    saw_close: std.atomic.Value(bool) = .{ .raw = false },
    saw_detach: std.atomic.Value(bool) = .{ .raw = false },
    close_detach_seen: std.Thread.ResetEvent = .{},
    attach_count: std.atomic.Value(u32) = .{ .raw = 0 },
    err: ?anyerror = null,

    fn run(self: *LifecycleAgent) void {
        self.body() catch |e| {
            self.err = e;
        };
    }

    fn body(self: *LifecycleAgent) !void {
        _ = try self.ctrl.handshake();
        while (true) {
            const frame = (try self.ctrl.nextFrame()) orelse return; // EOF: done
            switch (frame.type) {
                .open => {
                    self.seen_channel.store(frame.channel, .monotonic);
                    self.saw_request.set();
                    // Model a remote session that fails to spawn (bad command/cwd):
                    // the agent never sends OPENED. The client's OPEN RPC must time
                    // out rather than block forever.
                    if (self.silent_open) continue;
                    var sid = self.session_id;
                    if (self.unique_sessions) {
                        const n = self.open_count.fetchAdd(1, .monotonic);
                        const buf = try std.fmt.allocPrint(self.alloc, "sess-{d}", .{n});
                        try self.session_bufs.append(self.alloc, buf);
                        sid = buf;
                    }
                    try self.ctrl.sendJson(.opened, frame.channel, protocol.Opened{
                        .session_id = sid,
                        .pid = self.pid,
                    });
                },
                .attach => {
                    const n = self.attach_count.fetchAdd(1, .monotonic);
                    self.seen_channel.store(frame.channel, .monotonic);
                    self.saw_request.set();
                    // If configured, the FIRST attach reports attached_elsewhere; a
                    // retry (which carries force=true) succeeds.
                    const elsewhere = self.attached_elsewhere_first and n == 0;
                    try self.ctrl.sendJson(.attached, frame.channel, protocol.Attached{
                        .status = self.attach_status,
                        .rows = 24,
                        .cols = 80,
                        .cwd = "/home/me",
                        .title = "remote",
                        .snapshot_at_offset = self.snapshot_at_offset,
                        .exit_code = self.exit_code,
                        .attached_elsewhere = elsewhere,
                    });
                },
                .get_cwd => {
                    // Reply CWD on the SAME request channel (same-channel RPC).
                    if (self.silent_cwd) continue;
                    var parsed = protocol.parseJson(protocol.GetCwd, self.alloc, frame.payload) catch continue;
                    defer parsed.deinit();
                    const sid = parsed.value.session_id;
                    try self.ctrl.sendJson(.cwd, frame.channel, protocol.Cwd{
                        .session_id = sid,
                        .path = self.cwd_reply,
                        .ok = self.cwd_reply != null,
                        .found = self.cwd_found,
                    });
                },
                .close => {
                    self.saw_close.store(true, .monotonic);
                    self.close_detach_seen.set();
                },
                .detach => {
                    self.saw_detach.store(true, .monotonic);
                    self.close_detach_seen.set();
                },
                .ping => {
                    var buf: [Heartbeat.encoded_len]u8 = undefined;
                    const hb = try Heartbeat.decode(frame.payload);
                    _ = hb.encodeInto(&buf);
                    try self.ctrl.sendFrame(.{
                        .type = .pong,
                        .channel = protocol.control_channel,
                        .seq = 0,
                        .payload = &buf,
                    });
                },
                .metrics_sub => {
                    self.saw_metrics_sub.store(true, .monotonic);
                    // Push `metrics_push_count` metrics frames on the control
                    // channel (first cpu_pct=0, then a non-zero delta), as the real
                    // agent's per-connection push pump does.
                    var i: u32 = 0;
                    while (i < self.metrics_push_count) : (i += 1) {
                        const host: protocol.HostMetrics = .{
                            .cpu_pct = if (i == 0) 0 else 12.5,
                            .mem_used = 8 * 1024 * 1024 * 1024,
                            .mem_total = 16 * 1024 * 1024 * 1024,
                            .ncpu = 10,
                            .uptime_s = 3600,
                            .load1 = 1.5,
                        };
                        try self.ctrl.sendJson(.metrics, protocol.control_channel, protocol.Metrics{
                            .host = host,
                        });
                    }
                },
                .metrics_unsub => {
                    self.saw_metrics_unsub.store(true, .monotonic);
                },
                .proc_list => {
                    // Reply PROC_SNAPSHOT on the SAME request channel (same-channel
                    // RPC, like CWD). A small fixed table so the client can assert the
                    // owned deep copy round-trips + frees clean.
                    self.saw_proc_list.store(true, .monotonic);
                    const procs = [_]protocol.Proc{
                        .{ .pid = 1, .ppid = 0, .name = "init", .cpu_pct = 0, .mem_bytes = 1024 * 1024, .user = "root", .cmd = null },
                        .{ .pid = 4242, .ppid = 1, .name = "ghoztty-agent", .cpu_pct = 12.5, .mem_bytes = 8 * 1024 * 1024, .user = "me", .cmd = "ghoztty-agent --listen" },
                    };
                    try self.ctrl.sendJson(.proc_snapshot, frame.channel, protocol.ProcSnapshot{
                        .ok = true,
                        .host = .{ .cpu_pct = 7.5, .mem_used = 4 * 1024 * 1024 * 1024, .mem_total = 16 * 1024 * 1024 * 1024, .ncpu = 8 },
                        .procs = &procs,
                        .truncated = true,
                    });
                },
                .proc_kill => {
                    // Reply PROC_KILL_RESULT on the SAME request channel. A "magic"
                    // bogus pid models a failure (ok=false, error); anything else
                    // succeeds (echoing the requested pid).
                    self.saw_proc_kill.store(true, .monotonic);
                    var parsed = protocol.parseJson(protocol.ProcKill, self.alloc, frame.payload) catch continue;
                    defer parsed.deinit();
                    const pid = parsed.value.pid;
                    const ok = pid != self.kill_fail_pid;
                    try self.ctrl.sendJson(.proc_kill_result, frame.channel, protocol.ProcKillResult{
                        .pid = pid,
                        .ok = ok,
                        .@"error" = if (ok) null else "no such process",
                    });
                },
                .proc_spawn => {
                    // Reply PROC_SPAWN_RESULT on the request channel with a fixed
                    // synthetic pid.
                    self.saw_proc_spawn.store(true, .monotonic);
                    try self.ctrl.sendJson(.proc_spawn_result, frame.channel, protocol.ProcSpawnResult{
                        .ok = true,
                        .pid = self.spawn_pid,
                        .@"error" = null,
                    });
                },
                else => {},
            }
        }
    }
};

/// Shared scaffolding for the lifecycle tests: a control + data loopback, a
/// Connection (raw encoding, long heartbeat so it doesn't interfere), a started
/// lifecycle agent thread, and a separate data-stream MockAgent for DATA.
const LifecycleHarness = struct {
    alloc: Allocator,
    ctrl_lb: Loopback,
    data_lb: Loopback,
    conn: *Connection,
    ctrl_agent: MockAgent,
    data_agent: MockAgent,
    agent: LifecycleAgent,
    thread: std.Thread = undefined,

    fn create(alloc: Allocator) !*LifecycleHarness {
        return createWithTimeout(alloc, rpc_open_timeout_ns);
    }

    fn createWithTimeout(alloc: Allocator, rpc_timeout_ns: u64) !*LifecycleHarness {
        const h = try alloc.create(LifecycleHarness);
        h.* = .{
            .alloc = alloc,
            .ctrl_lb = Loopback.init(alloc),
            .data_lb = Loopback.init(alloc),
            .conn = undefined,
            .ctrl_agent = undefined,
            .data_agent = undefined,
            .agent = undefined,
        };
        h.conn = try Connection.createOpts(
            alloc,
            h.ctrl_lb.clientStream(),
            h.data_lb.clientStream(),
            .{ .transfer_encoding = .raw },
            .{
                .heartbeat_interval_ms = 100_000, // effectively never during a test
                .rpc_open_timeout_ns = rpc_timeout_ns,
            },
        );
        h.ctrl_agent = MockAgent.init(alloc, h.ctrl_lb.agentStream(), .raw);
        h.data_agent = MockAgent.init(alloc, h.data_lb.agentStream(), .raw);
        h.agent = .{ .ctrl = &h.ctrl_agent, .alloc = alloc };
        return h;
    }

    /// Configure the agent BEFORE calling `start` (the agent thread reads the
    /// config fields). Returns a pointer for in-place tweaks.
    fn configure(h: *LifecycleHarness) *LifecycleAgent {
        return &h.agent;
    }

    fn start(h: *LifecycleHarness) !void {
        h.thread = try std.Thread.spawn(.{}, LifecycleAgent.run, .{&h.agent});
        try h.conn.start();
        _ = try h.conn.waitHandshake();
    }

    fn destroy(h: *LifecycleHarness) void {
        h.conn.shutdown();
        h.thread.join();
        for (h.agent.session_bufs.items) |b| h.alloc.free(b);
        h.agent.session_bufs.deinit(h.alloc);
        h.conn.destroy(h.alloc);
        h.ctrl_agent.deinit();
        h.data_agent.deinit();
        h.ctrl_lb.deinit();
        h.data_lb.deinit();
        h.alloc.destroy(h);
    }
};

test "openChannel: returns a pane with the agent's session_id/pid and routes DATA" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.session_id = "session-abc";
    a.pid = 9001;
    try h.start();

    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80, .command = "bash" });

    // The agent received a well-formed OPEN on the pane's channel id.
    a.saw_request.wait();
    try testing.expectEqual(pane.id, a.seen_channel.load(.monotonic));
    // The pane carries the agent-assigned identity.
    try testing.expectEqualStrings("session-abc", pane.session_id);
    try testing.expectEqual(@as(i64, 9001), pane.pid);

    // Subsequent agent DATA on that channel lands in the pane's ring.
    try agentSendData(&h.data_agent, pane.id, 0, "hello from the agent");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try drainChannel(pane.ring, &got, alloc, "hello from the agent".len);
    try testing.expectEqualStrings("hello from the agent", got.items);

    try testing.expect(a.err == null);
    // Teardown the pane explicitly (consumer has stopped draining: the test owns it).
    h.conn.closeChannel(pane);
}

test "EXIT frame: signals the pane's ring so the consumer can close the pane" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.session_id = "sess-exit";
    try h.start();

    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80, .command = "bash" });
    a.saw_request.wait();

    // Not exited until the agent reports it.
    try testing.expect(!pane.ring.isExited());

    // The agent frames EXIT on the per-session CONTROL channel (the pane's channel
    // id), ordered after any final DATA. The connection's control reader routes it
    // through `handleControlInternal` → `signalExit` on this pane's ring.
    try h.ctrl_agent.sendJson(.exit, pane.id, protocol.Exit{ .code = 137, .runtime_ms = 4242 });

    // The control thread observes the frame asynchronously; spin until it lands.
    const RingWait = struct {
        ring: *ring.Channel,
        fn done(self: *@This()) bool {
            return self.ring.isExited();
        }
    };
    var rw: RingWait = .{ .ring = pane.ring };
    try spinUntil(RingWait, &rw, RingWait.done);

    // The cached code/runtime are visible (acquire/release pairing in signalExit),
    // exactly what the Remote backend's drain coerces into `.child_exited`.
    try testing.expectEqual(@as(i64, 137), pane.ring.exit_code);
    try testing.expectEqual(@as(u64, 4242), pane.ring.runtime_ms);

    try testing.expect(a.err == null);
    h.conn.closeChannel(pane);
}

test "EXIT frame: an unknown channel id is dropped without crashing" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    try h.start();

    // No pane is registered for this channel; the control reader must drop the EXIT
    // (late/duplicate after teardown, or hostile id) and keep servicing the link.
    try h.ctrl_agent.sendJson(.exit, 0xDEADBEEF, protocol.Exit{ .code = 1, .runtime_ms = 0 });

    // The link is still healthy afterward: an OPEN still round-trips.
    h.configure().session_id = "still-alive";
    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80 });
    try testing.expectEqualStrings("still-alive", pane.session_id);
    h.conn.closeChannel(pane);
}

test "queryCwd: returns the agent's reported path for a session" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.cwd_reply = "/private/tmp/work";
    try h.start();

    const cwd = try h.conn.queryCwd("sess-1");
    defer alloc.free(cwd);
    try testing.expectEqualStrings("/private/tmp/work", cwd);
}

test "queryCwd: agent reporting ok=false surfaces CwdUnavailable (no hang)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    h.configure().cwd_reply = null; // agent replies CWD{ok=false}
    try h.start();

    try testing.expectError(error.CwdUnavailable, h.conn.queryCwd("sess-1"));
}

test "probeSession: tri-state — ok=true is alive regardless of found" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    h.configure().cwd_reply = "/private/tmp/work"; // ok=true
    try h.start();

    try testing.expectEqual(
        Connection.SessionProbe.alive,
        h.conn.probeSessionTimeout("sess-1", std.time.ns_per_s),
    );
}

test "probeSession: found=true with a failed cwd read is still alive (attachable)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.cwd_reply = null; // ok=false (cwd read failed)…
    a.cwd_found = true; // …but the session exists
    try h.start();

    try testing.expectEqual(
        Connection.SessionProbe.alive,
        h.conn.probeSessionTimeout("sess-1", std.time.ns_per_s),
    );
}

test "probeSession: found=false is POSITIVE dead" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.cwd_reply = null;
    a.cwd_found = false;
    try h.start();

    try testing.expectEqual(
        Connection.SessionProbe.dead,
        h.conn.probeSessionTimeout("sess-1", std.time.ns_per_s),
    );
}

test "probeSession: an older agent (no found field) is INCONCLUSIVE, never dead" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    h.configure().cwd_reply = null; // ok=false, found omitted (old agent)
    try h.start();

    try testing.expectEqual(
        Connection.SessionProbe.unknown,
        h.conn.probeSessionTimeout("sess-1", std.time.ns_per_s),
    );
}

test "probeSession: a silent agent times out as unknown (no error, no hang)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.createWithTimeout(alloc, 50 * std.time.ns_per_ms);
    defer h.destroy();
    h.configure().silent_cwd = true;
    try h.start();

    try testing.expectEqual(
        Connection.SessionProbe.unknown,
        h.conn.probeSessionTimeout("sess-1", 50 * std.time.ns_per_ms),
    );
}

test "queryCwd: a silent agent (no CWD reply) times out instead of deadlocking" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.createWithTimeout(alloc, 50 * std.time.ns_per_ms);
    defer h.destroy();
    h.configure().silent_cwd = true;
    try h.start();

    try testing.expectError(error.Timeout, h.conn.queryCwd("sess-1"));
}

test "queryCwdTimeout: explicit bound returns the path on a responsive agent" {
    const alloc = testing.allocator;
    // The connection's DEFAULT RPC timeout is the long production value; this
    // proves the EXPLICIT bound passed by the GUI path still returns the path
    // when the agent replies (a healthy agent answers in ms).
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    h.configure().cwd_reply = "C:\\Windows";
    try h.start();

    const cwd = try h.conn.queryCwdTimeout("sess-1", 1500 * std.time.ns_per_ms);
    defer alloc.free(cwd);
    try testing.expectEqualStrings("C:\\Windows", cwd);
}

test "queryCwdTimeout: a tight bound on a silent agent fails fast (GUI never stalls)" {
    const alloc = testing.allocator;
    // The GUI new-window/tab/split path passes a tight explicit bound so a slow
    // or wedged agent can't beachball. Prove the explicit bound (NOT the
    // connection's 10s default) governs: a silent agent returns error.Timeout
    // well under the default.
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    h.configure().silent_cwd = true;
    try h.start();

    const t = std.time.milliTimestamp();
    try testing.expectError(
        error.Timeout,
        h.conn.queryCwdTimeout("sess-1", 80 * std.time.ns_per_ms),
    );
    const elapsed = std.time.milliTimestamp() - t;
    try testing.expect(elapsed < 5_000);
}

// --- Host-metrics subscription (§9.3) ----------------------------------------

/// A thread-safe sink for the pushed `HostMetrics`. The handler fires on the
/// connection's control-reader thread, so the count + the last sample + the
/// "got enough" event are shared with the test thread under a mutex / ResetEvent.
const MetricsRec = struct {
    mutex: std.Thread.Mutex = .{},
    count: u32 = 0,
    want: u32 = 0,
    last: protocol.HostMetrics = .{},
    enough: std.Thread.ResetEvent = .{},

    fn handler(ctx: *anyopaque, host: protocol.HostMetrics) void {
        const self: *MetricsRec = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        self.count += 1;
        self.last = host;
        const reached = self.count >= self.want;
        self.mutex.unlock();
        if (reached) self.enough.set();
    }
};

test "subscribeMetrics: handler receives decodable HostMetrics pushes" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.metrics_push_count = 2;
    try h.start();

    var rec: MetricsRec = .{ .want = 2 };
    try h.conn.subscribeMetrics(500, &rec, MetricsRec.handler);

    // Wait (bounded) for both pushed frames.
    rec.enough.timedWait(2 * std.time.ns_per_s) catch {};

    rec.mutex.lock();
    const count = rec.count;
    const last = rec.last;
    rec.mutex.unlock();

    try testing.expect(a.saw_metrics_sub.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), count);
    // The second push carries the non-zero delta + the static fields the agent set.
    try testing.expectEqual(@as(f32, 12.5), last.cpu_pct);
    try testing.expectEqual(@as(u64, 8 * 1024 * 1024 * 1024), last.mem_used);
    try testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), last.mem_total);
    try testing.expectEqual(@as(u32, 10), last.ncpu);
    try testing.expectEqual(@as(?u64, 3600), last.uptime_s);
    try testing.expectEqual(@as(?f32, 1.5), last.load1);

    h.conn.unsubscribeMetrics();
    try testing.expect(a.err == null);
}

test "unsubscribeMetrics: clears the handler slot (no callback after)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.metrics_push_count = 1;
    try h.start();

    var rec: MetricsRec = .{ .want = 1 };
    try h.conn.subscribeMetrics(500, &rec, MetricsRec.handler);
    rec.enough.timedWait(2 * std.time.ns_per_s) catch {};

    // Unsubscribe: the slot is cleared under the write mutex, so no later push
    // can re-enter `rec` (which is about to leave scope).
    h.conn.unsubscribeMetrics();
    try testing.expect(h.conn.metrics_handler == null);

    // The agent recorded the unsub.
    var spins: usize = 0;
    while (!a.saw_metrics_unsub.load(.monotonic) and spins < 1000) : (spins += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(a.saw_metrics_unsub.load(.monotonic));

    // A second unsubscribe is a harmless no-op (slot already null).
    h.conn.unsubscribeMetrics();
    try testing.expect(h.conn.metrics_handler == null);
    try testing.expect(a.err == null);
}

test "requestProcSnapshot: owned deep copy round-trips and frees clean" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    try h.start();

    var snap = try h.conn.requestProcSnapshot(null, 25, 2 * std.time.ns_per_s);
    defer snap.deinit(); // testing.allocator flags any leak in the owned copy

    try testing.expect(a.saw_proc_list.load(.monotonic));
    try testing.expect(snap.truncated);
    try testing.expectEqual(@as(u32, 8), snap.host.ncpu);
    try testing.expectEqual(@as(f32, 7.5), snap.host.cpu_pct);
    try testing.expectEqual(@as(usize, 2), snap.procs.len);

    // First row: pid 1 init, owned strings duped out of the parsed arena.
    try testing.expectEqual(@as(i64, 1), snap.procs[0].pid);
    try testing.expectEqualStrings("init", snap.procs[0].name);
    try testing.expectEqualStrings("root", snap.procs[0].user.?);
    try testing.expect(snap.procs[0].cmd == null);

    // Second row: pid 4242, with a cmd string.
    try testing.expectEqual(@as(i64, 4242), snap.procs[1].pid);
    try testing.expectEqual(@as(i64, 1), snap.procs[1].ppid);
    try testing.expectEqualStrings("ghoztty-agent", snap.procs[1].name);
    try testing.expectEqual(@as(f32, 12.5), snap.procs[1].cpu_pct);
    try testing.expectEqualStrings("ghoztty-agent --listen", snap.procs[1].cmd.?);
    try testing.expect(a.err == null);
}

test "killProc: round-trips ok and surfaces the agent error string" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    try h.start();

    // A normal pid: ok=true, no error.
    var ok = try h.conn.killProc(4242, "TERM", 2 * std.time.ns_per_s);
    defer ok.deinit();
    try testing.expect(a.saw_proc_kill.load(.monotonic));
    try testing.expectEqual(@as(i64, 4242), ok.pid);
    try testing.expect(ok.ok);
    try testing.expect(ok.error_msg == null);

    // The sentinel "fail" pid: ok=false with an owned error string.
    var bad = try h.conn.killProc(a.kill_fail_pid, null, 2 * std.time.ns_per_s);
    defer bad.deinit();
    try testing.expect(!bad.ok);
    try testing.expectEqualStrings("no such process", bad.error_msg.?);
    try testing.expect(a.err == null);
}

test "spawnProc: round-trips ok with the agent-reported pid" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    try h.start();

    var out = try h.conn.spawnProc("sleep 1", "/tmp", 2 * std.time.ns_per_s);
    defer out.deinit();
    try testing.expect(a.saw_proc_spawn.load(.monotonic));
    try testing.expect(out.ok);
    try testing.expectEqual(@as(i64, 99001), out.pid.?);
    try testing.expect(out.error_msg == null);
    try testing.expect(a.err == null);
}

test "openChannel: a silent agent (no OPENED) times out instead of deadlocking" {
    const alloc = testing.allocator;
    // Tiny RPC timeout so the test is fast; the agent receives OPEN but never
    // replies OPENED (the real-world cause was a bad command/cwd making the
    // remote session fail to spawn — the WP4 GUI stall/hung-quit regression).
    const h = try LifecycleHarness.createWithTimeout(alloc, 50 * std.time.ns_per_ms);
    defer h.destroy();
    h.configure().silent_open = true;
    try h.start();

    const t = std.time.milliTimestamp();
    try testing.expectError(error.Timeout, h.conn.openChannel(.{ .rows = 24, .cols = 80 }));
    const elapsed = std.time.milliTimestamp() - t;

    // It returned (did not hang) and roughly respected the bound. Generous upper
    // bound to stay robust on a loaded CI host.
    try testing.expect(elapsed < 5_000);
    // The agent did see the OPEN (so we exercised the no-reply path, not a drop).
    try testing.expect(h.agent.saw_request.isSet());
    // No pane/channel was registered on the failed OPEN (caller owns nothing).
    h.conn.panes_mutex.lock();
    const pane_count = h.conn.panes.count();
    h.conn.panes_mutex.unlock();
    try testing.expectEqual(@as(usize, 0), pane_count);
}

test "cancelRpcsFor: wakes a parked OPEN promptly with error.Cancelled" {
    const alloc = testing.allocator;
    // LONG timeout: a pass proves the CANCEL woke the caller, not the timeout.
    // This is the surface-teardown path: the GUI thread must be able to wake a
    // pane's IO thread out of a doomed OPEN/ATTACH before joining it.
    const h = try LifecycleHarness.createWithTimeout(alloc, 60 * std.time.ns_per_s);
    defer h.destroy();
    h.configure().silent_open = true; // the agent never replies OPENED
    try h.start();

    var canceller: RpcCanceller = .{};
    const Worker = struct {
        conn: *Connection,
        canceller: *const RpcCanceller,
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = self.conn.openChannelCancellable(
                .{ .rows = 24, .cols = 80 },
                self.canceller,
            ) catch |e| {
                self.result = e;
                return;
            };
        }
    };
    var w: Worker = .{ .conn = h.conn, .canceller = &canceller };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&w});

    // Wait until the OPEN is on the wire (the slot is registered before the
    // send), then cancel: flag first, then the slot walk (the required order).
    h.agent.saw_request.wait();
    const t = std.time.milliTimestamp();
    canceller.cancel();
    h.conn.cancelRpcsFor(&canceller);
    thread.join();
    const elapsed = std.time.milliTimestamp() - t;

    try testing.expectEqual(@as(anyerror, error.Cancelled), w.result.?);
    // Woke promptly (well under the 60s RPC timeout). Generous for loaded CI.
    try testing.expect(elapsed < 5_000);
    // Nothing was registered for the cancelled OPEN (caller owns nothing).
    h.conn.panes_mutex.lock();
    const pane_count = h.conn.panes.count();
    h.conn.panes_mutex.unlock();
    try testing.expectEqual(@as(usize, 0), pane_count);
}

test "rpcCall: an already-cancelled canceller fails fast (register-vs-cancel race)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.createWithTimeout(alloc, 60 * std.time.ns_per_s);
    defer h.destroy();
    h.configure().silent_open = true;
    try h.start();

    // Cancel BEFORE issuing the RPC: models the GUI thread tearing the surface
    // down just as (or before) the IO thread reaches its OPEN/ATTACH.
    var canceller: RpcCanceller = .{};
    canceller.cancel();
    h.conn.cancelRpcsFor(&canceller);

    const t = std.time.milliTimestamp();
    try testing.expectError(error.Cancelled, h.conn.openChannelCancellable(
        .{ .rows = 24, .cols = 80 },
        &canceller,
    ));
    try testing.expect(std.time.milliTimestamp() - t < 5_000);
}

test "control reader exit fails a parked RPC promptly (no reply can ever arrive)" {
    const alloc = testing.allocator;
    // LONG timeout again: the parked OPEN must be failed by the control
    // reader's exit (link death), NOT by waiting out the timeout.
    const h = try LifecycleHarness.createWithTimeout(alloc, 60 * std.time.ns_per_s);
    defer h.destroy();
    h.configure().silent_open = true;
    try h.start();

    const Worker = struct {
        conn: *Connection,
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = self.conn.openChannel(.{ .rows = 24, .cols = 80 }) catch |e| {
                self.result = e;
                return;
            };
        }
    };
    var w: Worker = .{ .conn = h.conn };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&w});

    // Once the OPEN is on the wire, kill the control lane (models the
    // transport dying mid-RPC). The control reader sees EOF and exits; its
    // exit must fail the parked caller immediately.
    h.agent.saw_request.wait();
    const t = std.time.milliTimestamp();
    h.ctrl_lb.clientStream().close();
    thread.join();
    const elapsed = std.time.milliTimestamp() - t;

    try testing.expectEqual(@as(anyerror, error.ConnectionClosed), w.result.?);
    try testing.expect(elapsed < 5_000);

    // The connection is latched closed for RPCs: a later call fails fast
    // instead of parking for its full timeout on the dead link.
    const t2 = std.time.milliTimestamp();
    try testing.expectError(
        error.ConnectionClosed,
        h.conn.openChannel(.{ .rows = 24, .cols = 80 }),
    );
    try testing.expect(std.time.milliTimestamp() - t2 < 5_000);
}

test "openChannel: N concurrent OPENs on one Connection all succeed (rapid remote splits)" {
    // Regression (rapid remote split panes crashed on the ~3rd pane): each remote
    // pane's IO thread calls `openChannel` on the SHARED Connection concurrently.
    // The single by-type `pending_opened` slot used to reject all-but-one with
    // `error.RpcInFlight`, leaving panes non-functional. OPENs must now serialize
    // safely so every concurrent split gets a live pane.
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    // The agent mints a fresh session id per OPEN so every pane is distinct.
    const a = h.configure();
    a.unique_sessions = true;
    try h.start();

    const N = 6;
    const Worker = struct {
        conn: *Connection,
        result: ?anyerror = null,
        pane: ?*Pane = null,
        fn run(self: *@This()) void {
            self.pane = self.conn.openChannel(.{ .rows = 24, .cols = 80, .command = "bash" }) catch |e| {
                self.result = e;
                return;
            };
        }
    };
    var workers: [N]Worker = undefined;
    var threads: [N]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .conn = h.conn };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (threads) |t| t.join();

    // Every concurrent OPEN must have produced a live pane (no RpcInFlight).
    for (workers) |w| {
        if (w.result) |e| {
            std.debug.print("concurrent OPEN failed: {}\n", .{e});
            return e;
        }
        try testing.expect(w.pane != null);
    }
    // All N panes are tracked and distinct.
    h.conn.panes_mutex.lock();
    const pane_count = h.conn.panes.count();
    h.conn.panes_mutex.unlock();
    try testing.expectEqual(@as(usize, N), pane_count);

    // Teardown every pane explicitly (the test owns them; no consumer is draining).
    for (workers) |w| if (w.pane) |p| h.conn.closeChannel(p);
}

test "writeInput: bytes reach the agent as DATA with monotonic byte_offset" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    try h.start();

    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80 });
    h.agent.saw_request.wait();

    // Two writes; the agent should see them as DATA with offsets 0 then 5.
    try h.conn.writeInput(pane, "hello");
    try h.conn.writeInput(pane, "world!");

    const f1 = (try h.data_agent.nextFrame()) orelse return error.NoData;
    try testing.expectEqual(protocol.FrameType.data, f1.type);
    try testing.expectEqual(pane.id, f1.channel);
    const dp1 = try protocol.DataPayload.decode(f1.payload);
    try testing.expectEqual(@as(u64, 0), dp1.byte_offset);
    try testing.expectEqualStrings("hello", dp1.bytes);

    const f2 = (try h.data_agent.nextFrame()) orelse return error.NoData;
    const dp2 = try protocol.DataPayload.decode(f2.payload);
    try testing.expectEqual(@as(u64, 5), dp2.byte_offset); // advanced by "hello".len
    try testing.expectEqualStrings("world!", dp2.bytes);

    h.conn.closeChannel(pane);
}

test "attachChannel: resumed attach — byte-accurate resync discard anchored at last_byte_offset (§7.3)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .alive;
    a.snapshot_at_offset = 10;
    try h.start();

    // The client already APPLIED absolute bytes [0,11) (last_byte_offset = 11 =
    // next byte it expects). Replayed/overlapping bytes below that watermark
    // must be dropped; everything from 11 on must land.
    var outcome = try h.conn.attachChannel("session-xyz", 24, 80, 11, false);
    defer outcome.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, outcome.status);
    try testing.expectEqual(@as(u64, 10), outcome.snapshot_at_offset);
    try testing.expect(!outcome.attached_elsewhere);
    const pane = outcome.pane orelse return error.NoPane;
    try testing.expectEqualStrings("/home/me", outcome.cwd.?);
    try testing.expectEqualStrings("remote", outcome.title.?);

    h.agent.saw_request.wait();
    const ch = pane.id;

    // Frame A: offsets [0,5) — entirely already-applied (< 11) → dropped whole.
    try agentSendData(&h.data_agent, ch, 0, "AAAAA");
    // Frame B: offsets [5,15) — straddles the watermark. Bytes at abs 5..10
    // dropped (already applied), bytes at abs 11..14 kept. 10-byte payload:
    // indices 0..9 → abs 5..14. Keep abs >= 11 ⇒ indices 6,7,8,9.
    try agentSendData(&h.data_agent, ch, 5, "0123456789");
    // Frame C: offsets [15,20) — all beyond the watermark → kept whole.
    try agentSendData(&h.data_agent, ch, 15, "TAILX");

    // Expected landed bytes: suffix of B (indices 6..9 = "6789") + all of C.
    const expected = "6789TAILX";
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try drainChannel(pane.ring, &got, alloc, expected.len);
    try testing.expectEqualStrings(expected, got.items);

    try testing.expect(a.err == null);
    h.conn.closeChannel(pane);
}

test "attachChannel: fresh attach (offset 0) keeps the FULL gap-fill replay (blank-window regression)" {
    // WP-D1 wedged-window regression: a fresh attach (new surface, nothing
    // applied locally — the reconnect swap and the WP-D2 relaunch restore)
    // used to arm the resync discard at `snapshot_at_offset`, which threw away
    // the agent's whole `[0, S)` replay and produced a BLANK re-attached
    // window. Offset-0 attaches must deliver every replayed byte.
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .alive;
    a.snapshot_at_offset = 10; // agent head; replay covers [0,10)
    try h.start();

    var outcome = try h.conn.attachChannel("session-xyz", 24, 80, 0, false);
    defer outcome.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, outcome.status);
    const pane = outcome.pane orelse return error.NoPane;

    h.agent.saw_request.wait();
    const ch = pane.id;

    // The gap-fill replay ([0,10)) followed by live output ([10,15)): ALL of it
    // must reach the ring — nothing is "covered by a snapshot" (none is sent).
    try agentSendData(&h.data_agent, ch, 0, "0123456789");
    try agentSendData(&h.data_agent, ch, 10, "LIVE!");

    const expected = "0123456789LIVE!";
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try drainChannel(pane.ring, &got, alloc, expected.len);
    try testing.expectEqualStrings(expected, got.items);

    try testing.expect(a.err == null);
    h.conn.closeChannel(pane);
}

test "attachChannel: dead status surfaces exit_code; no pane" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .dead;
    a.exit_code = 137;
    try h.start();

    var outcome = try h.conn.attachChannel("gone", 24, 80, 0, false);
    defer outcome.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.dead, outcome.status);
    try testing.expectEqual(@as(i64, 137), outcome.exit_code.?);
    try testing.expect(outcome.pane == null);
}

test "attachChannel: not_found surfaces; no pane" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .not_found;
    try h.start();

    var outcome = try h.conn.attachChannel("nope", 24, 80, 0, false);
    defer outcome.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.not_found, outcome.status);
    try testing.expect(outcome.pane == null);
}

test "attachChannel: steal — attached_elsewhere without force, then force succeeds (§5.3)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .alive;
    a.attached_elsewhere_first = true; // first ATTACH reports stolen
    try h.start();

    // First attempt: no force → attached_elsewhere, no pane (we do NOT auto-steal).
    var first = try h.conn.attachChannel("contended", 24, 80, 0, false);
    defer first.deinit();
    try testing.expect(first.attached_elsewhere);
    try testing.expect(first.pane == null);

    // Retry with force=true → the agent (n==1) no longer reports elsewhere; success.
    var second = try h.conn.attachChannel("contended", 24, 80, 0, true);
    defer second.deinit();
    try testing.expect(!second.attached_elsewhere);
    const pane = second.pane orelse return error.NoPane;
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, second.status);

    try testing.expectEqual(@as(u32, 2), a.attach_count.load(.monotonic));
    h.conn.closeChannel(pane);
}

test "FLOW pause: a full undrained ring makes the agent receive FLOW{channel, pause} (§4.3)" {
    const alloc = testing.allocator;
    // Small control/data loopback; a tiny-capacity channel so a little DATA fills it.
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    const conn = try Connection.createOpts(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
        .{ .heartbeat_interval_ms = 100_000 },
    );
    defer conn.destroy(alloc);

    var ctrl_agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer ctrl_agent.deinit();
    var data_agent = MockAgent.init(alloc, data_lb.agentStream(), .raw);
    defer data_agent.deinit();

    // Register a small channel directly (no pane needed for the pure FLOW path);
    // capacity 64, high_water 48 so ~48 undrained bytes trip the pause edge.
    const ch_id: u128 = 0xF10F10;
    var ch = try ring.Channel.init(alloc, ch_id, .{ .capacity = 64, .high_water = 48, .low_water = 8 });
    defer ch.deinit(alloc);
    try conn.registerChannel(&ch);

    // The control agent answers the handshake (and would PONG, but we never PING).
    var hctx = HandshakeAgentCtx{ .agent = &ctrl_agent };
    const cth = try std.Thread.spawn(.{}, HandshakeAgentCtx.run, .{&hctx});

    try conn.start();
    _ = try conn.waitHandshake();
    cth.join();

    // Drive enough DATA (never draining the ring) to cross high-water.
    const block = [_]u8{'x'} ** 16;
    var off: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try agentSendData(&data_agent, ch_id, off, &block);
        off += block.len;
    }

    // The client's data reader must emit exactly a FLOW{pause} for this channel on
    // the control lane. Read control frames until we see it.
    var saw_pause = false;
    var guard: usize = 0;
    while (!saw_pause) {
        guard += 1;
        if (guard > 1000) return error.NoFlowPause;
        const frame = (try ctrl_agent.nextFrame()) orelse break;
        if (frame.type == .flow) {
            const flow = try protocol.Flow.decode(frame.payload);
            try testing.expectEqual(ch_id, flow.channel);
            try testing.expectEqual(protocol.FlowOp.pause, flow.op);
            saw_pause = true;
        }
    }
    try testing.expect(saw_pause);

    conn.shutdown();
    conn.deregisterChannel(ch_id);
}

test "closeChannel sends CLOSE and deregisters; later DATA is dropped" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    try h.start();

    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80 });
    h.agent.saw_request.wait();
    const ch = pane.id;

    h.conn.closeChannel(pane);
    // The agent must receive a CLOSE frame.
    h.agent.close_detach_seen.wait();
    try testing.expect(h.agent.saw_close.load(.monotonic));
    try testing.expect(!h.agent.saw_detach.load(.monotonic));

    // A later DATA to that (now-unknown) channel id must be dropped, not crash.
    try agentSendData(&h.data_agent, ch, 0, "after-close");
    // Nudge the data reader a moment; nothing should crash (we can't read a freed
    // ring, but the connection's data reader simply drops the unknown channel).
    std.Thread.yield() catch {};
}

test "detachChannel sends DETACH (not CLOSE) and deregisters" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    try h.start();

    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80 });
    h.agent.saw_request.wait();
    const ch = pane.id;

    h.conn.detachChannel(pane);
    h.agent.close_detach_seen.wait();
    try testing.expect(h.agent.saw_detach.load(.monotonic));
    try testing.expect(!h.agent.saw_close.load(.monotonic));

    // Later DATA to the deregistered channel is dropped, no crash.
    try agentSendData(&h.data_agent, ch, 0, "after-detach");
    std.Thread.yield() catch {};
}

test "shutdown unblocks a parked OPEN caller with an error" {
    const alloc = testing.allocator;
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    const conn = try Connection.createOpts(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
        .{ .heartbeat_interval_ms = 100_000 },
    );
    defer conn.destroy(alloc);

    // An agent that handshakes but NEVER replies to OPEN, so the call parks.
    var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer agent.deinit();
    var hctx = HandshakeAgentCtx{ .agent = &agent };
    const ath = try std.Thread.spawn(.{}, HandshakeAgentCtx.run, .{&hctx});

    try conn.start();
    _ = try conn.waitHandshake();
    ath.join();

    // Park an openChannel on a background thread; shutdown must wake it with an err.
    const OpenCaller = struct {
        conn: *Connection,
        result: anyerror!void = {},
        done: std.Thread.ResetEvent = .{},
        fn run(s: *@This()) void {
            if (s.conn.openChannel(.{ .rows = 24, .cols = 80 })) |_| {
                s.result = error.UnexpectedSuccess;
            } else |e| {
                s.result = e;
            }
            s.done.set();
        }
    };
    var oc = OpenCaller{ .conn = conn };
    const oth = try std.Thread.spawn(.{}, OpenCaller.run, .{&oc});

    // Give the OPEN a moment to register its pending slot, then shut down.
    // (No reply will come; shutdown is what unblocks it.)
    conn.shutdown();
    oc.done.wait();
    oth.join();
    try testing.expectError(error.ConnectionClosed, oc.result);
}

// Pull in the ssh Transport test suite (§4.1) so `zig test src/remote/connection.zig`
// exercises the real `connection.Stream`-over-ssh implementation alongside the
// in-memory loopback transport tests above.
test {
    _ = @import("ssh_transport.zig");
}
