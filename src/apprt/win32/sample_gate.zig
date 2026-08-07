//! Pure "should this panel sample right now?" gate for the win32 Activity
//! Monitor (T290).
//!
//! T285's panel polls every `trend_gauge.sample_interval_ms`, and every poll is
//! a FULL process enumeration — `CreateToolhelp32Snapshot` plus an `OpenProcess`
//! and two per-pid queries, ~300 processes on this box. That is the right cost
//! for a panel someone is looking at and pure waste for one that is minimized,
//! hidden, or sitting on another virtual desktop, which is where a panel left
//! open for hours actually spends most of its life.
//!
//! The gate is a two-state machine — running or suspended — and it lives here,
//! away from `ActivityMonitor.zig`, so it can be tested in the `none` lane with
//! no window to minimize. `ActivityMonitor.zig` supplies the OS answers
//! (`IsWindowVisible` / `IsIconic` / `DWMWA_CLOAKED`) and carries out the
//! action.
//!
//! Two conventions the tests pin:
//!
//!   * **Resuming is a fresh start, not a continuation.** The trend rings are
//!     indexed by sample, not by time, so a ring stitched across a ten-minute
//!     suspension would draw those ten minutes as one pixel — a chart that
//!     silently lies about its own X axis. `.resume_fresh` says to clear the
//!     rings first, which is what a source switch already does
//!     (`ActivityMonitor.switchSource`) and what Mac does on a source change.
//!   * **Becoming visible samples immediately.** Waiting for the next tick
//!     would mean the first frame a user sees after restoring the panel is up
//!     to a full interval stale, which reads as a frozen panel. `onShown` is
//!     therefore safe to call from messages that fire often (a restore, a show,
//!     a paint): it does nothing at all unless the gate is suspended.

const std = @import("std");

/// What the OS says about the panel window at this instant. All three are cheap
/// queries; none of them enumerate anything.
pub const Visibility = struct {
    /// `IsWindowVisible` — false while the window is hidden outright.
    visible: bool = true,
    /// `IsIconic` — minimized to the taskbar.
    minimized: bool = false,
    /// `DWMWA_CLOAKED` — composed but not shown. This is how a window on
    /// ANOTHER VIRTUAL DESKTOP reports itself; there is no window message for
    /// that transition, which is why the gate re-checks on every tick rather
    /// than relying on `WM_SIZE`/`WM_SHOWWINDOW` alone.
    cloaked: bool = false,

    /// Whether a sample taken now could be seen by anyone.
    ///
    /// Deliberately NOT a stab at full occlusion: a window buried behind
    /// another is still `visible`, un-minimized and un-cloaked, and Windows has
    /// no cheap, reliable "am I covered" answer (the DWM has no such attribute,
    /// and walking the z-order intersecting region by region is both expensive
    /// and wrong the moment a window is partly transparent). Guessing at it
    /// would suspend a panel someone is watching, which is a worse failure than
    /// sampling one they are not.
    pub fn observable(self: Visibility) bool {
        return self.visible and !self.minimized and !self.cloaked;
    }
};

/// What the caller should do with this tick.
pub const Action = enum {
    /// Take a sample as usual.
    sample,
    /// Do nothing. No enumeration, no repaint, no ring write.
    skip,
    /// The panel just became observable again: clear the trend rings, then
    /// sample.
    resume_fresh,
};

