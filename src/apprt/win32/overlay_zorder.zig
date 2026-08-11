//! Z-order policy for the win32 layered overlays — the banner strip
//! (`BannerOverlay`), the dim overlay (`DimOverlay`), the themed scrollbar
//! (`Scrollbar`), the read-only badge, the key-state indicator, the
//! hovered-URL bubble (`Surface.setMouseOverLink`, T180) and the resize
//! overlay (`Window.showResizeOverlay`). All of
//! them are `WS_POPUP` windows owned by the pane/window they decorate, which
//! is what keeps them glued above the terminal content: Windows never lets
//! an owned window sink below its owner, so the *relative* ordering is an
//! invariant we get for free.
//!
//! What ownership does NOT give us is anything about the windows in between.
//! Two ways an overlay ends up floating over OTHER applications, both of
//! them permanent until something re-places the popup — and until T142
//! every reposition said `SWP_NOZORDER`, i.e. "don't touch the z-order":
//!
//!   1. A stray `WS_EX_TOPMOST`. We never set it on an overlay, but any
//!      other process can (T142: a T131 verification probe did exactly that
//!      and never put it back, so for the rest of the day the banners of
//!      background windows sat over whatever was in front).
//!   2. Simply being SHOWN while its owner is not in front. `SWP_SHOWWINDOW`
//!      lifts a popup to the top of the non-topmost band, above unrelated
//!      windows — and it stays there. This one needs no stray probe at all,
//!      and it is measurable at baseline: `overlay-zorder.ps1` found a
//!      freshly-set banner on a BACKGROUND window sitting above the
//!      foreground window of the same app.
//!
//! So a reposition now re-checks both and heals them
//! (`win32.healOverlayZOrder` + `seatedAboveOwner`). The topmost check is
//! owner-RELATIVE, which is the subtlety: an overlay is *supposed* to be
//! topmost when its owner is, because Windows propagates the bit to owned
//! windows. That happens for real — `toggle_window_float_on_top`
//! (`App.zig`) and the quick terminal both make a window topmost — so
//! "clear the bit whenever we see it" would drop the banner out of the
//! topmost band and hide it behind its own window. Only an overlay that is
//! topmost while its owner is NOT is a stray.
//!
//! No OS imports, so this unit-tests in every app-runtime lane (the
//! `split_geometry.zig` pattern); the windowing half is `healOverlayZOrder`
//! in `win32.zig`.

const std = @import("std");
const testing = std.testing;

/// `WS_EX_TOPMOST`. Duplicated from `win32.zig` so this policy stays
/// importable from lanes with no win32 bindings; `win32.zig` asserts at
/// comptime that the two agree.
pub const ex_topmost: u32 = 0x00000008;

pub fn isTopmost(ex_style: u32) bool {
    return ex_style & ex_topmost != 0;
}

/// True when the overlay's topmost bit is one nobody in this app asked for:
/// set on the overlay while its owner's top-level window is not topmost.
/// Such an overlay floats over other applications' foreground windows and,
/// unhealed, stays that way forever.
///
/// `owner_ex` must come from the owner's TOP-LEVEL ancestor: `WS_EX_TOPMOST`
/// is a property of top-level windows, and our pane overlays are owned by a
/// child (the surface HWND), which never carries the bit.
pub fn isStray(overlay_ex: u32, owner_ex: u32) bool {
    return isTopmost(overlay_ex) and !isTopmost(owner_ex);
}

/// How many times a band change is attempted before we give up and log
/// (T277). `SetWindowPos` can report SUCCESS on a `HWND_TOPMOST` it did not
/// make: measured on this box with no foreground window (a background
/// desktop, a locked session, the gap between two windows taking focus), the
/// first call returns TRUE with `GetLastError() == 0` and `WS_EX_TOPMOST`
/// still clear, while an identical call issued immediately after takes. So
/// the outcome is READ BACK rather than inferred from the return value.
///
/// Three, not one and not a spin: the second attempt is the one that has been
/// observed to land, and a window that will not change bands at all must not
/// wedge the UI thread.
pub const band_change_attempts: u8 = 3;

/// True once the window's ex-style agrees with the band we asked for, i.e.
/// there is nothing left to retry. The only honest test of a band change,
/// because the API's own success value does not imply it.
pub fn bandSettled(ex_style: u32, want_topmost: bool) bool {
    return isTopmost(ex_style) == want_topmost;
}

