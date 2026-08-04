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
        [switch]$Quiet
    )
    $suffix = "-$Tag$PID"
    $env:GHOZTTY_PIPE_SUFFIX = $suffix
    $script:GhozttyIsolationTag = $suffix
    if (-not $Quiet) { "  [isolation] GHOZTTY_PIPE_SUFFIX=$suffix" }
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
        [string]$Label = 'endpoint is private (nothing answers before launch)'
    )
    if (-not $env:GHOZTTY_PIPE_SUFFIX) {
        throw "isolation: GHOZTTY_PIPE_SUFFIX is not set - call Set-GhozttyTestIsolation first"
    }
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
