//! The "What's New in Ghoztty" window (T624) — the win32 counterpart of
//! Mac's `WhatsNewWindowView`.
//!
//! One window per process, reused: a second invocation focuses the one that
//! is open rather than stacking copies (Mac keeps a lazily created `NSWindow`
//! for exactly this). It is a plain top-level `WS_OVERLAPPEDWINDOW` — not an
//! owned modal — because Mac's is a window the user can leave open behind the
//! terminal, and an owned window can never go behind its owner.
//!
//! What it shows: the notes bundled into this exe (`release_notes_bundle`),
//! split by `release_notes.partition` against the version the user was
//! running before this launch (`whats_new_seen`), with a Client tab and an
//! Agent tab. The split, the ordering and the "already installed" divider are
//! Mac's semantics verbatim; the two tabs exist so a session-persistence
//! change and a UI change are never mixed into one list.
//!
//! Layout is the pure `whats_new_layout.zig`, asserted at 1.0/1.25/1.5/2.0
//! per the design system; this file measures text, paints, and routes input.
//! Inline markdown (bold, italic, `code`, links) is the banner's own parser
//! (`banner_markdown.parseSegs`), so the notes render the same way a banner
//! renders the same string — one renderer, no second dialect.
//!
//! Instrumentation: the debug-only `whats-new` IPC action
//! (`ipc_whats_new.zig`) opens this window and reports the model it is
//! showing, which is what `test/win32/whats-new.ps1` drives.

const WhatsNewWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const build_config = @import("../../build_config.zig");
const layout = @import("whats_new_layout.zig");
const panel_theme = @import("panel_theme.zig");
const provenance = @import("provenance.zig");
const release_notes = @import("release_notes.zig");
const notes_render = @import("whats_new_notes.zig");
const bundle = @import("release_notes_bundle.zig");
const system_colors = @import("system_colors.zig");
const seen = @import("whats_new_seen.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyWhatsNew");

/// Mac's window title, word for word (with the same typographic apostrophe).
const TITLE = std.unicode.utf8ToUtf16LeStringLiteral("What\u{2019}s New in Ghoztty");

var class_registered: bool = false;

/// The open window, if any. GUI thread only.
var active: ?*WhatsNewWindow = null;

/// The launch's anchor. Snapshotted once, early, by `snapshotAtLaunch` — see
/// `whats_new_seen.zig` for why it cannot be read lazily.
var tracker: seen.Tracker = .{};
/// Owns `tracker.previous_seen`'s bytes for the life of the process.
var previous_seen_buf: [64]u8 = undefined;

/// The version everything here compares against. Resolved once at launch so
/// the anchor, the split and the store can never disagree about what "the
/// running build" is.
var current_version: []const u8 = "";
var current_version_buf: [64]u8 = undefined;

/// Debug-only override for the running version (see `currentVersion`).
const version_override_env = "GHOZTTY_WHATS_NEW_VERSION";

// ---------------------------------------------------------------------
// Launch-time tracking
// ---------------------------------------------------------------------

/// Read the stored last-seen version, hold it as this launch's anchor, and
/// advance the store to this build. Call ONCE, early in startup, before
/// anything can show notes. A second call is a no-op.
pub fn snapshotAtLaunch(alloc: Allocator) void {
    resolveCurrentVersion(alloc);
    const path = storePath(alloc) orelse {
        // No `%LOCALAPPDATA%`: no anchor, so everything bundled reads as new.
        _ = tracker.snapshot(null, currentVersion());
        return;
    };
    defer alloc.free(path);

    var buf: [256]u8 = undefined;
    const stored: ?[]const u8 = blk: {
        const f = std.fs.openFileAbsolute(path, .{}) catch break :blk null;
        defer f.close();
        const n = f.readAll(&buf) catch break :blk null;
        const parsed = seen.parseStored(buf[0..n]) orelse break :blk null;
        // Copy into the process-lifetime buffer: `buf` dies with this frame.
        if (parsed.len > previous_seen_buf.len) break :blk null;
        @memcpy(previous_seen_buf[0..parsed.len], parsed);
        break :blk previous_seen_buf[0..parsed.len];
    };

    if (tracker.snapshot(stored, currentVersion())) |write| {
        writeStore(path, write) catch |err| {
            log.warn("what's new: could not advance the seen-version store err={}", .{err});
        };
    }
}

/// The anchor this launch is splitting on, for the window and the IPC seam.
pub fn previousSeen() ?[]const u8 {
    return tracker.previous_seen;
}

