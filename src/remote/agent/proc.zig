//! Cross-platform process-table sampler for the remote machine activity monitor
//! (§9.3 process view, increment 3a). A `ProcSampler` enumerates the running
//! processes and computes a per-process CPU% via deltas against its OWN prev-state
//! (a pid-keyed map of cumulative busy-time + wall-clock at the last sample),
//! mirroring the host `metrics.Sampler` design — same delta helper (`metrics.cpuPct`),
//! same prev-state/`have_prev` shape, same per-OS branch on `builtin.os.tag` with
//! OS externs in per-OS blocks compiled only on that OS.
//!
//! ## cpu_pct semantics — PERCENT OF ONE CORE
//! `cpu_pct` is `proc busy-time delta / wall-clock delta * 100`. It is **per-core**:
//! a fully busy single thread reads ~100; a multithreaded process can exceed 100
//! (e.g. 8 busy threads → ~800). This matches `top`'s default %CPU column. The UI
//! (3b) normalizes by `HostMetrics.ncpu` if it wants a Task-Manager-style 0..100
//! total. The first sample for a given pid reads 0 (no prior baseline).
//!
//! ## Ownership
//! `sample()` fills a caller-provided `ArrayListUnmanaged(protocol.Proc)`; the
//! `name`/`user`/`cmd` strings are allocated from the caller's `alloc` and owned by
//! the caller (free after encoding — see `server.handleProcList`). The sampler's own
//! prev-state map is owned by the sampler (freed in `deinit`).
//!
//! Like `metrics.zig`, the live OS reads are validated against the Windows box; the
//! native macOS path additionally backs the in-file `zig test`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");

/// Default cap on the number of processes returned when the request asks for no
/// limit (`limit == 0`). Generous enough for any real machine's foreground set,
/// bounded so a pathological host (thousands of procs) can't balloon a snapshot.
pub const default_limit: u32 = 512;

/// Per-pid CPU baseline: cumulative busy time (in whatever unit the OS reports —
/// ns on macOS, 100ns FILETIME ticks on Windows) and the wall-clock nanoseconds at
/// the moment that busy reading was taken. The next sample diffs both to derive a
/// per-core busy fraction (busy-delta / wall-delta).
const PrevCpu = struct {
    busy: u64,
    wall_ns: i128,
};

