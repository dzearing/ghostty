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
//!   - **Child**: abstract (`session.Child`); the real pty/ConPTY impl is
//!     `pty_child.zig` (wired in `main.zig`), while tests inject a fake,
//!     pipe/buffer-backed child.
//!   - **Snapshot**: `ATTACHED.snapshot_at_offset` is the session's current
//!     outbound offset `S`; reconnect replays the ring forward from there. A true
//!     grid-model snapshot at `S` (§7.3), so ring eviction is invisible, is
//!     future work.
//!   - RPC, tunnels: out of scope.
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
//! These modules import `../protocol.zig` relatively (the same path the real
//! `zig build agent` graph uses). A `zig test` rooted at this file's directory
//! can't reach `../protocol.zig` ("import outside module path"), so root the test
//! one level up via the aggregator `src/remote/agent_test.zig`:
//!
//!   zig test -Mroot=src/remote/agent_test.zig
//!
//! The real build wires the agent exe via `build.zig` (`zig build agent`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const protocol = @import("../protocol.zig");
const session = @import("session.zig");
const metrics = @import("metrics.zig");
const proc = @import("proc.zig");
const proc_control = @import("proc_control.zig");

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

/// Spawns a child for an `OPEN` request. The real spawner (`pty_child.zig`) forks
/// a process on a pty/ConPTY and returns a pid + a `Child` whose output-reader
/// thread calls the session's sink; tests inject a fake spawner that hands back a
/// buffer-backed `FakeChild`.
///
/// The returned `Result.child` must remain valid until the session's child is
/// `terminate()`d. The spawner owns any backing storage and frees it on terminate.
pub const Spawner = struct {
    ctx: *anyopaque,
    spawnFn: *const fn (ctx: *anyopaque, open: protocol.Open) anyerror!Result,
    /// Launch a DETACHED process (no session/pty) for `PROC_SPAWN` (§9.3, inc 5).
    /// Injected (rather than imported by `server.zig`) so `server.zig`'s transport
    /// graph stays free of `CommandCore` — see `proc_spawn.zig`'s module doc. The
    /// real agent wires `pty_child.PtySpawner.spawnDetachedTrampoline`.
    spawnDetachedFn: *const fn (ctx: *anyopaque, cmd: []const u8, cwd: ?[]const u8) SpawnResult,

    pub const Result = struct {
        child: session.Child,
        pid: i64,
    };

    /// Result of a detached spawn (mirrors `proc_spawn.SpawnOutcome` but defined
    /// here so `server.zig` needn't import `proc_spawn.zig`). `@"error"` is usually a
    /// static string, but when `free_error` is true it was allocated from the
    /// agent's allocator (the Windows diagnostic note) and `handleProcSpawn` frees it
    /// after encoding the reply.
    pub const SpawnResult = struct {
        ok: bool = false,
        pid: ?i64 = null,
        @"error": ?[]const u8 = null,
        free_error: bool = false,
    };

    pub fn spawn(self: Spawner, open: protocol.Open) anyerror!Result {
        return self.spawnFn(self.ctx, open);
    }

    pub fn spawnDetached(self: Spawner, cmd: []const u8, cwd: ?[]const u8) SpawnResult {
        return self.spawnDetachedFn(self.ctx, cmd, cwd);
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

/// The agent's per-connection server: owns the two streams, the writer thread, and
/// the reader threads, and BRIDGES frames to/from a SHARED, daemon-scoped
/// `SessionStore` (the table + lock + children outlive this Server, so sessions
/// survive a client disconnect — §7.1 close-laptop). One `Server` per accepted
/// connection. Heap-allocated (`create`) so its address is stable for the threads.
pub const Server = struct {
    alloc: Allocator,
    control: Stream,
    data: Stream,
    encoding: protocol.TransferEncoding,
    local_hello: protocol.Hello,
    clock: Clock,
    spawner: Spawner,

    /// DAEMON-scoped session registry (§7.1 survival). SHARED across connections —
    /// owned by the daemon (`main.zig`), NOT by this per-connection Server, so
    /// sessions outlive a client disconnect (the close-laptop scenario). All table
    /// access goes through `store.mutex`. The previous design owned a per-connection
    /// `SessionTable`+mutex here; lifting it to the store is what makes reconnect
    /// catch-up possible.
    store: *session.SessionStore,
    /// Channels this connection currently has bound (so disconnect can DETACH just
    /// its own sessions, leaving others — future multi-client — untouched). Guarded
    /// by `store.mutex`.
    bound_channels: std.ArrayList(u128) = .empty,

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

    /// Host-metrics push pump (§9.3). A per-connection thread, lazily spawned on the
    /// first `metrics_sub` and torn down on `metrics_unsub` or shutdown. It samples
    /// the host every `metrics_interval_ms` and pushes a `metrics` frame on the
    /// control channel. Its own mutex/cond gate a timed wait so a stop request wakes
    /// it promptly (rather than sleeping out the full interval). MUST NOT outlive the
    /// Server — joined in `shutdown()`, asserted null in `destroy()` (UAF discipline).
    metrics_thread: ?std.Thread = null,
    metrics_mutex: std.Thread.Mutex = .{},
    metrics_cond: std.Thread.Condition = .{},
    metrics_interval_ms: u32 = 0, // 0 ⇒ unsubscribed
    metrics_stop: bool = false,

    /// Process-table sampler for `proc_list` (§9.3 process view). Unlike the metrics
    /// pump it needs no thread: `proc_list` is request/reply, sampled synchronously on
    /// the control reader. It holds per-pid CPU baselines across calls so a repeated
    /// `proc_list` yields real per-process CPU% (the first call on a pid reads 0).
    /// Owned by the Server; init in `create`, freed in `destroy`.
    proc_sampler: proc.ProcSampler = undefined,

    /// Per-session ring size (from Options), read by `create`'s table inserts.
    ring_bytes: usize = session.default_ring_bytes,

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
        /// This machine's hostname, advertised in the HELLO for client display
        /// (the window pill). Must outlive `start()` (encoded there). Optional.
        hostname: ?[]const u8 = null,
    };

    /// Stand up a per-connection Server over a SHARED daemon `store` (the registry
    /// that outlives connections, §7.1 survival). The store owns the session table,
    /// its lock, the id RNG, and the idle-TTL reaper; this Server only bridges
    /// frames to/from it for the life of one connection.
    pub fn create(
        alloc: Allocator,
        control: Stream,
        data: Stream,
        spawner: Spawner,
        store: *session.SessionStore,
        opts: Options,
    ) Allocator.Error!*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .control = control,
            .data = data,
            .encoding = opts.encoding,
            .local_hello = .{
                .transfer_encoding = opts.encoding,
                .capabilities = opts.capabilities,
                .hostname = opts.hostname,
            },
            .clock = opts.clock orelse Clock.real(),
            .spawner = spawner,
            .store = store,
            .ring_bytes = opts.ring_bytes,
        };
        self.proc_sampler = proc.ProcSampler.init(alloc);
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

    /// Stop everything for THIS connection: DETACH every session this connection
    /// bound (clear its bridge so the store stops framing to our dying writer, but
    /// KEEP the child running and ringing — the close-laptop survival path, §7.1),
    /// then close streams (unblocks reader threads at EOF), wake + drain the writer,
    /// and join all OUR threads. The sessions and their pty children are untouched;
    /// they live on in the store until reattached or idle-reaped. Safe to call once.
    ///
    /// CRITICAL (the wedge fix): we detach by clearing per-session bridge pointers
    /// under the store lock — we do NOT terminate any child here. Terminating a
    /// child joins its pty reader thread, whose output sink takes the store lock; if
    /// we did that while holding the lock (as the old `handleClose` did) the reader
    /// could never make progress and the join would hang, wedging the accept loop.
    pub fn shutdown(self: *Server) void {
        self.detachAll();
        // Stop + join the metrics pump BEFORE the streams close path completes: it
        // is a per-connection thread that frames onto our writer, so it must never
        // outlive the Server (the just-fixed UAF class). Signalling stop wakes its
        // timed cond wait immediately rather than waiting out the interval.
        self.stopMetricsPump();
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

    /// DETACH every session this connection bound: under the store lock, clear the
    /// session's bridge (point output nowhere) + `bound` flag and stop streaming, so
    /// the orphaned session keeps ringing output but frames nothing to our dead
    /// writer. Does NOT terminate children (survival, §7.1). Idempotent.
    fn detachAll(self: *Server) void {
        self.store.mutex.lock();
        defer self.store.mutex.unlock();
        for (self.bound_channels.items) |ch| {
            const s = self.store.table.getByChannel(ch) orelse continue;
            if (s.bridge_ctx == @as(?*anyopaque, self)) {
                s.bridge_ctx = null;
                s.bridge_data = null;
                s.bridge_exit = null;
                s.bound = false;
                s.streaming = false;
                s.last_activity_ms = self.clock.now();
            }
        }
        self.bound_channels.clearRetainingCapacity();
    }

    /// Free the server (must be shut down first). Frees per-connection state only;
    /// the SHARED session store (and its children) is owned by the daemon and
    /// outlives this Server — `destroy` never touches the table.
    pub fn destroy(self: *Server, alloc: Allocator) void {
        assert(self.control_thread == null and self.data_thread == null and self.writer_thread == null);
        assert(self.metrics_thread == null);
        self.proc_sampler.deinit();
        self.bound_channels.deinit(self.alloc);
        for (self.write_queue.items) |f| self.alloc.free(f.payload);
        self.write_queue.deinit(self.alloc);
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

    // --- Child output delivery ------------------------------------------------
    //
    // The pty reader thread's output sink points at the STORE (stable across
    // reconnects), not at this per-connection Server — see `store.onChildOutput`.
    // The store records into the ring + reaps, and (when a connection is bound)
    // calls back into the bound Server's bridge to actually frame DATA / EXIT onto
    // the wire. These two trampolines are that bridge.

    /// Bridge: frame a live child-output chunk as DATA on `channel`. Installed on a
    /// session (`bridge_data`) when this connection binds it; called by
    /// `store.onChildOutput` under the store lock.
    fn bridgeData(ctx: *anyopaque, channel: u128, byte_offset: u64, bytes: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendData(channel, byte_offset, bytes) catch {};
    }

    /// Bridge: frame EXIT on `channel` (ordered after the final DATA). Installed as
    /// `bridge_exit`; called by `store.onChildOutput` when the child reaps.
    fn bridgeExit(ctx: *anyopaque, channel: u128, code: i64, runtime_ms: u64) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendJson(.exit, channel, protocol.Exit{
            .code = code,
            .runtime_ms = runtime_ms,
        }) catch {};
    }

    /// Test/back-compat shim: deliver child output through the store (which bridges
    /// to this Server if bound). Real production output arrives via the store sink
    /// installed on the pty child; tests still call `server.onChildOutput(...)`.
    pub fn onChildOutput(self: *Server, channel: u128, bytes: []const u8) void {
        self.store.onChildOutput(channel, bytes);
    }

    /// Explicitly poll every live session for exit (tests call it after marking a
    /// fake child exited). Delegates a zero-length nudge per channel through the
    /// store so any exited child reaps + emits EXIT via the bridge.
    pub fn reapAll(self: *Server) void {
        self.store.mutex.lock();
        var channels: std.ArrayList(u128) = .empty;
        defer channels.deinit(self.alloc);
        var it = self.store.table.by_id.valueIterator();
        while (it.next()) |sp| channels.append(self.alloc, sp.*.channel) catch {};
        self.store.mutex.unlock();
        for (channels.items) |ch| self.store.onChildOutput(ch, &.{});
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
            .get_cwd => self.handleGetCwd(frame.channel, frame.payload),
            .ping => self.handlePing(frame.payload),
            .flow => self.handleFlow(frame.payload),
            .metrics_sub => self.handleMetricsSub(frame.payload),
            .metrics_unsub => self.handleMetricsUnsub(),
            .proc_list => self.handleProcList(frame.channel, frame.payload),
            .proc_kill => self.handleProcKill(frame.channel, frame.payload),
            .proc_spawn => self.handleProcSpawn(frame.channel, frame.payload),
            // The remaining types are agent→client replies (the agent produces
            // them) or out of scope: ignore.
            else => {},
        }
    }

    fn handleOpen(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Open, self.alloc, payload) catch return;
        defer parsed.deinit();
        const open = parsed.value;

        // Spawn the child (real pty). A spawn failure simply yields no OPENED; a real
        // agent would reply with an error META (out of scope).
        const spawned = self.spawner.spawn(open) catch return;

        self.store.mutex.lock();
        const s = self.store.table.create(
            spawned.child,
            spawned.pid,
            open.rows,
            open.cols,
            self.ring_bytes,
            self.clock.now(),
        ) catch {
            // Cap hit or OOM: terminate the orphaned child OUTSIDE the lock (the
            // terminate→reader-join deadlock rule), then drop.
            self.store.mutex.unlock();
            spawned.child.terminate();
            return;
        };
        // Bind the new session to THIS connection: install the outbound bridge so
        // live output frames to our writer, mark it bound (so the idle reaper leaves
        // it alone), and track its channel so disconnect detaches just our sessions.
        self.bindLocked(s);
        const channel = s.channel;
        const id_copy = s.id_str; // value copy; safe to use after unlock
        const pid = s.pid;
        const child = s.child; // value copy of the vtable handle
        self.store.mutex.unlock();

        // Hand the (real pty) child its channel + output sink so its reader thread
        // routes master-fd output to the STORE (stable across reconnects). Done
        // AFTER unlock because the sink itself takes the store lock. The fake child
        // ignores this (attach == null).
        child.attach(self.store, session.SessionStore.onChildOutputTrampoline, channel);

        self.sendJson(.opened, channel, protocol.Opened{
            .session_id = id_copy[0..],
            .pid = pid,
        }) catch {};
    }

    /// Bind session `s` to this connection: point its outbound bridge at us, mark it
    /// bound + streaming, and record its channel for detach-on-disconnect. Caller
    /// holds `store.mutex`. Idempotent-ish: re-binding repoints the bridge.
    fn bindLocked(self: *Server, s: *session.Session) void {
        s.bridge_ctx = self;
        s.bridge_data = bridgeData;
        s.bridge_exit = bridgeExit;
        s.bound = true;
        s.streaming = true;
        // Track the channel once (avoid dupes across re-attach within one conn).
        for (self.bound_channels.items) |c| if (c == s.channel) return;
        self.bound_channels.append(self.alloc, s.channel) catch {};
    }

    fn handleAttach(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Attach, self.alloc, payload) catch return;
        defer parsed.deinit();
        const att = parsed.value;

        self.store.mutex.lock();
        defer self.store.mutex.unlock();

        const s = self.store.table.getByIdStr(att.session_id) orelse {
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

        // Alive: (re)BIND the session to THIS connection — this is the close-laptop
        // reconnect path. The session may have been orphaned (its previous
        // connection dropped); binding repoints the bridge at our writer so live
        // output resumes flowing, and clears the orphan/idle-reap eligibility.
        self.bindLocked(s);

        // Capture the snapshot anchor S (= current outbound offset; a real grid
        // snapshot is `// TODO(snapshot)`). Resume the session's dims to the
        // attaching client's geometry.
        const now = self.clock.now();
        s.rows = att.rows;
        s.cols = att.cols;
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

        // Gap-fill / CATCH-UP (§7.3): replay everything the client missed while it
        // was gone. If the client's last_byte_offset < S and the ring still retains
        // `(last_byte_offset, S]`, replay it as DATA so reconnect has NO hole — this
        // is the bytes the remote produced during the disconnect. If the requested
        // start was evicted (deep scrollback overran the ring), replay what's
        // retained from the ring base and prepend a clear truncation marker (v1
        // honesty; the forthcoming grid snapshot makes the visible grid exact). Live
        // DATA then resumes from offset > S via the store sink.
        if (att.last_byte_offset < snapshot_at) {
            const base = s.ring.base_offset;
            var replay_from = att.last_byte_offset;
            if (replay_from < base) {
                // The exact resume point was evicted. Emit a marker, then replay from
                // the oldest byte we still have.
                const lost = base - att.last_byte_offset;
                var marker_buf: [96]u8 = undefined;
                const marker = std.fmt.bufPrint(
                    &marker_buf,
                    "\r\n[ghoztty: {d} bytes of scrollback lost during disconnect]\r\n",
                    .{lost},
                ) catch "";
                if (marker.len > 0) self.sendData(s.channel, att.last_byte_offset, marker) catch {};
                replay_from = base;
            }
            const want: usize = @intCast(snapshot_at - replay_from);
            if (want > 0) {
                const tmp = self.alloc.alloc(u8, want) catch return;
                defer self.alloc.free(tmp);
                if (s.ring.slice(replay_from, snapshot_at, tmp)) |n| {
                    self.sendData(s.channel, replay_from, tmp[0..n]) catch {};
                }
            }
        }
    }

    fn handleResize(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Resize, self.alloc, payload) catch return;
        defer parsed.deinit();
        const rz = parsed.value;
        // Update dims + snapshot the child under the lock; do the (potentially
        // blocking) ConPTY resize OUTSIDE it — never hold the global store lock
        // across child I/O (see handleInboundData).
        self.store.mutex.lock();
        const child: ?session.Child = blk: {
            const s = self.store.table.getByChannel(channel) orelse break :blk null;
            if (!s.alive) break :blk null;
            s.rows = rz.rows;
            s.cols = rz.cols;
            s.px_w = rz.px_w;
            s.px_h = rz.px_h;
            break :blk s.child;
        };
        self.store.mutex.unlock();
        if (child) |c| c.resize(rz.rows, rz.cols, rz.px_w, rz.px_h) catch {};
    }

    fn handleSignal(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Signal, self.alloc, payload) catch return;
        defer parsed.deinit();
        const sig = parsed.value;
        // Record the signal + snapshot the child under the lock; DELIVER it outside
        // the lock. signal() writes to the child's input pipe (Ctrl-C → 0x03), the
        // SAME blocking-WriteFile hazard as handleInboundData — never hold the global
        // store lock across it.
        self.store.mutex.lock();
        const child: ?session.Child = blk: {
            const s = self.store.table.getByChannel(channel) orelse break :blk null;
            if (!s.alive) break :blk null;
            s.setSignal(sig.name) catch {};
            break :blk s.child;
        };
        self.store.mutex.unlock();
        if (child) |c| c.signal(sig.name) catch {};
    }

    fn handleDetach(self: *Server, channel: u128) void {
        // Explicit DETACH: stop streaming + unbind from this connection, but KEEP
        // the session alive + ringing (§4.2/§7.1). After this the session is an
        // orphan (idle-TTL eligible) until a new ATTACH.
        //
        // OWNERSHIP GUARD (WP-D1 wedged-window fix): only the connection that
        // currently OWNS the bridge may detach the session. During a reconnect
        // swap the NEW connection ATTACHes (rebinding the bridge to itself)
        // and only then does the old surface's teardown DETACH arrive over the
        // still-open OLD connection. Unguarded, that stale DETACH stopped
        // `streaming` out from under the new owner and the freshly re-attached
        // window went permanently silent.
        self.store.mutex.lock();
        defer self.store.mutex.unlock();
        const s = self.store.table.getByChannel(channel) orelse return;
        if (s.bridge_ctx != @as(?*anyopaque, self)) return; // stale: not ours
        s.streaming = false;
        s.bridge_ctx = null;
        s.bridge_data = null;
        s.bridge_exit = null;
        s.bound = false;
        s.last_activity_ms = self.clock.now();
    }

    fn handleClose(self: *Server, channel: u128) void {
        // Terminate the child + free the session (§4.2). Idempotent on a stale
        // channel (closing a nonexistent target succeeds silently). Two-phase to
        // avoid the deadlock: UNLINK under the lock, then terminate+free OUTSIDE it
        // (terminate joins the pty reader, whose sink takes this very lock).
        self.store.mutex.lock();
        const s = self.store.table.getByChannel(channel);
        const unlinked = if (s) |sess| self.store.table.unlink(sess.id) else null;
        self.store.mutex.unlock();
        if (unlinked) |u| self.store.table.freeUnlinked(u);
    }

    /// `GET_CWD` (§WP4): on-demand "what is this session's child cwd?". Looks the
    /// session up by `session_id`, queries the OS for its child process's CURRENT
    /// working directory, and replies `CWD{session_id, path?, ok}` on the SAME
    /// request channel (the client correlates the reply by request channel).
    ///
    /// The OS query (`proc_pidinfo` / PEB read) runs OUTSIDE `store.mutex`: we
    /// snapshot the `session.Child` handle under the lock, drop the lock, then
    /// query. A `Child` handle stays valid until the child is `terminate`d, and a
    /// concurrent CLOSE only terminates after unlinking, so the worst case is the
    /// query failing gracefully (→ `ok = false`), never a use-after-free of the
    /// session table entry.
    fn handleGetCwd(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.GetCwd, self.alloc, payload) catch return;
        defer parsed.deinit();
        const req = parsed.value;

        // Snapshot the child handle (a value copy of the vtable handle) under the
        // lock; do the OS query unlocked.
        self.store.mutex.lock();
        const s = self.store.table.getByIdStr(req.session_id);
        const child: ?session.Child = if (s) |sess| (if (sess.alive) sess.child else null) else null;
        self.store.mutex.unlock();

        // Stable copy of the session_id for the reply (the parsed value is freed by
        // the trailing defer before sendJson runs through the writer queue).
        var id_buf: [64]u8 = undefined;
        const id_len = @min(req.session_id.len, id_buf.len);
        @memcpy(id_buf[0..id_len], req.session_id[0..id_len]);
        const id_copy = id_buf[0..id_len];

        const cwd: ?[]u8 = if (child) |c| c.queryCwd(self.alloc) else null;
        defer if (cwd) |p| self.alloc.free(p);

        self.sendJson(.cwd, channel, protocol.Cwd{
            .session_id = id_copy,
            .path = cwd,
            .ok = cwd != null,
        }) catch {};
    }

    fn handlePing(self: *Server, payload: []const u8) void {
        // Echo the PING payload back verbatim as PONG (carries the client's
        // timestamp for RTT, §6.4). Payload is opaque to the agent.
        self.enqueue(.control, .pong, protocol.control_channel, payload) catch {};
    }

    fn handleFlow(self: *Server, payload: []const u8) void {
        const flow = protocol.Flow.decode(payload) catch return;
        self.store.mutex.lock();
        defer self.store.mutex.unlock();
        const s = self.store.table.getByChannel(flow.channel) orelse return;
        // OWNERSHIP GUARD (same rule as handleDetach): only the bridge-owning
        // connection may pause/resume the session's streaming — a stale FLOW
        // from a superseded connection must not wedge (or spuriously resume)
        // the new owner's stream.
        if (s.bridge_ctx != @as(?*anyopaque, self)) return;
        switch (flow.op) {
            .pause => s.streaming = false,
            .@"resume" => s.streaming = true,
            .credit => {}, // v2; ignored in v1
        }
    }

    // --- Host metrics push (§9.3) --------------------------------------------

    /// `METRICS_SUB`: record the requested interval and lazily spawn the pump thread
    /// (one per connection). A re-subscription just updates the interval; the running
    /// pump picks it up on its next loop. A malformed payload is ignored (untrusted).
    fn handleMetricsSub(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.MetricsSub, self.alloc, payload) catch return;
        defer parsed.deinit();
        // Clamp to a sane floor so a hostile/zero interval can't busy-spin the pump.
        const interval = @max(parsed.value.interval_ms, 50);

        self.metrics_mutex.lock();
        self.metrics_interval_ms = interval;
        const need_spawn = self.metrics_thread == null;
        if (need_spawn) self.metrics_stop = false;
        self.metrics_cond.signal(); // wake an existing pump to pick up a new interval
        self.metrics_mutex.unlock();

        if (need_spawn) {
            self.metrics_thread = std.Thread.spawn(.{}, metricsPumpLoop, .{self}) catch null;
        }
    }

    /// `METRICS_UNSUB`: stop + join the pump (idempotent).
    fn handleMetricsUnsub(self: *Server) void {
        self.stopMetricsPump();
    }

    /// Signal the pump to stop, wake its timed wait, and join it. Idempotent and
    /// safe to call with no pump running. Called by `metrics_unsub` and `shutdown`.
    fn stopMetricsPump(self: *Server) void {
        self.metrics_mutex.lock();
        self.metrics_stop = true;
        self.metrics_interval_ms = 0;
        self.metrics_cond.signal();
        self.metrics_mutex.unlock();
        if (self.metrics_thread) |t| {
            t.join();
            self.metrics_thread = null;
        }
    }

    /// The metrics pump: own a `metrics.Sampler`, and until stopped, sample the host
    /// and push a `metrics` frame on the control channel, then wait `interval_ms`
    /// (a timed cond wait so stop wakes us immediately). Exits on stop or `closed`.
    fn metricsPumpLoop(self: *Server) void {
        var sampler = metrics.Sampler.init();
        while (true) {
            // Snapshot the interval + stop flag under the lock.
            self.metrics_mutex.lock();
            if (self.metrics_stop or self.closed) {
                self.metrics_mutex.unlock();
                return;
            }
            const interval_ms = self.metrics_interval_ms;
            self.metrics_mutex.unlock();

            const host = sampler.sample();
            self.sendJson(.metrics, protocol.control_channel, protocol.Metrics{
                .host = host,
            }) catch {};

            // Timed wait: wake early if stop is signalled mid-interval.
            self.metrics_mutex.lock();
            if (!self.metrics_stop and !self.closed) {
                self.metrics_cond.timedWait(
                    &self.metrics_mutex,
                    @as(u64, interval_ms) * std.time.ns_per_ms,
                ) catch {};
            }
            const stop = self.metrics_stop or self.closed;
            self.metrics_mutex.unlock();
            if (stop) return;
        }
    }

    // --- Process table (§9.3 process view) -----------------------------------

    /// `PROC_LIST` (§9.3): enumerate the host's processes and reply
    /// `PROC_SNAPSHOT{ok, host, procs, truncated}` on the SAME request channel (the
    /// client correlates the reply by request channel, like `GET_CWD`/`CWD`).
    ///
    /// Synchronous request/reply — no pump thread. The OS enumeration runs UNLOCKED
    /// (it touches no session-store state; it queries the whole machine), matching the
    /// `handleGetCwd` discipline. `host.cpu_pct` here may read 0: a fresh local host
    /// `Sampler` has no prior tick baseline for a one-shot read — the panel subscribes
    /// to the live `metrics` stream separately for an accurate host CPU%. The
    /// per-process `proc_sampler` DOES persist baselines across `proc_list` calls, so
    /// repeated polls yield real per-process CPU%.
    ///
    /// All proc strings are owned by `self.alloc`; we free them (and the list) after
    /// `sendJson` has encoded the snapshot to JSON. On any error we reply `ok=false`.
    fn handleProcList(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.ProcList, self.alloc, payload) catch {
            self.sendJson(.proc_snapshot, channel, protocol.ProcSnapshot{ .ok = false }) catch {};
            return;
        };
        defer parsed.deinit();
        const limit: u32 = parsed.value.limit orelse 0;

        // A one-shot host sample (no baseline ⇒ cpu_pct may be 0; that's fine).
        var host_sampler = metrics.Sampler.init();
        const host = host_sampler.sample();

        var procs: std.ArrayList(protocol.Proc) = .empty;
        defer {
            for (procs.items) |p| {
                self.alloc.free(@constCast(p.name));
                if (p.user) |u| self.alloc.free(@constCast(u));
                if (p.cmd) |c| self.alloc.free(@constCast(c));
            }
            procs.deinit(self.alloc);
        }

        const truncated = self.proc_sampler.sample(self.alloc, &procs, limit) catch {
            self.sendJson(.proc_snapshot, channel, protocol.ProcSnapshot{ .ok = false, .host = host }) catch {};
            return;
        };

        self.sendJson(.proc_snapshot, channel, protocol.ProcSnapshot{
            .ok = true,
            .host = host,
            .procs = procs.items,
            .truncated = truncated,
            .agent_pid = currentPid(),
        }) catch {};
    }

    /// This agent process's own pid, used by the client as the root of the
    /// "ghoztty-spawned" descendant tree. Cheap (one syscall); cross-OS.
    fn currentPid() i64 {
        if (builtin.os.tag == .windows) {
            const k32 = struct {
                extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
            };
            return @intCast(k32.GetCurrentProcessId());
        }
        return @intCast(std.c.getpid());
    }

    /// `PROC_KILL` (§9.3, inc 4): terminate the requested pid and reply
    /// `PROC_KILL_RESULT{pid, ok, error?}` on the SAME request channel (same-channel
    /// correlation, like `PROC_LIST`/`GET_CWD`). The OS kill runs UNLOCKED (it
    /// touches no session-store state). A malformed payload is ignored (untrusted).
    fn handleProcKill(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.ProcKill, self.alloc, payload) catch return;
        defer parsed.deinit();
        const pid = parsed.value.pid;

        const out = proc_control.killProc(pid, parsed.value.signal);
        self.sendJson(.proc_kill_result, channel, protocol.ProcKillResult{
            .pid = pid,
            .ok = out.ok,
            .@"error" = out.@"error",
        }) catch {};
    }

    /// `PROC_SPAWN` (§9.3, inc 5): launch a detached process via the platform shell
    /// and reply `PROC_SPAWN_RESULT{ok, pid?, error?}` on the request channel. The
    /// spawn runs UNLOCKED. A malformed payload is ignored (untrusted).
    fn handleProcSpawn(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.ProcSpawn, self.alloc, payload) catch return;
        defer parsed.deinit();

        // Spawn via the injected spawner (keeps `CommandCore` out of server.zig's
        // graph — see `proc_spawn.zig`). Runs UNLOCKED (no session-store state).
        const out = self.spawner.spawnDetached(parsed.value.cmd, parsed.value.cwd);
        // The Windows path may return an ALLOCATED diagnostic note in `@"error"`
        // (free_error). `sendJson` encodes synchronously, so free after it returns.
        defer if (out.free_error) {
            if (out.@"error") |m| self.alloc.free(@constCast(m));
        };
        self.sendJson(.proc_spawn_result, channel, protocol.ProcSpawnResult{
            .ok = out.ok,
            .pid = out.pid,
            .@"error" = out.@"error",
        }) catch {};
    }

    // --- Inbound DATA (client keystrokes) ------------------------------------

    fn handleInboundData(self: *Server, frame: protocol.Frame) void {
        const dp = protocol.DataPayload.decode(frame.payload) catch return;

        // Snapshot the owning session's child handle under the lock, then write
        // OUTSIDE it. `writeAll` is a blocking PTY/ConPTY input-pipe write that can
        // stall INDEFINITELY when the pipe is back-pressured or the peer conhost has
        // wedged. Holding the DAEMON-SCOPED `store.mutex` across it would wedge EVERY
        // session on this agent — both input (other `handleInboundData`s) AND output
        // (the child-output sink also takes `store.mutex`) — which is the remote-
        // window "sits there not responding" bug. A `session.Child` is a value-copy
        // vtable handle that stays valid until the child is `terminate`d, and CLOSE
        // only terminates AFTER unlinking under this lock, so the worst case is the
        // write failing gracefully, never a use-after-free of the table entry. (Same
        // lock→snapshot→unlock→IO discipline as `handleGetCwd`.)
        self.store.mutex.lock();
        const s = self.store.table.getByChannel(frame.channel);
        const child: ?session.Child = if (s) |sess| (if (sess.alive) sess.child else null) else null;
        self.store.mutex.unlock();

        // A short/failed write is non-fatal here.
        if (child) |c| c.writeAll(dp.bytes) catch {};
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
    /// When set, `queryCwd` returns a copy of this (models the OS cwd read). When
    /// null the vtable's `queryCwd` is still wired but returns null (query failed).
    fake_cwd: ?[]const u8 = null,
    /// Optional write gate (wedge test): when both are set, `write` signals
    /// `gate_entered` and then BLOCKS on `gate_release` before sinking the bytes —
    /// modeling a stalled ConPTY input pipe whose `WriteFile` never returns. Lets a
    /// test observe whether the agent holds the global store lock across a blocked
    /// child write. Null in every other test (no behavior change).
    gate_entered: ?*std.Thread.ResetEvent = null,
    gate_release: ?*std.Thread.ResetEvent = null,
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
        .queryCwd = qcwd,
    };
    fn qcwd(ctx: *anyopaque, alloc: Allocator) ?[]u8 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        const c = self.fake_cwd orelse return null;
        return alloc.dupe(u8, c) catch null;
    }
    fn wr(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        // Optional wedge gate: announce we're inside the write, then block until
        // the test releases us (models a stalled ConPTY input pipe).
        if (self.gate_entered) |e| e.set();
        if (self.gate_release) |r| r.wait();
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
        return .{ .ctx = self, .spawnFn = spawn, .spawnDetachedFn = spawnDetached };
    }
    fn spawn(ctx: *anyopaque, _: protocol.Open) anyerror!Spawner.Result {
        const self: *FakeSpawner = @ptrCast(@alignCast(ctx));
        if (self.next >= self.children.len) return error.NoMoreChildren;
        const fc = self.children[self.next];
        self.next += 1;
        return .{ .child = fc.child(), .pid = self.pid_base + @as(i64, @intCast(self.next)) };
    }
    /// REAL detached spawn so the `PROC_SPAWN`→`PROC_KILL` round-trip test
    /// exercises a genuine OS process. Uses `std.process.Child` directly (std-only,
    /// so this stays out of `CommandCore` and keeps `server.zig`'s graph importable
    /// by the client transport — the real agent injects `proc_spawn.spawnDetached`
    /// via `pty_child`). POSIX-only (the agent tests skip on Windows).
    fn spawnDetached(_: *anyopaque, cmd: []const u8, cwd: ?[]const u8) Spawner.SpawnResult {
        if (builtin.os.tag == .windows) return .{ .ok = false, .@"error" = "unsupported in test" };
        var child = std.process.Child.init(&.{ "/bin/sh", "-lc", cmd }, std.heap.page_allocator);
        child.cwd = cwd;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch |err| return .{ .ok = false, .@"error" = @errorName(err) };
        return .{ .ok = true, .pid = @intCast(child.id) };
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

/// Build a server + a mock client wired over two loopbacks, all on `enc`. Owns a
/// daemon-scoped `SessionStore` (shared registry), mirroring production: the store
/// outlives the Server, so tests reach the table via `h.server.store.{mutex,table}`.
const Harness = struct {
    alloc: Allocator,
    ctrl_lb: *Loopback,
    data_lb: *Loopback,
    store: *session.SessionStore,
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

        const store = try alloc.create(session.SessionStore);
        // No reaper thread in tests (deterministic): idle reaping is invoked
        // explicitly via `store.reapIdle()` where a test wants it. A huge TTL keeps
        // sessions from ever idling out under the fixed test clock.
        store.* = session.SessionStore.init(alloc, rng, clock, TestClock.now, std.math.maxInt(i64));

        const server = try Server.create(
            alloc,
            ctrl_lb.agentStream(),
            data_lb.agentStream(),
            spawner.spawner(),
            store,
            .{
                .encoding = enc,
                .ring_bytes = ring_bytes,
                .clock = clock.clock(),
            },
        );
        const client = MockClient.init(alloc, ctrl_lb.clientStream(), data_lb.clientStream(), enc);
        return .{
            .alloc = alloc,
            .ctrl_lb = ctrl_lb,
            .data_lb = data_lb,
            .store = store,
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
        self.store.deinit();
        self.alloc.destroy(self.store);
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

test "GET_CWD→CWD: agent replies with the child's queried cwd on the request channel" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc, .fake_cwd = "/private/tmp" };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(7);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const opened = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Issue GET_CWD on a fresh request channel; the agent must echo CWD on it.
    const req_ch: u128 = 0xC0FFEE;
    try h.client.sendControlJson(.get_cwd, req_ch, protocol.GetCwd{
        .session_id = opened.id[0..],
    });
    const reply = try h.client.waitControl(.cwd);
    try testing.expectEqual(req_ch, reply.channel);
    var parsed = try protocol.parseJson(protocol.Cwd, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(parsed.value.ok);
    try testing.expect(parsed.value.path != null);
    try testing.expectEqualStrings("/private/tmp", parsed.value.path.?);
    try testing.expectEqualStrings(opened.id[0..], parsed.value.session_id);
}

test "WEDGE: a session's blocking child write must NOT hold the global store lock" {
    // Reproduction + regression guard for the agent WEDGE. handleInboundData used
    // to call child.writeAll() WHILE HOLDING the daemon-scoped store.mutex. On
    // Windows a stalled ConPTY input pipe makes that WriteFile block indefinitely,
    // so the GLOBAL store lock is held indefinitely and EVERY other session wedges
    // — input (handleInboundData) AND output (the child-output sink also takes
    // store.mutex). Symptom: a remote window "sits there not responding", `exit`
    // never reaches the shell. The fix snapshots the child handle under the lock,
    // releases the lock, THEN writes (same pattern as handleGetCwd). This test
    // asserts the store lock is ACQUIRABLE while one session's child write blocks.
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var gate_entered: std.Thread.ResetEvent = .{};
    var gate_release: std.Thread.ResetEvent = .{};
    var fc: FakeChild = .{
        .alloc = alloc,
        .gate_entered = &gate_entered,
        .gate_release = &gate_release,
    };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(99);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit(); // runs LAST: joins the data thread (released below first)
    defer gate_release.set(); // runs BEFORE deinit so the blocked write can finish
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const opened = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Send keystrokes: the agent's data thread enters child.writeAll and BLOCKS
    // there (gate held), modeling a stalled input pipe.
    try h.client.sendDataInput(opened.channel, 0, "exit\r");
    gate_entered.wait(); // the data thread is now inside the blocking write

    // THE ASSERTION: with that write in flight, the global store lock must be FREE.
    // Pre-fix the data thread holds store.mutex for the whole blocked write, so a
    // concurrent session (or the output sink) can never make progress → tryLock
    // returns false → wedge. Post-fix the lock was released before the write.
    const acquired = h.store.mutex.tryLock();
    if (acquired) h.store.mutex.unlock();
    try testing.expect(acquired);
}

test "GET_CWD→CWD: unknown session replies ok=false (graceful, no crash)" {
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

    try h.client.sendControlJson(.get_cwd, 0xABCD, protocol.GetCwd{
        .session_id = "ffffffffffffffffffffffffffffffff",
    });
    const reply = try h.client.waitControl(.cwd);
    var parsed = try protocol.parseJson(protocol.Cwd, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(!parsed.value.ok);
    try testing.expect(parsed.value.path == null);
}

test "METRICS_SUB pushes metrics frames; METRICS_UNSUB stops the pump cleanly" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(30);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Subscribe with a small interval; at least one metrics frame must arrive with a
    // decodable HostMetrics (cpu_pct may be 0 on the first sample, no baseline yet).
    try h.client.sendControlJson(.metrics_sub, protocol.control_channel, protocol.MetricsSub{
        .interval_ms = 10,
    });
    const m1 = try h.client.waitControl(.metrics);
    var mp = try protocol.parseJson(protocol.Metrics, alloc, m1.payload);
    defer mp.deinit();
    // ncpu is read directly each sample (not delta-based) so it must be > 0 on a
    // real host; cpu_pct is allowed to be 0 on the first push.
    try testing.expect(mp.value.host.ncpu >= 1);
    try testing.expect(mp.value.host.cpu_pct >= 0);

    // A second push should follow (the pump loops on the interval).
    const m2 = try h.client.waitControl(.metrics);
    var mp2 = try protocol.parseJson(protocol.Metrics, alloc, m2.payload);
    defer mp2.deinit();

    // Unsubscribe: the pump stops + joins. The harness deinit (shutdown) must then
    // tear down with no hang/leak (testing.allocator catches leaks).
    try h.client.sendControlJson(.metrics_unsub, protocol.control_channel, protocol.MetricsUnsub{});
    // Give the unsub a moment to be processed (control reader is async); spin until
    // the pump thread is torn down.
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        if (h.server.metrics_thread == null) break;
        std.Thread.yield() catch {};
    }
    try testing.expect(h.server.metrics_thread == null);
}

test "PROC_LIST→PROC_SNAPSHOT: agent enumerates real processes on the request channel" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(40);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Request the process table on a fresh request channel; the agent must echo
    // PROC_SNAPSHOT on it (same-channel correlation, like GET_CWD).
    const req_ch: u128 = 0xC0FFEE_F00D;
    try h.client.sendControlJson(.proc_list, req_ch, protocol.ProcList{ .limit = 50 });
    const reply = try h.client.waitControl(.proc_snapshot);
    try testing.expectEqual(req_ch, reply.channel);

    var parsed = try protocol.parseJson(protocol.ProcSnapshot, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(parsed.value.ok);
    // A real host always has running processes; the agent's own process is one.
    try testing.expect(parsed.value.procs.len > 0);
    // Each row must decode with a non-empty name and a non-negative cpu_pct.
    var saw_named = false;
    for (parsed.value.procs) |p| {
        try testing.expect(p.cpu_pct >= 0);
        if (p.name.len > 0) saw_named = true;
    }
    try testing.expect(saw_named);
    // ncpu is read directly each host sample → > 0 on a real machine.
    try testing.expect(parsed.value.host.ncpu >= 1);
}

test "PROC_SPAWN→PROC_SPAWN_RESULT then PROC_KILL→PROC_KILL_RESULT round-trip" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(41);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Spawn a harmless short sleeper on the request channel; the agent must echo
    // PROC_SPAWN_RESULT{ok=true, pid>0} on it (same-channel correlation).
    const req_ch: u128 = 0x5A11AD;
    try h.client.sendControlJson(.proc_spawn, req_ch, protocol.ProcSpawn{
        .cmd = "sleep 0.2",
    });
    const sreply = try h.client.waitControl(.proc_spawn_result);
    try testing.expectEqual(req_ch, sreply.channel);
    var sparsed = try protocol.parseJson(protocol.ProcSpawnResult, alloc, sreply.payload);
    defer sparsed.deinit();
    try testing.expect(sparsed.value.ok);
    try testing.expect(sparsed.value.pid != null);
    const pid = sparsed.value.pid.?;
    try testing.expect(pid > 0);

    // Kill that pid (default TERM). The agent replies PROC_KILL_RESULT; ok should be
    // true (the sleeper is alive), but accept either since it may have already
    // exited and been reaped — the contract is "no crash, a structured result".
    const kill_ch: u128 = 0x11A11;
    try h.client.sendControlJson(.proc_kill, kill_ch, protocol.ProcKill{ .pid = pid });
    const kreply = try h.client.waitControl(.proc_kill_result);
    try testing.expectEqual(kill_ch, kreply.channel);
    var kparsed = try protocol.parseJson(protocol.ProcKillResult, alloc, kreply.payload);
    defer kparsed.deinit();
    try testing.expectEqual(pid, kparsed.value.pid);
    try testing.expect(kparsed.value.ok or kparsed.value.@"error" != null);
}

