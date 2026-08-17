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
    /// The selected machine's identity — glyph, name, session-count subtitle —
    /// flush LEFT in the band (T602, Mac's `headerIdentity`). It used to open
    /// the detail column, where it cost ~50 DIP of the one thing that column is
    /// short of: roster rows. The title and subtitle rects run to the band's
    /// trailing edge here; the PAINT clamps them against `AccountRow
    /// .identity_right`, because where the trailing composition begins depends
    /// on measured text this module never sees.
    identity_glyph: Rect,
    identity_title: Rect,
    identity_subtitle: Rect,
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

    /// The detail pane. Since T602 it BEGINS at its action row — the identity
    /// that used to head it lives in the band above.
    detail: Rect,

    /// The band the detail pane's action row is packed into, from the header's
    /// leading edge to the pane's trailing margin. The buttons themselves come
    /// from `actionRow`, which packs a RUN — the row's composition changes with
    /// the selected machine, so no button has a fixed slot (T177).
    action_row: Rect,
    /// Gap between two action buttons (Mac's `HStack(spacing: 8)`, 456).
    action_gap: i32,
    /// The session list's column-header line (T602): one caption line box
    /// between the action row and the roster, where the clickable CPU / Name
    /// headers sit. OUTSIDE the scrolled region, so the headers stay put while
    /// the rows move under them. Drawn only when there are rows — headers over
    /// "No active sessions" are furniture — but the space is always reserved,
    /// so toggling them cannot reflow the roster.
    session_header: Rect,
    /// Everything below the action row: the selected machine's session roster
    /// (T318), Mac's `detailSessions` scroll region
    /// (`MachineChooserView.swift:544-570`). It takes ALL the remaining height
    /// of the detail pane, because a roster is a list of unknown length and the
    /// pane is a fixed 840x540 — what does not fit scrolls, rather than the
    /// region growing.
    sessions: Rect,

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
    /// What a checkbox costs beyond its caption — the box glyph plus its
    /// built-in gap. The same 24 DIP allowance `ConfirmDialog` gives its
    /// accessory checkboxes, so the two checkbox surfaces agree.
    check_glyph_w: i32,
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
    // is exactly what forced the row to be one static and one button. Since
    // T602 the selected machine's identity stack is in the band too, and it is
    // the tallest thing there.
    const avatar_d = px(32, scale);
    const email_h = type_ramp.lineBox(type_ramp.caption(scale), scale);
    const link_h = type_ramp.lineBox(type_ramp.body(scale), scale);
    const stack_gap = px(2, scale);
    // The identity's line boxes, from the ramp: the machine name is the
    // subtitle role (the pane's subject, wherever it is drawn), the
    // session-count line its caption.
    const title_h = type_ramp.lineBox(type_ramp.subtitle(scale), scale);
    const subtitle_h = type_ramp.lineBox(type_ramp.caption(scale), scale);
    const identity_stack_h = title_h + stack_gap + subtitle_h;
    const account_h = @max(
        @max(@max(avatar_d, email_h + stack_gap + link_h), identity_stack_h),
        control_h,
    );
    const account_top = gap;
    const header_divider_y = account_top + account_h + gap;

    // The identity block (T602): the machine's mark at the band's leading
    // edge — square at the system's LARGE icon size (`SM_CXICON`, 32), the way
    // the row's is its small one — then the name over the session count, both
    // centered on the band. The text rects run to the band's trailing edge;
    // the paint clamps them against where the account composition begins.
    const identity_glyph: Rect = .{
        .left = margin,
        .top = account_top + @divTrunc(account_h - avatar_d, 2),
        .right = margin + avatar_d,
        .bottom = account_top + @divTrunc(account_h - avatar_d, 2) + avatar_d,
    };
    const id_text_left = identity_glyph.right + px(12, scale);
    const id_stack_top = account_top + @divTrunc(account_h - identity_stack_h, 2);
    const identity_title: Rect = .{
        .left = id_text_left,
        .top = id_stack_top,
        .right = client_w - margin,
        .bottom = id_stack_top + title_h,
    };
    const identity_subtitle: Rect = .{
        .left = id_text_left,
        .top = identity_title.bottom + stack_gap,
        .right = client_w - margin,
        .bottom = identity_title.bottom + stack_gap + subtitle_h,
    };

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
    const hint_line_h = type_ramp.lineBox(type_ramp.caption(scale), scale);
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

    // The detail pane begins at its action row (T602): the identity that used
    // to head it lives in the band, and the reclaimed height lands on roster
    // rows. Vertical padding is 12, not the 16 the identity block carried —
    // the point of moving it out was the space, and padding is the obvious way
    // to lose it again on the way down (Mac's own note on `detailActionBar`).
    const action_top = detail.top + px(12, scale);

    // The session list's column-header line (T602): one caption line box under
    // the action row, then the roster after a hair of separation.
    const session_header: Rect = .{
        .left = detail.left + margin,
        .top = action_top + btn_h + px(12, scale),
        .right = detail.right - margin,
        .bottom = action_top + btn_h + px(12, scale) + subtitle_h,
    };

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
            .check_glyph_w = px(24, scale),
        },
        .identity_glyph = identity_glyph,
        .identity_title = identity_title,
        .identity_subtitle = identity_subtitle,
        .header_divider_y = header_divider_y,
        .master = master,
        .master_divider_x = master.right,
        .filter = filter,
        .list = list,
        .hint = hint,
        .detail = detail,
        .action_row = .{
            .left = detail.left + margin,
            .top = action_top,
            .right = detail.right - margin,
            .bottom = action_top + btn_h,
        },
        .session_header = session_header,
        // `xs` under the header line, then the pane's 16 bottom margin, so the
        // roster sits in a well rather than against an edge.
        .sessions = .{
            .left = detail.left + margin,
            .top = session_header.bottom + px(4, scale),
            .right = detail.right - margin,
            .bottom = detail.bottom - margin,
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
/// these four (MachineChooserView.swift:1120-1155) and draws a different thing
/// in each — including `unconfigured`, a build carrying no Google OAuth client
/// id, where Mac shows a sentence and NO button at all.
pub const AccountState = enum { signed_in, signed_out, busy, unconfigured };

/// Pure state derivation, so the chooser and the tests agree on what "busy
/// while signed in" is (busy wins — the row is describing an operation, not an
/// account).
///
/// `configured` only decides the SIGNED-OUT case (T747): an account signed in
/// under an env-supplied client id must still be offered "Sign Out", and a
/// sign-in already in flight is describing itself.
pub fn accountState(signed_in: bool, busy: bool, configured: bool) AccountState {
    if (busy) return .busy;
    if (signed_in) return .signed_in;
    return if (configured) .signed_out else .unconfigured;
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
    /// The signed-out / busy / unconfigured state sentence, in the BODY role
    /// (T602). Measured because the sentence's STATIC control now shares the
    /// band with the painted identity: a control sized "whatever is left"
    /// would erase the identity under its background.
    status: i32 = 0,
    /// The "Share this machine" checkbox caption, in the BODY role (T547).
    /// 0 means the toggle is absent (no agent state dir to persist into) and
    /// the row packs exactly as it did before the toggle existed.
    share: i32 = 0,
};

/// The packed account row. Every field but `text` is optional because the row
/// has two compositions and a control that is not in this state must be hidden,
/// not moved off-screen.
pub const AccountRow = struct {
    /// The status text: the email when signed in (top of the stack), the state
    /// sentence otherwise. Right-aligned in both, so it always ends where the
    /// trailing element begins — and sized to its MEASURED caption since T602,
    /// because the band's leading side now belongs to the painted identity.
    text: Rect,
    /// The monogram circle — signed in only.
    avatar: ?Rect = null,
    /// The "Sign Out" link — signed in only, sized to its measured caption.
    link: ?Rect = null,
    /// The bordered sign-in control — signed out / busy only, sized to ITS
    /// measured caption. Finding 6: the two states used to share one 150 DIP
    /// slot, so both were as wide as "Sign in with Google…".
    button: ?Rect = null,
    /// The "Share this machine" checkbox (T547). It held the band's LEADING
    /// edge while that edge was empty space; since T602 the identity lives
    /// there (Mac's `headerIdentity` claims the same spot), so the toggle
    /// packs at the head of the TRAILING composition instead. Null when the
    /// toggle is absent (`AccountText.share == 0`).
    share: ?Rect = null,
    /// The furthest x the identity's text may run to (T602): one gap short of
    /// the leftmost trailing element. The identity rects in `Layout` run to
    /// the band's trailing edge because this module never sees measured text;
    /// the paint clamps them here.
    identity_right: i32,
};

/// Pack the account row for `state`. Pure — unit-tested.
///
/// Signed in, Mac's composition is a right-aligned email over a link with the
/// avatar to their right (2.4); signed out it is one bordered button at the
/// trailing edge, its state sentence beside it. The share toggle heads the
/// trailing run in every state. Everything stays inside the band: a caption
/// wide enough to overflow is clamped and the control truncates it, which is
/// what the email's own 240 cap already assumes.
pub fn accountRow(l: Layout, state: AccountState, text: AccountText) AccountRow {
    const a = l.account;
    const band = a.band;

    const share_w = if (text.share > 0)
        @min(band.width(), text.share + a.check_glyph_w)
    else
        0;
    const share_top = band.top + @divTrunc(band.height() - l.control_h, 2);

    // Place the share toggle one gap left of `edge`, clamped to the band.
    const shareAt = struct {
        fn f(band_: Rect, top: i32, h: i32, w: i32, gap_: i32, edge: i32) ?Rect {
            if (w <= 0) return null;
            const right = edge - gap_;
            return .{
                .left = @max(band_.left, right - w),
                .top = top,
                .right = @max(band_.left, right),
                .bottom = top + h,
            };
        }
    }.f;

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
            const reserved = if (share_w > 0) share_w + a.gap else 0;
            const room = @max(0, stack_right - band.left - reserved);
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

            const stack_left = @min(email.left, link.left);
            const share = shareAt(band, share_top, l.control_h, share_w, a.gap, stack_left);
            const leading = if (share) |s| s.left else stack_left;
            return .{
                .text = email,
                .avatar = avatar,
                .link = link,
                .share = share,
                .identity_right = @max(band.left, leading - a.gap),
            };
        },
        .signed_out, .busy => {
            const reserved = if (share_w > 0) share_w + a.gap else 0;
            const btn_room = @max(0, band.width() - reserved);
            const btn_w = @min(
                btn_room,
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
            // the button is — two things on one row share a center line — and
            // sized to its measured caption, right-aligned against the button.
            const status_right = @max(band.left, button.left - a.gap);
            const status_room = @max(0, status_right - band.left - reserved);
            const status_w = @min(@max(text.status, 0), status_room);
            const status_top = band.top + @divTrunc(band.height() - a.link_h, 2);
            const status: Rect = .{
                .left = status_right - status_w,
                .top = status_top,
                .right = status_right,
                .bottom = status_top + a.link_h,
            };
            const share = shareAt(band, share_top, l.control_h, share_w, a.gap, status.left);
            const leading = if (share) |s| s.left else status.left;
            return .{
                .text = status,
                .button = button,
                .share = share,
                .identity_right = @max(band.left, leading - a.gap),
            };
        },
        .unconfigured => {
            // No sign-in control at all: this build cannot sign in, so there
            // is nothing for a button to do — and chrome that controls nothing
            // does not appear (design system §"Vertical space belongs to the
            // terminal", and Mac's own answer at
            // MachineChooserView.swift:1150-1155). The sentence keeps its
            // right alignment against the band's trailing edge, so the row
            // reads as the same block with its control removed. The share
            // toggle STAYS: sharing enrolls on the relay's web page and needs
            // no local client id.
            const reserved = if (share_w > 0) share_w + a.gap else 0;
            const status_room = @max(0, band.width() - reserved);
            const status_w = @min(@max(text.status, 0), status_room);
            const status_top = band.top + @divTrunc(band.height() - a.link_h, 2);
            const status: Rect = .{
                .left = band.right - status_w,
                .top = status_top,
                .right = band.right,
                .bottom = status_top + a.link_h,
            };
            const share = shareAt(band, share_top, l.control_h, share_w, a.gap, status.left);
            const leading = if (share) |s| s.left else status.left;
            return .{
                .share = share,
                .text = status,
                .identity_right = @max(band.left, leading - a.gap),
            };
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
/// `restore_all` (T335) is the rarest of them: it needs the machine to have two
/// or more live sessions, so the row really does grow and shrink by one while
/// the chooser is open — which is why it was named here from the start.
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

test "layout: the identity lives in the band — glyph -> title -> subtitle (T602)" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layout(scale, 1);
        const band = l.account.band;
        // Flush left, nested in the band, square at the avatar's size — the
        // two identity marks on the surface are one size, not two nearby ones.
        try testing.expectEqual(band.left, l.identity_glyph.left);
        try testing.expectEqual(l.identity_glyph.width(), l.identity_glyph.height());
        try testing.expectEqual(l.account.avatar_d, l.identity_glyph.width());
        // Name over the session count, stacked in order at the band's gap.
        try testing.expect(l.identity_title.left > l.identity_glyph.right);
        try testing.expectEqual(l.identity_title.left, l.identity_subtitle.left);
        try testing.expectEqual(
            l.account.stack_gap,
            l.identity_subtitle.top - l.identity_title.bottom,
        );
        // Everything nests inside the band.
        for ([_]Rect{ l.identity_glyph, l.identity_title, l.identity_subtitle }) |r| {
            try testing.expect(r.top >= band.top);
            try testing.expect(r.bottom <= band.bottom);
            try testing.expect(r.left >= band.left);
            try testing.expect(r.right <= band.right);
        }
        // Line boxes from the ramp, like every other line box here.
        try testing.expectEqual(
            type_ramp.lineBox(type_ramp.subtitle(scale), scale),
            l.identity_title.height(),
        );
        try testing.expectEqual(
            type_ramp.lineBox(type_ramp.caption(scale), scale),
            l.identity_subtitle.height(),
        );
    }
}

test "layout: the detail pane begins at its action row (T602)" {
    // The identity moved out of the pane so the roster gets the height; the
    // action row's vertical padding is 12, not the 16 the identity block
    // carried (Mac's own note on `detailActionBar`).
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layout(scale, 1);
        const pad: i32 = @intFromFloat(@round(12.0 * scale));
        try testing.expectEqual(l.detail.top + pad, l.action_row.top);
    }
    // Everything in the pane still nests.
    const l = layout(1.0, 1);
    const row = actionRow(l, .{ .activity = true, .menu = true }, .{ .primary = 70, .activity = 48 });
    for (row.rects[0..row.len]) |r| {
        try testing.expect(r.left >= l.detail.left);
        try testing.expect(r.right <= l.detail.right);
        try testing.expect(r.bottom <= l.detail.bottom);
    }
}

