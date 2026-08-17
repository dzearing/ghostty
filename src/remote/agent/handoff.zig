//! **Non-destructive agent handoff** (T907, increment 4 of the T705 split —
//! design: `docs/design/agent-nondestructive-handoff.md`).
//!
//! The `ghoztty-agent` outlives the app on purpose, so a delivery swaps
//! `ghoztty-agent.exe` on disk and leaves the RUNNING agent alone. Until now the
//! only two ways to adopt that newer build were both lossy (T662): a silent
//! restart, allowed only at zero live sessions — a box with one always-open pane
//! never reaches it — or a mandatory dialog that closes every session. On a
//! long-lived box the agent simply stayed old.
//!
//! With per-session holders (T904–T906) the shell, its ConPTY and its
//! kill-on-close job live OUTSIDE the agent, so replacing the agent costs
//! nothing. This module is the replacement act:
//!
//! ```
//!   old agent ──spawn(newer exe, --handoff-successor=<private pipe>)──► successor
//!             ◄─────────────── READY <pid> <stamp> ────────────────────
//!             ───── snapshot rings + persist, then GO ────────────────►
//!             ──── exit(0): every holder is released, nothing killed
//!                                                       successor takes the
//!                                                       guard + public pipe and
//!                                                       re-adopts the holders
//! ```
//!
//! ## "Never neither"
//!
//! The old agent gives up NOTHING until the successor has proven it started: it
//! keeps its listener, its guard and its holder connections right up to the GO.
//! Every failure before that point — the exe would not spawn, the successor died
//! on startup, it never answered, it answered with the wrong build — ends with
//! the successor terminated and the old agent still serving, exactly as it was.
//! The successor, for its part, binds nothing public and takes no guard until it
//! has been told GO, so the two can never both be listening either.
//!
//! The one window that exists by construction is between GO and the successor's
//! bind: for a few milliseconds no agent owns the public pipe. That is the same
//! link drop the app's in-place recovery already handles (T145/T723), and the
//! sessions are in holders throughout, so it costs a reconnect and nothing else.
//!
//! ## Who decides
//!
//! The agent does, on its own supervisor thread. The alternative — the app asks
//! it to — was rejected: the agent is the only side that knows which sessions are
//! holder-backed, it needs no new wire opcode to act on what it knows, and it
//! must work with no app running at all (the unattended morning refresh, T525,
//! deliberately never touches the agent). The app's half is only to STAND DOWN,
//! which is what `capability.agent_handoff` negotiates.
//!
//! ## Mixed generations drain lazily
//!
//! A legacy session — one whose ConPTY the agent itself owns, because it predates
//! holders or was opened with the holder path off — cannot be carried across a
//! process boundary at all (the HPCON wall, see the design doc). So the handoff
//! WAITS: while any live session is legacy the supervisor does nothing but say
//! so, and the count is reported through `+sessions --agent`. Every such session
//! that closes brings the box one step closer; the forced path remains the
//! existing explicit confirmation the app offers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const agent_build = @import("../agent_build.zig");
const agent_lineage = @import("../agent_lineage.zig");
const pipe_stream = @import("../pipe_stream.zig");
const session = @import("session.zig");

const is_windows = builtin.os.tag == .windows;
const log = std.log.scoped(.agent_handoff);

// =============================================================================
// Environment knobs
// =============================================================================

/// Kill switch. Any non-empty value disables the supervisor entirely, so a box
/// that hits trouble can be put back on the pre-T907 behavior without a
/// downgrade.
pub const env_disable = "GHOZTTY_AGENT_NO_HANDOFF";

/// How often the supervisor looks at the binary on disk, in milliseconds.
/// Lowered by acceptance scripts; the default is deliberately unhurried — the
/// check is a `stat`, and only a CHANGED file costs a `--version` spawn.
pub const env_interval = "GHOZTTY_AGENT_HANDOFF_INTERVAL_MS";

/// **Debug builds only.** Hand off to the on-disk binary at the next check
/// without requiring it to be a newer build.
///
/// Every stamp in one tree comes from one binary, so without this an acceptance
/// script could never reach the handoff arm at all: there is no way to make a
/// second, NEWER agent out of the tree under test. It is read once and then
/// **removed from this process's environment block**, so no descendant inherits
/// it — a successor that did would hand off again immediately, forever.
///
/// Never honored in a release build, where a stray environment variable must not
/// be able to restart a user's agent.
pub const env_force = "GHOZTTY_AGENT_HANDOFF_FORCE";

pub const default_interval_ms: u64 = 60 * std.time.ms_per_s;

/// How long the old agent waits for the successor to answer at all. Generous:
/// a cold-started exe on a loaded box, reading `sessions.json` on the way.
pub const dial_timeout_ms: u64 = 20 * std.time.ms_per_s;

