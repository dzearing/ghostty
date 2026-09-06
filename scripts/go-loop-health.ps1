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
# invisible until somebody asked for it - and "did anything actually SHIP?"
# (`publish=`, T1292), which had the same shape and cost three days of finished
# work sitting on the branch while the user ran a build from before it.
#
# And it answers the question all of those presuppose: "is the loop doing WORK?"
# (`turn_age=`, T1290). Every other clock here measures liveness - a pid, a port,
# a pane that produced output - and on 2026-09-03 the loop was inert for 14.5
# hours while this line said HEALTHY, because the watchdog's nudge had refreshed
# the transcript six minutes earlier. A nudge is a treatment, not evidence; only
# a completed turn moves `turn_started`, so only a completed turn clears this.
#
# Exit codes are the verdict, so a caller can branch without parsing:
#   0 healthy      - a live owner, recent activity, a turning loop, a marked window
#   1 degraded     - running, but something is off (no marked window, no
#                    watchdog, dashboard down, activity going stale, no turn
#                    completed inside -TurnStaleMinutes)
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
    # The loop lock to read. Defaults to whatever go-loop-lock.ps1 resolves for
    # ITS repo, which is the real one - deliberately not derived from -Repo, so
    # a fixture repo cannot make a live loop read as free. The harness passes an
    # explicit path when the lock IS the subject.
    [string]$LockPath,
    # Activity older than this means the loop is not turning even if the
    # process is alive. Deliberately generous: a build-and-test task legitimately
    # runs long, and a false "stalled" is worse than a late one.
    [int]$StaleMinutes = 45,
    # How long a single turn may run before "the loop is working" stops being a
    # believable reading of a quiet pane (T1290). Much more generous than
    # -StaleMinutes because this clock only moves at turn boundaries: a
    # build-and-test task with a long acceptance sweep genuinely runs over an
    # hour, and the shape this exists to catch was FOURTEEN AND A HALF hours.
    [int]$TurnStaleMinutes = 180,
    # Past this, a quiet turn is worth ASKING the pane about (T1319's arms, and
    # the watchdog's own threshold). The 180m backstop above is the last
    # resort; these two arms are what catch a wedge in tens of minutes.
    [int]$TurnSuspectMinutes = 45,
    # Skip the pane read. The harness sets it so a health run needs no live
    # Ghoztty, and it is the only way to get the pre-2026-09-06 behavior back.
    [switch]$NoPaneProbe,
    # The ghoztty the pane probe reads through. Same default as the watchdog's,
    # so both supervisors question the same binary.
    [string]$GhozttyExe = "$env:LOCALAPPDATA\Programs\Ghoztty\ghoztty.exe",
    # The instant the daily-digest window is judged against. Defaults to now;
    # the harness passes an explicit one so "before 05:00" and "after 05:00"
    # are both reachable without waiting for a particular hour of the day.
    [datetime]$DigestAsOf = [datetime]::MinValue,
    # The daily publish's watermark, and the instant it is judged against
    # (T1292). Both are seams for the harness; the defaults are what the loop
    # actually reads.
    [string]$PublishWatermark = '',
    [datetime]$PublishAsOf = [datetime]::MinValue,
    # A pending "ship this now" request (T1294). Defaults beside the watermark.
    [string]$PublishRequest = '',
    # How long a request may sit unhonoured before the run degrades. A request is
    # filed mid-turn and honoured at that turn's step 6.5, so anything under an
    # hour is in-flight rather than stuck.
    [int]$RequestStaleHours = 3,
    [switch]$Json,
    # Gather the evidence a death leaves behind, for dissecting WHY.
    [switch]$Postmortem
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if ($DigestAsOf -eq [datetime]::MinValue) { $DigestAsOf = Get-Date }
if ($PublishAsOf -eq [datetime]::MinValue) { $PublishAsOf = Get-Date }
if (-not $PublishWatermark) { $PublishWatermark = Join-Path $env:LOCALAPPDATA 'ghoztty\daily-publish' }
if (-not $PublishRequest) { $PublishRequest = "$PublishWatermark-request" }
# Get-LoopStop. loop-session.ps1 is documented as free of load-time side effects.
. (Join-Path $PSScriptRoot 'loop-session.ps1')
$IsoFmt = 'yyyy-MM-ddTHH:mm:ssK'
function Now-Iso { (Get-Date).ToString($IsoFmt) }

