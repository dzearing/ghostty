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
#   H. Watchdog decisions (dry run): healthy lock => none; stale + open task
#      files => new-window; no open task for this seat (all closed, or only
#      seat: mac left) => none; missing task dir => still re-enters; rearm
#      window not elapsed => none.
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
#   T. A path typed into a pane arrives verbatim (T280): the re-entry's shim
#      path rides `+send-keys --keys-file=`, whose bytes are written with no
#      escape processing, with the old positional send as the negative control -
#      it must still arrive mangled, or the arm is measuring nothing.
#   R. A turn longer than the staleness window is not nudged (T253): the lock's
#      freshness follows the session TRANSCRIPT, which Claude Code advances by
#      itself, so a working turn is visibly alive without anybody remembering to
#      beat the heartbeat - and the nudge, when it does fire, is reset-first so
#      landing it on a live session cannot queue a second task into that context.
#   S. Stranded work (T847): paths dirty at claim time are a dead turn's work.
#      claim snapshots and reports them; `parity-tasks.ps1 validate` fails while
#      they stay dirty; `ack-stranded` hands them to an OPEN task (the ack
#      survives re-claims and dies with the task); resolving the tree deletes
#      the snapshot. All against a fixture git repo + fixture task dir.
#   W. Shared-index commit guard (T948): two sessions, one working tree, one
#      index. The 2026-08-17 swallow is reproduced against a fixture repo - A
#      stages, B commits with -A - and must be REFUSED by the pre-commit hook
#      while A holds; A's own git passes through on its key; a hold past its ttl
#      is cleared rather than obeyed; the commit path commits only its pathspec
#      and reads the result back; and `verify` still catches a foreign path in a
#      finished commit, which is what a bypassed hook leaves behind.
#   V. Boot revival (T829): after a reboot with nobody at the keyboard nothing
#      of ours can run at all, so the loop's answer is to MEASURE the gap
#      between power-on and a desktop existing, record it once per boot, and be
#      loud about it on the way back. Plus the links below that one, which are
#      ours to hold: the revive task fires AT LOGON, is not battery-gated, and
#      carries no execution time limit that would kill the watchdog it started.
#   X. The loop has an off switch and every re-entry path reads it (2026-08-23).
#   Y. The daily digest is enforced rather than remembered (T1223).
#   Z. The daily publish is on the health line, so "nothing shipped" is visible
#      in the same place as "no digest" (T1292).
#  AA. The health line measures WORK, not keystrokes (T1290): a turn that has
#      not completed inside -TurnStaleMinutes reddens the verdict however fresh
#      the pane is, so the watchdog's own nudge can no longer buy health.
#  BB. The WATCHDOG decides by that same clock (T1319): a held lock whose turn
#      has not completed is re-entered, and a composer holding unsent text is
#      read as a stalled turn rather than as activity.
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
$taskDir = Join-Path $root 'tasks'
$emptyTaskDir = Join-Path $root 'tasks-empty'
$macOnlyTaskDir = Join-Path $root 'tasks-mac-only'
$log = Join-Path $root 'watchdog.log'
# Isolated like the lock and the state file: a stop pending in the REAL repo
# must not decide what these arms observe.
$stopFile = Join-Path $root 'go-loop.stop.json'
$lockScript = Join-Path $Repo 'scripts\go-loop-lock.ps1'
$dogScript = Join-Path $Repo 'scripts\go-loop-watchdog.ps1'
$execScript = Join-Path $Repo 'scripts\go-loop-exec.ps1'

# Get-PaneOccupant (section M drives it directly) and, transitively,
# loop-session.ps1's New-LoopSendKeysText - the transport sections M and T use to
# put a PATH into a pane without an escape layer eating half of it.
. (Join-Path $Repo 'scripts\go-loop-pane-probe.ps1')
# Explicitly, not through the probe's conditional load: section BB drives
# Resolve-LoopStallVerdict directly, and a helper that happens to be in scope
# because another file needed something else is not a dependency anybody can see.
. (Join-Path $Repo 'scripts\loop-session.ps1')

New-Item -ItemType Directory -Force $root | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run the lock script and return @{ Code; Out; Raw }.
#
# `Out` has the message's leading ISO timestamp removed. Every assertion here
# asks what the lock ANSWERED - `^ACQUIRED`, `^held`, `^stale-dead` - and
# b64c3e8aa (2026-08-11) prefixed each message with `$(Now-Iso) ` for the uptime
# report without moving those anchors, which turned 26 of them red against a lock
# script that was working perfectly. The timestamp is a log prefix, not part of
# the answer, so it is stripped in ONE place rather than dulled into 26 loose
# substring matches. `Raw` keeps the whole line, and A0 below asserts the prefix
# is really there, so this can never quietly paper over a missing verb.
function Lock-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $lockScript,
        '-Repo', $Repo, '-LockPath', $lock) + $extra
    $out = (& powershell @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim()
    return @{ Code = $LASTEXITCODE; Raw = $out; Out = ($out -replace '^\d{4}-\d{2}-\d{2}T[\d:.+-]+\s+', '') }
}

function Dog-Run([string[]]$extra, [string]$taskDirPath) {
    if (-not $taskDirPath) { $taskDirPath = $taskDir }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
        '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $state,
        '-TaskDir', $taskDirPath, '-LogPath', $log,
        '-StopPath', $stopFile, '-Once') + $extra
    $out = & powershell @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Exec-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $execScript,
        '-Repo', $Repo, '-LockPath', $lock, '-StopPath', $stopFile, '-GhozttyExe', $Exe) + $extra
    $out = & powershell @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String
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
    $out = & $Exe @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String
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

# One-file-per-task fixtures (T479; the watchdog counts open task files, not
# rows in the frozen tracker table). $taskDir holds exactly one task this seat
# could work: a win todo, beside a done task and a mac-seat todo that must not
# count - so every `remaining=1` assertion below is also asserting both
# exclusions. $emptyTaskDir is all closed; $macOnlyTaskDir's only open task
# belongs to the Mac seat.
function Write-TaskFixture([string]$dir, [string]$id, [string]$status, [string]$seat) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    @(
        '---'
        "id: $id"
        "title: `"fixture $id`""
        "status: `"$status`""
        "seat: `"$seat`""
        '---'
        ''
        "# $id - fixture"
    ) -join "`r`n" | Out-File -FilePath (Join-Path $dir "$id.md") -Encoding utf8
}
Write-TaskFixture $taskDir 'T999' 'todo' 'win'
Write-TaskFixture $taskDir 'T998' 'done' 'win'
Write-TaskFixture $taskDir 'T997' 'todo' 'mac'
Write-TaskFixture $emptyTaskDir 'T999' 'done' 'win'
Write-TaskFixture $macOnlyTaskDir 'T999' 'todo' 'mac'

# --- A. lifecycle ---------------------------------------------------------
"A. lock lifecycle"
$r = Lock-Run @('status')
Assert 'A1 status on a missing lock reports FREE' ($r.Code -eq 0 -and $r.Out -match '^FREE')

$owner = Start-Sleeper; $sleepers += $owner
$r = Lock-Run @('acquire', '-PaneId', 'PANE-A', '-ClaudePid', $owner.Id)
Assert 'A2 acquire on a free lock succeeds' ($r.Code -eq 0 -and $r.Out -match '^ACQUIRED')
# ...and the stamp Lock-Run strips is genuinely on the wire (b64c3e8aa): without
# this the normalization above could hide a message that lost its verb entirely.
Assert 'A2b the message carries its ISO timestamp prefix' `
    ($r.Raw -match '^\d{4}-\d{2}-\d{2}T[\d:.+-]+\s+ACQUIRED')
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

$r = Dog-Run @('-DryRun') $emptyTaskDir
Assert 'H6 a task dir with nothing open produces no action' ($r.Out -match 'ACTION none')
Assert 'H7 and says why' ($r.Out -match 'no open tasks for this seat')
$r = Dog-Run @('-DryRun') $macOnlyTaskDir
Assert 'H7b a dir whose only open task is seat: mac also idles' ($r.Out -match 'ACTION none' -and $r.Out -match 'no open tasks for this seat')
$r = Dog-Run @('-DryRun') (Join-Path $root 'no-such-tasks')
Assert 'H7c a missing task dir never blocks re-entry' ($r.Out -match 'ACTION new-window' -and $r.Out -match 'remaining=-1')

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
        $fk = New-LoopSendKeysText -Exe $Exe -Text $fake -Tag 'guard-faketui'
        Ghoz (@('+send-keys', "--target=$($paneN.id)") + $fk.Args + @('Enter')) | Out-Null
        if ($fk.File) { Remove-Item -LiteralPath $fk.File -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
        $r = Dog-Run @('-DryRun', '-GhozttyExe', $Exe, '-ProbeGapSeconds', 3)
        Assert 'N4 a live claude in the pane is nudged, not shim''d' ($r.Out -match 'ACTION nudge')
        Assert 'N5 and the watchdog says who it found' ($r.Out -match 'occupant=claude')
        Assert 'N6 the shim was never typed into it' ($r.Out -notmatch 'ACTION restart-in-pane')
        Ghoz @('+send-keys', "--target=$($paneN.id)", 'C-c') | Out-Null
        Ghoz @('+close', '--target=go-loop-tui') | Out-Null
    }

    ""
    "T. a path reaches a pane VERBATIM through --keys-file (T280)"
    # Sections M10-M13 pin the transport helper's contract; this pins the same
    # claim ON THE WIRE, because the helper being right about which argument to
    # build says nothing about what the pane actually receives.
    #
    # One plausible Windows path carrying every escape `+send-keys` processes in
    # a positional argument: \t (twice), \n, and a trailing backslash.
    $payload = 'C:\Users\tom\AppData\nook\text\go.cmd\'

    $paneT = New-TestWindow 'go-loop-keys'
    Assert 'T0 a stand-in pane is open' ($null -ne $paneT)
    if ($paneT) {
        $tk = New-LoopSendKeysText -Exe $Exe -Text $payload -Tag 'guard-wire'
        Ghoz (@('+send-keys', "--target=$($paneT.id)") + $tk.Args) | Out-Null
        if ($tk.File) { Remove-Item -LiteralPath $tk.File -ErrorAction SilentlyContinue }
        $seen = ''
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 500
            $seen = (Ghoz @('+read', "--name=$($paneT.id)", '--lines=20')).Out
            if ($seen -match [regex]::Escape($payload)) { break }
        }
        # Nothing is submitted: the payload is only ever typed at the prompt, so
        # a mangled one cannot run whatever it happens to spell.
        Assert 'T1 the path arrives at the pane character for character' `
            ($seen -match [regex]::Escape($payload))
        Ghoz @('+close', '--target=go-loop-keys') | Out-Null
    }

    # The pre-T280 send, as the negative control. A payload that was never at
    # risk proves nothing, so the old transport must genuinely arrive broken -
    # its own window, because the mangled \n submits a line and there is no
    # reason to make T1 share a pane with that.
    $paneU = New-TestWindow 'go-loop-keys-raw'
    Assert 'T2 a second stand-in pane is open' ($null -ne $paneU)
    if ($paneU) {
        Ghoz @('+send-keys', "--target=$($paneU.id)", $payload) | Out-Null
        Start-Sleep -Seconds 2
        $rawSeen = (Ghoz @('+read', "--name=$($paneU.id)", '--lines=20')).Out
        Assert 'T3 the raw positional send does NOT deliver it intact' `
            ($rawSeen -notmatch [regex]::Escape($payload))
        Ghoz @('+close', '--target=go-loop-keys-raw') | Out-Null
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
# send-keys eats backslash escapes in a POSITIONAL argument, so a shim path
# under a user called "tom" would arrive with a TAB in it. T280 retired the
# hand-escaping: the path rides `--keys-file=`, whose bytes are written verbatim,
# and the escaper survives only inside the transport helper's degraded branch -
# an exe that predates the flag, where argv is the only thing left. These arms
# are the helper's contract; section T measures the same claim on the wire.
$mPath = 'C:\Users\tom\AppData\nook\text\go.cmd\'
$mKeys = New-LoopSendKeysText -Exe $Exe -Text $mPath -Tag 'guard-transport'
Assert 'M20 a path travels as a file, not as argv' `
    ($mKeys.Args.Count -eq 1 -and $mKeys.Args[0] -like '--keys-file=*' -and -not $mKeys.Degraded)
Assert 'M21 and the file holds the path VERBATIM - nothing doubled, nothing lost' `
    ($mKeys.File -and ([IO.File]::ReadAllText($mKeys.File) -ceq $mPath))
if ($mKeys.File) { Remove-Item -LiteralPath $mKeys.File -ErrorAction SilentlyContinue }

# The named case the escaper still exists for: an INSTALLED ghoztty older than
# T210. A stand-in whose `+send-keys --help` never says "keys-file" is what the
# watchdog met on day one (measured 2026-08-01 against +96fbe40c7), and there the
# doubling is still what makes the path arrive intact.
$oldExe = Join-Path $root 'old-ghoztty.cmd'
@('@echo off', 'echo Usage: ghoztty +send-keys --target=NAME [--enter] text...') -join "`r`n" |
    Out-File -FilePath $oldExe -Encoding ascii
$mOld = New-LoopSendKeysText -Exe $oldExe -Text $mPath -Tag 'guard-transport-old'
Assert 'M22 an exe without --keys-file degrades to argv, and says so' `
    ($mOld.Degraded -and -not $mOld.File -and $mOld.Args[0] -notlike '--keys-file=*')
Assert 'M23 and the degraded argv is escaped, so the path still survives' `
    ($mOld.Args[0] -ceq 'C:\\Users\\tom\\AppData\\nook\\text\\go.cmd\\')
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
# The all-closed task dir makes every tick decide 'none' immediately, so this
# daemon never reads a pane, opens a window, or types anything.
$dog = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
    '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $pState,
    '-TaskDir', $emptyTaskDir, '-LogPath', $pLog, '-MutexName', $pMutex,
    '-StopPath', $stopFile, '-PollSeconds', '2', '-DryRun')
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
    '-TaskDir', $emptyTaskDir, '-LogPath', $pLog, '-StopPath', $stopFile, '-Once')
