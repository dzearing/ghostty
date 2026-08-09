//! A PNG encoder (T637), for turning a clipboard bitmap into the file a
//! feedback report carries.
//!
//! Pure — pixels in, bytes out, no OS imports — so it asserts in the
//! `-Dapp-runtime=none` lane, which is the whole reason it exists in this shape.
//!
//! ## Why not GDI+, which is already linked here
//!
//! `gdiplus_decode.zig` decodes with GDI+ because there was no alternative: the
//! bytes arrive as an encoded image in an `IStream` and something has to parse
//! them. Encoding is the other direction and has no such constraint — the
//! pixels are already in hand, and PNG's encoder is a deflate stream plus four
//! chunk headers. Doing it here buys three things GDI+ cannot:
//!
//! - it is testable in the none lane, against a decoder written in the test, so
//!   "the file is a valid PNG carrying these exact pixels" is asserted rather
//!   than assumed;
//! - no `GdiplusStartup`, no encoder-CLSID lookup, no `IStream` round trip, and
//!   no COM on the paste path;
//! - deterministic output, so a test can compare bytes.
//!
//! And it needs no new vendored dependency, which is the same reasoning the git
//! diff pane used when it declined to vendor a diff renderer.
//!
//! ## Why the deflate is hand-written and not `std.compress.flate`
//!
//! Because zig 0.15.2 does not have one. `std.compress.flate.Compress` looks
//! like a compressor and is a stub: its `drain` ends in `@panic("TODO")`, and
//! the branch before that returns 0 when the buffer holds less than a window
//! plus lookahead — which makes `end()`'s `while (c.writer.end != 0)` an
//! INFINITE LOOP for every input smaller than ~32 KB. It does not fail, it
//! spins, which is how it cost a test lane 20 minutes of 100% CPU with no
//! output before it was caught. `std.compress.flate.Decompress` IS implemented,
//! so it is what the tests below inflate with — the encoder is asserted against
//! a decoder nobody here wrote.
//!
//! What is implemented here is fixed-Huffman deflate (RFC 1951 §3.2.6) with a
//! single-candidate hash match finder. Deliberately the simple end of the
//! design space: the Huffman tables are constants the spec prints, so there is
//! no tree building to get wrong, and PNG-filtered image data is dominated by
//! runs of zeroes that even a one-candidate finder turns into long matches.
//!
//! ## Scope
//!
//! 8-bit RGB and RGBA, non-interlaced — the two shapes a screen capture or a
//! clipboard bitmap ever arrives in once GDI has normalised it. Palettes,
//! 16-bit channels and interlacing are deliberately absent: nothing here
//! produces them, and an encoder that accepts inputs no caller has is untested
//! code by construction.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const Channels = enum(u8) {
    /// Three bytes per pixel: R, G, B.
    rgb = 3,
    /// Four bytes per pixel: R, G, B, A.
    rgba = 4,

    fn colorType(self: Channels) u8 {
        return switch (self) {
            .rgb => 2,
            .rgba => 6,
        };
    }

    pub fn count(self: Channels) usize {
        return @intFromEnum(self);
    }
};

pub const Pixels = struct {
    /// Tightly packed, TOP-DOWN, `width * height * channels` bytes.
    data: []const u8,
    width: u32,
    height: u32,
    channels: Channels = .rgba,
};

pub const Error = error{
    /// A zero dimension, or `data` that is not exactly the size the dimensions
    /// describe. Refused rather than padded: a short buffer is a caller bug,
    /// and encoding whatever happened to follow it in memory is how a
    /// screenshot ends up carrying somebody's heap.
    BadPixels,
};

