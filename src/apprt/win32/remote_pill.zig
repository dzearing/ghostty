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
//! ## Four states, and what each one says
//!
//! | State | Mark | Label | Fill | Click |
//! |---|---|---|---|---|
//! | `connected` | green dot | the machine's name | a tint of the band | Activity Monitor |
//! | `reconnecting` | amber dot | `winbox — Reconnecting… n/5` | a tint of the band | Activity Monitor |
//! | `disconnected` | refresh glyph | `winbox — Reconnect` | solid red | reconnect |
//! | `incompatible` | refresh glyph | `winbox — Version mismatch` | solid red | reconnect |
//!
//! The fourth is T628's, and it is a SENTENCE and not a hue: a link that is
//! down because the two ends disagree about the protocol used to present as the
//! third, so a machine that was awake, running its agent and perfectly
//! reachable told the user to go and check the network.
//!
//! The connected pill NAMES the machine (T610), which is the half of Mac's
//! `MachinePillView` T367 left out: Mac's control is really two, a
//! `MachinePillCapsule` (dot + machine name, clickable, opens the Remote
//! Activity Monitor) and a `ConnectionStatusPill` that appears only when the
//! link is not up. Windows merges them into one capsule, so the name is what
//! the capsule says while there is nothing wrong to report. A permanent
//! "Connected" would be chrome that says nothing; a permanent MACHINE NAME
//! answers the question three remote windows actually pose — which is which.
//!
//! When the link IS in trouble the status is APPENDED to the name rather than
//! replacing it (D93, answered 2026-09-07). The first shape of this pill swapped
//! the name out for `Reconnecting… 3/5`, which made three dropping remote
//! windows identical in the titlebar — the one question the pill exists to
//! answer, unanswerable exactly when it matters. So the name stays and the
//! status follows it, and the cost D93 accepted is paid by ELLIPSIZING THE NAME
//! AGGRESSIVELY: a degraded pill gives the name `max_name_degraded_dip` and no
//! more, so the widened capsule cannot eat the row the tab strip lives in.
//!
//! That is why the label is two strings and not one (`parts`). The status is the
//! part that must survive — a tail-ellipsized `winbox — Reconnecting…` says
//! nothing the name did not already say — so the two are measured and painted in
//! their own boxes, and the squeeze falls on the name. A single string with
//! `DT_END_ELLIPSIS` would cut the far end, which is precisely the status.
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

/// The pill's presentations, derived from the ladder's window state.
///
/// `disconnected.self_healable` does NOT split them: it splits the RECOVERY
/// paths, and a window whose fast ladder is exhausted looks identical to a user
/// to one that is terminally gone — `manualReconnect` starts from either.
///
/// `disconnected.reason` DOES split them (T628). A link that is down because
/// the far agent disagrees about the protocol is a machine that is awake, an
/// agent that is running and a network that is fine, and a pill saying
/// `Reconnect` about it is an offer that cannot be honoured. It is the same red
/// — the link IS broken — carrying a different sentence, which is also what
/// keeps WCAG 1.4.1 satisfied: the four states differ in TEXT (none, a count,
/// an offer, a diagnosis), so hue is never the only carrier.
pub const Mode = enum { connected, reconnecting, disconnected, incompatible };

pub fn modeFor(state: policy.WindowState) Mode {
    return switch (state) {
        .connected => .connected,
        .reconnecting => .reconnecting,
        .disconnected => |d| switch (d.reason) {
            .transient => .disconnected,
            .incompatible => .incompatible,
        },
    };
}

/// What each mode MEANS in the shared status vocabulary. The pixel colors come
/// from `chrome_theme`, resolved against the band the pill lands on.
pub fn tone(mode: Mode) chrome_theme.Tone {
    return switch (mode) {
        .connected => .good,
        .reconnecting => .warn,
        // One red for a broken link, whatever broke it. The reason is carried
        // by the words, not by a fourth hue nobody could learn.
        .disconnected, .incompatible => .danger,
    };
}

/// Is this the ACTION mode — the red capsule whose whole job is the offer to
/// re-dial? Only the broken one is. It is not the same question as "is the pill
/// clickable" any more (T610: every state is — see `clickAction`); it is what
/// decides the red fill, the refresh glyph and the imperative label, all of
/// which would be lying about a link that is up.
pub fn isAction(mode: Mode) bool {
    return mode == .disconnected or mode == .incompatible;
}