& powershell @argsOnce | Out-Null
$onceObj = Get-Content $onceState -Raw | ConvertFrom-Json
Assert 'P6 a -Once tick writes no beacon' ($null -eq $onceObj.tick_at)
Assert 'P7 a -Once tick leaves the action history alone' ($onceObj.last_action -eq 'nudge')

# -Status is the human-readable version of the same question.
$argsStatus = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
    '-Repo', $Repo, '-StatePath', $pState, '-Status')
$statusOut = (& powershell @argsStatus 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
Assert 'P8 -Status reports liveness' ($statusOut -match 'running:')
Assert 'P9 -Status reports the last tick' ($statusOut -match 'last tick:\s+\d')
Assert 'P10 -Status reports both autostart hooks' `
    ($statusOut -match 'run entry:' -and $statusOut -match 'revive task:')

# The fix for "gone until the next logon": a repeating per-user task that
# re-launches the watchdog, which the single-instance mutex makes a no-op while
# it is alive. Read-only here - installing/uninstalling would touch the real
# supervisor this box is running.
$taskQuery = (& schtasks /query /tn 'GhozttyGoLoopWatchdog' /fo LIST /v 2>&1 |
    ForEach-Object { $_.ToString() } | Out-String)
Assert 'P11 the revive task is registered (run -Install if this fails)' ($LASTEXITCODE -eq 0)

# P12 follows the chain rather than grepping the /TR line for the script name
# (T1172/T1192). Since the launch went windowless the action is wscript.exe on a
# generated launcher, so "go-loop-watchdog.ps1 appears in the task" is no longer
# true of a correctly registered task - it was red for a day on exactly that.
# What must stay true is that the task ENDS UP running the watchdog, whichever
# host it goes through.
$realAction = $null
try { $realAction = @((Get-ScheduledTask -TaskName 'GhozttyGoLoopWatchdog' -ErrorAction Stop).Actions)[0] } catch { }
$realExec = if ($realAction) { [string]$realAction.Execute } else { '' }
$realArgs = if ($realAction) { [string]$realAction.Arguments } else { '' }
$launched = "$realExec $realArgs"
if ($realArgs -match '"([^"]+\.vbs)"') {
    $vbsPath = $Matches[1]
    if (Test-Path -LiteralPath $vbsPath) { $launched += "`n" + (Get-Content -LiteralPath $vbsPath -Raw) }
}
Assert 'P12 the revive task ends up launching the watchdog' ($launched -match 'go-loop-watchdog\.ps1')
# T1192: powershell.exe under an Interactive principal is handed a console
# before it can read -WindowStyle Hidden, and with Windows Terminal as the
# default terminal application that console is a real window that takes focus.
# wscript.exe is GUI-subsystem and is given none.
Assert 'P12b the revive task launches windowless, so a revival cannot steal focus' `
    ($realExec -match '(^|\\)wscript(\.exe)?$')

# The READ side of the same beacon: the dashboard's own rule, asserted by the
# dashboard's own code (a rule re-implemented here would drift from it).
$dash = Join-Path $Repo 'scripts\task-dashboard.js'
if (Get-Command node -ErrorAction SilentlyContinue) {
    $dashOut = (& node $dash --selftest 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
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

# --- S. stranded work at claim (T847) --------------------------------------
""
"S. stranded work: dirty-at-claim paths are snapshotted, gated by validate, ack-able"
# A fixture git repo whose dirtiness this section fully controls. The claim runs
# with -Repo pointed here, so its lock AND its snapshot land in this repo's own
# temp\ (ignored, like the real one) and the real repo's snapshot is never
# touched; the fixture task dir keeps the ack away from the real tracker.
$taskScript = Join-Path $Repo 'scripts\parity-tasks.ps1'
$sRepo = Join-Path $root 'stranded-repo'
$sTasks = Join-Path $root 'stranded-tasks'
New-Item -ItemType Directory -Force $sRepo, $sTasks | Out-Null
git -C $sRepo init -q 2>$null
[System.IO.File]::WriteAllText((Join-Path $sRepo '.gitignore'), "temp/`n", (New-Object System.Text.UTF8Encoding $false))
git -C $sRepo add .gitignore 2>$null
git -C $sRepo -c user.email='t@t' -c user.name='t' commit -q -m 'fixture' 2>$null
$sSnap = Join-Path (Join-Path $sRepo 'temp') 'go-loop.stranded.json'
$sTaskLines = @('---', 'id: T1', 'title: "fixture T1"', 'deps: []', 'status: "todo"',
    'commits: []', '---', '', '# T1 - fixture', '', '## Progress log', '')
[System.IO.File]::WriteAllText((Join-Path $sTasks 'T1.md'), ($sTaskLines -join "`n"), (New-Object System.Text.UTF8Encoding $false))

function SClaim([string]$paneId) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $execScript claim `
        -Repo $sRepo -PaneId $paneId -GhozttyExe $Exe -NoClose 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}
# GHOZTTY_STRANDED_REPO is scoped to each call: a leaked value would point every
# later validate in this shell's children at the fixture.
function STask([string[]]$argList) {
    $env:GHOZTTY_STRANDED_REPO = $sRepo
    try {
        $out = & powershell -NoProfile -File $taskScript @argList -TaskDir $sTasks 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
    } finally { Remove-Item Env:GHOZTTY_STRANDED_REPO -ErrorAction SilentlyContinue }
}

$paneS = New-TestWindow 'stranded-s'
if ($null -eq $paneS) {
    "  SKIP S (no pane for claim)"; $script:skipped++
} else {
    Set-Content -Path (Join-Path $sRepo 'orphan.txt') -Value 'left behind'
    $r = SClaim $paneS.id
    Assert 'S1 claim reports the dirty path as stranded' ($r.Code -eq 0 -and $r.Out -match 'STRANDED WORK: 1 path' -and $r.Out -match 'orphan\.txt')
    Assert 'S2 the snapshot exists in the fixture repo temp' (Test-Path $sSnap)

    $r = STask @('validate')
    Assert 'S3 validate fails while the stranded path stays dirty' ($r.Code -ne 0 -and $r.Out -match 'STRANDED WORK' -and $r.Out -match 'orphan\.txt')

    $r = STask @('ack-stranded', 'T1')
    Assert 'S4 ack-stranded hands the paths to an open task' ($r.Code -eq 0 -and $r.Out -match 'T1 now owns 1 stranded path')
    $r = STask @('validate')
    Assert 'S5 validate passes on an acknowledged snapshot' ($r.Code -eq 0 -and $r.Out -match 'STRANDED WORK ACKNOWLEDGED')

    # The ack must survive the next turn's re-claim - the owed task may not be
    # picked for days, and a re-claim that dropped it would re-redden validate.
    $r = SClaim $paneS.id
    Assert 'S6 a re-claim carries the ack forward' ((Get-Content $sSnap -Raw) -match '"ackTask":\s*"T1"')

    # A closed task cannot keep absorbing the gate.
    & powershell -NoProfile -File $taskScript set-status T1 -Status done -TaskDir $sTasks -NoNote 2>&1 | Out-Null
    $r = STask @('validate')
    Assert 'S7 the ack dies with the task: validate fails once T1 closes' ($r.Code -ne 0 -and $r.Out -match 'STRANDED WORK' -and $r.Out -notmatch 'ACKNOWLEDGED')

    # Resolving the tree resolves the gate, and the snapshot cleans itself up.
    Remove-Item (Join-Path $sRepo 'orphan.txt') -Force
    $r = STask @('validate')
    Assert 'S8 validate passes once the tree is clean' ($r.Code -eq 0 -and $r.Out -notmatch 'STRANDED WORK')
    Assert 'S9 the resolved snapshot deleted itself' (-not (Test-Path $sSnap))

    $r = SClaim $paneS.id
    Assert 'S10 a clean tree claims clean' ($r.Out -match 'tree clean at claim')
    Ghoz @('+close', "--target=$($paneS.id)") | Out-Null
}

# --- V. boot revival (T829) ------------------------------------------------
""
"V. boot revival: the sign-in gap is measured, recorded once per boot, and loud"
# Pure: the classifier is driven with known boot/logon times instead of
# rebooting the box, and the task arm registers a fixture-named task so the real
# supervisor's registration is never touched. The one arm that reads the REAL
# task is read-only, and is there because the shape on THIS box is the thing
# that has to be right - a fixture proving `install` can produce a good task
# says nothing about whether anyone ran it.
$bootScript = Join-Path $Repo 'scripts\go-loop-boot.ps1'
$bootLedger = Join-Path $root 'boots.jsonl'
$fixtureTask = 'GhozttyGoLoopBootGuardFixture'

function Boot-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootScript,
        '-Repo', $Repo, '-LedgerPath', $bootLedger) + $extra
    $out = (& powershell @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}
function Ledger-Rows { if (Test-Path $bootLedger) { @(Get-Content $bootLedger | Where-Object { $_.Trim() }) } else { @() } }

# A box that signed itself back in is the outcome this task wants, and it must
# read as a quiet success rather than an outage.
$r = Boot-Run @('record', '-BootTime', '2026-08-01T03:00:00', '-LogonTime', '2026-08-01T03:01:00')
Assert 'V1 an unattended sign-in records quietly' `
    ($r.Code -eq 0 -and $r.Out -match 'signed in by itself after 1m' -and $r.Out -notmatch 'BOOT OUTAGE')