/// Encode one image. Caller frees.
pub fn encode(alloc: Allocator, px: Pixels) ![]u8 {
    const bpp = px.channels.count();
    if (px.width == 0 or px.height == 0) return Error.BadPixels;
    const expect_len = @as(usize, px.width) * @as(usize, px.height) * bpp;
    if (px.data.len != expect_len) return Error.BadPixels;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &signature);

    {
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], px.width, .big);
        std.mem.writeInt(u32, ihdr[4..8], px.height, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = px.channels.colorType();
        ihdr[10] = 0; // compression: deflate, the only value there is
        ihdr[11] = 0; // filter method: the adaptive five, likewise
        ihdr[12] = 0; // not interlaced
        try appendChunk(alloc, &out, "IHDR", &ihdr);
    }

    const filtered = try filterRows(alloc, px);
    defer alloc.free(filtered);

    const idat = try deflate(alloc, filtered);
    defer alloc.free(idat);
    try appendChunk(alloc, &out, "IDAT", idat);

    try appendChunk(alloc, &out, "IEND", "");
    return out.toOwnedSlice(alloc);
}

/// `length | type | data | crc`, where the CRC covers the type AND the data —
/// a detail that is easy to get wrong in exactly one direction, so it is
/// written once here.
fn appendChunk(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tag: *const [4]u8,
    data: []const u8,
) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(alloc, &len);
    try out.appendSlice(alloc, tag);
    try out.appendSlice(alloc, data);

    var crc: std.hash.Crc32 = .init();
    crc.update(tag);
    crc.update(data);
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, crc.final(), .big);
    try out.appendSlice(alloc, &be);
}

// -----------------------------------------------------------------------------
// Filtering
// -----------------------------------------------------------------------------

const Filter = enum(u8) { none = 0, sub = 1, up = 2, average = 3, paeth = 4 };

/// Every row prefixed with the filter type it was encoded under.
///
/// The filter is chosen per row by the minimum-sum-of-absolute-differences
/// heuristic the PNG spec recommends: whichever candidate leaves the smallest
/// total magnitude compresses best, because deflate is a match finder and small
/// residuals repeat. Filtering is not optional in practice — a screenshot's
/// rows are nearly identical to the one above, and `up` turns that into a run
/// of zeroes.
fn filterRows(alloc: Allocator, px: Pixels) ![]u8 {
    const bpp = px.channels.count();
    const stride = @as(usize, px.width) * bpp;
    const rows = @as(usize, px.height);

    const out = try alloc.alloc(u8, rows * (stride + 1));
    errdefer alloc.free(out);

    // One scratch row per candidate, reused for every line.
    const scratch = try alloc.alloc(u8, stride * 5);
    defer alloc.free(scratch);

    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const row = px.data[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else px.data[(y - 1) * stride ..][0..stride];

        var best: Filter = .none;
        var best_score: u64 = std.math.maxInt(u64);
        var best_slice: []const u8 = row;

        for ([_]Filter{ .none, .sub, .up, .average, .paeth }) |f| {
            const cand = scratch[@as(usize, @intFromEnum(f)) * stride ..][0..stride];
            applyFilter(f, row, prev, bpp, cand);
            const score = absSum(cand);
            if (score < best_score) {
                best_score = score;
                best = f;
                best_slice = cand;
            }
        }

        out[y * (stride + 1)] = @intFromEnum(best);
        @memcpy(out[y * (stride + 1) + 1 ..][0..stride], best_slice);
    }
    return out;
}

fn applyFilter(
    f: Filter,
    row: []const u8,
    prev: ?[]const u8,
    bpp: usize,
    out: []u8,
) void {
    for (row, 0..) |cur, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b: u8 = if (prev) |p| p[i] else 0;
        const c: u8 = if (prev) |p| (if (i >= bpp) p[i - bpp] else 0) else 0;
        out[i] = switch (f) {
            .none => cur,
            .sub => cur -% a,
            .up => cur -% b,
            // The spec's `floor((a+b)/2)`, computed in a width that cannot
            // overflow before the shift.
            .average => cur -% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) / 2)),
            .paeth => cur -% paeth(a, b, c),
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    // Ties go to `a`, then `b` — the order is part of the spec, not a
    // preference, because the decoder makes the same choice.
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Sum of each byte read as a SIGNED residual, which is what the heuristic
/// wants: 0xFF is a difference of one, not of 255.
fn absSum(bytes: []const u8) u64 {
    var total: u64 = 0;
    for (bytes) |v| {
        const s: i8 = @bitCast(v);
        total += @abs(@as(i32, s));
    }
    return total;
}

