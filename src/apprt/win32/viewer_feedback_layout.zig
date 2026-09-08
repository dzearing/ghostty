//! Geometry for the viewer pane's feedback composer (T634, the win32 half of
//! Mac's `ViewerFeedbackBar`): where the pill sits, how tall it is for a given
//! amount of text, and where the two circular actions sit inside its trailing
//! edge.
//!
//! Pure — no OS imports — so the whole module asserts in the none-runtime lane
//! at 1.0/1.25/1.5/2.0, which is where the win32 design system says chrome
//! geometry has to be pinned (most of these defects are invisible at 1.0 and
//! obvious at 1.25). Sibling of `viewer_nav_layout.zig`, and it inherits that
//! module's conventions: physical pixels, right/bottom exclusive, an absent
//! element is an EMPTY rect rather than a flag.
//!
//! ## The pill is a capsule, and that is a named exception
//!
//! The design system's radius scale is 4/6/8 DIP and an input field is 4. This
//! control is deliberately not on it: Mac's composer is a capsule because the
//! shape is what says "chat composer" rather than "form field", and a viewer
//! pane that looks like a chat composer on one platform and a text box on the
//! other is the divergence this project does not ship. See
//! `docs/design/win32-design-system.md` §3.1, which names it alongside the
//! status chip.
//!
//! The radius is FIXED at half the COLLAPSED pill height rather than half the
//! current height — the same reasoning Mac writes out: a radius recomputed at
//! every height stops being a pill and becomes an oval once the text grows,
//! so pinning it lets the straight sides lengthen instead.

const std = @import("std");
const icon_button = @import("icon_button.zig");

pub const Rect = icon_button.Rect;

/// Band inset on all four sides. `md` (8): the composer is a GROUP of controls
/// inside the pane's chrome, not a control in a strip.
pub const pad_dip: f32 = 8.0;

/// Pill <-> footer. Same step, for the same reason.
pub const row_gap_dip: f32 = 8.0;

/// The text's leading inset inside the pill. `lg` — the extra step buys the
/// round cap its clearance, so the first character does not sit in the curve.
pub const text_lead_dip: f32 = 12.0;

/// The pill's own inner padding around the action buttons, and the gap
/// between the two of them. `sm`, the default control-to-control step.
pub const pill_pad_dip: f32 = 4.0;

/// Text region <-> the first action button. `md`: they are different groups.
pub const text_gap_dip: f32 = 8.0;

/// The carousel tile (T646): a square, big enough that a pasted screenshot is
/// recognisable at a glance and small enough that the strip does not eat the
/// pane the feedback is about. Off the 4 DIP spacing scale by construction —
/// this is a CONTENT size, not a gap, and 56 is 14 steps of it.
pub const thumb_dip: f32 = 56.0;

/// Between two tiles. `md`: separate items, not one control's parts.
pub const thumb_gap_dip: f32 = 8.0;

/// The picture's own inset inside its tile, so the tile reads as a frame around
/// the image rather than a border drawn on top of it. `sm`.
pub const thumb_inset_dip: f32 = 4.0;

/// How many lines the pill grows to before the text scrolls instead. Mac's
/// `maxInputHeight` is ~6 lines and the reason is the same here: past this the
/// composer is eating the pane the feedback is ABOUT.
pub const max_lines: u32 = 6;

/// The two circular actions inside the pill's trailing edge, in strip order.
/// `snapshot` is Mac's `+` (add a screenshot), `send` its `↑`.
pub const Button = enum { snapshot, send };
pub const button_count = std.enums.values(Button).len;

/// What a button SAYS when you hover it (T640), and what a screen reader would
/// have to be told. Mac's `.help` strings with their chords respelled for
/// Windows — the chord belongs in the label because it is the only place the
/// composer ever names it (Mac does the same).
pub fn label(b: Button) []const u8 {
    return switch (b) {
        .snapshot => "Add a screenshot of the screen (Ctrl+Shift+S)",
        .send => "Send feedback (Ctrl+Enter)",
    };
}

/// Where keyboard focus can be inside the composer (T640). `text` is the text
/// surface — the RichEdit, or the web composer's editor — and is where focus
/// starts and returns to; the other two are the circular actions.
///
/// A CYCLE rather than a chain that tabs out of the band: the composer is a
/// modal-feeling group inside a viewer pane, and the pane's own chrome has no
/// tab order to hand focus on to. Tabbing off the end therefore has exactly
/// one sensible destination, which is where the user was typing.
pub const Stop = enum { text, snapshot, send };

pub fn stopOf(b: Button) Stop {
    return switch (b) {
        .snapshot => .snapshot,
        .send => .send,
    };
}

/// The button a stop names, or null for the text surface.
pub fn buttonOf(s: Stop) ?Button {
    return switch (s) {
        .text => null,
        .snapshot => .snapshot,
        .send => .send,
    };
}

