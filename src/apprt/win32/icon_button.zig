//! Pure geometry and state model for every icon button in the win32 chrome
//! (T204). No OS imports, so these unit tests run in every app-runtime lane
//! (the `split_geometry.zig` / `tab_strip_layout.zig` pattern).
//!
//! Why this module exists. The chrome grew four icon buttons over four
//! separate tasks, and each one open-coded its own treatment:
//!
//!   * "+"  (new tab)  — rounded hover fill, glyph drawn `DT_LEFT`
//!   * "≡"  (menu)     — rounded hover fill, glyph drawn `DT_CENTER`
//!   * "×"  (close)    — NO fill; hover only recolored the glyph red, `DT_LEFT`
//!   * chevron (banner collapse) — no hover, no hit state, no fill at all
//!
//! Four controls, four answers to the same question, so they could not agree
//! and did not. The user's report, 2026-07-30, naming all three symptoms:
//!
//! > "icon buttons should have a consistent design with consistent hover and
//! >  centered icons" ... "why doesn't the chevron in the banner have a
//! >  similar hover? why doesn't the x to close a tab have a similar hover?"
//!
//! And on the "+" specifically — its fill was a tab-height slab while the
//! glyph sat against the slab's left edge, so a hovered "+" read as a second
//! tab rather than a button.
//!
//! So the button model lives here, once: the shared square target, the
//! rounded fill inset inside it, the per-state shade, and the rule that the
//! glyph is centered on BOTH axes of that square. A site that wants an icon
//! button asks this module for its geometry; it does not get to invent one.
//! That is what makes the user's complaint un-reproducible by construction
//! rather than by three sites happening to agree.
//!
//! Measured target: `docs/design/win32-tab-strip.md`.

const std = @import("std");
const testing = std.testing;

/// Negative control for `test/win32/tab-strip.ps1` and
/// `test/win32/pane-banner.ps1` (project standard: an acceptance script has
/// to be SHOWN to fail, or it is not evidence). Flip to `true`, rebuild
/// `-Dapp-runtime=win32`, and re-run those scripts: it restores the pre-T204
/// world where glyphs are leading-aligned and only the "+"/"≡" light a fill,
/// so the centering assertions and the close/chevron hover assertions must
/// fail — and the "+"/"≡" hover assertions must NOT.
///
/// Left in the source rather than behind a build option so the control is one
/// edit away from any future reader, and so the unit tests below pin the
/// shipped (`false`) behavior on every build.
pub const T204_NEUTERED = false;

/// A rectangle in physical pixels, right/bottom exclusive. Mirrors `w32.RECT`
/// field-for-field so Window.zig can copy one into the other; declared here so
/// this module needs no OS import. `tab_strip_layout.zig` re-exports it, so
/// the strip and the banner share one rectangle type rather than two
/// structurally identical ones.
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

    pub fn isEmpty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn contains(self: Rect, x: i32) bool {
        return x >= self.left and x < self.right;
    }

    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }
};

/// A rounded rect expressed as the arguments to `CreateRoundRectRgn`, whose
/// right/bottom are inclusive — so they are already +1'd here and every call
/// site passes them straight through. One place to get that off-by-one right.
pub const RoundRegion = struct {
    left: i32,
    top: i32,
    /// Exclusive, already +1'd for `CreateRoundRectRgn`.
    right: i32,
    /// Exclusive, already +1'd.
    bottom: i32,
    /// The `w`/`h` arguments (diameter, not radius).
    ellipse: i32,
};

/// What the button is doing right now. One enum for every site, so "hovered"
/// cannot mean a red glyph in one place and a lit fill in another.
pub const State = enum {
    normal,
    hover,
    /// Mouse is down on the button.
    pressed,
    /// Latched on — the menu button while its popup is open. Windows keeps a
    /// menu button lit for as long as the menu it owns is showing.
    active,
};

/// Every DIP constant an icon button is built from, resolved to physical
/// pixels for one DPI scale.
///
/// Two rules from `docs/design/win32-design-system.md` are baked in here, and
/// they are why the fields look the way they do (T232):
///
///   1. The PAINTED square is 28 DIP; the HIT box is that square grown by
///      `hit_pad` on every side. A hit box may be more forgiving than the
///      paint — that costs nothing — but it is invisible, so it must never
///      contribute to a gap. Measuring the strip's gaps to the hit box is
///      what made the "+" look 16 px from a tab it was 8 DIP from.
///   2. Every mark extent is forced to the same PARITY as the square's side,
///      so `(side - extent) / 2` is an exact integer and the mark is centered
///      BY CONSTRUCTION rather than by rounding luck. A mark whose parity
///      differs from its container can only land half a pixel off-center, and
///      that half pixel is the "left half of the plus is shorter than the
///      right half" report.
pub const Metrics = struct {
    /// The square every icon button PAINTS. Chrome buttons are square; making
    /// this one number is what stops three controls from landing at three
    /// unrelated sizes.
    target: i32,
    /// How far the hit box grows past the painted square on EACH side, so a
    /// 28 DIP paint yields a >= 32 DIP click target. Symmetric on purpose:
    /// an asymmetric hit box moves the painted square when a site derives one
    /// from the other.
    hit_pad: i32,
    /// Inset of the rounded fill inside that square (`xs`), so two adjacent
    /// lit buttons never touch.
    inset: i32,
    /// Corner radius of the fill. Windows 11 lights a button as a rounded
    /// rect inset in its hit box, not as a full-bleed square — the square is
    /// what made the "+" and "≡" read as one slab.
    corner_r: i32,
    /// Mark thickness, ~2 DIP, parity-matched to `target`.
    stroke_w: i32,
    /// Mark thickness for CLOSED OUTLINE glyphs (maximize, restore) — 1 DIP,
    /// floored at one physical pixel.
    ///
    /// A deliberate amendment to design system §4.2's "stroke thickness is
    /// 2 DIP for every glyph", made when the first build shipped a maximize
    /// box that read as a filled square with a dot in it. That rule was
    /// written for OPEN marks (+, ×, hamburger, chevron), where the eye reads
    /// the stroke. In a closed outline the eye reads the ENCLOSED AREA, and a
    /// 2 DIP stroke on a 10 DIP box leaves 6 DIP of interior — 36% of the
    /// glyph's area — so it reads as filled. Windows' own ChromeMaximize is a
    /// 10x10 box with a 1 px stroke for exactly this reason.
    ///
    /// Same class of rule as §4.2's per-glyph mark widths: equal geometry
    /// does not mean equal apparent weight.
    stroke_outline: i32,
    /// Mark extents, tuned OPTICALLY per glyph rather than shared: equal
    /// geometric width does not read as equal width. A horizontal-only mark
    /// (the hamburger) reads narrower than one with a vertical member (the
    /// plus) at the same extent, and a diagonal cross reads wider than its
    /// bounding box. Design system §4.2.
    mark_add: i32,
    mark_close: i32,
    mark_menu: i32,
    /// Chevron width and total rise.
    mark_chevron_w: i32,
    mark_chevron_h: i32,
    /// Extent of the three CAPTION marks (minimize, maximize, restore), T254.
    /// 10 DIP, one number for all three: they sit side by side in one cluster,
    /// so any optical tuning between them would read as three different sizes
    /// rather than as three different icons. It is under `mark_close` (11)
    /// because two of the three are closed outlines, and a closed outline
    /// reads larger than an open mark of the same extent — the same optical
    /// rule that makes the hamburger need 14 (design system §4.2).
    mark_caption: i32,
    /// How far the restore glyph's two squares are offset from each other.
    /// Floored at `stroke_w + 1` so the back square's edges never merge into
    /// the front square's and turn the icon into a solid blob at 1.0.
    restore_off: i32,
    /// Vertical pitch between the hamburger's three rules. Applied
    /// symmetrically about the middle rule, so it needs no parity match.
    menu_pitch: i32,
    /// The DPI scale these metrics were resolved for, carried so the paint
    /// side can resolve DIP-specified sizes of its own — the icon-FONT glyph
    /// sizes (T497) — without a second `init` that could disagree.
    scale: f32,

    pub fn init(scale: f32) Metrics {
        const side = px(28.0, scale);
        const stroke = markPx(2.0, scale, side);
        return .{
            .target = side,
            .hit_pad = px(2.0, scale),
            .inset = px(2.0, scale),
            .corner_r = px(4.0, scale),
            .stroke_w = stroke,
            .stroke_outline = @max(px(1.0, scale), 1),
            .mark_add = markPx(12.0, scale, side),
            .mark_close = markPx(11.0, scale, side),
            .mark_menu = markPx(14.0, scale, side),
            .mark_chevron_w = markPx(12.0, scale, side),
            .mark_chevron_h = markPx(6.0, scale, side),
            .menu_pitch = px(4.0, scale),
            .mark_caption = markPx(10.0, scale, side),
            .restore_off = @max(px(3.0, scale), stroke + 1),
            .scale = scale,
        };
    }

    fn px(dip: f32, scale: f32) i32 {
        return @intFromFloat(@round(dip * scale));
    }

    /// A mark extent in physical pixels, forced to the same parity as `side`.
    ///
    /// Rounds DOWN on a parity mismatch, never up: rounding up collapses the
    /// optical order (close < add < menu) at half the scales, and a mark one
    /// pixel under its nominal DIP is invisible while a mis-centered one is
    /// exactly what the user reported.
    fn markPx(dip: f32, scale: f32, side: i32) i32 {
        var e = @max(px(dip, scale), 1);
        if (((side - e) & 1) != 0) e = if (e > 1) e - 1 else e + 1;
        return e;
    }
};

