//! The live system color reads the chrome palette needs (T304). Everything
//! DERIVED from them is in `chrome_theme.zig`, which is pure and unit-tested;
//! this file is only the OS lookup, kept as small as it sounds.

const std = @import("std");
const w32 = @import("win32.zig");
const chrome_theme = @import("chrome_theme.zig");
const panel_theme = @import("panel_theme.zig");

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

/// The cached accent, and the only entry point a PAINT path should call.
///
/// Two registry opens per painted control is the wrong shape for a value that
/// changes when the user visits Settings and never otherwise, and T305's
/// instruction is explicit: invalidate the chrome on the change notification
/// rather than re-read it on every paint. `invalidate()` is called from
/// `WM_DWMCOLORIZATIONCOLORCHANGED` (the accent itself) and
/// `WM_SETTINGCHANGE` (the light/dark flip, which arrives separately and can
/// carry an accent change with it).
///
/// Single-threaded by construction: every caller is on the UI thread, inside a
/// window procedure or a paint it drives. There is no lock because there is no
/// second thread that may read it, and adding one would imply otherwise.
var cached_accent: ?Rgb = null;

pub fn accentCached() Rgb {
    if (cached_accent) |c| return c;
    const c = accentOrDefault();
    cached_accent = c;
    return c;
}

pub fn invalidate() void {
    cached_accent = null;
}

/// Read `HKCU\...\Themes\Personalize\AppsUseLightTheme`. True when the system
/// apps theme is light. A missing or erroring value is treated as light, which
/// is how the Personalize key reads before it is ever written.
///
/// Lives here rather than in `Window` because it is a live system color read
/// and this file is where those are — `Window.systemUsesLightTheme` delegates
/// to it, so the panels and the chrome cannot end up asking the OS two
/// different questions.
pub fn usesLightTheme() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    const v = readDword(subkey, valname) orelse return true;
    return v != 0; // 0 = dark, nonzero = light
}

/// The palette a PANEL paints from (T308): the Activity Monitor, the machine
/// chooser, the hero carousel band.
///
/// The two inputs are the same ones `Window.chromePalette` resolves the chrome
/// from — the surface `window-theme` puts the app on, and the accent the user
/// picked — so a panel and the window behind it cannot disagree about which
/// theme is in force. `theme` is `anytype` for the reason `chrome_theme.
/// chromeBase`'s is: it keeps the pure module free of a config import.
///
/// Deliberately NOT debug-tinted. T43's marker is the chrome band, which is the
/// surface a user looks at to tell a dev build from their own terminal; a
/// tinted dialog would put amber on surfaces the acceptance scripts measure as
/// the proxy for what ships.
/// Memoized on its INPUTS rather than invalidated by a message, unlike the
/// accent above. `resolve` runs a contrast search per derived color and the
/// panels call this per painted row, so re-deriving an unchanged palette is
/// pure waste — but the light/dark read stays live, because a cache with two
/// invalidation sources is a cache that goes stale on the one nobody wired.
var panel_key: ?struct { base: Rgb, accent: Rgb } = null;
var panel_cache: panel_theme.Panel = undefined;

pub fn panelPalette(theme: anytype, terminal_bg: Rgb) panel_theme.Panel {
    const base = chrome_theme.chromeBase(theme, terminal_bg, usesLightTheme());
    const acc = accentCached();
    if (panel_key) |k| {
        if (k.base.eql(base) and k.accent.eql(acc)) return panel_cache;
    }
    panel_cache = panel_theme.resolve(base, acc);
    panel_key = .{ .base = base, .accent = acc };
    return panel_cache;
}

test "panelPalette: memoized on its inputs, and it follows them" {
    const testing = std.testing;
    const Theme = enum { auto, system, light, dark, ghostty };
    const term: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };

    const dark = panelPalette(Theme.dark, term);
    try testing.expectEqual(dark, panelPalette(Theme.dark, term));
    // A different base is a different palette, not the cached one.
    const light = panelPalette(Theme.light, term);
    try testing.expect(!light.bg.eql(dark.bg));
    try testing.expect(!light.text.eql(dark.text));
    // ...and going back re-resolves rather than handing back the light one.
    try testing.expectEqual(dark, panelPalette(Theme.dark, term));
}

test "accentCached: first read populates, invalidate forces a re-read" {
    const testing = std.testing;
    invalidate();
    try testing.expect(cached_accent == null);
    const first = accentCached();
    try testing.expectEqual(first, cached_accent.?);
    // Same answer from the cache as from the live read — the cache may not be
    // a different value, only a cheaper one.
    try testing.expectEqual(accentOrDefault(), accentCached());
    invalidate();
    try testing.expect(cached_accent == null);
    try testing.expectEqual(first, accentCached());
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
