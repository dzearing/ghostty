//! Geometry, wording and colors for the REMOTE CONNECTION PILL (T367), the
//! Windows port of Mac's `MachinePillView.swift` — the affordance that tells
//! you a remote window's link is live, retrying, or gone, and gives you the way
//! back when it is gone.
//!
//! No OS imports, so every number below is asserted at 1.0 / 1.25 / 1.5 / 2.0 in
//! every app-runtime lane — the `readonly_badge` / `key_state_pill` pattern. The
//! painting and hit-testing halves are `paintRemotePill` in `Window.zig` and
//! `caption_layout`, which place the rect this module fills in.
//!
//! ## Why it lives in the caption band
//!
//! Design system §6: vertical space belongs to the terminal, and an
//! always-visible status mark that cost a row would be paying for the same
//! pixels the window already bought for its titlebar. The band already hosts the
//! app's own "…" button (T234/T205), so the pill joins that cluster and shares
//! its vertical center — one baseline, not a second one invented here.
//!
//! ## Three states, and why the quiet one is quiet
//!
//! | State | Mark | Label | Fill |
//! |---|---|---|---|
//! | `connected` | green dot | *(none)* | a tint of the band |
//! | `reconnecting` | amber dot | `Reconnecting… n/5` | a tint of the band |
//! | `disconnected` | refresh glyph | `Reconnect` | solid red, and it is a BUTTON |
//!
//! Connected shows a dot and no words on purpose. A chip that permanently reads
//! "Connected" is chrome that says nothing — the information a working window
//! carries is "this one is remote, and it is fine", which is exactly what a
//! status LED conveys. The pill then GROWS, with words, only when something is
//! wrong, which is what makes the wrong case noticeable at all.
//!
//! That also settles WCAG 1.4.1 without a second signal being bolted on: the
//! three states differ in whether there is text and in what it says, so the hue
//! is never the only thing carrying the state. Mac reaches the same place from
//! the other direction (its status capsule is absent while connected).
//!
//! Mac's Reconnect button is accent-filled; this one is red. Mac can afford the
//! accent because its machine pill's separate red DOT is still on screen next to
//! it; here the pill is one control, so the color that says "broken" has to be
//! on the control itself, and T367 asks for a red state by name. The word
//! "Reconnect" is what keeps the red from reading as "destructive".

const std = @import("std");
const testing = std.testing;
const chrome_theme = @import("chrome_theme.zig");
const color_math = @import("color_math.zig");
const icon_button = @import("icon_button.zig");
const type_ramp = @import("type_ramp.zig");
const policy = @import("remote_reconnect.zig");

const Rgb = color_math.Rgb;

/// The chrome speaks one rectangle — `icon_button`'s.
pub const Rect = icon_button.Rect;

// =============================================================================
// What the pill says
// =============================================================================

/// The pill's three presentations, derived from the ladder's window state.
/// Deliberately three and not four: `disconnected.self_healable` splits the
/// RECOVERY paths, not the presentation — a window whose fast ladder is
/// exhausted and one that is terminally gone look identical to a user, and
/// `manualReconnect` starts from either.
pub const Mode = enum { connected, reconnecting, disconnected };

pub fn modeFor(state: policy.WindowState) Mode {
    return switch (state) {
        .connected => .connected,
        .reconnecting => .reconnecting,
        .disconnected => .disconnected,
    };
}

/// What each mode MEANS in the shared status vocabulary. The pixel colors come
/// from `chrome_theme`, resolved against the band the pill lands on.
pub fn tone(mode: Mode) chrome_theme.Tone {
    return switch (mode) {
        .connected => .good,
        .reconnecting => .warn,
        .disconnected => .danger,
    };
}

/// Is this mode a BUTTON — does clicking it do something? Only the broken one
/// is. A pill that is sometimes clickable is not a wobble in the model: the
/// action it offers (reconnect) has no meaning while the link is up, and an
/// enabled-looking control that does nothing is worse than none.
pub fn isAction(mode: Mode) bool {
    return mode == .disconnected;
}

/// The mark drawn at the pill's leading edge: a status dot, or the refresh
/// glyph on the button.
pub const Mark = enum { dot, refresh };

pub fn mark(mode: Mode) Mark {
    return switch (mode) {
        .connected, .reconnecting => .dot,
        .disconnected => .refresh,
    };
}