test "layout: the session-list header sits between the actions and the rows (T602)" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layout(scale, 1);
        // One caption line box, outside the scrolled region, sharing the
        // roster's own edges so the header's columns can ride the row grid.
        try testing.expect(l.session_header.top > l.action_row.bottom);
        try testing.expect(l.session_header.bottom <= l.sessions.top);
        try testing.expectEqual(l.sessions.left, l.session_header.left);
        try testing.expectEqual(l.sessions.right, l.session_header.right);
        try testing.expectEqual(
            type_ramp.lineBox(type_ramp.caption(scale), scale),
            l.session_header.height(),
        );
    }
}

test "layout: the session roster takes the detail pane below the action row (T318)" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layout(scale, 1);
        // Below the actions, clear of them, and inside the pane on every side.
        try testing.expect(l.sessions.top > l.action_row.bottom);
        try testing.expect(l.sessions.left >= l.detail.left);
        try testing.expect(l.sessions.right <= l.detail.right);
        try testing.expect(l.sessions.bottom <= l.detail.bottom);
        // The actions and the roster share one margin, so the pane reads as a
        // well rather than as two differently-inset blocks.
        try testing.expectEqual(l.action_row.left, l.sessions.left);
        try testing.expectEqual(l.action_row.right, l.sessions.right);
        // It is the tallest thing in the pane: a roster is a list of unknown
        // length, so it gets whatever is left rather than a fixed slot.
        try testing.expect(l.sessions.height() > l.action_row.height() * 3);
    }
}

