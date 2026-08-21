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
