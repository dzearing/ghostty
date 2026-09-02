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

/// Callback for one pushed per-session CPU sample. `rows` BORROWS the decoded
/// arena and is valid only for the duration of the call — copy anything you keep.
/// `interval_ms` is the cadence the AGENT chose (it throttles itself under load),
/// not the one the client asked for. Fires on the control-reader thread.
pub const SessionCpuHandler = *const fn (
    ctx: *anyopaque,
    rows: []const protocol.SessionCpuRow,
    interval_ms: u32,
) void;

/// Callback for a pushed session roster. `json` is the raw `SESSIONS` payload,
/// borrowed for the duration of the call — the client decodes it with the same
/// path it uses for a `LIST_SESSIONS` reply, so pushed and polled rosters can
/// never diverge. Fires on the control-reader thread.
pub const SessionsHandler = *const fn (ctx: *anyopaque, json: []const u8) void;

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
    /// The frame type that actually satisfied this slot (filled by
    /// `deliverRpcReply` before `done.set()`). Normally equals `want`; it
    /// differs for the one reply that is legitimately a DIFFERENT type — a
    /// refused OPEN answers `.open_failed` to a slot waiting on `.opened`
    /// (T469), and the caller has to be able to tell the two apart before it
    /// parses the payload as an `Opened`.
    reply_type: protocol.FrameType = .hello,
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
    /// The child pid reported by OPENED / ATTACHED(alive) / RELAUNCHED (0 when
    /// the agent pre-dates the ATTACHED.pid field or the session has no child).
    pid: i64,
    /// The child's PTY slave path on the AGENT'S machine (wp3), duped and
    /// connection-owned (freed in `teardownPane`). Null when the agent didn't
    /// report one (older agent, Windows ConPTY, or a childless pane). NOTE: for
    /// a cross-machine connection this names a REMOTE tty — callers deciding to
    /// surface it locally (e.g. `+list --tty` matching) must gate on the
    /// connection being the local agent.
    tty: ?[]u8 = null,
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

    /// The absolute stream position of everything this connection has handed to
    /// the pane's ring — i.e. what the consumer's applied offset becomes once it
    /// has drained the ring empty (T739). Seeded to the offset the attach
    /// actually resumed from (0 for a fresh OPEN or a relaunch, which start a new
    /// stream at 0) and advanced from the DATA frames' own `byte_offset`, which
    /// is the position of record — NOT by counting bytes, because two of the
    /// things the agent sends are not stream bytes at all (`FrameType.data_repaint`).
    ///
    /// Monotonic: an injected repaint anchored below the position we have already
    /// covered leaves it alone. Advanced only by the bytes the ring actually
    /// ACCEPTED, so a push the ring had no room for (flow control failed to keep
    /// up) leaves the position short — the safe direction, which replays a byte
    /// twice rather than skipping it.
    ///
    /// Written by the data reader thread, read by the pane's IO thread; atomic
    /// for exactly that reason.
    stream_pos: std.atomic.Value(u64) = .init(0),

    /// The absolute stream position handed to the ring so far. See `stream_pos`.
    pub fn streamPos(self: *const Pane) u64 {
        return self.stream_pos.load(.acquire);
    }
};

/// Which kind of inbound frame the data lane delivered: the session's own byte
/// stream (`DATA`, 0x10) or an injected repaint the agent synthesized for this
/// attach (`DATA_REPAINT`, 0x15 — T739). Both are fed to the terminal; only the
/// first advances the stream position.
pub const InboundKind = enum { data, repaint };

/// The stream position after routing one inbound frame, given the position we
/// had (`current`), what the frame was anchored at, how many of its bytes the
/// ring ACCEPTED, and whether it was an injected repaint (T739).
///
/// Pure so the rule that decides the next re-attach's resume point is assertable
/// without a live agent, a ring, or a pane:
///
///   * a `data` frame's bytes ARE the stream, so it covers up to
///     `byte_offset + accepted`;
///   * a `repaint` frame's bytes are the agent's own paint anchored AT
///     `byte_offset`, so it covers up to `byte_offset` and no further —
///     this is the whole fix, and it cannot be inferred from the anchor
///     because the first LIVE frame after a repaint carries the same one;
///   * never backwards: a frame wholly below where we already are (a resync
///     leftover, a marker anchored at the resume point) leaves the position
///     alone rather than rewinding it into replayed history.
pub fn streamPosAfter(
    current: u64,
    byte_offset: u64,
    accepted: usize,
    repaint: bool,
) u64 {
    const covered = if (repaint) byte_offset else byte_offset +| accepted;
    return @max(current, covered);
}

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
    /// The offset this attach actually resumed from (T532) — the caller's
    /// `last_byte_offset`, except when that was AHEAD of the agent's stream
    /// head, in which case it is the head (`Connection.resumeOffset`). The
    /// caller MUST use this, not what it passed in, as the absolute base for
    /// its own applied-byte accounting: keeping the phantom base would put
    /// every later `appliedOffset()` — and the manifest entry written from it —
    /// back in the future, and the next restore would freeze again.
    resume_offset: u64 = 0,
    /// The session already had an attached bridge (§5.3). When true with
    /// `force=false`, the caller may retry `attachChannel(..., force=true)` to steal.
    attached_elsewhere: bool,
    /// Present iff `status == .dead` (tombstone exit code, §7.1/§7.4).
    exit_code: ?i64,
    /// Set (with `status == .dead`) when the dead session is a RELAUNCHABLE
    /// tombstone the agent materialized from disk at start (§5.4 reboot floor,
    /// T12b) — the recorded argv/cwd can respawn it via `relaunchChannel`. A
    /// genuinely-exited child leaves this false. The caller uses it to decide
    /// whether to auto-relaunch (T12c) instead of showing an exited overlay.
    relaunchable: bool = false,
    /// The agent-authoritative session channel the `ATTACHED` reply arrived on
    /// (`rpc.channel`). Retained even for a dead attach (where no pane/ring is
    /// kept) so the caller can address a follow-up `relaunchChannel` at the
    /// SAME channel the agent will stream the respawned session on.
    channel: u128 = 0,
    rows: u16,
    cols: u16,
    /// The geometry the session's ring tail was drawn at before this attach
    /// resized it (0 = unknown / older agent). The caller replays the gap-fill
    /// at this geometry and then reflows to the live pane so the geometry-bound
    /// raw ring bytes land correctly (T106; mirrors `RelaunchOutcome.replay_cols`).
    replay_rows: u16 = 0,
    replay_cols: u16 = 0,
    /// Duped from the reply and owned here (null when the reply omitted them).
    cwd: ?[]u8,
    title: ?[]u8,
    /// The command the session was running, as the agent's recorded label
    /// (`protocol.Attached.argv`). Only a DEAD reply carries it, and only from
    /// an agent new enough to send it — it exists so the `restore` relaunch
    /// policy (T230) can name the command it is deliberately NOT re-running.
    /// Display text: never parsed, never executed.
    argv: ?[]u8 = null,
    /// The FOREGROUND command the agent last sampled inside the session's
    /// shell (`protocol.Attached.foreground_cmd`, T429) — set for a plain
    /// shell pane whose `argv` is null because the user TYPED the command.
    /// The notice prefers this over `argv`; an older agent omits it. Display
    /// text, same rules as `argv`.
    fg_cmd: ?[]u8 = null,
    alloc: Allocator,

    /// Free any owned strings (`cwd`/`title`/`argv`/`fg_cmd`). Does NOT free
    /// `pane` — a live pane is torn down via `closeChannel`/`detachChannel`.
    pub fn deinit(self: *AttachOutcome) void {
        if (self.cwd) |c| self.alloc.free(c);
        if (self.title) |t| self.alloc.free(t);
        if (self.argv) |a| self.alloc.free(a);
        if (self.fg_cmd) |f| self.alloc.free(f);
        self.* = undefined;
    }
};

