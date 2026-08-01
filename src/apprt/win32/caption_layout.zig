//! Pure geometry for the win32 caption bar (T254). No OS imports, so these
//! unit tests run in every app-runtime lane (the `split_geometry.zig` /
//! `tab_strip_layout.zig` pattern). The painting half is `paintCaption` in
//! Window.zig and the hit tests are `WM_NCHITTEST` + `handleCaptionClick`,
//! which consume the same rects — the one rule that keeps what you see and
//! what you can click from drifting apart.
//!
//! ## Why this module exists at all
//!
//! Until T254 the window was a plain `WS_OVERLAPPEDWINDOW` and the caption —
//! title text, minimize, maximize, close — was drawn by **DWM**, in the
//! non-client area, in another process's composition pass. T78 and T203 only
//! ever *asked DWM to restyle its own caption* (`DWMWA_CAPTION_COLOR`,
//! `DWMWA_TEXT_COLOR`, the immersive dark-mode flag). Tinting a surface
//! somebody else paints is not owning it: there is no DC to draw a button
//! into, and `GetWindowDC` + `WM_NCPAINT` is composited away.
//!
//! So `WM_NCCALCSIZE` gives the caption band back to the client area, and
//! everything in it becomes ours to lay out, paint and hit-test. That is the
//! prerequisite T234 (a "…" button left of minimize) assumed it already had,
//! and the one T205 (tabs inside the titlebar) needs next.
//!
//! ## The rules it is built to (docs/design/win32-design-system.md)
//!
//!   * **One icon-button size.** The caption buttons paint the SAME 28 DIP
//!     square as the strip's "+", "≡" and "×", from the same
//!     `icon_button.Metrics` — not a second constant that happens to agree
//!     today. Windows' own caption buttons are 46x32 px slabs; matching that
//!     would put two button vocabularies one row apart in the same window.
//!   * **Nothing touches anything.** 4 DIP between adjacent painted squares
//!     and between the group and the window edge; the title keeps `md` (8)
//!     from the button group because they are different GROUPS of controls.
//!   * **Size the container to the control.** `caption_h` is 4 + 28 + 4 = 36
//!     DIP because that is what the square plus its clearance needs. It is
//!     not a number copied off `SM_CYCAPTION`.
//!   * **Gaps between PAINTED edges, never hit boxes.** Every rect this module
//!     returns is the PAINTED square; `hitBox` grows it afterwards, and the
//!     grown boxes are allowed to eat the gaps between squares (they must not
//!     overlap each other, which `captionButtonHitBoxesNeverOverlap` asserts).
//!
//! ## The tab run shares the band (T205)
//!
//! `Mode.with_tabs` is the merged row: tabs, "+", then the drag gap, then the
//! "…" and the system trio, all on ONE row — what Windows Terminal, Edge and
//! Explorer do, and what the user asked for ("this is normal terminal and it
//! looks more polished than what you've built … the hamburger icon doesn't
//! horizontally align under the X above it"). Two rows of controls owned by
//! two different layouts can only ever *approximately* line up; one row makes
//! the alignment structural.
//!
//! Two things change in that mode and nothing else does:
//!
//!   * **The band is the STRIP's height, and the buttons sit on the strip's
//!     button baseline** — `btn_top` comes from `tab_strip_layout`'s own
//!     `buttonHit`/`targetBox` derivation, not from centering in the band. The
//!     "+" and the close "×" are already on that frame (T204); a caption
//!     button centered in the 40 DIP band instead would land 2 px higher and
//!     miss all three by exactly the amount the eye catches.
//!   * **The title is dropped.** The tabs are the title now, and painting a
//!     window title behind them is the two-rows problem in one row.
//!
//! `band_left` is the seam: the strip paints `[0, band_left)`, the caption
//! paints `[band_left, client_w)`, and the "+"'s painted right edge lands
//! exactly on it. The caption's own arrangement — right-anchored, close
//! outermost, "…" one group-gap inboard — is IDENTICAL in both modes, which
//! is why merging changed no horizontal number.

const std = @import("std");
const testing = std.testing;
const icon_button = @import("icon_button.zig");
const tab_strip = @import("tab_strip_layout.zig");

/// The caption speaks the same rectangle the rest of the chrome does — one
/// definition, in `icon_button.zig`.
pub const Rect = icon_button.Rect;

/// Everything clickable in the caption, ordered left-to-right as it is laid
/// out. The three system commands are in Windows' order, which is also the
/// order the muscle memory of every Windows user expects; the app's own "…"
/// sits OUTSIDE that group, to its left, so it can never be mistaken for a
/// fourth system button and can never be the thing under a pointer thrown at
/// the top-right corner.
pub const Button = enum { overflow, minimize, maximize, close };

/// Does the band hold the tab run as well (T205)?
///
/// `standalone` is a window showing one tab (or none): no strip exists, so the
/// band is its own 36 DIP row with the window title in it. `with_tabs` is the
/// merged row.
pub const Mode = enum { standalone, with_tabs };

