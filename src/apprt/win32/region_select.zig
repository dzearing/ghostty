//! The region selector's rect math (T647), the pure half of the feedback
//! composer's screenshot capture.
//!
//! A drag has two corners and no order: the user may pull the rectangle out of
//! any of its four corners, and the one they started from is whichever they
//! pressed on. Everything downstream — the crop out of the screen snapshot, the
//! bright window painted over the dim, the PNG's width and height — wants a
//! NORMALIZED rect instead: a top-left origin and a non-negative size. Getting
//! that wrong is invisible in a right-and-down drag, which is the one a
//! developer tries first, and produces an empty or inverted crop in the other
//! three.
//!
//! It is also where "a click is not a screenshot" lives. A zero-area drag —
//! press and release without moving, or a drag along a single row or column —
//! is a CANCEL, not an empty image: a 0x0 PNG is not something anybody asked
//! for, and a 200x0 one is worse because it looks like it worked.
//!
//! No OS imports, so this asserts in every app-runtime lane.

const std = @import("std");

pub const Point = struct { x: i32, y: i32 };

/// A rectangle in virtual-screen (physical pixel) coordinates. `x`/`y` may be
/// negative — a monitor left of or above the primary one lives there, and the
/// capture path must not assume the desktop starts at the origin.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x < self.right() and
            p.y >= self.y and p.y < self.bottom();
    }
};

/// The rectangle a drag from `a` to `b` selects, normalized — or null when it
/// has no area.
///
/// The two points are treated as PIXEL CORNERS the way a marquee is: the
/// selection spans from the smaller coordinate up to (not including) the
/// larger, so dragging from x=10 to x=14 selects four columns, not five. That
/// is the convention every crop in this path already uses, and it is what makes
/// a press-with-no-motion fall out as zero rather than as one stray pixel.
pub fn dragRect(a: Point, b: Point) ?Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const w = @max(a.x, b.x) - x0;
    const h = @max(a.y, b.y) - y0;
    if (w <= 0 or h <= 0) return null;
    return .{ .x = x0, .y = y0, .w = w, .h = h };
}

