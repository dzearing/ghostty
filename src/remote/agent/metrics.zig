//! Cross-platform host-metrics sampler for the remote machine activity monitor
//! (§9.3). A `Sampler` is owned by the agent's metrics pump thread (one per
//! subscribed connection); each `sample()` returns a `protocol.HostMetrics` by
//! value (scalars only — no allocation, nothing for the caller to free).
//!
//! CPU% is the *busy fraction since the previous `sample()` call*, so the very
//! first call returns `cpu_pct = 0` (no prior tick baseline). All other fields
//! (memory, ncpu, uptime, load) are instantaneous reads.
//!
//! Like `pty_child.zig`, the OS-specific reads branch on `builtin.os.tag`, each
//! body guarded so the non-target OS branches never compile (the agent is built
//! natively for macOS AND cross-compiled to `x86_64-windows-gnu`; both must
//! build). The live reads are validated against the Windows box; the only piece
//! tested deterministically here is the pure CPU-delta math (`cpuPct`).

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../protocol.zig");

/// Busy CPU percentage (0..100) from two cumulative tick counts. Factored out as a
/// pure function so the delta math is unit-tested without touching the OS. Returns
/// 0 when there is no prior baseline or the total didn't advance (avoids div-by-0
/// and a bogus spike on the first sample).
pub fn cpuPct(prev_busy: u64, prev_total: u64, busy: u64, total: u64) f32 {
    if (total <= prev_total) return 0; // first sample or clock didn't advance
    const d_total = total - prev_total;
    // Guard against a non-monotonic busy read (shouldn't happen, but be total).
    const d_busy = if (busy >= prev_busy) busy - prev_busy else 0;
    const frac = @as(f64, @floatFromInt(d_busy)) / @as(f64, @floatFromInt(d_total));
    return @floatCast(std.math.clamp(frac, 0.0, 1.0) * 100.0);
}

