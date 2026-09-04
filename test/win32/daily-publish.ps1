# The end-of-day publish decides correctly, and refuses to publish when it
# cannot (T1220).
#
# WHAT THIS GUARDS. Since decision D85 the ONLY way this repo's work reaches the
# user's terminal is a published win-v release, and `scripts\daily-publish.ps1`
# is what makes that happen without anybody typing a command. Three things about
# it are silent when they rot:
#
#   - the DUE decision. Too eager and the loop spends its evening running
#     ten-minute ReleaseFast builds; too shy and the day's fixes never ship, and
#     the only symptom is a user who says "still broken" about a fix that landed
#     yesterday - which is exactly the failure T525 was filed for.
#   - the VERSION scheme. A version that collides with an existing release
#     fails loudly, but a version that quietly walks the wrong axis (squatting
#     on a Mac minor the Mac seat has not released) shows up weeks later.
#   - the SKIP paths. Docker down and `gh` unauthenticated must be skips with a
#     named reason that leave the watermark alone, never failures that stall the
#     turn and never silent no-ops.
#
# The old `morning-refresh.ps1` had a harness that covered exactly these three
# shapes for the swap it drove; it was retired with the swap (T1218). This is
# what covers the publish that replaced it.
#
# Sections:
#
#   A  the due decision, all arms, with no clock and no watermark file.
#   B  the version scheme, over injected release-tag sets.
#   C  the preconditions, each one named in the reason when it is missing.
#   D  the watermark reader: this script's JSON, the older bare date, garbage.
#   E  live -Check: decides out loud, stamps nothing, publishes nothing.
#   F  live SKIP paths: Docker down no longer stops the default publish (the
#      whole of T1292), and under -Local it is still a skip with the reason
#      named, exit 0, watermark untouched, publish script never invoked.
#   G  live -NoPublish: stamps the day and reports the tag it would publish.
#   H  a real publish run stamps `tagged`, not `published`: CI has not built the
#      tag yet, and claiming otherwise is what hid a three-day outage.
#   I  the tag publisher's refusals (bad version, a version already tagged) and
#      its dry-run happy path.
#   J  the on-demand request (T1294): it gets through the one-per-day rule, and
#      nothing else does.
#   K  the request reader, including the shapes that must NOT read as a request.
#   L  the 2026-09-03 shape end to end: publish at T, fix at T+90m, shipped the
#      same day - and the ordinary cadence unchanged around it.
#   M  -Status: what shipped, and what has landed since.
#
# Hermetic: a sandbox watermark under %TEMP%, a fake `docker`/`gh` on PATH, and
# a sentinel publish script that records if it was ever run. No Docker, no
# network, no build, nothing published.
#
#   powershell -NoProfile -File test\win32\daily-publish.ps1
#   powershell -NoProfile -File test\win32\daily-publish.ps1 -NegativeControl
param(
    [string]$Repo = 'D:\git\ghoztty',
    # Score every assertion inverted: the proof this harness can go red.
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($NegativeControl) { $cond = -not $cond }
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    Assert "$name (expected '$expected', got '$actual')" ($expected -eq $actual)
}
function AssertMatch($name, $pattern, $text) {
    Assert "$name (pattern '$pattern')" ([bool]($text -match $pattern))
}

$publishDecider = Join-Path $Repo 'scripts\daily-publish.ps1'
if (-not (Test-Path -LiteralPath $publishDecider -PathType Leaf)) {
    "FATAL: missing $publishDecider - the end-of-day publish this harness guards is gone"
    "1 FAILURE(S)"
    exit 1
}

$env:GHOZTTY_DAILY_PUBLISH_DOTSOURCE = '1'
try { . $publishDecider } finally { Remove-Item Env:\GHOZTTY_DAILY_PUBLISH_DOTSOURCE -ErrorAction SilentlyContinue }

# ---- A. the due decision -------------------------------------------------
"== A. due decision =="
$evening = [datetime]'2026-09-01T18:30:00'
$morning = [datetime]'2026-09-01T09:00:00'