/// `r` clipped to `bounds`, or null when nothing of it survives.
///
/// The selector's window covers the whole virtual screen, so in practice a drag
/// cannot leave it — but a captured pointer keeps reporting coordinates after it
/// has been dragged past the edge (and off the desktop entirely, on a
/// non-rectangular multi-monitor arrangement), and those coordinates would index
/// outside the snapshot's pixels.
pub fn clampTo(r: Rect, bounds: Rect) ?Rect {
    const x0 = @max(r.x, bounds.x);
    const y0 = @max(r.y, bounds.y);
    const x1 = @min(r.right(), bounds.right());
    const y1 = @min(r.bottom(), bounds.bottom());
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// The selection a drag produces against a bounded desktop: normalized, then
/// clipped. Null when either step leaves nothing — which is the single
/// "nothing was captured" answer the selector acts on.
pub fn selection(a: Point, b: Point, bounds: Rect) ?Rect {
    const r = dragRect(a, b) orelse return null;
    return clampTo(r, bounds);
}

/// A rect expressed relative to `bounds`'s origin — the offset into the
/// snapshot's own pixel buffer, whose (0,0) is the virtual screen's top-left
/// corner rather than the desktop origin.
pub fn relativeTo(r: Rect, bounds: Rect) Rect {
    return .{ .x = r.x - bounds.x, .y = r.y - bounds.y, .w = r.w, .h = r.h };
}

// ------------------------------------------------------------------ keyboard

/// One arrow press. A single pixel, because the whole point of framing a region
/// by hand is landing on an exact edge, and a keyboard user has no sub-step to
/// fall back on the way a mouse does.
pub const step_fine_px: i32 = 1;

/// One arrow press with Ctrl held. 32 px, so crossing a 4K monitor is ~120
/// presses instead of ~3800 — a coarse step is what makes the fine one usable,
/// not a luxury on top of it.
pub const step_coarse_px: i32 = 32;

pub const Arrow = enum { left, right, up, down };

/// Which modifiers are held. The selector tracks these from the key messages
/// themselves rather than asking the OS (see `RegionSelector`'s header), so this
/// is passed in rather than read.
pub const Mods = struct { shift: bool = false, ctrl: bool = false };

/// The half of the selector's state the keyboard drives: a caret point and the
/// anchor the selection is measured from.
///
/// It is the same pair the mouse drives — press sets the anchor, motion moves
/// the caret — which is why the keyboard needs no second selection model and
/// the two can be interleaved freely.
pub const KeyState = struct {
    /// Where the caret is. Always inside `bounds` (inclusive of its far edge,
    /// see `clampPoint`).
    caret: Point,
    /// The selection's fixed corner, or null before one has been dropped.
    anchor: ?Point = null,
};

pub fn stepPx(mods: Mods) i32 {
    return if (mods.ctrl) step_coarse_px else step_fine_px;
}

/// `p` held inside `bounds`, with the far edge INCLUSIVE.
///
/// Inclusive because these are pixel corners, not pixels: a selection spans up
/// to but not including its second point (`dragRect`), so a caret that could
/// only reach `right() - 1` could never select the desktop's last column.
pub fn clampPoint(p: Point, bounds: Rect) Point {
    return .{
        .x = std.math.clamp(p.x, bounds.x, bounds.right()),
        .y = std.math.clamp(p.y, bounds.y, bounds.bottom()),
    };
}

/// Where a keyboard-driven capture starts: the middle of the monitor the user
/// is on. The middle rather than a corner because it is the shortest average
/// distance to anywhere on that screen, and because a caret at (0,0) is
/// indistinguishable from a caret that has not appeared.
pub fn caretStart(home: Rect) Point {
    return .{ .x = home.x + @divTrunc(home.w, 2), .y = home.y + @divTrunc(home.h, 2) };
}

/// One arrow press applied.
///
/// Two rules, and both exist to make the keyboard path unsurprising:
///
///   - A plain arrow NEVER destroys a selection. Once an anchor is down, arrows
///     resize from it exactly as dragging the mouse does. (Collapsing it the way
///     a text caret does would mean a keyboard user could lose a rectangle they
///     had spent thirty presses framing, with no undo anywhere in the gesture.)
///   - Shift+arrow drops the anchor at the caret it is leaving, so the very
///     first Shift+Right already selects something. It is the shortcut for
///     "Enter, then arrow", not a separate mode.
pub fn moveCaret(state: KeyState, arrow: Arrow, mods: Mods, bounds: Rect) KeyState {
    const step = stepPx(mods);
    const d: Point = switch (arrow) {
        .left => .{ .x = -step, .y = 0 },
        .right => .{ .x = step, .y = 0 },
        .up => .{ .x = 0, .y = -step },
        .down => .{ .x = 0, .y = step },
    };
    return .{
        .anchor = state.anchor orelse (if (mods.shift) state.caret else null),
        .caret = clampPoint(.{ .x = state.caret.x + d.x, .y = state.caret.y + d.y }, bounds),
    };
}

/// Enter (or Space) with no anchor yet: pin this corner. The keyboard's
/// equivalent of pressing the mouse button, which is why the same key finishes
/// the gesture once an anchor exists.
pub fn dropAnchor(state: KeyState) KeyState {
    return .{ .caret = state.caret, .anchor = state.caret };
}

// --------------------------------------------------------------- window pick

/// Which thing the overlay is selecting: a rectangle dragged (or keyed) out of
/// the desktop, or a whole WINDOW under the pointer.
///
/// Mac's `screencapture -i` has exactly these two, on exactly this toggle
/// (Space), and the second is the one somebody wanting "a picture of THIS
/// dialog" is reaching for — it is strictly more accurate than any rectangle
/// they could drag around the same window.
pub const Mode = enum { region, window };

/// Space toggles, rather than switching one way. A mode with no way out is
/// worse than no mode: a user who pressed Space to see what it did must be able
/// to press it again and be back where they were.
pub fn toggleMode(m: Mode) Mode {
    return switch (m) {
        .region => .window,
        .window => .region,
    };
}

/// One top-level window as the picker sees it: a handle (as an integer, so
/// nothing here imports an OS type), a frame in VIRTUAL-SCREEN coordinates, and
/// the three states that make a window unpickable even though it is enumerated.
pub const WindowInfo = struct {
    handle: usize,
    rect: Rect,
    visible: bool = true,
    /// Minimized. Its frame is off in the negative thousands, which would
    /// otherwise be a perfectly valid-looking rect to crop.
    minimized: bool = false,
    /// Composed but not drawn — a window on another virtual desktop, or one the
    /// shell has cloaked. It is not on the photograph, so it cannot be picked
    /// out of it.
    cloaked: bool = false,
};

/// Whether `w` may be picked at all, given the overlay's OWN handle.
///
/// The overlay is the window under the pointer at every point of the desktop —
/// it covers the whole virtual screen — so excluding it is not an edge case,
/// it is the first thing the pick has to do or nothing else is ever reachable.
pub fn isCandidate(w: WindowInfo, own: usize) bool {
    if (w.handle == 0 or w.handle == own) return false;
    if (!w.visible or w.minimized or w.cloaked) return false;
    return w.rect.w > 0 and w.rect.h > 0;
}

/// The rect a window pick at `p` selects: the FIRST candidate in `windows` that
/// contains the point, clipped to `bounds`. Null when nothing under the pointer
/// qualifies.
///
/// `windows` is in front-to-back z-order, which is the order the OS enumerates
/// top-level windows in, so "first" means "topmost" — the window the user can
/// actually see under the pointer, not whatever happens to be listed first.
pub fn pickWindow(windows: []const WindowInfo, p: Point, own: usize, bounds: Rect) ?Rect {
    for (windows) |w| {
        if (!isCandidate(w, own)) continue;
        if (!w.rect.contains(p)) continue;
        return clampTo(w.rect, bounds);
    }
    return null;
}

// -------------------------------------------------------------------- status

/// The longest status line the overlay can produce, used to MEASURE the hint
/// card once so it never resizes (and therefore never re-centers, jittering
/// sideways) while a drag is live. Digits are `8` because it is the widest one
/// in every proportional face we ship.
///
/// It has to cover BOTH modes, because Space switches between them with the
/// card already on screen: a template measured from region mode alone would
/// clip the window-mode line, and one measured per mode would resize the card
/// mid-gesture, which is the jitter this exists to prevent.
pub const status_template =
    "-88888,-88888  \u{b7}  Drag, arrows+Enter, or Space for a window  \u{b7}  Esc to cancel";

/// The overlay's live status line: what the hint card paints AND what the
/// window's accessible name is set to, which is the half a screen reader can
/// reach. A selection that is only drawn is not announced.
///
/// `caret` and `sel` are in VIRTUAL-SCREEN coordinates — the numbers a user can
/// compare against anything else on their desktop — so the caller rebases before
/// calling. Returns a slice of `buf`; a buffer too small for the line falls back
/// to the fixed instruction text rather than to a truncated number.
pub fn statusText(buf: []u8, caret: Point, sel: ?Rect) []const u8 {
    if (sel) |r| {
        return std.fmt.bufPrint(
            buf,
            "{d},{d}  {d}x{d}  \u{b7}  Enter to capture  \u{b7}  Esc to cancel",
            .{ r.x, r.y, r.w, r.h },
        ) catch status_fallback;
    }
    return std.fmt.bufPrint(
        buf,
        "{d},{d}  \u{b7}  Drag, arrows+Enter, or Space for a window  \u{b7}  Esc to cancel",
        .{ caret.x, caret.y },
    ) catch status_fallback;
}

const status_fallback = "Drag to capture  \u{b7}  Esc to cancel";

/// The same line for WINDOW mode: the picked window's origin and size, or the
/// instruction when the pointer is over nothing pickable.
///
/// It names Space in both states, because a mode you cannot find your way out
/// of is the failure this toggle is designed against, and the card is the only
/// place that says so.
pub fn windowStatusText(buf: []u8, sel: ?Rect) []const u8 {
    if (sel) |r| {
        return std.fmt.bufPrint(
            buf,
            "{d},{d}  {d}x{d}  \u{b7}  Click to capture  \u{b7}  Space for a region",
            .{ r.x, r.y, r.w, r.h },
        ) catch window_status_fallback;
    }
    return window_status_fallback;
}

const window_status_fallback =
    "Point at a window  \u{b7}  Space for a region  \u{b7}  Esc to cancel";

/// How long a status line can get. Sized off the template, with room for the
/// idle line's longer tail.
pub const status_max = 128;

// -------------------------------------------------------------------- chrome

/// The caret's arm length, from its center outward — 8 DIP, the scale step that
/// reads as a mark rather than as a crosshair cursor. Drawn only while the
/// keyboard is aiming and nothing is selected yet; with a selection on screen
/// the outline already says where the caret is.
pub const caret_arm_dip: f32 = 8.0;

/// The square a caret at `p` paints into, outline included — what has to be
/// invalidated when it moves.
pub fn caretBox(p: Point, scale: f32) Rect {
    const arm = px(caret_arm_dip, scale);
    const t = px(border_dip, scale);
    const half = arm + t;
    return .{ .x = p.x - half, .y = p.y - half, .w = 2 * half, .h = 2 * half };
}

/// The selection's outline. 2 DIP is the design system's divider weight, and
/// this is the same kind of thing: a meaningful boundary, which must clear the
/// 3:1 contrast floor against BOTH the dimmed desktop outside it and the bright
/// one inside.
pub const border_dip: f32 = 2.0;

/// The hint card's distance from the top of the monitor the capture started on.
/// `24` — the largest step on the 4 DIP scale, because this floats over
/// arbitrary content and needs to read as detached from it.
pub const hint_margin_dip: f32 = 24.0;

/// The hint card's inner padding. `12` across and `8` down: the same
/// text-inside-a-card pair the banner and composer use.
pub const hint_pad_x_dip: f32 = 12.0;
pub const hint_pad_y_dip: f32 = 8.0;

/// Card radius (design system §3.1's `8`). The hint is a floating card, not a
/// button and not a capsule.
pub const hint_radius_dip: f32 = 8.0;

/// How dark the un-selected desktop is painted, out of 255. Dark enough that
/// the bright selection is unmistakable, light enough that the user can still
/// see what they are about to drag over — a dim that hides the content defeats
/// the point of dragging over it.
pub const dim_numerator: u32 = 110;

pub fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

/// Where the "drag to capture" card sits: horizontally centered on `home` (the
/// monitor the pointer was on when the capture began, NOT the virtual screen,
/// whose center can be a bezel), one margin below its top edge.
///
/// `text_w`/`text_h` are the measured text extent in physical pixels; the card
/// is that plus padding. A card wider than the monitor is pinned to the
/// monitor's left edge rather than allowed to start off-screen.
pub fn hintBox(home: Rect, scale: f32, text_w: i32, text_h: i32) Rect {
    const w = text_w + 2 * px(hint_pad_x_dip, scale);
    const h = text_h + 2 * px(hint_pad_y_dip, scale);
    const x = home.x + @max(0, @divTrunc(home.w - w, 2));
    return .{ .x = x, .y = home.y + px(hint_margin_dip, scale), .w = w, .h = h };
}

// -------------------------------------------------------------- chrome tests

const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "hintBox: centered on the home monitor, one margin down, at every scale" {
    // Two monitors: the primary, and a second one to its LEFT. The card must
    // follow the monitor it was asked for, not the virtual screen's middle,
    // which here is the bezel between them.
    const left: Rect = .{ .x = -1920, .y = 0, .w = 1920, .h = 1080 };
    const primary: Rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 };

    for (scales) |s| {
        const text_w = px(300, s);
        const text_h = px(18, s);

        for ([_]Rect{ left, primary }) |home| {
            const card = hintBox(home, s, text_w, text_h);

            // Inside its own monitor, and nowhere near the other one.
            try testing.expect(card.x >= home.x);
            try testing.expect(card.right() <= home.right());
            try testing.expect(card.y > home.y);
            try testing.expect(card.bottom() < home.bottom());

            // Centered: the slack on the two sides differs by at most the one
            // pixel an odd width cannot split.
            const lead = card.x - home.x;
            const trail = home.right() - card.right();
            try testing.expect(@abs(lead - trail) <= 1);

            // The padding is the padding, on both axes.
            try testing.expectEqual(text_w + 2 * px(hint_pad_x_dip, s), card.w);
            try testing.expectEqual(text_h + 2 * px(hint_pad_y_dip, s), card.h);

            // And it clears the monitor's top edge by the whole margin — 24
            // DIP is 24 physical pixels at 1.0 and 48 at 2.0, which is the
            // scaling bug that only shows up off 1.0.
            try testing.expectEqual(px(hint_margin_dip, s), card.y - home.y);
        }
    }
}

