//! One warm, shared connection per REMOTE machine, borrowed by every feature
//! that needs to talk to that machine's agent (T461).
//!
//! This is the remote-side counterpart to `LocalAgent`'s warm shared connection,
//! and the win32 translation of Mac's `MachineConnectionPool.swift` (60ccd4f45).
//! The local agent has had a warm connection since session persistence shipped,
//! which is why the chooser's "This PC" row lists through one socket while every
//! remote row used to dial, read and free a fresh connection on EVERY roster
//! fetch — plus, for a relay machine, a whole WebSocket upgrade and relay
//! authentication each time. Both of the features stacked on top of that pay for
//! it: there is nowhere to hang a subscription (a per-session CPU meter needs a
//! connection that OUTLIVES one RPC, which a dial-read-free probe cannot host),
//! and a Kill's dial/free cycle armed exactly the window where the agent's push
//! pumps could outlive their connection (the T328 note in `SessionRoster.zig`).
//!
//! `machine_pool.zig` holds the RULES — the endpoint key, the lease refcount,
//! the re-dial cooldown, the generation check — and is unit-tested in the `none`
//! lane. This file is the resources: dial threads, `*Connection` handles, the
//! message hop back to the GUI thread, and the refcount that lets a blocking RPC
//! outlive the pool's own reference.
//!
//! ## Threading
//!
//! Every method here is GUI-THREAD ONLY except `Entry.retain`/`Entry.release`,
//! which are atomic on purpose (see below). A dial blocks — TCP connect, TLS,
//! WebSocket upgrade, HELLO handshake — so it runs on a detached thread and
//! posts its outcome as `WM_APP_MACHINE_POOL_DIALED` to the APP's message-only
//! window, never to a chooser's HWND: `DestroyWindow` discards a window's queued
//! messages, and a discarded dial would leak a whole connection.
//!
//! ## The refcount is what replaces Mac's ARC retain
//!
//! A pooled connection is used for BLOCKING calls (`LIST_SESSIONS`,
//! `CLOSE_SESSION`) on worker threads, where the last lease can drop mid-call.
//! Mac keeps the connection object alive across such a call by retaining it;
//! here `Entry` carries an atomic refcount — the pool holds one reference, and
//! each `borrow` holds another until the worker gives it back. Whoever drops the
//! last one frees the transport. That is strictly stronger than Mac's rule that
//! an invalidation must be delivered synchronously so subscribers stop touching
//! the handle before the free: a win32 link-state callback arrives on the
//! connection's own reader thread and can only ever POST to the GUI thread, so
//! synchronous delivery is not available to us — and does not need to be, since
//! a borrow the notification has not reached yet is holding the connection alive
//! by construction.
//!
//! ## What the pool deliberately does not own
//!
//! The LOCAL agent. `LocalAgent` already owns exactly this for the app's
//! lifetime, and pooling it here would mean two connections to one agent.

