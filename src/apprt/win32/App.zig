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
const SessionRoster = @import("SessionRoster.zig");
const ActivityMonitor = @import("ActivityMonitor.zig");
const RelayAccountRow = @import("RelayAccountRow.zig");
const RenameDialog = @import("RenameDialog.zig");
const BannerDialog = @import("BannerDialog.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const PaneView = @import("PaneView.zig");
const Surface = @import("Surface.zig");
const ViewerPane = @import("ViewerPane.zig");
const webview2 = @import("webview2.zig");
const Window = @import("Window.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const LocalAgent = @import("LocalAgent.zig");
const remote_connection = @import("../../remote/connection.zig");
const tab_color = @import("tab_color.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const update_check = @import("update_check.zig");
const session_layout = @import("session_layout.zig");
const layout_blobs = @import("layout_blobs.zig");
const restore_frame = @import("restore_frame.zig");
const agent_recovery = @import("agent_recovery.zig");
const agent_upgrade = @import("agent_upgrade.zig");
const host_defaults = @import("host_defaults.zig");
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

/// Posted to `msg_hwnd` when the shared local-agent connection's transport link
/// goes DOWN (T145). The observer that posts this runs on the connection's
/// reader thread under its `state_mutex`, so it may not touch GUI state or
/// re-enter `Connection` — it posts and returns, and the settle watch below
/// runs on the GUI thread. (WM_APP+9/+10 are RelayAccountRow / Window's open-menu.)
const WM_APP_AGENT_LINK_DOWN: u32 = w32.WM_APP + 11;

/// Posted to `msg_hwnd` to re-run the non-destructive agent-upgrade check
/// (T147) at a moment that is safe to be destructive: after the last persistent
/// window closed. Posted rather than called inline so the close that triggered
/// it has fully settled (the window is off `self.windows` but its teardown is
/// still unwinding) before we count what is live — the Mac trigger defers for
/// exactly the same reason.
const WM_APP_AGENT_UPGRADE_CHECK: u32 = w32.WM_APP + 12;

/// Ceiling on agent restarts spent chasing the bundled build in one app run
/// (T147). Two: one for the ordinary "the binary was swapped under us" case,
/// one spare for a restart that raced something, and no third because a third
/// means the restart is not the cure.
const max_agent_upgrade_attempts: u8 = 2;

/// Timer ID for the quit-after-last-window-closed delay.
const QUIT_TIMER_ID: usize = 1;

/// Timer ID (on `msg_hwnd`) for the debounced session-layout manifest write
/// (T89f). `markLayoutDirty` (re)arms it; a mutation storm collapses into one
/// write ~`LAYOUT_SYNC_DEBOUNCE_MS` after the last change. Distinct from the
/// notification/quit/quick-terminal timer ids (1–3).
const LAYOUT_SYNC_TIMER_ID: usize = 4;

/// Debounce window for the session-layout write (Mac `scheduleSync` uses the
/// same 250ms). Window-frame changes are already coalesced to drag-end by
/// `persistPlacement` (WM_EXITSIZEMOVE), so this mainly collapses the several
/// array shifts a single tab/split close produces.
const LAYOUT_SYNC_DEBOUNCE_MS: u32 = 250;

/// A fresh agent-backed pane publishes its session id asynchronously (after the
/// OPEN round-trips), so the first debounced capture can miss it. When that
/// happens the write re-arms after this interval, up to `MAX_RETRIES` times, so
/// a follow-up capture records the id — the win32 analog of the Mac
/// `syncAndCaptureSessionIDs` retry, bounded so a pane that never connects can't
/// re-arm forever (~40 × 400ms ≈ 16s ceiling).
const LAYOUT_SYNC_RETRY_MS: u32 = 400;
const LAYOUT_SYNC_MAX_RETRIES: u16 = 40;

/// Timer ID (on `msg_hwnd`) for the local-agent link settle watch (T145). Armed
/// only while a down link is being judged — there is no idle polling; the down
/// EDGE arrives as `WM_APP_AGENT_LINK_DOWN`.
const AGENT_WATCH_TIMER_ID: usize = 5;

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

/// Bounded retry counter for the session-layout write (T89f) while an
/// agent-backed pane hasn't published its session id yet (the OPEN reply is
/// async). Incremented each pending re-arm, reset to 0 once a capture finds
/// every agent-backed leaf resolved (or the ceiling is hit).
layout_sid_retries: u16 = 0,

/// What we last mirrored to the local agent's layout-blob store (T334), keyed
/// by manifest window id with the pushed blob's hash as the value. Keys are
/// owned by this map.
///
/// It exists to keep the push CHEAP and CONVERGENT: a sync re-pushes only the
/// windows whose bytes actually changed, and every key that is no longer in the
/// live topology is deleted — which is what makes a window CLOSE remove its
/// blob without a separate close hook, and what makes index-derived keys
/// (`win-0`, `win-1`) safe despite shifting when an earlier window closes.
pushed_layouts: std.StringHashMapUnmanaged(u64) = .empty,

/// The connection `pushed_layouts` describes. A reconnect (agent restart, link
/// recovery) means the peer's store is not the one we tracked, so the map is
/// dropped and the whole topology re-pushed rather than assumed present.
pushed_layouts_conn: ?*remote_connection.Connection = null,

/// The HINSTANCE for this module.
hinstance: w32.HINSTANCE,

/// Window class atoms from RegisterClassExW.
class_atom: u16 = 0,
terminal_class_atom: u16 = 0,
msg_class_atom: u16 = 0,
viewer_class_atom: u16 = 0,

/// The app-wide WebView2 host: one runtime probe, one shared
/// `ICoreWebView2Environment` for every viewer pane (T372/T373). Created
/// lazily — a session that never opens a viewer never starts a browser
/// process, and a box with no WebView2 runtime never notices this exists.
webview2_host: webview2.Host = undefined,

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

/// Find-or-spawn manager for the local session-persistence agent (T89d).
/// Owns the ONE shared connection every persistent window/tab/split rides
/// (mirrors the Mac `LocalAgentManager.sharedOwner`). Bounded + non-fatal:
/// see `LocalAgent.sharedConnection`.
local_agent: LocalAgent = undefined,

/// Deadline (ms, `milliTimestamp` scale) by which the shared local-agent link
/// must come back before its drop counts as real (T145). Non-null ⇒ a settle
/// watch is running and `AGENT_WATCH_TIMER_ID` is armed. Overlapping down edges
/// (`reconnecting → dead`) share ONE window: the first one arms it and the rest
/// are ignored, matching the Mac's single `sharedLinkDropWatchOwner`.
agent_settle_deadline_ms: ?i64 = null,

/// True while `recoverLocalAgentInPlace` is running. Recovery closes and builds
/// surfaces, which re-enters the layout-sync and IPC paths; a link transition
/// arriving mid-rebuild must not start a second recovery on top of the first.
agent_recovering: bool = false,

/// Non-zero while a destructive agent refresh is tearing the app's terminals
/// down and rebuilding them (T229). The app deliberately has zero — or
/// half-built — windows in that window of time, and it must not read that as
/// "the user closed the last window" and quit itself out from under the rebuild
/// the confirmation dialog promised. A COUNT, not a flag, so a nested refresh
/// cannot clear the outer one's guard.
agent_refresh_depth: usize = 0,

/// True once the user has declined a destructive agent refresh in this app run
/// (T147). It suppresses further PROMPTS only — the silent idle refresh still
/// happens the next time no sessions are live, which is exactly what the
/// dialog promises. Per-run by design: the next launch asks again, because by
/// then the sessions in question are new ones.
agent_upgrade_declined: bool = false,

/// How many agent restarts this run has already spent trying to adopt the
/// bundled build (T147). Bounded by `max_agent_upgrade_attempts`: if a restart
/// does not cure staleness — an agent from another install holding the
/// single-instance guard, say — retrying on every window close would kill an
/// innocent agent over and over.
agent_upgrade_attempts: u8 = 0,

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
        .local_agent = LocalAgent.init(alloc),
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

    // Register the viewer pane host class (T373). The class is registered
    // whether or not this box has a WebView2 runtime: a pane with no runtime
    // still needs a window to paint its error card in.
    self.viewer_class_atom = ViewerPane.registerClass(hinstance);
    if (self.viewer_class_atom == 0) return error.Win32Error;
    errdefer if (self.viewer_class_atom != 0) {
        _ = w32.UnregisterClassW(ViewerPane.CLASS_NAME, self.hinstance);
    };

    // The WebView2 host is inert until the first viewer pane asks it for an
    // environment, so constructing it costs nothing on a session that never
    // opens one.
    self.webview2_host = .init(alloc);

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

/// Perform a queued WM_APP_SETFOCUS: SetFocus the target surface, but only
/// while its top-level window still holds foreground. A deferred assert is a
/// *forward* of focus the window already received — never a grab. Without this
/// guard, two windows created back-to-back (session restore, T89f2) each queue
/// an assert whose execution steals activation from the other window; every
/// steal re-fires the loser's top-level WM_SETFOCUS forwarding, queueing the
/// next assert — a perpetual foreground ping-pong that makes the app
/// uncontrollable. Stale asserts are dropped; the surface gets focus on the
/// next genuine activation of its window.
pub fn performDeferredFocus(hwnd: w32.HWND) void {
    const root = w32.GetAncestor(hwnd, w32.GA_ROOT) orelse return;
    if (!shouldPerformDeferredFocus(
        onInputDesktop(),
        w32.GetForegroundWindow(),
        root,
    )) return;
    _ = w32.SetFocus(hwnd);
}

/// The `performDeferredFocus` decision, split out so it is unit-testable
/// (the win32 calls around it are not).
///
/// On the input desktop the rule is the T89f2 one: only forward focus the
/// window ALREADY holds. Off it — a background desktop created with
/// `CreateDesktopW`, which is how the acceptance harness runs the GUI
/// without stealing the user's foreground — there is no foreground window
/// at all: `GetForegroundWindow` returns null for every window on it. The
/// guard would then drop every deferred focus, so keyboard focus could
/// never move (splits, tabs, dialogs), and the guard's own reason for
/// existing is moot there because a `SetFocus` cannot steal activation
/// from a window that cannot have it.
fn shouldPerformDeferredFocus(
    on_input_desktop: bool,
    foreground: ?w32.HWND,
    root: w32.HWND,
) bool {
    if (!on_input_desktop) return true;
    return foreground == root;
}

/// Whether this process's GUI thread runs on the INPUT desktop (the one the
/// user sees). Cached: a thread's desktop is bound at startup and never
/// changes for the app. Failure to determine it is reported as `true`, so
/// the interactive path keeps its exact behavior when the query is denied.
var on_input_desktop_cache: ?bool = null;

fn onInputDesktop() bool {
    if (on_input_desktop_cache) |v| return v;
    const v = queryOnInputDesktop();
    on_input_desktop_cache = v;
    return v;
}

fn queryOnInputDesktop() bool {
    const mine = w32.GetThreadDesktop(w32.GetCurrentThreadId()) orelse return true;
    const input_desk = w32.OpenInputDesktop(0, 0, w32.DESKTOP_READOBJECTS) orelse return true;
    defer _ = w32.CloseDesktop(input_desk);

    // Handles differ even for the same desktop object, so compare names.
    var mine_name: [256]u16 = undefined;
    var input_name: [256]u16 = undefined;
    var mine_len: u32 = 0;
    var input_len: u32 = 0;
    if (w32.GetUserObjectInformationW(
        mine,
        w32.UOI_NAME,
        &mine_name,
        @sizeOf(@TypeOf(mine_name)),
        &mine_len,
    ) == 0) return true;
    if (w32.GetUserObjectInformationW(
        input_desk,
        w32.UOI_NAME,
        &input_name,
        @sizeOf(@TypeOf(input_name)),
        &input_len,
    ) == 0) return true;
    if (mine_len != input_len) return false;
    const n = mine_len / @sizeOf(u16);
    return std.mem.eql(u16, mine_name[0..n], input_name[0..n]);
}

test "shouldPerformDeferredFocus: input desktop forwards only to the foreground window" {
    const root: w32.HWND = @ptrFromInt(0x1000);
    const other: w32.HWND = @ptrFromInt(0x2000);
    try std.testing.expect(shouldPerformDeferredFocus(true, root, root));
    try std.testing.expect(!shouldPerformDeferredFocus(true, other, root));
    // No foreground window at all still means "not ours" on the input
    // desktop (a transient state there, e.g. the window being destroyed).
    try std.testing.expect(!shouldPerformDeferredFocus(true, null, root));
}

test "shouldPerformDeferredFocus: background desktop always forwards" {
    const root: w32.HWND = @ptrFromInt(0x1000);
    const other: w32.HWND = @ptrFromInt(0x2000);
    // A background desktop has no foreground window, so the guard cannot
    // apply — without this, focus never moves anywhere on a test desktop.
    try std.testing.expect(shouldPerformDeferredFocus(false, null, root));
    try std.testing.expect(shouldPerformDeferredFocus(false, root, root));
    try std.testing.expect(shouldPerformDeferredFocus(false, other, root));
}

/// Re-run the split layout of the window owning the given terminal-surface
/// HWND — used when a pane's banner strip height changed (T101 collapse/
/// expand) so the terminal band under the strip grows/shrinks to match.
/// Resolves the Surface via GWLP_USERDATA with the same guard as
/// surfaceWndProc; silently no-ops for anything else.
pub fn relayoutOwnerWindow(hwnd: w32.HWND) void {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return;
    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
    if (surface.hwnd == null or surface.hwnd.? != hwnd) return;
    surface.parent_window.layoutSplits();
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
    // Session re-attach (T89f2): if a layout manifest survives and its agent
    // sessions are still alive, rebuild those windows and SUPPRESS the default
    // blank window. Any failure (no manifest, persistence off, agent gone,
    // all-dead) returns false and we open one blank window as usual.
    const restored = self.restoreSessionLayout();

    // Create the initial Window container with one tab. Route through
    // createWindow so the session-persistence injection (T89d) applies to the
    // startup window exactly as it does to every later `new_window`. Skipped
    // when restore already opened at least one window.
    const startup_window: ?*Window = if (restored) null else try self.createWindow(.{});

    // Surface config load diagnostics once at startup (T69). After the
    // first window exists so the dialog has an owner to center on; the
    // dialog pumps its own modal loop, so startup messages (paints, IPC)
    // keep flowing while it is up. Owner is the blank startup window, or the
    // first restored window when restore suppressed it.
    const diag_owner: ?*Window = startup_window orelse
        (if (self.windows.items.len > 0) self.windows.items[0] else null);
    if (diag_owner) |w| self.showConfigErrorsIfAny(&self.config, w);

    // T145: start watching the shared local-agent link, now that the startup
    // windows (restored or blank) have resolved a connection. From here a dead
    // agent is NOTICED and the local windows rebuild in place, instead of the
    // panes sitting frozen until the user quits and relaunches.
    self.installLocalAgentWatch();

    // T147: restore has settled, so this is a safe moment to adopt a newer
    // bundled agent build. Idle ⇒ silent restart; live sessions ⇒ the mandatory
    // confirmation. This is what un-sticks an agent that survived several app
    // upgrades on an old binary (the upgrade script deliberately never kills
    // it), instead of waiting for a reboot.
    self.refreshLocalAgentIfStale("launch restore finished");

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
            if (msg.hwnd) |h| performDeferredFocus(h);
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
            } else if (ActivityMonitor.owning(msg.hwnd.?)) |monitor| {
                // The Activity Monitor panel (T285): Escape closes and the
                // arrow/page/home/end keys drive the table. Typing falls
                // through to the filter EDIT. Exclusive for the same reason as
                // the dialogs above — its children must never reach the
                // Surface-cast popup-edit intercepts.
                if (monitor.handleKey(vk)) continue :loop;
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

    // Activity Monitor panels (T285) are independent top-level windows, so they
    // are not torn down with any terminal window. Close them here so a sampling
    // thread can never outlive the allocator it is writing into.
    ActivityMonitor.closeAll();

    // Flush the session-layout manifest while every window/surface is still
    // alive (T89f). Quit DETACHES sessions (they survive under the agent), so
    // the topology we capture here is exactly what the next launch re-attaches.
    // Kill any pending debounce timer first so it can't fire mid-teardown.
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, LAYOUT_SYNC_TIMER_ID);
    // T145: no in-place recovery during teardown — the windows are about to go.
    self.endAgentSettleWatch();
    self.syncSessionLayout();

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

    // Tear down the shared local-agent connection AFTER every window (and its
    // surfaces) that borrowed it is gone. This is a pipe disconnect, not a
    // CLOSE — the agent keeps its pinned sessions + snapshots rings so they
    // re-attach on the next launch (T89d; the close-vs-quit split is T89e).
    self.local_agent.deinit();

    // Free the IPC target registry (keys are owned).
    self.ipc_registry.deinit(alloc);

    // Layout-blob bookkeeping (T334): the agent KEEPS the blobs on purpose —
    // they are what makes this machine restorable after we exit — so this frees
    // only our own key strings.
    self.clearPushedLayouts();
    self.pushed_layouts.deinit(alloc);
    self.pushed_layouts_conn = null;

    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }

    // Releases the shared environment; the client DLL stays loaded on purpose
    // (see `webview2.Host.client_dll`).
    self.webview2_host.deinit();

    if (self.viewer_class_atom != 0) {
        _ = w32.UnregisterClassW(ViewerPane.CLASS_NAME, self.hinstance);
        self.viewer_class_atom = 0;
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

/// (Re)arm the debounced session-layout write (T89f). Called from the layout
/// mutation sites (add/close tab, add/close split, rename, tab color, frame
/// change). No-op when persistence is off or the message window isn't up yet
/// (early startup; `terminate`/quit does a final sync regardless). `SetTimer`
/// with an existing id restarts it, giving the 250ms debounce for free.
pub fn markLayoutDirty(self: *App) void {
    if (!self.config.@"session-persistence") return;
    const hwnd = self.msg_hwnd orelse return;
    // A real mutation gets the full pending-sid retry budget again.
    self.layout_sid_retries = 0;
    _ = w32.SetTimer(hwnd, LAYOUT_SYNC_TIMER_ID, LAYOUT_SYNC_DEBOUNCE_MS, null);
}

/// Capture the live window/tab/split topology and atomically persist it to the
/// session-layout manifest (T89f). Best-effort. When persistence is off the
/// stale manifest is deleted so a later launch never restores it.
pub fn syncSessionLayout(self: *App) void {
    const gpa = self.core_app.alloc;
    if (!self.config.@"session-persistence") {
        session_layout.clear(gpa);
        // Persistence just went off (or was never on): the agent must not keep
        // offering this machine's windows for restore either.
        self.pushLayoutBlobs(.{});
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var pending = false;
    const file = self.captureSessionLayout(arena_state.allocator(), &pending) catch |err| {
        log.warn("session-layout capture failed err={}", .{err});
        return;
    };
    session_layout.write(gpa, file);
    self.pushLayoutBlobs(file);

    // If an agent-backed pane hasn't published its session id yet, the manifest
    // just written has a null session_id for it (not re-attachable). Re-arm a
    // bounded retry so a follow-up capture records the id once the OPEN reply
    // lands; reset the counter once nothing is pending (or the ceiling is hit).
    if (pending and self.layout_sid_retries < LAYOUT_SYNC_MAX_RETRIES) {
        self.layout_sid_retries += 1;
        if (self.msg_hwnd) |hwnd|
            _ = w32.SetTimer(hwnd, LAYOUT_SYNC_TIMER_ID, LAYOUT_SYNC_RETRY_MS, null);
    } else {
        self.layout_sid_retries = 0;
    }
}

/// Mirror the just-captured topology to the LOCAL agent's layout-blob store
/// (T334) — one `SET_LAYOUT{key, blob, session_ids}` per window, plus a delete
/// for every key that is no longer in the topology.
///
/// This is what makes a Windows machine visible to "Restore All" (§5.4/T18):
/// the agent holds the blobs, so another viewer — this box after a quit, or a
/// different machine over the relay — can rebuild the whole window/tab/split
/// topology from the AGENT's copy rather than from a local file it does not
/// have. The macOS analog is `LocalAgentManager.pushLayout`/`deleteLayout`.
///
/// Three properties, each load-bearing:
///
///   * **Non-spawning.** `sharedConnectionIfWarm` never dials and never starts
///     an agent (Mac's `warmSharedOwner` rule). Mirroring a layout is
///     housekeeping; it must not be the thing that launches a daemon.
///   * **Non-blocking.** `setLayoutNoWait` only enqueues the frame for the
///     writer thread, so this runs on the UI thread between a split drag and
///     its repaint without waiting on any ack.
///   * **Convergent.** The push is a full RECONCILE against `pushed_layouts`,
///     not an incremental edit: unchanged windows cost nothing, changed windows
///     are re-pushed, and vanished keys are deleted. `pushed_layouts` holds only
///     what THIS run pushed, so the delete pass can never reach a previous run's
///     blobs — which is the whole point of the store.
///
/// The key is `Window.layout_uuid` (T338), not the manifest's `id`. The id is
/// unique within one file but not across app runs: the auto IPC name
/// `window-N` comes from a per-process counter and `win-{index}` is a position
/// in this run's window list, so run 2's first window pushed under run 1's
/// first window's key. Since the push is an upsert, the relaunched app's blank
/// startup window overwrote the topology inside the 250ms layout debounce —
/// destroying the record precisely in the crash-with-no-manifest case that
/// "Restore All" exists for.
fn pushLayoutBlobs(self: *App, file: session_layout.File) void {
    const gpa = self.core_app.alloc;

    const conn = self.local_agent.sharedConnectionIfWarm() orelse {
        // No agent to mirror to. Keep the map: if this is a transient link
        // drop, the identity check below re-pushes everything once a new
        // connection appears.
        return;
    };
    // A different connection ⇒ a store we have never written to (an agent
    // restart materializes its blobs from disk, but we cannot know they match
    // what we last sent). Forget what we think we pushed and send it all again.
    if (self.pushed_layouts_conn != conn) {
        self.clearPushedLayouts();
        self.pushed_layouts_conn = conn;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Pass 1: upsert every window whose bytes changed.
    var live: std.StringHashMapUnmanaged(void) = .empty;
    defer live.deinit(gpa);
    for (file.windows) |win| {
        // T338: the key is the window's stable uuid, NOT its manifest `id`.
        // `orelse win.id` covers only a blob-sourced window written by a
        // pre-T338 build; every window this app captures has a uuid.
        const key = win.uuid orelse win.id;
        live.put(gpa, key, {}) catch {};

        const blob = layout_blobs.serializeWindow(arena, win) catch |err| {
            log.warn("layout push: serialize '{s}' failed err={}", .{ key, err });
            continue;
        };
        const hash = layout_blobs.blobHash(blob);
        if (self.pushed_layouts.get(key)) |prev| {
            if (prev == hash) continue;
        }
        const ids = layout_blobs.sessionIds(arena, win) catch |err| {
            log.warn("layout push: session ids for '{s}' failed err={}", .{ key, err });
            continue;
        };
        conn.setLayoutNoWait(key, blob, ids, false) catch |err| {
            log.warn("layout push: SET_LAYOUT '{s}' failed err={}", .{ key, err });
            continue;
        };
        // Own the key: it lives in the caller's capture arena.
        const gop = self.pushed_layouts.getOrPut(gpa, key) catch continue;
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, key) catch {
                _ = self.pushed_layouts.remove(key);
                continue;
            };
        }
        gop.value_ptr.* = hash;
    }

    // Pass 2: delete the keys that are gone (a closed window, a renamed one).
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    var it = self.pushed_layouts.iterator();
    while (it.next()) |entry| {
        if (live.contains(entry.key_ptr.*)) continue;
        stale.append(gpa, entry.key_ptr.*) catch continue;
    }
    for (stale.items) |key| {
        conn.setLayoutNoWait(key, null, &.{}, true) catch |err| {
            log.warn("layout push: delete '{s}' failed err={}", .{ key, err });
            continue;
        };
        if (self.pushed_layouts.fetchRemove(key)) |kv| gpa.free(kv.key);
    }
}

/// Drop the pushed-blob bookkeeping (and its owned keys). Does NOT touch the
/// agent's store — the caller either has no connection to it or is about to
/// re-push everything.
fn clearPushedLayouts(self: *App) void {
    const gpa = self.core_app.alloc;
    var it = self.pushed_layouts.iterator();
    while (it.next()) |entry| gpa.free(entry.key_ptr.*);
    self.pushed_layouts.clearRetainingCapacity();
}

const FrameCapture = struct {
    frame: ?session_layout.Frame = null,
    maximized: bool = false,
};

/// Read a window's outer rect + maximized flag (T89f). For a maximized OR
/// minimized window this is the RESTORED rect (`rcNormalPosition`) so restore
/// comes back to a sane size — the same split `persistPlacement` (T85) uses.
/// `GetWindowRect` on an iconic window returns the −32000,−32000 caption-stub
/// rect, which a later restore would faithfully rebuild as an offscreen sliver
/// (T106). Null frame ⇒ the query failed / no hwnd; restore falls back to
/// config.
fn captureFrame(hwnd_opt: ?w32.HWND) FrameCapture {
    const hwnd = hwnd_opt orelse return .{};
    const maximized = w32.IsZoomed(hwnd) != 0;
    var r: w32.RECT = undefined;
    if (maximized or w32.IsIconic(hwnd) != 0) {
        var wp: w32.WINDOWPLACEMENT = undefined;
        wp.length = @sizeOf(w32.WINDOWPLACEMENT);
        if (w32.GetWindowPlacement(hwnd, &wp) == 0) return .{ .maximized = maximized };
        r = wp.rcNormalPosition;
    } else {
        if (w32.GetWindowRect(hwnd, &r) == 0) return .{};
    }
    return .{
        .frame = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top },
        .maximized = maximized,
    };
}

/// Capture one leaf's restore metadata: the agent session id to re-ATTACH to
/// (null when the pane is not agent-backed — it restores as an exited pane),
/// the pane's stable id (T113), the current title, and any registered IPC
/// name. `kind`/`viewer_location` stay null (reserved for viewer panes, T90h).
/// Strings dupe into `arena`.
fn captureLeaf(self: *App, arena: Allocator, surface: *Surface) !session_layout.Leaf {
    const sid: ?[]const u8 = if (surface.core_surface_ready)
        surface.core_surface.remoteSessionId()
    else
        null;
    const ipc_name = if (surface.pane_view) |pv| self.ipcNameOf(.{ .pane = pv }) else null;
    return .{
        .session_id = if (sid) |s| try arena.dupe(u8, s) else null,
        .title = if (surface.getTitle()) |t| try arena.dupe(u8, t) else null,
        .ipc_name = if (ipc_name) |n| try arena.dupe(u8, n) else null,
        // Recorded unconditionally: it must survive even for a leaf with no
        // session (a fresh OPEN still keeps the id its shell was baked with).
        .pane_id = try arena.dupe(u8, surface.paneId()),
    };
}

/// A pinned tab title (T92) as UTF-8, or null when there is none to record.
fn captureTabTitle(arena: Allocator, win: *Window, ti: usize) !?[]const u8 {
    const len = win.tab_title_lens[ti];
    if (len == 0) return null;
    return try std.unicode.utf16LeToUtf8Alloc(arena, win.tab_titles[ti][0..len]);
}

/// Build the manifest `File` from live state into `arena` (T89f). Excludes
/// cross-machine (`remote_dialed`) windows — those are the remote-reconnect
/// path (T56), not local re-attach — and quick terminals (not restorable). The
/// flat `nodes` array is a 1:1 copy of the `SplitTree` node array, so child
/// handles carry over as indices unchanged. Caller frees `arena` after writing.
fn captureSessionLayout(self: *App, arena: Allocator, pending: *bool) !session_layout.File {
    var windows: std.ArrayList(session_layout.Window) = .empty;
    for (self.windows.items, 0..) |win, wi| {
        if (win.is_quick_terminal) continue;
        if (win.remote_dialed != null) continue;
        if (win.tab_count == 0) continue;

        const tabs = try arena.alloc(session_layout.Tab, win.tab_count);
        for (0..win.tab_count) |ti| {
            const tree = &win.tab_trees[ti];
            const nodes = try arena.alloc(session_layout.Node, tree.nodes.len);
            for (tree.nodes, 0..) |node, ni| {
                nodes[ni] = switch (node) {
                    .leaf => |pane| leaf: {
                        // A viewer leaf has no agent session to capture; it is
                        // described by the T89f-reserved additive fields
                        // instead. T90h owns restoring them.
                        const surface = pane.surface() orelse break :leaf .{ .leaf = .{
                            .kind = "viewer",
                            .pane_id = try arena.dupe(u8, pane.paneId()),
                            .viewer_location = if (pane.viewer().?.location) |loc|
                                try arena.dupe(u8, loc)
                            else
                                null,
                        } };
                        const leaf = try self.captureLeaf(arena, surface);
                        // No id yet but this leaf is EXPECTED to be agent-backed
                        // (its window rides the local agent, or the surface's
                        // remote backend is already wired) ⇒ the OPEN is still in
                        // flight; ask syncSessionLayout to retry so the id gets
                        // recorded. `local_agent_conn` is set before the first
                        // surface/capture, so this catches the startup pane whose
                        // remote_conn isn't attached at the very first write.
                        if (leaf.session_id == null and
                            (surface.remote_conn != null or win.local_agent_conn != null))
                            pending.* = true;
                        break :leaf .{ .leaf = leaf };
                    },
                    .split => |sp| .{ .split = .{
                        .layout = @tagName(sp.layout),
                        .ratio = @floatCast(sp.ratio),
                        .left = @intFromEnum(sp.left),
                        .right = @intFromEnum(sp.right),
                    } },
                };
            }
            const color = win.tab_colors[ti];
            tabs[ti] = .{
                .nodes = nodes,
                .color = if (color == .none) null else @tagName(color),
                .hero_ratio = win.tab_hero_ratio[ti],
                .title = if (win.tab_title_pinned[ti])
                    try captureTabTitle(arena, win, ti)
                else
                    null,
                .active = ti == win.active_tab,
            };
        }

        const frame_max = captureFrame(win.hwnd);
        try windows.append(arena, .{
            .id = if (win.ipc_name) |n|
                try arena.dupe(u8, n)
            else
                try std.fmt.allocPrint(arena, "win-{d}", .{wi}),
            // The identity that survives this app run (T338). `id` above does
            // not: both spellings restart per process.
            .uuid = try arena.dupe(u8, win.layoutUuid()),
            .frame = frame_max.frame,
            .maximized = frame_max.maximized,
            .title_override = if (win.title_override) |t| try arena.dupe(u8, t) else null,
            .ipc_name = if (win.ipc_name) |n| try arena.dupe(u8, n) else null,
            .active_tab = @intCast(win.active_tab),
            .tabs = tabs,
        });
    }
    return .{ .windows = try windows.toOwnedSlice(arena) };
}

/// Bounded wall-clock budget for the launch-time liveness probe (`LIST_SESSIONS`
/// on the local agent). A healthy agent answers in single-digit ms; a wedged one
/// times out and restore proceeds treating liveness as UNKNOWN (attempt ATTACH,
/// never drop) rather than hanging startup.
const restore_probe_timeout_ns: u64 = 2000 * std.time.ns_per_ms;

/// The liveness probe every rebuild takes before replaying a topology: the
/// agent's roster, plus the set of session ids we will ATTACH (alive, or a
/// relaunchable tombstone).
///
/// `set` being null is NOT the same as an empty set. Null means the probe
/// itself failed — liveness UNKNOWN, so attempt every leaf rather than drop a
/// window over a transport fault. An empty set means the agent answered and owns
/// nothing, which really does mean nothing is attachable.
///
/// The set BORROWS its keys from `roster`, so the two are freed together and
/// neither may outlive this struct.
const AttachProbe = struct {
    roster: ?remote_connection.OwnedSessions = null,
    set: ?std.StringHashMap(void) = null,

    fn take(gpa: Allocator, conn: *remote_connection.Connection) AttachProbe {
        var self: AttachProbe = .{};
        self.roster = conn.requestSessions(restore_probe_timeout_ns) catch |err| {
            log.warn("session-restore: liveness probe failed err={} (treating as unknown)", .{err});
            return self;
        };
        var m = std.StringHashMap(void).init(gpa);
        for (self.roster.?.sessions) |sess| {
            if (sess.alive or sess.relaunchable) m.put(sess.id, {}) catch {};
        }
        self.set = m;
        return self;
    }

    /// What the restore helpers take: null ⇒ unknown ⇒ attempt every leaf.
    fn attachSet(self: *const AttachProbe) ?*const std.StringHashMap(void) {
        return if (self.set) |*m| m else null;
    }

    fn deinit(self: *AttachProbe) void {
        if (self.set) |*m| m.deinit();
        if (self.roster) |*s| s.deinit();
    }
};

/// Which transport a rebuild's panes ride, and what the rebuilt window owns of
/// it. Threaded through the restore helpers as ONE value so a caller cannot set
/// the connection and forget the ownership that goes with it — the two are the
/// same decision (T336).
///
/// **win32 windows each own their transport.** `openDialedWindow` stores the
/// dial on the window and `Window.deinit` tears it down, so a shared connection
/// would die with whichever rebuilt window the user closed first and leave the
/// rest attached to a corpse. Mac can hand every rebuilt window ONE
/// `RemoteConnection` (`SessionLayoutRestore.swift:659-675`) because a
/// connection there is refcounted and owned by nobody in particular; here the
/// rule is one dial per window, stated rather than inherited.
const RestoreTransport = struct {
    /// The connection each restored leaf ATTACHes over.
    conn: *remote_connection.Connection,
    /// true ⇒ this box's own agent (the launch-time and local Restore All
    /// paths). false ⇒ a CROSS-MACHINE dial, which also stops `createWindow`
    /// from handing the window a local agent it must not use.
    local_agent: bool = true,
    /// Non-null ⇒ the window being built TAKES OWNERSHIP of this dial. Set for
    /// exactly one window; a second window needs its own dial.
    dialed: ?Window.RemoteDialed = null,
    /// Recorded on the window so T68's "New Window" re-dials the same machine.
    /// Strings borrowed for the call; `setRemoteMachine` dupes them.
    machine: ?Window.RemoteMachine = null,
    /// Re-clamp the recorded frame onto a visible LOCAL monitor. Cross-machine
    /// only: a frame from our own manifest describes monitors we still have,
    /// and moving it would be the app second-guessing the user (see
    /// `restore_frame.zig`).
    reanchor: bool = false,

    fn local(conn: *remote_connection.Connection) RestoreTransport {
        return .{ .conn = conn };
    }
};

/// Launch-time session re-attach (T89f2, the RESTORE half of T89f). Loads the
/// session-layout manifest T89f1 wrote, probes the local agent for which of its
/// sessions are still alive, and rebuilds every restorable window/tab/split —
/// each leaf ATTACHing to the agent session the `ghoztty-agent` kept alive
/// across this app's quit/crash/upgrade (same PID, gap-filled scrollback).
///
/// Returns TRUE iff at least one window was restored, in which case the caller
/// (`run`) SUPPRESSES the default blank startup window. Any failure — no
/// manifest, persistence off, agent unreachable, an all-dead layout — returns
/// false so the normal single blank window opens instead. Best-effort by design;
/// a partial failure restores the windows it can and skips the rest.
///
/// Liveness is TRI-STATE (design pin): a window is dropped ONLY when every one
/// of its session-backed leaves is POSITIVELY gone (the agent answered and none
/// of its ids are present in the roster). If the probe itself failed (agent
/// reachable enough to dial but `LIST_SESSIONS` timed out) liveness is UNKNOWN
/// and we still attempt ATTACH — never drop on transport failure.
///
/// A leaf is ATTACHABLE when its session is alive (same-PID re-attach,
/// gap-filled scrollback) OR a relaunchable TOMBSTONE (T89g): the agent
/// restarted (reboot / agent upgrade) and materialized the session from disk as
/// dead-but-relaunchable. ATTACHing a tombstone lets the shared termio path
/// (`termio/Remote.zig`) apply `session-relaunch` (T230): `notify`, the default,
/// opens a fresh shell in the recorded cwd with a notice naming the command and
/// runs NOTHING; `auto` respawns in-place with a `--- session restarted ---`
/// divider + ring-snapshot scrollback; `prompt` leaves a press-any-key pane).
/// A leaf whose session is
/// genuinely gone / has no id re-opens a FRESH agent-backed pane (the tree shape
/// and the window are preserved), which is friendlier than a permanently-exited
/// pane and keeps every restored pane persistable.
pub fn restoreSessionLayout(self: *App) bool {
    if (!self.config.@"session-persistence") return false;
    const gpa = self.core_app.alloc;

    const path = session_layout.layoutPath(gpa) orelse return false;
    defer gpa.free(path);
    var parsed = (session_layout.load(gpa, path) catch |err| {
        log.warn("session-restore: manifest load failed err={}", .{err});
        return false;
    }) orelse return false;
    defer parsed.deinit();
    const file = parsed.value;
    if (file.windows.len == 0) return false;

    // Resolve (find-or-spawn) the local agent. Without a connection we cannot
    // ATTACH anything, so fall back to a blank window. A cold reboot spawns the
    // agent fresh; it re-materializes the sessions from disk as relaunchable
    // tombstones, so the probe below finds them attachable and each leaf applies
    // `session-relaunch` (T89g/T230 — by default a fresh shell plus a notice,
    // never a re-run). Only sessions the agent truly no longer knows re-open
    // fresh.
    const conn = self.local_agent.sharedConnection() orelse {
        log.info("session-restore: no local agent; opening a blank window", .{});
        return false;
    };

    // Probe the roster. A null set ⇒ the probe failed (UNKNOWN — attempt every
    // leaf); a present set holds every session we can ATTACH: alive (same-PID
    // re-attach) OR a relaunchable tombstone (RELAUNCH per policy).
    // Genuinely-exited/unknown ids are absent → their leaves re-open fresh.
    var probe = AttachProbe.take(gpa, conn);
    defer probe.deinit();
    const attach_ptr = probe.attachSet();

    var restored: usize = 0;
    for (file.windows) |win| {
        if (!restoreWindowHasAttachableLeaf(win, attach_ptr)) continue;
        self.restoreWindow(win, .local(conn), attach_ptr) catch |err| {
            log.warn("session-restore: window '{s}' failed err={}", .{ win.id, err });
            continue;
        };
        restored += 1;
    }
    if (restored == 0) return false;
    log.info("session-restore: restored {d} window(s)", .{restored});
    return true;
}

/// Whether the window has at least one leaf we will ATTACH or re-open — i.e. not
/// EVERY session-backed leaf is positively gone. A window with no attachable
/// leaf (all its recorded sessions are gone from the roster) is dropped rather
/// than restored as a wall of exited panes. A relaunchable tombstone counts as
/// attachable (it RELAUNCHes), so a window of tombstones is kept (T89g).
fn restoreWindowHasAttachableLeaf(
    win: session_layout.Window,
    attach: ?*const std.StringHashMap(void),
) bool {
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            const sid = leaf.session_id orelse {
                // A leaf with no session id re-opens fresh — a reason to keep
                // the window (its layout is intact) even if nothing attaches.
                return true;
            };
            // Attachable (alive or relaunchable tombstone), or roster unknown
            // (probe failed) ⇒ attachable.
            if (attach) |a| {
                if (a.contains(sid)) return true;
            } else return true;
        }
    }
    // No leaves at all, or every session-backed leaf positively gone.
    return false;
}

