//! Pure geometry for the win32 tab strip (T202). No OS imports, so these unit
//! tests run in every app-runtime lane (the `split_geometry.zig` pattern).
//! The painting half is `paintTabBar` in Window.zig; the hit tests
//! (`handleTabBarClick`, `handleTabBarMouseMove`, `handleTabBarRightClick`)
//! consume the same rects, which is what keeps what you see and what you can
//! click from drifting apart.
//!
//! Target and measurements: `docs/design/win32-tab-strip.md`. The short
//! version, from reading pixels off a live Windows Terminal:
//!
//!   * A tab is NEVER handed the remainder of the strip. The old code gave
//!     the last tab `available - x`, so a single tab spanned the whole window;
//!     that one rule produced three of the four things the user called amateur
//!     (close button flung to the far edge, "+" jammed against the tab, and a
//!     full-width accent rule). That anti-stretch rule is permanent.
//!   * What a tab IS: its own content's width (title + padding), capped at
//!     **50% of the tab run** and floored at `min_tab_w`. Only when the
//!     preferred widths do not all fit does the strip fall back to the equal
//!     share T202 shipped, clamped to `[min_tab_w, cap]`, and only then does a
//!     title ellipsize. T202's fixed `max_tab_w = 200 DIP` is gone: it
//!     truncated titles with 1000px of empty strip beside them (T235, design
//!     system §6b). Measuring Windows Terminal's `TabWidthMode="Equal"` was
//!     right; concluding we had to copy its *algorithm* was too literal.
//!   * This module still measures no text. The caller measures the titles and
//!     passes preferred widths IN, which is what keeps the whole strip
//!     unit-testable with no window, no font and no DPI.
//!   * The "+" travels with the last tab (WinUI `AddTabButton`); the menu
//!     button is pinned right (WinUI `TabStripFooter`). Pinning both right
//!     made them read as one undifferentiated cluster.
//!   * Tabs can never be laid out under the button band. When they will not
//!     all fit at `min_tab_w`, the ones that do not fit get NO rect at all —
//!     invisible and unhittable — instead of being drawn off the end and
//!     painted over.

const std = @import("std");
const testing = std.testing;
const icon_button = @import("icon_button.zig");

/// Negative control for `test/win32/tab-strip.ps1` (project standard: an
/// acceptance script has to be SHOWN to fail, or it is not evidence). Flip to
/// `true`, rebuild `-Dapp-runtime=win32`, and re-run the script: it restores
/// the pre-T202 rule where the last tab is handed whatever width is left, so
/// the single-tab-width, tab-width-clamp and last-tab→"+" gap assertions must
/// fail — and the accent-rule and hit-test assertions must NOT.
///
/// Left in the source rather than behind a build option so the control is one
/// edit away from any future reader of this module, and so the unit tests
/// below pin the shipped (`false`) behavior on every build.
const T202_NEUTERED = false;

/// The strip speaks the same rectangle the rest of the chrome does — one
/// definition, in `icon_button.zig`, re-exported here so existing
/// `tab_strip.Rect` call sites are unchanged.
pub const Rect = icon_button.Rect;