/// Every DIP constant the caption is built from, resolved to physical pixels
/// for one DPI scale.
pub const Metrics = struct {
    /// Which band this is. Carried so `layout` can drop the title without the
    /// caller having to remember to, and so a `Metrics` and the `Layout` built
    /// from it can never describe two different rows.
    mode: Mode,
    /// Caption band height: `sm` + the shared 28 DIP square + `sm` = 36 DIP
    /// standalone; the tab strip's own `bar_h` (40 DIP) when the run shares it.
    ///
    /// Derived from the control, never the reverse (design system §0
    /// corollary). Centering a 28 DIP square inside a band sized from
    /// `SM_CYCAPTION` is exactly the mistake that produced the strip's 1 px
    /// bottom gap, and it would recur here at a different set of scales.
    caption_h: i32,
    /// Top of every caption button's PAINTED square, band-local.
    ///
    /// Standalone that is `pad_sm`. Merged it is whatever y the strip's own
    /// "+" paints at — asked of `tab_strip_layout` rather than restated, since
    /// the strip's buttons sit in the TABS' band (`tab_top_pad`..`bar_h`) and
    /// not in the full bar, a deliberate asymmetry that a local `(h - 28)/2`
    /// would quietly undo.
    btn_top: i32,
    /// The 4 DIP step. Button-to-button, and group-to-window-edge.
    pad_sm: i32,
    /// The 8 DIP step, for separating GROUPS: the title text from the button
    /// cluster.
    pad_md: i32,
    /// The PAINTED square of every caption button — `icon_button.Metrics.target`.
    btn_paint: i32,
    /// How far a button's HIT box grows past its painted square per side.
    btn_pad: i32,
    /// The shared chrome button metrics themselves, carried rather than
    /// copied: the painter needs them for glyphs and fills, and a caption
    /// button that drew from a second `icon_button.Metrics.init(scale)` could
    /// disagree with the square this module laid out.
    ib: icon_button.Metrics,

    pub fn init(scale: f32, mode: Mode) Metrics {
        // Not re-derived: the caption's gaps are measured against the shared
        // chrome square, so it has to BE the shared square.
        const ib = icon_button.Metrics.init(scale);
        const sm = px(4.0, scale);
        // The strip's band and its button baseline, asked for rather than
        // restated. In `standalone` nothing here is used — but computing it
        // unconditionally keeps the two branches to one expression each.
        const ts = tab_strip.Metrics.init(scale);
        return .{
            .mode = mode,
            .caption_h = switch (mode) {
                .standalone => sm + ib.target + sm,
                .with_tabs => ts.bar_h,
            },
            .btn_top = switch (mode) {
                .standalone => sm,
                // `buttonHit(0)` is the strip's own hit box for a button whose
                // painted square starts at x = 0; `targetBox` recovers that
                // square. Its `top` is the baseline the "+", the "≡" and the
                // tab close "×" already share.
                .with_tabs => icon_button.targetBox(ib, ts.buttonHit(0)).top,
            },
            .pad_sm = sm,
            .pad_md = px(8.0, scale),
            .btn_paint = ib.target,
            .btn_pad = ib.hit_pad,
            .ib = ib,
        };
    }

    fn px(dip: f32, scale: f32) i32 {
        return @intFromFloat(@round(dip * scale));
    }
};

/// Where everything in the caption band landed. All rects are PAINTED
/// extents, right/bottom exclusive, in client coordinates with the band's top
/// at y = 0.
pub const Layout = struct {
    /// The "…" window-menu button (T234). Left of `minimize`, separated from
    /// the system trio by `pad_md` rather than `pad_sm`: it is a different
    /// GROUP of controls (ours vs the OS's), and the design system's answer to
    /// "these are different groups" is one step up the spacing scale. The
    /// alternative — an evenly-spaced run of four — is exactly the
    /// undifferentiated cluster the "+"/"≡" pair was reported as.
    overflow: Rect,
    minimize: Rect,
    maximize: Rect,
    close: Rect,
    /// Where the window title may draw. Empty when the band is too narrow to
    /// hold both the buttons and a title, in which case the title is dropped
    /// rather than painted under the buttons — and always empty in
    /// `.with_tabs`, where the tabs ARE the title.
    title: Rect,
    /// The seam between the two painters (T205): the tab strip owns
    /// `[0, band_left)` of the band and the caption owns `[band_left,
    /// client_w)`. `0` in `.standalone` — the caption owns the whole row.
    ///
    /// It sits one `pad_md` left of the "…", which is exactly where the "+"'s
    /// painted right edge lands when the run is full, so the two painters meet
    /// on a painted edge instead of overlapping. Both fill with the same
    /// chrome background, so the seam is invisible either way; what it really
    /// buys is that neither BitBlt can erase the other's buttons, whatever
    /// order they paint in.
    band_left: i32,
    /// Everything left of `drag_right` in the band is `HTCAPTION`: drag to
    /// move, double-click to maximize. The button hit boxes own the rest.
    drag_right: i32,
    /// The client width this layout was computed for. Carried so the hit
    /// tests can reason about the window's right edge (the close button's hit
    /// box runs to it) without every caller having to pass it in again and
    /// risk passing a different one than the layout used.
    client_w: i32,
};