// -----------------------------------------------------------------------------
// Deflate
// -----------------------------------------------------------------------------

/// A zlib stream (RFC 1950), which is exactly what `IDAT` holds: a two-byte
/// header, one fixed-Huffman deflate block, and the Adler-32 of the input.
fn deflate(alloc: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    // CMF = deflate, 32 KB window; FLG picked so the pair is a multiple of 31,
    // which is the header's own check.
    try out.append(alloc, 0x78);
    try out.append(alloc, 0x01);

    var bits: BitWriter = .{ .alloc = alloc, .out = &out };
    try bits.writeBits(1, 1); // BFINAL: one block for the whole image
    try bits.writeBits(1, 2); // BTYPE 01: fixed Huffman
    try compressFixed(&bits, raw);
    try bits.symbol(end_of_block);
    try bits.flush();

    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(raw), .big);
    try out.appendSlice(alloc, &adler);
    return out.toOwnedSlice(alloc);
}

/// Deflate packs bits into bytes LEAST-significant first, while a Huffman code
/// is defined most-significant first. Both live here so no call site has to
/// remember which is which.
const BitWriter = struct {
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    acc: u32 = 0,
    held: u5 = 0,

    /// `count` bits of `value`, low bit first — how deflate stores every
    /// integer field (block type, extra bits).
    fn writeBits(self: *BitWriter, value: u32, count: u5) !void {
        var v = value;
        var n = count;
        while (n > 0) : (n -= 1) {
            self.acc |= (v & 1) << self.held;
            v >>= 1;
            if (self.held == 7) {
                try self.out.append(self.alloc, @truncate(self.acc));
                self.acc = 0;
                self.held = 0;
            } else self.held += 1;
        }
    }

    /// A Huffman code: its bits high-to-low, each appended by `writeBits`.
    fn writeCode(self: *BitWriter, code: u16, len: u5) !void {
        var i = len;
        while (i > 0) {
            i -= 1;
            try self.writeBits((@as(u32, code) >> i) & 1, 1);
        }
    }

    /// One literal/length symbol in the fixed alphabet.
    fn symbol(self: *BitWriter, sym: u16) !void {
        const c = fixedLiteral(sym);
        try self.writeCode(c.code, c.len);
    }

    /// Pad to a byte boundary — deflate's own rule for ending a stream.
    fn flush(self: *BitWriter) !void {
        if (self.held != 0) try self.out.append(self.alloc, @truncate(self.acc));
        self.acc = 0;
        self.held = 0;
    }
};

const end_of_block: u16 = 256;

const Code = struct { code: u16, len: u5 };

/// RFC 1951 §3.2.6's table, which is why there is no tree to build here.
fn fixedLiteral(sym: u16) Code {
    if (sym < 144) return .{ .code = 0x30 + sym, .len = 8 };
    if (sym < 256) return .{ .code = 0x190 + (sym - 144), .len = 9 };
    if (sym < 280) return .{ .code = sym - 256, .len = 7 };
    return .{ .code = 0xC0 + (sym - 280), .len = 8 };
}

// Length codes 257..285 and distance codes 0..29, base value then extra bits.
const length_base = [_]u16{
    3,  4,  5,  6,  7,  8,  9,  10, 11,  13,
    15, 17, 19, 23, 27, 31, 35, 43, 51,  59,
    67, 83, 99, 115, 131, 163, 195, 227, 258,
};
const length_extra = [_]u5{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
    1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0,
};
const dist_base = [_]u16{
    1,   2,   3,   4,   5,   7,    9,    13,   17,   25,
    33,  49,  65,  97,  129, 193,  257,  385,  513,  769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};
