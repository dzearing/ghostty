//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork (branding, fork apprt actions).
//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");

const App = @import("App.zig");
const MachineChooser = @import("MachineChooser.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const RenameDialog = @import("RenameDialog.zig");
const BannerDialog = @import("BannerDialog.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const terminal = @import("../../terminal/main.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const remote_connection = @import("../../remote/connection.zig");

/// The two remote transports a window can ride on: a direct TCP dial to the
/// agent (T20) or a rendezvous-relay WebSocket (T21b). Both `Dialed` shapes
/// own their mux/connection; this union only dispatches teardown.
pub const RemoteDialed = union(enum) {
    tcp: *tcp_dial.Dialed,
    relay: *relay_dial.Dialed,

    /// Tear down the transport and free the heap-owned Dialed.
    pub fn deinitDestroy(self: RemoteDialed, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |d| {
                d.deinit();
                alloc.destroy(d);
            },
        }
    }

    /// The live connection carried by either transport.
    pub fn conn(self: RemoteDialed) *remote_connection.Connection {
        return switch (self) {
            inline else => |d| d.conn,
        };
    }
};

/// How a remote window's agent was reached, recorded so "New Window" on a
/// focused remote window can dial the SAME machine again (T68). All strings
/// owned (duped by `setRemoteMachine`, freed in `deinit`).
pub const RemoteMachine = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    relay: struct { base: []const u8, device: []const u8 },

    pub fn deinitFree(self: RemoteMachine, alloc: std.mem.Allocator) void {
        switch (self) {
            .tcp => |t| alloc.free(t.host),
            .relay => |r| {
                alloc.free(r.base);
                alloc.free(r.device);
            },
        }
    }

    /// This machine's key in the per-host defaults store (T174): the relay
    /// DEVICE ID (stable across renames), else `host:port` — Mac's
    /// `Machine.settingsKey`. Borrows this machine's strings.
    pub fn hostDefaultsKey(self: RemoteMachine) host_defaults.Key {
        return switch (self) {
            .tcp => |t| .{ .tcp = .{ .host = t.host, .port = t.port } },
            .relay => |r| .{ .relay = r.device },
        };
    }
};
/// A client-area size in pixels (see `default_client_size`, T66).
pub const ClientSize = struct { width: u32, height: u32 };

const w32 = @import("win32.zig");
const DarkMode = @import("DarkMode.zig");
const HeroCarousel = @import("HeroCarousel.zig");
const hero_math = @import("hero_math.zig");
const dim_math = @import("dim_math.zig");
const split_geometry = @import("split_geometry.zig");
const color_math = @import("color_math.zig");
const tab_color = @import("tab_color.zig");
const title_font = @import("title_font.zig");
const window_memory = @import("window_memory.zig");
const host_defaults = @import("host_defaults.zig");
const commands = @import("commands.zig");
const menu_bar = @import("menu_bar.zig");
const menu_label = @import("menu_label.zig");

const log = std.log.scoped(.win32);

/// Posted by a Surface's renderer thread when a hero-mode thumbnail
/// snapshot is ready (wparam = the leaf's HWND; validated against the
/// active tab's tree before any pointer is touched). WM_APP+1..+5 are
/// defined in App.zig.
pub const WM_APP_HERO_SNAP: u32 = w32.WM_APP + 6;

/// Posted by a surface to open the menu system (T190) from the message loop
/// rather than from inside the key WndProc. Two reasons: the key event
/// finishes being delivered to the terminal first (so alt keeps behaving as
/// a modifier for anything reading key releases), and the modal
/// TrackPopupMenuEx loop never runs nested inside a keyboard WndProc — the
/// re-entrancy class T48 was.
pub const WM_APP_OPEN_MENU: u32 = w32.WM_APP + 10;

/// Hero-mode carousel thumbnail refresh period (Mac parity: 0.15s).
const HERO_SNAP_INTERVAL_MS: u32 = 150;
const HERO_SNAP_TIMER_ID: usize = 0x4853; // 'HS'

/// Hero-mode animation clock (T59b): one ~16ms timer, alive only while a
/// selection slide (0.35s, Mac parity) and/or carousel re-center (0.3s)
/// runs; progress comes from a real-time clock, not tick counts.
const HERO_ANIM_TIMER_ID: usize = 0x4841; // 'HA'
const HERO_ANIM_TICK_MS: u32 = 16;
pub const HERO_SLIDE_MS: f32 = 350.0;
const HERO_RECENTER_MS: f32 = 300.0;

/// During a hero divider drag the leaf resize (MoveWindow of every leaf)
/// is throttled to 80ms while the carousel repaints every tick — the Mac
/// debounces grid reflow by the same 80ms (T58 decision 4).
const HERO_DRAG_RESIZE_MS: i64 = 80;

/// Maximum number of tabs per window.
const MAX_TABS: usize = 64;

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Tab split trees owned by this window (fixed-capacity inline array).
tab_count: usize = 0,
tab_trees: [64]SplitTree(Surface) = undefined,

/// The currently focused surface within each tab.
tab_active_surface: [64]*Surface = undefined,

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Whether the tab bar is visible (shown when >1 tab).
tab_bar_visible: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// Hit-test rectangles for each tab in the tab bar. Zero-initialized
/// so input handlers that read it before the first paint (e.g., a
/// synthetic WM_LBUTTONDOWN during startup) get a no-match instead of
/// stack garbage.
tab_rects: [64]w32.RECT = std.mem.zeroes([64]w32.RECT),

/// Hit-test rectangle for the "+" (new tab) button.
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the close button on the hovered tab is being hovered.
hover_close: bool = false,

/// Whether the "+" (new tab) button is being hovered.
hover_new_tab: bool = false,

/// Hit-test rectangle for the "≡" (menu) button at the right end of the tab
/// strip — the host for the menu system (T190). Zero until the first paint,
/// which reads as "no match" for the input handlers.
menu_btn_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Whether the "≡" (menu) button is being hovered.
hover_menu_btn: bool = false,

/// The menu is currently tracking (`TrackPopupMenuEx` is on the stack).
/// Guards against re-entering the modal loop from a second click/key while
/// it is up — the second `TrackPopupMenuEx` would nest and the first would
/// return a stale result.
menu_open: bool = false,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
/// Starting X position of the drag.
drag_start_x: i16 = 0,
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,

/// Inline tab rename: Edit control HWND, font, and target tab index.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,

/// The "Rename Window" dialog (ctrl+shift+r), when open. Owned by
/// RenameDialog itself; this is a backreference for key routing and
/// teardown.
rename_dialog: ?*RenameDialog = null,

/// The open "Set Pane Banner" editor (T35), or null. Same lifecycle deal
/// as rename_dialog: owned by the BannerDialog itself, backreference for
/// key routing and teardown.
banner_dialog: ?*BannerDialog = null,

/// The open "New Remote Window" machine chooser (T22c), or null. Modal to
/// this window while open; a backreference for key routing and teardown.
machine_chooser: ?*MachineChooser = null,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [64][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [64]u16 = undefined,

/// True while the user has pinned a tab's title ("Change Tab Title…"
/// prompt or the inline tab rename, T92). A pinned tab title ignores
/// pane-driven updates until cleared with an empty rename (Mac
/// BaseTerminalController.titleOverride parity).
tab_title_pinned: [MAX_TABS]bool = [_]bool{false} ** MAX_TABS,

/// User-assigned accent color per tab (T72, Mac TerminalTabColor parity).
/// Set from the tab context menu; painted as a stripe in the tab bar.
tab_colors: [MAX_TABS]tab_color.TabColor = [_]tab_color.TabColor{.none} ** MAX_TABS,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Font used for painting the tab bar (Segoe UI).
tab_font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(Surface).Node.Handle = .root,
drag_split_layout: SplitTree(Surface).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// True after the last tab has been closed and WM_CLOSE has been posted.
/// Input handlers must bail when this is set — between PostMessage(WM_CLOSE)
/// and the dispatch, queued mouse/keyboard messages can otherwise reach
/// handlers that allocate into a window about to be freed (e.g. the
/// new-tab "+" button calling addTab()).
closing: bool = false,

/// Optional resize limits in window-rect pixels (incl. non-client).
/// 0 means "no limit" — the OS default applies. Set by .size_limit
/// and consulted from WM_GETMINMAXINFO.
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,

/// Default client-area size in pixels for `reset_window_size` (T66):
/// the core's `initial_size` action (window-width/height × cell size).
/// Null when the config doesn't set both dimensions — reset then falls
/// back to 800×600. Updated on every action (font-size changes recompute
/// it, Mac parity) but applied live only once, at window setup.
default_client_size: ?ClientSize = null,

/// True once the window-setup `initial_size` has been applied live.
/// Later re-sends (font-zoom recompute, a new tab's surface init) only
/// update `default_client_size` — Mac and GTK both treat the action as
/// store-only, so a re-send must not resize a window in use (T66).
initial_size_applied: bool = false,

/// Transient "columns × rows" overlay shown while resizing
/// (resize-overlay config). Owned popup: destroyed with the window.
resize_overlay_hwnd: ?w32.HWND = null,

/// True once the initial WM_SIZE has been seen; resize-overlay =
/// after-first suppresses the overlay for that first layout pass.
resize_seen_first: bool = false,

/// Show the window maximized on its first ShowWindow (T85): set when the
/// remembered placement was maximized or the `maximize` config is on.
start_maximized: bool = false,

/// Tracks the maximized state across WM_SIZE so only real
/// maximize/restore TRANSITIONS persist the placement memory (T85) —
/// SIZE_RESTORED fires for every programmatic resize too.
was_maximized: bool = false,

/// IPC surface-config overrides consumed by the NEXT Surface.init in this
/// window (see Surface.Overrides). Set immediately before addTab/newSplit
/// by the IPC server; creation is synchronous so borrowed strings are fine.
pending_surface_overrides: ?*const Surface.Overrides = null,

/// The dialed remote-agent transport this window rides on
/// (`+new-remote-window`), or null for a local window. OWNED: torn down in
/// deinit strictly AFTER every surface (each `termio.Remote` borrows
/// the transport's `conn`; core surface deinit joins the IO thread first).
/// Attached by the IPC handler right after createWindow succeeds.
remote_dialed: ?RemoteDialed = null,

/// The machine identity `remote_dialed` was dialed to (T68): lets New Window
/// on this window open a fresh connection to the same agent. Owned strings
/// (set via `setRemoteMachine`, freed in `deinit`). Null for local windows.
remote_machine: ?RemoteMachine = null,

/// The shared LOCAL session-persistence agent connection this window's
/// surfaces ride (T89d), or null when persistence is off / unavailable / this
/// is a cross-machine remote window. BORROWED — owned by `App.local_agent`
/// (app lifetime), NOT torn down in `deinit`. Set at createWindow time so the
/// initial surface AND all tabs/splits inherit it (via `buildRemoteInherit`),
/// exactly like `remote_dialed` for a cross-machine window. Mutually exclusive
/// with `remote_dialed`.
local_agent_conn: ?*remote_connection.Connection = null,

/// The window-level title pin (`+new-window --title`, `+rename`, the
/// "Change Window Title" prompt) — mirrors the Mac windowTitleOverride.
/// When set, the titlebar shows this over every tab/pane title until
/// cleared (empty title / `+rename --title=""`); precedence is window
/// pin → active tab title → active pane title (T92). Owned. Tab labels
/// still track their own (possibly pinned) tab titles.
title_override: ?[:0]u8 = null,

/// This window's canonical IPC name: `+new-window --target` when given,
/// else auto-generated `window-N` (Mac windowName semantics). Owned; also
/// the key it is registered under in App.ipc_targets. Null only for quick
/// terminals (not IPC-addressable) or if registration failed.
ipc_name: ?[]u8 = null,

/// Hero mode (fork feature, T19; TRUE port T58/T59a): per-tab presentation
/// state. The split tree is untouched — the selected leaf fills the hero
/// region on the left; every other leaf is HIDDEN (renderer kept awake)
/// and represented by a snapshot thumbnail in the owner-painted carousel
/// column on the right.
tab_hero_active: [MAX_TABS]bool = [_]bool{false} ** MAX_TABS,
tab_hero_index: [MAX_TABS]u16 = [_]u16{0} ** MAX_TABS,
/// Carousel share of the window width, per tab (Mac default 0.25,
/// clamped 0.1–0.6; adjusted by dragging the hero divider, T59b).
tab_hero_ratio: [MAX_TABS]f32 = [_]f32{hero_math.RATIO_DEFAULT} ** MAX_TABS,
/// Carousel wheel-scroll offset in px, per tab (Mac parity: clamped to
/// half the strip overflow either way; reset on selection change). T59b.
tab_hero_scroll: [MAX_TABS]i32 = [_]i32{0} ** MAX_TABS,

/// Transient hero-mode interaction state (T59b; active tab only — reset
/// on tab switch and tree change). Hovered carousel tile, or -1.
hero_hover_tile: isize = -1,
/// The hero/carousel divider is hovered (accent color + resize cursor).
hero_divider_hover: bool = false,
/// A divider drag is in progress (mouse captured).
hero_divider_drag: bool = false,
/// Wall-clock ms of the last throttled leaf resize during a divider drag.
hero_drag_resize_ms: i64 = 0,

/// Selection snapshot-slide animation (T58 decision 5): while it runs,
/// every hero-region HWND stays hidden and the region owner-paints the
/// outgoing + incoming SNAPSHOTS sliding by one strip slot; the incoming
/// surface is shown (and focused) when the slide completes.
hero_slide: ?HeroSlide = null,
/// Carousel re-center animation: a visual strip offset decaying from
/// `from_offset` to 0 (Mac: 0.3s ease, skipped on first show).
hero_recenter: ?HeroRecenter = null,

pub const HeroSlide = struct {
    from_index: usize,
    to_index: usize,
    start: std.time.Instant,
};

pub const HeroRecenter = struct {
    from_offset: i32,
    start: std.time.Instant,
};

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    /// If true, start fully opaque regardless of `background-opacity`. Set
    /// when `new_window` inherits from a parent window the user had
    /// toggled to opaque via `toggle_background_opacity`.
    force_opaque: bool = false,
    /// Config overrides for the first surface (IPC `+new-window` flags).
    /// Borrowed; only read during the synchronous first addTab.
    surface_overrides: ?*const Surface.Overrides = null,
    /// Canonical IPC name for this window (`+new-window --target`).
    /// Borrowed; duped at registration. Null → auto-generated `window-N`.
    ipc_name: ?[]const u8 = null,
};

/// Read HKCU\...\Themes\Personalize\AppsUseLightTheme. Returns true when the
/// system apps theme is light. A missing/erroring value is treated as light,
/// which is how the Personalize key reads before it is ever written.
pub fn systemUsesLightTheme() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) !=
        w32.ERROR_SUCCESS) return true;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, valname, null, &kind, @ptrCast(&val), &cb) !=
        w32.ERROR_SUCCESS) return true;
    if (kind != w32.REG_DWORD) return true;
    return val != 0; // 0 = dark, nonzero = light
}

/// Apply the DWM dark/light title bar, honoring `window-theme`: dark/light
/// force the mode, `system` reads the OS apps theme, and `auto`/`ghostty`
/// fall back to the terminal background luminance. The caption is tinted to
/// the terminal background only for the luminance-derived themes; for the
/// explicit dark/light/system themes the caption is reset to the system
/// default so the standard themed title bar (and legible glyphs) is drawn.
fn applyChromeTheme(hwnd: w32.HWND, theme: anytype, bg: anytype) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const by_luminance = luminance < 0.5;
    const dark = switch (theme) {
        .dark => true,
        .light => false,
        .system => !systemUsesLightTheme(),
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows.
        .auto, .ghostty => by_luminance,
    };

    const dark_mode: u32 = if (dark) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const tint_caption = switch (theme) {
        .auto, .ghostty => true,
        else => false,
    };
    const caption_color: u32 = if (tint_caption)
        (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16)
    else
        w32.DWMWA_COLOR_DEFAULT;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

