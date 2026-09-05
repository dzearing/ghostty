//! T1345: the per-pane layered-chrome fan-out — what it costs to keep the
//! banner strip, the dim wash, the themed scrollbar, the read-only badge and
//! the key-state pill glued to their pane while the pane is moving.
//!
//! Every one of those is its own `WS_EX_LAYERED` popup (see
//! `overlay_zorder.zig` for why), so ONE mouse move during a splitter drag
//! fans out into a window reposition per popup per pane, plus — for the
//! per-pixel-alpha ones — a full `UpdateLayeredWindow` blit, plus a z-order
//! re-check that walks the desktop's window list. T1343 measured the drag and
//! found that after its frame-wait batching this fan-out is the MAJORITY of
//! what a motion tick costs (9.7 ms placing panes + 3.3 ms re-gluing overlays,
//! of a 15.8 ms move at 8 panes). Nothing had ever counted the individual
//! operations, only timed the block they happen inside, so "where does the
//! placement time go" was still a guess.
//!
//! This module is the counting and the two policy decisions, kept pure so they
//! unit-test in every lane. The Windows-facing halves live where the calls
//! are: `win32.healOverlayZOrder`, `Scrollbar.repaint`, `Window.zig`.
//!
//! ## Why a UI-thread global rather than a field on `Window`
//!
//! The overlays do not know their `Window`. A `Scrollbar` holds its owner
//! HWND, a `DimOverlay` holds its owner HWND, and threading a back-pointer
//! through five popup types to reach a counter would be a worse change than
//! the one being measured. Every one of these calls happens on the UI thread —
//! they are `SetWindowPos`/`UpdateLayeredWindow` on windows this thread owns —
//! so a plain global is the honest shape. `state` below is only ever touched
//! from there.

const std = @import("std");
const testing = std.testing;

/// Which piece of per-pane chrome a counted operation belongs to. The total
/// alone says the fan-out is expensive; the breakdown says which popup to go
/// after, which is the difference between a measurement and a number.
pub const Kind = enum {
    scrollbar,
    dim,
    banner,
    badge,
    key_state,

    pub const count = @typeInfo(Kind).@"enum".fields.len;
};

/// One layout pass's worth of chrome operations. Reset at the top of a pass,
/// read at the bottom, folded into the drag sample.
pub const Counts = struct {
    /// `SetWindowPos` calls issued against a layered chrome popup.
    moves: u32 = 0,
    /// The same, split by which popup issued it.
    moves_by: [Kind.count]u32 = @splat(0),
    /// `UpdateLayeredWindow` blits — the expensive half, since each one
    /// allocates and fills a BGRA bitmap the size of the popup.
    blits: u32 = 0,
    /// Blits the content check found unnecessary: the popup is the same size
    /// and would have been painted with the same pixels.
    blits_skipped: u32 = 0,
    /// Z-order re-checks actually performed. Each one walks the z-order with
    /// `GetWindow`, which is a kernel transition per step.
    heals: u32 = 0,
    /// Heals `shouldHeal` declined, because the popup was already on screen
    /// and the pass cannot have moved it in the z-order.
    heals_skipped: u32 = 0,

    pub fn reset(self: *Counts) void {
        self.* = .{};
    }

    pub fn moveCount(self: Counts, kind: Kind) u32 {
        return self.moves_by[@intFromEnum(kind)];
    }

    /// Chrome operations that reached the window manager — the number that
    /// scales with the pane count and that the fix is trying to bring down.
    pub fn total(self: Counts) u32 {
        return self.moves +| self.blits +| self.heals;
    }
};

/// Whether a reposition of a layered overlay has to re-check its z-order.
///
/// The heal exists for two states an overlay can get into (T142): a stray
/// `WS_EX_TOPMOST` set by another process, and the lift `SWP_SHOWWINDOW` gives
/// a popup that was hidden. Neither can happen *inside* a layout pass that is
/// only moving already-visible popups with `SWP_NOZORDER` — the z-order is not
/// an input to that pass and nothing else runs on this thread while it does.
///
/// So during a suppressed pass an already-shown overlay skips the walk, and a
/// hidden→shown transition still heals, which is the case that needs it. A
/// pass that is not suppressed heals exactly as it always did, and `WM_ACTIVATE`
/// still heals every overlay this window owns whichever way this went.
pub fn shouldHeal(in: struct {
    /// A live layout pass is in progress (`Window.layoutSplitsLive`).
    suppressed: bool,
    /// The overlay was already visible before this reposition.
    was_shown: bool,
}) bool {
    if (!in.suppressed) return true;
    return !in.was_shown;
}