test "layout: extra hint lines never move the detail pane's roster" {
    // The status strip lives in the MASTER column; growing it must come out of
    // the list, not out of the roster next door.
    const one = layout(1.25, 1);
    const four = layout(1.25, 4);
    try testing.expectEqual(one.sessions.top, four.sessions.top);
    try testing.expectEqual(one.sessions.bottom, four.sessions.bottom);
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

    try testing.expectEqual(AccountState.busy, accountState(true, true, true));
    try testing.expectEqual(AccountState.busy, accountState(false, true, true));
    try testing.expectEqual(AccountState.signed_in, accountState(true, false, true));
    try testing.expectEqual(AccountState.signed_out, accountState(false, false, true));
}

test "accountRow: an unconfigured build offers no button at all (T747)" {
    // The defect this state exists for: a build with no `-Dgoogle-client-id`
    // rendered the full signed-out composition, so every press of a perfectly
    // healthy-looking button failed with NoClientId and the user read the
    // feature as broken.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layout(scale, 1);
        const row = accountRow(l, .unconfigured, .{ .status = 180 });
        try testing.expect(row.button == null);
        try testing.expect(row.avatar == null);
        try testing.expect(row.link == null);

        // The sentence keeps the trailing edge the control gave up, sized to
        // its measured caption (T602: the band's leading side belongs to the
        // painted identity now), on the band's center line like every state's.
        const band = l.account.band;
        try testing.expectEqual(band.right, row.text.right);
        try testing.expectEqual(@as(i32, 180), row.text.width());
        try testing.expect(row.text.top >= band.top);
        try testing.expect(row.text.bottom <= band.bottom);
        try testing.expectEqual(l.account.link_h, row.text.height());

        // And it is strictly more room than the signed-out sentence may take —
        // the message that replaces a control has the control's room too.
        const out = accountRow(l, .signed_out, .{ .button = 120, .status = 5000 });
        const un = accountRow(l, .unconfigured, .{ .status = 5000 });
        try testing.expect(un.text.width() > out.text.width());
    }

    // Only the signed-OUT case turns into it. A stored account (an env-supplied
    // client id, or a build that had one) must still be offered Sign Out, and a
    // sign-in in flight is describing itself.
    try testing.expectEqual(AccountState.unconfigured, accountState(false, false, false));
    try testing.expectEqual(AccountState.signed_in, accountState(true, false, false));
    try testing.expectEqual(AccountState.busy, accountState(false, true, false));
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