/// The next stop after `cur`, walking forward (Tab) or back (shift+Tab).
///
/// A DISABLED action is skipped, the way Windows skips a disabled control in a
/// dialog's tab order — the send button is dead while the report is empty, and
/// a focus ring on a button that cannot be pressed is a dead end. `text` is
/// always a stop, so the walk always terminates.
pub fn nextStop(cur: Stop, back: bool, enabled: [button_count]bool) Stop {
    const ring = [_]Stop{ .text, .snapshot, .send };
    var i: usize = for (ring, 0..) |s, idx| {
        if (s == cur) break idx;
    } else 0;
    var steps: usize = 0;
    while (steps < ring.len) : (steps += 1) {
        i = if (back)
            (i + ring.len - 1) % ring.len
        else
            (i + 1) % ring.len;
        const s = ring[i];
        const b = buttonOf(s) orelse return s;
        if (enabled[@intFromEnum(b)]) return s;
    }
    return .text;
}

/// The 2 DIP accent focus ring, inset 1 DIP inside the button's painted square
/// (design system §2.2). Returned as the ellipse a GDI pen is stroked ALONG,
/// so the inset already accounts for the pen straddling the path — a ring
/// drawn on the deflated square itself would spill half its width back over
/// the button's edge.
pub const focus_ring_dip: f32 = 2.0;
pub const focus_inset_dip: f32 = 1.0;

pub const FocusRing = struct {
    /// The path the pen follows.
    path: Rect,
    /// Pen width, at least one physical pixel.
    width: i32,
};

pub fn focusRing(scale: f32, painted: Rect) FocusRing {
    const w = @max(px(focus_ring_dip, scale), 1);
    const inset = px(focus_inset_dip, scale) + @divTrunc(w, 2);
    return .{
        .path = .{
            .left = painted.left + inset,
            .top = painted.top + inset,
            .right = painted.right - inset,
            .bottom = painted.bottom - inset,
        },
        .width = w,
    };
}

/// What the bar is being asked to lay out. A struct rather than five
/// positional arguments so a call site cannot silently swap two i32s.
pub const Input = struct {
    /// DPI scale (1.0 = 100%).
    scale: f32,
    /// The pane's width in physical pixels — the band spans it.
    width: i32,
    /// How many lines of text the composer currently holds, before clamping.
    /// 0 and 1 both mean one line: an empty composer is still a one-line pill.
    lines: u32 = 1,
    /// One line box of the composer's font, in physical pixels. Passed in
    /// rather than derived: a font metric belongs to a DC, and this module
    /// must stay OS-free.
    line_h: i32,
    /// How many thumbnails the carousel is showing — i.e. how many LIVE image
    /// chips the composer's text holds. 0 means no carousel at all: the row and
    /// its gap both go away, rather than leaving a band of blank pixels above
    /// the footer.
    images: u32 = 0,
    /// The footer row's height (the destination + key hints), or 0 for no
    /// footer at all — in which case its row gap goes away with it, rather
    /// than leaving a mysterious band of empty pixels.
    footer_h: i32 = 0,
};

