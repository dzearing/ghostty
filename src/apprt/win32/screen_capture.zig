//! A snapshot of the whole desktop, and the crop out of it that becomes a
//! feedback screenshot (T647).
//!
//! ## Why a snapshot rather than a grab at the end
//!
//! The region selector paints a dimmed copy of the screen and lets the user
//! drag a rectangle over it. That dimmed copy has to come from somewhere, and
//! grabbing the screen a SECOND time when the drag finishes would photograph
//! the selector's own window — a full-screen opaque one — instead of what the
//! user was pointing at. So the pixels are taken ONCE, before the overlay
//! exists, and everything after that (the dim, the bright selection, the PNG)
//! is a read out of that one buffer.
//!
//! It also makes the picture match what the user saw when they pressed the
//! button, which is the honest answer for a feedback screenshot: a menu they
//! were complaining about does not have to survive the act of describing it.
//!
//! ## The clipboard is never touched
//!
//! That is this whole module's reason to exist rather than shelling out to
//! `ms-screenclip:` or `SnippingTool /clip`, both of which publish the capture
//! through the clipboard and therefore destroy whatever the user had on it.
//! Mac's own comment on `screencapture -i -o` says the same thing about `-c`.
//! Nothing here opens the clipboard, and the acceptance script asserts it by
//! reading a known string back across a capture.
//!
//! ## Coordinates
//!
//! Everything public here is in VIRTUAL-SCREEN coordinates: physical pixels,
//! origin at the primary monitor's top-left, negative to the left of and above
//! it. The manifest declares PerMonitorV2, so no scaling is applied to those
//! numbers by the system and none is applied here — a 4K monitor at 150% is
//! captured at 3840x2160, not at 2560x1440. Rect math lives in the pure
//! `region_select.zig`, which asserts in every lane.

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const png_encode = @import("png_encode.zig");
const region = @import("region_select.zig");

const log = std.log.scoped(.viewer_feedback);

/// Refuse a desktop whose pixel count is beyond anything a real display wall
/// produces. The same guard `clipboard_image` puts on a pasted bitmap, for the
/// same reason: a bogus size must fail as "no capture", never as an allocation
/// the size of a metric read wrong.
const max_pixels: usize = 64 * 1024 * 1024;

/// The desktop's bounding box across every monitor, in physical pixels.
pub fn virtualScreenBounds() region.Rect {
    return .{
        .x = w32.GetSystemMetrics(w32.SM_XVIRTUALSCREEN),
        .y = w32.GetSystemMetrics(w32.SM_YVIRTUALSCREEN),
        .w = w32.GetSystemMetrics(w32.SM_CXVIRTUALSCREEN),
        .h = w32.GetSystemMetrics(w32.SM_CYVIRTUALSCREEN),
    };
}

/// One captured desktop: a 32-bit top-down DIB section holding every monitor,
/// plus where in virtual-screen coordinates its top-left corner sits.
///
/// The DIB is kept as a GDI object rather than as a plain buffer because the
/// selector BLITS out of it on every mouse move — a repaint of a 4K desktop has
/// to be a `BitBlt`, not a pixel loop — while `crop` reads the same memory
/// directly. `bits` is the section's own storage: it lives exactly as long as
/// `section` does, which is why `deinit` is the only thing allowed to free it.
pub const Snapshot = struct {
    section: w32.HANDLE,
    /// BGRA, top-down, `bounds.w * 4` bytes per row (a DIB section's stride is
    /// DWORD-aligned, and a 32-bit row already is).
    bits: [*]const u8,
    bounds: region.Rect,

    pub fn deinit(self: Snapshot) void {
        _ = w32.DeleteObject(self.section);
    }

    /// The PNG of `rect` (virtual-screen coordinates), or null when the rect
    /// does not survive clipping or the encode fails. Caller frees.
    pub fn crop(self: Snapshot, alloc: Allocator, rect: region.Rect) ?[]u8 {
        const clipped = region.clampTo(rect, self.bounds) orelse return null;
        const local = region.relativeTo(clipped, self.bounds);

        const w: usize = @intCast(local.w);
        const h: usize = @intCast(local.h);
        const stride: usize = @intCast(self.bounds.w);

        // BGRA in, RGB out: the same conversion `clipboard_image.normalize`
        // does, and for the same reason — the fourth byte of a GDI screen grab
        // is not an alpha anybody wrote, and honouring it turns a good
        // screenshot into a transparent rectangle.
        const rgb = alloc.alloc(u8, w * h * 3) catch return null;
        defer alloc.free(rgb);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const src_row = ((@as(usize, @intCast(local.y)) + y) * stride +
                @as(usize, @intCast(local.x))) * 4;
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const s = src_row + x * 4;
                const d = (y * w + x) * 3;
                rgb[d + 0] = self.bits[s + 2];
                rgb[d + 1] = self.bits[s + 1];
                rgb[d + 2] = self.bits[s + 0];
            }
        }

        return png_encode.encode(alloc, .{
            .data = rgb,
            .width = @intCast(w),
            .height = @intCast(h),
            .channels = .rgb,
        }) catch |err| {
            log.warn("screen capture: PNG encode failed ({s})", .{@errorName(err)});
            return null;
        };
    }
};

