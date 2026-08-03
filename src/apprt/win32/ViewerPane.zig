//! A viewer pane: a split-tree leaf that renders CONTENT (a markdown/text
//! file or a website) instead of a terminal. CLAUDE.md's "Viewer Panes"
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
const internal_os = @import("../../os/main.zig");
const pane_id_mod = @import("pane_id.zig");
const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.viewer_pane);

/// Window class for a viewer pane's host window. Registered once by
/// `App.init`; the name is what an acceptance script keys off to tell a viewer
/// pane from a terminal one.
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewer");

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

/// Where this pane currently IS. CLAUDE.md: `+list --json`'s `url` reports
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

/// Our reference on the `DocumentTitleChanged` handler (T383), same rule.
title_handler: ?*DocumentTitleChangedHandler = null,

/// Back-pointer to the split-tree leaf that owns this pane, set by
/// `PaneView.createViewer`. It is `Surface.pane_view`'s twin and exists for the
/// same reason: a title change has to name a LEAF to the window, and the pane
/// is what the title arrives at. Null for a pane that is not in a tree — which
/// is every pane in a unit test, and the reason `notifyTitle` is a no-op rather
/// than a dereference there.
pane_view: ?*PaneView = null,

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
    if (self.title_handler) |h| {
        h.release();
        self.title_handler = null;
    }
    if (self.env) |e| {
        e.release();
        self.env = null;
    }
    self.clearHeadings(alloc);
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
    if (self.resources_dir) |d| alloc.free(d);
    self.title = null;
    self.location = null;
    self.home_location = null;
    self.origin_directory = null;
    self.file_path = null;
    self.resources_dir = null;
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
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.readScale();
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
/// (CLAUDE.md's viewer contract, and P12's manifest fields). Later navigations
/// move `location` only.
///
/// Safe before there is a controller: the pane is the one holding this truth,
/// and `adoptController` replays it — the same rule `visible` and `focused`
/// already follow. That is not an edge case here, it is the NORMAL path: a
/// pane is constructed and told where to go long before a browser process
/// finishes starting.
pub fn navigate(self: *ViewerPane, alloc: Allocator, url: []const u8) Allocator.Error!void {
    const dup = try alloc.dupeZ(u8, url);
    if (self.location) |l| alloc.free(l);
    self.location = dup;
    // The document that WAS here is not the document being asked for, so the
    // pane has no completed load again until `onNavigationCompleted` says so.
    // Left stale, a `+reload` arriving during a navigation would re-render the
    // OLD file into the NEW page (T390).
    self.page_loaded = false;
    if (self.home_location == null) {
        self.home_location = alloc.dupeZ(u8, url) catch null;
    }

    // Re-derived on EVERY navigation rather than fixed at construction: the
    // same pane moves between a file and the web over its life (the address
    // bar, an in-page link), and a stale mode would render a website through
    // the markdown template.
    self.mode = content.modeFor(url);
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

    self.applyNavigation();
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
    const loc: []const u8 = if (self.mode.isFile())
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

fn onNewWindowRequested(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2NewWindowRequestedEventArgs,
) com.HRESULT {
    _ = sender;
    const a = args orelse return com.S_OK;

    // Handled FIRST, and unconditionally: whatever else goes wrong below, a
    // popup must not open a chrome-less WebView2 window we do not own and
    // cannot close. This is also the line T163 replaces — it will adopt the
    // request as a real ghoztty window instead of handing it to the browser —
    // which is why the deferral is left untaken rather than taken and dropped.
    _ = a.setHandled(true);

    // A pane that is already gone does not get to open browser tabs: the token
    // outlives it precisely so this check can be made.
    if (p.pane == null) return com.S_OK;

    const raw = a.uriRaw() orelse return com.S_OK;
    // The runtime allocated it on the COM heap; we free it on ours.
    defer w32.CoTaskMemFree(@ptrCast(raw));
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        raw,
        null,
        null,
        w32.SW_SHOW,
    );
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
        // The composer that consumes a quote is not built yet (design P10); the
        // bridge that carries it is, and dropping it silently here would make
        // the two indistinguishable from the outside.
        .quote => |q| log.debug(
            "viewer quote ({d} bytes) from heading={s}; no composer yet",
            .{ q.text.len, q.heading_id orelse "-" },
        ),
    }
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
}

