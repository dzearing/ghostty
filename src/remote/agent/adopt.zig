//! Adopting (and retiring) a standalone 'Ghoztty Agent' MSI install (T549).
//!
//! The one-installer plan (docs/design/one-installer-agent-consolidation.md,
//! decision 4) folds the relay agent into the app-managed session-persistence
//! agent. A box that already has the standalone MSI would otherwise run TWO
//! serving agents fighting over the same relay credential, plus a contested
//! `HKCU\...\Run\GhozttyAgent` value that the app and the MSI overwrite back
//! and forth. On such a box the consolidated agent ADOPTS the standalone
//! install at startup:
//!
//!   1. Mark sharing enabled (`sharing.json`) — the box was serving; adoption
//!      must not turn that off. relay.env is untouched (it lives outside both
//!      install dirs and both agents read the same path — no re-enroll, ever).
//!      An explicit user opt-out (an existing `sharing.json` with
//!      `enabled:false`) is respected, and the mark happens at most once.
//!   2. Wait for the standalone agent to go IDLE, then stop it. Its session
//!      store is in-memory — stopping it mid-session kills real remote
//!      shells — so we apply the same policy its own self-updater used ("swap
//!      only at zero live sessions"), observed from outside: a live session is
//!      a spawned shell, i.e. a process descendant, so zero non-ConPTY
//!      descendants over several consecutive polls means idle. Conservative in
//!      the safe direction: a phantom descendant (pid reuse) delays the stop,
//!      never hastens it.
//!   3. Uninstall the MSI product — matched by UpgradeCode
//!      (`7143BA66-FD7B-4D45-8555-E946D2141912`), NEVER by name — via
//!      per-user `msiexec /x {ProductCode} /qn`.
//!   4. Re-assert the Run key. The MSI uninstall deletes the contested
//!      `GhozttyAgent` value even when the app owns its data, so the value is
//!      snapshotted before and restored after (or recomposed from this
//!      process's own command line when the snapshot pointed into the retired
//!      install dir).
//!
//! THE HAZARD THIS FILE EXISTS TO CONTAIN: the standalone MSI's `KillAgentCA`
//! custom action terminates EVERY `ghoztty-agent.exe` by basename — on
//! uninstall too (see `msi_ca.zig`). A naive `msiexec /x` would therefore kill
//! THIS agent mid-adoption, and with it every live local shell it owns —
//! exactly the stranding T549 forbids. So for the duration of the uninstall
//! the agent SHIELDS itself: a deny-`PROCESS_TERMINATE` ACE for Everyone is
//! prepended to its own process DACL and removed right after. `KillAgentCA`
//! opens with `PROCESS_TERMINATE` only and is best-effort, so the denied
//! `OpenProcess` just skips us. If the shield cannot be raised, the uninstall
//! is NOT attempted (retried at the next agent start) — live shells are never
//! exposed to the kill.
//!
//! Debug-build safety (endpoint-isolation rule, T350 spirit): the agent state
//! dir is debug-isolated but the MSI registration, the install dir and the
//! Run key are GLOBAL — a debug/test agent acting on the real install would
//! uninstall the user's real product mid-test. A debug agent therefore
//! refuses to adopt unless BOTH `GHOSTTY_ADOPT_INSTALL_DIR` and
//! `GHOSTTY_ADOPT_UNINSTALL_CMD` are set, which is what the acceptance test
//! sets and a real box never does.
//!
//! Env knobs (GHOSTTY_ prefix — repo convention):
//!   - `GHOSTTY_ADOPT_DISABLE=1` — kill switch.
//!   - `GHOSTTY_ADOPT_INSTALL_DIR=<dir>` — standalone install dir override
//!     (default `%LOCALAPPDATA%\Programs\Ghoztty Agent`).
//!   - `GHOSTTY_ADOPT_UNINSTALL_CMD=<raw command line>` — replaces the
//!     msiexec invocation (tests point this at a recorder script). Run
//!     verbatim via CreateProcessW, no shell.
//!   - `GHOSTTY_ADOPT_RUNKEY_NAME=<value>` — Run-key value name override
//!     (default `GhozttyAgent`; tests use a scratch name so the real
//!     autostart entry is never touched).
//!   - `GHOSTTY_ADOPT_INTERVAL_MS=<n>` — overrides the idle-poll cadence.
//!
//! Everything decision-shaped is pure and unit-tested in the `test-agent`
//! lane on any host; the Win32 externs live behind a comptime OS gate.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sharing = @import("sharing.zig");
const atomic_write = @import("atomic_write.zig");
const internal_os = @import("../../os/main.zig");

/// File name, beside `sessions.json`/`sharing.json` in the agent state dir.
pub const file_name = "adoption.json";

pub const env_disable = "GHOSTTY_ADOPT_DISABLE";
pub const env_install_dir = "GHOSTTY_ADOPT_INSTALL_DIR";
pub const env_uninstall_cmd = "GHOSTTY_ADOPT_UNINSTALL_CMD";
pub const env_runkey_name = "GHOSTTY_ADOPT_RUNKEY_NAME";
pub const env_interval = "GHOSTTY_ADOPT_INTERVAL_MS";

