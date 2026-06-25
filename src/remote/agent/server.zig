//! Agent session-server core (WP2, increment 1) — the remote-host side of the
//! remote-machines wire protocol. It is the **symmetric peer** of the client
//! `src/remote/connection.zig`: where the client opens/attaches and renders, the
//! agent spawns/owns the child processes and streams their output back.
//!
//! Scope of THIS increment (§4.1–4.2 bootstrap/handshake, §7.1 session model):
//!
//!   - Read the client HELLO on control, reply with the agent HELLO echoing the
//!     pinned `transfer_encoding`, confirm via `protocol.negotiate` (§4.2).
//!   - A serialized MPSC writer thread that frames via `protocol.writeFrame` onto
//!     the correct channel (control vs data), assigning the per-connection
//!     `FrameSeq` at send time so seq order == wire order (mirrors the client).
//!   - A control reader thread that handshakes then dispatches every inbound
//!     control frame, and a data reader thread that routes inbound DATA to the
//!     owning session's child (keystrokes).
//!   - Frame handling: OPEN→OPENED + live DATA streaming; client DATA→child;
//!     ATTACH (alive/dead/not_found) with a byte-offset-anchored snapshot;
//!     RESIZE/SIGNAL/DETACH/CLOSE; EXIT-after-final-DATA on child exit; PING→PONG;
//!     FLOW pause/resume gating.
//!
//! Untrusted input (§15 M3): `protocol.Reader` bounds every frame; we additionally
//! validate session/channel **ownership** (an inbound channel must belong to a
//! session this connection opened) — unknown ids/channels are ignored, never a
//! crash.
//!
//! ## Stubbed vs real (increment 1)
//!
//!   - **Transport** (`Stream`): abstract vtable; tests drive it over an in-memory
//!     loopback. Real impl wraps the two ssh-channel pipe fds — out of scope.
//!   - **Child**: abstract (`session.Child`); only a fake, pipe/buffer-backed child
//!     is provided (tests feed its output). Real pty via `src/pty.zig` is a later
//!     increment (`// TODO(pty)`).
//!   - **Snapshot**: `ATTACHED.snapshot_at_offset` is the session's current
//!     outbound offset `S`; a real grid snapshot (§7.3) is `// TODO(snapshot)`.
//!   - Daemonization, idle-TTL GC, RPC, tunnels, Windows: out of scope.
//!
//! ## Driving it (test harness pattern)
//!
//!   var server = try Server.create(alloc, control_stream, data_stream, .{...});
//!   try server.start();                 // spawns writer + 2 readers
//!   _ = try server.waitHandshake();     // blocks until HELLOs exchanged
//!   ... a mock client drives frames over the loopback ...
//!   server.shutdown();                  // unblocks + joins all threads
//!   server.destroy(alloc);
//!
//! ## Running the tests
//!
//! These modules depend on `../protocol.zig`, which a plain
//! `zig test src/remote/agent/server.zig` can't reach ("import outside module
//! path"). Wire `protocol` in as a named module:
//!
//!   zig test --dep protocol \
//!     -Mroot=src/remote/agent/server.zig \
//!     -Mprotocol=src/remote/protocol.zig
//!
//! (same shape for `session.zig`). The real build wires this via `build.zig`,
//! which is out of scope for this increment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const protocol = @import("protocol");
const session = @import("session.zig");

/// Scratch read buffer per reader thread's blocking `Stream.read`.
const read_buf_size = 64 * 1024;

// -----------------------------------------------------------------------------
// Stream — an abstract bidirectional byte stream for ONE ssh channel
// -----------------------------------------------------------------------------

/// A blocking, bidirectional byte stream abstracting one ssh channel. Identical in
/// shape to the client's `connection.Stream` (the agent is the symmetric peer) but
/// defined here so the agent module is self-contained (depends only on `protocol`).
///
/// Threading: one reader thread calls `read` and the single writer thread calls
/// `writeAll` per stream, so an impl need not make `read`/`write` mutually
/// thread-safe — only `close` must be safe to call concurrently with a blocked
/// `read` (it unblocks it) and idempotent.
pub const Stream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Blocking read of up to `buf.len` bytes; returns the count. `0` ⇒ EOF.
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        /// Write some of `bytes`; returns count written (writeAll loops).
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        /// Unblock any pending `read` and mark EOF. Idempotent, concurrency-safe.
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn read(self: Stream, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ctx, buf);
    }

    pub fn writeAll(self: Stream, bytes: []const u8) anyerror!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try self.vtable.write(self.ctx, bytes[off..]);
            if (n == 0) return error.WriteZero;
            off += n;
        }
    }

    pub fn close(self: Stream) void {
        self.vtable.close(self.ctx);
    }
};

// -----------------------------------------------------------------------------
// Clock — injectable monotonic-ms source (deterministic in tests)
// -----------------------------------------------------------------------------

/// A millisecond clock. The real agent uses the wall clock; tests inject a fixed
/// one so timestamps/runtime are deterministic.
pub const Clock = struct {
    ctx: *anyopaque,
    nowFn: *const fn (ctx: *anyopaque) i64,

    pub fn now(self: Clock) i64 {
        return self.nowFn(self.ctx);
    }

    fn realNow(_: *anyopaque) i64 {
        return std.time.milliTimestamp();
    }

    /// A wall-clock implementation.
    pub fn real() Clock {
        return .{ .ctx = undefined, .nowFn = realNow };
    }
};

// -----------------------------------------------------------------------------
// Spawner — how the agent turns an OPEN into a Child (injectable)
// -----------------------------------------------------------------------------

