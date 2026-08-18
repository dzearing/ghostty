//! Where a viewer pane's `window.open()` / `target="_blank"` request ends up
//! (T163), and how big the window it asked for should be.
//!
//! Pure: no OS imports, so it is checkable in the `none` lane next to the other
//! viewer logic modules. The COM handshake that acts on the answer lives in
//! `ViewerPane.zig`; this file only decides.
//!
//! ## The rule is Mac's, not "adopt everything"
//!
//! The obvious reading of "adopt popups as ghoztty windows" is that every
//! popup becomes one. That is not what ships on macOS, and copying it would be
//! a regression rather than parity: `ViewerView.popupDestination` hands an
//! `http(s)` popup to the **system default browser** and cancels it, because
//! Ghoztty's web view keeps its own cookie store with no relationship to
//! Safari/Chrome/Edge — a site opened here renders logged out and an OAuth
//! popup never completes. Three things keep a popup in Ghoztty instead:
//!
//!   1. a **Cmd-held** click (**Ctrl** here), the deliberate escape hatch — a
//!      CLICK, so it takes a user gesture as well as the key (see `ctrlEscape`);
//!   2. a popup with **no URL** — a bare `window.open()`, where the script goes
//!      on to write into the window it was handed, so there is nothing to give
//!      a browser;
//!   3. a **non-web scheme**, which `ShellExecuteW` would resolve to some
//!      arbitrary registered handler.
//!
//! Cases 2 and 3 are exactly the popups that CANNOT be handed off, which is why
//! v1's unconditional `ShellExecuteW` was not merely "less nice": a bare
//! `window.open()` reached the shell as the literal string `about:blank`, and a
//! `ghoztty-viewer:`-style scheme would have reached whatever claims it.
//!
//! ## `about:blank` is win32's spelling of Mac's `nil` URL
//!
//! `WKUIDelegate` reports `navigationAction.request.url == nil` for a bare
//! `window.open()`; WebView2's `NewWindowRequestedEventArgs.Uri` reports the
//! string `about:blank` for the same call. They are the same event, so they get
//! the same answer here — that mapping is the one place the two platforms'
//! wording differs and it is deliberate, not an accident of parsing.

const std = @import("std");

/// The `ghoztty://` grammar (T695) — `handles` only.
const url_scheme = @import("../ipc/url_scheme.zig");

/// Where a popup goes. Mac's `ViewerView.PopupDestination`, minus the payload:
/// the URI is already in the caller's hand there.
pub const Destination = enum {
    /// Hand the URL to the system default browser and cancel the popup.
    default_browser,
    /// Open it as its own Ghoztty viewer window, adopting the web view so the
    /// opener↔popup relationship (and therefore `window.close()`) survives.
    ghoztty_window,
    /// A `ghoztty://` command: run it in process and cancel the popup (T695).
    ghoztty_command,
};

/// Decide where a popup goes. `uri` is what the runtime reported (null when it
/// could not be read at all, which is treated as "no URL"); `ctrl_held` is the
/// Ctrl-held escape hatch, and `user_initiated` is whether a user gesture asked
/// for the popup at all (see `ctrlEscape`).
pub fn destination(uri: ?[]const u8, ctrl_held: bool, user_initiated: bool) Destination {
    // A `ghoztty://` link is a command, not a destination, and it outranks the
    // Ctrl modifier: there is nothing to put in a window. Without this it fell
    // through the "non-web scheme ⇒ keep it here" rule below and a
    // `target="_blank"` focus link OPENED A VIEWER WINDOW pointed at the
    // command — window creation from the one scheme that must never create
    // anything (T695).
    if (uri) |u| if (url_scheme.handles(u)) return .ghoztty_command;
    if (ctrlEscape(ctrl_held, user_initiated)) return .ghoztty_window;
    const u = uri orelse return .ghoztty_window;
    if (u.len == 0) return .ghoztty_window;
    if (isBlank(u)) return .ghoztty_window;
    if (!isWebScheme(u)) return .ghoztty_window;
    return .default_browser;
}

/// Whether the Ctrl escape hatch applies to this popup.
///
/// The hatch is Mac's **Cmd-held click**, and the word doing the work is
/// *click*: `WKUIDelegate` reads the modifier off the `navigationAction` that
/// asked for the window, so a script calling `window.open()` in the background
/// sees no modifiers at all, whatever the user's hands are doing. Win32 has no
/// modifier on the event, so `ViewerPane` reads Ctrl off `GetAsyncKeyState` —
/// which answers for the WHOLE DESKTOP, including a Ctrl held for something
/// else entirely in another app. Pairing it with `IsUserInitiated` puts the
/// modifier back on the gesture, which is both the Mac behavior and the only
/// version that is not decided by unrelated typing (T860).
pub fn ctrlEscape(ctrl_held: bool, user_initiated: bool) bool {
    return ctrl_held and user_initiated;
}

