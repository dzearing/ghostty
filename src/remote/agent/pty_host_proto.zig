//! Wire protocol for the per-session ConPTY **holder** process (T904, increment
//! 1 of the T705 non-destructive agent upgrade — design:
//! `docs/design/agent-nondestructive-handoff.md`).
//!
//! This module is **pure and dependency-free** (only `std`) so every
//! decision-shaped piece — framing, payload encode/decode, the bounded replay
//! buffer, the replay-start arithmetic — runs in the `test-agent` lane on any
//! host. The Windows-only runtime around it lives in `pty_host.zig`.
//!
//! ## The channel
//!
//! One holder serves ONE owner at a time over an owner-only-DACL named pipe
//! (`\\.\pipe\ghoztty-pty-host[-debug]-<user>-<session-id>`). The conversation:
//!
//!   1. Holder → owner: `HELLO` — protocol version, holder build stamp, session
//!      id, the shell pid, the retained replay window `[start, end)`, and (if
//!      the shell already exited) the exit code. Always the first frame.
//!   2. Owner → holder: `ATTACH` — protocol version + the last output offset the
//!      owner has already seen (`ack`). The holder replays retained output from
//!      `replayStart(ack, start, end)` and then streams live.
//!   3. Steady state: `OUTPUT` (holder → owner, offset-tagged), `ACK`
//!      (owner → holder, releases replay bytes), `INPUT`/`RESIZE`/`SIGNAL`
//!      (owner → holder), `EXIT` (holder → owner, shell exit code),
//!      `SHUTDOWN` (owner → holder: terminate the shell and exit).
//!
//! ## Offsets and replay
//!
//! Output bytes carry ABSOLUTE offsets: the first byte the shell ever produced
//! is offset 0 and `end` only ever grows. The holder retains un-acked output in
//! a bounded ring (`ReplayBuffer`); when the ring overflows, the OLDEST bytes
//! are dropped (`start` advances) — a reconnecting owner whose `ack` is older
//! than `start` gap-fills from `start` and can tell exactly how many bytes were
//! lost (`start - ack`). Same shape as the app⇄agent gap-fill.
//!
//! ## Evolution rules (the agent contract's, in miniature)
//!
//! The holder outlives the agent that spawned it BY DESIGN — a reconnecting
//! owner is routinely a different build. So: `proto_version` bumps ONLY on a
//! breaking change (equality checked in HELLO/ATTACH; mismatch drops the
//! connection); everything else evolves additively — decoders IGNORE trailing
//! payload bytes they don't know (a newer peer may append fields), and both
//! ends IGNORE unknown frame types entirely.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bumped only for a BREAKING change. Compared for equality in HELLO (owner
/// checks) and ATTACH (holder checks); a mismatch drops the connection.
pub const proto_version: u16 = 1;

/// Frame header: `len u32 BE | type u8`. `len` counts the PAYLOAD only.
pub const header_len: usize = 5;

/// Hard cap on a single frame's payload. Output is chunked well below this;
/// the cap exists so a corrupt/hostile `len` can never trigger an unbounded
/// allocation.
pub const max_payload_len: u32 = 1024 * 1024;

/// Frame types. Unknown values are skipped by both ends (additive evolution).
pub const FrameType = enum(u8) {
    hello = 0x01,
    attach = 0x02,
    output = 0x03,
    ack = 0x04,
    input = 0x05,
    resize = 0x06,
    signal = 0x07,
    exit = 0x08,
    shutdown = 0x09,
    _,
};

pub const Error = error{
    /// Payload too short / structurally invalid for its declared type.
    Malformed,
    /// A declared frame length exceeds `max_payload_len`.
    FrameTooLong,
};

// =============================================================================
// Payload structs + encode/decode
// =============================================================================
//
// All integers are big-endian (house style: `src/remote/protocol.zig`).
// Decoders borrow slices from the payload they were handed — valid only as
// long as that buffer. Decoders IGNORE trailing bytes beyond what they parse
// (a newer peer may have appended fields); encoders write exactly v1's layout.

