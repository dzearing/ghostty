//! Pure geometry for re-anchoring a restored window frame (T336).
//!
//! A frame that came out of THIS machine's own manifest is replayed verbatim:
//! it was authored against the monitors we still have, and moving it would be
//! the app second-guessing where the user put their window.
//!
//! A frame that came out of ANOTHER machine's layout blob has no such
//! guarantee. The far machine may run a 4K portrait panel at (-2160, 0) or a
//! three-monitor wall; replaying those coordinates here puts the rebuilt window
//! somewhere the user cannot see it, and a Restore All whose windows land
//! off-screen is indistinguishable from one that did nothing. Mac clamps the
//! same way for the same reason (`SessionLayoutRestore.reanchoredFrame`,
//! `SessionLayoutRestore.swift:378-388`).
//!
//! The rule, ported: if the frame intersects ANY visible area, leave it alone —
//! a partially off-screen window is still a window the user can grab. Otherwise
//! re-center a same-sized window on the primary monitor's work area, shrinking
//! it only as far as it must to fit.
//!
//! This module is deliberately free of win32: the caller supplies the work
//! rects (`MonitorFromRect` answers the intersection question, `GetMonitorInfoW`
//! the primary's work area), so the arithmetic runs in the none-runtime test
//! lane.

const std = @import("std");

/// A rectangle in virtual-screen pixels, origin + size (the manifest's own
/// `session_layout.Frame` shape, kept structurally identical so the caller can
/// hand one over field-for-field).
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x +| self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y +| self.h;
    }
};

/// Whether two rectangles share any area. Touching edges do NOT count: a window
/// whose right edge is exactly a monitor's left edge has zero visible pixels on
/// it, which is the condition this whole module exists to catch.
pub fn intersects(a: Rect, b: Rect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.right() and b.x < a.right() and
        a.y < b.bottom() and b.y < a.bottom();
}

/// True when `frame` overlaps at least one of `work` — the "leave it alone"
/// test. An EMPTY `work` list means we could not enumerate monitors at all,
/// which is treated as "do not move it": inventing a position from no
/// information is worse than replaying the recorded one.
pub fn isVisible(frame: Rect, work: []const Rect) bool {
    if (work.len == 0) return true;
    for (work) |w| {
        if (intersects(frame, w)) return true;
    }
    return false;
}

/// The frame to actually use for a CROSS-MACHINE restore: `frame` when it lands
/// on a visible monitor, else a same-sized (or shrunk-to-fit) window centered on
/// `primary`.
///
/// A degenerate `frame` (zero or negative extent — a corrupt or truncated blob)
/// takes the primary's work area outright rather than being centered as a
/// zero-pixel window, which would restore an invisible window and report
/// success.
pub fn reanchor(frame: Rect, work: []const Rect, primary: Rect) Rect {
    if (frame.w > 0 and frame.h > 0 and isVisible(frame, work)) return frame;
    return centerOn(frame, primary);
}

/// The clamp on its own: `frame`'s size (shrunk to fit) centered in `primary`.
/// Split out because the win32 caller already knows the answer to the
/// visibility question — `MonitorFromRect` IS that query — and a second,
/// independently-derived answer is a chance for the two to disagree.
///
/// A degenerate `frame` takes the work area outright rather than being centered
/// as a zero-pixel window, which would restore an invisible window and report
/// success. A degenerate `primary` (nothing readable about this display) leaves
/// the frame alone: replaying a recorded position beats inventing one.
pub fn centerOn(frame: Rect, primary: Rect) Rect {
    if (primary.w <= 0 or primary.h <= 0) return frame;
    if (frame.w <= 0 or frame.h <= 0) return primary;

    const w = @min(frame.w, primary.w);
    const h = @min(frame.h, primary.h);
    return .{
        .x = primary.x + @divTrunc(primary.w - w, 2),
        .y = primary.y + @divTrunc(primary.h - h, 2),
        .w = w,
        .h = h,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

// The box this is written on, near enough: one 2560x1440 primary with a
// 40px-tall taskbar reserved out of the work area.
const primary_work: Rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1400 };

test "intersects: overlap, touching edges, and empty rects" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try testing.expect(intersects(a, .{ .x = 50, .y = 50, .w = 100, .h = 100 }));
    // Edge-touching is NOT an intersection: zero visible pixels.
    try testing.expect(!intersects(a, .{ .x = 100, .y = 0, .w = 100, .h = 100 }));
    try testing.expect(!intersects(a, .{ .x = 0, .y = 100, .w = 100, .h = 100 }));
    // A zero-area rect intersects nothing, including itself.
    try testing.expect(!intersects(a, .{ .x = 0, .y = 0, .w = 0, .h = 100 }));
}

