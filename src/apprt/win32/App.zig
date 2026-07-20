//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork (branding, fork apprt actions).
//! Win32 application runtime. Manages the Win32 window class, message loop,
//! and surface (window) lifecycle.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const ClaudeIntegration = @import("ClaudeIntegration.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const DarkMode = @import("DarkMode.zig");
const PathInstaller = @import("PathInstaller.zig");
const IpcRegistry = @import("IpcRegistry.zig");
const IpcServer = @import("IpcServer.zig");
const MachineChooser = @import("MachineChooser.zig");
const RenameDialog = @import("RenameDialog.zig");
const BannerDialog = @import("BannerDialog.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const update_check = @import("update_check.zig");
const w32 = @import("win32.zig");

const build_config = @import("../../build_config.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");

/// A registered global system hotkey: the RegisterHotKey id and the binding
/// action to perform when WM_HOTKEY delivers that id.
const GlobalHotkey = struct { id: i32, action: input.Binding.Action };

const log = std.log.scoped(.win32);

/// OpenGL draws happen on the renderer thread, not the app thread.
pub const must_draw_from_app_thread = false;

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// Posted by the IPC listener thread to marshal a request to the GUI
/// thread. wparam = *IpcServer.Pending. (WM_APP+2/+3 are defined below:
/// WM_APP_UPDATE_AVAILABLE, WM_APP_TRAY. WM_APP+6 is Window.WM_APP_HERO_SNAP;
/// WM_APP+7/+8 are ClaudeIntegration's prompt/done messages.)
pub const WM_APP_IPC: u32 = w32.WM_APP + 4;

/// Posted (via `deferSetFocus`) to move keyboard focus to a terminal
/// surface HWND from the top of the message loop instead of synchronously
/// inside a WndProc. The target is the posted window itself (msg.hwnd); the
/// run loop performs the real SetFocus and never dispatches this to a
/// WndProc. See `deferSetFocus` for why (T48 deadlock).
pub const WM_APP_SETFOCUS: u32 = w32.WM_APP + 5;

/// Timer ID for the quit-after-last-window-closed delay.
const QUIT_TIMER_ID: usize = 1;

/// Window class for the top-level container (GDI painting, no CS_OWNDC).
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyWindow");

/// Window class for terminal surfaces (OpenGL via WGL, needs CS_OWNDC).
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyTerminal");

/// Window class for the message-only HWND (WM_APP_WAKEUP, WM_TIMER).
pub const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyMsg");

/// The core application.
core_app: *CoreApp,

/// The configuration for the application. Loaded during init and
/// updated in response to config_change actions.
config: Config,

/// A message-only window used to receive WM_APP_WAKEUP.
/// This is not a visible window; it just participates in the message loop.
msg_hwnd: ?w32.HWND = null,

/// Coalesces WM_APP_WAKEUP posts (same N-signals -> >=1-delivery contract
/// as xev.Async): at most one wakeup message is in the queue at a time.
/// Without this, heavy PTY output posts one message per surface-mailbox
/// push (tens of thousands/s), fills the thread's 10,000-entry posted-
/// message quota, and EVERY PostMessageW in the process starts failing —
/// IPC requests answer "server not ready", deferred SetFocus and hero
/// snapshots get dropped (found by the T53a soak).
wakeup_pending: std.atomic.Value(bool) = .init(false),

/// The HINSTANCE for this module.
hinstance: w32.HINSTANCE,

/// Window class atoms from RegisterClassExW.
class_atom: u16 = 0,
terminal_class_atom: u16 = 0,
msg_class_atom: u16 = 0,

/// List of active Window containers (tabbed windows).
windows: std.ArrayList(*Window) = .empty,

/// Last mouse SCREEN position seen by any surface's WM_MOUSEMOVE (T75,
/// focus-follows-mouse). Windows regenerates WM_MOUSEMOVE for a
/// stationary cursor whenever the window under it changes (split
/// created/closed, pane shown/hidden), so focus may only follow the
/// mouse when the pointer physically moved — the win32 analog of the
/// GTK surface's "is_cursor_still" guard.
ffm_last_screen_pos: ?w32.POINT = null,

/// Background brush created from the configured background color.
/// Used by WM_ERASEBKGND to fill exposed areas during resize,
/// matching the terminal background so the flash is invisible.
bg_brush: ?w32.HBRUSH = null,

/// Quit timer state, mirroring GTK's three-state approach:
/// - off: no quit pending
/// - active: timer is running (waiting for delay to expire)
/// - expired: delay has elapsed, quit on next tick
quit_timer_state: enum { off, active, expired } = .off,

/// Whether quit has been requested.
quit_requested: bool = false,

/// The quick terminal instance (if active).
quick_terminal: ?*QuickTerminal = null,

/// Registered global system hotkeys (RegisterHotKey). Maps the id delivered in
/// WM_HOTKEY back to the binding action to perform. Generalized from the old
/// single quick-terminal hotkey to every keybind flagged `global:`.
global_hotkeys: std.ArrayList(GlobalHotkey) = .empty,

/// Cached ITaskbarList3 for taskbar-button progress (OSC 9;4), created lazily
/// on first progress_report. Null until then / if COM creation fails.
taskbar: ?*w32.ITaskbarList3 = null,

/// Core surface id of the surface that produced the current desktop
/// notification balloon; a balloon click focuses it. 0 = app-targeted.
/// A single id suffices: there is one NOTIF_DESKTOP_UID tray balloon and
/// each new notification overwrites it.
notif_desktop_surface_id: u64 = 0,

/// Version text of the newest win-v release the update check found (heap,
/// app allocator). A click on the update balloon opens that release's
/// GitHub page. Null until an update notification has been shown.
update_latest_ver: ?[]u8 = null,

/// Whether CoInitializeEx has been called on the main thread.
com_initialized: bool = false,

/// The IPC named-pipe server (null if binding failed non-fatally). Owning
/// the pipe name is also the single-instance lock; see IpcServer.zig.
ipc_server: ?IpcServer = null,

/// IPC target registry: named windows and panes (`+new-window --target`,
/// `+split --name`). See IpcRegistry.zig; the App methods below adapt it
/// to the live window list and app allocator.
ipc_registry: IpcRegistry = .{},

pub const IpcTarget = IpcRegistry.Target;

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;

    // Clear the inherited ignore-Ctrl-C flag. A GUI launched from a chain
    // that used CREATE_NEW_PROCESS_GROUP anywhere (scripts, CI, `+new-window`
    // auto-launch from automation) starts with ^C delivery disabled, and the
    // flag inherits into every ConPTY shell we spawn — ctrl+c then silently
    // never interrupts native children in ANY pane of this instance (T84).
    _ = w32.SetConsoleCtrlHandler(null, 0);

    // Load the configuration for this application.
    const alloc = core_app.alloc;
    var config = Config.load(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();

    // Create a brush matching the configured background color so that
    // any exposed window area during resize matches the terminal
    // background, making the flash invisible.
    const bg = config.background;
    const bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

    // Seed the app-level conditional state (light/dark) from the OS BEFORE
    // any surface exists — the macOS apprt does the equivalent at startup.
    // Every new core surface inherits this state, so its init-time
    // color-scheme report (T26) is a no-op instead of a `reload_config`
    // that re-derives the just-created surface's config from the app
    // config — a wipe that destroyed per-surface IPC overrides
    // (`+new-remote-window --command`'s `wait-after-command` in
    // particular) within milliseconds of creation.
    core_app.config_conditional_state.theme =
        if (Window.systemUsesLightTheme()) .light else .dark;

    // Keep the app config's own conditional state consistent with what we
    // just seeded: replay `light:`/`dark:` conditionals now so surface
    // clones start from a config whose recorded state MATCHES the app
    // state (`changeConditionalState` then returns null at surface init,
    // preserving runtime overrides on the clone). Configs with no theme
    // conditionals return null here — nothing to do.
    if (config.changeConditionalState(
        core_app.config_conditional_state,
    ) catch null) |applied| {
        config.deinit();
        config = applied;
    }

    // Opt the app into dark USER menus (TrackPopupMenuEx renders with the
    // classic light palette otherwise, breaking dark chrome — T79). Must
    // happen before any menu is shown; kept in sync on config reload and
    // WM_SETTINGCHANGE.
    DarkMode.apply(config.@"window-theme", config.background);

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
    };

    // Register the window container class (GDI painting, no CS_OWNDC).
    // CS_DBLCLKS is required to receive WM_LBUTTONDBLCLK for divider equalize.
    // Application icon, loaded from the embedded resource. Falls back
    // to the default app icon if missing (only happens with unusual
    // build configs that strip the .rc file).
    const app_icon = w32.LoadIconW(hinstance, w32.IDI_GHOSTTY) orelse
        w32.LoadIconW(null, w32.IDI_APPLICATION);

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_DBLCLKS,
        .lpfnWndProc = &Window.windowWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;
    errdefer if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
    };

    // Register the terminal surface class (OpenGL via WGL, needs CS_OWNDC).
    const tc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_OWNDC,
        .lpfnWndProc = &surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = TERMINAL_CLASS_NAME,
        .hIconSm = app_icon,
    };

    self.terminal_class_atom = w32.RegisterClassExW(&tc);
    if (self.terminal_class_atom == 0) return error.Win32Error;
    errdefer if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
    };

    // Register the message-only window class (WM_APP_WAKEUP, WM_TIMER).
    const mc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &msgWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = MSG_CLASS_NAME,
        .hIconSm = null,
    };

    self.msg_class_atom = w32.RegisterClassExW(&mc);
    if (self.msg_class_atom == 0) return error.Win32Error;
    errdefer if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
    };

    // Create a message-only window for receiving WM_APP_WAKEUP.
    // HWND_MESSAGE makes it a message-only window (invisible, no rendering).
    self.msg_hwnd = w32.CreateWindowExW(
        0,
        MSG_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("GhozttyMsg"),
        0, // no style needed
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;

    // Store self pointer in msg_hwnd's GWLP_USERDATA for msgWndProc access
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Bind the IPC pipe and become the master instance. If another process
    // already owns the pipe, forward a `new-window` request to it and exit
    // (Mac single-app behavior).
    self.ipc_server = @as(IpcServer, undefined);
    self.ipc_server.?.init(self) catch |err| switch (err) {
        error.AlreadyRunning => {
            log.info("another instance owns the IPC pipe; forwarding new-window", .{});
            const ok = internal_os.ipc_client.sendAction(alloc, "new-window", null) catch false;
            std.process.exit(if (ok) 0 else 1);
        },
        error.OutOfMemory => return error.OutOfMemory,
        // Run without an IPC server rather than refusing to start.
        error.BindFailed => self.ipc_server = null,
    };

    // Register global hotkey for quick terminal (if configured).
    self.registerGlobalHotkey();

    // Check for updates in the background (non-blocking). Only acts in
    // -Dwindows-update-check channel builds (T24).
    self.startUpdateCheck(.automatic);

    // Keep the `ghoztty` CLI resolvable from any shell (T70). Background
    // thread; only acts when running from the canonical install dir.
    PathInstaller.ensureOnPathAsync();

    // One-time Claude Code integration offer (T71). Background thread;
    // same canonical-install gate as the PATH self-heal.
    ClaudeIntegration.checkOnLaunchAsync(self);
}

/// Defer a focus change to a terminal surface out of the current WndProc.
///
/// Calling `SetFocus` synchronously from inside a WndProc (mouse-button
/// handlers, WM_SETFOCUS forwarding, focus-after-popup, or performAction)
/// runs the IME/CTF activation cascade inline; that cascade does a
/// synchronous SendMessage (WM_IME_SETCONTEXT) which re-enters our
/// WindowProc, and on that nested, non-pumping stack the GUI thread can
/// `std.Thread.Condition.wait()` forever — the T48 release deadlock
/// (docs/design/t48-deadlock-dump-analysis.md). Posting WM_APP_SETFOCUS
/// makes the run loop perform the SetFocus at the top of the loop, outside
/// any nested SendMessage/hook/CTF callback, so the cascade runs where the
/// thread can pump. Use this for terminal-surface targets; plain EDIT
/// controls and dialog windows don't drive the OpenGL surface's IME/CTF
/// hook path and keep synchronous focus (immediate typing/Tab routing).
pub fn deferSetFocus(hwnd: w32.HWND) void {
    _ = w32.PostMessageW(hwnd, WM_APP_SETFOCUS, 0, 0);
}

/// Open the config file in the default editor.
fn openConfigFile(self: *App) void {
    const config_path = configpkg.preferredDefaultFilePath(
        self.core_app.alloc,
    ) catch |err| {
        log.err("failed to get config path: {}", .{err});
        return;
    };
    defer self.core_app.alloc.free(config_path);

    // Convert to wide string for ShellExecuteW.
    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, config_path) catch return;
    if (wlen < wbuf.len) {
        wbuf[wlen] = 0;
        _ = w32.ShellExecuteW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("open"),
            @ptrCast(&wbuf),
            null,
            null,
            w32.SW_SHOW,
        );
    }
}

