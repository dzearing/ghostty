//! ssh Transport (§4.1/§4.3) — a real `connection.Stream` backed by an `ssh`
//! subprocess, plus the dialer that builds the two channels of one remote
//! connection and hands them to `connection.Connection`.
//!
//! ## Two channels over one ControlMaster (§4.3)
//! The design requires control frames and data frames to ride **two separate
//! SSH channels**, each with its own SSH-level flow-control window, so a `^C`
//! (control) is never queued behind a 32 KB DATA frame in the app writer. We
//! realize that as **two `ssh` subprocesses** that share one underlying TCP
//! connection via OpenSSH `ControlMaster`/`ControlPath`/`ControlPersist`:
//!
//!   - The **control** subprocess is dialed first with `ControlMaster=auto`
//!     and a private `ControlPath` socket. It establishes (or reuses) the TCP
//!     connection and runs `ghoztty-agent attach --channel=control`.
//!   - The **data** subprocess is dialed second against the SAME `ControlPath`;
//!     OpenSSH multiplexes it as a new SSH channel over the existing master, so
//!     no second TCP handshake / re-auth happens. It runs the agent with
//!     `--channel=data`.
//!
//! Each subprocess exposes ONE bidirectional byte stream: the client writes
//! framed bytes to the child's **stdin** and reads framed bytes from its
//! **stdout** (NOT a pty — the client side is pipe-based; the agent owns the
//! remote pty). `ChildStream` wraps that `(stdout_r, stdin_w)` fd pair as a
//! `connection.Stream`. The `Connection` byte-pump then runs unchanged on top.
//!
//! ## Interactive auth & first-contact (§4.1)
//! `ssh` is run with `-o BatchMode=no` and a controlled `SSH_ASKPASS`
//! (+ `SSH_ASKPASS_REQUIRE=force` and a non-empty `DISPLAY`) so key-passphrase
//! / password / keyboard-interactive (2FA) prompts and first-contact host-key
//! confirmation round-trip through the GUI askpass helper instead of blocking
//! on a controlling tty we don't have. First contact uses
//! `StrictHostKeyChecking=accept-new` (never `no`, §15 m8) — the explicit
//! fingerprint confirmation is surfaced by the askpass helper.
//!
//! ## Dependency injection (standalone testability)
//! Everything in this file imports ONLY siblings (`connection.zig`,
//! `protocol.zig`) + `std`, so `zig test src/remote/connection.zig` compiles
//! and runs the transport tests with no `src/`-root dependency. The one real
//! `src/` dependency — the GUI-free spawn core `CommandCore.DefaultCommand` —
//! is **injected as a comptime type parameter** (`CommandT`) by the production
//! caller (`apprt/embedded.zig`, which has the `src/` module root). The
//! standalone tests pass a tiny fake command type, so the pure arg/env builders
//! AND the `ChildStream` over a real pipe pair are fully unit-tested without a
//! live `ssh` and without reaching outside `src/remote/`.
//!
//! `buildArgs`/`buildEnv`/`controlPath` are pure; `ChildStream` is tested over
//! an in-process pipe pair.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;

const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const client_mux = @import("client_mux.zig");

const log = std.log.scoped(.remote_ssh);

/// pipe(2) with CLOEXEC set on both ends (POSIX). Mirrors `os/pipe.zig` but is
/// inlined here to keep this module sibling-only for standalone testability.
fn pipe() ![2]posix.fd_t {
    return posix.pipe2(.{ .CLOEXEC = true });
}

/// Which logical channel an `ssh` subprocess carries (§4.3). The agent is told
/// via `--channel=<name>` so it wires its end to the matching lane.
pub const Channel = enum {
    control,
    data,

    fn argValue(self: Channel) []const u8 {
        return switch (self) {
            .control => "control",
            .data => "data",
        };
    }
};

/// Dial parameters for one remote connection key (§3.5). Borrowed for the
/// duration of a `dial`/`buildArgs` call; nothing here is retained.
pub const DialConfig = struct {
    /// Remote host (DNS name or IP). Required, non-empty.
    host: []const u8,
    /// Optional SSH user (`user@host`). Null → ssh uses its own default.
    user: ?[]const u8 = null,
    /// TCP port. 0 → ssh default (22); any non-zero value is passed via `-p`.
    port: u16 = 0,
    /// Optional `-J` jump-host chain (comma-separated `[user@]host[:port],...`).
    jump: ?[]const u8 = null,
    /// Optional `-o ProxyCommand=<cmd>`: tunnel the SSH connection through an
    /// external byte-pipe helper instead of a direct TCP dial. This is how the
    /// relay transport works — `ProxyCommand` runs `ghoztty-relay-connect`, which
    /// pipes SSH over an authenticated `wss://` hop to the relay (Tailscale-free,
    /// NAT-agnostic). SSH still runs its handshake end-to-end with the remote
    /// sshd, so the relay only ever sees ciphertext. Null → a direct dial.
    proxy_command: ?[]const u8 = null,
    /// Absolute path to the remote agent executable (§4.1: invoked by absolute
    /// path, never bare `$PATH`). Defaults to the bare command for tests/dev;
    /// production supplies the pushed `~/.local/share/...` path.
    agent_path: []const u8 = "ghoztty-agent",
    /// Optional session id to re-attach to (`--session=<uuid>`). Null → the
    /// agent opens a fresh session.
    session_id: ?[]const u8 = null,
    /// The `ControlPath` socket shared by the two subprocesses. When null,
    /// `dial` mints one under `$TMPDIR`. Provided explicitly by tests.
    control_path: ?[]const u8 = null,
    /// Path to the SSH_ASKPASS helper to surface prompts in the GUI (§4.1).
    /// Null → no askpass is configured (prompts fall back to ssh's default,
    /// fine for key-only / agent-forwarded auth in tests).
    askpass_path: ?[]const u8 = null,
};