const MachineConnectionPool = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const machine_pool = @import("machine_pool.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted to the app's message-only window when something changed about a
/// pooled connection: `wparam` = the entry id whose link moved, `lparam` = the
/// new `LinkState.State` as an int. Also used to REPLAY a warm connection to a
/// lease that arrived after the dial (`wparam` = 0, `lparam` = the slot), which
/// is async for Mac's reason: the caller must be able to store its lease before
/// its callback runs.
pub const WM_APP_MACHINE_POOL_NOTIFY: u32 = w32.WM_APP + 27;

/// Posted to the app's message-only window when a dial finished. `wparam` = a
/// heap `*DialResult` the handler owns from that moment.
pub const WM_APP_MACHINE_POOL_DIALED: u32 = w32.WM_APP + 28;

/// How many subscribers the pool tracks at once. One per chooser region today
/// (the roster), with the CPU meter to come; far above what a session reaches.
pub const max_leases: usize = 32;

/// Why a machine is not usable. `offline` and `unauthorized` are different
/// SENTENCES to the user — "couldn't reach it" sends them to the network when
/// the answer is to sign in again — so the distinction is carried rather than
/// flattened into "failed".
pub const Failure = enum { none, offline, unauthorized };

/// The transport a pooled connection rides. Same two shapes as
/// `Window.RemoteDialed`, declared here rather than imported so the pool does
/// not reach into the window layer for a 10-line union.
const Transport = union(enum) {
    tcp: *tcp_dial.Dialed,
    relay: *relay_dial.Dialed,

    fn conn(self: Transport) *remote_connection.Connection {
        return switch (self) {
            inline else => |d| d.conn,
        };
    }

    fn deinitDestroy(self: Transport, alloc: Allocator) void {
        switch (self) {
            inline else => |d| {
                d.deinit();
                alloc.destroy(d);
            },
        }
    }
};

/// One live pooled connection. Refcounted (see the header): the pool holds one
/// reference for as long as the entry is installed, and every `borrow` holds one
/// for the length of its call.
pub const Entry = struct {
    alloc: Allocator,
    transport: Transport,
    /// This entry's pool-wide identity, monotonic for the app's life. The link
    /// callback posts it rather than a pointer, so an entry freed and its
    /// address reused cannot be mistaken for the one whose link died.
    id: u64,
    /// Where the link callback posts. Copied in at install time and never
    /// written again, which is what makes it safe to read off the connection's
    /// reader thread.
    hwnd: w32.HWND,
    refs: std.atomic.Value(u32),

    pub fn conn(self: *Entry) *remote_connection.Connection {
        return self.transport.conn();
    }

    fn retain(self: *Entry) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Give a reference back, freeing the transport when it was the last one.
    /// Safe from any thread — a worker that outlived the pool's own reference is
    /// exactly the case this exists for.
    pub fn release(self: *Entry) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.alloc;
        self.transport.deinitDestroy(alloc);
        alloc.destroy(self);
    }
};

/// The subscriber callback. Fires with the live connection when the machine
/// becomes usable and with null when it stops being (dial failed, link died). It
/// may fire more than once — a machine that comes back is re-dialed — so treat
/// it as a state feed, not a one-shot completion.
pub const OnChange = *const fn (
    ctx: *anyopaque,
    conn: ?*remote_connection.Connection,
    failure: Failure,
) void;