/// Spawns a child for an `OPEN` request. The real spawner forks a process on a pty
/// (`src/pty.zig`) and returns a pid + a `Child` whose output-reader thread calls
/// the session's sink. For this increment a test injects a fake spawner that hands
/// back a buffer-backed `FakeChild`. `// TODO(pty)`.
///
/// The returned `Result.child` must remain valid until the session's child is
/// `terminate()`d. The spawner owns any backing storage and frees it on terminate.
pub const Spawner = struct {
    ctx: *anyopaque,
    spawnFn: *const fn (ctx: *anyopaque, open: protocol.Open) anyerror!Result,

    pub const Result = struct {
        child: session.Child,
        pid: i64,
    };

    pub fn spawn(self: Spawner, open: protocol.Open) anyerror!Result {
        return self.spawnFn(self.ctx, open);
    }
};

// -----------------------------------------------------------------------------
// Outbound queue (MPSC → single writer thread), mirroring the client
// -----------------------------------------------------------------------------

/// Which ssh channel a queued frame is destined for.
const StreamId = enum { control, data };

/// One queued outbound frame; the writer owns `payload` (a private heap copy) and
/// frees it after emit.
const OutFrame = struct {
    stream: StreamId,
    ftype: protocol.FrameType,
    channel: u128,
    payload: []u8,
};

// -----------------------------------------------------------------------------
// Server
// -----------------------------------------------------------------------------

