//! Should a terminal surface's `WM_ERASEBKGND` paint the flat background, or
//! leave the pixels where they are for the GL frame that is already coming?
//!
//! T1031. The old answer was "always", with the comment that "the OpenGL
//! renderer will overwrite the entire client area on the next frame". The
//! *next* frame is the whole problem: the erase is synchronous and the GL
//! frame is not, so every erase puts one displayed frame of flat background
//! on screen before the content comes back. During a divider drag that is one
//! flash per motion tick, which is the strobing the user reported.
//!
//! The fill is not useless, though, and deleting it outright would trade a
//! flash for garbage:
//!
//!   * The search bar and the command palette are POPUPS registered under the
//!     same window class as the terminal surface, so they arrive at the same
//!     handler. They have no GL renderer behind them and paint their chrome in
//!     `WM_PAINT`; without the fill their background is whatever the desktop
//!     left there.
//!   * A surface that has never presented a frame has nothing behind it
//!     either. That is window creation, a restored session before its first
//!     draw, and a pane whose renderer has not started. Flat background is the
//!     right answer there — it is what the window is *about* to look like.
//!
//! So the rule is narrow: skip the fill only for the terminal surface window
//! itself, and only once the renderer has actually put a frame in it. Pure so
//! the rule is unit-testable in the `none` lane rather than only observable by
//! looking at a window.

const std = @import("std");

pub const Erase = struct {
    /// This HWND is the terminal surface window itself, rather than one of the
    /// popups that share its window class (search bar, command palette).
    is_surface_window: bool,

    /// The renderer thread has called `SwapBuffers` into this window at least
    /// once, so there are real pixels to preserve.
    has_presented_frame: bool,
};

/// True when the handler should `FillRect` the client area with the
/// background brush.
pub fn shouldFillBackground(e: Erase) bool {
    // Popups have no frame behind them, ever.
    if (!e.is_surface_window) return true;

    // Nothing to preserve yet: flat background beats undefined pixels.
    return !e.has_presented_frame;
}

/// The other half of "does the user see a blank frame": whether the pane
/// blocks for a frame at its new size before letting the resize land (T1393).
///
/// Declining the erase (above) only stops US from painting background. It does
/// nothing about the gap between the window changing size and the renderer
/// presenting at that size — during which the enlarged surface holds whatever
/// the GL front buffer had, i.e. the flat clear color. That gap is closed by
/// blocking the UI thread on the renderer's frame event, and until T1393 the
/// gate on it named the GESTURE rather than the situation: `in_live_resize`,
/// which is set at `WM_ENTERSIZEMOVE`.
///
/// Measured on 2026-09-06 with the `window resize cause=.. sync=..` oracle:
///
///   cause=restored  panes=2 sync=2   <- modal frame drag: guaranteed
///   cause=maximized panes=2 sync=0   <- maximize: no guarantee at all
///   cause=restored  panes=2 sync=0   <- restore: likewise
///
/// Maximize, restore, Aero-snap and a title-bar double-click resize the window
/// WITHOUT a modal size loop, so no `WM_ENTERSIZEMOVE` ever arrives and every
/// one of them relayouts panes the user is looking straight at with the
/// anti-flicker path switched off. Hence the rule below is about the pane's
/// state, not about which gesture got here: a pane with pixels in it waits;
/// a pane with nothing to preserve does not, because there the wait is a pure
/// stall (window creation, a restored session before its first draw) and the
/// flat background is the honest answer anyway — the same carve-out
/// `shouldFillBackground` makes, from the same fact.
pub const Present = struct {
    /// The pane is inside a modal size loop (`WM_ENTERSIZEMOVE` seen, no
    /// `WM_EXITSIZEMOVE` yet).
    in_live_resize: bool,

    /// The layout pass declared itself one the user is watching in real time —
    /// a divider drag, a banner expand/collapse, and since T1393 every
    /// whole-window `WM_SIZE` pass.
    in_live_layout: bool,

    /// The renderer thread has presented into this window at least once.
    has_presented_frame: bool,
};

/// True when `handleResize` should block for a frame at the new size.
pub fn shouldPresentSynchronously(p: Present) bool {
    // Nothing on screen to go stale: waiting here buys no pixels and costs the
    // startup path a frame per pane.
    if (!p.has_presented_frame) return false;
    return p.in_live_resize or p.in_live_layout;
}

test "popups always get the flat fill" {
    // Both popup states, because "has presented a frame" is meaningless for a
    // window with no renderer and must not accidentally start gating them.
    try std.testing.expect(shouldFillBackground(.{
        .is_surface_window = false,
        .has_presented_frame = false,
    }));
    try std.testing.expect(shouldFillBackground(.{
        .is_surface_window = false,
        .has_presented_frame = true,
    }));
}

test "a surface with no frame yet gets the flat fill" {
    try std.testing.expect(shouldFillBackground(.{
        .is_surface_window = true,
        .has_presented_frame = false,
    }));
}

test "a surface that has presented is left alone" {
    // The one case that changed in T1031, and the whole point of the module.
    try std.testing.expect(!shouldFillBackground(.{
        .is_surface_window = true,
        .has_presented_frame = true,
    }));
}

test "a modal frame drag presents synchronously" {
    try std.testing.expect(shouldPresentSynchronously(.{
        .in_live_resize = true,
        .in_live_layout = false,
        .has_presented_frame = true,
    }));
}

test "a watched layout pass presents synchronously without a size loop" {
    // T1393: maximize, restore, Aero-snap and a title-bar double-click raise
    // no WM_ENTERSIZEMOVE, so `in_live_resize` is false through a resize the
    // user is watching. The pass says it is live instead, and that is enough.
    try std.testing.expect(shouldPresentSynchronously(.{
        .in_live_resize = false,
        .in_live_layout = true,
        .has_presented_frame = true,
    }));
}

test "a pane with nothing presented never stalls" {
    // Both live flags on, and still no wait: there are no pixels to preserve,
    // so the block would be a pure frame of latency at window creation.
    try std.testing.expect(!shouldPresentSynchronously(.{
        .in_live_resize = true,
        .in_live_layout = true,
        .has_presented_frame = false,
    }));
}

test "an unwatched relayout stays asynchronous" {
    try std.testing.expect(!shouldPresentSynchronously(.{
        .in_live_resize = false,
        .in_live_layout = false,
        .has_presented_frame = true,
    }));
}