/// A borrow on one machine's warm connection. Holding it keeps the connection
/// dialed; releasing it may tear the connection down (if it was the last one).
pub const Lease = struct {
    key_buf: [machine_pool.max_key]u8 = undefined,
    key_len: usize = 0,
    ctx: *anyopaque,
    on_change: OnChange,
    released: bool = false,

    pub fn key(self: *const Lease) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

/// How a slot is dialed, so a re-dial after a dead link needs nothing from the
/// caller. Owned; freed with the slot. The token is REFRESHED on every acquire —
/// a rotated relay session token is the same endpoint, so it must not change the
/// key, and must not be remembered stale either.
const Recipe = union(enum) {
    relay: struct { base: []u8, device: []u8, token: []u8 },
    tcp: struct { host: []u8, port: u16 },

    fn deinit(self: Recipe, alloc: Allocator) void {
        switch (self) {
            .relay => |r| {
                alloc.free(r.base);
                alloc.free(r.device);
                alloc.free(r.token);
            },
            .tcp => |t| alloc.free(t.host),
        }
    }

    fn dupe(alloc: Allocator, ep: machine_pool.Endpoint, token: []const u8) ?Recipe {
        switch (ep) {
            .relay => |r| {
                const base = alloc.dupe(u8, r.base) catch return null;
                const device = alloc.dupe(u8, r.device) catch {
                    alloc.free(base);
                    return null;
                };
                const tok = alloc.dupe(u8, token) catch {
                    alloc.free(base);
                    alloc.free(device);
                    return null;
                };
                return .{ .relay = .{ .base = base, .device = device, .token = tok } };
            },
            .tcp => |t| {
                const host = alloc.dupe(u8, t.host) catch return null;
                return .{ .tcp = .{ .host = host, .port = t.port } };
            },
        }
    }
};

alloc: Allocator,
ledger: machine_pool.Ledger = .{},
/// The live connections, indexed by the ledger's slot. Never read by index
/// without asking the ledger for that slot first: a slot freed and re-claimed
/// belongs to a different endpoint.
entries: [machine_pool.max_entries]?*Entry = @splat(null),
recipes: [machine_pool.max_entries]?Recipe = @splat(null),
leases: [max_leases]?*Lease = @splat(null),
/// Monotonic entry ids — see `Entry.id`.
next_entry_id: u64 = 1,

pub fn init(alloc: Allocator) MachineConnectionPool {
    return .{ .alloc = alloc };
}

/// App teardown. Every lease is gone by now (a chooser releases its own on
/// close), but a lease list that is not empty is not a reason to leak: the
/// entries are freed either way.
pub fn deinit(self: *MachineConnectionPool) void {
    for (&self.leases) |*slot| {
        if (slot.*) |l| self.alloc.destroy(l);
        slot.* = null;
    }
    for (0..machine_pool.max_entries) |i| self.dropSlot(i);
}

// ---------------------------------------------------------------------
// Acquire / release
// ---------------------------------------------------------------------

/// Take a warm connection for `ep`, dialing if this is the first borrower.
/// Returns immediately — readiness arrives through `on_change`, never as a
/// return value, because a dial blocks and this runs on the GUI thread.
///
/// Null means the pool cannot serve this endpoint at all (key too long, no free
/// slot, no free lease, out of memory); the caller falls back to whatever it did
/// before the pool existed rather than silently showing nothing.
pub fn acquire(
    self: *MachineConnectionPool,
    hwnd: w32.HWND,
    ep: machine_pool.Endpoint,
    token: []const u8,
    ctx: *anyopaque,
    on_change: OnChange,
) ?*Lease {
    var kbuf: [machine_pool.max_key]u8 = undefined;
    const k = machine_pool.key(&kbuf, ep) orelse {
        log.warn("machine pool: endpoint key does not fit; not pooling it", .{});
        return null;
    };

    const lease_slot = self.freeLeaseSlot() orelse {
        log.warn("machine pool: no free lease slot ({d} held)", .{max_leases});
        return null;
    };

    const out = self.ledger.acquire(k);
    if (out.decision == .no_capacity) {
        log.warn("machine pool: every slot is taken; not pooling {s}", .{k});
        return null;
    }

    const lease = self.alloc.create(Lease) catch {
        _ = self.ledger.release(k);
        return null;
    };
    lease.* = .{ .key_len = k.len, .ctx = ctx, .on_change = on_change };
    @memcpy(lease.key_buf[0..k.len], k);
    self.leases[lease_slot] = lease;

    // Refresh the dial recipe on every acquire: same endpoint, possibly a
    // rotated token.
    self.setRecipe(out.slot, ep, token);

    switch (out.decision) {
        .dial => self.startDial(hwnd, out.slot, out.generation),
        // An in-flight dial notifies every lease on the key, this one included.
        .wait => {},
        .deliver_ready => {
            // Async, so the caller can store the lease before its callback runs
            // (Mac's reason, minus the modal hazard: a win32 posted message is
            // not swallowed by a modal loop, it is dispatched by it).
            _ = w32.PostMessageW(hwnd, WM_APP_MACHINE_POOL_NOTIFY, 0, @intCast(out.slot));
        },
        .hold, .no_capacity => {},
    }
    return lease;
}

/// Give a lease back. Tears the connection down when it was the last one.
/// Idempotent, and the lease pointer is invalid afterwards.
pub fn release(self: *MachineConnectionPool, lease: *Lease) void {
    if (lease.released) return;
    lease.released = true;
    const k = lease.key();
    // Read the slot BEFORE the ledger forgets it.
    const slot = self.ledger.find(k);
    const teardown = self.ledger.release(k);
    for (&self.leases) |*s| {
        if (s.* == lease) s.* = null;
    }
    self.alloc.destroy(lease);
    if (teardown) {
        if (slot) |i| {
            log.info("machine pool: last lease released; dropping the connection slot={d}", .{i});
            self.dropSlot(i);
        }
    }
}

/// Nudge a machine's connection back to life if it died or never came up — the
/// automatic counterpart to `acquire`, called from whatever the subscriber
/// already does periodically (for the roster, its own refetch). Honours the
/// ledger's cooldown and never dials for a machine with no leases.
pub fn ensureConnected(self: *MachineConnectionPool, hwnd: w32.HWND, ep: machine_pool.Endpoint) void {
    var kbuf: [machine_pool.max_key]u8 = undefined;
    const k = machine_pool.key(&kbuf, ep) orelse return;
    const out = self.ledger.ensure(k, std.time.milliTimestamp());
    if (out.decision == .dial) self.startDial(hwnd, out.slot, out.generation);
}

/// Borrow the machine's warm connection for a BLOCKING call, or null when it has
/// none. The returned entry carries a reference the caller MUST give back with
/// `Entry.release()` — from any thread, whenever the call is done.
pub fn borrow(self: *MachineConnectionPool, ep: machine_pool.Endpoint) ?*Entry {
    var kbuf: [machine_pool.max_key]u8 = undefined;
    const k = machine_pool.key(&kbuf, ep) orelse return null;
    const slot = self.ledger.find(k) orelse return null;
    const entry = self.entries[slot] orelse return null;
    entry.retain();
    return entry;
}

/// Whether `ep` has a live warm connection. For a decision on the GUI thread
/// only — anything that will BLOCK must go through `borrow`.
pub fn isWarm(self: *MachineConnectionPool, ep: machine_pool.Endpoint) bool {
    var kbuf: [machine_pool.max_key]u8 = undefined;
    const k = machine_pool.key(&kbuf, ep) orelse return false;
    const slot = self.ledger.find(k) orelse return false;
    return self.entries[slot] != null;
}

fn freeLeaseSlot(self: *const MachineConnectionPool) ?usize {
    for (self.leases, 0..) |l, i| {
        if (l == null) return i;
    }
    return null;
}

fn setRecipe(
    self: *MachineConnectionPool,
    slot: usize,
    ep: machine_pool.Endpoint,
    token: []const u8,
) void {
    const next = Recipe.dupe(self.alloc, ep, token) orelse return;
    if (self.recipes[slot]) |old| old.deinit(self.alloc);
    self.recipes[slot] = next;
}

/// Free the entry at `slot`, leaving the ledger and the recipe alone: a dead
/// link drops the connection but keeps the machine's leases and its way of being
/// re-dialed.
fn freeEntry(self: *MachineConnectionPool, slot: usize) void {
    const entry = self.entries[slot] orelse return;
    self.entries[slot] = null;
    // Stop it observing FIRST. `clearStateHandler` returns only once any
    // in-flight handler has finished, so after this no callback can reference
    // the entry — which is what makes `Entry` a safe handler context.
    entry.conn().clearStateHandler();
    entry.release();
}

/// Forget the slot entirely — the connection and how to re-dial it.
fn dropSlot(self: *MachineConnectionPool, slot: usize) void {
    self.freeEntry(slot);
    if (self.recipes[slot]) |r| r.deinit(self.alloc);
    self.recipes[slot] = null;
}

// ---------------------------------------------------------------------
// Dialing (worker thread)
// ---------------------------------------------------------------------

const DialRequest = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    /// The endpoint key, carried by VALUE: the ledger's slot can be freed and
    /// re-claimed by another endpoint while this dial blocks, so the key plus
    /// the generation is the only identity that cannot drift.
    key_buf: [machine_pool.max_key]u8,
    key_len: usize,
    generation: u64,
    recipe: Recipe,

    fn destroy(self: *DialRequest) void {
        self.recipe.deinit(self.alloc);
        self.alloc.destroy(self);
    }
};

