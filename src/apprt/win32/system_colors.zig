//! The live system color reads the chrome palette needs (T304). Everything
//! DERIVED from them is in `chrome_theme.zig`, which is pure and unit-tested;
//! this file is only the OS lookup, kept as small as it sounds.

const std = @import("std");
const w32 = @import("win32.zig");
const chrome_theme = @import("chrome_theme.zig");

const Rgb = chrome_theme.Rgb;

/// The user's accent color, or null when the system does not say.
///
/// Two sources, both DWORDs in Windows' ABGR encoding, both of which read
/// `0xFF810068` -> `#680081` on this box (2026-08-01), matching the accent
/// T302 recorded:
///
///   1. `HKCU\Software\Microsoft\Windows\DWM\AccentColor` — what DWM itself
///      paints borders and title bars with. Authoritative.
///   2. `HKCU\...\CurrentVersion\Explorer\Accent\AccentColorMenu` — Explorer's
///      copy of the same value, and the key T203's acceptance script flips.
///
/// `AccentPalette` under the same Explorer key is deliberately NOT read for
/// the light/dark variants, even though it holds eight shades: its index
/// semantics are reverse-engineered, and on this box index 3 — the index
/// usually claimed to BE the accent — is `#A94DC1`, a color the user never
/// picked. `chrome_theme` derives the variants instead, which is deterministic
/// and testable without a registry.
///
/// `DwmGetColorizationColor` is not used either: it returns the composed
/// colorization color (blended with the afterglow and the opacity slider),
/// which is a different quantity — on this box `ColorizationColor` is
/// `0xC4680081`, whose alpha byte would be read as a channel by any caller
/// expecting an accent.
pub fn accent() ?Rgb {
    if (readDword(
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\DWM"),
        std.unicode.utf8ToUtf16LeStringLiteral("AccentColor"),
    )) |v| return chrome_theme.accentFromDword(v);

    if (readDword(
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("AccentColorMenu"),
    )) |v| return chrome_theme.accentFromDword(v);

    return null;
}

/// The accent to paint with: the system's, else `chrome_theme.default_accent`
/// (Windows' own default). Callers that just want a color use this; callers
/// that need to know whether the system answered use `accent()`.
pub fn accentOrDefault() Rgb {
    return accent() orelse chrome_theme.default_accent;
}

test "accentOrDefault falls back exactly when the system does not answer" {
    // Runs on the box, so it exercises the real registry read — but it cannot
    // assert a PARTICULAR accent without failing on anyone else's machine.
    // What is always true is the relationship between the two entry points,
    // and asserting it is what makes this file compile in the win32 lane.
    const testing = std.testing;
    if (accent()) |a| {
        try testing.expectEqual(a, accentOrDefault());
    } else {
        try testing.expectEqual(chrome_theme.default_accent, accentOrDefault());
    }
}

fn readDword(subkey: [*:0]const u16, valname: [*:0]const u16) ?u32 {
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) !=
        w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(hkey);

    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, valname, null, &kind, @ptrCast(&val), &cb) !=
        w32.ERROR_SUCCESS) return null;
    // A REG_DWORD that is not four bytes is not a color; treating a short read
    // as one would hand back three channels of uninitialized stack.
    if (kind != w32.REG_DWORD or cb != @sizeOf(u32)) return null;
    return val;
}
