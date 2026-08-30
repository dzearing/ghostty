//! Startup failures that the user can SEE (T1177).
//!
//! `ghoztty.exe` is a GUI-subsystem binary: it has no console, so anything
//! written to stderr — including the error return trace Zig prints when `main`
//! returns an error — goes nowhere at all. Before this module, a failure in
//! `App.create`, `apprt.App.init` or `apprt.App.run` therefore produced the
//! worst possible outcome: the process exited, no window ever appeared, and
//! nothing on screen said why. A user who had just installed Ghoztty (or whose
//! install was half-laid-down, T1175) saw a shortcut that did nothing, and the
//! only feedback that ever arrived was some unrelated probe timing out minutes
//! later.
//!
//! The rule this module enforces: **a startup that cannot produce a window
//! produces a DIALOG instead.** Never a log line alone, never a silent exit.
//!
//! Two severities, because "Ghoztty cannot run" and "Ghoztty is running with
//! something missing" are different things to say to someone:
//!
//!   - `reportFatal` — nothing usable came up. Named cause, plain-language
//!     remedy, then the process exits. The caller is `main_ghostty.zig`, which
//!     owns every error path out of startup.
//!   - `reportDegraded` — a window IS up, but a startup precondition failed in
//!     a way the user needs to know about (today: the session agent is missing
//!     from the installation). Non-fatal by design: a terminal that works
//!     without session persistence is far better than no terminal, so this
//!     tells the truth and gets out of the way.
//!
//! The message text is composed by pure functions (`describe`, `remedyFor`)
//! that are unit-tested below, because the dialog itself cannot be asserted on
//! from a test lane and an untested message is how "loud" quietly becomes
//! "loud and wrong".

const std = @import("std");
const builtin = @import("builtin");

const ConfirmDialog = @import("ConfirmDialog.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_startup);

/// Where the log the dialog points at lives. Kept in one place so the message
/// and `main_ghostty.zig`'s sink cannot drift apart.
pub const log_path = "%LOCALAPPDATA%\\ghoztty\\ghoztty.log";

/// Largest message we compose. A stage sentence, an error name and a remedy
/// paragraph; anything longer would be an unreadable dialog anyway.
pub const max_message = 1024;

/// Plain-language guidance for `err`, written for someone who will never read
/// a stack trace. Matched on the error NAME rather than an error set, because
/// the errors reaching here come from three unrelated sets (core app, apprt,
/// std) and enumerating them would make this file a place that has to be
/// edited every time an unrelated function grows a new error.
pub fn remedyFor(err: anyerror) []const u8 {
    const name = @errorName(err);

    if (std.mem.eql(u8, name, "OutOfMemory"))
        return "The system is out of memory. Close some applications and start Ghoztty again.";

    if (std.mem.eql(u8, name, "NoStartupWindow"))
        return "Ghoztty started but could not put a terminal window on screen. " ++
            "Restart it; if that does not help, reinstall Ghoztty.";

    if (std.mem.eql(u8, name, "AgentBinaryNotFound") or
        std.mem.eql(u8, name, "FileNotFound") or
        std.mem.eql(u8, name, "NotDir"))
        return "Part of the installation is missing. Reinstall Ghoztty to restore it.";

    if (std.mem.eql(u8, name, "AccessDenied") or
        std.mem.eql(u8, name, "PermissionDenied"))
        return "Windows would not let Ghoztty open a file it needs. " ++
            "Check that your antivirus is not blocking it, then start Ghoztty again.";

    if (std.mem.eql(u8, name, "Win32Error"))
        return "Windows refused a request Ghoztty made while building its window. " ++
            "Sign out and back in, then start Ghoztty again.";

    return "Start Ghoztty again. If it keeps failing, reinstall it — and please " ++
        "include this message in a bug report.";
}

/// The whole dialog body for a fatal startup failure, written into `buf`.
///
/// `stage` is a sentence fragment naming what was underway ("opening its first
/// window"), so the first line reads as something a person would say rather
/// than as a diagnostic: "Ghoztty ran into a problem while opening its first
/// window and had to close." The error name follows on its own line — it is the
/// only part a bug report can be matched on — and the remedy closes.
pub fn describe(buf: []u8, stage: []const u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty ran into a problem while {s} and had to close.\n\n" ++
            "Error: {s}\n\n" ++
            "{s}\n\n" ++
            "Details are in " ++ log_path ++ ".",
        .{ stage, @errorName(err), remedyFor(err) },
    ) catch buf[0..0];
}

