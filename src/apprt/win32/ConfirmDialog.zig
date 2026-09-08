//! Dark-mode replacement for the light `MessageBoxW` prompts (T80).
//!
//! A small owner-centered dialog in the T50 RenameDialog pattern — dark
//! caption, dark client, system icon, message text, OK/Cancel — but with a
//! *synchronous* API: `show` disables the owner, runs its own nested
//! message loop (exactly what MessageBoxW does internally, which the T48
//! analysis established is WndProc-safe: the thread keeps pumping, so the
//! IME/CTF cascade and the IPC message-only window stay live), and returns
//! the user's choice. That keeps every caller's control flow identical to
//! the MessageBoxW it replaces.
//!
//! Semantics preserved from the MessageBoxW sites:
//!   - `default_cancel` mirrors MB_DEFBUTTON2: initial focus and the Enter
//!     default land on Cancel so an accidental Enter never approves a
//!     destructive action.
//!   - Escape cancels (for `ok_only` it simply dismisses).
//!   - The ✕ close box cancels.

const ConfirmDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const w32 = @import("win32.zig");
const type_ramp = @import("type_ramp.zig");
const utf16_text = @import("utf16_text.zig");
const brush_cache = @import("brush_cache.zig");
const panel_theme = @import("panel_theme.zig");
const system_colors = @import("system_colors.zig");
const release_notes = @import("release_notes.zig");
const whats_new_layout = @import("whats_new_layout.zig");
const WhatsNewNotesView = @import("WhatsNewNotesView.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyConfirmDialog");

/// `alt` is the optional THIRD button (`Options.alt_label`) — a second
/// affirmative that is not the primary one. It exists for the remote-close
/// confirmation's **Disconnect** (T1390), where "close the window but keep the
/// sessions" is neither OK nor Cancel.
pub const Result = enum { ok, cancel, alt };
pub const Style = enum { ok_only, ok_cancel };
pub const Icon = enum { none, warning, info };

pub const Options = struct {
    title: [*:0]const u16,
    text: [:0]const u16,
    style: Style = .ok_cancel,
    icon: Icon = .warning,
    /// MB_DEFBUTTON2 parity: focus + Enter default on Cancel.
    default_cancel: bool = true,
    /// Button captions. The affirmative/dismissive semantics (and the
    /// Result values) stay OK/Cancel regardless of the label — callers
    /// like the T69 config-errors dialog relabel them ("Open Config" /
    /// "Ignore") without changing any dialog behavior. Buttons widen to
    /// fit the longer caption.
    ok_label: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("OK"),
    cancel_label: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
    /// When non-null (and `style` is `.ok_cancel`), a THIRD button carrying
    /// this caption, returning `.alt`. It takes the LEADING slot of the button
    /// row — `[alt] [ok] [cancel]`, right-aligned with Cancel last — which is
    /// the Windows convention this dialog already follows for two buttons, and
    /// where a Win32 user looks for the primary action. (Mac puts its default
    /// rightmost; the platforms disagree about the row, not about the answer.)
    alt_label: ?[:0]const u16 = null,
    /// Put the Enter default on the third button instead of OK/Cancel. Mac's
    /// remote close defaults to Disconnect — the non-destructive answer — and
    /// so does this. Ignored when there is no `alt_label`.
    default_alt: bool = false,
    /// When non-null the dialog carries a single-line text field seeded with
    /// this text, below the message — Mac's NSAlert `accessoryView` prompts
    /// (rename a relay device, T176) are the same alert with a field bolted
    /// on, so this is the same dialog rather than a second class.
    ///
    /// Only `prompt` reads the field back; `show` ignores it. A field takes
    /// initial focus (with its text selected) and makes OK the Enter default,
    /// because a prompt's Enter must commit what was typed.
    input: ?[:0]const u16 = null,
    /// Optional checkbox rows between the message and the buttons — Mac's
    /// NSAlert accessory checkboxes (the agent-integration first-run offer,
    /// T870). MUTABLE: on OK the dialog writes each row's final state back
    /// into `checked`; on Cancel the values are left as passed. At most
    /// `max_checks` rows.
    checks: []Check = &.{},
    /// Optional RELEASE-NOTES accessory (T625): a scrolling region showing
    /// what an update changed, between the message and the buttons. Mac hangs
    /// the same view off its mandatory agent-restart alert, so the user
    /// answering "this closes your sessions" can see what the restart buys
    /// them.
    ///
    /// The notes scroll INSIDE a fixed band, so a release with twelve bullets
    /// and one with two produce the same dialog — evidence must never move the
    /// buttons the user is reaching for. Ignored on the app-less paths
    /// (`showStandalone`), which have no theme, no allocator and no update
    /// story.
    notes: ?Notes = null,
    /// Optional caption-sized secondary note under the check rows — Mac's
    /// wrapping caption label in the first-launch accessory (T600, the
    /// agent-config-write disclosure). Rendered in the caption ramp role and
    /// the secondary text color, so it reads as fine print rather than a
    /// second message paragraph.
    note: ?[:0]const u16 = null,
};

pub const Notes = struct {
    /// The split to show. BORROWED — the caller owns the store these slices
    /// point into, and `show` does not return until the dialog is gone, so a
    /// stack-owned store is exactly right.
    split: release_notes.Partitioned,
};

pub const Check = struct {
    label: [:0]const u16,
    checked: bool = true,
};

/// Checkbox row capacity (two agent runtimes today; room to grow).
pub const max_checks = 4;

/// Control id for the optional third button (T1390). A private value: the
/// checkbox rows own 100.., and IDOK/IDCANCEL are already spoken for.
const ID_ALT: u16 = 200;

/// The dialog's palette (T563), derived from the surface `window-theme` puts
/// the app on and the accent the user picked — the derivation the panels got
/// in T308. It was four literals described as "the RenameDialog dark palette",
/// which is a fine description of a dialog that can only ever be dark and a
/// defect on a light system theme.
///
/// `app` is optional because this dialog has an app-less path: the
/// startup-failure box (T1177) runs before there is an `App`, and the
/// standalone updater has none at all. With no configured `window-theme` and
/// no configured background to derive from, the honest surface is the OS apps
/// theme — which is what any other app-less Windows dialog follows.
fn pal(self: *const ConfirmDialog) panel_theme.Panel {
    return if (self.app) |a| system_colors.panelFor(a) else system_colors.panelSystem();
}

/// Keyed on the color they were made for: a GDI brush is immutable, so a theme
/// flip has to mean a new object rather than a handle stuck on the old palette.
var class_registered: bool = false;
var bg_brush: brush_cache.CachedBrush = .{};
var field_brush: brush_cache.CachedBrush = .{};

/// The app whose theme this dialog paints from, or null on the app-less
/// paths (`showStandalone`, and the updater's own process).
app: ?*App,
hwnd: w32.HWND,
static: ?w32.HWND,
/// The optional secondary note (`Options.note`), colored separately in
/// WM_CTLCOLORSTATIC.
note_static: ?w32.HWND = null,
ok_btn: w32.HWND,
cancel_btn: ?w32.HWND,
/// The optional third button (`Options.alt_label`), returning `.alt` (T1390).
alt_btn: ?w32.HWND = null,
/// The optional text field (`Options.input`), read back by `prompt`.
edit: ?w32.HWND = null,
/// The optional release-notes accessory (`Options.notes`), T625. Owns its own
/// scroll offset and swallows the wheel while the pointer is over it.
notes_view: ?*WhatsNewNotesView = null,
/// The optional checkbox rows (`Options.checks`), read back on OK.
check_btns: [max_checks]?w32.HWND = @splat(null),
n_checks: usize = 0,
icon_handle: ?w32.HICON,
icon_rect: w32.RECT,
default_cancel: bool,
/// Enter (and initial focus) lands on the third button rather than OK/Cancel.
/// Mutually exclusive with `default_cancel`, which `run` resolves.
default_alt: bool = false,
result: Result = .cancel,
done: bool = false,

