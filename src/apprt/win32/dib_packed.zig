//! Reading a PACKED DIB — the shape a bitmap has on the clipboard (T637).
//!
//! `CF_DIB` and `CF_DIBV5` hand over one memory block: a header, then an
//! optional colour table, then the pixel bits, with nothing between them saying
//! where one ends and the next begins. Every consumer has to re-derive that
//! offset from the header's own fields, and getting it wrong does not fail —
//! it renders the palette as pixels, or reads past the block.
//!
//! Pure — no OS imports, no pointers — so the derivation asserts in the
//! `-Dapp-runtime=none` lane against the header shapes real applications
//! actually put on the clipboard. `clipboard_image.zig` does the GDI half.
//!
//! ## The three things that move the offset
//!
//! - **The header's own size** is a field (`biSize`), not a constant: 12 for
//!   the OS/2 core header, 40 for `BITMAPINFOHEADER`, 108 for V4, 124 for V5.
//! - **`BI_BITFIELDS` adds three masks** after a 40-byte header — and only
//!   after a 40-byte one, because V4 and V5 carry their masks inside the
//!   header. A reader that adds 12 unconditionally lands 12 bytes into the
//!   image on every V5 paste, which is what Snipping Tool produces.
//! - **A palette** follows for anything 8bpp or below, sized by `biClrUsed`
//!   when that is set and by `1 << bitCount` when it is zero.
const std = @import("std");

/// What a packed DIB says about itself. Sizes are in the blob's own terms, so
/// a caller can bounds-check before handing anything to GDI.
pub const Info = struct {
    width: i32,
    height: i32,
    bit_count: u16,
    compression: u32,
    /// Byte offset of the first pixel from the START of the blob.
    bits_offset: usize,
    /// A negative `biHeight` means the rows are stored top-down.
    top_down: bool,

    pub fn absHeight(self: Info) i32 {
        return if (self.height < 0) -self.height else self.height;
    }
};

pub const BI_RGB: u32 = 0;
pub const BI_BITFIELDS: u32 = 3;
pub const BI_ALPHABITFIELDS: u32 = 6;

/// The OS/2 header, which is the only one with a different field layout.
const core_header_size: u32 = 12;
const info_header_size: u32 = 40;

pub const Error = error{
    /// Too short to hold the header it claims, or a header size no version of
    /// this structure has ever had.
    Malformed,
};

/// Parse a packed DIB's header. Refuses anything whose declared parts do not
/// fit inside `blob` — a bitmap that lies about its own size is a bitmap this
/// must not hand to GDI.
pub fn parse(blob: []const u8) Error!Info {
    if (blob.len < 4) return Error.Malformed;
    const header_size = std.mem.readInt(u32, blob[0..4], .little);

    if (header_size == core_header_size) {
        // BITMAPCOREHEADER: 16-bit dimensions, no compression field, and a
        // palette of RGBTRIPLEs rather than RGBQUADs.
        if (blob.len < core_header_size) return Error.Malformed;
        const w = std.mem.readInt(i16, blob[4..6], .little);
        const h = std.mem.readInt(i16, blob[6..8], .little);
        const bits = std.mem.readInt(u16, blob[10..12], .little);
        var offset: usize = core_header_size;
        if (bits <= 8) offset += (@as(usize, 1) << @intCast(bits)) * 3;
        if (offset > blob.len) return Error.Malformed;
        return .{
            .width = w,
            .height = h,
            .bit_count = bits,
            .compression = BI_RGB,
            .bits_offset = offset,
            .top_down = h < 0,
        };
    }

    // Everything else shares BITMAPINFOHEADER's first 40 bytes: V4 (108) and
    // V5 (124) only append.
    if (header_size < info_header_size) return Error.Malformed;
    if (blob.len < header_size) return Error.Malformed;

    const width = std.mem.readInt(i32, blob[4..8], .little);
    const height = std.mem.readInt(i32, blob[8..12], .little);
    const bit_count = std.mem.readInt(u16, blob[14..16], .little);
    const compression = std.mem.readInt(u32, blob[16..20], .little);
    const clr_used = std.mem.readInt(u32, blob[32..36], .little);

    var offset: usize = header_size;
    // The masks live BETWEEN the header and the palette, and only when the
    // header is too old to hold them itself.
    if (header_size == info_header_size) {
        if (compression == BI_BITFIELDS) offset += 12;
        if (compression == BI_ALPHABITFIELDS) offset += 16;
    }
    if (bit_count <= 8) {
        const entries: usize = if (clr_used != 0)
            clr_used
        else
            (@as(usize, 1) << @intCast(bit_count));
        offset += entries * 4;
    }
    if (offset > blob.len) return Error.Malformed;

    return .{
        .width = width,
        .height = height,
        .bit_count = bit_count,
        .compression = compression,
        .bits_offset = offset,
        .top_down = height < 0,
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

/// A 40-byte `BITMAPINFOHEADER` with the fields these tests care about, then
/// `trailing` bytes of whatever comes next.
fn infoHeader(
    buf: []u8,
    width: i32,
    height: i32,
    bit_count: u16,
    compression: u32,
    clr_used: u32,
) []u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 40, .little);
    std.mem.writeInt(i32, buf[4..8], width, .little);
    std.mem.writeInt(i32, buf[8..12], height, .little);
    std.mem.writeInt(u16, buf[12..14], 1, .little);
    std.mem.writeInt(u16, buf[14..16], bit_count, .little);
    std.mem.writeInt(u32, buf[16..20], compression, .little);
    std.mem.writeInt(u32, buf[32..36], clr_used, .little);
    return buf;
}

