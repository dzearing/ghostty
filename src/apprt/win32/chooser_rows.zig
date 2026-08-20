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
//! what a row SAYS (title/subtitle/status/glyph) and WHERE its pieces sit inside
//! the row rect. `MachineChooser.zig` keeps the GDI calls that paint them, and
//! since T1008 the selection COLORS live in `list_selection.zig` — they are the
//! platform's answer for every list, not this chooser's — and are re-exported
//! from here so the painter keeps one import.

const std = @import("std");

/// Re-exported so callers get the row palette and its color type from one
/// import.
const color_math = @import("color_math.zig");
pub const Rgb = color_math.Rgb;

/// The de-emphasized text ramp and the 3:1 chrome clamp both live in
/// `chrome_theme`; this module consumes them rather than keeping its own
/// answer (T310, the T206 rule).
const chrome_theme = @import("chrome_theme.zig");
/// The one type ramp (T310). The row's subline is the ramp's caption role, not
/// a number chosen here.
const type_ramp = @import("type_ramp.zig");
/// What a selected row looks like on this platform (T828, generalized by
/// T1008). Shared with the Activity Monitor's process table, which is the same
/// kind of surface and was still wearing the accent pill T828 retired here.
const list_selection = @import("list_selection.zig");

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
    /// `status_col_w` is the column RESERVED for it — the Local row draws no
    /// shape but still pays for the column, so every row shares one grid.
    status_cx: i32,
    status_cy: i32,
    status_col_w: i32,
    dot_d: i32,
    /// The reserved icon COLUMN (28 DIP, §3.2). It is the column — not the
    /// mark — that holds the text's left edge steady, so a glyph that grows
    /// cannot push the titles of every row sideways (S1 1001).
    glyph_col_x: i32,
    glyph_col_w: i32,
    /// The mark drawn inside that column, centered: `SM_CXSMICON` (16 DIP),
    /// the size Windows draws a small icon at.
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
    /// WinUI's selection indicator (T828): the rounded accent bar at the pill's
    /// left edge that carries "this row is selected" in Windows 11's own list
    /// language. It is the ONLY accent on a selected row — the accent-tinted
    /// fill and the accent perimeter it replaced are what the user reported as
    /// "a loud purple pill".
    ///
    /// `indicator_x` / `indicator_y` are relative to the row rect like every
    /// other field here; the bar is `xs` inside the pill's left edge (so it
    /// clears the pill's own rounded corner) and vertically centered.
    indicator_x: i32,
    indicator_y: i32,
    indicator_w: i32,
    indicator_h: i32,
    indicator_radius: i32,
    /// Focus rim (T312), drawn INSIDE the selection pill: design system §2.2's
    /// "2 DIP ring inset 1 DIP inside the painted square", applied to
    /// the pill because the pill is what the row paints.
    ///
    /// `focus_ring_w` is the pen width. `focus_path_inset` is where the pen's
    /// CENTRE line sits inside the pill so the rim's OUTER edge lands exactly
    /// one DIP in — GDI draws a pen centred on its path, which is the
    /// half-width that turns a "1 DIP inset" into a rim hanging over the pill's
    /// own edge if you pass the inset straight through.
    focus_ring_w: i32,
    focus_path_inset: i32,
    /// Corner radius of that path: the pill's radius minus how far in the path
    /// sits, so the rim stays concentric with the pill instead of squaring off
    /// inside a rounded shape.
    focus_ring_radius: i32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Row geometry at `scale` (the owner window's DPI scale). Pure — tested.
///
/// Every gap here is on the design system's 4 DIP scale (§1) and every one is
/// named by `docs/design/win32-machine-chooser.md` §3.2's Mac→Windows mapping.
/// Five of them were not, before T310: `fill_inset_y = 1`, `title_y = 7`, a 6
/// glyph gap, a 10 text gap and a 10 right pad. The scale test at the bottom of
/// this file is what stops them coming back.
pub fn rowMetrics(scale: f32) RowMetrics {
    const fill_inset_x = px(4, scale);
    // Row-to-row rhythm is 2 (§3.1) and it is paid TWICE — once by the row
    // above and once by the row below — so the datum is the gap and the inset
    // is derived from it. Writing `px(1, scale)` states half a gap as if it
    // were a spacing choice, which is how an off-scale number gets in.
    const row_gap = px(2, scale);
    const fill_inset_y = @divTrunc(row_gap, 2);

    const status_left = fill_inset_x + px(8, scale);
    const status_col_w = px(12, scale);
    const dot_d = px(8, scale);

    // `sm` between the status column and the icon column; the icon column is
    // Mac's 28 box; `lg` from the column to the text (§3.2).
    const glyph_col_x = status_left + status_col_w + px(4, scale);
    const glyph_col_w = px(28, scale);
    const glyph_mark = px(16, scale);

    // Line boxes follow the type ramp: a body line with `sm` of leading, a
    // caption line with the same. A hardcoded 17/14 would silently stop
    // matching the text the moment the ramp moved.
    const v_pad = px(4, scale);
    const title_y = v_pad;
    const title_h = type_ramp.lineBox(type_ramp.body(scale), scale);
    const subtitle_y = title_y + title_h + px(2, scale);
    const subtitle_h = type_ramp.lineBox(type_ramp.caption(scale), scale);
    const height = subtitle_y + subtitle_h + v_pad;

    // §2.2's ring, in the pill's own coordinates. Both numbers are quoted from
    // the design system rather than chosen here, and both are floored at one
    // physical pixel — a rim that rounds to zero at 1.0 is the same defect
    // T233 fixed on the split divider, one surface further in.
    const fill_radius = px(4, scale);
    const ring_w = @max(px(2, scale), 1);
    const ring_inset = @max(px(1, scale), 1);
    const path_inset = ring_inset + @divTrunc(ring_w, 2);

    // The selection indicator (T828). WinUI's is 3x16 with a fully rounded cap;
    // 3 is off this document's spacing scale, so the bar takes `sm` (4) — the
    // smallest step — and the scale's own 16, the size a small mark is drawn at
    // here (`glyph_mark` is the same number for the same reason). `xs` inside
    // the pill keeps it off the pill's rounded corner, and leaves `sm` of
    // painted gap to the status dot.
    const indicator_w = @max(px(4, scale), 1);
    const indicator_h = px(16, scale);

    return .{
        .height = height,
        .fill_inset_x = fill_inset_x,
        .fill_inset_y = fill_inset_y,
        // §3.1: a list item is the smallest surface on the dialog, so it takes
        // the scale's smallest radius. Mac's 6 encodes macOS's larger radius
        // language and does not survive the crossing.
        .fill_radius = fill_radius,
        .status_cx = status_left + @divTrunc(status_col_w, 2),
        .status_cy = @divTrunc(height, 2),
        .status_col_w = status_col_w,
        .dot_d = dot_d,
        .glyph_col_x = glyph_col_x,
        .glyph_col_w = glyph_col_w,
        .glyph_x = glyph_col_x + @divTrunc(glyph_col_w - glyph_mark, 2),
        .glyph_y = @divTrunc(height - glyph_mark, 2),
        .glyph_w = glyph_mark,
        .glyph_h = glyph_mark,
        .text_x = glyph_col_x + glyph_col_w + px(12, scale),
        .text_pad_right = px(8, scale),
        .title_y = title_y,
        .title_h = title_h,
        .subtitle_y = subtitle_y,
        .subtitle_h = subtitle_h,
        .subtitle_font_h = type_ramp.caption(scale).height,
        .indicator_x = fill_inset_x + px(2, scale),
        .indicator_y = @divTrunc(height - indicator_h, 2),
        .indicator_w = indicator_w,
        .indicator_h = indicator_h,
        // A capsule at every scale, like the session badges: half the width,
        // so the bar reads as a rounded mark rather than a rectangle with
        // slightly soft corners.
        .indicator_radius = @divTrunc(indicator_w, 2),
        .focus_ring_w = ring_w,
        .focus_path_inset = path_inset,
        .focus_ring_radius = @max(fill_radius - path_inset, 0),
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

/// Mac's `.green` for an online device. A BASE, never drawn raw: `onlineOn`
/// clamps it to the surface it lands on.
pub const online_green: Rgb = .{ .r = 0x34, .g = 0xC7, .b = 0x59 };

/// De-emphasized foreground for a row's subline, the detail pane's subtitle,
/// the status strip, the machine glyph and an offline status ring.
///
/// This replaced a flat `secondary_gray = #999999` in T310 (§4 finding 12).
/// That grey is **2.8:1 on Fluent's light surface** — under the 4.5:1 text
/// floor AND under the 3:1 chrome floor — so on a light theme every one of
/// those elements went illegible at once, and nothing in the code said so.
/// `chrome_theme` already answers this question for the tab bar's own
/// de-emphasized text; consuming it is the T206 rule, and it means the floor is
/// enforced by search on whatever surface the caller actually paints on.
pub fn secondaryOn(bg: Rgb) Rgb {
    return chrome_theme.textSecondaryOn(bg);
}

/// The online status dot, clamped to the 3:1 chrome floor (WCAG 1.4.11) — it
/// is a meaningful mark, not text, so it takes the chrome floor rather than
/// being dragged onto the text ramp and losing its green.
pub fn onlineOn(bg: Rgb) Rgb {
    return chrome_theme.accentOn(bg, online_green);
}

// The selection treatment itself — the neutral washes, the accent indicator's
// ink, the neutral focus rim — moved to `list_selection.zig` in T1008, when the
// Activity Monitor's process table turned out to be the second list on this
// platform and was still painting the pre-T828 accent pill. A module called
// "chooser rows" is the wrong owner for a rule that binds every list, and a
// second copy of the weights is how two panels drift apart one wash at a time.
//
// Re-exported here so the chooser's painter and its tests keep one import, and
// so the names in `MachineChooser.zig` / `chooser_sessions.zig` still read the
// way T828 left them.
pub const selection_wash_unfocused = list_selection.selection_wash_unfocused;
pub const selection_wash_focused = list_selection.selection_wash_focused;
pub const selectionFillFocused = list_selection.selectionFillFocused;
pub const selectionFillUnfocused = list_selection.selectionFillUnfocused;
pub const selectionIndicator = list_selection.selectionIndicator;
pub const selectionIndicatorUnfocused = list_selection.selectionIndicatorUnfocused;
pub const focusRing = list_selection.focusRim;
pub const hoverFill = list_selection.hoverFill;

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
// Row state (T312)
// ---------------------------------------------------------------------

/// The row's selection state and the colors it resolves to (T312/T828) live in
/// `list_selection.zig` since T1008 — every list on this platform answers "what
/// does a selected row look like" the same way, and the chooser is only one of
/// them. Re-exported so the painter reads unchanged.
pub const RowState = list_selection.RowState;
pub const RowPaint = list_selection.RowPaint;
pub const rowPaint = list_selection.rowPaint;

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

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
    try testing.expectEqual(a.glyph_col_w * 2, b.glyph_col_w);
}

test "rowMetrics: every gap is on the 4 DIP spacing scale (T310)" {
    // Design system §1, and the test that keeps win32-machine-chooser.md
    // §3.2's Mac→Windows mapping from rotting. Five of these were off it
    // before T310 and every one of them looked deliberate in isolation.
    const m = rowMetrics(1.0);
    const on_scale = [_]i32{ 2, 4, 8, 12, 16, 24 };
    const gaps = [_]struct { name: []const u8, v: i32 }{
        .{ .name = "row edge -> pill", .v = m.fill_inset_x },
        .{ .name = "row-to-row rhythm", .v = m.fill_inset_y * 2 },
        .{ .name = "pill -> status column", .v = (m.status_cx - @divTrunc(m.status_col_w, 2)) - m.fill_inset_x },
        .{ .name = "status column -> icon column", .v = m.glyph_col_x - (m.status_cx + @divTrunc(m.status_col_w, 2)) },
        .{ .name = "icon column -> text", .v = m.text_x - (m.glyph_col_x + m.glyph_col_w) },
        .{ .name = "text right pad", .v = m.text_pad_right },
        .{ .name = "row top pad", .v = m.title_y },
        .{ .name = "title -> subtitle", .v = m.subtitle_y - (m.title_y + m.title_h) },
        .{ .name = "row bottom pad", .v = m.height - (m.subtitle_y + m.subtitle_h) },
        .{ .name = "pill -> indicator", .v = m.indicator_x - m.fill_inset_x },
        .{
            .name = "indicator -> status dot",
            .v = (m.status_cx - @divTrunc(m.dot_d, 2)) - (m.indicator_x + m.indicator_w),
        },
    };
    for (gaps) |g| {
        if (std.mem.indexOfScalar(i32, &on_scale, g.v) == null) {
            std.debug.print("off-scale gap: {s} = {d}\n", .{ g.name, g.v });
            return error.OffSpacingScale;
        }
    }

    // Sizes are not gaps and have their own sources: §3.1's reserved 12 status
    // column, §3.2's 28 icon column, `SM_CXSMICON` (16), Mac's 8 dot, and the
    // scale's smallest radius (4).
    try testing.expectEqual(@as(i32, 12), m.status_col_w);
    try testing.expectEqual(@as(i32, 28), m.glyph_col_w);
    try testing.expectEqual(@as(i32, 16), m.glyph_w);
    try testing.expectEqual(@as(i32, 8), m.dot_d);
    try testing.expectEqual(@as(i32, 4), m.fill_radius);
    // The indicator bar: `sm` wide (WinUI's 3 is off this scale) and the same
    // 16 the icon mark takes, capped so it reads as a bar and not a rectangle.
    try testing.expectEqual(@as(i32, 4), m.indicator_w);
    try testing.expectEqual(@as(i32, 16), m.indicator_h);
    try testing.expectEqual(@as(i32, 2), m.indicator_radius);
}

test "rowMetrics: the selection indicator is a centered bar inside the pill (T828)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const m = rowMetrics(scale);
        // Inside the pill in both axes — a mark that hangs over the pill's edge
        // would read as a border fragment, which is the treatment T828 removed.
        try testing.expect(m.indicator_x > m.fill_inset_x);
        try testing.expect(m.indicator_y > m.fill_inset_y);
        try testing.expect(m.indicator_y + m.indicator_h <= m.height - m.fill_inset_y);
        // Vertically centered on the row, within a pixel of rounding.
        const above = m.indicator_y;
        const below = m.height - (m.indicator_y + m.indicator_h);
        try testing.expect(@abs(above - below) <= 1);
        // A capsule, and never wider than it is tall.
        try testing.expectEqual(@divTrunc(m.indicator_w, 2), m.indicator_radius);
        try testing.expect(m.indicator_w < m.indicator_h);
        // It stops short of the status dot rather than crowding it.
        try testing.expect(m.indicator_x + m.indicator_w < m.status_cx - @divTrunc(m.dot_d, 2));
    }
    // It scales with DPI like everything else here.
    try testing.expectEqual(rowMetrics(1.0).indicator_w * 2, rowMetrics(2.0).indicator_w);
    try testing.expectEqual(rowMetrics(1.0).indicator_h * 2, rowMetrics(2.0).indicator_h);
}