pub const DialResult = struct {
    alloc: Allocator,
    /// Where notifications for the connection this carries go — the same window
    /// the dial was posted to, so `onDialed` has one source of truth for it
    /// rather than a second copy inside the pool.
    hwnd: w32.HWND,
    key_buf: [machine_pool.max_key]u8,
    key_len: usize,
    generation: u64,
    /// The dialed transport, or null when the dial failed.
    transport: ?Transport,
    failure: Failure,

    pub fn key(self: *const DialResult) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    /// Frees the transport too when it was never adopted — which is the whole
    /// reason this lands on the app's window and not on a chooser's.
    pub fn destroy(self: *DialResult) void {
        if (self.transport) |t| t.deinitDestroy(self.alloc);
        self.alloc.destroy(self);
    }
};

fn startDial(self: *MachineConnectionPool, hwnd: w32.HWND, slot: usize, generation: u64) void {
    if (comptime builtin.os.tag != .windows) return;
    const k = self.ledger.keyOf(slot);
    const recipe = self.recipes[slot] orelse {
        _ = self.ledger.dialFailed(k, generation, std.time.milliTimestamp());
        self.notify(k, null, .offline);
        return;
    };

    const req = self.alloc.create(DialRequest) catch {
        _ = self.ledger.dialFailed(k, generation, std.time.milliTimestamp());
        self.notify(k, null, .offline);
        return;
    };
    const owned = Recipe.dupe(self.alloc, switch (recipe) {
        .relay => |r| .{ .relay = .{ .base = r.base, .device = r.device } },
        .tcp => |t| .{ .tcp = .{ .host = t.host, .port = t.port } },
    }, switch (recipe) {
        .relay => |r| r.token,
        .tcp => "",
    }) orelse {
        self.alloc.destroy(req);
        _ = self.ledger.dialFailed(k, generation, std.time.milliTimestamp());
        self.notify(k, null, .offline);
        return;
    };
    req.* = .{
        .alloc = self.alloc,
        .hwnd = hwnd,
        .key_buf = undefined,
        .key_len = k.len,
        .generation = generation,
        .recipe = owned,
    };
    @memcpy(req.key_buf[0..k.len], k);

    const thread = std.Thread.spawn(.{}, dialWorker, .{req}) catch |err| {
        log.warn("machine pool: dial thread spawn failed err={}", .{err});
        req.destroy();
        _ = self.ledger.dialFailed(k, generation, std.time.milliTimestamp());
        self.notify(k, null, .offline);
        return;
    };
    thread.detach();
    log.info("machine pool: dialing {s}", .{k});
}

