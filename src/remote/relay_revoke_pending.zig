//! A revocation that could not complete is REMEMBERED and finished later
//! (T1424 — the recovery half of main's `0c3a19764` / `f3b1e5fb5`).
//!
//! ## Why this exists
//!
//! T1421 made sign-out revoke this machine's enrollment, and made a revocation
//! that could not happen refuse to report success: the account stays signed in
//! and the chooser offers "Sign Out Anyway". What that left behind is the
//! thing this module fixes. "Sign Out Anyway" told the user, honestly, that the
//! machine is still connected to the account — and then never tried again. The
//! machine stayed listed, reachable and streamable from every other computer on
//! the account until the user remembered to go to one of those computers and
//! remove it by hand. Nobody remembers to do that. A security decision the user
//! already made ("this machine is not mine any more") was left depending on a
//! chore they were never going to perform.
//!
//! So a forced sign-out ARMS a pending revocation: a small record beside
//! relay.env holding the credential and the relay to aim it at. It is retried
//! at every app launch and on a backoff while the app runs, and it clears only
//! when the relay has actually answered. The user's sign-out finishes itself
//! the moment the network comes back.
//!
//! ## The record holds the credential, and that is the point
//!
//! The retry authenticates as the DEVICE, not as the account: by the time it
//! runs the user is signed out, so there is no session token to speak with.
//! `POST /v1/agent/deenroll` takes the device's own bearer token, which is
//! exactly the credential the machine is being stripped of — the Mac seat calls
//! this "relay.env kept as the retry's own record". Keeping it is not a
//! weakening: the machine IS still enrolled until the relay says otherwise, and
//! deleting the token locally would destroy the only thing that could ever
//! revoke it (`f3b1e5fb5`'s first lesson, already encoded in
//! `relay_revoke.revocationBase`). The file gets the same owner-only DACL
//! relay.env does.
//!
//! ## What is pure here
//!
//! The rules. `nextAfter` turns one attempt's answer into an obligation, and
//! `backoffMs` is the retry cadence; both are unit-tested without a network.
//! The two edge cases `f3b1e5fb5` paid for on the Mac seat are designed in
//! rather than rediscovered:
//!
//!   1. **A POST that landed with a lost response.** The relay deleted the
//!      device and the answer never arrived; the retry re-POSTs and gets a bare
//!      401. That is indistinguishable from "already revoked" and must be
//!      treated as done — but it is NOT evidence about anything else. The
//!      Mac's first cut used that 401 to clear the machine's suspension record
//!      too, so signing back in produced a machine that was simply gone, with
//!      no name to re-enroll under. `.clear_token_dead` exists as a separate
//!      outcome from `.clear_revoked` for that single reason: it says "stop
//!      retrying" and nothing more, and T1425's suspension record must not be
//!      touched on that branch.
//!   2. **A transient failure must not strand the machine.** Anything that is
//!      not a definite answer — no answer at all, a 5xx, a 404 from a relay
//!      that has no such endpoint — leaves the record ARMED. The alternative,
//!      giving up after N tries, means the machine stays enrolled forever
//!      because a laptop was closed at the wrong moment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const enroll = @import("agent/enroll.zig");
const relay_revoke = @import("relay_revoke.zig");
const win_acl = @import("win_acl.zig");
const atomic_write = @import("agent/atomic_write.zig");

const log = std.log.scoped(.relay_revoke_pending);

/// The armed record. `relay_base` is stored already normalized (see
/// `relay_revoke.normalizeBase`) so the retry never has to re-derive it from a
/// relay.env the user may have edited in the meantime.
pub const Record = struct {
    relay_base: []const u8,
    device_token: []const u8,
    /// The account that was signed out. Never used to authenticate — the
    /// retry is device-authenticated — but it is what a support question
    /// ("whose machine is this record trying to remove?") needs answered.
    account_email: []const u8 = "",
    /// Unix seconds the record was armed, for logging and for the chooser's
    /// future "still trying since …" (T1426).
    armed_at: i64 = 0,
};

