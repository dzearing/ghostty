# T969 acceptance: a pane printing FASTER than the holder retains still has a
# recoverable window - scrollback is saved on VOLUME, not only on a timer.
#
# In the user's terms: after T911, a crash of the background session manager
# gives you back everything printed since scrollback was last saved. But it was
# only saved every 30 seconds, and only about a megabyte of unsaved output can
# be held anywhere in the meantime - so a pane in the middle of a noisy build
# printed past that between two saves and the OLDEST of it was dropped to make
# room. The pane you were watching was fine; what a crash could hand back was
# not. The panes that print the most are exactly the ones whose recovery is
# worth the most, which is why this is the case worth closing.
#
# So this harness measures the RING SNAPSHOT FILE on disk, like its T911 sibling
# `holder-durable.ps1` - the file a fresh viewer replays from is the thing that
# had the hole - but it overruns the holder's replay ring before the crash
# instead of staying inside it.
#
# SCALED-DOWN NUMBERS, deliberately. The shipped pair is a 1 MB holder ring and
# a snapshot due at 512 KB of unsaved output; this run sets 64 KB and 32 KB via
# the agent's env knobs and floods ~256 KB. Same ratio, same mechanism, and the
# whole flood is over in a second or two - printing a megabyte through a ConPTY
# would take long enough to race the 30-second timer this harness has to stay
# inside, which would make the control arm measure the timer rather than the
# trigger. That the SHIPPED numbers hold the same ratio is pinned where it
# belongs, as a unit test over the two constants (`pty_holder_child.zig`).
#
# Sections:
#   A. Baseline: a holder-backed pane, and PROOF that ring snapshots are running
#      in this run - a first marker typed and observed landing in a .ring file.
#      That also synchronizes the clock: a snapshot just happened, so the whole
#      30-second interval is available for section B.
#   B. The overrun. A second marker is typed, confirmed on screen and confirmed
#      ABSENT from disk; then ~256 KB is printed - four times what the holder
#      can hold. THE assertion: the marker reaches a .ring file well inside the
#      periodic interval, because the volume trigger fired, not the timer.
#   C. The crash. The session manager is hard-killed and the replacement adopts
#      the surviving holder. The marker is still on disk - the holder dropped it
#      long ago, so nothing but the volume-triggered snapshot could have kept it.
#
# `-NegativeControl` runs the SAME build with GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES=0,
# the off switch for the volume trigger, and asserts the marker is LOST. That is
# a real measurement of this box rather than an inverted assertion: if the
# control arm also keeps the marker, this harness is not measuring what it
# claims (the likeliest cause being a periodic snapshot landing inside section
# B's window, which would make both arms pass).
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint (lib\Isolation),
# GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test, and only processes
# whose ExecutablePath is the exe/agent under test are ever stopped - never the
# user's installed release, which owns their live sessions.
#
#   powershell -NoProfile -File test\win32\holder-volume.ps1
#   powershell -NoProfile -File test\win32\holder-volume.ps1 -NegativeControl
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

# The scaled-down pair, held in the shipped ratio (threshold = half the ring).
$HolderReplayBytes = 65536
$VolumeBytes = 32768
# Four times the holder ring, so the marker is unquestionably past its horizon.
$FloodLines = 512
$FloodWidth = 500

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'HOLDER-VOLUME' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'HOLDER-VOLUME' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
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
function Read-PaneText([string]$tmp, [string]$target, [string]$tag, [int]$lines = 60) {
    $rc = Run-Cli "+read --name=$target --lines=$lines" "$tmp\read-$tag.txt" 15
    if ($rc -ne 0) { return '' }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', '')
}
function Wait-PaneHas([string]$tmp, [string]$target, [string]$tag, [string]$needle, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        if ((Read-PaneText $tmp $target "$tag$i") -match [regex]::Escape($needle)) { return $true }
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
        Start-Sleep -Milliseconds 700
    }
    return $false
}