test "PROC_KILL a bogus pid → ok=false (graceful)" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(42);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const req_ch: u128 = 0xB0_6051;
    try h.client.sendControlJson(.proc_kill, req_ch, protocol.ProcKill{ .pid = 2147483600 });
    const reply = try h.client.waitControl(.proc_kill_result);
    try testing.expectEqual(req_ch, reply.channel);
    var parsed = try protocol.parseJson(protocol.ProcKillResult, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(!parsed.value.ok);
    try testing.expect(parsed.value.@"error" != null);
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
        h.server.store.mutex.lock();
        const gone = h.server.store.table.getByChannel(o.channel) == null;
        h.server.store.mutex.unlock();
        if (gone) break;
        std.Thread.yield() catch {};
    }
    h.server.store.mutex.lock();
    try testing.expect(h.server.store.table.getByChannel(o.channel) == null);
    h.server.store.mutex.unlock();
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
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByChannel(o.channel).?;
    try testing.expectEqual(@as(u16, 50), s.rows);
    h.server.store.mutex.unlock();
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
        h.server.store.mutex.lock();
        const paused = !h.server.store.table.getByChannel(o.channel).?.streaming;
        h.server.store.mutex.unlock();
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
        h.server.store.mutex.lock();
        const live = h.server.store.table.getByChannel(o.channel).?.streaming;
        h.server.store.mutex.unlock();
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
        h.server.store.mutex.lock();
        const s = h.server.store.table.getByChannel(o.channel).?;
        const detached = !s.streaming and s.alive;
        h.server.store.mutex.unlock();
        if (detached) break;
        std.Thread.yield() catch {};
    }
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByChannel(o.channel).?;
    try testing.expect(!s.streaming);
    try testing.expect(s.alive);
    h.server.store.mutex.unlock();
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