/// How long the old agent waits for the READY line once connected.
pub const ready_timeout_ms: u64 = 10 * std.time.ms_per_s;

/// The successor's own deadline: if it has not been told GO within this, it
/// exits rather than lingering as a process that binds nothing and does nothing.
/// Comfortably longer than the two above, so the OLD agent's timeout is always
/// the one that fires first and the rollback is always the deliberate one.
pub const successor_deadline_ms: u64 = 60 * std.time.ms_per_s;

// =============================================================================
// The wire between the two agents (pure)
// =============================================================================
//
// Two newline-terminated ASCII lines over a private, owner-only-DACL named pipe.
// Deliberately not the JSON frame protocol the app speaks: this conversation has
// exactly two messages, it happens between two builds of the SAME program, and
// the whole value of the handoff is that it cannot half-work — a parser with
// more than one shape to get wrong is the wrong tool.

/// What the successor says when it is up and waiting for permission.
pub const Ready = struct {
    pid: u32,
    /// The successor's baked build stamp. It must equal the stamp the old agent
    /// read out of the binary it spawned: a mismatch means the process about to
    /// inherit every session is not the one that was probed, which is not a fact
    /// to discover after exiting.
    stamp: []const u8,
};

/// `READY <pid> <stamp>\n` into `buf`.
pub fn formatReady(buf: []u8, pid: u32, stamp: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "READY {d} {s}\n", .{ pid, stamp });
}

/// Parse one READY line (with or without its newline). Null for anything that is
/// not exactly the expected shape — an unparseable greeting is a failed handoff,
/// never a hopeful guess, because the next thing the old agent would do on a
/// "yes" is exit.
pub fn parseReady(raw: []const u8) ?Ready {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const verb = it.next() orelse return null;
    if (!std.mem.eql(u8, verb, "READY")) return null;
    const pid_tok = it.next() orelse return null;
    const stamp = it.next() orelse return null;
    if (it.next() != null) return null;
    if (stamp.len == 0) return null;
    const pid = std.fmt.parseInt(u32, pid_tok, 10) catch return null;
    return .{ .pid = pid, .stamp = stamp };
}

/// The old agent's permission to take over.
pub const go_line = "GO\n";

/// Is `raw` the GO line? Anything else — including a truncated read or a closed
/// pipe — is not, and the successor exits rather than binding on a maybe.
pub fn isGo(raw: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "GO");
}

// =============================================================================
// Which binary would we hand off TO (pure)
// =============================================================================

/// Strip the backup suffix every delivery leaves on the RUNNING agent's image.
///
/// A running exe cannot be deleted or overwritten on Windows, so
/// `upgrade-ghoztty-windows.ps1` renames it out of the way
/// (`ghoztty-agent.exe` → `ghoztty-agent.exe.bak`, or `.bak-20260803-090358`)
/// and copies the new build into the ORIGINAL path. From inside the running
/// process, therefore, "the newer build on disk" is our own image path with that
/// suffix removed — the same reasoning `agent_upgrade.imageIsAgent` matches on
/// from the app side, and the reason it matches on a prefix rather than a name.
///
/// Returns the input unchanged when it carries no such suffix, which is the
/// steady state (a freshly installed agent has never been renamed).
pub fn stripBackupSuffix(path: []const u8) []const u8 {
    const marker = ".bak";
    // Find the LAST `.bak` that starts a suffix of the form `.bak` or `.bak-…`,
    // so `.exe.bak-2026…` and `.exe.bak` both resolve to `.exe`.
    var i = path.len;
    while (i > marker.len) {
        i -= 1;
        if (path[i] != '.') continue;
        if (i + marker.len > path.len) continue;
        if (!std.ascii.eqlIgnoreCase(path[i .. i + marker.len], marker)) continue;
        const rest = path[i + marker.len ..];
        if (rest.len == 0 or rest[0] == '-') return path[0..i];
    }
    return path;
}

/// The path of the binary a handoff would run, or null when there is none to
/// consider (our image is not a backup, so nothing newer has been laid down
/// beside it under the canonical name).
///
/// `exists` answers "is there a file here?" and is injected so the rule is
/// testable without a filesystem.
pub fn candidatePath(self_exe: []const u8, exists: *const fn ([]const u8) bool) ?[]const u8 {
    const canonical = stripBackupSuffix(self_exe);
    if (canonical.len == self_exe.len) return null;
    if (!exists(canonical)) return null;
    return canonical;
}

// =============================================================================
// The decision (pure)
// =============================================================================

/// What the supervisor should do about the binary it just looked at.
pub const Verdict = enum {
    /// Nothing to adopt: no candidate on disk, it is not newer, or we could not
    /// read its stamp. Rule 1 of the upgrade policy — never act on a guess.
    none,
    /// A newer build IS there, but live sessions still own their ConPTY inside
    /// this process and cannot be carried across. Wait for them to close.
    wait_drain,
    /// Stale, and every live session is holder-backed. Hand off.
    handoff,
};

