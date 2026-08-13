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
const layout_mod = @import("viewer_feedback_layout.zig");
const doc = @import("viewer_feedback_doc.zig");
const feedback_images = @import("viewer_feedback_images.zig");
const utf16_offset = @import("utf16_offset.zig");
const clipboard_image = @import("clipboard_image.zig");
const gdiplus_decode = @import("gdiplus_decode.zig");
const RegionSelector = @import("RegionSelector.zig");
const system_colors = @import("system_colors.zig");
const viewer_accel = @import("viewer_accel.zig");
const ViewerPane = @import("ViewerPane.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.viewer_feedback);

const class_name_utf8 = "GhozttyViewerFeedback";
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(class_name_utf8);

/// Child id of the RichEdit, so `WM_COMMAND`'s low word names it.
const edit_id: usize = 1;

/// `'V'`. There is no `VK_V` — the letter keys ARE their ASCII codes, which is
/// how `viewer_accel.zig` spells them too.
const vk_v: u16 = 0x56;

/// "The wrapped line count moved while I was being laid out; ask the pane to
/// lay me out again." Posted, never sent — see `place`.
const WM_APP_RELAYOUT: u32 = w32.WM_APP + 1;

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

/// Live image chips, i.e. how many tiles the carousel shows (T646). Cached for
/// the same reason `lines` is: `barHeight` is asked on every bounds sync and
/// deriving this means scanning the composer's text.
images: u32 = 0,
/// How far the thumbnail strip is scrolled, in physical pixels.
carousel_scroll: i32 = 0,
/// The tile whose chip the caret is sitting in, drawn with a selection ring —
/// the visible half of "clicking a chip scrolls to its thumbnail".
carousel_selected: ?usize = null,
/// The tile the mouse went down on, so a click acts on mouse-UP over the same
/// one, the way the two circular actions already do.
pressed_thumb: ?usize = null,
/// Decoded thumbnails, keyed by image number AND tile size. The size is part
/// of the key rather than something a DPI change has to remember to clear: a
/// new scale simply misses and decodes, and the stale entries age out with the
/// composer.
thumbs: std.ArrayListUnmanaged(Thumb) = .empty,

/// True while `seedControl` is writing the buffer INTO the control, so the
/// `EN_CHANGE` that write raises does not mirror straight back out again.
seeding: bool = false,

/// Set when Ctrl+V was consumed as an IMAGE paste, so the `WM_CHAR` the
/// keystroke also generates is dropped rather than typed after the chip.
swallow_paste_char: bool = false,

/// The RichEdit's own window procedure, kept so the subclass can hand every
/// message it does not add to.
prev_edit_proc: ?*const anyopaque = null,

/// The screenshot region selector while one is up (T647). Non-null means a
/// capture is in flight, which is what makes `+` and Ctrl+Shift+S idempotent
/// rather than a way to stack full-desktop overlays.
selector: ?*RegionSelector = null,

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
/// The wash behind a quoted block, and the bar down its left edge (T641).
quote_rgb: color_math.Rgb = .{ .r = 0x24, .g = 0x24, .b = 0x28 },
accent_ref: u32 = 0x00D47800,
dark: bool = true,

/// One decoded carousel tile. `dib` is null for a picture GDI+ could not read —
/// cached as a FAILURE on purpose, so an unreadable attachment costs one decode
/// rather than one per repaint.
const Thumb = struct {
    number: u32,
    box: i32,
    dib: ?w32.HANDLE,
    w: i32 = 0,
    h: i32 = 0,
};

var class_registered: bool = false;
var richedit_loaded: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (T467): `paint` fills the client and then
        // lays the pill, the carousel and the send row out from
        // `Layout.init(layoutInput(width, scale))`, so the bar's content is a
        // function of its own bounds. The pane resizes it with
        // `MoveWindow(.., TRUE)` on every bounds sync - that paints whatever is
        // invalid, and without this style the only invalid part is the strip
        // the widen uncovered.
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
    log.info(
        "viewer feedback composer created cue_banner={} painted_placeholder={}",
        .{ cue != 0, cue == 0 },
    );

    self.* = .{
        .hwnd = hwnd,
        .edit = edit,
        .pane = pane,
        .alloc = alloc,
        .cue_banner = cue != 0,
    };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    // Subclassed LAST, and only once the bar is reachable from the parent:
    // `editProc` finds its bar through `owningEdit`, so a message arriving
    // before that back-pointer exists would be answered by `DefWindowProcW`
    // instead of by the control's own procedure.
    const prev_proc = w32.SetWindowLongPtrW(edit, w32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
    self.prev_edit_proc = if (prev_proc != 0)
        @ptrFromInt(@as(usize, @bitCast(prev_proc)))
    else
        null;
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
    // A capture still up has nowhere to deliver to once this is gone, and its
    // overlay covers the whole desktop — so it comes down first, silently.
    if (self.selector) |s| {
        self.selector = null;
        s.cancel();
    }
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
    self.dropThumbs();
    self.alloc.destroy(self);
}

/// The pane's image store was emptied (a report was filed), so the carousel's
/// cache is not just stale but WRONG: it is keyed by chip number and the store
/// restarts that sequence at 1.
/// The count itself is deliberately NOT reset here: `seedControl` runs next and
/// re-derives it from the (now empty) text, and it is that discovery which
/// reports the change and re-insets the page. Zeroing it here would make the
/// discovery a no-op and leave the band still tall enough for a strip that has
/// gone.
pub fn imagesCleared(self: *ViewerFeedbackBar) void {
    self.dropThumbs();
    self.carousel_scroll = 0;
    self.carousel_selected = null;
}

/// Free every cached tile bitmap. GDI objects are a process-wide budget, and a
/// composer that was pasted into a dozen times holds a dozen DIBs.
fn dropThumbs(self: *ViewerFeedbackBar) void {
    for (self.thumbs.items) |t| {
        if (t.dib) |d| _ = w32.DeleteObject(d);
    }
    self.thumbs.deinit(self.alloc);
    self.thumbs = .empty;
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

    // A quoted block reads as a block through THREE things at once, because no
    // one of them survives on its own: a wash behind its text, an accent bar
    // down its left, and a paragraph indent. The wash is a faint pull of the
    // pill toward the accent rather than a saturated panel — it sits under
    // body text that still has to clear 4.5:1, and `text_ref` is derived from
    // the band, not re-derived per run.
    const accent = chrome_theme.accentOn(self.pill_rgb, system_colors.accentCached());
    self.accent_ref = w32.RGB(accent.r, accent.g, accent.b);
    self.quote_rgb = color_math.mix(self.pill_rgb, accent, 0.14);

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
    // ...and the quote washes on top of it, in the theme's new colours. The
    // SCF_ALL above just flattened them.
    self.applyQuoteFormatting();

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

/// Re-count the live image chips. Returns true when the count changed, i.e.
/// when the carousel row appeared, disappeared, or grew — all of which move the
/// page, so the pane has to re-inset.
fn syncImages(self: *ViewerFeedbackBar) bool {
    const n: u32 = @intCast(@min(
        self.pane.feedbackImageCount(self.alloc),
        std.math.maxInt(u32),
    ));
    if (n == self.images) return false;
    self.images = n;
    // A strip that just lost tiles can be scrolled past its own end.
    self.carousel_scroll = self.currentLayout().clampScroll(self.carousel_scroll);
    if (self.carousel_selected) |i| {
        if (i >= n) self.carousel_selected = null;
    }
    self.logCarousel("tiles");
    return true;
}

/// Both cached metrics at once. Kept as one call because every text change can
/// move either — a pasted chip adds a tile AND can wrap a line — and asking for
/// one while forgetting the other is exactly the bug that leaves the page inset
/// by a stale band height.
fn syncMetrics(self: *ViewerFeedbackBar) bool {
    const grew_lines = self.syncLines();
    const grew_images = self.syncImages();
    return grew_lines or grew_images;
}

fn layoutInput(self: *const ViewerFeedbackBar, width: i32, scale: f32) layout_mod.Input {
    return .{
        .scale = scale,
        .width = width,
        .lines = self.lineCount(),
        .line_h = type_ramp.lineBox(type_ramp.body(scale), scale),
        .footer_h = type_ramp.lineBox(type_ramp.caption(scale), scale),
        .images = self.images,
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

    // A narrower pane re-wraps the text, so the line count this layout was
    // built from can be wrong the moment the control is moved — which is how
    // a composer ends up two lines tall around three lines of text after a
    // split divider is dragged. Corrected on the next message rather than
    // in-place: `place` is called FROM the pane's bounds sync, and calling
    // back into it here would re-enter it. The correction converges after one
    // pass, because the text rect's WIDTH does not depend on the line count.
    if (self.syncLines()) _ = w32.PostMessageW(self.hwnd, WM_APP_RELAYOUT, 0, 0);
}

/// Push the pane's buffer into the control — what opening the composer does,
/// so contents survive a close/reopen.
///
/// Line endings convert on the way in: the pane stores LF, and a RichEdit
/// given a bare LF renders it but reports its own CR back, so normalising in
/// both directions here keeps the buffer canonical.
pub fn seedControl(self: *ViewerFeedbackBar) void {
    const text = self.pane.feedbackText();

    // Converted whole, in one pass, rather than line by line: splitting UTF-8
    // at a byte boundary can cut a multi-byte sequence in half, and every such
    // split is a silently dropped tail for anyone not writing in ASCII.
    var crlf = std.ArrayList(u8).empty;
    defer crlf.deinit(self.alloc);
    crlf.ensureTotalCapacity(self.alloc, text.len + 16) catch return;
    for (text) |c| {
        if (c == '\n') crlf.append(self.alloc, '\r') catch return;
        crlf.append(self.alloc, c) catch return;
    }
    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, crlf.items) catch return;
    defer self.alloc.free(wide);

    self.seeding = true;
    defer self.seeding = false;
    _ = w32.SetWindowTextW(self.edit, wide.ptr);
    // Caret to the end, so reopening resumes writing rather than typing into
    // the front of what is already there.
    const all: w32.CHARRANGE = .{ .cpMin = -1, .cpMax = -1 };
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&all)));
    _ = w32.SendMessageW(self.edit, w32.EM_SCROLLCARET, 0, 0);
    // A reopened composer comes back with its quoted blocks looking like
    // quoted blocks: the text survived on the pane, the FORMATTING did not —
    // it lived in a control that was emptied. Derived here, from the same
    // registry the report is derived from, so the two cannot disagree.
    self.applyQuoteFormatting();
    self.ensurePlainAtCaret();
    // Seeding can change the band's height — most visibly after a report is
    // filed, where the text and every chip in it went at once. Posted rather
    // than called: the pane's own `setFeedbackOpen` calls this from inside its
    // bounds sync, and re-entering that sync from here would nest it.
    if (self.syncMetrics()) _ = w32.PostMessageW(self.hwnd, WM_APP_RELAYOUT, 0, 0);
}

