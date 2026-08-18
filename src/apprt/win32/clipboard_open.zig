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

const std = @import("std");
const w32 = @import("win32.zig");

/// Eight attempts, 15ms apart: ~120ms worst case, which covers the
/// milliseconds-long holds a normal copy produces without stalling a keypress.
pub const attempts: u32 = 8;
pub const retry_ms: u32 = 15;

/// Open the clipboard for this process, retrying briefly while another process
/// holds it. Returns false only when it stayed held for the whole budget.
///
/// On success the caller owns the clipboard and MUST `CloseClipboard` — the
/// usual shape being `defer _ = w32.CloseClipboard();` on the next line.
pub fn open(owner: ?w32.HWND) bool {
    var i: u32 = 0;
    while (i < attempts) : (i += 1) {
        if (w32.OpenClipboard(owner) != 0) return true;
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
