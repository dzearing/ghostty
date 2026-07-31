# Single-instance guard for the go.md parity loop (tracker T139a).
#
# The loop in go.md is self-perpetuating: every turn ends with /reset-context
# and the fresh session picks the next task. Nothing stopped TWO sessions from
# running that loop at once (T138's upgrade-script fork did exactly that on
# 2026-07-28: both sessions resumed the same transcript and both started
# building T131). Two loops on one tracker clash - same task, same files, two
# sets of commits.
#
# This script is the lock those sessions cooperate on. go.md step 1 runs
#   powershell -NoProfile -File scripts\go-loop-lock.ps1 acquire
# and a session that gets BUSY (exit 3) stops instead of working the task.
#
# The lock is a JSON file (default <repo>\temp\go-loop.lock.json - temp/ is
# gitignored) recording the owner's Ghoztty pane id, its claude pid + process
# start time (so a recycled pid cannot inherit the lock), and a heartbeat.
#
# Ownership is keyed on the PANE, not the pid: /reset-context keeps the pane
# and the pid, but the upgrade script kills claude and relaunches it in the
# same pane, and that relaunched session is the SAME loop slot.
#
# Takeover rules (so a crash never wedges the loop permanently):
#   - same pane id            -> refresh, it is our own lock
#   - owner process is gone   -> take it (reason=dead-owner)
#   - heartbeat older than    -> take it (reason=stale-heartbeat)
#     -StaleMinutes (30)
#   - otherwise               -> BUSY, exit 3
#
# Actions: acquire | heartbeat | release | status | adopt
# Exit codes: 0 ok, 2 usage/error, 3 BUSY (another live owner), 4 not owner.
#
# `adopt` is acquire's small cousin, for the watchdog (T241): a claude that was
# relaunched IN the owning pane is the same loop slot with a new pid, and until
# it runs step 0 the lock points at a corpse. Adopt re-points claude_pid at the
# live process without touching the pane, the turn counter, or acquire's
# takeover rules - the caller must already have established that the new
# process really is the one in that pane.
#
#   powershell -NoProfile -File scripts\go-loop-lock.ps1 acquire
#   powershell -NoProfile -File scripts\go-loop-lock.ps1 status -Json
param(
    [Parameter(Position = 0)]
    [ValidateSet('acquire', 'heartbeat', 'release', 'status', 'adopt')]
    [string]$Action = 'status',

    [string]$Repo,
    [string]$LockPath,
    [string]$PaneId = $env:GHOZTTY_PANE_ID,
    [int]$ClaudePid = 0,
    [int]$StaleMinutes = 30,
    [switch]$Json,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $LockPath) { $LockPath = Join-Path (Join-Path $Repo 'temp') 'go-loop.lock.json' }

