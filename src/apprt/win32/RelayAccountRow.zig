//! The relay-account row of the win32 machine chooser (T141).
//!
//! Sign-in used to be a CLI verb on Windows (`+relay-login` / `+relay-logout`,
//! T21a). The Mac client never had those — it signs in from the machine
//! chooser's account header — and a one-platform CLI verb is exactly the
//! divergence the user ruled out, so the verbs were deleted and this is where
//! signing in lives now: the chooser's own affordance, mirroring
//! `MachineChooserView.accountRow` on the Mac.
//!
//! This module owns the ASYNC half — the part that must not run on the GUI
//! thread. `relay_signin.signIn` blocks for as long as the user takes to
//! complete a browser consent screen (minutes), and `signOut` does a network
//! revoke; either on the GUI thread would freeze every window. So both run on a
//! detached thread and post `WM_APP_RELAY_ACCOUNT` to the app's message-only
//! window (`ClaudeIntegration`'s pattern), which routes the outcome to whatever
//! chooser is open — or to nobody, if the user closed it while signing in. The
//! sign-in still took effect either way: the account store is the state, not
//! the dialog.
//!
//! `MachineChooser` owns the HWNDs and the redraw; everything here is either
//! pure (unit-tested label/status text) or off-thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const MachineChooser = @import("MachineChooser.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted by the sign-in/sign-out thread to `App.msg_hwnd`. wparam = *Result
/// (ownership transfers to the GUI thread, which frees it in `onResult`).
/// WM_APP+1..+8 are taken (see App.zig / ClaudeIntegration.zig).
pub const WM_APP_RELAY_ACCOUNT: u32 = w32.WM_APP + 9;

pub const Kind = enum { sign_in, sign_out };

/// The outcome of an account operation, allocated on the app allocator by the
/// worker thread and freed by `onResult` on the GUI thread.
pub const Result = struct {
    kind: Kind,
    ok: bool,
    /// The signed-in email after a successful sign-in; empty otherwise.
    email: []const u8,
    /// A short user-facing sentence for the chooser's footer hint.
    message: []const u8,
};

/// Only one account operation at a time. A second click while one is in flight
/// is ignored (the chooser also disables the button, but the guard has to live
/// with the work, not the widget: the chooser can be closed and reopened while
/// a sign-in is still running).
var running: std.atomic.Value(bool) = .init(false);

/// True while a sign-in/sign-out is in flight. The chooser consults this when
/// it opens so a re-opened chooser shows the pending state rather than an
/// enabled button that would start a second flow.
pub fn isRunning() bool {
    return running.load(.acquire);
}

/// Start a browser sign-in on a detached thread. Safe to call from the GUI
/// thread. Returns false when one is already in flight.
pub fn signInAsync(app: *App) bool {
    return startAsync(app, .sign_in);
}

/// Start a sign-out (relay revoke + local store delete) on a detached thread.
/// Safe to call from the GUI thread. Returns false when one is in flight.
pub fn signOutAsync(app: *App) bool {
    return startAsync(app, .sign_out);
}

fn startAsync(app: *App, kind: Kind) bool {
    if (running.swap(true, .acq_rel)) {
        log.info("relay account: an operation is already running; ignoring", .{});
        return false;
    }
    const thread = std.Thread.spawn(.{}, worker, .{ app, kind }) catch |err| {
        running.store(false, .release);
        log.warn("relay account: thread spawn failed err={}", .{err});
        return false;
    };
    thread.detach();
    return true;
}

fn worker(app: *App, kind: Kind) void {
    defer running.store(false, .release);

    // The flow's own scratch memory: page-backed so it never touches the GUI
    // thread's allocator from off-thread.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const alloc = app.core_app.alloc;
    const res = alloc.create(Result) catch return;
    res.* = switch (kind) {
        .sign_in => blk: {
            if (relay_signin.signIn(arena, .{})) |outcome| {
                break :blk .{
                    .kind = .sign_in,
                    .ok = true,
                    .email = alloc.dupe(u8, outcome.email) catch "",
                    .message = "",
                };
            } else |err| {
                log.warn("relay account: sign-in failed err={}", .{err});
                break :blk .{
                    .kind = .sign_in,
                    .ok = false,
                    .email = "",
                    .message = relay_signin.errorMessage(err),
                };
            }
        },
        .sign_out => blk: {
            const was_signed_in = relay_signin.signOut(arena);
            break :blk .{
                .kind = .sign_out,
                .ok = true,
                .email = "",
                .message = if (was_signed_in) "Signed out." else "Already signed out.",
            };
        },
    };

    const hwnd = app.msg_hwnd orelse {
        free(app, res);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_RELAY_ACCOUNT, @intFromPtr(res), 0) == 0) {
        free(app, res);
    }
}

fn free(app: *App, res: *Result) void {
    const alloc = app.core_app.alloc;
    if (res.email.len > 0) alloc.free(res.email);
    alloc.destroy(res);
}

/// GUI thread (App's message-only WndProc): apply an account outcome. Owns
/// `res`. Routes to the open chooser when there is one; a closed chooser is not
/// an error — the store already changed, and the next chooser open reads it.
pub fn onResult(app: *App, res: *Result) void {
    defer free(app, res);
    log.info(
        "relay account: {s} {s}{s}",
        .{
            @tagName(res.kind),
            if (res.ok) "ok" else "failed",
            if (res.email.len > 0) " (signed in)" else "",
        },
    );
    if (openChooser(app)) |chooser| chooser.onAccountResult(res);
}

/// The first open machine chooser across all windows, if any. At most one is
/// ever open per window and the chooser is modal to its owner, so "first" is
/// "the one the user is looking at" in practice.
fn openChooser(app: *App) ?*MachineChooser {
    for (app.windows.items) |win| {
        if (win.machine_chooser) |chooser| return chooser;
    }
    return null;
}

// ---------------------------------------------------------------------
// Pure presentation (unit-tested; the chooser renders these verbatim)
// ---------------------------------------------------------------------

/// The account button's label for a given state. Mac parity: the signed-in
/// state offers "Sign Out", the signed-out state offers Google sign-in.
pub fn buttonLabel(signed_in: bool, busy: bool) []const u8 {
    if (busy) return "Signing in…";
    return if (signed_in) "Sign Out" else "Sign in with Google…";
}

/// The account status line shown next to the button.
pub fn statusText(email: ?[]const u8, busy: bool) []const u8 {
    if (busy) return "Finish signing in in your browser…";
    const e = email orelse return "Not signed in";
    return if (e.len == 0) "Not signed in" else e;
}

const testing = std.testing;

test "buttonLabel: signed-in offers sign out, busy overrides both" {
    try testing.expectEqualStrings("Sign Out", buttonLabel(true, false));
    try testing.expectEqualStrings("Sign in with Google…", buttonLabel(false, false));
    try testing.expectEqualStrings("Signing in…", buttonLabel(true, true));
    try testing.expectEqualStrings("Signing in…", buttonLabel(false, true));
}

test "statusText: email when signed in, never a blank line" {
    try testing.expectEqualStrings("me@example.com", statusText("me@example.com", false));
    try testing.expectEqualStrings("Not signed in", statusText(null, false));
    try testing.expectEqualStrings("Not signed in", statusText("", false));
    try testing.expect(statusText("me@example.com", true).len > 0);
}
