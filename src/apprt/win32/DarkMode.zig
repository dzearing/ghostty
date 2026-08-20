//! App-wide dark mode for classic USER-drawn UI that per-window theming
//! cannot reach — popup menus (`TrackPopupMenuEx`) in particular. Windows
//! has no documented API for dark context menus; Explorer and Windows
//! Terminal use undocumented-but-stable uxtheme ordinal exports:
//!
//!   - #135 `SetPreferredAppMode(mode)` (1903+; on 1809 the same ordinal
//!     is `AllowDarkModeForApp(BOOL)`)
//!   - #136 `FlushMenuThemes()`
//!   - #138 `ShouldSystemUseDarkMode()` (1903+ — probed only to detect
//!     which #135 signature this OS has)
//!
//! All lookups are by ordinal at runtime; on an OS where they are missing
//! everything degrades to a no-op and menus stay light (the pre-T79
//! behavior). The preferred mode is MAPPED from the one light/dark answer
//! `chrome_theme.isDark` gives the whole chrome (T309) rather than derived
//! again here, so menus match the title bar by construction: explicit
//! dark/light force the mode, `system` follows the OS apps theme (live,
//! across WM_SETTINGCHANGE), and `auto`/`ghostty` force the mode matching the
//! background luminance.

const std = @import("std");
const w32 = @import("win32.zig");
const chrome_theme = @import("chrome_theme.zig");

pub const AppMode = enum(i32) {
    default = 0,
    allow_dark = 1,
    force_dark = 2,
    force_light = 3,
};

const SetPreferredAppModeFn = *const fn (mode: i32) callconv(.winapi) i32;
const FlushMenuThemesFn = *const fn () callconv(.winapi) void;

var resolved: bool = false;
var set_preferred_app_mode: ?SetPreferredAppModeFn = null;
var flush_menu_themes: ?FlushMenuThemesFn = null;
/// True when ordinal #135 has the 1903+ `SetPreferredAppMode(enum)`
/// signature (probed via the presence of #138, also added in 1903).
var has_1903_signature: bool = false;

fn ordinal(n: u16) ?[*:0]const u8 {
    return @ptrFromInt(n);
}

fn resolve() void {
    if (resolved) return;
    resolved = true;
    const lib = w32.LoadLibraryW(
        std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll"),
    ) orelse return;
    set_preferred_app_mode = @ptrCast(w32.GetProcAddress(lib, ordinal(135)));
    flush_menu_themes = @ptrCast(w32.GetProcAddress(lib, ordinal(136)));
    has_1903_signature = w32.GetProcAddress(lib, ordinal(138)) != null;
}

/// The preferred app (menu) mode for a `window-theme` value + background
/// color, mapped onto the app-wide menu modes.
///
/// It does not decide light/dark itself — `chrome_theme.isDark` owns that one
/// answer for the whole chrome (T309), and this only maps it onto the three
/// menu modes. It used to re-derive it from its own inline luminance, which is
/// how the menus could in principle open on the opposite side from the title
/// bar over them.
///
/// `system` is the exception, and not a second derivation: it maps to
/// allow-dark, which is Windows' "follow the OS" mode, so menus track apps-theme
/// flips without anyone recomputing anything.
pub fn modeForTheme(theme: anytype, bg: anytype, system_light: bool) AppMode {
    const rgb: chrome_theme.Rgb = .{ .r = bg.r, .g = bg.g, .b = bg.b };
    return switch (theme) {
        .system => .allow_dark,
        else => if (chrome_theme.isDark(theme, rgb, system_light))
            .force_dark
        else
            .force_light,
    };
}

/// Set the app-wide preferred dark mode for USER menus and flush the menu
/// theme cache so menus created before the change re-evaluate. Idempotent
/// and cheap — called at app init, on config reload, and on
/// WM_SETTINGCHANGE (OS theme flips).
pub fn apply(theme: anytype, bg: anytype, system_light: bool) void {
    resolve();
    const set = set_preferred_app_mode orelse return;
    const mode = modeForTheme(theme, bg, system_light);
    const arg: i32 = if (has_1903_signature)
        @intFromEnum(mode)
    else switch (mode) {
        // 1809: ordinal #135 is AllowDarkModeForApp(BOOL).
        .default, .force_light => 0,
        .allow_dark, .force_dark => 1,
    };
    _ = set(arg);
    if (flush_menu_themes) |flush| flush();
}

test "modeForTheme decision table" {
    const Theme = enum { auto, system, light, dark, ghostty };
    const Rgb = struct { r: u8, g: u8, b: u8 };
    const dark_bg: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
    const light_bg: Rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff };

    // Explicit themes force the mode regardless of background.
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.dark, light_bg, true));
    try std.testing.expectEqual(AppMode.force_light, modeForTheme(Theme.light, dark_bg, false));

    // system follows the OS: allow-dark either way.
    try std.testing.expectEqual(AppMode.allow_dark, modeForTheme(Theme.system, dark_bg, false));
    try std.testing.expectEqual(AppMode.allow_dark, modeForTheme(Theme.system, light_bg, true));

    // auto/ghostty derive from background luminance.
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.auto, dark_bg, true));
    try std.testing.expectEqual(AppMode.force_light, modeForTheme(Theme.auto, light_bg, false));
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.ghostty, dark_bg, true));

    // Green-heavy backgrounds weigh more than blue-heavy (luminance, not
    // average): pure green is light, pure blue is dark.
    try std.testing.expectEqual(AppMode.force_light, modeForTheme(Theme.auto, Rgb{ .r = 0, .g = 0xff, .b = 0 }, false));
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.auto, Rgb{ .r = 0, .g = 0, .b = 0xff }, true));
}

test "modeForTheme: only `system` reads the OS side" {
    // Every other theme has a definite side of its own, so the OS answer must
    // not be able to move it. Worth asserting rather than assuming: `system` is
    // the one branch that consults `system_light`, and a future edit that let
    // another branch consult it would put the menus and the title bar on
    // different sides for the same config.
    const Theme = enum { auto, system, light, dark, ghostty };
    const Rgb = struct { r: u8, g: u8, b: u8 };
    const bgs = [_]Rgb{
        .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
        .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .{ .r = 0x80, .g = 0x80, .b = 0x80 },
    };
    for (bgs) |bg| {
        for ([_]Theme{ .auto, .light, .dark, .ghostty }) |theme| {
            try std.testing.expectEqual(
                modeForTheme(theme, bg, true),
                modeForTheme(theme, bg, false),
            );
        }
    }
}
