//! Live relay credentials for `--relay` mode + the relay.env change watcher.
//!
//! ## Why this exists
//! A re-enroll (`ghoztty-agent --enroll --relay=<base>` while the daemon is
//! running) rewrites relay.env with a fresh device token. Before this module
//! the daemon read the token exactly once at startup, so a re-enroll silently
//! required a manual restart. Now:
//!
//!   - `Creds` holds the CURRENT device token behind a mutex. Every control
//!     dial snapshots it (`current`), so a swapped token is used on the very
//!     next dial. Superseded tokens are RETIRED, never freed, while the daemon
//!     runs: in-flight session workers borrow their connection's snapshot for
//!     as long as that control connection lives, and a rare, tiny leak beats
//!     a use-after-free (they are reclaimed in `deinit`, which only tests
//!     reach — the relay daemon runs until the process dies).
//!   - `Watcher` polls relay.env on a modest interval (stat mtime+size as the
//!     cheap fast path; parse only on change). When the token actually
//!     changed it adopts the new one and BOUNCES the control link
//!     (`LinkControl.bounce`): the live connection closes, the loop redials
//!     within one backoff, and the redial picks up the fresh snapshot. A
//!     user-chosen park is respected — bounce never changes the
//!     desired state, so a parked link stays parked (and adopts the new token
//!     whenever the user reconnects).
//!
//! ## Precedence
//! `GHOSTTY_DEVICE_TOKEN` still wins (same rule as startup, see `main.zig`):
//! when the startup token came from the env var (`source == .env`), a
//! relay.env change is logged and IGNORED — the explicit env override must
//! not be clobbered by an enroll racing the daemon. The decision itself is
//! the pure `decide` function so the rule is unit-testable.
//!
//! Enroll's side of the race is handled in `enroll.zig`: `saveRelayEnv`
//! writes atomically (tmp + rename), so this watcher can never observe a
//! half-written credential.

const std = @import("std");
const Allocator = std.mem.Allocator;
const enroll = @import("enroll.zig");
const link_control = @import("link_control.zig");

/// Where the daemon's startup device token came from. Decides whether a
/// relay.env change is authoritative (`relay_env`) or ignored (`env`).
pub const Source = enum { env, relay_env };

/// What a relay.env change means for the running daemon.
pub const Decision = enum {
    /// Nothing to do: no token in the file, or the token is unchanged.
    none,
    /// `GHOSTTY_DEVICE_TOKEN` is authoritative — log and ignore the change.
    env_wins,
    /// relay.env is authoritative and holds a NEW token: adopt it and bounce
    /// the control link so the next dial authenticates with it.
    reload,
};

/// The reload rule, pure and testable: given where the current token came
/// from, the token in use, and the token now in relay.env (null = missing
/// file / no token line — never drop working credentials over that), decide
/// what the watcher should do.
pub fn decide(source: Source, current_token: []const u8, new_token: ?[]const u8) Decision {
    const tok = new_token orelse return .none;
    if (std.mem.eql(u8, tok, current_token)) return .none;
    if (source == .env) return .env_wins;
    return .reload;
}

/// The host part of a relay base for comparison: scheme stripped, trailing
/// slashes trimmed. Accepts both the daemon's normalized `wss://host` and
/// relay.env's `https://host/` spellings.
fn hostPart(s: []const u8) []const u8 {
    var v = s;
    inline for (.{ "wss://", "https://", "ws://", "http://" }) |prefix| {
        if (std.mem.startsWith(u8, v, prefix)) v = v[prefix.len..];
    }
    return std.mem.trimRight(u8, v, "/");
}

/// Whether relay.env's RELAY_BASE points at the same relay the daemon dialed.
/// A mismatch can't be hot-adopted (the ws base is baked into every worker's
/// data-dial URL for the daemon's lifetime) — the watcher logs that a restart
/// is needed.
pub fn baseMatches(ws_base: []const u8, relay_base: []const u8) bool {
    return std.ascii.eqlIgnoreCase(hostPart(ws_base), hostPart(relay_base));
}

/// The daemon's live device token. `current` is called from the dial path
/// (loop thread); `adopt` from the watcher thread — hence the mutex. Token
/// slices handed out by `current` stay valid until `deinit` (superseded
/// tokens are retired, not freed), so callers may hold a snapshot for a
/// connection's whole lifetime without copying.
pub const Creds = struct {
    alloc: Allocator,
    source: Source,
    mutex: std.Thread.Mutex = .{},
    token: []const u8,
    /// Superseded tokens, kept alive because dialed connections (and their
    /// session workers) borrow snapshots. Freed only in `deinit`.
    retired: std.ArrayList([]const u8) = .empty,

    /// Takes ownership of `token` (freed in `deinit`).
    pub fn init(alloc: Allocator, source: Source, token: []const u8) Creds {
        return .{ .alloc = alloc, .source = source, .token = token };
    }

    pub fn deinit(self: *Creds) void {
        for (self.retired.items) |t| self.alloc.free(t);
        self.retired.deinit(self.alloc);
        self.alloc.free(self.token);
        self.* = undefined;
    }

    /// Snapshot the current token. Stable until `deinit` — see the struct doc.
    pub fn current(self: *Creds) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.token;
    }

    /// Swap in a new token (ownership transfers; the old one is retired).
    pub fn adopt(self: *Creds, token: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // On OOM the old token simply stays unreferenced-but-alive: it may be
        // borrowed by a live connection, so freeing it here is never safe.
        self.retired.append(self.alloc, self.token) catch {};
        self.token = token;
    }
};

