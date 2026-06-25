//! Client-side `RemoteConnection` transport core (WP3, increment 1).
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

/// One queued outbound frame, owned by the writer queue until the writer emits it.
/// `payload` is a private heap copy the queue owns and frees; the caller's slice is
/// not retained past `enqueue`.
const OutFrame = struct {
    stream: StreamId,
    ftype: protocol.FrameType,
    channel: u128,
    payload: []u8,
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

    /// Per-connection frame sequence (§4.2). Assigned by the writer thread at send
    /// time so seq order matches wire order, single-writer (no atomics needed).
    frame_seq: protocol.FrameSeq = .{},

    /// Inbound DATA routing table (§3.4). The data reader pushes into it under its
    /// lock; the caller registers/deregisters the per-pane channels.
    channels: ring.ChannelTable,

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

    /// Allocate and initialize a connection over the two given channel streams.
    /// Does not spawn any thread or touch the wire — call `start` for that.
    pub fn create(
        alloc: Allocator,
        control: Stream,
        data: Stream,
        local_hello: protocol.Hello,
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
        };
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

        self.started = true;
    }

    /// Block until the handshake completes; return the negotiated parameters or
    /// the negotiation error (version/encoding mismatch, or a malformed peer
    /// HELLO / dropped control stream surfaced as `error.Incompatible`).
    pub fn waitHandshake(self: *Connection) !protocol.Negotiated {
        self.handshake_done.wait();
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
        self.writer_thread = null;
        self.control_thread = null;
        self.data_thread = null;
        self.state_mutex.unlock();

        // Wake the writer to drain-and-exit, and unblock both reader reads.
        self.signalClose();
        self.control.close();
        self.data.close();

        if (writer) |t| t.join();
        if (control) |t| t.join();
        if (data) |t| t.join();

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
        self.write_queue.deinit(alloc);
        self.channels.deinit();
        alloc.destroy(self);
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

        // --- Routing phase: dispatch every control frame to the handler. ---
        while (true) {
            while (reader.next() catch return) |frame| {
                if (self.ctrl_handler) |handler| {
                    handler(self.ctrl_handler_ctx, self, frame);
                }
            }
            const n = self.control.read(&scratch) catch return;
            if (n == 0) return; // EOF
            reader.push(scratch[0..n]) catch return;
        }
    }

    /// Parse a peer HELLO payload and negotiate it against our local HELLO.
    fn negotiatePeerHello(self: *Connection, payload: []const u8) protocol.ProtocolError!protocol.Negotiated {
        var parsed = protocol.Hello.parse(self.alloc, payload) catch return error.Incompatible;
        defer parsed.deinit();
        return protocol.negotiate(self.local_hello, parsed.value);
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

    /// The data reader. Loops read → push → drain. For each DATA frame, decode the
    /// payload and route the raw child bytes into the target channel's inbound ring
    /// (`pushTo`). An unknown channel id is dropped (§15 M3 — never crash). Non-DATA
    /// frames on the data stream are ignored. Exits on EOF or a protocol error.
    fn dataReaderLoop(self: *Connection) void {
        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;

        while (true) {
            while (reader.next() catch return) |frame| {
                if (frame.type != .data) continue; // ignore non-DATA on this lane
                const dp = protocol.DataPayload.decode(frame.payload) catch continue;
                // Route the raw bytes; `.unknown` (stale/hostile channel) is dropped.
                _ = self.channels.pushTo(frame.channel, dp.bytes);
            }
            const n = self.data.read(&scratch) catch return;
            if (n == 0) return; // EOF
            reader.push(scratch[0..n]) catch return;
        }
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