/// Everything the composer paints, in physical pixels, in the BAND's own
/// client coordinates (the band is a child window, so its origin is 0,0).
pub const Layout = struct {
    /// The band's height — what the pane reserves above the page for it, on
    /// top of the nav bar's own band.
    bar_h: i32,
    /// The pill.
    pill: Rect,
    /// Corner radius of the pill, fixed at half the collapsed height.
    pill_r: i32,
    /// Where the composer's text is drawn (and where a caret goes).
    text: Rect,
    /// The circular actions, indexed by `Button`.
    buttons: [button_count]Rect,
    /// The thumbnail strip (T646), EMPTY when there are no images. It is the
    /// VIEWPORT: tiles scroll inside it and are clipped to it.
    carousel: Rect,
    /// One tile's side, in physical pixels. 0 when there is no carousel.
    thumb: i32,
    /// Tile pitch — one tile plus the gap after it.
    thumb_stride: i32,
    /// The picture's inset inside its tile.
    thumb_inset: i32,
    /// A tile's corner radius — 4, the design system's control radius. A tile
    /// is a small chip of content, not a card.
    thumb_r: i32,
    /// How many tiles there are, i.e. `Input.images`.
    images: u32,
    /// The footer row, EMPTY when `footer_h` was 0.
    footer: Rect,
    /// Lines actually shown, i.e. `lines` clamped into [1, max_lines].
    lines: u32,

    pub fn init(in: Input) Layout {
        const m = icon_button.Metrics.init(in.scale);
        const pad = px(pad_dip, in.scale);
        const pill_pad = px(pill_pad_dip, in.scale);
        const lines = visibleLines(in.lines);

        // The pill's content band: the taller of the actions and the text.
        // At one line the actions are taller, which is what makes the
        // collapsed pill a true capsule around them.
        const line_h = @max(in.line_h, 1);
        const text_h = line_h * @as(i32, @intCast(lines));
        const content_h = @max(m.target, text_h);
        const pill_h = content_h + 2 * pill_pad;

        // The band spans the pane; the pill keeps `pad` on every side of it.
        const pill: Rect = .{
            .left = pad,
            .top = pad,
            .right = @max(in.width - pad, pad),
            .bottom = pad + pill_h,
        };

        // Actions are pinned to the pill's BOTTOM trailing corner, so they
        // stay put as the pill grows upward (Mac's `.bottom` alignment).
        var buttons: [button_count]Rect = undefined;
        const btn_bottom = pill.bottom - pill_pad;
        var right = pill.right - pill_pad;
        var i: usize = button_count;
        while (i > 0) {
            i -= 1;
            const left = right - m.target;
            buttons[i] = .{
                .left = left,
                .top = btn_bottom - m.target,
                .right = right,
                .bottom = btn_bottom,
            };
            right = left - pill_pad;
        }

        // The text takes what is left, floored so a violently narrow pane
        // yields an empty (never inverted) rect rather than text painted
        // under the buttons.
        const text_left = pill.left + px(text_lead_dip, in.scale);
        const text_right = @max(
            buttons[0].left - px(text_gap_dip, in.scale),
            text_left,
        );
        // Centered in the content band while it is shorter than the actions,
        // top-aligned once it is taller — one expression, no branch to get
        // backwards.
        const text_top = pill.top + pill_pad + @divTrunc(content_h - text_h, 2);

        // Rows stack under the pill, each preceded by ONE gap and only when it
        // is present — an absent row costs no pixels, which is what keeps a
        // composer with no images exactly as tall as it was before T646.
        const gap = px(row_gap_dip, in.scale);
        var y = pill.bottom;

        const thumb = if (in.images > 0) px(thumb_dip, in.scale) else 0;
        const carousel: Rect = if (thumb > 0) c: {
            y += gap;
            const r: Rect = .{
                .left = pill.left,
                .top = y,
                .right = pill.right,
                .bottom = y + thumb,
            };
            y = r.bottom;
            break :c r;
        } else .{};

        const footer_h = @max(in.footer_h, 0);
        const footer: Rect = if (footer_h > 0) f: {
            y += gap;
            const r: Rect = .{
                .left = pill.left,
                .top = y,
                .right = pill.right,
                .bottom = y + footer_h,
            };
            y = r.bottom;
            break :f r;
        } else .{};

        return .{
            .bar_h = y + pad,
            .pill = pill,
            .pill_r = @divTrunc(collapsedPillHeight(in.scale), 2),
            .text = .{
                .left = text_left,
                .top = text_top,
                .right = text_right,
                .bottom = text_top + text_h,
            },
            .buttons = buttons,
            .carousel = carousel,
            .thumb = thumb,
            .thumb_stride = thumb + px(thumb_gap_dip, in.scale),
            .thumb_inset = px(thumb_inset_dip, in.scale),
            .thumb_r = px(4.0, in.scale),
            .images = in.images,
            .footer = footer,
            .lines = lines,
        };
    }

    pub fn button(self: *const Layout, which: Button) Rect {
        return self.buttons[@intFromEnum(which)];
    }

    /// Hit test against the buttons' HIT boxes (grown past the paint, per the
    /// design system: forgiving to click, invisible to layout).
    pub fn hitButton(self: *const Layout, scale: f32, x: i32, y: i32) ?Button {
        const m = icon_button.Metrics.init(scale);
        for (self.buttons, 0..) |b, i| {
            if (b.width() <= 0) continue;
            if (icon_button.hitBox(m, b).containsPoint(x, y)) return @enumFromInt(i);
        }
        return null;
    }

    // ---------------------------------------------------------------------
    // The carousel (T646)
    //
    // Tiles live on one horizontal ribbon inside `carousel`, which is the
    // viewport. `scroll` is how far that ribbon has been pulled left, in
    // physical pixels — the ONE piece of state the caller keeps, so a tile's
    // position is always a function of it rather than something accumulated
    // per tile.
    // ---------------------------------------------------------------------

    /// Tile `index`'s rect in the band's coordinates, which may fall wholly or
    /// partly outside `carousel` — the painter clips, the hit test does not
    /// answer for a tile it cannot see.
    pub fn thumbAt(self: *const Layout, index: usize, scroll: i32) Rect {
        if (self.thumb <= 0) return .{};
        const left = self.carousel.left + @as(i32, @intCast(index)) * self.thumb_stride - scroll;
        return .{
            .left = left,
            .top = self.carousel.top,
            .right = left + self.thumb,
            .bottom = self.carousel.top + self.thumb,
        };
    }

    /// The tile under a point, or null. A tile only answers for the part of it
    /// that is inside the viewport: half a tile poking past the edge is half a
    /// tile the user can see, and the half they cannot is not clickable.
    pub fn hitThumb(self: *const Layout, scroll: i32, x: i32, y: i32) ?usize {
        if (self.thumb <= 0) return null;
        if (!self.carousel.containsPoint(x, y)) return null;
        var i: usize = 0;
        while (i < self.images) : (i += 1) {
            if (self.thumbAt(i, scroll).containsPoint(x, y)) return i;
        }
        return null;
    }

    /// How far the ribbon can be pulled before its last tile sits flush with
    /// the viewport's trailing edge. 0 when everything already fits, which is
    /// what keeps a two-image strip from scrolling at all.
    pub fn maxScroll(self: *const Layout) i32 {
        if (self.thumb <= 0 or self.images == 0) return 0;
        // No trailing gap: the ribbon ends at the last tile, not after it.
        const content = @as(i32, @intCast(self.images)) * self.thumb_stride -
            (self.thumb_stride - self.thumb);
        return @max(content - self.carousel.width(), 0);
    }

    pub fn clampScroll(self: *const Layout, scroll: i32) i32 {
        return std.math.clamp(scroll, 0, self.maxScroll());
    }

    /// The smallest scroll that brings tile `index` fully into view — what
    /// "clicking a chip scrolls to its thumbnail" resolves to. A tile already
    /// visible does not move the strip, so walking the caret across chips that
    /// share a screen does not jitter it.
    pub fn scrollToShow(self: *const Layout, index: usize, scroll: i32) i32 {
        if (self.thumb <= 0 or index >= self.images) return self.clampScroll(scroll);
        const left = @as(i32, @intCast(index)) * self.thumb_stride;
        const right = left + self.thumb;
        const view = self.carousel.width();
        if (left < scroll) return self.clampScroll(left);
        if (right > scroll + view) return self.clampScroll(right - view);
        return self.clampScroll(scroll);
    }
};

