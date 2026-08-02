//! Pure layout for the win32 machine chooser's master-detail shell (T175, the
//! structural half of T140).
//!
//! The chooser used to be a 440-wide single column — account row, filter, a
//! five-row list, a status sentence, then Open + Cancel. Mac's
//! `MachineChooserView` is an 840x540 master-detail chooser: an account row
//! across the top, a fixed 260-wide machine column on a faint wash at the left,
//! a detail pane at the right carrying the selected machine's identity and its
//! primary action, and a footer holding Cancel alone.
//!
//! Everything here is arithmetic on a DPI scale, so it runs in the none-runtime
//! test lane; `MachineChooser.zig` keeps the HWNDs and the GDI calls. The
//! `Rect` type is local rather than `w32.RECT` for exactly that reason.

const std = @import("std");
const chooser_rows = @import("chooser_rows.zig");
/// The one type ramp (T310). This module states font ROLES; the sizes behind
/// them live in `type_ramp.zig` so the chooser cannot drift from the other
/// dialog surfaces.
const type_ramp = @import("type_ramp.zig");

/// A rectangle in physical pixels, left/top inclusive and right/bottom
/// exclusive — the same convention as `RECT`, which this converts to at the
/// call site.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

/// Every region the chooser places, in physical pixels from the client origin.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,

    /// The account row's band and its metrics (T311). What sits IN the band
    /// depends on the sign-in state — signed in it is Mac's email-over-link
    /// stack with a monogram circle beside it, signed out a single bordered
    /// button — so the pieces come from `accountRow`, never from fixed slots.
    /// A full-width rule closes the band at `header_divider_y`.
    account: AccountBand,
    header_divider_y: i32,

    /// The master column — a faint wash behind the filter, the row list and
    /// the status strip — with a vertical rule down its right edge.
    master: Rect,
    master_divider_x: i32,
    filter: Rect,
    list: Rect,
    /// The status strip pinned to the bottom of the master column (Mac's
    /// "Refreshing devices… / Couldn't refresh devices: …"). It GROWS UPWARD
    /// into the list: the dialog is a fixed 840x540, so wrapped hint lines
    /// come out of the list's height, never out of the window's.
    hint: Rect,

    /// The detail pane and the pieces of its header.
    detail: Rect,
    detail_glyph: Rect,
    detail_title: Rect,
    detail_subtitle: Rect,

    /// The band the detail pane's action row is packed into, from the header's
    /// leading edge to the pane's trailing margin. The buttons themselves come
    /// from `actionRow`, which packs a RUN — the row's composition changes with
    /// the selected machine, so no button has a fixed slot (T177).
    action_row: Rect,
    /// Gap between two action buttons (Mac's `HStack(spacing: 8)`, 456).
    action_gap: i32,
    /// A labeled button is its measured caption plus `action_btn_pad` on each
    /// side, never narrower than this. These are the SURFACE's button-sizing
    /// rule, not the action row's private numbers — the account row's bordered
    /// control sizes by the same two, so a caption of the same width comes out
    /// the same width wherever it is (T311).
    action_min_btn_w: i32,
    action_btn_pad: i32,

    /// The one control height across the surface (design system §2.1): Cancel,
    /// the action row, the filter field and the account row's bordered button.
    control_h: i32,

    /// Footer: a rule, then Cancel alone at the trailing edge.
    footer_divider_y: i32,
    cancel: Rect,

    /// `CreateFontW` heights (positive; the caller negates them), from
    /// `type_ramp`. `font_h` is the ramp's BODY, `caption_font_h` its caption
    /// (the detail subtitle and the status strip), `title_font_h` its subtitle
    /// role — the detail pane's subject, which is also semibold.
    font_h: i32,
    caption_font_h: i32,
    title_font_h: i32,
    title_font_weight: i32,
    /// Height of one wrapped line of status-strip text.
    hint_line_h: i32,
};

