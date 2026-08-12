//! Pane-content capture (T275): the pure half of the debug-only
//! `capture-pane` IPC action — argument parsing, the size the capture is
//! taken at, and the pixel transform that turns the renderer's readback into
//! something `png_encode` accepts.
//!
//! ## What this exists for
//!
//! The win32 acceptance suite runs on a BACKGROUND desktop, where there is no
//! composite to `GetPixel` and `PrintWindow` of a `GhozttyTerminal` child
//! returns a flat fill — the harness's documented CAPTURE LIMIT
//! (`test/win32/test-desktop-harness.ps1`). So every assertion about what the
//! terminal GLASS is showing had to be dropped (T214): two
//! `Get-PaneColorCount` probes in `hero-mode.ps1`, and `window-color.ps1`'s
//! pane-centre tint. This is the fifth route T214 named and deliberately did
//! not build — the app asking its OWN renderer for the pixels, which needs no
//! desktop, no composite and no window visibility at all.
//!
//! ## Why it reuses hero mode's readback rather than adding one
//!
//! `Surface.heroSnap*` already has the pane's renderer thread blit its last
//! presented target into a downscaled FBO and `glReadPixels` it into a buffer
//! the GUI thread owns (`renderer/OpenGL.zig` `captureThumb`). That path is
//! already proven against a HIDDEN pane — hero mode's carousel thumbnails are
//! exactly that — which is the property this feature needs. A second GL
//! readback would be a second set of lifetime rules over the same texture, so
//! `Surface.captureContent` drives the same request slot and this module only
//! converts what comes out.
//!
//! ## The pixel shape, and why it is converted here
//!
//! `captureThumb` writes BOTTOM-UP BGRA — bottom-up because GL's readback
//! order matches a positive-height DIB, which is what let hero mode blit the
//! buffer with no flip (T58 decision 1). `png_encode` wants TOP-DOWN, and the
//! fourth byte of a GL readback of a terminal target is not an alpha anybody
//! wrote, so it is dropped exactly as `screen_capture` and
//! `clipboard_image.normalize` drop theirs. Both facts are pure arithmetic,
//! so they live here and assert in the `-Dapp-runtime=none` lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest capture dimension accepted. A capture allocates `w*h*4` for the
/// readback plus `w*h*3` for the RGB it becomes, and the renderer blits into
/// an offscreen renderbuffer of the same size — a caller asking for 100000 px
/// is a typo, not a request, and refusing it is cheaper than discovering the
/// allocation failure three layers down.
pub const max_dimension: u32 = 8192;

pub const Error = error{
    /// `--target=` was absent or empty.
    MissingTarget,
    /// `--path=` was absent or empty.
    MissingPath,
    /// `--width=`/`--height=` was not a number, was 0, or exceeded
    /// `max_dimension`.
    BadDimension,
};

/// A parsed `capture-pane` request. Sizes are OPTIONAL here and resolved
/// against the pane's own pixel size by `resolveSize` — a caller that names no
/// size wants the pane as it is, which is the common case and the one whose
/// numbers a test should not have to know.
pub const Request = struct {
    target: []const u8,
    path: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
};

/// Parse the argument vector of a `capture-pane` request.
///
/// Unknown arguments are IGNORED rather than refused, matching every other
/// verb the win32 server handles: a newer client sending a flag this build has
/// never heard of must not turn into a failed capture. (`+send-keys`'s
/// hard error on an unknown flag is the CLI's rule, not the server's, and it
/// exists because there a stray flag would be TYPED INTO the pane.)
pub fn parse(args: ?[]const []const u8) Error!Request {
    var target: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var width: ?u32 = null;
    var height: ?u32 = null;

    if (args) |list| for (list) |arg| {
        if (drop(arg, "--target=")) |v| {
            target = v;
        } else if (drop(arg, "--path=")) |v| {
            path = v;
        } else if (drop(arg, "--width=")) |v| {
            width = try dimension(v);
        } else if (drop(arg, "--height=")) |v| {
            height = try dimension(v);
        }
    };

    const t = target orelse return Error.MissingTarget;
    if (t.len == 0) return Error.MissingTarget;
    const p = path orelse return Error.MissingPath;
    if (p.len == 0) return Error.MissingPath;

    return .{ .target = t, .path = p, .width = width, .height = height };
}

