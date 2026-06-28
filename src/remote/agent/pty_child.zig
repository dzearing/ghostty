//! Real, POSIX-pty-backed `session.Child` (WP2, §4.1–§4.2/§7.1) — the production
//! replacement for the fake buffer-backed child. It is the agent's bridge between
//! a spawned shell/command and the session-server's frame routing:
//!
//!   - `open` opens a pty (`src/pty.zig`), spawns the user's shell on its SLAVE
//!     fds via the GUI-free `CommandCore.DefaultCommand`, and keeps the MASTER fd.
//!   - A reader thread pumps the MASTER fd → the session ring via the `Server`'s
//!     output sink (`onChildOutput`), so child output flows as DATA frames.
//!   - `write` (client keystrokes / inbound DATA) writes to the MASTER fd.
//!   - `resize` drives `TIOCSWINSZ` via `pty.setSize`.
//!   - `signal` maps a POSIX signal name to `kill(2)` on the child's process group.
//!   - `tryWait` is a non-blocking `waitpid(WNOHANG)` → exit code (drives the
//!     existing EXIT/tombstone path); `terminate` SIGKILLs + reaps + joins.
//!
//! Threading: exactly one reader thread per child calls the sink. The `Server`'s
//! `sess_mutex` serializes sink delivery with frame handling (the sink IS
//! `Server.onChildOutput`, which takes that lock). The child is heap-owned by the
//! `PtySpawner` and freed on `terminate`.
//!
//! ## Cross-platform (§13)
//!
//! The OS-specific operations branch on `builtin.os.tag` exactly the way
//! `src/pty.zig` does. On **POSIX** the child runs on a real pty: a forked shell
//! on the SLAVE fds, the MASTER fd pumped/written via `posix.read`/`posix.write`,
//! and signalled via `kill(2)` on the child's process group. On **Windows** the
//! child runs on a **ConPTY** (`WindowsPty`): the shell is spawned with null stdio
//! + `pseudo_console = pty.pseudo_console` (mirrors `src/termio/Exec.zig:1027` and
//! the proven `conpty_smoke.zig`), child output is pumped via
//! `ReadFile(pty.out_pipe)`, input is written via `WriteFile(pty.in_pipe)`, signals
//! map to ConPTY-friendly equivalents (Ctrl-C → `0x03` on the input pipe; kill →
//! `TerminateProcess`), and teardown closes the pty (→ `ClosePseudoConsole`) BEFORE
//! joining the reader so its blocked `ReadFile` EOFs (the smoke's deadlock fix).
//! The public `PtySpawner`/`session.Child` interface is byte-for-byte identical on
//! both — only the internal per-OS syscall arm differs.
//!
//! Deferred (later increments): daemonization, idle-TTL GC, Job/containment caps,
//! a real grid-model snapshot (§7.3). On Windows, Job-Object subtree kill +
//! `GenerateConsoleCtrlEvent` group signalling are future hardening; this arm uses
//! the simplest robust ConPTY paths (see `spike/FINDINGS.md` §5).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Pty = @import("../../pty.zig").Pty;
const CommandCore = @import("../../CommandCore.zig");
const protocol = @import("../protocol.zig");
const session = @import("session.zig");
const server = @import("server.zig");
const proc_spawn = @import("proc_spawn.zig");

/// On Windows the OS-specific arms reach `ReadFile`/`WriteFile`/`TerminateProcess`
/// straight from `std.os.windows` — the same kernel32 surface the smoke uses.
const windows = std.os.windows;
const is_windows = builtin.os.tag == .windows;

const log = std.log.scoped(.agent_pty);

/// The GUI-free command type used to fork+exec the shell on the pty slave.
const Command = CommandCore.DefaultCommand;

/// Scratch read size for the master-fd reader loop.
const read_buf_size: usize = 64 * 1024;