/// Show the given config's load diagnostics in a dialog, if it has any
/// (T69). Without this the diagnostics only reach `log.err`, which is
/// invisible in a GUI-subsystem release build — the user just silently
/// gets defaults (Mac shows ConfigurationErrorsController, GTK the
/// config-errors dialog). "Open Config" launches the editor, "Ignore"
/// carries on with the settings that did parse.
fn showConfigErrorsIfAny(
    self: *App,
    config: *const Config,
    owner: ?*Window,
) void {
    const diags = &config._diagnostics;
    if (diags.empty()) return;

    const alloc = self.core_app.alloc;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const items = diags.items();
    // Cap the list so a wildly broken file can't build a dialog taller
    // than the screen.
    const shown = @min(items.len, 8);
    buf.writer.print(
        "{d} issue{s} found while loading the configuration:\n\n",
        .{ items.len, if (items.len == 1) "" else "s" },
    ) catch return;
    for (items[0..shown]) |*diag| {
        diag.format(&buf.writer) catch return;
        buf.writer.writeByte('\n') catch return;
    }
    if (items.len > shown) {
        buf.writer.print(
            "\u{2026}and {d} more.\n",
            .{items.len - shown},
        ) catch return;
    }
    buf.writer.writeAll(
        "\nGhoztty is running with the remaining settings.",
    ) catch return;

    const text = buf.toOwnedSliceSentinel(0) catch return;
    defer alloc.free(text);
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return;
    defer alloc.free(text_w);

    const refocus: ?w32.HWND = if (owner) |win|
        (if (win.getActiveSurface()) |s| s.hwnd else null)
    else
        null;
    const result = ConfirmDialog.show(
        self,
        if (owner) |win| win.hwnd else null,
        if (owner) |win| win.scale else 1.0,
        refocus,
        .{
            .title = std.unicode.utf8ToUtf16LeStringLiteral("Configuration Errors"),
            .text = text_w,
            .icon = .warning,
            .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Open Config"),
            .cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Ignore"),
        },
    );
    if (result == .ok) self.openConfigFile();
}

pub fn run(self: *App) !void {
    // Create the initial Window container with one tab.
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, .{});
    try self.windows.append(alloc, window);
    _ = try window.addTab();

    // Surface config load diagnostics once at startup (T69). After the
    // first window exists so the dialog has an owner to center on; the
    // dialog pumps its own modal loop, so startup messages (paints, IPC)
    // keep flowing while it is up.
    self.showConfigErrorsIfAny(&self.config, window);

    // Enter the Win32 message loop
    var msg: w32.MSG = undefined;
    loop: while (true) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT received. Check if it's still wanted — stopQuitTimer()
            // resets quit_requested if a new surface opened after
            // PostQuitMessage was called (e.g. during startup).
            // GetMessageW consumes the quit flag, so the next call will
            // block normally for real messages.
            if (!self.quit_requested) continue;
            break;
        }
        if (result < 0) return error.Win32Error;
        if (self.quit_requested) break;

        // Deferred focus (T48). Perform SetFocus here — at the top of the
        // message loop, outside any nested SendMessage/hook/CTF callback —
        // rather than synchronously inside a WndProc. SetFocus runs the
        // IME/CTF activation cascade inline; from a deep WndProc stack that
        // cascade re-enters our WindowProc and the GUI thread can then
        // Condition.wait() forever (the release deadlock, see deferSetFocus
        // and docs/design/t48-deadlock-dump-analysis.md). We never dispatch
        // this message; the target is the posted window (msg.hwnd), whose
        // queued messages the OS drops if it was destroyed meanwhile.
        if (msg.message == WM_APP_SETFOCUS) {
            if (msg.hwnd) |h| _ = w32.SetFocus(h);
            continue;
        }

        // Dispatch a global hotkey to its bound action.
        if (msg.message == w32.WM_HOTKEY) {
            const id: i32 = @intCast(msg.wParam);
            for (self.global_hotkeys.items) |hk| {
                if (hk.id != id) continue;
                // apprt.App is this win32 App, so `self` is the rt_app.
                self.core_app.performAllAction(self, hk.action) catch |err| {
                    log.warn("global hotkey action failed err={}", .{err});
                };
                break;
            }
            continue;
        }

        // Intercept keystrokes destined for popup edit controls so
        // Enter/Escape/Arrow keys can be handled by our code.
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);

            // Modal "Rename Window" dialog: Enter/Escape/Tab are handled
            // by our code; every other key reaches the native controls
            // via Translate/Dispatch below. Checked first and exclusive —
            // the Surface-cast intercepts below must never run for dialog
            // children (their parent's GWLP_USERDATA is not a Surface),
            // and no global keybind bubbles out of a modal dialog.
            if (self.renameDialogOwning(msg.hwnd.?)) |dlg| {
                if (dlg.handleKey(vk)) continue :loop;
            } else if (self.bannerDialogOwning(msg.hwnd.?)) |dlg| {
                // Modal "Set Pane Banner" editor (T35): Escape/Tab and
                // Ctrl+Enter handled by our code; plain Enter falls through
                // to the multi-line edit as a newline. Exclusive, same
                // reasoning as the rename dialog above.
                if (dlg.handleKey(vk)) continue :loop;
            } else if (self.machineChooserOwning(msg.hwnd.?)) |chooser| {
                // Modal machine chooser: Enter/Escape/Tab/Up/Down handled by
                // our code (typing falls through to the filter EDIT). Like the
                // rename dialog, exclusive — its children must never reach the
                // Surface-cast intercepts (their parent is a *MachineChooser).
                if (chooser.handleKey(vk)) continue :loop;
            } else {
                // Check if this edit is a tab rename edit
                if (vk == w32.VK_RETURN or vk == w32.VK_ESCAPE) {
                    for (self.windows.items) |win| {
                        if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                            if (vk == w32.VK_RETURN) {
                                win.finishTabRename();
                            } else {
                                win.cancelTabRename();
                            }
                            continue :loop;
                        }
                    }
                }

                // Find the parent surface of this edit control
                if (surfaceParentOf(msg.hwnd.?)) |surface| {
                    if (surface.search_active and surface.search_edit == msg.hwnd) {
                        if (surface.handleSearchKey(vk)) continue;
                    }
                    if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                        if (surface.handlePaletteKey(vk)) continue;
                    }
                }

                // Bubble global keybindings from popup edit controls (tab
                // rename, command palette, search) up to the surface so that
                // e.g. `Ctrl+Shift+P` while renaming actually toggles the
                // palette instead of being eaten by the Edit. Excludes
                // Ctrl-only A/C/V/X/Y/Z so standard text-edit shortcuts keep
                // working inside the popup.
                const ctrl_held = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
                const shift_held = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
                const route_key = ctrl_held and (shift_held or !isEditShortcutVk(vk));
                if (route_key) {
                    const target_surface: ?*Surface = blk: {
                        // Tab rename edit lives on the Window, not a surface.
                        // Commit (not cancel) — matches standard Win32 inline
                        // rename convention (Explorer, Edge): any action that
                        // takes focus away saves the typed title.
                        for (self.windows.items) |win| {
                            if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                                win.finishTabRename();
                                break :blk win.getActiveSurface();
                            }
                        }
                        // Palette/search edits are children of a surface HWND.
                        const surface = surfaceParentOf(msg.hwnd.?) orelse break :blk null;
                        if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                            surface.setCommandPaletteActive(false);
                            break :blk surface;
                        }
                        if (surface.search_active and surface.search_edit == msg.hwnd) {
                            surface.setSearchActive(false, &[_:0]u8{});
                            break :blk surface;
                        }
                        break :blk null;
                    };
                    if (target_surface) |s| {
                        s.handleKeyEvent(msg.wParam, msg.lParam, .press);
                        continue :loop;
                    }
                }
            }
        }

        // Skip TranslateMessage for keyboard events on terminal surface
        // windows: handleKeyEvent (and sendWin32InputEvent in Win32 input
        // mode) calls ToUnicode directly, and TranslateMessage's internal
        // ToUnicodeEx mutates the same per-queue dead-key state — racing
        // it broke dead-key composition on ABNT2 (`~`+`a` → `~a`). Edit
        // controls (search, palette, tab rename) still need it.
        const skip_translate = switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP => blk: {
                // Keys claimed by the IME arrive as VK_PROCESSKEY and MUST
                // go through TranslateMessage: that is what forwards them to
                // the IME (ImmTranslateMessage) to generate the
                // WM_IME_STARTCOMPOSITION/WM_IME_COMPOSITION messages and
                // drive the candidate window. Skipping it made CJK input
                // dead. This does not disturb the ToUnicode dead-key state:
                // handleKeyEvent never calls ToUnicode for VK_PROCESSKEY.
                if (msg.wParam == w32.VK_PROCESSKEY) break :blk false;

                // VK_PACKET (SendInput KEYEVENTF_UNICODE: screen readers,
                // on-screen keyboards, automation) MUST also be translated:
                // TranslateMessage is the only thing that turns the packet
                // into the WM_CHAR carrying the injected character —
                // handleKeyEvent deliberately ignores VK_PACKET (T64).
                // Safe for the dead-key state: a packet bypasses layout
                // translation entirely.
                if (msg.wParam == w32.VK_PACKET) break :blk false;

                const h = msg.hwnd orelse break :blk false;
                const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
                break :blk atom != 0 and atom == self.terminal_class_atom;
            },
            else => false,
        };
        if (!skip_translate) _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.stopQuitTimer();

    if (self.update_latest_ver) |v| {
        self.core_app.alloc.free(v);
        self.update_latest_ver = null;
    }

    // Unregister all global hotkeys.
    for (self.global_hotkeys.items) |hk| _ = w32.UnregisterHotKey(null, hk.id);
    self.global_hotkeys.deinit(self.core_app.alloc);

    // Release the taskbar COM object if we created one.
    if (self.taskbar) |tb| {
        tb.Release();
        self.taskbar = null;
    }

    // Destroy quick terminal if active.
    if (self.quick_terminal) |qt| {
        qt.deinit();
        self.quick_terminal = null;
    }

    // Stop the IPC listener while msg_hwnd is still alive (a request could
    // be mid-marshal; deinit joins the listener thread).
    if (self.ipc_server) |*server| {
        server.deinit();
        self.ipc_server = null;
    }

    if (self.msg_hwnd) |hwnd| {
        // Clear GWLP_USERDATA before destroying so msgWndProc sees
        // userdata=0 and falls through to DefWindowProc for any
        // messages during destruction (e.g. WM_DESTROY).
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }

    // Deinit and free all Window containers.
    const alloc = self.core_app.alloc;
    for (self.windows.items) |window| {
        window.deinit();
        alloc.destroy(window);
    }
    self.windows.deinit(alloc);

    // Free the IPC target registry (keys are owned).
    self.ipc_registry.deinit(alloc);

    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }

    if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
        self.msg_class_atom = 0;
    }
    if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
        self.terminal_class_atom = 0;
    }
    if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
        self.class_atom = 0;
    }

    self.config.deinit();
}

/// Wake up the message loop from any thread by posting a message
/// to the message-only window. Coalesced: if a wakeup is already queued
/// and undelivered, this is a no-op (see `wakeup_pending`).
pub fn wakeup(self: *App) void {
    if (self.wakeup_pending.swap(true, .acq_rel)) return;
    if (self.msg_hwnd) |hwnd| {
        if (w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0) == 0) {
            // Queue full or window gone: clear so a later wakeup retries
            // instead of the flag wedging shut forever.
            self.wakeup_pending.store(false, .release);
        }
    } else {
        self.wakeup_pending.store(false, .release);
    }
}

/// Register `target` under `name`. See IpcRegistry.register.
pub fn ipcRegister(self: *App, name: []const u8, target: IpcTarget) Allocator.Error!void {
    return self.ipc_registry.register(self.core_app.alloc, self.windows.items, name, target);
}

/// Look up a live target by name. See IpcRegistry.lookup.
pub fn ipcLookup(self: *App, name: []const u8) ?IpcTarget {
    return self.ipc_registry.lookup(self.core_app.alloc, self.windows.items, name);
}

/// Reverse lookup: the registered name of a target, if any.
pub fn ipcNameOf(self: *App, target: IpcTarget) ?[]const u8 {
    return self.ipc_registry.nameOf(target);
}

/// Drop every registration pointing at `target`. See IpcRegistry.forget.
pub fn ipcForget(self: *App, target: IpcTarget) void {
    self.ipc_registry.forget(self.core_app.alloc, target);
}

/// Create, track, and populate a new Window (with its first tab). Shared by
/// the .new_window action and the IPC server.
pub fn createWindow(self: *App, opts: Window.InitOptions) !*Window {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, opts);
    errdefer window.deinit();
    try self.windows.append(alloc, window);
    errdefer _ = self.windows.pop();
    _ = try window.addTab();
    return window;
}