test "hintBox: text wider than the monitor pins to its left edge" {
    const home: Rect = .{ .x = 100, .y = 100, .w = 200, .h = 200 };
    const card = hintBox(home, 1.0, 500, 18);
    // Never starts left of the monitor, which is what a bare `(w - card.w)/2`
    // would do — the text is then clipped on the right, where a reader can at
    // least tell something is cut off.
    try testing.expectEqual(home.x, card.x);
}

test "px rounds rather than truncates" {
    // 2 DIP at 1.25 is 2.5 -> 3, not 2. A truncating scale is how a 2 DIP
    // divider disappears entirely at some scales and not others.
    try testing.expectEqual(@as(i32, 3), px(border_dip, 1.25));
    try testing.expectEqual(@as(i32, 2), px(border_dip, 1.0));
    try testing.expectEqual(@as(i32, 3), px(border_dip, 1.5));
    try testing.expectEqual(@as(i32, 4), px(border_dip, 2.0));
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "dragRect normalizes a drag pulled in any of the four directions" {
    const expected: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const tl: Point = .{ .x = 10, .y = 20 };
    const br: Point = .{ .x = 40, .y = 60 };
    const tr: Point = .{ .x = 40, .y = 20 };
    const bl: Point = .{ .x = 10, .y = 60 };

    // Down-right, the one a developer tries first.
    try testing.expectEqual(expected, dragRect(tl, br).?);
    // Up-left, which an unnormalized rect renders as a negative size.
    try testing.expectEqual(expected, dragRect(br, tl).?);
    // The two mixed directions, where only ONE axis is inverted — the pair a
    // "swap if x1 < x0" fix that forgot the other axis still gets wrong.
    try testing.expectEqual(expected, dragRect(tr, bl).?);
    try testing.expectEqual(expected, dragRect(bl, tr).?);
}

test "dragRect: a zero-area drag is nothing, not an empty picture" {
    // A click: press and release without moving.
    try testing.expect(dragRect(.{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }) == null);
    // A drag along one row, and one along one column. Both have a real extent
    // on one axis, which is exactly what makes them look like a capture until
    // the PNG comes out 200x0.
    try testing.expect(dragRect(.{ .x = 5, .y = 5 }, .{ .x = 205, .y = 5 }) == null);
    try testing.expect(dragRect(.{ .x = 5, .y = 5 }, .{ .x = 5, .y = 205 }) == null);
    // One pixel of motion on both axes IS a capture, however silly.
    try testing.expectEqual(
        Rect{ .x = 5, .y = 5, .w = 1, .h = 1 },
        dragRect(.{ .x = 5, .y = 5 }, .{ .x = 6, .y = 6 }).?,
    );
}

test "dragRect works in negative coordinates" {
    // A monitor left of and above the primary one. Nothing here may assume the
    // desktop starts at (0,0).
    try testing.expectEqual(
        Rect{ .x = -1920, .y = -300, .w = 400, .h = 200 },
        dragRect(.{ .x = -1520, .y = -100 }, .{ .x = -1920, .y = -300 }).?,
    );
}

test "clampTo clips to the desktop and rejects what falls off it" {
    const bounds: Rect = .{ .x = -100, .y = -50, .w = 1000, .h = 800 };

    // Wholly inside: untouched.
    const inside: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try testing.expectEqual(inside, clampTo(inside, bounds).?);

    // Hanging off the top-left and the bottom-right corners.
    try testing.expectEqual(
        Rect{ .x = -100, .y = -50, .w = 150, .h = 100 },
        clampTo(.{ .x = -500, .y = -400, .w = 550, .h = 450 }, bounds).?,
    );
    try testing.expectEqual(
        Rect{ .x = 800, .y = 700, .w = 100, .h = 50 },
        clampTo(.{ .x = 800, .y = 700, .w = 500, .h = 500 }, bounds).?,
    );

    // Entirely outside, and exactly touching the far edge: both are nothing.
    try testing.expect(clampTo(.{ .x = 900, .y = 0, .w = 100, .h = 100 }, bounds) == null);
    try testing.expect(clampTo(.{ .x = -600, .y = 0, .w = 100, .h = 100 }, bounds) == null);
}

test "selection: normalize then clip, in one answer" {
    const bounds: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };

    // Dragged up-left AND off the desktop's top-left corner.
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .w = 20, .h = 30 },
        selection(.{ .x = 20, .y = 30 }, .{ .x = -40, .y = -60 }, bounds).?,
    );
    // A click is still nothing after clipping.
    try testing.expect(selection(.{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }, bounds) == null);
    // A real drag entirely off the desktop is nothing too — normalization
    // succeeds and the clip is what rejects it.
    try testing.expect(selection(.{ .x = 200, .y = 200 }, .{ .x = 300, .y = 300 }, bounds) == null);
}