/// The version this build counts as "running": ordinarily its own
/// (`provenance.version`), and in a DEBUG build whatever
/// `GHOZTTY_WHATS_NEW_VERSION` says.
///
/// The override is not a convenience. The notes are keyed by the version line
/// a RELEASE carries, while a dev build's version comes from the branch's own
/// git description and sits well below it — so on a dev build every bundled
/// note is "newer than the running build" and the cap correctly drops all of
/// them. That leaves the one build a developer actually runs showing an empty
/// window, and leaves the cap itself untestable from outside, since a harness
/// can seed the anchor but cannot change what version the exe is. Gated on
/// `build_config.is_debug`, so a shipped build reads only its own stamp.
pub fn currentVersion() []const u8 {
    if (current_version.len > 0) return current_version;
    return provenance.version;
}

fn resolveCurrentVersion(alloc: Allocator) void {
    current_version = provenance.version;
    if (!build_config.is_debug) return;
    const override = std.process.getEnvVarOwned(alloc, version_override_env) catch return;
    defer alloc.free(override);
    const trimmed = std.mem.trim(u8, override, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > current_version_buf.len) return;
    @memcpy(current_version_buf[0..trimmed.len], trimmed);
    current_version = current_version_buf[0..trimmed.len];
    log.info("what's new: version overridden to {s} by " ++ version_override_env, .{current_version});
}

/// `%LOCALAPPDATA%\ghoztty\whats-new-seen[-debug]`. Caller frees.
fn storePath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{
        dir,
        "ghoztty",
        seen.fileName(build_config.is_debug),
    }) catch null;
}

fn writeStore(path: []const u8, version: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(version);
}

// ---------------------------------------------------------------------
// State
// ---------------------------------------------------------------------

const Tab = layout.Tab;
const tab_count = Tab.count;

/// One scope's decoded notes and the split it is showing.
///
/// Public since T625: the agent-restart confirmation shows the AGENT scope's
/// fresh half as an accessory, and it must split on the same anchor this
/// window does. A second `Store.parse` + `partition` pair in `App.zig` would
/// be the same three lines today and a different answer the first time the
/// anchor rule changes.
pub const Model = struct {
    store: release_notes.Store,
    split: release_notes.Partitioned,

    pub fn init(gpa: Allocator, entries: []const release_notes.Entry) !Model {
        var store = try release_notes.Store.parse(gpa, entries);
        errdefer store.deinit();
        const split = try store.partition(gpa, previousSeen(), currentVersion());
        return .{ .store = store, .split = split };
    }

    pub fn deinit(self: *Model, gpa: Allocator) void {
        self.split.deinit(gpa);
        self.store.deinit();
    }
};

app: *App,
hwnd: w32.HWND,
scale: f32,
selected: Tab = .client,
/// Scroll offset per tab, so switching back returns you where you were.
scroll: [tab_count]i32 = .{ 0, 0 },
content_h: [tab_count]i32 = .{ 0, 0 },
models: [tab_count]Model,
/// The shared release-notes renderer (T625) — the SAME one the agent-restart
/// dialog's accessory paints with, at this window's spacious density.
notes: notes_render.Renderer,
hover_link: ?[*]const u8 = null,
/// Grab offset while dragging the scroll thumb; -1 when not dragging.
thumb_drag_dy: i32 = -1,

// ---------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------

/// Open the window, or focus the one already open (Mac's `showWhatsNew`).
pub fn open(window: *Window) void {
    openFor(window.app, window.hwnd, window.scale);
}

