//! The "Share this machine" toggle of the win32 machine chooser (T547).
//!
//! The one-installer consolidation (docs/design/one-installer-agent-
//! consolidation.md, decision 2) puts serving in the machine chooser: the
//! account row gains a per-machine toggle that decides whether the LOCAL
//! agent raises its relay uplink and lets the user's other devices open
//! terminals here. The state is the agent's own `sharing.json` (written with
//! the exact code the agent reads it with — `src/remote/agent/sharing.zig`),
//! and the agent reconciles that file every few seconds (T546), so flipping
//! the toggle needs no poke, no Run-key rewrite and no new CLI verb (the T141
//! rule: account affordances are GUI on both platforms).
//!
//! This module owns the ASYNC half, on `RelayAccountRow`'s exact pattern: the
//! first flip on a machine with no device credential runs browser enrollment
//! (`enroll.run`), which blocks for as long as the user takes to finish the
//! relay's consent page — minutes, so it must not run on the GUI thread. The
//! worker posts `WM_APP_SHARE_MACHINE` to the app's message-only window and
//! the outcome routes to whatever chooser is open, or to nobody: sharing.json
//! is the state, not the dialog. Flips that need no browser (credential
//! already present, or turning sharing off) are one small atomic file write
//! and happen synchronously.
//!
//! `MachineChooser` owns the checkbox HWND and the redraw; everything here is
//! either pure (unit-tested labels and sentences) or off-thread.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const MachineChooser = @import("MachineChooser.zig");
const enroll = @import("../../remote/agent/enroll.zig");
const sharing = @import("../../remote/agent/sharing.zig");
const w32 = @import("win32.zig");
const utf16_text = @import("utf16_text.zig");

const log = std.log.scoped(.win32);

/// Posted by the enrollment thread to `App.msg_hwnd`. wparam = *Result
/// (ownership transfers to the GUI thread, which frees it in `onResult`).
/// WM_APP+1..+33 are taken (see App.zig's ledger comment).
pub const WM_APP_SHARE_MACHINE: u32 = w32.WM_APP + 34;

/// The outcome of an async enable, allocated on the app allocator by the
/// worker thread and freed by `onResult` on the GUI thread. Every message is
/// a static sentence, so only the struct itself is owned.
pub const Result = struct {
    ok: bool,
    /// A short user-facing sentence for the chooser's footer hint.
    message: []const u8,
};

/// Only one enrollment at a time. The guard lives with the work, not the
/// widget: the chooser can be closed and reopened while the browser flow is
/// still pending, and the reopened one must show the pending state rather
/// than start a second flow.
var running: std.atomic.Value(bool) = .init(false);

pub fn isRunning() bool {
    return running.load(.acquire);
}

/// Read the persisted per-machine sharing state. Absent or unreadable is
/// disabled — the same lenient read the agent does.
pub fn isEnabled(alloc: Allocator, config_path: []const u8) bool {
    return sharing.load(alloc, config_path).enabled;
}

/// Turn sharing OFF: one atomic write, on the GUI thread (it is a rename, not
/// a network op). The credential is deliberately kept — decision 2: toggling
/// off tears the uplink down, it does not sign the machine out.
pub fn disable(alloc: Allocator, config_path: []const u8) bool {
    sharing.save(alloc, config_path, .{ .enabled = false }) catch |err| {
        log.warn("share machine: disable write failed err={}", .{err});
        return false;
    };
    return true;
}

/// What a flip to ON did. `enabled` finished synchronously (a credential was
/// already on disk); `enrolling` started the browser flow and the caller
/// shows the pending state until `WM_APP_SHARE_MACHINE` lands; `busy` means a
/// flow is already pending; `failed` could not even start.
pub const StartOutcome = enum { enabled, enrolling, busy, failed };