fn setActiveHeading(self: *ViewerPane, alloc: Allocator, id: ?[]const u8) void {
    const dup: ?[]u8 = if (id) |v| (alloc.dupe(u8, v) catch return) else null;
    if (self.active_heading) |old| alloc.free(old);
    self.active_heading = dup;
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
        log.warn("viewer template failed to load; no content injected", .{});
        return com.S_OK;
    };
    self.page_loaded = true;
    // Web mode has nothing to inject — the page IS the content.
    if (!self.mode.isFile()) return com.S_OK;
    self.renderFileContent();
    return com.S_OK;
}

/// Reload this pane's content in place: the `+reload` verb, and (T391) the
/// file watcher's re-render. Mac's `ViewerView.reloadContent`, whose three-way
/// branch lives in `viewer_content.reloadPlan` so it is checkable without a
/// browser.
///
/// Safe to call in any state — a pane with no controller has no completed load
/// either, so it takes the `full_load` branch, and `applyNavigation` is already
/// a no-op until there is something to navigate.
pub fn reloadContent(self: *ViewerPane) void {
    switch (content.reloadPlan(self.mode, self.page_loaded)) {
        .full_load => self.applyNavigation(),
        .rerender => self.renderFileContent(),
        .refetch => self.refetchFromOrigin(),
    }
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
        .web => return,
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
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = content.requestPath(&path_buf, uri_buf[0..uri_len]) orelse {
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
        self.respond(env, a, alloc, "", "text/plain", 404, not_found_reason);
        return com.S_OK;
    };
    defer alloc.free(resolved);

    const bytes = std.fs.cwd().readFileAlloc(alloc, resolved, content.max_file_bytes) catch {
        log.warn("viewer resource is unreadable: {s}", .{resolved});
        self.respond(env, a, alloc, "", "text/plain", 404, not_found_reason);
        return com.S_OK;
    };
    defer alloc.free(bytes);

    self.respond(env, a, alloc, bytes, content.mimeType(content.extension(rel)), 200, ok_reason);
    return com.S_OK;
}

