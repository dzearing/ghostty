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
//! behavior). The preferred mode is derived from `window-theme` exactly
//! like the DWM chrome in Window.applyChromeTheme, so menus match the
//! title bar: explicit dark/light force the mode, `system` follows the OS
//! apps theme (live, across WM_SETTINGCHANGE), and `auto`/`ghostty` force
//! the mode matching the background luminance.

const std = @import("std");
const w32 = @import("win32.zig");

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
/// color — the same decision table as Window.applyChromeTheme's DWM
/// caption, mapped onto the app-wide menu modes. `system` maps to
/// allow-dark so menus track OS apps-theme flips automatically.
pub fn modeForTheme(theme: anytype, bg: anytype) AppMode {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    return switch (theme) {
        .dark => .force_dark,
        .light => .force_light,
        .system => .allow_dark,
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows.
        .auto, .ghostty => if (luminance < 0.5) .force_dark else .force_light,
    };
}

/// Set the app-wide preferred dark mode for USER menus and flush the menu
/// theme cache so menus created before the change re-evaluate. Idempotent
/// and cheap — called at app init, on config reload, and on
/// WM_SETTINGCHANGE (OS theme flips).
pub fn apply(theme: anytype, bg: anytype) void {
    resolve();
    const set = set_preferred_app_mode orelse return;
    const mode = modeForTheme(theme, bg);
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
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.dark, light_bg));
    try std.testing.expectEqual(AppMode.force_light, modeForTheme(Theme.light, dark_bg));

    // system follows the OS: allow-dark either way.
    try std.testing.expectEqual(AppMode.allow_dark, modeForTheme(Theme.system, dark_bg));
    try std.testing.expectEqual(AppMode.allow_dark, modeForTheme(Theme.system, light_bg));

    // auto/ghostty derive from background luminance.
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.auto, dark_bg));
    try std.testing.expectEqual(AppMode.force_light, modeForTheme(Theme.auto, light_bg));
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.ghostty, dark_bg));

    // Green-heavy backgrounds weigh more than blue-heavy (luminance, not
    // average): pure green is light, pure blue is dark.
    try std.testing.expectEqual(AppMode.force_light, modeForTheme(Theme.auto, Rgb{ .r = 0, .g = 0xff, .b = 0 }));
    try std.testing.expectEqual(AppMode.force_dark, modeForTheme(Theme.auto, Rgb{ .r = 0, .g = 0, .b = 0xff }));
}