// --- P1: session survival across disconnect + reconnect catch-up --------------

/// A second connection (Server + client + loopbacks) over an EXISTING shared store,
/// modeling a reconnect. The store/spawner/clock are owned by the first Harness.
const ReConn = struct {
    alloc: Allocator,
    ctrl_lb: *Loopback,
    data_lb: *Loopback,
    server: *Server,
    client: MockClient,

    fn init(h: *Harness, enc: protocol.TransferEncoding) !ReConn {
        const alloc = h.alloc;
        const ctrl_lb = try alloc.create(Loopback);
        ctrl_lb.* = Loopback.init(alloc);
        const data_lb = try alloc.create(Loopback);
        data_lb.* = Loopback.init(alloc);
        const server = try Server.create(
            alloc,
            ctrl_lb.agentStream(),
            data_lb.agentStream(),
            h.spawner.spawner(),
            h.store,
            .{ .encoding = enc, .ring_bytes = 4096, .clock = h.clock.clock() },
        );
        const client = MockClient.init(alloc, ctrl_lb.clientStream(), data_lb.clientStream(), enc);
        return .{ .alloc = alloc, .ctrl_lb = ctrl_lb, .data_lb = data_lb, .server = server, .client = client };
    }
    fn deinit(self: *ReConn) void {
        self.server.shutdown();
        self.client.deinit();
        self.server.destroy(self.alloc);
        self.ctrl_lb.deinit();
        self.data_lb.deinit();
        self.alloc.destroy(self.ctrl_lb);
        self.alloc.destroy(self.data_lb);
    }
};