/// Longest label any state can produce, so callers can size a stack buffer.
/// `Reconnecting… ` plus two single digits and a slash, with the ellipsis
/// counted as its three UTF-8 bytes.
pub const label_cap: usize = 32;

/// The pill's label, written into `buf` (needs `label_cap`). Empty for
/// `connected` — the dot is the whole message there.
///
/// The attempt is shown as `n/5` rather than a bare count because a number with
/// no ceiling cannot tell you whether waiting is still worth it. The ceiling is
/// the policy's own `max_attempts`, asked for rather than restated.
pub fn label(buf: []u8, state: policy.WindowState) []const u8 {
    return switch (state) {
        .connected => "",
        .reconnecting => |r| std.fmt.bufPrint(
            buf,
            "Reconnecting\u{2026} {d}/{d}",
            .{ r.attempt, policy.max_attempts },
        ) catch "Reconnecting\u{2026}",
        .disconnected => "Reconnect",
    };
}

/// The tooltip / accessible description, written into `buf` (needs
/// `tooltip_cap` plus the machine name). `machine` is the display name of the
/// machine this window's terminals run on, or an empty string when the window
/// has none to name.
pub const tooltip_cap: usize = 80;

pub fn tooltip(buf: []u8, state: policy.WindowState, machine: []const u8) []const u8 {
    const who = if (machine.len > 0) machine else "the remote machine";
    return switch (state) {
        .connected => std.fmt.bufPrint(buf, "Connected to {s}", .{who}) catch "Connected",
        .reconnecting => |r| std.fmt.bufPrint(
            buf,
            "Connection to {s} lost \u{2014} reconnecting (attempt {d} of {d})",
            .{ who, r.attempt, policy.max_attempts },
        ) catch "Reconnecting",
        .disconnected => std.fmt.bufPrint(
            buf,
            "Connection to {s} lost \u{2014} click to reconnect",
            .{who},
        ) catch "Click to reconnect",
    };
}

// =============================================================================
// Geometry
// =============================================================================

/// Pill height in DIP: one caption line box plus the 4 DIP step, which is
/// exactly how the chooser's session badges are sized. Asked of the ramp rather
/// than picked, so a ramp change moves the chip with its text.
pub const pad_x_dip: f32 = 8.0;
/// Gap between the mark and the label. The 4 DIP step.
pub const gap_dip: f32 = 4.0;
/// Status-dot diameter. 8 DIP: on the scale, and big enough that its hue is
/// judgeable at a glance rather than being a stray pixel.
pub const dot_dip: f32 = 8.0;
/// The refresh glyph's em box. 12 DIP is what `icon_button_paint` renders every
/// other chrome mark at, so the button's glyph carries the same optical weight
/// as the "…" beside it.
pub const glyph_dip: f32 = 12.0;