/// The largest `src_w` x `src_h` box that fits inside `box` x `box` with the
/// source's aspect ratio intact, at least 1 px on each side.
///
/// A tile is square and a screenshot is not, so something has to give: this
/// letterboxes rather than crops, because a cropped thumbnail of a screenshot
/// is a thumbnail of its middle — and the whole job of the strip is to let a
/// user tell one attachment from another.
pub fn fitInto(src_w: u32, src_h: u32, box: i32) struct { w: i32, h: i32 } {
    if (box <= 0 or src_w == 0 or src_h == 0) return .{ .w = 0, .h = 0 };
    const sw: i64 = @intCast(src_w);
    const sh: i64 = @intCast(src_h);
    const b: i64 = box;
    if (sw >= sh) {
        return .{ .w = box, .h = @intCast(@max(@divTrunc(sh * b, sw), 1)) };
    }
    return .{ .w = @intCast(@max(@divTrunc(sw * b, sh), 1)), .h = box };
}

/// The pill's height with the text collapsed to a single line — the actions
/// are the taller element there, so they set it.
pub fn collapsedPillHeight(scale: f32) i32 {
    const m = icon_button.Metrics.init(scale);
    return m.target + 2 * px(pill_pad_dip, scale);
}

/// `lines` clamped into what the pill will actually grow to. An empty
/// composer is one line, not zero.
pub fn visibleLines(lines: u32) u32 {
    return std.math.clamp(if (lines == 0) 1 else lines, 1, max_lines);
}

fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

// -----------------------------------------------------------------------------

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

/// A plausible body line box at `scale`. The real one comes from the DC; this
/// is the tests' stand-in and is deliberately SHORTER than the 28 DIP action
/// square, which is the interesting case (a one-line pill is sized by its
/// buttons, not by its text).
fn lineAt(scale: f32) i32 {
    return px(19.0, scale);
}