/// Mirror the control's text back into the pane's buffer. The pane is what
/// everything else reads (`feedbackText`, the send button's enabled state, the
/// report writer), and it is what outlives this window.
///
/// Read with `EM_GETTEXTEX`/`GT_DEFAULT` rather than `WM_GETTEXT`, and that is
/// load-bearing rather than a style choice (T641): `WM_GETTEXT` translates each
/// paragraph mark into CR+LF, so a document with N line breaks comes back N
/// characters longer than the control believes it is. `GT_DEFAULT` leaves the
/// bare CRs, which map to LF one-for-one — so a line break is one byte here and
/// one character there, and `units`/`bytes` are left with nothing to say about
/// line endings. What they DO convert is the encoding: this buffer is UTF-8 and
/// the control counts UTF-16 code units, which agree only for ASCII (T648).
fn readBack(self: *ViewerFeedbackBar) void {
    const n = w32.GetWindowTextLengthW(self.edit);
    if (n <= 0) {
        self.pane.feedbackSetText(self.alloc, "");
        return;
    }
    // GetWindowTextLengthW can OVER-report (it answers for the CRLF form), so
    // the buffer is generous and the copied count is what is trusted.
    const wide = self.alloc.alloc(u16, @as(usize, @intCast(n)) + 2) catch return;
    defer self.alloc.free(wide);
    var gt: w32.GETTEXTEX = .{
        .cb = @intCast(wide.len * @sizeOf(u16)),
        .flags = 0, // GT_DEFAULT: no CR -> CRLF translation
        .codepage = w32.CP_UNICODE,
        .lpDefaultChar = null,
        .lpUsedDefChar = null,
    };
    const got = w32.SendMessageW(
        self.edit,
        w32.EM_GETTEXTEX,
        @intFromPtr(&gt),
        @bitCast(@intFromPtr(wide.ptr)),
    );
    if (got <= 0) {
        self.pane.feedbackSetText(self.alloc, "");
        return;
    }
    const utf8 = std.unicode.utf16LeToUtf8Alloc(
        self.alloc,
        wide[0..@intCast(@as(usize, @bitCast(got)))],
    ) catch return;
    defer self.alloc.free(utf8);

    // RichEdit reports line breaks as bare CR. Canonicalise to LF so the
    // buffer, the report and every test speak one line ending. A CRLF that
    // slips through anyway (a paste, an older control) still collapses to one
    // LF rather than two breaks.
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

// -------------------------------------------------------------------------
// Quotes (T641)
// -------------------------------------------------------------------------

/// The left indent of a quoted block, in TWIPs (1/1440"): 15 twips is one DIP,
/// so this is the design system's 16 DIP step. Twips rather than pixels
/// because RichEdit does the DPI conversion itself — the same number is right
/// at every scale.
const quote_indent_twips: i32 = 16 * 15;

// -------------------------------------------------------------------------
// The offset boundary (T648)
//
// Every pure module here works in BYTES into the pane's UTF-8 buffer — which
// is right, because that buffer is what the report is written from. Every edit
// message works in UTF-16 CODE UNITS, because that is what a `W` control
// stores. The two are the same number only for ASCII, so a `CHARRANGE` is
// never filled from a byte offset directly: it goes through `charIndex`, and a
// number that came back out of the control goes through `byteOffset`.
//
// The conversion itself is pure and lives in `utf16_offset.zig`; what these
// two add is the buffer to convert against, which is always the pane's — the
// control and the pane are kept in step by `readBack`.
// -------------------------------------------------------------------------

/// A byte offset in the pane's buffer, as the character index the control
/// understands.
fn charIndex(self: *const ViewerFeedbackBar, byte: usize) i32 {
    return @intCast(utf16_offset.unitsBeforeByte(self.pane.feedbackText(), byte));
}

/// A character index out of the control, as a byte offset into the pane's
/// buffer — what every pure module here expects.
fn byteOffset(self: *const ViewerFeedbackBar, unit: i32) usize {
    if (unit <= 0) return 0;
    return utf16_offset.byteForUnits(self.pane.feedbackText(), @intCast(unit));
}

/// Where the caret is, as a byte offset into the pane's buffer.
fn caret(self: *const ViewerFeedbackBar) usize {
    var sel: w32.CHARRANGE = .{ .cpMin = 0, .cpMax = 0 };
    _ = w32.SendMessageW(self.edit, w32.EM_EXGETSEL, 0, @bitCast(@intFromPtr(&sel)));
    return self.byteOffset(sel.cpMin);
}

fn setCaret(self: *ViewerFeedbackBar, at: usize) void {
    const u = self.charIndex(at);
    const cr: w32.CHARRANGE = .{ .cpMin = u, .cpMax = u };
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&cr)));
    _ = w32.SendMessageW(self.edit, w32.EM_SCROLLCARET, 0, 0);
}