/// Every DIP constant the pill is built from, resolved for one DPI scale.
pub const Metrics = struct {
    /// Painted height of the capsule.
    h: i32,
    /// Corner radius — half the height, which is what makes it a capsule at
    /// every scale instead of a rounded rect at some of them (the chooser
    /// badge's rule, §3.1's capsule case).
    radius: i32,
    pad_x: i32,
    gap: i32,
    dot: i32,
    glyph: i32,
    /// The label's font — the caption role (12 DIP), the ramp's badge size.
    font: type_ramp.Font,
    /// The shared chrome button metrics, carried so the painter can hand them
    /// to `icon_button_paint.glyph` without deriving a second copy.
    ib: icon_button.Metrics,

    pub fn init(scale: f32) Metrics {
        const font = type_ramp.caption(scale);
        const h = type_ramp.lineBox(font, scale) + px(4.0, scale);
        return .{
            .h = h,
            .radius = @divTrunc(h, 2),
            .pad_x = px(pad_x_dip, scale),
            .gap = px(gap_dip, scale),
            .dot = px(dot_dip, scale),
            .glyph = px(glyph_dip, scale),
            .font = font,
            .ib = icon_button.Metrics.init(scale),
        };
    }

    /// The leading mark's square side for a mode.
    pub fn markSize(self: Metrics, mode: Mode) i32 {
        return switch (mark(mode)) {
            .dot => self.dot,
            .refresh => self.glyph,
        };
    }
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// The pill's natural width for a label `text_w` px wide (GDI-measured by the
/// caller at `m.font`). A label that measured to nothing takes its gap with it:
/// the gap separates two things, and `connected` only has one.
pub fn width(m: Metrics, mode: Mode, text_w: i32) i32 {
    const tw = @max(text_w, 0);
    const content = m.markSize(mode) + (if (tw > 0) m.gap + tw else 0);
    return content + m.pad_x * 2;
}

/// Where the pill's interior landed. All rects are PAINTED extents,
/// right/bottom exclusive, in the same coordinate space as `pill`.
pub const Layout = struct {
    /// The capsule itself — the rect handed in, unchanged. Carried so a painter
    /// has one struct to read rather than a rect plus a struct.
    pill: Rect,
    /// The leading mark's square: the dot, or the refresh glyph's em box.
    mark: Rect,
    /// The label's box, vertically centered by the caller's `DT_VCENTER`. Empty
    /// when the mode has no label, or when the pill was squeezed below the width
    /// its own mark needs.
    text: Rect,
};

/// Fill `pill`'s interior: mark at the leading edge, label after it.
///
/// The mark is vertically centered on the capsule and the label takes whatever
/// is left, so a pill narrower than its natural width tail-ellipsizes its label
/// (the caller's `DT_END_ELLIPSIS`) instead of overflowing. Below the width its
/// mark alone needs, the label is dropped outright — the same choice the caption
/// band makes with a title it cannot fit.
pub fn layout(m: Metrics, pill: Rect, mode: Mode) Layout {
    const empty: Layout = .{ .pill = pill, .mark = .{}, .text = .{} };
    if (pill.isEmpty()) return empty;

    const size = m.markSize(mode);
    const mark_top = pill.top + @divTrunc(pill.height() - size, 2);
    const mark_left = pill.left + m.pad_x;
    const mark_rect: Rect = .{
        .left = mark_left,
        .top = mark_top,
        .right = mark_left + size,
        .bottom = mark_top + size,
    };
    // A pill too narrow even for its mark and padding is degenerate; the caller
    // is expected to have dropped it, but a clamped rect must not produce a
    // mark hanging out the far side.
    if (mark_rect.right + m.pad_x > pill.right) return empty;

    const text_left = mark_rect.right + m.gap;
    const text_right = pill.right - m.pad_x;
    const text: Rect = if (hasLabel(mode) and text_right > text_left)
        .{ .left = text_left, .top = pill.top, .right = text_right, .bottom = pill.bottom }
    else
        .{};

    return .{ .pill = pill, .mark = mark_rect, .text = text };
}

fn hasLabel(mode: Mode) bool {
    return mode != .connected;
}

// =============================================================================
// Color
// =============================================================================

/// Every color one paint of the pill needs, resolved against the band it sits
/// on. Nothing here is a literal: a fixed foreground cannot satisfy a contrast
/// floor, because a floor is a statement about two colors (§2.3).
pub const Ink = struct {
    fill: Rgb,
    mark: Rgb,
    text: Rgb,
};

/// Resolve the pill's colors on a band of `bar`, given the user's chrome
/// palette and the control's interaction state.
///
/// The two quiet modes tint the band with their own tone and take their text
/// from the tint, so the label carries the 4.5:1 text floor against the surface
/// it is really drawn on. The action mode fills solid `pal.danger` — the same
/// red the caption's close-hover uses, so there is one red in the chrome and
/// not two — and takes the same white foreground with it.
///
/// White, not `contrastForeground(fill)` (T528). A searched foreground on a red
/// fill is exactly what put a BLACK X on the caption's close button: the red is
/// resolved to carry white, so a foreground that re-decides per state can only
/// disagree with the fill's own constraint. It firms DARKER on hover and press
/// for the same reason the caption slab does — a saturated fill that lightens
/// walks toward the ceiling white needs, and away from the color it is.
pub fn ink(bar: Rgb, pal: chrome_theme.Palette, mode: Mode, state: icon_button.State) Ink {
    if (mode == .disconnected) {
        const d = if (icon_button.paintsFill(state)) icon_button.fillDelta(state, false) else 0;
        const fill: Rgb = .{
            .r = icon_button.shadeChannel(pal.danger.r, d),
            .g = icon_button.shadeChannel(pal.danger.g, d),
            .b = icon_button.shadeChannel(pal.danger.b, d),
        };
        return .{ .fill = fill, .mark = pal.on_danger, .text = pal.on_danger };
    }

    // The quiet modes have NO interaction states, and that is not an oversight
    // to be tidied up later: they are not buttons (`isAction`), so hover and
    // press cannot happen to them, and a lit fill would promise an action that
    // clicking does not deliver. Ignoring `state` here keeps the color model
    // from carrying combinations the UI can never produce.
    const t = tone(mode);
    const fill = chrome_theme.toneFill(bar, t);
    return .{
        .fill = fill,
        .mark = chrome_theme.toneInk(fill, t),
        .text = chrome_theme.textOn(fill),
    };
}

// =============================================================================
// Tests
// =============================================================================

const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "modeFor: the ladder's three states map onto the three presentations" {
    try testing.expectEqual(Mode.connected, modeFor(.connected));
    try testing.expectEqual(Mode.reconnecting, modeFor(.{ .reconnecting = .{ .attempt = 1 } }));
    // Both disconnected tiers present identically — the split is about recovery.
    try testing.expectEqual(Mode.disconnected, modeFor(policy.exhausted_state));
    try testing.expectEqual(Mode.disconnected, modeFor(policy.terminal_state));
}

test "isAction: only the broken pill is clickable" {
    try testing.expect(!isAction(.connected));
    try testing.expect(!isAction(.reconnecting));
    try testing.expect(isAction(.disconnected));
}

test "label: connected is wordless, the others say what is happening" {
    var buf: [label_cap]u8 = undefined;
    try testing.expectEqualStrings("", label(&buf, .connected));
    try testing.expectEqualStrings(
        "Reconnecting\u{2026} 2/5",
        label(&buf, .{ .reconnecting = .{ .attempt = 2 } }),
    );
    try testing.expectEqualStrings("Reconnect", label(&buf, policy.exhausted_state));
    try testing.expectEqualStrings("Reconnect", label(&buf, policy.terminal_state));
}

test "label: the attempt ceiling is the policy's, not a restated number" {
    var buf: [label_cap]u8 = undefined;
    const s = label(&buf, .{ .reconnecting = .{ .attempt = policy.max_attempts } });
    var expect_buf: [label_cap]u8 = undefined;
    const expect = try std.fmt.bufPrint(
        &expect_buf,
        "Reconnecting\u{2026} {d}/{d}",
        .{ policy.max_attempts, policy.max_attempts },
    );
    try testing.expectEqualStrings(expect, s);
}

test "label_cap holds the longest label at an absurd attempt count" {
    var buf: [label_cap]u8 = undefined;
    const s = label(&buf, .{ .reconnecting = .{ .attempt = 999_999 } });
    // Either it fit or it fell back — never a truncated half-word.
    try testing.expect(std.mem.startsWith(u8, s, "Reconnecting"));
}

test "tooltip: names the machine, and degrades when there is none to name" {
    var buf: [tooltip_cap]u8 = undefined;
    try testing.expectEqualStrings("Connected to winbox", tooltip(&buf, .connected, "winbox"));
    try testing.expectEqualStrings(
        "Connected to the remote machine",
        tooltip(&buf, .connected, ""),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        tooltip(&buf, .{ .reconnecting = .{ .attempt = 3 } }, "winbox"),
        "attempt 3 of 5",
    ) != null);
    try testing.expect(std.mem.endsWith(
        u8,
        tooltip(&buf, policy.terminal_state, "winbox"),
        "click to reconnect",
    ));
}