pub const ProcSampler = struct {
    alloc: Allocator,
    /// Previous-sample CPU baseline keyed by pid. Entries for pids that vanish are
    /// pruned each `sample()` (a fresh map is swapped in), so the map never grows
    /// without bound across a long-lived connection.
    prev: std.AutoHashMapUnmanaged(i64, PrevCpu) = .empty,
    /// macOS `mach_timebase_info` ratio (ns = ticks * numer / denom), queried once
    /// at construction — it is constant for the life of the machine. 1/1 on every
    /// other OS (and on Intel Macs), where it is an identity. See `machTicksToNs`.
    tb_numer: u32 = 1,
    tb_denom: u32 = 1,

    pub fn init(alloc: Allocator) ProcSampler {
        var self: ProcSampler = .{ .alloc = alloc };
        if (builtin.os.tag == .macos) {
            var info: macos.mach_timebase_info_data_t = .{ .numer = 1, .denom = 1 };
            // KERN_SUCCESS == 0. On the (impossible) failure path we keep 1/1,
            // which is the pre-existing behavior rather than a zero divide.
            if (macos.mach_timebase_info(&info) == 0 and info.numer != 0 and info.denom != 0) {
                self.tb_numer = info.numer;
                self.tb_denom = info.denom;
            }
        }
        return self;
    }

    pub fn deinit(self: *ProcSampler) void {
        self.prev.deinit(self.alloc);
        self.* = undefined;
    }

    /// Enumerate processes now, appending up to `limit` rows to `out` (0 ⇒ use
    /// `default_limit`). `name`/`user`/`cmd` strings are allocated from `alloc` and
    /// owned by the caller. `cpu_pct` is 0 for a pid not seen on the previous call.
    /// Returns `true` if more processes existed than were returned (truncated).
    ///
    /// On a partial OS failure the sampler is robust: a process that denies access
    /// (a system pid on Windows, a vanished pid on macOS) is included with
    /// name/pid/ppid and cpu/mem 0 rather than aborting the whole enumeration.
    pub fn sample(
        self: *ProcSampler,
        alloc: Allocator,
        out: *std.ArrayListUnmanaged(protocol.Proc),
        limit: u32,
    ) !bool {
        const cap: u32 = if (limit == 0) default_limit else limit;
        return switch (builtin.os.tag) {
            .macos => self.sampleMacos(alloc, out, cap),
            .windows => self.sampleWindows(alloc, out, cap),
            .linux => self.sampleLinux(alloc, out, cap),
            else => false,
        };
    }

    /// Fold a fresh cumulative `busy` reading for `pid` (taken at wall-clock `now`,
    /// `busy` already in ns) into a per-core CPU%, and record the new baseline in
    /// `next` (the map being built for THIS sample, which becomes `self.prev` after
    /// the swap). Returns 0 when the pid had no prior baseline. Shared by every OS
    /// path. `metrics.cpuPct` (the host sampler's delta helper) clamps to a single
    /// core's 0..100; per-process we want the uncapped multithreaded reading, so we
    /// use `perCorePct` — the same busy/wall delta shape, just without the 1-core cap.
    fn cpuForPid(
        self: *ProcSampler,
        next: *std.AutoHashMapUnmanaged(i64, PrevCpu),
        pid: i64,
        busy: u64,
        now: i128,
    ) f32 {
        var pct: f32 = 0;
        if (self.prev.get(pid)) |p| {
            const d_wall: u64 = if (now > p.wall_ns) @intCast(now - p.wall_ns) else 0;
            pct = perCorePct(p.busy, busy, d_wall);
        }
        next.put(self.alloc, pid, .{ .busy = busy, .wall_ns = now }) catch {};
        return pct;
    }

    // --- macOS ---------------------------------------------------------------

    fn sampleMacos(
        self: *ProcSampler,
        alloc: Allocator,
        out: *std.ArrayListUnmanaged(protocol.Proc),
        cap: u32,
    ) !bool {
        if (builtin.os.tag != .macos) return false;
        const c = macos;

        // Enumerate pids via libproc `proc_listpids(PROC_ALL_PIDS)`. This avoids the
        // fragile hand-rolled `kinfo_proc` ABI: we get a flat i32[] of pids, then
        // query each with stable, documented libproc flavors (PROC_PIDTBSDINFO for
        // pid/ppid/name/uid, PROC_PIDTASKINFO for cpu/mem). Two-step sizing: ask for
        // the byte count (buffer == null), allocate, fetch.
        const needed = c.proc_listpids(c.PROC_ALL_PIDS, 0, null, 0);
        if (needed <= 0) return false;
        // Pad for procs that appear between the sizing and the fetch.
        const cap_bytes: usize = @as(usize, @intCast(needed)) + @sizeOf(i32) * 32;
        const pid_buf = alloc.alloc(u8, cap_bytes) catch return false;
        defer alloc.free(pid_buf);
        const wrote = c.proc_listpids(c.PROC_ALL_PIDS, 0, pid_buf.ptr, @intCast(pid_buf.len));
        if (wrote <= 0) return false;
        const npids: usize = @as(usize, @intCast(wrote)) / @sizeOf(i32);
        const pids: [*]const i32 = @ptrCast(@alignCast(pid_buf.ptr));

        var next: std.AutoHashMapUnmanaged(i64, PrevCpu) = .empty;
        errdefer next.deinit(self.alloc);

        const now = std.time.nanoTimestamp();
        var truncated = false;
        var i: usize = 0;
        while (i < npids) : (i += 1) {
            const pid32 = pids[i];
            if (pid32 <= 0) continue;
            const pid: i64 = pid32;
            if (out.items.len >= cap) {
                truncated = true;
                break;
            }

            // pid/ppid/name/uid via PROC_PIDTBSDINFO (a stable libproc struct). A
            // protected/vanished pid returns < sizeof → skip it (don't fail the whole
            // enumeration).
            var bsd: c.proc_bsdinfo = undefined;
            const bsd_sz: c_int = @sizeOf(c.proc_bsdinfo);
            if (c.proc_pidinfo(pid32, c.PROC_PIDTBSDINFO, 0, &bsd, bsd_sz) != bsd_sz) continue;
            const ppid: i64 = bsd.pbi_ppid;

            const name_z = std.mem.sliceTo(&bsd.pbi_comm, 0);
            const name = alloc.dupe(u8, name_z) catch continue;

            // cpu busy + mem: PROC_PIDTASKINFO. resident_size → mem;
            // total_user+total_system → busy, converted from MACH ABSOLUTE TIME
            // UNITS to ns (they are NOT nanoseconds — see `machTicksToNs`) so
            // `busy` shares the ns unit `cpuForPid`/`perCorePct` require, matching
            // the Windows (100ns ticks) and Linux (jiffies) paths.
            // Best-effort (0s on failure).
            var mem_bytes: u64 = 0;
            var busy_ns: u64 = 0;
            var ti: c.proc_taskinfo = undefined;
            const ti_sz: c_int = @sizeOf(c.proc_taskinfo);
            if (c.proc_pidinfo(pid32, c.PROC_PIDTASKINFO, 0, &ti, ti_sz) == ti_sz) {
                mem_bytes = ti.pti_resident_size;
                const busy_ticks = ti.pti_total_user +% ti.pti_total_system;
                busy_ns = machTicksToNs(busy_ticks, self.tb_numer, self.tb_denom);
            }

            // cmd: full executable image path via libproc `proc_pidpath`. One extra
            // syscall per pid; best-effort (null on a vanished/protected pid). The UI
            // shows this as the "Path" column. `user` stays null (UI drops it).
            const cmd: ?[]const u8 = blk: {
                var path_buf: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
                const n = c.proc_pidpath(pid32, &path_buf, path_buf.len);
                if (n <= 0) break :blk null;
                break :blk alloc.dupe(u8, path_buf[0..@intCast(n)]) catch null;
            };

            // Controlling terminal name (e.g. "ttys004") from the `e_tdev` we
            // already read above — no extra syscall. `NODEV` (all bits set) means
            // no controlling terminal: a daemon, or a child that called setsid.
            const tty: ?[]const u8 = blk: {
                if (bsd.e_tdev == std.math.maxInt(u32)) break :blk null;
                var tbuf: [64]u8 = undefined;
                const r = c.devname_r(@bitCast(bsd.e_tdev), c.S_IFCHR, &tbuf, tbuf.len);
                if (r == null) break :blk null;
                const n = std.mem.sliceTo(&tbuf, 0);
                if (n.len == 0) break :blk null;
                break :blk alloc.dupe(u8, n) catch null;
            };

            const cpu_pct = self.cpuForPid(&next, pid, busy_ns, now);

            out.append(alloc, .{
                .pid = pid,
                .ppid = ppid,
                .name = name,
                .cpu_pct = cpu_pct,
                .mem_bytes = mem_bytes,
                .user = null,
                .cmd = cmd,
                .tty = tty,
            }) catch {
                alloc.free(name);
                if (cmd) |x| alloc.free(x);
                if (tty) |x| alloc.free(x);
                break;
            };
        }

        self.prev.deinit(self.alloc);
        self.prev = next;
        return truncated;
    }

    // --- Windows -------------------------------------------------------------

    fn sampleWindows(
        self: *ProcSampler,
        alloc: Allocator,
        out: *std.ArrayListUnmanaged(protocol.Proc),
        cap: u32,
    ) !bool {
        if (builtin.os.tag != .windows) return false;
        const w = windows;
        const W = std.os.windows;

        const snap = w.CreateToolhelp32Snapshot(w.TH32CS_SNAPPROCESS, 0);
        if (snap == W.INVALID_HANDLE_VALUE) return false;
        defer W.CloseHandle(snap);

        var next: std.AutoHashMapUnmanaged(i64, PrevCpu) = .empty;
        errdefer next.deinit(self.alloc);

        var entry: w.PROCESSENTRY32W = .{ .dwSize = @sizeOf(w.PROCESSENTRY32W) };
        var truncated = false;
        var ok = w.Process32FirstW(snap, &entry) != 0;
        while (ok) : (ok = w.Process32NextW(snap, &entry) != 0) {
            const pid: i64 = @intCast(entry.th32ProcessID);
            if (pid < 0) continue;
            if (out.items.len >= cap) {
                truncated = true;
                break;
            }
            const ppid: i64 = @intCast(entry.th32ParentProcessID);

            // name: szExeFile is a fixed [260]u16 NUL-terminated UTF-16 string.
            const name_w = std.mem.sliceTo(&entry.szExeFile, 0);
            const name = std.unicode.utf16LeToUtf8Alloc(alloc, name_w) catch continue;

            // cpu busy + mem via a per-process handle. PROCESS_QUERY_LIMITED_INFORMATION
            // is the least-privileged right that still answers GetProcessTimes /
            // GetProcessMemoryInfo for processes the agent's token can see; system
            // pids (0/4) deny it → include the row with 0s rather than failing.
            var busy_100ns: u64 = 0;
            var mem_bytes: u64 = 0;
            // cmd: full executable image path. Reuses the SAME handle we open for
            // cpu/mem; null on access-denied / system pids (per brief, don't fail the
            // row). The UI shows this as the "Path" column. `user` stays null.
            var cmd: ?[]const u8 = null;
            const h = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID);
            if (h != null) {
                defer W.CloseHandle(h.?);
                var creation: W.FILETIME = undefined;
                var exit_ft: W.FILETIME = undefined;
                var kernel: W.FILETIME = undefined;
                var user_ft: W.FILETIME = undefined;
                if (w.GetProcessTimes(h.?, &creation, &exit_ft, &kernel, &user_ft) != 0) {
                    busy_100ns = filetimeToU64(kernel) +% filetimeToU64(user_ft);
                }
                var pmc: w.PROCESS_MEMORY_COUNTERS = .{ .cb = @sizeOf(w.PROCESS_MEMORY_COUNTERS) };
                if (w.K32GetProcessMemoryInfo(h.?, &pmc, pmc.cb) != 0) {
                    mem_bytes = pmc.WorkingSetSize;
                }
                // QueryFullProcessImageNameW(h, 0, buf, &len): the Win32-friendly full
                // path (flags 0 ⇒ DOS path, not the \Device\ NT path). `len` is in/out
                // WCHARs (set to capacity going in, receives the written length).
                var path_w: [w.image_path_max]W.WCHAR = undefined;
                var path_len: W.DWORD = @intCast(path_w.len);
                if (w.QueryFullProcessImageNameW(h.?, 0, &path_w, &path_len) != 0 and path_len > 0) {
                    cmd = std.unicode.utf16LeToUtf8Alloc(alloc, path_w[0..@intCast(path_len)]) catch null;
                }
            }

            // Convert 100ns FILETIME ticks → ns so busy and wall share the ns unit
            // the delta math expects (1 tick = 100ns).
            const busy_ns: u64 = busy_100ns *% 100;
            const now = std.time.nanoTimestamp();
            const cpu_pct = self.cpuForPid(&next, pid, busy_ns, now);

            out.append(alloc, .{
                .pid = pid,
                .ppid = ppid,
                .name = name,
                .cpu_pct = cpu_pct,
                .mem_bytes = mem_bytes,
                .user = null, // token lookup is fiddly; left null for v1 (per brief)
                .cmd = cmd,
                // Windows has no controlling-terminal concept, so pane attribution
                // has no tty to key on here. Explicitly null (not "unimplemented").
                .tty = null,
            }) catch {
                alloc.free(name);
                if (cmd) |x| alloc.free(x);
                break;
            };
        }

        self.prev.deinit(self.alloc);
        self.prev = next;
        return truncated;
    }

    // --- Linux ---------------------------------------------------------------

    fn sampleLinux(
        self: *ProcSampler,
        alloc: Allocator,
        out: *std.ArrayListUnmanaged(protocol.Proc),
        cap: u32,
    ) !bool {
        if (builtin.os.tag != .linux) return false;

        var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return false;
        defer dir.close();

        var next: std.AutoHashMapUnmanaged(i64, PrevCpu) = .empty;
        errdefer next.deinit(self.alloc);

        const clk_tck: u64 = 100; // USER_HZ; ~always 100 on Linux. busy is in jiffies.
        const now = std.time.nanoTimestamp();
        var truncated = false;

        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (ent.kind != .directory) continue;
            const pid = std.fmt.parseInt(i64, ent.name, 10) catch continue;
            if (out.items.len >= cap) {
                truncated = true;
                break;
            }

            var path_buf: [64]u8 = undefined;
            const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{s}/stat", .{ent.name}) catch continue;
            var sbuf: [4096]u8 = undefined;
            const f = std.fs.cwd().openFile(stat_path, .{}) catch continue;
            const slen = f.readAll(&sbuf) catch {
                f.close();
                continue;
            };
            f.close();
            const parsed = parseLinuxStat(sbuf[0..slen]) orelse continue;

            const name = alloc.dupe(u8, parsed.comm) catch continue;

            // busy (utime+stime in jiffies) → ns. mem: RSS pages * page_size (from
            // /proc/<pid>/statm field 2).
            const busy_ns: u64 = (parsed.utime +% parsed.stime) *% (std.time.ns_per_s / clk_tck);
            const mem_bytes = readLinuxRss(ent.name) *% std.heap.pageSize();

            // cmd: full executable path via readlink("/proc/<pid>/exe"). Best-effort
            // (null for kernel threads / permission-denied). The UI "Path" column.
            const cmd: ?[]const u8 = readLinuxExe(alloc, ent.name);

            // Controlling terminal (e.g. "pts/4") from the tty_nr we already
            // parsed — no extra file read. Null for a process with no ctty.
            const tty: ?[]const u8 = blk: {
                var tty_buf: [32]u8 = undefined;
                const n = linuxTtyName(&tty_buf, parsed.tty_nr) orelse break :blk null;
                break :blk alloc.dupe(u8, n) catch null;
            };

            const cpu_pct = self.cpuForPid(&next, pid, busy_ns, now);
            out.append(alloc, .{
                .pid = pid,
                .ppid = parsed.ppid,
                .name = name,
                .cpu_pct = cpu_pct,
                .mem_bytes = mem_bytes,
                .user = null,
                .cmd = cmd,
                .tty = tty,
            }) catch {
                alloc.free(name);
                if (cmd) |x| alloc.free(x);
                if (tty) |x| alloc.free(x);
                break;
            };
        }

        self.prev.deinit(self.alloc);
        self.prev = next;
        return truncated;
    }
};