/// The ATTACH override for one restored leaf: ride the local agent, and set
/// `session_id` iff the session is attachable — alive (same-PID re-attach) or a
/// relaunchable tombstone (RELAUNCH per policy), or the roster is unknown. A
/// genuinely-gone / id-less leaf gets a null session_id — the surface OPENs a
/// fresh agent-backed pane.
fn restoreAttachOverride(
    leaf: session_layout.Leaf,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) Surface.Overrides {
    const sid: ?[]const u8 = if (leaf.session_id) |s| blk: {
        const ok = if (attach) |a| a.contains(s) else true; // null set ⇒ unknown ⇒ attempt
        break :blk if (ok) s else null;
    } else null;
    return .{
        // T113: hand back the RECORDED pane id. The process we are re-attaching
        // to still holds it in `$GHOZTTY_PANE_ID`; generating a fresh one here
        // would silently break every pane's ability to name itself across an
        // app restart — the exact class of breakage T112 hit with pids.
        .pane_id = leaf.pane_id,
        .remote = .{
            .connection = tr.conn,
            .local_agent = tr.local_agent,
            .session_id = sid,
        },
    };
}

/// The first (leftmost-deepest) leaf reachable from `idx` in a flat manifest
/// node array — the leaf whose session the surface occupying that subtree's
/// position ATTACHes to. Null on a corrupt array (out-of-range index or a cycle).
fn restoreFirstLeaf(nodes: []const session_layout.Node, idx: usize) ?session_layout.Leaf {
    var i = idx;
    var guard: usize = 0;
    while (guard <= nodes.len) : (guard += 1) {
        if (i >= nodes.len) return null;
        if (nodes[i].leaf) |lf| return lf;
        const sp = nodes[i].split orelse return null;
        i = sp.left;
    }
    return null; // cycle guard tripped
}