/// Called from App.config_change so the title bar tracks live config
/// reloads (background color in particular).
/// Enable/disable the DWM accent blur behind the window (background-blur).
/// Visible where the window is translucent (background-opacity < 1): the
/// desktop behind shows blurred instead of sharp, the acrylic-ish look.
fn applyBackgroundBlur(hwnd: w32.HWND, enabled: bool) void {
    var policy: w32.ACCENT_POLICY = .{
        .AccentState = if (enabled) w32.ACCENT_ENABLE_BLURBEHIND else w32.ACCENT_DISABLED,
        .AccentFlags = 0,
        .GradientColor = 0,
        .AnimationId = 0,
    };
    var data: w32.WINDOWCOMPOSITIONATTRIBDATA = .{
        .Attrib = w32.WCA_ACCENT_POLICY,
        .pvData = @ptrCast(&policy),
        .cbData = @sizeOf(w32.ACCENT_POLICY),
    };
    _ = w32.SetWindowCompositionAttribute(hwnd, &data);
}

pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| {
        applyChromeTheme(hwnd, self.app.config.@"window-theme", self.app.config.background);
        applyBackgroundBlur(hwnd, self.app.config.@"background-blur".enabled());
    }
    // Re-apply unfocused-split-opacity/-fill (T74).
    self.updateDimOverlays();
    // Re-paint split dividers so split-divider-color takes effect live
    // (T73). Same GetDC path as layoutSplits — the lines sit in the
    // inter-pane gaps that WM_PAINT never covers.
    if (self.hwnd) |hwnd| {
        if (w32.GetDC(hwnd)) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }
    // Recreate the tab-bar font so window-title-font-family reloads live
    // (T78).
    self.createTabFont();
    self.invalidateTabBar();
}

/// (Re)create the tab bar font at the current DPI scale, honoring
/// `window-title-font-family` (T78). The DWM caption font of a
/// standard-frame window is not app-controllable, so on Windows the config
/// drives the owner-drawn tab bar (and the resize overlay, which shares the
/// font — it is re-pushed here so a config reload never leaves it holding a
/// deleted HFONT). GDI maps unknown face names to a usable fallback font.
fn createTabFont(self: *Window) void {
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    var face: [title_font.face_cap]u16 = undefined;
    title_font.faceName(self.app.config.@"window-title-font-family", &face);
    const font_height: i32 = -@as(i32, @intFromFloat(16.0 * self.scale));
    self.tab_font = w32.CreateFontW(
        font_height, // cHeight (negative = character height)
        0, // cWidth
        0, // cEscapement
        0, // cOrientation
        w32.FW_NORMAL, // cWeight
        0, // bItalic
        0, // bUnderline
        0, // bStrikeOut
        w32.DEFAULT_CHARSET, // iCharSet
        0, // iOutPrecision
        0, // iClipPrecision
        0, // iQuality
        0, // iPitchAndFamily
        @ptrCast(&face),
    );
    if (self.resize_overlay_hwnd) |h| {
        if (self.tab_font) |f| {
            _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
        .pending_surface_overrides = options.surface_overrides,
    };

    const style: u32 = if (options.is_quick_terminal)
        w32.WS_POPUP
    else if (app.config.@"window-decoration" == .none)
        // Borderless but still resizable: thin sizing frame, no title bar.
        w32.WS_POPUP | w32.WS_THICKFRAME
    else
        w32.WS_OVERLAPPEDWINDOW;
    const ex_style: u32 = if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;

    // Cascade non-quick-terminal windows: stack each new window 30px
    // down/right of the most recently created window. Stops once the
    // offset would push the window off the work area, then resets.
    // Quick terminals are positioned by QuickTerminal.calculateRects.
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;

    // Outer creation size (T85): explicit window-width/height config wins
    // (the core sends `initial_size` which resizes after creation, so keep
    // the plain default and let it), else the remembered last user-chosen
    // size (clamped to the primary work area), else the built-in default.
    var width: i32 = 800;
    var height: i32 = 600;
    if (!options.is_quick_terminal) {
        const config_sized = app.config.@"window-width" > 0 and
            app.config.@"window-height" > 0;
        if (!config_sized) {
            if (window_memory.load(app.core_app.alloc)) |remembered| {
                var work: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                const clamped = if (w32.SystemParametersInfoW(
                    w32.SPI_GETWORKAREA,
                    0,
                    @ptrCast(&work),
                    0,
                ) != 0) window_memory.clampToWorkArea(
                    remembered,
                    work.right - work.left,
                    work.bottom - work.top,
                ) else remembered;
                width = clamped.width;
                height = clamped.height;
                self.start_maximized = remembered.maximized;
            }
        }
        // `maximize` config: open maximized regardless of the memory
        // (Mac/GTK honor it; the remembered/config size stays the restored
        // size underneath).
        if (app.config.maximize) self.start_maximized = true;
    }
    // Honor an explicit configured window position; it takes precedence over
    // the cascade below. Only when BOTH coordinates are set — passing
    // CW_USEDEFAULT for one axis is not a valid literal coordinate (Win32
    // only special-cases it on x, and would use a huge negative y or treat
    // y as nCmdShow), so a partial config falls back to full default.
    if (!options.is_quick_terminal) {
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| {
                cx = px;
                cy = py;
            }
        }
    }
    if (!options.is_quick_terminal and
        cx == w32.CW_USEDEFAULT and cy == w32.CW_USEDEFAULT and
        app.windows.items.len > 0)
    {
        // Find the previously created window's position and bump.
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                // Reset the cascade if it would push off-screen.
                if (cx + width > w32.GetSystemMetrics(0) or
                    cy + height > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        if (comptime builtin.mode == .Debug)
            std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty [DEBUG]")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty"),
        style,
        cx,
        cy,
        width,
        height,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    applyChromeTheme(hwnd, app.config.@"window-theme", app.config.background);

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // If background opacity is less than 1.0, make the window transparent.
    // Skip when force_opaque (parent window was toggled to opaque via
    // toggle_background_opacity — inherit that state for the new window).
    if (app.config.@"background-opacity" < 1.0 and !options.force_opaque) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(app.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }
    if (app.config.@"background-blur".enabled()) {
        applyBackgroundBlur(hwnd, true);
    }

    // Query DPI scale.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    // Create the tab bar font (window-title-font-family, scaled).
    self.createTabFont();

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.

    // Every regular window is IPC-addressable under one canonical name:
    // `+new-window --target` when given, else auto-generated `window-N`
    // (Mac windowName semantics). Quick terminals are not listable targets.
    if (!options.is_quick_terminal) register: {
        const gpa = app.core_app.alloc;
        const name: []u8 = if (options.ipc_name) |n|
            gpa.dupe(u8, n) catch break :register
        else
            app.ipcNextWindowName() catch break :register;
        app.ipcRegister(name, .{ .window = self }) catch |err| {
            log.warn("IPC window registration failed err={}", .{err});
            gpa.free(name);
            break :register;
        };
        self.ipc_name = name;
    }
}

/// Deinitialize the Window: close all tabs, delete font, destroy HWND.
pub fn deinit(self: *Window) void {
    // Close the rename dialog / machine chooser first (each re-enables and
    // refocuses this window's HWND, which must still be alive).
    if (self.rename_dialog) |dlg| dlg.cancel();
    if (self.banner_dialog) |dlg| dlg.cancel();
    if (self.machine_chooser) |ch| ch.cancel();

    // Drop IPC names pointing at this window before the memory can be
    // recycled.
    self.app.ipcForget(.{ .window = self });
    if (self.ipc_name) |n| {
        self.app.core_app.alloc.free(n);
        self.ipc_name = null;
    }

    if (self.title_override) |t| {
        self.app.core_app.alloc.free(t);
        self.title_override = null;
    }

    // Close all tab surfaces.
    self.cleanupAllSurfaces();

    // Tear down the remote-agent transport AFTER every surface is gone:
    // each remote surface's termio backend borrows the transport's `conn`,
    // and its IO thread (joined by core surface deinit above) uses it.
    if (self.remote_dialed) |d| {
        d.deinitDestroy(self.app.core_app.alloc);
        self.remote_dialed = null;
    }
    if (self.remote_machine) |m| {
        m.deinitFree(self.app.core_app.alloc);
        self.remote_machine = null;
    }

    // Delete the tab bar font.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}

/// Width of the tab strip's "≡" menu button at a given DPI scale (T190).
/// Same 36pt square as the "+" beside it, so the two controls read as a
/// group and the strip's arithmetic stays one expression.
pub fn menuButtonWidth(scale: f32) i32 {
    return @intFromFloat(@round(36.0 * scale));
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    return rect;
}

/// Returns the currently active Surface, or null if there are no tabs.
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}

/// Find the tab index containing a given surface.
/// Checks tab_active_surface first, then scans all trees.
pub fn findTabIndex(self: *Window, surface: *Surface) ?usize {
    for (self.tab_active_surface[0..self.tab_count], 0..) |s, i| {
        if (s == surface) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}

/// Find the Node.Handle for a surface in a given tab's tree.
fn findHandle(self: *Window, tab_idx: usize, surface: *Surface) ?SplitTree(Surface).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}

/// Record the machine identity this window's remote transport was dialed to
/// (T68). Dupes all strings; call once right after attaching `remote_dialed`.
pub fn setRemoteMachine(self: *Window, machine: RemoteMachine) Allocator.Error!void {
    const alloc = self.app.core_app.alloc;
    self.remote_machine = switch (machine) {
        .tcp => |t| .{ .tcp = .{
            .host = try alloc.dupe(u8, t.host),
            .port = t.port,
        } },
        .relay => |r| relay: {
            const base = try alloc.dupe(u8, r.base);
            errdefer alloc.free(base);
            break :relay .{ .relay = .{
                .base = base,
                .device = try alloc.dupe(u8, r.device),
            } };
        },
    };
}

/// Remote inheritance for one new tab/split in a REMOTE window (T68, Mac
/// BaseTerminalController.newSplit / §WP4 parity): the synthesized surface
/// overrides (same shared connection, the parent pane's command, the parent
/// pane's cwd) plus the owned cwd string they borrow. The cwd is a bounded
/// agent RPC (GET_CWD); on any failure the new pane simply opens in the
/// agent's default cwd. Freed by the caller after Surface.init consumed the
/// overrides (termio.Remote dupes what it keeps).
const RemoteInherit = struct {
    overrides: Surface.Overrides,
    cwd: ?[]u8,
    /// Backs `overrides.remote.shell` when it came from the per-host defaults
    /// store (T174). Owned like `cwd` — and heap-owned rather than an inline
    /// buffer BECAUSE this struct is returned by value: a pointer into its own
    /// bytes would dangle the moment it was copied out.
    shell: ?[]u8 = null,

    /// Tight bound for the on-demand cwd RPC (Mac remoteCwdQueryTimeoutMs).
    /// A healthy agent replies in single-digit ms; the bound caps how long a
    /// wedged agent can hold the GUI thread (the same synchronous-GUI-dial
    /// trade the ≤10s remote open already makes on win32).
    const cwd_timeout_ns: u64 = 1500 * std.time.ns_per_ms;

    fn deinit(self: *RemoteInherit, alloc: Allocator) void {
        if (self.cwd) |c| alloc.free(c);
        if (self.shell) |s| alloc.free(s);
        self.* = undefined;
    }
};

/// Build the T68 remote-inheriting overrides for the NEXT surface in this
/// window, or null if this window is local. `parent` is the pane the new
/// frame conceptually splits from (the active surface for tabs); null skips
/// command/cwd inheritance and opens the agent's default shell in its
/// default cwd.
fn buildRemoteInherit(self: *Window, parent: ?*Surface) ?RemoteInherit {
    // Two flavors ride the same inheritance seam: a cross-machine
    // `remote_dialed` transport (T68), or the LOCAL session-persistence agent
    // (T89d, `local_agent = true`). They are mutually exclusive.
    const conn: *remote_connection.Connection, const is_local_agent: bool =
        if (self.remote_dialed) |dialed|
            .{ dialed.conn(), false }
        else if (self.local_agent_conn) |c|
            .{ c, true }
        else
            return null;

    var command: ?[]const u8 = null;
    var cwd: ?[]u8 = null;
    if (parent) |p| {
        command = p.core_surface.remoteCommand();
        if (p.core_surface.remoteSessionId()) |sid| {
            cwd = conn.queryCwdTimeout(sid, RemoteInherit.cwd_timeout_ns) catch |err| cwd: {
                log.debug("remote inherit: cwd query failed err={}", .{err});
                break :cwd null;
            };
        }
    }

    // T174: a tab/split OPENs a fresh session on the same machine, so the
    // per-host default SHELL applies — but NOT the default cwd, which would
    // yank the new pane away from where its parent is (Mac
    // `BaseTerminalController.newSplit` / `TerminalController`: shell only, the
    // cwd inherits above). Cross-machine windows only: the local
    // session-persistence agent is this machine, not a "host" with defaults.
    var shell: ?[]u8 = null;
    if (!is_local_agent) {
        if (self.remote_machine) |machine| {
            const alloc = self.app.core_app.alloc;
            var defaults: host_defaults.Resolved = .{};
            host_defaults.lookup(alloc, machine.hostDefaultsKey(), &defaults);
            if (defaults.shell()) |s| shell = alloc.dupe(u8, s) catch null;
        }
    }

    return .{
        .overrides = .{ .remote = .{
            .connection = conn,
            .working_directory = cwd,
            .shell = shell,
            .command = command,
            .local_agent = is_local_agent,
        } },
        .cwd = cwd,
        .shell = shell,
    };
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;

    // T68: a plain new tab in a remote window opens a fresh session on the
    // SAME machine/connection, inheriting the active pane's command + cwd
    // (Mac parity). IPC-provided overrides (the pending baton) win.
    var inherit: ?RemoteInherit = null;
    defer if (inherit) |*i| i.deinit(alloc);
    if (self.pending_surface_overrides == null) {
        const parent: ?*Surface = if (self.tab_count > 0)
            self.tab_active_surface[self.active_tab]
        else
            null;
        inherit = self.buildRemoteInherit(parent);
        if (inherit) |*i| self.pending_surface_overrides = &i.overrides;
    }
    // Surface.init consumes the baton; clear it on every exit path so a
    // failed init can never leave a dangling pointer to our stack.
    defer if (inherit != null) {
        self.pending_surface_overrides = null;
    };

    const surface = try alloc.create(Surface);
    try surface.init(self.app, self, .tab);
    // After surface.init succeeds, create the SplitTree which takes ownership
    // via ref(). If this fails, we manually clean up.
    var tree = SplitTree(Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit(); // tree.deinit() calls unref() which deinits+frees surface

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) {
        self.tab_trees[i] = self.tab_trees[i - 1];
        self.tab_active_surface[i] = self.tab_active_surface[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
        self.tab_title_lens[i] = self.tab_title_lens[i - 1];
        self.tab_title_pinned[i] = self.tab_title_pinned[i - 1];
        self.tab_colors[i] = self.tab_colors[i - 1];
        self.tab_hero_active[i] = self.tab_hero_active[i - 1];
        self.tab_hero_index[i] = self.tab_hero_index[i - 1];
        self.tab_hero_ratio[i] = self.tab_hero_ratio[i - 1];
        self.tab_hero_scroll[i] = self.tab_hero_scroll[i - 1];
    }
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_title_pinned[pos] = false;
    self.tab_colors[pos] = .none;
    self.tab_hero_active[pos] = false;
    self.tab_hero_index[pos] = 0;
    self.tab_hero_ratio[pos] = hero_math.RATIO_DEFAULT;
    self.tab_hero_scroll[pos] = 0;
    self.tab_count += 1;

    // Set default title.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    if (self.tab_count == 1) {
        // First tab — show the parent window now that the terminal is ready.
        // Quick terminal windows are shown by QuickTerminal.animateIn() instead.
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                // T85: first show honors the remembered/config maximized
                // state. The pre-show size (remembered or initial_size)
                // remains the restored size underneath.
                _ = w32.ShowWindow(
                    h,
                    if (self.start_maximized) w32.SW_MAXIMIZE else w32.SW_SHOW,
                );
                _ = w32.UpdateWindow(h);
            }
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.app.markLayoutDirty(); // T89f: tab added → re-persist the layout
    return surface;
}

/// Replace a tab's ENTIRE split tree with a single fresh surface built from
/// `overrides`, and return it (T145, in-place local-agent crash recovery).
///
/// This is a SWAP, not a close. The departing surfaces are released by the old
/// tree's `deinit` with their default teardown intent — DETACH, keep-alive —
/// and this function deliberately never calls `setSessionCloseIntent`: the
/// caller's whole purpose is to re-ATTACH those same agent sessions, so ending
/// them here would terminate the children of the panes it is recovering (the
/// Mac `e65cfa4d5` incident, stated as an invariant in
/// `agent_recovery.sessionSpared`).
///
/// The tab's presentation state (title, pin, color, hero) is untouched — it
/// lives on the window and was never lost. On failure the old tree is left
/// exactly as it was.
pub fn replaceTabRootSurface(
    self: *Window,
    tab_index: usize,
    overrides: *Surface.Overrides,
) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (tab_index >= self.tab_count) return error.InvalidTabIndex;
    const alloc = self.app.core_app.alloc;

    // Build the replacement FIRST: if it fails, the tab keeps the surfaces it
    // has (frozen, but present) rather than being emptied.
    self.pending_surface_overrides = overrides;
    defer self.pending_surface_overrides = null;

    const surface = try alloc.create(Surface);
    surface.init(self.app, self, .tab) catch |err| {
        alloc.destroy(surface);
        return err;
    };
    var tree = SplitTree(Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit();

    // Swap, then release the old tree. Order matters: the window must never be
    // observable holding a freed tree, and unref'ing the old surfaces runs
    // their teardown (which posts messages).
    var old_tree = self.tab_trees[tab_index];
    self.tab_trees[tab_index] = tree;
    self.tab_active_surface[tab_index] = surface;
    self.tab_hero_active[tab_index] = false;
    self.tab_hero_index[tab_index] = 0;
    old_tree.deinit();

    return surface;
}

/// Show or hide every surface in one tab. Fresh surfaces start visible, so a
/// caller that rebuilds a BACKGROUND tab (T145 in-place recovery) must hide its
/// panes or they paint over the active tab.
pub fn setTabSurfacesVisible(self: *Window, tab: usize, visible: bool) void {
    if (tab >= self.tab_count) return;
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| {
        entry.view.setVisible(visible);
        if (entry.view.hwnd) |h|
            _ = w32.ShowWindow(h, if (visible) w32.SW_SHOW else w32.SW_HIDE);
    }
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.closeTabByIndex(idx);
}

fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    // Cancel any in-progress rename (the edit control may belong to this tab).
    self.cancelTabRename();
    var tree = self.tab_trees[idx];
    // T89e: user closed this tab → every pane's agent session must END
    // (CLOSE), not detach. Mark before deinit; the flag is read as each
    // surface tears down its termio backend. App-quit teardown
    // (Window.deinit) never runs this path, so quitting keeps sessions.
    {
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.setSessionCloseIntent(true);
    }
    tree.deinit(); // This unrefs all surfaces → Surface.unref frees when ref_count=0
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
        self.tab_title_pinned[i] = self.tab_title_pinned[i + 1];
        self.tab_colors[i] = self.tab_colors[i + 1];
        self.tab_hero_active[i] = self.tab_hero_active[i + 1];
        self.tab_hero_index[i] = self.tab_hero_index[i + 1];
        self.tab_hero_ratio[i] = self.tab_hero_ratio[i + 1];
        self.tab_hero_scroll[i] = self.tab_hero_scroll[i + 1];
    }
    self.tab_count -= 1;
    if (self.tab_count == 0) {
        self.closing = true;
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
    self.app.markLayoutDirty(); // T89f: tab removed → re-persist the layout
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            var current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabByIndex(i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabByIndex(i);
            }
        },
    }
}