# The catch-up rule (T1292) reads the last publish's INSTANT, so an ordinary
# morning push - yesterday evening's publish still recent - is the arm that has
# to stay quiet.
$a1 = Test-DailyPublishDue -Now $morning -LastDate '2026-08-31' -LastAt '2026-08-31T18:00:00' -HourLocal 17
Assert 'A1 a push before the cutoff hour is not due' (-not $a1.Due)
AssertMatch 'A1 and says why' 'the day''s work is not done yet' $a1.Why

$a2 = Test-DailyPublishDue -Now $evening -LastDate '' -HourLocal 17
Assert 'A2 the first push after the cutoff, never published, is due' $a2.Due
AssertEq 'A2 today is the local date' '2026-09-01' $a2.Today

$a3 = Test-DailyPublishDue -Now $evening -LastDate '2026-09-01' -HourLocal 17
Assert 'A3 a second push the same evening is not due' (-not $a3.Due)
AssertMatch 'A3 and says so' 'already published today' $a3.Why

$a4 = Test-DailyPublishDue -Now $evening -LastDate '2026-08-31' -HourLocal 17
Assert 'A4 yesterday''s watermark does not block today' $a4.Due

$a5 = Test-DailyPublishDue -Now $morning -LastDate '2026-08-20' -HourLocal 17 -Force
Assert 'A5 -Force overrides both the hour and the watermark' $a5.Due

$a6 = Test-DailyPublishDue -Now $evening -LastDate '2027-01-01' -HourLocal 17
Assert 'A6 a watermark from the future does not wedge the publish forever' $a6.Due

$a7 = Test-DailyPublishDue -Now ([datetime]'2026-09-01T17:00:00') -LastDate '' -HourLocal 17
Assert 'A7 the cutoff hour itself counts as due' $a7.Due

# ---- A8..A12. the catch-up rule (T1292) ----------------------------------
#
# 2026-09-02: the loop's last push was 14:28 and it then stalled, so 17:00 never
# arrived while anything was running and the day shipped nothing - silently. The
# evening hour assumes a workday this loop does not have. These arms are the
# rule that makes "work ships within a day" true rather than aspirational, and
# the FIRST one is the case that used to be missed.
$a8 = Test-DailyPublishDue -Now $morning -LastDate '2026-08-30' -LastAt '2026-08-30T18:00:00' -HourLocal 17
Assert 'A8 a morning push after a day that stalled before 17:00 IS due' $a8.Due
AssertMatch 'A8 and says it is catching up' 'catch-up' $a8.Why

$a9 = Test-DailyPublishDue -Now $morning -LastDate '' -HourLocal 17
Assert 'A9 nothing ever published does not wait for the evening' $a9.Due
AssertMatch 'A9 and says so' 'nothing has ever been published' $a9.Why

$a10 = Test-DailyPublishDue -Now $morning -LastDate '2026-09-01' -LastAt '2026-09-01T02:00:00' -HourLocal 17
Assert 'A10 the one-per-day rule still wins over the catch-up rule' (-not $a10.Due)
AssertMatch 'A10 and says which' 'already published today' $a10.Why

# An old bare-date watermark has no instant; the fallback is that date at the
# cutoff hour, so it ages into the catch-up rule the same way.
$a11 = Test-DailyPublishDue -Now $morning -LastDate '2026-08-25' -HourLocal 17
Assert 'A11 a bare-date watermark still ages into a catch-up publish' $a11.Due

$a12 = Test-DailyPublishDue -Now $morning -LastDate '2026-08-25' -HourLocal 17 -StaleHours 0
Assert 'A12 -StaleHours 0 restores the pure evening gate' (-not $a12.Due)

# ---- B. the version scheme ----------------------------------------------
"== B. version scheme =="
$b1 = Resolve-DailyPublishVersion -Tags @()
AssertEq 'B1 no tags at all yields no version' '' $b1.Version
AssertMatch 'B1 and names what to do instead' 'by hand' $b1.Why

$b2 = Resolve-DailyPublishVersion -Tags @('v1.34.0', 'v1.33.0')
AssertEq 'B2 a Mac line with no Windows release publishes that line' '1.34.0' $b2.Version

$b3 = Resolve-DailyPublishVersion -Tags @('v1.34.0', 'win-v1.34.0')
AssertEq 'B3 a Windows release already on the Mac line walks the patch' '1.34.1' $b3.Version