/// Dialog layout in physical pixels, computed from the owner window's DPI
/// scale and the measured text extent. Pure — unit tested below.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    icon: w32.RECT,
    text: w32.RECT,
    /// The optional text field, spanning the text column (empty rect when the
    /// dialog has no input).
    input: w32.RECT,
    /// The optional release-notes accessory (empty rect when the dialog has
    /// none). Sits directly under the message, because it is evidence FOR the
    /// message rather than a second question.
    notes: w32.RECT,
    /// The optional checkbox rows (only the first `n_checks` passed to
    /// `layoutFor` are meaningful; the rest stay empty).
    checks: [max_checks]w32.RECT,
    /// The optional secondary note under the check rows (empty rect when the
    /// dialog has none).
    note: w32.RECT,
    ok: w32.RECT,
    cancel: w32.RECT,
    /// The optional third button (empty rect when the dialog has none).
    alt: w32.RECT,
    font_h: i32,
};

/// `btn_w` is the physical-pixel button width — at least the standard
/// 88 DIP, wider when a caption needs the room (see buttonWidth).
/// `has_input` adds a single-line field row under the message (T176);
/// `n_checks` adds that many checkbox rows between the message and the
/// field/buttons (T870); `note_h` (measured caption-text height, 0 for
/// none) adds the secondary note band under the checks (T600).
/// `notes_h` (0 for none) adds the fixed release-notes band under the message
/// (T625).
pub fn layoutFor(
    scale: f32,
    text_w: i32,
    text_h: i32,
    has_icon: bool,
    notes_h: i32,
    n_checks: usize,
    note_h: i32,
    has_input: bool,
    has_cancel: bool,
    has_alt: bool,
    btn_w: i32,
) Layout {
    const margin = px(16, scale);
    const icon_px = px(32, scale);
    const icon_gap = px(12, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);
    const btn_gap_v = px(18, scale);
    const input_h = px(26, scale);
    const input_gap = px(12, scale);
    const check_h = px(20, scale);
    const check_gap = px(12, scale);
    const check_row_gap = px(4, scale);
    const note_gap = px(12, scale);
    const notes_gap = px(12, scale);

    const icon_span: i32 = if (has_icon) icon_px + icon_gap else 0;
    // `alt` only ever accompanies a Cancel: it is a second AFFIRMATIVE, and a
    // dialog offering two ways to say yes and no way to say no is not a choice.
    const with_alt = has_alt and has_cancel;
    const n_btns: i32 = (if (has_cancel) @as(i32, 2) else 1) + @intFromBool(with_alt);
    const btns_w = n_btns * btn_w + (n_btns - 1) * btn_gap_h;

    var client_w = margin + icon_span + text_w + margin;
    // Never narrower than the button row (or a sane floor). A prompt gets a
    // wider floor: a field the width of a two-word message is unusable.
    client_w = @max(client_w, margin + btns_w + margin);
    // A notes accessory gets the widest floor of the three: release notes are
    // prose in bulleted blocks, and prose wrapped to a two-word message's
    // width is a column of single words.
    client_w = @max(client_w, px(if (notes_h > 0) 460 else if (has_input) 380 else 280, scale));

    const content_h = @max(text_h, if (has_icon) icon_px else 0);
    const nc: i32 = @intCast(@min(n_checks, max_checks));
    const checks_span: i32 = if (nc > 0)
        check_gap + nc * check_h + (nc - 1) * check_row_gap
    else
        0;
    const note_span: i32 = if (note_h > 0) note_gap + note_h else 0;
    const input_span: i32 = if (has_input) input_gap + input_h else 0;
    const notes_span: i32 = if (notes_h > 0) notes_gap + notes_h else 0;
    const client_h = margin + content_h + notes_span + checks_span + note_span +
        input_span + btn_gap_v + btn_h + margin;

    // Vertically center the shorter of icon/text within the content band.
    const icon_top = margin + @divTrunc(content_h - icon_px, 2);
    const text_top = margin + @divTrunc(content_h - text_h, 2);

    var checks: [max_checks]w32.RECT = @splat(.{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
    var i: i32 = 0;
    while (i < nc) : (i += 1) {
        const top = margin + content_h + notes_span + check_gap + i * (check_h + check_row_gap);
        checks[@intCast(i)] = .{
            .left = margin + icon_span,
            .top = top,
            .right = client_w - margin,
            .bottom = top + check_h,
        };
    }

    const notes_top = margin + content_h + notes_gap;
    const note_top = margin + content_h + notes_span + checks_span + note_gap;
    const input_top = margin + content_h + notes_span + checks_span + note_span + input_gap;
    const btn_top = margin + content_h + notes_span + checks_span + note_span +
        input_span + btn_gap_v;
    const right_left = client_w - margin - btn_w;
    const left_left = right_left - btn_gap_h - btn_w;
    const far_left = left_left - btn_gap_h - btn_w;
    // With two buttons OK sits left of Cancel; alone, OK takes the right slot.
    // A third button takes the slot LEFT of OK, so the row reads
    // [alt] [ok] [cancel] with the dismissive answer last (T1390) — OK does not
    // move, which is why a two-button caller's layout is byte-identical.
    const ok_left = if (has_cancel) left_left else right_left;
    const alt_left = far_left;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .icon = if (has_icon) .{
            .left = margin,
            .top = icon_top,
            .right = margin + icon_px,
            .bottom = icon_top + icon_px,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .text = .{
            .left = margin + icon_span,
            .top = text_top,
            .right = margin + icon_span + text_w,
            .bottom = text_top + text_h,
        },
        .input = if (has_input) .{
            .left = margin + icon_span,
            .top = input_top,
            // The field spans to the trailing margin, not to the message's
            // measured width — it is an entry box, not a caption.
            .right = client_w - margin,
            .bottom = input_top + input_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .notes = if (notes_h > 0) .{
            // The accessory spans the full text column to the trailing margin,
            // like the check rows and the fine print: it is a region, not a
            // paragraph aligned with the message.
            .left = margin + icon_span,
            .top = notes_top,
            .right = client_w - margin,
            .bottom = notes_top + notes_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .checks = checks,
        .note = if (note_h > 0) .{
            .left = margin + icon_span,
            .top = note_top,
            // Fine print spans the text column to the trailing margin, like
            // the check rows above it.
            .right = client_w - margin,
            .bottom = note_top + note_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .ok = .{ .left = ok_left, .top = btn_top, .right = ok_left + btn_w, .bottom = btn_top + btn_h },
        .alt = if (with_alt) .{
            .left = alt_left,
            .top = btn_top,
            .right = alt_left + btn_w,
            .bottom = btn_top + btn_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .cancel = if (has_cancel) .{
            .left = right_left,
            .top = btn_top,
            .right = right_left + btn_w,
            .bottom = btn_top + btn_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .font_h = type_ramp.body(scale).height,
    };
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Button width for the given widest caption extent (physical pixels):
/// the standard 88-DIP button, widened with 12 DIP of padding per side
/// when the caption needs the room.
pub fn buttonWidth(scale: f32, max_label_w: i32) i32 {
    return @max(px(88, scale), max_label_w + px(24, scale));
}

/// Show the dialog modally and return the user's choice. `owner` is
/// disabled for the duration (input-modal to that window; the app loop
/// keeps effectively running because we pump here). `refocus`, when given,
/// receives deferred focus after the dialog closes (T48 pattern) — pass
/// the active terminal surface HWND, or null when the window is about to
/// be destroyed anyway (posted focus to a dead HWND is dropped by the OS).
pub fn show(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
) Result {
    return run(app, app.hinstance, owner, scale, refocus, opts, null);
}

/// The same dialog with NO App behind it — the startup-failure path (T1177),
/// which runs when `App.create` or the runtime's `init` failed and there is
/// therefore no app, no window and no message loop to borrow. The dialog only
/// ever needed the app for its window-class instance handle, so that is all
/// this asks for; `null` resolves the process instance, which is what every
/// other class registration in this app uses.
pub fn showStandalone(owner: ?w32.HWND, scale: f32, opts: Options) Result {
    const hinstance = w32.GetModuleHandleW(null);
    return run(null, hinstance, owner, scale, null, opts, null);
}

/// Show a dialog carrying a text field (`opts.input` MUST be set) and return
/// what the user left in it, UTF-8 in `buf`, or null when they cancelled —
/// the win32 counterpart to Mac's NSAlert-with-accessoryView prompts.
///
/// Whitespace and no-op handling belong to the caller (see
/// `chooser_menu.newName`): this returns the field verbatim.
pub fn prompt(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
    buf: []u8,
) ?[]const u8 {
    std.debug.assert(opts.input != null);
    var out: Output = .{ .buf = buf };
    if (run(app, app.hinstance, owner, scale, refocus, opts, &out) != .ok) return null;
    return buf[0..out.len];
}

/// Where `prompt` collects the field's text. Separate from `Result` so `show`
/// can pass null and stay allocation-free.
const Output = struct {
    buf: []u8,
    len: usize = 0,
};

fn run(
    app: ?*App,
    hinstance: ?w32.HINSTANCE,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
    out: ?*Output,
) Result {
    registerClass(hinstance) orelse return fallback(owner, opts);

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    const has_icon = opts.icon != .none;
    const has_cancel = opts.style == .ok_cancel;
    // A third button is only offered alongside a Cancel (see `layoutFor`).
    const has_alt = opts.alt_label != null and has_cancel;
    const has_input = opts.input != null;
    const has_note = opts.note != null;
    const n_checks: usize = @min(opts.checks.len, max_checks);
    // The accessory needs a theme and an allocator, both of which come from
    // the app; the app-less paths (startup failure, the standalone updater)
    // never carry notes, and asking for them there is a caller bug, not a
    // reason to fail the dialog.
    const notes_h: i32 = if (opts.notes != null and app != null)
        whats_new_layout.accessoryHeight(scale)
    else
        0;

    // DPI-scaled dialog font, needed up front to measure the text. It is the
    // ramp's body — the same source `layoutFor` reports as `font_h`, so the
    // font the message is MEASURED in cannot differ from the one it is drawn
    // in (T313).
    const font = w32.CreateFontW(
        -type_ramp.body(scale).height,
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
    defer if (font) |f| {
        _ = w32.DeleteObject(f);
    };

    // The note renders (and is measured) in the caption ramp role — fine
    // print, one step below the message's body text (T600).
    const note_font: ?*anyopaque = if (has_note) w32.CreateFontW(
        -type_ramp.caption(scale).height,
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
    ) else null;
    defer if (note_font) |f| {
        _ = w32.DeleteObject(f);
    };

    // Measure the text: wrap at a max width; DrawText shrinks the rect to
    // the widest actual line (or grows it for an unbreakable run, e.g. the
    // About box's executable path — then the dialog widens to fit).
    var text_rect: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = px(420, scale),
        .bottom = 0,
    };
    var label_w: i32 = 0;
    var note_h: i32 = 0;
    {
        const hdc = w32.GetDC(null) orelse return fallback(owner, opts);
        defer _ = w32.ReleaseDC(null, hdc);
        const prev = if (font) |f| w32.SelectObject(hdc, f) else null;
        defer if (prev) |p| {
            _ = w32.SelectObject(hdc, p);
        };
        _ = w32.DrawTextW(
            hdc,
            opts.text.ptr,
            @intCast(opts.text.len),
            &text_rect,
            w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
        );

        // Widest button caption, so custom labels never truncate. All three
        // buttons share one width, so the third one has to be measured too —
        // "Disconnect" is wider than either of the stock captions (T1390).
        var labels: [3][:0]const u16 = undefined;
        var n_labels: usize = 1;
        labels[0] = opts.ok_label;
        if (has_cancel) {
            labels[n_labels] = opts.cancel_label;
            n_labels += 1;
        }
        if (has_alt) {
            labels[n_labels] = opts.alt_label.?;
            n_labels += 1;
        }
        for (labels[0..n_labels]) |label| {
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                label.ptr,
                @intCast(label.len),
                &r,
                w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            label_w = @max(label_w, r.right - r.left);
        }

        // A checkbox row must fit its label plus the box glyph, so a long
        // agent name widens the dialog like a long message would.
        for (opts.checks[0..n_checks]) |check| {
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                check.label.ptr,
                @intCast(check.label.len),
                &r,
                w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            text_rect.right = @max(text_rect.right, text_rect.left + (r.right - r.left) + px(24, scale));
        }

        // The note is measured in its own (caption) font. Its widest line
        // widens the dialog like the message's would; its height feeds the
        // layout's note band. The layout rect can only end up wider than
        // measured here, which re-wraps to FEWER lines, never a clipped one.
        if (opts.note) |note_text| {
            const prev_note = if (note_font) |f| w32.SelectObject(hdc, f) else null;
            defer if (prev_note) |p| {
                _ = w32.SelectObject(hdc, p);
            };
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = px(420, scale), .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                note_text.ptr,
                @intCast(note_text.len),
                &r,
                w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
            );
            text_rect.right = @max(text_rect.right, text_rect.left + (r.right - r.left));
            note_h = r.bottom - r.top;
        }
    }
    const l = layoutFor(
        scale,
        text_rect.right - text_rect.left,
        text_rect.bottom - text_rect.top,
        has_icon,
        notes_h,
        n_checks,
        note_h,
        has_input,
        has_cancel,
        has_alt,
        buttonWidth(scale, label_w),
    );

    // Outer size from the desired client size, centered on the owner (or
    // the primary screen when there is no owner window).
    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;
    var center: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = w32.GetSystemMetrics(0), // SM_CXSCREEN
        .bottom = w32.GetSystemMetrics(1), // SM_CYSCREEN
    };
    if (owner) |o| _ = w32.GetWindowRect(o, &center);
    const x = center.left + @divTrunc((center.right - center.left) - outer_w, 2);
    const y = center.top + @divTrunc((center.bottom - center.top) - outer_h, 2);

    // The dialog lives entirely on this stack frame — show() does not
    // return until the nested loop finishes, so no allocation is needed.
    var self: ConfirmDialog = .{
        .app = app,
        .hwnd = undefined,
        .static = null,
        .ok_btn = undefined,
        .cancel_btn = null,
        .icon_handle = switch (opts.icon) {
            .none => null,
            .warning => w32.LoadIconW(null, w32.IDI_WARNING),
            .info => w32.LoadIconW(null, w32.IDI_INFORMATION),
        },
        .icon_rect = l.icon,
        // A prompt's Enter must commit what was typed, so a field forces the
        // Enter default onto OK regardless of the caller's MB_DEFBUTTON2
        // preference (which exists to protect destructive confirmations).
        // A third button that claims the Enter default takes it from BOTH the
        // other two, so the two flags can never disagree about who is default.
        .default_cancel = has_cancel and opts.default_cancel and !has_input and
            !(has_alt and opts.default_alt),
        .default_alt = has_alt and opts.default_alt and !has_input,
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        opts.title,
        style,
        x,
        y,
        outer_w,
        outer_h,
        owner,
        null,
        hinstance,
        null,
    ) orelse return fallback(owner, opts);
    self.hwnd = hwnd;

    // The caption follows the same surface the body does (T563).
    system_colors.applyPanelChrome(hwnd, self.pal());

    // Message text.
    self.static = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        opts.text.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_NOPREFIX,
        l.text.left,
        l.text.top,
        l.text.right - l.text.left,
        l.text.bottom - l.text.top,
        hwnd,
        null,
        hinstance,
        null,
    );

    // Optional checkbox rows (Mac's accessory checkboxes, T870).
    // BS_AUTOCHECKBOX toggles itself on click and Space, so no WM_COMMAND
    // handling is needed; the state is read back after the modal loop.
    for (opts.checks[0..n_checks], 0..) |check, i| {
        const r = l.checks[i];
        const btn = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            check.label.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_AUTOCHECKBOX,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            hwnd,
            @ptrFromInt(100 + i),
            hinstance,
            null,
        ) orelse continue;
        _ = w32.SetWindowTheme(btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
        _ = w32.SendMessageW(btn, w32.BM_SETCHECK, if (check.checked) w32.BST_CHECKED else 0, 0);
        // Indexed like opts.checks (a failed create leaves a null hole), so
        // the readback below can never write one row's state into another.
        self.check_btns[i] = btn;
    }
    self.n_checks = n_checks;

    // Optional secondary note (Mac's wrapping caption label, T600).
    if (opts.note) |note_text| {
        self.note_static = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            note_text.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_NOPREFIX,
            l.note.left,
            l.note.top,
            l.note.right - l.note.left,
            l.note.bottom - l.note.top,
            hwnd,
            null,
            hinstance,
            null,
        );
    }

    // Optional release-notes accessory (T625). A failed create is not fatal:
    // the confirmation still asks its question, which is the part that must
    // never be lost.
    if (notes_h > 0) {
        if (opts.notes) |n| {
            self.notes_view = WhatsNewNotesView.create(
                app.?.core_app.alloc,
                app,
                hinstance,
                hwnd,
                l.notes,
                scale,
                n.split,
            );
            if (self.notes_view == null) {
                log.warn("confirm dialog: the release-notes accessory could not be created", .{});
            }
        }
    }

    // Optional text field (Mac's accessoryView).
    if (opts.input) |initial| {
        self.edit = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
            initial.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
            l.input.left,
            l.input.top,
            l.input.right - l.input.left,
            l.input.bottom - l.input.top,
            hwnd,
            null,
            hinstance,
            null,
        );
        if (self.edit) |e| {
            _ = w32.SetWindowTheme(e, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
        }
    }

    self.ok_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        opts.ok_label.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
            (if (self.default_cancel or self.default_alt) 0 else w32.BS_DEFPUSHBUTTON),
        l.ok.left,
        l.ok.top,
        l.ok.right - l.ok.left,
        l.ok.bottom - l.ok.top,
        hwnd,
        @ptrFromInt(@as(usize, @intCast(w32.IDOK))),
        hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        return fallback(owner, opts);
    };
    _ = w32.SetWindowTheme(self.ok_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

    if (has_cancel) {
        const cancel_btn = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            opts.cancel_label.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
                (if (self.default_cancel) w32.BS_DEFPUSHBUTTON else 0),
            l.cancel.left,
            l.cancel.top,
            l.cancel.right - l.cancel.left,
            l.cancel.bottom - l.cancel.top,
            hwnd,
            @ptrFromInt(@as(usize, @intCast(w32.IDCANCEL))),
            hinstance,
            null,
        ) orelse {
            _ = w32.DestroyWindow(hwnd);
            return fallback(owner, opts);
        };
        _ = w32.SetWindowTheme(cancel_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
        self.cancel_btn = cancel_btn;
    }

    // The optional third button (T1390). A failed create is NOT fatal the way
    // a missing OK is: the dialog still answers Close/Cancel, which is exactly
    // what it did before this button existed.
    if (has_alt) {
        if (w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            opts.alt_label.?.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
                (if (self.default_alt) w32.BS_DEFPUSHBUTTON else 0),
            l.alt.left,
            l.alt.top,
            l.alt.right - l.alt.left,
            l.alt.bottom - l.alt.top,
            hwnd,
            @ptrFromInt(@as(usize, ID_ALT)),
            hinstance,
            null,
        )) |alt_btn| {
            _ = w32.SetWindowTheme(alt_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
            self.alt_btn = alt_btn;
        } else {
            // Nothing can answer `.alt` any more, so the Enter default must go
            // back to a button that exists — the same one a caller who never
            // asked for a third button would have got.
            self.default_alt = false;
            self.default_cancel = has_cancel and opts.default_cancel and !has_input;
        }
    }

    if (note_font) |f| {
        if (self.note_static) |s| _ = w32.SendMessageW(s, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    if (font) |f| {
        if (self.static) |s| _ = w32.SendMessageW(s, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.edit) |e| _ = w32.SendMessageW(e, w32.WM_SETFONT, @intFromPtr(f), 1);
        for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
            _ = w32.SendMessageW(b, w32.WM_SETFONT, @intFromPtr(f), 1);
        };
        _ = w32.SendMessageW(self.ok_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.cancel_btn) |c| _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.alt_btn) |a| _ = w32.SendMessageW(a, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&self)));

    // Input-modal to the owner until the dialog closes.
    if (owner) |o| _ = w32.EnableWindow(o, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    if (self.edit) |e| {
        // The field takes focus with its seed text selected, so typing
        // replaces the old name (RenameDialog's behavior).
        _ = w32.SetFocus(e);
        _ = w32.SendMessageW(e, 0x00B1, 0, -1); // EM_SETSEL(0, -1)
    } else {
        _ = w32.SetFocus(self.defaultButton());
    }

    self.runModal();

    // Read the field and checkbox states BEFORE the window is destroyed.
    if (out) |o| if (self.edit) |e| {
        if (self.result == .ok) o.len = readEdit(e, o.buf);
    };
    if (self.result == .ok) {
        for (opts.checks[0..self.n_checks], 0..) |*check, i| {
            if (self.check_btns[i]) |b| {
                check.checked =
                    w32.SendMessageW(b, w32.BM_GETCHECK, 0, 0) == @as(isize, @intCast(w32.BST_CHECKED));
            }
        }
    }

    // Teardown. The accessory goes first: it is a child of this window, and
    // its own destroy path clears the back-pointer its WndProc reads.
    if (self.notes_view) |v| {
        v.destroy();
        self.notes_view = null;
    }
    // The owner MUST be re-enabled before the dialog is destroyed, otherwise
    // Windows may activate another app's window.
    if (owner) |o| _ = w32.EnableWindow(o, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(hwnd);
    if (owner) |o| _ = w32.SetForegroundWindow(o);
    if (refocus) |h| App.deferSetFocus(h); // T48

    return self.result;
}

/// Copy the edit control's text into `buf` as UTF-8, returning its length
/// (0 when it does not fit — a truncated device name is worse than none).
///
/// T990: `std.unicode.utf16LeToUtf8` never checked `buf`, so "does not fit"
/// was a panic rather than the 0 this comment promised. `toUtf8AllOrNothing`
/// is that promise, kept.
fn readEdit(edit: w32.HWND, buf: []u8) usize {
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, wbuf.len));
    return utf16_text.toUtf8AllOrNothing(buf, wbuf[0..wlen]);
}

/// Last-resort fallback when dialog construction fails: the old (light)
/// MessageBoxW, so a prompt is never silently skipped.
fn fallback(owner: ?w32.HWND, opts: Options) Result {
    // A three-answer confirmation has no OK/Cancel shape, so the system box
    // borrows Yes/No/Cancel: Yes is the third button, No is OK. MessageBoxW
    // cannot be relabeled, so the captions are lost — acceptable only because
    // this path is reached when the dialog CLASS failed to register, i.e. a
    // degraded box beats no box. Answering it can never be worse than the
    // dismissive default, which Cancel still is.
    const alt = if (opts.style == .ok_cancel) opts.alt_label else null;
    var flags: u32 = if (alt != null) w32.MB_YESNOCANCEL else switch (opts.style) {
        .ok_only => w32.MB_OK,
        .ok_cancel => w32.MB_OKCANCEL,
    };
    flags |= switch (opts.icon) {
        .none => 0,
        .warning => w32.MB_ICONWARNING,
        .info => w32.MB_ICONINFORMATION,
    };
    if (alt != null) {
        // Yes(1) is the third button, No(2) is OK, Cancel(3) is Cancel — so an
        // alt-default box needs no override and the other two name their slot.
        if (!opts.default_alt) flags |= if (opts.default_cancel) w32.MB_DEFBUTTON3 else w32.MB_DEFBUTTON2;
    } else if (opts.style == .ok_cancel and opts.default_cancel) {
        flags |= w32.MB_DEFBUTTON2;
    }
    // The note is a disclosure, not decoration (T600) — a fallback that
    // dropped it would show a consent prompt missing its fine print, so it
    // rides along as a trailing paragraph (or the message ships alone when
    // the combined text cannot fit the stack buffer).
    var buf: [1024:0]u16 = undefined;
    const text_ptr: [*:0]const u16 = blk: {
        const note = opts.note orelse break :blk opts.text.ptr;
        const total = opts.text.len + 2 + note.len;
        if (total > buf.len) break :blk opts.text.ptr;
        @memcpy(buf[0..opts.text.len], opts.text);
        buf[opts.text.len] = '\n';
        buf[opts.text.len + 1] = '\n';
        @memcpy(buf[opts.text.len + 2 ..][0..note.len], note);
        buf[total] = 0;
        break :blk @ptrCast(&buf);
    };
    const r = w32.MessageBoxW(owner, text_ptr, opts.title, flags);
    if (alt != null) {
        if (r == w32.IDYES) return .alt;
        return if (r == w32.IDNO) .ok else .cancel;
    }
    return if (opts.style == .ok_only or r == w32.IDOK) .ok else .cancel;
}

/// Nested modal message pump — the same shape MessageBoxW runs internally.
/// Replicates the App.run top-of-loop specials that matter while modal:
/// WM_APP_SETFOCUS (T48 deferred focus) is performed here, never
/// dispatched. Everything else (renderer wakeups, IPC — both handled in
/// window procs) flows through Translate/Dispatch as usual.
fn runModal(self: *ConfirmDialog) void {
    var msg: w32.MSG = undefined;
    while (!self.done) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT: repost for the outer App.run loop and bail out
            // without approving anything.
            w32.PostQuitMessage(@intCast(msg.wParam));
            self.result = .cancel;
            return;
        }
        if (result < 0) {
            self.result = .cancel;
            return;
        }
        if (msg.message == App.WM_APP_SETFOCUS) {
            if (msg.hwnd) |h| App.performDeferredFocus(h);
            continue;
        }
        // The wheel goes to the FOCUSED window, which in this dialog is a
        // button — and a BUTTON does not forward it to its parent. So the
        // notes accessory would never see a scroll it plainly invites, unless
        // the loop that owns the dialog routes by POINTER instead, which is
        // what every scrolling region on Windows behaves like anyway.
        if (msg.message == w32.WM_MOUSEWHEEL) {
            if (self.notes_view) |v| {
                const pt: w32.POINT = .{
                    .x = @as(i16, @bitCast(@as(u16, @intCast(msg.lParam & 0xFFFF)))),
                    .y = @as(i16, @bitCast(@as(u16, @intCast((msg.lParam >> 16) & 0xFFFF)))),
                };
                var rc: w32.RECT = undefined;
                if (w32.GetWindowRect(v.hwnd, &rc) != 0 and
                    pt.x >= rc.left and pt.x < rc.right and
                    pt.y >= rc.top and pt.y < rc.bottom)
                {
                    _ = w32.SendMessageW(v.hwnd, msg.message, msg.wParam, msg.lParam);
                    continue;
                }
            }
        }
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null and self.ownsHwnd(msg.hwnd.?)) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);
            if (self.handleKey(vk)) continue;
        }
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

