//! Agent-side lane multiplexer (WP2, §4.3) — folds the two logical lanes the
//! `Server` wants (control + data, each a `server.Stream`) onto a SINGLE underlying
//! byte transport (`server.Stream`). It is the symmetric mirror of the client's
//! `client_mux.ClientMux` and the exact generalization of what `main.zig`'s old
//! `StdioMux` did over stdin/stdout.
//!
//! ## Why generalized
//! The original `StdioMux` was hard-wired to `std.fs.File` stdin/stdout. The ssh
//! transport uses that (one stdin/stdout pipe pair per `ssh -- ghoztty-agent`). The
//! TCP daemon needs the SAME demux/serialize logic over a socket instead. So the
//! transport is now any `server.Stream`: a `StdioStream` adapter preserves the
//! stdio path; a `socket_stream.SocketStream.serverStream()` provides the TCP path.
//!
//! ## Demux rule (must match the client's `ClientMux` byte-for-byte, §4.3)
//!   - **Inbound** (`pumpInput`): read the transport, parse whole frames with a
//!     `protocol.Reader`, re-encode each frame to its wire bytes, push into the
//!     control or data fifo by frame TYPE — `frame.type == .data` → data fifo,
//!     everything else → control fifo. Each lane's `read` drains its own fifo.
//!   - **Outbound** (`underlyingWrite`): writes from EITHER lane serialize onto the
//!     single transport under one `out_mutex`, so a frame is never interleaved.
//!   - **Lifecycle**: closing either lane (or EOF) closes the transport and EOFs
//!     both fifos so the `Server`'s two reader threads unblock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const server = @import("server.zig");

const Stream = server.Stream;

/// Scratch read buffer for the inbound pump. 64 KiB matches the client mux.
const read_buf_size: usize = 64 * 1024;

/// Multiplexes the control + data lanes onto a single underlying `server.Stream`.
pub const Mux = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    /// The single underlying transport (stdio adapter or socket). The mux drives
    /// `read`/`writeAll`/`close` on it. Ownership of any backing fd is the caller's
    /// concern; `close` here calls `transport.close()`.
    transport: Stream,

    out_mutex: std.Thread.Mutex = .{},

    control_fifo: Fifo,
    data_fifo: Fifo,

    closed: std.atomic.Value(bool) = .{ .raw = false },

    pub fn create(
        alloc: Allocator,
        transport: Stream,
        encoding: protocol.TransferEncoding,
    ) !*Mux {
        const self = try alloc.create(Mux);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .transport = transport,
            .control_fifo = Fifo.init(alloc),
            .data_fifo = Fifo.init(alloc),
        };
        return self;
    }

    pub fn destroy(self: *Mux) void {
        self.control_fifo.deinit();
        self.data_fifo.deinit();
        self.alloc.destroy(self);
    }

    pub fn controlStream(self: *Mux) Stream {
        return .{ .ctx = self, .vtable = &control_vtable };
    }
    pub fn dataStream(self: *Mux) Stream {
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
        const self: *Mux = @ptrCast(@alignCast(ctx));
        return self.control_fifo.read(buf);
    }
    fn dataRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Mux = @ptrCast(@alignCast(ctx));
        return self.data_fifo.read(buf);
    }

    /// Serialize a whole-frame write from either lane onto the single transport.
    fn underlyingWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Mux = @ptrCast(@alignCast(ctx));
        self.out_mutex.lock();
        defer self.out_mutex.unlock();
        try self.transport.writeAll(bytes);
        return bytes.len;
    }

    fn closeAll(ctx: *anyopaque) void {
        const self: *Mux = @ptrCast(@alignCast(ctx));
        self.shutdownOnce();
    }

    fn shutdownOnce(self: *Mux) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.control_fifo.close();
        self.data_fifo.close();
        self.transport.close();
    }

    /// Read the transport, demux whole frames to the lane fifos, until EOF/error.
    /// Blocks on the calling thread. On EOF both fifos are EOF'd so the Server's
    /// reader threads unblock. Mirrors the client `ClientMux.pumpInput` exactly.
    pub fn pumpInput(self: *Mux) void {
        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);

        while (true) {
            while (reader.next() catch break) |frame| {
                wire.clearRetainingCapacity();
                protocol.writeFrame(self.alloc, self.encoding, frame, &wire) catch continue;
                const lane: *Fifo = if (frame.type == .data)
                    &self.data_fifo
                else
                    &self.control_fifo;
                _ = lane.write(wire.items) catch {};
            }
            const n = self.transport.read(&scratch) catch break;
            if (n == 0) break; // EOF
            reader.push(scratch[0..n]) catch break;
        }
        self.shutdownOnce();
    }
};

/// A thread-safe blocking byte fifo (one producer = `pumpInput`, one consumer = a
/// Server lane reader). Identical to the client mux's `Fifo`.
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

// -----------------------------------------------------------------------------
// StdioStream — a `server.Stream` over a stdin/stdout `std.fs.File` pair
// -----------------------------------------------------------------------------

/// Adapts a stdin/stdout `std.fs.File` pair to a single `server.Stream` so the
/// generalized `Mux` can run over the ssh `ghoztty-agent` stdio path unchanged.
/// `read` consumes stdin; `write` writes stdout; `close` is a no-op (the process
/// owns stdin/stdout — stdin EOF is the shutdown signal, driven by `pumpInput`).
pub const StdioStream = struct {
    stdin: std.fs.File,
    stdout: std.fs.File,

    pub fn init(stdin: std.fs.File, stdout: std.fs.File) StdioStream {
        return .{ .stdin = stdin, .stdout = stdout };
    }

    pub fn stream(self: *StdioStream) Stream {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Stream.VTable = .{ .read = readFn, .write = writeFn, .close = closeFn };

    fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *StdioStream = @ptrCast(@alignCast(ctx));
        return self.stdin.read(buf); // 0 == EOF
    }
    fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *StdioStream = @ptrCast(@alignCast(ctx));
        try self.stdout.writeAll(bytes);
        return bytes.len;
    }
    fn closeFn(_: *anyopaque) void {
        // No-op: we don't own the process stdin/stdout. The pump exits on stdin EOF.
    }
};

test {
    std.testing.refAllDecls(@This());
}