/// Close a single surface within a split tree. If it's the last surface
/// in the tab, close the entire tab instead.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(surface) orelse {
        log.debug("closeSplitSurface: surface not found in any tab", .{});
        return;
    };
    const tree = &self.tab_trees[tab];

    if (!tree.isSplit()) {
        log.debug("closeSplitSurface: not split, closing whole tab", .{});
        self.closeTab(surface);
        return;
    }

    const handle = self.findHandle(tab, surface) orelse {
        log.debug("closeSplitSurface: handle not found", .{});
        return;
    };
    log.debug("closeSplitSurface: removing handle={} from tab={}", .{ handle.idx(), tab });

    // Find next focus target BEFORE removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);

    // Extract the surface pointer from the next handle before we modify the tree.
    const next_surface: ?*Surface = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitSurface: has_next={}", .{next_surface != null});

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };
    log.debug("closeSplitSurface: remove returned, new_tree nodes={}", .{new_tree.nodes.len});

    // T89e: user closed this one pane → END its agent session (CLOSE), not
    // detach. The surviving panes in `new_tree` keep their default (detach)
    // intent; only the removed `surface` is marked. old_tree.deinit() below
    // unrefs `surface` to zero, freeing it and reading this flag as its
    // termio backend tears down.
    surface.setSessionCloseIntent(true);

    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    if (next_surface) |ns| {
        log.debug("closeSplitSurface: focusing next surface", .{});
        self.tab_active_surface[tab] = ns;
        self.heroOnTreeChanged(tab);
        self.layoutSplits();
        self.app.markLayoutDirty(); // T89f: split closed → re-persist the layout
        if (ns.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
    } else {
        log.debug("closeSplitSurface: no next surface, closing tab", .{});
        self.closeTabByIndex(tab);
    }
}

/// Switch to the tab at the given index.
/// Set the visibility (occlusion) of every surface in the active tab. Used on
/// window minimize/restore so the renderer stops rebuilding frames while the
/// window is minimized.
fn setActiveTabVisible(self: *Window, visible: bool) void {
    if (self.active_tab >= self.tab_count) return;
    var it = self.tab_trees[self.active_tab].iterator();
    while (it.next()) |entry| entry.view.setVisible(visible);
}

pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.cancelTabRename();
    // Hero animations/hover/drag are active-tab state — drop them before
    // the switch (a mid-slide switch would otherwise leave the old tab's
    // panes hidden with no timer to show them).
    self.heroResetTransients();
    // Clear any in-progress tab drag
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (self.active_tab < self.tab_count) {
        var it = self.tab_trees[self.active_tab].iterator();
        while (it.next()) |entry| {
            entry.view.setVisible(false);
            if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }
    self.active_tab = idx;
    const surface = self.tab_active_surface[idx];
    self.layoutSplits();
    if (surface.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
    self.updateWindowTitle();
}

/// Number of leaves in a tab's tree.
fn leafCount(self: *Window, tab: usize) usize {
    var n: usize = 0;
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |_| n += 1;
    return n;
}

/// The tree-iteration-order index of `surface` in a tab, if present.
fn leafIndexOf(self: *Window, tab: usize, surface: *Surface) ?usize {
    var i: usize = 0;
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| : (i += 1) {
        if (entry.view == surface) return i;
    }
    return null;
}

/// The leaf at a tree-iteration-order index, if in range. Pub: the
/// hero slide painter resolves its outgoing/incoming snapshots by index.
pub fn leafAt(self: *Window, tab: usize, index: usize) ?*Surface {
    var i: usize = 0;
    var it = self.tab_trees[tab].iterator();
    while (it.next()) |entry| : (i += 1) {
        if (i == index) return entry.view;
    }
    return null;
}

/// Toggle hero mode for the active tab (fork feature, T19). Activation
/// needs more than one pane, seeds the selection from the focused pane,
/// and clears any zoom (zoom and hero are mutually exclusive).
pub fn toggleHeroMode(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    if (self.tab_hero_active[tab]) {
        self.tab_hero_active[tab] = false;
        self.heroResetTransients();
    } else {
        if (self.leafCount(tab) <= 1) return;
        const focused = self.tab_active_surface[tab];
        self.tab_hero_index[tab] = @intCast(self.leafIndexOf(tab, focused) orelse 0);
        self.tab_hero_scroll[tab] = 0;
        self.tab_trees[tab].zoom(null);
        self.tab_hero_active[tab] = true;
    }
    self.layoutSplits();
    // Repaint everything: entering paints the carousel, leaving clears it.
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
    if (self.tab_active_surface[tab].hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
}

/// Move the hero selection (clamped), focus it, and re-layout — animated
/// (snapshot slide + carousel re-center) when possible, instant otherwise.
fn heroSelect(self: *Window, index: isize) void {
    const tab = self.active_tab;
    const n = self.leafCount(tab);
    if (n == 0) return;
    const clamped: usize = @intCast(@max(0, @min(index, @as(isize, @intCast(n - 1)))));
    log.debug("heroSelect req={} clamped={} cur={} n={}", .{ index, clamped, self.tab_hero_index[tab], n });
    if (clamped == self.tab_hero_index[tab]) return;
    const old_index: usize = self.tab_hero_index[tab];

    // Capture the strip's CURRENT visual position before the switch so
    // the re-center can animate from it (includes wheel scroll and any
    // still-running re-center).
    const old_top0: ?i32 = if (HeroCarousel.geometry(self)) |g| g.top0 else null;

    self.tab_hero_index[tab] = @intCast(clamped);
    const view = self.leafAt(tab, clamped) orelse return;
    self.tab_active_surface[tab] = view;
    // Mac parity: a selection change resets the wheel-scroll offset.
    self.tab_hero_scroll[tab] = 0;

    if (self.heroStartAnims(old_index, clamped, old_top0)) return;
    self.layoutSplits();
    if (view.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
}

/// Clamp/deactivate hero state after the tab's tree changed (split
/// created, pane closed, layout rearranged). Also cancels any running
/// animations and drops transient hover/drag state — leaf indices (and
/// tile geometry) are no longer what they referred to.
pub fn heroOnTreeChanged(self: *Window, tab: usize) void {
    self.heroResetTransients();
    if (!self.tab_hero_active[tab]) return;
    const n = self.leafCount(tab);
    if (n <= 1) {
        self.tab_hero_active[tab] = false;
        return;
    }
    if (self.tab_hero_index[tab] >= n) self.tab_hero_index[tab] = @intCast(n - 1);
}

/// Focus-follows: clicking (or otherwise focusing) a carousel pane makes
/// it the hero. Called from the WM_SETFOCUS path. Routed through
/// heroSelect so external focus changes get the same animations as
/// keyboard/click selection (the redundant deferred SetFocus it issues is
/// a no-op — the surface already has focus).
pub fn heroOnSurfaceFocused(self: *Window, surface: *Surface) void {
    const tab = self.active_tab;
    if (!self.tab_hero_active[tab]) return;
    const index = self.leafIndexOf(tab, surface) orelse return;
    log.debug("heroOnSurfaceFocused hwnd={?} index={} cur={}", .{ surface.hwnd, index, self.tab_hero_index[tab] });
    if (index == self.tab_hero_index[tab]) return;
    self.heroSelect(@intCast(index));
}

/// SPI_GETCLIENTAREAANIMATION: users who disabled "animate controls and
/// elements inside windows" get instant selection swaps (T58 decision 5).
fn heroAnimationsEnabled() bool {
    var enabled: i32 = 1;
    if (w32.SystemParametersInfoW(
        w32.SPI_GETCLIENTAREAANIMATION,
        0,
        @ptrCast(&enabled),
        0,
    ) == 0) return true;
    return enabled != 0;
}

/// Eased 0→1 progress of an animation started at `start`, or null once
/// the duration has elapsed (or the monotonic clock is unavailable).
pub fn heroAnimProgress(start: std.time.Instant, duration_ms: f32) ?f32 {
    const now = std.time.Instant.now() catch return null;
    const ms = @as(f32, @floatFromInt(now.since(start))) / std.time.ns_per_ms;
    if (ms >= duration_ms) return null;
    return hero_math.easeInOutCubic(ms / duration_ms);
}

/// The re-center animation's current visual strip offset (0 when idle).
pub fn heroRecenterOffset(self: *Window) i32 {
    const rc = self.hero_recenter orelse return 0;
    const p = heroAnimProgress(rc.start, HERO_RECENTER_MS) orelse return 0;
    const f: f32 = @floatFromInt(rc.from_offset);
    return @intFromFloat(@round(f * (1.0 - p)));
}

/// Begin the selection snapshot-slide + carousel re-center. Returns false
/// when animations should not run (OS reduced-motion, missing snapshots,
/// no window) — the caller then falls back to the instant swap. Call
/// AFTER tab_hero_index/scroll have been updated to the new selection.
fn heroStartAnims(self: *Window, old_index: usize, new_index: usize, old_top0: ?i32) bool {
    if (!heroAnimationsEnabled()) return false;
    const hwnd = self.hwnd orelse return false;
    const tab = self.active_tab;
    const out_view = self.leafAt(tab, old_index) orelse return false;
    const in_view = self.leafAt(tab, new_index) orelse return false;
    // The slide owner-paints both SNAPSHOTS; without both DIBs (e.g.
    // immediately after entering hero mode) swap instantly instead.
    if (out_view.snap_dib == null or in_view.snap_dib == null) return false;
    const start = std.time.Instant.now() catch return false;

    self.hero_slide = .{ .from_index = old_index, .to_index = new_index, .start = start };
    // Both hero HWNDs stay hidden for the whole slide; the incoming one
    // is shown (and focused) by heroAnimTick when the slide completes.
    if (out_view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);

    // Re-center: decay from the old strip position to the new centered
    // one (Mac: 0.3s, skipped on first show — entering hero mode never
    // lands here). Clear any previous re-center BEFORE computing the
    // target so geometry() yields the settled position.
    self.hero_recenter = null;
    if (old_top0) |old| recenter: {
        const geo = HeroCarousel.geometry(self) orelse break :recenter;
        const delta = old - geo.top0;
        if (delta != 0) self.hero_recenter = .{ .from_offset = delta, .start = start };
    }

    _ = w32.SetTimer(hwnd, HERO_ANIM_TIMER_ID, HERO_ANIM_TICK_MS, null);
    self.heroInvalidateAnimRegions(true, self.hero_recenter != null);
    return true;
}

/// ~16ms animation heartbeat: repaint the animating regions; finish the
/// slide (show + focus the incoming pane) and the re-center when their
/// clocks run out; kill the timer once nothing animates.
fn heroAnimTick(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0 or !self.tab_hero_active[self.active_tab]) {
        self.heroCancelAnims();
        return;
    }
    const had_slide = self.hero_slide != null;
    const had_recenter = self.hero_recenter != null;
    var any = false;
    if (self.hero_slide) |s| {
        if (heroAnimProgress(s.start, HERO_SLIDE_MS) == null) {
            self.hero_slide = null;
            self.heroShowSelected(true);
        } else any = true;
    }
    if (self.hero_recenter) |rc| {
        if (heroAnimProgress(rc.start, HERO_RECENTER_MS) == null) {
            self.hero_recenter = null;
        } else any = true;
    }
    self.heroInvalidateAnimRegions(had_slide, had_recenter);
    if (!any) _ = w32.KillTimer(hwnd, HERO_ANIM_TIMER_ID);
}

/// Show (and optionally focus) the selected hero pane. Used at the end
/// of a slide — while one runs, every hero HWND is hidden.
fn heroShowSelected(self: *Window, focus: bool) void {
    const tab = self.active_tab;
    if (!self.tab_hero_active[tab]) return;
    const view = self.leafAt(tab, self.tab_hero_index[tab]) orelse return;
    if (view.hwnd) |h| {
        _ = w32.ShowWindow(h, w32.SW_SHOW);
        if (focus) App.deferSetFocus(h); // T48: defer out of WndProc
    }
}

/// Drop animation state without waiting for it to complete. If a slide
/// was mid-flight its panes are all hidden — reveal the selected one
/// (without stealing focus; every caller either re-layouts right after
/// or is tearing the tab down).
fn heroCancelAnims(self: *Window) void {
    if (self.hero_slide == null and self.hero_recenter == null) return;
    const had_slide = self.hero_slide != null;
    self.hero_slide = null;
    self.hero_recenter = null;
    if (self.hwnd) |h| _ = w32.KillTimer(h, HERO_ANIM_TIMER_ID);
    if (had_slide) self.heroShowSelected(false);
}

/// Reset every transient hero interaction: animations, hover chrome, and
/// a divider drag (releasing the mouse capture). Called on tab switch,
/// tree change, and hero-mode exit.
fn heroResetTransients(self: *Window) void {
    self.heroCancelAnims();
    self.hero_hover_tile = -1;
    self.hero_divider_hover = false;
    if (self.hero_divider_drag) {
        self.hero_divider_drag = false;
        _ = w32.ReleaseCapture();
    }
}

/// Invalidate the regions the animations paint: the hero rect for the
/// slide, the divider + carousel column for the re-center.
fn heroInvalidateAnimRegions(self: *Window, slide: bool, recenter: bool) void {
    const hwnd = self.hwnd orelse return;
    if (!slide and !recenter) return;
    const split = HeroCarousel.splitRects(self, self.surfaceRect());
    if (slide) {
        var r: w32.RECT = .{
            .left = split.hero.left,
            .top = split.hero.top,
            .right = split.hero.right,
            .bottom = split.hero.bottom,
        };
        _ = w32.InvalidateRect(hwnd, &r, 0);
    }
    if (recenter) {
        var r: w32.RECT = .{
            .left = split.divider.left,
            .top = split.carousel.top,
            .right = split.carousel.right,
            .bottom = split.carousel.bottom,
        };
        _ = w32.InvalidateRect(hwnd, &r, 0);
    }
}

/// Repaint the divider + carousel column (hover chrome, wheel scroll,
/// divider drag).
fn heroInvalidateCarousel(self: *Window) void {
    self.heroInvalidateAnimRegions(false, true);
}

/// Is the point (client coords) inside the hero/carousel divider band?
fn heroHitDivider(self: *Window, x: i32, y: i32) bool {
    if (self.tab_count == 0 or !self.tab_hero_active[self.active_tab]) return false;
    if (self.leafCount(self.active_tab) <= 1) return false;
    const split = HeroCarousel.splitRects(self, self.surfaceRect());
    return split.divider.contains(x, y);
}

/// Wheel over the carousel column (divider band included) scrolls the
/// thumbnail strip — clamped to half the strip overflow either way (Mac
/// parity). Client coords; returns true when the event was consumed.
pub fn heroWheel(self: *Window, x: i32, y: i32, raw_delta: i16) bool {
    if (self.tab_count == 0 or !self.tab_hero_active[self.active_tab]) return false;
    const geo = HeroCarousel.geometry(self) orelse return false;
    if (x < geo.split.divider.left or y < geo.split.carousel.top) return false;
    // One detent scrolls half a tile step — proportional to tile size so
    // the feel is stable across carousel widths and DPI.
    const step: f32 = @as(f32, @floatFromInt(geo.layout.thumb_h + geo.layout.gap)) / 2.0;
    const notches: f32 = @as(f32, @floatFromInt(raw_delta)) /
        @as(f32, @floatFromInt(w32.WHEEL_DELTA));
    // Manual scrolling takes over from a running re-center animation.
    self.hero_recenter = null;
    const tab = self.active_tab;
    const cur = hero_math.clampScroll(
        self.tab_hero_scroll[tab],
        geo.split.carousel,
        geo.layout,
        geo.count,
    );
    const next = hero_math.clampScroll(
        cur + @as(i32, @intFromFloat(@round(notches * step))),
        geo.split.carousel,
        geo.layout,
        geo.count,
    );
    self.tab_hero_scroll[tab] = next;
    // Debug-build oracle for hero-mode.ps1 (wheel reaches the carousel).
    log.debug("hero wheel scroll={} raw={}", .{ next, raw_delta });
    self.heroInvalidateCarousel();
    return true;
}

/// Surface-side wheel fallback (T58 decision 4): without Win10+ hover
/// routing, wheel messages follow keyboard focus (= the hero pane), so
/// the hero surface forwards wheel events that happen over the carousel.
/// Returns true when consumed.
pub fn heroWheelScreenCursor(self: *Window, raw_delta: i16) bool {
    if (self.tab_count == 0 or !self.tab_hero_active[self.active_tab]) return false;
    const hwnd = self.hwnd orelse return false;
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return false;
    _ = w32.ScreenToClient(hwnd, &pt);
    return self.heroWheel(pt.x, pt.y, raw_delta);
}

/// Mouse move below the tab bar while hero mode is active: tile hover
/// chrome + divider hover accent. Registers TrackMouseEvent (shared
/// `tracking_mouse` flag with the tab bar) so WM_MOUSELEAVE clears state.
fn heroMouseMove(self: *Window, x: i32, y: i32) void {
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd orelse return,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }
    const new_tile: isize = if (HeroCarousel.hitTest(self, x, y)) |i| @intCast(i) else -1;
    if (new_tile != self.hero_hover_tile) {
        self.heroInvalidateTile(self.hero_hover_tile);
        self.heroInvalidateTile(new_tile);
        self.hero_hover_tile = new_tile;
        // Debug-build oracle for hero-mode.ps1 (hover chrome reacts).
        log.debug("hero hover tile={}", .{new_tile});
    }
    const new_div = self.heroHitDivider(x, y);
    if (new_div != self.hero_divider_hover) {
        self.hero_divider_hover = new_div;
        self.heroInvalidateDivider();
    }
}

/// WM_MOUSELEAVE: drop hover chrome (tile + divider).
fn heroMouseLeave(self: *Window) void {
    if (self.hero_hover_tile != -1) {
        self.heroInvalidateTile(self.hero_hover_tile);
        self.hero_hover_tile = -1;
    }
    if (self.hero_divider_hover) {
        self.hero_divider_hover = false;
        self.heroInvalidateDivider();
    }
}

fn heroInvalidateTile(self: *Window, index: isize) void {
    if (index < 0) return;
    const hwnd = self.hwnd orelse return;
    if (HeroCarousel.tileRect(self, @intCast(index))) |r| {
        var inv = r;
        _ = w32.InvalidateRect(hwnd, &inv, 0);
    }
}

fn heroInvalidateDivider(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const split = HeroCarousel.splitRects(self, self.surfaceRect());
    var r: w32.RECT = .{
        .left = split.divider.left,
        .top = split.divider.top,
        .right = split.divider.right,
        .bottom = split.divider.bottom,
    };
    _ = w32.InvalidateRect(hwnd, &r, 0);
}

/// Begin a hero divider drag (mouse captured until WM_LBUTTONUP).
fn heroStartDividerDrag(self: *Window) void {
    self.hero_divider_drag = true;
    self.hero_drag_resize_ms = 0;
    if (self.hwnd) |h| _ = w32.SetCapture(h);
    self.heroInvalidateDivider();
}

/// Divider drag tick: recompute the per-tab ratio from the absolute
/// cursor position (no incremental deltas — the Mac measures in global
/// coords for the same no-oscillation reason). The carousel repaints
/// every tick; the leaf resize is throttled to 80ms (T58 decision 4).
fn heroUpdateDividerDrag(self: *Window, x: i32) void {
    if (!self.hero_divider_drag) return;
    const tab = self.active_tab;
    const rect = self.surfaceRect();
    const w: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
    const band: f32 = @floatFromInt(HeroCarousel.splitRects(self, rect).divider.width());
    // The cursor rides the band center; the carousel starts at the band's
    // right edge.
    const carousel_w: f32 = @as(f32, @floatFromInt(rect.right - x)) - band / 2.0;
    self.tab_hero_ratio[tab] = hero_math.clampRatio(carousel_w / w);

    const now = std.time.milliTimestamp();
    if (now - self.hero_drag_resize_ms >= HERO_DRAG_RESIZE_MS) {
        self.hero_drag_resize_ms = now;
        self.layoutHero(rect);
    }
    // Repaint the whole content region: the divider/carousel boundary
    // moves every tick even between throttled leaf resizes.
    if (self.hwnd) |h| {
        var inv = rect;
        _ = w32.InvalidateRect(h, &inv, 0);
    }
}

/// End a hero divider drag: release capture and do the final,
/// un-throttled layout at the exact ratio.
fn heroEndDividerDrag(self: *Window) void {
    if (!self.hero_divider_drag) return;
    self.hero_divider_drag = false;
    _ = w32.ReleaseCapture();
    log.debug("hero ratio={d:.3}", .{self.tab_hero_ratio[self.active_tab]});
    self.layoutSplits();
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
}

/// 150ms heartbeat while hero mode is active: ask every leaf's renderer
/// for a fresh thumbnail at the current tile size. Idle panes produce no
/// new frame until their next wakeup re-presents the last target, so the
/// steady-state cost of an unchanged pane is one atomic load per frame.
fn heroSnapTick(self: *Window) void {
    if (self.tab_count == 0 or !self.tab_hero_active[self.active_tab]) {
        if (self.hwnd) |h| _ = w32.KillTimer(h, HERO_SNAP_TIMER_ID);
        return;
    }
    // Minimized: panes are occluded and produce no frames — don't wake
    // every renderer thread each tick for nothing (T53 bar).
    if (self.hwnd) |h| if (w32.IsIconic(h) != 0) return;
    const geo = HeroCarousel.geometry(self) orelse return;
    var it = self.tab_trees[self.active_tab].iterator();
    while (it.next()) |entry| {
        entry.view.heroSnapRequest(
            @intCast(@max(geo.layout.thumb_w, 1)),
            @intCast(@max(geo.layout.thumb_h, 1)),
        );
    }
}

/// WM_APP_HERO_SNAP: a renderer thread finished a thumbnail capture.
/// wparam carries the leaf HWND; it is validated against the active
/// tab's tree before any Surface pointer is dereferenced (the pane may
/// have closed between post and delivery).
fn heroOnSnapReady(self: *Window, leaf_hwnd_int: usize) void {
    if (self.tab_count == 0 or !self.tab_hero_active[self.active_tab]) return;
    var it = self.tab_trees[self.active_tab].iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) {
        const h = entry.view.hwnd orelse continue;
        if (@intFromPtr(h) != leaf_hwnd_int) continue;
        if (entry.view.heroSnapPublish()) {
            if (self.hwnd) |wh| {
                if (HeroCarousel.tileRect(self, index)) |r| {
                    var inv: w32.RECT = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
                    _ = w32.InvalidateRect(wh, &inv, 0);
                }
            }
        }
        return;
    }
}

