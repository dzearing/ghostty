//! The viewer pane's feedback composer (T634, the win32 half of Mac's
//! `ViewerFeedbackBar`): an owner-painted native child window that slides in
//! below the nav bar and above the page, carrying a pill that grows with its
//! content and two circular actions inside the pill's trailing edge.
//!
//! Native, not web content, for the same pinned reason the nav bar is: chrome
//! rendered inside WebView2 would have to be injected into arbitrary
//! third-party pages, would fight their CSS and z-index, and would put the
//! composer inside the very content it is reporting on.
//!
//! ## Who does what
//!
//! The BAR owns its window, its painting and its hit testing. The PANE owns
//! everything that has to survive the bar — whether the composer is open, and
//! the text itself. That split is not a preference: Mac is explicit that
//! composer contents survive toggling the toolbar closed and open again, and
//! the natural win32 mistake is to keep the buffer in the child window, where
//! it dies with the window. So the buffer lives in `ViewerPane` and this file
//! only renders and edits it (`pane.feedbackText`, `feedbackInsert`,
//! `feedbackBackspace`).
//!
//! ## Which text control this IS
//!
//! A **RichEdit** (`Msftedit.dll`, class `RichEdit50W`) hosted as a child
//! filling the pill's text rect — D43's recommended answer, taken in T635.
//! T634 shipped this file's chrome over a deliberately minimal editing
//! surface (a plain UTF-8 buffer appended by `WM_CHAR`); everything that made
//! that surface a placeholder — no caret, no selection, no clipboard, no undo,
//! no IME — is the control's job now, and the geometry, the paint, the
//! open/close lifecycle and the pane's reflow all survived the swap exactly as
//! that task promised.
//!
//! RichEdit rather than a plain `EDIT` because the composer's end state has
//! image chips and quoted blocks in it (T641, T636), and an `EDIT` carries
//! neither attachments nor per-run formatting. RichEdit rather than a hand-
//! rolled model because caret, selection, word wrap, undo, drag-drop,
//! clipboard and IME composition are things the OS already gets right in cases
//! we would never think to test — and a feedback composer that eats a
//! Japanese user's text is worse than one that looks slightly off.
//!
//! Two consequences worth knowing:
//!
//! - **The control is the storage; the PANE is still the owner.** RichEdit
//!   holds the text while the composer is open, and every change is mirrored
//!   straight back into `pane.feedbackText()` from `EN_CHANGE`, so the buffer
//!   that has to outlive this window still does. Opening seeds the control
//!   from that buffer.
//! - **RichEdit sends no notifications by default.** Without the
//!   `EM_SETEVENTMASK`/`ENM_CHANGE` in `create`, `EN_CHANGE` never arrives and
//!   the mirror above silently never runs.
//!
//! Geometry lives in `viewer_feedback_layout.zig`, where it asserts at
//! 1.0/1.25/1.5/2.0 without a window.
const ViewerFeedbackBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const banner_card = @import("banner_card.zig");
const type_ramp = @import("type_ramp.zig");
const icon_button = @import("icon_button.zig");
const icon_paint = @import("icon_button_paint.zig");
const layout_mod = @import("viewer_feedback_layout.zig");
const viewer_accel = @import("viewer_accel.zig");
const ViewerPane = @import("ViewerPane.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.viewer_feedback);

const class_name_utf8 = "GhozttyViewerFeedback";
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(class_name_utf8);

/// Child id of the RichEdit, so `WM_COMMAND`'s low word names it.
const edit_id: usize = 1;

/// The placeholder an empty composer shows, Mac's accessibility label turned
/// into the cue an empty field needs (`EM_SETCUEBANNER`'s job, hand-drawn
/// here because the pill is not an EDIT).
const placeholder_w = std.unicode.utf8ToUtf16LeStringLiteral(
    "What's wrong with what you're looking at?",
);

/// The key hints in the footer's trailing slot. Spelled in the Windows
/// chords, which is the whole reason it is not Mac's string.
const hints = "Ctrl+Enter send  ·  Esc close";

hwnd: w32.HWND,
/// The RichEdit filling the pill's text rect. See "Which text control this IS".
edit: w32.HWND,
pane: *ViewerPane,
alloc: Allocator,

hover: ?layout_mod.Button = null,
pressed: ?layout_mod.Button = null,
tracking: bool = false,
focused: bool = false,

/// Wrapped lines the control is currently showing, clamped by the layout's own
/// cap. Cached rather than queried per layout pass: `place` is called from
/// every bounds sync, and asking the control there would mean sizing the
/// control from a number the control itself produces.
lines: u32 = 1,

/// True while `seedControl` is writing the buffer INTO the control, so the
/// `EN_CHANGE` that write raises does not mirror straight back out again.
seeding: bool = false,

/// The RichEdit's own window procedure, kept so the subclass can hand every
/// message it does not add to.
prev_edit_proc: ?*const anyopaque = null,

/// Whether the control answered `EM_SETCUEBANNER`. False everywhere measured
/// so far, which is why `editProc` paints the placeholder instead.
cue_banner: bool = false,

/// The scale the fonts were last built for; rebuilt when the pane's monitor
/// changes.
scale: f32 = 0,
body_font: ?*anyopaque = null, // HFONT
caption_font: ?*anyopaque = null,

// Theme, derived from the pane's background in `applyTheme` — the same
// derivation the nav bar runs, so the two bands are one surface.
bar_rgb: color_math.Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
pill_rgb: color_math.Rgb = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A },
border_ref: u32 = 0x00404040,
text_ref: u32 = 0x00FFFFFF,
secondary_ref: u32 = 0x00AAAAAA,
dark: bool = true,

