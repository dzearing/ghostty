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

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyConfirmDialog");

pub const Result = enum { ok, cancel };
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
};

pub const Check = struct {
    label: [:0]const u16,
    checked: bool = true,
};

/// Checkbox row capacity (two agent runtimes today; room to grow).
pub const max_checks = 4;

/// Dialog colors — the RenameDialog dark palette (matches the command
/// palette and the tab bar's dark styling).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_TEXT = w32.RGB(230, 230, 230);
/// The prompt field's fill — the same field color the chooser and the rename
/// dialog use, one notch darker than the dialog surface.
const COLOR_FIELD_BG = w32.RGB(30, 30, 30);

/// Class-lifetime brushes, created at class registration and never freed
/// (they live for the process, like the other dialog classes).
var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var field_brush: ?w32.HBRUSH = null;

hwnd: w32.HWND,
static: ?w32.HWND,
ok_btn: w32.HWND,
cancel_btn: ?w32.HWND,
/// The optional text field (`Options.input`), read back by `prompt`.
edit: ?w32.HWND = null,
/// The optional checkbox rows (`Options.checks`), read back on OK.
check_btns: [max_checks]?w32.HWND = @splat(null),
n_checks: usize = 0,
icon_handle: ?w32.HICON,
icon_rect: w32.RECT,
default_cancel: bool,
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
    /// The optional checkbox rows (only the first `n_checks` passed to
    /// `layoutFor` are meaningful; the rest stay empty).
    checks: [max_checks]w32.RECT,
    ok: w32.RECT,
    cancel: w32.RECT,
    font_h: i32,
};

