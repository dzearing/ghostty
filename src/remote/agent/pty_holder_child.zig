//! The agent's **owner side** of a per-session ConPTY holder (T905, increment 2
//! of the T705 non-destructive agent upgrade — design:
//! `docs/design/agent-nondestructive-handoff.md`).
//!
//! `open()` spawns a holder process (`ghoztty-agent --pty-host --spec <file>`)
//! that ESCAPES the agent's kill-on-close job, dials its control pipe, and
//! hands back a `session.Child`. That is the whole trick: to every other line
//! of the agent — the session store, the ring, `+sessions`, CLOSE, RESIZE,
//! SIGNAL, the exit/tombstone path — a holder-backed session is indistinguish-
//! able from the in-process `PtyChild` it replaces, because it presents the
//! same vtable. Nothing above this file knows a second process exists.
//!
//! What changes is what happens when the AGENT dies: nothing. The ConPTY, the
//! shell and the kill-on-close job all live in the holder, so an agent crash,
//! kill or upgrade leaves the shell running and the holder buffering its
//! output. Picking those survivors back up at the next agent start is T906;
//! this increment's promise is only that they are still there to pick up.
//!
//! ## Threads
//!
//!   - **caller's thread**: `open` (spawn + dial + HELLO + ATTACH), and every
//!     vtable call except output delivery. Frame writes take `write_mutex` so a
//!     keystroke and the reader's ACK can never interleave mid-frame.
//!   - **reader**: one per child. Pumps OUTPUT frames → the session sink,
//!     ACKs what it delivered (releasing the holder's replay buffer), records
//!     EXIT. On an unexpected pipe drop with the holder still ALIVE it
//!     RE-DIALS and re-ATTACHes at the last delivered offset — the protocol's
//!     gap-fill, used in production rather than only in the smoke.
//!
//! ## Failure shapes, and which one is which
//!
//!   - Shell exits → holder sends EXIT → `tryWait` reports the code → the
//!     normal tombstone path. Identical to `PtyChild`.
//!   - Pipe drops, holder alive → transient; re-dial and gap-fill. The session
//!     keeps running; the user sees at most a stall.
//!   - Holder gone → the ConPTY and shell went with it (its own Job Object).
//!     `tryWait` reports the holder's exit code so the session tombstones
//!     instead of hanging alive around a shell that no longer exists.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const proto = @import("pty_host_proto.zig");
const spec_mod = @import("pty_host_spec.zig");
const pty_host = @import("pty_host.zig");
const pipe_stream = @import("../pipe_stream.zig");
const server = @import("server.zig");
const session = @import("session.zig");
const internal_os = @import("../../os/main.zig");
const foreground = @import("foreground.zig");

const is_windows = builtin.os.tag == .windows;
const log = std.log.scoped(.pty_holder);

pub const Options = struct {
    /// Pipe-name-safe session id (`proto.validSessionId`) — becomes the control
    /// pipe's last component and the spec file's name.
    session_id: []const u8,
    /// The OPEN this session is being created from, forwarded verbatim.
    open: protocol.Open,
    /// Bounded un-acked output ring inside the holder.
    replay_bytes: usize = 1024 * 1024,
    /// How long an ownerless holder outlives its exited shell.
    exit_linger_ms: i64 = 10 * 60 * 1000,
    /// How long `open` waits for the freshly spawned holder to bind its pipe.
    dial_timeout_ms: u64 = 15_000,
};

/// What the agent records about a holder-backed session: enough for a LATER
/// agent to find and re-adopt it (T906), which is why every field is written
/// to `sessions.json`. Strings BORROW storage owned by the child and are valid
/// until `terminate` — copy them before any window where the child could go.
pub const Info = struct {
    pipe_name: []const u8,
    /// The holder process's OS pid (not the shell's).
    holder_pid: u32,
    /// The shell the holder spawned, as reported in HELLO.
    shell_pid: u32,
    /// The holder binary's build stamp, so a later agent can tell a
    /// same-generation holder from a stale one.
    stamp: []const u8,
};

pub const Spawned = struct {
    child: session.Child,
    info: Info,
};

/// The opt-in environment variable, read from the AGENT's own environment
/// snapshot (`PtySpawner.env`) rather than the live process environment, so
/// every session in one agent's lifetime is spawned the same way.
pub const env_var = "GHOZTTY_AGENT_PTY_HOLDER";

/// Whether new sessions should be spawned holder-backed, given the value of
/// `env_var` (null when unset). Flag-gated while the mechanism stabilizes
/// (T905): opting in is deliberate, and with the flag off the spawn path stays
/// bit-identical to the in-process ConPTY child that has shipped all along —
/// which is what makes a regression here attributable to the flag.
///
/// Pure, so the truth table is a unit test rather than a claim.
pub fn enabledFor(value: ?[]const u8) bool {
    if (!is_windows) return false; // POSIX holder half is T908 (seat: mac)
    const v = value orelse return false;
    return std.mem.eql(u8, v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "on") or
        std.ascii.eqlIgnoreCase(v, "yes");
}