/// Rebuild ONE manifest window (its tabs, split trees, per-leaf ATTACH, and
/// presentation state) as a live `Window`. Errors propagate so the caller skips
/// just this window.
fn restoreWindow(
    self: *App,
    win: session_layout.Window,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) !void {
    if (win.tabs.len == 0) {
        if (tr.dialed) |d| d.deinitDestroy(self.core_app.alloc);
        return error.CorruptLayout;
    }

    // Tab 0's first surface is created by createWindow's initial addTab; hand it
    // that leaf's ATTACH override up front. `ov0` must outlive createWindow.
    const first_leaf = restoreFirstLeaf(win.tabs[0].nodes, 0) orelse {
        if (tr.dialed) |d| d.deinitDestroy(self.core_app.alloc);
        return error.CorruptLayout;
    };
    var ov0 = restoreAttachOverride(first_leaf, tr, attach);
    const window = self.createWindow(.{
        .surface_overrides = &ov0,
        .ipc_name = win.ipc_name,
        // Re-adopt the layout identity (T338) so the rebuilt window keeps
        // pushing to the key its predecessor used, instead of orphaning that
        // blob and adding a duplicate under a fresh one. Applies to both
        // rebuild sources — the local manifest and an agent-held blob — since
        // both arrive here as a `session_layout.Window`.
        .layout_uuid = win.uuid,
    }) catch |err| {
        // Ownership transfers to the window, so a window that was never created
        // leaves the dial to us — the same contract `openDialedWindow` keeps,
        // for the same reason: the caller must never have to guess.
        if (tr.dialed) |d| d.deinitDestroy(self.core_app.alloc);
        return err;
    };
    // From here the WINDOW owns the transport: every later failure leaves a
    // partially built window alive, and `Window.deinit` is what frees it.
    if (tr.dialed) |d| window.remote_dialed = d;
    if (tr.machine) |m| window.setRemoteMachine(m) catch |err| {
        // Non-fatal: only T68's "New Window inherits the remote host" degrades.
        log.warn("session-restore: recording machine identity failed err={}", .{err});
    };
    try self.restoreTab(window, 0, win.tabs[0], tr, attach);

    // Remaining tabs, appended in manifest order (addTab activates each new tab,
    // so consecutive inserts keep the recorded order regardless of
    // window-new-tab-position).
    for (win.tabs[1..], 1..) |tab, ti| {
        const lf = restoreFirstLeaf(tab.nodes, 0) orelse return error.CorruptLayout;
        var ov = restoreAttachOverride(lf, tr, attach);
        window.pending_surface_overrides = &ov;
        _ = window.addTab() catch |err| {
            window.pending_surface_overrides = null;
            return err;
        };
        try self.restoreTab(window, ti, tab, tr, attach);
    }

    // Window-level presentation: title pin, active tab, outer placement.
    if (win.title_override) |t| window.setTitleOverride(t);
    if (window.tab_count > 0) {
        const active: usize = @min(@as(usize, win.active_tab), window.tab_count - 1);
        window.selectTabIndex(active);
    }
    applyRestoreFrame(window, win.frame, win.maximized, tr.reanchor);
}