/// The same, from a caller that has an app but no window (the IPC seam).
pub fn openFor(app: *App, owner: ?w32.HWND, scale: f32) void {
    if (active) |existing| {
        _ = w32.ShowWindow(existing.hwnd, w32.SW_SHOW);
        _ = w32.SetForegroundWindow(existing.hwnd);
        return;
    }
    registerClass(app) orelse return;

    const alloc = app.core_app.alloc;
    const self = alloc.create(WhatsNewWindow) catch |err| {
        log.warn("what's new: alloc failed err={}", .{err});
        return;
    };
    errdefer alloc.destroy(self);

    var client_model = Model.init(alloc, bundle.client) catch |err| {
        log.warn("what's new: client notes failed err={}", .{err});
        alloc.destroy(self);
        return;
    };
    const agent_model = Model.init(alloc, bundle.agent) catch |err| {
        log.warn("what's new: agent notes failed err={}", .{err});
        client_model.deinit(alloc);
        alloc.destroy(self);
        return;
    };

    self.* = .{
        .app = app,
        .hwnd = undefined,
        .scale = scale,
        .models = .{ client_model, agent_model },
        .notes = .init(alloc, scale, .spacious, system_colors.panelFor(app)),
    };

    const style: u32 = w32.WS_OVERLAPPEDWINDOW;
    const d = layout.defaultSize(scale);
    var outer: w32.RECT = .{ .left = 0, .top = 0, .right = d.w, .bottom = d.h };
    _ = w32.AdjustWindowRectEx(&outer, style, 0, 0);
    const outer_w = outer.right - outer.left;
    const outer_h = outer.bottom - outer.top;

    var x: i32 = w32.CW_USEDEFAULT;
    var y: i32 = w32.CW_USEDEFAULT;
    if (owner) |o| {
        var orect: w32.RECT = undefined;
        if (w32.GetWindowRect(o, &orect) != 0) {
            x = orect.left + @divTrunc((orect.right - orect.left) - outer_w, 2);
            y = orect.top + @divTrunc((orect.bottom - orect.top) - outer_h, 2);
        }
    }

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        TITLE,
        style,
        x,
        y,
        outer_w,
        outer_h,
        null,
        null,
        app.hinstance,
        null,
    ) orelse {
        self.models[0].deinit(alloc);
        self.models[1].deinit(alloc);
        alloc.destroy(self);
        return;
    };
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    system_colors.applyPanelChrome(hwnd, self.pal());
    active = self;

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    log.info("what's new: opened previous_seen={?s} current={s}", .{
        previousSeen(), currentVersion(),
    });
}

fn close(self: *WhatsNewWindow) void {
    const alloc = self.app.core_app.alloc;
    active = null;
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.notes.deinit();
    self.models[0].deinit(alloc);
    self.models[1].deinit(alloc);
    alloc.destroy(self);
}

/// Close the window if it is open — app shutdown, so nothing outlives the
/// allocator its notes were parsed into.
pub fn closeAll() void {
    if (active) |a| a.close();
}

/// The open window, if any (the IPC seam's read side).
pub fn current() ?*WhatsNewWindow {
    return active;
}

pub fn selectedTab(self: *const WhatsNewWindow) Tab {
    return self.selected;
}

/// The split one tab is showing, for the IPC seam.
pub fn splitFor(self: *const WhatsNewWindow, tab: Tab) release_notes.Partitioned {
    return self.models[@intFromEnum(tab)].split;
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // Every pixel is derived from the current client size — the tab rule
        // spans the width and the notes wrap to it — so a resize has to
        // repaint the whole client, not just the newly exposed strip.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = app.hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("what's new: class registration failed", .{});
        return null;
    }
    class_registered = true;
}

// ---------------------------------------------------------------------
// Theme + fonts
// ---------------------------------------------------------------------

const fillRect = notes_render.fillRect;
const cr = notes_render.cr;

fn pal(self: *const WhatsNewWindow) panel_theme.Panel {
    return system_colors.panelFor(self.app);
}

// ---------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------

fn clientRect(self: *const WhatsNewWindow) w32.RECT {
    var rc: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(self.hwnd, &rc);
    return rc;
}

fn labelWidths(self: *WhatsNewWindow, hdc: w32.HDC) [tab_count]i32 {
    var out: [tab_count]i32 = .{ 0, 0 };
    for (0..tab_count) |i| {
        const tab: Tab = @enumFromInt(@as(u8, @intCast(i)));
        out[i] = self.notes.measure(hdc, tab.label(), .{}, .body).cx;
    }
    return out;
}

fn frame(self: *WhatsNewWindow, hdc: w32.HDC) layout.Frame {
    const rc = self.clientRect();
    return layout.frameFor(
        self.scale,
        rc.right - rc.left,
        rc.bottom - rc.top,
        self.labelWidths(hdc),
        self.selected,
    );
}

