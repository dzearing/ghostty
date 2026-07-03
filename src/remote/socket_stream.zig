//! A TCP-socket-backed bidirectional byte stream (WP: TCP transport). This is the
//! real-network analogue of `ssh_transport.zig`'s `ChildStream`: where `ChildStream`
//! wraps an ssh subprocess's `(stdout_r, stdin_w)` pipe pair, `SocketStream` wraps a
//! single connected TCP socket fd so `read`→`recv` and `write`→`send`.
//!
//! It can hand out BOTH flavours of the (structurally identical) `Stream` vtable:
//!   - `serverStream()`   → `agent/server.zig`'s `server.Stream`  (agent side).
//!   - `connectionStream()` → `connection.zig`'s `connection.Stream` (client side).
//! The two vtables have the same `{read, write, close}` shape; the underlying fns
//! are shared.
//!
//! ## EOF / reset mapping (mirrors `ChildStream`)
//! A peer-closed or reset connection is reported as EOF (`read` returns 0), never an
//! error, so the reader threads in `Server`/`Connection` see a clean stream end:
//!   - `read`:  `recv` returning 0 is EOF; `ConnectionResetByPeer` / a closed fd
//!     (`NotOpenForReading` / `SocketNotConnected`) → 0.
//!   - `write`: `BrokenPipe` / `ConnectionResetByPeer` / closed fd → 0, which
//!     `writeAll` turns into `error.WriteZero` (a dead lane), exactly like
//!     `ChildStream.writeFn`.
//!
//! ## close unblocks a blocked read
//! `close` does `shutdown(.both)` then `close(fd)`. The `shutdown` makes a blocked
//! `recv` on another thread return 0 (EOF) immediately, satisfying the `Stream`
//! contract that `close` is safe to call concurrently with a blocked `read` and
//! unblocks it. `close` is idempotent (guarded by an atomic flag).
//!
//! ## SIGPIPE
//! On Darwin/BSD we set `SO_NOSIGPIPE` on the socket so a `send` to a dead peer
//! returns `EPIPE`/`BrokenPipe` (mapped to 0 above) instead of raising SIGPIPE and
//! killing the process. On Linux we pass `MSG_NOSIGNAL` on every `send`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const server = @import("agent/server.zig");
const connection = @import("connection.zig");

