//! A solid GDI brush that follows a palette (T308).
//!
//! Both dialog panels used to create their brushes once, at window-class
//! registration, from constants: `bg_brush = CreateSolidBrush(COLOR_BG)`. That
//! is fine for a color that cannot change and wrong for one that can — a GDI
//! brush is immutable, so "the theme flipped" has to mean a NEW object, and a
//! process-lifetime handle made from the dark palette keeps painting the dark
//! palette forever.
//!
//! So the brush is keyed on the color it was made for: ask for the same color
//! and you get the same handle back (no churn on the paint path, which is the
//! reason these were hoisted out of `WM_PAINT` in the first place); ask for a
//! different one and the old object is deleted and replaced exactly once.
//!
//! Single-threaded by construction, like `system_colors`' accent cache: every
//! caller is on the UI thread inside a window procedure or a paint it drives.

const std = @import("std");
const w32 = @import("win32.zig");

/// A COLORREF is `0x00BBGGRR` — the top byte is zero for every real color, so
/// `0xFFFFFFFF` cannot be one and is safe as "nothing cached yet".
const no_color: u32 = 0xFFFFFFFF;

pub const CachedBrush = struct {
    handle: ?w32.HBRUSH = null,
    color: u32 = no_color,

    /// The brush for `color`, created on first use and whenever the color
    /// moves. Null only when GDI refuses to make one, which every caller
    /// already has to handle (the old code stored `?HBRUSH` for the same
    /// reason).
    pub fn get(self: *CachedBrush, color: u32) ?w32.HBRUSH {
        if (self.handle) |h| {
            if (self.color == color) return h;
            _ = w32.DeleteObject(@ptrCast(h));
            self.handle = null;
            self.color = no_color;
        }
        const h = w32.CreateSolidBrush(color) orelse return null;
        self.handle = h;
        self.color = color;
        return h;
    }

    /// Drop the cached object. Not needed at process exit (Windows reclaims
    /// GDI objects with the process) — it exists so a test can prove the
    /// replacement path deletes rather than leaks.
    pub fn deinit(self: *CachedBrush) void {
        if (self.handle) |h| _ = w32.DeleteObject(@ptrCast(h));
        self.handle = null;
        self.color = no_color;
    }
};

test "CachedBrush: same color reuses the handle, a new color replaces it" {
    const testing = std.testing;
    var b: CachedBrush = .{};
    defer b.deinit();

    const first = b.get(w32.RGB(32, 32, 32));
    try testing.expect(first != null);
    // The point of the cache: a paint path asking again must not allocate.
    try testing.expectEqual(first, b.get(w32.RGB(32, 32, 32)));

    // ...and the point of the invalidation: a theme flip must not keep
    // painting the old color.
    const second = b.get(w32.RGB(243, 243, 243));
    try testing.expect(second != null);
    try testing.expect(second.? != first.?);
    try testing.expectEqual(second, b.get(w32.RGB(243, 243, 243)));
}

test "CachedBrush: an untouched cache has nothing to delete" {
    var b: CachedBrush = .{};
    b.deinit();
    b.deinit();
    try std.testing.expect(b.handle == null);
}