/// The account row's band and the metrics `accountRow` packs it from (T311).
///
/// Split out because the row has two compositions, not one: Mac's
/// `accountRow` (MachineChooserView.swift:903-976) draws the email over a
/// LINK-styled "Sign Out" with a monogram circle beside them when signed in,
/// and a single bordered button when signed out. A `Layout` that named one
/// status rect and one button rect could only describe the second, which is
/// how the win32 row ended up as a static plus a 150 DIP slot sized for the
/// longer of two captions (findings 5 and 6).
pub const AccountBand = struct {
    /// The whole row, inside the dialog's side margins.
    band: Rect,
    /// Gap between the band's pieces (`md`, Mac's 10 snapped to the scale).
    gap: i32,
    /// The monogram circle's diameter. Mac's 34 is off the 4 DIP scale; this is
    /// the system's LARGE icon size (`SM_CXICON`, 32) — the same rule the detail
    /// pane's mark already follows, so the two identity marks on the surface are
    /// one size and not two nearby ones.
    avatar_d: i32,
    /// Line box of the email (the ramp's caption role) and of the link (its body
    /// role), each the font plus `sm` of leading like every other line box here.
    email_h: i32,
    link_h: i32,
    /// Between the two lines of the stack — Mac's 1, snapped to the scale's 2,
    /// the same value the detail pane puts between its title and subtitle.
    stack_gap: i32,
    /// Mac caps the email at 240 and middle-truncates the rest (2.4).
    email_max_w: i32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Chooser layout at `scale` (the owner window's DPI scale) with the status
/// strip sized for `hint_lines` wrapped lines (measured at runtime, clamped by
/// `chooser_rows.clampHintLines`). Pure — unit-tested.
pub fn layout(scale: f32, hint_lines: i32) Layout {
    const lines = chooser_rows.clampHintLines(hint_lines);

    // Mac's 840x540 (MachineChooserView.swift:270). Fixed: unlike the old
    // single-column dialog, nothing here grows the window.
    const client_w = px(840, scale);
    const client_h = px(540, scale);

    const margin = px(16, scale);
    // Mac's 10 is off the 4 DIP scale; §3.2 maps it to `md`. This one number is
    // the account row's vertical padding AND the filter->list gap, so it moved
    // in one place.
    const gap = px(8, scale);

    // One control height across the whole surface (design system §2.1): the
    // footer's Cancel, the detail pane's action row, the filter field and the
    // account control are all 28. Two heights that differ by 2 do not read as
    // a deliberate hierarchy, they read as nobody having decided.
    const control_h = px(28, scale);

    // Account header — Mac pads it 16 horizontal / 10 vertical (251-252).
    //
    // The band is as tall as the tallest thing that can go in it (design system
    // §2.3: size the container to the control). Signed in that is the two-line
    // email/link stack, not the 28 control height — a band pinned to `control_h`
    // is exactly what forced the row to be one static and one button.
    const avatar_d = px(32, scale);
    const email_h = type_ramp.caption(scale).height + px(4, scale);
    const link_h = type_ramp.body(scale).height + px(4, scale);
    const stack_gap = px(2, scale);
    const account_h = @max(@max(avatar_d, email_h + stack_gap + link_h), control_h);
    const account_top = gap;
    const header_divider_y = account_top + account_h + gap;

    // Footer — Cancel alone, 16 all round (737-742).
    const btn_w = px(96, scale);
    const btn_h = control_h;
    const cancel_top = client_h - margin - btn_h;
    const footer_divider_y = cancel_top - margin;

    const body_top = header_divider_y + 1;
    const body_bottom = footer_divider_y;

    // Master column — a fixed 260 wide on a wash (259-260).
    const master_w = px(260, scale);
    const master: Rect = .{ .left = 0, .top = body_top, .right = master_w, .bottom = body_bottom };

    // Filter: Mac's 14 horizontal / 14 top / 10 bottom (329-330), snapped to
    // the scale — 14 -> `lg` (12), 10 -> `md` (8, the shared `gap`).
    const filter_pad = px(12, scale);
    const filter_h = control_h;
    const filter: Rect = .{
        .left = filter_pad,
        .top = master.top + filter_pad,
        .right = master.right - filter_pad,
        .bottom = master.top + filter_pad + filter_h,
    };

    // Status strip at the bottom of the column, then the list fills what is
    // left between it and the filter.
    // The status strip is caption text, so its wrapped line box is the caption
    // role plus the same `sm` leading every other line box on the surface has.
    const hint_line_h = type_ramp.caption(scale).height + px(4, scale);
    const hint_h = hint_line_h * lines;
    const hint: Rect = .{
        .left = filter_pad,
        .top = master.bottom - px(8, scale) - hint_h,
        .right = master.right - filter_pad,
        .bottom = master.bottom - px(8, scale),
    };

    // List inset 8 horizontally (343). Its height is snapped DOWN to whole
    // rows: an owner-drawn listbox would otherwise render a clipped half row at
    // its foot, and the leftover is invisible anyway — the list's background is
    // the same wash as the column behind it.
    const list_inset = px(8, scale);
    const list_top = filter.bottom + gap;
    const row_h = chooser_rows.rowMetrics(scale).height;
    const avail = hint.top - list_inset - list_top;
    const rows_h = if (row_h > 0) @max(row_h, @divTrunc(avail, row_h) * row_h) else avail;
    const list: Rect = .{
        .left = list_inset,
        .top = list_top,
        .right = master.right - list_inset,
        .bottom = list_top + rows_h,
    };

    // Detail pane, right of the vertical rule.
    const detail: Rect = .{
        .left = master.right + 1,
        .top = body_top,
        .right = client_w,
        .bottom = body_bottom,
    };

    // Detail header — 16 padding, a 30-wide glyph column, 12 to the text, and
    // 14 between the identity block and the action row (440-454).
    // The pane's mark is the system's LARGE icon size (`SM_CXICON`, 32), the
    // way the row's is its small one (`SM_CXSMICON`, 16) — one rule for both
    // instead of Mac's 30 and our own 20.
    const glyph_w = px(32, scale);
    // Line boxes from the ramp plus `sm` of leading, like the row's.
    const title_h = type_ramp.subtitle(scale).height + px(4, scale);
    const subtitle_h = type_ramp.caption(scale).height + px(4, scale);
    const detail_glyph: Rect = .{
        .left = detail.left + margin,
        .top = detail.top + margin,
        .right = detail.left + margin + glyph_w,
        .bottom = detail.top + margin + glyph_w,
    };
    const text_left = detail_glyph.right + px(12, scale);
    const text_right = detail.right - margin;
    const detail_title: Rect = .{
        .left = text_left,
        .top = detail.top + margin,
        .right = text_right,
        .bottom = detail.top + margin + title_h,
    };
    const detail_subtitle: Rect = .{
        .left = text_left,
        .top = detail_title.bottom + px(2, scale),
        .right = text_right,
        .bottom = detail_title.bottom + px(2, scale) + subtitle_h,
    };
    const identity_bottom = @max(detail_glyph.bottom, detail_subtitle.bottom);
    // Mac's 14 between the identity block and the actions -> `lg` (§3.2).
    const action_top = identity_bottom + px(12, scale);

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .account = .{
            .band = .{
                .left = margin,
                .top = account_top,
                .right = client_w - margin,
                .bottom = account_top + account_h,
            },
            .gap = gap,
            .avatar_d = avatar_d,
            .email_h = email_h,
            .link_h = link_h,
            .stack_gap = stack_gap,
            .email_max_w = px(240, scale),
        },
        .header_divider_y = header_divider_y,
        .master = master,
        .master_divider_x = master.right,
        .filter = filter,
        .list = list,
        .hint = hint,
        .detail = detail,
        .detail_glyph = detail_glyph,
        .detail_title = detail_title,
        .detail_subtitle = detail_subtitle,
        .action_row = .{
            .left = detail.left + margin,
            .top = action_top,
            .right = detail.right - margin,
            .bottom = action_top + btn_h,
        },
        // `md` (8) between two commands, Mac's `HStack(spacing: 8)`; `lg` (12)
        // of padding each side of a caption, and a 96 DIP floor that matches the
        // footer's Cancel so a short label still reads as a real button. Every
        // number is on the design system's 4 DIP scale (§1).
        .action_gap = px(8, scale),
        .action_min_btn_w = px(96, scale),
        .action_btn_pad = px(12, scale),
        .control_h = control_h,
        .footer_divider_y = footer_divider_y,
        .cancel = .{
            .left = client_w - margin - btn_w,
            .top = cancel_top,
            .right = client_w - margin,
            .bottom = cancel_top + btn_h,
        },
        .font_h = type_ramp.body(scale).height,
        .caption_font_h = type_ramp.caption(scale).height,
        .title_font_h = type_ramp.subtitle(scale).height,
        .title_font_weight = type_ramp.subtitle(scale).weight,
        .hint_line_h = hint_line_h,
    };
}

// ---------------------------------------------------------------------
// The account row (T311)
// ---------------------------------------------------------------------

/// What the account row is showing. Mac branches its `accountRow` on exactly
/// these three (MachineChooserView.swift:903-932) and draws a different thing in
/// each; the "unconfigured" fourth is a build without a relay base, which win32
/// reports through the status strip instead.
pub const AccountState = enum { signed_in, signed_out, busy };

/// Pure state derivation, so the chooser and the tests agree on what "busy
/// while signed in" is (busy wins — the row is describing an operation, not an
/// account).
pub fn accountState(signed_in: bool, busy: bool) AccountState {
    if (busy) return .busy;
    return if (signed_in) .signed_in else .signed_out;
}

/// Measured caption widths in physical pixels, WITHOUT padding — the caller
/// measures its own strings with the font it will draw them in and passes them
/// here, so this module stays text-free (T235's lesson, the same contract
/// `ActionText` has).
pub const AccountText = struct {
    /// The email, measured in the ramp's CAPTION role.
    email: i32 = 0,
    /// "Sign Out", measured in the ramp's BODY role — a link has no padding, so
    /// this IS its width.
    link: i32 = 0,
    /// The bordered control's caption, in the BODY role.
    button: i32 = 0,
};

/// The packed account row. Every field but `text` is optional because the row
/// has two compositions and a control that is not in this state must be hidden,
/// not moved off-screen.
pub const AccountRow = struct {
    /// The status text: the email when signed in (top of the stack), the state
    /// sentence otherwise. Right-aligned in both, so it always ends where the
    /// trailing element begins.
    text: Rect,
    /// The monogram circle — signed in only.
    avatar: ?Rect = null,
    /// The "Sign Out" link — signed in only, sized to its measured caption.
    link: ?Rect = null,
    /// The bordered sign-in control — signed out / busy only, sized to ITS
    /// measured caption. Finding 6: the two states used to share one 150 DIP
    /// slot, so both were as wide as "Sign in with Google…".
    button: ?Rect = null,
};

/// Pack the account row for `state`. Pure — unit-tested.
///
/// Signed in, Mac's composition is a right-aligned email over a link with the
/// avatar to their right (2.4); signed out it is one bordered button at the
/// trailing edge. Everything stays inside the band: a caption wide enough to
/// overflow is clamped to the band's leading edge and the control truncates it,
/// which is what the email's own 240 cap already assumes.
pub fn accountRow(l: Layout, state: AccountState, text: AccountText) AccountRow {
    const a = l.account;
    const band = a.band;

    switch (state) {
        .signed_in => {
            const avatar_top = band.top + @divTrunc(band.height() - a.avatar_d, 2);
            const avatar: Rect = .{
                .left = band.right - a.avatar_d,
                .top = avatar_top,
                .right = band.right,
                .bottom = avatar_top + a.avatar_d,
            };

            const stack_right = avatar.left - a.gap;
            const room = @max(0, stack_right - band.left);
            const stack_h = a.email_h + a.stack_gap + a.link_h;
            const stack_top = band.top + @divTrunc(band.height() - stack_h, 2);

            const email_w = @min(@max(text.email, 0), @min(a.email_max_w, room));
            const email: Rect = .{
                .left = stack_right - email_w,
                .top = stack_top,
                .right = stack_right,
                .bottom = stack_top + a.email_h,
            };

            const link_w = @min(@max(text.link, 0), room);
            const link: Rect = .{
                .left = stack_right - link_w,
                .top = email.bottom + a.stack_gap,
                .right = stack_right,
                .bottom = email.bottom + a.stack_gap + a.link_h,
            };

            return .{ .text = email, .avatar = avatar, .link = link };
        },
        .signed_out, .busy => {
            const btn_w = @min(
                band.width(),
                @max(l.action_min_btn_w, @max(text.button, 0) + 2 * l.action_btn_pad),
            );
            const btn_top = band.top + @divTrunc(band.height() - l.control_h, 2);
            const button: Rect = .{
                .left = band.right - btn_w,
                .top = btn_top,
                .right = band.right,
                .bottom = btn_top + l.control_h,
            };

            // The sentence is one body line box, centered on the band the way
            // the button is — two things on one row share a center line.
            const status_top = band.top + @divTrunc(band.height() - a.link_h, 2);
            const status: Rect = .{
                .left = band.left,
                .top = status_top,
                .right = @max(band.left, button.left - a.gap),
                .bottom = status_top + a.link_h,
            };
            return .{ .text = status, .button = button };
        },
    }
}

// ---------------------------------------------------------------------
// The detail pane's action row (T177)
// ---------------------------------------------------------------------

/// One control in the detail pane's action row. Mac's row is
///
///     [ New Window ]  [ Restore All ]?  [ Activity ]?  [ … ]?
///
/// (`MachineChooserView.detailHeader`, MachineChooserView.swift:456-494) — a
/// run whose composition depends on the selected machine, not four fixed slots.
/// `restore_all` belongs to T146 and is never present yet; it is named here
/// because the row has to be able to grow by one without moving anything else.
pub const Action = enum { primary, restore_all, activity, menu };

pub const max_actions: usize = 4;

/// Which optional actions the selected machine offers. The primary action is
/// always present — every row can open a window.
pub const Composition = struct {
    restore_all: bool = false,
    activity: bool = false,
    menu: bool = false,
};

/// Measured caption widths in physical pixels, WITHOUT padding — the caller
/// measures its own strings with the dialog font and passes them in, so this
/// module stays text-free (T235's lesson: a width that comes from text metrics
/// cannot be re-derived by anyone who does not measure). The menu button is
/// square and carries a single glyph, so it has no entry.
pub const ActionText = struct {
    primary: i32 = 0,
    restore_all: i32 = 0,
    activity: i32 = 0,
};

/// The packed row: what is in it, and where each control goes.
pub const ActionRow = struct {
    kinds: [max_actions]Action = @splat(.primary),
    rects: [max_actions]Rect = @splat(.{ .left = 0, .top = 0, .right = 0, .bottom = 0 }),
    len: usize = 0,

    /// Where `a` sits, or null when this composition does not include it.
    pub fn rect(self: *const ActionRow, a: Action) ?Rect {
        for (self.kinds[0..self.len], self.rects[0..self.len]) |k, r| {
            if (k == a) return r;
        }
        return null;
    }
};

/// Pack the action row left to right at a consistent gap, each labeled button
/// sized to its own caption. Pure — unit-tested.
///
/// Everything stays inside `l.action_row`: if the captions are wide enough to
/// overflow the band (long labels at a large font), the labeled buttons give up
/// width proportionally down to half the minimum before anything is clipped, and
/// the run is clamped to the band's trailing edge as a last resort. A button
/// that has run out of room is still better than one drawn over the pane edge.
pub fn actionRow(l: Layout, comp: Composition, text: ActionText) ActionRow {
    const band = l.action_row;
    const h = band.height();

    var row: ActionRow = .{};
    var widths: [max_actions]i32 = @splat(0);
    var labeled: [max_actions]bool = @splat(false);

    const add = struct {
        fn f(r: *ActionRow, w: *[max_actions]i32, lab: *[max_actions]bool, kind: Action, width: i32, is_labeled: bool) void {
            r.kinds[r.len] = kind;
            w[r.len] = width;
            lab[r.len] = is_labeled;
            r.len += 1;
        }
    }.f;

    const btnW = struct {
        fn f(layout_: Layout, text_w: i32) i32 {
            return @max(layout_.action_min_btn_w, text_w + 2 * layout_.action_btn_pad);
        }
    }.f;

    add(&row, &widths, &labeled, .primary, btnW(l, text.primary), true);
    if (comp.restore_all) add(&row, &widths, &labeled, .restore_all, btnW(l, text.restore_all), true);
    if (comp.activity) add(&row, &widths, &labeled, .activity, btnW(l, text.activity), true);
    // Square, so it reads as a glyph button rather than a second command (Mac's
    // borderless ellipsis menu, 456-492).
    if (comp.menu) add(&row, &widths, &labeled, .menu, h, false);

    // Shed overflow from the labeled buttons only — the square glyph button has
    // no slack to give and stops being square the moment it is squeezed.
    const gaps = l.action_gap * @as(i32, @intCast(row.len - 1));
    var total: i32 = gaps;
    for (widths[0..row.len]) |w| total += w;
    const floor_w = @divTrunc(l.action_min_btn_w, 2);
    var over = total - band.width();
    if (over > 0) {
        var slack: i32 = 0;
        for (widths[0..row.len], labeled[0..row.len]) |w, is_lab| {
            if (is_lab) slack += @max(0, w - floor_w);
        }
        if (slack > 0) {
            const shed = @min(over, slack);
            var taken: i32 = 0;
            for (0..row.len) |i| {
                if (!labeled[i]) continue;
                const give = @max(0, widths[i] - floor_w);
                if (give == 0) continue;
                const cut = @divTrunc(shed * give, slack);
                widths[i] -= cut;
                taken += cut;
            }
            // Integer division leaves a few pixels unshed; take them from the
            // widest button that still has room.
            var remainder = shed - taken;
            while (remainder > 0) {
                var widest: ?usize = null;
                for (0..row.len) |i| {
                    if (!labeled[i] or widths[i] <= floor_w) continue;
                    if (widest == null or widths[i] > widths[widest.?]) widest = i;
                }
                const i = widest orelse break;
                widths[i] -= 1;
                remainder -= 1;
            }
            over -= shed;
        }
    }

    var x = band.left;
    for (0..row.len) |i| {
        const right = @min(band.right, x + widths[i]);
        row.rects[i] = .{
            .left = @min(x, band.right),
            .top = band.top,
            .right = right,
            .bottom = band.bottom,
        };
        x = right + l.action_gap;
    }
    return row;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "layout: the dialog is Mac's fixed 840x540" {
    const l = layout(1.0, 1);
    try testing.expectEqual(@as(i32, 840), l.client_w);
    try testing.expectEqual(@as(i32, 540), l.client_h);
}

test "layout: master column is a fixed 260 with the detail pane beside it" {
    const l = layout(1.0, 1);
    try testing.expectEqual(@as(i32, 260), l.master.width());
    try testing.expectEqual(l.master.right, l.master_divider_x);
    // The detail pane starts past the rule and runs to the client edge.
    try testing.expect(l.detail.left > l.master.right);
    try testing.expectEqual(l.client_w, l.detail.right);
    try testing.expect(l.detail.width() > l.master.width());
}

test "layout: the body sits between the header and footer rules" {
    const l = layout(1.0, 1);
    try testing.expect(l.header_divider_y > l.account.band.bottom - 1);
    try testing.expect(l.master.top > l.header_divider_y);
    try testing.expectEqual(l.footer_divider_y, l.master.bottom);
    try testing.expectEqual(l.master.top, l.detail.top);
    try testing.expectEqual(l.master.bottom, l.detail.bottom);
}

test "layout: the footer holds Cancel alone, at the trailing edge" {
    const l = layout(1.0, 1);
    try testing.expect(l.cancel.top > l.footer_divider_y);
    try testing.expectEqual(l.client_w - 16, l.cancel.right);
    try testing.expectEqual(l.client_h - 16, l.cancel.bottom);
    // The primary action lives in the detail pane, not down here.
    const primary = actionRow(l, .{}, .{ .primary = 70 }).rect(.primary).?;
    try testing.expect(primary.bottom < l.footer_divider_y);
    try testing.expect(primary.left > l.master.right);
}

test "layout: master column stacks filter, list, status strip" {
    const l = layout(1.0, 1);
    try testing.expect(l.filter.top >= l.master.top);
    try testing.expect(l.list.top > l.filter.bottom);
    try testing.expect(l.hint.top > l.list.bottom);
    try testing.expect(l.hint.bottom <= l.master.bottom);
    // All three stay inside the column.
    for ([_]Rect{ l.filter, l.list, l.hint }) |r| {
        try testing.expect(r.left >= l.master.left);
        try testing.expect(r.right <= l.master.right);
    }
}

test "layout: extra hint lines come out of the list, not the window" {
    const one = layout(1.0, 1);
    const three = layout(1.0, 3);
    try testing.expectEqual(one.client_h, three.client_h);
    try testing.expectEqual(one.client_w, three.client_w);

    const extra = 2 * one.hint_line_h;
    try testing.expectEqual(one.hint.height() + extra, three.hint.height());
    // The list gives up the room the strip took — in whole rows, so it can
    // shed at most one row more than the strip gained.
    try testing.expectEqual(one.list.top, three.list.top);
    try testing.expect(three.list.height() <= one.list.height());
    const shed = one.list.height() - three.list.height();
    const row_h = chooser_rows.rowMetrics(1.0).height;
    try testing.expect(shed >= extra - row_h);
    try testing.expect(shed <= extra + row_h);
    // Whatever it sheds, it never grows into the strip.
    try testing.expect(three.list.bottom <= three.hint.top);
}

test "layout: the list is always a whole number of rows" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 2.0) }) |scale| {
        const row_h = chooser_rows.rowMetrics(scale).height;
        var lines: i32 = 1;
        while (lines <= chooser_rows.max_hint_lines) : (lines += 1) {
            const l = layout(scale, lines);
            try testing.expectEqual(@as(i32, 0), @rem(l.list.height(), row_h));
            try testing.expect(l.list.height() >= row_h);
            try testing.expect(l.list.bottom <= l.hint.top);
        }
    }
}

