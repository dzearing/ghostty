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

const AgentIntegration = @import("AgentIntegration.zig");
const AgentIntegrationsDialog = @import("AgentIntegrationsDialog.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const DarkMode = @import("DarkMode.zig");
const PathInstaller = @import("PathInstaller.zig");
const IpcRegistry = @import("IpcRegistry.zig");
const IpcServer = @import("IpcServer.zig");
const MachineChooser = @import("MachineChooser.zig");
const SessionRoster = @import("SessionRoster.zig");
const SessionCpuProbe = @import("SessionCpuProbe.zig");
const RestoreAllRelay = @import("RestoreAllRelay.zig");
const ActivityMonitor = @import("ActivityMonitor.zig");
const RelayAccountRow = @import("RelayAccountRow.zig");
const ShareMachineRow = @import("ShareMachineRow.zig");
const brush_cache = @import("brush_cache.zig");
const system_colors = @import("system_colors.zig");
const RenameDialog = @import("RenameDialog.zig");
const BannerDialog = @import("BannerDialog.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const PaneView = @import("PaneView.zig");
const Surface = @import("Surface.zig");
const ViewerPane = @import("ViewerPane.zig");
const ViewerNavBar = @import("ViewerNavBar.zig");
const ViewerFeedbackBar = @import("ViewerFeedbackBar.zig");
const ViewerFindBar = @import("ViewerFindBar.zig");
const webview2 = @import("webview2.zig");
const Window = @import("Window.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const LocalAgent = @import("LocalAgent.zig");
const MachineConnectionPool = @import("MachineConnectionPool.zig");
const remote_connection = @import("../../remote/connection.zig");
const protocol = @import("../../remote/protocol.zig");
const tab_color = @import("tab_color.zig");
const clipboard_open = @import("clipboard_open.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const update_check = @import("update_check.zig");
const install_location = @import("install_location.zig");
const update_apply = @import("update_apply.zig");
const update_install = @import("update_install.zig");
const update_progress = @import("update_progress.zig");
const UpdateProgress = @import("UpdateProgress.zig");
const install_prepare = @import("install_prepare.zig");
const install_maintenance = @import("install_maintenance.zig");
const install_restart = @import("install_restart.zig");
const utf16_text = @import("utf16_text.zig");
const tray_notify = @import("tray_notify.zig");
const orphan_notify = @import("orphan_notify.zig");
const session_layout = @import("session_layout.zig");
const layout_refresh = @import("layout_refresh.zig");
const layout_cost = @import("layout_cost.zig");
const layout_blobs = @import("layout_blobs.zig");
const restore_frame = @import("restore_frame.zig");
const window_placement = @import("window_placement.zig");
const agent_recovery = @import("agent_recovery.zig");
const restore_retry = @import("restore_retry.zig");
const RemoteReconnect = @import("RemoteReconnect.zig");
const agent_upgrade = @import("agent_upgrade.zig");
const job_escape = @import("job_escape.zig");
const relaunch_guard = @import("relaunch_guard.zig");
const job_spawn = @import("job_spawn.zig");
const restart_manager = @import("restart_manager.zig");
const url_scheme = @import("url_scheme.zig");
const provenance = @import("provenance.zig");
const host_defaults = @import("host_defaults.zig");
const gui_pump = @import("gui_pump.zig");
const startup_error = @import("startup_error.zig");
const surface_reap = @import("surface_reap.zig");
const surface_window_role = @import("surface_window_role.zig");
const resize_paint = @import("resize_paint.zig");
const window_active = @import("window_active.zig");
const translate_policy = @import("translate_policy.zig");
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
/// WM_APP+7/+8 and +30/+31 are AgentIntegration's prompt/done messages;
/// +32 is AgentIntegrationsDialog's worker update.)
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

/// Posted to `msg_hwnd` by `reapSurfaceHwnd` to destroy a closed pane's child
/// HWND (T681). wparam = the HWND. It lands here rather than being called
/// inline in `Surface.deinit` so the `DestroyWindow` runs from the top of the
/// message loop, with the renderer thread joined and the WGL context already
/// deleted — see `surface_reap.zig` for the whole rationale and for the
/// two-factor check that keeps a recycled handle safe.
const WM_APP_REAP_SURFACE: u32 = w32.WM_APP + 26;

/// Posted by the long-unattached session check's worker thread (T534):
/// wparam = *OrphanRosterResult (heap; ownership transfers to the handler).
/// The GUI thread evaluates the roster and may show the forgotten-session
/// balloon. (+27..+32 are taken — see MachineConnectionPool / SessionCpuProbe /
/// AgentIntegration / AgentIntegrationsDialog. +34 is ShareMachineRow's.)
const WM_APP_ORPHAN_ROSTER: u32 = w32.WM_APP + 33;

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

/// Timer ID (on `msg_hwnd`) for the in-place recovery RETRY (T723). Armed only
/// after a recovery aborted with no reachable agent, one-shot per attempt, and
/// disarmed the moment the link is back or the schedule is spent.
const AGENT_RETRY_TIMER_ID: usize = 7;

/// Timer ID (on `msg_hwnd`) for the periodic session-layout REFRESH (T922).
/// Repeating, armed once at startup while persistence is on.
///
/// The manifest carries each pane's persisted SCREEN, and a screen goes stale
/// the moment the pane prints anything — but every other write trigger is a
/// TOPOLOGY mutation (a split, a tab, a rename, a banner). So a pane that has
/// simply been running for an hour had its screen recorded as of the last time
/// a window moved, and a reboot brought THAT back: on D78's restore path the
/// user reads an hour-old screen instead of the error the crash interrupted.
/// This tick re-captures; `session_layout.writeIfChanged` keeps an idle
/// terminal from paying for it.
const LAYOUT_REFRESH_TIMER_ID: usize = 10;

/// Poll cadence for that refresh, and the quiet window it waits for. Each tick
/// is one lock-free atomic read per pane (`Termio.remoteAppliedOffset`), so an
/// idle terminal pays nothing measurable and never writes; the capture happens
/// on the FIRST tick that finds the panes quiet again, which is what keeps a
/// build's whole output from costing a manifest rewrite every two seconds.
const LAYOUT_REFRESH_MS: u32 = 2_000;

/// …and the ceiling on that "wait for quiet" (T922; see `layout_refresh`).
/// Matched to the local agent's own ring-snapshot cadence (`session.zig`, 30
/// ticks of 1s): the two halves of what a reboot brings back, the app's screen
/// and the agent's ring, are then recorded at the same worst-case rhythm.
const LAYOUT_REFRESH_MAX_MS: i64 = 30_000;

/// How long a BOUNDED capture waits for one pane's renderer mutex before it
/// carries that pane's cached screen forward instead (T1311).
///
/// Small on purpose: this path only ever runs while panes are flooding, and the
/// question it asks is "is this pane's lock free right now-ish?", not "please
/// queue me behind the IO thread". A pane that says no is retried on the next
/// tick two seconds later, so nothing is lost by asking briefly.
const LAYOUT_CAPTURE_LOCK_NS: u64 = 2 * std.time.ns_per_ms;

/// How long the whole bounded pass may spend re-dumping screens before it
/// leaves the rest of the panes for the next tick.
///
/// HALF a display frame, out of the frame `layout_cost` judges the whole sync
/// against — because the capture is not the whole sync. Serializing the
/// manifest and mirroring it to the agent follow it on the same thread and cost
/// several milliseconds of their own, and the deadline is checked BEFORE a pane
/// is started rather than enforced during it, so the pass can also overrun by
/// one pane's dump plus its `LAYOUT_CAPTURE_LOCK_NS`. Half a frame leaves room
/// for both and still lands the whole sync inside one frame; measured at eight
/// flooded panes it lands around 6 ms mean.
const LAYOUT_CAPTURE_BUDGET_MS: i64 = @intCast(layout_cost.frame_budget_us / std.time.us_per_ms / 2);

/// Timer ID 9: the periodic long-unattached session check (T534). Armed at
/// startup with a short first fire, then re-armed at the full cadence on every
/// tick. (Timer 8 is the orphan balloon's icon-cleanup timer, defined beside
/// the other NOTIF_* timer ids below.)
const ORPHAN_CHECK_TIMER_ID: usize = 9;

/// Timer ID (on `msg_hwnd`) for the DEFERRED launch restore (T976). Armed only
/// when the launch restore ran before the local agent was dialable and had to
/// carry windows forward; one-shot per attempt, and it disarms itself the
/// moment the carried set is empty or the schedule in `restore_retry.zig` runs
/// out. (Timer 10 is the layout refresh, defined above.)
const RESTORE_RETRY_TIMER_ID: usize = 11;

/// Timer ID 12: the periodic "am I still the build that is on disk?" check
/// (T1205). Repeating. Windows cannot replace a running image, so an upgrade
/// leaves every open window running the OLD exe — normal, expected, and until
/// this timer completely invisible: the user installed 1.35.0, kept typing
/// into a window from the day before, and had no way to find out. (Timer 13 is
/// this notification's icon-cleanup timer, beside the other NOTIF_* ids.)
const STALE_BUILD_CHECK_TIMER_ID: usize = 12;

/// How often to re-ask. A minute is far below the granularity a person cares
/// about ("did my update take?") and far above anything that costs: one
/// `stat` of a file already in the OS cache.
const STALE_BUILD_CHECK_MS: u32 = 60_000;

/// Timer ID 14: the periodic "has a newer release been published?" check
/// (T1171). Repeating. The automatic update check used to run exactly once,
/// at launch, which is the wrong cadence for a terminal that stays open for
/// days: a release published at 08:00 reached the window the user was typing
/// in only when they next restarted it. Timer 12 above answers the sibling
/// question - "is a newer build already on THIS disk?" - and the two are
/// deliberately separate, because one is about the network and one is about
/// a file.
const UPDATE_RECHECK_TIMER_ID: usize = 14;

/// How often the running app re-asks the release channel. Ten minutes is a
/// tick, not a fetch: `shouldRunUpdateCheck` still throttles the network to
/// one request per `UPDATE_CHECK_INTERVAL_SECS`, so this only bounds how long
/// a published release waits AFTER the throttle expires. Overridable with
/// GHOZTTY_UPDATE_RECHECK_MS, which exists for test\win32\update-check.ps1 -
/// an acceptance script cannot wait ten minutes for the second tick.
const UPDATE_RECHECK_MS: u32 = 10 * 60 * 1000;

/// How soon after launch to ask the first time. An MSI that closes and
/// restarts us through the Restart Manager (T1204) lands here with a file
/// newer than the process by a hair — inside `image_freshness.tolerance_ns`,
/// so it is correctly NOT stale — while a script that swapped the exe under a
/// long-lived window is caught on the first tick.
const STALE_BUILD_FIRST_MS: u32 = 15_000;

/// Window class for the top-level container (GDI painting, no CS_OWNDC).
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyWindow");

/// Window class for terminal surfaces (OpenGL via WGL, needs CS_OWNDC).
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyTerminal");

/// The search bar's and the command palette's surface and field fills, keyed
/// on the color they were made for so a theme flip replaces the GDI object
/// instead of painting through a stale one (T563). Process lifetime, GUI
/// thread only - the same contract every other `CachedBrush` here has.
var popup_bg_brush: brush_cache.CachedBrush = .{};
var popup_field_brush: brush_cache.CachedBrush = .{};

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

/// Window keys (`session_layout.windowKey`, gpa-owned dupes) the launch
/// restore left in the manifest WITHOUT a positive adjudication (T590): the
/// agent was unspawnable, the liveness probe never landed, or the rebuild
/// itself failed. `syncSessionLayout` carries the on-disk entries for these
/// keys forward through every wholesale rewrite — the win32 translation of
/// Mac's "agent unreachable; keeping N manifest entries for next launch" —
/// so one bad launch cannot erase the only surviving record of the layout.
/// A key leaves the set when its window is live again (`mergeCarried`
/// adjudicates it) or when persistence is turned off. Never populated by a
/// window the agent answered about and disowned: those stay dropped, which is
/// what keeps the manifest from becoming immortal.
carried_layout_windows: std.StringHashMapUnmanaged(void) = .empty,

/// The connection `pushed_layouts` describes. A reconnect (agent restart, link
/// recovery) means the peer's store is not the one we tracked, so the map is
/// dropped and the whole topology re-pushed rather than assumed present.
pushed_layouts_conn: ?*remote_connection.Connection = null,

/// Decode scratch for the WP-D3 screen snapshot of the leaf currently being
/// restored (T109). ONE buffer, not one per leaf: `restoreAttachOverride` hands
/// out a borrowed slice that `Surface.init` consumes synchronously (the surface
/// is constructed before the next leaf's override is built), so the next call
/// can free it and reuse the slot. That keeps the peak cost at a single pane's
/// screen no matter how many windows a restore rebuilds. Freed in `deinit`.
restore_snapshot_scratch: ?[]u8 = null,

/// Identity of the last session-layout body this process wrote to disk (T922),
/// so a refresh tick that decides to capture can still skip the write when the
/// capture turns out identical — a repaint that lands back on the same screen,
/// or a pane whose output never reached the snapshotted region. Null until the
/// first write.
layout_body_id: ?session_layout.BodyId = null,

/// T922 refresh bookkeeping, all in the units the tick compares: the summed
/// agent-stream offset across every pane, which moves iff some pane applied
/// output. `seen` is the last poll, `captured` the poll the manifest on disk
/// reflects, `last_write_ms` when that capture happened.
layout_refresh_seen: u64 = 0,
layout_refresh_captured: u64 = 0,
layout_refresh_last_write_ms: i64 = 0,

/// The BOUNDED round (T1311), which is what a forced capture becomes while the
/// panes are still printing. `round_ms` is when the current round began — a
/// pane whose screen was dumped after it is current for this round — and
/// `incomplete` says the last pass ran out of frame with panes still owing one,
/// which makes the next tick force again instead of waiting out another
/// ceiling. `deadline_ms` is the wall clock the in-flight pass must stop
/// re-dumping at, and `deferred` counts the panes it carried forward; both are
/// scratch owned by `tickLayoutRefresh` for the duration of one capture.
layout_round_ms: i64 = 0,
layout_round_incomplete: bool = false,
layout_capture_deadline_ms: i64 = std.math.maxInt(i64),
layout_capture_deferred: usize = 0,

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

/// True while a long-unattached session check (T534) has a worker thread out
/// reading the local agent's roster; at most one is ever in flight.
orphan_check_inflight: bool = false,

/// Version text of the newest win-v release the update check found (heap,
/// app allocator). A click on the update balloon offers to install that
/// release, and opens its GitHub page when there is nothing installable.
/// Null until an update notification has been shown.
update_latest_ver: ?[]u8 = null,

/// The `.msi` asset URL for `update_latest_ver` (heap, app allocator), or
/// null when that release published no installable package. This is what
/// separates "install it for me" from the old notify-only behavior: with no
/// asset there is nothing to download, and the balloon falls back to opening
/// the release page (T1178).
update_asset_url: ?[]u8 = null,

/// Path of the verified package already downloaded for `update_latest_ver`
/// (heap, app allocator). Set by the background download that `auto-update =
/// download` performs, so a click on the balloon installs immediately rather
/// than starting a fetch the user has to wait through.
update_staged_msi: ?[]u8 = null,

/// True while a download worker is out. At most one is ever in flight: a
/// second click while the first is still fetching must not start a second
/// 40MB transfer into the same staged path.
update_download_inflight: bool = false,

/// True once the stale-build balloon (T1205) has been shown for the build
/// currently on disk. Notify ONCE and then be quiet: the condition is
/// permanent until the user restarts, and a notification that reappears every
/// minute is not a notice, it is nagging. About still says so every time it
/// is opened, and a NEWER build landing on disk re-arms this (the file's
/// mtime is what is remembered, not merely "we told them once").
stale_build_notified_ns: i128 = 0,

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

/// One warm connection per REMOTE machine (T461), shared by every feature that
/// talks to that machine's agent — today the chooser's session roster and its
/// Kill. The remote-side counterpart to `local_agent`'s shared connection, and
/// app-scoped for the same reason: a connection keyed by the endpoint outlives
/// the transient UI that asked for it only as long as somebody holds a lease, but
/// the TABLE of them must not belong to any one dialog.
machine_pool: MachineConnectionPool = undefined,

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

/// How many in-place recovery RETRIES have already run since the last abort
/// (T723), indexing `agent_recovery.retry_delays_ms`. Reset to 0 by any
/// successful re-dial, so a later, unrelated agent death gets the full schedule
/// again rather than inheriting a spent one.
agent_retry_attempts: usize = 0,

/// True while `AGENT_RETRY_TIMER_ID` is armed. Also the "a recovery is already
/// pending" flag: while it is set, a fresh settle watch would only race the
/// retry to the same re-dial.
agent_retry_armed: bool = false,

/// How many DEFERRED launch-restore retries have already run (T976), indexing
/// `restore_retry.retry_delays_ms`. Only ever counts up: the deferred pass runs
/// once per launch, so a spent schedule is a launch that gave up, not a state
/// to recover from.
restore_retry_attempts: usize = 0,

/// True while `RESTORE_RETRY_TIMER_ID` is armed (T976).
restore_retry_armed: bool = false,

/// Non-zero while a destructive agent refresh is tearing the app's terminals
/// down and rebuilding them (T229). The app deliberately has zero — or
/// half-built — windows in that window of time, and it must not read that as
/// "the user closed the last window" and quit itself out from under the rebuild
/// the confirmation dialog promised. A COUNT, not a flag, so a nested refresh
/// cannot clear the outer one's guard.
agent_refresh_depth: usize = 0,

/// True once the user has declined a destructive agent restart in this app run
/// (T147; since T1056 that means the PROTOCOL-SKEW confirmation, the only one
/// left). It suppresses further PROMPTS only — the silent idle refresh still
/// happens the next time no sessions are live. Per-run by design: the next
/// launch asks again, because by then the sessions in question are new ones.
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
    DarkMode.apply(
        config.@"window-theme",
        config.background,
        Window.systemUsesLightTheme(),
    );

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
        .local_agent = LocalAgent.init(alloc),
        .machine_pool = MachineConnectionPool.init(alloc),
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

    // T992: every clipboard open in this process claims this window. It is the
    // one HWND with the right lifetime — a surface can be freed while a copy is
    // in flight, and an open that names no window at all excludes nobody, which
    // makes the copy's empty-then-set pair non-atomic. See clipboard_open.zig.
    clipboard_open.setDefaultOwner(self.msg_hwnd);

    // T188: from here on, a long blocking GUI-thread operation can keep serving
    // IPC by calling `gui_pump.pump()` — session restore is the one that needs
    // it. Installed as soon as the window it drains exists, and taken down in
    // `deinit` before that window is destroyed.
    gui_pump.install(self, pumpIpcHook);

    // T118: an app launched from inside ANOTHER instance's pane inherits that
    // instance's `$GHOZTTY_IPC_SOCKET` (running `zig-out\bin\ghoztty.exe` from
    // a pane of the installed release is the everyday case). That value names
    // someone else's endpoint, so drop it here — before the bind below, before
    // the AlreadyRunning forward, and before we spawn anything that would
    // inherit our environment. Every pane we open is baked with OUR endpoint
    // explicitly (see Surface.init), so nothing depends on the inherited one.
    _ = internal_os.unsetenv(apprt.ipc.socket_env);

    // Bind the IPC pipe and become the master instance. If another process
    // already owns the pipe, forward a `new-window` request to it and exit
    // (Mac single-app behavior).
    self.ipc_server = @as(IpcServer, undefined);
    self.ipc_server.?.init(self) catch |err| switch (err) {
        error.AlreadyRunning => {
            log.info("another instance owns the IPC pipe; forwarding new-window", .{});
            // T487: forward what THIS launch asked for, not a bare verb. A
            // null payload threw away `-e`/`--command` and the working
            // directory after they were parsed — exit 0, nothing logged, the
            // command just never ran (the same silent-drop shape T406 fixed
            // on the restore path). The process exits on the next line, so
            // the argv is never freed.
            const fwd_args = forwardedNewWindowArgs(
                alloc,
                self.config.@"initial-command",
                self.config.@"working-directory",
            ) catch null;
            // T1022: and say WHICH build asked. Two copies of one lineage
            // (the installed release and the Desktop portable) share this
            // endpoint by design, so the window the user gets belongs to
            // whichever was started first — D79 chose that, and named the
            // shortcut-looks-wrong case as its one con. The running instance
            // compares this identity with its own and is loud when they
            // differ; when they match it stays silent, because two copies of
            // the same build are indistinguishable and the join is invisible
            // on purpose.
            // T1023: and ASK first when the build that owns the endpoint is
            // not the build the user started. D79's mitigation says two
            // different versions must not quietly become one app; they cannot
            // become two apps either (the local agent and the saved layout are
            // shared on purpose, so they survive an upgrade), so what the
            // mitigation buys the user is the CHOICE — take the window from the
            // build already running, or back out and quit it first.
            var id = launchIdentity(alloc);
            if (self.handoffChoice(alloc, &id) == .cancel) {
                log.info("launch cancelled: a different build owns the endpoint", .{});
                std.process.exit(0);
            }
            const ok = internal_os.ipc_client.sendActionWithHandoff(
                alloc,
                "new-window",
                fwd_args,
                id,
            ) catch false;
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
    // Clear what a previous update left behind (T1178): the staged package,
    // the applier copy, and any image that had to be renamed aside because a
    // PTY holder was still running out of it. BEFORE the check, and on this
    // thread: a sweep racing the check's background pre-download would delete
    // the package it just staged. It walks two small directories and treats
    // every failure as "not yet, try next launch".
    update_install.sweep(self.core_app.alloc);

    self.startUpdateCheck(.automatic);

    // First long-unattached session check (T534) shortly after launch — late
    // enough that the launch restore has re-attached everything it is going
    // to. Each tick re-arms at the full cadence, so only the first fire is
    // early.
    if (self.msg_hwnd) |mh| {
        const first = @min(self.orphanCheckIntervalMs(), 60_000);
        _ = w32.SetTimer(mh, ORPHAN_CHECK_TIMER_ID, first, null);
    }

    // "Is a newer build sitting on disk?" (T1205). Repeating, so it needs no
    // re-arm; the first fire is deliberately soon after launch, because the
    // window most likely to be stale is one that has been open a long time
    // and the answer must not wait a full cadence to arrive.
    if (self.msg_hwnd) |mh| {
        _ = w32.SetTimer(mh, STALE_BUILD_CHECK_TIMER_ID, STALE_BUILD_FIRST_MS, null);
    }

    // "Has a newer release been published?" (T1171). Repeating, so it needs no
    // re-arm. The launch check above is the first ask; without this timer it
    // was also the last, and a window left open across a publish never learned
    // there was anything to take.
    if (self.msg_hwnd) |mh| {
        _ = w32.SetTimer(mh, UPDATE_RECHECK_TIMER_ID, self.updateRecheckIntervalMs(), null);
    }

    // Keep each pane's persisted SCREEN current (T922). Repeating, so it needs
    // no re-arm; started here rather than on the first mutation because a pane
    // that never triggers one is exactly the pane whose screen goes stalest.
    if (self.config.@"session-persistence") {
        if (self.msg_hwnd) |mh|
            _ = w32.SetTimer(mh, LAYOUT_REFRESH_TIMER_ID, LAYOUT_REFRESH_MS, null);
    }

    // Keep the `ghoztty` CLI resolvable from any shell (T70). Background
    // thread; only acts when running from the canonical install dir.
    PathInstaller.ensureOnPathAsync();

    // Tell the shell that `ghoztty://` links belong to this build (T695).
    // Background thread; a debug build registers `ghoztty-debug://` only, so a
    // dev instance never takes over the user's links.
    url_scheme.registerAsync();

    // One-time agent-integration offer + Claude plugin migration (T870).
    // Background thread; same canonical-install gate as the PATH self-heal.
    AgentIntegration.checkOnLaunchAsync(self);
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
    if (!window_active.shouldForwardFocus(
        w32.activation(),
        @intFromPtr(root),
    )) return;
    _ = w32.SetFocus(hwnd);
}

/// Hand a closed pane's child HWND over to be destroyed from the top of the
/// message loop (T681).
///
/// `Surface.deinit` cannot call `DestroyWindow` on its own stack — the first
/// win32 commit recorded a segfault inside OPENGL32.dll's window-destruction
/// hook when it did — and leaving the handle for the parent window's teardown
/// leaks one USER object per closed pane for the life of the app. USER objects
/// are a per-process quota (10k) and this box's sessions run for days, so the
/// leak matters even though each close leaks only one.
///
/// The caller has already cleared `GWLP_USERDATA`, which is both what stops
/// `surfaceWndProc` touching the freed `*Surface` and the second factor
/// `performSurfaceReap` checks before it destroys anything.
///
/// With no `msg_hwnd` there is nowhere to defer TO — that is only true after
/// `terminate` has torn the app down, at which point every window is going
/// away anyway, so the handle is simply left to Win32.
pub fn reapSurfaceHwnd(self: *App, hwnd: w32.HWND) void {
    const msg = self.msg_hwnd orelse return;
    _ = w32.PostMessageW(msg, WM_APP_REAP_SURFACE, @intFromPtr(hwnd), 0);
}

/// Perform a queued `WM_APP_REAP_SURFACE`: destroy the pane window, but only
/// once the two facts `surface_reap.reapable` asks for still hold. By the time
/// this runs the handle may have been freed with its parent window and even
/// recycled onto something else — see `surface_reap.zig`.
fn performSurfaceReap(hwnd: w32.HWND) void {
    var cls: [40]u16 = undefined;
    const n = w32.GetClassNameW(hwnd, &cls, cls.len);
    const class_matches = n > 0 and
        std.mem.eql(u16, cls[0..@intCast(n)], TERMINAL_CLASS_NAME);
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (!surface_reap.reapable(.{
        .class_matches = class_matches,
        .userdata = @bitCast(userdata),
    })) return;

    _ = w32.DestroyWindow(hwnd);
}

/// Re-run the split layout of the window owning the given terminal-surface
/// HWND — used when a pane's banner strip height changed (T101 collapse/
/// expand) so the terminal band under the strip grows/shrinks to match.
/// Resolves the Surface via GWLP_USERDATA with the same guard as
/// surfaceWndProc; silently no-ops for anything else.
/// Does the user want in-window motion at all? `SPI_GETCLIENTAREAANIMATION`
/// is the OS switch behind Settings ▸ Accessibility ▸ Visual effects ▸
/// "Animation effects" ("animate controls and elements inside windows"), and
/// turning it off means every chrome animation degrades to the instant state
/// swap it animates between (T58 decision 5, T149).
///
/// ONE resolution site on purpose: an accessibility preference honored by
/// some of the chrome and not the rest is worse than one honored by none of
/// it, because the half that keeps moving is the half the setting exists for.
/// Fails OPEN — an SPI call that errors leaves animations on, which is the
/// default every Windows install ships with.
pub fn clientAreaAnimationsEnabled() bool {
    var enabled: i32 = 1;
    if (w32.SystemParametersInfoW(
        w32.SPI_GETCLIENTAREAANIMATION,
        0,
        @ptrCast(&enabled),
        0,
    ) == 0) return true;
    return enabled != 0;
}

pub fn relayoutOwnerWindow(hwnd: w32.HWND) void {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return;
    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
    if (surface.hwnd == null or surface.hwnd.? != hwnd) return;
    // Live: this is the banner expanding or collapsing under the user's
    // click, so the pane below it resizes while they watch (T1031).
    surface.parent_window.layoutSplitsLive();
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

/// True when the `GHOZTTY_STARTUP_FAIL` test seam names `which` (T1177).
///
/// Debug builds only, like every other seam in this file: a stray environment
/// variable must never be able to stop a user's terminal from opening. It
/// forces a startup state that is real in the field (a half-laid-down install,
/// a window class that would not register) and that an acceptance script has no
/// other way to build — there is no supported way to make window creation fail
/// from outside the process.
fn startupFailSeam(self: *App, which: []const u8) bool {
    if (comptime !build_config.is_debug) return false;
    const alloc = self.core_app.alloc;
    const value = std.process.getEnvVarOwned(alloc, "GHOZTTY_STARTUP_FAIL") catch return false;
    defer alloc.free(value);
    if (!std.mem.eql(u8, value, which)) return false;
    log.warn("startup failure seam active: {s} (debug test hook)", .{which});
    return true;
}

/// Present a fatal startup failure to the user (T1177), called by
/// `main_ghostty.zig` when any step of startup returns an error.
///
/// A free function with no `self`, because most of the failures it reports
/// happen BEFORE an App exists — `App.create` running out of memory is one of
/// them. `main_ghostty` discovers it with `@hasDecl`, which is how the win32
/// apprt gets a dialog while the apprts with a console keep stderr.
pub fn reportStartupFailure(stage: []const u8, err: anyerror) void {
    startup_error.reportFatal(stage, err);
}

/// Tell the user, once, when the app came up but a startup precondition did
/// NOT (T1177). Today that is exactly one condition: the session agent is not
/// in the installation, which is what a half-laid-down install looks like from
/// in here (T1175). The terminal works without it, so this is a notice rather
/// than a refusal — but silence was the defect, and "session persistence
/// silently stopped existing" is precisely the kind of thing the user has to
/// discover the hard way otherwise.
fn showStartupWarningsIfAny(self: *App, owner: ?*Window) void {
    const failure = self.local_agent.resolveFailure() orelse return;
    if (failure != .agent_binary_missing) return;

    var buf: [startup_error.max_message]u8 = undefined;
    const text = startup_error.describeDegraded(
        &buf,
        "Ghoztty's session agent is missing from this installation.",
        "Terminals will still open, but they will not survive quitting or " ++
            "restarting Ghoztty, and the session chooser will be empty.",
        "Reinstall Ghoztty to restore it.",
    );
    startup_error.reportDegraded(
        self,
        if (owner) |w| w.hwnd else null,
        if (owner) |w| w.scale else 1.0,
        std.unicode.utf8ToUtf16LeStringLiteral("Session persistence unavailable"),
        text,
    );
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

/// True while `pumpIpc` is draining, so a handler that reaches a pump point of
/// its own (an IPC-created window that resolves the agent, say) does not recurse
/// into the drain it is already inside.
var ipc_pumping: bool = false;

/// The `gui_pump` hook (T188). `ctx` is the `*App`.
fn pumpIpcHook(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx orelse return));
    self.pumpIpc();
}

/// Serve every IPC request already marshalled to the GUI thread, then return.
///
/// Deliberately narrow: `PeekMessageW` is filtered to `WM_APP_IPC` on the
/// message-only window, so this never dispatches paint, focus, timer or input
/// messages and therefore cannot re-enter a WndProc the way a general nested
/// pump would (which is the T48 deadlock's shape). `IpcServer.deinit` runs the
/// identical drain for the same reason.
///
/// Called from the blocking stretches of startup — see `gui_pump` — where the
/// alternative is a listener thread parked on `Pending.done` for the whole
/// restore while its client waits.
pub fn pumpIpc(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    if (ipc_pumping) return;
    ipc_pumping = true;
    defer ipc_pumping = false;

    var msg: w32.MSG = undefined;
    while (w32.PeekMessageW(&msg, hwnd, WM_APP_IPC, WM_APP_IPC, w32.PM_REMOVE) != 0) {
        if (msg.wParam != 0) {
            const pending: *IpcServer.Pending = @ptrFromInt(msg.wParam);
            IpcServer.serveOnGuiThread(pending);
        }
    }
}

/// T487: the `+new-window` argv a second launch forwards to the running
/// instance, rebuilt from this launch's parsed config so `ghoztty -e cmd…`
/// and `--working-directory` survive the handoff. The cwd is forwarded
/// whenever it resolved to a path: config finalize resolves the Windows CLI
/// default to the launching directory (T506), so this matches both a first
/// launch and `+new-window`'s auto-inserted `--working-directory`. Returns
/// null when there is nothing to say, preserving the bare-verb wire shape.
/// Allocations are owned by the caller; the forward path exits the process
/// immediately after sending, so it never frees them.
/// This process's build identity, for the launch handoff (T1022).
///
/// The exe path is the only part that has to be looked up at runtime, and a
/// failure to resolve it is not a reason to skip the handoff: the version and
/// commit alone still answer "is this the build you started?", and the notice
/// degrades to naming the build without a path. Allocated from `alloc`, which
/// is the app allocator — the process exits a few statements later, so nothing
/// frees it.
fn launchIdentity(alloc: Allocator) internal_os.ipc_handoff.Identity {
    return .{
        .version = launchVersion(alloc),
        .commit = launchCommit(alloc),
        .exe = std.fs.selfExePathAlloc(alloc) catch "",
    };
}

/// DEBUG-ONLY test seam (T1023): the version/commit a launch REPORTS.
///
/// Two copies of one lineage at different commits is the case the prompt
/// exists for, and there is no way to produce it from outside — the only exe
/// an acceptance script has is the one build in `zig-out`, and both sides of
/// the handoff would report it. Setting these makes the launch claim to be a
/// different build without pretending to be one anywhere else, which is
/// exactly the input the comparison takes. Gated on the build mode rather than
/// on an env value alone, so a release build has no such lever at all.
const version_override_env = "GHOZTTY_HANDOFF_VERSION";
const commit_override_env = "GHOZTTY_HANDOFF_COMMIT";

fn launchVersion(alloc: Allocator) []const u8 {
    return envOverride(alloc, version_override_env) orelse provenance.version;
}

fn launchCommit(alloc: Allocator) []const u8 {
    return envOverride(alloc, commit_override_env) orelse provenance.commit;
}

fn envOverride(alloc: Allocator, name: []const u8) ?[]const u8 {
    if (comptime !build_config.is_debug) return null;
    const value = std.process.getEnvVarOwned(alloc, name) catch return null;
    if (value.len == 0) {
        alloc.free(value);
        return null;
    }
    return value;
}

/// What a losing launch does with the window it asked for (T1023).
const HandoffChoice = enum {
    /// Open it in the instance that already owns the endpoint.
    join,
    /// Open nothing: the user would rather quit that instance and start this
    /// copy themselves.
    cancel,
};

/// Test/automation hook: `join` skips the T1023 prompt and hands off exactly
/// as the build before it did. An acceptance script that drives a deliberate
/// mismatch has no one to answer a modal dialog, and a scripted launch must
/// never be able to block on one.
const handoff_prompt_env = "GHOZTTY_HANDOFF_PROMPT";

/// Ask the user before handing this launch's window to a DIFFERENT build, and
/// report what they chose. `id` is this launch's identity; on an answered
/// prompt it is marked `prompted` so the running instance does not repeat the
/// fact as a balloon.
///
/// Everything here fails toward the old behavior. Same build, no answer from
/// the running instance, a request to skip the prompt, or an allocation
/// failure all return `.join` — the case this exists for is rare (it needs two
/// copies of one lineage at different commits), and a launch that cannot ask
/// must still open a window rather than die on the question.
fn handoffChoice(
    self: *App,
    alloc: Allocator,
    id: *internal_os.ipc_handoff.Identity,
) HandoffChoice {
    if (std.process.getEnvVarOwned(alloc, handoff_prompt_env)) |mode| {
        defer alloc.free(mode);
        if (std.mem.eql(u8, mode, "join")) return .join;
    } else |_| {}

    // T1120: the morning delivery relaunches this exe with nobody in front of
    // it, and it kills only the instances running from the install dir — so a
    // Desktop-portable or share copy of the SAME lineage keeps the endpoint,
    // which is precisely the version mismatch this prompt exists for. Asking
    // there is the worst shape available: this process shows a modal and then
    // exits, so the terminal the delivery promised to bring back never appears
    // until somebody clicks. Join instead, which is the non-destructive answer
    // and the one this whole function already fails toward.
    if (self.unattendedRefreshActive()) {
        log.info("launch of a different build during an unattended refresh; joining without asking", .{});
        return .join;
    }

    const running = internal_os.ipc_client.queryIdentity(alloc) orelse return .join;
    const prompt = (internal_os.ipc_handoff.mismatchPrompt(alloc, id.*, running) catch
        return .join) orelse return .join;
    log.warn(
        "launch of a different build: launcher={s} running={s}; asking",
        .{ id.version, running.version },
    );

    const title_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, prompt.title) catch return .join;
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, prompt.text) catch return .join;
    const ok_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, prompt.ok_label) catch return .join;
    const cancel_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, prompt.cancel_label) catch return .join;

    // There is no window to own the dialog — this process lost the race before
    // it created one — so it centers on the screen and takes the foreground it
    // is entitled to as the process the user just started. The scale comes from
    // the message-only window rather than the 1.0 an ownerless caller would
    // otherwise pass, so the dialog is sized for the display it lands on.
    const dpi: f32 = @floatFromInt(if (self.msg_hwnd) |h| w32.GetDpiForWindow(h) else 96);
    const result = ConfirmDialog.show(self, null, @max(1.0, dpi / 96.0), null, .{
        .title = title_w.ptr,
        .text = text_w,
        .icon = .warning,
        // The affirmative is the non-destructive one — it opens a window and
        // touches nothing else — so Enter takes it and Escape backs out.
        .default_cancel = false,
        .ok_label = ok_w,
        .cancel_label = cancel_w,
    });
    if (result != .ok) return .cancel;
    id.prompted = true;
    return .join;
}

fn forwardedNewWindowArgs(
    alloc: Allocator,
    initial_command: ?configpkg.Config.Command,
    working_directory: ?configpkg.Config.WorkingDirectory,
) Allocator.Error!?[]const [:0]const u8 {
    var args: std.ArrayList([:0]const u8) = .empty;
    errdefer args.deinit(alloc);

    if (working_directory) |wd| {
        if (wd.value()) |path| {
            try args.append(alloc, try std.fmt.allocPrintSentinel(
                alloc,
                "--working-directory={s}",
                .{path},
                0,
            ));
        }
    }

    if (initial_command) |cmd| switch (cmd) {
        // `-e argv…` parses to `.direct`; the IPC verb's own `-e` carries an
        // argv the server execs without shell wrapping, so the shape maps 1:1.
        .direct => |argv| {
            try args.append(alloc, try alloc.dupeZ(u8, "-e"));
            for (argv) |arg| try args.append(alloc, try alloc.dupeZ(u8, arg));
        },
        // `initial-command = <string>` is shell-expanded; `--command=` is the
        // verb's shell-expanded form.
        .shell => |command| try args.append(alloc, try std.fmt.allocPrintSentinel(
            alloc,
            "--command={s}",
            .{command},
            0,
        )),
    };

    if (args.items.len == 0) {
        args.deinit(alloc);
        return null;
    }
    return try args.toOwnedSlice(alloc);
}

test "forwardedNewWindowArgs: nothing to forward stays a bare verb (T487)" {
    const testing = std.testing;
    try testing.expect(try forwardedNewWindowArgs(testing.allocator, null, null) == null);
    // `.inherit` and `.home` resolve to no path — still a bare verb.
    try testing.expect(try forwardedNewWindowArgs(testing.allocator, null, .inherit) == null);
    try testing.expect(try forwardedNewWindowArgs(testing.allocator, null, .home) == null);
}

test "forwardedNewWindowArgs: -e argv and the launch cwd survive the handoff (T487)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = (try forwardedNewWindowArgs(
        alloc,
        .{ .direct = &.{ "pwsh", "-NoExit", "-Command", "echo hi" } },
        .{ .path = "D:\\proj" },
    )).?;
    try testing.expectEqual(@as(usize, 6), args.len);
    try testing.expectEqualStrings("--working-directory=D:\\proj", args[0]);
    try testing.expectEqualStrings("-e", args[1]);
    try testing.expectEqualStrings("pwsh", args[2]);
    try testing.expectEqualStrings("-NoExit", args[3]);
    try testing.expectEqualStrings("-Command", args[4]);
    try testing.expectEqualStrings("echo hi", args[5]);
}