test "relativeTo rebases onto the snapshot's own buffer" {
    const bounds: Rect = .{ .x = -1920, .y = -180, .w = 3840, .h = 1260 };
    // The primary monitor's origin is 1920 pixels into the snapshot, not 0.
    try testing.expectEqual(
        Rect{ .x = 1920, .y = 180, .w = 200, .h = 100 },
        relativeTo(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, bounds),
    );
    // A rect at the snapshot's own origin rebases to (0,0).
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .w = 5, .h = 5 },
        relativeTo(.{ .x = -1920, .y = -180, .w = 5, .h = 5 }, bounds),
    );
}

// ----------------------------------------------------------- keyboard tests

const desktop: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };

test "an arrow moves the caret one pixel, Ctrl moves it a coarse step" {
    try testing.expectEqual(@as(i32, 1), stepPx(.{}));
    try testing.expectEqual(@as(i32, 1), stepPx(.{ .shift = true }));
    try testing.expectEqual(step_coarse_px, stepPx(.{ .ctrl = true }));
    try testing.expectEqual(step_coarse_px, stepPx(.{ .ctrl = true, .shift = true }));

    const start: KeyState = .{ .caret = .{ .x = 100, .y = 100 } };
    try testing.expectEqual(
        Point{ .x = 101, .y = 100 },
        moveCaret(start, .right, .{}, desktop).caret,
    );
    try testing.expectEqual(
        Point{ .x = 99, .y = 100 },
        moveCaret(start, .left, .{}, desktop).caret,
    );
    try testing.expectEqual(
        Point{ .x = 100, .y = 99 },
        moveCaret(start, .up, .{}, desktop).caret,
    );
    try testing.expectEqual(
        Point{ .x = 100, .y = 101 },
        moveCaret(start, .down, .{}, desktop).caret,
    );
    // Ctrl scales every direction, not just the two a developer tries.
    try testing.expectEqual(
        Point{ .x = 132, .y = 100 },
        moveCaret(start, .right, .{ .ctrl = true }, desktop).caret,
    );
    try testing.expectEqual(
        Point{ .x = 100, .y = 68 },
        moveCaret(start, .up, .{ .ctrl = true }, desktop).caret,
    );
}