test "layout: the hint line count is clamped like the strip that renders it" {
    const capped = layout(1.0, 99);
    const at_max = layout(1.0, chooser_rows.max_hint_lines);
    try testing.expectEqual(at_max.hint.height(), capped.hint.height());
    // Even at the cap the list stays a real list, not a peephole.
    try testing.expect(capped.list.height() >= chooser_rows.rowMetrics(1.0).height * 5);
}

test "layout: the management menu button sits beside the primary action" {
    const l = layout(1.0, 1);
    const row = actionRow(l, .{ .menu = true }, .{ .primary = 70 });
    const primary = row.rect(.primary).?;
    const menu = row.rect(.menu).?;
    // Same row, to its trailing side, with a gap.
    try testing.expectEqual(primary.top, menu.top);
    try testing.expectEqual(primary.bottom, menu.bottom);
    try testing.expect(menu.left >= primary.right);
    try testing.expect(menu.left - primary.right <= 12);
    // Square, and inside the detail pane.
    try testing.expectEqual(menu.height(), menu.width());
    try testing.expect(menu.left > l.master.right);
    try testing.expect(menu.right <= l.detail.right);
    try testing.expect(menu.bottom < l.footer_divider_y);
}

test "layout: detail header runs glyph -> title -> subtitle -> primary action" {
    const l = layout(1.0, 1);
    const row = actionRow(l, .{ .activity = true, .menu = true }, .{ .primary = 70, .activity = 48 });
    try testing.expect(l.detail_glyph.left >= l.detail.left);
    try testing.expect(l.detail_title.left > l.detail_glyph.right);
    try testing.expectEqual(l.detail_title.left, l.detail_subtitle.left);
    try testing.expect(l.detail_subtitle.top >= l.detail_title.bottom);
    try testing.expect(l.action_row.top >= l.detail_subtitle.bottom);
    try testing.expect(l.action_row.top >= l.detail_glyph.bottom);
    // Everything nests inside the pane.
    var rects: [max_actions + 3]Rect = undefined;
    rects[0] = l.detail_glyph;
    rects[1] = l.detail_title;
    rects[2] = l.detail_subtitle;
    for (row.rects[0..row.len], 0..) |r, i| rects[3 + i] = r;
    for (rects[0 .. 3 + row.len]) |r| {
        try testing.expect(r.left >= l.detail.left);
        try testing.expect(r.right <= l.detail.right);
        try testing.expect(r.bottom <= l.detail.bottom);
    }
}