/// What Enter answers when focus is not on a button. Pure, and the one place
/// the two default flags are resolved into an answer.
pub fn defaultResultFor(default_alt: bool, default_cancel: bool) Result {
    if (default_alt) return .alt;
    if (default_cancel) return .cancel;
    return .ok;
}

fn defaultResult(self: *const ConfirmDialog) Result {
    return defaultResultFor(self.default_alt and self.alt_btn != null, self.default_cancel);
}

fn defaultButton(self: *const ConfirmDialog) w32.HWND {
    // The third button wins when it asked for the default (T1390): the
    // remote-close confirmation defaults to Disconnect, the answer that
    // destroys nothing.
    if (self.default_alt) {
        if (self.alt_btn) |a| return a;
    }
    if (self.default_cancel) {
        if (self.cancel_btn) |c| return c;
    }
    return self.ok_btn;
}

/// The dialog's own owner-drawn content, into whichever DC it is handed — the
/// paint cycle's own, or a caller's under WM_PRINTCLIENT (T940).
fn paintInto(self: *const ConfirmDialog, hdc: w32.HDC) void {
    if (self.icon_handle) |icon| {
        _ = w32.DrawIconEx(
            hdc,
            self.icon_rect.left,
            self.icon_rect.top,
            icon,
            self.icon_rect.right - self.icon_rect.left,
            self.icon_rect.bottom - self.icon_rect.top,
            0,
            null,
            w32.DI_NORMAL,
        );
    }
}