const dist_extra = [_]u5{
    0, 0, 0, 0, 1, 1, 2, 2,  3,  3,
    4, 4, 5, 5, 6, 6, 7, 7,  8,  8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

const min_match: usize = 3;
const max_match: usize = 258;
const max_dist: usize = 32768;

/// One fixed-Huffman block over the whole input.
///
/// The match finder is a 15-bit hash of three bytes to the LAST position that
/// hashed there — one candidate, no chains. That is a deliberate floor rather
/// than a first draft: the input is PNG-filtered image data, whose compressible
/// structure is long runs of equal bytes, and a run is found by its immediately
/// preceding position, which is exactly the candidate a one-deep table holds.
fn compressFixed(bits: *BitWriter, data: []const u8) !void {
    const table_bits = 15;
    const table_len = 1 << table_bits;
    const none = std.math.maxInt(u32);

    // 128 KB of table; on the heap, not on a message-loop thread's stack.
    var head = try bits.alloc.alloc(u32, table_len);
    defer bits.alloc.free(head);
    @memset(head, none);

    var i: usize = 0;
    while (i < data.len) {
        if (i + min_match > data.len) {
            try bits.symbol(data[i]);
            i += 1;
            continue;
        }
        const h = hash3(data[i..][0..3], table_bits);
        const cand = head[h];
        head[h] = @intCast(i);

        var len: usize = 0;
        if (cand != none and i - cand <= max_dist) {
            len = matchLen(data, cand, i);
        }
        if (len < min_match) {
            try bits.symbol(data[i]);
            i += 1;
            continue;
        }

        try emitMatch(bits, len, i - cand);
        // Every position the match covers still has to enter the table, or the
        // next run of the same bytes has nothing to match against.
        var j = i + 1;
        const stop = i + len;
        while (j < stop and j + min_match <= data.len) : (j += 1) {
            head[hash3(data[j..][0..3], table_bits)] = @intCast(j);
        }
        i = stop;
    }
}

fn hash3(b: *const [3]u8, comptime table_bits: u6) usize {
    const v = (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | @as(u32, b[2]);
    return (v *% 0x9E3779B1) >> @intCast(32 - table_bits);
}

fn matchLen(data: []const u8, from: usize, at: usize) usize {
    const limit = @min(max_match, data.len - at);
    var n: usize = 0;
    // `from + n` may run into `at` and beyond — that is LZ77's overlapping
    // match, and it is what turns a run of zeroes into one (len, dist=1) pair
    // rather than eighty of them.
    while (n < limit and data[from + n] == data[at + n]) n += 1;
    return n;
}

fn emitMatch(bits: *BitWriter, len: usize, dist: usize) !void {
    var lc: usize = length_base.len - 1;
    while (lc > 0 and length_base[lc] > len) lc -= 1;
    try bits.symbol(@intCast(257 + lc));
    if (length_extra[lc] != 0) {
        try bits.writeBits(@intCast(len - length_base[lc]), length_extra[lc]);
    }

    var dc: usize = dist_base.len - 1;
    while (dc > 0 and dist_base[dc] > dist) dc -= 1;
    // Distance codes have their own fixed alphabet: five bits, flat.
    try bits.writeCode(@intCast(dc), 5);
    if (dist_extra[dc] != 0) {
        try bits.writeBits(@intCast(dist - dist_base[dc]), dist_extra[dc]);
    }
}

/// RFC 1950's checksum over the UNCOMPRESSED data.
fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

/// Decode a PNG this module produced, all the way back to pixels — the oracle
/// that makes every test here an end-to-end one rather than a check that the
/// encoder agrees with itself. Deliberately strict: it accepts only what
/// `encode` emits, and errors on anything else.
fn decode(alloc: Allocator, png: []const u8) !Pixels {
    try testing.expect(png.len > 8);
    try testing.expectEqualSlices(u8, &signature, png[0..8]);

    var at: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: Channels = .rgba;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(alloc);
    var saw_end = false;

    while (at + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        const tag = png[at + 4 ..][0..4];
        const data = png[at + 8 ..][0..len];

        var crc: std.hash.Crc32 = .init();
        crc.update(tag);
        crc.update(data);
        try testing.expectEqual(
            crc.final(),
            std.mem.readInt(u32, png[at + 8 + len ..][0..4], .big),
        );

        if (std.mem.eql(u8, tag, "IHDR")) {
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            try testing.expectEqual(@as(u8, 8), data[8]);
            channels = switch (data[9]) {
                2 => .rgb,
                6 => .rgba,
                else => return error.UnsupportedColorType,
            };
            try testing.expectEqual(@as(u8, 0), data[12]); // never interlaced
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, tag, "IEND")) {
            saw_end = true;
        }
        at += 12 + len;
    }
    try testing.expect(saw_end);
    try testing.expectEqual(png.len, at);

    // Inflate, then undo the per-row filters.
    const raw = try inflate(alloc, idat.items);
    defer alloc.free(raw);

    const bpp = channels.count();
    const stride = @as(usize, width) * bpp;
    try testing.expectEqual(@as(usize, height) * (stride + 1), raw.len);

    const out = try alloc.alloc(u8, @as(usize, height) * stride);
    errdefer alloc.free(out);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const f: Filter = @enumFromInt(raw[y * (stride + 1)]);
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = out[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else out[(y - 1) * stride ..][0..stride];
        for (src, 0..) |v, i| {
            const a: u8 = if (i >= bpp) dst[i - bpp] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (prev) |p| (if (i >= bpp) p[i - bpp] else 0) else 0;
            dst[i] = switch (f) {
                .none => v,
                .sub => v +% a,
                .up => v +% b,
                .average => v +% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) / 2)),
                .paeth => v +% paeth(a, b, c),
            };
        }
    }
    return .{ .data = out, .width = width, .height = height, .channels = channels };
}