# @(...) around the call, not just inside the function: a one-element array
# returned from a PowerShell function unrolls to the bare string, and [-1] on a
# string is its last CHARACTER - which matches nothing and reads as a real bug.
Assert 'V2 it lands in the ledger as unattended' (@(Ledger-Rows)[-1] -match '"unattended":true')

# The measured failure: 25 hours with no desktop. Loud, with the span and the
# one-time human fix in the same block.
$r = Boot-Run @('record', '-BootTime', '2026-08-02T03:00:00', '-LogonTime', '2026-08-03T04:09:00')
Assert 'V3 a reboot nobody signed in to is a loud BOOT OUTAGE' ($r.Out -match 'BOOT OUTAGE')
Assert 'V4 the outage names the measured span' ($r.Out -match '1d 1h 9m')
Assert 'V5 the outage names the fix a human can act on' ($r.Out -match 'Sign-in options')

# Once per boot, not once per turn: `claim` calls this every time.
$before = (Ledger-Rows).Count
$r = Boot-Run @('record', '-BootTime', '2026-08-02T03:00:00', '-LogonTime', '2026-08-03T04:09:00')
Assert 'V6 re-recording the same boot says nothing' ($r.Out -eq '')
Assert 'V7 re-recording the same boot adds no row' ((Ledger-Rows).Count -eq $before)

$r = Boot-Run @('record', '-BootTime', '2026-08-04T03:00:00', '-LogonTime', '2026-08-04T03:00:30')
Assert 'V8 a different boot is a new row' ((Ledger-Rows).Count -eq ($before + 1))

# `check`'s link-1 verdict comes from the ledger, never from the registry - the
# registry on this box reads "configured" (AutoLogonSID set to the user's own
# SID) while the box demonstrably does not sign itself in.
$r = Boot-Run @('check', '-Json', '-TaskName', $fixtureTask)
$j = $null
try { $j = ($r.Out | ConvertFrom-Json) } catch { }
Assert 'V9 check reads link 1 off the last recorded boot' ($null -ne $j -and $j.link1 -eq 'unattended')
Assert 'V10 check totals the downtime it has measured' ($null -ne $j -and [math]::Round([double]$j.lost_minutes) -eq 1509)
Assert 'V11 an unregistered revive task is BROKEN, not merely noted' `
    ($r.Code -eq 2 -and $null -ne $j -and @($j.broken).Count -gt 0)

# `install` owns the task SHAPE, and reads it back rather than trusting that
# Register-ScheduledTask did what it was told.
$r = Boot-Run @('install', '-TaskName', $fixtureTask, '-WatchdogScript', $dogScript)
Assert 'V12 install registers the revive task' ($r.Code -eq 0 -and $r.Out -match 'INSTALLED')
Assert 'V13 install verifies the shape it just wrote' `
    ($r.Out -match 'atLogon=True' -and $r.Out -match 'repeats=True' -and
     $r.Out -match 'batteryGate=False' -and $r.Out -match 'timeLimited=False')
# T1192, on the fixture rather than the live supervisor: the shape the INSTALLER
# writes, not the shape this box happens to be carrying. P12/P12b assert the
# real task; these assert that a fresh install produces it, which is the half
# that regressed - the live task was fixed by hand and the installer was not,
# so the next -Install would have put the focus-stealing console back.
$fixtureVbs = Join-Path (Split-Path -Parent $dogScript) `
    ("$([System.IO.Path]::GetFileNameWithoutExtension($dogScript))-launch.vbs")
Assert 'V13a install writes a launcher next to the watchdog it was given' (Test-Path -LiteralPath $fixtureVbs)
$fixtureVbsText = if (Test-Path -LiteralPath $fixtureVbs) { Get-Content -LiteralPath $fixtureVbs -Raw } else { '' }
Assert 'V13b the launcher points at THAT watchdog, not this box''s' `
    ($fixtureVbsText -match [regex]::Escape($dogScript))
Assert 'V13c the launcher gives it no console' ($fixtureVbsText -match '(?m),\s*0\s*,\s*False\s*$')
$fixtureAction = $null
try { $fixtureAction = @((Get-ScheduledTask -TaskName $fixtureTask -ErrorAction Stop).Actions)[0] } catch { }
Assert 'V13d install registers wscript.exe, not powershell.exe' `
    ($null -ne $fixtureAction -and ([string]$fixtureAction.Execute) -match '(^|\\)wscript(\.exe)?$')
Assert 'V13e install reads the launch shape back and says so' ($r.Out -match 'windowless=True')

$r = Boot-Run @('install', '-TaskName', $fixtureTask, '-WatchdogScript', $dogScript)
Assert 'V14 install is idempotent' ($r.Code -eq 0 -and $r.Out -match 'atLogon=True')
$r = Boot-Run @('check', '-Json', '-TaskName', $fixtureTask)
$j = $null
try { $j = ($r.Out | ConvertFrom-Json) } catch { }
# Scoped to the task: the fixture name has no HKCU Run entry and is not
# supposed to, so the whole `broken` list would never empty here.
Assert 'V15 check stops calling the task broken once it is installed' `
    ($null -ne $j -and @($j.broken | Where-Object { $_ -match 'revive task' }).Count -eq 0)
& powershell -NoProfile -Command "Unregister-ScheduledTask -TaskName '$fixtureTask' -Confirm:`$false -ErrorAction SilentlyContinue" *> $null