/// Sum `cpu_pct` over `root` and every transitive descendant of it in `procs`.
///
/// Used for the per-session CPU roll-up: a session is busy because the agent
/// running inside it is busy, not because its shell is, so the number the chooser
/// wants covers the whole tree hanging off the session's child pid.
///
/// Walks a ppid→children adjacency map built once per call by the caller (see
/// `childMap`), so rolling up N sessions over one snapshot stays linear rather
/// than rescanning the table per session. Robust to cycles (a visited set — a
/// corrupt/racy ppid must not hang the pump) and to a root that isn't present
/// (returns 0).
fn subtreeCpu(
    children: *const std.AutoHashMapUnmanaged(i64, std.ArrayListUnmanaged(i64)),
    cpu_by_pid: *const std.AutoHashMapUnmanaged(i64, f32),
    root: i64,
    scratch: *std.ArrayListUnmanaged(i64),
    seen: *std.AutoHashMapUnmanaged(i64, void),
    alloc: Allocator,
) f32 {
    scratch.clearRetainingCapacity();
    seen.clearRetainingCapacity();
    if (cpu_by_pid.get(root) == null) return 0;
    scratch.append(alloc, root) catch return 0;
    seen.put(alloc, root, {}) catch return 0;

    var total: f32 = 0;
    while (scratch.pop()) |pid| {
        total += cpu_by_pid.get(pid) orelse 0;
        const kids = children.get(pid) orelse continue;
        for (kids.items) |kid| {
            if (seen.contains(kid)) continue;
            seen.put(alloc, kid, {}) catch continue;
            scratch.append(alloc, kid) catch continue;
        }
    }
    return total;
}

