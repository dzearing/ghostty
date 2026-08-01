//! Pure layout for the win32 Activity Monitor panel (T284, the arithmetic half
//! of T226).
//!
//! Mac's `RemoteActivityMonitorView` is a vertical stack — a machine-card
//! carousel, two trend gauges, a control bar, a selectable process table, and a
//! conditional error banner — in a **resizable** window (`minWidth: 620,
//! minHeight: 380`, opened at 700x480 by `RemoteActivityMonitor.swift:165`).
//! Unlike the chooser, which is a fixed 840x540, everything here is a function
//! of the current client size, so `layout()` takes it.
//!
//! Everything is arithmetic on a DPI scale, so it runs in the none-runtime test
//! lane; `ActivityMonitor.zig` (T285) keeps the HWNDs and the GDI calls. The
//! `Rect` type is local rather than `w32.RECT` for exactly that reason — the
//! same split as `chooser_layout.zig` / `MachineChooser.zig`.
//!
//! Design-system notes (`docs/design/win32-design-system.md`), because every
//! number here is a decision:
//!
//!   * Mac's ad-hoc 10 pt paddings are **snapped to the 4 DIP scale** — §1
//!     admits 2/4/8/12/16/24 and nothing else, so a 10 becomes `md` (8) for
//!     control rows and the header keeps Mac's 12 (`lg`).
//!   * The separators are 1 px hairlines, matching the sibling dialog
//!     (`chooser_layout.zig`'s `header_divider_y` / `footer_divider_y`). §5's
//!     2 DIP band is about the draggable split lines BETWEEN PANES, where a
//!     vanishing line costs the user a grab target; an intra-dialog rule has no
//!     grab band and reads as a rule at 1 px.
//!   * The table is the only region that absorbs slack. Every other band is a
//!     fixed height, so growing the window grows the row count and nothing
//!     else — which is what a process table is for.

const std = @import("std");

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

/// Mac's window bounds, in DIP (`RemoteActivityMonitor.swift:165`,
/// `RemoteActivityMonitorView.swift:760`).
pub const min_client_w: f32 = 620;
pub const min_client_h: f32 = 380;
pub const default_client_w: f32 = 700;
pub const default_client_h: f32 = 480;

/// Dialog content inset (`xl`) — the horizontal margin every band uses.
const pad_x: f32 = 16;
/// Group separation (`md`) — the default vertical padding and control gap.
const pad_md: f32 = 8;
/// Card outer margin (`lg`) — the gauges' vertical padding, Mac's own 12.
const pad_lg: f32 = 12;
/// The default control-to-control gap (`sm`).
const pad_sm: f32 = 4;

/// One machine card, painted (Mac: a 160x56 content frame plus 10/6 padding).
pub const card_w: f32 = 180;
pub const card_h: f32 = 68;

/// Height of a gauge's chart area (Mac: `TrendGaugeView.chartHeight`).
pub const chart_h: f32 = 64;
/// Height of the gauge's title/value line above its chart.
const gauge_title_h: f32 = 24;

/// One row of the control bar — filter field and buttons share it, so they
/// cannot round apart (§1: two heights that are equal in DIP come from one
/// constant).
const control_h: f32 = 28;
/// The filter field never grows past this (Mac: `.frame(maxWidth: 240)`), and
/// never shrinks below this — it is a `maxWidth` on Mac, so the field yields
/// first when the bar is under pressure, but a 40-px-wide text box is not a
/// text box.
const filter_max_w: f32 = 240;
const filter_min_w: f32 = 120;
const show_all_w: f32 = 96;
const count_w: f32 = 110;
const kill_w: f32 = 96;
const new_proc_w: f32 = 124;

/// Process-table metrics.
pub const table_header_h: f32 = 24;
pub const table_row_h: f32 = 22;
/// Text inset inside a table cell, so adjacent columns never touch (§0.1).
pub const cell_pad: f32 = 8;

/// Error-banner text line.
const banner_text_h: f32 = 20;

/// What the panel is currently showing. Bands that are absent take no height
/// at all rather than collapsing to a sliver.
pub const Options = struct {
    /// The machine-card carousel. Hidden when the panel has a single source
    /// (§6: chrome that controls nothing does not appear).
    has_carousel: bool = true,
    /// The dismissable action-error banner under the table.
    has_banner: bool = false,
    /// The Kill button, which Mac shows only while rows are selected.
    has_kill: bool = false,
};

/// Every region the panel places, in physical pixels from the client origin.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,

    /// The machine-card carousel (zero-height when `has_carousel` is false).
    carousel: Rect,
    carousel_divider_y: i32,

    /// The gauge band and the two gauges that split it 50/50.
    header: Rect,
    gauge_cpu: Rect,
    gauge_mem: Rect,
    /// The chart area inside a gauge, relative to that gauge's own left/top:
    /// add the gauge's origin. Height is `chart_h`.
    gauge_chart_dy: i32,
    header_divider_y: i32,

    /// The control bar and its contents, left to right.
    control: Rect,
    filter: Rect,
    show_all: Rect,
    /// The status badge slot between the checkbox and the right-hand group
    /// ("List truncated" / "Refresh failed"). Empty when there is no slack.
    badge: Rect,
    count: Rect,
    /// Zero-width when `has_kill` is false.
    kill_btn: Rect,
    new_proc_btn: Rect,
    control_divider_y: i32,

    /// The process table: a header row, then the rows.
    table: Rect,
    table_header: Rect,
    table_rows: Rect,
    row_h: i32,

    /// The action-error banner (zero-height when `has_banner` is false).
    banner: Rect,
    /// The banner's dismiss button, at its trailing edge.
    banner_close: Rect,

    /// `CreateFontW` heights (positive; the caller negates them).
    font_h: i32,
    title_font_h: i32,
    caption_font_h: i32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// The smallest client the panel may be resized to, in physical pixels.
