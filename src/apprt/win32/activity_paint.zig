//! Activity monitor painting: every pixel the panel draws.
//!
//! Split out of `ActivityMonitor.zig` (T299). This is the biggest of the
//! panel's planes and the most self-contained one: it takes a `Layout` (pure
//! arithmetic from `activity_layout.zig`), a palette, and an HDC, and it
//! touches no lifetime — nothing here starts a thread, opens a connection, or
//! frees anything. That is what makes it safe to read on its own, and it is
//! why it moved first.
//!
//! `paint` itself double-buffers into a memory DC and blits once, so the panel
//! never flickers while a sample lands. Everything under it draws into that
//! same DC in layout order: carousel, gauges, control bar, table, banner.
//!
//! The small GDI helpers at the top (`rect`, `fill`, `drawText`, `roundRect`,
//! `strokeRoundRect`, `ellipse`, `px`) are shared by all of it and are the
//! panel's whole vocabulary for talking to GDI.

const std = @import("std");

const ActivityMonitor = @import("ActivityMonitor.zig");
const Scrollbar = @import("Scrollbar.zig");
const actions = @import("activity_actions.zig");
const cards_mod = @import("activity_cards.zig");
const chrome_theme = @import("chrome_theme.zig");
const gauge = @import("trend_gauge.zig");
const icon_button = @import("icon_button.zig");
const icon_button_paint = @import("icon_button_paint.zig");
const layout_mod = @import("activity_layout.zig");
const list_selection = @import("list_selection.zig");
const panel_theme = @import("panel_theme.zig");
const rows_mod = @import("activity_rows.zig");
const remote_protocol = @import("../../remote/protocol.zig");
const w32 = @import("win32.zig");

const cr = ActivityMonitor.cr;

// ---------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------

pub fn rect(r: layout_mod.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

pub fn fill(hdc: w32.HDC, r: w32.RECT, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);
    var rr = r;
    _ = w32.FillRect(hdc, &rr, brush);
}

pub fn drawText(hdc: w32.HDC, text: []const u8, r: layout_mod.Rect, flags: u32) void {
    var wbuf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
    if (n == 0) return;
    var rr = rect(r);
    _ = w32.DrawTextW(hdc, &wbuf, @intCast(n), &rr, flags | w32.DT_NOPREFIX);
}

pub const text_flags: u32 = w32.DT_SINGLELINE | w32.DT_VCENTER;