/// Drop a quoted passage into the composer at the caret (Mac's Quote button).
///
/// The passage has already been registered by the pane, so this is only the
/// editing half: compute the block purely, put it in with `EM_REPLACESEL` so
/// it lands on the undo stack, then re-derive the formatting from the text.
pub fn insertQuote(self: *ViewerFeedbackBar, passage: []const u8) void {
    const ins = doc.insertion(
        self.alloc,
        self.pane.feedbackText(),
        self.caret(),
        passage,
    ) catch return;
    defer ins.deinit(self.alloc);

    // LF -> CRLF on the way in, the same conversion `seedControl` does: a bare
    // LF handed to RichEdit is not a paragraph break.
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(self.alloc);
    crlf.ensureTotalCapacity(self.alloc, ins.insert.len + 8) catch return;
    for (ins.insert) |c| {
        if (c == '\n') crlf.append(self.alloc, '\r') catch return;
        crlf.append(self.alloc, c) catch return;
    }
    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, crlf.items) catch return;
    defer self.alloc.free(wide);

    // `ins.at` is a byte offset into the PRE-insert buffer, which is what the
    // pane still holds at this point, so it converts against the same text the
    // control is showing.
    const at_u = self.charIndex(ins.at);
    const at: w32.CHARRANGE = .{ .cpMin = at_u, .cpMax = at_u };
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&at)));
    // wparam TRUE: the insertion is undoable, so Ctrl+Z takes a quote back out
    // the way it takes typing back out.
    _ = w32.SendMessageW(self.edit, w32.EM_REPLACESEL, 1, @bitCast(@intFromPtr(wide.ptr)));

    self.readBack();
    self.applyQuoteFormatting();
    self.setCaret(ins.caret_after);
    // The caret is now on the plain line under the block; without this the
    // first character typed there would be born wearing the quote's wash.
    self.ensurePlainAtCaret();

    if (self.syncMetrics()) self.textChanged() else _ = w32.InvalidateRect(self.hwnd, null, 1);
    _ = w32.InvalidateRect(self.edit, null, 1);
}

// -------------------------------------------------------------------------
// Images (T637)
// -------------------------------------------------------------------------