/// Rebuild one tab: replay the split tree onto its (already-created) first
/// surface, then reapply the tab's color / hero ratio / pinned title.
fn restoreTab(
    self: *App,
    window: *Window,
    tab_index: usize,
    tab: session_layout.Tab,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) !void {
    if (tab.nodes.len == 0) return error.CorruptLayout;
    const first_pane = window.tab_active_pane[tab_index];
    const first_surface = first_pane.surface() orelse return error.CorruptLayout;
    try self.restoreBuildSubtree(window, tab.nodes, 0, first_surface, tr, attach, 0);

    if (tab.color) |c| {
        if (std.meta.stringToEnum(tab_color.TabColor, c)) |tc| window.tab_colors[tab_index] = tc;
    }
    if (tab.hero_ratio) |r| window.tab_hero_ratio[tab_index] = r;
    if (tab.title) |t| window.setTabTitlePin(tab_index, t);
}

/// Recursively reproduce a manifest subtree by splitting. `anchor` is the live
/// surface currently occupying this subtree's whole region (the first leaf of
/// the subtree). A leaf node registers its IPC pane name on `anchor`; a split
/// node creates the right subtree's first surface via `newSplitAt` (ATTACHing it
/// to that subtree's first leaf), then recurses into both children. Bounded by
/// `nodes.len` against a corrupt (cyclic / out-of-range) manifest.
fn restoreBuildSubtree(
    self: *App,
    window: *Window,
    nodes: []const session_layout.Node,
    idx: usize,
    anchor: *Surface,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
    depth: usize,
) !void {
    if (depth > nodes.len or idx >= nodes.len) return error.CorruptLayout;
    const node = nodes[idx];
    if (node.leaf) |lf| {
        if (lf.ipc_name) |n| if (anchor.pane_view) |pv|
            self.ipcRegister(n, .{ .pane = pv }) catch |err|
            log.warn("session-restore: pane IPC register '{s}' failed err={}", .{ n, err });
        return;
    }
    const sp = node.split orelse return error.CorruptLayout;
    if (sp.left >= nodes.len or sp.right >= nodes.len) return error.CorruptLayout;

    // The NEW surface takes the right/bottom position — attach it to the first
    // leaf of the right subtree.
    const right_leaf = restoreFirstLeaf(nodes, sp.right) orelse return error.CorruptLayout;
    var ov = restoreAttachOverride(right_leaf, tr, attach);
    window.pending_surface_overrides = &ov;

    // `.right`/`.down` put the OLD (anchor) surface on the left/top with `ratio`
    // as its share — the exact inverse of the capture (which stored the left
    // child's ratio). horizontal → right, vertical → down.
    const dir: SplitTree(PaneView).Split.Direction =
        if (std.mem.eql(u8, sp.layout, "vertical")) .down else .right;
    const anchor_pane = anchor.pane_view orelse return error.CorruptLayout;
    const new_surface = window.newSplitAt(anchor_pane, dir, @floatCast(sp.ratio)) catch |err| {
        window.pending_surface_overrides = null;
        return err;
    } orelse {
        window.pending_surface_overrides = null;
        return error.CorruptLayout;
    };

    try self.restoreBuildSubtree(window, nodes, sp.left, anchor, tr, attach, depth + 1);
    try self.restoreBuildSubtree(window, nodes, sp.right, new_surface, tr, attach, depth + 1);
}

// =============================================================================
// Non-destructive local-agent upgrade (T147)
// =============================================================================

/// Post the upgrade re-check to the GUI thread (see
/// `WM_APP_AGENT_UPGRADE_CHECK`). Called when a persistent window goes away:
/// the agent may have just become idle, and idle is the one moment a stale
/// agent can be adopted with nothing to lose.
pub fn scheduleAgentUpgradeCheck(self: *App) void {
    if (!self.config.@"session-persistence") return;
    const hwnd = self.msg_hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_AGENT_UPGRADE_CHECK, 0, 0);
}

/// How many LIVE sessions the agent itself owns, or null when it could not be
/// asked — the input the upgrade policy weighs a destructive restart against.
///
/// Asked of the AGENT, not counted from this app's panes, and the difference is
/// load-bearing: at app quit every window is destroyed while its sessions stay
/// alive on purpose (detach, not close), so a pane count would read 0 at exactly
/// the moment killing the agent destroys the most work. It also sees sessions
/// this app never adopted — another instance's, or a previous run's pinned ones
/// — which a pane walk cannot.
///
/// Tombstones (`alive == false`) are NOT counted: their child is already gone
/// and `sessions.json` brings them back as tombstones after the restart, so a
/// restart costs them nothing.
fn liveAgentSessionCount(self: *App) ?usize {
    const conn = self.local_agent.sharedConnectionIfWarm() orelse return null;
    var roster = conn.requestSessions(restore_probe_timeout_ns) catch |err| {
        log.warn("agent upgrade check: session probe failed err={} (treating as unknown)", .{err});
        return null;
    };
    defer roster.deinit();

    var n: usize = 0;
    for (roster.sessions) |sess| {
        if (sess.alive) n += 1;
    }
    return n;
}