/// Host metrics sampler. Holds the previous CPU tick baseline so `sample()` can
/// compute a delta. Construct with `init`; the struct is plain data (no resources
/// to release), so there is no `deinit`.
pub const Sampler = struct {
    /// Previous cumulative busy + total CPU ticks (0,0 ⇒ no baseline yet).
    prev_busy: u64 = 0,
    prev_total: u64 = 0,
    have_prev: bool = false,

    pub fn init() Sampler {
        return .{};
    }

    /// Sample host metrics now. `cpu_pct` is the busy fraction since the previous
    /// `sample()` (0 on the first call). The returned struct owns no memory.
    pub fn sample(self: *Sampler) protocol.HostMetrics {
        return switch (builtin.os.tag) {
            .macos => self.sampleMacos(),
            .linux => self.sampleLinux(),
            .windows => self.sampleWindows(),
            else => .{},
        };
    }

    /// Fold a fresh cumulative (busy, total) tick reading into the running CPU%
    /// and advance the baseline. Shared by every OS path.
    fn cpuFromTicks(self: *Sampler, busy: u64, total: u64) f32 {
        const pct = if (self.have_prev)
            cpuPct(self.prev_busy, self.prev_total, busy, total)
        else
            0;
        self.prev_busy = busy;
        self.prev_total = total;
        self.have_prev = true;
        return pct;
    }

    // --- macOS ---------------------------------------------------------------

    fn sampleMacos(self: *Sampler) protocol.HostMetrics {
        if (builtin.os.tag != .macos) return .{};
        const c = macos;

        var h: protocol.HostMetrics = .{};

        // CPU: host_statistics(HOST_CPU_LOAD_INFO) → cumulative user/sys/idle/nice
        // ticks across all cores. busy = user+sys+nice; total = busy+idle.
        var cpu_load: c.host_cpu_load_info = undefined;
        var count: c.mach_msg_type_number_t = c.HOST_CPU_LOAD_INFO_COUNT;
        const host = c.mach_host_self();
        if (c.host_statistics(host, c.HOST_CPU_LOAD_INFO, @ptrCast(&cpu_load), &count) == 0) {
            const user = cpu_load.cpu_ticks[c.CPU_STATE_USER];
            const sys = cpu_load.cpu_ticks[c.CPU_STATE_SYSTEM];
            const idle = cpu_load.cpu_ticks[c.CPU_STATE_IDLE];
            const nice = cpu_load.cpu_ticks[c.CPU_STATE_NICE];
            const busy: u64 = @as(u64, user) + sys + nice;
            const total: u64 = busy + idle;
            h.cpu_pct = self.cpuFromTicks(busy, total);
        }

        // Memory: HW_MEMSIZE (total) via sysctl; used = (active+wired+compressed)
        // * page_size via vm_statistics64.
        h.mem_total = c.sysctlU64(&[_]c_int{ c.CTL_HW, c.HW_MEMSIZE }) orelse 0;
        var page_size: c.vm_size_t = 0;
        _ = c.host_page_size(host, &page_size);
        var vm: c.vm_statistics64 = undefined;
        var vm_count: c.mach_msg_type_number_t = c.HOST_VM_INFO64_COUNT;
        if (c.host_statistics64(host, c.HOST_VM_INFO64, @ptrCast(&vm), &vm_count) == 0 and page_size > 0) {
            const used_pages: u64 = @as(u64, vm.active_count) + vm.wire_count + vm.compressor_page_count;
            h.mem_used = used_pages * @as(u64, page_size);
        }

        // ncpu: hw.logicalcpu (HW_NCPU is the same logical count on modern macOS).
        if (c.sysctlU64(&[_]c_int{ c.CTL_HW, c.HW_NCPU })) |n| h.ncpu = @intCast(n);

        // uptime: KERN_BOOTTIME timeval → now - boot.
        if (c.bootTimeSecs()) |boot| {
            const now: i64 = std.time.timestamp();
            if (now > boot) h.uptime_s = @intCast(now - boot);
        }

        // load1: getloadavg()[0].
        var loads: [3]f64 = undefined;
        if (c.getloadavg(&loads, 3) >= 1) h.load1 = @floatCast(loads[0]);

        return h;
    }

    // --- Linux ---------------------------------------------------------------

    fn sampleLinux(self: *Sampler) protocol.HostMetrics {
        if (builtin.os.tag != .linux) return .{};
        var h: protocol.HostMetrics = .{};

        // CPU: first line of /proc/stat — "cpu  user nice system idle iowait irq
        // softirq steal ...". busy = sum of all - idle - iowait; total = sum of all.
        if (readSmallFile("/proc/stat")) |buf| {
            var nbuf = buf;
            if (parseProcStatCpu(nbuf.slice())) |t| {
                h.cpu_pct = self.cpuFromTicks(t.busy, t.total);
            }
        }

        // ncpu: count "cpuN " lines in /proc/stat, or fall back to 1.
        if (readSmallFile("/proc/stat")) |buf| {
            var nbuf = buf;
            h.ncpu = countCpuLines(nbuf.slice());
        }
        if (h.ncpu == 0) h.ncpu = 1;

        // Memory: /proc/meminfo MemTotal / MemAvailable (kB).
        if (readSmallFile("/proc/meminfo")) |buf| {
            var nbuf = buf;
            const mi = parseMeminfo(nbuf.slice());
            h.mem_total = mi.total_kb * 1024;
            const used_kb = if (mi.total_kb > mi.avail_kb) mi.total_kb - mi.avail_kb else 0;
            h.mem_used = used_kb * 1024;
        }

        // uptime: first float of /proc/uptime (seconds since boot).
        if (readSmallFile("/proc/uptime")) |buf| {
            var nbuf = buf;
            if (parseFirstFloat(nbuf.slice())) |secs| h.uptime_s = @intFromFloat(secs);
        }

        // load1: first float of /proc/loadavg.
        if (readSmallFile("/proc/loadavg")) |buf| {
            var nbuf = buf;
            if (parseFirstFloat(nbuf.slice())) |l| h.load1 = @floatCast(l);
        }

        return h;
    }

    // --- Windows -------------------------------------------------------------

    fn sampleWindows(self: *Sampler) protocol.HostMetrics {
        if (builtin.os.tag != .windows) return .{};
        const w = windows;
        var h: protocol.HostMetrics = .{};

        // CPU: GetSystemTimes(idle, kernel, user). kernel INCLUDES idle, so
        // total = kernel + user and busy = total - idle.
        var idle_ft: std.os.windows.FILETIME = undefined;
        var kernel_ft: std.os.windows.FILETIME = undefined;
        var user_ft: std.os.windows.FILETIME = undefined;
        if (w.GetSystemTimes(&idle_ft, &kernel_ft, &user_ft) != 0) {
            const idle = filetimeToU64(idle_ft);
            const kernel = filetimeToU64(kernel_ft);
            const user = filetimeToU64(user_ft);
            const total = kernel + user;
            const busy = if (total > idle) total - idle else 0;
            h.cpu_pct = self.cpuFromTicks(busy, total);
        }

        // Memory: GlobalMemoryStatusEx.
        var mem: w.MEMORYSTATUSEX = .{ .dwLength = @sizeOf(w.MEMORYSTATUSEX) };
        if (w.GlobalMemoryStatusEx(&mem) != 0) {
            h.mem_total = mem.ullTotalPhys;
            h.mem_used = if (mem.ullTotalPhys > mem.ullAvailPhys)
                mem.ullTotalPhys - mem.ullAvailPhys
            else
                0;
        }

        // ncpu: GetSystemInfo.dwNumberOfProcessors.
        var si: std.os.windows.SYSTEM_INFO = undefined;
        std.os.windows.kernel32.GetSystemInfo(&si);
        h.ncpu = si.dwNumberOfProcessors;

        // uptime: GetTickCount64() ms since boot. No load average on Windows.
        h.uptime_s = w.GetTickCount64() / 1000;

        return h;
    }
};