fn ownsHwnd(self: *const ConfirmDialog, hwnd: w32.HWND) bool {
    if (hwnd == self.hwnd or hwnd == self.ok_btn) return true;
    if (self.static) |s| if (hwnd == s) return true;
    if (self.note_static) |s| if (hwnd == s) return true;
    if (self.cancel_btn) |c| if (hwnd == c) return true;
    if (self.alt_btn) |a| if (hwnd == a) return true;
    if (self.edit) |e| if (hwnd == e) return true;
    for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
        if (hwnd == b) return true;
    };
    return false;
}

/// Tab order: field (when present) → OK → Cancel → wrap. Pure — unit-tested
/// through `nextFocusIndex`, which is the same cycle over stop indices.
pub fn nextFocusIndex(cur: usize, stops: usize, backwards: bool) usize {
    if (stops == 0) return 0;
    if (backwards) return (cur + stops - 1) % stops;
    return (cur + 1) % stops;
}

fn finish(self: *ConfirmDialog, result: Result) void {
    self.result = result;
    self.done = true;
}

/// Handle a dialog key from the nested pump. Returns true when consumed.
fn handleKey(self: *ConfirmDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            // MB_OK parity: Escape dismisses an OK-only box as "ok".
            self.finish(if (self.cancel_btn == null) .ok else .cancel);
            return true;
        },
        w32.VK_RETURN => {
            // Enter activates the focused button, else the default —
            // standard dialog convention (MB_DEFBUTTON2 preserved). Enter in
            // the text field commits, like any prompt.
            const focus = w32.GetFocus();
            if (self.cancel_btn != null and focus == self.cancel_btn) {
                self.finish(.cancel);
            } else if (self.alt_btn != null and focus == self.alt_btn) {
                self.finish(.alt);
            } else if (focus == @as(?w32.HWND, self.ok_btn)) {
                self.finish(.ok);
            } else {
                self.finish(self.defaultResult());
            }
            return true;
        },
        w32.VK_TAB => {
            // Focus stops in order: checkboxes (top-down), field (when
            // present), then the button row LEFT TO RIGHT as it is painted —
            // the third button, OK, Cancel (T1390).
            var stops: [4 + max_checks]w32.HWND = undefined;
            var n: usize = 0;
            for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
                stops[n] = b;
                n += 1;
            };
            if (self.edit) |e| {
                stops[n] = e;
                n += 1;
            }
            if (self.alt_btn) |a| {
                stops[n] = a;
                n += 1;
            }
            stops[n] = self.ok_btn;
            n += 1;
            if (self.cancel_btn) |c| {
                stops[n] = c;
                n += 1;
            }
            if (n < 2) return true;

            const focus = w32.GetFocus();
            var cur: usize = 0;
            for (stops[0..n], 0..) |h, i| {
                if (focus == @as(?w32.HWND, h)) cur = i;
            }
            const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            _ = w32.SetFocus(stops[nextFocusIndex(cur, n, backwards)]);
            return true;
        },
        else => return false,
    }
}