/// `btn_w` is the physical-pixel button width — at least the standard
/// 88 DIP, wider when a caption needs the room (see buttonWidth).
/// `has_input` adds a single-line field row under the message (T176);
/// `n_checks` adds that many checkbox rows between the message and the
/// field/buttons (T870).
pub fn layoutFor(
    scale: f32,
    text_w: i32,
    text_h: i32,
    has_icon: bool,
    n_checks: usize,
    has_input: bool,
    has_cancel: bool,
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

    const icon_span: i32 = if (has_icon) icon_px + icon_gap else 0;
    const n_btns: i32 = if (has_cancel) 2 else 1;
    const btns_w = n_btns * btn_w + (n_btns - 1) * btn_gap_h;

    var client_w = margin + icon_span + text_w + margin;
    // Never narrower than the button row (or a sane floor). A prompt gets a
    // wider floor: a field the width of a two-word message is unusable.
    client_w = @max(client_w, margin + btns_w + margin);
    client_w = @max(client_w, px(if (has_input) 380 else 280, scale));

    const content_h = @max(text_h, if (has_icon) icon_px else 0);
    const nc: i32 = @intCast(@min(n_checks, max_checks));
    const checks_span: i32 = if (nc > 0)
        check_gap + nc * check_h + (nc - 1) * check_row_gap
    else
        0;
    const input_span: i32 = if (has_input) input_gap + input_h else 0;
    const client_h = margin + content_h + checks_span + input_span + btn_gap_v + btn_h + margin;

    // Vertically center the shorter of icon/text within the content band.
    const icon_top = margin + @divTrunc(content_h - icon_px, 2);
    const text_top = margin + @divTrunc(content_h - text_h, 2);

    var checks: [max_checks]w32.RECT = @splat(.{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
    var i: i32 = 0;
    while (i < nc) : (i += 1) {
        const top = margin + content_h + check_gap + i * (check_h + check_row_gap);
        checks[@intCast(i)] = .{
            .left = margin + icon_span,
            .top = top,
            .right = client_w - margin,
            .bottom = top + check_h,
        };
    }

    const input_top = margin + content_h + checks_span + input_gap;
    const btn_top = margin + content_h + checks_span + input_span + btn_gap_v;
    const right_left = client_w - margin - btn_w;
    const left_left = right_left - btn_gap_h - btn_w;
    // With two buttons OK sits left of Cancel; alone, OK takes the right slot.
    const ok_left = if (has_cancel) left_left else right_left;

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
        .checks = checks,
        .ok = .{ .left = ok_left, .top = btn_top, .right = ok_left + btn_w, .bottom = btn_top + btn_h },
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
    return run(app, owner, scale, refocus, opts, null);
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
    if (run(app, owner, scale, refocus, opts, &out) != .ok) return null;
    return buf[0..out.len];
}

/// Where `prompt` collects the field's text. Separate from `Result` so `show`
/// can pass null and stay allocation-free.
const Output = struct {
    buf: []u8,
    len: usize = 0,
};

fn run(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
    out: ?*Output,
) Result {
    registerClass(app) orelse return fallback(owner, opts);

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    const has_icon = opts.icon != .none;
    const has_cancel = opts.style == .ok_cancel;
    const has_input = opts.input != null;
    const n_checks: usize = @min(opts.checks.len, max_checks);

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

        // Widest button caption, so custom labels never truncate.
        const labels: [2][:0]const u16 = .{ opts.ok_label, opts.cancel_label };
        for (labels, 0..) |label, i| {
            if (i == 1 and !has_cancel) break;
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
    }
    const l = layoutFor(
        scale,
        text_rect.right - text_rect.left,
        text_rect.bottom - text_rect.top,
        has_icon,
        n_checks,
        has_input,
        has_cancel,
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
        .default_cancel = has_cancel and opts.default_cancel and !has_input,
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
        app.hinstance,
        null,
    ) orelse return fallback(owner, opts);
    self.hwnd = hwnd;

    // Dark title bar, matching the terminal windows.
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

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
        app.hinstance,
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
            app.hinstance,
            null,
        ) orelse continue;
        _ = w32.SetWindowTheme(btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
        _ = w32.SendMessageW(btn, w32.BM_SETCHECK, if (check.checked) w32.BST_CHECKED else 0, 0);
        // Indexed like opts.checks (a failed create leaves a null hole), so
        // the readback below can never write one row's state into another.
        self.check_btns[i] = btn;
    }
    self.n_checks = n_checks;

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
            app.hinstance,
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
            (if (self.default_cancel) 0 else w32.BS_DEFPUSHBUTTON),
        l.ok.left,
        l.ok.top,
        l.ok.right - l.ok.left,
        l.ok.bottom - l.ok.top,
        hwnd,
        @ptrFromInt(@as(usize, @intCast(w32.IDOK))),
        app.hinstance,
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
            app.hinstance,
            null,
        ) orelse {
            _ = w32.DestroyWindow(hwnd);
            return fallback(owner, opts);
        };
        _ = w32.SetWindowTheme(cancel_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
        self.cancel_btn = cancel_btn;
    }

    if (font) |f| {
        if (self.static) |s| _ = w32.SendMessageW(s, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.edit) |e| _ = w32.SendMessageW(e, w32.WM_SETFONT, @intFromPtr(f), 1);
        for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
            _ = w32.SendMessageW(b, w32.WM_SETFONT, @intFromPtr(f), 1);
        };
        _ = w32.SendMessageW(self.ok_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.cancel_btn) |c| _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
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

    // Teardown. The owner MUST be re-enabled before the dialog is
    // destroyed, otherwise Windows may activate another app's window.
    if (owner) |o| _ = w32.EnableWindow(o, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(hwnd);
    if (owner) |o| _ = w32.SetForegroundWindow(o);
    if (refocus) |h| App.deferSetFocus(h); // T48

    return self.result;
}

/// Copy the edit control's text into `buf` as UTF-8, returning its length
/// (0 when it does not fit — a truncated device name is worse than none).
fn readEdit(edit: w32.HWND, buf: []u8) usize {
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, wbuf.len));
    return std.unicode.utf16LeToUtf8(buf, wbuf[0..wlen]) catch 0;
}

/// Last-resort fallback when dialog construction fails: the old (light)
/// MessageBoxW, so a prompt is never silently skipped.
fn fallback(owner: ?w32.HWND, opts: Options) Result {
    var flags: u32 = switch (opts.style) {
        .ok_only => w32.MB_OK,
        .ok_cancel => w32.MB_OKCANCEL,
    };
    flags |= switch (opts.icon) {
        .none => 0,
        .warning => w32.MB_ICONWARNING,
        .info => w32.MB_ICONINFORMATION,
    };
    if (opts.style == .ok_cancel and opts.default_cancel) flags |= w32.MB_DEFBUTTON2;
    const r = w32.MessageBoxW(owner, opts.text.ptr, opts.title, flags);
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
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null and self.ownsHwnd(msg.hwnd.?)) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);
            if (self.handleKey(vk)) continue;
        }
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