/// Adopt a newer bundled agent build without waiting for a reboot (T147, Mac
/// `refreshLocalAgentIfStale`).
///
/// The agent deliberately outlives the app — the upgrade script swaps
/// `ghoztty-agent.exe` on disk and never kills the running one (T89h) — so
/// without this an agent-side fix reaches the user only when they next reboot.
/// Called at the two moments where a restart can be safe: launch restore
/// finished, and the last persistent window closed.
///
/// The DECISION is `agent_upgrade.decide` (pure, unit-tested); this function is
/// only its mechanism. Idle ⇒ restart silently (logged, never invisible). Live
/// sessions ⇒ the mandatory confirmation CLAUDE.md requires, never a silent
/// reset; a decline defers to the next idle moment and is not re-asked this run.
pub fn refreshLocalAgentIfStale(self: *App, reason: []const u8) void {
    if (!self.config.@"session-persistence") return;
    if (self.agent_recovering) return;
    // Quitting is never a safe moment: the windows are going away but their
    // sessions are meant to SURVIVE the app (that is the whole feature), and a
    // restart here would end them behind the user's back.
    if (self.quit_requested) return;

    // Nothing dialed ⇒ no agent whose build we can judge. Deliberately does NOT
    // spawn one: a freshly spawned agent is by definition current, so spawning
    // to ask would only ever answer "not stale".
    if (!self.local_agent.hasSharedConnection()) {
        log.debug("agent upgrade check: no shared agent connection, nothing to judge [{s}]", .{reason});
        return;
    }

    // A restart that doesn't cure staleness must not retry forever (e.g. an
    // agent from a different install still holding the single-instance guard).
    // Bounded, and the ceiling is logged rather than silently absorbed.
    if (self.agent_upgrade_attempts >= max_agent_upgrade_attempts) {
        log.info(
            "agent upgrade check: attempt ceiling reached ({d}/{d}), not retrying this run [{s}]",
            .{ self.agent_upgrade_attempts, max_agent_upgrade_attempts, reason },
        );
        return;
    }

    const bundled = self.local_agent.bundledVersion();
    const running = self.local_agent.runningVersion();

    // Unknown liveness ⇒ do nothing. "We couldn't ask how much this would
    // destroy" is never grounds for destroying it.
    const live = self.liveAgentSessionCount() orelse {
        log.info("agent upgrade check skipped: agent session liveness unknown [{s}]", .{reason});
        return;
    };

    // Log the decision WHERE IT IS MADE, before acting on it (T201). Every arm
    // used to report only after the fact — and `.confirm_first` reports only
    // once the user answers a modal that can sit there indefinitely, while
    // `.none` reported nothing ever. That made a correctly-working mandatory
    // confirmation indistinguishable in the log from a check that decided
    // nothing, and from one that never ran.
    const decision = agent_upgrade.evaluate(running, bundled, live);
    log.info(
        "agent upgrade check: {s} (running {s}, bundled {s}, {d} live session(s)) [{s}]",
        .{
            decision.reason.description(),
            agent_upgrade.stampForLog(running),
            agent_upgrade.stampForLog(bundled),
            live,
            reason,
        },
    );

    switch (decision.action) {
        .none => return,
        .refresh_now => {
            self.agent_upgrade_attempts += 1;
            _ = self.local_agent.restartForUpgrade();
            // Re-dial straight away so the fresh agent is warm before the next
            // window asks — and through the recovery path, not a bare re-dial:
            // "no LIVE sessions" still allows agent-backed windows full of
            // TOMBSTONES, and those panes must be re-ATTACHed (RELAUNCHed) onto
            // the new agent rather than left pointing at a retired connection.
            // With no windows at all it degrades to exactly a re-dial.
            // Same guard as the confirmed path: the rebuild empties and refills
            // the window list, and the app must not quit itself in between.
            self.beginAgentRefresh();
            _ = self.recoverLocalAgentInPlace();
            self.endAgentRefresh();
            log.info("local agent refreshed to bundled build {s} (idle, no live sessions affected)", .{bundled orelse "?"});
        },
        .confirm_first => {
            if (self.agent_upgrade_declined) {
                log.info(
                    "local agent still stale with {d} live session(s), but the user deferred this run [{s}]",
                    .{ live, reason },
                );
                return;
            }
            self.promptAndRefreshLocalAgent(live, running, bundled orelse "?");
        },
    }
}

/// The mandatory confirmation before a destructive agent restart while sessions
/// are live, and the restart itself when the user takes it.
///
/// On confirm the local windows are rebuilt in place on the fresh agent: the
/// terminated agent's children are gone, but its `sessions.json` survives, so
/// the respawned agent materializes them as relaunchable tombstones and the
/// re-ATTACH finds each one dead.
///
/// What happens next is `session-relaunch` (T230), and the DEFAULT is `notify`:
/// each pane comes back on a FRESH shell in its recorded working directory,
/// above a notice naming the command that had been running. It is deliberately
/// NOT re-run — "We should not ever re-execute the commands which were
/// previously ran". (`auto` restores the old RELAUNCH-with-divider behavior for
/// anyone who opts in.) That is the honest outcome the dialog promises: the
/// panes come back, their processes do not, and nothing starts itself.
fn promptAndRefreshLocalAgent(self: *App, live: usize, running: ?[]const u8, bundled: []const u8) void {
    const alloc = self.core_app.alloc;

    var text_buf: [1024]u8 = undefined;
    const text = agent_upgrade.formatConfirmText(&text_buf, live) catch return;
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return;
    defer alloc.free(text_w);
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, agent_upgrade.confirm_title) catch return;
    defer alloc.free(title_w);

    const owner: ?*Window = if (self.windows.items.len > 0) self.windows.items[0] else null;

    // Announce the modal BEFORE it blocks (T201). `ConfirmDialog.show` pumps its
    // own loop and does not return until the user answers, which can be never —
    // so without this line a dialog sitting on a second monitor leaves no trace
    // at all, and the log simply stops. Every message after this one is
    // contingent on an answer; this one is the evidence that we asked.
    log.info(
        "agent upgrade: showing mandatory restart confirmation ({d} live session(s), running {s} → bundled {s}); waiting for the user",
        .{ live, agent_upgrade.stampForLog(running), bundled },
    );

    const result = ConfirmDialog.show(
        self,
        if (owner) |win| win.hwnd else null,
        if (owner) |win| win.scale else 1.0,
        if (owner) |win| (if (win.getActiveSurface()) |s| s.hwnd else null) else null,
        .{
            .title = title_w.ptr,
            .text = text_w,
            .icon = .warning,
            .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Update Now"),
            .cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Later"),
        },
    );
    if (result != .ok) {
        self.agent_upgrade_declined = true;
        log.info("user deferred destructive agent refresh ({d} live session(s))", .{live});
        return;
    }

    log.warn(
        "user confirmed destructive agent refresh (running {s} → bundled {s}, {d} live session(s))",
        .{ running orelse "<pre-versioned>", bundled, live },
    );
    self.agent_upgrade_attempts += 1;

    // The dialog PROMISED the panes come back, so nothing between here and the
    // rebuild may end the app behind the user's back — a momentarily empty
    // window list must not trip `quit-after-last-window-closed`, and neither
    // must a WM_QUIT already sitting in the queue. Cleared unconditionally on
    // the way out (see `endAgentRefresh`).
    self.beginAgentRefresh();
    defer self.endAgentRefresh();

    _ = self.local_agent.restartForUpgrade();
    const rebuilt = self.recoverLocalAgentInPlace();
    log.warn("destructive agent refresh finished: {d} window(s) rebuilt", .{rebuilt orelse 0});

    // The honest fallback. `recoverLocalAgentInPlace` returning null means the
    // fresh agent could not be reached at all: every pane is now pointing at a
    // retired connection and there is nothing behind them. Saying so is the
    // whole point — the failure the user reported was INVISIBLE, and an empty
    // desktop with no explanation is the worst outcome a confirmation can have.
    if (rebuilt == null) self.showAgentRefreshFailed();
}

/// Guard the window of time in which the app is destroying and rebuilding its
/// own terminals: it must not quit itself while it has legitimately zero (or
/// half-built) windows. Re-entrant-safe by counting rather than flagging.
fn beginAgentRefresh(self: *App) void {
    self.agent_refresh_depth += 1;
    self.stopQuitTimer();
}

fn endAgentRefresh(self: *App) void {
    if (self.agent_refresh_depth > 0) self.agent_refresh_depth -= 1;
    if (self.agent_refresh_depth > 0) return;
    // Re-evaluate honestly: if the rebuild really did leave no windows, the
    // normal policy applies again from here.
    if (self.windows.items.len == 0) self.startQuitTimer();
}

/// Tell the user, in the same modal channel that asked for consent, that the
/// restart they approved did not work. Never a silent disappearance (T229).
fn showAgentRefreshFailed(self: *App) void {
    const text = std.unicode.utf8ToUtf16LeStringLiteral(
        "Ghoztty could not restart the background terminal process.\n\n" ++
            "Your open panes are no longer connected. Close and reopen Ghoztty " ++
            "to start a fresh background process; the panes' previous working " ++
            "directories are restored with it.",
    );
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Background terminal process");
    const owner: ?*Window = if (self.windows.items.len > 0) self.windows.items[0] else null;
    log.warn("agent refresh failed; telling the user", .{});
    _ = ConfirmDialog.show(
        self,
        if (owner) |win| win.hwnd else null,
        if (owner) |win| win.scale else 1.0,
        null,
        .{
            .title = title,
            .text = text,
            .icon = .warning,
            .style = .ok_only,
        },
    );
}

// =============================================================================
// In-place local-agent crash recovery (T145)
// =============================================================================

/// Install the shared-connection link observer so a dropped local-agent link is
/// NOTICED (T145). Idempotent and cheap; `LocalAgent` re-applies it to every
/// connection it installs as shared, including the one recovery dials, so a
/// second agent crash is caught the same way as the first.
///
/// Without this the app only discovers a dead agent lazily, when the next
/// surface asks for a connection — i.e. the user's existing panes stay frozen
/// until they happen to open a new window, which is the whole defect.
pub fn installLocalAgentWatch(self: *App) void {
    if (!self.config.@"session-persistence") return;
    self.local_agent.setStateObserver(self, onLocalAgentLinkChange);
}

/// Link-state observer. Runs on the CONNECTION'S READER THREAD, under its
/// `state_mutex`: it may not touch GUI state, allocate into app structures, or
/// re-enter `Connection`. It posts and returns; every decision happens on the
/// GUI thread in `beginAgentSettleWatch`.
fn onLocalAgentLinkChange(
    ctx: *anyopaque,
    conn: *remote_connection.Connection,
    old: remote_connection.LinkState.State,
    new: remote_connection.LinkState.State,
) void {
    _ = conn;
    // Only DOWN edges are interesting. A link that is already down and moves
    // between down states (`reconnecting → dead`) posts again, which is
    // harmless: the watch is single-shot per settle window.
    if (!agent_recovery.isDown(new)) return;
    if (agent_recovery.isDown(old) and old == new) return;

    const self: *App = @ptrCast(@alignCast(ctx));
    // `msg_hwnd` is created in `init` and cleared in `terminate`, both on the
    // GUI thread. A racing teardown at worst drops this post, and a teardown is
    // exactly when recovery is pointless anyway.
    const hwnd = self.msg_hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_AGENT_LINK_DOWN, 0, 0);
}

/// Start the settle window for a down shared link, or do nothing if one is
/// already running (overlapping down edges share ONE window). GUI thread.
fn beginAgentSettleWatch(self: *App) void {
    if (self.agent_settle_deadline_ms != null) return;
    if (self.agent_recovering) return;
    const hwnd = self.msg_hwnd orelse return;
    const state = self.local_agent.linkState() orelse return;
    if (!agent_recovery.isDown(state)) return;

    self.agent_settle_deadline_ms = std.time.milliTimestamp() + agent_recovery.settle_ms;
    _ = w32.SetTimer(hwnd, AGENT_WATCH_TIMER_ID, agent_recovery.poll_ms, null);
    log.warn(
        "shared local-agent link went down (state={s}); watching {d}ms before deciding on in-place recovery",
        .{ @tagName(state), agent_recovery.settle_ms },
    );
}

/// End the settle watch and disarm its timer. GUI thread.
fn endAgentSettleWatch(self: *App) void {
    self.agent_settle_deadline_ms = null;
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, AGENT_WATCH_TIMER_ID);
}

/// One tick of the settle window: sample the link, ask the pure policy what it
/// means, and act. GUI thread.
fn tickAgentSettleWatch(self: *App) void {
    const deadline = self.agent_settle_deadline_ms orelse return;
    const remaining = deadline - std.time.milliTimestamp();

    // No shared connection at all ⇒ a racing re-dial (or teardown) already
    // replaced what we were watching.
    const state = self.local_agent.linkState() orelse {
        self.endAgentSettleWatch();
        log.info("local-agent link watch ended: no shared connection to judge", .{});
        return;
    };

    // Only touch the filesystem on the deciding tick — the pid read is the one
    // expensive part of the policy's inputs.
    const live_pid: ?i64 = if (agent_recovery.isDown(state) and remaining <= 0)
        self.local_agent.liveAgentPid()
    else
        null;

    const verdict = agent_recovery.evaluate(
        state,
        true, // linkState() is by definition the CURRENT shared connection
        remaining,
        self.local_agent.sharedPid(),
        live_pid,
    );

    switch (verdict) {
        .keep_watching => return,
        .link_recovered => {
            self.endAgentSettleWatch();
            log.warn(
                "shared local-agent link recovered on its own (state={s}); no in-place recovery needed",
                .{@tagName(state)},
            );
        },
        .owner_replaced => {
            self.endAgentSettleWatch();
            log.info("shared local-agent link dropped but a new connection is already in place", .{});
        },
        .agent_restarted => |d| {
            self.endAgentSettleWatch();
            log.warn(
                "local agent is gone (was pid {d}, now {?d}); recovering local windows in place",
                .{ d.previous_pid, d.current_pid },
            );
            self.beginAgentRefresh();
            _ = self.recoverLocalAgentInPlace();
            self.endAgentRefresh();
        },
        .transport_down => |d| {
            self.endAgentSettleWatch();
            log.warn(
                "local-agent transport failed but agent pid {d} is still alive; recovering local windows in place",
                .{d.pid},
            );
            self.beginAgentRefresh();
            _ = self.recoverLocalAgentInPlace();
            self.endAgentRefresh();
        },
    }
}

