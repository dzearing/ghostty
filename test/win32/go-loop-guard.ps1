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
#   P. The supervisor's own liveness is observable (T440): a running watchdog
#      stamps a beacon on every tick including the quiet ones, a -Once tick
#      never does, -Status reports both autostart hooks, and the every-10-minute
#      revive task is registered so a dead watchdog cannot wait for a logon.
#   Q. `status` asks the PANE when the recorded pid is dead (T440), so a claude
#      relaunched in the owning pane reads as held rather than stale-dead -
#      while `acquire` stays pid-based, on purpose.
#   R. A turn longer than the staleness window is not nudged (T253): the lock's
#      freshness follows the session TRANSCRIPT, which Claude Code advances by
#      itself, so a working turn is visibly alive without anybody remembering to
#      beat the heartbeat - and the nudge, when it does fire, is reset-first so
#      landing it on a live session cannot queue a second task into that context.
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
$execScript = Join-Path $Repo 'scripts\go-loop-exec.ps1'

# Get-PaneOccupant / ConvertTo-SendKeysLiteral (section M drives them directly,
# section N needs the escaper to type a path into a pane).
. (Join-Path $Repo 'scripts\go-loop-pane-probe.ps1')

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

function Exec-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $execScript,
        '-Repo', $Repo, '-LockPath', $lock, '-GhozttyExe', $Exe) + $extra
    $out = & powershell @argList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Read-LockFile { if (Test-Path $lock) { Get-Content $lock -Raw | ConvertFrom-Json } else { $null } }
function Write-LockFile($obj) { ($obj | ConvertTo-Json -Depth 5) | Out-File -FilePath $lock -Encoding utf8 }

# "This loop has shown no sign of life for N minutes" - which since T253 means
# BOTH signals, not just the heartbeat. Every fixture here is acquired from the
# session running this script, so `acquire` records that session's own live
# transcript; backdating the heartbeat alone would leave the lock reading fresh
# off the harness's own pulse, and the assertions below would be measuring this
# file rather than the code. Section R owns the case where the transcript is
# deliberately kept moving.
function Set-LockStale($minutes) {
    $L = Read-LockFile
    $L.heartbeat = (Get-Date).AddMinutes(-$minutes).ToString('o')
    if ($L.PSObject.Properties.Name -contains 'transcript') { $L.transcript = '' }
    Write-LockFile $L
}

# A live stand-in for "somebody else's claude": a hidden sleeping powershell.
function Start-Sleeper {
    return Start-Process powershell -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 900'
}