/// The standalone agent MSI's PERMANENT UpgradeCode (relay/deploy/msi/
/// ghoztty-agent.wxs). Products are matched by this, never by display name —
/// this box carries an unrelated ghost product whose name also says Ghoztty.
pub const upgrade_code = "{7143BA66-FD7B-4D45-8555-E946D2141912}";

/// Contested Run-key value name (the app and the MSI both write it).
pub const default_runkey_name = "GhozttyAgent";

/// Idle-poll cadence while waiting for the standalone agent to drain.
pub const default_poll_interval_ms: u64 = 30 * std.time.ms_per_s;
/// Consecutive zero-descendant observations required before the stop.
pub const idle_polls_needed: u32 = 3;
/// Bound on one uninstall invocation (msiexec or the test override).
pub const uninstall_wait_ms: u32 = 10 * 60 * 1000;

// -----------------------------------------------------------------------------
// Persisted adoption state (adoption.json). Same lenient-parse/atomic-save
// rules as sharing.zig: malformed content reads as "nothing happened yet",
// which only ever repeats an idempotent step.

pub const State = struct {
    /// The whole adoption ran to completion; never look again.
    done: bool = false,
    /// Sharing was marked (or deliberately skipped) once — a later user
    /// opt-out must never be overridden by an adoption retry.
    sharing_marked: bool = false,
};

pub fn pathFor(alloc: Allocator, sessions_file: ?[]const u8) ?[]u8 {
    const sf = sessions_file orelse return null;
    const dir = std.fs.path.dirname(sf) orelse return null;
    return std.fs.path.join(alloc, &.{ dir, file_name }) catch null;
}

pub fn parse(alloc: Allocator, content: []const u8) State {
    const parsed = std.json.parseFromSlice(
        State,
        alloc,
        content,
        .{ .ignore_unknown_fields = true },
    ) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

pub fn load(alloc: Allocator, path: []const u8) State {
    const content = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return .{};
    defer alloc.free(content);
    return parse(alloc, content);
}

pub fn save(alloc: Allocator, path: []const u8, st: State) !void {
    var buf: [128]u8 = undefined;
    const content = try std.fmt.bufPrint(
        &buf,
        "{{\"version\":1,\"done\":{s},\"sharing_marked\":{s}}}\n",
        .{
            if (st.done) "true" else "false",
            if (st.sharing_marked) "true" else "false",
        },
    );
    try atomic_write.writeChunks(alloc, path, &.{content}, .{});
}

// -----------------------------------------------------------------------------
// Gating: who may adopt.

pub const Gate = enum {
    run,
    disabled,
    /// Debug build without both test overrides: the global install/registry
    /// surface belongs to the RELEASE lineage; a dev agent must not touch it.
    debug_needs_overrides,
};

pub fn gate(
    is_debug: bool,
    disable_set: bool,
    have_dir_override: bool,
    have_cmd_override: bool,
) Gate {
    if (disable_set) return .disabled;
    if (is_debug and !(have_dir_override and have_cmd_override)) return .debug_needs_overrides;
    return .run;
}

// -----------------------------------------------------------------------------
// Idle detection: "zero live sessions", observed from outside. A live session
// is a spawned shell — a process descendant of the agent — so the observable
// gate is "no descendants that are not ConPTY plumbing". The walk is pure so
// the rule unit-tests on any host (same shape as descendants.zig, plus the
// plumbing filter that lets console-subsystem stand-ins work in tests).

pub const ProcEntry = struct {
    pid: u32,
    ppid: u32,
    /// conhost.exe / openconsole.exe — ConPTY plumbing that exists whenever a
    /// console handle does, not evidence of a live session by itself. (A live
    /// session's SHELL still counts; only the plumbing is ignored.)
    conpty_plumbing: bool = false,
};

const max_walk_depth: usize = 128;

fn parentOf(entries: []const ProcEntry, pid: u32) ?u32 {
    for (entries) |e| {
        if (e.pid == pid) return e.ppid;
    }
    return null;
}

fn descendsFrom(entries: []const ProcEntry, root: u32, pid: u32) bool {
    var current = pid;
    var depth: usize = 0;
    while (depth < max_walk_depth) : (depth += 1) {
        const parent = parentOf(entries, current) orelse return false;
        if (parent == root) return true;
        // A snapshot cycle (pid recycling) or a root/self link ends the walk.
        if (parent == current or parent == 0) return false;
        current = parent;
    }
    return false;
}

/// How many non-plumbing processes descend from `root`. Zero across several
/// consecutive polls is the idle gate. Conservative by construction: a stale
/// parent link from pid reuse can only ADD a phantom descendant, which delays
/// the stop rather than killing live work.
pub fn busyDescendantCount(entries: []const ProcEntry, root: u32) u32 {
    if (root == 0) return 0;
    var count: u32 = 0;
    for (entries) |e| {
        if (e.pid == root) continue;
        if (e.conpty_plumbing) continue;
        if (descendsFrom(entries, root, e.pid)) count += 1;
    }
    return count;
}

// -----------------------------------------------------------------------------
// Run-key policy: what to do about `HKCU\...\Run\<name>` after the uninstall
// deleted (or spared) it. Pure, so the decision table is testable.

pub const RunKeyAction = enum {
    /// The value survived (or never existed): nothing to repair.
    leave,
    /// The uninstall deleted the app-owned value: put the snapshot back.
    restore_snapshot,
    /// The deleted value pointed into the retired install dir — restoring it
    /// would resurrect a dead command. Write this agent's own composition
    /// (exe + argv), which is exactly what the app's autostart writes.
    write_own,
};

pub fn runKeyAction(
    pre_value: ?[]const u8,
    post_exists: bool,
    install_dir: []const u8,
) RunKeyAction {
    if (post_exists) return .leave;
    const pre = pre_value orelse return .leave; // nothing was deleted
    if (install_dir.len > 0 and std.ascii.indexOfIgnoreCase(pre, install_dir) != null)
        return .write_own;
    return .restore_snapshot;
}

/// Compose `"exe" "arg1" "arg2"` — the quoting shape the app's autostart
/// writes (every token quoted). Caller frees.
pub fn quoteCommandLine(alloc: Allocator, exe: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '"');
    try out.appendSlice(alloc, exe);
    try out.append(alloc, '"');
    for (args) |a| {
        try out.appendSlice(alloc, " \"");
        try out.appendSlice(alloc, a);
        try out.append(alloc, '"');
    }
    return out.toOwnedSlice(alloc);
}

