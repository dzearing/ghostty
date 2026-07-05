//! Agent SELF-UPDATE (relay mode only — NOT `--listen`/`--stdio`).
//!
//! A background thread polls the relay's public CDN manifest
//! (`GET <relay base>/dl/version.json`, FIXED schema shared with the publisher):
//!
//!   {"windows-x86_64": {"version": "20260703-c322788",
//!                       "sha256": "<hex>", "path": "/dl/ghoztty-agent.exe"},
//!    "macos-aarch64":  {...}}
//!
//! ~90s after startup and every 6h after that, the updater compares the entry
//! for THIS platform (`platform_key`, `<os>-<arch>`) against the baked build
//! version (`agent_build_options.agent_version`, "YYYYMMDD-<git short hash>").
//! A missing manifest / missing platform key is a quiet no-op (debug-level
//! log only); "dev" builds NEVER self-update.
//!
//! On a version difference it STAGES the new binary next to the running exe:
//! download to memory, verify SHA-256 (mismatch = discard + log + retry next
//! cycle), write to `<exe>.new.tmp`, then rename to `<exe>.new` — the rename
//! makes staging crash-safe (a partial download can never be applied).
//!
//! APPLY is idle-gated: only when the daemon has ZERO live sessions (attached
//! OR detached-with-retained-scrollback — i.e. the session table is empty; the
//! idle-TTL reaper eventually clears abandoned ones). Once staged, idleness is
//! polled every ~30s. Apply = rename running exe → `<exe>.old`, rename `.new`
//! into place, spawn the new exe with the SAME argv + `--force-replace` (so it
//! wins the single-instance takeover against us), then exit. Renaming a
//! running executable is legal on Windows, macOS, and Linux. On startup the
//! agent best-effort deletes leftovers (`.old` may still be held briefly by
//! Windows — ignored; the next restart gets it).
//!
//! Env knobs (GHOSTTY_ prefix — repo convention):
//!   - `GHOSTTY_AGENT_NO_SELFUPDATE=1` — kill switch, disables the loop.
//!   - `GHOSTTY_AGENT_UPDATE_INTERVAL_MS=<n>` — overrides ALL loop intervals
//!     (initial delay, check interval, idle poll) for tests/live verification.
//!   - `GHOSTTY_AGENT_UPDATE_BASE=<url>` — overrides the manifest/download
//!     base URL (`http://` allowed — loopback integration tests).
//!
//! The check/stage/apply pipeline is deliberately seam-injected (intervals,
//! idleness source, spawn, exit) so the whole cycle is testable in-process
//! against a loopback HTTP server — see the tests at the bottom.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const http_client = @import("../http_client.zig");
const session = @import("session.zig");

/// Manifest location under the relay base (public CDN path).
pub const manifest_path = "/dl/version.json";

pub const env_disable = "GHOSTTY_AGENT_NO_SELFUPDATE";
pub const env_interval = "GHOSTTY_AGENT_UPDATE_INTERVAL_MS";
pub const env_base = "GHOSTTY_AGENT_UPDATE_BASE";

/// First manifest check ~90s after startup (let the daemon settle / connect).
pub const default_initial_delay_ms: u64 = 90 * std.time.ms_per_s;
/// Steady-state manifest check cadence.
pub const default_check_interval_ms: u64 = 6 * std.time.ms_per_hour;
/// Idleness poll cadence once an update is staged.
pub const default_idle_poll_ms: u64 = 30 * std.time.ms_per_s;

/// The manifest is a small JSON object; the binary can be tens of MB.
const max_manifest_len: usize = 64 * 1024;
const max_binary_len: usize = 256 * 1024 * 1024;

/// This build's manifest key: `<os>-<arch>` (e.g. `windows-x86_64`,
/// `macos-aarch64`). Matches the publisher's FIXED key set.
pub const platform_key: []const u8 = blk: {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @tagName(builtin.cpu.arch),
    };
    break :blk os ++ "-" ++ arch;
};

/// One platform's manifest entry. All fields owned (duped from the parse).
pub const ManifestEntry = struct {
    version: []u8,
    sha256: []u8,
    path: []u8,

    pub fn deinit(self: *ManifestEntry, alloc: Allocator) void {
        alloc.free(self.version);
        alloc.free(self.sha256);
        alloc.free(self.path);
        self.* = undefined;
    }
};

