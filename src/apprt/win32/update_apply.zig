//! Pure logic for APPLYING a Windows update (T1178): which asset to fetch,
//! whether what came back is really an MSI, what msiexec is asked to do, and
//! how the applier process is told what to do. No OS calls, so the tests run
//! in every app-runtime lane (the `update_check.zig` pattern next door). The
//! WinINet download, the process choreography and the UI live in
//! `update_install.zig` and `App.zig`.
//!
//! Why any of this exists: `update_check.zig` could tell the user a newer
//! `win-v*` release existed, and then the only way to get it was
//! `scripts\upgrade-ghoztty-windows.ps1` and a handful of manual steps. The
//! Mac build updates itself; the user asked for the same here ("no more weird
//! scripts for upgrading this one", 2026-08-30).
//!
//! The two shapes worth reading before editing:
//!
//! - **The asset is found by URL, not by position.** GitHub's releases list
//!   nests assets inside their release object, so the obvious scan is "find
//!   the win-v tag, then take the next `browser_download_url`". That is a
//!   guess about field ORDER inside a JSON object, which no JSON producer
//!   promises. Instead every `browser_download_url` in the document is
//!   considered and one is accepted only if it is an `.msi` published under
//!   `/download/win-v<version>/` — self-validating, order-independent, and
//!   incapable of handing back an asset that belongs to a different release.
//! - **An in-use exe is renamed, never deleted.** Windows refuses to delete or
//!   overwrite a running image, but it will happily RENAME one — the handle
//!   follows the file. Per-session PTY holders (`ghoztty-agent.exe
//!   --pty-host`) outlive the agent BY DESIGN (docs/claude/sessions.md), so an
//!   update that waited for them would either never run or would kill the
//!   user's shells to install itself. `sidelineName` is how the installer
//!   clears INSTALLDIR for msiexec while those holders keep running out of the
//!   file they already opened.

const std = @import("std");

/// The `.msi` asset the Windows release workflow publishes is always
/// `Ghoztty-<version>-x64.msi` (see .github/workflows/release-windows.yml).
/// Only the extension is matched when picking the asset — the name is used
/// for the staged copy, so a rename upstream cannot make the update
/// undiscoverable.
pub const msi_extension = ".msi";

/// The JSON needle for a release asset's download URL. GitHub's API emits
/// compact JSON with no space after the colon, the same assumption
/// `update_check.zig` has always made about `"tag_name":"`.
const url_needle = "\"browser_download_url\":\"";

/// Find the MSI download URL belonging to the `win-v<version>` release.
/// Returns a slice into `json`, or null when the release has no MSI asset
/// (a build still uploading, or a release that only carries the portable
/// zip) — which is not an error, just nothing to offer.
pub fn findMsiUrl(json: []const u8, version: []const u8) ?[]const u8 {
    // The fragment that proves a URL belongs to THIS release. GitHub asset
    // URLs are .../releases/download/<tag>/<name>.
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "/download/win-v{s}/", .{version}) catch return null;

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, json, i, url_needle)) |hit| {
        const start = hit + url_needle.len;
        const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
        const url = json[start..end];
        i = end + 1;
        if (!std.mem.endsWith(u8, url, msi_extension)) continue;
        if (std.mem.indexOf(u8, url, marker) == null) continue;
        return url;
    }
    return null;
}

/// The file name to stage a download under, derived from the URL's last
/// path segment. Falls back to a version-derived name for a URL that ends
/// in a separator or is otherwise nameless, so a staged file always has a
/// name a human can recognise on disk.
pub fn stagedName(buf: []u8, url: []const u8, version: []const u8) ![]const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |slash| {
        const name = url[slash + 1 ..];
        if (name.len > 0 and std.mem.endsWith(u8, name, msi_extension) and !unsafeName(name)) {
            return std.fmt.bufPrint(buf, "{s}", .{name});
        }
    }
    return std.fmt.bufPrint(buf, "Ghoztty-{s}-x64.msi", .{version});
}