$sleepers = @()
function Kill-Sleepers { foreach ($s in $sleepers) { Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue } }

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: this run's own IPC endpoint, before any CLI call. Sections I/J drive a
# live GUI and this script's whole subject is a watchdog that CLOSES windows —
# pointed at the user's installed release by an inherited `$GHOZTTY_IPC_SOCKET`
# it would close theirs.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'gloop')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Exact-exe rather than a '*zig-out*' CommandLine match (T53b), plus the
# sibling agent and the debug session-layout manifest, so a previous run's
# pane cannot be focused in place of this run's fixture.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
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
function Get-WindowTitle($target) {
    $r = Ghoz @('+list', '--json')
    if ($r.Code -ne 0) { return $null }
    try { $j = $r.Out | ConvertFrom-Json } catch { return $null }
    foreach ($w in $j.data.windows) { if ($w.target -eq $target) { return $w.title } }
    return $null
}
function New-TestWindow($target) {
    Ghoz @('+new-window', "--target=$target", "--working-directory=$Repo") | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $p = Get-WindowPane $target
        if ($p) { return $p }
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
Set-LockStale 120
$r = Lock-Run @('status', '-PaneId', 'PANE-C')
Assert 'E1 status flags a stale heartbeat with the owner alive' ($r.Out -match '^stale-heartbeat' -and $r.Out -match 'alive=True')
$r = Lock-Run @('acquire', '-PaneId', 'PANE-C', '-ClaudePid', $PID)
Assert 'E2 a stale lock is taken over' ($r.Code -eq 0 -and $r.Out -match 'reason=stale-heartbeat')
# ...but not before it is stale: -StaleMinutes is honoured.
Set-LockStale 40
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

Set-LockStale 120
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
Assert-GhozttyPrivateEndpoint -Exe $Exe
# T211 desktop: every window these sections open is driven over IPC, never by
# SendInput or screen capture, so this migrates off the interactive desktop
# cleanly - and a watchdog test that yanks the user's foreground while they
# work is exactly what they asked us to stop doing.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
$td = $null
try {
    $td = New-TestDesktop
    Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -WorkingDirectory $Repo | Out-Null
} catch {
    # A desktop we cannot create must not cost the whole suite; say so loudly
    # and fall back, rather than reporting a green run that never happened.
    "  NOTE test desktop unavailable ($_); falling back to the interactive desktop"
    $td = $null
    Start-Process $Exe -ArgumentList '--session-persistence=false' | Out-Null
}
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    if ((Ghoz @('+list')).Code -eq 0) { $ready = $true; break }
}
Assert 'I0 the debug GUI is up' $ready
# Before the watchdog is pointed at anything: prove it is ours.
if ($ready) { Assert-GhozttyIsolated -Exe $Exe }

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
        Set-LockStale 120
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

    ""
    "K. execution-window marking"
    $paneA = New-TestWindow 'exec-a'
    $paneC = New-TestWindow 'plain-c'
    Assert 'K0 two stand-in windows are open' ($null -ne $paneA -and $null -ne $paneC)
    if ($paneA -and $paneC) {
        $r = Exec-Run @('mark', '-PaneId', $paneA.id)
        Assert 'K1 mark succeeds' ($r.Code -eq 0 -and $r.Out -match '^MARKED')
        Assert 'K2 the window title carries the marker' ((Get-WindowTitle 'exec-a') -like '`[go-loop`]*')
        Assert 'K3 an unmarked window keeps its own title' ((Get-WindowTitle 'plain-c') -notlike '`[go-loop`]*')
        $r = Exec-Run @('list', '-PaneId', $paneA.id)
        Assert 'K4 list flags only the marked window' `
            (([regex]::Matches($r.Out, '(?m)^EXEC ')).Count -eq 1 -and $r.Out -match 'EXEC exec-a')
        $r = Exec-Run @('unmark', '-PaneId', $paneA.id)
        Assert 'K5 unmark succeeds' ($r.Code -eq 0 -and $r.Out -match '^UNMARKED')
        Assert 'K6 the marker is gone from the title' ((Get-WindowTitle 'exec-a') -notlike '`[go-loop`]*')
    }

    ""
    "L. duplicate execution windows resolve themselves"
    $paneB = New-TestWindow 'exec-b'
    Assert 'L0 a second execution window is open' ($null -ne $paneB)
    if ($paneA -and $paneB -and $paneC) {
        # A holds the lock (a live owner); B is a marked duplicate; C is the
        # user's task-filing window - unmarked, and must be left strictly alone.
        $primary = Start-Sleeper; $sleepers += $primary
        Remove-Item $lock -Force -ErrorAction SilentlyContinue
        Lock-Run @('acquire', '-PaneId', $paneA.id, '-ClaudePid', $primary.Id) | Out-Null
        Exec-Run @('mark', '-PaneId', $paneB.id) | Out-Null
        $titleC = Get-WindowTitle 'plain-c'

        $r = Exec-Run @('claim', '-PaneId', $paneA.id, '-GraceSeconds', 1)
        Assert 'L1 the lock holder claims primary' ($r.Code -eq 0 -and $r.Out -match '^PRIMARY')
        Assert 'L2 it marks its own window' ((Get-WindowTitle 'exec-a') -like '`[go-loop`]*')
        Assert 'L3 it names the duplicate' ($r.Out -match 'DUPLICATE execution window target=exec-b')
        Assert 'L4 it reports resolving exactly one' ($r.Out -match 'resolved 1 duplicate')
        $gone = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not (Get-WindowPane 'exec-b')) { $gone = $true; break }
        }
        Assert 'L5 the duplicate window is closed' $gone
        Assert 'L6 the UNMARKED window is untouched' `
            (($null -ne (Get-WindowPane 'plain-c')) -and ((Get-WindowTitle 'plain-c') -eq $titleC))

        # The loser's side of the same protocol: a marked window that does not
        # hold the lock stands down, tells the primary, and unmarks itself.
        $paneD = New-TestWindow 'exec-d'
        Assert 'L7 a would-be duplicate is open' ($null -ne $paneD)
        if ($paneD) {
            Exec-Run @('mark', '-PaneId', $paneD.id) | Out-Null
            $r = Exec-Run @('claim', '-PaneId', $paneD.id, '-NoSelfClose')
            Assert 'L8 it stands down with exit 3' ($r.Code -eq 3 -and $r.Out -match '^STAND-DOWN')
            Assert 'L9 it names the primary it deferred to' ($r.Out -match "notified primary in pane $($paneA.id)")
            Assert 'L10 it unmarks itself' ((Get-WindowTitle 'exec-d') -notlike '`[go-loop`]*')
            $seen = ''
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 500
                $seen = (Ghoz @('+read', "--name=$($paneA.id)", '--lines=20')).Out
                if ($seen -match 'stood down') { break }
            }
            Assert 'L11 the primary was really told, in its own pane' ($seen -match 'duplicate execution window .* stood down')

            # ...and with self-close on (the default), the duplicate goes away.
            Exec-Run @('mark', '-PaneId', $paneD.id) | Out-Null
            Exec-Run @('claim', '-PaneId', $paneD.id) | Out-Null
            $gone = $false
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 500
                if (-not (Get-WindowPane 'exec-d')) { $gone = $true; break }
            }
            Assert 'L12 a stood-down duplicate closes itself' $gone
        }
        Ghoz @('+close', '--target=exec-a') | Out-Null
        Ghoz @('+close', '--target=plain-c') | Out-Null
    }

    ""
    "N. a live Claude TUI is never sent a shell command (T241)"
    # The 2026-07-31 near-miss: the lock named a DEAD pid while a claude was
    # running in the pane, so the watchdog typed the resume shim's PATH into a
    # TUI. It became a chat message; send-keys reported 0; nothing re-entered.
    $paneN = New-TestWindow 'go-loop-tui'
    Assert 'N0 a stand-in loop pane is open' ($null -ne $paneN)
    if ($paneN) {
        $dead = Start-Sleeper; $sleepers += $dead
        Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue
        Lock-Run @('acquire', '-PaneId', $paneN.id, '-ClaudePid', $dead.Id) | Out-Null
        Stop-Process -Id $dead.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 600
        Assert 'N1 the lock now reads stale-dead' ((Lock-Run @('status', '-PaneId', $paneN.id)).Out -match '^stale-dead')

        # Positive control first: a pane genuinely at a shell prompt still gets
        # the shim, so N3 is not just "the watchdog stopped doing anything".
        $r = Dog-Run @('-DryRun', '-GhozttyExe', $Exe)
        Assert 'N2 a dead owner at a shell prompt still gets the shim' ($r.Out -match 'ACTION restart-in-pane')
        Assert 'N3 and the pane was classified as a shell' ($r.Out -match 'occupant=shell')

        # Now put a stand-in TUI in the pane and re-decide. It must keep the
        # bottom of the screen (a plain `echo` scrolls a shell prompt back
        # under it, which is the "claude exited" case, not this one), and it
        # must be quiet so the still-producing check does not veto the nudge.
        $fake = Join-Path $root 'fake-tui.cmd'
        @(
            '@echo off',
            'echo   bypass permissions on (shift+tab to cycle)',
            'ping -n 120 127.0.0.1 >nul'
        ) -join "`r`n" | Out-File -FilePath $fake -Encoding ascii
        Ghoz @('+send-keys', "--target=$($paneN.id)", (ConvertTo-SendKeysLiteral $fake), 'Enter') | Out-Null
        Start-Sleep -Seconds 3
        $r = Dog-Run @('-DryRun', '-GhozttyExe', $Exe, '-ProbeGapSeconds', 3)
        Assert 'N4 a live claude in the pane is nudged, not shim''d' ($r.Out -match 'ACTION nudge')
        Assert 'N5 and the watchdog says who it found' ($r.Out -match 'occupant=claude')
        Assert 'N6 the shim was never typed into it' ($r.Out -notmatch 'ACTION restart-in-pane')
        Ghoz @('+send-keys', "--target=$($paneN.id)", 'C-c') | Out-Null
        Ghoz @('+close', '--target=go-loop-tui') | Out-Null
    }
}