test "bandSettled: only the ex-style answers, in both directions" {
    try testing.expect(bandSettled(ex_topmost, true));
    try testing.expect(!bandSettled(0, true));
    try testing.expect(bandSettled(0, false));
    try testing.expect(!bandSettled(ex_topmost, false));
    // Unrelated bits never decide it. 0x100 is WS_EX_WINDOWEDGE, which every
    // ordinary top-level window carries — and is exactly what the failing
    // T277 read back looked like.
    try testing.expect(!bandSettled(0x100, true));
    try testing.expect(bandSettled(0x100, false));
    try testing.expect(bandSettled(0x100 | ex_topmost, true));
}

test "band_change_attempts leaves room for the retry that lands" {
    // One attempt is the bug this constant exists to fix; an unbounded spin
    // would hang the UI thread on a window that will not move.
    try testing.expect(band_change_attempts >= 2);
    try testing.expect(band_change_attempts <= 5);
}

/// One window seen while walking DOWN from the owner through the windows
/// stacked directly above it, looking for the overlay.
pub const WalkWindow = struct {
    /// This is the overlay we are placing.
    is_self: bool,
    /// Hidden windows are in the z-order but cannot occlude anything.
    is_visible: bool,
    /// Another popup owned by the same window — a sibling overlay of another
    /// pane. Harmless between us and our owner.
    is_sibling: bool,
};

pub const WalkStep = enum {
    /// The overlay is already seated directly above its owner (modulo
    /// hidden and sibling windows): nothing to do.
    seated,
    /// This window neither is us nor could occlude us: look further down.
    keep_walking,
    /// A foreign visible window sits between the overlay and its owner —
    /// which means the overlay is somewhere above it, over other apps.
    reseat,
};

pub fn walkStep(w: WalkWindow) WalkStep {
    if (w.is_self) return .seated;
    if (!w.is_visible) return .keep_walking;
    if (w.is_sibling) return .keep_walking;
    return .reseat;
}

test "walkStep: seated when we are the first thing above the owner" {
    try testing.expectEqual(WalkStep.seated, walkStep(.{
        .is_self = true,
        .is_visible = true,
        .is_sibling = true,
    }));
    // Ourselves while hidden still counts as seated — a hidden overlay has
    // no z-order problem, and hiding is how the panes of inactive tabs park.
    try testing.expectEqual(WalkStep.seated, walkStep(.{
        .is_self = true,
        .is_visible = false,
        .is_sibling = true,
    }));
}

test "walkStep: hidden and sibling windows do not count as occluders" {
    // A hidden window of any provenance: keep looking.
    try testing.expectEqual(WalkStep.keep_walking, walkStep(.{
        .is_self = false,
        .is_visible = false,
        .is_sibling = false,
    }));
    // Another pane's overlay on the same window: fine to be above us.
    try testing.expectEqual(WalkStep.keep_walking, walkStep(.{
        .is_self = false,
        .is_visible = true,
        .is_sibling = true,
    }));
}

test "walkStep: a foreign visible window between us and the owner means reseat" {
    try testing.expectEqual(WalkStep.reseat, walkStep(.{
        .is_self = false,
        .is_visible = true,
        .is_sibling = false,
    }));
}

test "isStray only fires on overlay-topmost, owner-not" {
    // WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW — what the pane
    // overlays are actually created with.
    const overlay: u32 = 0x00080000 | 0x08000000 | 0x00000080;
    // A plain window (WS_EX_APPWINDOW-ish) and a float-on-top one.
    const plain: u32 = 0x00040000;
    const floating: u32 = plain | ex_topmost;

    // Healthy: neither is topmost.
    try testing.expect(!isStray(overlay, plain));
    // The T142 defect: a stray probe topmosted the overlay only.
    try testing.expect(isStray(overlay | ex_topmost, plain));
    // Legitimate: `toggle_window_float_on_top` / quick terminal — the OS
    // propagates the owner's bit to the overlay, and clearing it would hide
    // the banner behind its own window.
    try testing.expect(!isStray(overlay | ex_topmost, floating));
    // Owner topmost, overlay not (mid-propagation): not ours to "fix" by
    // clearing a bit that is already clear.
    try testing.expect(!isStray(overlay, floating));
}

test "isTopmost reads only the topmost bit" {
    try testing.expect(!isTopmost(0));
    try testing.expect(isTopmost(ex_topmost));
    try testing.expect(!isTopmost(~ex_topmost));
    try testing.expect(isTopmost(0xFFFFFFFF));
}
