//! T681: whether a DEFERRED pane-HWND reap is still allowed to fire.
//!
//! A terminal pane's child HWND is not destroyed inside `Surface.deinit`. The
//! window is created by the same thread that renders into it through WGL, and
//! the very first win32 commit recorded a segfault inside OPENGL32.dll's
//! window-destruction hook when `DestroyWindow` ran on the same stack as the
//! context teardown. Rather than re-litigate that on the user's terminal, the
//! reap is POSTED: `Surface.deinit` clears the window's `GWLP_USERDATA` and
//! hands the bare handle to the app, whose message-only window destroys it
//! from the top of the message loop — with the renderer thread joined, the
//! WGL context deleted, the DC released and no ghoztty frame underneath.
//!
//! Deferral buys safety and costs one thing: by the time the message is
//! pumped the handle may no longer be ours. Closing the whole WINDOW deinits
//! every pane and then destroys the parent, and Win32 destroys child windows
//! with their parent — so the posted reaps arrive at handles Windows has
//! already freed and may have recycled onto something else. Destroying a
//! recycled handle would take down an unrelated window, which is a far worse
//! bug than the leak this fixes.
//!
//! Hence the two-factor check below, evaluated at reap time:
//!
//!  1. The handle still names a window of the terminal class. A freed handle
//!     fails `GetClassNameW` outright; a recycled one almost never comes back
//!     as `GhozttyTerminal`.
//!  2. That window's `GWLP_USERDATA` is zero. Every LIVE surface stores its
//!     `*Surface` there, and only `Surface.deinit` clears it — immediately
//!     before posting. So a handle that got recycled onto a NEW pane is
//!     rejected by this leg even though it passes the first.
//!
//! The one window where a live pane reads as reapable is between
//! `CreateWindowExW` and the `SetWindowLongPtrW` that follows it in
//! `Surface.init`. Nothing pumps the message queue across those two lines —
//! `CreateWindowExW` delivers WM_NCCREATE/WM_CREATE synchronously and never
//! retrieves a POSTED message — so a reap cannot land inside it.
//!
//! Pure on purpose: the decision is asserted in the `none` lane, and the win32
//! caller supplies the two facts by calling the OS.

const std = @import("std");

/// What the caller measured about a posted handle at the moment the reap
/// message was pumped.
pub const Candidate = struct {
    /// `GetClassNameW` answered, and the name it answered with is the
    /// terminal surface class. False for a handle that no longer names a
    /// window at all (the call fails) and for one recycled onto some other
    /// class.
    class_matches: bool,

    /// The window's `GWLP_USERDATA`. Zero once `Surface.deinit` has cleared
    /// it; a live surface's own pointer otherwise.
    userdata: usize,
};

/// True when this handle is the dead pane window we posted and nothing else.
pub fn reapable(c: Candidate) bool {
    return c.class_matches and c.userdata == 0;
}

test "reapable: the handle we posted, still ours and already cleared" {
    try std.testing.expect(reapable(.{ .class_matches = true, .userdata = 0 }));
}

test "reapable: a handle freed with its parent window is left alone" {
    // GetClassNameW fails on a freed handle, so the class leg is false and
    // the userdata read is meaningless (0 is what a failed read returns too).
    try std.testing.expect(!reapable(.{ .class_matches = false, .userdata = 0 }));
}

test "reapable: a recycled handle on some other class is left alone" {
    try std.testing.expect(!reapable(.{ .class_matches = false, .userdata = 0x7ff0_0000 }));
}

test "reapable: a handle recycled onto a LIVE pane is left alone" {
    // The leg that matters: same class, so factor 1 passes. A live surface
    // stored its pointer, so factor 2 rejects it and the new pane survives.
    try std.testing.expect(!reapable(.{ .class_matches = true, .userdata = 0x7ff0_0000 }));
}
