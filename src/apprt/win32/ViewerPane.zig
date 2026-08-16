//! A viewer pane: a split-tree leaf that renders CONTENT (a markdown/text
//! file or a website) instead of a terminal. docs/claude/viewers.md's "Viewer Panes"
//! section is the cross-platform contract; this is the win32 half.
//!
//! **The host floor (T373).** The pane owns a `GhozttyViewer` child window and,
//! inside it, an `ICoreWebView2Controller` created asynchronously on the app's
//! ONE shared environment (`webview2.Host`, T372). What lands here is
//! everything that makes a viewer a normal split-tree citizen — bounds,
//! visibility, DPI, focus, dark mode, teardown — plus the native error card it
//! shows when there is no runtime to host. Navigation, the file/web modes, the
//! resource resolver and the IPC constructor are T374/T375/T90e; nothing
//! constructs a viewer from IPC yet.
//!
//! ## Two windows, one pane
//!
//! The pane's own HWND is a plain child window we paint. WebView2 parents its
//! OWN Chromium child windows inside it and paints those itself, so the pane's
//! painting is only ever seen before the controller is up (a background wash)
//! or when it never comes up (the error card). That split is deliberate: the
//! host window exists from the moment the pane does, so the split tree can lay
//! it out, focus it and close it without ever asking whether a browser process
//! happened to start.
//!
//! ## The async chain, and the pane that dies during it
//!
//! Creation is two asynchronous hops — wait for the shared environment, then
//! wait for the controller — and a pane can be closed in the middle of either.
//! Both hops therefore carry a heap-allocated `Pending` token rather than the
//! pane pointer: the pane clears `Pending.pane` on the way out, so a callback
//! that arrives after the pane is gone finds a null and cleans up instead of
//! writing into freed memory. This is the same hazard `Host.drain` guards
//! against from the other side, and it is not theoretical: closing a viewer
//! pane in the first second of its life is exactly what a user does when they
//! open one by mistake.
//!
//! ## DPI
//!
//! `ShouldDetectMonitorScaleChanges` is OFF and the pane pushes
//! `RasterizationScale` itself (T90a design §4). The window already tracks its
//! own DPI and lays panes out in physical pixels under per-monitor-v2, and two
//! sources of truth for scale is how a pane ends up rendering at 1.25 inside
//! bounds computed for 1.0. A child window never receives `WM_DPICHANGED` —
//! the top-level window does — so the scale is re-read from the host window on
//! every bounds sync, which a DPI change always causes.
const ViewerPane = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const iface = @import("webview2_iface.zig");
const webview2 = @import("webview2.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const type_ramp = @import("type_ramp.zig");
const error_card = @import("viewer_error_card.zig");
const bridge = @import("viewer_bridge.zig");
const content = @import("viewer_content.zig");
const viewer_watcher = @import("viewer_watcher.zig");
const viewer_accel = @import("viewer_accel.zig");
const window_chord = @import("window_chord.zig");
const viewer_popup = @import("viewer_popup.zig");
// `inputpkg`, not `input`: `navigateFromAddress` has a parameter named
// `input` and zig refuses the shadow.
const inputpkg = @import("../../input.zig");
const viewer_nav = @import("viewer_nav.zig");
const nav_layout = @import("viewer_nav_layout.zig");
const toc_layout = @import("viewer_toc_layout.zig");
const viewer_prefs = @import("viewer_prefs.zig");
const gdiplus_decode = @import("gdiplus_decode.zig");
const view_arg = @import("../../cli/view_arg.zig");
const ViewerNavBar = @import("ViewerNavBar.zig");
const ViewerFeedbackBar = @import("ViewerFeedbackBar.zig");
const feedback_doc = @import("viewer_feedback_doc.zig");
const feedback_report = @import("viewer_feedback_report.zig");
const feedback_images_mod = @import("viewer_feedback_images.zig");
const ViewerFeedbackSend = @import("ViewerFeedbackSend.zig");
const viewer_worktree = @import("viewer_worktree.zig");
const git_run = @import("git_run.zig");
const ViewerWorktreeProbe = @import("ViewerWorktreeProbe.zig");
const ViewerDiffProbe = @import("ViewerDiffProbe.zig");
const viewer_diff = @import("viewer_diff.zig");
const build_config = @import("../../build_config.zig");
const ViewerTOCPanel = @import("ViewerTOCPanel.zig");
const internal_os = @import("../../os/main.zig");
const pane_id_mod = @import("pane_id.zig");
const DimOverlay = @import("DimOverlay.zig").DimOverlay;
const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.viewer_pane);

/// Window class for a viewer pane's host window. Registered once by
/// `App.init`; the name is what an acceptance script keys off to tell a viewer
/// pane from a terminal one.
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewer");

/// The watcher thread's "your file changed" post (T391).
///
/// `WM_APP` numbers are per-window-class, and this one is delivered to a
/// `GhozttyViewer` host window, whose `wndProc` is the one below — it cannot
/// collide with `App.zig`'s assignments. The number is nonetheless taken clear
/// of that list so a post that lands on the wrong window is obviously wrong
/// rather than plausibly right.
pub const WM_APP_VIEWER_RELOAD: u32 = w32.WM_APP + 20;

/// An app keybind chord the accelerator handler matched (T394), re-posted so
/// the ACTION runs from the message loop rather than from inside the
/// controller's own event callback — `close_surface` tears the controller
/// down, and WebView2 must never be closed from within its own handler. The
/// browser process is synchronously blocked during the `Invoke`, so the
/// handler only decides `Handled` and posts; wparam carries the vkey (low
/// word) and the extended bit (bit 16), lparam the `input.Mods` bits.
pub const WM_APP_VIEWER_ACCEL: u32 = w32.WM_APP + 21;

/// Put the caret in this pane's address field, posted rather than called
/// (T396 "Viewer: Open Browser Pane"): the split that just created the pane
/// queued a deferred SetFocus at it (T48), and a synchronous
/// `focusAddressBar` would be stolen by that queued focus a moment later.
/// Posting orders the caret behind it.
pub const WM_APP_VIEWER_FOCUS_ADDRESS: u32 = w32.WM_APP + 22;

/// The worktree probe's "I have an answer" post (T633). Its worker runs `git`,
/// which is a process spawn on every navigation — far too much to do on the
/// message loop the terminal next door draws on — so the resolution happens on
/// a thread and only its RESULT lands here, on the GUI thread, where the nav
/// bar can be re-laid and repainted.
pub const WM_APP_VIEWER_WORKTREE: u32 = w32.WM_APP + 23;

/// The diff worker's "git has answered" post (T463). A listing is several
/// process spawns and a patch is one more, so only the RESULT lands here, on
/// the GUI thread, where it can be pushed into the page.
pub const WM_APP_VIEWER_DIFF: u32 = w32.WM_APP + 26;

/// The feedback sender's "the report is filed (or is not)" post (T636). Its
/// worker runs `git rev-parse` twice, reads the quoted file and writes the
/// report folder — all blocking work with no business on the message loop the
/// terminal next door draws on — so only its RESULT lands here, on the GUI
/// thread, where the composer can be cleared and the confirmation shown.
pub const WM_APP_VIEWER_FEEDBACK_SENT: u32 = w32.WM_APP + 24;

/// The page called `window.close()` (T163) — Mac's `webViewDidClose`. Posted
/// rather than acted on for exactly the reason `WM_APP_VIEWER_ACCEL` is:
/// closing the pane destroys the controller, and a controller must never be
/// torn down from inside its own event callback (the browser process is
/// synchronously blocked for the length of the `Invoke`).
pub const WM_APP_VIEWER_CLOSE: u32 = w32.WM_APP + 25;

/// How long the "Filed …" confirmation stays up before the composer closes
/// itself, matching Mac's 1.8s: long enough to read, short enough that the
/// pane gives its space back without being asked.
const feedback_close_delay_ms: u32 = 1800;

/// The confirmation's timer id, in the host window's own timer space.
const feedback_close_timer_id: usize = 3;

/// The debounce timer's id, in the host window's own timer space.
const reload_timer_id: usize = 1;

/// The nav chrome's cursor-sampling timer (T159). Polling, not
/// `TrackMouseEvent`: the cursor spends its life over WebView2's own Chromium
/// child windows, so this host window never sees the WM_MOUSEMOVEs a tracking
/// rectangle needs — the same reason Mac watches with an app-local event
/// monitor rather than a tracking area.
const nav_timer_id: usize = 2;

/// The working-tree poll's timer id, in the host window's own timer space
/// (T463).
const diff_timer_id: usize = 4;

/// How often a `git-status:` pane re-checks the working tree, matching Mac's
/// `diffRefreshInterval`.
///
/// A poll rather than a file watcher, because the thing being watched is a
/// whole REPOSITORY: a watcher would have to cover every tracked file, the
/// index and HEAD, and would still miss a `git add` performed in another
/// checkout of the same repo. The page is only redrawn when the file list
/// actually moved, so an idle pane costs one `git diff` and no repaint.
const diff_poll_ms: u32 = 2000;

/// How long the pane waits for the writes to stop before re-reading, matching
/// Mac's 0.1s (`ViewerView.scheduleReload`). An editor's save is several
/// notifications inside a few milliseconds — a truncate, a write, a rename —
/// and re-rendering on the first of them shows the reader a half-written file.
const reload_debounce_ms: u32 = 100;

/// One heading the page reported, with its strings owned by the pane.
/// `viewer_bridge.Heading` is the same thing borrowed from a parse arena; this
/// is the copy that outlives it.
pub const Heading = struct {
    id: []u8,
    text: []u8,
    level: u8,
};

/// How far along the two-hop creation chain this pane is.
pub const State = enum {
    /// No host window yet, or one that has not been asked to start.
    idle,
    /// Waiting on the shared `ICoreWebView2Environment`.
    waiting_env,
    /// The environment is up; waiting on this pane's controller.
    creating,
    /// A live controller, sized and visible.
    ready,
    /// No content will appear; the pane paints the error card.
    failed,
};

/// The child window hosting this viewer's content.
hwnd: ?w32.HWND = null,

/// Owning window. Set at construction, like `Surface.parent_window`.
///
/// Deliberately NOT read by anything on the WebView2 or painting paths: the
/// colors and the scale are copied onto the pane at construction instead, so
/// the host floor can be driven in a unit test against a bare parent HWND
/// without standing up an `App` and a `Window` first.
parent_window: *Window = undefined,

/// This pane's stable, ghoztty-owned identity (T113 contract). Generated at
/// construction so `+list --json` and `--target=<id>` work for viewer panes
/// exactly as they do for terminals.
pane_id: pane_id_mod.Buf = undefined,

/// Current title (file basename, or the document title in web mode). Owned;
/// freed in `deinit`.
title: ?[:0]u8 = null,

/// Where this pane currently IS. docs/claude/viewers.md: `+list --json`'s `url` reports
/// the current location, not the one the pane was opened with. Owned.
location: ?[:0]u8 = null,

/// Where this pane was ORIGINALLY opened, which "home" returns to and which
/// the session manifest persists separately from `location`. Owned.
home_location: ?[:0]u8 = null,

/// The directory this pane was opened FROM — `--working-directory`, which the
/// CLI seeds with the caller's cwd for every `--view=` open
/// (`cli/split.zig:seedViewWorkingDirectory`). Owned; null when nothing said.
///
/// Kept even though nothing on win32 consumes it yet (worktree feedback capture
/// is deferred — design P10): it is the provenance fallback for a pane whose
/// location names no directory of its own, a website or a blank page, so it can
/// never be re-derived later. The manifest persists it (P12) for the same
/// reason it persists `home_location` — a value that cannot be recomputed is
/// exactly the kind that has to be written down.
origin_directory: ?[]u8 = null,

/// Which renderer `location` gets (T90e). Derived from the location on every
/// `navigate`, because a pane can move between a file and the web.
mode: content.Mode = .web,

/// The filesystem path `location` names, for the two file modes; null in web
/// mode. Owned, and kept separately from `location` because the two differ
/// whenever the location is a `file://` URL.
file_path: ?[]u8 = null,

/// The bundled viewer assets directory (`…/share/ghostty/viewer`), resolved
/// once when the pane starts. Owned. Null on an installation whose resources
/// cannot be found — the pane then renders nothing and says so, rather than
/// serving the viewed file's directory as if it were the template.
resources_dir: ?[]u8 = null,

/// Mirrors `Surface.visible`: false while the pane's tab is not selected or
/// the window is minimized.
visible: bool = true,

/// Whether the pane currently holds keyboard focus, so a controller that
/// arrives late still lands focus where the user put it.
focused: bool = false,

state: State = .idle,

/// Whether a navigation has COMPLETED at the current location (Mac's
/// `pageLoaded`). Cleared by every `navigate` and set from
/// `onNavigationCompleted`, so it means "there is a document here to act on"
/// rather than "a controller exists". `+reload` reads it to tell a reload from
/// a first load (T390).
page_loaded: bool = false,

/// Why there will be no content. Set with `.failed`, and the error card's text.
failure: ?webview2.Failure = null,

/// The keyboard (ctrl+plus/minus/0) page-zoom factor for this pane (T161).
/// 1.0 is 100%. In-session only — deliberately NOT persisted, so a restored
/// pane comes back at 100% (Mac's `zoomFactor`, same rule). Independent of
/// pinch / ctrl+wheel, which Chromium tracks itself.
zoom_factor: f64 = 1.0,

/// The live controller, once there is one.
controller: ?*iface.ICoreWebView2Controller = null,

/// The in-flight async chain's token; see the file header. Non-null from the
/// first `start` until `deinit`, whether or not a hop is outstanding — the
/// pane holds one of its two references for its whole life.
pending: ?*Pending = null,

/// Our reference on the `NewWindowRequested` handler, held for the pane's life
/// so the same object can be un-registered — and, more to the point, so there
/// is a named owner for it. The handler holds a token reference of its own,
/// which it gives back when its LAST reference dies (`com.CallbackOwning`), not
/// when this one does.
new_window_handler: ?*NewWindowRequestedHandler = null,

/// Our reference on the `WebMessageReceived` handler, held for the same reason
/// and released the same way (T375).
web_message_handler: ?*WebMessageReceivedHandler = null,

/// Our reference on the `WebResourceRequested` handler (T90e), same rule.
resource_handler: ?*WebResourceRequestedHandler = null,

/// Our reference on the `NavigationCompleted` handler (T90e), same rule.
navigation_handler: ?*NavigationCompletedHandler = null,

/// Our reference on the `NavigationStarting` handler (T392), same rule.
navigation_starting_handler: ?*NavigationStartingHandler = null,

/// Our reference on the `DocumentTitleChanged` handler (T383), same rule.
title_handler: ?*DocumentTitleChangedHandler = null,

/// Our reference on the `AcceleratorKeyPressed` handler (T394), same rule.
accel_handler: ?*AcceleratorKeyPressedHandler = null,

/// Our reference on the `WindowCloseRequested` handler (T163), same rule.
window_close_handler: ?*WindowCloseRequestedHandler = null,

/// The `window.open()` this pane exists to BE, from the moment the popup
/// trampoline builds the window until the pane's controller arrives and is
/// handed to the runtime (T163). Null for every ordinary pane.
///
/// While it is set the pane must NOT navigate itself: WebView2 drives the
/// navigation on the web view it is given, and a `Navigate` of our own would
/// race it and break the opener↔popup relationship. `adoptController` is where
/// the two branches part.
popup: ?*PopupRequest = null,

/// How an adopted popup becomes its own ghoztty window (T163). INSTALLED by
/// `Window.createViewerPane`, and the indirection is the same load-bearing one
/// `open_link_split` documents: `App.createWindow` pulls the whole surface and
/// renderer world into comptime analysis, and this file has unit tests that
/// must compile without it. Null for a bare test pane, which has no app to open
/// a window in — the popup then simply does not open, and `Handled` has already
/// seen to it that nothing else does either.
///
/// Keyed on the PANE rather than on its leaf, unlike `open_link_split`: a popup
/// opens a whole new window, so there is no leaf to open it beside, and a
/// pane_view is exactly what a bare test pane must not have (setting one makes
/// `notifyTitle` dereference an undefined `parent_window`).
open_popup_window: ?*const fn (v: *ViewerPane, open: PopupOpen) void = null,

/// How a page's `window.close()` closes this pane (T163) — Mac's
/// `webViewDidClose`. Same indirection and the same pane-keyed signature as
/// `open_popup_window`, for the same two reasons.
close_from_page: ?*const fn (v: *ViewerPane) void = null,

// --- Hero-mode thumbnail (T397) -------------------------------------------
// A viewer is a full citizen of the hero carousel, so it owes the carousel a
// tile picture the same way a terminal does. The mechanism is the only part
// that differs: a terminal's renderer thread reads its own GL back buffer
// every 150ms, where a viewer has to ask `CapturePreview` for an encoded PNG
// of the whole page and decode it. See `heroSnapRequest` for what that costs
// and why the cadence is not the terminal's.

/// The last decoded thumbnail, sized to the tile. Owned; `DeleteObject`ed by
/// `deinit` and by each replacement.
snap_dib: ?w32.HANDLE = null,
snap_dib_w: i32 = 0,
snap_dib_h: i32 = 0,

/// A capture is outstanding: the runtime owes us exactly one completion, and
/// starting a second would race two decodes onto the same fields. Mac's
/// `HeroCarouselView` guards its `takeSnapshot` the same way.
snap_in_flight: bool = false,

/// The stream the in-flight capture is writing into. Owned by the pane, not
/// by the handler, so a pane that dies mid-capture still releases it.
snap_stream: ?*iface.IStream = null,

/// Tile size the last capture was scaled for, and the moment one was last
/// ASKED for (see `heroSnapRequest` for why the attempt, not the success, is
/// what the refresh floor is measured from).
snap_w: i32 = 0,
snap_h: i32 = 0,
snap_asked_ms: i64 = 0,

/// A newly decoded thumbnail is in `snap_dib` and the tile has not repainted
/// yet — the viewer's half of `Surface.snap_seq != snap_dib_seq`.
snap_dirty: bool = false,

/// Back-pointer to the split-tree leaf that owns this pane, set by
/// `PaneView.createViewer`. It is `Surface.pane_view`'s twin and exists for the
/// same reason: a title change has to name a LEAF to the window, and the pane
/// is what the title arrives at. Null for a pane that is not in a tree — which
/// is every pane in a unit test, and the reason `notifyTitle` is a no-op rather
/// than a dereference there.
pane_view: ?*PaneView = null,

/// How a linked markdown file becomes a viewer split (T392). INSTALLED by
/// `Window.createViewerPane` rather than called into `Window` directly, and
/// the indirection is load-bearing: `newViewerSplitAt` pulls the whole
/// surface/renderer world into comptime analysis, and this file has unit
/// tests — the win32 test binary would then need the OTHER apprt's renderer
/// branch (GTK modules it is never given) just to compile. Null for a bare
/// test pane, which has no tree to split anyway.
open_link_split: ?*const fn (pv: *PaneView, location: []const u8, origin: ?[]const u8) void = null,

/// How a forwarded accelerator chord's ACTION reaches the window (T394).
/// The same load-bearing indirection as `open_link_split`, for the same
/// reason: `performViewerBindingAction` reaches `addTab`/`newSplitAt`/
/// `App.createWindow`, which pull the renderer world into comptime analysis.
/// Null for a bare test pane — a chord then resolves but performs nothing.
perform_accel_action: ?*const fn (pv: *PaneView, action: inputpkg.Binding.Action) void = null,

/// The app's shared environment, kept for the life of the pane because
/// `CreateWebResourceResponse` lives on it and the resource handler needs one
/// per intercepted request. Our own reference; released in `deinit`.
env: ?*iface.ICoreWebView2Environment = null,

/// The document's headings, as the page last reported them. Owned — both the
/// slice and every string in it. This is Mac's `setTOCItems` input; T160 draws
/// the card from it.
headings: []Heading = &.{},

/// The heading the reader is currently in, or null when the page says there is
/// none. Mac's `activeHeadingID`. Owned.
active_heading: ?[]u8 = null,

/// Physical pixels per DIP for this pane's monitor. Re-read from the host
/// window on every bounds sync.
scale: f32 = 1.0,

/// The pane background the host window paints before/instead of content.
/// Copied from the window's config at construction.
bg: color_math.Rgb = .{ .r = 0x28, .g = 0x2C, .b = 0x34 },

/// What the page's `prefers-color-scheme` should say (T90a design §14).
/// `auto` is also the degrade for a runtime too old to have a profile.
color_scheme: iface.PreferredColorScheme = .auto,

/// Live reload (T391): watches `file_path`'s directory and posts
/// `WM_APP_VIEWER_RELOAD` at this pane's host window when the document
/// changes. Idle in web mode, and idle for a pane that has no host window yet
/// — which is the whole of the unit-test population that never opens one.
watcher: viewer_watcher.Watcher = .{},

/// The navigation chrome (T159). Null when its window could not be created —
/// the pane then has no bar, which is a degradation, not a broken pane.
nav: ?*ViewerNavBar = null,

/// Which git worktree this pane's content belongs to, and the machinery that
/// answers that question off the UI thread (T633). Null until the pane has an
/// allocator to hand it — which is every pane before `start`, and every unit
/// test that drives a bare pane.
worktree: ?ViewerWorktreeProbe = null,

/// Everything a `git-status:` / `git-diff:<revspec>` pane asks git for, and the
/// worker that asks off the UI thread (T463). Null on the same terms as
/// `worktree` — a pane with no allocator and no host window runs no git.
diff_probe: ?ViewerDiffProbe = null,

/// Which file of the current diff the page is showing, as an index into the
/// probe's list. Null before the first patch has been asked for.
///
/// Kept as a PATH as well, because a refresh rebuilds the list and the index
/// alone would then name whatever moved into that slot — a file that was
/// staged out from under the reader.
diff_file: ?[]u8 = null,

/// Whether the page has been given a listing since it last loaded. A poll only
/// redraws when the file list MOVED, so without this a freshly-loaded page
/// whose diff has not changed would be handed nothing and stay blank — Mac's
/// `force` flag, for the same case.
diff_pushed: bool = false,

/// The layout the diff page renders in — `unified` or `split`. In-session for
/// now; the controls that change it live in the nav bar, which the win32 diff
/// pane does not have yet (filed separately).
diff_style: []const u8 = "unified",

/// The feedback composer (T634). Created hidden alongside the nav bar, in
/// `ensureNav`, because that is the one place with both halves it needs (a
/// host window to parent it and an allocator to own it) — a WndProc has
/// neither, and this window's own message handlers are where the composer is
/// edited. Null when its window could not be created, which is a degradation
/// (a feedback button that logs its intent) rather than a broken pane.
feedback: ?*ViewerFeedbackBar = null,

/// Whether the composer is open. Ephemeral, like `toc_open` and for the same
/// reason: restoring an open composer would cover the content it is about.
feedback_open: bool = false,

/// The composer's text. On the PANE, not on the bar, because Mac is explicit
/// that contents survive toggling the toolbar closed and open — and on win32
/// the natural mistake is to own the buffer in the child window, where it
/// dies with the window. Owned; freed in `deinit`.
feedback_text: std.ArrayListUnmanaged(u8) = .empty,

/// Every quoted passage the page has sent up, with its referential context
/// (T641). On the pane for the same reason the text is — a quote inserted,
/// the composer closed and reopened, and the report sent has to still carry
/// the quote's heading and block selector.
///
/// Entries are never removed here. Which of them are still IN the report is
/// derived from `feedback_text` on demand (`feedbackQuoteSpans`), which is
/// what makes deleting a block drop its metadata without anything having to
/// notice the deletion.
feedback_quotes: feedback_doc.Registry = .{},

/// Every image pasted into the composer, PNG-encoded (T637). On the pane for
/// the same reason the quotes are, and derived the same way: which of them are
/// still in the report comes from the `[Image #N]` chips still in
/// `feedback_text`, so deleting a chip drops its picture without anything
/// having to be told.
feedback_images: feedback_images_mod.Store = .{},

/// The machinery that files a report off the UI thread (T636), created
/// alongside the probe for the same reason it is: it needs a host window to
/// post its completion at. Null for every pane that never opened one.
feedback_send: ?ViewerFeedbackSend = null,

/// What the composer's footer says instead of its destination — "Filed …" or a
/// failure — set when a send lands and cleared when the composer next opens.
/// Owned; on the PANE rather than the bar because it is the send's result, and
/// the send outlives any one paint.
feedback_status: ?[]u8 = null,

/// What the user currently has SELECTED in the page, tracked by the injected
/// blob's `selection_tracker_js` and read synchronously when a report is filed
/// (see that script's comment for why win32 tracks rather than asks). Owned;
/// null when nothing is selected, which is also its state on a fresh page.
page_selection: ?[]u8 = null,

/// The table-of-contents card (T160). Created lazily the first time a
/// document reports 2+ headings; null before that, and null when its window
/// could not be created (a degradation, not a broken pane).
toc: ?*ViewerTOCPanel = null,

/// Which presentation the card is in right now. `compact` pins the nav bar
/// open (its contents button is the card's only opener).
toc_mode: toc_layout.Mode = .hidden,

/// Whether the compact overlay is toggled open. Deliberately EPHEMERAL — it
/// must not survive a session restore, because restoring an overlay would
/// hide the content it covers (docs/claude/viewers.md's viewer contract).
toc_open: bool = false,

/// The shared card-width preference, DIP. 0 = not loaded yet; read from
/// `viewer_prefs` the first time a card is needed.
toc_width_dip: f32 = 0,

/// The gutter width last pushed to the page (CSS px), so bounds syncs do not
/// spam `setGutter`. -1 forces the next push — set whenever a render has
/// reset the page's own padding.
toc_gutter_css: f32 = 0,

/// Whether the bar is currently revealed. The content inset follows this bit
/// and nothing else, so the bar RESERVES its space (Mac parity: top-of-page
/// content is never covered).
nav_visible: bool = false,

/// When the revealed bar hides, in `GetTickCount64` ms; 0 = nothing armed.
nav_deadline: u64 = 0,

/// The last FILE location this pane rendered, kept across web navigations —
/// it is what Back re-renders when the browser walks history onto the
/// bundled template again (Mac's `fileLocation`, which its `syncMode` reads
/// for exactly this). Owned. Distinct from `file_path`: that one is nulled
/// the moment the pane goes web so the watcher disarms.
file_location: ?[:0]u8 = null,

/// The directory a rendered `.html` page is allowed to read from (T601): the
/// viewed file's OWN directory, recursively, and nothing above it. Owned; null
/// in every other mode.
///
/// PINNED when the pane enters html mode, not re-derived per navigation. A
/// local site whose index links into `docs/` navigates the pane to
/// `docs/page.html`, and re-deriving the root from the new file would move the
/// grant down with it — the page's own `../style.css` would then be an escape
/// out of a root it defined, and a link back up would 404. Mac's grant has the
/// same shape for the same reason: it is passed once, to `loadFileURL`.
html_root: ?[]u8 = null,

/// The page-host URL `html_root`'s current file is served at, derived once per
/// navigation. Owned; null in every other mode.
///
/// Stored rather than rebuilt because `applyNavigation` has no allocator — it
/// runs from the reload path and from controller adoption as well as from
/// `navigate`, and a navigation target it could fail to build is a pane that
/// silently shows nothing.
html_url: ?[:0]u8 = null,

/// Whether the html pane is showing the TEMPLATE's error card instead of its
/// page, because the file could not be read when the navigation was issued
/// (T601). Cleared by every navigation that finds the file again.
///
/// A missing file is the one case where an html pane loads the template: our
/// resource handler would answer 404 and Chromium would paint its own
/// can't-be-reached page, which says nothing about which file or why. Mac gets
/// its card from `renderFileContent` for the same reason.
html_fallback: bool = false,

/// History availability as of the last `HistoryChanged`. Mirrored onto the
/// bar; read directly by the live test.
can_go_back: bool = false,
can_go_forward: bool = false,

/// Our references on the T159 event handlers, same rule as the others.
source_handler: ?*SourceChangedHandler = null,
history_handler: ?*HistoryChangedHandler = null,

/// The module instance the host window was created with, kept so the nav bar
/// can be created from whichever of the two setup calls runs second.
hinstance: ?w32.HINSTANCE = null,

/// Unfocused-split dim overlay (T380): the same T74 layered popup a terminal
/// pane shows, owned by the host window. Created lazily on first show, so a
/// pane that is never part of a split never pays for one.
dim_overlay: ?*DimOverlay = null,

// -------------------------------------------------------------------------
// Construction
// -------------------------------------------------------------------------

/// Allocate and initialize a viewer pane. The caller owns the returned
/// pointer until it is handed to a `PaneView`.
pub fn create(alloc: Allocator, parent: *Window) Allocator.Error!*ViewerPane {
    const self = try alloc.create(ViewerPane);
    self.* = .{ .parent_window = parent };
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    _ = pane_id_mod.format(&self.pane_id, bytes);

    // Snapshot what the paint and WebView2 paths need, so neither has to reach
    // back through `parent_window` (see that field's comment).
    self.scale = parent.scale;
    const c = parent.app.config.background;
    self.bg = .{ .r = c.r, .g = c.g, .b = c.b };
    // Seed the scheme from the OS now rather than waiting for the next
    // `reportColorScheme`: a pane created between two OS theme changes would
    // otherwise sit on AUTO, which is nearly right and not the same thing.
    self.color_scheme = if (Window.systemColorScheme() == .dark) .dark else .light;
    return self;
}