test "the caret stops at the desktop's edges, far edge included" {
    // The far edge is REACHABLE: a caret capped at right()-1 could never select
    // the last column, because a selection spans up to but not including its
    // second point.
    var s: KeyState = .{ .caret = .{ .x = 1919, .y = 1079 } };
    s = moveCaret(s, .right, .{ .ctrl = true }, desktop);
    s = moveCaret(s, .down, .{ .ctrl = true }, desktop);
    try testing.expectEqual(Point{ .x = 1920, .y = 1080 }, s.caret);
    // And it goes no further, however many presses arrive.
    s = moveCaret(s, .right, .{ .ctrl = true }, desktop);
    try testing.expectEqual(Point{ .x = 1920, .y = 1080 }, s.caret);

    // The near edge, on a desktop whose origin is negative — a monitor left of
    // and above the primary one.
    const negative: Rect = .{ .x = -1920, .y = -300, .w = 3840, .h = 1380 };
    var t: KeyState = .{ .caret = .{ .x = -1919, .y = -299 } };
    t = moveCaret(t, .left, .{ .ctrl = true }, negative);
    t = moveCaret(t, .up, .{ .ctrl = true }, negative);
    try testing.expectEqual(Point{ .x = -1920, .y = -300 }, t.caret);
}

test "Shift+arrow starts a selection at the caret it leaves" {
    const start: KeyState = .{ .caret = .{ .x = 400, .y = 300 } };
    const after = moveCaret(start, .right, .{ .shift = true, .ctrl = true }, desktop);
    // The anchor is where the caret WAS, so the very first press selects
    // something rather than a zero-width nothing.
    try testing.expectEqual(Point{ .x = 400, .y = 300 }, after.anchor.?);
    try testing.expectEqual(Point{ .x = 432, .y = 300 }, after.caret);

    // One axis alone still has no AREA, which is the same "not a picture"
    // answer a single-row mouse drag gets — the second axis is what makes it a
    // selection.
    try testing.expect(selection(after.anchor.?, after.caret, desktop) == null);
    const framed = moveCaret(after, .down, .{ .ctrl = true }, desktop);
    try testing.expectEqual(
        Rect{ .x = 400, .y = 300, .w = 32, .h = 32 },
        selection(framed.anchor.?, framed.caret, desktop).?,
    );
}

