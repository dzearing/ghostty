//! Geometry, colors and card pixels for the KEY-STATE PILL (T446), the
//! Windows port of Mac's `Ghostty.SurfaceView.KeyStateIndicator`
//! (`macos/Sources/Ghostty/Surface View/SurfaceView.swift`): a small card at
//! the bottom of a pane naming the key tables you are inside and the keys of a
//! multi-key sequence you have pressed so far.
//!
//! The state it draws is `key_state.Model`; the window and the GDI text are
//! `KeyStateIndicator.zig`. No OS imports here, so every number below is
//! asserted at 1.0 / 1.25 / 1.5 / 2.0 in every app-runtime lane — the
//! `readonly_badge` / `banner_card` pattern.
//!
//! Three translations away from the Mac original, all deliberate:
//!
//! - **Fixed at the pane's bottom, not draggable.** Mac's pill can be flung to
//!   the top edge and the position is view state that does not persist. The
//!   INFORMATION is the feature; drag-to-reposition is a Mac interaction habit
//!   with no Windows idiom, and a control that moves when you touch it is not
//!   one the design system has a vocabulary for. Filed as a decision rather
//!   than skipped silently.
//! - **A card, not a capsule.** Radius 8 (design system §3.1, cards and
//!   overlays), the same as the banner and read-only cards it will sit near.
//!   A capsule here would be the odd one out.
//! - **Everything on the 4 DIP scale.** Mac's 5pt/6pt/13pt values are snapped
//!   to 4/4/12; the sizes below are the Windows rulebook's, not AppKit's.
//!
//! The waiting indicator IS animated (three dots on a sine wave, Mac's
//! `PendingIndicator`), because a static mark cannot distinguish "waiting for
//! your next key" from "wedged" — which is the exact ambiguity this whole
//! feature exists to remove. The phase is an argument, so the animation stays
//! a property of the caller's timer and this module stays pure.

const std = @import("std");
const color_math = @import("color_math.zig");
const card = @import("banner_card.zig");
const icon_button = @import("icon_button.zig");
const key_state = @import("key_state.zig");

const Rgb = color_math.Rgb;

/// Integer rect, right/bottom exclusive. Shared with the icon-button geometry
/// so `icon_button_paint.fontCodepoint` takes our rects directly.
pub const Rect = icon_button.Rect;

/// Table-name boxes the layout can carry: the model's retained names plus one
/// more for the "…" overflow marker the caller appends when the stack is
/// deeper than that.
pub const MAX_ITEMS: usize = key_state.MAX_TABLES + 1;
pub const MAX_KEYS: usize = key_state.MAX_KEYS;

/// Gap between the card and the pane's bottom edge, unscaled px. Matches the
/// read-only badge's inset from the top, so the two chips on one pane are
/// inset by the same amount from the edges they hug.
pub const INSET: f32 = 8.0;

/// Card corner radius, unscaled px. Design system §3.1.
pub const RADIUS: f32 = 8.0;

/// Card inner padding, unscaled px. Wider on the long axis than the short one,
/// like every other chip in the app (Mac uses 12/6 here).
pub const PAD_X: f32 = 12.0;
pub const PAD_Y: f32 = 4.0;

/// Gap inside the key-table run: between the keyboard glyph and the first
/// name, and on each side of a chevron.
pub const TABLE_GAP: f32 = 4.0;

/// Gap on each side of the section divider, unscaled px. Larger than
/// `TABLE_GAP` because it separates two different KINDS of thing.
pub const SECTION_GAP: f32 = 8.0;

/// Gap between adjacent key caps, and between the last cap and the dots.
pub const KEY_GAP: f32 = 4.0;

/// Keyboard glyph em box and chevron em box, unscaled px. The chevron is
/// smaller on purpose: it is punctuation between names, not a control.
pub const GLYPH: f32 = 12.0;
pub const CHEVRON: f32 = 8.0;

/// Label font size, unscaled px — table names and key-cap text alike.
pub const FONT_PX: f32 = 12.0;

/// Key-cap inner padding and corner radius, unscaled px. Radius 4 is the
/// design system's button radius, which is what a key cap is a picture of.
pub const CAP_PAD_X: f32 = 4.0;
pub const CAP_PAD_Y: f32 = 2.0;
pub const CAP_RADIUS: f32 = 4.0;

/// Section divider: one physical pixel wide, this tall, unscaled px.
pub const DIVIDER_W: f32 = 1.0;
pub const DIVIDER_H: f32 = 12.0;

/// Waiting dots: diameter and the gap between them, unscaled px.
pub const DOT: f32 = 4.0;
pub const DOT_GAP: f32 = 2.0;
pub const DOT_COUNT: usize = 3;

/// Card border thickness, unscaled px, floored at one physical pixel.
pub const BORDER: f32 = 1.0;

/// Elevation-1 drop shade, unscaled px — the read-only badge's, because these
/// two chips rest on pane content in exactly the same way.
pub const SHADOW_BLUR: f32 = 4.0;
pub const SHADOW_DY: f32 = 2.0;
pub const SHADOW_ALPHA: f32 = 0.28;

/// WCAG floors from the design system: 4.5:1 for text, 3:1 for a chrome glyph
/// or a meaningful boundary (1.4.11).
pub const TEXT_CONTRAST: f64 = 4.5;
pub const CHROME_CONTRAST: f64 = 3.0;

/// How far a secondary mark starts out from the card fill before the contrast
/// search gets hold of it. Mac draws the glyph in `.secondary` and the chevron
/// in `.tertiary`; one subdued weight is enough here, and starting subdued
/// means the search lands ON the 3:1 floor instead of way past it.
const SECONDARY_MIX: f64 = 0.55;

/// The card's own fill: the same glass wash the banner and read-only cards
/// use. Two cards on one pane resolving to two different fills is the
/// inconsistency the design system calls a defect.
pub fn fillColor(pane_bg: Rgb) Rgb {
    return card.fillColor(pane_bg);
}

/// A key cap's fill: one more wash step off the card, so the cap reads as
/// raised without inventing a color.
pub fn capFillColor(fill: Rgb) Rgb {
    return card.fillColor(fill);
}

/// Table names and key-cap text: full contrast against whatever they sit on.
/// Plain black/white clears 4.5:1 at every background (worst case 4.58:1), so
/// this is a guarantee rather than a search that might land short.
pub fn labelColor(bg: Rgb) Rgb {
    return color_math.contrastForeground(bg);
}

/// The card border, a key cap's border, and the section divider: a subdued
/// hairline moved only as far as the 3:1 boundary floor requires.
pub fn borderColor(fill: Rgb) Rgb {
    return atLeast(color_math.mix(fill, labelColor(fill), 0.15), fill, CHROME_CONTRAST);
}