# Read-only, on the REAL supervisor task, for the same reason P11/P12 are: the
# flags that matter are the ones on this box. A laptop on battery would never
# revive, and the default 72-hour execution limit kills the watchdog the task
# itself started.
$realTask = $null
try { $realTask = Get-ScheduledTask -TaskName 'GhozttyGoLoopWatchdog' -ErrorAction Stop } catch { }
if ($null -eq $realTask) {
    "  SKIP V16-V18 (no GhozttyGoLoopWatchdog task; run go-loop-watchdog.ps1 -Install)"
    $script:skipped++
} else {
    $realLogon = @($realTask.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count
    Assert 'V16 the real revive task fires at logon (run go-loop-boot.ps1 install if this fails)' ($realLogon -gt 0)
    Assert 'V17 the real revive task is not battery-gated' `
        (-not ([bool]$realTask.Settings.DisallowStartIfOnBatteries -or [bool]$realTask.Settings.StopIfGoingOnBatteries))
    Assert 'V18 the real revive task has no execution time limit' `
        (([string]$realTask.Settings.ExecutionTimeLimit) -in @('', 'PT0S'))
}

# One owner for the shape: the watchdog must delegate rather than register its
# own defaults again. Asserted on the source because running -Install for real
# would re-register the supervisor this box is relying on right now.
$dogSrc = Get-Content $dogScript -Raw
Assert 'V19 the watchdog delegates the task shape to go-loop-boot.ps1' `
    ($dogSrc -match 'go-loop-boot\.ps1' -and $dogSrc -notmatch 'schtasks\s+/create')

# --- W. shared-index commit guard (T948) -----------------------------------
""
"W. commit guard: one index, two sessions - the swallow is prevented, and caught"
# The 2026-08-17 shape, reproduced: session A stages its own paths, session B
# commits with -A in the gap, and git commits the INDEX - which holds both. Run
# against a fixture repo so the real one is never committed to; the guard script
# is pointed at it with -Repo, and `install` deliberately wires the fixture to
# the REAL scripts\githooks, because the hook under test is the shipped one.
$cgScript = Join-Path $Repo 'scripts\git-commit-guard.ps1'
$wRepo = Join-Path $root 'commit-guard-repo'
New-Item -ItemType Directory -Force $wRepo | Out-Null
git -C $wRepo init -q 2>$null
git -C $wRepo config user.email 't@t' 2>$null
git -C $wRepo config user.name 't' 2>$null
Set-Content -Path (Join-Path $wRepo 'base.txt') -Value 'base'
git -C $wRepo add base.txt 2>$null
git -C $wRepo commit -q -m 'fixture' 2>$null

function CG([string[]]$argList) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $cgScript @argList -Repo $wRepo 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}
# A commit attempted the way the OTHER window attempts it: whatever is in the
# tree, no lock key, straight `git commit`.
function WCommit([string]$msg) {
    $out = & git -C $wRepo commit -m $msg 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}
function WHead { (& git -C $wRepo rev-parse HEAD 2>$null | Select-Object -First 1) }

$r = CG @('install')
Assert 'W1 install arms the hook via core.hooksPath' `
    ($r.Code -eq 0 -and (& git -C $wRepo config --local --get core.hooksPath) -match 'githooks')

# Session A holds while it stages; session B stages everything and commits.
CG @('hold', '-Key', 'AAA', '-Holder', 'session A') | Out-Null
Set-Content -Path (Join-Path $wRepo 'a-work.txt') -Value 'session A work, half written'
$headBefore = WHead
Set-Content -Path (Join-Path $wRepo 'b-work.txt') -Value 'session B work'
git -C $wRepo add -A 2>$null
$r = WCommit 'session B: a -A commit in the gap'
Assert 'W2 the -A commit from the second session is REFUSED' ($r.Code -ne 0 -and $r.Out -match 'COMMIT REFUSED')
Assert 'W3 the refusal names the holder and the remedy' ($r.Out -match 'session A' -and $r.Out -match 'git-commit-guard\.ps1 release')
Assert 'W4 nothing was committed: HEAD did not move' ((WHead) -eq $headBefore)

# The holder's own git carries the key and is never in its own way.
$env:GHOZTTY_COMMIT_LOCK_KEY = 'AAA'
$r = WCommit 'session A: my own commit'
Remove-Item Env:GHOZTTY_COMMIT_LOCK_KEY -ErrorAction SilentlyContinue
Assert 'W5 the holder itself commits normally' ($r.Code -eq 0 -and (WHead) -ne $headBefore)

# A second session cannot take a live hold, and cannot quietly overwrite it.
$r = CG @('hold', '-Key', 'BBB', '-Holder', 'session B')
Assert 'W6 a second hold is BUSY (exit 3)' ($r.Code -eq 3 -and $r.Out -match 'BUSY' -and $r.Out -match 'session A')
$r = CG @('status')
Assert 'W7 the lock still names the first holder' ($r.Out -match 'held' -and $r.Out -match 'session A')

# A crashed holder must never wedge the repo: past its ttl the hook clears the
# lock instead of obeying it.
CG @('release', '-Force') | Out-Null
CG @('hold', '-Key', 'CCC', '-TtlSeconds', '1') | Out-Null
Start-Sleep -Seconds 2
Set-Content -Path (Join-Path $wRepo 'after-stale.txt') -Value 'x'
git -C $wRepo add -A 2>$null
$r = WCommit 'after a stale hold'
Assert 'W8 a hold past its ttl is cleared, not obeyed' ($r.Code -eq 0)
$r = CG @('status')
Assert 'W9 and the stale lock file is gone' ($r.Out -match '^free')

# The commit path proves what it committed. A foreign path staged in the shared
# index is EXCLUDED by the pathspec and named out loud, rather than riding along.
Set-Content -Path (Join-Path $wRepo 'mine.txt') -Value 'mine'
Set-Content -Path (Join-Path $wRepo 'theirs.txt') -Value 'theirs'
git -C $wRepo add theirs.txt 2>$null
$r = CG @('commit', '-Paths', 'mine.txt', '-Message', 'only my own path')
$committed = @(& git -C $wRepo show --pretty=format: --name-only HEAD 2>$null | Where-Object { $_ })
Assert 'W10 commit reports exactly the requested paths' ($r.Code -eq 0 -and $r.Out -match 'COMMITTED')
Assert 'W11 the commit contains only the requested path' ($committed.Count -eq 1 -and $committed[0] -eq 'mine.txt')
Assert 'W12 the excluded foreign path is named, not silently dropped' ($r.Out -match 'theirs\.txt')

# And the detection arm, which is what a bypassed hook leaves: read a finished
# commit back and refuse to call it clean when it carries somebody else's work.
$r = CG @('verify', '-Paths', 'docs/nothing-like-this.md', '-Sha', 'HEAD')
Assert 'W13 verify catches a commit carrying foreign paths (exit 5)' ($r.Code -eq 5 -and $r.Out -match 'SWALLOWED WORK' -and $r.Out -match 'mine\.txt')
$r = CG @('verify', '-Paths', 'mine.txt', '-Sha', 'HEAD')
Assert 'W14 verify passes a commit that carries only its own paths' ($r.Code -eq 0 -and $r.Out -match 'CLEAN')

# The documented invocation is `-Paths 'a','b'`, and `powershell -File` hands
# that over as ONE string - it binds every argument as text and never splits an
# array. Caught the first real turn that used it: git rejected a single absurd
# pathspec. Both spellings must mean the same thing.
Set-Content -Path (Join-Path $wRepo 'two-a.txt') -Value 'a'
Set-Content -Path (Join-Path $wRepo 'two-b.txt') -Value 'b'
$r = CG @('commit', '-Paths', 'two-a.txt,two-b.txt', '-Message', 'a comma-separated pathspec')
$committed = @(& git -C $wRepo show --pretty=format: --name-only HEAD 2>$null | Where-Object { $_ })
Assert 'W16 a comma-separated -Paths is two paths, not one' `
    ($r.Code -eq 0 -and $committed.Count -eq 2 -and ($committed -contains 'two-a.txt') -and ($committed -contains 'two-b.txt'))

# git narrates on stderr while succeeding ("LF will be replaced by CRLF", push
# progress), and PowerShell 5.1 turns each such line into a terminating
# ErrorRecord under $ErrorActionPreference = 'Stop'. That killed the guard's
# first real commit with exit code 0 in hand, so the fixture is made to produce
# exactly that warning: a CRLF file under autocrlf, staged through the guard.
git -C $wRepo config core.autocrlf true 2>$null
[System.IO.File]::WriteAllText((Join-Path $wRepo 'crlf.txt'), "one`r`ntwo`r`n")
$r = CG @('commit', '-Paths', 'crlf.txt', '-Message', 'a file that makes git warn')
Assert 'W17 a git warning on stderr is not a failure' ($r.Code -eq 0 -and $r.Out -match 'COMMITTED')
git -C $wRepo config --unset core.autocrlf 2>$null

# -Push is the shape go.md step 6 uses, and it was unexercised until it failed
# on a real turn: `$push = ...` inside the script assigned a hashtable to the
# [switch]$Push PARAMETER (PowerShell variable names are case-insensitive) and
# died in parameter binding before the verb ran. A bare repo makes the whole
# path real without a network.
$wBare = Join-Path $root 'commit-guard-remote.git'
git init -q --bare $wBare 2>$null
git -C $wRepo remote add origin $wBare 2>$null
git -C $wRepo push -q -u origin HEAD 2>$null
Set-Content -Path (Join-Path $wRepo 'pushed.txt') -Value 'pushed'
$r = CG @('commit', '-Push', '-Paths', 'pushed.txt', '-Message', 'a commit that pushes')
$remoteHead = (& git -C $wBare rev-parse HEAD 2>$null | Select-Object -First 1)
Assert 'W18 -Push commits and pushes' `
    ($r.Code -eq 0 -and $r.Out -match 'PUSHED' -and $remoteHead -eq (WHead))

# --- T1057: the push is not optional -------------------------------------
# `-Push` was an opt-in switch and a plain `git commit` bypassed the guard
# entirely, so "push immediately after every commit" (go.md step 4) was
# honour-system - and the user had to state it twice, two weeks apart. These
# arms score the mechanical version: commit pushes on its own, opting out is
# explicit and says why, and the state "HEAD is ahead of origin" is something
# the turn boundary can SEE.
Set-Content -Path (Join-Path $wRepo 'default-push.txt') -Value 'no -Push flag anywhere'
$r = CG @('commit', '-Paths', 'default-push.txt', '-Message', 'a commit with no push flag')
$remoteHead = (& git -C $wBare rev-parse HEAD 2>$null | Select-Object -First 1)
Assert 'W19 commit pushes by default - no flag needed' `
    ($r.Code -eq 0 -and $r.Out -match 'PUSHED' -and $remoteHead -eq (WHead))
$r = CG @('unpushed')
Assert 'W20 unpushed is clean right after a pushing commit' ($r.Code -eq 0 -and $r.Out -match 'push clean')

# Opting out is a decision, and a decision leaves a record.
Set-Content -Path (Join-Path $wRepo 'held-back.txt') -Value 'deliberately local'
$r = CG @('commit', '-NoPush', '-Reason', 'testing the opt-out', '-Paths', 'held-back.txt', '-Message', 'a commit held back')
Assert 'W21 -NoPush skips the push and prints the reason' `
    ($r.Code -eq 0 -and $r.Out -match 'PUSH SKIPPED \(-NoPush\)' -and $r.Out -match 'testing the opt-out')
Assert 'W22 the held-back commit really did not reach the remote' `
    ((& git -C $wBare rev-parse HEAD 2>$null | Select-Object -First 1) -ne (WHead))

# Teeth: the planted unpushed commit is CAUGHT, with a non-zero exit, and it is
# named rather than merely counted.
$r = CG @('unpushed')
Assert 'W23 unpushed catches the local-only commit (exit 7)' `
    ($r.Code -eq 7 -and $r.Out -match 'UNPUSHED WORK: 1 commit' -and $r.Out -match 'a commit held back')
$r = CG @('unpushed', '-Json')
Assert 'W24 the json answer says the same thing' ($r.Code -eq 7 -and $r.Out -match '"count":\s*1' -and $r.Out -match '"clean":\s*false')

# And the remedy the message names actually resolves it.
$r = CG @('push')
Assert 'W25 push ships the backlog' ($r.Code -eq 0 -and $r.Out -match 'PUSHED 1 commit')
$r = CG @('unpushed')
Assert 'W26 and unpushed goes clean again' ($r.Code -eq 0 -and $r.Out -match 'push clean')

# A rejected push is the one recoverable failure, and go.md step 4 says how:
# pull with rebase, push again. Reported-and-left is what leaves work here.
$pBare = Join-Path $root 'reject-remote.git'
$pRepo = Join-Path $root 'reject-mine'
$pOther = Join-Path $root 'reject-theirs'
git init -q --bare $pBare 2>$null
git clone -q $pBare $pRepo 2>$null
git -C $pRepo config user.email 't@t' 2>$null; git -C $pRepo config user.name 't' 2>$null
Set-Content -Path (Join-Path $pRepo 'seed.txt') -Value 'seed'
git -C $pRepo add seed.txt 2>$null
git -C $pRepo -c core.hooksPath= commit -q -m 'seed' 2>$null
git -C $pRepo push -q -u origin HEAD 2>$null
git clone -q $pBare $pOther 2>$null
git -C $pOther config user.email 't@t' 2>$null; git -C $pOther config user.name 't' 2>$null
Set-Content -Path (Join-Path $pOther 'theirs-first.txt') -Value 'landed first'
git -C $pOther add theirs-first.txt 2>$null
git -C $pOther -c core.hooksPath= commit -q -m 'the other seat got there first' 2>$null
git -C $pOther push -q origin HEAD 2>$null

Set-Content -Path (Join-Path $pRepo 'mine-second.txt') -Value 'mine'
$r = & powershell -NoProfile -ExecutionPolicy Bypass -File $cgScript commit `
    -Repo $pRepo -Paths 'mine-second.txt' -Message 'mine, onto a branch that moved' 2>&1 |
    ForEach-Object { $_.ToString() } | Out-String
$pCode = $LASTEXITCODE
$pRemote = (& git -C $pBare rev-parse HEAD 2>$null | Select-Object -First 1)
$pLocal = (& git -C $pRepo rev-parse HEAD 2>$null | Select-Object -First 1)
Assert 'W27 a rejected push is rebased and pushed, not reported and left' `
    ($pCode -eq 0 -and $r -match 'push rejected' -and $r -match 'PUSHED' -and $pRemote -eq $pLocal)
$pLog = @(& git -C $pRepo log --oneline 2>$null | Where-Object { $_ })
Assert 'W28 the other seat''s commit survived the rebase' `
    (@($pLog | Where-Object { $_ -match 'the other seat got there first' }).Count -gt 0)

# A branch nobody has ever pushed is the same problem with a longer tail.
$oRepo = Join-Path $root 'no-upstream-repo'
New-Item -ItemType Directory -Force $oRepo | Out-Null
git -C $oRepo init -q 2>$null
git -C $oRepo config user.email 't@t' 2>$null; git -C $oRepo config user.name 't' 2>$null
Set-Content -Path (Join-Path $oRepo 'only-here.txt') -Value 'only here'
git -C $oRepo add only-here.txt 2>$null
git -C $oRepo commit -q -m 'never shared' 2>$null
$r = & powershell -NoProfile -ExecutionPolicy Bypass -File $cgScript unpushed -Repo $oRepo 2>&1 |
    ForEach-Object { $_.ToString() } | Out-String
Assert 'W29 a branch with no upstream counts as unpushed' ($LASTEXITCODE -eq 7 -and $r -match 'no upstream')
# ...and committing there is not a FAILURE - the commit is fine, there is just
# nowhere to send it. Exiting non-zero would read as "the commit failed", so the
# skip is said out loud and the teeth stay with the gate above.
Set-Content -Path (Join-Path $oRepo 'second.txt') -Value 'second'
$r = & powershell -NoProfile -ExecutionPolicy Bypass -File $cgScript commit `
    -Repo $oRepo -Paths 'second.txt' -Message 'nowhere to push this' 2>&1 |
    ForEach-Object { $_.ToString() } | Out-String
Assert 'W29b a commit with no upstream succeeds and says the push was skipped' `
    ($LASTEXITCODE -eq 0 -and $r -match 'COMMITTED' -and $r -match 'PUSH SKIPPED' -and $r -match 'no upstream')

# The gate end of it: `parity-tasks.ps1 validate` is what every commit passes
# through, so that is where the answer has to have teeth. Both directions.
$wTasks = Join-Path $root 'push-tasks'
New-Item -ItemType Directory -Force $wTasks | Out-Null
$wTaskLines = @('---', 'id: T1', 'title: "fixture T1"', 'deps: []', 'status: "todo"',
    'commits: []', '---', '', '# T1 - fixture', '', '## Progress log', '')
[System.IO.File]::WriteAllText((Join-Path $wTasks 'T1.md'), ($wTaskLines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
function WValidate([string[]]$extra) {
    $env:GHOZTTY_UNPUSHED_REPO = $wRepo
    try {
        $out = & powershell -NoProfile -File $taskScript validate -TaskDir $wTasks @extra 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
    } finally { Remove-Item Env:GHOZTTY_UNPUSHED_REPO -ErrorAction SilentlyContinue }
}
$r = WValidate @()
Assert 'W30 validate passes while the branch is level with its upstream' ($r.Code -eq 0 -and $r.Out -notmatch 'UNPUSHED WORK')
Set-Content -Path (Join-Path $wRepo 'gate-me.txt') -Value 'unpushed on purpose'
CG @('commit', '-NoPush', '-Reason', 'planting one for the gate', '-Paths', 'gate-me.txt', '-Message', 'a commit the gate must catch') | Out-Null
$r = WValidate @()
Assert 'W31 validate FAILS over an unpushed commit' ($r.Code -ne 0 -and $r.Out -match 'UNPUSHED WORK')
$r = WValidate @('-NoPushCheck')
Assert 'W32 the -NoPushCheck hatch is open, and says it was taken' ($r.Code -eq 0 -and $r.Out -match 'PUSH CHECK SKIPPED')
CG @('push') | Out-Null
$r = WValidate @()
Assert 'W33 validate goes green once the commit is pushed' ($r.Code -eq 0 -and $r.Out -notmatch 'UNPUSHED WORK')

# --- T1245: the message file is written for THIS commit, or there is no commit
# `-MessageFile temp\msg2.txt` was run on a turn that never wrote that file, and
# a leftover from an earlier turn was sitting there: the guard proved the PATHS
# and never asked whether the SUBJECT belonged to this work, so e4824918e went
# out - and was pushed - titled after somebody else's task. A stale message is
# worse than a missing one, because a missing one would have been noticed.
$msgPath = Join-Path $wRepo 'temp\msg.txt'
New-Item -ItemType Directory -Force (Split-Path $msgPath) | Out-Null
Set-Content -Path (Join-Path $wRepo 'msg-missing.txt') -Value 'x'
$headBefore = WHead
$r = CG @('commit', '-Paths', 'msg-missing.txt', '-MessageFile', $msgPath)
Assert 'W34 a -MessageFile that does not exist is REFUSED, and the path is named' `
    ($r.Code -eq 2 -and $r.Out -match 'MESSAGE FILE MISSING' -and $r.Out -match 'msg\.txt')
Assert 'W35 nothing was committed over the missing message' ((WHead) -eq $headBefore)

[System.IO.File]::WriteAllText($msgPath, "   `r`n`t`r`n", (New-Object System.Text.UTF8Encoding $false))
$r = CG @('commit', '-Paths', 'msg-missing.txt', '-MessageFile', $msgPath)
Assert 'W36 an empty / whitespace-only message file is REFUSED' `
    ($r.Code -eq 2 -and $r.Out -match 'MESSAGE FILE EMPTY')
Assert 'W37 nothing was committed over the empty message' ((WHead) -eq $headBefore)

# The remedy for staleness is that a message cannot survive its own commit.
[System.IO.File]::WriteAllText($msgPath, "the subject written for this commit`n", (New-Object System.Text.UTF8Encoding $false))
$r = CG @('commit', '-Paths', 'msg-missing.txt', '-MessageFile', $msgPath)
Assert 'W38 a real message file commits normally' `
    ($r.Code -eq 0 -and $r.Out -match 'COMMITTED' -and
     (& git -C $wRepo log -1 --pretty=%s 2>$null) -match 'the subject written for this commit')
Assert 'W39 the message file is consumed, so it cannot be reused stale' (-not (Test-Path $msgPath))

# A UTF-8 BOM is three bytes git commits INTO THE SUBJECT, invisible at the
# console and permanent in the feed. `Set-Content -Encoding utf8` (PS 5.1)
# writes one, which is how 2d9959fd6 went out with a mojibake first character.
# Normalised, not refused: the message is right, only its first three bytes
# are not.
Set-Content -Path (Join-Path $wRepo 'msg-bom.txt') -Value 'work behind a BOM-headed message'
Set-Content -Path $msgPath -Value 'chore(tracker): a subject behind a BOM' -Encoding utf8
$bomBytes = [System.IO.File]::ReadAllBytes($msgPath)
Assert 'W39a the fixture really has a BOM (the trap this asserts against)' `
    ($bomBytes.Length -ge 3 -and $bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF)
$r = CG @('commit', '-Paths', 'msg-bom.txt', '-MessageFile', $msgPath)
$bomSubject = (& git -C $wRepo log -1 --pretty=%s 2>$null)
Assert 'W39b a BOM-headed message file still commits' ($r.Code -eq 0 -and $r.Out -match 'COMMITTED')
Assert 'W39c and the subject starts at the first REAL character' `
    ($bomSubject -eq 'chore(tracker): a subject behind a BOM')
Assert 'W39d the strip is said out loud rather than done silently' ($r.Out -match 'stripped a UTF-8 BOM')
Assert 'W39e the original message file is still consumed (T1245 unchanged)' (-not (Test-Path $msgPath))

# The 2026-09-01 shape end to end: a second turn commits with the same path and
# never writes it. Before this it inherited the first turn's subject; now it is
# the missing-file refusal, which is a stop rather than a wrong feed item.
Set-Content -Path (Join-Path $wRepo 'msg-stale.txt') -Value 'second turn work'
$headBefore = WHead
$r = CG @('commit', '-Paths', 'msg-stale.txt', '-MessageFile', $msgPath)
Assert 'W40 the next turn cannot inherit the last turn''s subject' `
    ($r.Code -eq 2 -and (WHead) -eq $headBefore)

# The one arm about THIS box: claim arms the guard every turn, so the real repo
# should be wired right now. Read-only - nothing here reconfigures the real repo.
$realHooks = (& git -C $Repo config --local --get core.hooksPath 2>$null)
Assert 'W15 the real repo has the guard armed (run go-loop-exec.ps1 claim if this fails)' `
    ($realHooks -match 'githooks')

# --- X. the loop has an off switch, and the watchdog honours it (2026-08-23/24)
# The loop had no way to be stopped on purpose. Closing the window is not it:
# the watchdog re-enters whenever the lock goes stale while tasks remain, which
# is exactly what a closed window looks like. The stop is therefore a request
# honoured at a turn boundary - and it is only a stop if EVERY re-entry path
# reads it, which is what these arms score.
#
# X7 exists because the first attempt shipped broken in the most invisible way
# possible: the check was added to the watchdog and armed, and the watchdog
# went on opening a window every twenty minutes for a full day, because
# PowerShell reads a script once and that process had been up for six days.
# Nothing anywhere reported that the running copy was stale.
$xRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gz-stop-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$xRepo = Join-Path $xRoot 'repo'
New-Item -ItemType Directory -Force -Path (Join-Path $xRepo 'temp') | Out-Null
$xFlag = Join-Path $xRepo 'temp\go-loop.stop.json'
$Exec = Join-Path $Repo 'scripts\go-loop-exec.ps1'

function XExec([string[]]$a) {
    # .ToString() per record before Out-String: a merged stream formats
    # ErrorRecords differently per host, so the captured text would depend on
    # who ran the suite (test\win32\stderr-capture-audit.ps1 C1).
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Exec @a 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

$r = XExec @('stop', '-Repo', $xRepo, '-PaneId', 'none', '-Reason', 'harness arm')
Assert 'X1 stop writes the flag and says the turn in flight finishes' `
    ($r.Code -eq 0 -and (Test-Path -LiteralPath $xFlag) -and $r.Out -match 'STOP REQUESTED')

$r = XExec @('claim', '-Repo', $xRepo, '-PaneId', 'none')
Assert 'X2 claim refuses with exit 4 and names the reason, not a rival' `
    ($r.Code -eq 4 -and $r.Out -match 'STOPPED by request' -and $r.Out -match 'harness arm' -and $r.Out -notmatch 'STAND-DOWN')

# Exit 4 must be its OWN code: 3 means "another window is primary" and would
# send whoever reads it hunting for a duplicate that does not exist.
Assert 'X3 the refusal tells the reader how to undo it' ($r.Out -match 'go-loop-exec\.ps1 resume')

$r = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\go-loop-health.ps1') -Repo $xRepo 2>&1 |
    ForEach-Object { $_.ToString() } | Out-String
$hCode = $LASTEXITCODE
Assert 'X4 health calls it STOPPED (exit 3), not DOWN - a supervisor must not revive it' `
    ($hCode -eq 3 -and $r -match 'STOPPED')

$r = XExec @('resume', '-Repo', $xRepo, '-PaneId', 'none')
Assert 'X5 resume clears the flag' ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $xFlag) -and $r.Out -match 'RESUMED')

