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
const pane_id_mod = @import("pane_id.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.viewer_pane);

/// Window class for a viewer pane's host window. Registered once by
/// `App.init`; the name is what an acceptance script keys off to tell a viewer
/// pane from a terminal one.
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewer");

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
    // after this point must find a dead token, not a half-freed pane.
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
        w32.WS_CHILD | w32.WS_CLIPCHILDREN,
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
    if (self.focused) _ = c.moveFocus(.programmatic);

    // Stop painting the empty background: from here the controller owns the
    // pixels.
    if (self.hwnd) |h| _ = w32.InvalidateRect(h, null, 1);
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