/// A name taken from a URL becomes a path on disk, so anything that could
/// steer it out of the staging directory disqualifies it: a separator, a
/// drive-letter colon, or a parent-directory hop.
fn unsafeName(name: []const u8) bool {
    if (std.mem.indexOfAny(u8, name, "\\/:") != null) return true;
    if (std.mem.indexOf(u8, name, "..") != null) return true;
    return false;
}

/// The OLE compound-file signature every MSI package starts with
/// (D0 CF 11 E0 A1 B1 1A E1). An HTML error page, a rate-limit JSON body or
/// a truncated transfer all fail this, which is the point: msiexec is never
/// handed something we have not looked at.
const msi_magic = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

/// True if `bytes` begins with the MSI (OLE compound file) signature and is
/// large enough to be a package rather than a stub. The size floor is
/// deliberately far below any real Ghoztty MSI (tens of MB) — it exists to
/// reject a truncated transfer that happens to start correctly, not to
/// second-guess the packager.
pub fn looksLikeMsi(bytes: []const u8) bool {
    if (bytes.len < min_msi_bytes) return false;
    return std.mem.startsWith(u8, bytes, &msi_magic);
}

/// Smallest thing that could plausibly be a package. One OLE sector header
/// plus a little; anything under this is a truncated or empty download.
pub const min_msi_bytes: usize = 4096;

/// What the app is allowed to do about an available update, derived from the
/// `auto-update` config (shared with macOS: off / check / download).
pub const Policy = enum {
    /// Never check.
    off,
    /// Check and notify; the download only starts if the user asks for it.
    notify,
    /// Check, download in the background, then notify that it is ready.
    download,
};

/// Map the `auto-update` config value (as `@tagName`, or null when unset) to
/// what this platform does about it.
///
/// Unset means `download`, which is what Sparkle defaults to on the Mac and
/// therefore what "like the normal mac ghoztty" means. An unrecognised value
/// is treated as unset rather than as `off`: a config Ghoztty cannot parse
/// must not silently turn updates off.
pub fn policyFromName(name: ?[]const u8) Policy {
    const n = name orelse return .download;
    if (std.mem.eql(u8, n, "off")) return .off;
    if (std.mem.eql(u8, n, "check")) return .notify;
    if (std.mem.eql(u8, n, "download")) return .download;
    return .download;
}

/// The msiexec command line that applies a staged package.
///
/// `/i` installs (a major upgrade removes the old product first, keyed on the
/// permanent UpgradeCode in dist/windows-installer/build-msi.sh). `/qb-!`
/// gives a progress bar with no cancel button and no modal at the end — the
/// user already consented in Ghoztty's own dialog, and a dialog nobody is
/// watching would leave the terminal closed until someone clicked it.
/// `/norestart` because a per-user install has no business rebooting the box,
/// and `/l*v` so a failed update leaves something to read.
///
/// The MSI's own launch-on-finish custom action is conditioned on
/// `UILevel > 3` and does not fire at this UI level; the applier relaunches
/// Ghoztty itself, which is the only version that can relaunch the RIGHT
/// install directory after an upgrade moved it.
pub fn msiexecCommandLine(buf: []u8, msi_path: []const u8, log_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "msiexec.exe /i \"{s}\" /qb-! /norestart /l*v \"{s}\"",
        .{ msi_path, log_path },
    );
}

/// Where a running image is renamed to so msiexec can write its replacement.
/// `stamp` is any monotonic-enough number (a timestamp): the name only has to
/// be unique against what is already in the directory, and a leftover from a
/// previous update is swept when nothing holds it any more.
///
/// The suffix, not a different directory, on purpose: `MoveFileW` across
/// volumes copies, and INSTALLDIR may sit on a different volume than the
/// temp directory. A rename inside one directory is atomic and cannot fail
/// for space.
pub fn sidelineName(buf: []u8, exe_path: []const u8, stamp: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.old-{d}", .{ exe_path, stamp });
}

