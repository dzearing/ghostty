//! `wp4-e2e` — the WP4 Phase-1 headless de-risk harness.
//!
//! Proves the **REAL surface path** works over TCP against the **real,
//! channel-authoritative** `ghoztty-agent` WITHOUT the `test_client.zig`
//! frame-level workaround: it uses the high-level `Connection.openChannel` — the
//! exact call `src/termio/Remote.zig` makes — to open a shell session, sends
//! `echo wp4-foundation\r` as DATA, and asserts the echoed output comes back
//! through the inbound ring on the agent-authoritative data channel.
//!
//! Why this is the de-risk: the agent mints its OWN session channel and replies
//! OPENED on it (see `agent/server.zig`). Before the WP4 rendezvous fix,
//! `Connection.openChannel` correlated the OPENED reply by the channel it SENT
//! OPEN on, so the two never met against the real agent and `openChannel` hung
//! (`error.OpenTimeout` here). After the fix, `openChannel` adopts the
//! agent-chosen channel from the OPENED frame and registers its ring there — so
//! this harness round-trips. It FAILS before the fix and PASSES after.
//!
//! ## Usage
//!   wp4-e2e [path-to-ghoztty-agent]
//! Spawns the agent on `127.0.0.1:<ephemeral>`, dials it (`tcp_dial.dial`), drives
//! `Connection.openChannel`, asserts the round-trip, then tears down. Exits 0 on
//! PASS, non-zero on FAIL. If no agent path is given it defaults to
//! `zig-out/bin/ghoztty-agent`.
//!
//! This is a `zig build wp4-e2e`-able native harness in the same dependency-light
//! client graph as `remote-test-client` (protocol/connection/tcp_dial only).
//!
//! ## Phase 2 — WP-D2 restore proof (window restore on relaunch)
//! After the open proof, the harness proves the exact protocol flow the Mac
//! client's relaunch-restore relies on (remote-relay-roadmap §2.4 / WP-D2),
//! against the real agent:
//!   1. dial #1, OPEN a shell (the window the user had open), remember its
//!      session UUID (the manifest write),
//!   2. drop the whole connection WITHOUT CLOSE (app quit ⇒ transport EOF ⇒
//!      the agent DETACHES the session and keeps it alive — SessionStore,
//!      detach ≠ terminate, spec §7.1),
//!   3. dial #2 (the relaunch), `GET_CWD`-probe the remembered UUID (the
//!      restore liveness probe) and assert a bogus UUID fails cleanly
//!      (`CwdUnavailable`, the drop-the-manifest-entry tier),
//!   4. `ATTACH` by UUID (same args as `termio/Remote.zig`) → status=alive →
//!      live DATA round-trip through the re-attached pane.
//!
//! ## Phase 3 — WP-D1 connection-status proof (reconnect state machine)
//! Proves the client-side §5.1 FSM + the primitives the GUI's reconnect loop
//! (BaseTerminalController, WP-D1) drives, against a real agent DEATH:
//!   1. dial, OPEN a session, register a state observer (the same seam
//!      `ghostty_remote_connection_set_state_callback` exposes to Swift),
//!   2. KILL the agent under the live connection → the reader EOF must drive
//!      CONNECTED → RECONNECTING (§5.2) — the GUI's yellow-pill trigger,
//!   3. start a fresh agent (the "agent is back" retry window) → the retry
//!      loop's dial+handshake step succeeds,
//!   4. probe the old session UUID on the new agent → fails cleanly
//!      (a restarted agent lost its in-memory sessions) — the GUI's terminal
//!      `disconnected` tier. (The happy re-ATTACH path is Phase 2: sessions
//!      survive a CONNECTION drop while the agent lives.)
//!
//! ## Phase 4 — WP-D1 frozen-agent freeze/thaw proof (the wedged-window bug)
//! Reproduces the live GUI repro headlessly: an agent that is UNREACHABLE but
//! whose TCP listener still ACCEPTS (SIGSTOP — the kernel completes the 3WHS
//! from the backlog and buffers the client HELLO; the frozen process never
//! answers). Two bugs are covered:
//!   1. a reconnect-attempt dial against the frozen agent must FAIL within the
//!      handshake deadline (pre-fix: `tcp_dial.dial` parked forever inside
//!      `waitHandshake`, so the GUI's attempt counter froze at "(1)" and
//!      backoff never advanced),
//!   2. after SIGCONT, the GUI's reconnect-swap ordering must not wedge the
//!      session: new connection ATTACHes (rebinds the bridge), THEN the old
//!      surface's teardown DETACH lands on the OLD connection. Pre-fix the
//!      agent's `handleDetach` stopped `streaming` UNCONDITIONALLY — even when
//!      the bridge already belonged to the NEW connection — so the freshly
//!      swapped window got no output ever again (blank/wedged window, while
//!      the pill claimed healthy).
//! Also asserts the short-outage invariants that must keep working: the OLD
//! connection self-heals to CONNECTED after the thaw (its transport never
//! died), and the post-thaw ATTACH replays the pre-freeze content (grid not
//! blank).

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const tcp_dial = @import("tcp_dial.zig");