pub fn paint(self: *ActivityMonitor, hdc: w32.HDC) void {
    const p = self.pal();
    const l = self.layout();

    // Double-buffered: the table repaints on every 1.5 s poll, and a direct
    // paint of that many rows flickers.
    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const bmp = w32.CreateCompatibleBitmap(hdc, l.client_w, l.client_h) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const old_bmp = w32.SelectObject(mem_dc, bmp);
    defer _ = w32.SelectObject(mem_dc, old_bmp);

    fill(mem_dc, .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h }, cr(p.bg));
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    paintCarousel(self, mem_dc, l);
    paintGauges(self, mem_dc, l);
    paintControlBar(self, mem_dc, l);
    paintTable(self, mem_dc, l);
    // After the rows, and after the empty state: a rim the next row painted
    // over is not a focus indicator.
    paintTableFocus(self, mem_dc, l);
    paintBanner(self, mem_dc, l);

    // Dividers last so nothing paints over them. A hidden band reports its rule
    // at -1 and must not paint a line across the top of the window.
    for ([_]i32{ l.carousel_divider_y, l.header_divider_y, l.control_divider_y }) |y| {
        if (y < 0) continue;
        fill(mem_dc, .{ .left = 0, .top = y, .right = l.client_w, .bottom = y + 1 }, cr(p.divider));
    }

    _ = w32.BitBlt(hdc, 0, 0, l.client_w, l.client_h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// The machine-card carousel (T296). Cards are clipped to the band so a
/// scrolled strip cannot paint over the gauges below it.
pub fn paintCarousel(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (!cards_mod.hasCarousel(self.card_count)) return;

    // Save/restore rather than `SelectClipRgn(dc, null)`: clearing the clip
    // outright would un-clip whatever the caller had set, not just what we add.
    const saved = w32.SaveDC(hdc);
    defer {
        if (saved != 0) _ = w32.RestoreDC(hdc, saved);
    }
    _ = w32.IntersectClipRect(
        hdc,
        l.carousel.left,
        l.carousel.top,
        l.carousel.right,
        l.carousel.bottom,
    );

    const active = self.activeCardIndex();
    for (self.cards[0..self.card_count], 0..) |card, i| {
        const idx: i32 = @intCast(i);
        const r = layout_mod.cardRect(l, idx, self.carousel_scroll, self.scale);
        if (r.right <= l.carousel.left or r.left >= l.carousel.right) continue;
        const is_active = active != null and active.? == i;
        // The ring means "the keyboard is HERE" (§2.2), so it is drawn only
        // while the carousel really holds focus — a ring parked on a card
        // while the caret sits in the filter box says the opposite.
        const carousel_focused = self.panel_focused and self.focus == .carousel;
        paintCard(self, hdc, r, card, is_active, carousel_focused and idx == self.card_focus, idx == self.card_hover);
    }
}

pub fn paintCard(
    self: *ActivityMonitor,
    hdc: w32.HDC,
    r: layout_mod.Rect,
    card: cards_mod.Card,
    is_active: bool,
    is_focused: bool,
    is_hover: bool,
) void {
    const p = self.pal();
    const radius = px(8, self.scale);
    const fill_color: u32 = if (is_active)
        cr(p.select)
    else if (is_hover)
        cr(p.card_hover)
    else
        cr(p.card);
    const border_color: u32 = if (is_active) cr(p.accent) else cr(p.card_border);
    const border_w: i32 = if (is_active) @max(2, px(2, self.scale)) else @max(1, px(1, self.scale));

    roundRect(hdc, r, radius, fill_color, border_color, border_w);

    // The focus ring lives OUTSIDE the card and only when focus is NOT already
    // on the active card — otherwise the accent border and the ring stack into
    // a double border that reads as a rendering bug (Mac makes the same call,
    // :1481-1488).
    if (is_focused and !is_active) {
        const pad = @max(2, px(2, self.scale));
        const ring: layout_mod.Rect = .{
            .left = r.left - pad,
            .top = r.top - pad,
            .right = r.right + pad,
            .bottom = r.bottom + pad,
        };
        strokeRoundRect(hdc, ring, radius + pad, cr(p.accent), @max(2, px(2, self.scale)));
    }

    const c = layout_mod.cardContent(r, self.scale);
    const switching = is_active and self.dialing;

    // Status dot.
    const dot_color: u32 = switch (cards_mod.dot(card.summary, switching)) {
        .good => cr(p.good),
        .pending => cr(p.pending),
        .bad => cr(p.bad),
        .unknown => cr(p.neutral),
    };
    ellipse(hdc, c.dot, dot_color);

    const secondary: u32 = if (is_active) cr(p.secondary_on_select) else cr(p.secondary);
    const flags: u32 = text_flags | w32.DT_END_ELLIPSIS;

    const old_font = if (self.font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, cr(p.text));
    drawText(hdc, card.label, c.label, flags);

    if (self.caption_font) |f| _ = w32.SelectObject(hdc, f);
    _ = w32.SetTextColor(hdc, secondary);
    var sbuf: [48]u8 = undefined;
    drawText(hdc, cards_mod.summaryLine(&sbuf, card.summary, switching), c.summary, flags);

    // The metric line is tabular — a number that jitters sideways every 1.5 s
    // is the reason `num_font` exists.
    if (self.num_font) |f| _ = w32.SelectObject(hdc, f);
    var mbuf: [64]u8 = undefined;
    const metric = cards_mod.metricLine(&mbuf, card.summary);
    if (metric.len > 0) drawText(hdc, metric, c.metric, flags);

    if (old_font) |f| _ = w32.SelectObject(hdc, f);
}

pub fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// A filled rounded rect with a border, in the GDI idiom the banner overlay
/// already uses (`BannerOverlay.zig:524-529`).
pub fn roundRect(
    hdc: w32.HDC,
    r: layout_mod.Rect,
    radius: i32,
    fill_color: u32,
    border_color: u32,
    border_w: i32,
) void {
    const brush = w32.CreateSolidBrush(fill_color) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(0, border_w, border_color) orelse return; // PS_SOLID
    defer _ = w32.DeleteObject(pen);
    const old_brush = w32.SelectObject(hdc, @ptrCast(brush));
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
}

/// The same shape, stroked only — the focus ring must not paint over whatever
/// is behind the card's corners.
pub fn strokeRoundRect(hdc: w32.HDC, r: layout_mod.Rect, radius: i32, color: u32, width: i32) void {
    const pen = w32.CreatePen(0, width, color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const hollow = w32.GetStockObject(w32.NULL_BRUSH);
    const old_brush = w32.SelectObject(hdc, hollow);
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
}

pub fn ellipse(hdc: w32.HDC, r: layout_mod.Rect, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(0, 1, color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_brush = w32.SelectObject(hdc, @ptrCast(brush));
    defer _ = w32.SelectObject(hdc, old_brush);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    _ = w32.Ellipse(hdc, r.left, r.top, r.right, r.bottom);
}

pub fn paintGauges(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    const p = self.pal();
    const host: remote_protocol.HostMetrics = if (self.snap) |s| s.host else .{};

    var vbuf: [48]u8 = undefined;
    var dbuf: [64]u8 = undefined;
    var mbuf: [32]u8 = undefined;

    const cpu_value = rows_mod.formatHostCpu(&vbuf, host.cpu_pct);
    const cpu_detail = std.fmt.bufPrint(&dbuf, "{d} cores", .{host.ncpu}) catch "";
    paintGauge(self, hdc, l, l.gauge_cpu, "CPU", cpu_value, cpu_detail, cr(p.cpu), cr(p.cpu_fill), self.cpu_ring[0..self.ring_len]);

    var vbuf2: [48]u8 = undefined;
    var dbuf2: [64]u8 = undefined;
    const mem_value = rows_mod.formatMemory(&vbuf2, host.mem_used);
    const mem_detail = std.fmt.bufPrint(&dbuf2, "of {s}", .{rows_mod.formatMemory(&mbuf, host.mem_total)}) catch "";
    paintGauge(self, hdc, l, l.gauge_mem, "Memory", mem_value, mem_detail, cr(p.mem), cr(p.mem_fill), self.mem_ring[0..self.ring_len]);
}

pub fn paintGauge(
    self: *ActivityMonitor,
    hdc: w32.HDC,
    l: layout_mod.Layout,
    box: layout_mod.Rect,
    title: []const u8,
    value: []const u8,
    detail: []const u8,
    tint: u32,
    fill_tint: u32,
    samples: []const f32,
) void {
    const p = self.pal();
    const title_band: layout_mod.Rect = .{
        .left = box.left,
        .top = box.top,
        .right = box.right,
        .bottom = box.top + l.gauge_chart_dy,
    };

    _ = w32.SelectObject(hdc, self.caption_font);
    _ = w32.SetTextColor(hdc, cr(p.secondary));
    drawText(hdc, title, title_band, text_flags | w32.DT_LEFT);
    drawText(hdc, detail, title_band, text_flags | w32.DT_RIGHT);

    // The headline number sits between them, so the eye lands on it first.
    _ = w32.SelectObject(hdc, self.title_font);
    _ = w32.SetTextColor(hdc, cr(p.text));
    drawText(hdc, value, title_band, text_flags | w32.DT_CENTER);

    const chart: layout_mod.Rect = .{
        .left = box.left,
        .top = box.top + l.gauge_chart_dy,
        .right = box.right,
        .bottom = box.bottom,
    };
    fill(hdc, rect(chart), cr(p.well));

    var grid: [gauge.gridline_values.len]i32 = undefined;
    gauge.gridlines(chart, &grid);
    for (grid) |y| {
        fill(hdc, .{ .left = chart.left, .top = y, .right = chart.right, .bottom = y + 1 }, cr(p.grid));
    }

    if (samples.len == 0) return;

    var pts: [gauge.ring_capacity]gauge.Point = undefined;
    const line = gauge.polyline(chart, samples, &pts);
    if (line.len == 0) return;

    // The filled area under the curve, then the curve itself on top of it.
    if (gauge.fillClose(chart, line)) |closers| {
        var poly: [gauge.ring_capacity + 2]w32.POINT = undefined;
        for (line, 0..) |pt, i| poly[i] = .{ .x = pt.x, .y = pt.y };
        poly[line.len] = .{ .x = closers[0].x, .y = closers[0].y };
        poly[line.len + 1] = .{ .x = closers[1].x, .y = closers[1].y };

        const brush = w32.CreateSolidBrush(fill_tint);
        const pen = w32.CreatePen(w32.PS_SOLID, 1, fill_tint);
        if (brush != null and pen != null) {
            const ob = w32.SelectObject(hdc, brush);
            const op = w32.SelectObject(hdc, pen);
            _ = w32.Polygon(hdc, &poly, @intCast(line.len + 2));
            _ = w32.SelectObject(hdc, ob);
            _ = w32.SelectObject(hdc, op);
        }
        if (brush) |b| _ = w32.DeleteObject(b);
        if (pen) |pn| _ = w32.DeleteObject(pn);
    }

    var wide: [gauge.ring_capacity]w32.POINT = undefined;
    for (line, 0..) |pt, i| wide[i] = .{ .x = pt.x, .y = pt.y };
    const pen = w32.CreatePen(w32.PS_SOLID, @max(1, @as(i32, @intFromFloat(@round(self.scale)))), tint) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old = w32.SelectObject(hdc, pen);
    _ = w32.Polyline(hdc, &wide, @intCast(line.len));
    _ = w32.SelectObject(hdc, old);
}

pub fn paintControlBar(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    const p = self.pal();
    _ = w32.SelectObject(hdc, self.caption_font);

    const total = if (self.snap) |s| s.rows.len else 0;
    const truncated = if (self.snap) |s| s.truncated else false;
    if (l.badge.width() > 0) {
        if (actions.badgeText(self.refresh_failed, truncated, total)) |badge| {
            _ = w32.SetTextColor(hdc, cr(p.warn));
            drawText(hdc, badge, l.badge, text_flags | w32.DT_LEFT | w32.DT_END_ELLIPSIS);
        }
    }

    var buf: [64]u8 = undefined;
    const count = rows_mod.formatCount(&buf, self.filterSpec(), self.order_len, total);
    _ = w32.SetTextColor(hdc, cr(p.secondary));
    drawText(hdc, count, l.count, text_flags | w32.DT_RIGHT);
}

pub fn paintTable(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    const p = self.pal();
    const widths = layout_mod.columnWidths(self.scale, l.table.width());

    // Header band.
    fill(hdc, rect(l.table_header), cr(p.header));
    _ = w32.SelectObject(hdc, self.font);
    _ = w32.SetTextColor(hdc, cr(p.label));
    for (layout_mod.column_specs, 0..) |spec, i| {
        const col: layout_mod.Column = @enumFromInt(i);
        const cell = layout_mod.cellRect(l.table_header, widths, col, self.scale);
        const active = @intFromEnum(sortKeyColumn(self)) == i;

        // The sort indicator gets its OWN reserved slot at the cell's trailing
        // edge and the title ellipsizes inside what is left. Appending it to
        // the title string instead put it inside the ellipsis: "% CPU" plus an
        // arrow does not fit the 60-90 DIP CPU column, so DT_END_ELLIPSIS ate
        // the arrow and the panel showed "% CPU…" with no indicator on the very
        // column it was sorted by. Caught in a capture before this shipped.
        const arrow_w: i32 = if (active) sortArrowWidth(self.scale) else 0;
        var title_cell = cell;
        title_cell.right = @max(title_cell.left, title_cell.right - arrow_w);

        const align_flag: u32 = if (spec.right_align) w32.DT_RIGHT else w32.DT_LEFT;
        drawText(hdc, spec.title, title_cell, text_flags | align_flag | w32.DT_END_ELLIPSIS);
        if (active) {
            paintSortArrow(hdc, .{
                .left = cell.right - arrow_w,
                .top = cell.top,
                .right = cell.right,
                .bottom = cell.bottom,
            }, self.sort.ascending, self.scale, cr(p.label));
        }
    }
    fill(
        hdc,
        .{ .left = l.table.left, .top = l.table_header.bottom - 1, .right = l.table.right, .bottom = l.table_header.bottom },
        cr(p.divider),
    );

    const snap = self.snap orelse {
        paintEmptyState(self, hdc, l);
        return;
    };
    if (self.order_len == 0) {
        paintEmptyState(self, hdc, l);
        return;
    }

    // What a SELECTED ROW looks like (T1008): the platform's list treatment,
    // resolved once for the whole pass because it is the same for every row —
    // a neutral wash at the weight the table's focus earns, and the accent spent
    // on one leading-edge capsule. The table is a list, so it answers this the
    // way the machine chooser's rows do, out of the same module.
    //
    // "Focused" here is the TABLE, not a caret row: macOS's emphasized /
    // unemphasized selection, and the same thing `RowState.focused` means for a
    // single-select listbox whose caret is its selection. The caret's own rim is
    // `paintTableFocus`.
    const table_focused = self.panel_focused and self.focus == .table;
    const sel = list_selection.rowPaint(p.bg, p.accent, .{
        .selected = true,
        .focused = table_focused,
    });
    const sel_fill = sel.fill.?;
    const sel_text = chrome_theme.textOn(sel_fill);
    const sel_secondary = chrome_theme.textSecondaryOn(sel_fill);
    const hover_fill = list_selection.hoverFill(p.bg);

    const visible = layout_mod.visibleRows(l);
    var i: i32 = 0;
    while (i < visible) : (i += 1) {
        const idx = self.scroll + i;
        if (idx < 0 or @as(usize, @intCast(idx)) >= self.order_len) break;
        const row = snap.rows[self.order[@intCast(idx)]];
        const row_rect = layout_mod.rowRect(l, i);

        const selected = self.isSelected(row.pid);
        if (selected) {
            fill(hdc, rect(row_rect), cr(sel_fill));
            if (sel.indicator) |ink| {
                const bar = layout_mod.rowIndicator(row_rect, self.scale);
                roundRect(hdc, bar, @divTrunc(bar.width(), 2), cr(ink), cr(ink), 1);
            }
        } else if (self.hover_row == idx) {
            fill(hdc, rect(row_rect), cr(hover_fill));
        }

        paintRow(self, hdc, row_rect, widths, row, snap.host.ncpu, .{
            .text = if (selected) sel_text else p.text,
            .secondary = if (selected) sel_secondary else p.secondary,
        });
    }

    paintScrollThumb(self, hdc, l, visible);
}

/// §2.2's keyboard focus ring for the table (T289).
///
/// The table is an owner-drawn region, so nothing draws this for us the way the
/// theme draws it for the native EDIT and BUTTONs. It goes on the CARET row —
/// Windows' list-view convention, and the split T312 already made for the
/// chooser's rows: a selection is a fill and stays put while focus moves away,
/// focus is a rim and follows the keyboard. A row that is both wears both.
///
/// With no row to carry it — an empty table, everything filtered out, or a
/// caret scrolled off screen by the wheel — the rim falls back to the row area
/// itself, inset by the panel's margin. A focus stop that draws nothing is the
/// defect this task exists to fix, and "there are no rows" is not an excuse to
/// reproduce it.
pub fn paintTableFocus(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (!self.panel_focused or self.focus != .table) return;

    // The HEADER's cursor takes the ring while it is up (T567). One focus stop
    // draws ONE indicator: a rim on a heading AND a rim on the caret row would
    // say the keyboard was in two places, which is the doubled-outline defect
    // §2.2 is about — and the caret row keeps its selection fill either way, so
    // nothing is lost by lending the rim to the header.
    if (self.header_cursor) |col| {
        const widths = layout_mod.columnWidths(self.scale, l.table.width());
        const band = layout_mod.headerCursorRect(l.table_header, widths, col);
        const path = layout_mod.focusRingPath(band, self.scale);
        if (path.width() <= 0 or path.height() <= 0) return;
        const hp = self.pal();
        strokeRoundRect(
            hdc,
            path,
            0,
            cr(list_selection.focusRim(hp.header)),
            layout_mod.focusRing(self.scale).width,
        );
        return;
    }

    const visible = layout_mod.visibleRows(l);
    const on_row: ?layout_mod.Rect = blk: {
        const idx = self.caretIndex() orelse break :blk null;
        const row = idx - self.scroll;
        if (row < 0 or row >= visible) break :blk null;
        break :blk layout_mod.rowRect(l, row);
    };
    const target = on_row orelse layout_mod.tableFocusFallback(l, self.scale);
    const path = layout_mod.focusRingPath(target, self.scale);
    if (path.width() <= 0 or path.height() <= 0) return;

    // A row is a square band, so its rim is square; the fallback is a
    // standalone element and takes the scale's smallest radius (§3.1).
    const radius: i32 = if (on_row != null) 0 else px(4, self.scale);

    // NEUTRAL ink, not the accent (§2.2's list amendment, T828/T1008): a
    // selected row already spends the accent on its indicator capsule, and an
    // accent rim around it is a second accent mark on one control — the doubled
    // outline the user reported on the chooser. Floored against what the rim
    // actually sits on, which is the selection fill when the caret row is
    // selected and the panel when it is not.
    const p = self.pal();
    const under: panel_theme.Rgb = blk: {
        const idx = self.caretIndex() orelse break :blk p.bg;
        if (on_row == null) break :blk p.bg;
        const pid = self.pidAt(idx) orelse break :blk p.bg;
        if (!self.isSelected(pid)) break :blk p.bg;
        break :blk list_selection.selectionFillFocused(p.bg);
    };
    strokeRoundRect(
        hdc,
        path,
        radius,
        cr(list_selection.focusRim(under)),
        layout_mod.focusRing(self.scale).width,
    );
}

/// The slot the sort indicator reserves at a header cell's trailing edge: the
/// mark plus one `sm` of clearance from the title (§0.1 — nothing touches
/// anything).
pub fn sortArrowWidth(scale: f32) i32 {
    return @max(8, @as(i32, @intFromFloat(@round(12 * scale))));
}

/// The sort indicator: a FILLED triangle, not a text glyph (§4 — glyphs are
/// filled shapes). Points down for descending, up for ascending, centered in
/// its slot.
pub fn paintSortArrow(hdc: w32.HDC, box: layout_mod.Rect, ascending: bool, scale: f32, color: u32) void {
    const half_w = @max(3, @as(i32, @intFromFloat(@round(3.5 * scale))));
    const half_h = @max(2, @as(i32, @intFromFloat(@round(2.0 * scale))));
    const cx = @divTrunc(box.left + box.right, 2);
    const cy = @divTrunc(box.top + box.bottom, 2);
    const tip_y = if (ascending) cy - half_h else cy + half_h;
    const base_y = if (ascending) cy + half_h else cy - half_h;
    var pts = [_]w32.POINT{
        .{ .x = cx - half_w, .y = base_y },
        .{ .x = cx + half_w, .y = base_y },
        .{ .x = cx, .y = tip_y },
    };

    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(w32.PS_SOLID, 1, color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const ob = w32.SelectObject(hdc, brush);
    const op = w32.SelectObject(hdc, pen);
    _ = w32.Polygon(hdc, &pts, pts.len);
    _ = w32.SelectObject(hdc, ob);
    _ = w32.SelectObject(hdc, op);
}

/// The two text colors a row draws with, already floored against the surface
/// the row actually paints — the selection fill when there is one, the panel
/// otherwise. Resolved by the caller once per pass rather than per row (T1008;
/// the T308 rule that a color is only correct relative to its own surface).
pub const RowInk = struct {
    text: panel_theme.Rgb,
    secondary: panel_theme.Rgb,
};

pub fn paintRow(
    self: *ActivityMonitor,
    hdc: w32.HDC,
    row_rect: layout_mod.Rect,
    widths: [layout_mod.column_count]i32,
    row: rows_mod.Row,
    ncpu: u32,
    ink: RowInk,
) void {
    var buf: [32]u8 = undefined;

    _ = w32.SelectObject(hdc, self.num_font);
    _ = w32.SetTextColor(hdc, cr(ink.text));
    const pid_text = std.fmt.bufPrint(&buf, "{d}", .{row.pid}) catch "";
    drawText(hdc, pid_text, layout_mod.cellRect(row_rect, widths, .pid, self.scale), text_flags | w32.DT_LEFT);

    var cbuf: [32]u8 = undefined;
    drawText(
        hdc,
        rows_mod.formatCpu(&cbuf, row.cpu_pct, ncpu),
        layout_mod.cellRect(row_rect, widths, .cpu, self.scale),
        text_flags | w32.DT_RIGHT,
    );
    var mbuf: [32]u8 = undefined;
    drawText(
        hdc,
        rows_mod.formatMemory(&mbuf, row.mem_bytes),
        layout_mod.cellRect(row_rect, widths, .mem, self.scale),
        text_flags | w32.DT_RIGHT,
    );

    _ = w32.SelectObject(hdc, self.font);
    drawText(
        hdc,
        if (row.name.len == 0) rows_mod.empty_cell else row.name,
        layout_mod.cellRect(row_rect, widths, .name, self.scale),
        text_flags | w32.DT_LEFT | w32.DT_END_ELLIPSIS,
    );

    // The path is secondary text and ellipsizes in the MIDDLE, so the leaf
    // filename survives (Mac's `.truncationMode(.head)`, :1020).
    //
    // Its color is the de-emphasized ramp resolved against the surface THIS row
    // paints, not against the panel behind it (T308): a selected row is a
    // different surface, and a grey measured on the panel was never measured on
    // the selection fill. It used to jump to the PRIMARY color on a selected row
    // because the old accent-tinted fill left no legible secondary; the neutral
    // wash does, so the hierarchy survives being selected (T1008).
    _ = w32.SetTextColor(hdc, cr(ink.secondary));
    drawText(
        hdc,
        if (row.cmd.len == 0) rows_mod.empty_cell else row.cmd,
        layout_mod.cellRect(row_rect, widths, .path, self.scale),
        text_flags | w32.DT_LEFT | w32.DT_PATH_ELLIPSIS,
    );
}

pub fn paintEmptyState(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    const p = self.pal();
    const total = if (self.snap) |s| s.rows.len else 0;
    const state = actions.emptyState(self.dialing, self.loading, self.refresh_failed, total);
    if (state != .unreachable_source) {
        _ = w32.SelectObject(hdc, self.font);
        _ = w32.SetTextColor(hdc, cr(p.secondary));
        const text = switch (state) {
            .connecting => "Connecting\u{2026}",
            .loading => "Loading\u{2026}",
            else => "No processes match",
        };
        drawText(hdc, text, l.table_rows, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);
        return;
    }

    // Mac's two-line "Couldn't connect" block (:1034-1045): a headline the eye
    // lands on and a subtitle naming the source that is unreachable.
    const mid = @divTrunc(l.table_rows.top + l.table_rows.bottom, 2);
    const line_h = l.row_h;
    _ = w32.SelectObject(hdc, self.font);
    _ = w32.SetTextColor(hdc, cr(p.text));
    drawText(hdc, "Couldn't connect", .{
        .left = l.table_rows.left,
        .top = mid - line_h,
        .right = l.table_rows.right,
        .bottom = mid,
    }, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);

    var buf: [96]u8 = undefined;
    const sub = std.fmt.bufPrint(
        &buf,
        "The {s} source is unreachable.",
        .{self.source.label()},
    ) catch "The source is unreachable.";
    _ = w32.SelectObject(hdc, self.caption_font);
    _ = w32.SetTextColor(hdc, cr(p.secondary));
    drawText(hdc, sub, .{
        .left = l.table_rows.left,
        .top = mid,
        .right = l.table_rows.right,
        .bottom = mid + line_h,
    }, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER);
}

/// The dismissable action-error banner under the table (Mac's `errorBanner`,
/// :1059-1080): a warning glyph, the message, and an ✕ at the trailing edge.
///
/// Painted, not a native control: it is one band that appears and disappears
/// with `Options.has_banner`, and a child window would have to be moved and
/// shown/hidden in lockstep with a rect the layout module already computes.
pub fn paintBanner(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout) void {
    const p = self.pal();
    if (self.err_len == 0) return;

    fill(hdc, rect(l.banner), cr(p.banner));
    // A rule along its top edge, so the banner reads as a band and not as the
    // table's last row painted a different color.
    fill(hdc, .{
        .left = l.banner.left,
        .top = l.banner.top,
        .right = l.banner.right,
        .bottom = l.banner.top + 1,
    }, cr(p.divider));

    const m = icon_button.Metrics.init(self.scale);
    const glyph_box = icon_button.targetBox(m, .{
        .left = l.banner_close.left,
        .top = l.banner_close.top,
        .right = l.banner_close.right,
        .bottom = l.banner_close.bottom,
    });
    icon_button_paint.glyph(hdc, m, glyph_box, .close, cr(p.secondary));

    // The band's own margin, TAKEN from the layout module rather than
    // re-derived from `pad_x` here: the ✕ sits one margin in from the trailing
    // edge, so `client_w - banner_close.right` IS the margin (the T257 lesson —
    // a second copy of a number is a second chance to be wrong).
    const margin = l.client_w - l.banner_close.right;
    const icon_w = margin;
    const gap = @divTrunc(margin, 2);

    // Both floored against the BANNER, which is a tinted surface of its own -
    // `p.warn` and `p.text` are measured against the panel (T308).
    const warn_on_banner = panel_theme.textSemanticOn(panel_theme.warn_base, p.banner);
    const text_on_banner = chrome_theme.textOn(p.banner);
    _ = w32.SelectObject(hdc, self.caption_font);
    _ = w32.SetTextColor(hdc, cr(warn_on_banner));
    drawText(hdc, "\u{26A0}", .{
        .left = l.banner.left + margin,
        .top = l.banner.top,
        .right = l.banner.left + margin + icon_w,
        .bottom = l.banner.bottom,
    }, text_flags | w32.DT_CENTER);

    const text_left = l.banner.left + margin + icon_w + gap;
    _ = w32.SetTextColor(hdc, cr(text_on_banner));
    drawText(hdc, self.err_buf[0..self.err_len], .{
        .left = text_left,
        .top = l.banner.top,
        // Clear of the ✕ by one gap — nothing touches anything (§0.1).
        .right = @max(text_left, l.banner_close.left - gap),
        .bottom = l.banner.bottom,
    }, text_flags | w32.DT_LEFT | w32.DT_END_ELLIPSIS);
}

/// An overlay thumb on the table's trailing edge — the app's own scrollbar
/// idiom (`Scrollbar.zig`, overlay mode), reusing its pure thumb arithmetic so
/// the panel and the terminal cannot disagree about where a thumb goes.
pub fn paintScrollThumb(self: *ActivityMonitor, hdc: w32.HDC, l: layout_mod.Layout, visible: i32) void {
    const p = self.pal();
    if (visible <= 0) return;
    if (self.order_len <= @as(usize, @intCast(visible))) return;

    const track_h = l.table_rows.height();
    const t = Scrollbar.thumbRect(
        self.order_len,
        @intCast(self.scroll),
        @intCast(visible),
        track_h,
        thumbMin(self.scale),
    );
    const w = thumbWidth(self.scale);
    fill(hdc, .{
        .left = l.table_rows.right - w,
        .top = l.table_rows.top + t.y,
        .right = l.table_rows.right,
        .bottom = l.table_rows.top + t.y + t.h,
    }, if (self.thumb_drag_dy >= 0) cr(p.boundary_active) else cr(p.boundary));
}

pub fn thumbWidth(scale: f32) i32 {
    return @max(4, @as(i32, @intFromFloat(@round(8 * scale))));
}

pub fn thumbMin(scale: f32) i32 {
    return @max(8, @as(i32, @intFromFloat(@round(20 * scale))));
}

/// The layout column the current sort key maps to.
pub fn sortKeyColumn(self: *const ActivityMonitor) layout_mod.Column {
    return switch (self.sort.key) {
        .pid => .pid,
        .name => .name,
        .cpu => .cpu,
        .mem => .mem,
        .path => .path,
    };
}

/// The sort key a table column maps to. The inverse of `sortKeyColumn`.
pub fn columnSortKey(col: layout_mod.Column) rows_mod.SortKey {
    return switch (col) {
        .pid => .pid,
        .name => .name,
        .cpu => .cpu,
        .mem => .mem,
        .path => .path,
    };
}

/// Which header column contains `x`, given the column widths. Pure —
/// unit-tested.
pub fn columnAt(table: layout_mod.Rect, widths: [layout_mod.column_count]i32, x: i32) ?layout_mod.Column {
    if (x < table.left) return null;
    var left = table.left;
    for (widths, 0..) |w, i| {
        if (x >= left and x < left + w) return @enumFromInt(i);
        left += w;
    }
    return null;
}

// ---------------------------------------------------------------------
// Tests (pure logic only)
// ---------------------------------------------------------------------

const testing = std.testing;

test "columnAt: every column hits, and the gutters outside the table miss" {
    const table: layout_mod.Rect = .{ .left = 10, .top = 0, .right = 210, .bottom = 100 };
    const widths = [layout_mod.column_count]i32{ 20, 40, 30, 50, 60 };

    try testing.expect(columnAt(table, widths, 5) == null); // left of the table
    try testing.expectEqual(layout_mod.Column.pid, columnAt(table, widths, 10).?);
    try testing.expectEqual(layout_mod.Column.pid, columnAt(table, widths, 29).?);
    try testing.expectEqual(layout_mod.Column.name, columnAt(table, widths, 30).?);
    try testing.expectEqual(layout_mod.Column.cpu, columnAt(table, widths, 70).?);
    try testing.expectEqual(layout_mod.Column.mem, columnAt(table, widths, 100).?);
    try testing.expectEqual(layout_mod.Column.path, columnAt(table, widths, 150).?);
    try testing.expectEqual(layout_mod.Column.path, columnAt(table, widths, 209).?);
    try testing.expect(columnAt(table, widths, 210) == null); // past the last column
}

test "columnSortKey round-trips every column" {
    // A header click maps a column to a sort key; the arrow maps it back. The
    // two must agree, or the arrow lands on a different column than the one the
    // table is ordered by.
    for (0..layout_mod.column_count) |i| {
        const col: layout_mod.Column = @enumFromInt(i);
        const key = columnSortKey(col);
        const back: layout_mod.Column = switch (key) {
            .pid => .pid,
            .name => .name,
            .cpu => .cpu,
            .mem => .mem,
            .path => .path,
        };
        try testing.expectEqual(col, back);
    }
}