/// Lay the caption band out for a client area `client_w` wide.
///
/// Right-anchored, in Windows' order, close outermost: a user who throws the
/// pointer at the top-right corner must land on close, which is the whole
/// reason that corner is where it is (Fitts' law, and Windows has trained it
/// for thirty years).
pub fn layout(m: Metrics, client_w: i32) Layout {
    const top = m.btn_top;
    const bot = top + m.btn_paint;

    // Right to left: close, maximize, minimize. Built by stepping one
    // (square + gap) at a time from the right edge inset, so the three gaps
    // are the same integer by construction and cannot round apart.
    const step = m.btn_paint + m.pad_sm;
    const close_r = client_w - m.pad_sm;
    const close: Rect = .{ .left = close_r - m.btn_paint, .top = top, .right = close_r, .bottom = bot };
    const max: Rect = .{ .left = close.left - step, .top = top, .right = close.right - step, .bottom = bot };
    const min: Rect = .{ .left = max.left - step, .top = top, .right = max.right - step, .bottom = bot };

    // The app's own button, one GROUP separation left of the system trio.
    const over_r = min.left - m.pad_md;
    const over: Rect = .{ .left = over_r - m.btn_paint, .top = top, .right = over_r, .bottom = bot };

    // The drag region ends where the leftmost button's HIT box begins — not
    // where its paint begins. A hit box must never contribute to a visible
    // gap (design system §0 rule 2), but it is exactly what decides where a
    // click stops being a drag.
    const drag_right = over.left - innerPad(m);

    // The title stops `md` short of the button group, because they are
    // different groups of controls. A band with no room for both drops the
    // title; painting it under the buttons is worse than not painting it.
    // In `.with_tabs` there is no title at all — the tab run has the space.
    const title_l = m.pad_md;
    const title_r = over.left - m.pad_md;
    const title: Rect = if (m.mode == .standalone and title_r > title_l)
        .{ .left = title_l, .top = 0, .right = title_r, .bottom = m.caption_h }
    else
        .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

    return .{
        .overflow = over,
        .minimize = min,
        .maximize = max,
        .close = close,
        .title = title,
        .drag_right = drag_right,
        .band_left = switch (m.mode) {
            .standalone => 0,
            .with_tabs => @max(over.left - m.pad_md, 0),
        },
        .client_w = client_w,
    };
}

/// How far a caption button's hit box may grow toward its NEIGHBOUR.
///
/// `icon_button.hit_pad` is 2 DIP and the gap between two painted squares is
/// 4 DIP, so in DIP terms the two boxes meet exactly. At fractional scales
/// they do not: at 1.25 the pad rounds to 3 and the gap to 5, and the boxes
/// overlap by a pixel — which means one button silently eats a strip of its
/// neighbour's clicks, and by right-to-left order that button is always
/// `close`. Half the gap, rounded DOWN, can never overlap at any scale.
///
/// This is the interior sides only. Outward, the boxes run to the band's
/// edges (see `hitBox`), because there is nothing out there to collide with.
fn innerPad(m: Metrics) i32 {
    return @min(m.btn_pad, @divTrunc(m.pad_sm, 2));
}

/// The HIT box for a caption button: the painted square, grown to the band's
/// full height, grown `innerPad` toward its neighbours, and — for the
/// outermost button — grown all the way to the window edge.
///
/// That last part is deliberate and is why this does not simply call
/// `icon_button.hitBox`. Windows has trained thirty years of users that
/// slamming the pointer into the top-right corner closes the window (Fitts'
/// law: an edge is infinitely tall, a 4 DIP inset from it is not). The design
/// system's answer is already written down — rule 2, a hit box may be bigger
/// than its paint because it is invisible — so the close button PAINTS with
/// its 4 DIP inset and HITS to the corner.
///
/// On a restored window the top rows are the resize edge and `ncHitTest`
/// gives them to `HTTOP` before it ever asks about a button, exactly as a
/// stock frame does; maximized, there is no resize edge and the corner really
/// is close's.
pub fn hitBox(m: Metrics, l: Layout, b: Button) Rect {
    const inner = innerPad(m);
    const painted = switch (b) {
        .overflow => l.overflow,
        .minimize => l.minimize,
        .maximize => l.maximize,
        .close => l.close,
    };
    return .{
        .left = painted.left - inner,
        .top = 0,
        .right = if (b == .close) l.client_w else painted.right + inner,
        .bottom = m.caption_h,
    };
}