/// Parse the manifest and select `key`'s entry. Any malformed input, missing
/// key, or implausible field (non-64-hex sha, path not starting with `/`)
/// returns null — the manifest is public input; a bad one must mean "no
/// update", never an error path.
pub fn parseManifest(alloc: Allocator, json: []const u8, key: []const u8) ?ManifestEntry {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const entry = switch (root.get(key) orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const version = jsonString(entry, "version") orelse return null;
    const sha256 = jsonString(entry, "sha256") orelse return null;
    const path = jsonString(entry, "path") orelse return null;
    if (version.len == 0) return null;
    if (sha256.len != 64) return null; // hex SHA-256
    if (path.len == 0 or path[0] != '/') return null;

    const v = alloc.dupe(u8, version) catch return null;
    const s = alloc.dupe(u8, sha256) catch {
        alloc.free(v);
        return null;
    };
    const p = alloc.dupe(u8, path) catch {
        alloc.free(v);
        alloc.free(s);
        return null;
    };
    return .{ .version = v, .sha256 = s, .path = p };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Is `remote` an update over `local`? Pure inequality — the manifest is the
/// single source of truth, so ANY difference (upgrade or rollback) is applied.
/// "dev" builds (no baked version) never self-update.
pub fn updateAvailable(local: []const u8, remote: []const u8) bool {
    if (std.mem.eql(u8, local, "dev")) return false;
    if (remote.len == 0) return false;
    return !std.mem.eql(u8, local, remote);
}

/// Result of a single check (`checkNow`), for the tray "Check for updates" UI.
pub const CheckOutcome = enum {
    /// Manifest says this build is current — nothing to do.
    up_to_date,
    /// A newer build was downloaded + sha-verified + staged; it applies on the
    /// next idle moment (zero live sessions).
    update_staged,
    /// The check couldn't complete (network / manifest / download / hash). The
    /// loop retries automatically.
    check_failed,
    /// Another check is already running (single-flight).
    busy,
};

/// The background updater. Production wiring is `maybeStart` (env knobs, real
/// exe path/argv, store-backed idleness, detached thread); tests build one
/// directly with short intervals and hooked spawn/exit seams.
pub const Updater = struct {
    alloc: Allocator,
    /// `http(s)://host[:port]` base the manifest + binary are fetched under
    /// (no trailing slash). Borrowed; must outlive the updater.
    base_url: []const u8,
    /// This build's baked version (compared against the manifest).
    local_version: []const u8,
    /// Absolute path of the running executable — the swap target.
    exe_path: []const u8,
    /// argv to respawn with (exe + original args, WITHOUT `--force-replace`;
    /// apply appends it). Borrowed; must outlive the updater.
    argv: []const []const u8,

    initial_delay_ms: u64 = default_initial_delay_ms,
    check_interval_ms: u64 = default_check_interval_ms,
    idle_poll_ms: u64 = default_idle_poll_ms,

    /// Idleness source: live session count (attached + detached-retained).
    /// Apply proceeds only at zero. Default (null ctx) is "always idle".
    live_ctx: ?*anyopaque = null,
    liveSessionsFn: *const fn (?*anyopaque) usize = alwaysIdle,

    /// Test seams: the real ones spawn a detached child / call process.exit.
    spawn_ctx: ?*anyopaque = null,
    spawnFn: *const fn (?*anyopaque, *Updater, []const []const u8) anyerror!void = spawnReal,
    exitFn: *const fn (*Updater) void = exitReal,

    // Stop plumbing (tests; production never stops it) + manual-check state.
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    stop_flag: bool = false,
    /// Single-flight guard: true while a check (loop or manual) is running, so a
    /// tray "Check for updates" and the background loop never stage concurrently.
    checking: bool = false,
    /// A verified update is staged and waiting only on idleness to apply. Set by
    /// a manual check so the loop applies it without re-downloading.
    pending_apply: bool = false,

    /// THE LOOP: initial delay → check (+stage) → idle-gate → apply → respawn
    /// → exit. Runs until `exitFn` (production: never returns from it) or
    /// `requestStop` (tests).
    pub fn runLoop(self: *Updater) void {
        std.debug.print(
            "ghoztty-agent: self-update: enabled (version {s}, platform {s}, base {s}; first check in {d}s)\n",
            .{ self.local_version, platform_key, self.base_url, self.initial_delay_ms / 1000 },
        );
        if (self.sleepOrStop(self.initial_delay_ms)) return;
        while (true) {
            // A manual check may have already staged an update (pending_apply);
            // otherwise check now. Both share the single-flight guard in checkNow.
            if (self.stagedOrCheck()) {
                // Staged: gate the apply on ZERO live sessions.
                var logged_wait = false;
                while (true) {
                    const live = self.liveSessionsFn(self.live_ctx);
                    if (live == 0) break;
                    if (!logged_wait) {
                        std.debug.print("ghoztty-agent: self-update: staged; waiting for idle ({d} live session(s))\n", .{live});
                        logged_wait = true;
                    }
                    if (self.sleepOrStop(self.idle_poll_ms)) return;
                }
                std.debug.print("ghoztty-agent: self-update: idle; applying\n", .{});
                if (self.applyStaged()) {
                    self.exitFn(self);
                    return; // test exit hooks return; production never gets here
                } else |err| {
                    // Swap failed and was rolled back; retry a full cycle later
                    // (re-download), so clear the staged flag.
                    std.debug.print("ghoztty-agent: self-update: apply failed ({s}); will retry next cycle\n", .{@errorName(err)});
                    self.mutex.lock();
                    self.pending_apply = false;
                    self.mutex.unlock();
                }
            }
            if (self.sleepOrStop(self.check_interval_ms)) return;
        }
    }

    /// Loop helper: true if an update is staged and ready to apply — either a
    /// manual check already staged one (`pending_apply`), or a fresh check does
    /// so now.
    fn stagedOrCheck(self: *Updater) bool {
        self.mutex.lock();
        const pending = self.pending_apply;
        self.mutex.unlock();
        if (pending) return true;
        return self.checkNow() == .update_staged;
    }

    /// Unblock + stop the loop (tests).
    pub fn requestStop(self: *Updater) void {
        self.mutex.lock();
        self.stop_flag = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }

    /// Sleep up to `ms`, waking early on `requestStop`. Returns true to stop.
    fn sleepOrStop(self: *Updater, ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.stop_flag and ms > 0) {
            self.cond.timedWait(&self.mutex, ms * std.time.ns_per_ms) catch {};
        }
        return self.stop_flag;
    }

    /// Back-compat thin wrapper: true iff a fresh update was staged. Used by the
    /// tests; the loop and tray use `checkNow`/`doCheck` for the richer outcome.
    pub fn checkAndStage(self: *Updater) bool {
        return self.doCheck() == .update_staged;
    }

    /// Manual, user-initiated check (the tray "Check for updates"). Single-flight
    /// with the background loop via `checking`, so the two never stage at once.
    /// On a staged update it sets `pending_apply` (the loop then applies it when
    /// idle, without re-downloading) — pair with `wake` to apply promptly.
    pub fn checkNow(self: *Updater) CheckOutcome {
        self.mutex.lock();
        if (self.checking) {
            self.mutex.unlock();
            return .busy;
        }
        self.checking = true;
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            self.checking = false;
            self.mutex.unlock();
        }

        const outcome = self.doCheck();
        if (outcome == .update_staged) {
            self.mutex.lock();
            self.pending_apply = true;
            self.mutex.unlock();
        }
        return outcome;
    }

    /// Wake the loop out of its sleep so a just-staged update applies now (once
    /// idle) instead of at the next 6h check. A spurious wake is harmless — the
    /// loop simply re-evaluates and sleeps again.
    pub fn wake(self: *Updater) void {
        self.mutex.lock();
        self.cond.broadcast();
        self.mutex.unlock();
    }

    /// One manifest check; on a version difference, download + verify + stage.
    /// Returns `.update_staged` when `<exe>.new` is ready to apply, `.up_to_date`
    /// when current, `.check_failed` on any error (the loop retries next cycle).
    /// The quiet no-update paths log only in debug builds.
    fn doCheck(self: *Updater) CheckOutcome {
        const alloc = self.alloc;

        // 1. Fetch + parse the manifest, select this platform's entry.
        const url = std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base_url, manifest_path }) catch return .check_failed;
        defer alloc.free(url);
        var resp = http_client.get(alloc, url, max_manifest_len) catch |err| {
            debugLog("manifest fetch failed ({s})", .{@errorName(err)});
            return .check_failed;
        };
        defer resp.deinit(alloc);
        if (resp.status != 200) {
            debugLog("manifest fetch: HTTP {d}", .{resp.status});
            return .check_failed;
        }
        var entry = parseManifest(alloc, resp.body, platform_key) orelse {
            debugLog("manifest invalid or no entry for {s}", .{platform_key});
            return .check_failed;
        };
        defer entry.deinit(alloc);

        // 2. Version gate.
        if (!updateAvailable(self.local_version, entry.version)) {
            debugLog("up to date ({s})", .{self.local_version});
            return .up_to_date;
        }
        std.debug.print("ghoztty-agent: self-update: update found: {s} -> {s}\n", .{ self.local_version, entry.version });

        // 3. Download the binary (to memory — verified BEFORE anything is
        //    written next to the exe).
        const bin_url = std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base_url, entry.path }) catch return .check_failed;
        defer alloc.free(bin_url);
        var bin = http_client.get(alloc, bin_url, max_binary_len) catch |err| {
            std.debug.print("ghoztty-agent: self-update: download failed ({s}); will retry next cycle\n", .{@errorName(err)});
            return .check_failed;
        };
        defer bin.deinit(alloc);
        if (bin.status != 200 or bin.body.len == 0) {
            std.debug.print("ghoztty-agent: self-update: download failed (HTTP {d}); will retry next cycle\n", .{bin.status});
            return .check_failed;
        }
        std.debug.print("ghoztty-agent: self-update: downloaded {d} bytes\n", .{bin.body.len});

        // 4. Verify SHA-256 against the manifest.
        var expected: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&expected, entry.sha256) catch {
            std.debug.print("ghoztty-agent: self-update: manifest sha256 is not hex; discarding download\n", .{});
            return .check_failed;
        };
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bin.body, &actual, .{});
        if (!std.mem.eql(u8, &expected, &actual)) {
            std.debug.print("ghoztty-agent: self-update: sha256 MISMATCH (want {s}); discarding download, will retry next cycle\n", .{entry.sha256});
            return .check_failed;
        }
        std.debug.print("ghoztty-agent: self-update: sha256 verified\n", .{});

        // 5. Stage crash-safely: write `<exe>.new.tmp`, rename → `<exe>.new`.
        self.stageBytes(bin.body) catch |err| {
            std.debug.print("ghoztty-agent: self-update: staging failed ({s}); will retry next cycle\n", .{@errorName(err)});
            return .check_failed;
        };
        std.debug.print("ghoztty-agent: self-update: staged {s} at {s}.new\n", .{ entry.version, self.exe_path });
        return .update_staged;
    }

    /// Write the verified bytes to `<exe>.new.tmp` (exec bit set on POSIX),
    /// then rename into `<exe>.new` — a torn write can never be applied.
    fn stageBytes(self: *Updater, bytes: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.alloc, "{s}.new.tmp", .{self.exe_path});
        defer self.alloc.free(tmp_path);
        const new_path = try std.fmt.allocPrint(self.alloc, "{s}.new", .{self.exe_path});
        defer self.alloc.free(new_path);
        {
            const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
            defer f.close();
            try f.writeAll(bytes);
            if (builtin.os.tag != .windows) try f.chmod(0o755);
        }
        errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};
        try std.fs.renameAbsolute(tmp_path, new_path);
    }

    /// The SWAP: running exe → `<exe>.old`, `<exe>.new` → exe, then spawn the
    /// new exe with the same argv + `--force-replace`. Every failure rolls the
    /// files back so the still-running (old) process matches its on-disk
    /// binary; the caller retries a full cycle later. On success the caller
    /// must exit promptly (the replacement takes the single-instance guard
    /// from us by force).
    pub fn applyStaged(self: *Updater) !void {
        const new_path = try std.fmt.allocPrint(self.alloc, "{s}.new", .{self.exe_path});
        defer self.alloc.free(new_path);
        const old_path = try std.fmt.allocPrint(self.alloc, "{s}.old", .{self.exe_path});
        defer self.alloc.free(old_path);

        // Clear the .old slot (belt-and-braces; rename overwrites on all three
        // OSes, but a stale immovable .old should not block the swap).
        std.fs.deleteFileAbsolute(old_path) catch {};
        try std.fs.renameAbsolute(self.exe_path, old_path);
        std.fs.renameAbsolute(new_path, self.exe_path) catch |err| {
            std.fs.renameAbsolute(old_path, self.exe_path) catch {};
            return err;
        };

        // Respawn: same argv + --force-replace (dedup'd) so the replacement
        // wins the single-instance takeover against this process.
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        var have_force = false;
        for (self.argv) |a| {
            if (std.mem.eql(u8, a, "--force-replace") or std.mem.eql(u8, a, "--replace")) have_force = true;
            try argv.append(self.alloc, a);
        }
        if (!have_force) try argv.append(self.alloc, "--force-replace");

        std.debug.print("ghoztty-agent: self-update: swapped binaries; respawning {s} --force-replace\n", .{self.exe_path});
        self.spawnFn(self.spawn_ctx, self, argv.items) catch |err| {
            // Undo the swap: better a stale-but-running agent than none.
            std.debug.print("ghoztty-agent: self-update: respawn failed ({s}); rolling back the swap\n", .{@errorName(err)});
            std.fs.renameAbsolute(self.exe_path, new_path) catch {};
            std.fs.renameAbsolute(old_path, self.exe_path) catch {};
            return err;
        };
        std.debug.print("ghoztty-agent: self-update: replacement spawned; exiting\n", .{});
    }

    fn alwaysIdle(_: ?*anyopaque) usize {
        return 0;
    }

    /// Production spawn: detached child (never waited on — it outlives us; on
    /// POSIX it reparents when we exit right after). stdio is dropped: the
    /// replacement's own supervisor/log redirection applies on its next launch,
    /// and inheriting OUR redirected handles would pin them past our exit.
    fn spawnReal(_: ?*anyopaque, self: *Updater, argv: []const []const u8) anyerror!void {
        var child = std.process.Child.init(argv, self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
    }

    fn exitReal(_: *Updater) void {
        std.process.exit(0);
    }
};