var class_registered: bool = false;
var richedit_loaded: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
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
        log.warn("viewer feedback class registration failed", .{});
        return;
    }
    class_registered = true;
}

/// Create the composer as a HIDDEN child of the pane's host window. Null when
/// the window cannot be created — the pane then simply has no composer, which
/// degrades to the pre-T634 world (a feedback button that logs its intent)
/// rather than to a crash.
pub fn create(
    alloc: Allocator,
    pane: *ViewerPane,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
) ?*ViewerFeedbackBar {
    registerClass(hinstance);
    if (!class_registered) return null;

    // Msftedit registers its classes from its entry point, so this has to
    // happen before the CreateWindowExW below — without it the control window
    // simply fails to create and the pane loses its composer. Never freed: the
    // classes stay registered for the process's life either way.
    if (!richedit_loaded) {
        richedit_loaded = w32.LoadLibraryW(w32.MSFTEDIT_DLL) != null;
        if (!richedit_loaded) {
            log.warn("Msftedit.dll could not be loaded; viewer has no composer", .{});
            return null;
        }
    }

    const self = alloc.create(ViewerFeedbackBar) catch return null;
    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD, // not visible until the button opens it
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

    // ES_WANTRETURN so a bare Enter is a newline in the report rather than a
    // beep (Ctrl+Enter sends, and that is routed in App.zig); ES_AUTOVSCROLL
    // so a report past the pill's six-line cap scrolls with the caret. No
    // WS_VSCROLL: a scrollbar inside a capsule is not a thing this design has.
    const edit = w32.CreateWindowExW(
        0,
        w32.MSFTEDIT_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_MULTILINE |
            w32.ES_AUTOVSCROLL | w32.ES_WANTRETURN,
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

    // RichEdit sends NOTHING to its parent until asked. Without this the
    // EN_CHANGE mirror never runs and the pane's buffer stays empty while the
    // user watches their text appear on screen.
    _ = w32.SendMessageW(edit, w32.EM_SETEVENTMASK, 0, @bitCast(w32.ENM_CHANGE));

    // The placeholder an empty composer shows — Mac's accessibility label
    // turned into a cue. wparam TRUE keeps it up while the empty field is
    // focused, which is the state the composer opens in.
    //
    // `EM_SETCUEBANNER` is an EDIT message, and RichEdit does not answer it —
    // measured, not assumed: it returns 0 on Msftedit here. So the placeholder
    // is painted by the subclass below, and this call stays only as the
    // preferred path if a future RichEdit grows one. The acceptance script
    // reads the logged answer, which is how the fallback stays honest rather
    // than becoming a fallback nobody notices is always taken.
    const cue = w32.SendMessageW(
        edit,
        w32.EM_SETCUEBANNER,
        1,
        @bitCast(@intFromPtr(placeholder_w.ptr)),
    );
    const prev_proc = w32.SetWindowLongPtrW(edit, w32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
    log.info(
        "viewer feedback composer created cue_banner={} painted_placeholder={}",
        .{ cue != 0, cue == 0 },
    );

    self.* = .{
        .hwnd = hwnd,
        .edit = edit,
        .pane = pane,
        .alloc = alloc,
        .prev_edit_proc = if (prev_proc != 0) @ptrFromInt(@as(usize, @bitCast(prev_proc))) else null,
        .cue_banner = cue != 0,
    };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.applyTheme();
    return self;
}

/// The bar that owns `hwnd` when `hwnd` is its RichEdit — the hook the main
/// message loop routes composer keys through, mirroring
/// `ViewerNavBar.owningEdit`. Identified by the PARENT's class name rather
/// than by a pointer stashed on the control, because a control's
/// `GWLP_USERDATA` belongs to the control.
pub fn owningEdit(hwnd: w32.HWND) ?*ViewerFeedbackBar {
    const parent = w32.GetParent(hwnd) orelse return null;
    var name: [32:0]u16 = undefined;
    const n = w32.GetClassNameW(parent, &name, name.len);
    if (n <= 0) return null;
    if (!std.mem.eql(u16, name[0..@intCast(n)], CLASS_NAME)) return null;
    const self = fromHwnd(parent) orelse return null;
    if (self.edit != hwnd) return null;
    return self;
}

pub fn destroy(self: *ViewerFeedbackBar) void {
    // Un-subclass the control BEFORE the back-pointer goes: `editProc` finds
    // its bar through the parent, so a teardown message arriving in between
    // would reach a proc that can no longer route it.
    if (self.prev_edit_proc) |p| {
        _ = w32.SetWindowLongPtrW(self.edit, w32.GWLP_WNDPROC, @bitCast(@intFromPtr(p)));
    }
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // synchronously, and they must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    if (self.body_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.caption_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    self.alloc.destroy(self);
}

fn fromHwnd(hwnd: w32.HWND) ?*ViewerFeedbackBar {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

// -------------------------------------------------------------------------
// Theme & layout
// -------------------------------------------------------------------------

/// Re-derive every color from the pane's background — the same one-source
/// rule the nav bar and the banner card follow, so the composer's band and
/// the bar above it are one surface rather than two nearly-equal greys.
pub fn applyTheme(self: *ViewerFeedbackBar) void {
    const bg = self.pane.bg;
    self.dark = !color_math.isLight(bg);
    self.bar_rgb = banner_card.fillColor(bg);
    const text = chrome_theme.textOn(self.bar_rgb);
    const secondary = chrome_theme.textSecondaryOn(self.bar_rgb);
    self.text_ref = w32.RGB(text.r, text.g, text.b);
    self.secondary_ref = w32.RGB(secondary.r, secondary.g, secondary.b);
    // The pill sits a step off the band — darker in dark mode, lighter in
    // light — so it reads as a well, exactly as the address field does.
    const d: i32 = if (self.dark) -14 else 14;
    self.pill_rgb = .{
        .r = icon_button.shadeChannel(self.bar_rgb.r, d),
        .g = icon_button.shadeChannel(self.bar_rgb.g, d),
        .b = icon_button.shadeChannel(self.bar_rgb.b, d),
    };
    // A 1 px boundary that carries meaning needs 3:1 (design system §2.3), so
    // the border is shaded AWAY from the pill rather than a hairline of the
    // band's own color.
    const bd: i32 = if (self.dark) 40 else -40;
    self.border_ref = w32.RGB(
        icon_button.shadeChannel(self.pill_rgb.r, bd),
        icon_button.shadeChannel(self.pill_rgb.g, bd),
        icon_button.shadeChannel(self.pill_rgb.b, bd),
    );

    // RichEdit paints its own background and its own text, so the pill's fill
    // and the band's text colour have to be pushed INTO it — they are still
    // derived above, in the one place, rather than picked again here.
    _ = w32.SendMessageW(
        self.edit,
        w32.EM_SETBKGNDCOLOR,
        0, // 0: use the COLORREF given, not the system window colour
        @bitCast(@as(usize, w32.RGB(self.pill_rgb.r, self.pill_rgb.g, self.pill_rgb.b))),
    );
    var cf = std.mem.zeroes(w32.CHARFORMAT2W);
    cf.cbSize = @sizeOf(w32.CHARFORMAT2W);
    cf.dwMask = w32.CFM_COLOR;
    cf.crTextColor = self.text_ref;
    // DEFAULT sets what the NEXT character typed inherits; ALL recolours what
    // is already there. An empty composer needs the first, a re-themed one
    // mid-report needs the second, and there is no single flag that is both.
    _ = w32.SendMessageW(self.edit, w32.EM_SETCHARFORMAT, w32.SCF_DEFAULT, @bitCast(@intFromPtr(&cf)));
    _ = w32.SendMessageW(self.edit, w32.EM_SETCHARFORMAT, w32.SCF_ALL, @bitCast(@intFromPtr(&cf)));

    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// How many lines the composer currently shows: the control's own WRAPPED line
/// count, clamped by the layout's cap. Cached in `self.lines` by `syncLines`,
/// because `place` sizes the control from this and must not ask the control it
/// is about to move.
fn lineCount(self: *const ViewerFeedbackBar) u32 {
    return layout_mod.visibleLines(self.lines);
}

/// Re-read the control's wrapped line count. Returns true when it changed, i.e.
/// when the pill has to grow or shrink and the pane has to re-inset the page.
fn syncLines(self: *ViewerFeedbackBar) bool {
    const n = w32.SendMessageW(self.edit, w32.EM_GETLINECOUNT, 0, 0);
    const lines: u32 = if (n > 0) @intCast(@as(usize, @bitCast(n))) else 1;
    if (layout_mod.visibleLines(lines) == layout_mod.visibleLines(self.lines)) {
        self.lines = lines;
        return false;
    }
    self.lines = lines;
    return true;
}

fn layoutInput(self: *const ViewerFeedbackBar, width: i32, scale: f32) layout_mod.Input {
    return .{
        .scale = scale,
        .width = width,
        .lines = self.lineCount(),
        .line_h = type_ramp.lineBox(type_ramp.body(scale), scale),
        .footer_h = type_ramp.lineBox(type_ramp.caption(scale), scale),
    };
}

/// The band height this composer needs at `width`/`scale`. The pane asks for
/// it BEFORE placing anything (it has to inset the page by nav + composer in
/// one pass), which is why it is derivable without a DC: every input is the
/// type ramp and the DPI scale, never a measured string.
pub fn barHeight(self: *const ViewerFeedbackBar, width: i32, scale: f32) i32 {
    return layout_mod.Layout.init(self.layoutInput(width, scale)).bar_h;
}

/// Position the composer across the pane, directly under the nav bar.
/// Idempotent and cheap; the pane calls it from every bounds sync while the
/// composer is open.
pub fn place(self: *ViewerFeedbackBar, top: i32, width: i32, scale: f32) void {
    const l = layout_mod.Layout.init(self.layoutInput(width, scale));
    _ = w32.MoveWindow(self.hwnd, 0, top, width, l.bar_h, 1);
    if (self.scale != scale) {
        self.scale = scale;
        if (self.body_font) |f| _ = w32.DeleteObject(@ptrCast(f));
        if (self.caption_font) |f| _ = w32.DeleteObject(@ptrCast(f));
        self.body_font = makeFont(type_ramp.body(scale));
        self.caption_font = makeFont(type_ramp.caption(scale));
        if (self.body_font) |f| {
            // 0 for lparam: no redraw request needed, the MoveWindow below
            // repaints the control anyway.
            _ = w32.SendMessageW(self.edit, w32.WM_SETFONT, @intFromPtr(f), 0);
        }
    }
    // The control fills the text rect exactly, which is what makes the pill's
    // 12 DIP lead and the gap to the buttons the control's OWN margins — no
    // second inset to keep in step with the layout module.
    _ = w32.MoveWindow(
        self.edit,
        l.text.left,
        l.text.top,
        @max(l.text.width(), 0),
        @max(l.text.height(), 0),
        1,
    );
}

/// Push the pane's buffer into the control — what opening the composer does,
/// so contents survive a close/reopen.
///
/// Line endings convert on the way in: the pane stores LF, and a RichEdit
/// given a bare LF renders it but reports its own CR back, so normalising in
/// both directions here keeps the buffer canonical.
pub fn seedControl(self: *ViewerFeedbackBar) void {
    const text = self.pane.feedbackText();
    var buf = std.ArrayList(u16).empty;
    defer buf.deinit(self.alloc);
    // Worst case one UTF-16 unit per byte plus a CR per LF; a failed
    // allocation leaves the control empty rather than showing half a report.
    buf.ensureTotalCapacity(self.alloc, text.len * 2 + 1) catch return;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) buf.appendSlice(self.alloc, &.{ '\r', '\n' }) catch return;
        first = false;
        var tmp: [512]u16 = undefined;
        var rest = line;
        while (rest.len > 0) {
            const chunk = @min(rest.len, tmp.len / 2);
            const n = std.unicode.utf8ToUtf16Le(&tmp, rest[0..chunk]) catch break;
            buf.appendSlice(self.alloc, tmp[0..n]) catch return;
            rest = rest[chunk..];
        }
    }
    buf.append(self.alloc, 0) catch return;

    self.seeding = true;
    defer self.seeding = false;
    _ = w32.SetWindowTextW(self.edit, @ptrCast(buf.items.ptr));
    // Caret to the end, so reopening resumes writing rather than typing into
    // the front of what is already there.
    const all: w32.CHARRANGE = .{ .cpMin = -1, .cpMax = -1 };
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&all)));
    _ = w32.SendMessageW(self.edit, w32.EM_SCROLLCARET, 0, 0);
    _ = self.syncLines();
}

