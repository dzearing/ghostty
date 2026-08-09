//! Taking an image off the clipboard as PNG bytes (T637) — what Ctrl+V in the
//! viewer's feedback composer runs before it decides whether it is pasting
//! text or a picture.
//!
//! ## Why this is not just `GetClipboardData(CF_DIB)`
//!
//! Mac's trap here was `readablePasteboardTypes`: without declaring the image
//! types, AppKit *disabled* Cmd-V for an image-only clipboard and the paste
//! override never ran — a silent no-op. The win32 shape of that mistake is a
//! control that only ever asks for `CF_UNICODETEXT`, which is exactly what
//! RichEdit does by default. So the composer asks HERE first, and the formats
//! below are the ones a real clipboard carries:
//!
//! - **`"PNG"`**, a registered format, is what every browser and most modern
//!   editors publish alongside a bitmap. Taken first and copied VERBATIM: it
//!   is already the file we want, and a decode/re-encode round trip would cost
//!   quality for nothing.
//! - **`CF_DIBV5`** then **`CF_DIB`**, which is what Snipping Tool, Paint,
//!   Excel and the Win+Shift+S overlay publish.
//! - **`CF_BITMAP`**, a bare HBITMAP. GDI synthesises it from a DIB and vice
//!   versa, so this is mostly a backstop — but it costs four lines.
//!
//! ## Normalising through GDI, deliberately
//!
//! A clipboard DIB can be 1/4/8/16/24/32 bits, palettised, `BI_BITFIELDS` with
//! arbitrary channel masks, bottom-up or top-down. Handling that matrix by
//! hand is a lot of code for pixels nobody looks at twice, so one
//! `StretchDIBits` into a 32-bit top-down DIB section does it: GDI already
//! knows every one of those formats, and what comes out is always BGRA in one
//! layout. `dib_packed.zig` supplies the one thing GDI will not — where the
//! pixels start inside the packed block — and asserts it in the none lane.
//!
//! ## Alpha is dropped, on purpose
//!
//! The normalised result is written as opaque RGB. A 32-bit clipboard DIB's
//! fourth byte is unreliable — plenty of applications publish one with every
//! alpha byte zero, and honouring that would turn a perfectly good screenshot
//! into a fully transparent image, which reads as blank in the report. Mac's
//! `screencapture` produces opaque captures too, so nothing is lost against
//! the platform we are matching. A `"PNG"` taken verbatim keeps whatever alpha
//! it had, because nothing here touched it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const dib_packed = @import("dib_packed.zig");
const png_encode = @import("png_encode.zig");
const images = @import("viewer_feedback_images.zig");

const log = std.log.scoped(.viewer_feedback);

/// Beyond this the picture is not feedback, it is a memory incident. 64
/// megapixels is over twice a 6K display.
const max_pixels: usize = 64 * 1024 * 1024;

/// `OpenClipboard` fails while another process holds it, which happens
/// routinely for a few milliseconds after a copy. Retried rather than refused,
/// because "paste did nothing" is indistinguishable from a bug.
const open_attempts: u32 = 8;
const open_retry_ms: u32 = 15;

/// Whether the clipboard holds a picture. Cheap enough for a keystroke: it
/// opens nothing and allocates nothing.
///
/// This is the question the composer asks BEFORE letting RichEdit handle a
/// paste, so a clipboard carrying both an image and its own text fallback (a
/// browser's "copy image" does) pastes as the image.
pub fn available() bool {
    if (w32.IsClipboardFormatAvailable(pngFormat()) != 0) return true;
    for ([_]u32{ w32.CF_DIBV5, w32.CF_DIB, w32.CF_BITMAP }) |fmt| {
        if (w32.IsClipboardFormatAvailable(fmt) != 0) return true;
    }
    return false;
}

/// The clipboard's image as PNG bytes, or null when there is no image on it
/// (or it could not be read). Caller frees.
pub fn read(alloc: Allocator, owner: ?w32.HWND) ?[]u8 {
    if (!open(owner)) {
        log.warn("clipboard image: OpenClipboard failed", .{});
        return null;
    }
    defer _ = w32.CloseClipboard();

    // Already a PNG: hand it over untouched.
    if (readVerbatimPng(alloc)) |png| return png;

    for ([_]u32{ w32.CF_DIBV5, w32.CF_DIB }) |fmt| {
        if (w32.IsClipboardFormatAvailable(fmt) == 0) continue;
        if (readPackedDib(alloc, fmt)) |png| return png;
    }
    if (w32.IsClipboardFormatAvailable(w32.CF_BITMAP) != 0) {
        if (readBitmap(alloc)) |png| return png;
    }
    return null;
}

fn open(owner: ?w32.HWND) bool {
    var i: u32 = 0;
    while (i < open_attempts) : (i += 1) {
        if (w32.OpenClipboard(owner) != 0) return true;
        w32.Sleep(open_retry_ms);
    }
    return false;
}

/// The registered `"PNG"` format id, resolved once. Zero when it could not be
/// registered, which `IsClipboardFormatAvailable` treats as "no".
fn pngFormat() u32 {
    const State = struct {
        var id: u32 = 0;
        var tried: bool = false;
    };
    if (!State.tried) {
        State.tried = true;
        State.id = w32.RegisterClipboardFormatW(
            std.unicode.utf8ToUtf16LeStringLiteral("PNG"),
        );
    }
    return State.id;
}