// -----------------------------------------------------------------------------
// The adoption runner (thread). Windows-only from here down.

const Ctx = struct {
    alloc: Allocator,
    state_path: []u8,
    state: State,
    install_dir: []u8,
    sessions_file: []u8,
    uninstall_cmd: ?[]u8,
    runkey_name: []u8,
    interval_ms: u64,
};

fn getEnv(alloc: Allocator, name: []const u8) ?[]u8 {
    const v = std.process.getEnvVarOwned(alloc, name) catch return null;
    if (v.len == 0) {
        alloc.free(v);
        return null;
    }
    return v;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("ghoztty-agent: adoption: " ++ fmt ++ "\n", args);
}

/// Start the adoption thread when a standalone install is present and this
/// build is allowed to act on it. Quiet in every no-op case — a normal box
/// has nothing to adopt and should hear nothing about it.
pub fn maybeStart(alloc: Allocator, sessions_file: ?[]const u8) void {
    if (comptime builtin.os.tag != .windows) return;

    const is_debug = @import("agent_build_options").is_debug;
    const disable = if (getEnv(alloc, env_disable)) |v| blk: {
        defer alloc.free(v);
        break :blk !std.mem.eql(u8, v, "0");
    } else false;

    var dir_override = getEnv(alloc, env_install_dir);
    var cmd_override = getEnv(alloc, env_uninstall_cmd);
    var cleanup_overrides = true;
    defer if (cleanup_overrides) {
        if (dir_override) |d| alloc.free(d);
        if (cmd_override) |c| alloc.free(c);
    };

    switch (gate(is_debug, disable, dir_override != null, cmd_override != null)) {
        .run => {},
        .disabled, .debug_needs_overrides => return,
    }

    const state_path = pathFor(alloc, sessions_file) orelse return;
    var state_path_owned = true;
    defer if (state_path_owned) alloc.free(state_path);

    const st = load(alloc, state_path);
    if (st.done) return;

    const install_dir: []u8 = dir_override orelse blk: {
        const local = getEnv(alloc, "LOCALAPPDATA") orelse return;
        defer alloc.free(local);
        break :blk std.fs.path.join(alloc, &.{ local, "Programs", "Ghoztty Agent" }) catch return;
    };
    var install_dir_owned = dir_override == null;
    defer if (install_dir_owned) alloc.free(install_dir);

    std.fs.accessAbsolute(install_dir, .{}) catch return; // nothing to adopt

    const ctx = alloc.create(Ctx) catch return;
    const sf_dup = alloc.dupe(u8, sessions_file.?) catch {
        alloc.destroy(ctx);
        return;
    };
    const runkey = if (getEnv(alloc, env_runkey_name)) |n| n else (alloc.dupe(u8, default_runkey_name) catch {
        alloc.free(sf_dup);
        alloc.destroy(ctx);
        return;
    });
    const interval: u64 = if (getEnv(alloc, env_interval)) |v| blk: {
        defer alloc.free(v);
        break :blk std.fmt.parseInt(u64, v, 10) catch default_poll_interval_ms;
    } else default_poll_interval_ms;

    ctx.* = .{
        .alloc = alloc,
        .state_path = state_path,
        .state = st,
        .install_dir = install_dir,
        .sessions_file = sf_dup,
        .uninstall_cmd = cmd_override,
        .runkey_name = runkey,
        .interval_ms = interval,
    };
    // The ctx owns these now; keep the defers off them.
    state_path_owned = false;
    install_dir_owned = false;
    cleanup_overrides = false;
    if (dir_override != null) {
        // install_dir IS dir_override — owned by ctx via install_dir.
        dir_override = null;
    }
    cmd_override = null;

    if (std.Thread.spawn(.{}, run, .{ctx})) |t| {
        t.detach();
    } else |err| {
        say("thread spawn failed ({s}); will retry at the next agent start", .{@errorName(err)});
        // One-shot leak of ctx on this rare path; the next start retries.
    }
}

