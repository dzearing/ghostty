//! Every `SetTimer` id armed on `App.msg_hwnd`, in ONE place (T608).
//!
//! `msg_hwnd` is the app's single hidden message-only window, so every timer
//! on it shares one id space: `SetTimer` with an (hwnd, id) pair that already
//! exists REPLACES the existing timer, and `KillTimer` kills whichever one is
//! there. Two features that pick the same number therefore cancel each other,
//! silently and only when both happen to be live at once.
//!
//! That is exactly what happened: the quick-terminal slide animation and the
//! update balloon's icon-cleanup timer were both id 3, declared in two
//! different files with nothing comparing them. An update notification arriving
//! mid-slide re-armed the id at 10s and stalled the animation, and the
//! cleanup's own tick was then routed to `onAnimationTick`, so the tray icon
//! outlived its balloon.
//!
//! The ids used to be declared across three files. They live here now, and the
//! `comptime` block below fails the BUILD on a duplicate — so the next feature
//! that needs a timer cannot reintroduce the collision by picking a number
//! somebody else already took.
//!
//! Ids on other windows are a different space and do not belong here:
//! `ActivityMonitor` runs its sample timer on its own hwnd, so its id 1 is not
//! a collision with `quit` below.

/// Quit-after-last-window-closed delay (`App.quit_timer_state`).
pub const quit: usize = 1;

/// Icon cleanup for the desktop-notification balloon.
pub const notif_desktop: usize = 2;

/// Quick-terminal slide animation tick (`QuickTerminal.onAnimationTick`).
pub const quick_terminal_anim: usize = 3;

/// Debounced session-layout manifest write (T89f).
pub const layout_sync: usize = 4;

/// Local-agent link settle watch (T145).
pub const agent_watch: usize = 5;

/// Cross-machine reconnect ladder (T366).
pub const remote_reconnect: usize = 6;

/// In-place agent-recovery retry (T723).
pub const agent_retry: usize = 7;

/// Icon cleanup for the orphaned-session balloon (T534).
pub const notif_orphan: usize = 8;

/// Periodic long-unattached session check (T534).
pub const orphan_check: usize = 9;

/// Periodic session-layout refresh (T922).
pub const layout_refresh: usize = 10;

/// Deferred launch restore (T976).
pub const restore_retry: usize = 11;

/// Periodic "am I still the build that is on disk?" check (T1205).
pub const stale_build_check: usize = 12;

/// Icon cleanup for the stale-build balloon (T1205).
pub const notif_stale: usize = 13;

/// Periodic release-channel re-check (T1171).
pub const update_recheck: usize = 14;

/// Icon cleanup for the update-available balloon. Was id 3 until T608, where it
/// collided with `quick_terminal_anim` above.
pub const notif_update: usize = 15;

// Fail the build if two ids above are equal. Every `pub const … : usize` in
// this file is a timer id and is compared against every other one, so a new
// entry is covered by adding it — there is no second list to keep in step.
comptime {
    const decls = @typeInfo(@This()).@"struct".decls;
    for (decls, 0..) |a, i| {
        const av = @field(@This(), a.name);
        if (@TypeOf(av) != usize) continue;
        for (decls[i + 1 ..]) |b| {
            const bv = @field(@This(), b.name);
            if (@TypeOf(bv) != usize) continue;
            if (av == bv) @compileError(
                "duplicate App.msg_hwnd timer id: " ++ a.name ++ " and " ++ b.name,
            );
        }
    }
}

test "msg_hwnd timer ids are unique" {
    // The comptime block above is the real gate; this is the readable failure
    // for anyone running the lane rather than the build, and it also proves the
    // registry is reachable from the test lane at all.
    const std = @import("std");
    const decls = @typeInfo(@This()).@"struct".decls;
    var seen: [64]bool = @splat(false);
    inline for (decls) |d| {
        const v = @field(@This(), d.name);
        if (@TypeOf(v) == usize) {
            try std.testing.expect(v < seen.len);
            try std.testing.expect(!seen[v]);
            seen[v] = true;
        }
    }
}