# --- M / O: pure, so they run even when no GUI came up --------------------
""
"O. adopt: a relaunched claude in the owning pane keeps the lock"
$adopter = Start-Sleeper; $sleepers += $adopter
Remove-Item $lock -Force -ErrorAction SilentlyContinue
Lock-Run @('acquire', '-PaneId', 'PANE-O', '-ClaudePid', $PID) | Out-Null
$r = Lock-Run @('adopt', '-PaneId', 'PANE-O', '-ClaudePid', $adopter.Id)
Assert 'O1 adopt succeeds for the owning pane' ($r.Code -eq 0 -and $r.Out -match '^ADOPTED')
$L = Read-LockFile
Assert 'O2 the lock now names the new pid' ([int]$L.claude_pid -eq $adopter.Id)
Assert 'O3 the pane is unchanged' ($L.pane_id -eq 'PANE-O')
Assert 'O4 the reason records the adoption' ($L.reason -eq 'adopted')
Assert 'O5 the lock reads healthy again' ((Lock-Run @('status', '-PaneId', 'PANE-O')).Out -match '^held')
$r = Lock-Run @('adopt', '-PaneId', 'PANE-STRANGER', '-ClaudePid', $adopter.Id)
Assert 'O6 adopt from another pane is refused' ($r.Code -eq 4 -and $r.Out -match '^NOTOWNER')
$r = Lock-Run @('adopt', '-PaneId', 'PANE-O', '-ClaudePid', 999999)
Assert 'O7 adopting a dead pid is refused' ($r.Code -eq 2 -and $r.Out -match 'not a live process')