fn run(ctx: *Ctx) void {
    if (comptime builtin.os.tag != .windows) return;
    const alloc = ctx.alloc;
    say("standalone agent install detected at '{s}'; adopting (T549)", .{ctx.install_dir});

    // 1. Sharing continuity: the box was serving via the standalone agent, so
    //    the consolidated agent must keep serving — unless the user already
    //    said no in sharing.json, which adoption respects.
    if (!ctx.state.sharing_marked) {
        if (sharing.pathFor(alloc, ctx.sessions_file)) |spath| {
            defer alloc.free(spath);
            const exists = blk: {
                std.fs.accessAbsolute(spath, .{}) catch break :blk false;
                break :blk true;
            };
            if (exists and !sharing.load(alloc, spath).enabled) {
                say("sharing.json already says disabled; respecting the opt-out", .{});
            } else {
                sharing.save(alloc, spath, .{ .enabled = true }) catch |err| {
                    say("could not mark sharing enabled ({s}); continuing", .{@errorName(err)});
                };
                say("sharing marked enabled (this machine was already serving)", .{});
            }
            ctx.state.sharing_marked = true;
            save(alloc, ctx.state_path, ctx.state) catch {};
        }
    }

    // 2. Idle-stop: wait for the standalone agent (if running) to have zero
    //    live sessions, then stop it. Its store is in-memory; a stop at idle
    //    loses nothing.
    var idle_streak: u32 = 0;
    var said_waiting = false;
    while (win.findAgentUnder(alloc, ctx.install_dir)) |pid| {
        const entries = win.snapshotEntries(alloc) orelse {
            // No snapshot → cannot prove idle → conservative wait.
            idle_streak = 0;
            std.Thread.sleep(ctx.interval_ms * std.time.ns_per_ms);
            continue;
        };
        defer alloc.free(entries);
        const busy = busyDescendantCount(entries, pid);
        if (busy > 0) {
            idle_streak = 0;
            if (!said_waiting) {
                said_waiting = true;
                say("standalone agent (pid {d}) has {d} live session process(es); waiting for idle before stopping it", .{ pid, busy });
            }
        } else {
            idle_streak += 1;
            if (idle_streak >= idle_polls_needed) {
                if (win.terminatePid(pid)) {
                    say("standalone agent (pid {d}) idle; stopped it", .{pid});
                } else {
                    say("could not stop the standalone agent (pid {d}); the uninstall will finish the job", .{pid});
                }
                break;
            }
        }
        std.Thread.sleep(ctx.interval_ms * std.time.ns_per_ms);
    }

    // 3. Uninstall, shielded. The MSI's KillAgentCA terminates every
    //    ghoztty-agent.exe by basename — including US, and with us every live
    //    local shell — so refuse to run it without the shield.
    const pre_value = win.readRunValue(alloc, ctx.runkey_name);
    defer if (pre_value) |v| alloc.free(v);

    var shield = win.Shield.raise() orelse {
        say("could not shield this agent from the MSI's kill-by-name; NOT uninstalling now (retried at the next agent start)", .{});
        return;
    };

    var ok = true;
    if (ctx.uninstall_cmd) |cmd| {
        const exit = win.runCommandLine(alloc, cmd, uninstall_wait_ms);
        ok = exit != null and exit.? == 0;
        say("uninstall override ran (exit={?d})", .{exit});
    } else {
        var product_buf: [16][38]u8 = undefined;
        const products = win.relatedProducts(&product_buf);
        if (products == 0) {
            say("no MSI product registered under the agent UpgradeCode; leaving the files at '{s}' alone", .{ctx.install_dir});
        }
        var i: usize = 0;
        while (i < products) : (i += 1) {
            const code = product_buf[i][0..38];
            var line_buf: [96]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "msiexec.exe /x {s} /qn", .{code}) catch unreachable;
            const exit = win.runCommandLine(alloc, line, uninstall_wait_ms);
            // 0 = done, 3010 = done + reboot wanted; anything else is a miss.
            const this_ok = exit != null and (exit.? == 0 or exit.? == 3010);
            say("msiexec /x {s} → exit={?d}", .{ code, exit });
            ok = ok and this_ok;
        }
    }
    shield.lower();

    // 4. Run-key repair: the uninstall removes the contested value even when
    //    the app owned its data; put the right command back.
    const post = win.readRunValue(alloc, ctx.runkey_name);
    const post_exists = post != null;
    if (post) |v| alloc.free(v);
    switch (runKeyAction(pre_value, post_exists, ctx.install_dir)) {
        .leave => {},
        .restore_snapshot => {
            if (win.writeRunValue(alloc, ctx.runkey_name, pre_value.?)) {
                say("restored the '{s}' Run entry the uninstall removed", .{ctx.runkey_name});
            } else {
                say("could not restore the '{s}' Run entry; the app rewrites it on its next launch", .{ctx.runkey_name});
            }
        },
        .write_own => {
            if (composeOwnCommand(alloc)) |cmd| {
                defer alloc.free(cmd);
                if (win.writeRunValue(alloc, ctx.runkey_name, cmd)) {
                    say("pointed the '{s}' Run entry at this agent (the retired one owned it)", .{ctx.runkey_name});
                }
            } else |_| {}
        },
    }

    if (ok) {
        ctx.state.done = true;
        save(alloc, ctx.state_path, ctx.state) catch {};
        say("adoption complete; the standalone install is retired", .{});
    } else {
        say("uninstall did not fully succeed; adoption will retry at the next agent start", .{});
    }
}

