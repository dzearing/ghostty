# One-shot health answer for the go.md parity loop (user, 2026-08-11).
#
# The pieces this reads all existed - go-loop-lock.ps1 status, go-loop-exec.ps1
# list, go-loop-watchdog.ps1 -Status, the dashboard port - but answering "is the
# loop actually running, and for how long" meant running four commands and
# correlating them by hand. That is too much friction for a check that is
# supposed to happen every couple of hours, and friction is why it did not
# happen: on 2026-08-11 the loop was revived into a second window at 08:21 and
# nobody noticed until the user asked why the tracker had died.
#
# Every line is timestamped and carries UPTIME, because "alive" alone cannot
# tell a loop that has run all night from one revived forty seconds ago - and
# the difference between those two is the entire question.
#
#   powershell -NoProfile -File scripts\go-loop-health.ps1
#   powershell -NoProfile -File scripts\go-loop-health.ps1 -Json
#   powershell -NoProfile -File scripts\go-loop-health.ps1 -Postmortem
#
# It also answers "did today's digest get written?" (`digest=` on the line,
# T1223) - go.md step 0.5 had no enforcement at all, so a skipped morning was
# invisible until somebody asked for it.
#
# Exit codes are the verdict, so a caller can branch without parsing:
#   0 healthy      - a live owner, recent activity, a marked window
#   1 degraded     - running, but something is off (no marked window, no
#                    watchdog, dashboard down, activity going stale)
#   2 down         - no live loop owner at all
#   3 stopped      - quiet ON PURPOSE: somebody ran `go-loop-exec.ps1 stop`.
#                    Distinct from `down` because a supervisor that cannot tell
#                    them apart re-enters the loop the user just stopped.
[CmdletBinding()]
param(
    # Resolved in the body, not here: $PSScriptRoot is not yet bound while
    # parameter defaults are evaluated under PS 5.1, so a default that reads it
    # dies before the first line runs.
    [string]$Repo,
    [int]$Port = 7788,
    [string]$StopPath,
    # Activity older than this means the loop is not turning even if the
    # process is alive. Deliberately generous: a build-and-test task legitimately
    # runs long, and a false "stalled" is worse than a late one.
    [int]$StaleMinutes = 45,
    # The instant the daily-digest window is judged against. Defaults to now;
    # the harness passes an explicit one so "before 05:00" and "after 05:00"
    # are both reachable without waiting for a particular hour of the day.
    [datetime]$DigestAsOf = [datetime]::MinValue,
    [switch]$Json,
    # Gather the evidence a death leaves behind, for dissecting WHY.
    [switch]$Postmortem
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if ($DigestAsOf -eq [datetime]::MinValue) { $DigestAsOf = Get-Date }
# Get-LoopStop. loop-session.ps1 is documented as free of load-time side effects.
. (Join-Path $PSScriptRoot 'loop-session.ps1')
$IsoFmt = 'yyyy-MM-ddTHH:mm:ssK'
function Now-Iso { (Get-Date).ToString($IsoFmt) }

function Test-Port([int]$P) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $P); return $true } catch { return $false } finally { $c.Dispose() }
}

# --- the loop lock ---------------------------------------------------------

$lock = $null
try {
    $raw = & powershell -NoProfile -File (Join-Path $PSScriptRoot 'go-loop-lock.ps1') status -Json 2>$null
    if ($raw) { $lock = ($raw | Out-String | ConvertFrom-Json) }
} catch { }

$state = 'free'
$uptime = '-'
$uptimeMin = 0
$turn = 0
$pane = ''
$loopPid = 0
$ageMin = [double]::PositiveInfinity
if ($lock -and $lock.state) {
    $state = [string]$lock.state
    if ($lock.PSObject.Properties.Name -contains 'uptime') { $uptime = [string]$lock.uptime }
    if ($lock.PSObject.Properties.Name -contains 'uptime_minutes') { $uptimeMin = [double]$lock.uptime_minutes }
    $turn = [int]$lock.turn
    $pane = [string]$lock.pane_id
    $loopPid = [int]$lock.claude_pid
    if ($lock.PSObject.Properties.Name -contains 'age_minutes') { $ageMin = [double]$lock.age_minutes }
}