/// A pty-backed child process. Heap-allocated and owned by the `PtySpawner`; freed
/// in `terminate` (idempotent). Implements the `session.Child` vtable.
pub const PtyChild = struct {
    alloc: Allocator,

    pty: Pty,
    cmd: Command,
    /// On POSIX this is the child pid; on Windows `posix.pid_t == windows.HANDLE`,
    /// so this holds the child's process HANDLE (what `CommandCore.startWindows`
    /// stores in `cmd.pid`) — used directly by `TerminateProcess`.
    pid: posix.pid_t,

    /// The owning data channel + output sink, published by `attach` after the
    /// session is registered (the reader thread waits on this before delivering).
    sink_ctx: ?*anyopaque = null,
    sink: ?*const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void = null,
    channel: u128 = 0,
    attached: std.Thread.ResetEvent = .{},

    /// The master-fd reader thread.
    reader: ?std.Thread = null,

    /// Lifecycle flags, guarded by `mutex`.
    mutex: std.Thread.Mutex = .{},
    reaped: bool = false,
    exit_code: ?i64 = null,
    /// Set once `terminate` has run; makes it idempotent and tells the reader to
    /// stop (it also unblocks on master EOF when the slave side is gone).
    closed: bool = false,

    /// Build a `session.Child` handle over this struct.
    pub fn child(self: *PtyChild) session.Child {
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
    };

    // --- attach: publish channel + sink, start the reader ---------------------

    fn attachFn(
        ctx: *anyopaque,
        sink_ctx: *anyopaque,
        sink: *const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void,
        channel: u128,
    ) void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        self.sink_ctx = sink_ctx;
        self.sink = sink;
        self.channel = channel;
        self.mutex.unlock();
        // Unblock (or, on first call, allow) the reader to deliver output.
        self.attached.set();
        // Start the reader exactly once.
        if (self.reader == null) {
            self.reader = std.Thread.spawn(.{}, readerLoop, .{self}) catch |err| blk: {
                log.warn("failed to spawn pty reader thread: {}", .{err});
                break :blk null;
            };
        }
    }

    /// Pump MASTER → sink until EOF (slave closed: child exited / pty torn down).
    fn readerLoop(self: *PtyChild) void {
        // Wait until the channel/sink are published so we never route output to a
        // zero channel. (attach() always fires before any output is meaningful.)
        self.attached.wait();
        var buf: [read_buf_size]u8 = undefined;
        while (true) {
            const n = if (is_windows) blk: {
                // Windows: ConPTY output side. `ReadFile(out_pipe)` blocks until
                // bytes arrive and returns 0 (with BROKEN_PIPE) once the ConPTY
                // tears down after the child exits / `ClosePseudoConsole` runs —
                // that is our EOF (mirrors `conpty_smoke.zig`'s reader).
                var read: windows.DWORD = 0;
                if (windows.kernel32.ReadFile(self.pty.out_pipe, &buf, buf.len, &read, null) == 0)
                    break :blk 0;
                break :blk @as(usize, read);
            } else posix.read(self.pty.master, &buf) catch |err| switch (err) {
                // On Linux a pty master read after the slave hangs up yields EIO;
                // treat it as EOF rather than an error.
                error.InputOutput => 0,
                error.WouldBlock => continue,
                else => 0,
            };
            if (n == 0) break; // EOF: child gone
            self.mutex.lock();
            const sink = self.sink;
            const sink_ctx = self.sink_ctx;
            const channel = self.channel;
            self.mutex.unlock();
            if (sink) |f| f(sink_ctx.?, channel, buf[0..n]);
        }
        // After EOF the child has (almost certainly) exited; surface it so the next
        // tryWait reaps and the EXIT/tombstone path fires. A final zero-length sink
        // call nudges the server to reap-check.
        self.mutex.lock();
        const sink = self.sink;
        const sink_ctx = self.sink_ctx;
        const channel = self.channel;
        self.mutex.unlock();
        if (sink) |f| f(sink_ctx.?, channel, &.{});
    }

    // --- write: client keystrokes → master ------------------------------------

    fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        if (is_windows) {
            // Windows: feed the ConPTY input side. `WriteFile(in_pipe)` is the
            // smoke-proven input path (`conpty_smoke.zig`). Return the count so the
            // caller loops on a short write, exactly like the POSIX branch.
            var written: windows.DWORD = 0;
            if (bytes.len == 0) return 0;
            if (windows.kernel32.WriteFile(self.pty.in_pipe, bytes.ptr, @intCast(bytes.len), &written, null) == 0)
                return error.BrokenPipe;
            return @intCast(written);
        }
        return posix.write(self.pty.master, bytes);
    }

    // --- resize: TIOCSWINSZ ----------------------------------------------------

    fn resizeFn(ctx: *anyopaque, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        try self.pty.setSize(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = px_w,
            .ws_ypixel = px_h,
        });
    }

    // --- signal: kill the child's process group --------------------------------

    fn signalFn(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));

        // Windows has no POSIX signals. Map the names we care about onto the
        // ConPTY-friendly equivalents (see `spike/FINDINGS.md` §5):
        //   - INT / QUIT / TSTP / "Ctrl-C" intent → write 0x03 (ETX) to the ConPTY
        //     input pipe. This is the robust, smoke-proven interrupt path: the
        //     ConPTY delivers it to the foreground child as a console Ctrl-C. We do
        //     NOT use `GenerateConsoleCtrlEvent` because the agent's child is not
        //     spawned into its own console process group here, so 0x03-on-input is
        //     the simplest correct path.
        //   - KILL / TERM / HUP → hard `TerminateProcess(hProcess, 1)`. Windows has
        //     no catchable TERM-vs-KILL distinction for a non-cooperating child, so
        //     both escalate to an unconditional terminate (exit code 1).
        //   - Anything else (CONT, USR1/2, WINCH, ...) → ignored (no analogue).
        if (is_windows) {
            if (eqlAny(name, &.{ "INT", "QUIT", "TSTP" })) {
                var written: windows.DWORD = 0;
                const etx = [_]u8{0x03};
                if (windows.kernel32.WriteFile(self.pty.in_pipe, &etx, 1, &written, null) == 0)
                    log.warn("windows interrupt (0x03) write failed", .{});
                return;
            }
            if (eqlAny(name, &.{ "KILL", "TERM", "HUP" })) {
                if (windows.kernel32.TerminateProcess(self.pid, 1) == 0)
                    log.warn("TerminateProcess failed", .{});
                return;
            }
            return; // no ConPTY analogue — drop silently (untrusted input, §15 M3)
        }

        const sig = sigFromName(name) orelse return;
        // The child is its own session/process-group leader (pty.childPreExec calls
        // setsid), so its pgid == pid. Signal the whole group with kill(-pid). If
        // the group lookup fails (e.g. the child hasn't finished setsid yet, or the
        // group is already gone), fall back to signaling the pid directly so an
        // interactive ^C / kill is never silently dropped.
        posix.kill(-self.pid, sig) catch {
            posix.kill(self.pid, sig) catch |err| {
                log.warn("kill({d}, {d}) failed: {}", .{ self.pid, sig, err });
            };
        };
    }

    // --- tryWait: non-blocking reap -------------------------------------------

    fn tryWaitFn(ctx: *anyopaque) ?i64 {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.reaped) return self.exit_code;

        if (is_windows) {
            // Non-blocking reap on Windows: poll the process HANDLE with a zero
            // timeout (we must NOT use `CommandCore.wait` here — it blocks on
            // `WaitForSingleObject(INFINITE)`). WAIT_OBJECT_0 means the process is
            // signalled (exited); WAIT_TIMEOUT means still running.
            const status = windows.kernel32.WaitForSingleObject(self.pid, 0);
            if (status != windows.WAIT_OBJECT_0) return null; // still running
            var exit_code: windows.DWORD = 0;
            if (windows.kernel32.GetExitCodeProcess(self.pid, &exit_code) == 0)
                return null;
            const code: i64 = @intCast(exit_code);
            self.reaped = true;
            self.exit_code = code;
            return code;
        }

        // A genuinely non-blocking reap: `waitpid(WNOHANG)` returns pid 0 when the
        // child has no status yet (we must NOT use `CommandCore.wait(false)` here —
        // it busy-LOOPS until a status is available, which would block this poll).
        const res = posix.waitpid(self.pid, std.c.W.NOHANG);
        if (res.pid == 0) return null; // still running
        const exit = CommandCore.Exit.init(res.status);
        const code: i64 = switch (exit) {
            .Exited => |c| @intCast(c),
            .Signal => |s| @intCast(128 + @as(i64, s)),
            .Stopped => |s| @intCast(128 + @as(i64, s)),
            .Unknown => |s| @intCast(s),
        };
        self.reaped = true;
        self.exit_code = code;
        return code;
    }

    // --- queryCwd: read the child's CURRENT working directory from the OS -------

    /// Ask the OS for the child shell's *current* working directory. This is the
    /// on-demand cwd query the client uses at split/tab time so a new remote pane
    /// inherits the parent's cwd. It reads the CHILD process's actual cwd (not any
    /// OSC-7 hint), so it works even for shells that never emit OSC 7 (cmd.exe).
    ///
    /// Returns a fresh `alloc`-owned UTF-8 slice, or null on any failure (child
    /// gone, syscall error, malformed data). Never crashes on a hostile/buggy
    /// child — all reads are bounds-checked.
    fn queryCwdFn(ctx: *anyopaque, alloc: Allocator) ?[]u8 {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));

        // If we've already reaped the child there's nothing to query.
        self.mutex.lock();
        const dead = self.reaped or self.closed;
        self.mutex.unlock();
        if (dead) return null;

        return switch (builtin.os.tag) {
            .macos => queryCwdMacos(self.pid, alloc),
            .linux => queryCwdLinux(self.pid, alloc),
            .windows => queryCwdWindows(self.pid, alloc),
            else => null,
        };
    }

    // --- terminate: SIGKILL + reap + join + free -------------------------------

    fn terminateFn(ctx: *anyopaque) void {
        const self: *PtyChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return;
        }
        self.closed = true;
        const already_reaped = self.reaped;
        self.mutex.unlock();

        // Hard kill the child if it hasn't already exited.
        //   - POSIX: SIGKILL the whole process group (`-pid`), uncatchable.
        //   - Windows: `TerminateProcess(hProcess, 1)` — there is no process-group
        //     analogue here, so we terminate the ConPTY's root child directly.
        if (!already_reaped) {
            if (is_windows) {
                _ = windows.kernel32.TerminateProcess(self.pid, 1);
            } else {
                posix.kill(-self.pid, posix.SIG.KILL) catch {};
            }
        }

        // Tear down the pty BEFORE joining the reader (the smoke-proven ordering):
        //   - POSIX: closing the master fd hangs up the slave and EOFs the reader's
        //     `read`.
        //   - Windows: `pty.deinit` calls `ClosePseudoConsole`, which is what gives
        //     the reader's blocked `ReadFile(out_pipe)` its EOF. Closing it AFTER
        //     the join would deadlock (see `conpty_smoke.zig`'s teardown note).
        self.pty.deinit();

        // Join the reader (now unblocked by EOF). Ensure it was at least allowed to
        // run (attach may never have fired for an instantly-failed session).
        self.attached.set();
        if (self.reader) |t| {
            t.join();
            self.reader = null;
        }

        // Reap the child to avoid a zombie (best-effort; ignore if already reaped).
        self.mutex.lock();
        const need_reap = !self.reaped;
        self.mutex.unlock();
        if (need_reap) _ = self.cmd.wait(true) catch {};

        self.alloc.destroy(self);
    }
};

