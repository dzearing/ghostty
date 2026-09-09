//! The PNG decoder behind a viewer pane's hero thumbnail (T397) and the
//! feedback composer's thumbnail carousel (T646).
//!
//! `ICoreWebView2::CapturePreview` is the only way to get a WebView2's pixels,
//! and it hands back an ENCODED image in an `IStream` — there is no raw-bitmap
//! variant and no target size, so the browser gives us a full-page PNG and
//! something on our side has to turn it into a tile-sized DIB.
//!
//! GDI+'s flat API is that something. It ships in every Windows since XP and it
//! reads straight out of an `IStream` — where WIC would be four more COM
//! interfaces to declare for the same answer.
//!
//! There are two decodes here because there are two kinds of picture, and the
//! difference is ALPHA:
//!
//!   - `decodeScaled` (hero) flattens any alpha against opaque black and
//!     shrinks with one `StretchBlt` (HALFTONE). Its source is a capture of a
//!     web page, which has none, and the tile is blitted opaque.
//!   - `decodeBytes` (carousel) keeps the alpha channel, premultiplied, and
//!     lets GDI+ do the scaling straight into the DIB we keep. Its source is a
//!     picture the user pasted, which really can be see-through, and the colour
//!     it must show through to is a theme colour the cache must not bake in
//!     (T669).
//!
//! Neither path lets the big full-size intermediate outlive the call.
//!
//! Lifetime: GDI+ wants a process-wide `GdiplusStartup` before any other call
//! and a matching `GdiplusShutdown`. Startup is lazy and happens at most once —
//! a viewer pane may never enter hero mode, and paying for GDI+ at app launch
//! for a feature most sessions never touch is the kind of cost that shows up in
//! the T53 soak and nowhere else. Shutdown is deliberately never called: the
//! only moment it would be correct is process exit, where it buys nothing and
//! risks tearing the library out from under an in-flight decode.
const std = @import("std");

const w32 = @import("win32.zig");
const com = @import("com.zig");
const iface = @import("webview2_iface.zig");

const log = std.log.scoped(.win32);

// ---------------------------------------------------------------- GDI+ flat

/// `GpStatus`; 0 is `Ok` and every other value is a failure we only log.
const GpStatus = u32;
const Ok: GpStatus = 0;

const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*anyopaque = null,
    SuppressBackgroundThread: w32.BOOL = 0,
    SuppressExternalCodecs: w32.BOOL = 0,
};

extern "gdiplus" fn GdiplusStartup(
    token: *usize,
    input: *const GdiplusStartupInput,
    output: ?*anyopaque,
) callconv(.winapi) GpStatus;

extern "gdiplus" fn GdipCreateBitmapFromStream(
    stream: *anyopaque,
    bitmap: *?*anyopaque,
) callconv(.winapi) GpStatus;

extern "gdiplus" fn GdipGetImageWidth(image: *anyopaque, width: *u32) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipGetImageHeight(image: *anyopaque, height: *u32) callconv(.winapi) GpStatus;

extern "gdiplus" fn GdipCreateHBITMAPFromBitmap(
    bitmap: *anyopaque,
    hbm: *?w32.HANDLE,
    background: u32,
) callconv(.winapi) GpStatus;

extern "gdiplus" fn GdipDisposeImage(image: *anyopaque) callconv(.winapi) GpStatus;

// The alpha-preserving half of the module (T669). GDI+ can scale straight into
// memory we own, which is the only way to keep an alpha channel across the
// resize: the `HBITMAP` route below flattens it against a background colour,
// and a `StretchBlt` through a DC would drop it again even if it did not.
extern "gdiplus" fn GdipCreateBitmapFromScan0(
    width: i32,
    height: i32,
    stride: i32,
    format: i32,
    scan0: ?[*]u8,
    bitmap: *?*anyopaque,
) callconv(.winapi) GpStatus;

extern "gdiplus" fn GdipGetImageGraphicsContext(
    image: *anyopaque,
    graphics: *?*anyopaque,
) callconv(.winapi) GpStatus;

extern "gdiplus" fn GdipDeleteGraphics(graphics: *anyopaque) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetInterpolationMode(graphics: *anyopaque, mode: i32) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipSetPixelOffsetMode(graphics: *anyopaque, mode: i32) callconv(.winapi) GpStatus;