// --- action row (T177) ------------------------------------------------

test "actionRow: packs left to right at a consistent gap, in Mac's order" {
    const l = layout(1.0, 1);
    const row = actionRow(
        l,
        .{ .restore_all = true, .activity = true, .menu = true },
        .{ .primary = 70, .restore_all = 66, .activity = 44 },
    );
    try testing.expectEqual(@as(usize, 4), row.len);
    try testing.expectEqual(Action.primary, row.kinds[0]);
    try testing.expectEqual(Action.restore_all, row.kinds[1]);
    try testing.expectEqual(Action.activity, row.kinds[2]);
    try testing.expectEqual(Action.menu, row.kinds[3]);

    // One leading edge, one gap, one baseline.
    try testing.expectEqual(l.action_row.left, row.rects[0].left);
    for (row.rects[0..row.len]) |r| {
        try testing.expectEqual(l.action_row.top, r.top);
        try testing.expectEqual(l.action_row.bottom, r.bottom);
        try testing.expect(r.right <= l.action_row.right);
    }
    for (1..row.len) |i| {
        try testing.expectEqual(l.action_gap, row.rects[i].left - row.rects[i - 1].right);
    }
}

test "actionRow: composition follows what the row offers" {
    const l = layout(1.0, 1);
    const t: ActionText = .{ .primary = 70, .restore_all = 66, .activity = 44 };

    // The local row: one button, no management menu, no Activity.
    const local = actionRow(l, .{}, t);
    try testing.expectEqual(@as(usize, 1), local.len);
    try testing.expect(local.rect(.primary) != null);
    try testing.expect(local.rect(.activity) == null);
    try testing.expect(local.rect(.menu) == null);

    // A remote row: Mac gates Activity and the `…` menu on the same
    // `if case .remote` (MachineChooserView.swift:474-491).
    const remote = actionRow(l, .{ .activity = true, .menu = true }, t);
    try testing.expectEqual(@as(usize, 3), remote.len);
    try testing.expect(remote.rect(.activity) != null);
    try testing.expect(remote.rect(.menu) != null);
    // Adding Restore All (T146) shifts what follows it, and nothing else.
    const with_all = actionRow(l, .{ .restore_all = true, .activity = true, .menu = true }, t);
    try testing.expectEqual(remote.rect(.primary).?.left, with_all.rect(.primary).?.left);
    try testing.expect(with_all.rect(.activity).?.left > remote.rect(.activity).?.left);
}

