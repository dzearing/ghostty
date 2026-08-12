//! Window-scoped chords that are NOT core binding actions (T746).
//!
//! Almost every chord this app answers is a `input.Binding.Action` looked up in
//! the keybind set, and that lookup is reached from wherever the keyboard focus
//! happens to be. A handful of chords have no action to bind — T22c decision 3
//! settled that "new remote window" is one of them, because the core has no
//! `new_remote_window` action and inventing one is a cross-platform obligation
//! the Mac seat answers with a menu item instead.
//!
//! The cost of that decision was paid in T746: the chord was implemented as an
//! `if` inside `Surface.handleKeyEvent`, which is reached only while a TERMINAL
//! pane owns the focus. Every other focus target in the same window got a
//! different answer to the same keystroke —
//!
//!   * a focused VIEWER pane fell through to the app keybind table, where the
//!     cross-platform `ctrl+shift+n -> new_window` default is still bound, and
//!     opened a plain local window;
//!   * the focused TOP-LEVEL window dropped it entirely (`Window.wndProc` has
//!     no WM_KEYDOWN arm), which is the literal "nothing happens" the user
//!     reported.
//!
//! So the chord lives here, once, and every focus target asks this module what
//! a keystroke means. A chord that is not a binding action still has to have
//! exactly one definition; this is it.
//!
//! Pure — no OS imports — so the table is asserted in the `none` lane.

const std = @import("std");
const input = @import("../../input.zig");

/// A chord the WINDOW answers, whatever inside it holds the keyboard.
pub const WindowChord = enum {
    /// ctrl+shift+n — open the "New Remote Window" machine chooser. Shadows
    /// the cross-platform `ctrl+shift+n -> new_window` default on this
    /// platform; plain ctrl+n still opens a local window.
    new_remote_window,
};

/// Classify a virtual key + modifier state as a window chord, or null.
///
/// Deliberately strict about the modifiers that must be ABSENT: alt+ctrl+shift+n
/// and win+ctrl+shift+n are not this chord, and answering them here would take
/// a keystroke away from the keybind set (where a user may have bound one) for
/// no reason. Side-specific modifier bits are ignored — left and right ctrl are
/// both ctrl.
pub fn classify(vk: u16, mods: input.Mods) ?WindowChord {
    if (vk == 'N' and mods.ctrl and mods.shift and !mods.alt and !mods.super) {
        return .new_remote_window;
    }
    return null;
}

test "classify: ctrl+shift+n is the chooser chord" {
    try std.testing.expectEqual(
        WindowChord.new_remote_window,
        classify('N', .{ .ctrl = true, .shift = true }).?,
    );
}

test "classify: side-specific modifier bits do not change the answer" {
    var mods: input.Mods = .{ .ctrl = true, .shift = true };
    mods.sides.ctrl = .right;
    mods.sides.shift = .right;
    try std.testing.expectEqual(
        WindowChord.new_remote_window,
        classify('N', mods).?,
    );
}

test "classify: a missing modifier is not the chord" {
    try std.testing.expect(classify('N', .{ .ctrl = true }) == null);
    try std.testing.expect(classify('N', .{ .shift = true }) == null);
    try std.testing.expect(classify('N', .{}) == null);
}

test "classify: an EXTRA modifier is not the chord" {
    // Both stay available to the keybind set rather than being swallowed here.
    try std.testing.expect(classify('N', .{ .ctrl = true, .shift = true, .alt = true }) == null);
    try std.testing.expect(classify('N', .{ .ctrl = true, .shift = true, .super = true }) == null);
}

test "classify: another key with the same modifiers is not the chord" {
    for ([_]u16{ 'M', 'B', 'T', 'W', '0' }) |vk| {
        try std.testing.expect(classify(vk, .{ .ctrl = true, .shift = true }) == null);
    }
}