// -----------------------------------------------------------------------------
// ChildStream — a connection.Stream over an ssh child's (stdout, stdin) fds
// -----------------------------------------------------------------------------

/// A `connection.Stream` backed by an `ssh` subprocess's stdio pipes:
/// `read` consumes the child's stdout, `write` feeds the child's stdin. Owns
/// the two parent-side fds (the read end of the child's stdout pipe and the
/// write end of its stdin pipe) and closes them on `close`.
///
/// Threading matches the `Stream` contract: one reader thread calls `read`,
/// one writer thread calls `write`, and `close` is safe to call concurrently
/// with a blocked `read` (closing the fd makes the blocked `read` return).
/// `close` is idempotent (guarded by an atomic flag) so the writer's failure
/// path and `Connection.shutdown` can both call it.
pub const ChildStream = struct {
    /// Parent-side read end of the child's stdout. Blocking `read`s here.
    read_fd: posix.fd_t,
    /// Parent-side write end of the child's stdin.
    write_fd: posix.fd_t,
    closed: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init(read_fd: posix.fd_t, write_fd: posix.fd_t) ChildStream {
        // On Darwin/BSD, request EPIPE-instead-of-SIGPIPE on the write fd so a
        // write to a dead child returns `error.BrokenPipe` (which `writeFn`
        // turns into a clean closed-lane) rather than killing the process. On
        // Linux we rely on `MSG_NOSIGNAL`/the process-wide SIGPIPE ignore that
        // `global.init` installs; standalone tests get the same safety here.
        switch (builtin.os.tag) {
            .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => {
                _ = posix.fcntl(write_fd, posix.F.SETNOSIGPIPE, 1) catch {};
            },
            else => {},
        }
        return .{ .read_fd = read_fd, .write_fd = write_fd };
    }

    /// The `Stream` view over this child's pipes.
    pub fn stream(self: *ChildStream) connection.Stream {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: connection.Stream.VTable = .{
        .read = readFn,
        .write = writeFn,
        .close = closeFn,
    };

    fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *ChildStream = @ptrCast(@alignCast(ctx));
        const n = posix.read(self.read_fd, buf) catch |err| switch (err) {
            // A closed fd (during shutdown) surfaces as NotOpenForReading /
            // OperationAborted → report EOF, not a crash.
            error.NotOpenForReading, error.OperationAborted => return 0,
            else => return err,
        };
        return n; // 0 == EOF (peer closed / child exited)
    }

    fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *ChildStream = @ptrCast(@alignCast(ctx));
        return posix.write(self.write_fd, bytes) catch |err| switch (err) {
            // A broken pipe (child gone) is a closed stream: surface as 0 so
            // `writeAll` turns it into `error.WriteZero` and the connection
            // treats it as a dead lane.
            error.BrokenPipe, error.NotOpenForWriting => 0,
            else => err,
        };
    }

    /// Idempotent. Closing the read fd unblocks any blocked `read`.
    fn closeFn(ctx: *anyopaque) void {
        const self: *ChildStream = @ptrCast(@alignCast(ctx));
        if (self.closed.swap(true, .acq_rel)) return;
        // Close write first (signals EOF to the child's stdin), then read.
        if (self.write_fd >= 0) posix.close(self.write_fd);
        if (self.read_fd >= 0 and self.read_fd != self.write_fd) posix.close(self.read_fd);
    }
};

// -----------------------------------------------------------------------------
// Argument / environment construction (pure — unit-tested without spawning)
// -----------------------------------------------------------------------------

/// Build the `ControlMaster` socket path for a connection key. Deterministic
/// per (user, host, port) so the data subprocess reuses the control master's
/// socket. Caller owns the returned slice.
pub fn controlPath(alloc: Allocator, cfg: DialConfig) ![]u8 {
    // posix.getenv is a compile error on Windows (and this file imports only
    // std, so the shared os.getenv helper is off-limits): branch per-OS here.
    const tmp_owned: ?[]u8 = if (comptime builtin.os.tag == .windows)
        std.process.getEnvVarOwned(alloc, "TEMP") catch null
    else
        null;
    defer if (tmp_owned) |t| alloc.free(t);
    const tmp: []const u8 = if (comptime builtin.os.tag == .windows)
        tmp_owned orelse "."
    else
        posix.getenv("TMPDIR") orelse "/tmp";
    // A short, collision-resistant tag from the key. ssh has a ~104-byte
    // sun_path limit, so we hash rather than embed the raw host/user.
    var hasher = std.hash.Wyhash.init(0);
    if (cfg.user) |u| hasher.update(u);
    hasher.update("@");
    hasher.update(cfg.host);
    hasher.update(":");
    var portbuf: [8]u8 = undefined;
    hasher.update(std.fmt.bufPrint(&portbuf, "{d}", .{cfg.port}) catch "0");
    const tag = hasher.final();
    return std.fmt.allocPrint(alloc, "{s}/ghoztty-ssh-{x}.sock", .{
        std.mem.trimRight(u8, tmp, "/"),
        tag,
    });
}