/// The whole policy in one pure function.
///
/// `on_disk == null` means we could not read the candidate's stamp (no file, or
/// `--version` failed), which is `.none` for the same reason the app's policy
/// treats an unreadable bundled binary that way: an unknown is not evidence.
///
/// `force` is the debug-only test seam (`env_force`) and skips ONLY the
/// staleness comparison. It deliberately does NOT skip the drain gate: a test
/// that could lose a session would be testing something we do not ship.
///
/// It is safe for `force` to skip the comparison entirely — including the "is
/// this the same build?" half — because `candidatePath` has already refused the
/// only dangerous case structurally: a candidate that resolves back to the
/// RUNNING image is not a candidate at all. What is left is a different file,
/// which under `force` is exactly what a test wants and in production is
/// unreachable (the flag is release-gated off).
pub fn decide(
    self_stamp: []const u8,
    on_disk: ?[]const u8,
    mix: session.SessionTable.LiveMix,
    force: bool,
) Verdict {
    const candidate = on_disk orelse return .none;
    if (candidate.len == 0) return .none;
    if (!force and !agent_build.isStale(self_stamp, candidate)) return .none;
    return if (mix.handoffSafe()) .handoff else .wait_drain;
}

// =============================================================================
// Reporting (pure)
// =============================================================================

/// One clause for the log line / `+sessions --agent`, naming what is holding a
/// handoff back. Written into `buf`.
pub fn formatDrain(buf: []u8, legacy: usize) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d} session{s} still owned by this agent must close first",
        .{ legacy, if (legacy == 1) "" else "s" },
    );
}

// =============================================================================
// The private pipe name
// =============================================================================

/// `\\.\pipe\ghoztty-agent-handoff[-debug]-<user>-<nonce>` — one name per
/// attempt, so a retried handoff never meets the previous attempt's pipe.
///
/// Build-mode segmented and lineage-suffixed for the same reason every other
/// endpoint here is (T350): a debug agent under test must not be able to talk to
/// the release agent the user is sitting in front of.
pub fn pipeName(alloc: Allocator, is_debug: bool, nonce: u64) ![]u8 {
    var user_buf: [256]u8 = undefined;
    const user = userName(&user_buf) orelse "user";
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const suffix = agent_lineage.fromEnv(&sfx_buf) orelse "";
    return std.fmt.allocPrint(
        alloc,
        "\\\\.\\pipe\\ghoztty-agent-handoff{s}{s}{s}-{s}-{x:0>16}",
        .{
            if (is_debug) "-debug" else "",
            if (suffix.len > 0) "-" else "",
            suffix,
            user,
            nonce,
        },
    );
}

fn userName(buf: []u8) ?[]const u8 {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, "USERNAME") catch return null;
    defer std.heap.page_allocator.free(v);
    if (v.len == 0 or v.len > buf.len) return null;
    // Pipe names are a flat namespace: keep it to characters that cannot be
    // mistaken for a separator.
    for (v, 0..) |c, i| buf[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    return buf[0..v.len];
}

// =============================================================================
// Mechanism (Windows)
// =============================================================================

pub const Supervisor = if (is_windows) win.SupervisorImpl else stub.SupervisorImpl;

/// The successor's half: bind the private pipe named on our command line, report
/// READY, and block until the predecessor says GO. Returns an error on anything
/// else, and the caller must then exit WITHOUT binding anything public.
pub const awaitGo = if (is_windows) win.awaitGoImpl else stub.awaitGoImpl;

const stub = struct {
    const SupervisorImpl = struct {
        pub fn start(_: Allocator, _: *session.SessionStore, _: []const u8) void {}
    };
    fn awaitGoImpl(_: Allocator, _: []const u8) !void {
        return error.Unsupported;
    }
};