pub fn deinit(self: *ViewerPane, alloc: Allocator) void {
    // Before anything else: the watcher owns a THREAD that posts at this pane's
    // host window, and `stop` joins it. Every teardown below — the host window,
    // `file_path` — is something that thread's message would arrive at.
    self.watcher.stop();
    // The hero thumbnail's stream and DIB, before the token below goes dead:
    // an in-flight capture's completion handler reads them THROUGH the token,
    // so clearing them first is what makes the null-pane check sufficient.
    self.deinitHeroSnap();
    // Drop out of any in-flight callback FIRST: a controller that completes
    // after this point must find a dead token, not a half-freed pane. The
    // token itself outlives this call — every handler that borrowed it holds a
    // reference — so a late EVENT reads a null pane rather than freed memory.
    if (self.pending) |p| {
        p.pane = null;
        p.release();
        self.pending = null;
    }
    if (self.controller) |c| {
        // `Close` is what tears down the browser-side view; releasing without
        // it leaks a renderer process for the life of the app.
        c.close();
        c.release();
        self.controller = null;
    }
    if (self.new_window_handler) |h| {
        h.release();
        self.new_window_handler = null;
    }
    if (self.web_message_handler) |h| {
        h.release();
        self.web_message_handler = null;
    }
    if (self.resource_handler) |h| {
        h.release();
        self.resource_handler = null;
    }
    if (self.navigation_handler) |h| {
        h.release();
        self.navigation_handler = null;
    }
    if (self.navigation_starting_handler) |h| {
        h.release();
        self.navigation_starting_handler = null;
    }
    if (self.title_handler) |h| {
        h.release();
        self.title_handler = null;
    }
    if (self.accel_handler) |h| {
        h.release();
        self.accel_handler = null;
    }
    if (self.window_close_handler) |h| {
        h.release();
        self.window_close_handler = null;
    }
    // A pane that dies before its controller arrives still owes the opening
    // script an answer (T163). Releasing the last reference here is what turns
    // its `window.open()` into a null return instead of a permanent wait.
    if (self.popup) |req| {
        req.release();
        self.popup = null;
    }
    if (self.source_handler) |h| {
        h.release();
        self.source_handler = null;
    }
    if (self.history_handler) |h| {
        h.release();
        self.history_handler = null;
    }
    if (self.env) |e| {
        e.release();
        self.env = null;
    }
    self.clearHeadings(alloc);
    // The TOC panel after clearHeadings (whose hook just emptied its
    // borrowed rows) and before the host window, for the nav bar's reason.
    if (self.toc) |panel| {
        panel.destroy();
        self.toc = null;
    }
    // The bar before the host window: it is the host's child, and destroying
    // it while its back-pointers are intact is the ordered half of the pair
    // (DestroyWindow(host) would take it down as an anonymous child).
    if (self.nav) |nav| {
        nav.destroy();
        self.nav = null;
    }
    // The composer is the bar's sibling, so it goes on the same terms — and
    // its TEXT is the pane's, so it is freed here rather than with the window
    // that renders it (T634: the buffer must outlive the chrome).
    if (self.feedback) |bar| {
        bar.destroy();
        self.feedback = null;
    }
    self.feedback_text.deinit(alloc);
    self.feedback_quotes.deinit(alloc);
    self.feedback_images.deinit(alloc);
    self.feedback_open = false;
    if (self.feedback_status) |s| alloc.free(s);
    self.feedback_status = null;
    if (self.page_selection) |s| alloc.free(s);
    self.page_selection = null;
    // After the bar (which reads the probe's answer) and before the host
    // window: `deinit` JOINS the worker, and a completion posted in the
    // meantime is dropped with the window it was addressed to. The feedback
    // sender is joined on the same terms — a pane can be closed while `git` is
    // still starting up for a report that was already staged.
    if (self.worktree) |*probe| {
        probe.deinit();
        self.worktree = null;
    }
    if (self.feedback_send) |*sender| {
        sender.deinit();
        self.feedback_send = null;
    }
    // Same ordering, same reason (T463): `deinit` JOINS whatever git worker is
    // out, and its completion post dies with the window it was addressed to.
    if (self.diff_probe) |*probe| {
        probe.deinit();
        self.diff_probe = null;
    }
    if (self.diff_file) |f| alloc.free(f);
    self.diff_file = null;
    // Destroy the dim overlay before the host window (its owner) is gone —
    // the same ordering Surface.deinit keeps for its own (T380).
    if (self.dim_overlay) |d| {
        d.destroy();
        self.dim_overlay = null;
    }
    if (self.hwnd) |h| {
        _ = w32.SetWindowLongPtrW(h, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(h);
        self.hwnd = null;
    }
    if (self.title) |t| alloc.free(t);
    if (self.location) |l| alloc.free(l);
    if (self.home_location) |l| alloc.free(l);
    if (self.origin_directory) |d| alloc.free(d);
    if (self.file_path) |p| alloc.free(p);
    if (self.file_location) |l| alloc.free(l);
    if (self.resources_dir) |d| alloc.free(d);
    if (self.html_root) |d| alloc.free(d);
    if (self.html_url) |u| alloc.free(u);
    self.title = null;
    self.location = null;
    self.home_location = null;
    self.origin_directory = null;
    self.file_path = null;
    self.file_location = null;
    self.resources_dir = null;
    self.html_root = null;
    self.html_url = null;
    self.html_fallback = false;
    self.state = .idle;
}

/// This pane's stable id (T113).
pub fn paneId(self: *const ViewerPane) []const u8 {
    return &self.pane_id;
}

/// Replace the pane title and push it up the T92 chain — pane → tab label →
/// titlebar — which is the same chain `Surface.setTitle` drives for a terminal.
/// Dupes; the pane owns the copy.
///
/// An unchanged title returns early rather than re-notifying: a website fires
/// `DocumentTitleChanged` more than once for one page, and each notification
/// walks the tab strip and repaints it.
pub fn setTitle(self: *ViewerPane, alloc: Allocator, value: []const u8) Allocator.Error!void {
    if (self.title) |t| if (std.mem.eql(u8, t, value)) return;
    const dup = try alloc.dupeZ(u8, value);
    if (self.title) |t| alloc.free(t);
    self.title = dup;
    self.notifyTitle();
}

/// Tell the owning window this pane's title changed. A no-op for a pane that is
/// not in a split tree yet (every pane under unit test, and a pane between
/// `create` and the tree taking it).
fn notifyTitle(self: *ViewerPane) void {
    const pv = self.pane_view orelse return;
    const t = self.title orelse return;
    self.parent_window.onPaneTitleChanged(pv, t);
}

// -------------------------------------------------------------------------
// Host window
// -------------------------------------------------------------------------

/// Register the viewer host window class. Called once from `App.init`;
/// returns the atom, or 0 on failure (which `App` treats as fatal, like the
/// other two classes).
pub fn registerClass(hinstance: ?w32.HINSTANCE) u16 {
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // The card is centered, so every resize has to repaint the whole
        // client area, not just the newly exposed strip.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        // No class background brush: every pixel is painted in WM_PAINT from
        // the pane's own background color, which is the terminal's, not a
        // system color.
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    return w32.RegisterClassExW(&wc);
}

/// Create the host window as a child of `parent_hwnd` at `rect`.
///
/// Takes primitives rather than reading `parent_window` so the whole host
/// floor is drivable from a test against a bare parent window.
pub fn createHostWindow(
    self: *ViewerPane,
    hinstance: ?w32.HINSTANCE,
    parent_hwnd: w32.HWND,
    rect: w32.RECT,
) !void {
    std.debug.assert(self.hwnd == null);
    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        // WS_CLIPCHILDREN: WebView2 parents its own Chromium windows inside
        // this one, and painting the background over them is a flicker the
        // user reads as a flash on every resize.
        //
        // WS_VISIBLE because the pane is born `visible = true` and
        // `setVisible` is a no-op for a value it already holds — a host window
        // created hidden would depend on a layout pass to appear, which is a
        // second source of truth for the same bit. `Surface.init` shows its
        // child window for the same reason.
        w32.WS_CHILD | w32.WS_CLIPCHILDREN | w32.WS_VISIBLE_STYLE,
        rect.left,
        rect.top,
        @max(rect.right - rect.left, 1),
        @max(rect.bottom - rect.top, 1),
        parent_hwnd,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    self.hinstance = hinstance;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.readScale();

    // The nav chrome's hover poll (T159): samples the cursor for the reveal
    // strip. Runs for the pane's whole life — 150ms of GetCursorPos is noise,
    // and a timer that starts and stops with visibility is two more states
    // that can disagree.
    if (self.pending) |p| self.ensureNav(p.alloc, hinstance, hwnd);
    _ = w32.SetTimer(hwnd, nav_timer_id, nav_layout.poll_ms, null);
}

/// Create the nav bar once both halves exist: the host window to parent it
/// and an allocator to own it. Called from whichever of `createHostWindow` /
/// `start` runs second — the two orders are both live (PaneView starts the
/// async chain after the window; the unit tests too, but nothing enforces it).
fn ensureNav(self: *ViewerPane, alloc: Allocator, hinstance: ?w32.HINSTANCE, hwnd: w32.HWND) void {
    if (self.nav != null) return;
    self.nav = ViewerNavBar.create(alloc, self, hinstance, hwnd);
    if (self.nav == null) log.warn("viewer nav bar could not be created; pane has no chrome", .{});
    self.pushAddress();
    // The worktree probe needs the same two halves and lands with the bar it
    // puts a button on. Its first resolution runs for wherever `navigate`
    // already put the pane, which is normally before either half exists.
    if (self.worktree == null) {
        self.worktree = ViewerWorktreeProbe.init(alloc);
        self.worktree.?.attach(hwnd, WM_APP_VIEWER_WORKTREE);
        self.refreshWorktree();
    }
    // ...and so does the report writer (T636), which posts its own completion
    // at this same window.
    if (self.feedback_send == null) {
        self.feedback_send = ViewerFeedbackSend.init(alloc);
        self.feedback_send.?.attach(hwnd, WM_APP_VIEWER_FEEDBACK_SENT);
    }
    // ...and so does the diff loader (T463). Its first listing is asked for by
    // the page-ready call rather than here, because a listing pushed before the
    // template exists has nowhere to land.
    if (self.diff_probe == null) {
        self.diff_probe = ViewerDiffProbe.init(alloc);
        self.diff_probe.?.attach(hwnd, WM_APP_VIEWER_DIFF);
        self.syncDiffPoll();
    }
    // The composer (T634) needs the same two halves, and it is built HERE
    // rather than on first open for one concrete reason: it edits itself from
    // its own WndProc, which has no allocator to reach for. Hidden until the
    // feedback button opens it, so a pane that never files anything pays for
    // one 0x0 child window and nothing else.
    if (self.feedback == null) {
        self.feedback = ViewerFeedbackBar.create(alloc, self, hinstance, hwnd);
        if (self.feedback == null) {
            log.warn("viewer feedback composer could not be created", .{});
        }
    }
}

/// Re-derive which worktree this pane's content belongs to, and move the nav
/// bar's feedback button to match.
///
/// Called on EVERY location change rather than once at construction: a pane
/// moves between a file, a dev server and a remote site over its life, and each
/// is a different worktree or none (docs/claude/viewers.md's provenance rule). A resolution
/// that is already cached lands synchronously here; anything else arrives later
/// on `WM_APP_VIEWER_WORKTREE`.
fn refreshWorktree(self: *ViewerPane) void {
    const probe = if (self.worktree) |*p| p else return;
    if (probe.refresh(self.location orelse "", self.origin_directory) != .pending) {
        self.pushWorktree();
    }
}

/// A resolution settled: push it at the bar, and say so in the log.
///
/// A change in the button's PRESENCE re-lays the strip (the address field's
/// width moved with it); a change of destination alone only repaints and
/// re-labels, which the bar does itself.
///
/// The log line is the acceptance script's only oracle: the bar is native
/// owner-painted chrome inside a background test desktop, where nothing can
/// screenshot it, so "the button is there and points at this worktree" has to
/// be readable in the GUI's own stderr.
fn pushWorktree(self: *ViewerPane) void {
    const probe = if (self.worktree) |*p| p else return;
    const root = probe.worktreePath();
    log.info("viewer worktree pane={s} feedback={s} worktree={s}", .{
        self.paneId(),
        if (root != null) "shown" else "hidden",
        root orelse "<none>",
    });
    // A pane that navigated out of every working tree has nowhere left to
    // file, so an open composer closes with the button that opened it. The
    // TEXT survives — the user may navigate straight back — and closing is
    // what keeps the composer from being a form with no destination.
    if (root == null and self.feedback_open) self.setFeedbackOpen(false);
    const nav = self.nav orelse return;
    if (nav.setWorktree(root) and self.nav_visible) self.syncBounds();
}

/// The worktree the composer would file into, or null when this pane's
/// content belongs to no working tree. The same answer the nav bar gates its
/// button on, so the button and the composer's footer cannot disagree.
pub fn feedbackWorktree(self: *ViewerPane) ?[]const u8 {
    const probe = if (self.worktree) |*p| p else return null;
    return probe.worktreePath();
}

/// The feedback button was clicked (T633's affordance, T634's composer).
pub fn toggleFeedback(self: *ViewerPane) void {
    self.setFeedbackOpen(!self.feedback_open);
}

/// Open or close the composer (Mac's `setFeedbackOpen`).
///
/// Opening is gated on a worktree for the same reason the button is: with
/// nowhere to file, a composer is a lie. Closing hands focus back to the page
/// so the pane is usable again, and never touches the text — a composer
/// closed and reopened comes back with the half-written report in it.
pub fn setFeedbackOpen(self: *ViewerPane, open: bool) void {
    if (self.feedback_open == open) return;
    const root = self.feedbackWorktree();
    if (open and root == null) return;

    // Whatever the composer does next, it is not "close yourself in a moment
    // because a report was just filed". A timer left armed across a manual
    // close would fire into a composer the user had since REOPENED and shut it
    // under them (T636).
    if (self.hwnd) |h| _ = w32.KillTimer(h, feedback_close_timer_id);

    if (open) {
        const bar = self.feedback orelse {
            log.warn("viewer feedback composer could not be created", .{});
            return;
        };
        self.feedback_open = true;
        // A "Filed …" line from the last report is not true of this one, and a
        // confirmation still on screen while a fresh report is being typed is
        // the footer lying about where the text will go. (Only a pane with a
        // `pending` can have set a status in the first place — every path that
        // sets one goes through its allocator.)
        if (self.pending) |p| self.setFeedbackStatus(p.alloc, "");
        // The composer's only close affordance is the button that opened it,
        // so the nav bar has to stop auto-hiding while it is open — the same
        // reason the compact TOC layout pins it.
        if (!self.nav_visible) self.setNavVisible(true);
        // Placed BEFORE it is shown: `place` is what gives the window its
        // size, its position and its fonts, and a window shown at 0x0 with no
        // scale would take one paint pass to become itself.
        self.syncBounds();
        // Seeded BEFORE it is shown, so a reopened composer never flashes
        // empty on its way back to the half-written report it holds.
        bar.seedControl();
        bar.setVisible(true);
        bar.takeFocus();
    } else {
        self.feedback_open = false;
        if (self.feedback) |bar| {
            // Hand focus back to the content before hiding: a hidden window
            // holding focus leaves the pane with no keyboard at all.
            if (bar.hasFocus()) self.focus();
            bar.setVisible(false);
        }
        self.syncBounds();
        // The bar was pinned open by the composer; give it back its ordinary
        // auto-hide deadline rather than leaving it open forever.
        self.nav_deadline = w32.GetTickCount64() + nav_layout.hide_delay_ms;
    }

    // The acceptance script's oracle, and the same shape T633's line has:
    // native owner-painted chrome inside a background test desktop cannot be
    // screenshotted, so the pane states what it did in its own stderr.
    log.info("viewer feedback pane={s} open={} bar_h={d} worktree={s}", .{
        self.paneId(),
        self.feedback_open,
        self.feedbackBarHeight(),
        root orelse "<none>",
    });
}

/// The band the composer currently reserves above the page, 0 when closed.
fn feedbackBarHeight(self: *ViewerPane) i32 {
    if (!self.feedback_open) return 0;
    const bar = self.feedback orelse return 0;
    const h = self.hwnd orelse return 0;
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(h, &r) == 0) return 0;
    return bar.barHeight(@max(r.right - r.left, 0), self.scale);
}

/// File the composed report into the detected worktree's queue (T636).
///
/// Everything that blocks — two `git rev-parse` spawns, reading the quoted
/// file, writing the folder — happens on `ViewerFeedbackSend`'s worker; this
/// only snapshots what the user composed and hands it over. The composer keeps
/// its text until the write actually lands, so a failed send leaves the report
/// in the box rather than swallowing it.
pub fn sendFeedback(self: *ViewerPane, alloc: Allocator) void {
    const root = self.feedbackWorktree() orelse {
        self.setFeedbackStatus(alloc, "No worktree — nowhere to file this");
        return;
    };
    const sender = if (self.feedback_send) |*s| s else return;
    // A second press while the first send is out must not file twice.
    if (sender.busy()) return;

    // The quotes still in the text, and the metadata each one carries. Derived,
    // never tallied: a block the user deleted is simply not in `spans`.
    const spans = self.feedbackQuoteSpans(alloc) orelse &.{};
    defer if (spans.len != 0) alloc.free(spans);

    // The images still chipped into the text, and the entries they name.
    // Derived exactly like the quotes, from the same buffer.
    const image_spans = self.feedback_images.live(alloc, self.feedback_text.items) catch &.{};
    defer if (image_spans.len != 0) alloc.free(image_spans);

    var images = alloc.alloc(feedback_report.Image, image_spans.len) catch {
        self.setFeedbackStatus(alloc, "Could not file this report (out of memory)");
        return;
    };
    defer alloc.free(images);
    var numbers = alloc.alloc(u32, image_spans.len) catch {
        self.setFeedbackStatus(alloc, "Could not file this report (out of memory)");
        return;
    };
    defer alloc.free(numbers);
    for (image_spans, 0..) |s, i| {
        const e = self.feedback_images.entries.items[s.index];
        images[i] = .{
            .number = e.number,
            .png = e.png,
            .pixel_width = e.pixel_width,
            .pixel_height = e.pixel_height,
        };
        numbers[i] = e.number;
    }

    const quoted = feedback_report.renderBody(alloc, self.feedback_text.items, spans) catch {
        self.setFeedbackStatus(alloc, "Could not file this report (out of memory)");
        return;
    };
    defer alloc.free(quoted);
    // Chips become markdown image references LAST, over the rendered body:
    // `renderBody` has already moved every offset by adding `> ` and trimming,
    // and the links are re-found by text rather than placed by offset.
    const body = feedback_images_mod.renderLinks(alloc, quoted, numbers) catch {
        self.setFeedbackStatus(alloc, "Could not file this report (out of memory)");
        return;
    };
    defer alloc.free(body);
    // A report that is nothing but a picture is still a report.
    if (images.len == 0 and std.mem.trim(u8, body, " \t\r\n").len == 0) return;

    var quotes = alloc.alloc(feedback_report.Quote, spans.len) catch {
        self.setFeedbackStatus(alloc, "Could not file this report (out of memory)");
        return;
    };
    defer alloc.free(quotes);
    for (spans, 0..) |s, i| {
        const e = self.feedback_quotes.entries.items[s.index];
        quotes[i] = .{
            .number = e.id,
            .text = e.text,
            .heading_id = e.heading_id,
            .heading_text = e.heading_text,
            .block_selector = e.block_selector,
            .block_text = e.block_text,
            .offset_in_block = e.offset_in_block,
            .document_offset = e.document_offset,
        };
    }

    var viewport_buf: [32]u8 = undefined;
    const viewport = self.viewportText(&viewport_buf);

    const started = sender.begin(.{
        .worktree_path = root,
        .worktree_name = viewer_worktree.worktreeName(root),
        .location = self.location orelse "",
        .kind = if (self.mode == .web) "web" else "file",
        .file_path = self.file_path,
        .page_title = self.title,
        .selection = self.page_selection,
        // Absent rather than a row of NULs when the pane was built without one
        // — every pane the app makes has an id, and a report is not the place
        // to discover that a test double did not.
        .pane_id = if (pane_id_mod.isValid(self.paneId())) self.paneId() else null,
        .viewport = viewport,
        .app_version = build_config.version_string,
        .body = body,
        .quotes = quotes,
        .images = images,
        .epoch_secs = @intCast(@max(std.time.timestamp(), 0)),
        // Only has to break a tie inside one second; the timestamp separates
        // everything else.
        .suffix = std.crypto.random.int(u24),
    });
    if (!started) {
        self.setFeedbackStatus(alloc, "Could not file this report");
        return;
    }

    // The acceptance oracle, and the same shape the rest of this chrome logs:
    // owner-painted chrome inside a background test desktop cannot be
    // screenshotted, so the pane states what it did in its own stderr.
    // `buffer` is the composer's raw text and `bytes` the rendered body: the
    // two differ (trimming, `> ` on quoted lines), and the acceptance script
    // needs the first to check the control⇄pane mirror.
    log.info(
        "viewer feedback pane={s} action=send bytes={d} buffer={d} quotes={d} images={d} worktree={s}",
        .{ self.paneId(), body.len, self.feedback_text.items.len, quotes.len, images.len, root },
    );
}

/// The pane's size in DIPs, e.g. "820x540" — it tells a reader whether a
/// layout complaint was made at a narrow width. Empty when the pane has no
/// window to measure, which is every unit-test pane.
fn viewportText(self: *ViewerPane, buf: []u8) []const u8 {
    const h = self.hwnd orelse return "";
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(h, &r) == 0) return "";
    const scale = if (self.scale > 0) self.scale else 1.0;
    const w: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(r.right - r.left)) / scale));
    const height: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(r.bottom - r.top)) / scale));
    return std.fmt.bufPrint(buf, "{d}x{d}", .{ w, height }) catch "";
}

/// The send worker landed. On success the composer is emptied and closes
/// itself behind a confirmation; on failure the text is kept, because a report
/// the user has to retype is worse than one that took two presses.
fn completeFeedbackSend(self: *ViewerPane) void {
    const sender = if (self.feedback_send) |*s| s else return;
    const p = self.pending orelse return;
    const result = sender.complete() orelse return;

    self.setFeedbackStatus(p.alloc, result.text);
    if (result.ok) {
        self.feedbackSetText(p.alloc, "");
        // The registry goes with the text: its entries describe passages that
        // are now in a filed report, and a quote that survived into the NEXT
        // report would attach that report's context to this one's passage.
        self.feedback_quotes.deinit(p.alloc);
        // ...and so do the images, for the same reason plus a plainer one:
        // they are megabytes, and the report that needed them has them now.
        self.feedback_images.deinit(p.alloc);
        if (self.feedback) |bar| {
            // The carousel's cache is keyed by chip NUMBER, and the store just
            // reset its counter — so without this the next paste's `#1` would
            // paint the picture the report that has just been filed carried.
            bar.imagesCleared();
            bar.seedControl();
        }
        if (self.hwnd) |h| {
            _ = w32.SetTimer(h, feedback_close_timer_id, feedback_close_delay_ms, null);
        }
    }
    log.info("viewer feedback pane={s} filed={} stem={s} status={s}", .{
        self.paneId(),
        result.ok,
        result.stem,
        result.text,
    });
    if (self.feedback) |bar| bar.repaint();
}

/// What the composer's footer says instead of its destination. Owned by the
/// pane; cleared when the composer next opens, so a stale "Filed …" never
/// greets the next report.
fn setFeedbackStatus(self: *ViewerPane, alloc: Allocator, text: []const u8) void {
    const dup: ?[]u8 = if (text.len == 0) null else (alloc.dupe(u8, text) catch null);
    if (self.feedback_status) |s| alloc.free(s);
    self.feedback_status = dup;
}

/// The footer's status line, or null when the composer should show its
/// destination instead.
pub fn feedbackStatus(self: *const ViewerPane) ?[]const u8 {
    return self.feedback_status;
}

// The composer's text. The editing happens in a RichEdit (T635, D43's answer)
// which is the storage WHILE the composer is open; this buffer is the copy
// that outlives it, mirrored from `EN_CHANGE` and seeded back on open. That
// split is what makes composer contents survive a close/reopen, which Mac is
// explicit about and which a buffer kept in the child window could not do.
//
// Line endings here are LF. RichEdit speaks CR; `ViewerFeedbackBar` converts
// in both directions so exactly one convention reaches the report writer.

pub fn feedbackText(self: *const ViewerPane) []const u8 {
    return self.feedback_text.items;
}

/// Replace the buffer wholesale — what the composer's change mirror does.
/// All-or-nothing: a failed allocation leaves the previous contents in place
/// rather than a truncated report.
pub fn feedbackSetText(self: *ViewerPane, alloc: Allocator, bytes: []const u8) void {
    self.feedback_text.clearRetainingCapacity();
    self.feedback_text.appendSlice(alloc, bytes) catch {};
}

/// Mirror of `Surface.setVisible`. A viewer has no renderer thread to park, so
/// this hides the host window and tells the controller to stop rendering —
/// the WebView2 half matters: an invisible-but-live view keeps compositing.
pub fn setVisible(self: *ViewerPane, visible: bool) void {
    if (self.visible == visible) return;
    self.visible = visible;
    if (self.controller) |c| _ = c.setVisible(visible);
    if (self.hwnd) |h| {
        _ = w32.ShowWindow(h, if (visible) w32.SW_SHOW else w32.SW_HIDE);
    }
}

/// Give the pane keyboard focus. Called from the host window's `WM_SETFOCUS`,
/// which the T48 `deferSetFocus` path posts — this never calls `SetFocus`
/// itself, for the same reason nothing else in the app does.
pub fn focus(self: *ViewerPane) void {
    self.focused = true;
    if (self.controller) |c| _ = c.moveFocus(.programmatic);
}

/// Show (or reposition) this pane's unfocused-split dim overlay (T380),
/// mirroring `Surface.showDimOverlay`. The overlay is an owned popup, so DWM
/// composites it above WebView2's own Chromium child windows the same way it
/// sits above a terminal's OpenGL content — a plain child window could not.
/// Called by `Window.updateDimOverlays` through the PaneView arm; takes the
/// allocator as a parameter (the ViewerPane convention) so the host floor
/// stays drivable from a unit test without an `App` or a `Window`.
pub fn showDimOverlay(self: *ViewerPane, alloc: Allocator, color: u32, alpha: u8) void {
    const hwnd = self.hwnd orelse return;
    if (self.dim_overlay == null) {
        // The host window's own module handle; createHostWindow recorded it.
        const hinstance = self.hinstance orelse return;
        self.dim_overlay = DimOverlay.create(
            alloc,
            hwnd,
            hinstance,
        ) catch |err| {
            log.warn("viewer dim overlay create failed err={}", .{err});
            return;
        };
    }
    self.dim_overlay.?.show(color, alpha);
}

/// Hide this pane's dim overlay if it exists.
pub fn hideDimOverlay(self: *ViewerPane) void {
    if (self.dim_overlay) |d| d.hide();
}

/// Re-check the z-order of this pane's layered popups (T142). The dim overlay
/// is the only one a viewer owns — its banner slot and scrollbar are
/// terminal-only.
pub fn healOverlayZOrders(self: *ViewerPane) void {
    const owner = self.hwnd orelse return;
    if (self.dim_overlay) |d| w32.healOverlayZOrder(d.hwnd, owner);
}

// -------------------------------------------------------------------------
// Navigation
// -------------------------------------------------------------------------

/// The longest location this pane will carry, in UTF-16 units. Chrome's own
/// omnibox limit is 2 MB and no real address comes near either number; the
/// cap exists so navigation can format into a stack buffer at a point (a
/// controller arriving) where there is no allocator and no way to fail.
const location_cap = 4096;

/// Point this pane at `url` and record it as the pane's current location.
///
/// The FIRST location is also the pane's home — where the nav bar's Home
/// button returns to, kept separately from where the user has since navigated
/// (docs/claude/viewers.md's viewer contract, and P12's manifest fields). Later navigations
/// move `location` only.
///
/// Safe before there is a controller: the pane is the one holding this truth,
/// and `adoptController` replays it — the same rule `visible` and `focused`
/// already follow. That is not an edge case here, it is the NORMAL path: a
/// pane is constructed and told where to go long before a browser process
/// finishes starting.
pub fn navigate(self: *ViewerPane, alloc: Allocator, requested: []const u8) Allocator.Error!void {
    // A diff location is CANONICALIZED on the way in (T463): `git-status` and
    // `git-status:` are one location, and `git-diff: main...HEAD ` is the same
    // diff as `git-diff:main...HEAD`. One spelling is what the address bar
    // shows, what `+list --json` reports and what the manifest restores — and
    // the pane compares locations to decide what to re-run.
    var canon_buf: [location_cap]u8 = undefined;
    const url: []const u8 = if (viewer_diff.parse(requested)) |spec|
        (spec.canonicalLocation(&canon_buf) orelse requested)
    else
        requested;

    const dup = try alloc.dupeZ(u8, url);
    if (self.location) |l| alloc.free(l);
    self.location = dup;
    // The document that WAS here is not the document being asked for, so the
    // pane has no completed load again until `onNavigationCompleted` says so.
    // Left stale, a `+reload` arriving during a navigation would re-render the
    // OLD file into the NEW page (T390).
    self.page_loaded = false;
    // ...and neither is the selection: whatever the user had highlighted is a
    // fact about the OLD document, and the new one starts with none (T636).
    self.setPageSelection(alloc, null);
    if (self.home_location == null) {
        self.home_location = alloc.dupeZ(u8, url) catch null;
    }

    // Re-derived on EVERY navigation rather than fixed at construction: the
    // same pane moves between a file and the web over its life (the address
    // bar, an in-page link), and a stale mode would render a website through
    // the markdown template.
    const was_template = self.mode.usesTemplate();
    self.mode = content.modeFor(url);
    // Leaving the TEMPLATE — for the web, or for a rendered `.html` page, which
    // the web view loads itself: whatever headings the template last reported
    // are gone with it, and nothing will arrive to clear them, because the
    // bridge only exists in our template. Keying this on `usesTemplate` rather
    // than `isFile` is what keeps a markdown document's table of contents from
    // hanging over the HTML page that replaced it (T601). (`syncCommitted`
    // applies the same rule to BROWSER-initiated moves, where the pane's mode
    // has not flipped yet by the time the commit event lands; this is the
    // pane-initiated half, which flips the mode right here.)
    if (was_template and !self.mode.usesTemplate()) self.clearHeadings(alloc);
    if (self.file_path) |p| alloc.free(p);
    self.file_path = null;
    if (self.mode.isFile()) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (content.filePath(&buf, url)) |path| {
            self.file_path = try alloc.dupe(u8, path);
        } else {
            log.warn("viewer location is not a usable file path", .{});
        }
    }
    if (self.mode.usesTemplate()) {
        // Remember the file separately from `file_path`: this copy SURVIVES
        // the pane going web, because it is what Back re-renders when the
        // browser walks history onto the template again (T159).
        //
        // A rendered `.html` file is deliberately NOT recorded here (T601,
        // Mac's `fileLocation` note): this field means "the file the TEMPLATE
        // page is holding", and overwriting it with a directly-loaded page
        // would lose the markdown document still sitting behind it in history.
        if (alloc.dupeZ(u8, url)) |copy| {
            if (self.file_location) |l| alloc.free(l);
            self.file_location = copy;
        } else |_| {}
    }
    self.syncHtmlGrant(alloc);

    // Name the pane NOW, from the location alone. A website's real title
    // arrives later over `DocumentTitleChanged`; a file's never does (the
    // template's `<title>` is not the document's name), so in file mode this is
    // the whole answer. Either way the pane is never nameless while it loads —
    // the T383 defect, where a tab read "Ghoztty" for a pane that knew exactly
    // what it was showing.
    self.setTitle(alloc, content.initialTitle(self.mode, url, self.file_path)) catch {};

    // Where a viewer IS is restore state (T90h), so moving it is a layout
    // change in exactly the way a new split is. Routed through `pane_view`
    // rather than `parent_window`: the back-pointer is null until the pane is
    // in a tree, which is both the pre-insert half of its own construction (the
    // insert marks the layout dirty itself) and every unit test.
    if (self.pane_view) |pv| pv.parentWindow().app.markLayoutDirty();

    self.pushAddress();
    self.refreshWorktree();
    self.applyNavigation();
    self.syncWatcher(alloc);
    // A diff's content is a repository, not a file, so its "watcher" is a poll
    // and its first load happens when the template says it is ready (T463).
    self.diff_pushed = false;
    self.syncDiffPoll();
}

/// Re-derive the read grant and the page URL a rendered `.html` file loads
/// from (T601), for a navigation the PANE issued — an open, the address bar,
/// Home, a session restore. Every one of those names a file outright, so the
/// grant is re-derived from it; a navigation the PAGE issued is handled by
/// `syncCommitted`, which keeps the grant it was given.
///
/// Non-fatal throughout: a pane that cannot build a page URL falls back to the
/// template and its error card, which says which file and why, rather than
/// leaving a blank pane behind a silent failure.
fn syncHtmlGrant(self: *ViewerPane, alloc: Allocator) void {
    if (self.html_root) |d| alloc.free(d);
    if (self.html_url) |u| alloc.free(u);
    self.html_root = null;
    self.html_url = null;
    self.html_fallback = false;
    if (self.mode != .html) return;

    const path = self.file_path orelse {
        self.html_fallback = true;
        return;
    };
    // Resolved against the process cwd when it is not already absolute: the
    // grant is a prefix check, and a relative root would match nothing the
    // page asks for. The CLI resolves `--view=` paths already, so this is the
    // belt for a location that reached the pane another way.
    const abs = std.fs.path.resolve(alloc, &.{path}) catch {
        self.html_fallback = true;
        return;
    };
    errdefer alloc.free(abs);

    const dir = content.baseDirectory(abs) orelse {
        alloc.free(abs);
        self.html_fallback = true;
        return;
    };
    const root = alloc.dupe(u8, dir) catch {
        alloc.free(abs);
        self.html_fallback = true;
        return;
    };
    const url = content.pageUrlFor(alloc, root, abs) catch null;
    alloc.free(abs);
    self.html_root = root;
    self.html_url = url orelse {
        self.html_fallback = true;
        return;
    };
    // A file that is not there has no page to load, and the resource handler's
    // 404 would surface as Chromium's own error page. Answer with the pane's
    // card instead, which names the file (`applyNavigation` reads this).
    self.html_fallback = !isReadableFile(path);
    // The pane STATES its grant. This is the only place the decision is made,
    // and the acceptance harness runs on a background desktop where nothing can
    // see a rendered page — so what proves an `.html` file is being rendered
    // rather than shown as source is this line plus the resource requests that
    // follow it, both of which only a page load can produce.
    log.info("viewer html pane={s} page={s} root={s} fallback={}", .{
        self.paneId(),
        self.html_url orelse "",
        root,
        self.html_fallback,
    });
}

fn isReadableFile(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

/// Point the live-reload watcher at wherever the pane now IS (T391).
///
/// Driven off `navigate` alone, because `navigate` is the only thing that
/// changes `file_path` — a pane that moves from a file to a website stops
/// watching, one that moves the other way starts, and one that re-opens the
/// same file re-arms harmlessly.
///
/// Unlike Mac, nothing else has to call this: `ReadDirectoryChangesW` reports
/// by name within a directory, so an atomic save arrives as a notification for
/// the same basename rather than orphaning the watch (see `viewer_watcher`).
/// There is no equivalent of `reloadNeedsRearm` to drive from the reload path.
fn syncWatcher(self: *ViewerPane, alloc: Allocator) void {
    self.watcher.stop();
    // No host window means nothing to post at. That is the pre-`createHostWindow`
    // moment and every unit test that drives a bare pane, both of which want a
    // pane that simply does not watch rather than one that fails to open.
    const hwnd = self.hwnd orelse return;
    // Stopping the watcher is not enough: a notification that arrived within
    // the debounce window has already armed the timer, and a one-shot timer
    // outlives the thread that armed it. Left running it fires against
    // wherever the pane WENT — for a web destination a cache-bypassing
    // re-fetch of a page nobody asked to reload (T400). Leaving a document
    // cancels its pending render, the way Mac's `reloadDebounce?.cancel()`
    // does.
    _ = w32.KillTimer(hwnd, reload_timer_id);
    const path = self.file_path orelse return;
    self.watcher.start(alloc, hwnd, WM_APP_VIEWER_RELOAD, path);
}

// -------------------------------------------------------------------------
// Git diff panes (T463; Mac's `refreshDiff` / `pushDiffListing` /
// `pushDiffFile`)
// -------------------------------------------------------------------------

/// The spec this pane is showing, or null when it is not showing a diff.
/// Borrows from `location`.
fn diffSpec(self: *const ViewerPane) ?viewer_diff.Spec {
    if (self.mode != .diff) return null;
    return viewer_diff.parse(self.location orelse return null);
}

/// Start (or restart) the working-tree poll, and stop it everywhere else.
///
/// Only `git-status:` polls: a commit or a range is a fixed pair of trees and
/// re-running it would spend a process every two seconds to redraw the same
/// bytes. Driven from the same places `syncWatcher` is, because it is the same
/// question for a pane whose content is a repository rather than a file.
fn syncDiffPoll(self: *ViewerPane) void {
    const hwnd = self.hwnd orelse return;
    _ = w32.KillTimer(hwnd, diff_timer_id);
    const spec = self.diffSpec() orelse return;
    if (!spec.tracksWorkingTree()) return;
    _ = w32.SetTimer(hwnd, diff_timer_id, diff_poll_ms, null);
}

/// Ask git for this pane's file list. Everything below lands later, on
/// `WM_APP_VIEWER_DIFF`.
fn refreshDiff(self: *ViewerPane) void {
    const probe = if (self.diff_probe) |*p| p else return;
    if (self.mode != .diff) return;
    probe.requestListing(self.location orelse return, self.origin_directory);
}

/// A listing arrived: push the header, then open a file so the pane is not a
/// summary over an empty page.
fn applyDiffListing(self: *ViewerPane, alloc: Allocator) void {
    const probe = if (self.diff_probe) |*p| p else return;
    const spec = self.diffSpec() orelse return;
    const resolved = probe.resolvedSpec(self.location orelse "") orelse spec;

    var files: usize = 0;
    var additions: u64 = 0;
    var deletions: u64 = 0;
    for (probe.files.items) |f| {
        files += 1;
        additions += f.additions;
        deletions += f.deletions;
    }

    var subtitle_buf: [512]u8 = undefined;
    var message_buf: [512]u8 = undefined;
    var detail_buf: [1024]u8 = undefined;
    var listing: viewer_diff.Listing = .{
        .title = resolved.title(),
        .subtitle = viewer_diff.subtitle(&subtitle_buf, resolved, probe.repo),
        .file_count = files,
        .additions = additions,
        .deletions = deletions,
        .style = self.diff_style,
    };
    if (probe.failure) |*f| {
        const view = f.view();
        listing.message = view.title();
        listing.detail = view.detail(&detail_buf);
    } else if (files == 0) {
        listing.message = viewer_diff.emptyMessage(&message_buf, resolved);
    }

    // The acceptance oracle. `+list` cannot see inside a WebView2 and the suite
    // runs on a background desktop, so the GUI's own stderr is where "this pane
    // really rendered this diff" has to be readable (the T633 rule, same shape).
    log.info("viewer diff pane={s} spec={s} repo={s} files={d} +{d} -{d} status={s}", .{
        self.paneId(),
        self.location orelse "",
        probe.repo orelse "<none>",
        files,
        additions,
        deletions,
        listing.message orelse "ok",
    });

    const js = viewer_diff.setDiffListingCall(alloc, listing) catch return;
    defer alloc.free(js);
    self.executeScript(alloc, js);

    // Nothing to open, and nothing to keep: a pane whose diff emptied out must
    // not keep claiming to be showing a file that left it.
    if (files == 0) {
        if (self.diff_file) |f| alloc.free(f);
        self.diff_file = null;
        return;
    }
    self.openDiffFile(alloc, self.reselectDiffFile(), null);
}

/// Which file the page should be showing after a refresh: the same one when it
/// is still in the diff (a poll must not yank the reader somewhere else), else
/// the first — the pane has no file tree yet, so the first file is what makes a
/// freshly-opened diff show a diff rather than "select a file".
fn reselectDiffFile(self: *const ViewerPane) usize {
    const probe = if (self.diff_probe) |*p| p else return 0;
    const want = self.diff_file orelse return 0;
    for (probe.files.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.path, want)) return i;
    }
    return 0;
}

/// Ask git for one file's patch, remembering which file that is.
fn openDiffFile(self: *ViewerPane, alloc: Allocator, index: usize, scroll_to: ?[]const u8) void {
    const probe = if (self.diff_probe) |*p| p else return;
    if (index >= probe.files.items.len) return;
    const entry = probe.files.items[index];

    if (self.diff_file) |f| alloc.free(f);
    self.diff_file = alloc.dupe(u8, entry.path) catch null;

    // A binary file never gets a patch; say so immediately rather than spawning
    // a git process that will produce nothing useful (Mac's `loadDiffPatch`).
    if (entry.binary) {
        self.pushDiffFile(alloc, entry, null, scroll_to);
        return;
    }
    probe.requestPatch(self.location orelse return, index, scroll_to);
}

/// A patch arrived (or was skipped): put it on screen.
fn applyDiffPatch(self: *ViewerPane, alloc: Allocator) void {
    const probe = if (self.diff_probe) |*p| p else return;
    const path = probe.patch_path orelse return;
    for (probe.files.items) |entry| {
        if (!std.mem.eql(u8, entry.path, path)) continue;
        self.pushDiffFile(alloc, entry, probe.patch, null);
        return;
    }
}

fn pushDiffFile(
    self: *ViewerPane,
    alloc: Allocator,
    entry: ViewerDiffProbe.Entry,
    patch: ?[]const u8,
    scroll_to: ?[]const u8,
) void {
    log.info("viewer diff pane={s} file={s} status={s} patch={d}", .{
        self.paneId(),
        entry.path,
        entry.status.letter(),
        (patch orelse "").len,
    });
    const js = viewer_diff.setDiffFileCall(alloc, .{
        .path = entry.path,
        .old_path = entry.old_path,
        .status = entry.status,
        .origin = entry.origin,
        .additions = entry.additions,
        .deletions = entry.deletions,
        .binary = entry.binary,
        .language = content.highlightLanguage(content.extension(entry.path)) orelse "",
        .patch = patch orelse "",
        .scroll_to = scroll_to,
    }) catch return;
    defer alloc.free(js);
    self.executeScript(alloc, js);
}

/// The diff worker landed. The ONLY place its answer is read, and it runs on
/// the GUI thread — which is what lets the page be driven straight from it.
fn completeDiff(self: *ViewerPane, alloc: Allocator) void {
    const probe = if (self.diff_probe) |*p| p else return;
    // A snapshot of what was on screen BEFORE this answer, so a poll that found
    // nothing new redraws nothing: re-pushing an identical listing would reset
    // the page's scroll every two seconds.
    const before = probe.snapshot(alloc);
    defer ViewerDiffProbe.freeSnapshot(alloc, before);

    switch (probe.complete()) {
        .none => return,
        .listing => {
            if (probe.listingDiffers(before) or !self.diff_pushed) {
                self.diff_pushed = true;
                self.applyDiffListing(alloc);
            }
        },
        .patch => self.applyDiffPatch(alloc),
    }
    probe.drainDeferred(self.location orelse "", self.origin_directory);
}

/// Everything a freshly-created viewer pane is opened WITH. One struct rather
/// than a growing parameter list because all three values travel together
/// through the same three call sites (`+new-window --view`, `+split --view`,
/// and session restore), and only restore ever sets the last two.
///
/// Strings are BORROWED for the duration of the open call; the pane dupes what
/// it keeps.
pub const Open = struct {
    /// Where to navigate. Required.
    location: []const u8,

    /// Override for the pane's home (the Home button's target). Null ⇒ the
    /// first `navigate` sets home from `location`, which is what a NEW pane
    /// wants. Restore passes the recorded home, because a restored pane's
    /// location may be somewhere it navigated to later and re-homing it there
    /// would quietly lose where it started (T90h).
    home_location: ?[]const u8 = null,

    /// The directory the pane was opened from (`--working-directory`).
    origin_directory: ?[]const u8 = null,

    /// The parked `window.open()` this pane is being built to adopt (T163).
    /// Non-null ONLY on the popup path. The pane takes its own reference on it
    /// and answers it when its controller arrives; until then it must not
    /// navigate. Every other open path leaves this null and navigates normally.
    popup: ?*PopupRequest = null,
};

/// Apply the non-location half of an `Open` — the two values `navigate` cannot
/// derive. Call AFTER `navigate`, so the home override lands on top of the home
/// that navigation seeds rather than under it.
///
/// Non-fatal: a pane that fails to record its home still shows its content, so
/// this degrades to "Home returns to where you are" rather than failing the
/// open. Same rule `navigate` already applies to its own home seed.
pub fn applyOpenMetadata(self: *ViewerPane, alloc: Allocator, opts: Open) void {
    if (opts.home_location) |home| {
        if (alloc.dupeZ(u8, home)) |dup| {
            if (self.home_location) |l| alloc.free(l);
            self.home_location = dup;
        } else |_| log.warn("viewer home location could not be recorded", .{});
    }
    if (opts.origin_directory) |dir| {
        if (alloc.dupe(u8, dir)) |dup| {
            if (self.origin_directory) |d| alloc.free(d);
            self.origin_directory = dup;
        } else |_| log.warn("viewer origin directory could not be recorded", .{});
    }
}