/// Polls relay.env for changes and applies `decide`. Runs on its own thread
/// (`run`) for the daemon's lifetime; `checkOnce` is the unit-testable tick.
pub const Watcher = struct {
    alloc: Allocator,
    /// relay.env path. Owned.
    path: []const u8,
    creds: *Creds,
    link: *link_control.LinkControl,
    /// The daemon's dialed `wss://host` base — only for the RELAY_BASE
    /// mismatch warning. Borrowed (daemon lifetime).
    ws_base: []const u8,
    poll_interval_ms: u64 = poll_interval_default_ms,
    /// Set by `requestStop` (tests); `run` returns promptly.
    stop: std.Thread.ResetEvent = .{},
    /// Last seen (mtime, size) — the cheap "did anything change" fast path.
    /// Null until the first successful stat; correctness never depends on it
    /// (a spurious pass just re-reads and lands on `decide(...) == .none`).
    last: ?Sig = null,

    const Sig = struct { mtime: i128, size: u64 };

    /// A re-enroll is human-paced (browser round trip), so 5s keeps the
    /// pickup snappy while the steady-state cost stays one stat per tick.
    const poll_interval_default_ms: u64 = 5_000;

    /// Takes ownership of `path`.
    pub fn init(
        alloc: Allocator,
        path: []const u8,
        creds: *Creds,
        link: *link_control.LinkControl,
        ws_base: []const u8,
    ) Watcher {
        return .{ .alloc = alloc, .path = path, .creds = creds, .link = link, .ws_base = ws_base };
    }

    pub fn deinit(self: *Watcher) void {
        self.alloc.free(self.path);
        self.* = undefined;
    }

    /// Thread entry: tick every `poll_interval_ms` until `requestStop`.
    pub fn run(self: *Watcher) void {
        const interval_ns = self.poll_interval_ms * std.time.ns_per_ms;
        while (true) {
            if (self.stop.timedWait(interval_ns)) {
                return; // stop requested
            } else |_| {} // interval elapsed — tick
            self.checkOnce();
        }
    }

    pub fn requestStop(self: *Watcher) void {
        self.stop.set();
    }

    /// One poll tick: stat, and on change parse + apply the reload decision.
    /// All failure modes (missing file, unreadable, malformed) keep the
    /// current credentials — the watcher only ever upgrades, never breaks, a
    /// working link.
    pub fn checkOnce(self: *Watcher) void {
        const st = std.fs.cwd().statFile(self.path) catch return;
        const sig: Sig = .{ .mtime = st.mtime, .size = st.size };
        if (self.last) |l| {
            if (l.mtime == sig.mtime and l.size == sig.size) return;
        }
        self.last = sig;

        var env = enroll.loadRelayEnv(self.alloc, self.path) catch return;
        defer env.deinit(self.alloc);

        // RELAY_BASE can't be hot-swapped (see `baseMatches`); say so once
        // per file change instead of silently dialing the old relay forever.
        if (env.relay_base) |base| {
            if (!baseMatches(self.ws_base, base)) {
                std.debug.print(
                    "ghoztty-agent: relay.env RELAY_BASE changed to {s}; restart the agent to use it\n",
                    .{base},
                );
            }
        }

        switch (decide(self.creds.source, self.creds.current(), env.device_token)) {
            .none => {},
            .env_wins => std.debug.print(
                "ghoztty-agent: relay.env device token changed but GHOSTTY_DEVICE_TOKEN is set; ignoring (env wins)\n",
                .{},
            ),
            .reload => {
                // Hand the parsed token straight to Creds (skip a re-dupe);
                // env.deinit must not free it afterwards.
                const tok = env.device_token.?;
                env.device_token = null;
                self.creds.adopt(tok);
                std.debug.print(
                    "ghoztty-agent: relay.env device token changed (re-enroll); reconnecting with the new credential\n",
                    .{},
                );
                // Drop the live control connection (if any): the loop redials
                // within one backoff and `dial` snapshots the new token.
                // Desired state is untouched — a user-parked link stays parked.
                self.link.bounce();
            },
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "decide: relay_env source adopts a new token" {
    try testing.expectEqual(Decision.reload, decide(.relay_env, "old", "new"));
}

test "decide: unchanged token is a no-op (either source)" {
    try testing.expectEqual(Decision.none, decide(.relay_env, "tok", "tok"));
    try testing.expectEqual(Decision.none, decide(.env, "tok", "tok"));
}

test "decide: missing/empty token never drops working creds" {
    try testing.expectEqual(Decision.none, decide(.relay_env, "tok", null));
    try testing.expectEqual(Decision.none, decide(.env, "tok", null));
}

test "decide: GHOSTTY_DEVICE_TOKEN wins over a relay.env change" {
    try testing.expectEqual(Decision.env_wins, decide(.env, "env-tok", "file-tok"));
}

test "baseMatches: scheme + trailing slash insensitive" {
    try testing.expect(baseMatches("wss://relay.example.com", "https://relay.example.com/"));
    try testing.expect(baseMatches("wss://relay.example.com:8443", "wss://relay.example.com:8443"));
    try testing.expect(!baseMatches("wss://relay.example.com", "https://other.example.com"));
}

test "creds: adopt swaps the token and keeps the old slice alive" {
    const alloc = testing.allocator;
    var creds = Creds.init(alloc, .relay_env, try alloc.dupe(u8, "old-token"));
    defer creds.deinit();

    const old = creds.current();
    creds.adopt(try alloc.dupe(u8, "new-token"));
    try testing.expectEqualStrings("new-token", creds.current());
    // The retired snapshot must still be readable (borrowed by live conns).
    try testing.expectEqualStrings("old-token", old);
}

/// A minimal live "connection" for asserting that `checkOnce` bounces the
/// link: counts closes via the registered transport.
const FakeLive = struct {
    closes: u32 = 0,

    fn transport(self: *FakeLive) link_control.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: link_control.Transport.VTable = .{
        .dial = dial,
        .serve = serve,
        .close = close,
        .deinit = deinit,
    };

    fn dial(_: *anyopaque) ?*anyopaque {
        return null;
    }
    fn serve(_: *anyopaque, _: *anyopaque) void {}
    fn close(ctx: *anyopaque, _: *anyopaque) void {
        const self: *FakeLive = @ptrCast(@alignCast(ctx));
        self.closes += 1;
    }
    fn deinit(_: *anyopaque, _: *anyopaque) void {}
};

test "watcher: relay.env token change is adopted and bounces the link" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "relay.env" });
    // Watcher takes ownership of `path`.

    try enroll.saveRelayEnv(alloc, path, "https://relay.example.com", "token-one");

    var creds = Creds.init(alloc, .relay_env, try alloc.dupe(u8, "token-one"));
    defer creds.deinit();
    var link = link_control.LinkControl{ .host = "relay.example.com" };
    var fake = FakeLive{};
    var conn_stub: u8 = 0;
    link.registerLive(fake.transport(), &conn_stub);

    var watcher = Watcher.init(alloc, path, &creds, &link, "wss://relay.example.com");
    defer watcher.deinit();

    // Baseline tick: file matches the in-use token — nothing happens.
    watcher.checkOnce();
    try testing.expectEqualStrings("token-one", creds.current());
    try testing.expectEqual(@as(u32, 0), fake.closes);

    // Re-enroll: atomic rewrite with a fresh token. Different length so the
    // stat fast path can't false-negative on filesystems with coarse mtime.
    try enroll.saveRelayEnv(alloc, path, "https://relay.example.com", "token-two-longer");

    watcher.checkOnce();
    try testing.expectEqualStrings("token-two-longer", creds.current());
    try testing.expectEqual(@as(u32, 1), fake.closes);
    // Desired state untouched: the loop would redial, not park.
    try testing.expect(link.display() != .offline);

    // Same content again (no further writes): no re-bounce.
    watcher.checkOnce();
    try testing.expectEqual(@as(u32, 1), fake.closes);
}

