//! Pure geometry + policy for the viewer table-of-contents card (T160), the
//! Windows port of Mac's `ViewerTOCPanel` + `ViewerSidePanel` +
//! `ViewerView.desiredSidePanelLayout`: which presentation a pane's width
//! calls for (left gutter vs floating overlay vs none), where the card and its
//! rows sit, how wide the user may drag it, and how much gutter the page is
//! asked to reserve.
//!
//! Pure — no OS imports — so the whole module asserts in the none-runtime lane
//! at 1.0/1.25/1.5/2.0 (the design-system rule: most spacing defects are
//! invisible at 1.0 and obvious at 1.25). The native half is
//! `ViewerTOCPanel.zig`, which owns the window, the fonts and the paint.
//!
//! Every number that has a Mac twin cites it, because the two platforms must
//! read as one design: the thresholds and row metrics come from
//! `ViewerView.swift` (`sidePanelGutterMinWidth` etc.) and
//! `ViewerSidePanel.swift` (`SidePanelRow`).

const std = @import("std");
const banner_card = @import("banner_card.zig");

// ---------------------------------------------------------------------------
// Design constants (DIP)
// ---------------------------------------------------------------------------

/// Pane width at or above which the card gets its own gutter; below it the
/// gutter would squeeze the document column too far to read and the card
/// floats over the content instead. Mac: `sidePanelGutterMinWidth = 720`.
pub const gutter_min_dip: f32 = 720.0;

/// Card width: the default and the range the user may drag it to. One width
/// serves both layouts and every viewer pane (it is a persisted preference,
/// `viewer_prefs.zig`). Mac: `sidePanelDefaultWidth/MinWidth/MaxWidth`.
pub const card_default_dip: f32 = 240.0;
pub const card_min_dip: f32 = 170.0;
pub const card_max_dip: f32 = 460.0;

/// The one outer margin. The card floats this far inside every edge, and the
/// document leaves the same margin on all four of its own — which is what
/// makes a TOC card and a banner in the pane next door line up at their
/// corners (docs/claude/viewers.md: "Margins are one number"). Tied to the banner card's
/// margin BY IDENTITY, not by a copied 12: if either moved alone the corners
/// would stop lining up, so there is exactly one number to move.
pub const margin_dip: f32 = banner_card.MARGIN;

/// Row metrics, taken off a macOS sidebar via Mac's `SidePanelRow` rather
/// than invented: the selection fill insets from the card's edges, the label
/// insets again inside the fill, and the row is tall enough that the fill
/// reads as a pill around the label instead of a stripe behind it.
pub const fill_inset_dip: f32 = 8;
pub const text_inset_dip: f32 = 10;
pub const row_v_pad_dip: f32 = 7;
pub const row_corner_dip: f32 = 6;
/// One indent step per heading depth. Mac: `SidePanelRow.indentStep`.
pub const indent_step_dip: f32 = 11;
/// Where a row's LABEL sits, measured from the card's edge; the header
/// caption aligns to this, not to the fill inset. Mac: `labelInset`.
pub const label_inset_dip: f32 = fill_inset_dip + text_inset_dip;

/// Indent steps are capped so a deeply nested section still fits the card.
/// Mac: `ViewerTOCItem.maxDepth`.
pub const max_depth: u8 = 3;

/// A row's text wraps to at most this many lines. Mac: `.lineLimit(2)`.
pub const max_row_lines: u8 = 2;

/// The pinned header's vertical padding around its "CONTENTS" caption.
/// Mac: `.padding(.vertical, 10)`.
pub const header_pad_v_dip: f32 = 10;

/// The card's minimum useful height; below it the card is not worth the strip
/// of document it takes. Mac: `max(80, ...)` in `updateSidePanelLayout`.
pub const card_min_h_dip: f32 = 80;

/// Total grab width of the resize handle, centered on the card's right edge —
/// about 3 DIP of slop each side of the 1px rim, because a target you have to
/// hit exactly is a target you miss. Mac: `SidePanelResizeHandle.grabWidth`.
pub const handle_grab_dip: f32 = 7;

