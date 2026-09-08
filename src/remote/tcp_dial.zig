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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const client_mux = @import("client_mux.zig");
const socket_stream = @import("socket_stream.zig");
const pipe_stream = @import("pipe_stream.zig");

/// A fully stood-up, handshaked client connection over a TCP socket, AF_UNIX
/// socket, or Windows named pipe. The caller drives `conn` (openChannel /
/// writeInput / attachChannel / ...) and tears it all down with `deinit`.
pub const Dialed = struct {
    alloc: Allocator,
    transport: Transport,
    mux: *client_mux.ClientMux,
    conn: *connection.Connection,
    /// The negotiated parameters from the HELLO handshake.
    negotiated: protocol.Negotiated,

    /// The owned transport wrapper under the mux. The underlying fd/handle is
    /// closed by the mux's `close` (→ the stream's own `close`); deinit only
    /// frees the wrapper.
    pub const Transport = union(enum) {
        sock: *socket_stream.SocketStream,
        pipe: *pipe_stream.PipeStream,
    };

    /// Tear everything down in the strict order (see the module doc). Idempotent on
    /// the connection (its `shutdown` is). Safe to call once.
    pub fn deinit(self: *Dialed) void {
        self.conn.shutdown();
        self.mux.joinPump();
        self.conn.destroy(self.alloc);
        self.mux.destroy();
        switch (self.transport) {
            .sock => |s| self.alloc.destroy(s),
            .pipe => |p| self.alloc.destroy(p),
        }
        self.* = undefined;
    }
};

/// The HELLO handshake failed (a dropped stream, a garbage payload, or a peer
/// that answered something that isn't a HELLO). An INCOMPATIBLE peer is
/// `error.ProtocolIncompatible` instead — see `DialReport`.
pub const HandshakeFailed = error{HandshakeFailed};

/// What a dial learned about the peer even though it failed. Filled in only
/// when the caller passes one (`dialPipeTimeoutReport`); everything is
/// best-effort and null means "we never found out".
///
/// It exists for exactly one decision: a `error.ProtocolIncompatible` says the
/// two ends cannot talk, and the app's response to that is destructive (restart
/// the local agent, ending its sessions). Doing that when the AGENT is the
/// NEWER side is a silent downgrade, so the direction has to be knowable before
/// anything is killed (T125).
pub const DialReport = struct {
    /// The `proto_version` the peer advertised in its HELLO, or null when no
    /// HELLO was parsed at all (timeout, dropped stream, garbage).
    peer_proto_version: ?u16 = null,
};

/// What a FAILED HELLO handshake means, from the error the wait returned and
/// the peer proto version the control reader managed to parse.
///
/// A peer we UNDERSTOOD and disagreed with is a different box state from one
/// that never spoke, and the caller's response to it is different too (T125):
/// a skew is permanent until somebody updates a side, so retrying it is wasted
/// time and "could not reach that machine" sends the user to the network for an
/// answer that is not there (T628).
///
/// `error.Incompatible` alone cannot tell them apart: the control reader also
/// raises it for EOF before the HELLO, a malformed frame, and a HELLO payload
/// that would not parse. A parsed peer proto version is the discriminator — it
/// is written ONLY after `Hello.parse` succeeded, and the sole error left after
/// that point is `negotiate` disagreeing.
///
/// It is a free function rather than three lines inline because BOTH dialers
/// need the same answer and only one of them had it: `relay_dial` collapsed
/// every handshake failure into `error.HandshakeFailed`, so a remote machine on
/// an incompatible protocol was indistinguishable from one that is off (T628).
pub fn classifyHandshakeError(err: anyerror, peer_proto: ?u16) anyerror {
    return switch (err) {
        error.HandshakeTimeout => error.HandshakeTimeout,
        error.Incompatible => if (peer_proto != null)
            error.ProtocolIncompatible
        else
            error.HandshakeFailed,
        else => error.HandshakeFailed,
    };
}

/// Default deadline for the HELLO handshake (WP-D1). A peer that TCP-accepts
/// but never answers (frozen/SIGSTOPped agent: the kernel backlog completes the
/// connect; the process says nothing) must fail the dial instead of parking it
/// forever — the GUI reconnect loop counts the failed attempt and backs off.
pub const default_handshake_timeout_ns: u64 = 10 * std.time.ns_per_s;