test "forwardedNewWindowArgs: a shell-form initial-command maps to --command (T487)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = (try forwardedNewWindowArgs(alloc, .{ .shell = "htop -d 5" }, null)).?;
    try testing.expectEqual(@as(usize, 1), args.len);
    try testing.expectEqualStrings("--command=htop -d 5", args[0]);
}

pub fn run(self: *App) !void {
    // T406: a launch command (`ghoztty -e cmd…`, or `initial-command` in the
    // config) is something the user asked for on THIS launch; the windows a
    // restore rebuilds are what they left behind last time. Neither may
    // silently swallow the other, so when both are present we do BOTH — and
    // the requested window is created FIRST, before restore, for a mechanical
    // reason: core `Surface.init` hands `initial-command` to whichever surface
    // is `app.first`, and a restored pane would otherwise eat it and have
    // nowhere to run it (it ATTACHes to a session that already exists, so the
    // command would vanish with no window, no error and no log line — the
    // whole defect).
    const launch_command = self.config.@"initial-command" != null;
    var startup_window: ?*Window = null;
    if (launch_command) {
        startup_window = try self.createWindow(.{});
        log.info("launch command: opened its window before session restore", .{});
    }

    // Session re-attach (T89f2): if a layout manifest survives and its agent
    // sessions are still alive, rebuild those windows and SUPPRESS the default
    // blank window. Any failure (no manifest, persistence off, agent gone,
    // all-dead) returns false and we open one blank window as usual.
    const restored = self.restoreSessionLayout();

    // Create the initial Window container with one tab. Route through
    // createWindow so the session-persistence injection (T89d) applies to the
    // startup window exactly as it does to every later `new_window`. Skipped
    // when restore already opened at least one window, and when the launch
    // command above already opened one.
    //
    // The TEST SEAM (T1177, debug builds only) suppresses this last window so
    // the guard below meets the real state it exists for: a launch that ends
    // with nothing on screen. Seaming HERE rather than short-circuiting the
    // guard is the point — an acceptance run then exercises the guard, the
    // error, `main_ghostty`'s reporter and the dialog, which is the whole
    // chain that used to be a silent exit. Unset (every real launch) leaves
    // the code below byte-identical.
    const force_no_window = self.startupFailSeam("no-window");
    if (startup_window == null and !restored and !force_no_window) {
        startup_window = try self.createWindow(.{});
    }

    // Restore's windows were created after the launch-command window and are
    // sitting on top of it. The command is what the user just typed, so give it
    // the foreground back.
    if (launch_command and restored) {
        if (startup_window) |w| {
            if (w.hwnd) |hwnd| _ = w32.SetForegroundWindow(hwnd);
        }
    }

    // T1177: a launch that reaches this point with NO WINDOW is the silent
    // startup failure, and it is silent precisely because nothing errored — the
    // restore reported success, or a window was created and never materialized,
    // and the process then sat in a message loop with nothing on screen. There
    // is no error to propagate here, so this MAKES one: `main_ghostty` turns it
    // into a dialog naming the failure instead of an exit nobody sees.
    if (self.windows.items.len == 0) {
        log.err("startup finished with no window; refusing to run headless", .{});
        return error.NoStartupWindow;
    }

    // T1204: tell Windows to bring this terminal BACK after an installer
    // closes it. An upgrade over a running Ghoztty is the normal case — it is
    // what the in-app updater does every time — and without this registration
    // the Restart Manager's best outcome is "your terminal is gone now".
    // Registered here, after a window exists, so a launch that never got that
    // far is not a thing Windows would relaunch into the same failure.
    restart_manager.register();

    // Surface config load diagnostics once at startup (T69). After the
    // first window exists so the dialog has an owner to center on; the
    // dialog pumps its own modal loop, so startup messages (paints, IPC)
    // keep flowing while it is up. Owner is the blank startup window, or the
    // first restored window when restore suppressed it.
    const diag_owner: ?*Window = startup_window orelse
        (if (self.windows.items.len > 0) self.windows.items[0] else null);
    if (diag_owner) |w| self.showConfigErrorsIfAny(&self.config, w);
    self.showStartupWarningsIfAny(diag_owner);

    // T145: start watching the shared local-agent link, now that the startup
    // windows (restored or blank) have resolved a connection. From here a dead
    // agent is NOTICED and the local windows rebuild in place, instead of the
    // panes sitting frozen until the user quits and relaunches.
    self.installLocalAgentWatch();
    gui_pump.pump();

    // T147: restore has settled, so this is a safe moment to adopt a newer
    // bundled agent build. Idle ⇒ silent restart; live sessions ⇒ the mandatory
    // confirmation. This is what un-sticks an agent that survived several app
    // upgrades on an old binary (the upgrade script deliberately never kills
    // it), instead of waiting for a reboot.
    self.refreshLocalAgentIfStale("launch restore finished");

    // T188: the last pump before the loop takes over. Everything above this
    // line runs with the loop not yet started, so without it a request that
    // arrived during the final startup steps would wait on them too.
    gui_pump.pump();

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
                // A viewer pane's address field (T159): Enter navigates,
                // Escape reverts — the same main-loop routing every popup
                // edit uses, because an EDIT control never sees these keys
                // itself. Everything else falls through so typing works.
                // The pane-scoped viewer chords (T161: ctrl+r reload,
                // ctrl+d/ctrl+l re-select the address) are live in the
                // field too — the chords belong to the PANE, and the bar is
                // inside the pane.
                if (vk == w32.VK_RETURN or vk == w32.VK_ESCAPE) {
                    if (ViewerNavBar.owningEdit(msg.hwnd.?)) |nav| {
                        if (nav.handleEditKey(vk)) continue :loop;
                    }
                }
                if (ViewerNavBar.owningEdit(msg.hwnd.?)) |nav| {
                    if (nav.handleEditChord(vk)) continue :loop;
                }
                // A viewer pane's feedback composer (T635): its RichEdit eats
                // Escape and Ctrl+Enter itself, so the composer's own chords
                // are routed here exactly like the address field's. Everything
                // else — typing, arrows, Ctrl+A/C/V/X/Z — falls through to the
                // control, which is the whole point of using a real one.
                if (ViewerFeedbackBar.owningEdit(msg.hwnd.?)) |bar| {
                    if (bar.handleKey(vk)) continue :loop;
                    if (bar.handleChord(vk)) continue :loop;
                }
                // A viewer pane's find field (T1184): Enter/Shift-Enter step
                // matches and Escape closes the card, none of which an EDIT
                // delivers itself. The pane-scoped chords are live in the field
                // too, for the same reason they are in the address bar — they
                // belong to the PANE, and the card is inside the pane.
                if (ViewerFindBar.owningEdit(msg.hwnd.?)) |bar| {
                    if (bar.handleEditKey(vk)) continue :loop;
                    if (bar.handleEditChord(vk)) continue :loop;
                }
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

        // Alt chords arrive as WM_SYSKEYDOWN, which the intercept above never
        // sees. The viewer address field's alt+d (T161, the Windows-native
        // address-bar alias) is the one such chord we claim; everything else
        // falls through so alt-menu access keeps working.
        if (msg.message == w32.WM_SYSKEYDOWN and msg.hwnd != null) {
            if (ViewerNavBar.owningEdit(msg.hwnd.?)) |nav| {
                if (nav.handleEditChord(@intCast(msg.wParam & 0xFFFF))) continue :loop;
            }
            if (ViewerFeedbackBar.owningEdit(msg.hwnd.?)) |bar| {
                if (bar.handleChord(@intCast(msg.wParam & 0xFFFF))) continue :loop;
            }
            if (ViewerFindBar.owningEdit(msg.hwnd.?)) |bar| {
                if (bar.handleEditChord(@intCast(msg.wParam & 0xFFFF))) continue :loop;
            }
        }

        // A click landing on a viewer address field (T159): the browser
        // omnibox rule. A focus-GAINING click selects the whole address, and
        // the selection has to land AFTER the EDIT's own click tracking —
        // which runs through mouse-up and ends by placing a caret, wiping any
        // selection applied earlier (the exact ordering Mac's
        // `selectAddressWhenClickCompletes` exists for). Noting the DOWN and
        // posting from the UP is what gets the order right; the messages
        // still dispatch to the EDIT normally.
        if ((msg.message == w32.WM_LBUTTONDOWN or msg.message == w32.WM_LBUTTONUP) and
            msg.hwnd != null)
        {
            if (ViewerNavBar.owningEdit(msg.hwnd.?)) |nav| {
                if (msg.message == w32.WM_LBUTTONDOWN) nav.noteClickDown() else nav.noteClickUp();
            }
            if (ViewerFindBar.owningEdit(msg.hwnd.?)) |bar| {
                if (msg.message == w32.WM_LBUTTONDOWN) bar.noteClickDown() else bar.noteClickUp();
            }
        }

        // Skip TranslateMessage for keyboard events on terminal surface
        // windows: handleKeyEvent (and sendWin32InputEvent in Win32 input
        // mode) calls ToUnicode directly, and TranslateMessage's internal
        // ToUnicodeEx mutates the same per-queue dead-key state — racing
        // it broke dead-key composition on ABNT2 (`~`+`a` → `~a`). Edit
        // controls (search, palette, tab rename) still need it, and so do
        // VK_PROCESSKEY (IME) and VK_PACKET (injected text) — the rules and
        // their reasons live in `translate_policy.zig`, which is where they
        // are asserted (T222). The only thing that needs the OS here is the
        // target window's class.
        const skip_translate = blk: {
            // The class lookup is a syscall on the message loop's hot path, so
            // it runs only for the messages the policy can answer "skip" for
            // at all — every other message translates unconditionally.
            if (!translate_policy.isKeyMessage(msg.message)) break :blk false;
            const class_atom: u16 = if (msg.hwnd) |h|
                @truncate(w32.GetClassLongW(h, w32.GCW_ATOM))
            else
                0;
            break :blk translate_policy.skipTranslate(
                msg.message,
                msg.wParam,
                class_atom,
                self.terminal_class_atom,
            );
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
    if (self.msg_hwnd) |hwnd| {
        _ = w32.KillTimer(hwnd, LAYOUT_SYNC_TIMER_ID);
        _ = w32.KillTimer(hwnd, LAYOUT_REFRESH_TIMER_ID); // T922
    }
    // T145: no in-place recovery during teardown — the windows are about to go.
    self.endAgentSettleWatch();
    // T976: nor a deferred restore — a window built mid-teardown would be one
    // the quit path has already walked past.
    self.cancelRestoreRetry();
    // The authoritative last write before the app goes away, so the screens
    // it records must be the ones the user was actually looking at (T412).
    self.syncSessionLayout(.fresh);

    if (self.update_latest_ver) |v| {
        self.core_app.alloc.free(v);
        self.update_latest_ver = null;
    }
    if (self.update_asset_url) |v| {
        self.core_app.alloc.free(v);
        self.update_asset_url = null;
    }
    if (self.update_staged_msi) |v| {
        self.core_app.alloc.free(v);
        self.update_staged_msi = null;
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

    // T188: no more pumping from here. The IPC drain below owns the remaining
    // in-flight requests, and the window it peeks is about to be destroyed.
    gui_pump.uninstall();

    // Stop the IPC listener while msg_hwnd is still alive (a request could
    // be mid-marshal; deinit joins the listener thread).
    if (self.ipc_server) |*server| {
        server.deinit();
        self.ipc_server = null;
    }

    if (self.msg_hwnd) |hwnd| {
        // T992: stop handing this window out as the clipboard owner before it
        // is destroyed — a stale handle there would fail every later open.
        clipboard_open.setDefaultOwner(null);
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

    // Same ordering rule for the remote machines' warm connections (T461): every
    // chooser is gone with its window above, so every lease is released and this
    // is only mopping up an entry a borrow still held.
    self.machine_pool.deinit();

    // Free the IPC target registry (keys are owned).
    self.ipc_registry.deinit(alloc);

    // Layout-blob bookkeeping (T334): the agent KEEPS the blobs on purpose —
    // they are what makes this machine restorable after we exit — so this frees
    // only our own key strings.
    self.clearPushedLayouts();
    self.pushed_layouts.deinit(alloc);
    self.pushed_layouts_conn = null;

    // T590: the carried-window keys are gpa-owned dupes of manifest keys.
    self.clearCarriedLayouts();
    self.carried_layout_windows.deinit(alloc);

    // T109: the last restored leaf's decoded screen. Every surface that
    // borrowed it is long gone by now (they dupe what they keep).
    if (self.restore_snapshot_scratch) |s| {
        alloc.free(s);
        self.restore_snapshot_scratch = null;
    }

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

/// Register `target` under `name`, without caring whether an incumbent kept
/// it. See IpcRegistry.register.
pub fn ipcRegister(self: *App, name: []const u8, target: IpcTarget) Allocator.Error!void {
    _ = try self.ipcRegisterChecked(name, target);
}

/// Register `target` under `name` and report whether `target` actually holds
/// it afterwards (T121). Callers that RECORD the name — a window's
/// `ipc_name`, which `+list` reports as its `target` — must use this: a name
/// an incumbent kept would otherwise be advertised by a window it does not
/// route to.
pub fn ipcRegisterChecked(
    self: *App,
    name: []const u8,
    target: IpcTarget,
) Allocator.Error!IpcRegistry.RegisterResult {
    return self.ipc_registry.register(self.core_app.alloc, self.windows.items, name, target);
}

/// Reserve an ADOPTED window name so the auto allocator can never re-mint it.
/// See IpcRegistry.reserveWindowName (T121).
pub fn ipcReserveWindowName(self: *App, name: []const u8) void {
    self.ipc_registry.reserveWindowName(name);
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

/// The summed agent-stream offset across every terminal pane (T922).
///
/// A cursor, not a quantity: it moves iff some pane applied output, which is
/// exactly the event that invalidates the persisted screens and is invisible to
/// every other layout-write trigger. Summing is safe for this use — offsets only
/// ever grow, so the sum only ever grows, and two panes cannot cancel out. Each
/// read is a lock-free atomic (`Remote.appliedOffset`), so the whole poll costs
/// one load per pane.
fn paneStreamOffsetSum(self: *App) u64 {
    var sum: u64 = 0;
    for (self.windows.items) |win| {
        if (win.tab_count == 0) continue;
        for (0..win.tab_count) |ti| {
            for (win.tab_trees[ti].nodes) |node| {
                const pane = switch (node) {
                    .leaf => |p| p,
                    .split => continue,
                };
                const surface = pane.surface() orelse continue;
                if (!surface.core_surface_ready) continue;
                sum +%= surface.core_surface.io.remoteAppliedOffset() orelse 0;
            }
        }
    }
    return sum;
}

/// One tick of the session-layout REFRESH (T922): persist the panes' screens
/// again if — and only if — some pane has painted since the last time they were
/// persisted. The decision itself is `layout_refresh.decide`, where it is unit
/// tested; this owns reading the panes and the clock.
fn tickLayoutRefresh(self: *App) void {
    if (!self.config.@"session-persistence") return;

    const now = self.paneStreamOffsetSum();
    const ms = std.time.milliTimestamp();
    const action = layout_refresh.decide(.{
        .now = now,
        .seen = self.layout_refresh_seen,
        .captured = self.layout_refresh_captured,
        .since_write_ms = ms - self.layout_refresh_last_write_ms,
        .max_wait_ms = LAYOUT_REFRESH_MAX_MS,
        .round_incomplete = self.layout_round_incomplete,
    });
    self.layout_refresh_seen = now;
    switch (action) {
        .idle, .wait => return,
        .capture, .capture_bounded => {},
    }

    self.layout_refresh_captured = now;
    self.layout_refresh_last_write_ms = ms;

    if (action == .capture) {
        // The panes went quiet, so re-dumping every screen IS this tick's job
        // and it pays the idle price (T412).
        self.layout_round_incomplete = false;
        self.syncSessionLayout(.fresh);
        return;
    }

    // The ceiling fired while the panes are still printing (T1311). A full
    // re-dump here is the ~991 ms freeze the user feels every 30 seconds, so
    // this round spends ONE FRAME on the panes it has not refreshed yet and
    // finishes on the following ticks. A round is only over once a pass
    // deferred nobody.
    if (!self.layout_round_incomplete) self.layout_round_ms = ms;
    self.layout_capture_deadline_ms = ms + LAYOUT_CAPTURE_BUDGET_MS;
    self.layout_capture_deferred = 0;
    self.syncSessionLayout(.fresh_bounded);
    self.layout_round_incomplete = self.layout_capture_deferred > 0;
    self.layout_capture_deadline_ms = std.math.maxInt(i64);
}

/// Capture the live window/tab/split topology and atomically persist it to the
/// session-layout manifest (T89f). Best-effort. When persistence is off the
/// stale manifest is deleted so a later launch never restores it.
///
/// `screens` says whether the panes' SCREENS are re-dumped or carried forward
/// (T412) — see `ScreenCapture`. Every caller whose trigger is a topology or
/// frame change passes `.reuse`; only the T922 refresh and the quit/shutdown
/// flush pay for `.fresh`.
pub fn syncSessionLayout(self: *App, screens: ScreenCapture) void {
    const gpa = self.core_app.alloc;
    if (!self.config.@"session-persistence") {
        session_layout.clear(gpa);
        // Forget what was on disk: if persistence comes back on, the next
        // capture must write even when it happens to serialize to the same
        // bytes as the file this just deleted.
        self.layout_body_id = null;
        // Turning persistence off is the user asking to FORGET — the carried
        // unrestored windows (T590) included, or they would resurrect if it
        // came back on.
        self.clearCarriedLayouts();
        // Persistence just went off (or was never on): the agent must not keep
        // offering this machine's windows for restore either.
        self.pushLayoutBlobs(.{});
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var pending = false;
    // T412: this whole function runs on the UI thread, and the capture below
    // takes every pane's renderer mutex. Measure it — a drag end and the T922
    // refresh both land here, so a cost nobody watches is a stutter nobody can
    // attribute. `Timer.start` cannot fail on a platform with a monotonic
    // clock; a box without one simply records zeros rather than losing the sync.
    var cost: layout_cost.Sample = .{
        .fresh_screens = screens != .reuse,
        .mode = switch (screens) {
            .fresh => .fresh,
            .fresh_bounded => .bounded,
            .reuse => .reuse,
        },
    };
    var timer: ?std.time.Timer = std.time.Timer.start() catch null;
    const captured = self.captureSessionLayout(
        arena_state.allocator(),
        &pending,
        &cost.snapshot_bytes,
        screens,
    ) catch |err| {
        log.warn("session-layout capture failed err={}", .{err});
        return;
    };
    cost.panes = captured.paneCount();
    // Only a bounded pass can defer anything; the counter is its scratch, so
    // reading it for any other sync would report the last round's leftovers.
    cost.deferred_screens = if (screens == .fresh_bounded) self.layout_capture_deferred else 0;
    if (timer) |*t| cost.capture_us = t.lap() / std.time.ns_per_us;
    // T590: a wholesale rewrite must not erase the windows the launch restore
    // could not adjudicate (agent unspawnable, probe never landed) — re-read
    // their on-disk entries and carry them forward. `carried_parsed` owns the
    // borrowed strings, so it must outlive the write AND the blob push.
    var carried_parsed: ?session_layout.Parsed = null;
    defer if (carried_parsed) |*p| p.deinit();
    var windows = captured.windows;
    if (self.carried_layout_windows.count() > 0) {
        if (loadLocalManifest(gpa)) |p| carried_parsed = p;
        const manifest: []const session_layout.Window =
            if (carried_parsed) |p| p.value.windows else &.{};
        windows = session_layout.mergeCarried(
            arena_state.allocator(),
            gpa,
            captured.windows,
            manifest,
            &self.carried_layout_windows,
        ) catch |err| blk: {
            log.warn("session-layout carry-forward failed err={}", .{err});
            break :blk captured.windows;
        };
    }
    const file: session_layout.File = .{ .windows = windows };
    cost.wrote = session_layout.writeIfChanged(gpa, file, &self.layout_body_id);
    if (timer) |*t| cost.write_us = t.lap() / std.time.ns_per_us;
    // The blob push is NOT gated on that write. It reconciles against what this
    // process has already pushed, so an unchanged topology costs nothing — but
    // it is also how a re-established agent link gets the whole set back, and
    // that recovery must not wait for the layout to happen to change.
    self.pushLayoutBlobs(file);
    if (timer) |*t| cost.push_us = t.lap() / std.time.ns_per_us;
    self.reportLayoutCost(cost);

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

/// Emit what the sync just cost (T412).
///
/// Two levels on purpose. **Debug** carries every sync, which is what an
/// on-box measurement reads (`test\win32\layout-capture-cost.ps1`) — a Debug
/// build logs to stderr, and the debug level never reaches the file sink, so
/// this cannot grow a user's `ghoztty.log`. **Info** carries only the syncs
/// that missed the frame budget, so a field report of "dragging the window
/// hitches" has the number in the log the user already has, and a healthy app
/// still writes nothing. The shape is `key=value` throughout so a harness can
/// parse it without a format the prose would drift from.
fn reportLayoutCost(self: *App, cost: layout_cost.Sample) void {
    _ = self;
    const fmt = "session-layout sync total_us={d} capture_us={d} write_us={d} " ++
        "push_us={d} panes={d} snapshot_bytes={d} wrote={} fresh_screens={} " ++
        "mode={s} deferred_screens={d}";
    const args = .{
        cost.totalUs(),
        cost.capture_us,
        cost.write_us,
        cost.push_us,
        cost.panes,
        cost.snapshot_bytes,
        cost.wrote,
        cost.fresh_screens,
        @tagName(cost.mode),
        cost.deferred_screens,
    };
    if (cost.overBudget()) {
        log.info(fmt ++ " OVER-BUDGET", args);
    } else {
        log.debug(fmt, args);
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

/// Remember one manifest window the launch restore is leaving behind WITHOUT a
/// positive adjudication (T590), so `syncSessionLayout` carries its on-disk
/// entry forward instead of erasing it. Best-effort: an allocation failure
/// costs the carry, never the restore.
fn carryUnrestoredWindow(self: *App, win: session_layout.Window) void {
    const gpa = self.core_app.alloc;
    const key = session_layout.windowKey(win);
    const gop = self.carried_layout_windows.getOrPut(gpa, key) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, key) catch {
            _ = self.carried_layout_windows.remove(key);
            return;
        };
    }
}

/// Drop the carried-window keys (T590). Persistence went off, or the app is
/// tearing down.
fn clearCarriedLayouts(self: *App) void {
    const gpa = self.core_app.alloc;
    var it = self.carried_layout_windows.iterator();
    while (it.next()) |entry| gpa.free(entry.key_ptr.*);
    self.carried_layout_windows.clearRetainingCapacity();
}

const FrameCapture = struct {
    frame: ?session_layout.Frame = null,
    maximized: bool = false,
};

/// The primary display's full height in pixels, or null when the metric is
/// unreadable. Recorded next to every captured frame (T623): it is the one
/// number a Mac reader needs to flip our top-down y into Cocoa's bottom-up y
/// (`y' = h_primary - y - h`), and the same field arriving FROM a Mac blob is
/// what lets `mac_layout_blob` flip in the other direction. Full frame height
/// on purpose, not the work area — the coordinate spaces are anchored at the
/// primary's full frame, and a work-area flip is off by the taskbar.
fn primaryScreenHeight() ?i32 {
    const h = w32.GetSystemMetrics(1); // SM_CYSCREEN
    return if (h > 0) h else null;
}

/// Read a window's outer rect + maximized flag (T89f). For a maximized OR
/// minimized window this is the RESTORED rect (`rcNormalPosition`) so restore
/// comes back to a sane size — the same split `persistPlacement` (T85) uses.
/// `GetWindowRect` on an iconic window returns the −32000,−32000 caption-stub
/// rect, which a later restore would faithfully rebuild as an offscreen sliver
/// (T106). Null frame ⇒ the query failed / no hwnd; restore falls back to
/// config.
///
/// The manifest's frames are SCREEN coordinates throughout (that is what
/// `restore_frame`'s monitor arithmetic and `SetWindowPos` both mean), so the
/// `rcNormalPosition` arm converts out of the placement struct's own workspace
/// coordinates on the way past — see `window_placement.zig`. A no-op on a
/// bottom-taskbar desktop; a taskbar's thickness of drift on any other.
fn captureFrame(hwnd_opt: ?w32.HWND) FrameCapture {
    const hwnd = hwnd_opt orelse return .{};
    const maximized = w32.IsZoomed(hwnd) != 0;
    var r: w32.RECT = undefined;
    if (maximized or w32.IsIconic(hwnd) != 0) {
        var wp: w32.WINDOWPLACEMENT = undefined;
        wp.length = @sizeOf(w32.WINDOWPLACEMENT);
        if (w32.GetWindowPlacement(hwnd, &wp) == 0) return .{ .maximized = maximized };
        r = wp.rcNormalPosition;
        const screen = window_placement.toScreen(.{
            .x = r.left,
            .y = r.top,
            .w = r.right - r.left,
            .h = r.bottom - r.top,
        }, workspaceOrigin());
        return .{
            .frame = .{ .x = screen.x, .y = screen.y, .w = screen.w, .h = screen.h },
            .maximized = maximized,
        };
    }
    if (w32.GetWindowRect(hwnd, &r) == 0) return .{};
    return .{
        .frame = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top },
        .maximized = maximized,
    };
}

/// The primary monitor's work-area origin — the offset between screen and
/// `WINDOWPLACEMENT` workspace coordinates. An unreadable work area answers
/// `(0, 0)`, which makes both conversions the identity: replaying the recorded
/// numbers unchanged beats shifting them by a guess.
fn workspaceOrigin() window_placement.Origin {
    var work: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (w32.SystemParametersInfoW(w32.SPI_GETWORKAREA, 0, @ptrCast(&work), 0) == 0) return .{};
    return .{ .x = work.left, .y = work.top };
}

/// Capture one leaf's restore metadata: the agent session id to re-ATTACH to
/// (null when the pane is not agent-backed — it restores as an exited pane),
/// the pane's stable id (T113), the current title, the sticky banner (T422),
/// any registered IPC name, and the WP-D3 screen snapshot (T109).
/// `kind`/`viewer_location` stay null (reserved for viewer panes, T90h).
/// Strings dupe into `arena`.
fn captureLeaf(
    self: *App,
    arena: Allocator,
    surface: *Surface,
    budget: *session_layout.SnapshotBudget,
    screens: ScreenCapture,
) !session_layout.Leaf {
    const sid: ?[]const u8 = if (surface.core_surface_ready)
        surface.core_surface.remoteSessionId()
    else
        null;
    const ipc_name = if (surface.pane_view) |pv| self.ipcNameOf(.{ .pane = pv }) else null;
    const snap = try self.captureLeafSnapshot(arena, surface, budget, screens);
    return .{
        .session_id = if (sid) |s| try arena.dupe(u8, s) else null,
        .title = if (surface.getTitle()) |t| try arena.dupe(u8, t) else null,
        .ipc_name = if (ipc_name) |n| try arena.dupe(u8, n) else null,
        // T422: the banner's raw markdown source. App-side overlay state that
        // no PTY replay carries, so the manifest is its only way back.
        .banner = if (surface.banner_text) |b|
            (if (b.len > 0) try arena.dupe(u8, b) else null)
        else
            null,
        // Recorded unconditionally: it must survive even for a leaf with no
        // session (a fresh OPEN still keeps the id its shell was baked with).
        .pane_id = try arena.dupe(u8, surface.paneId()),
        .screen_snapshot = snap.data,
        .screen_snapshot_offset = snap.offset,
    };
}

/// One leaf's captured WP-D3 pair, base64'd and ready for the manifest. Both
/// null ⇒ this pane records no snapshot and restores the pre-T109 way.
const CapturedSnapshot = struct { data: ?[]const u8 = null, offset: ?u64 = null };

/// Whether a layout capture must re-dump each pane's SCREEN, or may carry
/// forward what the pane last recorded (T412).
///
/// The screen dump is the expensive half of a sync and it is paid on the UI
/// thread: measured on this box, eight panes printing continuously cost
/// **991 ms** per capture, because `sessionSnapshot` takes each pane's
/// `renderer_state.mutex` and the IO thread holds it while feeding output. Most
/// triggers do not need a fresh one — a window drag (T220), a tab, a split, a
/// rename, a banner all move the TOPOLOGY and leave the content alone — so they
/// ask for `.reuse` and the sync costs milliseconds instead.
///
/// `.fresh` belongs to the two triggers whose subject IS the screen: the T922
/// refresh WHEN THE PANES WENT QUIET (so it pays the idle price, not the
/// flooded one), and the quit / end-session flush, which is the authoritative
/// last write before the app goes away.
///
/// `.fresh_bounded` is the third one, and it exists because the refresh's
/// 30-second ceiling only ever fires while the panes are flooding — so that one
/// caller paid the 991 ms worst case every single time, which is a full second
/// of frozen window every half minute for anyone running a long build (T1311).
/// It re-dumps too, but it will not queue behind the IO thread and it will not
/// spend more than a frame: a pane whose renderer mutex is busy, or that the
/// pass ran out of time to reach, carries its cached screen forward and is
/// picked up by the next tick two seconds later. Every pane still gets a fresh
/// screen; the cost is spread over ticks instead of taken in one freeze.
///
/// Reuse is never "restore blank": a pane with nothing cached — one created
/// since the last full capture — falls through and captures fresh, bounded pass
/// or not.
const ScreenCapture = enum { fresh, fresh_bounded, reuse };

/// The WP-D3 snapshot pair for one terminal leaf (T109): the pane's structured
/// VT screen repaint, base64'd into `arena`, plus the absolute agent-stream byte
/// offset it reflects.
///
/// Both null is the normal, harmless answer for a local exec pane, a pane whose
/// core surface is not up yet, and a fresh pane that has applied nothing — the
/// core's `sessionSnapshot` decides all three, so this stays the one place that
/// asks. Both null is ALSO the answer when the capture errors or the budget
/// refuses the pane: a snapshot is an optimization on top of a restore that
/// already works, so it must never be able to fail the capture it rides in.
fn captureLeafSnapshot(
    self: *App,
    arena: Allocator,
    surface: *Surface,
    budget: *session_layout.SnapshotBudget,
    screens: ScreenCapture,
) !CapturedSnapshot {
    const none: CapturedSnapshot = .{};
    if (!surface.core_surface_ready) return none;

    // T412: reuse what this pane last recorded, when the trigger says the
    // content cannot have changed and there IS something to reuse. This is the
    // whole saving — see `Surface.last_snapshot`.
    if (screens == .reuse) {
        if (surface.last_snapshot != null) return self.reuseLeafSnapshot(arena, surface, budget);
    }

    // T1311: a bounded round re-dumps only what it still owes, and only while
    // it has frame left. Both tests need a cached screen to fall back on; a
    // pane without one always captures, however busy it is, because the
    // alternative is restoring it blank.
    if (screens == .fresh_bounded and surface.last_snapshot != null) {
        // Already refreshed since this round began: current, and re-dumping it
        // would spend the round's frame on a pane that owes nothing.
        if (surface.last_snapshot_ms >= self.layout_round_ms)
            return self.reuseLeafSnapshot(arena, surface, budget);
        if (std.time.milliTimestamp() >= self.layout_capture_deadline_ms) {
            self.layout_capture_deferred += 1;
            return self.reuseLeafSnapshot(arena, surface, budget);
        }
    }

    const snap = (if (screens == .fresh_bounded and surface.last_snapshot != null)
        surface.core_surface.sessionSnapshotTimeout(arena, LAYOUT_CAPTURE_LOCK_NS) catch |err| {
            if (err == error.WouldBlock) {
                // The IO thread is mid-chunk. Nothing is wrong and nothing is
                // lost: this pane keeps the screen it has and the next tick
                // asks again.
                self.layout_capture_deferred += 1;
                return self.reuseLeafSnapshot(arena, surface, budget);
            }
            log.warn("session-layout: screen snapshot failed err={}", .{err});
            return none;
        }
    else
        surface.core_surface.sessionSnapshot(arena) catch |err| {
            log.warn("session-layout: screen snapshot failed err={}", .{err});
            return none;
        }) orelse return none;
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(snap.data.len);
    if (!budget.take(encoded_len)) {
        log.info(
            "session-layout: screen snapshot dropped, over budget bytes={d}",
            .{encoded_len},
        );
        return none;
    }
    const buf = try arena.alloc(u8, encoded_len);
    const encoded = encoder.encode(buf, snap.data);

    // Remember it for the next reuse. The arena copy dies with this capture, so
    // the cache owns its own gpa-allocated bytes. A failed dupe simply leaves
    // the previous cache in place: this is an optimization, and it must never
    // be able to fail the capture it rides in.
    const gpa = self.core_app.alloc;
    if (gpa.dupe(u8, encoded)) |kept| {
        if (surface.last_snapshot) |old| gpa.free(old);
        surface.last_snapshot = kept;
        surface.last_snapshot_offset = snap.byte_offset;
        // T1311: which round this pane has been reached in.
        surface.last_snapshot_ms = std.time.milliTimestamp();
    } else |_| {}

    return .{ .data = encoded, .offset = snap.byte_offset };
}

/// Hand this pane's CACHED screen to the capture that asked for it, through the
/// arena and the snapshot budget (T412/T1311). The caller has already decided
/// that reusing is right; this owns only the copy.
fn reuseLeafSnapshot(
    self: *App,
    arena: Allocator,
    surface: *Surface,
    budget: *session_layout.SnapshotBudget,
) !CapturedSnapshot {
    _ = self;
    const cached = surface.last_snapshot orelse return .{};
    if (!budget.take(cached.len)) return .{};
    return .{
        .data = try arena.dupe(u8, cached),
        .offset = surface.last_snapshot_offset,
    };
}

/// Capture one VIEWER leaf's restore metadata (T90h). A viewer owns no agent
/// session, so `session_id` stays null and the four additive `kind`/`viewer_*`
/// fields carry everything a restore needs: what to navigate to, what Home
/// means, and which directory the pane came from.
///
/// The IPC name is captured for the same reason a terminal's is — a pane opened
/// as `+split --name=doc` must still answer to `doc` after a relaunch.
///
/// The TITLE is deliberately NOT captured: a viewer derives its name from its
/// location (file basename, or the document title a website reports), so
/// re-opening produces it again, and a recorded one would only go stale.
fn captureViewerLeaf(
    self: *App,
    arena: Allocator,
    pane: *PaneView,
) !session_layout.Leaf {
    const view = pane.viewer().?;
    const ipc_name = self.ipcNameOf(.{ .pane = pane });
    return .{
        .kind = session_layout.kind_viewer,
        .pane_id = try arena.dupe(u8, pane.paneId()),
        .ipc_name = if (ipc_name) |n| try arena.dupe(u8, n) else null,
        .viewer_location = if (view.location) |loc| try arena.dupe(u8, loc) else null,
        .viewer_home_location = if (view.home_location) |loc|
            try arena.dupe(u8, loc)
        else
            null,
        .viewer_origin_directory = if (view.origin_directory) |dir|
            try arena.dupe(u8, dir)
        else
            null,
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
fn captureSessionLayout(
    self: *App,
    arena: Allocator,
    pending: *bool,
    /// T412: where the snapshot bytes this capture spent are reported, for the
    /// cost line. Optional because only the debounced sync measures itself —
    /// the recovery path has one caller and no budget of its own to read.
    budget_used: ?*usize,
    screens: ScreenCapture,
) !session_layout.File {
    var windows: std.ArrayList(session_layout.Window) = .empty;
    // T109: one budget for the WHOLE file, spent in tree order, so the encoded
    // snapshots can never crowd the topology past `max_file_bytes` (which would
    // fail the next load outright and cost the user every window).
    var snapshot_budget: session_layout.SnapshotBudget = .{};
    defer if (budget_used) |out| {
        out.* = snapshot_budget.used;
    };
    for (self.windows.items, 0..) |win, wi| {
        if (win.is_quick_terminal) continue;
        if (win.remote_dialed != null) continue;
        if (win.tab_count == 0) continue;

        try windows.append(arena, try self.captureWindow(arena, win, wi, &snapshot_budget, pending, screens));
    }
    return .{ .windows = try windows.toOwnedSlice(arena) };
}

/// Capture ONE live window as a manifest entry: its tabs, their split-tree node
/// arrays (a 1:1 copy, so child handles carry over as indices), presentation
/// state and outer frame.
///
/// Split out of `captureSessionLayout` for T366: the remote-reconnect swap
/// rebuilds exactly one CROSS-MACHINE window, which that walk deliberately skips
/// — but the thing it needs captured is the same thing, node for node, and a
/// second capture written beside this one would drift the first time a field is
/// added to a leaf.
fn captureWindow(
    self: *App,
    arena: Allocator,
    win: *Window,
    wi: usize,
    snapshot_budget: *session_layout.SnapshotBudget,
    pending: *bool,
    screens: ScreenCapture,
) !session_layout.Window {
    const tabs = try arena.alloc(session_layout.Tab, win.tab_count);
    for (0..win.tab_count) |ti| {
        const tree = &win.tab_trees[ti];
        const nodes = try arena.alloc(session_layout.Node, tree.nodes.len);
        for (tree.nodes, 0..) |node, ni| {
            nodes[ni] = switch (node) {
                .leaf => |pane| leaf: {
                    // A viewer leaf has no agent session to capture: what
                    // restores it is its own location, so the four additive
                    // viewer fields ARE its restore metadata (T90h).
                    const surface = pane.surface() orelse break :leaf .{
                        .leaf = try captureViewerLeaf(self, arena, pane),
                    };
                    const leaf = try self.captureLeaf(arena, surface, snapshot_budget, screens);
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
            // The tab identity that survives this app run (T1048): what
            // in-place recovery pairs on, instead of counting positions in a
            // list that can move while the re-dial blocks.
            .uuid = try arena.dupe(u8, win.tabUuid(ti)),
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
    return .{
        .id = if (win.ipc_name) |n|
            try arena.dupe(u8, n)
        else
            try std.fmt.allocPrint(arena, "win-{d}", .{wi}),
        // The identity that survives this app run (T338). `id` above does
        // not: both spellings restart per process.
        .uuid = try arena.dupe(u8, win.layoutUuid()),
        .frame = frame_max.frame,
        // Only meaningful next to a frame it can convert; a frameless capture
        // records nothing rather than a stray metric.
        .primary_screen_height = if (frame_max.frame != null) primaryScreenHeight() else null,
        .maximized = frame_max.maximized,
        .title_override = if (win.title_override) |t| try arena.dupe(u8, t) else null,
        .ipc_name = if (win.ipc_name) |n| try arena.dupe(u8, n) else null,
        .active_tab = @intCast(win.active_tab),
        .tabs = tabs,
    };
}

/// Capture ONE window on its own, with a fresh snapshot budget (T366). The
/// remote-reconnect swap's entry into the shared capture above: it rebuilds a
/// single window, so the whole-file budget that keeps a manifest under
/// `max_file_bytes` has nothing to share with, and nothing here is written to
/// disk — the capture is consumed in the same call stack.
pub fn captureOneWindow(
    self: *App,
    arena: Allocator,
    win: *Window,
    index: usize,
) !session_layout.Window {
    var budget: session_layout.SnapshotBudget = .{};
    var pending = false;
    return self.captureWindow(arena, win, index, &budget, &pending, .fresh);
}

/// Bounded wall-clock budget for the launch-time liveness probe (`LIST_SESSIONS`
/// on the local agent). A healthy agent answers in single-digit ms; a wedged one
/// times out and restore proceeds treating liveness as UNKNOWN (attempt ATTACH,
/// never drop) rather than hanging startup.
pub const restore_probe_timeout_ns: u64 = 2000 * std.time.ns_per_ms;

/// How long launch restore will wait for the agent's ATTACHED flags to settle
/// before treating them as the truth (T851), and how long it sleeps between
/// re-probes. Only paid when a window this launch would restore reads as held
/// by a live viewer — i.e. after a crash whose cleanup has not landed yet, or
/// when a second instance of this lineage really is running. The budget is the
/// crash side's guarantee: it must comfortably outlast the agent noticing a
/// dead client's broken pipe (milliseconds in practice), because the cost of
/// being too impatient there is a launch that recovers nothing.
pub const restore_attach_settle_budget_ns: u64 = 2000 * std.time.ns_per_ms;
pub const restore_attach_settle_interval_ns: u64 = 200 * std.time.ns_per_ms;

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
pub const AttachProbe = struct {
    roster: ?remote_connection.OwnedSessions = null,
    set: ?std.StringHashMap(void) = null,
    /// The sessions a LIVE viewer is currently bound to, and which `set`
    /// therefore does NOT list (empty under `.attachable`). Borrows its keys
    /// from `roster` exactly as `set` does.
    held: ?std.StringHashMap(void) = null,

    /// What "attachable" means for THIS probe.
    ///
    /// `.attachable` is the historical rule: alive or a relaunchable tombstone.
    /// It is what the REMOTE paths keep, because across a network our own
    /// attach can outlive the connection that made it (a half-open TCP the peer
    /// has not reaped), so "the roster says attached" there is not evidence
    /// that somebody else is holding the session — `attached_elsewhere` and the
    /// steal retry adjudicate that case instead.
    ///
    /// `.skip_live_holders` additionally excludes every session the agent
    /// reports as ATTACHED (T851). The agent rebinds a session to the newest
    /// attach, so attaching to a session another running app already holds does
    /// not share it — it steals it, and the first app's pane becomes a frozen
    /// picture (T652's attached-is-not-alive, from the other side). Locally the
    /// evidence is good: an app that dies drops its named pipe, the agent's
    /// `detachAll` clears `bound` on the broken connection, and the flag is
    /// accurate again within milliseconds. The caller still owns the RACE
    /// (a relaunch that beats that cleanup) — see the settle loop in
    /// `restoreSessionLayout`.
    pub const Policy = enum { attachable, skip_live_holders };

    pub fn take(gpa: Allocator, conn: *remote_connection.Connection, policy: Policy) AttachProbe {
        // A TEST SEAM (T657), and it earns its place the way T469's two did.
        // The probe is what normally spares a stale leaf an ATTACH it cannot
        // win: a session the roster does not list gets `session_id = null` and
        // OPENs fresh. So the refused-ATTACH path this build now explains is
        // the one taken when the probe DID NOT LAND — a real production case
        // (a slow or wedged agent past `restore_probe_timeout_ns`), and one an
        // acceptance script otherwise cannot produce from a single tree
        // without racing the agent. Forcing the tri-state to UNKNOWN
        // reproduces exactly that branch, deterministically, with no other
        // behavior changed.
        //
        // Unset (every real launch) leaves the code below byte-identical.
        if (std.process.getEnvVarOwned(gpa, "GHOZTTY_RESTORE_PROBE_UNKNOWN")) |v| {
            defer gpa.free(v);
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                log.warn("session-restore: liveness probe forced UNKNOWN by GHOZTTY_RESTORE_PROBE_UNKNOWN", .{});
                return .{};
            }
        } else |_| {}
        const roster = conn.requestSessions(restore_probe_timeout_ns) catch |err| {
            log.warn("session-restore: liveness probe failed err={} (treating as unknown)", .{err});
            return .{};
        };
        return .fromRoster(gpa, roster, policy);
    }

    /// Build the probe from a roster that was ALREADY fetched, taking ownership
    /// of it. The remote-reconnect swap (T366) runs its `LIST_SESSIONS` on the
    /// redial worker — the whole point of that thread is that the GUI never
    /// blocks on a machine that may be gone — so by the time the decision is
    /// made the blocking half has happened. A null roster is a FAILED probe and
    /// keeps the tri-state's "unknown ⇒ attempt every leaf" meaning.
    pub fn fromRoster(
        gpa: Allocator,
        roster: ?remote_connection.OwnedSessions,
        policy: Policy,
    ) AttachProbe {
        var self: AttachProbe = .{ .roster = roster };
        const r = roster orelse return self;
        var m = std.StringHashMap(void).init(gpa);
        var h = std.StringHashMap(void).init(gpa);
        for (r.sessions) |sess| {
            if (!(sess.alive or sess.relaunchable)) continue;
            // A live viewer holds it: attaching would take it away from them
            // (T851). Recorded rather than merely dropped, so the caller can
            // tell "somebody else has this window" from "these sessions are
            // gone" — two drops that mean opposite things.
            if (policy == .skip_live_holders and sess.alive and sess.attached) {
                h.put(sess.id, {}) catch {};
                continue;
            }
            m.put(sess.id, {}) catch {};
        }
        self.set = m;
        self.held = h;
        return self;
    }

    /// The probe for a launch with NO agent connection (T398). An EMPTY set,
    /// deliberately not a null one: with no agent nothing CAN be attached, and
    /// that is KNOWN rather than unknown. The difference is the whole liveness
    /// tri-state — a null here would read as "probe failed, attempt every leaf"
    /// and rebuild terminal-only windows as walls of fresh shells, which is
    /// exactly what the never-all-dead rule refuses to do.
    fn agentless(gpa: Allocator) AttachProbe {
        return .{ .set = std.StringHashMap(void).init(gpa) };
    }

    /// What the restore helpers take: null ⇒ unknown ⇒ attempt every leaf.
    pub fn attachSet(self: *const AttachProbe) ?*const std.StringHashMap(void) {
        return if (self.set) |*m| m else null;
    }

    /// The sessions withheld because a live viewer holds them, or null when the
    /// probe never landed. Null and empty mean the same thing to every reader
    /// here (nothing is held), unlike `attachSet`.
    pub fn heldSet(self: *const AttachProbe) ?*const std.StringHashMap(void) {
        return if (self.held) |*m| m else null;
    }

    /// Whether the agent that answered still owns `id`. Tri-state, and the
    /// caller must keep it that way: null means the probe never landed, which
    /// is NOT "the session is gone" (T366 reads it as "attempt anyway").
    pub fn owns(self: *const AttachProbe, id: []const u8) ?bool {
        const m = self.set orelse return null;
        return m.contains(id);
    }

    pub fn deinit(self: *AttachProbe) void {
        if (self.set) |*m| m.deinit();
        if (self.held) |*m| m.deinit();
        if (self.roster) |*s| s.deinit();
    }
};

/// The session id one restored leaf will ATTACH to: its recorded id iff the
/// roster says attachable (alive or a relaunchable tombstone), or the roster is
/// UNKNOWN (probe failed, so attempt). Null for a viewer leaf (owns no
/// session), an id-less leaf (re-opens fresh), or a positively-gone session.
/// This is THE attach rule — `restoreAttachOverride` applies it and the T411
/// gap counter mirrors it, so the two cannot drift.
fn leafAttachSessionId(
    leaf: session_layout.Leaf,
    attach: ?*const std.StringHashMap(void),
) ?[]const u8 {
    if (leaf.isViewer()) return null;
    const sid = leaf.session_id orelse return null;
    if (attach) |a| {
        if (!a.contains(sid)) return null;
    }
    return sid;
}

/// Record every session id a restored window's leaves ATTACH to (T411): keys go
/// into `attached` (borrowed from the manifest arena, which outlives the
/// caller's use) and `panes` counts the attaching leaves. Fresh re-opens and
/// viewers are not counted — they hold no agent session, so they cannot
/// account for one.
fn collectAttachedLeaves(
    win: session_layout.Window,
    attach: ?*const std.StringHashMap(void),
    attached: *std.StringHashMap(void),
    panes: *usize,
) void {
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            const sid = leafAttachSessionId(leaf, attach) orelse continue;
            attached.put(sid, {}) catch {};
            panes.* += 1;
        }
    }
}

/// How many of the agent's LIVE sessions no restored pane attached to (T411).
/// A live pinned session outside the layout is invisible otherwise — the reaper
/// is (correctly) not allowed to touch it, so it holds a slot and a real shell
/// forever unless someone notices. Tombstones and exited sessions are not
/// counted: they are T278's problem, not a running process.
fn countUnattachedLive(
    sessions: []const remote_connection.OwnedSession,
    attached: *const std.StringHashMap(void),
) usize {
    var n: usize = 0;
    for (sessions) |s| {
        // A session another running app holds is not an orphan and never was
        // the gap this counter reports (T851): somebody is looking at it. Only
        // a session NOBODY is bound to — including us, once this restore's
        // attaches are counted — is the invisible pinned shell worth a warning.
        if (s.alive and !s.attached and !attached.contains(s.id)) n += 1;
    }
    return n;
}

test "leafAttachSessionId applies the one attach rule (T411 counts what restore attaches)" {
    var set = std.StringHashMap(void).init(std.testing.allocator);
    defer set.deinit();
    try set.put("alive-1", {});

    // In the roster: attach.
    try std.testing.expectEqualStrings(
        "alive-1",
        leafAttachSessionId(.{ .session_id = "alive-1" }, &set).?,
    );
    // Positively gone: fresh re-open, no session accounted for.
    try std.testing.expect(leafAttachSessionId(.{ .session_id = "gone-1" }, &set) == null);
    // Roster UNKNOWN (probe failed): attempt the recorded id.
    try std.testing.expectEqualStrings(
        "gone-1",
        leafAttachSessionId(.{ .session_id = "gone-1" }, null).?,
    );
    // Viewer and id-less leaves own no session either way.
    try std.testing.expect(
        leafAttachSessionId(.{ .kind = "viewer", .session_id = "alive-1" }, &set) == null,
    );
    try std.testing.expect(leafAttachSessionId(.{}, &set) == null);
}

test "AttachProbe.skip_live_holders withholds sessions a live viewer holds (T851)" {
    const alloc = std.testing.allocator;

    // A roster with one of each: a session another running app is attached to,
    // an orphaned live one, a relaunchable tombstone, and a genuinely-exited
    // session. The middle two are what a second launch may take; the first is
    // somebody's screen and the last is gone.
    //
    // The probe OWNS the roster it is handed and `deinit` frees every string in
    // it, so each row is built with duped ones — a literal here would be a free
    // of static memory the moment the probe is torn down.
    const Row = struct {
        id: []const u8,
        alive: bool,
        attached: bool,
        relaunchable: bool = false,
        exit_code: ?i64 = null,
    };
    const spec = [_]Row{
        .{ .id = "held-1", .alive = true, .attached = true },
        .{ .id = "orphan-1", .alive = true, .attached = false },
        .{ .id = "tomb-1", .alive = false, .attached = false, .relaunchable = true },
        .{ .id = "gone-1", .alive = false, .attached = false, .exit_code = 0 },
    };
    const build = struct {
        fn roster(a: Allocator, rows: []const Row) !remote_connection.OwnedSessions {
            const out = try a.alloc(remote_connection.OwnedSession, rows.len);
            for (rows, 0..) |r, i| out[i] = .{
                .id = try a.dupe(u8, r.id),
                .alive = r.alive,
                .exit_code = r.exit_code,
                .attached = r.attached,
                .activity = try a.dupe(u8, "idle"),
                .pid = 0,
                .title = null,
                .cwd = null,
                .argv = null,
                .created_at = 0,
                .last_activity = 0,
                .pinned = false,
                .relaunchable = r.relaunchable,
            };
            return .{ .sessions = out, .alloc = a };
        }
    }.roster;

    var probe = AttachProbe.fromRoster(alloc, try build(alloc, &spec), .skip_live_holders);
    defer probe.deinit();
    const set = probe.attachSet().?;
    try std.testing.expect(!set.contains("held-1"));
    try std.testing.expect(set.contains("orphan-1"));
    try std.testing.expect(set.contains("tomb-1"));
    try std.testing.expect(!set.contains("gone-1"));
    // Held is recorded, not merely dropped: the caller must be able to tell
    // "somebody has this" from "this is gone".
    const held = probe.heldSet().?;
    try std.testing.expect(held.contains("held-1"));
    try std.testing.expect(!held.contains("orphan-1"));
    try std.testing.expect(!held.contains("gone-1"));

    // The remote arms keep the old rule verbatim: an attached session is still
    // attachable there, because the flag may be our own un-reaped connection.
    var plain = AttachProbe.fromRoster(alloc, try build(alloc, &spec), .attachable);
    defer plain.deinit();
    try std.testing.expect(plain.attachSet().?.contains("held-1"));
    try std.testing.expectEqual(@as(u32, 0), plain.heldSet().?.count());
}

test "restoreWindowHeldByLiveViewer distinguishes a stolen window from a gone one (T851)" {
    const alloc = std.testing.allocator;
    var held = std.StringHashMap(void).init(alloc);
    defer held.deinit();
    try held.put("held-1", {});

    const held_nodes = [_]session_layout.Node{.{ .leaf = .{ .session_id = "held-1" } }};
    const gone_nodes = [_]session_layout.Node{.{ .leaf = .{ .session_id = "gone-1" } }};
    const viewer_nodes = [_]session_layout.Node{
        .{ .leaf = .{ .kind = "viewer", .viewer_location = "https://example.com/" } },
    };
    const held_tabs = [_]session_layout.Tab{.{ .nodes = &held_nodes, .active = true }};
    const gone_tabs = [_]session_layout.Tab{.{ .nodes = &gone_nodes, .active = true }};
    const viewer_tabs = [_]session_layout.Tab{.{ .nodes = &viewer_nodes, .active = true }};

    const held_win: session_layout.Window = .{ .id = "w-held", .tabs = &held_tabs };
    const gone_win: session_layout.Window = .{ .id = "w-gone", .tabs = &gone_tabs };
    const viewer_win: session_layout.Window = .{ .id = "w-view", .tabs = &viewer_tabs };

    try std.testing.expect(restoreWindowHeldByLiveViewer(held_win, &held));
    try std.testing.expect(!restoreWindowHeldByLiveViewer(gone_win, &held));
    // A viewer leaf owns no session, so it can never be held by anyone.
    try std.testing.expect(!restoreWindowHeldByLiveViewer(viewer_win, &held));
    // No probe (agentless, or the probe never landed) ⇒ nothing is held, which
    // must not turn into "everything is held" and stall the settle loop.
    try std.testing.expect(!restoreWindowHeldByLiveViewer(held_win, null));

    // The settle loop's condition is scoped to the windows THIS restore would
    // replay: a held window anywhere in the set arms the wait, a set with none
    // does not (so an unrelated instance never slows a launch down).
    const wins = [_]session_layout.Window{ gone_win, held_win };
    try std.testing.expect(anyRestoreWindowHeld(&wins, &held));
    const clean = [_]session_layout.Window{ gone_win, viewer_win };
    try std.testing.expect(!anyRestoreWindowHeld(&clean, &held));
    try std.testing.expect(!anyRestoreWindowHeld(&wins, null));
}

test "countUnattachedLive ignores sessions another viewer holds (T411/T851)" {
    const alloc = std.testing.allocator;
    var attached = std.StringHashMap(void).init(alloc);
    defer attached.deinit();
    try attached.put("mine-1", {});

    const rows = [_]remote_connection.OwnedSession{
        // Attached by this restore: accounted for.
        .{ .id = "mine-1", .alive = true, .exit_code = null, .attached = false, .activity = "idle", .pid = 1, .title = null, .cwd = null, .argv = null, .created_at = 0, .last_activity = 0, .pinned = false },
        // Held by another running app: not an orphan, so not a gap.
        .{ .id = "held-1", .alive = true, .exit_code = null, .attached = true, .activity = "idle", .pid = 2, .title = null, .cwd = null, .argv = null, .created_at = 0, .last_activity = 0, .pinned = false },
        // Nobody's: the one the counter exists to report.
        .{ .id = "orphan-1", .alive = true, .exit_code = null, .attached = false, .activity = "idle", .pid = 3, .title = null, .cwd = null, .argv = null, .created_at = 0, .last_activity = 0, .pinned = false },
        // Dead: T278's problem, never counted.
        .{ .id = "gone-1", .alive = false, .exit_code = 0, .attached = false, .activity = "idle", .pid = 0, .title = null, .cwd = null, .argv = null, .created_at = 0, .last_activity = 0, .pinned = false },
    };
    try std.testing.expectEqual(@as(usize, 1), countUnattachedLive(&rows, &attached));
}

test "restoreWindowHasAttachableLeaf keeps viewer-bearing windows with no agent (T398)" {
    // The agentless roster: nothing is attachable, and that is KNOWN.
    var empty = std.StringHashMap(void).init(std.testing.allocator);
    defer empty.deinit();

    const viewer_only = [_]session_layout.Node{
        .{ .leaf = .{ .kind = "viewer", .viewer_location = "https://example.com/" } },
    };
    const mixed = [_]session_layout.Node{
        .{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session_id = "gone-1" } },
        .{ .leaf = .{ .kind = "viewer", .viewer_location = "https://example.com/" } },
    };
    const terminal_only = [_]session_layout.Node{
        .{ .leaf = .{ .session_id = "gone-1" } },
    };

    // The tab arrays must live in THIS frame. A helper that built one from a
    // runtime `nodes` slice and returned `.{ .tabs = &local }` handed back a
    // pointer into its own frame; Debug left that memory intact and ReleaseSafe
    // reused it, which is how this test segfaulted 10 runs out of 10 (T477).
    const viewer_tabs = [_]session_layout.Tab{.{ .nodes = &viewer_only, .active = true }};
    const mixed_tabs = [_]session_layout.Tab{.{ .nodes = &mixed, .active = true }};
    const terminal_tabs = [_]session_layout.Tab{.{ .nodes = &terminal_only, .active = true }};

    const viewer_win: session_layout.Window = .{ .id = "w1", .tabs = &viewer_tabs };
    const mixed_win: session_layout.Window = .{ .id = "w1", .tabs = &mixed_tabs };
    const terminal_win: session_layout.Window = .{ .id = "w1", .tabs = &terminal_tabs };

    // The bug: both of these were dropped before restore ever reached them,
    // because the connection resolve above bailed first.
    try std.testing.expect(restoreWindowHasAttachableLeaf(viewer_win, &empty));
    try std.testing.expect(restoreWindowHasAttachableLeaf(mixed_win, &empty));
    // Still dropped, and must be: every leaf in it is a session that is gone.
    try std.testing.expect(!restoreWindowHasAttachableLeaf(terminal_win, &empty));
    // An UNKNOWN roster (probe failed) is the other tri-state arm and still
    // attempts everything — the agentless set must not be spelled `null`.
    try std.testing.expect(restoreWindowHasAttachableLeaf(terminal_win, null));
}

test "collectAttachedLeaves counts only leaves that attach a session" {
    const nodes = [_]session_layout.Node{
        .{ .leaf = .{ .session_id = "alive-1" } },
        .{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 0, .right = 2 } },
        .{ .leaf = .{ .session_id = "gone-1" } }, // positively gone: fresh re-open
        .{ .leaf = .{ .kind = "viewer", .viewer_location = "https://example.com/" } },
        .{ .leaf = .{} }, // id-less: fresh re-open
    };
    const tabs = [_]session_layout.Tab{.{ .nodes = &nodes, .active = true }};
    const win: session_layout.Window = .{ .id = "w1", .tabs = &tabs };

    var set = std.StringHashMap(void).init(std.testing.allocator);
    defer set.deinit();
    try set.put("alive-1", {});

    var attached = std.StringHashMap(void).init(std.testing.allocator);
    defer attached.deinit();
    var panes: usize = 0;
    collectAttachedLeaves(win, &set, &attached, &panes);
    try std.testing.expectEqual(@as(usize, 1), panes);
    try std.testing.expect(attached.contains("alive-1"));
    try std.testing.expectEqual(@as(u32, 1), attached.count());
}

test "countUnattachedLive counts live sessions outside the attached set only" {
    const mk = struct {
        fn s(id: []const u8, alive: bool) remote_connection.OwnedSession {
            return .{
                .id = id,
                .alive = alive,
                .exit_code = null,
                .attached = false,
                .activity = "idle",
                .pid = 42,
                .title = null,
                .cwd = null,
                .argv = null,
                .created_at = 0,
                .last_activity = 0,
                .pinned = true,
            };
        }
    };

    var attached = std.StringHashMap(void).init(std.testing.allocator);
    defer attached.deinit();
    try attached.put("alive-attached", {});

    const sessions = [_]remote_connection.OwnedSession{
        mk.s("alive-attached", true), // a restored pane holds it
        mk.s("alive-orphan", true), // the T411 orphan: live, held by nothing
        mk.s("dead-tombstone", false), // T278's problem, never this counter's
    };
    try std.testing.expectEqual(@as(usize, 1), countUnattachedLive(&sessions, &attached));

    // The zero case is a real answer, not a missing line.
    const all_attached = [_]remote_connection.OwnedSession{mk.s("alive-attached", true)};
    try std.testing.expectEqual(@as(usize, 0), countUnattachedLive(&all_attached, &attached));
}

test "translate_policy never drifts from the win32 constants (T222)" {
    // `translate_policy.zig` takes no OS import, so its message and virtual-key
    // values are literals. This lane CAN name the real constants, so a
    // transcription error over there fails here rather than shipping as a
    // TranslateMessage skip that eats every injected character.
    try std.testing.expectEqual(w32.WM_KEYDOWN, translate_policy.WM_KEYDOWN);
    try std.testing.expectEqual(w32.WM_KEYUP, translate_policy.WM_KEYUP);
    try std.testing.expectEqual(w32.WM_SYSKEYDOWN, translate_policy.WM_SYSKEYDOWN);
    try std.testing.expectEqual(w32.WM_SYSKEYUP, translate_policy.WM_SYSKEYUP);
    try std.testing.expectEqual(w32.VK_PROCESSKEY, translate_policy.VK_PROCESSKEY);
    try std.testing.expectEqual(w32.VK_PACKET, translate_policy.VK_PACKET);

    // And the loop's own gate: every key message the runtime can deliver is one
    // the policy claims, so the class-atom lookup is never skipped for a
    // message that would have answered "skip".
    for ([_]u32{ w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP }) |m| {
        try std.testing.expect(translate_policy.isKeyMessage(m));
    }
}

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
    /// The connection each restored leaf ATTACHes over, or NULL when this
    /// launch has no agent at all (T398). A viewer leaf rides no connection in
    /// either case — re-opening its recorded location IS its restore (T90h) —
    /// so a null here does not cancel the restore; it means every TERMINAL leaf
    /// in the window opens as a plain local ConPTY pane, which is what a pane
    /// opened while the agent is down would be anyway.
    conn: ?*remote_connection.Connection,
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

    /// The transport for a launch with NO local agent (T398): nothing to ATTACH
    /// to, so terminal leaves open fresh local panes and viewer leaves restore
    /// normally. Only the launch-time path builds one — the chooser's Restore
    /// All starts from a connection by definition.
    fn agentless() RestoreTransport {
        return .{ .conn = null };
    }
};

/// Launch-time session re-attach (T89f2, the RESTORE half of T89f). Rebuilds
/// every restorable window/tab/split, each leaf ATTACHing to the agent session
/// the `ghoztty-agent` kept alive across this app's quit/crash/upgrade (same
/// PID, gap-filled scrollback).
///
/// TWO sources, unioned (T194, Mac's `20e505aaf`): the app-local session-layout
/// manifest T89f1 wrote, AND the layout blobs the agent itself holds. The second
/// is what makes a CRASH survivable — the manifest can regress to nothing (a
/// relaunch that rebuilt no windows then overwrote it) while the agent still
/// holds a blob for every window whose PTYs are alive, and the windows were
/// simply lost. `session_layout.reconcile` states the merge rule; the recovered
/// entries are ADOPTED back into the manifest at the end so the next launch
/// needs no round trip.
///
/// Returns TRUE iff at least one window was restored, in which case the caller
/// (`run`) SUPPRESSES the default blank startup window. Any failure — persistence
/// off, neither source holding anything, an all-dead layout — returns false so
/// the normal single blank window opens instead. Best-effort by design; a
/// partial failure restores the windows it can and skips the rest.
///
/// NO AGENT is a degraded restore, not a failure (T398). Terminal leaves cannot
/// ATTACH without one, so they count as gone and their windows drop out under
/// the never-all-dead rule below — but a VIEWER leaf never needed a connection,
/// so a window holding one comes back with its viewers at their recorded
/// locations and any terminal beside them as a fresh local ConPTY pane. This
/// used to bail before it reached them, dropping a whole viewer-only window for
/// a reason that applied to none of its panes. The windows it still drops are
/// not ERASED either (T590): without a positive adjudication (agent answered,
/// probe landed) their manifest entries are carried forward through this run's
/// rewrites (`carried_layout_windows` → `mergeCarried`), so a launch that
/// restores nothing no longer overwrites the recorded layout with its one
/// blank window — the next launch, agent back, restores them.
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
/// (`termio/Remote.zig`) apply `session-relaunch` (T230): `restore`, the default,
/// opens a fresh shell in the recorded cwd with a notice naming the command and
/// runs NOTHING; `rerun` respawns in-place with a `--- session restarted ---`
/// divider + ring-snapshot scrollback; `prompt` leaves a press-any-key pane).
/// A leaf whose session is
/// genuinely gone / has no id re-opens a FRESH agent-backed pane (the tree shape
/// and the window are preserved), which is friendlier than a permanently-exited
/// pane and keeps every restored pane persistable.
pub fn restoreSessionLayout(self: *App) bool {
    return self.restorePass(null);
}

/// One restore pass. `only` is null for the LAUNCH pass (every window the two
/// sources offer) and a set of window keys for the DEFERRED pass (T976) — the
/// windows an earlier pass carried forward because the local agent was not
/// dialable yet, and nothing else.
///
/// The filter is what keeps the deferred pass from being a second launch: by
/// the time it runs, this process has its own windows in the manifest (the
/// blank startup window, anything the user opened since), and rebuilding those
/// would duplicate what is already on screen. Every other rule below — the
/// never-all-dead drop, the attach-flag settle, the positive-adjudication
/// gate — is re-applied verbatim, so a window that became held, or whose
/// sessions died while we waited, is adjudicated on what is true NOW.
fn restorePass(self: *App, only: ?[]const []const u8) bool {
    if (!self.config.@"session-persistence") return false;
    const gpa = self.core_app.alloc;
    const deferred = only != null;

    // A TEST SEAM (T620), earning its place the way T657's probe override does.
    // The state this forces — a launch where NEITHER restore source yields a
    // window (manifest gone or empty, GET_LAYOUTS faulted) while the agent
    // still holds live sessions — is a real production shape, and it is the
    // ONLY shape that leaves an orphaned live session for the chooser to
    // resume. An acceptance script cannot build it any other way: the manifest
    // and the agent's layout store are shared across pipe-suffix instances and
    // T194's adoption has no attached-elsewhere filter, so any helper instance
    // that launches into the fixture adopts the other instance's window and
    // steals its session. Unset (every real launch) leaves the code below
    // byte-identical.
    if (std.process.getEnvVarOwned(gpa, "GHOZTTY_RESTORE_SKIP")) |v| {
        defer gpa.free(v);
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
            log.warn("session-restore: skipped entirely by GHOZTTY_RESTORE_SKIP", .{});
            return false;
        }
    } else |_| {}

    // The app-local manifest. An ABSENT or EMPTY file is no longer the end of
    // the story (T194): after a CRASH it can have regressed to nothing — a
    // relaunch that rebuilt no windows then overwrote it with the one blank
    // window it did open — while the ever-running agent still holds a blob for
    // every window whose PTYs are alive. So this is one of TWO sources, and a
    // missing one is an empty set, not a bail-out.
    var parsed = loadLocalManifest(gpa);
    defer if (parsed) |*p| p.deinit();
    const local_windows: []const session_layout.Window =
        if (parsed) |p| p.value.windows else &.{};

    // Resolve (find-or-spawn) the local agent. A cold reboot spawns the agent
    // fresh; it re-materializes the sessions from disk as relaunchable
    // tombstones, so the probe below finds them attachable and each leaf applies
    // `session-relaunch` (T89g/T230 — by default a fresh shell plus a notice,
    // never a re-run). Only sessions the agent truly no longer knows re-open
    // fresh.
    //
    // A MISSING agent (unspawnable binary, a dial that will not come up) is no
    // longer the end of the restore (T398). It does end every ATTACH — those
    // shells are genuinely gone — but a VIEWER pane rides no agent at all
    // (T90h: re-opening its recorded location IS its restore), so a window
    // holding one is restorable with no connection whatsoever. Everything below
    // therefore treats the connection as optional and the roster as EMPTY: the
    // never-all-dead rule then drops exactly the windows whose every leaf is a
    // gone session (as it does today when the agent answers and knows none of
    // them), and keeps the rest.
    //
    // T188: from here to the end of the restore, every stretch that blocks the
    // GUI thread pumps IPC around itself. The dial below is the longest one by
    // far (measured 10.7 s against an agent suspended across the relaunch) and
    // pumps from inside its own poll loop as well — see `LocalAgent.findOrSpawn`.
    gui_pump.pump();
    const conn: ?*remote_connection.Connection = self.local_agent.sharedConnection();
    gui_pump.pump();
    if (conn == null) log.info(
        "session-restore: no local agent; restoring only windows that need none",
        .{},
    );

    // T194: ALWAYS ask the agent what it holds, even with a healthy manifest —
    // that is the whole point, since the case worth recovering is exactly the
    // one where the local file cannot tell us about it. A pull failure is not
    // fatal: it degrades to the manifest-only behaviour this had before. With
    // no agent there is nobody to ask, which is the same empty set.
    const recovered = if (conn) |c| self.pullAgentLayouts(c) else null;
    defer if (recovered) |d| d.deinit();
    gui_pump.pump();
    const agent_windows: []const session_layout.Window =
        if (recovered) |d| d.windows else &.{};

    const union_set = session_layout.reconcile(gpa, local_windows, agent_windows) catch |err| {
        log.warn("session-restore: reconcile failed err={}", .{err});
        return false;
    };
    defer gpa.free(union_set.windows);
    if (union_set.windows.len == 0) return false;
    if (union_set.adopted > 0) {
        log.info(
            "session-restore: recovered {d} crash-orphaned window(s) from the agent " ++
                "({d} in the local manifest)",
            .{ union_set.adopted, local_windows.len },
        );
    }

    // Probe the roster. A null set ⇒ the probe failed (UNKNOWN — attempt every
    // leaf); a present set holds every session we can ATTACH: alive (same-PID
    // re-attach) OR a relaunchable tombstone (RELAUNCH per policy).
    // Genuinely-exited/unknown ids are absent → their leaves re-open fresh.
    var probe = if (conn) |c|
        AttachProbe.take(gpa, c, .skip_live_holders)
    else
        AttachProbe.agentless(gpa);
    defer probe.deinit();
    gui_pump.pump();

    // T851, the SETTLE. `.skip_live_holders` leaves out every session the agent
    // says is attached, and at launch there are exactly two reasons a session
    // reads attached: another app instance really is holding it (do not steal
    // it), or the app that WAS holding it just died and the agent has not
    // noticed the broken pipe yet (attach anyway — this is crash recovery, the
    // reason launch restore exists). Only the clock tells them apart, so wait
    // for the flag to settle instead of guessing: a dead holder's flag clears
    // as soon as the agent's reader errors out (measured well under a second on
    // this box), a live holder's never does. The wait is bounded, it is paid
    // only while a window we would actually restore is held, and the fallback
    // when the budget runs out is the safe one — treat it as live, leave the
    // window alone, and carry it to the next launch.
    if (conn) |c| {
        var waited: u64 = 0;
        while (anyRestoreWindowHeld(union_set.windows, probe.heldSet()) and
            waited < restore_attach_settle_budget_ns)
        {
            std.Thread.sleep(restore_attach_settle_interval_ns);
            waited += restore_attach_settle_interval_ns;
            gui_pump.pump();
            const next = AttachProbe.take(gpa, c, .skip_live_holders);
            probe.deinit();
            probe = next;
            gui_pump.pump();
        }
        if (waited > 0) log.info(
            "session-restore: waited {d}ms for attach flags to settle; {s}",
            .{
                waited / std.time.ns_per_ms,
                if (anyRestoreWindowHeld(union_set.windows, probe.heldSet()))
                    "a running instance still holds them"
                else
                    "they cleared (the holder was gone)",
            },
        );
    }
    const attach_ptr = probe.attachSet();
    const held_ptr = probe.heldSet();

    // T411: track which agent sessions the restored panes actually attach to,
    // so the launch can say — in the same breath as "restored N window(s)" —
    // whether the agent is holding LIVE sessions nothing re-attached. Keys
    // borrow from the manifest/blob arenas freed at function exit.
    var attached_ids = std.StringHashMap(void).init(gpa);
    defer attached_ids.deinit();
    var attached_panes: usize = 0;

    // T590: a window this restore drops is only FORGOTTEN when the drop is a
    // positive adjudication — the agent answered AND the roster probe landed,
    // so its every session is known gone. With no agent (or a failed probe)
    // the drop says nothing about the sessions, so the window's manifest entry
    // is carried forward through the coming rewrites instead of being erased
    // by the blank startup window's first sync (Mac: "agent unreachable;
    // keeping N manifest entries for next launch").
    const positively_adjudicated = conn != null and probe.roster != null;

    // T976: the deferred pass re-decides the carried set from scratch, so it
    // hands the map back empty and the loop below re-fills it with whatever it
    // still cannot build. This happens HERE — past every early return — on
    // purpose: a pass that bails before the loop (no manifest, a failed
    // reconcile, persistence turned off underneath us) has learned nothing
    // about those windows, and clearing them any earlier would let the next
    // manifest rewrite erase entries the launch deliberately preserved. The
    // filter slice is the CALLER's copy of the keys, so emptying the map does
    // not disturb it.
    if (deferred) self.clearCarriedLayouts();

    var restored: usize = 0;
    for (union_set.windows) |win| {
        // T188: a window boundary is the natural yield point — nothing of this
        // one is half-built, and each window costs an ATTACH per pane. A caller
        // that lands mid-restore sees the windows built so far, which is a
        // truthful partial answer; before this it saw no answer at all.
        gui_pump.pump();
        // T976: the deferred pass rebuilds ONLY what an earlier pass carried.
        // A skip here is not a drop — the window is either already on screen or
        // was never this pass's to consider — so it must not be carried either,
        // or the retry would keep re-adjudicating windows it will never build.
        if (only) |keys| {
            if (!containsKey(keys, session_layout.windowKey(win))) continue;
        }
        if (!restoreWindowHasAttachableLeaf(win, attach_ptr)) {
            // T851: two drops that look identical here and mean opposite
            // things. "Every session is gone" is an adjudication and the
            // window may be forgotten; "a running instance is showing this
            // window" is not — the window is alive on somebody's screen, so it
            // is carried forward rather than erased by this launch's first
            // manifest rewrite.
            const held = restoreWindowHeldByLiveViewer(win, held_ptr);
            if (held) log.info(
                "session-restore: '{s}' is open in another running instance; leaving it there",
                .{win.id},
            );
            if (held or !positively_adjudicated) self.carryUnrestoredWindow(win);
            continue;
        }
        const tr: RestoreTransport = if (conn) |c| .local(c) else .agentless();
        self.restoreWindow(win, tr, attach_ptr) catch |err| {
            log.warn("session-restore: window '{s}' failed err={}", .{ win.id, err });
            // A build failure is never an adjudication: keep the entry so the
            // next launch can try again (Mac keeps entries on any non-dead
            // failure too).
            self.carryUnrestoredWindow(win);
            continue;
        };
        restored += 1;
        collectAttachedLeaves(win, attach_ptr, &attached_ids, &attached_panes);
    }
    if (self.carried_layout_windows.count() > 0) {
        // T976: "for the next launch" is the LAST resort, not the first. When
        // the reason those windows are still here is an agent that had not come
        // up within `spawn_deadline_ms` — not an adjudication that their
        // sessions are gone — the restore is unfinished rather than decided, so
        // arm the deferred pass and finish it when the agent arrives.
        if (!deferred and restore_retry.shouldArm(
            self.carried_layout_windows.count(),
            positively_adjudicated,
        )) {
            log.info(
                "session-restore: {d} window(s) still need the local agent; " ++
                    "retrying for up to {d}s before deferring them to the next launch",
                .{ self.carried_layout_windows.count(), restore_retry.budgetMs() / 1000 },
            );
            // Hold their `window-N` names against the blank startup window this
            // launch is about to open (T121's counter, from the other side).
            // The counter restarts at zero every run and only ever moves
            // FORWARD, so a startup window that mints `window-1` first makes the
            // carried `window-1` unreachable when the deferred pass finally
            // rebuilds it: the incumbent wins the registration, and every
            // `--target=window-1` a script was written against lands on a blank
            // terminal instead. Reserving now costs nothing and keeps each name
            // for its owner.
            for (union_set.windows) |w| {
                const name = w.ipc_name orelse continue;
                if (self.carried_layout_windows.contains(session_layout.windowKey(w)))
                    self.ipcReserveWindowName(name);
            }
            self.armRestoreRetry();
        } else if (!deferred) {
            log.info(
                "session-restore: keeping {d} unrestored manifest window(s) for the next launch",
                .{self.carried_layout_windows.count()},
            );
        }
    }
    if (restored == 0) return false;
    log.info("session-restore: restored {d} window(s)", .{restored});

    // T411: the gap report. An unattached LIVE session is a real shell holding
    // a session slot that no window shows; `pinned` (correctly) exempts it from
    // the idle-TTL reaper, so without this line it is invisible unless the user
    // opens the chooser roster and counts. The zero case logs too — a counter
    // that only appears when nonzero cannot be told from one that never ran.
    if (conn == null) {
        // Not "unknown": with no agent there is no roster to be behind on, and
        // every restored terminal pane is a fresh local shell by construction.
        log.info(
            "session-restore: attached 0 pane(s); no local agent, so every restored terminal pane is a fresh local shell",
            .{},
        );
    } else if (probe.roster) |roster| {
        const unattached = countUnattachedLive(roster.sessions, &attached_ids);
        if (unattached > 0) {
            log.warn(
                "session-restore: attached {d} pane(s); {d} live agent session(s) unattached",
                .{ attached_panes, unattached },
            );
        } else {
            log.info(
                "session-restore: attached {d} pane(s); 0 live agent session(s) unattached",
                .{attached_panes},
            );
        }
    } else {
        log.info(
            "session-restore: attached {d} pane(s); unattached live session count unknown (probe failed)",
            .{attached_panes},
        );
    }

    // ADOPT (Mac's `SessionLayoutManifest.adopt(_:)`): the agent-recovered
    // windows are this box's again, so write them into the local manifest —
    // otherwise the very next launch would have to recover them all over again,
    // and a launch with no agent would lose them for good. win32 regenerates
    // the manifest wholesale from the live windows, so arming the debounced sync
    // IS the adopt; the message loop `run` is about to enter fires it.
    if (union_set.adopted > 0) self.markLayoutDirty();
    return true;
}

/// Whether `key` is one of `keys`. Linear on purpose: the deferred restore's
/// filter is the handful of windows one launch could not rebuild, and a hash
/// map for four strings costs more than it saves.
fn containsKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// Arm the next deferred-restore retry, or give up and say so (T976). GUI
/// thread.
fn armRestoreRetry(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    const delay = restore_retry.retryDelayMs(self.restore_retry_attempts) orelse {
        self.reportRestoreDeferred();
        self.cancelRestoreRetry();
        return;
    };
    self.restore_retry_armed = true;
    _ = w32.SetTimer(hwnd, RESTORE_RETRY_TIMER_ID, delay, null);
}

/// Disarm the deferred restore. GUI thread. Does NOT touch
/// `carried_layout_windows`: whatever is still in it is carried to the next
/// launch, which is the pre-T976 behaviour and the correct floor.
fn cancelRestoreRetry(self: *App) void {
    self.restore_retry_armed = false;
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, RESTORE_RETRY_TIMER_ID);
}

/// The give-up line. Says the same thing the launch used to say immediately,
/// now with the wait behind it so a reader can tell "the agent never came up"
/// from "we never waited".
fn reportRestoreDeferred(self: *App) void {
    const n = self.carried_layout_windows.count();
    if (n == 0) return;
    log.warn(
        "session-restore: no local agent after {d}s; keeping {d} unrestored " ++
            "manifest window(s) for the next launch",
        .{ restore_retry.budgetMs() / 1000, n },
    );
}

/// One deferred-restore tick (T976): has the local agent come up? If it has,
/// finish the launch restore for the windows that were waiting on it; if not,
/// wait again until the schedule runs out. GUI thread.
///
/// The timer is one-shot per attempt (killed here before anything else), so a
/// slow dial can never queue a second tick behind itself.
fn tickRestoreRetry(self: *App) void {
    self.restore_retry_armed = false;
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, RESTORE_RETRY_TIMER_ID);

    // FIND-only: the launch already issued the spawn, so this asks whether the
    // agent has finished binding its pipe. It costs nothing while none has.
    const agent_up = self.local_agent.adoptIfUp() != null;

    switch (restore_retry.evaluate(
        self.carried_layout_windows.count(),
        agent_up,
        self.restore_retry_attempts,
    )) {
        .stand_down => {
            self.cancelRestoreRetry();
            return;
        },
        .exhausted => {
            self.reportRestoreDeferred();
            self.cancelRestoreRetry();
            return;
        },
        .retry => {
            self.restore_retry_attempts += 1;
            self.armRestoreRetry();
            return;
        },
        .restore => {},
    }
    self.restore_retry_attempts += 1;

    const gpa = self.core_app.alloc;
    log.info(
        "session-restore: the local agent came up after the launch; completing " ++
            "the restore of {d} window(s)",
        .{self.carried_layout_windows.count()},
    );

    // Snapshot the carried keys, because the pass below empties the map and
    // re-fills it with whatever it still cannot build — and because iterating
    // the very map it mutates would be a use-after-free waiting to happen. The
    // pass owns the clear, not this function: it does it only once it is past
    // the early returns that would otherwise drop the keys having learned
    // nothing.
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| gpa.free(k);
        keys.deinit(gpa);
    }
    var it = self.carried_layout_windows.iterator();
    while (it.next()) |entry| {
        const dup = gpa.dupe(u8, entry.key_ptr.*) catch continue;
        keys.append(gpa, dup) catch {
            gpa.free(dup);
            continue;
        };
    }
    if (keys.items.len == 0) {
        self.cancelRestoreRetry();
        return;
    }

    const restored = self.restorePass(keys.items);

    // The manifest must learn what just happened either way: a rebuilt window
    // has to be captured (it is live now, and the carried entry that stood in
    // for it is gone), and a window this pass positively dropped has to stop
    // being carried.
    self.markLayoutDirty();

    if (!restored) log.info(
        "session-restore: the deferred pass rebuilt no window; the agent knows " ++
            "none of their sessions",
        .{},
    );

    // The deferred pass runs ONCE. Its job was to finish the restore when the
    // agent arrived, and it has; anything it left behind was adjudicated by an
    // agent that ANSWERED — held by another running instance, or a window that
    // failed to build — and re-running the whole pass against the same healthy
    // agent would reach the same verdict fifteen more times. Those entries go
    // to the next launch, exactly as they did before T976.
    if (self.carried_layout_windows.count() > 0) log.info(
        "session-restore: {d} window(s) the agent could not give back; keeping " ++
            "them for the next launch",
        .{self.carried_layout_windows.count()},
    );
    self.cancelRestoreRetry();
}

/// Load the app-local session-layout manifest, or null when there isn't a usable
/// one (no `%LOCALAPPDATA%`, no file — a first start or persistence was off —
/// or an unreadable/corrupt one). Every arm is non-fatal by design: since T194
/// the manifest is one of two restore sources, so its absence costs the caller
/// the local half and nothing more.
fn loadLocalManifest(gpa: Allocator) ?session_layout.Parsed {
    const path = session_layout.layoutPath(gpa) orelse return null;
    defer gpa.free(path);
    return session_layout.load(gpa, path) catch |err| {
        log.warn("session-restore: manifest load failed err={}", .{err});
        return null;
    };
}

/// Pull the layout blobs the LOCAL agent holds (`GET_LAYOUTS`, T334), decoded
/// into replayable windows. Null on any transport or decode failure — the caller
/// then restores from the local manifest alone, which is exactly what it did
/// before T194, rather than losing the launch to a bad round trip.
fn pullAgentLayouts(self: *App, conn: *remote_connection.Connection) ?layout_blobs.Decoded {
    const gpa = self.core_app.alloc;
    const payload = conn.requestLayouts(restore_probe_timeout_ns) catch |err| {
        log.warn("session-restore: GET_LAYOUTS failed err={}", .{err});
        return null;
    };
    defer gpa.free(payload);
    const decoded = layout_blobs.decodeLayouts(gpa, payload) catch |err| {
        log.warn("session-restore: layouts payload unreadable err={}", .{err});
        return null;
    };
    if (decoded.skipped > 0) {
        log.warn("session-restore: {d} agent blob(s) skipped as unreadable", .{decoded.skipped});
    }
    return decoded;
}

/// Whether the window has at least one leaf we will ATTACH or re-open — i.e. not
/// EVERY session-backed leaf is positively gone. A window with no attachable
/// leaf (all its recorded sessions are gone from the roster) is dropped rather
/// than restored as a wall of exited panes. A relaunchable tombstone counts as
/// attachable (it RELAUNCHes), so a window of tombstones is kept (T89g).
///
/// With no agent at all (T398) `attach` is the EMPTY set, so this reads exactly
/// as it does against an agent that knows none of the recorded sessions: the
/// viewer arm below keeps a viewer-bearing window, and a terminal-only window
/// is dropped. That equivalence is the point — "no agent" and "agent has
/// forgotten every session" are the same fact about every terminal leaf.
pub fn restoreWindowHasAttachableLeaf(
    win: session_layout.Window,
    attach: ?*const std.StringHashMap(void),
) bool {
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            // A VIEWER leaf always restores: it owns no agent session, so
            // nothing about it can be "gone from the roster". This is what
            // keeps a mixed tree from being dropped wholesale when every
            // terminal in it died — and what lets an all-viewer window come
            // back at all (T90h).
            if (leaf.isViewer()) return true;
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

/// Whether any leaf of this window names a session a LIVE viewer holds (T851).
/// The window is somebody else's screen right now: restoring it here would not
/// copy it, it would take it, and the app that has it would keep drawing the
/// last picture it received. Null/empty `held` ⇒ false, which is every launch
/// with no second instance running.
pub fn restoreWindowHeldByLiveViewer(
    win: session_layout.Window,
    held: ?*const std.StringHashMap(void),
) bool {
    const h = held orelse return false;
    for (win.tabs) |tab| {
        for (tab.nodes) |node| {
            const leaf = node.leaf orelse continue;
            if (leaf.isViewer()) continue;
            const sid = leaf.session_id orelse continue;
            if (h.contains(sid)) return true;
        }
    }
    return false;
}

/// Whether ANY window we are about to restore is held by a live viewer — the
/// settle loop's condition (T851). It is deliberately scoped to the windows
/// this restore would replay rather than to the roster at large: a live
/// instance holding sessions that appear in no window of ours is not a reason
/// to make this launch wait.
pub fn anyRestoreWindowHeld(
    windows: []const session_layout.Window,
    held: ?*const std.StringHashMap(void),
) bool {
    for (windows) |win| {
        if (restoreWindowHeldByLiveViewer(win, held)) return true;
    }
    return false;
}

/// The ATTACH override for one restored leaf: ride the local agent, and set
/// `session_id` iff the session is attachable — alive (same-PID re-attach) or a
/// relaunchable tombstone (RELAUNCH per policy), or the roster is unknown. A
/// genuinely-gone / id-less leaf gets a null session_id — the surface OPENs a
/// fresh agent-backed pane.
fn restoreAttachOverride(
    self: *App,
    leaf: session_layout.Leaf,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) Surface.Overrides {
    // No connection (T398): there is nothing to ATTACH over, so this leaf opens
    // as a plain local ConPTY pane. It still ADOPTs its recorded pane id — the
    // id is ghoztty's own, not the agent's, and dropping it would break every
    // `--target=$GHOZTTY_PANE_ID` the pane's own processes were baked with.
    const conn = tr.conn orelse return .{ .pane_id = leaf.pane_id };

    const sid: ?[]const u8 = leafAttachSessionId(leaf, attach);
    // T109: the recorded screen goes with the SESSION we are re-attaching to.
    // A leaf whose session is gone OPENs a fresh shell, and painting the dead
    // session's last screen over it would be a lie about what the pane is —
    // exactly the case `termio.Remote` refuses on the relaunch path.
    const snap: ?Snapshot = if (sid != null) self.decodeLeafSnapshot(leaf) else null;
    return .{
        // T113: hand back the RECORDED pane id. The process we are re-attaching
        // to still holds it in `$GHOZTTY_PANE_ID`; generating a fresh one here
        // would silently break every pane's ability to name itself across an
        // app restart — the exact class of breakage T112 hit with pids.
        .pane_id = leaf.pane_id,
        .remote = .{
            .connection = conn,
            .local_agent = tr.local_agent,
            .session_id = sid,
            .restore_snapshot = if (snap) |s| s.data else null,
            .restore_offset = if (snap) |s| s.offset else 0,
            // T422: `restoreLeafPresentation` puts this banner back on the GUI
            // thread; telling the backend keeps the session-interrupted notice
            // from claiming the same slot from the IO thread moments later.
            // Independent of `sid` — the notice only ever fires on the path
            // where the recorded session is GONE.
            .pane_banner_restored = if (leaf.banner) |b| b.len > 0 else false,
        },
    };
}

/// A decoded WP-D3 pair, pointing into the App's single decode scratch.
const Snapshot = struct { data: []const u8, offset: u64 };

/// Decode one leaf's recorded screen snapshot into the App's scratch buffer
/// (T109), replacing whatever the previous restored leaf left there. Null for a
/// leaf that recorded none, recorded only half the pair, or whose base64 does
/// not decode — every one of which just means "restore this pane the pre-T109
/// way", never an error: the snapshot is a speed/fidelity win layered on a
/// restore that already works without it.
///
/// The two fields travel together on purpose. An offset with no screen would
/// have the agent skip everything at or below it with nothing painted in its
/// place — a pane blank above the gap — so a missing half voids the pair.
fn decodeLeafSnapshot(self: *App, leaf: session_layout.Leaf) ?Snapshot {
    const encoded = leaf.screen_snapshot orelse return null;
    const offset = leaf.screen_snapshot_offset orelse return null;
    if (encoded.len == 0 or offset == 0) return null;

    const gpa = self.core_app.alloc;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(encoded) catch |err| {
        log.warn("session-restore: snapshot length invalid err={}", .{err});
        return null;
    };
    if (len == 0) return null;
    const buf = gpa.alloc(u8, len) catch return null;
    decoder.decode(buf, encoded) catch |err| {
        log.warn("session-restore: snapshot decode failed err={}", .{err});
        gpa.free(buf);
        return null;
    };
    if (self.restore_snapshot_scratch) |old| gpa.free(old);
    self.restore_snapshot_scratch = buf;
    return .{ .data = buf, .offset = offset };
}

/// How to re-open one recorded VIEWER leaf (T90h). A viewer has no session to
/// ATTACH to — re-opening its location IS its restore — so this is the viewer
/// twin of `restoreAttachOverride`.
///
/// A leaf that says `kind: viewer` but records no location still opens, as a
/// blank browser pane: the tree shape and the pane's identity are the parts a
/// restore must not silently drop, and `about:blank` is a real product state
/// (design P11) rather than an error placeholder. A location whose FILE has
/// since been deleted needs nothing special here — the file viewer renders its
/// in-page error card, exactly as it does when `--view` first names a missing
/// path.
fn restoreViewerOpen(leaf: session_layout.Leaf) ViewerPane.Open {
    return .{
        .location = leaf.viewer_location orelse "about:blank",
        // Restore-only: without this the pane would re-home to wherever it had
        // navigated by capture time, quietly moving what Home means.
        .home_location = leaf.viewer_home_location,
        .origin_directory = leaf.viewer_origin_directory,
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
    // A viewer first pane takes the viewer arm of createWindow and NO surface
    // overrides — they describe a shell it does not have, the same split the
    // `+new-window --view` path makes.
    const first_viewer = first_leaf.isViewer();
    var ov0 = self.restoreAttachOverride(first_leaf, tr, attach);
    const window = self.createWindow(.{
        .surface_overrides = if (first_viewer) null else &ov0,
        .viewer_open = if (first_viewer) restoreViewerOpen(first_leaf) else null,
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
    if (tr.dialed) |d| window.setRemoteDialed(d);
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
        if (lf.isViewer()) {
            _ = try window.addViewerTab(restoreViewerOpen(lf));
        } else {
            var ov = self.restoreAttachOverride(lf, tr, attach);
            window.pending_surface_overrides = &ov;
            _ = window.addTab() catch |err| {
                window.pending_surface_overrides = null;
                return err;
            };
        }
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
    // The anchor is the LEAF, not a surface: a tab's first pane is a viewer
    // whenever its first recorded leaf was one, and narrowing to `*Surface`
    // here would fail the whole tab on a null (T90h).
    const first_pane = window.tab_active_pane[tab_index];
    // Re-adopt the tab's layout identity (T1048) before anything else can
    // capture this window again, so the rebuilt tab keeps the key its
    // predecessor used rather than the fresh one `insertPaneAsTab` just made.
    // Absent in a pre-T1048 manifest, and then the fresh id stands.
    if (tab.uuid) |u| window.adoptTabUuid(tab_index, u);
    try self.restoreBuildSubtree(window, tab.nodes, 0, first_pane, tr, attach, 0);

    if (tab.color) |c| {
        if (std.meta.stringToEnum(tab_color.TabColor, c)) |tc| window.tab_colors[tab_index] = tc;
    }
    if (tab.hero_ratio) |r| window.tab_hero_ratio[tab_index] = r;
    if (tab.title) |t| window.setTabTitlePin(tab_index, t);
}

/// Recursively reproduce a manifest subtree by splitting. `anchor` is the live
/// pane currently occupying this subtree's whole region (the first leaf of the
/// subtree). A leaf node registers its IPC pane name on `anchor`; a split node
/// creates the right subtree's first pane — `newSplitAt` for a terminal
/// (ATTACHing it to that subtree's first leaf), `newViewerSplitAt` for a viewer
/// (re-opening its recorded location) — then recurses into both children.
/// Bounded by `nodes.len` against a corrupt (cyclic / out-of-range) manifest.
fn restoreBuildSubtree(
    self: *App,
    window: *Window,
    nodes: []const session_layout.Node,
    idx: usize,
    anchor: *PaneView,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
    depth: usize,
) !void {
    if (depth > nodes.len or idx >= nodes.len) return error.CorruptLayout;
    const node = nodes[idx];
    if (node.leaf) |lf| {
        if (lf.ipc_name) |n|
            self.ipcRegister(n, .{ .pane = anchor }) catch |err|
                log.warn("session-restore: pane IPC register '{s}' failed err={}", .{ n, err });
        restoreLeafPresentation(anchor, lf);
        return;
    }
    const sp = node.split orelse return error.CorruptLayout;
    if (sp.left >= nodes.len or sp.right >= nodes.len) return error.CorruptLayout;

    // `.right`/`.down` put the OLD (anchor) pane on the left/top with `ratio`
    // as its share — the exact inverse of the capture (which stored the left
    // child's ratio). horizontal → right, vertical → down.
    const dir: SplitTree(PaneView).Split.Direction =
        if (std.mem.eql(u8, sp.layout, "vertical")) .down else .right;

    // The NEW pane takes the right/bottom position — restore it from the first
    // leaf of the right subtree.
    const right_leaf = restoreFirstLeaf(nodes, sp.right) orelse return error.CorruptLayout;
    const new_pane: *PaneView = if (right_leaf.isViewer())
        try window.newViewerSplitAt(
            anchor,
            dir,
            @floatCast(sp.ratio),
            restoreViewerOpen(right_leaf),
        ) orelse return error.CorruptLayout
    else pane: {
        var ov = self.restoreAttachOverride(right_leaf, tr, attach);
        window.pending_surface_overrides = &ov;
        const new_surface = window.newSplitAt(anchor, dir, @floatCast(sp.ratio)) catch |err| {
            window.pending_surface_overrides = null;
            return err;
        } orelse {
            window.pending_surface_overrides = null;
            return error.CorruptLayout;
        };
        break :pane new_surface.pane_view orelse return error.CorruptLayout;
    };

    try self.restoreBuildSubtree(window, nodes, sp.left, anchor, tr, attach, depth + 1);
    try self.restoreBuildSubtree(window, nodes, sp.right, new_pane, tr, attach, depth + 1);
}

/// Put back the app-side presentation a restored terminal pane carries in the
/// manifest and NOWHERE else (T422): its last title and its sticky banner.
///
/// Neither rides the agent's PTY replay — the banner is a native overlay the
/// viewer owns, and the title is the app's cached copy of the last OSC 0/2 — so
/// a restore that skipped this left every pane blank-titled and bannerless.
/// That is the reported loss: the user's banners carry live task state (goal,
/// status, PR links) and came back replaced by the session-interrupted notice,
/// which had simply found the slot empty.
///
/// Terminal leaves only: `+set-banner` rejects viewers, and a viewer's title
/// comes from the content it re-opens. The title goes in on the
/// terminal-reported path, so the first OSC title the restored shell emits
/// takes over normally (Mac `SessionLayoutRestore` does the same).
fn restoreLeafPresentation(pane: *PaneView, lf: session_layout.Leaf) void {
    const surface = switch (pane.kind) {
        .terminal => |s| s,
        .viewer => return,
    };
    const alloc = surface.app.core_app.alloc;

    if (lf.title) |t| {
        if (t.len > 0) {
            // `setTitle` wants a sentinel-terminated slice and dupes it itself,
            // so this copy is scratch: freed as soon as the call returns.
            if (alloc.dupeZ(u8, t)) |z| {
                defer alloc.free(z);
                surface.setTitle(z);
            } else |err| {
                log.warn("session-restore: pane title restore failed err={}", .{err});
            }
        }
    }

    if (lf.banner) |b| {
        if (b.len > 0) surface.setPaneBanner(b);
    }
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

/// The live session roster split into the two generations the upgrade policy
/// cares about (T907), plus whether this agent replaces itself at all.
const AgentSessionMix = struct {
    /// How many LIVE sessions the agent itself owns — the input the upgrade
    /// policy weighs a destructive restart against.
    ///
    /// Asked of the AGENT, not counted from this app's panes, and the difference
    /// is load-bearing: at app quit every window is destroyed while its sessions
    /// stay alive on purpose (detach, not close), so a pane count would read 0 at
    /// exactly the moment killing the agent destroys the most work. It also sees
    /// sessions this app never adopted — another instance's, or a previous run's
    /// pinned ones — which a pane walk cannot.
    ///
    /// Tombstones (`alive == false`) are NOT counted: their child is already gone
    /// and `sessions.json` brings them back as tombstones after the restart, so a
    /// restart costs them nothing.
    live: usize,
    /// Live sessions whose ConPTY the agent owns DIRECTLY. Each one holds a
    /// non-destructive handoff back, because it cannot be carried across a
    /// process boundary at any price.
    legacy: usize,
    /// Both peers negotiated `capability.agent_handoff`.
    handoff_capable: bool,
};

/// One roster probe answering everything the upgrade decision needs. Null on any
/// failure at all — "we could not ask how much this would destroy" is never
/// grounds for destroying it, and it is also never grounds for standing down
/// and waiting for a handoff that may not be coming.
fn agentSessionMix(self: *App) ?AgentSessionMix {
    const conn = self.local_agent.sharedConnectionIfWarm() orelse return null;
    const capable = conn.peerHandsOffItself();
    var roster = conn.requestSessions(restore_probe_timeout_ns) catch |err| {
        log.warn("agent upgrade check: session probe failed err={} (treating as unknown)", .{err});
        return null;
    };
    defer roster.deinit();

    var live: usize = 0;
    var legacy: usize = 0;
    for (roster.sessions) |sess| {
        if (!sess.alive) continue;
        live += 1;
        // An agent too old to report the field omits it, and the default is
        // false — i.e. "legacy", which can only ever hold a handoff back. The
        // direction that fails silently is the other one.
        if (!sess.holder_backed) legacy += 1;
    }
    return .{ .live = live, .legacy = legacy, .handoff_capable = capable };
}

/// Is an unattended client refresh in progress (T525)?
///
/// The morning delivery restarts the app with nobody in front of it, and the
/// fresh app's first act is the agent-upgrade check below — which used to land
/// on `confirm_first` for a stale build and put a modal on an empty desk. The
/// delivery leaves a marker holding a UTC unix-seconds deadline; while it is in
/// the future, a confirmation is deferred rather than shown.
///
/// Since T1056 a stale build raises no modal at all, so the case this was
/// written for cannot happen any more. What the marker guards now is EVERY
/// prompt a relaunch can raise on its own with nobody there to answer it —
/// T1120 audited them and the list is three: the protocol-skew confirmation
/// below, the different-build handoff prompt (`handoffChoice`), and the
/// one-time agent-integration offers (`AgentIntegration`). A prompt that only
/// a user action can reach is not on it, and neither is the config-error
/// dialog, which reports the user's own broken file and is the one message
/// they should find waiting for them.
///
/// Every failure here answers `false`. A marker we could not read, a
/// `%LOCALAPPDATA%` we could not resolve, a deadline we could not parse — none
/// of those are evidence that a refresh is running, and "suppress on a guess" is
/// the direction that fails silently and forever.
pub fn unattendedRefreshActive(self: *App) bool {
    const alloc = self.core_app.alloc;
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return false;
    defer alloc.free(dir);
    // Debug builds get their own marker, same coexistence rule as the IPC pipe
    // and the agent's state dir: a dev build's unattended run must not silence
    // the release app the user is sitting in front of.
    const name = if (build_config.is_debug)
        agent_upgrade.defer_marker_name ++ "-debug"
    else
        agent_upgrade.defer_marker_name;
    const path = std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch return false;
    defer alloc.free(path);

    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [128]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    return agent_upgrade.deferralActive(buf[0..n], std.time.timestamp());
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
/// The DECISION is `agent_upgrade.evaluate` (pure, unit-tested); this function
/// is only its mechanism. Idle ⇒ restart silently (logged, never invisible).
/// Live sessions ⇒ NOTHING (T1056): the agent is protocol-compatible by the fact
/// that we are talking to it, so the newer build is adopted at the next quiet
/// moment — the last persistent window closing, or the next cold start — and no
/// session is ever ended to install it a few hours sooner.
///
/// The liveness question is put to the AGENT (`agentSessionMix` →
/// `LIST_SESSIONS`), never to this app's window list: a window count reads 0 in
/// all the wrong situations — a partial or slow restore, the user closing their
/// last window while pinned sessions keep running, a second app instance — and
/// a 0 that is not true is a silent bootout.
pub fn refreshLocalAgentIfStale(self: *App, reason: []const u8) void {
    if (!self.config.@"session-persistence") return;
    if (self.agent_recovering) return;
    // Quitting is never a safe moment: the windows are going away but their
    // sessions are meant to SURVIVE the app (that is the whole feature), and a
    // restart here would end them behind the user's back.
    if (self.quit_requested) return;

    // A protocol skew is checked BEFORE the connection test below, because it is
    // the one stale-agent state that leaves no connection to judge: the agent
    // answered, we could not agree with it, and the dial was torn down. Falling
    // through to "nothing dialed, nothing to judge" is exactly the silent
    // give-up T125 exists to end.
    if (self.local_agent.protocolSkew()) |skew| {
        self.handleAgentProtocolSkew(skew, reason);
        return;
    }

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
    const mix = self.agentSessionMix() orelse {
        log.info("agent upgrade check skipped: agent session liveness unknown [{s}]", .{reason});
        return;
    };
    const live = mix.live;

    // Log the decision WHERE IT IS MADE, before acting on it (T201). Every arm
    // used to report only after the fact — and `.confirm_first` reports only
    // once the user answers a modal that can sit there indefinitely, while
    // `.none` reported nothing ever. That made a correctly-working mandatory
    // confirmation indistinguishable in the log from a check that decided
    // nothing, and from one that never ran.
    // T525 used to fold an unattended-refresh deferral in here, because a stale
    // build put a modal on an empty desk during the morning delivery. Since
    // T1056 it cannot: staleness raises no modal at all, so there is nothing to
    // defer and the marker is not even read on this path. `applyDeferral` still
    // guards the SKEW confirmation, which is the one that remains.
    const decision = agent_upgrade.evaluate(running, bundled, live, .{
        .capable = mix.handoff_capable,
        .legacy_live = mix.legacy,
    });
    log.info(
        "agent upgrade check: {s} (running {s}, bundled {s}, {d} live session(s), {d} of them legacy, handoff-capable={}) [{s}]",
        .{
            decision.reason.description(),
            agent_upgrade.stampForLog(running),
            agent_upgrade.stampForLog(bundled),
            live,
            mix.legacy,
            mix.handoff_capable,
            reason,
        },
    );

    switch (decision.action) {
        .none => return,
        // T907: the agent is replacing itself. Nothing to do — deliberately not
        // even a re-dial, because there is nothing to re-dial YET: the successor
        // takes over on the agent's own schedule, and the link drop when it does
        // is what the existing in-place recovery is for. Touching the agent here
        // is precisely the destructive act this arm exists to avoid.
        .handoff_now => return,
        .refresh_now => {
            self.agent_upgrade_attempts += 1;
            // Supervised for the same reason the confirmed path is (T421): this
            // one asks nobody, so an app that ended here would be even harder to
            // explain than one that ended after a dialog.
            var guard = relaunch_guard.arm(self.core_app.alloc);
            defer if (guard) |*g| g.disarm();
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
        // Unreachable since T1056: a build-stamp gap never asks for consent to
        // end a session, because ending one buys nothing (the agent we are
        // talking to has already agreed the wire contract in HELLO). Handled
        // rather than `unreachable` for the same reason the skew handler handles
        // its impossible arms: this is the destructive path, and in a release
        // build `unreachable` would turn a future policy edit into undefined
        // behavior instead of a log line.
        .confirm_first => {
            log.err(
                "agent upgrade check: a stale BUILD asked to end {d} live session(s) ({s}); refusing",
                .{ live, @tagName(decision.reason) },
            );
            return;
        },
    }
}

/// The mandatory-update path, and since T1056 its ONLY trigger: the running
/// agent speaks a protocol this build cannot negotiate (T125).
///
/// T147 answers "is the running agent an older BUILD?" and needs a working
/// connection to ask. This is the case where there is no connection *because*
/// the agent is stale — the handshake is where it failed — and until now the app
/// simply gave up: no dialog, no explanation, session persistence quietly off
/// for the rest of the run. docs/claude/sessions.md's agent contract requires the opposite,
/// that an incompatible skew take the mandatory-update path.
///
/// The DECISION is `agent_upgrade.evaluateSkew` (pure, unit-tested); everything
/// here is its mechanism — the same refresh-guard, relaunch guard and honest
/// failure notice the silent idle refresh uses, so there is one restart story
/// rather than two.
///
/// Why the sessions may be ended HERE and nowhere else: the app cannot reach
/// them. The handshake failed, so there is no connection over which to save,
/// migrate or even count them, and leaving the agent alone leaves the user with
/// session persistence silently off for the rest of the run. That is the whole
/// distinction T1056 draws — a stale BUILD still works, an unnegotiable
/// PROTOCOL does not.
fn handleAgentProtocolSkew(self: *App, skew: LocalAgent.Skew, reason: []const u8) void {
    const alloc = self.core_app.alloc;
    const raw = agent_upgrade.evaluateSkew(skew.peer_proto_version, protocol.proto_version);
    // T525: an unattended refresh must not raise this modal on an empty desk.
    // Since T1056 this is the only place the deferral still has anything to
    // suppress — and a skew is the worse one to leave sitting there, since until
    // it is answered session persistence is off.
    const decision = agent_upgrade.applyDeferral(
        raw,
        raw.action == .confirm_first and self.unattendedRefreshActive(),
    );

    // Logged where it is made, before acting, for the same reason the staleness
    // check logs there (T201): a modal can sit unanswered forever, and a `.none`
    // would otherwise leave no trace that the check ran at all.
    log.info(
        "agent upgrade check: {s} (agent protocol {?d}, this app {d}) [{s}]",
        .{ decision.reason.description(), skew.peer_proto_version, protocol.proto_version, reason },
    );

    switch (decision.action) {
        // `.none` here means the app is the out-of-date side, or we could not
        // tell. Either way nothing gets killed. New windows fall back to
        // non-persistent shells, which is degraded but not destructive.
        .none => return,
        // A skew has no idle arm — see `evaluateSkew`, which is exhaustively
        // tested for it. Handled rather than `unreachable` anyway: this is a
        // destructive path, and in a release build `unreachable` would turn a
        // future policy edit into undefined behavior instead of a log line.
        .refresh_now, .handoff_now => {
            log.err(
                "agent upgrade check: a protocol skew asked for a non-consensual restart ({s}); refusing",
                .{@tagName(decision.action)},
            );
            return;
        },
        .confirm_first => {},
    }

    if (self.agent_upgrade_declined) {
        log.info("local agent still protocol-skewed, but the user deferred this run [{s}]", .{reason});
        return;
    }
    if (self.agent_upgrade_attempts >= max_agent_upgrade_attempts) {
        log.info(
            "agent upgrade check: attempt ceiling reached ({d}/{d}), not retrying this run [{s}]",
            .{ self.agent_upgrade_attempts, max_agent_upgrade_attempts, reason },
        );
        return;
    }

    var text_buf: [1024]u8 = undefined;
    const text = agent_upgrade.formatSkewConfirmText(
        &text_buf,
        skew.peer_proto_version,
        protocol.proto_version,
    ) catch return;
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return;
    defer alloc.free(text_w);
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, agent_upgrade.skew_confirm_title) catch return;
    defer alloc.free(title_w);

    const owner: ?*Window = if (self.windows.items.len > 0) self.windows.items[0] else null;

    log.info("agent upgrade: showing mandatory protocol-skew confirmation; waiting for the user", .{});
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
        log.info("user deferred the protocol-skew agent restart", .{});
        return;
    }

    log.warn(
        "user confirmed destructive agent restart to clear a protocol skew (agent protocol {?d} → this app's {d})",
        .{ skew.peer_proto_version, protocol.proto_version },
    );
    self.agent_upgrade_attempts += 1;

    // Same two guards as the confirmed staleness path, for the same reasons: the
    // rebuild empties and refills the window list (so the app must not quit
    // itself in between), and if the process ends anyway something outside it
    // has to notice (T421).
    self.beginAgentRefresh();
    defer self.endAgentRefresh();
    var guard = relaunch_guard.arm(alloc);
    defer if (guard) |*g| g.disarm();

    _ = self.local_agent.restartForUpgrade();
    const rebuilt = self.recoverLocalAgentInPlace();
    log.warn("protocol-skew agent restart finished: {d} window(s) rebuilt", .{rebuilt orelse 0});
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
    // A retry IS a pending recovery (T723). Opening a settle window alongside it
    // would race the same re-dial and, worse, restart the judgement from
    // `evaluate` — which on a link that has been down for a minute would arrive
    // at the same verdict a second time and double the GUI-thread cost of a
    // wedged agent's handshake timeouts.
    if (self.agent_retry_armed) return;
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

/// Arm the next in-place recovery retry, or give up and say so (T723). GUI
/// thread; called only from the re-dial-failure site in
/// `recoverLocalAgentInPlace`, so every caller of recovery inherits it.
fn armAgentRecoveryRetry(self: *App) void {
    const hwnd = self.msg_hwnd orelse return;
    const delay = agent_recovery.retryDelayMs(self.agent_retry_attempts) orelse {
        self.cancelAgentRecoveryRetry();
        self.reportAgentUnreachable();
        return;
    };
    self.agent_retry_armed = true;
    _ = w32.SetTimer(hwnd, AGENT_RETRY_TIMER_ID, delay, null);
    log.warn(
        "in-place recovery: retry {d}/{d} in {d}ms",
        .{ self.agent_retry_attempts + 1, agent_recovery.retry_delays_ms.len, delay },
    );
}

/// Disarm the retry and forget the attempt count. GUI thread.
fn cancelAgentRecoveryRetry(self: *App) void {
    self.agent_retry_armed = false;
    self.agent_retry_attempts = 0;
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, AGENT_RETRY_TIMER_ID);
}

/// One retry tick: re-check the link, then either stand down or run recovery
/// again. GUI thread.
///
/// The timer is one-shot per attempt (killed here before anything else), so a
/// slow re-dial can never queue a second tick behind itself — the next attempt
/// is armed by `recoverLocalAgentInPlace`'s failure path only after this one has
/// finished.
fn tickAgentRecoveryRetry(self: *App) void {
    self.agent_retry_armed = false;
    if (self.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, AGENT_RETRY_TIMER_ID);

    switch (agent_recovery.evaluateRetry(
        self.local_agent.linkState(),
        self.agent_retry_attempts,
    )) {
        .link_recovered => {
            // The wedge ended. The panes were never rebuilt — the abort left
            // them on the old connection, which is the one that just healed —
            // so replacing their surfaces now would destroy working panes for
            // an event that cured itself.
            log.warn("in-place recovery: the shared link came back on its own; retries stood down", .{});
            self.cancelAgentRecoveryRetry();
            return;
        },
        .no_owner => {
            log.info("in-place recovery: no shared connection left to retry for", .{});
            self.cancelAgentRecoveryRetry();
            return;
        },
        .exhausted => {
            self.cancelAgentRecoveryRetry();
            self.reportAgentUnreachable();
            return;
        },
        .retry => {},
    }

    // Nothing left that rode the dropped connection ⇒ nothing to recover, and
    // re-dialing would only spawn an agent for windows that no longer exist.
    var any_agent_window = false;
    for (self.windows.items) |win| {
        if (win.local_agent_conn != null) {
            any_agent_window = true;
            break;
        }
    }
    if (!any_agent_window) {
        log.info("in-place recovery: no local-agent windows are left; retries stood down", .{});
        self.cancelAgentRecoveryRetry();
        return;
    }

    self.agent_retry_attempts += 1;
    log.warn(
        "in-place recovery: retry {d}/{d} starting",
        .{ self.agent_retry_attempts, agent_recovery.retry_delays_ms.len },
    );
    self.beginAgentRefresh();
    _ = self.recoverLocalAgentInPlace();
    self.endAgentRefresh();
}

/// Tell the user, in the pane itself, that their shell is frozen and why (T723).
///
/// The whole defect this task names is a pane that sits silently dead, so the
/// give-up point has to be visible somewhere a person is already looking. A
/// BANNER rather than a modal: the app is otherwise working, the user may have
/// several unaffected windows, and a dialog that steals focus from a terminal
/// they are typing in is its own defect. It is per-pane because the condition is
/// per-pane.
///
/// A pane that already carries a banner keeps it (T422's rule): the user's own
/// banner holds live task state, and this notice is not entitled to that slot.
/// Those panes still have the log line and the frozen prompt itself.
fn reportAgentUnreachable(self: *App) void {
    const notice = agent_unreachable_notice;

    var frozen: usize = 0;
    var claimed: usize = 0;
    for (self.windows.items) |win| {
        if (win.local_agent_conn == null) continue;
        for (0..win.tab_count) |t| {
            var it = win.tab_trees[t].iterator();
            while (it.next()) |entry| {
                const surface = entry.view.surface() orelse continue;
                frozen += 1;
                if (surface.banner_text != null) continue;
                surface.setPaneBanner(notice);
                claimed += 1;
            }
        }
    }

    log.err(
        "in-place recovery GAVE UP after {d} retries: no local agent could be reached; " ++
            "{d} pane(s) are frozen ({d} told in their banner)",
        .{ agent_recovery.retry_delays_ms.len, frozen, claimed },
    );
}

/// Take back the give-up notice from every pane still showing it, and ONLY from
/// those (T723). Ownership is proven by the text: the notice is a fixed literal
/// nothing else writes, so an exact match is ours and anything else is the
/// user's own banner, which this must never touch.
fn clearAgentUnreachableNotice(self: *App) void {
    for (self.windows.items) |win| {
        for (0..win.tab_count) |t| {
            var it = win.tab_trees[t].iterator();
            while (it.next()) |entry| {
                const surface = entry.view.surface() orelse continue;
                const text = surface.banner_text orelse continue;
                if (!std.mem.eql(u8, text, agent_unreachable_notice)) continue;
                surface.setPaneBanner(null);
            }
        }
    }
}

/// The give-up banner's exact text. One definition because `reportAgentUnreachable`
/// writes it and `clearAgentUnreachableNotice` identifies it by comparing against
/// it — two spellings would leave a stale notice on a recovered pane forever.
const agent_unreachable_notice =
    "**Session helper unreachable** — this pane's shell is frozen. " ++
    "Ghoztty could not reach the background agent that owns it. " ++
    "Close and reopen the pane, or restart Ghoztty to recover.";

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
/// writes, re-dial, and then rebuild each window's tabs from that capture using
/// the same per-leaf ATTACH override, presentation restore and IPC re-register
/// the restore walk uses — so split ratios, tab colors, hero ratios, pinned
/// titles, IPC pane names and pane ids all come back through code that is
/// already exercised by every restore test, and a bug fixed in one place is
/// fixed in both.
///
/// Since T399 it rebuilds only the leaves that rode the dropped connection.
/// Viewer panes stay exactly where they are, alive, because they never rode it
/// (`rebuildTabInPlace`).
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

    // Before the capture, never after (T723): the rebuild restores each leaf's
    // banner FROM the capture (`restoreLeafPresentation`), so a give-up notice
    // still on a pane at capture time would be re-applied to the fresh pane that
    // just came back — a "your shell is frozen" banner over a working shell.
    self.clearAgentUnreachableNotice();

    const gpa = self.core_app.alloc;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Capture BEFORE re-dialing: the live tree is the source of truth, and the
    // debounced manifest on disk may be up to a full debounce stale.
    var pending = false;
    const captured = self.captureSessionLayout(arena, &pending, null, .fresh) catch |err| {
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
        // …and that used to be the end of it (T723). The abort is terminal on
        // its own: the settle watch is already closed, and the link cannot
        // produce a second DOWN edge to re-open one — `reconnecting` only
        // leaves for `dead` on a DETACHED frame, which a wedged or killed agent
        // never sends. So a wedge that outlasts the re-dial, or an agent that
        // dies right after one, left every pane frozen until the app was
        // relaunched. Arm a bounded, backed-off retry instead.
        self.armAgentRecoveryRetry();
        return null;
    };

    // A re-dial that worked ends the retry story, whichever path got us here:
    // the schedule resets so a LATER, unrelated agent death gets a full budget
    // rather than inheriting a spent one.
    self.cancelAgentRecoveryRetry();

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

    // Match captured windows to live ones BY IDENTITY (T343). This used to be a
    // positional join that replayed `captureSessionLayout`'s skip rule by hand,
    // because at the time there was no id worth keying on; T338's `layout_uuid`
    // is one, so the two walks no longer have to agree step for step. A window
    // whose uuid is absent from the capture is simply left alone — which is both
    // what the old skip rule meant and the right answer for a window that was
    // born, or that closed, while `reconnectForRecovery` blocked above.
    const live_keys = arena.alloc([]const u8, self.windows.items.len) catch |err| {
        log.warn("in-place recovery: pairing allocation failed err={}", .{err});
        return null;
    };
    for (self.windows.items, 0..) |win, i| live_keys[i] = win.layoutUuid();
    const pairing = session_layout.pairWindows(arena, captured.windows, live_keys) catch |err| {
        log.warn("in-place recovery: pairing failed err={}", .{err});
        return null;
    };

    var rebuilt: usize = 0;
    for (self.windows.items, pairing) |win, matched| {
        const ci = matched orelse continue;
        // A window that was never agent-backed (persistence unresolved at its
        // creation, so its panes are plain exec children) has nothing to
        // re-attach and must not have its shells replaced. The capture does not
        // filter these out, so this one is ours to check.
        if (win.local_agent_conn == null) continue;

        _ = self.rebuildWindowInPlace(arena, win, captured.windows[ci], .local(conn), attach_ptr) catch |err| {
            log.warn("in-place recovery: window '{s}' failed err={}", .{ captured.windows[ci].id, err });
            continue;
        };
        rebuilt += 1;
    }

    log.info("in-place recovery: rebuilt {d} window(s) on the new agent connection", .{rebuilt});
    if (rebuilt > 0) self.markLayoutDirty();
    return rebuilt;
}

/// Replace one live window's tab trees with fresh surfaces ATTACHed over `tr`.
/// The window itself — its HWND, position, tab count and selection — is kept;
/// only the surfaces inside it are rebuilt, which is what makes this "in place".
///
/// Two callers, one walk: the LOCAL-agent crash recovery above (`tr.local_agent`,
/// a fresh shared connection) and the CROSS-MACHINE reconnect swap (T366,
/// `RemoteReconnect`, a freshly dialed per-window transport the caller has
/// already installed on the window). Returns the number of terminal leaves that
/// came back, which is what tells the remote swap whether it attached anything
/// at all — a swap that attached nothing must not retire the old transport.
pub fn rebuildWindowInPlace(
    self: *App,
    arena: Allocator,
    window: *Window,
    captured: session_layout.Window,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) !usize {
    if (captured.tabs.len == 0) return error.CorruptLayout;
    const active_tab = window.active_tab;

    // The window's own connection pointer must move to the new connection
    // BEFORE any surface is built: later tabs/splits read it, and leaving it on
    // the retired connection would quietly make every future pane in this
    // window unrecoverable. The cross-machine caller does the same for
    // `remote_dialed` (its own field) before it gets here.
    if (tr.local_agent) window.local_agent_conn = tr.conn;

    // Match captured tabs to live ones BY IDENTITY (T1048) — the same move
    // T343 made one level up, for the same reason. This used to be
    // `captured.tabs[ti]` for live tab `ti`, which held only while the tab list
    // had not moved since the capture; the capture is followed by a re-dial
    // that can block for seconds, so a tab closed (or opened, or dragged) in
    // that gap shifted every later tab into its neighbour's tree.
    // `rebuildTabInPlace`'s shape check could not catch it: two single-pane
    // tabs have the same shape. A live tab the capture has no entry for is left
    // alone, which is the conservative answer for a tab born after the capture.
    const live_tab_keys = try arena.alloc([]const u8, window.tab_count);
    for (0..window.tab_count) |ti| live_tab_keys[ti] = window.tabUuid(ti);
    const tab_pairing = try session_layout.pairTabs(arena, captured.tabs, live_tab_keys);

    var attached: usize = 0;
    for (0..window.tab_count) |ti| {
        const ci = tab_pairing[ti] orelse continue;
        attached += self.rebuildTabInPlace(arena, window, ti, captured.tabs[ci], tr, attach) catch |err| {
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
    return attached;
}

/// Rebuild ONE tab in place, re-binding only what the dropped link actually
/// invalidated. Returns how many terminal leaves came back on `tr`.
///
/// The surgical path swaps each TERMINAL leaf for a fresh surface ATTACHed over
/// `tr`, in the slot it already occupies, and touches nothing else: the tree
/// keeps its shape, its ratios and its zoom, and every VIEWER pane keeps its
/// WebView2 host, its page, its scroll position and its in-page state (T399).
/// A viewer rides no agent session, so a link that dropped cannot have
/// invalidated it — tearing one down was churn charged to the user for an event
/// that never touched their pane.
///
/// That walk is licensed by a correspondence check, not by hope:
/// `captureSessionLayout` writes the manifest node array as a 1:1 copy of the
/// live `SplitTree` node array, so while the two still agree node-for-node,
/// index `i` names the same pane in both. A tab whose tree MOVED between the
/// capture and the rebuild falls back to replacing the whole root, which is
/// correct for any tree at the cost of the churn above.
fn rebuildTabInPlace(
    self: *App,
    arena: Allocator,
    window: *Window,
    tab_index: usize,
    tab: session_layout.Tab,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) !usize {
    if (tab.nodes.len == 0) return error.CorruptLayout;

    const captured_shapes = try capturedNodeShapes(arena, tab.nodes);
    const live_shapes = try liveNodeShapes(arena, &window.tab_trees[tab_index]);
    if (agent_recovery.shapesCorrespond(captured_shapes, live_shapes)) {
        return self.rebuildTabLeavesInPlace(window, tab_index, tab, tr, attach);
    }

    log.warn(
        "in-place recovery: tab {d}'s tree no longer matches its capture " ++
            "({d} live node(s) vs {d} captured); replacing the whole root",
        .{ tab_index, live_shapes.len, captured_shapes.len },
    );
    // The root walk rebuilds the whole tab, so its terminal leaves are back by
    // construction — it counts them from the capture rather than instrumenting
    // the recursive walker, and reports them even on a partial failure (what the
    // caller needs is "does anything now ride the new transport"). A tab whose
    // leaves are all viewers is honestly zero.
    return try self.rebuildTabRootInPlace(window, tab_index, tab, tr, attach);
}

/// Swap ONLY this tab's terminal leaves, each in the slot it already holds.
/// Caller has already established that `tab.nodes` and the live tree correspond
/// index-for-index, which is what makes `nodes[i]` addressable in both.
///
/// Never fails as a whole: a leaf that cannot be rebuilt is logged and left
/// frozen, because the panes that DID come back are worth more than an
/// all-or-nothing tab. Returns how many leaves actually came back.
fn rebuildTabLeavesInPlace(
    self: *App,
    window: *Window,
    tab_index: usize,
    tab: session_layout.Tab,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) usize {
    var attached: usize = 0;
    for (tab.nodes, 0..) |node, i| {
        const lf = node.leaf orelse continue;
        if (!agent_recovery.rebuildsLeaf(if (lf.isViewer()) .viewer else .terminal)) continue;

        // Re-read the tree every iteration: each replacement re-allocates the
        // node array (the tree is a persistent structure), so a slice taken
        // before the loop would be freed memory by the second pass. The HANDLES
        // are what stay put, which is the whole reason this walk is by index.
        const live = switch (window.tab_trees[tab_index].nodes[i]) {
            .leaf => |pane| pane,
            .split => continue,
        };

        var ov = self.restoreAttachOverride(lf, tr, attach);
        const fresh = window.replaceTabLeaf(tab_index, live, .{ .terminal = &ov }) catch |err| {
            log.warn(
                "in-place recovery: tab {d} leaf {d} failed err={}",
                .{ tab_index, i, err },
            );
            continue;
        };

        // The two things a fresh surface does NOT inherit from the one it
        // replaced — the same pair `restoreBuildSubtree` puts back on the
        // launch-restore path. The IPC name went with the departing surface's
        // teardown (it forgets its own registry entry), and the title and
        // banner live nowhere but the manifest.
        if (lf.ipc_name) |n|
            self.ipcRegister(n, .{ .pane = fresh }) catch |err|
                log.warn("in-place recovery: pane IPC register '{s}' failed err={}", .{ n, err });
        restoreLeafPresentation(fresh, lf);
        attached += 1;
    }
    return attached;
}

/// The fallback: build a fresh root surface for the tab, swap the whole tree,
/// then replay the recorded splits onto it via the shared restore walker. This
/// is what every tab used to get; it is now reserved for a tab whose live tree
/// no longer corresponds to the capture, where per-leaf replacement has no
/// meaningful slot to aim at.
///
/// Errors ONLY before the root has been replaced. Once it has, a failure in the
/// subtree walk is logged and the count returned anyway — because the count is
/// what tells the remote-reconnect swap whether anything now rides the NEW
/// transport (T366), and "the root moved but I reported nothing moved" is how
/// that caller would free a connection a live surface is holding.
fn rebuildTabRootInPlace(
    self: *App,
    window: *Window,
    tab_index: usize,
    tab: session_layout.Tab,
    tr: RestoreTransport,
    attach: ?*const std.StringHashMap(void),
) !usize {
    const first_leaf = restoreFirstLeaf(tab.nodes, 0) orelse return error.CorruptLayout;
    var ov = self.restoreAttachOverride(first_leaf, tr, attach);
    // Rebuild the root as the KIND it was. A viewer rides no agent connection,
    // so recovery has nothing to re-bind for it — but the tab still has to come
    // back holding a viewer, not a terminal wearing its slot (T90h).
    const root = try window.replaceTabRoot(tab_index, if (first_leaf.isViewer())
        .{ .viewer = restoreViewerOpen(first_leaf) }
    else
        .{ .terminal = &ov });

    // Everything below the root is the ordinary restore walk. `restoreTab`
    // would re-apply color/hero/title too, but those live on the WINDOW and
    // were never lost — only the surfaces were — so we replay just the splits.
    self.restoreBuildSubtree(window, tab.nodes, 0, root, tr, attach, 0) catch |err|
        log.warn("in-place recovery: tab {d} subtree replay failed err={}", .{ tab_index, err });

    var n: usize = 0;
    for (tab.nodes) |node| {
        const lf = node.leaf orelse continue;
        if (!lf.isViewer()) n += 1;
    }
    return n;
}

/// Project a captured manifest tab onto the shape vocabulary the correspondence
/// rule speaks (`agent_recovery.NodeShape`).
fn capturedNodeShapes(
    arena: Allocator,
    nodes: []const session_layout.Node,
) ![]agent_recovery.NodeShape {
    const out = try arena.alloc(agent_recovery.NodeShape, nodes.len);
    for (nodes, 0..) |n, i| {
        out[i] = if (n.leaf) |lf|
            (if (lf.isViewer())
                agent_recovery.NodeShape.viewer
            else
                agent_recovery.NodeShape.terminal)
        else
            .split;
    }
    return out;
}

/// The same projection for the LIVE tree the capture was taken from.
fn liveNodeShapes(
    arena: Allocator,
    tree: *const SplitTree(PaneView),
) ![]agent_recovery.NodeShape {
    const out = try arena.alloc(agent_recovery.NodeShape, tree.nodes.len);
    for (tree.nodes, 0..) |n, i| {
        out[i] = switch (n) {
            .leaf => |pane| if (pane.isViewer())
                agent_recovery.NodeShape.viewer
            else
                agent_recovery.NodeShape.terminal,
            .split => .split,
        };
    }
    return out;
}

/// Apply the restored outer placement: the recorded normal rect AND the
/// recorded maximized state, which are one fact and are therefore applied with
/// one call. Null frame with no maximized flag ⇒ the capture knew nothing;
/// leave the created position (config/cascade) as-is.
///
/// **The two halves cannot be applied separately** (T748). By the time this
/// runs the window has already been SHOWN — and shown maximized whenever the
/// T85 placement memory said the user's last window was, which for a user who
/// works maximized is every window on every launch. `SetWindowPos` then moves
/// and resizes that window WITHOUT clearing `WS_MAXIMIZE`: Windows still calls
/// it maximized (so the caption drops its resize border and the chrome lays
/// itself out for a maximized window) while it sits at a normal window's size
/// and position. That is the "maximized but no border, renders oddly" window
/// the report describes, and the following `ShowWindow(SW_MAXIMIZE)` could not
/// undo it — asking for a state the window is already in does nothing. The
/// mirror image is just as broken: a manifest window that was NOT maximized,
/// restored while the memory says maximized, was resized to its small rect with
/// the maximize style still set.
///
/// `SetWindowPlacement` is the one call that sets `rcNormalPosition` and the
/// show state together, so no intermediate state exists to be caught in.
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
    // Nothing recorded at all (the capture's query failed): today's behavior is
    // to leave the window exactly as it was created, and a placement call here
    // would instead impose a state nobody measured.
    if (frame == null and !maximized) return;

    const placed: ?session_layout.Frame = if (frame) |f| blk: {
        if (!reanchor) break :blk f;
        const r = reanchorFrame(.{ .x = f.x, .y = f.y, .w = f.w, .h = f.h });
        if (r.x != f.x or r.y != f.y or r.w != f.w or r.h != f.h) {
            log.info(
                "session-restore: frame {d},{d} {d}x{d} is off every monitor here, re-anchored to {d},{d} {d}x{d}",
                .{ f.x, f.y, f.w, f.h, r.x, r.y, r.w, r.h },
            );
        }
        break :blk .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    } else null;

    log.debug("session-restore: placing window maximized={} frame={any}", .{ maximized, placed });

    // The manifest is authoritative for THIS window: the placement memory only
    // ever supplied a default for a window nobody had a record of. Set before
    // the early return below, so a window still waiting for its first
    // ShowWindow maximizes (or does not) per the manifest.
    window.start_maximized = maximized;

    // Not shown yet — the created rect IS the normal rect and `start_maximized`
    // above drives the first ShowWindow. A plain move is enough here, and is
    // what must happen: a placement call would make the window visible before
    // its first pane is ready.
    if (w32.IsWindowVisible(hwnd) == 0) {
        if (placed) |f| _ = w32.SetWindowPos(
            hwnd,
            null,
            f.x,
            f.y,
            f.w,
            f.h,
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
        );
        return;
    }

    var wp: w32.WINDOWPLACEMENT = undefined;
    wp.length = @sizeOf(w32.WINDOWPLACEMENT);
    if (w32.GetWindowPlacement(hwnd, &wp) == 0) {
        // No placement to amend. Fall back to the two-step, ORDERED so it can
        // never leave the hybrid state above: un-maximize first, move second.
        if (w32.IsZoomed(hwnd) != 0) {
            // Already exactly where the manifest wants it; the geometry of a
            // maximized window belongs to Windows.
            if (maximized) return;
            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
        }
        if (placed) |f| _ = w32.SetWindowPos(
            hwnd,
            null,
            f.x,
            f.y,
            f.w,
            f.h,
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
        );
        if (maximized) _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
        return;
    }

    wp.flags = 0;
    wp.showCmd = switch (window_placement.show(maximized)) {
        .maximized => w32.SW_SHOWMAXIMIZED,
        .show_noactivate => @intCast(w32.SW_SHOWNOACTIVATE),
    };
    if (placed) |f| {
        const ws = window_placement.toWorkspace(
            .{ .x = f.x, .y = f.y, .w = f.w, .h = f.h },
            workspaceOrigin(),
        );
        wp.rcNormalPosition = .{
            .left = ws.x,
            .top = ws.y,
            .right = ws.x +| ws.w,
            .bottom = ws.y +| ws.h,
        };
    }
    _ = w32.SetWindowPlacement(hwnd, &wp);
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
    if (opts.viewer_open) |open| {
        _ = try window.addViewerTab(open);
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
    window.setRemoteDialed(dialed);
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
    opts_with_machine.machine = .{ .relay = .{ .base = relay_base, .device = device, .token = token } };
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
/// Give a window built by a single-session resume the name its layout record
/// carries (T1296). A resume is a restore of ONE leaf, and until this it was the
/// only restore path that rebuilt a pane without rebuilding what the pane was
/// called — so a user who resumed three sessions on another machine got three
/// windows they could not tell apart.
///
/// The two kinds of name are applied differently, and deliberately so:
///
///   * a PINNED name is the one the user typed (`+rename` / the rename dialog),
///     so it goes back as a pin and outranks whatever the shell says next;
///   * an unpinned one is the pane's last terminal-reported title, so it goes in
///     on the terminal-reported path and the first title the resumed shell emits
///     replaces it normally — the same rule `restoreLeafPresentation` follows
///     for a full restore, and the reason a shell title can never masquerade as
///     a name the user chose.
fn applyResumeName(window: *Window, name: ?SessionRoster.WindowName) void {
    const n = name orelse return;
    if (n.text.len == 0) return;
    if (n.pinned) {
        window.setTitleOverride(n.text);
        return;
    }
    if (window.tab_count == 0) return;
    const surface = window.tab_active_pane[window.active_tab].surface() orelse return;
    const alloc = window.app.core_app.alloc;
    const z = alloc.dupeZ(u8, n.text) catch return;
    defer alloc.free(z);
    surface.setTitle(z);
}

pub fn resumeLocalSession(
    self: *App,
    session_id: []const u8,
    pane_id: ?[]const u8,
    /// The name the machine's layout record has for this session's window, or
    /// null when it has none (persistence off, a session no window recorded).
    name: ?SessionRoster.WindowName,
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
    applyResumeName(window, name);
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
/// relay) is `RestoreAllRelay`, which does its dialing on a worker thread and
/// lands back in `adoptRestoreAll` (T339); this one dials nothing.
pub fn restoreAllLocalSessions(self: *App) RestoreAllError!usize {
    // Non-spawning would be wrong here, unlike the push: the user asked for
    // this, so resolving (and if necessary starting) the agent is the job.
    const conn = self.local_agent.sharedConnection() orelse {
        log.warn("restore all: no local agent connection", .{});
        return error.NoAgent;
    };

    const restored = try self.restoreAllLocalFrom(conn);
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

/// The LOCAL rebuild: pull the agent-owned layout blobs (`GET_LAYOUTS`, T334)
/// over the shared agent connection, probe liveness, and replay each decoded
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
///
/// It runs synchronously on the GUI thread, and stays that way: every RPC here
/// is a bounded named-pipe round trip to a daemon on this box. The CROSS-MACHINE
/// rebuild is the one whose network cannot be trusted to be fast — it dials a
/// relay N+1 times — and that half lives in `RestoreAllRelay` on a worker thread
/// (T339), landing back through `adoptRestoreAll`.
fn restoreAllLocalFrom(
    self: *App,
    pull: *remote_connection.Connection,
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

    // T851: the same no-stealing rule launch restore follows. This arm needs no
    // settle window — the button is pressed long after any crash that orphaned
    // these sessions, so an ATTACHED flag here is a live viewer, and the one
    // whose windows are already open HERE is caught by `windowIsOpenOn` below.
    var probe = AttachProbe.take(gpa, pull, .skip_live_holders);
    defer probe.deinit();
    const attach_ptr = probe.attachSet();
    const held_ptr = probe.heldSet();

    var restored: usize = 0;
    for (decoded.windows) |win| {
        // Mac's double-attach guard (`SessionLayoutRestore.swift:695-699`) in the
        // identity win32 actually has: the agent rebinds a session to the NEWEST
        // attach, so rebuilding a window whose panes are already on screen would
        // quietly steal them from the window that has them — and the user would
        // watch their own terminal go blank to make a copy of itself.
        //
        // It runs FIRST, ahead of the liveness gates: our own open window's
        // sessions read as held by a live viewer (they are — by us), and a skip
        // that says "you are already looking at this" is a better answer than a
        // silent drop for the same fact.
        if (self.windowIsOpenOn(win, null)) {
            log.info("restore all: '{s}' is already open here, skipping", .{win.id});
            continue;
        }
        // T851: the same window open in ANOTHER running instance. Rebuilding it
        // here would take it off their screen, so say so and leave it.
        if (restoreWindowHeldByLiveViewer(win, held_ptr)) {
            log.info(
                "restore all: '{s}' is open in another running instance; leaving it there",
                .{win.id},
            );
            continue;
        }
        if (!restoreWindowHasAttachableLeaf(win, attach_ptr)) continue;
        const tr: RestoreTransport = .local(pull);
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

/// GUI thread (T339): rebuild the windows a `RestoreAllRelay` worker prepared,
/// each on the transport that worker dialed for it. Returns how many were
/// rebuilt; the job's remaining dials are freed by `Job.destroy`, so every early
/// return here is safe rather than a leaked connection per window.
///
/// The dials are already open, so nothing in this function blocks on the
/// network. What it must still do on this thread is the DECIDING — `createWindow`
/// and everything under it is GUI-thread-only — and re-applying the
/// double-attach guard against the LIVE panes: the worker filtered against a
/// snapshot taken before it dialed, and a pane can have attached to one of these
/// sessions in between (a second chooser, an IPC resume, the reconnect ladder).
pub fn adoptRestoreAll(self: *App, job: *RestoreAllRelay.Job) usize {
    // The app is on its way out: building windows now would race teardown, and
    // the user is not going to see them. Every dial the job holds is freed with
    // it.
    if (self.quit_requested) {
        log.info("restore all: reply landed while quitting; dropping the rebuild", .{});
        return 0;
    }

    const attach_ptr = job.probe.attachSet();
    const machine = job.machine();
    var restored: usize = 0;
    for (job.prepared) |*p| {
        if (self.windowIsOpenOn(p.win, machine)) {
            log.info("restore all: '{s}' is already open here, skipping", .{p.win.id});
            continue;
        }
        const dialed = p.dialed orelse continue;
        const tr: RestoreTransport = .{
            .conn = dialed.conn(),
            .local_agent = false,
            .dialed = dialed,
            .machine = machine,
            // The far machine's monitors are not ours (T336).
            .reanchor = true,
        };
        // Ownership moves with the transport: `restoreWindow` hands it to the
        // window it builds and frees it itself on every failure path, so the
        // job must not free it a second time.
        p.dialed = null;
        self.restoreWindow(p.win, tr, attach_ptr) catch |err| {
            log.warn("restore all: window '{s}' failed err={}", .{ p.win.id, err });
            continue;
        };
        restored += 1;
    }

    if (restored > 0) {
        log.info("restore all: rebuilt {d} window(s) from the agent's layouts", .{restored});
    } else {
        log.info("restore all: nothing to rebuild ({d} layout(s) held)", .{job.held});
    }
    return restored;
}

/// Snapshot the session ids our panes currently hold on `scope` (null ⇒ this
/// box's agent), deep-copied so a worker thread can use them after this returns.
/// Caller frees each id and the slice — `RestoreAllRelay.Job.destroy` does.
///
/// GUI thread only: it walks the live window tree, which is exactly what a
/// worker may not do.
pub fn openSessionIdsOn(
    self: *const App,
    alloc: Allocator,
    scope: ?Window.RemoteMachine,
) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |id| alloc.free(id);
        out.deinit(alloc);
    }
    for (self.windows.items) |win| {
        if (!windowIsOn(win, scope)) continue;
        for (0..win.tab_count) |t| {
            var it = win.tab_trees[t].iterator();
            while (it.next()) |entry| {
                const surface = entry.view.surface() orelse continue;
                if (!surface.core_surface_ready) continue;
                const sid = surface.core_surface.remoteSessionId() orelse continue;
                if (sid.len == 0) continue;
                try out.append(alloc, try alloc.dupe(u8, sid));
            }
        }
    }
    return out.toOwnedSlice(alloc);
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
    /// The name the FAR machine's layout record has for this session's window
    /// (T1296), or null when it has none.
    name: ?SessionRoster.WindowName,
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
    // The PINNED half rides `openDialedWindow`'s own `title` option (it applies
    // it as an override, which is exactly what a pin is); the unpinned half is
    // applied here, after the window exists, so it lands on the pane's
    // terminal-reported title instead of freezing over it.
    const pinned: ?[]const u8 = if (name) |n| (if (n.pinned) n.text else null) else null;
    const window = try self.openDialedWindow(.{ .relay = dialed }, .{
        .session_id = session_id,
        .machine = .{ .relay = .{ .base = relay_base, .device = device, .token = token } },
        .title = pinned,
    });
    if (pinned == null) applyResumeName(window, name);
    return window;
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
pub fn showRemoteOpenFailed(self: *App, owner: *Window) void {
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

/// The IPC endpoint this app's server actually BOUND, or null when the bind
/// failed and we serve no IPC at all (T118). Every pane is baked with this as
/// `$GHOZTTY_IPC_SOCKET` so a CLI run inside it drives THIS instance instead
/// of whichever build `ghoztty` on `$PATH` happens to be. Null leaves the pane
/// unbaked, i.e. on the CLI's own derivation — the pre-T118 behavior, which is
/// also the only sensible answer when we own no endpoint to name.
pub fn ipcEndpoint(self: *const App) ?[]const u8 {
    if (self.ipc_server) |*server| return server.path;
    return null;
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
                const launched = try autoLaunchInstance(
                    alloc,
                    apprt.ipc.args.autoLaunchDirectory(value.arguments),
                );
                defer std.os.windows.CloseHandle(launched);
                // T118: the instance we just launched is OUR exe, so it binds
                // the DERIVED endpoint — never the one baked into this pane by
                // some other app. Drop the baked value for the retry, or a
                // command run from a surviving pane whose app is gone (session
                // persistence outlives the app by design) would spend the whole
                // backoff dialing a pipe nothing will ever answer on again.
                // Safe to mutate: this is a one-shot CLI process.
                _ = internal_os.unsetenv(apprt.ipc.socket_env);

                // The new instance needs to create its window and bind the
                // pipe; a cold debug start on a busy box can take a while.
                //
                // T755: the budget is a DEADLINE (`ipc_timeout.auto_launch_ms`)
                // rather than a fixed attempt count, and it is nearly three
                // times what the old 20-attempts-of-500ms came to. That budget
                // was reached in the wild — `ipc-p1.ps1`'s first section lost
                // three assertions to one cold auto-launch and passed clean on
                // the re-run, which is indistinguishable from a real
                // regression to whoever runs the floor next.
                //
                // Waiting longer is only safe because the wait now WATCHES the
                // process it started: an instance that dies during startup ends
                // the wait immediately instead of burning the whole budget on a
                // peer that is never coming. A patient wait for a live process
                // and a fast answer about a dead one are the same policy.
                const timeout = internal_os.ipc_timeout;
                var waited_ms: u32 = 0;
                while (true) {
                    std.Thread.sleep(timeout.auto_launch_poll_ms * std.time.ns_per_ms);
                    waited_ms += timeout.auto_launch_poll_ms;
                    return internal_os.ipc_client.sendAction(
                        alloc,
                        comptime action.wireName(),
                        value.arguments,
                    ) catch |retry_err| switch (retry_err) {
                        error.NoRunningInstance => {
                            if (instanceExited(launched)) {
                                log.warn(
                                    "auto-launched instance exited before it answered after {d}ms",
                                    .{waited_ms},
                                );
                                return error.NoRunningInstance;
                            }
                            if (waited_ms < timeout.auto_launch_ms) continue;
                            log.warn(
                                "auto-launched instance did not answer within {d}ms",
                                .{timeout.auto_launch_ms},
                            );
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
///
/// The directory travels on TWO channels, and both are load-bearing (T236):
///
/// - `lpCurrentDirectory` sets the new PROCESS's cwd, which is what the
///   session-persistence agent it spawns inherits — a RELAUNCH of a session
///   that recorded no cwd lands in the agent's directory.
/// - `--working-directory=` on the command line is what the STARTUP window
///   actually honors. Its working directory comes from the resolved config,
///   and since T144 that resolved value is forwarded to the local agent on
///   OPEN — so the process cwd alone never reaches the startup pane. T132
///   shipped with only the first channel and B3 held because the OPEN then
///   carried no cwd at all; T144 closed that hole and exposed this. The
///   resolved default is no longer unconditionally `home` (T506), but this
///   spawn is detached and carries no CLI marker, so it still resolves to
///   `home` — the argument is what makes the answer explicit either way.
/// Returns the new process's handle (T755) so the caller can tell "still
/// starting" from "already dead" while it waits. The caller owns it and must
/// `CloseHandle` it.
fn autoLaunchInstance(alloc: Allocator, cwd: ?[]const u8) apprt.ipc.Errors!std.os.windows.HANDLE {
    const windows = std.os.windows;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Our own exe, and a TEST binary's own exe is the test runner: launching it
    // starts a second copy of the suite instead of an app, detached and outside
    // the lane that made it (T933). The refusal reads as an IPC failure, which
    // is exactly what "no instance could be launched" already means here.
    const exe = internal_os.self_exe.productExePath(&exe_buf) catch return error.IPCFailed;

    // The explicit config argument for the startup window (see above). Best-
    // effort like the wide-encode below: an unrepresentable path just drops
    // the argument, never fails the launch.
    var cwd_arg_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const cwd_arg: ?[]const u8 = if (cwd) |c|
        apprt.ipc.args.autoLaunchCwdArg(&cwd_arg_buf, c)
    else
        null;

    // Quoted, mutable (CreateProcessW may rewrite lpCommandLine), NUL-
    // terminated wide command line.
    var cmd_utf8_buf: [2 * std.fs.max_path_bytes + 128]u8 = undefined;
    const cmd_utf8 = (if (cwd_arg) |a|
        std.fmt.bufPrint(&cmd_utf8_buf, "\"{s}\" {s}", .{ exe, a })
    else
        std.fmt.bufPrint(&cmd_utf8_buf, "\"{s}\"", .{exe})) catch
        return error.IPCFailed;
    var cmd_w: [2 * std.fs.max_path_bytes + 129]u16 = undefined;
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
    windows.CloseHandle(pi.hThread);
    return pi.hProcess;
}

/// Has the process behind `handle` already exited? A zero-millisecond wait is
/// the cheapest "is it still alive" there is, and anything other than a clean
/// signal is answered as "still alive" — a wait we cannot perform must never be
/// the reason a healthy startup is abandoned.
fn instanceExited(handle: std.os.windows.HANDLE) bool {
    const windows = std.os.windows;
    return windows.kernel32.WaitForSingleObject(handle, 0) == windows.WAIT_OBJECT_0;
}

// Not in zig std's kernel32 as of 0.15.2.
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;

/// T245: this process may be `ghoztty.com`, the console-subsystem twin of
/// ghoztty.exe (see src/cli/com_shim.zig). A GUI launch through the twin —
/// no `+action` on the command line — must NOT run the GUI in-process: the
/// caller's shell is WAITING on a console-subsystem child, and a shell must
/// never block on the terminal it just launched. Respawn the sibling
/// ghoztty.exe detached with our command-line tail passed through verbatim,
/// and return true so main exits 0 immediately.
///
/// Called from main_ghostty before the App exists (alongside the relaunch
/// guard). Returns false — run the GUI here after all, a degraded but
/// functional fallback — when this process is not the twin or the respawn
/// cannot be arranged.
pub fn runComShimGuiRespawn(alloc: Allocator) bool {
    const windows = std.os.windows;
    const com_shim = @import("../../cli/com_shim.zig");

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&exe_buf) catch return false;
    if (!com_shim.isComShim(self_path)) return false;

    const dir = std.fs.path.dirname(self_path) orelse return false;
    const sibling = std.fs.path.join(alloc, &.{ dir, "ghoztty.exe" }) catch
        return false;
    defer alloc.free(sibling);
    const sibling_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, sibling) catch
        return false;
    defer alloc.free(sibling_w);

    // `"<sibling>" <tail>` — our raw command line minus argv[0], spliced
    // verbatim so `-e`/`--config` arguments survive byte-exact. Mutable:
    // CreateProcessW may rewrite lpCommandLine.
    const raw_cmd = GetCommandLineW();
    const raw_len = std.mem.len(raw_cmd);
    const tail = raw_cmd[com_shim.commandLineTailIndex(raw_cmd[0..raw_len])..raw_len];
    var cmd: std.ArrayList(u16) = .empty;
    defer cmd.deinit(alloc);
    build: {
        cmd.append(alloc, '"') catch break :build;
        cmd.appendSlice(alloc, sibling_w) catch break :build;
        cmd.append(alloc, '"') catch break :build;
        if (tail.len > 0) {
            cmd.append(alloc, ' ') catch break :build;
            cmd.appendSlice(alloc, tail) catch break :build;
        }
        cmd.append(alloc, 0) catch break :build;

        // T506: tell the child it was launched from a command line, so its
        // `working-directory` default resolves to the directory the user was
        // standing in rather than to home. It cannot work this out for itself:
        // the spawn below is DETACHED, so the child has no console, and the
        // only process that could vouch for it — this one — exits moments
        // later. The child inherits our environment, so the variable is set on
        // US for the duration of the spawn, exactly as `relaunch_guard.arm`
        // does it; the child consumes and clears it (`os.cli_launch`).
        //
        // Best-effort: if the variable cannot be set the respawn still happens
        // and the child just falls back to the pre-T506 default.
        const cli_env_w = std.unicode.utf8ToUtf16LeStringLiteral(
            internal_os.cli_launch.env_var,
        );
        _ = w32.SetEnvironmentVariableW(
            cli_env_w,
            std.unicode.utf8ToUtf16LeStringLiteral("1"),
        );
        defer _ = w32.SetEnvironmentVariableW(cli_env_w, null);

        // Same detached spawn as autoLaunchInstance above, and safe for the
        // same reasons: no handle inheritance (a GUI child holding the
        // caller's pipes would keep them open for its whole life), and
        // App.init clears the inherited ignore-^C flag the process-group
        // flag sets (T84).
        var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
        si.cb = @sizeOf(windows.STARTUPINFOW);
        var pi: windows.PROCESS_INFORMATION = undefined;
        if (windows.kernel32.CreateProcessW(
            null,
            @ptrCast(cmd.items.ptr),
            null,
            null,
            windows.FALSE,
            .{ .detached_process = true, .create_new_process_group = true },
            null,
            null,
            &si,
            &pi,
        ) == 0) break :build;
        windows.CloseHandle(pi.hProcess);
        windows.CloseHandle(pi.hThread);
        return true;
    }

    log.warn(
        "ghoztty.com could not respawn the GUI sibling; running the GUI in-process",
        .{},
    );
    return false;
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
            // this surface isn't currently the active window. Without
            // this, BEL on a backgrounded terminal is invisible.
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                        if (!w32.windowIsActive(win_hwnd)) {
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
                    Window.systemUsesLightTheme(),
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
                    // Return to the configured default (window-width/height
                    // × cell size, Mac returnToDefaultSize parity); 800×600
                    // only when the config never set one (T66). The viewer
                    // chord path reaches the same method (T682).
                    core_surface.rt_surface.parent_window.resetToDefaultSize();
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
                            // 512 units can need 1536 bytes, so a long CJK
                            // title used to panic here — copying a title is
                            // the last thing that should end the app (T990).
                            var utf8_buf: [1024]u8 = undefined;
                            const utf8_len = utf16_text.toUtf8Truncating(&utf8_buf, wbuf[0..wlen]);
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
                    if (surface.core_surface_ready) {
                        surface.setPwd(value.pwd);
                        // T185: this action only ever fires on a REAL OSC 7
                        // report (the initial termio seed pushes no action),
                        // so its arrival is the signal that this shell
                        // tracks its cwd live and the OS-level fallback
                        // (`livePwd`) must stand down.
                        surface.pwd_reported = true;
                    }
                },
            }
            return true;
        },

        // A sequenced binding started, continued or resolved (T446). Each
        // pending key is appended to the pane's key-state model and shown as a
        // key cap in the pill at the pane's bottom; `.end` clears it.
        //
        // This used to be acknowledged and dropped, which meant a pane waiting
        // for the second half of a chord looked exactly like a pane that had
        // ignored the first half.
        .key_sequence => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface = core_surface.rt_surface;
                switch (value) {
                    .trigger => |t| surface.key_state_model.pushTrigger(t),
                    .end => surface.key_state_model.endSequence(),
                }
                surface.updateKeyStateIndicator();
                return true;
            },
        },

        // A key table was entered or left (T446). Tables NEST, so this is a
        // stack: `.activate` pushes, `.deactivate` pops one, `.deactivate_all`
        // clears — mirroring `Surface.keyboard.table_stack` in the core, which
        // the apprt never sees directly.
        .key_table => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                const surface = core_surface.rt_surface;
                switch (value) {
                    .activate => |name| surface.key_state_model.activate(name),
                    .deactivate => surface.key_state_model.deactivate(),
                    .deactivate_all => surface.key_state_model.deactivateAll(),
                }
                surface.updateKeyStateIndicator();
                return true;
            },
        },

        // Acknowledge actions that don't need Win32-specific handling.
        // The core handles the logic; we just confirm receipt.
        .cell_size,
        // Platform-specific actions that don't apply on Windows:
        .secure_input, // macOS EnableSecureEventInput
        .undo, // macOS NSUndoManager
        .redo, // macOS NSUndoManager
        .show_gtk_inspector, // GTK-only
        .show_on_screen_keyboard, // GTK/mobile
        .inspector, // Not yet implemented (debug overlay)
        .render_inspector, // Not yet implemented (debug overlay)
        => return true,

        // Read-only mode changed (T445). The core has already flipped
        // `core_surface.readonly`; all this has to do is let the pane
        // re-derive its badge from that state. It used to be acknowledged
        // and dropped, which is why a read-only pane on Windows was
        // indistinguishable from a wedged one.
        .readonly => switch (target) {
            .app => return false,
            .surface => |core_surface| {
                core_surface.rt_surface.updateReadonlyBadge();
                return true;
            },
        },

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
                    const window = core_surface.rt_surface.parent_window;
                    // The quick terminal topmosts itself as part of how it
                    // works; letting this action fight it would leave it
                    // sliding under other windows. Mac refuses for the same
                    // reason (`validateMenuItem` in AppDelegate.swift), and
                    // the menu row is grayed here to match — this is the
                    // guard for the palette and a keybind, which are not.
                    if (window.is_quick_terminal) return true;
                    const win_hwnd = window.hwnd orelse return true;
                    const ex = w32.GetWindowLongPtrW(win_hwnd, w32.GWL_EXSTYLE);
                    const is_topmost = (ex & @as(isize, w32.WS_EX_TOPMOST)) != 0;
                    const want: bool = switch (value) {
                        .on => true,
                        .off => false,
                        .toggle => !is_topmost,
                    };
                    if (want == is_topmost) return true;
                    // Not a bare SetWindowPos: the API reports success on a
                    // band change it did not make when there is no foreground
                    // window, which is what made this action look like it did
                    // nothing from a keybind while working from the menu
                    // (T277). `setTopmost` reads the ex-style back.
                    _ = w32.setTopmost(win_hwnd, want);
                    // Changing bands moves every popup this window owns —
                    // the OS drags them along, but only as far as the band,
                    // not to the seat directly above their owner. Re-check
                    // them so a banner cannot end up over another app on the
                    // way in, or under a foreign window on the way out (the
                    // T142 invariant, from the other direction).
                    window.healOverlayZOrders();
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
                            if (!w32.windowIsActive(win_hwnd)) {
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
/// wparam = heap ptr to an `UpdateFound` the handler takes ownership of.
/// wparam == 0 carries manual-check feedback instead: lparam 0 = up to
/// date, 1 = check failed, 2 = a download failed (only posted for checks the
/// user asked for, or for a download the user consented to).
const WM_APP_UPDATE_AVAILABLE: u32 = w32.WM_APP + 2;

/// What a completed update check hands the GUI thread. Heap-allocated and
/// handed over by pointer rather than assembled from wparam/lparam widths:
/// there are three owned strings now, and a static buffer here would be a
/// race between the worker writing and the message thread reading.
const UpdateFound = struct {
    /// The newer release's version text ("1.5.0").
    version: []u8,
    /// Its `.msi` asset URL, or null when the release has no installable
    /// package (then the offer degrades to opening the release page).
    asset_url: ?[]u8,
    /// A verified package already on disk, when `auto-update = download`
    /// fetched it in the background.
    staged_msi: ?[]u8,

    fn destroy(self: *UpdateFound, alloc: Allocator) void {
        alloc.free(self.version);
        if (self.asset_url) |u| alloc.free(u);
        if (self.staged_msi) |p| alloc.free(p);
        alloc.destroy(self);
    }
};

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
/// removing the other's icon. The uIDs live in `tray_notify.zig` beside the
/// decode that reads them back off the callback message.
const NOTIF_DESKTOP_UID: u32 = tray_notify.desktop_uid;
const NOTIF_DESKTOP_TIMER_ID: usize = 2;
const NOTIF_UPDATE_UID: u32 = tray_notify.update_uid;
const NOTIF_UPDATE_TIMER_ID: usize = 3;
const NOTIF_ORPHAN_UID: u32 = tray_notify.orphan_uid;
const NOTIF_ORPHAN_TIMER_ID: usize = 8;
const NOTIF_STALE_UID: u32 = tray_notify.stale_build_uid;
const NOTIF_STALE_TIMER_ID: usize = 13;

/// Register a notification-area icon's behavior version, which is what turns
/// the `NIN_*` balloon notifications on. Without it the icon keeps the
/// shell's default pre-5.0 behavior and a balloon click is delivered to
/// nobody — see `tray_notify.zig` for the full story. MSDN: *"NIM_SETVERSION
/// must be called every time a notification area icon is added (NIM_ADD)"*,
/// and the setting does not survive a logoff, so every balloon re-applies it.
/// `added` is what NIM_ADD returned, and it is in the failure message on
/// purpose: SETVERSION addresses an icon by (hWnd, uID), so it fails for an
/// icon that was never created — which is the whole story on a desktop with
/// no shell (a background test desktop, a session with explorer down), where
/// there is no notification area to add to and nothing is wrong with us.
fn setNotifyIconVersion(hwnd: w32.HWND, uid: u32, added: bool) void {
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = uid;
    // The union is uVersion for THIS message and uTimeout for the others,
    // which is why this cannot ride along on the NIM_ADD struct.
    nid.uVersion_or_uTimeout = w32.NOTIFYICON_VERSION;
    if (w32.Shell_NotifyIconW(w32.NIM_SETVERSION, &nid) == 0) {
        log.warn(
            "NIM_SETVERSION failed for tray uid={d} (NIM_ADD {s}); balloon clicks will not be delivered",
            .{ uid, if (added) "succeeded" else "failed too" },
        );
    }
}

/// Minimum interval between update checks, in seconds. The check
/// timestamp is persisted in %LOCALAPPDATA%/ghostty/update_check_at.
const UPDATE_CHECK_INTERVAL_SECS: i64 = 60 * 60; // 1 hour

/// How an update check was requested. Automatic checks (app launch) are
/// gated and throttled; manual checks (`check_for_updates` action) always
/// run and report their outcome in a balloon.
const UpdateTrigger = enum { automatic, manual };

/// What `auto-update` asks this platform to do (T1178). Unset means
/// `download`, which is Sparkle's default on the Mac and therefore what
/// "update it like the normal mac ghoztty" means here.
fn updatePolicy(self: *const App) update_apply.Policy {
    const name: ?[]const u8 = if (self.config.@"auto-update") |au| @tagName(au) else null;
    return update_apply.policyFromName(name);
}

/// Start a background thread to check for updates (T24, extended by T1178
/// from notify-only to notify-download-install).
///
/// Automatic checks run only where an update is the right thing to offer:
/// a build stamped with -Dwindows-update-check (the MSI release pipeline
/// sets it), OR any non-Debug build RUNNING FROM the installed-release
/// folder. Portable unpacks and `zig-out` dev builds still never phone home
/// or nag. Checks honor `auto-update = off` and are throttled to one fetch
/// per UPDATE_CHECK_INTERVAL_SECS. The GHOZTTY_UPDATE_URL env override
/// (acceptance-test hook) force-enables the automatic check and bypasses the
/// throttle. Manual checks skip all gates: an explicit user action deserves
/// an answer.
///
/// The location clause is T1217. The build flag alone answers "did the MSI
/// pipeline make these bytes?", and that stopped being the same question as
/// "is this the user's installed terminal" the day the loop's morning refresh
/// started writing a script-built exe over the install: on 2026-08-31 a
/// terminal installed from the website at 07:08 could no longer find updates
/// at 07:49, with nothing on screen to say so. The same staging bytes go to
/// the portable copies too, so the answer could not be moved into the build —
/// it has to be about where the exe is, which is what `install_location`
/// answers.
fn startUpdateCheck(self: *App, trigger: UpdateTrigger) void {
    if (trigger == .automatic) {
        const overridden = envUpdateUrlIsSet(self.core_app.alloc);
        if (!self.autoUpdateCheckAllowed() and !overridden) return;
        if (self.updatePolicy() == .off) {
            log.info("update check disabled (auto-update = off)", .{});
            return;
        }
        if (!overridden and !self.shouldRunUpdateCheck()) {
            log.debug("skipping update check (last run within {d}s)", .{UPDATE_CHECK_INTERVAL_SECS});
            return;
        }
    }

    // What the user has already been told about, copied HERE (T1171). The
    // repeating check would otherwise re-offer the same release every hour,
    // and the worker cannot read `update_latest_ver` itself: that field is the
    // GUI thread's, written by `showUpdateNotification`, and a worker reading
    // it while a later notification replaced it is a use-after-free rather
    // than a stale answer. A manual check passes null on purpose - the user
    // asked, so they get an answer even if it is one they have seen.
    const already_offered: ?[]u8 = if (trigger == .automatic and self.update_latest_ver != null)
        (self.core_app.alloc.dupe(u8, self.update_latest_ver.?) catch null)
    else
        null;

    _ = std.Thread.spawn(.{}, updateCheckThread, .{ self, trigger, already_offered }) catch |err| {
        log.warn("failed to start update check thread: {}", .{err});
        if (already_offered) |o| self.core_app.alloc.free(o);
    };
}

/// How long between automatic re-checks (T1171). Debug builds honor
/// GHOZTTY_UPDATE_RECHECK_MS so the acceptance script can watch a second tick
/// arrive; release builds always use `UPDATE_RECHECK_MS`.
fn updateRecheckIntervalMs(self: *App) u32 {
    const v = orphanEnvMs(
        self.core_app.alloc,
        "GHOZTTY_UPDATE_RECHECK_MS",
        UPDATE_RECHECK_MS,
    );
    return @intCast(std.math.clamp(v, 500, std.math.maxInt(u32)));
}

/// Whether THIS exe may run an automatic update check (T1217).
///
/// Debug builds are excluded outright even from the location clause: a debug
/// build derives its own endpoints and state dir on purpose, and one that
/// happened to be copied into the install folder must not start acting like
/// the user's product.
fn autoUpdateCheckAllowed(self: *const App) bool {
    var arena = std.heap.ArenaAllocator.init(self.core_app.alloc);
    defer arena.deinit();
    return install_location.autoUpdateCheckEnabled(arena.allocator());
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
fn updateCheckThread(app: *App, trigger: UpdateTrigger, already_offered: ?[]u8) void {
    const alloc = app.core_app.alloc;
    const manual = trigger == .manual;
    defer if (already_offered) |o| alloc.free(o);

    var release = fetchLatestWinRelease(alloc) catch |err| switch (err) {
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
    if (!update_check.isNewer(current_sv, release.version)) {
        log.info("update check: up to date (current={s} latest=win-v{s})", .{
            build_config.version_string, release.version,
        });
        release.deinit(alloc);
        if (manual) postUpdateFeedback(app, 0);
        return;
    }
    log.info("update available: current={s} latest=win-v{s} msi={s}", .{
        build_config.version_string,
        release.version,
        release.asset_url orelse "(none published)",
    });

    // Already offered this exact version, so say nothing (T1171). Returning
    // before the pre-download matters as much as before the balloon: a
    // deferred update would otherwise re-fetch its package every tick.
    if (!update_check.shouldNotify(already_offered, release.version)) {
        log.info("update check: win-v{s} already offered; not re-notifying", .{release.version});
        release.deinit(alloc);
        return;
    }

    // `auto-update = download` (the default) fetches the package here, on the
    // worker, so the click that follows the balloon installs immediately
    // instead of starting a transfer the user waits through. A download that
    // fails is not an error the user is shown: the notification still goes
    // out, and the click path downloads again with feedback.
    var staged: ?[]u8 = null;
    if (app.updatePolicy() == .download) {
        if (release.asset_url) |url| {
            // No progress panel here: this download is unprompted background
            // work the user did not ask for and is not waiting on. The panel
            // belongs to the click path, where somebody IS waiting (T1195).
            staged = update_install.download(alloc, url, release.version, null) catch |err| blk: {
                log.warn("update pre-download failed: {}", .{err});
                break :blk null;
            };
        }
    }
    if (staged != null) log.info("update staged for win-v{s}", .{release.version});

    const found = alloc.create(UpdateFound) catch {
        if (staged) |p| alloc.free(p);
        release.deinit(alloc);
        return;
    };
    found.* = .{
        .version = release.version,
        .asset_url = release.asset_url,
        .staged_msi = staged,
    };

    const hwnd = app.msg_hwnd orelse {
        found.destroy(alloc);
        return;
    };

    // Hand ownership of the heap payload to the message handler. This avoids a
    // static-buffer race between this worker thread writing and the message
    // thread reading.
    if (w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, @intFromPtr(found), 1) == 0) {
        // PostMessage failed (e.g., HWND already destroyed). Free here since
        // the handler will never run.
        found.destroy(alloc);
    }
}

/// Post manual-check feedback to the GUI thread: code 0 = up to date,
/// 1 = check failed, 2 = a consented download failed (see
/// WM_APP_UPDATE_AVAILABLE's encoding).
fn postUpdateFeedback(app: *App, code: isize) void {
    const hwnd = app.msg_hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, 0, code);
}

/// Worker for a download the user consented to at the balloon (the
/// `auto-update = check` path, or a background pre-download that failed).
/// Posts the staged package back so the GUI thread can install it.
///
/// `shared` is the progress channel the panel reads (T1195); this thread
/// holds one of its two references and releases it on every exit, including
/// the failure paths, so a panel that has already closed frees it here.
fn updateDownloadThread(app: *App, version: []u8, url: []u8, shared: *update_progress.Shared) void {
    const alloc = app.core_app.alloc;
    defer alloc.free(version);
    defer alloc.free(url);
    defer shared.release(alloc);

    const staged: []u8 = update_install.download(alloc, url, version, .{
        .ctx = shared,
        .report = reportUpdateProgress,
    }) catch |err| {
        log.warn("update download failed: {}", .{err});
        shared.finish(.failed);
        postUpdateFeedback(app, 2);
        return;
    };
    shared.finish(.ok);

    const found = alloc.create(UpdateFound) catch {
        alloc.free(staged);
        return;
    };
    found.* = .{
        .version = alloc.dupe(u8, version) catch {
            alloc.destroy(found);
            alloc.free(staged);
            return;
        },
        .asset_url = null,
        .staged_msi = staged,
    };

    const hwnd = app.msg_hwnd orelse {
        found.destroy(alloc);
        return;
    };
    // lparam 2 = "the user already consented; install it".
    if (w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, @intFromPtr(found), 2) == 0) {
        found.destroy(alloc);
    }
}

/// `update_install.Progress` shim: two relaxed atomic stores, called from the
/// download thread after every chunk. Deliberately does nothing else — the
/// panel's timer is what turns these numbers into pixels, so the transfer
/// never waits on a repaint.
fn reportUpdateProgress(ctx: *anyopaque, received: u64, total: u64) void {
    const shared: *update_progress.Shared = @ptrCast(@alignCast(ctx));
    shared.report(received, total);
}

/// Show a notification balloon that an update is available. Remembers the
/// version so a balloon click opens that release's GitHub page. The caller
/// (message handler) still owns and frees `ver`.
fn showUpdateNotification(self: *App, found: *UpdateFound) void {
    if (found.version.len == 0) return;
    log.info("showing update balloon for win-v{s}", .{found.version});

    const alloc = self.core_app.alloc;
    if (self.update_latest_ver) |old| alloc.free(old);
    self.update_latest_ver = alloc.dupe(u8, found.version) catch null;
    if (self.update_asset_url) |old| alloc.free(old);
    self.update_asset_url = if (found.asset_url) |u| (alloc.dupe(u8, u) catch null) else null;
    if (self.update_staged_msi) |old| alloc.free(old);
    self.update_staged_msi = if (found.staged_msi) |p| (alloc.dupe(u8, p) catch null) else null;

    // Three sentences, one per state, because they promise different things:
    // a staged package installs on the spot, an asset still has to be fetched,
    // and a release with neither is the old notify-only outcome.
    var body_utf8: [256]u8 = undefined;
    const body = if (self.update_staged_msi != null) std.fmt.bufPrint(
        &body_utf8,
        "Version {s} is ready to install.\nClick to install and restart.",
        .{found.version},
    ) catch return else if (self.update_asset_url != null) std.fmt.bufPrint(
        &body_utf8,
        "Version {s} is available.\nClick to download and install.",
        .{found.version},
    ) catch return else std.fmt.bufPrint(
        &body_utf8,
        "Version {s} is available.\nClick to open the download page.",
        .{found.version},
    ) catch return;
    self.showUpdateBalloon("Ghoztty Update Available", body);
}

/// Show manual-check feedback: code 0 = up to date, 2 = a download the user
/// consented to failed, anything else = the check itself failed.
fn showUpdateFeedback(self: *App, code: isize) void {
    if (code == 0) {
        var body_utf8: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_utf8,
            "Ghoztty is up to date (version {s}).",
            .{build_config.version_string},
        ) catch return;
        self.showUpdateBalloon("Ghoztty", body);
    } else if (code == 2) {
        self.update_download_inflight = false;
        self.showUpdateBalloon("Ghoztty", "The update could not be downloaded.\nClick to open the releases page.");
    } else {
        self.showUpdateBalloon("Ghoztty", "Could not check for updates.\nClick to open the releases page.");
    }
}

/// Act on a click of the update balloon (T1178). Returns true when the click
/// was handled as an offer to install — false means there is nothing
/// installable and the caller should fall back to opening the release page,
/// which is exactly what this notification did before there was an installer.
///
/// The confirmation is mandatory and it is Ghoztty's own dialog rather than
/// msiexec's: what the user is consenting to is their terminal CLOSING, and
/// that sentence has to be said by the thing that is about to close.
fn offerUpdate(self: *App) bool {
    const alloc = self.core_app.alloc;
    const ver = self.update_latest_ver orelse return false;
    if (self.update_staged_msi == null and self.update_asset_url == null) return false;

    if (self.update_download_inflight) {
        self.showUpdateBalloon("Ghoztty", "The update is still downloading.");
        return true;
    }

    var text_buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &text_buf,
        "Ghoztty {s} is available. You have {s}.\n\n" ++
            "Ghoztty will close, install the update and reopen. " ++
            "Your terminal sessions are kept.",
        .{ ver, build_config.version_string },
    ) catch return false;
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return false;
    defer alloc.free(text_w);

    const owner: ?*Window = if (self.windows.items.len > 0) self.windows.items[0] else null;
    if (owner) |win| {
        if (win.hwnd) |wh| _ = w32.SetForegroundWindow(wh);
    }
    const result = ConfirmDialog.show(
        self,
        if (owner) |win| win.hwnd else null,
        if (owner) |win| win.scale else 1.0,
        if (owner) |win| (if (win.getActiveSurface()) |s| s.hwnd else null) else null,
        .{
            .title = std.unicode.utf8ToUtf16LeStringLiteral("Update Ghoztty"),
            .text = text_w,
            .icon = .info,
            .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Install and Restart"),
            .cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Later"),
        },
    );
    if (result != .ok) {
        log.info("update: user deferred win-v{s}", .{ver});
        return true;
    }

    // Already downloaded (the `auto-update = download` default): install now.
    if (self.update_staged_msi != null) {
        self.applyStagedUpdate();
        return true;
    }

    // `auto-update = check`: fetch it, then install without asking again —
    // consent was given for the whole operation, not for the download.
    const url = self.update_asset_url orelse return true;
    const ver_copy = alloc.dupe(u8, ver) catch return true;
    const url_copy = alloc.dupe(u8, url) catch {
        alloc.free(ver_copy);
        return true;
    };
    // The progress channel (T1195): two holders, the worker and the panel,
    // whichever outlives the other frees it. Allocated before the thread so a
    // failure to allocate never leaves a thread reporting into nothing.
    const shared = alloc.create(update_progress.Shared) catch {
        alloc.free(ver_copy);
        alloc.free(url_copy);
        return true;
    };
    shared.* = .{};

    self.update_download_inflight = true;
    _ = std.Thread.spawn(.{}, updateDownloadThread, .{ self, ver_copy, url_copy, shared }) catch |err| {
        log.warn("failed to start update download thread: {}", .{err});
        self.update_download_inflight = false;
        alloc.free(ver_copy);
        alloc.free(url_copy);
        // Both references are ours to drop: no worker, and no panel yet.
        shared.release(alloc);
        shared.release(alloc);
        return true;
    };

    // A panel instead of the one-shot balloon this path used to show. It is
    // self-managing: it ticks on its own timer and closes itself when the
    // download reaches a terminal state, so nothing here holds a pointer to
    // it. A window that fails to open costs the report, not the update - the
    // balloon is still there to say something happened.
    if (UpdateProgress.create(
        alloc,
        self,
        self.hinstance,
        if (owner) |win| win.hwnd else null,
        if (owner) |win| win.scale else 1.0,
        ver,
        shared,
    ) == null) {
        shared.release(alloc);
        self.showUpdateBalloon("Ghoztty", "Downloading the update…");
    }
    return true;
}

/// Hand the staged package to a detached applier and quit. Everything after
/// this point happens in `update_install.zig`, outside this process, because
/// the file being replaced is the one this process is running from.
///
/// A refusal here is loud and NON-destructive: if the applier cannot be armed
/// the app does not quit, so the user keeps the terminal they have.
fn applyStagedUpdate(self: *App) void {
    const msi = self.update_staged_msi orelse return;
    if (!update_install.arm(self.core_app.alloc, msi)) {
        self.showUpdateBalloon(
            "Ghoztty",
            "The update could not be started.\nClick to open the releases page.",
        );
        return;
    }
    log.warn("update: applier armed, quitting to install", .{});
    self.quit_requested = true;
    w32.PostQuitMessage(0);
}

/// Ask whether a newer build is on disk, and say so once when it is (T1205).
///
/// This is the "unprompted" half of the answer to *"I think I'm on the newest
/// build but I'm not sure."* About tells anyone who opens it; nobody opens it
/// unless they already suspect something. So the app volunteers it — once per
/// build that appears on disk, on the same tray-balloon surface an available
/// update already uses, and with the same click-to-act contract.
fn checkStaleBuild(self: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(self.core_app.alloc);
    defer arena_state.deinit();
    const prov = provenance.collect(arena_state.allocator()) catch return;
    if (!prov.newer_build_installed) return;

    // Remember the FILE's timestamp, not a bool: a second upgrade landing
    // while the window is still open is a new fact and deserves to be said
    // again, while the same file must never be announced twice.
    const on_disk_ns = staleBuildOnDiskNs(prov.exe);
    if (on_disk_ns == 0 or on_disk_ns == self.stale_build_notified_ns) return;
    self.stale_build_notified_ns = on_disk_ns;

    log.info(
        "newer build installed on disk (running build started {s}, exe written {s})",
        .{ prov.started, prov.exe_modified },
    );
    self.showTrayBalloon(
        NOTIF_STALE_UID,
        NOTIF_STALE_TIMER_ID,
        "Ghoztty Was Updated",
        "This window is still running the older build.\nClick to restart into the new one.",
    );
}

/// The on-disk mtime of `exe` in nanoseconds, or 0 when it cannot be read.
/// Separate from `provenance.collect` because the balloon needs the raw
/// number to dedupe on, and provenance hands back the formatted string a
/// human reads.
fn staleBuildOnDiskNs(exe: []const u8) i128 {
    const f = std.fs.openFileAbsolute(exe, .{}) catch return 0;
    defer f.close();
    const st = f.stat() catch return 0;
    return st.mtime;
}

/// Start the newer build and quit this one (T1205).
///
/// The order is deliberate: SPAWN FIRST, and only quit if the spawn worked.
/// A failure here must leave the user with the terminal they already have —
/// the same rule `applyStagedUpdate` follows, for the same reason. The new
/// process is detached and escapes this app's job object, or the job teardown
/// that follows our exit would kill the replacement along with us (T524).
///
/// Sessions survive: the agent owns the PTYs, and the relaunched app
/// re-attaches them exactly as it does after a logoff or a Restart Manager
/// close.
pub fn restartIntoInstalledBuild(self: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(self.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = std.fs.selfExePathAlloc(arena) catch |err| {
        log.err("restart into new build: cannot resolve own exe: {}", .{err});
        return;
    };
    const cmd = std.fmt.allocPrint(arena, "\"{s}\"", .{exe}) catch return;
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(arena, cmd) catch return;

    const spawned = job_spawn.spawnEscapingJob(
        arena,
        cmd_w.ptr,
        job_spawn.DETACHED_PROCESS,
        "restart into new build",
    ) catch |err| {
        log.err("restart into new build: spawn of {s} FAILED: {}", .{ exe, err });
        self.showTrayBalloon(
            NOTIF_STALE_UID,
            NOTIF_STALE_TIMER_ID,
            "Ghoztty",
            "Could not restart automatically.\nQuit and reopen Ghoztty to use the new build.",
        );
        return;
    };
    const pid = w32.GetProcessId(spawned.pi.hProcess);
    std.os.windows.CloseHandle(spawned.pi.hProcess);
    std.os.windows.CloseHandle(spawned.pi.hThread);
    log.warn("restart into new build: launched pid {d} (escape={s}), quitting", .{
        pid,
        spawned.tier.name(),
    });

    self.quit_requested = true;
    w32.PostQuitMessage(0);
}

/// Show a balloon on the update tray icon. A click is delivered as
/// WM_APP_TRAY (NOTIF_UPDATE_UID) → opens the release page.
fn showUpdateBalloon(self: *App, title_utf8: []const u8, body_utf8: []const u8) void {
    self.showTrayBalloon(NOTIF_UPDATE_UID, NOTIF_UPDATE_TIMER_ID, title_utf8, body_utf8);
}

/// Show a balloon on `uid`'s tray icon, cleaned up by `timer_id`. A click is
/// delivered as WM_APP_TRAY and routed by uid (`tray_notify.classify`).
/// Title/body must fit the NOTIFYICONDATAW limits (64/256 UTF-16 units incl.
/// nul); longer text is dropped rather than truncated mid-rune.
fn showTrayBalloon(
    self: *App,
    uid: u32,
    timer_id: usize,
    title_utf8: []const u8,
    body_utf8: []const u8,
) void {
    const hwnd = self.msg_hwnd orelse return;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = uid;
    // NIF_MESSAGE registers our callback so a click on the balloon
    // is delivered as WM_APP_TRAY.
    // NIF_INFO (the balloon itself) is added only after NIM_SETVERSION below.
    nid.uFlags = w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
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

    // Add the icon, register the version, THEN show the balloon. The order is
    // the point: the version must be set before the balloon exists, or the
    // click that dismisses it is handled under the default (Windows 95)
    // behavior and never reaches WM_APP_TRAY.
    const added = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid) != 0;
    setNotifyIconVersion(hwnd, uid, added);
    nid.uFlags |= w32.NIF_INFO;
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
    _ = w32.SetTimer(hwnd, timer_id, 10000, null);
}

/// Response-size cap for the releases-list fetch. Release notes can be
/// large; 30 releases with long bodies stay well under this.
const UPDATE_RESPONSE_MAX: usize = 1024 * 1024;

/// The newest published Windows release, as far as the feed describes it.
/// Both fields are caller-owned.
const LatestRelease = struct {
    /// Version text, e.g. "1.4.1".
    version: []u8,
    /// Its `.msi` asset URL, or null when the release published none — an
    /// update that can be announced but not installed.
    asset_url: ?[]u8,

    fn deinit(self: *LatestRelease, alloc: Allocator) void {
        alloc.free(self.version);
        if (self.asset_url) |u| alloc.free(u);
        self.* = undefined;
    }
};

/// Fetch the releases list from GitHub (or GHOZTTY_UPDATE_URL) and return the
/// newest win-v release: its version text and, when the release carries one,
/// the download URL of its MSI. error.NoWinRelease if the feed has no win-v
/// tag.
fn fetchLatestWinRelease(alloc: Allocator) !LatestRelease {
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
        return try releaseFromFeed(alloc, data);
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

    return try releaseFromFeed(alloc, body.items);
}

/// Pull the newest win-v release out of a releases-list body. Shared by both
/// arms of `fetchLatestWinRelease` so the canned `file://` feed the acceptance
/// test serves is parsed by exactly the code the network path uses.
fn releaseFromFeed(alloc: Allocator, data: []const u8) !LatestRelease {
    const ver = update_check.findLatestWinVersion(data) orelse return error.NoWinRelease;
    const version = try alloc.dupe(u8, ver);
    errdefer alloc.free(version);
    const asset_url: ?[]u8 = if (update_apply.findMsiUrl(data, ver)) |u|
        try alloc.dupe(u8, u)
    else
        null;
    return .{ .version = version, .asset_url = asset_url };
}

/// Was this process started as the agent-refresh relaunch guard (T421)? If so,
/// run it and hand `main` the exit code — a guard never becomes a terminal.
///
/// A DECL on the apprt so `main_ghostty.zig` reaches it the same way it reaches
/// `startQuitTimer`, instead of importing a win32 module directly.
pub fn runRelaunchGuard(alloc: Allocator) ?u8 {
    return relaunch_guard.runFromEnv(alloc);
}

/// Was this process started as the update applier (T1178)? If so, run it and
/// hand `main` the exit code — an applier never becomes a terminal. It is a
/// COPY of ghoztty.exe living in the staging directory, precisely so the
/// installed exe it is about to replace is not open.
///
/// A DECL on the apprt for the same reason `runRelaunchGuard` is one.
pub fn runUpdateApplier(alloc: Allocator) ?u8 {
    return update_install.runFromEnv(alloc);
}

/// Was this process started as an installer prepare step (T1207)? If so, run
/// it and hand `main` the exit code — a prepare step never becomes a terminal.
/// msiexec runs it out of INSTALLDIR immediately before the Restart Manager is
/// asked who holds the files being replaced, so that the answer does not
/// include the processes owning the user's live shells.
///
/// A DECL on the apprt for the same reason `runRelaunchGuard` is one.
pub fn runInstallPrepare(alloc: Allocator) ?u8 {
    return install_prepare.runFromArgs(alloc);
}

/// Was this process started as the installer's maintenance prompt (T1291)? If
/// so, ask and hand `main` the exit code — a prompt never becomes a terminal.
/// msiexec runs it out of INSTALLDIR when the SAME version is already
/// installed, which is the case that used to end with the installer vanishing
/// without a word. The Cancel answer never comes back here: it leaves the
/// process with 1602, which is wider than the `u8` `main` exits with.
///
/// A DECL on the apprt for the same reason `runRelaunchGuard` is one.
pub fn runInstallMaintenance(alloc: Allocator) ?u8 {
    return install_maintenance.runFromArgs(alloc);
}

/// Was this process started as the installer's RESTART OFFER (T1352)? If so,
/// make the offer and hand `main` the exit code — an offer never becomes a
/// terminal. msiexec runs it out of INSTALLDIR after the files have been
/// replaced, because the exe it has just written is the only process on the box
/// guaranteed to contain code new enough to say that the windows on screen are
/// running the old build.
///
/// A DECL on the apprt for the same reason `runRelaunchGuard` is one.
pub fn runInstallRestart(alloc: Allocator) ?u8 {
    return install_restart.runFromArgs(alloc);
}

/// T675: is this process inside a kill-on-close job it does not own — the
/// agent's PTY job, when the app is launched from inside a pane? If so,
/// respawn outside it and tell `main` to exit: the escaped twin is THE app,
/// and this jailed one must not create a single window. Without this, the
/// destructive agent refresh tears the app down mid-kill (T268's mechanism).
///
/// A DECL on the apprt for the same reason as `runRelaunchGuard`:
/// `main_ghostty` reaches it without importing a win32 module directly.
pub fn escapeHostileJobAtStartup(alloc: Allocator) bool {
    return job_escape.escapeAtStartup(alloc);
}

/// Was this process launched BY a `ghoztty://` link (T695)? If so, focus what
/// the link names and hand `main` the exit code — an activation never becomes a
/// terminal, and in particular never forwards a `new-window` to the running
/// instance the way an ordinary second launch does.
///
/// A DECL on the apprt for the same reason as `runRelaunchGuard`: `main_ghostty`
/// reaches it without importing a win32 module directly.
pub fn runUrlSchemeActivation(alloc: Allocator) ?u8 {
    return url_scheme.runActivation(alloc);
}

/// Focus what a `ghoztty://` link clicked INSIDE Ghoztty names — a banner link,
/// a viewer page's link or popup. Handled in process so it always means "this
/// app" rather than "whichever build registered the scheme", which is what lets
/// a generated document hardcode `ghoztty://` and still work in a debug build.
pub fn handleUrlSchemeLink(
    self: *App,
    owner: ?w32.HWND,
    scale: f32,
    url: []const u8,
) bool {
    return url_scheme.handleInApp(self, owner, scale, url);
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

/// Tell the user that the window they just got belongs to a DIFFERENT build
/// than the one they started (T1022). A balloon rather than a dialog: the
/// window is already open and usable, so this is information, not a decision —
/// and a modal here would block the launch the user is watching for.
///
/// Text is bounded by `ipc_handoff.mismatchNotice`, which sizes the body for
/// `szInfo`; the copies below are the same ones every other notification makes.
pub fn showLaunchHandoffNotice(self: *App, title: []const u8, body: []const u8) void {
    self.showDesktopNotificationText(title, body);
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
    // NIF_INFO (the balloon itself) is added only after NIM_SETVERSION below.
    nid.uFlags = w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
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

    // Add the icon, register the version, then show the balloon (the icon is
    // removed by the timer below). The order is the point: the version must be
    // set before the balloon exists, or the click that dismisses it is handled
    // under the shell's default (Windows 95) behavior and never reaches
    // WM_APP_TRAY — which is what made click-to-focus dead code until T448.
    const added = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid) != 0;
    setNotifyIconVersion(hwnd, NOTIF_DESKTOP_UID, added);
    nid.uFlags |= w32.NIF_INFO;
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);

    // Schedule icon removal via a timer (distinct from the update
    // notification's timer so the two don't trample each other).
    _ = w32.SetTimer(hwnd, NOTIF_DESKTOP_TIMER_ID, 6000, null);
}

// -----------------------------------------------------------------------
// Long-unattached session notification (T534)
// -----------------------------------------------------------------------
//
// The agent keeps a pinned live session FOREVER once nothing shows it — that
// keep-forever default is the contract (D18: never silently reap) — so
// discovery is the app's job: a periodic check reads the local roster, and a
// session continuously unattached past a generous threshold earns one tray
// balloon naming it. Clicking the balloon opens the machine chooser, where the
// T520 "not in any window" badge marks the session and Resume / Kill already
// live; ignoring or dismissing it IS "Keep" — a per-episode stamp keeps that
// episode quiet for a long while, and only an ATTACH (which resets the agent's
// clock) starts a new episode. Policy is pure in `orphan_notify.zig`.

/// Heap box a finished orphan-check worker posts back to the GUI thread.
const OrphanRosterResult = struct {
    alloc: Allocator,
    roster: ?remote_connection.OwnedSessions,

    fn destroy(self: *OrphanRosterResult) void {
        if (self.roster) |*r| r.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

/// Bounded worker-side RPC budget; a wedged agent costs one missed check, not
/// a parked thread per tick (the inflight flag holds until the reply lands).
const orphan_rpc_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// Debug-only cadence/threshold override (acceptance seam). Release builds run
/// the hard-coded policy — D18 ruled out config knobs, and these are not
/// knobs: they exist so a test can watch a "24 hours later" story in seconds.
///
/// Named for the check it was written for; the update re-check (T1171) uses it
/// too, for exactly the same reason and under the same debug-only rule.
fn orphanEnvMs(alloc: Allocator, name: []const u8, default_val: i64) i64 {
    if (comptime !build_config.is_debug) return default_val;
    const v = std.process.getEnvVarOwned(alloc, name) catch return default_val;
    defer alloc.free(v);
    const parsed = std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10) catch return default_val;
    return if (parsed > 0) parsed else default_val;
}

fn orphanCheckIntervalMs(self: *App) u32 {
    const v = orphanEnvMs(
        self.core_app.alloc,
        "GHOZTTY_ORPHAN_CHECK_MS",
        orphan_notify.default_check_interval_ms,
    );
    return @intCast(std.math.clamp(v, 500, std.math.maxInt(u32)));
}

/// Kick one background read of the local agent's roster for the check. Never
/// spawns an agent — a notifier must not start a daemon any more than browsing
/// does (SessionRoster's rule) — and never blocks the GUI thread.
fn startOrphanCheck(self: *App) void {
    if (self.orphan_check_inflight) return;
    const hwnd = self.msg_hwnd orelse return;
    const alloc = self.core_app.alloc;
    const res = alloc.create(OrphanRosterResult) catch return;
    res.* = .{ .alloc = alloc, .roster = null };
    self.orphan_check_inflight = true;
    const warm = self.local_agent.sharedConnectionIfWarm();
    const thread = std.Thread.spawn(.{}, orphanCheckWorker, .{ res, hwnd, warm }) catch {
        self.orphan_check_inflight = false;
        res.destroy();
        return;
    };
    thread.detach();
}

fn orphanCheckWorker(
    res: *OrphanRosterResult,
    hwnd: w32.HWND,
    warm: ?*remote_connection.Connection,
) void {
    var probe: ?tcp_dial.Dialed = null;
    const conn: ?*remote_connection.Connection = warm orelse blk: {
        probe = LocalAgent.dialProbe(res.alloc);
        break :blk if (probe) |p| p.conn else null;
    };
    defer if (probe) |*p| p.deinit();

    if (conn) |c| {
        res.roster = c.requestSessions(orphan_rpc_timeout_ns) catch |err| r: {
            log.debug("orphan check: LIST_SESSIONS failed err={}", .{err});
            break :r null;
        };
    }
    if (w32.PostMessageW(hwnd, WM_APP_ORPHAN_ROSTER, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}

/// GUI thread: a roster landed — decide whether anything deserves a balloon.
/// The ORACLE LINE is printed before the shell is asked to show anything: on a
/// desktop with no notification area (a background test desktop) the decision
/// still happened and is still observable.
fn onOrphanRoster(self: *App, res: *OrphanRosterResult) void {
    self.orphan_check_inflight = false;
    defer res.destroy();
    const roster = res.roster orelse return;
    const alloc = self.core_app.alloc;

    var rows = alloc.alloc(orphan_notify.Row, roster.sessions.len) catch return;
    defer alloc.free(rows);
    for (roster.sessions, 0..) |s, i| rows[i] = .{
        .id = s.id,
        .alive = s.alive,
        .attached = s.attached,
        .unattached_since = s.unattached_since,
    };

    // The agent is local, so its clock and ours are the same wall clock.
    const now_ms = std.time.milliTimestamp();
    const notify_after = orphanEnvMs(
        alloc,
        "GHOZTTY_ORPHAN_NOTIFY_AFTER_MS",
        orphan_notify.default_notify_after_ms,
    );
    const renotify_after = orphanEnvMs(
        alloc,
        "GHOZTTY_ORPHAN_RENOTIFY_MS",
        orphan_notify.default_renotify_after_ms,
    );

    var stamps = loadOrphanStamps(alloc);
    defer stamps.deinit();

    const d = orphan_notify.decide(rows, stamps.value, now_ms, notify_after, renotify_after);
    const idx = d.announce orelse return;
    const s = roster.sessions[idx];
    const since = s.unattached_since orelse return;

    // The acceptance oracle: the decision, said before any shell call.
    log.info(
        "orphan notify: session={s} unattached_for_ms={d} eligible={d} cwd={s}",
        .{ s.id, now_ms - since, d.eligible, s.cwd orelse "-" },
    );

    // Stamp FIRST — this is what "Keep" means: once told, this episode stays
    // quiet for a long while regardless of what the shell did with the
    // balloon. Existing stamps for sessions the agent no longer lists are
    // pruned so the file cannot grow without bound.
    var keep: std.ArrayListUnmanaged(orphan_notify.Stamp) = .empty;
    defer keep.deinit(alloc);
    keep.append(alloc, .{
        .id = s.id,
        .unattached_since = since,
        .notified_at = now_ms,
    }) catch return;
    for (stamps.value) |st| {
        if (std.mem.eql(u8, st.id, s.id)) continue;
        const still = for (roster.sessions) |r2| {
            if (std.mem.eql(u8, r2.id, st.id)) break true;
        } else false;
        if (still) keep.append(alloc, st) catch {};
    }
    saveOrphanStamps(alloc, keep.items);

    var body_buf: [256]u8 = undefined;
    const body = orphan_notify.formatBody(&body_buf, s.cwd, s.argv, now_ms - since, d.eligible - 1);
    self.showTrayBalloon(
        NOTIF_ORPHAN_UID,
        NOTIF_ORPHAN_TIMER_ID,
        "A terminal session is still running",
        body,
    );
}

/// The loaded stamp file, holding its JSON arena alive as long as the slice is
/// read. Any failure at all loads as "no stamps" — worst case the user hears
/// about an episode once more, never an error dialog.
const OrphanStamps = struct {
    parsed: ?std.json.Parsed(orphan_notify.StampFile),
    value: []const orphan_notify.Stamp,

    fn deinit(self: *OrphanStamps) void {
        if (self.parsed) |*p| p.deinit();
        self.* = undefined;
    }
};

/// `%LOCALAPPDATA%\ghoztty\orphan-notify[-debug].json` — the same debug-build
/// coexistence pattern as `session_layout.layoutPath`, so a dev build never
/// suppresses (or burns) the release app's notifications. Caller frees.
fn orphanStampsPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (comptime build_config.is_debug)
        "orphan-notify-debug.json"
    else
        "orphan-notify.json";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

fn loadOrphanStamps(alloc: Allocator) OrphanStamps {
    const none: OrphanStamps = .{ .parsed = null, .value = &.{} };
    const path = orphanStampsPath(alloc) orelse return none;
    defer alloc.free(path);
    const f = std.fs.openFileAbsolute(path, .{}) catch return none;
    defer f.close();
    const bytes = f.readToEndAlloc(alloc, 1024 * 1024) catch return none;
    defer alloc.free(bytes);
    // `.alloc_always`: the ids must be COPIES — with the default policy an
    // unescaped string field points into `bytes`, which is freed right here,
    // and a dangling id silently matches nothing (measured: every stamp read
    // as "no stamp" and the balloon re-fired on every tick).
    const parsed = std.json.parseFromSlice(orphan_notify.StampFile, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return none;
    return .{ .parsed = parsed, .value = parsed.value.stamps };
}

fn saveOrphanStamps(alloc: Allocator, stamps: []const orphan_notify.Stamp) void {
    const path = orphanStampsPath(alloc) orelse return;
    defer alloc.free(path);
    const json = std.json.Stringify.valueAlloc(
        alloc,
        orphan_notify.StampFile{ .stamps = stamps },
        .{},
    ) catch return;
    defer alloc.free(json);
    if (std.fs.path.dirname(path)) |dir| std.fs.makeDirAbsolute(dir) catch {};
    const f = std.fs.createFileAbsolute(path, .{}) catch return;
    defer f.close();
    f.writeAll(json) catch {};
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

    // Guard: verify this is a surface window or one of its popups. One
    // definition for both the guard and the WM_DESTROY routing below, so the
    // two cannot disagree about which window this is (T613).
    const role = surface_window_role.roleOf(.{
        .surface = if (surface.hwnd) |h| @intFromPtr(h) else null,
        .search = if (surface.search_hwnd) |h| @intFromPtr(h) else null,
        .palette = if (surface.palette_hwnd) |h| @intFromPtr(h) else null,
    }, @intFromPtr(hwnd));
    const is_surface_window = role == .surface;
    const is_palette_popup = role == .palette_popup;
    if (role == .foreign)
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
            // One of this Surface's three windows is being destroyed (by
            // Surface.deinit or by parent Window destruction). Clear the state
            // belonging to THAT window, so deinit doesn't double-destroy it.
            // Lifecycle is managed by Window.
            //
            // T613: clearing `surface.hwnd` here unconditionally is what
            // crashed the app. `Surface.deinit` destroys the two popups a few
            // lines before it clears the terminal window's GWLP_USERDATA, so a
            // popup's WM_DESTROY zeroed `hwnd`, the `if (self.hwnd)` at the end
            // of deinit then did nothing, and the terminal window went into
            // `DestroyWindow` still holding a `*Surface` about to be freed —
            // read back through OPENGL32's wglWndProc subclass as a segfault.
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            const clears = surface_window_role.destroyClears(role);
            if (clears.surface_window) {
                surface.hwnd = null;
                surface.core_surface_ready = false;
            }
            if (clears.search_popup) {
                surface.search_hwnd = null;
                surface.search_edit = null;
                surface.search_count_label = null;
            }
            if (clears.palette_popup) {
                surface.palette_hwnd = null;
                surface.palette_edit = null;
            }
            return 0;
        },

        w32.WM_ERASEBKGND => {
            // The fill used to be unconditional, "because the OpenGL renderer
            // will overwrite the entire client area on the next frame". The
            // NEXT frame was the bug (T1031): this erase is synchronous and
            // the GL frame is not, so each one displayed a flat background
            // rectangle before the text came back. Measured to fire on a
            // WINDOW resize and not during a divider drag, so this is the
            // window-edge half of the report specifically — the divider and
            // banner halves are the clip styles, the batched layout pass and
            // the synchronous present.
            //
            // `resize_paint` owns the rule and is unit tested; the two cases
            // that still need the fill are a surface with no presented frame
            // behind it and the search/palette popups, which share this
            // window class and have no renderer at all.
            const presented = surface.has_presented_frame.load(.acquire);
            const fill = resize_paint.shouldFillBackground(.{
                .is_surface_window = is_surface_window,
                .has_presented_frame = presented,
            });
            // Debug-build oracle for resize-flicker.ps1 (T1031), and the only
            // one there is: WM_ERASEBKGND hands the handler a DC belonging to
            // WHOEVER SENT IT, so a test in another process cannot pose this
            // question by sending the message — an HDC does not survive a
            // process boundary, and the cross-process probe that tried it
            // passed against nothing. Same shape as `banner collapse from=`:
            // the app states the decision it made, and the script reads it out
            // of the debug build's stderr.
            log.debug("surface erase surface={} presented={} fill={}", .{
                is_surface_window,
                presented,
                fill,
            });
            if (fill) {
                if (surface.app.bg_brush) |brush| {
                    const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                    var rect: w32.RECT = undefined;
                    if (w32.GetClientRect(hwnd, &rect) != 0) {
                        _ = w32.FillRect(hdc_erase, &rect, brush);
                    }
                }
            }
            return 1;
        },

        // The palette popup into a caller's DC (T563). The terminal surface
        // itself is deliberately NOT printable - it is a GL surface and
        // `PrintWindow` returns a flat fill for it, which is the capture limit
        // T214 wrote down - but the palette is ordinary GDI and answering here
        // is what lets a probe photograph it synchronously.
        w32.WM_PRINTCLIENT => {
            if (is_palette_popup and wparam != 0) {
                surface.paintPaletteInto(@ptrFromInt(wparam), hwnd);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
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

        // The palette's and the search bar's edit fields. Both were hardcoded
        // dark (`RGB(30,30,30)` / `RGB(45,45,45)` under a fixed light text);
        // they take the panel palette's field now, so they follow the theme
        // the window does (T563).
        w32.WM_CTLCOLOREDIT => {
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            const p = surface.panelPalette();
            _ = w32.SetTextColor(hdc_edit, system_colors.cr(p.text));
            _ = w32.SetBkColor(hdc_edit, system_colors.cr(p.field));
            if (popup_field_brush.get(system_colors.cr(p.field))) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // The search bar's match-count label ("3/17"), on the bar's surface.
        w32.WM_CTLCOLORSTATIC => {
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            const p = surface.panelPalette();
            _ = w32.SetTextColor(hdc_static, system_colors.cr(p.secondary));
            _ = w32.SetBkColor(hdc_static, system_colors.cr(p.bg));
            if (popup_bg_brush.get(system_colors.cr(p.bg))) |brush| {
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

    if (msg == WM_APP_REAP_SURFACE) {
        // wparam = the closed pane's HWND, already unhooked from its Surface.
        if (wparam != 0) performSurfaceReap(@ptrFromInt(wparam));
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

    if (msg == AgentIntegration.WM_APP_CLAUDE_PROMPT) {
        // wparam = detected-agent bits.
        AgentIntegration.showFirstRunPrompt(app, wparam);
        return 0;
    }

    if (msg == AgentIntegration.WM_APP_CLAUDE_DONE) {
        // wparam = heap *Done owned by the handler.
        if (wparam != 0) {
            const done: *AgentIntegration.Done = @ptrFromInt(wparam);
            AgentIntegration.onDone(app, done);
        }
        return 0;
    }

    if (msg == AgentIntegration.WM_APP_MIGRATION_PROMPT) {
        AgentIntegration.showMigrationPrompt(app);
        return 0;
    }

    if (msg == AgentIntegration.WM_APP_MIGRATION_DONE) {
        // wparam = heap *MigrationDone owned by the handler.
        if (wparam != 0) {
            const done: *AgentIntegration.MigrationDone = @ptrFromInt(wparam);
            AgentIntegration.onMigrationDone(app, done);
        }
        return 0;
    }

    if (msg == AgentIntegrationsDialog.WM_APP_AGENTS_UPDATE) {
        // wparam = heap *Update owned by the handler (T871): a dialog
        // worker's probe/action result, dropped if the dialog closed.
        if (wparam != 0) {
            const up: *AgentIntegrationsDialog.Update = @ptrFromInt(wparam);
            AgentIntegrationsDialog.onUpdate(app, up);
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

    if (msg == ShareMachineRow.WM_APP_SHARE_MACHINE) {
        // wparam = heap *Result owned by the handler (T547 share-this-machine
        // enrollment ran on a detached thread; this is the GUI-thread landing).
        if (wparam != 0) {
            const res: *ShareMachineRow.Result = @ptrFromInt(wparam);
            ShareMachineRow.onResult(app, res);
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

    if (msg == SessionCpuProbe.WM_APP_CHOOSER_SESSION_CPU) {
        // wparam = the chooser id a pushed per-session CPU frame belongs to
        // (T462). An integer payload with nothing to free, and routed by id for
        // the same reason the roster's reply is: a chooser that closed first
        // must not be written through, and a dialog HWND can be recycled.
        MachineChooser.onSessionCpu(app, @intCast(wparam));
        return 0;
    }

    if (msg == MachineConnectionPool.WM_APP_MACHINE_POOL_DIALED) {
        // wparam = heap *DialResult owned by the handler. Here rather than on a
        // chooser's window for the same reason as the roster above, and with a
        // sharper consequence: a discarded dial leaks the CONNECTION it opened,
        // which nothing else would ever free (T461).
        if (wparam != 0) {
            const res: *MachineConnectionPool.DialResult = @ptrFromInt(wparam);
            app.machine_pool.onDialed(res);
        }
        return 0;
    }

    if (msg == MachineConnectionPool.WM_APP_MACHINE_POOL_NOTIFY) {
        // Two integer payloads, no allocation: a warm-connection replay for a
        // late lease (wparam 0), or a pooled connection's link state moving
        // (wparam = its entry id). Posted from the connection's reader thread,
        // which may not touch GUI state.
        app.machine_pool.onNotify(wparam, lparam);
        return 0;
    }

    if (msg == RestoreAllRelay.WM_APP_RESTORE_ALL) {
        // wparam = heap *Job owned by the handler (T339: a cross-machine
        // Restore All dialed on a worker thread). It lands here rather than on
        // the chooser's own window for the same reason the roster does — a
        // chooser that closed first would have the message DISCARDED with its
        // queue, leaking one relay connection per window it carries.
        if (wparam != 0) {
            const job: *RestoreAllRelay.Job = @ptrFromInt(wparam);
            MachineChooser.onRestoreAll(app, job);
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

    if (msg == ActivityMonitor.WM_APP_ACTIVITY_PROBE) {
        // wparam = heap *ProbeResult owned by the handler (T298). Landing here
        // is what lets a probe dial that finished after its panel closed FREE
        // the connection it just opened instead of leaking it with the
        // window's discarded message queue.
        if (wparam != 0) {
            const res: *ActivityMonitor.ProbeResult = @ptrFromInt(wparam);
            ActivityMonitor.onProbeDialed(res);
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

    if (msg == RemoteReconnect.WM_APP_REMOTE_LINK) {
        // T366: a cross-machine window's transport changed state. Posted from
        // that connection's reader thread; the ladder is driven here.
        RemoteReconnect.onLinkPost(app);
        return 0;
    }

    if (msg == RemoteReconnect.WM_APP_REMOTE_DIALED) {
        // wparam = heap *Result owned by the handler. It lands HERE and not on
        // the terminal window for the same reason the chooser's replies do:
        // DestroyWindow discards a window's queued messages, and a discarded
        // reply would leak the connection this attempt just opened.
        if (wparam != 0) {
            const res: *RemoteReconnect.Result = @ptrFromInt(wparam);
            RemoteReconnect.onDialed(app, res);
        }
        return 0;
    }

    if (msg == WM_APP_UPDATE_AVAILABLE) {
        // wparam = heap pointer to an UpdateFound we now own. lparam 1 = a
        // check found this; lparam 2 = a download the user already consented
        // to finished, so it installs without asking twice. wparam == 0 is
        // feedback (lparam 0 = up to date, 1 = check failed, 2 = download
        // failed).
        if (wparam != 0) {
            const found: *UpdateFound = @ptrFromInt(wparam);
            defer found.destroy(app.core_app.alloc);
            app.showUpdateNotification(found);
            if (lparam == 2) {
                app.update_download_inflight = false;
                app.applyStagedUpdate();
            }
        } else {
            app.showUpdateFeedback(lparam);
        }
        return 0;
    }

    if (msg == WM_APP_TRAY) {
        // wparam = uID, lparam's low word = the NIN_*/WM_* event. What that
        // pair MEANS is decided in `tray_notify.classify` (unit-tested); this
        // is only the doing.
        switch (tray_notify.classify(wparam, lparam) orelse return 0) {
            .focus_notifying_surface => {
                // Focus the surface that produced the notification (click-to-
                // focus, matching macOS/GTK). A surface whose pane has since
                // been closed resolves to null and is simply dropped — a
                // notification for a pane that is gone has nowhere to go.
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
            },
            .review_orphan_sessions => {
                // The forgotten-session balloon (T534): open the machine
                // chooser, where the T520 "not in any window" badge marks the
                // session and Resume / Kill live. Anchored on the focused
                // window (the chooser is per-window), falling back to any
                // open one; no window at all means nowhere to review, drop.
                const win: ?*Window = if (app.core_app.focusedSurface()) |s|
                    s.rt_surface.parent_window
                else if (app.windows.items.len > 0)
                    app.windows.items[0]
                else
                    null;
                if (win) |w| {
                    if (w.hwnd) |wh| _ = w32.SetForegroundWindow(wh);
                    MachineChooser.open(w);
                }
            },
            .restart_into_new_build => {
                // T1205: the newer build is already on disk — nothing to
                // fetch, nothing to install. Restarting IS the whole action,
                // and the user asked for it by clicking a balloon that says
                // so, which is the consent `applyStagedUpdate` gets from its
                // dialog.
                app.restartIntoInstalledBuild();
            },
            .open_release_page => {
                // T1178: when there is something installable, a click INSTALLS
                // it — that is the whole point of the notification now, and
                // the release page is what is left when there is not.
                if (app.offerUpdate()) return 0;

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
            },
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
        // Every trigger that arms this timer moved the TOPOLOGY, not the
        // content, so the screens carry forward (T412).
        app.syncSessionLayout(.reuse);
        return 0;
    }

    // Timer ID 10: the periodic session-layout REFRESH (T922). Repeating, so it
    // is not killed here. Its whole job is to re-capture each pane's SCREEN,
    // which no mutation trigger ever notices. `tickLayoutRefresh` owns both the
    // "has anything painted?" question and the persistence-off check — the
    // latter re-read per tick rather than disarmed, so a config reload that
    // turns persistence off does not leave the tick deleting the manifest and
    // the agent's blobs on a loop.
    if (msg == w32.WM_TIMER and wparam == LAYOUT_REFRESH_TIMER_ID) {
        app.tickLayoutRefresh();
        return 0;
    }

    // Timer ID 5: local-agent link settle watch (T145). Self-re-arming (a
    // periodic SetTimer), killed by `endAgentSettleWatch` once a verdict lands.
    if (msg == w32.WM_TIMER and wparam == AGENT_WATCH_TIMER_ID) {
        app.tickAgentSettleWatch();
        return 0;
    }

    // Timer ID 9: the periodic long-unattached session check (T534). Re-armed
    // here at the full cadence — the launch arm fires sooner on purpose.
    if (msg == w32.WM_TIMER and wparam == ORPHAN_CHECK_TIMER_ID) {
        _ = w32.SetTimer(hwnd, ORPHAN_CHECK_TIMER_ID, app.orphanCheckIntervalMs(), null);
        app.startOrphanCheck();
        return 0;
    }

    // A background orphan-check worker parked its roster (T534): evaluate it
    // on the GUI thread (ownership of the box transfers here).
    if (msg == WM_APP_ORPHAN_ROSTER) {
        const res: *OrphanRosterResult = @ptrFromInt(wparam);
        app.onOrphanRoster(res);
        return 0;
    }

    // Timer ID 7: the in-place recovery retry (T723). Armed only after a
    // recovery aborted with no reachable agent; one-shot per attempt.
    if (msg == w32.WM_TIMER and wparam == AGENT_RETRY_TIMER_ID) {
        app.tickAgentRecoveryRetry();
        return 0;
    }

    // Timer ID 12: "is a newer build on disk?" (T1205). Repeating; the launch
    // arm fires sooner, so the first tick re-arms at the full cadence.
    if (msg == w32.WM_TIMER and wparam == STALE_BUILD_CHECK_TIMER_ID) {
        _ = w32.SetTimer(hwnd, STALE_BUILD_CHECK_TIMER_ID, STALE_BUILD_CHECK_MS, null);
        app.checkStaleBuild();
        return 0;
    }

    // Timer ID 14: the periodic release-channel re-check (T1171). Repeating;
    // every gate the launch check answers to (install location, `auto-update =
    // off`, the one-per-hour network throttle) is re-answered here, so a tick
    // is usually a file read and nothing else.
    if (msg == w32.WM_TIMER and wparam == UPDATE_RECHECK_TIMER_ID) {
        app.startUpdateCheck(.automatic);
        return 0;
    }

    // Timer ID 11: the deferred launch restore (T976). Armed only when the
    // launch restore had to carry windows forward for want of an agent;
    // one-shot per attempt.
    if (msg == w32.WM_TIMER and wparam == RESTORE_RETRY_TIMER_ID) {
        app.tickRestoreRetry();
        return 0;
    }

    // Timer ID 6: the cross-machine reconnect ladder (T366). Armed only while
    // some remote window is mid-ladder, waiting on a background re-dial, or has
    // a dial in flight; it disarms itself the moment none does.
    if (msg == w32.WM_TIMER and wparam == RemoteReconnect.TIMER_ID) {
        RemoteReconnect.tick(app);
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
        (wparam == NOTIF_DESKTOP_TIMER_ID or wparam == NOTIF_UPDATE_TIMER_ID or
            wparam == NOTIF_ORPHAN_TIMER_ID or wparam == NOTIF_STALE_TIMER_ID))
    {
        const uid: u32 = switch (wparam) {
            NOTIF_DESKTOP_TIMER_ID => NOTIF_DESKTOP_UID,
            NOTIF_UPDATE_TIMER_ID => NOTIF_UPDATE_UID,
            NOTIF_STALE_TIMER_ID => NOTIF_STALE_UID,
            else => NOTIF_ORPHAN_UID,
        };
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
