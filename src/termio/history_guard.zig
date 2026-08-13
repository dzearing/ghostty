//! Keep a resize from importing SCROLLBACK into a viewport the child is about
//! to repaint (T431).
//!
//! ## The bug this exists to stop, measured
//!
//! Two behaviours that are each correct alone and destroy history together:
//!
//! 1. **Ghostty's resize pulls history down into the active area.** Growing the
//!    row count with the cursor on the bottom row deliberately "pulls down"
//!    scrollback rather than appending blank rows, so making a window taller
//!    reveals what scrolled off instead of showing empty space
//!    (`PageList.resizeWithoutReflow`, the `.gt` branch — the comment there says
//!    so in as many words). A reflow to a narrower width can do the same when
//!    the viewport has trailing blank rows. Both are good behaviour on a POSIX
//!    pty and both are only a MOVE of the active-area boundary: no row is
//!    copied, so a row that crosses from history into the active area is no
//!    longer in history.
//!
//! 2. **A ConPTY child owns the viewport absolutely and repaints all of it after
//!    every resize.** conhost hands us its whole screen buffer as absolutely
//!    positioned VT, opening with `ESC[H ESC[2J`. Anything on the active screen
//!    that conhost does not know about is erased.
//!
//! Put together, every row that (1) imports is erased by (2) — and because the
//! import was a move, it is then gone from the scrollback as well. Measured on
//! box with numbered lines (`test\win32\scrollback-narrow.ps1`): fill a pane
//! with `line 1`..`line 500`, then drag the window taller by 18 rows, and lines
//! 456–473 are **permanently gone** — exactly the rows the viewport gained.
//! Widening the window, dragging a divider, un-zooming a split, maximizing:
//! every one of those grows a pane and eats that much history.
//!
//! ## The guard
//!
//! Pin the first row of the active area before the resize; after it, ask where
//! that pin ended up. If it is now `k` rows down the active area, the resize
//! imported `k` rows of history — so scroll those `k` rows straight back out.
//! The active area ends up the same height with `k` blank rows at the bottom,
//! which is exactly what conhost's own buffer looks like after the same resize,
//! so the two models stay in step and the child's repaint has nothing of ours
//! to erase.
//!
//! A tracked pin is the only handle that survives a reflow — row counts, history
//! depths and byte offsets are all re-wrapped out from under you when the width
//! changes — which is the same reason `session_notice.trackFold` uses one. This
//! module generalises that one-block guard (T423) to the whole boundary: with
//! the first active row held in place, nothing above it can be dragged in,
//! notice included.
//!
//! ## Why it is the CHILD's pty that decides, not the host OS
//!
//! Fact (2) is ConPTY's. A POSIX child does not repaint on `SIGWINCH`, so the
//! rows ghostty pulls down stay on screen and stay readable — that is the whole
//! point of the behaviour, and macOS keeps it. Turning it on everywhere would
//! be a user-visible regression on the platform where the pull-down works, for a
//! bug that cannot happen there.
//!
//! The question is therefore about the CHILD, and for a local pane the child is
//! always this machine's — which is why T431 shipped `builtin.os.tag ==
//! .windows` and why that was right for every pane that existed then. A **remote
//! pane** breaks the equivalence: the shell lives on the agent's machine, so a
//! macOS window can own a ConPTY child (guard needed, and its absence was real
//! data loss) and a Windows window can own a POSIX one (guard pointless — the
//! user sees new blank rows where previously-scrolled output should have slid
//! into view).
//!
//! So the flavour rides the agent HELLO (`protocol.PtyFlavor`, T471) and the
//! decision is per pane, made by `enabledFor` on what the backend's child
//! actually runs on. A peer too old to say answers null, which falls back to
//! `local_flavor` — bit-for-bit the pre-T471 behaviour, so an old agent is not a
//! regression, just an unimproved case.

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal/main.zig");
const protocol = @import("../remote/protocol.zig");

const log = std.log.scoped(.history_guard);

/// The pty flavour of children THIS machine spawns. The answer for every local
/// (exec) pane, and the fallback for a remote peer that did not report one.
/// Derived once, on the wire type, so the agent's HELLO and this guard cannot
/// disagree about what this build runs.
pub const local_flavor: protocol.PtyFlavor = .local;

