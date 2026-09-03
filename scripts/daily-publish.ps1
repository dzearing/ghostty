# The end-of-day Windows publish (tracker T1220).
#
# THE PROBLEM. Decision D85 (2026-08-31) settled who owns the user's terminal:
# "the terminal should only ever run something that was actually published".
# T1218 then removed the morning swap that used to push repo bits straight into
# the installed app. That was the right call and it came with a promise: the
# loop PUBLISHES at the end of a day's work, so today's fixes still reach the
# user today, through the ordinary in-app updater. Without this script that
# promise is a sentence in a task file: the work lands on the branch and sits
# there until somebody types a publish command by hand.
#
# THE TRIGGER is the same shape as the retired morning refresh's, moved to the
# other end of the day: a real signal (the loop's task-boundary push) rather
# than a clock alone, at most once per local day, with a durable watermark. A
# clock alone would fire into whatever half-finished tree happened to be checked
# out; a task-boundary push is the loop saying "this commit is good". The hour
# is the EVENING (17:00 local by default) rather than the morning, because the
# point is that a fix which landed today ships today - a morning publish would
# always be shipping yesterday.
#
# AND A CATCH-UP RULE, because the evening hour assumes a workday this loop does
# not have (T1292). On 2026-09-02 the loop's last push was at 14:28 and it then
# stalled: 17:00 never arrived while anything was running, so the day published
# nothing and said nothing. A wall-clock gate inside a process with no schedule
# is a coin flip. So a publish is ALSO due at the first task-boundary push once
# -StaleHours (24 by default) have passed since the last one, whatever the hour.
# The evening rule still shapes a normal day; the catch-up rule is what makes
# "work ships within a day" true rather than aspirational, and it is what fires
# on the morning after a day that died early.
#
# WHAT IT DOES, once a day: run scripts\publish-windows-tag.ps1, which puts the
# win-v<Version> tag on HEAD and pushes it to origin. The Release (Windows)
# workflow then builds the MSI + portable ZIP on ubuntu-latest and creates the
# release. The installed terminal's update check scans for the newest win-v tag,
# so that release IS the delivery.
#
# WHY A TAG PUSH AND NOT A LOCAL BUILD (T1292). Until 2026-09-03 this ran
# scripts\publish-windows-release.ps1, which packages the MSI with wixl inside
# the msitools Docker image. wixl does not run on Windows, so that path requires
# Docker Desktop - and Docker Desktop is deliberately kept down on this box (its
# WSL2 backend once took 28 GB and buried the machine), which is exactly why
# every script here says starting it is the user's call. The result was a
# publish that asked every evening for a precondition it was structurally
# forbidden to satisfy: it wrote a polite SKIP into a temp log and shipped
# nothing, for three days, while nineteen tasks closed. A step whose failure mode
# is "nothing happens" is the worst kind, so the dependency is gone rather than
# excused. -Local reinstates the old path for a box that genuinely wants to
# package locally.
#
# WHAT IT NEVER DOES: touch the installed app. See scripts\install-ownership.ps1
# and decision D85. Publishing is the only delivery path this repo has.
#
# SKIPS ARE NOT FAILURES. What a publish needs that this loop cannot arrange is
# now down to one thing: HEAD must already be on the remote (it always is, since
# the commit guard pushes). Under -Local the old pair comes back - Docker
# Desktop up, `gh` authenticated. A missing precondition is a SKIP with the
# reason named in the log, the watermark is NOT consumed (so a later push the
# same day can still publish), and the loop carries on. The one thing that must
# never happen is a publish attempt stalling the turn.
#
# A SKIP IS ALSO NOT INVISIBLE ANY MORE. `publish=` on
# scripts\go-loop-health.ps1 reads the watermark and reports ok / due /
# stale-<n>d / failed / never, and degrades the run when nothing has shipped for
# a day. That is the same shape as `digest=` (T1223) and it exists for the same
# reason: the three-day outage had to be noticed by the user.
#
# HOW THE CALLER USES IT (go.md step 6.5):
#
#   powershell -NoProfile -File scripts\daily-publish.ps1
#
#   exit 0  -> not due, or skipped with a named reason. Finish the turn.
#   exit 10 -> published (tag printed). Finish the turn.
#   exit 1  -> it was due and the publish failed. Nothing was released; finish
#              the turn normally so a bad publish cannot stall the loop.
#
# VERSION SCHEME (the thing this script decides, so nobody has to remember it).
# A Windows release is `win-v<X.Y.Z>`; the Mac releases are `v<X.Y.Z>` in the
# same repo. The daily publish takes the Mac line as its base and walks the
# PATCH:
#
#   base = the newest vX.Y.Z Mac release tag
#   if there is no win-v release at or above `base` -> publish base itself
#   otherwise -> publish the newest win-v version with its patch + 1
#
# So a Mac v1.37.0 is followed by win-v1.37.0, then win-v1.37.1, win-v1.37.2 ...
# one per publishing day, until the next Mac release pulls the base up again.
# The consequences that matter: the version the user sees says which Mac line
# their Windows build corresponds to; the daily walk never squats on a Mac minor
# the Mac seat has not released yet; MSI upgrade ordering stays monotonic; and
# the chosen version can never collide with an existing release, because it is
# derived from the set of releases that exist. `publish-windows-release.ps1`
# refuses an existing tag as a second line of defence.
#
# WATERMARK. %LOCALAPPDATA%\ghoztty\daily-publish, one JSON object recording the
# local date, the instant, the tag, the commit and the outcome of the last
# publish. The date is what the due decision reads; the instant is what the
# catch-up rule measures; the rest is what the morning digest and the health
# line read to answer "is what I am running the work I read about yesterday?". A
# plain yyyy-MM-dd line is still accepted, so an older watermark is not a reason
# to publish twice, and a watermark with no `at` falls back to its date at the
# cutoff hour.
#
# THE TAG IS NOT THE RELEASE, so the watermark records `tagged` and the NEXT run
# confirms it. CI builds for ten minutes after the push, and a run that goes red
# leaves a tag with no release behind it - which used to be indistinguishable
# from a successful publish. Every invocation re-checks a `tagged` watermark
# against `gh release view` and rewrites it to `published` or `failed`, so the
# health line tells the truth about what actually shipped rather than about what
# was attempted.
#
# Acceptance: test\win32\daily-publish.ps1
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$WatermarkPath = (Join-Path $env:LOCALAPPDATA 'ghoztty\daily-publish'),
    # Local hour on/after which a task-boundary push counts as "end of the day's
    # work". 17, so the day's fixes are published while the day is still today.
    [int]$HourLocal = 17,
    # The catch-up rule: however early in the day it is, a publish is due once
    # this many hours have passed since the last one. 24, so a day whose loop
    # stalled before the evening ships its work the next morning instead of
    # never. 0 disables it and restores the pure evening gate.
    [int]$StaleHours = 24,
    # Test seam. Empty = now.
    [string]$Now = '',
    # Decide and print, change nothing, publish nothing.
    [switch]$Check,
    # Ignore the watermark (still stamps it). For a deliberate second publish.
    [switch]$Force,
    # Test seam: go as far as the publish and report what WOULD have run.
    [switch]$NoPublish,
    # Passed through to the publish script (everything but the release itself).
    # Still stamps, so a dry run consumes the day deliberately.
    [switch]$DryRun,
    # Publish by building and packaging on this box (the pre-T1292 path):
    # scripts\publish-windows-release.ps1, which needs Docker Desktop up and gh
    # authenticated. The default is the tag push, which needs neither.
    [switch]$Local,
    # Empty = publish-windows-tag.ps1, or publish-windows-release.ps1 under
    # -Local.
    [string]$PublishScript = ''
)