/// A loaded record and the memory it points into.
pub const Loaded = struct {
    parsed: std.json.Parsed(Record),

    pub fn value(self: Loaded) Record {
        return self.parsed.value;
    }

    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
    }
};

/// What one de-enroll attempt learned. `unanswered` covers every shape of "the
/// relay did not tell us anything": no route to it, a refused connection, a
/// timeout, a TLS failure.
pub const Answer = union(enum) {
    status: u16,
    unanswered,
};

/// What to do after one attempt.
pub const Next = enum {
    /// The relay confirmed the revocation. Clear the record; the machine is
    /// gone from the account.
    clear_revoked,
    /// The token is dead — a prior de-enroll landed, or the device row was
    /// already removed from another client. Stop retrying, and treat this as
    /// evidence about NOTHING ELSE (see the module comment and T1425).
    clear_token_dead,
    /// No definite answer. Stay armed and try again later.
    stay_armed,
};

/// The retry rule, pure.
///
/// 204 is the relay's success for `POST /v1/agent/deenroll` (200 is accepted
/// too — a relay that answers with a body has still deleted the device).
/// 401 means the bearer is no longer a device, which is what "already revoked"
/// looks like from here. Everything else — 404 included, because a relay
/// without that route is a mis-aimed request rather than a revoked machine —
/// leaves the record armed.
pub fn nextAfter(answer: Answer) Next {
    return switch (answer) {
        .unanswered => .stay_armed,
        .status => |s| switch (s) {
            200, 204 => .clear_revoked,
            401 => .clear_token_dead,
            else => .stay_armed,
        },
    };
}

/// How long to wait before attempt `n` (0-based: attempt 0 runs immediately).
///
/// This is also the answer to "retried when the network comes back". Windows
/// can signal an address change, but the interesting transition is not the
/// adapter coming up — it is the RELAY becoming reachable, which no local
/// event reports. A capped backoff asks the only question that actually
/// settles it, and the cap is what bounds "the machine is still enrolled" to
/// minutes rather than until the next relaunch.
pub fn backoffMs(attempt: u32) u64 {
    return switch (attempt) {
        0 => 0,
        1 => 5 * std.time.ms_per_s,
        2 => 15 * std.time.ms_per_s,
        3 => 60 * std.time.ms_per_s,
        4 => 5 * std.time.ms_per_min,
        else => 15 * std.time.ms_per_min,
    };
}

/// Whether a record can actually be retried. A record with no token, or with a
/// base nothing can dial, would spin forever against nothing; it is deleted
/// instead of retried, and the log says so.
pub fn usable(rec: Record) bool {
    return rec.device_token.len > 0 and relay_revoke.isUsableBase(rec.relay_base);
}

/// Where the record lives: beside relay.env, so `GHOSTTY_RELAY_ENV` (the
/// override tests already use to isolate the credential) carries this file with
/// it and the two can never end up in different sandboxes. Owned by the caller.
pub fn recordPath(alloc: Allocator) ![]u8 {
    const env_path = try enroll.relayEnvPath(alloc);
    defer alloc.free(env_path);
    const dir = std.fs.path.dirname(env_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, "pending-revoke.json" });
}

/// Arm a pending revocation. Atomic (a half-written record is a record that
/// can never be retried) and owner-only ACL'd — it holds a bearer credential,
/// exactly like the relay.env it sits beside.
pub fn arm(alloc: Allocator, rec: Record) !void {
    const path = try recordPath(alloc);
    defer alloc.free(path);
    return armAt(alloc, path, rec);
}

/// `arm` at an explicit path. The path-taking form is what the tests drive:
/// the record's location is derived from `GHOSTTY_RELAY_ENV`, and a test that
/// mutated the process environment to reach it would be changing the answer
/// for every other test in the lane.
pub fn armAt(alloc: Allocator, path: []const u8, rec: Record) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, rec, .{});
    defer alloc.free(json);

    try atomic_write.writeChunks(alloc, path, &.{json}, .{ .secret = true });
    atomic_write.cleanStaging(path);
    win_acl.harden(alloc, path);
    log.info("armed a pending revocation for this machine at {s}", .{rec.relay_base});
}

