//! T42 — give a spawned shell the environment an interactive logon would
//! have, on Windows, instead of whatever the *spawning process* happened to
//! inherit.
//!
//! ## The defect this exists for
//!
//! `ghoztty-agent` owns every session-persistence and every cross-machine
//! PTY, and each child's environment is a clone of the AGENT PROCESS's
//! environment (`remote/agent/pty_child.zig`). That environment is a snapshot
//! taken from whoever started the agent — an HKCU `Run` entry, a scheduled
//! task, an SSH bridge, an MSI custom action, a self-update relaunch. None of
//! those is guaranteed to carry the interactive user's `Path`, and a
//! cross-machine OPEN forwards no env at all (`open.env` is empty by design:
//! the far machine may be a different OS). The user-visible symptom, reported
//! 2026-07-13: a remote Windows session opened from the Mac had **none of the
//! user's PATH entries** — no `ghoztty`, no user-scope tooling.
//!
//! The same class of staleness already bit the working directory: an agent
//! started by the `Run` entry inherits `C:\WINDOWS\system32` as its cwd
//! (`termio/Remote.zig:openWorkingDirectory`). This is that lesson applied to
//! the environment block.
//!
//! ## The rule: ADDITIVE ONLY
//!
//! Windows composes a logon environment from two registry keys — HKLM
//! `…\Session Manager\Environment` (system) and HKCU `Environment` (user) —
//! with `Path` **concatenated** system-then-user and everything else
//! user-wins. This module reads the same two keys, but it never *weakens* the
//! environment the process already has:
//!
//!   - `Path` is MERGED: the process's own value first, then the registry
//!     entries it is missing (case-insensitive, `path_env.normalize`).
//!     Existing entries keep their position, so a harness that deliberately
//!     prepends a shim directory still shadows what it meant to shadow.
//!   - Every other registry variable is applied **only if the process
//!     environment does not already define it** (user key before system key,
//!     matching logon precedence).
//!
//! The defect is *absence*, not staleness, and the agent's own environment is
//! authoritative for anything it already carries. Being additive is what makes
//! this safe to run on every spawn (which is also what keeps it FRESH: a PATH
//! edit made after the agent started is picked up by the next session, where a
//! once-at-startup overlay would inherit the same staleness it is fixing).
//!
//! `GHOZTTY_USER_ENV=0` / `=off` disables the overlay entirely (escape hatch +
//! the negative control in `test/win32/agent-user-env.ps1`).
//!
//! Windows-only by construction: POSIX has no registry, and a POSIX agent
//! spawns its shell login+interactive (`-lic`), which is that platform's way
//! of getting the user's real environment.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const path_env = @import("path_env.zig");

const log = std.log.scoped(.user_env);

/// One registry environment variable. `key`/`value` are borrowed from the
/// caller's arena.
pub const Var = struct {
    key: []const u8,
    value: []const u8,
};

/// The environment variable whose registry values are concatenated rather than
/// overridden. Windows only does this for `Path`.
const path_key = "Path";

// -------------------------------------------------------------------------
// Pure logic (no OS calls — unit-tested in every lane)
// -------------------------------------------------------------------------

/// Join `parts` — each a `;`-separated PATH value — into one value, in order,
/// dropping empty segments and case-insensitive duplicates. Entries keep their
/// original spelling; only the comparison is normalized. Caller owns the
/// result.
pub fn mergePath(alloc: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Normalized forms of what we have emitted, for the dedupe. PATHs are
    // dozens of entries, so a linear scan beats a hash map's setup.
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);

    for (parts) |part| {
        var it = std.mem.splitScalar(u8, part, ';');
        while (it.next()) |entry| {
            const norm = path_env.normalize(entry);
            if (norm.len == 0) continue;

            var dup = false;
            for (seen.items) |s| {
                if (std.ascii.eqlIgnoreCase(s, norm)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try seen.append(alloc, norm);

            if (out.items.len > 0) try out.append(alloc, ';');
            try out.appendSlice(alloc, std.mem.trim(u8, entry, " \t"));
        }
    }

    return out.toOwnedSlice(alloc);
}

/// The key `env` already uses for `name`, in ITS spelling, or null. Compared
/// ASCII-case-insensitively because Windows environment names are — and
/// because `std.process.EnvMap` is only case-insensitive when the *host* is
/// Windows, which would make this module's behavior differ between the two
/// seats' test lanes.
fn existingKey(env: *const std.process.EnvMap, name: []const u8) ?[]const u8 {
    var it = env.iterator();
    while (it.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) return kv.key_ptr.*;
    }
    return null;
}