/// `HELLO` (holder → owner, first frame on every connection).
pub const Hello = struct {
    version: u16,
    /// The shell already exited; `exit_code` is meaningful.
    exited: bool,
    exit_code: i64,
    /// Win32 pid of the spawned shell (0 if unknown).
    shell_pid: u32,
    /// Oldest retained output offset (replay begins at or after this).
    start: u64,
    /// Next output offset to be produced (== total bytes ever produced).
    end: u64,
    /// Holder build stamp (the agent build stamp of the binary serving).
    stamp: []const u8,
    session_id: []const u8,

    pub fn encode(self: Hello, alloc: Allocator) ![]u8 {
        if (self.stamp.len > std.math.maxInt(u16)) return Error.Malformed;
        if (self.session_id.len > std.math.maxInt(u16)) return Error.Malformed;
        const fixed = 2 + 1 + 8 + 4 + 8 + 8;
        const n = fixed + 2 + self.stamp.len + 2 + self.session_id.len;
        const buf = try alloc.alloc(u8, n);
        var w: Writer = .{ .buf = buf };
        w.int(u16, self.version);
        w.int(u8, if (self.exited) 1 else 0);
        w.int(i64, self.exit_code);
        w.int(u32, self.shell_pid);
        w.int(u64, self.start);
        w.int(u64, self.end);
        w.str(self.stamp);
        w.str(self.session_id);
        std.debug.assert(w.pos == n);
        return buf;
    }

    pub fn decode(payload: []const u8) Error!Hello {
        var r: Reader = .{ .buf = payload };
        const version = try r.int(u16);
        const flags = try r.int(u8);
        const exit_code = try r.int(i64);
        const shell_pid = try r.int(u32);
        const start = try r.int(u64);
        const end = try r.int(u64);
        const stamp = try r.str();
        const session_id = try r.str();
        return .{
            .version = version,
            .exited = (flags & 1) != 0,
            .exit_code = exit_code,
            .shell_pid = shell_pid,
            .start = start,
            .end = end,
            .stamp = stamp,
            .session_id = session_id,
        };
    }
};

/// `ATTACH` (owner → holder, its first frame).
pub const Attach = struct {
    version: u16,
    /// Last output offset the owner already has; replay starts at
    /// `replayStart(ack, start, end)`.
    ack: u64,

    pub fn encode(self: Attach, buf: *[10]u8) []u8 {
        var w: Writer = .{ .buf = buf };
        w.int(u16, self.version);
        w.int(u64, self.ack);
        return buf[0..w.pos];
    }

    pub fn decode(payload: []const u8) Error!Attach {
        var r: Reader = .{ .buf = payload };
        return .{ .version = try r.int(u16), .ack = try r.int(u64) };
    }
};

/// `OUTPUT` (holder → owner): `offset u64 | bytes`. `offset` is the absolute
/// stream offset of the FIRST byte in this frame.
pub const Output = struct {
    offset: u64,
    bytes: []const u8,

    /// Encoded as header-only into `buf`; the caller writes `bytes` after it
    /// (avoids copying pty output through an allocation).
    pub fn encodeHeader(self: Output, buf: *[8]u8) void {
        std.mem.writeInt(u64, buf, self.offset, .big);
    }

    pub fn decode(payload: []const u8) Error!Output {
        var r: Reader = .{ .buf = payload };
        const offset = try r.int(u64);
        return .{ .offset = offset, .bytes = payload[r.pos..] };
    }
};

/// `ACK` (owner → holder): retained replay bytes below `offset` may be freed.
pub const Ack = struct {
    offset: u64,

    pub fn encode(self: Ack, buf: *[8]u8) []u8 {
        std.mem.writeInt(u64, buf, self.offset, .big);
        return buf[0..8];
    }

    pub fn decode(payload: []const u8) Error!Ack {
        var r: Reader = .{ .buf = payload };
        return .{ .offset = try r.int(u64) };
    }
};