fn applyNavigation(self: *ViewerPane) void {
    const c = self.controller orelse return;
    // A file-mode pane navigates to the BUNDLED TEMPLATE, not to the file: the
    // file's bytes arrive afterwards through `window.__viewer` (T90a design
    // §6). Navigating to the file itself would hand markdown to Chromium's
    // plain-text viewer, which is the "renders as raw text" defect the whole
    // offline renderer exists to avoid.
    // A rendered `.html` file is the exception: the web view loads the PAGE
    // itself, from its own virtual host, so its CSS, scripts, images and fonts
    // run exactly as they would if it were served (T601). The fallback is the
    // template, whose error card is the only thing that can name a file that
    // could not be read.
    const loc: []const u8 = if (self.mode == .html)
        (if (self.html_fallback) content.page_url else self.html_url orelse content.page_url)
    else if (self.mode.usesTemplate())
        content.page_url
    else
        self.location orelse return;
    // UTF-16 units never outnumber UTF-8 bytes (a 4-byte sequence becomes two
    // units, every shorter one becomes a single unit), so a length check on the
    // input is a real bound on the output — not the after-the-fact check that
    // would already have overrun.
    if (loc.len >= location_cap) {
        log.warn("viewer location is too long to navigate to ({d} bytes)", .{loc.len});
        return;
    }
    var buf: [location_cap]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, loc) catch {
        log.warn("viewer location is not valid UTF-8", .{});
        return;
    };
    buf[len] = 0;
    const web = c.coreWebView() orelse return;
    defer web.release();
    if (!web.navigate(buf[0..len :0])) log.warn("Navigate failed for this pane", .{});
}

/// `ICoreWebView2NewWindowRequestedEventHandler`: `window.open()` and
/// `target=_blank`.
///
/// Its context is the pane's `Pending` token, not the pane — an event handler
/// outlives the pane that registered it, and the token is the codebase's
/// existing answer to that (`com.CallbackOwning` is what lets it give the
/// reference back when the runtime finally drops the object).
const NewWindowRequestedHandler = com.CallbackOwning(
    iface.IID_NewWindowRequestedHandler,
    onNewWindowRequested,
    releasePendingToken,
);

fn releasePendingToken(p: *Pending) void {
    p.release();
}

/// A popup this app has agreed to ADOPT, parked on a WebView2 deferral until
/// the window that will host it has a web view of its own (T163).
///
/// The whole point of the type is that the answer is owed exactly once. A
/// deferral that is never completed hangs the calling script's `window.open()`
/// forever, and a `NewWindowRequested` that completes with neither a
/// `NewWindow` nor `Handled` lets the runtime open a chrome-less window we do
/// not own — so the request has to survive every path out of the creation
/// chain, including the ones that fail. It is therefore REFCOUNTED, on the same
/// two-owner model `Pending` uses: the trampoline that starts the window holds
/// one reference, the pane it hands the request to takes a second, and whoever
/// drops the last one answers the page.
pub const PopupRequest = struct {
    args: *iface.ICoreWebView2NewWindowRequestedEventArgs,
    deferral: *iface.ICoreWebView2Deferral,
    alloc: Allocator,
    refs: u8,

    /// Whether the runtime has been told what to do. Answering twice is not a
    /// contract WebView2 defines, so the second attempt is dropped rather than
    /// explored.
    answered: bool = false,

    /// Take the args and a deferral off a live event. Null when the runtime
    /// refuses the deferral or we cannot allocate — the caller then falls back
    /// to the synchronous answer, which is always available.
    fn take(
        alloc: Allocator,
        args: *iface.ICoreWebView2NewWindowRequestedEventArgs,
    ) ?*PopupRequest {
        const self = alloc.create(PopupRequest) catch return null;
        // Order matters: the deferral is what can fail, so nothing is retained
        // until it is in hand.
        const deferral = args.getDeferral() orelse {
            alloc.destroy(self);
            return null;
        };
        args.addRef();
        self.* = .{
            .args = args,
            .deferral = deferral,
            .alloc = alloc,
            .refs = 1,
        };
        return self;
    }

    /// Take a second reference. Called by `Window.createViewerPane` as it hands
    /// the request to the pane that will answer it.
    pub fn retain(self: *PopupRequest) void {
        self.refs += 1;
    }

    /// Give the parked request `web` as its window. Idempotent, and it does NOT
    /// free — `release` is what ends the object's life, so a pane that answers
    /// early still holds its reference until it lets go.
    fn answer(self: *PopupRequest, web: ?*iface.ICoreWebView2) void {
        if (self.answered) return;
        self.answered = true;
        if (web) |w| {
            // `Handled` was already set by the handler, unconditionally, so a
            // failure HERE degrades to `window.open()` returning null rather
            // than to a rogue WebView2 window.
            if (!self.args.setNewWindow(w)) {
                log.warn("put_NewWindow failed; the popup will not open", .{});
            }
        }
        if (!self.deferral.complete()) {
            log.warn("popup deferral Complete failed; the opener may hang", .{});
        }
    }

    /// Drop one reference. The last one out answers the page — with nothing, if
    /// nobody managed to build a window — because a request that is simply
    /// dropped is a script waiting forever.
    fn release(self: *PopupRequest) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        self.answer(null);
        self.deferral.release();
        self.args.release();
        self.alloc.destroy(self);
    }
};

/// Everything the popup trampoline needs to build the window. One struct
/// because it travels through a function POINTER — see `open_popup_window` for
/// why that indirection is load-bearing — and a pointer type with six
/// parameters is unreadable at both ends.
pub const PopupOpen = struct {
    /// The parked request. The trampoline consumes exactly one reference on it,
    /// whether or not it manages to build anything.
    req: *PopupRequest,
    /// Where the popup is going. Borrowed for the duration of the call.
    location: []const u8,
    /// The opener's origin directory, inherited so feedback filed from a popup
    /// still lands in the same repo (Mac passes its `originDirectory` the same
    /// way). Borrowed.
    origin_directory: ?[]const u8,
    /// The size `window.open(…, "width=…,height=…")` asked for, in physical
    /// pixels, or null when it asked for none.
    size: ?PopupSize,
};

/// Re-exported so `Window.InitOptions` can name the type without importing the
/// pure module: the popup size travels from here to there and nowhere else.
pub const PopupSize = viewer_popup.Size;

fn onNewWindowRequested(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2NewWindowRequestedEventArgs,
) com.HRESULT {
    _ = sender;
    const a = args orelse return com.S_OK;

    // Handled FIRST, and unconditionally: whatever else goes wrong below, a
    // popup must not open a chrome-less WebView2 window we do not own and
    // cannot close. Every other path in this function is then free to fail into
    // "the popup does not open", which a script sees as `window.open()`
    // returning null — a documented outcome, unlike a stray browser window.
    _ = a.setHandled(true);

    // A pane that is already gone does not get to open windows or browser tabs:
    // the token outlives it precisely so this check can be made.
    const self = p.pane orelse return com.S_OK;

    // The URI, as UTF-8, for the decision and for the window that may follow.
    //
    // Three outcomes, and they are deliberately not the same one:
    //   - no URI at all ⇒ Mac's nil URL, which keeps the popup here;
    //   - a URI we cannot REPRESENT — too long for the buffer, or not decodable
    //     — goes straight to the shell in its original UTF-16, which is exactly
    //     what this handler did before T163. Nothing is lost by not reasoning
    //     about it, and the alternative (adopting it as a blank pane) would
    //     silently drop the destination the page asked for.
    //   - anything else gets the real decision below.
    //
    // The length guard is the load-bearing half: UTF-8 needs up to 3 bytes per
    // UTF-16 unit, and `utf16LeToUtf8` writes into the destination without
    // bounds-checking it — an overrun here is a crash inside a COM callback,
    // with the browser process blocked on us.
    var uri_buf: [location_cap]u8 = undefined;
    var too_long = false;
    const uri: ?[]const u8 = uri: {
        const raw = a.uriRaw() orelse break :uri null;
        defer w32.CoTaskMemFree(@ptrCast(raw));
        const wide = std.mem.span(raw);
        if (wide.len * 3 > uri_buf.len) {
            log.warn("popup URI is too long to route ({d} units); handing it to the shell", .{wide.len});
            too_long = true;
            // Same rule as `shellOpen` (T594): a test binary never reaches the
            // shell. This branch bypasses the sink-guarded router by design, so
            // it needs the guard of its own.
            if (builtin.is_test) {
                log.err("test build refused to shell-open a too-long popup URI", .{});
            } else _ = w32.ShellExecuteW(
                null,
                std.unicode.utf8ToUtf16LeStringLiteral("open"),
                raw,
                null,
                null,
                w32.SW_SHOW,
            );
            break :uri null;
        }
        const len = std.unicode.utf16LeToUtf8(&uri_buf, wide) catch break :uri null;
        break :uri uri_buf[0..len];
    };
    if (too_long) return com.S_OK;

    // WebView2 puts no modifier state on the args — there is no win32 analog of
    // `navigationAction.modifierFlags` — so the Ctrl escape hatch is read off
    // the keyboard directly. `GetAsyncKeyState`, not `GetKeyState`: the latter
    // answers for the message this thread is currently dispatching, which is a
    // browser-process message here and not the click at all.
    const ctrl_held = (w32.GetAsyncKeyState(w32.VK_CONTROL) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;

    switch (viewer_popup.destination(uri, ctrl_held)) {
        .default_browser => {
            // Non-null by construction: `destination` only ever routes a
            // readable http(s) URI here.
            const u = uri orelse return com.S_OK;
            self.openExternal(p.alloc, u);
        },
        .ghoztty_command => {
            // Non-null by construction, same as the browser arm. Nothing is
            // adopted and no deferral is taken: the popup simply does not open,
            // which is what `window.open()` returning null already means to a
            // script — and the link does its one job instead (T695).
            const u = uri orelse return com.S_OK;
            self.focusLinkTarget(u);
        },
        .ghoztty_window => self.adoptPopup(p.alloc, a, uri),
    }
    return com.S_OK;
}

/// Turn a `window.open()` into a real ghoztty window whose single pane IS the
/// popup (T163).
///
/// The mechanism is the whole point and it is not "open a window at the same
/// URL": the runtime must be handed a web view WE created, which it then
/// navigates itself. That is what preserves `window.opener` and therefore
/// `window.close()` — a view we navigated ourselves is a different window as
/// far as the opening script is concerned, and both would be dead. Since our
/// web view is created asynchronously, the request is parked on a deferral
/// until it exists.
fn adoptPopup(
    self: *ViewerPane,
    alloc: Allocator,
    args: *iface.ICoreWebView2NewWindowRequestedEventArgs,
    uri: ?[]const u8,
) void {
    // No trampoline installed means there is nowhere to put a window, so the
    // popup does not open. `Handled` is already true, so nothing leaks out.
    const open_window = self.open_popup_window orelse return;

    const req = PopupRequest.take(alloc, args) orelse {
        log.warn("could not defer the popup; it will not open", .{});
        return;
    };
    // The trampoline's own reference. Released unconditionally on the way out —
    // if the window came up, the pane took a second one and this is not the last.
    defer req.release();

    // A popup that named no URL is the blank page its script writes into, which
    // is exactly what `--view=about:blank` opens (docs/claude/viewers.md's blank browser
    // pane). Naming it here rather than leaving the location empty is what
    // gives the pane a title and an address before WebView2 navigates it.
    const location = if (uri) |u| u else content.blank_page;

    open_window(self, .{
        .req = req,
        .location = location,
        .origin_directory = self.origin_directory,
        .size = self.popupSize(args),
    });
}

/// The size the opener asked for, in physical pixels for THIS pane's monitor.
/// Null when it asked for none, which is a window at the ordinary default.
fn popupSize(self: *ViewerPane, args: *iface.ICoreWebView2NewWindowRequestedEventArgs) ?PopupSize {
    const features = args.windowFeatures() orelse return null;
    defer features.release();
    return viewer_popup.requestedSize(
        features.hasSize(),
        features.width(),
        features.height(),
        self.scale,
    );
}

/// `ICoreWebView2WindowCloseRequestedEventHandler`: the page called
/// `window.close()` — Mac's `webViewDidClose` (T163).
const WindowCloseRequestedHandler = com.CallbackOwning(
    iface.IID_WindowCloseRequestedHandler,
    onWindowCloseRequested,
    releasePendingToken,
);

fn onWindowCloseRequested(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*anyopaque,
) com.HRESULT {
    _ = sender;
    _ = args; // the event carries nothing at all
    const self = p.pane orelse return com.S_OK;
    const hwnd = self.hwnd orelse return com.S_OK;
    // Posted, never done here: closing the pane destroys this very controller,
    // and the browser process is synchronously blocked inside this call.
    _ = w32.PostMessageW(hwnd, WM_APP_VIEWER_CLOSE, 0, 0);
    return com.S_OK;
}

// -------------------------------------------------------------------------
// The page bridge (T375, design P1/P2)
// -------------------------------------------------------------------------

/// `ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler`. It has
/// nothing to do on success — the script is installed either way — but the slot
/// is not optional: the runtime dereferences the handler to hand back the
/// script's id, so a null there is a crash in someone else's process.
const AddScriptCompletedHandler = com.CallbackOwning(
    iface.IID_AddScriptCompletedHandler,
    onAddScriptCompleted,
    releasePendingToken,
);

fn onAddScriptCompleted(p: *Pending, result: com.HRESULT, id: ?[*:0]const u16) com.HRESULT {
    _ = p;
    _ = id;
    // Only the failure is worth a word. A page that loads without the blob
    // still renders; it just has no selection toolbar and posts nothing back,
    // which is a degradation the user can see and a log line can explain.
    if (com.failed(result)) log.warn(
        "AddScriptToExecuteOnDocumentCreated failed hr=0x{X:0>8}; no quoting in this pane",
        .{@as(u32, @bitCast(result))},
    );
    return com.S_OK;
}

/// `ICoreWebView2WebMessageReceivedEventHandler`: everything the page posts
/// through the shim. Carries the `Pending` token for the same reason the
/// new-window handler does — an event handler outlives the pane.
const WebMessageReceivedHandler = com.CallbackOwning(
    iface.IID_WebMessageReceivedHandler,
    onWebMessageReceived,
    releasePendingToken,
);

fn onWebMessageReceived(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2WebMessageReceivedEventArgs,
) com.HRESULT {
    _ = sender;
    const a = args orelse return com.S_OK;
    // A pane that is already gone does not get to act on its page's messages.
    const self = p.pane orelse return com.S_OK;

    const raw = a.jsonRaw() orelse return com.S_OK;
    // The runtime allocated it on the COM heap; we free it on ours.
    defer w32.CoTaskMemFree(@ptrCast(raw));

    // The JSON is UTF-16 and everything downstream is UTF-8. A payload that is
    // not valid UTF-16 came from a page, not from us, so it is dropped rather
    // than fatal.
    const utf8 = std.unicode.utf16LeToUtf8Alloc(p.alloc, std.mem.span(raw)) catch return com.S_OK;
    defer p.alloc.free(utf8);

    const parsed = bridge.parse(p.alloc, utf8) orelse return com.S_OK;
    defer parsed.deinit();
    self.applyMessage(p.alloc, parsed.message);
    return com.S_OK;
}

/// Act on one parsed page message. Split out from the COM callback so it is
/// reachable from a unit test without a browser process.
fn applyMessage(self: *ViewerPane, alloc: Allocator, message: bridge.Message) void {
    switch (message) {
        .headings => |items| self.setHeadings(alloc, items),
        .active => |id| self.setActiveHeading(alloc, id),
        .quote => |q| self.acceptQuote(alloc, q),
        .selection => |text| self.setPageSelection(alloc, text),
    }
}

/// Remember what the user has selected in the page, so a report can say what
/// they were pointing at (T636). Null clears it — a click into the page must
/// take the previous selection out of the next report.
///
/// Best-effort: a selection we could not copy is one the report goes without,
/// which is strictly better than a send that fails over context.
fn setPageSelection(self: *ViewerPane, alloc: Allocator, text: ?[]const u8) void {
    const dup: ?[]u8 = if (text) |t| (alloc.dupe(u8, t) catch null) else null;
    if (self.page_selection) |s| alloc.free(s);
    self.page_selection = dup;
}

/// The page's Quote button: register the passage with its referential context
/// and put it into the composer as its own block (T641).
///
/// Opening the composer is part of quoting, not a separate step — the user
/// pressed Quote to say something about the passage, and a quote filed into a
/// composer they cannot see is a quote they do not know they made. It is the
/// one thing here that can fail: a pane in no working tree has nowhere to
/// file, and `setFeedbackOpen` refuses for that reason.
fn acceptQuote(self: *ViewerPane, alloc: Allocator, q: bridge.Quote) void {
    if (!self.feedback_open) self.setFeedbackOpen(true);
    if (!self.feedback_open) {
        log.info("viewer quote pane={s} dropped: no worktree to file into", .{self.paneId()});
        return;
    }

    const id = self.feedback_quotes.add(alloc, q) catch |err| {
        log.warn("viewer quote pane={s} not registered: {s}", .{ self.paneId(), @errorName(err) });
        return;
    };
    const entry = self.feedback_quotes.entries.items[self.feedback_quotes.entries.items.len - 1];
    if (self.feedback) |bar| bar.insertQuote(entry.text);

    // The acceptance script's oracle: this chrome is owner-painted inside a
    // background test desktop and cannot be screenshotted, so the pane states
    // what it did — including the context it recorded, which is the half a
    // "the text arrived" check would miss.
    log.info(
        "viewer quote pane={s} id={d} bytes={d} heading={s} block={s} offset={?d} live={d}",
        .{
            self.paneId(),
            id,
            entry.text.len,
            entry.heading_id orelse "-",
            entry.block_selector orelse "-",
            entry.document_offset,
            self.feedbackQuoteCount(alloc),
        },
    );
}

/// Where the live quotes sit in the composer's text. Caller frees. Null when
/// the derivation could not be done at all (an allocation failure), which
/// callers treat as "no quotes" rather than as a reason to stop.
pub fn feedbackQuoteSpans(self: *const ViewerPane, alloc: Allocator) ?[]feedback_doc.Span {
    return self.feedback_quotes.live(alloc, self.feedback_text.items) catch null;
}

/// How many quotes the report would carry right now — the number that drops
/// when the user deletes a block.
pub fn feedbackQuoteCount(self: *const ViewerPane, alloc: Allocator) usize {
    const spans = self.feedbackQuoteSpans(alloc) orelse return 0;
    defer alloc.free(spans);
    return spans.len;
}

/// Take one PNG into the composer's store and answer with the number its chip
/// carries, or null when it could not be taken (not a PNG, too big, or the
/// composer already holds as much as it will).
///
/// The pane owns the store, so the picture survives the composer being closed
/// and reopened exactly as its text does — and the chip's number is allocated
/// here, before anything is inserted, so the two can never disagree about what
/// `[Image #N]` refers to.
pub fn feedbackAddImage(self: *ViewerPane, alloc: Allocator, png: []const u8) ?u32 {
    const number = self.feedback_images.add(alloc, png) catch |err| {
        log.warn("viewer feedback pane={s} image rejected: {s}", .{
            self.paneId(),
            @errorName(err),
        });
        self.setFeedbackStatus(alloc, switch (err) {
            error.TooLarge, error.Full => "That image is too large to attach",
            else => "That is not an image this can attach",
        });
        if (self.feedback) |bar| bar.repaint();
        return null;
    };
    return number;
}

/// How many images the report would carry right now — the number that drops
/// when the user deletes a chip. The acceptance script's oracle.
pub fn feedbackImageCount(self: *const ViewerPane, alloc: Allocator) usize {
    const spans = self.feedback_images.live(alloc, self.feedback_text.items) catch return 0;
    defer if (spans.len != 0) alloc.free(spans);
    return spans.len;
}

/// Where the live chips SIT, in the composer's buffer — what the thumbnail
/// carousel paints from and what a click on a tile selects (T646). Caller
/// frees. Same derivation as `feedbackImageCount` and as the report's `images`
/// array, so the strip cannot show a picture the report would not carry.
pub fn feedbackImageSpans(
    self: *const ViewerPane,
    alloc: Allocator,
) ?[]feedback_images_mod.Span {
    return self.feedback_images.live(alloc, self.feedback_text.items) catch null;
}

/// The PNG behind a live chip's `index` into `feedbackImageSpans`.
pub fn feedbackImageEntry(
    self: *const ViewerPane,
    span: feedback_images_mod.Span,
) *const feedback_images_mod.Entry {
    return &self.feedback_images.entries.items[span.index];
}

/// Replace the pane's heading list with its own copy of `items`.
///
/// All-or-nothing: the new list is built before the old one is freed, so an
/// allocation failure part-way leaves the pane showing the headings it already
/// had rather than half a document's worth.
fn setHeadings(self: *ViewerPane, alloc: Allocator, items: []const bridge.Heading) void {
    const owned = alloc.alloc(Heading, items.len) catch return;
    var filled: usize = 0;
    for (items, 0..) |item, i| {
        const id = alloc.dupe(u8, item.id) catch return freeOwned(alloc, owned, filled);
        const text = alloc.dupe(u8, item.text) catch {
            alloc.free(id);
            return freeOwned(alloc, owned, filled);
        };
        owned[i] = .{ .id = id, .text = text, .level = item.level };
        filled += 1;
    }
    self.clearHeadings(alloc);
    self.headings = owned;

    // The render that produced these headings also reset the page's own
    // padding, so the next layout pass must re-push the gutter even when its
    // width did not change.
    self.toc_gutter_css = -1;
    if (self.toc) |panel| panel.setItems();
    self.updateTOC(alloc);
}

fn freeOwned(alloc: Allocator, owned: []Heading, filled: usize) void {
    for (owned[0..filled]) |h| {
        alloc.free(h.id);
        alloc.free(h.text);
    }
    alloc.free(owned);
}

/// Drop the heading list AND the active id. They go together on purpose: the
/// active id names a heading in this list, so keeping it across a new document
/// would highlight a row that no longer exists. The page re-reports it
/// immediately anyway — `indexHeadings` posts `headings` then `active`.
fn clearHeadings(self: *ViewerPane, alloc: Allocator) void {
    for (self.headings) |h| {
        alloc.free(h.id);
        alloc.free(h.text);
    }
    if (self.headings.len > 0) alloc.free(self.headings);
    self.headings = &.{};
    if (self.active_heading) |id| alloc.free(id);
    self.active_heading = null;

    // The panel's rows BORROW the ids just freed: rebuild them (to empty) in
    // the same breath, and retract the card — a document with no headings has
    // no contents. No script push here: the page this padding belonged to is
    // being replaced or torn down.
    if (self.toc) |panel| {
        panel.setItems();
        panel.hide();
    }
    self.toc_mode = .hidden;
    self.toc_open = false;
    self.toc_gutter_css = 0;
    if (self.nav) |nav| nav.setContentsButton(false);
}

fn setActiveHeading(self: *ViewerPane, alloc: Allocator, id: ?[]const u8) void {
    const dup: ?[]u8 = if (id) |v| (alloc.dupe(u8, v) catch return) else null;
    if (self.active_heading) |old| alloc.free(old);
    self.active_heading = dup;
    // The card's highlight follows the page's own reports — including the
    // pin a row click sets, which the page holds through its smooth scroll.
    if (self.toc) |panel| panel.syncActiveFromPane(true);
}

// -------------------------------------------------------------------------
// The table-of-contents card (T160)
// -------------------------------------------------------------------------

/// Recompute the card's presentation for the pane's current size and heading
/// list, place (or retract) the panel, and keep the page's gutter and the nav
/// bar's contents button in step. The one entry point — headings arriving,
/// bounds syncs, width drags and the overlay toggle all funnel here (Mac's
/// `updateSidePanelLayout`).
fn updateTOC(self: *ViewerPane, alloc: Allocator) void {
    const h = self.hwnd orelse return;
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(h, &r) == 0) return;
    const width = @max(r.right - r.left, 0);
    const height = @max(r.bottom - r.top, 0);
    var top: i32 = 0;
    if (self.nav_visible) {
        if (self.nav) |nav| {
            top = @min(
                nav_layout.Layout.init(self.scale, width, nav.shown()).bar_h,
                height,
            );
        }
    }
    // The card starts BELOW the composer, not behind it. Mac solves the same
    // problem by z-order (`composerDrawsAboveTheTOCCard`); here the two are
    // sibling child windows, so the honest fix is that the card's band starts
    // where the composer's ends — no overlap to resolve.
    if (self.feedback_open) {
        if (self.feedback) |bar| {
            top = @min(top + bar.barHeight(width, self.scale), height);
        }
    }

    const pane_w_dip = @as(f32, @floatFromInt(width)) / self.scale;
    const wanted = toc_layout.mode(pane_w_dip, self.headings.len);

    if (wanted == .hidden) {
        self.toc_mode = .hidden;
        self.toc_open = false;
        if (self.toc) |panel| panel.hide();
        if (self.nav) |nav| nav.setContentsButton(false);
        self.pushGutter(alloc, 0);
        return;
    }

    if (self.toc_width_dip == 0) self.toc_width_dip = viewer_prefs.loadWidth(alloc);
    if (self.toc == null) {
        self.toc = ViewerTOCPanel.create(alloc, self, self.hinstance, h);
        const panel = self.toc orelse {
            log.warn("viewer TOC panel could not be created; document has no contents card", .{});
            return;
        };
        panel.setItems();
    }
    const panel = self.toc.?;

    // Entering the compact layout closes the overlay (it opens only from its
    // button) and hands the bar its contents toggle; the pinning itself rides
    // the hover poll, which shows the bar and holds it open while compact.
    if (wanted == .compact and self.toc_mode != .compact) self.toc_open = false;
    self.toc_mode = wanted;
    if (self.nav) |nav| nav.setContentsButton(wanted == .compact);

    const visible = wanted == .gutter or self.toc_open;
    const placement = panel.place(
        self.scale,
        top,
        width,
        @max(height - top, 0),
        self.toc_width_dip,
        visible,
    );

    // Only the gutter reserves page space; the compact overlay floats over
    // the document the way a menu does.
    const css: f32 = if (placement.which == .gutter)
        toc_layout.gutterCssWidth(placement.card_w_dip)
    else
        0;
    self.pushGutter(alloc, css);
}

/// Hand the page how much left padding to reserve for the card (CSS px; the
/// page's device-pixel ratio makes CSS px == DIP). The card floats OVER the
/// web view rather than beside it — insetting the web view natively left a
/// seam of window background where the page's own background should be
/// (Mac's `pushSidePanelGutter`, and viewer.js's `setGutter` comment).
fn pushGutter(self: *ViewerPane, alloc: Allocator, css: f32) void {
    if (css == self.toc_gutter_css) return;
    if (!self.page_loaded) return;
    self.toc_gutter_css = css;
    var buf: [64]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, "window.__viewer.setGutter({d})", .{css}) catch return;
    self.executeScript(alloc, js);
}

/// The nav bar's contents button (compact layout only): slide the card in or
/// out. The open state is ephemeral by design.
pub fn toggleTOCPanel(self: *ViewerPane) void {
    const p = self.pending orelse return;
    if (self.toc_mode != .compact) return;
    self.toc_open = !self.toc_open;
    self.updateTOC(p.alloc);
}

/// A card row was clicked: scroll the page to that heading. The page's
/// `scrollToAnchor` PINS the scroll spy to the clicked heading for the length
/// of the smooth scroll — the highlight must not walk off the row the user
/// asked for — and posts the pinned id back as an `active` message, which is
/// what moves this side's selection. The user's next scroll gesture hands the
/// spy back (all of that lives in viewer.js; this side must not fight it).
pub fn tocRowClicked(self: *ViewerPane, id: []const u8) void {
    const p = self.pending orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(p.alloc);
    out.appendSlice(p.alloc, "window.__viewer.scrollToAnchor(") catch return;
    content.appendJsString(p.alloc, &out, id) catch return;
    out.append(p.alloc, ')') catch return;
    self.executeScript(p.alloc, out.items);

    // The overlay is a menu in the narrow layout: using it dismisses it.
    if (self.toc_mode == .compact and self.toc_open) {
        self.toc_open = false;
        self.updateTOC(p.alloc);
    }
}

/// A resize drag is moving the card's right edge (called continuously with
/// the absolute width the drag implies, so the card cannot drift from
/// accumulated deltas). The card, the handle, and the page's gutter all
/// derive from this — one layout pass moves all three together.
pub fn setTOCWidthLive(self: *ViewerPane, proposed_dip: f32) void {
    const p = self.pending orelse return;
    const h = self.hwnd orelse return;
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(h, &r) == 0) return;
    const pane_w_dip = @as(f32, @floatFromInt(r.right - r.left)) / self.scale;
    const clamped = toc_layout.clampWidth(proposed_dip, pane_w_dip);
    if (clamped == self.toc_width_dip) return;
    self.toc_width_dip = clamped;
    self.updateTOC(p.alloc);
}

/// The resize drag ended: the chosen width is worth persisting. Saved once on
/// mouse-up rather than per pixel of drag (Mac's `onDragEnded`).
pub fn commitTOCWidth(self: *ViewerPane) void {
    const p = self.pending orelse return;
    if (self.toc_width_dip > 0) viewer_prefs.saveWidth(p.alloc, self.toc_width_dip);
}

/// Install the P2 blob and subscribe to what it posts back.
///
/// Non-fatal in both halves, and for the same reason `subscribeNewWindowRequested`
/// is: a pane that cannot inject still shows its page, it just has no selection
/// toolbar. Called from `adoptController` BEFORE the first navigation — a script
/// added after a page has started loading does not reach that page.
fn subscribeBridge(self: *ViewerPane) void {
    std.debug.assert(self.web_message_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const alloc = p.alloc;
    const web = c.coreWebView() orelse return;
    defer web.release();

    // The blob is ~12 KB of ASCII and the API wants UTF-16. Converted here
    // rather than at comptime so the pure module stays free of a 12 k-iteration
    // comptime loop; it runs once per pane and the buffer is transient because
    // `AddScriptToExecuteOnDocumentCreated` copies the string.
    if (std.unicode.utf8ToUtf16LeAllocZ(alloc, bridge.injected_js)) |wide| {
        defer alloc.free(wide);
        if (AddScriptCompletedHandler.create(alloc, p)) |handler| {
            p.refs += 1;
            defer handler.release(); // takes the borrowed token reference if it was the last
            if (!web.addScriptToExecuteOnDocumentCreated(wide.ptr, @ptrCast(handler))) {
                log.warn("AddScriptToExecuteOnDocumentCreated was refused; no quoting in this pane", .{});
            }
        } else |_| {}
    } else |_| {
        log.warn("could not widen the viewer bridge script; no quoting in this pane", .{});
    }

    const handler = WebMessageReceivedHandler.create(alloc, p) catch return;
    // The token reference the handler borrows. Taken BEFORE the object can
    // reach a runtime that might release it.
    p.refs += 1;
    if (!web.addWebMessageReceived(@ptrCast(handler))) {
        log.warn("add_WebMessageReceived failed; the page cannot talk back", .{});
        handler.release(); // takes the borrowed token reference with it
        return;
    }
    self.web_message_handler = handler;
}

// -------------------------------------------------------------------------
// File mode (T90e, design §5/§6)
//
// A file-mode pane loads the BUNDLED TEMPLATE from a synthetic origin and gets
// its content injected afterwards. Two subscriptions make that work:
//
//   * `WebResourceRequested` serves every request the template makes —
//     `viewer.html` itself, its stylesheets, its vendored scripts, and any
//     image the rendered markdown references — out of the three tiers
//     `viewer_content.zig` computes. Nothing reaches the network; the origin
//     does not exist in DNS.
//   * `NavigationCompleted` is when `window.__viewer` exists, so it is when
//     the file's bytes can be handed over.
// -------------------------------------------------------------------------

/// `ICoreWebView2WebResourceRequestedEventHandler`.
const WebResourceRequestedHandler = com.CallbackOwning(
    iface.IID_WebResourceRequestedHandler,
    onWebResourceRequested,
    releasePendingToken,
);

/// `ICoreWebView2NavigationCompletedEventHandler`.
const NavigationCompletedHandler = com.CallbackOwning(
    iface.IID_NavigationCompletedHandler,
    onNavigationCompleted,
    releasePendingToken,
);

/// `ICoreWebView2ExecuteScriptCompletedHandler`. Nothing to do on success; the
/// slot exists so a failure to inject is a log line rather than a blank pane
/// with no explanation.
const ExecuteScriptCompletedHandler = com.CallbackOwning(
    iface.IID_ExecuteScriptCompletedHandler,
    onExecuteScriptCompleted,
    releasePendingToken,
);

fn onExecuteScriptCompleted(p: *Pending, result: com.HRESULT, value: ?[*:0]const u16) com.HRESULT {
    _ = p;
    _ = value;
    if (com.failed(result)) log.warn(
        "ExecuteScript failed hr=0x{X:0>8}; the pane will show an empty document",
        .{@as(u32, @bitCast(result))},
    );
    return com.S_OK;
}

/// Register the resource interception and the navigation hook on a freshly
/// adopted controller.
///
/// Both are registered for EVERY pane, web mode included, rather than only for
/// file panes: a pane navigates between the two over its life, and a
/// subscription that has to be added later would have to be added from inside
/// a navigation. The filter matches only our synthetic origin, so a pane
/// showing a website never sees a resource event.
fn subscribeFileMode(self: *ViewerPane) void {
    std.debug.assert(self.resource_handler == null);
    std.debug.assert(self.navigation_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    resources: {
        const handler = WebResourceRequestedHandler.create(p.alloc, p) catch break :resources;
        p.refs += 1;
        // The filter FIRST: with no filter registered the event never fires,
        // and a handler added to an unfiltered view is a silent no-op rather
        // than an error.
        const filter = std.unicode.utf8ToUtf16LeStringLiteral(content.resource_filter);
        if (!web.addWebResourceRequestedFilter(filter, .all)) {
            log.warn("AddWebResourceRequestedFilter failed; file viewers cannot load", .{});
            handler.release();
            break :resources;
        }
        // The PAGE host (T601), registered alongside rather than instead: the
        // two origins are served from different roots, and a pane crosses
        // between them over its life (a markdown doc linking to an html file,
        // and Back out of it again).
        //
        // A failure here is NOT fatal to the subscription, unlike the one
        // above: it costs rendered `.html` panes and nothing else, and taking
        // markdown down with it would trade one mode for two.
        const page_filter = std.unicode.utf8ToUtf16LeStringLiteral(content.page_resource_filter);
        if (!web.addWebResourceRequestedFilter(page_filter, .all)) {
            log.warn("AddWebResourceRequestedFilter failed; .html files cannot render", .{});
        }
        if (!web.addWebResourceRequested(@ptrCast(handler))) {
            log.warn("add_WebResourceRequested failed; file viewers cannot load", .{});
            handler.release();
            break :resources;
        }
        self.resource_handler = handler;
    }

    const handler = NavigationCompletedHandler.create(p.alloc, p) catch return;
    p.refs += 1;
    if (!web.addNavigationCompleted(@ptrCast(handler))) {
        log.warn("add_NavigationCompleted failed; file content cannot be injected", .{});
        handler.release();
        return;
    }
    self.navigation_handler = handler;
}

fn onNavigationCompleted(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2NavigationCompletedEventArgs,
) com.HRESULT {
    _ = sender;
    const self = p.pane orelse return com.S_OK;
    // A failed load has no `window.__viewer` to call, and injecting into
    // Chromium's own error page would throw in someone else's document. It is
    // also not a page `+reload` may re-render into, which is why the flag is
    // set AFTER this check and for both modes (T390).
    if (args) |a| if (!a.isSuccess()) {
        log.warn(
            "viewer navigation did not complete (status={?d}); no content injected",
            .{a.webErrorStatus()},
        );
        return com.S_OK;
    };
    self.page_loaded = true;
    // A fresh document has no selection, and the outgoing one's last tracked
    // selection can still be in flight when this lands — its `postMessage` was
    // queued before the old page went away (T636). Clearing HERE, at the point
    // the new document exists, is what keeps the previous page's highlight out
    // of the next report.
    self.setPageSelection(p.alloc, null);
    // Keyboard page zoom survives navigation (T161): re-push a non-default
    // factor so following a link or reloading keeps the chosen zoom — the
    // same re-apply Mac does after `didFinish`.
    if (self.zoom_factor != 1.0) self.pushZoom();
    // A rendered `.html` file has nothing to inject either — the web view
    // loaded the page, and the page is the content (T601). The one exception is
    // the fallback, where the template is on screen precisely so the pane can
    // say which file it could not read.
    if (self.mode == .html) {
        if (self.html_fallback) self.injectError(
            p.alloc,
            content.error_unreadable,
            self.file_path orelse self.location orelse "",
        );
        return com.S_OK;
    }
    // Web mode has nothing to inject — the page IS the content.
    if (!self.mode.usesTemplate()) return com.S_OK;
    self.renderFileContent();
    return com.S_OK;
}

// -------------------------------------------------------------------------
// Link routing (T392, design row 5; Mac `decidePolicyFor` + `handleFileModeLink`)
// -------------------------------------------------------------------------

/// `ICoreWebView2NavigationStartingEventHandler`: a top-level navigation is
/// about to happen, and file mode gets to say no.
const NavigationStartingHandler = com.CallbackOwning(
    iface.IID_NavigationStartingHandler,
    onNavigationStarting,
    releasePendingToken,
);

/// Test seam (the live host-floor test only): when set, every routed link is
/// RECORDED here as `<kind>:<target>` instead of reaching `ShellExecuteW` or
/// the split tree. The test must observe routing without opening the user's
/// real browser over a green lane — and a bare test pane has no split tree to
/// open a viewer into anyway.
const LinkSink = struct {
    alloc: Allocator,
    entries: std.ArrayList([]u8) = .empty,

    fn append(self: *LinkSink, kind: []const u8, target: []const u8) void {
        const s = std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ kind, target }) catch return;
        self.entries.append(self.alloc, s) catch self.alloc.free(s);
    }

    fn deinit(self: *LinkSink) void {
        for (self.entries.items) |e| self.alloc.free(e);
        self.entries.deinit(self.alloc);
    }
};
var link_sink: ?*LinkSink = null;

