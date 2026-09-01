//! The viewer pane's navigation bar (T159, design P3): an owner-painted
//! native child window carrying back / forward / reload / home and a real
//! `EDIT` control for the address field.
//!
//! Native, not web content, by pinned decision: chrome rendered inside the
//! WebView2 would have to be injected into arbitrary third-party pages, would
//! fight their CSS and z-index, and would put the address field inside the
//! very content it navigates. Precedents for the shape of this file are
//! `RenameDialog.zig` (the EDIT handling) and `BannerOverlay.zig` (the
//! icon-button painting); the geometry and the reveal policy live in
//! `viewer_nav_layout.zig` where they assert at every scale without a window.
//!
//! ## Who does what
//!
//! The bar OWNS its controls and their painting. The PANE owns when the bar
//! is visible (the hover poll, the content inset) and what the buttons mean —
//! every click lands back on `ViewerPane` (`goBack`, `goForward`,
//! `reloadFromChrome`, `goHome`, `navigateFromAddress`). The main message
//! loop owns the two keystrokes an EDIT cannot see the house way
//! (Enter/Escape, routed via `owningEdit` exactly like the rename dialog's
//! `handleKey`) and the click-selects-all ordering (see `noteClick`).
const ViewerNavBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
// Test-only (T467): the class-level resize/redraw probe. Imported at file
// scope so its own positive and negative controls are queued into the win32
// test lane along with the class test below.
const class_redraw = @import("class_redraw.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const banner_card = @import("banner_card.zig");
const type_ramp = @import("type_ramp.zig");
const icon_button = @import("icon_button.zig");
const icon_paint = @import("icon_button_paint.zig");
const layout_mod = @import("viewer_nav_layout.zig");
const viewer_nav = @import("viewer_nav.zig");
const viewer_worktree = @import("viewer_worktree.zig");
const viewer_accel = @import("viewer_accel.zig");
const ViewerPane = @import("ViewerPane.zig");
const input = @import("../../input.zig");
const utf16_text = @import("utf16_text.zig");

const log = std.log.scoped(.viewer_nav);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewerNav");
const class_name_utf8 = "GhozttyViewerNav";

/// Select the whole address once a focus-gaining click has fully finished.
/// Posted by the main loop's `WM_LBUTTONUP` intercept, never sent: the EDIT
/// must finish its own click tracking (which places a caret and would wipe
/// the selection) before this arrives — the same ordering lesson Mac's
/// `selectAddressWhenClickCompletes` encodes.
pub const WM_APP_SELECT_ALL: u32 = w32.WM_APP + 1;

/// Open the "…" overflow menu (T1159). POSTED from the button's mouse-up
/// rather than tracked inside it: `TrackPopupMenuEx` runs its own modal loop,
/// and starting one from inside a click handler that still owns the bar's
/// press state leaves that state frozen under the menu for as long as it is
/// up. The same reason `ViewerPane` posts its own menu openers.
pub const WM_APP_OVERFLOW_MENU: u32 = w32.WM_APP + 2;

const edit_id: usize = 1;

/// The feedback tooltip's tool id, in this bar's own tool space.
const tip_id: usize = 2;

/// UTF-16 units the tooltip text may hold. "Send feedback to " plus a full
/// path, with room to spare.
const tip_text_cap: usize = 320;

hwnd: w32.HWND,
edit: w32.HWND,
pane: *ViewerPane,
alloc: Allocator,

/// History state, pushed by the pane from `HistoryChanged`. A button with
/// nowhere to go paints dim and answers no click.
can_back: bool = false,
can_forward: bool = false,

/// Whether the leading contents toggle is shown (T160): true only while the
/// pane's TOC is in its compact overlay layout, pushed by the pane.
show_contents: bool = false,

/// The worktree the trailing feedback button files into (T633), pushed by the
/// pane whenever its provenance resolves. Empty ⇒ the pane's content belongs
/// to no working tree and the button is ABSENT — not disabled: with nowhere to
/// file a report the button would be a lie (Mac gates it the same way).
worktree: [std.fs.max_path_bytes]u8 = undefined,
worktree_len: usize = 0,

/// The feedback button's tooltip, and the control that shows it. Created on
/// first use and kept for the bar's life; `tip_text` is the buffer comctl32
/// reads through, so it must outlive every message the control sends itself.
tip: ?w32.HWND = null,
tip_text: [tip_text_cap:0]u16 = undefined,
tip_added: bool = false,

hover: ?layout_mod.Button = null,
pressed: ?layout_mod.Button = null,
tracking: bool = false,

/// Set by the main loop's `WM_LBUTTONDOWN` intercept when the click landed
/// on an UNFOCUSED address field; consumed on the matching `WM_LBUTTONUP`.
/// A click into an already-focused field just places the caret (the browser
/// omnibox rule, both halves).
select_on_up: bool = false,

/// The scale the font and layout were last built for; rebuilt when the
/// pane's monitor changes.
scale: f32 = 0,
font: ?*anyopaque = null, // HFONT (CreateFontW's own return shape)
edit_brush: ?w32.HBRUSH = null,

// Theme, derived from the pane's background in `applyTheme`.
bar_rgb: color_math.Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
field_rgb: color_math.Rgb = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A },
text_ref: u32 = 0x00FFFFFF,
secondary_ref: u32 = 0x00AAAAAA,
dark: bool = true,

