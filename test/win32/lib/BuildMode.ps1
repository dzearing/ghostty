# BuildMode.ps1 - T350. Refuse, BEFORE anything is launched or typed, to run an
# acceptance script against a build whose endpoints are the user's.
#
# Dot-source it (CleanSlate.ps1 and Isolation.ps1 already do):
#
#     . (Join-Path $PSScriptRoot 'BuildMode.ps1')
#     Assert-GhozttyIsolatedBuild -Exe $Exe
#
# WHY THIS EXISTS
#
# `-Exe zig-out\bin\ghoztty.exe` chooses which CLI BINARY runs. It does not
# choose which APP that CLI reaches, nor which AGENT: both are named endpoints
# derived from the BUILD MODE, and a mode that is not "debug" derives exactly
# the endpoints the user's installed Ghoztty already owns.
#
#   is_debug (Debug, ReleaseSafe)  ->  \\.\pipe\ghoztty-debug-<user>
#                                      \\.\pipe\ghoztty-agent-debug-<user>
#                                      %LOCALAPPDATA%\ghoztty\...-debug\...
#   otherwise (ReleaseFast, ReleaseSmall)
#                                  ->  \\.\pipe\ghoztty-<user>
#                                      \\.\pipe\ghoztty-agent-<user>
#                                      the user's own state files
#
# So a `zig build -Dapp-runtime=win32` run WITHOUT `-Doptimize=Debug` leaves a
# release build in zig-out, and from that moment the whole suite drives the
# user's terminal: `+new-window` opens windows in it, the path-filtered kills
# match nothing (different ExecutablePath), and every assertion measures a
# binary nobody here built. Nothing reports an error; the scripts pass.
# Observed for real on 2026-08-02 (T248): `zig-out\bin\ghoztty.exe +list --json`
# answered `"exe":"...\Programs\Ghoztty\ghoztty.exe"`, and the user's running
# terminal was holding leaked `ipc-p1.ps1` fixture windows.
#
# WHY BUILD MODE, AND NOT "IS A PRIVATE PIPE SUFFIX SET"
#
# `GHOZTTY_PIPE_SUFFIX` (T441 / Isolation.ps1) moves the APP endpoint only. The
# local agent's pipe is `is_debug`-derived and has NO env override
# (`LocalAgent.pipeName`, src\apprt\win32\LocalAgent.zig), and so is its state
# directory. A release build under a private suffix therefore still dials the
# agent that owns the user's live sessions. Build mode is the one gate that
# covers both halves, which is why the suffix is not accepted as an opt-in here.
#
# WHAT CATCHES WHAT
#
#   Assert-GhozttyIsolatedBuild  (this file)  - the exe we are ABOUT to launch;
#                                               works on a cold box, where
#                                               nothing answers yet.
#   Assert-GhozttyUnderTest      (CleanSlate) - the app ALREADY answering is a
#                                               different install.
#   Assert-GhozttyPrivateEndpoint / -Isolated (Isolation) - the suffix took, and
#                                               we are not in the caller's app.
#
# The first is the only one that can speak before the first `+new-window`, which
# is the moment a leaked fixture becomes visible in the user's terminal.

Set-StrictMode -Off

# One `+version` per exe per process: three libraries may ask, and the answer
# cannot change while a run is in flight.
if (-not (Get-Variable -Name GhozttyBuildModeCache -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name GhozttyBuildModeCache -Scope Script -Value @{}
}

function Test-GhozttyIsolatedBuildMode {
    <#
    .SYNOPSIS
    Pure predicate: does this build mode derive the `-debug` endpoints?

    .DESCRIPTION
    Mirrors `build_config.is_debug` (src\build_config.zig), which is what both
    `ipc_client.endpointPath` and `LocalAgent.pipeName` switch on. Debug and
    ReleaseSafe are isolated; ReleaseFast and ReleaseSmall share the user's.
    An unrecognized mode is treated as NOT isolated - the safe direction is to
    refuse a run we cannot vouch for.
    #>
    param([string]$Mode)
    if (-not $Mode) { return $false }
    $m = $Mode.TrimStart('.').Trim()
    return ($m -eq 'Debug' -or $m -eq 'ReleaseSafe')
}

function Get-GhozttyBuildMode {
    <#
    .SYNOPSIS
    The build mode baked into $Exe, read from its own `+version` output.

    .DESCRIPTION
    Local and offline: `+version` prints `- build mode    : .Debug` from
    `builtin.mode` without needing a running server, which is what makes this
    usable on a cold box. (`+list --json`'s `build.mode` reports the RUNNING
    app instead, and on a cold box there is none.)

    Returns the mode as printed, minus zig's leading dot; $null when the exe is
    missing or prints no such line. The `Running Instance` section also carries
    a `- mode` line, so the match is anchored on `build mode`.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)

    if ($script:GhozttyBuildModeCache.ContainsKey($Exe)) {
        return $script:GhozttyBuildModeCache[$Exe]
    }

    $mode = $null
    try {
        # Piped capture, never `> file` from PowerShell: that writes 0 bytes for
        # a native ghoztty command (T245). Never `Select-Object -First` either -
        # it tears down the still-running child and reports a false failure.
        $raw = (& $Exe +version 2>&1 | Out-String)
        if ($raw -match '(?m)^\s*-\s*build mode\s*:\s*\.?(\w+)') {
            $mode = $matches[1]
        }
    } catch {
        $mode = $null
    }

    $script:GhozttyBuildModeCache[$Exe] = $mode
    return $mode
}

function Assert-GhozttyIsolatedBuild {
    <#
    .SYNOPSIS
    Throw unless $Exe's endpoints are the debug ones - i.e. not the user's.

    .DESCRIPTION
    Call this before the app under test is launched. Returns the build mode on
    success.

    -Allow (or GHOZTTY_TEST_ALLOW_RELEASE=1) is the opt-in for a script whose
    SUBJECT is a release build - an upgrade or delivery test. It is deliberately
    an explicit act: there is no env var that makes a release run safe, only one
    that says "I know, and this script is about that build".

    A mode this file cannot read at all (an exe that does not run, or one too
    old to print the line) is refused for the same reason an unknown mode is:
    a run we cannot vouch for is exactly the run that leaks into the user's
    terminal.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [switch]$Allow
    )

    if ($Allow -or $env:GHOZTTY_TEST_ALLOW_RELEASE -eq '1') {
        return (Get-GhozttyBuildMode -Exe $Exe)
    }

    $mode = Get-GhozttyBuildMode -Exe $Exe
    if (Test-GhozttyIsolatedBuildMode -Mode $mode) { return $mode }

    $shown = if ($mode) { $mode } else { '<could not read `+version`>' }
    throw @"
Assert-GhozttyIsolatedBuild: REFUSING TO RUN. The exe under test
    $Exe
is a '$shown' build, so it does NOT use the -debug endpoints. Its IPC pipe, its
local agent's pipe and its state files are the ones the user's INSTALLED Ghoztty
owns, and this script would open windows in the user's terminal, type into it,
and then report a pass about a binary nobody here built.

A private GHOZTTY_PIPE_SUFFIX does not fix this: the agent pipe is build-mode
derived and has no env override.

Rebuild zig-out the way CLAUDE.md says, and re-run:
    zig build -Dapp-runtime=win32 -Doptimize=Debug

If this script's SUBJECT really is a release build (an upgrade or delivery
test), say so explicitly: pass -Allow to this assert, or set
GHOZTTY_TEST_ALLOW_RELEASE=1 for the run.
"@
}