fn onNavigationStarting(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2NavigationStartingEventArgs,
) com.HRESULT {
    _ = sender;
    const a = args orelse return com.S_OK;
    const self = p.pane orelse return com.S_OK;

    const raw = a.uriRaw() orelse return com.S_OK;
    // The runtime allocated it on the COM heap; we free it on ours.
    defer w32.CoTaskMemFree(@ptrCast(raw));
    const uri = std.unicode.utf16LeToUtf8Alloc(p.alloc, std.mem.span(raw)) catch return com.S_OK;
    defer p.alloc.free(uri);

    const class = content.classifyLink(self.mode, uri);

    // A `ghoztty://` link is answered in EVERY mode and for every navigation
    // kind, which is why the URI is read before the two gates below (T695).
    // WebView2 cannot load the scheme at all, so letting a website pane's
    // navigation through would be a dead click rather than a passthrough.
    if (class == .ghoztty_command) {
        _ = a.setCancel(true);
        self.focusLinkTarget(uri);
        return com.S_OK;
    }

    // Websites — and rendered `.html` files, which are pages (T601) — navigate
    // freely within the pane, and so do the pane's own reloads and history
    // walks (`syncCommitted` reconciles those after the fact).
    if (self.mode.isLivePage()) return com.S_OK;
    if (!content.routesAsLink(navKind(a))) return com.S_OK;

    switch (class) {
        .ghoztty_command => unreachable, // answered above, in every mode
        .allow => {},
        .browser => {
            _ = a.setCancel(true);
            self.openExternal(p.alloc, uri);
        },
        .relative => {
            _ = a.setCancel(true);
            self.openRelativeLink(p.alloc, uri);
        },
        .file_url => {
            _ = a.setCancel(true);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (content.filePath(&buf, uri)) |path| {
                self.dispatchFileLink(p.alloc, path);
            }
        },
        // Mac's nil-fileURL return: cancelled, and nothing else happens.
        .drop => _ = a.setCancel(true),
    }
    return com.S_OK;
}

/// The navigation kind, or null on a runtime whose args predate
/// `ICoreWebView2NavigationStartingEventArgs3`.
fn navKind(a: *iface.ICoreWebView2NavigationStartingEventArgs) ?content.NavKind {
    const a3 = a.queryArgs3() orelse return null;
    defer a3.release();
    return switch (a3.navigationKind() orelse return null) {
        .reload => .reload,
        .back_or_forward => .back_or_forward,
        .new_document => .new_document,
        // A kind this build does not know is a kind the policy has no claim
        // about — but it is also not one of the two the pane issues about
        // itself, so it routes the way an unknown runtime does.
        _ => null,
    };
}

/// A clicked RELATIVE link (`https://ghoztty-viewer/<rel>`): resolve it next
/// to the viewed file, and only an existing file opens — Mac's
/// `resolveForNavigation`, existence checks included.
fn openRelativeLink(self: *ViewerPane, alloc: Allocator, uri: []const u8) void {
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = content.requestPath(&rel_buf, uri) orelse return;
    const fp = self.file_path orelse return;
    const base = content.baseDirectory(fp) orelse return;

    const first = self.takeIfFile(alloc, content.navCandidate(alloc, base, rel) catch null);
    const path = first orelse
        self.takeIfFile(alloc, content.rootedCandidate(alloc, base, rel) catch null) orelse {
        // Mac returns silently here; the log line is our one addition,
        // because "I clicked and nothing happened" should leave a trace.
        log.info("viewer link names no existing file: {s}", .{rel});
        return;
    };
    defer alloc.free(path);
    self.dispatchFileLink(alloc, path);
}

/// Open a routed FILE target: markdown as a viewer split next to this pane,
/// anything else with its default app (Mac `handleFileModeLink`'s switch).
fn dispatchFileLink(self: *ViewerPane, alloc: Allocator, path: []const u8) void {
    switch (content.fileLinkAction(path)) {
        .viewer_split => {
            if (link_sink) |s| return s.append("split", path);
            self.openLinkedViewerSplit(path);
        },
        .default_app => {
            if (link_sink) |s| return s.append("app", path);
            self.shellOpen(alloc, path);
        },
    }
}

/// Open another viewer as a split to the RIGHT of this pane (Mac
/// `openViewerSplit`), through the trampoline `Window.createViewerPane`
/// installed. A pane that is not in a tree — a bare unit-test pane — has
/// neither a leaf nor a trampoline, and does nothing.
///
/// The origin travels with the link: a pane opened from a link in this one
/// inherits this one's origin, so a chain of doc links keeps the same
/// provenance (Mac passes `originDirectory` for the same reason).
fn openLinkedViewerSplit(self: *ViewerPane, location: []const u8) void {
    const pv = self.pane_view orelse return;
    const open = self.open_link_split orelse return;
    open(pv, location, self.origin_directory);
}

/// A `ghoztty://` link clicked in this pane's page: raise what it names, in
/// process (T695). Never leaves the app and never navigates — the pane keeps
/// showing what it was showing.
fn focusLinkTarget(self: *ViewerPane, url: []const u8) void {
    if (link_sink) |s| return s.append("focus", url);
    const pv = self.pane_view orelse return;
    const window = pv.parentWindow();
    _ = window.app.handleUrlSchemeLink(window.hwnd, self.scale, url);
}

/// Hand `target` (a URL or a file path) to the shell — the default browser
/// for the one, the default app for the other. The same call answers both
/// because that is what `ShellExecuteW(open)` is.
fn openExternal(self: *ViewerPane, alloc: Allocator, url: []const u8) void {
    if (link_sink) |s| return s.append("browser", url);
    self.shellOpen(alloc, url);
}

fn shellOpen(self: *ViewerPane, alloc: Allocator, target: []const u8) void {
    _ = self;
    // A test binary must never reach the shell (T594): `ShellExecuteW(open)`
    // launches the user's default browser in the INTERACTIVE session no matter
    // which desktop the test runs on, so a handoff that escapes a green lane
    // is a real Edge window left on the user's screen. Recorded when the test
    // installed a sink; loud otherwise — never executed.
    if (builtin.is_test) {
        if (link_sink) |s| return s.append("shell", target);
        log.err("test build refused to shell-open: {s}", .{target});
        return;
    }
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, target) catch return;
    defer alloc.free(wide);
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        wide,
        null,
        null,
        w32.SW_SHOW,
    );
}

/// Register the routing handler on a freshly adopted controller. Registered
/// for EVERY pane, web mode included, for the reason the title handler is: a
/// web pane becomes a file pane the moment the user types a path, and a
/// subscription installed only for the starting mode would be dead by then.
/// Non-fatal like every subscription — a pane without it follows file-mode
/// links in place, which is degraded, not broken.
fn subscribeNavigationStarting(self: *ViewerPane) void {
    std.debug.assert(self.navigation_starting_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const handler = NavigationStartingHandler.create(p.alloc, p) catch return;
    p.refs += 1;
    if (!web.addNavigationStarting(@ptrCast(handler))) {
        log.warn("add_NavigationStarting failed; file-mode links navigate in place", .{});
        handler.release(); // takes the borrowed token reference with it
        return;
    }
    self.navigation_starting_handler = handler;
}

/// Reload this pane's content in place: the `+reload` verb, and (T391) the
/// file watcher's re-render. Mac's `ViewerView.reloadContent`, whose three-way
/// branch lives in `viewer_content.reloadPlan` so it is checkable without a
/// browser.
///
/// Safe to call in any state — a pane with no controller has no completed load
/// either, so it takes the `full_load` branch, and `applyNavigation` is already
/// a no-op until there is something to navigate.
pub fn reloadContent(self: *ViewerPane, reason: content.ReloadReason) void {
    // An html pane sitting on the fallback template has no page to reload: the
    // file it wants is the one that was missing, so the recovery is to try the
    // navigation again — which is exactly what a save of that file should do.
    if (self.mode == .html and self.html_fallback) {
        if (self.pending) |p| self.syncHtmlGrant(p.alloc);
        self.applyNavigation();
        return;
    }
    switch (content.reloadPlan(self.mode, self.page_loaded, reason)) {
        .full_load => self.applyNavigation(),
        .rerender => self.renderFileContent(),
        .refetch => self.refetchFromOrigin(),
        .reload_in_place => self.reloadInPlace(),
    }
}

/// A plain reload: the page is re-fetched, its history entry is replaced rather
/// than pushed, and the engine restores the scroll offset across it.
///
/// This is what a SAVE does to a rendered `.html` file (T601) — Mac's `reload()`
/// against its `reloadFromOrigin()`. Editing a long page must not throw the
/// reader back to the top of it, and page-host responses carry
/// `Cache-Control: no-store`, so "plain" still means the bytes now on disk.
fn reloadInPlace(self: *ViewerPane) void {
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();
    if (!web.reload()) log.warn("Reload failed for this pane", .{});
}

/// Re-fetch the current web page from its ORIGIN, bypassing caches.
///
/// `Reload()` is a normal reload and may serve the cache, which is the answer
/// the user ran `+reload` to get rid of; DevTools' `Page.reload` with
/// `ignoreCache` is the only way to say it through this API. The plain reload
/// stays as the fallback because a refused DevTools call must still reload the
/// page rather than do nothing (design P8).
fn refetchFromOrigin(self: *ViewerPane) void {
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const method = std.unicode.utf8ToUtf16LeStringLiteral(content.devtools_reload_method);
    const params = std.unicode.utf8ToUtf16LeStringLiteral(content.devtools_reload_params);
    if (web.callDevToolsProtocolMethod(method, params, null)) return;

    log.warn("Page.reload was refused; falling back to a cache-allowed reload", .{});
    if (!web.reload()) log.warn("Reload failed for this pane", .{});
}

/// Read the viewed file and hand it to the page. Every failure below ends in
/// the page's own error card rather than a blank pane: a viewer that shows
/// nothing and says nothing is indistinguishable from one that is still
/// loading.
fn renderFileContent(self: *ViewerPane) void {
    const p = self.pending orelse return;
    const alloc = p.alloc;
    // A diff has no file to read: its content comes from git, asynchronously,
    // and arrives on `WM_APP_VIEWER_DIFF` (T463). The page is ready NOW, which
    // is what this call means, so this is where the first listing is asked for
    // — and why `diff_pushed` is cleared by every navigation: a freshly-loaded
    // page must be handed the listing even when git's answer has not moved.
    if (self.mode == .diff) {
        self.diff_pushed = false;
        self.refreshDiff();
        return;
    }
    const path = self.file_path orelse {
        self.injectError(alloc, content.error_unreadable, self.location orelse "");
        return;
    };

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, content.max_file_bytes) catch |err| {
        self.injectError(alloc, switch (err) {
            error.FileTooBig => content.error_too_large,
            else => content.error_unreadable,
        }, path);
        return;
    };
    defer alloc.free(bytes);

    // A UTF-8 BOM is invisible to the reader and NOT invisible to the
    // renderer: left in place it becomes a stray glyph ahead of the first
    // heading, and Windows editors write one routinely. Dropped here rather
    // than in the page, so both platforms' renderers stay one file.
    var text = bytes;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    // Mac's `String(data:encoding:.utf8)` returning nil is exactly this check;
    // a binary file opened by mistake gets a card, not mojibake.
    if (!std.unicode.utf8ValidateSlice(text)) {
        self.injectError(alloc, content.error_not_text, path);
        return;
    }

    const js = switch (self.mode) {
        .markdown => content.setMarkdownCall(alloc, text),
        .code => content.setCodeCall(
            alloc,
            text,
            content.highlightLanguage(content.extension(path)),
        ),
        // Neither has content to inject: a website is its own page, and so is a
        // rendered `.html` file (T601) — the web view loaded it directly. A
        // diff answered above, before there was a file path to fail on.
        .web, .html, .diff => return,
    } catch return;
    defer alloc.free(js);
    self.executeScript(alloc, js);
}

fn injectError(self: *ViewerPane, alloc: Allocator, title: []const u8, detail: []const u8) void {
    log.warn("viewer file error: {s} ({s})", .{ title, detail });
    const js = content.setErrorCall(alloc, title, detail) catch return;
    defer alloc.free(js);
    self.executeScript(alloc, js);
}

fn executeScript(self: *ViewerPane, alloc: Allocator, js: []const u8) void {
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, js) catch {
        log.warn("could not widen the viewer content script", .{});
        return;
    };
    defer alloc.free(wide);

    const handler = ExecuteScriptCompletedHandler.create(alloc, p) catch return;
    p.refs += 1;
    defer handler.release();
    _ = web.executeScript(wide.ptr, @ptrCast(handler));
}

/// Serve one request the bundled template made. Runs on the GUI thread, off
/// the message loop, and is synchronous by design — every answer is a file
/// read off local disk, so there is nothing worth a deferral.
fn onWebResourceRequested(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2WebResourceRequestedEventArgs,
) com.HRESULT {
    _ = sender;
    const a = args orelse return com.S_OK;
    const self = p.pane orelse return com.S_OK;
    const env = self.env orelse return com.S_OK;
    const alloc = p.alloc;

    const req = a.request() orelse return com.S_OK;
    defer req.release();
    const raw = req.uriRaw() orelse return com.S_OK;
    defer w32.CoTaskMemFree(@ptrCast(raw));

    var uri_buf: [4096]u8 = undefined;
    const uri_len = std.unicode.utf16LeToUtf8(&uri_buf, std.mem.span(raw)) catch return com.S_OK;
    const uri = uri_buf[0..uri_len];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // The PAGE host first (T601), and served from its own root alone: the
    // viewed file's directory, recursively. It deliberately does NOT fall
    // through to the bundled-assets tier — a page asking for `viewer.css` must
    // get its own or nothing, never ours.
    if (content.pageRequestPath(&path_buf, uri)) |rel| {
        self.servePageResource(env, a, alloc, rel);
        return com.S_OK;
    }

    const rel = content.requestPath(&path_buf, uri) orelse {
        // Not ours after all: leave the request alone rather than answering it
        // with a 404 we have no business sending.
        return com.S_OK;
    };

    const resolved = self.resolveResource(alloc, rel) orelse {
        // Chromium asks every origin for a favicon it was never offered, so
        // that one miss is expected and would otherwise put a warning in the
        // log on every single page load.
        if (!std.mem.eql(u8, rel, "favicon.ico")) {
            log.warn("viewer resource not found: {s}", .{rel});
        }
        self.respond(env, a, alloc, "", "text/plain", 404, not_found_reason, .default);
        return com.S_OK;
    };
    defer alloc.free(resolved);

    const bytes = std.fs.cwd().readFileAlloc(alloc, resolved, content.max_file_bytes) catch {
        log.warn("viewer resource is unreadable: {s}", .{resolved});
        self.respond(env, a, alloc, "", "text/plain", 404, not_found_reason, .default);
        return com.S_OK;
    };
    defer alloc.free(bytes);

    self.respond(
        env,
        a,
        alloc,
        bytes,
        content.mimeType(content.extension(rel)),
        200,
        ok_reason,
        .default,
    );
    return com.S_OK;
}

const ok_reason = std.unicode.utf8ToUtf16LeStringLiteral("OK");
const not_found_reason = std.unicode.utf8ToUtf16LeStringLiteral("Not Found");

/// Answer one request a rendered `.html` page made (T601), from the pane's read
/// grant and nothing else.
///
/// One tier, not three: `candidateUnder` against `html_root`, which is exactly
/// the "the file's own directory, recursively" grant Mac passes to
/// `loadFileURL(allowingReadAccessTo:)`. A page reaching UP out of its folder
/// (`../shared/app.css`) is refused, which is the documented cost of a
/// narrow-by-default grant: widening one later is easy, taking one back is not.
///
/// Every answer is `no-store`. A local page is edited and re-saved while it is
/// on screen, so a cached response is a wrong answer that looks exactly like a
/// right one — and it is what lets a plain in-place reload (which keeps the
/// reader's scroll) still show the bytes now on disk.
fn servePageResource(
    self: *ViewerPane,
    env: *iface.ICoreWebView2Environment,
    a: *iface.ICoreWebView2WebResourceRequestedEventArgs,
    alloc: Allocator,
    rel: []const u8,
) void {
    const root = self.html_root orelse {
        // No grant means no page: a request on this host with nothing behind it
        // is a stale load from a pane that has since moved on.
        self.respond(env, a, alloc, "", "text/plain", 404, not_found_reason, .no_store);
        return;
    };
    const resolved = self.takeIfFile(alloc, content.candidateUnder(alloc, root, rel) catch null) orelse {
        // Chromium asks every origin for a favicon it was never offered.
        if (!std.mem.eql(u8, rel, "favicon.ico")) {
            log.warn("viewer page resource not found or outside its grant: {s}", .{rel});
        }
        self.respond(env, a, alloc, "", "text/plain", 404, not_found_reason, .no_store);
        return;
    };
    defer alloc.free(resolved);

    const bytes = std.fs.cwd().readFileAlloc(alloc, resolved, content.max_file_bytes) catch {
        log.warn("viewer page resource is unreadable: {s}", .{resolved});
        self.respond(env, a, alloc, "", "text/plain", 404, not_found_reason, .no_store);
        return;
    };
    defer alloc.free(bytes);

    // A subresource request is proof the page was PARSED as HTML: a document
    // rendered as source never asks for its own stylesheet. That is what the
    // acceptance harness reads, so it is logged at info rather than debug.
    log.info("viewer page pane={s} served={s} bytes={d}", .{ self.paneId(), rel, bytes.len });
    self.respond(
        env,
        a,
        alloc,
        bytes,
        content.mimeType(content.extension(rel)),
        200,
        ok_reason,
        .no_store,
    );
}

/// The 3-tier resolution (design §6, Mac's `ViewerSchemeHandler.resolve`):
/// bundled assets, then the viewed file's directory, then an absolute
/// reference the document wrote itself. Returns the first candidate that is a
/// readable FILE — a directory is not a resource, and answering with one would
/// be a read error dressed up as a hit. Caller owns the result.
fn resolveResource(self: *ViewerPane, alloc: Allocator, rel: []const u8) ?[]u8 {
    if (self.resources_dir) |root| {
        if (self.takeIfFile(alloc, content.candidateUnder(alloc, root, rel) catch null)) |hit| return hit;
    }
    const base = if (self.file_path) |p| content.baseDirectory(p) else null;
    if (base) |root| {
        if (self.takeIfFile(alloc, content.candidateUnder(alloc, root, rel) catch null)) |hit| return hit;
        if (self.takeIfFile(alloc, content.rootedCandidate(alloc, root, rel) catch null)) |hit| return hit;
    }
    return null;
}

fn takeIfFile(self: *ViewerPane, alloc: Allocator, candidate: ?[]u8) ?[]u8 {
    _ = self;
    const path = candidate orelse return null;
    const stat = std.fs.cwd().statFile(path) catch {
        alloc.free(path);
        return null;
    };
    if (stat.kind != .file) {
        alloc.free(path);
        return null;
    }
    return path;
}

/// Answer an intercepted request with `bytes`.
///
/// The body has to be an `IStream`, which is what `CreateWebResourceResponse`
/// takes, and `CreateStreamOnHGlobal` leaves the seek pointer where `Write`
/// left it — at the END. Rewinding is not tidiness: without it the response is
/// a zero-byte body that reports success, which renders as a blank page with
/// no error anywhere.
const Caching = enum { default, no_store };

fn respond(
    self: *ViewerPane,
    env: *iface.ICoreWebView2Environment,
    args: *iface.ICoreWebView2WebResourceRequestedEventArgs,
    alloc: Allocator,
    bytes: []const u8,
    mime: []const u8,
    status: i32,
    reason: [*:0]const u16,
    caching: Caching,
) void {
    _ = self;
    var stream_ptr: ?*anyopaque = null;
    if (com.failed(w32.CreateStreamOnHGlobal(null, 1, &stream_ptr))) return;
    const stream: *iface.IStream = @ptrCast(@alignCast(stream_ptr orelse return));
    defer stream.release();
    if (!stream.writeAll(bytes)) return;
    if (!stream.rewind()) return;

    // The runtime parses a CRLF-joined header block, not a single header.
    const headers = std.fmt.allocPrint(alloc, "Content-Type: {s}{s}", .{
        mime,
        switch (caching) {
            .default => "",
            .no_store => "\r\nCache-Control: no-store",
        },
    }) catch return;
    defer alloc.free(headers);
    const headers_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, headers) catch return;
    defer alloc.free(headers_w);

    const response = env.createWebResourceResponse(stream, status, reason, headers_w.ptr) orelse {
        log.warn("CreateWebResourceResponse failed", .{});
        return;
    };
    defer response.release();
    _ = args.setResponse(response);
}

/// Push the OS color scheme into the page (T90a design §14). Called for every
/// pane by `Window.reportColorScheme`, and again for this pane as soon as its
/// controller arrives.
pub fn setColorScheme(self: *ViewerPane, dark: bool) void {
    self.color_scheme = if (dark) .dark else .light;
    self.applyColorScheme();
    // The bar's palette derives from the pane background, which does not
    // move with the OS scheme — but re-deriving here is cheap and keeps the
    // chrome honest if a config reload ever changes the background underneath.
    if (self.nav) |nav| nav.applyTheme();
    if (self.feedback) |bar| bar.applyTheme();
    // The TOC card's palette DOES follow the scheme: it sits on the document,
    // whose background is the page's own light/dark.
    if (self.toc) |panel| panel.applyTheme();
}

fn applyColorScheme(self: *ViewerPane) void {
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();
    // A runtime older than revision 13 has no profile to set it on. AUTO
    // (follow the OS) is the documented degrade and it is nearly right, so
    // this is a debug log, not a warning.
    const v13 = web.queryV13() orelse {
        log.debug("runtime has no ICoreWebView2_13; color scheme stays AUTO", .{});
        return;
    };
    defer v13.release();
    const profile = v13.profile() orelse return;
    defer profile.release();
    _ = profile.setPreferredColorScheme(self.color_scheme);
}

/// Re-read the host window's DPI and push it as the rasterization scale.
fn readScale(self: *ViewerPane) void {
    const h = self.hwnd orelse return;
    const dpi = w32.GetDpiForWindow(h);
    if (dpi == 0) return;
    const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    if (scale == self.scale) return;
    self.scale = scale;
    self.pushRasterizationScale();
}

fn pushRasterizationScale(self: *ViewerPane) void {
    const c = self.controller orelse return;
    const c3 = c.queryV3() orelse return;
    defer c3.release();
    _ = c3.setRasterizationScale(self.scale);
}

// -------------------------------------------------------------------------
// Hero-mode thumbnails (T397)
// -------------------------------------------------------------------------

/// `ICoreWebView2CapturePreviewCompletedHandler`. One-shot, created per
/// capture; the `Pending` token is what makes it safe for a pane to be closed
/// while the browser process is still encoding.
const CapturePreviewHandler = com.CallbackOwning(
    iface.IID_CapturePreviewCompletedHandler,
    onCapturePreviewCompleted,
    releasePendingToken,
);

/// How long a viewer thumbnail is allowed to be stale before the heartbeat
/// takes another (T397).
///
/// The terminal cadence — every 150ms, Mac's number — is wrong here and the
/// reason is the transport, not taste. A terminal snapshot is a GL readback
/// into a buffer the renderer thread already owns; a viewer snapshot is a
/// full-page PNG *encoded* by the browser process and *decoded* by GDI+ on our
/// GUI thread, so running it at 150ms would spend a chunk of every frame on a
/// picture of a document that has not moved. Two seconds keeps a thumbnail
/// that visibly tracks the page for well under 1% of the GUI thread. A size
/// change or a fresh capture request jumps the queue regardless.
const snap_min_interval_ms: i64 = 2000;

/// Ask the browser for a thumbnail at `w`x`h` device pixels, if one is due.
///
/// Called from the carousel's 150ms heartbeat like a terminal's, and drops
/// most of those calls on the floor: nothing to capture into without a
/// controller, nothing to gain while one is already in flight, and nothing to
/// see when the last one was asked for recently AND at this same size.
pub fn heroSnapRequest(self: *ViewerPane, w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    if (self.snap_in_flight) return;
    const want_w: i32 = @intCast(@min(w, @as(u32, std.math.maxInt(i32))));
    const want_h: i32 = @intCast(@min(h, @as(u32, std.math.maxInt(i32))));

    const now = std.time.milliTimestamp();
    const resized = want_w != self.snap_w or want_h != self.snap_h;
    if (!resized) {
        const age = now - self.snap_asked_ms;
        if (age >= 0 and age < snap_min_interval_ms) return;
    }
    self.snap_w = want_w;
    self.snap_h = want_h;
    // Stamped on the ATTEMPT, not on success. A capture that keeps failing —
    // a runtime too old for the slot, a view with no frame yet — would
    // otherwise miss the floor entirely (there is no thumbnail, so nothing
    // says "recent") and re-ask on all seven ticks a second, forever.
    self.snap_asked_ms = now;

    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    // The stream outlives this call — the runtime writes into it on its own
    // schedule — so it hangs off the pane, which is the thing whose lifetime
    // the completion handler already has to survive.
    self.releaseSnapStream();
    var stream_ptr: ?*anyopaque = null;
    if (com.failed(w32.CreateStreamOnHGlobal(null, 1, &stream_ptr))) return;
    const stream: *iface.IStream = @ptrCast(@alignCast(stream_ptr orelse return));
    self.snap_stream = stream;

    const handler = CapturePreviewHandler.create(p.alloc, p) catch {
        self.releaseSnapStream();
        return;
    };
    p.refs += 1;
    // Ours; the runtime takes its own. Releasing here frees it outright when
    // the call below fails before AddRef-ing, which is the point.
    defer handler.release();

    if (!web.capturePreview(.png, stream, @ptrCast(handler))) {
        log.warn("CapturePreview failed to start; viewer tile keeps its placeholder", .{});
        self.releaseSnapStream();
        // NOT `p.release()` here: the deferred `handler.release()` above frees
        // the handler outright (the call failed before any AddRef), and
        // `CallbackOwning`'s zero-hook gives the token reference back as it
        // goes. Releasing here too would decrement it twice.
        return;
    }
    self.snap_in_flight = true;
}

fn onCapturePreviewCompleted(p: *Pending, result: com.HRESULT) com.HRESULT {
    const self = p.pane orelse return com.S_OK;
    self.snap_in_flight = false;
    defer self.releaseSnapStream();

    if (com.failed(result)) {
        log.warn(
            "CapturePreview hr=0x{X:0>8}; viewer tile keeps its previous picture",
            .{@as(u32, @bitCast(result))},
        );
        return com.S_OK;
    }
    const stream = self.snap_stream orelse return com.S_OK;
    // The runtime leaves the seek pointer at the END, exactly as `respond`
    // documents for the resource-response stream. A decoder handed that reads
    // zero bytes and reports a corrupt image.
    if (!stream.rewind()) return com.S_OK;

    const thumb = gdiplus_decode.decodeScaled(@ptrCast(stream), self.snap_w, self.snap_h) orelse
        return com.S_OK;
    if (self.snap_dib) |old| _ = w32.DeleteObject(old);
    self.snap_dib = thumb.dib;
    self.snap_dib_w = thumb.w;
    self.snap_dib_h = thumb.h;
    self.snap_dirty = true;
    log.debug("hero snap committed hwnd={?} kind=viewer {}x{}", .{ self.hwnd, thumb.w, thumb.h });

    // Same wake-up the renderer thread posts, so one path on the Window side
    // publishes and invalidates whichever kind of leaf produced the picture.
    if (self.hwnd) |h| _ = w32.PostMessageW(
        self.parent_window.hwnd orelse return com.S_OK,
        Window.WM_APP_HERO_SNAP,
        @intFromPtr(h),
        0,
    );
    return com.S_OK;
}

/// GUI thread, on `WM_APP_HERO_SNAP`: true when a newly decoded thumbnail is
/// waiting to be painted. The decode already happened on this thread, so
/// unlike a terminal's there is nothing left to copy — only the edge to report.
pub fn heroSnapPublish(self: *ViewerPane) bool {
    if (!self.snap_dirty) return false;
    self.snap_dirty = false;
    return true;
}

fn releaseSnapStream(self: *ViewerPane) void {
    if (self.snap_stream) |s| s.release();
    self.snap_stream = null;
}

/// Drop this pane's thumbnail state. Called from `deinit`, and the reason the
/// stream is owned by the pane rather than by the in-flight handler.
fn deinitHeroSnap(self: *ViewerPane) void {
    self.releaseSnapStream();
    if (self.snap_dib) |dib| _ = w32.DeleteObject(dib);
    self.snap_dib = null;
    self.snap_dib_w = 0;
    self.snap_dib_h = 0;
}

/// Match the controller's bounds to the host window's client area. Bounds are
/// physical pixels in the HOST window's client coordinates, which is why this
/// reads `GetClientRect` rather than taking the layout rect: the two agree
/// only when the host window has already been moved, and the layout pass moves
/// it first.
pub fn syncBounds(self: *ViewerPane) void {
    const h = self.hwnd orelse return;
    self.readScale();
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(h, &r) == 0) return;
    const width = @max(r.right - r.left, 0);
    const height = @max(r.bottom - r.top, 0);

    // The bar reserves its band while visible (Mac parity: the content is
    // inset, never covered), and follows the pane's width live.
    var top: i32 = 0;
    if (self.nav_visible) {
        if (self.nav) |nav| {
            nav.place(width, self.scale);
            top = @min(
                nav_layout.Layout.init(self.scale, width, nav.shown()).bar_h,
                height,
            );
        }
    }

    // The composer takes the next band down, and reserves it the same way the
    // bar does — the page is inset by nav + composer, never covered by either.
    // Its height tracks the text BOTH WAYS: a deleted line gives the space
    // back, which is the half of this a "grows with content" implementation
    // forgets (Mac pins it with `contentReflowsUpWhenComposerShrinks`).
    if (self.feedback_open) {
        if (self.feedback) |bar| {
            bar.place(top, width, self.scale);
            top = @min(top + bar.barHeight(width, self.scale), height);
        }
    }

    if (self.controller) |c| {
        _ = c.setBounds(.{
            .left = 0,
            .top = top,
            .right = width,
            .bottom = height,
        });
    }

    // The TOC card follows the pane's width LIVE — dragging a split divider
    // across 720 DIP flips it between its gutter and overlay layouts here.
    if (self.pending) |p| self.updateTOC(p.alloc);
}

// -------------------------------------------------------------------------
// The creation chain
// -------------------------------------------------------------------------

/// The token both async hops carry instead of the pane pointer.
///
/// Two references: one the pane holds for its whole life, one the outstanding
/// hop holds. The hop's reference moves from the environment waiter to the
/// controller handler without ever being dropped in between, so there is
/// exactly one place a hop can lose track of it — and it is the same place the
/// hop ends.
pub const Pending = struct {
    pane: ?*ViewerPane,
    refs: u8,
    alloc: Allocator,

    fn release(self: *Pending) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.alloc.destroy(self);
    }
};

/// `ICoreWebView2CreateCoreWebView2ControllerCompletedHandler` — a COM object
/// we implement, on `com.Callback`'s one vtable (T376).
const ControllerCompletedHandler = com.Callback(
    iface.IID_ControllerCompletedHandler,
    onControllerCompleted,
);

/// Begin creating this pane's web view on the app's shared environment.
///
/// Safe to call only once (the state guard asserts it): a second chain would
/// leave two tokens holding the pane. Failures are not exceptional — a box
/// without WebView2 lands in `.failed` with an error card, and that is a
/// supported machine.
pub fn start(self: *ViewerPane, alloc: Allocator, host: *webview2.Host) void {
    std.debug.assert(self.state == .idle);
    std.debug.assert(self.hwnd != null);

    const p = alloc.create(Pending) catch {
        self.fail(.environment_unavailable);
        return;
    };
    p.* = .{ .pane = self, .refs = 2, .alloc = alloc };
    self.pending = p;
    self.state = .waiting_env;

    // The other half of `createHostWindow`'s ensureNav — whichever call runs
    // second creates the bar (T159).
    if (self.hwnd) |h| self.ensureNav(alloc, self.hinstance, h);

    // Resolved once, here, rather than per request: it is a directory walk
    // from the exe outward and the resource handler runs dozens of times for
    // one page. A null result is not fatal — the pane still comes up, and its
    // template request 404s with a log line naming the cause.
    if (self.resources_dir == null) {
        if (internal_os.resourcesDir(alloc)) |*found| {
            var dirs = found.*;
            defer dirs.deinit(alloc);
            if (dirs.app()) |dir| {
                self.resources_dir = std.fs.path.join(alloc, &.{ dir, "viewer" }) catch null;
            }
        } else |_| {}
        if (self.resources_dir == null) log.warn(
            "no bundled viewer assets found; file viewers will not render",
            .{},
        );
    }

    // May answer synchronously when the environment is already up or already
    // known to be unavailable, which is why `pending`/`state` are set first.
    host.request(.{ .ctx = p, .func = onEnvironmentReady });
}

fn onEnvironmentReady(ctx: *anyopaque, result: webview2.Host.Result) void {
    const p: *Pending = @ptrCast(@alignCast(ctx));
    const self = p.pane orelse {
        // The pane was closed while the environment was still coming up.
        p.release();
        return;
    };

    switch (result) {
        .failed => |f| {
            self.fail(f);
            p.release();
        },
        .ready => |env| {
            const hwnd = self.hwnd orelse {
                self.fail(.environment_unavailable);
                p.release();
                return;
            };
            // Kept for the pane's life: `CreateWebResourceResponse` lives on
            // the environment, and the resource handler needs one per request.
            // The Host's reference is the Host's; this is ours.
            if (self.env == null) {
                env.addRef();
                self.env = env;
            }
            const handler = ControllerCompletedHandler.create(p.alloc, p) catch {
                self.fail(.environment_unavailable);
                p.release();
                return;
            };
            // Our own reference on the handler; the runtime takes its own if
            // it keeps it. Releasing here can free it outright when the call
            // below fails before AddRef-ing, which is the point.
            defer handler.release();

            self.state = .creating;
            const hr = env.createController(hwnd, @ptrCast(handler));
            if (com.failed(hr)) {
                log.warn("CreateCoreWebView2Controller hr=0x{X:0>8}", .{@as(u32, @bitCast(hr))});
                self.fail(.create_call_failed);
                // The handler will never be invoked, so the hop's reference
                // ends here rather than in the callback.
                p.release();
            }
        },
    }
}

fn onControllerCompleted(
    p: *Pending,
    result: com.HRESULT,
    controller: ?*iface.ICoreWebView2Controller,
) com.HRESULT {
    // Runs on the GUI thread, off its message loop. Keep it short.
    const self = p.pane orelse {
        // The pane went away mid-creation. The controller still has to be
        // closed, or a renderer process outlives the pane that asked for it.
        if (controller) |c| {
            c.close();
        }
        p.release();
        return com.S_OK;
    };
    defer p.release();

    if (com.failed(result) or controller == null) {
        log.warn("controller creation failed hr=0x{X:0>8} controller={s}", .{
            @as(u32, @bitCast(result)),
            if (controller == null) "null" else "set",
        });
        self.fail(.create_callback_failed);
        return com.S_OK;
    }

    // Borrowed for the duration of Invoke; we are keeping it.
    controller.?.addRef();
    self.adoptController(controller.?);
    return com.S_OK;
}