/// Connect to `host:port`, wrap the socket as the single transport, fold the two
/// lanes through a `ClientMux`, create + start a `Connection`, and block until the
/// HELLO handshake completes — at most `default_handshake_timeout_ns`. On success
/// returns a `Dialed` the caller owns; on any failure all partial resources are
/// cleaned up and the error is returned.
///
/// The error set is inferred (it spans TCP connect, allocation, thread spawn,
/// `error.HandshakeFailed`, and `error.HandshakeTimeout`).
///
/// `encoding` is the pinned transfer encoding (must match what the agent runs with;
/// `.raw` for a clean TCP/Tailscale hop).
pub fn dial(
    alloc: Allocator,
    host: []const u8,
    port: u16,
    encoding: protocol.TransferEncoding,
) !Dialed {
    return dialTimeout(alloc, host, port, encoding, default_handshake_timeout_ns);
}

/// `dial` with an explicit HELLO-handshake deadline (ns). Tests use a short
/// deadline; production callers should go through `dial`.
pub fn dialTimeout(
    alloc: Allocator,
    host: []const u8,
    port: u16,
    encoding: protocol.TransferEncoding,
    handshake_timeout_ns: u64,
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
    // `dialConnected` takes ownership of `sock` (closes + destroys it on any
    // failure), so no errdefer here.
    return dialConnected(alloc, .{ .sock = sock }, sock.connectionStream(), encoding, handshake_timeout_ns, null);
}

/// Default deadline shared by `dialUnix`; the same rationale as
/// `default_handshake_timeout_ns` (a peer that accepts but never speaks must not
/// park the dial forever).
pub fn dialUnix(
    alloc: Allocator,
    path: []const u8,
    encoding: protocol.TransferEncoding,
) !Dialed {
    return dialUnixTimeout(alloc, path, encoding, default_handshake_timeout_ns);
}

/// `dialUnix` with an explicit HELLO-handshake deadline (ns). The AF_UNIX
/// analogue of `dialTimeout`: connect a stream socket at `path`, then hand the
/// fd to the SAME `dialConnected` core (mux → Connection → HELLO). Used for the
/// local-agent 0600 unix socket (T09/T09b); `SocketStream` is fd-based and
/// transport-agnostic so recv/send/shutdown work verbatim on AF_UNIX.
pub fn dialUnixTimeout(
    alloc: Allocator,
    path: []const u8,
    encoding: protocol.TransferEncoding,
    handshake_timeout_ns: u64,
) !Dialed {
    // 1. Connect an AF_UNIX stream socket at `path` (mirrors the CLI's
    //    connectUnixSocket). We own the fd from here; on each pre-`sock` error
    //    path we close it explicitly (no errdefer, so `dialConnected`'s own
    //    teardown can't double-close it) — same discipline as the TCP path.
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);

    var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    if (path.len >= addr.path.len) {
        std.posix.close(fd);
        return error.NameTooLong;
    }
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |e| {
        std.posix.close(fd);
        return e;
    };

    // Hand the fd to a SocketStream immediately so teardown is uniform.
    const sock = alloc.create(socket_stream.SocketStream) catch |e| {
        std.posix.close(fd);
        return e;
    };
    sock.* = socket_stream.SocketStream.init(fd);
    // `dialConnected` takes ownership of `sock` (closes + destroys it on any
    // failure) — cancel the raw-fd errdefer above by returning through it.
    return dialConnected(alloc, .{ .sock = sock }, sock.connectionStream(), encoding, handshake_timeout_ns, null);
}

/// Connect to a Windows named pipe at `name` (a full `\\.\pipe\...` path) —
/// the local `ghoztty-agent --listen-pipe` transport (T89c), the Windows
/// analogue of `dialUnix`. Windows-only: returns `error.PipeUnsupported`
/// elsewhere.
pub fn dialPipe(
    alloc: Allocator,
    name: []const u8,
    encoding: protocol.TransferEncoding,
) !Dialed {
    return dialPipeTimeout(alloc, name, encoding, default_handshake_timeout_ns);
}

/// `dialPipe` with an explicit HELLO-handshake deadline (ns). Connect the pipe
/// (PIPE_BUSY retried inside `pipe_stream.dialHandle`), then hand the handle to
/// the SAME `dialConnected` core (mux → Connection → HELLO) as every other
/// transport.
pub fn dialPipeTimeout(
    alloc: Allocator,
    name: []const u8,
    encoding: protocol.TransferEncoding,
    handshake_timeout_ns: u64,
) !Dialed {
    return dialPipeTimeoutReport(alloc, name, encoding, handshake_timeout_ns, null);
}

