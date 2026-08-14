//! Sticky pane-banner overlay (T35/T91). Windows analog of the Mac
//! `SurfacePaneBanner`: a card rendered above the terminal content of a
//! pane that persists (survives scrolling, screen clears, content updates)
//! until changed or cleared.
//!
//! Like DimOverlay/Scrollbar, the banner is a WS_EX_LAYERED popup owned by
//! its surface HWND — DWM composites it above the surface's OpenGL
//! content, which a plain child window cannot reliably do. Unlike the dim
//! overlay it is NOT click-through: `[text](url)` links are clickable
//! (hand cursor + ShellExecuteW), a multi-line banner collapses/expands on
//! click, and a click on a single-line banner focuses the pane underneath.
//!
//! The window covers the band the layout reserves above the terminal
//! (T101) and is fully OPAQUE (T131): it paints the pane background, then
//! the floating glass card inside it (`banner_card.zig`, the port of Mac's
//! `GlassCardBackground`). It used to be a translucent full-width strip,
//! which let the stale terminal pixels behind the band show through — that
//! see-through is what read as "text scrolling behind the banner".
//!
//! Content comes from the pure banner_markdown block parser (unit tested
//! in every lane): text lines, headings, thematic-break rules, lists with
//! a shared marker gutter (bullets / ordered numbers / native checkbox
//! boxes), and pipe tables with bold-measured column widths, `:` alignment
//! and long-cell word wrap. This file owns only the windowing, GDI
//! measurement, and painting.

const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const markdown = @import("banner_markdown.zig");
const card = @import("banner_card.zig");
const banner_layout = @import("banner_layout.zig");
const banner_link = @import("banner_link.zig");
const Surface = @import("Surface.zig");
const color_math = @import("color_math.zig");
const icon_button = @import("icon_button.zig");
const icon_paint = @import("icon_button_paint.zig");
const homedir = @import("../../os/homedir.zig");

const log = std.log.scoped(.win32_banner);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyBannerOverlay");

/// Window opacity (LWA_ALPHA). FULLY opaque (T131): the card's own
/// translucency is composited against the pane background in
/// `banner_card.render`, so nothing behind the window can bleed through.
/// A window-wide alpha let stale terminal pixels in the reserved band show
/// through the banner — the user-visible "text scrolling behind" bug. The
/// window stays WS_EX_LAYERED because that is what puts it above the
/// surface's OpenGL content.
const STRIP_ALPHA: u8 = 255;

/// Margin between the card and the band edges (Mac `GlassCard.outerMargin`).
const MARGIN: f32 = card.MARGIN;

/// Unscaled layout metrics. The Mac banner is a 12pt system font with
/// 12pt padding; our base font is 15px (T35), so px metrics scale by
/// 15/12 where they mirror a Mac point value.
const PAD: f32 = card.PADDING;
const FONT_H: f32 = 15.0;
const LINE_H: f32 = 20.0;
/// Vertical gap between blocks (Mac: VStack spacing 8).
const BLOCK_GAP: f32 = 8.0;
/// Vertical gap between list rows / table rows (Mac: Grid spacing 4).
const ROW_GAP: f32 = 4.0;
/// Gap between a list marker gutter and item content (Mac: 6).
const GUTTER_GAP: f32 = 6.0;
/// Horizontal gap between table columns (Mac: 18).
const COL_GAP: f32 = 18.0;
/// Native checkbox side (Mac: 12 at 12pt → 15 at our 15px base).
const CHECK_SIDE: f32 = 15.0;
/// Tail-truncation glyph for a cell that runs past `MAX_CELL_LINES`.
const ELLIPSIS = "…";
/// Negative-control switch (kept, deliberately): true restores the
/// pre-T123 table sizing — the fixed 360pt cap, no mid-string break, no
/// 3-line cell cap. Flipping it and re-running `pane-banner.ps1` must fail
/// exactly the 6 assertions of the T123 table block in section 6g and
/// nothing else; that is how those assertions were shown to test the fix
/// rather than the harness. (Measured 2026-08-12, T283: 6 FAILED / 109
/// passed — the >360px value wrapping on a wide pane, both narrow-pane
/// reflow assertions, the mid-string break, and both 3-line-cap
/// assertions. Nothing in 6h moves.)
///
/// T283 had to reshape it to keep that promise. It used to return the
/// single-line fast path out of `layoutInline` outright, which meant a
/// neutered build did not wrap table cells AT ALL — so the 360pt cap it
/// restores had no observable consequence and `a >360px value does not
/// wrap`, the assertion that names the user's report, could not fail no
/// matter how the flag was set. It also took T377's paragraph/heading/list
/// wrapping down with it (5 of section 6h went red), which is a control
/// reaching outside its own claim. Both halves are the `glyphCentered()`
/// shape from T209: a control that cannot adjudicate its own assertion.
const T123_NEUTERED = false;
/// The same negative control for T377: true restores the pre-T377 world
/// where ONLY table cells wrapped — a paragraph, a heading and a list row
/// were each drawn as one `drawInlineLine` at a fixed line height, and the
/// content column ran to one card padding from the band edge, i.e. straight
/// under the collapse chevron. Flipping it and re-running `pane-banner.ps1`
/// must fail exactly the section-6h assertions and nothing else.
const T377_NEUTERED = false;

/// The width a non-table block wraps against. `0` is `layoutInline`'s
/// "width unknown" signal, which is precisely the pre-T377 single-line
/// path, so the negative control needs no second code path to drift.
fn wrapWidth(content_w: i32) i32 {
    return if (T377_NEUTERED) 0 else content_w;
}
/// Collapsed content height: first line fully visible plus a sliver that
/// fades out (Mac: 24 at 12pt → 30 at 15px).
const COLLAPSED_H: f32 = 30.0;
/// Timer id for the collapse/expand animation heartbeat (T149). The only
/// timer this window class owns.
const COLLAPSE_TIMER_ID: usize = 1;

/// Negative control for `pane-banner.ps1`'s T149 section, the same seam
/// `T377_NEUTERED` gives the wrap work above. Flipping it restores the
/// pre-T149 jump cut — card and terminal both snapping in one frame — and
/// re-running the script must fail exactly the 6f2 assertions that are about
/// MOTION and nothing else. (Measured 2026-08-09: 6 of the 14 go red — the
/// three frame assertions in each direction — while the eight survivors are
/// the toggle and settled-geometry ones, which are 6f's claim restated, and
/// no assertion outside 6f2 moves.)
const T149_NEUTERED = false;

/// Negative control for `pane-banner.ps1`'s T833 assertions. Flipping it
/// restores the pre-T833 behavior — the animation heartbeat ticks and logs,
/// but only `updatePosition`'s resize path ever dirties the client — so an
/// EXPAND, whose window height never changes, freezes on whichever frame the
/// toggle's own invalidate happened to catch. Re-running the script must fail
/// exactly the 6f2 "reaches the screen" assertions in the expand direction and
/// nothing else.
const T833_NEUTERED = false;
/// Chevron toggle glyph half-width / height.
const CHEV_W: f32 = 5.0;
const CHEV_H: f32 = 3.5;

/// Heading text px per level (Mac: 17/16/15/14/13/12pt over a 12pt base,
/// scaled by 15/12).
const heading_px = [6]f32{ 21.25, 20.0, 18.75, 17.5, 16.25, 15.0 };
/// Number of cached font size classes: base + 6 heading levels.
const size_classes = 7;

/// The task-list checkbox green (Apple systemGreen, what the Mac's
/// `Color.green` resolves near).
const GREEN = color_math.Rgb{ .r = 52, .g = 199, .b = 89 };