test "P1: session survives connection drop; reattach replays the ring gap (catch-up)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 1000 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(20);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Conn 1: open, see some live output (offsets 0..5), then DROP the connection
    // WITHOUT closing the session (shutdown DETACHes, never terminates).
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    var id_buf: [32]u8 = o.id;
    h.server.onChildOutput(o.channel, "hello"); // offset 0, S=5
    _ = try h.client.nextData();
    h.server.shutdown(); // laptop close: detach, keep session + ring alive

    // The session must STILL be in the shared store, alive, ringing.
    h.store.mutex.lock();
    const survived = h.store.table.getByChannel(o.channel);
    try testing.expect(survived != null);
    try testing.expect(survived.?.alive);
    try testing.expect(!survived.?.bound); // orphaned now
    h.store.mutex.unlock();

    // While disconnected, the child keeps producing — recorded into the ring even
    // though no connection is bound (offsets 5..16).
    h.server.onChildOutput(o.channel, "WORLD-GAP!!"); // offset 5, S=16

    // Conn 2: reconnect over the SAME store and ATTACH with last_byte_offset=5
    // (everything we'd seen). The agent must replay (5,16] = "WORLD-GAP!!".
    var rc = try ReConn.init(&h, .raw);
    defer rc.deinit();
    try rc.server.start();
    try rc.client.handshake();
    _ = try rc.server.waitHandshake();

    try rc.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 5,
    });
    const af = try rc.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(u64, 16), ap.value.snapshot_at_offset);

    // The replayed gap arrives as DATA at offset 5 — the bytes produced WHILE GONE.
    const d = try rc.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 5), dp.byte_offset);
    try testing.expectEqualSlices(u8, "WORLD-GAP!!", dp.bytes);

    // And live streaming resumes on the NEW connection (offset 16 forward).
    h.server.onChildOutput(o.channel, "+live");
    const d2 = try rc.client.nextData();
    const dp2 = try protocol.DataPayload.decode(d2.?.payload);
    try testing.expectEqual(@as(u64, 16), dp2.byte_offset);
    try testing.expectEqualSlices(u8, "+live", dp2.bytes);
}

