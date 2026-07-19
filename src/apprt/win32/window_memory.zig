//! Window placement memory (T85): persist the last user-chosen outer
//! window size (and maximized state) so new windows open at that size.
//!
//! This is the Windows-native analog of macOS frame autosave / GTK
//! window-save-state. Precedence for a new window's size:
//!
//!   explicit `window-width`/`window-height` config (core sends
//!   `initial_size`)  >  remembered placement  >  built-in default.
//!
//! Decisions (recorded for T85):
//! - Only SIZE is remembered, not position — window position is governed
//!   by `window-position-x/y` config and the cascade logic in Window.init.
//! - The memory updates ONLY on user-interactive changes (drag resize via
//!   WM_EXITSIZEMOVE, maximize/restore transitions). Programmatic resizes
//!   (`initial_size`, `reset_window_size`) never write it, so
//!   `reset_window_size` stays the escape hatch that returns to the
//!   config/default size without disturbing the memory.
//! - Quick-terminal windows neither read nor write the memory.
//!
//! Storage: one small text file, `%LOCALAPPDATA%\ghoztty\window_placement`
//! (same area as `update_check_at`), format: `<width> <height> <0|1>\n`
//! (outer pixels, maximized flag).
//!
//! The parse/format/clamp logic below is pure (no OS imports) so its unit
//! tests run in every app-runtime lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Sanity bounds for a remembered outer size, in pixels. Values outside
/// this range mean a corrupt/hand-edited file and are rejected.
pub const MIN_DIM: i32 = 200;
pub const MAX_DIM: i32 = 30000;

pub const Placement = struct {
    /// Outer (window rect) size in pixels.
    width: i32,
    height: i32,
    maximized: bool,
};

/// Parse the persisted placement file content. Returns null on any
/// malformed or out-of-bounds input.
pub fn parse(text: []const u8) ?Placement {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const w_s = it.next() orelse return null;
    const h_s = it.next() orelse return null;
    const m_s = it.next() orelse return null;
    if (it.next() != null) return null;

    const w = std.fmt.parseInt(i32, w_s, 10) catch return null;
    const h = std.fmt.parseInt(i32, h_s, 10) catch return null;
    if (w < MIN_DIM or w > MAX_DIM) return null;
    if (h < MIN_DIM or h > MAX_DIM) return null;

    const m = if (std.mem.eql(u8, m_s, "1"))
        true
    else if (std.mem.eql(u8, m_s, "0"))
        false
    else
        return null;

    return .{ .width = w, .height = h, .maximized = m };
}

/// Format a placement into `buf` in the on-disk format.
pub fn format(buf: []u8, p: Placement) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {d} {d}\n", .{
        p.width,
        p.height,
        @as(u1, if (p.maximized) 1 else 0),
    }) catch unreachable; // 3 bounded ints always fit the caller's buffer
}

/// Clamp a remembered size to a monitor work area so a size remembered on
/// a large monitor never opens a window bigger than the current one.
/// Non-positive work-area dims (query failed) leave the size unchanged.
pub fn clampToWorkArea(p: Placement, work_w: i32, work_h: i32) Placement {
    var out = p;
    if (work_w >= MIN_DIM and out.width > work_w) out.width = work_w;
    if (work_h >= MIN_DIM and out.height > work_h) out.height = work_h;
    return out;
}

/// Buffer size that always fits a formatted placement.
pub const FORMAT_BUF_LEN: usize = 32;

fn placementPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    // Debug builds get their own file (same coexistence pattern as the
    // debug IPC pipe) so test/dev windows never pollute the release
    // app's remembered size.
    const name = if (builtin.mode == .Debug)
        "window_placement-debug"
    else
        "window_placement";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// Load the remembered placement, or null if absent/corrupt.
pub fn load(alloc: Allocator) ?Placement {
    const path = placementPath(alloc) orelse return null;
    defer alloc.free(path);
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    return parse(buf[0..n]);
}

/// Persist a placement. Best-effort: failures are silently ignored (the
/// memory is a convenience, never worth an error dialog).
pub fn save(alloc: Allocator, p: Placement) void {
    const path = placementPath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(format(&buf, p)) catch {};
}

test "parse: valid" {
    const t = std.testing;
    try t.expectEqual(
        Placement{ .width = 1280, .height = 720, .maximized = false },
        parse("1280 720 0\n").?,
    );
    try t.expectEqual(
        Placement{ .width = 800, .height = 600, .maximized = true },
        parse("800 600 1").?,
    );
    // Tolerant of extra whitespace/CRLF.
    try t.expectEqual(
        Placement{ .width = 640, .height = 480, .maximized = false },
        parse("  640\t480  0\r\n").?,
    );
}

test "parse: malformed" {
    const t = std.testing;
    try t.expectEqual(@as(?Placement, null), parse(""));
    try t.expectEqual(@as(?Placement, null), parse("1280 720"));
    try t.expectEqual(@as(?Placement, null), parse("1280 720 0 9"));
    try t.expectEqual(@as(?Placement, null), parse("abc 720 0"));
    try t.expectEqual(@as(?Placement, null), parse("1280 720 2"));
    try t.expectEqual(@as(?Placement, null), parse("1280 720 true"));
}

test "parse: bounds" {
    const t = std.testing;
    try t.expectEqual(@as(?Placement, null), parse("199 720 0"));
    try t.expectEqual(@as(?Placement, null), parse("1280 199 0"));
    try t.expectEqual(@as(?Placement, null), parse("30001 720 0"));
    try t.expectEqual(@as(?Placement, null), parse("-500 720 0"));
    // Exactly on the bounds is accepted.
    try t.expect(parse("200 200 0") != null);
    try t.expect(parse("30000 30000 1") != null);
}

test "format round-trips through parse" {
    const t = std.testing;
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const cases = [_]Placement{
        .{ .width = 1280, .height = 720, .maximized = false },
        .{ .width = 200, .height = 30000, .maximized = true },
    };
    for (cases) |p| {
        try t.expectEqual(p, parse(format(&buf, p)).?);
    }
}

test "clampToWorkArea" {
    const t = std.testing;
    const big = Placement{ .width = 3840, .height = 2160, .maximized = false };
    // Clamped to a smaller work area.
    try t.expectEqual(
        Placement{ .width = 1920, .height = 1040, .maximized = false },
        clampToWorkArea(big, 1920, 1040),
    );
    // Fits: unchanged.
    const small = Placement{ .width = 800, .height = 600, .maximized = true };
    try t.expectEqual(small, clampToWorkArea(small, 1920, 1040));
    // Bogus work area (query failed): unchanged.
    try t.expectEqual(big, clampToWorkArea(big, 0, 0));
    try t.expectEqual(big, clampToWorkArea(big, -1, -1));
}