/// What a click on the pill DOES in each state.
///
/// Two answers, and no state is inert: a working remote window's pill is Mac's
/// `MachinePillCapsule`, which opens the Remote Activity Monitor on the
/// connection the window already holds; a broken one's is the reconnect offer,
/// and reconnecting is the only thing worth offering there. The reconnecting
/// state keeps the Activity Monitor because its connection is still the
/// window's own — the ladder is retrying that link, not replacing it — and
/// taking the panel away mid-ladder would remove the one view that shows what
/// the far machine is doing.
pub const Click = enum { activity, reconnect };

pub fn clickAction(mode: Mode) Click {
    return if (isAction(mode)) .reconnect else .activity;
}

/// Is this mode one the AUTOMATIC ladder will keep working on? The skew is not:
/// it is the one broken state where retrying is known to be futile, so the
/// window sits still and waits for a person. The pill still re-dials on a
/// CLICK, because updating the far machine is exactly what a person does
/// between reading this label and pressing it.
pub fn retriesOnItsOwn(mode: Mode) bool {
    return mode != .incompatible;
}

/// The mark drawn at the pill's leading edge: a status dot, or the refresh
/// glyph on the button.
pub const Mark = enum { dot, refresh };

pub fn mark(mode: Mode) Mark {
    return switch (mode) {
        .connected, .reconnecting => .dot,
        // The skew keeps the refresh glyph because the click keeps its meaning:
        // once a side is updated, this pill is how you come back. A second
        // glyph would be a new symbol to learn for a control that still does
        // the same thing.
        .disconnected, .incompatible => .refresh,
    };
}

/// Longest machine name the pill will carry, in UTF-8 bytes. A longer name is
/// cut at a character boundary rather than refused: the DIP ceilings already
/// decides what is SEEN, and this is only the bound on what is copied.
pub const name_cap: usize = 64;

/// What separates the machine name from the status that follows it. It leads the
/// STATUS rather than trailing the name, so a name squeezed to its floor
/// ellipsizes its own characters and never the dash — a trailing separator
/// produces `winbox…Reconnect`, with the one glyph that made it a sentence gone.
pub const sep = " \u{2014} ";

/// Longest a status alone can be, separator included, so a caller can size a
/// buffer for one half: `\u{2014} Reconnecting… 999999/5` and room to spare.
pub const status_cap: usize = 32;

/// Longest label any state can produce, so callers can size a stack buffer: the
/// machine name plus the status that now follows it (D93).
pub const label_cap: usize = name_cap + status_cap;

/// The pill's label in the two halves it is really made of.
///
/// `name` is the machine this window rides on; `status` is what the link to it
/// is doing, empty while the link is fine. They are painted in that order and
/// squeezed independently, which is the whole reason they are two strings — see
/// the module header.
pub const Parts = struct {
    name: []const u8 = "",
    status: []const u8 = "",
};

/// The pill's two halves, written into `buf` (needs `label_cap`). `machine` is
/// the display name of the machine this window rides on, or empty when the
/// window has none to name — a connected pill then falls back to the wordless
/// dot it showed before T610, which is the honest answer rather than a
/// placeholder.
///
/// The status carries the separator when there is a name in front of it, and
/// that is the ONE place the question is answered: a window with no machine to
/// name says `Reconnect`, never `— Reconnect`.
///
/// The attempt is shown as `n/5` rather than a bare count because a number with
/// no ceiling cannot tell you whether waiting is still worth it. The ceiling is
/// the policy's own `max_attempts`, asked for rather than restated.
pub fn parts(buf: []u8, state: policy.WindowState, machine: []const u8) Parts {
    const name = copyName(buf, machine);
    const rest = buf[name.len..];
    const lead: []const u8 = if (name.len > 0) sep else "";

    const status: []const u8 = switch (state) {
        .connected => "",
        .reconnecting => |r| std.fmt.bufPrint(
            rest,
            "{s}Reconnecting\u{2026} {d}/{d}",
            .{ lead, r.attempt, policy.max_attempts },
        ) catch "Reconnecting\u{2026}",
        .disconnected => |d| switch (d.reason) {
            .transient => std.fmt.bufPrint(
                rest,
                "{s}Reconnect",
                .{lead},
            ) catch "Reconnect",
            // Not an offer, a diagnosis (T628). "Reconnect" here would be a
            // button promising something no click can deliver, and the user
            // would press it five times before going to look at the network.
            .incompatible => std.fmt.bufPrint(
                rest,
                "{s}Version mismatch",
                .{lead},
            ) catch "Version mismatch",
        },
    };
    return .{ .name = name, .status = status };
}