pub fn minClient(scale: f32) struct { w: i32, h: i32 } {
    return .{ .w = px(min_client_w, scale), .h = px(min_client_h, scale) };
}

/// The client the panel opens at, in physical pixels.
pub fn defaultClient(scale: f32) struct { w: i32, h: i32 } {
    return .{ .w = px(default_client_w, scale), .h = px(default_client_h, scale) };
}

/// Panel layout at `scale` for a client of `client_w` x `client_h` physical
/// pixels. A client smaller than `minClient` is treated as the minimum, so a
/// caller that has not clamped its window yet still gets a coherent layout
/// instead of inverted rects. Pure — unit-tested.
pub fn layout(scale: f32, client_w_in: i32, client_h_in: i32, opts: Options) Layout {
    const min = minClient(scale);
    const client_w = @max(client_w_in, min.w);
    const client_h = @max(client_h_in, min.h);

    const margin = px(pad_x, scale);
    const gap = px(pad_md, scale);
    const divider = 1;

    // --- Carousel -------------------------------------------------------
    const carousel_h = if (opts.has_carousel) gap + px(card_h, scale) + gap else 0;
    const carousel: Rect = .{ .left = 0, .top = 0, .right = client_w, .bottom = carousel_h };
    // A hidden carousel takes its rule with it: two rules stacked on nothing
    // is exactly the "chrome that controls nothing" §6 forbids.
    const carousel_divider_y = if (opts.has_carousel) carousel_h else -1;
    const header_top = if (opts.has_carousel) carousel_h + divider else 0;

    // --- Gauges ---------------------------------------------------------
    const gauge_h = px(gauge_title_h, scale) + px(pad_sm, scale) + px(chart_h, scale);
    const header_pad_v = px(pad_lg, scale);
    const header: Rect = .{
        .left = 0,
        .top = header_top,
        .right = client_w,
        .bottom = header_top + header_pad_v + gauge_h + header_pad_v,
    };
    // 50/50 across the band with `xl` between them, Mac's `spacing: 16`.
    const gauge_gap = margin;
    const gauge_span = client_w - 2 * margin;
    const gauge_w = @divTrunc(gauge_span - gauge_gap, 2);
    const gauge_top = header.top + header_pad_v;
    const gauge_cpu: Rect = .{
        .left = margin,
        .top = gauge_top,
        .right = margin + gauge_w,
        .bottom = gauge_top + gauge_h,
    };
    const gauge_mem: Rect = .{
        // Right-aligned against the trailing margin so an odd `gauge_span`
        // loses its pixel in the middle gap, never off the panel's edge.
        .left = client_w - margin - gauge_w,
        .top = gauge_top,
        .right = client_w - margin,
        .bottom = gauge_top + gauge_h,
    };
    const header_divider_y = header.bottom;

    // --- Control bar ----------------------------------------------------
    const ctl_h = px(control_h, scale);
    const control_top = header.bottom + divider;
    const control: Rect = .{
        .left = 0,
        .top = control_top,
        .right = client_w,
        .bottom = control_top + gap + ctl_h + gap,
    };
    const row_top = control.top + gap;
    const row_bottom = row_top + ctl_h;

    // The right-hand group, laid out from the trailing margin inward so the
    // slack always lands in the middle (where the badge lives).
    const new_proc_btn: Rect = .{
        .left = client_w - margin - px(new_proc_w, scale),
        .top = row_top,
        .right = client_w - margin,
        .bottom = row_bottom,
    };
    const kill_right = new_proc_btn.left - gap;
    const kill_btn: Rect = if (opts.has_kill) .{
        .left = kill_right - px(kill_w, scale),
        .top = row_top,
        .right = kill_right,
        .bottom = row_bottom,
    } else .{
        // Zero-width, parked where it would appear, so a caller that paints it
        // unconditionally draws nothing rather than something misplaced.
        .left = kill_right,
        .top = row_top,
        .right = kill_right,
        .bottom = row_bottom,
    };
    const count_right = if (opts.has_kill) kill_btn.left - gap else new_proc_btn.left - gap;
    const count: Rect = .{
        .left = count_right - px(count_w, scale),
        .top = row_top,
        .right = count_right,
        .bottom = row_bottom,
    };
    // The filter is the only elastic control on the row: the right-hand group
    // and the checkbox are fixed, so the field takes what is left, capped at
    // Mac's 240 and floored so it never becomes a stub.
    const left_span = count.left - gap - margin;
    const filter_w = std.math.clamp(
        left_span - gap - px(show_all_w, scale),
        px(filter_min_w, scale),
        px(filter_max_w, scale),
    );
    const filter: Rect = .{
        .left = margin,
        .top = row_top,
        .right = margin + filter_w,
        .bottom = row_bottom,
    };
    const show_all: Rect = .{
        .left = filter.right + gap,
        .top = row_top,
        .right = filter.right + gap + px(show_all_w, scale),
        .bottom = row_bottom,
    };

    const badge_left = show_all.right + gap;
    const badge_right = count.left - gap;
    const badge: Rect = .{
        .left = badge_left,
        .top = row_top,
        .right = @max(badge_left, badge_right),
        .bottom = row_bottom,
    };
    const control_divider_y = control.bottom;

    // --- Banner (bottom-anchored) ---------------------------------------
    const banner_h = if (opts.has_banner) gap + px(banner_text_h, scale) + gap else 0;
    const banner: Rect = .{
        .left = 0,
        .top = client_h - banner_h,
        .right = client_w,
        .bottom = client_h,
    };
    const banner_btn = px(banner_text_h, scale);
    const banner_close: Rect = if (opts.has_banner) .{
        .left = client_w - margin - banner_btn,
        .top = banner.top + gap,
        .right = client_w - margin,
        .bottom = banner.top + gap + banner_btn,
    } else .{ .left = client_w - margin, .top = banner.top, .right = client_w - margin, .bottom = banner.top };

    // --- Table: everything that is left ---------------------------------
    const table_top = control.bottom + divider;
    const table: Rect = .{
        .left = 0,
        .top = table_top,
        .right = client_w,
        .bottom = @max(table_top, banner.top),
    };
    const header_h = px(table_header_h, scale);
    const table_header: Rect = .{
        .left = table.left,
        .top = table.top,
        .right = table.right,
        .bottom = @min(table.bottom, table.top + header_h),
    };
    const table_rows: Rect = .{
        .left = table.left,
        .top = table_header.bottom,
        .right = table.right,
        .bottom = table.bottom,
    };

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .carousel = carousel,
        .carousel_divider_y = carousel_divider_y,
        .header = header,
        .gauge_cpu = gauge_cpu,
        .gauge_mem = gauge_mem,
        .gauge_chart_dy = px(gauge_title_h, scale) + px(pad_sm, scale),
        .header_divider_y = header_divider_y,
        .control = control,
        .filter = filter,
        .show_all = show_all,
        .badge = badge,
        .count = count,
        .kill_btn = kill_btn,
        .new_proc_btn = new_proc_btn,
        .control_divider_y = control_divider_y,
        .table = table,
        .table_header = table_header,
        .table_rows = table_rows,
        .row_h = px(table_row_h, scale),
        .banner = banner,
        .banner_close = banner_close,
        .font_h = px(15, scale),
        .title_font_h = px(20, scale),
        .caption_font_h = px(12, scale),
    };
}