const marker = "wp4-foundation";
const restore_marker = "wp4-d2-restore";
const freeze_marker = "wp4-freeze-pre";
const thaw_marker = "wp4-thaw-live";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const agent_path = try resolveAgentPath(alloc);
    defer alloc.free(agent_path);

    // Opt-in long-freeze soak (GHOZTTY_E2E_LONG_FREEZE=1): replays the exact
    // live-GUI outage timeline (175s SIGSTOP with the Swift retry schedule
    // running against the frozen listener) instead of the normal phases.
    // ~3.5 minutes; not part of the default run. This is the harness that
    // exonerated the Zig connection layer during the 2026-07-03 wedged-window
    // investigation (old link healed 58ms after SIGCONT).
    if (std.process.hasEnvVar(alloc, "GHOZTTY_E2E_LONG_FREEZE") catch false) {
        const ok = try runLongFreezeExperiment(alloc, agent_path);
        std.process.exit(if (ok) 0 else 1);
    }

    // Fast-iteration gate: run ONLY the dead-tombstone reap proof (Phase 5).
    if (std.process.hasEnvVar(alloc, "GHOZTTY_E2E_ONLY_REAP") catch false) {
        const ok = runReapProof(alloc, agent_path) catch |err| {
            diag("[wp4-e2e] FAIL (reap): {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.process.exit(if (ok) 0 else 1);
    }

    // Pick an ephemeral port the agent will bind. We bind+close to learn a free
    // port, then hand it to the agent (a tiny race window, acceptable for a test).
    const port = try freePort();
    var addr_buf: [32]u8 = undefined;
    const listen_arg = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});

    diag("[wp4-e2e] spawning agent: {s} --listen {s}\n", .{ agent_path, listen_arg });
    var child = std.process.Child.init(
        &.{ agent_path, "--listen", listen_arg },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    // Pin raw encoding so the dialer (also raw) negotiates cleanly.
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try cloneEnv(alloc, &env);
    try env.put("GHOZTTY_AGENT_ENCODING", "raw");
    try putIsolatedLock(alloc, &env);
    child.env_map = &env;
    try child.spawn();

    // Make sure we always reap the agent (it's a daemon: it never exits on its own).
    var reaped = false;
    defer if (!reaped) {
        _ = child.kill() catch {};
    };

    // Wait for the agent's "listening on ..." readiness line on stdout.
    try waitForListening(alloc, &child);

    // ---- The actual proof: dial + openChannel + DATA round-trip ----
    const result = runProof(alloc, port) catch |err| {
        diag("[wp4-e2e] FAIL: {s}\n", .{@errorName(err)});
        _ = child.kill() catch {};
        reaped = true;
        std.process.exit(1);
    };

    if (!result) {
        diag("[wp4-e2e] FAIL: did not observe the echoed marker in the inbound ring\n", .{});
        _ = child.kill() catch {};
        reaped = true;
        std.process.exit(1);
    }

    // ---- Phase 2: WP-D2 restore proof (detach on disconnect → re-attach) ----
    const restore_ok = runRestoreProof(alloc, port) catch |err| {
        diag("[wp4-e2e] FAIL (restore): {s}\n", .{@errorName(err)});
        _ = child.kill() catch {};
        reaped = true;
        std.process.exit(1);
    };

    // ---- Phase 3: WP-D1 connection-status proof (kills the shared agent as
    // its trigger, so it runs last). ----
    const state_ok = runStateProof(alloc, agent_path, port, &child) catch |err| {
        diag("[wp4-e2e] FAIL (state): {s}\n", .{@errorName(err)});
        _ = child.kill() catch {};
        reaped = true;
        std.process.exit(1);
    };
    reaped = true; // the state proof killed (and reaped) the shared agent.

    // ---- Phase 4: WP-D1 freeze/thaw proof (frozen agent: SIGSTOP/SIGCONT) ----
    const freeze_ok = runFreezeThawProof(alloc, agent_path) catch |err| {
        diag("[wp4-e2e] FAIL (freeze/thaw): {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // ---- Phase 5: dead-tombstone reap proof (reap-dead-sessions) ----
    const reap_ok = runReapProof(alloc, agent_path) catch |err| {
        diag("[wp4-e2e] FAIL (reap): {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    if (restore_ok and state_ok and freeze_ok and reap_ok) {
        const stdout = std.fs.File.stdout();
        stdout.writeAll("PASS: Connection.openChannel round-tripped '" ++ marker ++ "' over TCP against the real channel-authoritative agent\n") catch {};
        stdout.writeAll("PASS: WP-D2 restore — session survived the dropped connection; GET_CWD probe + ATTACH-by-UUID round-tripped '" ++ restore_marker ++ "' on re-dial\n") catch {};
        stdout.writeAll("PASS: WP-D1 status — agent death drove CONNECTED->RECONNECTING; retry-dial to a fresh agent handshook; a gone session probe failed cleanly (disconnected tier)\n") catch {};
        stdout.writeAll("PASS: WP-D1 freeze/thaw — frozen-agent dial failed within the handshake deadline; old link self-healed on thaw; re-ATTACH replayed pre-freeze content; stale DETACH did not wedge the re-attached session\n") catch {};
        stdout.writeAll("PASS: reap-dead-sessions — a pinned session whose child exited was reaped on unbind (gone from LIST_SESSIONS + sessions file), stayed gone across an agent restart, while the alive pinned survivor came back as a resumable relaunchable tombstone\n") catch {};
        std.process.exit(0);
    } else {
        diag("[wp4-e2e] FAIL: see diagnostics above\n", .{});
        std.process.exit(1);
    }
}

/// Opt-in long-freeze soak: mirror the live GUI repro exactly — 175s SIGSTOP
/// with the Swift retry schedule (5 dial attempts, delays 1/2/4/8/15s, each
/// bounded at 10s) run DURING the freeze, then SIGCONT, then check that the
/// ORIGINAL connection self-heals at the Zig level and its pane still
/// round-trips I/O. Also regression cover for the agent-side thaw crash: the
/// 5 stale backlog sockets are accepted at SIGCONT, which used to panic the
/// agent (setsockopt EINVAL → std `unreachable`) — the post-thaw dial+attach
/// here fails loudly if the agent died.
fn runLongFreezeExperiment(alloc: Allocator, agent_path: []const u8) !bool {
    const port = try freePort();
    var addr_buf: [32]u8 = undefined;
    const listen_arg = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});
    var child = try spawnAgent(alloc, agent_path, listen_arg);
    defer {
        _ = std.posix.kill(child.id, std.posix.SIG.CONT) catch {};
        _ = child.kill() catch {};
    }
    try waitForListening(alloc, &child);

    var dialed_a = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed_a.deinit();
    const pane_a = try dialed_a.conn.openChannel(.{
        .rows = 24,
        .cols = 80,
        .term = "xterm-ghostty",
    });
    defer dialed_a.conn.detachChannel(pane_a);
    try dialed_a.conn.writeInput(pane_a, "echo " ++ freeze_marker ++ "\r");
    if (!try drainForMarker(alloc, dialed_a.conn, pane_a, freeze_marker)) return false;

    const t0 = std.time.milliTimestamp();
    diag("[exp] t=0 SIGSTOP\n", .{});
    try std.posix.kill(child.id, std.posix.SIG.STOP);

    // Wait for reconnecting.
    while (dialed_a.conn.state() != .reconnecting) std.Thread.sleep(50 * std.time.ns_per_ms);
    diag("[exp] t={d}ms conn A reconnecting\n", .{std.time.milliTimestamp() - t0});

    // The Swift schedule: delays between attempts 1/2/4/8/15s, each dial 10s.
    const delays = [_]u64{ 1, 2, 4, 8, 15 };
    for (delays, 1..) |d, i| {
        std.Thread.sleep(d * std.time.ns_per_s);
        const s = std.time.milliTimestamp();
        if (tcp_dial.dial(alloc, "127.0.0.1", port, .raw)) |dd| {
            var dd2 = dd;
            diag("[exp] attempt {d}: dial unexpectedly SUCCEEDED\n", .{i});
            dd2.deinit();
        } else |err| {
            diag("[exp] t={d}ms attempt {d}: dial failed ({s}) after {d}ms\n", .{
                std.time.milliTimestamp() - t0, i, @errorName(err), std.time.milliTimestamp() - s,
            });
        }
    }

    // Keep frozen until t=175s.
    while (std.time.milliTimestamp() - t0 < 175_000) std.Thread.sleep(500 * std.time.ns_per_ms);
    diag("[exp] t={d}ms SIGCONT (conn A state={s})\n", .{
        std.time.milliTimestamp() - t0, @tagName(dialed_a.conn.state()),
    });
    try std.posix.kill(child.id, std.posix.SIG.CONT);

    // Does A self-heal?
    {
        const deadline = std.time.milliTimestamp() + 20_000;
        while (std.time.milliTimestamp() < deadline) {
            if (dialed_a.conn.state() == .connected) break;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        diag("[exp] t={d}ms conn A state={s}\n", .{
            std.time.milliTimestamp() - t0, @tagName(dialed_a.conn.state()),
        });
        if (dialed_a.conn.state() != .connected) return false;
    }

    // Does the ORIGINAL pane still round-trip?
    try dialed_a.conn.writeInput(pane_a, "echo " ++ thaw_marker ++ "\r");
    const live = try drainForMarker(alloc, dialed_a.conn, pane_a, thaw_marker);
    diag("[exp] original-pane round-trip after thaw: {}\n", .{live});
    return live;
}

/// Phase 4: the frozen-agent (SIGSTOP) freeze/thaw proof. See the module doc.
///
/// The GUI event sequence this replays headlessly (BaseTerminalController's
/// WP-D1 reconnect loop, live-reproduced on 2026-07-03 with a loopback agent):
///   conn A = the window's original connection; agent SIGSTOPped;
///   A → reconnecting (3 missed heartbeats); the retry loop dials a
///   REPLACEMENT connection — the frozen listener still tcp-accepts, so the
///   dial must be bounded by a handshake deadline (bug 1); on SIGCONT the old
///   link self-heals AND/OR the swap completes: new conn B ATTACHes (agent
///   rebinds the session bridge to B), then the old surface teardown's DETACH
///   arrives over A and must NOT strip the session's streaming flag from
///   under B (bug 2).
fn runFreezeThawProof(alloc: Allocator, agent_path: []const u8) !bool {
    // Dedicated agent (the shared one died in Phase 3).
    const port = try freePort();
    var addr_buf: [32]u8 = undefined;
    const listen_arg = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});
    var child = try spawnAgent(alloc, agent_path, listen_arg);
    var reaped = false;
    defer if (!reaped) {
        // Make sure it isn't left SIGSTOPped (kill of a stopped process works,
        // but resume first so the reap is prompt and deterministic).
        _ = std.posix.kill(child.id, std.posix.SIG.CONT) catch {};
        _ = child.kill() catch {};
    };
    try waitForListening(alloc, &child);

    // conn A: the "window's" connection. OPEN + produce pre-freeze content.
    var dialed_a = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed_a.deinit();
    const pane_a = try dialed_a.conn.openChannel(.{
        .rows = 24,
        .cols = 80,
        .term = "xterm-ghostty",
    });
    var pane_a_detached = false;
    defer if (!pane_a_detached) dialed_a.conn.detachChannel(pane_a);
    const session_id = try alloc.dupe(u8, pane_a.session_id);
    defer alloc.free(session_id);

    try dialed_a.conn.writeInput(pane_a, "echo " ++ freeze_marker ++ "\r");
    if (!try drainForMarker(alloc, dialed_a.conn, pane_a, freeze_marker)) {
        diag("[wp4-e2e] freeze FAIL: no pre-freeze echo\n", .{});
        return false;
    }

    // FREEZE the agent. Its TCP listener keeps accepting at the kernel level
    // (backlog), but the process answers nothing.
    diag("[wp4-e2e] freeze: SIGSTOP agent pid={d}\n", .{child.id});
    try std.posix.kill(child.id, std.posix.SIG.STOP);

    // A must degrade to RECONNECTING via missed heartbeats (3 × 3000ms + slack).
    {
        const deadline = std.time.milliTimestamp() + 20_000;
        while (std.time.milliTimestamp() < deadline) {
            if (dialed_a.conn.state() == .reconnecting) break;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (dialed_a.conn.state() != .reconnecting) {
            diag("[wp4-e2e] freeze FAIL: conn A never hit reconnecting (state={s})\n", .{
                @tagName(dialed_a.conn.state()),
            });
            return false;
        }
    }
    diag("[wp4-e2e] freeze: conn A is reconnecting; dialing the frozen agent (the retry-loop attempt)\n", .{});

    // Bug 1: the reconnect attempt's dial. The frozen listener tcp-accepts, so
    // pre-fix `tcp_dial.dial` parked forever in `waitHandshake` (the GUI's
    // attempt counter froze at "(1)"). With the handshake deadline it must
    // come back with an error well before our 20s observation window ends.
    const DialAttempt = struct {
        alloc: Allocator,
        port: u16,
        done: std.atomic.Value(bool) = .{ .raw = false },
        dialed: ?tcp_dial.Dialed = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            if (tcp_dial.dial(self.alloc, "127.0.0.1", self.port, .raw)) |d| {
                self.dialed = d;
            } else |e| {
                self.err = e;
            }
            self.done.store(true, .release);
        }
    };
    var attempt: DialAttempt = .{ .alloc = alloc, .port = port };
    const dial_started_ms = std.time.milliTimestamp();
    const attempt_thread = try std.Thread.spawn(.{}, DialAttempt.run, .{&attempt});
    var attempt_joined = false;
    // NOTE: pre-fix the thread never exits while the agent is frozen; we join
    // it after SIGCONT below (the thaw unblocks the handshake) so the stack
    // slot stays valid either way.

    var dial_bounded = false;
    {
        const deadline = std.time.milliTimestamp() + 20_000;
        while (std.time.milliTimestamp() < deadline) {
            if (attempt.done.load(.acquire)) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        const elapsed = std.time.milliTimestamp() - dial_started_ms;
        if (!attempt.done.load(.acquire)) {
            diag("[wp4-e2e] freeze FAIL (bug 1): dial against the frozen agent still HUNG after {d}ms — no handshake deadline, the GUI attempt counter freezes at (1)\n", .{elapsed});
        } else if (attempt.dialed != null) {
            diag("[wp4-e2e] freeze FAIL (bug 1): dial unexpectedly SUCCEEDED against a frozen agent\n", .{});
            attempt.dialed.?.deinit();
            attempt.dialed = null;
        } else {
            diag("[wp4-e2e] freeze: dial failed as it must ({s}) after {d}ms\n", .{
                @errorName(attempt.err.?), elapsed,
            });
            dial_bounded = true;
        }
        if (attempt.done.load(.acquire)) {
            attempt_thread.join();
            attempt_joined = true;
        }
    }

    // THAW.
    diag("[wp4-e2e] thaw: SIGCONT agent\n", .{});
    try std.posix.kill(child.id, std.posix.SIG.CONT);

    // Reap the (pre-fix) hung dial attempt now that the thaw unblocked it.
    if (!attempt_joined) {
        attempt_thread.join();
        if (attempt.dialed) |*d| d.deinit();
    }

    // Short-outage invariant: the OLD connection's transport never died
    // (SIGSTOP keeps the socket healthy), so A must self-heal to CONNECTED.
    {
        const deadline = std.time.milliTimestamp() + 15_000;
        while (std.time.milliTimestamp() < deadline) {
            if (dialed_a.conn.state() == .connected) break;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (dialed_a.conn.state() != .connected) {
            diag("[wp4-e2e] thaw FAIL: conn A did not self-heal to connected (state={s})\n", .{
                @tagName(dialed_a.conn.state()),
            });
            return false;
        }
    }
    diag("[wp4-e2e] thaw: conn A self-healed to connected\n", .{});

    // The GUI swap: dial the replacement (post-thaw it must handshake), probe,
    // and re-ATTACH — the exact completeRemoteReconnect → threadEnter flow.
    var dialed_b = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed_b.deinit();
    const cwd = try dialed_b.conn.queryCwdTimeout(session_id, 5 * std.time.ns_per_s);
    alloc.free(cwd);

    var outcome = try dialed_b.conn.attachChannel(session_id, 24, 80, 0, false);
    defer outcome.deinit();
    const pane_b = outcome.pane orelse {
        diag("[wp4-e2e] thaw FAIL: re-ATTACH yielded no pane (status={s} attached_elsewhere={})\n", .{
            @tagName(outcome.status), outcome.attached_elsewhere,
        });
        return false;
    };
    defer dialed_b.conn.closeChannel(pane_b);

    // Grid-not-blank proof: the attach gap-fill must replay the pre-freeze
    // content (offset 0 → full retained ring).
    if (!try drainForMarker(alloc, dialed_b.conn, pane_b, freeze_marker)) {
        diag("[wp4-e2e] thaw FAIL: re-ATTACH replay did not contain the pre-freeze content\n", .{});
        return false;
    }
    diag("[wp4-e2e] thaw: re-ATTACH replayed the pre-freeze content\n", .{});

    // Bug 2: the old surface's teardown DETACH lands over conn A AFTER the new
    // ATTACH rebound the session to conn B (the common completeRemoteReconnect
    // ordering: the new SurfaceView ATTACHes as it spins up, then the old tree
    // is released). The agent must treat it as a stale no-op — pre-fix it
    // stopped `streaming` unconditionally and the swapped window went silent.
    dialed_a.conn.detachChannel(pane_a);
    pane_a_detached = true;
    std.Thread.sleep(500 * std.time.ns_per_ms); // let the DETACH land

    try dialed_b.conn.writeInput(pane_b, "echo " ++ thaw_marker ++ "\r");
    const live = try drainForMarker(alloc, dialed_b.conn, pane_b, thaw_marker);
    if (!live) {
        diag("[wp4-e2e] thaw FAIL (bug 2): stale DETACH from the OLD connection wedged the re-attached session (no output after the swap)\n", .{});
    } else {
        diag("[wp4-e2e] thaw: re-attached session still live after the stale DETACH\n", .{});
    }

    _ = std.posix.kill(child.id, std.posix.SIG.CONT) catch {};
    _ = child.kill() catch {};
    reaped = true;
    return dial_bounded and live;
}

/// Dial the agent, OPEN a shell via the high-level `Connection.openChannel`, send
/// `echo wp4-foundation\r`, and drain the pane's inbound ring looking for the
/// echoed marker. Returns true on success.
fn runProof(alloc: Allocator, port: u16) !bool {
    diag("[wp4-e2e] dialing 127.0.0.1:{d}\n", .{port});
    var dialed = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed.deinit();
    diag("[wp4-e2e] handshake ok: proto_version={d} encoding={s}\n", .{
        dialed.negotiated.proto_version,
        @tagName(dialed.negotiated.transfer_encoding),
    });

    // THE FIXED PATH: the same call termio/Remote.zig makes. Against the real
    // agent this only returns if openChannel adopts the agent-authoritative
    // channel from OPENED; before the fix this blocks → OpenTimeout (rpcCall is
    // unblocked by shutdown, but the agent never replies on our channel).
    const open: protocol.Open = .{
        .rows = 24,
        .cols = 80,
        // A plain shell; `echo` is portable on the macOS/POSIX agent host.
        .term = "xterm-ghostty",
    };
    const pane = try dialed.conn.openChannel(open);
    diag("[wp4-e2e] openChannel OK: session_id={s} pid={d} channel=0x{x}\n", .{
        pane.session_id, pane.pid, pane.id,
    });
    defer dialed.conn.closeChannel(pane);

    // Send the command as input DATA (CR is the portable Enter, matching
    // test_client.zig). The pane owns its outbound offset (writeInput).
    try dialed.conn.writeInput(pane, "echo " ++ marker ++ "\r");
    diag("[wp4-e2e] sent 'echo {s}\\r'; draining inbound ring for the echo...\n", .{marker});

    // Drain the pane's ring on the agent-authoritative channel until we see the
    // marker echoed back (the shell prints it), or we time out.
    return drainForMarker(alloc, dialed.conn, pane, marker);
}

/// WP-D2 restore proof: OPEN on connection #1, drop the connection with NO
/// CLOSE (the app quit), re-dial, GET_CWD-probe by session UUID (plus a bogus
/// UUID that must fail cleanly), then ATTACH by UUID — with the same arguments
/// `termio/Remote.zig` uses — and prove the re-attached pane is live.
fn runRestoreProof(alloc: Allocator, port: u16) !bool {
    // 1. First life: open a session and remember its UUID (the manifest write).
    const session_id: []u8 = blk: {
        var dialed = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
        // NOTE: no closeChannel — quitting the app only drops the transport;
        // the agent must DETACH (keep alive), never terminate (§7.1).
        defer dialed.deinit();
        const pane = try dialed.conn.openChannel(.{
            .rows = 24,
            .cols = 80,
            .term = "xterm-ghostty",
        });
        diag("[wp4-e2e] restore: opened session_id={s}; dropping connection WITHOUT close\n", .{pane.session_id});
        break :blk try alloc.dupe(u8, pane.session_id);
    };
    defer alloc.free(session_id);

    // 2. Second life: re-dial (the relaunch).
    var dialed = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed.deinit();

    // 3a. The restore liveness probe (AppDelegate.restoreRemoteWindows): a
    // still-alive session answers GET_CWD with ok=true.
    const cwd = try dialed.conn.queryCwdTimeout(session_id, 5 * std.time.ns_per_s);
    diag("[wp4-e2e] restore: probe OK, session alive (cwd={s})\n", .{cwd});
    alloc.free(cwd);

    // 3b. A gone/unknown session must fail cleanly (the drop-the-manifest-entry
    // tier) — no hang, no crash.
    if (dialed.conn.queryCwdTimeout(
        "00000000-dead-beef-0000-000000000000",
        5 * std.time.ns_per_s,
    )) |p| {
        alloc.free(p);
        diag("[wp4-e2e] restore FAIL: bogus session probe unexpectedly returned a cwd\n", .{});
        return false;
    } else |err| switch (err) {
        error.CwdUnavailable => {},
        else => return err,
    }

    // 4. Re-ATTACH by UUID (same args as termio/Remote.zig: offset 0, no force).
    var outcome = try dialed.conn.attachChannel(session_id, 24, 80, 0, false);
    defer outcome.deinit();
    if (outcome.status != .alive or outcome.pane == null) {
        diag("[wp4-e2e] restore FAIL: attach status={s} attached_elsewhere={}\n", .{
            @tagName(outcome.status), outcome.attached_elsewhere,
        });
        return false;
    }
    const pane = outcome.pane.?;
    defer dialed.conn.closeChannel(pane);
    diag("[wp4-e2e] restore: ATTACH alive on channel=0x{x}; sending 'echo {s}\\r'\n", .{
        pane.id, restore_marker,
    });

    try dialed.conn.writeInput(pane, "echo " ++ restore_marker ++ "\r");
    return drainForMarker(alloc, dialed.conn, pane, restore_marker);
}

/// WP-D1 connection-status proof. Kills the SHARED agent (`child`) as its
/// disconnect trigger — must run last. On return (ok or error before the kill,
/// which the caller handles) the shared agent is dead and reaped.
fn runStateProof(
    alloc: Allocator,
    agent_path: []const u8,
    port: u16,
    child: *std.process.Child,
) !bool {
    // The observer the GUI registers via
    // `ghostty_remote_connection_set_state_callback` (same `setStateHandler`
    // seam). It must not call back into the connection (fired under the state
    // lock), so it only records atomically — exactly like the Swift trampoline.
    const Recorder = struct {
        saw_reconnecting: std.atomic.Value(bool) = .{ .raw = false },
        fn handler(
            ctx: *anyopaque,
            _: *connection.Connection,
            _: connection.LinkState.State,
            new: connection.LinkState.State,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (new == .reconnecting) self.saw_reconnecting.store(true, .monotonic);
        }
    };
    var rec: Recorder = .{};

    // 1. The "live window": dial + OPEN with the observer registered.
    var dialed = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed.deinit();
    dialed.conn.setStateHandler(&rec, Recorder.handler);

    const pane = try dialed.conn.openChannel(.{
        .rows = 24,
        .cols = 80,
        .term = "xterm-ghostty",
    });
    defer dialed.conn.closeChannel(pane);
    const session_id = try alloc.dupe(u8, pane.session_id);
    defer alloc.free(session_id);
    if (dialed.conn.state() != .connected) {
        diag("[wp4-e2e] state FAIL: expected connected after open, got {s}\n", .{
            @tagName(dialed.conn.state()),
        });
        return false;
    }
    diag("[wp4-e2e] state: session {s} open, state=connected; killing the agent\n", .{session_id});

    // 2. Kill the agent under the live connection (the WP-D1 acceptance
    // trigger: "kill the agent under a live window").
    _ = child.kill() catch {};

    // 3. Reader EOF must drive CONNECTED → RECONNECTING (§5.2) promptly — this
    // is what turns the GUI pill yellow and starts its retry loop.
    {
        const deadline = std.time.milliTimestamp() + 5000;
        while (std.time.milliTimestamp() < deadline) {
            if (rec.saw_reconnecting.load(.monotonic) and
                dialed.conn.state() == .reconnecting) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (!rec.saw_reconnecting.load(.monotonic) or dialed.conn.state() != .reconnecting) {
            diag("[wp4-e2e] state FAIL: no reconnecting transition after agent death (state={s})\n", .{
                @tagName(dialed.conn.state()),
            });
            return false;
        }
    }
    diag("[wp4-e2e] state: observed CONNECTED->RECONNECTING after agent death\n", .{});

    // 4. "The agent comes back within the retry window": start a fresh agent
    // and prove the retry loop's dial+handshake step succeeds against it.
    const port2 = try freePort();
    var addr_buf: [32]u8 = undefined;
    const listen_arg = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port2});
    var child2 = try spawnAgent(alloc, agent_path, listen_arg);
    var reaped2 = false;
    defer if (!reaped2) {
        _ = child2.kill() catch {};
    };
    try waitForListening(alloc, &child2);

    var dialed2 = try tcp_dial.dial(alloc, "127.0.0.1", port2, .raw);
    defer dialed2.deinit();
    diag("[wp4-e2e] state: retry-dial to the fresh agent handshook OK\n", .{});

    // 5. A RESTARTED agent lost its in-memory sessions: the liveness probe for
    // the old UUID must fail cleanly — the GUI's terminal `disconnected` tier
    // (keep the window, stop retrying). No hang, no crash.
    if (dialed2.conn.queryCwdTimeout(session_id, 5 * std.time.ns_per_s)) |p| {
        alloc.free(p);
        diag("[wp4-e2e] state FAIL: restarted agent unexpectedly knew the old session\n", .{});
        return false;
    } else |err| switch (err) {
        error.CwdUnavailable => {},
        else => return err,
    }
    diag("[wp4-e2e] state: gone-session probe failed cleanly (disconnected tier)\n", .{});

    _ = child2.kill() catch {};
    reaped2 = true;
    return true;
}

// -----------------------------------------------------------------------------
// Phase 5: dead-tombstone reap proof (reap-dead-sessions)
// -----------------------------------------------------------------------------

/// What a `LIST_SESSIONS` roster should say about a given session id.
const SessionWant = enum { present_alive, present_dead, gone };

/// Poll `LIST_SESSIONS` until the row for `id` matches `want` (or `timeout_ms`).
fn waitForSession(
    alloc: Allocator,
    conn: *connection.Connection,
    id: []const u8,
    want: SessionWant,
    timeout_ms: i64,
) !bool {
    _ = alloc;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var last_count: usize = 0;
    var last_present = false;
    var last_alive = false;
    while (std.time.milliTimestamp() < deadline) {
        var roster = try conn.requestSessions(5 * std.time.ns_per_s);
        defer roster.deinit();
        var found: ?connection.OwnedSession = null;
        for (roster.sessions) |s| {
            if (std.mem.eql(u8, s.id, id)) {
                found = s;
                break;
            }
        }
        last_count = roster.sessions.len;
        last_present = found != null;
        last_alive = if (found) |f| f.alive else false;
        const ok = switch (want) {
            .gone => found == null,
            .present_alive => found != null and found.?.alive,
            .present_dead => found != null and !found.?.alive,
        };
        if (ok) return true;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    diag("[reap-e2e] waitForSession timeout: want={s} last(roster_len={d} present={} alive={})\n", .{ @tagName(want), last_count, last_present, last_alive });
    return false;
}

/// True iff the file at `path` contains `needle` (the reboot-floor sessions file
/// stores each session's hex id verbatim, so a substring match answers "is this
/// session persisted?"). A missing file counts as "does not contain".
fn fileContainsId(alloc: Allocator, path: []const u8, needle: []const u8) !bool {
    const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer alloc.free(data);
    return std.mem.indexOf(u8, data, needle) != null;
}

/// End-to-end proof for the tombstone-leak fix. A PINNED persistent session whose
/// child EXITED must be reaped the instant its viewer DETACHES (unbind): gone from
/// `LIST_SESSIONS`, excluded from the on-disk sessions file, and NOT
/// re-materialized after an agent restart. Meanwhile an ALIVE pinned session must
/// survive the restart as a resumable (relaunchable) reboot-floor tombstone.
///
/// Runs its OWN agent with a real `--sessions-file` (the shared phases don't
/// persist) so the reboot-floor set on disk and across a restart is assertable.
/// Isolated lock + a temp sessions file: never touches the user's real agents.
fn runReapProof(alloc: Allocator, agent_path: []const u8) !bool {
    const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
    const sessions_file = try std.fmt.allocPrint(
        alloc,
        "{s}/reap-e2e-sessions-{d}-{d}.json",
        .{ std.mem.trimRight(u8, tmp, "/"), std.c.getpid(), std.time.nanoTimestamp() },
    );
    defer alloc.free(sessions_file);
    std.fs.cwd().deleteFile(sessions_file) catch {};
    defer std.fs.cwd().deleteFile(sessions_file) catch {};

    const port = try freePort();
    var addr_buf: [32]u8 = undefined;
    const listen_arg = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{port});
    var child = try spawnAgentPersist(alloc, agent_path, listen_arg, sessions_file);
    var reaped = false;
    defer if (!reaped) {
        _ = child.kill() catch {};
    };
    try waitForListening(alloc, &child);

    // 1. Two PINNED sessions (persistent local panes): `victim` (child will exit)
    //    and `survivor` (stays alive across the restart).
    var dialed = try tcp_dial.dial(alloc, "127.0.0.1", port, .raw);
    defer dialed.deinit();
    const victim = try dialed.conn.openChannel(.{
        .rows = 24,
        .cols = 80,
        // `TERM=dumb`: a heavy interactive profile (p10k) skips instant-prompt and
        // cursor-position queries under a dumb terminal, so the shell doesn't hang
        // waiting on responses the headless harness never sends. It prints a
        // minimal prompt then runs `exit 0` and exits — the output flows to the
        // agent's sink whose reap-check `tryWait` catches the already-exited child
        // → a DETERMINISTIC tombstone (the persistent-pane "child died" case).
        .term = "dumb",
        .pinned = true,
        .command = "exit 0",
    });
    const victim_id = try alloc.dupe(u8, victim.session_id);
    defer alloc.free(victim_id);
    const survivor = try dialed.conn.openChannel(.{
        .rows = 24,
        .cols = 80,
        .term = "xterm-ghostty",
        .pinned = true,
    });
    const survivor_id = try alloc.dupe(u8, survivor.session_id);
    defer alloc.free(survivor_id);
    diag("[reap-e2e] opened pinned victim={s} (pid={d}) survivor={s}\n", .{ victim_id, victim.pid, survivor_id });

    // 2. The victim's process exits on its own → the agent tombstones it while
    //    STILL BOUND (viewer attached) — the `[process exited]` UX, which must
    //    NOT be reaped yet (bound-tombstone path is preserved).
    if (!try waitForSession(alloc, dialed.conn, victim_id, .present_dead, 10_000)) {
        diag("[reap-e2e] FAIL: victim never became a dead-but-present tombstone\n", .{});
        return false;
    }
    diag("[reap-e2e] victim is a dead+bound tombstone (still listed) — good\n", .{});

    // 3. DETACH the victim (viewer closes / window gone) → unbind → immediate reap.
    dialed.conn.detachChannel(victim);
    if (!try waitForSession(alloc, dialed.conn, victim_id, .gone, 8_000)) {
        diag("[reap-e2e] FAIL: dead+unbound victim was NOT reaped from LIST_SESSIONS\n", .{});
        return false;
    }
    // The alive survivor must remain listed (pinned+alive is never reaped).
    if (!try waitForSession(alloc, dialed.conn, survivor_id, .present_alive, 8_000)) {
        diag("[reap-e2e] FAIL: alive survivor unexpectedly missing after the reap\n", .{});
        return false;
    }
    diag("[reap-e2e] victim reaped on unbind; survivor still listed — good\n", .{});

    // 4. The reap rewrote the reboot-floor file: victim excluded, survivor kept.
    if (try fileContainsId(alloc, sessions_file, victim_id)) {
        diag("[reap-e2e] FAIL: reaped victim still in sessions file (would re-materialize)\n", .{});
        return false;
    }
    if (!try fileContainsId(alloc, sessions_file, survivor_id)) {
        diag("[reap-e2e] FAIL: alive survivor missing from sessions file (won't restore)\n", .{});
        return false;
    }
    diag("[reap-e2e] sessions file excludes the victim, keeps the survivor — good\n", .{});

    // 5. Restart the agent against the SAME sessions file (reboot-floor reload).
    _ = child.kill() catch {};
    reaped = true;
    _ = child.wait() catch {};

    const port2 = try freePort();
    var addr_buf2: [32]u8 = undefined;
    const listen_arg2 = try std.fmt.bufPrint(&addr_buf2, "127.0.0.1:{d}", .{port2});
    var child2 = try spawnAgentPersist(alloc, agent_path, listen_arg2, sessions_file);
    var reaped2 = false;
    defer if (!reaped2) {
        _ = child2.kill() catch {};
    };
    try waitForListening(alloc, &child2);

    var dialed2 = try tcp_dial.dial(alloc, "127.0.0.1", port2, .raw);
    defer dialed2.deinit();

    // 5a. The reaped victim must NOT reappear — ATTACH by its id is `.not_found`
    //     (positively absent from the reloaded table).
    var v_out = try dialed2.conn.attachChannel(victim_id, 24, 80, 0, false);
    defer v_out.deinit();
    if (v_out.status != .not_found) {
        diag("[reap-e2e] FAIL: reaped victim came back after restart (attach status={s})\n", .{@tagName(v_out.status)});
        return false;
    }

    // 5b. The survivor must reappear as a resumable reboot-floor tombstone —
    //     ATTACH is `.dead` with `relaunchable == true` (the legitimate Resume).
    var s_out = try dialed2.conn.attachChannel(survivor_id, 24, 80, 0, false);
    defer s_out.deinit();
    if (!(s_out.status == .dead and s_out.relaunchable)) {
        diag("[reap-e2e] FAIL: survivor not resumable after restart (status={s} relaunchable={})\n", .{ @tagName(s_out.status), s_out.relaunchable });
        return false;
    }
    diag("[reap-e2e] after restart: victim stays gone; survivor is a resumable relaunchable tombstone — good\n", .{});

    _ = child2.kill() catch {};
    reaped2 = true;
    return true;
}

/// Spawn an agent process on `listen_arg` with the raw encoding pinned (like
/// main's shared agent). The caller must `waitForListening` and kill/reap it.
fn spawnAgent(
    alloc: Allocator,
    agent_path: []const u8,
    listen_arg: []const u8,
) !std.process.Child {
    var child = std.process.Child.init(
        &.{ agent_path, "--listen", listen_arg },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try cloneEnv(alloc, &env);
    try env.put("GHOZTTY_AGENT_ENCODING", "raw");
    try putIsolatedLock(alloc, &env);
    child.env_map = &env;
    try child.spawn();
    // `spawn` consumed the env/argv; drop the dangling pointer for hygiene.
    child.env_map = null;
    return child;
}

/// Like `spawnAgent`, but with a `--sessions-file` so the agent persists its
/// reboot-floor metadata (§5.4, T12) — needed to prove reap exclusion on disk and
/// survival across an agent restart.
fn spawnAgentPersist(
    alloc: Allocator,
    agent_path: []const u8,
    listen_arg: []const u8,
    sessions_file: []const u8,
) !std.process.Child {
    var child = std.process.Child.init(
        &.{ agent_path, "--listen", listen_arg, "--sessions-file", sessions_file },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try cloneEnv(alloc, &env);
    try env.put("GHOZTTY_AGENT_ENCODING", "raw");
    try putIsolatedLock(alloc, &env);
    child.env_map = &env;
    try child.spawn();
    child.env_map = null;
    return child;
}

/// Point `GHOSTTY_AGENT_LOCK` at a unique temp path so harness agents never
/// collide with a user's real running agent (or each other) on the per-user
/// single-instance guard — a live `ghoztty-agent --listen` on the box would
/// otherwise make every spawn here exit 183 (`AgentNeverListened`).
fn putIsolatedLock(alloc: Allocator, env: *std.process.EnvMap) !void {
    const tmp = env.get("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(
        alloc,
        "{s}/wp4-e2e-agent-{d}-{d}.lock",
        .{ std.mem.trimRight(u8, tmp, "/"), std.c.getpid(), std.time.nanoTimestamp() },
    );
    defer alloc.free(path);
    try env.put("GHOSTTY_AGENT_LOCK", path);
}

/// Drain `pane`'s inbound ring until `needle` shows up as completed shell
/// OUTPUT (see `containsMarkerOutput`) or an 8s deadline passes.
fn drainForMarker(
    alloc: Allocator,
    conn: *connection.Connection,
    pane: *connection.Pane,
    needle: []const u8,
) !bool {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    var buf: [16 * 1024]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 8000;
    var total: usize = 0;
    while (std.time.milliTimestamp() < deadline) {
        const r = pane.ring.pop(&buf);
        if (r.read == 0) {
            if (conn.isEvicted()) break;
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        total += r.read;
        try acc.appendSlice(alloc, buf[0..r.read]);
        // The shell echoes the typed command AND prints the echo output; either
        // way the marker appears at least once in the stream. Require it to appear
        // beyond the bare command echo: count >= 2 occurrences OR a newline-led
        // occurrence (the command output line). Simplest robust check: the marker
        // appears and we've seen a CR/LF after it (output line completed).
        if (containsMarkerOutput(acc.items, needle)) {
            diag("[wp4-e2e] observed '{s}' in ring after {d} bytes\n", .{ needle, total });
            return true;
        }
    }
    diag("[wp4-e2e] drained {d} bytes total without a confirmed '{s}' output\n", .{ total, needle });
    return false;
}

/// True once `text` contains `needle` followed (somewhere later) by a line
/// terminator — i.e. the shell actually ran `echo` and printed the marker on its
/// own line, not just the keystroke echo of the command we typed.
fn containsMarkerOutput(text: []const u8, needle: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, needle)) |idx| {
        const after = idx + needle.len;
        if (std.mem.indexOfAnyPos(u8, text, after, "\r\n") != null) return true;
        search_from = after;
    }
    return false;
}

// -----------------------------------------------------------------------------
// Process / port helpers
// -----------------------------------------------------------------------------

/// Resolve the agent exe path: argv[1] if given, else `zig-out/bin/ghoztty-agent`.
fn resolveAgentPath(alloc: Allocator) ![]u8 {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len >= 2) return alloc.dupe(u8, args[1]);
    return alloc.dupe(u8, "zig-out/bin/ghoztty-agent");
}

/// Bind an ephemeral TCP port, read it back, and release it. Returns the port so
/// the agent can bind it (a brief TOCTOU window, fine for a localhost test).
fn freePort() !u16 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    return listener.listen_address.getPort();
}

/// Block until the agent prints its "listening on ..." readiness line (or its
/// stdout EOFs / we time out). The agent writes that line right after bind.
fn waitForListening(alloc: Allocator, child: *std.process.Child) !void {
    const out = child.stdout orelse return error.NoAgentStdout;
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    var buf: [1024]u8 = undefined;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        const n = out.read(&buf) catch 0;
        if (n == 0) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }
        try acc.appendSlice(alloc, buf[0..n]);
        if (std.mem.indexOf(u8, acc.items, "listening") != null) {
            diag("[wp4-e2e] agent ready: {s}", .{std.mem.trimRight(u8, acc.items, "\n")});
            diag("\n", .{});
            return;
        }
    }
    return error.AgentNeverListened;
}

/// Copy the current process environment into `env` so the spawned agent inherits
/// PATH etc. (it execs a shell).
fn cloneEnv(alloc: Allocator, env: *std.process.EnvMap) !void {
    var src = try std.process.getEnvMap(alloc);
    defer src.deinit();
    var it = src.iterator();
    while (it.next()) |entry| {
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn diag(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