/// Hero layout (T58 true port): the selected leaf fills the hero region
/// on the left; every OTHER leaf is hidden (SW_HIDE) but kept renderer-
/// visible so it keeps producing frames for its carousel thumbnail. ALL
/// leaves — hidden included — are MoveWindow'd to the hero rect: the
/// thumbnails inherit the hero aspect ratio for free and a selection swap
/// needs no grid reflow (the Mac keeps all strip slots hero-sized for
/// exactly this reason). The carousel column itself has no child HWNDs;
/// it is owner-painted by HeroCarousel.
fn layoutHero(self: *Window, rect: w32.RECT) void {
    // A re-layout mid-animation (window resize, tab ops) invalidates the
    // animation's captured geometry — finish instantly and lay out the
    // settled state.
    self.heroCancelAnims();
    const tab = self.active_tab;
    const n = self.leafCount(tab);
    if (self.tab_hero_index[tab] >= n) self.tab_hero_index[tab] = @intCast(n - 1);
    const hero_index: usize = self.tab_hero_index[tab];

    const split = HeroCarousel.splitRects(self, rect);
    const hero_w = @max(split.hero.width(), 1);
    const hero_h = @max(split.hero.height(), 1);

    var it = self.tab_trees[tab].iterator();
    var leaf_i: usize = 0;
    while (it.next()) |entry| : (leaf_i += 1) {
        // Renderer stays awake even for hidden leaves (thumbnail source).
        entry.view.setVisible(true);
        if (entry.view.hwnd) |h| {
            // Banner strip band above the hero-sized terminal (T101);
            // hidden leaves get the same inset so their thumbnail aspect
            // matches what selection will show.
            const inset = entry.view.bannerLayoutInset(@intCast(hero_w), hero_h);
            _ = w32.MoveWindow(h, split.hero.left, split.hero.top + inset, @intCast(hero_w), @intCast(@max(hero_h - inset, 1)), 1);
            _ = w32.ShowWindow(h, if (leaf_i == hero_index) w32.SW_SHOW else w32.SW_HIDE);
        }
    }

    if (self.hwnd) |h| {
        // Repaint the owner-painted divider + carousel column.
        var inv: w32.RECT = .{
            .left = split.divider.left,
            .top = rect.top,
            .right = rect.right,
            .bottom = rect.bottom,
        };
        _ = w32.InvalidateRect(h, &inv, 0);
        // Thumbnail refresh heartbeat while hero is active (Mac: 0.15s).
        _ = w32.SetTimer(h, HERO_SNAP_TIMER_ID, HERO_SNAP_INTERVAL_MS, null);
    }
}

pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    // Runs after every layout path below (including the hero/zoom early
    // returns) so the dim overlays track pane rects and layout state.
    defer self.updateDimOverlays();
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    if (self.tab_hero_active[self.active_tab]) {
        if (self.leafCount(self.active_tab) > 1) {
            self.layoutHero(rect);
            return;
        }
        self.tab_hero_active[self.active_tab] = false;
    }
    // Not in hero mode: stop the thumbnail heartbeat (harmless if it was
    // never started) and repaint the area the carousel used to own.
    if (self.hwnd) |h| _ = w32.KillTimer(h, HERO_SNAP_TIMER_ID);
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                entry.view.setVisible(true);
                if (entry.view.hwnd) |h| {
                    // Banner strip band above the zoomed terminal (T101).
                    const inset = entry.view.bannerLayoutInset(rect.right - rect.left, rect.bottom - rect.top);
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top - inset, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top + inset, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                entry.view.setVisible(false);
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }
    self.layoutNode(tree, .root, rect);

    // Paint divider lines directly using GetDC (not BeginPaint, which
    // clips to the invalid region and misses the content area gaps).
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }
}

/// Show/hide/reposition the unfocused-split dim overlays (T74): every
/// unfocused pane of the active tab's split gets a click-through layered
/// popup filled with `unfocused-split-fill` at 1 - `unfocused-split-opacity`
/// alpha (Mac parity). Walks ALL tabs so a tab switch hides the old tab's
/// overlays (they are popups — hiding the pane HWND does not hide them).
/// Idempotent and cheap; called from layoutSplits, focus changes, WM_MOVE,
/// and config reload.
pub fn updateDimOverlays(self: *Window) void {
    const config = &self.app.config;
    // Config clamps opacity to [0.15, 1]; 1 → alpha 0 → feature off.
    const alpha = dim_math.overlayAlpha(config.@"unfocused-split-opacity");
    const fill = config.@"unfocused-split-fill" orelse config.background;
    const color = w32.RGB(fill.r, fill.g, fill.b);

    for (0..self.tab_count) |tab| {
        const tree = self.tab_trees[tab];
        var it = tree.iterator();
        while (it.next()) |entry| {
            const dim = dim_math.shouldDim(.{
                .alpha = alpha,
                .active_tab = tab == self.active_tab,
                .is_split = tree.isSplit(),
                .zoomed = tree.zoomed != null,
                .hero = self.tab_hero_active[tab],
                .focused_pane = entry.view == self.tab_active_surface[tab],
            });
            if (dim) {
                entry.view.showDimOverlay(color, alpha);
            } else {
                entry.view.hideDimOverlay();
            }
        }
    }

    // Pane banners glue to the same layout/visibility/config events (T35).
    self.updatePaneBanners();
}

/// Re-check the z-order of every layered popup this window owns — each
/// pane's banner/dim/scrollbar plus the window's own resize overlay — and
/// heal a stray `WS_EX_TOPMOST` (T142). Cheap and idempotent: a window with
/// nothing wrong pays two `GetWindowLongW` reads per popup.
pub fn healOverlayZOrders(self: *Window) void {
    // A window on its way out has no z-order worth defending, and its panes
    // are being torn down under us.
    if (self.closing) return;
    const hwnd = self.hwnd orelse return;
    for (0..self.tab_count) |tab| {
        var it = self.tab_trees[tab].iterator();
        while (it.next()) |entry| entry.view.healOverlayZOrders();
    }
    if (self.resize_overlay_hwnd) |h| w32.healOverlayZOrder(h, hwnd);
}

/// Reposition/show/hide every pane's sticky banner strip (T35). Rides the
/// dim-overlay triggers (layoutSplits, focus changes, WM_MOVE, tab switch,
/// config reload) via updateDimOverlays. Idempotent and cheap — panes
/// without a banner pay one null check.
pub fn updatePaneBanners(self: *Window) void {
    for (0..self.tab_count) |tab| {
        var it = self.tab_trees[tab].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            const overlay = surface.banner_overlay orelse continue;
            surface.refreshBannerColors();
            overlay.updatePosition(surface.scale);
        }
    }
}