$b4 = Resolve-DailyPublishVersion -Tags @('v1.34.0', 'win-v1.34.0', 'win-v1.34.1', 'win-v1.34.2')
AssertEq 'B4 the walk continues from the NEWEST Windows release' '1.34.3' $b4.Version

$b5 = Resolve-DailyPublishVersion -Tags @('v1.37.0', 'win-v1.36.3')
AssertEq 'B5 a new Mac release pulls the base up instead of walking' '1.37.0' $b5.Version
AssertMatch 'B5 and says why' 'Mac line moved' $b5.Why

$b6 = Resolve-DailyPublishVersion -Tags @('v1.34.0', 'win-v1.36.0')
AssertEq 'B6 Windows ahead of the Mac line keeps walking its own patch' '1.36.1' $b6.Version

$b7 = Resolve-DailyPublishVersion -Tags @('v1.34.0', 'win-v1.34.0', 'nightly', 'v1.2', 'win-v', '', $null, 'v1.9.0-dev')
AssertEq 'B7 non-release tags are ignored rather than skewing the walk' '1.34.1' $b7.Version

$b8 = Resolve-DailyPublishVersion -Tags @('v1.9.0', 'v1.10.0', 'win-v1.9.0')
AssertEq 'B8 versions are compared numerically, not lexically' '1.10.0' $b8.Version

$b9 = Resolve-DailyPublishVersion -Tags @('win-v1.36.0')
AssertEq 'B9 Windows releases with no Mac tag still walk' '1.36.1' $b9.Version

# The property that matters most: whatever it picks is not already released.
$existing = @('v1.34.0', 'win-v1.34.0', 'win-v1.34.1', 'win-v1.35.0')
$bA = Resolve-DailyPublishVersion -Tags $existing
Assert 'B10 the chosen version is never one that already has a release' (
    $existing -notcontains "win-v$($bA.Version)" -and $existing -notcontains "v$($bA.Version)"
)

# ---- C. preconditions ----------------------------------------------------
#
# The -Local arm is the pre-T1292 packaging path and keeps the old pair. The
# default tag arm is the point of the task: Docker down must NOT be able to stop
# a publish, because Docker is deliberately down on this box and asking for it
# every evening is what shipped nothing for three days.
"== C. preconditions =="
$c1 = Test-PublishPreconditions -DockerUp $true -GhAuthenticated $true -HeadPushed $true -Mode 'local'
Assert 'C1 everything present is a go' $c1.Ok
AssertEq 'C1 with no reason to name' '' $c1.Reason

$c2 = Test-PublishPreconditions -DockerUp $false -GhAuthenticated $true -HeadPushed $true -Mode 'local'
Assert 'C2 Docker down blocks the LOCAL packaging publish' (-not $c2.Ok)
AssertMatch 'C2 and is named' 'Docker' $c2.Reason

$c3 = Test-PublishPreconditions -DockerUp $true -GhAuthenticated $false -HeadPushed $true -Mode 'local'
Assert 'C3 an unauthenticated gh blocks the local publish' (-not $c3.Ok)
AssertMatch 'C3 and is named' 'gh' $c3.Reason

$c4 = Test-PublishPreconditions -DockerUp $true -GhAuthenticated $true -HeadPushed $false -Mode 'local'
Assert 'C4 an unpushed HEAD blocks the publish' (-not $c4.Ok)
AssertMatch 'C4 and is named' 'remote branch' $c4.Reason

$c5 = Test-PublishPreconditions -DockerUp $false -GhAuthenticated $false -HeadPushed $false -Mode 'local'
Assert 'C5 every missing precondition is named, not just the first' (
    $c5.Reason -match 'Docker' -and $c5.Reason -match 'gh' -and $c5.Reason -match 'remote branch'
)

$c6 = Test-PublishPreconditions -DockerUp $false -GhAuthenticated $false -HeadPushed $true
Assert 'C6 in the default tag mode a down Docker cannot stop the publish (T1292)' $c6.Ok
AssertEq 'C6 and nothing is named as missing' '' $c6.Reason

