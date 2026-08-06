//! Pure logic for `ghoztty.com`, the console-subsystem twin of `ghoztty.exe`
//! (T245). The Win32 half — the detached GUI respawn — lives in
//! `src/apprt/win32/App.zig` (`runComShimGuiRespawn`); everything testable
//! lives here so the zig test lanes cover it.
//!
//! Why `ghoztty.com` exists: PowerShell decides whether to WAIT for — and
//! wire file redirection to — a native child by reading the PE header's
//! subsystem field. `ghoztty.exe` is a GUI-subsystem binary (it is the app),
//! so `ghoztty +list --json > out.json` from PowerShell launches it without
//! waiting and tears the pipeline down immediately: the file stays 0 bytes
//! and `$LASTEXITCODE` stays empty, silently. No child-side handle logic can
//! fix a parent that never waits, so the fix ships a console-subsystem
//! `ghoztty.com` next to the exe: PATHEXT resolves `.COM` before `.EXE`, so
//! a bare `ghoztty` from PowerShell or cmd finds it, waits for it, and wires
//! redirection properly (the `devenv.com` pattern).
//!
//! Why a patched COPY of the app rather than a small relay shim: the first
//! cut was a ~1MB console exe that relayed std handles to `ghoztty.exe` —
//! and Windows Defender's ML heuristics quarantined it on sight
//! (`Trojan:Win32/Bearfoos.A!ml`, observed on-box 2026-08-06: a tiny,
//! unsigned, version-info-less console binary that spawns processes with
//! inherited handles is the static shape of a dropper). The 45MB debug /
//! ~15MB release app binary with its VERSIONINFO resources has never been
//! flagged, so `ghoztty.com` is now that exact binary with ONE WORD changed:
//! the optional header's Subsystem field (GUI→console), flipped at install
//! time by `src/build/patch_subsystem_main.zig`. That also deletes the whole
//! relay layer: a CLI verb run via `.com` executes in the console process
//! directly — byte-exact arguments, direct exit codes, working Ctrl-C —
//! which is precisely the configuration debug builds (Console subsystem)
//! already ship.
//!
//! The one behavior the twin adds: launched with NO CLI action (a bare
//! `ghoztty`, or `ghoztty -e …`), it must NOT run the GUI in-process — the
//! caller's shell is WAITING on it (console subsystem!), and a shell must
//! never block on the terminal it just launched. Instead it respawns the
//! sibling `ghoztty.exe` detached, passing its command-line tail through
//! verbatim, and exits 0.

const std = @import("std");

/// True when a process whose executable path is `self_path` is the
/// `ghoztty.com` twin and must respawn the GUI sibling instead of running
/// the GUI in-process. Matched on the basename, case-insensitively (NTFS is
/// case-preserving); the build mode is irrelevant — a debug `.com` behaves
/// identically.
pub fn isComShim(self_path: []const u8) bool {
    const base = std.fs.path.basename(self_path);
    return std.ascii.eqlIgnoreCase(base, "ghoztty.com");
}

test "isComShim: matches the twin's basename only" {
    try std.testing.expect(isComShim("C:\\Program Files\\Ghoztty\\ghoztty.com"));
    try std.testing.expect(isComShim("D:\\git\\ghoztty\\zig-out\\bin\\GHOZTTY.COM"));
    try std.testing.expect(!isComShim("C:\\Program Files\\Ghoztty\\ghoztty.exe"));
    try std.testing.expect(!isComShim("ghoztty-agent.exe"));
    try std.testing.expect(!isComShim("ghoztty.com.exe"));
    try std.testing.expect(isComShim("ghoztty.com"));
}

/// Index of the first byte after argv[0] (and any following whitespace) in a
/// raw Win32 command line — the start of the tail the GUI respawn splices
/// onto the relaunched `"…\ghoztty.exe"` verbatim. Passing the tail through
/// untouched (rather than re-quoting a parsed argv) keeps flags like
/// `-e <cmd…>` byte-exact through the respawn.
///
/// argv[0] follows CommandLineToArgvW's rule for the first token only: if it
/// starts with `"` it runs to the next `"` with NO escape handling;
/// otherwise it runs to the first space or tab.
pub fn commandLineTailIndex(cmd: []const u16) usize {
    var i: usize = 0;
    if (cmd.len > 0 and cmd[0] == '"') {
        i = 1;
        while (i < cmd.len and cmd[i] != '"') i += 1;
        if (i < cmd.len) i += 1; // consume the closing quote
    } else {
        while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t') i += 1;
    }
    while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
    return i;
}

test "commandLineTailIndex: unquoted argv0" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const cmd = L("ghoztty.com --title=x -e claude");
    try std.testing.expectEqualSlices(
        u16,
        L("--title=x -e claude"),
        cmd[commandLineTailIndex(cmd)..],
    );
}

test "commandLineTailIndex: quoted argv0 with spaces" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const cmd = L("\"C:\\Program Files\\Ghoztty\\ghoztty.com\"  -e pwsh -NoExit -Command \"echo hi\"");
    try std.testing.expectEqualSlices(
        u16,
        L("-e pwsh -NoExit -Command \"echo hi\""),
        cmd[commandLineTailIndex(cmd)..],
    );
}

test "commandLineTailIndex: no arguments" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const bare = L("ghoztty.com");
    try std.testing.expectEqual(bare.len, commandLineTailIndex(bare));
    const quoted = L("\"C:\\x y\\ghoztty.com\"");
    try std.testing.expectEqual(quoted.len, commandLineTailIndex(quoted));
    try std.testing.expectEqual(@as(usize, 0), commandLineTailIndex(L("")));
}

test "commandLineTailIndex: unterminated quote" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const cmd = L("\"C:\\broken");
    try std.testing.expectEqual(cmd.len, commandLineTailIndex(cmd));
}
