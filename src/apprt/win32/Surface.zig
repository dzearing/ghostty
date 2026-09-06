//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork (branding, fork apprt actions).
//! Win32 Surface. Each Surface corresponds to one HWND (window) and
//! owns an OpenGL (WGL) context for rendering.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const termio = @import("../../termio.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");
const remote_connection = @import("../../remote/connection.zig");
const gl_loader = @import("../../renderer/gl_loader.zig");

const App = @import("App.zig");
const AgentIntegration = @import("AgentIntegration.zig");
const AgentIntegrationsDialog = @import("AgentIntegrationsDialog.zig");
const ActivityMonitor = @import("ActivityMonitor.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const PaneView = @import("PaneView.zig");
const RefCount = @import("pane_refcount.zig").RefCount;
const RenameDialog = @import("RenameDialog.zig");
const ViewerPane = @import("ViewerPane.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const drag_perf = @import("drag_perf.zig");
const resize_paint = @import("resize_paint.zig");
const clipboard_open = @import("clipboard_open.zig");
const utf16_text = @import("utf16_text.zig");
const Scrollbar = @import("Scrollbar.zig").Scrollbar;
const DimOverlay = @import("DimOverlay.zig").DimOverlay;
const BannerOverlay = @import("BannerOverlay.zig").BannerOverlay;
const ReadonlyBadge = @import("ReadonlyBadge.zig").ReadonlyBadge;
const KeyStateIndicator = @import("KeyStateIndicator.zig").KeyStateIndicator;
const key_state = @import("key_state.zig");
const translate_policy = @import("translate_policy.zig");
const window_chord = @import("window_chord.zig");
const banner_layout = @import("banner_layout.zig");
const context_menu = @import("context_menu.zig");
const menu_activation = @import("menu_activation.zig");
const commands = @import("commands.zig");
const menu_label = @import("menu_label.zig");
const pane_id_mod = @import("pane_id.zig");
const palette_jump = @import("palette_jump.zig");
const tab_tooltip = @import("tab_tooltip.zig");
const brush_cache = @import("brush_cache.zig");
const panel_theme = @import("panel_theme.zig");
const system_colors = @import("system_colors.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const ProcessTree = @import("ProcessTree.zig");
const session_disconnect = @import("session_disconnect.zig");
const provenance = @import("provenance.zig");
const color_math = @import("color_math.zig");

const log = std.log.scoped(.win32);

/// The Win32 window handle.
hwnd: ?w32.HWND = null,

/// Device context for the window (with CS_OWNDC, this persists for the
/// lifetime of the window).
hdc: ?w32.HDC = null,

/// WGL OpenGL rendering context.
hglrc: ?w32.HGLRC = null,

/// Current client area dimensions in pixels.
width: u32 = 800,
height: u32 = 600,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// The parent App.
app: *App,

/// The parent Window that contains this Surface as a tab.
parent_window: *Window = undefined,

/// This pane's stable, ghoztty-owned identity (T113): the docs/claude/cli.md "Pane
/// identity" UUID, exported to the pane's processes as `$GHOZTTY_PANE_ID`,
/// reported as the `+list --json` leaf `id`, and accepted directly by every
/// `--target`/`--name`. Filled by `init` — either generated fresh or taken
/// from the session-layout manifest on restore, so the value the shell was
/// baked with keeps addressing the same pane across app relaunch, re-attach,
/// and agent RELAUNCH. Never null after `init`; read it via `paneId()`.
pane_id: pane_id_mod.Buf = undefined,

/// The core terminal surface. Initialized by init() after creating
/// the window and WGL context. Manages fonts, renderer, PTY, and IO.
core_surface: CoreSurface = undefined,

/// Whether core_surface has been fully initialized. Win32 messages
/// (WM_SETFOCUS, WM_SIZE, etc.) can arrive during init before
/// core_surface is ready — handlers must check this flag.
core_surface_ready: bool = false,

/// The user answered **Disconnect** for this pane (T1390): the window closes
/// but its agent session must stay alive and resumable, so every later
/// CLOSE-on-free marking is refused. See `session_disconnect.DetachPin` for the
/// ordering problem this exists to solve.
detach_pin: session_disconnect.DetachPin = .{},

/// Whether core_surface.init() completed successfully (ever).
/// Different from core_surface_ready which is cleared during shutdown.
core_surface_initialized: bool = false,

/// Buffered high surrogate from WM_CHAR for supplementary plane characters.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages (surrogate pair).
high_surrogate: u16 = 0,

/// Bitmask of currently-pressed mouse buttons (left=1, right=2,
/// middle=4). Used so SetCapture/ReleaseCapture only run on the
/// 0→nonzero and nonzero→0 transitions; without this, a right-click
/// in the middle of a left-button drag would call SetCapture again
/// (replacing capture) and the next button-up would release prematurely.
mouse_button_mask: u3 = 0,

/// Last cursor position this surface saw in a mouse MESSAGE, in client
/// coordinates. `getCursorPos` falls back to it when `GetCursorPos` fails,
/// which it does whenever the calling thread's desktop is not the input
/// desktop — a locked workstation, the secure desktop, a disconnected RDP
/// session, or (T216) an acceptance run on a background test desktop. Before
/// this the failure propagated out of `mouseButtonCallback` and killed the
/// whole click: the right-click context menu never opened, because the
/// apprt only shows it when the core returns "unconsumed".
///
/// A message-derived position is not a downgrade: it is queue-synchronized
/// with the event being handled, whereas `GetCursorPos` reports where the
/// pointer is *now*, which may already have moved on.
last_cursor_client: ?w32.POINT = null,

/// Whether an IME composition session is active. When true, handleKeyEvent
/// skips VK_PROCESSKEY events (the IME is intercepting keys), and composed
/// text is extracted from WM_IME_COMPOSITION instead.
ime_composing: bool = false,

/// Set to true when handleKeyEvent produced text via ToUnicode. Any
/// subsequent WM_CHAR (from IME, SendInput Unicode/VK_PACKET, or
/// PostMessage) is then suppressed to avoid double input. Reset to false
/// when WM_CHAR arrives (whether suppressed or processed).
key_event_produced_text: bool = false,

/// Whether the user is actively dragging a window border/titlebar.
/// During live resize, handleResize blocks until the renderer draws
/// one frame at the new size (or a timeout expires), eliminating the
/// visual flicker from the DWM stretching stale content.
///
/// Set for a window-frame drag at WM_ENTERSIZEMOVE, and by the window for the
/// two other interactions that relayout panes live: a divider drag and a
/// banner expand/collapse (T1031). Those are not modal size loops, so nothing
/// used to put them on the synchronous-present path and every relayout tick
/// showed background before it showed text.
in_live_resize: bool = false,

/// The renderer thread has presented at least one frame into this window.
///
/// Read by `WM_ERASEBKGND` (T1031): once there are real pixels in the window,
/// filling the client with the flat background brush puts a visible blank
/// frame on screen ahead of the GL frame that is already on its way. Before
/// the first present there is nothing to preserve and the fill is correct.
/// Written from the renderer thread in `signalFrameDrawn`, read on the UI
/// thread, so it is atomic — a torn bool would only ever cost one extra fill,
/// but "only ever" is not a thing to guess about across threads.
has_presented_frame: std.atomic.Value(bool) = .init(false),

/// Manual-reset event signaled by the renderer thread after presenting
/// a frame. The main thread waits on this during live resize to
/// synchronize rendering with the DWM compositor.
frame_event: ?w32.HANDLE = null,

/// Themed scrollbar (custom layered-popup overlay).
/// Created lazily after the surface HWND exists.
scrollbar: ?*Scrollbar = null,

/// Unfocused-split dim overlay (T74): a layered popup filled with
/// `unfocused-split-fill` shown over this pane while an unfocused split.
/// Created lazily on first dim (single-pane windows never pay for one).
/// Driven by Window.updateDimOverlays.
dim_overlay: ?*DimOverlay = null,

/// Sticky pane banner (T35): overlay strip above the terminal content,
/// plus the raw markdown source (owned) so the editor can prefill it and
/// `+list --json` can report it. Both null while no banner is set.
banner_overlay: ?*BannerOverlay = null,
banner_text: ?[:0]u8 = null,

/// The last WP-D3 screen snapshot this pane recorded (T412), base64'd exactly
/// as the manifest carries it, plus the agent-stream offset it reflects. Owned
/// by the app allocator; replaced by every FULL layout capture and freed here.
///
/// It exists because dumping the screen is by far the most expensive part of a
/// layout sync — it takes `renderer_state.mutex`, which the IO thread holds
/// while feeding output, so eight busy panes measured **991 ms** on this box —
/// and most syncs do not need a fresh one. A window drag, a new tab, a rename:
/// the topology moved, the content did not. Those reuse this, and only the
/// T922 refresh (which deliberately waits for the panes to go quiet) and the
/// quit/shutdown flush pay for a re-dump. A pane with none yet — one created
/// since the last full capture — still captures fresh, so reuse can never mean
/// "restores blank".
last_snapshot: ?[]const u8 = null,
last_snapshot_offset: ?u64 = null,

/// When `last_snapshot` was taken (`std.time.milliTimestamp`), or 0 for never.
///
/// The bounded refresh round (T1311) spreads a forced capture across ticks, and
/// this is how it knows which panes it has already reached: a pane whose screen
/// was dumped after the round began is current, and re-dumping it would spend
/// the round's frame on a pane that owes nothing while the pane behind it keeps
/// waiting.
last_snapshot_ms: i64 = 0,

/// Read-only badge (T445): the corner card that marks this pane as
/// read-only. Created lazily the first time the mode is entered — a pane
/// that never goes read-only never pays for a popup — and kept afterwards,
/// hidden, because the mode is a toggle people flip more than once.
readonly_badge: ?*ReadonlyBadge = null,

/// Key-state pill (T446): which key tables this pane is inside, and which
/// keys of a multi-key sequence have been pressed so far. The MODEL is always
/// present (it is 700-odd bytes of fixed buffers and it has to be able to
/// record a `.key_table` activation before any window exists); the popup is
/// created lazily the first time there is something to show, so a pane that
/// never enters a sequence or a table never pays for one.
key_state_model: key_state.Model = .{},
key_state_indicator: ?*KeyStateIndicator = null,

/// Background tint (T67): explicit `--color`/`--split-color`/picker color,
/// or the auto-shifted split-inheritance tint. Null ⇒ config background.
/// The Mac stores this as backgroundTintNSColor; `+list --json` reports it
/// additively as the pane's `background_tint`.
background_tint: ?color_math.Rgb = null,

/// The current mouse cursor. Cached so WM_SETCURSOR can restore it
/// (DefWindowProc resets the cursor to the class cursor on every
/// WM_SETCURSOR, so we must override it ourselves).
current_cursor: ?w32.HCURSOR = null,

/// The last title set via setTitle (owned copy), so getTitle and the IPC
/// `+list` tree can report a per-pane title. Null until the first set.
title: ?[:0]u8 = null,

/// The pane's working directory (owned copy), cached off the GUI thread's
/// hot path exactly like `title` — GTK caches the same action the same way
/// (`apprt/gtk/class/surface.zig` setPwd).
///
/// T111b: `+list` used to read this with `core_surface.pwd()`, which takes
/// that pane's `renderer_state.mutex`. Under a flood the IO thread holds
/// that mutex nearly continuously, so the liveness probe every automation
/// bar in this tracker is written against (`+list` answers) was the one
/// call that queued behind the flood. Core already pushes every change here
/// as a `.pwd` action, so the cache is not merely faster — it removes
/// `+list` from the contended path entirely.
///
/// Null until the first `.pwd` action or the first `+list` seeds it from
/// the terminal (the initial cwd is set by termio at startup and reported
/// through no action, so `+list` seeds it once and every later read is
/// lock-free). An EMPTY string is a real cached value — "this pane has no
/// working directory" — not an absent one; panes launched without a
/// working directory never get a terminal pwd, and treating that as
/// "not cached yet" put `+list` back on the pane's mutex on every call.
pwd: ?[:0]u8 = null,

/// True once this pane's shell has ACTUALLY reported its working directory
/// via OSC 7 (the `.pwd` action) — i.e. the shell tracks the user's `cd`s
/// live (pwsh via the T27 integration, bash/zsh, any OSC-7-emitting
/// program). False means `pwd` above is frozen at the starting directory
/// termio seeded (cmd.exe has no prompt hook and can never report), so
/// consumers that want the CURRENT directory must ask the OS for the shell
/// process's real cwd instead (`livePwd`, T185).
pwd_reported: bool = false,

/// Non-null while the user has manually set this pane's title ("Change
/// Pane Title…" prompt, T92). Holds the last terminal-reported title so
/// clearing the manual title restores it; while set, setTitle updates
/// this instead of `title` (Mac SurfaceView.titleFromTerminal parity).
title_from_terminal: ?[:0]u8 = null,

/// Activity state of this pane (`+set-state` IPC / OSC 7777). Aggregated
/// per-window (needs_input > busy > idle) into a title suffix.
activity_state: terminal.osc.Command.ActivityState = .idle,

/// When false, WM_SETCURSOR sets the cursor to null (invisible). The
/// core surface toggles this for typing-while-mouse-still etc.
mouse_visible: bool = true,

/// Search popup HWND (a small top-level window containing an Edit
/// control). Uses a popup instead of a child window because the
/// OpenGL viewport covers the entire client area and would paint
/// over a child control.
search_hwnd: ?w32.HWND = null,

/// The Edit control inside the search popup.
search_edit: ?w32.HWND = null,

/// Whether the search bar is currently visible.
search_active: bool = false,

/// A lone Alt press is pending: Alt went down with nothing else held, and
/// nothing has happened since. Releasing it opens the menu (T190) — the
/// classic Windows menu-bar activation. Any other key, or losing focus
/// (alt+tab), disarms it, so alt-as-a-modifier is untouched.
alt_menu_armed: bool = false,

/// Font handle for the search edit (must be deleted on cleanup).
search_font: ?*anyopaque = null,

/// Right-aligned STATIC control in the search popup showing the
/// "selected/total" match count (search_total / search_selected actions).
search_count_label: ?w32.HWND = null,

/// Small popup at the bottom-left of the surface showing the hovered URL
/// (mouse_over_link action), like a browser status bubble.
link_preview_hwnd: ?w32.HWND = null,

/// Font for the link preview popup (deleted on cleanup).
link_font: ?*anyopaque = null,

/// Last reported search match count and selected index (0-based), from
/// the search_total / search_selected apprt actions.
search_total: ?usize = null,
search_selected: ?usize = null,

/// Command palette popup HWND.
palette_hwnd: ?w32.HWND = null,
/// Edit control inside the command palette popup.
palette_edit: ?w32.HWND = null,
/// Font handle for the palette edit (must be deleted on cleanup).
palette_font: ?*anyopaque = null,
/// Cached paint-time font for the palette list (14pt Segoe UI). The
/// edit control uses palette_font (16pt); this is for FillRect/DrawText
/// in paintPalette. Cached so we don't allocate a new HFONT on every
/// keystroke-driven repaint.
palette_paint_font: ?*anyopaque = null,
/// Whether the command palette is currently visible.
palette_active: bool = false,
/// Currently selected item in the filtered palette list.
palette_selected: u16 = 0,
/// Number of items currently in the filtered list.
palette_count: u16 = 0,
/// Indices into palette_entries for the current filter.
palette_filtered: [palette_entries.len + MAX_USER_PALETTE_ENTRIES + palette_jump.max_entries]u16 = undefined,
/// Arena holding the "Focus: <pane>" jump-entry snapshot (T555) — taken
/// each time the palette opens, freed when it closes. Null while closed.
palette_jump_arena: ?std.heap.ArenaAllocator = null,
/// The snapshotted jump entries, one per live pane across every window.
/// All slices are owned by `palette_jump_arena`.
palette_jump_entries: []const JumpEntry = &.{},

/// Remote-machine backend for this surface (remote-machines design §3.2),
/// or null for a local ConPTY surface. Set from `Overrides.remote` BEFORE
/// `core_surface.init` runs so `remoteBackend()` can branch the termio
/// backend construction. The connection is BORROWED — it is owned by the
/// parent Window (`Window.remote_dialed`), which tears it down only after
/// every surface riding on it has been deinitialized.
remote_conn: ?*remote_connection.Connection = null,

/// True ⇒ `remote_conn` is the LOCAL session-persistence agent (T89d), so
/// `remoteBackend()` returns `local_shell_integration = true` (inject shell
/// integration + GHOSTTY_* env, pin the session). False for a cross-machine
/// remote window. Set from `Overrides.Remote.local_agent` at init.
remote_is_local_agent: bool = false,

/// The REMOTE working directory / shell for the OPEN-new session, borrowed
/// from the IPC request arena for the duration of `core_surface.init` ONLY
/// (`termio.Remote.init` dupes them). Cleared right after init returns so
/// no dangling arena pointers outlive the request.
remote_working_directory: ?[]const u8 = null,
remote_shell: ?[]const u8 = null,

/// T468: the keep-alive invocation of the OPEN's `--command`, forwarded to the
/// agent as `OPEN.argv` so a `--command=` pane lands at a live shell instead of
/// "Process exited". Same borrow contract as `remote_shell` — the IPC request
/// arena owns it and `termio.Remote.init` dupes what it keeps.
remote_command_argv: ?[]const []const u8 = null,

/// Non-null ⇒ ATTACH to this existing agent session instead of OPENing a new
/// one (session re-attach restore, T89f2). Set from `Overrides.Remote.session_id`
/// at init; borrowed for the duration of `core_surface.init` ONLY (the same
/// lifetime contract as `remote_working_directory` — `termio.Remote.init` dupes
/// what it keeps and `remoteBackend()` is called exactly once, during init).
remote_session_id: ?[]const u8 = null,

/// WP-D3 fast re-attach (T109): the decoded screen repaint to paint on ATTACH
/// and the absolute stream offset it reflects. Same borrow contract as
/// `remote_working_directory` — valid for `core_surface.init` only, cleared
/// right after — because the App's decode scratch is reused by the NEXT leaf
/// this restore builds. Null/0 ⇒ full-ring replay.
remote_restore_snapshot: ?[]const u8 = null,
remote_restore_offset: u64 = 0,

/// T422: this restored pane brought its OWN sticky banner back from the
/// manifest, so the session-interrupted notice must not take the slot. Set
/// from `Overrides.Remote.pane_banner_restored` at init and read once by
/// `remoteBackend()`; false for every non-restore path.
remote_pane_banner_restored: bool = false,

/// Hero-mode thumbnail snapshot pipeline (T58 design / T59a). The renderer
/// thread captures its own presented frame (blit of the offscreen render
/// target — never an HWND capture, which can't see hidden panes) into
/// `snap_buffer` when `snap_requested` is set, then posts WM_APP_HERO_SNAP
/// to `snap_notify_hwnd`. The GUI thread copies the pixels into a DIB for
/// carousel painting. `snap_requested` is the renderer's one-atomic-load
/// fast path per frame when hero mode is inactive (T53 bar); everything
/// else is guarded by `snap_mutex`.
snap_mutex: std.Thread.Mutex = .{},
snap_requested: std.atomic.Value(bool) = .init(false),
/// Requested thumbnail size in px (guarded by snap_mutex). The GUI thread
/// pre-sizes snap_buffer to w*h*4 so the renderer never allocates.
snap_req_w: u32 = 0,
snap_req_h: u32 = 0,
/// Top-level window to notify with WM_APP_HERO_SNAP (guarded).
snap_notify_hwnd: ?w32.HWND = null,
/// BGRA bottom-up pixels, snap_req_w * snap_req_h * 4 (guarded).
snap_buffer: []u8 = &.{},
/// Bumped on every completed capture (guarded). The GUI-side DIB cache
/// syncs only when this differs from snap_dib_seq.
snap_seq: u32 = 0,
/// GUI-thread-only DIB cache of the last published snapshot.
snap_dib: ?w32.HANDLE = null,
snap_dib_bits: ?[*]u8 = null,
snap_dib_w: i32 = 0,
snap_dib_h: i32 = 0,
snap_dib_seq: u32 = 0,

/// Reference count for SplitTree ownership. Starts at 0 because the owning
/// `PaneView` calls ref() to take initial ownership (before T90c the tree
/// held this reference directly; the counting is unchanged). Same tested
/// arithmetic as the PaneView above it — see `pane_refcount.zig` (T371).
ref_count: RefCount = .{},

/// The split-tree leaf that owns this surface (T90c), or null before the
/// wrapper exists / after the surface is orphaned. Lets the destroy paths
/// that only hold a `*Surface` name the leaf — see `deinit`'s `ipcForget`.
pane_view: ?*PaneView = null,

/// SplitTree view protocol: increment reference count.
pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface {
    _ = alloc;
    self.ref_count.retain();
    return self;
}

/// SplitTree view protocol: decrement reference count.
pub fn unref(self: *Surface, alloc: Allocator) void {
    if (!self.ref_count.release()) return;
    if (self.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    self.deinit();
    alloc.destroy(self);
}

/// SplitTree view protocol: identity comparison.
pub fn eql(self: *const Surface, other: *const Surface) bool {
    return self == other;
}

/// This pane's stable id (T113). Valid from the top of `init` onward.
pub fn paneId(self: *const Surface) []const u8 {
    return &self.pane_id;
}

/// Per-surface config overrides for IPC-driven creation (`+new-window
/// --command/--working-directory/--env`, `+split ...`). Consumed by the
/// next Surface.init through the parent Window's pending_surface_overrides
/// baton; the strings only need to outlive that (synchronous) init.
pub const Overrides = struct {
    /// argv to spawn, in the config `Command.direct` form. Direct (not
    /// `.shell`) because the Windows `.shell` path whitespace-splits with
    /// no quoting rules — a shell-wrapped command would be mangled.
    command_argv: ?[]const [:0]const u8 = null,
    working_directory: ?[]const u8 = null,
    env: []const EnvVar = &.{},

    /// The pane id to ADOPT instead of generating a fresh one (T113): the
    /// session-layout manifest's recorded id for the leaf this surface is
    /// restoring. The re-attached (or agent-RELAUNCHed) shell keeps the
    /// `$GHOZTTY_PANE_ID` it was baked with, so restore MUST hand the same
    /// value back or the pane stops answering to its own documented id.
    /// Borrowed for the consuming `Surface.init` only (copied into the
    /// surface's own buffer); ignored when malformed. Null ⇒ generate.
    pane_id: ?[]const u8 = null,

    /// Remote-machine session (`+new-remote-window`): the surface is built
    /// with the `.remote` termio backend riding on this connection instead
    /// of a local ConPTY. All strings are REMOTE-native values forwarded
    /// verbatim in the agent OPEN (never wrapped by the local shell table —
    /// the agent applies its own shell's convention).
    remote: ?Remote = null,

    pub const EnvVar = apprt.ipc.args.EnvVar;

    pub const Remote = struct {
        /// Already dialed + handshake-complete. Owned by the parent Window
        /// (cross-machine) or by the App's `LocalAgent` (local persistence,
        /// `local_agent = true`).
        connection: *remote_connection.Connection,
        /// cwd ON THE REMOTE MACHINE, or null for the agent's default. For the
        /// LOCAL agent (`local_agent = true`) the agent IS this machine, so a
        /// local path is valid here.
        working_directory: ?[]const u8 = null,
        /// Shell ON THE REMOTE MACHINE, or null for the agent's default.
        shell: ?[]const u8 = null,
        /// Command to run instead of an interactive shell (runs through the
        /// resolved remote shell, agent-side). Null ⇒ interactive shell.
        command: ?[]const u8 = null,
        /// The LOCAL shell table's keep-alive invocation of `command`
        /// (`wrapShellCommandArgv`), exec'd verbatim by the agent instead of its
        /// own `<shell> /c <cmd>` synthesis (T468). Set ONLY alongside `command`
        /// and ONLY when `local_agent` — the agent is this machine there, so the
        /// local flavor table is the right one; a cross-machine agent must keep
        /// applying its own. Without it a `--command=` pane runs `cmd.exe /c`
        /// and dies the moment its command returns. `command` is still sent, as
        /// the session's human-readable label.
        command_argv: ?[]const []const u8 = null,
        /// True ⇒ this connection is the LOCAL session-persistence agent (same
        /// machine + same Ghoztty build), so the core injects ghoztty shell
        /// integration + the per-pane GHOSTTY_* env an exec pane would set, and
        /// pins the session against the idle-TTL reaper (T89d). The Windows
        /// analog of the Mac `Machine.isLocalMachine` signal. NEVER set for a
        /// cross-machine window.
        local_agent: bool = false,
        /// Non-null ⇒ ATTACH to this existing agent session id instead of
        /// OPENing a fresh one — session re-attach restore (T89f2). Borrowed;
        /// must outlive the consuming `Surface.init` (the manifest `Parsed`
        /// that owns it stays alive for the whole restore). Null ⇒ OPEN new.
        session_id: ?[]const u8 = null,

        /// WP-D3 fast re-attach (T109): the DECODED structured VT screen repaint
        /// the manifest recorded for this leaf, and the absolute agent-stream
        /// byte offset it reflects. The surface paints the snapshot on ATTACH
        /// and hands the offset to the agent as the ATTACH `last_byte_offset`,
        /// so only `(offset, S]` is replayed instead of the whole retained ring.
        /// Borrowed for the duration of the consuming `Surface.init` only
        /// (`termio.Remote.init` dupes it into the backend arena). Null/0 ⇒ the
        /// pre-T109 full-ring replay.
        restore_snapshot: ?[]const u8 = null,
        restore_offset: u64 = 0,

        /// T422: the restore is putting this pane's own sticky banner back
        /// (the manifest leaf carried one). The session-interrupted notice
        /// then keeps its in-stream copy but does NOT also claim the banner
        /// slot — a pane's own banner outranks a sentence that is identical
        /// in every pane. False ⇒ the slot is empty and the notice may use it.
        pane_banner_restored: bool = false,
    };
};

/// Initialize a new Surface, retrying once against a fallback OpenGL
/// implementation if the system one turns out to be below the renderer's
/// version floor (T1251).
///
/// The retry is a WHOLE new window rather than a second context on the same
/// one: a window's pixel format may be set exactly once, and a standalone GL
/// implementation chooses its own formats, so reusing the device context the
/// system driver already claimed is not a thing Windows allows. `initOnce`
/// unwinds completely on failure — the context, the DC and the window all go
/// back — so the second attempt starts from nothing, exactly as the first did.
///
/// When there is no fallback to try (the ordinary case today, and the case on
/// any machine where the fallback is not installed) the original error is
/// returned untouched and the T1249 startup dialog explains it.
pub fn init(
    self: *Surface,
    app: *App,
    parent: *Window,
    context: apprt.surface.NewSurfaceContext,
) !void {
    self.initOnce(app, parent, context) catch |err| {
        if (!gl_loader.shouldRetry(
            err,
            gl_loader.activeKind(),
            gl_loader.fallbackAvailable(),
        )) return err;

        if (!gl_loader.switchToFallback()) return err;

        log.warn(
            "the display's OpenGL is below what the renderer needs ({}); " ++
                "retrying with the fallback implementation",
            .{err},
        );
        try self.initOnce(app, parent, context);
    };
}

/// One attempt at creating the Win32 window and WGL context, then the core
/// terminal surface (fonts, renderer, PTY, IO). See `init` for why this is a
/// separate function.
fn initOnce(
    self: *Surface,
    app: *App,
    parent: *Window,
    context: apprt.surface.NewSurfaceContext,
) !void {
    self.* = .{
        .app = app,
        .parent_window = parent,
    };

    // T113: this pane's identity exists before anything else can ask for it
    // (the IPC registry resolves it, the manifest records it, and the env bake
    // below hands it to the shell). A restore override replaces it further
    // down, before the bake.
    _ = pane_id_mod.generate(&self.pane_id);

    // Create a manual-reset event for synchronizing resize with the
    // renderer thread. Manual-reset so we control exactly when it's reset.
    self.frame_event = w32.CreateEventW(null, 1, 0, null);

    // Create a WS_CHILD window inside the parent Window container.
    const parent_hwnd = parent.hwnd orelse return error.Win32Error;
    const sr = parent.surfaceRect();
    // WS_CLIPSIBLINGS is the other half of the container's WS_CLIPCHILDREN
    // (T1031): a layout pass moves several panes, and without it a pane that
    // has already been moved can be painted over by a sibling that is still
    // at its old geometry for the rest of the pass. With the pair in place a
    // relayout is one frame instead of a flash per child.
    const hwnd = w32.CreateWindowExW(
        0,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_CLIPSIBLINGS,
        sr.left,
        sr.top,
        @intCast(@max(sr.right - sr.left, 1)),
        @intCast(@max(sr.bottom - sr.top, 1)),
        parent_hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Accept dropped files so a file dragged onto the terminal pastes
    // its path. WM_DROPFILES is delivered to surfaceWndProc.
    w32.DragAcceptFiles(hwnd, 1);

    // Store the Surface pointer in the window's GWLP_USERDATA so that
    // the WndProc can retrieve it.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Get the device context. With CS_OWNDC, this DC is valid for
    // the lifetime of the window.
    self.hdc = w32.GetDC(hwnd);
    if (self.hdc == null) return error.Win32Error;
    errdefer {
        _ = w32.ReleaseDC(hwnd, self.hdc.?);
        self.hdc = null;
    }

    // Set up the pixel format for OpenGL
    try self.setupPixelFormat();

    // Create the WGL context
    self.hglrc = @ptrCast(gl_loader.active().createContext(@ptrCast(self.hdc.?)));
    if (self.hglrc == null) return error.Win32Error;
    errdefer {
        _ = gl_loader.active().makeCurrent(null, null);
        _ = gl_loader.active().deleteContext(@ptrCast(self.hglrc.?));
        self.hglrc = null;
    }

    // Query the initial DPI and size
    self.updateDpiScale();
    self.updateClientSize();

    log.debug("Win32 surface created: {}x{} scale={d:.2}", .{
        self.width,
        self.height,
        self.scale,
    });

    // Show the child window before initializing the core surface.
    // core_surface.init() spawns ConPTY + cmd.exe which needs the
    // window to be visible and have valid dimensions. On the old
    // top-level architecture, ShowWindow was called in createWindow()
    // before core_surface.init(). We must preserve that order.
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);

    // --- Core terminal surface initialization ---
    const alloc = app.core_app.alloc;

    // Create the themed scrollbar popup (owned by the surface HWND).
    self.scrollbar = try Scrollbar.create(alloc, hwnd, self);
    errdefer if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    };

    // Seed initial theme colors from the app config.
    if (self.scrollbar) |sb| {
        sb.setTheme(
            app.config.background.toTerminalRGB(),
            app.config.foreground.toTerminalRGB(),
        );
    }

    // Register this surface with the core app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Create a config copy for this surface.
    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();

    // T185: `newConfig` inherited the focused pane's OSC-7 pwd, which for a
    // shell that never reports (cmd.exe has no prompt hook) is frozen at
    // that pane's STARTING directory. When the focused pane's shell tracks
    // its cwd only in the OS (`pwd_reported` false), override with the
    // shell process's real cwd so ctrl+n / new tab / split land where the
    // user actually is. This runs BEFORE the IPC overrides below, so an
    // explicit `--working-directory` still wins. The same config value is
    // what T144 forwards to the local agent's OPEN, so the override covers
    // exec and agent panes alike.
    if (apprt.surface.shouldInheritWorkingDirectory(context, &app.config)) live: {
        const prev = app.core_app.focusedSurface() orelse break :live;
        const carena = config._arena.?.allocator();
        const live = prev.rt_surface.livePwd(carena) orelse break :live;
        config.@"working-directory" = .{ .path = live };
    }

    // Capture the focused surface's live (possibly ctrl+scroll-zoomed)
    // font size for `window-inherit-font-size` (Mac parity: embedded.zig
    // newSurfaceOptions). Captured before core_surface.init: focus only
    // moves to this new pane later via the deferred SetFocus, so the
    // focused surface is still the pane the user opened us from. Applied
    // AFTER init via setFontSize so `original_font_size` keeps the config
    // default and reset_font_size returns to it.
    const inherit_font_points: f32 = points: {
        if (!app.config.@"window-inherit-font-size") break :points 0;
        const focused = app.core_app.focusedSurface() orelse break :points 0;
        break :points focused.font_size.points;
    };

    // Apply IPC overrides (command/cwd/env) queued on the parent window by
    // the IPC server. One-shot: cleared here so a later plain tab/split
    // doesn't inherit them.
    if (parent.pending_surface_overrides) |ov| {
        parent.pending_surface_overrides = null;
        const carena = config._arena.?.allocator();
        // T113: adopt the restored identity BEFORE the env bake below, so the
        // re-attached shell's baked `$GHOZTTY_PANE_ID` still names this pane.
        // A malformed value is dropped (the generated one stands) rather than
        // producing a pane that answers to garbage.
        if (ov.pane_id) |pid| {
            if (pane_id_mod.isValid(pid)) {
                @memcpy(&self.pane_id, pid);
            } else {
                log.warn("session-restore: ignoring malformed pane id '{s}'", .{pid});
            }
        }
        if (ov.command_argv) |argv| {
            const copy = try carena.alloc([:0]const u8, argv.len);
            for (argv, 0..) |arg, i| copy[i] = try carena.dupeZ(u8, arg);
            config.command = .{ .direct = copy };
        }
        if (ov.working_directory) |wd| {
            config.@"working-directory" = .{ .path = try carena.dupe(u8, wd) };
        }
        for (ov.env) |env_var| {
            const kv = try std.fmt.allocPrint(
                carena,
                "{s}={s}",
                .{ env_var.key, env_var.value },
            );
            config.env.parseCLI(carena, kv) catch |err| {
                log.warn("IPC env override rejected key={s} err={}", .{ env_var.key, err });
            };
        }
        if (ov.remote) |r| {
            // Recorded BEFORE core_surface.init so remoteBackend() branches
            // the termio backend to `.remote` (remote-machines design §3.2).
            self.remote_conn = r.connection;
            self.remote_is_local_agent = r.local_agent;
            self.remote_working_directory = r.working_directory;
            self.remote_shell = r.shell;
            // Non-null ⇒ ATTACH to a restored session (T89f2) rather than OPEN.
            self.remote_session_id = r.session_id;
            // T109: the persisted screen + the offset it reflects, so the ATTACH
            // asks for a delta instead of the whole ring.
            self.remote_restore_snapshot = r.restore_snapshot;
            self.remote_restore_offset = r.restore_offset;
            // T422: this pane's own banner is coming back, so the
            // session-interrupted notice must not overwrite it.
            self.remote_pane_banner_restored = r.pane_banner_restored;
            // An explicit remote command travels through the same surface
            // config seam Exec uses; the core only forwards it into the
            // agent OPEN when `wait-after-command` marks it as explicitly
            // requested (the stall-fix invariant — a local default command
            // like the login shell must never reach a remote agent). It is
            // NOT wrapped by the local shell table: the agent applies its
            // own shell's native convention.
            if (r.command) |cmd| {
                config.command = .{ .shell = try carena.dupeZ(u8, cmd) };
                config.@"wait-after-command" = true;
                // T468: …with ONE exception to "not wrapped by the local shell
                // table". For the LOCAL agent the flavor table IS the right
                // one (the agent is this machine), and on Windows the
                // keep-alive lives in argv, which cannot ride the command
                // string. The command above still travels as the label.
                self.remote_command_argv = r.command_argv;
            }
        }
    }

    // T113: bake `$GHOZTTY_PANE_ID` into the pane's environment, the way the
    // Mac apprt does via `surface_cfg.environmentVariables`. This rides the
    // surface config's `env` overrides on purpose: that is the ONE seam both
    // backends read — an exec pane applies it last as `env_override`, and an
    // agent-backed pane (session-persistence is on by default, so that is
    // every local pane) has it forwarded verbatim in the OPEN's env, which the
    // agent also replays when it RELAUNCHes a tombstone. Applied AFTER the IPC
    // overrides so the ghoztty-owned id always wins over a stray `--env`.
    {
        const carena = config._arena.?.allocator();
        const kv = try std.fmt.allocPrint(
            carena,
            "GHOZTTY_PANE_ID={s}",
            .{self.paneId()},
        );
        config.env.parseCLI(carena, kv) catch |err| {
            log.warn("pane id env bake failed err={}", .{err});
        };
    }

    // T118: bake this app's own IPC endpoint too, through the same seam and
    // for the same reason — so an IPC command run inside the pane drives THIS
    // instance rather than whichever build `ghoztty` on `$PATH` resolves to.
    // On Windows the value is a pipe name, but the var keeps the documented
    // `GHOZTTY_IPC_SOCKET` spelling (see `apprt.ipc.socket_env`). Riding the
    // `env` overrides carries it to all three spawn paths for free: plain
    // exec applies it as `env_override`, the agent forwards it in the OPEN
    // (and replays it on RELAUNCH), and a remote pane gets it too — a remote
    // pane's IPC still belongs to the LOCAL app.
    if (app.ipcEndpoint()) |endpoint| {
        const carena = config._arena.?.allocator();
        const kv = try std.fmt.allocPrint(
            carena,
            "{s}={s}",
            .{ apprt.ipc.socket_env, endpoint },
        );
        config.env.parseCLI(carena, kv) catch |err| {
            log.warn("ipc endpoint env bake failed err={}", .{err});
        };
    }

    // T492: bake `$GHOZTTY_WINDOW_NAME` from the window's canonical IPC name,
    // so panes of an AUTO-named window (Ctrl+N, bare `+new-window`, restore)
    // can target their own window. The Mac injects windowName into the surface
    // config the same way; here `Window.init` has always claimed `ipc_name`
    // before its first surface exists, so every non-quick-terminal pane —
    // first tab, later tabs, splits — reads the name the window actually
    // HOLDS (an adopted `--target` that lost its name to an incumbent bakes
    // the minted fallback, which is the routable one). Only when nothing set
    // it yet: an explicit `--target`/`--env` override or a user `env` config
    // arrived via the overrides above and wins. Quick terminals have no IPC
    // name and keep the core's per-surface fallback.
    if (parent.ipc_name) |wn| {
        if (config.env.map.get("GHOZTTY_WINDOW_NAME") == null) {
            const carena = config._arena.?.allocator();
            const kv = try std.fmt.allocPrint(
                carena,
                "GHOZTTY_WINDOW_NAME={s}",
                .{wn},
            );
            config.env.parseCLI(carena, kv) catch |err| {
                log.warn("window name env bake failed err={}", .{err});
            };
        }
    }

    // Initialize the core surface. This sets up fonts, the renderer, PTY,
    // and spawns the renderer + IO threads.
    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );

    // Apply the inherited font size (embedded.zig applies opts.font_size
    // the same way, post-init). Non-fatal: a font failure must not kill
    // surface creation.
    if (inherit_font_points != 0 and
        inherit_font_points != self.core_surface.font_size.points)
    {
        var font_size = self.core_surface.font_size;
        font_size.points = inherit_font_points;
        self.core_surface.setFontSize(font_size) catch |err| {
            log.warn("failed to inherit font size err={}", .{err});
        };
    }

    // The remote cwd/shell strings were borrowed from the IPC request arena
    // for the duration of core_surface.init only (termio.Remote duped them).
    // Clear them so nothing dangles past the request. `remote_conn` stays:
    // it is owned by the parent Window and outlives this surface.
    self.remote_working_directory = null;
    self.remote_shell = null;
    self.remote_command_argv = null;
    // T109: same rule, and here it is not merely tidy — the App reuses one
    // decode scratch buffer per restored leaf, so a pointer left behind would
    // name the NEXT pane's screen.
    self.remote_restore_snapshot = null;
    self.remote_restore_offset = 0;

    // Mark the surface as ready. Before this point, Win32 messages
    // (triggered by ShowWindow, wglCreateContext, etc.) must be ignored.
    self.core_surface_ready = true;
    self.core_surface_initialized = true;

    // Seed the cached pwd HERE, not on the first `+list` (T111b). The value
    // is already final: `Termio.init` → `backend.initTerminal` sets the
    // initial pwd synchronously before this point, and every later change
    // arrives as a `.pwd` action. Seeding now costs one uncontended lock on
    // a pane that has not produced a byte yet; seeding lazily charged that
    // same lock to whichever `+list` happened to see the pane first, which
    // under a flood is not cheap at all — measured at a 19.2 s `+list`
    // handler when the first sighting landed on a storm pane.
    if (self.core_surface.pwd(self.app.core_app.alloc)) |maybe| {
        if (maybe) |p| {
            defer self.app.core_app.alloc.free(p);
            self.setPwd(p);
        } else self.setPwd("");
    } else |_| {}

    // Report the OS color scheme so OSC 10/11 queries and `light:`/`dark:`
    // conditional config start out correct (T26). WM_SETTINGCHANGE keeps
    // it current afterwards.
    self.core_surface.colorSchemeCallback(Window.systemColorScheme()) catch |err| {
        log.warn("initial color scheme report failed err={}", .{err});
    };
}

pub fn deinit(self: *Surface) void {
    log.debug("surface deinit: start addr={x}", .{@intFromPtr(self)});

    // Drop IPC names pointing at this pane before the memory can be
    // recycled. Registry targets are keyed on the PaneView leaf (T90c), so
    // a surface that never made it into a tree — an init that failed before
    // `PaneView.createTerminal` — has no names to drop.
    if (self.pane_view) |pv| self.app.ipcForget(.{ .pane = pv });

    if (self.title) |t| {
        self.app.core_app.alloc.free(t);
        self.title = null;
    }

    if (self.title_from_terminal) |t| {
        self.app.core_app.alloc.free(t);
        self.title_from_terminal = null;
    }

    if (self.pwd) |p| {
        self.app.core_app.alloc.free(p);
        self.pwd = null;
    }

    if (self.core_surface_initialized) {
        log.debug("surface deinit: core_surface.deinit start", .{});
        self.core_surface.deinit();
        log.debug("surface deinit: core_surface.deinit done", .{});

        self.app.core_app.deleteSurface(self);
        log.debug("surface deinit: deleteSurface done", .{});
    }

    // Snapshot buffer: freed only after core_surface.deinit so the
    // renderer thread (the only other toucher) is already joined.
    if (self.snap_buffer.len > 0) {
        self.app.core_app.alloc.free(self.snap_buffer);
        self.snap_buffer = &.{};
    }
    if (self.snap_dib) |dib| {
        _ = w32.DeleteObject(dib);
        self.snap_dib = null;
        self.snap_dib_bits = null;
    }

    if (self.frame_event) |event| {
        _ = w32.CloseHandle(event);
        self.frame_event = null;
    }
    log.debug("surface deinit: frame_event closed", .{});

    if (self.hglrc) |hglrc| {
        log.debug("surface deinit: wglMakeCurrent(null)", .{});
        _ = gl_loader.active().makeCurrent(null, null);
        log.debug("surface deinit: wglDeleteContext", .{});
        _ = gl_loader.active().deleteContext(@ptrCast(hglrc));
        self.hglrc = null;
    }
    log.debug("surface deinit: GL context cleaned up", .{});

    if (self.hdc) |hdc| {
        if (self.hwnd) |hwnd| {
            log.debug("surface deinit: ReleaseDC", .{});
            _ = w32.ReleaseDC(hwnd, hdc);
        }
        self.hdc = null;
    }
    log.debug("surface deinit: DC released", .{});

    // Destroy the themed scrollbar before the surface HWND is gone.
    if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    }

    // Destroy the dim overlay before the surface HWND (its owner) is gone.
    if (self.dim_overlay) |d| {
        d.destroy();
        self.dim_overlay = null;
    }

    // Close an open banner editor targeting this pane (T35) — e.g. an IPC
    // `+close` while the dialog is up; its surface pointer must not dangle.
    if (self.parent_window.banner_dialog) |dlg| {
        if (dlg.surface == self) dlg.cancel();
    }

    // Destroy the banner overlay before the surface HWND (its owner) is
    // gone, and free the banner source (T35).
    if (self.banner_overlay) |b| {
        b.destroy();
        self.banner_overlay = null;
    }
    if (self.banner_text) |t| {
        self.app.core_app.alloc.free(t);
        self.banner_text = null;
    }

    // T412: the cached screen snapshot dies with the pane it describes.
    if (self.last_snapshot) |s| {
        self.app.core_app.alloc.free(s);
        self.last_snapshot = null;
    }

    // Same for the read-only badge (T445).
    if (self.readonly_badge) |b| {
        b.destroy();
        self.readonly_badge = null;
    }

    // ...and the key-state pill (T446), which also owns an animation timer
    // that must be killed before its window goes away.
    if (self.key_state_indicator) |k| {
        k.destroy();
        self.key_state_indicator = null;
    }

    // Destroy popup windows and their GDI resources.
    if (self.search_hwnd) |popup| {
        _ = w32.DestroyWindow(popup);
        self.search_hwnd = null;
        self.search_edit = null;
        self.search_count_label = null;
    }
    if (self.search_font) |f| {
        _ = w32.DeleteObject(f);
        self.search_font = null;
    }
    if (self.link_preview_hwnd) |h| {
        _ = w32.DestroyWindow(h);
        self.link_preview_hwnd = null;
    }
    if (self.link_font) |f| {
        _ = w32.DeleteObject(f);
        self.link_font = null;
    }
    if (self.palette_hwnd) |popup| {
        _ = w32.DestroyWindow(popup);
        self.palette_hwnd = null;
        self.palette_edit = null;
    }
    if (self.palette_font) |f| {
        _ = w32.DeleteObject(f);
        self.palette_font = null;
    }
    if (self.palette_paint_font) |f| {
        _ = w32.DeleteObject(f);
        self.palette_paint_font = null;
    }
    self.freePaletteJumpEntries();

    // Reap the child HWND, but not from this stack (T681). Calling
    // DestroyWindow here is what the first win32 commit found segfaulting
    // inside OPENGL32.dll's window-destruction hook, on the same stack that
    // had just deleted the WGL context — so the handle is POSTED to the app's
    // message-only window and destroyed from the top of the message loop
    // instead, with the renderer thread joined, the context deleted and the DC
    // released. Leaving it for the parent window's own teardown (what this did
    // until T681) leaked one USER object per closed pane for the life of the
    // app, and USER objects are a per-process quota of 10k.
    //
    // Clearing GWLP_USERDATA first does double duty: it stops surfaceWndProc
    // from touching this soon-to-be-freed Surface, and it is the second factor
    // `App.performSurfaceReap` checks so a handle Win32 recycled in the
    // meantime is never destroyed out from under its new owner.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        self.app.reapSurfaceHwnd(hwnd);
    }
    self.hwnd = null;
    log.debug("surface deinit: complete", .{});
}