pub const BannerOverlay = struct {
    alloc: std.mem.Allocator,
    /// The pane this banner belongs to. Supplies the viewer-split target and
    /// the origin directory for the link action menu (T165) — the win32
    /// analog of Mac's weak `BannerLinkOpener.surface`. The Surface owns the
    /// overlay and destroys it in its own deinit, so the pointer cannot
    /// outlive the pane.
    ///
    /// Optional because the class-behavior tests below drive a bare overlay
    /// against a plain owner window, with no pane behind it. Everything a
    /// link action needs from a pane degrades to "hand it to the shell"
    /// rather than to a null deref — the same fallback Mac takes when its
    /// weak surface or controller is gone.
    surface: ?*Surface,
    /// The surface HWND this banner sits on top of (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,
    /// Arena holding the parsed blocks and their text (reset per setText).
    arena: std.heap.ArenaAllocator,
    blocks: []const markdown.Block = &.{},

    /// Multi-line banners collapse/expand on click (Mac chevron parity).
    collapsible: bool = false,
    /// Is the pointer over the collapse chevron? (T204 — the chevron had no
    /// hover state at all, which is why the user asked "why doesn't the
    /// chevron in the banner have a similar hover?". It is an icon button
    /// like every other one now, so it needs the hot-tracking every other one
    /// already had.)
    hover_chevron: bool = false,
    /// Whether `TrackMouseEvent` is armed, so WM_MOUSELEAVE arrives and the
    /// hover can be dropped when the pointer leaves the overlay.
    mouse_tracked: bool = false,
    collapsed: bool = false,
    /// The in-flight collapse/expand, if any (T149): the card height the
    /// toggle started from, and when it started. Null when settled.
    ///
    /// The TARGET height is deliberately not stored — it is whatever
    /// `cardHeight()` answers for the (already flipped) `collapsed` state,
    /// so a banner whose text changes mid-flight animates to the new
    /// settled height instead of to a stale one.
    collapse_anim: ?struct {
        from_h: i32,
        start: std.time.Instant,
    } = null,
    /// Expanded content height in px (excludes padding), lazily computed;
    /// -1 means stale (recompute on next use).
    content_h: i32 = -1,

    /// The card height the LAST paint actually put on the screen (T833), or
    /// -1 before the first one. `paintedCardHeight()` is what the next paint
    /// would draw; this is what the pixels currently show, which is the only
    /// thing that can answer "is the card stale?" — during an expand the
    /// window keeps the settled band the whole way, so its size cannot.
    painted_h: i32 = -1,

    /// Height the window layout reserved for this strip ABOVE the owner
    /// pane (T101). The layout shrinks/offsets the owner HWND by this and
    /// `updatePosition` glues the strip into the vacated band, so the
    /// terminal grid starts below the banner instead of under it. 0 until
    /// a layout pass ran (then the strip falls back to overlapping the
    /// owner top so it is never lost).
    inset: i32 = 0,

    /// Width of the pane slot the banner spans, fed TOP-DOWN by the window
    /// layout (T123). Table columns are sized from it, so the banner
    /// reflows live with the pane and can never act as a minimum pane
    /// width. 0 until a layout pass ran — then column sizing falls back to
    /// the old fixed cap so the first paint is never absurdly wide.
    pane_w: i32 = 0,

    scale: f32 = 1.0,
    bg: u32 = 0, // COLORREF card fill
    bg_rgb: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    /// The pane's own background — what the band around the card shows,
    /// and the backdrop the card's wash is composited over (T131).
    pane_bg_rgb: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    fg: u32 = 0xFFFFFF,
    fg_rgb: color_math.Rgb = .{ .r = 255, .g = 255, .b = 255 },
    link_fg: u32 = 0xFF9C4F, // COLORREF is 0x00BBGGRR
    divider: u32 = 0,
    bg_brush: ?w32.HBRUSH = null,
    alpha_set: bool = false,

    /// Cached card backdrop (T131): the band background + elevation shadow
    /// + card fill/sheen/rim, rendered by `banner_card` into a DIB section
    /// and blitted under the text. Regenerated only when the band size, the
    /// pane background, or the DPI scale changes — a banner repaint (hover,
    /// collapse, content update) reuses it.
    card_dc: ?w32.HDC = null,
    card_bmp: ?*anyopaque = null,
    card_bits: ?[*]u32 = null,
    card_w: i32 = 0,
    card_h: i32 = 0,
    card_bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    card_scale: f32 = 0,

    /// Lazy font cache: size class (0 base, 1–6 headings) × style bits
    /// (bold | italic<<1 | ul<<2 | code<<3).
    fonts: [size_classes * 16]?*anyopaque = @splat(null),

    /// Link hit rects, rebuilt on every paint (client coordinates).
    links: std.ArrayList(LinkRect) = .empty,

    /// Which link the pointer is over, identified by its URL slice's POINTER
    /// (T165). Not an index into `links`: one `[text](url)` occurrence can
    /// produce several hit rects — nested styling splits it, and so does a
    /// wrap — and the whole link must go solid together, the way Mac keys its
    /// hover on the link's character range. The parser `arena.dupe`s the URL
    /// once per occurrence, so the slice's `.ptr` IS that occurrence's
    /// identity, and two `[a](x)`/`[b](x)` links with the same text are still
    /// two different pointers. Cleared on `setText` — the arena reset that
    /// frees the URLs is what makes the pointer meaningless.
    hover_link: ?[*]const u8 = null,

    /// Scratch for the decoded path a file link hands to a viewer pane
    /// (T165). The viewer dupes what it keeps, so the buffer only has to
    /// outlive the call.
    viewer_path_buf: [std.fs.max_path_bytes]u8 = undefined,

    const LinkRect = struct {
        rect: w32.RECT,
        /// Arena-owned (lives until the next setText).
        url: []const u8,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        surface: ?*Surface,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*BannerOverlay {
        try registerClassOnce(hinstance);

        const self = try alloc.create(BannerOverlay);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .surface = surface,
            .owner = owner,
            .hwnd = undefined,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL content.
        // WS_EX_NOACTIVATE — clicks never move activation to the popup.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
        // Deliberately not WS_EX_TRANSPARENT: links/collapse are clickable.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE |
            w32.WS_EX_TOOLWINDOW;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1, // placeholder — updatePosition glues to the owner
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;

        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *BannerOverlay) void {
        _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.hwnd);
        self.clearFonts();
        self.releaseCardSurface();
        if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.links.deinit(self.alloc);
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    /// Replace the banner source text (raw markdown) and repaint. The
    /// caller keeps ownership of `text`; empty text is the caller's cue to
    /// destroy/hide instead — here it just paints an empty strip.
    pub fn setText(self: *BannerOverlay, text: []const u8) void {
        _ = self.arena.reset(.retain_capacity);
        self.links.clearRetainingCapacity();
        // The reset above freed every URL, so the hover's identity pointer
        // now names nothing (T165).
        self.hover_link = null;
        // Bare relative paths in the text resolve against the pane, here
        // and not at click time, because the parser is what decides whether
        // they are links at all: with nothing to resolve against they stay
        // plain text rather than becoming a link that goes nowhere (T539).
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        self.blocks = markdown.parseBlocks(
            self.arena.allocator(),
            .{
                .cwd = if (self.surface) |s| s.pwd else null,
                .home = homedir.home(&home_buf) catch null,
            },
            text,
        ) catch &.{};
        self.collapsible = std.mem.indexOfScalar(u8, text, '\n') != null;
        if (!self.collapsible) self.collapsed = false;
        self.content_h = -1;
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    /// Refresh card colors from the pane's effective background (per-pane
    /// tint or config background) and the config foreground. The fill is
    /// Mac's glass wash — `lighten(0.06)` on a dark pane, `darken(0.04)` on
    /// a light one (T131) — composited, not translucent.
    pub fn setColors(self: *BannerOverlay, pane_bg: color_math.Rgb, fg: color_math.Rgb) void {
        const light = color_math.isLight(pane_bg);
        const strip = card.fillColor(pane_bg);
        // The band around the card is the pane's own background, so a pane
        // background change repaints even when the card fill rounds to the
        // same value.
        const bg_changed = !std.meta.eql(self.pane_bg_rgb, pane_bg);
        self.pane_bg_rgb = pane_bg;
        const div = if (light)
            color_math.darken(pane_bg, 0.25)
        else
            color_math.lighten(pane_bg, 0.25);
        const bg_ref = w32.RGB(strip.r, strip.g, strip.b);
        const fg_ref = w32.RGB(fg.r, fg.g, fg.b);
        const link_ref: u32 = if (light) w32.RGB(0, 102, 204) else w32.RGB(90, 160, 255);
        const div_ref = w32.RGB(div.r, div.g, div.b);
        if (!bg_changed and bg_ref == self.bg and fg_ref == self.fg and
            link_ref == self.link_fg and div_ref == self.divider and
            self.bg_brush != null) return;
        self.bg = bg_ref;
        self.bg_rgb = strip;
        self.fg = fg_ref;
        self.fg_rgb = fg;
        self.link_fg = link_ref;
        self.divider = div_ref;
        if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.bg_brush = w32.CreateSolidBrush(bg_ref);
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    /// Glue the strip into the band the window layout reserved above the
    /// owner pane (T101; screen coordinates). Hides when the owner is not
    /// visible (hidden split, other tab, hero carousel). Idempotent —
    /// doubles as the reposition call.
    pub fn updatePosition(self: *BannerOverlay, scale: f32) void {
        if (w32.IsWindowVisible_(self.owner) == 0) {
            self.hide();
            return;
        }
        if (!self.alpha_set) {
            _ = w32.SetLayeredWindowAttributes(self.hwnd, 0, STRIP_ALPHA, w32.LWA_ALPHA);
            self.alpha_set = true;
        }
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &rect) == 0) return;
        // The owner spans the pane slot's full width (the layout only ever
        // offsets its TOP by the band), so its rect is the pane width the
        // banner content must size itself to (T123).
        const strip = self.insetHeight(scale, rect.right - rect.left);
        // `inset` > 0: the layout moved the owner down by that much; the
        // strip fills the vacated band exactly (bottom-clipped when the
        // clamp engaged in a degenerate short pane). `inset` == 0: no
        // layout pass ran yet — fall back to overlapping the owner top so
        // the strip is never lost.
        const settled = if (self.inset > 0) @min(self.inset, strip) else strip;
        // While the card animates (T149) the popup has to cover BOTH the
        // band the layout reserved and the card's height right now.
        // Collapsing, the terminal has ALREADY snapped up under the settled
        // (short) band while the card is still tall, so the card overhangs
        // the terminal for the length of the animation — exactly what Mac's
        // overlay does, and the reason the inset can snap at all. Expanding,
        // the card is shorter than the band and the window keeps the band.
        // Capped at the pane slot so a degenerate short pane is never
        // covered outright.
        const height = if (self.collapse_anim == null) settled else blk: {
            const anim = banner_layout.bandHeight(self.paintedCardHeight(), self.px(MARGIN));
            const slot = @max(self.inset, 0) + (rect.bottom - rect.top);
            break :blk @max(settled, @min(anim, slot));
        };
        const top = rect.top - @max(self.inset, 0);
        const new_w = @max(rect.right - rect.left, 1);
        const new_h = @max(height, 1);

        // Is this a RESIZE or just a move? (T456) A resize restyles every
        // pixel of the card; a move restyles none of them.
        var old: w32.RECT = undefined;
        const resized = w32.GetWindowRect(self.hwnd, &old) == 0 or
            (old.right - old.left) != new_w or (old.bottom - old.top) != new_h;

        // SWP_NOCOPYBITS on a resize: the class already invalidates the whole
        // client (CS_HREDRAW|CS_VREDRAW), so blitting the old bits into the
        // new rect only buys a frame of stretched, stale card before the
        // repaint lands over it.
        var flags: u32 = w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW;
        if (resized) flags |= w32.SWP_NOCOPYBITS;

        _ = w32.SetWindowPos(self.hwnd, null, rect.left, top, new_w, new_h, flags);

        // Repaint NOW, not on the next pumped WM_PAINT (T456). This runs
        // inside the layout pass that just moved the owner pane, and a
        // divider drag re-runs that pass per mouse-move — so a deferred
        // paint puts the card a whole drag frame behind the pane it is
        // glued to, which is what "the overlay lags the drag" describes.
        // Painting synchronously costs nothing extra overall: it is the
        // same card render, moved earlier in the same frame.
        if (resized) _ = w32.UpdateWindow(self.hwnd);
        // Every reposition re-checks the z-order instead of leaving it to
        // whatever last touched it (T142).
        w32.healOverlayZOrder(self.hwnd, self.owner);
    }

    /// The strip's natural height at `scale` in a `pane_w`-wide pane slot,
    /// for the window layout to reserve above the owner pane (T101). Syncs
    /// the overlay's scale and pane width first, so a DPI change measures
    /// with the right fonts and a resize re-measures at the width the
    /// content will actually be painted into (T123 — a table that rewraps
    /// narrower gets a taller band, and one that unwraps gets a shorter
    /// one, instead of the band and the paint disagreeing).
    pub fn insetHeight(self: *BannerOverlay, scale: f32, pane_w: i32) i32 {
        if (scale != self.scale) {
            self.scale = scale;
            self.clearFonts();
            self.content_h = -1;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
        }
        const w = @max(pane_w, 0);
        if (w != self.pane_w) {
            self.pane_w = w;
            self.content_h = -1;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
        }
        return self.stripHeight();
    }

    pub fn hide(self: *BannerOverlay) void {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    }

    /// Total band height: the floating card (padding + content) plus the
    /// margin it leaves on the top AND bottom, so the terminal content
    /// below always starts a breath under the card (Mac parity — its
    /// bottom margin is part of the measured banner height too).
    fn stripHeight(self: *BannerOverlay) i32 {
        return banner_layout.bandHeight(
            self.cardHeight(),
            self.px(MARGIN),
        );
    }

    /// Height of the card itself: uniform inner padding around the content.
    /// The SETTLED height — what the window layout reserves, and what a
    /// running collapse/expand is heading for. `paintedCardHeight` is what
    /// gets drawn.
    fn cardHeight(self: *BannerOverlay) i32 {
        const content = if (self.collapsed)
            self.px(COLLAPSED_H)
        else
            self.ensureContentHeight();
        return self.px(PAD) * 2 + content;
    }

    /// The card height with a running collapse/expand applied (T149) — the
    /// settled height when nothing is animating, which is every paint but
    /// the ~11 frames after a toggle.
    fn paintedCardHeight(self: *BannerOverlay) i32 {
        const target = self.cardHeight();
        const a = self.collapse_anim orelse return target;
        const p = self.collapseProgress() orelse return target;
        return banner_layout.collapseHeight(a.from_h, target, p);
    }

    /// Linear 0→1 progress of the collapse animation, or null when none is
    /// running, it has run out, or the monotonic clock is unavailable — in
    /// every one of those the caller uses the settled height, which is the
    /// pre-T149 behavior.
    fn collapseProgress(self: *const BannerOverlay) ?f32 {
        const a = self.collapse_anim orelse return null;
        const now = std.time.Instant.now() catch return null;
        const ms = @as(f32, @floatFromInt(now.since(a.start))) / std.time.ns_per_ms;
        if (ms >= banner_layout.COLLAPSE_MS) return null;
        return ms / banner_layout.COLLAPSE_MS;
    }

    /// Width available to the content INSIDE the card: the pane slot less
    /// the card's margin and padding on both sides, and less the collapse
    /// chevron's reserved column when the banner has one (T377). 0 while
    /// the pane width is still unknown, which is the signal for the
    /// fixed-cap fallback.
    ///
    /// The measuring pass and the paint MUST agree here, so both go
    /// through `contentWidthFor` — a band reserved from one width and
    /// painted at another is exactly how a banner ends up over the
    /// terminal.
    fn contentWidth(self: *const BannerOverlay) i32 {
        if (self.pane_w <= 0) return 0;
        return self.contentWidthFor(self.pane_w);
    }

    fn contentWidthFor(self: *const BannerOverlay, client_w: i32) i32 {
        const margin = self.px(MARGIN);
        return banner_layout.contentWidth(
            client_w,
            margin + self.px(PAD),
            margin,
            if (self.collapsible and !T377_NEUTERED) icon_button.Metrics.init(self.scale).target else 0,
            self.px(banner_layout.CHEVRON_GAP),
        );
    }

    /// Expanded content height, measured via a window DC when stale. The
    /// measure runs at the SAME content width the paint will use, so the
    /// reserved band always matches what gets drawn into it (T123).
    fn ensureContentHeight(self: *BannerOverlay) i32 {
        if (self.content_h >= 0) return self.content_h;
        const hdc = w32.GetDC(self.hwnd) orelse {
            return self.px(LINE_H); // degrade: one-line strip
        };
        defer _ = w32.ReleaseDC(self.hwnd, hdc);
        self.content_h = self.renderContent(hdc, 0, 0, self.contentWidth(), false);
        return self.content_h;
    }

    fn px(self: *const BannerOverlay, v: f32) i32 {
        return @intFromFloat(@round(v * self.scale));
    }

    fn clearFonts(self: *BannerOverlay) void {
        for (&self.fonts) |*f| {
            if (f.*) |font| _ = w32.DeleteObject(font);
            f.* = null;
        }
    }

    /// Font for a style at a size class (0 = base text, 1–6 = heading
    /// levels). Headings render semibold (Mac parity), so class > 0
    /// forces bold.
    fn fontFor(self: *BannerOverlay, style: markdown.Style, size_class: usize) ?*anyopaque {
        const bold = style.bold or size_class > 0;
        const bits: usize = @as(usize, @intFromBool(bold)) |
            (@as(usize, @intFromBool(style.italic)) << 1) |
            (@as(usize, @intFromBool(style.underline)) << 2) |
            (@as(usize, @intFromBool(style.code)) << 3);
        const idx = size_class * 16 + bits;
        if (self.fonts[idx]) |f| return f;
        const face = if (style.code)
            std.unicode.utf8ToUtf16LeStringLiteral("Consolas")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        const height = if (size_class == 0) FONT_H else heading_px[size_class - 1];
        self.fonts[idx] = w32.CreateFontW(
            -self.px(height),
            0,
            0,
            0,
            if (bold) 700 else 400,
            @intFromBool(style.italic),
            @intFromBool(style.underline),
            0,
            w32.DEFAULT_CHARSET,
            0,
            0,
            0,
            0,
            face,
        );
        return self.fonts[idx];
    }

    /// Blend `c` toward the strip background by `1 - t` (t = opacity of c
    /// over the strip), the GDI stand-in for Mac's alpha-composited marks.
    fn overStrip(self: *const BannerOverlay, c: color_math.Rgb, t: f32) u32 {
        const blend = struct {
            fn ch(a: u8, b: u8, tt: f32) u8 {
                const v = @as(f32, @floatFromInt(b)) * (1.0 - tt) +
                    @as(f32, @floatFromInt(a)) * tt;
                return @intFromFloat(@max(0.0, @min(255.0, @round(v))));
            }
        };
        return w32.RGB(
            blend.ch(c.r, self.bg_rgb.r, t),
            blend.ch(c.g, self.bg_rgb.g, t),
            blend.ch(c.b, self.bg_rgb.b, t),
        );
    }

    /// Secondary text/marker color (Mac `.secondary`): fg at ~55% over bg.
    fn secondary(self: *const BannerOverlay) u32 {
        return self.overStrip(self.fg_rgb, 0.55);
    }

    // -----------------------------------------------------------------
    // Measure + draw walker. One code path computes geometry for both the
    // measuring pass (draw=false → returns content height) and painting
    // (draw=true → also fills link rects), so height and pixels can't
    // drift apart.
    // -----------------------------------------------------------------

    /// The style a run is actually rendered with. A LINK drops the parser's
    /// `underline` flag (T165): its rule is drawn by hand below, dotted at
    /// rest and solid on hover, and GDI's own `lfUnderline` is only ever
    /// solid — leaving it on would make every link look permanently hovered.
    /// A non-link `__underline__` keeps its solid font underline, exactly as
    /// Mac does. Applied in the MEASURE path too so the two passes select the
    /// identical font and can never disagree about a width.
    fn renderStyle(style: markdown.Style, link: ?[]const u8, force_bold: bool) markdown.Style {
        var s = style;
        if (force_bold) s.bold = true;
        if (link != null) s.underline = false;
        return s;
    }

    fn measureSeg(
        self: *BannerOverlay,
        hdc: w32.HDC,
        text: []const u8,
        style: markdown.Style,
        link: ?[]const u8,
        size_class: usize,
        force_bold: bool,
    ) w32.SIZE {
        const s = renderStyle(style, link, force_bold);
        var wbuf: [1024]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return .{ .cx = 0, .cy = 0 };
        if (wlen == 0) return .{ .cx = 0, .cy = 0 };
        const font = self.fontFor(s, size_class);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        return size;
    }

    fn drawSegText(
        self: *BannerOverlay,
        hdc: w32.HDC,
        x: i32,
        y: i32,
        line_h: i32,
        text: []const u8,
        style: markdown.Style,
        link: ?[]const u8,
        size_class: usize,
        force_bold: bool,
        draw: bool,
    ) i32 {
        const s = renderStyle(style, link, force_bold);
        var wbuf: [1024]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
        if (wlen == 0) return 0;
        const font = self.fontFor(s, size_class);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        if (draw) {
            const ty = y + @divTrunc(line_h - size.cy, 2);
            _ = w32.SetTextColor(hdc, if (link != null) self.link_fg else self.fg);
            _ = w32.TextOutW(hdc, x, ty, &wbuf, @intCast(wlen));
            if (link) |url| {
                self.links.append(self.alloc, .{
                    .rect = .{ .left = x, .top = y, .right = x + size.cx, .bottom = y + line_h },
                    .url = url,
                }) catch {};
                self.drawLinkUnderline(
                    hdc,
                    x,
                    ty,
                    size.cx,
                    size.cy,
                    self.hover_link == url.ptr,
                );
            }
        }
        return size.cx;
    }

    /// The link hover affordance (T165): a dotted rule under the run at rest,
    /// a solid one while the pointer is over this link. Filled rects, not a
    /// `LineTo` pen — the design system's rule, and here it also buys exact
    /// dot boundaries, which a styled pen's phase does not guarantee.
    fn drawLinkUnderline(
        self: *BannerOverlay,
        hdc: w32.HDC,
        x: i32,
        text_y: i32,
        w: i32,
        text_h: i32,
        solid: bool,
    ) void {
        if (w <= 0) return;
        const u = banner_layout.linkUnderline(text_y, text_h, self.scale);
        const brush = w32.CreateSolidBrush(self.link_fg) orelse return;
        defer _ = w32.DeleteObject(@ptrCast(brush));
        if (solid) {
            var r: w32.RECT = .{
                .left = x,
                .top = u.y,
                .right = x + w,
                .bottom = u.y + u.thickness,
            };
            _ = w32.FillRect(hdc, &r, brush);
            return;
        }
        // Dot phase is keyed to the CLIENT x, not to this run's left edge.
        // One link is drawn as many runs — the wrap tokenizer splits it per
        // word, and nested styling splits it again — so a per-run phase would
        // put two dots hard against each other at every word boundary and
        // read as a dirty line. An absolute phase makes every fragment part
        // of one continuous rule.
        const end = x + w;
        var dx: i32 = x - @mod(x, u.period);
        while (dx < end) : (dx += u.period) {
            const left = @max(x, dx);
            const right = @min(end, dx + u.dot);
            if (right <= left) continue;
            var r: w32.RECT = .{
                .left = left,
                .top = u.y,
                .right = right,
                .bottom = u.y + u.thickness,
            };
            _ = w32.FillRect(hdc, &r, brush);
        }
    }

    /// Draw a native task-list checkbox centered on the line; returns its
    /// advance width.
    fn drawCheckbox(self: *BannerOverlay, hdc: w32.HDC, x: i32, y: i32, line_h: i32, checked: bool, draw: bool) i32 {
        const side = self.px(CHECK_SIDE);
        if (!draw) return side;
        const top = y + @divTrunc(line_h - side, 2);
        const radius = self.px(3.0);

        const fill_ref = if (checked) self.overStrip(GREEN, 0.16) else self.bg;
        const border_ref = if (checked)
            self.overStrip(GREEN, 0.55)
        else
            self.overStrip(self.fg_rgb, 0.55);

        const fill = w32.CreateSolidBrush(fill_ref);
        const pen = w32.CreatePen(0, 1, border_ref); // PS_SOLID
        if (fill != null and pen != null) {
            const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
            const prev_pen = w32.SelectObject(hdc, pen.?);
            _ = w32.RoundRect(hdc, x, top, x + side, top + side, radius, radius);
            _ = w32.SelectObject(hdc, prev_pen);
            _ = w32.SelectObject(hdc, prev_brush);
        }
        if (fill) |b| _ = w32.DeleteObject(@ptrCast(b));
        if (pen) |p| _ = w32.DeleteObject(p);

        if (checked) {
            const check_pen = w32.CreatePen(0, @max(1, self.px(1.6)), w32.RGB(GREEN.r, GREEN.g, GREEN.b));
            if (check_pen) |p| {
                const prev_pen = w32.SelectObject(hdc, p);
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(top);
                const fs: f32 = @floatFromInt(side);
                _ = w32.MoveToEx(hdc, @intFromFloat(fx + fs * 0.26), @intFromFloat(fy + fs * 0.54), null);
                _ = w32.LineTo(hdc, @intFromFloat(fx + fs * 0.44), @intFromFloat(fy + fs * 0.72));
                _ = w32.LineTo(hdc, @intFromFloat(fx + fs * 0.76), @intFromFloat(fy + fs * 0.30));
                _ = w32.SelectObject(hdc, prev_pen);
                _ = w32.DeleteObject(p);
            }
        }
        return side;
    }

    /// Lay out one single-display-line run of inline content at (x, y);
    /// returns the total advance width.
    fn drawInlineLine(
        self: *BannerOverlay,
        hdc: w32.HDC,
        x0: i32,
        y: i32,
        line_h: i32,
        segs: []const markdown.Inline,
        size_class: usize,
        force_bold: bool,
        draw: bool,
    ) i32 {
        var x = x0;
        for (segs) |inl| switch (inl) {
            .seg => |s| x += self.drawSegText(hdc, x, y, line_h, s.text, s.style, s.link, size_class, force_bold, draw),
            .checkbox => |checked| x += self.drawCheckbox(hdc, x, y, line_h, checked, draw),
        };
        return x - x0;
    }

    fn hasCheckbox(segs: []const markdown.Inline) bool {
        for (segs) |inl| if (inl == .checkbox) return true;
        return false;
    }

    /// A word/space token of a wrapping table cell.
    const Token = struct {
        text: []const u8 = "", // empty for a checkbox token
        style: markdown.Style = .{},
        link: ?[]const u8 = null,
        checkbox: ?bool = null,
        is_space: bool = false,
        width: f32 = 0,
    };

    /// Split inline content into word/space tokens with measured widths.
    /// `size_class` is the font size class the run renders at (0 base,
    /// 1–6 heading levels) — a heading has to be tokenized in ITS font or
    /// the wrap breaks at the wrong words (T377).
    fn tokenizeCell(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        segs: []const markdown.Inline,
        size_class: usize,
        force_bold: bool,
    ) std.mem.Allocator.Error![]Token {
        var out: std.ArrayList(Token) = .empty;
        for (segs) |inl| switch (inl) {
            .checkbox => |checked| try out.append(arena, .{
                .checkbox = checked,
                .width = @floatFromInt(self.px(CHECK_SIDE)),
            }),
            .seg => |s| {
                var i: usize = 0;
                while (i < s.text.len) {
                    const is_space = s.text[i] == ' ';
                    var j = i;
                    while (j < s.text.len and (s.text[j] == ' ') == is_space) j += 1;
                    const word = s.text[i..j];
                    const size = self.measureSeg(hdc, word, s.style, s.link, size_class, force_bold);
                    try out.append(arena, .{
                        .text = word,
                        .style = s.style,
                        .link = s.link,
                        .is_space = is_space,
                        .width = @floatFromInt(size.cx),
                    });
                    i = j;
                }
            },
        };
        return out.items;
    }

    /// Natural (single-line) width of a run of inline content.
    fn cellNaturalWidth(
        self: *BannerOverlay,
        hdc: w32.HDC,
        segs: []const markdown.Inline,
        size_class: usize,
        force_bold: bool,
    ) i32 {
        var total: i32 = 0;
        for (segs) |inl| switch (inl) {
            .seg => |s| total += self.measureSeg(hdc, s.text, s.style, s.link, size_class, force_bold).cx,
            .checkbox => total += self.px(CHECK_SIDE),
        };
        return total;
    }

    /// Replace every non-space token wider than `max_w` with a run of
    /// sub-tokens that each fit, so a long unbroken string breaks
    /// mid-string instead of overflowing its column (T123 / CLAUDE.md:
    /// "even a long unbroken token breaks mid-string"). Returns `tokens`
    /// untouched — no allocation — when nothing is too wide, which is the
    /// overwhelmingly common case.
    fn breakWideTokens(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        tokens: []const Token,
        max_w: i32,
        size_class: usize,
    ) std.mem.Allocator.Error![]const Token {
        if (max_w <= 0) return tokens;
        const limit: f32 = @floatFromInt(max_w);
        const too_wide = struct {
            fn f(t: Token, lim: f32) bool {
                return t.checkbox == null and !t.is_space and t.width > lim;
            }
        }.f;
        var any = false;
        for (tokens) |t| {
            if (too_wide(t, limit)) {
                any = true;
                break;
            }
        }
        if (!any) return tokens;

        var out: std.ArrayList(Token) = .empty;
        for (tokens) |t| {
            if (!too_wide(t, limit)) {
                try out.append(arena, t);
                continue;
            }
            var rest = t.text;
            while (rest.len > 0) {
                const fit = self.prefixFitting(
                    hdc,
                    rest,
                    renderStyle(t.style, t.link, false),
                    max_w,
                    size_class,
                );
                // Always consume at least one codepoint: a column too
                // narrow for even a single glyph must still terminate.
                const take = if (fit > 0)
                    fit
                else
                    (std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
                const chunk = rest[0..@min(take, rest.len)];
                try out.append(arena, .{
                    .text = chunk,
                    .style = t.style,
                    .link = t.link,
                    .width = @floatFromInt(self.measureSeg(hdc, chunk, t.style, t.link, size_class, false).cx),
                });
                rest = rest[chunk.len..];
            }
        }
        return out.items;
    }

    /// Byte length of the longest prefix of `text` that renders within
    /// `max_w` px in `style`. 0 when nothing fits (or on failure).
    fn prefixFitting(
        self: *BannerOverlay,
        hdc: w32.HDC,
        text: []const u8,
        style: markdown.Style,
        max_w: i32,
        size_class: usize,
    ) usize {
        var wbuf: [1024]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
        if (wlen == 0) return 0;
        const font = self.fontFor(style, size_class);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var fit: i32 = 0;
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        if (w32.GetTextExtentExPointW(hdc, &wbuf, @intCast(wlen), max_w, &fit, null, &size) == 0) return 0;
        if (fit <= 0) return 0;
        var units: usize = @min(@as(usize, @intCast(fit)), wlen);
        // Never break inside a surrogate pair.
        if (units > 0 and units < wlen and wbuf[units - 1] >= 0xD800 and wbuf[units - 1] <= 0xDBFF) units -= 1;
        return banner_layout.utf16PrefixBytes(text, units);
    }

    /// One run of inline content laid out into display lines. Used by
    /// EVERY block that holds inline content — paragraphs, headings, list
    /// rows and table cells (T377) — so they cannot wrap by different
    /// rules.
    const InlineLayout = struct {
        tokens: []const Token = &.{},
        lines: []markdown.WrapLine = &.{},
        /// Single-line fast path when the run fits (or holds a checkbox).
        single: bool = true,
        /// The run went past MAX_CELL_LINES and its last visible line
        /// tail-truncates with an ellipsis.
        truncated: bool = false,

        /// Display lines this run occupies.
        fn lineCount(self: InlineLayout) i32 {
            return if (self.single) 1 else @intCast(self.lines.len);
        }
    };

    /// Which of T123's two cell rules apply to a run. Taken as DATA rather
    /// than read off the comptime flag inside `layoutInline`, for the reason
    /// `icon_button.glyphTarget` is: a unit test can then assert that the two
    /// worlds produce DIFFERENT output, and the neuter reaches TABLE CELLS
    /// only — a paragraph, a heading and a list row keep wrapping by T377's
    /// rules whatever T123 is set to, so a control cannot fail assertions
    /// outside its own claim (T283).
    const CellWrap = struct {
        /// Break a token wider than its column mid-string.
        break_wide: bool = true,
        /// Cap the run at `MAX_CELL_LINES` display lines, tail-truncating
        /// the last visible one.
        cap_lines: bool = true,

        /// The shipped rules, and what every non-table block always uses.
        const shipped: CellWrap = .{};

        /// The world the neuter restores: a cell still wraps (at the fixed
        /// fallback cap `columnWidths` hands it), and does neither of the
        /// two things T123 added.
        const pre_t123: CellWrap = .{ .break_wide = false, .cap_lines = false };

        /// What a TABLE cell gets.
        fn forCell() CellWrap {
            return if (T123_NEUTERED) pre_t123 else shipped;
        }
    };

    /// Wrap `segs` into at most `MAX_CELL_LINES` display lines within
    /// `max_w` px. Returns the single-line fast path when the run already
    /// fits, when the width is not known yet, or when the run holds an
    /// inline checkbox — a native checkbox box cannot reflow around
    /// wrapping text, so such a run stays on one line (a LIST checkbox is
    /// the item's marker, drawn in the gutter, and never lands here, so a
    /// task-list row wraps like any other).
    fn layoutInline(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        segs: []const markdown.Inline,
        max_w: i32,
        size_class: usize,
        force_bold: bool,
        rules: CellWrap,
    ) InlineLayout {
        if (max_w <= 0) return .{};
        if (hasCheckbox(segs)) return .{};
        if (self.cellNaturalWidth(hdc, segs, size_class, force_bold) <= max_w) return .{};

        const raw = self.tokenizeCell(arena, hdc, segs, size_class, force_bold) catch return .{};
        const tokens: []const Token = if (rules.break_wide)
            self.breakWideTokens(arena, hdc, raw, max_w, size_class) catch return .{}
        else
            raw;
        const tw = arena.alloc(f32, tokens.len) catch return .{};
        const ts = arena.alloc(bool, tokens.len) catch return .{};
        for (tokens, 0..) |t, ti| {
            tw[ti] = t.width;
            ts[ti] = t.is_space;
        }
        var lines = markdown.wrapTokens(arena, tw, ts, @floatFromInt(max_w)) catch return .{};
        // Capped at MAX_CELL_LINES display lines; past that the last
        // visible line tail-truncates, so one nasty run can't blow up the
        // banner height (Mac parity).
        const truncated = rules.cap_lines and lines.len > banner_layout.MAX_CELL_LINES;
        if (truncated) lines = lines[0..banner_layout.MAX_CELL_LINES];
        return .{
            .tokens = tokens,
            .lines = lines,
            .single = false,
            .truncated = truncated,
        };
    }

    /// Paint (or just measure) a laid-out run in a `slot_w`-wide slot at
    /// (`x0`, `y0`). Returns the height it occupies, which is what the
    /// caller must report upward — the band height, the pane inset and the
    /// display cap all derive from it, so a wrap that does not report its
    /// height paints over the terminal.
    fn drawWrapped(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        lay: InlineLayout,
        segs: []const markdown.Inline,
        x0: i32,
        y0: i32,
        line_h: i32,
        slot_w: i32,
        alignment: ?markdown.ColumnAlignment,
        size_class: usize,
        force_bold: bool,
        draw: bool,
    ) i32 {
        if (lay.single) {
            const cw = self.cellNaturalWidth(hdc, segs, size_class, force_bold);
            _ = self.drawInlineLine(
                hdc,
                alignedX(x0, slot_w, cw, alignment),
                y0,
                line_h,
                segs,
                size_class,
                force_bold,
                draw,
            );
            return line_h;
        }

        for (lay.lines, 0..) |wl, li| {
            var run = lay.tokens[wl.start..wl.end];
            // Tail-truncate the last visible line of a capped run: drop
            // whatever no longer fits beside the ellipsis, then draw the
            // ellipsis itself.
            const ellipsis = lay.truncated and li + 1 == lay.lines.len;
            var ell_w: i32 = 0;
            if (ellipsis) {
                ell_w = self.measureSeg(hdc, ELLIPSIS, .{}, null, size_class, force_bold).cx;
                if (arena.alloc(f32, run.len)) |tw2| {
                    for (run, 0..) |t, ti| tw2[ti] = t.width;
                    const keep = banner_layout.fitWithEllipsis(
                        tw2,
                        @floatFromInt(ell_w),
                        @floatFromInt(slot_w),
                    );
                    run = run[0..keep];
                    while (run.len > 0 and run[run.len - 1].is_space) run = run[0 .. run.len - 1];
                } else |_| {}
            }
            var lw: f32 = @floatFromInt(ell_w);
            for (run) |t| lw += t.width;
            var tx = alignedX(x0, slot_w, @intFromFloat(@round(lw)), alignment);
            const ly = y0 + @as(i32, @intCast(li)) * line_h;
            for (run) |t| {
                if (t.checkbox) |checked| {
                    tx += self.drawCheckbox(hdc, tx, ly, line_h, checked, draw);
                } else {
                    tx += self.drawSegText(hdc, tx, ly, line_h, t.text, t.style, t.link, size_class, force_bold, draw);
                }
            }
            if (ellipsis) {
                _ = self.drawSegText(hdc, tx, ly, line_h, ELLIPSIS, .{}, null, size_class, force_bold, draw);
            }
        }
        return @as(i32, @intCast(lay.lines.len)) * line_h;
    }

    /// Height + draw of one table block in `avail_w` px of content width.
    /// Column widths come from the widest cell's natural width (+slack)
    /// with header cells measured bold — the Mac's exact scheme, so bold
    /// labels never force-wrap — divided against the PANE's width rather
    /// than a fixed cap (T123), so a wide pane is used and a narrow one
    /// rewraps instead of being blocked from shrinking.
    fn renderTable(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        table: markdown.Table,
        x0: i32,
        y0: i32,
        avail_w: i32,
        draw: bool,
    ) i32 {
        const columns = table.header.len;
        if (columns == 0) return 0;

        const line_h = self.px(LINE_H);
        const row_gap = self.px(ROW_GAP);
        const col_gap = self.px(COL_GAP);
        const slack = self.px(2.0);
        const show_header = table.hasVisibleHeader();

        const natural = arena.alloc(f32, columns) catch return 0;
        @memset(natural, 0);
        if (show_header) {
            for (table.header, 0..) |cell, col| {
                natural[col] = @max(natural[col], @as(f32, @floatFromInt(self.cellNaturalWidth(hdc, cell, 0, true))));
            }
        }
        for (table.rows) |row| {
            for (row, 0..) |cell, col| {
                if (col >= columns) break;
                natural[col] = @max(natural[col], @as(f32, @floatFromInt(self.cellNaturalWidth(hdc, cell, 0, false))));
            }
        }
        for (natural) |*n| n.* += @floatFromInt(slack);

        const shares = arena.alloc(f32, columns) catch return 0;
        banner_layout.columnWidths(
            natural,
            shares,
            if (T123_NEUTERED) 0 else @floatFromInt(@max(avail_w, 0)),
            @floatFromInt(col_gap),
        );
        const widths = arena.alloc(i32, columns) catch return 0;
        for (shares, 0..) |s, col| widths[col] = @max(1, @as(i32, @intFromFloat(@floor(s))));

        // Wrap layout per body cell (checkbox cells stay single-line).
        const layouts = arena.alloc(InlineLayout, table.rows.len * columns) catch return 0;
        @memset(layouts, .{});
        for (table.rows, 0..) |row, r| {
            for (row, 0..) |cell, col| {
                if (col >= columns) break;
                layouts[r * columns + col] = self.layoutInline(arena, hdc, cell, widths[col], 0, false, CellWrap.forCell());
            }
        }

        var y = y0;

        if (show_header) {
            for (table.header, 0..) |cell, col| {
                var cx = x0;
                for (widths[0..col]) |wd| cx += wd + col_gap;
                const cw = self.inlineLineWidth(hdc, cell, true);
                _ = self.drawInlineLine(hdc, alignedX(cx, widths[col], cw, table.alignments[col]), y, line_h, cell, 0, true, draw);
            }
            y += line_h + row_gap;
            // Divider spanning the table's content width.
            if (draw) {
                var tw: i32 = 0;
                for (widths, 0..) |wd, col| {
                    tw += wd;
                    if (col + 1 < columns) tw += col_gap;
                }
                self.drawHLine(hdc, x0, x0 + tw, y);
            }
            y += 1 + row_gap;
        }

        for (table.rows, 0..) |row, r| {
            var row_h: i32 = line_h;
            for (0..columns) |col| {
                row_h = @max(row_h, layouts[r * columns + col].lineCount() * line_h);
            }
            var cx = x0;
            for (0..columns) |col| {
                const cell: []const markdown.Inline = if (col < row.len) row[col] else &.{};
                _ = self.drawWrapped(
                    arena,
                    hdc,
                    layouts[r * columns + col],
                    cell,
                    cx,
                    y,
                    line_h,
                    widths[col],
                    table.alignments[col],
                    0,
                    false,
                    draw,
                );
                cx += widths[col] + col_gap;
            }
            y += row_h;
            if (r + 1 < table.rows.len) y += row_gap;
        }

        return y - y0;
    }

    fn inlineLineWidth(self: *BannerOverlay, hdc: w32.HDC, segs: []const markdown.Inline, force_bold: bool) i32 {
        return self.cellNaturalWidth(hdc, segs, 0, force_bold);
    }

    fn alignedX(x0: i32, col_w: i32, content_w: i32, alignment: ?markdown.ColumnAlignment) i32 {
        const a = alignment orelse .leading;
        return switch (a) {
            .leading => x0,
            .center => x0 + @max(0, @divTrunc(col_w - content_w, 2)),
            .trailing => x0 + @max(0, col_w - content_w),
        };
    }

    fn drawHLine(self: *BannerOverlay, hdc: w32.HDC, x1: i32, x2: i32, y: i32) void {
        const pen = w32.CreatePen(0, 1, self.divider); // PS_SOLID
        if (pen) |p| {
            const prev = w32.SelectObject(hdc, p);
            _ = w32.MoveToEx(hdc, x1, y, null);
            _ = w32.LineTo(hdc, x2, y);
            _ = w32.SelectObject(hdc, prev);
            _ = w32.DeleteObject(p);
        }
    }

    /// Height + draw of one list block: markers share a gutter sized to
    /// the widest marker so all item content left-aligns. An item whose
    /// content is wider than what is left of `avail_w` wraps, and its
    /// continuation lines start at the SAME gutter-relative x as its first
    /// line — never back under the marker (T377).
    fn renderList(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        items: []const markdown.ListItem,
        x0: i32,
        y0: i32,
        avail_w: i32,
        draw: bool,
    ) i32 {
        const line_h = self.px(LINE_H);
        const row_gap = self.px(ROW_GAP);
        const dot = self.px(5.0);
        const check = self.px(CHECK_SIDE);

        var gutter: i32 = 0;
        for (items) |item| {
            const wd: i32 = switch (item.marker) {
                .checkbox => check,
                .bullet => dot,
                .ordered => |n| blk: {
                    var buf: [12]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}.", .{n}) catch break :blk 0;
                    break :blk self.measureSeg(hdc, s, .{}, null, 0, false).cx;
                },
            };
            gutter = @max(gutter, wd);
        }

        // Content column: everything right of the shared marker gutter.
        const content_x = x0 + gutter + self.px(GUTTER_GAP);
        const content_w = @max(avail_w - (content_x - x0), 0);

        var y = y0;
        for (items, 0..) |item, idx| {
            if (draw) {
                switch (item.marker) {
                    .checkbox => |checked| {
                        const mx = x0 + @divTrunc(gutter - check, 2);
                        _ = self.drawCheckbox(hdc, mx, y, line_h, checked, true);
                    },
                    .bullet => {
                        // A drawn dot sizes predictably vs the "•" glyph
                        // (Mac parity). RoundRect with full corner radius
                        // is a filled circle.
                        const mx = x0 + @divTrunc(gutter - dot, 2);
                        const my = y + @divTrunc(line_h - dot, 2);
                        const brush = w32.CreateSolidBrush(self.secondary());
                        const pen = w32.CreatePen(0, 1, self.secondary());
                        if (brush != null and pen != null) {
                            const pb = w32.SelectObject(hdc, @ptrCast(brush.?));
                            const pp = w32.SelectObject(hdc, pen.?);
                            _ = w32.RoundRect(hdc, mx, my, mx + dot, my + dot, dot, dot);
                            _ = w32.SelectObject(hdc, pp);
                            _ = w32.SelectObject(hdc, pb);
                        }
                        if (brush) |b| _ = w32.DeleteObject(@ptrCast(b));
                        if (pen) |p| _ = w32.DeleteObject(p);
                    },
                    .ordered => |n| {
                        var buf: [12]u8 = undefined;
                        if (std.fmt.bufPrint(&buf, "{d}.", .{n})) |s| {
                            const mw = self.measureSeg(hdc, s, .{}, null, 0, false).cx;
                            const mx = x0 + @divTrunc(gutter - mw, 2);
                            const prev_color = w32.SetTextColor(hdc, self.secondary());
                            var wbuf: [24]u16 = undefined;
                            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, s) catch 0;
                            if (wlen > 0) {
                                const font = self.fontFor(.{}, 0);
                                const prev_font = w32.SelectObject(hdc, font);
                                var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
                                _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
                                _ = w32.TextOutW(hdc, mx, y + @divTrunc(line_h - size.cy, 2), &wbuf, @intCast(wlen));
                                _ = w32.SelectObject(hdc, prev_font);
                            }
                            _ = w32.SetTextColor(hdc, prev_color);
                        } else |_| {}
                    },
                }
            }
            const lay = self.layoutInline(arena, hdc, item.content, wrapWidth(content_w), 0, false, CellWrap.shipped);
            y += self.drawWrapped(
                arena,
                hdc,
                lay,
                item.content,
                content_x,
                y,
                line_h,
                content_w,
                .leading,
                0,
                false,
                draw,
            );
            if (idx + 1 < items.len) y += row_gap;
        }
        return y - y0;
    }

    /// Walk all blocks: measure (draw=false) or paint (draw=true).
    /// Returns total content height. (`x0`, `y0`) is the content origin in
    /// client coords (the card's inner top-left) and `content_w` is the
    /// width available to it (bounds the rule width).
    fn renderContent(
        self: *BannerOverlay,
        hdc: w32.HDC,
        x0: i32,
        y0: i32,
        content_w: i32,
        draw: bool,
    ) i32 {
        const line_h = self.px(LINE_H);
        const block_gap = self.px(BLOCK_GAP);
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

        // One scratch arena for the whole walk: every block's wrap pass
        // allocates its tokens and line ranges here and they only have to
        // outlive this call.
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const arena = scratch.allocator();

        var y: i32 = y0;
        for (self.blocks, 0..) |block, bi| {
            if (bi > 0) y += block_gap;
            const h: i32 = switch (block) {
                .text => |segs| blk: {
                    const lay = self.layoutInline(arena, hdc, segs, wrapWidth(content_w), 0, false, CellWrap.shipped);
                    break :blk self.drawWrapped(arena, hdc, lay, segs, x0, y, line_h, content_w, .leading, 0, false, draw);
                },
                .heading => |h| blk: {
                    const hpx = heading_px[@min(h.level - 1, 5)];
                    const hl = self.px(hpx * 4.0 / 3.0);
                    const sc = @min(h.level, 6);
                    const lay = self.layoutInline(arena, hdc, h.content, wrapWidth(content_w), sc, false, CellWrap.shipped);
                    break :blk self.drawWrapped(arena, hdc, lay, h.content, x0, y, hl, content_w, .leading, sc, false, draw);
                },
                .rule => blk: {
                    if (draw) self.drawHLine(hdc, x0, x0 + content_w, y);
                    break :blk 1;
                },
                .list => |items| self.renderList(arena, hdc, items, x0, y, content_w, draw),
                .table => |t| self.renderTable(arena, hdc, t, x0, y, content_w, draw),
            };
            y += h;
        }
        return y - y0;
    }

    /// Chevron toggle hit rect (the card's top-right corner), in client
    /// coords — inside the card, not the band (T131).
    /// The chevron button's box — ONE definition, used by both the paint and
    /// the hit test. Keeping these in two places is precisely how a button
    /// ends up looking right and being unclickable (T204 deliverable 5).
    fn chevronBox(self: *BannerOverlay, client_w: i32) icon_button.Rect {
        // The shared chrome icon-button target (T204), not a local 24px
        // guess — this button has to be the same size and shape as the tab
        // strip's, because the user reads them as one set of controls.
        const side = icon_button.Metrics.init(self.scale).target;
        const margin = self.px(MARGIN);
        // Vertically centered on the card's first content line, which is
        // where the chevron has always sat.
        const cy = margin + self.px(PAD) + @divTrunc(self.px(LINE_H), 2);
        const top = cy - @divTrunc(side, 2);
        return .{
            .left = client_w - margin - side,
            .top = top,
            .right = client_w - margin,
            .bottom = top + side,
        };
    }

    /// Paint the band: the glass card backdrop (pane background + shadow +
    /// card), then the blocks inside the card, then collapse fade +
    /// chevron. Rebuilds the link hit rects as a side effect.
    fn paint(self: *BannerOverlay, hdc: w32.HDC) void {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &client) == 0) return;

        // Debug-build oracle for pane-banner.ps1's T833 assertions, and the
        // record of what the pixels now show. `banner collapse h=` says which
        // frame the animation WANTED; this says which frame was drawn, and
        // the two only agreed in the collapse direction before T833.
        self.painted_h = self.paintedCardHeight();
        log.debug("banner paint h={} cw={} pw={}", .{
            self.painted_h,
            client.right,
            self.pane_w,
        });

        // The band the CARD occupies. The whole client when settled; while
        // the card animates OPEN it is shorter than the window, which is
        // already sized to the taller settled band (T149).
        var band = client;
        if (self.collapse_anim != null) {
            const h = banner_layout.bandHeight(
                self.paintedCardHeight(),
                self.px(MARGIN),
            );
            if (h < band.bottom) {
                band.bottom = h;
                // Whatever the shrunken card no longer covers is band
                // background — the pane's own color, the same thing the
                // margins around the card show.
                self.fillBand(hdc, client);
            }
        }

        self.paintCardBackdrop(hdc, band);

        self.links.clearRetainingCapacity();

        // Content lives inside the card: one margin, then one padding —
        // and stops short of the chevron's reserved column (T377).
        const inner = self.px(MARGIN) + self.px(PAD);
        const content_w = self.contentWidthFor(client.right);

        // Clip everything the content walker draws to the card's own
        // rounded shape, so a collapsed banner's overflow (and any block
        // wider than the card) stops at the card edge instead of spilling
        // across the margin the terminal sees.
        const clip = self.cardClipRegion(band);
        defer if (clip) |rgn| {
            _ = w32.SelectClipRgn(hdc, null);
            _ = w32.DeleteObject(rgn);
        };
        if (clip) |rgn| _ = w32.SelectClipRgn(hdc, rgn);

        _ = self.renderContent(hdc, inner, inner, content_w, true);

        // Content overflows the card — collapsed, and every frame of a
        // collapse or expand on the way there — so its tail dissolves into
        // the card fill instead of being guillotined by the clip region
        // (Mac mask parity). ONE rule for all three states: the card is
        // shorter than the content wants.
        const wanted = self.px(PAD) * 2 + self.ensureContentHeight();
        const shown = (band.bottom - band.top) - self.px(MARGIN) * 2;
        if (shown < wanted) self.paintCollapseFade(hdc, band);

        if (self.collapsible) self.paintChevron(hdc, client);
    }

    /// Fill `rect` with the pane's own background — the color the band
    /// around the card shows. Only needed while the card animates SHORTER
    /// than the window (T149): every settled paint has the card backdrop
    /// covering every pixel of the client already.
    fn fillBand(self: *BannerOverlay, hdc: w32.HDC, rect: w32.RECT) void {
        const brush = w32.CreateSolidBrush(w32.RGB(
            self.pane_bg_rgb.r,
            self.pane_bg_rgb.g,
            self.pane_bg_rgb.b,
        )) orelse return;
        defer _ = w32.DeleteObject(@ptrCast(brush));
        var r = rect;
        _ = w32.FillRect(hdc, &r, brush);
    }

    /// The card's rounded shape as a GDI region (client coords), for
    /// clipping content to it. Null when the region cannot be created —
    /// callers then draw unclipped rather than not at all.
    fn cardClipRegion(self: *BannerOverlay, client: w32.RECT) ?*anyopaque {
        const margin = self.px(MARGIN);
        const r = self.px(card.RADIUS);
        const left = client.left + margin;
        const top = client.top + margin;
        const right = client.right - margin;
        const bottom = client.bottom - margin;
        if (right <= left or bottom <= top) return null;
        return w32.CreateRoundRectRgn(left, top, right + 1, bottom + 1, r * 2, r * 2);
    }

    /// Blit the cached glass-card backdrop, regenerating it when the band
    /// size, the pane background, or the DPI scale changed (T131). Falls
    /// back to a flat card-fill rect if the DIB cannot be created.
    fn paintCardBackdrop(self: *BannerOverlay, hdc: w32.HDC, client: w32.RECT) void {
        const w = @max(client.right - client.left, 1);
        const h = @max(client.bottom - client.top, 1);

        const stale = self.card_dc == null or self.card_w != w or self.card_h != h or
            !std.meta.eql(self.card_bg, self.pane_bg_rgb) or self.card_scale != self.scale;
        if (stale) self.buildCardSurface(hdc, w, h);

        if (self.card_dc) |mem| {
            _ = w32.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, w32.SRCCOPY);
            return;
        }
        if (self.bg_brush) |brush| _ = w32.FillRect(hdc, &client, brush);
    }

    fn buildCardSurface(self: *BannerOverlay, hdc: w32.HDC, w: i32, h: i32) void {
        self.releaseCardSurface();

        var bmi = std.mem.zeroes(w32.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;

        const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
        var bits: ?*anyopaque = null;
        const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(mem_dc);
            return;
        };
        const raw = bits orelse {
            _ = w32.DeleteObject(bmp);
            _ = w32.DeleteDC(mem_dc);
            return;
        };
        _ = w32.SelectObject(mem_dc, bmp);

        const pixels = @as([*]u32, @ptrCast(@alignCast(raw)));
        const count: usize = @intCast(w * h);
        card.render(
            pixels[0..count],
            card.Metrics.init(w, h, self.scale),
            self.pane_bg_rgb,
        );

        self.card_dc = mem_dc;
        self.card_bmp = bmp;
        self.card_bits = pixels;
        self.card_w = w;
        self.card_h = h;
        self.card_bg = self.pane_bg_rgb;
        self.card_scale = self.scale;
    }

    fn releaseCardSurface(self: *BannerOverlay) void {
        if (self.card_dc) |dc| _ = w32.DeleteDC(dc);
        if (self.card_bmp) |b| _ = w32.DeleteObject(b);
        self.card_dc = null;
        self.card_bmp = null;
        self.card_bits = null;
        self.card_w = 0;
        self.card_h = 0;
        self.card_scale = 0;
    }

    /// Fade the tail of collapsed content into the card fill: an
    /// alpha-ramp DIB of the fill color blended over the lower portion of
    /// the CARD (Mac: linear mask opaque→clear from 55% to 100%). Spans the
    /// card, not the band — the margins around it are pane background.
    fn paintCollapseFade(self: *BannerOverlay, hdc: w32.HDC, client: w32.RECT) void {
        const margin = self.px(MARGIN);
        const card_top = client.top + margin;
        const card_bottom = client.bottom - margin;
        const card_h = card_bottom - card_top;
        if (card_h <= 0) return;
        const fade_top = card_top + @divTrunc(card_h * 45, 100);
        const fade_h = card_bottom - fade_top;
        if (fade_h <= 0) return;

        var bmi = std.mem.zeroes(w32.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = 1;
        bmi.bmiHeader.biHeight = -fade_h; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;

        const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bmp);
        const pixels = @as([*]u32, @ptrCast(@alignCast(bits orelse return)))[0..@intCast(fade_h)];
        for (pixels, 0..) |*p, row| {
            const a: u32 = @min(255, (row * 255) / @as(usize, @intCast(fade_h)));
            // Premultiplied BGRA of the strip bg at alpha a.
            const r = (@as(u32, self.bg_rgb.r) * a) / 255;
            const g = (@as(u32, self.bg_rgb.g) * a) / 255;
            const b = (@as(u32, self.bg_rgb.b) * a) / 255;
            p.* = (a << 24) | (r << 16) | (g << 8) | b;
        }

        const old = w32.SelectObject(mem_dc, bmp);
        defer _ = w32.SelectObject(mem_dc, old);
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };
        _ = w32.AlphaBlend(
            hdc,
            client.left,
            fade_top,
            client.right - client.left,
            fade_h,
            mem_dc,
            0,
            0,
            1,
            fade_h,
            blend,
        );
    }

    /// The collapse/expand chevron in the top-right corner (Mac parity:
    /// chevron.up when expanded, chevron.down when collapsed).
    fn paintChevron(self: *BannerOverlay, hdc: w32.HDC, client: w32.RECT) void {
        const ib = icon_button.Metrics.init(self.scale);
        const box = self.chevronBox(client.right);

        // T204: the same lit fill every other icon button gets. The chevron
        // used to have none, so it was the one control in the chrome that
        // gave no feedback that it was a button at all.
        const state: icon_button.State = if (self.hover_chevron) .hover else .normal;
        const glyph: icon_button.Glyph = if (self.collapsed) .chevron_down else .chevron_up;
        if (icon_button.paintsFill(state) and icon_button.lightsFill(glyph)) {
            // Shade from the CARD's fill, not the pane background: the
            // chevron sits on the card, so that is the surface its hover has
            // to lift off.
            const base = card.fillColor(self.pane_bg_rgb);
            const d = icon_button.fillDelta(state, !color_math.isLight(self.pane_bg_rgb));
            const color = w32.RGB(
                icon_button.shadeChannel(base.r, d),
                icon_button.shadeChannel(base.g, d),
                icon_button.shadeChannel(base.b, d),
            );
            const f = icon_button.fillRegion(ib, box);
            if (w32.CreateRoundRectRgn(f.left, f.top, f.right, f.bottom, f.ellipse, f.ellipse)) |rgn| {
                defer _ = w32.DeleteObject(rgn);
                if (w32.CreateSolidBrush(color)) |brush| {
                    defer _ = w32.DeleteObject(@ptrCast(brush));
                    _ = w32.FillRgn(hdc, rgn, @ptrCast(brush));
                }
            }
        }

        // `glyphTarget`, not `targetBox` — see the note at Window.paintIconButton
        // (T209): centering has to be something T204_NEUTERED can take away.
        icon_paint.glyph(hdc, ib, icon_button.glyphTarget(ib, box, glyph), glyph, self.secondary());
    }

    /// Hot-track the chevron. Returns true when the hover changed, so the
    /// caller can repaint only then — a banner that invalidates on every
    /// WM_MOUSEMOVE would repaint its whole composited card continuously.
    fn updateChevronHover(self: *BannerOverlay, x: i32, y: i32) bool {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &client) == 0) return false;
        const hot = self.collapsible and self.chevronBox(client.right).containsPoint(x, y);
        if (hot == self.hover_chevron) return false;
        self.hover_chevron = hot;
        // Debug-build oracle for pane-banner.ps1's T209 chevron section. Same
        // reason as the strip's (`tab hover ...` in Window.zig): the hover
        // cannot survive to a capture on the background test desktop, so the
        // TRIGGER is read from the log and the FILL is probed separately.
        log.debug("banner chevron hover={}", .{hot});
        return true;
    }

    fn toggleCollapsed(self: *BannerOverlay) void {
        if (!self.collapsible) return;
        // Start the animation from where the card IS, not from the settled
        // height of the state being left: a second click mid-flight has to
        // reverse out of the current frame, or the card jumps before it
        // moves.
        const from = self.paintedCardHeight();
        self.collapsed = !self.collapsed;
        // Debug-build oracle for pane-banner.ps1's T149 section, logged HERE
        // rather than inside `startCollapseAnim`: the toggle happens whether
        // or not an animation follows it, so its line is what tells a release
        // build (no oracle at all — skip) apart from a build whose animation
        // stopped working (a toggle with no frames after it — fail). Same
        // deal as `banner chevron hover=`: 180ms of card heights cannot
        // survive to a screen capture on the background test desktop.
        log.debug("banner collapse from={} to={}", .{ from, self.cardHeight() });
        self.startCollapseAnim(from);
        // The strip height changed: re-run the owning window's layout so
        // the terminal band under the strip grows/shrinks to match (T101).
        // The layout pass repositions this popup via updatePaneBanners.
        //
        // What it reserves is the SETTLED height, so the terminal reflows
        // in ONE step per toggle while the card animates over it (T149,
        // Mac 89465f320). An inset that tracked the animation would drag
        // the whole grid through eleven resizes per click — the flicker
        // Mac's hidden measurement copy exists to avoid.
        App.relayoutOwnerWindow(self.owner);
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    /// Begin a card resize from `from_h` to the settled `cardHeight()`.
    /// Silently does nothing (leaving the instant toggle) when the user has
    /// turned in-window animation off, when the clock is unavailable, or
    /// when there is no distance to cover.
    fn startCollapseAnim(self: *BannerOverlay, from_h: i32) void {
        self.stopCollapseAnim();
        if (T149_NEUTERED) return;
        if (from_h == self.cardHeight()) return;
        if (!App.clientAreaAnimationsEnabled()) return;
        const start = std.time.Instant.now() catch return;
        self.collapse_anim = .{ .from_h = from_h, .start = start };
        _ = w32.SetTimer(
            self.hwnd,
            COLLAPSE_TIMER_ID,
            banner_layout.COLLAPSE_TICK_MS,
            null,
        );
    }

    fn stopCollapseAnim(self: *BannerOverlay) void {
        if (self.collapse_anim == null) return;
        self.collapse_anim = null;
        _ = w32.KillTimer(self.hwnd, COLLAPSE_TIMER_ID);
    }

    /// ~60Hz heartbeat while the card resizes (T149): re-glue the popup to
    /// the animated height and repaint. The band the LAYOUT reserved does
    /// not move — only this window does, which is what keeps the terminal
    /// grid out of the animation.
    fn onCollapseTick(self: *BannerOverlay) void {
        const done = self.collapseProgress() == null;
        // The frame this tick is about to draw, for pane-banner.ps1's T149
        // section (the other half of the oracle `toggleCollapsed` opens).
        // Read BEFORE the animation is retired, so the last line logged is
        // the settled height rather than a frame short of it.
        log.debug("banner collapse h={}", .{self.paintedCardHeight()});
        if (done) self.stopCollapseAnim();
        // Dirty the client for THIS frame's card height (T833). The window
        // resize `updatePosition` relies on to repaint only happens in the
        // collapse direction: expanding, the layout reserved the settled
        // (taller) band in one step at the toggle, so every frame is drawn
        // inside a window whose size never changes — no CS_VREDRAW
        // invalidate, no repaint, and the card froze on whichever frame the
        // toggle's own invalidate happened to catch. The user saw an expand
        // that left a stale, half-open card behind.
        //
        // Keyed on the height that was actually PAINTED, not on the one the
        // last tick wanted, so a frame that rounds to the same height still
        // has nothing to draw — the property the resize path had for free.
        const dirty = !T833_NEUTERED and self.paintedCardHeight() != self.painted_h;
        if (dirty) _ = w32.InvalidateRect(self.hwnd, null, 1);
        // `updatePosition` invalidates and repaints synchronously whenever
        // the height actually changed, which is every frame of a COLLAPSE.
        self.updatePosition(self.scale);
        // ...and an expand frame is still dirty here, so finish it in the
        // same tick rather than leaving the card a pumped WM_PAINT behind
        // the geometry it is glued to (T456's reasoning, one direction over).
        if (dirty) _ = w32.UpdateWindow(self.hwnd);
    }

    fn linkAt(self: *const BannerOverlay, x: i32, y: i32) ?[]const u8 {
        for (self.links.items) |l| {
            if (x >= l.rect.left and x < l.rect.right and
                y >= l.rect.top and y < l.rect.bottom) return l.url;
        }
        return null;
    }

    /// Hot-track the links (T165). Returns true when the hover CHANGED, so
    /// the caller repaints only then — the same contract `updateChevronHover`
    /// keeps, and for the same reason: a card that invalidates on every
    /// WM_MOUSEMOVE repaints its whole composite continuously.
    fn updateLinkHover(self: *BannerOverlay, x: i32, y: i32) bool {
        const hot: ?[*]const u8 = if (self.linkAt(x, y)) |url| url.ptr else null;
        if (hot == self.hover_link) return false;
        self.hover_link = hot;
        // Debug-build oracle for pane-banner.ps1's T165 section, the same
        // deal as `banner chevron hover=`: the affordance cannot survive to a
        // capture on the background test desktop, so the TRIGGER is read from
        // the log and the RULE is probed separately.
        log.debug("banner link hover={}", .{hot != null});
        return true;
    }

    /// Right-click on a link: the action menu (T165). Every verb the modifier
    /// scheme can reach, plus Copy, which has no chord — the discoverable
    /// form of `banner_link.clickAction`, with the left-click default first
    /// by contract.
    fn openLinkMenu(self: *BannerOverlay, url: []const u8, x: i32, y: i32) void {
        const menu = w32.CreatePopupMenu() orelse return;
        defer _ = w32.DestroyMenu(menu);

        const kind = banner_link.kindOf(url);
        var buf: [banner_link.MAX_ITEMS]banner_link.Item = undefined;
        for (banner_link.build(kind, &buf)) |item| switch (item) {
            .separator => _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null),
            .cmd => |c| _ = w32.AppendMenuW(
                menu,
                w32.MF_STRING,
                @intFromEnum(c.id),
                c.title.ptr,
            ),
        };

        var pt = w32.POINT{ .x = x, .y = y };
        _ = w32.ClientToScreen(self.hwnd, &pt);

        // The overlay is WS_EX_NOACTIVATE and answers WM_MOUSEACTIVATE with
        // MA_NOACTIVATE, so the right-click that got us here did NOT bring
        // its window forward. A tracked menu whose owner is not the
        // foreground window is the documented case where an outside click
        // fails to dismiss it — hence the two halves of the MSDN workaround:
        // foreground the top-level window before, post it a message after.
        // This is `SetForegroundWindow`, not `SetFocus`: the T48 deadlock was
        // re-entrant IME/CTF focus routing, which this does not enter.
        const top: ?w32.HWND = if (self.surface) |s| s.parent_window.hwnd else null;
        if (top) |t| _ = w32.SetForegroundWindow(t);
        const cmd = w32.TrackPopupMenuEx(
            menu,
            w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
            pt.x,
            pt.y,
            // Owned by the SURFACE window, not by this popup: a menu owned by
            // a never-active window gets no keyboard.
            self.owner,
            null,
        );
        if (top) |t| _ = w32.PostMessageW(t, w32.WM_NULL, 0, 0);

        const id = std.meta.intToEnum(
            banner_link.Id,
            @as(usize, @intCast(cmd)),
        ) catch return; // 0 = dismissed without choosing
        self.performLinkAction(banner_link.action(id), url);
    }

    /// Run one link action. The single dispatch point for both the click
    /// scheme and the menu, so a row can never do something its chord does
    /// not (`banner_link` maps both onto this enum for exactly that reason).
    fn performLinkAction(self: *BannerOverlay, act: banner_link.Action, url: []const u8) void {
        switch (act) {
            .open_with_system => self.shellExecute(null, url),
            .reveal_in_explorer => {
                // `explorer /select,<path>` opens the containing folder with
                // the file SELECTED — the Windows analog of Mac's
                // `activateFileViewerSelecting`. A click reveals, never
                // opens, so it can't launch whatever app claims the
                // extension.
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const path = banner_link.filePath(url, &path_buf) orelse return;
                var arg_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
                const args = std.fmt.bufPrint(&arg_buf, "/select,\"{s}\"", .{path}) catch return;
                self.shellExecuteArgs("explorer.exe", args);
            },
            .open_in_side_pane => {
                // No pane to split off ⇒ hand it to the shell rather than
                // dropping the click on the floor (Mac's `guard … else
                // { openWithSystem(url); return }`).
                const surface = self.surface orelse return self.shellExecute(null, url);
                surface.openViewerSplitBeside(self.viewerLocation(url) orelse return, false);
            },
            .open_in_new_window => self.openViewerWindow(url),
            .copy => self.copyLink(url),
            .focus_target => self.focusTarget(url),
        }
    }

    /// A `ghoztty://` link: raise the window or pane it names, in process
    /// (T695). Never leaves the app, so a link clicked in a debug build's
    /// banner focuses a window of THAT build rather than whichever one
    /// registered the scheme with the shell.
    fn focusTarget(self: *BannerOverlay, url: []const u8) void {
        const surface = self.surface orelse return;
        // The banner's own window owns the warning if the target is gone, so
        // it reads as "that link failed" rather than as an app-wide problem.
        _ = surface.app.handleUrlSchemeLink(
            surface.parent_window.hwnd,
            self.scale,
            url,
        );
    }

    /// What a viewer pane is pointed at. `ViewerPane` reads any
    /// non-`http`/`about` location as a literal filesystem path (Mac's
    /// `viewerLocation` makes the same call), so a file link hands over its
    /// decoded path — `file:///C:/a.md` would send it looking for a file by
    /// that name. Returns a slice into `self.viewer_path_buf`, valid until
    /// the next call.
    fn viewerLocation(self: *BannerOverlay, url: []const u8) ?[]const u8 {
        if (banner_link.kindOf(url) != .file) return url;
        return banner_link.filePath(url, &self.viewer_path_buf);
    }

    /// A new one-pane Ghoztty viewer window — the same tree `+new-window
    /// --view=<location>` builds.
    fn openViewerWindow(self: *BannerOverlay, url: []const u8) void {
        const surface = self.surface orelse return self.shellExecute(null, url);
        const location = self.viewerLocation(url) orelse return;
        _ = surface.app.createWindow(.{ .viewer_open = .{
            .location = location,
            .origin_directory = surface.pwd,
        } }) catch |err| {
            log.warn("banner link: viewer window failed err={}", .{err});
        };
    }

    /// Copy the link: a plain path for a file (a `file://` string is useless
    /// in a shell or another editor), the full URL for anything web — Mac's
    /// `pasteboardString(for:)` rule.
    fn copyLink(self: *BannerOverlay, url: []const u8) void {
        const surface = self.surface orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const text = if (banner_link.kindOf(url) == .file)
            (banner_link.filePath(url, &path_buf) orelse return)
        else
            url;
        // `ClipboardContent.data` is sentinel-terminated, so the slice is
        // copied into a terminated buffer rather than passed through.
        var z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (text.len >= z_buf.len) return;
        @memcpy(z_buf[0..text.len], text);
        z_buf[text.len] = 0;
        const z: [:0]const u8 = z_buf[0..text.len :0];
        // `confirm = false`: this is the user's own menu choice, not a
        // program writing the clipboard behind their back — the case
        // `clipboard-write = ask` exists to gate.
        surface.setClipboard(
            .standard,
            &.{.{ .mime = "text/plain", .data = z }},
            false,
        ) catch |err| log.warn("banner link: copy failed err={}", .{err});
    }

    fn shellExecute(self: *BannerOverlay, verb: ?[*:0]const u16, target: []const u8) void {
        _ = self;
        var wtarget: [2048:0]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wtarget, target) catch return;
        if (wlen >= wtarget.len) return;
        wtarget[wlen] = 0;
        _ = w32.ShellExecuteW(
            null,
            verb orelse std.unicode.utf8ToUtf16LeStringLiteral("open"),
            @ptrCast(&wtarget),
            null,
            null,
            w32.SW_SHOW,
        );
    }

    fn shellExecuteArgs(self: *BannerOverlay, exe: []const u8, args: []const u8) void {
        _ = self;
        var wexe: [260:0]u16 = undefined;
        const elen = std.unicode.utf8ToUtf16Le(&wexe, exe) catch return;
        if (elen >= wexe.len) return;
        wexe[elen] = 0;
        var wargs: [2048:0]u16 = undefined;
        const alen = std.unicode.utf8ToUtf16Le(&wargs, args) catch return;
        if (alen >= wargs.len) return;
        wargs[alen] = 0;
        _ = w32.ShellExecuteW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("open"),
            @ptrCast(&wexe),
            @ptrCast(&wargs),
            null,
            w32.SW_SHOW,
        );
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (T456): every pixel of the card is laid
        // out against the CURRENT band size — the rounded rim and its
        // shadow sit on the edges, the chevron column is measured in from
        // the right, and each block is word-wrapped to the content width.
        // So a size change makes the whole card stale, and repainting only
        // the sliver Windows uncovers leaves the rest drawn at the old
        // geometry. That is the "unpainted gap around the banner" a
        // divider drag shows. DimOverlay gets away with `.style = 0`
        // because it is a flat fill, where a partial repaint is
        // indistinguishable from a full one; a card is not.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = bannerWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // painted in WM_PAINT with the cached brush
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn bannerWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*BannerOverlay = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_ERASEBKGND => return 1, // WM_PAINT covers everything

        w32.WM_TIMER => {
            if (wparam == COLLAPSE_TIMER_ID) self.onCollapseTick();
            return 0;
        },

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paint(hdc);
            return 0;
        },

        // T204: the chevron is an icon button, so it hot-tracks like one.
        // The overlay had no WM_MOUSEMOVE handling at all before this — which
        // is the mechanical reason the chevron could not have a hover, not a
        // styling oversight.
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
            if (!self.mouse_tracked) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.mouse_tracked = true;
            }
            var dirty = self.updateChevronHover(x, y);
            // Not short-circuited: BOTH hovers must be updated on every move,
            // or moving straight from the chevron onto a link leaves the
            // first one latched lit.
            if (self.updateLinkHover(x, y)) dirty = true;
            if (dirty) _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.mouse_tracked = false;
            if (self.hover_link != null) {
                self.hover_link = null;
                log.debug("banner link hover={}", .{false});
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            if (self.hover_chevron) {
                self.hover_chevron = false;
                // Logged here as well as in `updateChevronHover` (T209): the
                // un-hover reaches the state through EITHER path, and on the
                // background test desktop it is almost always this one. A
                // clear that happens without being reported reads, from the
                // outside, exactly like a hover that latched forever.
                log.debug("banner chevron hover={}", .{false});
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                _ = w32.ScreenToClient(hwnd, &pt);
                const cursor = if (self.linkAt(pt.x, pt.y) != null)
                    w32.LoadCursorW(null, w32.IDC_HAND)
                else
                    w32.LoadCursorW(null, w32.IDC_ARROW);
                _ = w32.SetCursor(cursor);
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // Right-click a link → the action menu (T165). Anywhere else on the
        // card is left to DefWindowProc: the banner has no menu of its own,
        // and swallowing the click would only make the card feel dead.
        w32.WM_RBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
            if (self.linkAt(x, y)) |url| {
                self.openLinkMenu(url, x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
            if (self.linkAt(x, y)) |url| {
                // MK_CONTROL / MK_SHIFT ride in wparam, which is the state at
                // the time of the click — GetKeyState would answer for now
                // instead, and a modifier released between the button-up and
                // this handler would silently downgrade the action.
                const ctrl = (wparam & w32.MK_CONTROL) != 0;
                const shift = (wparam & w32.MK_SHIFT) != 0;
                self.performLinkAction(
                    banner_link.clickAction(banner_link.kindOf(url), ctrl, shift),
                    url,
                );
            } else if (self.collapsible) {
                // Mac parity: a tap anywhere on a multi-line banner
                // toggles collapse.
                self.toggleCollapsed();
            } else {
                // A click on a single-line strip focuses the pane under
                // it, like a click on the pane itself (T48: never
                // SetFocus in a WndProc).
                App.deferSetFocus(self.owner);
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

// T283: every negative control in this module ships CLEAR, and the T123 one
// has something to change when it is set. Four of the eight `*_NEUTERED`
// flags in `src/apprt/win32/` pinned their shipped value with a unit test
// and four did not — including all three here, so a flag left `true` by an
// experiment would have shipped a degraded banner and gone red only in an
// acceptance script somebody remembered to run.
//
// The second assertion is the part that is not bookkeeping: a control whose
// two worlds are the SAME value cannot adjudicate anything, which is the
// `glyphCentered()`/`universalHover()` failure (T209, T282) expressed as
// data rather than as a call-site audit.
test "T283: the banner's negative controls are clear and non-empty" {
    try std.testing.expect(!T123_NEUTERED);
    try std.testing.expect(!T377_NEUTERED);
    try std.testing.expect(!T149_NEUTERED);

    const CellWrap = BannerOverlay.CellWrap;
    try std.testing.expectEqual(CellWrap.shipped, CellWrap.forCell());
    try std.testing.expect(!std.meta.eql(CellWrap.shipped, CellWrap.pre_t123));
    try std.testing.expect(CellWrap.shipped.break_wide and CellWrap.shipped.cap_lines);
}

// T456: a WIDTH change makes the whole card stale, not just the strip
// Windows uncovers. The card's rounded rim, its shadow, its chevron column
// and every wrapped line are laid out against the full width — repaint the
// exposed sliver only, as a class with no CS_HREDRAW/CS_VREDRAW does, and
// the rest of the card keeps the geometry it had before the drag. That is
// the "unpainted gap around the banner" a divider drag shows.
//
// Asserted against a real window because this IS window-class behavior:
// the thing under test is what Windows invalidates, which no pure function
// can stand in for.
test "banner class: a resize invalidates the whole card, not the exposed strip" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClassOnce(hinst) catch return error.SkipZigTest;

    // ON-SCREEN and shown, at layered alpha 0. Both halves are load-bearing:
    // a window parked outside every monitor has an empty visible region, so
    // Windows invalidates nothing on a resize and the test passes for the
    // wrong reason (measured — that is what this test did first). Alpha 0
    // keeps it genuinely visible to the window manager while painting
    // nothing a user could see, so a test run never flashes a card.
    const hwnd = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
        WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        400,
        200,
        null,
        null,
        hinst,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(hwnd);
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, 0, w32.LWA_ALPHA);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);

    // Start from a clean slate: nothing pending, so whatever the resize
    // invalidates is the only thing in the update region afterwards.
    _ = w32.ValidateRect(hwnd, null);
    try std.testing.expectEqual(@as(i32, 0), w32.GetUpdateRect(hwnd, null, 0));

    // Widen by 40px — the amount a divider drag moves in a few frames.
    _ = w32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        440,
        200,
        w32.SWP_NOMOVE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
    );

    var upd: w32.RECT = undefined;
    try std.testing.expect(w32.GetUpdateRect(hwnd, &upd, 0) != 0);
    var client: w32.RECT = undefined;
    try std.testing.expect(w32.GetClientRect(hwnd, &client) != 0);
    // The whole client, not the 40px sliver.
    try std.testing.expectEqual(client.right - client.left, upd.right - upd.left);
    try std.testing.expectEqual(client.bottom - client.top, upd.bottom - upd.top);
}

// T456, second half: the repaint must land in the SAME layout pass that
// resized the strip. `updatePosition` runs inside `Window.layoutSplits`,
// which a divider drag re-runs per mouse-move — so a card left waiting for
// the next pumped WM_PAINT is drawn a whole drag frame behind the pane it
// is glued to. Asserting "nothing still pending" is how you check that from
// the outside: an update region surviving the call IS the lag.
test "banner overlay: a size-changing updatePosition repaints in the same pass" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClassOnce(hinst) catch return error.SkipZigTest;

    // Stand-in owner — `updatePosition` reads only its visibility and rect.
    // Alpha 0, on-screen, for the reason the class test documents.
    const owner = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
        WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        300,
        600,
        200,
        null,
        null,
        hinst,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(owner);
    _ = w32.SetLayeredWindowAttributes(owner, 0, 0, w32.LWA_ALPHA);
    _ = w32.ShowWindow(owner, w32.SW_SHOWNOACTIVATE);

    const overlay = BannerOverlay.create(std.testing.allocator, null, owner, hinst) catch
        return error.SkipZigTest;
    defer overlay.destroy();
    // Claim the alpha slot before updatePosition can set STRIP_ALPHA, so the
    // card stays invisible to a human watching the test run.
    _ = w32.SetLayeredWindowAttributes(overlay.hwnd, 0, 0, w32.LWA_ALPHA);
    overlay.alpha_set = true;

    overlay.setText("**Build status**\nA paragraph long enough that its wrap point moves when the pane width does.");

    // Every scale the win32 design system requires: the band height is
    // scale-derived, so a resize at 2.0 moves far more pixels than one at
    // 1.0 and is the case a partial repaint disfigures worst.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        overlay.inset = @intFromFloat(120.0 * scale);
        _ = w32.SetWindowPos(owner, null, 0, 300, 600, 200, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        overlay.updatePosition(scale);
        _ = w32.UpdateWindow(overlay.hwnd); // settle the first paint

        // The divider-drag case: the owner pane's WIDTH changes.
        _ = w32.SetWindowPos(owner, null, 0, 300, 380, 200, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        overlay.updatePosition(scale);

        try std.testing.expectEqual(@as(i32, 0), w32.GetUpdateRect(overlay.hwnd, null, 0));
    }
}

// T833: the OTHER direction of the same seam, and the one nothing covered.
//
// `updatePosition` repaints when the popup's SIZE changes, which is every frame
// of a COLLAPSE — the card shrinks and the window shrinks with it. An EXPAND
// gets no such thing: the toggle relayouts the grid ONCE, to the settled
// (taller) band, so the window is already at its final size before the first
// animated frame and never changes again. Nothing else dirtied the client, so
// the card stayed on whichever frame the toggle's own invalidate happened to
// catch and the user was left looking at a stale, half-open card in a
// full-height band.
//
// The assertion is the painted height MOVING while the window height does not:
// `painted_h` is written by `paint`, so it only advances if a WM_PAINT really
// ran. `GetUpdateRect` == 0 after every tick is the T456 half restated — the
// frame is drawn IN the tick, not a pumped paint later.
test "banner overlay: an expanding card repaints while the window keeps its size" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClassOnce(hinst) catch return error.SkipZigTest;

    const owner = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
        WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        300,
        600,
        200,
        null,
        null,
        hinst,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(owner);
    _ = w32.SetLayeredWindowAttributes(owner, 0, 0, w32.LWA_ALPHA);
    _ = w32.ShowWindow(owner, w32.SW_SHOWNOACTIVATE);

    const overlay = BannerOverlay.create(std.testing.allocator, null, owner, hinst) catch
        return error.SkipZigTest;
    defer overlay.destroy();
    _ = w32.SetLayeredWindowAttributes(overlay.hwnd, 0, 0, w32.LWA_ALPHA);
    overlay.alpha_set = true;

    overlay.setText("**Build status**\nsecond line\nthird line\nfourth line");

    // Settle COLLAPSED, the state a first click leaves behind: the layout has
    // already given the band back to the grid and the card is painted short.
    overlay.collapsed = true;
    overlay.updatePosition(1.0); // teaches it the pane width
    overlay.inset = overlay.stripHeight();
    overlay.updatePosition(1.0);
    _ = w32.InvalidateRect(overlay.hwnd, null, 1);
    _ = w32.UpdateWindow(overlay.hwnd);
    const collapsed_h = overlay.painted_h;
    try std.testing.expect(collapsed_h > 0);

    // The second click: the flip, plus the ONE relayout the toggle issues.
    overlay.collapsed = false;
    overlay.inset = overlay.stripHeight();
    const target = overlay.cardHeight();
    try std.testing.expect(target > collapsed_h);
    overlay.updatePosition(1.0);
    _ = w32.InvalidateRect(overlay.hwnd, null, 1);
    _ = w32.UpdateWindow(overlay.hwnd);

    var before: w32.RECT = undefined;
    try std.testing.expect(w32.GetWindowRect(overlay.hwnd, &before) != 0);

    // Drive the animation by hand rather than through `startCollapseAnim`: no
    // timer to pump, and no dependency on the system's client-area animation
    // setting, which would legitimately turn the whole thing off.
    overlay.collapse_anim = .{
        .from_h = collapsed_h,
        .start = std.time.Instant.now() catch return error.SkipZigTest,
    };

    var saw_intermediate = false;
    var guard: usize = 0;
    while (overlay.collapse_anim != null and guard < 200) : (guard += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        overlay.onCollapseTick();
        if (overlay.painted_h > collapsed_h and overlay.painted_h < target) {
            saw_intermediate = true;
        }
        try std.testing.expectEqual(@as(i32, 0), w32.GetUpdateRect(overlay.hwnd, null, 0));
    }

    var after: w32.RECT = undefined;
    try std.testing.expect(w32.GetWindowRect(overlay.hwnd, &after) != 0);
    // The premise: the window really did hold still for the whole animation.
    try std.testing.expectEqual(before.bottom - before.top, after.bottom - after.top);
    try std.testing.expect(saw_intermediate);
    // And it ends up showing the card it settled at, not a frame short of it.
    try std.testing.expectEqual(target, overlay.painted_h);
}