const win = struct {
    const windows = std.os.windows;
    const job_spawn = @import("../../apprt/win32/job_spawn.zig");

    extern "kernel32" fn SetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpValue: ?[*:0]const u16,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: windows.HANDLE,
        lpBuffer: ?*anyopaque,
        nBufferSize: windows.DWORD,
        lpBytesRead: ?*windows.DWORD,
        lpTotalBytesAvail: ?*windows.DWORD,
        lpBytesLeftThisMessage: ?*windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    fn takeForceFlag(alloc: Allocator) bool {
        if (!@import("agent_build_options").is_debug) return false;
        const v = std.process.getEnvVarOwned(alloc, env_force) catch return false;
        defer alloc.free(v);
        const on = v.len > 0 and !std.mem.eql(u8, v, "0");
        // Remove it from OUR environment block whether or not it was on, so a
        // successor can never inherit it and hand off again in a loop. A child
        // spawned with no explicit environment inherits the block as it stands
        // NOW, so clearing it here is enough — there is no per-spawn filtering
        // to remember at each call site.
        _ = SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(env_force), null);
        return on;
    }

    /// The background thread that watches the binary beside us.
    const SupervisorImpl = struct {
        alloc: Allocator,
        store: *session.SessionStore,
        self_stamp: []const u8,
        interval_ms: u64,
        force: bool,
        /// (size, mtime) of the candidate the last `--version` probe read, so a
        /// steady box pays a `stat` per tick and nothing more.
        probed: ?Probed = null,

        const Probed = struct {
            size: u64,
            mtime: i128,
            stamp: ?[]u8,
            /// Handoffs attempted against THIS exact file that rolled back.
            failures: usize = 0,
        };

        /// How many times a given on-disk binary is tried before the supervisor
        /// stops reaching for it.
        ///
        /// A rollback is safe — the old agent keeps serving — but it is not free:
        /// it spawns a process every interval, forever, against a build that has
        /// already proven it will not come up. The count resets when the file
        /// changes, which is the only event that makes the next attempt different
        /// from the last one. Same shape, and the same reasoning, as the app's
        /// `max_agent_upgrade_attempts`.
        const max_attempts_per_build: usize = 3;

        /// Start watching. Best-effort: a supervisor that cannot start leaves the
        /// agent exactly as it was before T907, which is a working agent.
        pub fn start(alloc: Allocator, store: *session.SessionStore, self_stamp: []const u8) void {
            if (disabled(alloc)) {
                log.debug("handoff supervisor disabled by {s}", .{env_disable});
                return;
            }
            const force = takeForceFlag(alloc);
            const self = alloc.create(SupervisorImpl) catch return;
            self.* = .{
                .alloc = alloc,
                .store = store,
                .self_stamp = self_stamp,
                .interval_ms = intervalMs(alloc),
                .force = force,
            };
            const t = std.Thread.spawn(.{}, run, .{self}) catch {
                alloc.destroy(self);
                return;
            };
            t.detach();
        }

        fn run(self: *SupervisorImpl) void {
            while (true) {
                std.Thread.sleep(self.interval_ms * std.time.ns_per_ms);
                self.tick();
            }
        }

        fn tick(self: *SupervisorImpl) void {
            const exe = std.fs.selfExePathAlloc(self.alloc) catch return;
            defer self.alloc.free(exe);
            const candidate = candidatePath(exe, fileExists) orelse return;

            const stamp = self.candidateStamp(candidate) orelse return;

            const mix = blk: {
                self.store.mutex.lock();
                defer self.store.mutex.unlock();
                break :blk self.store.table.liveMix();
            };

            switch (decide(self.self_stamp, stamp, mix, self.force)) {
                .none => return,
                .wait_drain => {
                    var buf: [128]u8 = undefined;
                    const why = formatDrain(&buf, mix.legacy) catch return;
                    log.info(
                        "a newer agent ({s}) is on disk but the handoff is waiting: {s}",
                        .{ stamp, why },
                    );
                },
                .handoff => {
                    if (self.probed) |p| if (p.failures >= max_attempts_per_build) {
                        log.debug(
                            "not retrying the handoff to {s}: {d} attempt(s) already rolled back",
                            .{ stamp, p.failures },
                        );
                        return;
                    };
                    // `perform` returns only on FAILURE — success exits the
                    // process — so reaching the next line IS the rollback.
                    self.perform(candidate, stamp);
                    if (self.probed) |*p| {
                        p.failures += 1;
                        if (p.failures >= max_attempts_per_build) log.warn(
                            "handoff to {s} rolled back {d} times; not trying again until that binary changes",
                            .{ stamp, p.failures },
                        );
                    }
                },
            }
        }

        /// The candidate's build stamp, cached against its (size, mtime) so an
        /// unchanged file costs no process spawn.
        fn candidateStamp(self: *SupervisorImpl, path: []const u8) ?[]const u8 {
            const st = std.fs.cwd().statFile(path) catch return null;
            if (self.probed) |p| {
                if (p.size == st.size and p.mtime == st.mtime) return p.stamp;
                if (p.stamp) |s| self.alloc.free(s);
                self.probed = null;
            }

            const result = std.process.Child.run(.{
                .allocator = self.alloc,
                .argv = &.{ path, "--version" },
                .max_output_bytes = 4096,
            }) catch {
                self.probed = .{ .size = st.size, .mtime = st.mtime, .stamp = null };
                return null;
            };
            defer self.alloc.free(result.stdout);
            defer self.alloc.free(result.stderr);

            const parsed = agent_build.parseVersionOutput(result.stdout);
            const owned: ?[]u8 = if (parsed) |p| (self.alloc.dupe(u8, p) catch null) else null;
            self.probed = .{ .size = st.size, .mtime = st.mtime, .stamp = owned };
            return owned;
        }

        /// The choreography. Returns only on FAILURE — a successful handoff exits
        /// the process.
        fn perform(self: *SupervisorImpl, candidate: []const u8, stamp: []const u8) void {
            var arena_state = std.heap.ArenaAllocator.init(self.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var nonce: u64 = 0;
            std.crypto.random.bytes(std.mem.asBytes(&nonce));
            const pipe = pipeName(arena, is_debug_build, nonce) catch return;

            const cmd = buildCommandLine(arena, candidate, pipe) catch |err| {
                log.warn("handoff: could not build the successor command line: {}", .{err});
                return;
            };
            const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(arena, cmd) catch return;

            log.info("handoff: starting successor ({s} -> {s})", .{ self.self_stamp, stamp });

            // Out of our job, for the same reason a holder is: the successor must
            // outlive us, and a job teardown that kills us would kill it too.
            const spawned = job_spawn.spawnEscapingJob(
                arena,
                cmd_w,
                job_spawn.DETACHED_PROCESS | job_spawn.CREATE_NO_WINDOW,
                "agent handoff",
            ) catch |err| {
                log.warn("handoff aborted: could not spawn the successor: {}", .{err});
                return;
            };
            windows.CloseHandle(spawned.pi.hThread);
            var keep_successor = false;
            defer if (!keep_successor) {
                _ = windows.kernel32.TerminateProcess(spawned.pi.hProcess, 1);
                windows.CloseHandle(spawned.pi.hProcess);
            };

            const handle = dialSuccessor(arena, pipe, spawned.pi.hProcess) catch |err| {
                log.warn("handoff aborted: the successor never answered ({}); this agent keeps serving", .{err});
                return;
            };
            var stream = pipe_stream.PipeStream.init(handle);
            const io = stream.serverStream();
            defer io.close();

            var line_buf: [512]u8 = undefined;
            const line = readLine(handle, io, &line_buf, ready_timeout_ms) catch |err| {
                log.warn("handoff aborted: no READY from the successor ({}); this agent keeps serving", .{err});
                return;
            };
            const ready = parseReady(line) orelse {
                log.warn("handoff aborted: the successor greeted with something else; this agent keeps serving", .{});
                return;
            };
            // The process that answered must be the BINARY WE SPAWNED. The pipe
            // carries an owner-only DACL and a per-attempt nonce, so this is not
            // the first line of defence — but a mismatch means the thing about to
            // inherit every session is not the thing we probed, and that is not a
            // fact to discover after exiting.
            if (!std.mem.eql(u8, ready.stamp, stamp)) {
                log.warn(
                    "handoff aborted: the successor reports build {s}, but the binary we spawned reports {s}; this agent keeps serving",
                    .{ ready.stamp, stamp },
                );
                return;
            }

            // The point of no return is one line away, so bring disk state up to
            // date FIRST: the successor re-adopts each holder at the offset the
            // ring SNAPSHOT ends at (T906), and `persistMeta` is what writes that
            // watermark down. (The stretch between this snapshot and our exit is
            // T911's known exposure — milliseconds here, and reported by the
            // successor rather than silent.)
            self.store.snapshotRings();
            self.store.persistMeta();

            io.writeAll(go_line) catch |err| {
                log.warn("handoff aborted: could not send GO ({}); this agent keeps serving", .{err});
                return;
            };

            keep_successor = true;
            log.info(
                "handoff: successor pid {d} ({s}) is taking over; exiting so it can adopt the holders",
                .{ ready.pid, ready.stamp },
            );
            // Exit rather than unwind: process death is what releases the holder
            // connections, and it is the same teardown the console-ctrl stop
            // already uses. Nothing is terminated on the way out.
            std.process.exit(0);
        }

        /// Every argument we were started with, retargeted at `candidate` and
        /// carrying the handoff pipe + `--force-replace`.
        fn buildCommandLine(arena: Allocator, candidate: []const u8, pipe: []const u8) ![]u8 {
            const args = try std.process.argsAlloc(arena);
            var out: std.ArrayList(u8) = .empty;
            try appendQuoted(arena, &out, candidate);
            for (args[1..]) |a| {
                // Never carry a previous handoff's private pipe forward, and
                // never double `--force-replace`.
                if (std.mem.startsWith(u8, a, successor_flag ++ "=")) continue;
                if (std.mem.eql(u8, a, "--force-replace") or std.mem.eql(u8, a, "--replace")) continue;
                try out.append(arena, ' ');
                try appendQuoted(arena, &out, a);
            }
            try out.append(arena, ' ');
            try appendQuoted(arena, &out, try std.fmt.allocPrint(arena, "{s}={s}", .{ successor_flag, pipe }));
            try out.appendSlice(arena, " --force-replace");
            return out.toOwnedSlice(arena);
        }

        const is_debug_build = @import("agent_build_options").is_debug;
    };

    /// Quote one argument the way `CommandLineToArgvW` un-quotes it. Our
    /// arguments are paths and flag=value pairs — they can contain spaces but
    /// never a `"` — so this is the short, correct rule rather than the full
    /// backslash-run dance. (Same reasoning, and same shape, as the holder
    /// spawn's quoting in `pty_holder_child.zig`.)
    fn appendQuoted(arena: Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
        const needs = std.mem.indexOfAny(u8, arg, " \t") != null;
        if (!needs) return out.appendSlice(arena, arg);
        try out.append(arena, '"');
        try out.appendSlice(arena, arg);
        try out.append(arena, '"');
    }

    fn fileExists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    fn disabled(alloc: Allocator) bool {
        const v = std.process.getEnvVarOwned(alloc, env_disable) catch return false;
        defer alloc.free(v);
        return v.len > 0 and !std.mem.eql(u8, v, "0");
    }

    fn intervalMs(alloc: Allocator) u64 {
        const v = std.process.getEnvVarOwned(alloc, env_interval) catch return default_interval_ms;
        defer alloc.free(v);
        const n = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch return default_interval_ms;
        // A zero/absurd interval would spin; clamp rather than refuse, so a typo
        // in a test script slows the loop instead of disabling the feature.
        return @max(n, 100);
    }

    /// Connect to the successor's private pipe, giving up early if the process
    /// died — a successor that crashed on startup must fail the handoff in
    /// milliseconds, not after the full dial timeout.
    fn dialSuccessor(alloc: Allocator, pipe: []const u8, proc: windows.HANDLE) !windows.HANDLE {
        var waited: u64 = 0;
        while (true) {
            if (pipe_stream.dialHandle(alloc, pipe)) |h| return h else |_| {}
            if (windows.kernel32.WaitForSingleObject(proc, 0) == windows.WAIT_OBJECT_0) {
                return error.SuccessorDied;
            }
            if (waited >= dial_timeout_ms) return error.Timeout;
            std.Thread.sleep(50 * std.time.ns_per_ms);
            waited += 50;
        }
    }

    /// Read one newline-terminated line, bounded. `PeekNamedPipe` never blocks
    /// and never consumes, which is how a deadline is put on an overlapped pipe
    /// read (the same poll `holder_adopt.waitReadable` uses).
    fn readLine(handle: windows.HANDLE, io: anytype, buf: []u8, timeout_ms: u64) ![]const u8 {
        var len: usize = 0;
        var waited: u64 = 0;
        while (true) {
            var avail: windows.DWORD = 0;
            if (PeekNamedPipe(handle, null, 0, null, &avail, null) == 0) return error.Closed;
            if (avail > 0) {
                if (len >= buf.len) return error.LineTooLong;
                const n = try io.read(buf[len..]);
                if (n == 0) return error.Closed;
                len += n;
                if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| return buf[0..nl];
                continue;
            }
            if (waited >= timeout_ms) return error.Timeout;
            std.Thread.sleep(25 * std.time.ns_per_ms);
            waited += 25;
        }
    }

    /// The successor's half.
    fn awaitGoImpl(alloc: Allocator, pipe: []const u8) !void {
        var listener = try pipe_stream.PipeListener.bind(alloc, pipe);
        defer listener.deinit();

        // Nothing about this wait is cancellable — `accept` blocks in the kernel
        // — so the deadline is a thread that ends the process. Safe by
        // construction: until GO lands we hold no guard and no public pipe, so
        // there is nothing for an abrupt exit to leave behind.
        const watchdog = std.Thread.spawn(.{}, deadlineWatchdog, .{}) catch null;
        if (watchdog) |t| t.detach();

        const handle = try listener.accept();
        var stream = pipe_stream.PipeStream.init(handle);
        const io = stream.serverStream();
        defer io.close();

        var buf: [256]u8 = undefined;
        const greeting = try formatReady(
            &buf,
            @intCast(windows.GetCurrentProcessId()),
            @import("agent_build_options").agent_version,
        );
        try io.writeAll(greeting);

        var line_buf: [256]u8 = undefined;
        const line = try readLine(handle, io, &line_buf, successor_deadline_ms);
        if (!isGo(line)) return error.HandoffRefused;
        handoff_done.store(true, .release);
    }

    var handoff_done: std.atomic.Value(bool) = .init(false);

    fn deadlineWatchdog() void {
        std.Thread.sleep(successor_deadline_ms * std.time.ns_per_ms);
        if (handoff_done.load(.acquire)) return;
        std.debug.print(
            "ghoztty-agent: handoff: predecessor never said GO within {d}ms; exiting without binding anything\n",
            .{successor_deadline_ms},
        );
        std.process.exit(3);
    }
};

