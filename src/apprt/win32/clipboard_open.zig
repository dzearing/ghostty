//! Opening the Windows clipboard, retried.
//!
//! The clipboard is one machine-wide, serialized resource: `OpenClipboard`
//! fails outright — it does not queue — while ANY other process on the desktop
//! holds it, and something always does for a few milliseconds after a copy
//! (the copying app itself, Explorer, a clipboard-history service, a remote
//! desktop's clipboard bridge). A single attempt therefore has a small but
//! permanent failure rate that has nothing to do with the code asking.
//!
//! What that costs when it is not retried: the caller silently does nothing.
//! "Copy link did nothing" and "paste did nothing" are indistinguishable from
//! a bug in the feature, which is why every open in this codebase goes through
//! here rather than calling `OpenClipboard` once and giving up.
//!
//! The retry budget is deliberately short — eight attempts, 15ms apart, so a
//! failing open costs at most ~120ms and never blocks a keystroke for a
//! noticeable beat. It is not a lock: for a section that must hold the
//! clipboard's CONTENTS steady across several operations, the caller needs its
//! own cross-process mutex (T850), because another process may open, write and
//! close between two of ours.
//!
//! ## The open must name a WINDOW, or it excludes nobody (T992)
//!
//! `OpenClipboard(NULL)` succeeds and looks like a hold, but the exclusion
//! Windows enforces is "another WINDOW has the clipboard open", and a null
//! owner is not a window. Measured on this box, both arms:
//!
//! | owner passed | another process opening while we hold | our SetClipboardData |
//! |---|---|---|
//! | `NULL`       | **succeeds** — straight through          | fails, 1418 `ERROR_CLIPBOARD_NOT_OPEN` |
//! | a real HWND  | refused, 5 `ERROR_ACCESS_DENIED`         | succeeds |
//!
//! So a copy opened with a null owner is not atomic: its `EmptyClipboard` and
//! its `SetClipboardData` are two separate acts, and another app that opens
//! and closes between them ENDS our open — the user's copy then silently
//! yields that app's content, or nothing at all, with no error anywhere.
//! (Unobstructed it works, which is why this survived: the failure needs a
//! second app writing the clipboard in the same few milliseconds.)
//!
//! Callers therefore pass a window, and `null` no longer means "no owner": it
//! means "use the app's clipboard owner window", which `App.init` registers
//! here (`setDefaultOwner`) and which lives for the whole process. That
//! indirection is the point — the write sites that need an owner are static
//! helpers with no `App` in reach, and a call site that forgets is exactly how
//! this defect arrives a second time.

const std = @import("std");
const w32 = @import("win32.zig");

const log = std.log.scoped(.clipboard);

/// The process-lifetime window every clipboard open falls back to: the app's
/// message-only window (`App.msg_hwnd`), registered by `App.init`.
///
/// A single global rather than a parameter because the alternative is worse:
/// `ViewerPane.clipboardWriteText` and friends are file-scope helpers with no
/// `App` pointer, and threading one through every clipboard user is the kind
/// of plumbing that gets skipped on the next call site. GUI-thread only, set
/// once at startup and cleared in `deinit` before the window is destroyed, so
/// there is no race to guard.
var default_owner: ?w32.HWND = null;

/// Register the app's clipboard owner window. Called once by `App.init` after
/// `msg_hwnd` exists, and again with `null` in `App.deinit` before it is
/// destroyed — a stale handle here would make every clipboard open fail.
pub fn setDefaultOwner(hwnd: ?w32.HWND) void {
    default_owner = hwnd;
}

/// The window an open with no explicit owner will claim, or null when none is
/// registered (unit tests, and any CLI path with no app).
pub fn defaultOwner() ?w32.HWND {
    return default_owner;
}

/// The window `open(owner)` will actually pass to `OpenClipboard`.
///
/// A caller's own window wins when it is still alive; a destroyed one falls
/// back to the app's rather than to null, because a surface can be freed while
/// a clipboard request is in flight (the confirm dialog pumps messages) and
/// "the window went away" must not silently downgrade the open to the
/// excludes-nobody shape.
pub fn effectiveOwner(owner: ?w32.HWND) ?w32.HWND {
    if (owner) |h| {
        if (w32.IsWindow(h) != 0) return h;
    }
    if (default_owner) |h| {
        if (w32.IsWindow(h) != 0) return h;
    }
    return null;
}

/// Eight attempts, 15ms apart: ~120ms worst case, which covers the
/// milliseconds-long holds a normal copy produces without stalling a keypress.
pub const attempts: u32 = 8;
pub const retry_ms: u32 = 15;

/// Open the clipboard for this process, retrying briefly while another process
/// holds it. Returns false only when it stayed held for the whole budget.
///
/// `owner` is the window that will own the clipboard; pass `null` to use the
/// app's (see `effectiveOwner`). It is not decoration — see the module comment:
/// an open with no window at all excludes nobody, and the write it guards is
/// then not atomic.
///
/// On success the caller owns the clipboard and MUST `CloseClipboard` — the
/// usual shape being `defer _ = w32.CloseClipboard();` on the next line.
pub fn open(owner: ?w32.HWND) bool {
    const hwnd = effectiveOwner(owner);
    if (hwnd == null) {
        // Not fatal — an unobstructed write still lands, which is how this
        // shape went unnoticed — but it is the atomicity hole, so say so
        // rather than letting it be invisible.
        log.warn("clipboard open with no owner window: the write is not atomic (T992)", .{});
    }
    var i: u32 = 0;
    while (i < attempts) : (i += 1) {
        if (w32.OpenClipboard(hwnd) != 0) return true;
        if (i + 1 < attempts) w32.Sleep(retry_ms);
    }
    return false;
}

test "budget is bounded and non-trivial" {
    // Both halves matter: a single attempt is the bug this module exists to
    // fix, and an unbounded wait would hang a keystroke behind whatever other
    // process is misbehaving with the clipboard.
    try std.testing.expect(attempts > 1);
    try std.testing.expect(attempts * retry_ms <= 500);
}

test "with no owner registered, an open still resolves to no window" {
    // The CLI and the unit lanes have no App, so this has to stay legal — it
    // is the pre-T992 behavior, kept as the fallback rather than as the norm.
    setDefaultOwner(null);
    try std.testing.expect(effectiveOwner(null) == null);
}

test "a dead window falls back to the app's, never to no window" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    // The scenario: a surface is freed (its window destroyed) while a clipboard
    // request is in flight. Before T992 the write simply passed null and lost
    // its atomicity; the fallback must be the app's window, not none.
    const app_window = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("clipboard-owner-test"),
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(app_window);

    setDefaultOwner(app_window);
    defer setDefaultOwner(null);

    // A live caller window wins.
    try std.testing.expect(effectiveOwner(app_window) == app_window);

    // A handle that is not a window (the shape a freed surface leaves behind)
    // resolves to the app's, not to null.
    const dead: w32.HWND = @ptrFromInt(0x1);
    try std.testing.expect(w32.IsWindow(dead) == 0);
    try std.testing.expect(effectiveOwner(dead) == app_window);

    // And an explicit "no owner of my own" does too.
    try std.testing.expect(effectiveOwner(null) == app_window);
}

test "open then close leaves the clipboard takeable again" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    // The round trip proves the helper hands back a clipboard the caller
    // actually owns: a second open can only succeed if the first was really
    // closed, and a first open that quietly failed would make the assert
    // below pass for the wrong reason — so both are asserted.
    try std.testing.expect(open(null));
    _ = w32.CloseClipboard();
    try std.testing.expect(open(null));
    _ = w32.CloseClipboard();
}