/// Mirror the control's text back into the pane's buffer. The pane is what
/// everything else reads (`feedbackText`, the send button's enabled state, the
/// report writer), and it is what outlives this window.
fn readBack(self: *ViewerFeedbackBar) void {
    const n = w32.GetWindowTextLengthW(self.edit);
    if (n <= 0) {
        self.pane.feedbackSetText(self.alloc, "");
        return;
    }
    const len: usize = @intCast(n);
    const wide = self.alloc.alloc(u16, len + 1) catch return;
    defer self.alloc.free(wide);
    const got = w32.GetWindowTextW(self.edit, wide.ptr, @intCast(wide.len));
    if (got <= 0) {
        self.pane.feedbackSetText(self.alloc, "");
        return;
    }
    const utf8 = std.unicode.utf16LeToUtf8Alloc(self.alloc, wide[0..@intCast(got)]) catch return;
    defer self.alloc.free(utf8);

    // RichEdit reports line breaks as bare CR. Canonicalise to LF so the
    // buffer, the report and every test speak one line ending.
    var norm = self.alloc.alloc(u8, utf8.len) catch return;
    defer self.alloc.free(norm);
    var w: usize = 0;
    var i: usize = 0;
    while (i < utf8.len) : (i += 1) {
        const c = utf8[i];
        if (c == '\r') {
            if (i + 1 < utf8.len and utf8[i + 1] == '\n') continue; // CRLF -> the LF
            norm[w] = '\n';
        } else norm[w] = c;
        w += 1;
    }
    self.pane.feedbackSetText(self.alloc, norm[0..w]);
}

