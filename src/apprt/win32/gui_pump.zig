//! T188: a way for a long, blocking GUI-thread operation to keep answering IPC.
//!
//! THE DEFECT THIS EXISTS FOR. An IPC request is never served by the listener
//! thread that accepted it: `IpcServer.listen` posts `WM_APP_IPC` to the app's
//! message-only window and then BLOCKS on the request's `done` event until the
//! GUI thread runs the handler. So a request is answered exactly when the GUI
//! thread pumps — never merely because the app is "running". Session restore
//! (`App.restoreSessionLayout`) is a straight-line GUI-thread call that dials
//! the local agent, probes its roster and rebuilds every window, and it pumps
//! nothing while it does: measured at 451 ms for a healthy 5-pane restore and
//! 10.7 s against an agent suspended across the relaunch. Every `ghoztty +…`
//! issued in that window sits and waits, which reads to a caller — and to the
//! upgrade script that reported it — as "no running Ghoztty instance".
//!
//! Note that DEFERRING the restore into the message loop (the T48 pattern) does
//! NOT fix this: it changes when the restore starts, not whether the GUI thread
//! pumps while it runs. A handler that blocks the loop for 10 s is the same
//! blackout as a call that blocks before the loop.
//!
//! WHAT THIS IS. A single process-wide hook the app installs once, and that a
//! blocking site calls at the points where it is already waiting anyway (a poll
//! sleep, the boundary between two restored windows). The app's implementation
//! drains ONLY `WM_APP_IPC` — the same targeted `PeekMessageW` drain
//! `IpcServer.deinit` already uses — so this never re-enters paint, focus or
//! input handling. That restraint is the whole safety argument: the T48
//! deadlock came from running a nested general message pump inside a WndProc
//! stack, and this deliberately is not one.
//!
//! THREAD RULE. `pump()` is a no-op unless it is called on the thread that
//! installed the hook. Blocking helpers get called from worker threads too
//! (`LocalAgent.dialProbe` is explicitly worker-safe), and a worker that
//! serviced a GUI-thread-only IPC handler would be a data race, so the check
//! is here rather than at each call site where it could be forgotten.

const std = @import("std");

/// The installed hook, or null when no app has installed one (unit tests, and
/// any build that never reaches `App.init`).
var hook: ?*const fn (?*anyopaque) void = null;

/// Opaque context handed back to the hook — the `*App` in practice.
var hook_ctx: ?*anyopaque = null;

/// The thread that installed the hook. Only it may run the hook.
var hook_thread: std.Thread.Id = 0;

/// Install the pump hook for this process. Call once, from the GUI thread,
/// after the message-only window exists.
pub fn install(ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
    hook_ctx = ctx;
    hook_thread = std.Thread.getCurrentId();
    hook = f;
}

/// Remove the hook. Call before the message-only window is destroyed, so a
/// late `pump()` cannot reach a dead HWND.
pub fn uninstall() void {
    hook = null;
    hook_ctx = null;
    hook_thread = 0;
}

/// Service anything the hook can service right now. Safe to call from anywhere:
/// with no hook installed, or from any thread but the installing one, it does
/// nothing at all.
pub fn pump() void {
    const f = hook orelse return;
    if (std.Thread.getCurrentId() != hook_thread) return;
    f(hook_ctx);
}

/// Whether a hook is installed AND this is the thread that may run it. Call
/// sites use it to skip work they would only do in order to pump.
pub fn active() bool {
    if (hook == null) return false;
    return std.Thread.getCurrentId() == hook_thread;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

var test_calls: usize = 0;

fn testHook(ctx: ?*anyopaque) void {
    test_calls += 1;
    if (ctx) |p| {
        const counter: *usize = @ptrCast(@alignCast(p));
        counter.* += 1;
    }
}

test "pump is a no-op with no hook installed" {
    uninstall();
    test_calls = 0;
    pump();
    try testing.expectEqual(@as(usize, 0), test_calls);
    try testing.expect(!active());
}

test "pump runs the hook with its context on the installing thread" {
    var counter: usize = 0;
    test_calls = 0;
    install(&counter, testHook);
    defer uninstall();

    try testing.expect(active());
    pump();
    pump();
    try testing.expectEqual(@as(usize, 2), test_calls);
    try testing.expectEqual(@as(usize, 2), counter);
}

test "uninstall stops the hook from running again" {
    var counter: usize = 0;
    test_calls = 0;
    install(&counter, testHook);
    pump();
    uninstall();
    pump();
    try testing.expectEqual(@as(usize, 1), test_calls);
    try testing.expect(!active());
}

test "pump from another thread does nothing" {
    var counter: usize = 0;
    test_calls = 0;
    install(&counter, testHook);
    defer uninstall();

    const Worker = struct {
        fn run(seen_active: *bool) void {
            seen_active.* = active();
            pump();
        }
    };
    var seen_active = true;
    var t = try std.Thread.spawn(.{}, Worker.run, .{&seen_active});
    t.join();

    // The worker neither reported itself active nor ran the hook.
    try testing.expect(!seen_active);
    try testing.expectEqual(@as(usize, 0), test_calls);
    try testing.expectEqual(@as(usize, 0), counter);

    // ...and the installing thread still works.
    pump();
    try testing.expectEqual(@as(usize, 1), test_calls);
}