test "composer geometry holds the design system at every scale" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const gap = px(4.0, scale);
        const width = px(600.0, scale);
        for ([_]u32{ 1, 2, 6 }) |lines| {
            const l = Layout.init(.{
                .scale = scale,
                .width = width,
                .lines = lines,
                .line_h = lineAt(scale),
                .footer_h = lineAt(scale),
            });

            // Nothing touches anything: the pill keeps >= 4 DIP from every
            // band edge (it keeps 8, the group step, but the FLOOR is what
            // the design system states).
            try testing.expect(l.pill.left >= gap);
            try testing.expect(l.pill.top >= gap);
            try testing.expect(width - l.pill.right >= gap);
            try testing.expect(l.bar_h - l.footer.bottom >= gap);

            // Both actions are the ONE shared icon-button square, sit inside
            // the pill's trailing edge, and clear it by >= 4 DIP on the
            // sides they touch.
            for (l.buttons) |b| {
                try testing.expectEqual(m.target, b.width());
                try testing.expectEqual(m.target, b.height());
                try testing.expect(b.top >= l.pill.top + gap);
                try testing.expect(l.pill.bottom - b.bottom >= gap);
                try testing.expect(b.left > l.pill.left);
                try testing.expect(l.pill.right - b.right >= gap);
            }
            // ...and >= 4 DIP between the two painted squares, in strip order.
            const snap = l.button(.snapshot);
            const send = l.button(.send);
            try testing.expect(send.left - snap.right >= gap);
            // The send button is the trailing one, hard against the pad.
            try testing.expectEqual(l.pill.right - px(pill_pad_dip, scale), send.right);
            // Both actions share one vertical frame (design system §2.1).
            try testing.expectEqual(snap.top, send.top);
            try testing.expectEqual(snap.bottom, send.bottom);

            // The text clears the first action by the group step and never
            // runs under it.
            try testing.expect(l.text.right <= snap.left - px(text_gap_dip, scale));
            try testing.expect(l.text.left > l.pill.left);
            try testing.expect(l.text.right > l.text.left);
            // ...and stays inside the pill vertically.
            try testing.expect(l.text.top >= l.pill.top);
            try testing.expect(l.text.bottom <= l.pill.bottom);

            // The footer is the pill's own column, one row gap below it.
            try testing.expectEqual(l.pill.left, l.footer.left);
            try testing.expectEqual(l.pill.right, l.footer.right);
            try testing.expectEqual(l.pill.bottom + px(row_gap_dip, scale), l.footer.top);

            // The band is exactly its parts (this is the number the pane
            // insets the page by, so an off-by-one here is a visible gap).
            try testing.expectEqual(
                px(pad_dip, scale) * 2 + l.pill.height() +
                    px(row_gap_dip, scale) + lineAt(scale),
                l.bar_h,
            );
        }
    }
}

test "the pill grows a line at a time and stops at six" {
    for (scales) |scale| {
        const line = lineAt(scale);
        var prev: i32 = 0;
        for (1..max_lines + 1) |n| {
            const l = Layout.init(.{
                .scale = scale,
                .width = px(600.0, scale),
                .lines = @intCast(n),
                .line_h = line,
            });
            try testing.expectEqual(@as(u32, @intCast(n)), l.lines);
            // Monotonic: every extra line reserves more space, never less.
            try testing.expect(l.bar_h > prev);
            prev = l.bar_h;
        }

        // Past the cap the band stops growing — the text scrolls instead of
        // eating the pane the feedback is about.
        const at_cap = Layout.init(.{
            .scale = scale,
            .width = px(600.0, scale),
            .lines = max_lines,
            .line_h = line,
        });
        for ([_]u32{ max_lines + 1, 40, 4000 }) |n| {
            const over = Layout.init(.{
                .scale = scale,
                .width = px(600.0, scale),
                .lines = n,
                .line_h = line,
            });
            try testing.expectEqual(at_cap.bar_h, over.bar_h);
            try testing.expectEqual(max_lines, over.lines);
        }
    }
}

test "an empty composer is a one-line capsule sized by its buttons" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const empty = Layout.init(.{
            .scale = scale,
            .width = px(600.0, scale),
            .lines = 0,
            .line_h = lineAt(scale),
        });
        const one = Layout.init(.{
            .scale = scale,
            .width = px(600.0, scale),
            .lines = 1,
            .line_h = lineAt(scale),
        });
        try testing.expectEqual(@as(u32, 1), empty.lines);
        try testing.expectEqual(one.bar_h, empty.bar_h);

        // At one line the ACTIONS set the height, so the pill is exactly the
        // collapsed capsule and its radius is exactly half of it: the ends
        // are semicircles, not rounded corners.
        try testing.expectEqual(collapsedPillHeight(scale), empty.pill.height());
        try testing.expectEqual(m.target + 2 * px(pill_pad_dip, scale), empty.pill.height());
        try testing.expectEqual(@divTrunc(empty.pill.height(), 2), empty.pill_r);

        // A single short line is CENTERED against the taller buttons rather
        // than sitting on the pill's floor.
        const above = empty.text.top - empty.pill.top;
        const below = empty.pill.bottom - empty.text.bottom;
        try testing.expect(@abs(above - below) <= 1);
    }
}