/// The agent's per-connection server: owns the two streams, the session table, the
/// writer thread, and the reader threads. One `Server` per accepted ssh
/// connection. Heap-allocated (`create`) so its address is stable for the threads.
pub const Server = struct {
    alloc: Allocator,
    control: Stream,
    data: Stream,
    encoding: protocol.TransferEncoding,
    local_hello: protocol.Hello,
    clock: Clock,
    spawner: Spawner,

    /// Session registry (§7.1). Guarded by `sess_mutex`.
    sess_mutex: std.Thread.Mutex = .{},
    table: session.SessionTable,

    /// Outbound MPSC queue + the single writer thread (§3.4).
    write_mutex: std.Thread.Mutex = .{},
    write_cond: std.Thread.Condition = .{},
    write_queue: std.ArrayList(OutFrame) = .empty,
    frame_seq: protocol.FrameSeq = .{},

    /// Handshake completion gate + result.
    handshake_done: std.Thread.ResetEvent = .{},
    negotiated: anyerror!protocol.Negotiated = error.Incompatible,

    started: bool = false,
    closed: bool = false,

    writer_thread: ?std.Thread = null,
    control_thread: ?std.Thread = null,
    data_thread: ?std.Thread = null,

    /// Per-session ring size (from Options), read by `create`'s table inserts.
    ring_bytes: usize = session.default_ring_bytes,
    /// Owned PRNG, freed in `destroy`. Always allocated (even when the caller
    /// supplied `opts.rng`) for uniform teardown.
    prng: *std.Random.DefaultPrng,

    pub const Options = struct {
        /// The pinned transfer encoding for this connection (§4.2). The agent
        /// echoes it in its HELLO; both sides must already agree.
        encoding: protocol.TransferEncoding,
        /// Capabilities the agent advertises in its HELLO.
        capabilities: []const []const u8 = &.{
            protocol.capability.resync,
            protocol.capability.flow,
        },
        /// Per-session raw-output ring size (§7.1). Lowered in tests.
        ring_bytes: usize = session.default_ring_bytes,
        clock: ?Clock = null,
        /// Deterministic RNG override for id/channel minting (tests). When null a
        /// fresh OS-seeded `DefaultPrng` is created and owned by the server.
        rng: ?std.Random = null,
    };

    pub fn create(
        alloc: Allocator,
        control: Stream,
        data: Stream,
        spawner: Spawner,
        opts: Options,
    ) Allocator.Error!*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        // Own a PRNG if the caller didn't supply one. Seeded from the OS so session
        // ids are unpredictable (§7.1 crypto-random) in production; deterministic
        // in tests via `opts.rng`.
        const prng = try alloc.create(std.Random.DefaultPrng);
        errdefer alloc.destroy(prng);
        var seed: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&seed));
        prng.* = std.Random.DefaultPrng.init(seed);
        const rng = opts.rng orelse prng.random();

        self.* = .{
            .alloc = alloc,
            .control = control,
            .data = data,
            .encoding = opts.encoding,
            .local_hello = .{
                .transfer_encoding = opts.encoding,
                .capabilities = opts.capabilities,
            },
            .clock = opts.clock orelse Clock.real(),
            .spawner = spawner,
            .table = session.SessionTable.init(alloc, rng),
            .ring_bytes = opts.ring_bytes,
            .prng = prng,
        };
        return self;
    }

    /// Start the writer + reader threads. Queues our HELLO first so it is the first
    /// control frame (the §4.2 "HELLO first in each direction" rule).
    pub fn start(self: *Server) !void {
        assert(!self.started);

        const hello_json = try self.local_hello.encode(self.alloc);
        defer self.alloc.free(hello_json);
        try self.enqueue(.control, .hello, protocol.control_channel, hello_json);

        self.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{self});
        errdefer {
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
        self.started = true;
    }

    /// Block until the handshake completes; return the negotiated params or the
    /// negotiation error.
    pub fn waitHandshake(self: *Server) !protocol.Negotiated {
        self.handshake_done.wait();
        return self.negotiated;
    }

    /// Stop everything: close streams (unblocks reader threads at EOF), wake + drain
    /// the writer, join all threads. Safe to call once; idempotent on the flag.
    pub fn shutdown(self: *Server) void {
        self.signalClose();
        self.control.close();
        self.data.close();
        if (self.control_thread) |t| t.join();
        self.control_thread = null;
        if (self.data_thread) |t| t.join();
        self.data_thread = null;
        if (self.writer_thread) |t| t.join();
        self.writer_thread = null;
        // In case a handshake never completed, release any waiter.
        if (!self.handshake_done.isSet()) {
            self.negotiated = error.Incompatible;
            self.handshake_done.set();
        }
    }

    /// Free the server (must be shut down first). Frees the session table (which
    /// terminates every child), any still-queued outbound payloads, and the PRNG.
    pub fn destroy(self: *Server, alloc: Allocator) void {
        assert(self.control_thread == null and self.data_thread == null and self.writer_thread == null);
        self.table.deinit();
        for (self.write_queue.items) |f| self.alloc.free(f.payload);
        self.write_queue.deinit(self.alloc);
        alloc.destroy(self.prng);
        alloc.destroy(self);
    }

    fn signalClose(self: *Server) void {
        self.write_mutex.lock();
        self.closed = true;
        self.write_cond.signal();
        self.write_mutex.unlock();
    }

    // --- Outbound -------------------------------------------------------------

    /// Enqueue a frame for the writer thread. Dups `payload` into queue-owned
    /// memory. On OOM the frame is dropped (best effort) since the caller (a reader
    /// thread) has nowhere useful to surface it.
    fn enqueue(
        self: *Server,
        stream: StreamId,
        ftype: protocol.FrameType,
        channel: u128,
        payload: []const u8,
    ) Allocator.Error!void {
        const owned = try self.alloc.dupe(u8, payload);
        errdefer self.alloc.free(owned);
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.closed) {
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

    /// Enqueue a JSON control frame (OPENED/ATTACHED/EXIT/META/...).
    fn sendJson(self: *Server, ftype: protocol.FrameType, channel: u128, value: anytype) !void {
        const json = try protocol.encodeJson(self.alloc, value);
        defer self.alloc.free(json);
        try self.enqueue(.control, ftype, channel, json);
    }

    /// Enqueue a DATA frame on the data channel (the §4.2 binary payload header).
    fn sendData(self: *Server, channel: u128, byte_offset: u64, bytes: []const u8) !void {
        const payload = try self.alloc.alloc(u8, protocol.DataPayload.encodedLen(bytes.len));
        defer self.alloc.free(payload);
        const dp: protocol.DataPayload = .{ .byte_offset = byte_offset, .bytes = bytes };
        _ = dp.encodeInto(payload);
        try self.enqueue(.data, .data, channel, payload);
    }

    // --- Child output delivery (called by the spawner's reader, or by tests) --

    /// Deliver `bytes` of child output for the session on `channel`: record into
    /// the session ring (advancing the outbound offset) and, if streaming is not
    /// FLOW-paused, frame it as DATA. Then reap-check the child and, if it exited,
    /// emit EXIT ordered AFTER this final DATA (§4.2 "EXIT ordered after final
    /// DATA"). Takes the session lock. Unknown channel ⇒ ignored.
    pub fn onChildOutput(self: *Server, channel: u128, bytes: []const u8) void {
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        const s = self.table.getByChannel(channel) orelse return;
        if (!s.alive) return;
        const now = self.clock.now();
        if (bytes.len > 0) {
            const at = s.recordOutput(bytes, now);
            if (s.streaming) {
                self.sendData(s.channel, at, bytes) catch {};
            }
        }
        self.reapLocked(s, now);
    }

    /// Reap a session's child if it exited; emit EXIT (after any final DATA already
    /// enqueued) and mark the tombstone. Caller holds `sess_mutex`.
    fn reapLocked(self: *Server, s: *session.Session, now: i64) void {
        if (!s.alive) return;
        const code = s.child.tryWait() orelse return;
        s.markExited(code, now);
        const runtime: u64 = @intCast(@max(0, now - s.created_ms));
        self.sendJson(.exit, s.channel, protocol.Exit{
            .code = code,
            .runtime_ms = runtime,
        }) catch {};
    }

    /// Explicitly poll every live session for exit (the real agent's `waitpid`
    /// reaper does this on SIGCHLD; tests call it after marking a fake child
    /// exited). Emits EXIT for any that have exited.
    pub fn reapAll(self: *Server) void {
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        const now = self.clock.now();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| self.reapLocked(sp.*, now);
    }

    // --- Writer thread (single writer; seq == wire order) ---------------------

    fn writerLoop(self: *Server) void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);
        var batch: std.ArrayList(OutFrame) = .empty;
        defer batch.deinit(self.alloc);

        while (true) {
            self.write_mutex.lock();
            while (self.write_queue.items.len == 0 and !self.closed) {
                self.write_cond.wait(&self.write_mutex);
            }
            // Swap the whole pending queue out so we hold the lock minimally.
            const pending = self.write_queue;
            self.write_queue = batch;
            batch = pending;
            const done = self.closed and batch.items.len == 0;
            self.write_mutex.unlock();

            for (batch.items) |f| {
                const frame: protocol.Frame = .{
                    .type = f.ftype,
                    .channel = f.channel,
                    .seq = self.frame_seq.next(), // single writer ⇒ seq == wire order
                    .payload = f.payload,
                };
                wire.clearRetainingCapacity();
                protocol.writeFrame(self.alloc, self.encoding, frame, &wire) catch {
                    self.alloc.free(f.payload);
                    continue;
                };
                const stream = switch (f.stream) {
                    .control => self.control,
                    .data => self.data,
                };
                stream.writeAll(wire.items) catch {};
                self.alloc.free(f.payload);
            }
            batch.clearRetainingCapacity();

            if (done) break;
        }
    }

    // --- Reader threads -------------------------------------------------------

    fn controlReaderLoop(self: *Server) void {
        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;

        // Handshake: consume frames until the client HELLO arrives.
        handshake: while (!self.handshake_done.isSet()) {
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
                self.completeHandshake(error.Incompatible);
                return;
            }
            reader.push(scratch[0..n]) catch {
                self.completeHandshake(error.Incompatible);
                break :handshake;
            };
        }
        if (std.meta.isError(self.negotiated)) return;

        // Routing: dispatch each control frame.
        while (true) {
            while (reader.next() catch return) |frame| {
                self.handleControlFrame(frame);
            }
            const n = self.control.read(&scratch) catch return;
            if (n == 0) return; // EOF
            reader.push(scratch[0..n]) catch return;
        }
    }

    fn dataReaderLoop(self: *Server) void {
        // The data lane only carries DATA frames (client keystrokes inbound). Wait
        // for the handshake so we never route before negotiation (the encoding is
        // fixed at construction, but ordering keeps semantics clean).
        self.handshake_done.wait();
        if (std.meta.isError(self.negotiated)) return;

        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;
        while (true) {
            while (reader.next() catch return) |frame| {
                if (frame.type == .data) self.handleInboundData(frame);
                // Any non-DATA on the data lane is malformed routing → ignore.
            }
            const n = self.data.read(&scratch) catch return;
            if (n == 0) return; // EOF
            reader.push(scratch[0..n]) catch return;
        }
    }

    // --- Handshake ------------------------------------------------------------

    fn completeHandshake(self: *Server, result: anyerror!protocol.Negotiated) void {
        if (self.handshake_done.isSet()) return;
        self.negotiated = result;
        self.handshake_done.set();
    }

    fn negotiatePeerHello(self: *Server, payload: []const u8) anyerror!protocol.Negotiated {
        var parsed = protocol.Hello.parse(self.alloc, payload) catch return error.Incompatible;
        defer parsed.deinit();
        return protocol.negotiate(self.local_hello, parsed.value);
    }

    // --- Control frame handling ----------------------------------------------

    /// Dispatch one inbound control frame. All payloads are untrusted; a malformed
    /// payload or unknown id is ignored (never a crash, §15 M3).
    fn handleControlFrame(self: *Server, frame: protocol.Frame) void {
        switch (frame.type) {
            .open => self.handleOpen(frame.payload),
            .attach => self.handleAttach(frame.payload),
            .resize => self.handleResize(frame.channel, frame.payload),
            .signal => self.handleSignal(frame.channel, frame.payload),
            .detach => self.handleDetach(frame.channel),
            .close => self.handleClose(frame.channel),
            .ping => self.handlePing(frame.payload),
            .flow => self.handleFlow(frame.payload),
            // Frames the agent never receives (it produces these) or that are out
            // of scope this increment: ignore.
            else => {},
        }
    }

    fn handleOpen(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Open, self.alloc, payload) catch return;
        defer parsed.deinit();
        const open = parsed.value;

        // Spawn the (fake, this increment) child. A spawn failure simply yields no
        // OPENED; a real agent would reply with an error META (out of scope).
        const spawned = self.spawner.spawn(open) catch return;

        self.sess_mutex.lock();
        const s = self.table.create(
            spawned.child,
            spawned.pid,
            open.rows,
            open.cols,
            self.ring_bytes,
            self.clock.now(),
        ) catch {
            // Cap hit or OOM: terminate the orphaned child, drop.
            self.sess_mutex.unlock();
            spawned.child.terminate();
            return;
        };
        const channel = s.channel;
        const id_copy = s.id_str; // value copy; safe to use after unlock
        const pid = s.pid;
        self.sess_mutex.unlock();

        self.sendJson(.opened, channel, protocol.Opened{
            .session_id = id_copy[0..],
            .pid = pid,
        }) catch {};
    }

    fn handleAttach(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Attach, self.alloc, payload) catch return;
        defer parsed.deinit();
        const att = parsed.value;

        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();

        const s = self.table.getByIdStr(att.session_id) orelse {
            // Unknown session → not_found. We reply on the control channel; the
            // client correlates by session_id in its pending-attach table.
            self.sendJson(.attached, protocol.control_channel, protocol.Attached{
                .status = .not_found,
            }) catch {};
            return;
        };

        if (!s.alive) {
            // Tombstone → dead + exit_code (§7.1/§7.4).
            self.sendJson(.attached, s.channel, protocol.Attached{
                .status = .dead,
                .exit_code = s.exit_code,
                .rows = s.rows,
                .cols = s.cols,
            }) catch {};
            return;
        }

        // Alive: capture the snapshot anchor S (= current outbound offset; a real
        // grid snapshot is `// TODO(snapshot)`). Resume the session's dims to the
        // attaching client's geometry and (re)enable streaming.
        const now = self.clock.now();
        s.rows = att.rows;
        s.cols = att.cols;
        s.streaming = true;
        s.last_activity_ms = now;
        s.child.resize(att.rows, att.cols, 0, 0) catch {};
        const snapshot_at = s.snapshotOffset();

        self.sendJson(.attached, s.channel, protocol.Attached{
            .status = .alive,
            .rows = s.rows,
            .cols = s.cols,
            .cwd = if (s.cwd) |c| c else null,
            .title = if (s.title) |t| t else null,
            .snapshot_at_offset = snapshot_at,
        }) catch {};

        // Gap-fill (§7.3): if the client's last_byte_offset < S and the ring still
        // retains `(last_byte_offset, S]`, replay it as DATA so the viewport has no
        // hole. If evicted, we skip it (v1 honesty: scrollback may be truncated);
        // the forthcoming snapshot makes the visible grid exact. Live DATA then
        // resumes naturally from offset > S via onChildOutput.
        if (att.last_byte_offset < snapshot_at) {
            const want: usize = @intCast(snapshot_at - att.last_byte_offset);
            const tmp = self.alloc.alloc(u8, want) catch return;
            defer self.alloc.free(tmp);
            if (s.ring.slice(att.last_byte_offset, snapshot_at, tmp)) |n| {
                self.sendData(s.channel, att.last_byte_offset, tmp[0..n]) catch {};
            }
        }
    }

    fn handleResize(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Resize, self.alloc, payload) catch return;
        defer parsed.deinit();
        const rz = parsed.value;
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        const s = self.table.getByChannel(channel) orelse return;
        if (!s.alive) return;
        s.rows = rz.rows;
        s.cols = rz.cols;
        s.px_w = rz.px_w;
        s.px_h = rz.px_h;
        s.child.resize(rz.rows, rz.cols, rz.px_w, rz.px_h) catch {};
    }

    fn handleSignal(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Signal, self.alloc, payload) catch return;
        defer parsed.deinit();
        const sig = parsed.value;
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        const s = self.table.getByChannel(channel) orelse return;
        if (!s.alive) return;
        s.setSignal(sig.name) catch {};
        s.child.signal(sig.name) catch {};
    }

    fn handleDetach(self: *Server, channel: u128) void {
        // Stop streaming; keep the session alive (§4.2/§7.1).
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        const s = self.table.getByChannel(channel) orelse return;
        s.streaming = false;
    }

    fn handleClose(self: *Server, channel: u128) void {
        // Terminate the child + free the session (§4.2). Idempotent on a stale
        // channel (closing a nonexistent target succeeds silently).
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        const s = self.table.getByChannel(channel) orelse return;
        self.table.remove(s.id);
    }

    fn handlePing(self: *Server, payload: []const u8) void {
        // Echo the PING payload back verbatim as PONG (carries the client's
        // timestamp for RTT, §6.4). Payload is opaque to the agent.
        self.enqueue(.control, .pong, protocol.control_channel, payload) catch {};
    }

    fn handleFlow(self: *Server, payload: []const u8) void {
        const flow = protocol.Flow.decode(payload) catch return;
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        const s = self.table.getByChannel(flow.channel) orelse return;
        switch (flow.op) {
            .pause => s.streaming = false,
            .@"resume" => s.streaming = true,
            .credit => {}, // v2; ignored in v1
        }
    }

    // --- Inbound DATA (client keystrokes) ------------------------------------

    fn handleInboundData(self: *Server, frame: protocol.Frame) void {
        const dp = protocol.DataPayload.decode(frame.payload) catch return;
        self.sess_mutex.lock();
        defer self.sess_mutex.unlock();
        // Ownership check (§15 M3): the channel must belong to a session we own.
        const s = self.table.getByChannel(frame.channel) orelse return;
        if (!s.alive) return;
        // Write keystrokes to the child. A short/failed write is non-fatal here.
        s.child.writeAll(dp.bytes) catch {};
    }
};