/// The bare-`window.open()` location, in WebView2's spelling. Compared
/// case-insensitively and with any query/fragment ignored, because
/// `about:blank#x` is still the blank page a script writes into.
fn isBlank(uri: []const u8) bool {
    const blank = "about:blank";
    if (uri.len < blank.len) return false;
    if (!std.ascii.eqlIgnoreCase(uri[0..blank.len], blank)) return false;
    if (uri.len == blank.len) return true;
    return switch (uri[blank.len]) {
        '?', '#' => true,
        else => false,
    };
}

/// Whether `uri` carries an `http`/`https` scheme — the only two the default
/// browser is ever handed. Anything else (a `mailto:`, a custom app scheme, a
/// relative string the runtime failed to resolve) stays in Ghoztty.
fn isWebScheme(uri: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    const scheme = uri[0..colon];
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https");
}

/// A window size in PHYSICAL pixels.
pub const Size = struct { w: i32, h: i32 };

/// Smallest window a popup may ask for. A sign-in popup that asks for 20×20 is
/// asking for something no user can use; Mac gets the same floor for free from
/// AppKit's own minimum content size.
pub const min_dim: i32 = 240;

/// Largest. Not a screen bound — clamping to the monitor is the window
/// creation's job, and this module knows nothing about monitors — just a bound
/// that keeps a hostile or broken `window.open(…, "width=1e9")` from
/// overflowing the arithmetic below.
pub const max_dim: i32 = 20_000;

/// The size the opener asked for, in physical pixels, or null when it asked for
/// none.
///
/// `has_size` is `ICoreWebView2WindowFeatures.HasSize`; `width`/`height` are its
/// CSS-pixel values, which is why they are scaled — Mac's `WKWindowFeatures`
/// hands back points and AppKit scales them on the way to the screen, and the
/// win32 equivalent has to do that multiplication by hand.
///
/// Mac's guard is `width > 0, height > 0`; this adds the clamp because a
/// physical-pixel `i32` is what a `CreateWindowExW` call actually receives.
pub fn requestedSize(has_size: bool, width: u32, height: u32, scale: f32) ?Size {
    if (!has_size) return null;
    if (width == 0 or height == 0) return null;
    if (!(scale > 0)) return null;
    return .{
        .w = scaleDim(width, scale),
        .h = scaleDim(height, scale),
    };
}