$ErrorActionPreference = 'Continue'

# ---- the decisions, pure -------------------------------------------------
#
# Separated from every side effect so the acceptance test can drive each arm
# without a clock, a watermark file, Docker, GitHub, or a ten-minute build.

function Test-DailyPublishDue {
    param(
        [Parameter(Mandatory)][datetime]$Now,
        # The watermark's date, or '' / $null when there is no watermark.
        [string]$LastDate = '',
        # The watermark's instant, for the catch-up rule. Empty falls back to
        # LastDate at the cutoff hour, which is when an old-format watermark's
        # publish would have happened.
        [string]$LastAt = '',
        [int]$HourLocal = 17,
        [int]$StaleHours = 24,
        [switch]$Force
    )
    $today = $Now.ToString('yyyy-MM-dd')
    $last = if ($LastDate) { $LastDate.Trim() } else { '' }
    if ($Force) {
        return [pscustomobject]@{ Due = $true; Today = $today; Why = "forced (last=$(if ($last) { $last } else { 'never' }))" }
    }
    # Ordered before the hour check on purpose: one publish per local day is the
    # invariant BOTH rules below sit under, so neither can double-publish.
    if ($last -eq $today) {
        return [pscustomobject]@{ Due = $false; Today = $today; Why = "already published today ($today)" }
    }
    if ($Now.Hour -lt $HourLocal) {
        # The evening rule has not fired. The catch-up rule (T1292) is what keeps
        # a day that stalled before 17:00 from shipping nothing at all: measure
        # from the last publish, not from the clock.
        if ($StaleHours -le 0) {
            return [pscustomobject]@{ Due = $false; Today = $today; Why = "before ${HourLocal}:00 local (it is $($Now.ToString('HH:mm'))) - the day's work is not done yet" }
        }
        $lastInstant = $null
        if ($LastAt) { try { $lastInstant = [datetime]::Parse($LastAt) } catch { $lastInstant = $null } }
        if ($null -eq $lastInstant -and $last -match '^\d{4}-\d{2}-\d{2}$') {
            try { $lastInstant = ([datetime]::ParseExact($last, 'yyyy-MM-dd', $null)).AddHours($HourLocal) } catch { $lastInstant = $null }
        }
        if ($null -eq $lastInstant) {
            return [pscustomobject]@{ Due = $true; Today = $today; Why = "nothing has ever been published - not waiting for ${HourLocal}:00 to ship the first one" }
        }
        $hours = ($Now - $lastInstant).TotalHours
        if ($hours -ge $StaleHours) {
            return [pscustomobject]@{
                Due   = $true
                Today = $today
                Why   = "catch-up: $([math]::Round($hours))h since the last publish ($last) and it is only $($Now.ToString('HH:mm')) - a day that stalled before ${HourLocal}:00 still ships"
            }
        }
        return [pscustomobject]@{ Due = $false; Today = $today; Why = "before ${HourLocal}:00 local (it is $($Now.ToString('HH:mm'))) - the day's work is not done yet, and the last publish was only $([math]::Round($hours))h ago" }
    }
    # A watermark from the FUTURE is not a reason to refuse forever (a clock
    # change, a restored profile). It is also not today, so it does not block.
    return [pscustomobject]@{
        Due   = $true
        Today = $today
        Why   = "first task-boundary push at/after ${HourLocal}:00 today (last publish: $(if ($last) { $last } else { 'never' }))"
    }
}