function Format-Age([double]$minutes) {
    if ([double]::IsInfinity($minutes)) { return 'unknown' }
    if ($minutes -lt 0) { $minutes = 0 }
    $t = [TimeSpan]::FromMinutes($minutes)
    if ($t.TotalDays -ge 1) { return '{0}d {1:00}h {2:00}m' -f $t.Days, $t.Hours, $t.Minutes }
    if ($t.TotalHours -ge 1) { return '{0}h {1:00}m' -f [math]::Floor($t.TotalHours), $t.Minutes }
    return '{0}m' -f [math]::Floor($t.TotalMinutes)
}

function Test-Port([int]$P) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $P); return $true } catch { return $false } finally { $c.Dispose() }
}

# --- the loop lock ---------------------------------------------------------

$lock = $null
try {
    $lockArgs = @('status', '-Json')
    if ($LockPath) { $lockArgs += @('-LockPath', $LockPath, '-NoPaneProbe') }
    $raw = & powershell -NoProfile -File (Join-Path $PSScriptRoot 'go-loop-lock.ps1') @lockArgs 2>$null
    if ($raw) { $lock = ($raw | Out-String | ConvertFrom-Json) }
} catch { }

$state = 'free'
$uptime = '-'
$uptimeMin = 0
$turn = 0
$pane = ''
$loopPid = 0
$ageMin = [double]::PositiveInfinity
$turnAgeMin = [double]::PositiveInfinity
$turnStarted = ''
if ($lock -and $lock.state) {
    $state = [string]$lock.state
    if ($lock.PSObject.Properties.Name -contains 'uptime') { $uptime = [string]$lock.uptime }
    if ($lock.PSObject.Properties.Name -contains 'uptime_minutes') { $uptimeMin = [double]$lock.uptime_minutes }
    $turn = [int]$lock.turn
    $pane = [string]$lock.pane_id
    $loopPid = [int]$lock.claude_pid
    if ($lock.PSObject.Properties.Name -contains 'age_minutes') { $ageMin = [double]$lock.age_minutes }
    if (($lock.PSObject.Properties.Name -contains 'turn_age_minutes') -and $null -ne $lock.turn_age_minutes) {
        $turnAgeMin = [double]$lock.turn_age_minutes
    }
    if ($lock.PSObject.Properties.Name -contains 'turn_started') { $turnStarted = [string]$lock.turn_started }
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

# --- the daily publish (T1292) ---------------------------------------------
#
# The digest field above exists because a step whose omission produces no signal
# eventually stops happening. Delivery had exactly that shape and it was worse,
# because the omission was *reported* - one polite SKIP line per evening in a
# temp log nobody reads - while the user went three days downloading a build
# from before the fix they had asked for. "Nothing shipped" has to be visible in
# the same place as "no digest", so it is.
#
# Read from the publish watermark alone: no gh, no network, no clock beyond the
# local date. daily-publish.ps1 is what reconciles a pushed tag against the
# release CI actually created, so by the time a state gets here it is honest.
#
#   ok         - published (or tagged and building) today or yesterday, and the
#                release carries everything on this branch
#   ok+<n>     - the same, except n commits have landed since that release and
#                are on nobody's machine (T1294)
#   stale-<n>d - the last publish was n days ago, n >= 2
#   failed     - the last attempt did not produce a release, or died before it
#                could record one (T1369)
#   never      - nothing has ever been published from this box
#
# The `+<n>` suffix exists because `ok` was true and misleading on 2026-09-03:
# the day HAD published, and 24 commits - including the fix for the bug the user
# had just reported - sat behind it. "Published" and "current" are different
# questions, and only the second one is the one a user feels. It is deliberately
# NOT a degrade: a commit landing after a release is the normal state of an
# afternoon, and a light that is always red is not a light. What degrades is a
# publish REQUEST that has gone unhonoured, because that is somebody asking for a
# release and not getting one.
# An `attempting` stamp older than this is a publish nobody finished (T1369).
# Two hours: the local packaging path's ReleaseFast build is the slowest thing
# that legitimately sits in this state, and it is nowhere near that.
function Test-PublishAttemptAbandoned($Wm, [datetime]$AsOf) {
    if (-not $Wm.at) { return $true }
    try { return (($AsOf - [datetime]::Parse([string]$Wm.at)).TotalHours -ge 2) } catch { return $true }
}

$publishState = 'never'
$publishTag = ''
$publishDate = ''
$publishCommit = ''
$publishBehind = $null
$requestReason = ''
$requestAgeHours = $null
try {
    if (Test-Path -LiteralPath $PublishWatermark) {
        $wmText = [IO.File]::ReadAllText($PublishWatermark).Trim()
        $wm = $null
        if ($wmText.StartsWith('{')) { $wm = $wmText | ConvertFrom-Json }
        elseif ($wmText -match '^(\d{4}-\d{2}-\d{2})') { $wm = [pscustomobject]@{ date = $Matches[1]; tag = ''; result = '' } }
        if ($wm -and $wm.date) {
            $publishDate = [string]$wm.date
            $publishTag = [string]$wm.tag
            $publishCommit = [string]$wm.commit
            $days = [int]([math]::Floor(($PublishAsOf.Date - ([datetime]::ParseExact($publishDate, 'yyyy-MM-dd', $null)).Date).TotalDays))
            if ([string]$wm.result -eq 'failed') { $publishState = 'failed' }
            elseif ([string]$wm.result -eq 'attempting' -and (Test-PublishAttemptAbandoned $wm $PublishAsOf)) {
                # A run that stamped `attempting` and never got as far as an
                # outcome - a crash, a reboot, a killed turn. Live for the
                # minutes a real publish takes, and after that it is a day that
                # shipped nothing while reading `ok`.
                $publishState = 'failed'
            }
            elseif ($days -ge 2) { $publishState = "stale-${days}d" }
            elseif ($days -lt 0) { $publishState = 'ok' }
            else { $publishState = 'ok' }
        }
    }
} catch { $publishState = 'never' }

# How far the shipped release is behind this branch. Local git only; a commit the
# repo does not have (a watermark from another clone) leaves the count unknown
# rather than guessed.
if ($publishState -eq 'ok' -and $publishCommit) {
    try {
        & git -C $Repo cat-file -e "$publishCommit^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $n = (& git -C $Repo rev-list --count "$publishCommit..HEAD" 2>$null)
            if ($LASTEXITCODE -eq 0 -and "$n" -match '^\d+$') {
                $publishBehind = [int]$n
                if ($publishBehind -gt 0) { $publishState = "ok+$publishBehind" }
            }
        }
    } catch { $publishBehind = $null }
}