test "metrics: the capsule is a capsule at every scale" {
    for (scales) |s| {
        const m = Metrics.init(s);
        try testing.expect(m.h > 0);
        // Radius is exactly half the height, so the ends are semicircles rather
        // than a rounded rect that happens to look right at 1.0.
        try testing.expectEqual(@divTrunc(m.h, 2), m.radius);
    }
}

test "metrics: the pill fits the caption band with the 4 DIP clearance" {
    const caption_layout = @import("caption_layout.zig");
    for (scales) |s| {
        const m = Metrics.init(s);
        for ([_]caption_layout.Mode{ .standalone, .with_tabs }) |band_mode| {
            const cm = caption_layout.Metrics.init(s, band_mode);
            // Design system §0 rule 2: >= 4 DIP between an element and its
            // container's edge, top and bottom.
            const slack = cm.caption_h - m.h;
            try testing.expect(slack >= 2 * px(4.0, s));
        }
    }
}

test "metrics: the pill is never taller than the button square it sits beside" {
    // The pill and the "…" share a vertical center; a pill taller than the
    // button's painted square would break the band's clearance from the other
    // side, since the caption centers the square, not the pill.
    for (scales) |s| {
        const m = Metrics.init(s);
        try testing.expect(m.h <= m.ib.target);
    }
}