/// The body for a DEGRADED start: a window is up, but `what` is missing.
/// `consequence` says what the user loses, `remedy` what fixes it — both
/// supplied by the caller, because only the caller knows which precondition
/// failed.
pub fn describeDegraded(
    buf: []u8,
    what: []const u8,
    consequence: []const u8,
    remedy: []const u8,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}\n\n{s}\n\n{s}",
        .{ what, consequence, remedy },
    ) catch buf[0..0];
}

/// UTF-8 → NUL-terminated UTF-16 into `buf`, or null when it does not fit.
///
/// Allocation-free on purpose: the fatal path runs when `App.create` has
/// already failed, and OutOfMemory is one of the errors it must be able to
/// report. A reporter that allocates cannot report that.
fn toUtf16Z(buf: []u16, text: []const u8) ?[:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Show a modal, blocking error dialog for a startup failure that leaves no
/// usable app, and LOG it. Returns once the user dismisses it; the caller
/// exits.
///
/// Deliberately takes no `*App`: the whole point is that it works when there is
/// no App, no window and no message loop — which is exactly the state every
/// caller is in. `ConfirmDialog.showStandalone` supplies the process instance
/// handle for the same reason.
pub fn reportFatal(stage: []const u8, err: anyerror) void {
    if (comptime builtin.os.tag != .windows) return;

    var buf: [max_message]u8 = undefined;
    const text = describe(&buf, stage, err);
    log.err("startup failed while {s}: {s}", .{ stage, @errorName(err) });

    var wbuf: [max_message * 2]u16 = undefined;
    const text_w = toUtf16Z(&wbuf, text) orelse return;
    _ = ConfirmDialog.showStandalone(null, 1.0, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty could not start"),
        .text = text_w,
        .style = .ok_only,
        .icon = .warning,
    });
}

/// Show a modal notice for a startup precondition that failed WITHOUT stopping
/// the app, and log it. `owner`/`scale` come from the window that did come up,
/// so the notice centers on it like every other dialog.
pub fn reportDegraded(
    app: anytype,
    owner: ?w32.HWND,
    scale: f32,
    title: [*:0]const u16,
    text: []const u8,
) void {
    if (comptime builtin.os.tag != .windows) return;

    log.warn("degraded start: {s}", .{text});
    var wbuf: [max_message * 2]u16 = undefined;
    const text_w = toUtf16Z(&wbuf, text) orelse return;
    _ = ConfirmDialog.show(app, owner, scale, null, .{
        .title = title,
        .text = text_w,
        .style = .ok_only,
        .icon = .warning,
    });
}

test "remedyFor: a missing file reads as a broken install, not a stack trace" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(
        u8,
        remedyFor(error.FileNotFound),
        "Reinstall Ghoztty",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        remedyFor(error.AgentBinaryNotFound),
        "Reinstall Ghoztty",
    ) != null);
}

test "remedyFor: an unmapped error still gets actionable guidance" {
    const testing = std.testing;
    const text = remedyFor(error.SomethingNobodyHasSeenBefore);
    try testing.expect(text.len > 0);
    try testing.expect(std.mem.indexOf(u8, text, "Start Ghoztty again") != null);
}

test "describe: names the stage, the error and where to look" {
    const testing = std.testing;
    var buf: [max_message]u8 = undefined;
    const text = describe(&buf, "opening its first window", error.NoStartupWindow);
    try testing.expect(std.mem.indexOf(u8, text, "opening its first window") != null);
    try testing.expect(std.mem.indexOf(u8, text, "NoStartupWindow") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ghoztty.log") != null);
    // The remedy, not just the diagnosis.
    try testing.expect(std.mem.indexOf(u8, text, "Restart it") != null);
}

test "describe: a buffer too small yields empty, never a panic" {
    const testing = std.testing;
    var buf: [8]u8 = undefined;
    try testing.expectEqual(
        @as(usize, 0),
        describe(&buf, "opening its first window", error.NoStartupWindow).len,
    );
}

test "describeDegraded: keeps the three parts in order" {
    const testing = std.testing;
    var buf: [max_message]u8 = undefined;
    const text = describeDegraded(
        &buf,
        "Ghoztty's session agent is missing.",
        "Terminals will not survive a restart.",
        "Reinstall Ghoztty.",
    );
    const a = std.mem.indexOf(u8, text, "session agent").?;
    const b = std.mem.indexOf(u8, text, "survive a restart").?;
    const c = std.mem.indexOf(u8, text, "Reinstall").?;
    try testing.expect(a < b and b < c);
}