/// `RESIZE` (owner → holder).
pub const Resize = struct {
    rows: u16,
    cols: u16,
    px_w: u16 = 0,
    px_h: u16 = 0,

    pub fn encode(self: Resize, buf: *[8]u8) []u8 {
        var w: Writer = .{ .buf = buf };
        w.int(u16, self.rows);
        w.int(u16, self.cols);
        w.int(u16, self.px_w);
        w.int(u16, self.px_h);
        return buf[0..w.pos];
    }

    pub fn decode(payload: []const u8) Error!Resize {
        var r: Reader = .{ .buf = payload };
        return .{
            .rows = try r.int(u16),
            .cols = try r.int(u16),
            .px_w = try r.int(u16),
            .px_h = try r.int(u16),
        };
    }
};

/// `EXIT` (holder → owner): the shell exited with `code`.
pub const Exit = struct {
    code: i64,

    pub fn encode(self: Exit, buf: *[8]u8) []u8 {
        std.mem.writeInt(i64, buf, self.code, .big);
        return buf[0..8];
    }

    pub fn decode(payload: []const u8) Error!Exit {
        var r: Reader = .{ .buf = payload };
        return .{ .code = try r.int(i64) };
    }
};

// `INPUT` and `SIGNAL` payloads are raw bytes (keystrokes / a POSIX-style
// signal name like "INT" or "KILL" — the holder maps it exactly like
// `PtyChild.signal`). `SHUTDOWN` has an empty payload.

// =============================================================================
// Frame accumulation (streaming reads → whole frames)
// =============================================================================

/// One parsed frame. `payload` borrows the accumulator's buffer: valid until
/// the next `push`.
pub const Frame = struct {
    type: FrameType,
    payload: []const u8,
};

/// Reassembles frames from arbitrary read chunks. Not thread-safe (one per
/// connection reader). `push` appends raw bytes; `next` pops the next complete
/// frame or null. A declared payload length over `max_payload_len` errors —
/// the connection is corrupt and must be dropped.
pub const Accum = struct {
    alloc: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Consumed prefix of `buf` (compacted on push).
    pos: usize = 0,

    pub fn init(alloc: Allocator) Accum {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Accum) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn push(self: *Accum, bytes: []const u8) !void {
        // Compact: drop the consumed prefix so the buffer stays bounded by
        // (one partial frame + new bytes). Invalidates prior Frame payloads.
        if (self.pos > 0) {
            const remaining = self.buf.items.len - self.pos;
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.pos..]);
            self.buf.shrinkRetainingCapacity(remaining);
            self.pos = 0;
        }
        try self.buf.appendSlice(self.alloc, bytes);
    }

    pub fn next(self: *Accum) Error!?Frame {
        const avail = self.buf.items[self.pos..];
        if (avail.len < header_len) return null;
        const len = std.mem.readInt(u32, avail[0..4], .big);
        if (len > max_payload_len) return Error.FrameTooLong;
        if (avail.len < header_len + len) return null;
        const frame: Frame = .{
            .type = @enumFromInt(avail[4]),
            .payload = avail[header_len .. header_len + len],
        };
        self.pos += header_len + len;
        return frame;
    }
};

/// Encode a frame header for a payload of `len` bytes.
pub fn frameHeader(t: FrameType, len: u32, buf: *[header_len]u8) void {
    std.mem.writeInt(u32, buf[0..4], len, .big);
    buf[4] = @intFromEnum(t);
}

// =============================================================================
// Replay buffer
// =============================================================================

