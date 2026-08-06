//! The machine chooser's session roster: the RPC, the state, and the painting
//! of the detail pane's per-session list (T318).
//!
//! `chooser_sessions.zig` holds everything pure about a roster row — the label
//! ladder, the connectable filter, the badges and the card geometry — and is
//! unit-tested in the none-runtime lane. This file is what that geometry is
//! drawn with, plus the part that cannot be pure: a blocking `LIST_SESSIONS`
//! against the local agent.
//!
//! ## Threading (inherited from T295, non-negotiable)
//!
//! The RPC blocks — dial, request, wait. It runs on a DETACHED THREAD and posts
//! its outcome back to the GUI thread as a `*Result`, which the handler owns
//! from that moment. A reply that lands after its chooser closed FREES what it
//! fetched instead of adopting it, which is why the message lands on the app's
//! message-only window and not on the chooser's HWND: `DestroyWindow` discards
//! a window's queued messages, and a discarded reply would leak a roster and,
//! on the probe path, a whole connection.
//!
//! A failed or slow fetch is a state OF THE REGION — never a modal, never a
//! blocked chooser.

const SessionRoster = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const chooser_layout = @import("chooser_layout.zig");
const chooser_sessions = @import("chooser_sessions.zig");
const chrome_theme = @import("chrome_theme.zig");
const icon_button = @import("icon_button.zig");
const LocalAgent = @import("LocalAgent.zig");
const session_layout = @import("session_layout.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// A finished roster fetch, in flight to the GUI thread. Follows the
/// `ActivityMonitor.DialResult` shape: heap-allocated by the worker, owned by
/// the handler.
pub const WM_APP_CHOOSER_SESSIONS: u32 = w32.WM_APP + 16;

/// How long the RPC may take before it resolves to `failed`. Generous enough
/// for a busy agent, short enough that a wedged one does not leave the region
/// spinning for the length of the dialog.
const rpc_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// Session ids are 32 hex chars on the wire; the buffer is the cap on what an
/// optimistic hide can remember, not a protocol constant.
const max_id_len = 64;
/// How many just-killed ids are hidden at once. A user killing more sessions
/// than this in one undo window is not a case worth growing state for — the
/// refetch drops them anyway.
const max_killed = 16;

// ---------------------------------------------------------------------
// State (GUI thread only)
// ---------------------------------------------------------------------

/// Everything the worker needs to reach a REMOTE machine's agent. There is no
/// new RPC on this path — `Connection.requestSessions` is transport-agnostic
/// (`connection.zig:1598`), which is Mac's own claim about it
/// (`SessionBrowserProbe.swift:93-96`) — so the whole remote half of this file
/// is the dial and who owns it.
pub const Remote = struct {
    /// The relay HTTPS base (an `http://` base is a loopback test relay).
    base: []const u8,
    /// The enrolled device id.
    device: []const u8,
    /// The bearer the relay authenticates with.
    token: []const u8,
};

alloc: Allocator,
state: chooser_sessions.State = .loading,
/// Which machine these sessions belong to (T319). Every fetch, adopt and paint
/// is about THIS target; moving it resets the region, because machine A's
/// sessions under machine B's name is the one thing worse than an empty pane.
target: chooser_sessions.Target = .none,
/// Relay credentials for a `.remote` target, BORROWED from the chooser (its
/// arena and its device listing both outlive the roster). Null for `.local`.
remote: ?Remote = null,
/// The fetched roster. Owned; freed here and replaced whole by each adopt.
owned: ?remote_connection.OwnedSessions = null,
/// Bumped on every fetch. A reply carrying an older serial is stale — its
/// chooser has moved on — and is freed rather than adopted.
serial: u64 = 0,
inflight: bool = false,
scroll: i32 = 0,
/// Index (into the VISIBLE rows) whose Kill button is under the pointer, or -1.
hover_kill: i32 = -1,
/// The keyboard sub-cursor (T320): an index into the VISIBLE rows, or
/// `chooser_sessions.no_cursor` when the machine row itself is highlighted and
/// the roster is not being navigated. Same index space as `hover_kill`,
/// `killAt` and `paint` — every one of them takes the rows array `visible()`
/// returned, so there is no second list for the two to disagree about.
cursor: i32 = chooser_sessions.no_cursor,

/// Sessions the user just killed, hidden optimistically so the row vanishes at
/// once instead of lingering — and degrading to a "pid" label — during the
/// close's undo window while the agent still lists it. Cleared when a refetch
/// confirms they are gone.
killed: [max_killed][max_id_len]u8 = undefined,
killed_len: [max_killed]usize = @splat(0),
killed_count: usize = 0,

/// The saved session-layout manifest, loaded once when the chooser opens, for
/// the `persisted_title` rung of the label ladder. Null when there is no
/// manifest (persistence off, or a first run).
manifest: ?session_layout.Parsed = null,

pub fn init(alloc: Allocator) SessionRoster {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *SessionRoster) void {
    if (self.owned) |*o| o.deinit();
    self.owned = null;
    if (self.manifest) |*m| m.deinit();
    self.manifest = null;
}

/// Load the session-layout manifest for the persisted-title rung. Best effort:
/// a missing or malformed manifest simply removes one rung from the ladder.
pub fn loadManifest(self: *SessionRoster) void {
    if (comptime builtin.os.tag != .windows) return;
    const path = session_layout.layoutPath(self.alloc) orelse return;
    defer self.alloc.free(path);
    self.manifest = session_layout.load(self.alloc, path) catch null;
}

// ---------------------------------------------------------------------
// The fetch (worker thread)
// ---------------------------------------------------------------------

const Request = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    chooser_id: u64,
    serial: u64,
    /// The app's warm shared agent connection, borrowed. Never freed here — it
    /// is owned by `LocalAgent` for the app's lifetime (and a retired one is
    /// kept alive precisely so a borrow like this can never dangle).
    warm: ?*remote_connection.Connection,
    /// A session to END before listing, for the Kill path. Owned.
    kill_id: ?[]u8,
    /// A relay target, DEEP-COPIED off the GUI thread's borrowed strings: the
    /// chooser that owns them can close while this dial is still blocking.
    remote: ?OwnedRemote = null,

    fn destroy(self: *Request) void {
        if (self.kill_id) |k| self.alloc.free(k);
        if (self.remote) |r| r.deinit(self.alloc);
        self.alloc.destroy(self);
    }
};