test "actionRow: each labeled button is its own caption plus padding" {
    const l = layout(1.0, 1);
    const wide = actionRow(l, .{ .activity = true }, .{ .primary = 70, .activity = 200 });
    const activity = wide.rect(.activity).?;
    try testing.expectEqual(200 + 2 * l.action_btn_pad, activity.width());
    // A short caption never shrinks past the comfortable minimum.
    const narrow = actionRow(l, .{ .activity = true }, .{ .primary = 70, .activity = 4 });
    try testing.expectEqual(l.action_min_btn_w, narrow.rect(.activity).?.width());
}

test "actionRow: an overflowing run stays inside the pane" {
    const l = layout(1.0, 1);
    const row = actionRow(
        l,
        .{ .restore_all = true, .activity = true, .menu = true },
        .{ .primary = 900, .restore_all = 900, .activity = 900 },
    );
    try testing.expectEqual(@as(usize, 4), row.len);
    for (row.rects[0..row.len]) |r| {
        try testing.expect(r.left >= l.action_row.left);
        try testing.expect(r.right <= l.action_row.right);
        try testing.expect(r.right >= r.left);
    }
    // The glyph button keeps its square: only the labeled buttons give width up.
    try testing.expectEqual(row.rects[3].height(), row.rects[3].width());
}