/// True if `name` case-insensitively equals any entry in `set`. Used by the
/// Windows SIGNAL arm to group POSIX signal names onto ConPTY actions.
fn eqlAny(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return false;
}

/// Map a POSIX signal NAME (no "SIG" prefix, e.g. "INT", "TERM") to its number.
/// Unknown names → null (ignored, never a crash — untrusted input, §15 M3).
fn sigFromName(name: []const u8) ?u8 {
    const S = posix.SIG;
    const table = .{
        .{ "HUP", S.HUP },   .{ "INT", S.INT },   .{ "QUIT", S.QUIT },
        .{ "KILL", S.KILL }, .{ "TERM", S.TERM }, .{ "USR1", S.USR1 },
        .{ "USR2", S.USR2 }, .{ "STOP", S.STOP }, .{ "CONT", S.CONT },
        .{ "TSTP", S.TSTP }, .{ "WINCH", S.WINCH },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return @intCast(entry[1]);
    }
    return null;
}

// -----------------------------------------------------------------------------
// Per-OS cwd query (on-demand split-cwd inheritance, WP4)
// -----------------------------------------------------------------------------
//
// Each helper reads the CHILD process's *current* working directory directly
// from the OS — independent of any OSC-7 hint — so cwd inheritance works even
// for shells that never report their cwd (e.g. cmd.exe). All return a fresh
// `alloc`-owned UTF-8 slice or null; none ever crash on bad data.

