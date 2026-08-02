//! Pure row model + geometry for the win32 machine chooser's owner-drawn list
//! (T172, the visual half of T140).
//!
//! The chooser used to be a default `LISTBOX` of single-line strings: one
//! full-width system-blue selection bar and "Name  —  host  ·  online" crammed
//! onto one line. Mac's chooser gives every row a real identity — a shape-coded
//! status indicator, a machine glyph, the name, and a dimmed subline — with a
//! rounded accent selection and a hover wash (`MachineChooserView.row(for:)`
//! and `statusIndicator(for:)`).
//!
//! Everything here is platform-free so it runs in the none-runtime test lane:
//! what a row SAYS (title/subtitle/status/glyph), WHERE its pieces sit inside
//! the row rect, and the blended selection/hover colors. `MachineChooser.zig`
//! keeps the GDI calls that paint them.

const std = @import("std");

/// Re-exported so callers get the row palette and its color type from one
/// import.
const color_math = @import("color_math.zig");
pub const Rgb = color_math.Rgb;

/// Shape-coded reachability of a row, mirroring Mac's `statusIndicator`:
/// online is a filled dot, offline a hollow ring, and `none` reserves the
/// column without drawing (the Local row) so every row shares one grid.
pub const Status = enum { none, online, offline };

/// The machine glyph drawn in the icon column. Mac uses SF Symbols
/// (`laptopcomputer` / `server.rack`); we draw the same two silhouettes with
/// GDI primitives, so there is no icon-font dependency to render as tofu.
pub const Glyph = enum { local, server };

/// What one row renders. Slices borrow the device list — valid only as long as
/// the chooser's fetched `Parsed` is alive.
pub const RowText = struct {
    title: []const u8,
    /// Dimmed second line. Empty means the row is single-line.
    subtitle: []const u8,
    status: Status,
    glyph: Glyph,
};

/// The pinned "this machine" row.
pub fn localRow() RowText {
    return .{
        .title = "Local",
        .subtitle = "This machine",
        .status = .none,
        .glyph = .local,
    };
}

/// A relay device row. Mac's `hostnameSubtext` rule: a hostname that is empty
/// or case-insensitively equal to the display name is noise ("MaximusHome" over
/// "(maximushome)"), so it is dropped and the row falls back to naming the
/// device's kind.
pub fn deviceRow(name: []const u8, hostname: ?[]const u8, online: bool) RowText {
    return .{
        .title = name,
        .subtitle = hostnameSubtext(name, hostname) orelse "Relay device",
        .status = if (online) .online else .offline,
        .glyph = .server,
    };
}

/// The hostname worth showing beneath `name`, or null when it adds nothing.
pub fn hostnameSubtext(name: []const u8, hostname: ?[]const u8) ?[]const u8 {
    const h = hostname orelse return null;
    if (h.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(h, name)) return null;
    return h;
}

// ---------------------------------------------------------------------
// Detail pane (T175)
// ---------------------------------------------------------------------

/// What the detail pane's header says about the selected row. `subtitle` may
/// borrow the caller's scratch buffer (see `deviceDetail`).
pub const DetailText = struct {
    title: []const u8,
    subtitle: []const u8,
    glyph: Glyph,
};

/// The local machine's detail header. Mac reads "This Mac" (`detailTitle`,
/// MachineChooserView.swift:511); the Windows-native name for the same thing is
/// what the shell calls it.
pub fn localDetail() DetailText {
    return .{
        .title = "This PC",
        .subtitle = "This machine",
        .glyph = .local,
    };
}

/// A relay device's detail header. Mac's subtitle is "N sessions · hostname";
/// Windows cannot browse a machine's sessions yet (T146), so the leading
/// element is the reachability the directory actually reported, and the
/// hostname follows when it says something the name does not.
///
/// `buf` backs the joined subtitle; the returned slice borrows it (and `name`
/// and `hostname` borrow the caller's device list, as everywhere else here).
pub fn deviceDetail(buf: []u8, name: []const u8, hostname: ?[]const u8, online: bool) DetailText {
    const state: []const u8 = if (online) "Online" else "Offline";
    const host = hostnameSubtext(name, hostname);
    const subtitle: []const u8 = if (host) |h|
        std.fmt.bufPrint(buf, "{s} · {s}", .{ state, h }) catch state
    else
        state;
    return .{ .title = name, .subtitle = subtitle, .glyph = .server };
}

// ---------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------