# --- M. pane occupancy classifier (pure) ----------------------------------
""
"M. pane occupancy classifier"
Assert 'M1 a cmd prompt is a shell' ((Get-PaneOccupant -Tail "some output`r`nD:\git\ghoztty>") -eq 'shell')
Assert 'M2 a powershell prompt is a shell' ((Get-PaneOccupant -Tail "PS D:\git\ghoztty> ") -eq 'shell')
Assert 'M3 a git-bash prompt is a shell' ((Get-PaneOccupant -Tail "David@BOX MINGW64 /d/git`r`n$ ") -eq 'shell')
Assert 'M4 the Claude composer is claude' `
    ((Get-PaneOccupant -Tail "  bypass permissions on (shift+tab to cycle)") -eq 'claude')
Assert 'M5 an interrupt hint is claude' ((Get-PaneOccupant -Tail "Determining... (esc to interrupt)") -eq 'claude')
Assert 'M6 an empty pane is unknown' ((Get-PaneOccupant -Tail '') -eq 'unknown')
Assert 'M7 unrecognised output is unknown' ((Get-PaneOccupant -Tail "building...`r`nlink ok") -eq 'unknown')

# --- U. one identity implementation (T168) --------------------------------
""
"U. process identity has exactly one implementation"
# The lock decides who may WORK and the upgrade decides whether to RELAUNCH,
# both from the same fact: is the claude that owned this loop still the same
# live process? They used to answer it from separate copies of one resolver,
# which is the shape of the bug T138 fixed - a fix applied to one copy leaves
# the other making the opposite call. These arms go red if a copy comes back.
$lockSrc = Get-Content $lockScript -Raw
Assert 'U1 the lock dot-sources the shared helpers' ($lockSrc -match 'loop-session\.ps1')
Assert 'U2 the lock keeps no private pid resolver' (-not ($lockSrc -match 'function\s+Resolve-ClaudePid'))
Assert 'U3 the lock keeps no private process stamp' (-not ($lockSrc -match 'function\s+Get-ProcStamp'))

# ...and the convergence is not only textual. A junk $env:CLAUDE_PID must not
# take the lock down with it: the private copy cast it to [int] unguarded, which
# is a TERMINATING error under this script's ErrorActionPreference, so a stray
# value in the environment would have failed `status` outright instead of
# falling through to the ancestry walk. The shared resolver TryParses.
$savedClaudePid = $env:CLAUDE_PID
try {
    $env:CLAUDE_PID = 'not-a-pid'
    $r = Lock-Run @('status', '-NoPaneProbe')
} finally {
    if ($null -eq $savedClaudePid) { Remove-Item Env:\CLAUDE_PID -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_PID = $savedClaudePid }
}
Assert 'U4 a non-numeric CLAUDE_PID does not fail the lock' `
    ($r.Code -eq 0 -and $r.Out -notmatch 'Cannot convert' -and $r.Out -match '^(FREE|held|stale)')

# --- R. a working turn is never nudged (T253, pure) ------------------------
""
"R. a long turn beats the staleness window by itself"
# The 2026-07-31 failure: 46 minutes of build + acceptance run + delivery with
# nobody refreshing the heartbeat, so the watchdog typed a prompt into a session
# that was working. The heartbeat is a checkpoint a model has to remember; the
# transcript is a pulse Claude Code emits on every message and tool result.
$rPane = 'PANE-R'
$rTrans = Join-Path $root 'session-R.jsonl'
'{"type":"user"}' | Out-File -FilePath $rTrans -Encoding utf8
$rProc = Start-Sleeper; $sleepers += $rProc
Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue
$r = Lock-Run @('acquire', '-PaneId', $rPane, '-ClaudePid', $rProc.Id, '-TranscriptPath', $rTrans)
Assert 'R1 acquire records the session transcript' `
    ($r.Code -eq 0 -and (Read-LockFile).transcript -eq $rTrans)
Assert 'R2 and says which pulse it got' ($r.Out -match 'pulse=transcript')

# A turn that has been working for two hours without a checkpoint.
$L = Read-LockFile
$L.heartbeat = (Get-Date).AddMinutes(-120).ToString('o')
Write-LockFile $L
(Get-Item $rTrans).LastWriteTime = Get-Date

$r = Lock-Run @('status', '-PaneId', $rPane)
Assert 'R3 a moving transcript keeps a 2h-old heartbeat healthy' ($r.Out -match '^held')
Assert 'R4 and names the transcript as the signal' ($r.Out -match 'by=transcript')
$S = (Lock-Run @('status', '-PaneId', $rPane, '-Json')).Out | ConvertFrom-Json
Assert 'R5 the checkpoint age is still reported separately' ([double]$S.heartbeat_age_minutes -gt 100)
Assert 'R6 the pulse does not rewrite the turn or the pid' `
    ([int]$S.turn -eq 1 -and [int]$S.claude_pid -eq $rProc.Id)

# The watchdog must therefore do nothing at all - without even reaching the
# pane probe, which is what made this a false nudge rather than a near miss.
$r = Dog-Run @('-DryRun')
Assert 'R7 the watchdog leaves a working turn alone' ($r.Out -match 'ACTION none')
Assert 'R8 and logs it as healthy, by the transcript' ($r.Out -match 'healthy: .*by=transcript')

# A second session must not be able to take the lock either: "no sign of life"
# is one rule, and both readers ask the same question.
$r = Lock-Run @('acquire', '-PaneId', 'PANE-R-RIVAL')
Assert 'R9 a rival cannot take the lock from a working turn' ($r.Code -eq 3 -and $r.Out -match '^BUSY')

