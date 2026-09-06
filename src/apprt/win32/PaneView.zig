//! The win32 split tree's leaf type: a pane is EITHER a terminal or a
//! viewer (`docs/design/viewer-panes-windows.md`; T90a §3, T90c).
//!
//! Before this the tree was `SplitTree(Surface)`, which made "leaf" and
//! "terminal" the same word. Retyping it to `SplitTree(PaneView)` is what
//! lets a viewer be a normal tree citizen — it resizes, focuses, zooms,
//! closes and persists through exactly the same code paths, with no
//! per-action bypass (Mac's `BaseTerminalController` needed one; win32's
//! split management is leaf-kind-agnostic pure Zig, so it does not).
//!
//! Ownership. The tree stores `*PaneView` and drives the SplitTree view
//! protocol (`ref`/`unref`/`eql`) against it, so PaneView carries the
//! reference count the tree manipulates and owns the leaf underneath:
//!
//!   * `.terminal` — the PaneView holds ONE reference on the Surface
//!     (taken in `createTerminal`, released when the PaneView's own count
//!     reaches zero). Surface keeps its own counter so its existing
//!     teardown — hide, deinit, destroy — is unchanged.
//!   * `.viewer` — the PaneView owns the ViewerPane outright.
//!
//! Each Surface keeps a back-pointer to its PaneView (`Surface.pane_view`)
//! so the destroy paths that only have a `*Surface` (IPC registry forget)
//! can still name the leaf.
//!
//! Kind-generic accessors below are what the tree call sites use: layout,
//! visibility, z-order healing and close-intent all work on any pane. The
//! terminal-only ones (`surface()`, `terminal()`) make the narrowing
//! explicit at the sites that genuinely need a terminal.
const PaneView = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const RefCount = @import("pane_refcount.zig").RefCount;
const Surface = @import("Surface.zig");
const ViewerPane = @import("ViewerPane.zig");
const Window = @import("Window.zig");
const session_disconnect = @import("session_disconnect.zig");


pub const Kind = enum { terminal, viewer };

kind: union(Kind) {
    terminal: *Surface,
    viewer: *ViewerPane,
},

/// Reference count for SplitTree ownership. Starts at 0 because
/// `SplitTree.init`/`split` call `ref()` to take the first reference,
/// exactly as `Surface.ref_count` used to. The arithmetic — and the
/// underflow rule that keeps a failed-into-the-tree pane from leaking — lives
/// in `pane_refcount.zig`, which is unit-tested in every lane (T371).
ref_count: RefCount = .{},

/// Wrap an existing Surface as a terminal pane. Takes one reference on the
/// surface, which is released when this PaneView is freed. The surface's
/// back-pointer is set here so `Surface` destroy paths can find the leaf.
pub fn createTerminal(alloc: Allocator, s: *Surface) Allocator.Error!*PaneView {
    const self = try alloc.create(PaneView);
    errdefer alloc.destroy(self);
    self.* = .{ .kind = .{ .terminal = try s.ref(alloc) } };
    s.pane_view = self;
    return self;
}

/// Wrap an existing ViewerPane. Takes ownership outright. The back-pointer is
/// set here for the reason the terminal arm's is: a title arriving at the pane
/// has to name a LEAF to the window (T383).
pub fn createViewer(alloc: Allocator, v: *ViewerPane) Allocator.Error!*PaneView {
    const self = try alloc.create(PaneView);
    self.* = .{ .kind = .{ .viewer = v } };
    v.pane_view = self;
    return self;
}

// -------------------------------------------------------------------------
// SplitTree view protocol
// -------------------------------------------------------------------------

/// SplitTree view protocol: increment reference count.
pub fn ref(self: *PaneView, alloc: Allocator) Allocator.Error!*PaneView {
    _ = alloc;
    self.ref_count.retain();
    return self;
}

/// SplitTree view protocol: decrement reference count, freeing the pane (and
/// the leaf it owns) at zero.
pub fn unref(self: *PaneView, alloc: Allocator) void {
    if (!self.ref_count.release()) return;
    switch (self.kind) {
        // Surface.unref runs its own hide/deinit/destroy at zero. The
        // back-pointer stays valid across it ON PURPOSE: Surface teardown
        // reaches back into the IPC registry to forget its own name, and
        // that name is keyed on the PaneView. We free ourselves after.
        .terminal => |s| s.unref(alloc),
        .viewer => |v| {
            v.deinit(alloc);
            alloc.destroy(v);
        },
    }
    alloc.destroy(self);
}