/// The HIT box for a painted square: the square grown by `hit_pad` on every
/// side. The inverse of `targetBox`, and exactly so — `targetBox(m,
/// hitBox(m, sq)) == sq` at every scale, which is what lets a layout reason in
/// painted edges while its call sites keep hit-testing the box they always had.
pub fn hitBox(m: Metrics, painted: Rect) Rect {
    return .{
        .left = painted.left - m.hit_pad,
        .top = painted.top - m.hit_pad,
        .right = painted.right + m.hit_pad,
        .bottom = painted.bottom + m.hit_pad,
    };
}

/// The shared square target, centered inside whatever box a site has for the
/// button. Sites keep their own (often wider, more forgiving) HIT box; the
/// paint always happens in this square, which is what puts every glyph and
/// every fill on one frame.
///
/// A box smaller than `target` on either axis clamps rather than overflowing —
/// a cramped strip should shrink its buttons, not paint outside itself.
pub fn targetBox(m: Metrics, box: Rect) Rect {
    const side = @min(m.target, @min(box.width(), box.height()));
    const cx = @divTrunc(box.left + box.right, 2);
    const cy = @divTrunc(box.top + box.bottom, 2);
    const half = @divTrunc(side, 2);
    return .{
        .left = cx - half,
        .top = cy - half,
        .right = cx - half + side,
        .bottom = cy - half + side,
    };
}

/// The rounded fill lit under a button, inset inside its shared target.
pub fn fillRegion(m: Metrics, box: Rect) RoundRegion {
    const t = targetBox(m, box);
    return .{
        .left = t.left + m.inset,
        .top = t.top + m.inset,
        .right = t.right - m.inset + 1,
        .bottom = t.bottom - m.inset + 1,
        .ellipse = m.corner_r * 2,
    };
}

/// Does this state paint a fill at all?
///
/// Under the neuter this answers `false` for everything except the states the
/// pre-T204 "+"/"≡" already lit, which is how the acceptance scripts can show
/// the close button's and the chevron's new hover actually came from here.
pub fn paintsFill(state: State) bool {
    return switch (state) {
        .normal => false,
        .hover, .pressed, .active => true,
    };
}

/// How far to shade the site's own base color for a state, per channel.
///
/// A DELTA rather than a color because the sites have different backgrounds:
/// the strip lights against the tab-bar background, the banner against its
/// card. Signed on `dark` so a light theme darkens on hover instead of
/// washing out — T203 owns the theming pass, but the sign belongs to the
/// button model, not to whoever calls it.
pub fn fillDelta(state: State, dark: bool) i32 {
    const magnitude: i32 = switch (state) {
        .normal => 0,
        .hover, .active => 15,
        // Pressed reads as a firmer version of hover, the way every Windows
        // chrome button does.
        .pressed => 25,
    };
    return if (dark) magnitude else -magnitude;
}

/// Apply `fillDelta` to one 8-bit channel, clamped.
pub fn shadeChannel(base: u8, delta: i32) u8 {
    const v = @as(i32, base) + delta;
    return @intCast(std.math.clamp(v, 0, 255));
}

/// A point in physical pixels, matching `w32.POINT` field-for-field so a
/// `Quad` can be handed straight to `Polygon` without a copy loop.
pub const Point = extern struct { x: i32, y: i32 };

/// One FILLED convex quad of a glyph, in GDI `Polygon` coordinates — which
/// means right/bottom exclusive, like every other rect in this module.
///
/// Filled, not stroked. `CreatePen` + `MoveToEx`/`LineTo` cannot draw a
/// symmetric mark: `LineTo` excludes its endpoint, so a stroke from `cx-h` to
/// `cx+h` paints one pixel short on the trailing side, and a pen wider than
/// 1 px biases its extra pixel up/left at even widths. Together they are the
/// "left half of the horizontal line of the plus is shorter than the right
/// half" report, and they cannot be fixed by nudging coordinates because the
/// bias flips with DPI. A filled quad has explicit extents, so symmetry is
/// arithmetic rather than a hope. (Design system §4.1.)
pub const Quad = extern struct { pts: [4]Point };

/// The icons the chrome draws. Names follow the Fluent icon they stand in for
/// (ChromeClose, Add, GlobalNavButton) so a later switch to a real icon font
/// is a substitution rather than a redesign.
pub const Glyph = enum {
    /// "×" — close a tab.
    close,
    /// "+" — new tab.
    add,
    /// "≡" — the window menu.
    menu,
    /// Collapse chevron, apex up (the banner is expanded).
    chevron_up,
    /// Expand chevron, apex down (the banner is collapsed).
    chevron_down,
    /// "—" — minimize the window (T254, ChromeMinimize).
    minimize,
    /// "□" — maximize the window (ChromeMaximize).
    maximize,
    /// "❐" — restore a maximized window (ChromeRestore).
    restore,
    /// "…" — the window menu, hosted in the caption bar (T234).
    ///
    /// A second glyph for the same command the hamburger opens, and
    /// deliberately not the hamburger itself: "≡" reads as a menu BAR (the
    /// strip's own control), while "…" is what Windows uses for "more
    /// commands" in a titlebar/command-bar cluster. Sharing the glyph across
    /// the two hosts would make the caption look like a duplicate of the
    /// strip rather than its overflow.
    overflow,
    /// "←" — navigate back (T159, Fluent Back). The FALLBACK draws a left
    /// chevron rather than a shafted arrow: it is the up-chevron transposed,
    /// so its symmetry is inherited rather than re-derived, and a chevron
    /// already reads as back/forward in every minimal browser chrome.
    back,
    /// "→" — navigate forward (Fluent Forward). The back glyph, mirrored.
    forward,
    /// "⟳" — reload the pane (Fluent Refresh). The fallback is an open
    /// square with a gap and a head — crude next to the font's arc, but a
    /// fallback's bar is "readable", not "identical" (see T497's header).
    refresh,
    /// "⌂" — return to the pane's opened location (Fluent Home).
    home,
    /// "≡" — toggle the viewer's table-of-contents overlay (T160, Fluent
    /// GlobalNavButton). The same mark as `menu` on purpose but a distinct
    /// case: on Windows the hamburger IS the native nav-pane toggle (Settings,
    /// the Store), and keeping the case separate means either host can move
    /// off the shared mark without dragging the other with it.
    contents,
    /// "🗩" — file feedback about what this viewer pane is showing (T633,
    /// Fluent Feedback; Mac uses `exclamationmark.bubble`). The FALLBACK is an
    /// open speech bubble with a tail and no interior mark: an exclamation
    /// inside a four-bar outline needs more quads than the shared buffer
    /// carries, and a bare bubble already reads as "say something about this" —
    /// a fallback's bar is "readable", not "identical" (see the header of
    /// `icon_button_paint`).
    feedback,
};

