//! Pure geometry for the win32 caption bar (T254, restyled native by T496).
//! No OS imports, so these unit tests run in every app-runtime lane (the
//! `split_geometry.zig` / `tab_strip_layout.zig` pattern). The painting half
//! is `paintCaption` in Window.zig and the hit tests are `WM_NCHITTEST` +
//! `handleCaptionClick`, which consume the same rects — the one rule that
//! keeps what you see and what you can click from drifting apart.
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
//! and the one T205 (tabs inside the titlebar) needed next.
//!
//! ## The system trio is NATIVE Windows 11, not app chrome (T496)
//!
//! T254 originally painted minimize/maximize/close as the same 28 DIP rounded
//! square as the strip's "+" and "≡", reasoning that Windows' 46x32 slabs
//! would "put two button vocabularies one row apart in the same window." The
//! user saw both and overrode it (2026-08-05): *"the minimize/restore/close
//! buttons at the top right do not match the windows 11 look and feel. This
//! makes the app seem off. They should match the windows design language."*
//!
//! So the trio now speaks Windows' own vocabulary, the same split Edge and
//! Explorer ship — THEIR controls get small rounded hovers, the system trio
//! is native slabs:
//!
//!   * **46 DIP wide, full band height, flush to the window's top and right
//!     edges, zero gaps between them.** The Fitts-law corner is now painted
//!     close, not merely hit-tested close.
//!   * **Rectangular hover/pressed fills covering the whole slab** — square
//!     corners, no inset. Close hovers Windows' red (#C42B1C, from the
//!     palette's `danger`), minimize/maximize shade the bar color.
//!   * **The standalone band is 32 DIP** — the native Win11 caption height —
//!     not a number derived from the app's own button square.
//!
//! This is a NAMED exception to the design system's 28-square / 4-DIP-gap
//! rules (docs/design/win32-design-system.md records it): the trio belongs to
//! the OS, so it is drawn to the OS's ruler. The app's own "…" button stays
//! the shared 28 DIP rounded square — it is ours, and that split is itself
//! the native pattern.
//!
//! ## The tab run shares the band (T205)
//!
//! `Mode.with_tabs` is the merged row: tabs, "+", then the drag gap, then the
//! "…" and the system trio, all on ONE row — what Windows Terminal, Edge and
//! Explorer do. The band is the STRIP's height (`tab_strip_layout.bar_h`) and
//! the system slabs span all of it, exactly as Windows Terminal's do. The "…"
//! keeps sitting on the strip's own button baseline so it lines up with the
//! "+" and the tab close "×" (T204's one-frame rule); the slabs need no
//! baseline — they ARE the band.
//!
//! `band_left` is the seam: the strip paints `[0, band_left)`, the caption
//! paints `[band_left, client_w)`, and the "+"'s painted right edge lands
//! exactly on it. The caption's own arrangement — right-anchored, close
//! outermost, "…" one group-gap inboard — is IDENTICAL in both modes.

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
pub const Button = enum { pill, overflow, minimize, maximize, close };

