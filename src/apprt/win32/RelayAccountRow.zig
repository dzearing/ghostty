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
//! window (`AgentIntegration`'s pattern), which routes the outcome to whatever
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
/// WM_APP+1..+8 are taken (see App.zig / AgentIntegration.zig).
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
    /// What became of THIS machine's device enrollment (T1421). Meaningful
    /// only on `.sign_out`. `.not_revoked` is the one the chooser must act on:
    /// the user is STILL SIGNED IN, and they have to be told and offered the
    /// way past it rather than left believing a sign-out that did not happen.
    machine: relay_signin.MachineOutcome = .nothing_to_revoke,
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
    return startAsync(app, .sign_in, .revoke);
}

/// Start a sign-out on a detached thread: revoke THIS machine's device
/// enrollment (T1421), revoke the session, delete the local store. Safe to call
/// from the GUI thread. Returns false when one is in flight.
///
/// `mode` is `.revoke` for the button, and `.force` for the "Sign Out Anyway"
/// the chooser offers after a `.not_revoked` outcome.
pub fn signOutAsync(app: *App, mode: relay_signin.SignOutMode) bool {
    return startAsync(app, .sign_out, mode);
}

fn startAsync(app: *App, kind: Kind, mode: relay_signin.SignOutMode) bool {
    if (running.swap(true, .acq_rel)) {
        log.info("relay account: an operation is already running; ignoring", .{});
        return false;
    }
    const thread = std.Thread.spawn(.{}, worker, .{ app, kind, mode }) catch |err| {
        running.store(false, .release);
        log.warn("relay account: thread spawn failed err={}", .{err});
        return false;
    };
    thread.detach();
    return true;
}