# --- the marked execution window -------------------------------------------
#
# A held lock with no [go-loop]-marked window is the shape the 2026-08-11
# duplication left behind: the lock moved to a revived session while an older
# window kept believing it was primary.
$marked = 0
try {
    $list = & powershell -NoProfile -File (Join-Path $PSScriptRoot 'go-loop-exec.ps1') list 2>$null
    $marked = @($list | Where-Object { $_ -match '\[go-loop\]' }).Count
} catch { }

# --- the supervisor ---------------------------------------------------------

$watchdog = $false
try {
    $w = & powershell -NoProfile -File (Join-Path $PSScriptRoot 'go-loop-watchdog.ps1') -Status 2>$null
    $watchdog = [bool]@($w | Where-Object { $_ -match '^running:\s+True' }).Count
} catch { }

$dashboard = Test-Port $Port

# --- what the loop is working on -------------------------------------------

$inProgress = @()
try {
    $taskDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
    $inProgress = @(Get-ChildItem $taskDir -Filter 'T*.md' -File -ErrorAction Stop |
        ForEach-Object {
            $head = Get-Content $_.FullName -TotalCount 20 -ErrorAction SilentlyContinue
            if ($head -match '^status:\s*"?in-progress"?') { $_.BaseName }
        })
} catch { }

# A decision the loop filed and is waiting on is one of the named suspects for
# a stall, so it is reported rather than left to a separate command.
$openDecisions = 0
try {
    $decDir = Join-Path $Repo 'docs\design\windows-parity-decisions'
    $openDecisions = @(Get-ChildItem $decDir -Filter 'D*.md' -File -ErrorAction Stop |
        Where-Object { (Get-Content $_.FullName -TotalCount 20 -ErrorAction SilentlyContinue) -match '^status:\s*"?open"?' }).Count
} catch { }

# --- the daily digest (T1223) ----------------------------------------------
#
# go.md step 0.5 asks for one digest a day, written for the user to read over
# coffee. On 2026-09-01 the loop simply did not write one, and nothing anywhere
# said so - the user found out by asking at 05:18. Before that, 08-24 through
# 08-29 went missing the same silent way. A step whose omission produces no
# signal is a step that eventually stops happening, so the omission gets a
# field here, beside the dead-lock and dead-watchdog lines somebody already
# reads.
#
# This never WRITES one, and must not: a generated placeholder turns the light
# green while destroying the thing the light measures. The digest is worth
# reading because somebody looked at the day and thought about it.
#
# Three states, and the middle one is why this is not a one-liner:
#   present  - today's file is on disk
#   missing  - past 05:00, the loop was turning today, and there is no file
#   not-due  - before 05:00, or the loop did not turn today at all (a box that
#              was off overnight, or a loop stopped on purpose, owes nothing;
#              and the standing rule is never to backfill a missed day)
$digestDate = $DigestAsOf.ToString('yyyy-MM-dd')
$digestRel = "docs\design\windows-parity-digests\$digestDate.md"
$digestState = 'not-due'
if (Test-Path -LiteralPath (Join-Path $Repo $digestRel)) {
    $digestState = 'present'
} else {
    $dueAt = $DigestAsOf.Date.AddHours(5)
    if ($DigestAsOf -ge $dueAt) {
        # "Did the loop turn today?" is answered from the lock history, not the
        # live lock: the lock says who holds it NOW, and a loop that ran this
        # morning and then died would read as owing nothing.
        $aliveToday = $false
        $histPath = Join-Path $Repo 'temp\go-loop-history.jsonl'
        if (Test-Path -LiteralPath $histPath) {
            foreach ($line in @(Get-Content -LiteralPath $histPath -Tail 500 -ErrorAction SilentlyContinue)) {
                if (-not $line) { continue }
                $at = $null
                try { $at = [datetime]::Parse([string](($line | ConvertFrom-Json).at)) } catch { continue }
                if ($at -ge $dueAt -and $at -le $DigestAsOf) { $aliveToday = $true; break }
            }
        }
        if ($aliveToday) { $digestState = 'missing' }
    }
}