/// SplitTree view protocol: identity comparison.
pub fn eql(self: *const PaneView, other: *const PaneView) bool {
    return self == other;
}

/// Free a pane that never made it into a tree — a `SplitTree.init`/`split`
/// that failed after `createTerminal`. The tree's ref/unref pair never ran,
/// so the count is still zero and calling `unref` directly would underflow
/// it to `maxInt(u32)` and leak everything underneath.
pub fn destroyUnowned(self: *PaneView, alloc: Allocator) void {
    self.ref_count.adoptUnowned();
    self.unref(alloc);
}

// -------------------------------------------------------------------------
// Kind-generic accessors (every tree call site uses these)
// -------------------------------------------------------------------------

/// The pane's kind, for switch sites that need to name it.
pub fn paneKind(self: *const PaneView) Kind {
    return std.meta.activeTag(self.kind);
}

pub fn isTerminal(self: *const PaneView) bool {
    return self.kind == .terminal;
}

pub fn isViewer(self: *const PaneView) bool {
    return self.kind == .viewer;
}

/// The pane's child window, if it has been created yet.
pub fn hwnd(self: *const PaneView) ?w32.HWND {
    return switch (self.kind) {
        .terminal => |s| s.hwnd,
        .viewer => |v| v.hwnd,
    };
}

/// The window this pane lives in.
pub fn parentWindow(self: *const PaneView) *Window {
    return switch (self.kind) {
        .terminal => |s| s.parent_window,
        .viewer => |v| v.parent_window,
    };
}

/// This pane's stable id (T113). Valid for both kinds.
pub fn paneId(self: *const PaneView) []const u8 {
    return switch (self.kind) {
        .terminal => |s| s.paneId(),
        .viewer => |v| v.paneId(),
    };
}

/// The pane's current title, if it has one.
pub fn title(self: *const PaneView) ?[:0]const u8 {
    return switch (self.kind) {
        .terminal => |s| s.title,
        .viewer => |v| v.title,
    };
}

/// Occlusion. Terminals park their renderer; viewers just hide.
pub fn setVisible(self: *PaneView, visible: bool) void {
    switch (self.kind) {
        .terminal => |s| s.setVisible(visible),
        .viewer => |v| v.setVisible(visible),
    }
}

/// Height reserved above the pane content for a sticky banner (T101).
/// Banners are terminal-only (`+set-banner` rejects viewers), so a viewer
/// reserves nothing.
pub fn bannerLayoutInset(self: *PaneView, slot_w: i32, slot_h: i32) i32 {
    return switch (self.kind) {
        .terminal => |s| s.bannerLayoutInset(slot_w, slot_h),
        .viewer => 0,
    };
}

/// Show the unfocused-split dim overlay (T74; viewers since T380 — the T373
/// host window is what gives the overlay something to glue to).
pub fn showDimOverlay(self: *PaneView, color: u32, alpha: u8, batch: ?*?w32.HDWP) void {
    switch (self.kind) {
        .terminal => |s| s.showDimOverlay(color, alpha, batch),
        // The viewer method takes the allocator as a parameter so the host
        // floor stays unit-testable without a Window; every PaneView is in a
        // tree, so reaching through the parent window is safe HERE.
        .viewer => |v| v.showDimOverlay(v.parent_window.app.core_app.alloc, color, alpha, batch),
    }
}

pub fn hideDimOverlay(self: *PaneView) void {
    switch (self.kind) {
        .terminal => |s| s.hideDimOverlay(),
        .viewer => |v| v.hideDimOverlay(),
    }
}

/// Re-check the z-order of this pane's layered popups (T142).
pub fn healOverlayZOrders(self: *PaneView) void {
    switch (self.kind) {
        .terminal => |s| s.healOverlayZOrders(),
        .viewer => |v| v.healOverlayZOrders(),
    }
}

/// A pane's most recent hero-mode thumbnail: a 32-bit DIB plus the pixel size
/// it was captured at. Both kinds produce one — a terminal from its renderer
/// thread's GL readback, a viewer from `ICoreWebView2::CapturePreview` — so the
/// carousel never has to ask what kind of leaf it is painting.
pub const HeroSnapshot = struct {
    dib: w32.HANDLE,
    w: i32,
    h: i32,
};