$IsoFmt = "yyyy-MM-ddTHH:mm:ss.fffffffK"
function Now-Iso { (Get-Date).ToString($IsoFmt) }
function Parse-Iso($s) {
    if (-not $s) { return $null }
    try {
        return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

# --- identity -------------------------------------------------------------

# The claude process that owns this session. $env:CLAUDE_PID is set by Claude
# Code for its tool shells; when it is missing (or points at something that is
# not claude any more) walk our own ancestry looking for claude.exe.
function Resolve-ClaudePid {
    if ($ClaudePid -gt 0) { return $ClaudePid }
    if ($env:CLAUDE_PID) {
        $p = Get-Process -Id ([int]$env:CLAUDE_PID) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'claude') { return [int]$env:CLAUDE_PID }
    }
    $walk = $PID
    for ($i = 0; $i -lt 8 -and $walk; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$walk" -ErrorAction SilentlyContinue
        if (-not $proc) { break }
        if ($proc.Name -like 'claude*') { return [int]$proc.ProcessId }
        $walk = $proc.ParentProcessId
    }
    return 0
}

function Get-ProcStamp($procId) {
    if (-not $procId -or $procId -le 0) { return $null }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $start = $null
    try { $start = $p.StartTime } catch { $start = $null }
    return @{ Name = $p.ProcessName; Start = $start }
}

# --- lock file ------------------------------------------------------------

function Read-Lock {
    if (-not (Test-Path $LockPath)) { return $null }
    try { return (Get-Content $LockPath -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { return $null }   # a truncated/corrupt lock is treated as no lock
}

function Write-Lock($lock) {
    $dir = Split-Path -Parent $LockPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $tmp = "$LockPath.$PID.tmp"
    ($lock | ConvertTo-Json -Depth 5) | Out-File -FilePath $tmp -Encoding utf8
    Move-Item -Force $tmp $LockPath
}

# Is the recorded owner still a live claude process? A pid alone is not proof:
# pids get recycled, so the recorded process name and start time must match.
function Test-OwnerAlive($lock) {
    if (-not $lock) { return $false }
    $stamp = Get-ProcStamp ([int]$lock.claude_pid)
    if (-not $stamp) { return $false }
    if ($lock.claude_name -and $stamp.Name -ne $lock.claude_name) { return $false }
    $recorded = Parse-Iso $lock.claude_start
    if ($recorded -and $stamp.Start) {
        if ([math]::Abs(($stamp.Start - $recorded).TotalSeconds) -gt 2) { return $false }
    }
    return $true
}

function Get-AgeMinutes($lock) {
    $hb = Parse-Iso $lock.heartbeat
    if (-not $hb) { return [double]::PositiveInfinity }
    return ((Get-Date) - $hb).TotalMinutes
}

function Test-Mine($lock) {
    if (-not $lock) { return $false }
    if ($PaneId -and $lock.pane_id -and $lock.pane_id -eq $PaneId) { return $true }
    # No pane id (not running in a Ghoztty pane): fall back to pid identity.
    if (-not $PaneId -and [int]$lock.claude_pid -eq $myPid -and $myPid -gt 0) { return $true }
    return $false
}

function Emit($lock, $line) {
    if ($Json) { ($lock | ConvertTo-Json -Depth 5) } else { $line }
}

$myPid = Resolve-ClaudePid
$myStamp = Get-ProcStamp $myPid

switch ($Action) {

    'acquire' {
        $lock = Read-Lock
        $reason = 'free'
        if ($lock) {
            $age = Get-AgeMinutes $lock
            if (Test-Mine $lock) { $reason = 'own-lock' }
            elseif ($Force) { $reason = 'forced' }
            elseif (-not (Test-OwnerAlive $lock)) { $reason = 'dead-owner' }
            elseif ($age -gt $StaleMinutes) { $reason = 'stale-heartbeat' }
            else {
                $line = "BUSY owner_pane=$($lock.pane_id) owner_pid=$($lock.claude_pid) " +
                        "heartbeat=$($lock.heartbeat) age=$([math]::Round($age, 1))m"
                Emit $lock $line
                exit 3
            }
        }

        $turn = 1
        $acquired = Now-Iso
        if ($lock -and $reason -eq 'own-lock') {
            if ($lock.turn) { $turn = [int]$lock.turn + 1 }
            if ($lock.acquired) { $acquired = $lock.acquired }
        }

        $startIso = ''
        if ($myStamp -and $myStamp.Start) { $startIso = $myStamp.Start.ToString($IsoFmt) }
        $name = ''
        if ($myStamp) { $name = $myStamp.Name }

        $new = [ordered]@{
            version      = 1
            pane_id      = $PaneId
            claude_pid   = $myPid
            claude_name  = $name
            claude_start = $startIso
            host         = $env:COMPUTERNAME
            repo         = $Repo
            acquired     = $acquired
            heartbeat    = Now-Iso
            turn         = $turn
            reason       = $reason
        }
        Write-Lock $new

        # Re-read: if two sessions raced, the loser sees the winner's pane id
        # here and backs off rather than both believing they hold the lock.
        $check = Read-Lock
        if (-not $check -or -not (Test-Mine $check)) {
            Emit $check "BUSY owner_pane=$($check.pane_id) owner_pid=$($check.claude_pid) (lost acquire race)"
            exit 3
        }
        Emit $check "ACQUIRED pane=$($new.pane_id) pid=$($new.claude_pid) turn=$turn reason=$reason"
        exit 0
    }

    'heartbeat' {
        $lock = Read-Lock
        if (-not $lock) { Emit $null 'NOTOWNER no lock file'; exit 4 }
        if (-not (Test-Mine $lock) -and -not $Force) {
            Emit $lock "NOTOWNER owner_pane=$($lock.pane_id) owner_pid=$($lock.claude_pid)"
            exit 4
        }
        $lock.heartbeat = Now-Iso
        Write-Lock $lock
        Emit $lock "HEARTBEAT pane=$($lock.pane_id) pid=$($lock.claude_pid) turn=$($lock.turn)"
        exit 0
    }

    'adopt' {
        $lock = Read-Lock
        if (-not $lock) { Emit $null 'NOTOWNER no lock file'; exit 4 }
        if (-not (Test-Mine $lock) -and -not $Force) {
            Emit $lock "NOTOWNER owner_pane=$($lock.pane_id) owner_pid=$($lock.claude_pid)"
            exit 4
        }
        if ($myPid -le 0) { Emit $lock 'ERROR no claude pid to adopt'; exit 2 }
        if (-not $myStamp) { Emit $lock "ERROR pid $myPid is not a live process"; exit 2 }
        # Add-Member -Force, not property assignment: a lock written by an
        # older build may not carry every field, and assigning to a missing
        # property on a PSCustomObject throws.
        $startIso = ''
        if ($myStamp.Start) { $startIso = $myStamp.Start.ToString($IsoFmt) }
        $lock | Add-Member -NotePropertyName claude_pid -NotePropertyValue $myPid -Force
        $lock | Add-Member -NotePropertyName claude_name -NotePropertyValue $myStamp.Name -Force
        $lock | Add-Member -NotePropertyName claude_start -NotePropertyValue $startIso -Force
        $lock | Add-Member -NotePropertyName reason -NotePropertyValue 'adopted' -Force
        $lock | Add-Member -NotePropertyName heartbeat -NotePropertyValue (Now-Iso) -Force
        Write-Lock $lock
        Emit $lock "ADOPTED pane=$($lock.pane_id) pid=$($lock.claude_pid) turn=$($lock.turn)"
        exit 0
    }

    'release' {
        $lock = Read-Lock
        if (-not $lock) { Emit $null 'FREE no lock file'; exit 0 }
        if (-not (Test-Mine $lock) -and -not $Force) {
            Emit $lock "NOTOWNER owner_pane=$($lock.pane_id) owner_pid=$($lock.claude_pid)"
            exit 4
        }
        Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
        Emit $lock "RELEASED pane=$($lock.pane_id) pid=$($lock.claude_pid)"
        exit 0
    }

    'status' {
        $lock = Read-Lock
        if (-not $lock) {
            if ($Json) { '{"state":"free"}' } else { 'FREE lock=' + $LockPath }
            exit 0
        }
        $age = Get-AgeMinutes $lock
        $alive = Test-OwnerAlive $lock
        $state = 'held'
        if (-not $alive) { $state = 'stale-dead' }
        elseif ($age -gt $StaleMinutes) { $state = 'stale-heartbeat' }
        $lock | Add-Member -NotePropertyName state -NotePropertyValue $state -Force
        $lock | Add-Member -NotePropertyName owner_alive -NotePropertyValue $alive -Force
        $lock | Add-Member -NotePropertyName age_minutes -NotePropertyValue ([math]::Round($age, 2)) -Force
        $lock | Add-Member -NotePropertyName mine -NotePropertyValue (Test-Mine $lock) -Force
        Emit $lock ("$state pane=$($lock.pane_id) pid=$($lock.claude_pid) alive=$alive " +
                    "age=$([math]::Round($age, 1))m turn=$($lock.turn) mine=$(Test-Mine $lock)")
        exit 0
    }
}