/// How many whole rows fit in the table's row area.
pub fn visibleRows(l: Layout) i32 {
    if (l.row_h <= 0) return 0;
    return @divTrunc(l.table_rows.height(), l.row_h);
}

/// The row index under `y` (client coordinates) given the current scroll
/// offset in rows, or null when `y` is outside the row area. Callers still
/// have to bounds-check against their own row count.
pub fn rowIndexAt(l: Layout, y: i32, scroll_rows: i32) ?i32 {
    if (l.row_h <= 0) return null;
    if (y < l.table_rows.top or y >= l.table_rows.bottom) return null;
    return scroll_rows + @divTrunc(y - l.table_rows.top, l.row_h);
}

/// The painted rect of the carousel card at `index`, given the carousel's
/// horizontal scroll offset in pixels. Cards keep `md` between them.
pub fn cardRect(l: Layout, index: i32, scroll_x: i32, scale: f32) Rect {
    const margin = px(pad_x, scale);
    const gap = px(pad_md, scale);
    const w = px(card_w, scale);
    const left = l.carousel.left + margin - scroll_x + index * (w + gap);
    return .{
        .left = left,
        .top = l.carousel.top + gap,
        .right = left + w,
        .bottom = l.carousel.top + gap + px(card_h, scale),
    };
}

/// One card's interior: the status dot and the three text lines Mac's
/// `MachineCard` stacks (:1436-1460).
pub const CardContent = struct {
    dot: Rect,
    label: Rect,
    summary: Rect,
    metric: Rect,
};

/// The dot's diameter (Mac's 7pt circle, rounded onto the 4 DIP scale's
/// neighbour so it stays even and centers without a half pixel).
const card_dot: f32 = 8;
/// The three text rows. `label` carries `font_h` (15) and the two detail rows
/// carry `caption_font_h` (12), each in a line box with room to sit in.
const card_label_h: f32 = 18;
const card_detail_h: f32 = 14;

/// Lay out one card's contents inside its painted rect. The text block is
/// CENTERED vertically, so the padding above and below it is symmetric by
/// construction rather than by a pair of constants that have to be kept equal
/// (§0.3). Pure — unit-tested.
pub fn cardContent(card: Rect, scale: f32) CardContent {
    const pad = px(pad_md, scale);
    const gap = px(pad_sm, scale);
    const dot_d = px(card_dot, scale);
    const label_h = px(card_label_h, scale);
    const detail_h = px(card_detail_h, scale);

    const block_h = label_h + gap + detail_h + gap + detail_h;
    const top = card.top + @divTrunc(card.height() - block_h, 2);
    const text_left = card.left + pad + dot_d + pad;
    const right = card.right - pad;

    return .{
        .dot = .{
            .left = card.left + pad,
            .top = top + @divTrunc(label_h - dot_d, 2),
            .right = card.left + pad + dot_d,
            .bottom = top + @divTrunc(label_h - dot_d, 2) + dot_d,
        },
        .label = .{ .left = text_left, .top = top, .right = right, .bottom = top + label_h },
        .summary = .{
            .left = card.left + pad,
            .top = top + label_h + gap,
            .right = right,
            .bottom = top + label_h + gap + detail_h,
        },
        .metric = .{
            .left = card.left + pad,
            .top = top + label_h + gap + detail_h + gap,
            .right = right,
            .bottom = top + block_h,
        },
    };
}