/// Rebuild every local-agent-backed window's split topology onto a FRESH
/// connection, without relaunching the app (T145, Mac `03f0f1f30`).
///
/// The shape is deliberately the launch-restore path, not a parallel one: we
/// capture the live topology into the same manifest structs `syncSessionLayout`
/// writes, re-dial, and then replay each window's tabs through `restoreTab` —
/// so split ratios, tab colors, hero ratios, pinned titles, IPC pane names and
/// pane ids all come back through code that is already exercised by every
/// restore test, and a bug fixed in one place is fixed in both.
///
/// What it does NOT do is close anything. The departing surfaces are released
/// by `SplitTree.deinit`, which tears them down with their DEFAULT intent —
/// DETACH, keep-alive — because nothing on this path calls
/// `setSessionCloseIntent(true)`. That is the invariant `agent_recovery
/// .sessionSpared` states and the whole lesson of Mac `e65cfa4d5`: the leaves
/// leave because we replaced the tree, and their sessions are the very ones the
/// new leaves just re-ATTACHed.
/// Returns the number of windows rebuilt, or null when recovery could not run
/// at all (already recovering, capture failed, or no agent could be reached).
/// Every one of those used to be a bare `return` — and the bare
/// `reconnectForRecovery() orelse return` on the confirmed-upgrade path is
/// precisely what made T229's field failure invisible twice over. A caller that
/// promised the user their panes would come back needs to know whether they
/// did.
fn recoverLocalAgentInPlace(self: *App) ?usize {
    if (self.agent_recovering) {
        log.warn("in-place recovery: skipped, a recovery is already running", .{});
        return null;
    }
    self.agent_recovering = true;
    defer self.agent_recovering = false;

    const gpa = self.core_app.alloc;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Capture BEFORE re-dialing: the live tree is the source of truth, and the
    // debounced manifest on disk may be up to a full debounce stale.
    var pending = false;
    const captured = self.captureSessionLayout(arena, &pending) catch |err| {
        log.warn("in-place recovery: layout capture failed err={}", .{err});
        return null;
    };

    // Re-dial BEFORE rebuilding, and note the ordering is load-bearing:
    // retiring the old connection shuts it down, so when the departing surfaces
    // are freed below their DETACH teardown fails fast instead of blocking the
    // GUI thread on a pipe nobody is reading.
    // THE line T229 is about. This was `orelse return` — the one exit in the
    // whole chain that said nothing at all, on the path where the app has just
    // TERMINATED the agent every pane was riding. When it fired, every surface
    // was left pointing at a retired connection with no record anywhere that it
    // had happened.
    const conn = self.local_agent.reconnectForRecovery() orelse {
        log.err(
            "in-place recovery ABORTED: no local agent could be re-dialed; " ++
                "{d} window(s) are left on the retired connection",
            .{captured.windows.len},
        );
        return null;
    };

    // A respawned agent materializes its recorded sessions from disk as
    // relaunchable tombstones, so ATTACH is still the right verb — the shared
    // termio path turns a tombstone into a RELAUNCH with the
    // `--- session restarted ---` divider (T89g). Probing which ids it knows
    // keeps a session it has genuinely lost from blocking the rebuild: that
    // leaf re-opens fresh instead.
    var roster: ?remote_connection.OwnedSessions = conn.requestSessions(
        restore_probe_timeout_ns,
    ) catch |err| blk: {
        log.warn("in-place recovery: liveness probe failed err={} (treating as unknown)", .{err});
        break :blk null;
    };
    defer if (roster) |*s| s.deinit();

    var attach_set: ?std.StringHashMap(void) = if (roster) |*s| set: {
        var m = std.StringHashMap(void).init(gpa);
        for (s.sessions) |sess| {
            if (sess.alive or sess.relaunchable) m.put(sess.id, {}) catch {};
        }
        break :set m;
    } else null;
    defer if (attach_set) |*m| m.deinit();
    const attach_ptr: ?*const std.StringHashMap(void) = if (attach_set) |*m| m else null;

    // Match captured windows to live ones by POSITION in `self.windows`:
    // `captureSessionLayout` walks that same list in order, skipping quick
    // terminals and cross-machine remote windows, so we replay the skip rule
    // here rather than trying to key on a synthesized `win-N` id.
    var ci: usize = 0;
    var rebuilt: usize = 0;
    for (self.windows.items) |win| {
        if (win.is_quick_terminal) continue;
        if (win.remote_dialed != null) continue;
        if (win.tab_count == 0) continue;
        defer ci += 1;
        if (ci >= captured.windows.len) break;
        // A window that was never agent-backed (persistence unresolved at its
        // creation, so its panes are plain exec children) has nothing to
        // re-attach and must not have its shells replaced.
        if (win.local_agent_conn == null) continue;

        self.rebuildWindowInPlace(win, captured.windows[ci], conn, attach_ptr) catch |err| {
            log.warn("in-place recovery: window '{s}' failed err={}", .{ captured.windows[ci].id, err });
            continue;
        };
        rebuilt += 1;
    }

    log.info("in-place recovery: rebuilt {d} window(s) on the new agent connection", .{rebuilt});
    if (rebuilt > 0) self.markLayoutDirty();
    return rebuilt;
}

/// Replace one live window's tab trees with fresh surfaces ATTACHed on `conn`.
/// The window itself — its HWND, position, tab count and selection — is kept;
/// only the surfaces inside it are rebuilt, which is what makes this "in place".
fn rebuildWindowInPlace(
    self: *App,
    window: *Window,
    captured: session_layout.Window,
    conn: *remote_connection.Connection,
    attach: ?*const std.StringHashMap(void),
) !void {
    if (captured.tabs.len == 0) return error.CorruptLayout;
    const active_tab = window.active_tab;

    // The window's own connection pointer must move to the new connection
    // BEFORE any surface is built: later tabs/splits read it, and leaving it on
    // the retired connection would quietly make every future pane in this
    // window unrecoverable.
    window.local_agent_conn = conn;

    const tab_count = @min(window.tab_count, captured.tabs.len);
    for (0..tab_count) |ti| {
        self.rebuildTabInPlace(window, ti, captured.tabs[ti], conn, attach) catch |err| {
            log.warn("in-place recovery: tab {d} failed err={}", .{ ti, err });
            continue;
        };
    }

    // Fresh surfaces start visible, so every rebuilt BACKGROUND tab would paint
    // over the active one. Hide them before re-selecting the tab that was
    // frontmost, which shows its own panes and lays them out.
    for (0..window.tab_count) |ti| {
        if (ti != active_tab) window.setTabSurfacesVisible(ti, false);
    }
    if (active_tab < window.tab_count) window.selectTabIndex(active_tab);
    window.layoutSplits();
}

/// Rebuild ONE tab in place: build a fresh root surface for it, swap the tree,
/// then replay the recorded splits onto it via the shared restore walker.
fn rebuildTabInPlace(
    self: *App,
    window: *Window,
    tab_index: usize,
    tab: session_layout.Tab,
    conn: *remote_connection.Connection,
    attach: ?*const std.StringHashMap(void),
) !void {
    if (tab.nodes.len == 0) return error.CorruptLayout;
    const first_leaf = restoreFirstLeaf(tab.nodes, 0) orelse return error.CorruptLayout;

    // Always the LOCAL agent: in-place recovery re-binds panes whose local
    // agent link dropped (T145). A cross-machine window's transport belongs to
    // the window and is torn down with it, never recovered here.
    const tr: RestoreTransport = .local(conn);
    var ov = restoreAttachOverride(first_leaf, tr, attach);
    const root = try window.replaceTabRootSurface(tab_index, &ov);

    // Everything below the root is the ordinary restore walk. `restoreTab`
    // would re-apply color/hero/title too, but those live on the WINDOW and
    // were never lost — only the surfaces were — so we replay just the splits.
    try self.restoreBuildSubtree(window, tab.nodes, 0, root, tr, attach, 0);
}

/// Apply the restored outer placement. Non-maximized: SetWindowPos to the exact
/// screen rect the capture recorded. Maximized: set the (restored-down) rect,
/// then maximize over it — matching T85's remembered-maximized behavior. Null
/// frame ⇒ leave the created position (config/cascade) as-is.
fn applyRestoreFrame(
    window: *Window,
    frame: ?session_layout.Frame,
    maximized: bool,
    /// Cross-machine (T336): clamp a frame authored on ANOTHER machine's
    /// monitors onto one of ours. Never for our own manifest — see
    /// `restore_frame.zig`.
    reanchor: bool,
) void {
    const hwnd = window.hwnd orelse return;
    if (frame) |f| {
        const placed: session_layout.Frame = if (reanchor) blk: {
            const r = reanchorFrame(.{ .x = f.x, .y = f.y, .w = f.w, .h = f.h });
            if (r.x != f.x or r.y != f.y or r.w != f.w or r.h != f.h) {
                log.info(
                    "session-restore: frame {d},{d} {d}x{d} is off every monitor here, re-anchored to {d},{d} {d}x{d}",
                    .{ f.x, f.y, f.w, f.h, r.x, r.y, r.w, r.h },
                );
            }
            break :blk .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        } else f;
        _ = w32.SetWindowPos(
            hwnd,
            null,
            placed.x,
            placed.y,
            placed.w,
            placed.h,
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
        );
    }
    if (maximized) {
        window.start_maximized = true;
        _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
    }
}

/// The win32 half of `restore_frame.reanchor`: ask the OS the two questions the
/// pure rule needs — does this rectangle touch any monitor, and what is the
/// primary's work area — and clamp.
///
/// `MonitorFromRect(MONITOR_DEFAULTTONULL)` IS the intersection query (it
/// returns null when the rect touches nothing), so there is no monitor
/// enumeration here and no chance of the two answers disagreeing. A failure to
/// read the primary's work area leaves the frame alone: replaying a recorded
/// position beats inventing one from nothing.
fn reanchorFrame(frame: restore_frame.Rect) restore_frame.Rect {
    var rc: w32.RECT = .{
        .left = frame.x,
        .top = frame.y,
        .right = frame.x +| frame.w,
        .bottom = frame.y +| frame.h,
    };
    if (w32.MonitorFromRect(&rc, w32.MONITOR_DEFAULTTONULL) != null) return frame;

    const primary = w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY) orelse
        return frame;
    var mi: w32.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(primary, &mi) == 0) return frame;

    const work: restore_frame.Rect = .{
        .x = mi.rcWork.left,
        .y = mi.rcWork.top,
        .w = mi.rcWork.right - mi.rcWork.left,
        .h = mi.rcWork.bottom - mi.rcWork.top,
    };
    // `MonitorFromRect` already answered the visibility question, so only the
    // clamp half of the rule runs here.
    return restore_frame.centerOn(frame, work);
}