/// Take the clipboard's picture into the composer, if it has one. True when it
/// did — in which case the caller must NOT let the control run its own paste,
/// or the image's text fallback lands underneath the chip.
///
/// This is where Mac's `readablePasteboardTypes` trap has its win32 twin: a
/// RichEdit asks the clipboard for text and nothing else, so an image-only
/// clipboard pastes as silence. The composer asks first.
fn tryPasteImage(self: *ViewerFeedbackBar) bool {
    if (!clipboard_image.available()) return false;
    const png = clipboard_image.read(self.alloc, self.hwnd) orelse return false;
    defer self.alloc.free(png);
    return self.attachImage(png);
}

/// Store one PNG and put its chip at the caret. False when the picture could
/// not be taken, in which case nothing was inserted and the pane has already
/// said why in the footer.
pub fn attachImage(self: *ViewerFeedbackBar, png: []const u8) bool {
    const number = self.pane.feedbackAddImage(self.alloc, png) orelse return false;

    const ins = feedback_images.insertion(
        self.alloc,
        self.pane.feedbackText(),
        self.caret(),
        number,
    ) catch return false;
    defer ins.deinit(self.alloc);

    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, ins.insert) catch return false;
    defer self.alloc.free(wide);

    // The chip is plain text with plain formatting: born inside a quote's wash
    // it would read as part of the quote, and its metadata is its NUMBER, not
    // its styling.
    self.ensurePlainAtCaret();
    // Byte offset into the pre-insert buffer; see `insertQuote`.
    const at_u = self.charIndex(ins.at);
    const at: w32.CHARRANGE = .{ .cpMin = at_u, .cpMax = at_u };
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&at)));
    // wparam TRUE, so Ctrl+Z takes the chip back out the way it takes typing
    // out — and the picture leaves the report with it, because the report is
    // derived from the text.
    _ = w32.SendMessageW(self.edit, w32.EM_REPLACESEL, 1, @bitCast(@intFromPtr(wide.ptr)));

    self.readBack();
    self.applyQuoteFormatting();
    self.setCaret(ins.caret_after);
    self.ensurePlainAtCaret();

    if (self.syncMetrics()) self.textChanged() else _ = w32.InvalidateRect(self.hwnd, null, 1);
    // The strip scrolls to the picture that just arrived, which is what makes
    // a paste visible once the ribbon is longer than the pane.
    self.showThumb(number);
    _ = w32.InvalidateRect(self.edit, null, 1);

    log.info("viewer feedback pane={s} image=#{d} bytes={d} live={d}", .{
        self.pane.paneId(),
        number,
        png.len,
        self.pane.feedbackImageCount(self.alloc),
    });
    return true;
}

/// Backspace and Delete against a chip take the WHOLE chip.
///
/// A chip is literally the characters `[Image #3]`, so an unguarded Backspace
/// eats the `]` and leaves `[Image #3` — text that no longer parses as a chip,
/// which silently drops the picture from the report while still looking like
/// it is attached. Selecting the run first makes the chip behave like Mac's
/// single attachment character. Returns true when it selected something, and
/// the caller then lets the control delete the selection normally.
fn selectChipForDelete(self: *ViewerFeedbackBar, vk: u16) bool {
    var sel: w32.CHARRANGE = .{ .cpMin = 0, .cpMax = 0 };
    _ = w32.SendMessageW(self.edit, w32.EM_EXGETSEL, 0, @bitCast(@intFromPtr(&sel)));
    // Only a bare caret: an explicit selection is the user's own, and widening
    // it would delete more than they asked for.
    if (sel.cpMin != sel.cpMax or sel.cpMin < 0) return false;

    const text = self.pane.feedbackText();
    const at: usize = self.byteOffset(sel.cpMin);
    const chip = switch (vk) {
        w32.VK_BACK => feedback_images.chipEndingAt(text, at),
        w32.VK_DELETE => feedback_images.chipStartingAt(text, at),
        else => null,
    } orelse return false;

    const cr: w32.CHARRANGE = .{ .cpMin = self.charIndex(chip.start), .cpMax = self.charIndex(chip.end) };
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&cr)));
    return true;
}

// -------------------------------------------------------------------------
// The thumbnail carousel (T646)
//
// The strip has NO state of its own about what is in it: every tile is derived
// from the live chips in the composer's text, the same set the report's
// `images` array comes from. Delete a chip and its thumbnail goes with it,
// because there was never a second list to update.
//
// What IS state here is presentation: how far the ribbon is scrolled, which
// tile is ringed, and the decoded bitmaps.
// -------------------------------------------------------------------------

/// Report the strip's whole state on every change: how many tiles, where they
/// are in the BAND's own coordinates, how far the ribbon is scrolled and which
/// tile is ringed.
///
/// This is the acceptance script's only oracle and the reason it is this
/// detailed. The suite runs on a background desktop where nothing can look at
/// painted pixels (T233), so "the thumbnails appeared" has to be a sentence the
/// app says — and geometry it can point a click at, rather than one the script
/// re-derives from design-system constants and gets subtly wrong at 1.25.
fn logCarousel(self: *ViewerFeedbackBar, what: []const u8) void {
    const l = self.currentLayout();
    log.info(
        "viewer feedback pane={s} carousel={s} tiles={d} scroll={d} selected={d} " ++
            "left={d} top={d} thumb={d} stride={d}",
        .{
            self.pane.paneId(),
            what,
            self.images,
            self.carousel_scroll,
            if (self.carousel_selected) |i| @as(i64, @intCast(i)) else -1,
            l.carousel.left,
            l.carousel.top,
            l.thumb,
            l.thumb_stride,
        },
    );
}