// =============================================================================
// macOS — Mach / sysctl externs (compiled only on macOS)
// =============================================================================

const macos = struct {
    const mach_port_t = u32;
    const host_t = mach_port_t;
    const kern_return_t = c_int;
    const mach_msg_type_number_t = u32;
    const natural_t = u32;
    const integer_t = i32;
    const vm_size_t = usize;

    const HOST_CPU_LOAD_INFO: c_int = 3;
    const HOST_VM_INFO64: c_int = 4;
    const CPU_STATE_USER: usize = 0;
    const CPU_STATE_SYSTEM: usize = 1;
    const CPU_STATE_IDLE: usize = 2;
    const CPU_STATE_NICE: usize = 3;

    // host_cpu_load_info_data_t: 4 cumulative tick counters.
    const host_cpu_load_info = extern struct {
        cpu_ticks: [4]natural_t,
    };
    const HOST_CPU_LOAD_INFO_COUNT: mach_msg_type_number_t =
        @sizeOf(host_cpu_load_info) / @sizeOf(integer_t);

    // vm_statistics64_data_t (we read active/wire/compressor; the rest pad to the
    // correct struct size so HOST_VM_INFO64_COUNT matches the kernel's expectation).
    const vm_statistics64 = extern struct {
        free_count: natural_t,
        active_count: natural_t,
        inactive_count: natural_t,
        wire_count: natural_t,
        zero_fill_count: u64,
        reactivations: u64,
        pageins: u64,
        pageouts: u64,
        faults: u64,
        cow_faults: u64,
        lookups: u64,
        hits: u64,
        purges: u64,
        purgeable_count: natural_t,
        speculative_count: natural_t,
        decompressions: u64,
        compressions: u64,
        swapins: u64,
        swapouts: u64,
        compressor_page_count: natural_t,
        throttled_count: natural_t,
        external_page_count: natural_t,
        internal_page_count: natural_t,
        total_uncompressed_pages_in_compressor: u64,
    };
    const HOST_VM_INFO64_COUNT: mach_msg_type_number_t =
        @sizeOf(vm_statistics64) / @sizeOf(integer_t);

    // sysctl name ids (sys/sysctl.h).
    const CTL_HW: c_int = 6;
    const HW_NCPU: c_int = 3;
    const HW_MEMSIZE: c_int = 24;
    const CTL_KERN: c_int = 1;
    const KERN_BOOTTIME: c_int = 21;

    const timeval = extern struct { tv_sec: c_long, tv_usec: i32 };

    extern "c" fn mach_host_self() host_t;
    extern "c" fn host_statistics(
        host: host_t,
        flavor: c_int,
        info: [*]integer_t,
        count: *mach_msg_type_number_t,
    ) kern_return_t;
    extern "c" fn host_statistics64(
        host: host_t,
        flavor: c_int,
        info: [*]integer_t,
        count: *mach_msg_type_number_t,
    ) kern_return_t;
    extern "c" fn host_page_size(host: host_t, out: *vm_size_t) kern_return_t;
    extern "c" fn sysctl(
        name: [*]c_int,
        namelen: c_uint,
        oldp: ?*anyopaque,
        oldlenp: ?*usize,
        newp: ?*anyopaque,
        newlen: usize,
    ) c_int;
    extern "c" fn getloadavg(loadavg: [*]f64, nelem: c_int) c_int;

    /// Read a u64 sysctl by MIB (e.g. {CTL_HW, HW_MEMSIZE}). Handles both 4- and
    /// 8-byte kernel returns. null on failure.
    fn sysctlU64(mib: []const c_int) ?u64 {
        var out: u64 = 0;
        var len: usize = @sizeOf(u64);
        const rc = sysctl(@constCast(mib.ptr), @intCast(mib.len), &out, &len, null, 0);
        if (rc != 0) return null;
        if (len == @sizeOf(u32)) return @as(u64, @as(u32, @truncate(out)));
        return out;
    }

    /// KERN_BOOTTIME → boot time in unix seconds. null on failure.
    fn bootTimeSecs() ?i64 {
        var tv: timeval = undefined;
        var len: usize = @sizeOf(timeval);
        var mib = [_]c_int{ CTL_KERN, KERN_BOOTTIME };
        const rc = sysctl(&mib, mib.len, &tv, &len, null, 0);
        if (rc != 0) return null;
        return @intCast(tv.tv_sec);
    }
};