/// Photograph the whole desktop. Null only when there is nothing to photograph
/// (a nonsense virtual-screen size) or GDI refuses to give us a buffer.
///
/// A `BitBlt` that FAILS is deliberately not fatal: the section is
/// zero-initialised, so the caller gets a black desktop of the right size
/// instead of nothing at all. That is the honest result on a session with no
/// display surface to read — a background desktop, a locked workstation, a
/// remote session that has gone away — and it keeps a capture from being the
/// one action in the composer that can fail with no picture and no explanation.
pub fn capture() ?Snapshot {
    const bounds = virtualScreenBounds();
    if (bounds.w <= 0 or bounds.h <= 0) {
        log.warn("screen capture: virtual screen is {d}x{d}", .{ bounds.w, bounds.h });
        return null;
    }
    const pixels = @as(usize, @intCast(bounds.w)) * @as(usize, @intCast(bounds.h));
    if (pixels > max_pixels) {
        log.warn("screen capture: {d}x{d} is too large to capture", .{ bounds.w, bounds.h });
        return null;
    }

    const screen = w32.GetDC(null) orelse return null;
    defer _ = w32.ReleaseDC(null, screen);

    // Negative height: rows top-down, the order both the selector's blits and
    // the PNG encoder want, so nothing downstream has to flip.
    var bits_ptr: ?*anyopaque = null;
    const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = bounds.w,
        .biHeight = -bounds.h,
        .biBitCount = 32,
    } };
    const section = w32.CreateDIBSection(
        screen,
        &bmi,
        w32.DIB_RGB_COLORS,
        &bits_ptr,
        null,
        0,
    ) orelse return null;
    const bits: [*]const u8 = @ptrCast(bits_ptr orelse {
        _ = w32.DeleteObject(section);
        return null;
    });

    const mem = w32.CreateCompatibleDC(screen) orelse {
        _ = w32.DeleteObject(section);
        return null;
    };
    defer _ = w32.DeleteDC(mem);
    const old = w32.SelectObject(mem, section);
    defer _ = w32.SelectObject(mem, old);

    // CAPTUREBLT so layered windows are in the shot. Without it every one of
    // Ghoztty's own overlays — scrollbars, dim, banner cards — is missing from
    // a screenshot of Ghoztty, which is the most likely subject of all.
    if (w32.BitBlt(
        mem,
        0,
        0,
        bounds.w,
        bounds.h,
        screen,
        bounds.x,
        bounds.y,
        w32.SRCCOPY | w32.CAPTUREBLT,
    ) == 0) {
        log.warn("screen capture: BitBlt of the desktop failed; the shot is blank", .{});
    }

    return .{ .section = section, .bits = bits, .bounds = bounds };
}

// -------------------------------------------------------------------- tests
//
// These run in the WIN32 lane against the real desktop, because that is the
// only place the GDI half of this can be exercised at all. What they assert is
// deliberately CONTENT-FREE: a session with no display surface (a background
// desktop, a disconnected RDP session) legitimately photographs as black, and
// a test that demanded interesting pixels would be red for a reason that is
// not a defect. What is deterministic — and what the crop math can get wrong —
// is the GEOMETRY, so that is what is checked.

const testing = std.testing;
const images = @import("viewer_feedback_images.zig");

test "capture: a snapshot of the whole virtual screen, croppable to a PNG" {
    const bounds = virtualScreenBounds();
    if (bounds.w <= 0 or bounds.h <= 0) return error.SkipZigTest;

    const snap = capture() orelse return error.SkipZigTest;
    defer snap.deinit();

    try testing.expectEqual(bounds.x, snap.bounds.x);
    try testing.expectEqual(bounds.y, snap.bounds.y);
    try testing.expectEqual(bounds.w, snap.bounds.w);
    try testing.expectEqual(bounds.h, snap.bounds.h);

    // A crop inside the desktop comes back as a PNG of exactly that size —
    // the end of the path a dragged rectangle takes.
    const want: region.Rect = .{ .x = bounds.x + 3, .y = bounds.y + 5, .w = 17, .h = 11 };
    const png = snap.crop(testing.allocator, want) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(png);
    const size = images.pngSize(png) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 17), size.width);
    try testing.expectEqual(@as(u32, 11), size.height);
}

test "crop: clipped at the edges, and nothing at all off them" {
    const snap = capture() orelse return error.SkipZigTest;
    defer snap.deinit();
    const b = snap.bounds;

    // Hanging off the bottom-right corner: what survives is what is on screen,
    // and it must not read past the buffer.
    const over: region.Rect = .{ .x = b.right() - 4, .y = b.bottom() - 3, .w = 100, .h = 100 };
    const png = snap.crop(testing.allocator, over) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(png);
    const size = images.pngSize(png) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 4), size.width);
    try testing.expectEqual(@as(u32, 3), size.height);

    // Entirely off the desktop is no picture, not an empty one.
    try testing.expect(snap.crop(
        testing.allocator,
        .{ .x = b.right() + 10, .y = b.y, .w = 20, .h = 20 },
    ) == null);
    // And a zero-area rect never reaches the encoder either.
    try testing.expect(snap.crop(
        testing.allocator,
        .{ .x = b.x, .y = b.y, .w = 0, .h = 10 },
    ) == null);
}
