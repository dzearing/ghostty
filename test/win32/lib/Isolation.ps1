# Isolation.ps1 - T441. Make "this script drives its OWN Ghoztty" a CHECKED
# property instead of a convention.
#
# THE DEFECT THIS EXISTS TO PREVENT, measured live on 2026-08-03. A CLI call
# resolves its endpoint from three sources, in this order (src/os/ipc_client.zig
# `clientEndpointPathFrom`):
#
#   1. an explicit `$GHOZTTY_PIPE_SUFFIX`  - a caller aiming on purpose
#   2. the pane's baked `$GHOZTTY_IPC_SOCKET`
#   3. this build's own derivation (`endpointPath`, where `$USERNAME` acts)
#
# Every acceptance script is started from one of the user's own Ghoztty panes,
# so source 2 is ALWAYS present and always names the user's installed release.
# A script that sets neither suffix - or that only overrides `$USERNAME`, which
# moves source 3 and is therefore never consulted - talks to the terminal the
# user is sitting in. `upgrade-no-fork.ps1` did exactly that and typed its
# fixture prompts, including a `powershell -File ...` line, into the go-loop's
# live Claude pane.
#
# The second consequence is quieter and just as bad: a floor script run that way
# exercises the INSTALLED release, so "P1-P3 ALL PASS" was evidence about the
# user's build rather than the one just compiled.
#
# `endpointPath` honors the suffix too, so the instance a script auto-launches
# BINDS the private pipe - one env var isolates both ends.
#
# Usage - three lines, in this order:
#
#     . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
#     Set-GhozttyTestIsolation -Tag 'ipcp1'        # before ANY CLI call
#     Assert-GhozttyPrivateEndpoint -Exe $Exe      # nothing answers yet
#     ... launch the instance ...
#     Assert-GhozttyIsolated -Exe $Exe             # and it is not the user's
#
# Both asserts THROW. A script whose isolation has silently stopped working
# must die where it stands, not degrade back into driving a live terminal.
#
# T352: the suffix must be unique to the RUN, not just to the script. The
# `$PID` below is doing that job, and a hand-rolled `$env:GHOZTTY_PIPE_SUFFIX =
# '-something'` must carry `$PID` too - `test\win32\isolation-meta.ps1` section
# C fails the tree otherwise. Why it matters beyond tidiness: `+new-window
# --target=<name>` is idempotent by design, so a fixed endpoint hands the next
# run whatever windows a run that died before its cleanup left registered
# there, and the fixture is FOCUSED instead of built. One run-unique endpoint
# closes that for every name the script registers, which is why those names
# were left alone rather than each given a prefix of their own.

# T350: the suffix isolates the APP endpoint and nothing else - the local
# agent's pipe is keyed separately (build mode, plus the GHOZTTY_AGENT_INSTANCE
# lineage this file's -ReleaseSandbox switch sets) - so a release build under a
# private suffix ALONE still dials the agent that owns the user's live sessions.
# `Assert-GhozttyPrivateEndpoint` therefore checks the build mode first, which
# also covers the ~half of the suite that sets a suffix by hand and never loads
# CleanSlate.ps1.
#
# T490: the sentence here used to say the agent pipe had NO env override, which
# stopped being true at T167 and is plausibly how a release-lineage script
# concluded the app suffix was all there was (T1158). It is three knobs, not
# one, and `-ReleaseSandbox` below is the one call that sets them.
. (Join-Path $PSScriptRoot 'BuildMode.ps1')

# T1168: minting a GHOZTTY_AGENT_INSTANCE is what makes the agent write its own
# `HKCU\...\Run\GhozttyAgent-<instance>` autostart value instead of clobbering
# the user's - which is the whole point - but nothing removed it when the run
# ended, so every isolated run left a permanent startup program behind pointed
# at a dead sandbox. The teardown is armed HERE, at the one place the suffix is
# minted, rather than at the bottom of each script that uses one: the bottom of
# the script is exactly what does not run when a run dies half way through.
. (Join-Path $PSScriptRoot 'HarnessLeak.ps1')

Set-Variable -Name GhozttyIsolationTag -Scope Script -Value $null -ErrorAction SilentlyContinue

<#
Give this process its own IPC endpoint. $PID makes it unique per run, so two
scripts (or two runs of one script) never collide, and a leaked instance from an
earlier run is never mistaken for this run's.