$root = Join-Path $env:TEMP "ghoztty-holder-volume-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedDurable = $env:GHOZTTY_AGENT_DURABLE_ACK
$savedReplay = $env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES
$savedVolume = $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # Holder-backed spawning is the DEFAULT since T909: clear only an inherited
    # opt-out, because with holders off there is no replay buffer to overrun and
    # the whole script would measure nothing.
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue
    # T911's durability gate is the floor this builds on: without it the holder
    # frees on delivery and section C is a measurement of T911, not of T969.
    Remove-Item env:GHOZTTY_AGENT_DURABLE_ACK -ErrorAction SilentlyContinue
    $env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES = "$HolderReplayBytes"
    if ($NegativeControl) {
        # The control arm: same build, same box, volume trigger OFF - i.e. the
        # pre-T969 behavior, where only the 30-second timer writes scrollback.
        $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES = '0'
        Say "== NEGATIVE CONTROL: GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES=0 (the marker must be LOST)"
    } else {
        $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES = "$VolumeBytes"
    }

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'volume969')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    # ========================================================================
    Say "== A: baseline - a holder-backed pane, and ring snapshots proven live"
    # ========================================================================
    $before = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @(
        '--title=t969-volume', '--window-width=100', '--window-height=30') | Out-Null

    $appPid = 0
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-Cli '+list --json' "$tmp\list-a.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-a.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like '*t969-volume*' })
            if ($app.Count -ge 1) { $appPid = [int]$app[0].ProcessId; break }
        }
        Start-Sleep -Milliseconds 600
    }
    Assert 'A1 premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) {
        Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
    }
    Assert-GhozttyIsolated -Exe $Exe

    $pane = 't969p'
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
        Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
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
    # ring snapshots are running in this run at all, and it tells us a snapshot
    # just fired - so section B has the whole periodic interval to itself.
    $warm = "T969WARM$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $warm, 'Enter') "$tmp\keys-warm.txt" 12 | Out-Null
    Assert 'A6 the pane is LIVE (the shell echoed the warm-up marker)' (
        Wait-PaneHas $tmp $pane 'warm' $warm 30)
    $warmOnDisk = Wait-RingHas $tmp $warm 75
    Assert 'A7 ring snapshots are running: the warm-up marker reached a .ring file' $warmOnDisk
    if (-not $warmOnDisk) {
        Say "    diagnostic: ring files seen -> $((Get-RingFiles $tmp) | ForEach-Object { $_.Name })"
        Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
    }
    $snapshotAt = Get-Date

    # ========================================================================
    Say "== B: the overrun - a marker, then more output than the holder can hold"
    # ========================================================================
    $marker = "T969GAP$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $marker, 'Enter') "$tmp\keys-gap.txt" 12 | Out-Null
    Assert 'B1 the marker is on screen (the shell printed it)' (
        Wait-PaneHas $tmp $pane 'gap' $marker 20)

    # THE premise. If this fails, a snapshot landed between the marker and here
    # and the run is measuring a marker that was already safe - which would pass
    # either way.
    Assert 'B2 premise: the marker is NOT in any ring snapshot yet' (-not (Ring-Has $tmp $marker))

    # The flood: ~256 KB, four times what this run's holder retains. Typed as a
    # file (`--keys-file` sends bytes verbatim) rather than as key notation, so
    # the command line is not re-tokenized on its way through the CLI - and it
    # calls powershell.exe explicitly, so it does not depend on which shell
    # flavor this box opens panes with.
    $done = "T969DONE$PID" + "Z"
    $floodCmd = "powershell -NoProfile -Command `"1..$FloodLines | ForEach-Object { 'F' * $FloodWidth }; 'x' + '$done'`""
    $floodFile = Join-Path $tmp 'flood.txt'
    [IO.File]::WriteAllText($floodFile, $floodCmd, [Text.Encoding]::ASCII)
    Run-CliArgs @('+send-keys', "--target=$pane", "--keys-file=$floodFile", 'Enter') "$tmp\keys-flood.txt" 15 | Out-Null

    $floodDone = Wait-PaneHas $tmp $pane 'flood' $done 90
    Assert 'B3 premise: the flood finished (its end marker printed)' $floodDone
    $floodSecs = [int]((Get-Date) - $snapshotAt).TotalSeconds
    Say "    (flood complete $floodSecs s after the last snapshot; the periodic pass is 30 s)"

    # THE assertion. Well inside the periodic interval, the marker is on disk -
    # so the trigger that wrote it was the VOLUME of output, not the clock. The
    # window is bounded so a periodic pass cannot be mistaken for the trigger.
    $windowSecs = [Math]::Max(4, 24 - $floodSecs)
    $early = Wait-RingHas $tmp $marker $windowSecs
    if ($NegativeControl) {
        Assert 'B4 (control) with the trigger off, nothing wrote the marker inside the interval' (-not $early)
    } else {
        Assert 'B4 the marker reached a .ring file inside the periodic interval (the volume trigger fired)' $early
    }

    # Hard kill: no shutdown path runs, so nothing flushes on the way out. That
    # is the crash this task is about.
    Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Assert 'B5 premise: the session manager is really gone' (-not (Test-Alive $agentPid))
    Assert 'B6 premise: the shell outlived it (the holder still owns it)' (Test-Alive $shellPidA)

    # ========================================================================
    Say "== C: after the crash - what a fresh viewer can still replay"
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

    # THE end-to-end assertion. The holder dropped these bytes long before the
    # crash - they were four floods ago in a 64 KB ring - so the only thing that
    # can still hand them back is a snapshot the volume trigger wrote.
    $recovered = Wait-RingHas $tmp $marker 100
    if ($NegativeControl) {
        Assert 'C3 (control) the marker was LOST, as it is lost without the volume trigger' (-not $recovered)
    } else {
        Assert 'C3 the marker is still on disk after the crash' $recovered
        if (-not $recovered) {
            Say "    diagnostic: ring files -> $((Get-RingFiles $tmp) | ForEach-Object { "$($_.Name) ($($_.Length) bytes)" })"
        }
    }
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-Everything
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    if ($null -ne $savedDurable) { $env:GHOZTTY_AGENT_DURABLE_ACK = $savedDurable }
    else { Remove-Item env:GHOZTTY_AGENT_DURABLE_ACK -ErrorAction SilentlyContinue }
    if ($null -ne $savedReplay) { $env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES = $savedReplay }
    else { Remove-Item env:GHOZTTY_AGENT_HOLDER_REPLAY_BYTES -ErrorAction SilentlyContinue }
    if ($null -ne $savedVolume) { $env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES = $savedVolume }
    else { Remove-Item env:GHOZTTY_AGENT_SNAPSHOT_VOLUME_BYTES -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard holder-volume -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'HOLDER-VOLUME' -Pass $script:passes -Fail $script:failures