/// The decoded tile for image `number`, at tile side `box`. Decoded on first
/// paint and cached — a repaint of a six-image strip must not be six PNG
/// decodes. Null when GDI+ could not read the picture, which is cached too.
fn thumbFor(self: *ViewerFeedbackBar, number: u32, png: []const u8, box: i32) ?Thumb {
    for (self.thumbs.items) |t| {
        if (t.number == number and t.box == box) return t;
    }
    const size = feedback_images.pngSize(png) orelse return null;
    const fit = layout_mod.fitInto(size.width, size.height, box);
    var entry: Thumb = .{ .number = number, .box = box, .dib = null };
    if (gdiplus_decode.decodeBytes(png, fit.w, fit.h)) |t| {
        entry.dib = t.dib;
        entry.w = t.w;
        entry.h = t.h;
        // Reported because a tile the strip COUNTS and a tile it can actually
        // draw are two different claims, and the acceptance suite runs where
        // no one can look at the pixels to tell them apart.
        log.info("viewer feedback pane={s} thumb=#{d} box={d} decoded={d}x{d}", .{
            self.pane.paneId(),
            number,
            box,
            t.w,
            t.h,
        });
    } else {
        log.warn("viewer feedback thumbnail #{d} could not be decoded", .{number});
    }
    self.thumbs.append(self.alloc, entry) catch {
        // Not cacheable, so it must not leak either: without the cache entry
        // nothing would ever delete this bitmap.
        if (entry.dib) |d| _ = w32.DeleteObject(d);
        return null;
    };
    return entry;
}

/// Point the strip at whichever chip the caret is in: ring its tile and scroll
/// it into view. This is the "vice versa" half of the sync — clicking a chip in
/// the text (or arrowing into one) walks the strip to its picture.
///
/// A caret at either END of a chip counts as inside it, because clicking a chip
/// parks the caret at one of them, and an end that did not count would make the
/// gesture do nothing at all.
fn syncCarouselToCaret(self: *ViewerFeedbackBar) void {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);

    const at = self.caret();
    var found: ?usize = null;
    for (spans, 0..) |s, i| {
        if (at >= s.start and at <= s.end) {
            found = i;
            break;
        }
    }

    const before_sel = self.carousel_selected;
    const before_scroll = self.carousel_scroll;
    self.carousel_selected = found;
    if (found) |i| {
        self.carousel_scroll = self.currentLayout().scrollToShow(i, self.carousel_scroll);
    }
    if (before_sel != self.carousel_selected or before_scroll != self.carousel_scroll) {
        _ = w32.InvalidateRect(self.hwnd, null, 1);
        self.logCarousel("caret");
    }
}

/// Bring image `number`'s tile into view — what a fresh paste does, so the
/// picture that just arrived is the one you can see even when the strip is
/// already longer than the pane.
///
/// Driven by the NUMBER rather than by the caret, because the caret lands past
/// the chip's trailing space and is therefore not "in" it: a paste knows
/// exactly which picture it just added, and guessing from the caret would be a
/// worse answer to a question nobody has to ask.
fn showThumb(self: *ViewerFeedbackBar, number: u32) void {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);
    for (spans, 0..) |s, i| {
        if (self.pane.feedbackImageEntry(s).number != number) continue;
        const next = self.currentLayout().scrollToShow(i, self.carousel_scroll);
        if (next != self.carousel_scroll) {
            self.carousel_scroll = next;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
            self.logCarousel("paste");
        }
        return;
    }
}

/// A tile was clicked: select its chip in the composer and put the caret there.
/// The forward half of the sync, and the reason it selects the whole chip
/// rather than just moving the caret — the chip is one unit (see
/// `selectChipForDelete`), so pointing at it means highlighting all of it.
fn activateThumb(self: *ViewerFeedbackBar, index: usize) void {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);
    if (index >= spans.len) return;
    const s = spans[index];

    const cr: w32.CHARRANGE = .{ .cpMin = self.charIndex(s.start), .cpMax = self.charIndex(s.end) };
    _ = w32.SetFocus(self.edit);
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&cr)));
    _ = w32.SendMessageW(self.edit, w32.EM_SCROLLCARET, 0, 0);

    self.carousel_selected = index;
    self.carousel_scroll = self.currentLayout().scrollToShow(index, self.carousel_scroll);
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    log.info("viewer feedback pane={s} thumbnail=#{d} chip={d}..{d}", .{
        self.pane.paneId(),
        self.pane.feedbackImageEntry(s).number,
        s.start,
        s.end,
    });
    self.logCarousel("click");
}

/// Wheel over the band scrolls the strip, when there is anything to scroll.
fn scrollCarousel(self: *ViewerFeedbackBar, delta: i32) void {
    const l = self.currentLayout();
    if (l.maxScroll() == 0) return;
    // One notch moves one whole tile: a strip of discrete pictures reads
    // better stepped than smeared.
    const next = l.clampScroll(self.carousel_scroll - delta * l.thumb_stride);
    if (next == self.carousel_scroll) return;
    self.carousel_scroll = next;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// The live quote spans, in the pane's buffer coordinates. Caller frees.
/// Null when there is nothing to do, so callers can bail without a branch on
/// an empty slice they would then have to free.
fn quoteSpans(self: *const ViewerFeedbackBar) ?[]doc.Span {
    const spans = self.pane.feedbackQuoteSpans(self.alloc) orelse return null;
    if (spans.len == 0) {
        self.alloc.free(spans);
        return null;
    }
    return spans;
}

/// Re-derive every run's formatting from the text: flat everywhere, washed and
/// indented over each live quote.
///
/// Derived rather than maintained, for the same reason identity is (see
/// `viewer_feedback_doc.zig`): RichEdit will not tell us how an edit moved a
/// run, so the only formatting that cannot drift out of step with the report
/// is formatting computed from the text the report is made of.
fn applyQuoteFormatting(self: *ViewerFeedbackBar) void {
    const spans = self.quoteSpans();
    defer if (spans) |s| self.alloc.free(s);

    // Selection is the caret when nothing is selected, so this is also what
    // keeps the caret where it was through the walk below.
    var sel: w32.CHARRANGE = .{ .cpMin = 0, .cpMax = 0 };
    _ = w32.SendMessageW(self.edit, w32.EM_EXGETSEL, 0, @bitCast(@intFromPtr(&sel)));

    _ = w32.SendMessageW(self.edit, w32.WM_SETREDRAW, 0, 0);
    self.formatRange(0, -1, false);
    if (spans) |list| {
        for (list) |s| self.formatRange(self.charIndex(s.start), self.charIndex(s.end), true);
    }
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&sel)));
    _ = w32.SendMessageW(self.edit, w32.WM_SETREDRAW, 1, 0);
    // WM_SETREDRAW does not repaint on the way back on; without this the
    // control keeps showing whatever was on screen when it was switched off.
    _ = w32.InvalidateRect(self.edit, null, 1);
}