/// The maximum quads any glyph needs, so callers can size a stack buffer.
/// `restore` is the worst case at 6: a four-bar outline for the front square
/// plus two bars for the back one's visible corner.
pub const max_quads: usize = 6;

/// `e` trimmed to fit inside `side` AND to share its parity, so the clearance
/// `(side - e) / 2` is the same integer on both sides with no rounding.
///
/// `Metrics.markPx` already guarantees the parity against the FULL square, so
/// normally this changes nothing. It earns its keep when `targetBox` had to
/// clamp — a strip too cramped for the shared square shrinks its buttons, and
/// a glyph must stay centered in the smaller square rather than inheriting the
/// parity of a square it is no longer in.
fn fitParity(side: i32, e: i32) i32 {
    var v = @min(e, side);
    if (((side - v) & 1) != 0) v -= 1;
    // A mark trimmed out of existence still has to be visible AND keep the
    // parity, so it falls back to the smallest extent of the right parity.
    if (v < 1) v = @min(2 - (side & 1), @max(side, 1));
    return v;
}

/// A rect centered inside `target`, `w` x `h`, right/bottom exclusive.
fn centered(target: Rect, w: i32, h: i32) Rect {
    const cw = fitParity(target.width(), w);
    const ch = fitParity(target.height(), h);
    const left = target.left + @divTrunc(target.width() - cw, 2);
    const top = target.top + @divTrunc(target.height() - ch, 2);
    return .{ .left = left, .top = top, .right = left + cw, .bottom = top + ch };
}

/// An axis-aligned filled bar as a quad, wound clockwise.
fn bar(r: Rect) Quad {
    return .{ .pts = .{
        .{ .x = r.left, .y = r.top },
        .{ .x = r.right, .y = r.top },
        .{ .x = r.right, .y = r.bottom },
        .{ .x = r.left, .y = r.bottom },
    } };
}

/// `q` reflected through the vertical line `x = m/2`. Used to build the second
/// half of a symmetric glyph FROM the first, so the two halves cannot disagree
/// — which is the whole lesson of the asymmetric "+".
fn mirrorX(q: Quad, m: i32) Quad {
    var r: Quad = undefined;
    for (q.pts, 0..) |p, i| r.pts[i] = .{ .x = m - p.x, .y = p.y };
    return r;
}

/// `q` reflected through the horizontal line `y = m/2`.
fn mirrorY(q: Quad, m: i32) Quad {
    var r: Quad = undefined;
    for (q.pts, 0..) |p, i| r.pts[i] = .{ .x = p.x, .y = m - p.y };
    return r;
}

/// `q` reflected through the main diagonal of the square `sq` (x and y
/// swapped). How a horizontal glyph becomes its vertical twin without a
/// second set of coordinates that could disagree with the first — the same
/// rule the mirrors follow.
fn transposeIn(q: Quad, sq: Rect) Quad {
    var r: Quad = undefined;
    for (q.pts, 0..) |p, i| r.pts[i] = .{
        .x = sq.left + (p.y - sq.top),
        .y = sq.top + (p.x - sq.left),
    };
    return r;
}

