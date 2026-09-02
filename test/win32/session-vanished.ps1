# T1162 acceptance: a persistent session whose shell already exited must stop
# being offered as a running one.
#
# WHAT THE USER SAW
#
# Ghoztty keeps a terminal session alive in the background so you can come back
# to it later. On 2026-08-31 six of those background sessions had their shells
# killed; a minute later `ghoztty +sessions` still reported all six as running
# against pids that no longer existed, and they were still listed the next day.
# Picking one does nothing useful - there is no process to come back to - and
# because the record is written to sessions.json it comes back on every restart,
# so the list only ever grows.
#
# WHY NOTHING NOTICED
#
# Exit detection rides the child's OUTPUT path: `SessionStore.markExited` is
# reached from exactly one place, `onChildOutput`, which the pty reader nudges
# with a zero-length call on EOF. That needs a reader. A detached session whose
# `--pty-host` holder is gone has none - no reader thread, no EOF, no nudge -
# and nothing polled. The fix is the reaper's vanished-child sweep: one process
# table snapshot every few seconds, and a session whose shell is missing from
# two consecutive snapshots is tombstoned.
#
# WHAT THIS SCRIPT DOES
#
#   A. A named, agent-backed pane, its session id, its live shell pid, and the
#      holder serving it - plus a typed marker echoed back, so a dead session
#      later proves something rather than being how the pane always was.
#   B. Kill ONLY the app. The session detaches and must still be reported alive:
#      the positive control for persistence, and the state the bug lives in.
#   C. Reproduce the field state exactly - holder gone, shell gone, nobody
#      reading. The holder is killed first (which is what the user's agent had
#      long since lost) and the shell is confirmed out of the process table.
#   D. THE OUTCOME: within a bounded wait the agent stops reporting that session
#      as running, so nothing offers the user a session that cannot come back.
#   E. The other half, which matters just as much: a session whose shell IS
#      running is never swept. A fresh pane stays alive and interactive across
#      several sweep intervals.
#
# WHAT THIS SCRIPT DOES NOT PROVE, measured rather than assumed
#
# It does not prove the SWEEP is what dropped the session. On 2026-08-31 this
# script was run against the same build with the sweep's off switch thrown
# (GHOZTTY_AGENT_VANISH_SWEEP=0) and section D still passed: killing the holder
# from OUTSIDE also tears the session down through the holder-loss path, which
# is a different mechanism reaching the same answer. The state the field bug
# needs - a session alive with no reader of any kind - is not reachable by
# killing processes from a script, so an inverted assertion here would have been
# a lie dressed as a control, and it was removed rather than kept green.
#
# So read this harness for what it measures: the user-visible OUTCOME in both
# directions, which is a real regression guard for either mechanism breaking.
# The sweep's own rules - two strikes, a pid the table cannot see, a session
# younger than the snapshot, a failed snapshot - are pinned by unit tests in
# `src\remote\agent\session.zig` against a synthetic process table, where the
# state IS constructible. A follow-up task owns building the no-reader state on
# box (the agent-handoff path is the likeliest route to it).
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint (lib\Isolation),
# GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test, and only processes
# whose ExecutablePath is the exe/agent under test are ever stopped - never the
# user's installed release, which owns their live sessions.
#
#   powershell -NoProfile -File test\win32\session-vanished.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# How long D waits. The sweep's own cadence is a snapshot every 5 reaper ticks
# and two consecutive misses, so ~10 s is the expected answer by either route;
# 90 s is a wide margin for a loaded box, and a bounded wait costs a real
# regression nothing.
$SweepTimeoutSec = 90
# How long E watches a LIVE session, in the same units: comfortably more than
# several sweep intervals, so a sweep that tombstones indiscriminately is caught.
$LiveWatchSec = 25

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'SESSION-VANISHED' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'SESSION-VANISHED' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# --- process helpers: ONLY ever the binaries under test ----------------------