/// Bounded ring of the most recent output bytes, addressed by ABSOLUTE stream
/// offset. `append` never blocks and never fails once constructed: when the
/// ring is full the OLDEST bytes are dropped (`start` advances) — the pty
/// reader must never stall on a slow/absent owner. `ackTo` releases bytes the
/// owner has confirmed. Not thread-safe (callers hold the holder's state lock).
pub const ReplayBuffer = struct {
    data: []u8,
    /// Oldest retained offset.
    start: u64 = 0,
    /// Next offset to be assigned (== total bytes ever appended).
    end: u64 = 0,

    pub fn init(alloc: Allocator, capacity: usize) !ReplayBuffer {
        std.debug.assert(capacity > 0);
        return .{ .data = try alloc.alloc(u8, capacity) };
    }

    pub fn deinit(self: *ReplayBuffer, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }

    /// Retained byte count.
    pub fn len(self: *const ReplayBuffer) usize {
        return @intCast(self.end - self.start);
    }

    pub fn append(self: *ReplayBuffer, bytes: []const u8) void {
        const cap = self.data.len;
        // A chunk at least as large as the ring replaces its entire contents;
        // only the last `cap` bytes are retainable.
        var src = bytes;
        if (src.len >= cap) {
            self.end += src.len - cap;
            src = src[src.len - cap ..];
            self.start = self.end;
        }
        var pos: usize = @intCast(self.end % cap);
        for (src) |b| {
            self.data[pos] = b;
            pos = if (pos + 1 == cap) 0 else pos + 1;
        }
        self.end += src.len;
        if (self.end - self.start > cap) self.start = self.end - cap;
    }

    /// Owner confirmed receipt through `offset`: drop retained bytes below it.
    /// Clamped — a stale or overshooting ack can never corrupt the window.
    pub fn ackTo(self: *ReplayBuffer, offset: u64) void {
        const clamped = @min(offset, self.end);
        if (clamped > self.start) self.start = clamped;
    }

    pub const Slices = struct {
        first: []const u8,
        second: []const u8,

        pub fn total(self: Slices) usize {
            return self.first.len + self.second.len;
        }
    };

    /// Retained bytes from `offset` (clamped into `[start, end]`) to `end`,
    /// as up to two ring slices. Valid until the next `append`/`ackTo`.
    pub fn from(self: *const ReplayBuffer, offset: u64) Slices {
        const cap = self.data.len;
        const lo = @min(@max(offset, self.start), self.end);
        const n: usize = @intCast(self.end - lo);
        if (n == 0) return .{ .first = &.{}, .second = &.{} };
        const p: usize = @intCast(lo % cap);
        const first_n = @min(n, cap - p);
        return .{
            .first = self.data[p .. p + first_n],
            .second = self.data[0 .. n - first_n],
        };
    }
};

/// Where replay begins for an owner that has seen everything up to `ack`,
/// against a holder retaining `[start, end)`. Bytes in `[ack, result)` — if
/// any — were dropped by the bounded ring and are unrecoverable.
pub fn replayStart(ack: u64, start: u64, end: u64) u64 {
    return @min(@max(ack, start), end);
}

/// Session ids become pipe-name components, so they are restricted to a safe
/// charset: ASCII alphanumerics plus `.`, `_`, `-`. Never empty, bounded.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