/// The remote connection pill's painted size (T367), or all-zero when this
/// window has no pill to show — a local window has no machine to be connected
/// to, so most windows pass `.{}` and nothing about the band changes.
///
/// A size rather than a rect: the caption owns WHERE its cluster sits, and the
/// pill owns how big it needs to be (its width follows a GDI-measured label
/// this module never sees, exactly like the tab run's "+"). Passing the two
/// numbers in keeps `remote_pill` out of this module's imports, so neither can
/// drag the other into a cycle.
pub const Pill = struct {
    w: i32 = 0,
    h: i32 = 0,
    /// Is the pill a BUTTON right now? It only is while the link is down (see
    /// `remote_pill.isAction`), and the difference is not cosmetic: a quiet
    /// status chip must stay part of the DRAG region, or a window whose
    /// titlebar is mostly tab strip grows a dead patch you cannot pick it up
    /// by. Carried with the size so one struct decides where a click goes.
    interactive: bool = false,

    pub fn isEmpty(self: Pill) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

/// Does the band hold the tab run as well (T205)?
///
/// `standalone` is a window showing one tab (or none): no strip exists, so the
/// band is its own 32 DIP row with the window title in it. `with_tabs` is the
/// merged row.
pub const Mode = enum { standalone, with_tabs };

/// Every DIP constant the caption is built from, resolved to physical pixels
/// for one DPI scale.
pub const Metrics = struct {
    /// Which band this is. Carried so `layout` can drop the title without the
    /// caller having to remember to, and so a `Metrics` and the `Layout` built
    /// from it can never describe two different rows.
    mode: Mode,
    /// Caption band height: the native Windows 11 caption height (32 DIP)
    /// standalone; the tab strip's own `bar_h` (40 DIP) when the run shares
    /// it. The system slabs span the full height either way (T496) — the
    /// band is not sized from the app's button square anymore, because the
    /// controls that own it are the OS's, drawn to the OS's ruler.
    caption_h: i32,
    /// Top of the app's own "…" button's PAINTED square, band-local. The
    /// system trio ignores it — the slabs run the band's full height.
    ///
    /// Standalone it centers the shared square in the native band. Merged it
    /// is whatever y the strip's own "+" paints at — asked of
    /// `tab_strip_layout` rather than restated, since the strip's buttons sit
    /// in the TABS' band (`tab_top_pad`..`bar_h`) and not in the full bar, a
    /// deliberate asymmetry that a local `(h - 28)/2` would quietly undo.
    btn_top: i32,
    /// The 4 DIP step, kept for callers that space AGAINST the caption.
    pad_sm: i32,
    /// The 8 DIP step, for separating GROUPS: the title text from the button
    /// cluster, and the app's "…" from the system trio.
    pad_md: i32,
    /// The PAINTED square of the app's own "…" — `icon_button.Metrics.target`.
    btn_paint: i32,
    /// How far the "…"'s HIT box grows past its painted square per side.
    btn_pad: i32,
    /// Width of one native system slab: 46 DIP, Windows' own caption button
    /// width (T496). The slab's height is `caption_h`.
    cap_btn_w: i32,
    /// The shared chrome button metrics themselves, carried rather than
    /// copied: the painter needs them for the "…"'s glyph and fill, and a
    /// caption that drew from a second `icon_button.Metrics.init(scale)`
    /// could disagree with the square this module laid out.
    ib: icon_button.Metrics,
    /// Top of a PINNED window title's text band in the merged row (T265):
    /// the strip's `tab_top_pad`, so the title `DT_VCENTER`s in the same
    /// vertical band a tab's label does and the two read as one row of text.
    /// 0 standalone, where the title centers in the whole band.
    merged_title_top: i32,
    /// Narrowest gap a pinned title may paint into (T265): the strip's own
    /// `min_tab_w`. Below the width of the narrowest legible tab, an
    /// ellipsized title is noise that jitters as tabs resize — the title
    /// drops instead, exactly as a too-narrow standalone band drops its.
    merged_title_min_w: i32,

    pub fn init(scale: f32, mode: Mode) Metrics {
        // Not re-derived: the "…" is the shared chrome square, so it has to
        // BE the shared square.
        const ib = icon_button.Metrics.init(scale);
        const sm = px(4.0, scale);
        // The strip's band and its button baseline, asked for rather than
        // restated. In `standalone` nothing here is used — but computing it
        // unconditionally keeps the two branches to one expression each.
        const ts = tab_strip.Metrics.init(scale);
        const cap_h = switch (mode) {
            .standalone => px(32.0, scale),
            .with_tabs => ts.bar_h,
        };
        return .{
            .mode = mode,
            .caption_h = cap_h,
            .btn_top = switch (mode) {
                .standalone => @divTrunc(cap_h - ib.target, 2),
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
            .cap_btn_w = px(46.0, scale),
            .ib = ib,
            .merged_title_top = switch (mode) {
                .standalone => 0,
                .with_tabs => ts.tab_top_pad,
            },
            .merged_title_min_w = ts.min_tab_w,
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
    /// The remote connection pill (T367), one `pad_md` left of the "…" and
    /// sharing its vertical center. Empty when the window has none — which is
    /// every local window, i.e. almost all of them.
    pill: Rect,
    /// Whether that pill is currently a button (see `Pill.interactive`). False
    /// whenever `pill` is empty.
    pill_interactive: bool,
    /// The "…" window-menu button (T234). Left of `minimize`, separated from
    /// the system trio by `pad_md`: it is a different GROUP of controls (ours
    /// vs the OS's), and since T496 the two groups even speak different
    /// visual languages — the "…" is the app's rounded square, the trio is
    /// native slabs — so the separation is what keeps the seam readable.
    overflow: Rect,
    /// Native slab: full band height, flush against `maximize`.
    minimize: Rect,
    /// Native slab: full band height, between `minimize` and `close`.
    maximize: Rect,
    /// Native slab: full band height, flush to the window's right edge — the
    /// top-right corner is painted close, not just hit-tested close.
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
    /// tests can reason about the window's right edge without every caller
    /// having to pass it in again and risk passing a different one than the
    /// layout used.
    client_w: i32,
};

/// Lay the caption band out for a client area `client_w` wide.
///
/// Right-anchored, in Windows' order, close outermost: a user who throws the
/// pointer at the top-right corner must land on close, which is the whole
/// reason that corner is where it is (Fitts' law, and Windows has trained it
/// for thirty years). Since T496 the corner even PAINTS close — the slabs are
/// flush to the edges, the way every native Win11 titlebar draws them.
pub fn layout(m: Metrics, client_w: i32, pill_size: Pill) Layout {
    // The system trio: three native slabs, full band height, zero gaps,
    // flush right. Built by stepping one slab width at a time from the
    // window's edge, so the three widths are the same integer by
    // construction and cannot round apart.
    const close: Rect = .{
        .left = client_w - m.cap_btn_w,
        .top = 0,
        .right = client_w,
        .bottom = m.caption_h,
    };
    const max: Rect = .{
        .left = close.left - m.cap_btn_w,
        .top = 0,
        .right = close.left,
        .bottom = m.caption_h,
    };
    const min: Rect = .{
        .left = max.left - m.cap_btn_w,
        .top = 0,
        .right = max.left,
        .bottom = m.caption_h,
    };

    // The app's own button: the shared 28 DIP square, one GROUP separation
    // left of the system trio, on the app's own button baseline.
    const top = m.btn_top;
    const bot = top + m.btn_paint;
    const over_r = min.left - m.pad_md;
    const over: Rect = .{ .left = over_r - m.btn_paint, .top = top, .right = over_r, .bottom = bot };

    // The pill (T367), one GROUP gap left of the "…" and centered on the SAME
    // vertical axis as the button's painted square, so the two read as one
    // cluster rather than two things that happen to be adjacent. It is dropped
    // rather than squeezed when the band cannot hold it and still leave the
    // strip (or a title) somewhere to live — the same rule the title follows,
    // for the same reason: a control clipped to a sliver is noise, not
    // information.
    const pill: Rect = if (pill_size.isEmpty()) .{} else blk: {
        const right = over.left - m.pad_md;
        const left = right - pill_size.w;
        if (left < m.pad_md) break :blk .{};
        const pill_top = top + @divTrunc(m.btn_paint - pill_size.h, 2);
        break :blk .{
            .left = left,
            .top = pill_top,
            .right = right,
            .bottom = pill_top + pill_size.h,
        };
    };

    // Everything left of the cluster is the cluster's leading edge: the pill
    // when there is one, the "…" otherwise. Stated once, because the drag
    // region, the title and the seam all measure from it.
    const cluster_left = if (pill.isEmpty()) over.left else pill.left;
    const pill_interactive = !pill.isEmpty() and pill_size.interactive;

    // The drag region ends where the leftmost CLICKABLE thing's hit box begins
    // — not where its paint begins. A hit box must never contribute to a
    // visible gap (design system §0 rule 2), but it is exactly what decides
    // where a click stops being a drag. The pill's hit box is its paint (it is
    // a capsule, not a 28 DIP square with slack around it), so an interactive
    // pill lands the two edges on the same x; a quiet one is not clickable at
    // all and stays inside the drag band, so you can still pick the window up
    // by it.
    const drag_right = if (pill_interactive) pill.left else over.left - m.btn_pad;

    // The title stops `md` short of the button group, because they are
    // different groups of controls. A band with no room for both drops the
    // title; painting it under the buttons is worse than not painting it.
    // In `.with_tabs` there is no title at all — the tab run has the space.
    const title_l = m.pad_md;
    const title_r = cluster_left - m.pad_md;
    const title: Rect = if (m.mode == .standalone and title_r > title_l)
        .{ .left = title_l, .top = 0, .right = title_r, .bottom = m.caption_h }
    else
        .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

    return .{
        .pill = pill,
        .pill_interactive = pill_interactive,
        .overflow = over,
        .minimize = min,
        .maximize = max,
        .close = close,
        .title = title,
        .drag_right = drag_right,
        .band_left = switch (m.mode) {
            .standalone => 0,
            .with_tabs => @max(cluster_left - m.pad_md, 0),
        },
        .client_w = client_w,
    };
}

/// Where a PINNED window title may draw in the merged row (T265).
///
/// The merged band deliberately lays out no `title` — tabs are the title, the
/// reference chrome (Windows Terminal, Edge, Explorer) shows none, and that
/// stays true for everyone who never pins one. But ghoztty documents the
/// window title as a first-class, pinnable thing (`+new-window --title`,
/// `+rename --title=`, Ctrl+Shift+R), and a pin the titlebar cannot show is a
/// shipped feature with no on-screen affordance. So the one band with room —
/// the empty drag gap between the strip's "+" and the caption's "…" — carries
/// the pinned title, and ONLY the pinned title: the fallback chain (tab/pane
/// titles) never paints here, so the common case still reads like the
/// reference.
///
/// `plus_paint_right` is the painted right edge of the strip's "+" — the
/// rightmost thing the strip laid out, which this module cannot derive itself
/// because the "+" travels with tab titles it never measures (the same reason
/// `ncHitTest` takes `client_right`). The title starts one GROUP gap
/// (`pad_md`) right of it and stops at the seam, whose own `pad_md` to the
/// "…" then keeps the title a group gap clear of the caption cluster — the
/// exact separation the standalone title keeps.
///
/// The gap is variable — it shrinks as tabs are added and can reach zero — so
/// below `merged_title_min_w` the title DROPS rather than ellipsizing into
/// jittering noise. Returns the empty rect then, and always in `.standalone`
/// (the band's own `title` already answers there).
///
/// The rect stays inside `[0, band_left)`: the STRIP's half of the row, which
/// is why the strip's painter draws it (the caption's blit starts at the seam
/// and could never show it). Vertically it is the tab band
/// (`merged_title_top`..`caption_h`), so a `DT_VCENTER` title shares the tab
/// labels' centerline.
pub fn mergedTitleRect(m: Metrics, l: Layout, plus_paint_right: i32) Rect {
    const empty: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (m.mode != .with_tabs) return empty;
    const left = plus_paint_right + m.pad_md;
    if (l.band_left - left < m.merged_title_min_w) return empty;
    return .{
        .left = left,
        .top = m.merged_title_top,
        .right = l.band_left,
        .bottom = m.caption_h,
    };
}

/// The HIT box for a caption button.
///
/// The three system slabs ARE their hit boxes: they already run the band's
/// full height, touch each other, and reach the window's right edge, exactly
/// as native Win11 caption buttons do — the paint and the click are one rect
/// by construction, and `close` owns the top-right corner because it is
/// painted there. The "…" keeps the app-button rule: its painted square grown
/// `btn_pad` per side horizontally and to the band's full height vertically
/// (a hit box may be bigger than its paint because it is invisible — design
/// system §0 rule 2).
///
/// On a restored window the top rows are the resize edge and `ncHitTest`
/// gives them to `HTTOP` before it ever asks about a button, exactly as a
/// stock frame does; maximized, there is no resize edge and the corner really
/// is close's.
pub fn hitBox(m: Metrics, l: Layout, b: Button) Rect {
    return switch (b) {
        .minimize => l.minimize,
        .maximize => l.maximize,
        .close => l.close,
        // The pill's hit box is its PAINT, grown only to the band's full height
        // the way the "…"'s is. It is not grown horizontally: unlike a 28 DIP
        // square in a wider slot, the capsule already extends to its own
        // padding, and a hit box reaching past it would start swallowing drags
        // from the empty band beside it.
        //
        // A pill that is not a button has NO hit box: there is nothing to
        // click, and an empty box is what puts it back in the drag region
        // instead of leaving a dead patch in the titlebar.
        .pill => if (!l.pill_interactive) .{} else .{
            .left = l.pill.left,
            .top = 0,
            .right = l.pill.right,
            .bottom = m.caption_h,
        },
        .overflow => .{
            .left = l.overflow.left - m.btn_pad,
            .top = 0,
            .right = l.overflow.right + m.btn_pad,
            .bottom = m.caption_h,
        },
    };
}

/// The system command a caption button stands for.
///
/// Kept here, as a pure mapping, rather than inline in the wndproc: it is the
/// one part of the click path that is decidable without a window, and it is
/// the part most likely to be wrong in a way nothing notices — a maximize
/// button that always sends `SC_MAXIMIZE` looks perfect until you click it on
/// an already-maximized window and nothing happens.
pub const Command = enum { minimize, maximize, restore, close, menu, reconnect };

pub fn command(b: Button, maximized: bool) Command {
    return switch (b) {
        // Not a `WM_SYSCOMMAND` at all — the caller opens the app's own menu.
        // It is in this enum anyway so that "what does this button do" has
        // exactly one answer, decided in the pure module with the rest.
        .overflow => .menu,
        // Likewise ours: the caller re-dials the window's machine. Whether the
        // pill is clickable AT ALL is `remote_pill.isAction`, which the caller
        // checks before it ever gets here.
        .pill => .reconnect,
        .minimize => .minimize,
        .maximize => if (maximized) .restore else .maximize,
        .close => .close,
    };
}

/// Which caption button, if any, is under a point in band-local coordinates.
///
/// Tested right-to-left so that even if a future layout let two boxes
/// overlap, the outer (destructive) button never silently swallows its
/// neighbour's clicks — `captionButtonHitBoxesNeverOverlap` is what keeps
/// that from being load-bearing.
pub fn hitTest(m: Metrics, l: Layout, x: i32, y: i32) ?Button {
    if (y < 0 or y >= m.caption_h) return null;
    if (hitBox(m, l, .close).containsPoint(x, y)) return .close;
    if (hitBox(m, l, .maximize).containsPoint(x, y)) return .maximize;
    if (hitBox(m, l, .minimize).containsPoint(x, y)) return .minimize;
    if (hitBox(m, l, .overflow).containsPoint(x, y)) return .overflow;
    if (hitBox(m, l, .pill).containsPoint(x, y)) return .pill;
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
/// resized from the top. (Native Win11 titlebars make the same trade: the
/// top few rows of the caption buttons are the resize edge when restored.)
/// The one exception is the TAB RUN (T266): between the corners, a tab owns
/// its full height and the top edge over it selects rather than resizes —
/// measured WT parity, see `ncHitTest`.
pub const NcHit = enum {
    top,
    top_left,
    top_right,
    /// The remote connection pill (T367). It gets its own code for the same
    /// reason the "…" borrows `HTSYSMENU`: the band's pixels are client but its
    /// mouse messages are non-client, so a control here only sees hover and
    /// click at all if the hit test names it.
    pill,
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
        // T266: between the corners, the frame stops where the strip's own
        // chrome begins. Measured against a live WindowsTerminal.exe 1.24
        // (2026-08-06, 120 dpi): WT's tab island answers HTCLIENT from the
        // window's very TOP row at a tab's x, so a WT tab owns every one of
        // its rows and the top resize edge lives only in the empty drag band
        // and the corners. Falling through here (instead of returning .top)
        // hands these rows to the strip check below, which is what makes a
        // click near a tab's top select the tab instead of resizing.
        if (x >= @min(client_right, l.band_left)) return .top;
    }

    // The strip's own controls, AFTER the corners (a tab at the window's edge
    // must not make the diagonal grab unreachable) and BEFORE the caption's,
    // since the two regions are disjoint by construction and asking in this
    // order means a stale `client_right` can never swallow the close button.
    // The top rows over the strip land here too (T266, above): the tab owns
    // its full height, the way WT's tabs do.
    if (x < @min(client_right, l.band_left)) return .client;

    if (hitTest(m, l, x, y)) |b| return switch (b) {
        .pill => .pill,
        .overflow => .overflow,
        .minimize => .minimize,
        .maximize => .maximize,
        .close => .close,
    };

    if (isDragRegion(m, l, x, y)) return .caption;
    // The slivers around the "…"'s hit box. Dragging from them is the only
    // sane answer: they are inside the caption band, they paint the caption
    // background, and treating them as client would put a terminal hit test
    // in the titlebar.
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

fn dipPx(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

test "the standalone band is the native 32 DIP caption height" {
    // Sized by the platform, not by the app's button square (T496). 36 DIP
    // (4 + 28 + 4) is what "the header doesn't feel native" measured as.
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        try testing.expectEqual(dipPx(32.0, s), m.caption_h);
        try testing.expectEqual(dipPx(46.0, s), m.cap_btn_w);
    }
}

test "the system trio is three native slabs: 46 DIP, full height, flush, no gaps" {
    // The native contract, as arithmetic. Every clause is something the user's
    // screenshot comparison showed us NOT doing: inset squares with gaps and
    // a corner that painted empty band.
    for (scales) |s| {
        for ([_]Mode{ .standalone, .with_tabs }) |mode| {
            const m = Metrics.init(s, mode);
            const l = layout(m, 1200, .{});
            for ([_]Rect{ l.minimize, l.maximize, l.close }) |r| {
                try testing.expectEqual(m.cap_btn_w, r.width());
                try testing.expectEqual(@as(i32, 0), r.top);
                try testing.expectEqual(m.caption_h, r.bottom);
            }
            // Flush right: the corner is PAINTED close.
            try testing.expectEqual(@as(i32, 1200), l.close.right);
            // Zero gaps: the slabs touch, by construction.
            try testing.expectEqual(l.close.left, l.maximize.right);
            try testing.expectEqual(l.maximize.left, l.minimize.right);
        }
    }
}

test "the app's own button keeps the shared square and a GROUP gap to the trio" {
    // The Edge/Explorer split: our control speaks the app's design system,
    // the OS's controls speak Windows'. The "…" is still the one 28 DIP
    // square, still `pad_md` clear of the trio, and never touches it.
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const ib = icon_button.Metrics.init(s);
        const l = layout(m, 1200, .{});
        try testing.expectEqual(ib.target, l.overflow.width());
        try testing.expectEqual(ib.target, l.overflow.height());
        try testing.expectEqual(m.pad_md, l.minimize.left - l.overflow.right);
        // Centered in the native band (the band is the OS's number now, so
        // the square centers in it rather than dictating it).
        try testing.expectEqual(
            @divTrunc(m.caption_h - m.btn_paint, 2),
            l.overflow.top,
        );
        // Title to the button group: a GROUP separation, so `md`.
        try testing.expectEqual(m.pad_md, l.overflow.left - l.title.right);
        try testing.expectEqual(m.pad_md, l.title.left);
    }
}

test "caption button hit boxes never overlap each other" {
    // The slabs are their own hit boxes and touch exactly; the "…"'s grown
    // box must stop short of the minimize slab. Swept finely, not at four
    // hand-picked scales.
    var s: f32 = 1.0;
    while (s <= 3.0) : (s += 0.05) {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, .{});
        const hover = hitBox(m, l, .overflow);
        const hmin = hitBox(m, l, .minimize);
        const hmax = hitBox(m, l, .maximize);
        const hclose = hitBox(m, l, .close);
        try testing.expect(hover.right <= hmin.left);
        try testing.expect(hmin.right <= hmax.left);
        try testing.expect(hmax.right <= hclose.left);
        // Each box still contains the whole rect it stands for, or the
        // "forgiving target" has been forgiving in the wrong direction.
        try testing.expect(hover.left <= l.overflow.left and hover.right >= l.overflow.right);
        try testing.expect(hmin.left <= l.minimize.left and hmin.right >= l.minimize.right);
        try testing.expect(hmax.left <= l.maximize.left and hmax.right >= l.maximize.right);
        try testing.expect(hclose.left <= l.close.left and hclose.right >= l.close.right);
    }
}

test "hitTest finds each button and nothing outside them" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, .{});
        const cy = @divTrunc(m.caption_h, 2);
        try testing.expectEqual(Button.overflow, hitTest(m, l, l.overflow.left + 1, cy).?);
        try testing.expectEqual(Button.minimize, hitTest(m, l, l.minimize.left + 1, cy).?);
        try testing.expectEqual(Button.maximize, hitTest(m, l, l.maximize.left + 1, cy).?);
        try testing.expectEqual(Button.close, hitTest(m, l, l.close.left + 1, cy).?);
        // The title area is not a button.
        try testing.expect(hitTest(m, l, l.title.left + 1, cy) == null);
        try testing.expect(hitTest(m, l, 0, cy) == null);
        // Below the band is not the caption's business at all.
        try testing.expect(hitTest(m, l, l.close.left + 1, m.caption_h) == null);
        try testing.expect(hitTest(m, l, l.close.left + 1, -1) == null);
    }
}