/// Take ownership of a live controller and bring it up to the pane's current
/// state — which may have moved on entirely while creation was in flight: the
/// pane can have been resized, hidden, focused and DPI-changed since `start`.
fn adoptController(self: *ViewerPane, c: *iface.ICoreWebView2Controller) void {
    self.controller = c;
    self.state = .ready;
    self.failure = null;

    // DPI first: bounds are physical pixels, and a view that rasterizes at a
    // different scale than its bounds were computed at is the defect this
    // ordering exists to avoid.
    if (c.queryV3()) |c3| {
        defer c3.release();
        _ = c3.setShouldDetectMonitorScaleChanges(false);
        _ = c3.setRasterizationScale(self.scale);
    } else {
        log.debug("runtime has no ICoreWebView2Controller3; scale follows the monitor", .{});
    }

    self.syncBounds();
    _ = c.setVisible(self.visible);
    self.applyColorScheme();
    self.subscribeNewWindowRequested();
    self.subscribeWindowCloseRequested();
    self.subscribeAcceleratorKey();
    self.subscribeDocumentTitle();
    // Before the navigation below, and that ordering is the contract: a script
    // registered after a page has started loading does not reach that page, so
    // the very first document a pane shows would be the one without a toolbar.
    self.subscribeBridge();
    // Also before the navigation, and for a sharper reason: a file-mode pane's
    // very first request IS the template's document, so an interception
    // registered after `Navigate` would miss the page it exists to serve.
    self.subscribeFileMode();
    // Before the navigation too, so the FIRST commit already updates the
    // address bar and the history buttons (T159).
    self.subscribeHistory();
    // And the link policy (T392) — before the navigation like everything
    // else, though its first decision is the template load it allows.
    self.subscribeNavigationStarting();
    if (self.focused) _ = c.moveFocus(.programmatic);

    // Last, so the page starts loading into a view that is already the right
    // size, scale and scheme — a navigation that begins before the bounds are
    // set lays the document out twice and the user sees the reflow.
    //
    // An ADOPTED popup takes the other branch (T163): the runtime navigates the
    // view we hand it, and a `Navigate` of our own would race that and sever the
    // opener↔popup relationship this whole path exists to keep. Every
    // subscription above is deliberately already in place — completing the
    // deferral is what starts the popup's navigation, so a bridge script or a
    // link policy registered afterwards would miss the popup's first document.
    if (self.popup) |req| {
        self.popup = null;
        defer req.release();
        if (c.coreWebView()) |web| {
            defer web.release();
            req.answer(web);
        } else {
            log.warn("adopted popup has no web view; it will not open", .{});
        }
    } else {
        self.applyNavigation();
    }

    // Stop painting the empty background: from here the controller owns the
    // pixels.
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 1);
}