/// Options for opening a remote-machine window (the shared open path below).
/// All string values are REMOTE-native and forwarded verbatim in the agent
/// OPEN (never wrapped by the local shell table). Slices are borrowed for the
/// duration of the call — `openDialedWindow` copies what it retains.
pub const RemoteOpenOptions = struct {
    /// cwd ON THE REMOTE MACHINE, or null for the agent's default.
    working_directory: ?[]const u8 = null,
    /// Shell ON THE REMOTE MACHINE, or null for the agent's default.
    shell: ?[]const u8 = null,
    /// Command to run instead of an interactive shell, or null.
    command: ?[]const u8 = null,
    /// Register the new window under this IPC name for later targeting.
    ipc_name: ?[]const u8 = null,
    /// Title override to apply to the new window, or null.
    title: ?[]const u8 = null,
    /// Bring the new window to the foreground (false ⇒ show inactive).
    activate: bool = true,
    /// The machine identity being dialed (T68): recorded on the window so
    /// "New Window" on it can re-dial the same agent. Strings borrowed;
    /// `Window.setRemoteMachine` dupes.
    machine: ?Window.RemoteMachine = null,
};

pub const RemoteOpenError = error{ DialFailed, CreateFailed } || Allocator.Error;

/// The ONE remote-window open tail (T22c decision 6): build the `.remote`
/// surface overrides from a completed dial, create the window, hand it
/// ownership of the transport, and apply title/activation. Shared by the
/// `+new-remote-window` IPC verb (both TCP and relay) and the machine chooser.
///
/// Takes ownership of `dialed`: on success the returned window owns it (torn
/// down in `Window.deinit`); on `CreateFailed` this frees it before returning,
/// so callers never double-free.
pub fn openDialedWindow(
    self: *App,
    dialed: Window.RemoteDialed,
    opts: RemoteOpenOptions,
) error{ CreateFailed, OutOfMemory }!*Window {
    const conn = switch (dialed) {
        inline else => |d| d.conn,
    };

    const overrides: Surface.Overrides = .{
        .remote = .{
            .connection = conn,
            .working_directory = opts.working_directory,
            .shell = opts.shell,
            .command = opts.command,
        },
    };

    const window = self.createWindow(.{
        .surface_overrides = &overrides,
        .ipc_name = opts.ipc_name,
    }) catch |err| {
        log.warn("remote window: create window failed err={}", .{err});
        dialed.deinitDestroy(self.core_app.alloc);
        return error.CreateFailed;
    };
    window.remote_dialed = dialed;
    if (opts.machine) |machine| {
        window.setRemoteMachine(machine) catch |err| {
            // Non-fatal: the window works; only T68 "New Window inherits the
            // remote host" degrades to a local window for this one.
            log.warn("remote window: recording machine identity failed err={}", .{err});
        };
    }

    if (opts.title) |title| window.setTitleOverride(title);
    if (!opts.activate) {
        if (window.hwnd) |hwnd| _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    } else if (window.hwnd) |hwnd| {
        _ = w32.SetForegroundWindow(hwnd);
    }
    return window;
}

/// Dial an enrolled relay device and open a window on it. The relay half of
/// the shared open path (T22c): both the `--relay`/`--device` IPC verb and the
/// machine chooser route through here so there is ONE relay-open path. The
/// caller resolves the bearer `token` (so it can shape its own no-credential
/// UX) and maps the two failure modes onto its own messaging.
pub fn openRelayWindow(
    self: *App,
    relay_base: []const u8,
    device: []const u8,
    token: []const u8,
    opts: RemoteOpenOptions,
) RemoteOpenError!*Window {
    const alloc = self.core_app.alloc;
    const dialed = try alloc.create(relay_dial.Dialed);
    dialed.* = relay_dial.dial(alloc, relay_base, device, token, .raw) catch |err| {
        log.warn(
            "remote window: relay dial failed relay={s} device={s} err={}",
            .{ relay_base, device, err },
        );
        alloc.destroy(dialed);
        return error.DialFailed;
    };
    var opts_with_machine = opts;
    opts_with_machine.machine = .{ .relay = .{ .base = relay_base, .device = device } };
    return self.openDialedWindow(.{ .relay = dialed }, opts_with_machine);
}

/// T68: the "New Window" action on a focused REMOTE window — dial the same
/// machine again (a fresh connection; win32 windows each own their
/// transport) and open the new window with the parent pane's command + cwd
/// inherited (Mac newWindowInheritingRemote semantics; the cwd is a bounded
/// GET_CWD RPC on the parent's still-live connection). Relay windows resolve
/// a fresh bearer token (account tier, then env) — signed out ⇒ error, like
/// the Mac's WP-B2 rule.
pub fn openRemoteWindowFrom(
    self: *App,
    parent: *Window,
    /// Explicit REMOTE-native values that beat inheritance (the IPC
    /// `+new-window --from-focused` flags); all-null for the keybind path.
    explicit: struct {
        working_directory: ?[]const u8 = null,
        shell: ?[]const u8 = null,
        command: ?[]const u8 = null,
    },
) RemoteOpenError!*Window {
    const machine = parent.remote_machine orelse return error.DialFailed;

    var arena_state = std.heap.ArenaAllocator.init(self.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Inheritance snapshot from the parent's active pane (cheap, lock-free),
    // then the bounded cwd RPC on the parent's existing connection. Explicit
    // values suppress the corresponding inheritance (Mac rule).
    var command: ?[]const u8 = explicit.command;
    var cwd: ?[]const u8 = explicit.working_directory;
    if (parent.tab_count > 0) {
        const pane = parent.tab_active_surface[parent.active_tab];
        if (command == null) command = pane.core_surface.remoteCommand();
        if (cwd == null) {
            if (parent.remote_dialed) |dialed| {
                if (pane.core_surface.remoteSessionId()) |sid| {
                    if (dialed.conn().queryCwdTimeout(
                        sid,
                        1500 * std.time.ns_per_ms,
                    )) |path| {
                        cwd = try arena.dupe(u8, path);
                        self.core_app.alloc.free(path);
                    } else |err| {
                        log.debug("new window remote inherit: cwd query failed err={}", .{err});
                    }
                }
            }
        }
    }

    const opts: RemoteOpenOptions = .{
        .working_directory = cwd,
        .shell = explicit.shell,
        .command = command,
        .machine = machine,
    };

    switch (machine) {
        .tcp => |t| {
            const alloc = self.core_app.alloc;
            const dialed = try alloc.create(tcp_dial.Dialed);
            dialed.* = tcp_dial.dial(alloc, t.host, t.port, .raw) catch |err| {
                log.warn(
                    "new window remote inherit: dial failed host={s} port={d} err={}",
                    .{ t.host, t.port, err },
                );
                alloc.destroy(dialed);
                return error.DialFailed;
            };
            return self.openDialedWindow(.{ .tcp = dialed }, opts);
        },
        .relay => |r| {
            const token = IpcHandlers.resolveToken(arena) orelse {
                log.warn("new window remote inherit: no relay credential (signed out)", .{});
                return error.DialFailed;
            };
            return self.openRelayWindow(r.base, r.device, token, opts);
        },
    }
}

/// Show the T68 "couldn't reach the machine" dialog (T80 dark ConfirmDialog,
/// OK-only) over `owner` after a failed inheriting re-dial.
fn showRemoteOpenFailed(self: *App, owner: *Window) void {
    const label: [:0]const u16 = switch (owner.remote_machine orelse return) {
        .tcp => std.unicode.utf8ToUtf16LeStringLiteral(
            "Couldn't open a new window on the remote machine.\nIs its agent still running?",
        ),
        .relay => std.unicode.utf8ToUtf16LeStringLiteral(
            "Couldn't open a new window on the remote machine.\nIs its agent still running (and are you signed in)?",
        ),
    };
    const refocus: ?w32.HWND = if (owner.getActiveSurface()) |s| s.hwnd else null;
    _ = ConfirmDialog.show(self, owner.hwnd, owner.scale, refocus, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty"),
        .text = label,
        .style = .ok_only,
        .icon = .warning,
    });
}

/// The next auto-generated window name (`window-N`). Caller owns the slice.
pub fn ipcNextWindowName(self: *App) Allocator.Error![]u8 {
    return self.ipc_registry.nextWindowName(self.core_app.alloc);
}

/// IPC client: runs in a CLI process (`ghoztty +new-window`, `+split`, ...)
/// and sends the action to the running instance's named pipe. The server
/// side lives in the pipe listener owned by this App.
///
/// `+new-window` with no running instance auto-launches one: spawn our own
/// exe detached and retry the send with backoff until the new instance's
/// pipe server answers (parity with the Mac flow).
pub fn performIpc(
    alloc: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    return internal_os.ipc_client.sendAction(
        alloc,
        comptime action.wireName(),
        value.arguments,
    ) catch |err| switch (err) {
        error.NoRunningInstance => switch (comptime action) {
            .new_window => {
                try autoLaunchInstance(alloc);
                // The new instance needs to create its window and bind the
                // pipe; a cold debug start on a busy box can take a while.
                var attempt: usize = 0;
                while (true) : (attempt += 1) {
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    return internal_os.ipc_client.sendAction(
                        alloc,
                        comptime action.wireName(),
                        value.arguments,
                    ) catch |retry_err| switch (retry_err) {
                        error.NoRunningInstance => {
                            if (attempt < 20) continue;
                            return error.NoRunningInstance;
                        },
                        else => return retry_err,
                    };
                }
            },
            else => return err,
        },
        else => return err,
    };
}