fn layoutNode(self: *Window, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            view.setVisible(true);
            if (view.hwnd) |h| {
                // Reserve the sticky-banner strip band above the terminal
                // (T101): the grid starts below the strip, never under it.
                const inset = view.bannerLayoutInset(rect.right - rect.left, rect.bottom - rect.top);
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top - inset, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top + inset, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        },
        .split => |s| {
            // Panes and the divider band TILE the rect (T155): the child
            // rects end/start exactly at the band, so no parent-owned pixel
            // is left between them to hold a stale line.
            if (s.layout == .horizontal) {
                const a = split_geometry.axis(rect.left, rect.right, s.ratio, self.scale);
                const left_rect = w32.RECT{ .left = a.lo_start, .top = rect.top, .right = a.band_lo, .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = a.band_hi, .top = rect.top, .right = a.hi_end, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect);
                self.layoutNode(tree, s.right, right_rect);
            } else {
                const a = split_geometry.axis(rect.top, rect.bottom, s.ratio, self.scale);
                const top_rect = w32.RECT{ .left = rect.left, .top = a.lo_start, .right = rect.right, .bottom = a.band_lo };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = a.band_hi, .right = rect.right, .bottom = a.hi_end };
                self.layoutNode(tree, s.left, top_rect);
                self.layoutNode(tree, s.right, bottom_rect);
            }
        },
    }
}

/// Paint divider lines between split panes in the active tab.
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    if (self.tab_hero_active[self.active_tab]) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    const color: u32 = if (self.app.config.@"split-divider-color") |c|
        w32.RGB(c.r, c.g, c.b)
    else
        0x00808080;
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);
    self.paintDividerNode(hdc, tree, .root, rect, brush);
}

fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT, brush: w32.HBRUSH) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            // FILL the whole band (Mac draws a filled Rectangle, not a
            // stroke). A hairline down the middle of a wider gap reads as
            // three edges once the panes carry their own background tint.
            if (s.layout == .horizontal) {
                const a = split_geometry.axis(rect.left, rect.right, s.ratio, self.scale);
                var band = w32.RECT{ .left = a.band_lo, .top = rect.top, .right = a.band_hi, .bottom = rect.bottom };
                _ = w32.FillRect(hdc, &band, brush);
                const left_rect = w32.RECT{ .left = a.lo_start, .top = rect.top, .right = a.band_lo, .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = a.band_hi, .top = rect.top, .right = a.hi_end, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect, brush);
                self.paintDividerNode(hdc, tree, s.right, right_rect, brush);
            } else {
                const a = split_geometry.axis(rect.top, rect.bottom, s.ratio, self.scale);
                var band = w32.RECT{ .left = rect.left, .top = a.band_lo, .right = rect.right, .bottom = a.band_hi };
                _ = w32.FillRect(hdc, &band, brush);
                const top_rect = w32.RECT{ .left = rect.left, .top = a.lo_start, .right = rect.right, .bottom = a.band_lo };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = a.band_hi, .right = rect.right, .bottom = a.hi_end };
                self.paintDividerNode(hdc, tree, s.left, top_rect, brush);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect, brush);
            }
        },
    }
}

const DividerHit = struct {
    handle: SplitTree(Surface).Node.Handle,
    layout: SplitTree(Surface).Split.Layout,
};

/// Hit-test the split divider grab band at (x, y) in window client
/// coords. The band is ~9 DIP wide (T94, Mac grab-handle parity) —
/// wider than the ~5 DIP visual gap between panes, so surface children
/// must fall through via WM_NCHITTEST/HTTRANSPARENT for the outer edges
/// to be reachable (see App.surfaceWndProc).
pub fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    if (self.tab_count == 0) return null;
    // Hero mode ignores the tree layout, so tree dividers don't exist on
    // screen (the hero/carousel divider drag lands in T59b).
    if (self.tab_hero_active[self.active_tab]) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}

fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Surface),
    handle: SplitTree(Surface).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            if (s.layout == .horizontal) {
                const a = split_geometry.axis(rect.left, rect.right, s.ratio, self.scale);
                if (split_geometry.inGrabBand(a, x, self.scale) and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                const left_rect = w32.RECT{ .left = a.lo_start, .top = rect.top, .right = a.band_lo, .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = a.band_hi, .top = rect.top, .right = a.hi_end, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, left_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, right_rect, x, y);
            } else {
                const a = split_geometry.axis(rect.top, rect.bottom, s.ratio, self.scale);
                if (split_geometry.inGrabBand(a, y, self.scale) and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = a.lo_start, .right = rect.right, .bottom = a.band_lo };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = a.band_hi, .right = rect.right, .bottom = a.hi_end };
                return self.hitTestDividerNode(tree, s.left, top_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, bottom_rect, x, y);
            }
        },
    }
}

fn startDividerDrag(self: *Window, handle: SplitTree(Surface).Node.Handle, layout: SplitTree(Surface).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;

    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };

    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
    // T110: persist the dragged split ratio. Armed at drag END (not on every
    // motion tick) so a drag is one debounced write, the same coalescing
    // `persistPlacement` does for window frames at WM_EXITSIZEMOVE.
    self.app.markLayoutDirty();
}

/// Create a new split in the active tab.
pub fn newSplit(self: *Window, direction: SplitTree(Surface).Split.Direction) !?*Surface {
    if (self.tab_count == 0) return null;
    return self.newSplitAt(self.tab_active_surface[self.active_tab], direction, 0.5);
}

/// Split at a specific surface (IPC `+split --pane`), with an explicit
/// ratio. The surface may live in a background tab; layout/focus side
/// effects only apply when its tab is active.
pub fn newSplitAt(
    self: *Window,
    at: *Surface,
    direction: SplitTree(Surface).Split.Direction,
    ratio: f16,
) !?*Surface {
    if (self.tab_count == 0) return null;
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(at) orelse return null;
    const handle = self.findHandle(tab, at) orelse return null;

    // T68: a plain split in a remote window opens a fresh session on the
    // SAME machine/connection, inheriting the split-parent pane's command +
    // cwd (Mac parity). IPC-provided overrides (the pending baton) win.
    var inherit: ?RemoteInherit = null;
    defer if (inherit) |*i| i.deinit(alloc);
    if (self.pending_surface_overrides == null) {
        inherit = self.buildRemoteInherit(at);
        if (inherit) |*i| self.pending_surface_overrides = &i.overrides;
    }
    defer if (inherit != null) {
        self.pending_surface_overrides = null;
    };

    // T67: every split inherits the parent pane's effective background
    // shifted for visual depth (Mac newSplit parity: lighten dark parents,
    // darken light ones). Captured before init; applied after so the core
    // terminal exists. An explicit IPC `--color` overwrites this right
    // after newSplitAt returns.
    const inherited_tint = color_math.shiftedTint(at.effectiveBackground());

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split);
    new_surface.applyBackgroundTint(inherited_tint, false);

    // Create a single-node tree for the new surface.
    var insert_tree = try SplitTree(Surface).init(alloc, new_surface);
    defer insert_tree.deinit();

    // Split the current tree at the target surface.
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        ratio,
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    // Focus the new surface.
    self.tab_active_surface[tab] = new_surface;
    self.heroOnTreeChanged(tab);
    if (self.tab_hero_active[tab]) {
        if (self.leafIndexOf(tab, new_surface)) |index| {
            self.tab_hero_index[tab] = @intCast(index);
        }
    }

    if (tab == self.active_tab) {
        self.layoutSplits();
        if (new_surface.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
    } else {
        // Surface.init shows its child hwnd; this pane belongs to a
        // background tab, so hide it until its tab is selected.
        if (new_surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }
    self.app.markLayoutDirty(); // T89f: split added → re-persist the layout
    return new_surface;
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    // Hero mode intercepts prev/next and vertical navigation to move the
    // carousel selection (Mac behavior); horizontal spatial navigation
    // still walks the real tree.
    if (self.tab_hero_active[tab]) {
        switch (goto_target) {
            .previous, .up => return self.heroSelect(@as(isize, self.tab_hero_index[tab]) - 1),
            .next, .down => return self.heroSelect(@as(isize, self.tab_hero_index[tab]) + 1),
            .left, .right => {},
        }
    }

    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const target: SplitTree(Surface).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;
    if (dest_handle == handle) return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |surface| {
            self.tab_active_surface[tab] = surface;

            // Navigating away from a zoomed split must not focus a hidden
            // pane (T77). Match Mac/GTK `split-preserve-zoom`: clear the
            // zoom by default, or carry it to the target under
            // `split-preserve-zoom = navigation`.
            if (tree.zoomed != null) {
                if (self.app.config.@"split-preserve-zoom".navigation) {
                    tree.zoom(dest_handle);
                } else {
                    tree.zoom(null);
                }
                self.layoutSplits();
            }

            if (surface.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
        },
        .split => {},
    }
}

/// Swap the active pane with the pane in the given direction (fork
/// feature; core SplitTree.swap does the tree work). Focus follows the
/// active surface to its new position.
pub fn swapSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    // Hero mode intercepts swap_split: the tree's spatial geometry is
    // invisible while hero is active, so a spatial swap silently mutates
    // the layout the user gets back on exit (reported 2026-07-16 — panes
    // came back in the wrong places, and focus-follows made the selection
    // chase the swapped pane to a surprise tile). up/down move the
    // carousel selection instead — ctrl+shift+arrows is the natural
    // Windows mirror of the Mac hero-nav chord (cmd+shift+arrows) —
    // and left/right do nothing.
    if (self.tab_hero_active[tab]) {
        switch (goto_target) {
            .previous, .up => return self.heroSelect(@as(isize, self.tab_hero_index[tab]) - 1),
            .next, .down => return self.heroSelect(@as(isize, self.tab_hero_index[tab]) + 1),
            .left, .right => return,
        }
    }

    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const target: SplitTree(Surface).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };
    const dest = (tree.goto(alloc, handle, target) catch return) orelse return;
    if (dest == handle) return;
    switch (tree.nodes[dest.idx()]) {
        .leaf => {},
        .split => return,
    }

    const new_tree = tree.swap(alloc, handle, dest) catch |err| {
        log.err("failed to swap splits: {}", .{err});
        return;
    };
    var old_tree = self.tab_trees[tab];
    self.tab_trees[tab] = new_tree;
    old_tree.deinit();

    self.layoutSplits();
    if (active_surface.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const layout: SplitTree(Surface).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);

    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
    self.app.markLayoutDirty(); // T110: equalized ratios must survive restore
}

/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];

    if (!tree.isSplit()) return;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tab_count - 1,
        .next => if (self.active_tab + 1 < self.tab_count) self.active_tab + 1 else 0,
        .last => self.tab_count - 1,
        _ => blk: {
            // GotoTab carries a c_int; clamp positive before casting so a
            // negative sentinel doesn't panic the @intCast. The configured
            // value is 1-indexed (goto_tab:1 = first tab) and out-of-range
            // selects the last tab, matching the Mac (TerminalController
            // onGotoTab) and GTK behavior.
            const raw = @intFromEnum(target);
            if (raw < 1) return false;
            const n: usize = @intCast(raw);
            break :blk @min(n - 1, self.tab_count - 1);
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    std.mem.swap(SplitTree(Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
    std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
    std.mem.swap([256]u16, &self.tab_titles[self.active_tab], &self.tab_titles[new_index]);
    std.mem.swap(u16, &self.tab_title_lens[self.active_tab], &self.tab_title_lens[new_index]);
    std.mem.swap(bool, &self.tab_title_pinned[self.active_tab], &self.tab_title_pinned[new_index]);
    std.mem.swap(tab_color.TabColor, &self.tab_colors[self.active_tab], &self.tab_colors[new_index]);
    // Hero state travels with the tab too (was missed when hero mode
    // landed — moveTabTo already handles it; this path didn't).
    std.mem.swap(bool, &self.tab_hero_active[self.active_tab], &self.tab_hero_active[new_index]);
    std.mem.swap(u16, &self.tab_hero_index[self.active_tab], &self.tab_hero_index[new_index]);
    std.mem.swap(f32, &self.tab_hero_ratio[self.active_tab], &self.tab_hero_ratio[new_index]);
    std.mem.swap(i32, &self.tab_hero_scroll[self.active_tab], &self.tab_hero_scroll[new_index]);
    self.active_tab = new_index;
    self.invalidateTabBar();
}

/// Update the top-level window title to match the active tab's title.
/// The OS apps color scheme, as the core's `apprt.ColorScheme`.
pub fn systemColorScheme() apprt.ColorScheme {
    return if (systemUsesLightTheme()) .light else .dark;
}

/// Report the OS color scheme to every pane in this window (T26). Drives
/// OSC 10/11 light/dark queries and `light:`/`dark:` conditional config —
/// the terminal-side signal, distinct from the DWM chrome theme.
pub fn reportColorScheme(self: *Window) void {
    const scheme = systemColorScheme();
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            if (!surface.core_surface_ready) continue;
            surface.core_surface.colorSchemeCallback(scheme) catch |err| {
                log.warn("color scheme callback failed err={}", .{err});
            };
        }
    }
}

/// Highest-priority activity state across every pane in every tab
/// (needs_input > busy > idle).
pub fn activityAggregate(self: *Window) terminal.osc.Command.ActivityState {
    var aggregate: terminal.osc.Command.ActivityState = .idle;
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            switch (entry.view.activity_state) {
                .needs_input => return .needs_input,
                .busy => aggregate = .busy,
                .idle => {},
            }
        }
    }
    return aggregate;
}

pub fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;

    // Base title: the override if set, else the active tab's title.
    var buf: [280]u16 = undefined;
    var len: usize = 0;
    if (self.title_override) |override| {
        len = std.unicode.utf8ToUtf16Le(buf[0..256], override) catch 0;
    } else {
        if (self.tab_count == 0) return;
        len = self.tab_title_lens[self.active_tab];
        @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    }

    // Activity suffix (`+set-state` / OSC 7777), matching the Mac's
    // " (busy)" / " (needs_input)" title decoration.
    const suffix: ?[]const u16 = switch (self.activityAggregate()) {
        .idle => null,
        .busy => std.unicode.utf8ToUtf16LeStringLiteral(" (busy)"),
        .needs_input => std.unicode.utf8ToUtf16LeStringLiteral(" (needs_input)"),
    };
    if (suffix) |s| {
        @memcpy(buf[len..][0..s.len], s);
        len += s.len;
    }

    // Debug builds mark themselves in the title (and thus the taskbar) so
    // a dev instance is never mistaken for the installed release — the
    // Windows equivalent of the Mac debug banner.
    if (comptime builtin.mode == .Debug) {
        const dbg = std.unicode.utf8ToUtf16LeStringLiteral(" [DEBUG]");
        @memcpy(buf[len..][0..dbg.len], dbg);
        len += dbg.len;
    }

    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Set (or clear, with null) the window title pin. Owned copy; wins over
/// tab/pane titles until cleared, like the Mac windowTitleOverride. An
/// empty title clears too (T92) — "pin empty" is never meaningful.
pub fn setTitleOverride(self: *Window, title: ?[]const u8) void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]u8 = if (title) |t|
        (if (t.len == 0) null else alloc.dupeZ(u8, t) catch return)
    else
        null;
    if (self.title_override) |old| alloc.free(old);
    self.title_override = copy;
    self.updateWindowTitle();
    self.app.markLayoutDirty(); // T89f: window title pin changed → re-persist
}

/// Called when a pane's title changes. Updates the stored tab title
/// and refreshes the window title bar / tab bar if needed. T92: a
/// user-pinned tab title ignores pane-driven updates, and only the
/// tab's focused pane drives the tab title (Mac parity — background
/// panes keep their own pane title without relabeling the tab).
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab_idx = self.findTabIndex(surface) orelse return;
    if (self.tab_title_pinned[tab_idx]) return;
    if (self.tab_active_surface[tab_idx] != surface) return;
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
}

/// Re-derive a tab's title from its focused pane (no-op while the tab
/// title is user-pinned). Called when the focused pane within a tab
/// changes so the tab label / titlebar follow the active pane (T92).
pub fn refreshTabTitle(self: *Window, tab_idx: usize) void {
    if (tab_idx >= self.tab_count) return;
    if (self.tab_title_pinned[tab_idx]) return;
    const title = self.tab_active_surface[tab_idx].title orelse return;
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    if (len == self.tab_title_lens[tab_idx] and
        std.mem.eql(u16, self.tab_titles[tab_idx][0..len], wbuf[0..len]))
        return;
    @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
}