const OwnedRemote = struct {
    base: []u8,
    device: []u8,
    token: []u8,

    fn dupe(alloc: Allocator, src: Remote) ?OwnedRemote {
        const base = alloc.dupe(u8, src.base) catch return null;
        const device = alloc.dupe(u8, src.device) catch {
            alloc.free(base);
            return null;
        };
        const token = alloc.dupe(u8, src.token) catch {
            alloc.free(base);
            alloc.free(device);
            return null;
        };
        return .{ .base = base, .device = device, .token = token };
    }

    fn deinit(self: OwnedRemote, alloc: Allocator) void {
        alloc.free(self.base);
        alloc.free(self.device);
        alloc.free(self.token);
    }
};

pub const Result = struct {
    alloc: Allocator,
    chooser_id: u64,
    serial: u64,
    /// The fetched roster, or null when the RPC failed / no agent answered.
    roster: ?remote_connection.OwnedSessions,
    /// Whether a requested Kill was confirmed by the agent. Null when this
    /// fetch did not carry one.
    killed_ok: ?bool = null,
    /// The relay rejected our bearer. A different sentence from "couldn't
    /// reach it", because it is the one the user can act on.
    unauthorized: bool = false,

    pub fn destroy(self: *Result) void {
        if (self.roster) |*r| r.deinit();
        self.alloc.destroy(self);
    }
};

/// Point the roster at a machine (T319) and fetch if the move calls for it.
/// `remote` carries the relay credentials for a `.remote` target and is ignored
/// otherwise; it is BORROWED — the worker deep-copies what it needs.
///
/// Returns true when the region changed and the caller should repaint.
pub fn show(
    self: *SessionRoster,
    app: *App,
    chooser_id: u64,
    target: chooser_sessions.Target,
    remote: ?Remote,
) bool {
    switch (chooser_sessions.transitionFor(self.target, target, self.state, self.inflight)) {
        .nothing => return false,
        .reset => {
            self.clear();
            self.target = target;
            self.remote = null;
            return true;
        },
        .reset_and_fetch => {
            self.clear();
            self.target = target;
            self.remote = if (target == .remote) remote else null;
            self.fetch(app, chooser_id, null);
            return true;
        },
        .refresh_in_place => {
            // Same machine: keep the rows AND the credentials, and refetch
            // without touching `state` (`fetch` only moves to `loading` when
            // there is nothing to show).
            self.fetch(app, chooser_id, null);
            return false;
        },
    }
}

/// Drop everything that belongs to the machine we are leaving. Not optional:
/// the rows, the scroll offset and the optimistic kill hides are all statements
/// about a specific agent.
fn clear(self: *SessionRoster) void {
    if (self.owned) |*o| o.deinit();
    self.owned = null;
    self.state = .loading;
    self.scroll = 0;
    self.hover_kill = -1;
    // The cursor belongs to the roster it was pointing at: a new machine's
    // rows are not the rows the user was walking (Mac clears `browseCursor`
    // on every highlight move, `MachineChooserView.swift:1328`).
    self.cursor = chooser_sessions.no_cursor;
    self.killed_count = 0;
    // Bump the serial so a reply already in flight for the OLD machine is
    // dropped instead of adopted under the new machine's name.
    self.serial +%= 1;
    self.inflight = false;
}