test "the corner radius is pinned to the collapsed height, not the current one" {
    // Mac's rule, and the reason it is a rule: a radius recomputed as
    // height/2 turns a six-line pill into an oval. The straight sides
    // lengthen; the caps do not change.
    for (scales) |scale| {
        const one = Layout.init(.{ .scale = scale, .width = 800, .lines = 1, .line_h = lineAt(scale) });
        const six = Layout.init(.{ .scale = scale, .width = 800, .lines = 6, .line_h = lineAt(scale) });
        try testing.expectEqual(one.pill_r, six.pill_r);
        try testing.expect(six.pill.height() > one.pill.height());
        // ...and the tall pill is emphatically NOT a capsule any more.
        try testing.expect(six.pill_r * 2 < six.pill.height());
    }
}

test "no footer means no footer row and no gap left behind" {
    for (scales) |scale| {
        const l = Layout.init(.{
            .scale = scale,
            .width = px(600.0, scale),
            .lines = 1,
            .line_h = lineAt(scale),
            .footer_h = 0,
        });
        try testing.expect(l.footer.isEmpty());
        try testing.expectEqual(
            px(pad_dip, scale) * 2 + l.pill.height(),
            l.bar_h,
        );
    }
}

test "a violently narrow pane never inverts the text rect" {
    for (scales) |scale| {
        for ([_]i32{ 0, 10, 60 }) |width| {
            const l = Layout.init(.{
                .scale = scale,
                .width = width,
                .lines = 3,
                .line_h = lineAt(scale),
            });
            try testing.expect(l.text.right >= l.text.left);
            try testing.expect(l.pill.right >= l.pill.left);
            // The band still reports a sane height, so the pane's inset can
            // never go negative.
            try testing.expect(l.bar_h > 0);
        }
    }
}

test "hit testing answers on the hit box, not the paint" {
    const scale: f32 = 1.25;
    const m = icon_button.Metrics.init(scale);
    const l = Layout.init(.{ .scale = scale, .width = 800, .lines = 1, .line_h = lineAt(scale) });
    for ([_]Button{ .snapshot, .send }) |which| {
        const b = l.button(which);
        try testing.expectEqual(
            which,
            l.hitButton(scale, @divTrunc(b.left + b.right, 2), @divTrunc(b.top + b.bottom, 2)).?,
        );
        // Just past the paint but inside the hit pad still answers.
        try testing.expectEqual(
            which,
            l.hitButton(scale, b.left, b.bottom + m.hit_pad - 1).?,
        );
    }
    // The text region is nobody's button, and neither is the band's far edge.
    try testing.expectEqual(
        @as(?Button, null),
        l.hitButton(scale, l.text.left, @divTrunc(l.text.top + l.text.bottom, 2)),
    );
    try testing.expectEqual(@as(?Button, null), l.hitButton(scale, 0, l.bar_h * 3));
}

// ----------------------------------------------------------------- carousel

test "no images means no carousel row and no gap left behind" {
    // The same rule the footer follows, and the one T646 names explicitly: a
    // composer nobody pasted into must be exactly as tall as it was before the
    // strip existed.
    for (scales) |scale| {
        const base: Input = .{
            .scale = scale,
            .width = px(600.0, scale),
            .lines = 1,
            .line_h = lineAt(scale),
            .footer_h = lineAt(scale),
        };
        const none = Layout.init(base);
        try testing.expect(none.carousel.isEmpty());
        try testing.expectEqual(@as(i32, 0), none.thumb);
        try testing.expectEqual(@as(i32, 0), none.maxScroll());
        try testing.expect(none.thumbAt(0, 0).isEmpty());
        try testing.expectEqual(@as(?usize, null), none.hitThumb(0, 0, 0));
        // The footer sits one gap under the pill, exactly as it did with no
        // carousel in the world at all.
        try testing.expectEqual(none.pill.bottom + px(row_gap_dip, scale), none.footer.top);
        try testing.expectEqual(
            px(pad_dip, scale) * 2 + none.pill.height() +
                px(row_gap_dip, scale) + lineAt(scale),
            none.bar_h,
        );
    }
}

