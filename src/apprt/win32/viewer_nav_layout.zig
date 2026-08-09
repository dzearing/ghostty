//! Geometry and reveal policy for the viewer nav bar (T159, design P3): where
//! the four buttons and the address field sit at one DPI scale, how tall the
//! hover strip is, and WHEN the bar shows or hides. Pure — every number is
//! arithmetic on the design-system scale, so the whole module asserts in the
//! none-runtime lane at 1.0/1.25/1.5/2.0 (the defects this catches are
//! invisible at 1.0 and obvious at 1.25).
//!
//! Reveal geometry follows Mac (`ViewerView.chromeRevealHeight` = 20, 2s
//! auto-hide, held open while the address field has focus or the cursor is on
//! the bar). The DECISION lives here rather than in the timer handler so the
//! show/hide policy is a table a unit test walks, not a WM_TIMER side effect.

const std = @import("std");
const icon_button = @import("icon_button.zig");

pub const Rect = icon_button.Rect;

/// The pane-top strip (in DIP) that reveals the bar on hover. Deliberately
/// thin so ordinary interaction with the page never triggers the bar — only
/// an intentional move to the very top edge (Mac's `chromeRevealHeight`).
pub const reveal_dip: f32 = 20.0;

/// Bar height: a 28 DIP icon button with the design system's 4 DIP breathing
/// room above and below. The container is sized to the control, not the
/// reverse.
pub const bar_dip: f32 = 36.0;

/// Auto-hide delays, matching Mac's `scheduleChromeHide` call sites: 2s after
/// the strip revealed it, 0.7s once the cursor has drifted down into the
/// content, 0.5s once it has left the pane entirely.
pub const hide_delay_ms: u32 = 2000;
pub const drift_delay_ms: u32 = 700;
pub const leave_delay_ms: u32 = 500;

/// How often the pane samples the cursor. Polling, not `TrackMouseEvent`:
/// the mouse spends its life over WebView2's own Chromium child windows, so
/// the host window never receives the move messages a tracking rectangle
/// needs (the same reason Mac uses an app-local event monitor here).
pub const poll_ms: u32 = 150;

/// The bar's buttons, in strip order. `contents` leads and exists only in a
/// narrow viewer pane whose document has a table of contents (T160): the
/// compact card's only opener lives in the chrome bar, which is why the bar
/// pins open there. Mac puts the same button first in its chrome bar.
///
/// `feedback` TRAILS — it is the only button on the far side of the address
/// field — and exists only when the pane's content resolves to a git worktree
/// (T633). With nowhere to file a report the button would be a lie, so it is
/// absent rather than disabled; Mac's chrome bar places and gates it the same
/// way.
pub const Button = enum { contents, back, forward, reload, home, feedback };
pub const button_count = std.enums.values(Button).len;

/// Which of the two conditional buttons this bar is showing. A struct rather
/// than positional bools so a third condition cannot silently swap with a
/// second at a call site.
pub const Shown = struct {
    contents: bool = false,
    feedback: bool = false,
};

