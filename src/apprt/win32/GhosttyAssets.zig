//! Embedded agent-integration assets (T866): the Ghoztty skill documents and
//! the two hook helper scripts the app installs for a coding agent. The Mac
//! app carries these same files as loose resources in its bundle
//! (`macos/Resources/Ghoztty/`, read by `GhosttyAssets.swift`); the Windows
//! equivalent of the app bundle is the exe itself, so here they are
//! `@embedFile`d — nothing to go missing or go stale beside the exe, and the
//! portable-zip manifest stays untouched.
//!
//! Layout of `assets/ghoztty/` (chosen here, recorded for convergence):
//!   - `upstream/`   pristine byte-for-byte mirror of tip-of-main's
//!                   `macos/Resources/Ghoztty/` — NEVER edited by hand. The
//!                   acceptance harness (section A of
//!                   `test/win32/hook-json.ps1`) compares every file against
//!                   `origin/main`, so drift from the Mac copies is loud.
//!   - `hooks/`, `skills/`  the copies the app ships, byte-identical to this
//!                   branch's `macos/Resources/Ghoztty/` and therefore AHEAD of
//!                   `upstream/` wherever this branch has edited them —
//!                   today that is `process-feedback/SKILL.md`, which T1321
//!                   taught to record a release request and to file deferred
//!                   work with `-UserReport`, so a fix a person asked for is
//!                   not left to the ordinary release cadence, and
//!                   `ghoztty/SKILL.md`, which T660 forked so the document an
//!                   agent READS describes the CLI this branch actually has:
//!                   `--keys-file=` (the only safe way to send generated text
//!                   through a PowerShell command line), `--busy-marker=`, the
//!                   motion-based `--when-idle` that replaced main's baked-in
//!                   `esc to interrupt` marker, and the `readonly` list field.
//!                   Both hook
//!                   scripts are deliberate forks — `ghoztty-banner.sh` replaces its `jq`
//!                   plumbing with `ghoztty +json` (native, dependency-free),
//!                   and `ghoztty-activity-state.sh` adds OSTYPE-guarded
//!                   Windows owner/liveness probes (T605: MSYS `kill -0`
//!                   cannot see a native pid and a native parent reads as
//!                   PPID=1, so without them every subagent marker is reaped
//!                   the moment it is written). Both forks are written to be
//!                   upstreamable (mac-seat tasks); once they land on main
//!                   each fork collapses back into the mirror and the Mac and
//!                   Windows builds converge on one copy.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.
const std = @import("std");

pub const Error = error{UnknownAsset};

/// The skill names the app installs, mirroring the Mac flow's set.
pub const skill_names = [_][]const u8{ "ghoztty", "process-feedback" };

const skill_ghoztty = @embedFile("assets/ghoztty/skills/ghoztty/SKILL.md");
const skill_process_feedback = @embedFile("assets/ghoztty/skills/process-feedback/SKILL.md");
const banner_script = @embedFile("assets/ghoztty/hooks/ghoztty-banner.sh");
const activity_state_script = @embedFile("assets/ghoztty/hooks/ghoztty-activity-state.sh");

/// The bundled SKILL.md text for a skill name, `error.UnknownAsset` for a
/// name not in `skill_names` (the Mac flow's `GhosttyAssetsError.missing`).
pub fn skillMarkdown(name: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, name, "ghoztty")) return skill_ghoztty;
    if (std.mem.eql(u8, name, "process-feedback")) return skill_process_feedback;
    return Error.UnknownAsset;
}

/// The banner updater hook script (the jq-free Windows fork; see header).
pub fn bannerScript() []const u8 {
    return banner_script;
}

/// The busy/idle activity-state hook script (the Windows-liveness fork;
/// see header).
pub fn activityStateScript() []const u8 {
    return activity_state_script;
}

test "every named skill resolves and looks like a skill document" {
    for (skill_names) |name| {
        const text = try skillMarkdown(name);
        try std.testing.expect(text.len > 0);
        // SKILL.md files open with YAML frontmatter.
        try std.testing.expect(std.mem.startsWith(u8, text, "---\n"));
    }
}

test "the process-feedback skill wires a user report through to a release" {
    // The deliberate divergence from main (T1321): a report drained from the
    // viewer feedback queue IS a user report, and until this text existed the
    // skill ended at "commit and move on" - so the fix rode the ordinary daily
    // release cadence and the person who reported it downloaded the same
    // broken build again (the T1294 shape). These are the two sentences that
    // stop that, and this is the tripwire if a re-vendor ever pastes an older
    // copy over the shipped asset.
    const text = try skillMarkdown("process-feedback");
    try std.testing.expect(std.mem.indexOf(u8, text, "daily-publish.ps1 -Request") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "parity-tasks.ps1 new -UserReport") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user-report: true") != null);
}

test "unknown skill is a typed error" {
    try std.testing.expectError(Error.UnknownAsset, skillMarkdown("nope"));
    try std.testing.expectError(Error.UnknownAsset, skillMarkdown(""));
}

test "hook scripts carry the shell ownership marker" {
    // Both scripts must be recognizable as ghoztty-managed (the marker the
    // T865 writer guards on) and start with a shebang.
    for ([_][]const u8{ bannerScript(), activityStateScript() }) |text| {
        try std.testing.expect(std.mem.startsWith(u8, text, "#!"));
        try std.testing.expect(std.mem.indexOf(u8, text, "# ghoztty-managed") != null);
    }
}

test "activity-state fork carries the Windows owner and liveness probes" {
    // The deliberate divergence from main (T605): owner resolution over the
    // native process tree and a `ps -W` liveness snapshot, both OSTYPE-guarded
    // so the POSIX paths stay byte-identical. If a re-vendor ever pastes
    // main's copy over the fork, this is the tripwire — without the probes the
    // machine reaps every subagent marker instantly on Windows.
    const text = activityStateScript();
    try std.testing.expect(std.mem.indexOf(u8, text, "owner_winpid") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ps -W") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "is_windows") != null);
}

test "banner script fork is jq-free and json-native" {
    // The one deliberate divergence from main: every jq call site is gone,
    // replaced by `ghoztty +json`. If a re-vendor ever pastes main's jq
    // version over the fork, this is the tripwire.
    const text = bannerScript();
    try std.testing.expect(std.mem.indexOf(u8, text, "ghoztty +json") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jq ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jq -") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "command -v jq") == null);
}