/// Debug-level logging: the quiet paths (no manifest, no platform entry, up to
/// date) print only in debug builds — a release agent must not chat every 6h.
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .Debug) {
        std.debug.print("ghoztty-agent: self-update: " ++ fmt ++ "\n", args);
    }
}

/// Live-session count for the idle gate: the DAEMON store's table size —
/// attached AND detached-with-retained-scrollback sessions both count (the
/// idle-TTL reaper is what eventually zeroes abandoned ones).
fn storeLiveSessions(ctx: ?*anyopaque) usize {
    const store: *session.SessionStore = @ptrCast(@alignCast(ctx.?));
    store.mutex.lock();
    defer store.mutex.unlock();
    return store.table.count();
}

/// PRODUCTION wiring, called from relay mode only: honor the kill switch and
/// the dev-build guard, resolve the base URL (relay host, or the env
/// override), capture the running exe path + argv for the respawn, apply the
/// test-interval override, and run the updater on a detached daemon-lifetime
/// thread. Failures only cost the feature, never the daemon.
/// Returns the live `Updater` (for the tray "Check for updates") or null when
/// self-update is disabled (kill switch / dev build) or failed to start.
pub fn maybeStart(
    alloc: Allocator,
    relay_host: []const u8,
    local_version: []const u8,
    store: *session.SessionStore,
) ?*Updater {
    if (std.process.getEnvVarOwned(alloc, env_disable)) |v| {
        defer alloc.free(v);
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
            std.debug.print("ghoztty-agent: self-update: disabled ({s}={s})\n", .{ env_disable, v });
            return null;
        }
    } else |_| {}
    if (std.mem.eql(u8, local_version, "dev")) {
        std.debug.print("ghoztty-agent: self-update: disabled (dev build has no baked version)\n", .{});
        return null;
    }
    return start(alloc, relay_host, local_version, store) catch |err| {
        std.debug.print("ghoztty-agent: self-update: failed to start ({s}); continuing without it\n", .{@errorName(err)});
        return null;
    };
}