/// Set up a pixel format suitable for OpenGL rendering.
fn setupPixelFormat(self: *Surface) !void {
    const pfd = w32.PIXELFORMATDESCRIPTOR{
        .nSize = @sizeOf(w32.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
        .iPixelType = w32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cRedBits = 0,
        .cRedShift = 0,
        .cGreenBits = 0,
        .cGreenShift = 0,
        .cBlueBits = 0,
        .cBlueShift = 0,
        .cAlphaBits = 8,
        .cAlphaShift = 0,
        .cAccumBits = 0,
        .cAccumRedBits = 0,
        .cAccumGreenBits = 0,
        .cAccumBlueBits = 0,
        .cAccumAlphaBits = 0,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .cAuxBuffers = 0,
        .iLayerType = 0, // PFD_MAIN_PLANE
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };

    // Through the chosen implementation, not gdi32 directly (T1251): a
    // standalone fallback such as Mesa's `opengl32.dll` owns its own pixel
    // formats, and GDI knows nothing about them.
    const gl = gl_loader.active();
    const format = gl.choosePixelFormat(@ptrCast(self.hdc.?), &pfd);
    if (format == 0) return error.Win32Error;

    if (gl.setPixelFormat(@ptrCast(self.hdc.?), format, &pfd) == 0)
        return error.Win32Error;
}

/// Update the DPI scale factor from the window's DPI.
fn updateDpiScale(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        const dpi = w32.GetDpiForWindow(hwnd);
        if (dpi != 0) {
            self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
    }
}

/// Update the cached client area size.
fn updateClientSize(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) != 0) {
            self.width = @intCast(rect.right - rect.left);
            self.height = @intCast(rect.bottom - rect.top);
        }
    }
}