fn drop(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return arg[prefix.len..];
}

fn dimension(text: []const u8) Error!u32 {
    const n = std.fmt.parseInt(u32, text, 10) catch return Error.BadDimension;
    if (n == 0 or n > max_dimension) return Error.BadDimension;
    return n;
}

pub const Size = struct { w: u32, h: u32 };

/// The size a capture is actually taken at: whatever the request named, else
/// the pane's own pixel size, clamped into [1, max_dimension].
///
/// A pane with a zero dimension (mid-layout, or collapsed to nothing) has no
/// content to capture and answers null rather than a 1x1 image nobody asked
/// for — a caller can tell "not laid out yet" from "here is one pixel", and
/// with a 1x1 it could not.
pub fn resolveSize(pane_w: i32, pane_h: i32, req: Request) ?Size {
    const w = pick(req.width, pane_w) orelse return null;
    const h = pick(req.height, pane_h) orelse return null;
    return .{ .w = w, .h = h };
}

fn pick(requested: ?u32, pane: i32) ?u32 {
    if (requested) |r| return @min(r, max_dimension);
    if (pane <= 0) return null;
    const n: u32 = @intCast(pane);
    return @min(n, max_dimension);
}

/// Byte length of the readback buffer for a capture of this size.
pub fn readbackLen(size: Size) usize {
    return @as(usize, size.w) * @as(usize, size.h) * 4;
}

/// Byte length of the RGB image the readback becomes.
pub fn rgbLen(size: Size) usize {
    return @as(usize, size.w) * @as(usize, size.h) * 3;
}

/// Convert a bottom-up BGRA readback into the top-down RGB `png_encode` takes.
///
/// `dst` must be `rgbLen(size)` and `src` `readbackLen(size)`; a mismatch is a
/// caller bug and is refused rather than partially filled, for the reason
/// `png_encode.Error.BadPixels` exists — an image that silently carries
/// whatever followed a short buffer in memory is worse than no image.
pub fn toRgbTopDown(dst: []u8, src: []const u8, size: Size) error{BadPixels}!void {
    if (dst.len != rgbLen(size) or src.len != readbackLen(size)) return error.BadPixels;
    const w: usize = size.w;
    const h: usize = size.h;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        // Row 0 of the output is the LAST row of the input: the readback is
        // bottom-up.
        const src_row = (h - 1 - y) * w * 4;
        const dst_row = y * w * 3;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const s = src_row + x * 4;
            const d = dst_row + x * 3;
            dst[d + 0] = src[s + 2]; // R
            dst[d + 1] = src[s + 1]; // G
            dst[d + 2] = src[s + 0]; // B
        }
    }
}

/// Allocating form of `toRgbTopDown`. Caller frees.
pub fn allocRgbTopDown(
    alloc: Allocator,
    src: []const u8,
    size: Size,
) (Allocator.Error || error{BadPixels})![]u8 {
    const dst = try alloc.alloc(u8, rgbLen(size));
    errdefer alloc.free(dst);
    try toRgbTopDown(dst, src, size);
    return dst;
}

// -----------------------------------------------------------------------
// Tests (none lane)
// -----------------------------------------------------------------------

test "parse: target and path are both required" {
    const testing = std.testing;
    try testing.expectError(Error.MissingTarget, parse(null));
    try testing.expectError(Error.MissingTarget, parse(&.{"--path=a.png"}));
    try testing.expectError(Error.MissingPath, parse(&.{"--target=t"}));
    // Present-but-empty is absent: `--target=` names no pane.
    try testing.expectError(Error.MissingTarget, parse(&.{ "--target=", "--path=a.png" }));
    try testing.expectError(Error.MissingPath, parse(&.{ "--target=t", "--path=" }));
}

test "parse: sizes are optional and default to absent" {
    const testing = std.testing;
    const req = try parse(&.{ "--target=logs", "--path=C:\\tmp\\a.png" });
    try testing.expectEqualStrings("logs", req.target);
    try testing.expectEqualStrings("C:\\tmp\\a.png", req.path);
    try testing.expect(req.width == null);
    try testing.expect(req.height == null);

    const sized = try parse(&.{ "--target=t", "--path=p", "--width=64", "--height=32" });
    try testing.expectEqual(@as(?u32, 64), sized.width);
    try testing.expectEqual(@as(?u32, 32), sized.height);
}

