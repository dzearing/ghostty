//! Hovered-frame capture (T282): the pure half of the debug-only
//! `capture-hover` IPC action — argument parsing, the client/non-client
//! routing decision, the `lparam` point packing, and the pixel transform that
//! turns a `PrintWindow` DIB into something `png_encode` accepts.
//!
//! ## The problem this exists for
//!
//! Every hover FILL in the win32 chrome was unassertable in pixels, and three
//! tasks paid for it separately (T233 split divider, T209 the tab close "×"
//! and the banner chevron, and by extension anything else the design system
//! says must light on hover). The reason is an ORDERING one, not a timing one:
//!
//!   * the acceptance suite runs on a BACKGROUND desktop, where there is no
//!     real cursor, so `TrackMouseEvent` — which watches the real cursor —
//!     makes the OS post `WM_MOUSELEAVE` within a frame of every posted
//!     `WM_MOUSEMOVE`;
//!   * `WM_PAINT` is the LOWEST-priority message in a thread's queue, so the
//!     posted leave is always drained BEFORE the paint the move dirtied.
//!
//! So the hovered frame is never painted at all. T209 measured 300 posted
//! moves in bursts of 25, interleaved with `PrintWindow` captures, and never
//! once caught a lit fill — not on the close "×", not on the "+" that has lit
//! a fill since long before T204. No faster capture wins that race, because it
//! is not a race.
//!
//! ## The fix, and why the guarantee is a guarantee
//!
//! The app does the whole probe itself, inside ONE handler on the GUI thread:
//! hit-test the point, SEND the move (a sent message is a direct call to the
//! window procedure when sender and target share a thread), force the repaint
//! with `RedrawWindow(RDW_UPDATENOW)` (also synchronous), and `PrintWindow`
//! the result. The thread never returns to its message loop between the move
//! and the capture, and a POSTED message is only ever drained by the message
//! loop — so the `WM_MOUSELEAVE` the move armed cannot land in the middle. The
//! ordering is a property of who is on the stack, not of how fast anything is.
//!
//! Nothing has to be un-done afterwards: the leave arrives on the next pump
//! and clears the hover exactly as it does today, so the probe leaves no
//! latched state behind for the next assertion to trip over. That is the whole
//! reason this is a capture rather than a "hold the hover" flag.
//!
//! ## What is pure and what is not
//!
//! Everything in this file is arithmetic and string work, so it asserts in the
//! `-Dapp-runtime=none` lane. The five Win32 calls that make up the actual
//! probe live in `ipc_hover.zig`, which is where the ordering above is
//! sequenced.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest window dimension accepted. A capture allocates `w*h*4` for the DIB
/// plus `w*h*3` for the RGB it becomes; a window reporting more than this is a
/// metric read wrong, not a request.
pub const max_dimension: i32 = 16384;

pub const Error = error{
    /// `--hwnd=` was absent, empty, zero, or not a number.
    BadHwnd,
    /// `--path=` was absent or empty.
    MissingPath,
    /// `--x=`/`--y=` was absent or not a number.
    BadCoord,
};

/// A parsed `capture-hover` request.
///
/// `x`/`y` are SCREEN coordinates — the same space `Send-TestMouse` takes and
/// the same math every migrated pixel probe already does with `GetWindowRect`.
/// The conversion to client coordinates happens on the client path only, which
/// is exactly what the harness does, so a caller never has to know which path
/// its point will take.
pub const Request = struct {
    hwnd: usize,
    x: i32,
    y: i32,
    path: []const u8,
    /// Force the CLIENT message even where the window hit-tests the point as
    /// non-client — the server-side twin of `Send-TestMouse -Client`, for a
    /// probe whose subject IS that path.
    client_only: bool = false,
};