test "the top-right corner lands on close, and is painted close" {
    // Fitts' law, and thirty years of Windows muscle memory: throwing the
    // pointer into the corner must close the window. Since T496 the slab is
    // flush to the edges, so the corner pixel is both CLICKABLE close and
    // PAINTED close — no hit-box-vs-paint gap left to reason about.
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, .{});
        try testing.expectEqual(Button.close, hitTest(m, l, 1199, 0).?);
        try testing.expectEqual(Button.close, hitTest(m, l, 1199, m.caption_h - 1).?);
        try testing.expect(l.close.containsPoint(1199, 0));
        // And the band's full height belongs to the buttons vertically, so a
        // click just under a glyph is not a lost click either.
        try testing.expectEqual(Button.minimize, hitTest(m, l, l.minimize.left + 1, 0).?);
        try testing.expectEqual(Button.minimize, hitTest(m, l, l.minimize.left + 1, m.caption_h - 1).?);
    }
}

test "drag region ends at the leftmost button's hit box, not its paint" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, .{});
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
        const l = layout(m, 1200, .{});
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

test "ncHitTest: over a TAB there is NO top resize edge - the tab owns its full height (T266)" {
    // Measured against a live WindowsTerminal.exe 1.24 (2026-08-06, 120 dpi):
    // WT's tab ISLAND answers HTCLIENT from the window's very top row at a
    // tab's x — a WT tab owns every one of its rows, and the top resize edge
    // lives only in the empty drag band (where WT's drag-bar child answers
    // HTTOP) and the corners. An earlier cut of this test pinned the opposite
    // ("the frame is never thinned over a tab") from a parent-window-only
    // probe: WM_NCHITTEST sent to the top-level answers HTTOP there, but a
    // user's mouse never reaches the top-level over a tab — the island child
    // covers it from row 0 and answers for itself. Probe the window the mouse
    // actually lands on, not the parent's model of it.
    const frames = [_]i32{ 8, 9, 11, 13 }; // GetSystemMetricsForDpi sums measured at 96/120/144/192 dpi
    for (scales, frames) |s, frame| {
        const m = Metrics.init(s, .with_tabs);
        const l = layout(m, 1200, .{});
        const border = resizeBorder(m, frame);
        // A real system frame never hits the half-band clamp.
        try testing.expectEqual(frame, border);
        // A mid-tab x: right of the corner grab, inside the tab run.
        const tab_x: i32 = @intFromFloat(@round(200.0 * s));
        const client_right: i32 = @intFromFloat(@round(400.0 * s));
        try testing.expect(tab_x > resizeCorner(m, frame));
        try testing.expect(tab_x < client_right);
        // Over the tab, every row from the very top belongs to the tab.
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, tab_x, 0, frame, false, client_right));
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, tab_x, border - 1, frame, false, client_right));
        // The corners keep the full diagonal grab even over the strip.
        try testing.expectEqual(NcHit.top_left, ncHitTest(m, l, 0, border - 1, frame, false, client_right));
        // The empty band right of the strip keeps the full frame...
        const empty_x = l.band_left - 1;
        try testing.expect(empty_x >= client_right);
        try testing.expectEqual(NcHit.top, ncHitTest(m, l, empty_x, border - 1, frame, false, client_right));
        // ...and one row below it the caption drags: the boundary sits
        // exactly on the metric there.
        try testing.expectEqual(NcHit.caption, ncHitTest(m, l, empty_x, border, frame, false, client_right));
        // Maximized there is no edge anywhere - the top row over a tab selects.
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, tab_x, 0, frame, true, client_right));
    }
}