/// A `Stream` over a single connected TCP socket fd. Heap-allocate it (so its
/// address is stable for the vtable `ctx`) via `create`, or embed it and take a
/// pointer; the vtable `ctx` is always `*SocketStream`.
pub const SocketStream = struct {
    fd: posix.socket_t,
    closed: std.atomic.Value(bool) = .{ .raw = false },

    /// On Linux, `send` needs `MSG_NOSIGNAL`; elsewhere we rely on `SO_NOSIGPIPE`.
    const send_flags: u32 = if (builtin.os.tag == .linux) std.os.linux.MSG.NOSIGNAL else 0;

    /// Wrap an already-connected socket fd. Sets `SO_NOSIGPIPE` on Darwin/BSD.
    pub fn init(fd: posix.socket_t) SocketStream {
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
                // SO_NOSIGPIPE: a write to a reset peer returns EPIPE instead of
                // raising SIGPIPE. Best-effort (ignore failure).
                //
                // MUST go through libc directly, NOT `posix.setsockopt`: the std
                // wrapper treats `EINVAL` as `unreachable`, but Darwin returns
                // EINVAL for a socket that was RESET while sitting in the accept
                // backlog (e.g. a reconnect dial that hit its handshake deadline
                // and closed while the agent was frozen). The std wrapper turned
                // that into a PANIC inside the agent's accept path — one stale
                // queued connection at thaw killed the whole agent (and every
                // live session with it). The `catch {}` never got a chance.
                const one: c_int = 1;
                _ = std.c.setsockopt(
                    fd,
                    posix.SOL.SOCKET,
                    posix.SO.NOSIGPIPE,
                    &one,
                    @sizeOf(c_int),
                );
            },
            else => {},
        }
        return .{ .fd = fd };
    }

    /// Allocate a heap `SocketStream` over `fd`. Freed by the caller via `destroy`
    /// (after `close`).
    pub fn create(alloc: Allocator, fd: posix.socket_t) !*SocketStream {
        const self = try alloc.create(SocketStream);
        self.* = SocketStream.init(fd);
        return self;
    }

    pub fn destroy(self: *SocketStream, alloc: Allocator) void {
        alloc.destroy(self);
    }

    // --- Shared byte ops (used by both vtable flavours) ----------------------

    fn readImpl(self: *SocketStream, buf: []u8) anyerror!usize {
        // `recv`'s `EBADF`/`ENOTSOCK` paths are `unreachable` in std (they assume no
        // concurrent close), but our `close` contract DOES race a blocked/entering
        // `read` on another thread (the mux pump). `recv` of a fd our own `close`
        // already shut down + closed can land on `EBADF`/`ENOTSOCK`; treat those — and
        // a normal reset — as EOF so the pump exits cleanly instead of panicking.
        if (self.closed.load(.acquire)) return 0;
        const n = posixRecv(self.fd, buf) catch |err| switch (err) {
            // Peer reset, our own close/shutdown raced this read, or the fd was
            // already closed by a concurrent `close` → EOF.
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            error.Closed,
            => return 0,
            else => return err,
        };
        return n; // 0 == orderly EOF (peer closed)
    }

    /// `posix.recv` but with the close-race `EBADF`/`ENOTSOCK` mapped to a catchable
    /// `error.Closed` instead of std's `unreachable` (which would panic when our own
    /// `close` races a blocked read on another thread).
    fn posixRecv(fd: posix.socket_t, buf: []u8) !usize {
        while (true) {
            const rc = posix.system.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .BADF, .NOTSOCK => return error.Closed,
                .CONNRESET, .CONNREFUSED => return error.ConnectionResetByPeer,
                .NOTCONN => return error.SocketNotConnected,
                .TIMEDOUT => return error.ConnectionTimedOut,
                .NOMEM => return error.SystemResources,
                .FAULT => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        }
    }

    fn writeImpl(self: *SocketStream, bytes: []const u8) anyerror!usize {
        if (self.closed.load(.acquire)) return 0;
        return posixSend(self.fd, bytes) catch |err| switch (err) {
            // A dead/reset peer (or a closed fd during shutdown) is a closed lane:
            // surface 0 so `writeAll` yields `error.WriteZero`.
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.Closed,
            => 0,
            else => err,
        };
    }

    /// `posix.send` with the close-race `EBADF`/`ENOTSOCK` mapped to `error.Closed`
    /// (std marks them `unreachable`), for the same reason as `posixRecv`.
    fn posixSend(fd: posix.socket_t, bytes: []const u8) !usize {
        while (true) {
            const rc = posix.system.sendto(fd, bytes.ptr, bytes.len, send_flags, null, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .BADF, .NOTSOCK => return error.Closed,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .ACCES => return error.AccessDenied,
                .FAULT => unreachable,
                else => |e| return posix.unexpectedErrno(e),
            }
        }
    }

    /// Idempotent. `shutdown(.both)` unblocks any blocked `recv` (it returns 0);
    /// then we close the fd. Safe to call concurrently with a blocked read.
    fn closeImpl(self: *SocketStream) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // shutdown first so a blocked reader on another thread wakes with EOF; the
        // socket may already be half-closed, so ignore errors.
        posix.shutdown(self.fd, .both) catch {};
        posix.close(self.fd);
    }

    // --- server.Stream adapter (agent side) ----------------------------------

    pub fn serverStream(self: *SocketStream) server.Stream {
        return .{ .ctx = self, .vtable = &server_vtable };
    }

    const server_vtable: server.Stream.VTable = .{
        .read = serverRead,
        .write = serverWrite,
        .close = closeFn,
    };
    fn serverRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        return readImpl(@ptrCast(@alignCast(ctx)), buf);
    }
    fn serverWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        return writeImpl(@ptrCast(@alignCast(ctx)), bytes);
    }

    // --- connection.Stream adapter (client side) -----------------------------

    pub fn connectionStream(self: *SocketStream) connection.Stream {
        return .{ .ctx = self, .vtable = &connection_vtable };
    }

    const connection_vtable: connection.Stream.VTable = .{
        .read = connRead,
        .write = connWrite,
        .close = closeFn,
    };
    fn connRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        return readImpl(@ptrCast(@alignCast(ctx)), buf);
    }
    fn connWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        return writeImpl(@ptrCast(@alignCast(ctx)), bytes);
    }

    /// Shared close for both vtables.
    fn closeFn(ctx: *anyopaque) void {
        closeImpl(@ptrCast(@alignCast(ctx)));
    }
};