/// Whether a layered popup has to be re-blitted, given what it looked like
/// last time and what it would look like now.
///
/// A `UpdateLayeredWindow` blit is not a repaint of a dirty region: it hands
/// the compositor a whole new bitmap, so it costs the popup's full area every
/// time regardless of how little changed. The size is load-bearing on the
/// "must blit" side — a popup that was RESIZED keeps its old layered surface
/// until something hands over a new one, so skipping there would leave stale
/// pixels stretched or clipped, which is the exact defect T1343 was told not
/// to reintroduce.
pub fn shouldBlit(prev: ?Signature, now: Signature) bool {
    const p = prev orelse return true;
    return !Signature.eql(p, now);
}

/// `shouldBlit` against the live state: the legacy shape has no memory of what
/// it painted, so it always blits.
pub fn blitNeeded(prev: ?Signature, now: Signature) bool {
    return shouldBlit(if (state.legacy) null else prev, now);
}

/// Whether a popup already on screen at `same_placement` can skip its move.
/// The legacy shape re-issues it, which is what the two `WM_MOVE`/`WM_SIZE`
/// arms of one pane placement used to do.
pub fn moveNeeded(shown: bool, same_placement: bool) bool {
    if (state.legacy) return true;
    return !shown or !same_placement;
}

/// Everything that decides what a chrome popup's pixels are. Two signatures
/// that compare equal describe the same bitmap at the same size, so the blit
/// between them would hand the compositor what it already has.
pub const Signature = struct {
    width: i32 = 0,
    height: i32 = 0,
    /// Packed BGRA of the track/background fill, 0 for fully transparent.
    fill: u32 = 0,
    /// Packed BGRA of the moving part (the scrollbar thumb).
    accent: u32 = 0,
    /// The moving part's rect within the popup.
    accent_y: i32 = 0,
    accent_h: i32 = 0,

    pub fn eql(a: Signature, b: Signature) bool {
        return a.width == b.width and
            a.height == b.height and
            a.fill == b.fill and
            a.accent == b.accent and
            a.accent_y == b.accent_y and
            a.accent_h == b.accent_h;
    }
};

/// UI-thread-only fan-out state. See the module header for why this is a
/// global.
pub const State = struct {
    counts: Counts = .{},
    /// Nesting depth of live layout passes. A nested pass joins the outer
    /// one rather than lifting the suppression when it ends.
    suppress_depth: u32 = 0,
    /// `GHOZTTY_CHROME_FANOUT_LEGACY`: put the pre-T1345 fan-out back — heal on
    /// every reposition, blit on every reposition, no placement cache, no
    /// batched wash — so both shapes can be measured on ONE build.
    ///
    /// This is not a compatibility hatch, it is the measurement's control. The
    /// improvement here is a few milliseconds of a mouse move on a box whose
    /// run-to-run spread is about that wide, so "compare today's number to the
    /// one written down yesterday" cannot tell a fix from a quiet afternoon.
    /// `GHOZTTY_DRAG_SERIAL_WAIT` exists for exactly this reason on T1343's
    /// half of the same drag.
    legacy: bool = false,

    pub fn suppressed(self: State) bool {
        return !self.legacy and self.suppress_depth > 0;
    }

    pub fn beginSuppress(self: *State) void {
        self.suppress_depth +|= 1;
    }

    pub fn endSuppress(self: *State) void {
        if (self.suppress_depth > 0) self.suppress_depth -= 1;
    }
};

pub var state: State = .{};

/// Record a chrome reposition. Called from the popup types' reposition paths.
pub fn noteMove(kind: Kind) void {
    state.counts.moves +|= 1;
    state.counts.moves_by[@intFromEnum(kind)] +|= 1;
}

pub fn noteBlit() void {
    state.counts.blits +|= 1;
}

pub fn noteBlitSkipped() void {
    state.counts.blits_skipped +|= 1;
}

pub fn noteHeal() void {
    state.counts.heals +|= 1;
}

pub fn noteHealSkipped() void {
    state.counts.heals_skipped +|= 1;
}