$c7 = Test-PublishPreconditions -DockerUp $true -GhAuthenticated $true -HeadPushed $false
Assert 'C7 tag mode still refuses a commit the remote does not have' (-not $c7.Ok)
AssertMatch 'C7 and says which' 'remote branch' $c7.Reason

# ---- D. the watermark reader --------------------------------------------
"== D. watermark reader =="
$d1 = Read-PublishWatermark -Text '{"date":"2026-09-01","tag":"win-v1.36.1","commit":"abc1234","result":"published"}'
AssertEq 'D1 JSON date' '2026-09-01' $d1.Date
AssertEq 'D1 JSON tag' 'win-v1.36.1' $d1.Tag
AssertEq 'D1 JSON result' 'published' $d1.Result

$d1b = Read-PublishWatermark -Text '{"date":"2026-09-01","at":"2026-09-01T18:04:11-07:00","tag":"win-v1.36.1","commit":"abc1234","result":"tagged"}'
AssertEq 'D1b the instant the catch-up rule measures from' '2026-09-01T18:04:11-07:00' $d1b.At
AssertEq 'D1b and the unconfirmed outcome a pushed tag starts at' 'tagged' $d1b.Result

$d2 = Read-PublishWatermark -Text "2026-08-31`n"
AssertEq 'D2 an older bare-date watermark still blocks a second publish' '2026-08-31' $d2.Date
AssertEq 'D2 and carries no instant, so the date-at-cutoff fallback is used' '' $d2.At

$d3 = Read-PublishWatermark -Text 'not a watermark'
AssertEq 'D3 garbage reads as never published' '' $d3.Date

$d4 = Read-PublishWatermark -Text ''
AssertEq 'D4 an empty watermark reads as never published' '' $d4.Date

$d5 = Read-PublishWatermark -Text '{ this is not json'
AssertEq 'D5 truncated JSON reads as never published rather than throwing' '' $d5.Date

# ---- J. the on-demand request (T1294) ------------------------------------
#
# The 2026-09-03 shape, as a decision: the day has published, the fix the user
# is waiting on lands ninety minutes later, and the old rule answered "already
# published today" until tomorrow. J1 is that exact input.
"== J. on-demand request =="
$publishedAt = [datetime]'2026-09-03T09:28:00'
$fixLanded = $publishedAt.AddMinutes(90)

$j0 = Test-DailyPublishDue -Now $fixLanded -LastDate '2026-09-03' -LastAt '2026-09-03T09:28:00' -HourLocal 17 `
    -HeadCommit '65da707' -LastCommit 'aaa1111'
Assert 'J0 without a request, a fix landing after the day''s publish still waits' (-not $j0.Due)

$j1 = Test-DailyPublishDue -Now $fixLanded -LastDate '2026-09-03' -LastAt '2026-09-03T09:28:00' -HourLocal 17 `
    -Requested -RequestReason 'T1291: the installer dies silently on a same-version install' `
    -HeadCommit '65da707' -LastCommit 'aaa1111'
Assert 'J1 a requested publish ships the same day, past the one-per-day rule' $j1.Due
AssertMatch 'J1 and quotes who is waiting' 'T1291' $j1.Why

# The noise guard: the request is the ONLY thing that gets through the date, and
# a turn that files none is unchanged in every arm.
$j2 = Test-DailyPublishDue -Now ([datetime]'2026-09-03T18:30:00') -LastDate '2026-09-03' -LastAt '2026-09-03T09:28:00' -HourLocal 17
Assert 'J2 an ordinary evening push after today''s publish is still one-a-day' (-not $j2.Due)
AssertMatch 'J2 and now says how to ask for a second one' '-Request' $j2.Why

# "Ship it" must never be able to mint an empty release.
$j3 = Test-DailyPublishDue -Now $fixLanded -LastDate '2026-09-03' -LastAt '2026-09-03T09:28:00' -HourLocal 17 `
    -Requested -RequestReason 'nothing actually landed' -HeadCommit 'aaa1111' -LastCommit 'aaa1111'
Assert 'J3 a request with nothing behind it is not due' (-not $j3.Due)
Assert 'J3 and asks for the request to be cleared rather than left to re-fire' $j3.ClearRequest
AssertMatch 'J3 saying why' 'nothing has landed since' $j3.Why