fn paint(self: *WhatsNewWindow, hdc: w32.HDC) void {
    const p = self.pal();
    const rc = self.clientRect();
    const client: layout.Rect = .{
        .x = 0,
        .y = 0,
        .w = rc.right - rc.left,
        .h = rc.bottom - rc.top,
    };
    self.notes.palette = p;
    fillRect(hdc, client, cr(p.bg));
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    const f = self.frame(hdc);
    const m = layout.metrics(self.scale);

    // Tab run: the selected label in primary text with an accent underline,
    // the other in secondary. The hairline under the run separates it from
    // the notes.
    for (f.tabs, 0..) |r, i| {
        const tab: Tab = @enumFromInt(@as(u8, @intCast(i)));
        const on = tab == self.selected;
        const line_h = self.notes.lineHeight(.body);
        _ = self.notes.drawText(
            hdc,
            r.x + m.tab_pad_x,
            r.y + @divTrunc(r.h - line_h, 2),
            tab.label(),
            .{ .bold = on },
            .body,
            if (on) cr(p.text) else cr(p.secondary),
            true,
        );
    }
    fillRect(hdc, f.rule, cr(p.divider));
    fillRect(hdc, f.underline, cr(p.accent));

    // The notes, clipped to the viewport and offset by the scroll.
    const idx = @intFromEnum(self.selected);
    self.notes.beginPaint();
    const saved = w32.SaveDC(hdc);
    _ = w32.IntersectClipRect(
        hdc,
        f.viewport.x,
        f.viewport.y,
        f.viewport.x + f.viewport.w,
        f.viewport.y + f.viewport.h,
    );
    const total = self.notes.render(
        hdc,
        f.viewport.x + m.margin,
        f.viewport.y - self.scroll[idx],
        f.text_w,
        self.models[idx].split,
        true,
    );
    _ = w32.RestoreDC(hdc, saved);
    self.content_h[idx] = total;

    if (layout.thumb(f.scrollbar, total, self.scroll[idx], m.wheel_step)) |t| {
        fillRect(hdc, t, cr(p.boundary));
    }
}

/// Measure the current tab's content height without painting, so scroll
/// clamping and the thumb have a total before the first paint.
fn measureContent(self: *WhatsNewWindow) void {
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    const f = self.frame(hdc);
    const m = layout.metrics(self.scale);
    const idx = @intFromEnum(self.selected);
    self.content_h[idx] = self.notes.render(
        hdc,
        f.viewport.x + m.margin,
        0,
        f.text_w,
        self.models[idx].split,
        false,
    );
}

// ---------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------

fn viewportHeight(self: *WhatsNewWindow) i32 {
    const rc = self.clientRect();
    const m = layout.metrics(self.scale);
    return @max(0, (rc.bottom - rc.top) - m.tab_h);
}