test "a plain arrow never destroys a selection" {
    // The rule that separates this from a text caret: thirty presses of framing
    // must not be undone by one arrow pressed without Shift.
    var s: KeyState = .{ .caret = .{ .x = 200, .y = 200 } };
    s = dropAnchor(s);
    try testing.expectEqual(Point{ .x = 200, .y = 200 }, s.anchor.?);
    s = moveCaret(s, .right, .{ .ctrl = true }, desktop);
    s = moveCaret(s, .down, .{ .ctrl = true }, desktop);
    try testing.expectEqual(Point{ .x = 200, .y = 200 }, s.anchor.?);
    try testing.expectEqual(
        Rect{ .x = 200, .y = 200, .w = 32, .h = 32 },
        selection(s.anchor.?, s.caret, desktop).?,
    );
    // And the anchor is not re-dropped by a later Shift+arrow either — it is
    // the corner the user pinned.
    s = moveCaret(s, .right, .{ .shift = true }, desktop);
    try testing.expectEqual(Point{ .x = 200, .y = 200 }, s.anchor.?);
}

test "the caret starts in the middle of the monitor the user is on" {
    const home: Rect = .{ .x = 1920, .y = 0, .w = 2560, .h = 1440 };
    try testing.expectEqual(Point{ .x = 3200, .y = 720 }, caretStart(home));
    // A monitor left of the primary one: nothing here may assume a positive
    // origin.
    const left: Rect = .{ .x = -1920, .y = -180, .w = 1920, .h = 1080 };
    try testing.expectEqual(Point{ .x = -960, .y = 360 }, caretStart(left));
}