/// Set (or clear, with null) the user's pinned tab title ("Change Tab
/// Title…" prompt / inline tab rename, T92). While pinned, pane-driven
/// title updates leave the tab title alone; clearing re-derives it from
/// the tab's focused pane.
pub fn setTabTitlePin(self: *Window, tab_idx: usize, title: ?[]const u8) void {
    if (tab_idx >= self.tab_count) return;
    if (title) |t| {
        var wbuf: [256]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, t) catch 0;
        const len: u16 = @intCast(@min(wlen, 255));
        @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
        self.tab_title_lens[tab_idx] = len;
        self.tab_title_pinned[tab_idx] = true;
    } else {
        self.tab_title_pinned[tab_idx] = false;
        self.refreshTabTitle(tab_idx);
    }
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
    self.app.markLayoutDirty(); // T89f: tab title pin changed → re-persist
}

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    const show_config = self.app.config.@"window-show-tab-bar";
    const should_show = switch (show_config) {
        .always => true,
        // `auto` means "show the strip when it has something to show". On
        // macOS that is tabs alone, because the app menu lives in the system
        // menu bar, which is always there. Windows has no such bar, so since
        // T190 the strip is ALSO the app's menu host (the ≡ button) — and a
        // menu you can only see once you happen to open a second tab is the
        // same "there's no way to get to the menu" the user reported in the
        // first place. So on Windows the strip has something to show from the
        // first window, and `never` remains the opt-out (F10 / a lone Alt /
        // the command palette still reach the menu there).
        .auto => true,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// WM_PAINT: one BeginPaint/EndPaint cycle covering both the tab bar and
/// (when hero mode is active) the owner-painted carousel column.
fn paintWindow(self: *Window) void {
    const hwnd = self.hwnd orelse return;

    var ps: w32.PAINTSTRUCT = undefined;
    const hdc_screen = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    self.paintTabBar(hdc_screen);
    // Dividers are part of the paint cycle (T155). BeginPaint clips to the
    // invalid region, so this covers an exposed band; the post-layout
    // GetDC pass in layoutSplits is what updates a band that MOVED without
    // anything invalidating the old spot.
    self.paintDividers(hdc_screen);
    if (self.tab_count > 0 and self.tab_hero_active[self.active_tab]) {
        HeroCarousel.paint(self, hdc_screen);
        // While a selection slide runs every hero HWND is hidden and the
        // hero region is owner-painted (outgoing/incoming snapshots).
        if (self.hero_slide != null) HeroCarousel.paintSlide(self, hdc_screen);
    }
}

/// Paint the tab bar using double-buffered GDI painting.
/// Draws tab backgrounds, text labels, close buttons (x), and the new-tab (+) button.
fn paintTabBar(self: *Window, hdc_screen: w32.HDC) void {
    const hwnd = self.hwnd orelse return;

    // If the tab bar is not visible, there is nothing to paint here.
    if (!self.tab_bar_visible) return;

    const bar_h = self.tabBarHeight();
    if (bar_h <= 0) return;

    // Get client rect width.
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left;
    if (client_w <= 0) return;

    // Double-buffer: create offscreen DC and bitmap.
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, client_w, bar_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // --- Colors ---
    const bg = self.app.config.background;
    // Bar background: terminal bg + 20 brightness per channel (slightly lighter).
    const bar_r: u8 = @min(@as(u16, bg.r) + 20, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 20, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 20, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);

    // Hover background: bar bg + 15 more (total +35 from terminal bg).
    const hover_r: u8 = @min(@as(u16, bar_r) + 15, 255);
    const hover_g: u8 = @min(@as(u16, bar_g) + 15, 255);
    const hover_b: u8 = @min(@as(u16, bar_b) + 15, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);

    // Active tab background: terminal bg (darker than bar).
    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);

    // Accent line color (blue).
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);

    // Text colors.
    const active_text_color = w32.RGB(230, 230, 230);
    const inactive_text_color = w32.RGB(150, 150, 150);

    // Close button colors.
    const close_normal_color = w32.RGB(150, 150, 150);
    const close_hover_color = w32.RGB(232, 65, 65);

    // --- Fill bar background ---
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = client_w, .bottom = bar_h };
    const bar_brush = w32.CreateSolidBrush(bar_color) orelse return;
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
    _ = w32.DeleteObject(@ptrCast(bar_brush));

    // --- Select font and set text mode ---
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // --- Calculate tab geometry ---
    const new_tab_btn_w: i32 = @intFromFloat(@round(36.0 * self.scale));
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    const accent_h: i32 = @intFromFloat(@round(2.0 * self.scale));

    const tab_count_i32: i32 = @intCast(self.tab_count);
    // The menu button (T190) sits at the far right, past the "+" — Windows
    // Terminal / VS Code / Edge all put this control there. Its width comes
    // out of the tab area exactly like the "+"'s, so the strip reflows
    // around it at any tab count and any DPI.
    const menu_btn_w: i32 = menuButtonWidth(self.scale);
    const available_w = client_w - new_tab_btn_w - menu_btn_w;

    // Calculate each tab's width: proportional, min 60px.
    const min_tab_w: i32 = @intFromFloat(@round(60.0 * self.scale));
    const max_tab_w: i32 = @intFromFloat(@round(200.0 * self.scale));

    var tab_w: i32 = if (tab_count_i32 > 0)
        @divTrunc(available_w, tab_count_i32)
    else
        0;
    tab_w = @max(tab_w, min_tab_w);
    tab_w = @min(tab_w, max_tab_w);

    // --- Draw each tab ---
    var x: i32 = 0;
    for (0..self.tab_count) |i| {
        const is_active = (i == self.active_tab);
        const is_hovered = (@as(isize, @intCast(i)) == self.hover_tab);

        // Last tab gets remainder width to fill the available area.
        const this_tab_w: i32 = if (i == self.tab_count - 1 and tab_count_i32 > 0)
            @max(available_w - x, min_tab_w)
        else
            tab_w;

        // Store hit-test rect.
        self.tab_rects[i] = w32.RECT{
            .left = x,
            .top = 0,
            .right = x + this_tab_w,
            .bottom = bar_h,
        };

        // Draw tab background. CreateSolidBrush failures are rare (GDI
        // handle exhaustion) and must NOT skip the loop body's geometry
        // update at the bottom — `continue`ing would leave subsequent
        // tabs sharing the same x position.
        if (is_active) {
            var tab_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &tab_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }

            // Draw accent line at bottom.
            var accent_rect = w32.RECT{
                .left = x,
                .top = bar_h - accent_h,
                .right = x + this_tab_w,
                .bottom = bar_h,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &accent_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        } else if (is_hovered) {
            var hover_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &hover_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Draw the user-assigned accent-color stripe across the top of the
        // tab (T72, Mac tab-color parity). Painted on active and inactive
        // tabs alike — the tag identifies the tab, not focus.
        if (tab_color.rgb(self.tab_colors[i])) |tc| {
            const stripe_h: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 2);
            var stripe_rect = w32.RECT{
                .left = x,
                .top = 0,
                .right = x + this_tab_w,
                .bottom = stripe_h,
            };
            if (w32.CreateSolidBrush(w32.RGB(tc.r, tc.g, tc.b))) |brush| {
                _ = w32.FillRect(mem_dc, &stripe_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        // Draw tab title text.
        const title_len = self.tab_title_lens[i];
        if (title_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var text_rect = w32.RECT{
                .left = x + text_pad,
                .top = 0,
                .right = x + this_tab_w - close_btn_w - text_pad,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&self.tab_titles[i]),
                @intCast(title_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Draw close button (x) — visible on active or hovered tabs.
        if (is_active or is_hovered) {
            const close_x = x + this_tab_w - close_btn_w - @divTrunc(text_pad, 2);
            const close_y_center = @divTrunc(bar_h, 2);
            const close_text_color = if (is_hovered and self.hover_close and @as(isize, @intCast(i)) == self.hover_tab)
                close_hover_color
            else
                close_normal_color;

            _ = w32.SetTextColor(mem_dc, close_text_color);
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"); // multiplication sign as close
            var close_rect = w32.RECT{
                .left = close_x,
                .top = close_y_center - @divTrunc(close_btn_w, 2),
                .right = close_x + close_btn_w,
                .bottom = close_y_center + @divTrunc(close_btn_w, 2),
            };
            _ = w32.DrawTextW(
                mem_dc,
                x_char,
                1,
                &close_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }

        x += this_tab_w;
    }

    // --- Draw the strip's buttons ---
    //
    // Pinned to the right EDGE, not to wherever the last tab ended. Tabs stop
    // shrinking at `min_tab_w`, so past ~20 tabs they overrun `available_w`
    // and anything drawn after them lands off-screen — which used to cost only
    // the "+" and would now cost the app's whole menu. Repaint the band first
    // so an overrunning tab does not show through it.
    {
        const btns_left = client_w - new_tab_btn_w - menu_btn_w;
        if (x > btns_left) {
            var band = w32.RECT{ .left = btns_left, .top = 0, .right = client_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(bar_color)) |brush| {
                _ = w32.FillRect(mem_dc, &band, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }
        x = btns_left;
    }

    // --- Draw new-tab (+) button ---
    {
        const btn_left = x;
        const btn_right = x + new_tab_btn_w;
        self.new_tab_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };

        // Hover highlight for new-tab button.
        if (self.hover_new_tab) {
            var btn_rect = w32.RECT{ .left = btn_left, .top = 0, .right = btn_right, .bottom = bar_h };
            const nt_brush = w32.CreateSolidBrush(hover_color);
            if (nt_brush) |brush| {
                _ = w32.FillRect(mem_dc, &btn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
        var plus_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            plus_char,
            1,
            &plus_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- Draw menu (≡) button (T190) ---
    {
        const btn_left = x + new_tab_btn_w;
        const btn_right = btn_left + menu_btn_w;
        self.menu_btn_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };

        // Same hover treatment as the "+" so the two read as one control
        // group. The menu being OPEN keeps it lit, which is how every
        // Windows menu button signals its popup belongs to it.
        if (self.hover_menu_btn or self.menu_open) {
            var btn_rect = w32.RECT{ .left = btn_left, .top = 0, .right = btn_right, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &btn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }

        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        // U+2261 IDENTICAL TO — the hamburger glyph, present in Segoe UI.
        const menu_char = std.unicode.utf8ToUtf16LeStringLiteral("≡");
        var menu_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            menu_char,
            1,
            &menu_rect,
            w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    // --- BitBlt to screen ---
    _ = w32.BitBlt(hdc_screen, 0, 0, client_w, bar_h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Resize so the CLIENT area is exactly `size` pixels, keeping position
/// and z-order. Used to apply the window-setup `initial_size` and by
/// `reset_window_size` (T66).
pub fn setClientSize(self: *Window, size: ClientSize) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = @intCast(size.width),
        .bottom = @intCast(size.height),
    };
    _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
    _ = w32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        w32.SWP_NOZORDER | w32.SWP_NOMOVE,
    );
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}

/// Handle WM_SIZE: re-layout the active tab's split panes and repaint tab bar.
/// Timer id used to auto-hide the resize overlay.
const RESIZE_OVERLAY_TIMER_ID: usize = 0x5247; // 'RG'

fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.showResizeOverlay();
}

/// Persist the window's outer size + maximized flag as the placement
/// memory for future windows (T85). When maximized, the RESTORED size is
/// stored (WINDOWPLACEMENT.rcNormalPosition, Windows convention) so a
/// later un-maximized window opens at the last real user size.
fn savePlacement(self: *Window, maximized: bool) void {
    if (self.is_quick_terminal) return;
    const hwnd = self.hwnd orelse return;

    var w: i32 = 0;
    var h: i32 = 0;
    if (maximized) {
        var wp: w32.WINDOWPLACEMENT = undefined;
        wp.length = @sizeOf(w32.WINDOWPLACEMENT);
        if (w32.GetWindowPlacement(hwnd, &wp) == 0) return;
        w = wp.rcNormalPosition.right - wp.rcNormalPosition.left;
        h = wp.rcNormalPosition.bottom - wp.rcNormalPosition.top;
    } else {
        var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (w32.GetWindowRect(hwnd, &r) == 0) return;
        w = r.right - r.left;
        h = r.bottom - r.top;
    }
    if (w < window_memory.MIN_DIM or h < window_memory.MIN_DIM) return;
    if (w > window_memory.MAX_DIM or h > window_memory.MAX_DIM) return;

    window_memory.save(self.app.core_app.alloc, .{
        .width = w,
        .height = h,
        .maximized = maximized,
    });
    self.app.markLayoutDirty(); // T89f: window frame changed → re-persist layout
}

/// Show the transient "columns × rows" overlay during a resize, honoring
/// the resize-overlay / -position / -duration config. Auto-hides via a
/// timer that each subsequent resize re-arms.
fn showResizeOverlay(self: *Window) void {
    switch (self.app.config.@"resize-overlay") {
        .never => return,
        .@"after-first" => if (!self.resize_seen_first) {
            // Suppress for the initial layout pass at window creation.
            self.resize_seen_first = true;
            return;
        },
        .always => {},
    }
    self.resize_seen_first = true;
    const hwnd = self.hwnd orelse return;

    // Grid dimensions from the active surface.
    const surface = self.getActiveSurface() orelse return;
    if (!surface.core_surface_ready) return;
    const grid = surface.core_surface.size.grid();

    var buf8: [32]u8 = undefined;
    const text8 = std.fmt.bufPrint(&buf8, "{d} \u{00D7} {d}", .{
        grid.columns,
        grid.rows,
    }) catch return;
    var buf16: [32]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch return;
    buf16[len16] = 0;

    if (self.resize_overlay_hwnd == null) {
        self.resize_overlay_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            hwnd,
            null,
            self.app.hinstance,
            null,
        );
        if (self.resize_overlay_hwnd) |h| {
            if (self.tab_font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const overlay = self.resize_overlay_hwnd orelse return;
    _ = w32.SetWindowTextW(overlay, @ptrCast(&buf16));

    // Position within the client area per resize-overlay-position.
    const s = self.scale;
    const ow: i32 = @intFromFloat(@round(110.0 * s));
    const oh: i32 = @intFromFloat(@round(34.0 * s));
    const margin: i32 = @intFromFloat(@round(16.0 * s));
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(hwnd, &client);
    const cw = client.right - client.left;
    const ch = client.bottom - client.top;
    const cx = @divTrunc(cw - ow, 2);
    const cy = @divTrunc(ch - oh, 2);
    var pt: w32.POINT = switch (self.app.config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = margin, .y = margin },
        .@"top-center" => .{ .x = cx, .y = margin },
        .@"top-right" => .{ .x = cw - ow - margin, .y = margin },
        .@"bottom-left" => .{ .x = margin, .y = ch - oh - margin },
        .@"bottom-center" => .{ .x = cx, .y = ch - oh - margin },
        .@"bottom-right" => .{ .x = cw - ow - margin, .y = ch - oh - margin },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(overlay, null, pt.x, pt.y, ow, oh, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    // Every reposition re-checks the z-order instead of leaving it to
    // whatever last touched it (T142).
    w32.healOverlayZOrder(overlay, hwnd);
    _ = w32.ShowWindow(overlay, w32.SW_SHOWNOACTIVATE);

    // (Re-)arm the auto-hide timer. asMilliseconds saturates, so huge
    // configured durations don't overflow the u32 SetTimer argument.
    const dur_ms: u32 = @max(1, self.app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, RESIZE_OVERLAY_TIMER_ID, dur_ms, null);
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Check the menu (≡) button first — it sits past the "+" at the far
    // right, so the two rects never overlap, but ordering the more specific
    // one first keeps a future layout change from silently swallowing it.
    if (x >= self.menu_btn_rect.left and x < self.menu_btn_rect.right) {
        self.openMenuBar();
        return;
    }

    // Check new-tab button.
    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = self.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }

    // Check each tab.
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            // Check close button area (right side of tab).
            const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
            if (x >= close_left) {
                self.closeTabByIndex(i);
            } else {
                self.selectTabIndex(i);
                // Start tracking potential tab drag
                self.drag_tab = @intCast(i);
                self.drag_start_x = x;
                self.drag_active = false;
                if (self.hwnd) |h| _ = w32.SetCapture(h);
                self.invalidateTabBar();
            }
            return;
        }
    }
}

/// Move a tab from one index to another, shifting intermediate tabs.
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.cancelTabRename();

    // Save the source tab state
    const saved_tree = self.tab_trees[from];
    const saved_surface = self.tab_active_surface[from];
    const saved_title = self.tab_titles[from];
    const saved_title_len = self.tab_title_lens[from];
    const saved_title_pinned = self.tab_title_pinned[from];
    const saved_color = self.tab_colors[from];
    const saved_hero_active = self.tab_hero_active[from];
    const saved_hero_index = self.tab_hero_index[from];
    const saved_hero_ratio = self.tab_hero_ratio[from];
    const saved_hero_scroll = self.tab_hero_scroll[from];

    if (from < to) {
        // Shift left: move [from+1..to+1] to [from..to]
        var i: usize = from;
        while (i < to) : (i += 1) {
            self.tab_trees[i] = self.tab_trees[i + 1];
            self.tab_active_surface[i] = self.tab_active_surface[i + 1];
            self.tab_titles[i] = self.tab_titles[i + 1];
            self.tab_title_lens[i] = self.tab_title_lens[i + 1];
            self.tab_title_pinned[i] = self.tab_title_pinned[i + 1];
            self.tab_colors[i] = self.tab_colors[i + 1];
            self.tab_hero_active[i] = self.tab_hero_active[i + 1];
            self.tab_hero_index[i] = self.tab_hero_index[i + 1];
            self.tab_hero_ratio[i] = self.tab_hero_ratio[i + 1];
            self.tab_hero_scroll[i] = self.tab_hero_scroll[i + 1];
        }
    } else {
        // Shift right: move [to..from] to [to+1..from+1]
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.tab_trees[i] = self.tab_trees[i - 1];
            self.tab_active_surface[i] = self.tab_active_surface[i - 1];
            self.tab_titles[i] = self.tab_titles[i - 1];
            self.tab_title_lens[i] = self.tab_title_lens[i - 1];
            self.tab_title_pinned[i] = self.tab_title_pinned[i - 1];
            self.tab_colors[i] = self.tab_colors[i - 1];
            self.tab_hero_active[i] = self.tab_hero_active[i - 1];
            self.tab_hero_index[i] = self.tab_hero_index[i - 1];
            self.tab_hero_ratio[i] = self.tab_hero_ratio[i - 1];
            self.tab_hero_scroll[i] = self.tab_hero_scroll[i - 1];
        }
    }

    // Place the saved tab at the destination
    self.tab_trees[to] = saved_tree;
    self.tab_active_surface[to] = saved_surface;
    self.tab_titles[to] = saved_title;
    self.tab_title_lens[to] = saved_title_len;
    self.tab_title_pinned[to] = saved_title_pinned;
    self.tab_colors[to] = saved_color;
    self.tab_hero_active[to] = saved_hero_active;
    self.tab_hero_index[to] = saved_hero_index;
    self.tab_hero_ratio[to] = saved_hero_ratio;
    self.tab_hero_scroll[to] = saved_hero_scroll;

    self.active_tab = to;
    self.invalidateTabBar();
    self.app.markLayoutDirty(); // T89f: tab reordered → re-persist the layout
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    var new_hover: isize = -1;
    var new_close = false;
    var new_new_tab = false;
    var new_menu_btn = false;

    if (y < self.tabBarHeight()) {
        // Check the menu (≡) button.
        if (x >= self.menu_btn_rect.left and x < self.menu_btn_rect.right) {
            new_menu_btn = true;
        } else if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            // Check new-tab button.
            new_new_tab = true;
        } else {
            // Check tabs.
            const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
            const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
            for (0..self.tab_count) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                    new_close = x >= close_left;
                    break;
                }
            }
        }
    }

    if (new_hover != self.hover_tab or
        new_close != self.hover_close or
        new_new_tab != self.hover_new_tab or
        new_menu_btn != self.hover_menu_btn)
    {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = new_new_tab;
        self.hover_menu_btn = new_menu_btn;
        self.invalidateTabBar();
    }
}

// Context menu command IDs.
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;
// Tab-color submenu (T72): one id per TabColor, in enum order.
const TAB_CTX_COLOR_BASE: usize = 9100;

// --- The menu system (T143/T190) ------------------------------------------
//
// The tree, its titles/mnemonics and the per-item state live in the pure
// `menu_bar.zig`; every row names a `commands.Id` and dispatches through
// `Surface.performCommand`, the same entry point the command palette uses
// (T189). Nothing below decides what a command DOES — it only builds the
// HMENU, tracks it, and hands the result back to that one dispatcher.

/// Open the menu system at the tab strip's "≡" button.
///
/// Also the target of F10 and a lone Alt press (Surface.handleKeyEvent), so
/// the classic Windows menu-bar activation lands on the same popup as the
/// click — the button is where the user is told to look.
pub fn openMenuBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.menu_open) return;

    // Bottom-left of the button, so the popup hangs off it the way a menu
    // bar's does. Before the first paint the rect is zeroed; the top-left of
    // the client area is the sane fallback and still lands under the strip.
    var pt = w32.POINT{
        .x = self.menu_btn_rect.left,
        .y = if (self.menu_btn_rect.bottom > 0) self.menu_btn_rect.bottom else self.tabBarHeight(),
    };
    _ = w32.ClientToScreen(hwnd, &pt);

    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu); // recursively frees the submenus too

    const state = self.menuBarState();
    self.buildMenuNodes(menu, &menu_bar.root, state);

    // Keep the button lit for the life of the popup (Windows menu-button
    // idiom) and repaint immediately — TrackPopupMenuEx blocks below.
    self.menu_open = true;
    self.invalidateTabBar();
    _ = w32.UpdateWindow(hwnd);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        hwnd,
        null,
    );

    // Drop the lit state HERE, not in a defer. Close Window / Close All
    // Windows / Exit run `Window.close()` inside the dispatch below, which
    // calls `DestroyWindow` synchronously — `onDestroy` then frees this very
    // allocation. Anything touching `self` after `performCommand` is a
    // use-after-free, so nothing does.
    self.menu_open = false;
    self.invalidateTabBar();

    if (cmd <= 0) return; // 0 = dismissed without choosing
    const id = menu_bar.fromMenuCommandId(@intCast(cmd)) orelse {
        log.warn("menu returned an unknown command id={}", .{cmd});
        return;
    };
    const surface = self.getActiveSurface() orelse return;
    log.debug("menu command id={s}", .{@tagName(id)});
    surface.performCommand(id);
}