/// Build the full `ssh` argument vector for one channel. `argv[0]` is `"ssh"`;
/// the agent launch command is appended after a `--` so the remote shell does
/// not reinterpret it. All slices are allocated from `alloc` (an arena in
/// production); the returned outer slice and every element are caller-owned.
///
/// Layout:
///   ssh -o BatchMode=no
///       -o StrictHostKeyChecking=accept-new
///       -o ControlMaster=auto -o ControlPath=<path> -o ControlPersist=60
///       [-p <port>] [-J <jump>]
///       [user@]host
///       -- <agent_path> attach --channel=<control|data> [--session=<uuid>]
pub fn buildArgs(
    alloc: Allocator,
    cfg: DialConfig,
    channel: Channel,
    control_path: []const u8,
) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;
    errdefer list.deinit(alloc);

    const H = struct {
        /// Append a copy of a literal/borrowed string.
        fn add(l: *std.ArrayList([:0]const u8), a: Allocator, v: []const u8) !void {
            try l.append(a, try a.dupeZ(u8, v));
        }
        /// Append a formatted string directly as a sentinel slice (no temp).
        fn addFmt(l: *std.ArrayList([:0]const u8), a: Allocator, comptime fmt: []const u8, fargs: anytype) !void {
            try l.append(a, try std.fmt.allocPrintSentinel(a, fmt, fargs, 0));
        }
    };

    try H.add(&list, alloc, "ssh");

    // Interactive auth & first-contact plumbing (§4.1). BatchMode=no lets ssh
    // prompt; the prompts are routed to the GUI via SSH_ASKPASS (see buildEnv).
    try H.add(&list, alloc, "-o");
    try H.add(&list, alloc, "BatchMode=no");
    // First contact: accept-new surfaces a fingerprint confirmation via askpass;
    // a *mismatch* still hard-fails (the §11.7 dialog), never silent (§15 m8).
    try H.add(&list, alloc, "-o");
    try H.add(&list, alloc, "StrictHostKeyChecking=accept-new");

    // ControlMaster: both channels share one TCP connection (§4.3).
    try H.add(&list, alloc, "-o");
    try H.add(&list, alloc, "ControlMaster=auto");
    try H.add(&list, alloc, "-o");
    try H.addFmt(&list, alloc, "ControlPath={s}", .{control_path});
    try H.add(&list, alloc, "-o");
    try H.add(&list, alloc, "ControlPersist=60");

    if (cfg.port != 0) {
        try H.add(&list, alloc, "-p");
        try H.addFmt(&list, alloc, "{d}", .{cfg.port});
    }
    if (cfg.jump) |j| {
        try H.add(&list, alloc, "-J");
        try H.add(&list, alloc, j);
    }
    if (cfg.proxy_command) |pc| {
        try H.add(&list, alloc, "-o");
        try H.addFmt(&list, alloc, "ProxyCommand={s}", .{pc});
    }

    // The destination: [user@]host.
    if (cfg.user) |u| {
        try H.addFmt(&list, alloc, "{s}@{s}", .{ u, cfg.host });
    } else {
        try H.add(&list, alloc, cfg.host);
    }

    // The remote command, after `--` so the login shell doesn't mangle it.
    try H.add(&list, alloc, "--");
    try H.add(&list, alloc, cfg.agent_path);
    try H.add(&list, alloc, "attach");
    try H.addFmt(&list, alloc, "--channel={s}", .{channel.argValue()});
    if (cfg.session_id) |sid| {
        try H.addFmt(&list, alloc, "--session={s}", .{sid});
    }

    return try list.toOwnedSlice(alloc);
}

/// Build args for the SINGLE-subprocess dial mode (§4.3): ONE
/// `ssh host -- ghoztty-agent [--session=<uuid>]` invocation with NO `--channel`
/// split. The single-process agent (`agent/main.zig`) multiplexes both lanes onto
/// its one stdin/stdout, so the client folds its two logical lanes onto this one
/// subprocess via `ClientMux`. There is no second subprocess, so no ControlMaster
/// is needed; we keep `BatchMode`/`StrictHostKeyChecking`/port/jump/askpass.
pub fn buildArgsSingle(
    alloc: Allocator,
    cfg: DialConfig,
) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;
    errdefer list.deinit(alloc);

    const H = struct {
        fn add(l: *std.ArrayList([:0]const u8), a: Allocator, v: []const u8) !void {
            try l.append(a, try a.dupeZ(u8, v));
        }
        fn addFmt(l: *std.ArrayList([:0]const u8), a: Allocator, comptime fmt: []const u8, fargs: anytype) !void {
            try l.append(a, try std.fmt.allocPrintSentinel(a, fmt, fargs, 0));
        }
    };

    try H.add(&list, alloc, "ssh");
    try H.add(&list, alloc, "-o");
    try H.add(&list, alloc, "BatchMode=no");
    try H.add(&list, alloc, "-o");
    try H.add(&list, alloc, "StrictHostKeyChecking=accept-new");

    if (cfg.port != 0) {
        try H.add(&list, alloc, "-p");
        try H.addFmt(&list, alloc, "{d}", .{cfg.port});
    }
    if (cfg.jump) |j| {
        try H.add(&list, alloc, "-J");
        try H.add(&list, alloc, j);
    }
    if (cfg.proxy_command) |pc| {
        try H.add(&list, alloc, "-o");
        try H.addFmt(&list, alloc, "ProxyCommand={s}", .{pc});
    }

    if (cfg.user) |u| {
        try H.addFmt(&list, alloc, "{s}@{s}", .{ u, cfg.host });
    } else {
        try H.add(&list, alloc, cfg.host);
    }

    // The remote command. No `--channel`: the single-process agent muxes both
    // lanes onto its one stdio pipe pair.
    try H.add(&list, alloc, "--");
    try H.add(&list, alloc, cfg.agent_path);
    if (cfg.session_id) |sid| {
        try H.addFmt(&list, alloc, "--session={s}", .{sid});
    }

    return try list.toOwnedSlice(alloc);
}

