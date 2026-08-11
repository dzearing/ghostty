//! "Is this one of our windows the ACTIVE one?" — the single reading of
//! activation the win32 apprt is allowed to make (T215).
//!
//! The obvious way to ask is `GetForegroundWindow`, and every site that used
//! to ask it that way was silently always-false on a **background desktop**:
//! one created with `CreateDesktopW` (which is how the acceptance harness runs
//! the GUI without stealing the user's foreground), and equally a locked
//! workstation, a UAC secure desktop or a disconnected RDP session. There is
//! no foreground window at all on such a desktop — the API returns null for
//! every window on it — so a guard written that way stops guarding and starts
//! answering "no", forever, with no error anywhere.
//!
//! T211 found the first instance (`App.performDeferredFocus` dropped every
//! queued focus assert, so keyboard focus could not move between panes at
//! all). T223 then found the way NOT to fix it: waving the guard through
//! unconditionally off the input desktop restored the entire T105 focus
//! live-lock there, 43 focus flips in 3 s. The lesson that module docs exist
//! to keep: `GetForegroundWindow` was a **proxy** for a question that still
//! has an answer off the input desktop, so the fix is to find the proxy that
//! survives — not to conclude the question is moot.
//!
//! That proxy is `GetActiveWindow`, which is scoped to the calling thread's
//! message queue rather than to the input desktop. Every window this app
//! owns lives on the one GUI thread, so off the input desktop it still names
//! exactly one of ours.
//!
//! Two decisions come out of it, and they differ only in what "nothing known"
//! means:
//!
//!   - `isActive` — the *reporting* reading: is this window the one the user
//!     is working in? Used by `+list --json`'s `focused` field, by the IPC
//!     default target, by the viewer's TOC emphasis and by its hover reveal.
//!     Unknown ⇒ **false**: never claim focus we cannot prove.
//!   - `shouldForwardFocus` — the *deferred-assert* reading (T211/T223): may
//!     this queued `WM_APP_SETFOCUS` still fire? Unknown ⇒ **true**, because
//!     dropping every assert leaves keyboard focus unable to move at all,
//!     which is the failure T211 was fixed to prevent.
//!
//! On the input desktop both are byte-identical to what shipped before:
//! `foreground == window`, nothing else consulted. That is deliberate — the
//! interactive path is the one the T105 fix was measured on, and this module
//! changes only the desktop where the old answer carried no information.
//!
//! No OS imports, so it unit-tests in the `none` lane (the
//! `split_geometry.zig` pattern); the windowing half is `w32.activation()`
//! in `win32.zig`, which fills the struct by calling the OS.

const std = @import("std");
const testing = std.testing;

/// What the caller measured about activation at this moment. Window handles
/// are carried as their integer values (`@intFromPtr`) so this stays free of
/// win32 bindings; **0 means "no such window"**, which is what a null
/// `GetForegroundWindow`/`GetActiveWindow` answers with.
pub const Activation = struct {
    /// Whether this process's GUI thread runs on the desktop the user sees.
    on_input_desktop: bool,

    /// `GetForegroundWindow()`. Always 0 off the input desktop.
    foreground: usize,

    /// `GetActiveWindow()` on the GUI thread. Queue-scoped, so it still names
    /// one of our windows off the input desktop.
    active: usize,
};

/// True when `window` is the window activation currently sits on.
///
/// Callers that report or paint state ask this one. A `window` of 0 (an
/// unrealized window, or a failed `GetAncestor`) is never active.
pub fn isActive(a: Activation, window: usize) bool {
    if (window == 0) return false;
    if (a.on_input_desktop) return a.foreground == window;
    return a.active == window;
}

/// True when a deferred `WM_APP_SETFOCUS` aimed at `window` may still fire —
/// i.e. activation has not moved off it since the assert was queued.
///
/// Same proxy as `isActive`, opposite default: off the input desktop with no
/// active window at all, the query told us nothing, and forwarding is the
/// safe answer (T211). On the input desktop a null foreground is a real
/// answer — a transient state, e.g. the window being destroyed — and is not
/// treated as unknown.
pub fn shouldForwardFocus(a: Activation, window: usize) bool {
    if (window == 0) return false;
    if (a.on_input_desktop) return a.foreground == window;
    if (a.active == 0) return true;
    return a.active == window;
}