/// Whether a pane whose child runs on `flavor` needs the guard, i.e. whether
/// that child repaints its whole viewport after a resize.
///
/// Null means "not reported": an agent older than T471, or a handshake that has
/// not resolved yet. Both fall back to `local_flavor`, which is the answer that
/// was hard-coded before this was negotiable — reduced function, never a wrong
/// guess about a pane we know nothing about.
pub fn enabledFor(flavor: ?protocol.PtyFlavor) bool {
    return (flavor orelse local_flavor) == .conpty;
}

/// Pin the first row of the active area, so `hold` can tell how far a resize
/// dragged it down. Returns null when there is nothing to guard or the pin
/// cannot be made — scrollback integrity is worth a guard, never worth failing
/// a resize over.
///
/// Only the primary screen has history to lose. The alternate screen has no
/// scrollback at all and is resized without reflow, so a pin there would be a
/// guard against nothing.
pub fn arm(t: *terminal.Terminal) ?*terminal.Pin {
    if (t.screens.active_key != .primary) return null;
    const p = t.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }) orelse return null;
    return t.screens.active.pages.trackPin(p) catch |err| {
        log.warn("could not pin the active-area boundary err={}", .{err});
        return null;
    };
}

/// Release a pin from `arm`. Safe to call whatever `hold` did.
pub fn disarm(t: *terminal.Terminal, pin: *terminal.Pin) void {
    t.screens.active.pages.untrackPin(pin);
}

/// Push back any history the resize imported into the active area. A no-op —
/// and it is the common case — when the boundary did not move.
///
/// Must be called AFTER `Terminal.resize`, which is what makes `scrollUp` the
/// right move here: `scrollUp` scrolls the SCROLLING REGION, and only a
/// full-screen region pushes its top rows into history. A program that had set
/// DECSTBM would break that — but `Terminal.resize` resets the scrolling region
/// to the whole screen as its last act, so by the time we run there is never a
/// partial region to catch us out.
pub fn hold(t: *terminal.Terminal, pin: *terminal.Pin) void {
    // Out of the active area entirely: the resize pushed content UP into
    // history, which is the direction that costs nothing.
    const pt = t.screens.active.pages.pointFromPin(.active, pin.*) orelse return;
    const imported = pt.coord().y;
    if (imported == 0) return;

    const old_x = t.screens.active.cursor.x;
    const old_y = t.screens.active.cursor.y;
    t.scrollUp(imported) catch |err| {
        log.warn("could not push imported history back out err={}", .{err});
        return;
    };
    // `scrollUp` leaves the cursor on the row NUMBER it was on, but every row
    // moved up by `imported` — so the cursor is now that far below its own
    // content. Follow the content.
    t.setCursorPos(
        @as(usize, if (old_y > imported) old_y - imported else 0) + 1,
        @as(usize, old_x) + 1,
    );
}

test "enabledFor: the CHILD's pty decides, not the host os (T471)" {
    const testing = std.testing;

    // A ConPTY child repaints; a POSIX child does not. Neither answer depends on
    // which OS this test is running on — that is the whole point.
    try testing.expect(enabledFor(.conpty));
    try testing.expect(!enabledFor(.posix));

    // Not reported (an agent older than T471, or a handshake still in flight)
    // falls back to this machine's flavour: exactly the pre-T471 derivation.
    try testing.expectEqual(builtin.os.tag == .windows, enabledFor(null));
    try testing.expectEqual(
        @as(protocol.PtyFlavor, if (builtin.os.tag == .windows) .conpty else .posix),
        local_flavor,
    );
}