// =============================================================================
// Windows — kernel32 externs not in std.os.windows (compiled only on Windows)
// =============================================================================

const windows = struct {
    const BOOL = std.os.windows.BOOL;
    const FILETIME = std.os.windows.FILETIME;
    const DWORD = std.os.windows.DWORD;

    // GlobalMemoryStatusEx's MEMORYSTATUSEX (not in std).
    const MEMORYSTATUSEX = extern struct {
        dwLength: DWORD,
        dwMemoryLoad: DWORD = 0,
        ullTotalPhys: u64 = 0,
        ullAvailPhys: u64 = 0,
        ullTotalPageFile: u64 = 0,
        ullAvailPageFile: u64 = 0,
        ullTotalVirtual: u64 = 0,
        ullAvailVirtual: u64 = 0,
        ullAvailExtendedVirtual: u64 = 0,
    };

    extern "kernel32" fn GetSystemTimes(
        lpIdleTime: *FILETIME,
        lpKernelTime: *FILETIME,
        lpUserTime: *FILETIME,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GlobalMemoryStatusEx(buffer: *MEMORYSTATUSEX) callconv(.winapi) BOOL;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
};

/// Pack a Windows FILETIME (two DWORDs) into a u64 of 100ns ticks.
fn filetimeToU64(ft: std.os.windows.FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

// =============================================================================
// Linux parsing helpers (pure; usable on any OS for unit testing)
// =============================================================================

/// A small fixed-size file read buffer. `/proc` files of interest are tiny, but
/// `/proc/stat` grows with core count, so cap generously and truncate if larger.
const SmallFile = struct {
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,
    fn slice(self: *SmallFile) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Read up to 16 KiB of a (proc) file. null on any error. Returns by value to keep
/// the buffer on the caller's stack (no allocation).
fn readSmallFile(path: []const u8) ?SmallFile {
    var sf: SmallFile = .{};
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    sf.len = file.readAll(&sf.buf) catch return null;
    if (sf.len == 0) return null;
    return sf;
}

const CpuTicks = struct { busy: u64, total: u64 };

/// Parse the aggregate "cpu " line of /proc/stat into (busy, total) jiffies.
/// Fields: user nice system idle iowait irq softirq steal guest guest_nice.
/// total = sum of all present; busy = total - idle - iowait.
fn parseProcStatCpu(text: []const u8) ?CpuTicks {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, first, "cpu ")) return null;
    var it = std.mem.tokenizeScalar(u8, first["cpu ".len..], ' ');
    var total: u64 = 0;
    var idle_iowait: u64 = 0;
    var idx: usize = 0;
    while (it.next()) |tok| : (idx += 1) {
        const v = std.fmt.parseInt(u64, tok, 10) catch continue;
        total += v;
        if (idx == 3 or idx == 4) idle_iowait += v; // idle(3) + iowait(4)
    }
    if (total == 0) return null;
    const busy = if (total > idle_iowait) total - idle_iowait else 0;
    return .{ .busy = busy, .total = total };
}

/// Count per-core "cpuN " lines (excludes the aggregate "cpu " line) in /proc/stat.
fn countCpuLines(text: []const u8) u32 {
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        if (std.mem.startsWith(u8, line, "cpu") and line[3] >= '0' and line[3] <= '9') n += 1;
    }
    return n;
}