fn scrollBy(self: *WhatsNewWindow, dy: i32) void {
    const idx = @intFromEnum(self.selected);
    const next = layout.clampScroll(
        self.scroll[idx] + dy,
        self.content_h[idx],
        self.viewportHeight(),
    );
    if (next == self.scroll[idx]) return;
    self.scroll[idx] = next;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn scrollTo(self: *WhatsNewWindow, y: i32) void {
    const idx = @intFromEnum(self.selected);
    self.scroll[idx] = 0;
    self.scrollBy(y);
}

/// Switch tabs. Public so the IPC seam can drive the tab the acceptance
/// harness is asserting about.
pub fn selectTab(self: *WhatsNewWindow, tab: Tab) void {
    if (self.selected == tab) return;
    self.selected = tab;
    self.measureContent();
    const idx = @intFromEnum(tab);
    self.scroll[idx] = layout.clampScroll(
        self.scroll[idx],
        self.content_h[idx],
        self.viewportHeight(),
    );
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn onLeftDown(self: *WhatsNewWindow, x: i32, y: i32) void {
    const hdc = w32.GetDC(self.hwnd) orelse return;
    const f = self.frame(hdc);
    _ = w32.ReleaseDC(self.hwnd, hdc);

    if (layout.hitTab(f, x, y)) |tab| {
        self.selectTab(tab);
        return;
    }

    // A link under the pointer wins over a drag.
    if (self.notes.linkAt(x, y)) |url| {
        self.app.openUrl(url);
        return;
    }

    const idx = @intFromEnum(self.selected);
    const m = layout.metrics(self.scale);
    if (layout.thumb(f.scrollbar, self.content_h[idx], self.scroll[idx], m.wheel_step)) |t| {
        if (t.contains(x, y)) {
            self.thumb_drag_dy = y - t.y;
            _ = w32.SetCapture(self.hwnd);
            return;
        }
        // A click in the gutter above or below the thumb pages toward it.
        if (f.scrollbar.contains(x, y)) {
            self.scrollBy(if (y < t.y) -self.viewportHeight() else self.viewportHeight());
        }
    }
}

fn onMouseMove(self: *WhatsNewWindow, x: i32, y: i32) void {
    if (self.thumb_drag_dy >= 0) {
        const hdc = w32.GetDC(self.hwnd) orelse return;
        const f = self.frame(hdc);
        _ = w32.ReleaseDC(self.hwnd, hdc);
        const idx = @intFromEnum(self.selected);
        const m = layout.metrics(self.scale);
        const t = layout.thumb(f.scrollbar, self.content_h[idx], self.scroll[idx], m.wheel_step) orelse return;
        const travel = @max(1, f.scrollbar.h - t.h);
        const want_y = y - self.thumb_drag_dy - f.scrollbar.y;
        const max_scroll = @max(0, self.content_h[idx] - f.scrollbar.h);
        self.scrollTo(@divTrunc(want_y * max_scroll, travel));
        return;
    }

    // The hand cursor is the only hover affordance here: the notes are prose,
    // not a list of rows, so nothing else lights up.
    const over: ?[*]const u8 = if (self.notes.linkAt(x, y)) |url| url.ptr else null;
    if (over != self.hover_link) {
        self.hover_link = over;
        _ = w32.SetCursor(w32.LoadCursorW(
            null,
            if (over != null) w32.IDC_HAND else w32.IDC_ARROW,
        ));
    }
}

fn onKey(self: *WhatsNewWindow, vk: u16) bool {
    const page: i32 = @max(1, self.viewportHeight() - self.notes.lineHeight(.body));
    const idx = @intFromEnum(self.selected);
    switch (vk) {
        w32.VK_ESCAPE => {
            self.close();
            return true;
        },
        w32.VK_DOWN => self.scrollBy(self.notes.lineHeight(.body)),
        w32.VK_UP => self.scrollBy(-self.notes.lineHeight(.body)),
        w32.VK_NEXT => self.scrollBy(page),
        w32.VK_PRIOR => self.scrollBy(-page),
        w32.VK_HOME => self.scrollTo(0),
        w32.VK_END => self.scrollTo(self.content_h[idx]),
        // Left/right move between tabs, the way a Win11 pivot does.
        w32.VK_LEFT => self.selectTab(.client),
        w32.VK_RIGHT => self.selectTab(.agent),
        w32.VK_TAB => self.selectTab(if (self.selected == .client) .agent else .client),
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *WhatsNewWindow = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_ERASEBKGND => return 1, // WM_PAINT covers the whole client
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            self.paint(hdc);
            _ = w32.EndPaint(hwnd, &ps);
            return 0;
        },
        // The same pixels into a caller's DC, so a probe photographs this
        // window synchronously rather than through DWM's async copy (T835).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paint(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_SIZE => {
            self.measureContent();
            const idx = @intFromEnum(self.selected);
            self.scroll[idx] = layout.clampScroll(
                self.scroll[idx],
                self.content_h[idx],
                self.viewportHeight(),
            );
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_GETMINMAXINFO => {
            const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const min = layout.minSize(self.scale);
            var frame_rc: w32.RECT = .{ .left = 0, .top = 0, .right = min.w, .bottom = min.h };
            _ = w32.AdjustWindowRectEx(&frame_rc, w32.WS_OVERLAPPEDWINDOW, 0, 0);
            mmi.ptMinTrackSize = .{
                .x = frame_rc.right - frame_rc.left,
                .y = frame_rc.bottom - frame_rc.top,
            };
            return 0;
        },
        w32.WM_DPICHANGED => {
            self.scale = @as(f32, @floatFromInt(@as(u16, @intCast(wparam & 0xFFFF)))) / 96.0;
            const suggested: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
            );
            self.notes.setScale(self.scale);
            self.measureContent();
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            const m = layout.metrics(self.scale);
            const notches = @divTrunc(@as(i32, delta), w32.WHEEL_DELTA);
            self.scrollBy(-notches * m.wheel_step);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            self.onLeftDown(loWordSigned(lparam), hiWordSigned(lparam));
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (self.thumb_drag_dy >= 0) {
                self.thumb_drag_dy = -1;
                _ = w32.ReleaseCapture();
            }
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            self.onMouseMove(loWordSigned(lparam), hiWordSigned(lparam));
            return 0;
        },
        w32.WM_KEYDOWN => {
            if (self.onKey(@intCast(wparam & 0xFFFF))) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // A light/dark flip or an accent change reaches top-level windows;
        // the palette is derived per paint, so the repaint IS the re-theme.
        w32.WM_SETTINGCHANGE => {
            system_colors.applyPanelChrome(hwnd, self.pal());
            _ = w32.InvalidateRect(hwnd, null, 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            self.close();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn loWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF))));
}

fn hiWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
}