/// True if `name` is one of the sidelined images `sidelineName` produces, and
/// therefore a candidate for the sweep on the next launch. Matched on the
/// shape rather than on a list of names, so a file this build never wrote
/// (an older Ghoztty's leftover) is still cleaned up.
pub fn isSidelined(name: []const u8) bool {
    const marker = ".old-";
    const at = std.mem.lastIndexOf(u8, name, marker) orelse return false;
    const digits = name[at + marker.len ..];
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// How the applier process is told what to do: `<pid>|<msi>|<exe>`.
/// Same shape and same reasoning as `relaunch_guard.Spec` — neither a Windows
/// path nor a decimal pid can contain `|`, so nothing needs escaping.
pub const Spec = struct {
    /// The app process to wait for. Nothing may touch INSTALLDIR until it is
    /// gone.
    pid: u32,
    /// The staged package to install.
    msi: []const u8,
    /// The binary to relaunch when the install finishes. Resolved before the
    /// app exits, because after the upgrade there is nobody left to ask.
    exe: []const u8,
};

const sep = '|';

pub fn formatSpec(buf: []u8, spec: Spec) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}{c}{s}{c}{s}", .{
        spec.pid, sep, spec.msi, sep, spec.exe,
    });
}

/// The inverse. Null for anything malformed: an applier that cannot read its
/// own orders must do nothing at all rather than guess a path and hand it to
/// msiexec.
pub fn parseSpec(raw: []const u8) ?Spec {
    const a = std.mem.indexOfScalar(u8, raw, sep) orelse return null;
    const rest = raw[a + 1 ..];
    const b = std.mem.indexOfScalar(u8, rest, sep) orelse return null;

    const pid = std.fmt.parseInt(u32, raw[0..a], 10) catch return null;
    if (pid == 0) return null;
    const msi = rest[0..b];
    const exe = rest[b + 1 ..];
    if (msi.len == 0 or exe.len == 0) return null;
    return .{ .pid = pid, .msi = msi, .exe = exe };
}

/// The largest failure message `describeFailure` composes. A cause sentence, a
/// remedy paragraph and a pointer at the log — anything longer would be a
/// dialog nobody reads.
pub const max_failure_message = 1024;

/// The dialog title an update failure is reported under. A constant so the
/// acceptance script can assert on the same string the app shows (T1206).
pub const failure_title = "Ghoztty could not finish updating";

/// Windows Installer exit codes this build says something specific about.
/// Named rather than inlined because the acceptance script and the unit tests
/// both refer to them, and a bare 1618 in three places is how a wrong number
/// survives.
pub const install_already_running: u32 = 1618; // ERROR_INSTALL_ALREADY_RUNNING
pub const install_user_exit: u32 = 1602; // ERROR_INSTALL_USEREXIT
pub const install_failure: u32 = 1603; // ERROR_INSTALL_FAILURE
pub const install_service_failure: u32 = 1601; // ERROR_INSTALL_SERVICE_FAILURE
pub const install_package_open_failed: u32 = 1619; // ERROR_INSTALL_PACKAGE_OPEN_FAILED
pub const install_package_invalid: u32 = 1620; // ERROR_INSTALL_PACKAGE_INVALID
pub const install_package_rejected: u32 = 1625; // ERROR_INSTALL_PACKAGE_REJECTED
pub const install_product_version: u32 = 1638; // ERROR_PRODUCT_VERSION

/// What went wrong, in one sentence a person would say out loud.
///
/// 1618 is the one this module exists for (T1206): a second installer
/// transaction cannot start while another holds the Windows Installer, and
/// before this the only thing that happened was a window disappearing.
pub fn failureCause(code: u32) []const u8 {
    return switch (code) {
        install_already_running =>
            "Another installation is already running on this PC, so Windows would " ++
            "not let Ghoztty's update start.",
        install_user_exit =>
            "The installation was cancelled before it finished.",
        install_service_failure =>
            "The Windows Installer service could not be started.",
        install_package_open_failed, install_package_invalid =>
            "The downloaded update package could not be opened — it looks damaged " ++
            "or incomplete.",
        install_package_rejected =>
            "Windows refused the update package because of a policy on this PC.",
        install_product_version =>
            "A different version of Ghoztty is already installed, and Windows would " ++
            "not install this one over it.",
        install_failure =>
            "Windows Installer stopped with a fatal error part way through.",
        else =>
            "Windows Installer stopped without finishing.",
    };
}