/// The system command a caption button stands for.
///
/// Kept here, as a pure mapping, rather than inline in the wndproc: it is the
/// one part of the click path that is decidable without a window, and it is
/// the part most likely to be wrong in a way nothing notices — a maximize
/// button that always sends `SC_MAXIMIZE` looks perfect until you click it on
/// an already-maximized window and nothing happens.
pub const Command = enum { minimize, maximize, restore, close, menu };

pub fn command(b: Button, maximized: bool) Command {
    return switch (b) {
        // Not a `WM_SYSCOMMAND` at all — the caller opens the app's own menu.
        // It is in this enum anyway so that "what does this button do" has
        // exactly one answer, decided in the pure module with the rest.
        .overflow => .menu,
        .minimize => .minimize,
        .maximize => if (maximized) .restore else .maximize,
        .close => .close,
    };
}

/// Which caption button, if any, is under a point in band-local coordinates.
///
/// Tested right-to-left so that even if a future layout let two boxes touch,
/// the outer (destructive) button never silently swallows its neighbour's
/// clicks — `captionButtonHitBoxesNeverOverlap` is what keeps that from being
/// load-bearing.
pub fn hitTest(m: Metrics, l: Layout, x: i32, y: i32) ?Button {
    if (y < 0 or y >= m.caption_h) return null;
    if (hitBox(m, l, .close).containsPoint(x, y)) return .close;
    if (hitBox(m, l, .maximize).containsPoint(x, y)) return .maximize;
    if (hitBox(m, l, .minimize).containsPoint(x, y)) return .minimize;
    if (hitBox(m, l, .overflow).containsPoint(x, y)) return .overflow;
    return null;
}

/// Is a band-local point in the draggable caption region?
pub fn isDragRegion(m: Metrics, l: Layout, x: i32, y: i32) bool {
    if (y < 0 or y >= m.caption_h) return false;
    return x >= 0 and x < l.drag_right;
}

/// What `WM_NCHITTEST` should answer for a point in band-local coordinates.
///
/// The whole policy lives here rather than in the wndproc so it is testable
/// with no window: the ORDER of these questions is the part that goes wrong.
/// Resize edges come first — a caption button that answered before the top
/// border would make a restored window's top edge un-grabbable in three
/// places, and the user would just find that the window "sometimes" cannot be
/// resized from the top.
pub const NcHit = enum {
    top,
    top_left,
    top_right,
    overflow,
    minimize,
    maximize,
    close,
    caption,
    /// Not the caption's business — the caller falls through to its own
    /// client handling (or `DefWindowProc`).
    client,
};

pub fn ncHitTest(
    m: Metrics,
    l: Layout,
    x: i32,
    y: i32,
    /// `SM_CYSIZEFRAME + SM_CXPADDEDBORDER` at this window's DPI.
    sys_frame: i32,
    /// A maximized window has no resize edge; its top row is content.
    maximized: bool,
    /// T205: how far right the CLIENT's own chrome reaches into the band —
    /// the right edge of the strip's "+" hit box, i.e. everything the tab
    /// strip lays out and hit-tests itself. `0` when the band holds no tabs.
    ///
    /// It is a parameter rather than a `Layout` field because the strip's
    /// controls move with the tab TITLES: the "+" follows the last tab, whose
    /// width comes from text this module never measures. The caller passes the
    /// rect the strip actually published, so what you see, what the strip
    /// clicks, and what `WM_NCHITTEST` hands to the client are one number.
    client_right: i32,
) NcHit {
    if (y < 0 or y >= m.caption_h) return .client;
    // Outside the client area horizontally is the window's LEFT/RIGHT sizing
    // border, which `WM_NCCALCSIZE` deliberately left with the OS. Answering
    // `.caption` there (the old fallback did) makes the top corners
    // un-resizable from the outside — the window drags instead of sizing, and
    // the user just finds that one corner "doesn't work".
    if (x < 0 or x >= l.client_w) return .client;

    if (!maximized and y < resizeBorder(m, sys_frame)) {
        const corner = resizeCorner(m, sys_frame);
        if (x < corner) return .top_left;
        if (x >= l.client_w - corner) return .top_right;
        return .top;
    }

    // The strip's own controls, AFTER the resize edge (a tab must not make the
    // window's top border un-grabbable — that is the same ordering rule the
    // caption buttons already obey) and BEFORE the caption's, since the two
    // regions are disjoint by construction and asking in this order means a
    // stale `client_right` can never swallow the close button.
    if (x < @min(client_right, l.band_left)) return .client;

    if (hitTest(m, l, x, y)) |b| return switch (b) {
        .overflow => .overflow,
        .minimize => .minimize,
        .maximize => .maximize,
        .close => .close,
    };

    if (isDragRegion(m, l, x, y)) return .caption;
    // The slivers between two buttons' hit boxes. Dragging from them is the
    // only sane answer: they are inside the caption band, they paint the
    // caption background, and treating them as client would put a terminal
    // hit test in the titlebar.
    return .caption;
}