fn defaultButton(self: *const ConfirmDialog) w32.HWND {
    if (self.default_cancel) {
        if (self.cancel_btn) |c| return c;
    }
    return self.ok_btn;
}

fn ownsHwnd(self: *const ConfirmDialog, hwnd: w32.HWND) bool {
    if (hwnd == self.hwnd or hwnd == self.ok_btn) return true;
    if (self.static) |s| if (hwnd == s) return true;
    if (self.cancel_btn) |c| if (hwnd == c) return true;
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
            } else if (focus == @as(?w32.HWND, self.ok_btn)) {
                self.finish(.ok);
            } else {
                self.finish(if (self.default_cancel) .cancel else .ok);
            }
            return true;
        },
        w32.VK_TAB => {
            // Focus stops in order: checkboxes (top-down), field (when
            // present), OK, Cancel.
            var stops: [3 + max_checks]w32.HWND = undefined;
            var n: usize = 0;
            for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
                stops[n] = b;
                n += 1;
            };
            if (self.edit) |e| {
                stops[n] = e;
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

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    bg_brush = w32.CreateSolidBrush(COLOR_BG);
    field_brush = w32.CreateSolidBrush(COLOR_FIELD_BG);
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &dialogWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = app.hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
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
        // The prompt field is a field, not dialog surface — without this it
        // renders as a white box in an otherwise dark dialog.
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_FIELD_BG);
            if (field_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_BG);
            if (bg_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
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
    const l = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    try testing.expect(l.client_w > 0 and l.client_h > 0);
    for ([_]w32.RECT{ l.icon, l.text, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: buttons right-aligned, OK left of Cancel, no overlap" {
    const l = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expectEqual(l.ok.top, l.cancel.top);
    try testing.expectEqual(l.cancel.right, l.client_w - 16);
}

test "layoutFor: ok-only puts OK in the rightmost slot, no cancel rect" {
    const l = layoutFor(1.0, 300, 40, false, 0, false, false, 88);
    try testing.expectEqual(l.ok.right, l.client_w - 16);
    try testing.expectEqual(@as(i32, 0), l.cancel.right - l.cancel.left);
    try testing.expectEqual(@as(i32, 0), l.icon.right - l.icon.left);
}

test "layoutFor: text starts right of the icon with a gap" {
    const l = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    try testing.expect(l.text.left >= l.icon.right + 12);
    // Without an icon the text hugs the margin.
    const l2 = layoutFor(1.0, 300, 40, false, 0, false, true, 88);
    try testing.expectEqual(@as(i32, 16), l2.text.left);
}

test "layoutFor: short text is vertically centered against the icon" {
    const l = layoutFor(1.0, 300, 16, true, 0, false, true, 88);
    // Icon (32px) taller than text (16px): text drops to center.
    try testing.expect(l.text.top > l.icon.top);
    try testing.expectEqual(l.icon.top, 16);
    // Text (60px) taller than icon: icon centers instead.
    const l2 = layoutFor(1.0, 300, 60, true, 0, false, true, 88);
    try testing.expect(l2.icon.top > l2.text.top);
}

test "layoutFor: narrow text still fits the button row" {
    const l = layoutFor(1.0, 40, 20, false, 0, false, true, 88);
    // Two 88px buttons + 8px gap + 2*16 margins = 216, floored at 280.
    try testing.expect(l.client_w >= 280);
    try testing.expect(l.ok.left >= 16);
}

test "layoutFor: scales with DPI" {
    const l1 = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    const l2 = layoutFor(2.0, 600, 80, true, 0, false, true, 176);
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

test "layoutFor: wide buttons widen the row and never overlap" {
    const l = layoutFor(1.0, 40, 20, false, 0, false, true, 124);
    try testing.expectEqual(@as(i32, 124), l.ok.right - l.ok.left);
    try testing.expectEqual(@as(i32, 124), l.cancel.right - l.cancel.left);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expect(l.ok.left >= 16);
    // Client floor still respected: 2*124 + 8 + 2*16 = 288 > 280.
    try testing.expectEqual(@as(i32, 288), l.client_w);
}

// --- Prompt field (T176) -----------------------------------------------

test "layoutFor: no input means no input rect and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    try testing.expectEqual(@as(i32, 0), plain.input.right - plain.input.left);
    try testing.expectEqual(@as(i32, 0), plain.input.bottom - plain.input.top);
}

test "layoutFor: the field sits between the message and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, true, true, 88);
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
    const plain = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    const with = layoutFor(1.0, 300, 40, true, 0, true, true, 88);
    // 12 gap + 26 field.
    try testing.expectEqual(plain.client_h + 38, with.client_h);
    // The message band above it does not move.
    try testing.expectEqual(plain.text.top, with.text.top);
    try testing.expectEqual(plain.icon.top, with.icon.top);
}

test "layoutFor: a prompt is never too narrow to type in" {
    // A two-word message would otherwise leave a 280-wide dialog whose field
    // is barely wider than the button row.
    const l = layoutFor(1.0, 40, 20, false, 0, true, true, 88);
    try testing.expect(l.client_w >= 380);
    try testing.expect(l.input.right - l.input.left >= 340);
}

test "layoutFor: the field scales with DPI like everything else" {
    const a = layoutFor(1.0, 300, 40, true, 0, true, true, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, true, true, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.input.top * 2, b.input.top);
    try testing.expectEqual((a.input.bottom - a.input.top) * 2, b.input.bottom - b.input.top);
}

// --- Checkbox rows (T870) ----------------------------------------------

test "layoutFor: no checks means no check rects and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    for (plain.checks) |r| {
        try testing.expectEqual(@as(i32, 0), r.right - r.left);
        try testing.expectEqual(@as(i32, 0), r.bottom - r.top);
    }
}