/// The keyboard glyph, the chevrons and the waiting dots: subdued, but never
/// below the 3:1 chrome-glyph floor.
pub fn glyphColor(fill: Rgb) Rgb {
    return atLeast(color_math.mix(fill, labelColor(fill), SECONDARY_MIX), fill, CHROME_CONTRAST);
}

/// `contrastAdjustedTo`, then VERIFIED against the color that will actually be
/// painted. Since T325 the shared search measures the 8-bit color it returns,
/// so this re-measure no longer catches a real gap — it is kept as the local
/// statement of the guarantee, one line that cannot be invalidated from
/// another module. Black/white always clears both floors, so the fallback is a
/// real answer rather than another approximation. (Same reasoning, same shape,
/// as `readonly_badge`.)
fn atLeast(base: Rgb, fill: Rgb, target: f64) Rgb {
    const c = color_math.contrastAdjustedTo(base, fill, target);
    if (ratio(c, fill) >= target) return c;
    return color_math.contrastForeground(fill);
}

/// WCAG contrast between two concrete colors.
pub fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

/// Alpha of waiting dot `i` at animation `phase` (turns, wrapping at 1.0).
/// Mac's `PendingIndicator.dotOpacity`, unchanged: a sine wave offset by a
/// third of a cycle per dot, riding between 0.3 and 1.0.
pub fn dotAlpha(i: usize, phase: f32) f32 {
    const offset = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(DOT_COUNT));
    const wave = @sin((phase + offset) * std.math.pi * 2.0);
    return 0.3 + 0.7 * ((wave + 1.0) / 2.0);
}

