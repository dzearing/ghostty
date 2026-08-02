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

alloc: Allocator,
state: chooser_sessions.State = .loading,
/// The fetched roster. Owned; freed here and replaced whole by each adopt.
owned: ?remote_connection.OwnedSessions = null,
/// Bumped on every fetch. A reply carrying an older serial is stale — its
/// chooser has moved on — and is freed rather than adopted.
serial: u64 = 0,
inflight: bool = false,
scroll: i32 = 0,
/// Index (into the VISIBLE rows) whose Kill button is under the pointer, or -1.
hover_kill: i32 = -1,

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

    fn destroy(self: *Request) void {
        if (self.kill_id) |k| self.alloc.free(k);
        self.alloc.destroy(self);
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

    pub fn destroy(self: *Result) void {
        if (self.roster) |*r| r.deinit();
        self.alloc.destroy(self);
    }
};

/// Start a roster fetch (optionally ending `kill_id` first) on a detached
/// thread. `chooser_id` identifies the chooser the reply belongs to; the reply
/// is matched on it, never on a pointer, so a chooser that closed in the
/// meantime cannot be written through.
///
/// Resolving the WARM connection happens HERE, on the GUI thread, because that
/// is where `LocalAgent`'s state lives. The blocking part is all the worker
/// does; when there is no warm connection the worker dials the EXISTING agent
/// itself and frees that probe afterwards — browsing must never SPAWN an agent.
pub fn fetch(
    self: *SessionRoster,
    app: *App,
    chooser_id: u64,
    kill_id: ?[]const u8,
) void {
    if (comptime builtin.os.tag != .windows) return;
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
        .warm = app.local_agent.sharedConnectionIfWarm(),
        .kill_id = null,
    };
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
    const conn: ?*remote_connection.Connection = req.warm orelse blk: {
        // No warm connection: dial the agent that is ALREADY running. Never
        // spawn one — browsing a roster must not start a daemon.
        probe = LocalAgent.dialProbe(alloc);
        break :blk if (probe) |p| p.conn else null;
    };
    defer if (probe) |*p| p.deinit();

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
        // back, so what it LOADED is said out loud (T318).
        log.info("chooser roster: loaded {d} session(s)", .{self.owned.?.sessions.len});
        if (res.killed_ok) |ok| {
            log.info("chooser roster: close session confirmed={}", .{ok});
        }
    } else {
        // A failed fetch does not erase a roster we already have: showing the
        // last known list beats blanking the region on one hiccup.
        if (self.owned == null) self.state = .failed;
    }
    self.scroll = 0;
    return true;
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

        const live = liveTitleFor(app, s.id);
        out[n] = .{
            .session = row,
            .live_title = live,
            .persisted_title = self.persistedTitleFor(s.id),
            .open_locally = live != null,
        };
        n += 1;
    }
    return out[0..n];
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
                if (!entry.view.core_surface_ready) continue;
                const sid = entry.view.core_surface.remoteSessionId() orelse continue;
                if (!std.mem.eql(u8, sid, id)) continue;
                // An open pane with no title yet still means OPEN, so report an
                // empty string rather than null — the ladder treats empty as an
                // absent rung and falls through, and the caller reads non-null
                // as "ours".
                return if (entry.view.title) |t2| t2 else "";
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

    if (self.state != .loaded or rows.len == 0) {
        const text = switch (self.state) {
            .loading => chooser_sessions.loading_text,
            .failed => chooser_sessions.failed_text,
            .loaded => chooser_sessions.empty_text,
        };
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
    const card_bg = chooser_sessions.cardFill(ctx.bg);

    // The card.
    fillRound(hdc, l.card, m.radius, card_bg);

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