# -NoSelfClose -NoClose: this arm runs a REAL claim, and claim resolves
# duplicates by closing windows. The fixture must never be able to reach the
# user's actual windows.
$r = XExec @('claim', '-Repo', $xRepo, '-PaneId', 'none', '-NoSelfClose', '-NoClose')
Assert 'X6 and claim stops answering 4 once the request is cleared' `
    ($r.Code -ne 4 -and $r.Out -notmatch 'STOPPED by request')

# --- the watchdog reads the same flag, and re-reads its own source ---------
# Run a COPY so editing it cannot disturb the real supervisor, and give it its
# own mutex or it exits against the live one.
$xScripts = Join-Path $xRoot 'scripts'
Copy-Item -Path (Join-Path $Repo 'scripts') -Destination $xScripts -Recurse -Force
$xWd = Join-Path $xScripts 'go-loop-watchdog.ps1'
$xLog = Join-Path $xRoot 'wd.log'
$xMutex = "Global\GhozttyGoLoopWatchdogTest$([guid]::NewGuid().ToString('N').Substring(0,8))"
& powershell -NoProfile -ExecutionPolicy Bypass -File $Exec stop -Repo $xRepo -PaneId 'none' -Reason 'watchdog arm' | Out-Null

$xProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $xWd,
    '-Repo', $xRepo, '-LogPath', $xLog, '-PollSeconds', '2', '-MutexName', $xMutex)
$null = $xProc.Handle   # cache before the child can exit (ExitCodeAudit)

function XWaitLog([string]$needle, [int]$sec) {
    $deadline = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $xLog) {
            $t = Get-Content -LiteralPath $xLog -Raw -ErrorAction SilentlyContinue
            if ($t -and $t -match [regex]::Escape($needle)) { return $true }
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

Assert 'X7 the watchdog refuses to re-enter while a stop is pending' (XWaitLog 'not re-entering' 25)
Assert 'X8 and it says out loud that it is watching its own source' (XWaitLog 'watching own source' 25)

# The arm that the first attempt would have failed: change the source under a
# RUNNING watchdog and it must pick the change up by itself.
Add-Content -LiteralPath $xWd -Value "`n# harness: a real byte change to force a self-restart`n"
$restarted = XWaitLog 'own source changed on disk' 30
Assert 'X9 a running watchdog re-execs when its own source changes' $restarted
Assert 'X10 and the replacement actually started' (XWaitLog 'replacement started' 15)

# The replacement must be a DIFFERENT live process, or "restarted" is a log line
# that means nothing.
$xAlive = $false
if ($restarted) {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $live = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($xWd) -and $_.ProcessId -ne $xProc.Id })
        if ($live.Count -ge 1) { $xAlive = $true; break }
        Start-Sleep -Milliseconds 400
    }
}
Assert 'X11 a new watchdog process is alive after the re-exec' $xAlive