/// Per-session CPU totals for `roots`, computed over one process snapshot.
///
/// `out` is filled in the same order as `roots` (0 for a root that isn't in the
/// snapshot — an exited session, or one clipped by the row cap). Caller owns
/// `out`, which must already have `roots.len` capacity.
pub fn rollUpByRoot(
    alloc: Allocator,
    procs: []const protocol.Proc,
    roots: []const i64,
    out: []f32,
) void {
    @memset(out, 0);
    if (roots.len == 0 or procs.len == 0) return;

    var children: std.AutoHashMapUnmanaged(i64, std.ArrayListUnmanaged(i64)) = .empty;
    var cpu_by_pid: std.AutoHashMapUnmanaged(i64, f32) = .empty;
    defer {
        var it = children.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        children.deinit(alloc);
        cpu_by_pid.deinit(alloc);
    }

    for (procs) |p| {
        cpu_by_pid.put(alloc, p.pid, p.cpu_pct) catch continue;
        const gop = children.getOrPut(alloc, p.ppid) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(alloc, p.pid) catch {};
    }

    var scratch: std.ArrayListUnmanaged(i64) = .empty;
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer {
        scratch.deinit(alloc);
        seen.deinit(alloc);
    }

    for (roots, 0..) |root, i| {
        out[i] = subtreeCpu(&children, &cpu_by_pid, root, &scratch, &seen, alloc);
    }
}

/// Convert a mach-absolute-time tick count to nanoseconds given a
/// `mach_timebase_info` ratio (`ns = ticks * numer / denom`).
///
/// macOS reports `pti_total_user`/`pti_total_system` in MACH ABSOLUTE TIME UNITS,
/// **not** nanoseconds, despite the widespread assumption otherwise. On Intel the
/// timebase is 1/1 so the two are indistinguishable — which is exactly why reading
/// them as ns went unnoticed. On Apple Silicon the timebase is 125/3 (a 24 MHz
/// counter, ≈41.67 ns per tick), so treating ticks as ns undercounts CPU by ~24x:
/// a fully-pinned core measures ~4% instead of ~100%.
///
/// The multiply is widened to u128 because a long-lived process's cumulative tick
/// count times `numer` can exceed u64.
fn machTicksToNs(ticks: u64, numer: u32, denom: u32) u64 {
    if (numer == denom or denom == 0) return ticks; // 1:1 (Intel) — exact, no math
    const wide = (@as(u128, ticks) * @as(u128, numer)) / @as(u128, denom);
    return std.math.cast(u64, wide) orelse std.math.maxInt(u64);
}

/// Per-core busy fraction (0..) as a percent: busy-delta / wall-delta * 100, where
/// both deltas are in the SAME unit (ns). NOT clamped to 100 — a multithreaded proc
/// legitimately exceeds 100. Returns 0 with no wall advance or a non-monotonic busy
/// read (a recycled pid).
fn perCorePct(prev_busy: u64, busy: u64, d_wall_ns: u64) f32 {
    if (d_wall_ns == 0) return 0;
    if (busy < prev_busy) return 0; // pid reused / non-monotonic; no spike
    const d_busy = busy - prev_busy;
    const frac = @as(f64, @floatFromInt(d_busy)) / @as(f64, @floatFromInt(d_wall_ns));
    const pct = frac * 100.0;
    // Cap at a sane ceiling so a glitch can't report an absurd value, but allow
    // well above 100 for genuinely multithreaded processes.
    return @floatCast(@min(pct, 100.0 * 1024.0));
}