// -----------------------------------------------------------------------
// Methods called by the core Surface.zig (rt_surface.*)
// -----------------------------------------------------------------------

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.scale, .y = self.scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    if (self.hwnd) |hwnd| {
        var point: w32.POINT = undefined;
        if (w32.GetCursorPos_(&point) != 0) {
            _ = w32.ScreenToClient(hwnd, &point);
            return .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            };
        }
    }
    // GetCursorPos failed (not the input desktop: locked workstation, secure
    // desktop, disconnected RDP, or a background test desktop). The last
    // position carried by a mouse message is the right answer there — and is
    // in fact the more accurate one, being synchronized with the event.
    if (self.last_cursor_client) |p| return .{
        .x = @floatFromInt(p.x),
        .y = @floatFromInt(p.y),
    };
    // Nothing to fall back on. Signal failure rather than returning a bogus
    // {0,0} origin, so the core skips the mouse computation instead of
    // resolving it against the top-left cell (which produced spurious
    // hover/selection at 0,0).
    return error.GetCursorPosFailed;
}

pub fn getTitle(self: *const Surface) ?[:0]const u8 {
    return self.title;
}

/// Notify the core whether this surface is currently visible. When a surface
/// is occluded (background tab, hidden split-zoom pane, minimized window) the
/// renderer skips rebuilding/rendering frames until it is visible again
/// (src/renderer/Thread.zig). The core mailbox dedupes redundant states, so
/// re-asserting the same visibility (e.g. on every layout pass) is cheap.
pub fn setVisible(self: *Surface, visible: bool) void {
    // Hide the hovered-URL bubble when this surface is occluded so a stale
    // preview doesn't float over the newly-active tab.
    if (!visible) {
        if (self.link_preview_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }
    if (!self.core_surface_ready) return;
    self.core_surface.occlusionCallback(visible) catch |err| {
        log.warn("occlusionCallback failed err={}", .{err});
    };
}

/// Show (or reposition) this pane's dim overlay at the given fill color
/// (COLORREF) and alpha. Lazily creates the overlay popup on first use.
/// Called by Window.updateDimOverlays (T74).
pub fn showDimOverlay(self: *Surface, color: u32, alpha: u8, batch: ?*?w32.HDWP) void {
    const hwnd = self.hwnd orelse return;
    if (self.dim_overlay == null) {
        self.dim_overlay = DimOverlay.create(
            self.app.core_app.alloc,
            hwnd,
            self.app.hinstance,
        ) catch |err| {
            log.warn("dim overlay create failed err={}", .{err});
            return;
        };
    }
    _ = self.dim_overlay.?.show(color, alpha, batch);
}

/// Hide this pane's dim overlay if it exists.
pub fn hideDimOverlay(self: *Surface) void {
    if (self.dim_overlay) |d| d.hide();
}

/// Show, reposition or hide this pane's read-only badge to match
/// `core_surface.readonly` (T445).
///
/// Driven from the STATE rather than from the `.readonly` action, so a tab
/// switch, a split-divider drag, a DPI change and a session restore all keep
/// the badge honest — an action-only path marks the pane once and then lets
/// the badge drift away from the pane it is glued to. Idempotent and cheap:
/// a pane that is not read-only and never has been pays one bool test.
pub fn updateReadonlyBadge(self: *Surface) void {
    if (!self.core_surface_ready) return;
    if (!self.core_surface.readonly) {
        if (self.readonly_badge) |b| b.hide();
        return;
    }
    const hwnd = self.hwnd orelse return;
    if (self.readonly_badge == null) {
        self.readonly_badge = ReadonlyBadge.create(
            self.app.core_app.alloc,
            self,
            hwnd,
            self.app.hinstance,
        ) catch |err| {
            log.warn("readonly badge create failed err={}", .{err});
            return;
        };
    }
    const config = &self.app.config;
    const pane_bg: color_math.Rgb = self.background_tint orelse .{
        .r = config.background.r,
        .g = config.background.g,
        .b = config.background.b,
    };
    self.readonly_badge.?.update(self.scale, pane_bg);
}

/// Show, reposition or hide this pane's key-state pill to match
/// `key_state_model` (T446).
///
/// Driven from the STATE rather than from the `.key_sequence` / `.key_table`
/// actions, for the reason `updateReadonlyBadge` documents: an action-only
/// path marks the pane once and then lets the popup drift away from the pane
/// it is glued to across a tab switch, a divider drag, a DPI change or a
/// window move. Idempotent and cheap — a pane with no pending keys and no
/// active table pays one `isEmpty` test.
pub fn updateKeyStateIndicator(self: *Surface) void {
    if (self.key_state_model.isEmpty()) {
        if (self.key_state_indicator) |k| k.hide();
        return;
    }
    const hwnd = self.hwnd orelse return;
    if (self.key_state_indicator == null) {
        self.key_state_indicator = KeyStateIndicator.create(
            self.app.core_app.alloc,
            hwnd,
            self.app.hinstance,
        ) catch |err| {
            log.warn("key state indicator create failed err={}", .{err});
            return;
        };
    }
    const config = &self.app.config;
    const pane_bg: color_math.Rgb = self.background_tint orelse .{
        .r = config.background.r,
        .g = config.background.g,
        .b = config.background.b,
    };
    self.key_state_indicator.?.update(self.scale, pane_bg, &self.key_state_model);
}

/// Re-check the z-order of every layered popup this pane owns and heal any
/// stray `WS_EX_TOPMOST` another process left behind (T142). A no-op in the
/// normal case; see `overlay_zorder.zig`. Rides window activation as well as
/// the layout path, because the moment the defect is VISIBLE — a background
/// window's banner over the foreground — is an activation change, and a
/// window nobody resizes would otherwise stay broken.
pub fn healOverlayZOrders(self: *Surface) void {
    const owner = self.hwnd orelse return;
    if (self.banner_overlay) |b| w32.healOverlayZOrder(b.hwnd, owner);
    if (self.dim_overlay) |d| w32.healOverlayZOrder(d.hwnd, owner);
    if (self.readonly_badge) |b| w32.healOverlayZOrder(b.hwnd, owner);
    if (self.key_state_indicator) |k| w32.healOverlayZOrder(k.hwnd, owner);
    if (self.scrollbar) |s| w32.healOverlayZOrder(s.hwnd, owner);
    // The hovered-URL bubble belongs on this list too (T180). It was left out
    // of T142 as a "short-lived popup", but only its VISIBILITY is short-lived:
    // the HWND is created on the first link hover and lives until the surface
    // is destroyed, so a stray topmost on it outlives every hover that follows.
    if (self.link_preview_hwnd) |h| w32.healOverlayZOrder(h, owner);
}

/// Set (or clear, with null/empty text) this pane's sticky banner (T35).
/// Reached from the `.pane_banner` apprt action (OSC 7778 / core routing)
/// and the `+set-banner` IPC verb. Stores the raw markdown source so the
/// banner editor can prefill it, and drives the overlay strip.
pub fn setPaneBanner(self: *Surface, text: ?[]const u8) void {
    const alloc = self.app.core_app.alloc;

    if (self.banner_text) |old| {
        alloc.free(old);
        self.banner_text = null;
    }

    // T422: the banner is persisted per pane in the session-layout manifest, and
    // nothing else in a banner change touches the topology — so without this the
    // manifest only learns about it if some unrelated mutation happens to write
    // afterwards. A banner set hours before a crash has to be on disk.
    self.app.markLayoutDirty();

    const t = text orelse "";
    if (t.len == 0) {
        if (self.banner_overlay) |b| {
            b.destroy();
            self.banner_overlay = null;
            // Give the vacated strip band back to the terminal (T101).
            self.parent_window.layoutSplits();
        }
        return;
    }

    self.banner_text = alloc.dupeZ(u8, t) catch null;

    const hwnd = self.hwnd orelse return;
    if (self.banner_overlay == null) {
        self.banner_overlay = BannerOverlay.create(
            alloc,
            self,
            hwnd,
            self.app.hinstance,
        ) catch |err| {
            log.warn("banner overlay create failed err={}", .{err});
            return;
        };
    }
    const overlay = self.banner_overlay.?;
    overlay.setText(t);
    self.refreshBannerColors();
    // Re-run the split layout so the terminal band shrinks by the strip
    // height (T101 — the strip must sit ABOVE the grid, not over it).
    // The layout pass repositions the overlay via updatePaneBanners.
    self.parent_window.layoutSplits();
}

/// Height the window layout must reserve above this pane's terminal for
/// the sticky banner strip (T101), clamped to the pane slot. Records the
/// reservation on the overlay so updatePosition glues the strip into the
/// reserved band. 0 when no banner is set.
///
/// `slot_w` is the pane slot's width, fed down so the banner's tables size
/// their columns to the pane and re-measure on every resize (T123).
pub fn bannerLayoutInset(self: *Surface, slot_w: i32, slot_h: i32) i32 {
    const overlay = self.banner_overlay orelse return 0;
    const inset = banner_layout.clampInset(overlay.insetHeight(self.scale, slot_w), slot_h);
    overlay.inset = inset;
    return inset;
}

/// Re-derive the banner strip colors from the pane's effective background
/// (per-pane tint or config background). Cheap and idempotent; called on
/// set and from Window.updatePaneBanners so config reloads re-color live.
pub fn refreshBannerColors(self: *Surface) void {
    const overlay = self.banner_overlay orelse return;
    const config = &self.app.config;
    const pane_bg: color_math.Rgb = self.background_tint orelse .{
        .r = config.background.r,
        .g = config.background.g,
        .b = config.background.b,
    };
    overlay.setColors(pane_bg, .{
        .r = config.foreground.r,
        .g = config.foreground.g,
        .b = config.foreground.b,
    });
}

// -----------------------------------------------------------------------
// Hero-mode thumbnail snapshots (T59a). Request/publish run on the GUI
// thread; wanted/acquire/commit run on the renderer thread.
// -----------------------------------------------------------------------

pub const SnapReq = struct { w: u32, h: u32 };

/// GUI thread: ask the renderer for a thumbnail capture at (w, h) px.
/// Pre-sizes the pixel buffer so the renderer thread never allocates,
/// then wakes the renderer so idle panes still produce a capture (the
/// re-present of the last frame runs the capture hook).
pub fn heroSnapRequest(self: *Surface, w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    if (!self.core_surface_ready) return;
    {
        self.snap_mutex.lock();
        defer self.snap_mutex.unlock();
        const len: usize = @as(usize, w) * @as(usize, h) * 4;
        if (self.snap_buffer.len != len) {
            const alloc = self.app.core_app.alloc;
            if (self.snap_buffer.len > 0) alloc.free(self.snap_buffer);
            self.snap_buffer = alloc.alloc(u8, len) catch {
                self.snap_buffer = &.{};
                return;
            };
        }
        self.snap_req_w = w;
        self.snap_req_h = h;
        self.snap_notify_hwnd = self.parent_window.hwnd;
    }
    self.snap_requested.store(true, .release);
    self.core_surface.renderer_thread.wakeup.notify() catch {};
}

/// Renderer thread: is a snapshot wanted? One atomic load when idle.
pub fn heroSnapWanted(self: *Surface) ?SnapReq {
    if (!self.snap_requested.load(.acquire)) return null;
    self.snap_mutex.lock();
    defer self.snap_mutex.unlock();
    if (self.snap_req_w == 0 or self.snap_req_h == 0) return null;
    return .{ .w = self.snap_req_w, .h = self.snap_req_h };
}

/// Renderer thread: lock and return the destination pixel buffer for a
/// capture at (w, h). Returns null (unlocked) if the request changed
/// since heroSnapWanted. On success the mutex STAYS HELD until
/// heroSnapCommit.
pub fn heroSnapAcquire(self: *Surface, w: u32, h: u32) ?[]u8 {
    self.snap_mutex.lock();
    const len: usize = @as(usize, w) * @as(usize, h) * 4;
    if (self.snap_req_w != w or self.snap_req_h != h or
        self.snap_buffer.len != len)
    {
        self.snap_mutex.unlock();
        return null;
    }
    return self.snap_buffer;
}

/// Renderer thread: complete a capture begun with heroSnapAcquire,
/// releasing the mutex. On success, bumps the sequence, clears the
/// request flag, and notifies the GUI thread. On failure the request
/// stays pending so the next frame retries.
pub fn heroSnapCommit(self: *Surface, ok: bool) void {
    const notify: ?w32.HWND = if (ok) self.snap_notify_hwnd else null;
    var seq: u32 = 0;
    if (ok) {
        self.snap_seq +%= 1;
        seq = self.snap_seq;
        self.snap_requested.store(false, .release);
    }
    self.snap_mutex.unlock();
    if (ok and (seq <= 4 or seq % 256 == 0)) {
        // Debug-build oracle for hero-mode.ps1: proves the renderer of a
        // (possibly hidden) pane produced a thumbnail capture. Rate-limited
        // so an hours-long hero session doesn't flood the debug log.
        log.debug("hero snap committed hwnd={?} seq={}", .{ self.hwnd, seq });
    }
    if (notify) |h| {
        _ = w32.PostMessageW(
            h,
            Window.WM_APP_HERO_SNAP,
            @intFromPtr(self.hwnd orelse return),
            0,
        );
    }
}

/// GUI thread: capture this pane's rendered content at (w, h) into `out`
/// (bottom-up BGRA, `w*h*4` bytes) and return once the renderer has delivered
/// it. Debug-only test seam behind the `capture-pane` IPC action (T275); see
/// `pane_capture.zig` for why it exists and what the pixels become.
///
/// It drives the SAME request slot hero mode does, deliberately: there is one
/// GL readback path in this app (`renderer/OpenGL.zig` `captureThumb`) and a
/// second one would be a second set of lifetime rules over the same texture.
/// The consequence is that a capture taken while hero mode is running steals
/// that pane's next thumbnail — the carousel simply re-requests on its next
/// 150ms tick, and nothing here runs during a hero session anyway.
///
/// Blocks the GUI thread for up to `timeout_ms`. That is acceptable ONLY
/// because the work happens on the pane's own renderer thread, which needs
/// nothing from the message loop to finish it — the same reason hero mode can
/// keep requesting captures from panes whose window is hidden.
pub fn captureContent(
    self: *Surface,
    w: u32,
    h: u32,
    out: []u8,
    timeout_ms: u64,
) error{ NotReady, WrongSize, Timeout }!void {
    if (w == 0 or h == 0) return error.WrongSize;
    if (out.len != @as(usize, w) * @as(usize, h) * 4) return error.WrongSize;
    if (!self.core_surface_ready) return error.NotReady;

    // The sequence BEFORE the request: a capture is delivered when the seq
    // moves, and comparing against a remembered value rather than against a
    // flag is what makes a stale hero snapshot sitting in the buffer
    // unmistakable for this request's answer.
    const before = seq: {
        self.snap_mutex.lock();
        defer self.snap_mutex.unlock();
        break :seq self.snap_seq;
    };

    self.heroSnapRequest(w, h);

    var waited: u64 = 0;
    const step_ms: u64 = 5;
    while (waited < timeout_ms) : (waited += step_ms) {
        {
            self.snap_mutex.lock();
            defer self.snap_mutex.unlock();
            if (self.snap_seq != before and
                self.snap_req_w == w and self.snap_req_h == h and
                self.snap_buffer.len == out.len)
            {
                @memcpy(out, self.snap_buffer);
                return;
            }
        }
        std.Thread.sleep(step_ms * std.time.ns_per_ms);
    }
    return error.Timeout;
}

/// GUI thread (WM_APP_HERO_SNAP): sync the DIB cache from the snapshot
/// buffer. Returns true if the DIB changed (tile needs a repaint).
pub fn heroSnapPublish(self: *Surface) bool {
    self.snap_mutex.lock();
    defer self.snap_mutex.unlock();
    if (self.snap_seq == self.snap_dib_seq) return false;
    const w: i32 = @intCast(self.snap_req_w);
    const h: i32 = @intCast(self.snap_req_h);
    if (self.snap_buffer.len != @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) return false;
    if (self.snap_dib == null or self.snap_dib_w != w or self.snap_dib_h != h) {
        if (self.snap_dib) |dib| _ = w32.DeleteObject(dib);
        self.snap_dib = null;
        self.snap_dib_bits = null;
        var bits: ?*anyopaque = null;
        // Positive height = bottom-up DIB, matching GL's bottom-up
        // ReadPixels order — no flip needed (T58 decision 1).
        const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = w, .biHeight = h } };
        const dib = w32.CreateDIBSection(null, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
        self.snap_dib = dib;
        self.snap_dib_bits = @ptrCast(bits orelse {
            _ = w32.DeleteObject(dib);
            self.snap_dib = null;
            return false;
        });
        self.snap_dib_w = w;
        self.snap_dib_h = h;
    }
    @memcpy(self.snap_dib_bits.?[0..self.snap_buffer.len], self.snap_buffer);
    self.snap_dib_seq = self.snap_seq;
    return true;
}

/// The LOCAL pid of this pane's shell, or 0 when there is none to name.
///
/// Session-persistence panes are remote-backed but LOCAL — their child runs
/// under this box's `ghoztty-agent`, so the agent-reported child pid is a real
/// pid in this machine's process table. A CROSS-MACHINE pane's pid indexes
/// ANOTHER machine's table and is never returned: matching it here would
/// silently name an unrelated local process.
pub fn shellPid(self: *Surface) u32 {
    if (!self.core_surface_ready) return 0;
    switch (self.core_surface.io.backend) {
        .exec => |*exec| {
            const process = exec.subprocess.process orelse return 0;
            return switch (process) {
                .fork_exec => |cmd| if (cmd.pid) |handle| w32.GetProcessId(handle) else 0,
                .flatpak => 0,
            };
        },
        .remote => |*r| {
            if (!r.local) return 0;
            const pid = r.child_pid.load(.acquire);
            if (pid <= 0) return 0;
            return std.math.cast(u32, pid) orelse 0;
        },
    }
}

/// The pane's shell process's REAL current working directory, read from the
/// OS (T185) — the live answer for shells that never report OSC 7. cmd.exe
/// (and bash, nu, …) call SetCurrentDirectory/chdir on every `cd`, so the
/// PEB value tracks the user where the OSC-7 seed stays frozen at the
/// starting directory forever. Returns null when the shell HAS reported
/// OSC 7 (the cached `pwd` is already live and, for pwsh, the process cwd
/// would be the stale one), when there is no shell pid, or when the read
/// fails — callers then fall back to the cached value. Takes no ghoztty
/// locks (two syscall reads on the shell pid), so it is safe in the
/// `+list` hot path (T111b).
pub fn livePwd(self: *Surface, alloc: Allocator) ?[]u8 {
    if (self.pwd_reported) return null;
    const pid = self.shellPid();
    if (pid == 0) return null;
    return internal_os.process_cwd.fromPid(pid, alloc);
}

/// True when this pane's shell is sitting idle — nothing is running under it,
/// so closing the pane destroys no work (T41). `map` is a Toolhelp32 snapshot
/// (`ProcessTree.snapshot`); callers closing a whole window take one for every
/// pane rather than one each.
///
/// A CROSS-MACHINE pane has no local pid to walk, so it asks the machine that
/// owns the process instead: the agent samples its own process table and pushes
/// the answer (`META{has_descendants}`, T356), and this reads the last pushed
/// value. That path is only reached when there is no local pid — where we have
/// one, the snapshot taken at close time is the exact answer and wins.
///
/// Answers FALSE whenever it cannot know: a surface that is not up yet, a shell
/// missing from the snapshot (Toolhelp32 failed, and an empty map would
/// otherwise read as "nothing is running"), a remote pane whose agent never
/// reported (too old, not sampled yet) or whose link is down, a read-only
/// surface, or `confirm-close-surface = always` — a confirmation the user
/// configured unconditionally is not a question about the shell.
pub fn shellIsIdle(self: *Surface, map: *const ProcessTree.PidMap) bool {
    if (!self.core_surface_ready) return false;
    if (self.core_surface.readonly) return false;
    if (self.core_surface.config.confirm_close_surface == .always) return false;
    const pid = self.shellPid();
    if (pid != 0) {
        if (!ProcessTree.contains(map, pid)) return false;
        return !ProcessTree.hasDescendants(map, pid);
    }
    return switch (self.core_surface.io.backend) {
        .exec => false,
        .remote => |*r| !(r.shellHasDescendants() orelse return false),
    };
}

/// `shellIsIdle` against a snapshot taken here. A failed snapshot answers
/// "not idle", same as an unknown shell.
pub fn shellIsIdleNow(self: *Surface) bool {
    const alloc = self.app.core_app.alloc;
    var map = ProcessTree.snapshot(alloc) catch return false;
    defer map.deinit(alloc);
    return self.shellIsIdle(&map);
}

pub fn close(self: *Surface, process_active: bool) void {
    log.debug("Surface.close called process_active={}", .{process_active});
    // If a shell command is still running, prompt the user before
    // closing. Without this, Ctrl+Shift+W silently kills the running
    // process — macOS shows the same kind of dialog for parity.
    //
    // `process_active` is the core's verdict, and on Windows it is always
    // true: it comes from `cursorIsAtPrompt`, which needs OSC 133 marks that
    // cmd.exe and stock PowerShell never emit. So an idle shell sitting at its
    // prompt looked identical to a running build. The process table is what
    // knows here, so a shell with no descendants closes without a dialog (T41).
    //
    // A CROSS-MACHINE pane can offer DISCONNECT instead (T1390): close the pane
    // here and leave its agent session - and the process inside it - running on
    // the box that hosts it. That widens the gate past the idle check, because
    // an idle shell on another machine is exactly the one worth walking away
    // from. It is widened HERE, at an interactive caller; `+close` and the
    // other scripted paths never reach this function, so nothing programmatic
    // can raise a modal.
    const offering = session_disconnect.machineIsDisconnectable(
        self.parent_window.remote_machine != null,
    ) and session_disconnect.isDisconnectable(self.disconnectFacts());

    if (offering) {
        var text_buf: [session_disconnect.text_cap]u8 = undefined;
        const text = session_disconnect.informativeText(
            &text_buf,
            if (self.parent_window.remote_machine) |m| m.displayName() else null,
            1,
        );
        var wide: [session_disconnect.text_cap * 2:0]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wide, text) catch 0;
        wide[wlen] = 0;

        const result = ConfirmDialog.show(
            self.app,
            self.parent_window.hwnd,
            self.parent_window.scale,
            self.hwnd,
            .{
                .title = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty"),
                .text = wide[0..wlen :0],
                .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Close"),
                .alt_label = std.unicode.utf8ToUtf16LeStringLiteral("Disconnect"),
                // Disconnect is the default: the answer that ends nothing.
                .default_alt = true,
            },
        );
        switch (result) {
            .cancel => return,
            .ok => {},
            .alt => self.pinDetach(),
        }
    } else if (process_active and !self.shellIsIdleNow()) {
        const result = ConfirmDialog.show(
            self.app,
            self.parent_window.hwnd,
            self.parent_window.scale,
            self.hwnd,
            .{
                .title = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty"),
                .text = std.unicode.utf8ToUtf16LeStringLiteral(
                    "A process is still running in this terminal.\nClose anyway?",
                ),
            },
        );
        if (result != .ok) return;
    }
    // Defer destruction to the message loop via PostMessage.
    // This avoids calling surface.deinit() from inside core_surface
    // callbacks (during tick), which causes reentrancy and crashes.
    // The WM_CLOSE handler in surfaceWndProc will call closeTab.
    if (self.hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
    }
}