# --- verdict ----------------------------------------------------------------

$alive = ($state -eq 'held')
$notes = @()
if (-not $alive) { $notes += "loop owner is $state" }
if ($alive -and $marked -eq 0) { $notes += 'no [go-loop]-marked window' }
if ($alive -and $marked -gt 1) { $notes += "$marked marked windows (duplicate loops)" }
if ($alive -and $ageMin -gt $StaleMinutes) { $notes += "no activity for $([math]::Round($ageMin))m" }
if (-not $watchdog) { $notes += 'watchdog is not running' }
if (-not $dashboard) { $notes += "dashboard is not listening on $Port" }
if ($inProgress.Count -gt 1) { $notes += "$($inProgress.Count) tasks claimed in-progress" }
if ($digestState -eq 'missing') {
    $notes += "today's digest is missing - go.md step 0.5, write $digestRel (never backfill an older day)"
}

$verdict = 'healthy'
$code = 0
if (-not $alive) { $verdict = 'down'; $code = 2 }
elseif ($notes.Count -gt 0) { $verdict = 'degraded'; $code = 1 }

# A requested stop reads EXACTLY like a dead loop - no owner, no marked window,
# no activity - so without this the 2-hourly supervisor check answers DOWN and
# revives the thing the user just asked to stop. Its own verdict and its own
# exit code (3), because "stopped" is not a degraded "down": nothing is wrong.
$stopReq = Get-LoopStop -Repo $Repo -Path $StopPath
if ($stopReq) {
    $verdict = 'stopped'
    $code = 3
    $notes = @(("stopped by request at $($stopReq.requested_at) by $($stopReq.requested_by)" +
        $(if ($stopReq.reason) { " - $($stopReq.reason)" } else { '' }))) +
        @('resume with: powershell -NoProfile -File scripts\go-loop-exec.ps1 resume') +
        ($notes | Where-Object { $_ -notmatch '^loop owner is |^watchdog is not running$' })
}

if ($Json) {
    [ordered]@{
        at             = Now-Iso
        verdict        = $verdict
        state          = $state
        uptime         = $uptime
        uptime_minutes = $uptimeMin
        turn           = $turn
        pane_id        = $pane
        claude_pid     = $loopPid
        age_minutes    = if ([double]::IsInfinity($ageMin)) { $null } else { $ageMin }
        marked_windows = $marked
        watchdog       = $watchdog
        dashboard      = $dashboard
        in_progress    = $inProgress
        open_decisions = $openDecisions
        digest         = $digestState
        digest_path    = $digestRel
        stopped        = [bool]$stopReq
        notes          = $notes
    } | ConvertTo-Json -Depth 4
} else {
    $task = if ($inProgress.Count) { $inProgress -join ',' } else { 'none' }
    "$(Now-Iso) $($verdict.ToUpper()) uptime=$uptime turn=$turn state=$state pane=$pane pid=$loopPid " +
    "task=$task decisions_open=$openDecisions digest=$digestState windows=$marked watchdog=$watchdog dashboard=$dashboard"
    foreach ($n in $notes) { "  - $n" }
}

if ($Postmortem) {
    ''
    '=== lock history (newest last) ==='
    $hist = Join-Path $Repo 'temp\go-loop-history.jsonl'
    if (Test-Path $hist) { Get-Content $hist -Tail 20 } else { "(none yet: $hist)" }
    ''
    '=== watchdog log ==='
    $wlog = Join-Path $env:TEMP 'ghoztty-go-loop-watchdog.log'
    if (Test-Path $wlog) { Get-Content $wlog -Tail 20 } else { "(none: $wlog)" }
    ''
    '=== ghoztty / agent process ages (a restart kills the loop AND the tracker) ==='
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe' OR Name='ghoztty-agent.exe'" |
        Select-Object ProcessId, Name, CreationDate, ExecutablePath | Format-Table -AutoSize | Out-String
    '=== claude processes ==='
    Get-Process claude -ErrorAction SilentlyContinue |
        Select-Object Id, StartTime | Sort-Object StartTime | Format-Table -AutoSize | Out-String
}

exit $code