/// The filled quads for `glyph`, centered in `target`.
///
/// Since T497 this is the FALLBACK: `icon_button_paint.glyph` renders the
/// system icon font (Segoe Fluent Icons, else Segoe MDL2 Assets) first, so a
/// normal Windows 10/11 machine draws Microsoft's own 1 px glyphs — the
/// user's "should feel native like it was built by microsoft" — and only a
/// machine actually missing both faces lands here. The two original reasons
/// for drawing by hand still govern the fallback's design (the same two T172
/// had for the machine-chooser icons):
///
///   1. A symbol font that is missing renders as tofu. "Ships with" is not
///      "is present", and a chrome button that renders as a box is worse
///      than one that is a little heavier — so presence is PROVEN
///      (create/select/GetTextFace) before the font path is trusted, and
///      these quads stay behind it.
///   2. Text characters carry a font's metrics, not ours — which is why the
///      font path uses the fixed DIP sizes in `icon_button_paint`, never the
///      user's tab-title font ("icons still feel too small", the old report).
///
/// Returns the used prefix of `out`, which must hold `max_quads` entries.
pub fn glyphQuads(m: Metrics, target: Rect, glyph: Glyph, out: []Quad) []const Quad {
    std.debug.assert(out.len >= max_quads);
    const t = m.stroke_w;

    switch (glyph) {
        .add => {
            out[0] = bar(centered(target, m.mark_add, t));
            out[1] = bar(centered(target, t, m.mark_add));
            return out[0..2];
        },
        .menu, .contents => {
            const mid = centered(target, m.mark_menu, t);
            out[0] = bar(.{
                .left = mid.left,
                .top = mid.top - m.menu_pitch,
                .right = mid.right,
                .bottom = mid.bottom - m.menu_pitch,
            });
            out[1] = bar(mid);
            // The third rule is the FIRST one mirrored through the middle
            // rule's own center line, so the outer two are equidistant by
            // construction instead of by two independent additions.
            out[2] = mirrorY(out[0], mid.top + mid.bottom);
            return out[0..3];
        },
        .close => {
            // Two diagonal bars across the mark box.
            //
            // `k` is how far each corner vertex sits from the diagonal ALONG
            // an axis, and the arithmetic is the whole reason this glyph is
            // easy to get wrong: the band's two long edges are `2k` apart
            // vertically, so at 45° its PERPENDICULAR thickness is `2k/√2 =
            // k·√2`. Setting `k` to a multiple of the stroke width makes an ×
            // ~1.4x heavier than intended, which paints a filled bowtie
            // instead of a close icon ("what is wrong with the x icon on the
            // tab??? it should be the standard X close icon, not some weird
            // variant", user, 2026-07-31). So k ≈ 3t/4 ≈ t/√2, which lands
            // the × at the same visual weight as the "+" beside it.
            const b = centered(target, m.mark_close, m.mark_close);
            const k = @max(@divTrunc(t * 3, 4), 1);
            // Top-left → bottom-right. The quad is its own 180° rotation
            // about the box center, so the two arms of the cross and the two
            // ends of each arm are all symmetric.
            out[0] = .{ .pts = .{
                .{ .x = b.left, .y = b.top + k },
                .{ .x = b.left + k, .y = b.top },
                .{ .x = b.right, .y = b.bottom - k },
                .{ .x = b.right - k, .y = b.bottom },
            } };
            out[1] = mirrorY(out[0], b.top + b.bottom);
            return out[0..2];
        },
        .chevron_up, .chevron_down => {
            // A shallower rise than the arms are wide — a chevron, not a
            // caret. One arm is built, the other is its mirror.
            const b = centered(target, m.mark_chevron_w, m.mark_chevron_h);
            // Where the arm meets the apex. `+1` so an odd-width chevron's
            // two arms overlap by a pixel at the apex rather than leaving a
            // hole there.
            const run = @divTrunc(b.width() + 1, 2);
            const apex_x = b.left + run;
            // Thickness measured VERTICALLY, and therefore slope-corrected so
            // the thickness the eye reads is `stroke_w` like every other mark
            // in the set (T239). The arm's rise is whatever the box has left
            // after the arm's own thickness, which the correction depends on —
            // so the rise is estimated from the nominal `t`. One step, not a
            // fixed point: the correction is a slope factor whose sensitivity
            // to the rise is well under half a pixel per pixel at every scale.
            const tv = slopedStroke(run, b.height() - t, t);
            // Arm as it runs down-left for `chevron_up`: low at the left edge
            // and high at the apex.
            const left_arm: Quad = .{ .pts = .{
                .{ .x = b.left, .y = b.bottom - tv },
                .{ .x = apex_x, .y = b.top },
                .{ .x = apex_x, .y = b.top + tv },
                .{ .x = b.left, .y = b.bottom },
            } };
            out[0] = left_arm;
            out[1] = mirrorX(left_arm, b.left + b.right);
            if (glyph == .chevron_down) {
                out[0] = mirrorY(out[0], b.top + b.bottom);
                out[1] = mirrorY(out[1], b.top + b.bottom);
            }
            return out[0..2];
        },
        .minimize => {
            // One rule, centered. The simplest glyph in the set, and the one
            // most likely to be "just a LineTo" — which is exactly how it
            // would end up a pixel off center at half the scales.
            out[0] = bar(centered(target, m.mark_caption, t));
            return out[0..1];
        },
        .maximize => {
            // A square OUTLINE, built as four bars rather than as a filled
            // rect punched with a background-colored one: the paint path fills
            // every quad with a single brush, and a punch-out would show the
            // button's REST color through a HOVERED fill.
            const b = centered(target, m.mark_caption, m.mark_caption);
            return squareOutline(b, m.stroke_outline, out);
        },
        .restore => {
            // Two squares, the front one down-left of the back one, and the
            // back one drawn only where it is not hidden (its top and right
            // edges) so it reads as being behind rather than crossing through.
            //
            // Not symmetric internally — it is a depth cue, and a symmetric
            // one would not read as two stacked windows. What IS symmetric,
            // and what the glyph test asserts, is the UNION: the front square
            // owns the left and bottom extents, the back one the top and
            // right, so together they fill exactly the centered mark box.
            const so = m.stroke_outline;
            const off = @min(m.restore_off, @max(m.mark_caption - so - 1, 1));
            const b = centered(target, m.mark_caption, m.mark_caption);
            const front: Rect = .{
                .left = b.left,
                .top = b.top + off,
                .right = b.right - off,
                .bottom = b.bottom,
            };
            const used = squareOutline(front, so, out);
            // Back square's top edge, from the front square's right edge
            // across to the union's right — so the two never overlap-paint.
            out[used.len] = bar(.{
                .left = b.left + off,
                .top = b.top,
                .right = b.right,
                .bottom = b.top + so,
            });
            // ...and its right edge, down to where the front square hides it.
            out[used.len + 1] = bar(.{
                .left = b.right - so,
                .top = b.top,
                .right = b.right,
                .bottom = b.bottom - off,
            });
            return out[0 .. used.len + 2];
        },
        .back, .forward => {
            // The up-chevron's own quads, computed in a centered SQUARE and
            // transposed through its diagonal to point left — then mirrored
            // for forward. Building from the chevron means the arm geometry,
            // its parity handling and its apex overlap are inherited, not
            // re-derived (the mirrored-halves rule, one level up).
            const side = @min(target.width(), target.height());
            const sq = centered(target, side, side);
            var tmp: [max_quads]Quad = undefined;
            const arms = glyphQuads(m, sq, .chevron_up, &tmp);
            for (arms, 0..) |q, i| out[i] = transposeIn(q, sq);
            if (glyph == .forward) {
                for (out[0..arms.len]) |*q| q.* = mirrorX(q.*, sq.left + sq.right);
            }
            return out[0..arms.len];
        },
        .refresh => {
            // An open square with a gap in its top edge and a head hanging
            // into the gap — the crude reading of a circular arrow. Bounds
            // are the full mark box: the right bar still owns the top-right
            // corner, so the glyph stays centered by construction.
            const b = centered(target, m.mark_close, m.mark_close);
            const so = m.stroke_w;
            const gap = @max(@divTrunc(b.width(), 3), so + 1);
            out[0] = bar(.{
                .left = b.left,
                .top = b.top,
                .right = b.right - gap,
                .bottom = b.top + so,
            });
            out[1] = bar(.{ .left = b.right - so, .top = b.top, .right = b.right, .bottom = b.bottom });
            out[2] = bar(.{ .left = b.left, .top = b.bottom - so, .right = b.right - so, .bottom = b.bottom });
            out[3] = bar(.{ .left = b.left, .top = b.top + so, .right = b.left + so, .bottom = b.bottom - so });
            // The head: a small filled drop under the gap's left end, so the
            // gap reads as an arrow entering the loop rather than as damage.
            const head = @max(so + 1, 2);
            out[4] = bar(.{
                .left = b.right - gap,
                .top = b.top,
                .right = b.right - gap + head,
                .bottom = b.top + head,
            });
            return out[0..5];
        },
        .home => {
            // A house: a chevron roof over an open-topped body. The roof owns
            // the full mark width and the top edge, the floor owns the
            // bottom, so the union is exactly the centered mark box.
            const b = centered(target, m.mark_menu, m.mark_menu);
            const roof_h = @max(@divTrunc(b.height(), 3), t);
            const apex_x = b.left + @divTrunc(b.width() + 1, 2);
            // Slope-corrected like the chevron's arms, and for the same
            // reason: the roof is sloped, so a thickness measured vertically
            // paints a lighter mark than the walls under it (T239).
            const rt = slopedStroke(apex_x - b.left, roof_h, t);
            out[0] = .{ .pts = .{
                .{ .x = b.left, .y = b.top + roof_h },
                .{ .x = apex_x, .y = b.top },
                .{ .x = apex_x, .y = b.top + rt },
                .{ .x = b.left, .y = b.top + roof_h + rt },
            } };
            out[1] = mirrorX(out[0], b.left + b.right);
            // Body: two walls and a floor, inset under the eaves. The walls
            // hang from the roof line so the silhouette closes.
            const wi = @max(@divTrunc(b.width(), 5), t);
            const body_top = b.top + roof_h;
            out[2] = bar(.{ .left = b.left + wi, .top = body_top, .right = b.left + wi + t, .bottom = b.bottom - t });
            out[3] = mirrorX(out[2], b.left + b.right);
            out[4] = bar(.{ .left = b.left + wi, .top = b.bottom - t, .right = b.right - wi, .bottom = b.bottom });
            return out[0..5];
        },
        .feedback => {
            // A speech bubble: a four-bar outline with a tail hanging off its
            // bottom-left corner. Outlined at `stroke_outline`, not
            // `stroke_w`, by the same rule the maximize box follows — in a
            // CLOSED mark the eye reads the enclosed area, and a 2 DIP stroke
            // on an 11 DIP box reads as a filled slab (Metrics.stroke_outline).
            //
            // The BODY owns the full mark box and the tail hangs inside its
            // bottom edge, so the union is exactly the centered mark box and
            // the glyph stays centered by construction — the tail cannot drag
            // it off-center the way an appended shape would.
            const b = centered(target, m.mark_close, m.mark_close);
            const so = m.stroke_outline;
            const body_bottom = b.bottom - @max(@divTrunc(b.height(), 4), so + 1);
            out[0] = bar(.{ .left = b.left, .top = b.top, .right = b.right, .bottom = b.top + so });
            out[1] = bar(.{ .left = b.left, .top = body_bottom - so, .right = b.right, .bottom = body_bottom });
            out[2] = bar(.{ .left = b.left, .top = b.top + so, .right = b.left + so, .bottom = body_bottom - so });
            out[3] = mirrorX(out[2], b.left + b.right);
            // The tail: a wedge dropping from the body's bottom edge to the
            // mark box's bottom, its vertical edge continuing the left wall so
            // the two read as one silhouette.
            const tail_w = @max(@divTrunc(b.width(), 3), so + 1);
            out[4] = .{ .pts = .{
                .{ .x = b.left + so, .y = body_bottom - so },
                .{ .x = b.left + so + tail_w, .y = body_bottom - so },
                .{ .x = b.left + so, .y = b.bottom },
                .{ .x = b.left + so, .y = b.bottom },
            } };
            return out[0..5];
        },
        .overflow => {
            // Three square dots on the mark box's center line, spanning the
            // same `mark_caption` extent as the three system glyphs beside it
            // — it is a fourth member of that cluster, so it is sized by the
            // same number rather than by one of its own.
            //
            // Built middle-out and mirrored: the middle dot is centered, the
            // left one is stepped off it, and the right one is the left one
            // reflected. The two outer dots are therefore equidistant from
            // the middle BY CONSTRUCTION, which is the same rule that fixed
            // the hamburger's rules and the "+"'s arms.
            const d = @max(t, 1);
            const b = centered(target, m.mark_caption, d);
            const mid = centered(b, d, d);
            // Whatever is left of the box after the middle dot, split evenly
            // between the two flanks: dot, gap, dot, gap, dot.
            const step = @divTrunc(b.width() - d, 2);
            out[0] = bar(.{
                .left = mid.left - step,
                .top = mid.top,
                .right = mid.right - step,
                .bottom = mid.bottom,
            });
            out[1] = bar(mid);
            out[2] = mirrorX(out[0], b.left + b.right);
            return out[0..3];
        },
    }
}