// T165: the link hover affordance, in PIXELS.
//
// This asserts the transition with no pointer, no desktop and no timing at
// all: the same banner painted twice into a DIB with only `hover_link`
// different.
//
// It was written because the acceptance script could not reach the hovered
// frame — on the background test desktop there is no real pointer, so Windows
// delivers WM_MOUSELEAVE a frame after every posted WM_MOUSEMOVE and the
// hovered paint never happened. T282 removed that limit (`capture-hover` holds
// the probe on one GUI-thread stack) and `pane-banner.ps1` now asserts the
// solid rule on the real composited overlay. This test stays: it is the
// cheapest form of the claim, it runs in the win32 unit lane with no GUI to
// launch, and a DIB comparison isolates the underline from everything else
// that could make a capture differ.
test "banner overlay: a link's underline is dotted at rest and solid on hover" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClassOnce(hinst) catch return error.SkipZigTest;

    const owner = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
        WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        300,
        600,
        120,
        null,
        null,
        hinst,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(owner);
    _ = w32.SetLayeredWindowAttributes(owner, 0, 0, w32.LWA_ALPHA);
    _ = w32.ShowWindow(owner, w32.SW_SHOWNOACTIVATE);

    const overlay = BannerOverlay.create(std.testing.allocator, null, owner, hinst) catch
        return error.SkipZigTest;
    defer overlay.destroy();
    _ = w32.SetLayeredWindowAttributes(overlay.hwnd, 0, 0, w32.LWA_ALPHA);
    overlay.alpha_set = true;

    // ALL CAPS label: no descender can drop glyph ink onto the underline row
    // and make a dotted rule score as a solid one.
    overlay.setText("[LINKLINKLINK](https://example.com/pr/1)");

    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        overlay.inset = @intFromFloat(80.0 * scale);
        overlay.updatePosition(scale);

        var client: w32.RECT = undefined;
        if (w32.GetClientRect(overlay.hwnd, &client) == 0) return error.SkipZigTest;
        const w = @max(client.right - client.left, 1);
        const h = @max(client.bottom - client.top, 1);

        // A top-down 32bpp DIB to paint into, so the pixels can be counted
        // directly (the same shape `buildCardSurface` uses).
        var bmi = std.mem.zeroes(w32.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -@as(i32, h);
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;

        const wnd_dc = w32.GetDC(overlay.hwnd) orelse return error.SkipZigTest;
        defer _ = w32.ReleaseDC(overlay.hwnd, wnd_dc);
        const mem_dc = w32.CreateCompatibleDC(wnd_dc) orelse return error.SkipZigTest;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse
            return error.SkipZigTest;
        defer _ = w32.DeleteObject(bmp);
        _ = w32.SelectObject(mem_dc, bmp);
        const pixels = @as([*]u32, @ptrCast(@alignCast(bits orelse return error.SkipZigTest)));
        const count: usize = @intCast(w * h);

        // Ink on the underline row, plus that row's span. The underline is
        // the BOTTOM-most row carrying link-colored pixels: it sits at the
        // foot of the text box, under every capital glyph.
        const Rule = struct { ink: i32, span: i32 };
        const measure = struct {
            fn run(px: []const u32, width: i32, height: i32) ?Rule {
                var y: i32 = height - 1;
                while (y >= 0) : (y -= 1) {
                    var ink: i32 = 0;
                    var lo: i32 = -1;
                    var hi: i32 = -1;
                    var x: i32 = 0;
                    while (x < width) : (x += 1) {
                        const p = px[@intCast(y * width + x)];
                        const r: i32 = @intCast((p >> 16) & 0xFF);
                        const b: i32 = @intCast(p & 0xFF);
                        // link_fg is a blue; the card wash is near-neutral.
                        if (b - r > 40) {
                            ink += 1;
                            if (lo < 0) lo = x;
                            hi = x;
                        }
                    }
                    if (ink > 0) return .{ .ink = ink, .span = hi - lo + 1 };
                }
                return null;
            }
        }.run;

        overlay.hover_link = null;
        overlay.paint(mem_dc);
        const rest = measure(pixels[0..count], w, h) orelse return error.SkipZigTest;

        // The paint above rebuilt the hit rects, so the link's identity
        // pointer is available now — the same value `updateLinkHover` stores.
        try std.testing.expect(overlay.links.items.len > 0);
        overlay.hover_link = overlay.links.items[0].url.ptr;
        overlay.paint(mem_dc);
        const hot = measure(pixels[0..count], w, h) orelse return error.SkipZigTest;
        overlay.hover_link = null;

        // Hovered: SOLID — every pixel from the run's first to its last.
        try std.testing.expect(hot.span > @as(i32, @intFromFloat(20.0 * scale)));
        try std.testing.expectEqual(hot.span, hot.ink);

        // At rest: the SAME rule in the same place — but dots are phased on
        // the client x (so the fragments of one link line up), which means
        // the first and last dot need not fall exactly on the run's ends. It
        // is short by less than one period, never more.
        const period = banner_layout.linkUnderline(0, 20, scale).period;
        try std.testing.expect(rest.span <= hot.span);
        try std.testing.expect(rest.span >= hot.span - period);
        // ...and it is DOTTED: 1 on, 2 off, so roughly a third of the span.
        try std.testing.expect(rest.ink > 0);
        try std.testing.expect(rest.ink <= @divTrunc(hot.span * 3, 5));
        try std.testing.expect(hot.ink > rest.ink);
    }
}