test "actionRow: every number is on the 4 DIP spacing scale" {
    // Design system §1: no value outside 2/4/8/12/16/24 at 1.0.
    const l = layout(1.0, 1);
    try testing.expectEqual(@as(i32, 8), l.action_gap);
    try testing.expectEqual(@as(i32, 12), l.action_btn_pad);
    // ...and the glyph button is the standard 28 DIP square (§2.1), which is
    // also the row's height, so the run has ONE baseline.
    const row = actionRow(l, .{ .menu = true }, .{ .primary = 70 });
    try testing.expectEqual(@as(i32, 28), row.rect(.menu).?.width());
    try testing.expectEqual(@as(i32, 28), l.action_row.height());
}

test "actionRow: scales with DPI" {
    inline for (.{ @as(f32, 1.25), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        const row = actionRow(l, .{ .activity = true, .menu = true }, .{ .primary = 70, .activity = 44 });
        for (row.rects[0..row.len]) |r| {
            try testing.expect(r.left >= l.action_row.left);
            try testing.expect(r.right <= l.action_row.right);
        }
        try testing.expectEqual(l.action_gap, row.rects[1].left - row.rects[0].right);
        try testing.expectEqual(row.rects[2].height(), row.rects[2].width());
    }
}

test "layout: account row is right-aligned against the client edge" {
    const l = layout(1.0, 1);
    const out = accountRow(l, .signed_out, .{ .button = 120 });
    try testing.expectEqual(l.client_w - 16, out.button.?.right);
    try testing.expect(out.text.right < out.button.?.left);
    try testing.expect(out.text.left > 0);

    // Signed in, the trailing element is the monogram, and the stack is right
    // -aligned against it rather than against the client edge.
    const in = accountRow(l, .signed_in, .{ .email = 140, .link = 50 });
    try testing.expectEqual(l.client_w - 16, in.avatar.?.right);
    try testing.expectEqual(in.avatar.?.left - l.account.gap, in.text.right);
    try testing.expectEqual(in.text.right, in.link.?.right);
}

test "accountRow: the two states are different compositions, not one slot (T311)" {
    const l = layout(1.0, 1);

    const out = accountRow(l, .signed_out, .{ .button = 120 });
    try testing.expect(out.button != null);
    try testing.expect(out.avatar == null);
    try testing.expect(out.link == null);

    const in = accountRow(l, .signed_in, .{ .email = 140, .link = 50 });
    try testing.expect(in.button == null);
    try testing.expect(in.avatar != null);
    try testing.expect(in.link != null);

    // Busy is the signed-out composition with its own caption: Mac replaces the
    // whole block while an operation is in flight.
    const busy = accountRow(l, .busy, .{ .button = 60 });
    try testing.expect(busy.button != null);
    try testing.expect(busy.avatar == null);

    try testing.expectEqual(AccountState.busy, accountState(true, true));
    try testing.expectEqual(AccountState.busy, accountState(false, true));
    try testing.expectEqual(AccountState.signed_in, accountState(true, false));
    try testing.expectEqual(AccountState.signed_out, accountState(false, false));
}

test "accountRow: the bordered control is sized to ITS caption (T311, finding 6)" {
    // The defect: one 150 DIP slot for both captions, so "Signing in…" was as
    // wide as "Sign in with Google…". A measured caption has to move the width.
    const l = layout(1.0, 1);
    const wide = accountRow(l, .signed_out, .{ .button = 140 }).button.?;
    const narrow = accountRow(l, .busy, .{ .button = 60 }).button.?;
    try testing.expect(wide.width() > narrow.width());
    try testing.expectEqual(140 + 2 * l.action_btn_pad, wide.width());
    // …and never narrower than the floor Cancel sits at, so a short caption is
    // still a button rather than a chip.
    try testing.expectEqual(l.action_min_btn_w, narrow.width());
    try testing.expectEqual(l.cancel.width(), narrow.width());

    // Both states stay inside the band, and a caption that cannot fit is
    // clamped rather than drawn over the master column.
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const ls = layout(scale, 1);
        const huge = accountRow(ls, .signed_out, .{ .button = 5000 });
        try testing.expect(huge.button.?.left >= ls.account.band.left);
        try testing.expect(huge.button.?.right <= ls.account.band.right);
        try testing.expect(huge.text.right >= huge.text.left);
    }
}