fn dialWorker(req: *DialRequest) void {
    defer req.destroy();
    const alloc = req.alloc;

    var transport: ?Transport = null;
    var failure: Failure = .offline;
    switch (req.recipe) {
        .relay => |r| {
            if (alloc.create(relay_dial.Dialed)) |d| {
                if (relay_dial.dial(alloc, r.base, r.device, r.token, .raw)) |ok| {
                    d.* = ok;
                    transport = .{ .relay = d };
                    failure = .none;
                } else |err| {
                    log.warn("machine pool: relay dial failed device={s} err={}", .{ r.device, err });
                    if (err == error.WebSocketUnauthorized) failure = .unauthorized;
                    alloc.destroy(d);
                }
            } else |_| {}
        },
        .tcp => |t| {
            if (alloc.create(tcp_dial.Dialed)) |d| {
                if (tcp_dial.dial(alloc, t.host, t.port, .raw)) |ok| {
                    d.* = ok;
                    transport = .{ .tcp = d };
                    failure = .none;
                } else |err| {
                    log.warn("machine pool: tcp dial failed host={s} err={}", .{ t.host, err });
                    alloc.destroy(d);
                }
            } else |_| {}
        },
    }

    const res = alloc.create(DialResult) catch {
        if (transport) |t| t.deinitDestroy(alloc);
        return;
    };
    res.* = .{
        .alloc = alloc,
        .hwnd = req.hwnd,
        .key_buf = req.key_buf,
        .key_len = req.key_len,
        .generation = req.generation,
        .transport = transport,
        .failure = failure,
    };
    if (w32.PostMessageW(req.hwnd, WM_APP_MACHINE_POOL_DIALED, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}

// ---------------------------------------------------------------------
// Landing (GUI thread)
// ---------------------------------------------------------------------

/// A dial finished. Takes ownership of `res`.
pub fn onDialed(self: *MachineConnectionPool, res: *DialResult) void {
    defer res.destroy();
    const k = res.key();

    const transport = res.transport orelse {
        if (self.ledger.dialFailed(k, res.generation, std.time.milliTimestamp())) {
            log.info("machine pool: dial failed {s} failure={s}", .{ k, @tagName(res.failure) });
            self.notify(k, null, res.failure);
        }
        return;
    };

    // Released, invalidated or re-dialed while we were blocking: this connection
    // belongs to nobody, and `destroy` above frees it.
    if (!self.ledger.dialSucceeded(k, res.generation)) {
        log.info("machine pool: a dial landed after its machine moved on; freeing it {s}", .{k});
        return;
    }
    const slot = self.ledger.find(k) orelse return;

    const entry = self.alloc.create(Entry) catch {
        _ = self.ledger.dialFailed(k, res.generation, std.time.milliTimestamp());
        self.notify(k, null, .offline);
        return;
    };
    entry.* = .{
        .alloc = self.alloc,
        .transport = transport,
        .id = self.next_entry_id,
        .hwnd = res.hwnd,
        .refs = .init(1),
    };
    self.next_entry_id +%= 1;
    res.transport = null; // adopted

    // A slot cannot already hold an entry (the ledger only says `dial` from
    // `absent`/`failed`, and both drop theirs), but be explicit rather than
    // leaking one if that ever stops being true.
    self.freeEntry(slot);
    self.entries[slot] = entry;
    entry.conn().setStateHandler(entry, onLinkChange);
    log.info("machine pool: warm connection ready {s} entry={d}", .{ k, entry.id });
    self.notify(k, entry.conn(), .none);

    // The link can die between the handshake and the handler being installed, so
    // ask once rather than waiting for an edge that has already gone past.
    if (entry.conn().state() == .dead) self.onLink(entry.id, .dead);
}

/// The link-state callback, on the CONNECTION's reader thread and under its
/// state mutex. It may not re-enter `Connection` and may not touch GUI state —
/// so it posts the entry id and gets out (the `LocalAgent.state_handler` rule).
fn onLinkChange(
    ctx: *anyopaque,
    conn: *remote_connection.Connection,
    old: remote_connection.LinkState.State,
    new: remote_connection.LinkState.State,
) void {
    _ = conn;
    _ = old;
    const entry: *Entry = @ptrCast(@alignCast(ctx));
    _ = w32.PostMessageW(
        entry.hwnd,
        WM_APP_MACHINE_POOL_NOTIFY,
        @intCast(entry.id),
        @intFromEnum(new),
    );
}

/// GUI thread: `WM_APP_MACHINE_POOL_NOTIFY`. `wparam` = 0 replays slot `lparam`
/// to its leases; anything else is the entry id whose link moved to `lparam`.
pub fn onNotify(self: *MachineConnectionPool, wparam: usize, lparam: isize) void {
    if (wparam == 0) {
        const slot: usize = @intCast(@max(lparam, 0));
        if (slot >= machine_pool.max_entries) return;
        const entry = self.entries[slot] orelse return;
        if (self.ledger.phaseOf(self.ledger.keyOf(slot)) != .ready) return;
        self.notify(self.ledger.keyOf(slot), entry.conn(), .none);
        return;
    }
    const state: remote_connection.LinkState.State =
        std.meta.intToEnum(remote_connection.LinkState.State, lparam) catch return;
    self.onLink(@intCast(wparam), state);
}

/// One connection's transport FSM moved. Only `dead` is acted on: the FSM enters
/// `reconnecting` after a few missed heartbeats and snaps back on the next
/// authentic packet, so treating a down EDGE as death would tear down working
/// connections on a scheduler hiccup — the same reasoning as
/// `agent_recovery.settle_ms`, without needing its settle window, because
/// nothing here rebuilds windows: it just re-dials.
fn onLink(self: *MachineConnectionPool, entry_id: u64, state: remote_connection.LinkState.State) void {
    if (state != .dead) return;
    const slot = self.slotForEntry(entry_id) orelse return;
    const k = self.ledger.keyOf(slot);
    const gen = self.ledger.generationOf(k) orelse return;
    if (!self.ledger.invalidate(k, gen, std.time.milliTimestamp())) return;
    log.info("machine pool: warm connection died {s}; dropping it", .{k});
    // Tell the subscribers BEFORE the free — they must stop using the handle,
    // and any borrow still holding it keeps it alive on its own.
    self.notify(k, null, .offline);
    self.freeEntry(slot);
}

fn slotForEntry(self: *const MachineConnectionPool, entry_id: u64) ?usize {
    for (self.entries, 0..) |maybe, i| {
        const e = maybe orelse continue;
        if (e.id == entry_id) return i;
    }
    return null;
}

/// Report the current truth about `k` to every lease on it. Iterates a SNAPSHOT:
/// a subscriber is allowed to release its lease from inside its own callback.
fn notify(
    self: *MachineConnectionPool,
    k: []const u8,
    conn: ?*remote_connection.Connection,
    failure: Failure,
) void {
    var snap: [max_leases]?*Lease = @splat(null);
    for (self.leases, 0..) |maybe, i| {
        const l = maybe orelse continue;
        if (l.released) continue;
        if (!std.mem.eql(u8, l.key(), k)) continue;
        snap[i] = l;
    }
    for (snap) |maybe| {
        const l = maybe orelse continue;
        // Re-check: an earlier callback in this same sweep may have released it.
        if (l.released) continue;
        l.on_change(l.ctx, conn, failure);
    }
}