/// Thickness of the top resize band, in physical pixels.
///
/// `WM_NCCALCSIZE` hands the top border to the client area along with the
/// caption, so the OS no longer offers a resize edge there — this band is what
/// `WM_NCHITTEST` turns back into `HTTOP`. `sys_frame` is the caller's
/// DPI-aware `SM_CYSIZEFRAME + SM_CXPADDEDBORDER` (this module takes no OS
/// dependency); 0 or nonsense falls back to the 4 DIP the system uses at 100%.
///
/// Clamped to at most half the band so the caption can never become entirely
/// un-draggable at an absurd system metric.
pub fn resizeBorder(m: Metrics, sys_frame: i32) i32 {
    const fallback = @max(@divTrunc(m.pad_sm, 1), 1);
    const v = if (sys_frame > 0) sys_frame else fallback;
    return @max(1, @min(v, @divTrunc(m.caption_h, 2)));
}

/// Corner grab width for `HTTOPLEFT` / `HTTOPRIGHT`, in physical pixels.
/// Windows uses roughly double the edge thickness so the diagonal grab is
/// reachable; matching it keeps the resize feel identical to a stock frame.
pub fn resizeCorner(m: Metrics, sys_frame: i32) i32 {
    return @min(resizeBorder(m, sys_frame) * 2, @divTrunc(m.caption_h, 2));
}

// -- tests -------------------------------------------------------------------
//
// Every one runs at 1.0, 1.25, 1.5 and 2.0. Design system §7: "most of these
// bugs are invisible at 1.0 and obvious at 1.25."

const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "caption_h is the shared square plus one spacing step above and below" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const ib = icon_button.Metrics.init(s);
        // Size the container to the control, never the reverse.
        try testing.expectEqual(ib.target + 2 * m.pad_sm, m.caption_h);
        try testing.expectEqual(ib.target, m.btn_paint);
        try testing.expectEqual(ib.hit_pad, m.btn_pad);
    }
}

test "every caption button paints the same square on one vertical frame" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        const all = [_]Rect{ l.overflow, l.minimize, l.maximize, l.close };
        for (all) |r| {
            try testing.expectEqual(m.btn_paint, r.width());
            try testing.expectEqual(m.btn_paint, r.height());
            try testing.expectEqual(l.close.top, r.top);
            try testing.expectEqual(l.close.bottom, r.bottom);
        }
    }
}

test "nothing touches: painted gaps are exactly one spacing step" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        // Button to button WITHIN the system trio, between PAINTED edges.
        try testing.expectEqual(m.pad_sm, l.maximize.left - l.minimize.right);
        try testing.expectEqual(m.pad_sm, l.close.left - l.maximize.right);
        // Our "…" to the system trio: a GROUP separation, so `md`. This is
        // the one gap in the band that is deliberately NOT `sm`, and it is
        // what keeps four squares from reading as one undifferentiated run.
        try testing.expectEqual(m.pad_md, l.minimize.left - l.overflow.right);
        // Group to the window's right edge, and to the band's top/bottom.
        try testing.expectEqual(m.pad_sm, 1200 - l.close.right);
        try testing.expectEqual(m.pad_sm, l.close.top);
        try testing.expectEqual(m.pad_sm, m.caption_h - l.close.bottom);
        // Title to the button group: a GROUP separation, so `md`.
        try testing.expectEqual(m.pad_md, l.overflow.left - l.title.right);
        try testing.expectEqual(m.pad_md, l.title.left);
    }
}

test "caption button hit boxes never overlap each other" {
    // A hit box may eat the gap between two painted squares — that is what it
    // is for — but two of them overlapping means one button steals the
    // other's clicks, and by right-to-left order the one that wins is always
    // `close`. Swept finely, not at four hand-picked scales: the naive
    // `hit_pad` on both sides overlaps at 1.25 and nowhere else.
    var s: f32 = 1.0;
    while (s <= 3.0) : (s += 0.05) {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        const hover = hitBox(m, l, .overflow);
        const hmin = hitBox(m, l, .minimize);
        const hmax = hitBox(m, l, .maximize);
        const hclose = hitBox(m, l, .close);
        try testing.expect(hover.right <= hmin.left);
        try testing.expect(hmin.right <= hmax.left);
        try testing.expect(hmax.right <= hclose.left);
        // Each box still contains the whole square it stands for, or the
        // "forgiving target" has been forgiving in the wrong direction.
        try testing.expect(hover.left <= l.overflow.left and hover.right >= l.overflow.right);
        try testing.expect(hmin.left <= l.minimize.left and hmin.right >= l.minimize.right);
        try testing.expect(hmax.left <= l.maximize.left and hmax.right >= l.maximize.right);
        try testing.expect(hclose.left <= l.close.left and hclose.right >= l.close.right);
    }
}