test "the carousel is a row of square tiles between the pill and the footer" {
    for (scales) |scale| {
        const gap = px(4.0, scale);
        const row_gap = px(row_gap_dip, scale);
        const width = px(600.0, scale);
        for ([_]u32{ 1, 2, 7 }) |n| {
            const l = Layout.init(.{
                .scale = scale,
                .width = width,
                .lines = 1,
                .line_h = lineAt(scale),
                .footer_h = lineAt(scale),
                .images = n,
            });

            // The strip is the pill's own column, one row gap below it, and
            // the footer moves down by exactly the strip plus its gap.
            try testing.expectEqual(l.pill.left, l.carousel.left);
            try testing.expectEqual(l.pill.right, l.carousel.right);
            try testing.expectEqual(l.pill.bottom + row_gap, l.carousel.top);
            try testing.expectEqual(px(thumb_dip, scale), l.carousel.height());
            try testing.expectEqual(l.carousel.bottom + row_gap, l.footer.top);

            // Nothing touches anything, band edges included.
            try testing.expect(l.carousel.left >= gap);
            try testing.expect(width - l.carousel.right >= gap);
            try testing.expect(l.bar_h - l.footer.bottom >= gap);

            // The band is exactly its parts — this is the number the pane
            // insets the page by.
            try testing.expectEqual(
                px(pad_dip, scale) * 2 + l.pill.height() +
                    row_gap + l.carousel.height() +
                    row_gap + lineAt(scale),
                l.bar_h,
            );

            // Tiles are squares on one pitch, sharing the strip's vertical
            // frame, with >= 4 DIP between two painted edges.
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const t = l.thumbAt(i, 0);
                try testing.expectEqual(l.thumb, t.width());
                try testing.expectEqual(l.thumb, t.height());
                try testing.expectEqual(l.carousel.top, t.top);
                try testing.expectEqual(l.carousel.bottom, t.bottom);
                if (i > 0) {
                    try testing.expect(t.left - l.thumbAt(i - 1, 0).right >= gap);
                }
            }
        }
    }
}

test "the strip scrolls only when it has to, and never past its ends" {
    for (scales) |scale| {
        // A 300 DIP pane holds three tiles comfortably and nine not at all:
        // the interesting case is a ribbon LONGER than its viewport, which is
        // where scroll exists at all.
        const l3 = Layout.init(.{
            .scale = scale,
            .width = px(300.0, scale),
            .lines = 1,
            .line_h = lineAt(scale),
            .images = 3,
        });
        const l9 = Layout.init(.{
            .scale = scale,
            .width = px(300.0, scale),
            .lines = 1,
            .line_h = lineAt(scale),
            .images = 9,
        });

        // Three tiles fit, so there is nothing to scroll.
        try testing.expectEqual(@as(i32, 0), l3.maxScroll());
        try testing.expectEqual(@as(i32, 0), l3.scrollToShow(2, 0));
        // Nine do not.
        try testing.expect(l9.maxScroll() > 0);

        // Scrolled to the end, the LAST tile sits flush with the trailing edge
        // — an off-by-one here shows as a permanently clipped final tile.
        const end = l9.maxScroll();
        try testing.expectEqual(l9.carousel.right, l9.thumbAt(8, end).right);
        try testing.expectEqual(l9.carousel.left, l9.thumbAt(0, 0).left);

        // Clamped at both ends, whatever it is handed.
        try testing.expectEqual(@as(i32, 0), l9.clampScroll(-9999));
        try testing.expectEqual(end, l9.clampScroll(end + 9999));

        // Bring the last tile into view; the first is then off the left.
        const to_last = l9.scrollToShow(8, 0);
        try testing.expectEqual(end, to_last);
        try testing.expect(l9.thumbAt(0, to_last).right <= l9.carousel.left);
        // Coming back to the first pulls the ribbon home.
        try testing.expectEqual(@as(i32, 0), l9.scrollToShow(0, to_last));
        // A tile already fully visible does not move the strip at all.
        try testing.expectEqual(to_last, l9.scrollToShow(8, to_last));
        // An index nobody has does not move it either.
        try testing.expectEqual(to_last, l9.scrollToShow(99, to_last));
    }
}

test "a tile only answers a click on the part of it that is on screen" {
    const scale: f32 = 1.25;
    const l = Layout.init(.{
        .scale = scale,
        .width = px(300.0, scale),
        .lines = 1,
        .line_h = lineAt(scale),
        .footer_h = lineAt(scale),
        .images = 9,
    });
    const mid_y = @divTrunc(l.carousel.top + l.carousel.bottom, 2);

    // Every tile whose centre is inside the viewport answers for itself.
    var i: usize = 0;
    while (i < l.images) : (i += 1) {
        const t = l.thumbAt(i, 0);
        const cx = @divTrunc(t.left + t.right, 2);
        const expected: ?usize = if (l.carousel.contains(cx)) i else null;
        try testing.expectEqual(expected, l.hitThumb(0, cx, mid_y));
    }

    // The gap between two tiles is nobody's, and neither is the row above or
    // below the strip.
    const gap_x = l.thumbAt(0, 0).right + 1;
    try testing.expectEqual(@as(?usize, null), l.hitThumb(0, gap_x, mid_y));
    try testing.expectEqual(@as(?usize, null), l.hitThumb(0, l.thumbAt(0, 0).left + 1, l.pill.top));
    try testing.expectEqual(@as(?usize, null), l.hitThumb(0, l.thumbAt(0, 0).left + 1, l.footer.top));

    // A tile scrolled off the leading edge is not clickable ANYWHERE — the
    // ribbon moved, and the hit test moved with it rather than answering for
    // the pixels the tile used to own.
    const end = l.maxScroll();
    try testing.expect(end > 0);
    var x = l.carousel.left;
    while (x < l.carousel.right) : (x += 1) {
        try testing.expect(l.hitThumb(end, x, mid_y) != @as(?usize, 0));
    }
    // ...and the LAST tile, which the same scroll brought flush with the
    // trailing edge, answers there.
    try testing.expectEqual(@as(?usize, 8), l.hitThumb(end, l.carousel.right - 2, mid_y));
}

