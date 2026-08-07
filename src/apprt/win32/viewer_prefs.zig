//! Persisted viewer chrome preferences (T160): the side-panel card width.
//!
//! A chrome preference rather than a property of any one document or window,
//! so it lives in its own small file and applies to every viewer pane — the
//! same way a sidebar width behaves in a document app, and unlike a split
//! ratio, which is per-window by nature. Mac stores the same number in
//! UserDefaults under `ViewerTOCCardWidth`; this is the `window_memory.zig`
//! pattern (one tiny text file under `%LOCALAPPDATA%\ghoztty`), which is
//! where win32 keeps such preferences — deliberately NOT the session-layout
//! manifest, which restores windows, not user taste.
//!
//! The parse/format/clamp logic is pure so its unit tests run in every
//! app-runtime lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const toc_layout = @import("viewer_toc_layout.zig");

/// Parse the persisted card width (whole DIP). Returns null on malformed or
/// out-of-range input — the caller then uses the design default, exactly as
/// if the file did not exist.
pub fn parseWidth(text: []const u8) ?f32 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const s = it.next() orelse return null;
    if (it.next() != null) return null;
    const v = std.fmt.parseInt(i32, s, 10) catch return null;
    const f: f32 = @floatFromInt(v);
    if (f < toc_layout.card_min_dip or f > toc_layout.card_max_dip) return null;
    return f;
}

/// Format a card width for the file. Stored as whole DIP: sub-pixel width
/// preferences are noise, and an integer file cannot half-parse.
pub fn formatWidth(buf: []u8, width_dip: f32) []const u8 {
    const v: i32 = @intFromFloat(@round(width_dip));
    return std.fmt.bufPrint(buf, "{d}\n", .{v}) catch unreachable;
}

pub const FORMAT_BUF_LEN: usize = 16;

fn widthPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    // Debug builds get their own file (the debug-IPC-pipe coexistence
    // pattern) so dev/test panes never move the release app's card.
    const name = if (builtin.mode == .Debug)
        "viewer_sidepanel_width-debug"
    else
        "viewer_sidepanel_width";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// The card width to use: the persisted preference, else the design default.
pub fn loadWidth(alloc: Allocator) f32 {
    const path = widthPath(alloc) orelse return toc_layout.card_default_dip;
    defer alloc.free(path);
    const f = std.fs.cwd().openFile(path, .{}) catch return toc_layout.card_default_dip;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return toc_layout.card_default_dip;
    return parseWidth(buf[0..n]) orelse toc_layout.card_default_dip;
}

/// Persist a card width. Best-effort: a preference is never worth an error
/// dialog.
pub fn saveWidth(alloc: Allocator, width_dip: f32) void {
    const path = widthPath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(formatWidth(&buf, width_dip)) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseWidth: valid, tolerant of whitespace" {
    try testing.expectEqual(@as(?f32, 240), parseWidth("240\n"));
    try testing.expectEqual(@as(?f32, 170), parseWidth("  170 \r\n"));
    try testing.expectEqual(@as(?f32, 460), parseWidth("460"));
}

test "parseWidth: malformed and out-of-range rejected" {
    try testing.expectEqual(@as(?f32, null), parseWidth(""));
    try testing.expectEqual(@as(?f32, null), parseWidth("abc"));
    try testing.expectEqual(@as(?f32, null), parseWidth("240 240"));
    try testing.expectEqual(@as(?f32, null), parseWidth("240.5"));
    // Outside the draggable range means a corrupt or hand-edited file.
    try testing.expectEqual(@as(?f32, null), parseWidth("169"));
    try testing.expectEqual(@as(?f32, null), parseWidth("461"));
    try testing.expectEqual(@as(?f32, null), parseWidth("-240"));
}

test "formatWidth round-trips through parseWidth" {
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    try testing.expectEqual(@as(?f32, 240), parseWidth(formatWidth(&buf, 240)));
    try testing.expectEqual(@as(?f32, 313), parseWidth(formatWidth(&buf, 312.7)));
    try testing.expectEqual(@as(?f32, 170), parseWidth(formatWidth(&buf, 170)));
}
