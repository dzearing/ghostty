//! Pure rules for replaying a restored window's PLACEMENT — its normal rect and
//! its maximized state, which are one fact and have to travel together (T748).
//!
//! Two things live here, both of them the kind of detail that is invisible on
//! the box it was written on and wrong on somebody else's:
//!
//! 1. **The coordinate space.** `WINDOWPLACEMENT.rcNormalPosition` is NOT in
//!    screen coordinates. It is in *workspace* coordinates — screen coordinates
//!    shifted by the origin of the PRIMARY monitor's work area — which is
//!    identical to screen coordinates on the usual bottom-taskbar desktop and
//!    differs by the taskbar's thickness when it sits at the top or the left.
//!    Everything else in this codebase speaks screen coordinates: the manifest's
//!    `session_layout.Frame`, `restore_frame`'s monitor arithmetic (it asks
//!    `MonitorFromRect`, which only answers for screen coordinates), and
//!    `SetWindowPos`. So the conversion belongs at that one boundary and nowhere
//!    else, and both ends of the round trip — the capture that reads a maximized
//!    window's restore-down rect, and the restore that hands it back — go
//!    through the same pair of functions rather than each remembering the rule.
//!
//! 2. **Which show command a restore asks for.** Spelled out below.
//!
//! Deliberately free of win32 (the caller supplies the work-area origin), so the
//! arithmetic runs in the none-runtime test lane.

const std = @import("std");

/// A rectangle in virtual-screen pixels — the manifest's own
/// `session_layout.Frame` shape. Shared with `restore_frame` so a frame can be
/// handed between the two without a third spelling of the same four fields.
pub const Rect = @import("restore_frame.zig").Rect;

/// The top-left of the primary monitor's WORK area (`SPI_GETWORKAREA`), which is
/// the offset between the two coordinate spaces. `(0, 0)` — a taskbar at the
/// bottom or the right, or an unreadable work area — makes both conversions the
/// identity, which is why this bug is invisible on almost every desktop.
pub const Origin = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Workspace → screen: what a `rcNormalPosition` read out of Windows means to
/// everything else here.
pub fn toScreen(r: Rect, work: Origin) Rect {
    return .{ .x = r.x +| work.x, .y = r.y +| work.y, .w = r.w, .h = r.h };
}

/// Screen → workspace: what a recorded frame has to become before it can be
/// handed back through `SetWindowPlacement`.
pub fn toWorkspace(r: Rect, work: Origin) Rect {
    return .{ .x = r.x -| work.x, .y = r.y -| work.y, .w = r.w, .h = r.h };
}

/// The show command a restore asks for, as a decision rather than a number.
///
/// The un-maximized case is deliberately the NO-ACTIVATE spelling
/// (`SW_SHOWNOACTIVATE`) rather than `SW_SHOWNORMAL`: a restore rebuilds every
/// window in turn, and each one grabbing the foreground on its way past is how
/// a multi-window restore ends up flipping activation between them. The
/// pre-T748 code applied its frame with `SWP_NOACTIVATE` for exactly that
/// reason, and this keeps that promise.
///
/// It also has to CLEAR a maximized state, and through `SetWindowPlacement` it
/// does — measured on the box: a window Windows had already maximized (from the
/// T85 placement memory) came back down onto `rcNormalPosition`, un-maximized,
/// when handed this show command. That is worth stating explicitly because
/// `ShowWindow(SW_SHOWNOACTIVATE)` is documented as "the most recent size and
/// position", which reads like it would leave a maximized window alone; the
/// placement call's `showCmd` is the state being ASKED FOR, not a hint.
///
/// The maximized case has no no-activate spelling — `SW_SHOWMAXIMIZED` is the
/// only way to maximize through a placement — which is no change: the pre-T748
/// code reached the same state through `ShowWindow(SW_MAXIMIZE)`, which
/// activates too.
pub const Show = enum {
    /// Un-maximize (or stay un-maximized) onto `rcNormalPosition`, without
    /// taking the foreground.
    show_noactivate,
    /// Maximize, with `rcNormalPosition` recorded as the restore-down rect.
    maximized,
};

pub fn show(maximized: bool) Show {
    return if (maximized) .maximized else .show_noactivate;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "a bottom-taskbar desktop makes both conversions the identity" {
    // The usual case, and the reason a workspace/screen mix-up can sit in the
    // code for months without anybody seeing it.
    const r: Rect = .{ .x = 200, .y = 120, .w = 1200, .h = 800 };
    try testing.expectEqual(r, toScreen(r, .{}));
    try testing.expectEqual(r, toWorkspace(r, .{}));
}

test "a taskbar at the top shifts the origin, never the size" {
    // 48px taskbar docked at the top of the primary monitor.
    const work: Origin = .{ .x = 0, .y = 48 };
    const screen: Rect = .{ .x = 100, .y = 148, .w = 900, .h = 600 };
    const workspace: Rect = .{ .x = 100, .y = 100, .w = 900, .h = 600 };

    try testing.expectEqual(workspace, toWorkspace(screen, work));
    try testing.expectEqual(screen, toScreen(workspace, work));
}

test "a taskbar on the left shifts x" {
    const work: Origin = .{ .x = 72, .y = 0 };
    const screen: Rect = .{ .x = 172, .y = 40, .w = 640, .h = 480 };
    try testing.expectEqual(
        Rect{ .x = 100, .y = 40, .w = 640, .h = 480 },
        toWorkspace(screen, work),
    );
}

test "the round trip is exact, including a window on a monitor left of primary" {
    const work: Origin = .{ .x = 0, .y = 48 };
    const cases = [_]Rect{
        .{ .x = 0, .y = 0, .w = 800, .h = 600 },
        .{ .x = -1920, .y = -200, .w = 1200, .h = 900 },
        .{ .x = 3000, .y = 1500, .w = 300, .h = 200 },
    };
    for (cases) |r| {
        try testing.expectEqual(r, toScreen(toWorkspace(r, work), work));
        try testing.expectEqual(r, toWorkspace(toScreen(r, work), work));
    }
}

test "a degenerate origin saturates instead of wrapping" {
    const r: Rect = .{ .x = std.math.maxInt(i32) - 1, .y = 0, .w = 10, .h = 10 };
    const out = toScreen(r, .{ .x = 1000, .y = 0 });
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), out.x);
    // The size is never touched by either conversion — only the origin moves.
    try testing.expectEqual(@as(i32, 10), out.w);
}

test "show: the recorded state decides, and only maximizing costs activation" {
    // Deliberately a function of the RECORDED state alone: what the window
    // happens to be right now (Windows may already have maximized it from the
    // placement memory) is not an input, because the placement call sets the
    // state being asked for either way.
    try testing.expectEqual(Show.maximized, show(true));
    try testing.expectEqual(Show.show_noactivate, show(false));
}
