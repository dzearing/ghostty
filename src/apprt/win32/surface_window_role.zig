//! T613: which of a Surface's windows a message just arrived for, and what a
//! `WM_DESTROY` on it is allowed to clear.
//!
//! One window procedure serves three different windows. A `*Surface` is stored
//! in the `GWLP_USERDATA` of its own terminal child HWND, of its search-bar
//! popup and of its command-palette popup, so `App.surfaceWndProc` runs for all
//! three and has to know which one it is looking at before it touches anything.
//!
//! Getting that wrong on `WM_DESTROY` is what crashed the app. The handler
//! cleared `Surface.hwnd` unconditionally, and `Surface.deinit` destroys the
//! two popups a few lines BEFORE it clears its own window's `GWLP_USERDATA`:
//!
//!   1. `DestroyWindow(palette_hwnd)` delivers `WM_DESTROY` synchronously,
//!   2. the handler sets `surface.hwnd = null` — the wrong window's field,
//!   3. `if (self.hwnd) |hwnd|` at the end of `deinit` therefore sees null, so
//!      the TERMINAL window keeps a `*Surface` that is freed moments later and
//!      its deferred reap (T681) is never posted either.
//!
//! Closing that window then dispatches `WM_DESTROY` through OPENGL32's
//! `wglWndProc` subclass into this procedure, which reads the freed pointer:
//! a hard segfault taking every other window and terminal in the process with
//! it. It needed nothing more exotic than having opened the command palette
//! (or the search bar) once during the window's life.
//!
//! Pure on purpose: the routing is asserted in the `none` lane, and the win32
//! caller supplies the four handles by reading its own fields.

const std = @import("std");

/// Which of the Surface's windows a handle names.
pub const Role = enum {
    /// The terminal child HWND itself — the one that owns the WGL context.
    surface,
    /// The search-bar popup (`Surface.search_hwnd`).
    search_popup,
    /// The command-palette popup (`Surface.palette_hwnd`).
    palette_popup,
    /// None of the above: the `*Surface` in this window's `GWLP_USERDATA` does
    /// not claim it, so nothing about it may be trusted.
    foreign,
};

/// The three handles a Surface stores, as plain integers so the classification
/// can be asserted without a Win32 handle. `null` for a window that does not
/// exist (yet, or any more).
pub const Windows = struct {
    surface: ?usize,
    search: ?usize,
    palette: ?usize,
};

/// Classify `hwnd` against the windows this Surface owns.
///
/// Precedence is surface → search → palette, which only matters if two fields
/// somehow held the same handle; the terminal window is the one whose state is
/// dangerous to get wrong, so it wins.
pub fn roleOf(w: Windows, hwnd: usize) Role {
    if (w.surface) |h| if (h == hwnd) return .surface;
    if (w.search) |h| if (h == hwnd) return .search_popup;
    if (w.palette) |h| if (h == hwnd) return .palette_popup;
    return .foreign;
}

/// Which of the Surface's fields a `WM_DESTROY` for this role must reset.
///
/// Every role clears the destroyed window's own `GWLP_USERDATA`: the pointer
/// is about to dangle, and for the terminal window that zero is also the second
/// factor `surface_reap.reapable` checks.
pub const DestroyClears = struct {
    /// `Surface.hwnd` and `Surface.core_surface_ready`.
    surface_window: bool = false,
    /// `Surface.search_hwnd`, `search_edit`, `search_count_label`.
    search_popup: bool = false,
    /// `Surface.palette_hwnd`, `palette_edit`.
    palette_popup: bool = false,
};

pub fn destroyClears(role: Role) DestroyClears {
    return switch (role) {
        .surface => .{ .surface_window = true },
        .search_popup => .{ .search_popup = true },
        .palette_popup => .{ .palette_popup = true },
        .foreign => .{},
    };
}

const H_SURFACE: usize = 0x1000;
const H_SEARCH: usize = 0x2000;
const H_PALETTE: usize = 0x3000;
const all: Windows = .{ .surface = H_SURFACE, .search = H_SEARCH, .palette = H_PALETTE };

test "roleOf: each of the three windows is told apart" {
    try std.testing.expectEqual(Role.surface, roleOf(all, H_SURFACE));
    try std.testing.expectEqual(Role.search_popup, roleOf(all, H_SEARCH));
    try std.testing.expectEqual(Role.palette_popup, roleOf(all, H_PALETTE));
}

test "roleOf: a handle this Surface does not own is foreign" {
    try std.testing.expectEqual(Role.foreign, roleOf(all, 0x9999));
}

test "roleOf: absent popups never match" {
    const bare: Windows = .{ .surface = H_SURFACE, .search = null, .palette = null };
    try std.testing.expectEqual(Role.surface, roleOf(bare, H_SURFACE));
    try std.testing.expectEqual(Role.foreign, roleOf(bare, H_SEARCH));
    try std.testing.expectEqual(Role.foreign, roleOf(bare, H_PALETTE));
}

test "roleOf: a Surface whose own window is already gone still routes its popups" {
    // The state `Surface.deinit` reaches after the terminal window's own
    // WM_DESTROY: hwnd is null, but the popups are still standing.
    const w: Windows = .{ .surface = null, .search = H_SEARCH, .palette = H_PALETTE };
    try std.testing.expectEqual(Role.search_popup, roleOf(w, H_SEARCH));
    try std.testing.expectEqual(Role.palette_popup, roleOf(w, H_PALETTE));
    try std.testing.expectEqual(Role.foreign, roleOf(w, H_SURFACE));
}

test "destroyClears: a popup's destruction never touches the surface window" {
    // The T613 regression, stated as the invariant it broke: destroying either
    // popup must leave `Surface.hwnd` alone, or `deinit` stops clearing the
    // terminal window's GWLP_USERDATA and stops posting its reap.
    try std.testing.expect(!destroyClears(.search_popup).surface_window);
    try std.testing.expect(!destroyClears(.palette_popup).surface_window);
    try std.testing.expect(destroyClears(.search_popup).search_popup);
    try std.testing.expect(destroyClears(.palette_popup).palette_popup);
}

test "destroyClears: the surface window clears only its own state" {
    const c = destroyClears(.surface);
    try std.testing.expect(c.surface_window);
    try std.testing.expect(!c.search_popup);
    try std.testing.expect(!c.palette_popup);
}

test "destroyClears: a foreign window clears nothing" {
    const c = destroyClears(.foreign);
    try std.testing.expect(!c.surface_window);
    try std.testing.expect(!c.search_popup);
    try std.testing.expect(!c.palette_popup);
}