/// What to DO about it. Every branch ends with something the user can act on;
/// "contact support" is not an option here, so the fallback is the update page
/// they can install from by hand.
pub fn failureRemedy(code: u32) []const u8 {
    return switch (code) {
        install_already_running =>
            "Wait for the other installation to finish — look for a setup or " ++
            "Windows Installer window — then check for updates again from " ++
            "Ghoztty's menu.",
        install_user_exit =>
            "Check for updates again from Ghoztty's menu when you are ready.",
        install_service_failure =>
            "Restart Windows, then check for updates again from Ghoztty's menu.",
        install_package_open_failed, install_package_invalid =>
            "Check for updates again from Ghoztty's menu — that downloads a fresh " ++
            "copy of the package.",
        install_package_rejected =>
            "Ask whoever manages this PC about its software installation policy, " ++
            "then check for updates again.",
        install_product_version =>
            "Uninstall Ghoztty from Windows Settings, then install the new version " ++
            "from the Ghoztty releases page.",
        else =>
            "Check for updates again from Ghoztty's menu. If it keeps failing, " ++
            "install the new version from the Ghoztty releases page.",
    };
}

/// The whole dialog body for an update that could not be applied.
///
/// It opens by saying what the user still HAS — their old version, still
/// working — because the first thing someone whose update just failed wants to
/// know is whether their terminal is broken. The numeric code comes last: it
/// is the only part a bug report can be matched on, and it is the only part
/// that means nothing to the reader.
pub fn describeFailure(buf: []u8, code: u32, log_path: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty could not finish updating, so it is still running the version " ++
            "you already had.\n\n{s}\n\n{s}\n\nDetails are in {s} (Windows " ++
            "Installer code {d}).",
        .{ failureCause(code), failureRemedy(code), log_path, code },
    ) catch buf[0..0];
}

/// The body for the other silent outcome on this path: the app the update was
/// waiting for never exited, so nothing was installed at all. Installing over a
/// live app would half-replace it, so the applier gives up — and before T1206
/// it gave up without saying anything.
pub fn describeAppStillRunning(buf: []u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty could not finish updating, so it is still running the version " ++
            "you already had.\n\nThe update waited for Ghoztty to close and it " ++
            "was still running, so nothing was installed.\n\nClose every Ghoztty " ++
            "window, then check for updates again from Ghoztty's menu.",
        .{},
    ) catch buf[0..0];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A realistic compact releases-list body: a Mac release first (newest), then
/// the Windows release with both its assets, then an older Windows release.
const feed =
    "[{\"tag_name\":\"v1.17.0\",\"assets\":[{\"browser_download_url\":" ++
    "\"https://github.com/dzearing/ghoztty/releases/download/v1.17.0/Ghoztty-1.17.0-arm64.dmg\"}]}," ++
    "{\"tag_name\":\"win-v1.5.0\",\"assets\":[" ++
    "{\"browser_download_url\":\"https://github.com/dzearing/ghoztty/releases/download/win-v1.5.0/Ghoztty-portable-1.5.0-x64.zip\"}," ++
    "{\"browser_download_url\":\"https://github.com/dzearing/ghoztty/releases/download/win-v1.5.0/Ghoztty-1.5.0-x64.msi\"}]}," ++
    "{\"tag_name\":\"win-v1.4.1\",\"assets\":[" ++
    "{\"browser_download_url\":\"https://github.com/dzearing/ghoztty/releases/download/win-v1.4.1/Ghoztty-1.4.1-x64.msi\"}]}]";

test "findMsiUrl picks the MSI of the named release, past the zip beside it" {
    const url = findMsiUrl(feed, "1.5.0").?;
    try testing.expectEqualStrings(
        "https://github.com/dzearing/ghoztty/releases/download/win-v1.5.0/Ghoztty-1.5.0-x64.msi",
        url,
    );
}