test "P1: explicit DETACH orphans the session (kept alive, unbound, not streaming)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(21);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlRaw(.detach, o.channel, "");
    var spins: usize = 0;
    while (spins < 10_000) : (spins += 1) {
        h.store.mutex.lock();
        const s = h.store.table.getByChannel(o.channel).?;
        const orphaned = !s.streaming and !s.bound and s.alive;
        h.store.mutex.unlock();
        if (orphaned) break;
        std.Thread.yield() catch {};
    }
    h.store.mutex.lock();
    const s = h.store.table.getByChannel(o.channel).?;
    try testing.expect(s.alive and !s.streaming and !s.bound);
    h.store.mutex.unlock();
}

test "WP-D1: stale DETACH from a superseded connection must not silence the new owner" {
    // The reconnect-swap wedge: conn 1 owns a session; conn 2 ATTACHes (the
    // agent rebinds the bridge — implicit steal); THEN conn 1's old surface
    // teardown sends DETACH for the same channel. That stale DETACH must be a
    // no-op: the session keeps streaming to conn 2. Pre-fix it stopped
    // `streaming` unconditionally and the freshly swapped window went silent.
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 1000 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(23);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Conn 1: open; some output so the attach below can anchor past it.
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    var id_buf: [32]u8 = o.id;
    h.server.onChildOutput(o.channel, "hello"); // offsets [0,5)
    _ = try h.client.nextData();

    // Conn 2 over the SAME store: ATTACH rebinds the bridge (conn 1 still open).
    var rc = try ReConn.init(&h, .raw);
    defer rc.deinit();
    try rc.server.start();
    try rc.client.handshake();
    _ = try rc.server.waitHandshake();
    try rc.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 5,
    });
    const af = try rc.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);

    // Conn 1: the STALE DETACH (the swapped-out surface tearing down). Sync
    // with a PING/PONG on the same control lane so we know it was processed.
    try h.client.sendControlRaw(.detach, o.channel, "");
    try h.client.sendControlRaw(.ping, protocol.control_channel, "stale-detach-sync");
    _ = try h.client.waitControl(.pong);

    // The session must STILL be bound + streaming to conn 2...
    h.store.mutex.lock();
    const s = h.store.table.getByChannel(o.channel).?;
    try testing.expect(s.alive and s.bound and s.streaming);
    h.store.mutex.unlock();

    // ...and live output must still reach conn 2.
    h.server.onChildOutput(o.channel, "+live");
    const d = try rc.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 5), dp.byte_offset);
    try testing.expectEqualSlices(u8, "+live", dp.bytes);
}