extern "gdiplus" fn GdipDrawImageRectI(
    graphics: *anyopaque,
    image: *anyopaque,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.winapi) GpStatus;

/// `PixelFormat32bppPARGB` — 32-bit BGRA with the colour channels already
/// multiplied by alpha, which is exactly what `AlphaBlend` reads. Asking GDI+
/// for it means nothing on our side ever has to premultiply by hand.
const PixelFormat32bppPARGB: i32 = 0x000E200B;
/// `InterpolationModeHighQualityBicubic` — the alpha path's answer to the
/// `HALFTONE` the flattening path uses: both average rather than drop rows,
/// which is what keeps a downscaled text page from reading as noise.
const InterpolationModeHighQualityBicubic: i32 = 7;
/// `PixelOffsetModeHighQuality` — samples at pixel centres, so a 1:1 draw is a
/// copy rather than a half-pixel-shifted resample.
const PixelOffsetModeHighQuality: i32 = 2;

/// Nonzero once `GdiplusStartup` succeeded. Only ever touched on the GUI
/// thread (every capture completes on the thread that created the WebView2
/// environment, which is ours), so it needs no synchronization.
var gdiplus_token: usize = 0;
var gdiplus_tried: bool = false;

fn ensureStarted() bool {
    if (gdiplus_token != 0) return true;
    if (gdiplus_tried) return false;
    gdiplus_tried = true;
    const input: GdiplusStartupInput = .{};
    var token: usize = 0;
    const status = GdiplusStartup(&token, &input, null);
    if (status != Ok or token == 0) {
        log.warn("GdiplusStartup failed status={}; viewer thumbnails unavailable", .{status});
        return false;
    }
    gdiplus_token = token;
    return true;
}

// ------------------------------------------------------------------ decode

/// A decoded thumbnail: a 32-bit DIB section the caller owns and must
/// `DeleteObject`.
pub const Thumbnail = struct {
    dib: w32.HANDLE,
    w: i32,
    h: i32,
    /// The DIB section's own pixels, valid for as long as `dib` is, and set
    /// only by the alpha-preserving path (`decodeBytes`). Nothing that PAINTS
    /// wants this — a blit goes through a DC — but a decode whose whole point
    /// is which bytes came out cannot be asserted on from the outside, and the
    /// unit test reads exactly these.
    bits: ?[*]u8 = null,
};

/// Decode the encoded image in `stream` and scale it into a fresh
/// `dst_w` x `dst_h` DIB. Null on any failure — a thumbnail that could not be
/// produced is a tile that keeps its placeholder, never a crash and never a
/// half-painted bitmap.
///
/// Any alpha in the source is FLATTENED against opaque black here, which is the
/// right answer for this function's one caller: the hero thumbnail (T397) is a
/// capture of a web page, which has no transparency, and the result is blitted
/// with `BitBlt`. A picture that really can be see-through wants `decodeBytes`
/// instead — see T669 for why the two are separate rather than one call with a
/// background colour threaded through it.
///
/// `stream` must be positioned at the START of the image; the caller rewinds
/// it, for the same reason `ViewerPane.respond` does.
pub fn decodeScaled(stream: *anyopaque, dst_w: i32, dst_h: i32) ?Thumbnail {
    if (dst_w <= 0 or dst_h <= 0) return null;
    if (!ensureStarted()) return null;

    var bitmap: ?*anyopaque = null;
    const create = GdipCreateBitmapFromStream(stream, &bitmap);
    if (create != Ok or bitmap == null) {
        log.warn("GdipCreateBitmapFromStream failed status={}", .{create});
        return null;
    }
    defer _ = GdipDisposeImage(bitmap.?);

    // A zero-dimension capture is a real answer from the runtime (a view that
    // has not laid out yet), and blitting from it would divide by zero.
    var src_w: u32 = 0;
    var src_h: u32 = 0;
    if (GdipGetImageWidth(bitmap.?, &src_w) != Ok) return null;
    if (GdipGetImageHeight(bitmap.?, &src_h) != Ok) return null;
    if (src_w == 0 or src_h == 0) return null;

    var hbm: ?w32.HANDLE = null;
    const to_hbm = GdipCreateHBITMAPFromBitmap(bitmap.?, &hbm, 0xFF000000);
    if (to_hbm != Ok or hbm == null) {
        log.warn("GdipCreateHBITMAPFromBitmap failed status={}", .{to_hbm});
        return null;
    }
    defer _ = w32.DeleteObject(hbm.?);

    return scaleInto(hbm.?, @intCast(src_w), @intCast(src_h), dst_w, dst_h);
}

