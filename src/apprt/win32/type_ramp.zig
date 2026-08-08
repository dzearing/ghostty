//! One type ramp for the win32 dialog surfaces (T310, the type half of T227).
//!
//! Every dialog on Windows used to write its own font height out longhand —
//! `font_h = px(15, scale)` appears in `chooser_layout`, `HostSettingsDialog`,
//! `activity_layout`, `BannerDialog`, `ConfirmDialog`, `NewProcessDialog` and
//! `RenameDialog`, seven copies of one number that nobody chose on purpose. A
//! ramp written out N times is N chances to disagree, which is the same
//! argument T257 made for hoisting the chrome geometry: the duplication is not
//! the defect, the silent divergence it permits is.
//!
//! The sizes come from `docs/design/win32-machine-chooser.md` §3.2, which
//! settled them for the chooser and stated the reasoning in a form that is not
//! chooser-specific:
//!
//!   - **Caption 12** — row sublines, detail subtitles, status strips, badges.
//!     Deliberately coincides with `SPI_GETNONCLIENTMETRICS`' 9 pt body, so the
//!     smallest text we draw is never smaller than Windows' own.
//!   - **Body 14** — row titles, buttons, input fields, labels.
//!   - **Body strong 14 @ 600** — an emphasized body run.
//!   - **Subtitle 20 @ 600** — a pane's subject.
//!
//! Body at **14 rather than the system metric's 12** is a conscious divergence
//! and §3.2 records why: Win11's own modern apps (Settings, the Store, Task
//! Manager's newer surfaces) are at 14, and matching the 9 pt GDI font makes a
//! dialog look like it shipped in 2009 next to them. It is 12/14/20 and nothing
//! else — the divergence buys three sizes, not a licence to invent more.
//!
//! Pure: no `win32.zig` import, so this runs in every app-runtime test lane.
//! Callers turn a height into a font themselves (`CreateFontW` wants it
//! negated; this module deals in positive heights like every layout module).

const std = @import("std");

/// A text role. `height` is a positive `CreateFontW` character height in
/// physical pixels; `weight` is a GDI weight (400 normal, 600 semibold).
pub const Font = struct {
    height: i32,
    weight: i32,
};

/// The ramp at 1.0, in DIP. Stated as data so a test can walk it.
pub const caption_dip: f32 = 12;
pub const body_dip: f32 = 14;
pub const subtitle_dip: f32 = 20;

pub const weight_normal: i32 = 400;
pub const weight_semibold: i32 = 600;

/// The leading a single line of text gets on top of its character height when
/// a layout has to reserve a box for it — the `sm` step of the 4 DIP spacing
/// scale. One number, because a line box written out per dialog is the same
/// silent-divergence hazard the ramp itself removes: `BannerDialog` reserved a
/// flat 16 px for a 15 px label, which was a fit by coincidence and would have
/// clipped the moment either number moved.
pub const leading_dip: f32 = 4;

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// De-emphasized text: sublines, subtitles, status strips, badges.
pub fn caption(scale: f32) Font {
    return .{ .height = px(caption_dip, scale), .weight = weight_normal };
}

/// The default text of a dialog: titles in a list row, button captions, input
/// fields, labels.
pub fn body(scale: f32) Font {
    return .{ .height = px(body_dip, scale), .weight = weight_normal };
}

/// Body, emphasized. Same size — weight is the emphasis, not a size bump, so a
/// strong run never reflows the line box around it.
pub fn bodyStrong(scale: f32) Font {
    return .{ .height = px(body_dip, scale), .weight = weight_semibold };
}

/// A pane's subject: the biggest text on a dialog surface.
pub fn subtitle(scale: f32) Font {
    return .{ .height = px(subtitle_dip, scale), .weight = weight_semibold };
}