/// The whole label as one string, written into `buf` (needs `label_cap`) — what
/// the debug oracle logs and what a reader that does not paint the halves
/// separately wants. The PAINTER uses `parts`, because the halves have to be
/// squeezed independently.
pub fn label(buf: []u8, state: policy.WindowState, machine: []const u8) []const u8 {
    var tmp: [label_cap]u8 = undefined;
    const p = parts(&tmp, state, machine);
    const n = @min(buf.len, p.name.len);
    @memcpy(buf[0..n], p.name[0..n]);
    const m = @min(buf.len - n, p.status.len);
    @memcpy(buf[n..][0..m], p.status[0..m]);
    return buf[0 .. n + m];
}

/// `machine` copied into `buf`, cut to `name_cap` on a UTF-8 character
/// boundary. Cutting mid-sequence would hand GDI a lone continuation byte and
/// paint a replacement glyph on the one control whose job is to be recognized.
fn copyName(buf: []u8, machine: []const u8) []const u8 {
    var n = @min(@min(buf.len, name_cap), machine.len);
    while (n > 0 and n < machine.len and machine[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(buf[0..n], machine[0..n]);
    return buf[0..n];
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
        .disconnected => |d| switch (d.reason) {
            .transient => std.fmt.bufPrint(
                buf,
                "Connection to {s} lost \u{2014} click to reconnect",
                .{who},
            ) catch "Click to reconnect",
            // The label has room for two words; this is where the user finds
            // out what to DO about it, and which side to update is the one
            // thing the label cannot fit.
            .incompatible => std.fmt.bufPrint(
                buf,
                "{s} runs a different version of Ghoztty \u{2014} update one side, then click to reconnect",
                .{who},
            ) catch "Update one side to reconnect",
        },
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
/// The widest the machine NAME may make the pill (T610). A machine name is user
/// data and hostnames run long; without a ceiling one window's
/// `build-agent-westus2.corp` would eat the band the tab run and the title live
/// in, and the pill would be the only control on screen sized by somebody's DNS.
/// 128 DIP is about sixteen characters of the caption face — enough that the
/// names people actually give machines fit whole — and anything past it
/// tail-ellipsizes, which is what the tooltip is there to rescue.
pub const max_name_dip: f32 = 128.0;

/// The name's ceiling once a STATUS shares the capsule with it (D93). The
/// status is 100-odd DIP of its own and the caption band is not getting any
/// wider, so the resting ceiling would put a degraded pill at a quarter of a
/// 1080p titlebar and push the tab strip aside every time a link wobbled. 72 DIP
/// is about nine characters — enough to tell `winbox` from `build-agent-1` at a
/// glance, which is the whole job D93 gave this label, and deliberately not
/// enough to read a long hostname whole. That is the cost D93's answer accepted
/// by name, and the tooltip still carries the name in full.
pub const max_name_degraded_dip: f32 = 72.0;

/// The floor the name keeps in a squeeze. The status may be clipped, the name
/// may be cut to `w…`, but a pill on a window that HAS a machine never stops
/// naming it — losing the name is the exact failure D93 was answered to end, and
/// a rule that gives it up under pressure is the same failure with a narrower
/// trigger.
pub const min_name_dip: f32 = 24.0;

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
    /// The name's ceiling while the link is up (`max_name_dip`), in physical
    /// pixels.
    max_name: i32,
    /// The name's ceiling while a status shares the capsule (`max_name_degraded_dip`).
    max_name_degraded: i32,
    /// The name's floor in a squeeze (`min_name_dip`).
    min_name: i32,
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
            .max_name = px(max_name_dip, scale),
            .max_name_degraded = px(max_name_degraded_dip, scale),
            .min_name = px(min_name_dip, scale),
            .font = font,
            .ib = icon_button.Metrics.init(scale),
        };
    }

    /// How wide the machine name may be in this mode: the resting ceiling while
    /// the link is up, the aggressive one once a status is sharing the capsule.
    pub fn maxName(self: Metrics, mode: Mode) i32 {
        return if (mode == .connected) self.max_name else self.max_name_degraded;
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

/// The pill's natural width for a name `name_w` px wide and a status `status_w`
/// px wide (both GDI-measured by the caller at `m.font`, from `parts`). A label
/// that measured to nothing takes its gap with it: the gap separates two things,
/// and a pill showing only its dot has one.
///
/// Only the NAME is clamped, and it is clamped here rather than at the measuring
/// site so the ceiling is enforced once for everyone who asks how wide the pill
/// is — `layout` then hands the clamped box to `DT_END_ELLIPSIS`. The status is
/// not clamped because it is not user data: its longest form is a wording this
/// module chose, and clipping it would drop the very thing the widened pill
/// exists to say.
pub fn width(m: Metrics, mode: Mode, name_w: i32, status_w: i32) i32 {
    const nw: i32 = @min(@as(i32, @max(name_w, 0)), m.maxName(mode));
    const sw: i32 = @max(status_w, 0);
    const text = nw + sw;
    const content = m.markSize(mode) + (if (text > 0) m.gap + text else 0);
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
    /// The machine name's box, vertically centered by the caller's `DT_VCENTER`.
    /// Empty when the window has no machine to name, or when the pill was
    /// squeezed below the width its own mark needs.
    name: Rect,
    /// The status's box, immediately after the name's (the separator leads the
    /// status string, so the two abut rather than being spaced apart here).
    /// Empty while the link is up.
    status: Rect,
};

/// Fill `pill`'s interior: mark at the leading edge, then the machine name, then
/// the status.
///
/// The mark is vertically centered on the capsule and the two text boxes take
/// whatever is left, so a pill narrower than its natural width tail-ellipsizes
/// (the caller's `DT_END_ELLIPSIS`) instead of overflowing. Below the width its
/// mark alone needs, the label is dropped outright — the same choice the caption
/// band makes with a title it cannot fit.
///
/// WHO gives way in a squeeze is the interesting part (D93). The status is
/// served first, because a pill that has room for `winbox — Reconn…` and chose
/// to spend it that way tells you nothing you did not already know. The name
/// then takes what is left, down to `m.min_name` — and no further: below that
/// the STATUS is clipped instead, because a pill on a window that has a machine
/// must never stop naming it. That floor is what makes "always show the name"
/// true at every width rather than only at comfortable ones.
///
/// Whether a mode HAS a label is not asked here (T610): every mode can have one
/// now, and a `connected` pill on a window with no machine to name simply
/// measured to zero and was never given the room. The boxes follow the space,
/// and the painter draws nothing into one that is empty.
pub fn layout(m: Metrics, pill: Rect, mode: Mode, name_w: i32, status_w: i32) Layout {
    const empty: Layout = .{ .pill = pill, .mark = .{}, .name = .{}, .status = .{} };
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
    const avail = text_right - text_left;
    if (avail <= 0) return .{ .pill = pill, .mark = mark_rect, .name = .{}, .status = .{} };

    const wanted_name: i32 = @min(@as(i32, @max(name_w, 0)), m.maxName(mode));
    const wanted_status: i32 = @max(status_w, 0);

    var nw: i32 = wanted_name;
    var sw: i32 = wanted_status;
    if (nw + sw > avail) {
        // The status is served first...
        sw = @min(wanted_status, avail);
        nw = avail - sw;
        // ...unless that leaves the name below its floor, which is the one thing
        // this pill is not allowed to do while it has a machine to name.
        if (wanted_name > 0 and nw < m.min_name) {
            nw = @min(@min(m.min_name, wanted_name), avail);
            sw = avail - nw;
        }
    }

    var x = text_left;
    const name_rect: Rect = if (nw > 0)
        .{ .left = x, .top = pill.top, .right = x + nw, .bottom = pill.bottom }
    else
        .{};
    x += nw;
    const status_rect: Rect = if (sw > 0)
        .{ .left = x, .top = pill.top, .right = x + sw, .bottom = pill.bottom }
    else
        .{};

    return .{ .pill = pill, .mark = mark_rect, .name = name_rect, .status = status_rect };
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
/// Every mode reacts to hover and press (T610), because every mode is now a
/// button: the quiet pill opens the Activity Monitor. The lit fill is the tint
/// SHADED, in the direction the band is not — lighter on a dark band, darker on
/// a light one — and the mark and label are then resolved against the shaded
/// fill rather than the resting one, so the contrast floors hold in the state
/// the pixels are actually in.
///
/// White, not `contrastForeground(fill)` (T528). A searched foreground on a red
/// fill is exactly what put a BLACK X on the caption's close button: the red is
/// resolved to carry white, so a foreground that re-decides per state can only
/// disagree with the fill's own constraint. It firms DARKER on hover and press
/// for the same reason the caption slab does — a saturated fill that lightens
/// walks toward the ceiling white needs, and away from the color it is.
pub fn ink(bar: Rgb, pal: chrome_theme.Palette, mode: Mode, state: icon_button.State) Ink {
    if (isAction(mode)) {
        const d = if (icon_button.paintsFill(state)) icon_button.fillDelta(state, false) else 0;
        const fill: Rgb = .{
            .r = icon_button.shadeChannel(pal.danger.r, d),
            .g = icon_button.shadeChannel(pal.danger.g, d),
            .b = icon_button.shadeChannel(pal.danger.b, d),
        };
        return .{ .fill = fill, .mark = pal.on_danger, .text = pal.on_danger };
    }

    // The quiet modes light too, now that clicking one opens the Activity
    // Monitor: an affordance that never responds to the pointer reads as
    // decoration, and the pill is the only chrome control a remote window has.
    const t = tone(mode);
    const base = chrome_theme.toneFill(bar, t);
    const d = if (icon_button.paintsFill(state))
        icon_button.fillDelta(state, !color_math.isLight(bar))
    else
        0;
    const fill: Rgb = .{
        .r = icon_button.shadeChannel(base.r, d),
        .g = icon_button.shadeChannel(base.g, d),
        .b = icon_button.shadeChannel(base.b, d),
    };
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

test "modeFor: the ladder's states map onto the presentations" {
    try testing.expectEqual(Mode.connected, modeFor(.connected));
    try testing.expectEqual(Mode.reconnecting, modeFor(.{ .reconnecting = .{ .attempt = 1 } }));
    // Both disconnected tiers present identically — the split is about recovery.
    try testing.expectEqual(Mode.disconnected, modeFor(policy.exhausted_state));
    try testing.expectEqual(Mode.disconnected, modeFor(policy.terminal_state));
    // ...except the one whose REASON the user has to know (T628).
    try testing.expectEqual(Mode.incompatible, modeFor(policy.incompatible_state));
}

test "a version skew reads as its own state, in words (T628)" {
    // The red is shared with `disconnected` — the link really is broken — so
    // everything that separates the two has to be text.
    try testing.expectEqual(tone(.disconnected), tone(.incompatible));
    try testing.expect(isAction(.incompatible));
    try testing.expectEqual(Mark.refresh, mark(.incompatible));
    // Clicking still re-dials: updating the far machine is what a person does
    // between reading this and pressing it. What must NOT happen is the ladder
    // doing it on its own, five times, for nothing.
    try testing.expectEqual(Click.reconnect, clickAction(.incompatible));
    try testing.expect(!retriesOnItsOwn(.incompatible));
    for ([_]Mode{ .connected, .reconnecting, .disconnected }) |m|
        try testing.expect(retriesOnItsOwn(m));

    var buf: [label_cap]u8 = undefined;
    const skew = parts(&buf, policy.incompatible_state, "winbox");
    try testing.expectEqualStrings("winbox", skew.name);
    try testing.expectEqualStrings(" \u{2014} Version mismatch", skew.status);

    // Distinct from the state it used to be indistinguishable from. This is the
    // whole defect: the two said the same thing about very different machines.
    var buf2: [label_cap]u8 = undefined;
    const down = parts(&buf2, policy.terminal_state, "winbox");
    try testing.expect(!std.mem.eql(u8, down.status, skew.status));

    // A window with no machine to name still gets a bare, unpunctuated status.
    var buf3: [label_cap]u8 = undefined;
    const nameless = parts(&buf3, policy.incompatible_state, "");
    try testing.expectEqualStrings("", nameless.name);
    try testing.expectEqualStrings("Version mismatch", nameless.status);

    // The tooltip carries the part the label has no room for: which side, and
    // that reconnecting is still the way back afterwards.
    var tip: [tooltip_cap + name_cap]u8 = undefined;
    const t = tooltip(&tip, policy.incompatible_state, "winbox");
    try testing.expect(std.mem.indexOf(u8, t, "winbox") != null);
    try testing.expect(std.mem.indexOf(u8, t, "different version") != null);
    try testing.expect(std.mem.indexOf(u8, t, "update one side") != null);
    // ...and it never says the connection was "lost", which is the word that
    // sends people to the network.
    try testing.expect(std.mem.indexOf(u8, t, "lost") == null);
}

test "the skew label fits the same buffers every other state is sized for" {
    // `status_cap` is what callers size a half-buffer with; a status that
    // overflowed it would fall back to the un-separated `catch` arm and paint
    // `winboxVersion mismatch`.
    var buf: [label_cap]u8 = undefined;
    const long = "build-agent-westus2.corp.example.internal.name.that.runs.on";
    const p2 = parts(&buf, policy.incompatible_state, long);
    try testing.expect(p2.status.len <= status_cap);
    try testing.expect(p2.name.len + p2.status.len <= label_cap);
    // The separator survived the squeeze — the status is a suffix of the name,
    // not glued to it.
    try testing.expect(std.mem.startsWith(u8, p2.status, sep));
}

test "isAction: only the broken pills wear the red action treatment" {
    try testing.expect(!isAction(.connected));
    try testing.expect(!isAction(.reconnecting));
    try testing.expect(isAction(.disconnected));
    try testing.expect(isAction(.incompatible));
}

test "clickAction: no state is inert, and only the broken one re-dials" {
    // Mac's capsule opens the Activity Monitor whenever the window has a
    // connection to look at; only the status half turns into a Reconnect.
    try testing.expectEqual(Click.activity, clickAction(.connected));
    try testing.expectEqual(Click.activity, clickAction(.reconnecting));
    try testing.expectEqual(Click.reconnect, clickAction(.disconnected));
}

test "label: the machine is named in EVERY state, with the status after it" {
    var buf: [label_cap]u8 = undefined;
    try testing.expectEqualStrings("winbox", label(&buf, .connected, "winbox"));
    // D93: the status is appended, never a swap. Three dropping remote windows
    // have to stay tellable apart in the titlebar.
    try testing.expectEqualStrings(
        "winbox \u{2014} Reconnecting\u{2026} 2/5",
        label(&buf, .{ .reconnecting = .{ .attempt = 2 } }, "winbox"),
    );
    try testing.expectEqualStrings(
        "winbox \u{2014} Reconnect",
        label(&buf, policy.exhausted_state, "winbox"),
    );
    try testing.expectEqualStrings(
        "winbox \u{2014} Reconnect",
        label(&buf, policy.terminal_state, "winbox"),
    );
}

test "label: with no machine to name, the status stands alone — no orphan dash" {
    var buf: [label_cap]u8 = undefined;
    // No machine to name -> the wordless dot, never a placeholder word.
    try testing.expectEqualStrings("", label(&buf, .connected, ""));
    try testing.expectEqualStrings(
        "Reconnecting\u{2026} 2/5",
        label(&buf, .{ .reconnecting = .{ .attempt = 2 } }, ""),
    );
    try testing.expectEqualStrings("Reconnect", label(&buf, policy.terminal_state, ""));
}

test "parts: the halves are the label, split where the squeeze has to fall" {
    var buf: [label_cap]u8 = undefined;
    const p = parts(&buf, .{ .reconnecting = .{ .attempt = 3 } }, "winbox");
    try testing.expectEqualStrings("winbox", p.name);
    // The separator leads the STATUS, so a name cut to its floor loses its own
    // characters and never the dash that made the two a sentence.
    try testing.expectEqualStrings(" \u{2014} Reconnecting\u{2026} 3/5", p.status);

    const up = parts(&buf, .connected, "winbox");
    try testing.expectEqualStrings("winbox", up.name);
    try testing.expectEqualStrings("", up.status);

    const anon = parts(&buf, policy.terminal_state, "");
    try testing.expectEqualStrings("", anon.name);
    try testing.expectEqualStrings("Reconnect", anon.status);
}

test "label: an over-long machine name is cut on a character boundary" {
    var buf: [label_cap]u8 = undefined;
    // Multi-byte throughout, so a naive byte cut would land mid-sequence.
    const long = "\u{00e9}" ** name_cap;
    const got = label(&buf, .connected, long);
    try testing.expect(got.len <= name_cap);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
    // And a name that fits is passed through whole.
    try testing.expectEqualStrings("build-agent-1", label(&buf, .connected, "build-agent-1"));
}

test "label: the attempt ceiling is the policy's, not a restated number" {
    var buf: [label_cap]u8 = undefined;
    const s = label(&buf, .{ .reconnecting = .{ .attempt = policy.max_attempts } }, "winbox");
    var expect_buf: [label_cap]u8 = undefined;
    const expect = try std.fmt.bufPrint(
        &expect_buf,
        "winbox{s}Reconnecting\u{2026} {d}/{d}",
        .{ sep, policy.max_attempts, policy.max_attempts },
    );
    try testing.expectEqualStrings(expect, s);
}

test "label_cap holds the longest label at an absurd attempt count" {
    var buf: [label_cap]u8 = undefined;
    const longest = "\u{00e9}" ** name_cap;
    const s = label(&buf, .{ .reconnecting = .{ .attempt = 999_999 } }, longest);
    // Either it fit or it fell back — never a truncated half-word, and never a
    // status the name pushed out of the buffer.
    try testing.expect(std.mem.indexOf(u8, s, "Reconnecting") != null);
    try testing.expect(std.unicode.utf8ValidateSlice(s));
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
        try testing.expectEqual(m.dot + m.pad_x * 2, width(m, .connected, 0, 0));
        // A label on the connected pill would still be honored if one existed,
        // so the "no gap" rule is about the measured text, not the mode.
        try testing.expectEqual(
            m.glyph + m.gap + 40 + m.pad_x * 2,
            width(m, .disconnected, 0, 40),
        );
    }
}

test "width: the name and the status both count, and they abut" {
    for (scales) |s| {
        const m = Metrics.init(s);
        // One gap for the pair, not one each: the separator is inside the
        // status string, so the two boxes touch.
        try testing.expectEqual(
            m.dot + m.gap + 30 + 60 + m.pad_x * 2,
            width(m, .reconnecting, 30, 60),
        );
    }
}

test "width: a long machine name cannot grow the pill past its ceiling" {
    for (scales) |s| {
        const m = Metrics.init(s);
        const capped = width(m, .connected, m.max_name, 0);
        // A name measuring twice the ceiling buys nothing more.
        try testing.expectEqual(capped, width(m, .connected, m.max_name * 2, 0));
        // ...and the ceiling is a real one: it is reached, not merely declared.
        try testing.expect(capped > width(m, .connected, 0, 0));
    }
}

test "width: a degraded pill holds the name to a tighter ceiling (D93)" {
    for (scales) |s| {
        const m = Metrics.init(s);
        try testing.expect(m.max_name_degraded < m.max_name);
        const huge = m.max_name * 4;
        // The same name buys less room once a status is sharing the capsule, so
        // the widened chip cannot eat the row the tab strip lives in.
        const up = width(m, .connected, huge, 0);
        const down = width(m, .reconnecting, huge, 0);
        try testing.expect(down < up);
        try testing.expectEqual(
            m.dot + m.gap + m.max_name_degraded + m.pad_x * 2,
            down,
        );
    }
}

test "width: grows with the label, monotonically" {
    for (scales) |s| {
        const m = Metrics.init(s);
        var last: i32 = 0;
        for ([_]i32{ 0, 10, 40, 100 }) |tw| {
            const w = width(m, .reconnecting, 0, tw);
            try testing.expect(w > last);
            last = w;
        }
    }
}

test "layout: mark, name and status keep the padding, and nothing hangs out" {
    for (scales) |s| {
        const m = Metrics.init(s);
        const name_w: i32 = px(40.0, s);
        const status_w: i32 = px(60.0, s);
        for ([_]Mode{ .connected, .reconnecting, .disconnected, .incompatible }) |mode| {
            const sw: i32 = if (mode == .connected) 0 else status_w;
            const w = width(m, mode, name_w, sw);
            const pill: Rect = .{ .left = 100, .top = 6, .right = 100 + w, .bottom = 6 + m.h };
            const l = layout(m, pill, mode, name_w, sw);

            try testing.expectEqual(pill.left + m.pad_x, l.mark.left);
            try testing.expectEqual(m.markSize(mode), l.mark.width());
            try testing.expectEqual(m.markSize(mode), l.mark.height());
            // Vertically centered on the capsule, to the pixel.
            try testing.expectEqual(
                pill.top + @divTrunc(pill.height() - l.mark.height(), 2),
                l.mark.top,
            );
            try testing.expect(l.mark.right <= pill.right - m.pad_x);

            // The name is present in EVERY mode now (D93) — that is the point.
            try testing.expect(!l.name.isEmpty());
            try testing.expectEqual(l.mark.right + m.gap, l.name.left);
            try testing.expectEqual(name_w, l.name.width());

            if (mode == .connected) {
                try testing.expect(l.status.isEmpty());
                try testing.expectEqual(pill.right - m.pad_x, l.name.right);
            } else {
                try testing.expect(!l.status.isEmpty());
                // Abutting: the separator is inside the status string.
                try testing.expectEqual(l.name.right, l.status.left);
                try testing.expectEqual(status_w, l.status.width());
                try testing.expectEqual(pill.right - m.pad_x, l.status.right);
            }
        }
    }
}

test "layout: the squeeze falls on the name first, and stops at its floor" {
    for (scales) |s| {
        const m = Metrics.init(s);
        const name_w = m.max_name_degraded;
        const status_w = px(90.0, s);

        // Comfortable: both get what they asked for.
        const roomy = width(m, .reconnecting, name_w, status_w);
        const full = layout(
            m,
            .{ .left = 0, .top = 0, .right = roomy, .bottom = m.h },
            .reconnecting,
            name_w,
            status_w,
        );
        try testing.expectEqual(name_w, full.name.width());
        try testing.expectEqual(status_w, full.status.width());

        // Squeezed by half the name: the STATUS is intact and the name gave way,
        // because a tail-clipped "Reconnec…" says nothing the name did not.
        const tight = layout(
            m,
            .{ .left = 0, .top = 0, .right = roomy - @divTrunc(name_w, 2), .bottom = m.h },
            .reconnecting,
            name_w,
            status_w,
        );
        try testing.expectEqual(status_w, tight.status.width());
        try testing.expect(tight.name.width() < name_w);
        try testing.expect(tight.name.width() >= m.min_name);

        // Squeezed past the floor: the name KEEPS its floor and the status is
        // clipped instead. A pill on a window that has a machine never stops
        // naming it (D93).
        const brutal = layout(
            m,
            .{
                .left = 0,
                .top = 0,
                .right = m.pad_x * 2 + m.dot + m.gap + m.min_name + @divTrunc(status_w, 2),
                .bottom = m.h,
            },
            .reconnecting,
            name_w,
            status_w,
        );
        try testing.expectEqual(m.min_name, brutal.name.width());
        try testing.expect(brutal.status.width() < status_w);
    }
}

test "layout: a squeezed pill drops its label, then refuses to draw at all" {
    for (scales) |s| {
        const m = Metrics.init(s);
        // Wide enough for the mark and its padding, too narrow for a label.
        const narrow = m.glyph + m.pad_x * 2 + m.gap;
        const pill: Rect = .{ .left = 0, .top = 0, .right = narrow, .bottom = m.h };
        const l = layout(m, pill, .disconnected, 40, 40);
        try testing.expect(!l.mark.isEmpty());
        try testing.expect(l.name.isEmpty());
        try testing.expect(l.status.isEmpty());

        // Narrower than the mark plus its padding: nothing, rather than a mark
        // hanging past the capsule's end.
        const tiny: Rect = .{ .left = 0, .top = 0, .right = m.glyph, .bottom = m.h };
        const lt = layout(m, tiny, .disconnected, 40, 40);
        try testing.expect(lt.mark.isEmpty());
        try testing.expect(lt.name.isEmpty());
        try testing.expect(lt.status.isEmpty());

        try testing.expect(layout(m, .{}, .connected, 0, 0).mark.isEmpty());
    }
}

/// The §2.3 floors, exactly as the design system states them. They used to
/// carry a 0.05 tolerance: the shared contrast search ran in Lab and sRGB
/// floats and then quantized to 8 bits, so a mark could land a hair under the
/// target it had just cleared (measured 2.9918 for the green dot on a white
/// band). T325 moved that search's acceptance test onto the quantized color,
/// so the floor no longer needs slack anywhere.
const mark_floor: f64 = chrome_theme.ui_contrast_target;
const text_floor: f64 = 4.5;

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
            for ([_]Mode{ .connected, .reconnecting, .disconnected, .incompatible }) |mode| {
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
                    if (isAction(mode)) {
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

test "ink: hover is a change of FILL, in every state, on either theme" {
    // §2.2: hover is a fill, not a recolored glyph. And since T610 the quiet
    // states light too, because clicking one opens the Activity Monitor — a
    // control that never answers the pointer reads as decoration.
    for ([_]Rgb{
        .{ .r = 0x1E, .g = 0x1E, .b = 0x1E },
        .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 },
    }) |bar| {
        const pal = chrome_theme.resolve(bar, .{ .r = 0x00, .g = 0x78, .b = 0xD4 });
        for ([_]Mode{ .connected, .reconnecting, .disconnected, .incompatible }) |mode| {
            const rest = ink(pal.bar, pal, mode, .normal);
            const hover = ink(pal.bar, pal, mode, .hover);
            const pressed = ink(pal.bar, pal, mode, .pressed);
            try testing.expect(channelDistance(rest.fill, hover.fill) > 0);
            // Pressed is a FIRMER hover, not a second direction.
            try testing.expect(
                channelDistance(rest.fill, pressed.fill) >
                    channelDistance(rest.fill, hover.fill),
            );
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
