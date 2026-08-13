//! The bookkeeping behind ONE warm connection per remote machine (T461).
//!
//! `MachineConnectionPool.zig` is the plumbing — dial threads, `*Connection`
//! handles, refcounts, the message hop back to the GUI thread. This module is
//! everything about the pool that is a RULE rather than a resource: what a
//! machine's identity is, and what taking or giving back a borrow means for it.
//!
//! It is split out for the reason Mac's `MachineConnectionPool.Ledger` is
//! (60ccd4f45): refcounting and re-dial policy are the parts that regress
//! silently. A connection freed while somebody still holds it crashes far from
//! the cause, and one that is never freed just leaks a socket per machine per
//! chooser opening — neither shows up as a failing pixel. Kept pure, both are
//! unit-testable in the `none` lane with no agent, no dial and no GUI thread.
//!
//! ## The identity key is the ENDPOINT
//!
//! Two chooser rows that name the same relay device (or the same `host:port`)
//! describe ONE agent, so they must share one connection. Keying by row — or by
//! chooser — would open a second socket to the same machine and, worse, would
//! make "is this machine warm" un-answerable from anywhere but the row that
//! dialed it. `activity_borrow.sourceId` keys the Activity Monitor's carousel
//! the same way and for the same reason; this key carries its scheme prefix as
//! well, because the pool holds both kinds at once and `relay:<base>|<device>`
//! must never collide with a `tcp:` key.
//!
//! ## Generations
//!
//! A dial blocks for as long as it takes; the machine can be released,
//! invalidated and re-dialed while one is in flight. Every state change that
//! makes an in-flight dial's result unwanted bumps the slot's generation, and a
//! landed dial is only installed when its generation still matches. The counter
//! is pool-wide and monotonic rather than per-slot, so a slot reused for the
//! same endpoint can never hand a stale dial a generation that matches by
//! accident.

const std = @import("std");

/// The longest endpoint key. A relay key is a whole HTTPS base plus a device id,
/// so this is generous by design; the cost is stack, and a key that does not fit
/// is REFUSED rather than truncated (a truncated key would alias two machines).
pub const max_key: usize = 320;

/// How many distinct endpoints the pool tracks at once. The chooser lists a
/// handful of machines and holds a lease only on the SELECTED one, so this is
/// far above what a session reaches; exhaustion is reported (`.no_capacity`) and
/// degrades to the pre-pool behavior rather than being silently ignored.
pub const max_entries: usize = 8;

/// A machine's transport identity, in the two shapes a remote agent can be
/// reached by.
pub const Endpoint = union(enum) {
    relay: struct { base: []const u8, device: []const u8 },
    tcp: struct { host: []const u8, port: u16 },
};

/// `ep`'s pool key, written into `buf`. Null when it does not fit — see
/// `max_key`.
pub fn key(buf: []u8, ep: Endpoint) ?[]const u8 {
    return switch (ep) {
        .relay => |r| std.fmt.bufPrint(buf, "relay:{s}|{s}", .{ r.base, r.device }) catch null,
        .tcp => |t| std.fmt.bufPrint(buf, "tcp:{s}:{d}", .{ t.host, t.port }) catch null,
    };
}

/// Where a machine's connection currently is.
pub const Phase = union(enum) {
    /// Never dialed, or torn down and forgotten.
    absent,
    /// A dial is in flight.
    dialing,
    /// A live connection exists.
    ready,
    /// The last attempt failed, or the link died, at this time (ms).
    failed: i64,
};

/// What the caller must do for a machine, given its phase.
pub const Decision = enum {
    /// Nothing live and nothing in flight — start a dial.
    dial,
    /// A dial is already in flight; this lease joins its waiters.
    wait,
    /// A warm connection exists; replay it to this lease.
    deliver_ready,
    /// Do nothing right now (too soon to retry, or nobody wants it).
    hold,
    /// Every slot is taken by another endpoint. The caller falls back to
    /// whatever it did before the pool existed rather than pretending.
    no_capacity,
};

/// A decision plus which slot it is about. `slot`/`generation` are only
/// meaningful for `.dial` (the values the completed dial must present back).
pub const Outcome = struct {
    decision: Decision,
    slot: usize = 0,
    generation: u64 = 0,
};

