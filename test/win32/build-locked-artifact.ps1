# T192 - `zig build` must install over an artifact a RUNNING process is holding
# open. Non-interactive; asserts and exits nonzero on any failure.
#
#   powershell -NoProfile -File test\win32\build-locked-artifact.ps1
#
# WHAT IS UNDER TEST
#
# Windows holds an executable's image file open for the life of the process, and
# `ghoztty-agent.exe` outliving the app is the whole point of session
# persistence - so a plain dev-loop `zig build` on a box where an earlier test
# run left a repo-lineage agent alive died with
#
#   error: unable to update file from '.zig-cache\o\<hash>\ghoztty-agent.exe'
#          to 'zig-out\bin\ghoztty-agent.exe': AccessDenied
#
# after `ghoztty.exe` had ALREADY installed. That shape is the expensive part: a
# session that trusts the exit code concludes "my change did not build" over a
# binary that really did change, or writes off a real test result as a stale
# binary. `src/build/install_unlock_main.zig` moves the locked destination aside
# (`<name>.old-<n>`) so the install's atomic rename lands on an empty path.
#
# HOW THE ARMS FORCE THE COLLISION
#
# The install step (`std.fs.Dir.updateFile`) skips the copy when size and mtime
# already match, so a locked-but-current file is in nobody's way and the failure
# does not reproduce. `-Dagent-version=<stamp>` re-links the agent with a
# different baked string - a genuinely new artifact, in ~15s, with no source
# edit - and that same stamp is then the oracle for WHICH binary landed on disk:
# it is searched for verbatim in the installed bytes. The stamp is a build-time
# override of the agent's self-update identity only; nothing else reads it.
#
# `GHOZTTY_INSTALL_UNLOCK=0` turns the guard off, which is how arm 2 reproduces
# the original failure from this same tree. Without that arm the suite could not
# tell "the fix works" from "the trap no longer reproduces".
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# The build under test must be the isolated (debug) one - this script rebuilds
# zig-out several times and starts an agent from it.
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    "  FAIL zig is not on PATH"
    exit 1
}
# Must live on the repo's drive or zig 0.15.2's build runner panics in
# convertPathArg before any step runs (CLAUDE.md, Windows build section).
if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    $env:ZIG_GLOBAL_CACHE_DIR = (Split-Path -Qualifier $Repo) + '\zig-global-cache'
}

$tmp = Join-Path $env:TEMP "ghoztty-t192-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$asideGlob = (Split-Path -Leaf $AgentExe) + '.old-*'
$binDir = Split-Path -Parent $AgentExe

function Get-AsideFiles {
    @(Get-ChildItem $binDir -Filter $asideGlob -ErrorAction SilentlyContinue)
}

function Test-StampIn($path, $stamp) {
    if (-not (Test-Path $path)) { return $false }
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path))
    return $text.Contains($stamp)
}