fn registerClass(hinstance: ?w32.HINSTANCE) ?void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &dialogWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        // Null, erased from the live palette in `WM_ERASEBKGND` instead
        // (T563) - a class brush is captured once per process, so it cannot
        // follow a theme flip.
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("confirm dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *ConfirmDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (notification == w32.BN_CLICKED) {
                switch (control_id) {
                    @as(u16, @intCast(w32.IDOK)) => {
                        self.finish(.ok);
                        return 0;
                    },
                    @as(u16, @intCast(w32.IDCANCEL)) => {
                        self.finish(.cancel);
                        return 0;
                    },
                    ID_ALT => {
                        self.finish(.alt);
                        return 0;
                    },
                    else => {},
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            // ✕ dismisses: cancel for confirms, ok for OK-only boxes.
            self.finish(if (self.cancel_btn == null) .ok else .cancel);
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paintInto(hdc);
            return 0;
        },
        // The same icon into a caller's DC, so a pixel probe can photograph
        // this dialog synchronously instead of through DWM's asynchronous copy
        // of the composited surface, which tears (T835/T940). The dialog's
        // TEXT is in child statics, which DefWindowProc's WM_PRINT handling
        // prints for us; only the owner-drawn icon comes from here.
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paintInto(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_ACTIVATE => {
            // Restore focus to the default button when reactivated (e.g.
            // after alt-tabbing away) and no child holds it.
            const state: u16 = @intCast(wparam & 0xFFFF);
            if (state != w32.WA_INACTIVE) {
                const focus = w32.GetFocus();
                const owned = focus != null and self.ownsHwnd(focus.?);
                if (!owned) _ = w32.SetFocus(self.edit orelse self.defaultButton());
            }
            return 0;
        },
        // The class carries no background brush (it would be frozen at
        // registration time), so the dialog surface is erased here from the
        // live palette instead.
        w32.WM_ERASEBKGND => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            var er: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &er) == 0) return 0;
            if (bg_brush.get(system_colors.cr(self.pal().bg))) |b| _ = w32.FillRect(hdc, &er, b);
            return 1;
        },
        // A light/dark flip or an accent change reaches TOP-LEVEL windows, and
        // this dialog is one. Repaint it AND its children: a control colors
        // itself from a `WM_CTLCOLOR*` reply, which is only sent when it
        // repaints (T307).
        w32.WM_SETTINGCHANGE, w32.WM_DWMCOLORIZATIONCOLORCHANGED => {
            if (msg != w32.WM_SETTINGCHANGE or system_colors.isColorSettingChange(lparam)) {
                system_colors.repaintForColorChange(hwnd);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The prompt field is a field, not dialog surface — without this it
        // renders as a white box in an otherwise dark dialog.
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            _ = w32.SetTextColor(hdc, system_colors.cr(p.text));
            _ = w32.SetBkColor(hdc, system_colors.cr(p.field));
            if (field_brush.get(system_colors.cr(p.field))) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            // lparam names the control: the note reads in the secondary
            // ramp, everything else in the message color.
            const ctl: ?w32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const color = if (self.note_static != null and ctl == self.note_static)
                p.secondary
            else
                p.text;
            _ = w32.SetTextColor(hdc, system_colors.cr(color));
            _ = w32.SetBkColor(hdc, system_colors.cr(p.bg));
            if (bg_brush.get(system_colors.cr(p.bg))) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------
// Tests (pure logic only — run in both test lanes)
// ---------------------------------------------------------------------

const testing = std.testing;

test "layoutFor: controls nest inside the client area at 1.0 scale" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.client_w > 0 and l.client_h > 0);
    for ([_]w32.RECT{ l.icon, l.text, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: buttons right-aligned, OK left of Cancel, no overlap" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expectEqual(l.ok.top, l.cancel.top);
    try testing.expectEqual(l.cancel.right, l.client_w - 16);
}

test "layoutFor: ok-only puts OK in the rightmost slot, no cancel rect" {
    const l = layoutFor(1.0, 300, 40, false, 0, 0, 0, false, false, false, 88);
    try testing.expectEqual(l.ok.right, l.client_w - 16);
    try testing.expectEqual(@as(i32, 0), l.cancel.right - l.cancel.left);
    try testing.expectEqual(@as(i32, 0), l.icon.right - l.icon.left);
}

test "layoutFor: text starts right of the icon with a gap" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.text.left >= l.icon.right + 12);
    // Without an icon the text hugs the margin.
    const l2 = layoutFor(1.0, 300, 40, false, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 16), l2.text.left);
}

