//! Pure layout for the win32 machine chooser's master-detail shell (T175, the
//! structural half of T140).
//!
//! The chooser used to be a 440-wide single column — account row, filter, a
//! five-row list, a status sentence, then Open + Cancel. Mac's
//! `MachineChooserView` is an 840x540 master-detail chooser: an account row
//! across the top, a fixed 260-wide machine column on a faint wash at the left,
//! a detail pane at the right carrying the selected machine's identity and its
//! primary action, and a footer holding Cancel alone.
//!
//! Everything here is arithmetic on a DPI scale, so it runs in the none-runtime
//! test lane; `MachineChooser.zig` keeps the HWNDs and the GDI calls. The
//! `Rect` type is local rather than `w32.RECT` for exactly that reason.

const std = @import("std");
const chooser_rows = @import("chooser_rows.zig");

/// A rectangle in physical pixels, left/top inclusive and right/bottom
/// exclusive — the same convention as `RECT`, which this converts to at the
/// call site.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

/// Every region the chooser places, in physical pixels from the client origin.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,

    /// Account row: status text on the left, the Sign In / Sign Out button
    /// right-aligned, with a full-width rule beneath at `header_divider_y`.
    account_status: Rect,
    account_btn: Rect,
    header_divider_y: i32,

    /// The master column — a faint wash behind the filter, the row list and
    /// the status strip — with a vertical rule down its right edge.
    master: Rect,
    master_divider_x: i32,
    filter: Rect,
    list: Rect,
    /// The status strip pinned to the bottom of the master column (Mac's
    /// "Refreshing devices… / Couldn't refresh devices: …"). It GROWS UPWARD
    /// into the list: the dialog is a fixed 840x540, so wrapped hint lines
    /// come out of the list's height, never out of the window's.
    hint: Rect,

    /// The detail pane and the pieces of its header.
    detail: Rect,
    detail_glyph: Rect,
    detail_title: Rect,
    detail_subtitle: Rect,
    primary_btn: Rect,

    /// Footer: a rule, then Cancel alone at the trailing edge.
    footer_divider_y: i32,
    cancel: Rect,

    /// `CreateFontW` heights (positive; the caller negates them).
    font_h: i32,
    title_font_h: i32,
    /// Height of one wrapped line of status-strip text.
    hint_line_h: i32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Chooser layout at `scale` (the owner window's DPI scale) with the status
/// strip sized for `hint_lines` wrapped lines (measured at runtime, clamped by
/// `chooser_rows.clampHintLines`). Pure — unit-tested.
pub fn layout(scale: f32, hint_lines: i32) Layout {
    const lines = chooser_rows.clampHintLines(hint_lines);

    // Mac's 840x540 (MachineChooserView.swift:270). Fixed: unlike the old
    // single-column dialog, nothing here grows the window.
    const client_w = px(840, scale);
    const client_h = px(540, scale);

    const margin = px(16, scale);
    const gap = px(10, scale);

    // Account header — Mac pads it 16 horizontal / 10 vertical (251-252).
    const account_h = px(26, scale);
    const account_btn_w = px(150, scale);
    const account_top = gap;
    const header_divider_y = account_top + account_h + gap;
    const account_btn_left = client_w - margin - account_btn_w;

    // Footer — Cancel alone, 16 all round (737-742).
    const btn_w = px(96, scale);
    const btn_h = px(28, scale);
    const cancel_top = client_h - margin - btn_h;
    const footer_divider_y = cancel_top - margin;

    const body_top = header_divider_y + 1;
    const body_bottom = footer_divider_y;

    // Master column — a fixed 260 wide on a wash (259-260).
    const master_w = px(260, scale);
    const master: Rect = .{ .left = 0, .top = body_top, .right = master_w, .bottom = body_bottom };

    // Filter: 14 horizontal / 14 top / 10 bottom (329-330).
    const filter_pad = px(14, scale);
    const filter_h = px(26, scale);
    const filter: Rect = .{
        .left = filter_pad,
        .top = master.top + filter_pad,
        .right = master.right - filter_pad,
        .bottom = master.top + filter_pad + filter_h,
    };

    // Status strip at the bottom of the column, then the list fills what is
    // left between it and the filter.
    const hint_line_h = px(16, scale);
    const hint_h = hint_line_h * lines;
    const hint: Rect = .{
        .left = filter_pad,
        .top = master.bottom - px(8, scale) - hint_h,
        .right = master.right - filter_pad,
        .bottom = master.bottom - px(8, scale),
    };

    // List inset 8 horizontally (343). Its height is snapped DOWN to whole
    // rows: an owner-drawn listbox would otherwise render a clipped half row at
    // its foot, and the leftover is invisible anyway — the list's background is
    // the same wash as the column behind it.
    const list_inset = px(8, scale);
    const list_top = filter.bottom + gap;
    const row_h = chooser_rows.rowMetrics(scale).height;
    const avail = hint.top - list_inset - list_top;
    const rows_h = if (row_h > 0) @max(row_h, @divTrunc(avail, row_h) * row_h) else avail;
    const list: Rect = .{
        .left = list_inset,
        .top = list_top,
        .right = master.right - list_inset,
        .bottom = list_top + rows_h,
    };

    // Detail pane, right of the vertical rule.
    const detail: Rect = .{
        .left = master.right + 1,
        .top = body_top,
        .right = client_w,
        .bottom = body_bottom,
    };

    // Detail header — 16 padding, a 30-wide glyph column, 12 to the text, and
    // 14 between the identity block and the action row (440-454).
    const glyph_w = px(30, scale);
    const title_h = px(24, scale);
    const subtitle_h = px(17, scale);
    const detail_glyph: Rect = .{
        .left = detail.left + margin,
        .top = detail.top + margin,
        .right = detail.left + margin + glyph_w,
        .bottom = detail.top + margin + glyph_w,
    };
    const text_left = detail_glyph.right + px(12, scale);
    const text_right = detail.right - margin;
    const detail_title: Rect = .{
        .left = text_left,
        .top = detail.top + margin,
        .right = text_right,
        .bottom = detail.top + margin + title_h,
    };
    const detail_subtitle: Rect = .{
        .left = text_left,
        .top = detail_title.bottom + px(2, scale),
        .right = text_right,
        .bottom = detail_title.bottom + px(2, scale) + subtitle_h,
    };
    const identity_bottom = @max(detail_glyph.bottom, detail_subtitle.bottom);
    const primary_top = identity_bottom + px(14, scale);
    const primary_w = px(124, scale);

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .account_status = .{
            .left = margin,
            .top = account_top,
            .right = account_btn_left - px(8, scale),
            .bottom = account_top + account_h,
        },
        .account_btn = .{
            .left = account_btn_left,
            .top = account_top,
            .right = account_btn_left + account_btn_w,
            .bottom = account_top + account_h,
        },
        .header_divider_y = header_divider_y,
        .master = master,
        .master_divider_x = master.right,
        .filter = filter,
        .list = list,
        .hint = hint,
        .detail = detail,
        .detail_glyph = detail_glyph,
        .detail_title = detail_title,
        .detail_subtitle = detail_subtitle,
        .primary_btn = .{
            .left = detail.left + margin,
            .top = primary_top,
            .right = detail.left + margin + primary_w,
            .bottom = primary_top + btn_h,
        },
        .footer_divider_y = footer_divider_y,
        .cancel = .{
            .left = client_w - margin - btn_w,
            .top = cancel_top,
            .right = client_w - margin,
            .bottom = cancel_top + btn_h,
        },
        .font_h = px(15, scale),
        .title_font_h = px(20, scale),
        .hint_line_h = hint_line_h,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "layout: the dialog is Mac's fixed 840x540" {
    const l = layout(1.0, 1);
    try testing.expectEqual(@as(i32, 840), l.client_w);
    try testing.expectEqual(@as(i32, 540), l.client_h);
}

test "layout: master column is a fixed 260 with the detail pane beside it" {
    const l = layout(1.0, 1);
    try testing.expectEqual(@as(i32, 260), l.master.width());
    try testing.expectEqual(l.master.right, l.master_divider_x);
    // The detail pane starts past the rule and runs to the client edge.
    try testing.expect(l.detail.left > l.master.right);
    try testing.expectEqual(l.client_w, l.detail.right);
    try testing.expect(l.detail.width() > l.master.width());
}

test "layout: the body sits between the header and footer rules" {
    const l = layout(1.0, 1);
    try testing.expect(l.header_divider_y > l.account_btn.bottom - 1);
    try testing.expect(l.master.top > l.header_divider_y);
    try testing.expectEqual(l.footer_divider_y, l.master.bottom);
    try testing.expectEqual(l.master.top, l.detail.top);
    try testing.expectEqual(l.master.bottom, l.detail.bottom);
}

test "layout: the footer holds Cancel alone, at the trailing edge" {
    const l = layout(1.0, 1);
    try testing.expect(l.cancel.top > l.footer_divider_y);
    try testing.expectEqual(l.client_w - 16, l.cancel.right);
    try testing.expectEqual(l.client_h - 16, l.cancel.bottom);
    // The primary action lives in the detail pane, not down here.
    try testing.expect(l.primary_btn.bottom < l.footer_divider_y);
    try testing.expect(l.primary_btn.left > l.master.right);
}

test "layout: master column stacks filter, list, status strip" {
    const l = layout(1.0, 1);
    try testing.expect(l.filter.top >= l.master.top);
    try testing.expect(l.list.top > l.filter.bottom);
    try testing.expect(l.hint.top > l.list.bottom);
    try testing.expect(l.hint.bottom <= l.master.bottom);
    // All three stay inside the column.
    for ([_]Rect{ l.filter, l.list, l.hint }) |r| {
        try testing.expect(r.left >= l.master.left);
        try testing.expect(r.right <= l.master.right);
    }
}

test "layout: extra hint lines come out of the list, not the window" {
    const one = layout(1.0, 1);
    const three = layout(1.0, 3);
    try testing.expectEqual(one.client_h, three.client_h);
    try testing.expectEqual(one.client_w, three.client_w);

    const extra = 2 * one.hint_line_h;
    try testing.expectEqual(one.hint.height() + extra, three.hint.height());
    // The list gives up the room the strip took — in whole rows, so it can
    // shed at most one row more than the strip gained.
    try testing.expectEqual(one.list.top, three.list.top);
    try testing.expect(three.list.height() <= one.list.height());
    const shed = one.list.height() - three.list.height();
    const row_h = chooser_rows.rowMetrics(1.0).height;
    try testing.expect(shed >= extra - row_h);
    try testing.expect(shed <= extra + row_h);
    // Whatever it sheds, it never grows into the strip.
    try testing.expect(three.list.bottom <= three.hint.top);
}

test "layout: the list is always a whole number of rows" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 2.0) }) |scale| {
        const row_h = chooser_rows.rowMetrics(scale).height;
        var lines: i32 = 1;
        while (lines <= chooser_rows.max_hint_lines) : (lines += 1) {
            const l = layout(scale, lines);
            try testing.expectEqual(@as(i32, 0), @rem(l.list.height(), row_h));
            try testing.expect(l.list.height() >= row_h);
            try testing.expect(l.list.bottom <= l.hint.top);
        }
    }
}