var class_registered: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (T467): the bar's whole layout is
        // `Layout.init(scale, width, shown)` - the buttons are anchored to the
        // right edge and the address field stretches between them - so a width
        // change makes every pixel stale, not just the strip the resize
        // uncovers. `place()` resizes with `MoveWindow(.., TRUE)`, which paints
        // the update region but does not widen it; the class style is what
        // makes that region the whole client.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // every pixel painted in WM_PAINT
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("viewer nav class registration failed", .{});
        return;
    }
    class_registered = true;
}

/// Create the bar as a HIDDEN child of the pane's host window. Null when any
/// window cannot be created — the pane then simply has no chrome, which
/// degrades to the pre-T159 world rather than to a crash.
pub fn create(
    alloc: Allocator,
    pane: *ViewerPane,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
) ?*ViewerNavBar {
    registerClass(hinstance);
    if (!class_registered) return null;

    const self = alloc.create(ViewerNavBar) catch return null;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD, // not visible until the hover strip reveals it
        0,
        0,
        0,
        0,
        parent,
        null,
        hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        return null;
    };

    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        0,
        0,
        0,
        0,
        hwnd,
        @ptrFromInt(edit_id),
        hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return null;
    };

    // The placeholder a blank browser pane shows ("Enter URL", Mac parity).
    // wparam TRUE keeps it visible while the empty field is focused, which is
    // exactly the blank pane's opening state.
    _ = w32.SendMessageW(
        edit,
        w32.EM_SETCUEBANNER,
        1,
        @bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Enter URL"))),
    );

    self.* = .{
        .hwnd = hwnd,
        .edit = edit,
        .pane = pane,
        .alloc = alloc,
    };
    self.tip_text[0] = 0;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.applyTheme();
    return self;
}