test "hitTest finds each button and nothing between or outside them" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        const cy = @divTrunc(m.caption_h, 2);
        try testing.expectEqual(Button.overflow, hitTest(m, l, l.overflow.left + 1, cy).?);
        try testing.expectEqual(Button.minimize, hitTest(m, l, l.minimize.left + 1, cy).?);
        try testing.expectEqual(Button.maximize, hitTest(m, l, l.maximize.left + 1, cy).?);
        try testing.expectEqual(Button.close, hitTest(m, l, l.close.left + 1, cy).?);
        // The title area is not a button. (The far right edge IS close — see
        // "the top-right corner lands on close".)
        try testing.expect(hitTest(m, l, l.title.left + 1, cy) == null);
        try testing.expect(hitTest(m, l, 0, cy) == null);
        // Below the band is not the caption's business at all.
        try testing.expect(hitTest(m, l, l.close.left + 1, m.caption_h) == null);
        try testing.expect(hitTest(m, l, l.close.left + 1, -1) == null);
    }
}

test "the top-right corner lands on close, not on empty band" {
    // Fitts' law, and thirty years of Windows muscle memory: throwing the
    // pointer into the corner must close the window. The 4 DIP inset means
    // the painted square does not reach the corner, so the HIT box has to.
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        // Every pixel of the last column inside the band, top row included.
        try testing.expectEqual(Button.close, hitTest(m, l, 1199, 0).?);
        try testing.expectEqual(Button.close, hitTest(m, l, 1199, m.caption_h - 1).?);
        // And the band's full height belongs to the buttons vertically, so a
        // click just under a glyph is not a lost click either.
        try testing.expectEqual(Button.minimize, hitTest(m, l, l.minimize.left + 1, 0).?);
        try testing.expectEqual(Button.minimize, hitTest(m, l, l.minimize.left + 1, m.caption_h - 1).?);
    }
}

test "drag region ends at the leftmost button's hit box, not its paint" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        try testing.expect(isDragRegion(m, l, l.title.left + 1, 1));
        try testing.expect(isDragRegion(m, l, l.drag_right - 1, 1));
        try testing.expect(!isDragRegion(m, l, l.drag_right, 1));
        // The boundary is the hit box: a click one pixel left of the painted
        // "…" square must still be a drag, not a lost click.
        try testing.expectEqual(hitBox(m, l, .overflow).left, l.drag_right);
        // And nothing in the drag region hit-tests as a button.
        try testing.expect(hitTest(m, l, l.drag_right - 1, 1) == null);
    }
}

test "ncHitTest: resize edges are asked BEFORE buttons, and only when restored" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        const frame: i32 = @intFromFloat(@round(8.0 * s));
        const border = resizeBorder(m, frame);
        const corner = resizeCorner(m, frame);

        // Restored: the top rows are the resize edge, everywhere across the
        // band — including directly over the close button, exactly as a stock
        // frame behaves.
        try testing.expectEqual(NcHit.top, ncHitTest(m, l, 600, 0, frame, false, 0));
        try testing.expectEqual(NcHit.top_left, ncHitTest(m, l, 0, 0, frame, false, 0));
        try testing.expectEqual(NcHit.top_right, ncHitTest(m, l, 1199, 0, frame, false, 0));
        try testing.expectEqual(NcHit.close, ncHitTest(m, l, 1199, border, frame, false, 0));

        // Maximized: no resize edge at all, so the very corner is close and
        // the band's top row is draggable/clickable all the way across.
        try testing.expectEqual(NcHit.close, ncHitTest(m, l, 1199, 0, frame, true, 0));
        try testing.expectEqual(NcHit.caption, ncHitTest(m, l, 600, 0, frame, true, 0));

        // Below the band is nobody's business here — and neither is the side
        // sizing border, which the OS still owns.
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, 600, m.caption_h, frame, false, 0));
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, 1200, 1, frame, true, 0));
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, -1, 1, frame, true, 0));

        // The corner grab is wider than the edge, but never so wide that the
        // middle of a 1200 px band stops being a plain top edge.
        try testing.expect(corner > 0 and corner < 600);

        // Each button answers for itself below the resize edge.
        const y = m.caption_h - 1;
        try testing.expectEqual(NcHit.overflow, ncHitTest(m, l, l.overflow.left + 1, y, frame, false, 0));
        try testing.expectEqual(NcHit.minimize, ncHitTest(m, l, l.minimize.left + 1, y, frame, false, 0));
        try testing.expectEqual(NcHit.maximize, ncHitTest(m, l, l.maximize.left + 1, y, frame, false, 0));
        try testing.expectEqual(NcHit.close, ncHitTest(m, l, l.close.left + 1, y, frame, false, 0));
        try testing.expectEqual(NcHit.caption, ncHitTest(m, l, l.title.left + 1, y, frame, false, 0));
    }
}

