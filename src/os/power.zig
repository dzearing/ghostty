//! Opting a process out of the OS's power/efficiency throttling (T1465).
//!
//! ## Why this exists
//!
//! Windows 11 decides on its own that a process is "background" and puts it in
//! **efficiency mode** (EcoQoS): its threads are scheduled onto E-cores and the
//! clock is held down. Nothing asks for this and nothing reports it — the
//! process simply runs slower, and only sometimes, which is exactly what makes
//! it expensive to find.
//!
//! It cost 2.2x on the pane path. `ghoztty-agent` holds a session's ConPTY in a
//! separate, windowless holder process, and on a burst of shell output that
//! holder's ConPTY read loop delivered ~8,200 chunks a second where the *same
//! loop, same API, same workload* inside the foreground app delivered ~18,000
//! (T1464/T1465). The user's report was the visible end of it: a Ghoztty pane
//! taking twice as long as conhost to catch up, but only on the shipped
//! session-persistence configuration.
//!
//! A terminal's PTY plumbing is latency work, not throughput work — every read
//! is a round trip to conhost — so an E-core at a reduced clock is felt
//! directly by whoever is watching the output. This is the documented way to
//! say "not this one": `SetProcessInformation(ProcessPowerThrottling)` with the
//! EXECUTION_SPEED bit set in `ControlMask` and CLEAR in `StateMask`, which
//! means *disable throttling*, as distinct from clearing `ControlMask` too
//! (which means "let the system decide", the default we are leaving).
//!
//! Child processes inherit the state, which is what makes one call at the top
//! of a holder cover the conhost the ConPTY spawns underneath it.
//!
//! Everywhere else this is a no-op: macOS has no equivalent knob we want (a
//! LaunchAgent-run daemon is not QoS-clamped the way an EcoQoS process is), and
//! the call site is written to be unconditional so the two platforms do not
//! drift.

const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("main.zig");

const log = std.log.scoped(.os_power);

/// Ask the OS never to run this process in efficiency mode.
///
/// Best-effort and silent about success: a failure means the process keeps the
/// default "system decides" state, which is what every build before this one
/// had, so there is nothing for a caller to recover from. Logged at debug so a
/// run that is unexpectedly slow can still be told apart from one that never
/// asked.
pub fn disableThrottling() void {
    if (comptime builtin.os.tag != .windows) return;

    const windows = std.os.windows;
    const exp = internal_os.windows.exp;

    var state: exp.PROCESS_POWER_THROTTLING_STATE = .{
        .Version = exp.PROCESS_POWER_THROTTLING_CURRENT_VERSION,
        // Which knob we are speaking about...
        .ControlMask = exp.PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
        // ...and what we want it set to: 0 = do not throttle.
        .StateMask = 0,
    };

    const ok = exp.kernel32.SetProcessInformation(
        windows.GetCurrentProcess(),
        .ProcessPowerThrottling,
        @ptrCast(&state),
        @sizeOf(exp.PROCESS_POWER_THROTTLING_STATE),
    );
    if (ok == 0) {
        log.debug("could not opt out of power throttling (gle={d})", .{
            @intFromEnum(windows.kernel32.GetLastError()),
        });
        return;
    }
    log.debug("power throttling disabled for this process", .{});
}


// -----------------------------------------------------------------------------
// Core placement on a hybrid CPU (T1465)
// -----------------------------------------------------------------------------
//
// The measurement that produced this: on a 13900K (8 performance cores, 16
// efficiency cores), a pane whose ConPTY is held by `ghoztty-agent` ingested a
// 7.7 MB burst in ~10.5 s where the identical read loop inside the app took
// ~5.9 s and conhost ~6.2 s. Every leg of the relay was IDLE - the holder's
// reader spent 96% of every second blocked in `ReadFile` and its peek found the
// pipe empty on every single read, so nothing downstream was ever the limit.
// The SOURCE was slow: conhost and the shell, both children of the holder, were
// being placed on efficiency cores, and the cmd->conhost round trip that
// produces every ~73-byte chunk of output costs ~122 us there against ~55 us on
// a performance core. The app does not pay it because a foreground GUI process
// and its children are not classified that way.
//
// Restricting the HOLDER's process tree to the performance cores closed the gap
// outright: 1.05x and 1.14x against the local pane, i.e. level with conhost.
//
// Two things make this safe to ship rather than a hardcoded mask:
//
//   - The set is DERIVED, from `GetSystemCpuSetInformation`'s per-CPU
//     `EfficiencyClass`. A CPU with one class - every non-hybrid machine - has
//     no faster half to prefer, so the answer is `null` and nothing is pinned.
//   - It stops at the shell. The holder and the conhost it creates are terminal
//     plumbing and belong on the fast cores; the user's SHELL is not, and a
//     parallel build started in a persisted pane must have the whole machine.
//     `allowAllCores` puts the spawned child back on the full mask, and its own
//     children inherit that.

/// The performance half of a hybrid CPU: the affinity mask of the processors
/// with the highest `EfficiencyClass`, and their CPU-set ids.
///
/// Null when the question does not apply - a non-hybrid CPU (one class, so
/// there is no faster half to prefer), more than one processor group, or an API
/// that answered nothing. Null means CALLERS DO NOTHING, which is deliberately
/// the same behavior every build before T1465 had.
pub const PerformanceCores = struct {
    mask: usize,
    ids: [64]u32,
    count: u32,

    pub fn idSlice(self: *const PerformanceCores) []const u32 {
        return self.ids[0..self.count];
    }
};