/// The pane's current thumbnail, or null when it has not produced one yet.
///
/// Kind-generic ON PURPOSE (T397). Hero mode used to narrow through
/// `surface()` here, which made a viewer leaf paint *nothing* — the tile slot
/// was still counted, so the strip showed a hole rather than an exclusion.
/// Mac's `HeroModeView` settled the same question the other way round ("every
/// pane participates: terminals and viewers alike"), so the win32 answer is
/// this accessor: every leaf has a tile, and whether it has CONTENT yet is a
/// separate, temporary question that both kinds answer the same way.
pub fn heroSnapshot(self: *const PaneView) ?HeroSnapshot {
    switch (self.kind) {
        .terminal => |s| {
            const dib = s.snap_dib orelse return null;
            if (s.snap_dib_w <= 0 or s.snap_dib_h <= 0) return null;
            return .{ .dib = dib, .w = s.snap_dib_w, .h = s.snap_dib_h };
        },
        .viewer => |v| {
            const dib = v.snap_dib orelse return null;
            if (v.snap_dib_w <= 0 or v.snap_dib_h <= 0) return null;
            return .{ .dib = dib, .w = v.snap_dib_w, .h = v.snap_dib_h };
        },
    }
}

/// Ask this pane for a fresh hero thumbnail sized to `w`x`h` device pixels.
/// Both kinds are asynchronous and both self-throttle, so the carousel's
/// heartbeat can call this unconditionally.
pub fn heroSnapRequest(self: *PaneView, w: u32, h: u32) void {
    switch (self.kind) {
        .terminal => |s| s.heroSnapRequest(w, h),
        .viewer => |v| v.heroSnapRequest(w, h),
    }
}

/// GUI thread, on `WM_APP_HERO_SNAP`: fold whatever the pane captured into its
/// DIB cache. True when the cache actually changed, i.e. the tile needs a
/// repaint.
pub fn heroSnapPublish(self: *PaneView) bool {
    return switch (self.kind) {
        .terminal => |s| s.heroSnapPublish(),
        .viewer => |v| v.heroSnapPublish(),
    };
}

/// Mark this pane to END its agent session rather than detach (T89e).
/// Viewers never own an agent session, so this is a no-op for them.
pub fn setSessionCloseIntent(self: *PaneView, intent: bool) void {
    switch (self.kind) {
        .terminal => |s| s.setSessionCloseIntent(intent),
        .viewer => {},
    }
}

/// Record the user's **Disconnect** for this pane (T1390), so every later
/// CLOSE-on-free marking is refused. A viewer owns no agent session, so there
/// is nothing to keep and nothing to pin.
pub fn pinDetach(self: *PaneView) void {
    switch (self.kind) {
        .terminal => |s| s.pinDetach(),
        .viewer => {},
    }
}

/// Release the Disconnect pin (a `+rearrange` kept this pane, so it is live
/// again and a later close is an ordinary close).
pub fn clearDetachPin(self: *PaneView) void {
    switch (self.kind) {
        .terminal => |s| s.clearDetachPin(),
        .viewer => {},
    }
}

/// The facts `session_disconnect` decides on. A viewer reports `has_surface =
/// false`, which is exactly why it is never counted in a Disconnect offer.
pub fn disconnectFacts(self: *PaneView) session_disconnect.PaneFacts {
    return switch (self.kind) {
        .terminal => |s| s.disconnectFacts(),
        .viewer => .{
            .has_surface = false,
            .process_exited = true,
            .confirm_close_enabled = false,
        },
    };
}

// -------------------------------------------------------------------------
// Terminal narrowing
// -------------------------------------------------------------------------

/// The underlying Surface, or null if this pane is a viewer. Call sites that
/// are terminal-only (`+send-keys`, `+read`, activity state, hero snapshots)
/// narrow through this.
pub fn surface(self: *const PaneView) ?*Surface {
    return switch (self.kind) {
        .terminal => |s| s,
        .viewer => null,
    };
}

/// The underlying ViewerPane, or null if this pane is a terminal.
pub fn viewer(self: *const PaneView) ?*ViewerPane {
    return switch (self.kind) {
        .terminal => null,
        .viewer => |v| v,
    };
}

test "the union carries the kind, so a leaf is never ambiguous" {
    // The point of the retype: `isTerminal`/`isViewer`/`paneKind` all read
    // the SAME tag, so there is no second place for a leaf's kind to live
    // and disagree (that is why `IpcRegistry.Target` keeps two variants
    // rather than growing a third `.viewerPane` one).
    const Payload = @FieldType(PaneView, "kind");
    try std.testing.expectEqual(Kind, @typeInfo(Payload).@"union".tag_type.?);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Payload).@"union".fields.len);
}