/// The command-line flag that makes a starting agent a handoff SUCCESSOR: it
/// binds this private pipe, reports READY, and waits for GO before it takes the
/// single-instance guard or binds the public pipe.
pub const successor_flag = "--handoff-successor";

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "READY round-trips, and anything else is refused" {
    var buf: [128]u8 = undefined;
    const line = try formatReady(&buf, 4242, "20260817-abcdef012");
    try testing.expectEqualStrings("READY 4242 20260817-abcdef012\n", line);

    const r = parseReady(line).?;
    try testing.expectEqual(@as(u32, 4242), r.pid);
    try testing.expectEqualStrings("20260817-abcdef012", r.stamp);
    // With or without the newline, and tolerant of CRLF (a line that crossed a
    // console on the way somewhere would still be the same message).
    try testing.expect(parseReady("READY 1 dev") != null);
    try testing.expect(parseReady("READY 1 dev\r\n") != null);

    // Everything that is not exactly the greeting. The old agent EXITS on a
    // successful parse, so a hopeful guess here costs the user their agent.
    try testing.expect(parseReady("") == null);
    try testing.expect(parseReady("GO") == null);
    try testing.expect(parseReady("READY") == null);
    try testing.expect(parseReady("READY 4242") == null);
    try testing.expect(parseReady("READY x dev") == null);
    try testing.expect(parseReady("READY -1 dev") == null);
    try testing.expect(parseReady("READY 1 dev extra") == null);
    try testing.expect(parseReady("ready 1 dev") == null);
}