/// The VERTICAL thickness a SLOPED arm needs so that the thickness the eye
/// reads — the one measured PERPENDICULAR to the arm — is `t`.
///
/// An arm that travels `run` across and `rise` up is a band whose two long
/// edges are `tv` apart measured straight down the screen, but only
/// `tv · run / hypot(run, rise)` apart across the arm. So a glyph built by
/// offsetting its arm vertically by `stroke_w` paints at `stroke_w · cos θ`,
/// and the shallower the arm the less that costs: the banner chevron's arms
/// run 6 across and rise 4, which is `0.83 · stroke_w` — a third of a pixel at
/// 100%, a full pixel at 300%, and one glyph quietly disagreeing with the "+",
/// the "×" and the hamburger beside it at every scale in between (T239).
///
/// This is the same mistake T232 fixed in the "×", where it ran the other way:
/// there the corner offset `k` produced `k·√2` and painted an arm ~1.4x too
/// HEAVY. Both are the design system's §4.3 rule — thickness is measured
/// perpendicular to the mark, never down a screen axis.
fn slopedStroke(run: i32, rise: i32, t: i32) i32 {
    if (run <= 0 or rise <= 0) return t;
    const a: f64 = @floatFromInt(run);
    const r: f64 = @floatFromInt(rise);
    const s: f64 = @floatFromInt(t);
    const tv: i32 = @intFromFloat(@round(s * @sqrt(a * a + r * r) / a));
    // Never thinner than the nominal stroke (the correction only ever adds),
    // and never so thick it eats the whole rise and paints a wedge.
    return std.math.clamp(tv, t, @max(t, rise));
}

/// Four filled bars forming the outline of `b`, `t` thick, drawn inward.
/// The top/bottom bars span the FULL width and the left/right ones only the
/// span between them, so no two bars overlap — overlapping quads are invisible
/// with an opaque brush but paint twice under any future alpha blend.
fn squareOutline(b: Rect, t: i32, out: []Quad) []const Quad {
    out[0] = bar(.{ .left = b.left, .top = b.top, .right = b.right, .bottom = b.top + t });
    out[1] = bar(.{ .left = b.left, .top = b.bottom - t, .right = b.right, .bottom = b.bottom });
    out[2] = bar(.{ .left = b.left, .top = b.top + t, .right = b.left + t, .bottom = b.bottom - t });
    out[3] = bar(.{ .left = b.right - t, .top = b.top + t, .right = b.right, .bottom = b.bottom - t });
    return out[0..4];
}

/// The pixel extent a set of quads actually paints, right/bottom EXCLUSIVE
/// (GDI's polygon fill excludes those edges, which is why the quads are
/// authored in that convention in the first place).
pub fn paintedBounds(quads: []const Quad) Rect {
    var r: Rect = .{
        .left = std.math.maxInt(i32),
        .top = std.math.maxInt(i32),
        .right = std.math.minInt(i32),
        .bottom = std.math.minInt(i32),
    };
    for (quads) |q| for (q.pts) |p| {
        r.left = @min(r.left, p.x);
        r.top = @min(r.top, p.y);
        r.right = @max(r.right, p.x);
        r.bottom = @max(r.bottom, p.y);
    };
    return r;
}

/// Are glyphs centered in their target? Always yes in the shipped build; the
/// neuter answers `false` so the paint sites fall back to the leading
/// alignment the user reported, and the centering assertions fail.
pub fn glyphCentered() bool {
    return !T204_NEUTERED;
}

/// The square a glyph is actually PAINTED in — `targetBox`, except under the
/// neuter, where it is pushed to the box's leading edge.
///
/// T209 added this because `glyphCentered()` was exported and then consumed by
/// nobody: flipping `T204_NEUTERED` changed the fills and left every glyph
/// exactly where the shipped build puts it, so the centering assertions the
/// control exists to adjudicate could not fail. A negative control that
/// answers a question no paint site asks is decoration.
///
/// Leading-aligned rather than "some other offset" because that is the world
/// being restored: the "+" and the "×" were drawn `DT_LEFT` in their boxes,
/// which is why a hovered "+" read as a second tab rather than a button.
///
/// It is the MARK's leading edge that is put on the box's, not the target
/// square's — `DT_LEFT` aligned the drawn character, and the difference is the
/// whole margin the control has to work with. Aligning the square instead
/// moved a 28 DIP glyph by 3 px at 125%, which an acceptance script measuring
/// off an antialiased tab edge cannot separate from noise. Aligning the mark
/// moves it by ~13.
pub fn glyphTarget(m: Metrics, box: Rect, glyph: Glyph) Rect {
    const t = targetBox(m, box);
    if (glyphCentered()) return t;
    var quads: [max_quads]Quad = undefined;
    const mark = paintedBounds(glyphQuads(m, t, glyph, &quads));
    const dx = box.left - mark.left;
    return .{
        .left = t.left + dx,
        .top = t.top,
        .right = t.right + dx,
        .bottom = t.bottom,
    };
}

/// Do the close "×" and the banner chevron light a fill like the "+" and "≡"?
/// Always yes in the shipped build; the neuter answers `false`, restoring the
/// pre-T204 state where those two were the odd ones out.
pub fn universalHover() bool {
    return !T204_NEUTERED;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "targetBox is square and centered in its box" {
    const m = Metrics.init(1.0);
    // The "+"/"≡" hit box: 32 wide, the full 4..40 band.
    const t = targetBox(m, .{ .left = 100, .top = 4, .right = 132, .bottom = 40 });
    try testing.expectEqual(@as(i32, 28), t.width());
    try testing.expectEqual(@as(i32, 28), t.height());
    // Centered horizontally on the box's own center (116).
    try testing.expectEqual(@as(i32, 102), t.left);
    try testing.expectEqual(@as(i32, 130), t.right);
}

test "hitBox and targetBox are exact inverses at every scale" {
    // The rule that makes painted-edge layout possible (T232): a layout can
    // place the PAINTED square, hand its call sites `hitBox` of it, and know
    // the painter — which only ever sees the hit box — recovers the same
    // square. If this drifts by a pixel every gap in the strip drifts with it.
    for ([_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0, 3.0 }) |scale| {
        const m = Metrics.init(scale);
        for ([_]i32{ 0, 1, 7, 100, 1001 }) |left| {
            for ([_]i32{ 0, 3, 4, 17 }) |top| {
                const sq: Rect = .{
                    .left = left,
                    .top = top,
                    .right = left + m.target,
                    .bottom = top + m.target,
                };
                const got = targetBox(m, hitBox(m, sq));
                try testing.expectEqual(sq.left, got.left);
                try testing.expectEqual(sq.top, got.top);
                try testing.expectEqual(sq.right, got.right);
                try testing.expectEqual(sq.bottom, got.bottom);
            }
        }
    }
}

test "the hit box clears the 32 DIP floor without moving the paint" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const sq: Rect = .{ .left = 0, .top = 0, .right = m.target, .bottom = m.target };
        const h = hitBox(m, sq);
        // >= 32 DIP, and grown by the SAME amount on both sides.
        try testing.expect(@as(f32, @floatFromInt(h.width())) >= 32.0 * scale - 0.5);
        try testing.expectEqual(sq.left - h.left, h.right - sq.right);
        try testing.expectEqual(sq.top - h.top, h.bottom - sq.bottom);
    }
}