# A request from before the day's own publish must not re-fire afterwards: the
# publish consumes it, and if the file survives, the commit check is the backstop.
$j4 = Test-DailyPublishDue -Now $fixLanded -LastDate '' -HourLocal 17 -Requested -RequestReason 'first ever'
Assert 'J4 a request with no watermark at all publishes' $j4.Due

$j5 = Test-DailyPublishDue -Now ([datetime]'2026-09-03T09:00:00') -LastDate '2026-09-03' -LastAt '2026-09-03T08:00:00' -HourLocal 17 `
    -Requested -RequestReason 'morning ask' -HeadCommit 'bbb2222' -LastCommit 'aaa1111'
Assert 'J5 the request does not wait for the evening hour either' $j5.Due

# ---- K. the request reader ----------------------------------------------
"== K. request reader =="
$k1 = Read-PublishRequest -Text '{"at":"2026-09-03T11:05:00-07:00","reason":"T1291 installer","commit":"65da707"}'
Assert 'K1 a JSON request reads as pending' $k1.Requested
AssertEq 'K1 with its reason' 'T1291 installer' $k1.Reason
AssertEq 'K1 and the commit it was filed at' '65da707' $k1.Commit

$k2 = Read-PublishRequest -Text ''
Assert 'K2 no file reads as no request' (-not $k2.Requested)

$k3 = Read-PublishRequest -Text '   '
Assert 'K3 an empty file reads as no request, not an unexplained release' (-not $k3.Requested)

$k4 = Read-PublishRequest -Text '{ truncated'
Assert 'K4 truncated JSON reads as no request rather than throwing' (-not $k4.Requested)

$k5 = Read-PublishRequest -Text "ship the installer fix`n"
Assert 'K5 a bare line typed by hand is still honoured' $k5.Requested
AssertEq 'K5 as its reason' 'ship the installer fix' $k5.Reason