/// Turn sharing ON. With a device credential already in relay.env this is
/// the same synchronous write `disable` does; without one it starts browser
/// enrollment on a detached thread (`relay_base` is the chooser's resolved
/// base). Safe to call from the GUI thread.
pub fn enableAsync(
    app: *App,
    relay_base: []const u8,
    config_path: []const u8,
) StartOutcome {
    const alloc = app.core_app.alloc;

    // Credential already present: no browser, just persist the flag. The
    // token's presence is the same test the agent's reconciler applies.
    if (enroll.loadDeviceToken(alloc)) |tok| {
        alloc.free(tok);
        sharing.save(alloc, config_path, .{ .enabled = true }) catch |err| {
            log.warn("share machine: enable write failed err={}", .{err});
            return .failed;
        };
        return .enabled;
    }

    if (running.swap(true, .acq_rel)) {
        log.info("share machine: an enrollment is already running; ignoring", .{});
        return .busy;
    }

    const job = alloc.create(Job) catch {
        running.store(false, .release);
        return .failed;
    };
    job.* = .{
        .app = app,
        .relay_base = alloc.dupe(u8, relay_base) catch {
            alloc.destroy(job);
            running.store(false, .release);
            return .failed;
        },
        .config_path = alloc.dupe(u8, config_path) catch {
            alloc.free(job.relay_base);
            alloc.destroy(job);
            running.store(false, .release);
            return .failed;
        },
    };

    const thread = std.Thread.spawn(.{}, worker, .{job}) catch |err| {
        job.deinit();
        running.store(false, .release);
        log.warn("share machine: thread spawn failed err={}", .{err});
        return .failed;
    };
    thread.detach();
    return .enrolling;
}

/// The worker's arguments — owned copies, because the chooser (and its arena,
/// where `relay_base` lives) can be destroyed while the browser flow runs.
const Job = struct {
    app: *App,
    relay_base: []u8,
    config_path: []u8,

    fn deinit(self: *Job) void {
        const alloc = self.app.core_app.alloc;
        alloc.free(self.relay_base);
        alloc.free(self.config_path);
        alloc.destroy(self);
    }
};

fn worker(job: *Job) void {
    const app = job.app;
    defer job.deinit();
    defer running.store(false, .release);

    // The flow's own scratch memory: page-backed so it never touches the GUI
    // thread's allocator from off-thread.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outcome: Result = blk: {
        var host_buf: [256]u8 = undefined;
        const name = hostName(&host_buf) orelse "unknown-host";
        if (enroll.run(arena, job.relay_base, name, .{})) {
            // Enrollment persisted relay.env; now persist the flag the agent
            // reconciles on. A write failure here must NOT read as enabled.
            if (sharing.save(arena, job.config_path, .{ .enabled = true })) {
                break :blk .{ .ok = true, .message = enabled_hint };
            } else |err| {
                log.warn("share machine: post-enroll enable write failed err={}", .{err});
                break :blk .{ .ok = false, .message = save_failed_hint };
            }
        } else |err| {
            log.warn("share machine: enrollment failed err={}", .{err});
            break :blk .{ .ok = false, .message = errorMessage(err) };
        }
    };

    const alloc = app.core_app.alloc;
    const res = alloc.create(Result) catch return;
    res.* = outcome;

    const hwnd = app.msg_hwnd orelse {
        alloc.destroy(res);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_SHARE_MACHINE, @intFromPtr(res), 0) == 0) {
        alloc.destroy(res);
    }
}

/// GUI thread (App's message-only WndProc): apply an enrollment outcome. Owns
/// `res`. A closed chooser is not an error — sharing.json already changed, and
/// the next chooser open reads it.
pub fn onResult(app: *App, res: *Result) void {
    defer app.core_app.alloc.destroy(res);
    log.info("share machine: enable {s}", .{if (res.ok) "ok" else "failed"});
    if (openChooser(app)) |chooser| chooser.onShareResult(res);
}

/// The first open machine chooser across all windows, if any (the same
/// routing `RelayAccountRow.onResult` uses).
fn openChooser(app: *App) ?*MachineChooser {
    for (app.windows.items) |win| {
        if (win.machine_chooser) |chooser| return chooser;
    }
    return null;
}