/// Floor for the card width in the compact (overlay) layout, where the pane
/// itself may be narrower than the preference. Mac: `max(120, ...)`.
pub const compact_floor_dip: f32 = 120.0;

// ---------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------

/// Which presentation the pane's current width calls for. Fewer than two
/// headings means no card at all — one heading is a title, not a table of
/// contents, and a card with nothing useful in it is a strip of the document
/// taken away for nothing (the page's own `indexHeadings` applies the same
/// floor, so this is defense in depth, not the only gate).
pub const Mode = enum { hidden, gutter, compact };

pub fn mode(pane_w_dip: f32, item_count: usize) Mode {
    if (item_count < 2) return .hidden;
    return if (pane_w_dip >= gutter_min_dip) .gutter else .compact;
}

/// Clamp a dragged card width: the allowed range, capped so the card never
/// starves the document beside it (the text column keeps at least the width
/// the gutter layout is predicated on). Mac: `setSidePanelWidth`.
pub fn clampWidth(proposed_dip: f32, pane_w_dip: f32) f32 {
    const pane_cap = @max(card_min_dip, pane_w_dip - gutter_min_dip / 2);
    return @min(@min(card_max_dip, pane_cap), @max(card_min_dip, proposed_dip));
}

/// The card width the compact overlay actually uses: the shared preference,
/// clamped to what the pane can hold. Mac: `min(sidePanelWidth, max(120,
/// bounds.width - outerMargin * 2))`.
///
/// The FLOOR is capped by the pane as well (T1130). Mac's expression floors the
/// card at 120 unconditionally and relies on `clipsToBounds` to hide whatever
/// hangs off the edge, which is the same shape as the defect 463dcb0b4 fixed
/// one level up: chrome that insists on a minimum the pane cannot pay. Squeeze
/// a pane to 62 DIP and that produces a card whose right half - rows, scrollbar
/// and the rounded corner that says where it ends - is cut off by the pane
/// rather than laid out inside it. A viewer is a leaf in the split tree and the
/// tree decides the width, so the card compresses to the pane instead. A pane
/// wide enough to pay the floor is unaffected, which is every pane above
/// 120 + 2 * margin DIP.
pub fn compactCardWidth(pref_dip: f32, pane_w_dip: f32) f32 {
    const avail = pane_w_dip - margin_dip * 2;
    const wanted = @min(pref_dip, @max(compact_floor_dip, avail));
    // Never wider than the pane, and never inverted: a degenerate pane still
    // yields a sliver rather than a negative width.
    return @max(@min(wanted, avail), 1.0);
}

/// How much gutter the page reserves (CSS px == DIP): the card's LEFT margin
/// plus the card — not a margin on each side. The space between the card's
/// right edge and the text is the document's own padding (viewer.css uses the
/// same 12px on all four sides), so that gap is one number in one place.
/// Mac: `GlassCard.outerMargin + cardWidth` in `updateSidePanelLayout`.
pub fn gutterCssWidth(card_w_dip: f32) f32 {
    return margin_dip + card_w_dip;
}

/// Indent depth for a heading, relative to the document's own top-most level,
/// so a file whose headings start at `##` is not indented a step for no
/// reason. Mac: `ViewerTOCItem.list(from:)`.
pub fn depthOf(level: u8, top_level: u8) u8 {
    if (level <= top_level) return 0;
    return @min(max_depth, level - top_level);
}

