# go-loop guard acceptance (tracker T139): the parity loop must never run twice
# and must never stay dead.
#
# Sections:
#   A. Lock lifecycle: free -> acquire -> held -> heartbeat -> release -> free.
#   B. Second session refused: a DIFFERENT pane, while the recorded owner is a
#      live process with a fresh heartbeat, gets BUSY (exit 3) and the lock file
#      still names the first owner. This is the two-loops-at-once case.
#   C. Same pane re-acquires (that is a /reset-context turn, not a rival) and
#      the turn counter advances.
#   D. Dead owner is taken over (reason=dead-owner) - a crash never wedges it.
#   E. Stale heartbeat is taken over (reason=stale-heartbeat) even with the
#      owner process alive - that is the turn-ended-with-a-summary case.
#   F. Pid recycling cannot hold the lock: same pid, wrong recorded start time
#      => treated as dead.
#   G. heartbeat/release from a non-owner => exit 4, lock untouched.
#   H. Watchdog decisions (dry run): healthy lock => none; stale + tracker rows
#      => new-window; no remaining tracker rows => none; rearm window not
#      elapsed => none.
#   I. Watchdog REAL re-entry, against a live debug GUI: no lock at all =>
#      it opens a window running the resume shim (asserted by reading the
#      pane's own output back).
#   J. Watchdog REAL nudge: lock owned by a live process with a stale
#      heartbeat, its pane alive and quiet => the resume prompt is typed into
#      that pane instead of opening a second window.
#
# Hermetic: every lock/state/tracker file lives under a per-run temp dir, the
# repo's own temp\go-loop.lock.json is never touched, and only ghoztty
# processes launched from zig-out are killed.
#
#   powershell -NoProfile -File test\win32\go-loop-guard.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-go-loop-$PID"
$lock = Join-Path $root 'go-loop.lock.json'
$state = Join-Path $root 'go-loop.watchdog.json'
$tracker = Join-Path $root 'tracker.md'
$emptyTracker = Join-Path $root 'tracker-empty.md'
$log = Join-Path $root 'watchdog.log'
$lockScript = Join-Path $Repo 'scripts\go-loop-lock.ps1'
$dogScript = Join-Path $Repo 'scripts\go-loop-watchdog.ps1'

New-Item -ItemType Directory -Force $root | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run the lock script and return @{ Code; Out }.
function Lock-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $lockScript,
        '-Repo', $Repo, '-LockPath', $lock) + $extra
    $out = & powershell @argList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Dog-Run([string[]]$extra, [string]$trackerPath) {
    if (-not $trackerPath) { $trackerPath = $tracker }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
        '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $state,
        '-Tracker', $trackerPath, '-LogPath', $log, '-Once') + $extra
    $out = & powershell @argList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Read-LockFile { if (Test-Path $lock) { Get-Content $lock -Raw | ConvertFrom-Json } else { $null } }
function Write-LockFile($obj) { ($obj | ConvertTo-Json -Depth 5) | Out-File -FilePath $lock -Encoding utf8 }

# A live stand-in for "somebody else's claude": a hidden sleeping powershell.
function Start-Sleeper {
    return Start-Process powershell -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 900'
}

$sleepers = @()
function Kill-Sleepers { foreach ($s in $sleepers) { Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue } }

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