/// Overlay registry variables onto `env` additively (see the module header).
/// `system` and `user` are the HKLM and HKCU sets, in registry order.
pub fn applyAdditive(
    alloc: Allocator,
    env: *std.process.EnvMap,
    system: []const Var,
    user: []const Var,
) !void {
    // 1. Path: existing value first, then system, then user. The existing key
    //    keeps its spelling so we replace rather than shadow it.
    const existing_path_key = existingKey(env, path_key);
    const current_path: []const u8 =
        if (existing_path_key) |k| env.get(k) orelse "" else "";

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    if (current_path.len > 0) try parts.append(alloc, current_path);
    for ([_][]const Var{ system, user }) |set| {
        for (set) |v| {
            if (std.ascii.eqlIgnoreCase(v.key, path_key)) try parts.append(alloc, v.value);
        }
    }
    if (parts.items.len > 1) {
        const merged = try mergePath(alloc, parts.items);
        defer alloc.free(merged);
        try env.put(existing_path_key orelse path_key, merged);
    } else if (parts.items.len == 1 and existing_path_key == null) {
        try env.put(path_key, parts.items[0]);
    }

    // 2. Everything else: only what the process environment is missing. User
    //    before system so the user key wins a key both define, matching how
    //    Windows composes a logon environment.
    for ([_][]const Var{ user, system }) |set| {
        for (set) |v| {
            if (v.key.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(v.key, path_key)) continue;
            if (existingKey(env, v.key) != null) continue;
            try env.put(v.key, v.value);
        }
    }
}

/// Whether `GHOZTTY_USER_ENV` turns the overlay off. Split out so the
/// spelling is asserted rather than described.
pub fn disabledBy(value: ?[]const u8) bool {
    const v = value orelse return false;
    return std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off");
}

/// Build the `lpEnvironment` block `CreateProcessW` wants when
/// `CREATE_UNICODE_ENVIRONMENT` is set: `name=value` pairs in UTF-16, each
/// NUL-terminated, the whole block terminated by an extra NUL — and, a
/// documented CreateProcessW requirement std's `createWindowsEnvBlock` skips,
/// **sorted case-insensitively by name**. Pure (no OS calls), so the shape is
/// unit-tested in every lane. Caller owns the result.
pub fn createEnvBlockW(alloc: Allocator, env: *const std.process.EnvMap) ![]u16 {
    const Entry = struct {
        key: []const u8,
        value: []const u8,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            const n = @min(a.key.len, b.key.len);
            for (a.key[0..n], b.key[0..n]) |ac, bc| {
                const au = std.ascii.toUpper(ac);
                const bu = std.ascii.toUpper(bc);
                if (au != bu) return au < bu;
            }
            return a.key.len < b.key.len;
        }
    };

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(alloc);
    var it = env.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.len == 0) continue;
        try entries.append(alloc, .{ .key = kv.key_ptr.*, .value = kv.value_ptr.* });
    }
    std.mem.sort(Entry, entries.items, {}, Entry.lessThan);

    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(alloc);
    for (entries.items) |e| {
        const key_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, e.key);
        defer alloc.free(key_w);
        try out.appendSlice(alloc, key_w);
        try out.append(alloc, '=');
        const value_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, e.value);
        defer alloc.free(value_w);
        try out.appendSlice(alloc, value_w);
        try out.append(alloc, 0);
    }
    try out.append(alloc, 0);
    // An empty environment still needs TWO NULs: CreateProcess reads the
    // second code unit even though the first should suffice.
    if (entries.items.len == 0) try out.append(alloc, 0);
    return out.toOwnedSlice(alloc);
}