test "P1: idle-TTL reaper evicts an orphaned session once past the TTL" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 0 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var prng = std.Random.DefaultPrng.init(22);

    // Build a store with a SMALL idle TTL (100ms) and no reaper thread; we invoke
    // reapIdle explicitly under the fixed clock.
    const store = try alloc.create(session.SessionStore);
    defer alloc.destroy(store);
    store.* = session.SessionStore.init(alloc, prng.random(), &clock, TestClock.now, 100);
    defer store.deinit();

    // A bound session is NEVER reaped, even past TTL.
    const s = try store.table.create(fc.child(), 1, 24, 80, 1024, 0);
    const channel = s.channel; // capture: `s` becomes dangling once reaped + freed
    s.bound = true;
    s.last_activity_ms = 0;
    clock.ms = 10_000; // way past TTL
    store.reapIdle();
    try testing.expect(store.table.getByChannel(channel) != null); // bound ⇒ kept

    // Orphan it; now it is reaped once last_activity is older than the TTL.
    s.bound = false;
    s.last_activity_ms = 10_000;
    clock.ms = 10_050; // only 50ms idle (< 100ms TTL) ⇒ still kept
    store.reapIdle();
    try testing.expect(store.table.getByChannel(channel) != null);

    clock.ms = 10_200; // 200ms idle (> 100ms TTL) ⇒ reaped + child terminated
    store.reapIdle();
    try testing.expect(store.table.getByChannel(channel) == null);
    try testing.expect(fc.terminated);
}