pub const Ledger = struct {
    pub const Slot = struct {
        used: bool = false,
        key_buf: [max_key]u8 = undefined,
        key_len: usize = 0,
        phase: Phase = .absent,
        leases: usize = 0,
        generation: u64 = 0,
    };

    slots: [max_entries]Slot = @splat(.{}),
    /// Monotonic for the pool's whole life — never reset when a slot is freed.
    next_gen: u64 = 1,
    /// How long a failed machine is left alone before an automatic retry. Only
    /// `ensure` honours it; an explicit `acquire` is the user selecting the row
    /// and always gets an attempt.
    redial_cooldown_ms: i64 = 5_000,

    pub fn keyOf(self: *const Ledger, slot: usize) []const u8 {
        return self.slots[slot].key_buf[0..self.slots[slot].key_len];
    }

    pub fn find(self: *const Ledger, k: []const u8) ?usize {
        for (&self.slots, 0..) |*s, i| {
            if (!s.used) continue;
            if (std.mem.eql(u8, s.key_buf[0..s.key_len], k)) return i;
        }
        return null;
    }

    pub fn phaseOf(self: *const Ledger, k: []const u8) Phase {
        const i = self.find(k) orelse return .absent;
        return self.slots[i].phase;
    }

    pub fn leaseCount(self: *const Ledger, k: []const u8) usize {
        const i = self.find(k) orelse return 0;
        return self.slots[i].leases;
    }

    pub fn generationOf(self: *const Ledger, k: []const u8) ?u64 {
        const i = self.find(k) orelse return null;
        return self.slots[i].generation;
    }

    fn claim(self: *Ledger, k: []const u8) ?usize {
        if (k.len == 0 or k.len > max_key) return null;
        for (&self.slots, 0..) |*s, i| {
            if (s.used) continue;
            s.* = .{ .used = true, .key_len = k.len };
            @memcpy(s.key_buf[0..k.len], k);
            return i;
        }
        return null;
    }

    fn bump(self: *Ledger, slot: usize) u64 {
        const gen = self.next_gen;
        self.next_gen +%= 1;
        self.slots[slot].generation = gen;
        return gen;
    }

    /// Take a lease on `k` and say what to do next. A FAILED machine is retried
    /// immediately here: an acquire is a deliberate act (the user selected this
    /// row), not a background tick.
    pub fn acquire(self: *Ledger, k: []const u8) Outcome {
        const i = self.find(k) orelse self.claim(k) orelse
            return .{ .decision = .no_capacity };
        self.slots[i].leases += 1;
        switch (self.slots[i].phase) {
            .ready => return .{ .decision = .deliver_ready, .slot = i, .generation = self.slots[i].generation },
            .dialing => return .{ .decision = .wait, .slot = i, .generation = self.slots[i].generation },
            .absent, .failed => {
                self.slots[i].phase = .dialing;
                return .{ .decision = .dial, .slot = i, .generation = self.bump(i) };
            },
        }
    }

    /// What to do to (re)establish `k` WITHOUT taking a lease — the automatic
    /// path, driven by whatever the caller already ticks on. Honours the
    /// cooldown, and refuses to dial for a machine nobody is holding.
    pub fn ensure(self: *Ledger, k: []const u8, now_ms: i64) Outcome {
        const i = self.find(k) orelse return .{ .decision = .hold };
        if (self.slots[i].leases == 0) return .{ .decision = .hold };
        switch (self.slots[i].phase) {
            .ready => return .{ .decision = .deliver_ready, .slot = i, .generation = self.slots[i].generation },
            .dialing => return .{ .decision = .wait, .slot = i, .generation = self.slots[i].generation },
            .absent => {
                self.slots[i].phase = .dialing;
                return .{ .decision = .dial, .slot = i, .generation = self.bump(i) };
            },
            .failed => |at| {
                if (now_ms - at < self.redial_cooldown_ms) return .{ .decision = .hold };
                self.slots[i].phase = .dialing;
                return .{ .decision = .dial, .slot = i, .generation = self.bump(i) };
            },
        }
    }

    /// Give a lease back. Returns true iff that was the LAST one and the
    /// connection must now be torn down.
    ///
    /// A release against a machine with no leases is INERT, not a teardown. The
    /// pool's own per-lease `released` flag already makes a double release a
    /// no-op, but the count must not be able to go negative-then-zero here
    /// either: that would report "tear it down" for a connection some LATER
    /// lease had since established.
    pub fn release(self: *Ledger, k: []const u8) bool {
        const i = self.find(k) orelse return false;
        if (self.slots[i].leases == 0) return false;
        self.slots[i].leases -= 1;
        if (self.slots[i].leases > 0) return false;
        // Forget the machine entirely. The slot's generation is NOT reused: a
        // dial still in flight for it presents a generation this ledger will
        // never hand out again, so it can only ever be refused.
        self.slots[i] = .{};
        return true;
    }

    /// A dial landed. Returns true when the caller should INSTALL the connection
    /// it made, false when it must free it: the machine was released,
    /// invalidated or re-dialed while the dial was in flight, so this connection
    /// belongs to nobody.
    pub fn dialSucceeded(self: *Ledger, k: []const u8, gen: u64) bool {
        const i = self.find(k) orelse return false;
        if (self.slots[i].generation != gen) return false;
        if (self.slots[i].leases == 0) return false;
        self.slots[i].phase = .ready;
        return true;
    }

    /// A dial failed. Returns true when the failure is the CURRENT truth about
    /// the machine and its leases should hear about it.
    pub fn dialFailed(self: *Ledger, k: []const u8, gen: u64, now_ms: i64) bool {
        const i = self.find(k) orelse return false;
        if (self.slots[i].generation != gen) return false;
        if (self.slots[i].leases == 0) return false;
        self.slots[i].phase = .{ .failed = now_ms };
        return true;
    }

    /// The live connection stopped being usable (the link went dead). Leaves the
    /// machine retryable after the cooldown, with its LEASES INTACT — the
    /// subscribers still want it, the socket just died. Returns true when there
    /// really was a ready connection to drop, so a stale link notification
    /// cannot invalidate a machine twice or invalidate one mid-dial.
    pub fn invalidate(self: *Ledger, k: []const u8, gen: u64, now_ms: i64) bool {
        const i = self.find(k) orelse return false;
        if (self.slots[i].generation != gen) return false;
        if (self.slots[i].phase != .ready) return false;
        self.slots[i].phase = .{ .failed = now_ms };
        _ = self.bump(i);
        return true;
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn keyFor(buf: []u8, ep: Endpoint) []const u8 {
    return key(buf, ep).?;
}

test "key: a relay endpoint is base + device, a tcp one is host:port" {
    var buf: [max_key]u8 = undefined;
    try testing.expectEqualStrings(
        "relay:https://relay.example|dev-abc",
        keyFor(&buf, .{ .relay = .{ .base = "https://relay.example", .device = "dev-abc" } }),
    );
    try testing.expectEqualStrings(
        "tcp:127.0.0.1:7777",
        keyFor(&buf, .{ .tcp = .{ .host = "127.0.0.1", .port = 7777 } }),
    );
}

test "key: the scheme prefix keeps the two kinds from colliding" {
    var a: [max_key]u8 = undefined;
    var b: [max_key]u8 = undefined;
    // A device id that spells a host:port must not key the same as one.
    const relay = keyFor(&a, .{ .relay = .{ .base = "", .device = "127.0.0.1:7777" } });
    const tcp = keyFor(&b, .{ .tcp = .{ .host = "127.0.0.1", .port = 7777 } });
    try testing.expect(!std.mem.eql(u8, relay, tcp));
}

test "key: refuses rather than truncating" {
    var small: [8]u8 = undefined;
    try testing.expect(key(&small, .{ .relay = .{ .base = "https://relay.example", .device = "dev" } }) == null);
    try testing.expect(key(&small, .{ .tcp = .{ .host = "a-rather-long-hostname.internal", .port = 7777 } }) == null);
}

test "the first borrow dials, the second joins it" {
    var l: Ledger = .{};
    const first = l.acquire("relay:r|dev");
    try testing.expectEqual(Decision.dial, first.decision);
    try testing.expectEqual(@as(usize, 1), l.leaseCount("relay:r|dev"));

    // A second subscriber while the dial is in flight must NOT start its own.
    const second = l.acquire("relay:r|dev");
    try testing.expectEqual(Decision.wait, second.decision);
    try testing.expectEqual(@as(usize, 2), l.leaseCount("relay:r|dev"));

    try testing.expect(l.dialSucceeded("relay:r|dev", first.generation));
    try testing.expectEqual(Phase.ready, l.phaseOf("relay:r|dev"));

    // A third arriving warm is replayed, not dialed.
    try testing.expectEqual(Decision.deliver_ready, l.acquire("relay:r|dev").decision);
}

test "two endpoints are two connections; two borrows of one endpoint are one" {
    var l: Ledger = .{};
    try testing.expectEqual(Decision.dial, l.acquire("relay:r|a").decision);
    try testing.expectEqual(Decision.dial, l.acquire("relay:r|b").decision);
    // The same endpoint again shares the in-flight dial.
    try testing.expectEqual(Decision.wait, l.acquire("relay:r|a").decision);
}

test "the connection is freed on the LAST release, not the first" {
    var l: Ledger = .{};
    const d = l.acquire("tcp:h:1");
    _ = l.acquire("tcp:h:1");
    try testing.expect(l.dialSucceeded("tcp:h:1", d.generation));

    try testing.expect(!l.release("tcp:h:1"));
    try testing.expectEqual(Phase.ready, l.phaseOf("tcp:h:1"));
    try testing.expect(l.release("tcp:h:1"));
    try testing.expectEqual(Phase.absent, l.phaseOf("tcp:h:1"));
}

test "a release nobody holds is inert" {
    var l: Ledger = .{};
    try testing.expect(!l.release("tcp:h:1"));

    const d = l.acquire("tcp:h:1");
    try testing.expect(l.dialSucceeded("tcp:h:1", d.generation));
    try testing.expect(l.release("tcp:h:1"));
    // The count must not go negative-then-zero and report a second teardown for
    // a connection a later lease might have established.
    try testing.expect(!l.release("tcp:h:1"));
    const again = l.acquire("tcp:h:1");
    try testing.expectEqual(Decision.dial, again.decision);
    // ...and that later lease's own release is a real teardown again.
    try testing.expect(l.release("tcp:h:1"));
}

test "a dial that lands after the last release is not installed" {
    var l: Ledger = .{};
    const d = l.acquire("relay:r|dev");
    try testing.expect(l.release("relay:r|dev"));
    // The worker was still blocked in the dial when the chooser closed.
    try testing.expect(!l.dialSucceeded("relay:r|dev", d.generation));
    try testing.expect(!l.dialFailed("relay:r|dev", d.generation, 0));
}

test "a dial that lands after the machine was re-dialed is not installed" {
    var l: Ledger = .{};
    const first = l.acquire("relay:r|dev");
    try testing.expect(l.dialFailed("relay:r|dev", first.generation, 1_000));
    // The user re-selected the row: a fresh attempt, a fresh generation.
    const second = l.acquire("relay:r|dev");
    try testing.expectEqual(Decision.dial, second.decision);
    try testing.expect(second.generation != first.generation);
    // The FIRST dial finally comes back. It belongs to nobody.
    try testing.expect(!l.dialSucceeded("relay:r|dev", first.generation));
    try testing.expect(l.dialSucceeded("relay:r|dev", second.generation));
}

test "a slot reused for the same endpoint cannot match a stale generation" {
    var l: Ledger = .{};
    const first = l.acquire("relay:r|dev");
    try testing.expect(l.release("relay:r|dev"));
    const second = l.acquire("relay:r|dev");
    try testing.expect(first.generation != second.generation);
    try testing.expect(!l.dialSucceeded("relay:r|dev", first.generation));
}

test "a dead link keeps the leases and becomes retryable after the cooldown" {
    var l: Ledger = .{};
    const d = l.acquire("relay:r|dev");
    try testing.expect(l.dialSucceeded("relay:r|dev", d.generation));

    try testing.expect(l.invalidate("relay:r|dev", d.generation, 10_000));
    // The subscriber still wants the machine; only the socket died.
    try testing.expectEqual(@as(usize, 1), l.leaseCount("relay:r|dev"));
    // Too soon.
    try testing.expectEqual(Decision.hold, l.ensure("relay:r|dev", 12_000).decision);
    // Past the cooldown.
    const redial = l.ensure("relay:r|dev", 15_000);
    try testing.expectEqual(Decision.dial, redial.decision);
    try testing.expect(redial.generation != d.generation);
}

test "invalidate is idempotent and never fires mid-dial" {
    var l: Ledger = .{};
    const d = l.acquire("relay:r|dev");
    // Nothing ready yet: a link notification for a dialing slot is not a death.
    try testing.expect(!l.invalidate("relay:r|dev", d.generation, 0));
    try testing.expect(l.dialSucceeded("relay:r|dev", d.generation));
    try testing.expect(l.invalidate("relay:r|dev", d.generation, 0));
    // The generation moved with the first invalidate, so the second reader of
    // the same dead link cannot invalidate the RE-dial that followed it.
    try testing.expect(!l.invalidate("relay:r|dev", d.generation, 0));
}

test "ensure never dials for a machine nobody holds" {
    var l: Ledger = .{};
    // Unknown endpoint: hold, and do not claim a slot for it.
    try testing.expectEqual(Decision.hold, l.ensure("relay:r|dev", 0).decision);
    try testing.expect(l.find("relay:r|dev") == null);

    const d = l.acquire("relay:r|dev");
    try testing.expect(l.dialFailed("relay:r|dev", d.generation, 0));
    try testing.expect(l.release("relay:r|dev"));
    try testing.expectEqual(Decision.hold, l.ensure("relay:r|dev", 100_000).decision);
}

test "capacity is reported, not silently ignored" {
    var l: Ledger = .{};
    for (0..max_entries) |i| {
        var buf: [max_key]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "tcp:h:{d}", .{i}) catch unreachable;
        try testing.expectEqual(Decision.dial, l.acquire(k).decision);
    }
    try testing.expectEqual(Decision.no_capacity, l.acquire("tcp:h:999").decision);
    // Freeing one makes room again.
    try testing.expect(l.release("tcp:h:0"));
    try testing.expectEqual(Decision.dial, l.acquire("tcp:h:999").decision);
}

test "an empty or over-long key is refused a slot" {
    var l: Ledger = .{};
    try testing.expectEqual(Decision.no_capacity, l.acquire("").decision);
    var big: [max_key + 1]u8 = @splat('k');
    try testing.expectEqual(Decision.no_capacity, l.acquire(&big).decision);
}