// -------------------------------------------------------------------------
// Windows registry plumbing
// -------------------------------------------------------------------------

pub const is_windows = builtin.os.tag == .windows;

const HKEY = *opaque {};
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
const KEY_READ: u32 = 0x00020019;
const REG_SZ: u32 = 1;
const REG_EXPAND_SZ: u32 = 2;
const ERROR_SUCCESS: u32 = 0;
const ERROR_NO_MORE_ITEMS: u32 = 259;

extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    ulOptions: u32,
    samDesired: u32,
    phkResult: *HKEY,
) callconv(.winapi) u32;

extern "advapi32" fn RegEnumValueW(
    hKey: HKEY,
    dwIndex: u32,
    lpValueName: [*]u16,
    lpcchValueName: *u32,
    lpReserved: ?*u32,
    lpType: ?*u32,
    lpData: ?[*]u8,
    lpcbData: ?*u32,
) callconv(.winapi) u32;

extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) u32;

extern "kernel32" fn ExpandEnvironmentStringsW(
    lpSrc: [*:0]const u16,
    lpDst: ?[*]u16,
    nSize: u32,
) callconv(.winapi) u32;

const system_subkey = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment";
const user_subkey = "Environment";

/// Longest environment value we will read out of the registry. A real `Path`
/// is a few KB; the registry allows far more, but a value this large is not an
/// environment variable any shell can use.
const max_value_wchars = 32 * 1024;

/// Read every `REG_SZ`/`REG_EXPAND_SZ` value under `root\subkey`, expanding
/// `REG_EXPAND_SZ` with `ExpandEnvironmentStringsW`. Allocated in `arena`.
/// Returns an empty slice when the key cannot be opened (a locked-down HKLM, a
/// profile with no `Environment` key at all) — absence is not an error here.
fn readKey(arena: Allocator, root: HKEY, comptime subkey: []const u8) ![]Var {
    if (!is_windows) return &.{};

    var key: HKEY = undefined;
    const sub = std.unicode.utf8ToUtf16LeStringLiteral(subkey);
    if (RegOpenKeyExW(root, sub, 0, KEY_READ, &key) != ERROR_SUCCESS) return &.{};
    defer _ = RegCloseKey(key);

    var out: std.ArrayList(Var) = .empty;
    // Registry value names cap at 16383 wchars; +1 for the NUL RegEnumValueW
    // writes but does not count.
    const name_buf = try arena.alloc(u16, 16384);
    const data_buf = try arena.alloc(u16, max_value_wchars);

    var index: u32 = 0;
    while (true) : (index += 1) {
        var name_len: u32 = @intCast(name_buf.len);
        var data_len: u32 = @intCast(data_buf.len * 2);
        var vtype: u32 = 0;
        const rc = RegEnumValueW(
            key,
            index,
            name_buf.ptr,
            &name_len,
            null,
            &vtype,
            @ptrCast(data_buf.ptr),
            &data_len,
        );
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc != ERROR_SUCCESS) {
            // A single oversized/unreadable value must not cost us the rest of
            // the key: step over it.
            log.debug("RegEnumValue({s}, {d}) rc={d}; skipping", .{ subkey, index, rc });
            if (index > 4096) break; // paranoia: never spin forever
            continue;
        }
        if (vtype != REG_SZ and vtype != REG_EXPAND_SZ) continue;
        if (name_len == 0) continue;

        const name = try std.unicode.utf16LeToUtf8Alloc(arena, name_buf[0..name_len]);

        var wide: []const u16 = data_buf[0 .. data_len / 2];
        while (wide.len > 0 and wide[wide.len - 1] == 0) wide = wide[0 .. wide.len - 1];
        if (wide.len == 0) continue;

        const raw = try std.unicode.utf16LeToUtf8Alloc(arena, wide);
        const value = if (vtype == REG_EXPAND_SZ)
            expand(arena, raw) catch raw
        else
            raw;
        if (value.len == 0) continue;

        try out.append(arena, .{ .key = name, .value = value });
    }

    return out.toOwnedSlice(arena);
}

