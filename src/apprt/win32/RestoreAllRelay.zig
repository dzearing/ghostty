//! T339: the cross-machine "Restore All" (T336) with its NETWORK off the GUI
//! thread.
//!
//! Rebuilding another machine's topology costs 1 + N relay dials — one for the
//! layout pull, then one per rebuilt window, because a win32 window OWNS its
//! transport and frees it on close (`Window.deinit`), so a shared connection
//! would die with the first window the user closed. That ownership rule is
//! T336's and stands; what was wrong is that all N+1 full WebSocket upgrades ran
//! on the GUI thread. On loopback that is milliseconds and invisible; against a
//! real rendezvous relay it is N+1 round trips with the message loop STOPPED —
//! a 6-window machine on a 300 ms link freezes the app for ~2 seconds with no
//! cursor, no paint and no way to cancel.
//!
//! So the work is split down the line that decides it:
//!
//!   worker thread   dial → GET_LAYOUTS → LIST_SESSIONS → one dial per window
//!   GUI thread      decide + `restoreWindow` per window (it creates windows)
//!
//! The pattern is the one `SessionRoster.fetch` (T295/T319) and
//! `RemoteReconnect`'s redial already use here: spawn, block off-thread,
//! `PostMessage` the result back to the app's message window (never to the
//! chooser's own — `DestroyWindow` discards a window's queued messages, and a
//! discarded reply would leak every connection it carries, the T318/T295
//! lesson).
//!
//! OWNERSHIP is the part worth stating. One `Job` allocation travels both ways:
//! the GUI thread fills in where to dial and what is already open, the worker
//! fills in what it pulled and dialed, and the GUI thread consumes it and frees
//! it. Every dial it carries is freed by `Job.destroy` unless the rebuild handed
//! it to a window first — so a reply landing after the chooser closed, after the
//! app started quitting, or on a window that failed to build cannot leak a
//! transport, and cannot hand one to a window that no longer exists.
//!
//! The dials are SERIAL. Off the GUI thread they no longer block paint, which
//! is the defect; making them concurrent would additionally collapse N round
//! trips into one, and is filed separately rather than smuggled in here.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const layout_blobs = @import("layout_blobs.zig");
const session_layout = @import("session_layout.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted to the app's message window when a restore worker is done.
/// wparam = `*Job`, owned by the handler.
pub const WM_APP_RESTORE_ALL: u32 = w32.WM_APP + 19;

/// The relay credentials a restore dials with. BORROWED for the `start` call
/// (the chooser owns them, and it may close while the worker is still dialing);
/// `start` deep-copies them into the job.
pub const Target = struct {
    base: []const u8,
    device: []const u8,
    token: []const u8,
};

/// One window the worker prepared: its decoded layout plus the transport it
/// dialed for it. `dialed` is owned by the job until the GUI thread hands it to
/// a window, which nulls it — whatever is left is freed by `Job.destroy`.
pub const Prepared = struct {
    win: session_layout.Window,
    dialed: ?Window.RemoteDialed,
};

/// The whole job, allocated on the GUI thread and freed there: the worker only
/// ever fills fields in. One allocation for both directions, so there is exactly
/// one free path for everything a restore holds.
pub const Job = struct {
    alloc: Allocator,
    /// The app's message window — the reply's destination.
    hwnd: w32.HWND,
    /// Which chooser asked, matched on the way back by ID and never by pointer.
    chooser_id: u64,

    // --- filled in by `start`, owned ------------------------------------
    base: []u8,
    device: []u8,
    token: []u8,
    /// Session ids one of OUR panes already holds on that machine, snapshotted
    /// on the GUI thread. The worker skips their windows rather than dialing a
    /// transport the double-attach guard is about to throw away.
    open: [][]u8 = &.{},

    // --- filled in by the worker ---------------------------------------
    /// Non-null ⇒ the pull never completed, so nothing was dialed and there is
    /// nothing to rebuild; the chooser turns it into a sentence.
    err: ?App.RestoreAllError = null,
    decoded: ?layout_blobs.Decoded = null,
    probe: App.AttachProbe = .{},
    prepared: []Prepared = &.{},
    /// How many layout blobs the machine holds, for the "nothing to rebuild"
    /// line — a machine with none is a different fact from one whose windows
    /// are all already open here.
    held: usize = 0,

    /// The machine every prepared window is dialed to, recorded on each rebuilt
    /// window so T68's "New Window" re-dials the same one. Borrows this job's
    /// strings; `setRemoteMachine` dupes them.
    pub fn machine(self: *const Job) Window.RemoteMachine {
        return .{ .relay = .{ .base = self.base, .device = self.device } };
    }

    /// Whether one of our panes already holds a session this window wants, per
    /// the GUI-thread snapshot. One leaf is enough: a window is restored as a
    /// unit (`App.windowIsOpenOn` states the same rule against LIVE panes, which
    /// is what the GUI thread re-checks before it builds anything).
    fn windowIsOpen(self: *const Job, win: session_layout.Window) bool {
        for (win.tabs) |tab| {
            for (tab.nodes) |node| {
                const leaf = node.leaf orelse continue;
                const sid = leaf.session_id orelse continue;
                if (sid.len == 0) continue;
                for (self.open) |id| {
                    if (std.mem.eql(u8, id, sid)) return true;
                }
            }
        }
        return false;
    }

    pub fn destroy(self: *Job) void {
        const alloc = self.alloc;
        // Every dial the rebuild did NOT take ownership of. This is the line
        // that makes a reply landing on a closed chooser (or a quitting app)
        // safe rather than a leaked connection per window.
        for (self.prepared) |p| if (p.dialed) |d| d.deinitDestroy(alloc);
        if (self.prepared.len > 0) alloc.free(self.prepared);
        self.probe.deinit();
        if (self.decoded) |d| d.deinit();
        for (self.open) |id| alloc.free(id);
        if (self.open.len > 0) alloc.free(self.open);
        alloc.free(self.base);
        alloc.free(self.device);
        alloc.free(self.token);
        alloc.destroy(self);
    }
};

/// GUI thread: start a cross-machine Restore All. Returns false when nothing was
/// started (out of memory, no message window, no thread) — the caller then says
/// so instead of waiting for a reply that will never come.
pub fn start(app: *App, chooser_id: u64, target: Target) bool {
    if (comptime builtin.os.tag != .windows) return false;
    const alloc = app.core_app.alloc;
    const hwnd = app.msg_hwnd orelse return false;

    const job = alloc.create(Job) catch return false;
    const base = alloc.dupe(u8, target.base) catch {
        alloc.destroy(job);
        return false;
    };
    const device = alloc.dupe(u8, target.device) catch {
        alloc.free(base);
        alloc.destroy(job);
        return false;
    };
    const token = alloc.dupe(u8, target.token) catch {
        alloc.free(base);
        alloc.free(device);
        alloc.destroy(job);
        return false;
    };
    job.* = .{
        .alloc = alloc,
        .hwnd = hwnd,
        .chooser_id = chooser_id,
        .base = base,
        .device = device,
        .token = token,
    };
    // Read the live panes HERE, where they may be read at all. A failed
    // snapshot is an empty one: the guard is re-applied on the GUI thread
    // before anything is built, so the worst case is a wasted dial.
    job.open = app.openSessionIdsOn(alloc, job.machine()) catch &.{};

    const thread = std.Thread.spawn(.{}, worker, .{job}) catch |err| {
        log.warn("restore all: worker thread spawn failed err={}", .{err});
        job.destroy();
        return false;
    };
    thread.detach();
    return true;
}

fn worker(job: *Job) void {
    const alloc = job.alloc;

    // The PULL's own connection: short-lived by design, exactly like the
    // roster's browse dial. Freed below whatever happens — the windows never
    // ride it, they each take their own.
    var pull = dialRelay(alloc, job.base, job.device, job.token) catch |err| {
        job.err = err;
        return finish(job);
    };
    defer pull.deinitDestroy(alloc);

    const payload = pull.conn().requestLayouts(App.restore_probe_timeout_ns) catch |err| {
        log.warn("restore all: GET_LAYOUTS failed err={}", .{err});
        job.err = error.PullFailed;
        return finish(job);
    };
    defer alloc.free(payload);

    const decoded = layout_blobs.decodeLayouts(alloc, payload) catch |err| {
        log.warn("restore all: layouts payload unreadable err={}", .{err});
        job.err = error.PullFailed;
        return finish(job);
    };
    job.decoded = decoded;
    job.held = decoded.windows.len;
    if (decoded.skipped > 0) {
        // Said out loud rather than silently: "3 of 5 windows" is a different
        // fact from "3 windows", and only one of them is worth investigating.
        log.warn("restore all: {d} blob(s) skipped as unreadable", .{decoded.skipped});
    }

    job.probe = App.AttachProbe.take(alloc, pull.conn());
    const attach_ptr = job.probe.attachSet();

    var list: std.ArrayList(Prepared) = .empty;
    defer list.deinit(alloc);
    for (decoded.windows) |win| {
        if (!App.restoreWindowHasAttachableLeaf(win, attach_ptr)) continue;
        // The double-attach guard, applied against the GUI thread's snapshot so
        // a window that is already on screen costs no dial at all. The agent
        // rebinds a session to the NEWEST attach, so rebuilding a window whose
        // panes are already open would quietly steal them from the window that
        // has them — the user would watch their own terminal go blank to make a
        // copy of itself.
        if (job.windowIsOpen(win)) {
            log.info("restore all: '{s}' is already open here, skipping", .{win.id});
            continue;
        }

        // Per-window transport. The dial happens BEFORE the rebuild so a
        // machine that stops answering mid-restore costs a skipped window
        // rather than a half-built one.
        const dialed = dialRelay(alloc, job.base, job.device, job.token) catch |err| {
            log.warn("restore all: window '{s}' dial failed err={}", .{ win.id, err });
            continue;
        };
        list.append(alloc, .{ .win = win, .dialed = dialed }) catch {
            dialed.deinitDestroy(alloc);
            break;
        };
    }
    job.prepared = list.toOwnedSlice(alloc) catch blk: {
        // The list still holds the dials, and `deinit` frees the array but not
        // what is in it. Nothing else will ever see them, so they are freed
        // here rather than left to an owner that does not exist.
        for (list.items) |p| if (p.dialed) |d| d.deinitDestroy(alloc);
        break :blk &.{};
    };
    finish(job);
}

/// Hand the job back to the GUI thread, or free it when there is no longer a
/// GUI thread to hand it to.
fn finish(job: *Job) void {
    if (w32.PostMessageW(job.hwnd, WM_APP_RESTORE_ALL, @intFromPtr(job), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        job.destroy();
    }
}

/// Dial an enrolled relay device, mapping the transport's errors onto the two
/// the chooser can actually say something useful about. Heap-owned so the result
/// can be handed to a window; the caller frees it if it does not.
///
/// Called from the WORKER thread only — it touches nothing but the allocator.
fn dialRelay(
    alloc: Allocator,
    base: []const u8,
    device: []const u8,
    token: []const u8,
) App.RestoreAllError!Window.RemoteDialed {
    const dialed = alloc.create(relay_dial.Dialed) catch return error.DialFailed;
    dialed.* = relay_dial.dial(alloc, base, device, token, .raw) catch |err| {
        log.warn(
            "restore all: relay dial failed relay={s} device={s} err={}",
            .{ base, device, err },
        );
        alloc.destroy(dialed);
        // A rejected bearer is not an unreachable machine, and telling the user
        // to check the network when the fix is signing in wastes their time
        // (the split T319 drew for the roster).
        return if (err == error.WebSocketUnauthorized) error.Unauthorized else error.DialFailed;
    };
    return .{ .relay = dialed };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A one-tab window whose single leaf carries `sid`.
fn oneLeafWindow(
    nodes: *[1]session_layout.Node,
    tabs: *[1]session_layout.Tab,
    sid: ?[]const u8,
) session_layout.Window {
    nodes[0] = .{ .leaf = .{ .session_id = sid } };
    tabs[0] = .{ .nodes = nodes[0..1] };
    return .{ .id = "w", .tabs = tabs[0..1] };
}

test "windowIsOpen matches a snapshotted session id" {
    var nodes: [1]session_layout.Node = undefined;
    var tabs: [1]session_layout.Tab = undefined;

    var open = [_][]u8{
        @constCast("sess-a"[0..]),
        @constCast("sess-b"[0..]),
    };
    const job: Job = .{
        .alloc = testing.allocator,
        .hwnd = undefined,
        .chooser_id = 1,
        .base = @constCast("http://r"[0..]),
        .device = @constCast("dev"[0..]),
        .token = @constCast("tok"[0..]),
        .open = open[0..],
    };

    try testing.expect(job.windowIsOpen(oneLeafWindow(&nodes, &tabs, "sess-b")));
    try testing.expect(!job.windowIsOpen(oneLeafWindow(&nodes, &tabs, "sess-c")));
    // No id and an empty id are both "not open" — neither names a session.
    try testing.expect(!job.windowIsOpen(oneLeafWindow(&nodes, &tabs, null)));
    try testing.expect(!job.windowIsOpen(oneLeafWindow(&nodes, &tabs, "")));
}

test "windowIsOpen with an empty snapshot never matches" {
    var nodes: [1]session_layout.Node = undefined;
    var tabs: [1]session_layout.Tab = undefined;
    const job: Job = .{
        .alloc = testing.allocator,
        .hwnd = undefined,
        .chooser_id = 1,
        .base = @constCast("http://r"[0..]),
        .device = @constCast("dev"[0..]),
        .token = @constCast("tok"[0..]),
    };
    try testing.expect(!job.windowIsOpen(oneLeafWindow(&nodes, &tabs, "sess-a")));
}
