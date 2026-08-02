//! A viewer pane: a split-tree leaf that renders CONTENT (a markdown/text
//! file or a website) instead of a terminal. CLAUDE.md's "Viewer Panes"
//! section is the cross-platform contract; this is the win32 half.
//!
//! **Scaffolding only (T90c).** This type exists so `PaneView` is the real
//! two-armed union the design pins (`docs/design/viewer-panes-windows.md`,
//! T90a §3) rather than a single-variant placeholder that T90d would have to
//! re-shape. It carries exactly the state every split-tree leaf must have to
//! be a normal tree citizen — an HWND, visibility, a title, a stable pane id,
//! and the SplitTree ref-count protocol — and nothing else. The WebView2 host,
//! the mode table, the resolver, and navigation land in T90d/T90e/T90f.
//!
//! Nothing constructs one yet: `PaneView.createTerminal` is the only
//! constructor T90c ships, so the `.viewer` arm of every accessor below is
//! reachable only from T90d onward.
const ViewerPane = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const pane_id_mod = @import("pane_id.zig");
const Window = @import("Window.zig");

/// The child window hosting this viewer's content. Null until the host
/// window is created (T90d).
hwnd: ?w32.HWND = null,

/// Owning window. Set at construction, like `Surface.parent_window`.
parent_window: *Window = undefined,

/// This pane's stable, ghoztty-owned identity (T113 contract). Generated at
/// construction so `+list --json` and `--target=<id>` work for viewer panes
/// exactly as they do for terminals.
pane_id: pane_id_mod.Buf = undefined,

/// Current title (file basename, or the document title in web mode). Owned;
/// freed in `deinit`.
title: ?[:0]u8 = null,

/// Where this pane currently IS. CLAUDE.md: `+list --json`'s `url` reports
/// the current location, not the one the pane was opened with. Owned.
location: ?[:0]u8 = null,

/// Where this pane was ORIGINALLY opened, which "home" returns to and which
/// the session manifest persists separately from `location`. Owned.
home_location: ?[:0]u8 = null,

/// Mirrors `Surface.visible`: false while the pane's tab is not selected or
/// the window is minimized.
visible: bool = true,

/// Allocate and initialize a viewer pane. The caller owns the returned
/// pointer until it is handed to a `PaneView`.
pub fn create(alloc: Allocator, parent: *Window) Allocator.Error!*ViewerPane {
    const self = try alloc.create(ViewerPane);
    self.* = .{ .parent_window = parent };
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    _ = pane_id_mod.format(&self.pane_id, bytes);
    return self;
}

pub fn deinit(self: *ViewerPane, alloc: Allocator) void {
    if (self.hwnd) |h| {
        _ = w32.DestroyWindow(h);
        self.hwnd = null;
    }
    if (self.title) |t| alloc.free(t);
    if (self.location) |l| alloc.free(l);
    if (self.home_location) |l| alloc.free(l);
    self.title = null;
    self.location = null;
    self.home_location = null;
}

/// This pane's stable id (T113).
pub fn paneId(self: *const ViewerPane) []const u8 {
    return &self.pane_id;
}

/// Mirror of `Surface.setVisible`. A viewer has no renderer thread to park,
/// so this only records the state and hides/shows the host window.
pub fn setVisible(self: *ViewerPane, visible: bool) void {
    if (self.visible == visible) return;
    self.visible = visible;
    if (self.hwnd) |h| {
        _ = w32.ShowWindow(h, if (visible) w32.SW_SHOW else w32.SW_HIDE);
    }
}

/// Replace the pane title. Dupes; the pane owns the copy.
pub fn setTitle(self: *ViewerPane, alloc: Allocator, value: []const u8) Allocator.Error!void {
    const dup = try alloc.dupeZ(u8, value);
    if (self.title) |t| alloc.free(t);
    self.title = dup;
}

test "viewer pane id is a valid pane id" {
    // Constructing needs a Window, which needs an app runtime; the id
    // formatting itself is what matters here and is pure.
    var buf: pane_id_mod.Buf = undefined;
    const id = pane_id_mod.format(&buf, [_]u8{7} ** 16);
    try std.testing.expect(pane_id_mod.isValid(id));
}