/// `dialPipeTimeout` that also fills in a `DialReport` about the peer. Only the
/// local-agent dial needs this: it is the one caller whose response to
/// `error.ProtocolIncompatible` is destructive, so it is the one caller that has
/// to know which side is behind.
pub fn dialPipeTimeoutReport(
    alloc: Allocator,
    name: []const u8,
    encoding: protocol.TransferEncoding,
    handshake_timeout_ns: u64,
    report: ?*DialReport,
) !Dialed {
    // Comptime gate: keeps the Windows pipe code out of POSIX analysis (the
    // same pattern as the agent's --listen-unix gate, mirrored).
    if (comptime builtin.os.tag != .windows) return error.PipeUnsupported;

    const handle = try pipe_stream.dialHandle(alloc, name);
    // We own the handle from here; hand it to a PipeStream immediately so
    // teardown is uniform (same discipline as the TCP/AF_UNIX paths).
    const pipe = alloc.create(pipe_stream.PipeStream) catch |e| {
        std.os.windows.CloseHandle(handle);
        return e;
    };
    pipe.* = pipe_stream.PipeStream.init(handle);
    // `dialConnected` takes ownership of `pipe` (closes + destroys it on any
    // failure).
    return dialConnected(alloc, .{ .pipe = pipe }, pipe.connectionStream(), encoding, handshake_timeout_ns, report);
}