fn makeFont(f: type_ramp.Font) ?*anyopaque {
    return w32.CreateFontW(
        -f.height,
        0,
        0,
        0,
        f.weight,
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
}

pub fn setVisible(self: *ViewerFeedbackBar, visible: bool) void {
    // SHOWNA, not SHOW: merely opening the composer must not yank activation
    // away from the page. Focus is given deliberately, by the pane, on the
    // click that opened it.
    _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNA else w32.SW_HIDE);
}

/// Put the caret in the composer. Separate from `setVisible` on purpose — see
/// the comment there.
pub fn takeFocus(self: *ViewerFeedbackBar) void {
    _ = w32.SetFocus(self.edit);
}

/// Whether keyboard focus is inside the composer right now. The pane's hover
/// poll reads this to hold the nav bar open — and "inside" includes the text
/// control, which is where focus actually sits while anyone is typing.
pub fn hasFocus(self: *const ViewerFeedbackBar) bool {
    const f = w32.GetFocus();
    return f == @as(?w32.HWND, self.hwnd) or f == @as(?w32.HWND, self.edit);
}

/// The text changed: the pill may have grown or shrunk, so the pane has to
/// re-inset the page. Repaint either way.
fn textChanged(self: *ViewerFeedbackBar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.pane.syncBounds();
}