// =============================================================================
// Tests — deterministic, over an in-memory loopback with a mock client
// =============================================================================

const testing = std.testing;
const all_encodings = [_]protocol.TransferEncoding{ .raw, .cobs, .base64 };

// --- ByteFifo: thread-safe blocking byte pipe (mirrors connection.zig) --------

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
        if (avail.len == 0) return 0;
        const n = @min(avail.len, dst.len);
        @memcpy(dst[0..n], avail[0..n]);
        self.head += n;
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

// --- Loopback: client Stream + agent Stream over two ByteFifos ----------------

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
    /// The agent's view: writes → agent_to_client, reads ← client_to_agent.
    fn agentStream(self: *Loopback) Stream {
        return .{ .ctx = self, .vtable = &agent_vtable };
    }
    /// The client's view: writes → client_to_agent, reads ← agent_to_client.
    fn clientStream(self: *Loopback) Stream {
        return .{ .ctx = self, .vtable = &client_vtable };
    }
    const agent_vtable: Stream.VTable = .{ .read = agentRead, .write = agentWrite, .close = closeBoth };
    const client_vtable: Stream.VTable = .{ .read = clientRead, .write = clientWrite, .close = closeBoth };
    fn agentRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.client_to_agent.read(buf);
    }
    fn agentWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.agent_to_client.write(bytes);
    }
    fn clientRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.agent_to_client.read(buf);
    }
    fn clientWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.client_to_agent.write(bytes);
    }
    fn closeBoth(ctx: *anyopaque) void {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        self.client_to_agent.close();
        self.agent_to_client.close();
    }
};