test "statusText announces the caret, then the live selection" {
    var buf: [status_max]u8 = undefined;

    // Nothing selected yet: the caret's own position, plus how to proceed
    // with either input device.
    const idle = statusText(&buf, .{ .x = -1234, .y = 56 }, null);
    try testing.expect(std.mem.startsWith(u8, idle, "-1234,56  "));
    try testing.expect(std.mem.indexOf(u8, idle, "arrows") != null);
    try testing.expect(std.mem.indexOf(u8, idle, "Esc") != null);

    // With a selection: the origin AND the size, which is the number both a
    // keyboard user and a mouse user are actually aiming at.
    const live = statusText(&buf, .{ .x = 0, .y = 0 }, .{ .x = 120, .y = 140, .w = 160, .h = 120 });
    try testing.expect(std.mem.startsWith(u8, live, "120,140  160x120  "));
    try testing.expect(std.mem.indexOf(u8, live, "Enter to capture") != null);

    // Every line fits the template the card is measured from, so the card
    // never has to resize mid-drag. The extremes are a full 5-digit negative
    // origin and the idle line's longer tail.
    try testing.expect(statusText(&buf, .{ .x = -32768, .y = -32768 }, .{
        .x = -32768,
        .y = -32768,
        .w = 32767,
        .h = 32767,
    }).len <= status_template.len);
    try testing.expect(statusText(&buf, .{ .x = -32768, .y = -32768 }, null).len <=
        status_template.len);
    try testing.expect(status_template.len < status_max);
}

// -------------------------------------------------------- window-pick tests

test "Space toggles between the two modes, both ways" {
    // Both ways, because a one-way switch strands a user who pressed Space to
    // find out what it does.
    try testing.expectEqual(Mode.window, toggleMode(.region));
    try testing.expectEqual(Mode.region, toggleMode(.window));
}

test "the overlay's own window is never a candidate" {
    // The overlay covers the whole virtual screen, so it is under the pointer
    // at every single point: if it were pickable, it would be the ONLY thing
    // ever picked and the mode would be dead on arrival.
    const own: usize = 0x1234;
    const overlay: WindowInfo = .{ .handle = own, .rect = desktop };
    try testing.expect(!isCandidate(overlay, own));
    try testing.expect(isCandidate(.{ .handle = 0x5678, .rect = desktop }, own));
    // A null handle is not a window either.
    try testing.expect(!isCandidate(.{ .handle = 0, .rect = desktop }, own));

    // And the pick agrees, with the overlay listed first the way the OS would
    // enumerate it (it is topmost).
    const under: WindowInfo = .{ .handle = 0x5678, .rect = .{ .x = 100, .y = 100, .w = 400, .h = 300 } };
    try testing.expectEqual(
        Rect{ .x = 100, .y = 100, .w = 400, .h = 300 },
        pickWindow(&.{ overlay, under }, .{ .x = 200, .y = 200 }, own, desktop).?,
    );
}

test "a window that cannot be seen cannot be picked" {
    const own: usize = 1;
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 200 };
    const p: Point = .{ .x = 10, .y = 10 };

    // Each of the three states on its own, then the empty rect. All of them
    // sit in the enumeration and none of them is on the photograph.
    try testing.expect(pickWindow(
        &.{.{ .handle = 2, .rect = r, .visible = false }},
        p,
        own,
        desktop,
    ) == null);
    try testing.expect(pickWindow(
        &.{.{ .handle = 2, .rect = r, .minimized = true }},
        p,
        own,
        desktop,
    ) == null);
    try testing.expect(pickWindow(
        &.{.{ .handle = 2, .rect = r, .cloaked = true }},
        p,
        own,
        desktop,
    ) == null);
    try testing.expect(pickWindow(
        &.{.{ .handle = 2, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }},
        p,
        own,
        desktop,
    ) == null);

    // And an unpickable window in FRONT does not shadow the pickable one
    // behind it — otherwise a cloaked window from another virtual desktop
    // would swallow every pick made under it.
    try testing.expectEqual(
        r,
        pickWindow(&.{
            .{ .handle = 2, .rect = desktop, .cloaked = true },
            .{ .handle = 3, .rect = r },
        }, p, own, desktop).?,
    );
}

test "the pick takes the topmost window under the pointer, and nothing else" {
    const own: usize = 1;
    const back: WindowInfo = .{ .handle = 2, .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 } };
    const front: WindowInfo = .{ .handle = 3, .rect = .{ .x = 100, .y = 100, .w = 200, .h = 200 } };
    const list = [_]WindowInfo{ front, back };

    // Over the overlap: the front one, because that is what the user sees.
    try testing.expectEqual(front.rect, pickWindow(&list, .{ .x = 150, .y = 150 }, own, desktop).?);
    // Over the back one only: the back one.
    try testing.expectEqual(back.rect, pickWindow(&list, .{ .x = 500, .y = 500 }, own, desktop).?);
    // Over neither: nothing. A pick with no window under it is not a capture,
    // the same way a zero-area drag is not one.
    try testing.expect(pickWindow(&list, .{ .x = 1500, .y = 900 }, own, desktop) == null);
    // An empty desktop picks nothing rather than falling over.
    try testing.expect(pickWindow(&.{}, .{ .x = 10, .y = 10 }, own, desktop) == null);
}