fn currentLayout(self: *ViewerFeedbackBar) layout_mod.Layout {
    var r: w32.RECT = undefined;
    const w = if (w32.GetClientRect(self.hwnd, &r) != 0) r.right - r.left else 0;
    return layout_mod.Layout.init(self.layoutInput(w, self.scale));
}

// -------------------------------------------------------------------------
// Painting
// -------------------------------------------------------------------------

fn buttonGlyph(b: layout_mod.Button) icon_button.Glyph {
    return switch (b) {
        .snapshot => .add,
        .send => .send,
    };
}

/// The send button is dead while there is nothing to send (Mac disables it on
/// `model.isEmpty`); the snapshot button never is.
fn buttonEnabled(self: *const ViewerFeedbackBar, b: layout_mod.Button) bool {
    return switch (b) {
        .snapshot => true,
        .send => self.pane.feedbackText().len > 0,
    };
}

fn paint(self: *ViewerFeedbackBar, hdc: w32.HDC, width: i32, height: i32) void {
    const bar_ref = w32.RGB(self.bar_rgb.r, self.bar_rgb.g, self.bar_rgb.b);
    if (w32.CreateSolidBrush(bar_ref)) |brush| {
        defer _ = w32.DeleteObject(@ptrCast(brush));
        var r = w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
        _ = w32.FillRect(hdc, &r, brush);
    }

    const l = layout_mod.Layout.init(self.layoutInput(width, self.scale));
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    self.paintPill(hdc, l);
    // No text here: the RichEdit paints its own, in `l.text`. This window
    // draws the pill AROUND it, which is why the control is created with no
    // border and its background pushed to match `pill_rgb`.
    self.paintButtons(hdc, l);
    self.paintFooter(hdc, l);
}

