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
#   - no sign of life for     -> take it (reason=stale-heartbeat)
#     -StaleMinutes (30)
#   - otherwise               -> BUSY, exit 3
#
# "Sign of life" is the NEWER of two signals (T253): the heartbeat, which a step
# in go.md refreshes at task boundaries, and the mtime of the session's own
# Claude Code transcript, which the harness advances on every message and every
# tool result. The heartbeat alone is a checkpoint that only exists when a model
# remembers to emit it, and a 46-minute task therefore read as a dead loop.
#
# `status` answers the same question the pane does, not just the pid (T440):
# when the recorded claude is gone but the owning pane still holds a live claude
# - the whole window after an upgrade relaunch, before the fresh session runs
# step 0 - it reports `held` with `owner_alive_by=pane` rather than
# `stale-dead`. See Test-PaneHoldsClaude.
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
    [switch]$Force,
    # The session transcript whose mtime is this loop's PULSE (T253). Normally
    # resolved from $env:CLAUDE_CODE_SESSION_ID; passed explicitly only by tests
    # and by a caller that already knows it. '-' records no transcript at all.
    [string]$TranscriptPath,
    # `status` only (T440): when the recorded pid is dead, ask the OWNING PANE
    # whether a claude is sitting in it before calling the loop dead. Skip the
    # probe with -NoPaneProbe (it costs one `ghoztty +read`, and a test that is
    # asserting the dead-pid path does not want the pane to answer for it).
    [switch]$NoPaneProbe,
    [string]$GhozttyExe = "$env:LOCALAPPDATA\Programs\Ghoztty\ghoztty.exe"
)

$ErrorActionPreference = 'Stop'

# Process identity is SHARED with the upgrade script, never re-derived here
# (T168). Both decide the same fact about the same loop - the lock decides who
# may work, the upgrade decides whether to relaunch - so a fix applied to one
# private copy would leave the other making the opposite call. That is the exact
# shape of the bug T138 fixed, so there is exactly one implementation:
# Resolve-LoopClaudePid / Get-LoopProcStamp / Test-LoopProcAlive.
. (Join-Path $PSScriptRoot 'loop-session.ps1')

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
#
# The claude process that owns this session, and whether a recorded owner is
# still that same live process, both come from loop-session.ps1 (dot-sourced
# above): Resolve-LoopClaudePid -Explicit $ClaudePid, Get-LoopProcStamp,
# Test-LoopProcAlive. The only thing left here is the translation between the
# LOCK FILE's shape (claude_pid / claude_name / claude_start, an ISO string) and
# the stamp objects those helpers speak - see Test-OwnerAlive.

# The session's own transcript - the file Claude Code appends to on every
# message and every tool result (T253).
#
# The heartbeat above is a CHECKPOINT: a step in go.md refreshes it at task
# boundaries, which means it is emitted only when a model remembers to emit it,
# and it goes missing exactly when the turn is busiest. On 2026-07-31 a turn
# spent 46 minutes on a build + acceptance run + delivery without one, the
# watchdog concluded the loop was stuck, and it typed a prompt into a session
# that was working - queueing a SECOND task into that context, the one thing the
# context rule exists to prevent.
#
# This is the pulse the checkpoint is not. Claude Code writes the transcript
# itself, so it advances while the turn works and stops when the turn ends,
# with nothing to remember and nothing to install. Recorded at `acquire`,
# because that runs INSIDE the session (go.md step 0) and $env:CLAUDE_CODE_SESSION_ID
# names it exactly - a watchdog looking in from outside could only guess.
#
# It is an ADDITIONAL source, never a replacement: an absent or unreadable
# transcript falls back to the heartbeat, which is today's behavior.
function Resolve-Transcript {
    if ($TranscriptPath) {
        if ($TranscriptPath -eq '-') { return '' }
        return $TranscriptPath
    }
    $sid = $env:CLAUDE_CODE_SESSION_ID
    if (-not $sid) { return '' }
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $root)) { return '' }
    # The per-project directory name is the cwd with ':' and '\' punched out to
    # '-'. Try that first (one stat), and only walk the tree when it misses, so
    # a mangling rule that changes upstream degrades to slow rather than wrong.
    $direct = Join-Path (Join-Path $root (($Repo -replace '[:\\/]', '-'))) "$sid.jsonl"
    if (Test-Path -LiteralPath $direct) { return $direct }
    $hit = Get-ChildItem -Path $root -Filter "$sid.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return ''
}