test "findMsiUrl never returns another release's asset" {
    // The older release's MSI is present in the same document and must not be
    // reachable by asking for 1.5.0 — nor may the Mac DMG be, at any version.
    const older = findMsiUrl(feed, "1.4.1").?;
    try testing.expect(std.mem.indexOf(u8, older, "win-v1.4.1") != null);
    try testing.expect(findMsiUrl(feed, "9.9.9") == null);
    try testing.expect(findMsiUrl(feed, "1.17.0") == null);
}

test "findMsiUrl tolerates assets listed before the tag" {
    // Field order inside a JSON object is not a promise anyone makes; the scan
    // must not depend on assets following tag_name.
    const reordered =
        "[{\"assets\":[{\"browser_download_url\":" ++
        "\"https://github.com/dzearing/ghoztty/releases/download/win-v2.0.0/Ghoztty-2.0.0-x64.msi\"}]," ++
        "\"tag_name\":\"win-v2.0.0\"}]";
    try testing.expect(findMsiUrl(reordered, "2.0.0") != null);
}

test "findMsiUrl on feeds with nothing to offer" {
    try testing.expect(findMsiUrl("", "1.0.0") == null);
    try testing.expect(findMsiUrl("not json", "1.0.0") == null);
    // A release with only the portable zip: notify-worthy, not installable.
    const zip_only =
        "[{\"tag_name\":\"win-v3.0.0\",\"assets\":[{\"browser_download_url\":" ++
        "\"https://github.com/dzearing/ghoztty/releases/download/win-v3.0.0/Ghoztty-portable-3.0.0-x64.zip\"}]}]";
    try testing.expect(findMsiUrl(zip_only, "3.0.0") == null);
    // Truncated body: the needle is there but the value never closes.
    try testing.expect(findMsiUrl("{\"browser_download_url\":\"https://x/download/win-v1.0.0/a.msi", "1.0.0") == null);
}

test "stagedName uses the asset's own file name" {
    var buf: [256]u8 = undefined;
    const n = try stagedName(
        &buf,
        "https://github.com/dzearing/ghoztty/releases/download/win-v1.5.0/Ghoztty-1.5.0-x64.msi",
        "1.5.0",
    );
    try testing.expectEqualStrings("Ghoztty-1.5.0-x64.msi", n);
}

test "stagedName refuses a name that could escape the staging directory" {
    var buf: [256]u8 = undefined;
    // A hostile or malformed last segment must never become the path we write
    // to; the version-derived fallback is always inside the staging dir.
    try testing.expectEqualStrings(
        "Ghoztty-1.5.0-x64.msi",
        try stagedName(&buf, "https://x/download/win-v1.5.0/", "1.5.0"),
    );
    try testing.expectEqualStrings(
        "Ghoztty-1.5.0-x64.msi",
        try stagedName(&buf, "https://x/a/..\\..\\evil.msi", "1.5.0"),
    );
    try testing.expectEqualStrings(
        "Ghoztty-1.5.0-x64.msi",
        try stagedName(&buf, "https://x/a/C:evil.msi", "1.5.0"),
    );
    try testing.expectEqualStrings(
        "Ghoztty-1.5.0-x64.msi",
        try stagedName(&buf, "https://x/a/..evil.msi", "1.5.0"),
    );
    // Not an MSI at all -> fall back rather than stage a .zip under a .msi
    // expectation.
    try testing.expectEqualStrings(
        "Ghoztty-1.5.0-x64.msi",
        try stagedName(&buf, "https://x/download/win-v1.5.0/Ghoztty-portable-1.5.0-x64.zip", "1.5.0"),
    );
}

test "looksLikeMsi accepts a package and rejects everything else" {
    var pkg: [min_msi_bytes]u8 = @splat(0);
    @memcpy(pkg[0..8], &[_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 });
    try testing.expect(looksLikeMsi(&pkg));

    // The failures that actually happen: an HTML error page, a JSON rate-limit
    // body, an empty file, and a transfer that stopped after the signature.
    try testing.expect(!looksLikeMsi("<!DOCTYPE html><html>404</html>"));
    try testing.expect(!looksLikeMsi("{\"message\":\"API rate limit exceeded\"}"));
    try testing.expect(!looksLikeMsi(""));
    try testing.expect(!looksLikeMsi(&[_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 }));
    // Right size, wrong contents.
    var wrong: [min_msi_bytes]u8 = @splat(0x41);
    try testing.expect(!looksLikeMsi(&wrong));
}