/// Register the popup handler on a freshly adopted controller. Non-fatal: a
/// pane that fails to subscribe still shows its page, it just lets WebView2
/// open its own popup window for a `target=_blank` — a degradation, not a
/// broken pane, so it must not take the navigation down with it.
fn subscribeNewWindowRequested(self: *ViewerPane) void {
    std.debug.assert(self.new_window_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const handler = NewWindowRequestedHandler.create(p.alloc, p) catch return;
    // The token reference the handler borrows. Taken BEFORE the object can
    // reach a runtime that might release it, so the hook can never give back a
    // reference that was never taken.
    p.refs += 1;
    if (!web.addNewWindowRequested(@ptrCast(handler))) {
        log.warn("add_NewWindowRequested failed; popups will open their own window", .{});
        handler.release(); // takes the borrowed token reference with it
        return;
    }
    self.new_window_handler = handler;
}

/// Register the `window.close()` hook on a freshly adopted controller (T163).
/// Non-fatal like every other subscription: a pane that fails to subscribe
/// still shows its page, an adopted popup just cannot close itself — which is
/// a degradation the user can work around with the pane's own close, not a
/// broken pane.
///
/// Registered on EVERY viewer, not only on adopted popups, and that is the
/// simplification: Chromium only honors `window.close()` on a window a script
/// opened, so on a pane the user opened this never fires and there is no second
/// case to keep in step.
fn subscribeWindowCloseRequested(self: *ViewerPane) void {
    std.debug.assert(self.window_close_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const handler = WindowCloseRequestedHandler.create(p.alloc, p) catch return;
    // Same ordering rule as above: the borrowed token reference is taken BEFORE
    // the object can reach a runtime that might release it.
    p.refs += 1;
    if (!web.addWindowCloseRequested(@ptrCast(handler))) {
        log.warn("add_WindowCloseRequested failed; window.close() will do nothing", .{});
        handler.release(); // takes the borrowed token reference with it
        return;
    }
    self.window_close_handler = handler;
}

/// `ICoreWebView2AcceleratorKeyPressedEventHandler` (T394): the browser saw
/// a chord before the page did, and asks whether the host wants it.
const AcceleratorKeyPressedHandler = com.CallbackOwning(
    iface.IID_AcceleratorKeyPressedHandler,
    onAcceleratorKeyPressed,
    releasePendingToken,
);

/// Register the accelerator handler on a freshly adopted controller (T394).
/// Non-fatal like every other subscription: a pane that fails here still
/// shows its page, the app keybinds just stay dead inside it — the pre-T394
/// state, as a degradation instead of the default.
fn subscribeAcceleratorKey(self: *ViewerPane) void {
    std.debug.assert(self.accel_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;

    const handler = AcceleratorKeyPressedHandler.create(p.alloc, p) catch return;
    p.refs += 1;
    if (!c.addAcceleratorKeyPressed(@ptrCast(handler))) {
        log.warn("add_AcceleratorKeyPressed failed; app keybinds stay dead in this pane", .{});
        handler.release(); // takes the borrowed token reference with it
        return;
    }
    self.accel_handler = handler;
    log.debug("accelerator handler registered", .{});
}

/// The modifier state at Invoke time. The event args carry no modifiers by
/// design — the IDL says to ask `GetKeyState` — and the browser process is
/// blocked on this callback, so the state cannot go stale under us.
fn accelMods() inputpkg.Mods {
    return .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
}

/// The app keybind action a chord resolves to for THIS pane, or null when the
/// page keeps the key. Consulted twice on purpose: once in the Invoke (to
/// decide `Handled` while the browser waits) and again when the posted
/// message lands (the config may have been reloaded in between; the current
/// table wins). Sequences (`leader`) and chained bindings stay with the page
/// — a viewer has no UI for a pending sequence prefix.
fn chordAction(self: *ViewerPane, vk: u16, extended: bool, mods: inputpkg.Mods) ?inputpkg.Binding.Action {
    const event = viewer_accel.keyEventFor(vk, extended, mods) orelse return null;
    const set = &self.parent_window.app.config.keybind.set;
    const entry = set.getEvent(event) orelse return null;
    const leaf = switch (entry.value_ptr.*) {
        .leaf => |l| l,
        .leader, .leaf_chained => return null,
    };
    if (!viewer_accel.forwards(leaf.action)) return null;
    return leaf.action;
}

/// Push the current `zoom_factor` to the web view (T161) — Mac's
/// `pushZoomToWebView`. Safe with no controller (a bare test pane).
fn pushZoom(self: *ViewerPane) void {
    const c = self.controller orelse return;
    if (!c.setZoomFactor(self.zoom_factor)) {
        log.warn("put_ZoomFactor failed; page zoom unchanged", .{});
    }
}

/// Apply a ctrl+plus/minus/0 zoom chord: step the factor and push it to the
/// page — Mac's `handleZoom`, with its exact step and clamp.
fn handleZoom(self: *ViewerPane, action: viewer_accel.ZoomAction) void {
    self.zoom_factor = viewer_accel.steppedZoom(self.zoom_factor, action);
    self.pushZoom();
}

/// Perform a pane-scoped chord (T161) — Mac's `handle(_:)`.
fn handlePaneChord(self: *ViewerPane, chord: viewer_accel.PaneChord) void {
    switch (chord) {
        .reload => self.reloadContent(.chrome),
        .focus_address => _ = self.focusAddressBar(),
    }
}

/// Whether a chord is claimed by THIS pane while its content holds focus
/// (T161): the pane-scoped table and zoom are checked BEFORE the app keybind
/// table (design doc P7's ordering — ctrl+d must reach the address bar, not
/// the global split-right), and the app table before the page.
fn claimsChord(self: *ViewerPane, vk: u16, extended: bool, mods: inputpkg.Mods) bool {
    if (viewer_accel.zoomAction(vk, mods) != null) return true;
    if (viewer_accel.paneChord(vk, mods) != null) return true;
    // Window-scoped chords that are not binding actions (T746). Checked BEFORE
    // the keybind table on purpose: ctrl+shift+n is still bound to the
    // cross-platform `new_window` default in the core set, so consulting the
    // table first is what made a focused viewer open a plain local window when
    // the user asked for the machine chooser.
    if (window_chord.classify(vk, mods) != null) return true;
    return self.chordAction(vk, extended, mods) != null;
}

fn onAcceleratorKeyPressed(
    p: *Pending,
    sender: ?*iface.ICoreWebView2Controller,
    args_opt: ?*iface.ICoreWebView2AcceleratorKeyPressedEventArgs,
) com.HRESULT {
    _ = sender;
    const self = p.pane orelse return com.S_OK;
    const args = args_opt orelse return com.S_OK;

    // Key-up halves of a chord are events too; only presses forward.
    const kind = args.keyEventKind() orelse return com.S_OK;
    switch (kind) {
        .key_down, .system_key_down => {},
        else => return com.S_OK,
    }

    const vk_u32 = args.virtualKey() orelse return com.S_OK;
    if (vk_u32 > 0xFFFF) return com.S_OK;
    const vk: u16 = @intCast(vk_u32);
    const status = args.physicalKeyStatus() orelse return com.S_OK;
    const extended = status.IsExtendedKey != 0;
    const mods = accelMods();

    log.debug("accel key vk=0x{x} ctrl={} shift={} alt={}", .{
        vk, mods.ctrl, mods.shift, mods.alt,
    });
    if (!self.claimsChord(vk, extended, mods)) return com.S_OK;

    // Ours. Claim it BEFORE returning (the browser is blocked on this very
    // decision), then run the action from the message loop — not from inside
    // the controller's own callback, where `close_surface` would tear the
    // controller down under its own Invoke frame.
    _ = args.setHandled(true);
    const hwnd = self.hwnd orelse return com.S_OK;
    const wparam: usize = @as(usize, vk) | (@as(usize, @intFromBool(extended)) << 16);
    const lparam: isize = @as(u16, @bitCast(mods));
    _ = w32.PostMessageW(hwnd, WM_APP_VIEWER_ACCEL, wparam, lparam);
    return com.S_OK;
}

/// `ICoreWebView2DocumentTitleChangedEventHandler`: a website naming itself.
const DocumentTitleChangedHandler = com.CallbackOwning(
    iface.IID_DocumentTitleChangedHandler,
    onDocumentTitleChanged,
    releasePendingToken,
);

/// Subscribe to `document.title`. Registered for EVERY pane, file panes
/// included, for the reason the resource interception is: a file pane becomes a
/// web pane the moment the user types an address, and a subscription installed
/// only for the starting mode would be dead by then (Mac observes `\.title` on
/// every viewer for exactly this).
fn subscribeDocumentTitle(self: *ViewerPane) void {
    std.debug.assert(self.title_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const handler = DocumentTitleChangedHandler.create(p.alloc, p) catch return;
    p.refs += 1;
    if (!web.addDocumentTitleChanged(@ptrCast(handler))) {
        log.warn("add_DocumentTitleChanged failed; this pane keeps its location as its name", .{});
        handler.release(); // takes the borrowed token reference with it
        return;
    }
    self.title_handler = handler;
}

fn onDocumentTitleChanged(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*anyopaque,
) com.HRESULT {
    _ = args; // the event carries no payload; the title is read off the sender
    const self = p.pane orelse return com.S_OK;
    // A file's name is its basename, not its page's `<title>` — the bundled
    // template supplies that, and it names the renderer rather than the
    // document. Mac guards the identical observer with `isWebURL`.
    if (self.mode.isFile()) return com.S_OK;
    const web = sender orelse return com.S_OK;

    const raw = web.documentTitleRaw() orelse return com.S_OK;
    // The runtime allocated it on the COM heap; we free it on ours.
    defer w32.CoTaskMemFree(@ptrCast(raw));
    const wide = std.mem.span(raw);
    // An empty title is what a page has before it declares one. Falling back to
    // the location keeps the pane named rather than blanking a tab mid-load.
    if (wide.len == 0) return com.S_OK;

    const utf8 = std.unicode.utf16LeToUtf8Alloc(p.alloc, wide) catch return com.S_OK;
    defer p.alloc.free(utf8);
    self.setTitle(p.alloc, utf8) catch {};
    return com.S_OK;
}

// -------------------------------------------------------------------------
// Navigation chrome (T159)
// -------------------------------------------------------------------------

/// One cursor sample against the reveal strip. The DECISION is
/// `nav_layout.hoverTick`, pure and unit-tested; this is only the plumbing
/// that feeds it and obeys it.
fn navHoverTick(self: *ViewerPane) void {
    const h = self.hwnd orelse return;
    const nav = self.nav orelse return;
    if (!self.visible) return;

    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return;
    if (w32.ScreenToClient(h, &pt) == 0) return;
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(h, &r) == 0) return;

    // Only an ACTIVE window's cursor reveals chrome: hovering across a
    // background app should not animate it (and the cursor's absolute screen
    // position is meaningless to a window the user is not in — the live test
    // depends on that, since a test window never owns the real cursor).
    // Active, not foreground, since T215: there is no foreground window at
    // all on a background desktop, which pinned this false and made the
    // hover reveal unreachable by any script running there.
    // The compact TOC layout pins the bar open: its contents button is the
    // card's only opener, so a bar that auto-hides strands the card (T160,
    // Mac's `setChromeVisible(true)` on entering compact).
    // The open composer pins it for the same reason and one more: the button
    // that closes the composer lives in the bar, so a bar that auto-hid out
    // from under an open composer would leave it with no close affordance at
    // all (Mac's `setChromeVisible(true)` in `setFeedbackOpen`).
    const toc_pinned = self.toc_mode == .compact or self.feedback_open;
    if (toc_pinned and !self.nav_visible) self.setNavVisible(true);

    const window_active_now = w32.windowIsActive(w32.GetAncestor(h, w32.GA_ROOT));
    const in_pane = window_active_now and
        pt.x >= 0 and pt.y >= 0 and pt.x < r.right and pt.y < r.bottom;
    const l = nav_layout.Layout.init(self.scale, r.right - r.left, nav.shown());
    // "Held" = the address field owns the keyboard, or the cursor is on the
    // revealed bar itself (its band is the top `bar_h` of the pane).
    const edit_focused = w32.GetFocus() == @as(?w32.HWND, nav.edit) or
        (if (self.feedback) |bar| bar.hasFocus() else false);
    const on_bar = self.nav_visible and in_pane and pt.y < l.bar_h;

    const action = nav_layout.hoverTick(.{
        .in_pane = in_pane,
        .y = pt.y,
        .visible = self.nav_visible,
        .held = edit_focused or on_bar or toc_pinned,
        .now_ms = w32.GetTickCount64(),
        .deadline_ms = self.nav_deadline,
        .reveal_h = l.reveal_h,
    });
    self.nav_deadline = action.deadline_ms;
    if (action.show) self.setNavVisible(true);
    if (action.hide) self.setNavVisible(false);
}

/// Reveal or retract the bar, moving the content edge with it.
fn setNavVisible(self: *ViewerPane, visible: bool) void {
    if (self.nav_visible == visible) return;
    const nav = self.nav orelse return;
    self.nav_visible = visible;
    if (visible) self.pushAddress();
    self.syncBounds(); // places the bar and insets the content
    nav.setVisible(visible);
}

/// Reveal the bar and put the caret in the address field with the whole
/// address selected — the keyboard entry point (Mac's `focusAddressBar`).
/// Returns false when this pane has no bar to focus.
pub fn focusAddressBar(self: *ViewerPane) bool {
    const nav = self.nav orelse return false;
    self.setNavVisible(true);
    self.nav_deadline = w32.GetTickCount64() + nav_layout.hide_delay_ms;
    nav.focusAddress();
    return true;
}

/// What the address field should read for where the pane is now, pushed to
/// the bar (which ignores it while the user is typing).
fn pushAddress(self: *ViewerPane) void {
    const nav = self.nav orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    nav.setAddress(viewer_nav.addressText(&buf, self.location));
}

/// History state from `HistoryChanged`, mirrored to the bar's buttons.
fn pushHistory(self: *ViewerPane) void {
    const nav = self.nav orelse return;
    nav.setHistory(self.can_go_back, self.can_go_forward);
}

/// The bar's back button: one entry back in the view's own history. The
/// runtime treats a back with nowhere to go as a no-op, same as Mac's
/// `webView.goBack()`.
pub fn goBack(self: *ViewerPane) void {
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();
    if (!web.goBack()) log.warn("GoBack failed for this pane", .{});
}

pub fn goForward(self: *ViewerPane) void {
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();
    if (!web.goForward()) log.warn("GoForward failed for this pane", .{});
}

/// The bar's reload button: a NORMAL browser reload (Mac's `reloadPage` is
/// `webView.reload()`), deliberately not `+reload`'s cache-bypassing refetch
/// — the button is the browser convention, the verb is the agent's tool. A
/// file pane reloads the template, whose NavigationCompleted re-renders the
/// file. A pane with no completed load falls back to a full load.
pub fn reloadFromChrome(self: *ViewerPane) void {
    if (!self.page_loaded) {
        self.reloadContent(.chrome);
        return;
    }
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();
    if (!web.reload()) log.warn("Reload failed for this pane", .{});
}

/// The bar's home button: return to the location this pane was opened with.
pub fn goHome(self: *ViewerPane) void {
    const p = self.pending orelse return;
    const home = self.home_location orelse return;
    // `navigate` frees and replaces `location`/`home_location` strings; the
    // home it is being handed must not alias the field it frees.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (home.len > buf.len) return;
    @memcpy(buf[0..home.len], home);
    self.navigate(p.alloc, buf[0..home.len]) catch {};
}

/// Submit from the address field (the main loop routes Enter here via the
/// bar). Mac's `navigate(to:)`: trim, classify, complete — plus the tilde
/// expansion the pure module cannot do, since `~` needs a home directory.
pub fn navigateFromAddress(self: *ViewerPane, input: []const u8) void {
    const p = self.pending orelse return;
    var resolve_buf: [viewer_nav.max_address]u8 = undefined;
    const resolved = viewer_nav.resolveInput(&resolve_buf, input) orelse return;

    var tilde_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target: []const u8 = expand: {
        if (view_arg.tildeRemainder(resolved)) |rem| {
            var home_buf: [std.fs.max_path_bytes]u8 = undefined;
            const home: ?[]const u8 = internal_os.home(&home_buf) catch null;
            if (home) |hm| {
                const rel = std.mem.trimLeft(u8, rem, "/\\");
                const joined = std.fmt.bufPrint(&tilde_buf, "{s}{s}{s}", .{
                    hm,
                    if (rel.len > 0) "\\" else "",
                    rel,
                }) catch break :expand resolved;
                break :expand joined;
            }
        }
        break :expand resolved;
    };

    self.navigate(p.alloc, target) catch return;
    // Submitting hands keyboard focus to the page, the way a browser omnibox
    // does — and it genuinely moves focus off the EDIT, so a later click back
    // into the field is a focus change that re-selects the address.
    if (self.controller) |c| _ = c.moveFocus(.programmatic);
}

/// Escape while editing the address: throw the edit away, put the pane's
/// real location back in the field, and hand focus to the page (Mac's
/// `cancelAddressEditing`).
pub fn cancelAddressEdit(self: *ViewerPane) void {
    if (self.nav) |nav| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        nav.forceAddress(viewer_nav.addressText(&buf, self.location));
    }
    if (self.controller) |c| _ = c.moveFocus(.programmatic);
}

/// `ICoreWebView2SourceChangedEventHandler`: the view's Source moved — a
/// typed address, an in-page link, or a history walk.
const SourceChangedHandler = com.CallbackOwning(
    iface.IID_SourceChangedHandler,
    onSourceChanged,
    releasePendingToken,
);

/// `ICoreWebView2HistoryChangedEventHandler`: the back/forward list changed.
const HistoryChangedHandler = com.CallbackOwning(
    iface.IID_HistoryChangedHandler,
    onHistoryChanged,
    releasePendingToken,
);

fn onSourceChanged(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*anyopaque,
) com.HRESULT {
    _ = args; // only carries IsNewDocument; the source is read off the sender
    const self = p.pane orelse return com.S_OK;
    const web = sender orelse return com.S_OK;
    const raw = web.sourceRaw() orelse return com.S_OK;
    defer w32.CoTaskMemFree(@ptrCast(raw));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(p.alloc, std.mem.span(raw)) catch return com.S_OK;
    defer p.alloc.free(utf8);
    log.debug("source changed: {s}", .{utf8});
    self.syncCommitted(p.alloc, utf8);
    return com.S_OK;
}

fn onHistoryChanged(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*anyopaque,
) com.HRESULT {
    _ = args; // no payload; CanGoBack/CanGoForward are read off the sender
    const self = p.pane orelse return com.S_OK;
    const web = sender orelse return com.S_OK;
    self.can_go_back = web.canGoBack() orelse false;
    self.can_go_forward = web.canGoForward() orelse false;
    self.pushHistory();
    return com.S_OK;
}

/// Reconcile the pane's mode with whatever the web view actually committed —
/// Mac's `syncMode(toCommitted:)`, and the thing that makes Back work across
/// a mode switch: a user who types a URL into a file viewer and presses Back
/// lands on the TEMPLATE page again, and the pane must go back to rendering
/// the file rather than sitting in web mode over a blank template.
fn syncCommitted(self: *ViewerPane, alloc: Allocator, src: []const u8) void {
    // The page host is tested FIRST, ahead of the generic "https means the
    // web" branch below (T601). A rendered `.html` file commits an `https://`
    // URL of its own, so without this an html pane would flip itself into web
    // mode on its own very first commit — losing its file, its watcher and its
    // title to a navigation it did not make.
    if (content.isPageOrigin(src)) {
        self.syncCommittedPage(alloc, src);
        return;
    }
    if (std.mem.eql(u8, src, content.page_url)) {
        // The template is back on screen. If the pane already knows it is a
        // TEMPLATE pane, this is the initial load (or a same-file reload) and
        // `navigate` said everything already. An html pane landing here is
        // walking BACK onto the markdown document behind it, which is a real
        // mode change and does need the work below.
        if (self.mode.usesTemplate()) return;
        const floc = self.file_location orelse return;
        self.mode = content.modeFor(floc);
        self.page_loaded = false;
        if (alloc.dupeZ(u8, floc)) |dup| {
            if (self.location) |l| alloc.free(l);
            self.location = dup;
        } else |_| {}
        if (self.file_path) |old| alloc.free(old);
        self.file_path = null;
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (content.filePath(&pbuf, floc)) |path| {
            self.file_path = alloc.dupe(u8, path) catch null;
        }
        self.setTitle(alloc, content.initialTitle(self.mode, floc, self.file_path)) catch {};
        self.syncWatcher(alloc);
        // The NavigationCompleted that follows this commit re-renders the
        // file into the fresh template — nothing to do here but wait for it.
    } else if (viewMode(src) == .web) {
        const was_file = self.mode.isFile();
        self.mode = .web;
        if (alloc.dupeZ(u8, src)) |dup| {
            if (self.location) |l| alloc.free(l);
            self.location = dup;
        } else |_| {}
        if (was_file) {
            // A website is not a rendered document: whatever headings the
            // template last reported are gone with it (nothing will arrive
            // to clear them — the bridge only exists in our template), and
            // there is no file under this pane to watch anymore.
            self.clearHeadings(alloc);
            if (self.file_path) |old| alloc.free(old);
            self.file_path = null;
            // Through `syncWatcher` rather than a bare `watcher.stop()`: with
            // `file_path` already cleared it stops the watch AND cancels a
            // debounce the watcher may have armed on the way out (T400), so
            // an in-page link to a website leaves the document as completely
            // as an address-bar navigation does.
            self.syncWatcher(alloc);
        }
    } else return;

    // Neither destination is a rendered page, so the html grant that may have
    // been in force goes with it (T601). Safe to call here and nowhere else on
    // this path: `mode` is never `.html` by now, so this only ever CLEARS — the
    // pinned grant is never re-derived behind a navigation the page made.
    self.syncHtmlGrant(alloc);

    if (self.pane_view) |pv| pv.parentWindow().app.markLayoutDirty();
    self.pushAddress();
    // A BROWSER-initiated move is a location change like any other — an
    // in-page link from a doc to a dev server crosses worktrees just as an
    // address-bar navigation does.
    self.refreshWorktree();
}

/// The web view committed a URL on the PAGE host: a rendered `.html` file
/// (T601), either the one this pane was opened with or another one the page
/// itself navigated to — a link into `docs/`, a Back out of a website, a
/// same-page reload.
///
/// The grant is NOT re-derived here. It was pinned when the pane entered html
/// mode and it stays where it was put: a page that links into a subdirectory
/// must still be able to reach the stylesheet next to its index, and a page
/// that links back up must not find itself outside a root that moved down.
/// What DOES move is the file the pane is looking at — its path, its title, and
/// the file the watcher re-loads on save.
fn syncCommittedPage(self: *ViewerPane, alloc: Allocator, src: []const u8) void {
    const root = self.html_root orelse return;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = content.pageRequestPath(&rel_buf, src) orelse return;
    const path = (content.candidateUnder(alloc, root, rel) catch null) orelse {
        // Outside the grant: the handler would have refused to serve it, so
        // there is nothing here to point the pane at.
        log.warn("viewer page committed a URL outside its read grant", .{});
        return;
    };
    defer alloc.free(path);

    // The same file again — a reload, or the initial load `navigate` already
    // described. Re-pointing the watcher and re-titling on every reload would
    // be churn with no change behind it.
    if (self.file_path) |cur| if (content.samePath(cur, path)) return;

    self.mode = .html;
    if (alloc.dupe(u8, path)) |dup| {
        if (self.file_path) |old| alloc.free(old);
        self.file_path = dup;
    } else |_| {}
    // `location` is the FILESYSTEM path, not the synthetic URL: it is what
    // `+list --json` reports, what the address bar shows, and what the session
    // manifest restores the pane from — and the page host exists only inside
    // this process. Mac normalizes the committed `file://` URL back the same
    // way, for the same reason.
    if (alloc.dupeZ(u8, path)) |dup| {
        if (self.location) |l| alloc.free(l);
        self.location = dup;
    } else |_| {}
    if (content.pageUrlFor(alloc, root, path) catch null) |url| {
        if (self.html_url) |old| alloc.free(old);
        self.html_url = url;
    }
    self.html_fallback = false;
    self.setTitle(alloc, content.initialTitle(.html, path, self.file_path)) catch {};
    // Only the viewed file is watched, on both platforms: an edited sibling
    // stylesheet needs an explicit reload.
    self.syncWatcher(alloc);

    if (self.pane_view) |pv| pv.parentWindow().app.markLayoutDirty();
    self.pushAddress();
    self.refreshWorktree();
}

fn viewMode(src: []const u8) enum { web, other } {
    for ([_][]const u8{ "http://", "https://", "about:" }) |prefix| {
        if (src.len >= prefix.len and std.ascii.eqlIgnoreCase(src[0..prefix.len], prefix)) {
            return .web;
        }
    }
    return .other;
}

/// Register the T159 pair on a freshly adopted controller. Non-fatal, like
/// every other subscription: a pane that fails here has dead back/forward
/// buttons and a stale address on in-page navigation — degraded chrome, not
/// a broken pane.
fn subscribeHistory(self: *ViewerPane) void {
    std.debug.assert(self.source_handler == null);
    std.debug.assert(self.history_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    source: {
        const handler = SourceChangedHandler.create(p.alloc, p) catch break :source;
        p.refs += 1;
        if (!web.addSourceChanged(@ptrCast(handler))) {
            log.warn("add_SourceChanged failed; the address bar will go stale", .{});
            handler.release();
            break :source;
        }
        self.source_handler = handler;
    }

    const handler = HistoryChangedHandler.create(p.alloc, p) catch return;
    p.refs += 1;
    if (!web.addHistoryChanged(@ptrCast(handler))) {
        log.warn("add_HistoryChanged failed; back/forward stay disabled", .{});
        handler.release();
        return;
    }
    self.history_handler = handler;
}

fn fail(self: *ViewerPane, reason: webview2.Failure) void {
    self.state = .failed;
    self.failure = reason;
    log.info("viewer pane has no web view: {s}", .{@tagName(reason)});
    // A pane that will never have a web view cannot adopt a popup (T163).
    // Answer NOW rather than at deinit: the opening script is blocked in
    // `window.open()`, and the failed pane may sit on screen with its error
    // card for as long as the user leaves it there.
    if (self.popup) |req| {
        req.release();
        self.popup = null;
    }
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 1);
}

// -------------------------------------------------------------------------
// Painting
// -------------------------------------------------------------------------

/// Paint the pane's own pixels: the background, plus the error card when there
/// will be no content. Split out from `WM_PAINT` so it can be driven against
/// any DC.
pub fn paint(self: *ViewerPane, hdc: w32.HDC, width: i32, height: i32) void {
    const bg_brush = w32.CreateSolidBrush(w32.RGB(self.bg.r, self.bg.g, self.bg.b));
    defer if (bg_brush) |b| {
        _ = w32.DeleteObject(b);
    };
    var full: w32.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = height };
    if (bg_brush) |b| _ = w32.FillRect(hdc, &full, b);

    const failure = self.failure orelse return;
    if (self.state != .failed) return;
    paintErrorCard(hdc, width, height, self.scale, self.bg, failure);
}

/// The native, owner-painted error card (T90a design §2). Free function taking
/// its colors and geometry, so the card is one thing to look at and one thing
/// to test — `viewer_error_card.zig` owns every number in it.
fn paintErrorCard(
    hdc: w32.HDC,
    width: i32,
    height: i32,
    scale: f32,
    bg: color_math.Rgb,
    failure: webview2.Failure,
) void {
    const m = error_card.layout(width, height, scale) orelse return;

    // The card is a wash over the pane background, exactly like the banner's
    // glass card — one card treatment for the app, not a second one invented
    // here. Text and the hairline rim come from `chrome_theme`, so the card
    // meets the same contrast floors as every other surface.
    const card_bg = color_math.wash(bg, if (color_math.isLight(bg)) 0.04 else 0.06);
    const text = chrome_theme.textOn(card_bg);
    const subtle = chrome_theme.textSecondaryOn(card_bg);

    const fill = w32.CreateSolidBrush(w32.RGB(card_bg.r, card_bg.g, card_bg.b)) orelse return;
    defer _ = w32.DeleteObject(fill);
    const rim = w32.CreatePen(
        w32.PS_SOLID,
        @max(@as(i32, @intFromFloat(@round(scale))), 1),
        w32.RGB(subtle.r, subtle.g, subtle.b),
    );
    defer if (rim) |p| {
        _ = w32.DeleteObject(p);
    };

    const old_brush = w32.SelectObject(hdc, fill);
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = if (rim) |p| w32.SelectObject(hdc, p) else null;
    defer if (rim != null) {
        _ = w32.SelectObject(hdc, old_pen);
    };
    _ = w32.RoundRect(
        hdc,
        m.card.left,
        m.card.top,
        m.card.right,
        m.card.bottom,
        m.radius * 2,
        m.radius * 2,
    );

    const body = type_ramp.body(scale);
    const caption = type_ramp.caption(scale);
    const msg_font = w32.CreateFontW(
        -body.height,
        0,
        0,
        0,
        type_ramp.weight_semibold,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
    defer if (msg_font) |f| {
        _ = w32.DeleteObject(f);
    };
    const hint_font = w32.CreateFontW(
        -caption.height,
        0,
        0,
        0,
        type_ramp.weight_normal,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
    defer if (hint_font) |f| {
        _ = w32.DeleteObject(f);
    };

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    const flags = w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER;

    drawLine(hdc, msg_font, text, failure.message(), m.message, flags);
    drawLine(hdc, hint_font, subtle, failure.hint(), m.hint, flags);
}

fn drawLine(
    hdc: w32.HDC,
    font: ?*anyopaque,
    color: color_math.Rgb,
    text: []const u8,
    rect: error_card.Rect,
    flags: u32,
) void {
    // The strings are short, fixed English sentences from `webview2.Failure`;
    // a stack buffer is the right size for them and cannot fail at paint time,
    // which an allocation could.
    var buf: [256]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
    const old_font = if (font) |f| w32.SelectObject(hdc, f) else null;
    defer if (font != null) {
        _ = w32.SelectObject(hdc, old_font);
    };
    _ = w32.SetTextColor(hdc, w32.RGB(color.r, color.g, color.b));
    var r: w32.RECT = .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };
    _ = w32.DrawTextW(hdc, buf[0..len].ptr, @intCast(len), &r, flags);
}

// -------------------------------------------------------------------------
// Window procedure
// -------------------------------------------------------------------------

fn fromHwnd(hwnd: w32.HWND) ?*ViewerPane {
    const ptr = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

pub fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SIZE => {
            self.syncBounds();
            return 0;
        },

        // The host window moved inside its parent (a divider drag, a tab
        // switch). WebView2 caches the screen position of its parent chain for
        // hit-testing and IME placement, and only this call refreshes it.
        w32.WM_MOVE => {
            if (self.controller) |c| c.notifyParentWindowPositionChanged();
            return 0;
        },

        w32.WM_SETFOCUS => {
            self.focus();
            // The tab label follows its FOCUSED pane (T92), so a viewer taking
            // focus has to become the tab's active pane and relabel it — the
            // same two lines the terminal's WndProc runs. Without them, clicking
            // from a terminal into a viewer leaves the tab named after the pane
            // the user just left, and a later `DocumentTitleChanged` is filtered
            // out by `onPaneTitleChanged`'s active-pane guard.
            //
            // `heroOnPaneFocused` is deliberately NOT here: hero excludes
            // viewers (T90g). `updateDimOverlays` IS (T380): the active pane
            // just changed, so the dim has to move off this pane and onto the
            // one the user left, exactly as the terminal focus path does.
            if (self.pane_view) |pv| {
                const win = self.parent_window;
                const tab = win.active_tab;
                win.tab_active_pane[tab] = pv;
                win.refreshTabTitle(tab);
                win.updateDimOverlays();
            }
            return 0;
        },

        w32.WM_KILLFOCUS => {
            self.focused = false;
            return 0;
        },

        // A forwarded app keybind chord (T394), posted by the accelerator
        // handler after it claimed the key. Resolve the chord AGAIN against
        // the current keybind table (a config reload may have landed in
        // between; one message-loop hop is exactly the window where that can
        // happen), then dispatch. NOTHING may touch `self` after the
        // dispatch: `close_surface` frees this very pane (and this HWND)
        // before `performViewerBindingAction` returns.
        WM_APP_VIEWER_ACCEL => {
            const vk: u16 = @intCast(wparam & 0xFFFF);
            const extended = (wparam & (1 << 16)) != 0;
            const mods: inputpkg.Mods = @bitCast(@as(u16, @intCast(lparam & 0xFFFF)));
            // Same order as the claim (T161): zoom, then the pane-scoped
            // chords, then the app keybind table. Both pane legs act on
            // `self` and return — only the app-action leg below has the
            // "nothing may touch self afterwards" hazard.
            if (viewer_accel.zoomAction(vk, mods)) |za| {
                self.handleZoom(za);
                return 0;
            }
            if (viewer_accel.paneChord(vk, mods)) |chord| {
                self.handlePaneChord(chord);
                return 0;
            }
            // Window chords, same order as the claim above and for the same
            // reason (T746). Routed through `pane_view` rather than the raw
            // `parent_window` back-pointer, which a bare test pane leaves
            // undefined — the pattern the hero-mode arm below already uses.
            if (window_chord.classify(vk, mods)) |chord| switch (chord) {
                .new_remote_window => {
                    if (self.pane_view) |pv| {
                        log.info("machine chooser: opening via ctrl+shift+n (viewer focus)", .{});
                        pv.parentWindow().openMachineChooser();
                    }
                    return 0;
                },
            };
            const action = self.chordAction(vk, extended, mods) orelse return 0;
            const pv = self.pane_view orelse return 0;
            const perform = self.perform_accel_action orelse return 0;
            perform(pv, action);
            return 0;
        },

        // The palette's "Open Browser Pane" asking for the caret, one queue
        // hop after the pane's own deferred focus (T396).
        WM_APP_VIEWER_FOCUS_ADDRESS => {
            _ = self.focusAddressBar();
            return 0;
        },

        // The watcher thread saw the document change (T391). Do NOT re-render
        // here — restart the debounce. `SetTimer` with an id that already has a
        // timer RESETS it, which is exactly Mac's cancel-and-reschedule, so a
        // burst of notifications collapses into one render after the writes
        // stop.
        WM_APP_VIEWER_RELOAD => {
            _ = w32.SetTimer(hwnd, reload_timer_id, reload_debounce_ms, null);
            return 0;
        },

        // The worktree worker has an answer (T633). This is the ONLY place the
        // answer is read, and it runs on the GUI thread — which is what lets
        // the bar be re-laid and repainted straight from it.
        WM_APP_VIEWER_WORKTREE => {
            if (self.worktree) |*probe| {
                _ = probe.complete();
                self.pushWorktree();
            }
            return 0;
        },

        // The diff worker has an answer (T463), on the same terms.
        WM_APP_VIEWER_DIFF => {
            if (self.pending) |p| self.completeDiff(p.alloc);
            return 0;
        },

        // The page called `window.close()` (T163) — Mac's `webViewDidClose`.
        // Closes this pane and nothing else: for the single-pane popup window
        // that IS the window, matching browser semantics, and if the user has
        // since split it, only the popup pane goes. Viewers own no process, so
        // there is nothing to confirm. NOTHING may touch `self` afterwards —
        // `close_surface` frees this very pane and this HWND, the same hazard
        // `WM_APP_VIEWER_ACCEL` documents.
        WM_APP_VIEWER_CLOSE => {
            const close = self.close_from_page orelse return 0;
            close(self);
            return 0;
        },

        // The feedback worker filed the report (or could not) — T636. Also the
        // only place THAT answer is read, for the same reason.
        WM_APP_VIEWER_FEEDBACK_SENT => {
            self.completeFeedbackSend();
            return 0;
        },

        w32.WM_TIMER => {
            if (wparam == nav_timer_id) {
                self.navHoverTick();
                return 0;
            }
            if (wparam == feedback_close_timer_id) {
                // One-shot: the confirmation has been read, so the composer
                // gives the pane its band back.
                _ = w32.KillTimer(hwnd, feedback_close_timer_id);
                self.setFeedbackOpen(false);
                return 0;
            }
            if (wparam == diff_timer_id) {
                // The working-tree poll (T463). Repeating, not one-shot: it is
                // a question about a repository that never stops being asked
                // while the pane is open. Re-entrancy is the probe's problem
                // and it has an answer — one worker, deferred re-issue — so a
                // slow `git diff` cannot stack spawns behind itself.
                self.refreshDiff();
                return 0;
            }
            if (wparam != reload_timer_id) {
                return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            // One-shot: killed BEFORE the render, so a slow render cannot be
            // re-entered by its own timer still firing underneath it.
            _ = w32.KillTimer(hwnd, reload_timer_id);
            // The watcher's reason, not the chrome's: a rendered `.html` page
            // reloads in place here so a save keeps the reader's scroll (T601).
            self.reloadContent(.file_changed);
            return 0;
        },

        // Every pixel is painted in WM_PAINT; erasing first is one full-window
        // fill of flicker per resize.
        w32.WM_ERASEBKGND => return 1,

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) != 0) {
                self.paint(hdc, r.right - r.left, r.bottom - r.top);
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
/// Test-only: the loopback page server below. See `TestPage.serve` for why
/// `std.net.Stream`'s own read/write cannot be used on Windows.
const socket_rw = @import("../../remote/socket_rw.zig");

test "viewer pane id is a valid pane id" {
    // Constructing needs a Window, which needs an app runtime; the id
    // formatting itself is what matters here and is pure.
    var buf: pane_id_mod.Buf = undefined;
    const id = pane_id_mod.format(&buf, [_]u8{7} ** 16);
    try std.testing.expect(pane_id_mod.isValid(id));
}

test "T594: a test build never hands a shell-open to the OS" {
    // The claim is structural — `builtin.is_test` short-circuits `shellOpen`
    // before `ShellExecuteW` — and this proves the observable half: with a
    // sink installed the refused handoff is RECORDED, so any future path that
    // reaches `shellOpen` under test shows up in a sink assertion instead of
    // as an Edge window on the user's desktop (the T594 leak).
    const alloc = testing.allocator;
    var sink: LinkSink = .{ .alloc = alloc };
    defer sink.deinit();
    link_sink = &sink;
    defer link_sink = null;

    var pane: ViewerPane = .{};
    pane.shellOpen(alloc, "http://127.0.0.1:1/t594.html");
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expectEqualStrings(
        "shell:http://127.0.0.1:1/t594.html",
        sink.entries.items[0],
    );
}

test "the 3-tier resolver picks the right tier, against a real tree" {
    // `viewer_content.zig` owns the PATH math and tests it exhaustively without
    // a filesystem. What can only be checked here is the part that stats: the
    // tiers are tried in order, a directory is not a resource, and a name that
    // exists in two tiers resolves to the bundled one.
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("assets");
    try tmp.dir.makePath("doc/pics");
    try tmp.dir.makePath("assets/sub");
    try tmp.dir.writeFile(.{ .sub_path = "assets/viewer.html", .data = "bundled" });
    try tmp.dir.writeFile(.{ .sub_path = "doc/viewer.html", .data = "shadow" });
    try tmp.dir.writeFile(.{ .sub_path = "doc/pics/a.png", .data = "img" });
    try tmp.dir.writeFile(.{ .sub_path = "doc/README.md", .data = "# x" });
    try tmp.dir.writeFile(.{ .sub_path = "secret.txt", .data = "no" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    var pane: ViewerPane = .{};
    pane.resources_dir = try std.fs.path.join(alloc, &.{ root, "assets" });
    defer alloc.free(pane.resources_dir.?);
    pane.file_path = try std.fs.path.join(alloc, &.{ root, "doc", "README.md" });
    defer alloc.free(pane.file_path.?);

    // Tier 1 wins over tier 2 for the same name: the template must never be
    // shadowed by a file that happens to sit beside the document.
    {
        const hit = pane.resolveResource(alloc, "viewer.html").?;
        defer alloc.free(hit);
        const want = try std.fs.path.join(alloc, &.{ root, "assets", "viewer.html" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, hit);
    }

    // Tier 2: a relative image beside the document.
    {
        const hit = pane.resolveResource(alloc, "pics/a.png").?;
        defer alloc.free(hit);
        const want = try std.fs.path.join(alloc, &.{ root, "doc", "pics", "a.png" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, hit);
    }

    // A DIRECTORY is not a resource. Answering with one would be a read error
    // dressed up as a hit, and the page would show a broken image with a
    // success status.
    try testing.expect(pane.resolveResource(alloc, "sub") == null);

    // The escape the guard exists for, all the way through the stat: the file
    // is really there and must still not be served.
    try testing.expect(pane.resolveResource(alloc, "../secret.txt") == null);
    try testing.expect(pane.resolveResource(alloc, "nope.png") == null);
}

test "a pane closed mid-creation leaves a token the callback can survive" {
    // The hazard the `Pending` token exists for, exercised without a runtime:
    // the pane goes away between `start` and the controller callback, and the
    // callback must find a null pane rather than write into freed memory.
    //
    // The token is built by hand here because `start` needs a host window;
    // what is under test is the ownership rule, not the window.
    const alloc = testing.allocator;
    const p = try alloc.create(Pending);
    var pane: ViewerPane = .{};
    p.* = .{ .pane = &pane, .refs = 2, .alloc = alloc };
    pane.pending = p;

    // Closing the pane clears the token and drops the pane's reference. The
    // hop still holds one, so the token is still there to be found.
    pane.deinit(alloc);
    try testing.expectEqual(@as(?*Pending, null), pane.pending);
    try testing.expectEqual(@as(u8, 1), p.refs);
    try testing.expectEqual(@as(?*ViewerPane, null), p.pane);

    // Now the late callback arrives. It must not touch the pane, and it must
    // drop the last reference — the testing allocator is the oracle for that:
    // a leak or a double free fails the test.
    try testing.expectEqual(com.S_OK, onControllerCompleted(p, com.S_OK, null));
}

test "an environment failure lands the pane on the error card" {
    // The runtime-absent path end to end, minus the window: a failed
    // environment must leave a pane that reports a failure with text to paint,
    // never one that sits in `creating` forever with a blank rectangle.
    const alloc = testing.allocator;
    const p = try alloc.create(Pending);
    var pane: ViewerPane = .{ .state = .waiting_env };
    p.* = .{ .pane = &pane, .refs = 2, .alloc = alloc };
    pane.pending = p;

    onEnvironmentReady(p, .{ .failed = .runtime_not_found });

    try testing.expectEqual(State.failed, pane.state);
    try testing.expectEqual(webview2.Failure.runtime_not_found, pane.failure.?);
    try testing.expect(pane.failure.?.message().len > 0);
    try testing.expect(pane.failure.?.hint().len > 0);

    pane.deinit(alloc);
}

test "host floor: a real controller on a real window, on this box" {
    // The test that proves T373's half of the undocumented ABI, the way T372
    // proved the environment's: it drives the WHOLE chain against the live
    // runtime — register the class, create a host window, wait for the shared
    // environment, wait for the controller — and then calls every slot the
    // pane depends on and reads the value BACK through its getter. A vtable
    // slot in the wrong position cannot survive a round trip.
    //
    // On a box with no runtime the chain lands in `.failed` with an error
    // card, which is the correct answer there; the test asserts that instead
    // and says so loudly (a quiet skip is a test reporting success for work it
    // never did — T372's lesson).
    const alloc = testing.allocator;

    // Never against the user's own browser profile (T430): a test lane that
    // shares `%LOCALAPPDATA%\ghoztty\EBWebView-debug` with a live debug Ghoztty
    // contends with the user's browser process tree for it.
    var test_profile = try webview2.TestProfile.begin(alloc);
    defer test_profile.end();

    // WebView2 wants an apartment on the calling thread; the app initializes
    // one at startup, the test harness has not.
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);

    const hinstance = w32.GetModuleHandleW(null);
    // The class may already be registered by another test in this binary;
    // a zero atom with an "already exists" error is not a failure.
    _ = registerClass(hinstance);
    defer _ = w32.UnregisterClassW(CLASS_NAME, hinstance);

    // A hidden top-level parent, so the pane's host window has somewhere to be
    // a child of without an App or a Window.
    const parent_class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewerTestParent");
    const pc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &w32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = parent_class,
        .hIconSm = null,
    };
    _ = w32.RegisterClassExW(&pc);
    defer _ = w32.UnregisterClassW(parent_class, hinstance);

    const parent = w32.CreateWindowExW(
        0,
        parent_class,
        std.unicode.utf8ToUtf16LeStringLiteral("viewer test"),
        w32.WS_OVERLAPPEDWINDOW,
        0,
        0,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(parent);

    var host = webview2.Host.init(alloc);
    defer host.deinit();

    var pane: ViewerPane = .{};
    defer pane.deinit(alloc);
    // `create` is what normally mints this, and this test builds the pane by
    // hand — without it the pane's id is a row of NULs, which the feedback
    // report below would have to have an opinion about.
    {
        var id_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);
        _ = pane_id_mod.format(&pane.pane_id, id_bytes);
    }
    try pane.createHostWindow(hinstance, parent, .{ .left = 0, .top = 0, .right = 640, .bottom = 480 });
    pane.start(alloc, &host);

    // The test binary is not an installed ghoztty, so `resourcesDir`'s walk up
    // from the exe finds nothing and file mode would 404 its own template.
    // Point the pane at the SOURCE tree's copy of the assets — byte-identical
    // to what the installer stages — so the file-mode chain below is exercised
    // rather than quietly skipped. `zig build` runs test binaries from the
    // build root, and this failing loudly if that ever changes is the point.
    if (pane.resources_dir) |d| alloc.free(d);
    pane.resources_dir = try std.fs.cwd().realpathAlloc(alloc, "src/viewer");

    // Both completed handlers arrive on THIS thread's message loop, so the
    // test has to be one. Bounded: a hang would wedge the lane, and a silent
    // timeout would make the test green and empty.
    var msg: w32.MSG = undefined;
    const settled = webview2.pumpUntil(&pane, struct {
        fn f(ctx: *const anyopaque) bool {
            const p: *const ViewerPane = @ptrCast(@alignCast(ctx));
            return p.state != .waiting_env and p.state != .creating;
        }
    }.f);
    if (!settled) {
        // Say TIMEOUT, not `expected .ready, found .creating` — the second
        // reads as a broken pane rather than as a wait that ran out, and that
        // misreading is what T407 was filed over.
        log.err(
            "host floor: no controller within the deadline (still {s}); " ++
                "something is probably holding the WebView2 profile",
            .{@tagName(pane.state)},
        );
        return error.WebView2ControllerTimeout;
    }

    if (pane.state == .failed) {
        log.warn(
            "SKIPPED live controller test, no usable runtime: {s}",
            .{@tagName(pane.failure.?)},
        );
        // The failure path is still a real assertion: whatever went wrong, the
        // pane must be able to PAINT it rather than sit blank.
        try testing.expect(pane.failure.?.message().len > 0);
        try testing.expect(error_card.layout(640, 480, pane.scale) != null);
        return;
    }
    try testing.expectEqual(State.ready, pane.state);
    const c = pane.controller.?;
    // Loud on the success path too, for the same reason T372's is: "78 tests
    // passed" cannot tell you whether this one talked to a browser process or
    // took the skip, and the difference is the entire value of the test.
    log.warn("live controller ready on hwnd={?} scale={d}", .{ pane.hwnd, pane.scale });

    // Bounds: the pane sized the controller to its host window's CLIENT area,
    // in the host's own coordinates. `put_Bounds` takes the RECT by value, so
    // this round trip is also the proof that the aggregate is passed the way
    // the callee reads it.
    const b = c.bounds().?;
    try testing.expectEqual(@as(i32, 0), b.left);
    try testing.expectEqual(@as(i32, 0), b.top);
    try testing.expectEqual(@as(i32, 640), b.right);
    try testing.expectEqual(@as(i32, 480), b.bottom);

    // ...and it tracks a resize, which is the path every divider drag takes.
    _ = w32.MoveWindow(pane.hwnd.?, 0, 0, 320, 200, 1);
    pane.syncBounds();
    const b2 = c.bounds().?;
    try testing.expectEqual(@as(i32, 320), b2.right);
    try testing.expectEqual(@as(i32, 200), b2.bottom);

    // Visibility mirrors the pane's.
    try testing.expectEqual(@as(?bool, true), c.isVisible());
    pane.setVisible(false);
    try testing.expectEqual(@as(?bool, false), c.isVisible());
    pane.setVisible(true);

    // DPI: the pane owns the scale, so monitor detection must be OFF and the
    // scale must be the one the pane pushed — the two halves of design §4.
    const c3 = c.queryV3().?;
    defer c3.release();
    try testing.expectEqual(@as(?bool, false), c3.shouldDetectMonitorScaleChanges());
    try testing.expectApproxEqAbs(
        @as(f64, pane.scale),
        c3.rasterizationScale().?,
        0.001,
    );

    // Dark mode: revision 13's profile is where `prefers-color-scheme` comes
    // from, and it is the one interface here declared as "105 slots we never
    // call, then get_Profile" — so reading the value back is what proves that
    // count is right.
    const web = c.coreWebView().?;
    defer web.release();
    const v13 = web.queryV13().?;
    defer v13.release();
    const profile = v13.profile().?;
    defer profile.release();
    pane.setColorScheme(true);
    try testing.expectEqual(iface.PreferredColorScheme.dark, profile.preferredColorScheme().?);
    pane.setColorScheme(false);
    try testing.expectEqual(iface.PreferredColorScheme.light, profile.preferredColorScheme().?);

    // MoveFocus into a view that is not in a foreground window can legitimately
    // refuse, so this asserts only that the call reaches the runtime and comes
    // back — the crash a wrong slot index would produce is the real oracle.
    _ = c.moveFocus(.programmatic);
    c.notifyParentWindowPositionChanged();

    // T374's two new slots, round-tripped the same way.
    //
    // `add_NewWindowRequested` (slot 44, the far side of the 38-slot opaque
    // block) already ran inside `adoptController`; a handler recorded here is
    // the runtime saying it accepted the subscription. A wrong index would have
    // called `Stop` or `GoForward` with two pointers instead.
    try testing.expect(pane.new_window_handler != null);

    // T383's `add_DocumentTitleChanged` (46), same argument: a recorded handler
    // is the runtime saying it accepted a subscription at that index. The slot
    // one before it is `remove_NewWindowRequested`, whose signature takes a
    // TOKEN rather than a handler — subscribing there would hand it a pointer
    // as if it were an i64.
    try testing.expect(pane.title_handler != null);

    // ------------------------------------------------------------------
    // T374/T90e: navigation, and the whole file-mode chain behind it
    // ------------------------------------------------------------------
    //
    // `Navigate` (slot 5) is only verifiable by reading something back:
    // navigating at the WRONG slot can still return S_OK, and the page not
    // moving is the only thing that says so.
    //
    // T374 pointed this at a local `.html` file and read `get_Source` back.
    // T90e makes that destination FILE mode, so the source is now the bundled
    // template — and the oracle moves to something much stronger. A markdown
    // file with two headings, opened here, comes back as `pane.headings` only
    // if EVERY link in the chain ran:
    //
    //   * `AddWebResourceRequestedFilter` (57) + `add_WebResourceRequested`
    //     (55) intercepted a request for an origin that does not resolve in
    //     DNS, so a miss is a hard failure and not a slow network;
    //   * `CreateWebResourceResponse` (environment slot 4) built a body from a
    //     rewound `IStream`, four times over — the document, its CSS, its
    //     vendored markdown-it, and `viewer.js`;
    //   * the 3-tier resolver found all four under the bundled assets;
    //   * `add_NavigationCompleted` (15) fired;
    //   * `ExecuteScript` (29) ran `window.__viewer.setMarkdown` with the file
    //     escaped as a JS literal;
    //   * and the page rendered it and posted its headings back up T375's
    //     bridge.
    //
    // A wrong slot index anywhere in that list produces silence, which is why
    // the assertion is on CONTENT arriving. None of it needs a network.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "t90e.md",
        .data = "# Alpha\n\nsome text\n\n## Beta\n",
    });
    try tmp.dir.writeFile(.{ .sub_path = "t90e.zig", .data = "const x = 1;\n" });
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const md_path = try std.fs.path.join(alloc, &.{ dir_path, "t90e.md" });
    defer alloc.free(md_path);

    try pane.navigate(alloc, md_path);
    try testing.expectEqual(content.Mode.markdown, pane.mode);

    var nav_timer = try std.time.Timer.start();
    while (nav_timer.read() < 30 * std.time.ns_per_s and pane.headings.len < 2) {
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    log.warn("file mode: headings={d}", .{pane.headings.len});
    try testing.expectEqual(@as(usize, 2), pane.headings.len);
    try testing.expectEqualStrings("Alpha", pane.headings[0].text);
    try testing.expectEqualStrings("Beta", pane.headings[1].text);

    // And the page really did load the TEMPLATE rather than the file: a
    // file-mode pane never navigates Chromium at the document itself, which is
    // what stops markdown from rendering as raw text.
    {
        const raw = web.sourceRaw();
        try testing.expect(raw != null);
        defer w32.CoTaskMemFree(@ptrCast(raw.?));
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(raw.?));
        defer alloc.free(utf8);
        try testing.expectEqualStrings(content.page_url, utf8);
    }

    // The pane recorded the place it was SENT, which is what `+list --json`'s
    // `url` and the session manifest read. `home_location` is the FIRST
    // location and does not move with it.
    try testing.expectEqualStrings(md_path, pane.location.?);
    try testing.expectEqualStrings(md_path, pane.home_location.?);

    // T383: a file pane is named by its file, and stays that way. The template
    // it actually loaded has a `<title>` of its own, and `DocumentTitleChanged`
    // has certainly fired by now (the document rendered) — so this assertion is
    // the file-mode GUARD, not just the fallback: without it the tab would read
    // whatever the bundled renderer calls itself.
    try testing.expectEqualStrings("t90e.md", pane.title.?);

    // ------------------------------------------------------------------
    // T386: the page's fonts, measured rather than asserted from the CSS
    // ------------------------------------------------------------------
    //
    // The bundled sheet and the selection toolbar both used to name macOS-only
    // families with a GENERIC keyword behind them, so on Windows they landed on
    // Arial while the chrome around them stayed Segoe UI. Reading the stack
    // back out of the stylesheet only proves what we typed; what matters is
    // which face the font matcher picks HERE, and that is measurable: two
    // strings set in different families measure to different widths on a
    // canvas. So the page measures the real stacks against Arial (the generic
    // sans-serif's answer on Windows) and against the Segoe families.
    //
    // The assertion is deliberately "not Arial, and one of the Segoe faces"
    // rather than "exactly Segoe UI": `system-ui` may resolve to Segoe UI
    // Variable Text on Windows 11, which is the RIGHT answer and would fail an
    // equality check against plain Segoe UI.
    {
        const Probe = struct {
            done: bool = false,
            ok: bool = false,
            text: [256]u8 = undefined,
            len: usize = 0,

            fn onDone(p: *@This(), result: com.HRESULT, value: ?[*:0]const u16) com.HRESULT {
                p.done = true;
                p.ok = !com.failed(result);
                if (value) |v| {
                    const span = std.mem.span(v);
                    const n = std.unicode.utf16LeToUtf8(&p.text, span) catch 0;
                    p.len = @min(n, p.text.len);
                }
                return com.S_OK;
            }
        };
        const ProbeHandler = com.Callback(iface.IID_ExecuteScriptCompletedHandler, Probe.onDone);

        // One measurement helper, then: the toolbar's stack, the document
        // body's COMPUTED stack (so the vendored sheet's variable really did
        // get overridden), Arial, and the Segoe faces.
        const js =
            \\(function () {
            \\  var c = document.createElement("canvas").getContext("2d");
            \\  function w(f) { c.font = "16px " + f; return c.measureText("Quote Copy Segoe 12345"); }
            \\  function width(f) { return w(f).width; }
            \\  var toolbar = 'system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
            \\  var body = getComputedStyle(document.querySelector(".markdown-body")).fontFamily;
            \\  var arial = width("Arial");
            \\  function segoe(f) {
            \\    return width(f) === width('"Segoe UI"') ||
            \\      width(f) === width('"Segoe UI Variable Text"') ||
            \\      width(f) === width('"Segoe UI Variable"');
            \\  }
            \\  return [
            \\    width(toolbar) !== arial, segoe(toolbar),
            \\    width(body) !== arial, segoe(body)
            \\  ].join(",");
            \\})()
        ;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, js);
        defer alloc.free(wide);

        var probe: Probe = .{};
        const handler = try ProbeHandler.create(alloc, &probe);
        defer handler.release();
        try testing.expect(web.executeScript(wide.ptr, @ptrCast(handler)));

        var probe_timer = try std.time.Timer.start();
        while (probe_timer.read() < 15 * std.time.ns_per_s and !probe.done) {
            while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageW(&msg);
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        try testing.expect(probe.done);
        try testing.expect(probe.ok);
        // ExecuteScript hands back the result as JSON, so a string comes
        // quoted. Loud on success as well as failure: "the fonts are right" is
        // the whole point of the test and cannot be read off a pass count.
        log.warn("font probe: {s}", .{probe.text[0..probe.len]});
        try testing.expectEqualStrings("\"true,true,true,true\"", probe.text[0..probe.len]);
    }

    // ------------------------------------------------------------------
    // T160: the table-of-contents card rides the same chain
    // ------------------------------------------------------------------
    //
    // Two headings arrived, so the pane built its native card. Which
    // PRESENTATION it is in depends on the pane's width in DIP, which depends
    // on this monitor's scale — so both layouts are driven explicitly by
    // resizing the host window rather than asserting whichever one 640px
    // happens to land on here.
    try testing.expect(pane.toc != null);
    const toc_panel = pane.toc.?;

    // Wide: >= 720 DIP puts the card in a left gutter — visible with no
    // toggle — and reserves the page gutter (the card's left margin plus the
    // card, one number; the document's own padding supplies the gap).
    {
        const wide_px: i32 = @intFromFloat(@ceil(760.0 * pane.scale));
        _ = w32.MoveWindow(pane.hwnd.?, 0, 0, wide_px, 480, 1);
        pane.syncBounds();
        try testing.expectEqual(toc_layout.Mode.gutter, pane.toc_mode);
        try testing.expect(shownByStyle(toc_panel.hwnd));
        // The width preference is live and inside its draggable range
        // (whatever a previous session persisted).
        try testing.expect(pane.toc_width_dip >= toc_layout.card_min_dip);
        try testing.expect(pane.toc_width_dip <= toc_layout.card_max_dip);
        var wr: w32.RECT = undefined;
        try testing.expect(w32.GetClientRect(pane.hwnd.?, &wr) != 0);
        const pane_w_dip = @as(f32, @floatFromInt(wr.right - wr.left)) / pane.scale;
        try testing.expectEqual(
            toc_layout.gutterCssWidth(toc_layout.clampWidth(pane.toc_width_dip, pane_w_dip)),
            pane.toc_gutter_css,
        );
    }

    // Narrow: below 720 DIP the card becomes an overlay — closed until the
    // chrome bar's contents button opens it — and the page gutter is
    // released. The switch followed the pane width LIVE, off one resize.
    {
        const narrow_px: i32 = @intFromFloat(@floor(500.0 * pane.scale));
        _ = w32.MoveWindow(pane.hwnd.?, 0, 0, narrow_px, 480, 1);
        pane.syncBounds();
        try testing.expectEqual(toc_layout.Mode.compact, pane.toc_mode);
        try testing.expect(!shownByStyle(toc_panel.hwnd));
        try testing.expectEqual(@as(f32, 0), pane.toc_gutter_css);
        // The bar gained its contents toggle (its band is the card's only
        // opener in this layout)...
        try testing.expect(pane.nav.?.show_contents);
        // ...which slides the card in.
        pane.toggleTOCPanel();
        try testing.expect(pane.toc_open);
        try testing.expect(shownByStyle(toc_panel.hwnd));

        // Clicking a row scrolls the page to that heading and PINS it: the
        // page posts the pinned id back as an `active` message, which is what
        // moves the native selection — and using the overlay dismisses it.
        const target_id = try alloc.dupe(u8, pane.headings[1].id);
        defer alloc.free(target_id);
        pane.tocRowClicked(target_id);
        try testing.expect(!pane.toc_open);
        try testing.expect(!shownByStyle(toc_panel.hwnd));
        var click_timer = try std.time.Timer.start();
        while (click_timer.read() < 30 * std.time.ns_per_s) {
            if (pane.active_heading) |a| {
                if (std.mem.eql(u8, a, target_id)) break;
            }
            while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageW(&msg);
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        log.warn("toc: click -> active={?s}", .{pane.active_heading});
        try testing.expect(pane.active_heading != null);
        try testing.expectEqualStrings(target_id, pane.active_heading.?);
        // The panel's highlighted row followed the page's report.
        try testing.expectEqual(@as(i32, 1), toc_panel.active);

        // Back to the original size for everything below.
        _ = w32.MoveWindow(pane.hwnd.?, 0, 0, 640, 480, 1);
        pane.syncBounds();
    }

    // CODE mode, on the same template: `setCode` clears the heading index, and
    // the page posts the empty list up the same bridge. Headings falling back
    // to zero is the page saying `window.__viewer.setCode` ran — a template
    // that reloaded and was never injected would leave the host's copy alone.
    const code_path = try std.fs.path.join(alloc, &.{ dir_path, "t90e.zig" });
    defer alloc.free(code_path);
    try pane.navigate(alloc, code_path);
    try testing.expectEqual(content.Mode.code, pane.mode);
    var code_timer = try std.time.Timer.start();
    while (code_timer.read() < 30 * std.time.ns_per_s and pane.headings.len != 0) {
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 0), pane.headings.len);
    try testing.expectEqualStrings("t90e.zig", pane.title.?);
    // No headings, no card: the TOC retracted with the document that fed it
    // (T160 — a code file gets no contents card, and neither does a
    // one-heading document, which the page reports as an empty list too).
    try testing.expectEqual(toc_layout.Mode.hidden, pane.toc_mode);
    try testing.expect(!shownByStyle(pane.toc.?.hwnd));

    // A missing file must not take the pane down: it renders the page's own
    // error card and the pane stays a live, navigable citizen.
    const missing = try std.fs.path.join(alloc, &.{ dir_path, "nope.md" });
    defer alloc.free(missing);
    try pane.navigate(alloc, missing);
    var miss_timer = try std.time.Timer.start();
    while (miss_timer.read() < 5 * std.time.ns_per_s) {
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expectEqual(State.ready, pane.state);

    // A second navigation moves `location` and leaves `home` where it was —
    // the pane's half of the Home button's contract.
    try pane.navigate(alloc, "about:blank");
    try testing.expectEqual(content.Mode.web, pane.mode);
    try testing.expectEqualStrings("about:blank", pane.location.?);
    try testing.expectEqualStrings(md_path, pane.home_location.?);
    // A location with no host is its own name — the blank browser pane's case.
    try testing.expectEqualStrings("about:blank", pane.title.?);

    // ------------------------------------------------------------------
    // T375: the bridge, on a real http:// page
    // ------------------------------------------------------------------
    //
    // Three undocumented slots and two design pins, all proven by one round
    // trip: `AddScriptToExecuteOnDocumentCreated` (slot 27) ran our blob in a
    // page we did not author, the shim (P1) turned a WebKit `postMessage` into
    // a WebView2 one, `add_WebMessageReceived` (slot 34) delivered it, and
    // `get_WebMessageAsJson` (args slot 4) handed back the JSON the parser
    // expects. A wrong index in any of them produces silence, not a wrong
    // answer, which is why the assertion is on CONTENT arriving.
    //
    // It has to be `http://`, not the local file above: the file already proved
    // navigation, and P2's whole point is that the toolbar reaches pages the
    // bundled template never touches. The server is a socket on loopback, so
    // this still holds on a box with no route out.
    var page: TestPage = undefined;
    try page.start();
    defer page.stop();
    const page_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/t375.html", .{page.port});
    defer alloc.free(page_url);

    try pane.navigate(alloc, page_url);
    // Before a byte of the page arrives the pane is already named — by its host,
    // which is what the address alone can say. This is the pre-load half of
    // T383, and it is asserted HERE because one line later the real title
    // overwrites it.
    try testing.expectEqualStrings("127.0.0.1", pane.title.?);
    var bridge_timer = try std.time.Timer.start();
    while (bridge_timer.read() < 30 * std.time.ns_per_s) {
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        if (pane.active_heading != null and pane.headings.len > 0) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    log.warn("bridge: headings={d} active={?s}", .{ pane.headings.len, pane.active_heading });

    try testing.expectEqual(@as(usize, 2), pane.headings.len);
    try testing.expectEqualStrings("one", pane.headings[0].id);
    try testing.expectEqualStrings("One", pane.headings[0].text);
    try testing.expectEqual(@as(u8, 1), pane.headings[0].level);
    try testing.expectEqualStrings("two", pane.headings[1].id);
    try testing.expectEqual(@as(u8, 2), pane.headings[1].level);

    // The page reports whether `selection.js` ran alongside the shim, which is
    // P2's claim: ONE blob, both halves, on a real website. "toolbar-missing"
    // here would mean the shim was injected and the toolbar was not — the exact
    // split the single-blob rule exists to make impossible.
    try testing.expectEqualStrings("toolbar-ran", pane.active_heading.?);

    // T383's live round trip: `add_DocumentTitleChanged` (46) delivered the
    // event and `get_DocumentTitle` (48) handed back the string, on a page we
    // did not author. The pane was called "127.0.0.1" a moment ago, so this is
    // the document renaming it — not the fallback still standing.
    try waitFor(&msg, 30, struct {
        fn named(p: *ViewerPane) bool {
            return p.title != null and std.mem.eql(u8, p.title.?, "t375");
        }
    }.named, &pane);
    log.warn("document title: {?s}", .{pane.title});
    try testing.expectEqualStrings("t375", pane.title.?);

    // ------------------------------------------------------------------
    // T390: `+reload`, both modes
    // ------------------------------------------------------------------
    //
    // Two vtable slots that were inside opaque runs until now — `Reload` (31)
    // and `CallDevToolsProtocolMethod` (36) — plus the branch that chooses
    // between them. A wrong index in either is silence or a corrupt call, and
    // nothing but a live runtime can tell.

    // WEB. The page reports which fetch it came from, so "req2" is the
    // document in front of the user having been re-fetched. The response is
    // cacheable and still fresh, so a cache-allowed reload would legitimately
    // have shown "req1" again — that is the failure this asserts against, and
    // `no_cache` is the same claim seen from the request side (Chromium sends
    // `no-cache` for a bypassing reload, `max-age=0` for an ordinary one).
    var reload_page: ReloadPage = undefined;
    try reload_page.start();
    defer reload_page.stop();
    const reload_url = try std.fmt.allocPrint(
        alloc,
        "http://127.0.0.1:{d}" ++ ReloadPage.path,
        .{reload_page.port},
    );
    defer alloc.free(reload_url);

    try pane.navigate(alloc, reload_url);
    try testing.expect(!pane.page_loaded);
    // Wait for BOTH the page's report and the completed-load flag: the
    // page's postMessage and NavigationCompleted are delivered in no
    // guaranteed order relative to each other, and under box load the
    // message wins the race often enough to fail a bare page_loaded assert
    // right after this wait (seen 2026-08-06 in the agent lane).
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.page_loaded and
                p.active_heading != null and std.mem.eql(u8, p.active_heading.?, "req1");
        }
    }.ready, &pane);
    try testing.expectEqualStrings("req1", pane.active_heading.?);
    // The completed load is what makes the next call a RELOAD rather than a
    // first load, and it is set for web mode too (nothing is injected there,
    // so the flag is the only thing that navigation-completed leaves behind).
    try testing.expect(pane.page_loaded);

    pane.reloadContent(.chrome);
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.active_heading != null and std.mem.eql(u8, p.active_heading.?, "req2");
        }
    }.ready, &pane);
    log.warn("reload: active={?s} requests={d} no_cache={}", .{
        pane.active_heading,
        reload_page.requests.load(.acquire),
        reload_page.no_cache.load(.acquire),
    });
    try testing.expectEqualStrings("req2", pane.active_heading.?);
    try testing.expectEqual(@as(u32, 2), reload_page.requests.load(.acquire));
    try testing.expect(reload_page.no_cache.load(.acquire));

    // FILE. The oracle is the FILE ON DISK changing under a pane that is
    // already showing it: a re-render that did not re-read would report the
    // two headings it already had. (`viewer.js` restores scroll across the
    // swap; that is the shared renderer's half and is not re-proven here.)
    try tmp.dir.writeFile(.{
        .sub_path = "t90e.md",
        .data = "# Alpha\n\n## Beta\n\n## Gamma\n",
    });
    try pane.navigate(alloc, md_path);
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.headings.len == 3;
        }
    }.ready, &pane);
    log.warn("reload: file grew to headings={d}", .{pane.headings.len});
    try testing.expectEqual(@as(usize, 3), pane.headings.len);

    // The reloaded file has TWO headings, not one: the page reports a table of
    // contents only from two headings up ("one heading is a title" —
    // `viewer.js:indexHeadings`), so a one-heading file would report zero and
    // be indistinguishable from a render that failed outright. The names change
    // as well as the count, which is what separates "re-read the file" from
    // "re-showed the two headings it already had".
    try tmp.dir.writeFile(.{ .sub_path = "t90e.md", .data = "# Delta\n\n## Epsilon\n" });
    pane.reloadContent(.chrome);
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.headings.len == 2 and std.mem.eql(u8, p.headings[0].text, "Delta");
        }
    }.ready, &pane);
    log.warn("reload: file re-rendered to headings={d} first={?s}", .{
        pane.headings.len,
        if (pane.headings.len > 0) pane.headings[0].text else null,
    });
    try testing.expectEqual(@as(usize, 2), pane.headings.len);
    try testing.expectEqualStrings("Delta", pane.headings[0].text);
    try testing.expectEqualStrings("Epsilon", pane.headings[1].text);

    // ------------------------------------------------------------------
    // T391: live reload — the same re-render, with NOBODY asking for it
    // ------------------------------------------------------------------
    //
    // Everything above called `reloadContent`. From here the test only touches
    // the FILE, so what is under test is the whole chain the user has: watcher
    // thread → `WM_APP_VIEWER_RELOAD` → debounce → render. The pane is at
    // `md_path`, so the watcher `navigate` armed is the one that must fire.
    try testing.expect(pane.watcher.isRunning());

    // An ordinary in-place save. Three headings, none of them the two on
    // screen, so a render that did not re-read the file is not mistakable for a
    // render that did.
    try tmp.dir.writeFile(.{
        .sub_path = "t90e.md",
        .data = "# Zeta\n\n## Eta\n\n## Theta\n",
    });
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.headings.len == 3 and std.mem.eql(u8, p.headings[0].text, "Zeta");
        }
    }.ready, &pane);
    log.warn("watch: in-place save -> headings={d} first={?s}", .{
        pane.headings.len,
        if (pane.headings.len > 0) pane.headings[0].text else null,
    });
    try testing.expectEqual(@as(usize, 3), pane.headings.len);
    try testing.expectEqualStrings("Zeta", pane.headings[0].text);

    // The ATOMIC save — write a scratch file, rename it over the target — which
    // is what every real editor does and the case that orphans a watch bound to
    // a file handle. On Windows the notification is for the NAME, so this must
    // work with no re-arm anywhere; if it ever needs one, this is what says so.
    try tmp.dir.writeFile(.{
        .sub_path = "t90e.md.tmp",
        .data = "# Iota\n\n## Kappa\n",
    });
    try tmp.dir.rename("t90e.md.tmp", "t90e.md");
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.headings.len == 2 and std.mem.eql(u8, p.headings[0].text, "Iota");
        }
    }.ready, &pane);
    log.warn("watch: atomic save -> headings={d} first={?s}", .{
        pane.headings.len,
        if (pane.headings.len > 0) pane.headings[0].text else null,
    });
    try testing.expectEqual(@as(usize, 2), pane.headings.len);
    try testing.expectEqualStrings("Iota", pane.headings[0].text);
    try testing.expectEqualStrings("Kappa", pane.headings[1].text);

    // A website has no file to watch, and leaving the previous file's watch
    // running would re-render a document the pane is no longer showing.
    try pane.navigate(alloc, reload_url);
    try testing.expect(!pane.watcher.isRunning());
    // ...and coming back re-arms it, which is the only re-arm this platform
    // needs.
    try pane.navigate(alloc, md_path);
    try testing.expect(pane.watcher.isRunning());

    // ------------------------------------------------------------------
    // T400: leaving a document CANCELS a debounce it already armed
    // ------------------------------------------------------------------
    //
    // A save landing inside the ~100ms debounce window of the user navigating
    // away used to leave a one-shot timer running on the host window, and
    // firing it re-rendered wherever the pane HAD GONE — for a web
    // destination `refetchFromOrigin`, an unrequested cache-bypassing
    // re-fetch of a page the user just opened. Modelled exactly: arm the
    // timer with the very message the watcher thread posts, then navigate
    // WITHOUT pumping in between, which is the whole window the bug lives in.
    const t400_host = pane.hwnd.?;

    // Positive control: the watcher's message really does arm a timer on this
    // window (`KillTimer` answers nonzero only when there was one to kill), so
    // "nothing armed" below is a cancellation and not an arming that quietly
    // stopped working.
    _ = w32.SendMessageW(t400_host, WM_APP_VIEWER_RELOAD, 0, 0);
    try testing.expect(w32.KillTimer(t400_host, reload_timer_id) != 0);

    // THE ORACLE, and it is the timer itself rather than the fetch it would
    // have caused: armed, navigated away, and nothing left on the host window
    // the instant `navigate` returns — before a single message has been
    // pumped, which is the whole window the bug lives in. Restoring the bug
    // (drop the `KillTimer` from `syncWatcher`) turns this line red.
    //
    // Counting fetches cannot do this job, and the reason is worth recording:
    // a stale timer that fires while the destination is STILL LOADING hits
    // `reloadPlan`'s `full_load` branch, not `refetch` — it re-navigates to a
    // page the cache already holds, so the server sees nothing. Loading needs
    // pumping and pumping is what fires the timer, so that is the ordering the
    // race actually lands in (measured: the mutation is invisible at the
    // server in both cache states). The redundant render is real either way;
    // only the timer says so reliably.
    const before_nav = reload_page.requests.load(.acquire);
    _ = w32.SendMessageW(t400_host, WM_APP_VIEWER_RELOAD, 0, 0);
    try pane.navigate(alloc, reload_url);
    try testing.expectEqual(@as(i32, 0), w32.KillTimer(t400_host, reload_timer_id));

    // The end-to-end companion: with the debounce cancelled, nothing fetches
    // AFTER the destination settles, however long we pump past the window.
    // Weaker than the line above (see why, there), but it is the user-visible
    // claim — the page they opened is not re-loaded behind their back.
    //
    // Only the post-settle delta is asserted. The navigation's own cost is
    // Chromium's cache's business (the response is `max-age=600`): 0 or 1
    // depending on cache warmth, and equating it against a separately measured
    // expectation is what made this arm flake about one run in three (T690
    // calibrated it away, T596 finished the job — two cache-dependent
    // measurements never HAVE to agree). Nothing navigates between the two
    // reads below, so the asserted number cannot depend on cache state at
    // all. The navigation's cost is logged, not asserted.
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.mode == .web and p.page_loaded;
        }
    }.ready, &pane);
    const t400_settled = reload_page.requests.load(.acquire);
    pumpFor(&msg, reload_debounce_ms * 4);
    const after_settle = reload_page.requests.load(.acquire) - t400_settled;
    log.warn("t400: navigation cost {d} fetch(es); pumping past the debounce window cost {d}, expected 0", .{
        t400_settled - before_nav,
        after_settle,
    });
    try testing.expectEqual(@as(u32, 0), after_settle);

    // Leave the pane where the T391 section left it: on the file, watching.
    try pane.navigate(alloc, md_path);
    try testing.expect(pane.watcher.isRunning());

    // ------------------------------------------------------------------
    // T159: history — the slots, the handler IIDs, and the file<->web
    // boundary
    // ------------------------------------------------------------------
    //
    // Recorded handlers are the runtime accepting subscriptions at slots 11
    // (`add_SourceChanged`) and 13 (`add_HistoryChanged`) — and the events
    // FIRING below is the proof of the two handler IIDs, which no header on
    // this box can vouch for: the runtime QIs our callback for exactly that
    // GUID before ever invoking it, so a wrong one is an event that never
    // arrives, and every wait below times out.
    try testing.expect(pane.source_handler != null);
    try testing.expect(pane.history_handler != null);

    // Let the file FINISH rendering so the boundary test below has a real
    // "before". `page_loaded` is the load-completed bit, and it is the guard
    // that matters: the stale headings from the watch section would satisfy
    // a headings-only wait instantly, and the next navigation would then
    // abort this one mid-load — a race, not a test.
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.page_loaded and p.headings.len == 2 and
                std.mem.eql(u8, p.headings[0].text, "Iota");
        }
    }.ready, &pane);

    // Onto the web. `get_CanGoBack` (38) must flip true — the template entry
    // is behind us — and `HistoryChanged` firing at all is what delivers it.
    try pane.navigate(alloc, reload_url);
    // `page_loaded` too: issuing GoBack while the forward load is still in
    // flight cancels that load instead of testing the boundary.
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.mode == .web and p.can_go_back and p.page_loaded;
        }
    }.ready, &pane);
    log.warn("history: web, can_back={} can_fwd={}", .{ pane.can_go_back, pane.can_go_forward });
    try testing.expect(pane.can_go_back);

    // `GoBack` (40): the browser walks onto the template again, and the pane
    // must go back to RENDERING THE FILE — docs/claude/viewers.md's "going Back from a
    // website re-renders the file". SourceChanged flips the mode, the
    // NavigationCompleted that follows re-injects the content, and the
    // headings coming back is the whole chain having run.
    pane.goBack();
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.mode == .markdown and p.headings.len == 2 and
                std.mem.eql(u8, p.headings[0].text, "Iota");
        }
    }.ready, &pane);
    log.warn("history: back -> mode={s} headings={d}", .{ @tagName(pane.mode), pane.headings.len });
    try testing.expectEqual(content.Mode.markdown, pane.mode);
    try testing.expectEqualStrings(md_path, pane.location.?);
    try testing.expect(pane.watcher.isRunning());

    // `GoForward` (41): the web page is ahead of us again.
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.can_go_forward;
        }
    }.ready, &pane);
    pane.goForward();
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.mode == .web;
        }
    }.ready, &pane);
    try testing.expect(std.mem.startsWith(u8, pane.location.?, "http://127.0.0.1"));
    // Leaving the file cleared its TOC and its watch (the web page will
    // never post headings to clear them itself).
    try testing.expect(!pane.watcher.isRunning());

    // Home: back to the location the pane was OPENED with (the markdown
    // file, from the very first navigate in this test).
    try testing.expectEqualStrings(md_path, pane.home_location.?);
    pane.goHome();
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.page_loaded and p.mode == .markdown and p.headings.len == 2;
        }
    }.ready, &pane);
    try testing.expectEqualStrings(md_path, pane.location.?);

    // ------------------------------------------------------------------
    // T159: the chrome itself — the bar exists, reveals, reserves its band,
    // and the address field holds the retypable location selected
    // ------------------------------------------------------------------
    try testing.expect(pane.nav != null);
    const nav = pane.nav.?;

    try testing.expect(pane.focusAddressBar());
    try testing.expectEqual(@as(?w32.HWND, nav.edit), w32.GetFocus());

    // The content edge moved down by exactly the bar's height — the bar
    // reserves space, never covers the page.
    {
        var cr: w32.RECT = undefined;
        try testing.expect(w32.GetClientRect(pane.hwnd.?, &cr) != 0);
        const nl = nav_layout.Layout.init(pane.scale, cr.right - cr.left, nav.shown());
        const nb = c.bounds().?;
        try testing.expectEqual(nl.bar_h, nb.top);
    }

    // The field shows the file's own path (the Mac-style display text) with
    // the whole address selected, ready to replace.
    {
        var abuf: [4096]u8 = undefined;
        try testing.expectEqualStrings(md_path, nav.addressText(&abuf));
        const sel = w32.SendMessageW(nav.edit, w32.EM_GETSEL, 0, 0);
        const sel_start: u16 = @intCast(@as(usize, @bitCast(sel)) & 0xFFFF);
        const sel_end: u16 = @intCast((@as(usize, @bitCast(sel)) >> 16) & 0xFFFF);
        try testing.expectEqual(@as(u16, 0), sel_start);
        try testing.expect(sel_end > 0); // whole address, not a bare caret
    }

    // Submitting an address navigates through the SAME omnibox completion
    // the unit tests pin: a bare host:port completes to http:// and the pane
    // goes web. This is the Enter path minus the keystroke (the main loop's
    // routing is one line; the behavior is here).
    {
        var url_buf: [64]u8 = undefined;
        const bare = try std.fmt.bufPrint(&url_buf, "127.0.0.1:{d}{s}", .{
            reload_page.port,
            ReloadPage.path,
        });
        pane.navigateFromAddress(bare);
        try waitFor(&msg, 30, struct {
            fn ready(p: *ViewerPane) bool {
                return p.mode == .web;
            }
        }.ready, &pane);
        try testing.expect(std.mem.startsWith(u8, pane.location.?, "http://127.0.0.1"));
    }

    // ------------------------------------------------------------------
    // T392: link routing — NavigationStarting cancels and routes
    // ------------------------------------------------------------------
    //
    // The recorded handler is the runtime accepting a subscription at slot 7
    // (`add_NavigationStarting`; one slot off is `NavigateToString` or a
    // token-taking remove). The routing below FIRING is the proof of the
    // handler's IID and of the args layout — the URI read and the cancel
    // written are both args slots, and a wrong one is silence or a corrupt
    // call. Note every section above already ran with this handler live, so
    // the history walks and reloads that passed are the allow half of the
    // policy: a gate that routed too much would have broken them.
    try testing.expect(pane.navigation_starting_handler != null);

    // Routed links land in the sink instead of the OS — a green lane must
    // not open the user's real browser — and a bare test pane has no split
    // tree to open a viewer into anyway.
    var sink: LinkSink = .{ .alloc = alloc };
    defer sink.deinit();
    link_sink = &sink;
    defer link_sink = null;

    // One document, one link per routed class. The linked markdown file
    // EXISTS (relative links are existence-checked); nope-linked.md does not.
    try tmp.dir.writeFile(.{ .sub_path = "linked.md", .data = "# Linked\n" });
    try tmp.dir.writeFile(.{
        .sub_path = "links.md",
        .data = "[missing](nope-linked.md)\n\n[doc](linked.md)\n\n" ++
            "[code](t90e.zig)\n\n[ext](https://example.com/x)\n\n" ++
            "[jump](ghoztty://focus/dev)\n",
    });
    const links_path = try std.fs.path.join(alloc, &.{ dir_path, "links.md" });
    defer alloc.free(links_path);
    try pane.navigate(alloc, links_path);
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.page_loaded and p.mode == .markdown;
        }
    }.ready, &pane);

    // Synthesized clicks, which is why the gate keys on the navigation KIND
    // rather than `IsUserInitiated` (a script click reports false there; a
    // real one reports true; both are NEW_DOCUMENT). Each click is issued
    // after the previous one's entry arrived, and the ExecuteScript queue
    // orders the first against the `setMarkdown` that renders the links.
    //
    // The MISSING link goes first and must produce nothing — proven by
    // position: if it opened anything, ITS entry would sit where the split's
    // is asserted below.
    pane.executeScript(alloc, "document.querySelector('a[href=\"nope-linked.md\"]').click()");
    pane.executeScript(alloc, "document.querySelector('a[href=\"linked.md\"]').click()");
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            _ = p;
            return link_sink.?.entries.items.len >= 1;
        }
    }.ready, &pane);
    pane.executeScript(alloc, "document.querySelector('a[href=\"t90e.zig\"]').click()");
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            _ = p;
            return link_sink.?.entries.items.len >= 2;
        }
    }.ready, &pane);
    pane.executeScript(alloc, "document.querySelector('a[href=\"https://example.com/x\"]').click()");
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            _ = p;
            return link_sink.?.entries.items.len >= 3;
        }
    }.ready, &pane);

    // T695: a `ghoztty://` link is answered IN PROCESS and never navigates.
    // Clicking it at all is also the sanitizer's test: DOMPurify's default URI
    // allowlist does not carry the scheme, so before `viewer.js` widened it the
    // anchor rendered with NO href — `querySelector('a[href=…]')` would find
    // nothing and no entry would ever arrive here.
    pane.executeScript(alloc, "document.querySelector('a[href=\"ghoztty://focus/dev\"]').click()");
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            _ = p;
            return link_sink.?.entries.items.len >= 4;
        }
    }.ready, &pane);

    log.warn("link routing: {d} routed", .{sink.entries.items.len});
    try testing.expectEqual(@as(usize, 4), sink.entries.items.len);
    {
        const linked_path = try std.fs.path.join(alloc, &.{ dir_path, "linked.md" });
        defer alloc.free(linked_path);
        // A markdown link opens a viewer split at the RESOLVED path, next to
        // the viewed file.
        const want_split = try std.fmt.allocPrint(alloc, "split:{s}", .{linked_path});
        defer alloc.free(want_split);
        try testing.expectEqualStrings(want_split, sink.entries.items[0]);
        // A code file goes to its default app.
        const want_app = try std.fmt.allocPrint(alloc, "app:{s}", .{code_path});
        defer alloc.free(want_app);
        try testing.expectEqualStrings(want_app, sink.entries.items[1]);
        // An external URL goes to the default browser, byte-for-byte.
        try testing.expectEqualStrings("browser:https://example.com/x", sink.entries.items[2]);
        // A `ghoztty://` link stays here — not the browser, not a split, not
        // the shell — and carries the whole URL to the in-process handler.
        try testing.expectEqualStrings("focus:ghoztty://focus/dev", sink.entries.items[3]);
    }

    // Every routed click was CANCELLED: the pane never left the template, and
    // it still believes — correctly — that it is showing the links file.
    {
        const raw = web.sourceRaw().?;
        defer w32.CoTaskMemFree(@ptrCast(raw));
        const src = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(raw));
        defer alloc.free(src);
        try testing.expectEqualStrings(content.page_url, src);
    }
    try testing.expectEqual(content.Mode.markdown, pane.mode);
    try testing.expectEqualStrings(links_path, pane.location.?);

    // ------------------------------------------------------------------
    // T162: the selection toolbar's Copy — on the template AND a website
    // ------------------------------------------------------------------
    //
    // The toolbar itself is shared JS the blob already carried in (T375); what
    // is under test is the half a Windows user can reach in v1: select text,
    // press Copy, and the passage lands on the SYSTEM clipboard. The oracle is
    // the native clipboard read back through `GetClipboardData` — the page's
    // own confirmation flash cannot vouch for bytes having left the browser.
    //
    // Two pages, deliberately: the bundled markdown template and the loopback
    // `http://` page. The website case is the whole point of user-script
    // injection — it is the exact gap Mac's fix closed — so a test that only
    // covered the template would pass on a build where websites get no
    // toolbar at all.
    //
    // Two CDP calls stand in for what a real user's click brings and a hidden
    // test window cannot: focus emulation (the async clipboard API refuses an
    // unfocused document outright) and a clipboard-write permission grant (a
    // real click carries user activation; a synthetic `dispatchEvent` does
    // not). Neither changes what the toolbar DOES — they remove the two
    // environmental refusals that have nothing to do with the code under test.
    {
        // The lane runs on the real window station, so the user's clipboard is
        // saved and put back — a test that eats what they had copied is a
        // defect of its own.
        const saved_clip = clipboardReadText(alloc);
        defer {
            if (saved_clip) |s| {
                clipboardWriteText(alloc, s);
                alloc.free(s);
            }
        }

        try tmp.dir.writeFile(.{
            .sub_path = "copy.md",
            .data = "# Copy\n\nghoztty copied this passage\n",
        });
        const copy_path = try std.fs.path.join(alloc, &.{ dir_path, "copy.md" });
        defer alloc.free(copy_path);

        const cases = [_]struct {
            location: []const u8,
            needle: []const u8,
            tag: []const u8,
        }{
            .{ .location = copy_path, .needle = "ghoztty copied this passage", .tag = "md" },
            .{ .location = page_url, .needle = "the quick brown fox", .tag = "web" },
        };
        for (cases) |case| {
            try pane.navigate(alloc, case.location);
            try waitFor(&msg, 30, struct {
                fn ready(p: *ViewerPane) bool {
                    return p.page_loaded;
                }
            }.ready, &pane);

            // Re-issued after each navigation: cheap, and it leaves no question
            // of whether an emulation override survived the document swap.
            _ = web.callDevToolsProtocolMethod(
                std.unicode.utf8ToUtf16LeStringLiteral("Emulation.setFocusEmulationEnabled"),
                std.unicode.utf8ToUtf16LeStringLiteral("{\"enabled\":true}"),
                null,
            );
            _ = web.callDevToolsProtocolMethod(
                std.unicode.utf8ToUtf16LeStringLiteral("Browser.grantPermissions"),
                std.unicode.utf8ToUtf16LeStringLiteral(
                    "{\"permissions\":[\"clipboardReadWrite\",\"clipboardSanitizedWrite\"]}",
                ),
                null,
            );

            clipboardWriteText(alloc, "t162-sentinel");

            const driver = try selectionDriverJs(alloc, case.needle, case.tag, false);
            defer alloc.free(driver);
            pane.executeScript(alloc, driver);

            // The driver reports through the bridge once it has pressed Copy —
            // and its button count is the shape T641 restored: TWO buttons,
            // Quote then Copy. One would mean the hide-quote flag is back and
            // Windows has silently lost quoting; the count rides in the id so
            // the failure names itself.
            const want_id = try std.fmt.allocPrint(alloc, "copybar-{s}:2", .{case.tag});
            defer alloc.free(want_id);
            var press_timer = try std.time.Timer.start();
            while (press_timer.read() < 30 * std.time.ns_per_s) {
                while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
                    _ = w32.TranslateMessage(&msg);
                    _ = w32.DispatchMessageW(&msg);
                }
                if (pane.active_heading) |a| {
                    // Any report from this page's driver ends the wait; the
                    // exact-match assert below then names a wrong button count.
                    if (std.mem.startsWith(u8, a, want_id[0 .. want_id.len - 1])) break;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            log.warn("copy[{s}]: toolbar report={?s}", .{ case.tag, pane.active_heading });
            try testing.expectEqualStrings(want_id, pane.active_heading.?);

            // Now the system clipboard. Asynchronous on the browser side, so
            // poll — and keep pumping, the write completion still needs the
            // message loop.
            var clip_timer = try std.time.Timer.start();
            var copied: ?[]u8 = null;
            defer if (copied) |c_| alloc.free(c_);
            while (clip_timer.read() < 30 * std.time.ns_per_s) {
                while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
                    _ = w32.TranslateMessage(&msg);
                    _ = w32.DispatchMessageW(&msg);
                }
                if (clipboardReadText(alloc)) |text| {
                    if (std.mem.eql(u8, text, case.needle)) {
                        copied = text;
                        break;
                    }
                    alloc.free(text);
                }
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
            log.warn("copy[{s}]: clipboard={?s}", .{ case.tag, copied });
            try testing.expect(copied != null);
            try testing.expectEqualStrings(case.needle, copied.?);
        }
    }

    // ------------------------------------------------------------------
    // T641: the selection toolbar's Quote — passage into the composer
    // ------------------------------------------------------------------
    //
    // The other half of the same bar, and the reason the button count above
    // is 2. This is the whole path in one go: a REAL page, a real selection, a
    // real press of the real Quote button, the shared `selection.js` gathering
    // the referential context, the bridge carrying it, and the pane putting it
    // into the composer as a block. Nothing here is a stand-in except the
    // mouse event, which is the same synthetic press Copy is driven with.
    //
    // It lives in this live test rather than in `test/win32/viewer-feedback.ps1`
    // because pressing the page's own button means running script IN the page,
    // and the acceptance harness has no way to do that from outside the
    // process — the app exposes no "execute JS" verb, deliberately.
    {
        try tmp.dir.writeFile(.{
            .sub_path = "quote.md",
            .data =
            \\# Alpha
            \\
            \\a paragraph under the first heading
            \\
            \\## Beta
            \\
            \\ghoztty quoted this passage
            \\
            ,
        });
        const quote_path = try std.fs.path.join(alloc, &.{ dir_path, "quote.md" });
        defer alloc.free(quote_path);

        // A THROWAWAY repository, made out of the tmp dir itself (T636).
        //
        // Without this the probe resolves to the ghoztty checkout the tmp dir
        // lives inside, and the send below would file a fake report into the
        // real `temp/feedback/new/` queue — where the user's own feedback
        // watcher would pick it up. A nested `git init` makes
        // `rev-parse --show-toplevel` stop at the tmp dir, so the whole report
        // lands inside what `tmp.cleanup()` deletes.
        const repo_ready = gitInitTestRepo(alloc, dir_path);
        if (!repo_ready) log.warn("quote: no throwaway repo; the send half is skipped", .{});

        try pane.navigate(alloc, quote_path);
        try waitFor(&msg, 30, struct {
            fn ready(p: *ViewerPane) bool {
                return p.page_loaded;
            }
        }.ready, &pane);

        // The composer only opens for a pane that has somewhere to file, and
        // that answer arrives from a worker thread (T633). Waiting for the
        // worktree to be THE TMP DIR — not merely non-null — is what makes this
        // a wait on the new resolution rather than on a stale one from a
        // location visited earlier in this test.
        const Wanted = struct {
            var root: []const u8 = "";
            fn ready(p: *ViewerPane) bool {
                const got = p.feedbackWorktree() orelse return false;
                return std.ascii.eqlIgnoreCase(got, root);
            }
        };
        if (repo_ready) {
            Wanted.root = dir_path;
            try waitFor(&msg, 30, Wanted.ready, &pane);
        } else {
            try waitFor(&msg, 30, struct {
                fn ready(p: *ViewerPane) bool {
                    return p.feedbackWorktree() != null;
                }
            }.ready, &pane);
        }
        log.warn("quote: worktree={?s}", .{pane.feedbackWorktree()});

        // T648: quote into a composer that ALREADY holds non-ASCII text, with
        // the caret parked in the middle of it.
        //
        // The composer's pure modules work in BYTES into the pane's UTF-8
        // buffer; the control works in UTF-16 CODE UNITS. They are the same
        // number only for ASCII, which is why every offset now goes through
        // `charIndex`/`byteOffset` — and why an all-ASCII quote test cannot
        // see the difference.
        //
        // `\u{e9}` five times, a blank line, then `TAIL` is 16 bytes and 11
        // code units. With the caret at unit 7 — the start of `TAIL`, just
        // past the blank line — the block needs NO leading newlines, because
        // it is already at the start of a line with air above it. Read as a
        // byte offset, 7 lands inside the fourth `\u{e9}`, where the preceding
        // byte is not a newline and two would be inserted.
        const seeded = "\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\n\nTAIL";
        pane.feedbackSetText(alloc, seeded);
        pane.setFeedbackOpen(true);
        try testing.expect(pane.feedback_open);
        {
            // Straight at the control, because the caret is what this arm is
            // about and the bar's own `setCaret` is the thing under test.
            const bar = pane.feedback.?;
            const cr: w32.CHARRANGE = .{ .cpMin = 7, .cpMax = 7 };
            _ = w32.SendMessageW(bar.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&cr)));
        }

        const driver = try selectionDriverJs(alloc, "ghoztty quoted this passage", "quote", true);
        defer alloc.free(driver);
        pane.executeScript(alloc, driver);

        var quote_timer = try std.time.Timer.start();
        while (quote_timer.read() < 30 * std.time.ns_per_s) {
            while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageW(&msg);
            }
            if (pane.feedback_quotes.entries.items.len > 0) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        try testing.expectEqual(@as(usize, 1), pane.feedback_quotes.entries.items.len);
        const entry = pane.feedback_quotes.entries.items[0];
        log.warn("quote: text='{s}' heading={?s} block={?s} offset={?d}", .{
            entry.text,
            entry.heading_text,
            entry.block_selector,
            entry.document_offset,
        });

        // The passage itself...
        try testing.expectEqualStrings("ghoztty quoted this passage", entry.text);
        // ...and the context that lets an agent find it again. The heading is
        // the SECOND one, which is the assertion that `selection.js` walked
        // the document rather than grabbing the first heading it saw.
        try testing.expectEqualStrings("Beta", entry.heading_text.?);
        try testing.expect(entry.block_selector != null);
        try testing.expect(entry.block_text != null);

        // Quoting opens the composer — a quote filed into a composer the user
        // cannot see is a quote they do not know they made.
        try testing.expect(pane.feedback_open);

        // The block is in the composer's text, on lines of its own, and it is
        // LIVE: that is the number the report's `quotes` array will have.
        try testing.expect(std.mem.indexOf(u8, pane.feedbackText(), entry.text) != null);
        try testing.expectEqual(@as(usize, 1), pane.feedbackQuoteCount(alloc));

        // T648: it landed exactly at the caret — one blank line above the
        // block and one below, with the tail intact. Two extra newlines here
        // would be the byte offset having been read as a character index.
        {
            const want = "\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\n\n" ++
                "ghoztty quoted this passage" ++ "\n\nTAIL";
            try testing.expectEqualStrings(want, pane.feedbackText());
        }

        // ------------------------------------------------------------------
        // T636: press send, and read the report back off disk
        // ------------------------------------------------------------------
        //
        // The end of the whole chain, with nothing stubbed: the composer's real
        // text and the real quote go to the real worker, which runs `git
        // rev-parse` against the throwaway repo, searches the source file for
        // the passage, and publishes a folder into `temp/feedback/new/`. What
        // is asserted is the FILE — a watcher's view of the report, not the
        // pane's view of itself.
        if (repo_ready) {
            // What the user is POINTING AT when they hit send, tracked by the
            // injected blob rather than asked for at send time (T636). Selected
            // for real in the page, and waited for rather than slept on: the
            // tracker debounces, so the wait IS the assertion that the message
            // arrived at all.
            const selected = "a paragraph under the first heading";
            pane.executeScript(alloc,
                \\(function () {
                \\  var p = document.querySelectorAll("p")[0];
                \\  var r = document.createRange();
                \\  r.selectNodeContents(p);
                \\  var s = window.getSelection();
                \\  s.removeAllRanges();
                \\  s.addRange(r);
                \\})()
            );
            const Selected = struct {
                fn ready(p: *ViewerPane) bool {
                    const s = p.page_selection orelse return false;
                    return std.mem.eql(u8, s, selected);
                }
            };
            try waitFor(&msg, 30, Selected.ready, &pane);

            // The user types under the quoted block, which is where quoting
            // parked the caret.
            const composed = try std.fmt.allocPrint(
                alloc,
                "{s}\n\nthis heading is wrong\n",
                .{pane.feedbackText()},
            );
            defer alloc.free(composed);
            pane.feedbackSetText(alloc, composed);
            try testing.expectEqual(@as(usize, 1), pane.feedbackQuoteCount(alloc));

            pane.sendFeedback(alloc);
            try waitFor(&msg, 30, struct {
                fn ready(p: *ViewerPane) bool {
                    return p.feedbackStatus() != null;
                }
            }.ready, &pane);
            log.warn("send: status={?s}", .{pane.feedbackStatus()});

            // Exactly ONE folder, and its report is complete — the atomicity
            // property, read the way a watcher reads it. A staging folder left
            // visible in `new/` would be a half-written report; there is none,
            // because the publish is a rename of a finished folder.
            var queue = try tmp.dir.openDir("temp/feedback/new", .{ .iterate = true });
            defer queue.close();
            var folders: usize = 0;
            var stem_buf: [64]u8 = undefined;
            var stem: []const u8 = "";
            var it = queue.iterate();
            while (try it.next()) |e| {
                folders += 1;
                @memcpy(stem_buf[0..e.name.len], e.name);
                stem = stem_buf[0..e.name.len];
            }
            try testing.expectEqual(@as(usize, 1), folders);

            const report_path = try std.fmt.allocPrint(
                alloc,
                "temp/feedback/new/{s}/report.json",
                .{stem},
            );
            defer alloc.free(report_path);
            const raw = try tmp.dir.readFileAlloc(alloc, report_path, 256 * 1024);
            defer alloc.free(raw);
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            log.warn("send: report={s}", .{raw});

            // The body is markdown, with the quote as a real blockquote and the
            // user's own sentence under it.
            const body = obj.get("body").?.string;
            try testing.expect(std.mem.indexOf(u8, body, "> ghoztty quoted this passage") != null);
            try testing.expect(std.mem.indexOf(u8, body, "this heading is wrong") != null);

            // The revision the user was looking at — the half T633 did not
            // ship, resolved here against the throwaway repo.
            const worktree_obj = obj.get("worktree").?.object;
            try testing.expectEqualStrings("main", worktree_obj.get("branch").?.string);
            try testing.expectEqual(@as(usize, 40), worktree_obj.get("commit").?.string.len);

            // Where they were, repo-relative and forward-slashed.
            const source = obj.get("source").?.object;
            try testing.expectEqualStrings("file", source.get("kind").?.string);
            try testing.expectEqualStrings("quote.md", source.get("relativePath").?.string);
            try testing.expectEqualStrings(pane.paneId(), source.get("paneID").?.string);
            // What they had highlighted — the difference between "this is
            // wrong" and a report that names what "this" was.
            try testing.expectEqualStrings(selected, source.get("selection").?.string);

            // ...and the quote, with the line of the SOURCE file it came from.
            // Line 7 is `ghoztty quoted this passage` in the document written
            // at the top of this block.
            const q = obj.get("quotes").?.array.items[0].object;
            try testing.expectEqualStrings("ghoztty quoted this passage", q.get("text").?.string);
            try testing.expectEqualStrings("Beta", q.get("headingText").?.string);
            try testing.expectEqual(@as(i64, 7), q.get("sourceLine").?.integer);

            // The composer is empty behind its confirmation, so the next report
            // does not start with the last one still in the box.
            try testing.expectEqual(@as(usize, 0), pane.feedbackText().len);
            try testing.expect(std.mem.startsWith(u8, pane.feedbackStatus().?, "Filed "));
        }

        // ...and deleting a block takes its metadata out of the report without
        // anything having to notice the deletion. (Done by rewriting the
        // buffer, which is exactly what the control's change mirror does when
        // a user selects the block and hits Delete.)
        pane.feedbackSetText(alloc, "just my own words\n");
        try testing.expectEqual(@as(usize, 0), pane.feedbackQuoteCount(alloc));
    }

    // ------------------------------------------------------------------
    // T463: a git diff, rendered by the same page
    // ------------------------------------------------------------------
    //
    // The whole chain with nothing stubbed: a real repository, the real
    // worker running real `git` off the message loop, the real payloads, and
    // the real `diff.js` building rows in the real document — asserted by
    // reading the DOM back, which is the only oracle that can tell "the page
    // rendered a diff" from "the pane logged that it pushed one". The
    // acceptance script outside can only read the log line; this is the half
    // that proves the log line was true.
    //
    // Its own repository rather than the one above: the counts have to be
    // KNOWN, and by this point that tmp dir has a feedback report in it.
    {
        var diff_tmp = testing.tmpDir(.{});
        defer diff_tmp.cleanup();
        try diff_tmp.dir.writeFile(.{ .sub_path = "tracked.txt", .data = "one\ntwo\n" });
        const diff_dir = try diff_tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(diff_dir);

        if (!gitInitTestRepo(alloc, diff_dir)) {
            log.warn("T463: no throwaway repo on this box; the diff arm is skipped", .{});
        } else {
            // One tracked file modified, one file never added: two entries in
            // two different sections, which is also the assertion that the
            // untracked leg synthesizes a patch git will not produce.
            try diff_tmp.dir.writeFile(.{ .sub_path = "tracked.txt", .data = "one\ntwo\nthree\n" });
            try diff_tmp.dir.writeFile(.{ .sub_path = "loose.txt", .data = "new\nfile\n" });

            // `git-status` without its colon: the canonical form is what the
            // pane must store, since that is what `+list` reports and what the
            // manifest restores.
            try pane.navigate(alloc, "git-status");
            pane.applyOpenMetadata(alloc, .{
                .location = "git-status:",
                .origin_directory = diff_dir,
            });
            try testing.expectEqual(content.Mode.diff, pane.mode);
            try testing.expectEqualStrings("git-status:", pane.location.?);
            try testing.expectEqualStrings("Working tree", pane.title.?);
            // The origin directory is applied AFTER the navigate that will use
            // it, exactly as the real open path orders the two — which is safe
            // because the listing is not asked for until the template has
            // finished loading, several message-loop turns later.
            //
            // The listing and then the patch: two worker round trips, each
            // landing as a posted message this pump has to deliver.
            try waitFor(&msg, 30, struct {
                fn ready(p: *ViewerPane) bool {
                    const probe = if (p.diff_probe) |*d| d else return false;
                    return p.page_loaded and p.diff_pushed and
                        probe.files.items.len == 2 and
                        probe.patch_path != null and !probe.busy();
                }
            }.ready, &pane);

            const probe = &pane.diff_probe.?;
            try testing.expectEqualStrings(diff_dir, probe.repo.?);
            // Sections, and which side each file came from.
            var saw_unstaged = false;
            var saw_untracked = false;
            for (probe.files.items) |f| {
                if (f.origin == .unstaged and std.mem.eql(u8, f.path, "tracked.txt")) {
                    saw_unstaged = true;
                    try testing.expectEqual(@as(u32, 1), f.additions);
                }
                if (f.origin == .untracked and std.mem.eql(u8, f.path, "loose.txt")) {
                    saw_untracked = true;
                    // Counted by READING the file — git will not diff it.
                    try testing.expectEqual(@as(u32, 2), f.additions);
                }
            }
            try testing.expect(saw_unstaged);
            try testing.expect(saw_untracked);

            // ...and the page drew it. `.d-file` is the file card, `.d-line`
            // its rows, `.d-add` an added line: a payload that never arrived,
            // or arrived as a JS syntax error, leaves all three at zero.
            const Probe = struct {
                done: bool = false,
                ok: bool = false,
                text: [256]u8 = undefined,
                len: usize = 0,

                fn onDone(p: *@This(), result: com.HRESULT, value: ?[*:0]const u16) com.HRESULT {
                    p.done = true;
                    p.ok = !com.failed(result);
                    if (value) |v| {
                        const span = std.mem.span(v);
                        const n = std.unicode.utf16LeToUtf8(&p.text, span) catch 0;
                        p.len = @min(n, p.text.len);
                    }
                    return com.S_OK;
                }
            };
            const ProbeHandler = com.Callback(iface.IID_ExecuteScriptCompletedHandler, Probe.onDone);
            const js =
                \\(function () {
                \\  var root = document.querySelector(".viewer-diff-root");
                \\  if (!root) return "no-root";
                \\  return [
                \\    root.querySelectorAll(".d-file").length,
                \\    root.querySelectorAll(".d-line, .d-pair").length > 0,
                \\    root.querySelectorAll(".d-add").length > 0,
                \\    (root.querySelector(".d-summary") || {}).textContent || ""
                \\  ].join("|");
                \\})()
            ;
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, js);
            defer alloc.free(wide);
            var dom: Probe = .{};
            const handler = try ProbeHandler.create(alloc, &dom);
            defer handler.release();
            try testing.expect(web.executeScript(wide.ptr, @ptrCast(handler)));
            var dom_timer = try std.time.Timer.start();
            while (dom_timer.read() < 15 * std.time.ns_per_s and !dom.done) {
                while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
                    _ = w32.TranslateMessage(&msg);
                    _ = w32.DispatchMessageW(&msg);
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            try testing.expect(dom.done);
            try testing.expect(dom.ok);
            // Loud on success too: "78 tests passed" cannot say whether this
            // one talked to a browser (the T372/T162 convention).
            log.warn("T463 diff DOM: {s}", .{dom.text[0..dom.len]});
            const got = dom.text[0..dom.len];
            try testing.expect(std.mem.startsWith(u8, got, "\"1|true|true|"));
            // The header names the whole diff, not just the open file.
            try testing.expect(std.mem.indexOf(u8, got, "Working tree") != null);
            try testing.expect(std.mem.indexOf(u8, got, "2 files") != null);
        }
    }
}