function Ghoz($argList) {
    $out = & $Exe @argList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

# Depth-first walk of a +list --json splits tree.
function Find-Leaves($node, $acc) {
    if ($null -eq $node) { return }
    if ($node.type -eq 'leaf') { $acc.Add($node.terminal) | Out-Null; return }
    Find-Leaves $node.left $acc
    Find-Leaves $node.right $acc
}
function Get-WindowPane($target) {
    $r = Ghoz @('+list', '--json')
    if ($r.Code -ne 0) { return $null }
    try { $j = $r.Out | ConvertFrom-Json } catch { return $null }
    foreach ($w in $j.data.windows) {
        if ($w.target -ne $target) { continue }
        foreach ($t in $w.tabs) {
            $acc = New-Object System.Collections.ArrayList
            Find-Leaves $t.splits $acc
            if ($acc.Count -gt 0) { return $acc[0] }
        }
    }
    return $null
}

# A tracker with one remaining row, and one with none.
@(
    '| ID | Task | Phase | Deps | Status | Commits |',
    '|----|------|-------|------|--------|---------|',
    '| T999 | something left to do | K | - | todo | - |'
) -join "`r`n" | Out-File -FilePath $tracker -Encoding utf8
@(
    '| ID | Task | Phase | Deps | Status | Commits |',
    '|----|------|-------|------|--------|---------|',
    '| T999 | all finished | K | - | done | abc1234 |'
) -join "`r`n" | Out-File -FilePath $emptyTracker -Encoding utf8

# --- A. lifecycle ---------------------------------------------------------
"A. lock lifecycle"
$r = Lock-Run @('status')
Assert 'A1 status on a missing lock reports FREE' ($r.Code -eq 0 -and $r.Out -match '^FREE')

$owner = Start-Sleeper; $sleepers += $owner
$r = Lock-Run @('acquire', '-PaneId', 'PANE-A', '-ClaudePid', $owner.Id)
Assert 'A2 acquire on a free lock succeeds' ($r.Code -eq 0 -and $r.Out -match '^ACQUIRED')
Assert 'A3 acquire reports reason=free' ($r.Out -match 'reason=free')
$L = Read-LockFile
Assert 'A4 lock records the pane id' ($L.pane_id -eq 'PANE-A')
Assert 'A5 lock records the owner pid' ([int]$L.claude_pid -eq $owner.Id)
Assert 'A6 lock records the owner process name' ($L.claude_name -eq 'powershell')
Assert 'A7 lock records the owner start time' ($L.claude_start -match '^\d{4}-\d{2}-\d{2}T')
Assert 'A8 lock records a heartbeat' ($L.heartbeat -match '^\d{4}-\d{2}-\d{2}T')

$r = Lock-Run @('status', '-PaneId', 'PANE-A')
Assert 'A9 status reports held/alive/mine' ($r.Out -match '^held' -and $r.Out -match 'alive=True' -and $r.Out -match 'mine=True')

$before = (Read-LockFile).heartbeat
Start-Sleep -Milliseconds 1100
$r = Lock-Run @('heartbeat', '-PaneId', 'PANE-A')
Assert 'A10 heartbeat from the owner succeeds' ($r.Code -eq 0 -and $r.Out -match '^HEARTBEAT')
Assert 'A11 heartbeat advances the timestamp' ((Read-LockFile).heartbeat -ne $before)

# --- B. a second session is refused --------------------------------------
""
"B. second session refused"
$r = Lock-Run @('acquire', '-PaneId', 'PANE-B', '-ClaudePid', $PID)
Assert 'B1 a different pane is refused with exit 3' ($r.Code -eq 3)
Assert 'B2 refusal names the current owner' ($r.Out -match '^BUSY' -and $r.Out -match 'owner_pane=PANE-A')
Assert 'B3 refusal reports the heartbeat age' ($r.Out -match 'age=\d')
Assert 'B4 the lock still belongs to the first session' ((Read-LockFile).pane_id -eq 'PANE-A')

# --- C. same pane re-acquires --------------------------------------------
""
"C. same pane re-acquires (a /reset-context turn)"
$turnBefore = [int](Read-LockFile).turn
$r = Lock-Run @('acquire', '-PaneId', 'PANE-A', '-ClaudePid', $owner.Id)
Assert 'C1 same pane re-acquire succeeds' ($r.Code -eq 0 -and $r.Out -match '^ACQUIRED')
Assert 'C2 reason is own-lock' ($r.Out -match 'reason=own-lock')
Assert 'C3 the turn counter advances' ([int](Read-LockFile).turn -eq $turnBefore + 1)
# The upgrade script kills claude and relaunches it in the SAME pane: a new pid
# in a known pane is the same loop slot, not a rival.
$relaunched = Start-Sleeper; $sleepers += $relaunched
$r = Lock-Run @('acquire', '-PaneId', 'PANE-A', '-ClaudePid', $relaunched.Id)
Assert 'C4 a relaunched claude in the same pane keeps the lock' ($r.Code -eq 0 -and $r.Out -match 'reason=own-lock')
Assert 'C5 the lock now records the new pid' ([int](Read-LockFile).claude_pid -eq $relaunched.Id)

# --- D. dead owner is taken over -----------------------------------------
""
"D. dead owner taken over"
Stop-Process -Id $relaunched.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 600
$r = Lock-Run @('status', '-PaneId', 'PANE-B')
Assert 'D1 status sees the owner is gone' ($r.Out -match '^stale-dead' -and $r.Out -match 'alive=False')
$newOwner = Start-Sleeper; $sleepers += $newOwner
$r = Lock-Run @('acquire', '-PaneId', 'PANE-B', '-ClaudePid', $newOwner.Id)
Assert 'D2 a new session takes a dead owner''s lock' ($r.Code -eq 0 -and $r.Out -match 'reason=dead-owner')
Assert 'D3 the lock now names the new pane' ((Read-LockFile).pane_id -eq 'PANE-B')
Assert 'D4 the turn counter restarts for a new owner' ([int](Read-LockFile).turn -eq 1)

# --- E. stale heartbeat is taken over ------------------------------------
""
"E. stale heartbeat taken over"
$L = Read-LockFile
$L.heartbeat = (Get-Date).AddMinutes(-120).ToString('o')
Write-LockFile $L
$r = Lock-Run @('status', '-PaneId', 'PANE-C')
Assert 'E1 status flags a stale heartbeat with the owner alive' ($r.Out -match '^stale-heartbeat' -and $r.Out -match 'alive=True')
$r = Lock-Run @('acquire', '-PaneId', 'PANE-C', '-ClaudePid', $PID)
Assert 'E2 a stale lock is taken over' ($r.Code -eq 0 -and $r.Out -match 'reason=stale-heartbeat')
# ...but not before it is stale: -StaleMinutes is honoured.
$L = Read-LockFile
$L.heartbeat = (Get-Date).AddMinutes(-40).ToString('o')
Write-LockFile $L
$r = Lock-Run @('acquire', '-PaneId', 'PANE-D', '-ClaudePid', $PID, '-StaleMinutes', 90)
Assert 'E3 a 40m-old heartbeat is NOT stale at -StaleMinutes 90' ($r.Code -eq 3)
$r = Lock-Run @('acquire', '-PaneId', 'PANE-D', '-ClaudePid', $PID, '-StaleMinutes', 30)
Assert 'E4 the same lock IS stale at -StaleMinutes 30' ($r.Code -eq 0 -and $r.Out -match 'reason=stale-heartbeat')

# --- F. pid recycling ----------------------------------------------------
""
"F. recycled pid cannot hold the lock"
$L = Read-LockFile
$L.claude_start = (Get-Date).AddDays(-3).ToString('o')   # same live pid, wrong process
Write-LockFile $L
$r = Lock-Run @('status', '-PaneId', 'PANE-E')
Assert 'F1 a start-time mismatch reads as a dead owner' ($r.Out -match '^stale-dead')
$r = Lock-Run @('acquire', '-PaneId', 'PANE-E', '-ClaudePid', $PID)
Assert 'F2 the lock is taken over' ($r.Code -eq 0 -and $r.Out -match 'reason=dead-owner')

# --- G. non-owner heartbeat/release --------------------------------------
""
"G. non-owner cannot heartbeat or release"
$r = Lock-Run @('heartbeat', '-PaneId', 'PANE-X')
Assert 'G1 heartbeat from a stranger exits 4' ($r.Code -eq 4 -and $r.Out -match '^NOTOWNER')
$r = Lock-Run @('release', '-PaneId', 'PANE-X')
Assert 'G2 release from a stranger exits 4' ($r.Code -eq 4 -and $r.Out -match '^NOTOWNER')
Assert 'G3 the lock survives both' ((Read-LockFile).pane_id -eq 'PANE-E')
$r = Lock-Run @('release', '-PaneId', 'PANE-E')
Assert 'G4 the owner can release' ($r.Code -eq 0 -and $r.Out -match '^RELEASED')
Assert 'G5 the lock file is gone' (-not (Test-Path $lock))
$r = Lock-Run @('release', '-PaneId', 'PANE-E')
Assert 'G6 releasing an absent lock is a no-op' ($r.Code -eq 0 -and $r.Out -match '^FREE')

# --- H. watchdog decisions (dry run) -------------------------------------
""
"H. watchdog decisions"
$healthy = Start-Sleeper; $sleepers += $healthy
Lock-Run @('acquire', '-PaneId', 'PANE-H', '-ClaudePid', $healthy.Id) | Out-Null
$r = Dog-Run @('-DryRun')
Assert 'H1 a healthy lock produces no action' ($r.Out -match 'ACTION none')
Assert 'H2 the healthy tick is logged' ($r.Out -match 'healthy: pane=PANE-H')

$L = Read-LockFile
$L.heartbeat = (Get-Date).AddMinutes(-120).ToString('o')
Write-LockFile $L
$r = Dog-Run @('-DryRun')
Assert 'H3 a stale lock with a gone pane opens a window' ($r.Out -match 'ACTION new-window')
Assert 'H4 the re-entry names the remaining task count' ($r.Out -match 'remaining=1')

Remove-Item $lock -Force -ErrorAction SilentlyContinue
$r = Dog-Run @('-DryRun')
Assert 'H5 no lock at all also re-enters' ($r.Out -match 'ACTION new-window')

$r = Dog-Run @('-DryRun') $emptyTracker
Assert 'H6 a tracker with nothing left produces no action' ($r.Out -match 'ACTION none')
Assert 'H7 and says why' ($r.Out -match 'no remaining tracker rows')

# Rearm: a real (non-dry) action stamps the state file; the next tick holds off.
([ordered]@{ last_action = 'new-window'; last_action_at = (Get-Date).ToString('o') } |
    ConvertTo-Json) | Out-File -FilePath $state -Encoding utf8
$r = Dog-Run @('-DryRun')
Assert 'H8 the rearm window suppresses a second re-entry' ($r.Out -match 'ACTION none')
Assert 'H9 and says so' ($r.Out -match 'rearm not elapsed')
$r = Dog-Run @('-DryRun', '-RearmMinutes', 0)
Assert 'H10 -RearmMinutes 0 re-enters again' ($r.Out -match 'ACTION new-window')
Remove-Item $state -Force -ErrorAction SilentlyContinue

# --- I / J. real re-entry against a live GUI -----------------------------
""
"I. real re-entry (new window)"
Stop-DebugGhoztty
$gui = Start-Process $Exe -PassThru -ArgumentList '--session-persistence=false'
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    if ((Ghoz @('+list')).Code -eq 0) { $ready = $true; break }
}
Assert 'I0 the debug GUI is up' $ready