/// Every DIP constant the strip is built from, resolved to physical pixels for
/// one DPI scale. Values and their rationale: `docs/design/win32-tab-strip.md`.
pub const Metrics = struct {
    /// Strip height, 40 DIP. It is NOT a free number: the band below
    /// `tab_top_pad` has to hold the shared 28 DIP icon-button square with
    /// `pad_sm` clear above and below it, which is 4 + 4 + 28 + 4 = 40. Size
    /// the container to the control, never the reverse — centering a 26 DIP
    /// square in the old 29 DIP band produced 1-2 px of "padding" that landed
    /// differently at every scale, which is the user's "no bottom gap" (T232,
    /// design system §0).
    ///
    /// It used to be 32 DIP, chosen against Windows Terminal's measured 40 on
    /// the grounds that WT's strip IS its titlebar and spends 8 DIP of it on a
    /// drag region. That reasoning was sound and the conclusion still wrong:
    /// the 8 DIP it saved came out of the buttons' breathing room, not out of
    /// a drag region we do not have.
    bar_h: i32,
    /// Strip background left above the chiclet, so its rounded top corners
    /// have something to read against.
    tab_top_pad: i32,
    /// The 4 DIP spacing step, once. Everything on the chrome's default gap —
    /// strip insets, inter-tab gap, the close button's clearance inside a tab
    /// — reads it from here, so two gaps that are equal in DIP cannot round
    /// apart at fractional DPI (design system §1).
    pad_sm: i32,
    /// The narrowest a tab's SLOT may be. Also the floor the proportional cap
    /// can never dip below, so a strip too narrow for 50%-of-the-run to hold a
    /// tab still shows one.
    ///
    /// There is deliberately no `max_tab_w` beside it any more (T235). A fixed
    /// DIP maximum is a truncation rule wearing a layout rule's clothes: it
    /// ellipsized `. Fix background p...` while most of the strip sat empty.
    /// The maximum is now `capWidth` — a proportion of the run.
    min_tab_w: i32,
    /// Top-corner radius of the selected/hovered chiclet (bottom corners stay
    /// square — the tab merges into the pane below it).
    corner_r: i32,
    /// Inset before the first tab.
    strip_pad_l: i32,
    /// Inset after the menu button. Its own metric rather than folded into
    /// the `client_w` arithmetic for two reasons: the user caught the strip
    /// being asymmetric without it ("the hamburger button has no gap between
    /// it and the border"), and once the strip shares a row with the caption
    /// buttons (T205) this becomes the gap to the caption group rather than
    /// to the window edge.
    strip_pad_r: i32,
    /// Separation last-tab → "+", and "+" → menu button. Measured between
    /// PAINTED edges (design system §0 rule 2). It used to be applied to the
    /// button's HIT box, which carried 5 DIP of invisible slack per side, so
    /// an 8 DIP constant painted as a 13 DIP gap at 100% and 16 px at the
    /// user's 125% — against 1 px of clearance below the same button. That
    /// 16:1 ratio is what T232 exists to remove.
    group_gap: i32,
    /// The PAINTED square of the "+" and "≡" buttons (T190 kept them equal).
    /// The shared chrome square, from `icon_button.Metrics.target` — this is
    /// what the eye sees and therefore what every gap is measured against.
    btn_paint: i32,
    /// How far each button's HIT box grows past its painted square on every
    /// side. A forgiving click target costs nothing; it just must never be
    /// mistaken for the button.
    btn_pad: i32,
    /// Width of the "+"/"≡" HIT box: the painted square plus `btn_pad` a
    /// side. Kept as its own field because every hit test and every call site
    /// already speaks in these boxes.
    btn_w: i32,
    /// Close-button hit box inside a tab. Same square, same padding, so the
    /// three strip buttons cannot land at three sizes (T204).
    close_btn_w: i32,
    /// Gap between two adjacent tabs (T206 — "tabs should have gaps in
    /// between"). Tabs used to tile edge to edge with a 1px rule between
    /// them, which is why they read as one continuous bar of text rather than
    /// as separate surfaces. The gap replaces that rule.
    tab_gap: i32,
    /// Leading padding before the title.
    text_pad: i32,
    /// T72 user tab-color tag thickness.
    stripe_h: i32,
    /// A 1 DIP rule (the inter-tab separator), never thinner than a pixel.
    hairline: i32,
    //
    // NOTE: the hover fill's corner radius and inset used to live here as
    // `btn_corner_r`/`btn_inset_x`/`btn_inset_y`. They moved to
    // `icon_button.Metrics` (T204) because the banner's chevron needs the
    // same numbers and cannot reasonably import the tab strip's metrics to
    // get them. Ask `icon_button.fillRegion` for the shape instead.

    pub fn init(scale: f32) Metrics {
        // The button geometry is NOT re-derived here. The strip's gaps are
        // measured against the shared chrome square, so the square has to be
        // the same object the painter uses, not a number that happens to
        // agree with it today.
        const ib = icon_button.Metrics.init(scale);
        const sm = px(4.0, scale);
        return .{
            // 4 (top pad) + 4 (clear) + 28 (square) + 4 (clear) = 40 DIP.
            .bar_h = sm + sm + ib.target + sm,
            .tab_top_pad = sm,
            .pad_sm = sm,
            .min_tab_w = px(60.0, scale),
            .corner_r = px(6.0, scale),
            .strip_pad_l = sm,
            .strip_pad_r = sm,
            .group_gap = px(8.0, scale),
            .btn_paint = ib.target,
            .btn_pad = ib.hit_pad,
            .btn_w = ib.target + 2 * ib.hit_pad,
            .close_btn_w = ib.target + 2 * ib.hit_pad,
            .tab_gap = sm,
            .text_pad = px(8.0, scale),
            .stripe_h = @max(px(3.0, scale), 2),
            .hairline = @max(px(1.0, scale), 1),
        };
    }

    fn px(dip: f32, scale: f32) i32 {
        return @intFromFloat(@round(dip * scale));
    }

    /// The close button's box inside a tab, shared by the painter and both
    /// hit tests. It used to be recomputed in three places from two loose
    /// constants, which is how a geometry change could silently move the
    /// glyph away from the thing you click.
    ///
    /// Positioned by its PAINTED square, which keeps `pad_sm` clear of the
    /// tab's right edge; the returned HIT box is that square grown by
    /// `btn_pad` horizontally and the tab's full height vertically. Before
    /// T232 the box was placed directly and the paint fell where it fell —
    /// which is why the "×" cleared the tab's top edge by 1-2 px ("the x
    /// button's gap on the top touches the edge of the tab!").
    pub fn closeRect(self: Metrics, tab: Rect) Rect {
        const paint_right = tab.right - self.pad_sm;
        return .{
            .left = paint_right - self.btn_paint - self.btn_pad,
            .top = tab.top,
            .right = paint_right + self.btn_pad,
            .bottom = tab.bottom,
        };
    }

    /// The title's box inside a tab: after the leading padding, stopping
    /// `pad_sm` before the close button's PAINTED left edge — not before its
    /// hit box, which would push the ellipsis in by an invisible amount.
    pub fn titleRect(self: Metrics, tab: Rect) Rect {
        const close_paint_left = tab.right - self.pad_sm - self.btn_paint;
        return .{
            .left = tab.left + self.text_pad,
            .top = tab.top,
            .right = close_paint_left - self.pad_sm,
            .bottom = tab.bottom,
        };
    }

    /// The PAINTED width a tab needs so a `text_w`-pixel title fits with no
    /// ellipsis: the leading pad, the title, then the close button's painted
    /// square with `pad_sm` either side.
    ///
    /// This is the exact inverse of `titleRect` and must stay that way — if
    /// the two ever disagree, a tab sized to its own stated preference would
    /// still ellipsize, which is the entire bug T235 exists to remove. The
    /// unit test "preferredWidth is the exact inverse of titleRect" pins it.
    pub fn preferredWidth(self: Metrics, text_w: i32) i32 {
        return self.text_pad + @max(text_w, 0) + self.pad_sm + self.btn_paint + self.pad_sm;
    }

    /// The HIT box for a strip button whose painted square starts at
    /// `paint_left`: the square grown by `btn_pad` horizontally, and the tabs'
    /// full vertical band. `icon_button.targetBox` recovers exactly the
    /// painted square from it, so the layout can place paint and the painter
    /// can consume boxes without either knowing the other's convention.
    pub fn buttonHit(self: Metrics, paint_left: i32) Rect {
        return .{
            .left = paint_left - self.btn_pad,
            .top = self.tab_top_pad,
            .right = paint_left + self.btn_paint + self.btn_pad,
            .bottom = self.bar_h,
        };
    }
};