test "parse: a nonsense dimension is refused, not clamped" {
    const testing = std.testing;
    try testing.expectError(Error.BadDimension, parse(&.{ "--target=t", "--path=p", "--width=0" }));
    try testing.expectError(Error.BadDimension, parse(&.{ "--target=t", "--path=p", "--width=x" }));
    try testing.expectError(Error.BadDimension, parse(&.{ "--target=t", "--path=p", "--height=-4" }));
    try testing.expectError(Error.BadDimension, parse(&.{ "--target=t", "--path=p", "--height=99999" }));
}

test "parse: an unknown flag is ignored, not fatal" {
    // A newer client's flag must not turn into a failed capture.
    const testing = std.testing;
    const req = try parse(&.{ "--target=t", "--from-the-future=1", "--path=p" });
    try testing.expectEqualStrings("t", req.target);
    try testing.expectEqualStrings("p", req.path);
}

test "resolveSize: the pane's own size is the default" {
    const testing = std.testing;
    const req = try parse(&.{ "--target=t", "--path=p" });
    try testing.expectEqual(Size{ .w = 800, .h = 600 }, resolveSize(800, 600, req).?);
}

test "resolveSize: an explicit size wins, and clamps" {
    const testing = std.testing;
    const req = try parse(&.{ "--target=t", "--path=p", "--width=40", "--height=20" });
    try testing.expectEqual(Size{ .w = 40, .h = 20 }, resolveSize(800, 600, req).?);

    // One axis given, the other from the pane.
    const half = try parse(&.{ "--target=t", "--path=p", "--width=40" });
    try testing.expectEqual(Size{ .w = 40, .h = 600 }, resolveSize(800, 600, half).?);

    // A pane larger than the cap is clamped rather than refused: the pane's
    // size is not something the caller chose.
    try testing.expectEqual(
        Size{ .w = max_dimension, .h = 600 },
        resolveSize(max_dimension + 500, 600, try parse(&.{ "--target=t", "--path=p" })).?,
    );
}

test "resolveSize: a pane with no area is null, not a 1x1 image" {
    const testing = std.testing;
    const req = try parse(&.{ "--target=t", "--path=p" });
    try testing.expect(resolveSize(0, 600, req) == null);
    try testing.expect(resolveSize(800, 0, req) == null);
    try testing.expect(resolveSize(-4, -4, req) == null);
}

test "toRgbTopDown: rows flip and BGRA becomes RGB" {
    const testing = std.testing;
    const size: Size = .{ .w = 2, .h = 2 };
    // Bottom-up: the first row here is the BOTTOM row of the image.
    const src = [_]u8{
        // bottom-left = blue, bottom-right = green   (B, G, R, A)
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        // top-left = red,    top-right = white
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
    };
    var dst: [12]u8 = undefined;
    try toRgbTopDown(&dst, &src, size);
    try testing.expectEqualSlices(u8, &[_]u8{
        // top row first
        0xFF, 0x00, 0x00, // red
        0xFF, 0xFF, 0xFF, // white — and its zero alpha is dropped, not honoured
        0x00, 0x00, 0xFF, // blue
        0x00, 0xFF, 0x00, // green
    }, &dst);
}

test "toRgbTopDown: a short buffer is refused" {
    const testing = std.testing;
    const size: Size = .{ .w = 2, .h = 2 };
    var dst: [12]u8 = undefined;
    var small: [8]u8 = undefined;
    try testing.expectError(error.BadPixels, toRgbTopDown(&dst, &small, size));
    var big: [16]u8 = undefined;
    try testing.expectError(error.BadPixels, toRgbTopDown(dst[0..9], &big, size));
}

test "allocRgbTopDown: round-trips a single pixel" {
    const testing = std.testing;
    const size: Size = .{ .w = 1, .h = 1 };
    const src = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const rgb = try allocRgbTopDown(testing.allocator, &src, size);
    defer testing.allocator.free(rgb);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x22, 0x11 }, rgb);
}

test "readbackLen/rgbLen agree with the buffers they describe" {
    const testing = std.testing;
    const size: Size = .{ .w = 7, .h = 5 };
    try testing.expectEqual(@as(usize, 7 * 5 * 4), readbackLen(size));
    try testing.expectEqual(@as(usize, 7 * 5 * 3), rgbLen(size));
}
