//! T70: keep the `ghoztty` CLI resolvable from any shell — the Windows
//! analog of macOS CommandLineInstaller.swift, which self-heals a
//! ~/.local/bin link + profile PATH entry on every launch. Here the
//! master GUI instance checks on a background thread whether the
//! directory it is running from is on the user PATH
//! (HKCU\Environment\Path) and appends it when missing, then broadcasts
//! WM_SETTINGCHANGE so shells launched afterwards see it. Idempotent:
//! an entry present in any spelling (case, trailing "\", quotes, or an
//! unexpanded %VAR% form) is detected and left alone.
//!
//! Deliberately narrower than the Mac flow: it only acts when this
//! process runs from the canonical install directory
//! (%LOCALAPPDATA%\Programs\Ghoztty — where the MSI also writes its own
//! Environment PATH entry), so dev builds (zig-out) and portable unpacks
//! never touch the user PATH. `GHOZTTY_PATH_SELFHEAL=0`/`off` disables
//! the check entirely; `force` skips the install-location gate (test
//! hook for path-selfheal.ps1, which must exercise the flow with a
//! zig-out build).
const std = @import("std");
const w32 = @import("win32.zig");
const path_env = @import("../../os/path_env.zig");

const log = std.log.scoped(.win32_path_installer);

/// Run the self-heal on a detached background thread. Registry access is
/// fast, but the WM_SETTINGCHANGE broadcast can block on unresponsive
/// windows, so none of this belongs on the GUI thread during startup.
pub fn ensureOnPathAsync() void {
    const thread = std.Thread.spawn(.{}, run, .{}) catch |err| {
        log.warn("PATH self-heal: thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn run() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    ensureOnPath(arena_state.allocator()) catch |err| {
        log.warn("PATH self-heal failed: {}", .{err});
    };
}

fn ensureOnPath(arena: std.mem.Allocator) !void {
    const heal_env: ?[]const u8 =
        std.process.getEnvVarOwned(arena, "GHOZTTY_PATH_SELFHEAL") catch null;
    if (heal_env) |v| {
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return;
    }
    const force = if (heal_env) |v| std.ascii.eqlIgnoreCase(v, "force") else false;

    const exe_dir = try std.fs.selfExeDirPathAlloc(arena);

    if (!force) {
        // Location gate: only the canonical install heals the PATH.
        const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return;
        const canonical = try std.fs.path.join(
            arena,
            &.{ local, "Programs", "Ghoztty" },
        );
        if (!path_env.eqlDir(exe_dir, canonical)) return;
    }

    var key: w32.HKEY = undefined;
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Environment");
    if (w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        subkey,
        0,
        w32.KEY_QUERY_VALUE | w32.KEY_SET_VALUE,
        &key,
    ) != w32.ERROR_SUCCESS) return error.RegOpenFailed;
    defer _ = w32.RegCloseKey(key);

    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("Path");

    // Read the current value. A truly clean profile can lack it entirely.
    var vtype: u32 = w32.REG_EXPAND_SZ;
    var raw: []const u8 = "";
    var size: u32 = 0;
    const qrc = w32.RegQueryValueExW(key, value_name, null, &vtype, null, &size);
    if (qrc == w32.ERROR_SUCCESS and size >= 2) {
        const buf = try arena.alloc(u16, (size + 1) / 2);
        var got: u32 = @intCast(buf.len * 2);
        if (w32.RegQueryValueExW(
            key,
            value_name,
            null,
            &vtype,
            @ptrCast(buf.ptr),
            &got,
        ) != w32.ERROR_SUCCESS) return error.RegQueryFailed;
        var wide: []const u16 = buf[0 .. got / 2];
        while (wide.len > 0 and wide[wide.len - 1] == 0) wide = wide[0 .. wide.len - 1];
        raw = try std.unicode.utf16LeToUtf8Alloc(arena, wide);
    } else if (qrc != w32.ERROR_SUCCESS and qrc != w32.ERROR_FILE_NOT_FOUND) {
        return error.RegQueryFailed;
    }

    // Never rewrite a value of a type we don't understand.
    if (vtype != w32.REG_SZ and vtype != w32.REG_EXPAND_SZ) return;

    if (path_env.contains(raw, exe_dir)) return;

    // The entry may be present in %VAR% form (e.g. the MSI could be asked
    // to write %LOCALAPPDATA%-relative values, or the user wrote one):
    // compare against the expanded value too before concluding absence.
    if (raw.len > 0) {
        const raw_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, raw);
        const need = w32.ExpandEnvironmentStringsW(raw_w, null, 0);
        if (need > 0) {
            const ebuf = try arena.alloc(u16, need);
            const written = w32.ExpandEnvironmentStringsW(raw_w, ebuf.ptr, need);
            if (written > 0 and written <= need) {
                const expanded = try std.unicode.utf16LeToUtf8Alloc(
                    arena,
                    ebuf[0 .. written - 1],
                );
                if (path_env.contains(expanded, exe_dir)) return;
            }
        }
    }

    const new_value = try path_env.append(arena, raw, exe_dir);
    const new_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, new_value);
    if (w32.RegSetValueExW(
        key,
        value_name,
        0,
        vtype,
        @ptrCast(new_w.ptr),
        @intCast((new_w.len + 1) * 2),
    ) != w32.ERROR_SUCCESS) return error.RegSetFailed;

    log.info("PATH self-heal: added {s} to the user PATH", .{exe_dir});

    // Nudge Explorer (and anything else listening) so terminals launched
    // from the shell see the new PATH without a sign-out. Timeout-guarded:
    // a hung top-level window must not wedge this thread forever.
    _ = w32.SendMessageTimeoutW(
        w32.HWND_BROADCAST,
        w32.WM_SETTINGCHANGE,
        0,
        @bitCast(@intFromPtr(subkey)),
        w32.SMTO_ABORTIFHUNG,
        1000,
        null,
    );
}
