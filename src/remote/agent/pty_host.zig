//! The per-session ConPTY **holder** process (T904, increment 1 of the T705
//! non-destructive agent upgrade — design:
//! `docs/design/agent-nondestructive-handoff.md`).
//!
//! `ghoztty-agent.exe --pty-host --session-id <id>` runs ONE session's shell:
//! it creates the ConPTY, spawns the shell on it, owns its own kill-on-close
//! Job Object over the shell subtree (all via the production
//! `PtySpawner`/`PtyChild` path — the exact machinery the agent itself uses),
//! and serves one owner at a time over an owner-only-DACL named pipe speaking
//! the `pty_host_proto` protocol. The agent never touches the HPCON, so an
//! agent restart costs no shell: the holder keeps it alive and a reconnecting
//! owner gap-fills from the bounded replay buffer.
//!
//! ## Threads
//!
//!   - **main**: bind the pipe, accept loop; per connection, sends HELLO then
//!     reads/handles owner frames (ATTACH/INPUT/ACK/RESIZE/SIGNAL/SHUTDOWN)
//!     until the owner disconnects.
//!   - **pty reader** (inside `PtyChild`): pumps ConPTY output → our sink →
//!     the replay buffer (never blocks on the owner — the ring drops oldest).
//!   - **writer** (one per attached owner): drains the replay buffer to the
//!     pipe as offset-tagged OUTPUT frames; sends EXIT once the shell is gone
//!     and everything produced has been sent.
//!   - **exit poller**: reaps the shell (`tryWait`), stamps the exit; after
//!     the shell exits it enforces the no-owner linger so an abandoned holder
//!     does not outlive its usefulness.
//!
//! ## Lifecycle
//!
//! The holder exits when: the owner sends SHUTDOWN (shell terminated first);
//! or the shell exited AND its EXIT frame was delivered to an owner; or the
//! shell exited and no owner showed up within the linger window. Killing the
//! holder kills the shell subtree (its Job Object); an owner dying merely
//! breaks the pipe — the shell lives on for the next owner.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const proto = @import("pty_host_proto.zig");
const pty_child = @import("pty_child.zig");
const pipe_stream = @import("../pipe_stream.zig");
const relay_perf = @import("relay_perf.zig");
const server = @import("server.zig");
const session = @import("session.zig");

const is_windows = builtin.os.tag == .windows;
const log = std.log.scoped(.pty_host);

pub const Options = struct {
    /// Session id (pipe-name-safe: `proto.validSessionId`). Required.
    session_id: []const u8,
    /// Full `\\.\pipe\...` path to serve. Null ⇒ `defaultPipeName(session_id)`.
    pipe_name: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    cwd: ?[]const u8 = null,
    /// One-shot command (per-shell flag synthesis, `windowsCommandArg`); null ⇒
    /// interactive shell.
    command: ?[]const u8 = null,
    /// Shell override; null ⇒ %COMSPEC% → cmd.exe (the `resolveShellPath` chain).
    shell: ?[]const u8 = null,
    /// Replay ring capacity in bytes.
    replay_bytes: usize = 1024 * 1024,
    /// After the shell exits with NO owner attached, how long to keep serving
    /// (so an agent can still collect the exit code) before giving up.
    exit_linger_ms: i64 = 10 * 60 * 1000,
    /// Holder build stamp advertised in HELLO (the agent build version).
    stamp: []const u8,
    /// The full OPEN this session was created from (`--spec`, T905). When
    /// present it is spawned VERBATIM and the scalar fields above are ignored:
    /// the agent's holder must reproduce exactly what an in-process `PtyChild`
    /// would have — the same explicit `argv` shell-integration rewrite, the
    /// same forwarded `OPEN.env`, the same `TERM` — and the only way to be sure
    /// of that is to spawn from the same value. Null on the hand-driven flag
    /// path (`--session-id --cwd --command …`, which the smoke uses).
    open: ?protocol.Open = null,
};

/// Derive the default holder pipe name for `session_id`:
/// `\\.\pipe\ghoztty-pty-host[-debug]-<user>-<session-id>`. The `-debug`
/// segment keeps a dev holder off the endpoints a release agent derives —
/// the same build-mode isolation as every other endpoint on this box (T350).
pub fn defaultPipeName(alloc: Allocator, session_id: []const u8) ![]u8 {
    const user: []const u8 = std.process.getEnvVarOwned(alloc, "USERNAME") catch
        try alloc.dupe(u8, "unknown");
    defer alloc.free(user);
    const debug_seg = if (builtin.mode == .Debug) "-debug" else "";
    return std.fmt.allocPrint(
        alloc,
        "\\\\.\\pipe\\ghoztty-pty-host{s}-{s}-{s}",
        .{ debug_seg, user, session_id },
    );
}