/// Where each piece of a row sits, in physical pixels relative to the row's
/// own rect (`x` values from the row's left edge, `y` values from its top).
///
/// The row is a fixed-height owner-drawn item: `height` is what the listbox is
/// told via `WM_MEASUREITEM`, and every other field must nest inside it.
pub const RowMetrics = struct {
    height: i32,
    /// Inset of the rounded selection/hover fill from the row's edges, so the
    /// highlight reads as a rounded pill inside a gutter — never the
    /// edge-to-edge system bar the user screenshotted.
    fill_inset_x: i32,
    fill_inset_y: i32,
    fill_radius: i32,
    /// Status indicator: a `dot_d`-diameter circle centered on `status_cx`.
    status_cx: i32,
    status_cy: i32,
    dot_d: i32,
    /// Machine glyph box.
    glyph_x: i32,
    glyph_y: i32,
    glyph_w: i32,
    glyph_h: i32,
    /// Text column (both lines share the left edge; the right edge is the
    /// row's own width minus `text_pad_right`).
    text_x: i32,
    text_pad_right: i32,
    title_y: i32,
    title_h: i32,
    subtitle_y: i32,
    subtitle_h: i32,
    /// Point size (as a negative `CreateFontW` height) for the subtitle, which
    /// is a notch smaller than the dialog font like Mac's `.caption`.
    subtitle_font_h: i32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Row geometry at `scale` (the owner window's DPI scale). Pure — tested.
pub fn rowMetrics(scale: f32) RowMetrics {
    const fill_inset_x = px(4, scale);
    const fill_inset_y = px(1, scale);

    const status_left = fill_inset_x + px(8, scale);
    const status_col_w = px(12, scale);
    const dot_d = px(8, scale);

    const glyph_x = status_left + status_col_w + px(6, scale);
    const glyph_w = px(20, scale);

    const title_y = px(7, scale);
    const title_h = px(17, scale);
    const subtitle_y = title_y + title_h + px(2, scale);
    const subtitle_h = px(14, scale);
    const height = subtitle_y + subtitle_h + px(4, scale);

    const glyph_h = px(16, scale);

    return .{
        .height = height,
        .fill_inset_x = fill_inset_x,
        .fill_inset_y = fill_inset_y,
        .fill_radius = px(6, scale),
        .status_cx = status_left + @divTrunc(status_col_w, 2),
        .status_cy = @divTrunc(height, 2),
        .dot_d = dot_d,
        .glyph_x = glyph_x,
        .glyph_y = @divTrunc(height - glyph_h, 2),
        .glyph_w = glyph_w,
        .glyph_h = glyph_h,
        .text_x = glyph_x + glyph_w + px(10, scale),
        .text_pad_right = px(10, scale),
        .title_y = title_y,
        .title_h = title_h,
        .subtitle_y = subtitle_y,
        .subtitle_h = subtitle_h,
        .subtitle_font_h = px(12, scale),
    };
}

/// Clamp a measured footer-hint line count to what the dialog will render. One
/// line minimum (the control keeps its slot so the layout never jumps), four
/// maximum (a runaway error string must not grow the dialog without bound).
pub const max_hint_lines: i32 = 4;

pub fn clampHintLines(measured: i32) i32 {
    if (measured < 1) return 1;
    if (measured > max_hint_lines) return max_hint_lines;
    return measured;
}

// ---------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------

/// Alpha-composite `fg` over `bg`. GDI has no alpha for these primitives, so
/// the blend is done up front and drawn as an opaque color (the same trick
/// `banner_card.zig` uses for the glass card).
pub fn blend(bg: Rgb, fg: Rgb, alpha: f64) Rgb {
    return color_math.mix(bg, fg, alpha);
}

/// Mac's `.green` for an online device.
pub const online_green: Rgb = .{ .r = 0x34, .g = 0xC7, .b = 0x59 };
/// The "secondary" gray Mac uses for offline rings, glyphs and sublines.
pub const secondary_gray: Rgb = .{ .r = 0x99, .g = 0x99, .b = 0x99 };

/// Selection fill: the accent at Mac's 0.25 over the row background.
///
/// `accent` is a PARAMETER since T305. It used to be a `pub const` here
/// spelling `#3D8EF8` — a blue nobody picked, and a second one
/// (`RGB(80,160,235)`) lived in `ActivityMonitor.zig`. Callers pass
/// `system_colors.accentCached()`, already floored to 3:1 against the surface
/// by `chrome_theme.resolve`, so this module composites and never clamps.
pub fn selectionFill(bg: Rgb, accent: Rgb) Rgb {
    return blend(bg, accent, 0.25);
}

/// Selection border — a stronger accent so the highlighted row still reads as
/// selected against a dark background at low fill opacity.
pub fn selectionBorder(bg: Rgb, accent: Rgb) Rgb {
    return blend(bg, accent, 0.7);
}

/// Hover wash: Mac's `Color.primary.opacity(0.06)`. `Color.primary` is white
/// on a dark surface and BLACK on a light one, so this is `color_math.wash`,
/// not a blend toward a hardcoded white — that literal was the same defect as
/// the strip's `background + 20`, one surface further in.
pub fn hoverFill(bg: Rgb) Rgb {
    return color_math.wash(bg, 0.06);
}

/// The master column's backing wash — Mac's `Color.primary.opacity(0.035)`
/// behind the machine list (MachineChooserView.swift:260). Faint on purpose:
/// it separates the column from the detail pane without becoming a panel.
pub fn columnWash(bg: Rgb) Rgb {
    return color_math.wash(bg, 0.035);
}

/// The hairline rules between the account row, the two columns and the footer
/// (Mac's `Divider()`).
pub fn dividerColor(bg: Rgb) Rgb {
    return color_math.wash(bg, 0.14);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "localRow: pinned this-machine row, no status shape" {
    const r = localRow();
    try testing.expectEqualStrings("Local", r.title);
    try testing.expectEqualStrings("This machine", r.subtitle);
    try testing.expectEqual(Status.none, r.status);
    try testing.expectEqual(Glyph.local, r.glyph);
}

test "deviceRow: hostname becomes the subline, online drives the shape" {
    const r = deviceRow("Winbox", "winbox.local", true);
    try testing.expectEqualStrings("Winbox", r.title);
    try testing.expectEqualStrings("winbox.local", r.subtitle);
    try testing.expectEqual(Status.online, r.status);
    try testing.expectEqual(Glyph.server, r.glyph);

    const off = deviceRow("Winbox", "winbox.local", false);
    try testing.expectEqual(Status.offline, off.status);
}

test "deviceRow: a redundant or missing hostname falls back, never blank" {
    // Case-insensitively equal to the name -> noise, per Mac's hostnameSubtext.
    try testing.expectEqualStrings("Relay device", deviceRow("MaximusHome", "maximushome", true).subtitle);
    try testing.expectEqualStrings("Relay device", deviceRow("Winbox", null, true).subtitle);
    try testing.expectEqualStrings("Relay device", deviceRow("Winbox", "", true).subtitle);
}

test "hostnameSubtext: keeps a genuinely different hostname" {
    try testing.expectEqualStrings("prod-1.internal", hostnameSubtext("Alpha", "prod-1.internal").?);
    try testing.expect(hostnameSubtext("Alpha", "ALPHA") == null);
    try testing.expect(hostnameSubtext("Alpha", null) == null);
}

test "localDetail: the detail header names the machine, not the row" {
    const d = localDetail();
    try testing.expectEqualStrings("This PC", d.title);
    try testing.expectEqualStrings("This machine", d.subtitle);
    try testing.expectEqual(Glyph.local, d.glyph);
}

test "deviceDetail: reachability leads, a useful hostname follows" {
    var buf: [128]u8 = undefined;
    const on = deviceDetail(&buf, "Winbox", "winbox.local", true);
    try testing.expectEqualStrings("Winbox", on.title);
    try testing.expectEqualStrings("Online · winbox.local", on.subtitle);
    try testing.expectEqual(Glyph.server, on.glyph);

    const off = deviceDetail(&buf, "Winbox", "winbox.local", false);
    try testing.expectEqualStrings("Offline · winbox.local", off.subtitle);
}

test "deviceDetail: a redundant hostname leaves the state standing alone" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Online", deviceDetail(&buf, "Maximus", "maximus", true).subtitle);
    try testing.expectEqualStrings("Offline", deviceDetail(&buf, "Maximus", null, false).subtitle);
}

test "deviceDetail: a buffer too small for the join degrades to the state" {
    var tiny: [3]u8 = undefined;
    try testing.expectEqualStrings("Online", deviceDetail(&tiny, "Alpha", "prod-1.internal", true).subtitle);
}

test "rowMetrics: every piece nests inside the row height" {
    const m = rowMetrics(1.0);
    try testing.expect(m.height > 0);
    try testing.expect(m.title_y >= 0);
    try testing.expect(m.title_y + m.title_h <= m.subtitle_y);
    try testing.expect(m.subtitle_y + m.subtitle_h <= m.height);
    try testing.expect(m.glyph_y >= 0 and m.glyph_y + m.glyph_h <= m.height);
    try testing.expect(m.status_cy - @divTrunc(m.dot_d, 2) >= 0);
    try testing.expect(m.status_cy + @divTrunc(m.dot_d, 2) <= m.height);
    // Two-line rows need more room than a default single-line listbox item.
    try testing.expect(m.height >= 40);
}

test "rowMetrics: columns run status -> glyph -> text, left to right" {
    const m = rowMetrics(1.0);
    try testing.expect(m.status_cx + @divTrunc(m.dot_d, 2) < m.glyph_x);
    try testing.expect(m.glyph_x + m.glyph_w < m.text_x);
    // The status column starts inside the selection pill, not at the very edge.
    try testing.expect(m.status_cx - @divTrunc(m.dot_d, 2) >= m.fill_inset_x);
}

test "rowMetrics: the selection pill is inset (not a full-width bar)" {
    const m = rowMetrics(1.0);
    try testing.expect(m.fill_inset_x > 0);
    try testing.expect(m.fill_inset_y > 0);
    try testing.expect(m.fill_radius > 0);
}

test "rowMetrics: scales with DPI" {
    const a = rowMetrics(1.0);
    const b = rowMetrics(2.0);
    try testing.expectEqual(a.height * 2, b.height);
    try testing.expectEqual(a.text_x * 2, b.text_x);
    try testing.expectEqual(a.dot_d * 2, b.dot_d);
    try testing.expectEqual(a.subtitle_font_h * 2, b.subtitle_font_h);
}

test "clampHintLines: at least one line, never unbounded" {
    try testing.expectEqual(@as(i32, 1), clampHintLines(0));
    try testing.expectEqual(@as(i32, 1), clampHintLines(-3));
    try testing.expectEqual(@as(i32, 2), clampHintLines(2));
    try testing.expectEqual(max_hint_lines, clampHintLines(99));
}

test "blend: endpoints and midpoint" {
    const bg: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    const fg: Rgb = .{ .r = 232, .g = 32, .b = 32 };
    try testing.expect(blend(bg, fg, 0.0).eql(bg));
    try testing.expect(blend(bg, fg, 1.0).eql(fg));
    try testing.expectEqual(@as(u8, 132), blend(bg, fg, 0.5).r);
    // Out-of-range alphas clamp instead of wrapping.
    try testing.expect(blend(bg, fg, -1.0).eql(bg));
    try testing.expect(blend(bg, fg, 2.0).eql(fg));
}

test "columnWash is a lift off the background, dimmer than hover" {
    const bg: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    const wash = columnWash(bg);
    try testing.expect(wash.r > bg.r);
    try testing.expect(wash.r < hoverFill(bg).r);
    // Neutral: a wash, not a tint.
    try testing.expectEqual(wash.r, wash.b);
}

test "dividerColor reads above the wash it separates" {
    const bg: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    try testing.expect(dividerColor(bg).r > columnWash(bg).r);
    try testing.expect(dividerColor(bg).r < 255);
}

test "selection and hover sit between the background and their source color" {
    const bg: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    const accent: Rgb = .{ .r = 0x3D, .g = 0x8E, .b = 0xF8 };
    const sel = selectionFill(bg, accent);
    try testing.expect(sel.b > bg.b and sel.b < accent.b);
    // The border is more accent than the fill, so the row reads as selected.
    try testing.expect(selectionBorder(bg, accent).b > sel.b);
    // The hover wash is a nudge, not a highlight: dimmer than the selection.
    const hov = hoverFill(bg);
    try testing.expect(hov.r > bg.r);
    try testing.expect(hov.b < sel.b);
}

test "selection tracks the accent it is given, and the washes follow luminance" {
    // The whole point of T305's parameterization: two different accents must
    // produce two different selections. A module that still held its own blue
    // would pass every test above and none of this one.
    const bg: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    const blue: Rgb = .{ .r = 0x3D, .g = 0x8E, .b = 0xF8 };
    const purple: Rgb = .{ .r = 0x68, .g = 0x00, .b = 0x81 };
    try testing.expect(!selectionFill(bg, blue).eql(selectionFill(bg, purple)));
    try testing.expect(selectionFill(bg, purple).r > selectionFill(bg, blue).r);
    try testing.expect(selectionFill(bg, purple).g < selectionFill(bg, blue).g);

    // And the three washes reverse direction on a light surface instead of
    // heading for white regardless, which is what `blend(bg, white, a)` did.
    const light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };
    try testing.expect(hoverFill(light).r < light.r);
    try testing.expect(columnWash(light).r < light.r);
    try testing.expect(dividerColor(light).r < columnWash(light).r);
}