/// Everything a LATER agent needs to pick up a holder this one left behind
/// (T906). All of it comes out of `sessions.json`.
pub const AdoptOptions = struct {
    /// The recorded control pipe. Dialed VERBATIM — never re-derived from the
    /// session id, because the holder's own id is a different random value
    /// minted before the session had one.
    pipe_name: []const u8,
    /// The AGENT's session id, for log lines only. It is deliberately NOT what
    /// the holder's HELLO is checked against: a holder's id is minted in
    /// `spawnHolderBacked` before `SessionTable.create` has assigned a session
    /// id, so the two are unrelated by construction and comparing them would
    /// refuse every adoption there is.
    session_id: []const u8,
    /// Recorded holder pid, for the liveness handle. 0 ⇒ unknown, and adoption
    /// then relies on the dial alone.
    holder_pid: u32 = 0,
    /// Last output offset this session's ring already holds — the ATTACH `ack`.
    ack: u64 = 0,
    /// How long to wait for the pipe. Short: an adoption sweep runs before the
    /// agent serves anybody, and a holder that is up has its pipe bound already
    /// (it binds before spawning the shell), so this covers a busy box, not a
    /// startup race.
    dial_timeout_ms: u64 = 2_000,
};

/// Whether `pipe_name` is the control pipe a holder calling itself `holder_id`
/// would have bound — i.e. the id is the name's last `-`-separated component
/// (`pty_host.defaultPipeName`).
///
/// This is the identity check adoption makes, and getting it wrong in either
/// direction is expensive: too strict and no session is ever adopted, too loose
/// and a user's pane is wired to somebody else's shell. The holder's id is NOT
/// the agent's session id — it is a fresh random value minted before the
/// session had an id — so the recorded pipe NAME is the only thing the two ends
/// share, which is why the comparison is against the name.
///
/// A suffix match rather than "split on the last dash" so an id containing a
/// dash (the hand-driven `--session-id` path) is handled exactly.
pub fn pipeNamesHolder(pipe_name: []const u8, holder_id: []const u8) bool {
    if (holder_id.len == 0 or holder_id.len >= pipe_name.len) return false;
    const start = pipe_name.len - holder_id.len;
    if (pipe_name[start - 1] != '-') return false;
    return std.mem.eql(u8, pipe_name[start..], holder_id);
}

pub const open = if (is_windows) win.open else stub.open;
/// Attach to an ALREADY RUNNING holder (T906) — the adoption half of `open`.
/// Same `Spawned` result and the same `HolderChild` behind it, so an adopted
/// session is indistinguishable from one this agent spawned itself.
pub const adopt = if (is_windows) win.adopt else stub.adopt;

const stub = struct {
    fn open(_: Allocator, _: Options) !Spawned {
        return error.PtyHolderUnsupported; // Windows-only for now (Mac half: T908)
    }
    fn adopt(_: Allocator, _: AdoptOptions) !Spawned {
        return error.PtyHolderUnsupported;
    }
};

