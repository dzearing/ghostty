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
const pane_id_mod = @import("pane_id.zig");
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

/// Mirrors `Surface.visible`: false while the pane's tab is not selected or
/// the window is minimized.
visible: bool = true,

/// Whether the pane currently holds keyboard focus, so a controller that
/// arrives late still lands focus where the user put it.
focused: bool = false,

state: State = .idle,

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
    self.clearHeadings(alloc);
    if (self.hwnd) |h| {
        _ = w32.SetWindowLongPtrW(h, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(h);
        self.hwnd = null;
    }
    if (self.title) |t| alloc.free(t);
    if (self.location) |l| alloc.free(l);
    if (self.home_location) |l| alloc.free(l);
    self.title = null;
    self.location = null;
    self.home_location = null;
    self.state = .idle;
}

/// This pane's stable id (T113).
pub fn paneId(self: *const ViewerPane) []const u8 {
    return &self.pane_id;
}

/// Replace the pane title. Dupes; the pane owns the copy.
pub fn setTitle(self: *ViewerPane, alloc: Allocator, value: []const u8) Allocator.Error!void {
    const dup = try alloc.dupeZ(u8, value);
    if (self.title) |t| alloc.free(t);
    self.title = dup;
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
    if (self.home_location == null) {
        self.home_location = alloc.dupeZ(u8, url) catch null;
    }
    self.applyNavigation();
}

fn applyNavigation(self: *ViewerPane) void {
    const c = self.controller orelse return;
    const loc = self.location orelse return;
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
    // Before the navigation below, and that ordering is the contract: a script
    // registered after a page has started loading does not reach that page, so
    // the very first document a pane shows would be the one without a toolbar.
    self.subscribeBridge();
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

    // `Navigate` (slot 5) is only verifiable by reading `get_Source` back:
    // navigating at the WRONG slot can still return S_OK, and the page not
    // moving is the only thing that says so.
    //
    // The destination is a real local FILE, and that choice is the whole
    // oracle. A freshly created web view already reports `about:blank` as its
    // source, so navigating THERE and finding it would be a green and empty
    // assertion — true before the call ran. (A `data:` URL was the first
    // attempt and is wrong for a different reason: Chromium blocks top-level
    // navigation to one, so the source came back empty.) A file needs no
    // network, so this holds on a box with no route out.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t374.html", .data = "<title>ghoztty</title>" });
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const target = try std.fmt.allocPrint(alloc, "file:///{s}/t374.html", .{dir_path});
    defer alloc.free(target);
    std.mem.replaceScalar(u8, target["file:///".len..], '\\', '/');

    const before = source: {
        const raw = web.sourceRaw() orelse break :source @as(?[]u8, null);
        defer w32.CoTaskMemFree(@ptrCast(raw));
        break :source std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(raw)) catch null;
    };
    defer if (before) |prev| alloc.free(prev);
    try testing.expect(!std.mem.eql(u8, before orelse "", target));

    try pane.navigate(alloc, target);
    var nav_timer = try std.time.Timer.start();
    var source: ?[]u8 = null;
    defer if (source) |s| alloc.free(s);
    while (nav_timer.read() < 30 * std.time.ns_per_s) {
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        if (web.sourceRaw()) |raw| {
            defer w32.CoTaskMemFree(@ptrCast(raw));
            const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(raw)) catch null;
            if (utf8) |u| {
                if (source) |s| alloc.free(s);
                source = u;
                if (std.mem.endsWith(u8, u, "/t374.html")) break;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    log.warn("navigated: source={s}", .{source orelse "<none>"});
    // Asserted by SHAPE, not by string equality: the browser normalizes a file
    // URL (drive-letter case, percent-encoding), and pinning the exact spelling
    // would be asserting Chromium's formatting rather than our navigation.
    // "it moved, and it moved THERE" is the whole claim.
    const got = source orelse "";
    try testing.expect(!std.mem.eql(u8, got, before orelse ""));
    try testing.expect(std.mem.startsWith(u8, got, "file:///"));
    try testing.expect(std.mem.endsWith(u8, got, "/t374.html"));
    // And the pane recorded the place it was SENT, which is what
    // `+list --json`'s `url` and the session manifest read. `home_location` is
    // the FIRST location and does not move with it.
    try testing.expectEqualStrings(target, pane.location.?);
    try testing.expectEqualStrings(target, pane.home_location.?);

    // A second navigation moves `location` and leaves `home` where it was —
    // the pane's half of the Home button's contract.
    try pane.navigate(alloc, "about:blank");
    try testing.expectEqualStrings("about:blank", pane.location.?);
    try testing.expectEqualStrings(target, pane.home_location.?);

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