# These return a PLAIN (unrolled) result, not the `return , @(...)` idiom used
# elsewhere in this directory. That wrapper preserves an array through the
# pipeline - including an EMPTY one, which then counts as ONE element at an
# `@(...)` call site, so "no holders are left" would measure 1 and every count
# assertion built on it would be a phantom. Unrolled, `@(Get-TestHolders).Count`
# is 0 for none and 1 for one, which is what the assertions below mean.
function Get-TestApps {
    return (Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return (Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
function Get-TestAgents {
    return (Get-TestAgentProcs | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Get-TestHolders {
    return (Get-TestAgentProcs | Where-Object { $_.CommandLine -match '--pty-host' })
}
function Count-TestAgents { return @(Get-TestAgents).Count }
function Count-TestHolders { return @(Get-TestHolders).Count }
function Test-Alive([int]$procId) {
    if ($procId -le 0) { return $false }
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}
function Wait-Gone([int]$procId, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Alive $procId)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}
function Stop-Everything {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgents)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
    foreach ($p in (Get-TestHolders)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
}

# --- CLI plumbing ------------------------------------------------------------

# T1238: the CLI runs ON THE TEST DESKTOP. It also captures stdout and stderr to
# a file itself, which is what the `cmd /c "... > file 2>&1"` dance was for -
# ghoztty.exe is GUI-subsystem, so a PowerShell pipe reads empty (T245) - and it
# bounds the wait, so a wedged server still fails the script instead of hanging
# it.
function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $argv = @($argsLine -split '\s+' | Where-Object { $_ -ne '' })
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}
function Run-CliArgs([string[]]$argv, [string]$out, [int]$timeoutSec = 15) {
    return Run-Cli ($argv -join ' ') $out $timeoutSec
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

# The agent's roster. PS 5.1 hands a JSON array down the pipeline as ONE object,
# so everything here goes through @() before it is counted.
function Get-Sessions([string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 15
    if ($code -ne 0) { return @() }
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
# "Does the agent still say this session is RUNNING?" Both ways it can stop
# saying so count as gone: the row drops out of the roster, or it is still there
# with `alive:false`. Either answer means a user is no longer offered a session
# that cannot come back.
function Test-ReportedRunning([string]$sessionId, [string]$tag) {
    foreach ($r in (Get-Sessions $tag)) {
        if ([string]$r.id -eq $sessionId) { return [bool]$r.alive }
    }
    return $false
}
function Wait-NotRunning([string]$sessionId, [string]$tag, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ReportedRunning $sessionId "$tag$i")) { return $true }
        $i++
        Start-Sleep -Milliseconds 1500
    }
    return $false
}
function Read-PaneText([string]$target, [string]$tag, [int]$lines = 60) {
    $rc = Run-Cli "+read --name=$target --lines=$lines" "$tmp\read-$tag.txt" 15
    if ($rc -ne 0) { return '' }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', '')
}
function Wait-PaneHas([string]$target, [string]$tag, [string]$needle, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        if ((Read-PaneText $target "$tag$i") -match [regex]::Escape($needle)) { return $true }
        $i++
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in (Windows-Of $tree)) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Get-Tree([string]$tag) {
    $rc = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}

# Bring the app up and wait for it to answer IPC. Returns its pid, or 0.
function Start-TestApp([string]$title, [int]$timeoutSec = 45) {
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @(
        "--title=$title", '--window-width=100', '--window-height=30'))
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-Cli '+list --json' "$tmp\list-up-$title.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-up-$title.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like "*$title*" })
            if ($app.Count -ge 1) { return [int]$app[0].ProcessId }
        }
        Start-Sleep -Milliseconds 600
    }
    return 0
}