// =============================================================================
// Little BE cursor helpers
// =============================================================================

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn int(self: *Writer, comptime T: type, v: T) void {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        std.mem.writeInt(T, self.buf[self.pos..][0..n], v, .big);
        self.pos += n;
    }

    fn str(self: *Writer, s: []const u8) void {
        self.int(u16, @intCast(s.len));
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn int(self: *Reader, comptime T: type) Error!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        if (self.buf.len - self.pos < n) return Error.Malformed;
        const v = std.mem.readInt(T, self.buf[self.pos..][0..n], .big);
        self.pos += n;
        return v;
    }

    fn str(self: *Reader) Error![]const u8 {
        const n = try self.int(u16);
        if (self.buf.len - self.pos < n) return Error.Malformed;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "hello: encode/decode round-trip, exited flag, trailing bytes ignored" {
    const h: Hello = .{
        .version = 1,
        .exited = true,
        .exit_code = -7,
        .shell_pid = 4242,
        .start = 100,
        .end = 250,
        .stamp = "20260816-abcdef0",
        .session_id = "sess-01",
    };
    const enc = try h.encode(testing.allocator);
    defer testing.allocator.free(enc);

    const dec = try Hello.decode(enc);
    try testing.expectEqual(@as(u16, 1), dec.version);
    try testing.expect(dec.exited);
    try testing.expectEqual(@as(i64, -7), dec.exit_code);
    try testing.expectEqual(@as(u32, 4242), dec.shell_pid);
    try testing.expectEqual(@as(u64, 100), dec.start);
    try testing.expectEqual(@as(u64, 250), dec.end);
    try testing.expectEqualStrings("20260816-abcdef0", dec.stamp);
    try testing.expectEqualStrings("sess-01", dec.session_id);

    // A NEWER holder may append fields: extra trailing bytes must decode fine.
    const padded = try std.mem.concat(testing.allocator, u8, &.{ enc, "future-fields" });
    defer testing.allocator.free(padded);
    const dec2 = try Hello.decode(padded);
    try testing.expectEqualStrings("sess-01", dec2.session_id);

    // Truncation anywhere is Malformed, never a crash.
    var i: usize = 0;
    while (i < enc.len) : (i += 1) {
        try testing.expectError(Error.Malformed, Hello.decode(enc[0..i]));
    }
}

test "attach/ack/resize/exit/output: fixed-layout round-trips" {
    var abuf: [10]u8 = undefined;
    const a = try Attach.decode(Attach.encode(.{ .version = 1, .ack = 999 }, &abuf));
    try testing.expectEqual(@as(u64, 999), a.ack);

    var kbuf: [8]u8 = undefined;
    const k = try Ack.decode(Ack.encode(.{ .offset = 12345 }, &kbuf));
    try testing.expectEqual(@as(u64, 12345), k.offset);

    var rbuf: [8]u8 = undefined;
    const r = try Resize.decode(Resize.encode(.{ .rows = 40, .cols = 100, .px_w = 800, .px_h = 600 }, &rbuf));
    try testing.expectEqual(@as(u16, 40), r.rows);
    try testing.expectEqual(@as(u16, 100), r.cols);
    try testing.expectEqual(@as(u16, 800), r.px_w);
    try testing.expectEqual(@as(u16, 600), r.px_h);

    var ebuf: [8]u8 = undefined;
    const e = try Exit.decode(Exit.encode(.{ .code = 130 }, &ebuf));
    try testing.expectEqual(@as(i64, 130), e.code);

    var obuf: [8]u8 = undefined;
    Output.encodeHeader(.{ .offset = 77, .bytes = &.{} }, &obuf);
    const payload = try std.mem.concat(testing.allocator, u8, &.{ &obuf, "hello" });
    defer testing.allocator.free(payload);
    const o = try Output.decode(payload);
    try testing.expectEqual(@as(u64, 77), o.offset);
    try testing.expectEqualStrings("hello", o.bytes);
}

test "accum: frames reassemble across arbitrary chunk boundaries" {
    var acc = Accum.init(testing.allocator);
    defer acc.deinit();

    // Two frames: INPUT "abc", SHUTDOWN (empty payload).
    var hdr: [header_len]u8 = undefined;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);
    frameHeader(.input, 3, &hdr);
    try wire.appendSlice(testing.allocator, &hdr);
    try wire.appendSlice(testing.allocator, "abc");
    frameHeader(.shutdown, 0, &hdr);
    try wire.appendSlice(testing.allocator, &hdr);

    // Push a byte at a time; collect frames as they complete.
    var got: usize = 0;
    for (wire.items) |b| {
        try acc.push(&.{b});
        while (try acc.next()) |f| {
            switch (got) {
                0 => {
                    try testing.expectEqual(FrameType.input, f.type);
                    try testing.expectEqualStrings("abc", f.payload);
                },
                1 => {
                    try testing.expectEqual(FrameType.shutdown, f.type);
                    try testing.expectEqual(@as(usize, 0), f.payload.len);
                },
                else => return error.TestUnexpectedResult,
            }
            got += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), got);
}