test "hold: growing the rows does not eat scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The measured bug, in miniature. Fill past the viewport so there is real
    // history, leave the cursor on the bottom row the way a shell prompt does,
    // then make the pane taller.
    var t = try terminal.Terminal.init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 4096 });
    defer t.deinit(alloc);
    for (1..13) |i| {
        var buf: [16]u8 = undefined;
        try t.printString(try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }

    const guard = arm(&t).?;
    defer disarm(&t, guard);
    try t.resize(alloc, 20, 9);

    // Not an aspiration: this is what the terminal DOES, and the reason the
    // guard exists. Four rows of history were dragged onto the active screen.
    {
        const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(view);
        try testing.expect(std.mem.indexOf(u8, view, "line 8") != null);
    }

    hold(&t, guard);
    {
        const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(view);
        try testing.expect(std.mem.indexOf(u8, view, "line 8") == null);
        try testing.expect(std.mem.indexOf(u8, view, "line 12") != null);
    }

    // And the child's repaint — the second half of the mechanism — cannot
    // reach what the guard put back. This is the assertion that actually
    // encodes "scrollback was not destroyed".
    //
    // Lines 9-12 are deliberately NOT asserted: at 5 rows they are the
    // VIEWPORT, which the child owns and repaints from its own buffer. Only
    // lines 1-8 — the history as it stood before the resize — are ours to
    // keep, and they are exactly what the bug ate.
    t.eraseDisplay(.complete, false);
    const all = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(all);
    for (1..9) |i| {
        var buf: [16]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "line {d}", .{i});
        testing.expect(std.mem.indexOf(u8, all, needle) != null) catch |err| {
            std.debug.print("lost {s} to a grow+repaint\n", .{needle});
            return err;
        };
    }
}

test "hold: a narrowing reflow over a blank viewport does not eat scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The other direction of the same mechanism: a ConPTY pane's viewport is
    // mostly trailing blank rows (a shell paints a few lines into twenty), and
    // the reflow refills them out of history.
    var t = try terminal.Terminal.init(alloc, .{ .cols = 64, .rows = 20, .max_scrollback = 4096 });
    defer t.deinit(alloc);
    for (1..9) |i| {
        var buf: [80]u8 = undefined;
        try t.printString(try std.fmt.bufPrint(
            &buf,
            "line {d} with enough text on it that a narrower pane must wrap it\n",
            .{i},
        ));
    }
    // Fold it all away, the way a cleared viewport over deep history looks.
    t.scrollUp(t.screens.active.cursor.y) catch unreachable;
    t.setCursorPos(1, 1);
    try t.printString("C:\\work>");

    const guard = arm(&t).?;
    defer disarm(&t, guard);
    try t.resize(alloc, 31, 20);
    hold(&t, guard);

    t.eraseDisplay(.complete, false);
    const all = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(all);
    const tight = try std.mem.replaceOwned(u8, alloc, all, "\n", "");
    defer alloc.free(tight);
    for (1..9) |i| {
        var buf: [16]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "line {d} with", .{i});
        testing.expect(std.mem.indexOf(u8, tight, needle) != null) catch |err| {
            std.debug.print("lost {s} to a narrow+repaint\n", .{needle});
            return err;
        };
    }
}

test "hold: shrinking rows costs nothing and moves nothing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 20, .rows = 8, .max_scrollback = 4096 });
    defer t.deinit(alloc);
    for (1..15) |i| {
        var buf: [16]u8 = undefined;
        try t.printString(try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }

    const guard = arm(&t).?;
    defer disarm(&t, guard);
    try t.resize(alloc, 20, 5);
    const before = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(before);

    // The guard runs after every resize for the pane's whole life, so the case
    // that must cost nothing is the one that happens every time.
    hold(&t, guard);
    const after = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(after);
    try testing.expectEqualStrings(before, after);
}

test "hold: the cursor follows its own content" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 4096 });
    defer t.deinit(alloc);
    for (1..13) |i| {
        var buf: [16]u8 = undefined;
        try t.printString(try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    try t.printString("C:\\work>");

    const guard = arm(&t).?;
    defer disarm(&t, guard);
    try t.resize(alloc, 20, 9);
    hold(&t, guard);

    // The prompt is the last real row; the cursor must still be sitting at its
    // end, not stranded on a blank row below it. A misplaced cursor is how the
    // child's coordinate frame and ours drift apart.
    const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(view);
    var rows = std.mem.splitScalar(u8, view, '\n');
    var last_content: usize = 0;
    var idx: usize = 0;
    while (rows.next()) |r| : (idx += 1) {
        if (std.mem.indexOf(u8, r, "C:\\work>") != null) last_content = idx;
    }
    try testing.expectEqual(last_content, @as(usize, t.screens.active.cursor.y));
    try testing.expectEqual(@as(usize, 8), @as(usize, t.screens.active.cursor.x));
}

test "arm: the alternate screen has no history to guard" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 4096 });
    defer t.deinit(alloc);
    try t.switchScreenMode(.@"1049", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    try testing.expect(arm(&t) == null);
}
