//! Socket recv/send with COMPLETE error mappings, plus `std.Io.Reader` /
//! `std.Io.Writer` implementations built on them (T81).
//!
//! ## Why not `std.net.Stream.Reader`/`Writer`?
//!
//! std's socket paths treat several "the socket is being torn down" errors as
//! `unreachable`, i.e. a PANIC in ReleaseSafe/Debug:
//!   - send after our own `shutdown(.both)` → `WSAESHUTDOWN` → unreachable
//!     (std assumes nobody sends after a write shutdown — but our transport
//!     `close` contract deliberately shutdowns first to unblock a writer
//!     thread parked in `send` on a dead link).
//!   - a pending overlapped op aborted by `closesocket` → `WSA_OPERATION_ABORTED`
//!     → unreachable.
//! T81: killing a relay agent under a live remote window made the relay drop
//! the client WebSocket without a close frame; the ws teardown then sent on the
//! shut-down socket and the `unreachable` panic killed the whole GUI process.
//! The same class exists agent-side (the agent uses the same WebSocket client).
//!
//! `recvOnce`/`sendOnce` are the raw ops (also used by `socket_stream.zig` —
//! this file is the extraction of its `posixRecv`/`posixSend`): every
//! close-race flavour maps to `error.Closed`/`error.ConnectionResetByPeer`/...,
//! never `unreachable`. `Reader`/`Writer` wrap them behind the standard
//! `std.Io` interfaces so buffered/TLS consumers (`ws_client.zig`) can use them
//! as drop-in replacements for `std.net.Stream.Reader`/`Writer`.
//!
//! ## Windows note
//! Winsock reports failure as `SOCKET_ERROR` + `WSAGetLastError()`, NOT via
//! errno — `posix.errno(-1)` would read a stale libc errno there, classifying
//! every failure as `.SUCCESS` and feeding -1 into `@intCast` (an instant
//! panic). So both ops have a dedicated Windows branch on `ws2_32`.
//!
//! ## SIGPIPE
//! On Darwin/BSD call `disableSigpipe(fd)` once per socket so a `send` to a
//! dead peer returns `EPIPE` instead of raising SIGPIPE; on Linux `sendOnce`
//! passes `MSG_NOSIGNAL`. (There is no SIGPIPE on Windows.)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// On Linux, `send` needs `MSG_NOSIGNAL`; elsewhere we rely on `SO_NOSIGPIPE`.
const send_flags: u32 = if (builtin.os.tag == .linux) std.os.linux.MSG.NOSIGNAL else 0;

pub const RecvError = error{
    Closed,
    ConnectionResetByPeer,
    SocketNotConnected,
    ConnectionTimedOut,
    SystemResources,
    Unexpected,
};

pub const SendError = error{
    Closed,
    BrokenPipe,
    ConnectionResetByPeer,
    SystemResources,
    AccessDenied,
    Unexpected,
};

/// Best-effort `SO_NOSIGPIPE` on Darwin/BSD (no-op elsewhere). MUST go through
/// libc directly, NOT `posix.setsockopt`: the std wrapper treats `EINVAL` as
/// `unreachable`, but Darwin returns EINVAL for a socket that was RESET while
/// sitting in the accept backlog — the std wrapper turned that into a PANIC
/// (one stale queued connection killed a whole agent).
pub fn disableSigpipe(fd: posix.socket_t) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
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
}

