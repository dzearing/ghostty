//! Where is this exe running from? (T1217)
//!
//! Three copies of Ghoztty live on a developer's box and they are NOT
//! interchangeable:
//!
//!   * the **installed release**, `%LOCALAPPDATA%\Programs\Ghoztty` — what the
//!     MSI writes and what the user's everyday terminal is,
//!   * a **portable unpack** (a Desktop folder, a network share),
//!   * a **dev prefix** (`zig-out`, `zig-out-release`, a worktree).
//!
//! Several behaviors are already keyed on that distinction by hand —
//! `AgentIntegration.setupEnabled`, `PathInstaller` — and T1217 added another:
//! the automatic update check. Two things made that a bug rather than a
//! preference. The loop's morning refresh writes a script-built exe over the
//! installed release, so "was this exe produced by the MSI pipeline" (the
//! `-Dwindows-update-check` build flag) stopped being the same question as "is
//! this the user's installed terminal" — on 2026-08-31 a terminal installed
//! from the website at 07:08 could no longer find updates at 07:49, with
//! nothing on screen to say so. And the same staging bytes are ALSO delivered
//! to the portable locations, where phoning home is deliberately not wanted,
//! so the answer could not simply be moved into the build.
//!
//! It has to be about where the exe IS, so it lives here — pure and testable —
//! instead of being spelled out a fourth time at the call site.
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../../build_config.zig");
const path_env = @import("../../os/path_env.zig");

/// The install directory's tail, under `%LOCALAPPDATA%`.
pub const install_subdir = "Programs\\Ghoztty";

/// Whether `exe_dir` IS the installed-release directory for a machine whose
/// `%LOCALAPPDATA%` is `local_app_data`.
///
/// Exact directory match, not a prefix match: a `zig-out` inside a checkout
/// that happens to sit under LOCALAPPDATA is not an install, and neither is a
/// subfolder of the install. Case-insensitive, trailing separators ignored,
/// and `/` reads as `\`, like Windows path resolution.
pub fn isInstallDir(exe_dir: []const u8, local_app_data: []const u8) bool {
    const local = path_env.normalize(local_app_data);
    if (local.len == 0) return false;
    const dir = path_env.normalize(exe_dir);
    if (dir.len <= local.len) return false;
    if (!eqlPathIgnoreSep(dir[0..local.len], local)) return false;

    var rest = dir[local.len..];
    // The separator between LOCALAPPDATA and the tail. `normalize` already
    // stripped a trailing one from `local` — except at a drive root ("C:\"),
    // which keeps its separator, so there is none left to consume there.
    if (rest.len > 0 and (rest[0] == '\\' or rest[0] == '/')) {
        rest = rest[1..];
    } else if (!(local.len == 3 and local[1] == ':')) {
        return false;
    }
    return eqlPathIgnoreSep(rest, install_subdir);
}

/// ASCII case-insensitive path compare that treats `/` and `\` as the same
/// separator, so a path that reached us through a POSIX-ish API still matches.
fn eqlPathIgnoreSep(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '/') '\\' else std.ascii.toLower(ca);
        const nb = if (cb == '/') '\\' else std.ascii.toLower(cb);
        if (na != nb) return false;
    }
    return true;
}

/// Runtime form: is the RUNNING executable the installed release?
///
/// Allocates from `arena` (nothing is freed individually). Answers false
/// rather than erroring when either the exe path or `%LOCALAPPDATA%` cannot be
/// read — an unknown location is treated as "not the install", which is the
/// safe side of every gate that asks.
pub fn isInstalledRelease(arena: std.mem.Allocator) bool {
    const exe_dir = std.fs.selfExeDirPathAlloc(arena) catch return false;
    const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return false;
    return isInstallDir(exe_dir, local);
}

/// Whether this exe may run the automatic win-v update check (T1217).
///
/// True for a build the MSI release pipeline stamped (`-Dwindows-update-check`,
/// T24), and for any non-Debug build RUNNING FROM the installed-release folder
/// — which is what a script-delivered refresh of the user's install is.
///
/// Debug is excluded even there: a debug build derives its own IPC endpoints
/// and state directory on purpose, and one that happened to be copied into the
/// install folder must not start behaving like the user's product.
///
/// This is the single answer behind the gate in `App.startUpdateCheck`, the
/// `update_check` field of `provenance.collect`, and the `update check:` line
/// of `ghoztty +version`, so those three cannot disagree — which is T1205's
/// lesson applied before it can be broken again.
pub fn autoUpdateCheckEnabled(arena: std.mem.Allocator) bool {
    if (build_config.windows_update_check) return true;
    if (builtin.mode == .Debug) return false;
    return isInstalledRelease(arena);
}

const testing = std.testing;

test "isInstallDir: the installed release" {
    try testing.expect(isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: case, trailing separators and slash direction do not matter" {
    try testing.expect(isInstallDir(
        "c:\\users\\david\\appdata\\local\\programs\\ghoztty\\",
        "C:\\Users\\David\\AppData\\Local\\",
    ));
    try testing.expect(isInstallDir(
        "C:/Users/David/AppData/Local/Programs/Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: a portable unpack is not the install" {
    try testing.expect(!isInstallDir(
        "D:\\Users\\David\\Desktop\\Ghoztty-portable-x64\\Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
    try testing.expect(!isInstallDir(
        "\\\\homeassistant\\share\\ghoztty-windows\\Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: a dev prefix is not the install" {
    try testing.expect(!isInstallDir(
        "D:\\git\\ghoztty\\zig-out\\bin",
        "C:\\Users\\David\\AppData\\Local",
    ));
    // Even one that happens to live under LOCALAPPDATA.
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\src\\ghoztty\\zig-out\\bin",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: neither a parent nor a child of the install dir counts" {
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs",
        "C:\\Users\\David\\AppData\\Local",
    ));
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\resources",
        "C:\\Users\\David\\AppData\\Local",
    ));
    // A sibling whose name merely starts the same way.
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty2",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: a drive-root LOCALAPPDATA still matches" {
    try testing.expect(isInstallDir("C:\\Programs\\Ghoztty", "C:\\"));
}

test "isInstallDir: an empty or unreadable LOCALAPPDATA is never the install" {
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty",
        "",
    ));
    try testing.expect(!isInstallDir("", "C:\\Users\\David\\AppData\\Local"));
}