/// Spawn a detached GUI instance of our own executable. Raw CreateProcessW
/// with bInheritHandles=FALSE: std.process.Child inherits handles, and a
/// GUI that inherits the CLI's redirected stdout/stderr keeps the caller's
/// pipes open — any script capturing `ghoztty +new-window` output would
/// block until the GUI exits.
fn autoLaunchInstance(alloc: Allocator) apprt.ipc.Errors!void {
    _ = alloc;
    const windows = std.os.windows;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.selfExePath(&exe_buf) catch return error.IPCFailed;

    // Quoted, mutable (CreateProcessW may rewrite lpCommandLine), NUL-
    // terminated wide command line.
    var cmd_utf8_buf: [std.fs.max_path_bytes + 2]u8 = undefined;
    const cmd_utf8 = std.fmt.bufPrint(&cmd_utf8_buf, "\"{s}\"", .{exe}) catch
        return error.IPCFailed;
    var cmd_w: [std.fs.max_path_bytes + 3]u16 = undefined;
    const cmd_len = std.unicode.utf8ToUtf16Le(cmd_w[0 .. cmd_w.len - 1], cmd_utf8) catch
        return error.IPCFailed;
    cmd_w[cmd_len] = 0;

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w),
        null,
        null,
        windows.FALSE, // no handle inheritance (see above)
        .{ .detached_process = true, .create_new_process_group = true },
        null,
        null,
        &si,
        &pi,
    ) == 0) return error.IPCFailed;
    windows.CloseHandle(pi.hProcess);
    windows.CloseHandle(pi.hThread);
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .new_window => {
            // T68: New Window on a focused REMOTE window opens on the SAME
            // machine (fresh dial, inherited command/cwd — the Mac
            // newWindowInheritingRemote analog). A failed re-dial shows an
            // error dialog instead of silently opening a local window the
            // user would mistake for the remote one.
            const parent_window: ?*Window = switch (target) {
                .app => null,
                .surface => |cs| cs.rt_surface.parent_window,
            };
            if (parent_window) |pw| {
                if (pw.remote_machine != null) {
                    _ = self.openRemoteWindowFrom(pw, .{}) catch |err| {
                        log.warn("new window on remote parent failed err={}", .{err});
                        self.showRemoteOpenFailed(pw);
                    };
                    return true;
                }
            }

            // Inherit opacity-toggle state from the parent window: if the
            // user toggled it to opaque via toggle_background_opacity, the
            // new window should start opaque too. Mirrors macOS behavior
            // from upstream e5c31e8b3 (#11583).
            const force_opaque: bool = switch (target) {
                .app => false,
                .surface => |cs| blk: {
                    if (self.config.@"background-opacity" >= 1.0) break :blk false;
                    const h = cs.rt_surface.parent_window.hwnd orelse break :blk false;
                    const ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                    break :blk (ex & w32.WS_EX_LAYERED) == 0;
                },
            };

            _ = self.createWindow(.{ .force_opaque = force_opaque }) catch |err| {
                log.err("failed to create new window err={}", .{err});
            };
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    rt_surface.setTitle(value.title);
                },
            }
            return true;
        },

        .ring_bell => {
            // Audio bell.
            _ = w32.MessageBeep(0xFFFFFFFF);
            // Visual bell: flash the taskbar button if the window owning
            // this surface isn't currently the foreground window. Without
            // this, BEL on a backgrounded terminal is invisible.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                        if (w32.GetForegroundWindow() != win_hwnd) {
                            var fwi: w32.FLASHWINFO = .{
                                .cbSize = @sizeOf(w32.FLASHWINFO),
                                .hwnd = win_hwnd,
                                .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                .uCount = 2,
                                .dwTimeout = 0,
                            };
                            _ = w32.FlashWindowEx(&fwi);
                        }
                    }
                },
            }
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },

        .config_change => {
            // Update our stored config with the new one.
            if (value.config.clone(self.core_app.alloc)) |new_config| {
                self.config.deinit();
                self.config = new_config;

                // Recreate the background brush from the new config.
                if (self.bg_brush) |old_brush| {
                    _ = w32.DeleteObject(@ptrCast(old_brush));
                }
                const bg = new_config.background;
                self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

                // Refresh DWM chrome (dark/light, caption color) on
                // every live window so a config reload that changes
                // the background color updates the title bar.
                for (self.windows.items) |w| w.onConfigChange();

                // Keep USER menu dark mode in sync with the (possibly
                // changed) window-theme/background (T79).
                DarkMode.apply(
                    self.config.@"window-theme",
                    self.config.background,
                );

                // Re-register global hotkeys against the new keybinds.
                for (self.global_hotkeys.items) |hk| _ = w32.UnregisterHotKey(null, hk.id);
                self.global_hotkeys.clearRetainingCapacity();
                self.registerGlobalHotkey();

                // Update quick terminal config.
                if (self.quick_terminal) |qt| {
                    qt.onConfigChange(&self.config);
                }
            } else |err| {
                log.err("error updating app config err={}", .{err});
            }
            return true;
        },

        .toggle_fullscreen => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleFullscreen();
                },
            }
            return true;
        },

        .toggle_maximize => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |hwnd| {
                        if (w32.IsZoomed(hwnd) != 0) {
                            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        } else {
                            _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
                        }
                    }
                },
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // Close the entire window (all tabs), not just one tab.
                    // Confirm first if any tab still has a running process.
                    const win = core_surface.rt_surface.parent_window;
                    if (win.confirmCloseIfNeeded()) win.close();
                },
            }
            return true;
        },

        .open_config => {
            self.openConfigFile();
            return true;
        },

        .scrollbar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setScrollbar(value);
                },
            }
            return true;
        },

        .mouse_shape => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseShape(value);
                },
            }
            return true;
        },

        .open_url => {
            // Open a URL using ShellExecuteW — the native Windows way.
            // internal_os.open() uses std.process.Child which can hit
            // unreachable on Windows, so we use ShellExecuteW directly.
            var wbuf: [2048]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, value.url) catch return true;
            if (wlen < wbuf.len) {
                wbuf[wlen] = 0;
                _ = w32.ShellExecuteW(
                    null,
                    std.unicode.utf8ToUtf16LeStringLiteral("open"),
                    @ptrCast(&wbuf),
                    null,
                    null,
                    w32.SW_SHOW,
                );
            }
            return true;
        },

        .mouse_over_link => {
            // Show the hovered URL in a small status bubble at the bottom
            // of the surface (cursor shape is handled by mouse_shape).
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseOverLink(value.url);
                },
            }
            return true;
        },

        .start_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(true, value.needle);
                },
            }
            return true;
        },

        .end_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(false, "");
                },
            }
            return true;
        },

        .search_total => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchTotal(value.total);
                },
            }
            return true;
        },

        .search_selected => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchSelected(value.selected);
                },
            }
            return true;
        },

        .desktop_notification => {
            self.showDesktopNotification(target, value);
            return true;
        },

        .new_tab => {
            // Add a new tab to the parent window of the focused surface.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const parent = core_surface.rt_surface.parent_window;
                    _ = parent.addTab() catch |err| {
                        log.err("failed to add new tab err={}", .{err});
                    };
                },
            }
            return true;
        },

        .close_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.closeTabMode(
                        value,
                        core_surface.rt_surface,
                    );
                },
            }
            return true;
        },

        .goto_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    _ = core_surface.rt_surface.parent_window.selectTab(value);
                },
            }
            return true;
        },

        .set_tab_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.onTabTitleChanged(
                        core_surface.rt_surface,
                        value.title,
                    );
                },
            }
            return true;
        },

        .move_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.moveTab(value.amount);
                },
            }
            return true;
        },

        .toggle_tab_overview => {
            return true;
        },

        .initial_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    // Store as the window's default size — reset_window_size
                    // returns to it, and font-size changes recompute it (T66).
                    win.default_client_size = .{
                        .width = value.width,
                        .height = value.height,
                    };
                    // Apply live only at window setup. Later re-sends (a
                    // font-zoom recompute, a new tab's surface init) are
                    // store-only on Mac and GTK: they must not resize a
                    // window the user is already working in.
                    if (!win.initial_size_applied) {
                        win.initial_size_applied = true;
                        win.setClientSize(win.default_client_size.?);
                    }
                },
            }
            return true;
        },

        .reload_config => {
            // Reload config and push to the core, which triggers
            // config_change actions on the target surface(s).
            //
            // The target matters (GTK apprt semantics): a SURFACE-scoped
            // soft reload (e.g. one surface's color-scheme conditional
            // state changed) must re-derive ONLY that surface. Re-deriving
            // every surface from the app config would wipe per-surface
            // config overrides (`+new-remote-window --command` sets
            // `wait-after-command` on its surface only — a wipe made the
            // window close underneath the user when the command exited).
            const alloc = self.core_app.alloc;
            if (value.soft) {
                // Soft reload: re-apply existing config (for conditional
                // state changes).
                switch (target) {
                    .app => self.core_app.updateConfig(self, &self.config) catch |err| {
                        log.err("soft config reload error: {}", .{err});
                    },
                    .surface => |core_surface| core_surface.updateConfig(&self.config) catch |err| {
                        log.err("soft surface config reload error: {}", .{err});
                    },
                }
            } else {
                // Hard reload: read config from disk
                var new_config = Config.load(alloc) catch |err| {
                    log.err("failed to reload config: {}", .{err});
                    return true;
                };
                defer new_config.deinit();
                self.core_app.updateConfig(self, &new_config) catch |err| {
                    log.err("config update error: {}", .{err});
                };

                // A hard reload re-parses the file: surface any
                // diagnostics like startup does (T69).
                const owner: ?*Window = switch (target) {
                    .surface => |core_surface| core_surface.rt_surface.parent_window,
                    .app => if (self.core_app.focusedSurface()) |s|
                        s.rt_surface.parent_window
                    else if (self.windows.items.len > 0)
                        self.windows.items[0]
                    else
                        null,
                };
                self.showConfigErrorsIfAny(&new_config, owner);
            }
            return true;
        },

        // Return false so the core draws its in-terminal child-exited UI
        // (press-any-key notice on clean exits, rich abnormal-exit
        // diagnostic with command + runtime). A modal MessageBox here both
        // suppressed that fallback (clean exit + wait-after-command showed
        // nothing) and blocked the GUI thread. A native non-modal banner
        // (Mac ChildExitedMessage parity) rides on the T35 pane-banner
        // infrastructure.
        .show_child_exited => return false,

        .toggle_window_decorations => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleWindowDecorations();
                },
            }
            return true;
        },

        .close_all_windows => {
            // Close every window (honoring confirm-close-surface), which is
            // distinct from `quit`: if a window's confirmation is declined,
            // the app stays up with that window. The quit timer starts on
            // its own once the last window is gone.
            //
            // Iterate over a snapshot: Window.close destroys the HWND, whose
            // WM_DESTROY handler removes it from self.windows.
            const alloc = self.core_app.alloc;
            const snapshot = alloc.dupe(*Window, self.windows.items) catch |err| {
                log.err("close_all_windows: allocation failed err={}", .{err});
                return true;
            };
            defer alloc.free(snapshot);
            for (snapshot) |window| {
                if (window.confirmCloseIfNeeded()) window.close();
            }
            return true;
        },

        .toggle_background_opacity => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        const current_ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                        if (current_ex & w32.WS_EX_LAYERED != 0) {
                            // Remove layered style (restore full opacity).
                            // Clearing WS_EX_LAYERED is not repainted
                            // automatically — without an explicit redraw the
                            // window stays translucent until the next
                            // repaint (e.g. a later focus change).
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex & ~w32.WS_EX_LAYERED);
                            _ = w32.RedrawWindow(
                                h,
                                null,
                                null,
                                w32.RDW_ERASE | w32.RDW_INVALIDATE | w32.RDW_FRAME | w32.RDW_ALLCHILDREN,
                            );
                        } else {
                            // Apply opacity from config
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
                            const alpha: u8 = @intFromFloat(@round(self.config.@"background-opacity" * 255.0));
                            _ = w32.SetLayeredWindowAttributes(h, 0, alpha, w32.LWA_ALPHA);
                        }
                    }
                },
            }
            return true;
        },

        .goto_window => {
            // With no tab bar, each "tab" is a window — goto_window
            // and goto_tab behave the same. Just acknowledge.
            return true;
        },

        .reset_window_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    // Return to the configured default (window-width/height
                    // × cell size, Mac returnToDefaultSize parity); 800×600
                    // only when the config never set one (T66).
                    win.setClientSize(win.default_client_size orelse
                        .{ .width = 800, .height = 600 });
                },
            }
            return true;
        },

        .copy_title_to_clipboard => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        // Get the window title and put it on the clipboard
                        var wbuf: [512]u16 = undefined;
                        const wlen: usize = @intCast(w32.GetWindowTextW(h, &wbuf, @intCast(wbuf.len)));
                        if (wlen > 0) {
                            var utf8_buf: [1024]u8 = undefined;
                            const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;
                            if (utf8_len > 0) {
                                // Copy to clipboard via the core surface
                                const alloc = self.core_app.alloc;
                                const text = alloc.dupeZ(u8, utf8_buf[0..utf8_len]) catch return true;
                                defer alloc.free(text);
                                core_surface.rt_surface.setClipboard(
                                    .standard,
                                    &.{.{ .mime = "text/plain", .data = text }},
                                    false,
                                ) catch {};
                            }
                        }
                    }
                },
            }
            return true;
        },

        .render => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.core_surface_ready) {
                        core_surface.rt_surface.core_surface.renderer_thread.wakeup.notify() catch {};
                    }
                },
            }
            return true;
        },

        // Acknowledge actions that don't need Win32-specific handling.
        // The core handles the logic; we just confirm receipt.
        .key_sequence,
        .key_table,
        .pwd,
        .cell_size,
        .readonly,
        // Platform-specific actions that don't apply on Windows:
        .secure_input, // macOS EnableSecureEventInput
        .undo, // macOS NSUndoManager
        .redo, // macOS NSUndoManager
        .show_gtk_inspector, // GTK-only
        .show_on_screen_keyboard, // GTK/mobile
        .inspector, // Not yet implemented (debug overlay)
        .render_inspector, // Not yet implemented (debug overlay)
        => return true,

        // Sticky pane banner (T35): OSC 7778 / `+set-banner` / the editor
        // dialog all funnel through the core surface to here.
        .pane_banner => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const text: []const u8 = value.text;
                core_surface.rt_surface.setPaneBanner(
                    if (text.len == 0) null else text,
                );
                return true;
            },
        },

        .prompt_banner => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                BannerDialog.open(core_surface.rt_surface);
                return true;
            },
        },

        .renderer_health => {
            // Surface a warning when the GPU renderer degrades so a frozen
            // display is explainable (macOS shows an in-window message).
            switch (value) {
                .healthy => {},
                .unhealthy => {
                    self.notif_desktop_surface_id = 0;
                    self.showDesktopNotificationText(
                        "Renderer Unhealthy",
                        "The GPU renderer is in an unhealthy state; terminal output may stop updating.",
                    );
                },
            }
            return true;
        },

        .progress_report => {
            // Reflect shell/TUI progress (OSC 9;4) on the taskbar button, the
            // Windows equivalent of the macOS Dock progress. Gated on
            // progress-style; the win32 apprt has no progress bar of its own.
            if (!self.config.@"progress-style") return true;
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const hwnd = core_surface.rt_surface.parent_window.hwnd orelse
                        return true;
                    const tb = self.taskbarList() orelse return true;
                    switch (value.state) {
                        .remove => tb.SetProgressState(hwnd, w32.TBPF_NOPROGRESS),
                        .indeterminate => tb.SetProgressState(hwnd, w32.TBPF_INDETERMINATE),
                        .set => {
                            tb.SetProgressState(hwnd, w32.TBPF_NORMAL);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                        .@"error" => {
                            tb.SetProgressState(hwnd, w32.TBPF_ERROR);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                        .pause => {
                            tb.SetProgressState(hwnd, w32.TBPF_PAUSED);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                    }
                },
            }
            return true;
        },

        .color_change => {
            // Foreground/cursor changes (OSC 10/12) retint the themed
            // scrollbar overlay, which is drawn by us rather than the
            // renderer (T28). Palette entries need no chrome update.
            switch (value.kind) {
                .foreground => {
                    const fg: terminal.color.RGB = .{ .r = value.r, .g = value.g, .b = value.b };
                    for (self.windows.items) |w| {
                        for (0..w.tab_count) |i| {
                            var it = w.tab_trees[i].iterator();
                            while (it.next()) |entry| {
                                if (entry.view.scrollbar) |sb| {
                                    sb.setTheme(self.config.background.toTerminalRGB(), fg);
                                }
                            }
                        }
                    }
                    return true;
                },
                .cursor => return true,
                .background => {},
                else => return true,
            }

            // Background: keep the class brush in sync so the resize flash
            // matches the terminal. The renderer paints the client area via
            // OpenGL; the brush only shows during resize before it catches
            // up. The scrollbar tracks the new background too.
            if (self.bg_brush) |old_brush| {
                _ = w32.DeleteObject(@ptrCast(old_brush));
            }
            self.bg_brush = w32.CreateSolidBrush(w32.RGB(value.r, value.g, value.b));
            {
                const bg: terminal.color.RGB = .{ .r = value.r, .g = value.g, .b = value.b };
                for (self.windows.items) |w| {
                    for (0..w.tab_count) |i| {
                        var it = w.tab_trees[i].iterator();
                        while (it.next()) |entry| {
                            if (entry.view.scrollbar) |sb| {
                                sb.setTheme(bg, self.config.foreground.toTerminalRGB());
                            }
                        }
                    }
                }
            }
            // SetClassLongPtrW propagates the new brush to all existing
            // windows of the class, not just future ones.
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (self.bg_brush) |b| {
                        _ = w32.SetClassLongPtrW(
                            h,
                            w32.GCLP_HBRBACKGROUND,
                            @intCast(@intFromPtr(b)),
                        );
                    }
                }
            }
            return true;
        },

        .size_limit => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    win.min_track_w = @intCast(value.min_width);
                    win.min_track_h = @intCast(value.min_height);
                    win.max_track_w = @intCast(value.max_width);
                    win.max_track_h = @intCast(value.max_height);
                },
            }
            return true;
        },

        .toggle_visibility => {
            // Hide all visible top-level Ghostty windows; if any are
            // already hidden, show + restore them. Equivalent to macOS
            // NSApp hide / show.
            var any_visible = false;
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (w32.IsWindowVisible_(h) != 0) {
                        any_visible = true;
                        break;
                    }
                }
            }
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (any_visible) {
                        _ = w32.ShowWindow(h, w32.SW_HIDE);
                    } else {
                        _ = w32.ShowWindow(h, w32.SW_SHOWNOACTIVATE);
                    }
                }
            }
            // The quick terminal manages its own visibility separately.
            return true;
        },

        .float_window => {
            // Toggle WS_EX_TOPMOST so the window stays above non-topmost
            // windows. Equivalent to macOS NSWindow.level = .floating.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return true;
                    const ex = w32.GetWindowLongPtrW(win_hwnd, w32.GWL_EXSTYLE);
                    const is_topmost = (ex & @as(isize, w32.WS_EX_TOPMOST)) != 0;
                    const want: bool = switch (value) {
                        .on => true,
                        .off => false,
                        .toggle => !is_topmost,
                    };
                    if (want == is_topmost) return true;
                    const insert_after = if (want) w32.HWND_TOPMOST else w32.HWND_NOTOPMOST;
                    _ = w32.SetWindowPos(
                        win_hwnd,
                        insert_after,
                        0,
                        0,
                        0,
                        0,
                        w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE,
                    );
                },
            }
            return true;
        },

        .command_finished => {
            // The core emits this for every finished command; all gating is
            // apprt-side (config notify-on-command-finish*), matching the
            // GTK and macOS runtimes.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    switch (self.config.@"notify-on-command-finish") {
                        .never => return true,
                        .unfocused => if (core_surface.focused) return true,
                        .always => {},
                    }
                    if (value.duration.lte(self.config.@"notify-on-command-finish-after"))
                        return true;

                    const act = self.config.@"notify-on-command-finish-action";
                    if (act.bell) {
                        _ = w32.MessageBeep(0xFFFFFFFF);
                        // Flash the taskbar button when backgrounded so the
                        // bell is visible too.
                        if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                            if (w32.GetForegroundWindow() != win_hwnd) {
                                var fwi: w32.FLASHWINFO = .{
                                    .cbSize = @sizeOf(w32.FLASHWINFO),
                                    .hwnd = win_hwnd,
                                    .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                    .uCount = 3,
                                    .dwTimeout = 0,
                                };
                                _ = w32.FlashWindowEx(&fwi);
                            }
                        }
                    }
                    if (act.notify) {
                        const title: []const u8 = if (value.exit_code) |code|
                            (if (code == 0) "Command Succeeded" else "Command Failed")
                        else
                            "Command Finished";
                        var body_buf: [128]u8 = undefined;
                        const body: []const u8 = if (value.exit_code) |code|
                            std.fmt.bufPrint(
                                &body_buf,
                                "Command took {f} and exited with code {d}.",
                                .{ value.duration.round(std.time.ns_per_ms), code },
                            ) catch "Command finished."
                        else
                            std.fmt.bufPrint(
                                &body_buf,
                                "Command took {f}.",
                                .{value.duration.round(std.time.ns_per_ms)},
                            ) catch "Command finished.";
                        self.notif_desktop_surface_id = core_surface.id;
                        self.showDesktopNotificationText(title, body);
                    }
                },
            }
            return true;
        },

        .mouse_visibility => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const visible = value == .visible;
                    core_surface.rt_surface.mouse_visible = visible;
                    // Force the next WM_SETCURSOR to apply the new state
                    // by issuing SetCursor immediately if the cursor is
                    // currently in our client area.
                    if (!visible) {
                        _ = w32.SetCursor(null);
                    } else if (core_surface.rt_surface.current_cursor) |c| {
                        _ = w32.SetCursor(c);
                    }
                },
            }
            return true;
        },

        .present_terminal => {
            // Raise the window containing the target surface and select
            // its tab. Restores from minimized/iconic state if necessary.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    if (win.hwnd) |hwnd| {
                        // ShowWindow(SW_RESTORE) brings back from minimize.
                        _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        _ = w32.SetForegroundWindow(hwnd);
                        // Make sure the tab containing this surface is active.
                        if (win.findTabIndex(core_surface.rt_surface)) |idx| {
                            if (idx != win.active_tab) win.selectTabIndex(idx);
                        }
                        // Focus the surface's child HWND (deferred — T48).
                        if (core_surface.rt_surface.hwnd) |sh| {
                            deferSetFocus(sh);
                        }
                    }
                },
            }
            return true;
        },

        .new_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const dir: SplitTree(Surface).Split.Direction = switch (value) {
                        .left => .left,
                        .right => .right,
                        .up => .up,
                        .down => .down,
                    };
                    _ = core_surface.rt_surface.parent_window.newSplit(dir) catch |err| blk: {
                        log.err("failed to create split: {}", .{err});
                        break :blk null;
                    };
                },
            }
            return true;
        },

        .goto_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.gotoSplit(value);
                },
            }
            return true;
        },

        .resize_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.resizeSplit(value);
                },
            }
            return true;
        },

        .equalize_splits => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.equalizeSplits();
                },
            }
            return true;
        },

        .toggle_split_zoom => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.toggleSplitZoom();
                },
            }
            return true;
        },

        .prompt_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // T92: branch on the PromptTitle payload — the pane,
                    // tab, and window prompts edit different levels of
                    // the title model (window pin → tab title → pane
                    // title). All three open the T50-style dialog.
                    const rt_surface = core_surface.rt_surface;
                    const window = rt_surface.parent_window;
                    switch (value) {
                        .surface => window.promptPaneTitle(rt_surface),
                        .tab => window.promptTabTitle(rt_surface),
                        .window => window.promptRenameWindow(),
                    }
                },
            }
            return true;
        },

        .check_for_updates => {
            self.startUpdateCheck(.manual);
            return true;
        },

        .toggle_command_palette => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const active = core_surface.rt_surface.palette_active;
                    core_surface.rt_surface.setCommandPaletteActive(!active);
                },
            }
            return true;
        },

        .toggle_quick_terminal => {
            if (self.quick_terminal) |qt| {
                qt.toggle();
            } else {
                const qt = QuickTerminal.init(self) catch |err| {
                    log.err("failed to create quick terminal: {}", .{err});
                    return true;
                };
                self.quick_terminal = qt;
                qt.toggle();
            }
            return true;
        },

        // OSC 7777 / `+set-state`: per-pane activity state, surfaced as a
        // window-title suffix aggregated across panes (T14).
        .activity_state => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface = core_surface.rt_surface;
                surface.activity_state = value;
                surface.parent_window.updateWindowTitle();
                return true;
            },
        },

        // Swap the focused pane with a neighbor (fork feature, T18).
        .swap_split => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                core_surface.rt_surface.parent_window.swapSplit(value);
                return true;
            },
        },

        // Hero mode: focused pane full-size left, carousel right (fork
        // feature, T19).
        .toggle_hero_mode => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                core_surface.rt_surface.parent_window.toggleHeroMode();
                return true;
            },
        },
    }
}