test "fitInto letterboxes rather than crops, and never yields a zero side" {
    // A landscape screenshot fills the tile's width; a portrait one its height.
    try testing.expectEqual(@as(i32, 56), fitInto(1920, 1080, 56).w);
    try testing.expectEqual(@as(i32, 31), fitInto(1920, 1080, 56).h);
    try testing.expectEqual(@as(i32, 56), fitInto(600, 1200, 56).h);
    try testing.expectEqual(@as(i32, 28), fitInto(600, 1200, 56).w);
    // A square stays square.
    try testing.expectEqual(@as(i32, 40), fitInto(10, 10, 40).w);
    try testing.expectEqual(@as(i32, 40), fitInto(10, 10, 40).h);
    // A 1x2000 sliver still has a pixel of width — a zero-width blit is a
    // failure, and an invisible attachment is worse than a smudged one.
    try testing.expectEqual(@as(i32, 1), fitInto(1, 2000, 56).w);
    // Degenerate inputs answer empty rather than dividing by zero.
    try testing.expectEqual(@as(i32, 0), fitInto(0, 10, 56).w);
    try testing.expectEqual(@as(i32, 0), fitInto(10, 0, 56).h);
    try testing.expectEqual(@as(i32, 0), fitInto(10, 10, 0).w);
}

// T640: the composer's keyboard focus model. The walk is the whole feature —
// a button nobody can reach is a button nobody can use — so it is asserted
// here, in a lane with no window in it, rather than only on the box.
test "nextStop walks text -> snapshot -> send -> text, and back" {
    const all = [_]bool{ true, true };

    try testing.expectEqual(Stop.snapshot, nextStop(.text, false, all));
    try testing.expectEqual(Stop.send, nextStop(.snapshot, false, all));
    try testing.expectEqual(Stop.text, nextStop(.send, false, all));

    try testing.expectEqual(Stop.send, nextStop(.text, true, all));
    try testing.expectEqual(Stop.snapshot, nextStop(.send, true, all));
    try testing.expectEqual(Stop.text, nextStop(.snapshot, true, all));
}

test "nextStop skips a disabled action rather than parking focus on it" {
    // The shipped case: an empty report, so send is dead. Tab from the text
    // reaches "+" and the next Tab goes back to the text — never onto a
    // button that cannot be pressed.
    var enabled = [_]bool{ true, true };
    enabled[@intFromEnum(Button.send)] = false;
    try testing.expectEqual(Stop.snapshot, nextStop(.text, false, enabled));
    try testing.expectEqual(Stop.text, nextStop(.snapshot, false, enabled));
    try testing.expectEqual(Stop.snapshot, nextStop(.text, true, enabled));

    // And with neither action live the walk still terminates on the text
    // rather than spinning.
    const none = [_]bool{ false, false };
    try testing.expectEqual(Stop.text, nextStop(.text, false, none));
    try testing.expectEqual(Stop.text, nextStop(.send, false, none));
}

test "the focus ring stays inside the button's painted square at every scale" {
    for (scales) |s| {
        const m = icon_button.Metrics.init(s);
        const painted: Rect = .{
            .left = 100,
            .top = 40,
            .right = 100 + m.target,
            .bottom = 40 + m.target,
        };
        const ring = focusRing(s, painted);
        try testing.expect(ring.width >= 1);
        // The stroke straddles the path, so the OUTER edge is what has to
        // clear the button's own square — a ring bleeding over the edge reads
        // as a rendering fault, not as focus.
        const half = @divTrunc(ring.width, 2);
        try testing.expect(ring.path.left - half >= painted.left);
        try testing.expect(ring.path.top - half >= painted.top);
        try testing.expect(ring.path.right + half <= painted.right);
        try testing.expect(ring.path.bottom + half <= painted.bottom);
        // And it is still a ring, not a dot.
        try testing.expect(ring.path.width() > ring.width * 2);
    }
}

test "every action has a label naming what it does and its chord" {
    for (std.enums.values(Button)) |b| {
        const text = label(b);
        try testing.expect(text.len > 0);
        // The chord is the half a user cannot discover any other way.
        try testing.expect(std.mem.indexOf(u8, text, "Ctrl+") != null);
        try testing.expectEqual(stopOf(b), stopOf(buttonOf(stopOf(b)).?));
    }
    try testing.expect(buttonOf(.text) == null);
}