/// Test-only: turn `dir` into its own throwaway git repository, with one
/// commit so `HEAD` resolves. False when git is not on this box or any step
/// failed — the caller then skips the half of the test that needs a repo
/// rather than filing a report into whatever repository `dir` sits inside.
///
/// `-c user.*` on the command line rather than in the repo config: the box's
/// global identity may be anything, and a commit that fails for want of one
/// would look like a bug in the code under test.
fn gitInitTestRepo(alloc: Allocator, dir: []const u8) bool {
    const runs = [_][]const []const u8{
        &.{ "git", "-C", dir, "init", "--initial-branch=main" },
        &.{ "git", "-C", dir, "add", "-A" },
        &.{
            "git",                        "-C",
            dir,                          "-c",
            "user.name=ghoztty test",     "-c",
            "user.email=test@ghoztty",    "commit",
            "--allow-empty",              "-m",
            "throwaway",
        },
    };
    var buf: [4096]u8 = undefined;
    for (runs) |argv| {
        _ = git_run.capture(alloc, argv, &buf) orelse return false;
    }
    // Proof rather than hope: the root git now reports for `dir` must BE `dir`.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv = viewer_worktree.rootArgv(0, dir);
    const out = git_run.capture(alloc, &argv, &buf) orelse return false;
    const root = viewer_worktree.parseRoot(&root_buf, out) orelse return false;
    return std.ascii.eqlIgnoreCase(root, dir);
}

/// A window's OWN visibility bit (T160's oracle). NOT `IsWindowVisible`,
/// which also requires every ancestor to be visible — the live tests' top-
/// level window is deliberately never shown, so that answer is always false
/// here regardless of what `place` did.
fn shownByStyle(hwnd: w32.HWND) bool {
    const style: usize = @bitCast(w32.GetWindowLongPtrW(hwnd, w32.GWL_STYLE));
    return style & w32.WS_VISIBLE_STYLE != 0;
}