/// Every unscaled metric above, in physical pixels at one DPI scale.
pub const Metrics = struct {
    scale: f32,
    inset: i32,
    radius: i32,
    pad_x: i32,
    pad_y: i32,
    table_gap: i32,
    section_gap: i32,
    key_gap: i32,
    glyph: i32,
    chevron: i32,
    font_px: i32,
    cap_pad_x: i32,
    cap_pad_y: i32,
    cap_radius: i32,
    divider_w: i32,
    divider_h: i32,
    dot: i32,
    dot_gap: i32,
    border: i32,
    shadow_blur: i32,
    shadow_dy: i32,

    pub fn init(scale: f32) Metrics {
        const s = @max(scale, 0.1);
        return .{
            .scale = s,
            .inset = px(INSET, s),
            .radius = px(RADIUS, s),
            .pad_x = px(PAD_X, s),
            .pad_y = px(PAD_Y, s),
            .table_gap = px(TABLE_GAP, s),
            .section_gap = px(SECTION_GAP, s),
            .key_gap = px(KEY_GAP, s),
            .glyph = px(GLYPH, s),
            .chevron = px(CHEVRON, s),
            .font_px = px(FONT_PX, s),
            .cap_pad_x = px(CAP_PAD_X, s),
            .cap_pad_y = px(CAP_PAD_Y, s),
            .cap_radius = px(CAP_RADIUS, s),
            // A divider or a border that rounds to zero is an invisible
            // boundary, which is a missing one.
            .divider_w = @max(px(DIVIDER_W, s), 1),
            .divider_h = px(DIVIDER_H, s),
            .dot = @max(px(DOT, s), 1),
            .dot_gap = @max(px(DOT_GAP, s), 1),
            .border = @max(px(BORDER, s), 1),
            .shadow_blur = px(SHADOW_BLUR, s),
            .shadow_dy = px(SHADOW_DY, s),
        };
    }

    /// Extra room the popup window needs around the card for the drop shade
    /// to have pixels to paint into.
    pub fn shadowPad(self: Metrics) i32 {
        return self.shadow_blur + self.shadow_dy;
    }

    /// Total width of the three waiting dots.
    pub fn dotsWidth(self: Metrics) i32 {
        return self.dot * @as(i32, @intCast(DOT_COUNT)) +
            self.dot_gap * @as(i32, @intCast(DOT_COUNT - 1));
    }
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// What the caller measured with GDI, in the order it will be drawn.
pub const Content = struct {
    /// Width of each key-table name's text, outermost first.
    tables: []const i32 = &.{},
    /// Width of each pending key's label text, in press order.
    keys: []const i32 = &.{},
    /// Text height at `FONT_PX`. One font for names and cap labels alike.
    text_h: i32 = 0,
};

/// Everything the painter needs. All rects are in the POPUP WINDOW's client
/// coordinates except `win`, which is in the pane's.
pub const Layout = struct {
    win: Rect = .{},
    card: Rect = .{},
    /// The keyboard glyph's em box. Empty when no key table is active.
    glyph: Rect = .{},
    /// Text boxes for the table names, outermost first.
    tables: [MAX_ITEMS]Rect = @splat(.{}),
    /// `chevrons[i]` is the chevron drawn BEFORE `tables[i]`; `chevrons[0]` is
    /// always empty (nothing precedes the first name).
    chevrons: [MAX_ITEMS]Rect = @splat(.{}),
    table_count: usize = 0,
    /// The vertical rule between the two sections. Empty unless both are
    /// present.
    divider: Rect = .{},
    /// Key-CAP boxes (the rounded chip, not its text). The label is drawn
    /// centered inside.
    caps: [MAX_KEYS]Rect = @splat(.{}),
    key_count: usize = 0,
    /// Bounding box of the three waiting dots. Empty when no key is pending.
    dots: Rect = .{},
    /// The pane is too small, or there is nothing to say. The caller hides.
    hidden: bool = true,
};

/// Place the pill, bottom-centered in a pane of `pane_w` x `pane_h` px.
///
/// The card's bottom edge lands exactly `m.inset` above the pane's bottom and
/// the card is horizontally centered — that pair is what the scale sweep
/// asserts, because a shadow allowance folded into the anchor is precisely how
/// an "8 DIP inset" quietly becomes 14 at 2.0.
///
/// When the content is wider than the pane can hold, the KEY section keeps its
/// natural size and the TABLE names shrink: a chord you are halfway through is
/// the urgent half of the message, and a table name still reads when elided.
/// A pane too narrow even for the keys alone hides the pill rather than
/// drawing a stub.
pub fn layout(m: Metrics, pane_w: i32, pane_h: i32, c: Content) Layout {
    const hidden: Layout = .{};

    var n_tables = @min(c.tables.len, MAX_ITEMS);
    const n_keys = @min(c.keys.len, MAX_KEYS);
    if (n_tables == 0 and n_keys == 0) return hidden;

    const text_h = @max(c.text_h, 0);
    const cap_h = text_h + m.cap_pad_y * 2;
    const content_h = @max(m.glyph, @max(cap_h, m.divider_h));
    const card_h = content_h + m.pad_y * 2;

    const max_w = pane_w - m.inset * 2;
    if (max_w <= m.pad_x * 2) return hidden;
    if (pane_h < card_h + m.inset * 2) return hidden;

    // Widths of the two runs at their natural size.
    const keys_w = keysWidth(m, c.keys[0..n_keys]);
    var names_budget = namesWidth(c.tables[0..n_tables]);
    var tables_w = tablesWidth(m, n_tables, names_budget);
    var sep_w: i32 = if (n_tables > 0 and n_keys > 0)
        m.section_gap * 2 + m.divider_w
    else
        0;

    const room = max_w - m.pad_x * 2;
    if (tables_w + sep_w + keys_w > room) {
        // The keys are load-bearing; anything left over is the tables'.
        const left = room - keys_w - sep_w;
        const fixed = tablesFixedWidth(m, n_tables);
        if (n_tables == 0 or left < fixed + @as(i32, @intCast(n_tables))) {
            // Not even one pixel per name: drop the whole table run rather
            // than draw a glyph with nothing after it.
            if (keys_w > room) return hidden;
            n_tables = 0;
            names_budget = 0;
            sep_w = 0;
            tables_w = 0;
        } else {
            names_budget = left - fixed;
            tables_w = fixed + names_budget;
        }
    }
    if (n_tables == 0 and n_keys == 0) return hidden;

    const card_w = @min(tables_w + sep_w + keys_w + m.pad_x * 2, max_w);

    // Card rect in PANE coordinates: bottom-centered.
    const card_pane: Rect = .{
        .left = @divTrunc(pane_w - card_w, 2),
        .top = pane_h - m.inset - card_h,
        .right = @divTrunc(pane_w - card_w, 2) + card_w,
        .bottom = pane_h - m.inset,
    };

    // The window is the card plus the shadow allowance, clipped to the pane so
    // a popup never hangs outside the surface it decorates. Clipping the
    // WINDOW never moves the card: the pad is decoration, the anchor is not.
    //
    // The pad is UNIFORM, including below — unlike the read-only badge, which
    // hangs off the pane's top edge with the whole pane beneath it to spill
    // into. This card sits `inset` above the pane's bottom, so an asymmetric
    // bottom allowance would push the window's edge onto the pane's and the
    // shade would be clipped by exactly the amount of slack it was given.
    // `shadowPad` already carries the downward offset.
    const pad = m.shadowPad();
    const win: Rect = .{
        .left = @max(card_pane.left - pad, 0),
        .top = @max(card_pane.top - pad, 0),
        .right = @min(card_pane.right + pad, pane_w),
        .bottom = @min(card_pane.bottom + pad, pane_h),
    };

    var l: Layout = .{
        .win = win,
        .card = offsetRect(card_pane, -win.left, -win.top),
        .table_count = n_tables,
        .key_count = n_keys,
        .hidden = false,
    };

    const mid = @divTrunc(l.card.top + l.card.bottom, 2);
    var x = l.card.left + m.pad_x;

    if (n_tables > 0) {
        l.glyph = centeredBox(x, mid, m.glyph, m.glyph);
        x = l.glyph.right + m.table_gap;

        var scaled: [MAX_ITEMS]i32 = @splat(0);
        shareWidths(c.tables[0..n_tables], names_budget, scaled[0..n_tables]);

        for (0..n_tables) |i| {
            if (i > 0) {
                l.chevrons[i] = centeredBox(x, mid, m.chevron, m.chevron);
                x = l.chevrons[i].right + m.table_gap;
            }
            l.tables[i] = .{
                .left = x,
                .top = mid - @divTrunc(text_h, 2),
                .right = x + scaled[i],
                .bottom = mid - @divTrunc(text_h, 2) + text_h,
            };
            x = l.tables[i].right + m.table_gap;
        }
        // The trailing gap after the last name belongs to whatever follows,
        // and the section gap already covers that.
        x -= m.table_gap;
    }

    if (n_tables > 0 and n_keys > 0) {
        x += m.section_gap;
        l.divider = .{
            .left = x,
            .top = mid - @divTrunc(m.divider_h, 2),
            .right = x + m.divider_w,
            .bottom = mid - @divTrunc(m.divider_h, 2) + m.divider_h,
        };
        x = l.divider.right + m.section_gap;
    }

    if (n_keys > 0) {
        for (0..n_keys) |i| {
            const w = @max(c.keys[i], 0) + m.cap_pad_x * 2;
            l.caps[i] = .{
                .left = x,
                .top = mid - @divTrunc(cap_h, 2),
                .right = x + w,
                .bottom = mid - @divTrunc(cap_h, 2) + cap_h,
            };
            x = l.caps[i].right + m.key_gap;
        }
        l.dots = centeredBox(x, mid, m.dotsWidth(), m.dot);
    }

    return l;
}

// ---------------------------------------------------------------------------
// The explainer (T576)
// ---------------------------------------------------------------------------
//
// The pill NAMES the table you are in; it does not say what a key table is.
// That is the half that matters to the person this feature is for, because the
// likeliest way to end up in one is by accident and "resize" alone does not
// tell you what happened to your keyboard. Mac answers it with a popover on
// the indicator; Windows answers it with the hover tooltip its own shell uses
// for exactly this ("what is this thing"), same words either way.
//
// The trigger is the reason this is here rather than in the window file: the
// pill's popup is click-through by construction (it floats over live terminal
// content, where a selection drag ends), so only the CARD may take the
// pointer, and the card rect is a layout answer.

/// The explainer's heading. Mac's popover title, verbatim.
pub const EXPLAINER_TITLE = "Key Table";

/// The explainer's sentence. Mac's popover body, verbatim — the two platforms
/// telling a user the same thing in different words would be a worse
/// divergence than the missing control was.
pub const EXPLAINER_BODY =
    "A key table is a named set of keybindings, activated by some other " ++
    "key. Keys are interpreted using this table until it is deactivated.";

/// True when the popup-window-local point `(x, y)` lands on the CARD, which is
/// the only part of the pill that may take the pointer. Everything else the
/// window covers — the shadow allowance on all four sides — stays
/// click-through, so a click that looks like it landed on the terminal DOES
/// land on the terminal.
pub fn hitsCard(l: Layout, x: i32, y: i32) bool {
    if (l.hidden or l.card.isEmpty()) return false;
    return l.card.containsPoint(x, y);
}

fn offsetRect(r: Rect, dx: i32, dy: i32) Rect {
    return .{
        .left = r.left + dx,
        .top = r.top + dy,
        .right = r.right + dx,
        .bottom = r.bottom + dy,
    };
}

/// A `w` x `h` box whose left edge is `x` and whose vertical center is `mid`.
fn centeredBox(x: i32, mid: i32, w: i32, h: i32) Rect {
    const top = mid - @divTrunc(h, 2);
    return .{ .left = x, .top = top, .right = x + w, .bottom = top + h };
}

fn namesWidth(names: []const i32) i32 {
    var sum: i32 = 0;
    for (names) |w| sum += @max(w, 0);
    return sum;
}

/// Everything in the table run that is NOT name text: the keyboard glyph, the
/// gap after it, and a chevron with a gap on each side between every pair.
fn tablesFixedWidth(m: Metrics, n: usize) i32 {
    if (n == 0) return 0;
    const pairs: i32 = @intCast(n - 1);
    return m.glyph + m.table_gap + pairs * (m.chevron + m.table_gap * 2);
}

fn tablesWidth(m: Metrics, n: usize, names: i32) i32 {
    if (n == 0) return 0;
    return tablesFixedWidth(m, n) + names;
}

fn keysWidth(m: Metrics, keys: []const i32) i32 {
    if (keys.len == 0) return 0;
    var sum: i32 = 0;
    for (keys) |w| sum += @max(w, 0) + m.cap_pad_x * 2;
    sum += m.key_gap * @as(i32, @intCast(keys.len)); // between caps, and before the dots
    return sum + m.dotsWidth();
}

/// Split `budget` across `natural` proportionally: never below one pixel each,
/// never above what each asked for, and never over budget in total.
///
/// Integer rounding leaves an overshoot of a few pixels, and it is trimmed off
/// the HEAD of the list. The names are drawn outermost-first, so the head is
/// the outer CONTEXT and the tail is the table you are actually in — and when
/// something has to give, it is the context.
fn shareWidths(natural: []const i32, budget: i32, out: []i32) void {
    std.debug.assert(natural.len == out.len);
    if (out.len == 0) return;

    var total: i32 = 0;
    for (natural) |w| total += @max(w, 0);

    if (total <= budget or total <= 0) {
        for (natural, out) |w, *o| o.* = @max(w, 0);
        // A budget larger than asked for is not spread out — text does not
        // grow to fill a box.
        return;
    }

    var used: i32 = 0;
    for (natural, out) |w, *o| {
        const share = @divTrunc(@as(i64, @max(w, 0)) * @as(i64, budget), @as(i64, total));
        o.* = @max(@as(i32, @intCast(share)), 1);
        used += o.*;
    }

    var over = used - budget;
    var i: usize = 0;
    while (over > 0 and i < out.len) : (i += 1) {
        const take = @min(over, out[i] - 1);
        out[i] -= take;
        over -= take;
    }
}

/// Paint the pill's card, key caps, divider and waiting dots into a per-pixel
/// alpha surface: `bgr` gets the STRAIGHT (un-premultiplied) `0x00RRGGBB`
/// color, `mask` the coverage alpha. Both are `l.win.width() * l.win.height()`
/// top-down.
///
/// Straight, and in two buffers, for the reason `readonly_badge.render`
/// documents: the caller draws the glyph, the chevrons and the labels into the
/// same DIB with GDI afterwards, and GDI text writes zero into the alpha byte.
/// Keeping the mask lets the caller re-apply the real coverage and premultiply
/// once, AFTER the text lands.
///
/// The card interior is fully opaque — that is what keeps the labels readable
/// over whatever the pane happens to be drawing — and only the drop shade and
/// the antialiased edge are translucent.
pub fn render(
    bgr: []u32,
    mask: []u8,
    m: Metrics,
    l: Layout,
    pane_bg: Rgb,
    phase: f32,
) void {
    if (l.hidden) return;
    const w: usize = @intCast(@max(l.win.width(), 0));
    const h: usize = @intCast(@max(l.win.height(), 0));
    if (w == 0 or h == 0) return;
    if (bgr.len < w * h or mask.len < w * h) return;

    const fill = fillColor(pane_bg);
    const border = borderColor(fill);
    const cap_fill = capFillColor(fill);
    const dot_rgb = glyphColor(fill);

    const radius: f32 = @floatFromInt(m.radius);
    const cap_radius: f32 = @floatFromInt(m.cap_radius);
    const bw: f32 = @floatFromInt(m.border);
    const blur: f32 = @floatFromInt(@max(m.shadow_blur, 1));
    const dy: f32 = @floatFromInt(m.shadow_dy);

    const cr = toF(l.card);
    const shadow = card.Rect{
        .left = cr.left,
        .top = cr.top + dy,
        .right = cr.right,
        .bottom = cr.bottom + dy,
    };

    for (0..h) |row| {
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        for (0..w) |col| {
            const x = @as(f32, @floatFromInt(col)) + 0.5;
            const i = row * w + col;

            const sd = card.sdRoundRect(x, y, cr, radius);
            const cov = cov1(sd);
            // The border is the outer edge minus the same shape inset by the
            // border width, so it hugs the antialiased boundary instead of
            // being a second rounded rect that can disagree with it.
            const rim = @max(cov - cov1(sd + bw), 0.0);

            var shade: f32 = 0.0;
            if (cov < 1.0) {
                const sds = card.sdRoundRect(x, y, shadow, radius);
                shade = SHADOW_ALPHA * (1.0 - smooth(-blur, blur, sds)) * (1.0 - cov);
            }

            const a = std.math.clamp(cov + shade * (1.0 - cov), 0.0, 1.0);
            mask[i] = @intFromFloat(@round(a * 255.0));
            if (a <= 0.0) {
                bgr[i] = 0;
                continue;
            }

            // Card fill, then the card's rim, then whatever sits on top of the
            // card at this pixel. Everything inside is fully covered, so the
            // inner marks only ever mix colors, never alpha.
            var c = mixRgb(fill, border, rim);
            if (cov >= 1.0) c = inner(c, cap_fill, border, dot_rgb, m, l, cap_radius, bw, x, y, phase);

            const k = cov / a;
            bgr[i] = pack(scaleCh(c.r, k), scaleCh(c.g, k), scaleCh(c.b, k));
        }
    }
}

/// The marks painted ON the card: key caps (fill + rim), the section divider,
/// and the waiting dots. Returns `base` unchanged where none of them land.
fn inner(
    base: Rgb,
    cap_fill: Rgb,
    border: Rgb,
    dot_rgb: Rgb,
    m: Metrics,
    l: Layout,
    cap_radius: f32,
    bw: f32,
    x: f32,
    y: f32,
    phase: f32,
) Rgb {
    var c = base;

    for (l.caps[0..l.key_count]) |capr| {
        if (capr.isEmpty()) continue;
        const sd = card.sdRoundRect(x, y, toF(capr), cap_radius);
        const cov = cov1(sd);
        if (cov <= 0.0) continue;
        const rim = @max(cov - cov1(sd + bw), 0.0);
        c = mixRgb(c, mixRgb(cap_fill, border, rim), cov);
    }

    if (!l.divider.isEmpty()) {
        const d = toF(l.divider);
        if (x >= d.left and x <= d.right and y >= d.top and y <= d.bottom) {
            c = border;
        }
    }

    if (!l.dots.isEmpty()) {
        const r = @as(f32, @floatFromInt(m.dot)) * 0.5;
        const cy = @as(f32, @floatFromInt(l.dots.top + l.dots.bottom)) * 0.5;
        for (0..DOT_COUNT) |i| {
            const step = m.dot + m.dot_gap;
            const cx = @as(f32, @floatFromInt(l.dots.left + @as(i32, @intCast(i)) * step)) + r;
            const dxp = x - cx;
            const dyp = y - cy;
            // Distance field of the circle, antialiased the same way the
            // rounded rects are — a hard threshold at this size is a visible
            // staircase.
            const cov = cov1(@sqrt(dxp * dxp + dyp * dyp) - r) * dotAlpha(i, phase);
            if (cov > 0.0) c = mixRgb(c, dot_rgb, cov);
        }
    }

    return c;
}

fn toF(r: Rect) card.Rect {
    return .{
        .left = @floatFromInt(r.left),
        .top = @floatFromInt(r.top),
        .right = @floatFromInt(r.right),
        .bottom = @floatFromInt(r.bottom),
    };
}

fn cov1(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0.0, 1.0);
}