/// Start a roster fetch (optionally ending `kill_id` first) on a detached
/// thread. `chooser_id` identifies the chooser the reply belongs to; the reply
/// is matched on it, never on a pointer, so a chooser that closed in the
/// meantime cannot be written through.
///
/// Resolving the WARM connection happens HERE, on the GUI thread, because that
/// is where `LocalAgent`'s state lives. The blocking part is all the worker
/// does; when there is no warm connection the worker dials the EXISTING agent
/// itself and frees that probe afterwards — browsing must never SPAWN an agent.
/// A `.remote` target skips all of that and dials the relay instead, freeing
/// that connection when it is done: per-machine browse connections are
/// short-lived (`SessionBrowserProbe.swift:145-149`), unlike the local agent's
/// warm one, which `LocalAgent` owns and this never frees.
pub fn fetch(
    self: *SessionRoster,
    app: *App,
    chooser_id: u64,
    kill_id: ?[]const u8,
) void {
    if (comptime builtin.os.tag != .windows) return;
    if (self.target == .none) return;
    const msg_hwnd = app.msg_hwnd orelse {
        self.state = .failed;
        return;
    };

    self.serial +%= 1;
    if (self.owned == null) self.state = .loading;

    const req = self.alloc.create(Request) catch {
        self.state = .failed;
        return;
    };
    req.* = .{
        .alloc = self.alloc,
        .hwnd = msg_hwnd,
        .chooser_id = chooser_id,
        .serial = self.serial,
        // A remote target never borrows the local agent's connection — that
        // would silently list THIS box's sessions under another machine's name.
        .warm = if (self.target == .local) app.local_agent.sharedConnectionIfWarm() else null,
        .kill_id = null,
    };
    if (self.target == .remote) {
        // No credential at all is the signed-out case, and it gets the SAME
        // actionable sentence a rejected one does — "couldn't reach it" would
        // send the user looking at the network.
        const r = self.remote orelse {
            req.destroy();
            self.state = .unauthorized;
            return;
        };
        req.remote = OwnedRemote.dupe(self.alloc, r) orelse {
            req.destroy();
            self.state = .failed;
            return;
        };
    }
    if (kill_id) |k| {
        req.kill_id = self.alloc.dupe(u8, k) catch {
            req.destroy();
            self.state = .failed;
            return;
        };
    }

    const thread = std.Thread.spawn(.{}, worker, .{req}) catch |err| {
        log.warn("chooser roster: fetch thread spawn failed err={}", .{err});
        req.destroy();
        self.state = .failed;
        return;
    };
    thread.detach();
    self.inflight = true;
}

