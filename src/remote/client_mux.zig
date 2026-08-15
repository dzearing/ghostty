//! Client-side lane multiplexer (WP3, §4.3) — two logical `connection.Stream`s
//! (control + data) riding a SINGLE underlying transport stream.
//!
//! ## Why this exists
//!
//! `connection.Connection` is built (§4.3) for TWO logical lanes — a *control*
//! lane (HELLO/PING/PONG/RPC/lifecycle) and a *data* lane (the muxed per-channel
//! DATA). The original ssh transport gave each lane its own ssh channel, i.e. two
//! subprocesses → two agent processes. But the single-process agent
//! (`agent/main.zig`, `StdioMux`) is ONE process with ONE stdin/stdout: it
//! multiplexes both lanes onto that single pipe pair. To talk to it over a single
//! ssh subprocess (or, later, a single TCP socket) the *client* must do the exact
//! symmetric thing — fold its two logical lanes onto one underlying stream.
//!
//! `ClientMux` is the byte-for-byte mirror of the agent's `StdioMux`:
//!
//!   - **Inbound** (`pumpInput`): a single pump reads the underlying stream, parses
//!     whole frames with a `protocol.Reader` (honoring the negotiated
//!     `TransferEncoding`), re-encodes each frame to its wire bytes, and pushes them
//!     into a per-lane blocking byte fifo by frame TYPE — **`protocol.onDataLane`
//!     → data lane, everything else → control lane** (identical to `StdioMux`).
//!     Each logical stream's `read` drains its own fifo, blocking until bytes or
//!     EOF, exactly like the agent's `Fifo`.
//!   - **Outbound** (`underlyingWrite`): writes from EITHER logical stream are
//!     serialized onto the single underlying stream under one `out_mutex`, so a
//!     frame from one lane is never interleaved mid-bytes with the other lane's.
//!     `Connection`'s MPSC writer hands us already-framed whole-frame wire bytes
//!     via one `Stream.writeAll` per frame, so a per-`write` mutex is sufficient to
//!     keep frames atomic — same contract `StdioMux.stdoutWrite` relies on.
//!   - **Lifecycle** (`closeAll`/EOF): closing either logical stream (or `deinit`)
//!     closes the underlying stream and EOFs both fifos so the two reader threads
//!     in `Connection` unblock. The pump also EOFs both fifos when the underlying
//!     stream hits EOF.
//!
//! ## Usage (what a single-ssh / TCP dialer calls)
//!
//! ```zig
//! var mux = try client_mux.ClientMux.create(alloc, transport_stream, encoding);
//! const lanes = mux.streams(); // .{ .control, .data }: two connection.Stream
//! const conn = try connection.Connection.create(alloc, lanes.control, lanes.data, hello);
//! const pump = try mux.startPump();  // spawns the inbound demux thread
//! try conn.start();
//! // ... drive the connection ...
//! conn.shutdown();   // closes the lane streams → mux closes the transport
//! pump.join();       // the pump thread exits on transport EOF
//! mux.destroy();
//! ```
//!
//! The pump can also be run inline on the caller's thread via `pumpInput` (it
//! blocks until EOF) — `startPump` just spawns that on a dedicated thread.
//!
//! Standalone-testable: `zig test src/remote/client_mux.zig` stands up a real
//! `Connection` over the mux's two lanes feeding ONE in-memory transport, and a
//! mock agent on the other end that runs the SAME demux rule as `StdioMux`; it
//! proves a HELLO handshake + OPEN→OPENED + a DATA round-trip flow correctly and
//! land on the right lanes without the two lanes corrupting each other.

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");

const Stream = connection.Stream;

/// Scratch read buffer for the inbound pump's blocking `Stream.read`. 64 KiB
/// matches the agent's `StdioMux.pumpInput` scratch so behavior mirrors exactly.
const read_buf_size: usize = 64 * 1024;

// -----------------------------------------------------------------------------
// ClientMux — one underlying transport Stream ↔ two logical connection.Streams
// -----------------------------------------------------------------------------