fn smooth(e0: f32, e1: f32, x: f32) f32 {
    if (e1 <= e0) return if (x < e0) 0.0 else 1.0;
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn mixRgb(a: Rgb, b: Rgb, t: f32) Rgb {
    const f = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = lerpCh(a.r, b.r, f),
        .g = lerpCh(a.g, b.g, f),
        .b = lerpCh(a.b, b.b, f),
    };
}

fn lerpCh(a: u8, b: u8, t: f32) u8 {
    const av: f32 = @floatFromInt(a);
    const bv: f32 = @floatFromInt(b);
    return @intFromFloat(std.math.clamp(@round(av + (bv - av) * t), 0.0, 255.0));
}

fn scaleCh(v: u8, k: f32) u32 {
    const f: f32 = @floatFromInt(v);
    return @intFromFloat(std.math.clamp(@round(f * k), 0.0, 255.0));
}

fn pack(r: u32, g: u32, b: u32) u32 {
    return (r << 16) | (g << 8) | b;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The four scales the design system requires every chrome number to be
/// asserted at. Most of these defects are invisible at 1.0 and obvious at 1.25.
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

const DARK = Rgb{ .r = 16, .g = 16, .b = 20 };

/// A plausible GDI measurement: roughly 0.55 em per character, and a line box
/// three px taller than the em. Only the relationships matter to the layout.
fn textW(m: Metrics, chars: usize) i32 {
    return @intCast(@divTrunc(@as(i32, @intCast(chars)) * m.font_px * 55, 100));
}
fn textH(m: Metrics) i32 {
    return m.font_px + 3;
}

fn sample(m: Metrics) Content {
    const S = struct {
        var tables: [2]i32 = undefined;
        var keys: [2]i32 = undefined;
    };
    S.tables = .{ textW(m, 6), textW(m, 6) };
    S.keys = .{ textW(m, 6), textW(m, 1) };
    return .{ .tables = &S.tables, .keys = &S.keys, .text_h = textH(m) };
}

test "the card is bottom-centered, exactly INSET above the pane's bottom" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const l = layout(m, 1200, 800, sample(m));
        try testing.expect(!l.hidden);

        // Back in pane coordinates.
        const bottom_gap = 800 - (l.win.top + l.card.bottom);
        try testing.expectEqual(m.inset, bottom_gap);

        const left = l.win.left + l.card.left;
        const right_gap = 1200 - (l.win.left + l.card.right);
        // Centered: the two side gaps differ by at most the odd pixel.
        try testing.expect(@abs(left - right_gap) <= 1);
    }
}

