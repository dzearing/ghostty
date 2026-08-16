//! What a notification-area callback message MEANS (T448) — the decode half
//! of the balloon-click path, kept free of app state so it can be asserted
//! without a window, an HWND or a running shell. The plumbing (showing the
//! balloon, focusing the surface, opening the release page) lives in
//! `App.zig`; nothing here touches one.
//!
//! **The registration is the load-bearing part.** The shell only sends the
//! `NIN_*` balloon notifications — including `NIN_BALLOONUSERCLICK`, the one
//! that makes clicking a notification jump to the pane that raised it — to an
//! icon that has asked for Windows 2000-or-later behavior. Registering an
//! icon with `NIM_ADD` alone leaves it on the shell's default pre-5.0
//! ("Windows 95") behavior, where a balloon click produces nothing and every
//! handler below is dead code. MSDN is unambiguous about the cure and its
//! cadence: *"NIM_SETVERSION must be called every time a notification area
//! icon is added (NIM_ADD) … The version setting is not persisted once a user
//! logs off."* That call was missing until T448, which is why the click-to-
//! focus code shipped, read correctly, and had never once run.
//!
//! **Version 3, not 4.** `NOTIFYICON_VERSION_4` turns the same `NIN_*`
//! messages on but REPACKS the callback: `wparam` becomes the cursor anchor
//! and `lparam` becomes `(event, uID)`. Version 3 enables the notifications
//! while keeping the `wparam = uID` / `lparam = event` packing that
//! `classify` below decodes, and it fits the Windows 2000-sized
//! `NOTIFYICONDATAW` our binding deliberately stops short of (no `guidItem`,
//! no `hBalloonIcon`). We want the messages, not the repacking.

const std = @import("std");
const w32 = @import("win32.zig");

/// Tray-icon ids. Distinct ids mean the desktop and update balloons coexist
/// without one's auto-cleanup removing the other's icon — and they are what
/// tells the two apart in the one callback message both share.
pub const desktop_uid: u32 = 1;
pub const update_uid: u32 = 2;
/// The long-unattached-session ("forgotten session") balloon, T534.
pub const orphan_uid: u32 = 3;

/// What the app should do about a callback message. `null` from `classify`
/// means "nothing" — the overwhelmingly common case, since the shell also
/// reports hovers, the balloon appearing, the balloon timing out, and every
/// mouse event over the icon through the same message.
pub const Action = enum {
    /// A desktop-notification balloon was dismissed BY A CLICK: present the
    /// surface that raised it (macOS/GTK do the same).
    focus_notifying_surface,
    /// An update balloon was dismissed by a click: open the release page.
    open_release_page,
    /// A forgotten-session balloon (T534) was dismissed by a click: open the
    /// machine chooser, where the marked session's Resume and Kill live.
    review_orphan_sessions,
};

/// Decode one `WM_APP_TRAY` (`uCallbackMessage`) delivery under
/// `NOTIFYICON_VERSION`: `wparam` is the icon's uID, the low word of
/// `lparam` is the event.
///
/// Only a *user click* on a balloon acts. A balloon that times out
/// (`NIN_BALLOONTIMEOUT`) or is hidden (`NIN_BALLOONHIDE`) was not chosen by
/// anyone, so it must not yank the user's foreground to some background
/// pane — which is the whole reason this is a switch on the event and not a
/// "the balloon went away" catch-all.
pub fn classify(wparam: usize, lparam: isize) ?Action {
    const event: u32 = @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF);
    if (event != w32.NIN_BALLOONUSERCLICK) return null;
    return switch (wparam) {
        desktop_uid => .focus_notifying_surface,
        update_uid => .open_release_page,
        orphan_uid => .review_orphan_sessions,
        else => null,
    };
}

test "classify: a balloon click routes by icon id" {
    const testing = std.testing;
    const click: isize = w32.NIN_BALLOONUSERCLICK;
    try testing.expectEqual(
        Action.focus_notifying_surface,
        classify(desktop_uid, click).?,
    );
    try testing.expectEqual(
        Action.open_release_page,
        classify(update_uid, click).?,
    );
    try testing.expectEqual(
        Action.review_orphan_sessions,
        classify(orphan_uid, click).?,
    );
}

test "classify: an unknown icon id does nothing" {
    const testing = std.testing;
    try testing.expectEqual(
        @as(?Action, null),
        classify(99, w32.NIN_BALLOONUSERCLICK),
    );
}

test "classify: only a click acts, never a timeout or a hover" {
    const testing = std.testing;
    // The events the shell also delivers on this same message. None of them
    // is a user choosing the notification, so none may steal foreground.
    const quiet = [_]u32{
        w32.NIN_BALLOONSHOW,
        w32.NIN_BALLOONHIDE,
        w32.NIN_BALLOONTIMEOUT,
        0x0200, // WM_MOUSEMOVE over the icon
        0x0202, // WM_LBUTTONUP on the icon
        0x0205, // WM_RBUTTONUP on the icon
    };
    for (quiet) |event| {
        try testing.expectEqual(
            @as(?Action, null),
            classify(desktop_uid, @intCast(event)),
        );
        try testing.expectEqual(
            @as(?Action, null),
            classify(update_uid, @intCast(event)),
        );
        try testing.expectEqual(
            @as(?Action, null),
            classify(orphan_uid, @intCast(event)),
        );
    }
}

test "classify: the event is the LOW word of lparam" {
    const testing = std.testing;
    // Under version 3 the high half of lparam carries nothing we own, so a
    // decode that read the whole word would miss the click. Assert the
    // masking rather than trusting that the shell always zeroes it.
    const dirty: isize = @bitCast(@as(usize, 0x1234_0000) | @as(usize, w32.NIN_BALLOONUSERCLICK));
    try testing.expectEqual(
        Action.focus_notifying_surface,
        classify(desktop_uid, dirty).?,
    );
}