/// Multiplexes the control + data logical lanes onto a single underlying
/// `connection.Stream` (a ChildStream over one ssh subprocess, a TCP socket, or
/// the in-memory test pipe). The exact symmetric mirror of the agent's `StdioMux`.
pub const ClientMux = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    /// The single underlying transport. Owned by the caller (the dialer); the mux
    /// drives `read`/`writeAll`/`close` on it but does not free it.
    transport: Stream,

    /// Serializes outbound whole-frame writes from both lanes (mirror of
    /// `StdioMux.out_mutex`). One `writeAll` per frame → frame-atomic.
    out_mutex: std.Thread.Mutex = .{},

    control_fifo: Fifo,
    data_fifo: Fifo,

    /// Set once `close` has run so closing again (or after EOF) is idempotent and
    /// we don't double-close the transport.
    closed: std.atomic.Value(bool) = .{ .raw = false },

    pump_thread: ?std.Thread = null,

    /// The two logical lane streams the caller hands to `Connection.create`.
    pub const Lanes = struct {
        control: Stream,
        data: Stream,
    };

    /// Allocate a mux over `transport`. Does not touch the wire or spawn a thread;
    /// call `startPump` (or `pumpInput`) to run the inbound demux loop.
    pub fn create(
        alloc: Allocator,
        transport: Stream,
        encoding: protocol.TransferEncoding,
    ) !*ClientMux {
        const self = try alloc.create(ClientMux);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .transport = transport,
            .control_fifo = Fifo.init(alloc),
            .data_fifo = Fifo.init(alloc),
        };
        return self;
    }

    /// Free the mux. The pump thread (if any) must have been joined first, and the
    /// transport must already be closed (via `close`/`Connection.shutdown` or EOF).
    pub fn destroy(self: *ClientMux) void {
        std.debug.assert(self.pump_thread == null);
        self.control_fifo.deinit();
        self.data_fifo.deinit();
        self.alloc.destroy(self);
    }

    /// The two logical lane streams for `Connection.create(alloc, control, data, …)`.
    pub fn streams(self: *ClientMux) Lanes {
        return .{ .control = self.controlStream(), .data = self.dataStream() };
    }

    fn controlStream(self: *ClientMux) Stream {
        return .{ .ctx = self, .vtable = &control_vtable };
    }
    fn dataStream(self: *ClientMux) Stream {
        return .{ .ctx = self, .vtable = &data_vtable };
    }

    const control_vtable: Stream.VTable = .{
        .read = controlRead,
        .write = underlyingWrite,
        .close = closeAll,
    };
    const data_vtable: Stream.VTable = .{
        .read = dataRead,
        .write = underlyingWrite,
        .close = closeAll,
    };

    fn controlRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *ClientMux = @ptrCast(@alignCast(ctx));
        return self.control_fifo.read(buf);
    }
    fn dataRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *ClientMux = @ptrCast(@alignCast(ctx));
        return self.data_fifo.read(buf);
    }

    /// Serialize a whole-frame write from either lane onto the single transport.
    /// `Connection`'s writer calls `Stream.writeAll` once per frame, which loops
    /// over this with the frame's complete wire bytes; holding `out_mutex` for the
    /// entire `writeAll` of one frame is what keeps frames from interleaving. Since
    /// the transport may itself do partial writes, we loop here under the lock so
    /// one lane's frame is fully on the wire before the other lane's begins.
    fn underlyingWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *ClientMux = @ptrCast(@alignCast(ctx));
        self.out_mutex.lock();
        defer self.out_mutex.unlock();
        try self.transport.writeAll(bytes);
        return bytes.len;
    }

    /// Close: tear down the transport (unblocking the pump's blocked `read`) and
    /// EOF both lane fifos (unblocking `Connection`'s two reader threads). Idempotent
    /// and safe to call concurrently with a blocked `read` (mirror of
    /// `StdioMux.closeAll` + the transport's own `close`). Either lane's `close`
    /// tears down everything, matching `Connection.shutdown` closing both lanes.
    fn closeAll(ctx: *anyopaque) void {
        const self: *ClientMux = @ptrCast(@alignCast(ctx));
        self.shutdownOnce();
    }

    fn shutdownOnce(self: *ClientMux) void {
        if (self.closed.swap(true, .acq_rel)) return; // already closed
        self.control_fifo.close();
        self.data_fifo.close();
        self.transport.close();
    }

    /// Run the inbound demux loop on the CALLING thread until the transport hits
    /// EOF (or an unrecoverable parse/read error). Reads the underlying stream,
    /// parses whole frames with a `protocol.Reader`, re-encodes each to its wire
    /// bytes, and pushes them into the control or data fifo by frame TYPE — the
    /// SAME routing rule as the agent's `StdioMux.pumpInput`:
    ///   `protocol.onDataLane(frame.type)` → data fifo, else → control fifo.
    /// On EOF/error both fifos are EOF'd so the two reader threads unblock.
    pub fn pumpInput(self: *ClientMux) void {
        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);

        while (true) {
            // Drain any whole frames currently buffered, routing each to its lane.
            while (reader.next() catch break) |frame| {
                wire.clearRetainingCapacity();
                protocol.writeFrame(self.alloc, self.encoding, frame, &wire) catch continue;
                const lane: *Fifo = if (protocol.onDataLane(frame.type))
                    &self.data_fifo
                else
                    &self.control_fifo;
                _ = lane.write(wire.items) catch {};
            }
            const n = self.transport.read(&scratch) catch break;
            if (n == 0) break; // EOF
            reader.push(scratch[0..n]) catch break;
        }
        // EOF/error: unblock both lanes' readers and tear the transport down so a
        // concurrent writer fails fast too. (Idempotent with `closeAll`.)
        self.shutdownOnce();
    }

    /// Spawn `pumpInput` on a dedicated thread and return its handle (also stored
    /// in `self.pump_thread`). The caller joins it after `Connection.shutdown`
    /// (which closes the lane streams → the transport → unblocks the pump's read).
    pub fn startPump(self: *ClientMux) !std.Thread {
        std.debug.assert(self.pump_thread == null);
        const t = try std.Thread.spawn(.{}, pumpThreadMain, .{self});
        self.pump_thread = t;
        return t;
    }

    fn pumpThreadMain(self: *ClientMux) void {
        self.pumpInput();
    }

    /// Close the transport (if not already) and join the pump thread. Convenience
    /// for a dialer's teardown: call after `Connection.shutdown` has joined its own
    /// threads. After this the mux can be `destroy`d.
    pub fn joinPump(self: *ClientMux) void {
        self.shutdownOnce();
        if (self.pump_thread) |t| {
            t.join();
            self.pump_thread = null;
        }
    }
};

