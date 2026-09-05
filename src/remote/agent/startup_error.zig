//! One-shot, pre-daemon error surface for `ghoztty-agent` on Windows.
//!
//! The agent is built as the GUI subsystem (see `src/build/GhosttyAgent.zig`),
//! so a launch from the app, the Start Menu or the HKCU Run entry has no
//! console for stderr to land in. When the daemon cannot start at all — today
//! that is a failed first-run enrollment (`main.zig`'s `autoEnrollForRelay`) —
//! a message box is the only thing the human ever sees. Without it the failure
//! is a process that exits silently.
//!
//! This used to live inside `tray.zig` as the "pre-tray" error box. T550
//! retired the tray (the consolidated agent ships inside Ghoztty and has no UI
//! of its own — the product's account surface is the machine chooser), and the
//! startup box is the one piece of it that was never about the tray: it fires
//! BEFORE any daemon setup, at a point where no icon or window has ever
//! existed.
//!
//! Blocks until dismissed; every caller exits immediately after, so nothing
//! else is stalled. No-op on non-Windows targets (notably the macOS host that
//! runs `zig build test-agent`), so callers need no platform gate of their own.

const std = @import("std");
const builtin = @import("builtin");

/// Show a modal error box titled "Ghoztty Agent". No-op off Windows.
pub fn show(text: []const u8) void {
    if (builtin.os.tag != .windows) return;
    win.show(text);
}

const win = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;
    const UINT = w.UINT;
    const HWND = w.HWND;

    const MB_OK: UINT = 0x0000;
    const MB_ICONERROR: UINT = 0x0010;

    extern "user32" fn MessageBoxW(
        hWnd: ?HWND,
        lpText: [*:0]const u16,
        lpCaption: [*:0]const u16,
        uType: UINT,
    ) callconv(.winapi) i32;

    fn show(text: []const u8) void {
        var buf: [512]u16 = undefined;
        // Owner HWND is null — no window of ours exists at these failures.
        _ = MessageBoxW(null, utf16(&buf, text), lit("Ghoztty Agent"), MB_OK | MB_ICONERROR);
    }

    /// Copy `src` into `dst` as a NUL-terminated UTF-16LE string, truncating to
    /// fit. Invalid UTF-8 (which our inputs never are) degrades to an ASCII
    /// copy rather than showing nothing.
    fn utf16(dst: []u16, src: []const u8) [*:0]const u16 {
        const room = dst.len - 1; // leave space for the NUL
        const written = std.unicode.utf8ToUtf16Le(dst[0..room], src) catch
            copyAsciiLossy(dst[0..room], src);
        dst[written] = 0;
        return @ptrCast(dst.ptr);
    }

    fn copyAsciiLossy(dst: []u16, src: []const u8) usize {
        var i: usize = 0;
        while (i < src.len and i < dst.len) : (i += 1) {
            dst[i] = if (src[i] < 0x80) src[i] else '?';
        }
        return i;
    }

    inline fn lit(comptime s: []const u8) [*:0]const u16 {
        return std.unicode.utf8ToUtf16LeStringLiteral(s);
    }
} else struct {};

test "show is a no-op off Windows and links on Windows" {
    // The value here is the COMPILE: this module is only reachable from the
    // Windows daemon paths, so without an explicit reference the test lane on
    // the macOS host would never type-check the non-Windows stub, and the
    // win32 lane would never type-check the MessageBoxW binding.
    if (builtin.os.tag != .windows) show("startup failed");
    try std.testing.expect(true);
}