/// Everything the bar paints, in physical pixels, for one scale and width.
pub const Layout = struct {
    /// Bar band height (the host window insets the content by exactly this
    /// while the bar is visible, so top-of-page content is never covered).
    bar_h: i32,
    /// Hover strip height, for the reveal test.
    reveal_h: i32,
    /// Painted squares of the buttons, indexed by `Button`. A button the bar
    /// is not showing (the contents toggle outside the compact TOC layout)
    /// has an EMPTY rect: it takes no room, paints nothing, and hits nothing.
    buttons: [button_count]Rect,
    /// The address field (a real EDIT control fills this rect).
    address: Rect,

    pub fn init(scale: f32, width: i32, shown: Shown) Layout {
        const m = icon_button.Metrics.init(scale);
        const pad = px(4.0, scale); // band edge + inter-button gap
        const field_gap = px(8.0, scale); // buttons cluster <-> field
        const bar_h = px(bar_dip, scale);
        const top = @divTrunc(bar_h - m.target, 2);

        var buttons: [button_count]Rect = undefined;
        var x = pad;
        for (&buttons, 0..) |*b, i| {
            const absent = switch (@as(Button, @enumFromInt(i))) {
                .contents => !shown.contents,
                .feedback => true, // placed from the trailing edge below
                else => false,
            };
            if (absent) {
                b.* = .{ .left = x, .top = top, .right = x, .bottom = top };
                continue;
            }
            b.* = .{
                .left = x,
                .top = top,
                .right = x + m.target,
                .bottom = top + m.target,
            };
            x += m.target + pad;
        }

        // The leading cluster's right edge — where the field may start, and the
        // floor the trailing button may not cross.
        const cluster_right = x - pad;

        // Feedback trails: measured in from the band's own right edge, never
        // past the leading cluster. A pane too narrow to hold both squeezes the
        // FIELD to nothing rather than overlapping two painted controls.
        if (shown.feedback) {
            const left = @max(width - pad - m.target, cluster_right + pad);
            buttons[@intFromEnum(Button.feedback)] = .{
                .left = left,
                .top = top,
                .right = left + m.target,
                .bottom = top + m.target,
            };
        }

        // The field takes what is left, floored so a violently narrow pane
        // yields an empty (never inverted) rect rather than a control painted
        // over the buttons.
        const field_left = cluster_right + field_gap;
        const field_limit = if (shown.feedback)
            buttons[@intFromEnum(Button.feedback)].left - field_gap
        else
            width - field_gap;
        const field_right = @max(field_limit, field_left);
        return .{
            .bar_h = bar_h,
            .reveal_h = px(reveal_dip, scale),
            .buttons = buttons,
            .address = .{
                .left = field_left,
                .top = top,
                .right = field_right,
                .bottom = top + m.target,
            },
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
            // An absent button's empty rect must not answer hits — inflating
            // it by the hit pad would otherwise conjure a phantom target.
            if (b.width() <= 0) continue;
            if (icon_button.hitBox(m, b).containsPoint(x, y)) {
                return @enumFromInt(i);
            }
        }
        return null;
    }
};

fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

// -----------------------------------------------------------------------------
// Reveal policy
// -----------------------------------------------------------------------------

/// One cursor sample, in the pane's own coordinates.
pub const HoverInput = struct {
    /// Cursor is inside the pane's client rect.
    in_pane: bool,
    /// Cursor y in pane coordinates (physical px); meaningless when
    /// `in_pane` is false.
    y: i32 = 0,
    /// The bar is currently shown.
    visible: bool,
    /// The bar must not hide out from under the user: the address field has
    /// keyboard focus, or the cursor is on the bar itself.
    held: bool,
    now_ms: u64,
    /// The pending hide deadline, 0 when none is scheduled.
    deadline_ms: u64,
    reveal_h: i32,
};

pub const HoverAction = struct {
    show: bool = false,
    hide: bool = false,
    deadline_ms: u64 = 0,
};

/// Decide what this cursor sample does to the bar. The rules, in order:
/// - held (field focused, or cursor on the bar): never hide; keep pushing the
///   deadline out.
/// - cursor in the reveal strip: show if hidden, and re-arm the full delay.
/// - otherwise, a visible bar hides when its deadline lapses; drifting into
///   the content or out of the pane can only PULL the deadline in, never push
///   it out (Mac's shorter re-schedules).
pub fn hoverTick(in: HoverInput) HoverAction {
    var out: HoverAction = .{ .deadline_ms = in.deadline_ms };

    if (in.held) {
        out.deadline_ms = in.now_ms + hide_delay_ms;
        return out;
    }

    if (in.in_pane and in.y >= 0 and in.y < in.reveal_h) {
        if (!in.visible) out.show = true;
        out.deadline_ms = in.now_ms + hide_delay_ms;
        return out;
    }

    if (!in.visible) return out;

    const cap: u64 = if (in.in_pane)
        in.now_ms + drift_delay_ms
    else
        in.now_ms + leave_delay_ms;
    if (out.deadline_ms == 0 or out.deadline_ms > cap) out.deadline_ms = cap;

    if (in.now_ms >= out.deadline_ms) {
        out.hide = true;
        out.deadline_ms = 0;
    }
    return out;
}