test "every icon button lands on ONE vertical frame" {
    const m = Metrics.init(1.0);
    // The three strip controls, given the same 4..40 band but different
    // widths. This is the user's "misaligned" complaint, as an assertion:
    // whatever their widths, their vertical extents must be identical.
    const band_top: i32 = 4;
    const band_bottom: i32 = 40;
    const plus = targetBox(m, .{ .left = 0, .top = band_top, .right = 32, .bottom = band_bottom });
    const menu = targetBox(m, .{ .left = 900, .top = band_top, .right = 932, .bottom = band_bottom });
    const close = targetBox(m, .{ .left = 300, .top = band_top, .right = 332, .bottom = band_bottom });

    try testing.expectEqual(plus.top, menu.top);
    try testing.expectEqual(plus.top, close.top);
    try testing.expectEqual(plus.bottom, menu.bottom);
    try testing.expectEqual(plus.bottom, close.bottom);
    // ...and identical size, which is the other half of "consistent design".
    try testing.expectEqual(plus.width(), menu.width());
    try testing.expectEqual(plus.width(), close.width());
}

test "the fill is a square inset inside the target, not a tab-shaped slab" {
    const m = Metrics.init(1.0);
    // The pre-T204 "+" fill was the full 36-wide button box inset by 2, i.e.
    // 32x24 — wider than tall, which is exactly why a hovered "+" read as a
    // second tab. The shared fill is square.
    const f = fillRegion(m, .{ .left = 0, .top = 4, .right = 32, .bottom = 40 });
    const w = f.right - 1 - f.left;
    const h = f.bottom - 1 - f.top;
    try testing.expectEqual(w, h);
    try testing.expectEqual(@as(i32, 24), w);
    try testing.expect(w < 32); // narrower than the old slab
}

test "fill region round-trips CreateRoundRectRgn's inclusive edges" {
    const m = Metrics.init(1.0);
    const box = Rect{ .left = 10, .top = 4, .right = 42, .bottom = 40 };
    const t = targetBox(m, box);
    const f = fillRegion(m, box);
    try testing.expectEqual(t.left + m.inset, f.left);
    try testing.expectEqual(t.right - m.inset + 1, f.right);
    try testing.expectEqual(m.corner_r * 2, f.ellipse);
}

test "a box smaller than the target clamps instead of overflowing" {
    const m = Metrics.init(1.0);
    const box = Rect{ .left = 0, .top = 0, .right = 12, .bottom = 12 };
    const t = targetBox(m, box);
    try testing.expectEqual(@as(i32, 12), t.width());
    try testing.expect(t.left >= box.left);
    try testing.expect(t.right <= box.right);
    try testing.expect(t.top >= box.top);
    try testing.expect(t.bottom <= box.bottom);
}

test "targetBox scales with DPI" {
    const m = Metrics.init(2.0);
    try testing.expectEqual(@as(i32, 56), m.target);
    const t = targetBox(m, .{ .left = 0, .top = 0, .right = 72, .bottom = 64 });
    try testing.expectEqual(@as(i32, 56), t.width());
}

test "glyph size does not track the tab title font" {
    // The regression this pins: every mark extent is derived from the DPI
    // scale alone. Nothing about a user-chosen title font can reach it, which
    // is what "icons still feel too small" was.
    const a = Metrics.init(1.0);
    const b = Metrics.init(1.0);
    try testing.expectEqual(a.mark_add, b.mark_add);
    try testing.expectEqual(@as(i32, 12), a.mark_add);
    try testing.expectEqual(@as(i32, 28), a.target);
}

test "every mark shares its square's parity, so it can be centered exactly" {
    // The arithmetic that makes symmetry constructive rather than hopeful: an
    // extent whose parity differs from the square's cannot be centered on an
    // integer grid, and the leftover half pixel is the "one arm shorter"
    // report. Checked over a wide sweep of scales, not just the pretty ones.
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        for ([_]i32{
            m.stroke_w,   m.mark_add,        m.mark_close,
            m.mark_menu,  m.mark_chevron_w,  m.mark_chevron_h,
        }) |e| {
            try testing.expect(e >= 1);
            try testing.expect(e <= m.target);
            try testing.expectEqual(@as(i32, 0), (m.target - e) & 1);
        }
    }
}

test "every non-normal state paints a fill" {
    // The whole point of the task: hover is a FILL everywhere, not a fill in
    // two places and a color change in a third.
    try testing.expect(!paintsFill(.normal));
    try testing.expect(paintsFill(.hover));
    try testing.expect(paintsFill(.pressed));
    try testing.expect(paintsFill(.active));
}

test "fillDelta shades toward the foreground on dark, away on light" {
    try testing.expectEqual(@as(i32, 0), fillDelta(.normal, true));
    try testing.expectEqual(@as(i32, 15), fillDelta(.hover, true));
    try testing.expectEqual(@as(i32, -15), fillDelta(.hover, false));
    // Pressed is firmer than hover in both themes.
    try testing.expect(@abs(fillDelta(.pressed, true)) > @abs(fillDelta(.hover, true)));
    try testing.expect(@abs(fillDelta(.pressed, false)) > @abs(fillDelta(.hover, false)));
}

test "hover and active shade identically" {
    // A menu button with its popup open should look hovered, not different.
    try testing.expectEqual(fillDelta(.hover, true), fillDelta(.active, true));
}

test "shadeChannel clamps at both ends" {
    try testing.expectEqual(@as(u8, 65), shadeChannel(50, 15));
    try testing.expectEqual(@as(u8, 255), shadeChannel(250, 15));
    try testing.expectEqual(@as(u8, 0), shadeChannel(5, -15));
}

const all_glyphs = [_]Glyph{
    .close,
    .add,
    .menu,
    .chevron_up,
    .chevron_down,
    .minimize,
    .maximize,
    .restore,
    .overflow,
    .back,
    .forward,
    .refresh,
    .home,
    .contents,
    .feedback,
};

/// The painted square a strip button gets at `scale`, i.e. what the glyph
/// tests below are actually drawing into. Derived from the metrics rather
/// than hard-coded, because a hard-coded 32x36 box silently CLAMPS the square
/// at 2.0 and then the test is measuring a cramped button, not the shipped
/// one.
fn squareAt(m: Metrics) Rect {
    const sq: Rect = .{ .left = 0, .top = m.hit_pad, .right = m.target, .bottom = m.hit_pad + m.target };
    return targetBox(m, hitBox(m, sq));
}