test "accountRow: the signed-in stack and the monogram nest in the band (T311)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        const band = l.account.band;
        const row = accountRow(l, .signed_in, .{ .email = 140, .link = 50 });
        const av = row.avatar.?;
        const link = row.link.?;

        // Everything inside the band, in both axes.
        for ([_]Rect{ row.text, link, av }) |r| {
            try testing.expect(r.top >= band.top);
            try testing.expect(r.bottom <= band.bottom);
            try testing.expect(r.left >= band.left);
            try testing.expect(r.right <= band.right);
        }

        // The mark is square (a circle's bounding box, not an oval).
        try testing.expectEqual(av.width(), av.height());
        try testing.expectEqual(l.account.avatar_d, av.width());

        // The stack is two stacked lines that do not overlap, and nothing
        // touches the monogram.
        try testing.expectEqual(l.account.stack_gap, link.top - row.text.bottom);
        try testing.expect(link.right + l.account.gap <= av.left);

        // The email cap is Mac's 240: a longer address is truncated by the
        // control, not allowed to push the stack into the master column.
        const long = accountRow(l, .signed_in, .{ .email = 4000, .link = 50 });
        try testing.expectEqual(l.account.email_max_w, long.text.width());
        try testing.expect(long.text.left >= band.left);
    }
}

test "accountRow: signed-out sentence and button share a center line (T311)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        const row = accountRow(l, .signed_out, .{ .button = 120 });
        const btn = row.button.?;
        const text_mid = row.text.top + @divTrunc(row.text.height(), 2);
        const btn_mid = btn.top + @divTrunc(btn.height(), 2);
        try testing.expect(@abs(text_mid - btn_mid) <= 1);
        // The bordered control is the surface's one control height.
        try testing.expectEqual(l.control_h, btn.height());
        try testing.expectEqual(l.cancel.height(), btn.height());
    }
}