/// Test-only: the JS that drives one Copy through the REAL toolbar (T162). It
/// polls for the paragraph carrying `needle` (which is also how it waits out
/// the template's async render), makes a live selection over it, raises the
/// `mouseup` the toolbar listens for, and presses the LAST button in the bar —
/// then reports through the bridge as `copybar-<tag>:<buttonCount>` so the
/// native side can assert both that Copy was pressed and that Quote is THERE
/// (T641 restored it: the bar ships two buttons, Quote then Copy, so the last
/// one is still Copy). Reaching the buttons through `host.shadowRoot` is
/// legitimate for a test: the root is `mode: "open"`.
///
/// `press_first` picks Quote (the leading button) instead — same selection,
/// same synthetic press, so the two arms differ in exactly one thing.
fn selectionDriverJs(
    alloc: Allocator,
    needle: []const u8,
    tag: []const u8,
    press_first: bool,
) ![]u8 {
    const template =
        \\(function () {
        \\  var tries = 0;
        \\  var timer = setInterval(function () {
        \\    tries += 1;
        \\    if (tries > 400) { clearInterval(timer); return; }
        \\    var all = document.querySelectorAll("p");
        \\    var target = null;
        \\    for (var i = 0; i < all.length; i++) {
        \\      if (all[i].textContent.indexOf("@NEEDLE@") !== -1) { target = all[i]; break; }
        \\    }
        \\    if (!target) return;
        \\    var range = document.createRange();
        \\    range.selectNodeContents(target);
        \\    var sel = window.getSelection();
        \\    sel.removeAllRanges();
        \\    sel.addRange(range);
        \\    document.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
        \\    var host = document.querySelector("[data-ghoztty-ui]");
        \\    var bar = host && host.shadowRoot && host.shadowRoot.querySelector(".bar.on");
        \\    if (!bar) return;
        \\    clearInterval(timer);
        \\    var buttons = bar.querySelectorAll("button");
        \\    buttons[@INDEX@].dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
        \\    window.webkit.messageHandlers.viewerTOC.postMessage(
        \\      { type: "active", id: "copybar-@TAG@:" + buttons.length });
        \\  }, 25);
        \\})();
    ;
    const with_needle = try std.mem.replaceOwned(u8, alloc, template, "@NEEDLE@", needle);
    defer alloc.free(with_needle);
    const with_tag = try std.mem.replaceOwned(u8, alloc, with_needle, "@TAG@", tag);
    defer alloc.free(with_tag);
    return try std.mem.replaceOwned(
        u8,
        alloc,
        with_tag,
        "@INDEX@",
        if (press_first) "0" else "buttons.length - 1",
    );
}

/// Test-only: the system clipboard's current text, owned by the caller, or
/// null when it holds none. The live copy test's oracle — the toolbar's whole
/// job is landing bytes HERE, outside the browser process.
fn clipboardReadText(alloc: Allocator) ?[]u8 {
    if (w32.OpenClipboard(null) == 0) return null;
    defer _ = w32.CloseClipboard();
    const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return null;
    const ptr = w32.GlobalLock(hglobal) orelse return null;
    defer _ = w32.GlobalUnlock(hglobal);
    const wptr: [*]const u16 = @ptrCast(@alignCast(ptr));
    var wlen: usize = 0;
    while (wptr[wlen] != 0) wlen += 1;
    return std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch null;
}

/// Test-only: put text on the system clipboard — the sentinel before each
/// press, and the user's own contents back afterwards. Mirrors the write in
/// `Surface.completeClipboardRequest` (SetClipboardData owns the HGLOBAL on
/// success; on any earlier failure we free it ourselves).
fn clipboardWriteText(alloc: Allocator, text: []const u8) void {
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch return;
    defer alloc.free(utf16);
    const byte_size = (utf16.len + 1) * @sizeOf(u16);
    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse return;
    const dst = w32.GlobalLock(hglobal) orelse {
        _ = w32.GlobalFree(hglobal);
        return;
    };
    const dst16: [*]u16 = @ptrCast(@alignCast(dst));
    @memcpy(dst16[0..utf16.len], utf16);
    dst16[utf16.len] = 0;
    _ = w32.GlobalUnlock(hglobal);
    if (w32.OpenClipboard(null) == 0) {
        _ = w32.GlobalFree(hglobal);
        return;
    }
    defer _ = w32.CloseClipboard();
    _ = w32.EmptyClipboard();
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, hglobal) == null) {
        _ = w32.GlobalFree(hglobal);
    }
}

/// Pump the message loop until `ready` says so or `timeout_s` elapses.
///
/// A viewer test's every oracle is something a browser process does on the
/// message loop, so "wait" here can never be a sleep: the callbacks that
/// deliver the answer only run while messages are being dispatched.
fn waitFor(
    msg: *w32.MSG,
    timeout_s: u64,
    ready: *const fn (*ViewerPane) bool,
    pane: *ViewerPane,
) !void {
    var timer = try std.time.Timer.start();
    while (timer.read() < timeout_s * std.time.ns_per_s) {
        while (w32.PeekMessageW(msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(msg);
            _ = w32.DispatchMessageW(msg);
        }
        if (ready(pane)) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

/// Dispatch messages for a fixed span with nothing to wait FOR — the negative
/// half of `waitFor`. Proving something does NOT happen needs the window in
/// which it would have happened to actually elapse, and a `WM_TIMER` only
/// exists while somebody is pumping (T400).
fn pumpFor(msg: *w32.MSG, ms: u64) void {
    var timer = std.time.Timer.start() catch return;
    while (timer.read() < ms * std.time.ns_per_ms) {
        while (w32.PeekMessageW(msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(msg);
            _ = w32.DispatchMessageW(msg);
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

/// A loopback HTTP server serving one page, for the live bridge test.
///
/// A real `http://` origin is the point — `file://` and the bundled template
/// are both pages we author, and P2's claim is about the ones we do not. A
/// socket on 127.0.0.1 gives that without a network.
/// Give an accepted test-server connection a bounded receive timeout (T430).
///
/// Chromium **preconnects**: it opens sockets to an origin speculatively and
/// may send nothing on them at all. A serving loop that blocks in `recv` on one
/// of those is stuck until Chromium's own idle timer closes it — measured at
/// ~3 minutes of a completely blocked wait (zero CPU) in the agent lane, and
/// unbounded if the browser process itself is wedged. While it is stuck it is
/// not in `accept()`, so the shutdown poke in `stop()` cannot reach it either
/// and `join()` waits with it.
///
/// A timeout turns all of that into "no request arrived, close it, loop".
/// `SOL_SOCKET`/`SO_RCVTIMEO` are not in zig's `ws2_32` bindings; on Windows
/// the value is a `DWORD` of milliseconds (not a `timeval`).
fn setRecvTimeout(handle: std.posix.socket_t, ms: u32) void {
    const SOL_SOCKET: i32 = 0xffff;
    const SO_RCVTIMEO: i32 = 0x1006;
    _ = std.os.windows.ws2_32.setsockopt(
        handle,
        SOL_SOCKET,
        SO_RCVTIMEO,
        @ptrCast(&ms),
        @sizeOf(u32),
    );
}

const TestPage = struct {
    server: std.net.Server,
    port: u16,
    thread: std.Thread,
    /// Set before the wake-up connection below, so the serving thread knows the
    /// connection it just accepted is the shutdown poke and not a request.
    stopping: std.atomic.Value(bool) = .init(false),

    /// The page posts through the WebKit path the SHARED viewer JS uses, so
    /// this is the shim under test rather than a WebView2 call written to pass.
    /// The second message carries `selection.js`'s own install guard, which is
    /// how one round trip proves both halves of the blob arrived.
    const html =
        \\<!doctype html><meta charset="utf-8"><title>t375</title>
        \\<p id="p">the quick brown fox</p>
        \\<script>
        \\(function () {
        \\  var w = window.webkit && window.webkit.messageHandlers
        \\    && window.webkit.messageHandlers.viewerTOC;
        \\  if (!w) return;
        \\  w.postMessage({ type: "headings", items: [
        \\    { id: "one", text: "One", level: 1 },
        \\    { id: "two", text: "Two", level: 2 }] });
        \\  w.postMessage({ type: "active",
        \\    id: window.__ghozttySelection ? "toolbar-ran" : "toolbar-missing" });
        \\})();
        \\</script>
        \\
    ;

    /// Initializes IN PLACE: the serving thread is handed `&self.server`, so
    /// the struct has to already be at its final address. Returning one by
    /// value would leave that pointer aimed at a dead stack slot.
    fn start(self: *TestPage) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.server = try addr.listen(.{ .reuse_address = true });
        errdefer self.server.deinit();
        self.port = self.server.listen_address.getPort();
        self.stopping = .init(false);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// T430: **wake the accept, then close** — never close and hope.
    ///
    /// Closing a listening socket that another thread is blocked in `accept()`
    /// on is explicitly unsupported on Windows: `closesocket` is documented not
    /// to signal a blocking call pending on the socket in a different thread,
    /// so the accept can sit there forever and `join()` never returns. That is
    /// a hang with zero CPU and no output — the exact shape that made two
    /// standing-floor lanes unreadable. Sending it a real connection is what
    /// makes the wake-up deterministic, and it is already the house idiom
    /// (`keepalive.zig`, `link_control.zig`, `self_update.zig` all do this).
    fn stop(self: *TestPage) void {
        self.stopping.store(true, .monotonic);
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.server.deinit();
    }

    /// `socket_rw`, not `Stream.read`/`Stream.writeAll`.
    ///
    /// Those go through `ReadFile`/`WriteFile` with a null `OVERLAPPED`, and
    /// zig creates its sockets with `WSA_FLAG_OVERLAPPED` — which makes every
    /// call fail with `ERROR_INVALID_PARAMETER (87)`. That is T89b's finding
    /// and `socket_rw.readStream`/`writeAllStream` are the house answer to it;
    /// this test hit the same wall and uses them rather than growing a fourth
    /// private copy of `recv`.
    fn serve(self: *TestPage) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            if (self.stopping.load(.monotonic)) return;
            setRecvTimeout(conn.stream.handle, 2000);

            // Drain the request line and headers. A socket closed with unread
            // data in its receive buffer is RESET rather than shut down, and
            // the reset takes our response with it.
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = socket_rw.readStream(conn.stream, buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            // A preconnect that never asked for anything: close it and go back
            // to waiting for a real request, rather than answering a question
            // nobody put.
            if (total == 0) continue;

            var head_buf: [160]u8 = undefined;
            const head = std.fmt.bufPrint(
                &head_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" ++
                    "Content-Length: {d}\r\nConnection: close\r\n\r\n",
                .{html.len},
            ) catch return;
            socket_rw.writeAllStream(conn.stream, head) catch continue;
            socket_rw.writeAllStream(conn.stream, html) catch continue;
            // `Connection: close` means the client waits for a FIN, so send one
            // explicitly rather than leaving it to the close above.
            _ = std.os.windows.ws2_32.shutdown(
                conn.stream.handle,
                std.os.windows.ws2_32.SD_SEND,
            );
        }
    }
};

/// A loopback HTTP server whose page CHANGES on every request, for the
/// `+reload` test (T390).
///
/// The page reports the request number it was built from, so the pane's
/// `active_heading` says which fetch the document in front of the user came
/// from. That is the only way to tell a real re-fetch from a reload the
/// browser answered out of its cache — the two are pixel-identical from
/// outside, which is exactly why P8 pins the DevTools call.
///
/// The response is deliberately CACHEABLE (`max-age=600`): with a fresh cache
/// entry available, a cache-allowed reload is entitled to skip the network
/// entirely, so a stale answer here is a genuine possibility rather than a
/// hypothetical.
const ReloadPage = struct {
    /// The one path this server answers, lowercase because the request line is
    /// matched against a lowercased copy.
    const path = "/t390.html";

    server: std.net.Server,
    port: u16,
    thread: std.Thread,
    /// Requests served so far. Written by the serving thread, read by the
    /// test — atomically, because they are different threads.
    requests: std.atomic.Value(u32) = .init(0),
    /// Whether the LAST request asked for a cache bypass. Chromium sends
    /// `Cache-Control: no-cache` for a hard reload and `max-age=0` for a
    /// normal one, so this is the request-side proof that `ignoreCache`
    /// reached the wire.
    no_cache: std.atomic.Value(bool) = .init(false),
    /// See `TestPage.stopping` — same reason, same shutdown handshake.
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(self: *ReloadPage) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.server = try addr.listen(.{ .reuse_address = true });
        errdefer self.server.deinit();
        self.port = self.server.listen_address.getPort();
        self.requests = .init(0);
        self.no_cache = .init(false);
        self.stopping = .init(false);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Wake the accept with a real connection before closing the listener — see
    /// `TestPage.stop` (T430).
    fn stop(self: *ReloadPage) void {
        self.stopping.store(true, .monotonic);
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.server.deinit();
    }

    fn serve(self: *ReloadPage) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            if (self.stopping.load(.monotonic)) return;
            setRecvTimeout(conn.stream.handle, 2000);

            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = socket_rw.readStream(conn.stream, buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            // A preconnect that never asked for anything — see `TestPage.serve`.
            if (total == 0) continue;
            // ASCII-insensitive: header VALUES are not case-normalized by
            // anyone, and matching only the lowercase spelling would make the
            // oracle depend on Chromium's capitalization.
            var lower_buf: [4096]u8 = undefined;
            const lower = std.ascii.lowerString(lower_buf[0..total], buf[0..total]);

            // Only the PAGE counts. Chromium asks every origin it visits for a
            // `/favicon.ico` that was never offered, so a server that counted
            // every request reported four fetches for two loads — and served
            // the favicon request an HTML body carrying the next number, which
            // put the page one ahead of the truth. Counting the document alone
            // is what makes "requests == 2" mean "loaded twice".
            if (std.mem.indexOf(u8, lower, "get " ++ path ++ " ") == null) {
                socket_rw.writeAllStream(
                    conn.stream,
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                ) catch {};
                _ = std.os.windows.ws2_32.shutdown(
                    conn.stream.handle,
                    std.os.windows.ws2_32.SD_SEND,
                );
                continue;
            }

            self.no_cache.store(
                std.mem.indexOf(u8, lower, "no-cache") != null,
                .release,
            );
            const n = self.requests.fetchAdd(1, .acq_rel) + 1;

            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf,
                \\<!doctype html><meta charset="utf-8"><title>t390</title>
                \\<p>request {d}</p>
                \\<script>
                \\(function () {{
                \\  var w = window.webkit && window.webkit.messageHandlers
                \\    && window.webkit.messageHandlers.viewerTOC;
                \\  if (!w) return;
                \\  w.postMessage({{ type: "active", id: "req{d}" }});
                \\}})();
                \\</script>
                \\
            , .{ n, n }) catch continue;

            var head_buf: [220]u8 = undefined;
            const head = std.fmt.bufPrint(
                &head_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" ++
                    "Cache-Control: max-age=600\r\n" ++
                    "Content-Length: {d}\r\nConnection: close\r\n\r\n",
                .{body.len},
            ) catch continue;
            socket_rw.writeAllStream(conn.stream, head) catch continue;
            socket_rw.writeAllStream(conn.stream, body) catch continue;
            _ = std.os.windows.ws2_32.shutdown(
                conn.stream.handle,
                std.os.windows.ws2_32.SD_SEND,
            );
        }
    }
};

test "page messages land on the pane, in the pane's own memory" {
    // The bridge's native half without a browser: what `onWebMessageReceived`
    // does once the JSON is parsed. The oracle that matters is OWNERSHIP — the
    // parse arena is freed the moment the COM callback returns, so a pane that
    // kept the arena's slices would be reading freed memory on the next repaint.
    const alloc = testing.allocator;
    var pane: ViewerPane = .{};
    defer pane.deinit(alloc);

    {
        const parsed = bridge.parse(alloc,
            \\{"type":"headings","items":[
            \\  {"id":"one","text":"One","level":1},
            \\  {"id":"two","text":"Two","level":2}]}
        ).?;
        pane.applyMessage(alloc, parsed.message);
        // Freed HERE, before a single assertion: the pane's copies have to
        // stand on their own from this line on.
        parsed.deinit();
    }
    try testing.expectEqual(@as(usize, 2), pane.headings.len);
    try testing.expectEqualStrings("one", pane.headings[0].id);
    try testing.expectEqualStrings("One", pane.headings[0].text);
    try testing.expectEqual(@as(u8, 1), pane.headings[0].level);
    try testing.expectEqualStrings("two", pane.headings[1].id);
    try testing.expectEqual(@as(u8, 2), pane.headings[1].level);

    {
        const parsed = bridge.parse(alloc, "{\"type\":\"active\",\"id\":\"two\"}").?;
        pane.applyMessage(alloc, parsed.message);
        parsed.deinit();
    }
    try testing.expectEqualStrings("two", pane.active_heading.?);

    // A second document replaces the first outright rather than appending, and
    // the testing allocator is the oracle for the old list being freed.
    {
        const parsed = bridge.parse(alloc, "{\"type\":\"headings\",\"items\":[{\"id\":\"x\",\"text\":\"X\",\"level\":1}]}").?;
        pane.applyMessage(alloc, parsed.message);
        parsed.deinit();
    }
    try testing.expectEqual(@as(usize, 1), pane.headings.len);
    try testing.expectEqualStrings("x", pane.headings[0].id);
    // Replacing the headings clears the active id with them: it named a heading
    // in a document that is gone.
    try testing.expectEqual(@as(?[]u8, null), pane.active_heading);

    // An empty list is a real message (the page cleared its document), and it
    // has to empty the pane rather than be ignored.
    {
        const parsed = bridge.parse(alloc, "{\"type\":\"headings\",\"items\":[]}").?;
        pane.applyMessage(alloc, parsed.message);
        parsed.deinit();
    }
    try testing.expectEqual(@as(usize, 0), pane.headings.len);

    // A quote arriving at a pane with nowhere to FILE (no worktree, and here
    // no window either) is dropped rather than half-accepted: the composer
    // never opens, the registry stays empty, and nothing else in the pane
    // moves. That is the same refusal the feedback BUTTON makes, and it has to
    // survive on this path too — `+split --view=https://example.com` in a
    // directory outside any repo is exactly this pane.
    {
        const parsed = bridge.parse(alloc, "{\"type\":\"quote\",\"text\":\"hello\"}").?;
        pane.applyMessage(alloc, parsed.message);
        parsed.deinit();
    }
    try testing.expectEqual(@as(usize, 0), pane.headings.len);
    try testing.expect(!pane.feedback_open);
    try testing.expectEqual(@as(usize, 0), pane.feedback_quotes.entries.items.len);
    try testing.expectEqual(@as(usize, 0), pane.feedbackQuoteCount(alloc));
}

test "a page message that arrives after the pane is gone is dropped" {
    // Same hazard as the new-window handler: the runtime can invoke an event
    // handler after the pane it was registered for has been closed. The token
    // is what makes that survivable, and the testing allocator is the oracle.
    const alloc = testing.allocator;
    const p = try alloc.create(Pending);
    var pane: ViewerPane = .{};
    p.* = .{ .pane = &pane, .refs = 2, .alloc = alloc };
    pane.pending = p;

    pane.deinit(alloc);
    try testing.expectEqual(@as(?*ViewerPane, null), p.pane);
    // No args object either, which is the other null this path has to tolerate.
    try testing.expectEqual(com.S_OK, onWebMessageReceived(p, null, null));
    p.release();
}

test "visibility is recorded even before a controller exists" {
    // A pane hidden while its controller is still coming up must come up
    // hidden — `adoptController` replays `visible`, and the pane is the one
    // holding that truth.
    var pane: ViewerPane = .{};
    try testing.expect(pane.visible);
    pane.setVisible(false);
    try testing.expect(!pane.visible);
    pane.setVisible(true);
    try testing.expect(pane.visible);

    // Same for focus: the WM_SETFOCUS that arrives before the controller must
    // not be lost.
    try testing.expect(!pane.focused);
    pane.focus();
    try testing.expect(pane.focused);
}

test "a restored open re-homes the pane; a fresh open homes it where it went" {
    // The T90h round-trip, with no browser in it: a pane restored at the place
    // it had NAVIGATED to must keep the home it was OPENED with, or the Home
    // button quietly starts meaning "wherever you last were".
    const alloc = testing.allocator;

    var restored: ViewerPane = .{};
    defer restored.deinit(alloc);
    const open: Open = .{
        .location = "https://example.com/",
        .home_location = "D:\\git\\ghoztty\\README.md",
        .origin_directory = "D:\\git\\ghoztty",
    };
    try restored.navigate(alloc, open.location);
    // Navigation seeds home from the location — the fresh-open behavior — and
    // the override has to land ON TOP of it, which is the whole reason
    // `applyOpenMetadata` runs after `navigate` and not before.
    try testing.expectEqualStrings("https://example.com/", restored.home_location.?);
    restored.applyOpenMetadata(alloc, open);
    try testing.expectEqualStrings("https://example.com/", restored.location.?);
    try testing.expectEqualStrings("D:\\git\\ghoztty\\README.md", restored.home_location.?);
    try testing.expectEqualStrings("D:\\git\\ghoztty", restored.origin_directory.?);

    // A FRESH open says nothing about home or origin, so navigation's own seed
    // stands and the pane records no origin at all.
    var fresh: ViewerPane = .{};
    defer fresh.deinit(alloc);
    const plain: Open = .{ .location = "about:blank" };
    try fresh.navigate(alloc, plain.location);
    fresh.applyOpenMetadata(alloc, plain);
    try testing.expectEqualStrings("about:blank", fresh.home_location.?);
    try testing.expect(fresh.origin_directory == null);

    // And a later navigation still moves only `location`: the override is not a
    // new rule, it is the same one restore has to be able to state explicitly.
    try fresh.navigate(alloc, "https://example.org/");
    try testing.expectEqualStrings("https://example.org/", fresh.location.?);
    try testing.expectEqualStrings("about:blank", fresh.home_location.?);
}

test "T380: the dim overlay glues to the host window and follows it" {
    // The viewer half of T74, proven on the host floor alone — no WebView2.
    // The overlay is a property of the HOST window (T373), so a pane whose
    // controller never arrived still dims correctly; the composited look on a
    // real split is the acceptance script's oracle, not this one's.
    const alloc = testing.allocator;
    const hinstance = w32.GetModuleHandleW(null);
    _ = registerClass(hinstance);
    defer _ = w32.UnregisterClassW(CLASS_NAME, hinstance);

    const parent_class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyDimTestParent");
    const pc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &w32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = parent_class,
        .hIconSm = null,
    };
    _ = w32.RegisterClassExW(&pc);
    defer _ = w32.UnregisterClassW(parent_class, hinstance);

    const parent = w32.CreateWindowExW(
        0,
        parent_class,
        std.unicode.utf8ToUtf16LeStringLiteral("dim test"),
        w32.WS_OVERLAPPEDWINDOW,
        0,
        0,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(parent);

    var pane: ViewerPane = .{};
    defer pane.deinit(alloc);

    // No host window yet: the call must be a safe no-op, the way every other
    // pre-createHostWindow entry point is.
    pane.showDimOverlay(alloc, w32.RGB(16, 16, 20), 77);
    try testing.expect(pane.dim_overlay == null);

    try pane.createHostWindow(hinstance, parent, .{ .left = 0, .top = 0, .right = 300, .bottom = 200 });
    const host = pane.hwnd.?;

    pane.showDimOverlay(alloc, w32.RGB(16, 16, 20), 77);
    const d = pane.dim_overlay orelse return error.NoOverlay;
    try testing.expect(shownByStyle(d.hwnd));

    // Click-through, non-activating, DWM-composited — the T74 contract, and
    // the reason a dimmed viewer still takes the click that focuses it.
    const ex: u32 = @bitCast(w32.GetWindowLongW(d.hwnd, w32.GWL_EXSTYLE));
    try testing.expect(ex & w32.WS_EX_LAYERED != 0);
    try testing.expect(ex & w32.WS_EX_TRANSPARENT != 0);
    try testing.expect(ex & w32.WS_EX_NOACTIVATE != 0);

    // Glued to the host: same screen rect.
    var host_rect: w32.RECT = undefined;
    var overlay_rect: w32.RECT = undefined;
    try testing.expect(w32.GetWindowRect(host, &host_rect) != 0);
    try testing.expect(w32.GetWindowRect(d.hwnd, &overlay_rect) != 0);
    try testing.expectEqual(host_rect, overlay_rect);

    // A divider drag moves the host; the next update call must re-glue.
    _ = w32.MoveWindow(host, 40, 30, 150, 100, 0);
    pane.showDimOverlay(alloc, w32.RGB(16, 16, 20), 77);
    try testing.expect(w32.GetWindowRect(host, &host_rect) != 0);
    try testing.expect(w32.GetWindowRect(d.hwnd, &overlay_rect) != 0);
    try testing.expectEqual(host_rect, overlay_rect);

    // Focus back: the overlay hides but stays allocated for the next flip.
    pane.hideDimOverlay();
    try testing.expect(!shownByStyle(d.hwnd));
    try testing.expect(pane.dim_overlay != null);

    // The heal pass runs against a live overlay without complaint (T142).
    pane.healOverlayZOrders();
}

// -------------------------------------------------------------------------
// T163: popup adoption, against the live runtime
// -------------------------------------------------------------------------

/// A loopback HTTP server whose one page opens a popup, for the T163 test.
///
/// The opener does its `window.open()` from `onload` and keeps the returned
/// handle on `window.__w`, which is what makes the whole thing checkable: a
/// popup that was really ADOPTED is the window that handle names, so writing
/// through it lands in our pane and `__w.close()` closes it. A popup we merely
/// re-navigated to the same location would be a different window, and both
/// would be silent no-ops.
const PopupPage = struct {
    /// Non-square on purpose: `ICoreWebView2WindowFeatures` puts `Height`
    /// before `Width` in its vtable, and a square request could not tell a
    /// swapped pair from a correct one.
    const want_w = 520;
    const want_h = 680;
    /// What the opener writes into the adopted popup, read back off the popup
    /// pane's title (which arrives over `DocumentTitleChanged`).
    const popup_title = "t163-adopted";

    const html = std.fmt.comptimePrint(
        \\<!doctype html><meta charset="utf-8"><title>t163-opener</title>
        \\<body>opener
        \\<script>
        \\window.addEventListener("load", function () {{
        \\  window.__w = window.open("", "t163", "width={d},height={d}");
        \\  if (window.__w) {{
        \\    window.__w.document.write(
        \\      "<!doctype html><title>{s}</title><body>popup");
        \\    window.__w.document.close();
        \\  }}
        \\}});
        \\</script>
        \\
    , .{ want_w, want_h, popup_title });

    server: std.net.Server,
    port: u16,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(self: *PopupPage) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.server = try addr.listen(.{ .reuse_address = true });
        errdefer self.server.deinit();
        self.port = self.server.listen_address.getPort();
        self.stopping = .init(false);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Wake the accept, then close — `TestPage.stop`'s rule, same reason (T430).
    fn stop(self: *PopupPage) void {
        self.stopping.store(true, .monotonic);
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.server.deinit();
    }

    fn serve(self: *PopupPage) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            if (self.stopping.load(.monotonic)) return;
            setRecvTimeout(conn.stream.handle, 2000);

            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = socket_rw.readStream(conn.stream, buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            // A Chromium preconnect that asked nothing; see `TestPage.serve`.
            if (total == 0) continue;

            var head_buf: [160]u8 = undefined;
            const head = std.fmt.bufPrint(
                &head_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" ++
                    "Content-Length: {d}\r\nConnection: close\r\n\r\n",
                .{html.len},
            ) catch return;
            socket_rw.writeAllStream(conn.stream, head) catch continue;
            socket_rw.writeAllStream(conn.stream, html) catch continue;
            _ = std.os.windows.ws2_32.shutdown(
                conn.stream.handle,
                std.os.windows.ws2_32.SD_SEND,
            );
        }
    }
};

/// Test seam for the popup trampoline (the live T163 test only). It stands in
/// for `Window.openPopupWindowFromViewer` under the same contract — take a
/// reference on the request, build a pane that carries it, and let that pane
/// answer the runtime — without an `App` or a split tree to build a real
/// window in.
const PopupSink = struct {
    alloc: Allocator,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
    host: *webview2.Host,

    /// How many popups the trampoline was asked to open, and what the last one
    /// asked for.
    seen: u32 = 0,
    size: ?PopupSize = null,
    location_buf: [256]u8 = undefined,
    location_len: usize = 0,

    /// The adopted pane. Deliberately WITHOUT a `pane_view`: a leaf implies a
    /// live `parent_window` (that is what `notifyTitle` dereferences), and this
    /// pane has none. Both seams the popup path uses are keyed on the pane for
    /// exactly this reason.
    pane: ?*ViewerPane = null,

    /// Whether the pane's close seam ran — the observable end of
    /// `window.close()`.
    closed: bool = false,

    fn location(self: *const PopupSink) []const u8 {
        return self.location_buf[0..self.location_len];
    }

    fn deinit(self: *PopupSink) void {
        if (self.pane) |p| {
            p.deinit(self.alloc);
            self.alloc.destroy(p);
            self.pane = null;
        }
    }
};
var popup_sink: ?*PopupSink = null;

fn testPopupOpen(v: *ViewerPane, open: PopupOpen) void {
    _ = v;
    const sink = popup_sink orelse return;
    sink.seen += 1;
    sink.size = open.size;
    sink.location_len = @min(open.location.len, sink.location_buf.len);
    @memcpy(sink.location_buf[0..sink.location_len], open.location[0..sink.location_len]);

    // Everything below mirrors `Window.createViewerPane`, in the same order and
    // for the same reasons — most of all the retain before anything fallible.
    const viewer = sink.alloc.create(ViewerPane) catch return;
    viewer.* = .{};
    {
        var id_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);
        _ = pane_id_mod.format(&viewer.pane_id, id_bytes);
    }
    viewer.close_from_page = &testPopupClose;
    open.req.retain();
    viewer.popup = open.req;
    sink.pane = viewer;

    viewer.createHostWindow(
        sink.hinstance,
        sink.parent,
        .{ .left = 0, .top = 0, .right = 400, .bottom = 300 },
    ) catch return;
    viewer.navigate(sink.alloc, open.location) catch {};
    viewer.start(sink.alloc, sink.host);
}

fn testPopupClose(v: *ViewerPane) void {
    _ = v;
    if (popup_sink) |s| s.closed = true;
}

fn popupWasSeen(p: *ViewerPane) bool {
    _ = p;
    const s = popup_sink orelse return false;
    return s.seen > 0;
}

fn popupSettled(p: *ViewerPane) bool {
    return p.state != .waiting_env and p.state != .creating;
}

fn popupWroteTitle(p: *ViewerPane) bool {
    const t = p.title orelse return false;
    return std.mem.eql(u8, t, PopupPage.popup_title);
}

fn popupWasClosed(p: *ViewerPane) bool {
    _ = p;
    const s = popup_sink orelse return false;
    return s.closed;
}

fn aLinkWasRouted(p: *ViewerPane) bool {
    _ = p;
    const s = link_sink orelse return false;
    return s.entries.items.len > 0;
}

test "T163: a popup is adopted as a pane, sized, and can close itself" {
    // The claim under test is an ABI handshake — `GetDeferral`,
    // `put_NewWindow`, `WindowFeatures`, `add_WindowCloseRequested` — so it can
    // only be made against the live runtime, exactly like the host floor above.
    // On a box with no runtime the pane lands in `.failed` and the test says so
    // loudly rather than passing empty (T372's rule).
    const alloc = testing.allocator;

    var test_profile = try webview2.TestProfile.begin(alloc);
    defer test_profile.end();

    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);

    const hinstance = w32.GetModuleHandleW(null);
    _ = registerClass(hinstance);
    defer _ = w32.UnregisterClassW(CLASS_NAME, hinstance);

    const parent_class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPopupTestParent");
    const pc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &w32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = parent_class,
        .hIconSm = null,
    };
    _ = w32.RegisterClassExW(&pc);
    defer _ = w32.UnregisterClassW(parent_class, hinstance);

    const parent = w32.CreateWindowExW(
        0,
        parent_class,
        std.unicode.utf8ToUtf16LeStringLiteral("popup test"),
        w32.WS_OVERLAPPEDWINDOW,
        0,
        0,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(parent);

    var host = webview2.Host.init(alloc);
    defer host.deinit();

    var sink: PopupSink = .{
        .alloc = alloc,
        .hinstance = hinstance,
        .parent = parent,
        .host = &host,
    };
    defer sink.deinit();
    popup_sink = &sink;
    defer popup_sink = null;

    // The browser leg must never reach `ShellExecuteW` from a test lane: it
    // would open the user's real browser over a green run.
    var links: LinkSink = .{ .alloc = alloc };
    defer links.deinit();
    link_sink = &links;
    defer link_sink = null;

    var page: PopupPage = undefined;
    try page.start();
    defer page.stop();

    var url_buf: [64]u8 = undefined;
    const opener_url = try std.fmt.bufPrint(
        &url_buf,
        "http://127.0.0.1:{d}/opener.html",
        .{page.port},
    );

    var opener: ViewerPane = .{};
    defer opener.deinit(alloc);
    {
        var id_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);
        _ = pane_id_mod.format(&opener.pane_id, id_bytes);
    }
    // No `pane_view` on either pane in this test, on purpose: setting one makes
    // `notifyTitle` dereference `parent_window`, which a bare pane leaves
    // undefined. The popup seams are pane-keyed so this stays possible.
    opener.open_popup_window = &testPopupOpen;

    try opener.createHostWindow(hinstance, parent, .{ .left = 0, .top = 0, .right = 640, .bottom = 480 });
    try opener.navigate(alloc, opener_url);
    opener.start(alloc, &host);

    var msg: w32.MSG = undefined;
    const settled = webview2.pumpUntil(&opener, struct {
        fn f(ctx: *const anyopaque) bool {
            const p: *const ViewerPane = @ptrCast(@alignCast(ctx));
            return p.state != .waiting_env and p.state != .creating;
        }
    }.f);
    if (!settled) {
        log.err("T163: no controller within the deadline (still {s})", .{@tagName(opener.state)});
        return error.WebView2ControllerTimeout;
    }
    if (opener.state == .failed) {
        log.warn(
            "SKIPPED live popup test, no usable runtime: {s}",
            .{@tagName(opener.failure.?)},
        );
        return;
    }
    log.warn("T163: opener controller ready, scale={d}", .{opener.scale});

    // ------------------------------------------------------------------
    // The page's `window.open("", "t163", "width=…,height=…")` is adopted.
    // ------------------------------------------------------------------
    try waitFor(&msg, 30, popupWasSeen, &opener);
    try testing.expectEqual(@as(u32, 1), sink.seen);
    // A popup that named no URL is the blank page its script writes into —
    // Mac's nil-URL case, which WebView2 spells `about:blank`.
    try testing.expectEqualStrings(content.blank_page, sink.location());

    // The size the opener asked for, scaled to this monitor. Non-square, so a
    // swapped Height/Width pair in the WindowFeatures vtable shows up here and
    // nowhere else in the tree.
    const want = viewer_popup.requestedSize(
        true,
        PopupPage.want_w,
        PopupPage.want_h,
        opener.scale,
    ).?;
    try testing.expectEqual(want, sink.size.?);
    log.warn("T163: popup asked for {d}x{d} physical", .{ want.w, want.h });

    const popup = sink.pane orelse return error.NoPopupPane;
    try waitFor(&msg, 30, popupSettled, popup);
    try testing.expectEqual(State.ready, popup.state);

    // THE ORACLE. The opener kept the handle `window.open()` returned and wrote
    // a document through it. That document can only land in this pane if the
    // pane IS the window the runtime handed the script — which is precisely
    // what `put_NewWindow` buys, and what opening a pane of our own at the same
    // location would not. The title arrives over `DocumentTitleChanged`.
    try waitFor(&msg, 30, popupWroteTitle, popup);
    try testing.expectEqualStrings(PopupPage.popup_title, popup.title.?);
    log.warn("T163: the opener wrote into the adopted pane", .{});

    // ------------------------------------------------------------------
    // `window.close()` on that handle closes the adopted pane.
    // ------------------------------------------------------------------
    try testing.expect(!sink.closed);
    opener.executeScript(alloc, "window.__w.close()");
    try waitFor(&msg, 30, popupWasClosed, &opener);
    try testing.expect(sink.closed);
    log.warn("T163: window.close() reached the pane's close action", .{});

    // ------------------------------------------------------------------
    // …and the OTHER leg: an http(s) popup still leaves for the browser. This
    // is the positive control for every "was adopted" claim above — without it
    // a routing bug that adopted everything would look identical.
    // ------------------------------------------------------------------
    var web_buf: [96]u8 = undefined;
    const web_url = try std.fmt.bufPrint(
        &web_buf,
        "http://127.0.0.1:{d}/elsewhere.html",
        .{page.port},
    );
    var script_buf: [192]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "window.open('{s}')", .{web_url});
    opener.executeScript(alloc, script);
    try waitFor(&msg, 30, aLinkWasRouted, &opener);
    try testing.expectEqual(@as(usize, 1), links.entries.items.len);
    var expect_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "browser:{s}", .{web_url});
    try testing.expectEqualStrings(expected, links.entries.items[0]);
    // And it did NOT also become a pane.
    try testing.expectEqual(@as(u32, 1), sink.seen);
    log.warn("T163: an http popup still reached the default browser", .{});
}
