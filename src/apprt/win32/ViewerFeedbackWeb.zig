//! The feedback composer's text surface: a second `ICoreWebView2Controller`
//! filling the pill's text rect, hosting the page in
//! `viewer_feedback_page.zig` (T934, answering D43).
//!
//! ## Why a whole second controller
//!
//! D43 asked which text control the composer should be built on and was
//! answered — against the recommendation — with "the same web view engine the
//! page beside it already uses". The reason is what a text control has to get
//! right that we would otherwise hand-carry: caret and selection, word wrap,
//! undo, the clipboard, drag and drop, IME composition for anyone writing in a
//! language that needs one, and a screen reader that can read the field back.
//! A browser engine has all of that; a control we drive by hand has whatever
//! we remembered to build.
//!
//! It is a SECOND controller rather than an overlay on the pane's own, and
//! that is not an implementation detail: chrome injected into the page would
//! have to survive arbitrary third-party CSS and z-index, and would put the
//! composer inside the very content it is reporting on. The pane's environment
//! is shared (one browser process, one user-data folder); only the controller
//! and its renderer are new.
//!
//! ## Lifetime — D43's own mitigation
//!
//! Created on the first OPEN and destroyed on CLOSE, with everything that has
//! to survive kept on the pane. That is what the decision's mitigation asked
//! for: a composer nobody has opened costs a closed pane nothing, and a
//! composer that has been closed gives its renderer back. The consequence to
//! rely on is that this object owns NO state a user would miss — the report
//! text lives in `pane.feedbackText()`, and every open re-seeds the page from
//! it.
//!
//! ## Everything here is asynchronous, and that is the shape change
//!
//! The RichEdit this replaces answered `caret()`, `lineCount()` and a text read
//! on the caller's own stack. A WebView2 answers through callbacks, so the
//! ownership flips: the PAGE owns the live document and pushes a snapshot up
//! on every edit, and this object keeps the last snapshot as the truth the bar
//! lays out from and the pane serializes from. Nothing here ever asks the page
//! a question.
//!
//! Two consequences worth knowing:
//!
//! - **Creation can still be in flight when the composer is closed again.**
//!   Every runtime callback goes through a refcounted `Token` whose back
//!   pointer is nulled on destroy, the same shape `ViewerPane.Pending` uses —
//!   a controller that completes into a dead composer is closed on the spot.
//! - **The page is not writable until it says `ready`.** Seeds and vars that
//!   arrive before that are held and flushed there, which is also what makes a
//!   page that reloaded itself heal instead of blanking the report.

const ViewerFeedbackWeb = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const iface = @import("webview2_iface.zig");
const page = @import("viewer_feedback_page.zig");
const ViewerFeedbackBar = @import("ViewerFeedbackBar.zig");

const log = std.log.scoped(.viewer_feedback);

/// The runtime's handle on a composer that may already be gone.
///
/// Identical in shape and in reason to `ViewerPane.Pending`: a controller
/// creation, a message subscription and an accelerator subscription all hold a
/// reference, and any of them can be invoked after the user has closed the
/// composer. `owner` is nulled by `destroy`, so a late callback finds a null
/// and does nothing instead of reading freed memory.
const Token = struct {
    owner: ?*ViewerFeedbackWeb,
    refs: u8,
    alloc: Allocator,

    fn release(self: *Token) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.alloc.destroy(self);
    }
};

fn releaseToken(t: *Token) void {
    t.release();
}

alloc: Allocator,
bar: *ViewerFeedbackBar,
/// The controller's parent — the composer BAND's window, so bounds are in the
/// same client coordinates `viewer_feedback_layout.Layout` already speaks.
parent: w32.HWND,
token: *Token,

controller: ?*iface.ICoreWebView2Controller = null,
message_handler: ?*WebMessageReceivedHandler = null,
accel_handler: ?*AcceleratorKeyPressedHandler = null,

/// The page has loaded and answered `ready`.
ready: bool = false,
/// What the host asked for before the controller existed, replayed on adoption
/// and again on every `ready`.
bounds: iface.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
visible: bool = false,
scale: f32 = 1.0,
/// A focus request that arrived before there was anything to focus.
want_focus: bool = false,