test "layoutFor: short text is vertically centered against the icon" {
    const l = layoutFor(1.0, 300, 16, true, 0, 0, 0, false, true, false, 88);
    // Icon (32px) taller than text (16px): text drops to center.
    try testing.expect(l.text.top > l.icon.top);
    try testing.expectEqual(l.icon.top, 16);
    // Text (60px) taller than icon: icon centers instead.
    const l2 = layoutFor(1.0, 300, 60, true, 0, 0, 0, false, true, false, 88);
    try testing.expect(l2.icon.top > l2.text.top);
}

test "layoutFor: narrow text still fits the button row" {
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, false, true, false, 88);
    // Two 88px buttons + 8px gap + 2*16 margins = 216, floored at 280.
    try testing.expect(l.client_w >= 280);
    try testing.expect(l.ok.left >= 16);
}

test "layoutFor: scales with DPI" {
    const l1 = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    const l2 = layoutFor(2.0, 600, 80, true, 0, 0, 0, false, true, false, 176);
    try testing.expectEqual(l1.client_w * 2, l2.client_w);
    try testing.expectEqual(l1.client_h * 2, l2.client_h);
    try testing.expectEqual(l1.ok.left * 2, l2.ok.left);
    try testing.expectEqual(l1.font_h * 2, l2.font_h);
}