// --- A fixed test clock -------------------------------------------------------

const TestClock = struct {
    ms: i64 = 0,
    fn clock(self: *TestClock) Clock {
        return .{ .ctx = self, .nowFn = now };
    }
    fn now(ctx: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ctx));
        return self.ms;
    }
};

// --- Fake child + spawner -----------------------------------------------------

/// A buffer-backed fake child. Keystrokes land in `input`. Output is delivered to
/// the server out-of-band by the test (calling `server.onChildOutput`), so the
/// child itself only sinks input and records control ops. `exit_code` is set by
/// the test to simulate the process exiting; `tryWait` then returns it.
const FakeChild = struct {
    input: std.ArrayList(u8) = .empty,
    last_resize: ?[4]u16 = null,
    last_signal: ?[]const u8 = null,
    exit_code: ?i64 = null,
    terminated: bool = false,
    mutex: std.Thread.Mutex = .{},
    alloc: Allocator,

    fn child(self: *FakeChild) session.Child {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: session.Child.VTable = .{
        .write = wr,
        .resize = rz,
        .signal = sg,
        .tryWait = tw,
        .terminate = tm,
    };
    fn wr(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.input.appendSlice(self.alloc, bytes);
        return bytes.len;
    }
    fn rz(ctx: *anyopaque, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.last_resize = .{ rows, cols, px_w, px_h };
    }
    fn sg(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.last_signal = name;
    }
    fn tw(ctx: *anyopaque) ?i64 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exit_code;
    }
    fn tm(ctx: *anyopaque) void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.terminated = true;
    }
    fn inputCopy(self: *FakeChild, alloc: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return alloc.dupe(u8, self.input.items);
    }
    fn setExit(self: *FakeChild, code: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.exit_code = code;
    }
    fn deinit(self: *FakeChild) void {
        self.input.deinit(self.alloc);
    }
};