/// The last snapshot the page pushed. This is what `lines` and `caret` mean
/// now: the answer as of the last edit, not a question anyone asks.
lines: u32 = 1,
caret: ?u32 = null,
/// How many seeds have gone down. Stamped into each one and echoed back in
/// every snapshot, so a snapshot measured before the latest seed is
/// recognisable and dropped rather than being written over the newer buffer.
seed_gen: u32 = 0,
/// Whether the editable box holds the caret, as the PAGE reports it. Kept
/// alongside the window-based test in `ViewerFeedbackBar.hasFocus` rather than
/// instead of it: the window test covers the moment focus is inside the
/// renderer but the box has not been told yet.
focused: bool = false,

// -------------------------------------------------------------------------
// Lifecycle
// -------------------------------------------------------------------------

/// Begin creating the composer's web view on the pane's existing environment.
///
/// Returns null only when the object itself could not be allocated or the
/// creation call was refused outright — a pane without a working environment
/// cannot exist in the first place (it would have shown an error card), so
/// there is no fallback text control owed here. That is what makes replacing
/// the RichEdit acceptable rather than keeping a second code path forever.
pub fn create(
    alloc: Allocator,
    bar: *ViewerFeedbackBar,
    parent: w32.HWND,
    env: *iface.ICoreWebView2Environment,
) ?*ViewerFeedbackWeb {
    const self = alloc.create(ViewerFeedbackWeb) catch return null;
    const token = alloc.create(Token) catch {
        alloc.destroy(self);
        return null;
    };
    // Two references: ours, and the one the creation callback carries.
    token.* = .{ .owner = self, .refs = 2, .alloc = alloc };
    self.* = .{
        .alloc = alloc,
        .bar = bar,
        .parent = parent,
        .token = token,
    };

    const handler = ControllerCompletedHandler.create(alloc, token) catch {
        token.refs -= 1; // the callback's reference is never taken
        self.destroyNow();
        return null;
    };
    // Ours; the runtime takes its own if it keeps the object. Releasing here
    // frees it outright when the call below fails before any AddRef, which is
    // the point.
    defer handler.release();

    const hr = env.createController(parent, @ptrCast(handler));
    if (com.failed(hr)) {
        log.warn("composer CreateCoreWebView2Controller hr=0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        // The handler will never be invoked, so its reference ends here.
        token.release();
        self.destroyNow();
        return null;
    }
    log.info("viewer composer controller requested", .{});
    return self;
}

/// Tear the composer's web view down. The text is NOT lost: it lives on the
/// pane, and the next open re-seeds the page from it.
pub fn destroy(self: *ViewerFeedbackWeb) void {
    // Before anything can be invoked again: a runtime callback that lands
    // during `Close` must find a null owner rather than a half-dead object.
    self.token.owner = null;
    if (self.controller) |c| {
        self.controller = null;
        // Close BEFORE release: the renderer process is a child of the
        // controller, and dropping the last reference without closing leaks it
        // for the life of the app.
        c.close();
        c.release();
    }
    if (self.message_handler) |h| {
        self.message_handler = null;
        h.release();
    }
    if (self.accel_handler) |h| {
        self.accel_handler = null;
        h.release();
    }
    log.info("viewer composer destroyed", .{});
    self.destroyNow();
}

/// Free the object and drop OUR token reference. Split out so the failure
/// paths in `create` can use it before anything has been subscribed.
fn destroyNow(self: *ViewerFeedbackWeb) void {
    const alloc = self.alloc;
    const token = self.token;
    token.owner = null;
    alloc.destroy(self);
    token.release();
}

/// `ICoreWebView2CreateCoreWebView2ControllerCompletedHandler`.
const ControllerCompletedHandler = com.CallbackOwning(
    iface.IID_ControllerCompletedHandler,
    onControllerCompleted,
    releaseToken,
);

fn onControllerCompleted(
    t: *Token,
    result: com.HRESULT,
    controller: ?*iface.ICoreWebView2Controller,
) com.HRESULT {
    const self = t.owner orelse {
        // Closed while creation was in flight. The controller still has to be
        // closed, or its renderer outlives the composer that asked for it.
        if (controller) |c| c.close();
        return com.S_OK;
    };
    if (com.failed(result) or controller == null) {
        log.warn("composer controller creation failed hr=0x{X:0>8}", .{@as(u32, @bitCast(result))});
        return com.S_OK;
    }
    // Borrowed for the duration of Invoke; we are keeping it.
    controller.?.addRef();
    self.adopt(controller.?);
    return com.S_OK;
}

/// Take ownership of a live controller and bring it up to the state the host
/// has meanwhile asked for — bounds, scale and visibility can all have moved
/// while creation was in flight.
fn adopt(self: *ViewerFeedbackWeb, c: *iface.ICoreWebView2Controller) void {
    self.controller = c;

    // DPI before bounds, for the pane's own reason: bounds are physical pixels
    // and the page's numbers are CSS pixels, so the rasterization scale is what
    // ties the two together. With it set, one CSS pixel is one DIP and
    // `viewer_feedback_page.Vars` can carry the design system unscaled.
    if (c.queryV3()) |c3| {
        defer c3.release();
        _ = c3.setShouldDetectMonitorScaleChanges(false);
        _ = c3.setRasterizationScale(self.scale);
    }

    _ = c.setBounds(self.bounds);
    // Deliberately NOT visible yet: `NavigateToString` paints the page's
    // background only once it has parsed the document, and a controller shown
    // before that composites the runtime's own white — a flash inside a dark
    // capsule on every open. `ready` is what turns it on.
    _ = c.setVisible(false);

    self.subscribeMessages();
    self.subscribeAccelerators();

    const web = c.coreWebView() orelse {
        log.warn("composer controller has no web view; the composer will not accept text", .{});
        return;
    };
    defer web.release();

    const html = page.documentAlloc(self.alloc) catch return;
    defer self.alloc.free(html);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, html) catch return;
    defer self.alloc.free(wide);
    if (!web.navigateToString(wide.ptr)) {
        log.warn("composer NavigateToString was refused; the composer will not accept text", .{});
        return;
    }
    log.info("viewer composer page loading bytes={d}", .{html.len});
}