if ($ready) {
    Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue
    $marker = 'GO-LOOP-REENTRY-OK'
    $r = Dog-Run @('-GhozttyExe', $Exe, '-ClaudeCommand', 'echo', '-ResumePrompt', $marker,
        '-WindowTarget', 'go-loop-test')
    Assert 'I1 the watchdog opened a window' ($r.Out -match 'ACTION new-window')
    $pane = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $pane = Get-WindowPane 'go-loop-test'
        if ($pane) { break }
    }
    Assert 'I2 the window exists and has a pane' ($null -ne $pane)
    if ($pane) {
        $seen = ''
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $seen = (Ghoz @('+read', "--name=$($pane.id)", '--lines=20')).Out
            if ($seen -match $marker) { break }
        }
        Assert 'I3 the pane really ran the resume shim' ($seen -match $marker)
    }
    Assert 'I4 the shim carries the whole quoted prompt' `
        ((Get-Content (Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd') -Raw) -match "echo `"$marker`"")
    Assert 'I5 the re-entry is recorded in the state file' `
        ((Test-Path $state) -and ((Get-Content $state -Raw | ConvertFrom-Json).last_action -eq 'new-window'))
    Ghoz @('+close', '--target=go-loop-test') | Out-Null

    ""
    "J. real re-entry (nudge a live but stalled session)"
    $r = Ghoz @('+new-window', '--target=go-loop-live', "--working-directory=$Repo")
    $pane = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $pane = Get-WindowPane 'go-loop-live'
        if ($pane) { break }
    }
    Assert 'J0 a stand-in loop pane is open' ($null -ne $pane)
    if ($pane) {
        $live = Start-Sleeper; $sleepers += $live
        Lock-Run @('acquire', '-PaneId', $pane.id, '-ClaudePid', $live.Id) | Out-Null
        $L = Read-LockFile
        $L.heartbeat = (Get-Date).AddMinutes(-120).ToString('o')
        Write-LockFile $L
        Remove-Item $state -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2   # let the pane settle so its tail stops moving
        $r = Dog-Run @('-GhozttyExe', $Exe, '-ResumePrompt', 'read go.md and go', '-ProbeGapSeconds', 3)
        Assert 'J1 a live owner in a live pane is nudged, not replaced' ($r.Out -match 'ACTION nudge')
        Assert 'J2 no second window was opened' (-not (Get-WindowPane 'go-loop-test'))
        $seen = ''
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $seen = (Ghoz @('+read', "--name=$($pane.id)", '--lines=20')).Out
            if ($seen -match 'read go\.md and go') { break }
        }
        Assert 'J3 the resume prompt was typed into the pane' ($seen -match 'read go\.md and go')

        # A pane that is still producing output is mid-task: leave it alone.
        Remove-Item $state -Force -ErrorAction SilentlyContinue
        Ghoz @('+send-keys', "--target=$($pane.id)", 'for /l %i in (1,1,9999) do @echo busy %i', 'Enter') | Out-Null
        Start-Sleep -Seconds 2
        $r = Dog-Run @('-GhozttyExe', $Exe, '-ProbeGapSeconds', 3)
        Assert 'J4 a pane that is still producing output is not nudged' ($r.Out -match 'ACTION none')
        Assert 'J5 and the watchdog says why' ($r.Out -match 'still producing output')
        Ghoz @('+send-keys', "--target=$($pane.id)", 'C-c') | Out-Null
        Ghoz @('+close', '--target=go-loop-live') | Out-Null
    }
}

# --- cleanup --------------------------------------------------------------
Kill-Sleepers
Stop-DebugGhoztty
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd') -Force -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) { "ALL PASS" ; exit 0 }
else { "$($script:failures) FAILURE(S)" ; exit 1 }