/// macOS: `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)` →
/// `info.pvi_cdir.vip_path` (a NUL-terminated absolute path).
fn queryCwdMacos(pid: posix.pid_t, alloc: Allocator) ?[]u8 {
    if (builtin.os.tag != .macos) return null;
    const PROC_PIDVNODEPATHINFO: c_int = 9;

    // Mirror the libproc structs exactly (C ABI). We only read `pvi_cdir.vip_path`,
    // but the whole struct must be laid out correctly so the field lands at the
    // right offset; declaring them `extern struct` lets Zig compute C offsets.
    const MAXPATHLEN = 1024;
    const fsid_t = extern struct { val: [2]i32 };
    const vinfo_stat = extern struct {
        vst_dev: u32,
        vst_mode: u16,
        vst_nlink: u16,
        vst_ino: u64,
        vst_uid: u32,
        vst_gid: u32,
        vst_atime: i64,
        vst_atimensec: i64,
        vst_mtime: i64,
        vst_mtimensec: i64,
        vst_ctime: i64,
        vst_ctimensec: i64,
        vst_birthtime: i64,
        vst_birthtimensec: i64,
        vst_size: i64,
        vst_blocks: i64,
        vst_blksize: i32,
        vst_flags: u32,
        vst_gen: u32,
        vst_rdev: u32,
        vst_qspare: [2]i64,
    };
    const vnode_info = extern struct {
        vi_stat: vinfo_stat,
        vi_type: c_int,
        vi_pad: c_int,
        vi_fsid: fsid_t,
    };
    const vnode_info_path = extern struct {
        vip_vi: vnode_info,
        vip_path: [MAXPATHLEN]u8,
    };
    const proc_vnodepathinfo = extern struct {
        pvi_cdir: vnode_info_path,
        pvi_rdir: vnode_info_path,
    };

    const proc_pidinfo = struct {
        extern "c" fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: ?*anyopaque,
            buffersize: c_int,
        ) c_int;
    }.proc_pidinfo;

    var info: proc_vnodepathinfo = undefined;
    const want: c_int = @sizeOf(proc_vnodepathinfo);
    const got = proc_pidinfo(@intCast(pid), PROC_PIDVNODEPATHINFO, 0, &info, want);
    // A successful call returns the number of bytes written (== struct size).
    if (got < want) return null;
    const path = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
    if (path.len == 0) return null;
    return alloc.dupe(u8, path) catch null;
}