const ok_reason = std.unicode.utf8ToUtf16LeStringLiteral("OK");
const not_found_reason = std.unicode.utf8ToUtf16LeStringLiteral("Not Found");

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
fn respond(
    self: *ViewerPane,
    env: *iface.ICoreWebView2Environment,
    args: *iface.ICoreWebView2WebResourceRequestedEventArgs,
    alloc: Allocator,
    bytes: []const u8,
    mime: []const u8,
    status: i32,
    reason: [*:0]const u16,
) void {
    _ = self;
    var stream_ptr: ?*anyopaque = null;
    if (com.failed(w32.CreateStreamOnHGlobal(null, 1, &stream_ptr))) return;
    const stream: *iface.IStream = @ptrCast(@alignCast(stream_ptr orelse return));
    defer stream.release();
    if (!stream.writeAll(bytes)) return;
    if (!stream.rewind()) return;

    // The runtime parses a CRLF-joined header block, not a single header.
    const headers = std.fmt.allocPrint(alloc, "Content-Type: {s}", .{mime}) catch return;
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

/// Match the controller's bounds to the host window's client area. Bounds are
/// physical pixels in the HOST window's client coordinates, which is why this
/// reads `GetClientRect` rather than taking the layout rect: the two agree
/// only when the host window has already been moved, and the layout pass moves
/// it first.
pub fn syncBounds(self: *ViewerPane) void {
    const h = self.hwnd orelse return;
    self.readScale();
    const c = self.controller orelse return;
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(h, &r) == 0) return;
    _ = c.setBounds(.{
        .left = 0,
        .top = 0,
        .right = @max(r.right - r.left, 0),
        .bottom = @max(r.bottom - r.top, 0),
    });
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
    self.subscribeDocumentTitle();
    // Before the navigation below, and that ordering is the contract: a script
    // registered after a page has started loading does not reach that page, so
    // the very first document a pane shows would be the one without a toolbar.
    self.subscribeBridge();
    // Also before the navigation, and for a sharper reason: a file-mode pane's
    // very first request IS the template's document, so an interception
    // registered after `Navigate` would miss the page it exists to serve.
    self.subscribeFileMode();
    if (self.focused) _ = c.moveFocus(.programmatic);

    // Last, so the page starts loading into a view that is already the right
    // size, scale and scheme — a navigation that begins before the bounds are
    // set lays the document out twice and the user sees the reflow.
    self.applyNavigation();

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

fn fail(self: *ViewerPane, reason: webview2.Failure) void {
    self.state = .failed;
    self.failure = reason;
    log.info("viewer pane has no web view: {s}", .{@tagName(reason)});
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
            // The other two things that path does — `heroOnPaneFocused` and
            // `updateDimOverlays` — are deliberately NOT here: hero excludes
            // viewers (T90g) and the viewer dim overlay is T380.
            if (self.pane_view) |pv| {
                const win = self.parent_window;
                const tab = win.active_tab;
                win.tab_active_pane[tab] = pv;
                win.refreshTabTitle(tab);
            }
            return 0;
        },

        w32.WM_KILLFOCUS => {
            self.focused = false;
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
    var timer = try std.time.Timer.start();
    var msg: w32.MSG = undefined;
    while (pane.state == .waiting_env or pane.state == .creating) {
        if (timer.read() > 60 * std.time.ns_per_s) break;
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
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
    try waitFor(&msg, 30, struct {
        fn ready(p: *ViewerPane) bool {
            return p.active_heading != null and std.mem.eql(u8, p.active_heading.?, "req1");
        }
    }.ready, &pane);
    try testing.expectEqualStrings("req1", pane.active_heading.?);
    // The completed load is what makes the next call a RELOAD rather than a
    // first load, and it is set for web mode too (nothing is injected there,
    // so the flag is the only thing that navigation-completed leaves behind).
    try testing.expect(pane.page_loaded);

    pane.reloadContent();
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
    pane.reloadContent();
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

/// A loopback HTTP server serving one page, for the live bridge test.
///
/// A real `http://` origin is the point — `file://` and the bundled template
/// are both pages we author, and P2's claim is about the ones we do not. A
/// socket on 127.0.0.1 gives that without a network.
const TestPage = struct {
    server: std.net.Server,
    port: u16,
    thread: std.Thread,

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
        self.thread = try std.Thread.spawn(.{}, serve, .{&self.server});
    }

    fn stop(self: *TestPage) void {
        // Closing the listener is what unblocks the accept the thread is
        // sitting in; there is no other way to interrupt it portably.
        self.server.deinit();
        self.thread.join();
    }

    /// `socket_rw`, not `Stream.read`/`Stream.writeAll`.
    ///
    /// Those go through `ReadFile`/`WriteFile` with a null `OVERLAPPED`, and
    /// zig creates its sockets with `WSA_FLAG_OVERLAPPED` — which makes every
    /// call fail with `ERROR_INVALID_PARAMETER (87)`. That is T89b's finding
    /// and `socket_rw.readStream`/`writeAllStream` are the house answer to it;
    /// this test hit the same wall and uses them rather than growing a fourth
    /// private copy of `recv`.
    fn serve(server: *std.net.Server) void {
        while (true) {
            const conn = server.accept() catch return;
            defer conn.stream.close();

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

            var head_buf: [160]u8 = undefined;
            const head = std.fmt.bufPrint(&head_buf,
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

    fn start(self: *ReloadPage) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.server = try addr.listen(.{ .reuse_address = true });
        errdefer self.server.deinit();
        self.port = self.server.listen_address.getPort();
        self.requests = .init(0);
        self.no_cache = .init(false);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stop(self: *ReloadPage) void {
        self.server.deinit();
        self.thread.join();
    }

    fn serve(self: *ReloadPage) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();

            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = socket_rw.readStream(conn.stream, buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
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
            const head = std.fmt.bufPrint(&head_buf,
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
        const parsed = bridge.parse(alloc,
            "{\"type\":\"headings\",\"items\":[{\"id\":\"x\",\"text\":\"X\",\"level\":1}]}").?;
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

    // A quote has no consumer yet (design P10) and must not disturb what does.
    {
        const parsed = bridge.parse(alloc, "{\"type\":\"quote\",\"text\":\"hello\"}").?;
        pane.applyMessage(alloc, parsed.message);
        parsed.deinit();
    }
    try testing.expectEqual(@as(usize, 0), pane.headings.len);
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