fn paintPill(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    const fill = w32.CreateSolidBrush(w32.RGB(self.pill_rgb.r, self.pill_rgb.g, self.pill_rgb.b));
    const pen = w32.CreatePen(0, 1, self.border_ref); // PS_SOLID
    if (fill != null and pen != null) {
        const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
        const prev_pen = w32.SelectObject(hdc, pen.?);
        // `RoundRect`'s width/height arguments are the ellipse DIAMETERS, so
        // a radius of half the collapsed height becomes that whole height —
        // which is what makes a one-line pill a true capsule.
        _ = w32.RoundRect(
            hdc,
            l.pill.left,
            l.pill.top,
            l.pill.right,
            l.pill.bottom,
            l.pill_r * 2,
            l.pill_r * 2,
        );
        _ = w32.SelectObject(hdc, prev_pen);
        _ = w32.SelectObject(hdc, prev_brush);
    }
    if (fill) |b| _ = w32.DeleteObject(@ptrCast(b));
    if (pen) |p| _ = w32.DeleteObject(p);
}

fn paintButtons(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    const m = icon_button.Metrics.init(self.scale);
    for (std.enums.values(layout_mod.Button)) |b| {
        const box = l.button(b);
        if (box.width() <= 0) continue;
        const enabled = self.buttonEnabled(b);
        const state: icon_button.State = st: {
            if (!enabled) break :st .normal;
            if (self.pressed == b) break :st .pressed;
            if (self.hover == b and self.pressed == null) break :st .hover;
            break :st .normal;
        };

        // The fill is a CIRCLE rather than the shared rounded rect: these two
        // sit inside a capsule, and a rounded square inside a capsule reads as
        // a control that did not get the memo. Everything else about them —
        // the square they occupy, the shade per state, the glyph centering —
        // is the shared icon-button model, so they stay one set with the
        // toolbar above.
        if (icon_button.paintsFill(state)) {
            const d = icon_button.fillDelta(state, self.dark);
            const fill = w32.CreateSolidBrush(w32.RGB(
                icon_button.shadeChannel(self.pill_rgb.r, d),
                icon_button.shadeChannel(self.pill_rgb.g, d),
                icon_button.shadeChannel(self.pill_rgb.b, d),
            ));
            const pen = w32.CreatePen(5, 1, 0); // PS_NULL — the fill has no ring
            if (fill != null and pen != null) {
                const t = icon_button.targetBox(m, box);
                const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
                const prev_pen = w32.SelectObject(hdc, pen.?);
                _ = w32.Ellipse(hdc, t.left + m.inset, t.top + m.inset, t.right - m.inset, t.bottom - m.inset);
                _ = w32.SelectObject(hdc, prev_pen);
                _ = w32.SelectObject(hdc, prev_brush);
            }
            if (fill) |br| _ = w32.DeleteObject(@ptrCast(br));
            if (pen) |p| _ = w32.DeleteObject(p);
        }

        const glyph = buttonGlyph(b);
        const color = if (enabled) self.text_ref else self.secondary_ref;
        icon_paint.glyph(hdc, m, icon_button.glyphTarget(m, box, glyph), glyph, color);
    }
}