/// Linux fallback: `readlink("/proc/<pid>/cwd")`.
fn queryCwdLinux(pid: posix.pid_t, alloc: Allocator) ?[]u8 {
    if (builtin.os.tag != .linux) return null;
    var path_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = posix.readlink(link, &out_buf) catch return null;
    if (target.len == 0) return null;
    return alloc.dupe(u8, target) catch null;
}

/// Windows: read the child's `PEB->ProcessParameters->CurrentDirectory.DosPath`.
/// `handle` here is the child's process HANDLE (POSIX `pid_t == windows.HANDLE`).
///
///   1. `NtQueryInformationProcess(ProcessBasicInformation)` → `PebBaseAddress`.
///   2. `ReadProcessMemory` the child's PEB → `ProcessParameters` pointer.
///   3. `ReadProcessMemory` the `RTL_USER_PROCESS_PARAMETERS` →
///      `CurrentDirectory.DosPath` (a `UNICODE_STRING`).
///   4. `ReadProcessMemory` its UTF-16 buffer and convert to UTF-8.
///
/// We use the std `PEB` / `RTL_USER_PROCESS_PARAMETERS` / `UNICODE_STRING` ABI
/// types (no hand-rolled offsets) and the std `ReadProcessMemory` wrapper. This
/// is the standard cross-process cwd read; every read is bounds-checked against
/// the untrusted child and any failure returns null (never crashes).
fn queryCwdWindows(handle: posix.pid_t, alloc: Allocator) ?[]u8 {
    if (builtin.os.tag != .windows) return null;

    // 1. PEB base address via NtQueryInformationProcess.
    var pbi: windows.PROCESS_BASIC_INFORMATION = undefined;
    var ret_len: windows.ULONG = 0;
    const st = windows.ntdll.NtQueryInformationProcess(
        handle,
        .ProcessBasicInformation,
        &pbi,
        @sizeOf(windows.PROCESS_BASIC_INFORMATION),
        &ret_len,
    );
    if (st != .SUCCESS) return null;

    // 2. Read the child's PEB, then take ProcessParameters (a remote pointer).
    var peb: windows.PEB = undefined;
    _ = windows.ReadProcessMemory(
        handle,
        @ptrCast(pbi.PebBaseAddress),
        std.mem.asBytes(&peb),
    ) catch return null;
    const pp_addr = @intFromPtr(peb.ProcessParameters);
    if (pp_addr == 0) return null;

    // 3. Read the RTL_USER_PROCESS_PARAMETERS; take CurrentDirectory.DosPath.
    var params: windows.RTL_USER_PROCESS_PARAMETERS = undefined;
    _ = windows.ReadProcessMemory(
        handle,
        @ptrFromInt(pp_addr),
        std.mem.asBytes(&params),
    ) catch return null;

    const us = params.CurrentDirectory.DosPath; // UNICODE_STRING
    const buf_ptr = us.Buffer orelse return null;
    const wlen: usize = us.Length / 2; // Length is in BYTES
    // A path far over MAX_PATH*2 is bogus; reject it (untrusted child).
    if (wlen == 0 or wlen > 32768) return null;

    // 4. Read the UTF-16 path buffer out of the child and convert to UTF-8.
    const wbuf = alloc.alloc(u16, wlen) catch return null;
    defer alloc.free(wbuf);
    _ = windows.ReadProcessMemory(
        handle,
        @ptrCast(buf_ptr),
        std.mem.sliceAsBytes(wbuf),
    ) catch return null;

    return std.unicode.utf16LeToUtf8Alloc(alloc, wbuf) catch null;
}