/// Upper bound on tabs a strip can lay out, matching `Window.MAX_TABS`. The
/// caller supplies the output buffer, so this is only a sanity clamp.
pub const MAX_TABS: usize = 64;

/// The resolved strip. `tabs[0..visible]` are the tabs that got a rect; any
/// tab index >= `visible` is deliberately not laid out (see the module doc)
/// and its rect must be zeroed by the caller so hit tests miss it.
pub const Strip = struct {
    /// How many tabs fit. Never greater than the requested count.
    visible: usize = 0,
    /// The uniform tab SLOT width used when the strip is UNDER PRESSURE — the
    /// preferred widths did not all fit, so every tab took the same equal
    /// share instead. **0 when each tab took its own preferred width** (and
    /// when nothing fit at all): there is no single width to report then, and
    /// a caller that wants tab `i`'s width reads `out[i]`.
    tab_w: i32 = 0,
    /// Right edge of the last laid-out tab (== `strip_pad_l` when none fit).
    tabs_right: i32 = 0,
    new_tab: Rect = .{},
    menu: Rect = .{},
};

/// The furthest right the "+"'s PAINTED square may start.
///
/// With a menu button the "+" stops one `group_gap` short of it; without one
/// the "+" IS the right-anchored control and takes the menu's slot, which is
/// why this is the single place the difference is expressed. `runWidth` and
/// `layout` both read it, so a menu-less strip cannot end up with a run that
/// disagrees with where the "+" actually lands.
fn plusPaintLimit(m: Metrics, client_w: i32, has_menu: bool) i32 {
    const band_right = client_w - m.strip_pad_r;
    return if (has_menu)
        band_right - m.btn_paint - m.group_gap - m.btn_paint
    else
        band_right - m.btn_paint;
}

/// The width the tab run may occupy on a `client_w`-wide strip: everything
/// left after the two insets and the "+"/"≡" band. Named because the
/// proportional cap is a fraction OF THIS, so `layout`, the tests and the
/// acceptance script all have to mean the same run.
///
/// `has_menu` is T260: on a window that draws its own caption the "…" button
/// up there IS the menu host, so the strip's "≡" is a second control opening
/// the same menu and does not paint. The run then reclaims exactly one painted
/// square plus one group gap — wider tabs, which is T235's direction.
pub fn runWidth(m: Metrics, client_w: i32, has_menu: bool) i32 {
    return plusPaintLimit(m, client_w, has_menu) - m.group_gap - m.strip_pad_l;
}

/// The most any ONE tab's slot may take: 50% of the run it sits in (design
/// system §6b rule 2) — a proportion of the container, never a DIP constant.
/// Wide window, long title: the tab grows. Narrow window: the same tab yields.
///
/// Floored at `min_tab_w` so a run too narrow for half of it to hold a tab
/// still shows one rather than none.
pub fn capWidth(m: Metrics, tabs_avail: i32) i32 {
    return @max(@divTrunc(tabs_avail, 2), m.min_tab_w);
}

/// One tab's preferred SLOT: its preferred PAINTED width plus the inter-tab
/// gap it gives up (T206), floored and capped. Exposed so the caller and the
/// tests can reason about a single tab without replaying `layout`.
pub fn slotWidth(m: Metrics, tabs_avail: i32, preferred_paint: i32) i32 {
    return std.math.clamp(preferred_paint + m.tab_gap, m.min_tab_w, capWidth(m, tabs_avail));
}