fn composeOwnCommand(alloc: Allocator) ![]u8 {
    // This command line goes into the Run key, so "our own exe" had better be
    // the agent: a test binary would register the TEST RUNNER to start at every
    // logon (T933). The caller treats a failure here as "leave the Run entry
    // alone", which is the only sane answer in a test build.
    const exe = try internal_os.self_exe.productExePathAlloc(alloc);
    defer alloc.free(exe);
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    return quoteCommandLine(alloc, exe, if (args.len > 1) @ptrCast(args[1..]) else &.{});
}

// -----------------------------------------------------------------------------
// Win32 surface: process scan/stop, registry snapshot/restore, the
// deny-terminate shield, MSI product enumeration, raw command execution.

const win = if (builtin.os.tag == .windows) struct {
    const W = std.os.windows;
    const DWORD = W.DWORD;
    const HANDLE = W.HANDLE;
    const BOOL = W.BOOL;
    const UINT = c_uint;

    const TH32CS_SNAPPROCESS: DWORD = 0x2;
    const PROCESS_TERMINATE: DWORD = 0x0001;
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
    const CREATE_NO_WINDOW: DWORD = 0x08000000;
    const ERROR_SUCCESS: DWORD = 0;
    const ERROR_NO_MORE_ITEMS: UINT = 259;

    const PROCESSENTRY32W = extern struct {
        dwSize: DWORD,
        cntUsage: DWORD,
        th32ProcessID: DWORD,
        th32DefaultHeapID: usize,
        th32ModuleID: DWORD,
        cntThreads: DWORD,
        th32ParentProcessID: DWORD,
        pcPriClassBase: i32,
        dwFlags: DWORD,
        szExeFile: [260]u16,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
    extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: ?[*:0]u16,
        lpProcessAttributes: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *W.STARTUPINFOW,
        lpProcessInformation: *W.PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;

    extern "advapi32" fn RegOpenKeyExW(hKey: ?*anyopaque, lpSubKey: [*:0]const u16, ulOptions: DWORD, samDesired: DWORD, phkResult: *?*anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn RegQueryValueExW(hKey: ?*anyopaque, lpValueName: [*:0]const u16, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?[*]u8, lpcbData: ?*DWORD) callconv(.winapi) DWORD;
    extern "advapi32" fn RegSetValueExW(hKey: ?*anyopaque, lpValueName: [*:0]const u16, Reserved: DWORD, dwType: DWORD, lpData: [*]const u8, cbData: DWORD) callconv(.winapi) DWORD;
    extern "advapi32" fn RegCloseKey(hKey: ?*anyopaque) callconv(.winapi) DWORD;

    extern "advapi32" fn GetSecurityInfo(handle: HANDLE, ObjectType: c_int, SecurityInfo: DWORD, ppsidOwner: ?*?*anyopaque, ppsidGroup: ?*?*anyopaque, ppDacl: ?*?*anyopaque, ppSacl: ?*?*anyopaque, ppSecurityDescriptor: ?*?*anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn SetSecurityInfo(handle: HANDLE, ObjectType: c_int, SecurityInfo: DWORD, psidOwner: ?*anyopaque, psidGroup: ?*anyopaque, pDacl: ?*anyopaque, pSacl: ?*anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn SetEntriesInAclW(cCount: c_ulong, pEntries: *EXPLICIT_ACCESS_W, OldAcl: ?*anyopaque, NewAcl: *?*anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn AllocateAndInitializeSid(auth: *const [6]u8, count: u8, s0: DWORD, s1: DWORD, s2: DWORD, s3: DWORD, s4: DWORD, s5: DWORD, s6: DWORD, s7: DWORD, sid: *?*anyopaque) callconv(.winapi) BOOL;
    extern "advapi32" fn FreeSid(pSid: ?*anyopaque) callconv(.winapi) ?*anyopaque;

    extern "msi" fn MsiEnumRelatedProductsW(lpUpgradeCode: [*:0]const u16, dwReserved: DWORD, iProductIndex: DWORD, lpProductBuf: [*]u16) callconv(.winapi) UINT;

    const TRUSTEE_W = extern struct {
        pMultipleTrustee: ?*anyopaque,
        MultipleTrusteeOperation: c_int,
        TrusteeForm: c_int,
        TrusteeType: c_int,
        ptstrName: ?*anyopaque,
    };
    const EXPLICIT_ACCESS_W = extern struct {
        grfAccessPermissions: DWORD,
        grfAccessMode: c_int,
        grfInheritance: DWORD,
        Trustee: TRUSTEE_W,
    };

    const SE_KERNEL_OBJECT: c_int = 6;
    const DACL_SECURITY_INFORMATION: DWORD = 4;
    const DENY_ACCESS: c_int = 3;
    const TRUSTEE_IS_SID: c_int = 0;
    const TRUSTEE_IS_WELL_KNOWN_GROUP: c_int = 5;

    const run_subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Run",
    );
    const HKEY_CURRENT_USER: ?*anyopaque = @ptrFromInt(0x80000001);
    const KEY_QUERY_VALUE: DWORD = 0x0001;
    const KEY_SET_VALUE: DWORD = 0x0002;
    const REG_SZ: DWORD = 1;
    const REG_EXPAND_SZ: DWORD = 2;

    fn eqlIgnoreCaseW(a: []const u16, b: []const u16) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const la = if (ca < 128) std.ascii.toLower(@intCast(ca)) else ca;
            const lb = if (cb < 128) std.ascii.toLower(@intCast(cb)) else cb;
            if (la != lb) return false;
        }
        return true;
    }

    const agent_exe_w = std.unicode.utf8ToUtf16LeStringLiteral("ghoztty-agent.exe");
    const conhost_w = std.unicode.utf8ToUtf16LeStringLiteral("conhost.exe");
    const openconsole_w = std.unicode.utf8ToUtf16LeStringLiteral("openconsole.exe");

    /// Find a running ghoztty-agent.exe whose full image path sits under
    /// `install_dir` — matching by PATH, so only the standalone install's own
    /// process is ever a candidate, never this one or any other agent.
    fn findAgentUnder(alloc: Allocator, install_dir: []const u8) ?u32 {
        const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == W.INVALID_HANDLE_VALUE) return null;
        defer _ = CloseHandle(snap);

        var entry: PROCESSENTRY32W = undefined;
        entry.dwSize = @sizeOf(PROCESSENTRY32W);
        var ok = Process32FirstW(snap, &entry);
        while (ok != 0) : (ok = Process32NextW(snap, &entry)) {
            const name = std.mem.sliceTo(&entry.szExeFile, 0);
            if (!eqlIgnoreCaseW(name, agent_exe_w)) continue;
            const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID) orelse continue;
            defer _ = CloseHandle(h);
            var path_buf: [W.PATH_MAX_WIDE]u16 = undefined;
            var n: DWORD = @intCast(path_buf.len);
            if (QueryFullProcessImageNameW(h, 0, &path_buf, &n) == 0) continue;
            const path = std.unicode.utf16LeToUtf8Alloc(alloc, path_buf[0..n]) catch continue;
            defer alloc.free(path);
            if (path.len > install_dir.len and
                std.ascii.startsWithIgnoreCase(path, install_dir) and
                (path[install_dir.len] == '\\' or path[install_dir.len] == '/'))
            {
                return entry.th32ProcessID;
            }
        }
        return null;
    }

    /// One process-table snapshot as pure entries for `busyDescendantCount`.
    fn snapshotEntries(alloc: Allocator) ?[]ProcEntry {
        const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == W.INVALID_HANDLE_VALUE) return null;
        defer _ = CloseHandle(snap);

        var list: std.ArrayList(ProcEntry) = .empty;
        errdefer list.deinit(alloc);
        var entry: PROCESSENTRY32W = undefined;
        entry.dwSize = @sizeOf(PROCESSENTRY32W);
        var ok = Process32FirstW(snap, &entry);
        while (ok != 0) : (ok = Process32NextW(snap, &entry)) {
            const name = std.mem.sliceTo(&entry.szExeFile, 0);
            list.append(alloc, .{
                .pid = entry.th32ProcessID,
                .ppid = entry.th32ParentProcessID,
                .conpty_plumbing = eqlIgnoreCaseW(name, conhost_w) or eqlIgnoreCaseW(name, openconsole_w),
            }) catch return null;
        }
        return list.toOwnedSlice(alloc) catch null;
    }

    fn terminatePid(pid: u32) bool {
        const h = OpenProcess(PROCESS_TERMINATE, 0, pid) orelse return false;
        defer _ = CloseHandle(h);
        if (TerminateProcess(h, 1) == 0) return false;
        _ = WaitForSingleObject(h, 5_000);
        return true;
    }

    /// Read `HKCU\...\Run\<name>` (REG_SZ/REG_EXPAND_SZ) as UTF-8, or null.
    fn readRunValue(alloc: Allocator, name: []const u8) ?[]u8 {
        var key: ?*anyopaque = null;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, run_subkey, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return null;
        defer _ = RegCloseKey(key);
        const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return null;
        defer alloc.free(name_w);
        var buf: [8192]u8 align(2) = undefined;
        var cb: DWORD = buf.len;
        var vtype: DWORD = 0;
        if (RegQueryValueExW(key, name_w, null, &vtype, &buf, &cb) != ERROR_SUCCESS) return null;
        if (vtype != REG_SZ and vtype != REG_EXPAND_SZ) return null;
        const wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, buf[0..cb]));
        const trimmed = std.mem.sliceTo(wide, 0);
        return std.unicode.utf16LeToUtf8Alloc(alloc, trimmed) catch null;
    }

    fn writeRunValue(alloc: Allocator, name: []const u8, data: []const u8) bool {
        var key: ?*anyopaque = null;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, run_subkey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return false;
        defer _ = RegCloseKey(key);
        const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch return false;
        defer alloc.free(name_w);
        const data_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, data) catch return false;
        defer alloc.free(data_w);
        return RegSetValueExW(
            key,
            name_w,
            0,
            REG_SZ,
            @ptrCast(data_w.ptr),
            @intCast((data_w.len + 1) * 2),
        ) == ERROR_SUCCESS;
    }

    /// The deny-PROCESS_TERMINATE shield: a deny ACE for Everyone prepended to
    /// this process's DACL, restored by `lower`. While raised, the MSI's
    /// kill-by-basename custom action (and anything else opening us with
    /// PROCESS_TERMINATE, same-user and unelevated) is refused.
    const Shield = struct {
        sd: ?*anyopaque,
        old_dacl: ?*anyopaque,
        new_dacl: ?*anyopaque,
        sid: ?*anyopaque,

        fn raise() ?Shield {
            var old_dacl: ?*anyopaque = null;
            var sd: ?*anyopaque = null;
            if (GetSecurityInfo(
                GetCurrentProcess(),
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                null,
                null,
                &old_dacl,
                null,
                &sd,
            ) != ERROR_SUCCESS) return null;

            // Everyone (S-1-1-0): the deny must cover msiexec however it runs.
            const world_authority: [6]u8 = .{ 0, 0, 0, 0, 0, 1 };
            var everyone: ?*anyopaque = null;
            if (AllocateAndInitializeSid(&world_authority, 1, 0, 0, 0, 0, 0, 0, 0, 0, &everyone) == 0) {
                _ = LocalFree(sd);
                return null;
            }

            var deny: EXPLICIT_ACCESS_W = .{
                .grfAccessPermissions = PROCESS_TERMINATE,
                .grfAccessMode = DENY_ACCESS,
                .grfInheritance = 0,
                .Trustee = .{
                    .pMultipleTrustee = null,
                    .MultipleTrusteeOperation = 0,
                    .TrusteeForm = TRUSTEE_IS_SID,
                    .TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP,
                    .ptstrName = everyone,
                },
            };
            var new_dacl: ?*anyopaque = null;
            if (SetEntriesInAclW(1, &deny, old_dacl, &new_dacl) != ERROR_SUCCESS) {
                _ = FreeSid(everyone);
                _ = LocalFree(sd);
                return null;
            }
            if (SetSecurityInfo(
                GetCurrentProcess(),
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                null,
                null,
                new_dacl,
                null,
            ) != ERROR_SUCCESS) {
                _ = LocalFree(new_dacl);
                _ = FreeSid(everyone);
                _ = LocalFree(sd);
                return null;
            }
            return .{ .sd = sd, .old_dacl = old_dacl, .new_dacl = new_dacl, .sid = everyone };
        }

        fn lower(self: *Shield) void {
            _ = SetSecurityInfo(
                GetCurrentProcess(),
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                null,
                null,
                self.old_dacl,
                null,
            );
            _ = LocalFree(self.new_dacl);
            _ = FreeSid(self.sid);
            _ = LocalFree(self.sd);
            self.* = undefined;
        }
    };

    /// Every registered product carrying the standalone agent's UpgradeCode,
    /// as `{GUID}` strings into `buf`. Returns how many.
    fn relatedProducts(buf: *[16][38]u8) usize {
        const code_w = std.unicode.utf8ToUtf16LeStringLiteral(upgrade_code);
        var count: usize = 0;
        var index: DWORD = 0;
        while (count < buf.len) : (index += 1) {
            var product_w: [39]u16 = undefined;
            const rc = MsiEnumRelatedProductsW(code_w, 0, index, &product_w);
            if (rc != ERROR_SUCCESS) break;
            const wide = std.mem.sliceTo(&product_w, 0);
            if (wide.len != 38) continue;
            for (wide, 0..) |c, i| buf[count][i] = @intCast(c & 0x7f);
            count += 1;
        }
        return count;
    }

    /// Run a raw command line (no shell) with no window; wait bounded.
    /// Returns the exit code, or null on spawn/wait failure.
    fn runCommandLine(alloc: Allocator, line_utf8: []const u8, timeout_ms: u32) ?u32 {
        const line_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, line_utf8) catch return null;
        defer alloc.free(line_w);
        var si: W.STARTUPINFOW = std.mem.zeroes(W.STARTUPINFOW);
        si.cb = @sizeOf(W.STARTUPINFOW);
        var pi: W.PROCESS_INFORMATION = undefined;
        if (CreateProcessW(null, line_w.ptr, null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi) == 0)
            return null;
        defer _ = CloseHandle(pi.hThread);
        defer _ = CloseHandle(pi.hProcess);
        if (WaitForSingleObject(pi.hProcess, timeout_ms) != 0) return null;
        var exit: DWORD = 0;
        if (GetExitCodeProcess(pi.hProcess, &exit) == 0) return null;
        return exit;
    }
} else struct {};