/// A thread-safe blocking byte fifo (one producer = `pumpInput`, one consumer =
/// a `Connection` lane reader thread). Reproduced client-side (NOT imported across
/// the client/agent boundary) from the agent's `Fifo` so the blocking-read +
/// EOF-on-close semantics match exactly.
const Fifo = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,
    closed: bool = false,
    alloc: Allocator,

    fn init(alloc: Allocator) Fifo {
        return .{ .alloc = alloc };
    }
    fn deinit(self: *Fifo) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }
    fn write(self: *Fifo, bytes: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        try self.buf.appendSlice(self.alloc, bytes);
        self.cond.signal();
        return bytes.len;
    }
    fn read(self: *Fifo, dst: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.head == self.buf.items.len and !self.closed) {
            self.cond.wait(&self.mutex);
        }
        const avail = self.buf.items[self.head..];
        if (avail.len == 0) return 0; // EOF
        const n = @min(avail.len, dst.len);
        @memcpy(dst[0..n], avail[0..n]);
        self.head += n;
        if (self.head == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
        }
        return n;
    }
    fn close(self: *Fifo) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const test_util = @import("test_util.zig");

// --- An in-memory bidirectional pipe (the single transport) -------------------

/// A thread-safe blocking byte fifo for the test transport (same shape as `Fifo`).
const TestFifo = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,
    closed: bool = false,
    /// When set, `read` on an empty fifo gives up after this long with
    /// `error.LoopbackReadTimeout` instead of blocking forever — the T258
    /// wedge shape, bounded here the same way as the agent lane's ByteFifo.
    /// Set only on the direction the TEST HARNESS reads (client→agent); the
    /// pump side idling between frames is the normal state.
    read_deadline_ns: ?u64 = null,
    alloc: Allocator,

    fn init(alloc: Allocator) TestFifo {
        return .{ .alloc = alloc };
    }
    fn deinit(self: *TestFifo) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }
    fn write(self: *TestFifo, bytes: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        try self.buf.appendSlice(self.alloc, bytes);
        self.cond.signal();
        return bytes.len;
    }
    fn read(self: *TestFifo, dst: []u8) !usize {
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
    fn close(self: *TestFifo) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

/// One SINGLE bidirectional in-memory transport. `c2a` carries client→agent bytes,
/// `a2c` the reverse. The client mux drives `clientStream`; the mock agent drives
/// `agentStream`. This is the ONE stream both logical lanes are folded onto.
const Pipe = struct {
    c2a: TestFifo,
    a2c: TestFifo,

    fn init(alloc: Allocator) Pipe {
        var p: Pipe = .{ .c2a = TestFifo.init(alloc), .a2c = TestFifo.init(alloc) };
        // The mock-agent runner (a test thread) reads c2a; bound that direction
        // so a frame that never arrives fails the test red instead of wedging
        // the lane (T258). The pump's a2c reads stay unbounded: idling between
        // frames is its normal state, and closeBoth wakes it at teardown.
        p.c2a.read_deadline_ns = test_util.liveness_ns;
        return p;
    }
    fn deinit(self: *Pipe) void {
        self.c2a.deinit();
        self.a2c.deinit();
    }

    fn clientStream(self: *Pipe) Stream {
        return .{ .ctx = self, .vtable = &client_vtable };
    }
    fn agentStream(self: *Pipe) Stream {
        return .{ .ctx = self, .vtable = &agent_vtable };
    }

    const client_vtable: Stream.VTable = .{ .read = clientRead, .write = clientWrite, .close = closeBoth };
    const agent_vtable: Stream.VTable = .{ .read = agentRead, .write = agentWrite, .close = closeBoth };

    fn clientRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        return self.a2c.read(buf);
    }
    fn clientWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        return self.c2a.write(bytes);
    }
    fn agentRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        return self.c2a.read(buf);
    }
    fn agentWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        return self.a2c.write(bytes);
    }
    fn closeBoth(ctx: *anyopaque) void {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        self.c2a.close();
        self.a2c.close();
    }
};