test "policyFromName: unset behaves like the Mac default" {
    try testing.expectEqual(Policy.download, policyFromName(null));
    try testing.expectEqual(Policy.off, policyFromName("off"));
    try testing.expectEqual(Policy.notify, policyFromName("check"));
    try testing.expectEqual(Policy.download, policyFromName("download"));
    // A value this build does not know must not silently disable updates.
    try testing.expectEqual(Policy.download, policyFromName("tomorrow"));
}

test "msiexecCommandLine quotes both paths and stays non-interactive" {
    var buf: [512]u8 = undefined;
    const cmd = try msiexecCommandLine(
        &buf,
        "C:\\Users\\Da vid\\AppData\\Local\\ghoztty\\updates\\Ghoztty-1.5.0-x64.msi",
        "C:\\Users\\Da vid\\AppData\\Local\\ghoztty\\updates\\install.log",
    );
    try testing.expectEqualStrings(
        "msiexec.exe /i \"C:\\Users\\Da vid\\AppData\\Local\\ghoztty\\updates\\Ghoztty-1.5.0-x64.msi\"" ++
            " /qb-! /norestart /l*v \"C:\\Users\\Da vid\\AppData\\Local\\ghoztty\\updates\\install.log\"",
        cmd,
    );
    // The two properties this line exists to have: no reboot, and no dialog
    // waiting for a user whose terminal is closed.
    try testing.expect(std.mem.indexOf(u8, cmd, "/norestart") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "/qb-!") != null);
}

test "sidelineName renames in place and is recognised by the sweep" {
    var buf: [512]u8 = undefined;
    const n = try sidelineName(&buf, "C:\\Program Files\\Ghoztty\\ghoztty-agent.exe", 1756500000);
    try testing.expectEqualStrings("C:\\Program Files\\Ghoztty\\ghoztty-agent.exe.old-1756500000", n);
    // Same directory: a cross-volume MoveFileW would copy 48MB, or fail.
    try testing.expectEqualStrings(
        std.fs.path.dirname("C:\\Program Files\\Ghoztty\\ghoztty-agent.exe").?,
        std.fs.path.dirname(n).?,
    );
    try testing.expect(isSidelined(n));
}

test "isSidelined matches only the shape the sweep may delete" {
    try testing.expect(isSidelined("ghoztty.exe.old-1"));
    try testing.expect(isSidelined("ghoztty-agent.exe.old-1756500000"));
    // Everything a live install legitimately contains.
    try testing.expect(!isSidelined("ghoztty.exe"));
    try testing.expect(!isSidelined("ghoztty-agent.exe"));
    try testing.expect(!isSidelined("ghoztty.exe.old-"));
    try testing.expect(!isSidelined("ghoztty.exe.old-abc"));
    try testing.expect(!isSidelined("notes.old-2.txt"));
}

test "formatSpec and parseSpec round-trip real Windows paths" {
    var buf: [1024]u8 = undefined;
    const s = try formatSpec(&buf, .{
        .pid = 41416,
        .msi = "C:\\Users\\David\\AppData\\Local\\ghoztty\\updates\\Ghoztty-1.5.0-x64.msi",
        .exe = "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe",
    });
    const p = parseSpec(s).?;
    try testing.expectEqual(@as(u32, 41416), p.pid);
    try testing.expectEqualStrings("C:\\Users\\David\\AppData\\Local\\ghoztty\\updates\\Ghoztty-1.5.0-x64.msi", p.msi);
    try testing.expectEqualStrings("C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe", p.exe);
}

test "parseSpec refuses anything it cannot read exactly" {
    try testing.expect(parseSpec("") == null);
    try testing.expect(parseSpec("41416") == null);
    try testing.expect(parseSpec("41416|C:\\a.msi") == null);
    try testing.expect(parseSpec("|C:\\a.msi|C:\\a.exe") == null);
    try testing.expect(parseSpec("abc|C:\\a.msi|C:\\a.exe") == null);
    // Pid 0 is the system idle process; never a thing to wait on.
    try testing.expect(parseSpec("0|C:\\a.msi|C:\\a.exe") == null);
    try testing.expect(parseSpec("7||C:\\a.exe") == null);
    try testing.expect(parseSpec("7|C:\\a.msi|") == null);
}