fn start(
    alloc: Allocator,
    relay_host: []const u8,
    local_version: []const u8,
    store: *session.SessionStore,
) !*Updater {
    // Everything below is daemon-lifetime (the thread never joins); nothing
    // here is freed on the success path.
    const base_url: []const u8 = blk: {
        if (std.process.getEnvVarOwned(alloc, env_base)) |v| {
            defer alloc.free(v);
            break :blk try alloc.dupe(u8, std.mem.trimRight(u8, v, "/"));
        } else |_| {}
        break :blk try std.fmt.allocPrint(alloc, "https://{s}", .{relay_host});
    };

    const exe_path = try std.fs.selfExePathAlloc(alloc);

    // Respawn argv: THIS exe's real path + the original args (argv[0] may have
    // been relative to a cwd we no longer know).
    const os_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, os_args);
    const argv = try alloc.alloc([]const u8, os_args.len);
    argv[0] = exe_path;
    for (os_args[1..], argv[1..]) |a, *slot| slot.* = try alloc.dupe(u8, a);

    const updater = try alloc.create(Updater);
    updater.* = .{
        .alloc = alloc,
        .base_url = base_url,
        .local_version = local_version,
        .exe_path = exe_path,
        .argv = argv,
        .live_ctx = store,
        .liveSessionsFn = storeLiveSessions,
    };
    if (std.process.getEnvVarOwned(alloc, env_interval)) |v| {
        defer alloc.free(v);
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \r\n"), 10)) |ms| {
            updater.initial_delay_ms = ms;
            updater.check_interval_ms = ms;
            updater.idle_poll_ms = ms;
        } else |_| {}
    } else |_| {}

    const t = try std.Thread.spawn(.{}, Updater.runLoop, .{updater});
    t.detach(); // daemon-lifetime thread; nothing ever joins it
    return updater;
}