/// Returns the open "Rename Window" dialog owning the given HWND (the
/// dialog itself or one of its controls), if any. Used by the message
/// loop to route dialog keys and to keep dialog children away from the
/// Surface-cast popup-edit intercepts.
/// Returns the open "Set Pane Banner" editor owning the given HWND (the
/// dialog itself or one of its controls), if any. Same routing job as
/// renameDialogOwning (T35).
fn bannerDialogOwning(self: *App, hwnd: w32.HWND) ?*BannerDialog {
    for (self.windows.items) |win| {
        if (win.banner_dialog) |dlg| {
            if (dlg.ownsHwnd(hwnd)) return dlg;
        }
    }
    return null;
}

fn renameDialogOwning(self: *App, hwnd: w32.HWND) ?*RenameDialog {
    for (self.windows.items) |win| {
        if (win.rename_dialog) |dlg| {
            if (dlg.ownsHwnd(hwnd)) return dlg;
        }
    }
    return null;
}

/// Returns the open machine chooser owning the given HWND (the chooser itself
/// or one of its controls), if any. Used by the message loop to route chooser
/// keys and keep its children away from the Surface-cast popup-edit intercepts.
fn machineChooserOwning(self: *App, hwnd: w32.HWND) ?*MachineChooser {
    for (self.windows.items) |win| {
        if (win.machine_chooser) |chooser| {
            if (chooser.ownsHwnd(hwnd)) return chooser;
        }
    }
    return null;
}

/// If `child`'s parent is a terminal surface HWND (TERMINAL_CLASS_NAME),
/// return that surface. The popup-edit keystroke intercepts in run() MUST
/// use this rather than casting the parent's GWLP_USERDATA directly: a
/// keystroke on the surface itself has the top-level GhozttyWindow as
/// parent, whose GWLP_USERDATA is a *Window — casting that to *Surface
/// read out-of-bounds garbage on every keypress (randomly eating keys or
/// crashing; found by the T65 close-on-keypress validation).
fn surfaceParentOf(child: w32.HWND) ?*Surface {
    const parent = w32.GetParent(child) orelse return null;
    var cls: [40]u16 = undefined;
    const n = w32.GetClassNameW(parent, &cls, cls.len);
    if (n <= 0) return null;
    if (!std.mem.eql(u16, cls[0..@intCast(n)], TERMINAL_CLASS_NAME)) return null;
    const userdata = w32.GetWindowLongPtrW(parent, w32.GWLP_USERDATA);
    if (userdata == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(userdata)));
}

/// Ctrl-modified VKs that should remain with the focused Edit control
/// rather than bubbling to the surface as a keybinding. Select-all,
/// copy, paste, cut, redo, undo.
fn isEditShortcutVk(vk: u16) bool {
    return switch (vk) {
        'A', 'C', 'V', 'X', 'Y', 'Z' => true,
        else => false,
    };
}

/// Register a system-wide hotkey for toggle_quick_terminal.
/// Scans keybinds for entries with the `global` flag.
/// Lazily create (and cache) the shell ITaskbarList3 used for taskbar-button
/// progress. Returns null if COM or the taskbar object is unavailable.
fn taskbarList(self: *App) ?*w32.ITaskbarList3 {
    if (self.taskbar) |tb| return tb;

    // COM must be initialized on this (the UI) thread before CoCreateInstance.
    // S_FALSE (already initialized) is fine; we only need it done once.
    if (!self.com_initialized) {
        _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
        self.com_initialized = true;
    }

    var ptr: ?*anyopaque = null;
    const hr = w32.CoCreateInstance(
        &w32.CLSID_TaskbarList,
        null,
        w32.CLSCTX_INPROC_SERVER,
        &w32.IID_ITaskbarList3,
        &ptr,
    );
    if (hr < 0 or ptr == null) return null;

    const tb: *w32.ITaskbarList3 = @ptrCast(@alignCast(ptr.?));
    _ = tb.HrInit();
    self.taskbar = tb;
    return tb;
}