/// Expand `%VAR%` references against the CURRENT process environment, the way
/// the logon composer does for a `REG_EXPAND_SZ`. Returns `src` unchanged when
/// the OS declines to expand it.
fn expand(arena: Allocator, src: []const u8) ![]const u8 {
    if (!is_windows) return src;
    if (std.mem.indexOfScalar(u8, src, '%') == null) return src;

    const src_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, src);
    const need = ExpandEnvironmentStringsW(src_w, null, 0);
    if (need == 0) return src;
    const buf = try arena.alloc(u16, need);
    const written = ExpandEnvironmentStringsW(src_w, buf.ptr, need);
    if (written == 0 or written > need) return src;
    // `written` counts the terminating NUL.
    return std.unicode.utf16LeToUtf8Alloc(arena, buf[0 .. written - 1]);
}

/// Overlay the Windows registry environment onto `env` (see the module
/// header). Best-effort and never fatal: a spawn with a lean environment beats
/// a spawn that failed. No-op off Windows.
pub fn overlay(alloc: Allocator, env: *std.process.EnvMap) void {
    if (!is_windows) return;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const off = std.process.getEnvVarOwned(arena, "GHOZTTY_USER_ENV") catch null;
    if (disabledBy(off)) {
        log.debug("user-env overlay disabled by GHOZTTY_USER_ENV", .{});
        return;
    }

    const system = readKey(arena, HKEY_LOCAL_MACHINE, system_subkey) catch |err| blk: {
        log.warn("reading the system environment key failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    const user = readKey(arena, HKEY_CURRENT_USER, user_subkey) catch |err| blk: {
        log.warn("reading the user environment key failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    if (system.len == 0 and user.len == 0) return;

    applyAdditive(alloc, env, system, user) catch |err| {
        log.warn("applying the user environment failed: {s}", .{@errorName(err)});
    };
}

// -------------------------------------------------------------------------
// Tests (pure — they run in every lane, on both seats)
// -------------------------------------------------------------------------

test "mergePath: order preserved, empties dropped, duplicates removed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const got = try mergePath(alloc, &.{
        "C:\\Windows\\system32;;C:\\Windows",
        "C:\\Windows\\SYSTEM32\\;C:\\Program Files\\Git\\cmd",
        "C:\\Users\\me\\.local\\bin",
    });
    defer alloc.free(got);
    try testing.expectEqualStrings(
        "C:\\Windows\\system32;C:\\Windows;C:\\Program Files\\Git\\cmd;C:\\Users\\me\\.local\\bin",
        got,
    );
}

test "mergePath: a trailing separator and a case difference are the same entry" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const got = try mergePath(alloc, &.{ "c:\\tools\\", "C:\\Tools" });
    defer alloc.free(got);
    try testing.expectEqualStrings("c:\\tools\\", got);
}

test "mergePath: empty input yields an empty value" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const got = try mergePath(alloc, &.{ "", ";; ;" });
    defer alloc.free(got);
    try testing.expectEqualStrings("", got);
}

test "applyAdditive: registry PATH entries are appended, existing ones keep their place" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("Path", "C:\\shim;C:\\Windows\\system32");

    const system = [_]Var{.{ .key = "Path", .value = "C:\\Windows\\system32;C:\\Windows" }};
    const user = [_]Var{.{ .key = "Path", .value = "C:\\Users\\me\\.local\\bin" }};
    try applyAdditive(alloc, &env, &system, &user);

    // The shim stays FIRST (a harness that prepended it still wins), the
    // system entry is not duplicated, and the user entry arrives last.
    try testing.expectEqualStrings(
        "C:\\shim;C:\\Windows\\system32;C:\\Windows;C:\\Users\\me\\.local\\bin",
        env.get("Path").?,
    );
}