test "accum: unknown frame type is delivered (caller skips), oversize len errors" {
    var acc = Accum.init(testing.allocator);
    defer acc.deinit();

    var hdr: [header_len]u8 = undefined;
    frameHeader(@enumFromInt(0xEE), 2, &hdr);
    try acc.push(&hdr);
    try acc.push("zz");
    const f = (try acc.next()).?;
    try testing.expectEqual(@as(u8, 0xEE), @intFromEnum(f.type));

    // A hostile length: error, never an allocation attempt.
    std.mem.writeInt(u32, hdr[0..4], max_payload_len + 1, .big);
    hdr[4] = @intFromEnum(FrameType.input);
    try acc.push(&hdr);
    try testing.expectError(Error.FrameTooLong, acc.next());
}

test "replay buffer: append/ack/from, wrap, and overflow drops oldest" {
    var rb = try ReplayBuffer.init(testing.allocator, 8);
    defer rb.deinit(testing.allocator);

    rb.append("abcde");
    try testing.expectEqual(@as(u64, 0), rb.start);
    try testing.expectEqual(@as(u64, 5), rb.end);

    // Overflow: 5 + 6 > 8 → oldest 3 dropped, window is [3, 11).
    rb.append("fghijk");
    try testing.expectEqual(@as(u64, 3), rb.start);
    try testing.expectEqual(@as(u64, 11), rb.end);

    // Full window read (wraps the ring internally).
    var out: [16]u8 = undefined;
    const s = rb.from(0); // stale offset clamps up to start
    @memcpy(out[0..s.first.len], s.first);
    @memcpy(out[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualStrings("defghijk", out[0..s.total()]);

    // Partial read from mid-window.
    const s2 = rb.from(9);
    var out2: [16]u8 = undefined;
    @memcpy(out2[0..s2.first.len], s2.first);
    @memcpy(out2[s2.first.len..][0..s2.second.len], s2.second);
    try testing.expectEqualStrings("jk", out2[0..s2.total()]);

    // Ack releases; overshoot clamps.
    rb.ackTo(9);
    try testing.expectEqual(@as(u64, 9), rb.start);
    rb.ackTo(3); // stale ack: no-op
    try testing.expectEqual(@as(u64, 9), rb.start);
    rb.ackTo(1000);
    try testing.expectEqual(@as(u64, 11), rb.start);
    try testing.expectEqual(@as(usize, 0), rb.len());
}

test "replay buffer: an append larger than the ring keeps only the tail" {
    var rb = try ReplayBuffer.init(testing.allocator, 4);
    defer rb.deinit(testing.allocator);

    rb.append("0123456789"); // 10 bytes into a 4-byte ring
    try testing.expectEqual(@as(u64, 10), rb.end);
    try testing.expectEqual(@as(u64, 6), rb.start);
    const s = rb.from(0);
    var out: [8]u8 = undefined;
    @memcpy(out[0..s.first.len], s.first);
    @memcpy(out[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualStrings("6789", out[0..s.total()]);
}

test "replayStart: clamps into the retained window" {
    try testing.expectEqual(@as(u64, 50), replayStart(0, 50, 100)); // gap: bytes lost
    try testing.expectEqual(@as(u64, 75), replayStart(75, 50, 100)); // in-window resume
    try testing.expectEqual(@as(u64, 100), replayStart(400, 50, 100)); // overshoot clamps
    try testing.expectEqual(@as(u64, 0), replayStart(0, 0, 0)); // empty stream
}

test "validSessionId: charset and bounds" {
    try testing.expect(validSessionId("abc-123_X.z"));
    try testing.expect(!validSessionId(""));
    try testing.expect(!validSessionId("has space"));
    try testing.expect(!validSessionId("back\\slash"));
    try testing.expect(!validSessionId("a" ** 129));
}