pub const run = if (is_windows) win.run else stub.run;

const stub = struct {
    fn run(_: Allocator, _: Options) !void {
        return error.PtyHostUnsupported; // Windows-only mode (parse-time gated)
    }
};

const win = struct {
    const windows = std.os.windows;

    /// Shared holder state. One mutex/cond pair serializes the pty sink, the
    /// per-owner writer, the frame handler, and the exit poller.
    const State = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        replay: proto.ReplayBuffer,

        /// Shell exit, stamped once by the exit poller.
        exited: bool = false,
        exit_code: i64 = 0,
        exited_at_ms: i64 = 0,

        /// Owner-connection state (main thread writes, poller reads).
        owner_connected: bool = false,
        last_disconnect_ms: i64 = 0,

        /// The EXIT frame reached an owner's pipe; the holder may finish.
        exit_delivered: bool = false,

        /// The SOURCE end of the relay (T1464): how fast the shell's own output
        /// actually arrives out of this holder's ConPTY. Touched only by the
        /// pty reader thread (`sinkFn`), which is the one thread that ever
        /// delivers a chunk - the same one-owner contract every other `Meter`
        /// has. It is the number every leg downstream is bounded by, and
        /// without it a slow relay and a slow ConPTY read look identical.
        read_meter: relay_perf.Meter = .init("holder_read"),
    };

    // MEASURED AND REJECTED (T1464): a one-millisecond coalescing wait here,
    // taken when the ring held less than 4 KiB, so a burst left with ~1,000 real
    // frames a second instead of ~8,300 tiny ones. It worked exactly as
    // designed - `bytes_per_frame` went 73 -> 146 and `frames_per_s` 8,294 ->
    // 4,378 - and moved the throughput not at all (626 KB/s against 594). The
    // ceiling is the holder's ConPTY READ rate (`perf holder_read`, ~8,700 reads
    // a second against the local path's ~19,000 of the same 73 bytes); every leg
    // downstream merely follows it. So the message count was never the cost, and
    // a millisecond of added echo latency buys nothing. Do not re-add batching
    // here without a number showing the source can go faster.

    /// Per-connection writer handle: `closed` tells a cond-parked writer the
    /// connection is gone (the stream alone cannot wake it).
    const Conn = struct {
        stream: server.Stream,
        closed: bool = false,
    };

    fn run(alloc: Allocator, opts: Options) !void {
        if (!proto.validSessionId(opts.session_id)) {
            log.err("invalid --session-id '{s}' (pipe-name-safe charset required)", .{opts.session_id});
            return error.InvalidSessionId;
        }

        const pipe_name = if (opts.pipe_name) |n|
            try alloc.dupe(u8, n)
        else
            try defaultPipeName(alloc, opts.session_id);
        defer alloc.free(pipe_name);

        var state: State = .{ .replay = try proto.ReplayBuffer.init(alloc, opts.replay_bytes) };
        defer state.replay.deinit(alloc);

        // Bind BEFORE spawning the shell: a taken name means another holder
        // already serves this session — refuse rather than double-spawn.
        var listener = pipe_stream.PipeListener.bind(alloc, pipe_name) catch |err| {
            log.err("cannot bind holder pipe '{s}': {}", .{ pipe_name, err });
            return err;
        };
        defer listener.deinit();

        // Spawn the shell through the production path: ConPTY + env overlay +
        // cwd fallback + shell resolution + the process-global kill-on-close
        // job (which in THIS process is the holder's own job — holder dies ⇒
        // shell subtree dies).
        var spawner = try pty_child.PtySpawner.init(alloc);
        defer spawner.deinit();
        const pc = try spawner.spawnChild(opts.open orelse .{
            .rows = opts.rows,
            .cols = opts.cols,
            .cwd = opts.cwd,
            .command = opts.command,
            .shell = opts.shell,
        });
        const child = pc.child();
        // One conversion for both Windows arms (T355): a `posix.pid_t` here is
        // the process HANDLE, and the pid the owner is told must be the shell's
        // real one — this is the number that reaches `+sessions` and `+list`.
        const shell_pid: u32 = @intCast(pty_child.reportedPid(pc.pid));

        // Route ConPTY output into the replay ring. The zero-length EOF nudge
        // is dropped here; exit is observed by the poller's `tryWait`.
        child.attach(&state, sinkFn, 1);

        const poller = try std.Thread.spawn(.{}, exitPoller, .{ &state, child, opts.exit_linger_ms });
        poller.detach();

        log.info(
            "holder serving session '{s}' on '{s}' (shell pid {d})",
            .{ opts.session_id, pipe_name, shell_pid },
        );

        while (true) {
            const handle = listener.accept() catch |err| {
                log.warn("accept failed: {}; retrying", .{err});
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            };
            var stream = pipe_stream.PipeStream.init(handle);
            serveOwner(alloc, &state, child, stream.serverStream(), shell_pid, opts);
            // serveOwner closed the stream; if the shell's EXIT was delivered
            // on this connection, the holder's work is done.
            state.mutex.lock();
            const finished = state.exit_delivered;
            state.owner_connected = false;
            state.last_disconnect_ms = std.time.milliTimestamp();
            state.mutex.unlock();
            if (finished) {
                log.info("exit delivered; holder done", .{});
                std.process.exit(0);
            }
        }
    }

    /// `PtyChild` output sink: append to the replay ring, wake the writer.
    /// Never blocks on the owner — a full ring drops its oldest bytes.
    fn sinkFn(ctx: *anyopaque, channel: u128, bytes: []const u8) void {
        _ = channel;
        const state: *State = @ptrCast(@alignCast(ctx));
        if (bytes.len == 0) return; // EOF nudge; the exit poller reaps
        state.read_meter.report();
        state.read_meter.wake();
        state.read_meter.frame(bytes.len);
        state.mutex.lock();
        defer state.mutex.unlock();
        state.replay.append(bytes);
        state.cond.broadcast();
    }

    /// Reap the shell, then enforce the no-owner linger.
    fn exitPoller(state: *State, child: session.Child, linger_ms: i64) void {
        while (true) {
            if (child.tryWait()) |code| {
                state.mutex.lock();
                state.exited = true;
                state.exit_code = code;
                state.exited_at_ms = std.time.milliTimestamp();
                state.cond.broadcast();
                state.mutex.unlock();
                log.info("shell exited with code {d}", .{code});
                break;
            }
            std.Thread.sleep(200 * std.time.ns_per_ms);
        }
        // Linger: give a (re)connecting owner time to collect the exit; an
        // abandoned holder must not idle forever. Delivered exits are ended
        // by the main loop, so only the ownerless timeout acts here.
        while (true) {
            state.mutex.lock();
            const connected = state.owner_connected;
            const since: i64 = @max(state.exited_at_ms, state.last_disconnect_ms);
            state.mutex.unlock();
            if (!connected and std.time.milliTimestamp() - since > linger_ms) {
                log.info("shell exited and no owner within linger; holder done", .{});
                std.process.exit(0);
            }
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
    }

    /// Serve one owner connection to completion (owner disconnect, SHUTDOWN,
    /// or a dead pipe). Always closes `stream` before returning.
    fn serveOwner(
        alloc: Allocator,
        state: *State,
        child: session.Child,
        stream: server.Stream,
        shell_pid: u32,
        opts: Options,
    ) void {
        defer stream.close();

        // HELLO first, always.
        state.mutex.lock();
        const hello: proto.Hello = .{
            .version = proto.proto_version,
            .exited = state.exited,
            .exit_code = state.exit_code,
            .shell_pid = shell_pid,
            .start = state.replay.start,
            .end = state.replay.end,
            .stamp = opts.stamp,
            .session_id = opts.session_id,
        };
        state.owner_connected = true;
        state.mutex.unlock();

        const hello_payload = hello.encode(alloc) catch return;
        defer alloc.free(hello_payload);
        var hdr: [proto.header_len]u8 = undefined;
        proto.frameHeader(.hello, @intCast(hello_payload.len), &hdr);
        stream.writeAll(&hdr) catch return;
        stream.writeAll(hello_payload) catch return;

        var conn: Conn = .{ .stream = stream };
        var writer: ?std.Thread = null;
        defer {
            // Wake + join the writer before the stream goes away.
            state.mutex.lock();
            conn.closed = true;
            state.cond.broadcast();
            state.mutex.unlock();
            if (writer) |t| t.join();
        }

        var accum = proto.Accum.init(alloc);
        defer accum.deinit();
        var buf: [64 * 1024]u8 = undefined;

        while (true) {
            const n = stream.read(&buf) catch 0;
            if (n == 0) return; // owner gone
            accum.push(buf[0..n]) catch return;
            while (accum.next() catch return) |frame| {
                switch (frame.type) {
                    .attach => {
                        if (writer != null) continue; // duplicate ATTACH: ignore
                        const at = proto.Attach.decode(frame.payload) catch return;
                        if (at.version != proto.proto_version) {
                            log.warn("owner protocol v{d} != v{d}; dropping", .{ at.version, proto.proto_version });
                            return;
                        }
                        state.mutex.lock();
                        const from = proto.replayStart(at.ack, state.replay.start, state.replay.end);
                        state.mutex.unlock();
                        writer = std.Thread.spawn(.{}, writerLoop, .{ state, &conn, from }) catch |err| {
                            log.warn("writer spawn failed: {}", .{err});
                            return;
                        };
                    },
                    .input => child.writeAll(frame.payload) catch |err| {
                        log.warn("input write failed: {}", .{err});
                    },
                    .ack => {
                        const ak = proto.Ack.decode(frame.payload) catch return;
                        state.mutex.lock();
                        state.replay.ackTo(ak.offset);
                        state.mutex.unlock();
                    },
                    .resize => {
                        const rs = proto.Resize.decode(frame.payload) catch return;
                        child.resize(rs.rows, rs.cols, rs.px_w, rs.px_h) catch |err| {
                            log.warn("resize failed: {}", .{err});
                        };
                    },
                    .signal => child.signal(frame.payload) catch |err| {
                        log.warn("signal failed: {}", .{err});
                    },
                    .shutdown => {
                        // Owner asked for teardown: exit. The kill-on-close
                        // Job Object (this process holds its only handle)
                        // terminates the shell subtree the moment the process
                        // goes away — deliberately NOT `child.terminate()`,
                        // which frees the child under the exit poller's feet.
                        log.info("SHUTDOWN received; exiting (job takes the shell)", .{});
                        std.process.exit(0);
                    },
                    else => {}, // unknown: additive evolution — ignore
                }
            }
        }
    }

    /// Drain `[sent, replay.end)` to the owner as OUTPUT frames; once the
    /// shell has exited and everything produced has been sent, deliver EXIT.
    fn writerLoop(state: *State, conn: *Conn, start_from: u64) void {
        var sent = start_from;
        // One buffer for the whole frame — header, offset, payload — so an
        // OUTPUT frame is ONE pipe write rather than three (T1464). Each write
        // on this path is an overlapped `WriteFile` plus its completion wait, so
        // three of them per frame is three kernel round trips for what the peer
        // reassembles into one message anyway.
        const prefix_len = proto.header_len + 8;
        var frame_buf: [prefix_len + 32 * 1024]u8 = undefined;
        const chunk = frame_buf[prefix_len..];
        var meter: relay_perf.Meter = .init("holder_out");
        while (true) {
            meter.report();
            var send_n: usize = 0;
            var send_exit = false;
            var exit_code: i64 = 0;

            state.mutex.lock();
            while (true) {
                if (conn.closed) {
                    state.mutex.unlock();
                    return;
                }
                // Bytes dropped by the bounded ring before we sent them (a
                // very slow owner): resume at the oldest retained offset. The
                // offset-tagged OUTPUT frame makes the gap visible.
                if (sent < state.replay.start) sent = state.replay.start;
                if (sent < state.replay.end) {
                    const s = state.replay.from(sent);
                    const n = @min(chunk.len, s.total());
                    const first_n = @min(n, s.first.len);
                    @memcpy(chunk[0..first_n], s.first[0..first_n]);
                    @memcpy(chunk[first_n..n], s.second[0 .. n - first_n]);
                    send_n = n;
                    break;
                }
                if (state.exited and !state.exit_delivered) {
                    send_exit = true;
                    exit_code = state.exit_code;
                    break;
                }
                if (state.exit_delivered) {
                    state.mutex.unlock();
                    return;
                }
                state.cond.wait(&state.mutex);
            }
            state.mutex.unlock();

            if (send_n > 0) {
                var hdr: [proto.header_len]u8 = undefined;
                var ohdr: [8]u8 = undefined;
                proto.frameHeader(.output, @intCast(8 + send_n), &hdr);
                proto.Output.encodeHeader(.{ .offset = sent, .bytes = &.{} }, &ohdr);
                @memcpy(frame_buf[0..proto.header_len], &hdr);
                @memcpy(frame_buf[proto.header_len..prefix_len], &ohdr);
                meter.wake();
                meter.frame(send_n);
                const io = meter.start();
                conn.stream.writeAll(frame_buf[0 .. prefix_len + send_n]) catch return;
                meter.stop(io);
                sent += send_n;
                continue;
            }

            if (send_exit) {
                var hdr: [proto.header_len]u8 = undefined;
                var ebuf: [8]u8 = undefined;
                proto.frameHeader(.exit, 8, &hdr);
                const payload = proto.Exit.encode(.{ .code = exit_code }, &ebuf);
                conn.stream.writeAll(&hdr) catch return;
                conn.stream.writeAll(payload) catch return;
                state.mutex.lock();
                state.exit_delivered = true;
                state.cond.broadcast();
                state.mutex.unlock();
                return;
            }
        }
    }
};