/// The shallowest heading level in a document, or null when it has none.
pub fn topLevel(levels: []const u8) ?u8 {
    if (levels.len == 0) return null;
    var top: u8 = levels[0];
    for (levels[1..]) |l| top = @min(top, l);
    return top;
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

pub fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

/// Everything the panel window needs to place itself for one pane size, in
/// physical pixels. Coordinates are relative to the pane's CONTENT area (the
/// client rect below the nav bar's inset, when the bar is visible).
pub const Layout = struct {
    which: Mode,
    /// The panel WINDOW's rect. In gutter mode this is the whole left strip
    /// (the page reserves it as padding, so everything behind the window is
    /// the document's own blank background); in compact mode it is exactly
    /// the card, which floats over live content and must not cover more than
    /// the card paints.
    window: Rect = .{},
    /// The card, in WINDOW coordinates.
    card: Rect = .{},
    /// The resize grab band, in WINDOW coordinates, straddling the card's
    /// right edge. Empty in compact mode — the overlay floats over the
    /// document like a menu; there is no gutter for a resize to redistribute.
    handle: Rect = .{},
    /// The card width in DIP that was actually used (the compact clamp may
    /// have shrunk the preference).
    card_w_dip: f32 = 0,

    /// Compute the panel placement.
    ///
    /// `content_w`/`content_h`: the pane's content area in px. `pref_dip`:
    /// the shared width preference. `needed_h`: the card content's measured
    /// height in px (header + all rows); the card sizes to it, capped by the
    /// space available.
    pub fn init(
        scale: f32,
        content_w: i32,
        content_h: i32,
        pref_dip: f32,
        needed_h: i32,
        item_count: usize,
    ) Layout {
        const pane_w_dip = @as(f32, @floatFromInt(content_w)) / scale;
        const which = mode(pane_w_dip, item_count);
        if (which == .hidden) return .{ .which = .hidden };

        const margin = px(margin_dip, scale);
        const card_w_dip = switch (which) {
            .gutter => clampWidth(pref_dip, pane_w_dip),
            .compact => compactCardWidth(pref_dip, pane_w_dip),
            .hidden => unreachable,
        };
        const card_w = px(card_w_dip, scale);

        // The card sizes to its content, capped by the pane: at most the
        // content height minus a margin above and below, at least the useful
        // minimum (a degenerate pane still gets a sliver rather than an
        // inverted rect).
        const max_card_h = @max(px(card_min_h_dip, scale), content_h - 2 * margin);
        const card_h = @max(@min(needed_h, max_card_h), 1);

        switch (which) {
            .gutter => {
                // Window: the whole gutter strip (card + a margin each side,
                // full content height). The strip behind it is the page's
                // reserved padding, so an opaque window there covers nothing.
                const win = Rect{
                    .left = 0,
                    .top = 0,
                    .right = 2 * margin + card_w,
                    .bottom = @max(content_h, 1),
                };
                const card = Rect{
                    .left = margin,
                    .top = margin,
                    .right = margin + card_w,
                    .bottom = margin + card_h,
                };
                const grab = px(handle_grab_dip, scale);
                return .{
                    .which = which,
                    .window = win,
                    .card = card,
                    .handle = .{
                        .left = card.right - @divTrunc(grab, 2),
                        .top = card.top,
                        .right = card.right - @divTrunc(grab, 2) + grab,
                        .bottom = card.bottom,
                    },
                    .card_w_dip = card_w_dip,
                };
            },
            .compact => {
                // Window: exactly the card, floating a margin inside the
                // content's top-left. It sits over live document text, so it
                // covers only what the card paints (the native side clips the
                // window to the card's rounded shape).
                //
                // The width is re-clamped HERE in PIXELS as well as in DIP
                // (T1130): `compactCardWidth` already keeps the card inside
                // the pane, but two independent roundings — the pane into DIP
                // and the card back into pixels — can each round up, and one
                // pixel past the pane edge is still a card the pane has to
                // clip. The clamp is the invariant; the DIP arithmetic is how
                // the card gets its shape.
                const fit_w = @max(@min(card_w, content_w - margin), 1);
                const win = Rect{
                    .left = margin,
                    .top = margin,
                    .right = margin + fit_w,
                    .bottom = margin + card_h,
                };
                return .{
                    .which = which,
                    .window = win,
                    .card = .{ .left = 0, .top = 0, .right = fit_w, .bottom = card_h },
                    // Report what was PAINTED, not what was asked for, so the
                    // drag's start width and the page's gutter agree with the
                    // card on screen.
                    .card_w_dip = @as(f32, @floatFromInt(fit_w)) / scale,
                };
            },
            .hidden => unreachable,
        }
    }
};

/// The pinned header's height: its caption line plus the vertical padding.
pub fn headerHeight(caption_line_h: i32, scale: f32) i32 {
    return caption_line_h + 2 * px(header_pad_v_dip, scale);
}

/// The compact overlay's slide (T543), and the pinned header's translucency.
///
/// Mac parks the compact card off the leading edge and animates a Core
/// Animation transform on toggle (`ViewerView.applySidePanelState`, 0.26s);
/// GDI has no such thing, so the card's window is stepped across by a timer
/// and the curve lives here, where it is asserted without a window.
///
/// The state is ONE number, `t` in 0 (parked off the left edge) through 1
/// (fully in), walking toward whatever the toggle currently wants. That is
/// what makes a fast double-toggle land correctly without re-reading anything
/// at the end of the animation: reversing simply changes which end `t` is
/// walking to, from wherever the card actually is.
pub const slide_ms: f32 = 150.0;

/// Alpha the pinned header composites its backdrop back at, 0-255. Mac's
/// `SidePanelHeader` sits on `glassBackdrop()` and the rows blur through it;
/// GDI has no live blur, so the header re-composites the card's own backdrop
/// at just under opaque, which reads as translucency without one. Low enough
/// that a row scrolling under keeps a recognizable shape, high enough that
/// the caption over it never competes with the text passing beneath.
pub const header_alpha: u8 = 217;

/// Ease-out cubic. Monotonic and fixed at both ends, so it is safe to apply
/// to a `t` that can reverse mid-flight.
pub fn slideEase(t: f32) f32 {
    const c = std.math.clamp(t, 0, 1);
    const inv = 1 - c;
    return 1 - inv * inv * inv;
}

/// Step `t` toward `want` for one frame of `dt_ms`, landing exactly on the
/// target rather than approaching it (a slide that never quite arrives leaves
/// a card one pixel off its resting place forever).
pub fn slideStep(t: f32, want: f32, dt_ms: f32) f32 {
    const d = @max(dt_ms, 0) / slide_ms;
    if (want > t) return @min(want, t + d);
    return @max(want, t - d);
}

/// Where the compact card's window sits for one point of the slide:
/// `resting_x` when fully in, entirely off the content's left edge when fully
/// out.
pub fn slideX(t: f32, resting_x: i32, card_w: i32) i32 {
    const out: f32 = @floatFromInt(-card_w);
    const in: f32 = @floatFromInt(resting_x);
    return @intFromFloat(@round(out + (in - out) * slideEase(t)));
}

/// One row's height from its wrapped line count.
pub fn rowHeight(lines: i32, line_h: i32, scale: f32) i32 {
    return lines * line_h + 2 * px(row_v_pad_dip, scale);
}

/// Where a row's text begins, in CARD coordinates, for one indent depth.
/// Composed from individually-rounded parts so an indent step is EXACTLY
/// `px(indent_step_dip)` at every scale — rounding one summed value instead
/// makes the step drift a pixel at 1.25 (the class of defect the four-scale
/// sweep exists to catch).
pub fn rowTextLeft(depth: u8, scale: f32) i32 {
    return px(fill_inset_dip, scale) + px(text_inset_dip, scale) +
        @as(i32, depth) * px(indent_step_dip, scale);
}

/// The width available to a row's text at one indent depth.
pub fn rowTextWidth(card_w: i32, depth: u8, scale: f32) i32 {
    const right = px(text_inset_dip, scale) + px(fill_inset_dip, scale);
    return @max(card_w - rowTextLeft(depth, scale) - right, 1);
}

/// The gap between the parts of a diff pane's file-tree row — the `sm` step of
/// the 4 DIP spacing scale, the same one the type ramp's leading uses. One
/// number for the badge-to-name gap and the name-to-counts gap, because two
/// numbers here is exactly the per-component fudge the margin rule forbids.
pub const row_gap_dip: f32 = 4;

/// The x extents of a diff-tree row's parts, in CARD coordinates (T464).
///
/// A file row is `[status] name … +N −M`; a folder row is `[chevron] title`
/// with no counts. Both are the same three boxes, so both come out of one
/// function: the leading box is the badge or the chevron, `counts_w` is zero
/// for a folder, and a `.section` row simply uses `rowTextLeft` the way a
/// heading does.
///
/// Composed from the SAME `rowTextLeft` / `rowTextWidth` insets the table of
/// contents uses, so the two things the one card can show line up with each
/// other and with the document beside them.
pub const RowBoxes = struct {
    badge_left: i32,
    badge_right: i32,
    name_left: i32,
    name_right: i32,
    counts_left: i32,
    counts_right: i32,

    pub fn nameWidth(self: RowBoxes) i32 {
        return @max(self.name_right - self.name_left, 1);
    }
};

pub fn treeRowBoxes(
    card_w: i32,
    depth: u8,
    scale: f32,
    badge_w: i32,
    counts_w: i32,
) RowBoxes {
    const gap = px(row_gap_dip, scale);
    const badge_left = rowTextLeft(depth, scale);
    const badge_right = badge_left + @max(badge_w, 0);
    const name_left = badge_right + (if (badge_w > 0) gap else 0);
    const right = card_w - px(text_inset_dip, scale) - px(fill_inset_dip, scale);
    const counts_left = if (counts_w > 0) right - counts_w else right;
    const name_right = @max(
        name_left + 1,
        if (counts_w > 0) counts_left - gap else right,
    );
    return .{
        .badge_left = badge_left,
        .badge_right = badge_right,
        .name_left = name_left,
        .name_right = name_right,
        .counts_left = counts_left,
        .counts_right = right,
    };
}

/// A status chip's width for its measured label: a capsule that is never
/// narrower than it is tall, so a one-letter badge is a circle rather than a
/// squashed lozenge. The design system's named capsule exception (a chip
/// reports a state, it does not offer a command).
pub fn badgeWidth(text_w: i32, line_h: i32, scale: f32) i32 {
    return @max(line_h, text_w + 2 * px(row_gap_dip, scale));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "mode: the 720 DIP threshold, and the two-heading floor" {
    // One heading is a title; no card regardless of width.
    try testing.expectEqual(Mode.hidden, mode(1000, 0));
    try testing.expectEqual(Mode.hidden, mode(1000, 1));
    // The threshold is on PANE width in DIP, inclusive at 720.
    try testing.expectEqual(Mode.gutter, mode(720, 2));
    try testing.expectEqual(Mode.compact, mode(719.5, 2));
    try testing.expectEqual(Mode.compact, mode(300, 5));
    try testing.expectEqual(Mode.gutter, mode(1400, 5));
}

test "clampWidth: range and the document-starvation cap" {
    // Inside the range, wide pane: unchanged.
    try testing.expectEqual(@as(f32, 240), clampWidth(240, 1400));
    // Below/above the range: clamped.
    try testing.expectEqual(card_min_dip, clampWidth(10, 1400));
    try testing.expectEqual(card_max_dip, clampWidth(900, 1400));
    // A pane barely wide enough for the gutter caps the card so the text
    // column keeps at least half the gutter threshold.
    const cap = clampWidth(460, 740);
    try testing.expectEqual(@as(f32, 740 - 720.0 / 2.0), cap);
    // The cap never drops below the minimum.
    try testing.expectEqual(card_min_dip, clampWidth(460, 100));
}

test "compactCardWidth: preference clamped to the pane, with a floor" {
    try testing.expectEqual(@as(f32, 240), compactCardWidth(240, 700));
    // A narrow pane shrinks the card to fit inside its margins...
    try testing.expectEqual(@as(f32, 300 - 24), compactCardWidth(460, 300));
    // ...and it holds at the floor while the pane can still pay for it.
    try testing.expectEqual(compact_floor_dip, compactCardWidth(460, compact_floor_dip + margin_dip * 2));
    // T1130: below that, the PANE wins. The floor used to hold regardless,
    // which put a 120 DIP card in a 76 DIP pane and let the pane clip the
    // half that would not fit - rows, scrollbar and the rounded corner that
    // says where the card ends.
    try testing.expectEqual(@as(f32, 100 - 24), compactCardWidth(460, 100));
    // Never inverted, however degenerate the pane.
    try testing.expect(compactCardWidth(460, 10) >= 1);
    try testing.expect(compactCardWidth(460, 0) >= 1);
}

test "T1130: the compact card never reaches past the pane, at any width" {
    for (scales) |scale| {
        var pane_dip: f32 = 20;
        while (pane_dip <= 700) : (pane_dip += 1) {
            const content_w = px(pane_dip, scale);
            const l = Layout.init(scale, content_w, px(600, scale), 240, px(200, scale), 3);
            if (l.which == .hidden) continue;
            try testing.expect(l.window.left >= 0);
            try testing.expect(l.window.right <= content_w);
            try testing.expect(l.window.width() >= 1);
            // Two independent clamps, and the test has to hold BOTH or the
            // pixel one alone would mask a card whose ROWS were measured at
            // the wrong width and then cropped. The width the card is laid
            // out to must itself fit the pane.
            if (l.which == .compact) {
                const wanted = compactCardWidth(240, pane_dip);
                try testing.expect(wanted * scale <= @as(f32, @floatFromInt(content_w)));
                try testing.expect(l.card_w_dip * scale <= @as(f32, @floatFromInt(content_w)));
            }
        }
    }
}

test "depth derives from the document's own top level, capped" {
    // Mac's semantics: a file whose headings start at ## is not indented a
    // step for no reason.
    try testing.expectEqual(@as(?u8, 2), topLevel(&.{ 2, 3, 4 }));
    try testing.expectEqual(@as(u8, 0), depthOf(2, 2));
    try testing.expectEqual(@as(u8, 1), depthOf(3, 2));
    try testing.expectEqual(@as(u8, 2), depthOf(4, 2));
    // Depth caps at max_depth so an h6 under an h1 still fits the card.
    try testing.expectEqual(max_depth, depthOf(6, 1));
    // A heading above the top level (impossible, but defensive) is 0.
    try testing.expectEqual(@as(u8, 0), depthOf(1, 2));
    try testing.expectEqual(@as(?u8, null), topLevel(&.{}));
}

test "documentAlignsToTheCard: one margin, everywhere, at every scale" {
    // The gutter the page reserves is the card's left margin plus the card —
    // and the margin IS the banner card's outer margin, by identity. This is
    // the win32 equivalent of Mac's `documentAlignsToTheCard` assert: the gap
    // between the card and the text is the document's own padding, the same
    // 12, so the card and a banner in the pane next door line up at their
    // corners.
    try testing.expectEqual(banner_card.MARGIN, margin_dip);
    try testing.expectEqual(@as(f32, 12 + 240), gutterCssWidth(240));

    for (scales) |scale| {
        const l = Layout.init(scale, px(1200, scale), px(600, scale), 240, px(400, scale), 5);
        try testing.expectEqual(Mode.gutter, l.which);
        const margin = px(margin_dip, scale);
        // Uniform margin: left of card, above card, and right of card to the
        // window's (= the gutter's) edge.
        try testing.expectEqual(margin, l.card.left);
        try testing.expectEqual(margin, l.card.top);
        try testing.expectEqual(margin, l.window.right - l.card.right);
        // And the page's reserved gutter ends exactly AT the card's right
        // edge — the gap between the card and the text is the document's own
        // padding (the same 12), not a second number added here.
        try testing.expectEqual(
            px(gutterCssWidth(l.card_w_dip), scale),
            l.card.right,
        );
    }
}

test "gutter layout: window is the full strip, card sizes to content" {
    for (scales) |scale| {
        const content_h = px(600, scale);
        const needed = px(300, scale);
        const l = Layout.init(scale, px(1200, scale), content_h, 240, needed, 4);
        try testing.expectEqual(Mode.gutter, l.which);
        // The strip spans the whole content height.
        try testing.expectEqual(@as(i32, 0), l.window.top);
        try testing.expectEqual(content_h, l.window.bottom);
        // The card takes its measured height (content fits here).
        try testing.expectEqual(needed, l.card.height());
        // A taller document caps at the content minus margins.
        const l2 = Layout.init(scale, px(1200, scale), content_h, 240, px(5000, scale), 4);
        try testing.expectEqual(content_h - 2 * px(margin_dip, scale), l2.card.height());
    }
}

test "compact layout: window IS the card, no handle" {
    for (scales) |scale| {
        const l = Layout.init(scale, px(500, scale), px(600, scale), 240, px(200, scale), 3);
        try testing.expectEqual(Mode.compact, l.which);
        const margin = px(margin_dip, scale);
        try testing.expectEqual(margin, l.window.left);
        try testing.expectEqual(margin, l.window.top);
        try testing.expectEqual(l.window.width(), l.card.width());
        try testing.expectEqual(l.window.height(), l.card.height());
        try testing.expectEqual(@as(i32, 0), l.handle.width());
        // The compact card still honors the width preference when it fits.
        try testing.expectEqual(px(240, scale), l.card.width());
    }
}

test "resize handle straddles the card's right edge, gutter only" {
    for (scales) |scale| {
        const l = Layout.init(scale, px(1200, scale), px(600, scale), 240, px(300, scale), 4);
        const grab = px(handle_grab_dip, scale);
        try testing.expectEqual(grab, l.handle.width());
        // Centered on the card's right edge (within integer rounding).
        const center = l.handle.left + @divTrunc(l.handle.width(), 2);
        try testing.expect(@abs(center - l.card.right) <= 1);
        // Spans the card's height.
        try testing.expectEqual(l.card.top, l.handle.top);
        try testing.expectEqual(l.card.bottom, l.handle.bottom);
    }
}

test "hidden layout for too few items regardless of size" {
    const l = Layout.init(1.0, 1200, 600, 240, 300, 1);
    try testing.expectEqual(Mode.hidden, l.which);
    try testing.expectEqual(@as(i32, 0), l.window.width());
}

test "row metrics: label inset, indent steps, and heights at every scale" {
    for (scales) |scale| {
        // The label inset is the fill inset plus the text inset — the header
        // aligns to it (Mac's labelInset).
        try testing.expectEqual(
            px(fill_inset_dip, scale) + px(text_inset_dip, scale),
            rowTextLeft(0, scale),
        );
        // Each depth adds one indent step.
        const step = rowTextLeft(1, scale) - rowTextLeft(0, scale);
        try testing.expectEqual(px(indent_step_dip, scale), step);
        try testing.expectEqual(rowTextLeft(0, scale) + 3 * step, rowTextLeft(3, scale));

        // Rows: text plus 7 DIP above and below; two-line rows grow by
        // exactly one line.
        const line_h = px(16, scale);
        try testing.expectEqual(
            line_h + 2 * px(row_v_pad_dip, scale),
            rowHeight(1, line_h, scale),
        );
        try testing.expectEqual(
            2 * line_h + 2 * px(row_v_pad_dip, scale),
            rowHeight(2, line_h, scale),
        );

        // Text width: symmetric insets, never negative even in a sliver.
        const w = rowTextWidth(px(240, scale), 0, scale);
        try testing.expectEqual(
            px(240, scale) - 2 * (px(fill_inset_dip, scale) + px(text_inset_dip, scale)),
            w,
        );
        try testing.expectEqual(@as(i32, 1), rowTextWidth(4, 3, scale));
    }
}

test "T543 slide: the curve is fixed at both ends and never goes backwards" {
    try testing.expectEqual(@as(f32, 0), slideEase(0));
    try testing.expectEqual(@as(f32, 1), slideEase(1));
    // Clamped, so a step that overshoots cannot throw the card past its rest.
    try testing.expectEqual(@as(f32, 0), slideEase(-0.5));
    try testing.expectEqual(@as(f32, 1), slideEase(2));
    var prev: f32 = -1;
    var i: u32 = 0;
    while (i <= 20) : (i += 1) {
        const e = slideEase(@as(f32, @floatFromInt(i)) / 20.0);
        try testing.expect(e >= prev);
        prev = e;
    }
    // Ease-OUT: most of the distance is covered in the first half.
    try testing.expect(slideEase(0.5) > 0.5);
}

test "T543 slide: a step lands exactly on the target, from either side" {
    // Opening: one full duration's worth of frames arrives, and stops there.
    try testing.expectEqual(@as(f32, 1), slideStep(0, 1, slide_ms));
    try testing.expectEqual(@as(f32, 1), slideStep(0.9, 1, slide_ms));
    // Closing walks the same number back down and stops at 0.
    try testing.expectEqual(@as(f32, 0), slideStep(0.2, 0, slide_ms));
    // A frame is a fraction of the distance, in the right direction.
    try testing.expect(slideStep(0, 1, slide_ms / 2) > 0);
    try testing.expect(slideStep(0.5, 1, 15) > 0.5);
    try testing.expect(slideStep(0.5, 0, 15) < 0.5);
    // A stalled frame (a clock that went backwards) moves nothing.
    try testing.expectEqual(@as(f32, 0.5), slideStep(0.5, 1, -10));
}

test "T543 slide: a toggle mid-flight reverses from where the card is" {
    // Half open, then the user toggles shut: the card walks back from 0.5
    // rather than restarting at 1, and reaches the parked position in less
    // than a full duration.
    var t: f32 = slideStep(0, 1, slide_ms / 2);
    try testing.expect(t > 0 and t < 1);
    const from = t;
    t = slideStep(t, 0, slide_ms / 4);
    try testing.expect(t < from);
    try testing.expectEqual(@as(f32, 0), slideStep(t, 0, slide_ms));
}

test "T543 slide: fully out clears the content edge, fully in is the rest" {
    const resting: i32 = 12;
    const card_w: i32 = 260;
    try testing.expectEqual(resting, slideX(1, resting, card_w));
    // Parked: the card's right edge is at the content's left edge, so no
    // pixel of it is on screen.
    try testing.expectEqual(-card_w, slideX(0, resting, card_w));
    // Mid-flight it is somewhere between, and monotonic in t.
    var prev: i32 = slideX(0, resting, card_w);
    var i: u32 = 1;
    while (i <= 20) : (i += 1) {
        const x = slideX(@as(f32, @floatFromInt(i)) / 20.0, resting, card_w);
        try testing.expect(x >= prev);
        try testing.expect(x <= resting);
        prev = x;
    }
}

test "header height is the caption line plus its padding" {
    for (scales) |scale| {
        const line = px(16, scale);
        try testing.expectEqual(line + 2 * px(header_pad_v_dip, scale), headerHeight(line, scale));
    }
}

test "tree row boxes: one inset scheme, shared with the table of contents" {
    for (scales) |scale| {
        const card_w = px(240, scale);
        for ([_]u8{ 0, 1, 2, 3 }) |depth| {
            const b = treeRowBoxes(card_w, depth, scale, px(14, scale), px(30, scale));
            // The leading box starts exactly where a heading's text would, so
            // a contents card and a file card line up on the same left edge.
            try testing.expectEqual(rowTextLeft(depth, scale), b.badge_left);
            // And the row ends on the same right inset the heading text does.
            try testing.expectEqual(
                rowTextLeft(depth, scale) + rowTextWidth(card_w, depth, scale),
                b.counts_right,
            );
            // The gap is the one step, on both sides of the name.
            try testing.expectEqual(px(row_gap_dip, scale), b.name_left - b.badge_right);
            try testing.expectEqual(px(row_gap_dip, scale), b.counts_left - b.name_right);
            try testing.expect(b.nameWidth() >= 1);
        }
    }
}

test "tree row boxes: a folder has no counts and reaches the right inset" {
    for (scales) |scale| {
        const card_w = px(240, scale);
        const b = treeRowBoxes(card_w, 1, scale, px(12, scale), 0);
        try testing.expectEqual(b.counts_right, b.name_right);
        try testing.expectEqual(b.counts_right, b.counts_left);
    }
}

test "tree row boxes: a starved card still yields a positive name box" {
    for (scales) |scale| {
        // Narrower than the insets themselves, at the deepest indent.
        const b = treeRowBoxes(px(40, scale), max_depth, scale, px(14, scale), px(40, scale));
        try testing.expect(b.nameWidth() >= 1);
    }
}

test "badgeWidth: never narrower than tall, so a letter chip is a circle" {
    for (scales) |scale| {
        const line_h = px(15, scale);
        try testing.expectEqual(line_h, badgeWidth(px(4, scale), line_h, scale));
        const wide = badgeWidth(px(40, scale), line_h, scale);
        try testing.expectEqual(px(40, scale) + 2 * px(row_gap_dip, scale), wide);
    }
}