test "rowMetrics: the icon column holds the text edge, the mark sits inside it" {
    // §3.2: the COLUMN is 28 so the text cannot drift per row; the MARK is
    // SM_CXSMICON (16), the size Windows draws a small icon at. Before T310
    // there was no column — the 20-wide mark WAS the column, so a wider glyph
    // would have pushed every title sideways.
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const m = rowMetrics(scale);
        try testing.expect(m.glyph_w < m.glyph_col_w);
        try testing.expectEqual(m.glyph_w, m.glyph_h);
        // Centered in its column, within a pixel of rounding on both sides.
        const lead = m.glyph_x - m.glyph_col_x;
        const trail = (m.glyph_col_x + m.glyph_col_w) - (m.glyph_x + m.glyph_w);
        try testing.expect(@abs(lead - trail) <= 1);
        // And the mark never escapes the column it is centered in.
        try testing.expect(m.glyph_x >= m.glyph_col_x);
        try testing.expect(m.glyph_x + m.glyph_w <= m.glyph_col_x + m.glyph_col_w);
    }
    try testing.expectEqual(@as(i32, 28), rowMetrics(1.0).glyph_col_w);
    try testing.expectEqual(@as(i32, 16), rowMetrics(1.0).glyph_w);
}

test "rowMetrics: the selection pill takes the scale's smallest radius" {
    // §3.1: 4 for the smallest surface. Mac's 6 is macOS's radius language.
    try testing.expectEqual(@as(i32, 4), rowMetrics(1.0).fill_radius);
    inline for (.{ @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const m = rowMetrics(scale);
        // It scales, and it never grows past half the pill's own height or the
        // "rounded rect" stops being one.
        try testing.expect(m.fill_radius > 0);
        try testing.expect(m.fill_radius * 2 <= m.height - 2 * m.fill_inset_y);
    }
}

test "rowMetrics: the text line boxes follow the type ramp, not their own numbers" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const m = rowMetrics(scale);
        // The subline IS the ramp's caption role — the same font the painter
        // creates from `subtitle_font_h`.
        try testing.expectEqual(type_ramp.caption(scale).height, m.subtitle_font_h);
        // Each line box has room for its text plus leading, and the title's
        // box is the larger of the two because its font is.
        try testing.expect(m.title_h > type_ramp.body(scale).height);
        try testing.expect(m.subtitle_h > type_ramp.caption(scale).height);
        try testing.expect(m.title_h > m.subtitle_h);
    }
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