# Positive controls: the transcript rescues nothing once IT goes quiet, and a
# lock that never had one behaves exactly as it did before T253.
(Get-Item $rTrans).LastWriteTime = (Get-Date).AddMinutes(-180)
$r = Lock-Run @('status', '-PaneId', $rPane)
Assert 'R10 a transcript that stopped moving is stale again' ($r.Out -match '^stale-heartbeat')
Assert 'R11 and the signal falls back to the heartbeat' ($r.Out -match 'by=heartbeat')
$r = Dog-Run @('-DryRun')
Assert 'R12 and the watchdog re-enters, as it always did' ($r.Out -match 'ACTION (nudge|restart-in-pane|new-window)')

$L = Read-LockFile
$L.transcript = ''
Write-LockFile $L
$r = Lock-Run @('status', '-PaneId', $rPane)
Assert 'R13 a lock with no transcript at all is unchanged behaviour' `
    ($r.Out -match '^stale-heartbeat' -and $r.Out -match 'by=heartbeat')

# ...and it does not have to stay that way: a lock written before T253 gains the
# pulse at the next heartbeat, which also runs inside the session.
$r = Lock-Run @('heartbeat', '-PaneId', $rPane, '-TranscriptPath', $rTrans)
$L = Read-LockFile
Assert 'R14 heartbeat adopts the pulse for a lock that had none' `
    ($r.Code -eq 0 -and $L.transcript -eq $rTrans)
Assert 'R15 without disturbing the turn or the pid' `
    ([int]$L.turn -eq 1 -and [int]$L.claude_pid -eq $rProc.Id)
Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue

# The nudge itself, when it does fire. Claude Code QUEUES text typed during a
# turn and delivers it at the end, so the prompt has to be one that cannot start
# a second task in a context that already holds one.
$dogAst = [System.Management.Automation.Language.Parser]::ParseFile($dogScript, [ref]$null, [ref]$null)
function Get-DogDefault($name) {
    $p = $dogAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
    if (-not $p -or -not $p.DefaultValue) { return '' }
    return $p.DefaultValue.Extent.Text.Trim("'", '"')
}
$prompt = Get-DogDefault 'ResumePrompt'
Assert 'R16 the default nudge resets the context first' ($prompt -match '/reset-context read go\.md and go')
Assert 'R17 and does not lead with a slash (the command menu eats the first Enter)' `
    ($prompt -and -not $prompt.StartsWith('/'))
Assert 'R18 the still-producing backstop samples a screen, not five lines' `
    ([int](Get-DogDefault 'ProbeLines') -ge 40 -and [int](Get-DogDefault 'ProbeGapSeconds') -ge 15)
# The whole point of rule 1: claude output in the SCROLLBACK with a shell
# prompt at the bottom means claude exited. Shim it, do not nudge it.
Assert 'M8 claude output above a shell prompt is a shell' `
    ((Get-PaneOccupant -Tail "esc to interrupt`r`nbypass permissions on`r`nD:\git\ghoztty>") -eq 'shell')
# ...and a composer line must never read as a prompt just because it ends in
# '>' (the loose "ends with >" regex is the trap this anchored rule replaces).
Assert 'M9 the composer line is not a shell prompt' `
    ((Get-PaneOccupant -Tail "  bypass permissions on`r`n| > run: dir D:\git >") -eq 'claude')
# send-keys eats backslash escapes, so a shim path under a user called "tom"
# would arrive with a TAB in it. Double them or the re-entry types nonsense.
Assert 'M10 a path with \t survives send-keys escaping' `
    ((ConvertTo-SendKeysLiteral 'C:\Users\tom\AppData\Local\Temp\go.cmd') -eq 'C:\\Users\\tom\\AppData\\Local\\Temp\\go.cmd')
Assert 'M11 a path with no backslash is unchanged' ((ConvertTo-SendKeysLiteral 'go.cmd') -eq 'go.cmd')
# T440: a WORKING Claude Code scrolls every idle-composer marker off the screen.
# Measured on the box 2026-08-04, a pane with a live session mid-task came back
# 'unknown' - the answer that makes the watchdog type a shell command at it.
Assert 'M12 a busy session is claude' `
    ((Get-PaneOccupant -Tail "Kneading... (15m 9s - 47.1k tokens)") -eq 'claude')
# Chrome wording has drifted twice; the transcript glyphs have not. Built from
# code points because this file must stay ASCII.
$bullet = [string][char]0x25CF
$connector = [string][char]0x23BF
Assert 'M13 a transcript bullet is claude' `
    ((Get-PaneOccupant -Tail "$bullet Reading go.md") -eq 'claude')
Assert 'M14 a tool-result connector is claude' `
    ((Get-PaneOccupant -Tail "  $connector  Read 373 lines") -eq 'claude')
# ...and rule 1 still outranks all of it, which is what makes matching
# scrollback safe: a claude that EXITED leaves its glyphs AND a shell prompt.
Assert 'M15 glyphs above a shell prompt are still a shell' `
    ((Get-PaneOccupant -Tail "$bullet Reading go.md`r`n  $connector  Read 373 lines`r`nD:\git\ghoztty>") -eq 'shell')