# A pending request is the loop being ASKED to ship and not having shipped.
try {
    if (Test-Path -LiteralPath $PublishRequest) {
        $rqText = [IO.File]::ReadAllText($PublishRequest).Trim()
        if ($rqText) {
            if ($rqText.StartsWith('{')) {
                $rq = $rqText | ConvertFrom-Json
                $requestReason = [string]$rq.reason
                if ($rq.at) { try { $requestAgeHours = ((Get-Date) - [datetime]::Parse([string]$rq.at)).TotalHours } catch { $requestAgeHours = $null } }
            } else {
                $requestReason = ($rqText -split "`n")[0].Trim()
            }
            if (-not $requestReason) { $requestReason = '(no reason recorded)' }
        }
    }
} catch { $requestReason = '' }

# --- verdict ----------------------------------------------------------------

$alive = ($state -eq 'held')
$notes = @()
if (-not $alive) { $notes += "loop owner is $state" }
if ($alive -and $marked -eq 0) { $notes += 'no [go-loop]-marked window' }
if ($alive -and $marked -gt 1) { $notes += "$marked marked windows (duplicate loops)" }
if ($alive -and $ageMin -gt $StaleMinutes) { $notes += "no activity for $([math]::Round($ageMin))m" }
# The progress gate (T1290). `age_minutes` above answers "did anything happen in
# that pane", which the watchdog's own nudge is enough to satisfy - so on
# 2026-09-03 the loop sat inert from 14:29 to 05:07 the next morning while this
# line read HEALTHY, six minutes after the nudge that had just refreshed the
# clock it was reading. A turn counter that has not advanced is the number that
# describes the thing being supervised, and it is the one that must decide.
$turnStalled = $false
if ($alive -and $turnAgeMin -gt $TurnStaleMinutes) {
    $turnStalled = $true
    $notes += ("no turn has completed for $(Format-Age $turnAgeMin) (turn $turn started " +
        "$(if ($turnStarted) { $turnStarted } else { 'before this field existed' })) - the pane may be " +
        'moving without the loop working; read it with `ghoztty +read --name=<pane>` before theorising ' +
        '(an API 529 sits there looking exactly like a live session)')
}
# HEALTH AND THE WATCHDOG MUST NOT DISAGREE (user, 2026-09-06).
#
# The 180m backstop above was this line's only turn arm, so twice in one
# morning the watchdog logged STALLED(by=composer) over a composer holding
# unsent text while this line, six feet away, printed HEALTHY - once for 76
# minutes with the turn's work uncommitted. Two supervisors reading the same
# pane and reaching opposite verdicts is worse than either being wrong alone:
# the controller checks THIS one, and it said everything was fine.
#
# So ask the same question through the same function the watchdog uses, rather
# than growing a second opinion here. `Resolve-LoopStallVerdict` carries all
# three arms (180m backstop, suspect+composer, suspect+idle) and is unit
# tested; only the backstop is re-stated above, with its own richer note.
if (-not $turnStalled -and $alive -and -not $NoPaneProbe -and $pane -and
    $turnAgeMin -gt $TurnSuspectMinutes) {
    # A probe that THROWS must not read as a quiet pass. The first cut called
    # Resolve-GhozttyCliExe with no -Exe; PowerShell wrote two red blocks to
    # stderr, the arm was skipped, and the line still printed HEALTHY - a
    # broken supervisor reporting health, which is the failure this whole block
    # exists to end. So the probe is wrapped, and being unable to look is
    # itself a note.
    $paneState = $null
    try {
        . (Join-Path $PSScriptRoot 'go-loop-pane-probe.ps1')
        $paneState = Read-PaneState -PaneId $pane `
            -GhozttyExe (Resolve-GhozttyCliExe -Exe $GhozttyExe)
    } catch {
        $notes += ("the pane probe failed after $(Format-Age $turnAgeMin) of quiet turn, " +
            "so the composer and idle arms could not be asked: $($_.Exception.Message)")
    }
    $verdict = if ($paneState) {
        Resolve-LoopStallVerdict -TurnAgeMinutes $turnAgeMin `
            -StaleMinutes $TurnStaleMinutes -SuspectMinutes $TurnSuspectMinutes `
            -ComposerText ([string]$paneState.Composer) `
            -PaneState $(if ($paneState.Working) { [string]$paneState.Working } else { 'unknown' })
    } else { @{ Stalled = $false; Clock = 'none'; Why = '' } }
    # T1370's lesson, re-learned here: "the composer looked empty" and "the
    # composer was never read" must never be the same line. Read-PaneState
    # answers a failed probe with a BLIND record rather than an exception, so
    # without this a ghoztty that cannot be reached reads as a quiet, healthy
    # pane - measured with -GhozttyExe pointed at a path that does not exist,
    # which printed HEALTHY.
    if ($paneState -and [string]$paneState.Working -eq 'unknown') {
        $notes += ("the pane could not be read after $(Format-Age $turnAgeMin) of quiet turn, " +
            'so a wedged composer would be invisible here - check the pane by hand with ' +
            '`ghoztty +read --name=<pane>`')
    }
    if ($verdict.Stalled) {
        $turnStalled = $true
        $notes += ("stalled(by=$($verdict.Clock)): $($verdict.Why) - the watchdog " +
            'sees this too and will nudge; if it keeps recurring, the turn is ending ' +
            'without submitting its own continuation, which is a go.md step 7 failure')
    }
}
if (-not $watchdog) { $notes += 'watchdog is not running' }
if (-not $dashboard) { $notes += "dashboard is not listening on $Port" }
if ($inProgress.Count -gt 1) { $notes += "$($inProgress.Count) tasks claimed in-progress" }
if ($digestState -eq 'missing') {
    $notes += "today's digest is missing - go.md step 0.5, write $digestRel (never backfill an older day)"
}
if ($publishState -eq 'never') {
    $notes += 'nothing has ever been published from this box - go.md step 6.5, scripts\daily-publish.ps1 -Check says whether one is due'
} elseif ($publishState -eq 'failed') {
    $notes += ("the last publish did not land: $(if ($publishTag) { $publishTag } else { $publishDate }) was tagged and no release exists - " +
        'check the Release (Windows) run for that tag; once a fix has landed, the next task-boundary run of ' +
        'scripts\daily-publish.ps1 retries on its own (T1369)')
} elseif ($publishState -like 'stale-*') {
    $notes += "nothing has shipped since $publishDate ($publishState) - the work that has landed since is not on the user's machine"
}
if ($requestReason -and ($null -eq $requestAgeHours -or $requestAgeHours -ge $RequestStaleHours)) {
    $notes += ("a publish was requested and has not gone out" +
        $(if ($null -ne $requestAgeHours) { " ($([math]::Round($requestAgeHours))h ago)" } else { '' }) +
        ": $requestReason - the next task-boundary run of scripts\daily-publish.ps1 ships it")
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
        # A loop parked on purpose is not turning BY DESIGN, so the progress
        # note is dropped here with the other two: nothing is wrong.
        ($notes | Where-Object { $_ -notmatch '^loop owner is |^watchdog is not running$|^no turn has completed ' })
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
        turn_started     = $turnStarted
        turn_age_minutes = if ([double]::IsInfinity($turnAgeMin)) { $null } else { $turnAgeMin }
        turn_stalled     = $turnStalled
        marked_windows = $marked
        watchdog       = $watchdog
        dashboard      = $dashboard
        in_progress    = $inProgress
        open_decisions = $openDecisions
        digest         = $digestState
        digest_path    = $digestRel
        publish        = $publishState
        publish_tag    = $publishTag
        publish_date   = $publishDate
        publish_commit = $publishCommit
        publish_behind = $publishBehind
        publish_request = $requestReason
        stopped        = [bool]$stopReq
        notes          = $notes
    } | ConvertTo-Json -Depth 4
} else {
    $task = if ($inProgress.Count) { $inProgress -join ',' } else { 'none' }
    "$(Now-Iso) $($verdict.ToUpper()) uptime=$uptime turn=$turn turn_age=$(Format-Age $turnAgeMin) state=$state pane=$pane pid=$loopPid " +
    "task=$task decisions_open=$openDecisions digest=$digestState publish=$publishState windows=$marked watchdog=$watchdog dashboard=$dashboard"
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
    '=== the loop pane, last 30 lines (T1290) ==='
    # Three stalls running were theorised about from the ledger when the answer
    # was one command away in the pane: "API Error: 529 Overloaded" reads as a
    # perfectly live session to every other probe here.
    if ($pane) {
        $exe = "$env:LOCALAPPDATA\Programs\Ghoztty\ghoztty.exe"
        if (Test-Path -LiteralPath $exe) {
            try { (& $exe +read "--name=$pane" '--lines=30' 2>&1 | ForEach-Object { $_.ToString() }) } catch { "(read failed: $_)" }
        } else { "(no ghoztty.exe at $exe)" }
    } else { '(no pane recorded on the lock)' }
    ''
    '=== ghoztty / agent process ages (a restart kills the loop AND the tracker) ==='
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe' OR Name='ghoztty-agent.exe'" |
        Select-Object ProcessId, Name, CreationDate, ExecutablePath | Format-Table -AutoSize | Out-String
    '=== claude processes ==='
    Get-Process claude -ErrorAction SilentlyContinue |
        Select-Object Id, StartTime | Sort-Object StartTime | Format-Table -AutoSize | Out-String
}

exit $code