# Tear down every fixture watchdog, parent and replacement alike.
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($xWd) })) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $xRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- Y. the daily digest is enforced, not remembered (T1223) ---------------
#
# go.md step 0.5 asks for one digest a day. It had no check of any kind, so the
# 2026-09-01 miss was invisible until the user asked for it, and 08-24..08-29
# went the same way with nobody noticing at all. These arms score the field
# that makes a miss visible - and, because a check nobody has watched go red is
# indistinguishable from a check that cannot (T1133), the FIRST arm is the
# missing case, not the happy one.
$yRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gz-digest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$yRepo = Join-Path $yRoot 'repo'
$yDigests = Join-Path $yRepo 'docs\design\windows-parity-digests'
New-Item -ItemType Directory -Force -Path $yDigests | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $yRepo 'temp') | Out-Null
$yHist = Join-Path $yRepo 'temp\go-loop-history.jsonl'
$yHealth = Join-Path $Repo 'scripts\go-loop-health.ps1'
$yToday = (Get-Date).ToString('yyyy-MM-dd')
$yFile = Join-Path $yDigests "$yToday.md"

function YHealth([string]$asOf) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $yHealth `
        -Repo $yRepo -DigestAsOf $asOf 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return $out
}

# The loop turned at 06:00 today and there is no file: that is the miss.
Set-Content -LiteralPath $yHist -Encoding ascii -Value ('{"at":"' + $yToday + 'T06:00:00-07:00","event":"heartbeat","turn":1}')
$y = YHealth "${yToday}T09:00:00"
Assert 'Y1 a skipped digest reads missing on the plain line, with no -Postmortem' ($y -match 'digest=missing')
Assert 'Y2 and the line says which step owes it and where the file goes' `
    ($y -match 'go\.md step 0\.5' -and $y -match [regex]::Escape("windows-parity-digests\$yToday.md"))
Assert 'Y3 the check reports the miss and never writes one (backfill stays forbidden)' `
    (-not (Test-Path -LiteralPath $yFile))

# Same fixture, file present: the positive control for Y1.
Set-Content -LiteralPath $yFile -Encoding ascii -Value @('---', "date: `"$yToday`"", '---', '## Commentary', 'x')
$y = YHealth "${yToday}T09:00:00"
Assert 'Y4 a written digest reads present, and stops nagging' `
    ($y -match 'digest=present' -and $y -notmatch 'digest is missing')

# A day the loop never turned owes nothing - a box that was off overnight, or a
# loop stopped on purpose, must not be reported as delinquent.
Remove-Item -LiteralPath $yFile -Force
Set-Content -LiteralPath $yHist -Encoding ascii -Value ('{"at":"' + (Get-Date).AddDays(-3).ToString('yyyy-MM-dd') + 'T06:00:00-07:00","event":"heartbeat","turn":1}')
$y = YHealth "${yToday}T09:00:00"
Assert 'Y5 a day the loop spent stopped is not-due, not missing' ($y -match 'digest=not-due')

# And before 05:00 nothing is owed yet, however busy the loop has been.
Set-Content -LiteralPath $yHist -Encoding ascii -Value ('{"at":"' + $yToday + 'T03:30:00-07:00","event":"heartbeat","turn":1}')
$y = YHealth "${yToday}T04:30:00"
Assert 'Y6 before 05:00 the digest is not-due even with the loop turning' ($y -match 'digest=not-due')

Remove-Item -LiteralPath $yRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- Z. delivery is on the health line too (T1292) --------------------------
#
# The digest field above exists because an omission with no signal eventually
# stops happening. Delivery had the same shape and it was worse: the daily
# publish DID report its skips, one line an evening into a temp log nobody
# reads, while the user spent three days installing a build from before the fix
# they had asked for. `publish=` puts "nothing shipped" where "no digest"
# already lives. First arm is the stale case, not the happy one (T1133).
$zRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gz-publish-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$zRepo = Join-Path $zRoot 'repo'
New-Item -ItemType Directory -Force -Path (Join-Path $zRepo 'temp') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $zRepo 'docs\design\windows-parity-digests') | Out-Null
$zWm = Join-Path $zRoot 'daily-publish'
$zHealth = Join-Path $Repo 'scripts\go-loop-health.ps1'
$zNow = [datetime]'2026-09-03T09:00:00'

function ZHealth([string]$json) {
    if ($null -eq $json) {
        Remove-Item -LiteralPath $zWm -Force -ErrorAction SilentlyContinue
    } else {
        Set-Content -LiteralPath $zWm -Encoding ascii -Value $json
    }
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File $zHealth `
            -Repo $zRepo -PublishWatermark $zWm -PublishAsOf $zNow.ToString('o') `
            -DigestAsOf $zNow.ToString('o') 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
}

# Three days since anything shipped - the exact state of this box on 2026-09-03.
$z = ZHealth '{"date":"2026-08-31","at":"2026-08-31T19:31:00-07:00","tag":"win-v1.36.0","commit":"abc1234","result":"published"}'
Assert 'Z1 a three-day-old publish reads stale on the plain line' ($z -match 'publish=stale-3d')
Assert 'Z2 and the note says the landed work is not on the user''s machine' `
    ($z -match 'nothing has shipped since 2026-08-31')
Assert 'Z3 and the run is degraded, not healthy' ($z -match 'DEGRADED')

# The positive control for Z1: yesterday's publish is the normal cadence.
$z = ZHealth '{"date":"2026-09-02","at":"2026-09-02T18:02:00-07:00","tag":"win-v1.36.2","commit":"abc1234","result":"published"}'
Assert 'Z4 yesterday''s publish reads ok, and stops nagging' `
    ($z -match 'publish=ok' -and $z -notmatch 'nothing has shipped since')

# A tag CI never turned into a release used to be indistinguishable from a good
# publish; daily-publish.ps1 reconciles it and this is where that surfaces.
$z = ZHealth '{"date":"2026-09-03","at":"2026-09-03T06:10:00-07:00","tag":"win-v1.36.3","commit":"abc1234","result":"failed"}'
Assert 'Z5 a tag that never became a release reads failed, even dated today' ($z -match 'publish=failed')
Assert 'Z6 and the note names the tag to go and look at' ($z -match 'win-v1\.36\.3')
Assert 'Z6b and the run is degraded, not healthy' ($z -match 'DEGRADED')
Assert 'Z6c and the note says the loop retries once a fix lands (T1369)' ($z -match 'retries on its own')

# T1369: a run that stamped `attempting` and never recorded an outcome - a
# crash, a reboot, a killed turn - is a day that shipped nothing just as much as
# a failed one, and it used to read `ok` on the strength of its date alone.
$z = ZHealth '{"date":"2026-09-03","at":"2026-09-03T06:10:00-07:00","tag":"win-v1.36.4","commit":"abc1234","result":"attempting","attempts":1}'
Assert 'Z6d an abandoned attempt reads failed rather than ok' ($z -match 'publish=failed')

# ...but a publish that is running RIGHT NOW is not abandoned, and must not
# light the board red for the ten minutes it takes.
$z = ZHealth '{"date":"2026-09-03","at":"2026-09-03T08:58:00-07:00","tag":"win-v1.36.4","commit":"abc1234","result":"attempting","attempts":1}'
Assert 'Z6e an attempt from two minutes ago is a publish in flight, not a failure' ($z -match 'publish=ok')

$z = ZHealth $null
Assert 'Z7 no watermark at all reads never, not ok' ($z -match 'publish=never')

# --- Z8..Z12. published is not the same question as current (T1294) ---------
#
# On 2026-09-03 the day HAD published, so this field read `ok`, and 24 commits
# sat behind that release - among them the fix for the installer bug the user
# had reported that morning. They downloaded the same broken installer and
# reported the same bug again. `ok` was true and it was the wrong true thing.
$zReqPath = Join-Path $zRoot 'daily-publish-request'
function ZHealthReq([string]$json, [string]$request, [string]$repo) {
    if ($null -eq $json) { Remove-Item -LiteralPath $zWm -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $zWm -Encoding ascii -Value $json }
    if ($null -eq $request) { Remove-Item -LiteralPath $zReqPath -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $zReqPath -Encoding ascii -Value $request }
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File $zHealth `
            -Repo $repo -PublishWatermark $zWm -PublishRequest $zReqPath `
            -PublishAsOf $zNow.ToString('o') -DigestAsOf $zNow.ToString('o') 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String)
}

# Measured against the REAL repo, because the count is a git question: a
# watermark pointing three commits back must read ok+3, not ok.
$zBehindCommit = (& git -C $Repo rev-parse --short HEAD~3 2>$null)
if ($LASTEXITCODE -eq 0 -and $zBehindCommit) {
    $zBehindCommit = $zBehindCommit.Trim()
    $z = ZHealthReq "{`"date`":`"2026-09-03`",`"at`":`"2026-09-03T06:10:00-07:00`",`"tag`":`"win-v1.36.2`",`"commit`":`"$zBehindCommit`",`"result`":`"published`"}" $null $Repo
    Assert 'Z8 a release three commits behind HEAD reads ok+3, not ok' ($z -match 'publish=ok\+3\b')

    $zHead = (& git -C $Repo rev-parse --short HEAD).Trim()
    $z = ZHealthReq "{`"date`":`"2026-09-03`",`"at`":`"2026-09-03T06:10:00-07:00`",`"tag`":`"win-v1.36.2`",`"commit`":`"$zHead`",`"result`":`"published`"}" $null $Repo
    Assert 'Z9 a release that carries HEAD reads plain ok' ($z -match 'publish=ok(?!\+)')
} else {
    Assert 'Z8/Z9 SKIP: could not resolve HEAD~3 in this repo' $true
}

# A request that has gone unhonoured is the loop being ASKED to ship and not
# shipping - that one DOES degrade, because somebody is waiting on it.
$zOld = (Get-Date).AddHours(-9).ToString('yyyy-MM-ddTHH:mm:sszzz')
$z = ZHealthReq '{"date":"2026-09-03","at":"2026-09-03T06:10:00-07:00","tag":"win-v1.36.2","commit":"abc1234","result":"published"}' `
    "{`"at`":`"$zOld`",`"reason`":`"T1291: the installer dies silently`",`"commit`":`"abc1234`"}" $zRepo
Assert 'Z10 an unhonoured publish request degrades the run' ($z -match 'DEGRADED')
Assert 'Z11 and the note quotes what is waiting' ($z -match 'T1291: the installer dies silently')