/// The outcome of `relaunchChannel` (§5.4 reboot floor, T12c). A `RELAUNCH`
/// respawns a dead-but-relaunchable session in place and streams FRESH output
/// from offset 0, so a live pane (`ok == true`) comes back with no resync
/// watermark (unlike an attach, which gap-fills a retained ring).
pub const RelaunchOutcome = struct {
    /// The live pane on `ok == true`; null otherwise. Torn down via
    /// `detachChannel`/`closeChannel` like any other pane.
    pane: ?*Pane,
    /// The session is alive under `pid` and streaming on its channel.
    ok: bool,
    /// The agent still has the session id. `ok == false, found == false` ⇒
    /// reaped/unknown (the caller may fall back to a fresh OPEN); `ok == false,
    /// found == true` ⇒ present but not relaunchable, or the respawn failed.
    found: bool,
    /// The respawned child pid (0 when `!ok`).
    pid: i64,
    /// The agent already replayed pre-restart scrollback + the restart divider from
    /// a ring disk snapshot (§5.4 reboot scrollback, T13); the caller should NOT
    /// print its own divider. False when the agent had no snapshot (blank relaunch).
    replayed: bool = false,
    /// The width/height the replayed scrollback was drawn at (0 = unknown). The
    /// caller replays at this width then reflows to the live pane so in-place
    /// prompt redraws in the raw stream don't smear (§5.4).
    replay_cols: u16 = 0,
    replay_rows: u16 = 0,
    /// The absolute stream offset at which the respawned child's OWN output
    /// starts, i.e. the size of everything the agent queued ahead of it (T1264).
    /// 0 = nothing replayed, or an agent too old to say. See
    /// `protocol.Relaunched.replay_bytes`.
    replay_bytes: u64 = 0,
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
            if (p.tty) |t| self.alloc.free(@constCast(t));
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
    /// True when the session is pinned against idle-TTL reaping (§7.1, T11).
    pinned: bool,
    /// True when the session is a relaunchable tombstone (materialized from disk
    /// at agent start, §5.4 reboot floor / T12b): `alive == false` but the recorded
    /// argv/cwd can revive it via RELAUNCH. A genuinely-exited child leaves this
    /// false (it carries an `exit_code` instead). Additive/optional — older agents
    /// omit the wire field, which decodes to false.
    relaunchable: bool = false,
    /// When the session last became continuously unattached (agent clock, ms),
    /// reported only while alive and unattached (T534). Null from an attached or
    /// dead row — and from an OLDER AGENT that never heard of the field, which is
    /// why every consumer treats null as "no clock", never as an error.
    unattached_since: ?i64 = null,
    /// True when the session's ConPTY, shell and kill-on-close job live in a
    /// separate `--pty-host` HOLDER process, so the shell outlives the agent
    /// (T905). What reads it is the non-destructive upgrade policy (T907): an
    /// agent can only replace itself once EVERY live session is holder-backed.
    /// Additive/optional — an older agent omits the wire field, which decodes to
    /// false, i.e. "legacy", which can only ever hold an upgrade back.
    holder_backed: bool = false,
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

    /// The peer's self-reported build stamp ("YYYYMMDD-<hash>") from its HELLO
    /// (null if the peer — an older agent — did not send one). Same write/read
    /// ordering and ownership as `peer_hostname`. The app compares it to the
    /// build it bundles to detect a stale local agent and lazily refresh it.
    peer_build_version: ?[:0]u8 = null,

    /// The `proto_version` the peer advertised in its HELLO, or null when no
    /// HELLO was ever parsed (dropped stream, garbage payload). Same write/read
    /// ordering as `peer_hostname`, with one deliberate difference: this one is
    /// captured so it survives a handshake that FAILED, because that is the only
    /// case it exists for. `negotiate` reports an incompatible pair as a bare
    /// `error.Incompatible`, which cannot say which side is behind — and killing
    /// the local agent to "fix" a skew where the AGENT is the newer side would be
    /// a silent downgrade (T125).
    peer_proto_version: ?u16 = null,

    /// The pty flavour the peer said its children run on (T471), or null when it
    /// did not say / named one this build does not know. Same write/read
    /// ordering as `peer_hostname`. A remote pane's terminal reads it to decide
    /// whether its resizes need the ConPTY scrollback guard, which on a cross-OS
    /// pane is not the same question as "am I running on Windows".
    peer_pty_flavor: ?protocol.PtyFlavor = null,

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
    session_cpu_handler: ?SessionCpuHandler = null,
    session_cpu_handler_ctx: *anyopaque = undefined,
    sessions_handler: ?SessionsHandler = null,
    sessions_handler_ctx: *anyopaque = undefined,

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

    /// The capabilities this app-side client advertises in its HELLO. Injected in
    /// `createOpts` when the caller left `local_hello.capabilities` empty (every
    /// dial path today), so ALL client connections advertise them regardless of
    /// transport. Additive: the agent negotiates the intersection and an older
    /// agent that doesn't advertise `close_session` simply leaves it disabled.
    /// `grid_snapshot` asks a modern agent to append a visible-screen repaint on
    /// re-attach (FIX 2); an older agent that never advertises it just replays its
    /// ring as before.
    /// `session_cpu` asks a modern agent for the pushed per-session CPU roll-up
    /// the chooser's meters render; an older agent never advertises it, the
    /// negotiated flag stays false, and we never send the opcode (which that agent
    /// would treat as a fatal framing error) — the meters just don't appear.
    /// `cpu_units` says this client understands (and itself produces) corrected
    /// `cpu_pct` units; the half that matters is the AGENT's matching string,
    /// whose absence tells the Activity Monitor that a remote `% CPU` may be
    /// ~24× low and must not be rendered as fact.
    pub const client_capabilities = [_][]const u8{
        protocol.capability.close_session,
        protocol.capability.grid_snapshot,
        protocol.capability.session_cpu,
        protocol.capability.sessions_push,
        protocol.capability.cpu_units,
        // We hand the agent a short prelude (`RELAUNCH.notice`) to splice into
        // the replay ahead of the respawned child's first byte, which is the only
        // slot where undoing the replay's re-armed VT modes cannot race that
        // child (T824). An older agent ignores it and we inject locally instead.
        protocol.capability.relaunch_notice,
        // We consume `META{has_descendants}` for the close confirmation (T356).
        // Advertising it is what tells the agent the sampling is worth doing.
        protocol.capability.session_busy,
        // We understand `OPEN_FAILED` (0x06), so a modern agent can refuse an
        // OPEN out loud instead of dropping it and leaving us to discover it as
        // `error.Timeout` ten seconds later (T469). An older agent never
        // advertises it, the negotiated flag stays false, and we keep the
        // timeout — the pane just takes the slow road to the same failure.
        protocol.capability.open_failed,
        // ...and `ATTACH_FAILED` (0x07), the same courtesy on the resume path
        // (T657). Same skew story: absent ⇒ the 10 s timeout we always had.
        protocol.capability.attach_failed,
        // We understand `DATA_REPAINT` (0x15), so a modern agent can tell us
        // which of the bytes it sends on ATTACH are its own repaint rather than
        // the session's stream (T739). An older agent sends them as plain DATA
        // and we count them, exactly as before — a resume point past the head,
        // which the T532 clamp then pulls back.
        protocol.capability.repaint_data,
        // We know that a handoff-capable agent replaces ITSELF when a newer
        // build lands beside it, carrying every holder-backed session across
        // (T907). Advertising it is what lets that agent's peer stand down
        // instead of restarting it destructively; an older agent never
        // advertises the other half, the negotiated flag stays false, and the
        // caller keeps its pre-T907 policy.
        protocol.capability.agent_handoff,
    };

    /// `create` with explicit health/heartbeat tunables (increment 2).
    ///
    /// THREAD-SAFETY INVARIANT: `alloc` MUST be thread-safe. `start` spawns the
    /// writer + two reader + heartbeat threads, and all of them (plus the caller's
    /// own RPC calls) allocate/free through this same allocator with no additional
    /// serialization. The GUI passes the app's thread-safe GPA/`c_allocator`. A CLI
    /// dialer must NOT pass a bare `ArenaAllocator`/`FixedBufferAllocator` — wrap it
    /// in a `std.heap.ThreadSafeAllocator` first (see `cli/sessions.zig`), or the
    /// arena's bookkeeping races corrupt the heap and crash in `rpcCall`.
    pub fn createOpts(
        alloc: Allocator,
        control: Stream,
        data: Stream,
        local_hello: protocol.Hello,
        opts: Options,
    ) !*Connection {
        const self = try alloc.create(Connection);
        errdefer alloc.destroy(self);
        // Advertise the app-side capabilities. Preserve any the caller set
        // explicitly; otherwise inject the client default so every dial path
        // (tcp/ssh/relay/mux) negotiates `close_session` with a modern agent.
        var hello = local_hello;
        if (hello.capabilities.len == 0) hello.capabilities = &client_capabilities;
        // Say what kind of pty WE spawn children on (T471). The agent has no use
        // for it today — the flow that matters is the other direction, an agent
        // telling us about the child it owns — but the field means one thing in
        // both directions, and a future agent that wants it should not need a
        // second wire change to get it. Statically-known string; costs a few
        // bytes in a frame sent once per connection.
        if (hello.pty_flavor == null) hello.pty_flavor = protocol.PtyFlavor.local.toString();
        self.* = .{
            .alloc = alloc,
            .control = control,
            .data = data,
            .local_hello = hello,
            .encoding = hello.transfer_encoding,
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

    /// Subscribe to the pushed session ROSTER. The agent sends a `sessions`
    /// frame immediately and then on every change (create, exit, close, attach,
    /// detach) — so the client never polls and can never render a session that
    /// has already exited.
    ///
    /// `error.Unsupported` when the peer did not advertise `sessions_push`; the
    /// caller then keeps its `LIST_SESSIONS` poll. Never sends the opcode to
    /// such a peer (an unknown opcode is a fatal framing error).
    pub fn subscribeSessions(
        self: *Connection,
        ctx: *anyopaque,
        handler: SessionsHandler,
    ) !void {
        if (self.negotiated) |n| {
            if (!n.sessions_push) return error.Unsupported;
        } else |_| return error.Unsupported;

        {
            self.sessions_handler_ctx = ctx;
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            self.sessions_handler = handler;
        }
        try self.writeControl(.sessions_sub, protocol.control_channel, "{}");
    }

    /// Stop the pushed roster and clear the handler; no callback fires after
    /// this returns. Safe when not subscribed and against an older agent.
    pub fn unsubscribeSessions(self: *Connection) void {
        const supported = if (self.negotiated) |n| n.sessions_push else |_| false;
        if (supported) {
            self.writeControl(.sessions_unsub, protocol.control_channel, "{}") catch {};
        }
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.sessions_handler = null;
    }

    /// Subscribe to the pushed per-session CPU stream. `interval_ms` is a HINT —
    /// the agent floors it and stretches it under its own load, reporting what it
    /// actually used in each callback.
    ///
    /// Returns `error.Unsupported` when the peer did not advertise
    /// `capability.session_cpu`. That check is NOT optional politeness: an
    /// unknown opcode is a fatal framing error to an older agent, so sending
    /// `session_cpu_sub` blind would kill a working connection. Callers treat
    /// `Unsupported` as "show no meter".
    ///
    /// The handler fires on the control-reader thread. The caller MUST call
    /// `unsubscribeSessionCpu` before freeing `ctx`.
    pub fn subscribeSessionCpu(
        self: *Connection,
        interval_ms: u32,
        ctx: *anyopaque,
        handler: SessionCpuHandler,
    ) !void {
        if (self.negotiated) |n| {
            if (!n.session_cpu) return error.Unsupported;
        } else |_| return error.Unsupported;

        // Publish the handler slot BEFORE subscribing so the first pushed frame
        // is never dropped for lack of a handler.
        {
            self.session_cpu_handler_ctx = ctx;
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            self.session_cpu_handler = handler;
        }

        const sub: protocol.SessionCpuSub = .{ .interval_ms = interval_ms };
        const json = try protocol.encodeJson(self.alloc, sub);
        defer self.alloc.free(json);
        try self.writeControl(.session_cpu_sub, protocol.control_channel, json);
    }

    /// Stop the pushed per-session CPU stream and clear the handler slot, so no
    /// further callback fires after this returns. Safe when not subscribed, and
    /// safe against an older agent (we simply never send the gated opcode).
    pub fn unsubscribeSessionCpu(self: *Connection) void {
        const supported = if (self.negotiated) |n| n.session_cpu else |_| false;
        if (supported) {
            const json = protocol.encodeJson(self.alloc, protocol.SessionCpuUnsub{}) catch null;
            if (json) |j| {
                defer self.alloc.free(j);
                self.writeControl(.session_cpu_unsub, protocol.control_channel, j) catch {};
            }
        }

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.session_cpu_handler = null;
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

    /// True while any of this connection's own threads is still unjoined. Read
    /// under `state_mutex` because `shutdown` claims the handles under it.
    fn threadsLive(self: *Connection) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.writer_thread != null or
            self.control_thread != null or
            self.data_thread != null or
            self.heartbeat_thread != null;
    }

    /// Free the connection. `shutdown` is the caller's job and normally ran
    /// already; when it did not, `destroy` runs it here rather than asserting.
    ///
    /// It used to assert instead, and an assert is the wrong instrument for
    /// this: it fires only when a thread happens to still be live at teardown,
    /// which makes it a crash in Debug and silence — a use-after-free, since
    /// the reader keeps pushing into memory the caller is about to free — in
    /// ReleaseFast. An error path that returns before `shutdown` is easy to
    /// write and the failure surfaces far away from it (T693).
    pub fn destroy(self: *Connection, alloc: Allocator) void {
        if (self.threadsLive()) self.shutdown();

        // Defensive: ensure no thread is still live and the queue is drained.
        assert(self.writer_thread == null);
        assert(self.control_thread == null);
        assert(self.data_thread == null);
        assert(self.heartbeat_thread == null);
        self.write_queue.deinit(alloc);
        self.channels.deinit();
        if (self.peer_hostname) |h| alloc.free(h);
        if (self.peer_build_version) |v| alloc.free(v);
        // Any panes still registered at destroy (the caller didn't close/detach
        // them) are freed here so the connection owns no leaks. Their channels were
        // already deregistered-or-irrelevant since all threads have joined.
        // Through the SAME helper `teardownPane` uses, deliberately: this loop was
        // a hand-copy of that free list and had already drifted from it — it never
        // freed `pane.tty`, so a connection dropped while an attached pane carried
        // an agent-side tty path leaked it (T811).
        var it = self.panes.iterator();
        while (it.next()) |entry| self.freePaneOwned(entry.value_ptr.*);
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
        return self.openChannelRefusable(open, canceller, null);
    }

    /// `openChannelCancellable` that also reports WHY the agent refused.
    ///
    /// When the agent answers `OPEN_FAILED` (0x06) this returns
    /// `error.OpenRefused` and, if `refusal` is non-null, fills it with the
    /// reason token and detail. A Zig error carries no payload, so the reason
    /// travels beside the error in a caller-owned struct rather than in a heap
    /// allocation every error path would have to remember to free.
    ///
    /// Every other failure is unchanged, `error.Timeout` included: an agent too
    /// old to advertise `capability.open_failed` never sends the frame, so a
    /// refusal there still surfaces as the 10 s timeout it always did, with
    /// `refusal` untouched. Callers must therefore treat a filled `refusal` as
    /// "known reason" and its absence as "no more than we knew before".
    pub fn openChannelRefusable(
        self: *Connection,
        open: protocol.Open,
        canceller: ?*const RpcCanceller,
        refusal: ?*protocol.RefusalCopy,
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

        // The agent refused, and said so (T469). Nothing was created — no
        // session, no channel, nothing registered — so there is nothing to undo
        // here; we only carry the reason out to whoever can show it.
        //
        // A payload we cannot parse is still a refusal: a newer agent could add
        // fields, and degrading a "refused, reason unknown" into a 10 s timeout
        // would be strictly worse than saying so generically.
        if (rpc.type == .open_failed) {
            if (refusal) |out| {
                if (protocol.parseJson(protocol.OpenFailed, self.alloc, rpc.payload)) |p| {
                    defer p.deinit();
                    out.set(p.value.reason, p.value.detail);
                } else |_| {
                    out.set("unparseable", null);
                }
            }
            return error.OpenRefused;
        }

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
        const tty: ?[]u8 = if (parsed.value.tty) |t| try self.alloc.dupe(u8, t) else null;
        errdefer if (tty) |t| self.alloc.free(t);

        const pane = try self.alloc.create(Pane);
        errdefer self.alloc.destroy(pane);
        pane.* = .{
            .id = id,
            .session_id = session_id,
            .pid = parsed.value.pid,
            .tty = tty,
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
                if (p.tty) |t| self.alloc.free(@constCast(t));
            }
            self.alloc.free(procs);
        }
        for (src, 0..) |p, i| {
            const name = try self.alloc.dupe(u8, p.name);
            errdefer self.alloc.free(name);
            const user: ?[]const u8 = if (p.user) |u| try self.alloc.dupe(u8, u) else null;
            errdefer if (user) |u| self.alloc.free(u);
            const cmd: ?[]const u8 = if (p.cmd) |c| try self.alloc.dupe(u8, c) else null;
            errdefer if (cmd) |c| self.alloc.free(c);
            const tty: ?[]const u8 = if (p.tty) |t| try self.alloc.dupe(u8, t) else null;
            procs[i] = .{
                .pid = p.pid,
                .ppid = p.ppid,
                .name = name,
                .cpu_pct = p.cpu_pct,
                .mem_bytes = p.mem_bytes,
                .user = user,
                .cmd = cmd,
                .tty = tty,
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
                .pinned = s.pinned,
                .relaunchable = s.relaunchable,
                .unattached_since = s.unattached_since,
                .holder_backed = s.holder_backed,
            };
            filled = i + 1;
        }

        return .{ .sessions = out, .alloc = self.alloc };
    }

    /// Push (or, with `delete`, remove) an OPAQUE per-window layout blob to the
    /// agent (§5.4 cross-machine "Resume all", T18). Sends `SET_LAYOUT{key, blob,
    /// session_ids, delete}` and awaits `SET_LAYOUT_RESULT{ok}`. Same-channel RPC
    /// (mirrors `queryCwdTimeout`), bounded by `timeout_ns`. Returns
    /// `error.SetLayoutFailed` when the agent reports `ok == false`.
    pub fn setLayout(
        self: *Connection,
        key: []const u8,
        blob: ?[]const u8,
        session_ids: []const []const u8,
        delete: bool,
        timeout_ns: u64,
    ) !void {
        const req_channel = std.crypto.random.int(u128);
        const set: protocol.SetLayout = .{
            .key = key,
            .blob = blob,
            .session_ids = session_ids,
            .delete = delete,
        };
        const json = try protocol.encodeJson(self.alloc, set);
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .set_layout, .set_layout_result, json, timeout_ns, null);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.SetLayoutResult, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();
        if (!parsed.value.ok) return error.SetLayoutFailed;
    }

    /// Fire-and-forget `SET_LAYOUT`: the same frame as `setLayout`, but it does
    /// NOT register an RPC slot and does not wait for the ack (the agent's
    /// `SET_LAYOUT_RESULT` lands on a channel nobody claimed and is dropped —
    /// see the `.set_layout_result` arm of the control reader). Mirrors
    /// `closeSessionNoWait`, and for the same reason.
    ///
    /// The caller is a UI thread mirroring its window topology as housekeeping
    /// (win32's `App.syncSessionLayout`, T334): it pushes one frame per window
    /// on every layout mutation, does nothing with the answer, and must not
    /// stall a repaint on an agent hiccup — a bounded RPC there would cost the
    /// whole timeout, per window, in front of a user who is dragging a split.
    /// `enqueue` only appends to the writer thread's queue, so this never
    /// touches the socket on the calling thread.
    ///
    /// Ungated by design: unlike `close_session`, the `SET_LAYOUT`/`GET_LAYOUTS`
    /// opcodes shipped in the same commit as the agent handler that answers them
    /// (43bfb8e4a, 2026-07-16), which predates every `ghoztty-agent` binary that
    /// has ever run on Windows — so there is no skew window in which a peer
    /// could see this opcode as unknown.
    pub fn setLayoutNoWait(
        self: *Connection,
        key: []const u8,
        blob: ?[]const u8,
        session_ids: []const []const u8,
        delete: bool,
    ) !void {
        const set: protocol.SetLayout = .{
            .key = key,
            .blob = blob,
            .session_ids = session_ids,
            .delete = delete,
        };
        const json = try protocol.encodeJson(self.alloc, set);
        defer self.alloc.free(json);
        try self.writeControl(.set_layout, std.crypto.random.int(u128), json);
    }

    /// Fetch every stored layout blob (§5.4 "Resume all", T18). Sends
    /// `GET_LAYOUTS{}` and awaits `LAYOUTS{layouts:[...]}`, returning the RAW reply
    /// payload JSON duped into `self.alloc` (the caller — the Swift resumer —
    /// decodes the `{layouts:[{key,blob}]}` shape and the opaque blobs itself, so
    /// there is no need to deep-copy into an `Owned*` struct here). Caller frees.
    /// Same-channel RPC, bounded by `timeout_ns`.
    pub fn requestLayouts(self: *Connection, timeout_ns: u64) ![]u8 {
        const req_channel = std.crypto.random.int(u128);
        const json = try protocol.encodeJson(self.alloc, protocol.GetLayouts{});
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .get_layouts, .layouts, json, timeout_ns, null);
        // Validate it parses (a malformed reply is an error, not a passthrough),
        // but hand back the raw bytes for the caller to decode.
        var parsed = protocol.parseJson(protocol.Layouts, self.alloc, rpc.payload) catch {
            self.alloc.free(rpc.payload);
            return error.MalformedReply;
        };
        parsed.deinit();
        return rpc.payload;
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

    /// The resume point an ATTACH may honor, given what the client believes it
    /// has applied (`last_byte_offset`) and where the agent says its outbound
    /// stream actually is (`ATTACHED.snapshot_at_offset`). T532.
    ///
    /// A client can never legitimately have applied MORE bytes than the agent
    /// has ever produced, so `last_byte_offset > agent_head` is not a resume —
    /// it is proof that the two are talking about different streams. That
    /// happens for real: a session id survives an agent restart, and the child
    /// relaunched under it starts a FRESH byte stream at 0, while a manifest
    /// written before the restart still records the old stream's offset.
    ///
    /// Honoring such an offset arms the §7.3 discard watermark above every byte
    /// the agent will ever send, so `routeInboundData` drops the agent's grid
    /// snapshot and then all live output, permanently, and `resync_active`
    /// never disarms. The pane still paints (the viewer replays its OWN
    /// persisted snapshot) and input still reaches the child, which is why the
    /// failure reads as "restored correctly, then non-interactive and not
    /// painting, but seemed to still be working" rather than as a blank pane or
    /// an error — the exact report from 2026-08-06.
    ///
    /// A head of 0 never clamps. It is ambiguous — a session that has produced
    /// nothing, or a peer too old to report one — and a wrong clamp there would
    /// re-deliver bytes the client already has. This guard exists to fix a
    /// freeze, not to trade it for a double-paint.
    pub fn resumeOffset(last_byte_offset: u64, agent_head: u64) u64 {
        if (agent_head == 0) return last_byte_offset;
        return @min(last_byte_offset, agent_head);
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
        return self.attachChannelRefusable(session_id, rows, cols, last_byte_offset, force, canceller, null);
    }

    /// `attachChannelCancellable` that also reports WHY the agent could not
    /// answer (T657), the `openChannelRefusable` shape exactly.
    ///
    /// When the agent answers `ATTACH_FAILED` (0x07) this returns
    /// `error.AttachRefused` and, if `refusal` is non-null, fills it with the
    /// reason token and detail.
    ///
    /// Note what does NOT come back this way: `not_found`, `dead` and
    /// `attached_elsewhere` are ordinary `AttachOutcome`s carrying that status
    /// — they always were, they arrive at once, and the client renders the
    /// user-facing reason from the status itself. This error is for the
    /// refusals no `Attached` payload could describe.
    ///
    /// Every other failure is unchanged, `error.Timeout` included: an agent too
    /// old to advertise `capability.attach_failed` never sends the frame, so
    /// such a refusal still surfaces as the 10 s timeout it always did, with
    /// `refusal` untouched.
    pub fn attachChannelRefusable(
        self: *Connection,
        session_id: []const u8,
        rows: u16,
        cols: u16,
        last_byte_offset: u64,
        force: bool,
        canceller: ?*const RpcCanceller,
        refusal: ?*protocol.RefusalCopy,
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

        // The agent could not answer, and said so (T657). Nothing was attached
        // — no channel, no ring, nothing registered — so there is nothing to
        // undo; we only carry the reason out to whoever can show it.
        //
        // A payload we cannot parse is still a refusal: a newer agent could add
        // fields, and degrading a "refused, reason unknown" into a 10 s timeout
        // would be strictly worse than saying so generically.
        if (rpc.type == .attach_failed) {
            if (refusal) |out| {
                if (protocol.parseJson(protocol.AttachFailed, self.alloc, rpc.payload)) |p| {
                    defer p.deinit();
                    out.set(p.value.reason, p.value.detail);
                } else |_| {
                    out.set("unparseable", null);
                }
            }
            return error.AttachRefused;
        }

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
        const argv = if (a.argv) |v| try self.alloc.dupe(u8, v) else null;
        errdefer if (argv) |v| self.alloc.free(v);
        const fg_cmd = if (a.foreground_cmd) |v| try self.alloc.dupe(u8, v) else null;
        errdefer if (fg_cmd) |v| self.alloc.free(v);

        // T532: what this attach will actually resume from. Equal to
        // `last_byte_offset` in every healthy case; clamped to the agent's head
        // when the caller's record belongs to a stream that no longer exists.
        // This module is the pure transport and does not log; the caller
        // (`termio.Remote`) compares `resume_offset` against what it passed and
        // says so out loud.
        const resume_at = resumeOffset(last_byte_offset, a.snapshot_at_offset);

        var outcome: AttachOutcome = .{
            .pane = null,
            .status = a.status,
            .snapshot_at_offset = a.snapshot_at_offset,
            .resume_offset = resume_at,
            .attached_elsewhere = a.attached_elsewhere,
            .exit_code = a.exit_code,
            .relaunchable = a.relaunchable,
            .channel = id,
            .rows = a.rows,
            .cols = a.cols,
            .replay_rows = a.replay_rows,
            .replay_cols = a.replay_cols,
            .cwd = cwd,
            .title = title,
            .argv = argv,
            .fg_cmd = fg_cmd,
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
        const pane_tty: ?[]u8 = if (a.tty) |t| try self.alloc.dupe(u8, t) else null;
        errdefer if (pane_tty) |t| self.alloc.free(t);
        const pane = try self.alloc.create(Pane);
        errdefer self.alloc.destroy(pane);
        pane.* = .{
            .id = id,
            .session_id = sid,
            // pid/tty ride ATTACHED for a live session (wp3); 0/null from an
            // older agent that pre-dates the fields.
            .pid = a.pid,
            .tty = pane_tty,
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
            //
            // T532: anchored at `resume_at`, not at the raw `last_byte_offset` —
            // a resume point above the agent's own head is a different stream,
            // and arming it discards every byte the agent will ever send.
            .discard_below = if (resume_at > 0) resume_at - 1 else 0,
            .resync_active = resume_at > 0,
            // T739: the position this attach resumes from is the position the
            // consumer starts at, and it is `resume_at` — the offset the agent
            // HONORED — for the same reason `discard_below` is: a clamped attach
            // is talking about a different stream than the one the caller asked
            // to resume.
            .stream_pos = .init(resume_at),
        };
        try self.trackPane(pane);
        keep_channel = true; // the pane now owns the registered ring
        outcome.pane = pane;
        return outcome;
    }

    /// Respawn-fidelity payload for a `RELAUNCH` (wp3): the viewer's live copy
    /// of what the agent's on-disk record lacks — the forwarded env allowlist
    /// (GHOZTTY_PANE_ID / GHOZTTY_WINDOW_NAME / shell-integration vars), the
    /// TERM value, and the explicit shell-integration argv rewrite. Borrowed
    /// for the duration of the call. All optional: `.{}` sends none (an older
    /// agent ignores them anyway).
    pub const RelaunchFidelity = struct {
        env: []const protocol.Open.EnvPair = &.{},
        term: ?[]const u8 = null,
        argv: ?[]const []const u8 = null,
        /// Bytes for the agent to append to the ring ahead of the replay (see
        /// `protocol.Relaunch.notice`). Only meaningful when
        /// `supportsRelaunchNotice()`; the caller is responsible for injecting
        /// them locally instead when that is false.
        notice: ?[]const u8 = null,
    };

    /// Respawn a dead-but-relaunchable session on its known `channel` (§5.4 reboot
    /// floor, T12c) and, on success, register the inbound ring + return a live pane.
    ///
    /// `channel` MUST be the agent-authoritative session channel a prior dead
    /// `ATTACHED` reply arrived on (`AttachOutcome.channel`): the agent echoes
    /// `RELAUNCHED` — and then streams the respawned session's DATA — on that same
    /// channel. We PRE-REGISTER the ring on it before sending `RELAUNCH` (the note in
    /// `attachChannelCancellable`) so no early output is dropped in the window
    /// between the reply and ring registration, then keep it only on `ok`.
    ///
    /// A relaunch is a FRESH stream: the pane is created with `discard_below = 0`
    /// and `resync_active = false` (no gap-fill replay, unlike an attach) so the
    /// caller applies the respawned session's output from byte 0.
    pub fn relaunchChannel(
        self: *Connection,
        session_id: []const u8,
        channel: u128,
        rows: u16,
        cols: u16,
        px_w: u16,
        px_h: u16,
    ) !RelaunchOutcome {
        return self.relaunchChannelCancellable(session_id, channel, rows, cols, px_w, px_h, .{}, null);
    }

    /// `relaunchChannel` with an optional cancellation token (see `RpcCanceller`),
    /// so surface teardown can wake a pane's IO thread out of a parked `RELAUNCH`.
    ///
    /// This is the `.auto` policy's one-shot path: prepare the pane, send `RELAUNCH`,
    /// and return the live pane (or null + torn-down channel on a non-ok reply). The
    /// `.prompt` policy (T12c2) instead splits these across a user consent step,
    /// calling `prepareRelaunchPane` up front and `sendRelaunchOnPane` on a keystroke.
    pub fn relaunchChannelCancellable(
        self: *Connection,
        session_id: []const u8,
        channel: u128,
        rows: u16,
        cols: u16,
        px_w: u16,
        px_h: u16,
        fidelity: RelaunchFidelity,
        canceller: ?*const RpcCanceller,
    ) !RelaunchOutcome {
        const pane = try self.prepareRelaunchPane(session_id, channel);
        // Any failure below (a transport/RPC error) returns the pre-registered ring
        // + pane to a clean state so the channel table is not left dangling.
        errdefer self.teardownPane(pane);
        const res = try self.sendRelaunchOnPane(pane, rows, cols, px_w, px_h, fidelity, canceller);
        if (!res.ok) {
            // Not respawned (reaped, not relaunchable, or spawn failed): keep no pane
            // and tear the pre-registered channel back down (a value return does not
            // fire the `errdefer` above).
            self.teardownPane(pane);
            return .{ .pane = null, .ok = false, .found = res.found, .pid = res.pid, .replayed = res.replayed, .replay_cols = res.replay_cols, .replay_rows = res.replay_rows, .replay_bytes = res.replay_bytes };
        }
        return .{ .pane = pane, .ok = true, .found = true, .pid = res.pid, .replayed = res.replayed, .replay_cols = res.replay_cols, .replay_rows = res.replay_rows, .replay_bytes = res.replay_bytes };
    }

    /// Register the inbound ring + a `Pane` for a session about to be relaunched,
    /// WITHOUT sending `RELAUNCH` yet. The pane has no live child (pid 0) until a
    /// later `sendRelaunchOnPane` succeeds. Used by the `.prompt` relaunch policy
    /// (T12c2): the client brings up a live-but-childless pane showing an
    /// "awaiting relaunch" prompt, then respawns the recorded process only once the
    /// user consents with a keystroke. Pre-registering the ring on the agent's known
    /// session channel means the respawned session's first DATA frames (the fresh
    /// shell prompt) are not dropped in the gap between `RELAUNCHED` and ring
    /// registration. Tear down via `detachChannel`/`closeChannel` (or
    /// `sendRelaunchOnPane`'s failure handling) like any other pane.
    pub fn prepareRelaunchPane(
        self: *Connection,
        session_id: []const u8,
        channel: u128,
    ) !*Pane {
        const ch = try self.alloc.create(ring.Channel);
        errdefer self.alloc.destroy(ch);
        ch.* = try ring.Channel.init(self.alloc, channel, .{});
        errdefer ch.deinit(self.alloc);
        try self.registerChannel(ch);
        errdefer self.deregisterChannel(channel);

        const sid = try self.alloc.dupe(u8, session_id);
        errdefer self.alloc.free(sid);
        const pane = try self.alloc.create(Pane);
        errdefer self.alloc.destroy(pane);
        pane.* = .{
            .id = channel,
            .session_id = sid,
            // No child yet; `sendRelaunchOnPane` fills the pid on a successful respawn.
            .pid = 0,
            .ring = ch,
            // A relaunch streams from offset 0 — no resync watermark, keep every byte.
            .discard_below = 0,
            .resync_active = false,
        };
        try self.trackPane(pane);
        return pane;
    }

    /// The result of `sendRelaunchOnPane`: whether the respawn succeeded, whether the
    /// agent still had the session, and the (respawned) child pid. Unlike
    /// `RelaunchOutcome` this carries no pane — `sendRelaunchOnPane` operates on a pane
    /// the caller already prepared and still owns.
    pub const RelaunchResult = struct { ok: bool, found: bool, pid: i64, replayed: bool = false, replay_cols: u16 = 0, replay_rows: u16 = 0, replay_bytes: u64 = 0 };

    /// Send `RELAUNCH` for an already-prepared pane (see `prepareRelaunchPane`) and
    /// await `RELAUNCHED`. On `ok`, the recorded process is respawned and streaming on
    /// the pane's channel (the pane's `pid` is updated). On `!ok` the pane is left
    /// intact (still childless) so the caller can surface a "relaunch failed" note and
    /// tear it down on threadExit. Correlates on the pane's channel (the agent replies
    /// RELAUNCHED on the session's own channel, which is the one we send on). Cancellable
    /// so surface teardown can wake the IO thread out of a parked `RELAUNCH`.
    pub fn sendRelaunchOnPane(
        self: *Connection,
        pane: *Pane,
        rows: u16,
        cols: u16,
        px_w: u16,
        px_h: u16,
        fidelity: RelaunchFidelity,
        canceller: ?*const RpcCanceller,
    ) !RelaunchResult {
        const req: protocol.Relaunch = .{
            .session_id = pane.session_id,
            .rows = rows,
            .cols = cols,
            .px_w = px_w,
            .px_h = px_h,
            .env = fidelity.env,
            .term = fidelity.term,
            .argv = fidelity.argv,
            .notice = fidelity.notice,
        };
        const json = try protocol.encodeJson(self.alloc, req);
        defer self.alloc.free(json);
        const rpc = try self.rpcCall(pane.id, .relaunch, .relaunched, json, self.rpc_open_timeout_ns, canceller);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.Relaunched, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();
        const r = parsed.value;
        if (r.ok) {
            pane.pid = r.pid;
            // A relaunch opened a FRESH pty (wp3): replace any stale tty with the
            // reported one (null from an older agent leaves the field cleared —
            // the old path is definitely wrong now).
            const new_tty: ?[]u8 = if (r.tty) |t| self.alloc.dupe(u8, t) catch null else null;
            if (pane.tty) |t| self.alloc.free(t);
            pane.tty = new_tty;
        }
        return .{ .ok = r.ok, .found = r.found, .pid = r.pid, .replayed = r.replayed, .replay_cols = r.replay_cols, .replay_rows = r.replay_rows, .replay_bytes = r.replay_bytes };
    }

    /// True iff the negotiated peer advertised the `close_session` capability —
    /// i.e. `closeSession` is safe to send (the agent understands the opcode). An
    /// older agent (or a not-yet-completed / failed handshake) reports false, so
    /// the caller falls back rather than emitting an opcode the peer would treat as
    /// a fatal framing error.
    pub fn supportsCloseSession(self: *Connection) bool {
        if (self.negotiated) |n| return n.close_session else |_| return false;
    }

    /// True iff the negotiated peer advertised `capability.relaunch_notice` —
    /// i.e. `RelaunchFidelity.notice` will be appended to the ring ahead of the
    /// replay, landing between the restored scrollback and the respawned child's
    /// first output. False for an older agent (or an incomplete/failed
    /// handshake), in which case the caller must inject those bytes into its own
    /// terminal instead.
    pub fn supportsRelaunchNotice(self: *Connection) bool {
        if (self.negotiated) |n| return n.relaunch_notice else |_| return false;
    }

    /// True iff the negotiated peer advertised `capability.grid_snapshot` — i.e.
    /// every ATTACH is followed by a self-contained repaint of the session's
    /// CURRENT visible screen (`agent/grid_snapshot.zig`), which homes to row 1
    /// and erases the display before it draws.
    ///
    /// The client needs to know this BEFORE it paints anything of its own: a
    /// repaint that is certain to arrive is what makes it safe to park a restored
    /// screen into scrollback rather than leave it on the viewport for that
    /// repaint to overwrite (T666). False for an older agent and for a handshake
    /// that has not completed, which is the safe direction — no repaint is
    /// promised, so nothing is parked.
    pub fn peerRepaintsOnAttach(self: *Connection) bool {
        if (self.negotiated) |n| return n.grid_snapshot else |_| return false;
    }

    /// True iff the peer negotiated `capability.repaint_data` — i.e. it FRAMES
    /// the repaints it injects (`DATA_REPAINT`, 0x15) instead of letting them
    /// ride ordinary DATA, so their bytes are known not to advance the stream
    /// position (T739). False for an older agent and for a handshake that has
    /// not landed, which is the pre-T739 wire and stays safe.
    pub fn peerLabelsRepaints(self: *Connection) bool {
        if (self.negotiated) |n| return n.repaint_data else |_| return false;
    }

    /// True iff the peer advertised `capability.cpu_units` — i.e. every `cpu_pct`
    /// it reports is in CORRECTED units and may be shown as fact.
    ///
    /// False for a pre-fix agent (whose macOS per-process percentages are ~24×
    /// low on Apple Silicon) AND for a handshake that hasn't completed or failed,
    /// which is the safe direction: the caller marks the number unverifiable
    /// rather than printing it. Never rescale on a false — the app cannot know
    /// the remote machine's mach timebase.
    pub fn cpuUnitsCorrected(self: *Connection) bool {
        if (self.negotiated) |n| return n.cpu_units else |_| return false;
    }

    /// True iff the peer advertised `capability.agent_handoff` — i.e. this agent
    /// replaces ITSELF with a newer on-disk build, carrying every holder-backed
    /// session across, so nothing here should restart it destructively for being
    /// stale (T907).
    ///
    /// False for an older agent AND for a handshake that has not landed, which is
    /// the safe direction in both cases: the caller keeps its pre-T907 policy
    /// (refresh at idle, confirm while live) rather than waiting forever for a
    /// handoff that is never coming.
    pub fn peerHandsOffItself(self: *Connection) bool {
        if (self.negotiated) |n| return n.agent_handoff else |_| return false;
    }

    /// End a session on the agent BY SESSION ID (the session-scoped equivalent of
    /// the channel-scoped pane `CLOSE`): terminate + free the remote session even
    /// when no local pane is attached to it (the chooser's "Kill" of a browsed
    /// session). Sends `CLOSE_SESSION{session_id}` and awaits
    /// `CLOSE_SESSION_RESULT{ok, found}` on a fresh request channel (same-channel
    /// RPC, mirrors `requestSessions`/`relaunch`), bounded by `timeout_ns`. Returns
    /// the agent's `ok` (true ⇒ the session was closed). Returns `error.Unsupported`
    /// when the peer never advertised the capability (gate the opcode: never send it
    /// to a peer that can't decode it).
    pub fn closeSession(self: *Connection, session_id: []const u8, timeout_ns: u64) !bool {
        if (!self.supportsCloseSession()) return error.Unsupported;

        const req_channel = std.crypto.random.int(u128);
        const json = try protocol.encodeJson(self.alloc, protocol.CloseSession{
            .session_id = session_id,
        });
        defer self.alloc.free(json);

        const rpc = try self.rpcCall(req_channel, .close_session, .close_session_result, json, timeout_ns, null);
        defer self.alloc.free(rpc.payload);

        var parsed = protocol.parseJson(protocol.CloseSessionResult, self.alloc, rpc.payload) catch
            return error.MalformedReply;
        defer parsed.deinit();
        return parsed.value.ok;
    }

    /// Fire-and-forget `CLOSE_SESSION`: same request as `closeSession`, but it
    /// does NOT register an RPC slot and does not wait for the reply (the agent's
    /// `CLOSE_SESSION_RESULT` lands on a channel nobody claimed and is dropped).
    ///
    /// For callers whose success does not depend on the answer, and who must not
    /// pay for it. The T230 `restore` path is exactly that: it retires the dead
    /// tombstone it is replacing as housekeeping, on the pane's IO thread, in the
    /// middle of bringing a fresh shell up for a user who is watching. A bounded
    /// RPC there costs the whole timeout on any hiccup — measured at 1.5 s per
    /// pane on box — to learn something it would do nothing about.
    pub fn closeSessionNoWait(self: *Connection, session_id: []const u8) !void {
        if (!self.supportsCloseSession()) return error.Unsupported;

        const json = try protocol.encodeJson(self.alloc, protocol.CloseSession{
            .session_id = session_id,
        });
        defer self.alloc.free(json);
        try self.writeControl(.close_session, std.crypto.random.int(u128), json);
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
        self.freePaneOwned(pane);
    }

    /// Free everything a `Pane` owns — its heap ring storage, session id, tty and
    /// the pane itself. The caller is responsible for having removed it from
    /// `panes` and deregistered its channel first; this only frees.
    ///
    /// The ONE place that knows a pane's free list, so the two teardown paths
    /// (`teardownPane` for a closed/detached session, `destroy` for panes still
    /// tracked when the connection goes away) cannot drift apart — which they had
    /// (T811). Requires a heap-allocated `ring`, the only kind `trackPane` ever
    /// sees in production.
    fn freePaneOwned(self: *Connection, pane: *Pane) void {
        pane.ring.deinit(self.alloc);
        self.alloc.destroy(pane.ring);
        self.alloc.free(pane.session_id);
        if (pane.tty) |t| self.alloc.free(t);
        self.alloc.destroy(pane);
    }

    /// The result of an `rpcCall`: the duped reply payload (caller frees) plus the
    /// channel the reply actually arrived on (the agent-authoritative session channel
    /// for OPEN/ATTACH; equal to the request channel otherwise).
    /// `type` is the frame that satisfied the call — equal to `want` except for
    /// a refused OPEN, which answers `.open_failed` (T469).
    const RpcResult = struct { payload: []u8, channel: u128, type: protocol.FrameType };

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
        return .{ .payload = owned, .channel = slot.reply_channel, .type = slot.reply_type };
    }

    /// True iff `got` is a legitimate terminal reply for a slot waiting on
    /// `want`. Normally that is only the same type; the exceptions are the two
    /// NEGATIVE replies — `open_failed` answers an `.opened` slot (T469) and
    /// `attach_failed` answers an `.attached` slot (T657).
    ///
    /// They are replies, not wrong-type frames, and the distinction is the
    /// whole point: routed through `WrongReply` the caller would learn the
    /// request failed but never why, which is the blank pane these tasks exist
    /// to remove.
    fn acceptsReply(want: protocol.FrameType, got: protocol.FrameType) bool {
        if (want == got) return true;
        if (want == .opened and got == .open_failed) return true;
        return want == .attached and got == .attach_failed;
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
                // A refusal is the OPEN's answer, so it goes to the same slot
                // (T469). There is no session and therefore no agent channel to
                // adopt, but stamping `frame.channel` costs nothing and the
                // caller never reaches the adopt step on this path.
                .opened, .open_failed => self.pending_opened,
                // Likewise for ATTACH: a refusal is the ATTACH's answer and
                // goes to the same slot (T657). It arrives on the control
                // channel — there is no session, so there is no session
                // channel — and the caller never reaches the adopt step.
                .attached, .attach_failed => self.pending_attached,
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
        slot.reply_type = frame.type;
        if (!acceptsReply(slot.want, frame.type)) {
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
            .opened, .attached, .open_failed, .attach_failed => {
                // Reply to an OPEN/ATTACH RPC: hand the payload to the parked caller
                // keyed by this channel id. If no caller is waiting (stale/duplicate
                // reply), it's dropped here; the user handler still observes it.
                //
                // `.open_failed`/`.attach_failed` ride the same path on purpose —
                // each is its request's negative answer, not a separate event
                // (T469, T657). An unsolicited one (no parked caller) is simply
                // dropped, exactly like a late OPENED.
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
                // Two sources share this frame type, distinguished by channel:
                //
                //  * a REPLY to a LIST_SESSIONS RPC, echoed on the REQUEST channel
                //    (same-channel correlation, like CWD/PROC_SNAPSHOT). Dropped
                //    if no caller is parked (a late reply after a timeout).
                //  * a PUSH from `sessions_sub`, sent on the CONTROL channel
                //    whenever the roster changes.
                //
                // Reusing one frame type is deliberate: pushed and polled rosters
                // are byte-identical, so the client has a single decode path and
                // the two can never drift apart.
                if (frame.channel == protocol.control_channel) {
                    self.write_mutex.lock();
                    const handler = self.sessions_handler;
                    const ctx = self.sessions_handler_ctx;
                    self.write_mutex.unlock();
                    if (handler) |h| h(ctx, frame.payload);
                    return;
                }
                _ = self.deliverRpcReply(frame);
            },
            .proc_kill_result, .proc_spawn_result => {
                // Replies to PROC_KILL / PROC_SPAWN RPCs (§9.3 process control, inc
                // 4+5). Same-channel correlation, like PROC_SNAPSHOT. Dropped if no
                // caller is parked (a late reply after a timeout).
                _ = self.deliverRpcReply(frame);
            },
            .set_layout_result, .layouts => {
                // Replies to SET_LAYOUT / GET_LAYOUTS RPCs (§5.4 "Resume all",
                // T18). Same-channel correlation, like CWD/SESSIONS: the agent
                // echoes the reply on the request channel. Dropped if no caller
                // is parked (a late reply after a timeout).
                _ = self.deliverRpcReply(frame);
            },
            .close_session_result => {
                // Reply to a CLOSE_SESSION RPC (T96). Same-channel correlation, like
                // CWD/SESSIONS: the agent echoes CLOSE_SESSION_RESULT on the request
                // channel. Dropped if no caller is parked — which is the normal case
                // for `closeSessionNoWait`, whose reply lands on a channel nobody
                // claimed by design.
                //
                // This arm is what makes `closeSession` an RPC at all. Without it the
                // reply reached the reader and stopped there, so EVERY close-by-id
                // burned the caller's full timeout and then reported failure over a
                // session the agent had already killed ~30 ms in — the chooser's Kill
                // and `remote-test-client --close-session` both. It read like a hang
                // in the agent's pty teardown; it was a missing dispatch arm here.
                _ = self.deliverRpcReply(frame);
            },
            .relaunched => {
                // Reply to a RELAUNCH RPC (§5.4 reboot floor, T12c). The agent echoes
                // RELAUNCHED on the SESSION's channel (the relaunchable path), which is
                // exactly the channel the client sent RELAUNCH on, so `deliverRpcReply`
                // matches it via the `pending` map keyed by `frame.channel`. Dropped if
                // no caller is parked (a late reply after a timeout).
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
            .meta => {
                // Session metadata push. Two payloads are routed onto the pane's
                // inbound ring today — the live foreground pid (wp3 `tcgetpgrp`
                // sampling) and whether anything is running under the shell
                // (T356) — each signalled under the channel-table lock (the same
                // `withChannel` discipline as `.exit`: the ring can't be freed
                // mid-call, and an unknown/late channel is dropped silently).
                // The pane's IO thread republishes both on the stable Remote
                // backend for GUI reads. They arrive in SEPARATE frames in
                // practice (different samplers, pushed on change), but each is
                // handled independently so a frame carrying both loses neither.
                // Additive: the user `ctrl_handler` still observes the frame
                // afterward in `controlReaderLoop`.
                var parsed = protocol.parseJson(protocol.Meta, self.alloc, frame.payload) catch return;
                defer parsed.deinit();
                if (parsed.value.foreground_pid) |fg| {
                    const FgSig = struct {
                        pid: i64,
                        fn apply(self_sig: @This(), ch: *ring.Channel) void {
                            ch.signalForegroundPid(self_sig.pid);
                        }
                    };
                    _ = self.channels.withChannel(frame.channel, FgSig{ .pid = fg }, FgSig.apply);
                }
                if (parsed.value.has_descendants) |has| {
                    const BusySig = struct {
                        has: bool,
                        fn apply(self_sig: @This(), ch: *ring.Channel) void {
                            ch.signalHasDescendants(self_sig.has);
                        }
                    };
                    _ = self.channels.withChannel(frame.channel, BusySig{ .has = has }, BusySig.apply);
                }
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
            .session_cpu => {
                // Pushed per-session CPU roll-up. Same discipline as `.metrics`:
                // decode failures are dropped silently, and the slot is read under
                // the lock its publish is ordered by. `rows` borrows the parsed
                // arena, so the handler must copy anything it keeps — the arena
                // dies when this scope exits.
                var parsed = protocol.parseJson(protocol.SessionCpu, self.alloc, frame.payload) catch return;
                defer parsed.deinit();
                self.write_mutex.lock();
                const handler = self.session_cpu_handler;
                const ctx = self.session_cpu_handler_ctx;
                self.write_mutex.unlock();
                if (handler) |h| h(ctx, parsed.value.sessions, parsed.value.interval_ms);
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
        // Same capture for the peer's build stamp (used by the app to detect a
        // stale local agent). Best-effort; null when the peer is an older agent.
        if (parsed.value.build_version) |v| {
            if (v.len > 0 and self.peer_build_version == null) {
                self.peer_build_version = self.alloc.dupeZ(u8, v) catch null;
            }
        }
        // And the peer's protocol version, which — unlike the two above — is
        // captured FOR the failure case: `negotiate` below turns a mismatch into
        // a bare `error.Incompatible`, and the only way to tell "the agent is
        // behind us" from "we are behind the agent" afterwards is this number.
        self.peer_proto_version = parsed.value.proto_version;
        // And what its children run on (T471) — a value, not a slice, so there
        // is nothing to dupe out of the parse arena. Null from an agent older
        // than the field, or from a future spelling we don't know; the reader
        // (`history_guard.enabledFor`) falls back to this machine's flavour.
        self.peer_pty_flavor = parsed.value.ptyFlavor();
        return protocol.negotiate(self.local_hello, parsed.value);
    }

    /// The `proto_version` the peer advertised, or null when no HELLO was
    /// parsed. Valid after the handshake resolves EITHER WAY — the incompatible
    /// case is what it exists for (see the field).
    pub fn peerProtoVersion(self: *const Connection) ?u16 {
        return self.peer_proto_version;
    }

    /// The peer's self-reported hostname (display-only), or null. Only valid
    /// after `waitHandshake` has returned successfully.
    pub fn peerHostname(self: *const Connection) ?[:0]const u8 {
        return self.peer_hostname;
    }

    /// The peer's self-reported build stamp ("YYYYMMDD-<hash>"), or null (an
    /// older agent that doesn't advertise it). Only valid after `waitHandshake`
    /// has returned successfully.
    pub fn peerBuildVersion(self: *const Connection) ?[:0]const u8 {
        return self.peer_build_version;
    }

    /// The pty flavour the peer spawns its children on (T471), or null from an
    /// agent too old to report one. Only valid after `waitHandshake` has
    /// returned successfully — a remote pane reads it once its pane is live.
    pub fn peerPtyFlavor(self: *const Connection) ?protocol.PtyFlavor {
        return self.peer_pty_flavor;
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
    fn routeInboundData(
        self: *Connection,
        channel: u128,
        byte_offset: u64,
        bytes: []const u8,
        kind: InboundKind,
    ) void {
        var to_push = bytes;
        // The absolute offset of the first byte we actually push. Moves up with
        // the resync trim below so the stream position we record names the bytes
        // that landed, not the ones we dropped.
        var push_at = byte_offset;

        // Consult the per-channel resync watermark (separate lock from the table).
        self.panes_mutex.lock();
        if (self.panes.get(channel)) |pane| {
            // A REPAINT is never a duplicate of anything the client already has —
            // it is the agent's own paint of the CURRENT screen (or its sentence
            // about a hole), synthesized for this attach. So it bypasses the
            // resync trim entirely: there is nothing here to discard, and
            // nothing that should disarm a watermark the real replay has not
            // crossed yet.
            if (pane.resync_active and kind == .data) {
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
                    push_at = keep_from;
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
        // How many of those bytes the pane will actually see. A `.buffered` push
        // is held in the pre-registration buffer and flushed by `register`, so
        // all of it counts; a `.unknown` push went nowhere.
        const accepted: usize = switch (res) {
            .unknown => 0,
            .buffered => to_push.len,
            .routed => |push| push.written,
        };
        self.advanceStreamPos(channel, push_at, accepted, kind);
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

    /// Publish the pane's absolute stream position after a routed frame (T739).
    /// Separate from the resync lookup above because it must run AFTER the push,
    /// with the count the ring accepted in hand, and the panes lock must not be
    /// held across that push.
    fn advanceStreamPos(
        self: *Connection,
        channel: u128,
        push_at: u64,
        accepted: usize,
        kind: InboundKind,
    ) void {
        // One line per injected repaint — which is at most one per ATTACH, and
        // the only place the size of the agent's injection is visible at all.
        if (kind == .repaint) std.log.scoped(.remote_conn).info(
            "repaint frame: {d} byte(s) at offset {d} (not stream position)",
            .{ accepted, push_at },
        );
        self.panes_mutex.lock();
        defer self.panes_mutex.unlock();
        const pane = self.panes.get(channel) orelse return;
        pane.stream_pos.store(streamPosAfter(
            pane.stream_pos.load(.monotonic),
            push_at,
            accepted,
            kind == .repaint,
        ), .release);
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
                // `data_repaint` (0x15) carries the same payload and is rendered
                // identically; what differs is that its bytes are the agent's
                // own paint rather than the session's stream, so they advance no
                // offset (T739). Only an agent that negotiated `repaint_data`
                // ever sends it.
                const kind: InboundKind = switch (frame.type) {
                    .data => .data,
                    .data_repaint => .repaint,
                    else => continue, // ignore anything else on this lane
                };
                const dp = protocol.DataPayload.decode(frame.payload) catch continue;
                self.routeInboundData(frame.channel, dp.byte_offset, dp.bytes, kind);
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
const test_util = @import("test_util.zig");

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
    /// When set, `read` on an empty fifo gives up after this long with
    /// `error.LoopbackReadTimeout` instead of blocking forever. A liveness
    /// bound like `waitUntil`'s (T346), not a performance assertion: it only
    /// fires when the awaited bytes NEVER come — the T258 hang, where a test
    /// wedged ~11 min in this wait with no failure text. Left null on the
    /// direction the Connection's own reader threads consume, where idling
    /// between frames is the normal state.
    read_deadline_ns: ?u64 = null,
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
        if (self.read_deadline_ns) |deadline_ns| {
            var timer = std.time.Timer.start() catch unreachable;
            while (self.head == self.buf.items.len and !self.closed) {
                const elapsed = timer.read();
                if (elapsed >= deadline_ns) return error.LoopbackReadTimeout;
                self.cond.timedWait(&self.mutex, deadline_ns - elapsed) catch {};
            }
        } else {
            while (self.head == self.buf.items.len and !self.closed) {
                self.cond.wait(&self.mutex);
            }
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
        var lb: Loopback = .{
            .client_to_agent = ByteFifo.init(alloc),
            .agent_to_client = ByteFifo.init(alloc),
        };
        // The MockAgent — the TEST side here, the mirror of server.zig's
        // Loopback where the client is the test side — reads client_to_agent
        // (`nextFrame`, `expect*` helpers), often from the main test thread.
        // Bound that direction so a frame that never arrives fails the waiting
        // test red instead of wedging the lane (T258). The Connection's own
        // reader threads consume agent_to_client; that stays unbounded (idle
        // is normal there, and closeBoth wakes it at teardown).
        lb.client_to_agent.read_deadline_ns = test_util.liveness_ns;
        return lb;
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

test "ByteFifo: a deadlined read fails cleanly instead of wedging (T258 shape)" {
    var fifo = ByteFifo.init(testing.allocator);
    defer fifo.deinit();
    fifo.read_deadline_ns = 50 * std.time.ns_per_ms;
    var buf: [16]u8 = undefined;
    try testing.expectError(error.LoopbackReadTimeout, fifo.read(&buf));
    // Data present → returned normally; the deadline is a liveness bound only.
    _ = try fifo.write("ok");
    try testing.expectEqual(@as(usize, 2), try fifo.read(&buf));
    // Closed → EOF (0), never a timeout error.
    fifo.close();
    try testing.expectEqual(@as(usize, 0), try fifo.read(&buf));
}

/// A mock agent's stream-side `protocol.Reader` + writer helpers, sharing the
/// pinned encoding. Reads frames from a stream blocking until one is available.
const MockAgent = struct {
    stream: Stream,
    encoding: protocol.TransferEncoding,
    reader: protocol.Reader,
    scratch: [read_buf_size]u8 = undefined,
    alloc: Allocator,
    /// The `pty_flavor` the CLIENT reported in its own HELLO, captured by the
    /// handshake (T471). Null until a handshake has run.
    saw_pty_flavor: ?protocol.PtyFlavor = null,

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
        return self.handshakeCaps(&.{});
    }

    /// `handshake`, but the agent HELLO advertises `caps`. Capability-gated
    /// opcodes (`close_session`) are refused client-side unless the peer
    /// advertised them, so a test that drives one must hand the mock its
    /// capability set — an empty set models an older agent.
    fn handshakeCaps(self: *MockAgent, caps: []const []const u8) !protocol.TransferEncoding {
        return self.handshakeFull(caps, null);
    }

    /// `handshakeCaps`, but the agent HELLO also reports `pty_flavor` — the wire
    /// spelling verbatim, so a test can model an agent on the OTHER os, an agent
    /// too old to say (null), or one naming a flavour this build never heard of
    /// (T471). Records the client's own reported flavour in `saw_pty_flavor`.
    fn handshakeFull(
        self: *MockAgent,
        caps: []const []const u8,
        pty_flavor: ?[]const u8,
    ) !protocol.TransferEncoding {
        const frame = (try self.nextFrame()) orelse return error.NoHello;
        try testing.expectEqual(protocol.FrameType.hello, frame.type);
        var parsed = try protocol.Hello.parse(self.alloc, frame.payload);
        defer parsed.deinit();
        const enc = parsed.value.transfer_encoding;
        self.saw_pty_flavor = parsed.value.ptyFlavor();

        const reply: protocol.Hello = .{
            .transfer_encoding = enc,
            .capabilities = caps,
            .pty_flavor = pty_flavor,
        };
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
        // T536 audit: without this, a failed start/handshake leaked the agent
        // thread parked on a loopback read — it then wrote its err field into
        // this dead stack frame while the NEXT test owned the memory. Same
        // disarming shape as the inbound-routing test (a second join is UB).
        var ath_joined = false;
        errdefer if (!ath_joined) {
            conn.shutdown();
            ath.join();
        };

        try conn.start();
        const neg = try conn.waitHandshake();
        ath.join();
        ath_joined = true;

        try testing.expectEqual(enc, neg.transfer_encoding);
        try testing.expectEqual(protocol.proto_version, neg.proto_version);
        try testing.expect(actx.err == null);
        try testing.expectEqual(enc, actx.saw_encoding);

        conn.shutdown();
    }
}

const FlavorAgentCtx = struct {
    agent: *MockAgent,
    /// The wire spelling this mock agent reports, or null for an agent too old
    /// to report one.
    flavor: ?[]const u8,
    err: ?anyerror = null,
    fn run(self: *FlavorAgentCtx) void {
        _ = self.agent.handshakeFull(&.{}, self.flavor) catch |e| {
            self.err = e;
        };
    }
};

test "handshake: the agent's pty flavour crosses the wire in both directions (T471)" {
    const alloc = testing.allocator;

    // What the agent says → what a pane on this connection believes its child
    // runs on. The last two are the skew cases: an agent from before the field
    // existed, and one naming a flavour this build has never heard of. Both must
    // land on null, which the guard reads as "assume this machine's" — i.e. the
    // pre-T471 behaviour, never a wrong positive answer.
    const cases = [_]struct { said: ?[]const u8, want: ?protocol.PtyFlavor }{
        .{ .said = "posix", .want = .posix },
        .{ .said = "conpty", .want = .conpty },
        .{ .said = null, .want = null },
        .{ .said = "tty37", .want = null },
    };

    for (cases) |c| {
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

        var agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
        defer agent.deinit();
        var actx: FlavorAgentCtx = .{ .agent = &agent, .flavor = c.said };
        const ath = try std.Thread.spawn(.{}, FlavorAgentCtx.run, .{&actx});
        // T536 audit: disarming errdefer — see the handshake test above.
        var ath_joined = false;
        errdefer if (!ath_joined) {
            conn.shutdown();
            ath.join();
        };

        try conn.start();
        _ = try conn.waitHandshake();
        ath.join();
        ath_joined = true;
        try testing.expect(actx.err == null);

        // The peer's answer, which is what a cross-OS pane hangs its scrollback
        // guard on.
        try testing.expectEqual(c.want, conn.peerPtyFlavor());

        // And the other direction: we report OUR flavour unasked, so an agent
        // that ever wants it does not need a second wire change to get it.
        try testing.expectEqual(protocol.PtyFlavor.local, agent.saw_pty_flavor.?);

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
    try agentSendDataFramed(agent, .data, channel, byte_offset, bytes);
}

/// An injected repaint (`DATA_REPAINT`, 0x15 — T739). Same payload as DATA.
fn agentSendRepaint(agent: *MockAgent, channel: u128, byte_offset: u64, bytes: []const u8) !void {
    try agentSendDataFramed(agent, .data_repaint, channel, byte_offset, bytes);
}

fn agentSendDataFramed(
    agent: *MockAgent,
    ftype: protocol.FrameType,
    channel: u128,
    byte_offset: u64,
    bytes: []const u8,
) !void {
    const payload = try agent.alloc.alloc(u8, protocol.DataPayload.encodedLen(bytes.len));
    defer agent.alloc.free(payload);
    const dp: protocol.DataPayload = .{ .byte_offset = byte_offset, .bytes = bytes };
    _ = dp.encodeInto(payload);
    try agent.sendFrame(.{ .type = ftype, .channel = channel, .seq = 0, .payload = payload });
}

/// How long a test wait may take before it is called a timeout. Generous on
/// purpose: it is an upper bound on a hang, not a performance assertion.
/// Follows the shared liveness bound (60s): 10s of a liveness bound proved
/// spendable under acceptance-script load (T183), and a spent bound turns a
/// green run red for nothing.
const test_wait_ms: u64 = test_util.liveness_ns / std.time.ns_per_ms;

/// A wall-clock budget for a test that waits on another thread.
///
/// Spin counts do not measure time, they measure scheduler contention (T472).
/// On a box running three test lanes and a WebView2 host, the 100_000 yields
/// this replaced could burn through in far less time than the writer thread
/// needed, so a green tree produced `error.Timeout` at random — and a flaky
/// red run costs more than a real one, because it trains whoever is watching
/// to shrug at red. A deadline cannot be starved that way, and it says what it
/// means: "nothing arrived within the liveness bound."
const TestDeadline = struct {
    timer: std.time.Timer,
    budget_ns: u64,

    fn start() !TestDeadline {
        return startWith(test_wait_ms);
    }

    fn startWith(budget_ms: u64) !TestDeadline {
        return .{
            .timer = try std.time.Timer.start(),
            .budget_ns = budget_ms * std.time.ns_per_ms,
        };
    }

    fn expired(self: *TestDeadline) bool {
        return self.timer.read() > self.budget_ns;
    }

    /// Yield to the thread we are waiting on, or report the budget is spent.
    fn yield(self: *TestDeadline) error{Timeout}!void {
        if (self.expired()) return error.Timeout;
        std.Thread.yield() catch {};
    }
};

test "T472: a test wait is bounded by the wall clock, not by a spin count" {
    // A spent budget is a timeout, and says so through the error rather than
    // by falling off the end of a loop.
    var spent = try TestDeadline.startWith(0);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try testing.expect(spent.expired());
    try testing.expectError(error.Timeout, spent.yield());

    // ...and no number of yields can spend a budget that has not elapsed. This
    // is the property the old oracle lacked: 100_000 contended yields on a
    // loaded box were a "timeout" while nothing was actually late.
    var generous = try TestDeadline.startWith(10 * std.time.ms_per_s * 60);
    for (0..200_000) |_| try generous.yield();
    try testing.expect(!generous.expired());
}

/// Drain a channel's ring until `want` bytes have been collected into `out`.
fn drainChannel(ch: *ring.Channel, out: *std.ArrayList(u8), alloc: Allocator, want: usize) !void {
    var dst: [256]u8 = undefined;
    var deadline = try TestDeadline.start();
    while (out.items.len < want) {
        const r = ch.pop(&dst);
        if (r.read == 0) {
            deadline.yield() catch {
                // Say what was actually collected: a bare `error.Timeout` out
                // of a drain names neither the channel nor how far it got.
                std.debug.print(
                    "\ndrainChannel: {d}ms budget spent with {d} of {d} byte(s): \"{s}\"\n",
                    .{ test_wait_ms, out.items.len, want, out.items },
                );
                return error.Timeout;
            };
            continue;
        }
        try out.appendSlice(alloc, dst[0..r.read]);
    }
}

test "T739: streamPosAfter — a repaint's bytes never advance the stream position" {
    // The measured attach burst, with the numbers from the T739 report: the
    // client resumes at 1714 (the agent's head), and the agent injects a 169-byte
    // grid-snapshot repaint anchored there. Counting those bytes is what recorded
    // 1883 and made the NEXT attach get clamped back to the head.
    try testing.expectEqual(@as(u64, 1714), streamPosAfter(1714, 1714, 169, true));
    // The same frame as ordinary stream data — the shape an OLDER agent sends,
    // where 1883 is the honest reading of what is on the wire and the client has
    // no way to know better. This is the pre-T739 behavior the skew degrades to.
    try testing.expectEqual(@as(u64, 1883), streamPosAfter(1714, 1714, 169, false));

    // A gap-fill: real stream bytes, anchored where we left off.
    try testing.expectEqual(@as(u64, 1200), streamPosAfter(1000, 1000, 200, false));
    // ...then the repaint at the head leaves it exactly there. That equality is
    // the whole point: the recorded offset now IS the agent's head.
    try testing.expectEqual(@as(u64, 1200), streamPosAfter(1200, 1200, 169, true));
    // ...and live output from the head advances it again.
    try testing.expectEqual(@as(u64, 1250), streamPosAfter(1200, 1200, 50, false));

    // The scrollback-lost marker: anchored at the resume point, which is where
    // we already are, so it moves nothing — and the replay that follows it comes
    // from the ring's base, ABOVE the evicted range, so the position jumps the
    // hole instead of counting bytes across it.
    try testing.expectEqual(@as(u64, 1000), streamPosAfter(1000, 1000, 45, true));
    try testing.expectEqual(@as(u64, 5000), streamPosAfter(1000, 4000, 1000, false));

    // Never backwards: a resync leftover wholly below where we are.
    try testing.expectEqual(@as(u64, 5000), streamPosAfter(5000, 100, 50, false));
    try testing.expectEqual(@as(u64, 5000), streamPosAfter(5000, 100, 50, true));

    // Only the bytes the ring ACCEPTED count. A push the ring had no room for
    // leaves the position short, which replays a byte twice rather than skipping
    // it — the safe direction.
    try testing.expectEqual(@as(u64, 1010), streamPosAfter(1000, 1000, 10, false));
    try testing.expectEqual(@as(u64, 1000), streamPosAfter(1000, 1000, 0, false));
}

test "T739: an injected repaint is rendered like DATA but advances no offset" {
    const alloc = testing.allocator;
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    const ch_id: u128 = 0x7739;
    var ch = try ring.Channel.init(alloc, ch_id, .{ .capacity = 4096 });
    defer ch.deinit(alloc);

    const conn = try Connection.create(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
    );
    defer conn.destroy(alloc);
    try conn.registerChannel(&ch);

    var ctrl_agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer ctrl_agent.deinit();
    var ictx: InboundAgentCtx = .{ .agent = &ctrl_agent, .channel = ch_id };
    const ath = try std.Thread.spawn(.{}, InboundAgentCtx.run, .{&ictx});
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };

    try conn.start();
    _ = try conn.waitHandshake();
    ath.join();
    ath_joined = true;

    // A tracked pane is what carries the position; the ring alone cannot.
    const sid = try alloc.dupe(u8, "s739");
    const pane = try alloc.create(Pane);
    pane.* = .{
        .id = ch_id,
        .session_id = sid,
        .pid = 0,
        .ring = &ch,
        .stream_pos = .init(100),
    };
    try conn.trackPane(pane);
    // Untrack + free on EVERY exit, failure included, and BEFORE `conn`'s
    // destroy defer fires (LIFO): a pane still tracked at destroy gets its
    // ring freed with `alloc.destroy(pane.ring)`, and THIS pane's ring is
    // `&ch` — a stack address, so that path is an invalid free, and `ch`'s
    // own deinit defer then double-frees the ring buffer (T536 audit). The
    // remove is under `panes_mutex`, the same lock the data reader's lookup
    // holds, so a live reader never sees the freed pane.
    defer {
        conn.panes_mutex.lock();
        _ = conn.panes.remove(ch_id);
        conn.panes_mutex.unlock();
        alloc.free(sid);
        alloc.destroy(pane);
    }

    var data_agent = MockAgent.init(alloc, data_lb.agentStream(), .raw);
    defer data_agent.deinit();

    // Gap-fill, then the repaint anchored at the head it produced.
    try agentSendData(&data_agent, ch_id, 100, "gap");
    try agentSendRepaint(&data_agent, ch_id, 103, "REPAINT");

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try drainChannel(&ch, &got, alloc, "gapREPAINT".len);
    // The repaint is rendered: its bytes reach the pane exactly like DATA's.
    try testing.expectEqualStrings("gapREPAINT", got.items);

    // ...but the position stops at the head. Counting the repaint would say 110,
    // which is past everything the session ever produced.
    // On the budget rather than a spin count (T472): a `break` on the deadline
    // hands the failure to `expectEqual`, which prints both positions.
    var deadline = try TestDeadline.start();
    while (pane.streamPos() != 103) deadline.yield() catch break;
    try testing.expectEqual(@as(u64, 103), pane.streamPos());

    // Live output from the head advances it again — the repaint cost nothing.
    try agentSendData(&data_agent, ch_id, 103, "live");
    deadline = try TestDeadline.start();
    while (pane.streamPos() != 107) deadline.yield() catch break;
    try testing.expectEqual(@as(u64, 107), pane.streamPos());

    conn.shutdown();
    // Deregister only after shutdown (the data reader has joined) so the
    // stack-owned ring is safe. `teardownPane` is not usable here — it frees a
    // heap ring this test does not have. The pane itself is untracked and
    // freed by the paired defer above, on success and failure alike.
    conn.deregisterChannel(ch_id);
}

test "T811: destroy frees a still-tracked pane's tty too, not just its ring and id" {
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

    // A pane shaped exactly as `openChannel`/`attachChannel` build one: heap ring,
    // duped session id, duped agent-side tty path. Never closed or detached, so
    // the connection still owns all four allocations when it goes away — the path
    // a dropped link with attached panes takes.
    const ch_id: u128 = 0x811;
    const ch = try alloc.create(ring.Channel);
    ch.* = try ring.Channel.init(alloc, ch_id, .{ .capacity = 256 });
    try conn.registerChannel(ch);

    const pane = try alloc.create(Pane);
    pane.* = .{
        .id = ch_id,
        .session_id = try alloc.dupe(u8, "s811"),
        .pid = 0,
        .tty = try alloc.dupe(u8, "/dev/ttys811"),
        .ring = ch,
    };
    try conn.trackPane(pane);

    // The assertion is the allocator's: `testing.allocator` fails the test if any
    // of the four survives. Before T811 the tty did.
    conn.destroy(alloc);
}

test "inbound DATA routing: bytes land in the right channel; unknown is dropped" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var ctrl_lb = Loopback.init(alloc);
        defer ctrl_lb.deinit();
        var data_lb = Loopback.init(alloc);
        defer data_lb.deinit();

        // The channel is created BEFORE the connection so its `deinit` defer
        // runs LAST: defers are LIFO, so the connection — whose data reader
        // pushes into this ring — is torn down first. Registered the other way
        // round, an early `return` from the body freed the ring under a live
        // reader thread (T693).
        const ch_id: u128 = 0x1234_5678;
        var ch = try ring.Channel.init(alloc, ch_id, .{ .capacity = 4096 });
        defer ch.deinit(alloc);

        const conn = try Connection.create(
            alloc,
            ctrl_lb.clientStream(),
            data_lb.clientStream(),
            .{ .transfer_encoding = enc },
        );
        defer conn.destroy(alloc);
        try conn.registerChannel(&ch);

        // Agent handshakes on control, then sends DATA on the data stream.
        var ctrl_agent = MockAgent.init(alloc, ctrl_lb.agentStream(), enc);
        defer ctrl_agent.deinit();
        var ictx: InboundAgentCtx = .{ .agent = &ctrl_agent, .channel = ch_id };
        const ath = try std.Thread.spawn(.{}, InboundAgentCtx.run, .{&ictx});
        // On an early failure the agent thread is still parked on its
        // handshake read; `shutdown` closes the loopback under it so the join
        // returns EOF instead of hanging, and it cannot outlive `ctrl_agent`.
        // The flag disarms it once the body has joined — a second join is UB.
        var ath_joined = false;
        errdefer if (!ath_joined) {
            conn.shutdown();
            ath.join();
        };

        try conn.start();
        _ = try conn.waitHandshake();
        ath.join();
        ath_joined = true;
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

test "T693: destroy without a prior shutdown joins the threads instead of asserting" {
    const alloc = testing.allocator;

    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    const ch_id: u128 = 0x0693;
    var ch = try ring.Channel.init(alloc, ch_id, .{ .capacity = 4096 });
    defer ch.deinit(alloc);

    const conn = try Connection.create(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
    );
    // No success-path defer — the explicit destroy-with-live-threads below IS
    // the test — but an early failure must still free the connection (T536
    // audit; destroy joining live threads is exactly the behavior under test).
    errdefer conn.destroy(alloc);
    try conn.registerChannel(&ch);

    var ctrl_agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer ctrl_agent.deinit();
    var ictx: InboundAgentCtx = .{ .agent = &ctrl_agent, .channel = ch_id };
    const ath = try std.Thread.spawn(.{}, InboundAgentCtx.run, .{&ictx});
    // T536 audit: disarming errdefer — see the handshake test above.
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };
    try conn.start();
    _ = try conn.waitHandshake();
    ath.join();
    ath_joined = true;

    // The live threads are the point: this is the state an error path leaves
    // behind when it returns before `shutdown`, and the state in which the old
    // `destroy` asserted (Debug) or freed the ring under the data reader
    // (ReleaseFast).
    try testing.expect(conn.threadsLive());

    conn.destroy(alloc);

    // Returning at all is the claim — `destroy` joined every thread rather
    // than tripping its assert — and `testing.allocator` covers the rest: the
    // write queue and pending map are only freed on the path that ran.
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
        // T536 audit: disarming errdefer — see the handshake test above.
        var ath_joined = false;
        errdefer if (!ath_joined) {
            conn.shutdown();
            ath.join();
        };

        try conn.start();
        _ = try conn.waitHandshake();

        const ch_id: u128 = 0xCAFE;
        try conn.writeData(ch_id, 4242, "keystrokes");

        ath.join();
        ath_joined = true;
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
        // T536 audit: disarming errdefer — see the handshake test above.
        var ath_joined = false;
        errdefer if (!ath_joined) {
            conn.shutdown();
            ath.join();
        };

        try conn.start();
        _ = try conn.waitHandshake();

        // Wait for the handler to fire (deterministic; no sleep-as-sync).
        try test_util.waitEvent(&sink.done);
        ath.join();
        ath_joined = true;
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
        // T536 audit: disarming errdefer — see the handshake test above.
        var ath_joined = false;
        errdefer if (!ath_joined) {
            conn.shutdown();
            ath.join();
        };

        try conn.start();
        _ = try conn.waitHandshake();
        ath.join();
        ath_joined = true;

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

/// Wait until `cond()` is true or the wall-clock budget is spent (no fixed
/// sleeps — the agent thread makes progress on its own). The budget is a
/// deadline rather than a spin count for the reason in `TestDeadline` (T472).
fn spinUntil(comptime ctx_t: type, ctx: *ctx_t, cond: *const fn (*ctx_t) bool) !void {
    var deadline = try TestDeadline.start();
    while (!cond(ctx)) try deadline.yield();
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
    // T536 audit: disarming errdefer — see the handshake test above.
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };

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
    ath_joined = true;
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
    // T536 audit: disarming errdefer — see the handshake test above.
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };

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
    ath_joined = true;
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
    // T536 audit: disarming errdefer — see the handshake test above.
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };

    try conn.start();
    _ = try conn.waitHandshake();

    // Trigger the agent to send a DETACHED (steal/eviction, §5.3).
    hctx.send_detached.store(true, .monotonic);
    // Nudge the agent loop: send a PING so it cycles and emits the DETACHED. We do
    // this by waiting for the agent to flag it sent.
    try test_util.waitEvent(&hctx.detached_sent);

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
    ath_joined = true;
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
    // T536 audit: disarming errdefer — see the handshake test above.
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };

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
    ath_joined = true;
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
    /// Reported as the child's pty slave path in OPENED, alive ATTACHED, and ok
    /// RELAUNCHED (wp3). Null models an older/Windows agent that omits it.
    tty: ?[]const u8 = null,
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
    /// Reported in ATTACHED (T12c): a dead session materialized from disk that
    /// can be respawned via RELAUNCH. Set alongside `attach_status = .dead`.
    attach_relaunchable: bool = false,
    /// When true the agent receives OPEN but NEVER replies OPENED (models a remote
    /// session whose command/cwd failed to spawn). Exercises the RPC timeout so a
    /// silent agent can't wedge the caller (the pane IO thread) forever.
    silent_open: bool = false,
    /// When set, an ATTACH is answered with `ATTACH_FAILED{reason}` on the
    /// CONTROL channel instead of an ATTACHED — the T657 refusal a real agent
    /// sends for a request it cannot answer at all.
    refuse_attach: ?[]const u8 = null,
    /// When true the agent receives ATTACH and NEVER replies (the pre-T657
    /// behavior for exactly that case). Exercises the fallback path an agent
    /// too old to advertise `attach_failed` still takes.
    silent_attach: bool = false,

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

    // RELAUNCH reply config (T12c). A RELAUNCH gets RELAUNCHED on the SAME
    // channel with these values; `saw_relaunch` records that one arrived and
    // `relaunch_channel` the channel it came in on (must equal the dead ATTACHED
    // channel the client re-uses).
    relaunch_ok: bool = true,
    relaunch_found: bool = true,
    relaunch_pid: i64 = 5555,
    saw_relaunch: std.atomic.Value(bool) = .{ .raw = false },
    // u128 has no x86_64 atomics; guarded by `seen_channel_mtx` like `seen_channel`.
    relaunch_channel: u128 = 0,

    // PROC_KILL / PROC_SPAWN reply config (inc 4+5). A PROC_KILL for `kill_fail_pid`
    // replies ok=false (models no-such-pid); any other pid succeeds. PROC_SPAWN
    // always replies ok=true with `spawn_pid`.
    saw_proc_kill: std.atomic.Value(bool) = .{ .raw = false },
    saw_proc_spawn: std.atomic.Value(bool) = .{ .raw = false },
    kill_fail_pid: i64 = -424242, // a sentinel no real test pid uses
    spawn_pid: i64 = 99001,

    // CLOSE_SESSION reply config (T96). A CLOSE_SESSION for `close_session_miss_id`
    // replies found=false/ok=false (models an unknown/stale id); any other id is
    // closed. `advertise_close_session = false` models an OLDER agent that never
    // announced the opcode, so the client refuses to send it. `silent_close_session`
    // models an agent that receives the request and never answers — the shape the
    // client saw for the whole life of the T96 defect.
    advertise_close_session: bool = true,
    silent_close_session: bool = false,
    close_session_miss_id: []const u8 = "ffffffffffffffffffffffffffffffff",
    saw_close_session: std.atomic.Value(bool) = .{ .raw = false },

    // Observations (atomics / events so the test thread can read them safely).
    // The channel id is u128 and x86_64 has no 128-bit atomics, so it is
    // mutex-guarded instead (setSeenChannel/seenChannel).
    seen_channel_mtx: std.Thread.Mutex = .{},
    seen_channel: u128 = 0,
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

    fn setSeenChannel(self: *LifecycleAgent, ch: u128) void {
        self.seen_channel_mtx.lock();
        defer self.seen_channel_mtx.unlock();
        self.seen_channel = ch;
    }

    fn seenChannel(self: *LifecycleAgent) u128 {
        self.seen_channel_mtx.lock();
        defer self.seen_channel_mtx.unlock();
        return self.seen_channel;
    }

    fn setRelaunchChannel(self: *LifecycleAgent, ch: u128) void {
        self.seen_channel_mtx.lock();
        defer self.seen_channel_mtx.unlock();
        self.relaunch_channel = ch;
    }

    fn relaunchChannel(self: *LifecycleAgent) u128 {
        self.seen_channel_mtx.lock();
        defer self.seen_channel_mtx.unlock();
        return self.relaunch_channel;
    }

    fn body(self: *LifecycleAgent) !void {
        const caps = [_][]const u8{protocol.capability.close_session};
        _ = try self.ctrl.handshakeCaps(if (self.advertise_close_session) &caps else &.{});
        while (true) {
            const frame = (try self.ctrl.nextFrame()) orelse return; // EOF: done
            switch (frame.type) {
                .open => {
                    self.setSeenChannel(frame.channel);
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
                        .tty = self.tty,
                    });
                },
                .attach => {
                    const n = self.attach_count.fetchAdd(1, .monotonic);
                    self.setSeenChannel(frame.channel);
                    self.saw_request.set();
                    if (self.silent_attach) continue;
                    if (self.refuse_attach) |reason| {
                        // On the CONTROL channel, as the real agent sends it:
                        // no session means no session channel.
                        try self.ctrl.sendJson(
                            .attach_failed,
                            protocol.control_channel,
                            protocol.AttachFailed{ .reason = reason, .detail = "why-it-said-no" },
                        );
                        continue;
                    }
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
                        .relaunchable = self.attach_relaunchable,
                        .pid = if (self.attach_status == .alive) self.pid else 0,
                        .tty = if (self.attach_status == .alive) self.tty else null,
                    });
                },
                .relaunch => {
                    // Reply RELAUNCHED on the SAME channel (the relaunchable path),
                    // as the real agent does when the tombstone is respawnable.
                    self.saw_relaunch.store(true, .monotonic);
                    self.setRelaunchChannel(frame.channel);
                    var parsed = protocol.parseJson(protocol.Relaunch, self.alloc, frame.payload) catch continue;
                    defer parsed.deinit();
                    const sid = parsed.value.session_id;
                    try self.ctrl.sendJson(.relaunched, frame.channel, protocol.Relaunched{
                        .session_id = sid,
                        .ok = self.relaunch_ok,
                        .pid = if (self.relaunch_ok) self.relaunch_pid else 0,
                        .found = self.relaunch_found,
                        .tty = if (self.relaunch_ok) self.tty else null,
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
                .close_session => {
                    // Reply CLOSE_SESSION_RESULT on the SAME request channel (T96),
                    // exactly as the agent's `handleCloseSession` does.
                    self.saw_close_session.store(true, .monotonic);
                    if (self.silent_close_session) continue;
                    var parsed = protocol.parseJson(protocol.CloseSession, self.alloc, frame.payload) catch continue;
                    defer parsed.deinit();
                    const sid = parsed.value.session_id;
                    const found = !std.mem.eql(u8, sid, self.close_session_miss_id);
                    try self.ctrl.sendJson(.close_session_result, frame.channel, protocol.CloseSessionResult{
                        .session_id = sid,
                        .ok = found,
                        .found = found,
                    });
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
    /// Null until `start` spawns the agent thread — so a `destroy` after a
    /// failed spawn joins nothing instead of joining an undefined handle
    /// (T536 audit).
    thread: ?std.Thread = null,

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
        if (h.thread) |t| t.join();
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
    a.tty = "/dev/ttys014";
    try h.start();

    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80, .command = "bash" });

    // The agent received a well-formed OPEN on the pane's channel id.
    try test_util.waitEvent(&a.saw_request);
    try testing.expectEqual(pane.id, a.seenChannel());
    // The pane carries the agent-assigned identity (incl. the wp3 tty).
    try testing.expectEqualStrings("session-abc", pane.session_id);
    try testing.expectEqual(@as(i64, 9001), pane.pid);
    try testing.expectEqualStrings("/dev/ttys014", pane.tty.?);

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
    try test_util.waitEvent(&a.saw_request);

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

test "META foreground_pid: routed to the pane's ring; unknown channel dropped (wp3)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.session_id = "sess-fg";
    try h.start();

    const pane = try h.conn.openChannel(.{ .rows = 24, .cols = 80, .command = "bash" });
    try test_util.waitEvent(&a.saw_request);
    try testing.expectEqual(@as(i64, 0), pane.ring.foregroundPid());

    // The agent pushes META{foreground_pid} on the session channel when the pty
    // foreground group changes; the control reader signals the pane's ring.
    try h.ctrl_agent.sendJson(.meta, pane.id, protocol.Meta{ .foreground_pid = 7777 });
    const RingWait = struct {
        ring: *ring.Channel,
        fn done(self: *@This()) bool {
            return self.ring.foregroundPid() == 7777;
        }
    };
    var rw: RingWait = .{ .ring = pane.ring };
    try spinUntil(RingWait, &rw, RingWait.done);

    // A META with NO foreground_pid (title/cwd-only, or an older agent) must not
    // disturb the cached value; an unknown channel is dropped silently.
    try h.ctrl_agent.sendJson(.meta, pane.id, protocol.Meta{ .title = "hi" });
    try h.ctrl_agent.sendJson(.meta, 0xDEADBEEF, protocol.Meta{ .foreground_pid = 1 });

    // The link stays healthy: input still round-trips after those frames.
    try testing.expectEqual(@as(i64, 7777), pane.ring.foregroundPid());
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

    // The agent recorded the unsub. On the wall-clock budget (T472), so a
    // loaded box cannot turn a slow round trip into a failure.
    var deadline = try TestDeadline.start();
    while (!a.saw_metrics_unsub.load(.monotonic)) deadline.yield() catch break;
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

test "closeSession: the agent's CLOSE_SESSION_RESULT wakes the RPC (T96)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    try h.start();

    // The whole point of the test is that this returns on the REPLY, not on the
    // timeout: a generous bound would pass either way, so the bound is far below
    // any plausible round trip over a loopback.
    const ok = try h.conn.closeSession("0123456789abcdef0123456789abcdef", 2 * std.time.ns_per_s);
    try testing.expect(a.saw_close_session.load(.monotonic));
    try testing.expect(ok);

    // An id the agent doesn't have answers definitively (found=false ⇒ ok=false)
    // rather than going quiet — the caller must be able to tell "already gone"
    // from "never answered".
    try testing.expect(!try h.conn.closeSession(a.close_session_miss_id, 2 * std.time.ns_per_s));
    try testing.expect(a.err == null);
}

test "closeSession: a silent agent times out instead of wedging the caller (T96)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.silent_close_session = true;
    try h.start();

    try testing.expectError(
        error.Timeout,
        h.conn.closeSession("0123456789abcdef0123456789abcdef", 50 * std.time.ns_per_ms),
    );
    try testing.expect(a.saw_close_session.load(.monotonic));
    try testing.expect(a.err == null);
}

test "closeSession: an agent that never advertised the capability is refused (T96)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.advertise_close_session = false;
    try h.start();

    // Gate the opcode rather than emit one an older agent would treat as a fatal
    // framing error — and fail INSTANTLY, without burning the RPC timeout.
    try testing.expectError(
        error.Unsupported,
        h.conn.closeSession("0123456789abcdef0123456789abcdef", 2 * std.time.ns_per_s),
    );
    try testing.expect(!a.saw_close_session.load(.monotonic));
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
    // T536 audit: a failed wait below must not leave the worker parked on the
    // RPC — it would later write `result` into this dead stack frame. Shutdown
    // fails every pending RPC, so the join is prompt.
    var worker_joined = false;
    errdefer if (!worker_joined) {
        h.conn.shutdown();
        thread.join();
    };

    // Wait until the OPEN is on the wire (the slot is registered before the
    // send), then cancel: flag first, then the slot walk (the required order).
    try test_util.waitEvent(&h.agent.saw_request);
    const t = std.time.milliTimestamp();
    canceller.cancel();
    h.conn.cancelRpcsFor(&canceller);
    thread.join();
    worker_joined = true;
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
    // T536 audit: disarming errdefer — see the cancelRpcsFor test above.
    var worker_joined = false;
    errdefer if (!worker_joined) {
        h.conn.shutdown();
        thread.join();
    };

    // Once the OPEN is on the wire, kill the control lane (models the
    // transport dying mid-RPC). The control reader sees EOF and exits; its
    // exit must fail the parked caller immediately.
    try test_util.waitEvent(&h.agent.saw_request);
    const t = std.time.milliTimestamp();
    h.ctrl_lb.clientStream().close();
    thread.join();
    worker_joined = true;
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
    var spawned: usize = 0;
    // T536 audit: if spawn i fails, workers 0..i are parked on their OPENs and
    // would outlive this frame — shutdown fails those RPCs so the joins are
    // prompt. Once all N spawned, the join loop below owns them (spawned == N
    // keeps this errdefer inert on later error returns).
    errdefer if (spawned < N) {
        h.conn.shutdown();
        for (threads[0..spawned]) |t| t.join();
    };
    for (&workers, 0..) |*w, i| {
        w.* = .{ .conn = h.conn };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
        spawned = i + 1;
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
    try test_util.waitEvent(&h.agent.saw_request);

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
    // The agent's head. It used to be 10 here, BEHIND the client's
    // last_byte_offset of 11 — a state the protocol cannot produce (both are
    // "next byte" indices in one space, so a client cannot have applied a byte
    // the agent never emitted) and one the T532 clamp now treats as the
    // stale-stream signal it is. Set it where a real resumed attach puts it:
    // at or above what the client has applied.
    a.snapshot_at_offset = 20;
    a.tty = "/dev/ttys020";
    try h.start();

    // The client already APPLIED absolute bytes [0,11) (last_byte_offset = 11 =
    // next byte it expects). Replayed/overlapping bytes below that watermark
    // must be dropped; everything from 11 on must land.
    var outcome = try h.conn.attachChannel("session-xyz", 24, 80, 11, false);
    defer outcome.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, outcome.status);
    try testing.expectEqual(@as(u64, 20), outcome.snapshot_at_offset);
    // Untouched by the clamp: this resume point is behind the head.
    try testing.expectEqual(@as(u64, 11), outcome.resume_offset);
    try testing.expect(!outcome.attached_elsewhere);
    const pane = outcome.pane orelse return error.NoPane;
    try testing.expectEqualStrings("/home/me", outcome.cwd.?);
    try testing.expectEqualStrings("remote", outcome.title.?);
    // pid/tty ride the alive ATTACHED (wp3) — the app-relaunch recovery path.
    try testing.expectEqual(@as(i64, 4242), pane.pid);
    try testing.expectEqualStrings("/dev/ttys020", pane.tty.?);

    try test_util.waitEvent(&h.agent.saw_request);
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

test "resumeOffset: a resume point can never be ahead of the agent's stream head (T532)" {
    // Normal resumes are untouched: behind the head, and exactly caught up.
    try testing.expectEqual(@as(u64, 11), Connection.resumeOffset(11, 1000));
    try testing.expectEqual(@as(u64, 1000), Connection.resumeOffset(1000, 1000));
    try testing.expectEqual(@as(u64, 0), Connection.resumeOffset(0, 1000));

    // Ahead of the head is impossible in a healthy stream, so it is evidence
    // that the stream restarted under this session id — clamp to the head.
    try testing.expectEqual(@as(u64, 1000), Connection.resumeOffset(43_394_044, 1000));

    // A head of 0 is ambiguous (a session that produced nothing, or a peer too
    // old to report one), so it never triggers the clamp: a wrong clamp here
    // would re-deliver bytes the client already has, and this guard exists to
    // fix a freeze, not to trade it for a double-paint.
    try testing.expectEqual(@as(u64, 11), Connection.resumeOffset(11, 0));
}

test "attachChannel: a resume point AHEAD of the agent's head is clamped, not armed (T532)" {
    // 2026-08-06: a user hard-killed the app, relaunched, and every restored
    // pane painted perfectly and was dead — no echo, no output — while the app
    // logged a successful attach at every step. This is that failure in one
    // test. The client's recorded offset (43 MB, from a manifest written before
    // the session's byte stream restarted under the same id) is far ahead of
    // the agent's actual head, so arming the §7.3 watermark at it discards
    // EVERY byte the agent will ever send: the agent's own grid snapshot, and
    // then live output, forever. The pane still paints — from the viewer's own
    // persisted snapshot — and input still reaches the child, which is exactly
    // why it reads as "repainted correctly, non-interactive, still working".
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .alive;
    a.snapshot_at_offset = 1000; // the agent's stream head
    try h.start();

    var outcome = try h.conn.attachChannel("session-xyz", 24, 80, 43_394_044, false);
    defer outcome.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, outcome.status);
    const pane = outcome.pane orelse return error.NoPane;

    try test_util.waitEvent(&h.agent.saw_request);
    const ch = pane.id;

    // The agent's grid snapshot lands AT its head; live output follows it.
    // Asserted BEFORE the bookkeeping below on purpose: without the clamp this
    // drain is what fails (with `error.Timeout` — nothing ever arrives), which
    // is the user-visible freeze rather than a mismatched number.
    try agentSendData(&h.data_agent, ch, 1000, "SNAPSHOT");
    try agentSendData(&h.data_agent, ch, 1008, "LIVE!");

    const expected = "SNAPSHOTLIVE!";
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try drainChannel(pane.ring, &got, alloc, expected.len);
    try testing.expectEqualStrings(expected, got.items);

    // The caller is TOLD what was honored, because its own absolute offset base
    // has to be rebased too — otherwise every later `appliedOffset()`, and the
    // manifest entry written from it, stays in the phantom future and the next
    // restore freezes again.
    try testing.expectEqual(@as(u64, 1000), outcome.resume_offset);

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

    try test_util.waitEvent(&h.agent.saw_request);
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

test "attachChannel: dead+relaunchable surfaces relaunchable + the session channel (T12c)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .dead;
    a.attach_relaunchable = true; // a disk-materialized tombstone, no exit_code
    try h.start();

    var outcome = try h.conn.attachChannel("reboot-floor", 24, 80, 0, false);
    defer outcome.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.dead, outcome.status);
    try testing.expect(outcome.relaunchable);
    try testing.expect(outcome.pane == null);
    // The channel the ATTACHED arrived on is retained so a follow-up RELAUNCH can
    // target the same channel the agent will stream the respawned session on.
    try test_util.waitEvent(&a.saw_request);
    try testing.expectEqual(a.seenChannel(), outcome.channel);
    try testing.expect(outcome.channel != 0);
}

test "relaunchChannel: revives a dead session → live pane, fresh stream routes DATA (T12c)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .dead;
    a.attach_relaunchable = true;
    a.relaunch_ok = true;
    a.relaunch_pid = 31337;
    try h.start();

    // 1) Dead attach learns the session channel.
    var outcome = try h.conn.attachChannel("sess-reboot", 24, 80, 0, false);
    defer outcome.deinit();
    try testing.expect(outcome.pane == null);
    const channel = outcome.channel;

    // 2) RELAUNCH on that channel → a live pane streaming from offset 0.
    const r = try h.conn.relaunchChannel("sess-reboot", channel, 24, 80, 0, 0);
    try testing.expect(r.ok);
    try testing.expect(r.found);
    try testing.expectEqual(@as(i64, 31337), r.pid);
    const pane = r.pane orelse return error.NoPane;
    try testing.expectEqual(channel, pane.id);
    try testing.expectEqualStrings("sess-reboot", pane.session_id);

    // The RELAUNCH went out on the SAME channel the dead ATTACHED came in on.
    try testing.expect(a.saw_relaunch.load(.monotonic));
    try testing.expectEqual(channel, a.relaunchChannel());

    // Fresh output on the channel (offset 0, no resync discard) lands in the ring.
    try agentSendData(&h.data_agent, pane.id, 0, "back after reboot");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try drainChannel(pane.ring, &got, alloc, "back after reboot".len);
    try testing.expectEqualStrings("back after reboot", got.items);

    try testing.expect(a.err == null);
    h.conn.closeChannel(pane);
}

test "relaunchChannel: ok=false found=false → no pane, channel torn down (T12c)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .dead;
    a.attach_relaunchable = true;
    a.relaunch_ok = false; // agent reaped the tombstone between attach and relaunch
    a.relaunch_found = false;
    try h.start();

    var outcome = try h.conn.attachChannel("sess-gone", 24, 80, 0, false);
    defer outcome.deinit();
    const channel = outcome.channel;

    const r = try h.conn.relaunchChannel("sess-gone", channel, 24, 80, 0, 0);
    try testing.expect(!r.ok);
    try testing.expect(!r.found);
    try testing.expect(r.pane == null);
    // The pre-registered channel was deregistered: later DATA on it is dropped
    // without crashing (no pane owns it).
    try agentSendData(&h.data_agent, channel, 0, "should be dropped");
    try testing.expect(a.err == null);
}

test "prompt relaunch: prepareRelaunchPane holds a childless pane; sendRelaunchOnPane revives it (T12c2)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .dead;
    a.attach_relaunchable = true;
    a.relaunch_ok = true;
    a.relaunch_pid = 4242;
    a.tty = "/dev/ttys021";
    try h.start();

    // 1) Dead attach learns the session channel (the viewer's prompt-policy path).
    var outcome = try h.conn.attachChannel("sess-prompt", 24, 80, 0, false);
    defer outcome.deinit();
    try testing.expect(outcome.pane == null);
    const channel = outcome.channel;

    // 2) Prepare a live-but-childless pane WITHOUT sending RELAUNCH (awaiting user
    //    consent). The ring is registered but no respawn has happened yet.
    const pane = try h.conn.prepareRelaunchPane("sess-prompt", channel);
    try testing.expectEqual(channel, pane.id);
    try testing.expectEqualStrings("sess-prompt", pane.session_id);
    try testing.expectEqual(@as(i64, 0), pane.pid); // no child yet
    try testing.expect(pane.tty == null); // no pty yet either
    try testing.expect(!a.saw_relaunch.load(.monotonic)); // no RELAUNCH sent yet

    // 3) User consents (a keystroke) → send RELAUNCH on the pane's channel.
    const res = try h.conn.sendRelaunchOnPane(pane, 24, 80, 0, 0, .{}, null);
    try testing.expect(res.ok);
    try testing.expect(res.found);
    try testing.expectEqual(@as(i64, 4242), res.pid);
    try testing.expectEqual(@as(i64, 4242), pane.pid); // pid filled in on success
    try testing.expectEqualStrings("/dev/ttys021", pane.tty.?); // fresh pty's tty too (wp3)
    try testing.expect(a.saw_relaunch.load(.monotonic));
    try testing.expectEqual(channel, a.relaunchChannel());

    // 4) Fresh output on the (already-registered) channel lands in the ring.
    try agentSendData(&h.data_agent, pane.id, 0, "prompt back");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try drainChannel(pane.ring, &got, alloc, "prompt back".len);
    try testing.expectEqualStrings("prompt back", got.items);

    try testing.expect(a.err == null);
    h.conn.closeChannel(pane);
}

test "prompt relaunch: sendRelaunchOnPane ok=false leaves the pane childless + detachable (T12c2)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.attach_status = .dead;
    a.attach_relaunchable = true;
    a.relaunch_ok = false; // reaped between prepare and consent
    a.relaunch_found = false;
    try h.start();

    var outcome = try h.conn.attachChannel("sess-prompt-gone", 24, 80, 0, false);
    defer outcome.deinit();
    const channel = outcome.channel;

    const pane = try h.conn.prepareRelaunchPane("sess-prompt-gone", channel);
    const res = try h.conn.sendRelaunchOnPane(pane, 24, 80, 0, 0, .{}, null);
    try testing.expect(!res.ok);
    try testing.expect(!res.found);
    // The pane is NOT torn down by a failed send (unlike the auto RelaunchOutcome
    // path) — the prompt path keeps it so the surface can show a note, and threadExit
    // detaches it cleanly. No child was ever installed.
    try testing.expectEqual(@as(i64, 0), pane.pid);
    try testing.expect(a.err == null);
    h.conn.detachChannel(pane);
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

test "attachChannelRefusable: ATTACH_FAILED is the ATTACH's answer, with its reason (T657)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.refuse_attach = protocol.AttachFailed.Reason.malformed_request;
    try h.start();

    var refusal: protocol.RefusalCopy = .{};
    const err = h.conn.attachChannelRefusable("sess-1", 24, 80, 0, false, null, &refusal);

    // A refusal, not a wrong-type frame and not a timeout: the whole point is
    // that the caller learns WHY in milliseconds.
    try testing.expectError(error.AttachRefused, err);
    try testing.expectEqualStrings("malformed_request", refusal.reason());
    try testing.expectEqualStrings("why-it-said-no", refusal.detail().?);
}