/// The same decode from BYTES already in memory — what the feedback composer's
/// thumbnail carousel needs (T646), where the picture is a PNG the store is
/// holding rather than something a runtime is streaming to us.
///
/// Unlike `decodeScaled` this KEEPS the alpha channel, premultiplied, and
/// leaves the compositing to whoever paints the tile (T669). A pasted picture
/// really can be see-through — a logo, a cropped screenshot with rounded
/// corners — and the colour it should show through to is the tile's fill, which
/// is a theme colour. Flattening here would bake that colour into the cached
/// bitmap and make a light/dark switch a re-decode of every tile; blending at
/// paint time keeps the cache theme-independent, which is also why the tile's
/// fill is derived rather than stored.
///
/// GDI+ reads from an `IStream` and nothing else, so the bytes are wrapped in
/// the cheapest one Windows offers. `fDeleteOnRelease` is TRUE: the HGLOBAL is
/// then the stream's, and there is exactly one release path to get right
/// instead of two.
pub fn decodeBytes(bytes: []const u8, dst_w: i32, dst_h: i32) ?Thumbnail {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(u32)) return null;

    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, bytes.len) orelse return null;
    var owned = false;
    defer if (!owned) {
        _ = w32.GlobalFree(hglobal);
    };
    {
        const dst = w32.GlobalLock(hglobal) orelse return null;
        defer _ = w32.GlobalUnlock(hglobal);
        @memcpy(dst[0..bytes.len], bytes);
    }

    var stream_ptr: ?*anyopaque = null;
    if (com.failed(w32.CreateStreamOnHGlobal(hglobal, 1, &stream_ptr))) return null;
    const stream: *iface.IStream = @ptrCast(@alignCast(stream_ptr orelse return null));
    owned = true; // the stream frees the HGLOBAL now, in its own Release
    defer stream.release();

    // Created around a full buffer, the seek pointer is already at 0 — but
    // saying so costs nothing and the one failure it prevents (a zero-byte
    // decode that reports "corrupt image") is the one this module already
    // documents twice.
    if (!stream.rewind()) return null;
    return decodeAlpha(@ptrCast(stream), dst_w, dst_h);
}