/// Best-effort startup cleanup of a previous update's artifacts next to the
/// running exe: the superseded `.old` binary (Windows may still hold it while
/// the old process winds down — ignore, the next restart gets it) and any
/// stale `.new`/`.new.tmp` download (the updater re-stages from scratch).
pub fn cleanupLeftovers(alloc: Allocator) void {
    const exe_path = std.fs.selfExePathAlloc(alloc) catch return;
    defer alloc.free(exe_path);
    cleanupLeftoversAt(alloc, exe_path);
}

/// `cleanupLeftovers` seam (tests point it at a scratch path).
pub fn cleanupLeftoversAt(alloc: Allocator, exe_path: []const u8) void {
    for ([_][]const u8{ ".old", ".new", ".new.tmp" }) |suffix| {
        const p = std.fmt.allocPrint(alloc, "{s}{s}", .{ exe_path, suffix }) catch continue;
        defer alloc.free(p);
        std.fs.deleteFileAbsolute(p) catch {};
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "platform_key: <os>-<arch> of this build" {
    // Exact spot-checks for the platforms the manifest actually ships.
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
        try testing.expectEqualStrings("macos-aarch64", platform_key);
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64)
        try testing.expectEqualStrings("windows-x86_64", platform_key);
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
        try testing.expectEqualStrings("linux-x86_64", platform_key);
    // And the shape holds everywhere.
    try testing.expect(std.mem.indexOfScalar(u8, platform_key, '-') != null);
}

test "parseManifest: selects the platform entry" {
    const json =
        \\{"windows-x86_64": {"version": "20260703-c322788", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "path": "/dl/ghoztty-agent.exe"},
        \\ "macos-aarch64":  {"version": "20260704-deadbee", "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "path": "/dl/ghoztty-agent-macos"}}
    ;
    var win = parseManifest(testing.allocator, json, "windows-x86_64").?;
    defer win.deinit(testing.allocator);
    try testing.expectEqualStrings("20260703-c322788", win.version);
    try testing.expectEqualStrings("/dl/ghoztty-agent.exe", win.path);

    var mac = parseManifest(testing.allocator, json, "macos-aarch64").?;
    defer mac.deinit(testing.allocator);
    try testing.expectEqualStrings("20260704-deadbee", mac.version);
}

test "parseManifest: missing key / malformed input → null (quiet no-update)" {
    const good =
        \\{"macos-aarch64": {"version": "v", "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", "path": "/dl/x"}}
    ;
    try testing.expect(parseManifest(testing.allocator, good, "windows-x86_64") == null);
    try testing.expect(parseManifest(testing.allocator, "not json at all", "macos-aarch64") == null);
    try testing.expect(parseManifest(testing.allocator, "[1,2,3]", "macos-aarch64") == null);
    // Bad fields: short sha, relative path, wrong types, missing fields.
    try testing.expect(parseManifest(testing.allocator,
        \\{"k": {"version": "v", "sha256": "abc", "path": "/x"}}
    , "k") == null);
    try testing.expect(parseManifest(testing.allocator,
        \\{"k": {"version": "v", "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", "path": "x"}}
    , "k") == null);
    try testing.expect(parseManifest(testing.allocator,
        \\{"k": {"version": 7, "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", "path": "/x"}}
    , "k") == null);
    try testing.expect(parseManifest(testing.allocator,
        \\{"k": {"version": "v", "path": "/x"}}
    , "k") == null);
}

test "updateAvailable: inequality, dev never updates" {
    try testing.expect(updateAvailable("20260101-aaaaaaa", "20260703-c322788"));
    try testing.expect(updateAvailable("20260703-c322788", "20260101-aaaaaaa")); // rollback applies too
    try testing.expect(!updateAvailable("20260703-c322788", "20260703-c322788"));
    try testing.expect(!updateAvailable("dev", "20260703-c322788"));
    try testing.expect(!updateAvailable("20260703-c322788", ""));
}

test "cleanupLeftoversAt: removes .old/.new/.new.tmp, missing files fine" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const exe = try std.fs.path.join(testing.allocator, &.{ dir, "ghoztty-agent" });
    defer testing.allocator.free(exe);

    try tmp.dir.writeFile(.{ .sub_path = "ghoztty-agent.old", .data = "o" });
    try tmp.dir.writeFile(.{ .sub_path = "ghoztty-agent.new", .data = "n" });
    cleanupLeftoversAt(testing.allocator, exe); // .new.tmp absent — must not error
    try testing.expectError(error.FileNotFound, tmp.dir.access("ghoztty-agent.old", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access("ghoztty-agent.new", .{}));
}

// -----------------------------------------------------------------------------
// Integration: the full check → stage → idle-gate → swap → respawn cycle
// against a real loopback HTTP server (the same plaintext-http path the
// production http_client uses; only the scheme differs from the relay).
// -----------------------------------------------------------------------------

/// Minimal loopback HTTP/1.1 server: serves the manifest at
/// `/dl/version.json` and the "new binary" bytes at `bin_path`; 404 otherwise.
/// One request per connection (the client sends `Connection: close`).
const TestServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    manifest: []const u8,
    bin_path: []const u8,
    bin: []const u8,
    stop_flag: std.atomic.Value(bool) = .init(false),
    port: u16,

    fn start(self: *TestServer, manifest: []const u8, bin_path: []const u8, bin: []const u8) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .manifest = manifest,
            .bin_path = bin_path,
            .bin = bin,
            .port = undefined,
        };
        self.port = self.listener.listen_address.in.getPort();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *TestServer) void {
        self.stop_flag.store(true, .seq_cst);
        // Unblock accept() with a throwaway connection.
        if (std.net.tcpConnectToAddress(self.listener.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.listener.deinit();
    }

    fn run(self: *TestServer) void {
        while (true) {
            const conn = self.listener.accept() catch return;
            defer conn.stream.close();
            if (self.stop_flag.load(.seq_cst)) return;
            self.serveOne(conn.stream) catch {};
        }
    }

    fn serveOne(self: *TestServer, stream: std.net.Stream) !void {
        // Read until the header terminator (GETs have no body).
        var req: [4096]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOf(u8, req[0..len], "\r\n\r\n") == null) {
            const n = try stream.read(req[len..]);
            if (n == 0) break;
            len += n;
        }
        // "GET <path> HTTP/1.1"
        const line_end = std.mem.indexOf(u8, req[0..len], "\r\n") orelse return;
        var it = std.mem.tokenizeScalar(u8, req[0..line_end], ' ');
        _ = it.next(); // method
        const path = it.next() orelse return;

        const body: ?[]const u8 = if (std.mem.eql(u8, path, manifest_path))
            self.manifest
        else if (std.mem.eql(u8, path, self.bin_path))
            self.bin
        else
            null;

        var hdr_buf: [256]u8 = undefined;
        if (body) |b| {
            const hdr = try std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{b.len});
            try stream.writeAll(hdr);
            try stream.writeAll(b);
        } else {
            try stream.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
    }
};

/// Shared scaffolding for the integration tests: a scratch "install dir" with
/// a fake current exe, a manifest advertising `new_version` for THIS platform
/// with the sha of `payload`, and the loopback server. Frees everything.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    server: TestServer,
    exe_path: []const u8,
    manifest: []const u8,
    base_url: []const u8,

    const old_exe_content = "OLD-BINARY";

    fn init(self: *Fixture, payload: []const u8, sha_override: ?[]const u8) !void {
        const alloc = testing.allocator;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        try self.tmp.dir.writeFile(.{ .sub_path = "ghoztty-agent", .data = old_exe_content });
        const dir = try self.tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(dir);
        self.exe_path = try std.fs.path.join(alloc, &.{ dir, "ghoztty-agent" });
        errdefer alloc.free(self.exe_path);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        const sha_hex = std.fmt.bytesToHex(digest, .lower);

        self.manifest = try std.fmt.allocPrint(
            alloc,
            \\{{"{s}": {{"version": "20990101-abcdef1", "sha256": "{s}", "path": "/dl/agent.bin"}}}}
        ,
            .{ platform_key, sha_override orelse @as([]const u8, &sha_hex) },
        );
        errdefer alloc.free(self.manifest);

        try self.server.start(self.manifest, "/dl/agent.bin", payload);
        self.base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{self.server.port});
    }

    fn deinit(self: *Fixture) void {
        self.server.stop();
        testing.allocator.free(self.base_url);
        testing.allocator.free(self.manifest);
        testing.allocator.free(self.exe_path);
        self.tmp.cleanup();
    }

    fn readInstalled(self: *Fixture, name: []const u8, buf: []u8) ![]u8 {
        const n = try self.tmp.dir.readFile(name, buf);
        return n;
    }
};