/// Resolve the strip for `client_w` pixels of client width and one entry per
/// tab in `prefer` — each the PAINTED width that tab's title wants, from
/// `Metrics.preferredWidth` (the caller measures the text; this module never
/// does). Tab rects go into `out`, which must hold at least `prefer.len`
/// entries; entries past `visible` are zeroed.
///
/// `has_menu` false (T260) drops the "≡": `Strip.menu` comes back a ZERO rect
/// rather than an off-screen or negative one, so every existing hit test —
/// each of which is a half-open `x >= left and x < right` — misses it by
/// construction instead of by remembering to ask.
pub fn layout(m: Metrics, client_w: i32, has_menu: bool, prefer: []const i32, out: []Rect) Strip {
    std.debug.assert(out.len >= prefer.len);
    const tab_count = @min(prefer.len, MAX_TABS);
    for (out[0..prefer.len]) |*r| r.* = .{};

    // EVERY number below is a PAINTED edge. The hit boxes are derived from
    // them at the end, never the other way round — that inversion is the
    // whole of the "+ has a huge left gap" bug (design system §0 rule 2).
    //
    // The menu button is pinned to the right END OF THE STRIP — its painted
    // square inset by `strip_pad_r`, matching the inset the first tab gets on
    // the left. The "+" may travel, but never past `group_gap` short of it.
    const menu_paint_left = client_w - m.strip_pad_r - m.btn_paint;
    const plus_paint_limit = plusPaintLimit(m, client_w, has_menu);

    // The buttons live in the SAME vertical band as the tabs
    // (`tab_top_pad`..`bar_h`), not in the full bar. T204: the close "×" is
    // centered inside a tab, so unless the "+" and "≡" share the tab's band
    // their shared square lands one pixel higher and the three controls miss
    // each other by exactly the amount the user could see. Their clearance
    // from the strip's TOP edge is therefore `tab_top_pad + pad_sm` rather
    // than `pad_sm` — a deliberate asymmetry (design system §0 rule 3), and
    // the price of the three buttons agreeing with each other.
    var s: Strip = .{
        .tabs_right = m.strip_pad_l,
        .menu = if (has_menu) m.buttonHit(menu_paint_left) else .{},
        .new_tab = m.buttonHit(plus_paint_limit),
    };

    // Width the tabs may occupy: up to `group_gap` short of the "+"'s limit.
    const tabs_avail = runWidth(m, client_w, has_menu);
    if (tab_count == 0 or tabs_avail < m.min_tab_w) return s;

    // SIZE TO CONTENT FIRST (T235, design system §6b). Every tab asks for what
    // its own title needs, floored at `min_tab_w` and capped at half the run.
    // Nothing is ever stretched to fill: if they all fit, the leftover strip
    // stays empty, which is the T202 rule this replacement had to preserve.
    var want: [MAX_TABS]i32 = undefined;
    var wanted_total: i32 = 0;
    for (prefer[0..tab_count], want[0..tab_count]) |p, *slot| {
        slot.* = slotWidth(m, tabs_avail, p);
        wanted_total += slot.*;
    }

    // ONLY SHRINK UNDER PRESSURE. When the preferred widths do not all fit,
    // fall back to T202's equal share clamped to [min, cap] — and only then
    // does `DT_END_ELLIPSIS` get to truncate anything. `uniform == 0` is the
    // sentinel for "no pressure, everyone got what they asked for".
    const count_i: i32 = @intCast(tab_count);
    const uniform: i32 = if (wanted_total <= tabs_avail) 0 else blk: {
        var w = @divTrunc(tabs_avail, count_i);
        w = @max(w, m.min_tab_w);
        w = @min(w, capWidth(m, tabs_avail));
        break :blk w;
    };

    // At `min_tab_w` some tabs may still not fit. Those get no rect rather
    // than a rect under the button band. Content-sized tabs fit by
    // construction — that is what `wanted_total <= tabs_avail` means.
    const visible = if (uniform == 0)
        tab_count
    else
        @min(tab_count, @as(usize, @intCast(@divTrunc(tabs_avail, uniform))));

    var x = m.strip_pad_l;
    for (out[0..visible], 0..) |*r, i| {
        // The neuter restores the exact rule T202 removed: the last tab takes
        // everything that is left, which is what stretched a single tab
        // across the whole window.
        const this_w = if (T202_NEUTERED and i + 1 == visible)
            @max(m.strip_pad_l + tabs_avail - x, m.min_tab_w)
        else if (uniform == 0)
            want[i]
        else
            uniform;
        // The slot is `this_w`; the tab itself gives up `tab_gap` of it, so
        // the gap comes out of the tab rather than being added between them
        // (which would make N tabs wider than the space they were fitted to).
        const drawn_w = @max(this_w - m.tab_gap, 1);
        r.* = .{ .left = x, .top = m.tab_top_pad, .right = x + drawn_w, .bottom = m.bar_h };
        x += this_w;
    }

    s.visible = visible;
    s.tab_w = uniform;
    // The last tab's own right EDGE, not the end of its slot: the slot ends
    // one `tab_gap` further right, and measuring the "+" gap from there would
    // silently widen it by the gap.
    s.tabs_right = out[visible - 1].right;
    s.new_tab = m.buttonHit(@min(s.tabs_right + m.group_gap, plus_paint_limit));
    return s;
}

/// The chiclet's clip shape, expressed as the rect to hand
/// `CreateRoundRectRgn`. The bottom is pushed past the strip so only the TOP
/// corners round — the tab merges into the pane below it, which is how a
/// WinUI TabView marks selection (and why it needs no underline).
/// Shared with `icon_button.zig` so the chiclet and the button fills are
/// handed to `CreateRoundRectRgn` through one type with one off-by-one rule.
/// For the chiclet the `bottom` is pushed past `bar_h`, so only the TOP
/// corners round and the rest is clipped away by the strip's own bitmap.
pub const RoundRegion = icon_button.RoundRegion;

pub fn chicletRegion(m: Metrics, tab: Rect) RoundRegion {
    return .{
        .left = tab.left,
        .top = tab.top,
        .right = tab.right + 1,
        .bottom = m.bar_h + m.corner_r + 1,
        .ellipse = m.corner_r * 2,
    };
}

/// The rounded fill lit under ANY of the strip's icon buttons — the "+", the
/// "≡", and (since T204) the close "×".
///
/// This used to inset the button's own hit box, which made the fill as wide
/// as the box: a 36x24 slab under the "+" that read as a second tab. It now
/// defers to the shared square in `icon_button.zig`, so all three strip
/// buttons and the banner's chevron light the same shape.
pub fn buttonFillRegion(ib: icon_button.Metrics, btn: Rect) RoundRegion {
    return icon_button.fillRegion(ib, btn);
}