fn registerGlobalHotkey(self: *App) void {
    const alloc = self.core_app.alloc;
    var next_id: i32 = 1;
    var it = self.config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leaf => |l| l,
            // Leader and chained bindings are not registered as global hotkeys.
            .leader, .leaf_chained => continue,
        };
        if (!leaf.flags.global) continue;

        const trigger = entry.key_ptr.*;

        // Convert Ghostty mods to Win32 mods.
        var mods: u32 = w32.MOD_NOREPEAT;
        if (trigger.mods.ctrl) mods |= w32.MOD_CONTROL;
        if (trigger.mods.alt) mods |= w32.MOD_ALT;
        if (trigger.mods.shift) mods |= w32.MOD_SHIFT;
        if (trigger.mods.super) mods |= w32.MOD_WIN;

        // Convert Ghostty key to Win32 VK.
        const vk: ?u32 = switch (trigger.key) {
            .physical => |phys| keyToVk(phys),
            .unicode => |cp| blk: {
                // For ASCII characters, VK code = uppercase char.
                if (cp >= 'a' and cp <= 'z') break :blk @as(u32, cp - 'a' + 'A');
                if (cp >= '0' and cp <= '9') break :blk @as(u32, cp);
                break :blk null;
            },
            else => null,
        };

        const vk_code = vk orelse {
            log.warn("unsupported key for global hotkey action={s}", .{@tagName(leaf.action)});
            continue;
        };

        const id = next_id;
        if (w32.RegisterHotKey(null, id, mods, vk_code) == 0) {
            log.warn("failed to register global hotkey (may be in use) action={s}", .{@tagName(leaf.action)});
            continue;
        }
        self.global_hotkeys.append(alloc, .{ .id = id, .action = leaf.action }) catch {
            _ = w32.UnregisterHotKey(null, id);
            continue;
        };
        next_id += 1;
        log.info("registered global hotkey id={} action={s}", .{ id, @tagName(leaf.action) });
    }
}

/// Map a Ghostty physical key to a Win32 virtual key code.
fn keyToVk(key: @import("../../input/key.zig").Key) ?u32 {
    return switch (key) {
        .key_a => 0x41,
        .key_b => 0x42,
        .key_c => 0x43,
        .key_d => 0x44,
        .key_e => 0x45,
        .key_f => 0x46,
        .key_g => 0x47,
        .key_h => 0x48,
        .key_i => 0x49,
        .key_j => 0x4A,
        .key_k => 0x4B,
        .key_l => 0x4C,
        .key_m => 0x4D,
        .key_n => 0x4E,
        .key_o => 0x4F,
        .key_p => 0x50,
        .key_q => 0x51,
        .key_r => 0x52,
        .key_s => 0x53,
        .key_t => 0x54,
        .key_u => 0x55,
        .key_v => 0x56,
        .key_w => 0x57,
        .key_x => 0x58,
        .key_y => 0x59,
        .key_z => 0x5A,
        .digit_0 => 0x30,
        .digit_1 => 0x31,
        .digit_2 => 0x32,
        .digit_3 => 0x33,
        .digit_4 => 0x34,
        .digit_5 => 0x35,
        .digit_6 => 0x36,
        .digit_7 => 0x37,
        .digit_8 => 0x38,
        .digit_9 => 0x39,
        .backquote => w32.VK_OEM_3,
        .minus => w32.VK_OEM_MINUS,
        .equal => w32.VK_OEM_PLUS,
        .bracket_left => w32.VK_OEM_4,
        .bracket_right => w32.VK_OEM_6,
        .backslash => w32.VK_OEM_5,
        .semicolon => w32.VK_OEM_1,
        .quote => w32.VK_OEM_7,
        .comma => w32.VK_OEM_COMMA,
        .period => w32.VK_OEM_PERIOD,
        .slash => w32.VK_OEM_2,
        .enter => w32.VK_RETURN,
        .tab => w32.VK_TAB,
        .space => w32.VK_SPACE,
        .backspace => w32.VK_BACK,
        .escape => w32.VK_ESCAPE,
        .f1 => w32.VK_F1,
        .f2 => w32.VK_F2,
        .f3 => w32.VK_F3,
        .f4 => w32.VK_F4,
        .f5 => w32.VK_F5,
        .f6 => w32.VK_F6,
        .f7 => w32.VK_F7,
        .f8 => w32.VK_F8,
        .f9 => w32.VK_F9,
        .f10 => w32.VK_F10,
        .f11 => w32.VK_F11,
        .f12 => w32.VK_F12,
        else => null,
    };
}

// -----------------------------------------------------------------------
// Update Checker
// -----------------------------------------------------------------------

/// GitHub releases-list API URL for this fork (newest-first). The update
/// check scans it for the newest `win-v*` tag (update_check.zig) — Windows
/// releases live beside the Mac `vX.Y.Z` releases in the same repo, so the
/// list endpoint is used instead of /latest (which points at the Mac
/// channel). Overridable via GHOZTTY_UPDATE_URL, which also force-enables
/// the check in non-channel builds so test/win32/update-check.ps1 can point
/// a plain Debug build at a local fake server.
const UPDATE_URL = "https://api.github.com/repos/dzearing/ghoztty/releases?per_page=30";

/// Custom message posted from the update thread to the message loop.
/// wparam = heap ptr to the newer version text, lparam = its length.
/// wparam == 0 carries manual-check feedback instead: lparam 0 = up to
/// date, 1 = check failed (only posted for user-initiated checks).
const WM_APP_UPDATE_AVAILABLE: u32 = w32.WM_APP + 2;

/// Tray-icon notification callback (uCallbackMessage). The wparam is
/// the tray icon's uID; lparam carries NIN_* events.
const WM_APP_TRAY: u32 = w32.WM_APP + 3;

/// User-facing GitHub releases page — the update-balloon click fallback
/// when no specific version is known.
const RELEASES_URL = "https://github.com/dzearing/ghoztty/releases";

/// Release page for a specific Windows build; the version text (e.g.
/// "1.4.1") is appended to form .../releases/tag/win-v1.4.1.
const RELEASE_TAG_URL_PREFIX = "https://github.com/dzearing/ghoztty/releases/tag/win-v";

/// Tray icon and timer IDs for notifications. Distinct IDs mean the
/// desktop and update balloons can coexist without one's auto-cleanup
/// removing the other's icon.
const NOTIF_DESKTOP_UID: u32 = 1;
const NOTIF_DESKTOP_TIMER_ID: usize = 2;
const NOTIF_UPDATE_UID: u32 = 2;
const NOTIF_UPDATE_TIMER_ID: usize = 3;

/// Minimum interval between update checks, in seconds. The check
/// timestamp is persisted in %LOCALAPPDATA%/ghostty/update_check_at.
const UPDATE_CHECK_INTERVAL_SECS: i64 = 60 * 60; // 1 hour

/// How an update check was requested. Automatic checks (app launch) are
/// gated and throttled; manual checks (`check_for_updates` action) always
/// run and report their outcome in a balloon.
const UpdateTrigger = enum { automatic, manual };

/// Start a background thread to check for updates (T24, notify-only: the
/// balloon links to the release page; nothing is downloaded or installed).
///
/// Automatic checks run ONLY in builds stamped with -Dwindows-update-check
/// (the MSI release pipeline sets it) so dev/portable/script-refreshed
/// builds never phone home or nag, honor `auto-update = off`, and are
/// throttled to one fetch per UPDATE_CHECK_INTERVAL_SECS. The
/// GHOZTTY_UPDATE_URL env override (acceptance-test hook) force-enables
/// the automatic check and bypasses the throttle. Manual checks skip all
/// gates: an explicit user action deserves an answer.
fn startUpdateCheck(self: *App, trigger: UpdateTrigger) void {
    if (trigger == .automatic) {
        const overridden = envUpdateUrlIsSet(self.core_app.alloc);
        if (!build_config.windows_update_check and !overridden) return;
        if (self.config.@"auto-update") |au| if (au == .off) {
            log.debug("update check disabled (auto-update = off)", .{});
            return;
        };
        if (!overridden and !self.shouldRunUpdateCheck()) {
            log.debug("skipping update check (last run within {d}s)", .{UPDATE_CHECK_INTERVAL_SECS});
            return;
        }
    }
    _ = std.Thread.spawn(.{}, updateCheckThread, .{ self, trigger }) catch |err| {
        log.warn("failed to start update check thread: {}", .{err});
    };
}

/// True if the GHOZTTY_UPDATE_URL test/debug override is present.
fn envUpdateUrlIsSet(alloc: Allocator) bool {
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_UPDATE_URL") catch return false;
    defer alloc.free(v);
    return v.len > 0;
}

/// Read the persisted "last checked at" timestamp; return true if
/// it's missing/stale. Updates the file with the current timestamp on
/// the way out so a successful return throttles the next call.
fn shouldRunUpdateCheck(self: *App) bool {
    const alloc = self.core_app.alloc;
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return true;
    defer alloc.free(dir);
    const path = std.fs.path.join(alloc, &.{ dir, "ghoztty", "update_check_at" }) catch return true;
    defer alloc.free(path);

    const now = std.time.timestamp();
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
        var buf: [32]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.fmt.parseInt(i64, text, 10)) |last| {
            if (now - last < UPDATE_CHECK_INTERVAL_SECS) return false;
        } else |_| {}
    } else |_| {}

    // Write (or create) the file with the current timestamp.
    if (std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return true)) |_| {} else |_| {}
    if (std.fs.cwd().createFile(path, .{ .truncate = true })) |f| {
        defer f.close();
        var ts_buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&ts_buf, "{d}", .{now}) catch return true;
        f.writeAll(s) catch {};
    } else |_| {}
    return true;
}

/// Background thread: fetch the releases list from GitHub, find the newest
/// win-v release, compare with the current version, post a message if
/// newer. Manual checks also post their up-to-date/failed outcome.
fn updateCheckThread(app: *App, trigger: UpdateTrigger) void {
    const alloc = app.core_app.alloc;
    const manual = trigger == .manual;

    const latest_ver: []u8 = fetchLatestWinVersion(alloc) catch |err| switch (err) {
        error.NoWinRelease => {
            // No Windows release published (or a fake feed without win-v
            // tags): nothing to offer, which for a manual check reads as
            // "you're up to date".
            log.info("update check: no win-v release found", .{});
            if (manual) postUpdateFeedback(app, 0);
            return;
        },
        else => {
            log.warn("update check failed: {}", .{err});
            if (manual) postUpdateFeedback(app, 1);
            return;
        },
    };

    // Compare against the binary's own version (from -Dversion-string,
    // which the MSI release pipeline stamps with the win-v tag's semver).
    const current_sv = build_config.version;
    if (!update_check.isNewer(current_sv, latest_ver)) {
        log.info("update check: up to date (current={s} latest=win-v{s})", .{
            build_config.version_string, latest_ver,
        });
        alloc.free(latest_ver);
        if (manual) postUpdateFeedback(app, 0);
        return;
    }
    log.info("update available: current={s} latest=win-v{s}", .{
        build_config.version_string, latest_ver,
    });

    const hwnd = app.msg_hwnd orelse {
        alloc.free(latest_ver);
        return;
    };

    // Hand ownership of the heap version text to the message handler via
    // wparam/lparam. This avoids a static-buffer race between this worker
    // thread writing the version and the message thread reading it.
    const wparam: usize = @intFromPtr(latest_ver.ptr);
    const lparam: isize = @intCast(latest_ver.len);
    if (w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, wparam, lparam) == 0) {
        // PostMessage failed (e.g., HWND already destroyed). Free the
        // buffer here since the handler will never run.
        alloc.free(latest_ver);
    }
}

/// Post manual-check feedback to the GUI thread: code 0 = up to date,
/// 1 = check failed (see WM_APP_UPDATE_AVAILABLE's encoding).
fn postUpdateFeedback(app: *App, code: isize) void {
    const hwnd = app.msg_hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, 0, code);
}

/// Show a notification balloon that an update is available. Remembers the
/// version so a balloon click opens that release's GitHub page. The caller
/// (message handler) still owns and frees `ver`.
fn showUpdateNotification(self: *App, ver: []const u8) void {
    if (ver.len == 0) return;
    log.info("showing update balloon for win-v{s}", .{ver});

    const alloc = self.core_app.alloc;
    if (self.update_latest_ver) |old| alloc.free(old);
    self.update_latest_ver = alloc.dupe(u8, ver) catch null;

    var body_utf8: [256]u8 = undefined;
    const body = std.fmt.bufPrint(
        &body_utf8,
        "Version {s} is available.\nClick to open the download page.",
        .{ver},
    ) catch return;
    self.showUpdateBalloon("Ghoztty Update Available", body);
}