/// The armed record, or null when there is none (or one that cannot be read).
pub fn load(alloc: Allocator) ?Loaded {
    const path = recordPath(alloc) catch return null;
    defer alloc.free(path);
    return loadAt(alloc, path);
}

/// `load` from an explicit path.
pub fn loadAt(alloc: Allocator, path: []const u8) ?Loaded {
    const content = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return null;
    defer alloc.free(content);

    // `alloc_always`, not the default: std.json hands back slices that point
    // INTO the source buffer when a string needs no unescaping, and `content`
    // is freed on the way out of this function. The record's whole job is to
    // outlive the read.
    const parsed = std.json.parseFromSlice(Record, alloc, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        log.warn("pending revocation record is unreadable err={}", .{err});
        return null;
    };
    return .{ .parsed = parsed };
}

/// Whether a retry is owed. Cheap enough for a launch path: one small local
/// read, no network.
pub fn isArmed(alloc: Allocator) bool {
    var rec = load(alloc) orelse return false;
    defer rec.deinit();
    return usable(rec.value());
}

/// Delete the record. Best-effort — a missing one is success.
pub fn clear(alloc: Allocator) void {
    const path = recordPath(alloc) catch return;
    defer alloc.free(path);
    clearAt(path);
}

/// `clear` at an explicit path.
pub fn clearAt(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    atomic_write.cleanStaging(path);
}

/// The result of one `retryOnce`.
pub const Outcome = enum {
    /// Nothing was armed.
    idle,
    /// The record named a credential or relay nothing could ever use; it was
    /// discarded rather than retried forever.
    discarded,
    /// The relay confirmed it. The machine is off the account.
    revoked,
    /// The token was already dead. Stop retrying; conclude nothing else.
    token_dead,
    /// Still owed. The record stays armed.
    still_armed,
};

/// Try to finish an armed revocation exactly once. Network-bound — never call
/// this on the GUI thread; `retryAsync` is the entry point the app uses.
pub fn retryOnce(alloc: Allocator) Outcome {
    var loaded = load(alloc) orelse return .idle;
    defer loaded.deinit();
    const rec = loaded.value();

    if (!usable(rec)) {
        log.warn("pending revocation names no usable credential; discarding it", .{});
        clear(alloc);
        return .discarded;
    }

    const base = relay_revoke.normalizeBase(alloc, rec.relay_base) catch {
        log.warn("pending revocation names an undialable relay; discarding it", .{});
        clear(alloc);
        return .discarded;
    };
    defer alloc.free(base);

    const answer: Answer = if (enroll.deEnrollStatus(alloc, base, rec.device_token)) |outcome|
        .{ .status = switch (outcome) {
            .revoked => @as(u16, 204),
            .token_dead => @as(u16, 401),
        } }
    else |err| switch (err) {
        // A relay that answered, and answered something else. Distinguishable
        // from silence, and it does not mean the machine is gone.
        error.DeenrollFailed => .{ .status = 0 },
        else => .unanswered,
    };

    return switch (nextAfter(answer)) {
        .clear_revoked => blk: {
            clear(alloc);
            log.info("pending revocation completed: this machine is off the account", .{});
            break :blk .revoked;
        },
        .clear_token_dead => blk: {
            // Deliberately narrow: the record goes and nothing else does. A
            // 401 is what a landed POST with a lost response looks like, and
            // the Mac seat's first cut read more into it than that.
            clear(alloc);
            log.info("pending revocation: the device credential is already dead", .{});
            break :blk .token_dead;
        },
        .stay_armed => .still_armed,
    };
}

// -----------------------------------------------------------------------------
// The retry driver
// -----------------------------------------------------------------------------

/// One retry loop at a time, however many times the app asks for one (launch,
/// then a forced sign-out in the same session).
var running: std.atomic.Value(bool) = .init(false);

/// True while a retry loop is in flight.
pub fn isRetrying() bool {
    return running.load(.acquire);
}