// =============================================================================
// macOS — libproc externs (compiled only on macOS)
// =============================================================================
//
// We enumerate via `proc_listpids` (a flat pid array) then query each pid with the
// stable, documented libproc flavors — avoiding the fragile hand-rolled
// `kinfo_proc` ABI. `proc_bsdinfo` (PROC_PIDTBSDINFO) gives pid/ppid/comm/uid;
// `proc_taskinfo` (PROC_PIDTASKINFO) gives cpu/mem. Both are stable across releases.

const macos = struct {
    const PROC_ALL_PIDS: u32 = 1;
    const PROC_PIDTBSDINFO: c_int = 3;
    const PROC_PIDTASKINFO: c_int = 4;

    const MAXCOMLEN = 16;
    const uid_t = u32;
    const gid_t = u32;

    // proc_pidpath() max path length (sys/proc_info.h: PROC_PIDPATHINFO_MAXSIZE =
    // 4 * MAXPATHLEN = 4 * 1024). The full executable image path fits within this.
    const PROC_PIDPATHINFO_MAXSIZE = 4 * 1024;

    // struct proc_bsdinfo (sys/proc_info.h, PROC_PIDTBSDINFO flavor). We read
    // pbi_ppid / pbi_comm / pbi_uid. pbi_comm is the (truncated) accounting name;
    // pbi_name is the longer 2*MAXCOMLEN name — we use pbi_comm to match `top`/`ps`.
    const proc_bsdinfo = extern struct {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: uid_t,
        pbi_gid: gid_t,
        pbi_ruid: uid_t,
        pbi_rgid: gid_t,
        pbi_svuid: uid_t,
        pbi_svgid: gid_t,
        rfu_1: u32,
        pbi_comm: [MAXCOMLEN]u8,
        pbi_name: [2 * MAXCOMLEN]u8,
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    };

    // proc_taskinfo (libproc.h): the PROC_PIDTASKINFO flavor. We read resident_size
    // (RSS) + total_user/total_system (cumulative CPU time in ns).
    const proc_taskinfo = extern struct {
        pti_virtual_size: u64,
        pti_resident_size: u64,
        pti_total_user: u64,
        pti_total_system: u64,
        pti_threads_user: u64,
        pti_threads_system: u64,
        pti_policy: i32,
        pti_faults: i32,
        pti_pageins: i32,
        pti_cow_faults: i32,
        pti_messages_sent: i32,
        pti_messages_received: i32,
        pti_syscalls_mach: i32,
        pti_syscalls_unix: i32,
        pti_csw: i32,
        pti_threadnum: i32,
        pti_numrunning: i32,
        pti_priority: i32,
    };

    // passwd (pwd.h) — only pw_name is read.
    const passwd = extern struct {
        pw_name: [*:0]u8,
        pw_passwd: [*:0]u8,
        pw_uid: uid_t,
        pw_gid: gid_t,
        pw_change: c_long,
        pw_class: [*:0]u8,
        pw_gecos: [*:0]u8,
        pw_dir: [*:0]u8,
        pw_shell: [*:0]u8,
        pw_expire: c_long,
    };

    // mach_timebase_info (mach/mach_time.h): the rational ratio converting mach
    // absolute time units to nanoseconds. Constant per machine; 1/1 on Intel,
    // 125/3 on Apple Silicon's 24MHz counter.
    const mach_timebase_info_data_t = extern struct {
        numer: u32,
        denom: u32,
    };
    extern "c" fn mach_timebase_info(info: *mach_timebase_info_data_t) c_int;

    extern "c" fn proc_listpids(
        type: u32,
        typeinfo: u32,
        buffer: ?*anyopaque,
        buffersize: c_int,
    ) c_int;
    extern "c" fn proc_pidinfo(
        pid: c_int,
        flavor: c_int,
        arg: u64,
        buffer: ?*anyopaque,
        buffersize: c_int,
    ) c_int;
    extern "c" fn getpwuid(uid: uid_t) ?*passwd;
    // devname_r(dev, type, buf, len): the device NAME for a dev_t (e.g. "ttys004"),
    // written into the caller's buffer — the `_r` form because `devname` returns a
    // shared static buffer and the sampler may run off the main thread. Returns
    // null when the dev has no name (notably `NODEV`, i.e. no controlling tty).
    // macOS `dev_t` is int32_t and `mode_t` is uint16_t.
    const dev_t = i32;
    const mode_t = u16;
    const S_IFCHR: mode_t = 0o020000;
    extern "c" fn devname_r(dev: dev_t, mode: mode_t, buf: [*]u8, len: c_int) ?[*:0]u8;
    // proc_pidpath(pid, buffer, buffersize): fills `buffer` with the process's full
    // executable image path, returns the byte length (0 / -1 on failure). Stable
    // libproc API (sys/proc_info.h).
    extern "c" fn proc_pidpath(pid: c_int, buffer: *anyopaque, buffersize: u32) c_int;
};

// =============================================================================
// Windows — toolhelp / process query externs not in std.os.windows
// =============================================================================