// -----------------------------------------------------------------------------
// PtySpawner — turns an OPEN into a pty-backed child (the real `server.Spawner`)
// -----------------------------------------------------------------------------

/// Spawns a real pty-backed child per OPEN. The default shell is `$SHELL` (falling
/// back to `/bin/sh`), invoked login+interactive (`-lic <command>`) when the OPEN
/// carries a `command`, else just login+interactive (`-li`) for a plain shell —
/// mirroring the local CLI's shell convention.
pub const PtySpawner = struct {
    alloc: Allocator,
    /// Owns an EnvMap so child env (TERM + inherited) outlives the fork's arena.
    /// Kept for the spawner's lifetime; each child's `cmd.env` borrows it.
    env: *std.process.EnvMap,

    pub fn init(alloc: Allocator) !*PtySpawner {
        const self = try alloc.create(PtySpawner);
        errdefer alloc.destroy(self);
        const env = try alloc.create(std.process.EnvMap);
        errdefer alloc.destroy(env);
        env.* = std.process.getEnvMap(alloc) catch std.process.EnvMap.init(alloc);
        self.* = .{ .alloc = alloc, .env = env };
        return self;
    }

    pub fn deinit(self: *PtySpawner) void {
        self.env.deinit();
        self.alloc.destroy(self.env);
        self.alloc.destroy(self);
    }

    /// A `server.Spawner` handle over this spawner — plug straight into
    /// `Server.create`.
    pub fn spawner(self: *PtySpawner) server.Spawner {
        return .{ .ctx = self, .spawnFn = spawnFn, .spawnDetachedFn = spawnDetachedFn };
    }

    /// Matches `server.Spawner.spawnFn`: turn an OPEN into a `Child` + pid.
    fn spawnFn(ctx: *anyopaque, open: protocol.Open) anyerror!server.Spawner.Result {
        const self: *PtySpawner = @ptrCast(@alignCast(ctx));
        const pc = try self.spawnChild(open);
        // `Result.pid` is an i64 identifier for the monitor view. On POSIX `pc.pid`
        // is the integer pid; on Windows it is the process HANDLE (a pointer), so we
        // surface its integer value (the OS process id is not separately tracked).
        const pid_i64: i64 = if (is_windows) @intCast(@intFromPtr(pc.pid)) else @intCast(pc.pid);
        return .{ .child = pc.child(), .pid = pid_i64 };
    }

    /// Matches `server.Spawner.spawnDetachedFn`: launch a detached process for
    /// `PROC_SPAWN` (§9.3, inc 5). Delegates to `proc_spawn.spawnDetached` (which
    /// pulls `CommandCore`, kept out of `server.zig` per `proc_spawn.zig`'s doc).
    fn spawnDetachedFn(ctx: *anyopaque, cmd: []const u8, cwd: ?[]const u8) server.Spawner.SpawnResult {
        const self: *PtySpawner = @ptrCast(@alignCast(ctx));
        // `self.alloc` is the same allocator the Server uses, so the Windows
        // diagnostic note (when `free_error`) is freed by `handleProcSpawn` correctly.
        const out = proc_spawn.spawnDetached(self.alloc, cmd, cwd);
        return .{ .ok = out.ok, .pid = out.pid, .@"error" = out.@"error", .free_error = out.free_error };
    }

    /// Open a pty, fork+exec the shell on its slave, return the owned `*PtyChild`.
    pub fn spawnChild(self: *PtySpawner, open: protocol.Open) !*PtyChild {
        const rows: u16 = if (open.rows == 0) 24 else open.rows;
        const cols: u16 = if (open.cols == 0) 80 else open.cols;

        var pty = try Pty.open(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = open.px_w,
            .ws_ypixel = open.px_h,
        });
        errdefer pty.deinit();

        // Set TERM for the child.
        try self.env.put("TERM", open.term);

        const pc = try self.alloc.create(PtyChild);
        errdefer self.alloc.destroy(pc);

        // Resolve the default shell, per-OS:
        //   - POSIX: OPEN.shell → $SHELL → /bin/sh.
        //   - Windows: OPEN.shell → %COMSPEC% → C:\Windows\System32\cmd.exe.
        const shell_path = blk: {
            if (open.shell) |s| if (s.len > 0) break :blk s;
            if (is_windows) {
                if (self.env.get("COMSPEC")) |s| if (s.len > 0) break :blk s;
                break :blk "C:\\Windows\\System32\\cmd.exe";
            }
            if (self.env.get("SHELL")) |s| if (s.len > 0) break :blk s;
            break :blk "/bin/sh";
        };

        // Build argv. `startCommand`/`startWindows` copies these before exec, so in
        // the PARENT they are dead after `start()` returns — we free them right
        // after (see the deferred frees below).
        //   - POSIX: with a command → `<shell> -lic <command>`; without → `<shell>
        //     -li` (login interactive) — mirroring the local CLI's shell convention.
        //   - Windows: cmd.exe-style. With a command → `<shell> /c <command>`;
        //     without → just `<shell>` (an interactive cmd.exe). `-lic`/`-li` are
        //     POSIX-shell flags with no Windows analogue.
        const shell_z = try self.alloc.dupeZ(u8, shell_path);
        defer self.alloc.free(shell_z);

        var args_list: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (args_list.items) |a| self.alloc.free(a);
            args_list.deinit(self.alloc);
        }
        // argv[0] is the shell path (a fresh dupe so freeing the list frees it).
        try args_list.append(self.alloc, try self.alloc.dupeZ(u8, shell_path));
        if (is_windows) {
            if (open.command) |cmd| if (cmd.len > 0) {
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, "/c"));
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, cmd));
            };
        } else if (open.command) |cmd| {
            if (cmd.len > 0) {
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, "-lic"));
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, cmd));
            } else {
                try args_list.append(self.alloc, try self.alloc.dupeZ(u8, "-li"));
            }
        } else {
            try args_list.append(self.alloc, try self.alloc.dupeZ(u8, "-li"));
        }
        const args = args_list.items;

        if (is_windows) {
            // Windows: spawn the shell as a ConPTY child. Mirrors the canonical
            // terminal wiring (`src/termio/Exec.zig:1027`) and the proven
            // `conpty_smoke.zig`: stdin/stdout/stderr are null (the ConPTY owns the
            // child's std handles via PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE) and
            // `pseudo_console` carries `pty.pseudo_console`. No `os_pre_exec`
            // (there is no fork; setsid/TIOCSCTTY are POSIX-only).
            pc.* = .{
                .alloc = self.alloc,
                .pty = pty,
                .cmd = .{
                    .path = shell_z,
                    .args = args,
                    .env = self.env,
                    .cwd = open.cwd,
                    .stdin = null,
                    .stdout = null,
                    .stderr = null,
                    .pseudo_console = pty.pseudo_console,
                },
                .pid = undefined,
            };
            try pc.cmd.start(self.alloc);
            pc.pid = pc.cmd.pid.?;
            return pc;
        }

        // POSIX: the slave fd is handed to the child as stdin/stdout/stderr; the
        // pty's childPreExec (setsid + TIOCSCTTY) runs via os_pre_exec so the child
        // gets a controlling terminal and its own process group.
        const slave_file: std.fs.File = .{ .handle = pty.slave };

        pc.* = .{
            .alloc = self.alloc,
            .pty = pty,
            .cmd = .{
                .path = shell_z,
                .args = args,
                .env = self.env,
                .cwd = open.cwd,
                .stdin = slave_file,
                .stdout = slave_file,
                .stderr = slave_file,
                .os_pre_exec = ptyPreExec,
                .data = pc, // so the pre_exec hook can reach the pty
            },
            .pid = 0,
        };

        try pc.cmd.start(self.alloc);
        pc.pid = pc.cmd.pid.?;

        // The parent no longer needs the slave fd (the child has it as its tty).
        posix.close(pty.slave);

        return pc;
    }
};