test "GO is recognized, and a truncated or empty read is not" {
    try testing.expect(isGo("GO"));
    try testing.expect(isGo("GO\n"));
    try testing.expect(isGo("GO\r\n"));
    try testing.expect(!isGo(""));
    try testing.expect(!isGo("G"));
    try testing.expect(!isGo("GONE"));
    try testing.expect(!isGo("NO"));
}

test "stripBackupSuffix undoes what every delivery does to the running image" {
    // The two shapes `upgrade-ghoztty-windows.ps1` produces.
    try testing.expectEqualStrings(
        "C:\\p\\Ghoztty\\ghoztty-agent.exe",
        stripBackupSuffix("C:\\p\\Ghoztty\\ghoztty-agent.exe.bak"),
    );
    try testing.expectEqualStrings(
        "C:\\p\\Ghoztty\\ghoztty-agent.exe",
        stripBackupSuffix("C:\\p\\Ghoztty\\ghoztty-agent.exe.bak-20260803-090358"),
    );
    // Case-insensitive, like the filesystem.
    try testing.expectEqualStrings("C:\\p\\a.exe", stripBackupSuffix("C:\\p\\a.exe.BAK"));

    // The steady state: a binary that has never been renamed is left alone.
    try testing.expectEqualStrings(
        "C:\\p\\Ghoztty\\ghoztty-agent.exe",
        stripBackupSuffix("C:\\p\\Ghoztty\\ghoztty-agent.exe"),
    );
    // A `.bak` that is not a SUFFIX, and a directory that merely contains one.
    try testing.expectEqualStrings("C:\\p\\a.bak.exe", stripBackupSuffix("C:\\p\\a.bak.exe"));
    try testing.expectEqualStrings("C:\\bak\\a.exe", stripBackupSuffix("C:\\bak\\a.exe"));
    try testing.expectEqualStrings("", stripBackupSuffix(""));
}