/// Parse the argument vector of a `capture-hover` request.
///
/// Unknown arguments are IGNORED rather than refused, matching every other
/// verb the win32 server handles (see `pane_capture.parse` for why).
pub fn parse(args: ?[]const []const u8) Error!Request {
    var hwnd: ?usize = null;
    var x: ?i32 = null;
    var y: ?i32 = null;
    var path: ?[]const u8 = null;
    var client_only = false;

    if (args) |list| for (list) |arg| {
        if (drop(arg, "--hwnd=")) |v| {
            hwnd = std.fmt.parseInt(usize, v, 10) catch return Error.BadHwnd;
        } else if (drop(arg, "--x=")) |v| {
            x = std.fmt.parseInt(i32, v, 10) catch return Error.BadCoord;
        } else if (drop(arg, "--y=")) |v| {
            y = std.fmt.parseInt(i32, v, 10) catch return Error.BadCoord;
        } else if (drop(arg, "--path=")) |v| {
            path = v;
        } else if (std.mem.eql(u8, arg, "--client")) {
            client_only = true;
        }
    };

    const h = hwnd orelse return Error.BadHwnd;
    if (h == 0) return Error.BadHwnd;
    const p = path orelse return Error.MissingPath;
    if (p.len == 0) return Error.MissingPath;

    return .{
        .hwnd = h,
        .x = x orelse return Error.BadCoord,
        .y = y orelse return Error.BadCoord,
        .path = p,
        .client_only = client_only,
    };
}

fn drop(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return arg[prefix.len..];
}

// Hit-test answers this module has to reason about. Duplicated from `win32.zig`
// rather than imported so this file stays OS-free and asserts in the none lane;
// they are ABI constants and cannot drift.
const HTNOWHERE: i32 = 0;
const HTCLIENT: i32 = 1;
const HTTRANSPARENT: i32 = -1;
const HTERROR: i32 = -2;

/// Does a `WM_NCHITTEST` answer mean the NON-CLIENT twin of a mouse message?
///
/// The rule mirrors `Send-TestMouse`'s (T263) exactly, including the three
/// answers that are deliberately NOT converted: `HTNOWHERE`, `HTTRANSPARENT`
/// and `HTERROR` all mean "not me", which is a z-order question this probe
/// does not ask — it aims at the hwnd the caller NAMED.
pub fn isNonClient(code: i32) bool {
    return code != HTCLIENT and code != HTNOWHERE and
        code != HTTRANSPARENT and code != HTERROR;
}

/// Pack a point into a mouse message's `lparam`: x in the low word, y in the
/// high word, both as SIGNED 16-bit.
///
/// The truncation is the point rather than an accident: a window on a monitor
/// left of or above the primary one has negative screen coordinates, and
/// `MAKELPARAM` has always carried them as `i16`. Building the word from the
/// unsigned value instead sets the sign bit of the OTHER field and lands the
/// probe on a coordinate nobody named.
pub fn packPoint(x: i32, y: i32) isize {
    const lo: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
    const hi: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
    return @as(isize, @as(i32, @bitCast((hi << 16) | lo)));
}

pub const Size = struct { w: u32, h: u32 };

/// The size a capture is taken at: the window's own rect, refused when it is
/// empty (a window mid-layout, or one that has been destroyed under us) or
/// beyond `max_dimension`.
pub fn resolveSize(win_w: i32, win_h: i32) ?Size {
    if (win_w <= 0 or win_h <= 0) return null;
    if (win_w > max_dimension or win_h > max_dimension) return null;
    return .{ .w = @intCast(win_w), .h = @intCast(win_h) };
}

/// Byte length of the 32-bit DIB `PrintWindow` writes for this size.
pub fn dibLen(size: Size) usize {
    return @as(usize, size.w) * @as(usize, size.h) * 4;
}

/// Byte length of the RGB image that DIB becomes.
pub fn rgbLen(size: Size) usize {
    return @as(usize, size.w) * @as(usize, size.h) * 3;
}

/// The BGRA the capture surface is pre-filled with before `PrintWindow`, so
/// "the window drew nothing" is distinguishable from "the window drew this".
///
/// The same magenta `TestDesktop.ps1` uses for its own synchronous capture, and
/// for the same reason: nothing in the win32 chrome paints it, so a surface
/// still holding it everywhere means the paint never happened. Alpha is
/// deliberately not part of it — a GDI paint leaves the fourth byte at whatever
/// it feels like, which is why `toRgb` drops it (T845).
pub const sentinel_bgr = [3]u8{ 0xFF, 0x00, 0xFF }; // B, G, R

/// Pre-fill a 32-bit DIB with `sentinel_bgr`.
pub fn fillSentinel(dib: []u8) void {
    var i: usize = 0;
    while (i + 4 <= dib.len) : (i += 4) {
        dib[i + 0] = sentinel_bgr[0];
        dib[i + 1] = sentinel_bgr[1];
        dib[i + 2] = sentinel_bgr[2];
        dib[i + 3] = 0;
    }
}