/// Runs in the forked child before exec: set up the controlling terminal via the
/// pty (`setsid` + `TIOCSCTTY`, then close the master/slave pair). Returns null on
/// success (continue to exec); a non-null exit code aborts the child. POSIX-only —
/// Windows has no fork/pre-exec hook (the ConPTY wires the child's std handles), so
/// the Windows spawn path never installs this; the stub keeps the file compiling.
fn ptyPreExec(cmd: *Command) ?u8 {
    if (is_windows) return null;
    const pc = cmd.getData(PtyChild) orelse return null;
    pc.pty.childPreExec() catch return 1;
    return null;
}

// =============================================================================
// Tests — drive a REAL pty-backed child end-to-end (spawn → input → output →
// exit/tombstone). These need `pty-c` + `os/main.zig`, so they only run inside
// the agent module graph (`zig build test-agent`), not the pure agent_test.zig.
// =============================================================================

const testing = std.testing;

/// A thread-safe sink that captures the pty child's output bytes (it stands in
/// for `Server.onChildOutput` → the session ring). The reader thread calls it.
const CaptureSink = struct {
    mutex: std.Thread.Mutex = .{},
    buf: std.ArrayList(u8) = .empty,
    alloc: Allocator,

    fn sink(ctx: *anyopaque, channel: u128, bytes: []const u8) void {
        _ = channel;
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.buf.appendSlice(self.alloc, bytes) catch {};
    }
    fn contains(self: *CaptureSink, needle: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.indexOf(u8, self.buf.items, needle) != null;
    }
    fn deinit(self: *CaptureSink) void {
        self.buf.deinit(self.alloc);
    }
};