test "width: the wordless state pays for no gap" {
    for (scales) |s| {
        const m = Metrics.init(s);
        try testing.expectEqual(m.dot + m.pad_x * 2, width(m, .connected, 0));
        // A label on the connected pill would still be honored if one existed,
        // so the "no gap" rule is about the measured text, not the mode.
        try testing.expectEqual(
            m.glyph + m.gap + 40 + m.pad_x * 2,
            width(m, .disconnected, 40),
        );
    }
}

test "width: grows with the label, monotonically" {
    for (scales) |s| {
        const m = Metrics.init(s);
        var last: i32 = 0;
        for ([_]i32{ 0, 10, 40, 120 }) |tw| {
            const w = width(m, .reconnecting, tw);
            try testing.expect(w > last);
            last = w;
        }
    }
}

test "layout: mark and label keep the padding, and nothing hangs out" {
    for (scales) |s| {
        const m = Metrics.init(s);
        const text_w: i32 = px(60.0, s);
        for ([_]Mode{ .connected, .reconnecting, .disconnected }) |mode| {
            const w = width(m, mode, if (mode == .connected) 0 else text_w);
            const pill: Rect = .{ .left = 100, .top = 6, .right = 100 + w, .bottom = 6 + m.h };
            const l = layout(m, pill, mode);

            try testing.expectEqual(pill.left + m.pad_x, l.mark.left);
            try testing.expectEqual(m.markSize(mode), l.mark.width());
            try testing.expectEqual(m.markSize(mode), l.mark.height());
            // Vertically centered on the capsule, to the pixel.
            try testing.expectEqual(
                pill.top + @divTrunc(pill.height() - l.mark.height(), 2),
                l.mark.top,
            );
            try testing.expect(l.mark.right <= pill.right - m.pad_x);

            if (mode == .connected) {
                try testing.expect(l.text.isEmpty());
                // The wordless pill's mark is centered horizontally too: with
                // equal padding on both sides, that falls out rather than being
                // arranged.
                try testing.expectEqual(pill.right - m.pad_x, l.mark.right);
            } else {
                try testing.expect(!l.text.isEmpty());
                try testing.expectEqual(l.mark.right + m.gap, l.text.left);
                try testing.expectEqual(pill.right - m.pad_x, l.text.right);
                try testing.expectEqual(text_w, l.text.width());
            }
        }
    }
}

test "layout: a squeezed pill drops its label, then refuses to draw at all" {
    for (scales) |s| {
        const m = Metrics.init(s);
        // Wide enough for the mark and its padding, too narrow for a label.
        const narrow = m.glyph + m.pad_x * 2 + m.gap;
        const pill: Rect = .{ .left = 0, .top = 0, .right = narrow, .bottom = m.h };
        const l = layout(m, pill, .disconnected);
        try testing.expect(!l.mark.isEmpty());
        try testing.expect(l.text.isEmpty());

        // Narrower than the mark plus its padding: nothing, rather than a mark
        // hanging past the capsule's end.
        const tiny: Rect = .{ .left = 0, .top = 0, .right = m.glyph, .bottom = m.h };
        const lt = layout(m, tiny, .disconnected);
        try testing.expect(lt.mark.isEmpty());
        try testing.expect(lt.text.isEmpty());

        try testing.expect(layout(m, .{}, .connected).mark.isEmpty());
    }
}