/// Build the environment for the `ssh` subprocess: a copy of the parent
/// environment plus the SSH_ASKPASS interactive-auth plumbing (§4.1). When
/// `cfg.askpass_path` is null, only the parent env is returned (no askpass).
/// Caller owns the returned `*EnvMap` and must `deinit`+`destroy` it.
pub fn buildEnv(alloc: Allocator, cfg: DialConfig) !*EnvMap {
    const env = try alloc.create(EnvMap);
    errdefer alloc.destroy(env);
    env.* = try std.process.getEnvMap(alloc);
    errdefer env.deinit();

    if (cfg.askpass_path) |askpass| {
        // Route every prompt (passphrase / password / 2FA / host-key) to the
        // GUI helper instead of a tty we don't have.
        try env.put("SSH_ASKPASS", askpass);
        // force: use the askpass even when a tty IS present (§4.1).
        try env.put("SSH_ASKPASS_REQUIRE", "force");
        // OpenSSH historically gated askpass on DISPLAY being set; ensure a
        // non-empty value so the askpass path is taken on all ssh builds.
        if (env.get("DISPLAY") == null) {
            try env.put("DISPLAY", "ghoztty:0");
        }
    }
    return env;
}

// -----------------------------------------------------------------------------
// Spawning — one ssh subprocess per channel (command type injected)
// -----------------------------------------------------------------------------

/// One live `ssh` subprocess + the parent-side `ChildStream` over its stdio.
/// Generic over `CommandT` (the GUI-free `CommandCore.DefaultCommand` in
/// production; a fake in tests). The `command` is retained so we can `wait`/
/// reap the child on teardown.
pub fn ChildChannel(comptime CommandT: type) type {
    return struct {
        const Self = @This();
        command: CommandT,
        stream_impl: *ChildStream,

        /// The `Stream` view handed to `Connection`.
        pub fn stream(self: *Self) connection.Stream {
            return self.stream_impl.stream();
        }
    };
}

/// Spawn one `ssh` subprocess for `channel` using the injected `CommandT`.
/// Sets up two pipes (child stdin, child stdout), wires them as the child's
/// fds, and keeps the parent ends in a heap `ChildStream`. `args` and `env`
/// must outlive the child's exec (the fork copies argv/envp before exec); the
/// caller owns and frees them after this returns. On success the returned
/// channel's `stream_impl` is owned by the caller (freed via `alloc.destroy`
/// after `close`).
///
/// `CommandT` must be a `CommandCore.Command(...)` instantiation: it exposes
/// `path`/`args`/`env`/`stdin`/`stdout` fields, a `start(alloc)` method, a
/// `wait(block)` method, and a `pid` field.
pub fn spawnChannel(
    comptime CommandT: type,
    alloc: Allocator,
    args: []const [:0]const u8,
    env: *const EnvMap,
    channel: Channel,
) !ChildChannel(CommandT) {
    const File = std.fs.File;

    // child stdin: parent writes `stdin[1]`, child reads `stdin[0]`.
    const stdin_pipe = try pipe();
    errdefer {
        posix.close(stdin_pipe[0]);
        posix.close(stdin_pipe[1]);
    }
    // child stdout: child writes `stdout[1]`, parent reads `stdout[0]`.
    const stdout_pipe = try pipe();
    errdefer {
        posix.close(stdout_pipe[0]);
        posix.close(stdout_pipe[1]);
    }

    const stream_impl = try alloc.create(ChildStream);
    errdefer alloc.destroy(stream_impl);
    stream_impl.* = ChildStream.init(stdout_pipe[0], stdin_pipe[1]);

    var cmd: CommandT = .{
        .path = args[0],
        .args = args,
        .env = env,
        // The child reads its framed stdin from the pipe read end and writes
        // framed stdout to the pipe write end. stderr is left inherited so ssh
        // auth diagnostics surface in the GUI process log.
        .stdin = File{ .handle = stdin_pipe[0] },
        .stdout = File{ .handle = stdout_pipe[1] },
    };
    try cmd.start(alloc);

    // The child now owns its ends; close the parent's copies of the child ends
    // so EOF propagates correctly when one side closes.
    posix.close(stdin_pipe[0]);
    posix.close(stdout_pipe[1]);

    log.debug("spawned ssh {s} channel pid={?d}", .{ channel.argValue(), cmd.pid });
    return .{ .command = cmd, .stream_impl = stream_impl };
}

// -----------------------------------------------------------------------------
// Transport — owns the two ssh subprocesses + the Connection
// -----------------------------------------------------------------------------