fn worker(req: *Request) void {
    defer req.destroy();
    const alloc = req.alloc;

    var probe: ?tcp_dial.Dialed = null;
    var relay: ?relay_dial.Dialed = null;
    var unauthorized = false;
    const conn: ?*remote_connection.Connection = if (req.remote) |r| blk: {
        // A REMOTE machine: dial the relay, read, free. Short-lived by design
        // — a browse must not leave a connection open to every machine the user
        // clicked through.
        relay = relay_dial.dial(alloc, r.base, r.device, r.token, .raw) catch |err| {
            log.warn("chooser roster: relay dial failed device={s} err={}", .{ r.device, err });
            unauthorized = err == error.WebSocketUnauthorized;
            break :blk null;
        };
        log.info("chooser roster: relay dialled device={s}", .{r.device});
        break :blk relay.?.conn;
    } else req.warm orelse blk: {
        // No warm connection: dial the agent that is ALREADY running. Never
        // spawn one — browsing a roster must not start a daemon.
        probe = LocalAgent.dialProbe(alloc);
        break :blk if (probe) |p| p.conn else null;
    };
    defer if (probe) |*p| p.deinit();
    // The relay connection is ours alone, so it is freed here. The local
    // agent's warm one is `LocalAgent`'s and is never touched.
    defer if (relay) |*r| r.deinit();

    var killed_ok: ?bool = null;
    var roster: ?remote_connection.OwnedSessions = null;
    if (conn) |c| {
        if (req.kill_id) |id| {
            killed_ok = c.closeSession(id, rpc_timeout_ns) catch |err| ok: {
                // `error.Unsupported` is an OLDER AGENT, not a failure to
                // report: the capability was never advertised, so the button
                // should have been disabled. Logged, reported as not-killed.
                log.warn("chooser roster: close session failed err={}", .{err});
                break :ok false;
            };
        }
        roster = c.requestSessions(rpc_timeout_ns) catch |err| r: {
            log.warn("chooser roster: LIST_SESSIONS failed err={}", .{err});
            break :r null;
        };
    }
    // T328 (resolved): a Kill on a REMOTE row used to lose its connection here
    // — both RPCs came back `error.ConnectionClosed`/`error.Timeout` — but the
    // defect was never in this worker: the agent's per-connection push pumps
    // could outlive their connection and write freed memory (fixed alongside
    // T420), and each roster dial/deinit cycle armed exactly that window. Do
    // NOT add a retry-on-fresh-dial here: one was tried and WEDGED the worker
    // (`relay_dial.dial`'s upgrade read has no deadline), which is worse than
    // a stale count. `chooser-sessions-remote.ps1` asserts the refetch lands.

    const res = alloc.create(Result) catch {
        if (roster) |*r| r.deinit();
        return;
    };
    res.* = .{
        .alloc = alloc,
        .chooser_id = req.chooser_id,
        .serial = req.serial,
        .roster = roster,
        .killed_ok = killed_ok,
        .unauthorized = unauthorized,
    };
    if (w32.PostMessageW(req.hwnd, WM_APP_CHOOSER_SESSIONS, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}

/// GUI thread: take ownership of a landed fetch. Returns true when it was
/// adopted — a stale serial is dropped, so the caller knows not to repaint.
pub fn adopt(self: *SessionRoster, res: *Result) bool {
    if (res.serial != self.serial) {
        log.debug("chooser roster: dropping a stale reply serial={d}", .{res.serial});
        return false;
    }
    self.inflight = false;

    if (res.roster) |r| {
        if (self.owned) |*old| old.deinit();
        self.owned = r;
        res.roster = null; // adopted
        self.state = .loaded;
        self.pruneKilled();
        // The acceptance oracle: an owner-drawn roster has no HWNDs to read
        // back, so what it LOADED is said out loud (T318) — WITH the machine it
        // loaded from (T319), because "5 sessions" is the same sentence whether
        // they came from this box or the one the user clicked.
        log.info("chooser roster: loaded {d} session(s) target={s} device={s}", .{
            self.owned.?.sessions.len,
            @tagName(self.target),
            self.targetDevice(),
        });
        if (res.killed_ok) |ok| {
            log.info("chooser roster: close session confirmed={}", .{ok});
        }
    } else {
        // A failed fetch does not erase a roster we already have: showing the
        // last known list beats blanking the region on one hiccup.
        if (self.owned == null) self.state = if (res.unauthorized) .unauthorized else .failed;
        log.info("chooser roster: fetch failed target={s} device={s} state={s}", .{
            @tagName(self.target),
            self.targetDevice(),
            @tagName(self.state),
        });
    }
    self.scroll = 0;
    return true;
}

/// The target's device id for logging, or `-` when there is no device (the
/// local agent, or no selection at all).
fn targetDevice(self: *const SessionRoster) []const u8 {
    return switch (self.target) {
        .remote => |id| id,
        else => "-",
    };
}

/// Optimistically hide a session the user just killed.
pub fn markKilled(self: *SessionRoster, id: []const u8) void {
    if (self.killed_count >= max_killed) return;
    if (id.len > max_id_len) return;
    const i = self.killed_count;
    @memcpy(self.killed[i][0..id.len], id);
    self.killed_len[i] = id.len;
    self.killed_count = i + 1;
}

fn isKilled(self: *const SessionRoster, id: []const u8) bool {
    for (0..self.killed_count) |i| {
        if (std.mem.eql(u8, self.killed[i][0..self.killed_len[i]], id)) return true;
    }
    return false;
}

/// Drop hidden ids the agent no longer lists — the kill is confirmed, so the
/// hide has done its job and must not outlive it (a recycled id would
/// otherwise stay invisible).
fn pruneKilled(self: *SessionRoster) void {
    const roster = self.owned orelse return;
    var out: usize = 0;
    for (0..self.killed_count) |i| {
        const id = self.killed[i][0..self.killed_len[i]];
        var still_there = false;
        for (roster.sessions) |s| {
            if (std.mem.eql(u8, s.id, id)) still_there = true;
        }
        if (!still_there) continue;
        if (out != i) {
            @memcpy(self.killed[out][0..id.len], id);
            self.killed_len[out] = id.len;
        }
        out += 1;
    }
    self.killed_count = out;
}

// ---------------------------------------------------------------------
// The visible rows
// ---------------------------------------------------------------------

/// Cap on rendered roster rows. Bounds the fixed-size scratch every caller
/// keeps; a machine with more live sessions than this is not a case the
/// chooser's fixed 840x540 can show anyway.
pub const max_rows = 128;

pub const VisibleRow = struct {
    session: chooser_sessions.Session,
    /// The live pane title bound to this session, when one of our panes has it
    /// open. Borrows the surface's own title.
    live_title: ?[]const u8 = null,
    /// The saved layout title. Borrows the manifest.
    persisted_title: ?[]const u8 = null,
    open_locally: bool = false,
};

/// The rows worth rendering, in agent order: connectable (alive OR a
/// relaunchable tombstone), minus anything the user just killed. Fills the
/// caller's buffer and returns its filled prefix.
pub fn visible(self: *const SessionRoster, app: *App, out: []VisibleRow) []const VisibleRow {
    const roster = self.owned orelse return out[0..0];
    var n: usize = 0;
    for (roster.sessions) |s| {
        if (n >= out.len) break;
        const row: chooser_sessions.Session = .{
            .id = s.id,
            .alive = s.alive,
            .relaunchable = s.relaunchable,
            .exit_code = s.exit_code,
            .attached = s.attached,
            .activity = s.activity,
            .pid = s.pid,
            .title = s.title,
            .cwd = s.cwd,
            .argv = s.argv,
        };
        if (!chooser_sessions.isConnectable(row)) continue;
        if (self.isKilled(s.id)) continue;

        // The live rung works for a remote machine too: a pane of ours attached
        // to one of ITS sessions carries that session's id. The manifest rung
        // does not — the saved layout is this box's, so its titles say nothing
        // about another machine and matching one would be a coincidence.
        const live = liveTitleFor(app, s.id);
        out[n] = .{
            .session = row,
            .live_title = live,
            .persisted_title = if (self.target == .local) self.persistedTitleFor(s.id) else null,
            .open_locally = live != null,
        };
        n += 1;
    }
    return out[0..n];
}

/// How many of this machine's sessions are ALIVE — the datum "Restore All" is
/// gated on (`chooser_sessions.restoreAllAvailable`, T335). Counted off the same
/// set `visible` renders, so an optimistically-killed session is gone from both
/// and the button cannot outlive the rows that justify it. NOT capped at
/// `max_rows`: the gate is a property of the machine, not of what fits on
/// screen.
pub fn aliveCount(self: *const SessionRoster) usize {
    const roster = self.owned orelse return 0;
    var n: usize = 0;
    for (roster.sessions) |s| {
        if (self.isKilled(s.id)) continue;
        // One predicate for "can this be attached", shared with the per-session
        // resume — a tombstone is listed but is not alive.
        if (chooser_sessions.isResumable(.{ .id = s.id, .alive = s.alive })) n += 1;
    }
    return n;
}

/// The title of an OPEN pane bound to `id`, or null. Also the answer to "is
/// this session open in one of our windows", which is what turns the badge from
/// `attached` (someone else holds it) into `open` (you do).
fn liveTitleFor(app: *App, id: []const u8) ?[]const u8 {
    for (app.windows.items) |win| {
        for (0..win.tab_count) |t| {
            var it = win.tab_trees[t].iterator();
            while (it.next()) |entry| {
                // The LIVE id off the pane's remote backend, not the surface's
                // `remote_session_id` — that one is only set when a pane
                // ATTACHES to a restored session, so a freshly OPENed
                // persistent pane has none and every pane on screen would be
                // badged `attached` (someone else has it) instead of `open`
                // (you do). Same source `captureLeaf` writes the manifest from.
                const s2 = entry.view.surface() orelse continue;
                if (!s2.core_surface_ready) continue;
                const sid = s2.core_surface.remoteSessionId() orelse continue;
                if (!std.mem.eql(u8, sid, id)) continue;
                // An open pane with no title yet still means OPEN, so report an
                // empty string rather than null — the ladder treats empty as an
                // absent rung and falls through, and the caller reads non-null
                // as "ours".
                return if (s2.title) |t2| t2 else "";
            }
        }
    }
    return null;
}

fn persistedTitleFor(self: *const SessionRoster, id: []const u8) ?[]const u8 {
    const parsed = self.manifest orelse return null;
    for (parsed.value.windows) |win| {
        for (win.tabs) |tab| {
            for (tab.nodes) |node| {
                const leaf = node.leaf orelse continue;
                const sid = leaf.session_id orelse continue;
                if (std.mem.eql(u8, sid, id)) return leaf.title;
            }
        }
    }
    return null;
}

/// The pane id the saved layout recorded for `id`, or null. A resumed pane
/// re-adopts it (T113): the shell we are ATTACHing to is still running with
/// that value baked into `$GHOZTTY_PANE_ID`, so handing it a fresh one would
/// break the pane's ability to name itself. Only meaningful for the LOCAL
/// machine — the manifest is this box's.
pub fn persistedPaneIdFor(self: *const SessionRoster, id: []const u8) ?[]const u8 {
    if (self.target != .local) return null;
    const parsed = self.manifest orelse return null;
    for (parsed.value.windows) |win| {
        for (win.tabs) |tab| {
            for (tab.nodes) |node| {
                const leaf = node.leaf orelse continue;
                const sid = leaf.session_id orelse continue;
                if (std.mem.eql(u8, sid, id)) return leaf.pane_id;
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------

/// What the roster needs from the chooser to draw itself: the region, the
/// surface it composites on, and the two fonts it uses. Passed rather than
/// imported so this file never reaches back into the dialog.
pub const PaintCtx = struct {
    hdc: w32.HDC,
    region: chooser_layout.Rect,
    scale: f32,
    bg: chooser_sessions.Rgb,
    /// The user's accent, already floored against `bg` by the caller — the same
    /// value the machine list's selected pill is painted with, so the keyboard
    /// cursor reads as the same selection (T320).
    accent: chooser_sessions.Rgb,
    /// Body semibold — the session's name.
    label_font: ?*anyopaque,
    /// Caption — the sublines and the badges.
    caption_font: ?*anyopaque,
};

fn rgb(c: chooser_sessions.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

fn rect(r: chooser_layout.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// Total height of the roster's cards at `scale`, for the scroll clamp.
pub fn contentHeight(rows: []const VisibleRow, scale: f32) i32 {
    const m = chooser_sessions.metrics(scale);
    var h: i32 = 0;
    for (rows, 0..) |row, i| {
        if (i > 0) h += m.row_gap;
        h += chooser_sessions.rowHeight(m, chooser_sessions.sublineCount(row.session));
    }
    return h;
}

/// Paint the region. Loading / failed / empty are single centered lines; a
/// loaded roster is a stack of cards clipped to the region and offset by the
/// scroll.
pub fn paint(self: *const SessionRoster, ctx: PaintCtx, rows: []const VisibleRow) void {
    const hdc = ctx.hdc;
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    if (self.target == .none) return;

    if (self.state != .loaded or rows.len == 0) {
        const text = chooser_sessions.stateText(self.state) orelse chooser_sessions.empty_text;
        var r = rect(ctx.region);
        const old = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
        _ = w32.SetTextColor(hdc, rgb(chrome_theme.textSecondaryOn(ctx.bg)));
        var wbuf: [128]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
        _ = w32.DrawTextW(
            hdc,
            &wbuf,
            @intCast(wlen),
            &r,
            w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
        if (old) |o| _ = w32.SelectObject(hdc, o);
        return;
    }

    const m = chooser_sessions.metrics(ctx.scale);
    // Clip to the region so a card that runs past the bottom is cut, not drawn
    // over the footer.
    _ = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, -1);
    _ = w32.IntersectClipRect(
        hdc,
        ctx.region.left,
        ctx.region.top,
        ctx.region.right,
        ctx.region.bottom,
    );

    var y = ctx.region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = chooser_sessions.rowLayout(m, ctx.region.left, y, ctx.region.width(), subs);
        y = l.card.bottom + m.row_gap;
        // Fully above or below the region: nothing to draw.
        if (l.card.bottom <= ctx.region.top or l.card.top >= ctx.region.bottom) continue;
        self.paintRow(ctx, m, l, row, @intCast(i));
    }
}

fn paintRow(
    self: *const SessionRoster,
    ctx: PaintCtx,
    m: chooser_sessions.Metrics,
    l: chooser_sessions.RowLayout,
    row: VisibleRow,
    index: i32,
) void {
    const hdc = ctx.hdc;
    const hovered = self.hover_kill == index;
    const cursored = self.cursor == index;
    // Everything on the card composites against the card's OWN surface, so a
    // cursored card's text and badges are floored against the accent wash they
    // actually sit on rather than against the plain card (the T206 rule).
    const card_bg = if (cursored)
        chooser_sessions.cursorFill(ctx.bg, ctx.accent)
    else
        chooser_sessions.cardFill(ctx.bg);

    // The card, plus the cursor's ring — the mark is never fill alone, so the
    // cursor survives a low-contrast accent and a color-blind reading (§2.4).
    fillRound(hdc, l.card, m.radius, card_bg);
    if (cursored) {
        strokeRound(
            hdc,
            l.card,
            m.radius,
            chooser_sessions.cursorBorder(ctx.bg, ctx.accent),
            @max(@as(i32, @intFromFloat(@round(ctx.scale))), 1),
        );
    }

    // Liveness: filled dot when alive, hollow ring for a tombstone — shape as
    // well as color, so the state survives a color-blind reading (§2.4).
    const dot_ink = chooser_sessions.dotInk(card_bg, row.session.alive);
    drawDot(hdc, l.dot, dot_ink, row.session.alive);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    // The label, then the badge run packed after its MEASURED width (a width
    // that comes from text metrics is measured, never re-derived).
    var lbuf: [32]u8 = undefined;
    const text = chooser_sessions.label(&lbuf, row.session, row.live_title, row.persisted_title);

    const old_label = if (ctx.label_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, rgb(chrome_theme.textOn(card_bg)));

    var badge_buf: [2]chooser_sessions.Badge = undefined;
    var exit_buf: [32]u8 = undefined;
    const run = chooser_sessions.badges(&badge_buf, &exit_buf, row.session, row.open_locally);

    // Reserve the badges' width so a long name ellipsizes instead of pushing
    // them out of the card.
    var badges_w: i32 = 0;
    if (run.len > 0) {
        const old_caption = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
        for (run) |b| badges_w += measure(hdc, b.text) + m.badge_pad_x * 2 + m.badge_gap;
        if (old_caption) |o| _ = w32.SelectObject(hdc, o);
    }

    var title_rect = rect(l.title);
    title_rect.right = @max(title_rect.right - badges_w, title_rect.left);
    const title_w = @min(measure(hdc, text), title_rect.right - title_rect.left);
    drawText(hdc, text, &title_rect);
    if (old_label) |o| _ = w32.SelectObject(hdc, o);

    if (run.len > 0) {
        const old_caption = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
        var bx = l.title.left + title_w + m.badge_gap;
        for (run) |b| {
            const w = measure(hdc, b.text);
            const box = chooser_sessions.badgeBox(m, bx, l.title, w);
            if (box.right > l.title.right) break;
            fillRound(hdc, box, m.badge_radius, chooser_sessions.badgeFill(card_bg, b.tone));
            var br = rect(box);
            _ = w32.SetTextColor(hdc, rgb(chooser_sessions.badgeInk(card_bg, b.tone)));
            drawTextCentered(hdc, b.text, &br);
            bx = box.right + m.badge_gap;
        }
        if (old_caption) |o| _ = w32.SelectObject(hdc, o);
    }

    // Sublines: cwd first (head-truncated, like Mac — the tail of a path is
    // what identifies it), then the command.
    const old_sub = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, rgb(chrome_theme.textSecondaryOn(card_bg)));
    var line = l.cwd;
    if (row.session.cwd) |cwd| {
        if (cwd.len > 0) {
            var r = rect(line);
            drawTextPathEllipsis(hdc, cwd, &r);
            line = l.argv;
        }
    }
    if (row.session.argv) |argv| {
        if (argv.len > 0) {
            var r = rect(line);
            drawText(hdc, argv, &r);
        }
    }
    if (old_sub) |o| _ = w32.SelectObject(hdc, o);

    // Kill: the app's one icon button, lit on hover like every other.
    drawKill(hdc, ctx, m, l.kill, hovered, card_bg);
}

fn drawKill(
    hdc: w32.HDC,
    ctx: PaintCtx,
    m: chooser_sessions.Metrics,
    box: chooser_layout.Rect,
    hovered: bool,
    card_bg: chooser_sessions.Rgb,
) void {
    _ = m;
    const im: icon_button.Metrics = .init(ctx.scale);
    if (hovered) {
        const dark = chrome_theme.textOn(card_bg).r > 0x80;
        const delta = icon_button.fillDelta(.hover, dark);
        const fill: chooser_sessions.Rgb = .{
            .r = icon_button.shadeChannel(card_bg.r, delta),
            .g = icon_button.shadeChannel(card_bg.g, delta),
            .b = icon_button.shadeChannel(card_bg.b, delta),
        };
        fillRound(hdc, .{
            .left = box.left + im.inset,
            .top = box.top + im.inset,
            .right = box.right - im.inset,
            .bottom = box.bottom - im.inset,
        }, im.corner_r, fill);
    }

    // A filled-quad "x" from the shared glyph module — never `LineTo` pen
    // strokes (§4.2: they drop the endpoint and bias wide pens to one side).
    var quads: [icon_button.max_quads]icon_button.Quad = undefined;
    const target = icon_button.glyphTarget(im, .{
        .left = box.left,
        .top = box.top,
        .right = box.right,
        .bottom = box.bottom,
    }, .close);
    const shapes = icon_button.glyphQuads(im, target, .close, &quads);
    const ink = if (hovered)
        chrome_theme.textOn(card_bg)
    else
        chrome_theme.textSecondaryOn(card_bg);
    const brush = w32.CreateSolidBrush(rgb(ink)) orelse return;
    defer _ = w32.DeleteObject(brush);
    const old = w32.SelectObject(hdc, brush);
    const pen = w32.GetStockObject(w32.NULL_PEN);
    const old_pen = w32.SelectObject(hdc, pen);
    for (shapes) |q| {
        var pts: [4]w32.POINT = undefined;
        // GDI's `Polygon` excludes the pen-less boundary, so each quad is
        // grown by one pixel on its far edges to land the same coverage the
        // pure module computed.
        for (q.pts, 0..) |p, i| pts[i] = .{ .x = p.x, .y = p.y };
        _ = w32.Polygon(hdc, &pts, 4);
    }
    _ = w32.SelectObject(hdc, old_pen);
    _ = w32.SelectObject(hdc, old);
}

fn fillRound(hdc: w32.HDC, r: chooser_layout.Rect, radius: i32, color: chooser_sessions.Rgb) void {
    const brush = w32.CreateSolidBrush(rgb(color)) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(color)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const ob = w32.SelectObject(hdc, brush);
    const op = w32.SelectObject(hdc, pen);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
    _ = w32.SelectObject(hdc, ob);
    _ = w32.SelectObject(hdc, op);
}

/// The same rounded rect, outlined instead of filled — a wide pen centered on
/// the path, so the ring is inset by half its width the way every other ring in
/// the chrome is.
fn strokeRound(
    hdc: w32.HDC,
    r: chooser_layout.Rect,
    radius: i32,
    color: chooser_sessions.Rgb,
    width: i32,
) void {
    const pen = w32.CreatePen(w32.PS_SOLID, width, rgb(color)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const ob = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_BRUSH));
    defer _ = w32.SelectObject(hdc, ob);
    const op = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, op);
    const inset = @divTrunc(width, 2);
    _ = w32.RoundRect(
        hdc,
        r.left + inset,
        r.top + inset,
        r.right - inset,
        r.bottom - inset,
        radius * 2,
        radius * 2,
    );
}

fn drawDot(hdc: w32.HDC, r: chooser_layout.Rect, color: chooser_sessions.Rgb, filled: bool) void {
    const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(color)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const brush = if (filled) w32.CreateSolidBrush(rgb(color)) else null;
    defer if (brush) |b| {
        _ = w32.DeleteObject(b);
    };
    const op = w32.SelectObject(hdc, pen);
    const ob = w32.SelectObject(hdc, brush orelse w32.GetStockObject(w32.NULL_BRUSH));
    _ = w32.Ellipse(hdc, r.left, r.top, r.right, r.bottom);
    _ = w32.SelectObject(hdc, op);
    _ = w32.SelectObject(hdc, ob);
}

fn measure(hdc: w32.HDC, text: []const u8) i32 {
    var wbuf: [256]u16 = undefined;
    if (text.len > wbuf.len) return 0;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    if (w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size) == 0) return 0;
    return size.cx;
}

fn drawText(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    drawWith(hdc, text, r, w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER |
        w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX);
}

/// A path ellipsizes in the MIDDLE: its tail is what identifies it, so
/// `DT_END_ELLIPSIS` would cut off the only part worth reading.
fn drawTextPathEllipsis(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    drawWith(hdc, text, r, w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER |
        w32.DT_PATH_ELLIPSIS | w32.DT_NOPREFIX);
}

fn drawTextCentered(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    drawWith(hdc, text, r, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX);
}

fn drawWith(hdc: w32.HDC, text: []const u8, r: *w32.RECT, flags: u32) void {
    var wbuf: [512]u16 = undefined;
    const clipped = if (text.len > wbuf.len) text[0..wbuf.len] else text;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, clipped) catch return;
    _ = w32.DrawTextW(hdc, &wbuf, @intCast(wlen), r, flags);
}

// ---------------------------------------------------------------------
// Hit testing (GUI thread)
// ---------------------------------------------------------------------

/// The visible row whose Kill button contains the client point, or null. Gaps
/// are measured to painted edges but CLICKS land on the hit box (§1.2), which
/// is why this tests `kill_hit` and the painter draws `kill`.
pub fn killAt(
    self: *const SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
    x: i32,
    y: i32,
) ?usize {
    if (x < region.left or x >= region.right) return null;
    if (y < region.top or y >= region.bottom) return null;

    const m = chooser_sessions.metrics(scale);
    var cy = region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = chooser_sessions.rowLayout(m, region.left, cy, region.width(), subs);
        cy = l.card.bottom + m.row_gap;
        if (l.kill_hit.left <= x and x < l.kill_hit.right and
            l.kill_hit.top <= y and y < l.kill_hit.bottom) return i;
    }
    return null;
}

/// The visible row whose CARD contains the client point, or null. The Kill
/// button sits inside a card, so callers test `killAt` first — one point can
/// answer both, and Kill is the more specific of the two.
pub fn rowAt(
    self: *const SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
    x: i32,
    y: i32,
) ?usize {
    if (x < region.left or x >= region.right) return null;
    if (y < region.top or y >= region.bottom) return null;

    const m = chooser_sessions.metrics(scale);
    var cy = region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = chooser_sessions.rowLayout(m, region.left, cy, region.width(), subs);
        cy = l.card.bottom + m.row_gap;
        if (l.card.left <= x and x < l.card.right and
            l.card.top <= y and y < l.card.bottom) return i;
    }
    return null;
}