/// The §2.3 floors, carrying `chrome_theme`'s own 0.05 tolerance — the same
/// one `chooser_sessions`' badge test documents at :880. The shared contrast
/// search runs in Lab and sRGB floats and then quantizes to 8 bits, which can
/// land a hair under the target it just cleared (measured 2.9918 for the green
/// dot on a white band). That is a property of
/// `color_math.contrastAdjustedTo`, paid by every accent on every surface, so
/// it is filed as its own task rather than papered over with a per-tone nudge
/// here.
const mark_floor: f64 = chrome_theme.ui_contrast_target - 0.05;
const text_floor: f64 = 4.5 - 0.05;

test "ink: every state clears its contrast floor on a sweep of bands" {
    // A spread of chrome bands: near-black, near-white, and saturated hues that
    // a user's terminal background could really produce.
    const bands = [_]Rgb{
        .{ .r = 0x1E, .g = 0x1E, .b = 0x1E },
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 },
        .{ .r = 0x2E, .g = 0x30, .b = 0x40 },
        .{ .r = 0x00, .g = 0x40, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xB0, .b = 0x00 },
        .{ .r = 0x68, .g = 0x00, .b = 0x81 },
    };
    const accents = [_]Rgb{
        .{ .r = 0x00, .g = 0x78, .b = 0xD4 },
        .{ .r = 0x68, .g = 0x00, .b = 0x81 },
    };
    const states = [_]icon_button.State{ .normal, .hover, .pressed, .active };

    for (bands) |bar| {
        for (accents) |accent| {
            const pal = chrome_theme.resolve(bar, accent);
            for ([_]Mode{ .connected, .reconnecting, .disconnected }) |mode| {
                for (states) |st| {
                    const c = ink(pal.bar, pal, mode, st);
                    // §2.3: chrome marks 3:1, label text 4.5:1 — against the
                    // fill they are really drawn on, in every state.
                    try testing.expect(ratio(c.mark, c.fill) >= mark_floor);
                    try testing.expect(ratio(c.text, c.fill) >= text_floor);

                    // And the red capsule carries the chrome's one destructive
                    // foreground in EVERY state (T528) — a searched one flips
                    // to black the moment a lit fill crosses the crossover,
                    // which is the caption close button's defect wearing the
                    // pill's shape.
                    if (mode == .disconnected) {
                        try testing.expectEqual(pal.on_danger, c.text);
                        try testing.expectEqual(pal.on_danger, c.mark);
                    }
                }
            }
        }
    }
}

test "ink: the quiet modes tint the band, the action mode owns it" {
    const bar: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x1E };
    const pal = chrome_theme.resolve(bar, .{ .r = 0x00, .g = 0x78, .b = 0xD4 });

    // A tint stays near the band it tints; a solid fill replaces it.
    const quiet = ink(pal.bar, pal, .connected, .normal);
    const loud = ink(pal.bar, pal, .disconnected, .normal);
    try testing.expectEqual(pal.danger, loud.fill);
    try testing.expect(
        channelDistance(quiet.fill, pal.bar) < channelDistance(loud.fill, pal.bar),
    );
}

test "ink: the button's hover is a change of FILL; the quiet states have none" {
    const bar: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x1E };
    const pal = chrome_theme.resolve(bar, .{ .r = 0x00, .g = 0x78, .b = 0xD4 });

    // §2.2: hover is a fill, not a recolored glyph.
    const rest = ink(pal.bar, pal, .disconnected, .normal);
    const hover = ink(pal.bar, pal, .disconnected, .hover);
    try testing.expect(channelDistance(rest.fill, hover.fill) > 0);

    // The quiet modes are not buttons, so no state can light them. Asserted
    // rather than assumed: a lit chip that does nothing when clicked is the
    // defect this rule exists to prevent.
    for ([_]Mode{ .connected, .reconnecting }) |mode| {
        const base = ink(pal.bar, pal, mode, .normal);
        for ([_]icon_button.State{ .hover, .pressed, .active }) |st| {
            try testing.expectEqual(base, ink(pal.bar, pal, mode, st));
        }
    }
}

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

fn channelDistance(a: Rgb, b: Rgb) i32 {
    return @as(i32, @intCast(@abs(@as(i32, a.r) - @as(i32, b.r)))) +
        @as(i32, @intCast(@abs(@as(i32, a.g) - @as(i32, b.g)))) +
        @as(i32, @intCast(@abs(@as(i32, a.b) - @as(i32, b.b))));
}