# The named, agent-backed pane a section works on: its leaf (carrying the
# session id) once the agent has adopted it.
function Wait-NamedLeaf([string]$paneName, [string]$tag, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $lv = @((All-Leaves (Get-Tree "$tag$i")) | Where-Object { $_.name -eq $paneName })
        if ($lv.Count -eq 1 -and $lv[0].session_id) { return $lv[0] }
        $i++
        Start-Sleep -Milliseconds 700
    }
    return $null
}
function Wait-ShellPid([string]$sessionId, [string]$tag, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        foreach ($r in (Get-Sessions "$tag$i")) {
            if ([string]$r.id -eq $sessionId -and $r.alive -eq $true -and [int]$r.pid -gt 0) {
                return [int]$r.pid
            }
        }
        $i++
        Start-Sleep -Milliseconds 600
    }
    return 0
}

$root = Join-Path $env:TEMP "ghoztty-session-vanished-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedSweep = $env:GHOZTTY_AGENT_VANISH_SWEEP

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # Holder-backed spawning is the DEFAULT since T909; clear only an inherited
    # opt-out, because section C's premise is that there IS a holder to remove.
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue
    # The sweep is on for this run; an inherited off switch would silently make
    # section D measure the holder-loss path alone.
    Remove-Item env:GHOZTTY_AGENT_VANISH_SWEEP -ErrorAction SilentlyContinue

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'vanish1162')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    # T1238: the GUI and every CLI call below start on a background test desktop,
    # so this script no longer throws a window across the user's screen.
    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    $td = New-TestDesktop


    # ========================================================================
    Say '== A: baseline - a live, agent-backed, holder-served pane'
    # ========================================================================
    $appPid = Start-TestApp 't1162-vanish'
    Assert 'A1 premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) {
        Write-TestVerdict -Label 'SESSION-VANISHED' -Pass $script:passes -Fail $script:failures
    }
    Assert-GhozttyIsolated -Exe $Exe

    $pane = 't1162p'
    $firstId = $null
    foreach ($lf in (All-Leaves (Get-Tree 'a1'))) { if (-not $firstId) { $firstId = $lf.id } }
    if ($firstId) {
        Run-Cli "+split --pane=$firstId --name=$pane --direction=right" "$tmp\split.txt" 20 | Out-Null
    } else {
        Run-Cli "+new-window --name=$pane" "$tmp\newwin.txt" 20 | Out-Null
    }

    $leaf = Wait-NamedLeaf $pane 'a2'
    Assert 'A2 the named pane exists and is agent-backed (it carries a session id)' ($null -ne $leaf)
    if ($null -eq $leaf) {
        Write-TestVerdict -Label 'SESSION-VANISHED' -Pass $script:passes -Fail $script:failures
    }
    $sessionId = [string]$leaf.session_id

    $shellPid = Wait-ShellPid $sessionId 'a3'
    Assert 'A3 the agent roster reports a live shell pid for that session' ($shellPid -gt 0)
    Assert 'A4 the session is holder-backed (a --pty-host process is serving it)' (
        (Count-TestHolders) -ge 1)

    # The pane is LIVE before anything is killed. Without this a "dead" session
    # later would prove only that it was never alive.
    $warm = "T1162WARM$PID" + 'Z'
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $warm, 'Enter') "$tmp\keys-warm.txt" 12 | Out-Null
    Assert 'A5 the pane is LIVE (the shell echoed a typed marker)' (
        Wait-PaneHas $pane 'warm' $warm 30)
    if ($shellPid -le 0) {
        Write-TestVerdict -Label 'SESSION-VANISHED' -Pass $script:passes -Fail $script:failures
    }

    # ========================================================================
    Say '== B: detach - the app dies, the session must persist'
    # ========================================================================
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Assert 'B1 the app is gone' (Wait-Gone $appPid 20)
    Assert 'B2 premise: the session manager survived the app' ((Count-TestAgents) -ge 1)
    # Persistence itself, and the exact state the bug lives in: nobody attached.
    Assert 'B3 the detached session is still reported as running (persistence works)' (
        Test-ReportedRunning $sessionId 'b3')

    # ========================================================================
    Say '== C: the field state - holder gone, shell gone, nobody reading'
    # ========================================================================
    $holderPids = @()
    foreach ($h in (Get-TestHolders)) { $holderPids += [int]$h.ProcessId }
    Assert 'C0 premise: a holder was serving the session' ($holderPids.Count -ge 1)
    foreach ($id in $holderPids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    $holdersGone = $true
    foreach ($id in $holderPids) { if (-not (Wait-Gone $id 20)) { $holdersGone = $false } }
    Assert 'C1 the holder was removed (no --pty-host process is left)' (
        $holdersGone -and (Count-TestHolders) -eq 0)

    # Losing the pseudoconsole normally takes the shell with it. If this box
    # leaves it running, end it directly: the state this harness needs is "the
    # shell has exited and nothing is reading", and how it got there is not the
    # subject. Reported either way so a run is readable afterwards.
    if (Test-Alive $shellPid) {
        Say "    the shell outlived its holder; ending pid $shellPid directly"
        Stop-Process -Id $shellPid -Force -ErrorAction SilentlyContinue
    }
    Assert "C2 premise: the session's shell (pid $shellPid) has left the process table" (
        Wait-Gone $shellPid 30)
    Assert 'C3 premise: the session manager is still running (it is the thing under test)' (
        (Count-TestAgents) -ge 1)

    # ========================================================================
    Say '== D: the agent must stop offering a session that cannot come back'
    # ========================================================================
    $dropped = Wait-NotRunning $sessionId 'd' $SweepTimeoutSec
    Assert "D1 the dead session stopped being reported as running (within ${SweepTimeoutSec}s)" $dropped

    # ========================================================================
    Say '== E: a session whose shell IS running is never swept'
    # ========================================================================
    # The other half of the rule. A sweep that tombstoned indiscriminately would
    # pass D and destroy the feature, so a live session is watched across several
    # sweep intervals and then asked to prove it is still interactive.
    $appPid2 = Start-TestApp 't1162-live'
    Assert 'E1 premise: a second app instance is up' ($appPid2 -gt 0)
    if ($appPid2 -gt 0) {
        $pane2 = 't1162q'
        $firstId2 = $null
        foreach ($lf in (All-Leaves (Get-Tree 'e1'))) { if (-not $firstId2) { $firstId2 = $lf.id } }
        if ($firstId2) {
            Run-Cli "+split --pane=$firstId2 --name=$pane2 --direction=right" "$tmp\split2.txt" 20 | Out-Null
        } else {
            Run-Cli "+new-window --name=$pane2" "$tmp\newwin2.txt" 20 | Out-Null
        }
        $leaf2 = Wait-NamedLeaf $pane2 'e2'
        Assert 'E2 premise: the second pane is agent-backed' ($null -ne $leaf2)
        if ($null -ne $leaf2) {
            $sessionId2 = [string]$leaf2.session_id
            Assert 'E3 premise: it has a live shell pid' ((Wait-ShellPid $sessionId2 'e3') -gt 0)
            Start-Sleep -Seconds $LiveWatchSec
            Assert "E4 the live session is STILL reported as running after ${LiveWatchSec}s of sweeps" (
                Test-ReportedRunning $sessionId2 'e4')
            $live = "T1162LIVE$PID" + 'Z'
            Run-CliArgs @('+send-keys', "--target=$pane2", 'echo', 'Space', $live, 'Enter') "$tmp\keys-live.txt" 12 | Out-Null
            Assert 'E5 and it is still interactive (the shell echoed a typed marker)' (
                Wait-PaneHas $pane2 'live' $live 30)
        }
    }

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-Everything
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    if ($null -ne $savedSweep) { $env:GHOZTTY_AGENT_VANISH_SWEEP = $savedSweep }
    else { Remove-Item env:GHOZTTY_AGENT_VANISH_SWEEP -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard session-vanished -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'SESSION-VANISHED' -Pass $script:passes -Fail $script:failures