fn worker(app: *App, kind: Kind, mode: relay_signin.SignOutMode) void {
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
            const out = relay_signin.signOut(arena, mode);
            break :blk .{
                .kind = .sign_out,
                // A sign-out that left the account signed in is NOT ok, and the
                // chooser must not re-read the account as though it had changed.
                .ok = out.signedOut(),
                .email = "",
                .message = signOutMessage(out),
                .machine = out.machine,
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

/// The account row's sentence when this build carries no Google OAuth client id
/// (T747). It replaces the button rather than sitting beside one: there is
/// nothing to press, and a build with no client id can only answer
/// `Error.NoClientId` to every attempt.
pub const unconfigured_status = "Google sign-in isn't set up in this build";

/// The footer-hint version of the same news, which is where the remedy goes —
/// the row's one line has no room for it, and the strip already wraps. Mac says
/// the same thing in its (larger) row: MachineChooserView.swift:1151.
pub const unconfigured_hint =
    "Google sign-in isn't set up in this build — it needs a Google OAuth client id " ++
    "(-Dgoogle-client-id, or GHOSTTY_GOOGLE_CLIENT_ID in the environment). " ++
    "See docs/design/relay-oidc-setup.md.";

/// The account status line shown next to the button, or "" when the state has
/// no sentence — the caller hides the STATIC on empty.
///
/// Three of the four states say something Mac says too: the email (2.4), the
/// browser-flow sentence beside Mac's "Waiting for browser sign-in…", and the
/// setup pointer an unconfigured build shows instead of a button it cannot
/// honour (T747). The **signed-out** state says nothing, because Mac says
/// nothing there — §2.4 records its signed-out row as the bordered button
/// alone — and on this surface the fact was already stated twice over: the
/// button's own caption is "Sign in with Google…", and the footer hint under
/// the empty list reads "Not signed in — use Sign in with Google above to list
/// your machines." A third copy in the band was the only text in the chooser
/// with no Mac counterpart at all (T316).
pub fn statusText(email: ?[]const u8, busy: bool, configured: bool) []const u8 {
    if (busy) return "Finish signing in in your browser…";
    const signed_out = if (configured) "" else unconfigured_status;
    const e = email orelse return signed_out;
    return if (e.len == 0) signed_out else e;
}

/// The footer sentence for a finished sign-out (T1421). Pure, so every branch
/// is readable in one place and testable in the `none` lane.
///
/// The wording carries the outcome rather than a generic "Signed out.", because
/// the four outcomes are four different facts about the user's machine and only
/// one of them means what "Signed out" used to mean. `.not_revoked` in
/// particular must not read as success: the account is still signed in.
pub fn signOutMessage(res: relay_signin.SignOutResult) []const u8 {
    return switch (res.machine) {
        .revoked => "Signed out — this machine was removed from your account.",
        .not_revoked => "Couldn't remove this machine from your account, so you're still signed in.",
        .left_enrolled => "Signed out. This machine is still connected — Ghoztty will remove it when the relay answers.",
        .nothing_to_revoke => if (res.was_signed_in) "Signed out." else "Already signed out.",
    };
}

/// The confirmation body shown when a sign-out could not revoke this machine.
/// Pure for the same reason as `signOutMessage`, and separate because the
/// dialog states the consequence the footer has no room for.
pub const not_revoked_title = "Couldn't remove this machine from your account";
pub const not_revoked_body =
    "Signing out revokes this machine's registration so it stops being listed, " ++
    "reachable and streamable from your other computers. That couldn't be done " ++
    "just now — the relay didn't answer.\n\n" ++
    "You can sign out anyway: this machine stays connected to that account for " ++
    "now, and Ghoztty keeps trying to remove it until the relay answers — while " ++
    "this app runs, and again every time it starts. You can also remove it from " ++
    "the machine list on another computer.";

/// The monogram letter for the avatar circle (T311): the email's first LETTER,
/// uppercased, mirroring Mac's `initials` (MachineChooserView.swift:942-976).
///
/// Mac takes `first?.uppercased()` outright; this skips leading punctuation and
/// digits first, because an address like `+ghoztty@…` or `1@…` would otherwise
/// put a symbol in the identity mark. When there is no letter at all the mark
/// still draws — with `?`, which reads as "we do not know who this is" rather
/// than as an empty accent disc. Returns null only when there is nothing signed
/// in, which is the state that has no avatar at all.
pub fn monogram(email: ?[]const u8) ?u8 {
    const e = email orelse return null;
    if (e.len == 0) return null;
    for (e) |c| {
        if (std.ascii.isAlphabetic(c)) return std.ascii.toUpper(c);
    }
    return '?';
}

const testing = std.testing;

test "monogram: the first letter, uppercased, and never an empty disc" {
    try testing.expectEqual(@as(?u8, 'M'), monogram("me@example.com"));
    try testing.expectEqual(@as(?u8, 'D'), monogram("dzearing@gmail.com"));
    // Leading punctuation/digits are skipped — a "+" in the mark is not an
    // identity cue, and gmail's plus-addressing makes that a real address.
    try testing.expectEqual(@as(?u8, 'G'), monogram("+ghoztty@example.com"));
    try testing.expectEqual(@as(?u8, 'A'), monogram("1account@example.com"));
    // No letter anywhere: the disc still draws, with a legible placeholder.
    try testing.expectEqual(@as(?u8, '?'), monogram("12345@678.90"));
    // Signed out (or an empty email) has no avatar at all.
    try testing.expectEqual(@as(?u8, null), monogram(null));
    try testing.expectEqual(@as(?u8, null), monogram(""));
}

test "buttonLabel: signed-in offers sign out, busy overrides both" {
    try testing.expectEqualStrings("Sign Out", buttonLabel(true, false));
    try testing.expectEqualStrings("Sign in with Google…", buttonLabel(false, false));
    try testing.expectEqualStrings("Signing in…", buttonLabel(true, true));
    try testing.expectEqualStrings("Signing in…", buttonLabel(false, true));
}

test "statusText: email when signed in, and nothing at all when signed out (T316)" {
    try testing.expectEqualStrings("me@example.com", statusText("me@example.com", false, true));
    // Signed out is Mac's composition: the bordered button alone. The state is
    // named by the button's caption and by the footer hint, not a third time
    // here.
    try testing.expectEqualStrings("", statusText(null, false, true));
    try testing.expectEqualStrings("", statusText("", false, true));
    // The browser-flow sentence stays — Mac shows one too (2.4).
    try testing.expect(statusText("me@example.com", true, true).len > 0);
    try testing.expect(statusText(null, true, true).len > 0);
}

test "statusText: an unconfigured build says so where signed-out says nothing (T747)" {
    // A drawn button IS the invitation, so the ordinary signed-out row needs no
    // words (T316); with no client id there is no button, and a row that said
    // nothing at all would be an empty band with no way out of it.
    try testing.expectEqualStrings(unconfigured_status, statusText(null, false, false));
    try testing.expectEqualStrings(unconfigured_status, statusText("", false, false));

    // A stored account still shows its email — Sign Out needs no client id.
    try testing.expectEqualStrings("me@example.com", statusText("me@example.com", false, false));
    // And a sign-in in flight still describes itself.
    try testing.expectEqualStrings(statusText(null, true, true), statusText(null, true, false));

    // The hint carries the remedy the one-line row has no room for, and names
    // both ways to supply an id plus the doc.
    try testing.expect(std.mem.indexOf(u8, unconfigured_hint, "relay-oidc-setup.md") != null);
    try testing.expect(std.mem.indexOf(u8, unconfigured_hint, "GHOSTTY_GOOGLE_CLIENT_ID") != null);
    try testing.expect(unconfigured_hint.len > unconfigured_status.len);
}

test "signOutMessage: the four outcomes say four different things (T1421)" {
    // `.not_revoked` is the one that must NOT read as success — the account is
    // still signed in, and a footer saying "Signed out." would be the same lie
    // the whole revocation path exists to stop telling.
    const not_revoked = signOutMessage(.{ .was_signed_in = true, .machine = .not_revoked });
    try testing.expect(std.mem.indexOf(u8, not_revoked, "still signed in") != null);
    try testing.expect(std.mem.indexOf(u8, not_revoked, "Signed out") == null);

    const revoked = signOutMessage(.{ .was_signed_in = true, .machine = .revoked });
    try testing.expect(std.mem.indexOf(u8, revoked, "removed from your account") != null);

    // Signing out anyway must still admit what is left behind — and, since
    // T1424, say that it is being finished rather than abandoned.
    const left = signOutMessage(.{ .was_signed_in = true, .machine = .left_enrolled });
    try testing.expect(std.mem.indexOf(u8, left, "still connected") != null);
    try testing.expect(std.mem.indexOf(u8, left, "will remove it") != null);

    // The unenrolled machine keeps the old wording, both ways round.
    try testing.expectEqualStrings(
        "Signed out.",
        signOutMessage(.{ .was_signed_in = true, .machine = .nothing_to_revoke }),
    );
    try testing.expectEqualStrings(
        "Already signed out.",
        signOutMessage(.{ .was_signed_in = false, .machine = .nothing_to_revoke }),
    );

    // All four are distinct: a footer that cannot tell two outcomes apart is a
    // footer the user cannot act on.
    const all = [_][]const u8{ not_revoked, revoked, left, signOutMessage(.{ .was_signed_in = true, .machine = .nothing_to_revoke }) };
    for (all, 0..) |a, i| {
        try testing.expect(a.len > 0);
        for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "not_revoked_body: names the consequence and the remedy (T1421)" {
    // The dialog is the only place the user learns that signing out anyway
    // leaves the machine reachable, and where to go to finish the job.
    try testing.expect(std.mem.indexOf(u8, not_revoked_body, "stays connected") != null);
    try testing.expect(std.mem.indexOf(u8, not_revoked_body, "another computer") != null);
    // T1424: the dialog no longer asks the user to remember a chore. It says
    // the app finishes the job itself, because it now does.
    try testing.expect(std.mem.indexOf(u8, not_revoked_body, "keeps trying") != null);
    try testing.expect(not_revoked_title.len > 0);
}

test "SignOutResult.signedOut: only a failed revocation keeps the account" {
    const R = relay_signin.SignOutResult;
    try testing.expect((R{ .was_signed_in = true, .machine = .revoked }).signedOut());
    try testing.expect((R{ .was_signed_in = true, .machine = .left_enrolled }).signedOut());
    try testing.expect((R{ .was_signed_in = true, .machine = .nothing_to_revoke }).signedOut());
    try testing.expect(!(R{ .was_signed_in = true, .machine = .not_revoked }).signedOut());
}