test "TestFifo: a deadlined read fails cleanly instead of wedging (T258 shape)" {
    var fifo = TestFifo.init(testing.allocator);
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

/// A mock single-process agent over ONE stream. It mirrors the agent's `StdioMux`
/// demux EXACTLY (`.data` → data lane, else → control lane) to prove the client
/// mux is the correct symmetric counterpart: every frame the client sends arrives
/// here whole, and the agent's replies — sent back over the SAME single stream —
/// land on the client's correct lane.
///
/// It is single-threaded: it reads whole frames from the transport, classifies
/// each by the StdioMux rule, and responds (HELLO echo, OPEN→OPENED, DATA echo).
const MockAgent = struct {
    alloc: Allocator,
    stream: Stream,
    encoding: protocol.TransferEncoding,
    reader: protocol.Reader,
    scratch: [read_buf_size]u8 = undefined,

    // Lane-arrival accounting, asserted by the test to prove correct demux.
    control_frames: usize = 0,
    data_frames: usize = 0,
    saw_hello: bool = false,
    saw_open: bool = false,
    saw_input_data: bool = false,
    last_input: std.ArrayList(u8) = .empty,

    fn init(alloc: Allocator, stream: Stream, encoding: protocol.TransferEncoding) MockAgent {
        return .{
            .alloc = alloc,
            .stream = stream,
            .encoding = encoding,
            .reader = protocol.Reader.init(alloc, encoding),
        };
    }
    fn deinit(self: *MockAgent) void {
        self.reader.deinit();
        self.last_input.deinit(self.alloc);
    }

    fn nextFrame(self: *MockAgent) !?protocol.Frame {
        while (true) {
            if (try self.reader.next()) |frame| return frame;
            const n = try self.stream.read(&self.scratch);
            if (n == 0) return null;
            try self.reader.push(self.scratch[0..n]);
        }
    }

    fn sendFrame(self: *MockAgent, frame: protocol.Frame) !void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);
        try protocol.writeFrame(self.alloc, self.encoding, frame, &wire);
        try self.stream.writeAll(wire.items);
    }

    /// Run until EOF. Classify each inbound frame by the StdioMux rule and respond.
    fn run(self: *MockAgent) !void {
        while (try self.nextFrame()) |frame| {
            // The EXACT StdioMux demux rule, asserted by the test via the counters.
            if (protocol.onDataLane(frame.type)) {
                self.data_frames += 1;
            } else {
                self.control_frames += 1;
            }

            switch (frame.type) {
                .hello => {
                    self.saw_hello = true;
                    // Echo the client's pinned encoding (control lane).
                    var parsed = try protocol.Hello.parse(self.alloc, frame.payload);
                    defer parsed.deinit();
                    const reply: protocol.Hello = .{ .transfer_encoding = parsed.value.transfer_encoding };
                    const json = try reply.encode(self.alloc);
                    defer self.alloc.free(json);
                    try self.sendFrame(.{
                        .type = .hello,
                        .channel = protocol.control_channel,
                        .seq = 0,
                        .payload = json,
                    });
                },
                .open => {
                    self.saw_open = true;
                    // Reply OPENED on the SAME channel (control lane).
                    const opened: protocol.Opened = .{ .session_id = "sess-1", .pid = 4242 };
                    const json = try protocol.encodeJson(self.alloc, opened);
                    defer self.alloc.free(json);
                    try self.sendFrame(.{
                        .type = .opened,
                        .channel = frame.channel,
                        .seq = 0,
                        .payload = json,
                    });
                },
                .data => {
                    // Client→agent input on the data lane. Remember it, then echo a
                    // DATA frame BACK on the data lane for the same channel so the
                    // round-trip lands in the pane's inbound ring.
                    self.saw_input_data = true;
                    const dp = try protocol.DataPayload.decode(frame.payload);
                    self.last_input.clearRetainingCapacity();
                    try self.last_input.appendSlice(self.alloc, dp.bytes);

                    const echo = "agent-echo";
                    const payload = try self.alloc.alloc(u8, protocol.DataPayload.encodedLen(echo.len));
                    defer self.alloc.free(payload);
                    const out: protocol.DataPayload = .{ .byte_offset = 0, .bytes = echo };
                    _ = out.encodeInto(payload);
                    try self.sendFrame(.{
                        .type = .data,
                        .channel = frame.channel,
                        .seq = 0,
                        .payload = payload,
                    });
                },
                else => {},
            }
        }
    }
};