test "attachChannelRefusable: a reason we cannot parse is still a refusal, not a timeout (T657)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    // A NEWER agent could reshape the payload; degrading "refused, reason
    // unknown" into a 10 s timeout would be strictly worse than saying so
    // generically.
    a.refuse_attach = "a_token_this_build_never_heard_of";
    try h.start();

    var refusal: protocol.RefusalCopy = .{};
    try testing.expectError(
        error.AttachRefused,
        h.conn.attachChannelRefusable("sess-1", 24, 80, 0, false, null, &refusal),
    );
    // Carried through verbatim — the SENTENCE is chosen client-side by
    // `termio/attach_failed_notice.zig`, which renders an unknown token
    // generically rather than echoing it at a user.
    try testing.expectEqualStrings("a_token_this_build_never_heard_of", refusal.reason());
}

test "attachChannel: an agent too old to refuse out loud still just times out (T657)" {
    const alloc = testing.allocator;
    const h = try LifecycleHarness.create(alloc);
    defer h.destroy();
    const a = h.configure();
    a.silent_attach = true; // never advertised `attach_failed`; drops the request
    try h.start();
    // Keep the fallback quick: the point is WHICH error, not how long we wait.
    h.conn.rpc_open_timeout_ns = 200 * std.time.ns_per_ms;

    var refusal: protocol.RefusalCopy = .{};
    try testing.expectError(
        error.Timeout,
        h.conn.attachChannelRefusable("sess-1", 24, 80, 0, false, null, &refusal),
    );
    // ...and the refusal is untouched, which is how a caller tells "known
    // reason" from "no more than we knew before" and keeps the generic text.
    try testing.expectEqual(@as(usize, 0), refusal.reason().len);
}