/// Did `PrintWindow` leave the surface exactly as `fillSentinel` left it?
///
/// Every pixel is examined rather than a grid sampled: the answer decides
/// whether the caller gets an error or a picture, and a grid that happens to
/// miss the one drawn region turns a real capture into a refusal. A full pass
/// over the DIB is already paid once by `toRgb`, so paying it twice is noise
/// next to the `PrintWindow` call itself.
pub fn allSentinel(dib: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= dib.len) : (i += 4) {
        if (dib[i + 0] != sentinel_bgr[0] or
            dib[i + 1] != sentinel_bgr[1] or
            dib[i + 2] != sentinel_bgr[2]) return false;
    }
    return true;
}

/// Convert a TOP-DOWN BGRA DIB into the top-down RGB `png_encode` takes.
///
/// Top-down in and top-down out, unlike `pane_capture.toRgbTopDown`: the DIB
/// section is created with a NEGATIVE height, so `PrintWindow` writes rows in
/// the order the encoder wants and nothing has to flip. The fourth byte is
/// dropped for the reason `screen_capture.crop` and
/// `clipboard_image.normalize` drop theirs — a GDI window grab's alpha is not
/// an alpha anybody wrote, and honouring it turns a good capture into a
/// transparent rectangle.
pub fn toRgb(dst: []u8, src: []const u8, size: Size) error{BadPixels}!void {
    if (dst.len != rgbLen(size) or src.len != dibLen(size)) return error.BadPixels;
    const n: usize = @as(usize, size.w) * @as(usize, size.h);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = i * 4;
        const d = i * 3;
        dst[d + 0] = src[s + 2]; // R
        dst[d + 1] = src[s + 1]; // G
        dst[d + 2] = src[s + 0]; // B
    }
}

/// Allocating form of `toRgb`. Caller frees.
pub fn allocRgb(
    alloc: Allocator,
    src: []const u8,
    size: Size,
) (Allocator.Error || error{BadPixels})![]u8 {
    const dst = try alloc.alloc(u8, rgbLen(size));
    errdefer alloc.free(dst);
    try toRgb(dst, src, size);
    return dst;
}

// -----------------------------------------------------------------------
// Tests (none lane)
// -----------------------------------------------------------------------

test "parse: hwnd, both coordinates and a path are all required" {
    const testing = std.testing;
    try testing.expectError(Error.BadHwnd, parse(null));
    try testing.expectError(Error.BadHwnd, parse(&.{ "--x=1", "--y=2", "--path=a.png" }));
    try testing.expectError(Error.BadHwnd, parse(&.{ "--hwnd=0", "--x=1", "--y=2", "--path=a.png" }));
    try testing.expectError(Error.MissingPath, parse(&.{ "--hwnd=5", "--x=1", "--y=2" }));
    try testing.expectError(Error.MissingPath, parse(&.{ "--hwnd=5", "--x=1", "--y=2", "--path=" }));
    try testing.expectError(Error.BadCoord, parse(&.{ "--hwnd=5", "--y=2", "--path=a.png" }));
    try testing.expectError(Error.BadCoord, parse(&.{ "--hwnd=5", "--x=1", "--path=a.png" }));
}

test "parse: a full request, and negative screen coordinates survive" {
    const testing = std.testing;
    const req = try parse(&.{ "--hwnd=123456", "--x=-1920", "--y=-40", "--path=C:\\t\\a.png" });
    try testing.expectEqual(@as(usize, 123456), req.hwnd);
    try testing.expectEqual(@as(i32, -1920), req.x);
    try testing.expectEqual(@as(i32, -40), req.y);
    try testing.expectEqualStrings("C:\\t\\a.png", req.path);
    try testing.expect(!req.client_only);
}

test "parse: --client forces the client path, and unknown flags are ignored" {
    const testing = std.testing;
    const req = try parse(&.{ "--hwnd=8", "--x=3", "--y=4", "--path=a.png", "--client", "--future=1" });
    try testing.expect(req.client_only);
    try testing.expectEqual(@as(i32, 3), req.x);
}