test "every glyph is symmetric inside its target, on both axes" {
    // The user's "the left half of the plus is shorter than the right half",
    // as an assertion — and the reason `glyphQuads` replaced pen strokes.
    // Symmetry is stated as EQUAL CLEARANCE inside the square rather than
    // `min + max == 2 * center`: the square's side can be even, in which case
    // its "center" is between two pixels and the old formula silently
    // tolerated a half-pixel bias. This one cannot.
    //
    // Swept finely, not at four hand-picked scales: most of these defects are
    // invisible at 1.0 and obvious at 1.25.
    var buf: [max_quads]Quad = undefined;
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        for ([_]Rect{
            squareAt(m), // the square the strip actually paints
            targetBox(m, .{ .left = 0, .top = 4, .right = 32, .bottom = 40 }),
            targetBox(m, .{ .left = 101, .top = 5, .right = 134, .bottom = 41 }), // odd, clamped
        }) |t| {
            for (all_glyphs) |g| {
                const quads = glyphQuads(m, t, g, &buf);
                // `minimize` is a single bar; everything else is at least two.
                const min_quads: usize = if (g == .minimize) 1 else 2;
                try testing.expect(quads.len >= min_quads);
                const b = paintedBounds(quads);
                // Right/bottom are exclusive, so the last painted pixel is
                // `right - 1`; clearance on each side must match exactly.
                try testing.expectEqual(b.left - t.left, t.right - b.right);
                try testing.expectEqual(b.top - t.top, t.bottom - b.bottom);
            }
        }
    }
}

test "every glyph keeps real clearance inside its square" {
    // Fitting is not enough — a mark that reaches its square's edge reads as
    // touching the button. Design system §0: nothing touches anything.
    var buf: [max_quads]Quad = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        for (all_glyphs) |g| {
            const b = paintedBounds(glyphQuads(m, t, g, &buf));
            try testing.expect(b.left > t.left);
            try testing.expect(b.right < t.right);
            try testing.expect(b.top > t.top);
            try testing.expect(b.bottom < t.bottom);
        }
    }
}

test "the glyphs keep their OPTICAL order, not one shared width" {
    // This test used to assert `close == add == menu` exactly. That is the
    // wrong invariant and it is why the user could see the hamburger was "not
    // wide enough by maybe 2px": equal geometric width does NOT read as equal
    // width. A horizontal-only mark reads narrow and a diagonal cross reads
    // wide, so the sizes are deliberately ordered close < add < menu — and
    // the ORDER is what has to hold at every scale. (Design system §4.2.)
    var buf: [max_quads]Quad = undefined;
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        var w: [3]i32 = undefined;
        for ([_]Glyph{ .close, .add, .menu }, 0..) |g, i| {
            w[i] = paintedBounds(glyphQuads(m, t, g, &buf)).width();
        }
        try testing.expect(w[0] < w[1]);
        try testing.expect(w[1] < w[2]);
        // ...and none of them runs away from the others: the three still read
        // as one set of controls, which is what T204 was about.
        try testing.expect(w[2] - w[0] <= @divTrunc(m.target, 3));
    }
}

test "the two chevrons mirror each other" {
    var up: [max_quads]Quad = undefined;
    var down: [max_quads]Quad = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const t = targetBox(m, .{ .left = 0, .top = 0, .right = m.target, .bottom = m.target });
        const a = glyphQuads(m, t, .chevron_up, &up);
        const b = glyphQuads(m, t, .chevron_down, &down);
        try testing.expectEqual(a.len, b.len);
        const ab = paintedBounds(a);
        const bb = paintedBounds(b);
        // Same footprint, flipped: every vertex of `up` reflects onto one of
        // `down` through the shared bounding box's horizontal axis.
        try testing.expectEqual(ab.left, bb.left);
        try testing.expectEqual(ab.right, bb.right);
        try testing.expectEqual(ab.top, bb.top);
        try testing.expectEqual(ab.bottom, bb.bottom);
        const my = ab.top + ab.bottom;
        for (a, b) |qa, qb| for (qa.pts, qb.pts) |pa, pb| {
            try testing.expectEqual(pa.x, pb.x);
            try testing.expectEqual(my, pa.y + pb.y);
        };
    }
}

/// The narrow dimension of a parallelogram quad, measured PERPENDICULAR to its
/// long side — the thickness the eye actually reads. Every mark in the open set
/// is built as a parallelogram (a bar is the axis-aligned case), so one formula
/// covers the lot: `area / long side`, with the area from the cross product.
fn quadThickness(q: Quad) f64 {
    const ux: f64 = @floatFromInt(q.pts[1].x - q.pts[0].x);
    const uy: f64 = @floatFromInt(q.pts[1].y - q.pts[0].y);
    const vx: f64 = @floatFromInt(q.pts[3].x - q.pts[0].x);
    const vy: f64 = @floatFromInt(q.pts[3].y - q.pts[0].y);
    const area = @abs(ux * vy - uy * vx);
    const lu = @sqrt(ux * ux + uy * uy);
    const lv = @sqrt(vx * vx + vy * vy);
    return area / @max(lu, lv);
}

test "every open glyph paints at the same PERPENDICULAR thickness" {
    // T232 asserted this of the "×" alone; T239 generalised it, because the
    // chevron was failing the same rule in the opposite direction — its arms
    // were offset by `stroke_w` VERTICALLY, which on a sloped arm paints
    // `stroke_w · cos θ`, so the banner's collapse control read lighter than
    // the "+" and the "≡" it sits beside. Measured across the whole open set:
    // whatever the arm's angle, the band the eye reads has to land within a
    // pixel of `stroke_w`, or the controls stop reading as one set.
    //
    // Closed OUTLINE glyphs (maximize, restore) are deliberately absent — they
    // are drawn at `stroke_outline` for the optical reason `Metrics` documents.
    const open = [_]Glyph{
        .add,        .close,   .menu,     .contents,
        .chevron_up, .chevron_down, .back, .forward,
        .minimize,   .home,    .overflow,
    };
    var buf: [max_quads]Quad = undefined;
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const want: f64 = @floatFromInt(m.stroke_w);
        for (open) |g| {
            for (glyphQuads(m, t, g, &buf)) |q| {
                const got = quadThickness(q);
                if (@abs(got - want) > 1.0) {
                    std.debug.print(
                        "scale {d}: {s} paints a {d:.2}px mark, want {d:.2}\n",
                        .{ scale, @tagName(g), got, want },
                    );
                    return error.MarkThicknessOffTheSet;
                }
            }
        }
    }
}

test "a mark is never hairline-invisible at any DPI" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0, 3.0 }) |scale| {
        try testing.expect(Metrics.init(scale).stroke_w >= 2);
    }
}

test "the plus is exactly as long as it is tall" {
    // Cheap, and it would have caught the reported asymmetry on its own: the
    // "+" is two bars of the same extent crossing at the square's center.
    var buf: [max_quads]Quad = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const q = glyphQuads(m, t, .add, &buf);
        try testing.expectEqual(@as(usize, 2), q.len);
        const b = paintedBounds(q);
        try testing.expectEqual(b.width(), b.height());
        try testing.expectEqual(m.mark_add, b.width());
        // Each bar is `stroke_w` across its short axis.
        const h_bar = paintedBounds(q[0..1]);
        const v_bar = paintedBounds(q[1..2]);
        try testing.expectEqual(m.stroke_w, h_bar.height());
        try testing.expectEqual(m.stroke_w, v_bar.width());
        // ...and the two halves of each bar are the same length, which is the
        // literal complaint.
        try testing.expectEqual(v_bar.left - h_bar.left, h_bar.right - v_bar.right);
        try testing.expectEqual(h_bar.top - v_bar.top, v_bar.bottom - h_bar.bottom);
    }
}