fn scaleDim(css: u32, scale: f32) i32 {
    const capped: f64 = @min(@as(f64, @floatFromInt(css)), @as(f64, max_dim));
    const scaled = capped * @as(f64, scale);
    const rounded: i32 = @intFromFloat(@round(@min(scaled, @as(f64, max_dim))));
    return @max(min_dim, @min(max_dim, rounded));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "an http(s) popup leaves for the default browser" {
    try testing.expectEqual(Destination.default_browser, destination("http://example.com/", false, false));
    try testing.expectEqual(Destination.default_browser, destination("https://example.com/x?y=1", false, false));
    // Scheme comparison is case-insensitive, the way every URL parser's is.
    try testing.expectEqual(Destination.default_browser, destination("HTTPS://example.com/", false, false));
}

test "Ctrl on a user's own click keeps any popup in ghoztty" {
    try testing.expectEqual(Destination.ghoztty_window, destination("https://example.com/", true, true));
    try testing.expectEqual(Destination.ghoztty_window, destination("about:blank", true, true));
    try testing.expectEqual(Destination.ghoztty_window, destination(null, true, true));
}

test "a Ctrl the user is holding for something else does not reroute a scripted popup" {
    // The T860 flake, as a rule: win32 reads Ctrl off `GetAsyncKeyState`, which
    // is the whole desktop's keyboard, so a page's own `window.open()` — no
    // click, no keypress, the user is in another app entirely — was being sent
    // to a Ghoztty window whenever a Ctrl happened to be down at that instant.
    // Mac cannot do that: its modifier comes off the navigation action.
    try testing.expectEqual(
        Destination.default_browser,
        destination("https://example.com/", true, false),
    );
    // The rest of the routing is unchanged by the gesture — a popup the browser
    // cannot be handed still stays here, gesture or no gesture.
    try testing.expectEqual(Destination.ghoztty_window, destination("about:blank", true, false));
    try testing.expectEqual(Destination.ghoztty_window, destination(null, true, false));
    try testing.expectEqual(Destination.ghoztty_window, destination("mailto:a@b.c", true, false));
    // And a gesture without Ctrl is not the escape hatch either: an ordinary
    // ctrl-less click on `target="_blank"` still leaves for the browser.
    try testing.expectEqual(
        Destination.default_browser,
        destination("https://example.com/", false, true),
    );
    // The predicate itself, since both halves are load-bearing.
    try testing.expect(ctrlEscape(true, true));
    try testing.expect(!ctrlEscape(true, false));
    try testing.expect(!ctrlEscape(false, true));
    try testing.expect(!ctrlEscape(false, false));
}

test "a popup the browser cannot be handed stays in ghoztty" {
    // A bare `window.open()`: Mac sees a nil URL, WebView2 says `about:blank`.
    try testing.expectEqual(Destination.ghoztty_window, destination("about:blank", false, false));
    try testing.expectEqual(Destination.ghoztty_window, destination("ABOUT:BLANK", false, false));
    try testing.expectEqual(Destination.ghoztty_window, destination("about:blank#frag", false, false));
    // Nothing readable at all.
    try testing.expectEqual(Destination.ghoztty_window, destination(null, false, false));
    try testing.expectEqual(Destination.ghoztty_window, destination("", false, false));
    // Non-web schemes: ShellExecuteW would hand these to whatever is registered.
    try testing.expectEqual(Destination.ghoztty_window, destination("mailto:a@b.c", false, false));
    try testing.expectEqual(Destination.ghoztty_window, destination("file:///C:/x.txt", false, false));
    try testing.expectEqual(Destination.ghoztty_window, destination("ghoztty-viewer://page/", false, false));
    // No scheme at all is not a web URL either.
    try testing.expectEqual(Destination.ghoztty_window, destination("example.com", false, false));
}

test "a ghoztty:// popup is a command, not a window — under every modifier" {
    // The bug this case exists for: it used to fall through "non-web scheme ⇒
    // keep it in ghoztty" and open a viewer window pointed at the command
    // string, which is window creation from the one scheme that creates
    // nothing.
    try testing.expectEqual(
        Destination.ghoztty_command,
        destination("ghoztty://focus/dev", false, false),
    );
    try testing.expectEqual(
        Destination.ghoztty_command,
        destination("ghoztty-debug://focus/dev", false, false),
    );
    // Ctrl is the escape hatch for CONTENT; a command has none to escape to.
    try testing.expectEqual(
        Destination.ghoztty_command,
        destination("ghoztty://focus/dev", true, true),
    );
    // A malformed one is still ours — it must not leak to the browser.
    try testing.expectEqual(
        Destination.ghoztty_command,
        destination("ghoztty://open/dev", false, false),
    );
    // ...and a lookalike scheme is not.
    try testing.expectEqual(
        Destination.ghoztty_window,
        destination("ghoztty-viewer://page/", false, false),
    );
}

test "about:blank's prefix is not enough on its own" {
    // `about:blankety` is a different location, and a naive `startsWith` would
    // call it the blank page.
    try testing.expectEqual(Destination.ghoztty_window, destination("about:blankety", false, false));
    // …though only because it is not http(s) either. The point of the case is
    // that `isBlank` does not claim it.
    try testing.expect(!isBlank("about:blankety"));
    try testing.expect(isBlank("about:blank"));
    try testing.expect(isBlank("about:blank?x"));
}

test "the requested size is honored, scaled and clamped" {
    // Nothing asked for.
    try testing.expectEqual(@as(?Size, null), requestedSize(false, 600, 400, 1.0));
    try testing.expectEqual(@as(?Size, null), requestedSize(true, 0, 400, 1.0));
    try testing.expectEqual(@as(?Size, null), requestedSize(true, 600, 0, 1.0));

    // The ordinary sign-in popup, at every scale the chrome modules assert at.
    try testing.expectEqual(Size{ .w = 600, .h = 700 }, requestedSize(true, 600, 700, 1.0).?);
    try testing.expectEqual(Size{ .w = 750, .h = 875 }, requestedSize(true, 600, 700, 1.25).?);
    try testing.expectEqual(Size{ .w = 900, .h = 1050 }, requestedSize(true, 600, 700, 1.5).?);
    try testing.expectEqual(Size{ .w = 1200, .h = 1400 }, requestedSize(true, 600, 700, 2.0).?);

    // A window nobody could use is floored, not honored.
    try testing.expectEqual(Size{ .w = min_dim, .h = min_dim }, requestedSize(true, 20, 20, 1.0).?);
    // And a nonsense one is capped rather than overflowing the i32 that
    // CreateWindowExW is going to receive.
    const huge = requestedSize(true, 4_000_000_000, 4_000_000_000, 2.0).?;
    try testing.expectEqual(max_dim, huge.w);
    try testing.expectEqual(max_dim, huge.h);
}

test "a nonsense scale is treated as no request at all" {
    try testing.expectEqual(@as(?Size, null), requestedSize(true, 600, 400, 0));
    try testing.expectEqual(@as(?Size, null), requestedSize(true, 600, 400, -1));
}