test "parse: a nonsense number is refused, not clamped" {
    const testing = std.testing;
    try testing.expectError(Error.BadHwnd, parse(&.{ "--hwnd=nope", "--x=1", "--y=2", "--path=a.png" }));
    try testing.expectError(Error.BadCoord, parse(&.{ "--hwnd=8", "--x=1.5", "--y=2", "--path=a.png" }));
}

test "isNonClient: the three not-me answers keep the client delivery" {
    const testing = std.testing;
    try testing.expect(!isNonClient(HTCLIENT));
    try testing.expect(!isNonClient(HTNOWHERE));
    try testing.expect(!isNonClient(HTTRANSPARENT));
    try testing.expect(!isNonClient(HTERROR));
    try testing.expect(isNonClient(2)); // HTCAPTION
    try testing.expect(isNonClient(8)); // HTMINBUTTON
    try testing.expect(isNonClient(20)); // HTCLOSE
}

test "packPoint: fields are 16-bit and negatives do not bleed across" {
    const testing = std.testing;
    try testing.expectEqual(@as(isize, 0x0004_0003), packPoint(3, 4));
    // -1 in the low word must leave the high word alone.
    try testing.expectEqual(@as(isize, 0x0002_FFFF), packPoint(-1, 2));
    // ...and a negative y must not spill into x.
    const p = packPoint(7, -1);
    try testing.expectEqual(@as(u16, 7), @as(u16, @truncate(@as(usize, @bitCast(p)))));
    try testing.expectEqual(@as(i16, -1), @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(p)) >> 16)))));
}

test "resolveSize: an empty or absurd window has no capture" {
    const testing = std.testing;
    try testing.expectEqual(@as(?Size, null), resolveSize(0, 100));
    try testing.expectEqual(@as(?Size, null), resolveSize(100, 0));
    try testing.expectEqual(@as(?Size, null), resolveSize(-5, 100));
    try testing.expectEqual(@as(?Size, null), resolveSize(100, max_dimension + 1));
    const s = resolveSize(800, 600).?;
    try testing.expectEqual(@as(u32, 800), s.w);
    try testing.expectEqual(@as(u32, 600), s.h);
}

test "toRgb: BGRA becomes RGB with the row order kept" {
    const testing = std.testing;
    const size: Size = .{ .w = 2, .h = 2 };
    // Row 0: red, green. Row 1: blue, white. BGRA, top-down.
    const src = [_]u8{
        0,   0,   255, 255, 0,   255, 0,   255,
        255, 0,   0,   255, 255, 255, 255, 255,
    };
    var dst: [12]u8 = undefined;
    try toRgb(&dst, &src, size);
    try testing.expectEqualSlices(u8, &.{
        255, 0,   0,   0,   255, 0,
        0,   0,   255, 255, 255, 255,
    }, &dst);
}

test "sentinel: a surface nothing drew into is still entirely sentinel" {
    const testing = std.testing;
    var dib: [4 * 4]u8 = undefined;
    fillSentinel(&dib);
    try testing.expect(allSentinel(&dib));
    // Alpha is not part of the comparison: a GDI paint scribbles it and that
    // must not read as "the window drew something".
    dib[3] = 0xFF;
    dib[7] = 0x7F;
    try testing.expect(allSentinel(&dib));
}

test "sentinel: one drawn pixel anywhere is enough to be a real capture" {
    const testing = std.testing;
    var dib: [4 * 64]u8 = undefined;
    fillSentinel(&dib);
    // The LAST pixel, which a sampling grid is exactly what would miss.
    dib[4 * 63 + 1] = 0x20;
    try testing.expect(!allSentinel(&dib));

    fillSentinel(&dib);
    dib[0] = 0x00; // first pixel's blue
    try testing.expect(!allSentinel(&dib));
}

test "toRgb: a short buffer is refused rather than partially filled" {
    const testing = std.testing;
    const size: Size = .{ .w = 2, .h = 2 };
    var dst: [12]u8 = undefined;
    const short = [_]u8{0} ** 8;
    try testing.expectError(error.BadPixels, toRgb(&dst, &short, size));
    var small: [6]u8 = undefined;
    const full = [_]u8{0} ** 16;
    try testing.expectError(error.BadPixels, toRgb(&small, &full, size));
}