const windows = struct {
    const W = std.os.windows;
    const BOOL = W.BOOL;
    const DWORD = W.DWORD;
    const HANDLE = W.HANDLE;
    const FILETIME = W.FILETIME;
    const WCHAR = W.WCHAR;

    const TH32CS_SNAPPROCESS: DWORD = 0x00000002;
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

    const MAX_PATH = 260;
    // Buffer size (in WCHARs) for QueryFullProcessImageNameW. Generous enough for an
    // extended-length image path without going to the full 32767 \\?\ maximum.
    const image_path_max = 1024;

    const PROCESSENTRY32W = extern struct {
        dwSize: DWORD,
        cntUsage: DWORD = 0,
        th32ProcessID: DWORD = 0,
        th32DefaultHeapID: usize = 0,
        th32ModuleID: DWORD = 0,
        cntThreads: DWORD = 0,
        th32ParentProcessID: DWORD = 0,
        pcPriClassBase: W.LONG = 0,
        dwFlags: DWORD = 0,
        szExeFile: [MAX_PATH]WCHAR = undefined,
    };

    // PROCESS_MEMORY_COUNTERS (psapi.h). We read WorkingSetSize.
    const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: DWORD,
        PageFaultCount: DWORD = 0,
        PeakWorkingSetSize: usize = 0,
        WorkingSetSize: usize = 0,
        QuotaPeakPagedPoolUsage: usize = 0,
        QuotaPagedPoolUsage: usize = 0,
        QuotaPeakNonPagedPoolUsage: usize = 0,
        QuotaNonPagedPoolUsage: usize = 0,
        PagefileUsage: usize = 0,
        PeakPagefileUsage: usize = 0,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetProcessTimes(
        hProcess: HANDLE,
        lpCreationTime: *FILETIME,
        lpExitTime: *FILETIME,
        lpKernelTime: *FILETIME,
        lpUserTime: *FILETIME,
    ) callconv(.winapi) BOOL;
    // K32GetProcessMemoryInfo is the kernel32 alias of psapi!GetProcessMemoryInfo
    // (available since Windows 7); linking it avoids a separate psapi import lib.
    extern "kernel32" fn K32GetProcessMemoryInfo(
        Process: HANDLE,
        ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
        cb: DWORD,
    ) callconv(.winapi) BOOL;
    // QueryFullProcessImageNameW(h, flags, buf, &len): full image path of a process.
    // flags 0 ⇒ Win32 DOS path (e.g. C:\Windows\...); 1 ⇒ native \Device\ path. `len`
    // is the buffer capacity in WCHARs on input and the written length on output.
    extern "kernel32" fn QueryFullProcessImageNameW(
        hProcess: HANDLE,
        dwFlags: DWORD,
        lpExeName: [*]WCHAR,
        lpdwSize: *DWORD,
    ) callconv(.winapi) BOOL;
};

/// Pack a Windows FILETIME (two DWORDs) into a u64 of 100ns ticks.
fn filetimeToU64(ft: std.os.windows.FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

// =============================================================================
// Linux parsing helpers (pure; usable on any OS for unit testing)
// =============================================================================

const LinuxStat = struct {
    ppid: i64,
    comm: []const u8, // borrows the input buffer
    utime: u64,
    stime: u64,
    /// Raw `tty_nr` (field 7). 0 ⇒ no controlling terminal.
    tty_nr: i64,
};

/// Parse the fields we need out of /proc/<pid>/stat. The format is:
///   pid (comm) state ppid pgrp session tty_nr(7) ... utime(14) stime(15) ...
/// `comm` can contain spaces/parens, so we anchor on the LAST ')' and split the
/// remainder by spaces. Returns null on a malformed line.
fn parseLinuxStat(text: []const u8) ?LinuxStat {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    if (open + 1 > close) return null;
    const comm = text[open + 1 .. close];

    // After ')' the remaining fields are space-separated starting at "state".
    // Indices (0-based on the post-comm tokens):
    //   0=state 1=ppid 2=pgrp 3=session 4=tty_nr ... 11=utime 12=stime
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var idx: usize = 0;
    var ppid: i64 = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var tty_nr: i64 = 0;
    while (it.next()) |tok| : (idx += 1) {
        switch (idx) {
            1 => ppid = std.fmt.parseInt(i64, tok, 10) catch 0,
            4 => tty_nr = std.fmt.parseInt(i64, tok, 10) catch 0,
            11 => utime = std.fmt.parseInt(u64, tok, 10) catch 0,
            12 => {
                stime = std.fmt.parseInt(u64, tok, 10) catch 0;
                break; // we have everything we need
            },
            else => {},
        }
    }
    return .{ .ppid = ppid, .comm = comm, .utime = utime, .stime = stime, .tty_nr = tty_nr };
}

/// Render a Linux `tty_nr` as a device name without the `/dev/` prefix, matching
/// the macOS path's convention. Returns null when there is no controlling
/// terminal (`tty_nr == 0`) or the device isn't a UNIX98 pty.
///
/// `tty_nr` packs major/minor: major = bits 8..19, minor = low 8 bits OR'd with
/// bits 20..31. Majors 136..143 are UNIX98 pty slaves (`/dev/pts/N`), which is
/// what an agent's sessions always run on; anything else (a legacy `/dev/ttyN`
/// console) is reported as null rather than guessed at, since only pts names
/// can be matched against a pane.
fn linuxTtyName(buf: []u8, tty_nr: i64) ?[]const u8 {
    if (tty_nr <= 0) return null;
    const n: u32 = @intCast(tty_nr);
    const major = (n >> 8) & 0xfff;
    const minor = (n & 0xff) | ((n >> 12) & 0xfff00);
    if (major < 136 or major > 143) return null;
    // UNIX98 pty minors are numbered per-major from 136.
    const index = (major - 136) * 256 + minor;
    return std.fmt.bufPrint(buf, "pts/{d}", .{index}) catch null;
}

/// Read RSS (resident pages) from /proc/<pid>/statm (field 2). 0 on any failure.
fn readLinuxRss(pid_name: []const u8) u64 {
    if (builtin.os.tag != .linux) return 0;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{s}/statm", .{pid_name}) catch return 0;
    var buf: [256]u8 = undefined;
    const f = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    const n = f.readAll(&buf) catch return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next() orelse return 0; // total program size
    const rss = it.next() orelse return 0; // resident set size (pages)
    return std.fmt.parseInt(u64, std.mem.trim(u8, rss, " \n"), 10) catch 0;
}

/// Read the full executable path via readlink("/proc/<pid>/exe"). Returns an
/// allocator-owned copy, or null on failure (kernel threads have no exe link, and
/// other-user processes deny it). Best-effort — never fails the row.
fn readLinuxExe(alloc: Allocator, pid_name: []const u8) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    var path_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&path_buf, "/proc/{s}/exe", .{pid_name}) catch return null;
    var target_buf: [4096]u8 = undefined;
    const target = std.fs.cwd().readLink(link, &target_buf) catch return null;
    if (target.len == 0) return null;
    return alloc.dupe(u8, target) catch null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "perCorePct: per-core busy fraction" {
    // 50ms busy over 100ms wall → 50% of one core.
    try testing.expectEqual(@as(f32, 50.0), perCorePct(0, 50 * std.time.ns_per_ms, 100 * std.time.ns_per_ms));
    // Fully busy one core.
    try testing.expectEqual(@as(f32, 100.0), perCorePct(0, 100 * std.time.ns_per_ms, 100 * std.time.ns_per_ms));
    // Multithreaded: 200ms busy over 100ms wall → 200% (can exceed 100).
    try testing.expectEqual(@as(f32, 200.0), perCorePct(0, 200 * std.time.ns_per_ms, 100 * std.time.ns_per_ms));
    // No wall advance → 0 (no div-by-zero / spike).
    try testing.expectEqual(@as(f32, 0.0), perCorePct(0, 1000, 0));
    // Non-monotonic busy (recycled pid) → 0, never negative.
    try testing.expectEqual(@as(f32, 0.0), perCorePct(1000, 500, 100 * std.time.ns_per_ms));
}

