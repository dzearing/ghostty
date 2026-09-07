//! The one thing an acceptance script cannot photograph: that a window
//! REPAINTED ITSELF (T1405).
//!
//! Every pixel oracle in `test/win32/` reads a window by handing it a DC and
//! asking for a frame — `WM_PRINTCLIENT` under `-Sync`, `PrintWindow(
//! PW_RENDERFULLCONTENT)` otherwise. That frame is drawn on demand, from the
//! current state, so it looks identical whether the app invalidated the window
//! a moment ago or has not drawn anything since it launched. Measured rather
//! than reasoned: `system_colors.repaintForColorChange` was cut down to a bare
//! cache drop with no `RedrawWindow` at all, and `chrome-theme.ps1` still
//! reported ALL PASS across 129 assertions.
//!
//! So the repaint is counted where it happens instead. A `WM_PAINT` handler
//! calls `record`, and under `GHOZTTY_PAINT_PROBE` each call prints one line:
//!
//!     paint-probe surface=viewer_toc n=3
//!
//! A script reads those lines out of the app's stderr, which is a channel the
//! camera cannot contaminate: `WM_PRINTCLIENT` deliberately does NOT record,
//! because a paint the harness asked for is exactly the thing that must not
//! count as the app repainting on its own. That asymmetry is the whole oracle
//! — leave it alone.
//!
//! The counters are UI-thread only, like `system_colors`' accent cache, and
//! for the same reason: every `WM_PAINT` is delivered on the thread that owns
//! the window. There is no lock because there is no second reader, and adding
//! one would imply otherwise.
//!
//! Cost when the env var is absent: one already-resolved bool test per paint.
//! The counters still advance so a probe enabled by a later build of the same
//! run cannot report a count that never started at zero.

const std = @import("std");

const log = std.log.scoped(.paint_probe);

/// The surfaces worth counting. Small on purpose: a probe is added when a
/// claim about repainting needs an oracle, not preemptively.
pub const Surface = enum {
    /// The top-level `GhozttyWindow` chrome — caption, tab strip, dividers.
    /// Note for anyone writing an assertion on it: the hero carousel
    /// refreshes its thumbnails on a 150ms timer, so this counter advances
    /// on its own while hero mode is active. `viewer_toc` is the quiet
    /// surface.
    window,
    /// The viewer's contents card (`GhozttyViewerTOC`), a real child HWND.
    /// It repaints only when something invalidates it, which is what makes it
    /// the surface T1405's assertion is written against — a child never
    /// receives a color-change broadcast itself, so its repaint can only have
    /// come from its owner's `RDW_ALLCHILDREN`.
    viewer_toc,
};

const surface_count = @typeInfo(Surface).@"enum".fields.len;

var counts = [_]u64{0} ** surface_count;
var enabled_cache: ?bool = null;

/// Count one paint of `surface` and return the new total. Pure but for the
/// module-level counters, so the arithmetic is testable without a window.
pub fn bump(surface: Surface) u64 {
    const i = @intFromEnum(surface);
    counts[i] += 1;
    return counts[i];
}

/// How many paints of `surface` have been counted so far.
pub fn count(surface: Surface) u64 {
    return counts[@intFromEnum(surface)];
}

/// Read the gate once. Env lookups are not free and a paint handler is a hot
/// path.
pub fn enabled() bool {
    if (enabled_cache) |e| return e;
    const e = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PAINT_PROBE");
    enabled_cache = e;
    return e;
}

/// Called from a `WM_PAINT` handler, and from nowhere else — see the module
/// comment for why `WM_PRINTCLIENT` must not call this.
pub fn record(surface: Surface) void {
    const n = bump(surface);
    if (!enabled()) return;
    log.info("paint-probe surface={s} n={d}", .{ @tagName(surface), n });
}

/// Test-only: the counters are module state, so a test that asserts on them
/// has to start from a known point.
fn resetForTest() void {
    counts = [_]u64{0} ** surface_count;
}

test "bump counts each surface independently" {
    resetForTest();
    defer resetForTest();

    try std.testing.expectEqual(@as(u64, 0), count(.window));
    try std.testing.expectEqual(@as(u64, 1), bump(.window));
    try std.testing.expectEqual(@as(u64, 2), bump(.window));
    try std.testing.expectEqual(@as(u64, 1), bump(.viewer_toc));
    try std.testing.expectEqual(@as(u64, 2), count(.window));
    try std.testing.expectEqual(@as(u64, 1), count(.viewer_toc));
}

test "record still counts when the probe is off" {
    resetForTest();
    defer resetForTest();

    // The line is what the env var gates, not the counting: a probe turned on
    // by an env var this process never saw would otherwise report totals that
    // silently began mid-run.
    record(.viewer_toc);
    record(.viewer_toc);
    try std.testing.expectEqual(@as(u64, 2), count(.viewer_toc));
}