# The version scheme, from the set of release tags that exist. See the header.
# Accepts bare tags in either form ('v1.34.0', 'win-v1.36.0'); anything else is
# ignored, so a `gh release list` line or a stray tag cannot skew the answer.
function Resolve-DailyPublishVersion {
    param([string[]]$Tags = @())

    function ToVer([string]$text) {
        if ($text -notmatch '^(\d+)\.(\d+)\.(\d+)$') { return $null }
        return [pscustomobject]@{
            Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3]
            Text  = $text
        }
    }
    function Cmp($a, $b) {
        if ($a.Major -ne $b.Major) { return $a.Major - $b.Major }
        if ($a.Minor -ne $b.Minor) { return $a.Minor - $b.Minor }
        return $a.Patch - $b.Patch
    }
    function Newest($list) {
        $best = $null
        foreach ($v in $list) { if ($null -eq $best -or (Cmp $v $best) -gt 0) { $best = $v } }
        return $best
    }

    $mac = @(); $win = @()
    foreach ($t in $Tags) {
        if ($null -eq $t) { continue }
        $t = $t.Trim()
        if ($t -like 'win-v*') { $v = ToVer ($t.Substring(5)); if ($v) { $win += $v } }
        elseif ($t -like 'v*') { $v = ToVer ($t.Substring(1)); if ($v) { $mac += $v } }
    }
    $macNewest = Newest $mac
    $winNewest = Newest $win

    if ($null -eq $macNewest -and $null -eq $winNewest) {
        return [pscustomobject]@{ Version = ''; Why = 'no vX.Y.Z or win-vX.Y.Z release tag found - pass -Version to publish-windows-release.ps1 by hand' }
    }
    if ($null -eq $winNewest) {
        return [pscustomobject]@{ Version = $macNewest.Text; Why = "first Windows release for the Mac line v$($macNewest.Text)" }
    }
    if ($null -ne $macNewest -and (Cmp $macNewest $winNewest) -gt 0) {
        return [pscustomobject]@{ Version = $macNewest.Text; Why = "the Mac line moved to v$($macNewest.Text) (newest Windows release is win-v$($winNewest.Text))" }
    }
    $next = "$($winNewest.Major).$($winNewest.Minor).$($winNewest.Patch + 1)"
    return [pscustomobject]@{ Version = $next; Why = "daily patch walk on win-v$($winNewest.Text)" }
}