fn subscribeMessages(self: *ViewerFeedbackWeb) void {
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const handler = WebMessageReceivedHandler.create(self.alloc, self.token) catch return;
    // The borrowed token reference, taken BEFORE the object can reach a runtime
    // that might release it.
    self.token.refs += 1;
    if (!web.addWebMessageReceived(@ptrCast(handler))) {
        log.warn("composer add_WebMessageReceived failed; the page cannot talk back", .{});
        handler.release(); // takes the borrowed reference with it
        return;
    }
    self.message_handler = handler;
}

fn subscribeAccelerators(self: *ViewerFeedbackWeb) void {
    const c = self.controller orelse return;
    const handler = AcceleratorKeyPressedHandler.create(self.alloc, self.token) catch return;
    self.token.refs += 1;
    if (!c.addAcceleratorKeyPressed(@ptrCast(handler))) {
        log.warn("composer add_AcceleratorKeyPressed failed; Ctrl+Enter and Esc stay dead", .{});
        handler.release();
        return;
    }
    self.accel_handler = handler;
}

// -------------------------------------------------------------------------
// The page talking up
// -------------------------------------------------------------------------

const WebMessageReceivedHandler = com.CallbackOwning(
    iface.IID_WebMessageReceivedHandler,
    onWebMessageReceived,
    releaseToken,
);

fn onWebMessageReceived(
    t: *Token,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2WebMessageReceivedEventArgs,
) com.HRESULT {
    _ = sender;
    const self = t.owner orelse return com.S_OK;
    const a = args orelse return com.S_OK;

    const raw = a.jsonRaw() orelse return com.S_OK;
    // The runtime allocated it on the COM heap; we free it on ours.
    defer w32.CoTaskMemFree(@ptrCast(raw));

    const utf8 = std.unicode.utf16LeToUtf8Alloc(self.alloc, std.mem.span(raw)) catch return com.S_OK;
    defer self.alloc.free(utf8);

    const parsed = page.parse(self.alloc, utf8) orelse return com.S_OK;
    defer parsed.deinit();
    self.apply(parsed.message);
    return com.S_OK;
}