/// The carousel's own left/right inset — the gap a scrolled-into-view card
/// keeps from the band's edge, so the same number that PLACES the first card is
/// the one that stops the last one from touching the edge (§0.1).
pub fn cardMargin(scale: f32) i32 {
    return px(pad_x, scale);
}

/// The index of the card under `(x, y)`, or null when the point is in the
/// carousel's padding or outside it. Cards are hit on their PAINTED rect, so
/// the gap between two cards belongs to neither (§0.2).
pub fn cardIndexAt(l: Layout, count: i32, x: i32, y: i32, scroll_x: i32, scale: f32) ?i32 {
    if (count <= 0) return null;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const r = cardRect(l, i, scroll_x, scale);
        if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return i;
    }
    return null;
}

/// The full width one carousel scroll extent needs for `count` cards.
pub fn carouselContentWidth(count: i32, scale: f32) i32 {
    if (count <= 0) return 0;
    const w = px(card_w, scale);
    const gap = px(pad_md, scale);
    return 2 * px(pad_x, scale) + count * w + (count - 1) * gap;
}

// ---------------------------------------------------------------------
// Process-table columns
// ---------------------------------------------------------------------

pub const Column = enum(usize) {
    pid = 0,
    name = 1,
    cpu = 2,
    mem = 3,
    path = 4,
};

pub const column_count = 5;

pub const ColumnSpec = struct {
    title: []const u8,
    /// DIP. `max = 0` means unbounded.
    min: f32,
    ideal: f32,
    max: f32,
    right_align: bool,
};

/// Mac's `TableColumn` widths, `RemoteActivityMonitorView.swift:986-1024`.
pub const column_specs = [column_count]ColumnSpec{
    .{ .title = "PID", .min = 50, .ideal = 60, .max = 80, .right_align = false },
    .{ .title = "Name", .min = 120, .ideal = 200, .max = 0, .right_align = false },
    .{ .title = "% CPU", .min = 60, .ideal = 70, .max = 90, .right_align = true },
    .{ .title = "Memory", .min = 70, .ideal = 90, .max = 110, .right_align = true },
    .{ .title = "Path", .min = 120, .ideal = 240, .max = 0, .right_align = false },
};

/// Column widths for a table `table_w` physical pixels wide.
///
/// Every column starts at its ideal, then the difference is distributed
/// proportionally and re-distributed around whatever a min/max refused, so the
/// widths **sum exactly to `table_w`** — the one property the painter depends
/// on, since it walks the array to place cell rects.
///
/// The single exception is a table narrower than the sum of the minimums
/// (possible only below `min_client_w`): the minimums win and the caller
/// clips, because a 12-px-wide PID column is worse than a cut-off Path.
pub fn columnWidths(scale: f32, table_w: i32) [column_count]i32 {
    var w: [column_count]i32 = undefined;
    var lo: [column_count]i32 = undefined;
    var hi: [column_count]i32 = undefined;
    var total: i32 = 0;
    for (column_specs, 0..) |c, i| {
        w[i] = px(c.ideal, scale);
        lo[i] = px(c.min, scale);
        hi[i] = if (c.max == 0) std.math.maxInt(i32) else px(c.max, scale);
        total += w[i];
    }

    // Proportional pass. Growing weights by IDEAL (so the two unbounded
    // columns do not swallow everything just because their headroom is
    // infinite); shrinking weights by the room a column actually has left.
    var iter: usize = 0;
    while (total != table_w and iter < 8) : (iter += 1) {
        const delta = table_w - total;
        var weight: [column_count]i64 = undefined;
        var wsum: i64 = 0;
        for (0..column_count) |i| {
            weight[i] = if (delta > 0)
                (if (w[i] < hi[i]) @as(i64, px(column_specs[i].ideal, scale)) else 0)
            else
                @as(i64, w[i]) - lo[i];
            if (weight[i] < 0) weight[i] = 0;
            wsum += weight[i];
        }
        if (wsum <= 0) break;

        var moved: i32 = 0;
        for (0..column_count) |i| {
            if (weight[i] == 0) continue;
            const share: i32 = @intCast(@divTrunc(@as(i64, delta) * weight[i], wsum));
            const nw = std.math.clamp(w[i] + share, lo[i], hi[i]);
            moved += nw - w[i];
            w[i] = nw;
        }
        total += moved;
        if (moved == 0) break;
    }

    // Exact fixup — integer division always leaves a few pixels. Flexible
    // columns take them first, so Path absorbs the remainder the way it
    // absorbs the slack.
    const order = [column_count]usize{
        @intFromEnum(Column.path),
        @intFromEnum(Column.name),
        @intFromEnum(Column.mem),
        @intFromEnum(Column.cpu),
        @intFromEnum(Column.pid),
    };
    while (total != table_w) {
        const step: i32 = if (total < table_w) 1 else -1;
        var progressed = false;
        for (order) |i| {
            const nw = w[i] + step;
            if (nw < lo[i] or nw > hi[i]) continue;
            w[i] = nw;
            total += step;
            progressed = true;
            break;
        }
        if (!progressed) break;
    }

    return w;
}