test "rollUpByRoot: sums a session's whole process tree" {
    const alloc = testing.allocator;
    // A pane's shell (100) with claude (200) under it, claude's node worker (300),
    // and a setsid'd Bash-tool grandchild (400 → 500). Plus an unrelated tree (900)
    // that must NOT leak into the total.
    const procs = [_]protocol.Proc{
        .{ .pid = 100, .ppid = 1, .name = "zsh", .cpu_pct = 1 },
        .{ .pid = 200, .ppid = 100, .name = "claude", .cpu_pct = 10 },
        .{ .pid = 300, .ppid = 200, .name = "node", .cpu_pct = 100 },
        .{ .pid = 400, .ppid = 200, .name = "bash", .cpu_pct = 2 },
        .{ .pid = 500, .ppid = 400, .name = "jq", .cpu_pct = 50 },
        .{ .pid = 900, .ppid = 1, .name = "other", .cpu_pct = 77 },
    };
    var out: [3]f32 = undefined;
    // Root 100 = the whole session; root 200 = just claude's side; root 12345 is
    // absent from the snapshot (an exited session) and must read 0, not garbage.
    rollUpByRoot(alloc, &procs, &.{ 100, 200, 12345 }, &out);
    try testing.expectEqual(@as(f32, 163), out[0]); // 1+10+100+2+50
    try testing.expectEqual(@as(f32, 162), out[1]); // 10+100+2+50
    try testing.expectEqual(@as(f32, 0), out[2]);
}

test "rollUpByRoot: a ppid cycle terminates instead of hanging the pump" {
    const alloc = testing.allocator;
    // 100 → 200 → 300 → 100. A corrupt or racy ppid read must not spin forever;
    // each pid is counted exactly once.
    const procs = [_]protocol.Proc{
        .{ .pid = 100, .ppid = 300, .name = "a", .cpu_pct = 1 },
        .{ .pid = 200, .ppid = 100, .name = "b", .cpu_pct = 2 },
        .{ .pid = 300, .ppid = 200, .name = "c", .cpu_pct = 4 },
    };
    var out: [1]f32 = undefined;
    rollUpByRoot(alloc, &procs, &.{100}, &out);
    try testing.expectEqual(@as(f32, 7), out[0]);
}

test "machTicksToNs: converts mach absolute time units to nanoseconds" {
    // Intel / already-ns timebase (1:1) — identity, and must not lose precision.
    try testing.expectEqual(@as(u64, 12_345), machTicksToNs(12_345, 1, 1));

    // Apple Silicon 24MHz timebase: numer=125 denom=3 ⇒ 41.666… ns per tick.
    // 24_000_000 ticks is one second of a fully-busy core ⇒ 1e9 ns.
    try testing.expectEqual(@as(u64, std.time.ns_per_s), machTicksToNs(24_000_000, 125, 3));

    // The intermediate must be widened: a cumulative tick count near u64 max
    // would overflow a u64 multiply by `numer` before the divide.
    const huge: u64 = std.math.maxInt(u64) / 2;
    try testing.expect(machTicksToNs(huge, 125, 3) > huge);
}

test "ProcSampler: a genuinely busy thread reports a plausible per-core cpu_pct" {
    // Guards the UNIT of the macOS busy reading, which is what made every row
    // read ~0. `pti_total_user`/`pti_total_system` are mach absolute time units,
    // not nanoseconds; reading them as ns undercounts by the timebase ratio
    // (~24x on Apple Silicon), so a fully-pinned core reports ~4 instead of ~100.
    //
    // We spin ONE thread (this one) for the whole sample window, so our own pid
    // must read near 100% of one core. The 50 floor is far below the correct
    // ~100 and far above the ~4 a unit bug produces, so the test is decisive
    // without being timing-flaky.
    if (builtin.os.tag != .macos and builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var s = ProcSampler.init(alloc);
    defer s.deinit();

    const my_pid: i64 = @intCast(switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => std.c.getpid(),
    });

    // Baseline sample (every pid reads 0 — no prior baseline).
    var out1: std.ArrayListUnmanaged(protocol.Proc) = .empty;
    defer {
        for (out1.items) |p| freeProc(alloc, p);
        out1.deinit(alloc);
    }
    _ = try s.sample(alloc, &out1, 0);

    // Burn one core for the sample window. `volatile` so the spin can't be
    // optimized away into a no-op (which would make the test vacuously pass a
    // buggy build by reporting ~0 for a genuinely idle process).
    var sink: u64 = 0;
    const spin_ns = 400 * std.time.ns_per_ms;
    const start = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - start < spin_ns) {
        var i: u32 = 0;
        while (i < 20_000) : (i += 1) {
            const p: *volatile u64 = &sink;
            p.* = p.* +% i;
        }
    }

    var out2: std.ArrayListUnmanaged(protocol.Proc) = .empty;
    defer {
        for (out2.items) |p| freeProc(alloc, p);
        out2.deinit(alloc);
    }
    _ = try s.sample(alloc, &out2, 0);

    var mine: ?f32 = null;
    for (out2.items) |p| {
        if (p.pid == my_pid) mine = p.cpu_pct;
    }
    try testing.expect(mine != null);
    try testing.expect(mine.? >= 50.0);
}