test "PtyChild: real pty spawn → input echoes back → exit/tombstone" {
    const alloc = testing.allocator;

    var spawner = try PtySpawner.init(alloc);
    defer spawner.deinit();

    // Spawn `sh -lic 'cat; exit 7'`-equivalent: a plain interactive shell. We feed
    // a command and observe its echo, then exit.
    const pc = try spawner.spawnChild(.{ .rows = 24, .cols = 80, .command = "cat" });
    var terminated = false;
    defer if (!terminated) pc.child().terminate();

    var capture: CaptureSink = .{ .alloc = alloc };
    defer capture.deinit();

    // Attach the sink (this also starts the reader thread).
    pc.child().attach(&capture, CaptureSink.sink, 0xABCD);

    // Write a line; `cat` echoes it straight back to the pty.
    try pc.child().writeAll("hello-pty-roundtrip\n");

    // Spin until the echoed bytes reach the sink (the reader thread is async).
    var spins: usize = 0;
    while (spins < 20_000) : (spins += 1) {
        if (capture.contains("hello-pty-roundtrip")) break;
        std.Thread.yield() catch {};
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try testing.expect(capture.contains("hello-pty-roundtrip"));

    // Send EOF to `cat` so it exits cleanly (Ctrl-D), then reap.
    try pc.child().writeAll(&.{0x04});
    var reaped: ?i64 = null;
    spins = 0;
    while (spins < 20_000) : (spins += 1) {
        if (pc.child().tryWait()) |code| {
            reaped = code;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try testing.expect(reaped != null);
    try testing.expectEqual(@as(i64, 0), reaped.?); // cat exits 0 on EOF

    // terminate is idempotent + frees the child (and joins the reader).
    pc.child().terminate();
    terminated = true;
}

test "PtyChild: SIGNAL terminates the child via its process group" {
    const alloc = testing.allocator;

    var spawner = try PtySpawner.init(alloc);
    defer spawner.deinit();

    // `sleep 30` so it stays alive until we signal it.
    const pc = try spawner.spawnChild(.{ .rows = 24, .cols = 80, .command = "sleep 30" });
    // Free the child even if an assertion below fails (no leak under the test
    // allocator). terminate() is idempotent with a later explicit call.
    var terminated = false;
    defer if (!terminated) pc.child().terminate();

    var capture: CaptureSink = .{ .alloc = alloc };
    defer capture.deinit();
    pc.child().attach(&capture, CaptureSink.sink, 1);

    // Give the child a beat to complete `setsid` (its pre_exec) so it is the leader
    // of its own process group before we signal the group. We send KILL: it cannot
    // be caught/ignored (an interactive `-i` shell may trap TERM/INT), so it
    // deterministically proves our `signal()` reaches the child's process group.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try pc.child().signal("KILL");

    var reaped: ?i64 = null;
    var spins: usize = 0;
    while (spins < 100_000) : (spins += 1) {
        if (pc.child().tryWait()) |code| {
            reaped = code;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    try testing.expect(reaped != null);
    // Killed by SIGKILL → 128 + SIGKILL(9) = 137 (our shell-convention mapping).
    try testing.expectEqual(@as(i64, 128 + 9), reaped.?);

    pc.child().terminate();
    terminated = true;
}