pub const Gate = struct {
    /// True while the panel is known to be unobservable. Starts false so a
    /// panel that opens in view samples on its very first tick.
    suspended: bool = false,

    /// A poll tick fired. This is the only place the gate ENTERS suspension:
    /// the window messages can tell us a panel went away, but only a tick can
    /// notice a virtual-desktop switch, so one code path handles both.
    pub fn onTick(self: *Gate, v: Visibility) Action {
        if (!v.observable()) {
            self.suspended = true;
            return .skip;
        }
        if (self.suspended) {
            self.suspended = false;
            return .resume_fresh;
        }
        return .sample;
    }

    /// The window reported that it is back in view — a `WM_SIZE` restore, a
    /// `WM_SHOWWINDOW` show, or a paint after a desktop switch. Safe to call
    /// from a high-frequency message: it answers `.skip` unless the gate is
    /// actually suspended AND the window really is observable now.
    pub fn onShown(self: *Gate, v: Visibility) Action {
        if (!self.suspended) return .skip;
        if (!v.observable()) return .skip;
        self.suspended = false;
        return .resume_fresh;
    }

    /// The window reported that it went away — a `WM_SIZE` minimize or a
    /// `WM_SHOWWINDOW` hide. Suspends immediately rather than waiting up to a
    /// full interval for the next tick to notice.
    pub fn onHidden(self: *Gate) void {
        self.suspended = true;
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

const shown: Visibility = .{};
const iconic: Visibility = .{ .minimized = true };
const hidden: Visibility = .{ .visible = false };
const cloaked: Visibility = .{ .cloaked = true };

test "observable is all three conditions" {
    try testing.expect(shown.observable());
    try testing.expect(!iconic.observable());
    try testing.expect(!hidden.observable());
    try testing.expect(!cloaked.observable());
    try testing.expect(!(Visibility{ .visible = false, .minimized = true, .cloaked = true }).observable());
}

test "a visible panel samples on every tick" {
    var g: Gate = .{};
    try testing.expectEqual(Action.sample, g.onTick(shown));
    try testing.expectEqual(Action.sample, g.onTick(shown));
    try testing.expectEqual(Action.sample, g.onTick(shown));
    try testing.expect(!g.suspended);
}

test "minimized ticks skip, and keep skipping" {
    var g: Gate = .{};
    try testing.expectEqual(Action.sample, g.onTick(shown));
    try testing.expectEqual(Action.skip, g.onTick(iconic));
    try testing.expectEqual(Action.skip, g.onTick(iconic));
    try testing.expectEqual(Action.skip, g.onTick(iconic));
    try testing.expect(g.suspended);
}

test "a cloaked panel — another virtual desktop — suspends the same way" {
    var g: Gate = .{};
    try testing.expectEqual(Action.skip, g.onTick(cloaked));
    try testing.expect(g.suspended);
    // And a tick is what notices it came back: there is no message for it.
    try testing.expectEqual(Action.resume_fresh, g.onTick(shown));
}

test "a hidden panel suspends the same way" {
    var g: Gate = .{};
    try testing.expectEqual(Action.skip, g.onTick(hidden));
    try testing.expectEqual(Action.resume_fresh, g.onTick(shown));
}

test "resuming is fresh exactly once, then ordinary sampling" {
    var g: Gate = .{};
    _ = g.onTick(iconic);
    try testing.expectEqual(Action.resume_fresh, g.onTick(shown));
    try testing.expectEqual(Action.sample, g.onTick(shown));
    try testing.expectEqual(Action.sample, g.onTick(shown));
}

test "onShown resumes immediately rather than waiting for the tick" {
    var g: Gate = .{};
    g.onHidden();
    try testing.expect(g.suspended);
    try testing.expectEqual(Action.resume_fresh, g.onShown(shown));
    try testing.expect(!g.suspended);
    // The tick that follows is an ordinary one — the catch-up already happened,
    // so the ring is not cleared twice.
    try testing.expectEqual(Action.sample, g.onTick(shown));
}

test "onShown does nothing when the gate is not suspended" {
    var g: Gate = .{};
    try testing.expectEqual(Action.skip, g.onShown(shown));
    try testing.expectEqual(Action.skip, g.onShown(shown));
    try testing.expect(!g.suspended);
    // Which is what makes it safe to call from WM_PAINT.
    try testing.expectEqual(Action.sample, g.onTick(shown));
}

test "onShown refuses to resume while the window is still not observable" {
    var g: Gate = .{};
    g.onHidden();
    // A restore message can arrive while the window is still cloaked (a
    // desktop switch racing an un-minimize); believing it would resume a panel
    // nobody can see.
    try testing.expectEqual(Action.skip, g.onShown(cloaked));
    try testing.expect(g.suspended);
    try testing.expectEqual(Action.resume_fresh, g.onShown(shown));
}

test "onHidden is idempotent and a tick does not undo it" {
    var g: Gate = .{};
    g.onHidden();
    g.onHidden();
    try testing.expectEqual(Action.skip, g.onTick(iconic));
    try testing.expect(g.suspended);
}

test "a panel that opens in view never spends its first tick resuming" {
    var g: Gate = .{};
    try testing.expect(!g.suspended);
    try testing.expectEqual(Action.sample, g.onTick(shown));
}