test "parseLinuxStat: extracts ppid/comm/utime/stime/tty_nr, comm with spaces+parens" {
    // Post-comm tokens: state ppid pgrp session tty_nr tpgid ... utime stime
    //                     S   1000 1234  1234    0     -1    ...  50    70
    const line = "1234 (my (weird) proc) S 1000 1234 1234 0 -1 4194560 200 0 0 0 50 70 0 0 20 0 1 0 1\n";
    const p = parseLinuxStat(line).?;
    try testing.expectEqual(@as(i64, 1000), p.ppid);
    try testing.expectEqualStrings("my (weird) proc", p.comm);
    try testing.expectEqual(@as(u64, 50), p.utime);
    try testing.expectEqual(@as(u64, 70), p.stime);
    try testing.expectEqual(@as(i64, 0), p.tty_nr); // this proc has no ctty

    // Same line with a real pts tty_nr (major 136, minor 4 ⇒ 136<<8 | 4 = 34820).
    // utime/stime must still land on the right tokens once tty_nr is non-zero.
    const line2 = "1234 (sh) S 1000 1234 1234 34820 1234 4194560 200 0 0 0 50 70 0 0 20 0 1 0 1\n";
    const q = parseLinuxStat(line2).?;
    try testing.expectEqual(@as(i64, 34820), q.tty_nr);
    try testing.expectEqual(@as(u64, 50), q.utime);
    try testing.expectEqual(@as(u64, 70), q.stime);
}

test "linuxTtyName: renders UNIX98 pty device names, null for anything else" {
    var buf: [32]u8 = undefined;
    // major 136, minor 4 ⇒ pts/4
    try testing.expectEqualStrings("pts/4", linuxTtyName(&buf, (136 << 8) | 4).?);
    // major 137 continues the numbering past 255 ⇒ pts/256
    try testing.expectEqualStrings("pts/256", linuxTtyName(&buf, (137 << 8) | 0).?);
    // No controlling terminal.
    try testing.expectEqual(@as(?[]const u8, null), linuxTtyName(&buf, 0));
    // A legacy console (major 4) is not a pts and can't be matched to a pane, so
    // we report null rather than inventing a name.
    try testing.expectEqual(@as(?[]const u8, null), linuxTtyName(&buf, (4 << 8) | 1));
}

test "ProcSampler: enumerates own pid with a name; second sample yields cpu_pct >= 0" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var s = ProcSampler.init(alloc);
    defer s.deinit();

    var out1: std.ArrayListUnmanaged(protocol.Proc) = .empty;
    defer {
        for (out1.items) |p| freeProc(alloc, p);
        out1.deinit(alloc);
    }
    _ = try s.sample(alloc, &out1, 0);
    try testing.expect(out1.items.len > 0);

    // Our own pid must appear, with a non-empty name.
    const my_pid: i64 = @intCast(switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => std.c.getpid(),
    });
    var found = false;
    for (out1.items) |p| {
        if (p.pid == my_pid) {
            found = true;
            try testing.expect(p.name.len > 0);
            // cmd is the full executable image path. On macOS/Linux it must be the
            // current process's absolute path (proc_pidpath / /proc/self/exe); a
            // leading '/' is the cheap "is it absolute" check. (Windows paths are
            // `X:\...`, so the absolute assertion is POSIX-only; the live Windows box
            // validates that path separately.)
            if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
                try testing.expect(p.cmd != null);
                try testing.expect(p.cmd.?.len > 0);
                try testing.expect(p.cmd.?[0] == '/');
            }
        }
        try testing.expect(p.cpu_pct >= 0);
        // `tty`, when present, is a bare device NAME — no "/dev/" prefix and
        // never an empty string (absent is spelled null). The Swift side
        // compares it against a pane's tty, so the shape has to be exact.
        // (Whether ANY process has one depends on how the tests were launched,
        // so presence itself isn't asserted here — the live panel covers that.)
        if (p.tty) |t| {
            try testing.expect(t.len > 0);
            try testing.expect(t[0] != '/');
        }
    }
    try testing.expect(found);

    // A second sample: cpu_pct must be present (>= 0) for every row and decodable.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    var out2: std.ArrayListUnmanaged(protocol.Proc) = .empty;
    defer {
        for (out2.items) |p| freeProc(alloc, p);
        out2.deinit(alloc);
    }
    _ = try s.sample(alloc, &out2, 0);
    try testing.expect(out2.items.len > 0);
    for (out2.items) |p| try testing.expect(p.cpu_pct >= 0);
}

/// Free one row's caller-owned strings. Public because `sample` hands ownership
/// of `name`/`user`/`cmd` to the caller, so every caller — the agent's PROC_LIST
/// handler, and tests in sibling modules (`pty_child.zig`, T98) — needs the
/// matching free.
pub fn freeProc(alloc: Allocator, p: protocol.Proc) void {
    alloc.free(p.name);
    if (p.user) |u| alloc.free(u);
    if (p.cmd) |c| alloc.free(c);
    if (p.tty) |t| alloc.free(t);
}
