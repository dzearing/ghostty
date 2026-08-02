//! Pure path and version math for the WebView2 host (T372).
//!
//! The loader-less runtime probe (`webview2.zig`) is all registry reads,
//! `LoadLibraryW` and COM; the *arithmetic* it does on the way — parsing a
//! version string, deciding whether one is usable, taking the last component
//! of a native path, and joining the two directory shapes the Evergreen
//! runtime advertises — is pure, so it lives here and is asserted in the
//! `-Dapp-runtime=none` lane like every other pure win32 module
//! (`tab_strip_layout.zig`, `icon_button.zig`, `caption_layout.zig`, …).
//!
//! Everything here works in **UTF-8**. The registry hands back UTF-16 and
//! `LoadLibraryW` wants UTF-16, so `webview2.zig` converts at both boundaries
//! and this module never imports an OS header. That is the same split the
//! house pure modules use, and it is what lets the none lane compile it.
//!
//! **No OS imports. Keep it that way.**
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A four-part Windows file version, e.g. `150.0.4078.105`.
///
/// The Evergreen runtime advertises exactly four parts. Fewer parses fine
/// (missing parts read as 0) so a malformed key degrades to "unusable"
/// rather than to a parse crash; more is an error, because a fifth part
/// means we are not looking at what we think we are.
pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    build: u32 = 0,
    patch: u32 = 0,

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.build != b.build) return std.math.order(a.build, b.build);
        return std.math.order(a.patch, b.patch);
    }

    /// The runtime is "present but not installed" sentinel: EdgeUpdate keeps
    /// the client key around with `pv = 0.0.0.0` after an uninstall, so a key
    /// that EXISTS is not evidence of a runtime. This is the check that
    /// difference turns on.
    pub fn usable(self: Version) bool {
        return self.major != 0 or self.minor != 0 or
            self.build != 0 or self.patch != 0;
    }
};

/// Parse `a.b.c.d`. Returns null for anything that is not a dot-separated run
/// of 1–4 decimal numbers, including the empty string.
pub fn parseVersion(s: []const u8) ?Version {
    if (s.len == 0) return null;
    var v: Version = .{};
    const fields = [_]*u32{ &v.major, &v.minor, &v.build, &v.patch };
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (i >= fields.len) return null; // a fifth component: not our shape
        if (part.len == 0) return null;
        fields[i].* = std.fmt.parseInt(u32, part, 10) catch return null;
        i += 1;
    }
    return v;
}

/// The architecture subdirectory the runtime keeps its client DLL under.
/// Chosen from the *host process* architecture, not the OS: an x86 process on
/// an x64 box must load the x86 client.
pub const Arch = enum {
    x86,
    x64,
    arm64,

    pub fn dirName(self: Arch) []const u8 {
        return switch (self) {
            .x86 => "x86",
            .x64 => "x64",
            .arm64 => "arm64",
        };
    }

    /// The arch of the process doing the loading.
    pub fn current() Arch {
        return switch (@import("builtin").cpu.arch) {
            .x86 => .x86,
            .x86_64 => .x64,
            .aarch64 => .arm64,
            else => .x64,
        };
    }
};

/// The client DLL inside a versioned browser directory:
/// `<browser_dir>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`.
///
/// `browser_dir` is the versioned application directory — the shape the
/// `ClientState` key's `EBWebView` value already has, and the shape
/// `versionedBrowserDir` builds out of the `Clients` key's two halves.
pub fn clientDllPath(alloc: Allocator, browser_dir: []const u8, arch: Arch) Allocator.Error![]u8 {
    const trimmed = trimTrailingSeparators(browser_dir);
    return std.fmt.allocPrint(
        alloc,
        "{s}\\EBWebView\\{s}\\EmbeddedBrowserWebView.dll",
        .{ trimmed, arch.dirName() },
    );
}

/// `<location>\<version>` — the versioned directory assembled from the
/// `Clients\{guid}` key's `location` + `pv` values. That key is the fallback
/// source; `ClientState\{guid}`'s `EBWebView` value already holds the joined
/// path and needs none of this.
pub fn versionedBrowserDir(
    alloc: Allocator,
    location: []const u8,
    version: []const u8,
) Allocator.Error![]u8 {
    const trimmed = trimTrailingSeparators(location);
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ trimmed, version });
}

/// `%LOCALAPPDATA%\ghoztty\EBWebView[-debug]` — the ONE user-data folder
/// every viewer pane in this app shares, so all of them run under a single
/// browser process tree (T90a design §4). The `-debug` suffix keeps a debug
/// build's profile off the installed release's, exactly like
/// `local-agent[-debug]` and the `-debug` IPC pipe.
pub fn userDataFolder(
    alloc: Allocator,
    local_appdata: []const u8,
    debug: bool,
) Allocator.Error![]u8 {
    const trimmed = trimTrailingSeparators(local_appdata);
    const suffix: []const u8 = if (debug) "-debug" else "";
    return std.fmt.allocPrint(alloc, "{s}\\ghoztty\\EBWebView{s}", .{ trimmed, suffix });
}