/// Character wash + paragraph indent over one range, in the control's own
/// CHARACTER indices (callers convert with `charIndex`). `to` of -1 is "to the
/// end", which is how the flat pass covers the whole document.
fn formatRange(self: *ViewerFeedbackBar, from: i32, to: i32, quoted: bool) void {
    const cr: w32.CHARRANGE = .{ .cpMin = from, .cpMax = to };
    _ = w32.SendMessageW(self.edit, w32.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&cr)));

    const wash = if (quoted) self.quote_rgb else self.pill_rgb;
    var cf = std.mem.zeroes(w32.CHARFORMAT2W);
    cf.cbSize = @sizeOf(w32.CHARFORMAT2W);
    cf.dwMask = w32.CFM_COLOR | w32.CFM_BACKCOLOR;
    cf.crTextColor = self.text_ref;
    // "No wash" is the PILL's own colour rather than an auto-colour effect:
    // the control's background is the pill, so they are the same pixel, and
    // one code path is easier to keep right than two.
    cf.crBackColor = w32.RGB(wash.r, wash.g, wash.b);
    _ = w32.SendMessageW(self.edit, w32.EM_SETCHARFORMAT, w32.SCF_SELECTION, @bitCast(@intFromPtr(&cf)));

    var pf = std.mem.zeroes(w32.PARAFORMAT2);
    pf.cbSize = @sizeOf(w32.PARAFORMAT2);
    pf.dwMask = w32.PFM_STARTINDENT;
    pf.dxStartIndent = if (quoted) quote_indent_twips else 0;
    _ = w32.SendMessageW(self.edit, w32.EM_SETPARAFORMAT, 0, @bitCast(@intFromPtr(&pf)));
}

/// Refuse quote styling at the source, before the character that would inherit
/// it exists.
///
/// RichEdit carries character formatting forward from the character BEFORE the
/// caret — the win32 spelling of the trap Mac hits through `typingAttributes`.
/// So the moment before a keystroke is applied, a caret that is not inside a
/// quote has its typing attributes reset to plain. Doing it here rather than
/// after the fact is what keeps a select-all + delete + type from leaving the
/// user writing inside a quote that no longer exists.
fn ensurePlainAtCaret(self: *ViewerFeedbackBar) void {
    var sel: w32.CHARRANGE = .{ .cpMin = 0, .cpMax = 0 };
    _ = w32.SendMessageW(self.edit, w32.EM_EXGETSEL, 0, @bitCast(@intFromPtr(&sel)));
    // A non-empty selection is about to be REPLACED; the format that matters
    // is the one at its start, which is where the new text lands.
    const pos: usize = self.byteOffset(sel.cpMin);

    const spans = self.quoteSpans();
    defer if (spans) |s| self.alloc.free(s);
    const list: []const doc.Span = if (spans) |s| s else &.{};
    if (doc.insideQuote(list, pos)) return;

    var cf = std.mem.zeroes(w32.CHARFORMAT2W);
    cf.cbSize = @sizeOf(w32.CHARFORMAT2W);
    cf.dwMask = w32.CFM_COLOR | w32.CFM_BACKCOLOR;
    cf.crTextColor = self.text_ref;
    cf.crBackColor = w32.RGB(self.pill_rgb.r, self.pill_rgb.g, self.pill_rgb.b);
    _ = w32.SendMessageW(self.edit, w32.EM_SETCHARFORMAT, w32.SCF_SELECTION, @bitCast(@intFromPtr(&cf)));

    // The indent is per PARAGRAPH, and the caret one past a quote's last
    // character is still in the quote's last paragraph — resetting from there
    // would un-indent the block the user is typing at the end of.
    if (doc.lineTouchesQuote(self.pane.feedbackText(), list, pos)) return;
    var pf = std.mem.zeroes(w32.PARAFORMAT2);
    pf.cbSize = @sizeOf(w32.PARAFORMAT2);
    pf.dwMask = w32.PFM_STARTINDENT;
    pf.dxStartIndent = 0;
    _ = w32.SendMessageW(self.edit, w32.EM_SETPARAFORMAT, 0, @bitCast(@intFromPtr(&pf)));
}

/// The accent bar down each quoted block's left edge.
///
/// Hand-drawn because `CHARFORMAT2.crBackColor` paints tight line boxes and
/// nothing else — no bar, no rounding — which is the same limitation that
/// makes Mac draw its bar in `drawBackground(in:)` rather than asking for a
/// background attribute. Drawn over the control's own `WM_PAINT` for the same
/// reason the placeholder is: the control is opaque and on top, so there is no
/// "behind" to paint into.
fn paintQuoteBars(self: *ViewerFeedbackBar, hdc: w32.HDC) void {
    const spans = self.quoteSpans() orelse return;
    defer self.alloc.free(spans);

    const scale = if (self.scale > 0) self.scale else 1.0;
    const line_h = type_ramp.lineBox(type_ramp.body(scale), scale);
    const w: i32 = @max(2, @as(i32, @intFromFloat(@round(3 * scale))));
    const x: i32 = @max(1, @as(i32, @intFromFloat(@round(5 * scale))));

    const brush = w32.CreateSolidBrush(self.accent_ref) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    for (spans) |s| {
        if (s.end == 0) continue;
        var top: w32.POINTL = .{ .x = 0, .y = 0 };
        var bottom: w32.POINTL = .{ .x = 0, .y = 0 };
        _ = w32.SendMessageW(self.edit, w32.EM_POSFROMCHAR, @intFromPtr(&top), self.charIndex(s.start));
        // The block's LAST character, not the position after it: one past the
        // end is the next line, and the bar would run a line too far. Stepped
        // back a CODE UNIT rather than a byte — `s.end - 1` can land inside a
        // multi-byte character, and a byte is not a position here.
        const last = @max(0, self.charIndex(s.end) - 1);
        _ = w32.SendMessageW(self.edit, w32.EM_POSFROMCHAR, @intFromPtr(&bottom), last);
        var r: w32.RECT = .{
            .left = x,
            .top = top.y,
            .right = x + w,
            .bottom = bottom.y + line_h,
        };
        if (r.bottom <= r.top) continue;
        _ = w32.FillRect(hdc, &r, brush);
    }
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
    self.paintCarousel(hdc, l);
    self.paintFooter(hdc, l);
}