const Meminfo = struct { total_kb: u64 = 0, avail_kb: u64 = 0 };

/// Parse MemTotal / MemAvailable (kB) out of /proc/meminfo.
fn parseMeminfo(text: []const u8) Meminfo {
    var mi: Meminfo = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            mi.total_kb = parseFirstUint(line["MemTotal:".len..]) orelse 0;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            mi.avail_kb = parseFirstUint(line["MemAvailable:".len..]) orelse 0;
        }
    }
    return mi;
}

fn parseFirstUint(text: []const u8) ?u64 {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

fn parseFirstFloat(text: []const u8) ?f64 {
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    const tok = it.next() orelse return null;
    return std.fmt.parseFloat(f64, tok) catch null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "cpuPct: busy/total delta math" {
    // 50 busy ticks over 200 total ticks since the prior sample → 25%.
    try testing.expectEqual(@as(f32, 25.0), cpuPct(100, 1000, 150, 1200));
    // Fully busy.
    try testing.expectEqual(@as(f32, 100.0), cpuPct(0, 0, 100, 100));
    // Idle (no busy advance).
    try testing.expectEqual(@as(f32, 0.0), cpuPct(100, 1000, 100, 1100));
    // No baseline / clock didn't advance → 0 (no spike on the first sample).
    try testing.expectEqual(@as(f32, 0.0), cpuPct(0, 0, 0, 0));
    try testing.expectEqual(@as(f32, 0.0), cpuPct(500, 1000, 500, 1000));
    // Non-monotonic busy is clamped, never negative.
    try testing.expectEqual(@as(f32, 0.0), cpuPct(100, 1000, 50, 1200));
}

test "Sampler.cpuFromTicks: first sample is 0, second reflects the delta" {
    var s = Sampler.init();
    try testing.expectEqual(@as(f32, 0.0), s.cpuFromTicks(100, 1000)); // baseline
    try testing.expectEqual(@as(f32, 25.0), s.cpuFromTicks(150, 1200)); // +50/+200
}

test "parseProcStatCpu / countCpuLines / parseMeminfo (Linux text parsing)" {
    const stat =
        "cpu  100 0 100 800 0 0 0 0 0 0\n" ++
        "cpu0 50 0 50 400 0 0 0 0 0 0\n" ++
        "cpu1 50 0 50 400 0 0 0 0 0 0\n" ++
        "intr 12345\n";
    const t = parseProcStatCpu(stat).?;
    // total = 100+0+100+800 = 1000; busy = total - idle(800) = 200.
    try testing.expectEqual(@as(u64, 1000), t.total);
    try testing.expectEqual(@as(u64, 200), t.busy);
    try testing.expectEqual(@as(u32, 2), countCpuLines(stat));

    const mem = "MemTotal:       16384 kB\nMemFree: 1000 kB\nMemAvailable:    8192 kB\n";
    const mi = parseMeminfo(mem);
    try testing.expectEqual(@as(u64, 16384), mi.total_kb);
    try testing.expectEqual(@as(u64, 8192), mi.avail_kb);

    try testing.expectEqual(@as(f64, 12345.67), parseFirstFloat("12345.67 98765.43 1\n").?);
}