test "the inset clears the design system's 4 DIP floor at every scale" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const floor: i32 = @intFromFloat(@round(4.0 * scale));
        try testing.expect(m.inset >= floor);
    }
}

test "every metric lands on the 4 DIP spacing scale" {
    // Design system §0: one 4 DIP scale (2/4/8/12/16/24), no value off it.
    // `BORDER` and `DIVIDER_W` are deliberately absent: a hairline is one
    // PHYSICAL pixel, a thickness rather than a spacing value, and rounding it
    // onto the scale would make it a 2 DIP slab at every DPI.
    const on_scale = [_]f32{
        INSET,
        RADIUS,
        PAD_X,
        PAD_Y,
        TABLE_GAP,
        SECTION_GAP,
        KEY_GAP,
        GLYPH,
        CHEVRON,
        FONT_PX,
        CAP_PAD_X,
        CAP_PAD_Y,
        CAP_RADIUS,
        DIVIDER_H,
        DOT,
        DOT_GAP,
        SHADOW_BLUR,
        SHADOW_DY,
    };
    for (on_scale) |v| {
        try testing.expect(v == 2.0 or v == 4.0 or v == 8.0 or
            v == 12.0 or v == 16.0 or v == 24.0);
    }
}

test "nothing inside the card touches anything else" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const l = layout(m, 1200, 800, sample(m));
        try testing.expect(!l.hidden);
        try testing.expectEqual(@as(usize, 2), l.table_count);
        try testing.expectEqual(@as(usize, 2), l.key_count);

        // The glyph starts one full pad in from the card's left edge.
        try testing.expectEqual(l.card.left + m.pad_x, l.glyph.left);
        // ...and a full table gap separates it from the first name.
        try testing.expectEqual(l.glyph.right + m.table_gap, l.tables[0].left);
        // A chevron sits between the two names with a gap on each side.
        try testing.expectEqual(l.tables[0].right + m.table_gap, l.chevrons[1].left);
        try testing.expectEqual(l.chevrons[1].right + m.table_gap, l.tables[1].left);
        // Nothing precedes the first name.
        try testing.expect(l.chevrons[0].isEmpty());
        // The divider gets a section gap on both sides.
        try testing.expectEqual(l.tables[1].right + m.section_gap, l.divider.left);
        try testing.expectEqual(l.divider.right + m.section_gap, l.caps[0].left);
        // Key caps are separated, and the dots follow the last one.
        try testing.expectEqual(l.caps[0].right + m.key_gap, l.caps[1].left);
        try testing.expectEqual(l.caps[1].right + m.key_gap, l.dots.left);
        // The last thing in the card still clears the trailing padding.
        try testing.expect(l.dots.right <= l.card.right - m.pad_x);
    }
}

test "every mark is vertically centered in the card" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const l = layout(m, 1200, 800, sample(m));
        const mid = @divTrunc(l.card.top + l.card.bottom, 2);
        for ([_]Rect{ l.glyph, l.chevrons[1], l.tables[0], l.divider, l.caps[0], l.dots }) |r| {
            const center = @divTrunc(r.top + r.bottom, 2);
            try testing.expect(@abs(center - mid) <= 1);
            // ...and inside the card, with its padding intact.
            try testing.expect(r.top >= l.card.top);
            try testing.expect(r.bottom <= l.card.bottom);
        }
    }
}