test "layout: the hint line count is clamped like the strip that renders it" {
    const capped = layout(1.0, 99);
    const at_max = layout(1.0, chooser_rows.max_hint_lines);
    try testing.expectEqual(at_max.hint.height(), capped.hint.height());
    // Even at the cap the list stays a real list, not a peephole.
    try testing.expect(capped.list.height() >= chooser_rows.rowMetrics(1.0).height * 5);
}

test "layout: detail header runs glyph -> title -> subtitle -> primary action" {
    const l = layout(1.0, 1);
    try testing.expect(l.detail_glyph.left >= l.detail.left);
    try testing.expect(l.detail_title.left > l.detail_glyph.right);
    try testing.expectEqual(l.detail_title.left, l.detail_subtitle.left);
    try testing.expect(l.detail_subtitle.top >= l.detail_title.bottom);
    try testing.expect(l.primary_btn.top >= l.detail_subtitle.bottom);
    try testing.expect(l.primary_btn.top >= l.detail_glyph.bottom);
    // Everything nests inside the pane.
    for ([_]Rect{ l.detail_glyph, l.detail_title, l.detail_subtitle, l.primary_btn }) |r| {
        try testing.expect(r.left >= l.detail.left);
        try testing.expect(r.right <= l.detail.right);
        try testing.expect(r.bottom <= l.detail.bottom);
    }
}

test "layout: account row is right-aligned against the client edge" {
    const l = layout(1.0, 1);
    try testing.expectEqual(l.client_w - 16, l.account_btn.right);
    try testing.expect(l.account_status.right < l.account_btn.left);
    try testing.expect(l.account_status.left > 0);
}

test "layout: scales with DPI" {
    const a = layout(1.0, 2);
    const b = layout(2.0, 2);
    try testing.expectEqual(a.client_w * 2, b.client_w);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.master.width() * 2, b.master.width());
    try testing.expectEqual(a.hint.height() * 2, b.hint.height());
    try testing.expectEqual(a.title_font_h * 2, b.title_font_h);
}