/// The rect of one cell in a row, given the row's rect and the column widths.
/// `cell_pad` is applied to both sides, so the text of two adjacent columns
/// keeps a full `md` between painted glyphs (§0.1).
pub fn cellRect(row: Rect, widths: [column_count]i32, col: Column, scale: f32) Rect {
    const pad = px(cell_pad, scale);
    var left = row.left;
    for (0..@intFromEnum(col)) |i| left += widths[i];
    const right = left + widths[@intFromEnum(col)];
    return .{
        .left = left + pad,
        .top = row.top,
        .right = @max(left + pad, right - pad),
        .bottom = row.bottom,
    };
}

/// The x of the divider on the trailing edge of `col`, for painting column
/// separators and for hit-testing a drag.
pub fn columnDividerX(table: Rect, widths: [column_count]i32, col: Column) i32 {
    var x = table.left;
    for (0..@intFromEnum(col) + 1) |i| x += widths[i];
    return x;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// Every scale the design system asks chrome to be asserted at — most of these
/// defects are invisible at 1.0 and obvious at 1.25.
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

fn defaultLayout(scale: f32) Layout {
    const d = defaultClient(scale);
    return layout(scale, d.w, d.h, .{});
}

test "layout: opens at Mac's 700x480 and clamps to its 620x380 minimum" {
    const l = defaultLayout(1.0);
    try testing.expectEqual(@as(i32, 700), l.client_w);
    try testing.expectEqual(@as(i32, 480), l.client_h);

    // Anything smaller than the minimum is treated as the minimum rather than
    // producing inverted rects.
    const tiny = layout(1.0, 100, 50, .{});
    try testing.expectEqual(@as(i32, 620), tiny.client_w);
    try testing.expectEqual(@as(i32, 380), tiny.client_h);
    try testing.expect(tiny.table.height() > 0);
    try testing.expect(tiny.table_rows.height() >= 0);
}

test "layout: the bands stack in Mac's order and never overlap" {
    for (scales) |scale| {
        const l = layout(scale, defaultClient(scale).w, defaultClient(scale).h, .{ .has_banner = true, .has_kill = true });
        try testing.expectEqual(@as(i32, 0), l.carousel.top);
        try testing.expect(l.carousel.bottom <= l.carousel_divider_y);
        try testing.expect(l.header.top > l.carousel.bottom);
        try testing.expect(l.control.top > l.header.bottom);
        try testing.expect(l.table.top > l.control.bottom);
        try testing.expect(l.banner.top >= l.table.bottom);
        try testing.expectEqual(l.client_h, l.banner.bottom);
        // The rules sit ON the seams, one per seam.
        try testing.expectEqual(l.header.bottom, l.header_divider_y);
        try testing.expectEqual(l.control.bottom, l.control_divider_y);
    }
}

test "layout: only the table absorbs slack" {
    const small = layout(1.0, 700, 480, .{});
    const tall = layout(1.0, 700, 800, .{});
    try testing.expectEqual(small.carousel.height(), tall.carousel.height());
    try testing.expectEqual(small.header.height(), tall.header.height());
    try testing.expectEqual(small.control.height(), tall.control.height());
    try testing.expectEqual(small.table.height() + 320, tall.table.height());
    // Extra height becomes rows, which is the entire point of a process table.
    try testing.expect(visibleRows(tall) > visibleRows(small));
}

test "layout: a hidden carousel takes its rule with it" {
    const with = layout(1.0, 700, 480, .{ .has_carousel = true });
    const without = layout(1.0, 700, 480, .{ .has_carousel = false });
    try testing.expect(with.carousel.height() > 0);
    try testing.expectEqual(@as(i32, 0), without.carousel.height());
    try testing.expect(without.carousel_divider_y < 0);
    try testing.expectEqual(@as(i32, 0), without.header.top);
    // The room goes to the table, not to a gap.
    try testing.expectEqual(
        with.table.height() + with.carousel.height() + 1,
        without.table.height(),
    );
}

test "layout: an absent banner takes no height and an absent Kill no width" {
    const plain = layout(1.0, 700, 480, .{});
    try testing.expectEqual(@as(i32, 0), plain.banner.height());
    try testing.expectEqual(@as(i32, 0), plain.kill_btn.width());
    try testing.expectEqual(plain.client_h, plain.table.bottom);

    const loud = layout(1.0, 700, 480, .{ .has_banner = true, .has_kill = true });
    try testing.expect(loud.banner.height() > 0);
    try testing.expect(loud.kill_btn.width() > 0);
    // The banner comes out of the table, never off the bottom of the window.
    try testing.expectEqual(loud.client_h, loud.banner.bottom);
    try testing.expectEqual(loud.banner.top, loud.table.bottom);
    try testing.expectEqual(plain.table.height() - loud.banner.height(), loud.table.height());
}

test "layout: the two gauges split the band 50/50 with a margin either side" {
    for (scales) |scale| {
        const l = defaultLayout(scale);
        try testing.expectEqual(l.gauge_cpu.width(), l.gauge_mem.width());
        try testing.expectEqual(l.gauge_cpu.top, l.gauge_mem.top);
        try testing.expectEqual(l.gauge_cpu.bottom, l.gauge_mem.bottom);
        // Equal margins, and the odd pixel lands in the middle gap.
        const margin = px(pad_x, scale);
        try testing.expectEqual(margin, l.gauge_cpu.left);
        try testing.expectEqual(margin, l.client_w - l.gauge_mem.right);
        try testing.expect(l.gauge_mem.left - l.gauge_cpu.right >= margin);
        // Both nest inside the header band.
        try testing.expect(l.gauge_cpu.top >= l.header.top);
        try testing.expect(l.gauge_mem.bottom <= l.header.bottom);
        // The chart sits under the title line and fills the rest of the gauge.
        try testing.expectEqual(
            px(chart_h, scale),
            l.gauge_cpu.height() - l.gauge_chart_dy,
        );
    }
}

test "layout: control bar runs filter -> show all -> badge -> count -> kill -> new" {
    for (scales) |scale| {
        const d = defaultClient(scale);
        const l = layout(scale, d.w, d.h, .{ .has_kill = true });
        const gap = px(pad_md, scale);
        const items = [_]Rect{ l.filter, l.show_all, l.badge, l.count, l.kill_btn, l.new_proc_btn };
        var prev: ?Rect = null;
        for (items) |r| {
            // One shared row: every control on the same frame (§2.1).
            try testing.expectEqual(l.filter.top, r.top);
            try testing.expectEqual(l.filter.bottom, r.bottom);
            // Inside the band, with the padding above and below.
            try testing.expect(r.top >= l.control.top + gap);
            try testing.expect(r.bottom <= l.control.bottom - gap);
            if (prev) |p| try testing.expect(r.left >= p.right);
            prev = r;
        }
        try testing.expectEqual(px(pad_x, scale), l.filter.left);
        try testing.expectEqual(px(pad_x, scale), l.client_w - l.new_proc_btn.right);
    }
}

test "layout: nothing touches anything in the control bar" {
    // §0.1 — every painted control keeps at least one spacing step from its
    // neighbour and from the band's edge. The badge is allowed to be empty,
    // and an empty rect has no painted edge to violate the rule.
    for (scales) |scale| {
        const d = defaultClient(scale);
        const l = layout(scale, d.w, d.h, .{ .has_kill = true });
        const step = px(pad_sm, scale);
        const painted = [_]Rect{ l.filter, l.show_all, l.count, l.kill_btn, l.new_proc_btn };
        var prev: ?Rect = null;
        for (painted) |r| {
            if (r.width() == 0) continue;
            if (prev) |p| try testing.expect(r.left - p.right >= step);
            prev = r;
        }
    }
}

test "layout: the filter is the control bar's elastic control" {
    // Wide enough for everything: the field sits at Mac's 240 cap and the
    // badge slot takes the slack.
    const wide = layout(1.0, 1600, 480, .{ .has_kill = true });
    try testing.expectEqual(@as(i32, 240), wide.filter.width());
    try testing.expect(wide.badge.width() > 100);

    // At the minimum client the row still fits, in order, with the field
    // shrunk rather than anything overlapping.
    const tight = layout(1.0, 620, 380, .{ .has_kill = true });
    try testing.expect(tight.filter.width() < 240);
    try testing.expect(tight.filter.width() >= 120);
    try testing.expect(tight.show_all.left >= tight.filter.right + 4);
    try testing.expect(tight.count.left >= tight.show_all.right + 4);
    try testing.expect(tight.kill_btn.left >= tight.count.right + 4);
    try testing.expect(tight.new_proc_btn.left >= tight.kill_btn.right + 4);
    try testing.expectEqual(@as(i32, 620 - 16), tight.new_proc_btn.right);

    // The field never grows past the cap however wide the window gets.
    var w: i32 = 620;
    while (w <= 3000) : (w += 37) {
        const l = layout(1.0, w, 480, .{ .has_kill = true });
        try testing.expect(l.filter.width() <= 240);
        try testing.expect(l.filter.width() >= 120);
    }
}

test "layout: hiding Kill closes the gap instead of leaving a hole" {
    const with = layout(1.0, 700, 480, .{ .has_kill = true });
    const without = layout(1.0, 700, 480, .{});
    try testing.expectEqual(with.new_proc_btn.left, without.new_proc_btn.left);
    // The count label slides right into the space Kill vacated.
    try testing.expect(without.count.right > with.count.right);
    try testing.expectEqual(without.new_proc_btn.left - 8, without.count.right);
}

test "layout: every region nests inside the client" {
    for (scales) |scale| {
        inline for (.{
            Options{},
            Options{ .has_banner = true, .has_kill = true },
            Options{ .has_carousel = false },
        }) |opts| {
            const d = defaultClient(scale);
            const l = layout(scale, d.w, d.h, opts);
            const all = [_]Rect{
                l.carousel, l.header,     l.gauge_cpu,    l.gauge_mem, l.control,
                l.filter,   l.show_all,   l.badge,        l.count,     l.kill_btn,
                l.new_proc_btn, l.table,  l.table_header, l.table_rows, l.banner,
                l.banner_close,
            };
            for (all) |r| {
                try testing.expect(r.left >= 0);
                try testing.expect(r.top >= 0);
                try testing.expect(r.right <= l.client_w);
                try testing.expect(r.bottom <= l.client_h);
                try testing.expect(r.width() >= 0);
                try testing.expect(r.height() >= 0);
            }
        }
    }
}

test "layout: the table is a header row plus the rows beneath it" {
    for (scales) |scale| {
        const d = defaultClient(scale);
        const l = layout(scale, d.w, d.h, .{});
        try testing.expectEqual(l.table.top, l.table_header.top);
        try testing.expectEqual(l.table_header.bottom, l.table_rows.top);
        try testing.expectEqual(l.table.bottom, l.table_rows.bottom);
        try testing.expectEqual(px(table_header_h, scale), l.table_header.height());
        try testing.expect(visibleRows(l) >= 5);
    }
}

test "layout: rowIndexAt maps the row area and rejects everything else" {
    const l = layout(1.0, 700, 480, .{});
    try testing.expectEqual(@as(?i32, null), rowIndexAt(l, l.table_header.top, 0));
    try testing.expectEqual(@as(?i32, null), rowIndexAt(l, l.table_rows.bottom, 0));
    try testing.expectEqual(@as(?i32, 0), rowIndexAt(l, l.table_rows.top, 0));
    try testing.expectEqual(@as(?i32, 0), rowIndexAt(l, l.table_rows.top + l.row_h - 1, 0));
    try testing.expectEqual(@as(?i32, 1), rowIndexAt(l, l.table_rows.top + l.row_h, 0));
    // Scrolling offsets the answer without moving the geometry.
    try testing.expectEqual(@as(?i32, 7), rowIndexAt(l, l.table_rows.top, 7));
}

test "cards: laid out left to right with md between painted edges" {
    for (scales) |scale| {
        const d = defaultClient(scale);
        const l = layout(scale, d.w, d.h, .{});
        const a = cardRect(l, 0, 0, scale);
        const b = cardRect(l, 1, 0, scale);
        try testing.expectEqual(px(card_w, scale), a.width());
        try testing.expectEqual(px(card_h, scale), a.height());
        try testing.expectEqual(a.height(), b.height());
        try testing.expectEqual(px(pad_md, scale), b.left - a.right);
        try testing.expectEqual(px(pad_x, scale), a.left - l.carousel.left);
        // Padded top and bottom inside the band, symmetrically (§0.3).
        try testing.expectEqual(a.top - l.carousel.top, l.carousel.bottom - a.bottom);
    }
}

test "cardContent: the text block is centered, and nothing touches" {
    for (scales) |scale| {
        const d = defaultClient(scale);
        const l = layout(scale, d.w, d.h, .{});
        const card = cardRect(l, 0, 0, scale);
        const c = cardContent(card, scale);

        // Symmetric by construction: the padding above the block equals the
        // padding below it (±1 px of integer centering).
        const top_pad = c.label.top - card.top;
        const bot_pad = card.bottom - c.metric.bottom;
        try testing.expect(@abs(top_pad - bot_pad) <= 1);

        // Every painted element clears its neighbour and the card's own edge by
        // at least `sm` (§0.2 measured between PAINTED edges).
        const min_gap = px(pad_sm, scale);
        try testing.expect(c.dot.left - card.left >= min_gap);
        try testing.expect(c.label.left - c.dot.right >= min_gap);
        try testing.expect(card.right - c.label.right >= min_gap);
        try testing.expect(c.summary.top - c.label.bottom >= min_gap);
        try testing.expect(c.metric.top - c.summary.bottom >= min_gap);
        try testing.expect(top_pad >= min_gap);
        try testing.expect(bot_pad >= min_gap);

        // The dot is square and rides the label's optical center.
        try testing.expectEqual(c.dot.width(), c.dot.height());
        try testing.expect(c.dot.top > c.label.top);
        try testing.expect(c.dot.bottom < c.label.bottom);
    }
}

test "cardContent: scales with the card, not with a fixed pixel count" {
    const one = cardContent(cardRect(layout(1.0, 700, 480, .{}), 0, 0, 1.0), 1.0);
    const two = cardContent(cardRect(layout(2.0, 1400, 960, .{}), 0, 0, 2.0), 2.0);
    try testing.expectEqual(one.dot.width() * 2, two.dot.width());
    try testing.expectEqual(one.label.height() * 2, two.label.height());
    try testing.expectEqual(one.summary.height() * 2, two.summary.height());
}

test "cardMargin: the inset that places card 0 is the one the strip ends on" {
    for (scales) |scale| {
        const d = defaultClient(scale);
        const l = layout(scale, d.w, d.h, .{});
        try testing.expectEqual(cardMargin(scale), cardRect(l, 0, 0, scale).left - l.carousel.left);
        try testing.expectEqual(
            carouselContentWidth(3, scale),
            cardRect(l, 2, 0, scale).right + cardMargin(scale),
        );
    }
}

test "cards: hit testing lands on painted rects, and the gap belongs to neither" {
    const l = layout(1.0, 700, 480, .{});
    const a = cardRect(l, 0, 0, 1.0);
    const b = cardRect(l, 1, 0, 1.0);
    try testing.expectEqual(@as(?i32, 0), cardIndexAt(l, 3, a.left, a.top, 0, 1.0));
    try testing.expectEqual(@as(?i32, 1), cardIndexAt(l, 3, b.left + 4, b.top + 4, 0, 1.0));
    try testing.expectEqual(@as(?i32, null), cardIndexAt(l, 3, a.right + 1, a.top, 0, 1.0));
    try testing.expectEqual(@as(?i32, null), cardIndexAt(l, 3, a.left, l.carousel.top, 0, 1.0));
    // Past the end of the real cards is nothing, even inside the band.
    try testing.expectEqual(@as(?i32, null), cardIndexAt(l, 1, b.left + 4, b.top + 4, 0, 1.0));
    // Scrolling moves the hit test with the paint.
    const scrolled = cardRect(l, 1, 40, 1.0);
    try testing.expectEqual(@as(?i32, 1), cardIndexAt(l, 3, scrolled.left + 4, scrolled.top + 4, 40, 1.0));
}

test "cards: the scroll extent covers every card plus both margins" {
    for (scales) |scale| {
        const l = layout(scale, defaultClient(scale).w, defaultClient(scale).h, .{});
        try testing.expectEqual(@as(i32, 0), carouselContentWidth(0, scale));
        const three = carouselContentWidth(3, scale);
        const last = cardRect(l, 2, 0, scale);
        try testing.expectEqual(last.right + px(pad_x, scale), three);
        // Each extra card adds exactly one card plus one gap.
        try testing.expectEqual(
            three + px(card_w, scale) + px(pad_md, scale),
            carouselContentWidth(4, scale),
        );
    }
}

test "columns: widths sum exactly to the table width at every scale" {
    for (scales) |scale| {
        var w: i32 = px(min_client_w, scale);
        while (w <= px(1600, scale)) : (w += 7) {
            const widths = columnWidths(scale, w);
            var sum: i32 = 0;
            for (widths) |x| sum += x;
            try testing.expectEqual(w, sum);
        }
    }
}

test "columns: every min and max is honoured" {
    for (scales) |scale| {
        var w: i32 = px(min_client_w, scale);
        while (w <= px(2400, scale)) : (w += 13) {
            const widths = columnWidths(scale, w);
            for (column_specs, 0..) |c, i| {
                try testing.expect(widths[i] >= px(c.min, scale));
                if (c.max != 0) try testing.expect(widths[i] <= px(c.max, scale));
            }
        }
    }
}

test "columns: slack goes to the unbounded columns, not to the capped ones" {
    const narrow = columnWidths(1.0, 700);
    const wide = columnWidths(1.0, 1600);
    const pid = @intFromEnum(Column.pid);
    const name = @intFromEnum(Column.name);
    const path = @intFromEnum(Column.path);
    try testing.expect(wide[name] > narrow[name]);
    try testing.expect(wide[path] > narrow[path]);
    // PID is capped at 80 DIP and stays there however wide the table gets.
    try testing.expectEqual(@as(i32, 80), wide[pid]);
    try testing.expect(narrow[pid] <= 80);
}

test "columns: a table below the sum of the minimums keeps the minimums" {
    // Only reachable below `min_client_w`; the minimums win and the caller
    // clips rather than painting a 12-px PID column.
    const widths = columnWidths(1.0, 200);
    var sum: i32 = 0;
    for (column_specs, 0..) |c, i| {
        try testing.expectEqual(@as(i32, @intFromFloat(c.min)), widths[i]);
        sum += widths[i];
    }
    try testing.expect(sum > 200);
}

test "columns: at the default width every column is between its min and ideal-or-more" {
    const widths = columnWidths(1.0, 700);
    // 700 exceeds the 660 of ideals, so nothing is squeezed below its ideal.
    for (column_specs, 0..) |c, i| {
        try testing.expect(widths[i] >= @as(i32, @intFromFloat(c.min)));
        if (c.max == 0) try testing.expect(widths[i] >= @as(i32, @intFromFloat(c.ideal)));
    }
}

test "columns: cells are inset so adjacent columns never touch" {
    for (scales) |scale| {
        const d = defaultClient(scale);
        const l = layout(scale, d.w, d.h, .{});
        const widths = columnWidths(scale, l.table.width());
        const row: Rect = .{
            .left = l.table.left,
            .top = l.table_rows.top,
            .right = l.table.right,
            .bottom = l.table_rows.top + l.row_h,
        };
        const pad = px(cell_pad, scale);
        var prev: ?Rect = null;
        inline for (.{ Column.pid, Column.name, Column.cpu, Column.mem, Column.path }) |col| {
            const c = cellRect(row, widths, col, scale);
            try testing.expect(c.left >= l.table.left);
            try testing.expect(c.right <= l.table.right);
            try testing.expectEqual(row.top, c.top);
            try testing.expectEqual(row.bottom, c.bottom);
            if (prev) |p| try testing.expect(c.left - p.right >= 2 * pad);
            prev = c;
        }
        // The last cell ends a pad short of the table's trailing edge.
        try testing.expectEqual(l.table.right - pad, prev.?.right);
    }
}

test "columns: dividers land on the accumulated column edges" {
    const l = layout(1.0, 700, 480, .{});
    const widths = columnWidths(1.0, l.table.width());
    try testing.expectEqual(l.table.left + widths[0], columnDividerX(l.table, widths, .pid));
    try testing.expectEqual(
        l.table.left + widths[0] + widths[1],
        columnDividerX(l.table, widths, .name),
    );
    // The last divider is the table's own trailing edge, since the widths sum
    // to the table width.
    try testing.expectEqual(l.table.right, columnDividerX(l.table, widths, .path));
}

test "layout: scales with DPI" {
    const a = layout(1.0, 700, 480, .{ .has_kill = true, .has_banner = true });
    const b = layout(2.0, 1400, 960, .{ .has_kill = true, .has_banner = true });
    try testing.expectEqual(a.carousel.height() * 2, b.carousel.height());
    try testing.expectEqual(a.header.height() * 2, b.header.height());
    try testing.expectEqual(a.control.height() * 2, b.control.height());
    try testing.expectEqual(a.banner.height() * 2, b.banner.height());
    try testing.expectEqual(a.row_h * 2, b.row_h);
    try testing.expectEqual(a.title_font_h * 2, b.title_font_h);
    // The table gets what is left, so it scales with the rest of the window.
    try testing.expect(b.table.height() >= a.table.height() * 2 - 4);
}