test "layoutFor: check rows sit between the message and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 2, false, true, 88);
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
    const plain = layoutFor(1.0, 300, 40, true, 0, false, true, 88);
    const one = layoutFor(1.0, 300, 40, true, 1, false, true, 88);
    const two = layoutFor(1.0, 300, 40, true, 2, false, true, 88);
    // 12 gap + 20 row.
    try testing.expectEqual(plain.client_h + 32, one.client_h);
    // +4 row gap + 20 row.
    try testing.expectEqual(one.client_h + 24, two.client_h);
    // The message band above does not move.
    try testing.expectEqual(plain.text.top, two.text.top);
}

test "layoutFor: checks stack above the input field when both are present" {
    const l = layoutFor(1.0, 300, 40, true, 2, true, true, 88);
    try testing.expect(l.input.top >= l.checks[1].bottom);
    try testing.expect(l.ok.top >= l.input.bottom);
}

test "layoutFor: check rows scale with DPI" {
    const a = layoutFor(1.0, 300, 40, true, 2, false, true, 88);
    const b = layoutFor(2.0, 600, 80, true, 2, false, true, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.checks[0].top * 2, b.checks[0].top);
    try testing.expectEqual((a.checks[1].bottom - a.checks[1].top) * 2, b.checks[1].bottom - b.checks[1].top);
}

test "layoutFor: a check count beyond capacity is clamped, not overflowed" {
    const l = layoutFor(1.0, 300, 40, true, max_checks + 3, false, true, 88);
    const capped = layoutFor(1.0, 300, 40, true, max_checks, false, true, 88);
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
        const l = layoutFor(scale, 300, 40, true, 0, false, true, 88);
        try testing.expectEqual(type_ramp.body(scale).height, l.font_h);
        // A confirm's message is body text, never a subtitle and never a
        // caption — one role, so it reads at the same size as the chooser it
        // is often opened over.
        try testing.expect(l.font_h > type_ramp.caption(scale).height);
        try testing.expect(l.font_h < type_ramp.subtitle(scale).height);
    }
    try testing.expectEqual(@as(i32, 14), layoutFor(1.0, 300, 40, true, 0, false, true, 88).font_h);
}