test "the close X is a cross, not a bowtie" {
    // Shipped once as a solid blob: `k` was set from the stroke width as
    // though a 45° band's perpendicular thickness were `k/√2`, when it is
    // `k·√2` — a 2x error, which fattened the arms until they merged into a
    // filled bowtie everywhere except the four tips.
    //
    // Asserted as arithmetic on the quad itself: `k` is the corner offset
    // along an axis, `k·√2` the thickness the eye sees, and that has to land
    // within a pixel of the "+"'s bar thickness or the two glyphs do not read
    // as one set of controls.
    var buf: [max_quads]Quad = undefined;
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const q = glyphQuads(m, t, .close, &buf);
        try testing.expectEqual(@as(usize, 2), q.len);
        const k = q[0].pts[1].x - q[0].pts[0].x;
        try testing.expect(k >= 1);
        // |k*√2 - stroke_w| <= 1, in hundredths so it stays integer math.
        try testing.expect(@abs(k * 141 - m.stroke_w * 100) <= 100);
        // The arms must still be thin enough to leave a real notch: the
        // vertical gap between the two long edges (2k) is well under the
        // mark's own extent, or the middle of the X fills solid.
        try testing.expect(2 * k < @divTrunc(m.mark_close, 2));
        // Square footprint, exactly the mark box.
        const b = paintedBounds(q);
        try testing.expectEqual(b.width(), b.height());
        try testing.expectEqual(m.mark_close, b.width());
    }
}

test "the hamburger's three rules are evenly spaced and never merge" {
    var buf: [max_quads]Quad = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const q = glyphQuads(m, t, .menu, &buf);
        try testing.expectEqual(@as(usize, 3), q.len);
        const top = paintedBounds(q[0..1]);
        const mid = paintedBounds(q[1..2]);
        const bot = paintedBounds(q[2..3]);
        try testing.expectEqual(mid.top - top.top, bot.top - mid.top);
        // A real gap between rules, or it reads as a slab.
        try testing.expect(mid.top > top.bottom);
        try testing.expect(bot.top > mid.bottom);
        // All three the same length.
        try testing.expectEqual(top.width(), mid.width());
        try testing.expectEqual(top.width(), bot.width());
    }
}

test "caption glyphs: minimize is one centered rule of the shared thickness" {
    var buf: [max_quads]Quad = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const q = glyphQuads(m, t, .minimize, &buf);
        try testing.expectEqual(@as(usize, 1), q.len);
        const b = paintedBounds(q);
        try testing.expectEqual(m.stroke_w, b.height());
        // Same extent as its two neighbours in the cluster, so the three read
        // as one set of icons rather than three sizes.
        try testing.expectEqual(m.mark_caption, b.width());
    }
}

test "caption glyphs: maximize is a HOLLOW square, not a filled slab" {
    // Four bars with a hole in the middle. A filled rect punched with a
    // background-colored one would show the REST color through a HOVERED
    // fill, which is the kind of bug that only appears on hover.
    var buf: [max_quads]Quad = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const q = glyphQuads(m, t, .maximize, &buf);
        try testing.expectEqual(@as(usize, 4), q.len);
        const b = paintedBounds(q);
        try testing.expectEqual(m.mark_caption, b.width());
        try testing.expectEqual(m.mark_caption, b.height());
        // The center pixel is inside no bar → the square is open.
        const cx = @divTrunc(b.left + b.right, 2);
        const cy = @divTrunc(b.top + b.bottom, 2);
        for (q) |quad| {
            const qb = paintedBounds(&[_]Quad{quad});
            try testing.expect(!(cx >= qb.left and cx < qb.right and
                cy >= qb.top and cy < qb.bottom));
        }
        // Every bar is exactly the OUTLINE stroke thick on its short axis —
        // 1 DIP, not the 2 DIP open-mark stroke. At 2 DIP a 10 DIP box has a
        // 6 DIP interior and reads as a filled square with a dot in it, which
        // is what the first build actually shipped.
        for (q) |quad| {
            const qb = paintedBounds(&[_]Quad{quad});
            try testing.expectEqual(m.stroke_outline, @min(qb.width(), qb.height()));
        }
        // The optical rule, as arithmetic: the enclosed area is the majority
        // of the glyph. Anything less and the outline reads as a fill.
        const interior = m.mark_caption - 2 * m.stroke_outline;
        try testing.expect(interior * 2 > m.mark_caption);
    }
}

test "caption glyphs: restore's two squares fill the mark box between them" {
    // The glyph is asymmetric ON PURPOSE — it is a depth cue. What has to be
    // symmetric, and what "every glyph is symmetric inside its target" checks,
    // is the union: the front square owns left+bottom, the back one top+right.
    // Asserted here directly so a future tweak to `restore_off` cannot quietly
    // shrink the union and leave the whole glyph sitting off-center.
    var buf: [max_quads]Quad = undefined;
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const q = glyphQuads(m, t, .restore, &buf);
        try testing.expectEqual(@as(usize, 6), q.len);
        const b = paintedBounds(q);
        try testing.expectEqual(m.mark_caption, b.width());
        try testing.expectEqual(m.mark_caption, b.height());
        // The front square (the first four bars) is inset from the union's
        // top and right, and flush with its left and bottom — i.e. it really
        // is in front and down-left.
        const front = paintedBounds(q[0..4]);
        try testing.expectEqual(b.left, front.left);
        try testing.expectEqual(b.bottom, front.bottom);
        try testing.expect(front.top > b.top);
        try testing.expect(front.right < b.right);
        // The offset always clears the stroke, or the back square's edges
        // merge into the front one's and the glyph is a blob.
        try testing.expect(front.top - b.top > m.stroke_outline);
    }
}

test "caption glyphs: the overflow dots are three, even, and never merge" {
    // Three dots is the whole glyph, so the two failure modes are: the dots
    // touch (it reads as a dash, which is `minimize`) or they are unevenly
    // spaced (which is what a hand-placed third dot always does). Both are
    // arithmetic, and both are invisible at 1.0 — swept finely, per §7.
    var buf: [max_quads]Quad = undefined;
    var scale: f32 = 1.0;
    while (scale <= 3.0) : (scale += 0.05) {
        const m = Metrics.init(scale);
        const t = squareAt(m);
        const q = glyphQuads(m, t, .overflow, &buf);
        try testing.expectEqual(@as(usize, 3), q.len);

        const b = paintedBounds(q);
        // It is a member of the caption cluster, so it spans that cluster's
        // one extent — not a fourth number that happens to look similar.
        try testing.expectEqual(m.mark_caption, b.width());

        // Left → middle → right, each a square dot of the shared stroke.
        const left = paintedBounds(q[0..1]);
        const mid = paintedBounds(q[1..2]);
        const right = paintedBounds(q[2..3]);
        for ([_]Rect{ left, mid, right }) |dot| {
            try testing.expectEqual(m.stroke_w, dot.width());
            try testing.expectEqual(m.stroke_w, dot.height());
            // One horizontal line: three dots that drifted vertically would
            // read as an ellipsis falling over.
            try testing.expectEqual(left.top, dot.top);
        }

        // Evenly spaced, and with a real gap: dots that touch are a dash.
        const gap_l = mid.left - left.right;
        const gap_r = right.left - mid.right;
        try testing.expectEqual(gap_l, gap_r);
        try testing.expect(gap_l >= 1);

        // Flush with the mark box on both flanks, so the glyph's extent is
        // the dots themselves rather than the dots plus a stray margin.
        try testing.expectEqual(b.left, left.left);
        try testing.expectEqual(b.right, right.right);
    }
}

test "glyphTarget is the centered target in the shipped build" {
    // The paint sites call THIS, so a build where it stopped agreeing with
    // `targetBox` would ship the neuter's leading alignment (T209).
    const m = Metrics.init(1.0);
    const box: Rect = .{ .left = 100, .top = 4, .right = 132, .bottom = 40 };
    for ([_]Glyph{ .add, .close, .menu, .chevron_up }) |g| {
        try testing.expectEqual(targetBox(m, box), glyphTarget(m, box, g));
    }
}

test "the shipped build centers glyphs and lights every button" {
    // These pin the SHIPPED behavior on every build, so flipping the neuter
    // for a negative-control run cannot be forgotten in place.
    try testing.expect(glyphCentered());
    try testing.expect(universalHover());
    try testing.expect(!T204_NEUTERED);
}