/// Act on one page message. Split out from the COM callback so the whole
/// protocol is reachable from a unit test with no browser process.
fn apply(self: *ViewerFeedbackWeb, message: page.Message) void {
    switch (message) {
        .ready => {
            self.ready = true;
            log.info("viewer composer ready", .{});
            // The bar pushes the design numbers and the report text back down;
            // doing it from here rather than caching them is what makes a page
            // that reloaded itself come back with the half-written report in
            // it instead of empty.
            self.bar.composerReady();
            if (self.controller) |c| _ = c.setVisible(self.visible);
            if (self.want_focus) {
                self.want_focus = false;
                self.takeFocus();
            }
        },
        .focus => |on| self.focused = on,
        .state => |s| {
            // In flight when the last seed went down, so it describes a
            // document that no longer exists. Its line count and caret are as
            // stale as its text, so the whole snapshot goes.
            if (s.gen != self.seed_gen) return;
            self.lines = s.lines;
            self.caret = s.caret;
            self.bar.composerState(s.text, s.quotes);
        },
        // Deliberately NOT generation-guarded (T936): a picture is not a
        // measurement of a document that may have been replaced, it is a thing
        // the user just did, and dropping it because a seed happened to be in
        // flight would be a paste that silently did nothing.
        .image => |img| self.bar.composerImage(img),
    }
}

// -------------------------------------------------------------------------
// The host talking down
// -------------------------------------------------------------------------

/// Post one already-serialized JSON message to the page. Silently dropped
/// before `ready`: the caller replays everything from `composerReady`.
fn post(self: *ViewerFeedbackWeb, json: []const u8) void {
    if (!self.ready) return;
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();
    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, json) catch return;
    defer self.alloc.free(wide);
    _ = web.postWebMessageAsJson(wide.ptr);
}

/// Push the design-system numbers into the page's custom properties.
pub fn pushVars(self: *ViewerFeedbackWeb, vars: page.Vars) void {
    if (!self.ready) return;
    const json = vars.json(self.alloc) catch return;
    defer self.alloc.free(json);
    self.post(json);
}

/// Replace the page's whole document with `text`, caret at `caret` UTF-16 code
/// units in (null means the end), and `quotes` naming the runs of it that are
/// quoted blocks (T935 — in UTF-16 units too, and the only way the ids reach a
/// page built from a buffer that outlived the last one).
pub fn seed(
    self: *ViewerFeedbackWeb,
    text: []const u8,
    caret: ?u32,
    quotes: []const page.QuoteSpan,
    images: []const page.ImageSpan,
) void {
    if (!self.ready) return;
    self.seed_gen +%= 1;
    // Never zero, which is what a page that has not been seeded reports.
    if (self.seed_gen == 0) self.seed_gen = 1;
    const json = page.seedJson(
        self.alloc,
        text,
        if (caret) |c| @intCast(c) else -1,
        self.seed_gen,
        quotes,
        images,
    ) catch return;
    defer self.alloc.free(json);
    self.post(json);
}

/// Select image chip `n`'s node, whole — what a click on its thumbnail does
/// (T936).
pub fn pick(self: *ViewerFeedbackWeb, n: u32) void {
    const json = page.pickJson(self.alloc, n) catch return;
    defer self.alloc.free(json);
    self.post(json);
}

/// Run one script in the composer's page.
///
/// The only caller is the host floor test, and it is here rather than in the
/// test because a `paste` is the one path in this file that no acceptance
/// script can reach: the suite runs on a background desktop where SendInput is
/// dead and a Chromium window ignores posted key messages, so dispatching a
/// synthetic `ClipboardEvent` from inside the page is the only way to prove the
/// engine's own clipboard path end to end. Fire and forget — nothing here reads
/// a result back, exactly like `ViewerPane.executeScript`.
pub fn executeScript(self: *ViewerFeedbackWeb, js: []const u8) void {
    const c = self.controller orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();
    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, js) catch return;
    defer self.alloc.free(wide);
    _ = web.executeScript(wide.ptr, null);
}

pub fn setBounds(self: *ViewerFeedbackWeb, r: iface.RECT) void {
    self.bounds = r;
    if (self.controller) |c| _ = c.setBounds(r);
}

pub fn setVisible(self: *ViewerFeedbackWeb, visible: bool) void {
    self.visible = visible;
    // Never shown before the page has painted itself once; `ready` applies it.
    if (!self.ready) return;
    if (self.controller) |c| _ = c.setVisible(visible);
}

pub fn setScale(self: *ViewerFeedbackWeb, scale: f32) void {
    if (self.scale == scale) return;
    self.scale = scale;
    const c = self.controller orelse return;
    const c3 = c.queryV3() orelse return;
    defer c3.release();
    _ = c3.setRasterizationScale(scale);
}