test "ncHitTest: the band right of the drag region never falls to client" {
    // The slivers around the "…"'s hit box are inside the caption and paint
    // the caption background. Answering `client` there would put a terminal
    // hit test in the titlebar — invisible until a user drags from a
    // one-pixel seam and the window does not move.
    var s: f32 = 1.0;
    while (s <= 3.0) : (s += 0.05) {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, .{});
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
        // Just wide enough for the three slabs, the "…" and its insets, and
        // no more: there is nowhere for a title to go.
        const narrow = 3 * m.cap_btn_w + m.btn_paint + 3 * m.pad_md;
        const l = layout(m, narrow, .{});
        try testing.expect(l.title.isEmpty());
        // The buttons themselves are still laid out correctly — a cramped
        // window loses its title, never its close button, and never the only
        // route to the menu.
        try testing.expectEqual(narrow, l.close.right);
        try testing.expectEqual(l.maximize.left, l.minimize.right);
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
        const a = layout(m, 800, .{});
        const b = layout(m, 1000, .{});
        try testing.expectEqual(@as(i32, 200), b.close.left - a.close.left);
        try testing.expectEqual(@as(i32, 200), b.minimize.left - a.minimize.left);
        try testing.expectEqual(@as(i32, 200), b.overflow.left - a.overflow.left);
        try testing.expectEqual(@as(i32, 200), b.drag_right - a.drag_right);
        try testing.expectEqual(a.title.left, b.title.left);
        try testing.expectEqual(@as(i32, 200), b.title.right - a.title.right);
    }
}