/// Mark whether this surface's agent session should CLOSE (terminate the
/// child + free the session) rather than DETACH (keep-alive for re-attach)
/// when the surface is eventually freed (T89e). Set true on user-initiated
/// pane/tab/window close paths BEFORE the surface is deinitialized; never on
/// app-quit teardown (Window.deinit), so quitting leaves sessions alive for
/// the next launch. No-op for local exec surfaces (the child dies with the
/// surface anyway) and before core-surface init.
/// A CLOSE marking is REFUSED while the pane is Disconnect-pinned (T1390), and
/// silently: the callers are the ordinary close paths, all of which mark
/// unconditionally, and none of them has anything useful to do about a refusal.
/// A DETACH marking always goes through — it agrees with the pin.
pub fn setSessionCloseIntent(self: *Surface, intent: bool) void {
    const resolved = self.detach_pin.resolve(intent) orelse return;
    if (self.core_surface_ready) self.core_surface.setSessionCloseIntent(resolved);
}

/// Record the user's **Disconnect** for this pane (T1390).
pub fn pinDetach(self: *Surface) void {
    self.detach_pin.pin();
}

/// Release the pin: this pane is live again (re-adopted by a `+rearrange` that
/// kept it), so a LATER close is a close like any other.
pub fn clearDetachPin(self: *Surface) void {
    self.detach_pin.clear();
}

/// The facts `session_disconnect` decides on, read off this live pane.
pub fn disconnectFacts(self: *Surface) session_disconnect.PaneFacts {
    return .{
        .has_surface = true,
        .process_exited = !self.core_surface_ready or self.core_surface.child_exited,
        .confirm_close_enabled = self.core_surface_ready and
            self.core_surface.config.confirm_close_surface != .false,
    };
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

/// Show a modal clipboard confirmation dialog on the owning window and
/// return true if the user approved. Mirrors the macOS/GTK clipboard
/// confirmation flow so the core's paste-protection and OSC 52
/// authorization guards actually gate the operation on Windows.
fn confirmClipboard(
    self: *Surface,
    comptime message: [:0]const u8,
    comptime title: [:0]const u8,
) bool {
    // default_cancel: an accidental Enter must not approve.
    const result = ConfirmDialog.show(
        self.app,
        self.parent_window.hwnd,
        self.parent_window.scale,
        self.hwnd,
        .{
            .title = std.unicode.utf8ToUtf16LeStringLiteral(title),
            .text = std.unicode.utf8ToUtf16LeStringLiteral(message),
        },
    );
    return result == .ok;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return false;

    const alloc = self.app.core_app.alloc;

    // Read the clipboard into an owned UTF-8 string in a tight scope so the
    // system clipboard is CLOSED before any modal confirmation dialog — the
    // dialog can be up for an unbounded time and would otherwise block every
    // other process's clipboard access.
    const utf8z: [:0]const u8 = blk: {
        // Retried: another process holding the clipboard for a few
        // milliseconds is normal, and a refused open here means the paste
        // silently does nothing (T947).
        if (!clipboard_open.open(self.hwnd)) {
            log.warn("OpenClipboard failed", .{});
            return false;
        }
        defer _ = w32.CloseClipboard();

        const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return false;
        const ptr16 = w32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed", .{});
            return false;
        };
        defer _ = w32.GlobalUnlock(hglobal);

        const wptr: [*]const u16 = @ptrCast(@alignCast(ptr16));
        var wlen: usize = 0;
        while (wptr[wlen] != 0) wlen += 1;

        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch |err| {
            log.warn("utf16LeToUtf8Alloc failed: {}", .{err});
            return false;
        };
        defer alloc.free(utf8);
        break :blk try alloc.dupeZ(u8, utf8);
    };
    defer alloc.free(utf8z);

    // The confirmation prompt below runs a modal message loop that can tick
    // the core (child-exited → surface close → this Surface freed). Capture
    // what we need to re-resolve the surface by id afterwards rather than
    // dereferencing `self`.
    const core_app = self.app.core_app;
    const surface_id = self.core_surface.id;

    // Complete with confirmed=false so the core runs its safety checks. If it
    // flags the paste as unsafe (paste-protection) or the OSC 52 read as
    // unauthorized (clipboard-read = ask), prompt and only re-complete with
    // confirmed=true on approval. Passing confirmed=true up front — as this
    // used to — silently disabled both guards on Windows.
    self.core_surface.completeClipboardRequest(state, utf8z, false) catch |err| {
        // confirmClipboard takes comptime strings (utf8ToUtf16LeStringLiteral),
        // so each error path calls it with its own literals. `self` may be
        // freed while the modal dialog pumps messages, so re-resolve the
        // surface by id before re-completing.
        const approved = switch (err) {
            error.UnsafePaste => self.confirmClipboard(
                "The text being pasted contains characters that could run " ++
                    "commands unexpectedly (for example, newlines).\n\nPaste anyway?",
                "Ghoztty \u{2014} Potentially Unsafe Paste",
            ),
            error.UnauthorizedPaste => self.confirmClipboard(
                "An application is requesting access to read the clipboard.\n\nAllow this?",
                "Ghoztty \u{2014} Authorize Clipboard Access",
            ),
            else => {
                log.err("completeClipboardRequest error: {}", .{err});
                return true;
            },
        };
        if (approved) {
            const cs = core_app.findSurfaceByID(surface_id) orelse return true;
            cs.completeClipboardRequest(state, utf8z, true) catch |e| {
                log.err("completeClipboardRequest (confirmed) error: {}", .{e});
            };
        }
    };

    return true;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    // Only the standard clipboard is supported on Win32.
    if (clipboard_type != .standard) return;

    // The confirm dialog below pumps messages and can free `self` (child
    // exit → surface close). Capture the App (stable for the process) and
    // avoid dereferencing `self` after the prompt.
    const app = self.app;

    // When the core requests confirmation (e.g. an OSC 52 clipboard write
    // with clipboard-write = ask), prompt before writing. Previously the
    // flag was discarded, so remote apps could write the clipboard silently.
    if (confirm) {
        if (!self.confirmClipboard(
            "An application is requesting to write to the system clipboard.\n\nAllow this?",
            "Ghoztty \u{2014} Authorize Clipboard Access",
        )) return;
    }

    // Find the text/plain content.
    const text = blk: {
        for (contents) |c| {
            if (std.mem.eql(u8, c.mime, "text/plain")) break :blk c.data;
        }
        // No text/plain content; nothing to write.
        return;
    };

    const alloc = app.core_app.alloc;

    // Convert UTF-8 to UTF-16LE.  Add 1 for the null terminator.
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
    defer alloc.free(utf16);

    // Size in bytes including the null terminator (u16 → 2 bytes each).
    const byte_size = (utf16.len + 1) * @sizeOf(u16);

    // Allocate a moveable global memory block.
    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse {
        log.warn("GlobalAlloc failed for clipboard write", .{});
        return;
    };

    const dst_bytes = w32.GlobalLock(hglobal) orelse {
        log.warn("GlobalLock failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    };

    // Copy the UTF-16LE data (including null terminator) into the block.
    const dst16: [*]u16 = @ptrCast(@alignCast(dst_bytes));
    @memcpy(dst16[0..utf16.len], utf16);
    dst16[utf16.len] = 0; // null terminator

    _ = w32.GlobalUnlock(hglobal);

    // No explicit owner: this write is not tied to the (possibly freed) surface
    // hwnd, so it claims the APP's clipboard window instead of no window at all
    // (T992) — the empty-then-set pair below is only atomic while a real window
    // owns the open, and another app slipping between the two is how a copy
    // silently ends up holding that app's content.
    // Retried for the same reason as the paste read above (T947): a copy that
    // loses the race is a keystroke that vanished with no message.
    if (!clipboard_open.open(null)) {
        log.warn("OpenClipboard failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    }
    defer _ = w32.CloseClipboard();

    _ = w32.EmptyClipboard();

    // SetClipboardData takes ownership of hglobal on success.
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, hglobal) == null) {
        log.warn("SetClipboardData failed", .{});
        _ = w32.GlobalFree(hglobal);
    }
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
    const alloc = self.app.core_app.alloc;
    var env = try internal_os.getEnvMap(alloc);
    errdefer env.deinit();

    // TERM and COLORTERM are set by termio/Exec.zig with platform-aware
    // logic (checking for terminfo, resources_dir, etc.). Do not set them here.

    return env;
}

/// Set the pane title. Called from performAction(.set_title) — the
/// terminal-reported (OSC 0/2) path. While the user holds a manual pane
/// title (setUserTitle), terminal titles are remembered for
/// restore-on-clear but do not displace it (T92).
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const alloc = self.app.core_app.alloc;
    const copy = alloc.dupeZ(u8, title) catch return;
    if (self.title_from_terminal) |old| {
        alloc.free(old);
        self.title_from_terminal = copy;
        return;
    }
    if (self.title) |old| alloc.free(old);
    self.title = copy;
    if (self.pane_view) |pv| self.parent_window.onPaneTitleChanged(pv, title);
}

/// Cache the pane's working directory (core `.pwd` action, or the one-time
/// seed from the terminal on the first `+list`). GUI thread only.
pub fn setPwd(self: *Surface, pwd_str: []const u8) void {
    const alloc = self.app.core_app.alloc;
    const copy = alloc.dupeZ(u8, pwd_str) catch return;
    if (self.pwd) |old| alloc.free(old);
    self.pwd = copy;
}

/// Set (or clear, with null) the user's manual pane title ("Change Pane
/// Title…" prompt, T92). While set, terminal-reported titles are
/// remembered but don't displace it; clearing restores the last
/// terminal-reported title.
pub fn setUserTitle(self: *Surface, title: ?[]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (title) |t| {
        const copy = alloc.dupeZ(u8, t) catch return;
        if (self.title_from_terminal == null) {
            // First manual set: the current (terminal) title becomes the
            // remembered restore value. Ownership moves; no copy.
            self.title_from_terminal = self.title orelse
                (alloc.dupeZ(u8, "") catch null);
            self.title = null;
        }
        if (self.title) |old| alloc.free(old);
        self.title = copy;
    } else {
        // No manual title active: nothing to clear.
        const remembered = self.title_from_terminal orelse return;
        self.title_from_terminal = null;
        if (self.title) |old| alloc.free(old);
        self.title = remembered;
    }
    if (self.title) |t| {
        if (self.pane_view) |pv| self.parent_window.onPaneTitleChanged(pv, t);
    }
}

/// Toggle fullscreen mode. Delegates to the parent Window.
pub fn toggleFullscreen(self: *Surface) void {
    self.parent_window.toggleFullscreen();
}

/// Set the mouse cursor shape. Caches the handle so WM_SETCURSOR can
/// restore it (Windows resets the cursor on every mouse move otherwise).
pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const cursor = switch (shape) {
        .text => w32.LoadCursorW(null, w32.IDC_IBEAM),
        .pointer => w32.LoadCursorW(null, w32.IDC_HAND),
        .crosshair => w32.LoadCursorW(null, w32.IDC_CROSS),
        .e_resize, .w_resize, .ew_resize => w32.LoadCursorW(null, w32.IDC_SIZEWE),
        .n_resize, .s_resize, .ns_resize => w32.LoadCursorW(null, w32.IDC_SIZENS),
        .nwse_resize, .nw_resize, .se_resize => w32.LoadCursorW(null, w32.IDC_SIZENWSE),
        .nesw_resize, .ne_resize, .sw_resize => w32.LoadCursorW(null, w32.IDC_SIZENESW),
        .not_allowed => w32.LoadCursorW(null, w32.IDC_NO),
        .progress => w32.LoadCursorW(null, w32.IDC_APPSTARTING),
        .wait => w32.LoadCursorW(null, w32.IDC_WAIT),
        else => w32.LoadCursorW(null, w32.IDC_ARROW),
    };
    self.current_cursor = cursor;
    if (cursor) |c| _ = w32.SetCursor(c);
}

/// Handle WM_SETCURSOR — restore our cached cursor so Windows doesn't
/// reset it to the class cursor (IDC_ARROW) on every mouse move.
/// Returns true if we handled it (caller should return TRUE).
pub fn handleSetCursor(self: *Surface) bool {
    // Hidden cursor: pass NULL.
    if (!self.mouse_visible) {
        _ = w32.SetCursor(null);
        return true;
    }
    if (self.current_cursor) |c| {
        _ = w32.SetCursor(c);
        return true;
    }
    return false;
}

/// Child window ID for the search edit control.
pub const SEARCH_EDIT_ID: u16 = 100;

/// Show or hide the search bar.
/// Show (or clear, when url is empty) the hovered-URL preview at the
/// bottom-left of the surface, like a browser status bubble. Driven by the
/// mouse_over_link action.
pub fn setMouseOverLink(self: *Surface, url: []const u8) void {
    if (url.len == 0) {
        if (self.link_preview_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        return;
    }
    const hwnd = self.hwnd orelse return;
    const s = self.scale;

    if (self.link_preview_hwnd == null) {
        self.link_preview_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            self.parent_window.hwnd.?,
            null,
            self.app.hinstance,
            null,
        );
        if (self.link_preview_hwnd) |h| {
            if (self.link_font == null) {
                self.link_font = w32.CreateFontW(
                    -@as(i32, @intFromFloat(@round(13.0 * s))),
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
            }
            if (self.link_font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const preview = self.link_preview_hwnd orelse return;

    var buf16: [512]u16 = undefined;
    const truncated = if (url.len > 480) url[0..480] else url;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, truncated) catch return;
    buf16[@min(len16, buf16.len - 1)] = 0;
    _ = w32.SetWindowTextW(preview, @ptrCast(&buf16));

    // Rough width from character count, capped to the surface width.
    const char_w: i32 = @intFromFloat(@round(7.0 * s));
    const pad: i32 = @intFromFloat(@round(12.0 * s));
    const pw: i32 = @min(
        @as(i32, @intCast(self.width)),
        @as(i32, @intCast(len16)) * char_w + pad,
    );
    const ph: i32 = @intFromFloat(@round(22.0 * s));
    var pt = w32.POINT{ .x = 0, .y = @as(i32, @intCast(self.height)) - ph };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(preview, null, pt.x, pt.y, pw, ph, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(preview, w32.SW_SHOWNOACTIVATE);
    // AFTER the show, because the show is half the reason to heal (T180):
    // `SW_SHOWNOACTIVATE` lifts a popup to the top of the non-topmost band,
    // and a link hovered in a BACKGROUND window then parks its bubble over
    // whatever application is actually in front. The other half is the stray
    // `WS_EX_TOPMOST` T142 was filed for, which on this popup would survive
    // every later hover — see `overlay_zorder.zig` for both.
    w32.healOverlayZOrder(preview, hwnd);
}

/// Store the total match count from the search_total action and refresh
/// the "selected/total" label in the search bar.
pub fn setSearchTotal(self: *Surface, total: ?usize) void {
    self.search_total = total;
    self.updateSearchCountLabel();
}

/// Store the selected match index (0-based) from the search_selected
/// action and refresh the "selected/total" label in the search bar.
pub fn setSearchSelected(self: *Surface, selected: ?usize) void {
    self.search_selected = selected;
    self.updateSearchCountLabel();
}

fn updateSearchCountLabel(self: *Surface) void {
    const label = self.search_count_label orelse return;
    var buf8: [32]u8 = undefined;
    const text8: []const u8 = blk: {
        const total = self.search_total orelse break :blk "";
        if (total == 0) break :blk "0/0";
        if (self.search_selected) |sel| {
            break :blk std.fmt.bufPrint(&buf8, "{d}/{d}", .{ sel + 1, total }) catch "";
        }
        break :blk std.fmt.bufPrint(&buf8, "-/{d}", .{total}) catch "";
    };
    var buf16: [64]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch 0;
    buf16[len16] = 0;
    _ = w32.SetWindowTextW(label, @ptrCast(&buf16));
}

pub fn setSearchActive(self: *Surface, active: bool, needle: [:0]const u8) void {
    if (active) {
        // Close command palette if open (mutual exclusion)
        if (self.palette_active) {
            self.setCommandPaletteActive(false);
        }
        self.search_active = true;
        self.ensureSearchBar();
        if (self.search_hwnd) |popup| {
            self.positionSearchBar();
            _ = w32.ShowWindow(popup, w32.SW_SHOW);

            // Set the search text if provided
            if (needle.len > 0) {
                if (self.search_edit) |edit| {
                    var wbuf: [512]u16 = undefined;
                    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, needle) catch 0;
                    if (wlen < wbuf.len) {
                        wbuf[wlen] = 0;
                        _ = w32.SetWindowTextW(edit, @ptrCast(&wbuf));
                    }
                }
            }

            // Focus the edit control
            if (self.search_edit) |edit| {
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.search_active = false;
        self.search_total = null;
        self.search_selected = null;
        self.updateSearchCountLabel();
        if (self.search_hwnd) |popup| {
            _ = w32.ShowWindow(popup, 0); // SW_HIDE
        }
        // Return focus to the main window (deferred — T48).
        if (self.hwnd) |hwnd| {
            App.deferSetFocus(hwnd);
        }
    }
}

/// Create the search popup window if it doesn't exist. The popup is a
/// small top-level window (WS_POPUP) that floats over the main window.
/// A child Edit control inside it handles the actual text input.
/// We can't use a child window of the main HWND because OpenGL covers
/// the entire client area and paints over child controls.
fn ensureSearchBar(self: *Surface) void {
    if (self.search_hwnd != null) return;

    const s = self.scale;
    const bar_w: i32 = @intFromFloat(@round(310.0 * s));
    const bar_h: i32 = @intFromFloat(@round(32.0 * s));
    const pad: i32 = @intFromFloat(@round(4.0 * s));

    // Create the popup container (no title bar, tool window so it
    // doesn't appear in the taskbar). Parent is the top-level Window
    // HWND so it floats above the terminal surface.
    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        bar_w,
        bar_h,
        self.parent_window.hwnd.?,
        null,
        self.app.hinstance,
        null,
    ) orelse return;

    // The popup's frame follows the same surface its body paints from
    // (T563) - it was pinned dark, so a light theme got a black hairline
    // border around a light bar.
    system_colors.applyPanelChrome(popup, self.panelPalette());
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Create the Edit control inside the popup, leaving room on the right
    // for the match-count label ("3/17").
    const count_w: i32 = @intFromFloat(@round(64.0 * s));
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        bar_w - pad * 2 - 2 - count_w,
        bar_h - pad * 2 - 2,
        popup,
        @ptrFromInt(@as(usize, SEARCH_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };

    // Right-aligned match-count label, filled by search_total /
    // search_selected actions (see setSearchTotal/setSearchSelected).
    self.search_count_label = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_RIGHT | w32.SS_CENTERIMAGE,
        bar_w - pad - count_w,
        pad,
        count_w - pad,
        bar_h - pad * 2 - 2,
        popup,
        null,
        self.app.hinstance,
        null,
    );

    // Set a readable font (DPI-scaled)
    self.search_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(16.0 * s))),
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
    if (self.search_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.search_count_label) |label| {
            _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }

    // Set GWLP_USERDATA on the popup so surfaceWndProc can route
    // WM_COMMAND (EN_CHANGE) and WM_CTLCOLOREDIT to this Surface.
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.search_hwnd = popup;
    self.search_edit = edit;
}

/// Position the search popup at the top-right corner of the parent window.
fn positionSearchBar(self: *Surface) void {
    const popup = self.search_hwnd orelse return;
    const hwnd = self.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const s = self.scale;
        const bar_width: i32 = @intFromFloat(@round(310.0 * s));
        const bar_height: i32 = @intFromFloat(@round(32.0 * s));
        const padding: i32 = @intFromFloat(@round(8.0 * s));
        const title_bar: i32 = @intFromFloat(@round(32.0 * s));
        // Position at top-right of the window, below the title bar
        _ = w32.MoveWindow(
            popup,
            rect.right - bar_width - padding,
            rect.top + title_bar + padding,
            bar_width,
            bar_height,
            1,
        );
    }
}

/// Handle text changes in the search edit control (EN_CHANGE).
pub fn handleSearchChange(self: *Surface) void {
    if (!self.core_surface_ready) return;
    const search = self.search_edit orelse return;

    // Get the current search text
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(search, &wbuf, @intCast(wbuf.len)));

    // 512 units can need 1536 bytes: searching for a long CJK phrase used to
    // panic here rather than search (T990). Truncating keeps the search box a
    // search box.
    var utf8_buf: [1024]u8 = undefined;
    const utf8_len = utf16_text.toUtf8Truncating(&utf8_buf, wbuf[0..wlen]);

    // Need a null-terminated slice for performBindingAction
    var needle_buf: [1025]u8 = undefined;
    @memcpy(needle_buf[0..utf8_len], utf8_buf[0..utf8_len]);
    needle_buf[utf8_len] = 0;
    const needle: [:0]const u8 = needle_buf[0..utf8_len :0];

    _ = self.core_surface.performBindingAction(.{ .search = needle }) catch |err| {
        log.err("search error: {}", .{err});
    };
}

/// Handle key events in the search bar. Returns true if handled.
pub fn handleSearchKey(self: *Surface, vk: u16) bool {
    if (!self.core_surface_ready) return false;

    switch (vk) {
        w32.VK_RETURN => {
            // Enter = next match, Shift+Enter = previous match
            const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const nav: input.Binding.Action = if (shift)
                .{ .navigate_search = .previous }
            else
                .{ .navigate_search = .next };
            _ = self.core_surface.performBindingAction(nav) catch |err| {
                log.err("navigate_search error: {}", .{err});
            };
            return true;
        },
        w32.VK_ESCAPE => {
            _ = self.core_surface.performBindingAction(.end_search) catch |err| {
                log.err("end_search error: {}", .{err});
            };
            return true;
        },
        else => return false,
    }
}

// -----------------------------------------------------------------------
// Command Palette
// -----------------------------------------------------------------------

/// The palette's static entries ARE the shared command registry (T189), in
/// registry order: `commands.zig` owns every command's name and what it
/// performs, and the menu system (T143) renders that same list in a
/// different shape. Neither surface can therefore offer a command the other
/// has never heard of — the drift that left hero mode out of the palette in
/// T57 while its keybind worked.
const palette_entries = commands.registry;

/// Cap on user-configured command-palette-entry commands shown in the
/// palette (bounds the fixed-size palette_filtered index array).
pub const MAX_USER_PALETTE_ENTRIES = 64;

/// Palette indexes >= JUMP_BASE refer to the "Focus: <pane>" jump-entry
/// snapshot (T555). The base is FIXED (past the largest possible user
/// range) rather than stacked on the live user count, so a config reload
/// while the palette is open cannot re-map a jump index onto a command.
const JUMP_BASE: u16 = palette_entries.len + MAX_USER_PALETTE_ENTRIES;

/// One "Focus: <pane>" palette entry (T555): a live pane somewhere in the
/// app, named the way the Mac palette's jumpOptions name it. The pane is
/// held by its stable id rather than a pointer — a pane can be closed over
/// IPC while the palette is open, and a stale id resolves to nothing
/// instead of a freed pointer.
const JumpEntry = struct {
    /// The pane's stable id (`$GHOZTTY_PANE_ID`), arena-owned.
    pane_id: []const u8,
    /// The full label, `"Focus: <title>"`, arena-owned.
    label: []const u8,
    /// The `~`-abbreviated cwd (terminal) or location (viewer), arena-owned;
    /// null when there is nothing to say or the title already says it.
    subtitle: ?[]const u8,
};