test "layout: every gap is on the 4 DIP spacing scale (T310)" {
    // The companion to `chooser_rows`' scale test, and together they are what
    // keeps win32-machine-chooser.md §3.2's mapping from rotting. Mac's 14
    // (filter pad, identity->actions) and 10 (account v-pad, filter->list) are
    // off the scale and were copied here verbatim before T310.
    const l = layout(1.0, 1);
    const acct_out = accountRow(l, .signed_out, .{ .button = 120 });
    const acct_in = accountRow(l, .signed_in, .{ .email = 140, .link = 50 });
    const on_scale = [_]i32{ 2, 4, 8, 12, 16, 24 };
    const gaps = [_]struct { name: []const u8, v: i32 }{
        .{ .name = "client -> account", .v = l.account.band.top },
        .{ .name = "account -> header rule", .v = l.header_divider_y - l.account.band.bottom },
        .{ .name = "dialog left margin", .v = l.account.band.left },
        .{ .name = "account text -> control", .v = acct_out.button.?.left - acct_out.text.right },
        .{ .name = "client -> account control (right)", .v = l.client_w - acct_out.button.?.right },
        .{ .name = "account stack -> monogram", .v = acct_in.avatar.?.left - acct_in.link.?.right },
        .{ .name = "client -> monogram (right)", .v = l.client_w - acct_in.avatar.?.right },
        .{ .name = "account email -> link", .v = acct_in.link.?.top - acct_in.text.bottom },
        .{ .name = "band -> monogram (top)", .v = acct_in.avatar.?.top - l.account.band.top },
        .{ .name = "master -> filter (top)", .v = l.filter.top - l.master.top },
        .{ .name = "master -> filter (left)", .v = l.filter.left - l.master.left },
        .{ .name = "filter -> list", .v = l.list.top - l.filter.bottom },
        .{ .name = "master -> list (left)", .v = l.list.left - l.master.left },
        .{ .name = "hint -> master bottom", .v = l.master.bottom - l.hint.bottom },
        .{ .name = "detail -> glyph (left)", .v = l.detail_glyph.left - l.detail.left },
        .{ .name = "detail -> glyph (top)", .v = l.detail_glyph.top - l.detail.top },
        .{ .name = "glyph -> title", .v = l.detail_title.left - l.detail_glyph.right },
        .{ .name = "title -> subtitle", .v = l.detail_subtitle.top - l.detail_title.bottom },
        .{ .name = "identity -> actions", .v = l.action_row.top - @max(l.detail_glyph.bottom, l.detail_subtitle.bottom) },
        .{ .name = "detail right margin", .v = l.detail.right - l.action_row.right },
        .{ .name = "action gap", .v = l.action_gap },
        .{ .name = "action button padding", .v = l.action_btn_pad },
        .{ .name = "footer rule -> cancel", .v = l.cancel.top - l.footer_divider_y },
        .{ .name = "cancel -> client bottom", .v = l.client_h - l.cancel.bottom },
        .{ .name = "cancel -> client right", .v = l.client_w - l.cancel.right },
    };
    for (gaps) |g| {
        if (std.mem.indexOfScalar(i32, &on_scale, g.v) == null) {
            std.debug.print("off-scale gap: {s} = {d}\n", .{ g.name, g.v });
            return error.OffSpacingScale;
        }
    }
}

test "layout: one control height across the surface (T310)" {
    // Design system §2.1. The filter and the account control used to be 26
    // while Cancel and the action row were 28 — a 2 px difference that reads
    // as nobody having decided, not as a hierarchy.
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        try testing.expectEqual(l.cancel.height(), l.filter.height());
        try testing.expectEqual(l.cancel.height(), l.control_h);
        try testing.expectEqual(
            l.cancel.height(),
            accountRow(l, .signed_out, .{ .button = 120 }).button.?.height(),
        );
        try testing.expectEqual(l.cancel.height(), l.action_row.height());
    }
    try testing.expectEqual(@as(i32, 28), layout(1.0, 1).filter.height());
}

test "layout: the account band is sized to its tallest content, not to a control (T311)" {
    // Design system §2.3. Before T311 the band WAS `control_h`, which is why the
    // row could only ever hold one line of text and one button — the composition
    // Mac uses when you are signed OUT.
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        const a = l.account;
        const stack_h = a.email_h + a.stack_gap + a.link_h;
        try testing.expect(a.band.height() >= stack_h);
        try testing.expect(a.band.height() >= a.avatar_d);
        try testing.expect(a.band.height() >= l.control_h);
        try testing.expectEqual(@max(@max(stack_h, a.avatar_d), l.control_h), a.band.height());
        // Line boxes come from the ramp: caption for the email, body for the
        // link, so the row consumes T310's ramp rather than restating sizes.
        try testing.expectEqual(type_ramp.caption(scale).height + px(4, scale), a.email_h);
        try testing.expectEqual(type_ramp.body(scale).height + px(4, scale), a.link_h);
        try testing.expect(a.email_h < a.link_h);
    }
    // The band grew from the 28 control height to the stack's own height; the
    // dialog did NOT grow with it (it is Mac's fixed 840x540), so the body took
    // the difference.
    try testing.expectEqual(@as(i32, 36), layout(1.0, 1).account.band.height());
    try testing.expectEqual(@as(i32, 840), layout(1.0, 1).client_w);
    try testing.expectEqual(@as(i32, 540), layout(1.0, 1).client_h);
}

test "layout: the fonts come from the ramp, in role order (T310)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        try testing.expectEqual(type_ramp.caption(scale).height, l.caption_font_h);
        try testing.expectEqual(type_ramp.body(scale).height, l.font_h);
        try testing.expectEqual(type_ramp.subtitle(scale).height, l.title_font_h);
        try testing.expectEqual(type_ramp.weight_semibold, l.title_font_weight);
        try testing.expect(l.caption_font_h < l.font_h);
        try testing.expect(l.font_h < l.title_font_h);
        // The row's subline is the same caption role as the detail pane's, so
        // the two smallest texts on the surface are one size, not two.
        try testing.expectEqual(l.caption_font_h, chooser_rows.rowMetrics(scale).subtitle_font_h);
        // Every line box has room for the text it holds.
        try testing.expect(l.detail_title.height() > l.title_font_h);
        try testing.expect(l.detail_subtitle.height() > l.caption_font_h);
        try testing.expect(l.hint_line_h > l.caption_font_h);
    }
    // Body is 14, not the 15 nobody chose and not the system metric's 12.
    try testing.expectEqual(@as(i32, 14), layout(1.0, 1).font_h);
}

test "layout: the status strip still leaves a real list at every scale" {
    // §4 finding 13, kept as a verify: the strip grows UPWARD into the list,
    // so the worst case is a 4-line strip at the largest scale.
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, chooser_rows.max_hint_lines);
        const row_h = chooser_rows.rowMetrics(scale).height;
        try testing.expect(@divTrunc(l.list.height(), row_h) >= 5);
    }
}

test "layout: scales with DPI" {
    const a = layout(1.0, 2);
    const b = layout(2.0, 2);
    try testing.expectEqual(a.client_w * 2, b.client_w);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.master.width() * 2, b.master.width());
    try testing.expectEqual(a.hint.height() * 2, b.hint.height());
    try testing.expectEqual(a.title_font_h * 2, b.title_font_h);
}