# Only ever repo-lineage agents: an installed Ghoztty runs its agent from
# %LOCALAPPDATA%\Programs and owns the user's live sessions.
function Stop-RepoAgents {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

# A long-lived repo-lineage agent, fully hermetic: its own pipe, its own
# port/sessions files, and a throwaway %LOCALAPPDATA% so it can never read or
# write a real agent's state.
# persistence: starts ghoztty-agent.exe directly - no app, no window, nothing to restore.
function Start-HeldAgent {
    $stateDir = Join-Path $tmp 'ghoztty\local-agent-debug'
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_AGENT_HEARTBEAT = "$tmp\agent.heartbeat"
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden -ArgumentList `
        "--listen-pipe=\\.\pipe\ghoztty-agent-t192-$PID", `
        "--port-file=$stateDir\port.json", `
        "--sessions-file=$stateDir\sessions.json", `
        "--headless", "--force-replace"
    Remove-Item env:GHOSTTY_AGENT_HEARTBEAT -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $saved
    Start-Sleep -Seconds 2
    return $p
}

function Invoke-ZigBuild {
    param([string]$Stamp, [string]$Unlock, [string]$LogName)
    $log = Join-Path $tmp $LogName
    $zargs = @('build', '-Dapp-runtime=win32', '-Doptimize=Debug')
    if ($Stamp) { $zargs += "-Dagent-version=$Stamp" }
    if ($Unlock) { $env:GHOZTTY_INSTALL_UNLOCK = $Unlock }
    Push-Location $Repo
    & zig @zargs *> $log
    $code = $LASTEXITCODE
    Pop-Location
    Remove-Item env:GHOZTTY_INSTALL_UNLOCK -ErrorAction SilentlyContinue
    $text = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

"== 0: baseline - no repo agent running, tree builds clean"
Stop-RepoAgents
# Clear leftovers from an earlier interrupted run so arm 1's count starts at 0.
Get-AsideFiles | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
$r = Invoke-ZigBuild -Stamp '' -Unlock '' -LogName 'base.log'
Assert "baseline build exits 0" ($r.Code -eq 0)
Assert "agent installed" (Test-Path $AgentExe)

"== 1: control - nothing holding it, a NEW agent installs in place"
$stamp1 = "t192-c-$PID"
$r = Invoke-ZigBuild -Stamp $stamp1 -Unlock '' -LogName 'control.log'
Assert "control build exits 0" ($r.Code -eq 0)
Assert "installed agent carries the new stamp" (Test-StampIn $AgentExe $stamp1)
Assert "nothing was moved aside" ((Get-AsideFiles).Count -eq 0)

"== 2: teeth - with the guard off, a held agent still fails the build"
$held = Start-HeldAgent
Assert "held agent is running" ($null -ne $held -and -not $held.HasExited)
$stamp2 = "t192-n-$PID"
$r = Invoke-ZigBuild -Stamp $stamp2 -Unlock '0' -LogName 'negative.log'
Assert "guard-off build fails" ($r.Code -ne 0)
Assert "and it fails with AccessDenied on the agent" `
    ($r.Text -match 'AccessDenied' -and $r.Text -match 'ghoztty-agent\.exe')
Assert "the old agent is still the one on disk" (-not (Test-StampIn $AgentExe $stamp2))

"== 3: the fix - the same build succeeds with the guard on"
$stamp3 = "t192-f-$PID"
$r = Invoke-ZigBuild -Stamp $stamp3 -Unlock '' -LogName 'fix.log'
Assert "build exits 0 with an agent still running" ($r.Code -eq 0)
Assert "the NEW agent is on disk at the install path" (Test-StampIn $AgentExe $stamp3)
$aside = Get-AsideFiles
Assert "exactly one file was moved aside" ($aside.Count -eq 1)
Assert "the moved-aside file is the OLD binary" `
    ($aside.Count -eq 1 -and (Test-StampIn $aside[0].FullName $stamp1))
Assert "the running agent survived the move" `
    ($null -ne $held -and -not (Get-Process -Id $held.Id -ErrorAction SilentlyContinue).HasExited)
# The kill filters every acceptance script uses match on ExecutablePath, which
# Windows captures at process creation and does NOT follow across a rename - so
# a moved-aside image stays reachable by exactly the cleanup that owns it.
$stillFound = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
    Where-Object { $_.ExecutablePath -eq $AgentExe -and $_.ProcessId -eq $held.Id })
Assert "the moved-aside process still matches the repo-path kill filter" ($stillFound.Count -eq 1)

"== 4: the leftover is swept once the process holding it exits"
Stop-RepoAgents
$r = Invoke-ZigBuild -Stamp '' -Unlock '' -LogName 'sweep.log'
Assert "sweep build exits 0" ($r.Code -eq 0)
Assert "no moved-aside files remain" ((Get-AsideFiles).Count -eq 0)
Assert "zig-out is back on the tree's own agent build" (-not (Test-StampIn $AgentExe $stamp3))

Stop-RepoAgents
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit $script:failures