/// The thumbnail strip: one tile per live chip, clipped to the viewport, with
/// the caret's own chip ringed.
fn paintCarousel(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (l.carousel.isEmpty()) return;
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);
    if (spans.len == 0) return;

    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    _ = w32.IntersectClipRect(
        hdc,
        l.carousel.left,
        l.carousel.top,
        l.carousel.right,
        l.carousel.bottom,
    );

    for (spans, 0..) |s, i| {
        const tile = l.thumbAt(i, self.carousel_scroll);
        // Wholly off one end: nothing to draw, and no decode to pay for.
        if (tile.right <= l.carousel.left or tile.left >= l.carousel.right) continue;

        // The tile's own well, one step off the band exactly as the pill is,
        // so an image with transparent or light edges still reads as a tile.
        self.paintTileFrame(hdc, l, tile, self.carousel_selected == i);

        const e = self.pane.feedbackImageEntry(s);
        const box = l.thumb - 2 * l.thumb_inset;
        const t = self.thumbFor(e.number, e.png, box) orelse continue;
        const dib = t.dib orelse continue;
        blitThumb(hdc, tile, t, dib);
    }
}

fn paintTileFrame(
    self: *ViewerFeedbackBar,
    hdc: w32.HDC,
    l: layout_mod.Layout,
    tile: layout_mod.Rect,
    selected: bool,
) void {
    const fill = w32.CreateSolidBrush(w32.RGB(self.pill_rgb.r, self.pill_rgb.g, self.pill_rgb.b));
    // A selected tile is ringed in the accent at 2 px: the ring is the only
    // thing saying "this is the picture the caret is in", so it has to survive
    // sitting next to a bright screenshot.
    const pen = if (selected)
        w32.CreatePen(0, 2, self.accent_ref)
    else
        w32.CreatePen(0, 1, self.border_ref);
    if (fill != null and pen != null) {
        const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
        const prev_pen = w32.SelectObject(hdc, pen.?);
        _ = w32.RoundRect(
            hdc,
            tile.left,
            tile.top,
            tile.right,
            tile.bottom,
            l.thumb_r * 2,
            l.thumb_r * 2,
        );
        _ = w32.SelectObject(hdc, prev_pen);
        _ = w32.SelectObject(hdc, prev_brush);
    }
    if (fill) |b| _ = w32.DeleteObject(@ptrCast(b));
    if (pen) |p| _ = w32.DeleteObject(p);
}

/// Blit one decoded picture into the middle of its tile. Already scaled to fit
/// (see `thumbFor`), so this is a straight `BitBlt` — the aspect ratio was
/// settled at decode time and cannot be got wrong twice.
fn blitThumb(hdc: w32.HDC, tile: layout_mod.Rect, t: Thumb, dib: w32.HANDLE) void {
    if (t.w <= 0 or t.h <= 0) return;
    const src = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(src);
    const old = w32.SelectObject(src, dib);
    defer _ = w32.SelectObject(src, old);
    _ = w32.BitBlt(
        hdc,
        tile.left + @divTrunc(tile.width() - t.w, 2),
        tile.top + @divTrunc(tile.height() - t.h, 2),
        t.w,
        t.h,
        src,
        0,
        0,
        w32.SRCCOPY,
    );
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

    // A send that has landed replaces the destination with what happened to
    // it — Mac's "Filed …". The destination is what the report is ABOUT to do;
    // once it has been done, saying so is the more useful of the two, and the
    // composer closes itself behind the confirmation anyway.
    if (self.pane.feedbackStatus()) |status| {
        const saved2 = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, saved2);
        _ = w32.IntersectClipRect(
            hdc,
            l.footer.left,
            l.footer.top,
            @max(l.footer.right - hint_w - 8, l.footer.left),
            l.footer.bottom,
        );
        _ = w32.SetTextColor(hdc, self.text_ref);
        drawUtf8(hdc, l.footer.left, l.footer.top, status);
        return;
    }

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

/// A button click, delivered on mouse-up over the same button it went down on.
/// `↑` files the report (T636); `+` takes a screenshot (T647).
fn activate(self: *ViewerFeedbackBar, b: layout_mod.Button) void {
    switch (b) {
        .snapshot => self.beginSnapshot(),
        .send => self.pane.sendFeedback(self.alloc),
    }
}

/// Put the region selector up (T647) — the `+` button and Ctrl+Shift+S.
///
/// Idempotent while one is already up: both entry points can be reached while
/// the overlay has focus, and a second full-desktop window over the first is
/// not a second screenshot, it is a stuck screen.
fn beginSnapshot(self: *ViewerFeedbackBar) void {
    if (self.selector != null) return;
    const hinstance: ?w32.HINSTANCE = @ptrCast(w32.GetModuleHandleW(null));
    self.selector = RegionSelector.begin(
        self.alloc,
        hinstance,
        w32.GetAncestor(self.hwnd, w32.GA_ROOT),
        self.scale,
        self,
        captureDone,
    );
    if (self.selector == null) {
        log.warn("viewer feedback pane={s} capture=unavailable", .{self.pane.paneId()});
    }
}

/// The selector's one callback: attach what it captured, or note the cancel.
///
/// The bytes belong to the selector and are freed as soon as this returns —
/// `attachImage` copies into the pane's store, the same contract the clipboard
/// paste path already relies on.
fn captureDone(ctx: *anyopaque, png: ?[]const u8) void {
    const self: *ViewerFeedbackBar = @ptrCast(@alignCast(ctx));
    // Cleared BEFORE anything else: the selector destroys itself the moment
    // this returns, so the pointer is dead from here on either way.
    self.selector = null;

    if (png) |bytes| {
        _ = self.attachImage(bytes);
    }
    // The overlay took the keyboard to get its Escape; the composer is where
    // the user was typing, and where the chip just landed.
    _ = w32.SetFocus(self.edit);
}