/// The keyboard cursor as an index INTO `rows`, or null when it points nowhere.
/// Clamped HERE, at the point of use, rather than kept in sync with every
/// change to the roster: a refetch or an optimistic Kill can shrink the list
/// under a parked cursor, and the row that slid into its index is not the row
/// the user was pointing at.
pub fn cursorIndex(self: *SessionRoster, rows: []const VisibleRow) ?usize {
    self.cursor = chooser_sessions.clampCursor(self.cursor, rows.len);
    if (self.cursor == chooser_sessions.no_cursor) return null;
    return @intCast(self.cursor);
}

/// Scroll the cursor's card fully into the region. Returns true when the offset
/// moved. Keyboard navigation that walks off the bottom of a long roster has to
/// bring the row with it, or the highlight is somewhere the user cannot see.
pub fn scrollToCursor(
    self: *SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
) bool {
    const idx = self.cursorIndex(rows) orelse return false;
    const m = chooser_sessions.metrics(scale);

    // The card's top/bottom in CONTENT space (scroll-independent).
    var top: i32 = 0;
    var height: i32 = 0;
    for (rows, 0..) |row, i| {
        const h = chooser_sessions.rowHeight(m, chooser_sessions.sublineCount(row.session));
        if (i == idx) {
            height = h;
            break;
        }
        top += h + m.row_gap;
    }

    const before = self.scroll;
    if (top < self.scroll) {
        self.scroll = top;
    } else if (top + height > self.scroll + region.height()) {
        self.scroll = top + height - region.height();
    }
    self.scroll = chooser_sessions.clampScroll(
        self.scroll,
        contentHeight(rows, scale),
        region.height(),
    );
    return self.scroll != before;
}

/// Apply a wheel notch. Returns true when the offset actually changed, so the
/// caller only repaints when there is something new to see.
pub fn scrollBy(
    self: *SessionRoster,
    delta: i32,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
) bool {
    const before = self.scroll;
    self.scroll = chooser_sessions.clampScroll(
        self.scroll + delta,
        contentHeight(rows, scale),
        region.height(),
    );
    return self.scroll != before;
}