test "the spec buffer holds two max-length paths" {
    // `armImpl`'s stack buffer must survive the deepest paths Windows hands
    // us; a truncating bufPrint there would hand msiexec a chopped path.
    var buf: [2 * std.fs.max_path_bytes + 32]u8 = undefined;
    const long = "C:\\" ++ ("d" ** 200);
    const s = try formatSpec(&buf, .{ .pid = 4294967295, .msi = long, .exe = long });
    const p = parseSpec(s).?;
    try testing.expectEqual(@as(u32, 4294967295), p.pid);
    try testing.expectEqualStrings(long, p.exe);
}

test "describeFailure names the collision in words, not just a number" {
    // The defect T1206 exists for: a second installer transaction collided
    // with the first and the only visible outcome was a window disappearing.
    var buf: [max_failure_message]u8 = undefined;
    const text = describeFailure(&buf, install_already_running, "C:\\stage\\install.log");

    try testing.expect(std.mem.indexOf(u8, text, "Another installation is already running") != null);
    // It says what the user still has, so nobody has to wonder whether their
    // terminal survived the failed update.
    try testing.expect(std.mem.indexOf(u8, text, "still running the version") != null);
    // It says what to do, and where to look.
    try testing.expect(std.mem.indexOf(u8, text, "Wait for the other installation") != null);
    try testing.expect(std.mem.indexOf(u8, text, "C:\\stage\\install.log") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1618") != null);
}

test "describeFailure: every named code gets its own cause and remedy" {
    const codes = [_]u32{
        install_already_running,
        install_user_exit,
        install_failure,
        install_service_failure,
        install_package_open_failed,
        install_package_invalid,
        install_package_rejected,
        install_product_version,
    };
    for (codes) |code| {
        var buf: [max_failure_message]u8 = undefined;
        const text = describeFailure(&buf, code, "C:\\l.log");
        // Nothing may truncate: bufPrint failure returns an empty slice, which
        // would be a dialog with no words in it — the very failure this fixes.
        try testing.expect(text.len > 120);
        try testing.expect(std.mem.indexOf(u8, text, failureCause(code)) != null);
        try testing.expect(std.mem.indexOf(u8, text, failureRemedy(code)) != null);
    }
    // 1618's cause is not shared with anything else; a copy-paste that mapped
    // the collision onto the generic sentence would pass every check above.
    try testing.expect(!std.mem.eql(u8, failureCause(install_already_running), failureCause(9999)));
    try testing.expect(!std.mem.eql(u8, failureRemedy(install_already_running), failureRemedy(9999)));
}

test "describeFailure: an unmapped code still says something actionable" {
    var buf: [max_failure_message]u8 = undefined;
    const text = describeFailure(&buf, 4242, "C:\\l.log");
    try testing.expect(std.mem.indexOf(u8, text, "without finishing") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Check for updates again") != null);
    try testing.expect(std.mem.indexOf(u8, text, "4242") != null);
}

test "describeFailure fits its buffer with a deep log path" {
    // The log lives beside the staged package, which lives under LOCALAPPDATA;
    // a long profile name must not silently empty the message.
    var buf: [max_failure_message]u8 = undefined;
    const deep = "C:\\Users\\" ++ ("n" ** 180) ++ "\\AppData\\Local\\ghoztty\\updates\\install.log";
    const text = describeFailure(&buf, install_failure, deep);
    try testing.expect(text.len > 0);
    try testing.expect(std.mem.indexOf(u8, text, deep) != null);
}

test "describeAppStillRunning tells the user what to close" {
    var buf: [max_failure_message]u8 = undefined;
    const text = describeAppStillRunning(&buf);
    try testing.expect(std.mem.indexOf(u8, text, "nothing was installed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Close every Ghoztty window") != null);
}