/// Repaint the composer's own chrome — what the pane calls when something it
/// owns and this draws (the footer's status line) has changed.
pub fn repaint(self: *ViewerFeedbackBar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 1);
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
            .send => self.pane.sendFeedback(self.alloc),
            .close => self.pane.setFeedbackOpen(false),
            .snapshot => self.beginSnapshot(),
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
        .reload => self.pane.reloadContent(.chrome),
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

    // BEFORE the control acts on it: every message that is about to put new
    // text where the caret is has its typing attributes reset first, so the
    // character never exists wearing the quote's formatting (T641). Doing it
    // afterwards would mean repainting a character the user already saw
    // tinted.
    switch (msg) {
        // A clipboard carrying a picture is pasted as the picture, and the
        // control never runs its own paste — see `tryPasteImage`.
        w32.WM_PASTE => {
            if (self.tryPasteImage()) return 0;
            self.ensurePlainAtCaret();
        },
        w32.WM_CHAR => {
            // Ctrl+V still generates its control character (TranslateMessage
            // runs before dispatch), so a paste this handled has to swallow
            // the SYN that follows or the chip gets a stray character after it.
            if (self.swallow_paste_char) {
                self.swallow_paste_char = false;
                if (wparam & 0xFFFF == 0x16) return 0;
            }
            self.ensurePlainAtCaret();
        },
        w32.WM_KEYDOWN => {
            // Enter is the one key that inserts text, and Delete/Backspace can
            // remove the character the caret was inheriting from.
            const vk: u16 = @intCast(wparam & 0xFFFF);
            if (vk == w32.VK_RETURN or vk == w32.VK_BACK or vk == w32.VK_DELETE) {
                // A chip deletes whole (see `selectChipForDelete`), then the
                // control removes the selection it was handed.
                _ = self.selectChipForDelete(vk);
                self.ensurePlainAtCaret();
            }
            // Ctrl+V is intercepted HERE rather than relying on the control to
            // turn it into a WM_PASTE: whether it does is a RichEdit internal,
            // and a paste that silently does nothing is the exact failure this
            // whole path exists to prevent.
            if (vk == vk_v and w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
                if (self.tryPasteImage()) {
                    self.swallow_paste_char = true;
                    return 0;
                }
            }
        },
        else => {},
    }

    const res = w32.CallWindowProcW(prev, hwnd, msg, wparam, lparam);

    // AFTER the control moved the caret: every way a selection changes without
    // the text changing (a click, an arrow key, Home/End) lands here, and the
    // strip follows the caret into whichever chip it is now in (T646). The
    // text-changing paths sync from `EN_CHANGE` instead, which is the one
    // notification RichEdit does send.
    switch (msg) {
        w32.WM_LBUTTONUP, w32.WM_KEYUP, w32.WM_KEYDOWN => self.syncCarouselToCaret(),
        else => {},
    }

    if (msg != w32.WM_PAINT) return res;

    // The quote bars come first: they are content, the placeholder is only
    // ever shown over an EMPTY control, and the two therefore never overlap.
    //
    // T252 audited these two `GetDC` paints and they STAY, as the third case
    // the rule allows: an overlay on a control we do not own. RichEdit does its
    // own `BeginPaint`/`EndPaint` inside `CallWindowProcW` above and validates
    // the region on the way out, so there is no paint cycle left to join —
    // invalidating here would only ask the control to paint itself again and
    // land right back at this line. What makes it safe is that it is DRIVEN by
    // `WM_PAINT`: every repaint of the control re-runs it, so the bars and the
    // placeholder are reproduced from state like anything painted inside the
    // cycle, rather than existing only until something paints over them. The
    // one thing it is not is capturable through the control's own
    // `WM_PRINT`/`WM_PRINTCLIENT`, which this subclass ignores — hence
    // viewer-feedback.ps1 reads the placeholder off the debug log
    // (`composer created … painted_placeholder=`) rather than off pixels.
    {
        const bars = w32.GetDC(hwnd);
        if (bars) |dc| {
            defer _ = w32.ReleaseDC(hwnd, dc);
            self.paintQuoteBars(dc);
        }
    }

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
                // Only a line- or tile-count change moves the page; anything
                // else is a repaint. Asking the pane to re-inset on every
                // keystroke would resize the WebView2 while someone is typing
                // into it.
                if (self.syncMetrics()) self.textChanged() else _ = w32.InvalidateRect(hwnd, null, 1);
                self.syncCarouselToCaret();
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
                return 0;
            }
            // A tile acts on mouse-UP over the same tile, the way the two
            // circular actions do — a click that slid off is a cancelled click
            // everywhere else in this chrome.
            if (l.hitThumb(self.carousel_scroll, x, y)) |i| {
                self.pressed_thumb = i;
                _ = w32.SetCapture(hwnd);
            }
            return 0;
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            _ = w32.ReleaseCapture();
            const was = self.pressed;
            const was_thumb = self.pressed_thumb;
            self.pressed = null;
            self.pressed_thumb = null;
            _ = w32.InvalidateRect(hwnd, null, 1);
            const l = self.currentLayout();
            if (was) |b| {
                if (l.hitButton(self.scale, x, y) == b) self.activate(b);
            } else if (was_thumb) |i| {
                if (l.hitThumb(self.carousel_scroll, x, y) == i) self.activateThumb(i);
            }
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            const raw: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            self.scrollCarousel(@divTrunc(@as(i32, raw), @as(i32, w32.WHEEL_DELTA)));
            return 0;
        },

        WM_APP_RELAYOUT => {
            self.textChanged();
            return 0;
        },

        w32.WM_KEYDOWN => {
            if (self.handleKey(@intCast(wparam & 0xFFFF))) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// T467: `paint` fills the client and then places the pill, the image carousel
// and the send row from a layout built on the bar's own width, so a resize
// makes all of it stale — not just the strip Windows uncovers.
test "viewer feedback class: a resize invalidates the whole bar" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClass(hinst);
    if (!class_registered) return error.SkipZigTest;
    try class_redraw.expectResizeInvalidatesWholeClient(CLASS_NAME);
}