test "buttonWidth: standard until the caption outgrows it, then padded" {
    // "OK"/"Cancel"-sized captions keep the 88-DIP standard width.
    try testing.expectEqual(@as(i32, 88), buttonWidth(1.0, 40));
    try testing.expectEqual(@as(i32, 176), buttonWidth(2.0, 80));
    // A wide caption ("Open Config") gets 12 DIP padding per side.
    try testing.expectEqual(@as(i32, 124), buttonWidth(1.0, 100));
}

test "layoutFor: a third button sits LEFT of OK, Cancel stays last" {
    // The remote-close confirmation's row (T1390): [Disconnect] [Close]
    // [Cancel], right-aligned, with the dismissive answer in the trailing slot
    // this dialog has always put it in.
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, true, 88);
    try testing.expect(l.alt.right <= l.ok.left);
    try testing.expect(l.ok.right <= l.cancel.left);
    // All three share the row and the width.
    try testing.expectEqual(l.ok.top, l.alt.top);
    try testing.expectEqual(l.ok.bottom, l.alt.bottom);
    try testing.expectEqual(l.ok.right - l.ok.left, l.alt.right - l.alt.left);
}

test "layoutFor: a third button does not move OK or Cancel" {
    // A two-button caller's layout must be byte-identical, so adding the
    // button cannot regress every other confirmation in the app.
    const two = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    const three = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, true, 88);
    try testing.expectEqual(two.ok.left, three.ok.left);
    try testing.expectEqual(two.cancel.left, three.cancel.left);
    try testing.expectEqual(two.client_h, three.client_h);
}

test "layoutFor: a narrow dialog widens to fit three buttons" {
    // Three 88px buttons + two 8px gaps + 2*16 margins = 312 > the 280 floor.
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, false, true, true, 88);
    try testing.expect(l.alt.left >= 16);
    try testing.expectEqual(@as(i32, 312), l.client_w);
}

test "layoutFor: a third button without a Cancel is ignored" {
    // Two ways to say yes and no way to say no is not a choice, so the third
    // button is only ever offered alongside a Cancel.
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, false, true, 88);
    try testing.expectEqual(@as(i32, 0), l.alt.right - l.alt.left);
}

test "defaultResultFor: the third button outranks OK and Cancel" {
    // The remote close defaults to Disconnect - the answer that destroys
    // nothing - so Enter on an untouched dialog must not end a remote process.
    try testing.expectEqual(Result.alt, defaultResultFor(true, true));
    try testing.expectEqual(Result.alt, defaultResultFor(true, false));
    try testing.expectEqual(Result.cancel, defaultResultFor(false, true));
    try testing.expectEqual(Result.ok, defaultResultFor(false, false));
}

test "layoutFor: wide buttons widen the row and never overlap" {
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, false, true, false, 124);
    try testing.expectEqual(@as(i32, 124), l.ok.right - l.ok.left);
    try testing.expectEqual(@as(i32, 124), l.cancel.right - l.cancel.left);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expect(l.ok.left >= 16);
    // Client floor still respected: 2*124 + 8 + 2*16 = 288 > 280.
    try testing.expectEqual(@as(i32, 288), l.client_w);
}

// --- Prompt field (T176) -----------------------------------------------

test "layoutFor: no input means no input rect and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 0), plain.input.right - plain.input.left);
    try testing.expectEqual(@as(i32, 0), plain.input.bottom - plain.input.top);
}

test "layoutFor: the field sits between the message and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, true, true, false, 88);
    try testing.expect(l.input.top >= l.text.bottom);
    try testing.expect(l.input.top >= l.icon.bottom - 1);
    try testing.expect(l.ok.top >= l.input.bottom);
    try testing.expect(l.cancel.top >= l.input.bottom);
    // Aligned with the message column, running to the trailing margin.
    try testing.expectEqual(l.text.left, l.input.left);
    try testing.expectEqual(l.client_w - 16, l.input.right);
    // And it nests, like everything else.
    for ([_]w32.RECT{ l.icon, l.text, l.input, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: the field's row is what makes a prompt taller" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    const with = layoutFor(1.0, 300, 40, true, 0, 0, 0, true, true, false, 88);
    // 12 gap + 26 field.
    try testing.expectEqual(plain.client_h + 38, with.client_h);
    // The message band above it does not move.
    try testing.expectEqual(plain.text.top, with.text.top);
    try testing.expectEqual(plain.icon.top, with.icon.top);
}

test "layoutFor: a prompt is never too narrow to type in" {
    // A two-word message would otherwise leave a 280-wide dialog whose field
    // is barely wider than the button row.
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, true, true, false, 88);
    try testing.expect(l.client_w >= 380);
    try testing.expect(l.input.right - l.input.left >= 340);
}

test "layoutFor: the field scales with DPI like everything else" {
    const a = layoutFor(1.0, 300, 40, true, 0, 0, 0, true, true, false, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, 0, 0, true, true, false, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.input.top * 2, b.input.top);
    try testing.expectEqual((a.input.bottom - a.input.top) * 2, b.input.bottom - b.input.top);
}

// --- Checkbox rows (T870) ----------------------------------------------

test "layoutFor: no checks means no check rects and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    for (plain.checks) |r| {
        try testing.expectEqual(@as(i32, 0), r.right - r.left);
        try testing.expectEqual(@as(i32, 0), r.bottom - r.top);
    }
}

test "layoutFor: check rows sit between the message and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, 2, 0, false, true, false, 88);
    try testing.expect(l.checks[0].top >= l.text.bottom);
    try testing.expect(l.checks[1].top >= l.checks[0].bottom);
    try testing.expect(l.ok.top >= l.checks[1].bottom);
    // Aligned with the message column, running to the trailing margin.
    try testing.expectEqual(l.text.left, l.checks[0].left);
    try testing.expectEqual(l.client_w - 16, l.checks[0].right);
    // Unused rows stay empty.
    try testing.expectEqual(@as(i32, 0), l.checks[2].right - l.checks[2].left);
    // And everything nests.
    for ([_]w32.RECT{ l.icon, l.text, l.checks[0], l.checks[1], l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: each check row adds its height, the block adds one gap" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    const one = layoutFor(1.0, 300, 40, true, 0, 1, 0, false, true, false, 88);
    const two = layoutFor(1.0, 300, 40, true, 0, 2, 0, false, true, false, 88);
    // 12 gap + 20 row.
    try testing.expectEqual(plain.client_h + 32, one.client_h);
    // +4 row gap + 20 row.
    try testing.expectEqual(one.client_h + 24, two.client_h);
    // The message band above does not move.
    try testing.expectEqual(plain.text.top, two.text.top);
}

test "layoutFor: checks stack above the input field when both are present" {
    const l = layoutFor(1.0, 300, 40, true, 0, 2, 0, true, true, false, 88);
    try testing.expect(l.input.top >= l.checks[1].bottom);
    try testing.expect(l.ok.top >= l.input.bottom);
}

test "layoutFor: check rows scale with DPI" {
    const a = layoutFor(1.0, 300, 40, true, 0, 2, 0, false, true, false, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, 2, 0, false, true, false, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.checks[0].top * 2, b.checks[0].top);
    try testing.expectEqual((a.checks[1].bottom - a.checks[1].top) * 2, b.checks[1].bottom - b.checks[1].top);
}

// --- Secondary note (T600) ---------------------------------------------

test "layoutFor: no note means no note rect and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 0), plain.note.right - plain.note.left);
    try testing.expectEqual(@as(i32, 0), plain.note.bottom - plain.note.top);
}