// -- T205: the merged row ----------------------------------------------------

test "with_tabs: the band IS the strip's band, slabs span it, '…' sits on its baseline" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const ts = tab_strip.Metrics.init(s);
        // Not "about the same height" — the same number, from the same module.
        try testing.expectEqual(ts.bar_h, m.caption_h);

        const l = layout(m, 1200, .{});
        // The system slabs span the merged band's full height, exactly what
        // Windows Terminal's caption buttons do in ITS tab row.
        for ([_]Rect{ l.minimize, l.maximize, l.close }) |r| {
            try testing.expectEqual(@as(i32, 0), r.top);
            try testing.expectEqual(ts.bar_h, r.bottom);
        }
        // The "…" is app chrome, so it stays on the strip's own button
        // baseline — the frame the "+" and the tab close "×" already share
        // (T204). That is what keeps the app's buttons aligned across the
        // seam while the OS's slabs ignore the baseline entirely.
        const plus = icon_button.targetBox(m.ib, ts.buttonHit(0));
        try testing.expectEqual(plus.top, l.overflow.top);
        try testing.expectEqual(plus.bottom, l.overflow.bottom);
    }
}

test "with_tabs: standalone's horizontal arrangement is untouched" {
    // Merging is a VERTICAL change. Every x in the band — the right edge, the
    // trio's widths, the group separation to the "…" — must be the same
    // number it was standalone, or the merge quietly became a redesign.
    for (scales) |s| {
        const a = layout(Metrics.init(s, .standalone), 1200, .{});
        const b = layout(Metrics.init(s, .with_tabs), 1200, .{});
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
        try testing.expect(layout(m, 1200, .{}).title.isEmpty());
        // ...and a standalone band of the same width still has one, so the
        // emptiness is the mode and not the width.
        try testing.expect(!layout(Metrics.init(s, .standalone), 1200, .{}).title.isEmpty());
    }
}