test "encode: a small RGBA image round-trips through a real decode" {
    const alloc = testing.allocator;
    // Deliberately noisy, so no filter is trivially right and the heuristic
    // actually has to pick per row.
    var data: [4 * 3 * 4]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 37 + (i / 5) * 11);

    const png = try encode(alloc, .{ .data = &data, .width = 4, .height = 3 });
    defer alloc.free(png);

    const back = try decode(alloc, png);
    defer alloc.free(back.data);
    try testing.expectEqual(@as(u32, 4), back.width);
    try testing.expectEqual(@as(u32, 3), back.height);
    try testing.expectEqual(Channels.rgba, back.channels);
    try testing.expectEqualSlices(u8, &data, back.data);
}

test "encode: RGB round-trips too, and says so in the IHDR" {
    const alloc = testing.allocator;
    var data: [5 * 2 * 3]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 53);

    const png = try encode(alloc, .{
        .data = &data,
        .width = 5,
        .height = 2,
        .channels = .rgb,
    });
    defer alloc.free(png);
    // Colour type 2 is at a fixed offset: 8 signature + 8 chunk header + 9.
    try testing.expectEqual(@as(u8, 2), png[8 + 8 + 9]);

    const back = try decode(alloc, png);
    defer alloc.free(back.data);
    try testing.expectEqual(Channels.rgb, back.channels);
    try testing.expectEqualSlices(u8, &data, back.data);
}

test "encode: a photograph-sized run of identical rows compresses hard" {
    // The reason filtering is here at all. A screen capture's rows are nearly
    // the row above, which `up` turns into zeroes; without a filter this would
    // still compress, but the assertion below is what would fail if the filter
    // bytes were ever written without the matching residuals.
    const alloc = testing.allocator;
    const w: u32 = 200;
    const h: u32 = 200;
    const data = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(data);
    for (data, 0..) |*b, i| {
        const x = (i / 4) % w;
        b.* = @truncate(x * 3); // a horizontal gradient, repeated every row
    }

    const png = try encode(alloc, .{ .data = data, .width = w, .height = h });
    defer alloc.free(png);
    try testing.expect(png.len < data.len / 20);

    const back = try decode(alloc, png);
    defer alloc.free(back.data);
    try testing.expectEqualSlices(u8, data, back.data);
}