# ---- live sections -------------------------------------------------------
#
# A sandbox with a fake `docker`/`gh` ahead of the real ones on PATH, and a
# sentinel publish script that writes a file if it is ever run.
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("daily-publish-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$binDir = Join-Path $sandbox 'bin'
New-Item -ItemType Directory -Path $binDir | Out-Null
$watermark = Join-Path $sandbox 'watermark'
$ranMarker = Join-Path $sandbox 'publish-ran.txt'
$fakePublish = Join-Path $sandbox 'fake-publish.ps1'
Set-Content -LiteralPath $fakePublish -Encoding ASCII -Value @"
param([string]`$Version = '', [switch]`$DryRun)
Set-Content -LiteralPath '$ranMarker' -Value `$Version
exit 0
"@

function Set-FakeTool([string]$name, [int]$code) {
    Set-Content -LiteralPath (Join-Path $binDir "$name.cmd") -Encoding ASCII -Value @"
@echo off
exit /b $code
"@
}

$requestFile = Join-Path $sandbox 'watermark-request'

function Invoke-Decider([string[]]$Extra, [int]$DockerCode, [int]$GhCode, [string]$At = '2026-09-01T18:30:00') {
    Set-FakeTool 'docker' $DockerCode
    Set-FakeTool 'gh' $GhCode
    # STDOUT ONLY (T883): the assertions below read this capture as text, and a
    # merged capture is where a host-formatted line gets into a text oracle. The
    # decider says everything it says on stdout, so stderr is left where it is
    # rather than redirected into the same file.
    $out = Join-Path $sandbox 'out.txt'
    $prevPath = $env:PATH
    $env:PATH = "$binDir;$prevPath"
    try {
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $publishDecider,
            '-Repo', $Repo, '-WatermarkPath', $watermark, '-PublishScript', $fakePublish,
            '-RequestPath', $requestFile,
            '-Now', $At, '-HourLocal', '17') + $Extra
        & powershell @psArgs > $out
        $code = $LASTEXITCODE
    } finally { $env:PATH = $prevPath }
    return [pscustomobject]@{ Exit = $code; Text = (Get-Content -Raw -LiteralPath $out) }
}

try {
    "== E. live -Check =="
    $e = Invoke-Decider -Extra @('-Check') -DockerCode 0 -GhCode 0
    AssertEq 'E1 a due -Check reports it and exits 10' 10 $e.Exit
    AssertMatch 'E2 naming the tag it would publish' 'win-v\d+\.\d+\.\d+' $e.Text
    Assert 'E3 and stamps nothing' (-not (Test-Path -LiteralPath $watermark))
    Assert 'E4 and runs no publish' (-not (Test-Path -LiteralPath $ranMarker))

    "== F. live skips =="
    # The T1292 arm, and the one that matters most: with Docker down - which is
    # its permanent state on this box - the default publish RUNS. For three days
    # it did not, and the only evidence was a SKIP line in a temp log.
    $f0 = Invoke-Decider -Extra @('-NoPublish') -DockerCode 1 -GhCode 0
    AssertEq 'F0 Docker down no longer stops the default publish' 10 $f0.Exit
    Assert 'F0 and nothing in the log calls Docker a reason to skip' ($f0.Text -notmatch 'SKIP.*Docker')
    Remove-Item -LiteralPath $watermark -Force -ErrorAction SilentlyContinue

    $f1 = Invoke-Decider -Extra @('-Local') -DockerCode 1 -GhCode 0
    AssertEq 'F1 under -Local, Docker down is a skip, not a failure' 0 $f1.Exit
    AssertMatch 'F1 with Docker named in the log' 'SKIP.*Docker' $f1.Text
    Assert 'F1 and the watermark untouched, so a later push can publish' (-not (Test-Path -LiteralPath $watermark))
    Assert 'F1 and nothing published' (-not (Test-Path -LiteralPath $ranMarker))

    $f2 = Invoke-Decider -Extra @('-Local') -DockerCode 0 -GhCode 1
    AssertEq 'F2 under -Local, an unauthenticated gh is a skip, not a failure' 0 $f2.Exit
    AssertMatch 'F2 with gh named in the log' 'SKIP.*gh' $f2.Text
    Assert 'F2 and the watermark untouched' (-not (Test-Path -LiteralPath $watermark))

    "== G. live -NoPublish =="
    $g = Invoke-Decider -Extra @('-NoPublish') -DockerCode 0 -GhCode 0
    AssertEq 'G1 a due publish reports 10' 10 $g.Exit
    Assert 'G2 and stamps the day' (Test-Path -LiteralPath $watermark)
    $stamped = Read-PublishWatermark -Text ([IO.File]::ReadAllText($watermark))
    AssertEq 'G3 with today''s local date' '2026-09-01' $stamped.Date
    AssertMatch 'G4 and the tag it chose' '^win-v\d+\.\d+\.\d+$' $stamped.Tag
    Assert 'G5 and the commit being released' ([bool]$stamped.Commit)

    $g2 = Invoke-Decider -Extra @() -DockerCode 0 -GhCode 0
    AssertEq 'G6 the stamp makes a second push the same evening a no-op' 0 $g2.Exit
    AssertMatch 'G6 saying it already published today' 'already published today' $g2.Text
    Assert 'G7 and the publish script was never run' (-not (Test-Path -LiteralPath $ranMarker))

    "== H. a pushed tag is not yet a release =="
    # The publish succeeded here means "the tag went out". CI still has to build
    # it, and a red release run leaves a tag with no release behind - which used
    # to be indistinguishable from a good publish, and is what let the health
    # line say everything was fine while nothing had shipped.
    Remove-Item -LiteralPath $watermark -Force -ErrorAction SilentlyContinue
    $h = Invoke-Decider -Extra @() -DockerCode 1 -GhCode 0
    AssertEq 'H1 a real publish run reports 10' 10 $h.Exit
    Assert 'H2 and the publish script actually ran, with Docker down' (Test-Path -LiteralPath $ranMarker)
    $hStamp = Read-PublishWatermark -Text ([IO.File]::ReadAllText($watermark))
    AssertEq 'H3 the outcome is tagged, not published - CI has not built it yet' 'tagged' $hStamp.Result
    AssertMatch 'H4 and the instant is recorded for the catch-up rule' '^\d{4}-\d{2}-\d{2}T' $hStamp.At
    AssertMatch 'H5 and the log says a tag went out rather than a release' 'TAGGED' $h.Text

    "== I. the tag publisher's refusals =="
    # publish-windows-tag.ps1 is the whole publish now, so its refusals are the
    # last thing between a bad version and a release nobody can install.
    $tagScript = Join-Path $Repo 'scripts\publish-windows-tag.ps1'
    Assert 'I0 the tag publisher exists' (Test-Path -LiteralPath $tagScript -PathType Leaf)
    function Invoke-TagPublisher([string[]]$TagArgs) {
        $out = Join-Path $sandbox 'tag-out.txt'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tagScript @TagArgs > $out 2>&1
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = (Get-Content -Raw -LiteralPath $out) }
    }
    $i1 = Invoke-TagPublisher @('-Version', '1.36', '-DryRun')
    AssertEq 'I1 a malformed version is refused' 1 $i1.Exit
    AssertMatch 'I1 and says what it wanted' 'X\.Y\.Z' $i1.Text

    # A version that already has a tag must never be re-pushed: the push would be
    # rejected as a non-fast-forward and read as a mysterious publish failure.
    $existing = @(git -C $Repo tag --list 'win-v[0-9]*.[0-9]*.[0-9]*')
    Assert 'I2 the repo has at least one published win-v tag to refuse' ($existing.Count -gt 0)
    $taken = if ($existing.Count) { ($existing[-1] -replace '^win-v', '') } else { '1.0.0' }
    $i2 = Invoke-TagPublisher @('-Version', $taken, '-DryRun')
    AssertEq 'I2 a version that is already tagged is refused' 1 $i2.Exit
    AssertMatch 'I2 and says so' 'already exists' $i2.Text

    # The happy path, as far as it can be taken without pushing: a fresh version
    # gets all the way to the push and stops there.
    $i3 = Invoke-TagPublisher @('-Version', '99.99.99', '-DryRun')
    AssertEq 'I3 a fresh version reaches the push and stops under -DryRun' 0 $i3.Exit
    AssertMatch 'I3 naming the tag it would push' 'win-v99\.99\.99' $i3.Text
    Assert 'I4 and no tag was created by a dry run' (
        -not (@(git -C $Repo tag --list 'win-v99.99.99')).Count
    )

    "== L. the 2026-09-03 shape, end to end =="
    # Publish at T; a fix the user is waiting on lands at T+90m; it must be able
    # to reach a release the same day, without anybody cutting a tag by hand.
    # Every step below is the real script, with a sentinel publisher.
    Remove-Item -LiteralPath $watermark, $ranMarker, $requestFile -Force -ErrorAction SilentlyContinue
    $l1 = Invoke-Decider -Extra @() -DockerCode 1 -GhCode 0 -At '2026-09-03T09:28:00'
    AssertEq 'L1 the day publishes as usual' 10 $l1.Exit
    Assert 'L1 and the publisher ran' (Test-Path -LiteralPath $ranMarker)
    $l1Tag = (Read-PublishWatermark -Text ([IO.File]::ReadAllText($watermark))).Tag
    Remove-Item -LiteralPath $ranMarker -Force -ErrorAction SilentlyContinue
    # The morning publish went out at an EARLIER commit than the one the fix
    # lands on - that is the whole scenario, and the sandbox's HEAD does not move
    # on its own, so the watermark is rewritten to say so.
    $l1Wm = [IO.File]::ReadAllText($watermark) -replace '"commit":"[^"]*"', "`"commit`":`"$((git -C $Repo rev-parse --short HEAD~1).Trim())`""
    [IO.File]::WriteAllText($watermark, $l1Wm)

    # 11:01 - the fix lands. Old behaviour, and the bug this task is about.
    $l2 = Invoke-Decider -Extra @() -DockerCode 1 -GhCode 0 -At '2026-09-03T11:01:00'
    AssertEq 'L2 without a request the fix is stranded until tomorrow' 0 $l2.Exit
    AssertMatch 'L2 exactly as it read on the day' 'already published today' $l2.Text
    Assert 'L2 and nothing was published' (-not (Test-Path -LiteralPath $ranMarker))

    # The turn that landed the fix records that somebody is waiting on it.
    $l3 = Invoke-Decider -Extra @('-Request', '-Reason', 'T1291: the installer dies silently on a same-version install') `
        -DockerCode 1 -GhCode 0 -At '2026-09-03T11:02:00'
    AssertEq 'L3 recording a request exits 0' 0 $l3.Exit
    Assert 'L3 and writes the request' (Test-Path -LiteralPath $requestFile)
    Assert 'L3 and publishes nothing by itself' (-not (Test-Path -LiteralPath $ranMarker))

    $l3b = Invoke-Decider -Extra @('-Request') -DockerCode 1 -GhCode 0 -At '2026-09-03T11:02:00'
    AssertEq 'L3b a request with no reason is refused - an unexplained release is noise' 1 $l3b.Exit

    # The next task-boundary push, minutes later. This is the whole task.
    $l4 = Invoke-Decider -Extra @() -DockerCode 1 -GhCode 0 -At '2026-09-03T11:03:00'
    AssertEq 'L4 the next push ships it the SAME DAY' 10 $l4.Exit
    Assert 'L4 and the publisher ran a second time today' (Test-Path -LiteralPath $ranMarker)
    AssertMatch 'L4 naming who was waiting' 'requested: T1291' $l4.Text
    # The second publish of a day must not re-use the morning's version. The
    # sentinel publisher creates no tag, so assert the property on the version
    # scheme directly, over the tag set the real publisher would have left
    # behind (publish-windows-tag.ps1 creates the tag locally before pushing it).
    $l5 = Resolve-DailyPublishVersion -Tags (@(git -C $Repo tag --list 'v[0-9]*.[0-9]*.[0-9]*') +
        @(git -C $Repo tag --list 'win-v[0-9]*.[0-9]*.[0-9]*') + @($l1Tag))
    Assert "L5 the second publish of a day walks past the morning's tag ($l1Tag)" ("win-v$($l5.Version)" -ne $l1Tag)
    Assert 'L6 and the request is consumed, so it cannot re-fire every push' (-not (Test-Path -LiteralPath $requestFile))
    Remove-Item -LiteralPath $ranMarker -Force -ErrorAction SilentlyContinue

    # And the cadence is exactly as it was for a turn that asks for nothing.
    $l7 = Invoke-Decider -Extra @() -DockerCode 1 -GhCode 0 -At '2026-09-03T18:30:00'
    AssertEq 'L7 the default cadence is unchanged - no publish-per-commit' 0 $l7.Exit
    Assert 'L7 and nothing else was published' (-not (Test-Path -LiteralPath $ranMarker))

    # A request left standing with nothing behind it clears itself rather than
    # minting an empty release on the next push.
    Set-Content -LiteralPath $requestFile -Encoding ascii -Value '{"at":"2026-09-03T19:00:00-07:00","reason":"nothing landed","commit":"deadbee"}'
    $l8 = Invoke-Decider -Extra @() -DockerCode 1 -GhCode 0 -At '2026-09-03T19:01:00'
    AssertEq 'L8 a request with nothing behind it publishes nothing' 0 $l8.Exit
    AssertMatch 'L8 and says why' 'nothing has landed since' $l8.Text
    Assert 'L8 and clears itself' (-not (Test-Path -LiteralPath $requestFile))
    Assert 'L8 and no empty release was minted' (-not (Test-Path -LiteralPath $ranMarker))

    "== M. -Status names what is stranded =="
    $m = Invoke-Decider -Extra @('-Status') -DockerCode 1 -GhCode 0 -At '2026-09-03T19:05:00'
    AssertEq 'M1 -Status exits 0' 0 $m.Exit
    AssertMatch 'M2 and names the last publish' 'LAST PUBLISH' $m.Text
    AssertMatch 'M3 and answers the stranded question' 'STRANDED' $m.Text
    Assert 'M4 and publishes nothing' (-not (Test-Path -LiteralPath $ranMarker))
    Complete-TestBody
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# A clean green run stamps the files this harness covers (T783). The negative
# control scores its checks inverted, so it never stamps.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard daily-publish -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Label 'T1220 ACCEPTANCE' -Pass $script:passes -Fail $script:failures