test "a plain 32-bit DIB: the bits start straight after the header" {
    var buf: [40 + 16]u8 = undefined;
    _ = infoHeader(&buf, 4, 4, 32, BI_RGB, 0);
    const info = try parse(&buf);
    try testing.expectEqual(@as(usize, 40), info.bits_offset);
    try testing.expectEqual(@as(i32, 4), info.width);
    try testing.expectEqual(@as(u16, 32), info.bit_count);
    try testing.expect(!info.top_down);
    try testing.expectEqual(@as(i32, 4), info.absHeight());
}

test "BI_BITFIELDS adds three masks after a 40-byte header, and only there" {
    {
        var buf: [40 + 12 + 16]u8 = undefined;
        _ = infoHeader(&buf, 2, 2, 32, BI_BITFIELDS, 0);
        const info = try parse(&buf);
        try testing.expectEqual(@as(usize, 52), info.bits_offset);
    }
    // A V5 header carries its masks INSIDE itself, so adding 12 here would
    // start the image 12 bytes in — the Snipping Tool paste.
    {
        var buf: [124 + 16]u8 = undefined;
        @memset(&buf, 0);
        std.mem.writeInt(u32, buf[0..4], 124, .little);
        std.mem.writeInt(i32, buf[4..8], 2, .little);
        std.mem.writeInt(i32, buf[8..12], 2, .little);
        std.mem.writeInt(u16, buf[14..16], 32, .little);
        std.mem.writeInt(u32, buf[16..20], BI_BITFIELDS, .little);
        const info = try parse(&buf);
        try testing.expectEqual(@as(usize, 124), info.bits_offset);
    }
}

test "a palette is counted, by biClrUsed when it is set and by depth when not" {
    // 8bpp with an explicit 16-entry palette.
    {
        var buf: [40 + 16 * 4 + 8]u8 = undefined;
        _ = infoHeader(&buf, 2, 2, 8, BI_RGB, 16);
        const info = try parse(&buf);
        try testing.expectEqual(@as(usize, 40 + 64), info.bits_offset);
    }
    // 8bpp with biClrUsed = 0 means the full 256 entries, not none.
    {
        var buf: [40 + 256 * 4 + 8]u8 = undefined;
        _ = infoHeader(&buf, 2, 2, 8, BI_RGB, 0);
        const info = try parse(&buf);
        try testing.expectEqual(@as(usize, 40 + 1024), info.bits_offset);
    }
    // 24bpp has no palette even when biClrUsed is (wrongly) non-zero... which
    // it can be, as an "optimal palette" hint. Bit depth decides.
    {
        var buf: [40 + 32]u8 = undefined;
        _ = infoHeader(&buf, 2, 2, 24, BI_RGB, 256);
        const info = try parse(&buf);
        try testing.expectEqual(@as(usize, 40), info.bits_offset);
    }
}

test "a top-down DIB is recognised by its negative height" {
    var buf: [40 + 16]u8 = undefined;
    _ = infoHeader(&buf, 2, -2, 32, BI_RGB, 0);
    const info = try parse(&buf);
    try testing.expect(info.top_down);
    try testing.expectEqual(@as(i32, -2), info.height);
    try testing.expectEqual(@as(i32, 2), info.absHeight());
}

test "the OS/2 core header, whose fields sit somewhere else entirely" {
    var buf: [12 + 2 * 3 + 16]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], 12, .little);
    std.mem.writeInt(i16, buf[4..6], 3, .little);
    std.mem.writeInt(i16, buf[6..8], 5, .little);
    std.mem.writeInt(u16, buf[8..10], 1, .little);
    std.mem.writeInt(u16, buf[10..12], 1, .little); // 1bpp -> 2 RGBTRIPLEs
    const info = try parse(&buf);
    try testing.expectEqual(@as(i32, 3), info.width);
    try testing.expectEqual(@as(i32, 5), info.height);
    try testing.expectEqual(@as(usize, 12 + 6), info.bits_offset);
}

test "a header that does not fit in its own blob is refused" {
    try testing.expectError(Error.Malformed, parse(""));
    try testing.expectError(Error.Malformed, parse(&[_]u8{ 1, 2, 3 }));

    // Claims 124 bytes of header inside 40 bytes of memory.
    var short: [40]u8 = undefined;
    @memset(&short, 0);
    std.mem.writeInt(u32, short[0..4], 124, .little);
    try testing.expectError(Error.Malformed, parse(&short));

    // A header size nothing has ever used.
    var odd: [64]u8 = undefined;
    @memset(&odd, 0);
    std.mem.writeInt(u32, odd[0..4], 20, .little);
    try testing.expectError(Error.Malformed, parse(&odd));

    // A palette that runs past the end of the block.
    var pal: [40 + 8]u8 = undefined;
    _ = infoHeader(&pal, 2, 2, 8, BI_RGB, 256);
    try testing.expectError(Error.Malformed, parse(&pal));
}