/// A spawner that hands out pre-created FakeChildren in order. Lets the test keep
/// direct handles to each child for assertions/output feeding.
const FakeSpawner = struct {
    children: []*FakeChild,
    next: usize = 0,
    pid_base: i64 = 1000,

    fn spawner(self: *FakeSpawner) Spawner {
        return .{ .ctx = self, .spawnFn = spawn };
    }
    fn spawn(ctx: *anyopaque, _: protocol.Open) anyerror!Spawner.Result {
        const self: *FakeSpawner = @ptrCast(@alignCast(ctx));
        if (self.next >= self.children.len) return error.NoMoreChildren;
        const fc = self.children[self.next];
        self.next += 1;
        return .{ .child = fc.child(), .pid = self.pid_base + @as(i64, @intCast(self.next)) };
    }
};

// --- MockClient: drives the agent over the loopback ---------------------------

/// A minimal client: handshakes, sends control/data frames, and reads/decodes the
/// agent's frames. Single-threaded with blocking reads — the test sequences it.
const MockClient = struct {
    control: Stream,
    data: Stream,
    encoding: protocol.TransferEncoding,
    ctrl_reader: protocol.Reader,
    data_reader: protocol.Reader,
    scratch: [read_buf_size]u8 = undefined,
    alloc: Allocator,

    fn init(alloc: Allocator, control: Stream, data: Stream, enc: protocol.TransferEncoding) MockClient {
        return .{
            .control = control,
            .data = data,
            .encoding = enc,
            .ctrl_reader = protocol.Reader.init(alloc, enc),
            .data_reader = protocol.Reader.init(alloc, enc),
            .alloc = alloc,
        };
    }
    fn deinit(self: *MockClient) void {
        self.ctrl_reader.deinit();
        self.data_reader.deinit();
    }

    fn sendFrameOn(self: *MockClient, stream: Stream, frame: protocol.Frame) !void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);
        try protocol.writeFrame(self.alloc, self.encoding, frame, &wire);
        try stream.writeAll(wire.items);
    }
    fn sendControlJson(self: *MockClient, ftype: protocol.FrameType, channel: u128, value: anytype) !void {
        const json = try protocol.encodeJson(self.alloc, value);
        defer self.alloc.free(json);
        try self.sendFrameOn(self.control, .{ .type = ftype, .channel = channel, .seq = 0, .payload = json });
    }
    fn sendControlRaw(self: *MockClient, ftype: protocol.FrameType, channel: u128, payload: []const u8) !void {
        try self.sendFrameOn(self.control, .{ .type = ftype, .channel = channel, .seq = 0, .payload = payload });
    }
    fn sendDataInput(self: *MockClient, channel: u128, byte_offset: u64, bytes: []const u8) !void {
        const payload = try self.alloc.alloc(u8, protocol.DataPayload.encodedLen(bytes.len));
        defer self.alloc.free(payload);
        const dp: protocol.DataPayload = .{ .byte_offset = byte_offset, .bytes = bytes };
        _ = dp.encodeInto(payload);
        try self.sendFrameOn(self.data, .{ .type = .data, .channel = channel, .seq = 0, .payload = payload });
    }

    /// Read one control frame (blocking). null on EOF. Payload borrows the reader.
    fn nextControl(self: *MockClient) !?protocol.Frame {
        return self.nextOn(self.control, &self.ctrl_reader);
    }
    fn nextData(self: *MockClient) !?protocol.Frame {
        return self.nextOn(self.data, &self.data_reader);
    }
    fn nextOn(self: *MockClient, stream: Stream, reader: *protocol.Reader) !?protocol.Frame {
        while (true) {
            if (try reader.next()) |f| return f;
            const n = try stream.read(&self.scratch);
            if (n == 0) return null;
            try reader.push(self.scratch[0..n]);
        }
    }

    /// Send the client HELLO and consume the agent's HELLO reply.
    fn handshake(self: *MockClient) !void {
        const hello: protocol.Hello = .{ .transfer_encoding = self.encoding };
        const json = try hello.encode(self.alloc);
        defer self.alloc.free(json);
        try self.sendFrameOn(self.control, .{
            .type = .hello,
            .channel = protocol.control_channel,
            .seq = 0,
            .payload = json,
        });
        const reply = (try self.nextControl()) orelse return error.NoAgentHello;
        try testing.expectEqual(protocol.FrameType.hello, reply.type);
    }

    /// Skip control frames until one of `want` type; returns it.
    fn waitControl(self: *MockClient, want: protocol.FrameType) !protocol.Frame {
        while (true) {
            const f = (try self.nextControl()) orelse return error.Eof;
            if (f.type == want) return f;
        }
    }
};

/// Build a server + a mock client wired over two loopbacks, all on `enc`.
const Harness = struct {
    alloc: Allocator,
    ctrl_lb: *Loopback,
    data_lb: *Loopback,
    server: *Server,
    client: MockClient,
    clock: *TestClock,
    spawner: *FakeSpawner,

    fn init(
        alloc: Allocator,
        enc: protocol.TransferEncoding,
        clock: *TestClock,
        spawner: *FakeSpawner,
        ring_bytes: usize,
        rng: std.Random,
    ) !Harness {
        const ctrl_lb = try alloc.create(Loopback);
        ctrl_lb.* = Loopback.init(alloc);
        const data_lb = try alloc.create(Loopback);
        data_lb.* = Loopback.init(alloc);

        const server = try Server.create(
            alloc,
            ctrl_lb.agentStream(),
            data_lb.agentStream(),
            spawner.spawner(),
            .{
                .encoding = enc,
                .ring_bytes = ring_bytes,
                .clock = clock.clock(),
                .rng = rng,
            },
        );
        const client = MockClient.init(alloc, ctrl_lb.clientStream(), data_lb.clientStream(), enc);
        return .{
            .alloc = alloc,
            .ctrl_lb = ctrl_lb,
            .data_lb = data_lb,
            .server = server,
            .client = client,
            .clock = clock,
            .spawner = spawner,
        };
    }

    fn deinit(self: *Harness) void {
        self.server.shutdown();
        self.client.deinit();
        self.server.destroy(self.alloc);
        self.ctrl_lb.deinit();
        self.data_lb.deinit();
        self.alloc.destroy(self.ctrl_lb);
        self.alloc.destroy(self.data_lb);
    }
};