test "a lone key table draws no divider and no key caps" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        var tables = [_]i32{textW(m, 6)};
        const l = layout(m, 1200, 800, .{ .tables = &tables, .text_h = textH(m) });
        try testing.expect(!l.hidden);
        try testing.expectEqual(@as(usize, 1), l.table_count);
        try testing.expectEqual(@as(usize, 0), l.key_count);
        try testing.expect(l.divider.isEmpty());
        try testing.expect(l.dots.isEmpty());
        try testing.expect(!l.glyph.isEmpty());
        // The name still clears the card's trailing padding.
        try testing.expect(l.tables[0].right <= l.card.right - m.pad_x);
    }
}

test "a lone pending sequence draws no keyboard glyph and no divider" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        var keys = [_]i32{textW(m, 6)};
        const l = layout(m, 1200, 800, .{ .keys = &keys, .text_h = textH(m) });
        try testing.expect(!l.hidden);
        try testing.expectEqual(@as(usize, 0), l.table_count);
        try testing.expectEqual(@as(usize, 1), l.key_count);
        try testing.expect(l.glyph.isEmpty());
        try testing.expect(l.divider.isEmpty());
        try testing.expect(!l.dots.isEmpty());
        // The first cap starts one pad in, and the dots clear the far pad.
        try testing.expectEqual(l.card.left + m.pad_x, l.caps[0].left);
        try testing.expect(l.dots.right <= l.card.right - m.pad_x);
    }
}

test "an empty model has no pill at all" {
    const m = Metrics.init(1.0);
    try testing.expect(layout(m, 1200, 800, .{}).hidden);
}

test "a key cap is its label plus padding, and taller than the text" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        var keys = [_]i32{textW(m, 6)};
        const l = layout(m, 1200, 800, .{ .keys = &keys, .text_h = textH(m) });
        try testing.expectEqual(keys[0] + m.cap_pad_x * 2, l.caps[0].width());
        try testing.expectEqual(textH(m) + m.cap_pad_y * 2, l.caps[0].height());
    }
}

test "a narrow pane shrinks the table names and never the keys" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const c = sample(m);
        const full = layout(m, 1200, 800, c);
        const cap_w = full.caps[0].width();

        // A pane just wide enough for the keys plus a sliver of table.
        var pane_w = full.card.width() + m.inset * 2;
        var shrunk = full;
        var found = false;
        while (pane_w > m.inset * 2 + m.pad_x * 2) : (pane_w -= @max(@divTrunc(pane_w, 20), 1)) {
            const l = layout(m, pane_w, 800, c);
            if (l.hidden) break;
            if (l.table_count == 2 and l.tables[0].width() < full.tables[0].width()) {
                shrunk = l;
                found = true;
                break;
            }
        }
        try testing.expect(found);
        // The keys kept their natural size...
        try testing.expectEqual(cap_w, shrunk.caps[0].width());
        // ...the names gave the ground, and stayed visible.
        try testing.expect(shrunk.tables[0].width() >= 1);
        try testing.expect(shrunk.tables[1].width() >= 1);
        // ...and nothing spilled past the card's padding.
        try testing.expect(shrunk.dots.right <= shrunk.card.right - m.pad_x);
    }
}

test "a pane too narrow for the tables drops them and keeps the keys" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const c = sample(m);
        // Exactly the keys, their padding and the insets: no room for a
        // glyph, a name and a divider on top.
        const keys_only = keysWidth(m, c.keys) + m.pad_x * 2;
        const l = layout(m, keys_only + m.inset * 2, 800, c);
        try testing.expect(!l.hidden);
        try testing.expectEqual(@as(usize, 0), l.table_count);
        try testing.expectEqual(@as(usize, 2), l.key_count);
        try testing.expect(l.glyph.isEmpty());
        try testing.expect(l.divider.isEmpty());
        try testing.expect(l.dots.right <= l.card.right - m.pad_x);
    }
}

test "a pane too small for even the keys hides the pill" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const c = sample(m);
        try testing.expect(layout(m, m.pad_x * 2, 800, c).hidden);
        try testing.expect(layout(m, 1200, m.pad_y, c).hidden);
        try testing.expect(layout(m, 0, 0, c).hidden);
        try testing.expect(layout(m, -10, -10, c).hidden);
    }
}

test "the window holds the card plus the shadow allowance, inside the pane" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const l = layout(m, 1200, 800, sample(m));
        try testing.expect(l.card.left > 0);
        try testing.expect(l.card.top > 0);
        try testing.expect(l.card.right < l.win.width());
        try testing.expect(l.card.bottom < l.win.height());
        try testing.expect(l.win.left >= 0);
        try testing.expect(l.win.top >= 0);
        try testing.expect(l.win.right <= 1200);
        try testing.expect(l.win.bottom <= 800);

        // The allowance is the same on all four sides — which is what makes
        // the acceptance script's bottom-gap oracle a fixed number
        // (`inset - shadowPad`) instead of a clipped one.
        const pad = m.shadowPad();
        try testing.expectEqual(pad, l.card.left);
        try testing.expectEqual(pad, l.card.top);
        try testing.expectEqual(pad, l.win.width() - l.card.right);
        try testing.expectEqual(pad, l.win.height() - l.card.bottom);
        try testing.expectEqual(m.inset - pad, 800 - l.win.bottom);
    }
}

test "the full table stack plus its overflow marker still lays out" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        var tables: [MAX_ITEMS]i32 = @splat(0);
        for (&tables) |*w| w.* = textW(m, 5);
        var keys: [MAX_KEYS]i32 = @splat(0);
        for (&keys) |*w| w.* = textW(m, 3);
        const l = layout(m, 4000, 800, .{ .tables = &tables, .keys = &keys, .text_h = textH(m) });
        try testing.expect(!l.hidden);
        try testing.expectEqual(MAX_ITEMS, l.table_count);
        try testing.expectEqual(MAX_KEYS, l.key_count);
        // Every chevron but the first is drawn, in order, without overlap.
        for (1..MAX_ITEMS) |i| {
            try testing.expect(!l.chevrons[i].isEmpty());
            try testing.expect(l.chevrons[i].left >= l.tables[i - 1].right);
            try testing.expect(l.tables[i].left >= l.chevrons[i].right);
        }
        for (1..MAX_KEYS) |i| {
            try testing.expect(l.caps[i].left >= l.caps[i - 1].right);
        }
        try testing.expect(l.dots.right <= l.card.right - m.pad_x);
    }
}