# What a publish needs before it is worth starting. In the default TAG mode that
# is one thing, and it is one the loop arranges for itself: the commit being
# released must already be on the remote, because CI builds the tag. Docker and
# gh are preconditions of the -Local packaging path ONLY - keeping them in the
# default set is what made this script structurally unable to ship (T1292).
function Test-PublishPreconditions {
    param(
        [bool]$DockerUp,
        [bool]$GhAuthenticated,
        [bool]$HeadPushed,
        # 'tag' (CI builds the pushed tag) or 'local' (this box packages).
        [string]$Mode = 'tag'
    )
    $missing = @()
    if ($Mode -eq 'local') {
        if (-not $DockerUp) { $missing += 'Docker Desktop is not running (wixl packages the MSI inside the msitools image, and starting Docker is the user''s call)' }
        if (-not $GhAuthenticated) { $missing += 'gh is not authenticated (`gh auth login`) - the release cannot be created' }
    }
    if (-not $HeadPushed) { $missing += 'HEAD is not on any remote branch - the release tag must point at a pushed commit' }
    return [pscustomobject]@{
        Ok     = ($missing.Count -eq 0)
        Reason = ($missing -join '; ')
    }
}

# Read a watermark that may be this script's JSON or the older single date line.
function Read-PublishWatermark {
    param([string]$Text = '')
    $empty = [pscustomobject]@{ Date = ''; At = ''; Tag = ''; Commit = ''; Result = '' }
    if (-not $Text) { return $empty }
    $t = $Text.Trim()
    if ($t.StartsWith('{')) {
        try {
            $o = $t | ConvertFrom-Json
            return [pscustomobject]@{
                Date   = [string]$o.date
                At     = [string]$o.at
                Tag    = [string]$o.tag
                Commit = [string]$o.commit
                Result = [string]$o.result
            }
        } catch { return $empty }
    }
    $first = ($t -split "`n")[0].Trim()
    if ($first -match '^\d{4}-\d{2}-\d{2}$') { return [pscustomobject]@{ Date = $first; At = ''; Tag = ''; Commit = ''; Result = '' } }
    return $empty
}

# Dot-sourced by the acceptance test for the functions above; running it that
# way must publish nothing.
if ($env:GHOZTTY_DAILY_PUBLISH_DOTSOURCE -eq '1') { return }

# ---- side effects --------------------------------------------------------