test "a picked window is clipped to the desktop" {
    // The common case this exists for: a window dragged half off the left edge
    // of the leftmost monitor. Its frame is real, but the part outside the
    // snapshot has no pixels to crop.
    const own: usize = 1;
    const half_off: WindowInfo = .{ .handle = 2, .rect = .{ .x = -200, .y = -100, .w = 600, .h = 400 } };
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .w = 400, .h = 300 },
        pickWindow(&.{half_off}, .{ .x = 10, .y = 10 }, own, desktop).?,
    );

    // And on a desktop whose own origin is negative, the clip is to THAT, not
    // to (0,0) — nothing in this path may assume the desktop starts at the
    // origin.
    const negative: Rect = .{ .x = -1920, .y = -300, .w = 3840, .h = 1380 };
    try testing.expectEqual(
        Rect{ .x = -1920, .y = -300, .w = 500, .h = 400 },
        pickWindow(
            &.{.{ .handle = 2, .rect = .{ .x = -2100, .y = -500, .w = 680, .h = 600 } }},
            .{ .x = -2000, .y = -400 },
            own,
            negative,
        ).?,
    );
}

test "windowStatusText announces the picked window, and always names the way out" {
    var buf: [status_max]u8 = undefined;

    const aimed = windowStatusText(&buf, .{ .x = -120, .y = 40, .w = 1280, .h = 720 });
    try testing.expect(std.mem.startsWith(u8, aimed, "-120,40  1280x720  "));
    try testing.expect(std.mem.indexOf(u8, aimed, "Click to capture") != null);
    try testing.expect(std.mem.indexOf(u8, aimed, "Space") != null);

    // Over nothing pickable: the instruction, which still names Space.
    const idle = windowStatusText(&buf, null);
    try testing.expect(std.mem.indexOf(u8, idle, "Point at a window") != null);
    try testing.expect(std.mem.indexOf(u8, idle, "Space") != null);
    try testing.expect(std.mem.indexOf(u8, idle, "Esc") != null);
}

test "every line of either mode fits the card the template measures" {
    // The card is measured ONCE, from the template, and Space switches modes
    // with it already on screen. A window-mode line longer than the template
    // would be clipped by a card that cannot grow.
    var buf: [status_max]u8 = undefined;
    const extreme: Rect = .{ .x = -32768, .y = -32768, .w = 32767, .h = 32767 };

    try testing.expect(windowStatusText(&buf, extreme).len <= status_template.len);
    try testing.expect(windowStatusText(&buf, null).len <= status_template.len);
    try testing.expect(statusText(&buf, .{ .x = -32768, .y = -32768 }, extreme).len <=
        status_template.len);
    try testing.expect(statusText(&buf, .{ .x = -32768, .y = -32768 }, null).len <=
        status_template.len);
    try testing.expect(status_template.len < status_max);
}

test "the region-mode idle line offers the window mode too" {
    // Discoverability: Space is a mode nobody would guess at. It is named in
    // the one line a user reads before choosing an input device, alongside the
    // keyboard path T671 shipped, which must not have been displaced by it.
    var buf: [status_max]u8 = undefined;
    const idle = statusText(&buf, .{ .x = 0, .y = 0 }, null);
    try testing.expect(std.mem.indexOf(u8, idle, "Space") != null);
    try testing.expect(std.mem.indexOf(u8, idle, "window") != null);
    try testing.expect(std.mem.indexOf(u8, idle, "arrows") != null);
    try testing.expect(std.mem.indexOf(u8, idle, "Drag") != null);
}

test "caretBox covers the whole mark at every scale" {
    for (scales) |s| {
        const box = caretBox(.{ .x = 500, .y = 400 }, s);
        const half = px(caret_arm_dip, s) + px(border_dip, s);
        // Centered on the caret, and wide enough for both arms plus the
        // outline that haloes them.
        try testing.expectEqual(500 - half, box.x);
        try testing.expectEqual(400 - half, box.y);
        try testing.expectEqual(2 * half, box.w);
        try testing.expectEqual(2 * half, box.h);
        try testing.expect(box.contains(.{ .x = 500, .y = 400 }));
    }
}

test "Rect edges and containment" {
    const r: Rect = .{ .x = -10, .y = -10, .w = 20, .h = 20 };
    try testing.expectEqual(@as(i32, 10), r.right());
    try testing.expectEqual(@as(i32, 10), r.bottom());
    try testing.expect(r.contains(.{ .x = -10, .y = -10 }));
    try testing.expect(r.contains(.{ .x = 9, .y = 9 }));
    // The far edge is exclusive, the same convention `dragRect` spans.
    try testing.expect(!r.contains(.{ .x = 10, .y = 0 }));
    try testing.expect(!r.contains(.{ .x = 0, .y = 10 }));
}