test "a frame on this machine's monitor is left exactly where it was" {
    const frame: Rect = .{ .x = 200, .y = 120, .w = 1200, .h = 800 };
    const out = reanchor(frame, &.{primary_work}, primary_work);
    try testing.expectEqual(frame, out);
}

test "a frame from another machine's monitor arrangement is re-centered" {
    // A window that lived on a portrait panel to the LEFT of the far machine's
    // primary: no pixel of it exists here.
    const frame: Rect = .{ .x = -2160, .y = 0, .w = 1080, .h = 1920 };
    const out = reanchor(frame, &.{primary_work}, primary_work);
    try testing.expect(isVisible(out, &.{primary_work}));
    // Same width (it fits), height shrunk to the work area, and centered.
    try testing.expectEqual(@as(i32, 1080), out.w);
    try testing.expectEqual(@as(i32, 1400), out.h);
    try testing.expectEqual(@as(i32, (2560 - 1080) / 2), out.x);
    try testing.expectEqual(@as(i32, 0), out.y);
}

test "a partially visible frame is NOT moved" {
    // Half off the right edge — still grabbable, so Mac's rule leaves it.
    const frame: Rect = .{ .x = 2400, .y = 100, .w = 800, .h = 600 };
    try testing.expect(isVisible(frame, &.{primary_work}));
    try testing.expectEqual(frame, reanchor(frame, &.{primary_work}, primary_work));
}

test "a second monitor counts as visible" {
    const second: Rect = .{ .x = 2560, .y = 0, .w = 1920, .h = 1040 };
    const frame: Rect = .{ .x = 3000, .y = 100, .w = 800, .h = 600 };
    try testing.expect(!isVisible(frame, &.{primary_work}));
    try testing.expect(isVisible(frame, &.{ primary_work, second }));
    try testing.expectEqual(frame, reanchor(frame, &.{ primary_work, second }, primary_work));
}

test "no monitor information ⇒ replay the recorded frame unchanged" {
    const frame: Rect = .{ .x = -5000, .y = -5000, .w = 800, .h = 600 };
    try testing.expect(isVisible(frame, &.{}));
    try testing.expectEqual(frame, reanchor(frame, &.{}, .{ .x = 0, .y = 0, .w = 0, .h = 0 }));
    // ... and the same when only the clamp half runs (the win32 caller's path,
    // where an unreadable primary is the failure mode).
    try testing.expectEqual(frame, centerOn(frame, .{ .x = 0, .y = 0, .w = 0, .h = 0 }));
}

test "centerOn matches reanchor's clamp for an invisible frame" {
    const frame: Rect = .{ .x = -2160, .y = 0, .w = 1080, .h = 1920 };
    try testing.expectEqual(
        reanchor(frame, &.{primary_work}, primary_work),
        centerOn(frame, primary_work),
    );
}

test "a frame larger than this screen shrinks to fit, not off the edges" {
    const frame: Rect = .{ .x = -8000, .y = -8000, .w = 3840, .h = 2160 };
    const out = reanchor(frame, &.{primary_work}, primary_work);
    try testing.expectEqual(primary_work, out);
}

test "a degenerate frame takes the work area rather than restoring invisibly" {
    try testing.expectEqual(primary_work, reanchor(
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        &.{primary_work},
        primary_work,
    ));
}