/// Captures the respawn for assertions instead of launching anything.
const SpawnCapture = struct {
    called: bool = false,
    saw_force_replace: bool = false,
    argv0: [512]u8 = undefined,
    argv0_len: usize = 0,

    fn hook(ctx: ?*anyopaque, _: *Updater, argv: []const []const u8) anyerror!void {
        const self: *SpawnCapture = @ptrCast(@alignCast(ctx.?));
        self.called = true;
        for (argv) |a| {
            if (std.mem.eql(u8, a, "--force-replace")) self.saw_force_replace = true;
        }
        self.argv0_len = @min(argv[0].len, self.argv0.len);
        @memcpy(self.argv0[0..self.argv0_len], argv[0][0..self.argv0_len]);
    }
};

fn noExit(_: *Updater) void {}

test "checkAndStage: downloads, verifies, and stages <exe>.new" {
    const payload = "NEW-BINARY-CONTENTS-1234567890";
    var fx: Fixture = undefined;
    try fx.init(payload, null);
    defer fx.deinit();

    var updater: Updater = .{
        .alloc = testing.allocator,
        .base_url = fx.base_url,
        .local_version = "20260101-1111111",
        .exe_path = fx.exe_path,
        .argv = &.{},
    };
    try testing.expect(updater.checkAndStage());

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(payload, try fx.readInstalled("ghoztty-agent.new", &buf));
    // The running exe is untouched by staging.
    try testing.expectEqualStrings(Fixture.old_exe_content, try fx.readInstalled("ghoztty-agent", &buf));
    // Crash-safety: the temp download name was renamed away.
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access("ghoztty-agent.new.tmp", .{}));
}