test "encode: a single pixel is a legal image" {
    const alloc = testing.allocator;
    const png = try encode(alloc, .{
        .data = &[_]u8{ 0x12, 0x34, 0x56, 0xFF },
        .width = 1,
        .height = 1,
    });
    defer alloc.free(png);
    const back = try decode(alloc, png);
    defer alloc.free(back.data);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0xFF }, back.data);
}

test "encode: pixels that do not match their dimensions are refused" {
    const alloc = testing.allocator;
    // Short by one pixel. Padding it would encode whatever follows the buffer.
    try testing.expectError(Error.BadPixels, encode(alloc, .{
        .data = &[_]u8{0} ** 12,
        .width = 2,
        .height = 2,
    }));
    try testing.expectError(Error.BadPixels, encode(alloc, .{
        .data = &[_]u8{},
        .width = 0,
        .height = 4,
    }));
    try testing.expectError(Error.BadPixels, encode(alloc, .{
        .data = &[_]u8{0} ** 4,
        .width = 1,
        .height = 0,
    }));
}

/// Inflate a zlib stream with std's decompressor — a decoder nobody here
/// wrote, which is the point.
///
/// An EMPTY window buffer, and `streamRemaining` rather than `allocRemaining`:
/// that combination selects `Decompress`'s direct path, which writes straight
/// into the destination. Handed a window buffer it takes the indirect path
/// instead and asserts inside `writableSlicePreserve` the first time a match
/// is longer than what is left of that buffer — i.e. on any real image.
fn inflate(alloc: Allocator, zlib: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(zlib);
    var dec: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = try dec.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

test "deflate: every shape of input round-trips through std's inflater" {
    const alloc = testing.allocator;

    var big: [40_000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    prng.random().bytes(&big);

    var runs: [12_000]u8 = undefined;
    @memset(&runs, 0);
    // A shape the match finder must get exactly right: overlapping matches
    // (dist=1 over a long zero run) with occasional literals between them.
    for (0..40) |k| runs[k * 300] = @intCast(k + 1);

    var mixed: [5000]u8 = undefined;
    for (&mixed, 0..) |*b, i| b.* = @truncate((i / 17) * 3);

    const cases = [_][]const u8{
        "",
        "a",
        "ab",
        "abc",
        "aaaa",
        "the quick brown fox jumps over the lazy dog",
        "abcabcabcabcabcabcabcabcabcabcabcabcabcabc",
        &big,
        &runs,
        &mixed,
    };
    for (cases) |raw| {
        const z = try deflate(alloc, raw);
        defer alloc.free(z);
        const back = try inflate(alloc, z);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, raw, back);
    }
}

test "deflate: a long run really is compressed, not just copied" {
    // The floor this whole hand-written compressor exists to clear. Stored
    // blocks would leave 200 KB here; a working match finder leaves a few
    // hundred bytes.
    const alloc = testing.allocator;
    const raw = try alloc.alloc(u8, 200_000);
    defer alloc.free(raw);
    @memset(raw, 0);

    const z = try deflate(alloc, raw);
    defer alloc.free(z);
    try testing.expect(z.len < 2000);

    const back = try inflate(alloc, z);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, raw, back);
}

test "adler32: the RFC's own example" {
    // RFC 1950 gives no vector, but zlib's canonical one is "abc" -> 0x024d0127.
    try testing.expectEqual(@as(u32, 0x024d0127), adler32("abc"));
    try testing.expectEqual(@as(u32, 1), adler32(""));
}

test "paeth: the spec's tie-breaking order, which the decoder relies on" {
    // All three equidistant -> a. This is the case a "closest wins" reading
    // gets wrong, and a wrong choice here corrupts every row after it.
    try testing.expectEqual(@as(u8, 10), paeth(10, 10, 10));
    // p = a + b - c favours b when a is the outlier.
    try testing.expectEqual(@as(u8, 200), paeth(10, 200, 10));
    try testing.expectEqual(@as(u8, 10), paeth(10, 10, 200));
}
