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
# WHAT IT DOES, once a day: run scripts\publish-windows-release.ps1, which
# builds the ReleaseFast staging prefix, packages the MSI + portable ZIP under
# the msitools Docker image and creates the win-v<Version> GitHub release. The
# installed terminal's update check scans for the newest win-v tag, so that
# publish IS the delivery.
#
# WHAT IT NEVER DOES: touch the installed app. See scripts\install-ownership.ps1
# and decision D85. Publishing is the only delivery path this repo has.
#
# SKIPS ARE NOT FAILURES. Two preconditions are outside this loop's gift:
# Docker Desktop must be up (wixl does not run on Windows) and `gh` must be
# authenticated. Neither is something a turn may go and fix - starting Docker in
# particular is the user's call, since its WSL2 backend has buried this box
# before. A missing precondition is a SKIP with the reason named in the log, the
# watermark is NOT consumed (so a later push the same day can still publish),
# and the loop carries on. The one thing that must never happen is a publish
# attempt stalling the turn.
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
# local date, the tag, the commit and the outcome of the last publish. The date
# is what the due decision reads; the rest is what the morning digest reads to
# answer "is what I am running the work I read about yesterday?". A plain
# yyyy-MM-dd line is still accepted, so an older watermark is not a reason to
# publish twice.
#
# Acceptance: test\win32\daily-publish.ps1
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$WatermarkPath = (Join-Path $env:LOCALAPPDATA 'ghoztty\daily-publish'),
    # Local hour on/after which a task-boundary push counts as "end of the day's
    # work". 17, so the day's fixes are published while the day is still today.
    [int]$HourLocal = 17,
    # Test seam. Empty = now.
    [string]$Now = '',
    # Decide and print, change nothing, publish nothing.
    [switch]$Check,
    # Ignore the watermark (still stamps it). For a deliberate second publish.
    [switch]$Force,
    # Test seam: go as far as the publish and report what WOULD have run.
    [switch]$NoPublish,
    # Passed through to publish-windows-release.ps1 (build + package, no
    # release). Still stamps, so a dry run consumes the day deliberately.
    [switch]$DryRun,
    # Empty = the sibling publish-windows-release.ps1.
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
        [int]$HourLocal = 17,
        [switch]$Force
    )
    $today = $Now.ToString('yyyy-MM-dd')
    $last = if ($LastDate) { $LastDate.Trim() } else { '' }
    if ($Force) {
        return [pscustomobject]@{ Due = $true; Today = $today; Why = "forced (last=$(if ($last) { $last } else { 'never' }))" }
    }
    if ($Now.Hour -lt $HourLocal) {
        return [pscustomobject]@{ Due = $false; Today = $today; Why = "before ${HourLocal}:00 local (it is $($Now.ToString('HH:mm'))) - the day's work is not done yet" }
    }
    if ($last -eq $today) {
        return [pscustomobject]@{ Due = $false; Today = $today; Why = "already published today ($today)" }
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

# The two things a publish needs that this loop cannot go and arrange, plus the
# one it can: the commit being released must already be on the remote.
function Test-PublishPreconditions {
    param(
        [bool]$DockerUp,
        [bool]$GhAuthenticated,
        [bool]$HeadPushed
    )
    $missing = @()
    if (-not $DockerUp) { $missing += 'Docker Desktop is not running (wixl packages the MSI inside the msitools image, and starting Docker is the user''s call)' }
    if (-not $GhAuthenticated) { $missing += 'gh is not authenticated (`gh auth login`) - the release cannot be created' }
    if (-not $HeadPushed) { $missing += 'HEAD is not on any remote branch - the release tag must point at a pushed commit' }
    return [pscustomobject]@{
        Ok     = ($missing.Count -eq 0)
        Reason = ($missing -join '; ')
    }
}

# Read a watermark that may be this script's JSON or the older single date line.
function Read-PublishWatermark {
    param([string]$Text = '')
    $empty = [pscustomobject]@{ Date = ''; Tag = ''; Commit = ''; Result = '' }
    if (-not $Text) { return $empty }
    $t = $Text.Trim()
    if ($t.StartsWith('{')) {
        try {
            $o = $t | ConvertFrom-Json
            return [pscustomobject]@{
                Date   = [string]$o.date
                Tag    = [string]$o.tag
                Commit = [string]$o.commit
                Result = [string]$o.result
            }
        } catch { return $empty }
    }
    $first = ($t -split "`n")[0].Trim()
    if ($first -match '^\d{4}-\d{2}-\d{2}$') { return [pscustomobject]@{ Date = $first; Tag = ''; Commit = ''; Result = '' } }
    return $empty
}

# Dot-sourced by the acceptance test for the functions above; running it that
# way must publish nothing.
if ($env:GHOZTTY_DAILY_PUBLISH_DOTSOURCE -eq '1') { return }

# ---- side effects --------------------------------------------------------

if (-not $PublishScript) { $PublishScript = Join-Path $PSScriptRoot 'publish-windows-release.ps1' }

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

Set-Location $Repo

$now = if ($Now) { [datetime]::Parse($Now) } else { Get-Date }
$mark = Read-PublishWatermark -Text $(
    if (Test-Path -LiteralPath $WatermarkPath) { try { [IO.File]::ReadAllText($WatermarkPath) } catch { '' } } else { '' }
)

$d = Test-DailyPublishDue -Now $now -LastDate $mark.Date -HourLocal $HourLocal -Force:$Force
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

$pre = Test-PublishPreconditions -DockerUp $dockerUp -GhAuthenticated $ghOk -HeadPushed $headPushed
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
    Stamp $(if ($DryRun) { 'dry-run' } else { 'published' }) "win-v$($v.Version)" | Out-Null
    Log "PUBLISHED win-v$($v.Version) ($hash). The installed terminal offers it at its next update check."
    exit 10
}

Stamp 'failed' "win-v$($v.Version)" | Out-Null
Log "PUBLISH FAILED (exit $code): nothing was released. Finish the turn normally; the next publishing day tries again."
exit 1