The value is NOT restored afterwards on purpose: it is process-local and the
process is the script, so there is nothing to leak and no `finally` to forget.
#>
function Set-GhozttyTestIsolation {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [switch]$Quiet,
        [switch]$ReleaseSandbox,
        [string]$SandboxRoot
    )
    $suffix = "-$Tag$PID"
    $env:GHOZTTY_PIPE_SUFFIX = $suffix
    $script:GhozttyIsolationTag = $suffix
    if (-not $Quiet) { "  [isolation] GHOZTTY_PIPE_SUFFIX=$suffix" }

    # T1158. The other two thirds, for a script that legitimately drives a
    # RELEASE-lineage build. The app pipe alone is the state BuildMode.ps1's
    # header calls "the dangerous state, not a partial win": a release build
    # under a private suffix still dials the agent that owns the user's live
    # sessions, so every pane it opens becomes a PINNED session in the user's
    # real roster - and a pinned live session is immortal by design, because
    # that is what makes a pane survive closing the window.
    #
    # Kept behind a switch rather than made unconditional: the ~50 debug-lineage
    # scripts already get their agent isolation from the build mode, and moving
    # their LOCALAPPDATA would move the very `-debug` state dirs their
    # assertions read.
    if ($ReleaseSandbox) {
        # `GHOZTTY_AGENT_INSTANCE` caps at 24 chars (agent_lineage.max_len) and
        # is REJECTED, not truncated, past that - two sandboxes differing only
        # past the cap would silently share one lineage. Keep it short and
        # run-unique: the tag is trimmed, the pid is not.
        $pidPart = [string]$PID
        $tagRoom = 24 - ($pidPart.Length + 1)
        $tagPart = if ($Tag.Length -gt $tagRoom) { $Tag.Substring(0, [Math]::Max(1, $tagRoom)) } else { $Tag }
        $instance = "$tagPart-$pidPart"
        $env:GHOZTTY_AGENT_INSTANCE = $instance

        # T1168: and arm its removal in the same breath. The value the agent is
        # now free to write is a permanent HKCU startup program; this is the
        # only line that makes it as temporary as the sandbox it names.
        [void](Register-AgentRunKeyTeardown -Instance $instance)

        $root = if ($SandboxRoot) { $SandboxRoot } else { Join-Path $env:TEMP "ghoztty-sandbox-$Tag$PID" }
        New-Item -ItemType Directory -Force (Join-Path $root 'ghoztty') | Out-Null
        $env:LOCALAPPDATA = $root

        if (-not $Quiet) {
            "  [isolation] GHOZTTY_AGENT_INSTANCE=$instance"
            "  [isolation] LOCALAPPDATA=$root"
        }
    }

    return $suffix
}

# Run `+list --json` and return the raw text. Routed through cmd's redirection:
# `ghoztty +verb > file` from PowerShell writes zero bytes (T245), and
# PowerShell's own native-stdout capture can interleave and drop lines.
function Get-GhozttyListRaw {
    param([Parameter(Mandatory = $true)][string]$Exe)
    $out = Join-Path $env:TEMP "ghoztty-iso-$PID.json"
    cmd /c "`"$Exe`" +list --json > `"$out`" 2>&1" | Out-Null
    $raw = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    Remove-Item $out -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return '' }
    return $raw
}

<#
Called BEFORE the script launches its instance: on a private endpoint nothing
may answer yet. This is the check that works even from a plain non-Ghoztty
shell, where there is no caller pane id to look for.

An answer here means the suffix did not take effect and we are pointed at a live
app - the user's, most likely - so it throws before the script types anything.
#>
function Assert-GhozttyPrivateEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Label = 'endpoint is private (nothing answers before launch)',
        [switch]$AllowReleaseBuild
    )
    if (-not $env:GHOZTTY_PIPE_SUFFIX) {
        throw "isolation: GHOZTTY_PIPE_SUFFIX is not set - call Set-GhozttyTestIsolation first"
    }
    # T350: a private suffix is not enough on its own - see the header.
    Assert-GhozttyIsolatedBuild -Exe $Exe -Allow:$AllowReleaseBuild | Out-Null
    $raw = Get-GhozttyListRaw -Exe $Exe
    # A live instance answers with a JSON array of windows; a private endpoint
    # answers "No running Ghoztty instance found."
    $answered = $raw -match '"' -and $raw -notmatch 'No running Ghoztty'
    if ($answered) {
        "  FAIL [isolation] $Label"
        "  ABORTING: something already answers on $($env:GHOZTTY_PIPE_SUFFIX); refusing to drive it"
        throw 'isolation check failed: a live instance answered on the private endpoint'
    }
    "  PASS [isolation] $Label"
}

<#
Called AFTER the instance is up and BEFORE anything is typed into it. Two
independent oracles off one `+list --json`:

  1. The server's own `"exe"` must BE $Exe. This is the evidence half of T441 -
     go.md's floor is only evidence about the build under test if the instance
     answering is that build. (Same assertion as CleanSlate's
     `Assert-GhozttyUnderTest`, inlined so a script need not load both files;
     keep the two in step.)
  2. The caller's own `$GHOZTTY_PANE_ID` must be absent from the tree. It can
     only appear there if we are talking to the app the caller is sitting in -
     which is the safety half, and the one that catches a leak even when both
     builds happen to live at the same path.

Oracle 2 is skipped when the script was not started from a Ghoztty pane (nothing
to look for); oracle 1 always runs.
#>
function Assert-GhozttyIsolated {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Label = "the answering instance is ours, not the caller's own app"
    )
    $raw = Get-GhozttyListRaw -Exe $Exe

    if ($raw -match '"exe":"([^"]+)"') {
        $serverExe = $matches[1] -replace '\\\\', '\'
        if ($serverExe -ne $Exe) {
            "  FAIL [isolation] $Label"
            "  ABORTING: the answering instance is $serverExe, not $Exe"
            throw 'isolation check failed: driving a different build than the one under test'
        }
    }

    $callerPane = $env:GHOZTTY_PANE_ID
    if ($callerPane -and ($raw -match [regex]::Escape($callerPane))) {
        "  FAIL [isolation] $Label"
        "  ABORTING: the answering instance contains the caller's own pane $callerPane"
        throw 'isolation check failed: refusing to drive a live pane'
    }
    "  PASS [isolation] $Label"
}