/// Read `OPENED` and return (session_id_copy, channel). The OPENED frame's channel
/// IS the session's data channel (the agent sends OPENED on it).
fn doOpen(h: *Harness, open: protocol.Open) !struct { id: [32]u8, channel: u128 } {
    try h.client.sendControlJson(.open, protocol.control_channel, open);
    const f = try h.client.waitControl(.opened);
    var parsed = try protocol.parseJson(protocol.Opened, h.alloc, f.payload);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 32), parsed.value.session_id.len);
    var id: [32]u8 = undefined;
    @memcpy(&id, parsed.value.session_id[0..32]);
    return .{ .id = id, .channel = f.channel };
}

test "handshake: agent echoes pinned encoding, negotiates" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var clock: TestClock = .{};
        var fc: FakeChild = .{ .alloc = alloc };
        defer fc.deinit();
        var kids = [_]*FakeChild{&fc};
        var sp: FakeSpawner = .{ .children = &kids };
        var prng = std.Random.DefaultPrng.init(1);

        var h = try Harness.init(alloc, enc, &clock, &sp, 4096, prng.random());
        defer h.deinit();
        try h.server.start();
        try h.client.handshake();
        const neg = try h.server.waitHandshake();
        try testing.expectEqual(enc, neg.transfer_encoding);
        try testing.expectEqual(protocol.proto_version, neg.proto_version);
    }
}

test "OPEN→OPENED then child output streams as DATA with advancing byte_offsets" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var clock: TestClock = .{};
        var fc: FakeChild = .{ .alloc = alloc };
        defer fc.deinit();
        var kids = [_]*FakeChild{&fc};
        var sp: FakeSpawner = .{ .children = &kids };
        var prng = std.Random.DefaultPrng.init(2);

        var h = try Harness.init(alloc, enc, &clock, &sp, 4096, prng.random());
        defer h.deinit();
        try h.server.start();
        try h.client.handshake();
        _ = try h.server.waitHandshake();

        const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

        // Feed two output chunks; they must arrive as DATA at offsets 0 then 5.
        h.server.onChildOutput(o.channel, "hello");
        h.server.onChildOutput(o.channel, " world");

        const d1 = try h.client.nextData();
        const dp1 = try protocol.DataPayload.decode(d1.?.payload);
        try testing.expectEqual(o.channel, d1.?.channel);
        try testing.expectEqual(@as(u64, 0), dp1.byte_offset);
        try testing.expectEqualSlices(u8, "hello", dp1.bytes);

        const d2 = try h.client.nextData();
        const dp2 = try protocol.DataPayload.decode(d2.?.payload);
        try testing.expectEqual(@as(u64, 5), dp2.byte_offset);
        try testing.expectEqualSlices(u8, " world", dp2.bytes);
    }
}

test "client DATA reaches the child (input round-trip)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(3);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendDataInput(o.channel, 0, "ls -la\n");

    // Spin until the child observes the input (the data reader thread is async).
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        const got = try fc.inputCopy(alloc);
        defer alloc.free(got);
        if (std.mem.eql(u8, got, "ls -la\n")) break;
        std.Thread.yield() catch {};
    }
    const got = try fc.inputCopy(alloc);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, "ls -la\n", got);
}

test "ATTACH alive returns snapshot anchor and streams forward from > S" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(4);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    // Produce some output so the snapshot offset S advances to 11.
    h.server.onChildOutput(o.channel, "hello world");
    _ = try h.client.nextData(); // drain the live DATA

    // Attach with last_byte_offset = 11 (already current) → no gap-fill, S = 11.
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 30,
        .cols = 100,
        .last_byte_offset = 11,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(u64, 11), ap.value.snapshot_at_offset);
    try testing.expectEqual(@as(u16, 30), ap.value.rows);

    // New live output streams forward from offset 11 (> S not double-applied).
    h.server.onChildOutput(o.channel, "!");
    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 11), dp.byte_offset);
    try testing.expectEqualSlices(u8, "!", dp.bytes);
}

test "ATTACH gap-fills retained ring bytes in (L, S]" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(5);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    h.server.onChildOutput(o.channel, "ABCDEFGHIJ"); // offsets 0..10, S = 10
    _ = try h.client.nextData(); // drain live

    // Client only saw up to offset 4; expects gap-fill of (4,10] = "EFGHIJ".
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 4,
    });
    _ = try h.client.waitControl(.attached);
    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 4), dp.byte_offset);
    try testing.expectEqualSlices(u8, "EFGHIJ", dp.bytes);
}

test "ATTACH to unknown session → not_found" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(6);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const bogus = "ffffffffffffffffffffffffffffffff";
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = bogus,
        .rows = 24,
        .cols = 80,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.not_found, ap.value.status);
}

