//! The PNG decoder behind a viewer pane's hero thumbnail (T397).
//!
//! `ICoreWebView2::CapturePreview` is the only way to get a WebView2's pixels,
//! and it hands back an ENCODED image in an `IStream` — there is no raw-bitmap
//! variant and no target size, so the browser gives us a full-page PNG and
//! something on our side has to turn it into a tile-sized DIB.
//!
//! GDI+'s flat API is that something. It is five entry points, it ships in
//! every Windows since XP, and it reads straight out of an `IStream` — where
//! WIC would be four more COM interfaces to declare for the same answer. What
//! it does NOT do is scale for us cheaply, so the decode lands at full size and
//! one `StretchBlt` (HALFTONE) shrinks it into the DIB we keep. The big
//! intermediate never outlives this call.
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
};

/// Decode the encoded image in `stream` and scale it into a fresh
/// `dst_w` x `dst_h` DIB. Null on any failure — a thumbnail that could not be
/// produced is a tile that keeps its placeholder, never a crash and never a
/// half-painted bitmap.
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
    return decodeScaled(@ptrCast(stream), dst_w, dst_h);
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