/// A live ssh transport: the two `ssh` subprocesses (control + data) and the
/// `Connection` byte-pump riding them. Generic over the injected `CommandT`.
/// Heap-allocated and owned by the C-API `RemoteConnectionHandle` (or a test).
/// `deinit` shuts the connection down, reaps both children, and frees
/// everything.
pub fn Transport(comptime CommandT: type) type {
    return struct {
        const Self = @This();
        const Child = ChildChannel(CommandT);

        alloc: Allocator,
        control_child: Child,
        data_child: Child,
        conn: *connection.Connection,
        /// The control-path socket, owned here and reused by both subprocesses.
        control_path: []u8,

        /// Dial a remote connection: pick the transfer encoding, build args/env,
        /// spawn the control then the data subprocess (sharing one
        /// ControlMaster), create the `Connection` over their two streams, and
        /// `start` it (queues the client HELLO + spawns the pump threads). Does
        /// NOT block on the handshake — the caller does that via
        /// `Connection.waitHandshake`.
        pub fn dial(alloc: Allocator, cfg: DialConfig) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            const cpath = if (cfg.control_path) |p|
                try alloc.dupe(u8, p)
            else
                try controlPath(alloc, cfg);
            errdefer alloc.free(cpath);

            // The env is shared by both subprocesses. Built once, freed at the
            // end of dialing (the fork copies envp before exec).
            const env = try buildEnv(alloc, cfg);
            defer {
                env.deinit();
                alloc.destroy(env);
            }

            // Control channel first (establishes / owns the ControlMaster).
            const ctrl_child = try spawnChild(CommandT, alloc, cfg, .control, cpath, env);
            errdefer teardownChild(CommandT, alloc, ctrl_child);

            // Data channel second (multiplexes over the existing master).
            const data_child = try spawnChild(CommandT, alloc, cfg, .data, cpath, env);
            errdefer teardownChild(CommandT, alloc, data_child);

            // Pin the transfer encoding (§4.2). `.cobs` is a safe default that
            // survives a CR/LF-mangling hop; the client decides the encoding.
            const hello: protocol.Hello = .{ .transfer_encoding = .cobs };

            var ctrl = ctrl_child;
            var data = data_child;
            const conn = try connection.Connection.create(
                alloc,
                ctrl.stream(),
                data.stream(),
                hello,
            );
            errdefer conn.destroy(alloc);

            self.* = .{
                .alloc = alloc,
                .control_child = ctrl_child,
                .data_child = data_child,
                .conn = conn,
                .control_path = cpath,
            };
            try self.conn.start();
            return self;
        }

        /// Shut down the connection, close the streams (which the children
        /// observe as EOF on stdin and exit), reap both children, and free
        /// everything.
        pub fn deinit(self: *Self) void {
            const alloc = self.alloc;
            self.conn.shutdown();
            self.conn.destroy(alloc);
            // Streams are already closed by `shutdown`; reap the children.
            reapChild(CommandT, &self.control_child);
            reapChild(CommandT, &self.data_child);
            alloc.destroy(self.control_child.stream_impl);
            alloc.destroy(self.data_child.stream_impl);
            alloc.free(self.control_path);
            alloc.destroy(self);
        }
    };
}

/// A live SINGLE-subprocess ssh transport (§4.3): ONE `ssh host -- ghoztty-agent`
/// child, a `ClientMux` folding the client's two logical lanes onto that one
/// `ChildStream`, and the `Connection` riding the mux's two lanes. This is the
/// path that talks to the single-process agent WITHOUT daemonization (the
/// two-channel `Transport` above is retained as the future daemon design).
///
/// Generic over `CommandT` exactly like `Transport`.
pub fn SingleTransport(comptime CommandT: type) type {
    return struct {
        const Self = @This();
        const Child = ChildChannel(CommandT);

        alloc: Allocator,
        child: Child,
        mux: *client_mux.ClientMux,
        conn: *connection.Connection,

        /// Dial a remote connection over ONE ssh subprocess. Spawns the child,
        /// stands up the `ClientMux` over its `ChildStream`, creates the
        /// `Connection` over the mux's two lanes, spawns the inbound demux pump,
        /// and `start`s the connection (queues the HELLO + spawns the pump
        /// threads). Does NOT block on the handshake — the caller does that via
        /// `Connection.waitHandshake`.
        pub fn dial(alloc: Allocator, cfg: DialConfig) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            const env = try buildEnv(alloc, cfg);
            defer {
                env.deinit();
                alloc.destroy(env);
            }

            // ONE subprocess, no `--channel`.
            var arena = std.heap.ArenaAllocator.init(alloc);
            const args = buildArgsSingle(arena.allocator(), cfg) catch |e| {
                arena.deinit();
                return e;
            };
            // `spawnChannel` only uses `channel` for a log label; `.control` is fine.
            var child = spawnChannel(CommandT, alloc, args, env, .control) catch |e| {
                arena.deinit();
                return e;
            };
            arena.deinit();
            errdefer teardownChild(CommandT, alloc, child);

            // Pin the transfer encoding (§4.2). `.cobs` survives a CR/LF-mangling
            // hop; the client decides the encoding (the agent echoes it).
            const encoding: protocol.TransferEncoding = .cobs;

            const mux = try client_mux.ClientMux.create(alloc, child.stream(), encoding);
            errdefer mux.destroy();

            const lanes = mux.streams();
            const hello: protocol.Hello = .{ .transfer_encoding = encoding };
            const conn = try connection.Connection.create(
                alloc,
                lanes.control,
                lanes.data,
                hello,
            );
            errdefer conn.destroy(alloc);

            self.* = .{
                .alloc = alloc,
                .child = child,
                .mux = mux,
                .conn = conn,
            };

            // Spawn the inbound demux pump BEFORE starting the connection so the
            // peer HELLO is demuxed onto the control lane as soon as it arrives.
            _ = try self.mux.startPump();
            try self.conn.start();
            return self;
        }

        /// Shut down the connection (closes the lane streams → the mux closes the
        /// underlying ChildStream → the child sees stdin EOF and exits, and the
        /// pump's blocked read unblocks), join the pump, reap the child, and free.
        pub fn deinit(self: *Self) void {
            const alloc = self.alloc;
            self.conn.shutdown();
            self.conn.destroy(alloc);
            // `shutdown` closed the lane streams, which closed the mux + transport.
            self.mux.joinPump();
            reapChild(CommandT, &self.child);
            alloc.destroy(self.child.stream_impl);
            self.mux.destroy();
            alloc.destroy(self);
        }
    };
}