/// Fill `menu_bar.State` from the focused surface and this window. Read at
/// open time only — the menu is built fresh per open, so there is no stale
/// state to invalidate.
fn menuBarState(self: *Window) menu_bar.State {
    var state: menu_bar.State = .{
        .tab_count = self.tab_count,
        .pane_count = if (self.tab_count > 0) self.leafCount(self.active_tab) else 1,
        .session_persistence = self.app.config.@"session-persistence",
    };
    if (self.getActiveSurface()) |surface| {
        state.search_active = surface.search_active;
        if (surface.core_surface_ready) {
            state.has_selection = surface.core_surface.hasSelection();
            state.readonly = surface.core_surface.readonly;
        }
    }
    return state;
}

/// Append `nodes` to `menu`, recursing into submenus. Item ids come from
/// `menu_bar.menuCommandId`, so a TPM_RETURNCMD result maps straight back
/// with `fromMenuCommandId`.
fn buildMenuNodes(
    self: *Window,
    menu: w32.HMENU,
    nodes: []const menu_bar.Node,
    state: menu_bar.State,
) void {
    for (nodes) |node| switch (node) {
        .separator => _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null),

        .item => |item| {
            const f = menu_bar.flags(item.cmd, state);
            var mf: u32 = w32.MF_STRING;
            if (!f.enabled) mf |= w32.MF_GRAYED;
            if (f.checked) mf |= w32.MF_CHECKED;
            // AppendMenuW copies the string, so a per-item stack buffer is
            // enough to carry the accelerator label.
            var label: menu_label.Buf = undefined;
            _ = w32.AppendMenuW(
                menu,
                mf,
                menu_bar.menuCommandId(item.cmd),
                self.menuItemLabel(item.cmd, menu_bar.title(item, state), &label),
            );
        },

        .submenu => |sub| {
            const child = w32.CreatePopupMenu() orelse {
                log.warn("submenu creation failed", .{});
                continue;
            };
            self.buildMenuNodes(child, sub.items, state);
            // Ownership passes to `menu`: DestroyMenu on the parent frees
            // every popup attached with MF_POPUP.
            _ = w32.AppendMenuW(menu, w32.MF_POPUP, @intFromPtr(child), sub.title);
        },
    };
}

/// `title`, plus a tab and the accelerator when the LIVE keybind set has a
/// trigger for this command's action (T129) — so a rebind relabels the menu
/// and an unbound command shows no hint. Commands with no binding behind
/// them (the machine chooser, About, the plugin install, Help) carry a
/// placeholder action in the registry and must never be labeled from it.
fn menuItemLabel(
    self: *const Window,
    id: commands.Id,
    title: [:0]const u16,
    buf: *menu_label.Buf,
) [*:0]const u16 {
    const cmd = commands.get(id);
    if (cmd.kind != .binding) return title.ptr;
    return menu_label.withAccel(
        title,
        self.app.config.keybind.set.getTrigger(cmd.action),
        buf,
    );
}

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Hit-test to find which tab was right-clicked.
    var clicked_tab: ?usize = null;
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            clicked_tab = i;
            break;
        }
    }

    // If clicked on empty area (not a tab), only show "New Tab".
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (self.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < self.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));

    // "Tab Color" submenu (T72): one swatch item per color, checkmark on
    // the current assignment. Swatch DIBs are app-owned — DestroyMenu does
    // not free hbmpItem bitmaps, so they are deleted after the menu closes.
    var swatches: [tab_color.count]?w32.HANDLE = [_]?w32.HANDLE{null} ** tab_color.count;
    defer for (swatches) |maybe_bmp| {
        if (maybe_bmp) |bmp| _ = w32.DeleteObject(bmp);
    };
    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        if (self.buildTabColorMenu(tab, &swatches)) |submenu| {
            _ = w32.AppendMenuW(menu, w32.MF_POPUP, @intFromPtr(submenu), std.unicode.utf8ToUtf16LeStringLiteral("Tab Color"));
        } else {
            log.warn("tab color submenu creation failed", .{});
        }
    }

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = @intCast(x), .y = @intCast(y) };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.closeTabByIndex(tab);
        },
        TAB_CTX_CLOSE_OTHERS => {
            if (clicked_tab) |tab| {
                var current = tab;
                var i: usize = self.tab_count;
                while (i > 0) {
                    i -= 1;
                    if (i != current) {
                        self.closeTabByIndex(i);
                        if (i < current) current -= 1;
                    }
                }
            }
        },
        TAB_CTX_CLOSE_RIGHT => {
            if (clicked_tab) |tab| {
                var i: usize = self.tab_count;
                while (i > tab + 1) {
                    i -= 1;
                    self.closeTabByIndex(i);
                }
            }
        },
        TAB_CTX_NEW_TAB => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => |c| {
            if (c >= TAB_CTX_COLOR_BASE and c < TAB_CTX_COLOR_BASE + tab_color.count) {
                if (clicked_tab) |tab| {
                    self.tab_colors[tab] = @enumFromInt(c - TAB_CTX_COLOR_BASE);
                    log.debug("tab {} color set to {}", .{ tab, self.tab_colors[tab] });
                    self.invalidateTabBar();
                    self.app.markLayoutDirty(); // T89f: tab color changed → re-persist
                }
            }
        },
    }
}

/// Build the "Tab Color" submenu (T72): ten items in TabColor order, each
/// with a rendered swatch bitmap, the current color checked. The created
/// swatch DIB handles are returned via `swatches` so the caller can delete
/// them after the menu closes (they outlive this function — the menu holds
/// only weak references). Returns null if menu creation fails.
fn buildTabColorMenu(
    self: *Window,
    tab: usize,
    swatches: *[tab_color.count]?w32.HANDLE,
) ?w32.HMENU {
    const submenu = w32.CreatePopupMenu() orelse return null;
    const current = self.tab_colors[tab];
    inline for (comptime std.meta.tags(tab_color.TabColor), 0..) |c, idx| {
        var flags: u32 = w32.MF_STRING;
        if (c == current) flags |= w32.MF_CHECKED;
        const id = TAB_CTX_COLOR_BASE + idx;
        _ = w32.AppendMenuW(submenu, flags, id, tab_color.labelW(c));
        if (self.makeSwatchBitmap(c)) |bmp| {
            swatches[idx] = bmp;
            const mii = w32.MENUITEMINFOW{
                .fMask = w32.MIIM_BITMAP,
                .hbmpItem = bmp,
            };
            _ = w32.SetMenuItemInfoW(submenu, @intCast(id), 0, &mii);
        }
    }
    return submenu;
}

/// Create a DPI-scaled 32bpp premultiplied-ARGB DIB swatch for a tab color
/// (rendered by the pure tab_color.writeSwatch). Caller owns the handle.
fn makeSwatchBitmap(self: *Window, c: tab_color.TabColor) ?w32.HANDLE {
    const size_f = @round(16.0 * self.scale);
    const size: usize = @intFromFloat(@max(size_f, 8.0));
    var bits: ?*anyopaque = null;
    const bmi = w32.BITMAPINFO{
        .bmiHeader = .{
            .biWidth = @intCast(size),
            .biHeight = -@as(i32, @intCast(size)), // top-down
        },
    };
    const bmp = w32.CreateDIBSection(null, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    const pixels = @as([*]u32, @ptrCast(@alignCast(bits orelse {
        _ = w32.DeleteObject(bmp);
        return null;
    })))[0 .. size * size];
    tab_color.writeSwatch(pixels, size, tab_color.rgb(c));
    return bmp;
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_new_tab or self.hover_menu_btn) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.hover_menu_btn = false;
        self.invalidateTabBar();
    }
}

/// Rename edit control child ID.
const RENAME_EDIT_ID: u16 = 300;

/// Open the "Change Window Title" dialog (ctrl+shift+r /
/// prompt_window_title). The title set here pins the titlebar for the
/// whole window until cleared with an empty commit (T50 dialog, T92
/// semantics). The inline tab-rename Edit remains the double-click
/// affordance on visible tabs.
pub fn promptRenameWindow(self: *Window) void {
    RenameDialog.open(self, .window, null);
}

/// Open the "Change Tab Title" dialog for the tab containing `surface`
/// (prompt_tab_title, T92). Commits via setTabTitlePin.
pub fn promptTabTitle(self: *Window, surface: *Surface) void {
    RenameDialog.open(self, .tab, surface);
}

/// Open the "Change Pane Title" dialog for `surface`
/// (prompt_surface_title, T92). Commits via Surface.setUserTitle.
pub fn promptPaneTitle(self: *Window, surface: *Surface) void {
    RenameDialog.open(self, .pane, surface);
}

/// Open the "New Remote Window" machine chooser (ctrl+shift+n / palette).
pub fn openMachineChooser(self: *Window) void {
    MachineChooser.open(self);
}

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    // Cancel any existing rename
    self.cancelTabRename();

    const hwnd = self.hwnd orelse return;

    // With the tab bar hidden (e.g. a single tab under the default
    // window-show-tab-bar = auto) there is no tab rect to anchor to —
    // tab_rects is zeroed/stale and the editor would be created invisible
    // while still stealing keyboard focus (an un-dismissable "mystery
    // box"). Anchor a visible strip at the top of the client area instead.
    const rect: w32.RECT = if (self.tab_bar_visible) self.tab_rects[tab_idx] else blk: {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        const h: i32 = @intFromFloat(@round(32.0 * self.scale));
        const max_w: i32 = @intFromFloat(@round(400.0 * self.scale));
        const w: i32 = @min(client.right - client.left - 8, max_w);
        if (w <= 8) return;
        break :blk .{ .left = 4, .top = 4, .right = 4 + w, .bottom = 4 + h };
    };

    // tab_titles stores only `tab_title_lens` valid u16s; the rest is
    // uninitialized. CreateWindowExW reads a NUL-terminated wide string,
    // so a NUL-terminated copy avoids the Edit displaying garbage past
    // the real title.
    var title_buf: [257]u16 = undefined;
    const tlen = self.tab_title_lens[tab_idx];
    @memcpy(title_buf[0..tlen], self.tab_titles[tab_idx][0..tlen]);
    title_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_tab = tab_idx;
}