/// Put the caret in the editable box. Two steps, and both are needed: the
/// CONTROLLER has to take win32 focus (nothing in the page can do that), and
/// the page then has to focus the box rather than whatever the document's
/// default is.
pub fn takeFocus(self: *ViewerFeedbackWeb) void {
    const c = self.controller orelse {
        self.want_focus = true;
        return;
    };
    if (!self.ready) {
        self.want_focus = true;
        return;
    }
    _ = c.moveFocus(.programmatic);
    self.post(page.focus_json);
}

// -------------------------------------------------------------------------
// Keyboard
// -------------------------------------------------------------------------

/// `WM_APP` message the accelerator handler posts to the BAND's window so the
/// chord runs off the message loop rather than inside the runtime's own
/// `Invoke` — where closing the composer would tear this controller down under
/// its own callback frame.
pub const WM_APP_COMPOSER_CHORD: u32 = w32.WM_APP + 2;

const AcceleratorKeyPressedHandler = com.CallbackOwning(
    iface.IID_AcceleratorKeyPressedHandler,
    onAcceleratorKeyPressed,
    releaseToken,
);

fn onAcceleratorKeyPressed(
    t: *Token,
    sender: ?*iface.ICoreWebView2Controller,
    args_opt: ?*iface.ICoreWebView2AcceleratorKeyPressedEventArgs,
) com.HRESULT {
    _ = sender;
    const self = t.owner orelse return com.S_OK;
    const args = args_opt orelse return com.S_OK;

    // Key-up halves are events too; only presses act.
    switch (args.keyEventKind() orelse return com.S_OK) {
        .key_down, .system_key_down => {},
        else => return com.S_OK,
    }
    const vk_u32 = args.virtualKey() orelse return com.S_OK;
    if (vk_u32 > 0xFFFF) return com.S_OK;
    const vk: u16 = @intCast(vk_u32);
    const status = args.physicalKeyStatus() orelse return com.S_OK;
    const extended = status.IsExtendedKey != 0;

    const mods = ViewerFeedbackBar.keyMods();

    // The composer's OWN chords first — Ctrl+Enter sends, Esc closes — because
    // they are the ones that would otherwise be shadowed by a user keybind on
    // the same keys.
    if (self.bar.claimsComposerKey(vk, mods)) {
        // Claim it BEFORE returning: the browser process is blocked on this
        // very decision, and an unclaimed key is a key Chromium also acts on.
        _ = args.setHandled(true);
        // Posted rather than run here — closing the composer tears THIS
        // controller down, and it must not happen under its own Invoke frame.
        const lparam: isize = @as(u16, @bitCast(mods));
        _ = w32.PostMessageW(self.parent, WM_APP_COMPOSER_CHORD, @as(usize, vk), lparam);
        return com.S_OK;
    }

    // Then everything the PANE claims — its own chords, page zoom, the window
    // chords and the whole keybind table. Before T934 the composer was a native
    // control and got all of that from the app's message loop for free; a
    // Chromium window sees the key first, so it has to be asked for.
    if (self.bar.pane.claimAccel(vk, extended, mods)) {
        _ = args.setHandled(true);
    }
    return com.S_OK;
}

// ---------------------------------------------------------------------
// Tests
//
// The COM half needs a browser and is covered by `test\win32\viewer-feedback.ps1`
// on the box. What is unit-testable here is the protocol's own arithmetic,
// which lives in `viewer_feedback_page.zig` and is tested there. These two
// assert the seams this file adds on top of it.
// ---------------------------------------------------------------------

const testing = std.testing;

test "the chord message is the band's, not a stray WM_APP" {
    // WM_APP + 1 is the band's own relayout post. Two different meanings on one
    // message id is the kind of collision that shows up as a composer that
    // resizes when you press Escape.
    try testing.expect(WM_APP_COMPOSER_CHORD != w32.WM_APP + 1);
}

test "a token whose owner is gone answers every callback harmlessly" {
    var token: Token = .{ .owner = null, .refs = 1, .alloc = testing.allocator };
    try testing.expectEqual(com.S_OK, onControllerCompleted(&token, com.S_OK, null));
    try testing.expectEqual(com.S_OK, onWebMessageReceived(&token, null, null));
    try testing.expectEqual(com.S_OK, onAcceleratorKeyPressed(&token, null, null));
    try testing.expectEqual(@as(u8, 1), token.refs);
}