/// Palette indexes >= palette_entries.len refer to user-configured
/// command-palette-entry commands from the config, in order.
fn paletteEntryName(self: *const Surface, idx: u16) []const u8 {
    if (idx < palette_entries.len) {
        const entry = palette_entries[idx];
        // T89e: signal that quitting keeps persistent sessions alive.
        if (entry.quit_keep and self.app.config.@"session-persistence")
            return "Quit Ghoztty (keep sessions)";
        return entry.name;
    }
    if (idx >= JUMP_BASE) {
        const jidx = idx - JUMP_BASE;
        if (jidx >= self.palette_jump_entries.len) return "";
        return self.palette_jump_entries[jidx].label;
    }
    const user = self.app.config.@"command-palette-entry".value.items;
    const uidx = idx - palette_entries.len;
    if (uidx >= user.len) return "";
    return user[uidx].title;
}

fn paletteEntryAction(self: *const Surface, idx: u16) ?input.Binding.Action {
    if (idx < palette_entries.len) {
        // Locally handled kinds have no binding action; returning null
        // suppresses a misleading keybind hint.
        const entry = palette_entries[idx];
        return if (entry.kind == .binding) entry.action else null;
    }
    // Jump entries dispatch a focus, not a binding — no keybind hint.
    if (idx >= JUMP_BASE) return null;
    const user = self.app.config.@"command-palette-entry".value.items;
    const uidx = idx - palette_entries.len;
    if (uidx >= user.len) return null;
    return user[uidx].action;
}

/// The dimmed trailing text for a palette row — only jump entries carry one
/// (the pane's abbreviated cwd, T555).
fn paletteEntrySubtitle(self: *const Surface, idx: u16) ?[]const u8 {
    if (idx < JUMP_BASE) return null;
    const jidx = idx - JUMP_BASE;
    if (jidx >= self.palette_jump_entries.len) return null;
    return self.palette_jump_entries[jidx].subtitle;
}

/// Free the jump-entry snapshot (palette close / surface deinit).
fn freePaletteJumpEntries(self: *Surface) void {
    self.palette_jump_entries = &.{};
    if (self.palette_jump_arena) |*arena| {
        arena.deinit();
        self.palette_jump_arena = null;
    }
}

/// Snapshot one "Focus: <pane>" entry per live pane across every window
/// (T555) — taken when the palette opens, exactly when Mac's `jumpOptions`
/// computes. Quick terminals are skipped (not addressable targets, same as
/// `+list`). Allocation failure degrades to a palette with fewer or no jump
/// entries, never an error the user sees.
fn buildPaletteJumpEntries(self: *Surface) void {
    self.freePaletteJumpEntries();
    self.palette_jump_arena = std.heap.ArenaAllocator.init(self.app.core_app.alloc);
    const arena = self.palette_jump_arena.?.allocator();

    var home_buf: [512]u8 = undefined;
    const home: ?[]const u8 = internal_os.home(&home_buf) catch null;

    var entries = std.ArrayList(JumpEntry).initCapacity(arena, 16) catch return;
    outer: for (self.app.windows.items) |window| {
        if (window.is_quick_terminal) continue;
        for (0..window.tab_count) |t| {
            // The tab title, for panes that have none of their own.
            const tab_title: []const u8 = std.unicode.utf16LeToUtf8Alloc(
                arena,
                window.tab_titles[t][0..window.tab_title_lens[t]],
            ) catch "";

            var it = window.tab_trees[t].iterator();
            while (it.next()) |entry| {
                if (entries.items.len >= palette_jump.max_entries) break :outer;
                const pane = entry.view;

                var title: []const u8 = undefined;
                var location: ?[]const u8 = null;
                if (pane.surface()) |s| {
                    title = palette_jump.displayTitle(s.getTitle(), tab_title);
                    // Live OS cwd first, OSC-7 cache second — the same
                    // composition as `+list` and the tab tooltip (T185).
                    location = s.livePwd(arena) orelse s.pwd;
                } else if (pane.viewer()) |v| {
                    title = palette_jump.displayTitle(v.title, tab_title);
                    location = v.location;
                } else continue;

                var tip_buf: [tab_tooltip.max_len]u8 = undefined;
                const sub: ?[]const u8 = if (location) |loc|
                    palette_jump.subtitle(&tip_buf, loc, home, title)
                else
                    null;

                const label = std.mem.concat(arena, u8, &.{
                    palette_jump.prefix, title,
                }) catch break :outer;
                entries.append(arena, .{
                    .pane_id = arena.dupe(u8, pane.paneId()) catch break :outer,
                    .label = label,
                    .subtitle = if (sub) |s2| arena.dupe(u8, s2) catch null else null,
                }) catch break :outer;
            }
        }
    }
    self.palette_jump_entries = entries.items;
}

/// Child window ID for the palette edit control.
pub const PALETTE_EDIT_ID: u16 = 200;

/// Layout constants for the palette list (unscaled, multiply by self.scale).
pub const PALETTE_LIST_TOP: f32 = 40.0;
pub const PALETTE_ITEM_HEIGHT: f32 = 28.0;

/// Toggle the command palette visibility.
pub fn setCommandPaletteActive(self: *Surface, active: bool) void {
    if (active) {
        // Close search bar if open (mutual exclusion)
        if (self.search_active) {
            self.setSearchActive(false, &[_:0]u8{});
        }
        self.palette_active = true;
        self.ensureCommandPalette();
        // Snapshot the "Focus: <pane>" jump entries at open (T555) — the
        // moment Mac's jumpOptions computes.
        self.buildPaletteJumpEntries();
        if (self.palette_hwnd) |popup| {
            self.positionCommandPalette();
            self.filterPaletteEntries("");
            _ = w32.ShowWindow(popup, w32.SW_SHOW);
            if (self.palette_edit) |edit| {
                _ = w32.SetWindowTextW(edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.palette_active = false;
        self.freePaletteJumpEntries();
        if (self.palette_hwnd) |popup| {
            _ = w32.ShowWindow(popup, 0); // SW_HIDE
        }
        if (self.hwnd) |hwnd| {
            App.deferSetFocus(hwnd); // T48
        }
    }
}

/// Create the command palette popup if it doesn't exist.
fn ensureCommandPalette(self: *Surface) void {
    if (self.palette_hwnd != null) return;

    const s = self.scale;
    const pal_w: i32 = @intFromFloat(@round(500.0 * s));
    const pal_h: i32 = @intFromFloat(@round(450.0 * s));
    const pad: i32 = @intFromFloat(@round(8.0 * s));
    const edit_h: i32 = @intFromFloat(@round(24.0 * s));

    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        pal_w,
        pal_h,
        self.parent_window.hwnd.?,
        null,
        self.app.hinstance,
        null,
    ) orelse return;

    // The popup's frame follows the same surface its body paints from
    // (T563) - it was pinned dark, so a light theme got a black hairline
    // border around a light bar.
    system_colors.applyPanelChrome(popup, self.panelPalette());
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Create the search edit at the top (DPI-scaled)
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        pal_w - pad * 2 - 2,
        edit_h,
        popup,
        @ptrFromInt(@as(usize, PALETTE_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };

    // Set font (DPI-scaled) — stored for cleanup in deinit
    self.palette_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(16.0 * s))),
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
    if (self.palette_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Set placeholder text via EM_SETCUEBANNER
    const placeholder = std.unicode.utf8ToUtf16LeStringLiteral("Type a command...");
    _ = w32.SendMessageW(edit, 0x1501, 1, @bitCast(@intFromPtr(placeholder))); // EM_SETCUEBANNER

    // Store surface pointer for message routing
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.palette_hwnd = popup;
    self.palette_edit = edit;
}

/// Position the command palette centered at the top of the parent window.
fn positionCommandPalette(self: *Surface) void {
    const popup = self.palette_hwnd orelse return;
    const hwnd = self.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const s = self.scale;
        const win_width = rect.right - rect.left;
        const pal_width: i32 = @intFromFloat(@round(500.0 * s));
        const pal_height: i32 = @intFromFloat(@round(450.0 * s));
        const title_bar: i32 = @intFromFloat(@round(40.0 * s));
        const x = rect.left + @divTrunc(win_width - pal_width, 2);
        const y = rect.top + title_bar;
        _ = w32.MoveWindow(popup, x, y, pal_width, pal_height, 1);
    }
}

/// Filter palette entries by a case-insensitive substring match.
fn filterPaletteEntries(self: *Surface, filter: []const u8) void {
    var count: u16 = 0;
    for (palette_entries, 0..) |entry, i| {
        if (filter.len == 0 or std.ascii.indexOfIgnoreCase(entry.name, filter) != null) {
            self.palette_filtered[count] = @intCast(i);
            count += 1;
        }
    }
    // User-configured command-palette-entry commands, appended after the
    // built-in entries.
    const user = self.app.config.@"command-palette-entry".value.items;
    const user_len = @min(user.len, MAX_USER_PALETTE_ENTRIES);
    for (user[0..user_len], 0..) |entry, i| {
        if (filter.len == 0 or std.ascii.indexOfIgnoreCase(entry.title, filter) != null) {
            self.palette_filtered[count] = @intCast(palette_entries.len + i);
            count += 1;
        }
    }
    // "Focus: <pane>" jump entries (T555), appended last. The filter also
    // matches the SUBTITLE, so panes can be found by directory.
    for (self.palette_jump_entries, 0..) |entry, i| {
        if (palette_jump.matches(filter, entry.label, entry.subtitle)) {
            self.palette_filtered[count] = @intCast(JUMP_BASE + i);
            count += 1;
        }
    }
    self.palette_count = count;
    self.palette_selected = 0;
    // Trigger repaint of the list area
    if (self.palette_hwnd) |popup| {
        _ = w32.InvalidateRect(popup, null, 1);
    }
}

/// Handle text changes in the palette search edit (EN_CHANGE).
pub fn handlePaletteChange(self: *Surface) void {
    const edit = self.palette_edit orelse return;

    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, @intCast(wbuf.len)));

    // Same shape as the Activity Monitor's filter (T989) and the machine
    // chooser's (T990): 256 units can need 768 bytes, so a long non-ASCII
    // palette query panicked here. Truncating filters on what fits.
    var utf8_buf: [512]u8 = undefined;
    const utf8_len = utf16_text.toUtf8Truncating(&utf8_buf, wbuf[0..wlen]);

    self.filterPaletteEntries(utf8_buf[0..utf8_len]);
}

