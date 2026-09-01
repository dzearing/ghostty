//! Pure logic for the Windows update check (T24): scan the GitHub
//! releases-list JSON for the newest `win-v*` tag and decide whether it is
//! newer than the running build. No OS calls, so the tests run in every
//! app-runtime lane (the hero_math/dim_math pattern). The WinINet fetch and
//! balloon UI live in App.zig.
//!
//! Channel design (recorded in windows-parity-details.md T24): Windows
//! builds are published as GitHub releases on dzearing/ghoztty tagged
//! `win-vX.Y.Z` (created with --latest=false so the Mac releases/latest
//! flow is untouched). The releases-list API returns newest-first, so the
//! FIRST `"tag_name":"win-v..."` occurrence is the latest Windows release.
const std = @import("std");

/// The tag prefix that marks a Windows release. Everything after it in the
/// tag is the semantic version ("win-v1.4.1" -> "1.4.1").
pub const tag_prefix = "win-v";

/// GitHub API compact-JSON needle. The API emits no space after the colon;
/// this matches the long-standing assumption in the original vendored
/// update check (which scanned `"tag_name":"` the same way).
const needle = "\"tag_name\":\"" ++ tag_prefix;

/// Find the newest win-v release tag in a GitHub /releases list response
/// and return its version text (the part after "win-v", e.g. "1.4.1").
/// Returns null if no win-v tag is present. The slice points into `json`.
pub fn findLatestWinVersion(json: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const ver_start = start + needle.len;
    const ver_end = std.mem.indexOfScalarPos(u8, json, ver_start, '"') orelse return null;
    if (ver_end == ver_start) return null;
    return json[ver_start..ver_end];
}

/// True if `latest_text` parses as a semantic version strictly newer than
/// `current`. Unparseable versions are never "newer" (fail closed: no
/// nagging on garbage data).
pub fn isNewer(current: std.SemanticVersion, latest_text: []const u8) bool {
    const latest = std.SemanticVersion.parse(latest_text) catch return false;
    return latest.order(current) == .gt;
}

test "findLatestWinVersion: first win-v among mac releases wins" {
    const testing = std.testing;
    // Releases list is newest-first; mac tags (v1.17.0) must be skipped and
    // the first win-v hit (the newest Windows release) returned, not later
    // ones.
    const json =
        "[{\"tag_name\":\"v1.17.0\",\"name\":\"Ghoztty v1.17.0\"}," ++
        "{\"tag_name\":\"win-v1.5.0\",\"name\":\"Ghoztty for Windows\"}," ++
        "{\"tag_name\":\"v1.16.2\"},{\"tag_name\":\"win-v1.4.1\"}]";
    try testing.expectEqualStrings("1.5.0", findLatestWinVersion(json).?);
}

test "findLatestWinVersion: no win-v tag" {
    const testing = std.testing;
    try testing.expect(findLatestWinVersion(
        "[{\"tag_name\":\"v1.17.0\"},{\"tag_name\":\"v1.16.2\"}]",
    ) == null);
    try testing.expect(findLatestWinVersion("") == null);
    try testing.expect(findLatestWinVersion("not json at all") == null);
}

test "findLatestWinVersion: truncated/malformed tail" {
    const testing = std.testing;
    // Needle present but the closing quote is missing (truncated response).
    try testing.expect(findLatestWinVersion("{\"tag_name\":\"win-v1.4.1") == null);
    // Empty version text.
    try testing.expect(findLatestWinVersion("{\"tag_name\":\"win-v\"}") == null);
}

test "isNewer: strict semver ordering" {
    const testing = std.testing;
    const current: std.SemanticVersion = .{ .major = 1, .minor = 4, .patch = 1 };
    try testing.expect(isNewer(current, "1.4.2"));
    try testing.expect(isNewer(current, "1.5.0"));
    try testing.expect(isNewer(current, "2.0.0"));
    try testing.expect(!isNewer(current, "1.4.1"));
    try testing.expect(!isNewer(current, "1.4.0"));
    try testing.expect(!isNewer(current, "0.9.9"));
    // Unparseable never notifies.
    try testing.expect(!isNewer(current, "banana"));
    try testing.expect(!isNewer(current, ""));
}

test "isNewer: build metadata on current is ignored (release exe stamp)" {
    const testing = std.testing;
    // Release exes are stamped "-Dversion-string=X.Y.Z+<commit>"; the build
    // metadata must not affect ordering (1.4.1+abc1234 vs win-v1.4.1 is up
    // to date, not an update).
    const current = try std.SemanticVersion.parse("1.4.1+abc1234");
    try testing.expect(!isNewer(current, "1.4.1"));
    try testing.expect(isNewer(current, "1.4.2"));
}

test "isNewer: dev pre-release is older than its release" {
    const testing = std.testing;
    // Git-derived dev versions look like "1.9.0-dev+hash"; semver orders
    // pre-releases BELOW the release, so a published win-v1.9.0 would
    // notify a 1.9.0-dev build. Dev builds never auto-check (build flag
    // gates them), so this is only reachable via the explicit env hook.
    const current = try std.SemanticVersion.parse("1.9.0-dev+0000000");
    try testing.expect(isNewer(current, "1.9.0"));
    try testing.expect(!isNewer(current, "1.8.9"));
}

/// Whether a check that found `latest` should raise a notification, given
/// `already_offered` — the version this app already told the user about.
///
/// T1171 made the automatic check REPEAT while the app runs (a terminal that
/// stays open for days used to ask exactly once, at launch, so a release
/// published at 08:00 was invisible until the next restart). Repeating a
/// question repeats its answer, and an hourly balloon for a version the user
/// has already seen — and possibly already declined with "Later" — is nagging,
/// not delivery. So the offer is made once per VERSION: the same version stays
/// quiet, and a newer one speaks up again.
///
/// `null` means nothing has been offered yet in this process, so anything
/// newer is news. Manual checks never pass an offered version: an explicit
/// "check for updates" deserves an answer even when it is the same answer.
pub fn shouldNotify(already_offered: ?[]const u8, latest: []const u8) bool {
    const offered = already_offered orelse return true;
    return !std.mem.eql(u8, offered, latest);
}

test "shouldNotify: first offer of a version speaks, a repeat stays quiet" {
    const testing = std.testing;
    try testing.expect(shouldNotify(null, "1.5.0"));
    try testing.expect(!shouldNotify("1.5.0", "1.5.0"));
    // A newer release after the user deferred the last one is news again.
    try testing.expect(shouldNotify("1.5.0", "1.6.0"));
    // Text comparison, not semver: the check only ever passes a version it
    // has already established is newer than the running build.
    try testing.expect(shouldNotify("1.5.0", "1.4.0"));
    try testing.expect(!shouldNotify("", ""));
}