test "band_left is the seam: one group gap left of the button cluster" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const ts = tab_strip.Metrics.init(s);
        const ib = icon_button.Metrics.init(s);
        const l = layout(m, 1200, .{});
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
        const l = layout(m, 1200, .{});
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
        const l = layout(m, 1200, .{});
        const y = m.caption_h - 1;
        try testing.expectEqual(NcHit.close, ncHitTest(m, l, l.close.left + 1, y, 8, false, 100_000));
        try testing.expectEqual(NcHit.overflow, ncHitTest(m, l, l.overflow.left + 1, y, 8, false, 100_000));
    }
}

// -- T265: the pinned title in the merged row --------------------------------

test "mergedTitleRect: one group gap off the '+', ending at the seam, in the tab band" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const ts = tab_strip.Metrics.init(s);
        const l = layout(m, 1200, .{});
        // A "+" well left of the seam: a short run, lots of drag band.
        const plus_right: i32 = dipPx(200.0, s);
        const r = mergedTitleRect(m, l, plus_right);
        try testing.expect(!r.isEmpty());
        // One GROUP gap off the "+"'s painted edge...
        try testing.expectEqual(plus_right + m.pad_md, r.left);
        // ...to the seam, whose own pad_md to the "…" keeps the title a group
        // gap clear of the caption cluster — the standalone separation.
        try testing.expectEqual(l.band_left, r.right);
        try testing.expectEqual(m.pad_md, l.overflow.left - r.right);
        // Vertically the TAB band, so DT_VCENTER shares the tab labels'
        // centerline rather than the full bar's.
        try testing.expectEqual(ts.tab_top_pad, r.top);
        try testing.expectEqual(m.caption_h, r.bottom);
    }
}