/// Decode and scale into a premultiplied 32-bit DIB with the alpha channel
/// intact — the half of the module `AlphaBlend` can paint (T669).
///
/// GDI+ does the scaling here rather than `StretchBlt`, because there is no way
/// to get an alpha channel through the other path: `GdipCreateHBITMAPFromBitmap`
/// composites it away by contract (its third argument is what against), and a
/// GDI blit treats the fourth byte as padding it may or may not carry. Handing
/// GDI+ our own DIB section as its `Scan0` means the scaled pixels land
/// straight in the bitmap we keep, with one fewer full-size intermediate than
/// the flattening path allocates.
fn decodeAlpha(stream: *anyopaque, dst_w: i32, dst_h: i32) ?Thumbnail {
    if (dst_w <= 0 or dst_h <= 0) return null;
    if (!ensureStarted()) return null;

    var src: ?*anyopaque = null;
    const create = GdipCreateBitmapFromStream(stream, &src);
    if (create != Ok or src == null) {
        log.warn("GdipCreateBitmapFromStream failed status={}", .{create});
        return null;
    }
    defer _ = GdipDisposeImage(src.?);

    // Same guard as the flattening path, for the same reason: a zero-dimension
    // image is a real answer, and drawing from one is undefined rather than
    // merely empty.
    var src_w: u32 = 0;
    var src_h: u32 = 0;
    if (GdipGetImageWidth(src.?, &src_w) != Ok) return null;
    if (GdipGetImageHeight(src.?, &src_h) != Ok) return null;
    if (src_w == 0 or src_h == 0) return null;

    // Negative `biHeight`, i.e. TOP-DOWN: GDI+'s `Scan0` contract is a positive
    // stride over rows in reading order, and the alternative (a bottom-up DIB
    // with a negative stride pointed at the last row) is the same picture
    // described in a way one more reader has to decode. The blit that paints it
    // goes through a DC, which presents either orientation the same way.
    var bits: ?*anyopaque = null;
    const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = dst_w, .biHeight = -dst_h } };
    const dib = w32.CreateDIBSection(null, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    var ok = false;
    defer if (!ok) {
        _ = w32.DeleteObject(dib);
    };
    const scan0: [*]u8 = @ptrCast(bits orelse return null);

    var dst: ?*anyopaque = null;
    const wrap = GdipCreateBitmapFromScan0(dst_w, dst_h, dst_w * 4, PixelFormat32bppPARGB, scan0, &dst);
    if (wrap != Ok or dst == null) {
        log.warn("GdipCreateBitmapFromScan0 failed status={}", .{wrap});
        return null;
    }
    // Disposing a bitmap made from `Scan0` frees the wrapper, never the pixels:
    // the DIB section outlives it and belongs to the caller.
    defer _ = GdipDisposeImage(dst.?);

    var g: ?*anyopaque = null;
    const ctx = GdipGetImageGraphicsContext(dst.?, &g);
    if (ctx != Ok or g == null) {
        log.warn("GdipGetImageGraphicsContext failed status={}", .{ctx});
        return null;
    }
    // Deleting the graphics flushes it, so this must happen before anyone reads
    // the pixels — a `defer` runs at return, which is before the caller resumes.
    defer _ = GdipDeleteGraphics(g.?);

    _ = GdipSetInterpolationMode(g.?, InterpolationModeHighQualityBicubic);
    _ = GdipSetPixelOffsetMode(g.?, PixelOffsetModeHighQuality);

    // The default compositing mode (`SourceOver`) onto the freshly created —
    // and therefore zeroed, i.e. fully transparent — surface reproduces the
    // source exactly, premultiplied, and does it without `SourceCopy`'s
    // documented edge behaviour on partially covered destination pixels.
    const drew = GdipDrawImageRectI(g.?, src.?, 0, 0, dst_w, dst_h);
    if (drew != Ok) {
        log.warn("GdipDrawImageRectI failed status={}", .{drew});
        return null;
    }

    ok = true;
    return .{ .dib = dib, .w = dst_w, .h = dst_h, .bits = scan0 };
}

/// Shrink `src` into a new DIB of exactly `dst_w` x `dst_h`.
///
/// Positive `biHeight` (bottom-up) so the result matches what a terminal's
/// snapshot DIB is, and both kinds can be blitted by the same carousel code
/// without one of them arriving upside down. Writing through a DC rather than
/// by hand is what makes the orientation a non-issue: GDI presents a bottom-up
/// DIB in ordinary top-down logical coordinates on both sides of the blit.
fn scaleInto(src: w32.HANDLE, src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) ?Thumbnail {
    const screen = w32.GetDC(null) orelse return null;
    defer _ = w32.ReleaseDC(null, screen);

    var bits: ?*anyopaque = null;
    const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = dst_w, .biHeight = dst_h } };
    const dst = w32.CreateDIBSection(null, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    var ok = false;
    defer if (!ok) {
        _ = w32.DeleteObject(dst);
    };

    const src_dc = w32.CreateCompatibleDC(screen) orelse return null;
    defer _ = w32.DeleteDC(src_dc);
    const dst_dc = w32.CreateCompatibleDC(screen) orelse return null;
    defer _ = w32.DeleteDC(dst_dc);

    const old_src = w32.SelectObject(src_dc, src);
    defer _ = w32.SelectObject(src_dc, old_src);
    const old_dst = w32.SelectObject(dst_dc, dst);
    defer _ = w32.SelectObject(dst_dc, old_dst);

    // HALFTONE is the only mode that averages rather than dropping rows, and a
    // dropped-row downscale of a text page reads as noise at tile size. It
    // needs the brush origin reset, per its own contract.
    _ = w32.SetStretchBltMode(dst_dc, w32.HALFTONE);
    _ = w32.SetBrushOrgEx(dst_dc, 0, 0, null);
    if (w32.StretchBlt(dst_dc, 0, 0, dst_w, dst_h, src_dc, 0, 0, src_w, src_h, w32.SRCCOPY) == 0) {
        return null;
    }

    ok = true;
    return .{ .dib = dst, .w = dst_w, .h = dst_h };
}