/// The 1px separator drawn between two adjacent tabs when neither is selected
/// or hovered (Windows Terminal draws one; it is what keeps transparent tabs
/// from reading as one run of text). Vertically inset to the middle ~50%.
pub fn separatorRect(m: Metrics, tab: Rect) Rect {
    const h = tab.bottom - tab.top;
    const inset = @divTrunc(h, 4);
    return .{
        .left = tab.right - m.hairline,
        .top = tab.top + inset,
        .right = tab.right,
        .bottom = tab.bottom - inset,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const WIDE: i32 = 1600;

/// A middling title, in DIP of TEXT — wide enough that a few tabs of it are a
/// real content-sized run, narrow enough that a wide strip fits several.
const TITLE_DIP: f32 = 120.0;

/// Lay out `n` tabs that all want the same title width. Most assertions below
/// are about geometry rather than about text, and a uniform preference is what
/// lets them keep saying what they said before T235 turned the width into an
/// input.
fn layoutN(scale: f32, client_w: i32, n: usize, buf: []Rect) struct { Metrics, Strip } {
    return layoutTitles(scale, client_w, n, TITLE_DIP, buf);
}

fn layoutTitles(scale: f32, client_w: i32, n: usize, text_dip: f32, buf: []Rect) struct { Metrics, Strip } {
    return layoutMenu(scale, client_w, n, text_dip, true, buf);
}

/// The same, with the T260 switch exposed: `has_menu` false is the strip on a
/// window whose caption already hosts the menu. Every pre-T260 test keeps
/// asking for the menu, so the geometry they pin is unchanged by construction.
fn layoutMenu(scale: f32, client_w: i32, n: usize, text_dip: f32, has_menu: bool, buf: []Rect) struct { Metrics, Strip } {
    const m = Metrics.init(scale);
    var prefer: [MAX_TABS]i32 = undefined;
    const p = m.preferredWidth(@intFromFloat(@round(text_dip * scale)));
    for (prefer[0..n]) |*e| e.* = p;
    return .{ m, layout(m, client_w, has_menu, prefer[0..n], buf) };
}

/// The slot one `TITLE_DIP` tab takes, i.e. the strip's pitch in these tests.
fn slotOf(m: Metrics, scale: f32) i32 {
    return m.preferredWidth(@intFromFloat(@round(TITLE_DIP * scale))) + m.tab_gap;
}

/// What a button's hit box actually PAINTS. Every gap assertion below is
/// written against this and never against the hit box — the tests have to
/// measure the strip the way the user's eye does, or they would have passed
/// against the 16:1 gap ratio that produced T232 (they did).
fn painted(scale: f32, hit: Rect) Rect {
    return icon_button.targetBox(icon_button.Metrics.init(scale), hit);
}

test "one tab is its title's width, not stretched across the window" {
    // THE bug this module exists for. `Window.zig` used to hand the last tab
    // `available - x`, so with one tab it took the entire strip. Since T235
    // the width it DOES take is its content's, not a constant.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 1, &buf);
        try testing.expectEqual(@as(usize, 1), s.visible);
        // The SLOT is the preferred width; the drawn tab gives up `tab_gap`
        // of it (T206), so every tab is followed by the same gap — including
        // the last one, before the "+".
        try testing.expectEqual(slotOf(m, scale) - m.tab_gap, buf[0].width());
        // Nothing was stretched to fill: no pressure, so no uniform width.
        try testing.expectEqual(@as(i32, 0), s.tab_w);
        // ... and there is real dead strip space left over.
        try testing.expect(s.tabs_right < @divTrunc(WIDE, 2));
    }
}

test "T235: preferredWidth is the exact inverse of titleRect" {
    // The invariant the whole feature rests on. A tab sized to `preferredWidth
    // (text_w)` must offer the title EXACTLY `text_w` — one pixel short and
    // `DT_END_ELLIPSIS` truncates the very title we just sized the tab to fit,
    // which is the T235 defect reappearing through the back door.
    for ([_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        for ([_]i32{ 0, 1, 37, 120, 512, 3000 }) |text_w| {
            const tab: Rect = .{
                .left = 100,
                .top = m.tab_top_pad,
                .right = 100 + m.preferredWidth(text_w),
                .bottom = m.bar_h,
            };
            try testing.expectEqual(@max(text_w, 0), m.titleRect(tab).width());
        }
    }
}

test "T235: a tab grows with its title, and is capped at half the run" {
    // The user's report, as arithmetic: ". Fix background p..." was truncated
    // at a 200 DIP constant while most of a wide strip sat empty.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);

        // Longer title => wider tab, monotonically, until the cap.
        var prev: i32 = 0;
        for ([_]f32{ 40, 80, 160, 240 }) |dip| {
            _, const s = layoutTitles(scale, WIDE, 1, dip, &buf);
            try testing.expectEqual(@as(usize, 1), s.visible);
            try testing.expect(buf[0].width() > prev);
            prev = buf[0].width();
        }
        // Past the old fixed 200 DIP cap, which is the point of the task.
        try testing.expect(prev > Metrics.px(200.0, scale));

        // A title long enough to swallow the window is capped at 50% of the
        // run — a proportion, not a constant — and still leaves the strip's
        // other half alone.
        _, const huge = layoutTitles(scale, WIDE, 1, 5000, &buf);
        const avail = runWidth(m, WIDE, true);
        try testing.expectEqual(capWidth(m, avail) - m.tab_gap, buf[0].width());
        try testing.expect(buf[0].width() <= @divTrunc(avail, 2));
        try testing.expect(huge.tabs_right < @divTrunc(WIDE, 2) + m.strip_pad_l);

        // Narrow window, SAME title: the cap yields with the container. This
        // is what "proportional" buys over a DIP constant.
        _ = layoutTitles(scale, @divTrunc(WIDE, 3), 1, 5000, &buf);
        try testing.expect(buf[0].width() < capWidth(m, avail) - m.tab_gap);
    }
}

test "T235: preferred widths that do not fit fall back to an equal share" {
    // Rule 3: shrink only under pressure, and when it happens every tab is the
    // same width again (T202's rule, kept for exactly this case).
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const slot = slotOf(m, scale);
        const avail = runWidth(m, WIDE, true);
        const fits: usize = @intCast(@divTrunc(avail, slot));

        // One fewer than fits: no pressure, everyone gets their preference.
        {
            _, const s = layoutN(scale, WIDE, fits - 1, &buf);
            try testing.expectEqual(fits - 1, s.visible);
            try testing.expectEqual(@as(i32, 0), s.tab_w);
            for (buf[0..s.visible]) |r| try testing.expectEqual(slot - m.tab_gap, r.width());
        }
        // Two more than fits: pressure. Uniform, narrower than preferred, and
        // never below the floor.
        {
            _, const s = layoutN(scale, WIDE, fits + 2, &buf);
            try testing.expect(s.tab_w > 0);
            try testing.expect(s.tab_w < slot);
            try testing.expect(s.tab_w >= m.min_tab_w);
            for (buf[1..s.visible], 0..) |r, i| try testing.expectEqual(buf[i].width(), r.width());
        }
    }
}