test "more items than the layout carries are clamped, not overrun" {
    const m = Metrics.init(1.0);
    var tables: [MAX_ITEMS + 4]i32 = @splat(20);
    var keys: [MAX_KEYS + 4]i32 = @splat(20);
    const l = layout(m, 4000, 800, .{ .tables = &tables, .keys = &keys, .text_h = textH(m) });
    try testing.expectEqual(MAX_ITEMS, l.table_count);
    try testing.expectEqual(MAX_KEYS, l.key_count);
}

test "metrics scale with DPI and never round a hairline out of existence" {
    var scale: f32 = 0.5;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        try testing.expect(m.border >= 1);
        try testing.expect(m.divider_w >= 1);
        try testing.expect(m.dot >= 1);
        try testing.expect(m.dot_gap >= 1);
        try testing.expect(m.glyph >= 1);
        try testing.expect(m.inset >= 1);
        try testing.expect(m.shadowPad() >= 1);
    }
    const one = Metrics.init(1.0);
    try testing.expectEqual(@as(i32, 8), one.inset);
    try testing.expectEqual(@as(i32, 8), one.radius);
    try testing.expectEqual(@as(i32, 12), one.glyph);
    try testing.expectEqual(@as(i32, 12), one.pad_x);
    const two = Metrics.init(2.0);
    try testing.expectEqual(@as(i32, 16), two.inset);
    try testing.expectEqual(@as(i32, 24), two.glyph);
    try testing.expectEqual(@as(i32, 24), two.pad_x);
    try testing.expectEqual(@as(i32, 8), two.dot);
}

test "shareWidths never exceeds its budget, and never starves a name" {
    var out: [4]i32 = undefined;
    const natural = [_]i32{ 100, 50, 25, 5 };

    // Plenty of room: everyone gets what they asked for, and no more.
    shareWidths(&natural, 1000, &out);
    try testing.expectEqualSlices(i32, &natural, &out);

    // Tight: proportional, in budget, nobody at zero.
    for ([_]i32{ 180, 90, 20, 4 }) |budget| {
        shareWidths(&natural, budget, &out);
        var sum: i32 = 0;
        for (out) |w| {
            try testing.expect(w >= 1);
            sum += w;
        }
        try testing.expect(sum <= budget);
    }
}

test "labels clear 4.5:1 and every boundary and glyph clears 3:1" {
    // Sweep the whole gray ramp plus a few real themes: the floors have to
    // hold on the user's background, not on the author's.
    var v: u8 = 0;
    while (true) : (v +|= 1) {
        try checkFloors(.{ .r = v, .g = v, .b = v });
        if (v == 255) break;
    }
    for ([_]Rgb{
        .{ .r = 16, .g = 16, .b = 20 }, // the usual dark terminal
        .{ .r = 253, .g = 246, .b = 227 }, // solarized light
        .{ .r = 0, .g = 43, .b = 54 }, // solarized dark
        .{ .r = 40, .g = 42, .b = 54 }, // dracula
        .{ .r = 128, .g = 128, .b = 128 }, // mid-tone, no room either way
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },
    }) |bg| try checkFloors(bg);
}

fn checkFloors(bg: Rgb) !void {
    const fill = fillColor(bg);
    // Table names on the card.
    try testing.expect(ratio(labelColor(fill), fill) >= TEXT_CONTRAST);
    // Key-cap labels on the cap.
    const cap = capFillColor(fill);
    try testing.expect(ratio(labelColor(cap), cap) >= TEXT_CONTRAST);
    // The card border, the cap border and the divider all share one color.
    try testing.expect(ratio(borderColor(fill), fill) >= CHROME_CONTRAST);
    // The keyboard glyph, the chevrons and the dots.
    try testing.expect(ratio(glyphColor(fill), fill) >= CHROME_CONTRAST);
}

test "dot alphas ride between 0.3 and 1.0, and never all together" {
    var phase: f32 = 0.0;
    while (phase < 1.0) : (phase += 0.01) {
        var lo: f32 = 2.0;
        var hi: f32 = -1.0;
        for (0..DOT_COUNT) |i| {
            const a = dotAlpha(i, phase);
            try testing.expect(a >= 0.3 - 0.001);
            try testing.expect(a <= 1.0 + 0.001);
            lo = @min(lo, a);
            hi = @max(hi, a);
        }
        // Three sine waves a third of a turn apart sum to zero, so they can
        // only ever be equal at zero — which none of them reaches, since the
        // wave is biased to 0.3. That is what makes the row read as MOTION
        // rather than as one block blinking on and off together.
        try testing.expect(hi - lo > 0.01);
    }
    // A full turn returns to where it started.
    try testing.expectApproxEqAbs(dotAlpha(0, 0.0), dotAlpha(0, 1.0), 0.0001);
    // ...and a quarter turn does not, which is what the animation is for.
    try testing.expect(@abs(dotAlpha(0, 0.0) - dotAlpha(0, 0.25)) > 0.1);
}

fn renderAt(bgr: []u32, mask: []u8, scale: f32, phase: f32) Layout {
    const m = Metrics.init(scale);
    const l = layout(m, 1200, 800, sample(m));
    render(bgr, mask, m, l, DARK, phase);
    return l;
}

test "render: the card interior is fully opaque, in the card's own fill" {
    var bgr: [800 * 200]u32 = @splat(0);
    var mask: [800 * 200]u8 = @splat(0);
    const l = renderAt(&bgr, &mask, 1.0, 0.0);
    const w: usize = @intCast(l.win.width());
    // A point inside the card but clear of the glyph, names, caps and dots:
    // just left of the divider, above the content's vertical middle.
    const x: usize = @intCast(l.divider.left - 2);
    const y: usize = @intCast(l.card.top + 1);
    const i = y * w + x;
    try testing.expectEqual(@as(u8, 255), mask[i]);
    const fill = fillColor(DARK);
    try testing.expectEqual(pack(fill.r, fill.g, fill.b), bgr[i]);
}

test "render: the window's own corner is fully transparent" {
    var bgr: [800 * 200]u32 = @splat(0);
    var mask: [800 * 200]u8 = @splat(0);
    _ = renderAt(&bgr, &mask, 1.0, 0.0);
    try testing.expectEqual(@as(u8, 0), mask[0]);
}

test "render: a drop shade falls below the card and fades out" {
    var bgr: [800 * 200]u32 = @splat(0);
    var mask: [800 * 200]u8 = @splat(0);
    const l = renderAt(&bgr, &mask, 1.0, 0.0);
    const w: usize = @intCast(l.win.width());
    const cx: usize = @intCast(@divTrunc(l.card.left + l.card.right, 2));
    const near = mask[@as(usize, @intCast(l.card.bottom + 1)) * w + cx];
    const far = mask[@as(usize, @intCast(@min(l.card.bottom + 4, l.win.height() - 1))) * w + cx];
    try testing.expect(near > 0);
    try testing.expect(far <= near);
    try testing.expect(near < 255);
}