// =============================================================================
// Tests — a real loopback TCP socket pair (no mock; exercises recv/send/close)
// =============================================================================

const testing = std.testing;

/// Bind a listener on an ephemeral 127.0.0.1 port, connect to it, accept, and hand
/// back both connected fds. Caller closes them.
fn loopbackPair() !struct { a: posix.socket_t, b: posix.socket_t } {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const bound = listener.listen_address;

    const client = try std.net.tcpConnectToAddress(bound);
    const accepted = try listener.accept();
    return .{ .a = client.handle, .b = accepted.stream.handle };
}

test "SocketStream: round-trips bytes over a real loopback socket" {
    const pair = try loopbackPair();
    var a = SocketStream.init(pair.a);
    var b = SocketStream.init(pair.b);
    defer a.serverStream().close();
    defer b.connectionStream().close();

    const sa = a.serverStream();
    const sb = b.connectionStream();

    try sa.writeAll("hello-socket");
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    while (total < "hello-socket".len) {
        const n = try sb.read(buf[total..]);
        try testing.expect(n > 0);
        total += n;
    }
    try testing.expectEqualStrings("hello-socket", buf[0..total]);

    // Reverse direction too.
    try sb.writeAll("pong");
    total = 0;
    while (total < "pong".len) {
        const n = try sa.read(buf[total..]);
        try testing.expect(n > 0);
        total += n;
    }
    try testing.expectEqualStrings("pong", buf[0..total]);
}

test "SocketStream: peer close surfaces as EOF (read returns 0)" {
    const pair = try loopbackPair();
    var a = SocketStream.init(pair.a);
    var b = SocketStream.init(pair.b);
    defer b.connectionStream().close();

    // Close side a; side b's next read must observe EOF (0), not an error.
    a.serverStream().close();

    var buf: [64]u8 = undefined;
    const n = try b.connectionStream().read(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "SocketStream: close unblocks a blocked read" {
    const pair = try loopbackPair();
    const a = try testing.allocator.create(SocketStream);
    defer testing.allocator.destroy(a);
    a.* = SocketStream.init(pair.a);
    var b = SocketStream.init(pair.b);
    defer b.connectionStream().close();

    const Reader = struct {
        s: *SocketStream,
        got_eof: bool = false,
        fn run(self: *@This()) void {
            var buf: [16]u8 = undefined;
            const n = self.s.serverStream().read(&buf) catch 0;
            self.got_eof = (n == 0);
        }
    };
    var r = Reader{ .s = a };
    const t = try std.Thread.spawn(.{}, Reader.run, .{&r});
    // Give the reader a moment to block in recv, then close from this thread.
    std.Thread.yield() catch {};
    std.Thread.sleep(20 * std.time.ns_per_ms);
    a.serverStream().close();
    t.join();
    try testing.expect(r.got_eof);
}

test "SocketStream: init on a dead/invalid fd must not panic (agent thaw crash)" {
    // Field crash (WP-D1 freeze/thaw): reconnect dials that hit their
    // handshake deadline close while the agent is SIGSTOPped; at thaw the
    // agent accept()s those already-reset backlog sockets and `init`'s
    // SO_NOSIGPIPE setsockopt gets EINVAL — which `std.posix.setsockopt`
    // declares `unreachable`, panicking the WHOLE agent (all sessions lost).
    // `init` must be best-effort on ANY fd state. A closed fd exercises the
    // same std `unreachable` class (EBADF) deterministically.
    const pair = try loopbackPair();
    posix.close(pair.a);
    posix.close(pair.b);
    // Pre-fix: panics inside std.posix.setsockopt (EBADF => unreachable).
    // Post-fix (raw libc call): a silent no-op.
    _ = SocketStream.init(pair.a);
}

test {
    testing.refAllDecls(@This());
}
