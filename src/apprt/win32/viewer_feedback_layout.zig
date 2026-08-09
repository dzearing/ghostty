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

/// How many lines the pill grows to before the text scrolls instead. Mac's
/// `maxInputHeight` is ~6 lines and the reason is the same here: past this the
/// composer is eating the pane the feedback is ABOUT.
pub const max_lines: u32 = 6;

/// The two circular actions inside the pill's trailing edge, in strip order.
/// `snapshot` is Mac's `+` (add a screenshot), `send` its `↑`.
pub const Button = enum { snapshot, send };
pub const button_count = std.enums.values(Button).len;

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

        const footer_h = @max(in.footer_h, 0);
        const row_gap = if (footer_h > 0) px(row_gap_dip, in.scale) else 0;
        const footer: Rect = if (footer_h > 0) .{
            .left = pill.left,
            .top = pill.bottom + row_gap,
            .right = pill.right,
            .bottom = pill.bottom + row_gap + footer_h,
        } else .{};

        return .{
            .bar_h = pad + pill_h + row_gap + footer_h + pad,
            .pill = pill,
            .pill_r = @divTrunc(collapsedPillHeight(in.scale), 2),
            .text = .{
                .left = text_left,
                .top = text_top,
                .right = text_right,
                .bottom = text_top + text_h,
            },
            .buttons = buttons,
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
};

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