/// Handle key events in the command palette. Returns true if handled.
pub fn handlePaletteKey(self: *Surface, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.setCommandPaletteActive(false);
            return true;
        },
        w32.VK_RETURN => {
            self.executePaletteSelection();
            return true;
        },
        w32.VK_UP => {
            if (self.palette_selected > 0) {
                self.palette_selected -= 1;
                if (self.palette_hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        w32.VK_DOWN => {
            if (self.palette_count > 0 and self.palette_selected < self.palette_count - 1) {
                self.palette_selected += 1;
                if (self.palette_hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        else => return false,
    }
}

/// Perform a registry command (T189). THE dispatch path for every command
/// surface — the palette today, the menu system tomorrow (T143/T190) — so a
/// command cannot behave one way when picked from a menu and another way
/// when picked from the palette.
///
/// Binding commands go through `performBindingAction`, exactly as their
/// keybind would. The rest are apprt-local because there is no binding to
/// perform.
pub fn performCommand(self: *Surface, id: commands.Id) void {
    if (!self.core_surface_ready) return;
    const cmd = commands.get(id);
    switch (cmd.kind) {
        // Opened locally via the machine chooser, not through a binding
        // action (there is none) — the T22c decision-4 path.
        .remote => {
            log.info("machine chooser: opening via command surface", .{});
            self.parent_window.openMachineChooser();
        },

        // The Activity Monitor panel (T285/T295), also apprt-local. Mac's
        // palette entry opens it on the window's OWN connection when there is
        // one and the LOCAL source otherwise
        // (RemoteActivityMonitor.openFromPalette:132-141).
        .activity => self.openActivityMonitor(),

        // Build provenance of this running instance (T52).
        .about => self.showAboutDialog(),

        // The Agent Integrations management window (T871): per-agent state
        // rows with Set Up / Update / Uninstall, probing off-thread. Mac's
        // palette entry opens the same window
        // (AppDelegate+Setup → AgentIntegrationsController.show).
        .claude => AgentIntegrationsDialog.open(
            self.app,
            self.parent_window.hwnd,
            self.parent_window.scale,
            self.hwnd,
        ),

        // The docs, in the default browser (macOS "Ghoztty Help").
        .help => self.app.openUrl(commands.help_url),

        // The three viewer palette entries (T396; Mac ViewerCommands.swift).
        .viewer_open_file => self.viewerOpenFilePrompt(),
        .viewer_open_url => RenameDialog.open(self.parent_window, .viewer_url, self),
        .viewer_open_browser => self.openViewerSplitBeside("about:blank", true),

        .binding => _ = self.core_surface.performBindingAction(cmd.action) catch |err| {
            log.err("command action error id={s} err={}", .{ @tagName(id), err });
        },
    }
}

/// Open the Activity Monitor for THIS surface's window (T295): a remote window
/// gets a panel riding its own connection, everything else gets Local.
///
/// The panel BORROWS that connection — the window owns it, and its session must
/// outlive the panel closing (`RemoteActivityMonitor.presentReusing`). The
/// source id is the window's machine identity, so a panel the chooser already
/// opened for the same machine is focused rather than duplicated.
fn openActivityMonitor(self: *Surface) void {
    const window = self.parent_window;
    const dialed = window.remote_dialed orelse return ActivityMonitor.openLocal(window);
    const machine = window.remote_machine orelse return ActivityMonitor.openLocal(window);

    // The registry key. A relay window keys on its DEVICE ID — the same string
    // the chooser opens with — so the two entry points meet at one panel.
    var id_buf: [ActivityMonitor.max_source_id]u8 = undefined;
    const id: []const u8 = switch (machine) {
        .relay => |r| blk: {
            if (r.device.len > id_buf.len) return ActivityMonitor.openLocal(window);
            @memcpy(id_buf[0..r.device.len], r.device);
            break :blk id_buf[0..r.device.len];
        },
        .tcp => |t| std.fmt.bufPrint(&id_buf, "{s}:{d}", .{ t.host, t.port }) catch
            return ActivityMonitor.openLocal(window),
    };

    ActivityMonitor.openReusing(window, .{ .remote = .{ .id = id } }, dialed.conn());
}

/// "Viewer: Open File in Pane…" (T396): a standard open-file dialog, then
/// the chosen file in a viewer split beside this pane (Mac's `NSOpenPanel`
/// sheet, `ViewerCommands.openFileFromPalette`). `GetOpenFileNameW` is
/// modal to the owner but runs a real message loop, so posted window
/// messages — the IPC server's `WM_APP_IPC` among them — keep dispatching
/// while it is up.
fn viewerOpenFilePrompt(self: *Surface) void {
    const owner = self.parent_window.hwnd orelse return;
    var file_buf: [4096:0]u16 = undefined;
    file_buf[0] = 0;
    var ofn: w32.OPENFILENAMEW = .{
        .hwndOwner = owner,
        .lpstrFile = &file_buf,
        .nMaxFile = file_buf.len,
        .lpstrTitle = std.unicode.utf8ToUtf16LeStringLiteral(
            "Choose a markdown or text file to view",
        ),
        .Flags = w32.OFN_FILEMUSTEXIST | w32.OFN_PATHMUSTEXIST |
            w32.OFN_HIDEREADONLY | w32.OFN_NOCHANGEDIR | w32.OFN_EXPLORER,
    };
    // Zero is both "cancelled" and "failed"; neither opens a pane.
    if (w32.GetOpenFileNameW(&ofn) == 0) return;
    const wlen = std.mem.indexOfSentinel(u16, 0, &file_buf);
    var utf8_buf: [std.fs.max_path_bytes]u8 = undefined;
    // All or nothing (T990): half a path names a different file, or nothing.
    const len = utf16_text.toUtf8AllOrNothing(&utf8_buf, file_buf[0..wlen]);
    if (len == 0) return;
    self.openViewerSplitBeside(utf8_buf[0..len], false);
}

/// Open a viewer split to the RIGHT of this pane showing `location`, with
/// this pane's working directory as the viewer's origin directory — the
/// shared tail of the three T396 palette entries, mirroring Mac's
/// `ViewerCommands.openViewer` (which seeds `surfaceView.pwd` the same
/// way). `focus_address` puts the caret in the new pane's address field
/// once the deferred pane focus has landed ("Open Browser Pane"'s caret
/// contract).
pub fn openViewerSplitBeside(self: *Surface, location: []const u8, focus_address: bool) void {
    const pv = self.pane_view orelse return;
    const alloc = self.app.core_app.alloc;
    // `livePwd` answers null when OSC 7 has reported (the cache is live)
    // or when the OS read fails — the cached value is the fallback either
    // way. The `Open` strings are borrowed (the pane dupes what it keeps),
    // so the live read is freed here.
    const live = self.livePwd(alloc);
    defer if (live) |p| alloc.free(p);
    const origin: ?[]const u8 = if (live) |p| p else if (self.pwd) |p| p else null;
    const pane = self.parent_window.newViewerSplitAt(pv, .right, 0.5, .{
        .location = location,
        .origin_directory = origin,
    }) catch |err| {
        log.warn("palette viewer split failed err={}", .{err});
        return;
    } orelse return;
    // The split queued a deferred SetFocus at the new pane (T48); this
    // post lands BEHIND it in the queue, so the caret reaches the address
    // field after the pane focus rather than being stolen by it (Mac
    // defers with `DispatchQueue.main.async` for the same reason).
    if (focus_address) {
        if (pane.viewer()) |v| {
            if (v.hwnd) |h| _ = w32.PostMessageW(h, ViewerPane.WM_APP_VIEWER_FOCUS_ADDRESS, 0, 0);
        }
    }
}

/// Execute the currently selected palette entry.
pub fn executePaletteSelection(self: *Surface) void {
    if (!self.core_surface_ready) return;
    if (self.palette_selected >= self.palette_count) return;

    const entry_idx = self.palette_filtered[self.palette_selected];

    // A "Focus: <pane>" jump entry (T555). The pane id is copied out BEFORE
    // the close — closing frees the jump-entry arena — and re-resolved by
    // identity, so a pane closed while the palette was open dissolves into a
    // no-op rather than a dangling pointer. The focus itself is the ONE
    // focus implementation (`IpcHandlers.focusTarget`), the same path a
    // `ghoztty://focus/<target>` link and the CLI take.
    if (entry_idx >= JUMP_BASE) {
        const jidx = entry_idx - JUMP_BASE;
        if (jidx >= self.palette_jump_entries.len) {
            self.setCommandPaletteActive(false);
            return;
        }
        var id_buf: pane_id_mod.Buf = undefined;
        const src = self.palette_jump_entries[jidx].pane_id;
        if (src.len > id_buf.len) {
            self.setCommandPaletteActive(false);
            return;
        }
        @memcpy(id_buf[0..src.len], src);
        const id = id_buf[0..src.len];
        self.setCommandPaletteActive(false);
        const target = self.app.ipcLookup(id) orelse return;
        IpcHandlers.focusTarget(target);
        return;
    }

    // Close the palette first.
    self.setCommandPaletteActive(false);

    // A registry entry runs through the shared command dispatch (T189), so
    // the palette and the menu perform it identically.
    if (entry_idx < palette_entries.len) {
        self.performCommand(palette_entries[entry_idx].id);
        return;
    }

    // Below the registry are the user's own `command-palette-entry`
    // commands, which are always binding actions.
    const action = self.paletteEntryAction(entry_idx) orelse return;

    // Execute the action
    _ = self.core_surface.performBindingAction(action) catch |err| {
        log.err("palette action error: {}", .{err});
    };
}

/// Show the About box: build provenance of THIS running instance (T52) —
/// the same answer as the IPC `version` verb, one dialog away. The modal
/// ConfirmDialog pumps its own message loop, so this is WndProc-safe
/// (unlike a Condition.wait — the T48 lesson).
pub fn showAboutDialog(self: *Surface) void {
    var arena_state = std.heap.ArenaAllocator.init(self.app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prov = provenance.collect(arena) catch return;

    // Every line here is a fact about THIS process (T1205). The old box put
    // the running build's version next to the ON-DISK file's mtime, so a
    // window running yesterday's build read as freshly updated — the user
    // checked About to confirm an install had worked and it told them the
    // opposite of the truth. The file's date is still shown, but only inside
    // the stale-build paragraph, where it is labelled as the other build's.
    const text = std.fmt.allocPrint(
        arena,
        "Ghoztty {s}\n\nCommit: {s}\nMode: {s}\nRuntime: {s}\nPID: {d}\nStarted: {s}\n\nExecutable:\n{s}{s}",
        .{
            prov.version,
            prov.commit,
            prov.mode,
            prov.runtime,
            prov.pid,
            prov.started,
            prov.exe,
            if (prov.newer_build_installed) stale: {
                break :stale std.fmt.allocPrint(
                    arena,
                    "\n\nA newer build was installed {s}.\nThis window is still running the older one — Windows cannot replace a running program.\n\nRestart Ghoztty to use the new build. Your sessions come back.",
                    .{prov.exe_modified},
                ) catch "";
            } else "",
        },
    ) catch return;
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(arena, text) catch return;

    // Stale: the box stops being an FYI and becomes the offer. Nothing about
    // "restart to pick it up" is discoverable otherwise, and this is the
    // surface the user opened precisely to ask the question.
    if (prov.newer_build_installed) {
        const r = ConfirmDialog.show(
            self.app,
            self.parent_window.hwnd,
            self.parent_window.scale,
            self.hwnd,
            .{
                .title = std.unicode.utf8ToUtf16LeStringLiteral("About Ghoztty"),
                .text = text_w,
                .style = .ok_cancel,
                .icon = .warning,
                .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Restart Now"),
                .cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Later"),
            },
        );
        if (r == .ok) self.app.restartIntoInstalledBuild();
        return;
    }

    _ = ConfirmDialog.show(
        self.app,
        self.parent_window.hwnd,
        self.parent_window.scale,
        self.hwnd,
        .{
            .title = std.unicode.utf8ToUtf16LeStringLiteral("About Ghoztty"),
            .text = text_w,
            .style = .ok_only,
            .icon = .info,
        },
    );
}

/// The palette the command palette and the search bar paint from (T563).
///
/// They are panels — a surface floating over the terminal with text and rows
/// on it — and until T563 they were the last hardcoded-dark ones: `RGB(30,30,30)`
/// behind the palette, `RGB(60,60,80)` under its selected row, two greys for
/// its text. On a light theme that put a black popup over a white window, on
/// the surface a user opens most.
pub fn panelPalette(self: *const Surface) panel_theme.Panel {
    return system_colors.panelFor(self.app);
}

/// The palette popup's surface fill, keyed on its color so a theme flip
/// replaces the object rather than repainting through a stale one. Process
/// lifetime and GUI-thread only, like every other `CachedBrush` here.
var palette_bg_brush: brush_cache.CachedBrush = .{};

/// Paint the command palette list area.
pub fn paintPalette(self: *Surface, hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    self.paintPaletteInto(hdc, hwnd);
}

/// The same chrome into a caller's DC, so a pixel probe can photograph the
/// palette synchronously (T940's contract, extended to this popup by T563).
/// Without it `PrintWindow` with no flags draws nothing here and the palette
/// is the one surface in this task that cannot be measured at all.
pub fn paintPaletteInto(self: *Surface, hdc: w32.HDC, hwnd: w32.HWND) void {
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;

    // The popup surface is the panel background. The brush is keyed on that
    // color rather than made once with the popup (T563): the popup outlives
    // its first open, so a brush created at construction time would still be
    // painting the palette the theme had then.
    const p = self.panelPalette();
    if (palette_bg_brush.get(system_colors.cr(p.bg))) |b| {
        _ = w32.FillRect(hdc, &client_rect, b);
    }

    // Reuse a cached 14pt font; create on first paint and keep it for
    // the lifetime of this popup. Rebuilt by handleDpiChange.
    const s = self.scale;
    if (self.palette_paint_font == null) {
        self.palette_paint_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(14.0 * s))),
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
    }
    const old_font = if (self.palette_paint_font) |f| w32.SelectObject(hdc, f) else null;
    defer {
        if (old_font) |of| _ = w32.SelectObject(hdc, of);
    }

    _ = w32.SetBkMode(hdc, 1); // TRANSPARENT

    const item_height: i32 = @intFromFloat(@round(PALETTE_ITEM_HEIGHT * s));
    const list_top: i32 = @intFromFloat(@round(PALETTE_LIST_TOP * s));
    const max_visible = @divTrunc(client_rect.bottom - list_top, item_height);
    if (max_visible <= 0) return; // popup too small to render any items

    // Calculate scroll offset to keep selected item visible
    var scroll_offset: i32 = 0;
    if (self.palette_selected >= max_visible) {
        scroll_offset = self.palette_selected - @as(u16, @intCast(max_visible)) + 1;
    }

    var i: u16 = 0;
    while (i < self.palette_count) : (i += 1) {
        const visual_idx = @as(i32, i) - scroll_offset;
        if (visual_idx < 0) continue;
        if (visual_idx >= max_visible) break;

        const y = list_top + visual_idx * item_height;
        const entry_idx = self.palette_filtered[i];
        const entry_name = self.paletteEntryName(entry_idx);
        const entry_action = self.paletteEntryAction(entry_idx);

        // Draw selection highlight
        if (i == self.palette_selected) {
            if (w32.CreateSolidBrush(system_colors.cr(p.select))) |sel_brush| {
                const sel_rect = w32.RECT{
                    .left = 0,
                    .top = y,
                    .right = client_rect.right,
                    .bottom = y + item_height,
                };
                _ = w32.FillRect(hdc, &sel_rect, sel_brush);
                _ = w32.DeleteObject(sel_brush);
            }
        }

        // Draw action name
        const text_pad: i32 = @intFromFloat(@round(12.0 * s));
        const text_top_pad: i32 = @intFromFloat(@round(4.0 * s));
        const kb_area: i32 = @intFromFloat(@round(160.0 * s));
        const row_text = if (i == self.palette_selected) p.text_on_select else p.text;
        const row_dim = if (i == self.palette_selected) p.secondary_on_select else p.secondary;
        _ = w32.SetTextColor(hdc, system_colors.cr(row_text));
        var name_rect = w32.RECT{
            .left = text_pad,
            .top = y + text_top_pad,
            .right = client_rect.right - kb_area,
            .bottom = y + item_height,
        };
        var wname_buf: [128]u16 = undefined;
        // User-configured palette titles are arbitrary length; cap to the
        // buffer (N UTF-8 bytes ≤ N UTF-16 units) on a codepoint boundary so
        // a long title truncates instead of overflowing the stack buffer.
        var name_len = @min(entry_name.len, wname_buf.len);
        while (name_len > 0 and entry_name[name_len - 1] & 0xC0 == 0x80) name_len -= 1;
        const wname_len = std.unicode.utf8ToUtf16Le(&wname_buf, entry_name[0..name_len]) catch 0;
        _ = w32.DrawTextW(hdc, @ptrCast(&wname_buf), @intCast(wname_len), &name_rect, 0);

        // Dimmed trailing subtitle (T555): a jump entry's abbreviated cwd,
        // right-aligned in the space after the title — the same dim gray as
        // a keybind hint, and it cannot collide with one because jump
        // entries never carry a keybind. Right-aligned so a clip eats the
        // path's HEAD and the distinguishing tail survives.
        if (self.paletteEntrySubtitle(entry_idx)) |sub| {
            // Measure the painted title so the subtitle starts after it.
            var meas = name_rect;
            _ = w32.DrawTextW(
                hdc,
                @ptrCast(&wname_buf),
                @intCast(wname_len),
                &meas,
                0x0420, // DT_CALCRECT | DT_SINGLELINE
            );
            const gap: i32 = @intFromFloat(@round(12.0 * s));
            var sub_rect = w32.RECT{
                .left = meas.right + gap,
                .top = y + text_top_pad,
                .right = client_rect.right - text_pad,
                .bottom = y + item_height,
            };
            if (sub_rect.left < sub_rect.right) {
                _ = w32.SetTextColor(hdc, system_colors.cr(row_dim));
                var wsub_buf: [tab_tooltip.max_len]u16 = undefined;
                const wsub_len = std.unicode.utf8ToUtf16Le(&wsub_buf, sub) catch 0;
                _ = w32.DrawTextW(
                    hdc,
                    @ptrCast(&wsub_buf),
                    @intCast(wsub_len),
                    &sub_rect,
                    0x0022, // DT_RIGHT | DT_SINGLELINE
                );
                _ = w32.SetTextColor(hdc, system_colors.cr(row_text));
            }
        }

        // Draw keybinding hint on the right
        const trigger = if (entry_action) |a| self.app.config.keybind.set.getTrigger(a) else null;
        if (trigger) |t| {
            _ = w32.SetTextColor(hdc, system_colors.cr(row_dim));
            var kb_buf: [64]u8 = undefined;
            const kb_len = formatTrigger(t, &kb_buf);
            var wkb_buf: [64]u16 = undefined;
            const wkb_len = std.unicode.utf8ToUtf16Le(&wkb_buf, kb_buf[0..kb_len]) catch 0;
            var kb_rect = w32.RECT{
                .left = client_rect.right - kb_area + text_top_pad,
                .top = y + text_top_pad,
                .right = client_rect.right - text_pad,
                .bottom = y + item_height,
            };
            _ = w32.DrawTextW(hdc, @ptrCast(&wkb_buf), @intCast(wkb_len), &kb_rect, 0x0002); // DT_RIGHT
        }
    }
}

/// Format a keybinding trigger for display (e.g. "Ctrl+Shift+T"). The
/// formatter is shared with the menu system (T190) so a chord reads the same
/// in the palette, the context menu, and the menu.
const formatTrigger = menu_label.formatTrigger;

/// Toggle window decorations (title bar + borders) on/off.
/// Delegates to the parent Window.
pub fn toggleWindowDecorations(self: *Surface) void {
    self.parent_window.toggleWindowDecorations();
}

/// Update the themed scrollbar to reflect the terminal's scroll state.
/// Called from performAction(.scrollbar) when the viewport changes.
pub fn setScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    if (self.scrollbar) |sb| sb.update(scrollbar);
}

/// Scroll the terminal to the given absolute row offset.
/// Called by the themed scrollbar during drag / click.
pub fn scrollToOffset(self: *Surface, offset: usize) void {
    if (!self.core_surface_ready) return;
    _ = self.core_surface.performBindingAction(.{ .scroll_to_row = offset }) catch |err| {
        log.err("scrollToOffset error: {}", .{err});
    };
}

// -----------------------------------------------------------------------
// Message handlers called from App.surfaceWndProc
// -----------------------------------------------------------------------

/// Handle WM_SIZE.
pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    // Skip zero-size events (minimized windows).
    if (width == 0 or height == 0) return;

    // T1343: one line of the drag measurement — how many panes a layout pass
    // actually resized, so "no frame waits" can be told apart from "no work".
    self.parent_window.noteResize();

    self.height = height;

    // Pre-flight the scrollbar so we know whether to subtract its width.
    // This must happen before sizeCallback so the grid gets the right width.
    var grid_width = width;
    if (self.scrollbar) |sb| {
        const sub = sb.repositionAndResize();
        if (sub > 0 and grid_width > @as(u32, @intCast(sub))) {
            grid_width -= @as(u32, @intCast(sub));
        }
    }
    self.width = grid_width;

    // Reposition popups with corrected width.
    if (self.search_active) self.positionSearchBar();
    if (self.palette_active) self.positionCommandPalette();

    if (!self.core_surface_ready) return;

    // Notify the core surface so it recalculates the terminal grid,
    // updates the renderer viewport, and sends SIGWINCH to the PTY.
    // T1343: the pane's own share of a motion tick — grid reflow, renderer
    // viewport, PTY SIGWINCH — timed under GHOZTTY_PERF so the drag breakdown
    // names it instead of lumping it into "everything that is not the wait".
    var size_timer = if (self.parent_window.drag_perf_on)
        std.time.Timer.start() catch null
    else
        null;
    self.core_surface.sizeCallback(.{ .width = grid_width, .height = height }) catch |err| {
        log.err("sizeCallback error: {}", .{err});
        return;
    };
    if (size_timer) |*t| self.parent_window.addResizeUs(t.read() / std.time.ns_per_us);

    // During a resize the user is watching, block until the renderer has
    // presented one frame at the new size. This prevents the DWM from
    // stretching stale framebuffer content to fill the new window area, which
    // causes visible flicker.
    //
    // "Watching" is not the same as "dragging the border", which is what this
    // used to test (T1393): maximize, restore, Aero-snap and a title-bar
    // double-click resize the window with no modal size loop, so no
    // `WM_ENTERSIZEMOVE` arrives and `in_live_resize` stays false right
    // through a resize happening in front of the user. `resize_paint` owns the
    // rule now and is unit tested; the pass declaring itself live is what
    // covers the gestures with no loop to be inside of.
    const presented = self.has_presented_frame.load(.acquire);
    if (!presented) self.parent_window.noteFreshPane();
    if (resize_paint.shouldPresentSynchronously(.{
        .in_live_resize = self.in_live_resize,
        .in_live_layout = self.parent_window.in_live_layout,
        .has_presented_frame = presented,
    })) {
        self.parent_window.notePresentSync();
        if (self.frame_event) |event| {
            // Reset the event before waking the renderer, so we
            // wait for a NEW frame, not a previously drawn one.
            _ = w32.ResetEvent(event);
        }

        // Wake the renderer to redraw at the new size.
        self.core_surface.renderer_thread.wakeup.notify() catch {};

        if (self.frame_event) |event| {
            // T1343: hand the event to the layout pass, which waits for every
            // pane at once when it closes. Paid per pane this wait was the
            // whole reason a splitter drag got slower with each split — four
            // panes meant four 16 ms stalls for ONE mouse move. Only a resize
            // with no pass around it (or `GHOZTTY_DRAG_SERIAL_WAIT`, which
            // exists so the two shapes can be measured against each other)
            // falls through to waiting for itself.
            if (!self.parent_window.deferFrameWait(event)) {
                var timer = if (self.parent_window.drag_perf_on)
                    std.time.Timer.start() catch null
                else
                    null;
                const rc = w32.WaitForSingleObject(
                    event,
                    @intCast(drag_perf.frame_wait_ms),
                );
                self.parent_window.addFrameWait(
                    if (timer) |*t| t.read() / std.time.ns_per_us else 0,
                    rc == w32.WAIT_TIMEOUT,
                );
            }
        }
    } else {
        // Outside live resize (programmatic resize, initial layout),
        // just wake the renderer asynchronously.
        self.core_surface.renderer_thread.wakeup.notify() catch {};
    }
}

/// Handle WM_DPICHANGED.
pub fn handleDpiChange(self: *Surface) void {
    self.updateDpiScale();

    // Popup fonts were created at the previous DPI. Rebuild them at
    // the new scale so search-bar / palette text doesn't render
    // tiny/huge after dragging the window between monitors.
    const s = self.scale;
    if (self.search_font) |old| {
        _ = w32.DeleteObject(old);
        self.search_font = null;
    }
    if (self.palette_font) |old| {
        _ = w32.DeleteObject(old);
        self.palette_font = null;
    }
    if (self.palette_paint_font) |old| {
        _ = w32.DeleteObject(old);
        self.palette_paint_font = null;
    }
    if (self.search_edit) |edit| {
        self.search_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(16.0 * s))),
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
        if (self.search_font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
            // The count label shares the search font; re-send it too or the
            // label keeps a handle to the just-deleted HFONT.
            if (self.search_count_label) |label| {
                _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    if (self.palette_edit) |edit| {
        self.palette_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(16.0 * s))),
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
        if (self.palette_font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }

    // Notify the scrollbar of the new DPI.
    if (self.scrollbar) |sb| sb.onDpiChanged(@intFromFloat(self.scale * 96.0));
}

/// Handle WM_KEYDOWN / WM_SYSKEYDOWN / WM_KEYUP / WM_SYSKEYUP.
pub fn handleKeyEvent(self: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    if (!self.core_surface_ready) return;
    const vk: u16 = @intCast(wparam & 0xFFFF);

    // The two synthetic keys the terminal must never be handed: VK_PROCESSKEY
    // (the IME owns the press and delivers its text through
    // WM_IME_COMPOSITION) and VK_PACKET (SendInput KEYEVENTF_UNICODE — screen
    // readers, on-screen keyboards, automation — whose character follows as its
    // own WM_CHAR, since App.run exempts the packet from the TranslateMessage
    // skip, T64). A packet additionally clears the produced-text flag: under
    // that skip an ordinary key never gets a WM_CHAR of its own, so the flag is
    // still stuck from the last text-producing keydown and would eat the
    // injected character. The rules and their reasons live in
    // `translate_policy.zig` alongside App.run's half, and are asserted there
    // (T222) — a real SendInput packet cannot be delivered off the input
    // desktop, so this branch has no automated path of its own.
    const disposition = translate_policy.keyDisposition(vk);
    if (disposition.clearsProducedText()) self.key_event_produced_text = false;
    if (disposition.dropsKey()) return;

    // F10 / a lone Alt press open the menu system (T190). Runs before the
    // key reaches the terminal so the disarm bookkeeping sees every key.
    if (self.trackMenuActivation(vk, lparam, action)) return;

    // ctrl+shift+n → "New Remote Window" (the machine chooser). Handled
    // locally (T22c decision 3): there is no core binding action for "new
    // remote window", so intercept the chord here, BEFORE keyCallback. On
    // Windows this shadows the cross-platform ctrl+shift+n → new_window
    // default (ctrl+n still opens a plain local window). First press only —
    // bit 30 of lparam is the previous key state, set on autorepeat.
    //
    // The chord itself is defined in `window_chord`, not here: a terminal pane
    // is only ONE of the things that can hold this window's keyboard, and when
    // it was spelled out inline a focused viewer pane opened a plain window
    // and a focused top-level window did nothing at all (T746).
    if (action == .press and (lparam & (1 << 30)) == 0) {
        if (window_chord.classify(vk, getModifiers())) |chord| switch (chord) {
            .new_remote_window => {
                log.info("machine chooser: opening via ctrl+shift+n", .{});
                self.parent_window.openMachineChooser();
                return;
            },
        };
    }

    // Determine left/right for modifier keys using the extended key flag
    // (bit 24 of lparam) and specific left/right VK codes.
    const extended = (lparam & (1 << 24)) != 0;

    const key = mapVirtualKey(vk, extended);

    // Build modifier state
    const mods = getModifiers();

    // Win32 Input Mode (mode 9001): encode key events as
    // \x1b[Vk;Sc;Uc;Kd;Cs;Rc_ sequences that ConPTY reconstructs
    // into INPUT_RECORD structs. This provides full Unicode support
    // and bypasses ConPTY codepage issues.
    //
    // We still need to check keybindings first (e.g., Ctrl+Shift+C
    // for copy) so they work in this mode. Only fall through to
    // Win32 input encoding if no binding matched.
    if (self.isWin32InputMode()) {
        // Check keybindings for non-modifier keys (Ctrl+Shift+C, etc.).
        // Modifier-only keys never have bindings, and sending them
        // through keyCallback would clear the selection.
        if (!key.modifier()) {
            const actual_action_w32 = if (action == .press and (lparam & (1 << 30)) != 0)
                input.Action.repeat
            else
                action;
            const unshifted_cp: u21 = if (key.codepoint()) |cp| cp else 0;
            const effect = self.core_surface.keyCallback(.{
                .action = actual_action_w32,
                .key = key,
                .mods = mods,
                .consumed_mods = .{},
                .utf8 = "", // no text — let Win32 input handle it
                .unshifted_codepoint = unshifted_cp,
            }) catch |err| {
                log.err("key callback error: {}", .{err});
                return;
            };
            // If a keybinding consumed the event, don't send Win32 input.
            if (effect == .consumed or effect == .closed) return;
        }

        // No binding matched — send as Win32 input sequence.
        self.sendWin32InputEvent(vk, lparam, action);
        return;
    }

    // Check if the key is a repeat (bit 30 of lparam is set for KEYDOWN
    // if the key was already down).
    const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
        input.Action.repeat
    else
        action;

    // Try to get the unshifted codepoint for this key
    const unshifted_codepoint: u21 = if (key.codepoint()) |cp| cp else 0;

    // Use ToUnicode to translate the key press into UTF-16 text,
    // then convert to UTF-8 for the key event. Only for press/repeat.
    var utf8_buf: [16]u8 = undefined;
    var utf8_text: []const u8 = "";
    var consumed_mods: input.Mods = .{};
    // The modifier set actually encoded into the key event. AltGr handling
    // below may clear ctrl+alt on this copy without disturbing `mods`.
    var event_mods = mods;

    // Reset the flag — WM_CHAR should be allowed through unless
    // ToUnicode produces text below.
    self.key_event_produced_text = false;

    if ((actual_action == .press or actual_action == .repeat) and !isModifierVk(vk)) {
        // App.run skips TranslateMessage for surface keyboard messages, so
        // this ToUnicode call owns the per-queue dead-key state. result>0
        // means composed text (including composition with a previously
        // pending dead key); result<0 means VK is itself a dead key and
        // ToUnicode just stored it for the next call.
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            // Mask to 8 bits — bit 24 of lparam is the extended-key flag,
            // not part of the scancode. Including it broke ToUnicode for
            // AltGr layouts (German, Polish) and arrow/numpad keys.
            const scancode: u32 = @intCast((lparam >> 16) & 0xFF);
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                scancode,
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                const utf16_slice = utf16_buf[0..@intCast(result)];
                // Skip Ctrl-induced control chars (0x01-0x1A): the core
                // handles modifier combos via key + mods, and emitting
                // the control char here would double-encode.
                if (utf16_slice[0] >= 0x20) {
                    // 4 units into 16 bytes is measured; the bounded call
                    // (T990) keeps it measured for whoever edits either.
                    const len = utf16_text.toUtf8Truncating(&utf8_buf, utf16_slice);
                    if (len > 0) {
                        utf8_text = utf8_buf[0..len];
                        if (mods.shift) consumed_mods.shift = true;
                        self.key_event_produced_text = true;
                        // AltGr layouts: Windows reports AltGr as
                        // Left-Ctrl+Right-Alt. When that combination itself
                        // produced printable text (e.g. German AltGr+Q '@',
                        // AltGr+8 '['), strip ctrl+alt from the ENCODED mods.
                        // The core key encoder reads raw event.mods and would
                        // otherwise turn the literal into a C0/CSIu control
                        // sequence. Gate on the right-Alt physically being down
                        // so genuine Ctrl+Alt chords are left untouched.
                        if (mods.ctrl and mods.alt and
                            (keyboard_state[w32.VK_RMENU] & 0x80) != 0)
                        {
                            event_mods.ctrl = false;
                            event_mods.alt = false;
                            consumed_mods.ctrl = true;
                            consumed_mods.alt = true;
                        }
                    }
                }
            }
        }
    }

    const event = input.KeyEvent{
        .action = actual_action,
        .key = key,
        .mods = event_mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_text,
        .unshifted_codepoint = unshifted_codepoint,
    };

    _ = self.core_surface.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
}

/// Handle WM_CHAR — character input after translation.
/// Win32 delivers codepoints > U+FFFF as two WM_CHAR messages
/// containing a UTF-16 surrogate pair (high then low).
///
/// Text is routed through keyCallback (not textCallback!) with
/// key=.unidentified, mirroring how GTK handles IME commits.
/// textCallback is for clipboard paste; keyCallback is for keyboard/IME text.
pub fn handleCharEvent(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const char_code: u16 = @intCast(wparam & 0xFFFF);

    // Skip control characters that are handled via WM_KEYDOWN
    if (char_code < 0x20 and char_code != '\t' and char_code != '\r' and char_code != '\n') return;

    // Handle UTF-16 surrogate pairs for codepoints > U+FFFF (e.g. emoji).
    const codepoint: u21 = if (char_code >= 0xD800 and char_code <= 0xDBFF) {
        // High surrogate — buffer it and wait for the low surrogate.
        self.high_surrogate = char_code;
        return;
    } else if (char_code >= 0xDC00 and char_code <= 0xDFFF) blk: {
        // Low surrogate — combine with buffered high surrogate.
        if (self.high_surrogate != 0) {
            const hi: u21 = self.high_surrogate;
            self.high_surrogate = 0;
            break :blk @intCast((@as(u21, hi - 0xD800) << 10) + (@as(u21, char_code) - 0xDC00) + 0x10000);
        }
        // Low surrogate without preceding high — invalid, skip.
        return;
    } else blk: {
        self.high_surrogate = 0; // Reset any stale high surrogate.
        break :blk @intCast(char_code);
    };

    // Convert codepoint to UTF-8
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return;

    // Send through keyCallback with .unidentified key — this is the
    // standard path for IME/text input (same as GTK's imCommit).
    // keyCallback will encode the utf8 text and write it to the PTY.
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("text input callback error: {}", .{err});
    };
}

/// Remember the client-coordinate cursor position a mouse message carried,
/// so `getCursorPos` has an answer when `GetCursorPos` cannot give one.
/// Mouse-message lparams are SIGNED 16-bit halves: a drag past the left or
/// top edge (with capture held) legitimately reports negative coordinates,
/// so they must be sign-extended, not masked.
pub fn noteCursorFromLparam(self: *Surface, lparam: isize) void {
    self.last_cursor_client = cursorFromLparam(lparam);
}

pub fn cursorFromLparam(lparam: isize) w32.POINT {
    return .{
        .x = @as(i16, @truncate(@as(isize, lparam & 0xFFFF))),
        .y = @as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))),
    };
}

/// Whether a mouse message's point is NEWS to the core (T802).
///
/// `null` — nothing delivered yet this surface — is news, so the very first
/// message always positions the core. An identical point is not: forwarding
/// it again with a button held reads as a zero-distance drag.
pub fn cursorMoved(last: ?w32.POINT, now: w32.POINT) bool {
    const prev = last orelse return true;
    return prev.x != now.x or prev.y != now.y;
}

test "cursorMoved only reports a point the core has not seen" {
    const testing = std.testing;
    const p: w32.POINT = .{ .x = 120, .y = 48 };

    // First message on this surface: nothing to compare against, so deliver.
    try testing.expect(cursorMoved(null, p));

    // The button-up of a double-click carries the press's own point. This is
    // the T802 case: delivering it again is a zero-distance drag that
    // replaces the link the double-click selected with the bare word.
    try testing.expect(!cursorMoved(p, p));

    // Real travel in either axis is still delivered, including the negative
    // coordinates a capture-held drag past the top-left produces.
    try testing.expect(cursorMoved(p, .{ .x = 121, .y = 48 }));
    try testing.expect(cursorMoved(p, .{ .x = 120, .y = 49 }));
    try testing.expect(cursorMoved(p, .{ .x = -5, .y = -10 }));
}