/// Create, track, and populate a new Window (with its first tab). Shared by
/// the .new_window action and the IPC server.
pub fn createWindow(self: *App, opts: Window.InitOptions) !*Window {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, opts);
    errdefer window.deinit();

    // Session persistence (T89d): route a fresh LOCAL window's surfaces through
    // the local agent so their processes survive this app (quit/crash/upgrade)
    // and can be re-attached (T89f). Only for a NON-remote window (a
    // `+new-remote-window` carries `surface_overrides.remote`, and its
    // tabs/splits inherit that cross-machine connection instead). Bounded +
    // non-fatal: a broken/unspawnable agent yields null and the window opens as
    // plain exec surfaces (`buildRemoteInherit` returns null → local ConPTY).
    // A CROSS-MACHINE remote window carries a `.remote` override with
    // `local_agent = false`; its tabs/splits inherit that connection, so it must
    // NOT also get a local agent. A LOCAL-agent first-pane override (T99, the
    // IPC `+new-window` path) has `local_agent = true` and does NOT count as
    // remote here — the window still needs `local_agent_conn` set so its later
    // tabs/splits inherit the same agent via `buildRemoteInherit`.
    const is_remote = if (opts.surface_overrides) |ov|
        (ov.remote != null and !ov.remote.?.local_agent)
    else
        false;
    if (!is_remote and self.config.@"session-persistence") {
        window.local_agent_conn = self.local_agent.sharedConnection();
    }

    try self.windows.append(alloc, window);
    errdefer _ = self.windows.pop();
    // `--view` (T374): the window's one pane is a viewer, not a terminal. It
    // goes through the same `addTab` bookkeeping — a viewer is a normal tab, so
    // there is no second tab-creation path to keep in step.
    if (opts.viewer_location) |location| {
        _ = try window.addViewerTab(location);
    } else {
        _ = try window.addTab();
    }
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
    /// ATTACH to this existing session instead of OPENing a fresh one (T320,
    /// resuming a browsed session). Borrowed for the duration of the call.
    /// Non-null suppresses the per-host cwd/shell defaults below: an ATTACH's
    /// shell and working directory were fixed when its session was first
    /// opened, and sending them again would describe a spawn that is not
    /// happening.
    session_id: ?[]const u8 = null,
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

    // Per-host defaults (T174): a NEW remote window takes this machine's stored
    // cwd + shell, and an explicit value from the caller (the chooser, or the
    // `+new-remote-window` flags, or T68's inheritance) always wins. Mac does
    // this in `Machine.applyOpenDefaults`; win32 has ONE open tail, so this is
    // the single seeding site. Only ever an OPEN — an ATTACH (T320) resumes a
    // session whose shell and cwd were fixed when it was first opened, so it
    // skips the lookup entirely rather than sending values nothing will read.
    var defaults: host_defaults.Resolved = .{};
    if (opts.session_id == null) {
        if (opts.machine) |machine| host_defaults.lookup(
            self.core_app.alloc,
            machine.hostDefaultsKey(),
            &defaults,
        );
    }

    const overrides: Surface.Overrides = .{
        .remote = .{
            .connection = conn,
            .working_directory = opts.working_directory orelse defaults.workingDirectory(),
            .shell = opts.shell orelse defaults.shell(),
            .command = opts.command,
            .session_id = opts.session_id,
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

/// Resume ONE browsed session of the LOCAL agent (T320): open a window whose
/// first pane ATTACHes to `session_id` instead of OPENing a fresh shell. The
/// machine chooser's session roster produces the id; this is the same override
/// shape launch-time restore builds (`restoreAttachOverride`), which is the
/// point — a resume is a restore of one leaf, on demand.
///
/// `pane_id` is the layout manifest's recorded id for that session when the
/// caller found one (T113: the shell we are attaching to still carries it in
/// `$GHOZTTY_PANE_ID`). Both slices are borrowed for the duration of the call.
pub fn resumeLocalSession(
    self: *App,
    session_id: []const u8,
    pane_id: ?[]const u8,
) !*Window {
    // No agent ⇒ nothing to attach to. Opening a plain window instead would
    // silently give the user a fresh shell in place of the session they picked.
    const conn = self.local_agent.sharedConnection() orelse {
        log.warn("resume session: no local agent connection", .{});
        return error.NoAgent;
    };
    var ov: Surface.Overrides = .{
        .pane_id = pane_id,
        .remote = .{
            .connection = conn,
            .local_agent = true,
            .session_id = session_id,
        },
    };
    log.info("resume session: attaching local session id={s}", .{session_id});
    const window = try self.createWindow(.{ .surface_overrides = &ov });
    if (window.hwnd) |hwnd| _ = w32.SetForegroundWindow(hwnd);
    return window;
}

/// What can go wrong rebuilding a machine's whole topology. Both arms are
/// user-facing (the chooser turns them into a footer hint), which is why "the
/// agent had nothing for us" is NOT one of them — that is a successful pull with
/// a count of zero, and it deserves a different sentence.
pub const RestoreAllError = error{
    /// No connection to the local agent, so there is nothing to pull from.
    NoAgent,
    /// GET_LAYOUTS failed or came back unreadable — a transport fault, not an
    /// empty machine. Answering "nothing to restore" here would be a lie.
    PullFailed,
    /// The relay refused the dial outright (T336): the machine is unreachable
    /// or its agent is down.
    DialFailed,
    /// The relay rejected our bearer (401/403). Distinct from `DialFailed`
    /// because the fix is the account row, not the network — the same split
    /// T319 drew for the roster.
    Unauthorized,
};

/// Restore ALL of the LOCAL agent's windows (T335, Mac's `resumeAllSessions`):
/// pull the agent-owned layout blobs (`GET_LAYOUTS`, T334), probe liveness, and
/// replay each decoded window through the SAME rebuild launch-time restore uses.
/// Returns how many windows were rebuilt (0 is a valid answer — the agent may
/// hold nothing, or everything it holds may already be open here).
///
/// The point of the exercise is the SOURCE: the topology comes from the AGENT's
/// copy, not from this box's `session-layout.json`. That is what makes it work
/// after the manifest is gone — a crash, a wiped profile, a first run on a
/// machine whose agent outlived its app — which is exactly when a user wants
/// their windows back and exactly when launch-time restore can do nothing. Mac
/// states the same property (`SessionLayoutRestore.swift:586-588`).
///
/// The cross-machine half (rebuild ANOTHER machine's topology here, over the
/// relay) is `restoreAllRelaySessions`; this one dials nothing.
pub fn restoreAllLocalSessions(self: *App) RestoreAllError!usize {
    // Non-spawning would be wrong here, unlike the push: the user asked for
    // this, so resolving (and if necessary starting) the agent is the job.
    const conn = self.local_agent.sharedConnection() orelse {
        log.warn("restore all: no local agent connection", .{});
        return error.NoAgent;
    };

    const restored = try self.restoreAllFrom(conn, .local);
    if (restored > 0) {
        // The rebuilt windows are this box's again: record them locally so the
        // NEXT launch restores them from the manifest without the round trip
        // (Mac's `bindLocal`). Deliberately NOT done for a cross-machine
        // rebuild — those windows are not ours to promise back, and
        // `captureSessionLayout` skips them anyway.
        self.markLayoutDirty();
    }
    return restored;
}

/// Restore ALL of a RELAY machine's windows here (T336, Mac's
/// `resumeAllRemoteSessions`): dial that machine, pull ITS agent-owned layout
/// blobs, and rebuild the whole topology locally with every pane ATTACHed to a
/// session that keeps running over there. Returns how many windows were rebuilt.
///
/// **Every rebuilt window gets its own dial.** The pull runs on a dial this
/// function owns and frees; each window then takes a fresh one it owns for life
/// (`RestoreTransport`). Mac shares one connection across the rebuild
/// (`SessionLayoutRestore.swift:659-675`) — win32 cannot, because `Window.deinit`
/// tears its transport down, so the first window the user closed would take the
/// others' agent with it. N windows is N+1 dials, and that is the deliberate
/// answer to the ownership question rather than an accident of the loop.
///
/// It runs SYNCHRONOUSLY on the GUI thread, like the single-session remote
/// resume it generalizes (T320's `resumeRelaySession`). That is fine for a
/// loopback or LAN relay and visible on a slow one; T339 moves it off-thread.
pub fn restoreAllRelaySessions(
    self: *App,
    relay_base: []const u8,
    device: []const u8,
    token: []const u8,
) RestoreAllError!usize {
    const alloc = self.core_app.alloc;

    // The PULL's own connection: short-lived by design, exactly like the
    // roster's browse dial (`SessionRoster.worker`). Freed below whatever
    // happens — the windows never ride it.
    var pull = self.dialRelay(relay_base, device, token) catch |err| return err;
    defer pull.deinitDestroy(alloc);

    const machine: Window.RemoteMachine = .{ .relay = .{ .base = relay_base, .device = device } };
    return self.restoreAllFrom(pull.conn(), .{ .relay = .{
        .base = relay_base,
        .device = device,
        .token = token,
        .machine = machine,
    } });
}

/// Where a Restore All's windows come from, and how each one is transported.
const RestoreAllSource = union(enum) {
    /// This box's agent: the windows ride the shared local connection and are
    /// bound back into the local manifest by the caller.
    local,
    /// Another machine over the relay: each window dials its own transport.
    relay: struct {
        base: []const u8,
        device: []const u8,
        token: []const u8,
        machine: Window.RemoteMachine,
    },
};

/// The rebuild both Restore All paths share: pull the agent-owned layout blobs
/// (`GET_LAYOUTS`, T334) over `pull`, probe liveness, and replay each decoded
/// window through the SAME helpers launch-time restore uses. Returns how many
/// windows were rebuilt (0 is a valid answer — the agent may hold nothing, or
/// everything it holds may already be open here).
///
/// The point of the exercise is the SOURCE: the topology comes from the AGENT's
/// copy, not from any local file. That is what makes it work after the manifest
/// is gone — a crash, a wiped profile, a machine whose agent outlived its app —
/// which is exactly when a user wants their windows back and exactly when
/// launch-time restore can do nothing. Mac states the same property
/// (`SessionLayoutRestore.swift:586-588`).
fn restoreAllFrom(
    self: *App,
    pull: *remote_connection.Connection,
    source: RestoreAllSource,
) RestoreAllError!usize {
    const gpa = self.core_app.alloc;

    const payload = pull.requestLayouts(restore_probe_timeout_ns) catch |err| {
        log.warn("restore all: GET_LAYOUTS failed err={}", .{err});
        return error.PullFailed;
    };
    defer gpa.free(payload);

    const decoded = layout_blobs.decodeLayouts(gpa, payload) catch |err| {
        log.warn("restore all: layouts payload unreadable err={}", .{err});
        return error.PullFailed;
    };
    defer decoded.deinit();
    if (decoded.skipped > 0) {
        // Said out loud rather than silently: "3 of 5 windows" is a different
        // fact from "3 windows", and only one of them is worth investigating.
        log.warn("restore all: {d} blob(s) skipped as unreadable", .{decoded.skipped});
    }

    var probe = AttachProbe.take(gpa, pull);
    defer probe.deinit();
    const attach_ptr = probe.attachSet();

    // Which machine's panes count as "already here" for the guard below. A
    // session id is only meaningful WITH the machine that owns it, so the walk
    // is scoped: a local id and a remote id that happen to match are two
    // different sessions on two different boxes.
    const scope: ?Window.RemoteMachine = switch (source) {
        .local => null,
        .relay => |r| r.machine,
    };

    var restored: usize = 0;
    for (decoded.windows) |win| {
        if (!restoreWindowHasAttachableLeaf(win, attach_ptr)) continue;
        // Mac's double-attach guard (`SessionLayoutRestore.swift:695-699`) in the
        // identity win32 actually has: the agent rebinds a session to the NEWEST
        // attach, so rebuilding a window whose panes are already on screen would
        // quietly steal them from the window that has them — and the user would
        // watch their own terminal go blank to make a copy of itself.
        //
        // Mac skips the guard entirely for a cross-machine rebuild because its
        // ids come from the LOCAL manifest and cannot match. Ours are read off
        // the live panes, so the same check keeps working across the relay —
        // pressing Restore All twice on a remote machine must not tear apart the
        // windows the first press built.
        if (self.windowIsOpenOn(win, scope)) {
            log.info("restore all: '{s}' is already open here, skipping", .{win.id});
            continue;
        }

        // Per-window transport. The dial happens BEFORE the rebuild so a
        // machine that stops answering mid-restore costs a skipped window
        // rather than a half-built one.
        const tr: RestoreTransport = switch (source) {
            .local => .local(pull),
            .relay => |r| blk: {
                const dialed = self.dialRelay(r.base, r.device, r.token) catch |err| {
                    log.warn(
                        "restore all: window '{s}' dial failed err={}",
                        .{ win.id, err },
                    );
                    continue;
                };
                break :blk .{
                    .conn = dialed.conn(),
                    .local_agent = false,
                    .dialed = dialed,
                    .machine = r.machine,
                    // The far machine's monitors are not ours (T336).
                    .reanchor = true,
                };
            },
        };

        self.restoreWindow(win, tr, attach_ptr) catch |err| {
            log.warn("restore all: window '{s}' failed err={}", .{ win.id, err });
            continue;
        };
        restored += 1;
    }

    if (restored > 0) {
        log.info("restore all: rebuilt {d} window(s) from the agent's layouts", .{restored});
    } else {
        log.info("restore all: nothing to rebuild ({d} layout(s) held)", .{decoded.windows.len});
    }
    return restored;
}

/// Dial an enrolled relay device for a restore, mapping the transport's errors
/// onto the two the chooser can actually say something useful about. Heap-owned
/// so the result can be handed to a window; the caller frees it if it does not.
fn dialRelay(
    self: *App,
    relay_base: []const u8,
    device: []const u8,
    token: []const u8,
) RestoreAllError!Window.RemoteDialed {
    const alloc = self.core_app.alloc;
    const dialed = alloc.create(relay_dial.Dialed) catch return error.DialFailed;
    dialed.* = relay_dial.dial(alloc, relay_base, device, token, .raw) catch |err| {
        log.warn(
            "restore all: relay dial failed relay={s} device={s} err={}",
            .{ relay_base, device, err },
        );
        alloc.destroy(dialed);
        // A rejected bearer is not an unreachable machine, and telling the user
        // to check the network when the fix is signing in wastes their time
        // (the split T319 drew for the roster).
        return if (err == error.WebSocketUnauthorized) error.Unauthorized else error.DialFailed;
    };
    return .{ .relay = dialed };
}

/// Whether any leaf of `win` names a session one of our panes already has open
/// ON THE SAME MACHINE. One leaf is enough: a window is restored as a unit, so a
/// partial rebuild would either steal that pane or come back missing it.
///
/// `scope` null means the LOCAL agent's sessions; a machine means panes dialed
/// to that machine. Without the scoping a remote id could collide with a local
/// one and silently drop a window from the rebuild.
fn windowIsOpenOn(
    self: *const App,
    win: session_layout.Window,
    scope: ?Window.RemoteMachine,
) bool {
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            const sid = leaf.session_id orelse continue;
            if (sid.len == 0) continue;
            if (self.paneForSession(sid, scope) != null) return true;
        }
    }
    return false;
}