test "child exit emits EXIT after final DATA; reattach → dead+exit_code; CLOSE frees" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 500 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(7);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Final output, THEN the child exits. onChildOutput emits DATA then (reaping)
    // EXIT — so the client must see DATA before EXIT (§4.2 ordering).
    fc.setExit(3);
    clock.ms = 1500; // 1000ms runtime
    h.server.onChildOutput(o.channel, "bye");

    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqualSlices(u8, "bye", dp.bytes);

    const ef = try h.client.waitControl(.exit);
    var ep = try protocol.parseJson(protocol.Exit, alloc, ef.payload);
    defer ep.deinit();
    try testing.expectEqual(@as(i64, 3), ep.value.code);
    try testing.expectEqual(@as(u64, 1000), ep.value.runtime_ms);

    // Reattach → tombstone: dead + exit_code.
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.dead, ap.value.status);
    try testing.expectEqual(@as(i64, 3), ap.value.exit_code.?);

    // CLOSE frees the tombstone + terminates the child handle.
    try h.client.sendControlRaw(.close, o.channel, "");
    // Spin until the session is gone.
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        h.server.sess_mutex.lock();
        const gone = h.server.table.getByChannel(o.channel) == null;
        h.server.sess_mutex.unlock();
        if (gone) break;
        std.Thread.yield() catch {};
    }
    h.server.sess_mutex.lock();
    try testing.expect(h.server.table.getByChannel(o.channel) == null);
    h.server.sess_mutex.unlock();
    try testing.expect(fc.terminated);
}

test "RESIZE and SIGNAL are recorded on the child" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(8);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlJson(.resize, o.channel, protocol.Resize{ .rows = 50, .cols = 120, .px_w = 1, .px_h = 2 });
    try h.client.sendControlJson(.signal, o.channel, protocol.Signal{ .name = "INT" });

    // Spin until both are observed (control reader is async).
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        if (fc.last_resize != null and fc.last_signal != null) break;
        std.Thread.yield() catch {};
    }
    try testing.expectEqual([4]u16{ 50, 120, 1, 2 }, fc.last_resize.?);
    try testing.expectEqualSlices(u8, "INT", fc.last_signal.?);
    // Session dims updated.
    h.server.sess_mutex.lock();
    const s = h.server.table.getByChannel(o.channel).?;
    try testing.expectEqual(@as(u16, 50), s.rows);
    h.server.sess_mutex.unlock();
}

test "FLOW pause halts streaming; resume continues from buffered offset" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(9);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Pause the channel, then feed output — it must NOT be framed (only ringed).
    try h.client.sendControlRaw(.flow, protocol.control_channel, blk: {
        const fl: protocol.Flow = .{ .channel = o.channel, .op = .pause };
        var buf: [protocol.Flow.encoded_len]u8 = undefined;
        _ = fl.encodeInto(&buf);
        break :blk &buf;
    });
    // Spin until the pause is applied.
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        h.server.sess_mutex.lock();
        const paused = !h.server.table.getByChannel(o.channel).?.streaming;
        h.server.sess_mutex.unlock();
        if (paused) break;
        std.Thread.yield() catch {};
    }
    h.server.onChildOutput(o.channel, "PAUSED"); // ringed at offset 0, not sent

    // Resume → subsequent output streams live (the buffered bytes recover via
    // attach gap-fill in production; here we assert the gate releases).
    try h.client.sendControlRaw(.flow, protocol.control_channel, blk: {
        const fl: protocol.Flow = .{ .channel = o.channel, .op = .@"resume" };
        var buf: [protocol.Flow.encoded_len]u8 = undefined;
        _ = fl.encodeInto(&buf);
        break :blk &buf;
    });
    spins = 0;
    while (spins < 10_000) : (spins += 1) {
        h.server.sess_mutex.lock();
        const live = h.server.table.getByChannel(o.channel).?.streaming;
        h.server.sess_mutex.unlock();
        if (live) break;
        std.Thread.yield() catch {};
    }
    h.server.onChildOutput(o.channel, "LIVE"); // streams at offset 6

    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 6), dp.byte_offset); // offset advanced past PAUSED
    try testing.expectEqualSlices(u8, "LIVE", dp.bytes);
}

test "PING is answered with PONG echoing the payload" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(10);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const stamp = "\x00\x00\x00\x00\x00\x00\x00\x2a"; // arbitrary 8-byte payload
    try h.client.sendControlRaw(.ping, protocol.control_channel, stamp);
    const pong = try h.client.waitControl(.pong);
    try testing.expectEqualSlices(u8, stamp, pong.payload);
}

test "DETACH stops streaming but keeps the session alive" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(11);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlRaw(.detach, o.channel, "");
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        h.server.sess_mutex.lock();
        const s = h.server.table.getByChannel(o.channel).?;
        const detached = !s.streaming and s.alive;
        h.server.sess_mutex.unlock();
        if (detached) break;
        std.Thread.yield() catch {};
    }
    h.server.sess_mutex.lock();
    const s = h.server.table.getByChannel(o.channel).?;
    try testing.expect(!s.streaming);
    try testing.expect(s.alive);
    h.server.sess_mutex.unlock();
}

test "unknown channel DATA is ignored (no crash, no child write)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(12);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    // Send DATA to a channel that doesn't exist; then a valid one. Only the valid
    // one should reach the child.
    try h.client.sendDataInput(0xDEAD_BEEF, 0, "ghost");
    try h.client.sendDataInput(o.channel, 0, "real");
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        const got = try fc.inputCopy(alloc);
        defer alloc.free(got);
        if (std.mem.eql(u8, got, "real")) break;
        std.Thread.yield() catch {};
    }
    const got = try fc.inputCopy(alloc);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, "real", got); // "ghost" never landed
}

test "clean shutdown joins all threads without hanging or leaking" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(13);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    // Open a session, leave it alive, then tear down via deinit (shutdown+destroy).
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    h.server.onChildOutput(o.channel, "some output"); // exercise the streaming path
    _ = try h.client.nextData();
    h.deinit(); // must not hang; testing.allocator catches leaks
}