/// Build args for `channel`, spawn the subprocess, and free the args (the fork
/// copied argv before exec). `env`/`cpath` are owned by the caller.
fn spawnChild(
    comptime CommandT: type,
    alloc: Allocator,
    cfg: DialConfig,
    channel: Channel,
    cpath: []const u8,
    env: *const EnvMap,
) !ChildChannel(CommandT) {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const args = try buildArgs(arena.allocator(), cfg, channel, cpath);
    return spawnChannel(CommandT, alloc, args, env, channel);
}

/// Close a child's stream and reap it (used on the dial errdefer path before a
/// `Transport` exists to own it).
fn teardownChild(comptime CommandT: type, alloc: Allocator, child: ChildChannel(CommandT)) void {
    var c = child;
    c.stream_impl.stream().close();
    reapChild(CommandT, &c);
    alloc.destroy(c.stream_impl);
}

/// Best-effort reap: kill the ssh child (its stdin already EOF'd via close) and
/// wait for it so we don't leak a zombie.
fn reapChild(comptime CommandT: type, child: *ChildChannel(CommandT)) void {
    if (child.command.pid) |pid| {
        // The ssh client exits when its stdin closes and the master persists
        // only for `ControlPersist`; a SIGTERM is a belt-and-suspenders nudge.
        // Guard pid > 0: `kill(0, ...)` would signal our whole process group and
        // `kill(-1, ...)` every process — only a real child pid is ever killed.
        if (pid > 0) posix.kill(pid, posix.SIG.TERM) catch {};
        _ = child.command.wait(true) catch {};
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "controlPath: deterministic per key, under TMPDIR" {
    const alloc = testing.allocator;
    const cfg: DialConfig = .{ .host = "example.com", .user = "alice", .port = 2222 };
    const a = try controlPath(alloc, cfg);
    defer alloc.free(a);
    const b = try controlPath(alloc, cfg);
    defer alloc.free(b);
    try testing.expectEqualStrings(a, b); // deterministic

    // A different port → a different socket.
    const cfg2: DialConfig = .{ .host = "example.com", .user = "alice", .port = 2200 };
    const c = try controlPath(alloc, cfg2);
    defer alloc.free(c);
    try testing.expect(!std.mem.eql(u8, a, c));

    try testing.expect(std.mem.endsWith(u8, a, ".sock"));
    try testing.expect(std.mem.indexOf(u8, a, "ghoztty-ssh-") != null);
}

test "buildArgs: control channel, user+port, agent path" {
    const alloc = testing.allocator;
    const cfg: DialConfig = .{
        .host = "host.example",
        .user = "bob",
        .port = 2022,
        .agent_path = "/opt/ghoztty/agent",
    };
    const args = try buildArgs(alloc, cfg, .control, "/tmp/cp.sock");
    defer {
        for (args) |a| alloc.free(a);
        alloc.free(args);
    }

    try testing.expectEqualStrings("ssh", args[0]);
    // Assemble for substring assertions.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (args) |a| {
        try joined.appendSlice(alloc, a);
        try joined.append(alloc, ' ');
    }
    const s = joined.items;
    try testing.expect(std.mem.indexOf(u8, s, "BatchMode=no") != null);
    try testing.expect(std.mem.indexOf(u8, s, "StrictHostKeyChecking=accept-new") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ControlMaster=auto") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ControlPath=/tmp/cp.sock") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ControlPersist=60") != null);
    try testing.expect(std.mem.indexOf(u8, s, "-p 2022 ") != null);
    try testing.expect(std.mem.indexOf(u8, s, "bob@host.example") != null);
    try testing.expect(std.mem.indexOf(u8, s, "/opt/ghoztty/agent attach --channel=control") != null);
}

test "buildArgs: data channel, no user, default port, with session" {
    const alloc = testing.allocator;
    const cfg: DialConfig = .{
        .host = "10.0.0.5",
        .session_id = "abc-123",
    };
    const args = try buildArgs(alloc, cfg, .data, "/tmp/cp.sock");
    defer {
        for (args) |a| alloc.free(a);
        alloc.free(args);
    }
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (args) |a| {
        try joined.appendSlice(alloc, a);
        try joined.append(alloc, ' ');
    }
    const s = joined.items;
    // No -p when port is 0; no user@ prefix; the bare host stands alone.
    try testing.expect(std.mem.indexOf(u8, s, "-p ") == null);
    try testing.expect(std.mem.indexOf(u8, s, "@10.0.0.5") == null);
    try testing.expect(std.mem.indexOf(u8, s, " 10.0.0.5 ") != null);
    try testing.expect(std.mem.indexOf(u8, s, "--channel=data") != null);
    try testing.expect(std.mem.indexOf(u8, s, "--session=abc-123") != null);
}

test "buildArgs: jump host" {
    const alloc = testing.allocator;
    const cfg: DialConfig = .{ .host = "target", .jump = "bastion.example" };
    const args = try buildArgs(alloc, cfg, .control, "/tmp/cp.sock");
    defer {
        for (args) |a| alloc.free(a);
        alloc.free(args);
    }
    var saw_j = false;
    var saw_jump = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-J")) saw_j = true;
        if (std.mem.eql(u8, a, "bastion.example")) saw_jump = true;
    }
    try testing.expect(saw_j and saw_jump);
}