/// Where the report lands, plus the key hints. Feedback going quietly to the
/// wrong repo is the main failure mode, so the destination is on screen the
/// whole time the composer is open (Mac's footer, same reasoning).
fn paintFooter(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (l.footer.isEmpty()) return;
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    _ = w32.IntersectClipRect(hdc, l.footer.left, l.footer.top, l.footer.right, l.footer.bottom);

    const prev = if (self.caption_font) |f| w32.SelectObject(hdc, f) else null;
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };
    _ = w32.SetTextColor(hdc, self.secondary_ref);

    // Hints trail; the destination leads and gives up its tail first, because
    // a truncated repo name is still readable and a truncated chord is not.
    const hint_w = textWidth(hdc, hints);
    drawUtf8(hdc, @max(l.footer.right - hint_w, l.footer.left), l.footer.top, hints);

    if (self.pane.feedbackWorktree()) |root| {
        const saved2 = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, saved2);
        _ = w32.IntersectClipRect(
            hdc,
            l.footer.left,
            l.footer.top,
            @max(l.footer.right - hint_w - 8, l.footer.left),
            l.footer.bottom,
        );
        drawUtf8(hdc, l.footer.left, l.footer.top, root);
    }
}

fn drawUtf8(hdc: w32.HDC, x: i32, y: i32, text: []const u8) void {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
    if (n == 0) return;
    _ = w32.TextOutW(hdc, x, y, &buf, @intCast(n));
}

fn textWidth(hdc: w32.HDC, text: []const u8) i32 {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return 0;
    if (n == 0) return 0;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = w32.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &size);
    return size.cx;
}

// -------------------------------------------------------------------------
// Input
// -------------------------------------------------------------------------