test "candidatePath: only a renamed image has a newer build beside it" {
    const Fake = struct {
        fn yes(_: []const u8) bool {
            return true;
        }
        fn no(_: []const u8) bool {
            return false;
        }
    };

    // The production shape: we are running the `.bak` the delivery left, and the
    // new build sits under the canonical name.
    try testing.expectEqualStrings(
        "C:\\p\\ghoztty-agent.exe",
        candidatePath("C:\\p\\ghoztty-agent.exe.bak", Fake.yes).?,
    );

    // Not renamed ⇒ nothing was laid down beside us ⇒ nothing to hand off to.
    // This is the case on every box that has never taken a delivery, and it must
    // never resolve to our own path (handing off to ourselves is a restart with
    // extra steps).
    try testing.expect(candidatePath("C:\\p\\ghoztty-agent.exe", Fake.yes) == null);
    // Renamed, but the canonical name is gone (a delivery that removed rather
    // than replaced): no file, no handoff.
    try testing.expect(candidatePath("C:\\p\\ghoztty-agent.exe.bak", Fake.no) == null);
}

test "decide: never on a guess, never while a legacy session is live" {
    const mine = "20260810-aaaaaaaaa";
    const newer = "20260817-bbbbbbbbb";
    const older = "20260701-ccccccccc";
    const clean: session.SessionTable.LiveMix = .{ .holder_backed = 3, .legacy = 0 };
    const mixed: session.SessionTable.LiveMix = .{ .holder_backed = 3, .legacy = 2 };
    const empty: session.SessionTable.LiveMix = .{};

    // Rule 1: an unreadable candidate is not evidence of anything.
    try testing.expectEqual(Verdict.none, decide(mine, null, clean, false));
    try testing.expectEqual(Verdict.none, decide(mine, "", clean, false));

    // Current and NEWER are both left alone — never downgrade, exactly as the
    // app-side policy does not.
    try testing.expectEqual(Verdict.none, decide(mine, mine, clean, false));
    try testing.expectEqual(Verdict.none, decide(mine, older, clean, false));

    // The headline: stale, and nothing live that cannot be carried.
    try testing.expectEqual(Verdict.handoff, decide(mine, newer, clean, false));
    // Idle is the same answer for the same reason.
    try testing.expectEqual(Verdict.handoff, decide(mine, newer, empty, false));

    // A single legacy session holds the whole box back, however many
    // holder-backed ones there are. It WAITS — it never proceeds and it never
    // gives up.
    try testing.expectEqual(Verdict.wait_drain, decide(mine, newer, mixed, false));
    try testing.expectEqual(
        Verdict.wait_drain,
        decide(mine, newer, .{ .holder_backed = 0, .legacy = 1 }, false),
    );
}

