//! One reposition path for the win32 floating chrome (T1392).
//!
//! Every bar and card the viewer floats over its content — the nav bar, the
//! find card, the feedback composer, the TOC card, the banner — is moved and
//! resized from the pane's bounds sync, which a divider drag re-runs on every
//! mouse move. What Windows is asked to do there decides whether the chrome
//! looks glued to the edge being dragged or a frame behind it:
//!
//! * `MoveWindow(.., TRUE)` INVALIDATES and lets the repaint fall out to the
//!   next idle. During a live drag the message loop is busy pumping sizing
//!   messages, so that paint lands a frame or more after the move — and since
//!   these classes carry `CS_HREDRAW | CS_VREDRAW`, the late frame is a full
//!   redraw of the whole bar. That is the "I watch it painting" the user
//!   reported against the address bar.
//! * Windows also BLITS the old bits into the new rect first, so the frame
//!   before the repaint shows the old layout stretched into the new width.
//!
//! The banner solved both in T456 by hand; this module is that solution
//! extracted, so the next overlay does not have to rediscover it:
//!
//! 1. Decide from the rects whether this is a RESIZE or just a MOVE.
//! 2. On a resize add `SWP_NOCOPYBITS` — the class already invalidates every
//!    pixel, so blitting the stale bits buys nothing but the smear.
//! 3. On a resize follow with `UpdateWindow`, which paints in THIS frame.
//!
//! A pure move keeps neither: nothing about the pixels changed, `NOCOPYBITS`
//! would throw away a perfectly good blit and force a needless repaint, and a
//! synchronous paint on a move is work with no visible payoff.
//!
//! **`SWP_NOCOPYBITS` is deliberately a single switch here.** T1348 is the open
//! question of whether that flag earns its place at all — its case is that
//! `SetWindowPos` blits 1:1 rather than stretching, so discarding the old bits
//! shows undefined pixels for the instant before the synchronous repaint where
//! keeping them would show the previous frame. That question is unresolved and
//! is not settled by this module; centralising the flag is what makes settling
//! it a one-line change instead of a five-window audit.

const std = @import("std");
const w32 = @import("win32.zig");

/// A window's outer size in pixels. Screen or client space does not matter —
/// only the extents are ever compared, and a move does not change those.
pub const Size = struct {
    w: i32,
    h: i32,
};

/// What a reposition owes Windows, decided from the old and new extents alone.
pub const Decision = struct {
    /// The extents changed (or the old ones could not be read, which is the
    /// safe answer: assume everything is stale).
    resized: bool,
    /// Add `SWP_NOCOPYBITS` to the `SetWindowPos` flags.
    no_copy_bits: bool,
    /// Force the `WM_PAINT` now, in the same frame as the move.
    sync_paint: bool,
};

/// The whole decision, as a pure function of the two rects.
///
/// `old` is null when the current rect is unknown — a window that has not been
/// placed yet, or a `GetWindowRect` that failed. Both mean "nothing on screen
/// can be trusted", which is the resize answer.
pub fn decide(old: ?Size, new: Size) Decision {
    const resized = if (old) |o| o.w != new.w or o.h != new.h else true;
    return .{
        .resized = resized,
        .no_copy_bits = resized,
        .sync_paint = resized,
    };
}

/// Read a window's current outer size, or null when Windows will not say.
pub fn currentSize(hwnd: w32.HWND) ?Size {
    var r: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &r) == 0) return null;
    return .{ .w = r.right - r.left, .h = r.bottom - r.top };
}

/// Move and/or resize a piece of floating chrome the way a live drag needs.
///
/// Drop-in for `MoveWindow(hwnd, x, y, w, h, TRUE)`. `base_flags` carries
/// whatever else the call site means (`SWP_SHOWWINDOW` on a popup that may be
/// coming back from hidden, say); the resize flags are added on top.
pub fn place(
    hwnd: w32.HWND,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    base_flags: u32,
) Decision {
    const d = decide(currentSize(hwnd), .{ .w = width, .h = height });
    var flags = base_flags | w32.SWP_NOACTIVATE | w32.SWP_NOZORDER;
    if (d.no_copy_bits) flags |= w32.SWP_NOCOPYBITS;
    _ = w32.SetWindowPos(hwnd, null, x, y, width, height, flags);
    if (d.sync_paint) _ = w32.UpdateWindow(hwnd);
    return d;
}

test "resize: no stale blit, and the paint is in this frame" {
    const d = decide(.{ .w = 400, .h = 40 }, .{ .w = 520, .h = 40 });
    try std.testing.expect(d.resized);
    try std.testing.expect(d.no_copy_bits);
    try std.testing.expect(d.sync_paint);
}

test "height-only resize counts too" {
    const d = decide(.{ .w = 400, .h = 40 }, .{ .w = 400, .h = 64 });
    try std.testing.expect(d.resized);
    try std.testing.expect(d.no_copy_bits);
    try std.testing.expect(d.sync_paint);
}

// The negative half, and the one T1392's validation names explicitly: a pure
// move must NOT take either. `SWP_NOCOPYBITS` on a move throws away a valid
// blit for a full repaint, and a synchronous paint there is a frame of work
// buying nothing — that is how a fix for one flicker becomes another.
test "pure move: keeps the blit and defers the paint" {
    const d = decide(.{ .w = 400, .h = 40 }, .{ .w = 400, .h = 40 });
    try std.testing.expect(!d.resized);
    try std.testing.expect(!d.no_copy_bits);
    try std.testing.expect(!d.sync_paint);
}

// A window nobody has measured yet has nothing worth blitting, so the unknown
// case has to land on the resize side. It is also what a failed
// `GetWindowRect` returns, and treating that as a move would silently restore
// the exact defect on any window Windows declines to measure.
test "unknown old rect is treated as a resize" {
    const d = decide(null, .{ .w = 400, .h = 40 });
    try std.testing.expect(d.resized);
    try std.testing.expect(d.no_copy_bits);
    try std.testing.expect(d.sync_paint);
}

// Negative control (T1133): the decision is a real fork, not a constant
// wearing a struct. If these two ever agree, every test above passes while
// the module has stopped deciding anything.
test "T1392 negative control: move and resize do not decide the same thing" {
    const same: Size = .{ .w = 400, .h = 40 };
    const move = decide(same, same);
    const resize = decide(same, .{ .w = 401, .h = 40 });
    try std.testing.expect(!std.meta.eql(move, resize));
}