// -----------------------------------------------------------------------------

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "bar geometry holds the design system at every scale" {
    for (scales) |scale| {
        // Every bar variant holds the same rules: the two conditional buttons
        // either take their slot or take no room at all.
        for ([_]Shown{
            .{},
            .{ .contents = true },
            .{ .feedback = true },
            .{ .contents = true, .feedback = true },
        }) |shown| {
            const m = icon_button.Metrics.init(scale);
            const l = Layout.init(scale, px(600.0, scale), shown);
            const gap = px(4.0, scale);

            // The band is the control plus 4 DIP above and below — sized to
            // the control, and tall enough that nothing touches its edges.
            try testing.expect(l.bar_h >= m.target + 2 * gap - 1);
            for (l.buttons) |b| {
                if (b.width() <= 0) continue; // absent contents toggle
                try testing.expect(b.top >= gap - 1);
                try testing.expect(l.bar_h - b.bottom >= gap - 1);
                // Painted square is the shared icon-button size.
                try testing.expectEqual(m.target, b.width());
                try testing.expectEqual(m.target, b.height());
            }

            // >= 4 DIP between any two painted squares, and buttons stay in
            // strip order with no overlap.
            var prev: ?Rect = null;
            for (l.buttons) |b| {
                if (b.width() <= 0) continue;
                if (prev) |p| try testing.expect(b.left - p.right >= gap);
                prev = b;
            }

            // The field clears the leading cluster by 8 DIP and the band edge
            // (or the trailing button) by 8, and shares the buttons' band.
            try testing.expect(l.address.left - l.button(.home).right >= px(8.0, scale));
            try testing.expectEqual(l.button(.home).top, l.address.top);
            try testing.expect(l.address.right < px(600.0, scale));
            if (shown.feedback) {
                const fb = l.button(.feedback);
                try testing.expect(fb.left - l.address.right >= px(8.0, scale));
                // And the trailing button keeps the band's own 4 DIP edge.
                try testing.expect(px(600.0, scale) - fb.right >= gap - 1);
            }

            // Reveal strip is 20 DIP.
            try testing.expectEqual(px(reveal_dip, scale), l.reveal_h);
        }
    }
}

test "the feedback button trails the field, and is absent when not asked for" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const width = px(600.0, scale);
        const without = Layout.init(scale, width, .{});
        const with = Layout.init(scale, width, .{ .feedback = true });

        // Absent: an empty rect that answers no hit, even dead on the spot the
        // present one occupies.
        try testing.expectEqual(@as(i32, 0), without.button(.feedback).width());
        const at = with.button(.feedback);
        try testing.expect(
            without.hitButton(scale, at.left + 1, at.top + 1) != Button.feedback,
        );

        // Present: standard square, hard against the band's trailing 4 DIP
        // edge, and the field gives up exactly that much width.
        try testing.expectEqual(m.target, at.width());
        try testing.expectEqual(m.target, at.height());
        try testing.expectEqual(width - px(4.0, scale), at.right);
        try testing.expect(with.address.right < without.address.right);
        try testing.expectEqual(
            Button.feedback,
            with.hitButton(scale, @divTrunc(at.left + at.right, 2), @divTrunc(at.top + at.bottom, 2)).?,
        );
    }
}

test "a narrow pane squeezes the field, never overlaps two painted buttons" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const gap = px(4.0, scale);
        // Narrow enough that the trailing button would land inside the leading
        // cluster if it were measured from the right edge alone.
        for ([_]i32{ 10, m.target * 2, m.target * 5 }) |width| {
            const l = Layout.init(scale, width, .{ .contents = true, .feedback = true });
            try testing.expect(l.address.right >= l.address.left);
            try testing.expect(l.button(.feedback).left - l.button(.home).right >= gap);
        }
    }
}

test "the contents toggle leads the strip, and is absent when not asked for" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const without = Layout.init(scale, px(600.0, scale), .{});
        const with = Layout.init(scale, px(600.0, scale), .{ .contents = true });

        // Absent: an empty rect, and the back button holds the lead slot.
        try testing.expectEqual(@as(i32, 0), without.button(.contents).width());
        try testing.expectEqual(px(4.0, scale), without.button(.back).left);
        // And an empty rect answers no hit, even dead on its position.
        const c = without.button(.contents);
        try testing.expect(without.hitButton(scale, c.left, c.top) != Button.contents);

        // Present: first in the strip, standard size, and everything after it
        // shifts right by one slot.
        try testing.expectEqual(px(4.0, scale), with.button(.contents).left);
        try testing.expectEqual(m.target, with.button(.contents).width());
        try testing.expectEqual(
            with.button(.contents).right + px(4.0, scale),
            with.button(.back).left,
        );
    }
}

test "a violently narrow pane never inverts the field rect" {
    for (scales) |scale| {
        const l = Layout.init(scale, 10, .{ .contents = true });
        try testing.expect(l.address.right >= l.address.left);
    }
}