pub fn performanceCores() ?PerformanceCores {
    if (comptime builtin.os.tag != .windows) return null;

    const windows = std.os.windows;
    const exp = internal_os.windows.exp;

    var buf: [64 * 1024]u8 align(8) = undefined;
    var needed: windows.ULONG = 0;
    if (exp.kernel32.GetSystemCpuSetInformation(
        @ptrCast(&buf),
        @intCast(buf.len),
        &needed,
        windows.GetCurrentProcess(),
        0,
    ) == 0) return null;
    const len: usize = @min(@as(usize, needed), buf.len);

    // Walk by each entry's OWN `Size` rather than `@sizeOf` - the struct the
    // kernel writes is smaller than the header's declaration on this Windows,
    // and stepping by the larger one silently drops the last processor.
    const min_entry = @offsetOf(exp.SYSTEM_CPU_SET_INFORMATION, "AllFlags") + 1;

    var out: PerformanceCores = .{ .mask = 0, .ids = undefined, .count = 0 };
    var best_class: u8 = 0;
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        var off: usize = 0;
        while (off + min_entry <= len) {
            const e: *const exp.SYSTEM_CPU_SET_INFORMATION = @ptrCast(@alignCast(&buf[off]));
            if (e.Size < min_entry) break;
            defer off += e.Size;
            if (e.Type != 0) continue; // CpuSetInformation
            if (e.Group != 0) return null; // multi-group: not our problem to solve
            if (pass == 0) {
                if (e.EfficiencyClass > best_class) best_class = e.EfficiencyClass;
                continue;
            }
            if (e.EfficiencyClass != best_class) continue;
            if (e.LogicalProcessorIndex >= @bitSizeOf(usize)) return null;
            if (out.count >= out.ids.len) return null;
            out.mask |= @as(usize, 1) << @intCast(e.LogicalProcessorIndex);
            out.ids[out.count] = e.Id;
            out.count += 1;
        }
        if (pass == 0 and best_class == 0) return null; // one class: nothing to prefer
    }
    if (out.count == 0) return null;
    return out;
}

/// The performance-core affinity mask alone, for callers that only want to pin.
pub fn performanceCoreMask() ?usize {
    const cores = performanceCores() orelse return null;
    return cores.mask;
}

/// Restrict this process - and every child it goes on to create, since affinity
/// is inherited - to the performance cores. A no-op on a non-hybrid CPU.
pub fn preferPerformanceCores() void {
    if (comptime builtin.os.tag != .windows) return;
    const windows = std.os.windows;
    const exp = internal_os.windows.exp;
    const mask = performanceCoreMask() orelse return;
    if (exp.kernel32.SetProcessAffinityMask(windows.GetCurrentProcess(), mask) == 0) {
        log.debug("could not prefer performance cores (gle={d})", .{
            @intFromEnum(windows.kernel32.GetLastError()),
        });
        return;
    }
    log.info("pty plumbing pinned to performance cores mask=0x{x}", .{mask});
}

/// Hand one child process the whole machine back, with a SOFT preference for
/// the performance cores.
///
/// This is the shell, and the two halves matter for different reasons. The
/// affinity goes back to the full system mask because a parallel build started
/// in a persisted pane must not be confined to half the cores by an inherited
/// pin. The CPU-set default then says where it would RATHER run: a preference
/// the scheduler honours while those cores are free and abandons when they are
/// not, which is what an interactive shell wants and what a 32-way build needs
/// it not to be.
pub fn allowAllCores(process: std.os.windows.HANDLE) void {
    if (comptime builtin.os.tag != .windows) return;
    const windows = std.os.windows;
    const exp = internal_os.windows.exp;

    var process_mask: usize = 0;
    var system_mask: usize = 0;
    if (exp.kernel32.GetProcessAffinityMask(
        windows.GetCurrentProcess(),
        &process_mask,
        &system_mask,
    ) == 0) return;
    if (system_mask != 0 and system_mask != process_mask) {
        _ = exp.kernel32.SetProcessAffinityMask(process, system_mask);
    }
    if (performanceCores()) |cores| {
        _ = exp.kernel32.SetProcessDefaultCpuSets(process, cores.idSlice().ptr, cores.count);
    }
}

test "disableThrottling is safe to call and idempotent" {
    // It reports nothing, so what a test can assert is that it neither traps
    // nor cares how many times it is called — the two ways a best-effort
    // startup call can actually hurt.
    disableThrottling();
    disableThrottling();
}

test "performanceCoreMask answers null or a non-empty subset of this machine" {
    const testing = std.testing;
    const mask = performanceCoreMask();
    // Off Windows there is nothing to ask, and on a non-hybrid Windows box the
    // honest answer is "no preference" rather than "every core" - a mask of all
    // cores would make the caller pin for no reason.
    if (comptime builtin.os.tag != .windows) {
        try testing.expect(mask == null);
        return;
    }
    if (mask) |m| {
        try testing.expect(m != 0);
        var process_mask: usize = 0;
        var system_mask: usize = 0;
        const exp = internal_os.windows.exp;
        if (exp.kernel32.GetProcessAffinityMask(
            std.os.windows.GetCurrentProcess(),
            &process_mask,
            &system_mask,
        ) != 0) {
            // Every bit it names must be a processor this machine actually has,
            // and it must be a PROPER subset - preferring all of them is the
            // same as preferring none, and would cost a pin for nothing.
            try testing.expectEqual(m, m & system_mask);
            try testing.expect(m != system_mask);
        }
    }
}