test "secondaryOn / onlineOn hold their floors on every surface (T310)" {
    // §4 finding 12: the retired `secondary_gray = #999999` had no floor at
    // all, and it is 2.8:1 on Fluent's light surface — under both the 4.5:1
    // text floor and the 3:1 chrome floor, so the sublines, the offline ring
    // and the machine glyph went illegible together on a light theme.
    const gray: Rgb = .{ .r = 0x99, .g = 0x99, .b = 0x99 };
    const light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };
    try testing.expect(ratio(gray, light) < 3.0);

    // A sweep, not a hand-picked pair — a single background is exactly how the
    // fixed grey survived this long.
    var v: u16 = 0;
    while (v <= 255) : (v += 8) {
        const c: u8 = @intCast(v);
        for ([_]Rgb{
            .{ .r = c, .g = c, .b = c },
            .{ .r = c, .g = @intCast(255 - v), .b = 0x40 },
            .{ .r = 0x20, .g = c, .b = @intCast(255 - v) },
        }) |bg| {
            // Text floor for the de-emphasized ramp...
            try testing.expect(ratio(secondaryOn(bg), bg) >= 4.4);
            // ...and the chrome floor for the status mark, which keeps its
            // green instead of being dragged onto the text ramp.
            try testing.expect(ratio(onlineOn(bg), bg) >= 2.95);
        }
    }

    // The online dot stays recognizably green, and stays distinguishable from
    // the de-emphasized ramp — shape-coded or not, the two must not converge.
    for ([_]Rgb{ light, .{ .r = 0x20, .g = 0x20, .b = 0x20 } }) |bg| {
        const on = onlineOn(bg);
        try testing.expect(on.g > on.r and on.g > on.b);
        try testing.expect(!on.eql(secondaryOn(bg)));
    }
}