# T244: the exact claude-in-this-pane walk. Pure - a fake Win32_Process
# snapshot drives Find-ClaudeDescendant directly.
function New-FakeProc([int]$ProcessId, [int]$ParentProcessId, [string]$Name, [string]$CommandLine) {
    [pscustomobject]@{
        ProcessId = $ProcessId; ParentProcessId = $ParentProcessId
        Name = $Name; CommandLine = $CommandLine
    }
}
$fakeTable = @(
    (New-FakeProc 100 1   'pwsh.exe'   'pwsh')                                          # the pane's shell
    (New-FakeProc 200 100 'claude.exe' 'claude --dangerously-skip-permissions')         # claude under it
    (New-FakeProc 300 200 'pwsh.exe'   'pwsh -NoProfile')                               # claude's tool shell
    (New-FakeProc 400 2   'claude.exe' 'claude')                                        # claude in ANOTHER pane
)
Assert 'M16 a live claude under the shell is found' `
    ((Find-ClaudeDescendant -ShellPid 100 -Procs $fakeTable) -eq 200)
Assert 'M17 a claude in another pane does not count' `
    ((Find-ClaudeDescendant -ShellPid 2 -Procs @((New-FakeProc 100 1 'pwsh.exe' 'pwsh'))) -eq 0)
# Chrome's native-messaging host is claude.exe too, but it is not a TUI in any
# pane - a browser launched FROM the pane must not classify the pane as claude.
$chromeTable = @(
    (New-FakeProc 100 1   'pwsh.exe'   'pwsh')
    (New-FakeProc 500 100 'chrome.exe' 'chrome')
    (New-FakeProc 501 500 'claude.exe' '"C:\Users\u\.local\bin\claude.exe" --chrome-native-host')
)
Assert 'M18 the chrome native host is not a pane claude' `
    ((Find-ClaudeDescendant -ShellPid 100 -Procs $chromeTable) -eq 0)
# Windows reuses pids, so a torn snapshot can hold a parent loop; the walk
# must terminate, not hang the watchdog.
$loopTable = @(
    (New-FakeProc 100 300 'pwsh.exe' 'pwsh')
    (New-FakeProc 300 100 'cmd.exe'  'cmd')
)
Assert 'M19 a pid loop in the snapshot terminates with no match' `
    ((Find-ClaudeDescendant -ShellPid 100 -Procs $loopTable) -eq 0)

# --- S. the submission gate (T562, pure) ----------------------------------
# `send-keys` exiting 0 means the bytes reached the pane, not that the session
# acted on them. On 2026-08-07 the loop sat all night at a composer holding an
# unsubmitted `read go.md and go` while every log in the chain said OK. The gate
# both the watchdog nudge and the upgrade's reuse path now run through decides
# from MOTION, and presses the submit again when a pane holding the prompt will
# not move. I/O is injected, so the decision is checkable without a pane.
""
"S. submission gate"
. (Join-Path $Repo 'scripts\loop-session.ps1')
$P562 = 'read go.md and go'
# A pane that answers on its own is submitted, and nothing extra is pressed.
$presses = 0
$feed = 0
$g = Wait-LoopSubmitted -Text $P562 -SettleSeconds 0 -WatchSeconds 3 `
    -Read { $script:feed++; "working... $script:feed" } -Submit { $script:presses++ }
Assert 'S1 a moving pane is submitted' ($g.Submitted)
Assert 'S2 and nothing extra was pressed' ($g.Attempts -eq 0 -and $presses -eq 0)

# The filed wedge: the prompt is on screen and the pane is frozen. Pressing the
# submit wakes it - which is the ONE thing the old code never did, because it
# read "on screen" as success.
$presses = 0
$woke = $false
$g = Wait-LoopSubmitted -Text $P562 -SettleSeconds 0 -WatchSeconds 2 `
    -Read { if ($script:woke) { "answering $script:presses" } else { "> $P562" } } `
    -Submit { $script:presses++; $script:woke = $true }
Assert 'S3 a frozen pane holding the prompt is submitted by the gate' ($g.Submitted)
Assert 'S4 with exactly one press' ($g.Attempts -eq 1 -and $presses -eq 1)
# The regression that broke every happy-path run while this was being built:
# the baseline must be FROZEN. Re-read it after the press and the pane's answer
# lands inside the new baseline, so the one-shot change is invisible and the
# gate reports a wedge over a pane it just woke up.
Assert 'S5 a ONE-SHOT change counts as motion (the baseline is frozen)' `
    ($g.Why -match 'after 1 extra submit')