test "ncHitTest: the gap between two buttons drags, it never falls to client" {
    // The slivers between hit boxes are inside the caption and paint the
    // caption background. Answering `client` there would put a terminal hit
    // test in the titlebar — invisible until a user drags from a one-pixel
    // seam and the window does not move.
    var s: f32 = 1.0;
    while (s <= 3.0) : (s += 0.05) {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200);
        const y = m.caption_h - 1;
        var x: i32 = l.drag_right;
        while (x < 1200) : (x += 1) {
            const hit = ncHitTest(m, l, x, y, 8, false, 0);
            try testing.expect(hit != .client);
        }
    }
}

test "a narrow window drops the title instead of painting it under the buttons" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        // Just wide enough for the four buttons and their insets, and no
        // more: there is nowhere for a title to go.
        const narrow = 4 * m.btn_paint + 4 * m.pad_sm + m.pad_md;
        const l = layout(m, narrow);
        try testing.expect(l.title.isEmpty());
        // The buttons themselves are still laid out correctly — a cramped
        // window loses its title, never its close button, and never the only
        // route to the menu.
        try testing.expectEqual(m.pad_sm, narrow - l.close.right);
        try testing.expectEqual(m.pad_sm, l.maximize.left - l.minimize.right);
        try testing.expectEqual(m.pad_md, l.minimize.left - l.overflow.right);
        try testing.expect(l.overflow.left >= 0);
    }
}

test "resizeBorder: honors the system metric, clamps, and never eats the band" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        try testing.expectEqual(@as(i32, 6), resizeBorder(m, 6));
        // A missing/absurd metric falls back rather than returning 0 — a
        // 0-thickness band means the window's top edge cannot be resized at
        // all, which is a far worse failure than a 4 DIP one.
        try testing.expect(resizeBorder(m, 0) >= 1);
        try testing.expect(resizeBorder(m, -100) >= 1);
        // Never more than half the band, or the caption stops being draggable.
        try testing.expect(resizeBorder(m, 10_000) <= @divTrunc(m.caption_h, 2));
        try testing.expect(resizeCorner(m, 10_000) <= @divTrunc(m.caption_h, 2));
        try testing.expect(resizeCorner(m, 4) >= resizeBorder(m, 4));
    }
}

test "command: the maximize button is a TOGGLE, the other two are not" {
    try testing.expectEqual(Command.maximize, command(.maximize, false));
    try testing.expectEqual(Command.restore, command(.maximize, true));
    // Minimize and close mean the same thing in both states — a "minimize"
    // that turned into a restore when zoomed would be a very confusing button.
    try testing.expectEqual(Command.minimize, command(.minimize, false));
    try testing.expectEqual(Command.minimize, command(.minimize, true));
    try testing.expectEqual(Command.close, command(.close, false));
    try testing.expectEqual(Command.close, command(.close, true));
    // ...and the "…" is the app's menu in either state — it is not a system
    // command at all, which is why it has its own `Command`.
    try testing.expectEqual(Command.menu, command(.overflow, false));
    try testing.expectEqual(Command.menu, command(.overflow, true));
}

test "layout is stable under width changes: only the anchor moves" {
    // The whole group is right-anchored, so widening the window must move
    // every button by exactly the delta and change nothing else. A layout
    // that recomputed gaps from the width would drift here.
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const a = layout(m, 800);
        const b = layout(m, 1000);
        try testing.expectEqual(@as(i32, 200), b.close.left - a.close.left);
        try testing.expectEqual(@as(i32, 200), b.minimize.left - a.minimize.left);
        try testing.expectEqual(@as(i32, 200), b.overflow.left - a.overflow.left);
        try testing.expectEqual(@as(i32, 200), b.drag_right - a.drag_right);
        try testing.expectEqual(a.title.left, b.title.left);
        try testing.expectEqual(@as(i32, 200), b.title.right - a.title.right);
    }
}

// -- T205: the merged row ----------------------------------------------------

test "with_tabs: the band IS the strip's band and the buttons sit on its baseline" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const ts = tab_strip.Metrics.init(s);
        // Not "about the same height" — the same number, from the same module.
        // Two heights that agree at 1.0 and drift at 1.25 is exactly the class
        // of defect the design system's §7 sweep exists to catch.
        try testing.expectEqual(ts.bar_h, m.caption_h);

        // The whole point of the merge: the caption buttons and the strip's
        // "+" paint on ONE horizontal frame. The user's report was two rows
        // that could not line up; a merged row that still missed by 2 px
        // would be the same complaint with less excuse.
        const l = layout(m, 1200);
        const plus = icon_button.targetBox(m.ib, ts.buttonHit(0));
        for ([_]Rect{ l.overflow, l.minimize, l.maximize, l.close }) |r| {
            try testing.expectEqual(plus.top, r.top);
            try testing.expectEqual(plus.bottom, r.bottom);
            try testing.expectEqual(m.btn_paint, r.height());
        }
        // And the band still clears the buttons below, on the spacing scale.
        try testing.expectEqual(ts.pad_sm, m.caption_h - l.close.bottom);
    }
}