/// Apply the edit text as the new tab title and destroy the edit control.
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const tab_idx = self.rename_tab;

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (wlen > 0) {
        // T92: a user rename pins the tab title against pane-driven
        // updates until cleared with an empty rename.
        const len: u16 = @intCast(@min(wlen, 255));
        @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
        self.tab_title_lens[tab_idx] = len;
        self.tab_title_pinned[tab_idx] = true;
        if (tab_idx == self.active_tab) self.updateWindowTitle();
    } else {
        // Empty clears the pin and restores the pane-driven title (T92).
        self.tab_title_pinned[tab_idx] = false;
        self.refreshTabTitle(tab_idx);
        if (tab_idx == self.active_tab) self.updateWindowTitle();
    }
    self.app.markLayoutDirty(); // T89f: inline tab rename → re-persist

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.invalidateTabBar();

    // Return focus to the active surface
    if (self.getActiveSurface()) |s| {
        if (s.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
    }
}

/// Cancel inline rename without applying changes.
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishTabRename: null before destroy.
        self.rename_edit = null;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        if (self.getActiveSurface()) |s| {
            if (s.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
        }
    }
}

/// Return true if it is safe to close this whole window. If any tab still
/// has a running process, show a single aggregate confirmation dialog
/// (mirroring macOS/GTK, which confirm once per window) and return whether
/// the user approved. Whole-window close paths (title-bar X, Alt+F4,
/// close_window) previously skipped this check entirely; the per-surface
/// close path (Ctrl+Shift+W) still confirms separately in Surface.close.
/// When the last tab has already been closed (tab_count == 0) there is
/// nothing to confirm, so this returns true silently.
pub fn confirmCloseIfNeeded(self: *Window) bool {
    var needs = false;
    outer: for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            if (surface.core_surface_ready and
                surface.core_surface.needsConfirmQuit())
            {
                needs = true;
                break :outer;
            }
        }
    }
    if (!needs) return true;

    const refocus: ?w32.HWND = if (self.getActiveSurface()) |s| s.hwnd else null;
    const result = ConfirmDialog.show(
        self.app,
        self.hwnd,
        self.scale,
        refocus,
        .{
            .title = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty"),
            .text = std.unicode.utf8ToUtf16LeStringLiteral(
                "Processes are still running in this window.\nClose anyway?",
            ),
        },
    );
    return result == .ok;
}

/// Handle WM_CLOSE: clean up all tabs, then destroy the window.
/// OpenGL contexts and DCs must be released BEFORE DestroyWindow,
/// because Win32 destroys child HWNDs during DestroyWindow and the
/// OpenGL driver crashes if contexts are still active on destroyed windows.
pub fn close(self: *Window) void {
    // T89e: this is a USER window-close (title-bar X, Alt+F4, close_window,
    // close_all_windows, +close window). Every pane's agent session must END
    // (CLOSE), not detach. Mark before cleanupAllSurfaces reads the flag.
    // The app-quit teardown path is Window.deinit (which also calls
    // cleanupAllSurfaces but deliberately does NOT mark), so quitting keeps
    // sessions alive for re-attach.
    self.markAllSessionsClose();

    // First, cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Deinit and free all tab trees (which unrefs and frees surfaces).
fn cleanupAllSurfaces(self: *Window) void {
    // Deinit in place and reset to .empty. SplitTree.deinit sets self.*
    // to undefined; deinit'ing a local copy would only mark the copy,
    // leaving stale arena/node pointers in tab_trees that any post-WM_CLOSE
    // message walking the slot could dereference.
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
    self.tab_count = 0;
}

/// Mark every pane in every tab to END its agent session (CLOSE) rather than
/// DETACH when freed (T89e). Called from the user window-close path
/// (Window.close) BEFORE the surfaces are torn down. The app-quit teardown
/// (Window.deinit) deliberately does NOT call this, so app quit / logoff /
/// crash / upgrade leave sessions alive for the next launch. No-op for local
/// exec panes (session-persistence off) — setSessionCloseIntent no-ops there.
fn markAllSessionsClose(self: *Window) void {
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.setSessionCloseIntent(true);
    }
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        if (self.tab_font) |font| {
            _ = w32.DeleteObject(font);
            self.tab_font = null;
        }
        self.hwnd = null;
        // QuickTerminal handles the rest of cleanup (freeing self, quit timer).
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }

    // Remove from App's window list.
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }

    // T89f: this window is gone → re-persist the layout so it drops from the
    // manifest (a no-op during app-quit teardown, where msg_hwnd is already
    // down and terminate() did the authoritative capture first).
    app.markLayoutDirty();

    // T147 (non-destructive agent upgrade): a persistent window just closed, so
    // the agent may have gone idle — the one moment a stale agent can be
    // adopted with nothing to lose. Posted, not called: this window is off the
    // list but its surfaces are still unwinding below, and the check counts
    // what is live.
    if (self.local_agent_conn != null) app.scheduleAgentUpgradeCheck();

    // Drop IPC names before the allocation is freed below (deinit() is not
    // called on this path).
    app.ipcForget(.{ .window = self });
    if (self.ipc_name) |n| {
        app.core_app.alloc.free(n);
        self.ipc_name = null;
    }
    if (self.title_override) |t| {
        app.core_app.alloc.free(t);
        self.title_override = null;
    }

    // Tear down the remote-agent transport (T81: this path used to LEAK it —
    // the connection, its ws socket, and all its threads outlived every
    // window close). Safe here for the same reason as in deinit(): close()
    // already ran cleanupAllSurfaces() before DestroyWindow, so no termio
    // backend borrows the conn anymore.
    if (self.remote_dialed) |d| {
        d.deinitDestroy(app.core_app.alloc);
        self.remote_dialed = null;
    }
    if (self.remote_machine) |m| {
        m.deinitFree(app.core_app.alloc);
        self.remote_machine = null;
    }

    // Clean up Window-level resources.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Window procedure for top-level container HWNDs (GhosttyWindow class).
/// GWLP_USERDATA stores a *Window pointer.
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Once the last tab is closed and WM_CLOSE has been posted, drop any
    // input messages still queued for this window. They could otherwise
    // mutate state (allocate, capture mouse, start drags) on a window
    // about to be destroyed. WM_CLOSE/WM_DESTROY/paint/size still flow
    // through so close itself can complete cleanly.
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    switch (msg) {
        w32.WM_SETTINGCHANGE => {
            // An OS light/dark flip arrives here (a WM_SETTINGCHANGE
            // broadcast reaches TOP-LEVEL windows only — never the child
            // surface procs). Re-report the scheme to every pane so OSC
            // 10/11 queries and `light:`/`dark:` conditional config react
            // live (T26), and re-apply the DWM chrome theme for
            // `window-theme = system`. The core no-ops when the scheme is
            // unchanged, so reacting to every setting change is safe.
            window.reportColorScheme();
            applyChromeTheme(
                hwnd,
                window.app.config.@"window-theme",
                window.app.config.background,
            );
            // Flush the USER menu theme cache so context menus track the
            // flip too (`system` runs in allow-dark mode — the mode value
            // is unchanged, but menus already created cached the old
            // palette) (T79).
            DarkMode.apply(
                window.app.config.@"window-theme",
                window.app.config.background,
            );
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT on the
            // top-level window too. See the matching handler in
            // App.surfaceWndProc for the rationale: returning 0 here
            // prevents oleacc from creating an AccWrap proxy whose
            // later destruction can re-enter our WindowProc via
            // SetFocus and deadlock on a COM marshaling reply.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_TIMER => {
            if (wparam == RESIZE_OVERLAY_TIMER_ID) {
                if (window.resize_overlay_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
                _ = w32.KillTimer(hwnd, RESIZE_OVERLAY_TIMER_ID);
                return 0;
            }
            if (wparam == HERO_SNAP_TIMER_ID) {
                window.heroSnapTick();
                return 0;
            }
            if (wparam == HERO_ANIM_TIMER_ID) {
                window.heroAnimTick();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_APP_HERO_SNAP => {
            window.heroOnSnapReady(wparam);
            return 0;
        },
        WM_APP_OPEN_MENU => {
            window.openMenuBar();
            return 0;
        },

        w32.WM_CTLCOLORSTATIC => {
            // Dark theming for the STATIC popups owned by this window
            // (hovered-URL link preview, resize overlay). Static controls
            // send this to their owner, i.e. here — not to surfaceWndProc.
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (window.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SIZE => {
            // Minimizing does not hide child surface HWNDs, so tell the core
            // to stop rendering the active tab while minimized. Return early:
            // the client rect is 0x0 while minimized, so re-laying-out would
            // both re-mark the surfaces visible (undoing the occlusion) and
            // collapse the grid, and the resize overlay would flash offscreen.
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setActiveTabVisible(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setActiveTabVisible(true);
            }
            // T85: persist maximize/restore TRANSITIONS only —
            // SIZE_RESTORED also fires for every programmatic resize
            // (initial_size, reset_window_size), which must not write
            // the placement memory.
            if (wparam == w32.SIZE_MAXIMIZED and !window.was_maximized) {
                window.was_maximized = true;
                window.savePlacement(true);
            } else if (wparam == w32.SIZE_RESTORED and window.was_maximized) {
                window.was_maximized = false;
                window.savePlacement(false);
            }
            window.handleResize();
            return 0;
        },
        w32.WM_MOVE => {
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar is a screen-positioned popup that must follow its
            // owner. Reposition every surface's scrollbar across all tabs
            // so hidden tabs don't surface a stale position when activated.
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    if (entry.view.scrollbar) |sb| _ = sb.repositionAndResize();
                }
            }
            // The dim overlays are screen-positioned popups too (T74).
            window.updateDimOverlays();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETMINMAXINFO => {
            // Apply user-configured size limits if any. lparam points
            // to a MINMAXINFO the OS will consult for resize clamping.
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = true;
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = false;
            }
            // T85: the user finished an interactive resize/move — remember
            // the outer size. Drag-to-top ("aero snap" maximize) can zoom
            // the window before this arrives, so read the live state and
            // keep the WM_SIZE transition tracker in sync.
            const zoomed = w32.IsZoomed(hwnd) != 0;
            window.was_maximized = zoomed;
            window.savePlacement(zoomed);
            return 0;
        },
        w32.WM_CLOSE => {
            // Title-bar X / Alt+F4 / close_all_windows land here. Confirm
            // once for the whole window if any tab has a running process.
            // window.close() then marks every pane's session CLOSE (T89e).
            if (!window.confirmCloseIfNeeded()) return 0;
            window.close();
            return 0;
        },
        w32.WM_QUERYENDSESSION => {
            // Logoff / shutdown / reboot (T89e): allow it (return TRUE). This
            // is an app-EXIT path, NOT a user window-close — we deliberately
            // do NOT mark sessions CLOSE here, so the local agent keeps its
            // pinned sessions + ring snapshots and they re-attach on the next
            // launch. (WM_QUERYENDSESSION never routes through window.close.)
            return 1;
        },
        w32.WM_ENDSESSION => {
            // The session is ending; the process is about to die. Sessions
            // survive because the agent owns the PTYs and we sent no CLOSE.
            // Flush the layout manifest NOW (synchronously — there may be no
            // more message pump) so re-attach restores the window geometry
            // after the logoff/reboot (T89f).
            window.app.syncSessionLayout();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            window.paintWindow();
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            // Tab rename Edit lost focus — commit (standard Win32
            // convention, matches Explorer file rename and Edge tabs).
            // Esc still cancels via the message-loop intercept that
            // catches VK_ESCAPE before it reaches the Edit.
            if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                window.finishTabRename();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // Forward keyboard focus to the active child surface.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the terminal.
            if (window.getActiveSurface()) |s| {
                if (s.hwnd) |h| App.deferSetFocus(h); // T48: defer out of WndProc
            }
            return 0;
        },
        // Deliberately still "erased nothing" (T155). Painting the divider
        // bands from here was tried and REVERTED: it regressed
        // pane-banner.ps1 (the banner overlay is a layered window above this
        // area, and erase-time painting into the parent DC disturbs its
        // composite). It is also unnecessary — the panes and the band now
        // TILE the content area, so a moved band's old pixels are covered by
        // a child window and there is no parent-owned region left to hold a
        // stale line. The band itself is painted in WM_PAINT and after layout.
        w32.WM_ERASEBKGND => return 1,
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.heroHitDivider(x, y)) {
                window.heroStartDividerDrag();
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.hero_divider_drag) {
                window.heroEndDividerDrag();
                return 0;
            }
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            if (window.drag_tab >= 0) {
                window.drag_tab = -1;
                window.drag_active = false;
                _ = w32.ReleaseCapture();
                return 0;
            }
            // Hero carousel: clicking a thumbnail selects it (the Mac
            // selects on mouse-up inside a tile).
            if (window.tab_count > 0 and window.tab_hero_active[window.active_tab]) {
                const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
                const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
                if (HeroCarousel.hitTest(window, x, y)) |index| {
                    window.heroSelect(@intCast(index));
                    return 0;
                }
            }
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            // Double-click the hero divider: reset the carousel ratio to
            // the default (parity with tree-divider double-click → 0.5).
            if (window.heroHitDivider(x, y)) {
                window.tab_hero_ratio[window.active_tab] = hero_math.RATIO_DEFAULT;
                window.layoutSplits();
                if (window.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
                return 0;
            }
            // Double-click on tab bar starts inline rename
            if (y < window.tabBarHeight()) {
                for (0..window.tab_count) |i| {
                    const rect = window.tab_rects[i];
                    if (x >= rect.left and x < rect.right) {
                        window.startTabRename(i);
                        return 0;
                    }
                }
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                window.app.markLayoutDirty(); // T110: double-click reset ratio
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (y < window.tabBarHeight()) {
                window.handleTabBarRightClick(x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.hero_divider_drag) {
                window.heroUpdateDividerDrag(x);
                return 0;
            }
            if (window.dragging_split) {
                window.updateDividerDrag(x, y);
                return 0;
            }
            // Handle tab drag reorder
            if (window.drag_tab >= 0) {
                const xi16: i16 = @truncate(x);
                const dx = if (xi16 > window.drag_start_x) xi16 - window.drag_start_x else window.drag_start_x - xi16;
                if (!window.drag_active and dx > 5) {
                    window.drag_active = true;
                }
                if (window.drag_active and window.tab_count > 1) {
                    // Use uniform tab widths for drag target calculation,
                    // not the painted widths (the last tab gets stretched
                    // to fill remaining space, skewing its midpoint).
                    const from: usize = @intCast(window.drag_tab);
                    const first_w = window.tab_rects[0].right - window.tab_rects[0].left;
                    var target: usize = 0;
                    for (0..window.tab_count) |i| {
                        const slot_left: i32 = @intCast(@as(i32, @intCast(i)) * first_w);
                        const slot_mid = slot_left + @divTrunc(first_w, 2);
                        if (x >= slot_mid) {
                            target = i;
                        }
                    }
                    // Clamp to valid range
                    if (target >= window.tab_count) target = window.tab_count - 1;
                    if (target != from) {
                        window.moveTabTo(from, target);
                        window.drag_tab = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            } else if (window.tab_count > 0 and window.tab_hero_active[window.active_tab]) {
                window.heroMouseMove(x, y);
            }
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            // Wheel over the owner-painted carousel scrolls it. The
            // message lands here (not on a child surface) via Win10+
            // hover routing; wheel coords are SCREEN coords.
            var pt: w32.POINT = .{
                .x = @as(i16, @truncate(lparam & 0xFFFF)),
                .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
            };
            _ = w32.ScreenToClient(hwnd, &pt);
            const raw: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            if (window.heroWheel(pt.x, pt.y, raw)) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.heroHitDivider(pt.x, pt.y) or window.hero_divider_drag) {
                    if (w32.LoadCursorW(null, w32.IDC_SIZEWE)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
                if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.handleTabBarMouseLeave();
            window.heroMouseLeave();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            // Either direction: this is the event at which a stray topmost
            // overlay becomes visible as "the background window's banner is
            // over the foreground", so it is the event that must heal it
            // (T142). Idempotent and cheap when nothing is wrong.
            window.healOverlayZOrders();
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