# A pane that will not wake is a failure, and it says which failure it is.
$presses = 0
$g = Wait-LoopSubmitted -Text $P562 -SettleSeconds 0 -WatchSeconds 1 -MaxSubmits 2 `
    -Read { "> $P562" } -Submit { $script:presses++ }
Assert 'S6 an unrecoverable wedge is NOT reported as submitted' (-not $g.Submitted)
Assert 'S7 bounded: it presses MaxSubmits times and stops' ($presses -eq 2 -and $g.Attempts -eq 2)
Assert 'S8 and names the state a human can act on' ($g.Why -match 'TYPED BUT NOT SUBMITTED')

# Nothing on screen and nothing moving means nothing landed. Pressing Enter
# cannot submit a prompt that was never typed, and doing so would paper over
# the real failure - so this path presses nothing at all.
$presses = 0
$g = Wait-LoopSubmitted -Text $P562 -SettleSeconds 0 -WatchSeconds 1 `
    -Read { 'an empty pane' } -Submit { $script:presses++ }
Assert 'S9 an empty pane is a delivery failure, not a submit failure' `
    (-not $g.Submitted -and $g.Why -match 'nothing landed to submit')
Assert 'S10 and no Enter is spent on it' ($presses -eq 0)

# Both callers must actually be wired to it, or the gate is decoration.
$dogSrc = Get-Content $dogScript -Raw
Assert 'S11 the watchdog nudge runs through the gate' ($dogSrc -match 'Wait-LoopSubmitted')
Assert 'S12 and wipes the composer before typing over it' ($dogSrc -match "'C-u'")
$upSrc = Get-Content (Join-Path $Repo 'scripts\upgrade-ghoztty-windows.ps1') -Raw
Assert 'S13 the upgrade reuse path runs through the same gate' ($upSrc -match 'Wait-LoopSubmitted')

# --- P. the supervisor's own liveness is observable (T440) ----------------
# The watchdog died at 09:14 on 2026-08-03 and nothing noticed for thirteen
# hours, because the only evidence it was gone was a log that stopped. It now
# stamps a beacon on every tick - healthy ticks included - so "the supervisor is
# missing" is a state a reader can see.
""
"P. watchdog health beacon"
$pState = Join-Path $root 'go-loop.watchdog-beacon.json'
$pLog = Join-Path $root 'watchdog-beacon.log'
# A private mutex name, or the user's real watchdog refuses this one on sight.
$pMutex = "Global\GhozttyGoLoopWatchdogTest$PID"
# The empty tracker makes every tick decide 'none' immediately, so this daemon
# never reads a pane, opens a window, or types anything.
$dog = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
    '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $pState,
    '-Tracker', $emptyTracker, '-LogPath', $pLog, '-MutexName', $pMutex,
    '-PollSeconds', '2', '-DryRun')
$beacon = $null
foreach ($i in 1..40) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $pState) {
        $beacon = Get-Content $pState -Raw | ConvertFrom-Json
        if ($beacon.tick_at) { break }
    }
}
Assert 'P1 a running watchdog stamps a beacon' ($null -ne $beacon -and $null -ne $beacon.tick_at)
Assert 'P2 the beacon names the live watchdog pid' ($beacon -and [int]$beacon.watchdog_pid -eq $dog.Id)
Assert 'P3 the beacon records the tick that ran' ($beacon -and $beacon.last_tick -eq 'none')
Assert 'P4 the beacon carries the poll interval' ($beacon -and [int]$beacon.poll_seconds -eq 2)
# It must keep beating while nothing happens - that is the whole point.
$firstTick = $beacon.tick_at
Start-Sleep -Seconds 4
$beacon2 = Get-Content $pState -Raw | ConvertFrom-Json
Assert 'P5 the beacon advances on a quiet tick' ($beacon2.tick_at -ne $firstTick)
Stop-Process -Id $dog.Id -Force -ErrorAction SilentlyContinue

# A -Once tick must NOT stamp it. The upgrade script's handoff runs -Once, and a
# process that exits two seconds later stamping its pid here would report the
# supervisor as dead moments after a handoff that worked.
$onceState = Join-Path $root 'go-loop.watchdog-once.json'
'{"last_action":"nudge","last_action_at":"2026-01-01T00:00:00.0000000+00:00"}' |
    Out-File -FilePath $onceState -Encoding utf8
$argsOnce = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
    '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $onceState,
    '-Tracker', $emptyTracker, '-LogPath', $pLog, '-Once')
& powershell @argsOnce | Out-Null
$onceObj = Get-Content $onceState -Raw | ConvertFrom-Json
Assert 'P6 a -Once tick writes no beacon' ($null -eq $onceObj.tick_at)
Assert 'P7 a -Once tick leaves the action history alone' ($onceObj.last_action -eq 'nudge')

# -Status is the human-readable version of the same question.
$argsStatus = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
    '-Repo', $Repo, '-StatePath', $pState, '-Status')
$statusOut = (& powershell @argsStatus 2>&1 | Out-String)
Assert 'P8 -Status reports liveness' ($statusOut -match 'running:')
Assert 'P9 -Status reports the last tick' ($statusOut -match 'last tick:\s+\d')
Assert 'P10 -Status reports both autostart hooks' `
    ($statusOut -match 'run entry:' -and $statusOut -match 'revive task:')

