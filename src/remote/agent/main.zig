//! `ghoztty-agent` entry point (WP2, §4.1–§4.2/§7.1) — the remote-host daemon the
//! client reaches via `ssh host -- ghoztty-agent`. It reads framed protocol from
//! stdin and writes framed protocol to stdout; the session-server core
//! (`server.zig`) spawns real pty-backed children (`pty_child.zig`) and streams
//! their output back.
//!
//! ## Transport over a single stdio pipe pair
//!
//! The wire design (§4.3) uses *two* logical lanes — a control lane and a data
//! lane — each a `Server.Stream`. Over an `ssh -- ghoztty-agent` invocation there
//! is only ONE stdin/stdout pipe pair, so this entry point multiplexes both lanes
//! onto it: a single inbound reader (`StdioMux`) demuxes each frame to the control
//! or data logical stream by frame type (DATA → data lane, everything else →
//! control lane), and both outbound streams serialize their writes onto stdout
//! under one mutex. The `Server`'s two reader threads then consume their lanes
//! unchanged. (A future ssh transport gives each lane its own ssh channel; the
//! `Server` is identical either way.)
//!
//! ## Deferred (this increment)
//!   - Daemonization / single-instance / detach from sshd (§4.1).
//!   - Real grid-model snapshot for resync (§7.3) — `snapshot_at_offset` stays the
//!     current outbound offset.
//!   - Idle-TTL GC, RPC, tunnels, Windows ConPTY.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const server = @import("server.zig");
const pty_child = @import("pty_child.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // The transfer encoding is fixed at construction (the client pins it in HELLO).
    // Default to raw; a CLI/env override is a later concern. We honor a
    // `GHOZTTY_AGENT_ENCODING` env hint to make the smoke test deterministic.
    const encoding = encodingFromEnv(alloc);

    try run(alloc, encoding);
}

fn encodingFromEnv(alloc: Allocator) protocol.TransferEncoding {
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_ENCODING") catch return .raw;
    defer alloc.free(v);
    if (std.ascii.eqlIgnoreCase(v, "cobs")) return .cobs;
    if (std.ascii.eqlIgnoreCase(v, "base64")) return .base64;
    return .raw;
}

/// Construct the mux + server over stdin/stdout and run until EOF.
pub fn run(alloc: Allocator, encoding: protocol.TransferEncoding) !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var mux = try StdioMux.create(alloc, stdin, stdout, encoding);
    defer mux.destroy();

    var spawner = try pty_child.PtySpawner.init(alloc);
    defer spawner.deinit();

    const srv = try server.Server.create(
        alloc,
        mux.controlStream(),
        mux.dataStream(),
        spawner.spawner(),
        .{ .encoding = encoding },
    );
    defer srv.destroy(alloc);

    try srv.start();

    // Pump stdin → lane fifos until EOF. This blocks in the calling thread.
    mux.pumpInput();

    // stdin hit EOF: the client hung up. Tear the server down (joins its threads).
    srv.shutdown();
}

// -----------------------------------------------------------------------------
// StdioMux — one stdin/stdout pipe pair ↔ two logical Server.Streams
// -----------------------------------------------------------------------------

/// Multiplexes the control + data logical lanes onto a single stdin/stdout pair.
///
/// Inbound: `pumpInput` reads stdin, parses whole frames with a `protocol.Reader`,
/// and pushes each frame's *re-encoded wire bytes* into the control or data lane
/// fifo (by frame type). The `Server`'s two reader threads then read+parse their
/// lane exactly as if it were a dedicated ssh channel.
///
/// Outbound: both logical streams write to stdout under `out_mutex` so frames are
/// never interleaved mid-bytes.
const StdioMux = struct {
    alloc: Allocator,
    encoding: protocol.TransferEncoding,
    stdin: std.fs.File,
    stdout: std.fs.File,

    out_mutex: std.Thread.Mutex = .{},

    control_fifo: Fifo,
    data_fifo: Fifo,

    fn create(
        alloc: Allocator,
        stdin: std.fs.File,
        stdout: std.fs.File,
        encoding: protocol.TransferEncoding,
    ) !*StdioMux {
        const self = try alloc.create(StdioMux);
        self.* = .{
            .alloc = alloc,
            .encoding = encoding,
            .stdin = stdin,
            .stdout = stdout,
            .control_fifo = Fifo.init(alloc),
            .data_fifo = Fifo.init(alloc),
        };
        return self;
    }

    fn destroy(self: *StdioMux) void {
        self.control_fifo.deinit();
        self.data_fifo.deinit();
        self.alloc.destroy(self);
    }

    fn controlStream(self: *StdioMux) server.Stream {
        return .{ .ctx = self, .vtable = &control_vtable };
    }
    fn dataStream(self: *StdioMux) server.Stream {
        return .{ .ctx = self, .vtable = &data_vtable };
    }

    const control_vtable: server.Stream.VTable = .{
        .read = controlRead,
        .write = stdoutWrite,
        .close = closeAll,
    };
    const data_vtable: server.Stream.VTable = .{
        .read = dataRead,
        .write = stdoutWrite,
        .close = closeAll,
    };

    fn controlRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *StdioMux = @ptrCast(@alignCast(ctx));
        return self.control_fifo.read(buf);
    }
    fn dataRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *StdioMux = @ptrCast(@alignCast(ctx));
        return self.data_fifo.read(buf);
    }
    fn stdoutWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *StdioMux = @ptrCast(@alignCast(ctx));
        self.out_mutex.lock();
        defer self.out_mutex.unlock();
        try self.stdout.writeAll(bytes);
        return bytes.len;
    }
    fn closeAll(ctx: *anyopaque) void {
        const self: *StdioMux = @ptrCast(@alignCast(ctx));
        self.control_fifo.close();
        self.data_fifo.close();
    }

    /// Read stdin, demux frames to the lane fifos, until EOF. Re-emits each frame
    /// (verbatim wire bytes) into its lane so the Server's per-lane Reader parses
    /// it identically.
    fn pumpInput(self: *StdioMux) void {
        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [64 * 1024]u8 = undefined;
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);

        while (true) {
            // Drain any whole frames currently buffered.
            while (reader.next() catch break) |frame| {
                wire.clearRetainingCapacity();
                protocol.writeFrame(self.alloc, self.encoding, frame, &wire) catch continue;
                const lane: *Fifo = if (frame.type == .data)
                    &self.data_fifo
                else
                    &self.control_fifo;
                _ = lane.write(wire.items) catch {};
            }
            const n = self.stdin.read(&scratch) catch break;
            if (n == 0) break; // EOF
            reader.push(scratch[0..n]) catch break;
        }
        // EOF: unblock both lanes' readers.
        self.control_fifo.close();
        self.data_fifo.close();
    }
};

/// A thread-safe blocking byte fifo (one producer = `pumpInput`, one consumer =
/// the Server lane reader). Mirrors the loopback fifo in `server.zig`'s tests.
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

test {
    std.testing.refAllDecls(@This());
}