/// Start the retry loop on a detached thread, if a revocation is armed and no
/// loop is already running. Safe to call from the GUI thread — it does one
/// small local read before deciding, and everything else happens off-thread.
///
/// Called at app launch and immediately after a forced sign-out arms a record.
pub fn retryAsync(alloc: Allocator) void {
    if (!isArmed(alloc)) return;
    if (running.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, retryLoop, .{}) catch |err| {
        running.store(false, .release);
        log.warn("could not start the revocation retry loop err={}", .{err});
        return;
    };
    thread.detach();
}

/// Retry until the relay answers, on `backoffMs`'s cadence. The loop ends only
/// when the record is gone — confirmed, dead, discarded, or cleared by a
/// sign-in on this machine. It never gives up on a transient failure: a
/// machine that stays enrolled because a laptop lid was shut at the wrong
/// moment is the whole defect.
fn retryLoop() void {
    var attempt: u32 = 0;
    while (true) : (attempt +|= 1) {
        const wait = backoffMs(attempt);
        if (wait > 0) std.Thread.sleep(wait * std.time.ns_per_ms);

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        switch (retryOnce(arena)) {
            .still_armed => continue,
            else => break,
        }
    }
    running.store(false, .release);
}

// -----------------------------------------------------------------------------
// Tests (pure — the `none` lane)
// -----------------------------------------------------------------------------

const testing = std.testing;

test "nextAfter: a confirmed revocation clears the record" {
    try testing.expectEqual(Next.clear_revoked, nextAfter(.{ .status = 204 }));
    try testing.expectEqual(Next.clear_revoked, nextAfter(.{ .status = 200 }));
}

test "nextAfter: a 401 stops the retry and concludes nothing else" {
    // A POST that landed with a lost response looks exactly like this. It ends
    // the retry — and `clear_token_dead` is a DIFFERENT outcome from
    // `clear_revoked` precisely so T1425's suspension record is not touched on
    // this branch (`f3b1e5fb5`: the machine vanished with no name to re-enroll
    // under).
    try testing.expectEqual(Next.clear_token_dead, nextAfter(.{ .status = 401 }));
}

test "nextAfter: an unanswerable relay stays armed" {
    try testing.expectEqual(Next.stay_armed, nextAfter(.unanswered));
}

test "nextAfter: a transient relay failure stays armed, it does not strand" {
    // 5xx, a quota refusal, a 404 from a relay with no such route: none of
    // these say the machine is gone, and giving up on them leaves it enrolled
    // until an explicit sign-out/in cycle nobody performs.
    for ([_]u16{ 0, 403, 404, 429, 500, 502, 503 }) |s| {
        try testing.expectEqual(Next.stay_armed, nextAfter(.{ .status = s }));
    }
}

test "backoffMs: the first attempt is immediate and the cadence is capped" {
    try testing.expectEqual(@as(u64, 0), backoffMs(0));
    try testing.expect(backoffMs(1) > 0);
    // Monotonic up to the cap, so an early failure is retried promptly and a
    // long outage does not spin.
    var prev: u64 = 0;
    for (0..5) |i| {
        const cur = backoffMs(@intCast(i));
        try testing.expect(cur >= prev);
        prev = cur;
    }
    const cap = backoffMs(5);
    try testing.expectEqual(cap, backoffMs(6));
    try testing.expectEqual(cap, backoffMs(1000));
    // Bounded: "still enrolled" is measured in minutes, not until a relaunch.
    try testing.expect(cap <= 15 * std.time.ms_per_min);
}

test "usable: a record with no token or no dialable base is never retried" {
    try testing.expect(usable(.{ .relay_base = "https://relay.example", .device_token = "tok" }));
    try testing.expect(usable(.{ .relay_base = "wss://relay.example", .device_token = "tok" }));
    try testing.expect(!usable(.{ .relay_base = "https://relay.example", .device_token = "" }));
    try testing.expect(!usable(.{ .relay_base = "not-a-url", .device_token = "tok" }));
    try testing.expect(!usable(.{ .relay_base = "", .device_token = "tok" }));
}