/// Show manual-check feedback: code 0 = up to date, anything else =
/// check failed.
fn showUpdateFeedback(self: *App, code: isize) void {
    if (code == 0) {
        var body_utf8: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_utf8,
            "Ghoztty is up to date (version {s}).",
            .{build_config.version_string},
        ) catch return;
        self.showUpdateBalloon("Ghoztty", body);
    } else {
        self.showUpdateBalloon("Ghoztty", "Could not check for updates.\nClick to open the releases page.");
    }
}

/// Show a balloon on the update tray icon. A click is delivered as
/// WM_APP_TRAY (NOTIF_UPDATE_UID) → opens the release page. Title/body
/// must fit the NOTIFYICONDATAW limits (64/256 UTF-16 units incl. nul);
/// longer text is dropped rather than truncated mid-rune.
fn showUpdateBalloon(self: *App, title_utf8: []const u8, body_utf8: []const u8) void {
    const hwnd = self.msg_hwnd orelse return;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_UPDATE_UID;
    // NIF_MESSAGE registers our callback so a click on the balloon
    // is delivered as WM_APP_TRAY → opens the GitHub releases page.
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 10000;

    var title_utf16: [64]u16 = undefined; // NOTIFYICONDATAW.szInfoTitle
    if (title_utf8.len >= title_utf16.len) return;
    const tlen = std.unicode.utf8ToUtf16Le(&title_utf16, title_utf8) catch return;
    @memcpy(nid.szInfoTitle[0..tlen], title_utf16[0..tlen]);
    nid.szInfoTitle[tlen] = 0;

    var body_utf16: [256]u16 = undefined; // NOTIFYICONDATAW.szInfo
    if (body_utf8.len >= body_utf16.len) return;
    const wlen = std.unicode.utf8ToUtf16Le(&body_utf16, body_utf8) catch return;
    @memcpy(nid.szInfo[0..wlen], body_utf16[0..wlen]);
    nid.szInfo[wlen] = 0;

    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
    _ = w32.SetTimer(hwnd, NOTIF_UPDATE_TIMER_ID, 10000, null);
}

/// Response-size cap for the releases-list fetch. Release notes can be
/// large; 30 releases with long bodies stay well under this.
const UPDATE_RESPONSE_MAX: usize = 1024 * 1024;

/// Fetch the releases list from GitHub (or GHOZTTY_UPDATE_URL) and return
/// the newest win-v release's version text (e.g. "1.4.1"), caller-owned.
/// error.NoWinRelease if the feed has no win-v tag.
fn fetchLatestWinVersion(alloc: Allocator) ![]u8 {
    const url_owned: ?[]u8 = std.process.getEnvVarOwned(alloc, "GHOZTTY_UPDATE_URL") catch null;
    defer if (url_owned) |u| alloc.free(u);
    const url: []const u8 = if (url_owned) |u| (if (u.len > 0) u else UPDATE_URL) else UPDATE_URL;

    // file:// overrides are read directly (WinINet's InternetOpenUrlW
    // rejects them); this is the acceptance test's canned-feed path.
    if (std.mem.startsWith(u8, url, "file://")) {
        var path = url["file://".len..];
        if (path.len > 2 and path[0] == '/') path = path[1..]; // file:///C:/…
        const f = std.fs.openFileAbsolute(path, .{}) catch return error.ReadFailed;
        defer f.close();
        const data = f.readToEndAlloc(alloc, UPDATE_RESPONSE_MAX) catch return error.ReadFailed;
        defer alloc.free(data);
        const ver = update_check.findLatestWinVersion(data) orelse return error.NoWinRelease;
        return try alloc.dupe(u8, ver);
    }

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty-UpdateCheck/1.0");
    const inet = w32.InternetOpenW(agent, w32.INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0) orelse
        return error.InternetOpenFailed;
    defer _ = w32.InternetCloseHandle(inet);

    // Convert URL to UTF-16
    var url_buf: [2048]u16 = undefined;
    if (url.len >= url_buf.len) return error.UrlTooLong;
    const url_len = std.unicode.utf8ToUtf16Le(&url_buf, url) catch return error.UrlTooLong;
    url_buf[url_len] = 0;

    // INTERNET_FLAG_SECURE is intentionally omitted: the scheme decides
    // (https for the real channel; the test override serves plain http
    // from 127.0.0.1).
    const flags = w32.INTERNET_FLAG_NO_CACHE_WRITE | w32.INTERNET_FLAG_RELOAD;
    const conn = w32.InternetOpenUrlW(inet, @ptrCast(&url_buf), null, 0, flags, 0) orelse
        return error.InternetOpenUrlFailed;
    defer _ = w32.InternetCloseHandle(conn);

    // Read the whole response (heap; the releases list is far bigger than
    // the old single-release response).
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    while (body.items.len < UPDATE_RESPONSE_MAX) {
        try body.ensureUnusedCapacity(alloc, 16 * 1024);
        const dst = body.unusedCapacitySlice();
        var bytes_read: u32 = 0;
        if (w32.InternetReadFile(conn, dst.ptr, @intCast(@min(dst.len, UPDATE_RESPONSE_MAX - body.items.len)), &bytes_read) == 0) {
            return error.ReadFailed;
        }
        if (bytes_read == 0) break;
        body.items.len += bytes_read;
    }

    const ver = update_check.findLatestWinVersion(body.items) orelse
        return error.NoWinRelease;
    return try alloc.dupe(u8, ver);
}

/// Start the quit timer. Called when the last surface closes.
pub fn startQuitTimer(self: *App) void {
    // Cancel any existing timer first.
    self.stopQuitTimer();

    // Check if we should quit at all.
    if (!self.config.@"quit-after-last-window-closed") return;

    // If a delay is configured, start a Win32 timer.
    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        const ms = v.asMilliseconds();
        if (self.msg_hwnd) |hwnd| {
            _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, ms, null);
            self.quit_timer_state = .active;
        }
    } else {
        // No delay — quit immediately.
        self.quit_timer_state = .expired;
        self.quit_requested = true;
        w32.PostQuitMessage(0);
    }
}

/// Cancel the quit timer. Called when a new surface opens.
pub fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer_state) {
        .off => {},
        .expired => {
            self.quit_timer_state = .off;
            // Reset quit_requested. The WM_QUIT posted by startQuitTimer's
            // no-delay path can't be removed from the queue (it's a flag,
            // not a real message). Instead, the message loop checks
            // quit_requested when GetMessageW returns 0 — if false, it
            // ignores the spurious WM_QUIT and continues. This handles
            // the normal startup sequence: main_ghostty calls
            // startQuitTimer() before any surfaces exist, then run()
            // creates the first surface which triggers stopQuitTimer().
            self.quit_requested = false;
        },
        .active => {
            if (self.msg_hwnd) |hwnd| {
                _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            }
            self.quit_timer_state = .off;
        },
    }
}

/// Show a Windows balloon notification via Shell_NotifyIconW.
/// Creates a temporary tray icon, shows the balloon, then removes
/// the icon after a short delay.
fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    value: apprt.Action.Value(.desktop_notification),
) void {
    // Remember the originating surface so a balloon click can focus it.
    self.notif_desktop_surface_id = switch (target) {
        .app => 0,
        .surface => |core_surface| core_surface.id,
    };
    self.showDesktopNotificationText(value.title, value.body);
}

/// Show a desktop toast with the given title/body via the tray icon. The
/// balloon click is delivered as WM_APP_TRAY (NIF_MESSAGE) and focuses the
/// surface stored in notif_desktop_surface_id, mirroring macOS/GTK where
/// clicking a notification presents the originating surface.
fn showDesktopNotificationText(self: *App, title: []const u8, body: []const u8) void {
    const hwnd = self.msg_hwnd orelse return;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID;
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 5000; // 5 second timeout

    // Copy title (UTF-8 → UTF-16LE)
    const title_z = title;
    var title_len = std.unicode.utf8ToUtf16Le(&nid.szInfoTitle, title_z) catch 0;
    if (title_len >= nid.szInfoTitle.len) title_len = nid.szInfoTitle.len - 1;
    nid.szInfoTitle[title_len] = 0;

    // Copy body (UTF-8 → UTF-16LE)
    const body_z = body;
    var body_len = std.unicode.utf8ToUtf16Le(&nid.szInfo, body_z) catch 0;
    if (body_len >= nid.szInfo.len) body_len = nid.szInfo.len - 1;
    nid.szInfo[body_len] = 0;

    // Tooltip
    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    // Add the icon, show notification, then remove the icon.
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);

    // Schedule icon removal via a timer (distinct from the update
    // notification's timer so the two don't trample each other).
    _ = w32.SetTimer(hwnd, NOTIF_DESKTOP_TIMER_ID, 6000, null);
}

/// Notify the core app of a tick.
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}