test "hit testing answers on the hit box, not the paint" {
    const scale: f32 = 1.25;
    const m = icon_button.Metrics.init(scale);
    const l = Layout.init(scale, 800, .{});
    const back = l.button(.back);
    // Dead center of the painted square.
    try testing.expectEqual(
        Button.back,
        l.hitButton(scale, @divTrunc(back.left + back.right, 2), @divTrunc(back.top + back.bottom, 2)).?,
    );
    // Just past the paint but inside the hit pad still answers.
    try testing.expectEqual(
        Button.back,
        l.hitButton(scale, back.right + m.hit_pad - 1, back.top).?,
    );
    // The gap midpoint between two buttons belongs to whichever hit box
    // reaches it first or neither — never both; here just assert it does not
    // crash and resolves deterministically.
    _ = l.hitButton(scale, back.right + m.hit_pad + 1, -50);
    // Far outside is nobody's.
    try testing.expectEqual(@as(?Button, null), l.hitButton(scale, 0, l.bar_h * 3));
}

test "hover policy: strip reveals, drift and leave pull the deadline in" {
    const reveal = 25; // px at some scale; the policy is scale-agnostic

    // In the strip, hidden -> show with the full delay armed.
    var a = hoverTick(.{
        .in_pane = true,
        .y = 10,
        .visible = false,
        .held = false,
        .now_ms = 1000,
        .deadline_ms = 0,
        .reveal_h = reveal,
    });
    try testing.expect(a.show);
    try testing.expectEqual(@as(u64, 1000 + hide_delay_ms), a.deadline_ms);

    // Still in the strip -> deadline keeps re-arming, no hide.
    a = hoverTick(.{
        .in_pane = true,
        .y = 5,
        .visible = true,
        .held = false,
        .now_ms = 2000,
        .deadline_ms = 3000,
        .reveal_h = reveal,
    });
    try testing.expect(!a.show and !a.hide);
    try testing.expectEqual(@as(u64, 2000 + hide_delay_ms), a.deadline_ms);

    // Drift into the content: the 2s deadline is pulled IN to 0.7s...
    a = hoverTick(.{
        .in_pane = true,
        .y = 300,
        .visible = true,
        .held = false,
        .now_ms = 2100,
        .deadline_ms = 4000,
        .reveal_h = reveal,
    });
    try testing.expect(!a.hide);
    try testing.expectEqual(@as(u64, 2100 + drift_delay_ms), a.deadline_ms);

    // ...but a deadline already sooner is never pushed OUT.
    a = hoverTick(.{
        .in_pane = true,
        .y = 300,
        .visible = true,
        .held = false,
        .now_ms = 2200,
        .deadline_ms = 2400,
        .reveal_h = reveal,
    });
    try testing.expectEqual(@as(u64, 2400), a.deadline_ms);

    // Leaving the pane arms the shortest delay.
    a = hoverTick(.{
        .in_pane = false,
        .visible = true,
        .held = false,
        .now_ms = 3000,
        .deadline_ms = 0,
        .reveal_h = reveal,
    });
    try testing.expectEqual(@as(u64, 3000 + leave_delay_ms), a.deadline_ms);

    // The deadline lapsing hides the bar and clears itself.
    a = hoverTick(.{
        .in_pane = true,
        .y = 300,
        .visible = true,
        .held = false,
        .now_ms = 5000,
        .deadline_ms = 4500,
        .reveal_h = reveal,
    });
    try testing.expect(a.hide);
    try testing.expectEqual(@as(u64, 0), a.deadline_ms);

    // Held (field focused / cursor on the bar): never hides, keeps re-arming,
    // even outside the pane.
    a = hoverTick(.{
        .in_pane = false,
        .visible = true,
        .held = true,
        .now_ms = 9000,
        .deadline_ms = 100,
        .reveal_h = reveal,
    });
    try testing.expect(!a.hide);
    try testing.expectEqual(@as(u64, 9000 + hide_delay_ms), a.deadline_ms);

    // A hidden bar with the cursor idle in content does nothing at all.
    a = hoverTick(.{
        .in_pane = true,
        .y = 300,
        .visible = false,
        .held = false,
        .now_ms = 9500,
        .deadline_ms = 0,
        .reveal_h = reveal,
    });
    try testing.expect(!a.show and !a.hide);
    try testing.expectEqual(@as(u64, 0), a.deadline_ms);
}