test "viewer_accel.keyFromVk never drifts from mapVirtualKey" {
    // `viewer_accel.zig` cannot import an OS surface, so its VK table is
    // literals. This lane CAN name the `w32.VK_*` constants through
    // `mapVirtualKey`, so the whole 8-bit VK space is the drift guard: a
    // transcription error over there fails here, on the box, every run.
    const viewer_accel = @import("viewer_accel.zig");
    for (0..256) |vk_usize| {
        const vk: u16 = @intCast(vk_usize);
        try std.testing.expectEqual(mapVirtualKey(vk, false), viewer_accel.keyFromVk(vk, false));
        try std.testing.expectEqual(mapVirtualKey(vk, true), viewer_accel.keyFromVk(vk, true));
    }
}

test "cursorFromLparam decodes signed 16-bit halves" {
    const testing = std.testing;
    // Ordinary in-window point.
    var p = cursorFromLparam(@as(isize, (40 << 16) | 10));
    try testing.expectEqual(@as(i32, 10), p.x);
    try testing.expectEqual(@as(i32, 40), p.y);

    // Dragging past the top-left with capture held: both halves are
    // negative, and masking instead of sign-extending would read them as
    // ~65500 and send the selection off to the far corner.
    p = cursorFromLparam(@as(isize, @bitCast(@as(usize, 0xFFF6_FFFB))));
    try testing.expectEqual(@as(i32, -5), p.x);
    try testing.expectEqual(@as(i32, -10), p.y);

    // Right/bottom edge of a wide window stays positive.
    p = cursorFromLparam(@as(isize, (0x7FFF << 16) | 0x7FFF));
    try testing.expectEqual(@as(i32, 32767), p.x);
    try testing.expectEqual(@as(i32, 32767), p.y);
}

/// Handle WM_LBUTTONDOWN / WM_RBUTTONDOWN / WM_MBUTTONDOWN /
/// WM_LBUTTONUP / WM_RBUTTONUP / WM_MBUTTONUP. `wparam` is the mouse
/// message's MK_* modifier word: shift/ctrl come from it (queue-synchronized
/// with the click, and honored for posted/synthetic messages that GetKeyState
/// can never see) while alt/super still come from getModifiers().
pub fn handleMouseButton(
    self: *Surface,
    button: input.MouseButton,
    action: input.MouseButtonState,
    wparam: usize,
    lparam: isize,
) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
    // Read before noteCursorFromLparam overwrites it: the point the core was
    // last told about is what decides whether this message carries news.
    const prev_cursor_client = self.last_cursor_client;
    self.noteCursorFromLparam(lparam);

    var mods = getModifiers();
    mods.shift = (wparam & w32.MK_SHIFT) != 0;
    mods.ctrl = (wparam & w32.MK_CONTROL) != 0;

    // Capture mouse on the first pressed button; release only when all
    // buttons are up. Otherwise a right-click in the middle of a left-
    // button drag clobbers capture, and the next up-event releases it
    // for everyone.
    const bit: u3 = switch (button) {
        .left => 1,
        .right => 2,
        .middle => 4,
        else => 0,
    };
    if (bit != 0) {
        const prev = self.mouse_button_mask;
        if (action == .press) {
            self.mouse_button_mask |= bit;
            if (prev == 0) {
                if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
            }
        } else {
            self.mouse_button_mask &= ~bit;
            if (prev != 0 and self.mouse_button_mask == 0) {
                _ = w32.ReleaseCapture();
            }
        }
    }

    // T240: a right-press that mouse reporting would swallow opens the
    // context menu instead of reaching the terminal application. Every pane
    // the user keeps open is a TUI (Claude Code, vim, lazygit) and they all
    // turn reporting on, so the old `!consumed` gate below made the menu
    // unreachable in practice — the feature read as missing because it was.
    //
    // The decision has to happen BEFORE the core sees the press: once
    // reported, the click is gone to the app and the selection the menu
    // would act on has been cleared. Nothing is synthesized to the core
    // here either — it never saw the press, so there is no click state to
    // unstick, and a lone synthesized release would be REPORTED to the app
    // as a release with no press.
    if (button == .right and
        action == .press and
        self.core_surface.rightPressWouldReport(mods))
    {
        self.showContextMenuUnreported(lparam);
        return;
    }

    // Update cursor position first — but only when this message actually
    // carries a NEW point (T802).
    //
    // Every Windows mouse message carries a client point, and forwarding it
    // ahead of the button is what makes a press land on the right cell when
    // no WM_MOUSEMOVE preceded it (posted input, a pane appearing under a
    // stationary cursor). Re-sending a point the core already has is not
    // free: with a button down the core reads a position update as a DRAG,
    // so the button-up that ends a double-click used to arrive as a
    // zero-distance word-drag and replaced the link the double-click had
    // selected with the bare word under the pointer. macOS never had this —
    // its mouseUp sends no position at all.
    //
    // The core is guarded too (`samePin` in `Surface.zig`); this half keeps
    // the redundant event from being manufactured in the first place.
    if (cursorMoved(prev_cursor_client, cursorFromLparam(lparam))) {
        self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
            log.err("cursor pos callback error: {}", .{err});
        };
    }

    const consumed = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| blk: {
        log.err("mouse button callback error: {}", .{err});
        break :blk true;
    };

    // Unconsumed right-press under the default right-click-action =
    // context-menu: the core has already selected the hovered word/link
    // and returned false, signalling the apprt to show its context menu
    // (same contract the GTK apprt follows).
    if (!consumed and button == .right and action == .press) {
        self.showContextMenu(lparam);
    }
}

/// Show the context menu for a right-press the core never saw (T240: the
/// mouse-reporting bypass). Same capture cleanup as `showContextMenu`, minus
/// the synthesized release — there is no press to balance, and the release
/// would be reported to the application as an orphan.
fn showContextMenuUnreported(self: *Surface, lparam: isize) void {
    self.releaseMouseForMenu();
    self.openContextMenu(
        @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF)))),
        @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF)))),
    );
}

/// The press handler took mouse capture; release it and clear the mask
/// before the modal menu loop, otherwise the pending button-up is captured
/// and immediately dismisses the menu.
fn releaseMouseForMenu(self: *Surface) void {
    if (self.mouse_button_mask != 0) {
        self.mouse_button_mask = 0;
        _ = w32.ReleaseCapture();
    }
}

/// Show the surface right-click context menu at the given client coords
/// (packed in lparam like a mouse message). Press-path entry: cleans up
/// mouse capture and synthesizes the right-button release before the modal
/// menu loop.
fn showContextMenu(self: *Surface, lparam: isize) void {
    self.releaseMouseForMenu();

    // TrackPopupMenuEx's modal loop takes capture and swallows the physical
    // WM_RBUTTONUP, so the core would never see the right-button release and
    // would leave click_state[right] stuck at .press (corrupting later mouse
    // motion). Synthesize the release now.
    _ = self.core_surface.mouseButtonCallback(.release, .right, getModifiers()) catch |err| {
        log.err("mouse button callback error: {}", .{err});
    };

    self.openContextMenu(
        @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF)))),
        @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF)))),
    );
}

/// Classic Windows menu activation for the menu system (T190): **F10** and
/// a **lone Alt press** open the menu at the tab strip's ≡ button. Windows
/// users still reach for both, and neither had any meaning here before.
///
/// Returns true when the key was consumed (F10 only).
///
/// Two deliberate narrowings, because this is a terminal and the child owns
/// the keyboard:
///
///   - **Alt only counts when it is alone.** It arms on a first press with
///     no other modifier held and disarms on any other key, on autorepeat,
///     and on focus loss (alt+tab) — so alt-as-a-modifier, alt+key escape
///     sequences and alt+tab are all untouched. The release is never
///     consumed, so a client reading key releases still sees it.
///   - **F10 yields to full-screen TUIs.** `htop`, `mc` and friends bind F10
///     and they all run on the ALTERNATE screen; a shell prompt does not.
///     So F10 opens the menu on the primary screen only, and is passed
///     through untouched on the alternate one. That is a measurable
///     discriminator rather than a guess about what the child wants.
///   - **F10 yields to a user binding** (T575). A `keybind = f10=…`, a key
///     table whose trigger is F10, or the second half of a sequence all beat
///     the menu: the user stated an intent and the platform default is only a
///     default. Alt is untouched by that rule — see `menu_activation.zig`,
///     which holds the F10 predicate and its tests.
///
/// The menu itself is opened by POSTING to the window (WM_APP_OPEN_MENU),
/// never by tracking a modal popup nested inside this key WndProc.
fn trackMenuActivation(
    self: *Surface,
    vk: u16,
    lparam: isize,
    action: input.Action,
) bool {
    const repeat = (lparam & (1 << 30)) != 0;

    if (vk == w32.VK_MENU) {
        if (action == .press) {
            // Autorepeat means the key is being HELD as a modifier.
            if (repeat) {
                self.alt_menu_armed = false;
                return false;
            }
            const ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
            const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const winkey = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
                w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0;
            self.alt_menu_armed = !ctrl and !shift and !winkey;
            return false;
        }

        // Release: open the menu if nothing intervened, and still deliver
        // the release to the terminal.
        if (self.alt_menu_armed) {
            self.alt_menu_armed = false;
            self.postOpenMenu();
        }
        return false;
    }

    // Any other key ends the "lone" part of a lone Alt.
    self.alt_menu_armed = false;

    if (action != .press or vk != w32.VK_F10) return false;

    const mods = getModifiers();

    // The alternate-screen probe takes the renderer lock and the binding
    // lookup walks the keybind state, so ask the cheap questions first: a
    // modified or repeating F10 is not a menu request and needs neither.
    if (!menu_activation.f10OpensMenu(.{ .mods = mods, .repeat = repeat })) return false;

    if (!menu_activation.f10OpensMenu(.{
        .mods = mods,
        .repeat = repeat,
        .on_alternate_screen = self.onAlternateScreen(),
        // A user binding on F10 wins over the menu (T575). `keyEventIsBinding`
        // is the same lookup `keyCallback` is about to do — the in-flight
        // sequence first, then the active key tables inner-to-outer, then the
        // root set — so an F10 that is the second half of a chord, or a table's
        // trigger, keeps the menu shut exactly as a root binding does.
        .has_binding = self.core_surface.keyEventIsBinding(.{
            .action = .press,
            .key = .f10,
            .mods = mods,
            .consumed_mods = .{},
            .utf8 = "",
            .unshifted_codepoint = 0,
        }) != null,
    })) return false;

    self.postOpenMenu();
    return true;
}

/// Is the terminal showing the alternate screen (i.e. a full-screen TUI is
/// running)?
///
/// PRIORITY (T114), for the same reason `isWin32InputMode` is: this runs on
/// the GUI thread on an F10 keystroke, and the plain mutex can be held by a
/// busy pane's IO/renderer for seconds. Measured with the plain lock: F10
/// right after a zoom, or while a child was flooding output, produced NO
/// menu within 3s and then opened one several seconds later, out of band.
fn onAlternateScreen(self: *Surface) bool {
    if (!self.core_surface_ready) return false;
    self.core_surface.renderer_state.lockPriority();
    defer self.core_surface.renderer_state.unlockPriority();
    return self.core_surface.io.terminal.screens.active_key == .alternate;
}

/// Ask the parent window to open the menu system from its message loop.
fn postOpenMenu(self: *Surface) void {
    const hwnd = self.parent_window.hwnd orelse return;
    _ = w32.PostMessageW(hwnd, Window.WM_APP_OPEN_MENU, 0, 0);
}

/// Keyboard-invoked context menu (WM_CONTEXTMENU: VK_APPS / Shift+F10
/// falling through to DefWindowProc, or automation). Opens at the pane
/// center — there is no click point.
pub fn showContextMenuKeyboard(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    var rc: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rc) == 0) return;
    self.openContextMenu(
        @divTrunc(rc.right - rc.left, 2),
        @divTrunc(rc.bottom - rc.top, 2),
    );
}

/// Build + track the context menu at the given client point and dispatch
/// the chosen command. Items and flags come from the pure context_menu
/// model (Mac surface-menu parity, T102); dispatch goes through the same
/// binding actions as the command palette.
fn openContextMenu(self: *Surface, client_x: i32, client_y: i32) void {
    const hwnd = self.hwnd orelse return;

    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    const items = context_menu.build(.{
        .has_selection = self.core_surface.hasSelection(),
        .readonly = self.core_surface.readonly,
    });
    for (items) |item| switch (item) {
        .separator => _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null),
        .cmd => |c| {
            var flags: u32 = w32.MF_STRING;
            if (!c.enabled) flags |= w32.MF_GRAYED;
            if (c.checked) flags |= w32.MF_CHECKED;
            // AppendMenuW copies the string, so a per-item stack buffer is
            // enough to carry the accelerator label.
            var label: menu_label.Buf = undefined;
            _ = w32.AppendMenuW(
                menu,
                flags,
                @intFromEnum(c.id),
                self.menuLabel(c.id, c.title, &label),
            );
        },
    };

    var pt = w32.POINT{ .x = client_x, .y = client_y };
    _ = w32.ClientToScreen(hwnd, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        hwnd,
        null,
    );

    const id = std.meta.intToEnum(
        context_menu.Id,
        @as(usize, @intCast(cmd)),
    ) catch return; // 0 = dismissed without choosing
    if (id == .bg_color) {
        self.pickBackgroundColor();
        return;
    }
    // Everything else is a binding action, and it is the SAME action the
    // item's accelerator hint was formatted from (context_menu.action).
    const binding = context_menu.action(id) orelse return;
    _ = self.core_surface.performBindingAction(binding) catch |err| {
        log.err("context menu action failed err={}", .{err});
    };
}

/// Menu item text for `id`: the base title, plus a tab and the accelerator
/// when the live keybind set has a trigger for the item's action — the
/// Windows convention, and the app's only self-teaching surface for chords
/// (T129: the pane banner's ctrl+shift+b differs from the Mac cmd+r and was
/// named nowhere, so users concluded the feature was broken). Reading the
/// trigger from config means a rebind relabels the menu, and an unbound
/// action simply shows no hint.
///
/// Returns a pointer into `buf`, or `title` itself when there is no chord.
/// The formatting itself is `menu_label.withAccel`, shared with the menu
/// system (T190) so the two menu surfaces cannot label the same chord
/// differently.
fn menuLabel(
    self: *const Surface,
    id: context_menu.Id,
    title: [:0]const u16,
    buf: *menu_label.Buf,
) [*:0]const u16 {
    const act = context_menu.action(id) orelse return title.ptr;
    return menu_label.withAccel(
        title,
        self.app.config.keybind.set.getTrigger(act),
        buf,
    );
}

/// The pane's effective background: the explicit/inherited tint when set,
/// otherwise the configured terminal background (the Mac's
/// `backgroundTintNSColor ?? derivedConfig.backgroundColor`).
pub fn effectiveBackground(self: *Surface) color_math.Rgb {
    if (self.background_tint) |tint| return tint;
    const bg = self.app.config.background.toTerminalRGB();
    return .{ .r = bg.r, .g = bg.g, .b = bg.b };
}

/// Apply a background tint to the live terminal (T67). Always sets the
/// terminal background; with `adjust_palette` (explicit colors — CLI flag
/// or picker) it also sets a black/white contrast foreground and shifts the
/// ANSI 0–15 palette to keep WCAG 4.5:1 against the new background (the Mac
/// applyColorScheme/applyPaletteForColor). Auto-shifted split inheritance
/// passes false: bg only, default palette untouched (Mac parity — its
/// auto-shift is an overlay that never touches terminal colors).
pub fn applyBackgroundTint(
    self: *Surface,
    rgb: color_math.Rgb,
    adjust_palette: bool,
) void {
    if (!self.core_surface_ready) return;
    self.background_tint = rgb;

    {
        // Terminal color state is shared with the IO thread — mutate under
        // the renderer mutex like every other GUI-thread terminal access.
        //
        // ONE hold for the whole scheme, deliberately: the renderer can
        // draw between two holds, and a frame that has the new background
        // but the old foreground is the unreadable flash T150 exists to
        // remove (Mac `applyBackgroundForColor`).
        self.core_surface.renderer_state.mutex.lock();
        defer self.core_surface.renderer_state.mutex.unlock();
        const t = &self.core_surface.io.terminal;
        t.colors.background.set(.{ .r = rgb.r, .g = rgb.g, .b = rgb.b });
        if (adjust_palette) {
            const s = color_math.scheme(rgb);
            const fg: terminal.color.RGB = .{
                .r = s.foreground.r,
                .g = s.foreground.g,
                .b = s.foreground.b,
            };
            t.colors.foreground.set(fg);
            for (s.palette, 0..) |c, i| {
                t.colors.palette.set(@intCast(i), .{ .r = c.r, .g = c.g, .b = c.b });
            }

            // The base 16 are readable now, but 256-color content — prompt
            // greys from the grayscale ramp, cube colors — still carries
            // the OLD background's lightness, and nothing else ever
            // revisits indices 16–255. Regenerate them from the adjusted
            // base-16 and the new bg/fg; `harmonious` keeps each entry's
            // contrast RELATIVE to the background, which is what lets a
            // dark-theme prompt stay legible when the background goes
            // light (Mac `ghostty_surface_regenerate_palette`).
            const generated = terminal.color.generate256Color(
                t.colors.palette.current,
                .initEmpty(),
                .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
                fg,
                true,
            );
            // Adopt only the cube/ramp — the base 16 were just adjusted.
            @memcpy(t.colors.palette.current[16..], generated[16..]);

            t.flags.dirty.palette = true;
        }
    }

    // Keep the themed scrollbar in tune with the new background.
    if (self.scrollbar) |sb| {
        const fg = self.app.config.foreground.toTerminalRGB();
        sb.setTheme(.{ .r = rgb.r, .g = rgb.g, .b = rgb.b }, fg);
    }

    // Truecolor content is beyond every palette above: a program that
    // emitted `38;2;r;g;b` picked those channels for the background it saw
    // at startup and is never told the background moved. Have the renderer
    // enforce a floor per cell at draw time instead — it clamps upward
    // only, so it can never weaken the user's `minimum-contrast`.
    if (adjust_palette) {
        _ = self.core_surface.renderer_thread.mailbox.push(.{
            .min_contrast = @floatCast(color_math.runtime_min_contrast),
        }, .{ .forever = {} });
    }

    self.core_surface.renderer_thread.wakeup.notify() catch {};
}

/// Context menu "Background Color..." (T67): the common color dialog seeded
/// with the pane's effective background; OK applies the full color scheme
/// (bg + contrast fg + palette), the Windows-native analog of the Mac's
/// NSColorPanel picker.
fn pickBackgroundColor(self: *Surface) void {
    // Dialog custom-color slots persist for the app session (statics — the
    // common dialog expects caller-owned storage).
    const S = struct {
        var custom_colors: [16]u32 = @splat(0x00FFFFFF);
    };
    const current = self.effectiveBackground();
    var cc: w32.CHOOSECOLORW = .{
        .hwndOwner = self.hwnd,
        .rgbResult = colorref(current),
        .lpCustColors = &S.custom_colors,
        .Flags = w32.CC_RGBINIT | w32.CC_FULLOPEN | w32.CC_ANYCOLOR,
    };
    if (w32.ChooseColorW(&cc) == 0) return; // cancelled
    self.applyBackgroundTint(fromColorref(cc.rgbResult), true);
}

/// COLORREF is 0x00BBGGRR.
fn colorref(rgb: color_math.Rgb) u32 {
    return @as(u32, rgb.r) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}

fn fromColorref(cr: u32) color_math.Rgb {
    return .{
        .r = @truncate(cr & 0xFF),
        .g = @truncate((cr >> 8) & 0xFF),
        .b = @truncate((cr >> 16) & 0xFF),
    };
}

/// Handle WM_MOUSEMOVE.
pub fn handleMouseMove(self: *Surface, lparam: isize) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
    self.noteCursorFromLparam(lparam);

    if (self.app.config.@"focus-follows-mouse") self.focusFollowsMouse(lparam);

    // Pass modifiers so the core can detect Ctrl+hover for link highlighting.
    const mods = getModifiers();

    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
}

/// T75: `focus-follows-mouse` — focus the split pane under the pointer on
/// mouse-move (Mac SurfaceView mouseMoved / GTK surface parity).
fn focusFollowsMouse(self: *Surface, lparam: isize) void {
    const hwnd = self.hwnd orelse return;

    // Gate on real pointer motion in SCREEN coordinates: Windows delivers
    // WM_MOUSEMOVE to whatever appears under a stationary cursor (split
    // created/closed, pane shown), and a pane materializing under the
    // mouse must not yank keyboard focus from the pane the user is
    // typing in. Screen coords (not client) so the guard still holds
    // when the message arrives at a DIFFERENT pane than the last one.
    var pt: w32.POINT = .{
        .x = @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF)))),
        .y = @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF)))),
    };
    if (w32.ClientToScreen(hwnd, &pt) == 0) return;
    const moved = if (self.app.ffm_last_screen_pos) |last|
        pt.x != last.x or pt.y != last.y
    else
        // First event since launch: no motion proven — record only.
        false;
    self.app.ffm_last_screen_pos = pt;
    if (!moved) return;

    if (w32.GetFocus() == hwnd) return;

    // Only move focus between panes of the ACTIVE window. Hovering an
    // inactive window must not activate it (Windows convention: hover
    // never raises), and an open popup — command palette, rename /
    // confirm dialog, machine chooser, all separate active windows —
    // must not have its focus stolen by a stray move over the terminal.
    const parent_hwnd = self.parent_window.hwnd orelse return;
    if (w32.GetActiveWindow() != parent_hwnd) return;

    App.deferSetFocus(hwnd); // T48: never SetFocus inside a WndProc
}

/// Handle WM_DROPFILES — a file (or files) was dropped onto this
/// surface. Convert each path to UTF-8, quote if it contains
/// whitespace, and paste into the terminal at the cursor.
pub fn handleDropFiles(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const hdrop: w32.HDROP = @ptrFromInt(wparam);
    defer w32.DragFinish(hdrop);

    // Number of files dropped (passing 0xFFFFFFFF as iFile).
    const count = w32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    if (count == 0) return;

    const alloc = self.app.core_app.alloc;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // First call with NULL gets length (in chars, excluding NUL).
        const u16_len = w32.DragQueryFileW(hdrop, i, null, 0);
        if (u16_len == 0) continue;
        const u16_buf = alloc.alloc(u16, u16_len + 1) catch return;
        defer alloc.free(u16_buf);
        const got = w32.DragQueryFileW(hdrop, i, u16_buf.ptr, @intCast(u16_buf.len));
        if (got == 0) continue;

        // UTF-16 → UTF-8.
        const utf8_buf = alloc.alloc(u8, u16_buf.len * 4) catch return;
        defer alloc.free(utf8_buf);
        // The destination is sized from the source (4 bytes per unit covers
        // the worst case), so nothing truncates here; the bounded call is the
        // house rule rather than a fix (T990).
        const utf8_len = utf16_text.toUtf8Truncating(utf8_buf, u16_buf[0..got]);
        const path = utf8_buf[0..utf8_len];

        if (i > 0) buf.append(alloc, ' ') catch return;
        const needs_quote = std.mem.indexOfAny(u8, path, " \t") != null;
        if (needs_quote) buf.append(alloc, '"') catch return;
        buf.appendSlice(alloc, path) catch return;
        if (needs_quote) buf.append(alloc, '"') catch return;
    }

    if (buf.items.len == 0) return;

    // Send through keyCallback as text so it goes through the same
    // path as IME/clipboard input (PTY-bound, encoding-correct).
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = buf.items,
        .unshifted_codepoint = 0,
    }) catch |err| {
        log.err("drop-files keyCallback: {}", .{err});
    };
}