test "T235: mixed titles each get their own width" {
    // The content path is per-tab, not a single width applied to everyone —
    // otherwise "size to content" would just be "size to the widest".
    var buf: [MAX_TABS]Rect = undefined;
    const m = Metrics.init(1.0);
    const prefer = [_]i32{
        m.preferredWidth(40),
        m.preferredWidth(300),
        m.preferredWidth(120),
    };
    const s = layout(m, WIDE, true, &prefer, &buf);
    try testing.expectEqual(@as(usize, 3), s.visible);
    for (prefer, buf[0..3]) |p, r| try testing.expectEqual(p, r.width());
    // Laid out end to end with one gap between, in order.
    for (buf[1..3], 0..) |r, i| try testing.expectEqual(buf[i].right + m.tab_gap, r.left);
}

test "the tab area never reaches the button band" {
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        for ([_]usize{ 1, 2, 3, 8, 20, 40, 64 }) |n| {
            const m, const s = layoutN(scale, WIDE, n, &buf);
            if (s.visible == 0) continue;
            const plus = painted(scale, s.new_tab);
            const menu = painted(scale, s.menu);
            try testing.expect(s.tabs_right + m.group_gap <= plus.left);
            try testing.expect(plus.right + m.group_gap <= menu.left);
            // The strip is inset by the SAME amount at both ends. Without a
            // right inset the menu button sat flush on the window border
            // while the first tab was inset by 4 — asymmetric by omission,
            // and the user caught it.
            try testing.expectEqual(m.strip_pad_l, m.strip_pad_r);
            try testing.expectEqual(WIDE, menu.right + m.strip_pad_r);
            // Every laid-out tab is left of the "+" it paints.
            for (buf[0..s.visible]) |r| try testing.expect(r.right <= plus.left);
        }
    }
}

test "T232: every painted gap in the strip is its DIP constant, exactly" {
    // The regression this module now exists to prevent, stated as arithmetic.
    // Measured at the user's 125% before the fix: the "+" square sat 16 px
    // from the tab and 1 px from the strip's bottom edge — a 16:1 ratio
    // between two gaps that should both have been on the 4 DIP scale.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0 }) |scale| {
        for ([_]usize{ 1, 2, 3, 8 }) |n| {
            const m, const s = layoutN(scale, WIDE, n, &buf);
            if (s.visible == 0) continue;
            const plus = painted(scale, s.new_tab);
            const menu = painted(scale, s.menu);
            const close = painted(scale, m.closeRect(buf[0]));

            // Horizontal: tab → "+" → "≡" → window edge. The "+" TRAVELS with
            // the last tab, so its gap to the tab is the constant and its gap
            // to the pinned menu button is whatever strip is left over — the
            // reverse of what the pre-T202 strip did.
            try testing.expectEqual(m.group_gap, plus.left - s.tabs_right);
            try testing.expect(menu.left - plus.right >= m.group_gap);
            try testing.expectEqual(m.strip_pad_r, WIDE - menu.right);
            try testing.expectEqual(m.strip_pad_l, buf[0].left);

            // Vertical: every button square clears the band it sits in by
            // `pad_sm` above AND below. This is the "no bottom gap" half.
            for ([_]Rect{ plus, menu, close }) |sq| {
                try testing.expectEqual(m.pad_sm, sq.top - m.tab_top_pad);
                try testing.expectEqual(m.pad_sm, m.bar_h - sq.bottom);
            }
            // ...and the "×" clears the tab's own right edge by the same
            // amount ("the x button's gap on the top touches the edge").
            try testing.expectEqual(m.pad_sm, buf[0].right - close.right);

            // No gap anywhere in the strip is more than 2x any other. Before
            // T232 the worst pair was 16:1.
            var lo: i32 = m.pad_sm;
            var hi: i32 = m.pad_sm;
            for ([_]i32{ m.group_gap, m.strip_pad_l, m.tab_gap, plus.top - m.tab_top_pad }) |g| {
                lo = @min(lo, g);
                hi = @max(hi, g);
            }
            try testing.expect(hi <= 2 * lo);
        }
    }
}

test "T232: hit boxes may overlap the gaps, but never each other" {
    // The other half of rule 2: a forgiving click target is free precisely
    // BECAUSE it is invisible — so it is allowed to reach into a gap, and it
    // is never allowed to steal a neighbour's clicks.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 3, &buf);
        try testing.expect(s.new_tab.right <= s.menu.left);
        try testing.expect(buf[s.visible - 1].right <= s.new_tab.left);
        try testing.expect(s.menu.right <= WIDE);
        // The close button's hit box stays inside its tab.
        for (buf[0..s.visible]) |tab| {
            const close = m.closeRect(tab);
            try testing.expect(close.right <= tab.right);
            try testing.expect(close.left > tab.left);
        }
        // Hit boxes really are more forgiving than the paint, or none of the
        // above would be saying anything.
        try testing.expect(s.new_tab.width() > painted(scale, s.new_tab).width());
    }
}

test "the + follows the last tab and stops at its limit" {
    var buf: [MAX_TABS]Rect = undefined;
    const m = Metrics.init(1.0);
    const slot = slotOf(m, 1.0);

    _, const one = layoutN(1.0, WIDE, 1, &buf);
    _, const two = layoutN(1.0, WIDE, 2, &buf);
    _, const three = layoutN(1.0, WIDE, 3, &buf);
    // Adding a tab moves the "+" right by exactly one tab slot...
    try testing.expectEqual(one.new_tab.left + slot, two.new_tab.left);
    try testing.expectEqual(two.new_tab.left + slot, three.new_tab.left);
    // ... and it is a real gap, not zero (the "clipped" look) — measured
    // between painted edges, which is the only measurement the user can see.
    try testing.expectEqual(m.group_gap, painted(1.0, one.new_tab).left - one.tabs_right);

    // Once the tabs fill the strip the "+" stops at its limit and stays put.
    _, const many = layoutN(1.0, WIDE, 40, &buf);
    _, const more = layoutN(1.0, WIDE, 64, &buf);
    try testing.expectEqual(many.new_tab.left, more.new_tab.left);
    try testing.expect(painted(1.0, many.new_tab).right + m.group_gap <= painted(1.0, many.menu).left);
}