test "buildArgs: proxy command (relay transport)" {
    const alloc = testing.allocator;
    const pc = "ghoztty-relay-connect -base https://relay -device d1";
    const cfg: DialConfig = .{ .host = "d1", .proxy_command = pc };
    inline for (.{ true, false }) |single| {
        const args = if (single)
            try buildArgsSingle(alloc, cfg)
        else
            try buildArgs(alloc, cfg, .control, "/tmp/cp.sock");
        defer {
            for (args) |a| alloc.free(a);
            alloc.free(args);
        }
        var saw_o = false;
        var saw_pc = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "-o")) saw_o = true;
            if (std.mem.eql(u8, a, "ProxyCommand=" ++ pc)) saw_pc = true;
        }
        try testing.expect(saw_o and saw_pc);
    }
}

test "buildArgsSingle: ONE subprocess, no --channel, no ControlMaster" {
    const alloc = testing.allocator;
    const cfg: DialConfig = .{
        .host = "host.example",
        .user = "bob",
        .port = 2222,
        .agent_path = "/opt/ghoztty-agent",
        .session_id = "abc-123",
    };
    const args = try buildArgsSingle(alloc, cfg);
    defer {
        for (args) |a| alloc.free(a);
        alloc.free(args);
    }
    try testing.expectEqualStrings("ssh", args[0]);
    var saw_dest = false;
    var saw_agent = false;
    var saw_session = false;
    for (args) |a| {
        // The single-process path must NOT split lanes or open a ControlMaster.
        try testing.expect(std.mem.indexOf(u8, a, "--channel") == null);
        try testing.expect(std.mem.indexOf(u8, a, "ControlMaster") == null);
        try testing.expect(std.mem.indexOf(u8, a, "ControlPath") == null);
        if (std.mem.eql(u8, a, "bob@host.example")) saw_dest = true;
        if (std.mem.eql(u8, a, "/opt/ghoztty-agent")) saw_agent = true;
        if (std.mem.eql(u8, a, "--session=abc-123")) saw_session = true;
    }
    try testing.expect(saw_dest and saw_agent and saw_session);
}

test "buildEnv: askpass plumbing set when configured" {
    const alloc = testing.allocator;
    const cfg: DialConfig = .{ .host = "h", .askpass_path = "/usr/lib/ghoztty-askpass" };
    const env = try buildEnv(alloc, cfg);
    defer {
        env.deinit();
        alloc.destroy(env);
    }
    try testing.expectEqualStrings("/usr/lib/ghoztty-askpass", env.get("SSH_ASKPASS").?);
    try testing.expectEqualStrings("force", env.get("SSH_ASKPASS_REQUIRE").?);
    try testing.expect(env.get("DISPLAY") != null); // non-empty DISPLAY ensured
}

test "buildEnv: no askpass when unconfigured" {
    const alloc = testing.allocator;
    const cfg: DialConfig = .{ .host = "h" };
    const env = try buildEnv(alloc, cfg);
    defer {
        env.deinit();
        alloc.destroy(env);
    }
    try testing.expect(env.get("SSH_ASKPASS") == null);
    try testing.expect(env.get("SSH_ASKPASS_REQUIRE") == null);
}

// --- ChildStream over an in-process pipe pair --------------------------------
//
// Proves the `connection.Stream` vtable carries bytes both directions and that
// `close` unblocks a blocked `read` (the contract `Connection.shutdown` relies
// on). No ssh involved: we wire the "child" ends to the test thread.

test "ChildStream: round-trips bytes through the Stream vtable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // to_peer: stream writes to_peer[1], peer reads to_peer[0].
    const to_peer = try pipe();
    // from_peer: peer writes from_peer[1], stream reads from_peer[0].
    const from_peer = try pipe();

    var cs = ChildStream.init(from_peer[0], to_peer[1]);
    const s = cs.stream();

    // Write through the stream → readable on the peer's read end.
    try s.writeAll("hello");
    var buf: [16]u8 = undefined;
    const n = try posix.read(to_peer[0], &buf);
    try testing.expectEqualStrings("hello", buf[0..n]);

    // Peer writes → readable through the stream.
    _ = try posix.write(from_peer[1], "world");
    const m = try s.read(&buf);
    try testing.expectEqualStrings("world", buf[0..m]);

    // Close the peer's write end → stream read returns EOF (0).
    posix.close(from_peer[1]);
    const e = try s.read(&buf);
    try testing.expectEqual(@as(usize, 0), e);

    // Clean up the peer's remaining fd and the stream's owned fds (idempotent).
    posix.close(to_peer[0]);
    s.close();
    s.close(); // idempotent
}

test "ChildStream: close unblocks a blocked read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const to_peer = try pipe();
    const from_peer = try pipe();
    var cs = ChildStream.init(from_peer[0], to_peer[1]);

    const Ctx = struct {
        cs: *ChildStream,
        got: usize = 1,
        fn run(self: *@This()) void {
            var buf: [8]u8 = undefined;
            // Blocks until close() shuts the read fd.
            self.got = self.cs.stream().read(&buf) catch 99;
        }
    };
    var ctx: Ctx = .{ .cs = &cs };
    const th = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    // Give the reader a moment to block, then close.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    cs.stream().close();
    th.join();
    // The blocked read returns 0 (EOF) once the fd is closed under it.
    try testing.expectEqual(@as(usize, 0), ctx.got);

    posix.close(to_peer[0]);
    posix.close(from_peer[1]);
}