// =============================================================================
// Tests (pure logic only — runs in the test-agent lane on any host).
// =============================================================================

const testing = std.testing;

test "gate: disabled wins over everything" {
    try testing.expectEqual(Gate.disabled, gate(false, true, true, true));
    try testing.expectEqual(Gate.disabled, gate(true, true, true, true));
}

test "gate: a debug build needs BOTH overrides" {
    try testing.expectEqual(Gate.debug_needs_overrides, gate(true, false, false, false));
    try testing.expectEqual(Gate.debug_needs_overrides, gate(true, false, true, false));
    try testing.expectEqual(Gate.debug_needs_overrides, gate(true, false, false, true));
    try testing.expectEqual(Gate.run, gate(true, false, true, true));
}

test "gate: a release build runs with no overrides" {
    try testing.expectEqual(Gate.run, gate(false, false, false, false));
    try testing.expectEqual(Gate.run, gate(false, false, true, true));
}

test "state: parse round-trips and tolerates junk" {
    try testing.expect(parse(testing.allocator, "{\"version\":1,\"done\":true,\"sharing_marked\":true}").done);
    try testing.expect(!parse(testing.allocator, "").done);
    try testing.expect(!parse(testing.allocator, "not json").done);
    try testing.expect(!parse(testing.allocator, "{\"done\":\"yes\"}").done);
    const st = parse(testing.allocator, "{\"version\":9,\"sharing_marked\":true,\"future\":1}");
    try testing.expect(st.sharing_marked and !st.done);
}