const root: usize = 0x1000;
const other: usize = 0x2000;

test "isActive: on the input desktop, foreground alone decides" {
    try testing.expect(isActive(.{
        .on_input_desktop = true,
        .foreground = root,
        .active = other,
    }, root));
    try testing.expect(!isActive(.{
        .on_input_desktop = true,
        .foreground = other,
        .active = root,
    }, root));
    // No foreground window at all still means "not ours" on the input
    // desktop, exactly as the pre-T215 comparison did.
    try testing.expect(!isActive(.{
        .on_input_desktop = true,
        .foreground = 0,
        .active = root,
    }, root));
}

test "isActive: off the input desktop, the queue-scoped active window decides" {
    // Foreground is always null off the input desktop and carries no
    // information there, so it must not change the answer either way.
    try testing.expect(isActive(.{
        .on_input_desktop = false,
        .foreground = 0,
        .active = root,
    }, root));
    try testing.expect(!isActive(.{
        .on_input_desktop = false,
        .foreground = 0,
        .active = other,
    }, root));
    try testing.expect(isActive(.{
        .on_input_desktop = false,
        .foreground = other,
        .active = root,
    }, root));
}

test "isActive: nothing known never claims focus" {
    // The reporting reading's default: `+list --json` must not mark a window
    // focused on the strength of a query that answered nothing.
    try testing.expect(!isActive(.{
        .on_input_desktop = false,
        .foreground = 0,
        .active = 0,
    }, root));
}

test "isActive: an unrealized window is never active" {
    try testing.expect(!isActive(.{
        .on_input_desktop = true,
        .foreground = 0,
        .active = 0,
    }, 0));
    // Not even when the OS reports no active window either — 0 == 0 must not
    // read as a match.
    try testing.expect(!isActive(.{
        .on_input_desktop = false,
        .foreground = 0,
        .active = 0,
    }, 0));
}

test "shouldForwardFocus: input desktop forwards only to the foreground window" {
    try testing.expect(shouldForwardFocus(.{
        .on_input_desktop = true,
        .foreground = root,
        .active = root,
    }, root));
    try testing.expect(!shouldForwardFocus(.{
        .on_input_desktop = true,
        .foreground = other,
        .active = root,
    }, root));
    // No foreground window at all still means "not ours" on the input
    // desktop (a transient state there, e.g. the window being destroyed).
    try testing.expect(!shouldForwardFocus(.{
        .on_input_desktop = true,
        .foreground = 0,
        .active = root,
    }, root));
    // The active window is not consulted on the input desktop: foreground
    // alone decides, exactly as it did before T223.
    try testing.expect(shouldForwardFocus(.{
        .on_input_desktop = true,
        .foreground = root,
        .active = other,
    }, root));
    try testing.expect(shouldForwardFocus(.{
        .on_input_desktop = true,
        .foreground = root,
        .active = 0,
    }, root));
}

test "shouldForwardFocus: background desktop guards on the active window" {
    try testing.expect(shouldForwardFocus(.{
        .on_input_desktop = false,
        .foreground = 0,
        .active = root,
    }, root));
    try testing.expect(shouldForwardFocus(.{
        .on_input_desktop = false,
        .foreground = other,
        .active = root,
    }, root));
    // The stale assert of a window that is no longer this thread's active
    // window is dropped — that steal is the T105 restore ping-pong.
    try testing.expect(!shouldForwardFocus(.{
        .on_input_desktop = false,
        .foreground = 0,
        .active = other,
    }, root));
    try testing.expect(!shouldForwardFocus(.{
        .on_input_desktop = false,
        .foreground = root,
        .active = other,
    }, root));
}

test "shouldForwardFocus: background desktop with no active window still forwards" {
    // Nothing known about activation: forward, because dropping every assert
    // would leave keyboard focus unable to move at all (T211). This is the
    // one place the two readings deliberately disagree.
    const a: Activation = .{
        .on_input_desktop = false,
        .foreground = 0,
        .active = 0,
    };
    try testing.expect(shouldForwardFocus(a, root));
    try testing.expect(!isActive(a, root));
}