# The fix for "gone until the next logon": a repeating per-user task that
# re-launches the watchdog, which the single-instance mutex makes a no-op while
# it is alive. Read-only here - installing/uninstalling would touch the real
# supervisor this box is running.
$taskQuery = (& schtasks /query /tn 'GhozttyGoLoopWatchdog' /fo LIST /v 2>&1 | Out-String)
Assert 'P11 the revive task is registered (run -Install if this fails)' ($LASTEXITCODE -eq 0)
Assert 'P12 the revive task launches the watchdog' ($taskQuery -match 'go-loop-watchdog\.ps1')

# The READ side of the same beacon: the dashboard's own rule, asserted by the
# dashboard's own code (a rule re-implemented here would drift from it).
$dash = Join-Path $Repo 'scripts\task-dashboard.js'
if (Get-Command node -ErrorAction SilentlyContinue) {
    $dashOut = (& node $dash --selftest 2>&1 | Out-String)
    Assert 'P13 the dashboard reads the beacon correctly' ($LASTEXITCODE -eq 0 -and $dashOut -match 'ALL PASS')
    if ($dashOut -notmatch 'ALL PASS') { $dashOut.Trim() }
} else {
    "  SKIP P13 (node not on PATH)"
    $script:skipped++
}

# --- Q. the lock follows a relaunch, not a pid (T440) ---------------------
# The upgrade kills claude and relaunches it in the SAME pane; nothing updates
# the lock until that session reaches go.md step 0. For that whole window
# `status` said stale-dead about a session that was working, and the dashboard
# said "nothing running" (user, 2026-08-03).
""
"Q. status asks the pane when the recorded pid is dead"
# A stand-in ghoztty whose +read answers like a pane with Claude Code in it.
$fakeExe = Join-Path $root 'fake-ghoztty-claude.cmd'
@('@echo off', 'echo   bypass permissions on (shift+tab to cycle)', 'exit /b 0') -join "`r`n" |
    Out-File -FilePath $fakeExe -Encoding ascii
$fakeShell = Join-Path $root 'fake-ghoztty-shell.cmd'
@('@echo off', 'echo D:\git\ghoztty^>', 'exit /b 0') -join "`r`n" |
    Out-File -FilePath $fakeShell -Encoding ascii

Remove-Item $lock -Force -ErrorAction SilentlyContinue
Lock-Run @('acquire', '-PaneId', 'PANE-Q', '-ClaudePid', $PID) | Out-Null
# Kill the recorded owner by hand: a pid that never existed is as dead as one
# that exited, and does not require killing something real.
$L = Read-LockFile
$L.claude_pid = 999999
$L.claude_name = 'claude'
$L.claude_start = ''
Write-LockFile $L

$r = Lock-Run @('status', '-PaneId', 'PANE-Q', '-NoPaneProbe')
Assert 'Q1 without the probe a dead pid is still stale-dead' ($r.Out -match '^stale-dead')
$r = Lock-Run @('status', '-PaneId', 'PANE-Q', '-GhozttyExe', $fakeExe)
Assert 'Q2 a claude in the owning pane keeps the lock held' ($r.Out -match '^held')
Assert 'Q3 and says the pane is what answered' ($r.Out -match 'by=pane')
$r = Lock-Run @('status', '-PaneId', 'PANE-Q', '-GhozttyExe', $fakeShell)
Assert 'Q4 a shell prompt in the pane does not count as alive' ($r.Out -match '^stale-dead')
$r = Lock-Run @('status', '-PaneId', 'PANE-Q', '-GhozttyExe', (Join-Path $root 'no-such.exe'))
Assert 'Q5 an unreachable ghoztty never invents a live loop' ($r.Out -match '^stale-dead')
# The probe must not paper over a genuinely absent owner process either: with a
# LIVE recorded pid the fast path answers and the pane is never read.
$qAlive = Start-Sleeper; $sleepers += $qAlive
Lock-Run @('adopt', '-PaneId', 'PANE-Q', '-ClaudePid', $qAlive.Id) | Out-Null
$r = Lock-Run @('status', '-PaneId', 'PANE-Q', '-GhozttyExe', $fakeShell)
Assert 'Q6 a live recorded pid is held on its own evidence' ($r.Out -match '^held' -and $r.Out -match 'by=pid')

# acquire is deliberately NOT pane-aware: a probe that misreads must never be
# able to wedge the loop, so a dead recorded owner is still taken over.
$L = Read-LockFile
$L.claude_pid = 999999
Write-LockFile $L
$r = Lock-Run @('acquire', '-PaneId', 'PANE-Q-OTHER', '-ClaudePid', $PID)
Assert 'Q7 acquire still takes over a dead owner' ($r.Code -eq 0 -and $r.Out -match 'reason=dead-owner')

# --- cleanup --------------------------------------------------------------
Kill-Sleepers
Stop-DebugGhoztty
if ($td) { Remove-TestDesktop }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd') -Force -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" ; exit 0 }
else { "$($script:failures) FAILURE(S)" ; exit 1 }