test "mergedTitleRect: drops below the minimum width instead of ellipsizing to noise" {
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const ts = tab_strip.Metrics.init(s);
        const l = layout(m, 1200, .{});
        try testing.expectEqual(ts.min_tab_w, m.merged_title_min_w);
        // Exactly the minimum gap: paints.
        const at_min = l.band_left - m.pad_md - m.merged_title_min_w;
        try testing.expect(!mergedTitleRect(m, l, at_min).isEmpty());
        try testing.expectEqual(
            m.merged_title_min_w,
            mergedTitleRect(m, l, at_min).width(),
        );
        // One pixel narrower: drops.
        try testing.expect(mergedTitleRect(m, l, at_min + 1).isEmpty());
        // A "+" at (or absurdly past) the seam: drops, never a negative rect.
        try testing.expect(mergedTitleRect(m, l, l.band_left).isEmpty());
        try testing.expect(mergedTitleRect(m, l, l.band_left + 500).isEmpty());
    }
}

test "mergedTitleRect: standalone answers empty - the band's own title already exists" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, .{});
        try testing.expect(mergedTitleRect(m, l, dipPx(200.0, s)).isEmpty());
        // ...and the standalone title rect is still there, so nothing painted
        // twice and nothing painted nowhere.
        try testing.expect(!l.title.isEmpty());
    }
}

test "mergedTitleRect: stays inside the strip's half of the row" {
    // The strip blits [0, band_left); a title past the seam would be cut off
    // (or repainted over) by the caption's own blit. Swept, not spot-checked.
    var s: f32 = 1.0;
    while (s <= 3.0) : (s += 0.05) {
        const m = Metrics.init(s, .with_tabs);
        const l = layout(m, 1200, .{});
        var plus: i32 = 0;
        while (plus < 1200) : (plus += 37) {
            const r = mergedTitleRect(m, l, plus);
            if (r.isEmpty()) continue;
            try testing.expect(r.left >= 0);
            try testing.expect(r.right <= l.band_left);
            try testing.expect(r.width() >= m.merged_title_min_w);
        }
    }
}

test "over the strip the TAB wins the top rows; the corners and caption keep the edge" {
    // Until T266 this test pinned the opposite: .top at a strip x, on the
    // theory that a tab must never make the top border un-grabbable. The
    // measured reference (WT 1.24, see the T266 test above) says tabs own
    // their full height; the resize edge survives in the corners, the empty
    // band, and over the caption's own controls.
    for (scales) |s| {
        const m = Metrics.init(s, .with_tabs);
        const l = layout(m, 1200, .{});
        const frame: i32 = 8;
        // A strip x with the strip full to the seam: the tab's row, not the frame's.
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, 600, 0, frame, false, l.band_left));
        // The corner grab still outranks the strip.
        try testing.expectEqual(NcHit.top_left, ncHitTest(m, l, 0, 0, frame, false, l.band_left));
        // Over the caption's own controls the top rows still resize, exactly
        // as a stock Win11 frame treats its caption buttons when restored.
        try testing.expectEqual(NcHit.top, ncHitTest(m, l, l.close.left + 1, 0, frame, false, l.band_left));
        // Maximized there is no resize edge, so the same point is the strip's.
        try testing.expectEqual(NcHit.client, ncHitTest(m, l, 600, 0, frame, true, l.band_left));
    }
}

// ---------------------------------------------------------------------
// The remote connection pill (T367)
// ---------------------------------------------------------------------

/// A representative pill size for a scale: the same shape `remote_pill` builds,
/// stated here as plain numbers so this module's tests stay free of it.
fn samplePill(s: f32) Pill {
    return .{
        .w = @intFromFloat(@round(120.0 * s)),
        .h = @intFromFloat(@round(20.0 * s)),
        .interactive = true,
    };
}

/// The same pill in its quiet (non-button) state.
fn sampleQuietPill(s: f32) Pill {
    var p = samplePill(s);
    p.interactive = false;
    return p;
}

test "no pill is the default, and it changes nothing about the band" {
    for (scales) |s| {
        for ([_]Mode{ .standalone, .with_tabs }) |mode| {
            const m = Metrics.init(s, mode);
            const l = layout(m, 1200, .{});
            try testing.expect(l.pill.isEmpty());
            try testing.expect(!l.pill_interactive);
            try testing.expect(hitBox(m, l, .pill).isEmpty());
            // Left of the "…"'s HIT box (which reaches `btn_pad` past its
            // paint) there is nothing to hit at all — no pill, no sliver.
            try testing.expect(hitTest(
                m,
                l,
                l.overflow.left - m.btn_pad - 1,
                @divTrunc(m.caption_h, 2),
            ) == null);
            // Byte-for-byte the layout the caption had before pills existed.
            const zero: Pill = .{ .w = 0, .h = 0 };
            try testing.expectEqual(l, layout(m, 1200, zero));
        }
    }
}

test "the pill sits one GROUP gap left of the button, on the button's center" {
    for (scales) |s| {
        for ([_]Mode{ .standalone, .with_tabs }) |mode| {
            const m = Metrics.init(s, mode);
            const p = samplePill(s);
            const l = layout(m, 1200, p);

            try testing.expect(!l.pill.isEmpty());
            try testing.expectEqual(p.w, l.pill.width());
            try testing.expectEqual(p.h, l.pill.height());
            // §1: a GROUP separation from the "…", never a smaller fudge.
            try testing.expectEqual(m.pad_md, l.overflow.left - l.pill.right);
            // Same vertical center as the button's painted square, to the pixel
            // — which is what makes the two read as one cluster.
            const btn_cy2 = l.overflow.top + l.overflow.bottom;
            try testing.expectEqual(btn_cy2, l.pill.top + l.pill.bottom);
            // §0 rule 2: clear of the band's own edges.
            try testing.expect(l.pill.top >= m.pad_sm);
            try testing.expect(m.caption_h - l.pill.bottom >= m.pad_sm);
        }
    }
}

