# T911 acceptance: output printed between two ring snapshots survives an agent
# crash, instead of existing only until the holder is told to forget it.
#
# In the user's terms: the background session manager can die at any moment, and
# the history a FRESH window can replay must not stop at the last time scrollback
# was saved to disk. Everything printed since then is still on the shell that is
# still running - it just has to still be held somewhere.
#
# What was wrong before T911: the agent ACKed a holder the instant it took bytes
# off the pipe, and an ACK is the holder's permission to FREE. So the stretch
# between the last ring snapshot and a crash lived in exactly one place - the
# agent's in-memory ring - and died with it. The holder had already dropped it,
# and the snapshot on disk never had it. It was invisible while the APP stayed up
# (the app still had the pixels), which is why T906's harness could not see it.
#
# So this harness measures the RING SNAPSHOT FILE on disk, not the pane. The file
# is what a fresh viewer replays from, and it is the thing that had the hole.
#
# Sections:
#   A. Baseline: a holder-backed pane, and PROOF that ring snapshots are running
#      in this run - a first marker typed and then observed landing in a .ring
#      file. That also synchronizes the clock: a snapshot just happened, so the
#      whole snapshot interval is available for section B.
#   B. The gap. A second marker is typed and confirmed on screen, and confirmed
#      ABSENT from every .ring file - it exists only in the agent's memory and in
#      the holder's replay buffer. Then the session manager is hard-killed, so
#      nothing flushes on the way out.
#   C. Recovery. The replacement manager adopts the surviving holder, and the
#      holder replays the gap it was never told to release. THE assertion: the
#      second marker reaches a .ring file on disk.
#
# `-NegativeControl` runs the SAME build with `GHOZTTY_AGENT_DURABLE_ACK=0`, the
# off switch for the durability gate, and asserts the marker is LOST. That is a
# real measurement of this box rather than an inverted assertion: if the control
# arm also finds the marker, this harness is not measuring what it claims.
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint (lib\Isolation),
# GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test, and only processes
# whose ExecutablePath is the exe/agent under test are ever stopped - never the
# user's installed release, which owns their live sessions.
#
#   powershell -NoProfile -File test\win32\holder-durable.ps1
#   powershell -NoProfile -File test\win32\holder-durable.ps1 -NegativeControl
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl
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

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'HOLDER-DURABLE' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'HOLDER-DURABLE' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# --- process helpers: ONLY ever the binaries under test ----------------------