test "accountRow: the share toggle heads the trailing run in every state (T547/T602)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        const band = l.account.band;
        const text: AccountText = .{ .email = 140, .link = 50, .button = 120, .status = 90, .share = 110 };

        inline for (.{ .signed_in, .signed_out, .busy, .unconfigured }) |state| {
            const row = accountRow(l, state, text);
            const share = row.share.?;

            // Inside the band, at the surface's one control height, sized to
            // its caption plus the checkbox glyph allowance.
            try testing.expect(share.left >= band.left);
            try testing.expect(share.right <= band.right);
            try testing.expect(share.top >= band.top);
            try testing.expect(share.bottom <= band.bottom);
            try testing.expectEqual(l.control_h, share.height());
            try testing.expectEqual(110 + l.account.check_glyph_w, share.width());

            // It heads the trailing run: everything else in the composition
            // sits to its RIGHT — the band's leading side is the identity's.
            for ([_]?Rect{ row.text, row.link, row.button, row.avatar }) |maybe| {
                const r = maybe orelse continue;
                try testing.expect(r.left >= share.right);
            }
            // And the identity's room ends one gap short of the toggle.
            try testing.expectEqual(share.left - l.account.gap, row.identity_right);
        }
    }
}

test "accountRow: share == 0 is exactly the pre-toggle trailing run (T547)" {
    // A chooser with no agent state dir to persist into hides the toggle, and
    // the trailing run must pack as if T547 never happened.
    const l = layout(1.0, 1);
    const band = l.account.band;

    const out = accountRow(l, .signed_out, .{ .button = 120, .status = 90 });
    try testing.expect(out.share == null);
    try testing.expectEqual(out.button.?.left - l.account.gap, out.text.right);
    try testing.expectEqual(out.text.left - l.account.gap, out.identity_right);

    const un = accountRow(l, .unconfigured, .{ .status = 90 });
    try testing.expect(un.share == null);
    try testing.expectEqual(band.right, un.text.right);
    try testing.expectEqual(un.text.left - l.account.gap, un.identity_right);
}

