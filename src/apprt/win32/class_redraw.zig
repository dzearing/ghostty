//! T467: measuring what a window class invalidates when its window is RESIZED.
//!
//! `CS_HREDRAW | CS_VREDRAW` is the difference between "Windows invalidates the
//! whole client area on a size change" and "Windows invalidates only the strip
//! the resize uncovered". A class whose painted content is derived from its own
//! bounds needs the first; a class that paints something a partial repaint
//! cannot tell apart (a flat fill) is fine with the second. Getting it wrong is
//! invisible in a screenshot and obvious in motion: the window keeps the
//! geometry it was last painted at while its frame moves (T456, the pane
//! banner).
//!
//! That property belongs to the CLASS, not to any function, so it can only be
//! asserted against a real window — which is what this module does, once, for
//! every class that needs it. Both controls live here too (`positive`/
//! `negative` below), so the measurement is proven in both directions on every
//! run rather than by a hand-run experiment somebody remembers doing.
//!
//! The audit that decided which classes need this is in
//! `docs/claude/win32-ui.md`.

const std = @import("std");
const w32 = @import("win32.zig");

/// What one resize invalidated, against the client it happened in.
pub const Measured = struct {
    client_w: i32,
    client_h: i32,
    update_w: i32,
    update_h: i32,

    pub fn coversWholeClient(self: Measured) bool {
        return self.update_w == self.client_w and self.update_h == self.client_h;
    }
};

/// Which dimension the probe changes. Measured separately so a class carrying
/// only one of the two style bits cannot pass: a probe that moves both edges at
/// once is satisfied by `CS_HREDRAW` alone.
pub const Axis = enum { width, height };

const start_w: i32 = 400;
const start_h: i32 = 200;
/// The amount a divider drag moves in a few frames.
const grow: i32 = 40;

/// Create a window of `class_name`, resize it along `axis`, and report what
/// Windows put in its update region.
///
/// The window is created ON-SCREEN and shown, at layered alpha 0. Both halves
/// are load-bearing: parked outside every monitor it has an empty visible
/// region, so Windows invalidates nothing on a resize and a "covers the whole
/// client" assertion fails for a reason that has nothing to do with the class
/// (measured in T456, where the first version of this test passed while parked
/// off-screen for exactly that reason). Alpha 0 keeps it genuinely visible to
/// the window manager while painting nothing a human running the suite sees.
///
/// Returns `error.SkipZigTest` when this process has no usable window station,
/// which is how the win32 lane behaves on a machine with no interactive desktop.
pub fn measureResize(class_name: [*:0]const u16, axis: Axis) !Measured {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;

    const hwnd = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        start_w,
        start_h,
        null,
        null,
        hinst,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(hwnd);
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, 0, w32.LWA_ALPHA);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);

    // Start from a clean slate, so whatever the resize invalidates is the only
    // thing in the update region afterwards.
    _ = w32.ValidateRect(hwnd, null);
    if (w32.GetUpdateRect(hwnd, null, 0) != 0) return error.SkipZigTest;

    _ = w32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        if (axis == .width) start_w + grow else start_w,
        if (axis == .height) start_h + grow else start_h,
        w32.SWP_NOMOVE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
    );

    var upd: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetUpdateRect(hwnd, &upd, 0);
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return error.SkipZigTest;

    return .{
        .client_w = client.right - client.left,
        .client_h = client.bottom - client.top,
        .update_w = upd.right - upd.left,
        .update_h = upd.bottom - upd.top,
    };
}

/// Assert that BOTH a width change and a height change invalidate the whole
/// client — i.e. that the class carries `CS_HREDRAW | CS_VREDRAW`. This is the
/// one call a class's own test makes.
pub fn expectResizeInvalidatesWholeClient(class_name: [*:0]const u16) !void {
    for ([_]Axis{ .width, .height }) |axis| {
        const m = try measureResize(class_name, axis);
        // Named per axis so a half-styled class says which bit is missing.
        errdefer std.debug.print(
            "class redraw probe: {s} resize invalidated {d}x{d} of a {d}x{d} client\n",
            .{ @tagName(axis), m.update_w, m.update_h, m.client_w, m.client_h },
        );
        try std.testing.expect(m.coversWholeClient());
    }
}

// ---------------------------------------------------------------------------
// Controls. A probe that only ever runs against classes expected to pass is not
// evidence: "the update region is the whole client" also holds when the update
// region is the whole client for an unrelated reason (a window that was never
// validated, a resize that failed outright). These two classes are identical
// except for the style bits, so a run that shows one full and one strip-sized
// is the probe measuring the thing it claims to.

const control_positive = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyRedrawProbePositive");
const control_negative = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyRedrawProbeNegative");

fn registerControl(name: [*:0]const u16, style: u32) !void {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = style,
        .lpfnWndProc = &w32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinst,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = name,
        .hIconSm = null,
    };
    // A second registration in the same test binary fails with
    // ERROR_CLASS_ALREADY_EXISTS, which is not a failure of anything.
    _ = w32.RegisterClassExW(&wc);
}

test "redraw probe: a styled class invalidates the whole client on either axis" {
    try registerControl(control_positive, w32.CS_HREDRAW | w32.CS_VREDRAW);
    try expectResizeInvalidatesWholeClient(control_positive);
}

test "redraw probe: NEGATIVE CONTROL, a style-0 class invalidates only the new strip" {
    try registerControl(control_negative, 0);

    // Widening moves the right edge: the update region is the uncovered
    // column, full height and `grow` wide. Anything wider than that would mean
    // the probe cannot tell a styled class from an unstyled one.
    const wide = try measureResize(control_negative, .width);
    try std.testing.expect(!wide.coversWholeClient());
    try std.testing.expectEqual(grow, wide.update_w);
    try std.testing.expectEqual(start_h, wide.update_h);

    // And heightening moves the bottom edge: a `grow`-tall band, full width.
    const tall = try measureResize(control_negative, .height);
    try std.testing.expect(!tall.coversWholeClient());
    try std.testing.expectEqual(start_w, tall.update_w);
    try std.testing.expectEqual(grow, tall.update_h);
}