fn readVerbatimPng(alloc: Allocator) ?[]u8 {
    const fmt = pngFormat();
    if (fmt == 0 or w32.IsClipboardFormatAvailable(fmt) == 0) return null;
    const blob = lock(fmt) orelse return null;
    defer _ = w32.GlobalUnlock(blob.handle);

    // Trust the format name only as far as the bytes back it up: some
    // applications register "PNG" and publish something else entirely.
    if (!images.isPng(blob.bytes)) {
        log.warn("clipboard image: the PNG format held {d} bytes that are not a PNG", .{
            blob.bytes.len,
        });
        return null;
    }
    return alloc.dupe(u8, blob.bytes) catch null;
}

const Locked = struct {
    handle: *anyopaque,
    bytes: []const u8,
};

fn lock(fmt: u32) ?Locked {
    const handle = w32.GetClipboardData(fmt) orelse return null;
    const size = w32.GlobalSize(handle);
    if (size == 0) return null;
    const ptr = w32.GlobalLock(handle) orelse return null;
    return .{ .handle = handle, .bytes = ptr[0..size] };
}

fn readPackedDib(alloc: Allocator, fmt: u32) ?[]u8 {
    const blob = lock(fmt) orelse return null;
    defer _ = w32.GlobalUnlock(blob.handle);

    const info = dib_packed.parse(blob.bytes) catch |err| {
        log.warn("clipboard image: unreadable DIB ({s})", .{@errorName(err)});
        return null;
    };
    const width = info.width;
    const height = info.absHeight();
    if (!sane(width, height)) return null;

    return normalize(alloc, width, height, .{
        .dib = .{
            .header = blob.bytes.ptr,
            .bits = blob.bytes.ptr + info.bits_offset,
        },
    });
}

fn readBitmap(alloc: Allocator) ?[]u8 {
    const hbm = w32.GetClipboardData(w32.CF_BITMAP) orelse return null;
    var bm: w32.BITMAP = .{};
    if (w32.GetObjectW(hbm, @sizeOf(w32.BITMAP), &bm) == 0) return null;
    if (!sane(bm.bmWidth, bm.bmHeight)) return null;
    return normalize(alloc, bm.bmWidth, bm.bmHeight, .{ .hbitmap = hbm });
}

fn sane(width: i32, height: i32) bool {
    if (width <= 0 or height <= 0) return false;
    const pixels = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    if (pixels > max_pixels) {
        log.warn("clipboard image: {d}x{d} is too large to attach", .{ width, height });
        return false;
    }
    return true;
}

const Source = union(enum) {
    /// A packed DIB: a pointer at its header and one at its pixels.
    dib: struct { header: [*]const u8, bits: [*]const u8 },
    /// A device-dependent bitmap handle.
    hbitmap: w32.HANDLE,
};

/// Convert any source into a 32-bit top-down BGRA buffer via GDI, then encode
/// it as opaque RGB. Null on any failure — a paste that cannot be read is a
/// paste that does nothing, never a crash.
fn normalize(alloc: Allocator, width: i32, height: i32, src: Source) ?[]u8 {
    const screen = w32.GetDC(null) orelse return null;
    defer _ = w32.ReleaseDC(null, screen);

    // Negative height: rows top-down, so the buffer is in the order the PNG
    // encoder wants and nothing has to be flipped afterwards.
    var bits_ptr: ?*anyopaque = null;
    const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = width,
        .biHeight = -height,
        .biBitCount = 32,
    } };
    const section = w32.CreateDIBSection(
        null,
        &bmi,
        w32.DIB_RGB_COLORS,
        &bits_ptr,
        null,
        0,
    ) orelse return null;
    defer _ = w32.DeleteObject(section);
    const bits: [*]const u8 = @ptrCast(bits_ptr orelse return null);

    switch (src) {
        .dib => |d| {
            const dc = w32.CreateCompatibleDC(screen) orelse return null;
            defer _ = w32.DeleteDC(dc);
            const old = w32.SelectObject(dc, section);
            defer _ = w32.SelectObject(dc, old);
            // Source and destination are the same size, so this is a straight
            // format conversion; GDI reads the source's own layout (palette,
            // masks, bottom-up) out of the header it is given.
            if (w32.StretchDIBits(
                dc,
                0,
                0,
                width,
                height,
                0,
                0,
                width,
                height,
                d.bits,
                d.header,
                w32.DIB_RGB_COLORS,
                w32.SRCCOPY,
            ) == 0) return null;
        },
        .hbitmap => |hbm| {
            var out_bmi: w32.BITMAPINFO = .{ .bmiHeader = .{
                .biWidth = width,
                .biHeight = -height,
                .biBitCount = 32,
            } };
            if (w32.GetDIBits(
                screen,
                hbm,
                0,
                @intCast(height),
                bits_ptr,
                &out_bmi,
                w32.DIB_RGB_COLORS,
            ) == 0) return null;
        },
    }

    // GDI wrote BGRA; PNG wants RGB in that order, and the alpha byte is not
    // trustworthy (see the header). One pass, no intermediate.
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const rgb = alloc.alloc(u8, w * h * 3) catch return null;
    defer alloc.free(rgb);
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        rgb[i * 3 + 0] = bits[i * 4 + 2];
        rgb[i * 3 + 1] = bits[i * 4 + 1];
        rgb[i * 3 + 2] = bits[i * 4 + 0];
    }

    return png_encode.encode(alloc, .{
        .data = rgb,
        .width = @intCast(w),
        .height = @intCast(h),
        .channels = .rgb,
    }) catch |err| {
        log.warn("clipboard image: PNG encode failed ({s})", .{@errorName(err)});
        return null;
    };
}