/// Window procedure for terminal surface child HWNDs (GhosttyTerminal class).
/// GWLP_USERDATA stores a *Surface pointer.
fn surfaceWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const surface: *Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Guard: verify this is a surface window or one of its popups.
    const is_surface_window = surface.hwnd != null and surface.hwnd.? == hwnd;
    const is_search_popup = surface.search_hwnd != null and surface.search_hwnd.? == hwnd;
    const is_palette_popup = surface.palette_hwnd != null and surface.palette_hwnd.? == hwnd;
    if (!is_surface_window and !is_search_popup and !is_palette_popup)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_ENTERSIZEMOVE => {
            surface.in_live_resize = true;
            return 0;
        },

        w32.WM_EXITSIZEMOVE => {
            surface.in_live_resize = false;
            return 0;
        },

        w32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            surface.handleResize(width, height);
            return 0;
        },

        w32.WM_MOVE => {
            if (surface.scrollbar) |sb| _ = sb.repositionAndResize();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SHOWWINDOW => {
            if (surface.scrollbar) |sb| sb.setOwnerVisible(wparam != 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETTINGCHANGE => {
            if (surface.scrollbar) |sb| {
                if (sb.onSettingsChange()) {
                    // Re-flow the grid to accommodate a mode change.
                    const width: u32 = surface.width;
                    const height: u32 = surface.height;
                    const lp_size: isize = @intCast((@as(usize, height) << 16) | @as(usize, width));
                    _ = w32.PostMessageW(hwnd, w32.WM_SIZE, 0, lp_size);
                }
            }

            // Note: OS light/dark flips do NOT arrive here — a
            // WM_SETTINGCHANGE broadcast only reaches top-level windows.
            // The color-scheme report lives in Window.windowWndProc (T26).
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CLOSE => {
            // Posted by Surface.close() to defer destruction to the
            // message loop. This is the safe place to call closeSplitSurface
            // (outside of core_surface callbacks).
            surface.parent_window.closeSplitSurface(surface);
            return 0;
        },

        w32.WM_DESTROY => {
            // The child HWND is being destroyed (by Surface.deinit or
            // parent Window destruction). Clear state so deinit()
            // doesn't double-destroy. Lifecycle is managed by Window.
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            surface.hwnd = null;
            surface.core_surface_ready = false;
            return 0;
        },

        w32.WM_ERASEBKGND => {
            // Fill with the configured background color to prevent
            // a visible flash during resize. The OpenGL renderer will
            // overwrite the entire client area on the next frame.
            if (surface.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },

        w32.WM_PAINT => {
            if (is_palette_popup) {
                surface.paintPalette(hwnd);
                return 0;
            }
            // Validate the paint region to stop Windows from
            // sending more WM_PAINT messages, then wake the
            // renderer thread to redraw.
            _ = w32.ValidateRect(hwnd, null);
            if (surface.core_surface_ready) {
                surface.core_surface.renderer_thread.wakeup.notify() catch {};
            }
            return 0;
        },

        w32.WM_DPICHANGED => {
            surface.handleDpiChange();
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            surface.handleKeyEvent(wparam, lparam, .press);
            return 0;
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            surface.handleKeyEvent(wparam, lparam, .release);
            return 0;
        },

        w32.WM_SYSCHAR => {
            // TranslateMessage is skipped for terminal surface windows
            // (see App.run), so WM_SYSCHAR is never posted by it for our
            // windows. This handler guards against WM_SYSCHAR arriving via
            // SendInput, PostMessage, or other injection paths: forwarding
            // it to DefWindowProc would treat it as an unmatched menu
            // accelerator and ring MessageBeep. Consume it unconditionally.
            return 0;
        },

        w32.WM_DEADCHAR, w32.WM_SYSDEADCHAR => {
            // The message loop skips TranslateMessage for surface windows,
            // so WM_DEADCHAR is normally never posted for them. If one
            // arrives via another path (e.g. SendInput), drop it — dead
            // keys are composed via ToUnicode in handleKeyEvent.
            return 0;
        },

        w32.WM_CHAR => {
            // In Win32 Input Mode a WM_CHAR can only be INJECTED text
            // (T64): the run loop skips TranslateMessage for ordinary
            // surface keydowns (their Unicode goes in the WM_KEYDOWN's Uc
            // field instead), IME results are consumed whole in
            // WM_IME_COMPOSITION (never DefWindowProc'd, so no WM_IME_CHAR
            // duplicates), which leaves VK_PACKET translation and direct
            // WM_CHAR posts. Encode the injected character as a synthetic
            // win32-input sequence instead of dropping it.
            if (surface.isWin32InputMode()) {
                log.debug("injected WM_CHAR in win32-input mode uc={x}", .{wparam & 0xFFFF});
                surface.sendWin32CharEvent(@intCast(wparam & 0xFFFF));
                return 0;
            }

            // If handleKeyEvent already produced text via ToUnicode for
            // the preceding WM_KEYDOWN, suppress this WM_CHAR to avoid
            // double input. Otherwise, process it — the character came
            // from IME, SendInput Unicode (VK_PACKET), PostMessage, or
            // another source that didn't go through handleKeyEvent.
            if (surface.key_event_produced_text) {
                surface.key_event_produced_text = false;
                return 0;
            }
            surface.handleCharEvent(wparam);
            return 0;
        },

        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT. Without this,
            // DefWindowProc creates an oleacc AccWrap proxy for each surface
            // HWND. When focus moves between split panes (which are sibling
            // child HWNDs in our layout), oleacc destroys the outgoing
            // surface's AccWrap synchronously inside DefWindowProc; the
            // destructor re-enters our WindowProc via SetFocus, which fires
            // ImeSystemHandler -> oleacc!CreateClient -> COM marshaling that
            // waits for a reply this thread cannot pump (deep WindowProc
            // stack). Result: SleepConditionVariableSRW forever — the
            // ghost-hang dumps all bottom out exactly there.
            //
            // wezterm avoids this by being single-HWND (no cross-window
            // focus dance), so AccWraps that exist there are never
            // destroyed in this re-entrant pattern. Returning 0 here for
            // OBJID_CLIENT prevents AccWrap creation for our surface
            // windows, breaking the chain at the source. We don't expose
            // terminal-cell-level accessibility today anyway, so the only
            // thing this disables is the generic window-frame proxy that
            // screen readers would otherwise see.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_SETCONTEXT => {
            // The composition (preedit) is rendered inline in the terminal
            // by the core, so tell the system not to show the default
            // floating composition window. The IME candidate list is
            // unaffected and still anchors to ImmSetCompositionWindow.
            const cleared = lparam & ~w32.ISC_SHOWUICOMPOSITIONWINDOW;
            return w32.DefWindowProcW(hwnd, msg, wparam, cleared);
        },

        w32.WM_IME_STARTCOMPOSITION => {
            surface.handleImeStartComposition();
            // Consume: we draw the composition inline; no default window.
            return 0;
        },

        w32.WM_IME_COMPOSITION => {
            // Handles both intermediate preedit (GCS_COMPSTR, mirrored
            // inline) and the final result string (GCS_RESULTSTR, committed
            // to the terminal). Always consume so DefWindowProc doesn't
            // generate WM_IME_CHAR or draw a default composition window.
            _ = surface.handleImeComposition(lparam);
            return 0;
        },

        w32.WM_IME_ENDCOMPOSITION => {
            surface.handleImeEndComposition();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONDOWN => {
            if (is_palette_popup) {
                const y: i32 = @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
                const sc = surface.scale;
                const list_top: i32 = @intFromFloat(@round(Surface.PALETTE_LIST_TOP * sc));
                const item_height: i32 = @intFromFloat(@round(Surface.PALETTE_ITEM_HEIGHT * sc));
                if (y >= list_top) {
                    const clicked = @divTrunc(y - list_top, item_height);
                    if (clicked >= 0 and clicked < surface.palette_count) {
                        surface.palette_selected = @intCast(clicked);
                        surface.executePaletteSelection();
                    }
                }
                return 0;
            }
            // Take keyboard focus on click. WS_CHILD windows don't
            // auto-focus the way top-level windows do, so without this
            // an active sibling popup edit (tab rename, search, palette)
            // keeps focus and the click never commits/dismisses it.
            deferSetFocus(hwnd);
            surface.handleMouseButton(.left, .press, lparam);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            surface.handleMouseButton(.left, .release, lparam);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            deferSetFocus(hwnd);
            surface.handleMouseButton(.right, .press, lparam);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            surface.handleMouseButton(.right, .release, lparam);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            deferSetFocus(hwnd);
            surface.handleMouseButton(.middle, .press, lparam);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            surface.handleMouseButton(.middle, .release, lparam);
            return 0;
        },
        w32.WM_XBUTTONDOWN => {
            // X1 = back (button four), X2 = forward (button five). Deliver to
            // the terminal for mouse reporting instead of the shell nav.
            deferSetFocus(hwnd);
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .five else .four;
            surface.handleMouseButton(btn, .press, lparam);
            return 1; // TRUE: handled; suppresses the default WM_APPCOMMAND.
        },
        w32.WM_XBUTTONUP => {
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .five else .four;
            surface.handleMouseButton(btn, .release, lparam);
            return 1;
        },

        w32.WM_MOUSEMOVE => {
            surface.handleMouseMove(lparam);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            surface.handleMouseWheel(wparam, .vertical);
            return 0;
        },

        w32.WM_MOUSEHWHEEL => {
            surface.handleMouseWheel(wparam, .horizontal);
            return 0;
        },

        w32.WM_DROPFILES => {
            surface.handleDropFiles(wparam);
            return 0;
        },

        w32.WM_SETCURSOR => {
            // Only override the cursor in the client area. For non-client
            // areas (resize borders, title bar), let DefWindowProc handle it.
            const hit_test: u16 = @intCast(lparam & 0xFFFF);
            if (hit_test == w32.HTCLIENT and surface.handleSetCursor()) {
                return 1; // TRUE = we set the cursor
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == Surface.SEARCH_EDIT_ID and notification == w32.EN_CHANGE) {
                surface.handleSearchChange();
                return 0;
            }
            if (control_id == Surface.PALETTE_EDIT_ID and notification == w32.EN_CHANGE) {
                surface.handlePaletteChange();
                return 0;
            }
            // Auto-dismiss popups when the Edit loses focus (click outside,
            // Alt+Tab away). Matches standard popup UX (VS Code palette,
            // macOS Spotlight). The dismiss helpers clear *_active first,
            // so any re-entrant EN_KILLFOCUS during ShowWindow(SW_HIDE) /
            // SetFocus falls through these guards as a no-op.
            if (notification == w32.EN_KILLFOCUS) {
                if (control_id == Surface.PALETTE_EDIT_ID and surface.palette_active) {
                    surface.setCommandPaletteActive(false);
                    return 0;
                }
                if (control_id == Surface.SEARCH_EDIT_ID and surface.search_active) {
                    surface.setSearchActive(false, &[_:0]u8{});
                    return 0;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLOREDIT => {
            // Dark mode colors for search/palette edit controls
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, if (is_palette_popup) w32.RGB(30, 30, 30) else w32.RGB(45, 45, 45));
            if (is_palette_popup) {
                if (surface.palette_brush) |brush| {
                    return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
                }
            }
            if (surface.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLORSTATIC => {
            // Dark mode colors for the search match-count label.
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(160, 160, 160));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (surface.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_ACTIVATE => {
            // Dismiss command palette when it loses focus
            if (is_palette_popup) {
                const activate = @as(u16, @intCast(wparam & 0xFFFF));
                if (activate == 0) { // WA_INACTIVE
                    surface.setCommandPaletteActive(false);
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETFOCUS => {
            // Update the active surface for this tab when a split pane gains focus.
            const tab = surface.parent_window.active_tab;
            surface.parent_window.tab_active_surface[tab] = surface;
            // T92: the tab label / titlebar follow the focused pane's
            // title (no-op when the tab title is user-pinned or the
            // title is unchanged).
            surface.parent_window.refreshTabTitle(tab);
            surface.parent_window.heroOnSurfaceFocused(surface);
            // Dim the pane that lost the active slot, undim this one (T74).
            surface.parent_window.updateDimOverlays();
            surface.handleFocus(true);
            return 0;
        },
        w32.WM_KILLFOCUS => {
            surface.handleFocus(false);
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Window procedure for the message-only HWND (GhosttyMsg class).
/// GWLP_USERDATA stores an *App pointer.
fn msgWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));

    if (msg == WM_APP_WAKEUP) {
        // Clear BEFORE tick: a wakeup arriving during tick must post a new
        // message (its work might land after tick already drained).
        app.wakeup_pending.store(false, .release);
        app.tick();
        return 0;
    }

    if (msg == WM_APP_IPC) {
        // wparam = *IpcServer.Pending, owned by the listener thread which is
        // blocked waiting for the response.
        if (wparam != 0) {
            const pending: *IpcServer.Pending = @ptrFromInt(wparam);
            IpcServer.serveOnGuiThread(pending);
        }
        return 0;
    }

    if (msg == ClaudeIntegration.WM_APP_CLAUDE_PROMPT) {
        ClaudeIntegration.showFirstRunPrompt(app);
        return 0;
    }

    if (msg == ClaudeIntegration.WM_APP_CLAUDE_DONE) {
        // wparam = heap *Done owned by the handler.
        if (wparam != 0) {
            const done: *ClaudeIntegration.Done = @ptrFromInt(wparam);
            ClaudeIntegration.onDone(app, done);
        }
        return 0;
    }

    if (msg == WM_APP_UPDATE_AVAILABLE) {
        // wparam = heap pointer to the version string, lparam = length.
        // We own the buffer and must free it after use. wparam == 0 is
        // manual-check feedback (lparam 0 = up to date, 1 = failed).
        if (wparam != 0 and lparam > 0) {
            const ptr: [*]u8 = @ptrFromInt(wparam);
            const len: usize = @intCast(lparam);
            const ver = ptr[0..len];
            defer app.core_app.alloc.free(ver);
            app.showUpdateNotification(ver);
        } else if (wparam == 0) {
            app.showUpdateFeedback(lparam);
        }
        return 0;
    }

    if (msg == WM_APP_TRAY) {
        // wparam = uID, lparam = NIN_* event. We only act on
        // NIN_BALLOONUSERCLICK on the update notification, opening the
        // GitHub releases page in the user's default browser.
        const event: u32 = @intCast(lparam & 0xFFFF);
        if (wparam == NOTIF_DESKTOP_UID and event == w32.NIN_BALLOONUSERCLICK) {
            // Focus the surface that produced the notification (click-to-
            // focus, matching macOS/GTK).
            if (app.notif_desktop_surface_id != 0) {
                if (app.core_app.findSurfaceByID(app.notif_desktop_surface_id)) |surface| {
                    _ = app.performAction(
                        .{ .surface = surface },
                        .present_terminal,
                        {},
                    ) catch |err| {
                        log.warn("present_terminal from notification failed err={}", .{err});
                    };
                }
            }
            return 0;
        }
        if (wparam == NOTIF_UPDATE_UID and event == w32.NIN_BALLOONUSERCLICK) {
            // Open the specific win-v release page when a version is
            // known (update balloon); the releases list otherwise
            // (up-to-date / check-failed feedback balloons).
            var url_utf8_buf: [256]u8 = undefined;
            const url_utf8: []const u8 = if (app.update_latest_ver) |v|
                std.fmt.bufPrint(&url_utf8_buf, RELEASE_TAG_URL_PREFIX ++ "{s}", .{v}) catch RELEASES_URL
            else
                RELEASES_URL;
            var url_buf: [512]u16 = undefined;
            const url_len = std.unicode.utf8ToUtf16Le(&url_buf, url_utf8) catch return 0;
            url_buf[url_len] = 0;
            _ = w32.ShellExecuteW(
                null,
                std.unicode.utf8ToUtf16LeStringLiteral("open"),
                @ptrCast(&url_buf),
                null,
                null,
                w32.SW_SHOW,
            );
        }
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
        app.quit_timer_state = .expired;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }

    // Timer ID 3: quick terminal animation tick.
    if (msg == w32.WM_TIMER and wparam == QuickTerminal.ANIM_TIMER_ID) {
        if (app.quick_terminal) |qt| qt.onAnimationTick();
        return 0;
    }

    // Notification icon cleanup timers. Each notification kind has its
    // own (uID, timer-id) pair so an in-flight balloon isn't removed by
    // an unrelated timeout.
    if (msg == w32.WM_TIMER and
        (wparam == NOTIF_DESKTOP_TIMER_ID or wparam == NOTIF_UPDATE_TIMER_ID))
    {
        const uid: u32 = if (wparam == NOTIF_DESKTOP_TIMER_ID)
            NOTIF_DESKTOP_UID
        else
            NOTIF_UPDATE_UID;
        _ = w32.KillTimer(hwnd, wparam);
        var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = uid;
        _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
        return 0;
    }

    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
