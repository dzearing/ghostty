//! When F10 belongs to the MENU and when it belongs to the user (T575).
//!
//! F10 opens the menu bar on Windows, and a terminal that ignored that would be
//! the odd application out — so `Surface.trackMenuActivation` claims the key and
//! returns before `keyCallback` ever sees it. The cost of claiming it
//! unconditionally was that a `keybind = f10=…` (or a sequence, or a key table
//! whose trigger is F10) silently never fired: the user stated an intent, the
//! config accepted it, and the key did something else. Worse, the menu it opened
//! then owned every following keystroke, so the keyboard read as stuck.
//!
//! The precedent for the shape of the fix is already in this frontend — the
//! viewer's ctrl+r / ctrl+d shadow their global bindings only while a viewer
//! pane holds focus (T161). Let the config win where the user has stated an
//! intent, keep the platform default everywhere else.
//!
//! Only F10 is decided here. A lone Alt press opens the same menu and is
//! deliberately NOT conditional on anything: Alt is a modifier, alt-menu access
//! is the one keyboard route to the menu that does not depend on a binding
//! existing, and making it conditional would take that route away from every
//! user who has never bound a key.
//!
//! Pure — no OS imports — so the rule is asserted in the `none` lane rather
//! than only by driving a real menu on the box. Registered for that in
//! `src/apprt.zig`'s test block: a module reached only through a lazily
//! analyzed function body is never analyzed by a test build, so its tests
//! silently do not exist until they are imported there.

const std = @import("std");
const input = @import("../../input.zig");

/// Everything the F10 rule looks at, gathered by the caller.
pub const F10Context = struct {
    /// Modifier state at the moment of the press. Any modifier at all means
    /// this is not the bare F10 the menu answers.
    mods: input.Mods = .{},

    /// Autorepeat (lparam bit 30). A held F10 is not a menu request.
    repeat: bool = false,

    /// The terminal is showing the alternate screen, i.e. a full-screen TUI is
    /// running. `htop`, `mc` and friends bind F10 and all run there; a shell
    /// prompt does not. A measurable discriminator rather than a guess about
    /// what the child wants.
    on_alternate_screen: bool = false,

    /// The live keybind state has an entry for this event — the root set, an
    /// active key table, or the in-flight half of a sequence. When the user has
    /// bound F10, the binding wins and the menu stays shut.
    has_binding: bool = false,
};

/// Does this F10 press open the menu bar?
///
/// False means "not ours" — the key is passed on to the terminal and the
/// keybind machinery untouched.
pub fn f10OpensMenu(ctx: F10Context) bool {
    if (ctx.repeat) return false;
    if (ctx.mods.ctrl or ctx.mods.shift or ctx.mods.alt or ctx.mods.super) return false;
    if (ctx.on_alternate_screen) return false;
    if (ctx.has_binding) return false;
    return true;
}

test "bare F10 with no binding opens the menu" {
    try std.testing.expect(f10OpensMenu(.{}));
}

test "a user binding on F10 wins over the menu (T575)" {
    try std.testing.expect(!f10OpensMenu(.{ .has_binding = true }));
}

test "a binding does not resurrect F10 in the cases the menu already declined" {
    // The binding check is one more reason to decline, never a reason to
    // claim: an alternate-screen F10 still belongs to the TUI even when a
    // binding exists, and the modifier and autorepeat narrowings are unmoved.
    try std.testing.expect(!f10OpensMenu(.{ .on_alternate_screen = true, .has_binding = true }));
    try std.testing.expect(!f10OpensMenu(.{ .repeat = true, .has_binding = true }));
    try std.testing.expect(!f10OpensMenu(.{ .mods = .{ .ctrl = true }, .has_binding = true }));
}

test "every modifier disqualifies the press" {
    try std.testing.expect(!f10OpensMenu(.{ .mods = .{ .ctrl = true } }));
    try std.testing.expect(!f10OpensMenu(.{ .mods = .{ .shift = true } }));
    try std.testing.expect(!f10OpensMenu(.{ .mods = .{ .alt = true } }));
    try std.testing.expect(!f10OpensMenu(.{ .mods = .{ .super = true } }));
}

test "side-specific modifier bits alone are not modifiers" {
    // `sides` only says WHICH ctrl is down; the flag says whether one is.
    var mods: input.Mods = .{};
    mods.sides.ctrl = .right;
    try std.testing.expect(f10OpensMenu(.{ .mods = mods }));
}

test "autorepeat and the alternate screen still decline on their own" {
    try std.testing.expect(!f10OpensMenu(.{ .repeat = true }));
    try std.testing.expect(!f10OpensMenu(.{ .on_alternate_screen = true }));
}