pub fn destroy(self: *ViewerNavBar) void {
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // (WM_KILLFOCUS, WM_COMMAND) synchronously, and they must not find a
    // half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    // The tooltip is a POPUP owned by the bar, not a child of it, so
    // DestroyWindow(self.hwnd) does not take it down — and it subclassed the
    // bar, so it has to go first.
    if (self.tip) |t| {
        _ = w32.DestroyWindow(t);
        self.tip = null;
    }
    _ = w32.DestroyWindow(self.hwnd); // destroys the EDIT with it
    if (self.font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.edit_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.alloc.destroy(self);
}

fn fromHwnd(hwnd: w32.HWND) ?*ViewerNavBar {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The bar whose ADDRESS FIELD is `hwnd`, if any. The main message loop's
/// routing hook: an EDIT's parent of our class carries the bar in its
/// userdata, so no window list has to be walked (there is one nav bar per
/// viewer pane, not one per app).
pub fn owningEdit(hwnd: w32.HWND) ?*ViewerNavBar {
    const parent = w32.GetParent(hwnd) orelse return null;
    var name: [24:0]u16 = undefined;
    const n = w32.GetClassNameW(parent, &name, name.len);
    if (n <= 0) return null;
    const expect = std.unicode.utf8ToUtf16LeStringLiteral(class_name_utf8);
    if (!std.mem.eql(u16, name[0..@intCast(n)], expect)) return null;
    const self = fromHwnd(parent) orelse return null;
    if (self.edit != hwnd) return null;
    return self;
}

// -------------------------------------------------------------------------
// Theme & layout
// -------------------------------------------------------------------------

/// Re-derive every color from the pane's background. Called at creation and
/// whenever the pane's color scheme changes — the same one-source rule the
/// banner card follows (its fill IS this fill).
pub fn applyTheme(self: *ViewerNavBar) void {
    const bg = self.pane.bg;
    self.dark = !color_math.isLight(bg);
    self.bar_rgb = banner_card.fillColor(bg);
    const text = chrome_theme.textOn(self.bar_rgb);
    const secondary = chrome_theme.textSecondaryOn(self.bar_rgb);
    self.text_ref = w32.RGB(text.r, text.g, text.b);
    self.secondary_ref = w32.RGB(secondary.r, secondary.g, secondary.b);
    // The field sits a step off the band — darker in dark mode, lighter in
    // light — so it reads as a well, not as paint missing from the band.
    const d: i32 = if (self.dark) -14 else 14;
    self.field_rgb = .{
        .r = icon_button.shadeChannel(self.bar_rgb.r, d),
        .g = icon_button.shadeChannel(self.bar_rgb.g, d),
        .b = icon_button.shadeChannel(self.bar_rgb.b, d),
    };
    if (self.edit_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.edit_brush = w32.CreateSolidBrush(w32.RGB(
        self.field_rgb.r,
        self.field_rgb.g,
        self.field_rgb.b,
    ));
    _ = w32.SetWindowTheme(
        self.edit,
        if (self.dark)
            std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Explorer"),
        null,
    );
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Which conditional buttons this bar is currently showing — the one place
/// the two flags become the layout's input, so the paint, the hit test and the
/// placement cannot disagree about the strip they are describing.
pub fn shown(self: *const ViewerNavBar) layout_mod.Shown {
    return .{ .contents = self.show_contents, .feedback = self.worktree_len > 0 };
}

/// Position the bar across the top of the pane and its EDIT inside it.
/// Idempotent and cheap; the pane calls it from every bounds sync while the
/// bar is visible.
pub fn place(self: *ViewerNavBar, width: i32, scale: f32) void {
    const l = layout_mod.Layout.init(scale, width, self.shown());
    _ = w32.MoveWindow(self.hwnd, 0, 0, width, l.bar_h, 1);
    const field_w = @max(l.address.right - l.address.left, 0);
    _ = w32.MoveWindow(
        self.edit,
        l.address.left,
        l.address.top,
        field_w,
        l.address.bottom - l.address.top,
        1,
    );
    // In the minimum band the field is not painted at all (T1159), and an EDIT
    // moved to zero width is still a focusable control that draws a caret at
    // the band's left edge. Hidden, it is out of the tab order and off the
    // screen, which is what "absent" has to mean for it to read as designed.
    _ = w32.ShowWindow(self.edit, if (field_w > 0) w32.SW_SHOWNA else w32.SW_HIDE);
    if (self.scale != scale) {
        self.scale = scale;
        if (self.font) |f| _ = w32.DeleteObject(@ptrCast(f));
        const ramp = type_ramp.body(scale);
        self.font = w32.CreateFontW(
            -ramp.height,
            0,
            0,
            0,
            ramp.weight,
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
        if (self.font) |f| _ = w32.SendMessageW(self.edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    self.syncTip(l);
}

pub fn setVisible(self: *ViewerNavBar, visible: bool) void {
    _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNA else w32.SW_HIDE);
}

// -------------------------------------------------------------------------
// State pushed by the pane
// -------------------------------------------------------------------------

/// New back/forward availability (from `HistoryChanged`).
pub fn setHistory(self: *ViewerNavBar, back: bool, forward: bool) void {
    if (self.can_back == back and self.can_forward == forward) return;
    self.can_back = back;
    self.can_forward = forward;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Show or drop the leading contents toggle (T160). The pane follows with a
/// bounds sync, whose `place` re-lays the strip around the change.
pub fn setContentsButton(self: *ViewerNavBar, show: bool) void {
    if (self.show_contents == show) return;
    self.show_contents = show;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Point the trailing feedback button at `root`, or take it away (null / a
/// path too long to hold). The pane calls this whenever provenance resolves;
/// the bar re-lays itself on the next bounds sync, which the pane drives.
///
/// Returns whether the button's PRESENCE changed, so the pane only pays for a
/// re-layout when the strip's shape actually moved — a re-resolution to the
/// same worktree (the common case on a back/forward walk) costs nothing.
pub fn setWorktree(self: *ViewerNavBar, root: ?[]const u8) bool {
    const had = self.worktree_len > 0;
    const next: []const u8 = if (root) |r|
        (if (r.len <= self.worktree.len) r else "")
    else
        "";
    if (next.len == self.worktree_len and
        std.mem.eql(u8, self.worktree[0..self.worktree_len], next))
    {
        return false;
    }
    @memcpy(self.worktree[0..next.len], next);
    self.worktree_len = next.len;
    // The tooltip is re-synced HERE, not only from `place`: a pane that moves
    // between two files in two different worktrees keeps the button and only
    // changes where it files, so nothing would drive a bounds sync.
    self.syncTip(self.currentLayout());
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    return had != (next.len > 0);
}

// -------------------------------------------------------------------------
// The feedback button's tooltip
// -------------------------------------------------------------------------

/// A rect tool in SUBCLASS mode, not the track mode the tab strip uses
/// (`Window.tabTipEnsure`): the strip already tracks its own hover to paint
/// tabs, so it has the hover state to drive a tip by hand, while this is one
/// small rect whose whole behavior — the delay, the placement, the dismissal —
/// is exactly what comctl32 does for free. Fewer moving parts, and the timing
/// is the system's rather than ours.
fn tipEnsure(self: *ViewerNavBar) ?w32.HWND {
    if (self.tip) |h| return h;

    var icc = w32.INITCOMMONCONTROLSEX{
        .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
        .dwICC = w32.ICC_TAB_CLASSES,
    };
    _ = w32.InitCommonControlsEx(&icc);

    const tip = w32.CreateWindowExW(
        w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        w32.TOOLTIPS_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.TTS_ALWAYSTIP | w32.TTS_NOPREFIX,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        self.hwnd,
        null,
        null,
        null,
    ) orelse return null;

    // The bar's own theme decides the tip's, the way the dialogs decide theirs
    // — the bar is already dark or light for this pane's background.
    if (self.dark) {
        _ = w32.SetWindowTheme(
            tip,
            std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
            null,
        );
    }
    self.tip = tip;
    return tip;
}

fn tipToolInfo(self: *ViewerNavBar, rect: w32.RECT) w32.TOOLINFOW {
    return .{
        .cbSize = @sizeOf(w32.TOOLINFOW),
        .uFlags = w32.TTF_SUBCLASS,
        .hwnd = self.hwnd,
        .uId = tip_id,
        .rect = rect,
        .hinst = null,
        .lpszText = @ptrCast(&self.tip_text),
        .lParam = 0,
        .lpReserved = null,
    };
}

/// Bring the tooltip in line with the button's presence, rect and destination.
/// Idempotent, and safe to call before the tip exists.
fn syncTip(self: *ViewerNavBar, l: layout_mod.Layout) void {
    const box = l.button(.feedback);
    if (self.worktree_len == 0 or box.width() <= 0) {
        if (self.tip_added) {
            var ti = self.tipToolInfo(.{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
            if (self.tip) |t| _ = w32.SendMessageW(t, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&ti)));
            self.tip_added = false;
        }
        return;
    }

    var text_buf: [tip_text_cap]u8 = undefined;
    const text = viewer_worktree.tooltipText(&text_buf, self.worktree[0..self.worktree_len]);
    const n = std.unicode.utf8ToUtf16Le(self.tip_text[0 .. self.tip_text.len - 1], text) catch 0;
    self.tip_text[n] = 0;

    const tip = self.tipEnsure() orelse return;
    // The HIT box, not the paint: the tip should follow the same forgiving
    // target a click does (design system — a hit box may exceed its paint).
    const m = icon_button.Metrics.init(self.scale);
    const hit = icon_button.hitBox(m, box);
    var ti = self.tipToolInfo(.{
        .left = hit.left,
        .top = hit.top,
        .right = hit.right,
        .bottom = hit.bottom,
    });
    if (!self.tip_added) {
        if (w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti))) == 0) return;
        self.tip_added = true;
        return;
    }
    _ = w32.SendMessageW(tip, w32.TTM_NEWTOOLRECTW, 0, @bitCast(@intFromPtr(&ti)));
    _ = w32.SendMessageW(tip, w32.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
}

/// Show `text` in the address field — unless the user is EDITING it, whose
/// keystrokes must never be stomped by a page redirect arriving mid-thought.
pub fn setAddress(self: *ViewerNavBar, text: []const u8) void {
    if (w32.GetFocus() == @as(?w32.HWND, self.edit)) return;
    self.forceAddress(text);
}

/// `setAddress` without the focus guard: the Escape path WANTS to overwrite
/// the abandoned edit while the field still holds focus.
pub fn forceAddress(self: *ViewerNavBar, text: []const u8) void {
    var buf: [address_cap_utf16]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch 0;
    buf[n] = 0;
    _ = w32.SetWindowTextW(self.edit, buf[0..n :0]);
}

/// UTF-16 buffer bound for the field's text: the address module's own cap
/// plus the terminator (UTF-16 units never outnumber UTF-8 bytes).
const address_cap_utf16 = viewer_nav.max_address + 1;

/// Put the caret in the address field with the whole address selected — the
/// keyboard entry point (the blank browser pane's palette command, and later
/// the ctrl+l / ctrl+d chords).
pub fn focusAddress(self: *ViewerNavBar) void {
    _ = w32.SetFocus(self.edit);
    _ = w32.SendMessageW(self.edit, w32.EM_SETSEL, 0, -1);
}

/// The field's current text, UTF-8, into `buf`.
pub fn addressText(self: *ViewerNavBar, buf: []u8) []const u8 {
    var wide: [address_cap_utf16]u16 = undefined;
    const n = w32.GetWindowTextW(self.edit, &wide, wide.len);
    if (n <= 0) return "";
    // The in-repo caller sizes `buf` at `address_cap_utf16 * 3`, which cannot
    // truncate — but the bound belongs here, where every caller gets it (T990).
    const len = utf16_text.toUtf8Truncating(buf, wide[0..@intCast(n)]);
    return buf[0..len];
}

// -------------------------------------------------------------------------
// Main-loop hooks (the EDIT's keys and clicks)
// -------------------------------------------------------------------------

/// Enter/Escape while the address field holds focus, routed here by the main
/// message loop (an EDIT control never delivers these itself — the same
/// arrangement every popup edit in App.run uses). Returns true when consumed.
pub fn handleEditKey(self: *ViewerNavBar, vk: u16) bool {
    switch (vk) {
        w32.VK_RETURN => {
            var buf: [address_cap_utf16 * 3]u8 = undefined;
            const text = self.addressText(&buf);
            self.pane.navigateFromAddress(text);
            return true;
        },
        w32.VK_ESCAPE => {
            self.pane.cancelAddressEdit();
            return true;
        },
        else => return false,
    }
}

/// The pane-scoped chords while the address field holds focus (T161): the
/// chords are live anywhere inside the viewer pane — its page OR its bar —
/// so ctrl+r still reloads and ctrl+l/ctrl+d re-select the address from
/// inside the field. Routed by the main message loop like `handleEditKey`
/// (an EDIT never delivers modifier chords itself). Zoom is deliberately NOT
/// here: Mac scopes ctrl+plus/minus/0 to focused CONTENT, and the field is
/// chrome. Returns true when consumed.
pub fn handleEditChord(self: *ViewerNavBar, vk: u16) bool {
    const mods: input.Mods = .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    const chord = viewer_accel.paneChord(vk, mods) orelse return false;
    // Dispatched by the PANE rather than switched on here, so a chord added to
    // the table reaches this control for free — the exhaustive switch this used
    // to be made every new chord a compile error in three files that have
    // nothing to say about it (T1184 added three).
    self.pane.handlePaneChord(chord);
    return true;
}

/// The main loop saw a `WM_LBUTTONDOWN` headed for the address field. If the
/// field is not yet focused, arm select-on-up; the matching `noteClickUp`
/// posts the selection so it lands AFTER the EDIT's own click tracking.
pub fn noteClickDown(self: *ViewerNavBar) void {
    self.select_on_up = w32.GetFocus() != @as(?w32.HWND, self.edit);
}

pub fn noteClickUp(self: *ViewerNavBar) void {
    if (!self.select_on_up) return;
    self.select_on_up = false;
    _ = w32.PostMessageW(self.hwnd, WM_APP_SELECT_ALL, 0, 0);
}

// -------------------------------------------------------------------------
// Painting & input
// -------------------------------------------------------------------------

fn buttonEnabled(self: *const ViewerNavBar, b: layout_mod.Button) bool {
    return switch (b) {
        .contents => true,
        .back => self.can_back,
        .forward => self.can_forward,
        // Never disabled: a feedback button with nowhere to file is ABSENT,
        // which the layout expresses as an empty rect. The overflow control is
        // only ever placed when it has something in it.
        .reload, .home, .feedback, .overflow => true,
    };
}

fn buttonGlyph(b: layout_mod.Button) icon_button.Glyph {
    return switch (b) {
        .contents => .contents,
        .back => .back,
        .forward => .forward,
        .reload => .refresh,
        .home => .home,
        .overflow => .overflow,
        .feedback => .feedback,
    };
}

/// The menu label for a command that did not fit on the strip. Written the way
/// the tooltip would read, not the way the enum is spelled: this is the only
/// place these commands are ever WORDS rather than glyphs.
fn overflowTitle(b: layout_mod.Button) [:0]const u16 {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    return switch (b) {
        .contents => L("Contents"),
        .back => L("Back"),
        .forward => L("Forward"),
        .reload => L("Reload"),
        .home => L("Home"),
        .feedback => L("Send feedback…"),
        // Never in its own menu.
        .overflow => L("More"),
    };
}

/// Show the commands this width could not paint. The menu is the whole reason
/// the strip is allowed to drop a button at all (T1159): before it, a pane
/// narrow enough to shed `home` simply had no way to go home.
fn openOverflowMenu(self: *ViewerNavBar) void {
    const l = self.currentLayout();
    var buf: [layout_mod.button_count]layout_mod.Button = undefined;
    const items = l.overflowItems(&buf);
    if (items.len == 0) return;

    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    for (items) |b| {
        // A command with nowhere to go is GRAYED here rather than omitted: the
        // menu stands in for the strip, and the strip dims those buttons too —
        // an item that came and went with history would make the menu's own
        // length jump around.
        const flags: u32 = w32.MF_STRING |
            (if (self.buttonEnabled(b)) @as(u32, 0) else w32.MF_GRAYED);
        _ = w32.AppendMenuW(menu, flags, @intFromEnum(b) + 1, overflowTitle(b).ptr);
    }

    // Under the control's own left edge, so the menu reads as belonging to the
    // "…" rather than to the cursor.
    const box = l.button(.overflow);
    var pt = w32.POINT{ .x = box.left, .y = l.bar_h };
    _ = w32.ClientToScreen(self.hwnd, &pt);

    // The MSDN pair for a tracked menu whose owner is not foreground (the same
    // one `ViewerPane.openLinkMenu` uses): foreground the top-level window
    // first so an outside click dismisses the menu, and post it a message
    // after so the menu's own loop exits cleanly.
    const top: ?w32.HWND = if (self.pane.pane_view) |pv| pv.parentWindow().hwnd else null;
    if (top) |t| _ = w32.SetForegroundWindow(t);
    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd,
        null,
    );
    if (top) |t| _ = w32.PostMessageW(t, w32.WM_NULL, 0, 0);
    if (cmd <= 0) return; // dismissed without choosing
    const idx: usize = @intCast(cmd - 1);
    if (idx >= layout_mod.button_count) return;
    const chosen: layout_mod.Button = @enumFromInt(idx);
    if (chosen == .overflow) return;
    self.activate(chosen);
}

fn paint(self: *ViewerNavBar, hdc: w32.HDC, width: i32, height: i32) void {
    const bar_ref = w32.RGB(self.bar_rgb.r, self.bar_rgb.g, self.bar_rgb.b);
    if (w32.CreateSolidBrush(bar_ref)) |brush| {
        defer _ = w32.DeleteObject(@ptrCast(brush));
        var r = w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
        _ = w32.FillRect(hdc, &r, brush);
    }

    const l = layout_mod.Layout.init(self.scale, width, self.shown());
    const m = icon_button.Metrics.init(self.scale);
    for (std.enums.values(layout_mod.Button)) |b| {
        const box = l.button(b);
        if (box.width() <= 0) continue; // an absent conditional button
        const enabled = self.buttonEnabled(b);

        const state: icon_button.State = st: {
            if (!enabled) break :st .normal; // a disabled button never lights
            if (self.pressed == b) break :st .pressed;
            if (self.hover == b and self.pressed == null) break :st .hover;
            break :st .normal;
        };
        if (icon_button.paintsFill(state)) {
            const d = icon_button.fillDelta(state, self.dark);
            const fill = w32.RGB(
                icon_button.shadeChannel(self.bar_rgb.r, d),
                icon_button.shadeChannel(self.bar_rgb.g, d),
                icon_button.shadeChannel(self.bar_rgb.b, d),
            );
            const f = icon_button.fillRegion(m, box);
            if (w32.CreateRoundRectRgn(f.left, f.top, f.right, f.bottom, f.ellipse, f.ellipse)) |rgn| {
                defer _ = w32.DeleteObject(rgn);
                if (w32.CreateSolidBrush(fill)) |brush| {
                    defer _ = w32.DeleteObject(@ptrCast(brush));
                    _ = w32.FillRgn(hdc, rgn, @ptrCast(brush));
                }
            }
        }

        // State is never color alone — but disabled MAY be, per the design
        // system's own state table: the dimmed glyph plus the dead hover is
        // the standard Windows treatment.
        const glyph = buttonGlyph(b);
        const color = if (enabled) self.text_ref else self.secondary_ref;
        icon_paint.glyph(hdc, m, icon_button.glyphTarget(m, box, glyph), glyph, color);
    }
}

fn updateHover(self: *ViewerNavBar, x: i32, y: i32) void {
    const l = self.currentLayout();
    const hot = l.hitButton(self.scale, x, y);
    const hot_enabled: ?layout_mod.Button = if (hot) |b|
        (if (self.buttonEnabled(b)) b else null)
    else
        null;
    if (hot_enabled == self.hover) return;
    self.hover = hot_enabled;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

fn currentLayout(self: *ViewerNavBar) layout_mod.Layout {
    var r: w32.RECT = undefined;
    const w = if (w32.GetClientRect(self.hwnd, &r) != 0) r.right - r.left else 0;
    return layout_mod.Layout.init(self.scale, w, self.shown());
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
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
        // The same bar into a caller's DC, so a pixel probe can photograph it
        // synchronously rather than through DWM's asynchronous copy of the
        // composited surface, which tears mid-row (T835/T940).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), r.right - r.left, r.bottom - r.top);
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            self.updateHover(x, y);
            if (!self.tracking) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.tracking = true;
            }
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.tracking = false;
            if (self.hover != null or self.pressed != null) {
                self.hover = null;
                self.pressed = null;
                _ = w32.InvalidateRect(hwnd, null, 1);
            }
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            const l = self.currentLayout();
            if (l.hitButton(self.scale, x, y)) |b| {
                if (self.buttonEnabled(b)) {
                    self.pressed = b;
                    _ = w32.SetCapture(hwnd);
                    _ = w32.InvalidateRect(hwnd, null, 1);
                }
            }
            return 0;
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            _ = w32.ReleaseCapture();
            const was = self.pressed;
            self.pressed = null;
            _ = w32.InvalidateRect(hwnd, null, 1);
            if (was) |b| {
                const l = self.currentLayout();
                if (l.hitButton(self.scale, x, y) == b) self.activate(b);
            }
            return 0;
        },

        WM_APP_SELECT_ALL => {
            _ = w32.SendMessageW(self.edit, w32.EM_SETSEL, 0, -1);
            return 0;
        },

        WM_APP_OVERFLOW_MENU => {
            self.openOverflowMenu();
            return 0;
        },

        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, self.text_ref);
            _ = w32.SetBkColor(hdc, w32.RGB(self.field_rgb.r, self.field_rgb.g, self.field_rgb.b));
            if (self.edit_brush) |b| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_COMMAND => {
            const code: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const id: u16 = @intCast(wparam & 0xFFFF);
            if (id == edit_id and code == w32.EN_SETFOCUS) {
                // Focus arriving by any road holds the bar open; the pane's
                // hover poll reads GetFocus, so nothing to store — but a
                // KEYBOARD arrival (tab, palette command) should select all,
                // and a click arrival is handled by noteClickDown/Up. The
                // click case is distinguishable: the mouse is down over us.
                if (w32.GetKeyState(w32.VK_LBUTTON) >= 0) {
                    _ = w32.SendMessageW(self.edit, w32.EM_SETSEL, 0, -1);
                }
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// A button click, delivered on mouse-up over the same button it went down
/// on. Everything routes to the pane — the bar knows how to paint a back
/// button, not what "back" means.
fn activate(self: *ViewerNavBar, b: layout_mod.Button) void {
    switch (b) {
        .contents => self.pane.toggleTOCPanel(),
        .back => self.pane.goBack(),
        .forward => self.pane.goForward(),
        .reload => self.pane.reloadFromChrome(),
        .home => self.pane.goHome(),
        .feedback => self.pane.toggleFeedback(),
        // Posted, never tracked inline — see WM_APP_OVERFLOW_MENU.
        .overflow => _ = w32.PostMessageW(self.hwnd, WM_APP_OVERFLOW_MENU, 0, 0),
    }
}

// T467: the bar's buttons are anchored to its right edge and the address field
// spans what is left, so a pane width change re-lays out every one of them.
// `place()` resizes with `MoveWindow(.., TRUE)`, which paints the update
// region — the class is what decides that the region is the whole bar and not
// the sliver the widen uncovered.
test "viewer nav class: a resize invalidates the whole bar" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClass(hinst);
    if (!class_registered) return error.SkipZigTest;
    try class_redraw.expectResizeInvalidatesWholeClient(CLASS_NAME);
}