// ------------------------------------------------------------------- tests

const png_encode = @import("png_encode.zig");
const testing = std.testing;

// The T669 regression, asserted where it actually happens: at the decode.
//
// The picture is built here rather than checked in as a blob, so what is
// transparent is visible in the test instead of being a claim about a file.
// Sampling is deliberately away from the seam — a resampling filter is allowed
// to blend ACROSS the boundary, and asserting it does not would be asserting
// the interpolation mode rather than the alpha.
//
// Before the fix this failed on the first assertion: the transparent half came
// back opaque (alpha 255) and black, because the decode composited it against
// `0xFF000000`.
test "decode: a transparent PNG keeps its alpha instead of being flattened onto black" {
    const alloc = testing.allocator;
    const side: u32 = 16;
    const data = try alloc.alloc(u8, side * side * 4);
    defer alloc.free(data);
    for (0..side) |y| {
        for (0..side) |x| {
            const i = (y * side + x) * 4;
            if (x < side / 2) {
                @memset(data[i..][0..4], 0); // fully transparent
            } else {
                data[i + 0] = 0xFF; // opaque red
                data[i + 1] = 0x00;
                data[i + 2] = 0x00;
                data[i + 3] = 0xFF;
            }
        }
    }

    const png = try png_encode.encode(alloc, .{ .data = data, .width = side, .height = side });
    defer alloc.free(png);

    // 1:1, so the only thing under test is what the decode does to the pixels.
    const t = decodeBytes(png, @intCast(side), @intCast(side)) orelse {
        return testing.expect(false);
    };
    defer _ = w32.DeleteObject(t.dib);
    try testing.expectEqual(@as(i32, @intCast(side)), t.w);
    try testing.expectEqual(@as(i32, @intCast(side)), t.h);
    const px = t.bits orelse return testing.expect(false);

    // Top-down, 4 bytes per pixel, BGRA premultiplied.
    const row: usize = 8;
    const clear = px[((row * side) + 2) * 4 ..][0..4];
    try testing.expectEqual(@as(u8, 0), clear[3]); // alpha
    // Premultiplied by an alpha of zero, so the colour channels are zero too —
    // which is the assertion that says no background colour was composited in.
    try testing.expectEqual(@as(u8, 0), clear[0]);
    try testing.expectEqual(@as(u8, 0), clear[1]);
    try testing.expectEqual(@as(u8, 0), clear[2]);

    // And the opaque half is still the colour it was, so "keeps the alpha" did
    // not quietly become "lost the picture".
    const solid = px[((row * side) + 13) * 4 ..][0..4];
    try testing.expectEqual(@as(u8, 255), solid[3]);
    try testing.expect(solid[2] > 0xF0); // R
    try testing.expect(solid[1] < 0x10); // G
    try testing.expect(solid[0] < 0x10); // B
}

// A fully opaque picture must come back byte-identical whichever path it takes,
// because that is the promise that lets the carousel switch to `AlphaBlend`
// without every ordinary screenshot changing appearance.
test "decode: an opaque PNG survives the alpha path unchanged" {
    const alloc = testing.allocator;
    const side: u32 = 8;
    const data = try alloc.alloc(u8, side * side * 4);
    defer alloc.free(data);
    for (0..side) |y| {
        for (0..side) |x| {
            const i = (y * side + x) * 4;
            data[i + 0] = @intCast(x * 30);
            data[i + 1] = @intCast(y * 30);
            data[i + 2] = 0x40;
            data[i + 3] = 0xFF;
        }
    }
    const png = try png_encode.encode(alloc, .{ .data = data, .width = side, .height = side });
    defer alloc.free(png);

    const t = decodeBytes(png, @intCast(side), @intCast(side)) orelse {
        return testing.expect(false);
    };
    defer _ = w32.DeleteObject(t.dib);
    const px = t.bits orelse return testing.expect(false);

    for (0..side) |y| {
        for (0..side) |x| {
            const src = data[((y * side) + x) * 4 ..][0..4];
            const got = px[((y * side) + x) * 4 ..][0..4];
            try testing.expectEqual(@as(u8, 255), got[3]);
            try testing.expectEqual(src[0], got[2]); // R
            try testing.expectEqual(src[1], got[1]); // G
            try testing.expectEqual(src[2], got[0]); // B
        }
    }
}
