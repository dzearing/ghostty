//! Client TCP dialer (WP: TCP transport) — the reusable client entry point that a
//! test client (and later the Swift app / orchestrator) calls to stand up a real
//! networked `RemoteConnection` against a TCP-listening `ghoztty-agent`.
//!
//! It is the TCP analogue of `ssh_transport.zig`'s dialer: where that spawns an ssh
//! subprocess and wraps its stdio as a `ChildStream`, this connects a TCP socket and
//! wraps it as a `socket_stream.SocketStream`. The rest is identical to the
//! single-channel ssh path: ONE transport stream → `ClientMux` (folds the two
//! logical lanes) → `Connection.create(control, data, hello)` → start the pump + the
//! connection threads → handshake.
//!
//! ## Lifetime / teardown
//! `Dialed` owns the socket stream, the mux, and the connection. `deinit` performs
//! the strict teardown order:
//!   1. `conn.shutdown()` — closes the two lane streams (→ mux closes the transport
//!      socket, unblocking the pump's blocked `recv`) and joins the connection's
//!      writer/reader/heartbeat threads.
//!   2. `mux.joinPump()` — joins the inbound demux thread (already unblocked by 1).
//!   3. free `conn`, `mux`, the socket stream wrapper, and any owned strings.
//! The socket fd itself is closed by the mux's `close` (→ `SocketStream.close`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const client_mux = @import("client_mux.zig");
const socket_stream = @import("socket_stream.zig");

/// A fully stood-up, handshaked client connection over a TCP socket. The caller
/// drives `conn` (openChannel / writeInput / attachChannel / ...) and tears it all
/// down with `deinit`.
pub const Dialed = struct {
    alloc: Allocator,
    sock: *socket_stream.SocketStream,
    mux: *client_mux.ClientMux,
    conn: *connection.Connection,
    /// The negotiated parameters from the HELLO handshake.
    negotiated: protocol.Negotiated,

    /// Tear everything down in the strict order (see the module doc). Idempotent on
    /// the connection (its `shutdown` is). Safe to call once.
    pub fn deinit(self: *Dialed) void {
        self.conn.shutdown();
        self.mux.joinPump();
        self.conn.destroy(self.alloc);
        self.mux.destroy();
        self.alloc.destroy(self.sock);
        self.* = undefined;
    }
};

/// The HELLO handshake failed (version/encoding mismatch or a dropped stream).
pub const HandshakeFailed = error{HandshakeFailed};

/// Connect to `host:port`, wrap the socket as the single transport, fold the two
/// lanes through a `ClientMux`, create + start a `Connection`, and block until the
/// HELLO handshake completes. On success returns a `Dialed` the caller owns; on any
/// failure all partial resources are cleaned up and the error is returned.
///
/// The error set is inferred (it spans TCP connect, allocation, thread spawn, and
/// `error.HandshakeFailed`).
///
/// `encoding` is the pinned transfer encoding (must match what the agent runs with;
/// `.raw` for a clean TCP/Tailscale hop).
pub fn dial(
    alloc: Allocator,
    host: []const u8,
    port: u16,
    encoding: protocol.TransferEncoding,
) !Dialed {
    // 1. Connect the TCP socket. `tcpConnectToHost` resolves the host (DNS or a
    //    literal) and connects; we then own the stream's fd.
    const stream = try std.net.tcpConnectToHost(alloc, host, port);
    // From here, on any error we must close the fd. We hand it to a SocketStream
    // immediately so teardown is uniform.
    const sock = alloc.create(socket_stream.SocketStream) catch |e| {
        stream.close();
        return e;
    };
    sock.* = socket_stream.SocketStream.init(stream.handle);
    errdefer {
        sock.connectionStream().close(); // closes the fd
        alloc.destroy(sock);
    }

    // 2. Fold the two logical lanes onto the single socket via the client mux.
    const mux = client_mux.ClientMux.create(alloc, sock.connectionStream(), encoding) catch |e| {
        return e;
    };
    errdefer mux.destroy();

    // 3. Create the connection over the mux's two lanes with our HELLO.
    const hello: protocol.Hello = .{ .transfer_encoding = encoding };
    const conn = connection.Connection.create(alloc, mux.streams().control, mux.streams().data, hello) catch |e| {
        return e;
    };
    errdefer conn.destroy(alloc);

    // 4. Spawn the inbound demux pump, then start the connection threads.
    _ = mux.startPump() catch |e| return e;
    errdefer {
        // If start fails after the pump is running, close the transport so the pump
        // exits, then join it.
        conn.shutdown(); // safe even if start partially ran
        mux.joinPump();
    }
    conn.start() catch |e| return e;

    // 5. Block until the HELLO handshake completes (or fails).
    const negotiated = conn.waitHandshake() catch {
        // Handshake failed: tear down (shutdown joins everything; pump joined too).
        conn.shutdown();
        mux.joinPump();
        return error.HandshakeFailed;
    };

    return .{
        .alloc = alloc,
        .sock = sock,
        .mux = mux,
        .conn = conn,
        .negotiated = negotiated,
    };
}