test "the record round-trips through JSON with its credential intact" {
    const alloc = testing.allocator;
    const rec: Record = .{
        .relay_base = "https://relay.example",
        .device_token = "dev-tok-1",
        .account_email = "a@b.com",
        .armed_at = 1_700_000_000,
    };
    const json = try std.json.Stringify.valueAlloc(alloc, rec, .{});
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(Record, alloc, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try testing.expectEqualStrings(rec.relay_base, parsed.value.relay_base);
    try testing.expectEqualStrings(rec.device_token, parsed.value.device_token);
    try testing.expectEqualStrings(rec.account_email, parsed.value.account_email);
    try testing.expectEqual(rec.armed_at, parsed.value.armed_at);
}

test "a record written by an older build without the optional fields still loads" {
    // Forward compatibility in the direction that matters: the record is
    // written by the build that signs out and read by whatever build launches
    // next, which may be older or newer than it.
    const alloc = testing.allocator;
    const parsed = try std.json.parseFromSlice(
        Record,
        alloc,
        \\{"relay_base":"https://relay.example","device_token":"t","future_field":7}
    ,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expect(usable(parsed.value));
    try testing.expectEqualStrings("", parsed.value.account_email);
}

test "the armed record survives on disk and is cleared only by an answer" {
    // The state machine the retry actually walks, driven over a real file:
    // armed → still armed after an unanswerable relay → cleared by a confirmed
    // revocation. `nextAfter` decides; this asserts the record on disk agrees
    // with it, because a decision that never reaches the file is a machine
    // that stays enrolled.
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "pending-revoke.json" });
    defer alloc.free(path);

    try testing.expect(loadAt(alloc, path) == null);

    try armAt(alloc, path, .{
        .relay_base = "https://relay.example",
        .device_token = "dev-tok-1",
        .account_email = "a@b.com",
        .armed_at = 1_700_000_000,
    });

    {
        var loaded = loadAt(alloc, path) orelse return error.NotArmed;
        defer loaded.deinit();
        try testing.expect(usable(loaded.value()));
        try testing.expectEqualStrings("dev-tok-1", loaded.value().device_token);
    }

    // An unanswerable relay leaves it exactly where it was — including the
    // credential, which is the only thing that can ever revoke this machine.
    try testing.expectEqual(Next.stay_armed, nextAfter(.unanswered));
    {
        var loaded = loadAt(alloc, path) orelse return error.NotArmed;
        defer loaded.deinit();
        try testing.expectEqualStrings("dev-tok-1", loaded.value().device_token);
    }

    // A 401 clears the record and NOTHING ELSE (T1425's suspension record is
    // not this branch's business — `f3b1e5fb5`).
    try testing.expectEqual(Next.clear_token_dead, nextAfter(.{ .status = 401 }));
    clearAt(path);
    try testing.expect(loadAt(alloc, path) == null);

    // Re-arming after a clear is the "signed out again" path, and it must not
    // depend on any leftover state.
    try armAt(alloc, path, .{ .relay_base = "wss://relay.example", .device_token = "dev-tok-2" });
    {
        var loaded = loadAt(alloc, path) orelse return error.NotArmed;
        defer loaded.deinit();
        try testing.expectEqualStrings("dev-tok-2", loaded.value().device_token);
    }
    try testing.expectEqual(Next.clear_revoked, nextAfter(.{ .status = 204 }));
    clearAt(path);
    try testing.expect(loadAt(alloc, path) == null);

    // Clearing what is not there is success, not an error: a retry that races
    // a sign-in must not fail on the second delete.
    clearAt(path);
}

test "an unusable record is discarded rather than retried forever" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "pending-revoke.json" });
    defer alloc.free(path);

    try armAt(alloc, path, .{ .relay_base = "not-a-url", .device_token = "tok" });
    var loaded = loadAt(alloc, path) orelse return error.NotArmed;
    defer loaded.deinit();
    try testing.expect(!usable(loaded.value()));
}