# A request filed minutes ago is in flight - this turn's step 6.5 ships it - and
# must not paint the loop red on its way past.
$zFresh = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
$z = ZHealthReq '{"date":"2026-09-03","at":"2026-09-03T06:10:00-07:00","tag":"win-v1.36.2","commit":"abc1234","result":"published"}' `
    "{`"at`":`"$zFresh`",`"reason`":`"filed this minute`",`"commit`":`"abc1234`"}" $zRepo
Assert 'Z12 a request filed this minute is in flight, not a fault' ($z -notmatch 'filed this minute')

Remove-Item -LiteralPath $zRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- AA. the health line measures WORK, not keystrokes (T1290) -------------
#
# On 2026-09-03 the loop was inert from 14:29 to 05:07 the next morning - no
# turn, no commit - and the health line read HEALTHY the whole way through. The
# watchdog had found the lock stale at 04:59, nudged the pane, and logged that
# the pane moved; six minutes later the health check measured that nudge and
# called it activity. The cure manufactured the symptom of health.
#
# So there is a third clock beside the heartbeat and the transcript pulse:
# `turn_started`, which ONLY a completed turn moves, because only a completed
# turn reaches go.md step 0 again. First arm is the stall, not the happy case
# (T1133): a green light nobody has watched go red is not a light.
$aaRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gz-turn-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$aaRepo = Join-Path $aaRoot 'repo'
New-Item -ItemType Directory -Force -Path (Join-Path $aaRepo 'temp') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $aaRepo 'docs\design\windows-parity-digests') | Out-Null
$aaLock = Join-Path $aaRoot 'go-loop.lock.json'
$aaTranscript = Join-Path $aaRoot 'transcript.jsonl'
$aaHealth = Join-Path $Repo 'scripts\go-loop-health.ps1'
$aaNow = Get-Date
# Publish and digest are deliberately made CLEAN in this fixture: the arms
# below assert that the turn gate is the sole reason the verdict moves, and a
# second standing complaint would let a broken gate pass them.
$aaWatermark = Join-Path $aaRoot 'daily-publish'
Set-Content -LiteralPath $aaWatermark -Encoding ascii -Value ('{"date":"' + $aaNow.ToString('yyyy-MM-dd') + '","tag":"win-vAA","result":"published"}')
# A live owner this fixture can point at without inventing one: THIS process.
$aaProc = Get-Process -Id $PID
$aaIso = 'yyyy-MM-ddTHH:mm:ss.fffffffK'

function AAWriteLock([object]$turnStarted, [datetime]$heartbeat) {
    # The transcript is touched to NOW every time - that is the nudge, and the
    # thing the old verdict was reading.
    Set-Content -LiteralPath $aaTranscript -Encoding ascii -Value '{}'
    $o = [ordered]@{
        version      = 1
        pane_id      = 'AA-FIXTURE-PANE'
        claude_pid   = $PID
        claude_name  = $aaProc.ProcessName
        claude_start = $aaProc.StartTime.ToString($aaIso)
        session_id   = 'aa-fixture'
        transcript   = $aaTranscript
        host         = $env:COMPUTERNAME
        repo         = $aaRepo
        acquired     = $aaNow.AddDays(-3).ToString($aaIso)
        heartbeat    = $heartbeat.ToString($aaIso)
        turn         = 66
        reason       = 'own-lock'
    }
    if ($null -ne $turnStarted) { $o['turn_started'] = ([datetime]$turnStarted).ToString($aaIso) }
    Set-Content -LiteralPath $aaLock -Encoding ascii -Value ($o | ConvertTo-Json -Depth 4)
}

function AAHealth([switch]$AsJson, [int]$TurnStaleMinutes = 0) {
    $a = @('-Repo', $aaRepo, '-LockPath', $aaLock, '-DigestAsOf', $aaNow.ToString('o'),
           '-PublishAsOf', $aaNow.ToString('o'), '-PublishWatermark', $aaWatermark)
    if ($AsJson) { $a += '-Json' }
    if ($TurnStaleMinutes -gt 0) { $a += @('-TurnStaleMinutes', "$TurnStaleMinutes") }
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File $aaHealth @a 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String)
}

# The exact 2026-09-03 shape: transcript touched seconds ago, heartbeat and turn
# 14.5 hours old, turn counter unchanged.
AAWriteLock $aaNow.AddHours(-14.5) $aaNow.AddHours(-14.5)
$aa = AAHealth
Assert 'AA1 a 14.5h-old turn behind fresh pane activity is not HEALTHY' `
    ($aa -match 'DEGRADED' -and $aa -notmatch 'HEALTHY')
# The teeth check: run the SAME fixture with the gate widened out of the way and
# diff the complaints. Exactly one appears, and it is this one. Without this arm
# AA1 passes on any unrelated grumble - which is how a gate that cannot fail
# ships looking like one that can. Asserted on the NOTES rather than the verdict
# word, because the suite runs on a background desktop where the dashboard port
# and the marked-window count are legitimately not what a foreground box has.
$aaNarrowJson = (AAHealth -AsJson) | ConvertFrom-Json
$aaWideJson = (AAHealth -AsJson -TurnStaleMinutes 100000) | ConvertFrom-Json
# Unwrapped inline, not through a helper: a PS 5.1 function that returns an
# EMPTY array unrolls it to $null at the call site, and the widened run's note
# list is empty by construction - so the helper form failed this arm for a
# reason that had nothing to do with the gate.
$aaNarrowNotes = @($aaNarrowJson.notes)
$aaWideNotes = @($aaWideJson.notes)
Assert 'AA1b and it is the turn gate alone that reddens it - one added note, no others' `
    ($aaNarrowNotes.Count -eq ($aaWideNotes.Count + 1) -and
     @($aaWideNotes | Where-Object { $_ -match 'no turn has completed' }).Count -eq 0 -and
     @($aaNarrowNotes | Where-Object { $_ -match 'no turn has completed' }).Count -eq 1)
Assert 'AA2 the plain line carries the progress clock, not just the liveness one' `
    ($aa -match 'turn_age=14h')
Assert 'AA3 and the note names the last completed turn and how long ago it started' `
    ($aa -match 'no turn has completed for 14h' -and $aa -match 'turn 66 started')
Assert 'AA4 the note sends the reader to the pane, where a 529 is visible' `
    ($aa -match '\+read' -and $aa -match '529')

# THE arm this task exists for: nudging again refreshes the transcript and must
# change nothing. AAWriteLock re-touches it on every call.
AAWriteLock $aaNow.AddHours(-14.5) $aaNow.AddHours(-14.5)
$aa = AAHealth
Assert 'AA5 a second nudge does not buy health - only a completed turn does' `
    ($aa -match 'DEGRADED' -and $aa -match 'no turn has completed')

# Back-compat: a lock written before turn_started existed falls back to the
# HEARTBEAT, never to the transcript pulse - otherwise the upgrade itself would
# have re-introduced the bug for every lock already on disk.
AAWriteLock $null $aaNow.AddHours(-14.5)
$aa = AAHealth
Assert 'AA6 a pre-T1290 lock falls back to the heartbeat, so it still reads stalled' `
    ($aa -match 'no turn has completed for 14h')

# The positive control for AA1: a turn that started four minutes ago. Only the
# progress note is asserted away - this fixture cannot speak for the dashboard
# or the watchdog, which have notes of their own.
AAWriteLock $aaNow.AddMinutes(-4) $aaNow.AddMinutes(-4)
$aa = AAHealth
Assert 'AA7 a turn that started minutes ago produces no progress complaint' `
    ($aa -match 'turn_age=4m' -and $aa -notmatch 'no turn has completed')

$aa = AAHealth -AsJson
$aaJson = $null
try { $aaJson = $aa | ConvertFrom-Json } catch { }
Assert 'AA8 -Json carries turn_age_minutes and turn_stalled for the dashboard' `
    ($null -ne $aaJson -and $aaJson.turn_age_minutes -ge 3 -and $aaJson.turn_age_minutes -le 6 -and
     $aaJson.turn_stalled -eq $false)

Remove-Item -LiteralPath $aaRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- BB. the WATCHDOG decides by the same clock (T1319) --------------------
#
# AA above is the observer; this is the actor. On 2026-09-04 they disagreed in
# the worst direction for two and a half hours: the health line said
# `DOWN ... turn_age=2h 32m` and the watchdog - the only thing that recovers an
# unattended loop - said `healthy: ... age=31.51m (by=transcript)` every five
# minutes, because the transcript's 31 minutes measured the keystrokes that
# typed `/rc` into the composer and never sent it. A supervisor that reports
# correctly and never acts is not a supervisor.
""
"BB. the watchdog reads the progress clock, not the pane pulse"

# --- the composer classifier (pure) ---
# A composer box, borders and all. Written from code points so this file stays
# ASCII (PS 5.1 mojibakes a BOM-less non-ASCII source), which is also what the
# classifier itself has to survive.
$bbV = [string][char]0x2502      # box side
$bbH = ([string][char]0x2500) * 20
$bbTL = [string][char]0x256D; $bbTR = [string][char]0x256E
$bbBL = [string][char]0x2570; $bbBR = [string][char]0x256F
function BBPane([string]$composer) {
    return (@(
        '* Read(go.md)',
        '  ' + ([string][char]0x23BF) + '  Read 240 lines',
        '',
        "$bbTL$bbH$bbTR",
        "$bbV > $composer",
        "$bbBL$bbH$bbBR",
        '  ? for shortcuts                              bypass permissions on'
    ) -join "`r`n")
}
Assert 'BB1 an unsent continuation is pending composer text' `
    ((Get-PaneComposerText -Tail (BBPane '/rc')) -eq '/rc')
Assert 'BB2 the exact 2026-09-04 text is read back whole' `
    ((Get-PaneComposerText -Tail (BBPane '/reset-context read go.md and go')) -eq '/reset-context read go.md and go')
Assert 'BB3 an empty composer is not pending text' ((Get-PaneComposerText -Tail (BBPane '')) -eq '')

# The chrome this box actually renders, measured off the loop's own pane on
# 2026-09-04 (Claude Code v2.1.251, 98-column pane). It is NOT a box: the
# composer is a full-width horizontal RULE with the input row under it, and
# because the rule is exactly the pane width the input row arrives from `+read`
# as a CONTINUATION of it - one logical line, `<98 rule chars>> text`. That is
# why the indent rule above survives both chromes: a border flattens to
# whitespace whichever shape it has, and only the transcript's own `> message`
# sits at column 0.
$bbRule = ([string][char]0x2500) * 98
function BBRulePane([string]$composer, [string]$status) {
    return (@(
        '* Read(go.md)',
        '',
        "$bbRule> $composer",
        "$bbRule  $status",
        '  users/dzearing/windows-amd64 | D:\git\ghoztty',
        '  ' + ([string][char]0x23F5) + ' bypass permissions on - 6 shells'
    ) -join "`r`n")
}
Assert 'BB3b the rule-style composer this box renders is read the same way' `
    ((Get-PaneComposerText -Tail (BBRulePane '/rc' 'ctx: 205k/1000k')) -eq '/rc')
Assert 'BB3c and an empty one is still empty' `
    ((Get-PaneComposerText -Tail (BBRulePane '' 'ctx: 205k/1000k')) -eq '')
# The false positive that would have nudged this box forever: the user's custom
# status line carries a right-aligned `/rc` on EVERY pane, all the time. A
# "does the pane contain a slash command" check would fire on it once a turn ran
# long - which is also the likeliest reading of "`/rc` appears in the composer"
# in the incident report this task was filed from.
Assert 'BB3d a slash command in the status line is not pending composer text' `
    ((Get-PaneComposerText -Tail (BBRulePane '' 'ctx: 205k/1000k (21%) | files: 9 changed | v2.1.251                  /rc')) -eq '')
Assert 'BB4 the TUI placeholder is not pending text' `
    ((Get-PaneComposerText -Tail (BBPane 'Try "how do I..."')) -eq '')
# THE false positive that would nudge every working session forever: Claude Code
# renders a SUBMITTED user message as '> text' at column 0. Only the composer's
# marker is indented, because a border sits to its left.
Assert 'BB5 a submitted message in the transcript is not pending text' `
    ((Get-PaneComposerText -Tail "> read go.md and go`r`n`r`n* Bash(git status)`r`n  done") -eq '')
Assert 'BB6 an empty pane reads as no composer' ((Get-PaneComposerText -Tail '') -eq '')
Assert 'BB7 a shell prompt is not a composer' `
    ((Get-PaneComposerText -Tail "D:\git\ghoztty>") -eq '')