test "watcher: env-sourced token ignores a relay.env change" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "relay.env" });

    try enroll.saveRelayEnv(alloc, path, "https://relay.example.com", "file-token");

    var creds = Creds.init(alloc, .env, try alloc.dupe(u8, "env-token"));
    defer creds.deinit();
    var link = link_control.LinkControl{ .host = "relay.example.com" };
    var fake = FakeLive{};
    var conn_stub: u8 = 0;
    link.registerLive(fake.transport(), &conn_stub);

    var watcher = Watcher.init(alloc, path, &creds, &link, "wss://relay.example.com");
    defer watcher.deinit();

    watcher.checkOnce();
    try testing.expectEqualStrings("env-token", creds.current());
    try testing.expectEqual(@as(u32, 0), fake.closes);
}

test "watcher: missing relay.env keeps current creds" {
    const alloc = testing.allocator;

    var creds = Creds.init(alloc, .relay_env, try alloc.dupe(u8, "tok"));
    defer creds.deinit();
    var link = link_control.LinkControl{ .host = "x" };
    const path = try alloc.dupe(u8, "/definitely/not/a/real/path/relay.env");

    var watcher = Watcher.init(alloc, path, &creds, &link, "wss://x");
    defer watcher.deinit();

    watcher.checkOnce();
    try testing.expectEqualStrings("tok", creds.current());
}