test "layoutFor: the note sits between the checks and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, 2, 32, false, true, false, 88);
    try testing.expect(l.note.top >= l.checks[1].bottom);
    try testing.expect(l.ok.top >= l.note.bottom);
    // Aligned with the message column, running to the trailing margin like
    // the check rows.
    try testing.expectEqual(l.text.left, l.note.left);
    try testing.expectEqual(l.client_w - 16, l.note.right);
    // And it nests.
    try testing.expect(l.note.bottom <= l.client_h);
}

test "layoutFor: the note band is what makes a disclosing dialog taller" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 2, 0, false, true, false, 88);
    const with = layoutFor(1.0, 300, 40, true, 0, 2, 32, false, true, false, 88);
    // 12 gap + the measured 32.
    try testing.expectEqual(plain.client_h + 44, with.client_h);
    // Nothing above it moves.
    try testing.expectEqual(plain.text.top, with.text.top);
    try testing.expectEqual(plain.checks[1].top, with.checks[1].top);
}

test "layoutFor: the note stacks above the input field when both are present" {
    const l = layoutFor(1.0, 300, 40, true, 0, 1, 28, true, true, false, 88);
    try testing.expect(l.note.top >= l.checks[0].bottom);
    try testing.expect(l.input.top >= l.note.bottom);
    try testing.expect(l.ok.top >= l.input.bottom);
}

test "layoutFor: the note scales with DPI" {
    const a = layoutFor(1.0, 300, 40, true, 0, 2, 30, false, true, false, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, 2, 60, false, true, false, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.note.top * 2, b.note.top);
    try testing.expectEqual((a.note.bottom - a.note.top) * 2, b.note.bottom - b.note.top);
}

test "layoutFor: no notes means no notes rect and a byte-identical layout (T625)" {
    // The accessory is opt-in, and every dialog that never asks for one must
    // lay out exactly as it did before the band existed.
    const plain = layoutFor(1.0, 300, 40, true, 0, 2, 32, true, true, false, 88);
    try testing.expectEqual(@as(i32, 0), plain.notes.right - plain.notes.left);
    try testing.expectEqual(@as(i32, 0), plain.notes.bottom - plain.notes.top);
    try testing.expectEqual(@as(i32, 0), plain.notes.top);
}

test "layoutFor: the notes band sits between the message and the buttons (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    const l = layoutFor(1.0, 300, 40, true, h, 0, 0, false, true, false, 88);
    try testing.expect(l.notes.top >= l.text.bottom);
    try testing.expect(l.ok.top >= l.notes.bottom);
    // It spans the text column to the trailing margin, like the check rows
    // and the fine print — it is a region, not a paragraph.
    try testing.expectEqual(l.text.left, l.notes.left);
    try testing.expectEqual(l.client_w - 16, l.notes.right);
    try testing.expectEqual(h, l.notes.bottom - l.notes.top);
    try testing.expect(l.notes.bottom <= l.client_h);
}

test "layoutFor: the notes band is what makes the update dialog taller (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88);
    const with = layoutFor(1.0, 300, 40, true, h, 0, 0, false, true, false, 88);
    // 12 gap + the fixed band.
    try testing.expectEqual(plain.client_h + 12 + h, with.client_h);
    // Nothing above it moves.
    try testing.expectEqual(plain.text.top, with.text.top);
    try testing.expectEqual(plain.icon.top, with.icon.top);
}

test "layoutFor: the notes band pushes the checks, note and field down (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    const l = layoutFor(1.0, 300, 40, true, h, 2, 28, true, true, false, 88);
    try testing.expect(l.checks[0].top >= l.notes.bottom);
    try testing.expect(l.note.top >= l.checks[1].bottom);
    try testing.expect(l.input.top >= l.note.bottom);
    try testing.expect(l.ok.top >= l.input.bottom);
}

test "layoutFor: notes get a width floor wide enough for prose (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    // A two-word message would otherwise leave the notes a column of single
    // words: the accessory takes the widest of the three floors.
    const l = layoutFor(1.0, 60, 20, true, h, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 460), l.client_w);
    // 460 client, less the margins and the warning icon's column: prose
    // width, not a two-word gutter.
    try testing.expectEqual(@as(i32, 384), l.notes.right - l.notes.left);
}

test "layoutFor: the notes band scales with DPI (T625)" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const h = whats_new_layout.accessoryHeight(scale);
        const l = layoutFor(scale, @intFromFloat(300 * scale), @intFromFloat(40 * scale), true, h, 0, 0, false, true, false, @intFromFloat(88 * scale));
        // The band is the DPI-scaled height, seated below the message and
        // clear of the buttons at every scale the app runs at.
        try testing.expectEqual(h, l.notes.bottom - l.notes.top);
        try testing.expect(l.notes.top >= l.text.bottom);
        try testing.expect(l.ok.top >= l.notes.bottom);
        try testing.expect(l.notes.bottom <= l.client_h);
        try testing.expect(l.notes.right <= l.client_w);
        // And the whole dialog grew by the band plus its gap, never by less.
        const plain = layoutFor(scale, @intFromFloat(300 * scale), @intFromFloat(40 * scale), true, 0, 0, 0, false, true, false, @intFromFloat(88 * scale));
        // And the dialog grew by exactly the band plus the gap above it —
        // the message is the taller half of the content band here, so that
        // gap is readable straight off the two rects.
        try testing.expectEqual(
            plain.client_h + (l.notes.top - l.text.bottom) + h,
            l.client_h,
        );
    }
}

test "layoutFor: a check count beyond capacity is clamped, not overflowed" {
    const l = layoutFor(1.0, 300, 40, true, 0, max_checks + 3, 0, false, true, false, 88);
    const capped = layoutFor(1.0, 300, 40, true, 0, max_checks, 0, false, true, false, 88);
    try testing.expectEqual(capped.client_h, l.client_h);
}

test "nextFocusIndex: cycles both ways and wraps" {
    // field -> OK -> Cancel -> field
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 3, false));
    try testing.expectEqual(@as(usize, 2), nextFocusIndex(1, 3, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(2, 3, false));
    try testing.expectEqual(@as(usize, 2), nextFocusIndex(0, 3, true));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(1, 3, true));
    // Two stops (no field) is the old OK <-> Cancel toggle.
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 2, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(1, 2, false));
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 2, true));
    // Degenerate cases never index out of range.
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(0, 1, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(0, 0, false));
}

test "layoutFor: the font comes from the ramp (T313)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layoutFor(scale, 300, 40, true, 0, 0, 0, false, true, false, 88);
        try testing.expectEqual(type_ramp.body(scale).height, l.font_h);
        // A confirm's message is body text, never a subtitle and never a
        // caption — one role, so it reads at the same size as the chooser it
        // is often opened over.
        try testing.expect(l.font_h > type_ramp.caption(scale).height);
        try testing.expect(l.font_h < type_ramp.subtitle(scale).height);
    }
    try testing.expectEqual(@as(i32, 14), layoutFor(1.0, 300, 40, true, 0, 0, 0, false, true, false, 88).font_h);
}