test "rowMetrics: the focus rim is §2.2's ring, in the pill's own coordinates" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const m = rowMetrics(scale);
        // 2 DIP thick, inset 1 DIP — and never rounded away to nothing.
        try testing.expect(m.focus_ring_w >= 1);
        try testing.expectEqual(@max(@as(i32, @intFromFloat(@round(2 * scale))), 1), m.focus_ring_w);
        // The pen is centred on its path, so the path sits half a width further
        // in than the stated inset; that is what puts the rim's OUTER edge one
        // DIP inside the pill instead of straddling its edge.
        try testing.expect(m.focus_path_inset > @divTrunc(m.focus_ring_w, 2));
        const outer = m.focus_path_inset - @divTrunc(m.focus_ring_w, 2);
        try testing.expectEqual(@max(@as(i32, @intFromFloat(@round(1 * scale))), 1), outer);
        // Concentric with the pill, and inside it in both axes.
        try testing.expectEqual(@max(m.fill_radius - m.focus_path_inset, 0), m.focus_ring_radius);
        try testing.expect(m.focus_ring_radius < m.fill_radius);
        const pill_h = m.height - 2 * m.fill_inset_y;
        try testing.expect(2 * (m.focus_path_inset + m.focus_ring_w) < pill_h);
    }
    // At 1.0 the DIPs are the pixels, so the numbers are readable as the spec.
    const m = rowMetrics(1.0);
    try testing.expectEqual(@as(i32, 2), m.focus_ring_w);
    try testing.expectEqual(@as(i32, 2), m.focus_path_inset);
}

test "selection tracks the accent it is given, and the washes follow luminance" {
    // The whole point of T305's parameterization: two different accents must
    // produce two different selections. A module that still held its own blue
    // would pass every test above and none of this one. Since T828 the accent
    // rides the INDICATOR rather than the fill, so that is where it is asserted.
    const bg: Rgb = .{ .r = 32, .g = 32, .b = 32 };
    const on = selectionFillFocused(bg);
    const blue: Rgb = .{ .r = 0x3D, .g = 0x8E, .b = 0xF8 };
    const purple: Rgb = .{ .r = 0x68, .g = 0x00, .b = 0x81 };
    try testing.expect(!selectionIndicator(on, blue).eql(selectionIndicator(on, purple)));
    try testing.expect(selectionIndicator(on, purple).r > selectionIndicator(on, blue).r);
    try testing.expect(selectionIndicator(on, purple).g < selectionIndicator(on, blue).g);

    // And the three washes reverse direction on a light surface instead of
    // heading for white regardless, which is what `blend(bg, white, a)` did.
    const light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };
    try testing.expect(hoverFill(light).r < light.r);
    try testing.expect(columnWash(light).r < light.r);
    try testing.expect(dividerColor(light).r < columnWash(light).r);
}