/// The open pane ATTACHed to `id` on the machine named by `scope`, or null.
/// Reads the LIVE id off the pane's remote backend — the same source
/// `captureLeaf` writes the manifest from — so a freshly OPENed persistent pane
/// counts, not just a re-attached one.
fn paneForSession(
    self: *const App,
    id: []const u8,
    scope: ?Window.RemoteMachine,
) ?*Surface {
    for (self.windows.items) |win| {
        if (!windowIsOn(win, scope)) continue;
        for (0..win.tab_count) |t| {
            var it = win.tab_trees[t].iterator();
            while (it.next()) |entry| {
                const surface = entry.view.surface() orelse continue;
                if (!surface.core_surface_ready) continue;
                const sid = surface.core_surface.remoteSessionId() orelse continue;
                if (std.mem.eql(u8, sid, id)) return surface;
            }
        }
    }
    return null;
}

/// Whether `win`'s panes live on the machine named by `scope` (null ⇒ this box).
/// A window with no dial is local; a dialed one is identified by the machine it
/// was opened against, which is exactly what T68 already records.
fn windowIsOn(win: *const Window, scope: ?Window.RemoteMachine) bool {
    const want = scope orelse return win.remote_dialed == null;
    const have = win.remote_machine orelse return false;
    return switch (want) {
        .relay => |w| switch (have) {
            .relay => |h| std.mem.eql(u8, w.base, h.base) and std.mem.eql(u8, w.device, h.device),
            .tcp => false,
        },
        .tcp => |w| switch (have) {
            .tcp => |h| w.port == h.port and std.mem.eql(u8, w.host, h.host),
            .relay => false,
        },
    };
}

/// Resume ONE browsed session of a RELAY machine (T320): dial that machine and
/// open a local window whose pane ATTACHes to `session_id` over the new
/// transport. The relay half of the same story — one dial, then the shared
/// open tail, so a resumed remote window owns its connection exactly like a
/// `+new-remote-window` one and re-dials the same machine for its own "New
/// Window" (T68).
pub fn resumeRelaySession(
    self: *App,
    relay_base: []const u8,
    device: []const u8,
    token: []const u8,
    session_id: []const u8,
) RemoteOpenError!*Window {
    const alloc = self.core_app.alloc;
    const dialed = try alloc.create(relay_dial.Dialed);
    dialed.* = relay_dial.dial(alloc, relay_base, device, token, .raw) catch |err| {
        log.warn(
            "resume session: relay dial failed relay={s} device={s} err={}",
            .{ relay_base, device, err },
        );
        alloc.destroy(dialed);
        return error.DialFailed;
    };
    log.info("resume session: attaching remote session id={s} device={s}", .{ session_id, device });
    return self.openDialedWindow(.{ .relay = dialed }, .{
        .session_id = session_id,
        .machine = .{ .relay = .{ .base = relay_base, .device = device } },
    });
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
        const pane = parent.tab_active_pane[parent.active_tab].surface() orelse
            return error.CreateFailed;
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
                // T132: launch the GUI IN the requested directory. The app the
                // request wakes up inherits the CLI's cwd, and everything it
                // starts inherits it in turn — the startup window, any
                // `working-directory = inherit` pane, and (crucially) the
                // session-persistence agent it spawns, whose cwd is where a
                // later RELAUNCH lands a session that recorded none. A detached
                // launcher script sits in `C:\Windows\System32`, so without this
                // the auto-launched instance and its agent do too.
                try autoLaunchInstance(
                    alloc,
                    apprt.ipc.args.autoLaunchDirectory(value.arguments),
                );
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
///
/// `cwd` (T132) is the directory to start the instance in — the request's
/// `--working-directory` when it named a real path. Null, or a path we cannot
/// encode, falls back to inheriting our own cwd (the pre-T132 behavior); the
/// re-sent IPC request still carries the flag, so the worst case is the old one.
fn autoLaunchInstance(alloc: Allocator, cwd: ?[]const u8) apprt.ipc.Errors!void {
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

    // Working directory for the new instance, NUL-terminated wide. Best-effort:
    // an unencodable path just leaves it null (inherit ours) rather than
    // failing the launch.
    const cwd_w: ?[:0]const u16 = if (cwd) |c|
        (std.unicode.utf8ToUtf16LeAllocZ(alloc, c) catch null)
    else
        null;
    defer if (cwd_w) |w| alloc.free(w);

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
        if (cwd_w) |w| w.ptr else null,
        &si,
        &pi,
    ) == 0) return error.IPCFailed;
    windows.CloseHandle(pi.hProcess);
    windows.CloseHandle(pi.hThread);
}

/// Open a URL in the user's default browser — the native Windows way.
/// `internal_os.open()` uses `std.process.Child`, which can hit unreachable
/// on Windows, so this goes straight to `ShellExecuteW`.
///
/// Shared by the core's `open_url` action and the Help command (T189), which
/// has no binding to route through.
pub fn openUrl(self: *App, url: []const u8) void {
    _ = self;
    var wbuf: [2048]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, url) catch return;
    if (wlen >= wbuf.len) return;
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
            self.openUrl(value.url);
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
                    if (core_surface.rt_surface.pane_view) |pv| {
                        core_surface.rt_surface.parent_window.closeTabMode(value, pv);
                    }
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
                    const rt = core_surface.rt_surface;
                    if (rt.pane_view) |pv| {
                        rt.parent_window.onPaneTitleChanged(pv, value.title);
                    }
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

        // The pane's working directory changed (OSC 7 / shell integration).
        // Cache it on the rt surface so `+list` never has to take that
        // pane's renderer mutex to report it (T111b) — the same thing GTK
        // does with this action.
        .pwd => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const surface = core_surface.rt_surface;
                    if (surface.core_surface_ready) surface.setPwd(value.pwd);
                },
            }
            return true;
        },

        // Acknowledge actions that don't need Win32-specific handling.
        // The core handles the logic; we just confirm receipt.
        .key_sequence,
        .key_table,
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
                                const surface = entry.view.surface() orelse continue;
                                if (surface.scrollbar) |sb| {
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
                            const s2 = entry.view.surface() orelse continue;
                            if (s2.scrollbar) |sb| {
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
                        if (core_surface.rt_surface.pane_view) |pane| {
                            if (win.findTabIndex(pane)) |idx| {
                                if (idx != win.active_tab) win.selectTabIndex(idx);
                            }
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

    // A destructive agent refresh is in flight (T229): the window list is
    // empty or half-built ON PURPOSE and is about to be rebuilt, so this is not
    // "the user closed the last window". `endAgentRefresh` re-asks once the
    // rebuild has settled.
    if (self.agent_refresh_depth > 0) {
        log.info("quit timer suppressed: a destructive agent refresh is in progress", .{});
        return;
    }

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
            // message loop. This is the safe place to call closeSplitPane
            // (outside of core_surface callbacks).
            if (surface.pane_view) |pane| surface.parent_window.closeSplitPane(pane);
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
            surface.handleMouseButton(.left, .press, wparam, lparam);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            surface.handleMouseButton(.left, .release, wparam, lparam);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            deferSetFocus(hwnd);
            surface.handleMouseButton(.right, .press, wparam, lparam);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            surface.handleMouseButton(.right, .release, wparam, lparam);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            deferSetFocus(hwnd);
            surface.handleMouseButton(.middle, .press, wparam, lparam);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            surface.handleMouseButton(.middle, .release, wparam, lparam);
            return 0;
        },
        w32.WM_XBUTTONDOWN => {
            // X1 = back (button four), X2 = forward (button five). Deliver to
            // the terminal for mouse reporting instead of the shell nav.
            deferSetFocus(hwnd);
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .five else .four;
            surface.handleMouseButton(btn, .press, wparam, lparam);
            return 1; // TRUE: handled; suppresses the default WM_APPCOMMAND.
        },
        w32.WM_XBUTTONUP => {
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .five else .four;
            surface.handleMouseButton(btn, .release, wparam, lparam);
            return 1;
        },
        w32.WM_CONTEXTMENU => {
            // Keyboard-invoked (VK_APPS / Shift+F10 via DefWindowProc, or
            // automation). Mouse right-clicks never get here — the RBUTTON
            // handlers above consume them.
            surface.showContextMenuKeyboard();
            return 0;
        },

        w32.WM_NCHITTEST => {
            // T94: the split-divider grab band is ~9 DIP wide but the
            // visual gap between panes is only ~5 DIP, so the band's
            // outer edges lie over the pane surfaces. Fall through
            // (HTTRANSPARENT) so those hits reach the parent Window,
            // which owns divider drag + resize-cursor feedback.
            if (is_surface_window and !surface.parent_window.dragging_split) {
                var pt: w32.POINT = .{
                    .x = @as(i16, @truncate(lparam & 0xFFFF)),
                    .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
                };
                if (surface.parent_window.hwnd) |parent_hwnd| {
                    _ = w32.ScreenToClient(parent_hwnd, &pt);
                    if (surface.parent_window.hitTestDivider(pt.x, pt.y) != null)
                        return w32.HTTRANSPARENT;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
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
            if (surface.pane_view) |pv| surface.parent_window.tab_active_pane[tab] = pv;
            // T92: the tab label / titlebar follow the focused pane's
            // title (no-op when the tab title is user-pinned or the
            // title is unchanged).
            surface.parent_window.refreshTabTitle(tab);
            if (surface.pane_view) |pv| surface.parent_window.heroOnPaneFocused(pv);
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

    if (msg == RelayAccountRow.WM_APP_RELAY_ACCOUNT) {
        // wparam = heap *Result owned by the handler (T141 relay sign-in/out
        // ran on a detached thread; this is the GUI-thread landing).
        if (wparam != 0) {
            const res: *RelayAccountRow.Result = @ptrFromInt(wparam);
            RelayAccountRow.onResult(app, res);
        }
        return 0;
    }

    if (msg == ActivityMonitor.WM_APP_ACTIVITY_DIALED) {
        // wparam = heap *DialResult owned by the handler. It lands HERE and not
        // on the panel's own window on purpose: DestroyWindow discards a
        // window's queued messages, and a discarded dial would leak the
        // connection it just opened (T295).
        if (wparam != 0) {
            const res: *ActivityMonitor.DialResult = @ptrFromInt(wparam);
            ActivityMonitor.onDialed(res);
        }
        return 0;
    }

    if (msg == SessionRoster.WM_APP_CHOOSER_SESSIONS) {
        // wparam = heap *Result owned by the handler. Same reason it lands here
        // rather than on the chooser's own window as the two above: a chooser
        // that closed first would have this message DISCARDED with its queue,
        // leaking the roster it carries (T318).
        if (wparam != 0) {
            const res: *SessionRoster.Result = @ptrFromInt(wparam);
            MachineChooser.onSessions(app, res);
        }
        return 0;
    }

    if (msg == ActivityMonitor.WM_APP_ACTIVITY_MACHINES) {
        // wparam = heap *MachineListResult owned by the handler, landing here
        // rather than on the panel for the same reason as the dial above
        // (T296).
        if (wparam != 0) {
            const res: *ActivityMonitor.MachineListResult = @ptrFromInt(wparam);
            ActivityMonitor.onMachines(res);
        }
        return 0;
    }

    if (msg == WM_APP_AGENT_UPGRADE_CHECK) {
        // T147: a persistent window closed; the agent may have just gone idle,
        // which is the safe moment to adopt a newer bundled build.
        app.refreshLocalAgentIfStale("last persistent window closed");
        return 0;
    }

    if (msg == WM_APP_AGENT_LINK_DOWN) {
        // T145: the shared local-agent link dropped. Posted from the
        // connection's reader thread; every decision happens here, on the GUI
        // thread, after a settle window (a down edge is not proof of death).
        app.beginAgentSettleWatch();
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

    // Debounced session-layout write (T89f): the timer fired after the last
    // layout/frame/title mutation settled — capture the topology and persist.
    if (msg == w32.WM_TIMER and wparam == LAYOUT_SYNC_TIMER_ID) {
        _ = w32.KillTimer(hwnd, LAYOUT_SYNC_TIMER_ID);
        app.syncSessionLayout();
        return 0;
    }

    // Timer ID 5: local-agent link settle watch (T145). Self-re-arming (a
    // periodic SetTimer), killed by `endAgentSettleWatch` once a verdict lands.
    if (msg == w32.WM_TIMER and wparam == AGENT_WATCH_TIMER_ID) {
        app.tickAgentSettleWatch();
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