fn updateHover(self: *ViewerFeedbackBar, x: i32, y: i32) void {
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

/// A button click, delivered on mouse-up over the same button it went down
/// on. Both destinations are still stubs by design: the screenshot is T636
/// and the report writer is T637, and a button that logs its intent is what
/// T633 established as the honest placeholder for a wired-but-unbuilt action.
fn activate(self: *ViewerFeedbackBar, b: layout_mod.Button) void {
    switch (b) {
        .snapshot => log.info(
            "viewer feedback pane={s} action=snapshot (screenshots are T636)",
            .{self.pane.paneId()},
        ),
        .send => self.pane.sendFeedback(),
    }
}

/// The composer's own chords: Ctrl+Enter sends, Escape closes.
///
/// Routed from the main message loop (`App.zig`, via `owningEdit`) rather than
/// handled in a window proc, for the same reason the address field's
/// Enter/Escape are: a multi-line edit control consumes both itself and its
/// parent never sees them. Returns true when consumed.
pub fn handleKey(self: *ViewerFeedbackBar, vk: u16) bool {
    const mods: input.Mods = .{
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    if (viewer_accel.composerChord(vk, mods)) |chord| {
        switch (chord) {
            .send => self.pane.sendFeedback(),
            .close => self.pane.setFeedbackOpen(false),
        }
        return true;
    }
    return false;
}

/// The pane-scoped chords (T161: ctrl+r reload, ctrl+d / ctrl+l / alt+d
/// address bar) while the composer holds focus. They belong to the PANE, and
/// the composer is inside the pane — the same rule the address field follows.
/// Ctrl+A/C/V/X/Z are deliberately NOT here: they are the control's.
pub fn handleChord(self: *ViewerFeedbackBar, vk: u16) bool {
    const mods: input.Mods = .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    const chord = viewer_accel.paneChord(vk, mods) orelse return false;
    switch (chord) {
        .reload => self.pane.reloadContent(),
        .focus_address => _ = self.pane.focusAddressBar(),
    }
    return true;
}

/// The RichEdit's subclass, whose whole job is the placeholder.
///
/// Painted here rather than by the band behind it because the control is
/// opaque and on top: there is no "behind" to draw into. Drawn AFTER the
/// control's own `WM_PAINT` has run, so it lands over a background the control
/// has already cleared, and only while the control is empty — where "empty"
/// means the pane's mirrored buffer, so nothing has to parse the control's
/// text on a paint.
fn editProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const self = owningEdit(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const prev = self.prev_edit_proc orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const res = w32.CallWindowProcW(prev, hwnd, msg, wparam, lparam);
    if (msg != w32.WM_PAINT) return res;
    if (self.cue_banner) return res; // the control drew its own
    if (self.pane.feedbackText().len != 0) return res;

    const hdc = w32.GetDC(hwnd) orelse return res;
    defer _ = w32.ReleaseDC(hwnd, hdc);
    // Character 0's own position, so the cue starts exactly where the first
    // typed character will — RichEdit keeps a small inset of its own that a
    // hand-picked origin would only approximate.
    var origin: w32.POINTL = .{ .x = 0, .y = 0 };
    _ = w32.SendMessageW(hwnd, w32.EM_POSFROMCHAR, @intFromPtr(&origin), 0);
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    if (self.body_font) |f| _ = w32.SelectObject(hdc, f);
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, self.secondary_ref);
    _ = w32.TextOutW(hdc, origin.x, origin.y, placeholder_w.ptr, placeholder_w.len);
    return res;
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

        // Focus lands on the text control, not on the band; a click that
        // reaches the band itself hands it straight on so the caret is never
        // somewhere the user cannot type.
        w32.WM_SETFOCUS => {
            self.focused = true;
            _ = w32.SetFocus(self.edit);
            return 0;
        },

        w32.WM_KILLFOCUS => {
            self.focused = false;
            _ = w32.InvalidateRect(hwnd, null, 1);
            return 0;
        },

        w32.WM_COMMAND => {
            const code: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const id: usize = wparam & 0xFFFF;
            if (id == edit_id and code == w32.EN_CHANGE and !self.seeding) {
                const was_empty = self.pane.feedbackText().len == 0;
                self.readBack();
                // The painted placeholder appears and disappears with the
                // text, and the control only repaints what IT changed — so
                // the crossing has to force a full repaint of the control.
                if (was_empty != (self.pane.feedbackText().len == 0)) {
                    _ = w32.InvalidateRect(self.edit, null, 1);
                }
                // Only a line-count change moves the page; anything else is a
                // repaint. Asking the pane to re-inset on every keystroke
                // would resize the WebView2 while someone is typing into it.
                if (self.syncLines()) self.textChanged() else _ = w32.InvalidateRect(hwnd, null, 1);
            }
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
            // A click anywhere in the band puts the caret here — clicking a
            // composer to type in it is not a thing a user should have to aim
            // for.
            _ = w32.SetFocus(hwnd);
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

        w32.WM_KEYDOWN => {
            if (self.handleKey(@intCast(wparam & 0xFFFF))) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