test "render: a key cap is a different color from the card it sits on" {
    var bgr: [800 * 200]u32 = @splat(0);
    var mask: [800 * 200]u8 = @splat(0);
    const l = renderAt(&bgr, &mask, 1.0, 0.0);
    const w: usize = @intCast(l.win.width());
    const cx: usize = @intCast(@divTrunc(l.caps[0].left + l.caps[0].right, 2));
    const cy: usize = @intCast(@divTrunc(l.caps[0].top + l.caps[0].bottom, 2));
    const fill = fillColor(DARK);
    const cap = capFillColor(fill);
    try testing.expectEqual(pack(cap.r, cap.g, cap.b), bgr[cy * w + cx]);
    try testing.expect(bgr[cy * w + cx] != pack(fill.r, fill.g, fill.b));
    // ...and it is still fully opaque: a cap is ON the card, not a hole in it.
    try testing.expectEqual(@as(u8, 255), mask[cy * w + cx]);
}

test "render: the divider is painted in the border color" {
    var bgr: [800 * 200]u32 = @splat(0);
    var mask: [800 * 200]u8 = @splat(0);
    const l = renderAt(&bgr, &mask, 1.0, 0.0);
    const w: usize = @intCast(l.win.width());
    const cx: usize = @intCast(l.divider.left);
    const cy: usize = @intCast(@divTrunc(l.divider.top + l.divider.bottom, 2));
    const fill = fillColor(DARK);
    const border = borderColor(fill);
    try testing.expectEqual(pack(border.r, border.g, border.b), bgr[cy * w + cx]);
}

test "render: the waiting dots change with the phase" {
    var a_bgr: [800 * 200]u32 = @splat(0);
    var a_mask: [800 * 200]u8 = @splat(0);
    var b_bgr: [800 * 200]u32 = @splat(0);
    var b_mask: [800 * 200]u8 = @splat(0);
    const l = renderAt(&a_bgr, &a_mask, 1.0, 0.0);
    // A quarter turn, not a half: the wave is symmetric about its midpoint,
    // so half a turn puts the first dot back at exactly the same alpha.
    _ = renderAt(&b_bgr, &b_mask, 1.0, 0.25);

    const w: usize = @intCast(l.win.width());
    const cy: usize = @intCast(@divTrunc(l.dots.top + l.dots.bottom, 2));
    const cx: usize = @intCast(l.dots.left + @divTrunc(l.dots.width(), 6));
    try testing.expect(a_bgr[cy * w + cx] != b_bgr[cy * w + cx]);
    // The dot is drawn ON the card, so the card's alpha is untouched by the
    // animation — only the color moves.
    try testing.expectEqual(a_mask[cy * w + cx], b_mask[cy * w + cx]);
}

test "render: every scale paints, and none writes out of bounds" {
    for (scales) |scale| {
        var bgr: [1600 * 400]u32 = @splat(0xDEAD);
        var mask: [1600 * 400]u8 = @splat(7);
        const l = renderAt(&bgr, &mask, scale, 0.25);
        const n: usize = @intCast(l.win.width() * l.win.height());
        try testing.expect(n > 0);
        // Wrote exactly the claimed area: the first byte past it is untouched.
        try testing.expectEqual(@as(u8, 7), mask[n]);
        var opaque_px: usize = 0;
        for (mask[0..n]) |a| {
            if (a == 255) opaque_px += 1;
        }
        try testing.expect(opaque_px > 0);
    }
}

test "render: a hidden layout and undersized buffers paint nothing" {
    var bgr: [64]u32 = @splat(0);
    var mask: [64]u8 = @splat(0);
    const m = Metrics.init(1.0);
    render(&bgr, &mask, m, .{}, DARK, 0.0);
    try testing.expectEqual(@as(u32, 0), bgr[0]);
    // A real layout that does not fit the buffers refuses rather than
    // overrunning them.
    render(&bgr, &mask, m, layout(m, 1200, 800, sample(m)), DARK, 0.0);
    try testing.expectEqual(@as(u32, 0), bgr[0]);
}

test "the explainer's hit area is the card and nothing else" {
    for (scales) |scale| {
        const m = Metrics.init(scale);
        const l = layout(m, 1200, 800, sample(m));
        try testing.expect(!l.hidden);

        // Dead center of the card takes the pointer.
        try testing.expect(hitsCard(
            l,
            @divTrunc(l.card.left + l.card.right, 2),
            @divTrunc(l.card.top + l.card.bottom, 2),
        ));
        // Every corner of the card is inside it (half-open on the far edges,
        // the way `containsPoint` reads every other hit box in this app).
        try testing.expect(hitsCard(l, l.card.left, l.card.top));
        try testing.expect(hitsCard(l, l.card.right - 1, l.card.bottom - 1));

        // The shadow allowance is NOT the card: the window's own corner, and
        // one pixel outside each card edge, all fall through to the terminal.
        try testing.expect(!hitsCard(l, 0, 0));
        try testing.expect(!hitsCard(l, l.card.left - 1, l.card.top));
        try testing.expect(!hitsCard(l, l.card.left, l.card.top - 1));
        try testing.expect(!hitsCard(l, l.card.right, l.card.bottom - 1));
        try testing.expect(!hitsCard(l, l.card.right - 1, l.card.bottom));

        // The allowance is real at every scale — otherwise the two assertions
        // above would be testing an empty region.
        try testing.expect(l.card.left > 0);
        try testing.expect(l.card.top > 0);
    }
}

test "a hidden pill takes no pointer anywhere" {
    const m = Metrics.init(1.0);
    // Too small for even the keys: `layout` hides, and a hidden layout must
    // not claim a hit at a rect it never placed.
    const l = layout(m, 20, 20, sample(m));
    try testing.expect(l.hidden);
    try testing.expect(!hitsCard(l, 0, 0));
    try testing.expect(!hitsCard(l, 10, 10));
    // The default (never laid out) is hidden too.
    try testing.expect(!hitsCard(.{}, 0, 0));
}

test "the explainer says what a key table is, in Mac's words" {
    // The heading names the thing on screen and the body answers the question
    // the name raises. A tooltip title is capped at 99 characters by comctl32.
    try testing.expect(EXPLAINER_TITLE.len > 0);
    try testing.expect(EXPLAINER_TITLE.len < 99);
    try testing.expect(std.mem.indexOf(u8, EXPLAINER_BODY, "keybindings") != null);
    try testing.expect(std.mem.indexOf(u8, EXPLAINER_BODY, "deactivated") != null);
    // Plain ASCII prose: the tooltip is measured and drawn by comctl32 with no
    // mnemonic processing (TTS_NOPREFIX), and an `&` would still read oddly.
    for (EXPLAINER_TITLE ++ EXPLAINER_BODY) |c| {
        try testing.expect(c >= 0x20 and c < 0x7F);
        try testing.expect(c != '&');
    }
}