const AgentRunner = struct {
    agent: *MockAgent,
    err: ?anyerror = null,
    fn run(self: *AgentRunner) void {
        self.agent.run() catch |e| {
            self.err = e;
        };
    }
};

const all_encodings = [_]protocol.TransferEncoding{ .raw, .cobs, .base64 };

test "loopback: two logical lanes over ONE transport ↔ StdioMux demux — HELLO + OPEN + DATA round-trip" {
    const alloc = testing.allocator;

    for (all_encodings) |enc| {
        var pipe = Pipe.init(alloc);
        defer pipe.deinit();

        // --- Agent side: a single-process mock over the ONE stream. ----------
        var agent = MockAgent.init(alloc, pipe.agentStream(), enc);
        defer agent.deinit();
        var runner = AgentRunner{ .agent = &agent };
        const agent_thread = try std.Thread.spawn(.{}, AgentRunner.run, .{&runner});

        // --- Client side: a real Connection over the mux's two lanes. ---------
        const mux = try ClientMux.create(alloc, pipe.clientStream(), enc);
        const lanes = mux.streams();
        const hello: protocol.Hello = .{ .transfer_encoding = enc };
        const conn = try connection.Connection.create(alloc, lanes.control, lanes.data, hello);

        // Spawn the inbound demux pump, then start the connection's threads.
        const pump = try mux.startPump();
        try conn.start();

        // 1) HELLO handshake flows over the control lane of the single transport.
        const negotiated = try conn.waitHandshake();
        try testing.expectEqual(enc, negotiated.transfer_encoding);

        // 2) OPEN→OPENED RPC (control lane) yields a live pane.
        const pane = try conn.openChannel(.{ .cwd = null, .rows = 24, .cols = 80 });
        try testing.expectEqualStrings("sess-1", pane.session_id);
        try testing.expectEqual(@as(i64, 4242), pane.pid);

        // 3) A DATA round-trip on the data lane: client input → agent → echo back
        //    into the pane's inbound ring. Prove it lands on the DATA lane.
        try conn.writeInput(pane, "hello-agent");

        // Drain the pane's inbound ring until the agent's echo arrives.
        var got: [64]u8 = undefined;
        const total = try test_util.drainRing(pane.ring, &got, "agent-echo".len);
        try testing.expectEqualStrings("agent-echo", got[0..total]);

        // The agent saw the client's input on the DATA lane verbatim.
        try testing.expectEqualStrings("hello-agent", agent.last_input.items);

        // --- Teardown: shutdown closes the lane streams → transport → pump EOF.
        conn.closeChannel(pane);
        conn.shutdown();
        mux.joinPump();
        _ = pump; // handle is owned/joined via joinPump
        agent_thread.join();

        try testing.expect(runner.err == null);

        // --- Demux assertions: frames landed on the CORRECT lanes (StdioMux rule).
        try testing.expect(agent.saw_hello); // HELLO on control lane
        try testing.expect(agent.saw_open); // OPEN on control lane
        try testing.expect(agent.saw_input_data); // input on DATA lane
        // Exactly one DATA frame reached the agent (the input); HELLO/OPEN/CLOSE
        // were all classified onto the control lane, never the data lane.
        try testing.expectEqual(@as(usize, 1), agent.data_frames);
        try testing.expect(agent.control_frames >= 2); // at least HELLO + OPEN

        conn.destroy(alloc);
        mux.destroy();
    }
}

test {
    std.testing.refAllDecls(@This());
}