test "T260: dropping the menu hands the run exactly one square and one gap" {
    // The user-visible claim: on a window whose caption hosts the menu, the
    // strip's "≡" is gone and the tabs get that space — not "about that much".
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const with = runWidth(m, WIDE, true);
        const without = runWidth(m, WIDE, false);
        try testing.expectEqual(m.btn_paint + m.group_gap, without - with);

        // The "+" is still `group_gap` clear of the run in BOTH cases — the
        // gap is the invariant, the button count is what changed. Measured
        // between painted edges, because that is the gap the eye sees.
        for ([_]bool{ true, false }) |has_menu| {
            _, const s = layoutMenu(scale, WIDE, 1, TITLE_DIP, has_menu, &buf);
            try testing.expectEqual(m.group_gap, painted(scale, s.new_tab).left - s.tabs_right);
        }

        // And with no menu the "+" becomes the right-anchored control, taking
        // the square the "≡" used to hold — same inset from the window edge,
        // so the strip does not become lopsided when the button disappears.
        // Read off a strip with NO tabs, where the "+" sits at its limit
        // instead of travelling with a last tab.
        _, const bare = layoutMenu(scale, WIDE, 0, TITLE_DIP, false, &buf);
        try testing.expectEqual(WIDE - m.strip_pad_r, painted(scale, bare.new_tab).right);
        _, const bare_menu = layoutMenu(scale, WIDE, 0, TITLE_DIP, true, &buf);
        try testing.expectEqual(WIDE - m.strip_pad_r, painted(scale, bare_menu.menu).right);
        // A strip stuffed past its capacity still never pushes the "+" past
        // that limit — the freed square is the tabs', not an overrun.
        _, const full = layoutMenu(scale, WIDE, 40, TITLE_DIP, false, &buf);
        try testing.expect(painted(scale, full.new_tab).right <= WIDE - m.strip_pad_r);
        try testing.expect(full.tabs_right + m.group_gap <= painted(scale, full.new_tab).left);
    }
}

test "T260: a menu-less strip reports a ZERO menu rect, which every hit test misses" {
    // The hit tests are half-open `x >= left and x < right`, so a zero rect is
    // unhittable at every x — including x = 0, the one a "just move it
    // off-screen" answer gets wrong. This is why the rect is zeroed rather
    // than parked somewhere harmless-looking.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        for ([_]usize{ 0, 1, 8, 40 }) |n| {
            _, const s = layoutMenu(scale, WIDE, n, TITLE_DIP, false, &buf);
            try testing.expect(s.menu.isEmpty());
            for ([_]i32{ 0, 1, WIDE - 1, WIDE }) |x| {
                try testing.expect(!(x >= s.menu.left and x < s.menu.right));
            }
        }
    }
    // A degenerate strip is where an "empty means zero-width" bug would hide:
    // no tabs fit, so the buttons are all there is to get wrong.
    const m = Metrics.init(1.0);
    _, const narrow = layoutMenu(1.0, 60, 3, TITLE_DIP, false, &buf);
    try testing.expect(narrow.menu.isEmpty());
    try testing.expectEqual(@as(i32, 60) - m.strip_pad_r, painted(1.0, narrow.new_tab).right);
}

test "T260: tabs actually get wider on a menu-less strip" {
    // The point of the change, not just its arithmetic: at the width where the
    // run's 50% cap is what limits a tab, dropping the menu raises the cap.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        _, const with = layoutMenu(scale, WIDE, 1, 5000, true, &buf);
        const w_capped = buf[0].width();
        _, const without = layoutMenu(scale, WIDE, 1, 5000, false, &buf);
        const wo_capped = buf[0].width();
        try testing.expect(wo_capped > w_capped);
        try testing.expectEqual(capWidth(m, runWidth(m, WIDE, false)) - m.tab_gap, wo_capped);
        // Both still leave the "+" its landing spot rather than running under it.
        try testing.expect(with.tabs_right + m.group_gap <= painted(scale, with.new_tab).left);
        try testing.expect(without.tabs_right + m.group_gap <= painted(scale, without.new_tab).left);
    }
}

test "tabs shrink with count, then overflow instead of running off the end" {
    var buf: [MAX_TABS]Rect = undefined;
    const m = Metrics.init(1.0);
    const slot = slotOf(m, 1.0);

    // Two tabs of a middling title fit with room to spare, so neither shrinks
    // and there is no uniform width to report.
    try testing.expectEqual(@as(i32, 0), layoutN(1.0, WIDE, 2, &buf)[1].tab_w);
    // Enough tabs to force a shrink below what they asked for — which since
    // T235 is a count derived from the run and the title, not from a constant.
    const fits: usize = @intCast(@divTrunc(runWidth(m, WIDE, true), slot));
    _, const squeezed = layoutN(1.0, WIDE, fits + 3, &buf);
    try testing.expect(squeezed.tab_w < slot);
    try testing.expect(squeezed.tab_w > m.min_tab_w);
    try testing.expectEqual(fits + 3, squeezed.visible);
    // ... and enough to hit the floor, after which tabs are dropped, not
    // painted under the buttons.
    _, const flood = layoutN(1.0, WIDE, 64, &buf);
    try testing.expectEqual(m.min_tab_w, flood.tab_w);
    try testing.expect(flood.visible < 64);
    try testing.expect(flood.visible > 0);
    // Dropped tabs have a zero rect, so a hit test can never find them.
    for (buf[flood.visible..64]) |r| try testing.expect(r.isEmpty());
}