test "acceptsReply: each negative reply answers its own request, and nothing else" {
    // `open_failed` answers OPEN and `attach_failed` answers ATTACH — never the
    // other way round. Crossed, a refused OPEN would satisfy a parked ATTACH
    // and the pane would report the wrong failure entirely.
    try testing.expect(Connection.acceptsReply(.opened, .open_failed));
    try testing.expect(Connection.acceptsReply(.attached, .attach_failed));
    try testing.expect(!Connection.acceptsReply(.opened, .attach_failed));
    try testing.expect(!Connection.acceptsReply(.attached, .open_failed));
    // Same type is always a reply; an unrelated type never is.
    try testing.expect(Connection.acceptsReply(.attached, .attached));
    try testing.expect(!Connection.acceptsReply(.attached, .relaunched));
}

test "FLOW pause: a full undrained ring makes the agent receive FLOW{channel, pause} (§4.3)" {
    const alloc = testing.allocator;
    // Small control/data loopback; a tiny-capacity channel so a little DATA fills it.
    var ctrl_lb = Loopback.init(alloc);
    defer ctrl_lb.deinit();
    var data_lb = Loopback.init(alloc);
    defer data_lb.deinit();

    // A small channel (no pane needed for the pure FLOW path); capacity 64,
    // high_water 48 so ~48 undrained bytes trip the pause edge. Created BEFORE
    // the connection so its `deinit` defer runs LAST — the data reader that
    // pushes into this ring must be joined before the ring is freed (T693).
    const ch_id: u128 = 0xF10F10;
    var ch = try ring.Channel.init(alloc, ch_id, .{ .capacity = 64, .high_water = 48, .low_water = 8 });
    defer ch.deinit(alloc);

    const conn = try Connection.createOpts(
        alloc,
        ctrl_lb.clientStream(),
        data_lb.clientStream(),
        .{ .transfer_encoding = .raw },
        .{ .heartbeat_interval_ms = 100_000 },
    );
    defer conn.destroy(alloc);
    try conn.registerChannel(&ch);

    var ctrl_agent = MockAgent.init(alloc, ctrl_lb.agentStream(), .raw);
    defer ctrl_agent.deinit();
    var data_agent = MockAgent.init(alloc, data_lb.agentStream(), .raw);
    defer data_agent.deinit();

    // The control agent answers the handshake (and would PONG, but we never PING).
    var hctx = HandshakeAgentCtx{ .agent = &ctrl_agent };
    const cth = try std.Thread.spawn(.{}, HandshakeAgentCtx.run, .{&hctx});
    // Same disarming errdefer as the inbound-routing test: an early failure
    // must not leave this thread parked on a read into `ctrl_agent` after the
    // body returns, and a second join after the explicit one is UB.
    var cth_joined = false;
    errdefer if (!cth_joined) {
        conn.shutdown();
        cth.join();
    };

    try conn.start();
    _ = try conn.waitHandshake();
    cth.join();
    cth_joined = true;

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
    try test_util.waitEvent(&h.agent.saw_request);
    const ch = pane.id;

    h.conn.closeChannel(pane);
    // The agent must receive a CLOSE frame.
    try test_util.waitEvent(&h.agent.close_detach_seen);
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
    try test_util.waitEvent(&h.agent.saw_request);
    const ch = pane.id;

    h.conn.detachChannel(pane);
    try test_util.waitEvent(&h.agent.close_detach_seen);
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
    // T536 audit: disarming errdefer — see the handshake test above.
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };

    try conn.start();
    _ = try conn.waitHandshake();
    ath.join();
    ath_joined = true;

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
    // T536 audit: the shutdown below fails the parked OPEN, so on a failed
    // wait the caller thread still exits — join it rather than leak it.
    var oth_joined = false;
    errdefer if (!oth_joined) oth.join();

    // Give the OPEN a moment to register its pending slot, then shut down.
    // (No reply will come; shutdown is what unblocks it.)
    conn.shutdown();
    try test_util.waitEvent(&oc.done);
    oth.join();
    oth_joined = true;
    try testing.expectError(error.ConnectionClosed, oc.result);
}

// Pull in the ssh Transport test suite (§4.1) so `zig test src/remote/connection.zig`
// exercises the real `connection.Stream`-over-ssh implementation alongside the
// in-memory loopback transport tests above.
test {
    _ = @import("ssh_transport.zig");
}