test "applyAdditive: the PATH key keeps the spelling the environment already used" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("PATH", "C:\\a");

    const user = [_]Var{.{ .key = "Path", .value = "C:\\b" }};
    try applyAdditive(alloc, &env, &.{}, &user);

    try testing.expectEqualStrings("C:\\a;C:\\b", env.get("PATH").?);
    // No second, differently-spelled PATH: that would leave the child with two
    // and let the loser win depending on how CreateProcess folds them.
    var count: usize = 0;
    var it = env.iterator();
    while (it.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "Path")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "applyAdditive: PATH is created when the environment has none" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    const system = [_]Var{.{ .key = "Path", .value = "C:\\Windows" }};
    try applyAdditive(alloc, &env, &system, &.{});
    try testing.expectEqualStrings("C:\\Windows", env.get("Path").?);
}

test "applyAdditive: a variable the environment already has is never overwritten" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("TEMP", "C:\\deliberate");

    const system = [_]Var{.{ .key = "TEMP", .value = "C:\\Windows\\TEMP" }};
    const user = [_]Var{.{ .key = "temp", .value = "C:\\Users\\me\\Temp" }};
    try applyAdditive(alloc, &env, &system, &user);

    try testing.expectEqualStrings("C:\\deliberate", env.get("TEMP").?);
}

test "applyAdditive: a missing variable is added, user key beating system key" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    const system = [_]Var{
        .{ .key = "TEMP", .value = "C:\\Windows\\TEMP" },
        .{ .key = "PATHEXT", .value = ".COM;.EXE;.BAT" },
    };
    const user = [_]Var{.{ .key = "TEMP", .value = "C:\\Users\\me\\Temp" }};
    try applyAdditive(alloc, &env, &system, &user);

    try testing.expectEqualStrings("C:\\Users\\me\\Temp", env.get("TEMP").?);
    try testing.expectEqualStrings(".COM;.EXE;.BAT", env.get("PATHEXT").?);
}

test "applyAdditive: an empty key never creates a bare =value entry" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    const user = [_]Var{.{ .key = "", .value = "junk" }};
    try applyAdditive(alloc, &env, &.{}, &user);
    try testing.expectEqual(@as(usize, 0), env.count());
}

test "createEnvBlockW: names are sorted case-insensitively, pairs NUL-joined, block double-NUL-terminated" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    // Deliberately inserted out of order; `b` vs `PATH` also checks the sort
    // is case-INSENSITIVE (case-sensitive ordinal would put `PATH` before `b`).
    try env.put("b", "2");
    try env.put("PATH", "C:\\Windows");
    try env.put("A", "1");

    const block = try createEnvBlockW(alloc, &env);
    defer alloc.free(block);

    const expected = std.unicode.utf8ToUtf16LeStringLiteral("A=1\x00b=2\x00PATH=C:\\Windows\x00\x00");
    try testing.expectEqualSlices(u16, expected, block);
}

test "createEnvBlockW: a value containing = survives verbatim" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("X", "a=b;c=d");

    const block = try createEnvBlockW(alloc, &env);
    defer alloc.free(block);

    const expected = std.unicode.utf8ToUtf16LeStringLiteral("X=a=b;c=d\x00\x00");
    try testing.expectEqualSlices(u16, expected, block);
}

test "createEnvBlockW: the empty map is exactly two NULs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();

    const block = try createEnvBlockW(alloc, &env);
    defer alloc.free(block);
    try testing.expectEqualSlices(u16, &[_]u16{ 0, 0 }, block);
}

test "disabledBy: only 0 and off (any case) turn the overlay off" {
    const testing = std.testing;
    try testing.expect(disabledBy("0"));
    try testing.expect(disabledBy("off"));
    try testing.expect(disabledBy("OFF"));
    try testing.expect(!disabledBy(null));
    try testing.expect(!disabledBy("1"));
    try testing.expect(!disabledBy(""));
    try testing.expect(!disabledBy("on"));
}