function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
function Get-TestAgents {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Get-TestHolders {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -match '--pty-host' })
}
function Test-Alive([int]$procId) {
    if ($procId -le 0) { return $false }
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}
function Stop-Everything {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgents)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
    foreach ($p in (Get-TestHolders)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
}
function Wait-NewAgent($excludePids, $timeoutSec = 45) {
    $excludePids = @($excludePids | ForEach-Object { [int]$_ })
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $fresh = @((Get-TestAgents) | Where-Object { $excludePids -notcontains [int]$_.ProcessId })
        if ($fresh.Count -gt 0) { return [int]$fresh[0].ProcessId }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

# --- CLI plumbing ------------------------------------------------------------

# ghoztty.exe is GUI-subsystem, so a pipe reads empty; redirect through cmd and
# bound the wait, or a wedged server hangs the script instead of failing it.
function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Run-CliArgs([string[]]$argv, [string]$out, [int]$timeoutSec = 15) {
    return Run-Cli ($argv -join ' ') $out $timeoutSec
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

function Get-Sessions([string]$tmp, [string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Read-PaneText([string]$tmp, [string]$target, [string]$tag) {
    $rc = Run-Cli "+read --name=$target --lines=2000" "$tmp\read-$tag.txt" 12
    if ($rc -ne 0) { return '' }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', '')
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
function Get-Tree([string]$tmp, [string]$tag) {
    $rc = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}

# --- the measurement: what is on DISK ----------------------------------------

# Every ring snapshot under the per-run state dir, read as bytes. Found by
# extension rather than re-derived from a path, so a state-dir move cannot
# silently turn this into a test of nothing.
function Get-RingFiles([string]$root) {
    return , @(Get-ChildItem -Path $root -Filter '*.ring' -Recurse -File -ErrorAction SilentlyContinue)
}
function Ring-Has([string]$root, [string]$needle) {
    foreach ($f in (Get-RingFiles $root)) {
        $txt = ''
        try { $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::ASCII) } catch { continue }
        if ($txt -match [regex]::Escape($needle)) { return $true }
    }
    return $false
}
function Wait-RingHas([string]$root, [string]$needle, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Ring-Has $root $needle) { return $true }
        Start-Sleep -Milliseconds 900
    }
    return $false
}

$root = Join-Path $env:TEMP "ghoztty-holder-durable-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedDurable = $env:GHOZTTY_AGENT_DURABLE_ACK

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # Holder-backed spawning is the DEFAULT since T909: this arm sets nothing and
    # only CLEARS an inherited opt-out, because with holders off there is no
    # replay buffer at all and the whole script would measure nothing.
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue
    if ($NegativeControl) {
        # The control arm: same build, same box, durability gate OFF - i.e. the
        # pre-T911 ack-on-delivery behavior.
        $env:GHOZTTY_AGENT_DURABLE_ACK = '0'
        Say "== NEGATIVE CONTROL: GHOZTTY_AGENT_DURABLE_ACK=0 (the marker must be LOST)"
    } else {
        Remove-Item env:GHOZTTY_AGENT_DURABLE_ACK -ErrorAction SilentlyContinue
    }

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'durable911')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    # ========================================================================
    Say "== A: baseline - a holder-backed pane, and ring snapshots proven live"
    # ========================================================================
    $before = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @(
        '--title=t911-durable', '--window-width=100', '--window-height=30') | Out-Null

    $appPid = 0
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-Cli '+list --json' "$tmp\list-a.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-a.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like '*t911-durable*' })
            if ($app.Count -ge 1) { $appPid = [int]$app[0].ProcessId; break }
        }
        Start-Sleep -Milliseconds 600
    }
    Assert 'A1 premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) {
        Write-TestVerdict -Label 'HOLDER-DURABLE' -Pass $script:passes -Fail $script:failures
    }
    Assert-GhozttyIsolated -Exe $Exe

    $pane = 't911p'
    $firstId = $null
    foreach ($lf in (All-Leaves (Get-Tree $tmp 'a1'))) { if (-not $firstId) { $firstId = $lf.id } }
    if ($firstId) {
        Run-Cli "+split --pane=$firstId --name=$pane --direction=right" "$tmp\split.txt" 20 | Out-Null
    } else {
        Run-Cli "+new-window --name=$pane" "$tmp\newwin.txt" 20 | Out-Null
    }

    $agentPid = Wait-NewAgent $before 45
    Assert 'A2 premise: a session manager is running' ($agentPid -ne 0)

    $paneLeaf = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $lv = @((All-Leaves (Get-Tree $tmp 'a2')) | Where-Object { $_.name -eq $pane })
        if ($lv.Count -eq 1 -and $lv[0].session_id) { $paneLeaf = $lv[0]; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'A3 the named pane exists and is agent-backed (it carries a session id)' (
        $null -ne $paneLeaf)
    if ($null -eq $paneLeaf) {
        Write-TestVerdict -Label 'HOLDER-DURABLE' -Pass $script:passes -Fail $script:failures
    }
    $sessionId = [string]$paneLeaf.session_id

    $shellPidA = 0
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        foreach ($r in (Get-Sessions $tmp 'a')) {
            if ([string]$r.id -eq $sessionId -and $r.alive -eq $true) { $shellPidA = [int]$r.pid }
        }
        if ($shellPidA -gt 0) { break }
        Start-Sleep -Milliseconds 600
    }
    Assert 'A4 the agent roster reports a live shell pid for that session' ($shellPidA -gt 0)
    Assert 'A5 the session is holder-backed (a --pty-host process is serving it)' (
        (Get-TestHolders).Count -ge 1)

    # A first marker, followed all the way to DISK. Two things at once: it proves
    # ring snapshots are actually running in this run (without that, section C's
    # assertion could fail for a reason that has nothing to do with T911), and it
    # tells us a snapshot just fired - so section B has the whole interval.
    $warm = "T911WARM$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $warm, 'Enter') "$tmp\keys-warm.txt" 12 | Out-Null
    $sawWarm = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Read-PaneText $tmp $pane 'warm') -match [regex]::Escape($warm)) { $sawWarm = $true; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'A6 the pane is LIVE (the shell echoed the warm-up marker)' $sawWarm
    $warmOnDisk = Wait-RingHas $tmp $warm 75
    Assert 'A7 ring snapshots are running: the warm-up marker reached a .ring file' $warmOnDisk
    if (-not $warmOnDisk) {
        Say "    diagnostic: ring files seen -> $((Get-RingFiles $tmp) | ForEach-Object { $_.Name })"
        Write-TestVerdict -Label 'HOLDER-DURABLE' -Pass $script:passes -Fail $script:failures
    }

    # ========================================================================
    Say "== B: the gap - a marker that is on screen but NOT yet on disk"
    # ========================================================================
    $marker = "T911GAP$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $marker, 'Enter') "$tmp\keys-gap.txt" 12 | Out-Null
    $sawGap = $false
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if ((Read-PaneText $tmp $pane 'gap') -match [regex]::Escape($marker)) { $sawGap = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert 'B1 the gap marker is on screen (the shell printed it)' $sawGap

    # THE premise. If this fails, a snapshot landed inside the window and the run
    # is measuring a marker that was already safe - which would pass either way.
    $notYet = -not (Ring-Has $tmp $marker)
    Assert 'B2 premise: the gap marker is NOT in any ring snapshot yet' $notYet

    # Hard kill: no shutdown path runs, so nothing flushes the ring on the way
    # out. That is the crash this task is about.
    Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Assert 'B3 premise: the session manager is really gone' (-not (Test-Alive $agentPid))
    Assert 'B4 premise: the shell outlived it (the holder still owns it)' (Test-Alive $shellPidA)
    Assert 'B5 premise: the crash flushed nothing (the marker is still not on disk)' (
        -not (Ring-Has $tmp $marker))

    # ========================================================================
    Say "== C: recovery - the replacement manager gets the gap back from the holder"
    # ========================================================================
    $newAgentPid = Wait-NewAgent (@($before) + @($agentPid)) 60
    Assert 'C1 a replacement session manager came up' ($newAgentPid -ne 0 -and $newAgentPid -ne $agentPid)

    # Adoption, not relaunch - the same shell pid. Without this the holder never
    # replayed anything and C3 would be measuring the wrong failure.
    $shellPidC = 0
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        foreach ($r in (Get-Sessions $tmp 'c')) {
            if ([string]$r.id -eq $sessionId -and $r.alive -eq $true) { $shellPidC = [int]$r.pid }
        }
        if ($shellPidC -gt 0) { break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'C2 premise: the same shell was adopted (same pid, nothing relaunched)' (
        $shellPidC -gt 0 -and $shellPidC -eq $shellPidA)

    # THE assertion. The bytes the agent lost with its memory can only come back
    # from the holder, and the holder only still has them because the ACK it got
    # meant "on disk" rather than "delivered".
    $recovered = Wait-RingHas $tmp $marker 100
    if ($NegativeControl) {
        Assert 'C3 (control) the gap marker was LOST, as the pre-T911 behavior loses it' (-not $recovered)
    } else {
        Assert 'C3 the gap marker reached a ring snapshot after recovery' $recovered
        if (-not $recovered) {
            Say "    diagnostic: ring files -> $((Get-RingFiles $tmp) | ForEach-Object { "$($_.Name) ($($_.Length) bytes)" })"
        }
    }
} finally {
    Stop-Everything
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    if ($null -ne $savedDurable) { $env:GHOZTTY_AGENT_DURABLE_ACK = $savedDurable }
    else { Remove-Item env:GHOZTTY_AGENT_DURABLE_ACK -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard holder-durable -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'HOLDER-DURABLE' -Pass $script:passes -Fail $script:failures