/// One `recv`, with the close-race `EBADF`/`ENOTSOCK`/`WSAESHUTDOWN` mapped to
/// a catchable `error.Closed` instead of std's `unreachable` (which would panic
/// when our own `close` races a blocked read on another thread). 0 == EOF.
pub fn recvOnce(fd: posix.socket_t, buf: []u8) RecvError!usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        while (true) {
            const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
            const rc = w.ws2_32.recv(fd, buf.ptr, len, 0);
            if (rc != w.ws2_32.SOCKET_ERROR) return @intCast(rc);
            switch (w.ws2_32.WSAGetLastError()) {
                .WSAEINTR => continue,
                .WSAEBADF, .WSAENOTSOCK => return error.Closed,
                // WSAESHUTDOWN: our own `close` did shutdown(.both) while
                // this read raced it — same close-race class as EBADF.
                .WSAESHUTDOWN => return error.Closed,
                .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET, .WSAECONNREFUSED => return error.ConnectionResetByPeer,
                .WSAENOTCONN => return error.SocketNotConnected,
                .WSAETIMEDOUT => return error.ConnectionTimedOut,
                .WSAENOBUFS => return error.SystemResources,
                else => |e| return w.unexpectedWSAError(e),
            }
        }
    } else while (true) {
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

/// One `send`, with every teardown flavour (`EBADF`/`ENOTSOCK`/`WSAESHUTDOWN`/
/// `WSAENOTCONN`) mapped to `error.Closed` — std marks them `unreachable`, so a
/// send racing (or, on the ws close path, deliberately following) our own
/// `shutdown` must never reach std's mapping. Returns bytes accepted.
pub fn sendOnce(fd: posix.socket_t, bytes: []const u8) SendError!usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        while (true) {
            const len: i32 = @intCast(@min(bytes.len, std.math.maxInt(i32)));
            const rc = w.ws2_32.send(fd, bytes.ptr, len, 0);
            if (rc != w.ws2_32.SOCKET_ERROR) return @intCast(rc);
            switch (w.ws2_32.WSAGetLastError()) {
                .WSAEINTR => continue,
                // A send on a not-/no-longer-connected socket is a dead lane.
                .WSAEBADF, .WSAENOTSOCK, .WSAESHUTDOWN, .WSAENOTCONN => return error.Closed,
                .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => return error.ConnectionResetByPeer,
                .WSAENOBUFS => return error.SystemResources,
                else => |e| return w.unexpectedWSAError(e),
            }
        }
    } else while (true) {
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

/// `std.net.Stream.read` replacement for loopback TEST HARNESSES (T89b): std's
/// `Stream.read` goes through `windows.ReadFile` on Windows, which fails with
/// `ERROR_INVALID_PARAMETER` (87) on the OVERLAPPED sockets std creates —
/// `recv` is the correct call on a socket regardless of its overlapped flag.
/// 0 == EOF, like `Stream.read`.
pub fn readStream(stream: std.net.Stream, buf: []u8) RecvError!usize {
    return recvOnce(stream.handle, buf);
}

/// `std.net.Stream.writeAll` replacement for loopback TEST HARNESSES (T89b):
/// same overlapped-socket problem as `readStream`, on the `WriteFile` side.
pub fn writeAllStream(stream: std.net.Stream, bytes: []const u8) SendError!void {
    var off: usize = 0;
    while (off < bytes.len) off += try sendOnce(stream.handle, bytes[off..]);
}

/// A buffered `std.Io.Reader` over a socket fd — the panic-free stand-in for
/// `std.net.Stream.Reader` (same field/method shape: pinned `interface_state`,
/// `interface()`, `getError()`). Heap-pin it: the interface uses
/// `@fieldParentPtr`.
pub const Reader = struct {
    interface_state: std.Io.Reader,
    fd: posix.socket_t,
    error_state: ?RecvError = null,

    pub fn init(fd: posix.socket_t, buffer: []u8) Reader {
        return .{
            .interface_state = .{
                .vtable = &.{ .stream = streamFn },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .fd = fd,
        };
    }

    pub fn interface(r: *Reader) *std.Io.Reader {
        return &r.interface_state;
    }

    pub fn getError(r: *const Reader) ?RecvError {
        return r.error_state;
    }

    fn streamFn(
        io_r: *std.Io.Reader,
        io_w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface_state", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = recvOnce(r.fd, dest) catch |err| {
            r.error_state = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        io_w.advance(n);
        return n;
    }
};

/// A buffered `std.Io.Writer` over a socket fd — the panic-free stand-in for
/// `std.net.Stream.Writer` (same shape: `interface` field, `err`). Heap-pin it.
pub const Writer = struct {
    interface: std.Io.Writer,
    fd: posix.socket_t,
    err: ?SendError = null,

    pub fn init(fd: posix.socket_t, buffer: []u8) Writer {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drainFn },
                .buffer = buffer,
            },
            .fd = fd,
        };
    }

    /// One `sendOnce` per call; partial progress is legal (`flush`/`writeAll`
    /// loop). Buffered bytes go first, then the caller's data slices (the last
    /// one `splat`-repeated, of which we send at most one instance per call).
    fn drainFn(
        io_w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        const buffered = io_w.buffered();
        if (buffered.len != 0) {
            const n = sendOnce(w.fd, buffered) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            return io_w.consume(n);
        }
        if (data.len == 0) return 0;
        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len == 0) continue;
            const n = sendOnce(w.fd, bytes) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            return io_w.consume(n);
        }
        const last = data[data.len - 1];
        if (last.len == 0 or splat == 0) return 0;
        const n = sendOnce(w.fd, last) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        return io_w.consume(n);
    }
};