/// Shared post-connect core for every transport (TCP, AF_UNIX, named pipe):
/// given an already heap-allocated transport wrapper and its connection-side
/// stream, fold the two logical lanes through a `ClientMux`, stand up + start a
/// `Connection`, and block until the HELLO handshake completes (bounded by
/// `handshake_timeout_ns`). Takes OWNERSHIP of `transport`: on any failure it
/// closes the stream + destroys the wrapper and returns the error; on success
/// the returned `Dialed` owns it.
fn dialConnected(
    alloc: Allocator,
    transport: Dialed.Transport,
    stream: connection.Stream,
    encoding: protocol.TransferEncoding,
    handshake_timeout_ns: u64,
    report: ?*DialReport,
) !Dialed {
    errdefer {
        stream.close(); // closes the fd/handle
        switch (transport) {
            .sock => |s| alloc.destroy(s),
            .pipe => |p| alloc.destroy(p),
        }
    }

    // 2. Fold the two logical lanes onto the single transport via the client mux.
    const mux = client_mux.ClientMux.create(alloc, stream, encoding) catch |e| {
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

    // 5. Block until the HELLO handshake completes (or fails), bounded by the
    //    deadline. On timeout the peer accepted TCP but never spoke (frozen
    //    agent / half-open middlebox): tear down exactly like a failed
    //    handshake (`shutdown` closes the lanes, unblocking + joining the
    //    reader still parked on the HELLO) and surface `HandshakeTimeout`.
    const negotiated = conn.waitHandshakeTimeout(handshake_timeout_ns) catch |err| {
        // Handshake failed: tear down (shutdown joins everything; pump joined too).
        conn.shutdown();
        mux.joinPump();
        // Read the peer's HELLO facts only AFTER the join, so the control
        // reader that wrote them has certainly finished.
        const peer_proto = conn.peerProtoVersion();
        if (report) |r| r.peer_proto_version = peer_proto;
        return classifyHandshakeError(err, peer_proto);
    };

    return .{
        .alloc = alloc,
        .transport = transport,
        .mux = mux,
        .conn = conn,
        .negotiated = negotiated,
    };
}

// =============================================================================
// Tests — dial a real in-process TCP agent-shaped peer over loopback
// =============================================================================

const testing = std.testing;
const test_util = @import("test_util.zig");

/// A minimal in-process "agent" over ONE accepted socket that mirrors the agent's
/// `Mux`/`StdioMux` demux rule and answers a HELLO + OPEN→OPENED, then echoes DATA.
/// This proves the dialer stands up a working `Connection` over a real socket
/// (recv/send + the mux), independent of the full pty-backed agent exe.
const MiniAgent = struct {
    fd: std.posix.socket_t,
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    err: ?anyerror = null,
    /// Advertise a different `proto_version` than this build pins, to model the
    /// agent-outlives-the-app skew (T125). Null = agree, like a real agent.
    proto_version: ?u16 = null,

    fn run(self: *MiniAgent) void {
        var ss = socket_stream.SocketStream.init(self.fd);
        self.runStream(ss.connectionStream());
    }

    /// Transport-agnostic body: serve HELLO/OPEN/DATA over any connected
    /// `connection.Stream` (socket or named pipe). Closes the stream on exit.
    fn runStream(self: *MiniAgent, stream: connection.Stream) void {
        self.runInner(stream) catch |e| {
            self.err = e;
        };
    }

    fn runInner(self: *MiniAgent, stream: connection.Stream) !void {
        defer stream.close();

        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [4096]u8 = undefined;

        while (true) {
            while (try reader.next()) |frame| {
                switch (frame.type) {
                    .hello => {
                        const reply: protocol.Hello = .{
                            .proto_version = self.proto_version orelse protocol.proto_version,
                            .transfer_encoding = self.encoding,
                        };
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
    const total = try test_util.drainRing(pane.ring, &buf, "ping".len);
    try testing.expectEqualStrings("ping", buf[0..total]);

    dialed.conn.closeChannel(pane);
    dialed.deinit();
    agent_thread.join();
    listener.deinit();
    try testing.expect(agent.err == null);
}

test "classifyHandshakeError: only a peer we parsed and disagreed with is a skew" {
    // The rule both dialers now share (T628). A timeout stays a timeout; a
    // disagreement WITH a parsed peer version is the permanent one; the same
    // disagreement WITHOUT one (EOF before the HELLO, garbage, an unparseable
    // payload) is an ordinary handshake failure and must stay retryable.
    try testing.expectEqual(
        @as(anyerror, error.HandshakeTimeout),
        classifyHandshakeError(error.HandshakeTimeout, null),
    );
    try testing.expectEqual(
        @as(anyerror, error.ProtocolIncompatible),
        classifyHandshakeError(error.Incompatible, 7),
    );
    try testing.expectEqual(
        @as(anyerror, error.HandshakeFailed),
        classifyHandshakeError(error.Incompatible, null),
    );
    try testing.expectEqual(
        @as(anyerror, error.HandshakeFailed),
        classifyHandshakeError(error.EndOfStream, null),
    );
    // A peer version parsed on a NON-disagreement error changes nothing: the
    // discriminator is the pair, not either half.
    try testing.expectEqual(
        @as(anyerror, error.HandshakeFailed),
        classifyHandshakeError(error.EndOfStream, 7),
    );
    try testing.expectEqual(
        @as(anyerror, error.HandshakeTimeout),
        classifyHandshakeError(error.HandshakeTimeout, 7),
    );
}

test "dial: a peer on a different protocol version fails as ProtocolIncompatible" {
    // The T125 skew, end to end over a real socket: a peer that ANSWERS and
    // disagrees must be distinguishable from one that never spoke, because the
    // app's response to it is destructive (restart the local agent) and its
    // response to a dead agent is not (spawn one).
    const alloc = testing.allocator;
    const enc: protocol.TransferEncoding = .raw;

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
    var agent = MiniAgent{
        .fd = undefined,
        .alloc = alloc,
        .encoding = enc,
        // An agent from a future build. The direction does not matter to the
        // dialer — only that the two ends disagree.
        .proto_version = protocol.proto_version + 1,
    };
    var accepter = Accepter{ .listener = &listener, .agent = &agent };
    const agent_thread = try std.Thread.spawn(.{}, Accepter.run, .{&accepter});

    try testing.expectError(
        error.ProtocolIncompatible,
        dial(alloc, "127.0.0.1", bound.getPort(), enc),
    );

    agent_thread.join();
    listener.deinit();
}

test "dial: a peer that accepts and says nothing is NOT reported as incompatible" {
    // The negative control for the test above. A silent peer times out; a torn
    // one fails the handshake. Neither is a protocol disagreement, and treating
    // either as one would hand the app a destructive answer to a transient
    // problem.
    const alloc = testing.allocator;

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    const bound = listener.listen_address;

    const Silent = struct {
        listener: *std.net.Server,
        conn: ?std.net.Server.Connection = null,
        fn run(self: *@This()) void {
            self.conn = self.listener.accept() catch null;
        }
    };
    var silent = Silent{ .listener = &listener };
    const t = try std.Thread.spawn(.{}, Silent.run, .{&silent});

    try testing.expectError(
        error.HandshakeTimeout,
        dialTimeout(alloc, "127.0.0.1", bound.getPort(), .raw, 200 * std.time.ns_per_ms),
    );

    t.join();
    if (silent.conn) |c| c.stream.close();
    listener.deinit();
}

test "dialUnix: stands up a Connection over a real AF_UNIX socket, OPEN + DATA round-trip" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = testing.allocator;
    const enc: protocol.TransferEncoding = .raw;

    // A short, unique socket path (sun_path is only ~104 bytes on macOS, so a
    // nested tmpDir realpath can overflow it — keep it under /tmp).
    var pbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "/tmp/gztt-t09b-dial-{d}.sock", .{std.c.getpid()});
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    // Bind an AF_UNIX listener and start the mini agent on the accepted socket.
    const addr = try std.net.Address.initUnix(path);
    var listener = try addr.listen(.{});

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

    // Dial the unix socket (the T09b path).
    var dialed = try dialUnix(alloc, path, enc);
    try testing.expectEqual(enc, dialed.negotiated.transfer_encoding);

    // OPEN a session.
    const pane = try dialed.conn.openChannel(.{ .rows = 24, .cols = 80 });
    try testing.expectEqualStrings("mini-1", pane.session_id);

    // DATA round-trip: input → agent echo → pane ring.
    try dialed.conn.writeInput(pane, "ping");
    var buf: [64]u8 = undefined;
    const total = try test_util.drainRing(pane.ring, &buf, "ping".len);
    try testing.expectEqualStrings("ping", buf[0..total]);

    dialed.conn.closeChannel(pane);
    dialed.deinit();
    agent_thread.join();
    listener.deinit();
    try testing.expect(agent.err == null);
}

test "dialPipe: stands up a Connection over a real named pipe, OPEN + DATA round-trip" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    const alloc = testing.allocator;
    const enc: protocol.TransferEncoding = .raw;

    var nbuf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&nbuf, "\\\\.\\pipe\\gztt-t89c-dial-{d}", .{
        std.os.windows.GetCurrentProcessId(),
    });

    // Bind a pipe listener and run the mini agent over the accepted instance.
    var listener = try pipe_stream.PipeListener.bind(alloc, name);
    defer listener.deinit();

    const Accepter = struct {
        listener: *pipe_stream.PipeListener,
        agent: *MiniAgent,
        fn run(self: *@This()) void {
            const h = self.listener.accept() catch return;
            var ps = pipe_stream.PipeStream.init(h);
            self.agent.runStream(ps.connectionStream());
        }
    };
    var agent = MiniAgent{ .fd = undefined, .alloc = alloc, .encoding = enc };
    var accepter = Accepter{ .listener = &listener, .agent = &agent };
    const agent_thread = try std.Thread.spawn(.{}, Accepter.run, .{&accepter});

    // Dial the pipe (the T89c path).
    var dialed = try dialPipe(alloc, name, enc);
    try testing.expectEqual(enc, dialed.negotiated.transfer_encoding);

    // OPEN a session.
    const pane = try dialed.conn.openChannel(.{ .rows = 24, .cols = 80 });
    try testing.expectEqualStrings("mini-1", pane.session_id);

    // DATA round-trip: input → agent echo → pane ring.
    try dialed.conn.writeInput(pane, "ping");
    var buf: [64]u8 = undefined;
    const total = try test_util.drainRing(pane.ring, &buf, "ping".len);
    try testing.expectEqualStrings("ping", buf[0..total]);

    dialed.conn.closeChannel(pane);
    dialed.deinit();
    agent_thread.join();
    try testing.expect(agent.err == null);
}

test "dialPipe: connecting to a nonexistent pipe fails cleanly (no leak)" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var nbuf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&nbuf, "\\\\.\\pipe\\gztt-t89c-nope-{d}", .{
        std.os.windows.GetCurrentProcessId(),
    });
    try testing.expectError(error.FileNotFound, dialPipe(testing.allocator, name, .raw));
}

test "dialUnix: connect to a nonexistent path fails cleanly (no leak)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "/tmp/gztt-t09b-nope-{d}.sock", .{std.c.getpid()});
    std.fs.cwd().deleteFile(path) catch {};
    // No listener bound → connect must fail (ENOENT/ECONNREFUSED) and free the fd.
    try testing.expectError(error.FileNotFound, dialUnix(alloc, path, .raw));
}

test {
    testing.refAllDecls(@This());
    // Ride the pipe transport's own unit tests along wherever tcp_dial's
    // tests run (both app lanes + test-agent) — `pipe_stream` is a private
    // import, so refAllDecls alone would not pull them in.
    _ = pipe_stream;
}