test "decide: the force seam skips staleness and NOTHING else" {
    const mine = "20260810-aaaaaaaaa";
    const older = "20260701-ccccccccc";
    const clean: session.SessionTable.LiveMix = .{ .holder_backed = 1, .legacy = 0 };
    const mixed: session.SessionTable.LiveMix = .{ .holder_backed = 1, .legacy = 1 };

    // What it is for: one tree cannot produce two stamps, so an acceptance script
    // could otherwise never reach the handoff arm at all. Including the case the
    // acceptance script actually creates — two copies of the SAME binary, one
    // renamed — which is why the equality half is skipped too.
    try testing.expectEqual(Verdict.handoff, decide(mine, older, clean, true));
    try testing.expectEqual(Verdict.handoff, decide(mine, mine, clean, true));

    // What it must NOT skip. A forced test that could lose a session would be
    // testing something we do not ship.
    try testing.expectEqual(Verdict.wait_drain, decide(mine, older, mixed, true));
    try testing.expectEqual(Verdict.wait_drain, decide(mine, mine, mixed, true));
    // Nor does it invent a candidate.
    try testing.expectEqual(Verdict.none, decide(mine, null, clean, true));
    try testing.expectEqual(Verdict.none, decide(mine, "", clean, true));
}

test "LiveMix.handoffSafe is about legacy sessions, not about being idle" {
    const M = session.SessionTable.LiveMix;
    try testing.expect((M{}).handoffSafe());
    try testing.expect((M{ .holder_backed = 9 }).handoffSafe());
    try testing.expect(!(M{ .legacy = 1 }).handoffSafe());
    try testing.expect(!(M{ .holder_backed = 9, .legacy = 1 }).handoffSafe());
    try testing.expectEqual(@as(usize, 10), (M{ .holder_backed = 9, .legacy = 1 }).live());
}

test "formatDrain pluralizes the count a user is asked to wait for" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "1 session still owned by this agent must close first",
        try formatDrain(&buf, 1),
    );
    var buf2: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "3 sessions still owned by this agent must close first",
        try formatDrain(&buf2, 3),
    );
}

test "pipeName is build-mode segmented and unique per attempt" {
    const alloc = testing.allocator;
    const debug = try pipeName(alloc, true, 0x1234);
    defer alloc.free(debug);
    const release = try pipeName(alloc, false, 0x1234);
    defer alloc.free(release);

    try testing.expect(std.mem.startsWith(u8, debug, "\\\\.\\pipe\\ghoztty-agent-handoff-debug-"));
    try testing.expect(std.mem.startsWith(u8, release, "\\\\.\\pipe\\ghoztty-agent-handoff-"));
    // T350 endpoint isolation: a dev agent's handoff must be unreachable from
    // the release agent the user is sitting in front of.
    try testing.expect(!std.mem.eql(u8, debug, release));
    // The nonce is what stops a retried handoff meeting the previous attempt's
    // pipe (a name only vanishes when its last handle closes).
    const other = try pipeName(alloc, true, 0x5678);
    defer alloc.free(other);
    try testing.expect(!std.mem.eql(u8, debug, other));
    try testing.expect(std.mem.endsWith(u8, debug, "0000000000001234"));
}