/// The height of the box a layout reserves for ONE line of `f`: the character
/// height plus `leading_dip`. Use it wherever a rect exists to hold a line of
/// text — a label row, a hint strip, a row title — so the box follows the ramp
/// instead of being a constant that happens to be big enough today.
pub fn lineBox(f: Font, scale: f32) i32 {
    return f.height + px(leading_dip, scale);
}

/// The face every role is set in. One name, so a dialog cannot half-migrate.
pub const face = "Segoe UI";

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "the ramp is 12 / 14 / 20 at 1.0, and nothing else" {
    try testing.expectEqual(@as(i32, 12), caption(1.0).height);
    try testing.expectEqual(@as(i32, 14), body(1.0).height);
    try testing.expectEqual(@as(i32, 14), bodyStrong(1.0).height);
    try testing.expectEqual(@as(i32, 20), subtitle(1.0).height);

    // Three sizes total. The divergence from the system metric bought us 14;
    // it did not buy a fourth size, and this is the assertion that says so.
    var seen: [4]i32 = .{
        caption(1.0).height,
        body(1.0).height,
        bodyStrong(1.0).height,
        subtitle(1.0).height,
    };
    std.mem.sort(i32, &seen, {}, std.sort.asc(i32));
    var distinct: usize = 0;
    for (seen, 0..) |h, i| {
        if (i == 0 or h != seen[i - 1]) distinct += 1;
    }
    try testing.expectEqual(@as(usize, 3), distinct);
}

test "a line box is the ramp height plus one leading step, at every scale" {
    try testing.expectEqual(@as(i32, 16), lineBox(caption(1.0), 1.0));
    try testing.expectEqual(@as(i32, 18), lineBox(body(1.0), 1.0));
    try testing.expectEqual(@as(i32, 24), lineBox(subtitle(1.0), 1.0));

    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        // The box always clears its text, and never by more than one step —
        // a box that has drifted away from its font is the defect this exists
        // to prevent.
        inline for (.{ caption, body, subtitle }) |role| {
            const f = role(scale);
            try testing.expect(lineBox(f, scale) > f.height);
            try testing.expectEqual(f.height + @as(i32, @intFromFloat(@round(leading_dip * scale))), lineBox(f, scale));
        }
        // Emphasis does not change the box, because it does not change the size.
        try testing.expectEqual(lineBox(body(scale), scale), lineBox(bodyStrong(scale), scale));
    }
}

test "caption is never smaller than the system's own body metric" {
    // SPI_GETNONCLIENTMETRICS reports a 9 pt / 12 px body on this box (T302
    // §1.1). The smallest text we draw sits AT that floor, never under it.
    try testing.expect(caption(1.0).height >= 12);
    try testing.expect(caption(1.0).height < body(1.0).height);
    try testing.expect(body(1.0).height < subtitle(1.0).height);
}

test "emphasis is weight, not size" {
    try testing.expectEqual(body(1.0).height, bodyStrong(1.0).height);
    try testing.expect(bodyStrong(1.0).weight > body(1.0).weight);
    try testing.expectEqual(weight_normal, caption(1.0).weight);
    try testing.expectEqual(weight_semibold, subtitle(1.0).weight);
}

test "scales with DPI, and weight does not" {
    inline for (.{ @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        try testing.expect(caption(scale).height > caption(1.0).height);
        try testing.expect(body(scale).height > body(1.0).height);
        try testing.expect(subtitle(scale).height > subtitle(1.0).height);
        // The ordering survives rounding at every scale — a ramp that inverts
        // at 1.25 is exactly the class of defect the design system calls out.
        try testing.expect(caption(scale).height < body(scale).height);
        try testing.expect(body(scale).height < subtitle(scale).height);
        try testing.expectEqual(weight_semibold, subtitle(scale).weight);
    }
    try testing.expectEqual(@as(i32, 24), caption(2.0).height);
    try testing.expectEqual(@as(i32, 28), body(2.0).height);
    try testing.expectEqual(@as(i32, 40), subtitle(2.0).height);
}