test "checkAndStage: sha256 mismatch discards the download (nothing staged)" {
    var fx: Fixture = undefined;
    try fx.init("NEW-BINARY", "0000000000000000000000000000000000000000000000000000000000000000");
    defer fx.deinit();

    var updater: Updater = .{
        .alloc = testing.allocator,
        .base_url = fx.base_url,
        .local_version = "20260101-1111111",
        .exe_path = fx.exe_path,
        .argv = &.{},
    };
    try testing.expect(!updater.checkAndStage());
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access("ghoztty-agent.new", .{}));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access("ghoztty-agent.new.tmp", .{}));
}

test "checkAndStage: same version / dev build → quiet no-op" {
    var fx: Fixture = undefined;
    try fx.init("NEW-BINARY", null);
    defer fx.deinit();

    var same: Updater = .{
        .alloc = testing.allocator,
        .base_url = fx.base_url,
        .local_version = "20990101-abcdef1", // == manifest version
        .exe_path = fx.exe_path,
        .argv = &.{},
    };
    try testing.expect(!same.checkAndStage());

    var dev: Updater = .{
        .alloc = testing.allocator,
        .base_url = fx.base_url,
        .local_version = "dev",
        .exe_path = fx.exe_path,
        .argv = &.{},
    };
    try testing.expect(!dev.checkAndStage());
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access("ghoztty-agent.new", .{}));
}