test "a live pass skips the z-order walk for overlays that were already up" {
    // The whole claim the suppression rests on: an already-shown popup being
    // moved with SWP_NOZORDER cannot have changed places.
    try testing.expect(!shouldHeal(.{ .suppressed = true, .was_shown = true }));

    // A popup coming back from hidden is exactly the case the heal exists for
    // (SWP_SHOWWINDOW lifts it above unrelated windows), so it still heals
    // even mid-drag.
    try testing.expect(shouldHeal(.{ .suppressed = true, .was_shown = false }));

    // Outside a live pass nothing is skipped, whatever the popup's state.
    try testing.expect(shouldHeal(.{ .suppressed = false, .was_shown = true }));
    try testing.expect(shouldHeal(.{ .suppressed = false, .was_shown = false }));
}

test "a blit is skipped only when the same pixels at the same size would land" {
    const base: Signature = .{
        .width = 12,
        .height = 400,
        .fill = 0,
        .accent = 0xC0FFFFFF,
        .accent_y = 10,
        .accent_h = 80,
    };

    // Nothing has ever been blitted — the popup's layered surface is empty.
    try testing.expect(shouldBlit(null, base));

    // Same everything: the compositor already holds this bitmap.
    try testing.expect(!shouldBlit(base, base));

    // A vertical-divider drag changes the pane's WIDTH, which moves the
    // scrollbar without changing its bitmap at all. This is the case the skip
    // is worth having.
    var moved = base;
    moved.accent_y = base.accent_y; // position on screen is not in the bitmap
    try testing.expect(!shouldBlit(base, moved));

    // A resize must blit: the old layered surface is the wrong size and
    // skipping leaves stale pixels, which is the flicker T1343 forbade.
    var taller = base;
    taller.height = 500;
    try testing.expect(shouldBlit(base, taller));

    var wider = base;
    wider.width = 14;
    try testing.expect(shouldBlit(base, wider));

    // Scroll position, colors and the thumb's own size all change pixels.
    var scrolled = base;
    scrolled.accent_y = 40;
    try testing.expect(shouldBlit(base, scrolled));

    var recolored = base;
    recolored.accent = 0xFFFF0000;
    try testing.expect(shouldBlit(base, recolored));

    var refilled = base;
    refilled.fill = 0xFF202020;
    try testing.expect(shouldBlit(base, refilled));

    var fatter = base;
    fatter.accent_h = 120;
    try testing.expect(shouldBlit(base, fatter));
}

test "a move is counted against the popup that issued it" {
    // The breakdown is the point: 22 moves per mouse move says the fan-out is
    // expensive, "8 scrollbar + 14 dim" says where to look next.
    state.counts.reset();
    for (0..8) |_| noteMove(.scrollbar);
    for (0..14) |_| noteMove(.dim);

    try testing.expectEqual(@as(u32, 22), state.counts.moves);
    try testing.expectEqual(@as(u32, 8), state.counts.moveCount(.scrollbar));
    try testing.expectEqual(@as(u32, 14), state.counts.moveCount(.dim));
    try testing.expectEqual(@as(u32, 0), state.counts.moveCount(.banner));
    state.counts.reset();
    try testing.expectEqual(@as(u32, 0), state.counts.moveCount(.dim));
}

test "counts accumulate and reset, and total is what reached the window manager" {
    var c: Counts = .{};
    try testing.expectEqual(@as(u32, 0), c.total());

    c.moves = 16;
    c.blits = 8;
    c.blits_skipped = 24;
    c.heals = 2;
    c.heals_skipped = 30;
    // Skipped work is counted so a regression that stops skipping is visible,
    // but it is not part of what the pass paid.
    try testing.expectEqual(@as(u32, 26), c.total());

    c.reset();
    try testing.expectEqual(@as(u32, 0), c.total());
    try testing.expectEqual(@as(u32, 0), c.blits_skipped);
    try testing.expectEqual(@as(u32, 0), c.heals_skipped);
}

test "suppression nests, and a nested pass ending does not lift it" {
    var s: State = .{};
    try testing.expect(!s.suppressed());

    s.beginSuppress();
    try testing.expect(s.suppressed());

    s.beginSuppress();
    s.endSuppress();
    // The outer pass is still running.
    try testing.expect(s.suppressed());

    s.endSuppress();
    try testing.expect(!s.suppressed());

    // An unbalanced close cannot wrap the depth around into "suppressed
    // forever", which would silently disable the heal for the process.
    s.endSuppress();
    try testing.expect(!s.suppressed());
}