/// Handle WM_MOUSEWHEEL (vertical) and WM_MOUSEHWHEEL (horizontal).
/// `axis` selects which scroll axis to deliver the delta on.
pub fn handleMouseWheel(self: *Surface, wparam: usize, axis: enum { vertical, horizontal }) void {
    if (!self.core_surface_ready) return;
    // The high word of wparam contains the wheel delta (signed).
    // One detent (WHEEL_DELTA) is one discrete "tick"; the core then
    // applies mouse-scroll-multiplier (discrete default 3), which
    // matches the Windows 3-lines-per-notch convention. Do NOT also
    // apply SPI_GETWHEELSCROLLLINES here — that double-multiplies
    // (verified 9 lines/notch, test/win32/wheel-scroll.ps1).
    const raw_delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));

    // T59b: with hero mode active and the cursor over the owner-painted
    // carousel column, the wheel scrolls the carousel, not the terminal.
    // Fallback path for wheel-follows-focus routing — under the Win10+
    // "scroll inactive windows on hover" default the parent window gets
    // the message directly and this never fires.
    if (axis == .vertical and self.parent_window.heroWheelScreenCursor(raw_delta)) return;

    const delta: f64 = @as(f64, @floatFromInt(raw_delta)) / @as(f64, @floatFromInt(w32.WHEEL_DELTA));

    const scroll_mods: input.ScrollMods = .{};

    // Win32 horizontal wheel positive-right; core API positive-right also.
    const xoff: f64 = if (axis == .horizontal) delta else 0;
    const yoff: f64 = if (axis == .vertical) delta else 0;
    self.core_surface.scrollCallback(xoff, yoff, scroll_mods) catch |err| {
        log.err("scroll callback error: {}", .{err});
    };
}

/// Handle WM_IME_STARTCOMPOSITION — an IME composition session has begun.
/// Position the candidate window near the terminal cursor and let Windows
/// show its default composition UI.
pub fn handleImeStartComposition(self: *Surface) void {
    self.ime_composing = true;
    // Drop any buffered high surrogate so it can't pair with IME output.
    self.high_surrogate = 0;
    self.positionImeWindow();
}

/// Handle WM_IME_ENDCOMPOSITION — the IME composition session has ended.
pub fn handleImeEndComposition(self: *Surface) void {
    self.ime_composing = false;
    // Clear any leftover inline preedit (e.g. composition cancelled with Esc).
    if (self.core_surface_ready) {
        self.core_surface.preeditCallback(null) catch {};
    }
}

/// Handle WM_IME_COMPOSITION — intermediate or final text from the IME.
/// When the result string is available (GCS_RESULTSTR), extract it and
/// send it to the terminal. Returns true if we handled the result string.
pub fn handleImeComposition(self: *Surface, lparam: isize) bool {
    if (!self.core_surface_ready) return false;

    const flags: u32 = @intCast(lparam & 0xFFFFFFFF);

    // Intermediate composition text: mirror it inline at the cursor via the
    // core's preedit (underlined, like macOS/GTK) instead of the default
    // floating composition window (suppressed via WM_IME_SETCONTEXT).
    if (flags & w32.GCS_RESULTSTR == 0) {
        if (flags & w32.GCS_COMPSTR != 0) {
            self.updateImePreedit();
            return true;
        }
        return false;
    }

    // Result string: clear the inline preedit, then commit the text below.
    self.core_surface.preeditCallback(null) catch {};

    const hwnd = self.hwnd orelse return false;
    const himc = w32.ImmGetContext(hwnd) orelse return false;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    // Query the length of the result string (in bytes).
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, null, 0);
    if (byte_len <= 0) return false;
    // The W variant always returns an even byte count, but reject odd
    // values defensively rather than panicking via @divExact.
    if (byte_len & 1 != 0) return false;

    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));

    // Stack buffer for typical IME results (up to 64 UTF-16 code units).
    var stack_buf: [64]u16 = undefined;

    if (u16_len <= stack_buf.len) {
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, &stack_buf, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        self.sendImeText(stack_buf[0..actual_len]);
    } else {
        // Unusual: very long composition. Allocate on the heap.
        const alloc = self.app.core_app.alloc;
        const buf = alloc.alloc(u16, u16_len) catch return false;
        defer alloc.free(buf);
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, buf.ptr, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        self.sendImeText(buf[0..actual_len]);
    }

    // GCS_RESULTSTR and GCS_COMPSTR can arrive together (e.g. an IME commits
    // a syllable while starting the next). We cleared the preedit above for
    // the result; re-mirror the new composition so it isn't invisible until
    // the next keystroke.
    if (flags & w32.GCS_COMPSTR != 0) self.updateImePreedit();

    // Reposition the IME window for the next composition
    self.positionImeWindow();
    return true;
}

/// Convert a UTF-16 IME result to UTF-8 and send it to the terminal.
/// Read the current GCS_COMPSTR composition string and mirror it into the
/// core's preedit so it renders inline at the cursor. An empty composition
/// clears the preedit.
fn updateImePreedit(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    var buf16: [128]u16 = undefined;
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, null, 0);
    if (byte_len <= 0 or byte_len & 1 != 0) {
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));
    if (u16_len > buf16.len) {
        // Absurdly long composition; clear rather than truncate mid-pair.
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const got = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, &buf16, @intCast(byte_len));
    if (got <= 0 or got & 1 != 0) return;
    const n: usize = @intCast(@divTrunc(got, 2));

    // Worst case 3 bytes of UTF-8 per UTF-16 code unit — and the bounded
    // conversion (T990) rather than the sizing comment alone.
    var buf8: [buf16.len * 3]u8 = undefined;
    const len8 = utf16_text.toUtf8Truncating(&buf8, buf16[0..n]);
    self.core_surface.preeditCallback(if (len8 == 0) null else buf8[0..len8]) catch |err| {
        log.warn("preeditCallback failed err={}", .{err});
    };
}

fn sendImeText(self: *Surface, utf16: []const u16) void {
    // In Win32 Input Mode, send each character as a Win32 input event
    // so ConPTY can reconstruct the full Unicode codepoints.
    if (self.isWin32InputMode()) {
        for (utf16) |code_unit| {
            self.sendWin32CharEvent(code_unit);
        }
        return;
    }

    // Convert UTF-16LE to UTF-8 in a stack buffer, IN CHUNKS (T990). The
    // buffer used to be sized by a guess at how much anyone would commit at
    // once ("256 bytes covers even long CJK phrases") and converted with
    // `std.unicode.utf16LeToUtf8`, which does not bounds-check its
    // destination — an 86-character CJK commit, or a paste through the IME,
    // panicked the app instead of typing. Truncating would be the wrong
    // answer here too, since this is the user's actual text and not a search
    // needle, so send as many whole codepoints as fit and continue from where
    // the conversion stopped: the terminal sees the same bytes, just in more
    // than one callback.
    var rest = utf16;
    while (rest.len > 0) {
        var utf8_buf: [256]u8 = undefined;
        const converted = utf16_text.toUtf8Counting(&utf8_buf, rest);
        if (converted.bytes == 0) {
            // A whole codepoint always fits in 256 bytes, so nothing consumed
            // means malformed UTF-16 (a dangling surrogate half). Stop rather
            // than spin.
            log.warn("IME text stopped at malformed UTF-16", .{});
            return;
        }
        rest = rest[converted.units..];

        // Send through keyCallback with .unidentified key — this is the
        // standard path for IME/text input (same as GTK's imCommit).
        _ = self.core_surface.keyCallback(.{
            .action = .press,
            .key = .unidentified,
            .mods = .{},
            .consumed_mods = .{},
            .composing = false,
            .utf8 = utf8_buf[0..converted.bytes],
        }) catch |err| {
            log.err("IME text callback error: {}", .{err});
            return;
        };
    }
}

/// Position the IME candidate/composition window near the terminal cursor.
fn positionImeWindow(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    // Use the core surface's imePoint() which calculates the cursor
    // position in pixels from the terminal grid, accounting for padding
    // and content scale.
    var pos = w32.POINT{ .x = 0, .y = 0 };
    if (self.core_surface_ready) {
        const ime_pos = self.core_surface.imePoint();
        pos.x = @intFromFloat(ime_pos.x);
        pos.y = @intFromFloat(ime_pos.y);
    }

    const cf = w32.COMPOSITIONFORM{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = pos,
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    _ = w32.ImmSetCompositionWindow(himc, &cf);
}

// -----------------------------------------------------------------------
// Win32 Input Mode (mode 9001)
// -----------------------------------------------------------------------

/// Check if Win32 Input Mode is active. This mode is requested by ConPTY
/// via \x1b[?9001h and causes key events to be sent as
/// \x1b[Vk;Sc;Uc;Kd;Cs;Rc_ sequences.
pub fn isWin32InputMode(self: *Surface) bool {
    // PRIORITY (T114): every keystroke asks this on the GUI thread, so a lost
    // race here is felt directly as unresponsive typing into a busy pane.
    self.core_surface.renderer_state.lockPriority();
    defer self.core_surface.renderer_state.unlockPriority();
    return self.core_surface.io.terminal.modes.get(.win32_input);
}

/// Encode and send a key event in Win32 Input Mode format.
/// Format: \x1b[Vk;Sc;Uc;Kd;Cs;Rc_
fn sendWin32InputEvent(self: *Surface, vk: u16, lparam: isize, action: input.Action) void {
    const scancode: u16 = @intCast((lparam >> 16) & 0xFF);
    const extended = (lparam & (1 << 24)) != 0;
    const repeat_count: u16 = @intCast(lparam & 0xFFFF);
    const key_down: u1 = if (action == .press or action == .repeat) 1 else 0;

    // Get the Unicode character for this key via ToUnicode. Skip
    // modifier-only keys: they never produce a character and calling
    // ToUnicode for them is one of the ways the per-thread kernel
    // keyboard state can drift over time.
    var unicode_char: u16 = 0;
    if (key_down == 1 and !isModifierVk(vk)) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                @intCast(scancode),
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                // Composed (or literal) char — possibly produced by
                // combining with a previously-pending dead key. Only the
                // first UTF-16 code unit is captured; supplementary-plane
                // compositions (result == 2, surrogate pair) are truncated
                // to the high surrogate. This is a Win32 Input Mode protocol
                // limitation: the Uc field is 16-bit.
                unicode_char = utf16_buf[0];
            } else if (result < 0) {
                // VK is a dead key. ToUnicode stored it in the queue's
                // dead-key state; the next press's ToUnicode call will
                // compose with it. Send Uc=0 so applications reading the
                // sequence don't see a stray dead char. The state is safe
                // to keep because App.run skips TranslateMessage for
                // surface windows — we are the only consumer.
                unicode_char = 0;
            }
        }
    }

    // Build the Win32 dwControlKeyState bitmask.
    var ctrl_state: u32 = 0;
    if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_LSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0)
        ctrl_state |= 0x0010; // SHIFT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_LCONTROL)) < 0)
        ctrl_state |= 0x0008; // LEFT_CTRL_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0)
        ctrl_state |= 0x0004; // RIGHT_CTRL_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_LMENU)) < 0)
        ctrl_state |= 0x0002; // LEFT_ALT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0)
        ctrl_state |= 0x0001; // RIGHT_ALT_PRESSED
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0)
        ctrl_state |= 0x0080; // CAPSLOCK_ON
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0)
        ctrl_state |= 0x0020; // NUMLOCK_ON
    if (w32.GetKeyState(@as(i32, w32.VK_SCROLL)) & 1 != 0)
        ctrl_state |= 0x0040; // SCROLLLOCK_ON
    if (extended)
        ctrl_state |= 0x0100; // ENHANCED_KEY

    self.writeWin32InputSequence(vk, scancode, unicode_char, key_down, ctrl_state, repeat_count);
}

/// Send a Win32 Input Mode event for a WM_CHAR character (IME, PostMessage, etc.)
/// These are characters without a corresponding WM_KEYDOWN, so we send a
/// synthetic key event with vk=0, sc=0.
pub fn sendWin32CharEvent(self: *Surface, char_code: u16) void {
    // Key-down event with the Unicode character
    self.writeWin32InputSequence(0, 0, char_code, 1, 0, 1);
    // Key-up event
    self.writeWin32InputSequence(0, 0, char_code, 0, 0, 1);
}

/// Format and write a Win32 input sequence directly to the PTY,
/// bypassing keyCallback to avoid side effects (selection clearing,
/// modifier tracking, cursor hiding, etc.).
/// Format: \x1b[Vk;Sc;Uc;Kd;Cs;Rc_
fn writeWin32InputSequence(
    self: *Surface,
    vk: u16,
    sc: u16,
    uc: u16,
    kd: u1,
    cs: u32,
    rc: u16,
) void {
    var buf: [64]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{};{};{};{};{};{}_", .{
        vk, sc, uc, kd, cs, rc,
    }) catch return;

    // Write directly to the PTY via the IO queue.
    const msg = termio.Message.writeReq(
        self.app.core_app.alloc,
        seq,
    ) catch return;
    self.core_surface.io.queueMessage(msg, .unlocked);
}

/// Called by the renderer thread after SwapBuffers to signal that a
/// frame has been presented. Wakes the main thread if it's blocking
/// in handleResize during live resize.
pub fn signalFrameDrawn(self: *Surface) void {
    // Ordered before the event: a thread woken by the event must never see
    // "no frame yet" for a frame that has already been presented (T1031).
    // Load-then-store so the steady state is a relaxed read rather than a
    // cross-thread write on every frame — this runs at the display rate.
    if (!self.has_presented_frame.load(.monotonic)) {
        self.has_presented_frame.store(true, .release);
    }
    if (self.frame_event) |event| {
        _ = w32.SetEvent(event);
    }
}

/// Handle WM_SETFOCUS / WM_KILLFOCUS.
pub fn handleFocus(self: *Surface, focused: bool) void {
    // Focus changes are the other end of a lone Alt: alt+tab takes the alt
    // DOWN here and delivers its UP somewhere else, and the menu must not
    // open when focus comes back (T190). Cleared on both edges, and before
    // the readiness guard so it can never get stuck armed.
    self.alt_menu_armed = false;

    if (!self.core_surface_ready) return;
    // Drop any buffered high surrogate and pending dead key on focus loss —
    // otherwise they would combine with the next character when focus returns.
    if (!focused) {
        self.high_surrogate = 0;
        // Composition messages follow keyboard focus, so a split losing
        // focus mid-composition never gets its own WM_IME_ENDCOMPOSITION.
        // Cancel the composition and clear its inline preedit now.
        if (self.ime_composing) {
            self.ime_composing = false;
            if (self.hwnd) |hwnd| {
                if (w32.ImmGetContext(hwnd)) |himc| {
                    defer _ = w32.ImmReleaseContext(hwnd, himc);
                    _ = w32.ImmNotifyIME(himc, w32.NI_COMPOSITIONSTR, w32.CPS_CANCEL, 0);
                }
            }
            self.core_surface.preeditCallback(null) catch {};
        }
        // Drain any pending dead-key state so an unfinished compose
        // doesn't bleed into the next focused surface or another app.
        var ks: [256]u8 = undefined;
        if (w32.GetKeyboardState(&ks) != 0) {
            var buf: [4]u16 = undefined;
            // 0x39 is the standard scancode for VK_SPACE on all layouts.
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
        }
    }
    self.core_surface.focusCallback(focused) catch |err| {
        log.err("focus callback error: {}", .{err});
    };
}

/// Get the current keyboard modifier state from Win32.
/// Live modifier state, read from the thread's input queue. Public because a
/// pane is not the only thing that answers a keystroke: `Window.wndProc` reads
/// it for the window-scoped chords (T746), and two readers of the same fact
/// spelled two ways is how the sides bits would quietly diverge.
pub fn getModifiers() input.Mods {
    var mods: input.Mods = .{};

    // GetKeyState returns a value where the high bit indicates the key
    // is currently down.
    if (w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0) {
        mods.shift = true;
        // Determine which shift key is pressed
        if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0) {
            mods.sides.shift = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
        mods.ctrl = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0) {
            mods.sides.ctrl = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) {
        mods.alt = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0) {
            mods.sides.alt = .right;
        }
    }

    // Check super (Windows key)
    if (w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0)
    {
        mods.super = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0) {
            mods.sides.super = .right;
        }
    }

    // Lock keys (low bit indicates toggle state)
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0) {
        mods.caps_lock = true;
    }
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0) {
        mods.num_lock = true;
    }

    return mods;
}

/// True for VKs that on their own never produce a character (Shift, Ctrl,
/// Alt, Win, lock keys). Calling ToUnicode for these is wasted at best and
/// can perturb the kernel's per-thread keyboard state at worst (in
/// particular, ToUnicode buffers any pending dead key into kernel state
/// even when the result is unused).
fn isModifierVk(vk: u16) bool {
    return switch (vk) {
        w32.VK_SHIFT,
        w32.VK_LSHIFT,
        w32.VK_RSHIFT,
        w32.VK_CONTROL,
        w32.VK_LCONTROL,
        w32.VK_RCONTROL,
        w32.VK_MENU,
        w32.VK_LMENU,
        w32.VK_RMENU,
        w32.VK_LWIN,
        w32.VK_RWIN,
        w32.VK_CAPITAL,
        w32.VK_NUMLOCK,
        w32.VK_SCROLL,
        => true,
        else => false,
    };
}

/// Map a Win32 virtual key code to a Ghostty input.Key.
fn mapVirtualKey(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        // Letter keys (A-Z: 0x41-0x5A)
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,

        // Number keys (0-9: 0x30-0x39)
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,

        // Function keys
        w32.VK_F1 => .f1,
        w32.VK_F2 => .f2,
        w32.VK_F3 => .f3,
        w32.VK_F4 => .f4,
        w32.VK_F5 => .f5,
        w32.VK_F6 => .f6,
        w32.VK_F7 => .f7,
        w32.VK_F8 => .f8,
        w32.VK_F9 => .f9,
        w32.VK_F10 => .f10,
        w32.VK_F11 => .f11,
        w32.VK_F12 => .f12,
        w32.VK_F13 => .f13,
        w32.VK_F14 => .f14,
        w32.VK_F15 => .f15,
        w32.VK_F16 => .f16,
        w32.VK_F17 => .f17,
        w32.VK_F18 => .f18,
        w32.VK_F19 => .f19,
        w32.VK_F20 => .f20,
        w32.VK_F21 => .f21,
        w32.VK_F22 => .f22,
        w32.VK_F23 => .f23,
        w32.VK_F24 => .f24,

        // Navigation / editing keys
        w32.VK_RETURN => if (extended) .numpad_enter else .enter,
        w32.VK_BACK => .backspace,
        w32.VK_TAB => .tab,
        w32.VK_ESCAPE => .escape,
        w32.VK_SPACE => .space,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_END => .end,
        w32.VK_HOME => .home,
        w32.VK_LEFT => .arrow_left,
        w32.VK_UP => .arrow_up,
        w32.VK_RIGHT => .arrow_right,
        w32.VK_DOWN => .arrow_down,
        w32.VK_INSERT => .insert,
        w32.VK_DELETE => .delete,

        // Modifier keys
        w32.VK_LSHIFT => .shift_left,
        w32.VK_RSHIFT => .shift_right,
        w32.VK_LCONTROL => .control_left,
        w32.VK_RCONTROL => .control_right,
        w32.VK_LMENU => .alt_left,
        w32.VK_RMENU => .alt_right,
        w32.VK_LWIN => .meta_left,
        w32.VK_RWIN => .meta_right,
        w32.VK_SHIFT => if (extended) .shift_right else .shift_left,
        w32.VK_CONTROL => if (extended) .control_right else .control_left,
        w32.VK_MENU => if (extended) .alt_right else .alt_left,

        // Lock keys
        w32.VK_CAPITAL => .caps_lock,
        w32.VK_NUMLOCK => .num_lock,
        w32.VK_SCROLL => .scroll_lock,

        // OEM keys (US keyboard layout)
        w32.VK_OEM_1 => .semicolon,
        w32.VK_OEM_PLUS => .equal,
        w32.VK_OEM_COMMA => .comma,
        w32.VK_OEM_MINUS => .minus,
        w32.VK_OEM_PERIOD => .period,
        w32.VK_OEM_2 => .slash,
        w32.VK_OEM_3 => .backquote,
        w32.VK_OEM_4 => .bracket_left,
        w32.VK_OEM_5 => .backslash,
        w32.VK_OEM_6 => .bracket_right,
        w32.VK_OEM_7 => .quote,

        // Numpad keys
        w32.VK_NUMPAD0 => .numpad_0,
        w32.VK_NUMPAD1 => .numpad_1,
        w32.VK_NUMPAD2 => .numpad_2,
        w32.VK_NUMPAD3 => .numpad_3,
        w32.VK_NUMPAD4 => .numpad_4,
        w32.VK_NUMPAD5 => .numpad_5,
        w32.VK_NUMPAD6 => .numpad_6,
        w32.VK_NUMPAD7 => .numpad_7,
        w32.VK_NUMPAD8 => .numpad_8,
        w32.VK_NUMPAD9 => .numpad_9,
        w32.VK_MULTIPLY => .numpad_multiply,
        w32.VK_ADD => .numpad_add,
        w32.VK_SEPARATOR => .numpad_separator,
        w32.VK_SUBTRACT => .numpad_subtract,
        w32.VK_DECIMAL => .numpad_decimal,
        w32.VK_DIVIDE => .numpad_divide,

        // Misc
        w32.VK_APPS => .context_menu,
        w32.VK_PAUSE => .pause,

        else => .unidentified,
    };
}

/// Return a pointer to the core terminal surface.
pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

/// Returns the remote-machine backend for this surface, or null for a local
/// ConPTY surface (remote-machines design §3.2). `CoreSurface.init` calls
/// this at the single backend-construction site to decide between the
/// `.remote` and `.exec` backends. The connection is borrowed (owned by the
/// parent Window); the cwd/shell slices are borrowed for the duration of
/// the construction call only (`termio.Remote.init` dupes them).
pub fn remoteBackend(self: *Surface) ?CoreSurface.RemoteBackend {
    const conn = self.remote_conn orelse return null;
    return .{
        .connection = conn,
        // Non-null ⇒ ATTACH to this restored session (T89f2); null ⇒ OPEN a
        // fresh one (the T20 new-window / T89d new-pane path). Borrowed for
        // this construction call only (termio.Remote.init dupes it).
        .session_id = self.remote_session_id,
        // LOCAL agent (T89d): inject ghoztty shell integration + per-pane
        // GHOSTTY_* env, pin the session (survives the viewer quitting). The
        // core keys pinned/local/tty-reporting off this flag; a cross-machine
        // window leaves it false (a macOS/other-OS resources path is
        // meaningless there).
        .local_shell_integration = self.remote_is_local_agent,
        // Empty ⇒ null so a stray empty string never forwards a cwd/shell.
        .working_directory = if (self.remote_working_directory) |w|
            (if (w.len > 0) w else null)
        else
            null,
        .shell = if (self.remote_shell) |s|
            (if (s.len > 0) s else null)
        else
            null,
        // WP-D3 (T109). An empty snapshot is treated as none: `termio.Remote`
        // only honors an offset that comes WITH a screen to paint, and passing
        // a bare offset would attach past content nothing ever drew.
        .restore_snapshot = if (self.remote_restore_snapshot) |s|
            (if (s.len > 0) s else null)
        else
            null,
        .restore_offset = self.remote_restore_offset,
        // T422: the restore already put this pane's sticky banner back, so a
        // dead-tombstone ATTACH keeps the notice to its in-stream copy.
        .pane_banner_restored = self.remote_pane_banner_restored,
        // T468: the keep-alive invocation of `--command`, for the LOCAL agent
        // only. An empty argv is treated as none — an OPEN carrying a zero-arg
        // argv would leave the agent nothing to exec at all.
        .command_argv = if (self.remote_is_local_agent)
            (if (self.remote_command_argv) |a| (if (a.len > 0) a else null) else null)
        else
            null,
    };
}

/// Return a reference to the App for use by core code.
pub fn rtApp(self: *Surface) *App {
    return self.app;
}