test "applyStaged: swaps binaries and respawns with --force-replace" {
    const payload = "NEW-BINARY-CONTENTS";
    var fx: Fixture = undefined;
    try fx.init(payload, null);
    defer fx.deinit();

    var capture: SpawnCapture = .{};
    var updater: Updater = .{
        .alloc = testing.allocator,
        .base_url = fx.base_url,
        .local_version = "20260101-1111111",
        .exe_path = fx.exe_path,
        .argv = &.{ fx.exe_path, "--relay=wss://relay.example.com", "--headless" },
        .spawn_ctx = &capture,
        .spawnFn = SpawnCapture.hook,
        .exitFn = noExit,
    };
    try testing.expect(updater.checkAndStage());
    try updater.applyStaged();

    var buf: [128]u8 = undefined;
    // The exe slot now holds the new binary; the old one was set aside.
    try testing.expectEqualStrings(payload, try fx.readInstalled("ghoztty-agent", &buf));
    try testing.expectEqualStrings(Fixture.old_exe_content, try fx.readInstalled("ghoztty-agent.old", &buf));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access("ghoztty-agent.new", .{}));
    // Respawn: same argv (exe first) + --force-replace appended.
    try testing.expect(capture.called);
    try testing.expect(capture.saw_force_replace);
    try testing.expectEqualStrings(fx.exe_path, capture.argv0[0..capture.argv0_len]);
}

test "runLoop: full cycle gated on idleness (stage → wait → apply → exit)" {
    const payload = "NEW-BINARY-CONTENTS-LOOP";
    var fx: Fixture = undefined;
    try fx.init(payload, null);
    defer fx.deinit();

    const Gate = struct {
        var live: std.atomic.Value(usize) = .init(1);
        var exited: std.atomic.Value(bool) = .init(false);
        fn liveFn(_: ?*anyopaque) usize {
            return live.load(.seq_cst);
        }
        fn exitFn(_: *Updater) void {
            exited.store(true, .seq_cst);
        }
    };
    Gate.live.store(1, .seq_cst);
    Gate.exited.store(false, .seq_cst);

    var capture: SpawnCapture = .{};
    var updater: Updater = .{
        .alloc = testing.allocator,
        .base_url = fx.base_url,
        .local_version = "20260101-1111111",
        .exe_path = fx.exe_path,
        .argv = &.{ fx.exe_path, "--relay=wss://relay.example.com" },
        .initial_delay_ms = 1,
        .check_interval_ms = 5,
        .idle_poll_ms = 5,
        .liveSessionsFn = Gate.liveFn,
        .spawn_ctx = &capture,
        .spawnFn = SpawnCapture.hook,
        .exitFn = Gate.exitFn,
    };

    const t = try std.Thread.spawn(.{}, Updater.runLoop, .{&updater});

    // Phase 1: with a live session, the update stages but must NOT apply.
    var staged = false;
    for (0..500) |_| { // ≤ 5s
        std.Thread.sleep(10 * std.time.ns_per_ms);
        if (fx.tmp.dir.access("ghoztty-agent.new", .{})) |_| {
            staged = true;
            break;
        } else |_| {}
    }
    try testing.expect(staged);
    std.Thread.sleep(50 * std.time.ns_per_ms); // several idle polls
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(Fixture.old_exe_content, try fx.readInstalled("ghoztty-agent", &buf));
    try testing.expect(!Gate.exited.load(.seq_cst));

    // Phase 2: sessions drain to zero → apply + respawn + exit.
    Gate.live.store(0, .seq_cst);
    t.join(); // runLoop returns right after the exit hook
    try testing.expect(Gate.exited.load(.seq_cst));
    try testing.expect(capture.called);
    try testing.expect(capture.saw_force_replace);
    try testing.expectEqualStrings(payload, try fx.readInstalled("ghoztty-agent", &buf));
    try testing.expectEqualStrings(Fixture.old_exe_content, try fx.readInstalled("ghoztty-agent.old", &buf));
}

test "runLoop: requestStop unblocks the initial delay" {
    var updater: Updater = .{
        .alloc = testing.allocator,
        .base_url = "http://127.0.0.1:1", // never reached
        .local_version = "20260101-1111111",
        .exe_path = "/nonexistent/ghoztty-agent",
        .argv = &.{},
        .initial_delay_ms = 60_000,
    };
    const t = try std.Thread.spawn(.{}, Updater.runLoop, .{&updater});
    updater.requestStop();
    t.join(); // must not hang for the full minute
}

test {
    testing.refAllDecls(@This());
}