/// This machine's name for the relay's device list: the DNS hostname
/// (preserves case, matches what the agent advertises in its HELLO) rather
/// than %COMPUTERNAME%'s uppercased NetBIOS name.
fn hostName(out: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        var wbuf: [256]u16 = undefined;
        var size: u32 = wbuf.len;
        // 1 == ComputerNameDnsHostname
        if (kernel32.GetComputerNameExW(1, &wbuf, &size) == 0) return null;
        // All or nothing (T990): half a host name is a different machine, and
        // the plain `std.unicode.utf16LeToUtf8` this used to call panicked on
        // a short `out` rather than erroring — the `catch` could not see it.
        const n = utf16_text.toUtf8AllOrNothing(out, wbuf[0..size]);
        return if (n == 0) null else out[0..n];
    } else {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const name = std.posix.gethostname(&buf) catch return null;
        if (name.len == 0 or name.len > out.len) return null;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
}

const kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetComputerNameExW(
        NameType: c_int,
        lpBuffer: [*]u16,
        nSize: *u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

// ---------------------------------------------------------------------
// Pure presentation (unit-tested; the chooser renders these verbatim)
// ---------------------------------------------------------------------

/// The checkbox caption. Constant across states — a checkbox that renames
/// itself reads as a different setting; the STATE is the check mark and the
/// footer hint carries the news.
pub const label = "Share this machine";

/// Footer hints for the flips that finish synchronously, and for the pending
/// browser flow. The chooser shows these verbatim in its status strip.
pub const enabled_hint =
    "Sharing is on — your other devices can open terminals on this machine.";
pub const disabled_hint =
    "Sharing is off. This machine keeps its credential; flip the switch to share again.";
pub const pending_hint =
    "Finish adding this machine in your browser — sharing turns on once it's approved.";
pub const save_failed_hint =
    "Couldn't save the sharing setting. Check that the agent's data folder is writable.";

/// A user-facing sentence for a failed enrollment. Mirrors the tone of
/// `relay_signin.errorMessage`: what happened and what to do, no error codes.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EnrollDenied => "The browser request was declined. Flip the switch again to retry.",
        error.EnrollExpired => "The browser link expired before it was approved. Flip the switch again to retry.",
        error.EnrollUnavailable => "This relay has no sign-in configured, so machines can't be added to it.",
        error.EnrollRefused, error.EnrollRejected => "The relay refused to add this machine. Try again, or check the relay's account settings.",
        else => "Couldn't reach the relay to add this machine. Check your connection and flip the switch again.",
    };
}

/// Whether the checkbox should read as CHECKED for a given (persisted,
/// pending) pair. While enrollment runs the user's intent is ON, so the box
/// stays checked and disabled rather than snapping back and re-checking
/// itself minutes later.
pub fn boxChecked(persisted: bool, pending: bool) bool {
    return persisted or pending;
}

const testing = std.testing;

test "boxChecked: pending keeps the user's intent visible" {
    try testing.expect(boxChecked(true, false));
    try testing.expect(boxChecked(false, true));
    try testing.expect(boxChecked(true, true));
    try testing.expect(!boxChecked(false, false));
}

test "errorMessage: every enrollment failure has a plain sentence" {
    // Each named failure mode gets its own remedy, and anything else still
    // produces a sentence rather than an error name.
    for ([_]anyerror{
        error.EnrollDenied,
        error.EnrollExpired,
        error.EnrollUnavailable,
        error.EnrollRefused,
        error.EnrollRejected,
        error.ConnectionRefused,
    }) |err| {
        const msg = errorMessage(err);
        try testing.expect(msg.len > 0);
        try testing.expect(std.mem.indexOf(u8, msg, "error.") == null);
    }
    // Denied and expired both say how to recover: flip again.
    try testing.expect(std.mem.indexOf(u8, errorMessage(error.EnrollDenied), "again") != null);
    try testing.expect(std.mem.indexOf(u8, errorMessage(error.EnrollExpired), "again") != null);
}

test "hints: the toggle's sentences say what changed for the user" {
    try testing.expect(std.mem.indexOf(u8, enabled_hint, "other devices") != null);
    try testing.expect(std.mem.indexOf(u8, disabled_hint, "off") != null);
    try testing.expect(std.mem.indexOf(u8, pending_hint, "browser") != null);
    try testing.expectEqualStrings("Share this machine", label);
}