const win = struct {
    const windows = std.os.windows;
    /// The tiered job escape, shared with the app's relaunch guard and local
    /// agent launch (T524/T426). Imported across the apprt boundary on purpose:
    /// it depends on nothing but `std` + `os/windows.zig`, and the alternative
    /// — a second copy of the breakaway → shell-parent-hop → in-job ladder —
    /// is the kind of near-duplicate that drifts apart one bug fix at a time.
    const job_spawn = @import("../../apprt/win32/job_spawn.zig");

    /// How long `terminate` gives a holder to honour SHUTDOWN before it is
    /// terminated outright. Deliberately tiny: the hard kill is not a fallback
    /// of last resort but an equally COMPLETE teardown (the holder owns the only
    /// handle to the kill-on-close job over the shell subtree), so waiting buys
    /// nothing but latency — and `+close` is latency-bounded by the session
    /// persistence floor (T63). Politeness, not safety.
    const shutdown_grace_ms: u64 = 400;

    /// Total time the reader will spend trying to get back to a LIVE holder
    /// after an unexpected pipe drop before declaring the session gone.
    const redial_budget_ms: u64 = 30_000;

    const HolderChild = struct {
        alloc: Allocator,

        /// Owned: the control-pipe connection to the holder.
        pstream: *pipe_stream.PipeStream,
        stream: server.Stream,
        /// Owned copies (Info borrows these).
        pipe_name: []u8,
        stamp: []u8,

        /// Holder process handle (owned; closed on terminate) + its pid.
        holder_proc: windows.HANDLE,
        holder_pid: u32,
        shell_pid: u32,

        /// Serializes whole frames onto the pipe (reader ACKs vs caller INPUT).
        write_mutex: std.Thread.Mutex = .{},

        /// Guards everything below.
        mutex: std.Thread.Mutex = .{},
        sink_ctx: ?*anyopaque = null,
        sink: ?*const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void = null,
        channel: u128 = 0,
        attached: std.Thread.ResetEvent = .{},
        reader: ?std.Thread = null,
        /// Frame reassembly for the link. Owned here (not by the reader) so
        /// bytes the holder sent alongside HELLO — before the reader thread
        /// even exists — are never dropped on the floor.
        accum: proto.Accum,

        /// Last output offset delivered to the sink — the resume point for a
        /// re-ATTACH, and what we ACK back to release the holder's ring.
        received: u64 = 0,
        acked: u64 = 0,

        exited: bool = false,
        exit_code: i64 = 0,
        reaped: bool = false,
        /// The reader gave up: no live holder to talk to any more.
        lost: bool = false,
        /// `terminate` ran (also tells the reader to stop redialing).
        closed: bool = false,

        pub fn child(self: *HolderChild) session.Child {
            return .{ .ctx = self, .vtable = &vtable };
        }

        const vtable: session.Child.VTable = .{
            .attach = attachFn,
            .write = writeFn,
            .resize = resizeFn,
            .signal = signalFn,
            .tryWait = tryWaitFn,
            .terminate = terminateFn,
            .queryCwd = queryCwdFn,
            .queryForegroundPid = queryForegroundPidFn,
            .queryForegroundCommand = queryForegroundCommandFn,
            .deliveredOffset = deliveredOffsetFn,
        };

        /// Where this child's output stream stands, in the HOLDER's offset space
        /// (T906). `received` is advanced BEFORE the sink call that carries those
        /// bytes, and the store reads this from inside that sink call — so the
        /// answer always includes the bytes the caller is appending right now,
        /// which is exactly the invariant the persisted watermark needs.
        fn deliveredOffsetFn(ctx: *anyopaque) ?u64 {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.received;
        }

        // --- frame writing ----------------------------------------------------

        fn sendFrame(self: *HolderChild, t: proto.FrameType, payload: []const u8) !void {
            var hdr: [proto.header_len]u8 = undefined;
            proto.frameHeader(t, @intCast(payload.len), &hdr);
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            try self.stream.writeAll(&hdr);
            if (payload.len > 0) try self.stream.writeAll(payload);
        }

        // --- attach: publish channel + sink, start the reader ------------------

        fn attachFn(
            ctx: *anyopaque,
            sink_ctx: *anyopaque,
            sink: *const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void,
            channel: u128,
        ) void {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            self.sink_ctx = sink_ctx;
            self.sink = sink;
            self.channel = channel;
            self.mutex.unlock();
            self.attached.set();
            if (self.reader == null) {
                self.reader = std.Thread.spawn(.{}, readerLoop, .{self}) catch |err| blk: {
                    log.warn("failed to spawn holder reader thread: {}", .{err});
                    break :blk null;
                };
            }
        }

        fn deliver(self: *HolderChild, bytes: []const u8) void {
            self.mutex.lock();
            const sink = self.sink;
            const sink_ctx = self.sink_ctx;
            const channel = self.channel;
            self.mutex.unlock();
            if (sink) |f| f(sink_ctx.?, channel, bytes);
        }

        /// Pump the holder's frames until the shell exits or the holder is
        /// gone. A pipe drop with the holder still alive is transient: re-dial,
        /// re-ATTACH at `received`, and keep going (the protocol's gap-fill).
        fn readerLoop(self: *HolderChild) void {
            self.attached.wait();
            var buf: [64 * 1024]u8 = undefined;

            while (true) {
                // Drain anything already reassembled (the HELLO read may have
                // carried the first OUTPUT frames with it) before blocking.
                var fatal = false;
                while (true) {
                    const maybe = self.accum.next() catch {
                        fatal = true;
                        break;
                    };
                    const frame = maybe orelse break;
                    if (self.handleFrame(frame)) break; // EXIT: stop reading
                }
                if (fatal) break;
                self.ackDelivered();
                self.mutex.lock();
                const done = self.exited;
                self.mutex.unlock();
                if (done) break;

                const n = self.stream.read(&buf) catch 0;
                if (n == 0) {
                    // The link died. Alive holder ⇒ transient, reconnect and
                    // gap-fill; dead holder ⇒ the session really is over.
                    if (self.reconnect()) continue else break;
                }
                self.accum.push(buf[0..n]) catch break;
            }

            // Whatever ended the loop, nudge the server to reap-check (the same
            // zero-length nudge `PtyChild`'s reader ends on).
            self.deliver(&.{});
        }

        /// Handle one frame. Returns true when the shell's EXIT arrived.
        fn handleFrame(self: *HolderChild, frame: proto.Frame) bool {
            switch (frame.type) {
                .output => {
                    const o = proto.Output.decode(frame.payload) catch return false;
                    self.mutex.lock();
                    const expected = self.received;
                    self.received = o.offset + o.bytes.len;
                    self.mutex.unlock();
                    if (o.offset > expected) {
                        // The holder's bounded ring dropped bytes before we
                        // could take them (a very slow or long-absent owner).
                        // Say how many: a silent gap in a user's scrollback is
                        // exactly the thing that must not be silent.
                        log.warn(
                            "holder replay gap: {d} byte(s) lost before offset {d}",
                            .{ o.offset - expected, o.offset },
                        );
                    }
                    if (o.bytes.len > 0) self.deliver(o.bytes);
                },
                .exit => {
                    const e = proto.Exit.decode(frame.payload) catch return false;
                    self.mutex.lock();
                    self.exited = true;
                    self.exit_code = e.code;
                    self.mutex.unlock();
                    return true;
                },
                // HELLO is consumed by `open`/`reconnect`; anything unknown is a
                // newer holder's additive frame — ignore, never drop the link.
                else => {},
            }
            return false;
        }

        /// Release the holder's retained bytes up to what we have delivered.
        /// One ACK per read batch, not per frame: the ring only needs to know
        /// the high-water mark.
        fn ackDelivered(self: *HolderChild) void {
            self.mutex.lock();
            const want = self.received;
            const have = self.acked;
            self.mutex.unlock();
            if (want == have) return;
            var buf: [8]u8 = undefined;
            self.sendFrame(.ack, proto.Ack.encode(.{ .offset = want }, &buf)) catch return;
            self.mutex.lock();
            self.acked = want;
            self.mutex.unlock();
        }

        /// The pipe went away. If the holder process is still alive this is a
        /// broken connection, not a dead session: re-dial and re-ATTACH at the
        /// last delivered offset. Returns true when the link is back.
        fn reconnect(self: *HolderChild) bool {
            self.mutex.lock();
            const stop = self.closed or self.exited;
            const ack = self.received;
            self.mutex.unlock();
            if (stop) return false;

            var waited: u64 = 0;
            while (waited < redial_budget_ms) : (waited += 200) {
                if (!processAlive(self.holder_proc)) break;
                std.Thread.sleep(200 * std.time.ns_per_ms);
                self.mutex.lock();
                const abort = self.closed;
                self.mutex.unlock();
                if (abort) return false;

                const handle = pipe_stream.dialHandle(self.alloc, self.pipe_name) catch continue;
                const pstream = pipe_stream.PipeStream.create(self.alloc, handle) catch {
                    var s = pipe_stream.PipeStream.init(handle);
                    s.serverStream().close();
                    continue;
                };
                const stream = pstream.serverStream();

                // Install the new link UNDER `write_mutex`, which is also what
                // `terminate` takes to close the current one. Without that
                // interlock a `terminate` racing this swap would close the OLD
                // stream, leave the new one open, and then block forever in
                // `reader.join()` — the reader would be parked on a read
                // nobody is going to cancel. Re-checking `closed` inside the
                // lock is the other half: a terminate that already ran wins,
                // and this connection is dropped instead of installed.
                self.write_mutex.lock();
                self.mutex.lock();
                const abandoned = self.closed;
                self.mutex.unlock();
                if (abandoned) {
                    self.write_mutex.unlock();
                    stream.close();
                    pstream.destroy(self.alloc);
                    return false;
                }
                const old_pstream = self.pstream;
                const old_stream = self.stream;
                self.pstream = pstream;
                self.stream = stream;
                self.write_mutex.unlock();
                old_stream.close(); // idempotent; the peer already hung up
                old_pstream.destroy(self.alloc);

                // A fresh link is a fresh frame stream: whatever half-frame the
                // dead one left behind must not be parsed against it.
                self.accum.deinit();
                self.accum = proto.Accum.init(self.alloc);

                if (helloThenAttach(stream, &self.accum, ack)) |_| {
                    log.info("re-attached to holder for pipe '{s}' at offset {d}", .{ self.pipe_name, ack });
                    return true;
                } else |err| {
                    log.warn("holder re-attach failed: {}", .{err});
                    stream.close();
                    continue;
                }
            }

            self.mutex.lock();
            self.lost = true;
            self.mutex.unlock();
            log.warn("holder for pipe '{s}' is gone; session ends", .{self.pipe_name});
            return false;
        }

        // --- write / resize / signal ------------------------------------------

        fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            if (bytes.len == 0) return 0;
            try self.sendFrame(.input, bytes);
            return bytes.len; // framed: all of it, or an error
        }

        fn resizeFn(ctx: *anyopaque, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            var buf: [8]u8 = undefined;
            try self.sendFrame(.resize, proto.Resize.encode(.{
                .rows = rows,
                .cols = cols,
                .px_w = px_w,
                .px_h = px_h,
            }, &buf));
        }

        fn signalFn(ctx: *anyopaque, name: []const u8) anyerror!void {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            // The holder maps the POSIX-style name exactly like `PtyChild` does
            // (0x03 for INT, TerminateProcess for KILL/TERM), so the mapping
            // lives in ONE place and cannot diverge between the two children.
            try self.sendFrame(.signal, name);
        }

        // --- tryWait: exit from the holder, or the holder's own death ---------

        fn tryWaitFn(ctx: *anyopaque) ?i64 {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.reaped) return self.exit_code;
            if (self.exited) {
                self.reaped = true;
                return self.exit_code;
            }
            if (self.lost) {
                // No holder left to ask. The ConPTY and shell died with it (its
                // kill-on-close job), so report an exit rather than leaving a
                // session alive around a shell that no longer exists.
                var code: windows.DWORD = 1;
                _ = windows.kernel32.GetExitCodeProcess(self.holder_proc, &code);
                if (code == still_active) code = 1;
                self.reaped = true;
                self.exited = true;
                self.exit_code = @intCast(code);
                return self.exit_code;
            }
            return null;
        }

        // --- OS queries, asked of the SHELL (not the holder) ------------------

        fn queryCwdFn(ctx: *anyopaque, alloc: Allocator) ?[]u8 {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            const dead = self.reaped or self.closed or self.exited;
            const pid = self.shell_pid;
            self.mutex.unlock();
            if (dead or pid == 0) return null;
            return internal_os.process_cwd.fromPid(pid, alloc);
        }

        /// ConPTY has no foreground process group — parity with `PtyChild` and
        /// the local `WindowsPty`, both of which answer null here.
        fn queryForegroundPidFn(_: *anyopaque) ?i64 {
            return null;
        }

        fn queryForegroundCommandFn(ctx: *anyopaque, alloc: Allocator) ?session.ForegroundCommand {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            const dead = self.reaped or self.closed or self.exited;
            const pid = self.shell_pid;
            self.mutex.unlock();
            if (dead or pid == 0) return null;
            return switch (foreground.queryWindows(alloc, pid) orelse return null) {
                .none => .none,
                .cmd => |c| .{ .cmd = c },
            };
        }

        // --- terminate ---------------------------------------------------------

        fn terminateFn(ctx: *anyopaque) void {
            const self: *HolderChild = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            if (self.closed) {
                self.mutex.unlock();
                return;
            }
            self.closed = true;
            self.mutex.unlock();

            // Ask nicely first so the holder can tear the shell down through
            // its own job and exit 0; the hard kill below is the backstop.
            self.sendFrame(.shutdown, &.{}) catch {};

            // Close the link BEFORE joining: `close` cancels the reader's
            // parked overlapped read, which is the only thing that unblocks it.
            // Under `write_mutex` so a reader mid-`reconnect` cannot install a
            // replacement stream behind us and leave the join with nothing to
            // wake (see `reconnect`).
            self.write_mutex.lock();
            self.stream.close();
            self.write_mutex.unlock();
            self.attached.set();
            if (self.reader) |t| {
                t.join();
                self.reader = null;
            }
            self.pstream.destroy(self.alloc);
            self.accum.deinit();

            if (!waitProcessExit(self.holder_proc, shutdown_grace_ms)) {
                // Killing the holder is a COMPLETE teardown, not a leak: it
                // holds the only handle to the kill-on-close job over the shell
                // subtree, so the ConPTY, the shell and its children all go.
                _ = windows.kernel32.TerminateProcess(self.holder_proc, 1);
            }
            windows.CloseHandle(self.holder_proc);

            self.alloc.free(self.pipe_name);
            self.alloc.free(self.stamp);
            self.alloc.destroy(self);
        }
    };

    // -------------------------------------------------------------------------
    // Spawning + connecting
    // -------------------------------------------------------------------------

    const still_active: windows.DWORD = 259;

    fn processAlive(h: windows.HANDLE) bool {
        var code: windows.DWORD = 0;
        if (windows.kernel32.GetExitCodeProcess(h, &code) == 0) return false;
        return code == still_active;
    }

    fn waitProcessExit(h: windows.HANDLE, ms: u64) bool {
        var waited: u64 = 0;
        while (waited < ms) : (waited += 50) {
            if (!processAlive(h)) return true;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return !processAlive(h);
    }

    /// Read the holder's HELLO and answer with ATTACH. Returns the HELLO with
    /// its strings BORROWED from `accum` (valid until the next push) — callers
    /// that keep anything must copy it.
    fn helloThenAttach(
        stream: server.Stream,
        accum: *proto.Accum,
        ack: u64,
    ) !proto.Hello {
        var buf: [64 * 1024]u8 = undefined;
        const hello = while (true) {
            if (try accum.next()) |f| {
                if (f.type != .hello) return error.HolderNoHello;
                break try proto.Hello.decode(f.payload);
            }
            const n = stream.read(&buf) catch 0;
            if (n == 0) return error.HolderNoHello;
            try accum.push(buf[0..n]);
        };
        if (hello.version != proto.proto_version) {
            log.warn(
                "holder speaks protocol v{d}, this agent v{d}; refusing",
                .{ hello.version, proto.proto_version },
            );
            return error.HolderProtocolMismatch;
        }
        var abuf: [10]u8 = undefined;
        const payload = proto.Attach.encode(.{ .version = proto.proto_version, .ack = ack }, &abuf);
        var hdr: [proto.header_len]u8 = undefined;
        proto.frameHeader(.attach, @intCast(payload.len), &hdr);
        try stream.writeAll(&hdr);
        try stream.writeAll(payload);
        return hello;
    }

    /// Quote one command-line argument the way `CommandLineToArgvW` un-quotes
    /// it. Both arguments we pass are absolute paths (which can contain spaces
    /// but never a `"`), so this is the short, correct rule rather than the
    /// full backslash-run dance.
    fn appendQuoted(list: *std.ArrayList(u8), alloc: Allocator, arg: []const u8) !void {
        try list.append(alloc, '"');
        for (arg) |c| {
            if (c == '"') try list.append(alloc, '\\');
            try list.append(alloc, c);
        }
        try list.append(alloc, '"');
    }

    fn open(alloc: Allocator, opts: Options) !Spawned {
        if (!proto.validSessionId(opts.session_id)) return error.InvalidSessionId;

        const pipe_name = try pty_host.defaultPipeName(alloc, opts.session_id);
        errdefer alloc.free(pipe_name);

        // 1. Stage the spawn spec (the whole OPEN, verbatim).
        const spec_path = try spec_mod.tempPath(alloc, opts.session_id);
        defer alloc.free(spec_path);
        try spec_mod.write(alloc, spec_path, .{
            .session_id = opts.session_id,
            .pipe_name = pipe_name,
            .replay_bytes = opts.replay_bytes,
            .exit_linger_ms = opts.exit_linger_ms,
            .open = opts.open,
        });
        // If anything below fails the holder never reads it, so it must not be
        // left sitting in TEMP with the session's forwarded environment in it.
        var spec_consumed = false;
        errdefer if (!spec_consumed) std.fs.cwd().deleteFile(spec_path) catch {};

        // 2. Spawn the holder OUT of the agent's kill-on-close job — the entire
        //    point is that it outlives us. `spawnEscapingJob` is the existing
        //    tiered escape (breakaway → shell-parent hop → in-job, loudly).
        const self_exe = try std.fs.selfExePathAlloc(alloc);
        defer alloc.free(self_exe);

        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(alloc);
        try appendQuoted(&cmd, alloc, self_exe);
        try cmd.appendSlice(alloc, " --pty-host --spec ");
        try appendQuoted(&cmd, alloc, spec_path);

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, cmd.items);

        const spawned = try job_spawn.spawnEscapingJob(
            arena,
            cmd_w,
            job_spawn.DETACHED_PROCESS | job_spawn.CREATE_NO_WINDOW,
            "pty-holder",
        );
        windows.CloseHandle(spawned.pi.hThread);
        const holder_proc = spawned.pi.hProcess;
        errdefer {
            _ = windows.kernel32.TerminateProcess(holder_proc, 1);
            windows.CloseHandle(holder_proc);
        }
        if (!spawned.tier.escaped()) {
            // Degraded, and worth saying: a holder inside our job dies with the
            // agent, which is exactly the property this task exists to remove.
            log.warn(
                "holder for session '{s}' could not escape the agent's job ({s}); it will NOT survive an agent restart",
                .{ opts.session_id, spawned.tier.name() },
            );
        }

        // 3. Dial the control pipe. The holder binds BEFORE spawning the shell,
        //    so a connection means it is really serving this session.
        const handle = dial(alloc, pipe_name, holder_proc, opts.dial_timeout_ms) catch |err| {
            log.warn("could not reach holder for session '{s}': {}", .{ opts.session_id, err });
            return err;
        };
        spec_consumed = true; // it bound the pipe, so it read the spec

        const pstream = try pipe_stream.PipeStream.create(alloc, handle);
        errdefer {
            pstream.serverStream().close();
            pstream.destroy(alloc);
        }
        const stream = pstream.serverStream();

        var accum = proto.Accum.init(alloc);
        errdefer accum.deinit();
        const hello = try helloThenAttach(stream, &accum, 0);
        const stamp = try alloc.dupe(u8, hello.stamp);
        errdefer alloc.free(stamp);

        const self = try alloc.create(HolderChild);
        // `accum` moves into the child (plain data — no self-pointers), and
        // with it any bytes that arrived alongside HELLO.
        self.* = .{
            .alloc = alloc,
            .pstream = pstream,
            .stream = stream,
            .pipe_name = pipe_name,
            .stamp = stamp,
            .holder_proc = holder_proc,
            .holder_pid = @intCast(spawned.pi.dwProcessId),
            .shell_pid = hello.shell_pid,
            .accum = accum,
        };
        log.info(
            "session '{s}' is holder-backed: holder pid {d}, shell pid {d}, stamp {s}",
            .{ opts.session_id, self.holder_pid, self.shell_pid, self.stamp },
        );
        return .{
            .child = self.child(),
            .info = .{
                .pipe_name = self.pipe_name,
                .holder_pid = self.holder_pid,
                .shell_pid = self.shell_pid,
                .stamp = self.stamp,
            },
        };
    }

    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: windows.DWORD,
        bInheritHandle: windows.BOOL,
        dwProcessId: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetNamedPipeServerProcessId(
        Pipe: windows.HANDLE,
        ServerProcessId: *windows.ULONG,
    ) callconv(.winapi) windows.BOOL;

    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;
    const PROCESS_TERMINATE: windows.DWORD = 0x0001;
    const SYNCHRONIZE: windows.DWORD = 0x00100000;

    /// Pick up a holder that is already running (T906).
    ///
    /// Two identity checks stand between "a pipe answered" and "this is the
    /// shell that pane was showing", because getting it wrong wires a user's
    /// pane to somebody else's process:
    ///
    ///   1. The holder's HELLO must claim the HOLDER id embedded in the pipe
    ///      name we recorded — NOT the agent's session id, which a holder has
    ///      never heard of (`holderIdFromPipe`). That is what proves the
    ///      process answering this name is the one that bound it, rather than a
    ///      later holder that reused the name.
    ///   2. The process we take a handle to is the pipe's SERVER
    ///      (`GetNamedPipeServerProcessId`), and it must match the recorded pid
    ///      when we have one. Windows recycles pids, so trusting the record
    ///      alone would let `terminate` kill an innocent process that inherited
    ///      it; trusting the pipe alone would let a stranger on the name be
    ///      adopted.
    ///
    /// Failure NEVER terminates the holder — an agent that cannot serve it
    /// leaves it running and says so, so a newer-protocol holder outlives a
    /// rollback instead of being destroyed by it.
    fn adopt(alloc: Allocator, opts: AdoptOptions) !Spawned {
        const handle = try dialExisting(alloc, opts.pipe_name, opts.dial_timeout_ms);
        var pstream_ok = false;
        errdefer if (!pstream_ok) {
            var s = pipe_stream.PipeStream.init(handle);
            s.serverStream().close();
        };

        var server_pid: windows.ULONG = 0;
        const pid: u32 = if (GetNamedPipeServerProcessId(handle, &server_pid) != 0 and server_pid != 0)
            @intCast(server_pid)
        else
            opts.holder_pid;
        if (pid == 0) return error.HolderPidUnknown;
        if (opts.holder_pid != 0 and pid != opts.holder_pid) {
            log.warn(
                "pipe '{s}' is served by pid {d}, not the recorded holder {d}; not adopting",
                .{ opts.pipe_name, pid, opts.holder_pid },
            );
            return error.HolderPidMismatch;
        }
        const holder_proc = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE,
            0,
            pid,
        ) orelse return error.HolderUnreachable;
        errdefer windows.CloseHandle(holder_proc);

        const pstream = try pipe_stream.PipeStream.create(alloc, handle);
        pstream_ok = true;
        errdefer {
            pstream.serverStream().close();
            pstream.destroy(alloc);
        }
        const stream = pstream.serverStream();

        var accum = proto.Accum.init(alloc);
        errdefer accum.deinit();
        const hello = try helloThenAttach(stream, &accum, opts.ack);
        if (!pipeNamesHolder(opts.pipe_name, hello.session_id)) {
            log.warn(
                "holder on '{s}' identifies as '{s}', which is not the holder that name belongs to; not adopting",
                .{ opts.pipe_name, hello.session_id },
            );
            return error.HolderSessionMismatch;
        }

        const pipe_copy = try alloc.dupe(u8, opts.pipe_name);
        errdefer alloc.free(pipe_copy);
        const stamp = try alloc.dupe(u8, hello.stamp);
        errdefer alloc.free(stamp);

        const self = try alloc.create(HolderChild);
        self.* = .{
            .alloc = alloc,
            .pstream = pstream,
            .stream = stream,
            .pipe_name = pipe_copy,
            .stamp = stamp,
            .holder_proc = holder_proc,
            .holder_pid = pid,
            .shell_pid = hello.shell_pid,
            .accum = accum,
            // We told the holder we already have everything below `ack`, so the
            // stream resumes there. Starting at 0 instead would make the first
            // adopted frame look like a replay gap the size of the scrollback.
            .received = opts.ack,
            .acked = opts.ack,
        };
        log.info(
            "adopted holder for session '{s}': holder pid {d}, shell pid {d}, stamp {s}, retained [{d},{d}), resuming at {d}",
            .{ opts.session_id, pid, hello.shell_pid, stamp, hello.start, hello.end, opts.ack },
        );
        if (hello.start > opts.ack) log.warn(
            "session '{s}': {d} byte(s) of output were dropped from the holder's replay buffer while no agent was running",
            .{ opts.session_id, hello.start - opts.ack },
        );
        return .{
            .child = self.child(),
            .info = .{
                .pipe_name = self.pipe_name,
                .holder_pid = self.holder_pid,
                .shell_pid = self.shell_pid,
                .stamp = self.stamp,
            },
        };
    }

    /// Dial a holder that should ALREADY be serving. Unlike `dial` there is no
    /// process handle to early-out on, so this is a plain bounded retry — a
    /// holder that is not there simply never answers.
    fn dialExisting(alloc: Allocator, pipe_name: []const u8, timeout_ms: u64) !windows.HANDLE {
        var waited: u64 = 0;
        while (true) {
            if (pipe_stream.dialHandle(alloc, pipe_name)) |h| return h else |_| {}
            if (waited >= timeout_ms) return error.HolderDialTimeout;
            std.Thread.sleep(50 * std.time.ns_per_ms);
            waited += 50;
        }
    }

    /// Connect to `pipe_name`, retrying while the holder starts up. Gives up
    /// early — and says so — if the holder process dies, so a holder that
    /// refuses its spec surfaces as a spawn failure the user is told about
    /// instead of a 15-second stall.
    fn dial(alloc: Allocator, pipe_name: []const u8, holder: windows.HANDLE, timeout_ms: u64) !windows.HANDLE {
        var waited: u64 = 0;
        while (waited < timeout_ms) : (waited += 50) {
            if (pipe_stream.dialHandle(alloc, pipe_name)) |h| return h else |_| {}
            if (!processAlive(holder)) return error.HolderExited;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return error.HolderDialTimeout;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "pipeNamesHolder: the recorded NAME is the shared identity, not the session id" {
    const pipe = "\\\\.\\pipe\\ghoztty-pty-host-debug-dave-0123456789abcdef0123456789abcdef";

    // The holder answers with the id it was spawned under, which is the last
    // component of the name it bound. This is the case that must pass, and the
    // first version of this check compared against the AGENT's session id
    // instead — which a holder has never heard of, so every adoption was
    // refused and every session was silently relaunched with a fresh shell.
    try testing.expect(pipeNamesHolder(pipe, "0123456789abcdef0123456789abcdef"));

    // A different holder squatting the name is refused: adopting it would wire
    // a user's pane to somebody else's shell.
    try testing.expect(!pipeNamesHolder(pipe, "ffffffffffffffffffffffffffffffff"));
    // A trailing FRAGMENT of the id is not the id — the boundary must be a
    // real `-`, or "…-dave-abc" would match a holder calling itself "c".
    try testing.expect(!pipeNamesHolder(pipe, "cdef0123456789abcdef"));
    try testing.expect(!pipeNamesHolder(pipe, ""));
    try testing.expect(!pipeNamesHolder(pipe, pipe));

    // An id containing a dash (the hand-driven `--pty-host --session-id` path)
    // still matches exactly — which is why this is a suffix test and not a
    // split on the last dash.
    try testing.expect(pipeNamesHolder("\\\\.\\pipe\\ghoztty-pty-host-dave-smoke-1", "smoke-1"));
}

test "enabledFor: only an explicit opt-in turns holders on" {
    // Off is the default and every unset/near-miss value keeps it off — the
    // flag exists so a regression is attributable, which only holds if nothing
    // enables it by accident.
    try testing.expect(!enabledFor(null));
    try testing.expect(!enabledFor(""));
    try testing.expect(!enabledFor("0"));
    try testing.expect(!enabledFor("false"));
    try testing.expect(!enabledFor("11"));
    try testing.expect(!enabledFor(" 1"));

    if (!is_windows) {
        // POSIX has no holder yet (T908): the flag must not half-enable one.
        try testing.expect(!enabledFor("1"));
        return;
    }
    try testing.expect(enabledFor("1"));
    try testing.expect(enabledFor("true"));
    try testing.expect(enabledFor("TRUE"));
    try testing.expect(enabledFor("on"));
    try testing.expect(enabledFor("Yes"));
}