test "the pill takes its space from the title and the seam, not from the buttons" {
    for (scales) |s| {
        const p = samplePill(s);

        // Standalone: the title stops a group gap short of the PILL now.
        const ms = Metrics.init(s, .standalone);
        const without = layout(ms, 1200, .{});
        const with = layout(ms, 1200, p);
        try testing.expectEqual(without.overflow, with.overflow);
        try testing.expectEqual(without.minimize, with.minimize);
        try testing.expectEqual(without.maximize, with.maximize);
        try testing.expectEqual(without.close, with.close);
        try testing.expectEqual(with.pill.left - ms.pad_md, with.title.right);
        try testing.expect(with.title.right < without.title.right);

        // Merged: the seam moves left with the pill, so the strip gets a
        // narrower run rather than the two painters overlapping.
        const mm = Metrics.init(s, .with_tabs);
        const mwithout = layout(mm, 1200, .{});
        const mwith = layout(mm, 1200, p);
        try testing.expectEqual(mwith.pill.left - mm.pad_md, mwith.band_left);
        try testing.expect(mwith.band_left < mwithout.band_left);
        try testing.expect(mwith.pill.left >= mwith.band_left);
    }
}

test "the drag region stops at a CLICKABLE pill, so dragging never fires it" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, samplePill(s));
        const cy = @divTrunc(m.caption_h, 2);
        try testing.expectEqual(l.pill.left, l.drag_right);
        try testing.expect(!isDragRegion(m, l, l.pill.left, cy));
        try testing.expect(isDragRegion(m, l, l.pill.left - 1, cy));
    }
}

test "a quiet pill is still titlebar you can pick the window up by" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, sampleQuietPill(s));
        const cy = @divTrunc(m.caption_h, 2);
        const frame: i32 = 8;

        // Same rect — the pill is drawn either way; only its click behavior
        // differs, which is what keeps the band from reflowing when the link
        // drops and comes back.
        try testing.expectEqual(layout(m, 1200, samplePill(s)).pill, l.pill);
        try testing.expect(!l.pill_interactive);

        try testing.expect(hitBox(m, l, .pill).isEmpty());
        try testing.expect(hitTest(m, l, l.pill.left + 1, cy) == null);
        try testing.expect(isDragRegion(m, l, l.pill.left + 1, cy));
        try testing.expectEqual(
            NcHit.caption,
            ncHitTest(m, l, l.pill.left + 1, cy, frame, true, 0),
        );
    }
}

test "the pill is hit over its whole capsule and the band's full height" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, samplePill(s));
        const cy = @divTrunc(m.caption_h, 2);

        try testing.expectEqual(Button.pill, hitTest(m, l, l.pill.left, cy).?);
        try testing.expectEqual(Button.pill, hitTest(m, l, l.pill.right - 1, cy).?);
        // The band's full height: a click just above the capsule is still the
        // pill's, the same forgiveness the "…" gets.
        try testing.expectEqual(Button.pill, hitTest(m, l, l.pill.left, 0).?);
        try testing.expectEqual(Button.pill, hitTest(m, l, l.pill.left, m.caption_h - 1).?);
        // And it never reaches past its own paint into the drag band.
        try testing.expect(hitTest(m, l, l.pill.left - 1, cy) == null);
        // Its neighbour still wins its own box.
        try testing.expectEqual(Button.overflow, hitTest(m, l, l.overflow.left, cy).?);
    }
}

test "the pill's hit box never overlaps the buttons'" {
    for (scales) |s| {
        for ([_]Mode{ .standalone, .with_tabs }) |mode| {
            const m = Metrics.init(s, mode);
            const l = layout(m, 1200, samplePill(s));
            const boxes = [_]Rect{
                hitBox(m, l, .pill),
                hitBox(m, l, .overflow),
                hitBox(m, l, .minimize),
                hitBox(m, l, .maximize),
                hitBox(m, l, .close),
            };
            for (boxes, 0..) |a, i| {
                for (boxes[i + 1 ..]) |b| {
                    try testing.expect(a.right <= b.left or b.right <= a.left);
                }
            }
        }
    }
}

test "WM_NCHITTEST names the pill, and the resize edge still outranks it" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        const l = layout(m, 1200, samplePill(s));
        const frame: i32 = 8;
        const cy = @divTrunc(m.caption_h, 2);
        try testing.expectEqual(NcHit.pill, ncHitTest(m, l, l.pill.left + 1, cy, frame, false, 0));
        // Restored, the top rows are the frame's — the same trade the caption
        // buttons make, so the top edge stays grabbable across the whole band.
        try testing.expectEqual(NcHit.top, ncHitTest(m, l, l.pill.left + 1, 0, frame, false, 0));
        // Maximized there is no frame, so the pill owns its top row.
        try testing.expectEqual(NcHit.pill, ncHitTest(m, l, l.pill.left + 1, 0, frame, true, 0));
    }
}

test "a band too narrow for the pill drops it rather than clipping it" {
    for (scales) |s| {
        const m = Metrics.init(s, .standalone);
        // The buttons alone nearly fill the band: whatever is left cannot hold
        // a 120 DIP capsule.
        const narrow = m.cap_btn_w * 3 + m.btn_paint + m.pad_md * 2 + 4;
        const l = layout(m, narrow, samplePill(s));
        try testing.expect(l.pill.isEmpty());
        // ...and the band degrades exactly as it did before pills existed.
        try testing.expectEqual(layout(m, narrow, .{}), l);
    }
}

test "command: the pill re-dials; nothing else in the caption does" {
    try testing.expectEqual(Command.reconnect, command(.pill, false));
    try testing.expectEqual(Command.reconnect, command(.pill, true));
}