test "state: save + load round-trip through a real file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, file_name });
    defer testing.allocator.free(path);

    try save(testing.allocator, path, .{ .done = true, .sharing_marked = true });
    const st = load(testing.allocator, path);
    try testing.expect(st.done and st.sharing_marked);
}

test "pathFor: beside the sessions file, none without one" {
    const p = pathFor(testing.allocator, "/state/dir/sessions.json") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(p);
    try testing.expect(std.mem.endsWith(u8, p, file_name));
    try testing.expectEqual(@as(?[]u8, null), pathFor(testing.allocator, null));
}

test "busyDescendantCount: idle agent has none; a shell counts; plumbing does not" {
    // 100 = the agent; 200 = its conhost; 300 = unrelated.
    const idle = [_]ProcEntry{
        .{ .pid = 100, .ppid = 1 },
        .{ .pid = 200, .ppid = 100, .conpty_plumbing = true },
        .{ .pid = 300, .ppid = 1 },
    };
    try testing.expectEqual(@as(u32, 0), busyDescendantCount(&idle, 100));

    // A session shell (400) under the agent counts, and so does its child.
    const busy = [_]ProcEntry{
        .{ .pid = 100, .ppid = 1 },
        .{ .pid = 200, .ppid = 100, .conpty_plumbing = true },
        .{ .pid = 400, .ppid = 100 },
        .{ .pid = 500, .ppid = 400 },
    };
    try testing.expectEqual(@as(u32, 2), busyDescendantCount(&busy, 100));
}