/// The last component of a native Windows path, with any trailing separators
/// ignored. The versioned browser directory ends in the runtime's version, so
/// this is how a `ClientState` hit reports which version it found without a
/// second registry read.
pub fn lastPathComponent(path: []const u8) []const u8 {
    const trimmed = trimTrailingSeparators(path);
    if (trimmed.len == 0) return trimmed;
    var i = trimmed.len;
    while (i > 0) : (i -= 1) {
        const c = trimmed[i - 1];
        if (c == '\\' or c == '/') return trimmed[i..];
    }
    return trimmed;
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    return path[0..end];
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "parseVersion: the four-part shape the runtime advertises" {
    const v = parseVersion("150.0.4078.105").?;
    try testing.expectEqual(@as(u32, 150), v.major);
    try testing.expectEqual(@as(u32, 0), v.minor);
    try testing.expectEqual(@as(u32, 4078), v.build);
    try testing.expectEqual(@as(u32, 105), v.patch);
    try testing.expect(v.usable());
}

test "parseVersion: short forms fill with zero" {
    try testing.expectEqual(@as(u32, 1), parseVersion("1").?.major);
    try testing.expectEqual(@as(u32, 0), parseVersion("1").?.patch);
    try testing.expectEqual(@as(u32, 2), parseVersion("1.2").?.minor);
}

test "parseVersion: rejects junk instead of guessing" {
    try testing.expect(parseVersion("") == null);
    try testing.expect(parseVersion("1.2.3.4.5") == null);
    try testing.expect(parseVersion("1..3") == null);
    try testing.expect(parseVersion("1.2.x") == null);
    try testing.expect(parseVersion("v1.2") == null);
    try testing.expect(parseVersion("1.2.3.") == null);
}

test "usable: an uninstalled runtime leaves the key behind at 0.0.0.0" {
    // This is the whole reason the probe reads `pv` instead of testing for
    // the key's existence: EdgeUpdate keeps the client key after uninstall.
    try testing.expect(!parseVersion("0.0.0.0").?.usable());
    try testing.expect(!(Version{}).usable());
    try testing.expect(parseVersion("0.0.0.1").?.usable());
}

test "Version.order" {
    const a = parseVersion("150.0.4078.105").?;
    const b = parseVersion("150.0.4078.106").?;
    const c = parseVersion("151.0.1.1").?;
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.gt, b.order(a));
    try testing.expectEqual(std.math.Order.eq, a.order(a));
    try testing.expectEqual(std.math.Order.lt, b.order(c));
}

test "clientDllPath: the layout measured on the box" {
    const alloc = testing.allocator;
    const p = try clientDllPath(
        alloc,
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\150.0.4078.105",
        .x64,
    );
    defer alloc.free(p);
    try testing.expectEqualStrings(
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\150.0.4078.105" ++
            "\\EBWebView\\x64\\EmbeddedBrowserWebView.dll",
        p,
    );
}

test "clientDllPath: a trailing separator does not double up" {
    const alloc = testing.allocator;
    const p = try clientDllPath(alloc, "C:\\rt\\1.2.3.4\\", .arm64);
    defer alloc.free(p);
    try testing.expectEqualStrings("C:\\rt\\1.2.3.4\\EBWebView\\arm64\\EmbeddedBrowserWebView.dll", p);
}

test "versionedBrowserDir: the Clients-key fallback joins location + pv" {
    const alloc = testing.allocator;
    const p = try versionedBrowserDir(
        alloc,
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application",
        "150.0.4078.105",
    );
    defer alloc.free(p);
    try testing.expectEqualStrings(
        "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\150.0.4078.105",
        p,
    );
}

test "userDataFolder: one folder per lineage, debug kept apart" {
    const alloc = testing.allocator;
    const rel = try userDataFolder(alloc, "C:\\Users\\dev\\AppData\\Local", false);
    defer alloc.free(rel);
    try testing.expectEqualStrings("C:\\Users\\dev\\AppData\\Local\\ghoztty\\EBWebView", rel);

    const dbg = try userDataFolder(alloc, "C:\\Users\\dev\\AppData\\Local\\", true);
    defer alloc.free(dbg);
    try testing.expectEqualStrings("C:\\Users\\dev\\AppData\\Local\\ghoztty\\EBWebView-debug", dbg);
}

test "lastPathComponent: the version falls out of the ClientState path" {
    try testing.expectEqualStrings(
        "150.0.4078.105",
        lastPathComponent("C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\150.0.4078.105"),
    );
    try testing.expectEqualStrings("1.2.3.4", lastPathComponent("C:\\rt\\1.2.3.4\\\\"));
    try testing.expectEqualStrings("x", lastPathComponent("x"));
    try testing.expectEqualStrings("", lastPathComponent(""));
    try testing.expectEqualStrings("", lastPathComponent("\\"));
    // Forward slashes are legal in Win32 paths and the registry has held
    // them before; do not let one hide the component.
    try testing.expectEqualStrings("9.9", lastPathComponent("C:/rt/9.9"));
}

test "Arch.dirName covers every case" {
    try testing.expectEqualStrings("x86", Arch.dirName(.x86));
    try testing.expectEqualStrings("x64", Arch.dirName(.x64));
    try testing.expectEqualStrings("arm64", Arch.dirName(.arm64));
}