# When did this loop last show a sign of life, and which signal said so?
# The NEWER of the checkpoint and the pulse - a stale heartbeat with a moving
# transcript is a working turn, not a dead loop.
function Get-ActivityStamp($lock) {
    $at = Parse-Iso $lock.heartbeat
    $by = 'heartbeat'
    $t = ''
    if ($lock.PSObject.Properties.Name -contains 'transcript') { $t = [string]$lock.transcript }
    if ($t -and (Test-Path -LiteralPath $t)) {
        try {
            $m = (Get-Item -LiteralPath $t -ErrorAction Stop).LastWriteTime
            if (-not $at -or $m -gt $at) { $at = $m; $by = 'transcript' }
        } catch { }
    }
    return @{ At = $at; By = $by }
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
#
# The rule itself is Test-LoopProcAlive's; this only rehydrates the lock file's
# three flat fields into the stamp that function takes. A missing claude_pid
# reads as pid 0, which is dead - the same answer the private copy gave.
function Test-OwnerAlive($lock) {
    if (-not $lock) { return $false }
    return (Test-LoopProcAlive ([pscustomobject]@{
        Pid   = [int]$lock.claude_pid
        Name  = [string]$lock.claude_name
        Start = (Parse-Iso $lock.claude_start)
    }))
}

# The pid is not the loop; the PANE is (T440). The upgrade script kills claude
# and relaunches it in the same pane, and nothing updates the lock until that
# fresh session reaches go.md step 0 - an entire turn later, and unbounded if
# the resume failed. For that whole window `status` answered `stale-dead` about
# a session that was working, which is what a human and the dashboard both read
# as "nothing is running" (user, 2026-08-03: "the status page isn't reporting
# what's running").
#
# So when the recorded pid is a corpse, ask the pane. A claude in the owning
# pane IS the owner - that is already how `acquire` decides ownership, and this
# just teaches the readers the same rule. Only `status` does this: acquire's
# takeover rules stay pid-based on purpose, because a probe that misreads must
# never be able to wedge the loop.
function Test-PaneHoldsClaude($lock) {
    if ($NoPaneProbe) { return $false }
    if (-not $lock -or -not $lock.pane_id) { return $false }
    if (-not (Test-Path $GhozttyExe)) { return $false }
    try {
        . (Join-Path $PSScriptRoot 'go-loop-pane-probe.ps1')
        return ((Read-PaneOccupant -PaneId $lock.pane_id -GhozttyExe $GhozttyExe) -eq 'claude')
    } catch { return $false }
}

# Age of the loop's last sign of life, from whichever signal is newer (T253).
# Both `acquire`'s takeover rule and `status` read this, so a session that is
# demonstrably working cannot have its lock taken from under it either.
function Get-AgeMinutes($lock) {
    $s = Get-ActivityStamp $lock
    if (-not $s.At) { return [double]::PositiveInfinity }
    return ((Get-Date) - $s.At).TotalMinutes
}

# The raw checkpoint age, for readers that want to say "last checkpoint" rather
# than "last sign of life".
function Get-HeartbeatAgeMinutes($lock) {
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

$myPid = Resolve-LoopClaudePid -Explicit $ClaudePid
$myStamp = Get-LoopProcStamp $myPid

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

        # Re-resolved on every acquire, not carried over: /reset-context starts a
        # NEW session id in the SAME pane, so the previous turn's transcript is a
        # file that will never be appended to again.
        $transcript = ''
        try { $transcript = Resolve-Transcript } catch { $transcript = '' }

        $new = [ordered]@{
            version      = 1
            pane_id      = $PaneId
            claude_pid   = $myPid
            claude_name  = $name
            claude_start = $startIso
            session_id   = [string]$env:CLAUDE_CODE_SESSION_ID
            transcript   = $transcript
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
        Emit $check ("ACQUIRED pane=$($new.pane_id) pid=$($new.claude_pid) turn=$turn reason=$reason " +
                     "pulse=$(if ($transcript) { 'transcript' } else { 'heartbeat-only' })")
        exit 0
    }

    'heartbeat' {
        $lock = Read-Lock
        if (-not $lock) { Emit $null 'NOTOWNER no lock file'; exit 4 }
        if (-not (Test-Mine $lock) -and -not $Force) {
            Emit $lock "NOTOWNER owner_pane=$($lock.pane_id) owner_pid=$($lock.claude_pid)"
            exit 4
        }
        $lock | Add-Member -NotePropertyName heartbeat -NotePropertyValue (Now-Iso) -Force
        # heartbeat also runs INSIDE the session, so it is the second place that
        # can point the lock at this session's transcript - which is how a lock
        # written before T253 (or by an older build) gains the pulse without
        # waiting for the next acquire. Add-Member -Force, not assignment: such a
        # lock has no `transcript` property to assign to.
        $t = ''
        try { $t = Resolve-Transcript } catch { $t = '' }
        if ($t) {
            $lock | Add-Member -NotePropertyName transcript -NotePropertyValue $t -Force
            $lock | Add-Member -NotePropertyName session_id -NotePropertyValue ([string]$env:CLAUDE_CODE_SESSION_ID) -Force
        }
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
        $activity = Get-ActivityStamp $lock
        $age = Get-AgeMinutes $lock
        $hbAge = Get-HeartbeatAgeMinutes $lock
        $alive = Test-OwnerAlive $lock
        $aliveBy = 'pid'
        if (-not $alive -and (Test-PaneHoldsClaude $lock)) { $alive = $true; $aliveBy = 'pane' }
        if (-not $alive) { $aliveBy = 'none' }
        $state = 'held'
        if (-not $alive) { $state = 'stale-dead' }
        elseif ($age -gt $StaleMinutes) { $state = 'stale-heartbeat' }
        $lock | Add-Member -NotePropertyName state -NotePropertyValue $state -Force
        $lock | Add-Member -NotePropertyName owner_alive -NotePropertyValue $alive -Force
        $lock | Add-Member -NotePropertyName owner_alive_by -NotePropertyValue $aliveBy -Force
        # age_minutes is the age of the last SIGN OF LIFE, not of the heartbeat
        # (T253) - the heartbeat's own age is beside it for anyone who wants to
        # say "last checkpoint".
        $lock | Add-Member -NotePropertyName age_minutes -NotePropertyValue ([math]::Round($age, 2)) -Force
        $lock | Add-Member -NotePropertyName heartbeat_age_minutes -NotePropertyValue ([math]::Round($hbAge, 2)) -Force
        $lock | Add-Member -NotePropertyName activity_by -NotePropertyValue $activity.By -Force
        $activityIso = ''
        if ($activity.At) { $activityIso = $activity.At.ToString($IsoFmt) }
        $lock | Add-Member -NotePropertyName activity_at -NotePropertyValue $activityIso -Force
        $lock | Add-Member -NotePropertyName mine -NotePropertyValue (Test-Mine $lock) -Force
        Emit $lock ("$state pane=$($lock.pane_id) pid=$($lock.claude_pid) alive=$alive(by=$aliveBy) " +
                    "age=$([math]::Round($age, 1))m(by=$($activity.By)) turn=$($lock.turn) mine=$(Test-Mine $lock)")
        exit 0
    }
}