// --- spawnChannel + a live Connection handshake using a FAKE command ---------
//
// Injects a fake `CommandT` whose `start` runs a tiny in-process "ssh+agent"
// thread that reads the framed client stdin and speaks the HELLO handshake back
// on stdout, exactly like the real agent would over the ssh pipe. This proves
// the spawn wiring (pipes → ChildStream → Connection) carries a real handshake,
// without requiring a live `ssh` binary or remote agent. The two channels use
// two independent fake children, mirroring the two ssh subprocesses.

/// A fake CommandCore-shaped command. `start` forks an in-process thread (not a
/// real process) that plays the agent on the child's stdin/stdout fds. It
/// exposes the same fields/methods `spawnChannel` duck-types against.
const FakeAgentCommand = struct {
    const Exit = union(enum) { Exited: u8 };

    path: [:0]const u8 = "ssh",
    args: []const [:0]const u8 = &.{},
    env: ?*const EnvMap = null,
    stdin: ?std.fs.File = null,
    stdout: ?std.fs.File = null,
    pid: ?std.posix.pid_t = null,

    // The agent thread + a stop flag, retained so `wait` can join it.
    thread: ?std.Thread = null,

    fn start(self: *FakeAgentCommand, alloc: Allocator) !void {
        // A real `Command` forks and the child inherits its own copies of the
        // fds; `spawnChannel` then closes the parent's copies of the *child*
        // ends. Since our fake "child" is an in-process thread sharing the fd
        // table, we `dup` the child ends here so the parent's post-spawn close
        // doesn't yank the fds out from under the agent thread.
        const child_in = try std.posix.dup(self.stdin.?.handle); // child reads stdin
        const child_out = try std.posix.dup(self.stdout.?.handle); // child writes stdout
        self.thread = try std.Thread.spawn(.{}, struct {
            fn entry(in_fd: std.posix.fd_t, out_fd: std.posix.fd_t, a: Allocator) void {
                // Own the duped fds; close them when the agent thread exits.
                defer std.posix.close(in_fd);
                defer std.posix.close(out_fd);
                // Read the client HELLO, reply, then drain.
                var reader = protocol.Reader.init(a, .cobs);
                defer reader.deinit();
                var scratch: [4096]u8 = undefined;
                const hello = blk: while (true) {
                    if (reader.next() catch return) |frame| {
                        if (frame.type == .hello) break :blk frame;
                        continue;
                    }
                    const k = std.posix.read(in_fd, &scratch) catch return;
                    if (k == 0) return;
                    reader.push(scratch[0..k]) catch return;
                };
                var parsed = protocol.Hello.parse(a, hello.payload) catch return;
                const enc = parsed.value.transfer_encoding;
                parsed.deinit();
                const reply: protocol.Hello = .{ .transfer_encoding = enc };
                const json = reply.encode(a) catch return;
                defer a.free(json);
                var wire: std.ArrayList(u8) = .empty;
                defer wire.deinit(a);
                protocol.writeFrame(a, enc, .{
                    .type = .hello,
                    .channel = protocol.control_channel,
                    .seq = 0,
                    .payload = json,
                }, &wire) catch return;
                _ = std.posix.write(out_fd, wire.items) catch return;
                while (true) {
                    const k = std.posix.read(in_fd, &scratch) catch return;
                    if (k == 0) return;
                }
            }
        }.entry, .{ child_in, child_out, alloc });
        self.pid = 0;
    }

    fn wait(self: FakeAgentCommand, block: bool) !Exit {
        _ = block;
        if (self.thread) |t| t.join();
        return .{ .Exited = 0 };
    }
};

test "spawnChannel: pipes carry a real HELLO handshake (fake agent, no ssh)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    // Two fake children = the two ssh subprocesses. We bypass `dial` (which
    // would shell out to real ssh) and wire the streams into a Connection here,
    // mirroring exactly what `dial` does after spawning.
    const args: []const [:0]const u8 = &.{"ssh"};
    var env = EnvMap.init(alloc);
    defer env.deinit();

    var ctrl_child = try spawnChannel(FakeAgentCommand, alloc, args, &env, .control);
    var data_child = try spawnChannel(FakeAgentCommand, alloc, args, &env, .data);
    // Teardown is the same regardless of how the assertions go: shutdown closes
    // the streams (EOFs the fake agents' stdin), the reaper joins the threads,
    // and we free the stream impls + the connection.
    defer {
        reapChild(FakeAgentCommand, &ctrl_child);
        reapChild(FakeAgentCommand, &data_child);
        alloc.destroy(ctrl_child.stream_impl);
        alloc.destroy(data_child.stream_impl);
    }

    const hello: protocol.Hello = .{ .transfer_encoding = .cobs };
    const conn = try connection.Connection.create(
        alloc,
        ctrl_child.stream(),
        data_child.stream(),
        hello,
    );
    defer {
        conn.shutdown();
        conn.destroy(alloc);
    }

    try conn.start();
    const neg = try conn.waitHandshake();
    try testing.expectEqual(protocol.TransferEncoding.cobs, neg.transfer_encoding);
    try testing.expectEqual(protocol.proto_version, neg.proto_version);
}