test "busyDescendantCount: a shell under plumbing still counts" {
    // ConPTY shape: agent → conhost → shell. The shell is real work even
    // though its direct parent is plumbing.
    const entries = [_]ProcEntry{
        .{ .pid = 100, .ppid = 1 },
        .{ .pid = 200, .ppid = 100, .conpty_plumbing = true },
        .{ .pid = 300, .ppid = 200 },
    };
    try testing.expectEqual(@as(u32, 1), busyDescendantCount(&entries, 100));
}

test "busyDescendantCount: cycles terminate and root 0 is never busy" {
    const cyclic = [_]ProcEntry{
        .{ .pid = 100, .ppid = 1 },
        .{ .pid = 200, .ppid = 300 },
        .{ .pid = 300, .ppid = 200 },
    };
    try testing.expectEqual(@as(u32, 0), busyDescendantCount(&cyclic, 100));
    try testing.expectEqual(@as(u32, 0), busyDescendantCount(&cyclic, 0));
}

test "runKeyAction: survives → leave; deleted app value → restore; standalone value → write own" {
    const dir = "C:\\Users\\x\\AppData\\Local\\Programs\\Ghoztty Agent";
    // Value still there after the uninstall: leave it alone.
    try testing.expectEqual(RunKeyAction.leave, runKeyAction("\"C:\\app\\agent.exe\" --listen-pipe=x", true, dir));
    // Nothing existed before: nothing was deleted.
    try testing.expectEqual(RunKeyAction.leave, runKeyAction(null, false, dir));
    // App-owned value deleted: put the snapshot back.
    try testing.expectEqual(RunKeyAction.restore_snapshot, runKeyAction("\"C:\\app\\agent.exe\" --listen-pipe=x", false, dir));
    // Standalone-owned value deleted: restoring would resurrect a dead
    // command; write our own instead (case-insensitive match).
    try testing.expectEqual(RunKeyAction.write_own, runKeyAction("\"c:\\users\\x\\appdata\\local\\programs\\ghoztty agent\\ghoztty-agent.exe\" --relay=url", false, dir));
}

test "quoteCommandLine: every token quoted" {
    const cmd = try quoteCommandLine(testing.allocator, "C:\\a b\\agent.exe", &.{ "--listen-pipe=p", "--headless" });
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("\"C:\\a b\\agent.exe\" \"--listen-pipe=p\" \"--headless\"", cmd);
    const bare = try quoteCommandLine(testing.allocator, "x.exe", &.{});
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("\"x.exe\"", bare);
}