// =============================================================================
// Tests — a real loopback TCP socket pair (no mock; exercises recv/send/close)
// =============================================================================

const testing = std.testing;

fn loopbackPair() !struct { a: posix.socket_t, b: posix.socket_t } {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const bound = listener.listen_address;

    const client = try std.net.tcpConnectToAddress(bound);
    const accepted = try listener.accept();
    return .{ .a = client.handle, .b = accepted.stream.handle };
}

fn closeSock(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        std.os.windows.closesocket(fd) catch {};
    } else {
        posix.close(fd);
    }
}

test "Reader/Writer: round-trip through the std.Io interfaces" {
    const pair = try loopbackPair();
    defer closeSock(pair.a);
    defer closeSock(pair.b);

    var wbuf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;
    var w = Writer.init(pair.a, &wbuf);
    var r = Reader.init(pair.b, &rbuf);

    try w.interface.writeAll("hello-io");
    try w.interface.flush();

    var got: [8]u8 = undefined;
    const n = try r.interface().readSliceShort(&got);
    try testing.expectEqualStrings("hello-io", got[0..n]);
}

test "readStream/writeAllStream: round-trip + EOF over std.net.Stream (T89b)" {
    const pair = try loopbackPair();
    const a: std.net.Stream = .{ .handle = pair.a };
    const b: std.net.Stream = .{ .handle = pair.b };
    defer closeSock(pair.b);

    try writeAllStream(a, "harness-bytes");
    var got: [64]u8 = undefined;
    var total: usize = 0;
    while (total < "harness-bytes".len) {
        const n = try readStream(b, got[total..]);
        try testing.expect(n != 0);
        total += n;
    }
    try testing.expectEqualStrings("harness-bytes", got[0..total]);

    // Peer close → EOF (0), the same contract Stream.read gives on POSIX.
    closeSock(pair.a);
    try testing.expectEqual(@as(usize, 0), try readStream(b, &got));
}

test "Writer: flush after shutdown(.both) is an error, not a panic (T81)" {
    // The T81 regression: the ws close path shutdowns the socket, then a
    // best-effort/racing send follows. Through std.net.Stream.Writer this hit
    // `.WSAESHUTDOWN => unreachable` and killed the process; through ours it
    // must surface as error.WriteFailed.
    const pair = try loopbackPair();
    defer closeSock(pair.a);
    defer closeSock(pair.b);

    var wbuf: [64]u8 = undefined;
    var w = Writer.init(pair.a, &wbuf);
    // Real users (`ws_client.connect`, `SocketStream.init`) set NOSIGPIPE on
    // Darwin/BSD; without it the post-shutdown send below would raise SIGPIPE
    // there instead of returning EPIPE.
    disableSigpipe(pair.a);

    try w.interface.writeAll("doomed"); // buffered only, no send yet
    posix.shutdown(pair.a, .both) catch {};
    try testing.expectError(error.WriteFailed, w.interface.flush());
    try testing.expect(w.err != null);

    // Subsequent writes big enough to force a drain also fail, not panic.
    var big: [128]u8 = @splat('x');
    try testing.expectError(error.WriteFailed, w.interface.writeAll(&big));
}

test "Reader: peer close surfaces as EndOfStream through the interface" {
    const pair = try loopbackPair();
    defer closeSock(pair.b);

    var rbuf: [64]u8 = undefined;
    var r = Reader.init(pair.b, &rbuf);
    closeSock(pair.a);

    var got: [16]u8 = undefined;
    const n = try r.interface().readSliceShort(&got);
    try testing.expectEqual(@as(usize, 0), n);
}

test "Reader: recv after local shutdown is EOF or a mapped error, never a panic" {
    const pair = try loopbackPair();
    defer closeSock(pair.a);
    defer closeSock(pair.b);

    var rbuf: [64]u8 = undefined;
    var r = Reader.init(pair.b, &rbuf);
    posix.shutdown(pair.b, .both) catch {};

    var got: [16]u8 = undefined;
    // Windows reports WSAESHUTDOWN (→ error.Closed → ReadFailed); POSIX
    // returns 0 (EOF → readSliceShort gives 0). Both are fine — the assertion
    // is that we get HERE instead of dying in an `unreachable`.
    if (r.interface().readSliceShort(&got)) |n| {
        try testing.expectEqual(@as(usize, 0), n);
    } else |err| {
        try testing.expectEqual(error.ReadFailed, err);
        try testing.expectEqual(@as(?RecvError, error.Closed), r.getError());
    }
}