test "with_tabs: standalone's horizontal arrangement is untouched" {
    // Merging is a VERTICAL change. Every x in the band — the right inset, the
    // trio's internal gaps, the group separation to the "…" — must be the same
    // number it was before, or the merge quietly became a redesign.
    for (scales) |s| {
        const a = layout(Metrics.init(s, .standalone), 1200);
        const b = layout(Metrics.init(s, .with_tabs), 1200);
        try testing.expectEqual(a.close.left, b.close.left);
        try testing.expectEqual(a.maximize.left, b.maximize.left);
        try testing.expectEqual(a.minimize.left, b.minimize.left);
        try testing.expectEqual(a.overflow.left, b.overflow.left);
        try testing.expectEqual(a.drag_right, b.drag_right);
    }
}

test "with_tabs: the tabs are the title, so no title is laid out" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        try testing.expect(layout(m, 1200).title.isEmpty());
        // ...and a standalone band of the same width still has one, so the
        // emptiness is the mode and not the width.
        try testing.expect(!layout(Metrics.init(s, .standalone), 1200).title.isEmpty());
    }
}

test "band_left is the seam: one group gap left of the button cluster" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const ts = tab_strip.Metrics.init(s);
        const ib = icon_button.Metrics.init(s);
        const l = layout(m, 1200);
        try testing.expectEqual(l.overflow.left - m.pad_md, l.band_left);

        // The contract with the strip: handed `band_left + strip_pad_r` as its
        // client width, a menu-less strip lands the "+"'s PAINTED right edge
        // exactly on the seam. If these two ever disagree the "+" either
        // overlaps the "…" or floats short of it — and both painters fill the
        // same background, so nothing on screen would say which.
        const strip_w = l.band_left + ts.strip_pad_r;
        var out: [4]tab_strip.Rect = undefined;
        const prefer = [_]i32{ ts.min_tab_w, ts.min_tab_w };
        const strip = tab_strip.layout(ts, strip_w, false, &prefer, &out);
        const plus_paint = icon_button.targetBox(ib, strip.new_tab);
        try testing.expect(plus_paint.right <= l.band_left);

        // ...and the "+"'s own painted LIMIT — the furthest right the strip
        // would ever put it — lands exactly ON the seam. Stated against
        // `runWidth`, which is the public form of that limit, rather than
        // against some particular set of tabs: a full run still ends one
        // `tab_gap` short (the last tab gives that gap up), so a layout with
        // wide tabs would measure 4 DIP shy and say nothing about the rule.
        try testing.expectEqual(
            l.band_left,
            tab_strip.runWidth(ts, strip_w, false) + ts.group_gap + ts.strip_pad_l + ts.btn_paint,
        );
    }
}

test "with_tabs: the strip's own controls answer .client, the caption's do not" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const l = layout(m, 1200);
        const y = m.caption_h - 1; // below any resize edge
        const frame: i32 = 8;
        const client_right = l.band_left; // strip filled its whole half

        // A tab, and the "+" beside it, are the strip's business.
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, 10, y, frame, false, client_right));
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, l.band_left - 1, y, frame, false, client_right));
        // The empty middle still drags the window, which is what makes a
        // merged row usable at all.
        try testing.expectEqual(NcHit.caption, ncHitTest(m, l, l.band_left, y, frame, false, client_right));
        // And the caption's own four are unchanged.
        try testing.expectEqual(NcHit.overflow, ncHitTest(m, l, l.overflow.left + 1, y, frame, false, client_right));
        try testing.expectEqual(NcHit.close, ncHitTest(m, l, l.close.left + 1, y, frame, false, client_right));
    }
}

test "a stale client_right can never swallow a caption button" {
    // `client_right` comes from the last paint, so a window that resized
    // between a paint and a click can present one that is far too wide. The
    // close button must still close: it is clamped to the seam.
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const l = layout(m, 1200);
        const y = m.caption_h - 1;
        try testing.expectEqual(NcHit.close, ncHitTest(m, l, l.close.left + 1, y, 8, false, 100_000));
        try testing.expectEqual(NcHit.overflow, ncHitTest(m, l, l.overflow.left + 1, y, 8, false, 100_000));
    }
}

test "the resize edge still wins over a tab" {
    // A tab reaching the window's top row must not make the top border
    // un-grabbable — the same ordering rule the caption buttons obey, and the
    // one a merged row is most likely to break.
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const l = layout(m, 1200);
        const frame: i32 = 8;
        try testing.expectEqual(NcHit.top, ncHitTest(m, l, 600, 0, frame, false, l.band_left));
        try testing.expectEqual(NcHit.top_left, ncHitTest(m, l, 0, 0, frame, false, l.band_left));
        // Maximized there is no resize edge, so the same point is the strip's.
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, 600, 0, frame, true, l.band_left));
    }
}