test "tabs are separated by exactly one gap, and are all the same width" {
    // T206 replaced edge-to-edge tiling with a real gap ("tabs should have
    // gaps in between"): what used to be `buf[i].right == r.left` is now
    // `+ tab_gap`. Equal widths still hold — a gap that came out of only some
    // tabs would make them different sizes.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 6, &buf);
        try testing.expectEqual(m.strip_pad_l, buf[0].left);
        try testing.expect(m.tab_gap > 0);
        for (buf[1..s.visible], 0..) |r, i| {
            try testing.expectEqual(buf[i].right + m.tab_gap, r.left);
            try testing.expectEqual(buf[i].width(), r.width());
        }
        // Tabs hang below the strip top by the pad, and reach the bottom so
        // the selected one merges into the pane.
        for (buf[0..s.visible]) |r| {
            try testing.expectEqual(m.tab_top_pad, r.top);
            try testing.expectEqual(m.bar_h, r.bottom);
        }
    }
}

test "a window too narrow for a tab still lays out its buttons" {
    // A degenerate strip must not produce negative widths or a tab drawn on
    // top of the menu button; the buttons matter more than the tabs there.
    var buf: [MAX_TABS]Rect = undefined;
    const m = Metrics.init(1.0);
    for ([_]i32{ 0, 10, 60, 100, 130 }) |w| {
        _, const s = layoutN(1.0, w, 3, &buf);
        try testing.expectEqual(@as(usize, 0), s.visible);
        try testing.expectEqual(w - m.strip_pad_r, painted(1.0, s.menu).right);
        for (buf[0..3]) |r| try testing.expect(r.isEmpty());
    }
    // Just wide enough for one minimum tab, and it appears — at the floor,
    // because three tabs that each want more than the whole run is pressure.
    _, const ok = layoutN(1.0, m.strip_pad_l + m.strip_pad_r + m.min_tab_w + m.group_gap * 2 + m.btn_paint * 2, 3, &buf);
    try testing.expectEqual(@as(usize, 1), ok.visible);
    try testing.expectEqual(m.min_tab_w, ok.tab_w);
}

test "close and title boxes stay inside their tab, close after title" {
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 3, &buf);
        for (buf[0..s.visible]) |tab| {
            const close = m.closeRect(tab);
            const title = m.titleRect(tab);
            try testing.expect(close.left > tab.left);
            try testing.expect(close.right <= tab.right);
            try testing.expect(close.top >= tab.top);
            try testing.expect(close.bottom <= tab.bottom);
            try testing.expect(title.left > tab.left);
            try testing.expect(title.right <= close.left);
        }
    }
}

test "the chiclet rounds only its top corners" {
    var buf: [MAX_TABS]Rect = undefined;
    const m, const s = layoutN(1.0, WIDE, 2, &buf);
    _ = s;
    const rr = chicletRegion(m, buf[0]);
    try testing.expectEqual(buf[0].left, rr.left);
    try testing.expectEqual(buf[0].top, rr.top);
    try testing.expectEqual(buf[0].right + 1, rr.right);
    // The rounded bottom is pushed past the strip, so the strip's own bitmap
    // clips it and the tab meets the pane with square corners.
    try testing.expect(rr.bottom > m.bar_h);
    try testing.expectEqual(m.corner_r * 2, rr.ellipse);
}

test "a button's hover fill is inset inside its hit box, on every button" {
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 2, &buf);
        const ib = icon_button.Metrics.init(scale);
        // T204: the close "×" is in this list now. It used to be the one
        // strip control with no fill at all.
        for ([_]Rect{ s.new_tab, s.menu, m.closeRect(buf[0]) }) |btn| {
            const f = buttonFillRegion(ib, btn);
            try testing.expect(f.left >= btn.left);
            try testing.expect(f.right - 1 <= btn.right);
            try testing.expect(f.top >= btn.top);
            try testing.expect(f.bottom - 1 <= btn.bottom);
            try testing.expect(f.ellipse > 0);
        }
    }
}

test "T204: all three strip buttons paint one square on one vertical frame" {
    // The user's complaint as an assertion. Whatever their hit boxes are, the
    // three controls must paint identical squares at identical heights — that
    // is what "consistent design" means here, and it is checkable.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 3, &buf);
        const ib = icon_button.Metrics.init(scale);
        const plus = icon_button.targetBox(ib, s.new_tab);
        const menu = icon_button.targetBox(ib, s.menu);
        const close = icon_button.targetBox(ib, m.closeRect(buf[0]));

        try testing.expectEqual(plus.top, menu.top);
        try testing.expectEqual(plus.top, close.top);
        try testing.expectEqual(plus.bottom, menu.bottom);
        try testing.expectEqual(plus.bottom, close.bottom);
        try testing.expectEqual(plus.width(), menu.width());
        try testing.expectEqual(plus.width(), close.width());
        try testing.expectEqual(plus.width(), plus.height());
        // And the close box is wide enough that the shared square is not
        // clamped down inside it — the pre-T204 20 DIP box would clamp.
        try testing.expectEqual(ib.target, close.width());
    }
}

test "the buttons share the tabs' vertical band, not the full bar" {
    var buf: [MAX_TABS]Rect = undefined;
    const m, const s = layoutN(1.0, WIDE, 2, &buf);
    try testing.expectEqual(m.tab_top_pad, s.new_tab.top);
    try testing.expectEqual(m.tab_top_pad, s.menu.top);
    try testing.expectEqual(buf[0].top, s.new_tab.top);
    try testing.expectEqual(m.bar_h, s.menu.bottom);
}

test "the separator is a 1px hairline inset inside the tab" {
    var buf: [MAX_TABS]Rect = undefined;
    const m, _ = layoutN(1.0, WIDE, 2, &buf);
    const sep = separatorRect(m, buf[0]);
    try testing.expectEqual(m.hairline, sep.width());
    try testing.expectEqual(buf[0].right, sep.right);
    try testing.expect(sep.top > buf[0].top);
    try testing.expect(sep.bottom < buf[0].bottom);
}