test "accountRow: a huge share caption is clamped to the band (T547)" {
    const l = layout(1.0, 1);
    const band = l.account.band;
    const row = accountRow(l, .signed_out, .{ .button = 120, .status = 60, .share = 5000 });
    const share = row.share.?;
    try testing.expect(share.left >= band.left);
    try testing.expect(share.right <= band.right);
    // The trailing composition still packs without escaping the band, and the
    // identity's room never runs past the band's leading edge.
    try testing.expect(row.button.?.right <= band.right);
    try testing.expect(row.text.right >= row.text.left);
    try testing.expect(row.identity_right >= band.left);
}

test "accountRow: identity_right stops short of every trailing element (T602)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.5) }) |scale| {
        const l = layout(scale, 1);
        inline for (.{ .signed_in, .signed_out, .busy, .unconfigured }) |state| {
            const row = accountRow(
                l,
                state,
                .{ .email = 140, .link = 50, .button = 120, .status = 90 },
            );
            for ([_]?Rect{ row.text, row.link, row.button, row.avatar, row.share }) |maybe| {
                const r = maybe orelse continue;
                try testing.expect(row.identity_right <= r.left);
            }
            try testing.expect(row.identity_right >= l.account.band.left);
        }
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
        // The monogram's distance to the band's top is deliberately NOT here:
        // it is a CENTERING remainder, (band_h - avatar_d) / 2, not a chosen
        // gap — it happened to be 2 while the band was 36, and T602's taller
        // band (the identity stack is its tallest tenant now) makes it 5. The
        // choice being asserted is "centered", which the T311 nesting test
        // already holds at every scale.
        .{ .name = "master -> filter (top)", .v = l.filter.top - l.master.top },
        .{ .name = "master -> filter (left)", .v = l.filter.left - l.master.left },
        .{ .name = "filter -> list", .v = l.list.top - l.filter.bottom },
        .{ .name = "master -> list (left)", .v = l.list.left - l.master.left },
        .{ .name = "hint -> master bottom", .v = l.master.bottom - l.hint.bottom },
        .{ .name = "identity glyph -> title", .v = l.identity_title.left - l.identity_glyph.right },
        .{ .name = "identity title -> subtitle", .v = l.identity_subtitle.top - l.identity_title.bottom },
        .{ .name = "detail -> actions (top)", .v = l.action_row.top - l.detail.top },
        .{ .name = "actions -> session header", .v = l.session_header.top - l.action_row.bottom },
        .{ .name = "session header -> roster", .v = l.sessions.top - l.session_header.bottom },
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
        const identity_h = l.identity_title.height() + a.stack_gap + l.identity_subtitle.height();
        try testing.expect(a.band.height() >= stack_h);
        try testing.expect(a.band.height() >= a.avatar_d);
        try testing.expect(a.band.height() >= l.control_h);
        // The identity stack joined the band in T602 and is its tallest tenant.
        try testing.expect(a.band.height() >= identity_h);
        try testing.expectEqual(
            @max(@max(@max(stack_h, a.avatar_d), identity_h), l.control_h),
            a.band.height(),
        );
        // Line boxes come from the ramp: caption for the email, body for the
        // link, so the row consumes T310's ramp rather than restating sizes.
        try testing.expectEqual(type_ramp.lineBox(type_ramp.caption(scale), scale), a.email_h);
        try testing.expectEqual(type_ramp.lineBox(type_ramp.body(scale), scale), a.link_h);
        try testing.expect(a.email_h < a.link_h);
    }
    // The band grew again in T602 — the identity stack (24 + 2 + 16) is now
    // its tallest tenant; the dialog did NOT grow with it (it is Mac's fixed
    // 840x540), so the body took the difference — and got it back with
    // interest when the identity left the detail pane.
    try testing.expectEqual(@as(i32, 42), layout(1.0, 1).account.band.height());
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
        try testing.expect(l.identity_title.height() > l.title_font_h);
        try testing.expect(l.identity_subtitle.height() > l.caption_font_h);
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