$mode = if ($Local) { 'local' } else { 'tag' }
if (-not $PublishScript) {
    $PublishScript = Join-Path $PSScriptRoot $(if ($Local) { 'publish-windows-release.ps1' } else { 'publish-windows-tag.ps1' })
}

$log = Join-Path $env:TEMP 'ghoztty-daily-publish.log'
function Log($m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    $line | Add-Content $log
    Write-Host $line
}

# Probe natives that talk on stderr without letting PS 5.1 turn their stderr
# into a terminating error.
function Invoke-Probe([scriptblock]$block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { & $block *> $null } finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}

# Rewrite an existing watermark with a new outcome, keeping everything else it
# recorded. Used by the confirmation pass above: the day, the tag and the commit
# are history, only the verdict moves.
function Write-Confirmed-Watermark {
    param([string]$Path, $Mark, [string]$Result)
    try {
        $json = [ordered]@{
            date   = $Mark.Date
            at     = $Mark.At
            tag    = $Mark.Tag
            commit = $Mark.Commit
            result = $Result
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($Path, "$json`n", (New-Object Text.UTF8Encoding($false)))
    } catch {
        Log "WARNING: could not update the watermark $Path ($($_.Exception.Message))"
    }
}

Set-Location $Repo

# NOT `$now`: PowerShell variable names are case-insensitive, so that is the
# [string]$Now parameter, and assigning a DateTime to it converts straight back
# to a string. Every consumer that wanted a real DateTime then had to be lucky.
$nowDt = if ($Now) { [datetime]::Parse($Now) } else { Get-Date }
$mark = Read-PublishWatermark -Text $(
    if (Test-Path -LiteralPath $WatermarkPath) { try { [IO.File]::ReadAllText($WatermarkPath) } catch { '' } } else { '' }
)

# Confirm a tag from an earlier run actually became a release before deciding
# anything else. A pushed tag is a promise CI keeps ten minutes later, or does
# not: without this, a red release run reads exactly like a good publish for the
# rest of the day and the health line says `ok` about a release that does not
# exist. Cheap, and only when there is something to confirm.
if ($mark.Result -eq 'tagged' -and $mark.Tag) {
    $seen = (Invoke-Probe { gh release view $mark.Tag --repo dzearing/ghoztty --json tagName })
    if ($seen -eq 0) {
        $mark.Result = 'published'
        Write-Confirmed-Watermark -Path $WatermarkPath -Mark $mark -Result 'published'
        Log "CONFIRMED $($mark.Tag) is published."
    } elseif ((Invoke-Probe { gh auth status }) -eq 0) {
        # gh works and still cannot see the release. Give CI an hour before
        # calling it dead: the tag is normally pushed minutes before this runs.
        $tagAge = 999.0
        if ($mark.At) { try { $tagAge = ((Get-Date) - [datetime]::Parse($mark.At)).TotalHours } catch { } }
        if ($tagAge -ge 1) {
            $mark.Result = 'failed'
            Write-Confirmed-Watermark -Path $WatermarkPath -Mark $mark -Result 'failed'
            Log "PUBLISH DID NOT LAND: $($mark.Tag) was pushed $([math]::Round($tagAge))h ago and there is still no release. Check the Release (Windows) run for that tag."
        }
    }
}

$d = Test-DailyPublishDue -Now $nowDt -LastDate $mark.Date -LastAt $mark.At -HourLocal $HourLocal -StaleHours $StaleHours -Force:$Force
if (-not $d.Due) {
    Log "NOT DUE: $($d.Why)"
    exit 0
}

# Preconditions BEFORE the watermark. A skip must not consume the day: Docker
# coming up an hour later should still get the work published tonight.
$dockerUp = (Invoke-Probe { docker info }) -eq 0
$ghOk = (Invoke-Probe { gh auth status }) -eq 0
$headPushed = $false
try { $headPushed = [bool](@(git branch -r --contains HEAD 2>$null).Count) } catch { $headPushed = $false }

$pre = Test-PublishPreconditions -DockerUp $dockerUp -GhAuthenticated $ghOk -HeadPushed $headPushed -Mode $mode
if (-not $pre.Ok) {
    Log "SKIP: due ($($d.Why)) but $($pre.Reason). Nothing published; the watermark is untouched, so a later push today can still publish."
    exit 0
}

# The version, from the releases that exist. gh is the authority (that is where
# a collision would live); local tags are unioned in so a missing fetch cannot
# make the walk restart at an already-published number.
$tags = @()
$ghOut = & gh release list --repo dzearing/ghoztty --limit 100 2>$null
if ($LASTEXITCODE -eq 0) {
    foreach ($line in @($ghOut)) {
        foreach ($field in ($line -split "`t")) {
            $f = $field.Trim()
            if ($f -match '^(win-)?v\d+\.\d+\.\d+$') { $tags += $f }
        }
    }
}
$tags += @(git tag --list 'v[0-9]*.[0-9]*.[0-9]*')
$tags += @(git tag --list 'win-v[0-9]*.[0-9]*.[0-9]*')

$v = Resolve-DailyPublishVersion -Tags $tags
if (-not $v.Version) {
    Log "SKIP: due ($($d.Why)) but $($v.Why)"
    exit 0
}
$hash = (git rev-parse --short HEAD).Trim()
Log "DUE: $($d.Why); publishing win-v$($v.Version) at $hash ($($v.Why))"

if ($Check) {
    Log 'CHECK ONLY: not stamping, not publishing'
    exit 10
}

# Stamp before the publish, the way the morning refresh did: a publish that
# fails and re-fires on every task-boundary push would spend the rest of the
# evening running ten-minute ReleaseFast builds. One attempt per day. A SKIP
# above never gets here, so an absent precondition costs nothing.
function Stamp([string]$result, [string]$tag) {
    try {
        $dir = Split-Path -Parent $WatermarkPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = [ordered]@{
            date   = $d.Today
            at     = $nowDt.ToString('yyyy-MM-ddTHH:mm:ssK')
            tag    = $tag
            commit = $hash
            result = $result
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($WatermarkPath, "$json`n", (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch {
        Log "WARNING: could not stamp the watermark $WatermarkPath ($($_.Exception.Message))"
        return $false
    }
}

if (-not (Stamp 'attempting' "win-v$($v.Version)")) {
    Log 'refusing to publish, because an unstamped publish would re-fire on the next push'
    exit 1
}

if ($NoPublish) {
    Log "NO-PUBLISH: would have run $PublishScript -Version $($v.Version)"
    Stamp 'no-publish' "win-v$($v.Version)" | Out-Null
    exit 10
}

if (-not (Test-Path -LiteralPath $PublishScript -PathType Leaf)) {
    Log "PUBLISH FAILED: $PublishScript not found"
    Stamp 'failed' "win-v$($v.Version)" | Out-Null
    exit 1
}

Log "running $PublishScript -Version $($v.Version)$(if ($DryRun) { ' -DryRun' })"
if ($DryRun) { & $PublishScript -Version $v.Version -DryRun } else { & $PublishScript -Version $v.Version }
$code = $LASTEXITCODE

if ($code -eq 0) {
    # 'tagged' rather than 'published' in tag mode: the release exists once CI
    # finishes, and the confirmation pass at the top of the next run is what
    # turns this into 'published' or 'failed'. Claiming 'published' here is the
    # exact lie this task existed to remove.
    $result = if ($DryRun) { 'dry-run' } elseif ($mode -eq 'tag') { 'tagged' } else { 'published' }
    Stamp $result "win-v$($v.Version)" | Out-Null
    if ($result -eq 'tagged') {
        Log "TAGGED win-v$($v.Version) ($hash). Release (Windows) builds it; the next run confirms the release exists."
    } else {
        Log "PUBLISHED win-v$($v.Version) ($hash). The installed terminal offers it at its next update check."
    }
    exit 10
}

Stamp 'failed' "win-v$($v.Version)" | Out-Null
Log "PUBLISH FAILED (exit $code): nothing was released. Finish the turn normally; the next publishing day tries again."
exit 1
