//! Activity monitor machine list and carousel (T296).
//!
//! Split out of `ActivityMonitor.zig` (T299). This is where the panel learns
//! which machines exist and turns them into the strip of cards along the top:
//! the relay directory fetch and its worker, the card rebuild that merges
//! directory entries with live windows and probe results, and `switchToCard`,
//! which is the one click that moves the whole panel to another machine.
//!
//! `activity_cards.zig` is the pure half — how many cards fit, which one is
//! centred, what a summary line says. This file is the stateful half, and the
//! rule that matters here is that the card list is REBUILT rather than
//! patched: a machine that went away, a window that connected, a probe that
//! answered all land in the same place, so there is one code path deciding
//! what a card says instead of four.
//!
//! `switchToCard` hands off to the connection plane (`activity_dial.zig`) for
//! everything with a lifetime in it — tearing the old source down, borrowing a
//! window's connection, or dialing a new one.
//!
//! The commentary this file inherited from the panel's header:
//!
//! ## The machine carousel (T296)
//! Once open, the panel moves to any other source in ONE click, without opening
//! a second window (Mac's `RemoteActivityMonitorModel.switchTo`,
//! RemoteActivityMonitorView.swift:307). Three parts:
//!
//! - **The list.** Mac reads a local `MachineRegistry`; Windows' machine list is
//!   the relay directory, and `relay_directory.listDevices` is a synchronous
//!   authenticated HTTPS GET. The chooser can afford that on the GUI thread
//!   because it is a modal dialog with a spinner; a non-modal panel cannot, so
//!   the fetch runs on a detached thread and lands as
//!   `WM_APP_ACTIVITY_MACHINES` on the APP's message-only window — the same
//!   outlives-the-panel reasoning as the dial.
//! - **The cards.** `activity_cards.zig` owns the ordering (Local first), the
//!   three lines of text, the status dot and the focus arithmetic. The ACTIVE
//!   source always gets a card even when the directory does not list it (a
//!   borrowed connection, a signed-out account, a machine deleted while the
//!   panel is open) — a carousel that cannot show you where you are is lying.
//! - **The switch.** `switchTo` tears the current source down, resets every
//!   view field so one machine's trend history can never bleed into another's,
//!   and starts the new one. It BUMPS `serial`, which is what makes an
//!   in-flight dial for the abandoned source land on `onDialed`'s
//!   panel-is-gone path and free itself instead of being adopted under the new
//!   machine's name.
//!
//! A sample worker started for the previous source is dropped by GENERATION
//! (`source_gen`), not by joining: joining a worker parked on a BORROWED
//! connection would freeze the GUI for up to `rpc_timeout_ns`, and a borrowed
//! connection cannot be `shutdown` to cut it short — it is a live window's
//! shell.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ActivityMonitor = @import("ActivityMonitor.zig");
const dial_mod = @import("activity_dial.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const borrow_mod = @import("activity_borrow.zig");
const cards_mod = @import("activity_cards.zig");
const probe_mod = @import("activity_probe.zig");
const layout_mod = @import("activity_layout.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");

const Source = ActivityMonitor.Source;
const WM_APP_ACTIVITY_MACHINES = ActivityMonitor.WM_APP_ACTIVITY_MACHINES;
const log = ActivityMonitor.log;
const max_monitors = ActivityMonitor.max_monitors;
const max_source_id = ActivityMonitor.max_source_id;
const max_source_label = ActivityMonitor.max_source_label;
const panelMatches = ActivityMonitor.panelMatches;
const slotFor = ActivityMonitor.slotFor;

const beginMetrics = dial_mod.beginMetrics;
const borrowFromWindow = dial_mod.borrowFromWindow;
const resetForNewSource = dial_mod.resetForNewSource;
const startDial = dial_mod.startDial;
const teardownSource = dial_mod.teardownSource;

// ---------------------------------------------------------------------
// Machine list (the carousel's sources)
// ---------------------------------------------------------------------

/// Machines the carousel offers besides Local. `activity_cards.max_cards`
/// counts Local, so this is one fewer.
pub const max_machines: usize = cards_mod.max_cards - 1;

/// One machine, held BY VALUE. The relay's parsed device list lives in an arena
/// that is freed the moment the fetch returns, and the panel outlives every
/// fetch — so nothing here may be a slice into somebody else's memory. Fixed
/// buffers also make the whole result one flat heap object to hand between
/// threads, with no arena to keep alive and no per-string free to get wrong.
pub const MachineEntry = struct {
    id: [max_source_id]u8 = @splat(0),
    id_len: usize = 0,
    name: [max_source_label]u8 = @splat(0),
    name_len: usize = 0,
    /// The directory's own liveness flag — the fallback an INACTIVE card
    /// reports when no probe has reached that machine (T298), and all it ever
    /// reported before probes existed.
    online: bool = false,
    /// Which transport a PROBE would dial this machine over (T298). It travels
    /// with the entry rather than being guessed from the id, because a relay
    /// device id and a `host:port` are both opaque strings — a directory entry
    /// is always `.relay`, and a window entry is whatever that window rode in
    /// on.
    kind: probe_mod.Kind = .relay,

    pub fn idSlice(self: *const MachineEntry) []const u8 {
        return self.id[0..self.id_len];
    }

    fn nameSlice(self: *const MachineEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Copy one device in, truncating rather than refusing: a machine with an
    /// absurd id is still switchable, and the id is only ever compared against
    /// another copy of itself.
    fn set(self: *MachineEntry, id: []const u8, name: []const u8, online: bool) void {
        self.setKind(id, name, online, .relay);
    }

    fn setKind(
        self: *MachineEntry,
        id: []const u8,
        name: []const u8,
        online: bool,
        kind: probe_mod.Kind,
    ) void {
        self.id_len = @min(id.len, self.id.len);
        @memcpy(self.id[0..self.id_len], id[0..self.id_len]);
        self.name_len = @min(name.len, self.name.len);
        @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
        self.online = online;
        self.kind = kind;
    }
};

/// A finished machine-list fetch, in flight to the GUI thread. Owned by the
/// handler, which frees it.
pub const MachineListResult = struct {
    alloc: Allocator,
    slot: usize,
    serial: u64,
    count: usize = 0,
    entries: [max_machines]MachineEntry = @splat(.{}),

    pub fn destroy(self: *MachineListResult) void {
        self.alloc.destroy(self);
    }
};

/// Everything the list thread needs, heap-owned so it outlives the call that
/// spawned it. The thread frees it.
pub const MachineListRequest = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    slot: usize,
    serial: u64,
    base: []u8,
    token: []u8,

    pub fn destroy(self: *MachineListRequest) void {
        const alloc = self.alloc;
        alloc.free(self.base);
        alloc.free(self.token);
        alloc.destroy(self);
    }
};

// ---------------------------------------------------------------------
// Machine list + carousel
// ---------------------------------------------------------------------

/// Kick off the relay device-list fetch on a detached thread. Credentials are
/// resolved HERE, on the GUI thread, for the same reason the dial does it: the
/// account store lives on this side.
///
/// Signed out is not an error — it is a panel with one source, which paints no
/// carousel at all (design system §6).
pub fn startMachineList(self: *ActivityMonitor) void {
    const alloc = self.app.core_app.alloc;
    const msg_hwnd = self.app.msg_hwnd orelse return;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = IpcHandlers.resolveToken(arena) orelse {
        log.info("activity monitor: no relay credential, carousel shows local sources only", .{});
        return;
    };
    const base = relay_directory.resolveBase(arena) catch return;

    const req = alloc.create(MachineListRequest) catch return;
    req.* = .{
        .alloc = alloc,
        .hwnd = msg_hwnd,
        .slot = self.slot,
        .serial = self.serial,
        .base = alloc.dupe(u8, base) catch {
            alloc.destroy(req);
            return;
        },
        .token = undefined,
    };
    req.token = alloc.dupe(u8, token) catch {
        alloc.free(req.base);
        alloc.destroy(req);
        return;
    };

    const thread = std.Thread.spawn(.{}, machineListWorker, .{req}) catch |err| {
        log.warn("activity monitor: machine-list thread spawn failed err={}", .{err});
        req.destroy();
        return;
    };
    thread.detach();
}

/// The detached fetch. Owns `req`; copies every device out of the parsed arena
/// BEFORE that arena dies, and hands the GUI thread one flat result.
pub fn machineListWorker(req: *MachineListRequest) void {
    defer req.destroy();
    const alloc = req.alloc;

    const res = alloc.create(MachineListResult) catch return;
    res.* = .{ .alloc = alloc, .slot = req.slot, .serial = req.serial };

    if (relay_directory.listDevices(alloc, req.base, req.token)) |parsed| {
        defer parsed.deinit();
        for (parsed.value.devices) |dev| {
            if (res.count == res.entries.len) {
                log.warn("activity monitor: more than {d} machines, carousel shows the first {d}", .{
                    parsed.value.devices.len,
                    res.entries.len,
                });
                break;
            }
            res.entries[res.count].set(dev.id, dev.name, dev.online);
            res.count += 1;
        }
    } else |err| {
        // A directory we cannot reach is a carousel with fewer cards, not a
        // broken panel: the active source and Local are always switchable.
        log.warn("activity monitor: machine list failed err={}", .{err});
    }

    if (w32.PostMessageW(req.hwnd, WM_APP_ACTIVITY_MACHINES, @intFromPtr(res), 0) == 0) {
        res.destroy();
    }
}

/// GUI thread (App.msgWndProc): a machine list arrived. Takes ownership of
/// `res`.
pub fn onMachines(res: *MachineListResult) void {
    defer res.destroy();

    var serials: [max_monitors]?u64 = @splat(null);
    for (ActivityMonitor.open_wins, 0..) |maybe, i| {
        if (maybe) |p| {
            if (!p.closing) serials[i] = p.serial;
        }
    }
    if (!panelMatches(&serials, res.slot, res.serial)) {
        log.info("activity monitor: machine list landed after its panel closed slot={d}", .{res.slot});
        return;
    }

    const self = ActivityMonitor.open_wins[res.slot].?;
    self.machine_count = @min(res.count, self.machines.len);
    for (self.machines[0..self.machine_count], res.entries[0..self.machine_count]) |*dst, src| {
        dst.* = src;
    }
    rebuildCards(self);
    // Probe the machines this list just introduced (T298). After the rebuild,
    // because `rebuildCards` is what re-derives `win_machines` and the probe set
    // spans both lists.
    self.syncProbes();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The summary a card paints. The ACTIVE card prefers what the panel actually
/// knows (Mac's `summary(for:)`, :266); every other card prefers its PROBE
/// (T298), and falls back to the directory's flag when no probe has reached it
/// — which is all any inactive card had before probes existed.
pub fn cardSummary(self: *ActivityMonitor, local: bool, id: []const u8, online: bool) cards_mod.Summary {
    const active = switch (self.source) {
        .local => local,
        .remote => |r| !local and std.mem.eql(u8, r.id, id),
    };
    if (!active) {
        if (local) {
            if (self.local_card) |h| return .{
                .state = .live,
                .online = true,
                .uptime_s = h.uptime_s orelse 0,
                .cpu_pct = h.cpu_pct,
                .mem_used = h.mem_used,
                .mem_total = h.mem_total,
            };
        } else if (self.probeSummary(id)) |s| return s;
        return .{ .state = .idle, .online = if (local) true else online };
    }

    if (self.dialing) return .{ .state = .connecting };
    const snap = self.snap orelse return .{
        .state = if (self.refresh_failed) .failed else .connecting,
    };
    if (self.refresh_failed and self.order_len == 0) return .{ .state = .failed };
    return .{
        .state = .live,
        .online = true,
        // An agent that does not report uptime leaves it null, and the card's
        // second line falls back to "—" rather than claiming "up 0m".
        .uptime_s = snap.host.uptime_s orelse 0,
        .cpu_pct = snap.host.cpu_pct,
        .mem_used = snap.host.mem_used,
        .mem_total = snap.host.mem_total,
    };
}

/// Re-derive the card list from the machine list and the active source, then
/// re-place the chrome if the carousel appeared or disappeared.
///
/// Cheap and idempotent: called at open, when the machine list lands, on every
/// adopted snapshot (the active card's numbers are live) and after a switch.
pub fn rebuildCards(self: *ActivityMonitor) void {
    const had = cards_mod.hasCarousel(self.card_count);
    const first = self.card_count == 0;

    var n: usize = 0;
    self.cards[n] = .{
        .local = true,
        .label = "Local",
        .summary = cardSummary(self, true, "", true),
    };
    n += 1;

    for (self.machines[0..self.machine_count]) |*m| {
        if (n == self.cards.len) break;
        const id = m.idSlice();
        self.cards[n] = .{
            .local = false,
            .id = id,
            .label = if (m.name_len > 0) m.nameSlice() else id,
            .summary = cardSummary(self, false, id, m.online),
        };
        n += 1;
    }

    // Machines a live WINDOW is connected to (T301). Without these the panel
    // can leave a borrowed machine and never get back: the relay directory does
    // not list a `127.0.0.1:PORT` box at all, and lists nothing whatsoever with
    // no signed-in account, so the machine's card vanished the moment it
    // stopped being the ACTIVE source — a one-way trip to Local. These cards
    // are always reachable, because `switchToCard` borrows that window's
    // connection rather than dialing one.
    refreshWindowMachines(self);
    for (self.win_machines[0..self.win_machine_count]) |*m| {
        if (n == self.cards.len) break;
        const id = m.idSlice();
        // A machine the directory already listed keeps the directory's card:
        // that one carries the human NAME, and this one only has an id.
        if (cards_mod.indexOf(self.cards[0..n], false, id) != null) continue;
        self.cards[n] = .{
            .local = false,
            .id = id,
            .label = if (m.name_len > 0) m.nameSlice() else id,
            .summary = cardSummary(self, false, id, m.online),
        };
        n += 1;
    }

    // The active source ALWAYS has a card. It can be missing from the directory
    // for reasons that are all normal: the panel borrowed a remote window's
    // connection, the account is signed out, the fetch failed, or the machine
    // was removed while the panel sat open.
    if (self.source == .remote and n < self.cards.len) {
        const id = self.source.remote.id;
        if (cards_mod.indexOf(self.cards[0..n], false, id) == null) {
            self.cards[n] = .{
                .local = false,
                .id = id,
                .label = self.source.label(),
                .summary = cardSummary(self, false, id, true),
            };
            n += 1;
        }
    }
    self.card_count = n;

    // The ring STARTS on the active card (Mac seeds it in `onAppear`, :838-841)
    // and stays where the user left it afterwards — a list that grew under the
    // ring must not yank it back and make the next arrow key go somewhere the
    // user did not ask for. `moveFocus(…, 0, …)` is the clamp that keeps it on
    // a card that still exists.
    if (first) {
        if (activeCardIndex(self)) |i| self.card_focus = @intCast(i);
    }
    self.card_focus = cards_mod.moveFocus(self.card_focus, 0, n);

    if (cards_mod.hasCarousel(n) != had) self.applyLayout();
    clampCarousel(self);
    logCarousel(self);
}

/// Re-derive `win_machines` from the app's live windows (T301). By VALUE, like
/// every other entry here: a window can close between two rebuilds, and a card
/// slicing into its freed `remote_machine` strings would outlive them.
///
/// The id is the same key `borrowFromWindow` matches on, and it doubles as the
/// label — a window knows which machine it is on, not what the user named it.
/// A directory entry for the same machine wins in `rebuildCards`, so the nicer
/// name is preferred wherever one exists.
pub fn refreshWindowMachines(self: *ActivityMonitor) void {
    var n: usize = 0;
    for (self.app.windows.items) |win| {
        if (n == self.win_machines.len) break;
        if (win.remote_dialed == null) continue;
        const machine = win.remote_machine orelse continue;

        var buf: [borrow_mod.max_id]u8 = undefined;
        const id = borrow_mod.sourceId(&buf, switch (machine) {
            .relay => |r| .{ .relay = r.device },
            .tcp => |t| .{ .tcp = .{ .host = t.host, .port = t.port } },
        }) orelse continue;

        // Two windows on one machine are one card. The first wins, which is the
        // same first-match rule the borrow itself uses.
        var seen = false;
        for (self.win_machines[0..n]) |*prev| {
            if (std.mem.eql(u8, prev.idSlice(), id)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        // `online` is not the directory's guess here — it is this app's own
        // link state for that window, which is the one thing about a machine we
        // do not have to ask anybody about.
        self.win_machines[n].setKind(
            id,
            id,
            win.reconnect.ladder == .connected,
            // The kind a PROBE would dial this machine over (T298). A window is
            // the only place that answer exists for a `127.0.0.1:PORT` box: the
            // relay directory does not list one at all.
            switch (machine) {
                .relay => .relay,
                .tcp => .tcp,
            },
        );
        n += 1;
    }
    self.win_machine_count = n;
}

/// The card index of the panel's current source, or null (which can only happen
/// with no cards at all).
pub fn activeCardIndex(self: *const ActivityMonitor) ?usize {
    return switch (self.source) {
        .local => cards_mod.indexOf(self.cards[0..self.card_count], true, ""),
        .remote => |r| cards_mod.indexOf(self.cards[0..self.card_count], false, r.id),
    };
}

pub fn clampCarousel(self: *ActivityMonitor) void {
    const l = self.layout();
    if (!cards_mod.hasCarousel(self.card_count)) {
        self.carousel_scroll = 0;
        return;
    }
    self.carousel_scroll = cards_mod.clampScroll(
        self.carousel_scroll,
        layout_mod.carouselContentWidth(@intCast(self.card_count), self.scale),
        l.carousel.width(),
    );
}

/// Scroll the focused card fully into view.
pub fn scrollCardIntoView(self: *ActivityMonitor) void {
    if (!cards_mod.hasCarousel(self.card_count)) return;
    const l = self.layout();
    // `cardRect` at scroll 0 is the card in CONTENT coordinates, which is what
    // `scrollToShow` wants.
    const r = layout_mod.cardRect(l, self.card_focus, 0, self.scale);
    self.carousel_scroll = cards_mod.scrollToShow(
        self.carousel_scroll,
        r.left,
        r.right,
        l.carousel.width(),
        layout_mod.cardMargin(self.scale),
    );
    clampCarousel(self);
}

/// The carousel's state, logged because a GDI-painted card has no text to read
/// back. The RECTS are the painter's own arithmetic — an acceptance script
/// clicks what this reports rather than re-deriving a layout it would then be
/// asserting against itself (the T257 lesson).
pub fn logCarousel(self: *ActivityMonitor) void {
    var buf: [512]u8 = undefined;
    var used: usize = 0;
    if (cards_mod.hasCarousel(self.card_count)) {
        const l = self.layout();
        for (0..self.card_count) |i| {
            const r = layout_mod.cardRect(l, @intCast(i), self.carousel_scroll, self.scale);
            const part = std.fmt.bufPrint(buf[used..], "{s}{d},{d},{d},{d}", .{
                @as([]const u8, if (used == 0) "" else ";"),
                r.left,
                r.top,
                r.right,
                r.bottom,
            }) catch break;
            used += part.len;
        }
    }

    // Each card's READOUT, which is otherwise unreadable: these are GDI-painted
    // strings with no control to query, and T298's whole subject is whether an
    // inactive card carries live numbers. One entry per card, in card order:
    //   <id or "local">/<state>/<uptime_s>/<cpu%>/<mem_used>/<mem_total>
    var sbuf: [768]u8 = undefined;
    var sused: usize = 0;
    for (self.cards[0..self.card_count]) |c| {
        const s = c.summary;
        const part = std.fmt.bufPrint(sbuf[sused..], "{s}{s}/{s}/{d}/{d}/{d}/{d}", .{
            @as([]const u8, if (sused == 0) "" else ";"),
            if (c.local) @as([]const u8, "local") else c.id,
            @tagName(s.state),
            s.uptime_s,
            @as(u32, @intFromFloat(@round(std.math.clamp(s.cpu_pct, 0, 100)))),
            s.mem_used,
            s.mem_total,
        }) catch break;
        sused += part.len;
    }

    log.info(
        "activity monitor: carousel cards={d} focus={d} active={d} scroll={d} probes={d} rects={s} states={s}",
        .{
            self.card_count,
            self.card_focus,
            if (activeCardIndex(self)) |i| @as(i64, @intCast(i)) else -1,
            self.carousel_scroll,
            self.probeCount(),
            buf[0..used],
            sbuf[0..sused],
        },
    );
}

/// Switch the panel to the card at `index` (Mac's `switchTo`, :307). One click,
/// no second window.
pub fn switchToCard(self: *ActivityMonitor, index: i32) void {
    if (index < 0 or index >= @as(i32, @intCast(self.card_count))) return;
    const card = self.cards[@intCast(index)];

    // Everything below rewrites `id_buf`/`name_buf`, and the ACTIVE card's
    // slices point straight at them. Copy first, then decide.
    var id_copy: [max_source_id]u8 = undefined;
    var name_copy: [max_source_label]u8 = undefined;
    const id_len = @min(card.id.len, id_copy.len);
    const name_len = @min(card.label.len, name_copy.len);
    @memcpy(id_copy[0..id_len], card.id[0..id_len]);
    @memcpy(name_copy[0..name_len], card.label[0..name_len]);

    const target: Source = if (card.local)
        .local
    else
        .{ .remote = .{ .id = id_copy[0..id_len], .name = name_copy[0..name_len] } };

    if (self.source.eql(target)) return;

    // One panel per source is the registry's whole promise (`openInner`), and a
    // switch has to keep it: if another panel is already showing this machine,
    // focusing it is the honest answer — two panels keyed alike would leave one
    // of them unreachable by `open` forever.
    if (slotFor(&ActivityMonitor.open_keys, target)) |other| {
        if (other != self.slot) {
            if (ActivityMonitor.open_wins[other]) |existing| {
                log.info("activity monitor: {s} is already open, focusing it", .{target.label()});
                _ = w32.ShowWindow(existing.hwnd, w32.SW_SHOW);
                _ = w32.SetForegroundWindow(existing.hwnd);
                return;
            }
        }
    }

    log.info("activity monitor: switching {s} -> {s}", .{ self.source.label(), target.label() });

    self.teardownSource();

    // A dial or a machine-list fetch already in flight for the OLD source must
    // not be adopted under the new one. Bumping the serial routes both onto
    // their panel-is-gone path, which frees whatever they were carrying.
    self.serial = ActivityMonitor.next_serial;
    ActivityMonitor.next_serial += 1;

    // Adopt the new identity into OUR buffers: `id_copy` dies with this frame.
    self.source = target;
    if (!card.local) {
        @memcpy(self.id_buf[0..id_len], id_copy[0..id_len]);
        @memcpy(self.name_buf[0..name_len], name_copy[0..name_len]);
        self.source = .{ .remote = .{
            .id = self.id_buf[0..id_len],
            .name = self.name_buf[0..name_len],
        } };
    }
    ActivityMonitor.open_keys[self.slot] = self.source;
    self.setTitle();

    self.resetForNewSource();

    if (self.source == .remote) {
        // Borrow the connection a live WINDOW is already riding to this machine
        // (T301). A fresh owned dial was the only option here before, and it is
        // wrong twice over when a window is already talking to the target: with
        // no signed-in account it just fails, while a working link sits one
        // window away, and with an account it opens a redundant second
        // connection. A direct-TCP window is the case that cannot be papered
        // over at all — it has no relay device id, so there is nothing correct
        // to re-dial. Borrowing is what the palette entry already does, and the
        // window-close release path (`releaseBorrowed`) is what makes it safe to
        // do from here, where the panel cannot see that window's lifetime.
        if (borrowFromWindow(self.app, self.source.remote.id)) |conn| {
            self.remote_conn = .{ .conn = conn, .dialed = null };
            self.beginMetrics();
            log.info("activity monitor: borrowing a window's connection source={s}", .{self.source.label()});
        } else {
            self.startDial();
        }
    }
    rebuildCards(self);
    // The machine we just LEFT wants a probe now, and the one we arrived at
    // must give its up (its card is the panel's own connection from here).
    self.syncProbes();
    self.kickSample();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}