// =============================================================================
// Tests — dial a real in-process TCP agent-shaped peer over loopback
// =============================================================================

const testing = std.testing;

/// A minimal in-process "agent" over ONE accepted socket that mirrors the agent's
/// `Mux`/`StdioMux` demux rule and answers a HELLO + OPEN→OPENED, then echoes DATA.
/// This proves the dialer stands up a working `Connection` over a real socket
/// (recv/send + the mux), independent of the full pty-backed agent exe.
const MiniAgent = struct {
    fd: std.posix.socket_t,
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    err: ?anyerror = null,

    fn run(self: *MiniAgent) void {
        self.runInner() catch |e| {
            self.err = e;
        };
    }

    fn runInner(self: *MiniAgent) !void {
        var ss = socket_stream.SocketStream.init(self.fd);
        const stream = ss.connectionStream();
        defer stream.close();

        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [4096]u8 = undefined;

        while (true) {
            while (try reader.next()) |frame| {
                switch (frame.type) {
                    .hello => {
                        const reply: protocol.Hello = .{ .transfer_encoding = self.encoding };
                        const json = try reply.encode(self.alloc);
                        defer self.alloc.free(json);
                        try sendFrame(self.alloc, stream, self.encoding, .{
                            .type = .hello,
                            .channel = protocol.control_channel,
                            .seq = 0,
                            .payload = json,
                        });
                    },
                    .open => {
                        const opened: protocol.Opened = .{ .session_id = "mini-1", .pid = 7 };
                        const json = try protocol.encodeJson(self.alloc, opened);
                        defer self.alloc.free(json);
                        try sendFrame(self.alloc, stream, self.encoding, .{
                            .type = .opened,
                            .channel = frame.channel,
                            .seq = 0,
                            .payload = json,
                        });
                    },
                    .data => {
                        const dp = try protocol.DataPayload.decode(frame.payload);
                        const payload = try self.alloc.alloc(u8, protocol.DataPayload.encodedLen(dp.bytes.len));
                        defer self.alloc.free(payload);
                        const out: protocol.DataPayload = .{ .byte_offset = 0, .bytes = dp.bytes };
                        _ = out.encodeInto(payload);
                        try sendFrame(self.alloc, stream, self.encoding, .{
                            .type = .data,
                            .channel = frame.channel,
                            .seq = 0,
                            .payload = payload,
                        });
                    },
                    else => {},
                }
            }
            const n = try stream.read(&scratch);
            if (n == 0) return;
            try reader.push(scratch[0..n]);
        }
    }

    fn sendFrame(
        alloc: Allocator,
        stream: connection.Stream,
        enc: protocol.TransferEncoding,
        frame: protocol.Frame,
    ) !void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(alloc);
        try protocol.writeFrame(alloc, enc, frame, &wire);
        try stream.writeAll(wire.items);
    }
};

test "dial: stands up a Connection over a real loopback socket, OPEN + DATA round-trip" {
    const alloc = testing.allocator;
    const enc: protocol.TransferEncoding = .raw;

    // Bind an ephemeral port and start the mini agent on the accepted socket.
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    const bound = listener.listen_address;

    const Accepter = struct {
        listener: *std.net.Server,
        agent: *MiniAgent,
        fn run(self: *@This()) void {
            const c = self.listener.accept() catch return;
            self.agent.fd = c.stream.handle;
            self.agent.run();
        }
    };
    var agent = MiniAgent{ .fd = undefined, .alloc = alloc, .encoding = enc };
    var accepter = Accepter{ .listener = &listener, .agent = &agent };
    const agent_thread = try std.Thread.spawn(.{}, Accepter.run, .{&accepter});

    // Dial it.
    var dialed = try dial(alloc, "127.0.0.1", bound.getPort(), enc);
    try testing.expectEqual(enc, dialed.negotiated.transfer_encoding);

    // OPEN a session.
    const pane = try dialed.conn.openChannel(.{ .rows = 24, .cols = 80 });
    try testing.expectEqualStrings("mini-1", pane.session_id);

    // DATA round-trip: input → agent echo → pane ring.
    try dialed.conn.writeInput(pane, "ping");
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    const deadline = std.time.milliTimestamp() + 5000;
    while (total < "ping".len) {
        const r = pane.ring.pop(buf[total..]);
        if (r.read > 0) {
            total += r.read;
        } else {
            if (std.time.milliTimestamp() > deadline) return error.Timeout;
            std.Thread.yield() catch {};
        }
    }
    try testing.expectEqualStrings("ping", buf[0..total]);

    dialed.conn.closeChannel(pane);
    dialed.deinit();
    agent_thread.join();
    listener.deinit();
    try testing.expect(agent.err == null);
}

test {
    testing.refAllDecls(@This());
}