# Only the bottom of the screen is the composer; scrollback that happens to hold
# an indented '>' must not resurrect as pending input.
Assert 'BB8 an indented marker far up the scrollback is out of the window' `
    ((Get-PaneComposerText -Tail ((@("  > stale text") + (1..20 | ForEach-Object { "line $_" })) -join "`r`n")) -eq '')

# --- the stall verdict (pure) ---
$bbFresh = Resolve-LoopStallVerdict -TurnAgeMinutes 4 -StaleMinutes 180 -SuspectMinutes 45 -ComposerText ''
Assert 'BB9 a turn that started minutes ago is not stalled' `
    (-not $bbFresh.Stalled -and $bbFresh.Clock -eq 'none')
$bbLong = Resolve-LoopStallVerdict -TurnAgeMinutes 240 -StaleMinutes 180 -SuspectMinutes 45 -ComposerText ''
Assert 'BB10 no turn inside the limit is stalled, whatever the pane shows' `
    ($bbLong.Stalled -and $bbLong.Clock -eq 'turn' -and $bbLong.Why -match 'no turn has completed for 240')
# The arm this task exists for: 2h32m is UNDER the 180m backstop, so the turn
# clock alone would still have waited another half hour. The composer is what
# makes the 2026-09-04 shape catchable.
$bbShape = Resolve-LoopStallVerdict -TurnAgeMinutes 152 -StaleMinutes 180 -SuspectMinutes 45 -ComposerText '/rc'
Assert 'BB11 the 2026-09-04 shape - fresh pane, unsent text, turn unmoved - is stalled' `
    ($bbShape.Stalled -and $bbShape.Clock -eq 'composer')
Assert 'BB12 and the verdict quotes the text it decided on' ($bbShape.Why -match "'/rc'")
# Positive controls in both directions: the same composer text early in a turn
# is a user typing, and an empty composer late in one is just a long turn.
$bbEarly = Resolve-LoopStallVerdict -TurnAgeMinutes 10 -StaleMinutes 180 -SuspectMinutes 45 -ComposerText '/rc'
Assert 'BB13 unsent text early in a turn is somebody typing, not a stall' (-not $bbEarly.Stalled)
$bbQuiet = Resolve-LoopStallVerdict -TurnAgeMinutes 152 -StaleMinutes 180 -SuspectMinutes 45 -ComposerText ''
Assert 'BB14 a long turn with an empty composer is left alone' (-not $bbQuiet.Stalled)
$bbUnknown = Resolve-LoopStallVerdict -TurnAgeMinutes ([double]::PositiveInfinity) -StaleMinutes 180 -SuspectMinutes 45
Assert 'BB15 a lock that cannot say when its turn started reads as stalled, not as fine' `
    ($bbUnknown.Stalled -and $bbUnknown.Why -match 'unknown time')

# --- the watchdog acts on it ---
Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue
$bbProc = Start-Sleeper; $sleepers += $bbProc
Lock-Run @('acquire', '-PaneId', 'PANE-BB', '-ClaudePid', $bbProc.Id) | Out-Null
# Fresh transcript and fresh heartbeat - this fixture is HELD by every liveness
# measure there is. Only the turn is old.
$L = Read-LockFile
$L.turn_started = (Get-Date).AddMinutes(-200).ToString('o')
Write-LockFile $L
Assert 'BB16 the lock still reads held - no liveness signal is stale' `
    ((Lock-Run @('status', '-PaneId', 'PANE-BB')).Out -match '^held')
$r = Dog-Run @('-DryRun')
Assert 'BB17 a held lock whose turn has not completed is re-entered anyway' `
    ($r.Out -match 'ACTION new-window')
Assert 'BB18 and the log names the clock it decided on' ($r.Out -match 'STALLED\(by=turn\)')
Assert 'BB19 and the number, so a wrong call is auditable' `
    ($r.Out -match 'no turn has completed for 200' -and $r.Out -match 'turn_age=200\.\d+m\(limit=180m\)')
# Teeth, the AA1b way: the SAME fixture with the turn gate widened out of the
# way does nothing at all. Without this arm BB17 passes on any unrelated
# staleness - which is how a gate that cannot fail ships looking like one that can.
$r = Dog-Run @('-DryRun', '-TurnStaleMinutes', '100000', '-TurnSuspectMinutes', '100000')
Assert 'BB20 widening the turn gate makes the same fixture healthy again' `
    ($r.Out -match 'ACTION none' -and $r.Out -match 'healthy:')
Assert 'BB21 and the healthy line carries both clocks, not just the pulse' `
    ($r.Out -match 'healthy:.*age=[\d.]+m\(by=\w+\).*turn_age=200\.\d+m')
# The safe direction: between the suspect bar and the backstop, a composer the
# watchdog cannot read is never treated as full. "Could not see the pane" must
# not be the thing that types into it.
$r = Dog-Run @('-DryRun', '-TurnStaleMinutes', '100000', '-TurnSuspectMinutes', '45')
Assert 'BB22 an unreadable composer does not count as unsent text' `
    ($r.Out -match 'ACTION none' -and $r.Out -match 'healthy:')
# And the log SAYS what it saw, so the next miss is readable in the log rather
# than only in the limit it chose (T1370). On 2026-09-05 `limit=180m` was the
# only evidence that the composer had been read as empty.
Assert 'BB22b and the healthy line names the observation, not just the clocks' `
    ($r.Out -match 'healthy:.*composer=none session=unknown')

# --- BB23-BB34. is the session WORKING, or merely present? (T1370) ---------
#
# BB3d already refused the status line's `/rc` as pending text, and it was
# right: on this box EVERY pane carries a right-aligned slash-command
# indicator - `/rc` on a healthy pane mid-turn, `/rc failed` on another - so it
# is a record of the last command, not input waiting to be sent. That is also
# why the composer arm did not fire on 2026-09-05: the composer really WAS
# empty. An API transport error truncated the turn before anything was typed.
#
# So the discriminator that shape needs is not "is there text" but "is Claude
# working". A Claude Code TUI in flight renders a spinner with the elapsed time
# directly above the composer; an idle one renders nothing there. Idle plus a
# turn clock that has not moved is a stalled turn, whatever the composer holds.
$bbSpin = '  ' + ([string][char]0x2733) + ' Whirlpooling' + ([string][char]0x2026) +
          ' (3m 1s ' + ([string][char]0x00B7) + ' ' + ([string][char]0x2193) +
          ' 6.3k tokens ' + ([string][char]0x00B7) + ' thought for 25s)'
$bbStatus = 'ctx: 117k/1000k (12%) | files: 1 changed | v2.1.251 (Opus 5 (1M context))                  /rc'
function BBLivePane([string[]]$Body) {
    return ((@('* Read(go.md)', '') + $Body + @(
        "$bbRule> ",
        "$bbRule  $bbStatus",
        '  users/dzearing/windows-amd64 | D:\git\ghoztty',
        '  ' + ([string][char]0x23F5) + ' bypass permissions on - 7 shells'
    )) -join "`r`n")
}
# Measured off the loop's own pane 2026-09-05 17:20 while this task was being
# worked - a turn demonstrably in flight.
$bbWorking = BBLivePane @($bbSpin, '  Tip: Use /btw to ask a quick side question')
# And the 2026-09-05 15:45 stall: same chrome, same status-line `/rc`, no
# spinner, and the transport error that ended the turn still on screen.
$bbIdle = BBLivePane @(
    '  The response stopped arriving. The response above may be incomplete.',
    '')
Assert 'BB23 a pane with the elapsed-time spinner is working' `
    ((Get-PaneWorkingState -Tail $bbWorking) -eq 'working')
Assert 'BB24 the 2026-09-05 pane - same chrome, no spinner - is idle' `
    ((Get-PaneWorkingState -Tail $bbIdle) -eq 'idle')
# The composer arm's own reading of that pane, which is what made the miss
# invisible: it is empty, and correctly so.
Assert 'BB25 and its composer really is empty, so the composer arm was right' `
    ((Get-PaneComposerText -Tail $bbIdle) -eq '')
# Safe direction everywhere else: "I cannot see a Claude composer" is never
# "the session is idle", because idle is the answer that types into a pane.
Assert 'BB26 a pane with no composer at all is unknown, not idle' `
    ((Get-PaneWorkingState -Tail "D:\git\ghoztty>") -eq 'unknown')
Assert 'BB27 an empty read is unknown, not idle' ((Get-PaneWorkingState -Tail '') -eq 'unknown')
# The spinner only counts where it lives - just above the composer. One left
# behind in the scrollback must not report a dead session as working.
Assert 'BB28 a spinner far up the scrollback is out of the window' `
    ((Get-PaneWorkingState -Tail (BBLivePane (@($bbSpin) + (1..14 | ForEach-Object { "  line $_" })))) -eq 'idle')
# The other spinner shape, early in a turn before any tokens have arrived.
Assert 'BB29 the early-turn spinner counts too' `
    ((Get-PaneWorkingState -Tail (BBLivePane @('  ' + ([string][char]0x2733) + ' Herding' + ([string][char]0x2026) + ' (7s ' + ([string][char]0x00B7) + ' esc to interrupt)'))) -eq 'working')

# --- the verdict's third arm ---
$bbStuck = Resolve-LoopStallVerdict -TurnAgeMinutes 67 -StaleMinutes 180 -SuspectMinutes 45 `
    -ComposerText '' -PaneState 'idle'
Assert 'BB30 the 2026-09-05 shape - idle session, empty composer, turn unmoved - is stalled' `
    ($bbStuck.Stalled -and $bbStuck.Clock -eq 'idle')
Assert 'BB31 and it names the 67 minutes it decided on' ($bbStuck.Why -match '67')
# The gate that protects a slow build: working is working, however long it runs.
$bbBusy = Resolve-LoopStallVerdict -TurnAgeMinutes 152 -StaleMinutes 180 -SuspectMinutes 45 `
    -ComposerText '' -PaneState 'working'
Assert 'BB32 a long turn that is still working is left alone' (-not $bbBusy.Stalled)
$bbIdleEarly = Resolve-LoopStallVerdict -TurnAgeMinutes 10 -StaleMinutes 180 -SuspectMinutes 45 `
    -ComposerText '' -PaneState 'idle'
Assert 'BB33 an idle pane early in a turn is between turns, not a stall' (-not $bbIdleEarly.Stalled)
$bbBlind = Resolve-LoopStallVerdict -TurnAgeMinutes 152 -StaleMinutes 180 -SuspectMinutes 45 `
    -ComposerText '' -PaneState 'unknown'
Assert 'BB34 a pane the probe could not classify is not nudged' (-not $bbBlind.Stalled)

Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue

# --- cleanup --------------------------------------------------------------
Kill-Sleepers
Stop-DebugGhoztty
if ($td) { Remove-TestDesktop }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd') -Force -ErrorAction SilentlyContinue

# --- stamp (T783) ---------------------------------------------------------
# A green run RECORDS the content of every file it covers, so
# scripts\guard-due.ps1 can answer "has anything run this harness against the
# code as it now stands?". Stamped only on a CLEAN sweep: a run with skipped
# sections proved less than the whole harness claims, and a stamp written over
# unmeasured code is the green hat this suite spends so much effort refusing.
# A red run leaves the stamp alone on purpose - red must stay due.
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) {
        "  stamp NOT updated: $($script:skipped) section(s) skipped, so this run did not cover the whole harness"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard go-loop -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    }
}

""
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" ; exit 0 }
else { "$($script:failures) FAILURE(S)" ; exit 1 }
