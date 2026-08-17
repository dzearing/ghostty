# The once-a-morning, app-only client refresh (tracker T525).
#
# The user works all day in one Ghoztty, which keeps running whatever exe it was
# launched with, so shipped work reads to them as missing features. The fix is a
# refresh triggered by the first task-boundary push after 5am - and the whole
# design constraint is that it must not interrupt anything: never touch the
# agent (an agent update ends the go loop, which the directive forbids) and
# never raise the mandatory agent-restart confirmation at a machine nobody is
# sitting at.
#
#   A  pure: the due decision. Four arms, no clock, no files, no delivery.
#   B  the watermark: -Check does not stamp, a stamped day does not re-fire, and
#      the stamp happens BEFORE the launch so a failure cannot restart the
#      user's terminal on every push for the rest of the day.
#   C  the no-pane guard: a refresh with nowhere to type the resume back is
#      refused here, where it costs a stale day, not there, where it costs the
#      loop.
#   D  -AppOnly in upgrade-ghoztty-windows.ps1: the agent exe is NOT swapped
#      (with the ordinary delivery as the positive control that it otherwise
#      IS), and the deferral marker is written before the kill.
#   E  the marker the app reads: shape, and the negative controls that must
#      never suppress a confirmation.
#   F  go.md documents the flow, since a turn following it exactly is the only
#      thing that runs this.
#
# Hermetic: every install/staging/watermark path is under
# %TEMP%\ghoztty-morning-<pid>, TEMP is redirected for every child so the box's
# real upgrade log is untouched, no build is ever run, no app is ever launched,
# and -NoExtraInstalls keeps section D away from the real portable/share copies.
#
#   powershell -NoProfile -File test\win32\morning-refresh.ps1
param(
    # Only ever used as a REAL binary that carries SOME commit, and as bytes to
    # copy. Never launched as an app.
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$PureOnly,
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-morning-$PID"

# isolation: none - no app is ever launched and no CLI verb is ever run; the
# +list mention below is commentary on a child script's behavior. Every path
# the run touches sits under $root (T680 meta-check reads this marker).

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

New-Item -ItemType Directory -Force $root | Out-Null
# T199: a stand-in INSTALL dir lives under $root, and a refresh ends by
# launching the app out of one. Arm the teardown so a run that dies mid-way
# still takes its ghoztty processes with it.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-HarnessGhozttyRoot -Root $root | Out-Null
$refresh = Join-Path $Repo 'scripts\morning-refresh.ps1'
Assert "0 morning-refresh.ps1 exists" (Test-Path -LiteralPath $refresh -PathType Leaf)

# ============================================================================
"== A: the due decision (pure)"
# ============================================================================
# Dot-source for the function only; the guard env var stops the script body
# before it can stamp or deliver anything.
$env:GHOZTTY_MORNING_REFRESH_DOTSOURCE = '1'
try { . $refresh } finally { Remove-Item env:GHOZTTY_MORNING_REFRESH_DOTSOURCE -ErrorAction SilentlyContinue }

$morning = [datetime]'2026-08-09 06:30'
$night = [datetime]'2026-08-09 03:10'

$a1 = Test-MorningRefreshDue -Now $morning -LastDate '' -HourLocal 5
Assert "A1 the first push of the day, never refreshed before" $a1.Due
Assert "A2 and it says why in words a log reader can use" ($a1.Why -match 'never')

$a3 = Test-MorningRefreshDue -Now $morning -LastDate '2026-08-08' -HourLocal 5
Assert "A3 a push the morning after yesterday's refresh is due" $a3.Due
AssertEq "A4 and the day it would stamp is today" '2026-08-09' $a3.Today

# THE arm that stops a restart-per-push loop: later pushes the same day.
$a5 = Test-MorningRefreshDue -Now $morning -LastDate '2026-08-09' -HourLocal 5
Assert "A5 a second push the same day is NOT due" (-not $a5.Due)
Assert "A6 and says so as 'already refreshed today'" ($a5.Why -match 'already refreshed today')

# A pre-dawn push is the loop working through the night; the user is asleep and
# the digest is not written yet.
$a7 = Test-MorningRefreshDue -Now $night -LastDate '2026-08-08' -HourLocal 5
Assert "A7 a 03:10 push is not the morning" (-not $a7.Due)
Assert "A8 and names the cutoff rather than just refusing" ($a7.Why -match '5:00 local')

# Cutoff exactly: 05:00 counts, 04:59 does not.
Assert "A9 05:00 sharp is the morning" `
    (Test-MorningRefreshDue -Now ([datetime]'2026-08-09 05:00') -LastDate '2026-08-08' -HourLocal 5).Due
Assert "A10 04:59 is not" `
    (-not (Test-MorningRefreshDue -Now ([datetime]'2026-08-09 04:59') -LastDate '2026-08-08' -HourLocal 5).Due)

# -Force is a deliberate mid-day refresh and beats both refusals.
Assert "A11 -Force overrides 'already today'" `
    (Test-MorningRefreshDue -Now $morning -LastDate '2026-08-09' -HourLocal 5 -Force).Due
Assert "A12 -Force overrides the hour" `
    (Test-MorningRefreshDue -Now $night -LastDate '2026-08-08' -HourLocal 5 -Force).Due

# A watermark from the future (clock change, restored profile) must not wedge
# the feature off forever: it is not today, so it does not block.
Assert "A13 a future watermark does not block tomorrow's refresh" `
    (Test-MorningRefreshDue -Now $morning -LastDate '2027-01-01' -HourLocal 5).Due
# Whitespace is what a hand-edited or CRLF-written watermark looks like.
Assert "A14 a padded watermark still matches today" `
    (-not (Test-MorningRefreshDue -Now $morning -LastDate "  2026-08-09`r" -HourLocal 5).Due)

if ($PureOnly) {
    ""
    if (-not $Keep) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
    exit ($script:failures -gt 0)
}

function Invoke-InSandboxTemp([string[]]$Argv, [string]$TempDir, [int]$TimeoutMs = 90000) {
    $savedTemp, $savedTmp = $env:TEMP, $env:TMP
    $env:TEMP, $env:TMP = $TempDir, $TempDir
    try {
        $o = Join-Path $TempDir "child-$([guid]::NewGuid().ToString('N').Substring(0,8)).out"
        $e = "$o.err"
        $p = Start-Process powershell -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e -ArgumentList $Argv
        # Cache .Handle BEFORE the child exits or .ExitCode reads back empty.
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
        return [pscustomobject]@{
            Code = $p.ExitCode
            Out  = (Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue)
            Err  = (Get-Content -LiteralPath $e -Raw -ErrorAction SilentlyContinue)
        }
    } finally { $env:TEMP, $env:TMP = $savedTemp, $savedTmp }
}

# ============================================================================
"== B: the watermark, end to end (no delivery)"
# ============================================================================
# -NoLaunch runs every side effect except the delivery itself, which is what
# makes the stamp-before-launch ordering observable without restarting anything.
$bRoot = Join-Path $root 'watermark'
New-Item -ItemType Directory -Force $bRoot | Out-Null
$bMark = Join-Path $bRoot 'morning-refresh'

function Invoke-Refresh([string[]]$Extra, [string]$Pane = 'PANE-FOR-TEST') {
    $saved = $env:GHOZTTY_PANE_ID
    $env:GHOZTTY_PANE_ID = $Pane
    try {
        return Invoke-InSandboxTemp -TempDir $bRoot -TimeoutMs 60000 -Argv (
            @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $refresh,
              '-Repo', $Repo, '-WatermarkPath', $bMark) + $Extra)
    } finally {
        if ($null -eq $saved) { Remove-Item env:GHOZTTY_PANE_ID -ErrorAction SilentlyContinue }
        else { $env:GHOZTTY_PANE_ID = $saved }
    }
}

$b1 = Invoke-Refresh @('-Now', '2026-08-09T06:30', '-Check')
AssertEq "B1 -Check on a due morning reports 'launch it' (exit 10)" 10 $b1.Code
Assert "B2 and it did NOT stamp - a check must not consume the day" (-not (Test-Path -LiteralPath $bMark))

$b3 = Invoke-Refresh @('-Now', '2026-08-09T03:10', '-Check')
AssertEq "B3 -Check before 5am reports 'carry on' (exit 0)" 0 $b3.Code

$b4 = Invoke-Refresh @('-Now', '2026-08-09T06:30', '-NoLaunch')
AssertEq "B4 a due morning would launch the delivery (exit 10)" 10 $b4.Code
Assert "B5 and it stamped BEFORE the launch, not after it" (Test-Path -LiteralPath $bMark)
AssertEq "B6 the stamp is today's local date" '2026-08-09' `
    ((Get-Content -LiteralPath $bMark -Raw).Trim())
Assert "B7 the launch it describes is the app-only one" ($b4.Out -match '-AppOnly')

# THE regression this ordering exists for: a second push the same day must be a
# no-op, or the user's terminal restarts on every task boundary.
$b8 = Invoke-Refresh @('-Now', '2026-08-09T09:15', '-NoLaunch')
AssertEq "B8 THE POINT: the next push the same day does nothing (exit 0)" 0 $b8.Code
Assert "B9 and says which day it already served" ($b8.Out -match 'already refreshed today')

$b10 = Invoke-Refresh @('-Now', '2026-08-10T05:30', '-NoLaunch')
AssertEq "B10 tomorrow's first push is due again" 10 $b10.Code
AssertEq "B11 and the stamp rolled forward" '2026-08-10' `
    ((Get-Content -LiteralPath $bMark -Raw).Trim())

# No BOM: the watermark is re-read by this same script, but the marker in D/E is
# read by the app's Zig parser, and one writer habit covers both.
# Existence is asserted separately: a missing file would otherwise make the
# BOM check pass on a null, which is the false green this suite must not print.
$bBytes = if (Test-Path -LiteralPath $bMark) { [IO.File]::ReadAllBytes($bMark) } else { $null }
Assert "B12 the watermark is written without a UTF-8 BOM" `
    ($null -ne $bBytes -and -not ($bBytes.Length -ge 3 -and $bBytes[0] -eq 0xEF -and $bBytes[1] -eq 0xBB -and $bBytes[2] -eq 0xBF))

# ============================================================================
"== C: no pane, no refresh"
# ============================================================================
# Without a pane id the delivery restarts the app and then cannot type the
# resume prompt anywhere - the loop sits at an empty prompt until the watchdog
# notices. Refusing costs one stale day; proceeding costs the loop.
Remove-Item -LiteralPath $bMark -Force -ErrorAction SilentlyContinue
$c1 = Invoke-Refresh @('-Now', '2026-08-11T06:30', '-NoLaunch') -Pane ''
AssertEq "C1 a due morning outside a Ghoztty pane is refused (exit 0)" 0 $c1.Code
Assert "C2 and names the reason" ($c1.Out -match 'GHOZTTY_PANE_ID')
Assert "C3 THE POINT: it did not burn the day's watermark either" (-not (Test-Path -LiteralPath $bMark))

# ============================================================================
"== D: -AppOnly delivers the app and nothing else"
# ============================================================================
$upgrade = Join-Path $Repo 'scripts\upgrade-ghoztty-windows.ps1'
$dRoot = Join-Path $root 'upgrade'
$dStaging = Join-Path $dRoot 'staging'
$dInstall = Join-Path $dRoot 'install'
New-Item -ItemType Directory -Force (Join-Path $dStaging 'bin') | Out-Null
New-Item -ItemType Directory -Force $dInstall | Out-Null
Copy-Item -LiteralPath $Exe (Join-Path $dStaging 'bin\ghoztty.exe') -Force
$dLog = Join-Path $dRoot 'ghoztty-upgrade.log'
$dMarker = Join-Path $dRoot 'agent-upgrade-defer'
$installedExe = Join-Path $dInstall 'ghoztty.exe'
$installedAgent = Join-Path $dInstall 'ghoztty-agent.exe'

. (Join-Path $Repo 'scripts\delivery-version.ps1')
$exeCommit = (Resolve-GhozttyExeCommit -Exe $Exe).Commit
Assert "D0 the probe binary carries a readable commit ($exeCommit)" ([bool]$exeCommit)

# Sentinels, not binaries: the agent exe is never executed on this path, and its
# survival byte-for-byte IS the assertion.
$agentSentinel = 'RUNNING-AGENT-BUILD-DO-NOT-REPLACE'
Set-Content -LiteralPath $installedAgent -Encoding ascii -Value $agentSentinel
Set-Content -LiteralPath (Join-Path $dStaging 'bin\ghoztty-agent.exe') -Encoding ascii -Value 'NEWER-AGENT-BUILD'
Set-Content -LiteralPath $installedExe -Encoding ascii -Value 'PREVIOUS-APP'

function Invoke-Upgrade([string[]]$Extra) {
    Remove-Item -LiteralPath $dLog -Force -ErrorAction SilentlyContinue
    return Invoke-InSandboxTemp -TempDir $dRoot -Argv (
        @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
          '-Staging', $dStaging, '-InstallDir', $dInstall, '-WorkingDirectory', $Repo,
          '-ExpectedCommit', $exeCommit, '-NoResume', '-NoExtraInstalls',
          '-DelaySeconds', '0') + $Extra)
}

$d1 = Invoke-Upgrade @('-AppOnly', '-DeferMarkerPath', $dMarker, '-DeferMinutes', '20')
$dLogText = Get-Content -LiteralPath $dLog -Raw -ErrorAction SilentlyContinue
AssertEq "D1 an app-only delivery succeeds" 0 $d1.Code
Assert "D2 the app was swapped" ($dLogText -match 'exe swapped')
Assert "D3 and verified against the delivered commit" ($dLogText -match 'POST-SWAP VERIFY OK')
AssertEq "D4 the installed exe really is the staged app" `
    (Get-FileHash -LiteralPath (Join-Path $dStaging 'bin\ghoztty.exe')).Hash `
    (Get-FileHash -LiteralPath $installedExe).Hash

Assert "D5 THE POINT: the agent swap was skipped, and said so" ($dLogText -match 'APP-ONLY: ghoztty-agent\.exe NOT swapped')
AssertEq "D6 THE POINT: the installed agent is byte-for-byte untouched" $agentSentinel `
    ((Get-Content -LiteralPath $installedAgent -Raw).Trim())
Assert "D7 and no .bak was left behind by a half-done rename" `
    (-not (Test-Path -LiteralPath "$installedAgent.bak"))

Assert "D8 the deferral marker was written" (Test-Path -LiteralPath $dMarker)
$markerBody = Get-Content -LiteralPath $dMarker -Raw
$markerDeadline = [int64](($markerBody -split "`n")[0].Trim())
$nowUnix = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Assert "D9 its deadline is in the future" ($markerDeadline -gt $nowUnix)
Assert "D10 and inside the window it asked for (~20 min)" ($markerDeadline -le ($nowUnix + 20 * 60 + 5))
$mBytes = [IO.File]::ReadAllBytes($dMarker)
Assert "D11 written without a BOM - the app parses the first line as an integer" `
    (-not ($mBytes.Length -ge 3 -and $mBytes[0] -eq 0xEF -and $mBytes[1] -eq 0xBB -and $mBytes[2] -eq 0xBF))
Assert "D12 the marker is armed BEFORE the kill, so the app cannot beat it" `
    ($dLogText.IndexOf('APP-ONLY: agent-upgrade confirmation deferred') -lt $dLogText.IndexOf('killing '))

# Goal 2 of the task is that the reboot is VERIFIED, not assumed - and the
# honest half of that is what the script says when it has no proof. This run is
# -NoResume, so no app was ever started and nothing answered +list; a line
# claiming the app came back here would be exactly the fabricated success that
# T208's POST-SWAP check exists to prevent.
Assert "D12b with no app started, the refresh reports itself UNVERIFIED" `
    ($dLogText -match 'APP-REFRESH UNVERIFIED')
Assert "D12c and never claims the app came back" (-not ($dLogText -match 'APP-REFRESH OK'))

# --- the positive control: an ORDINARY delivery still ships the agent --------
# Without this, D5/D6 would pass just as well against a script that had stopped
# swapping the agent at all.
Set-Content -LiteralPath $installedAgent -Encoding ascii -Value $agentSentinel
Remove-Item -LiteralPath "$installedAgent.bak" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $dMarker -Force -ErrorAction SilentlyContinue
$d13 = Invoke-Upgrade @('-DeferMarkerPath', $dMarker)
$dLogText = Get-Content -LiteralPath $dLog -Raw -ErrorAction SilentlyContinue
AssertEq "D13 CONTROL: an ordinary delivery succeeds too" 0 $d13.Code
Assert "D14 CONTROL: and it DOES swap the agent" ($dLogText -match 'agent exe swapped')
AssertEq "D15 CONTROL: the installed agent is the staged one" 'NEWER-AGENT-BUILD' `
    ((Get-Content -LiteralPath $installedAgent -Raw).Trim())
Assert "D16 CONTROL: and it writes no deferral marker - an attended delivery may ask" `
    (-not (Test-Path -LiteralPath $dMarker))

# ============================================================================
"== E: the marker contract, from the app's side"
# ============================================================================
# The Zig parser is unit-tested in the none/win32 lanes
# (src/apprt/win32/agent_upgrade.zig). What belongs here is that the WRITER and
# the READER agree, and that the failure directions are the safe ones.
$eSrc = Get-Content -LiteralPath (Join-Path $Repo 'src\apprt\win32\agent_upgrade.zig') -Raw
Assert "E1 the app and the script name the same marker file" `
    ($eSrc -match 'defer_marker_name\s*=\s*"agent-upgrade-defer"')
Assert "E2 the app defers only a confirmation, never the free idle upgrade" `
    ($eSrc -match 'if \(d\.action != \.confirm_first\) return d;')
$eApp = Get-Content -LiteralPath (Join-Path $Repo 'src\apprt\win32\App.zig') -Raw
Assert "E3 both routes to that modal are deferred (staleness and skew)" `
    (([regex]::Matches($eApp, 'agent_upgrade\.applyDeferral')).Count -ge 2)
Assert "E4 a deferral is NOT a decline - the next quiet moment still asks" `
    ($eApp -match 'unattendedRefreshActive' -and
     -not ($eApp -match 'unattendedRefreshActive\(\)\s*\)\s*\{[^}]*agent_upgrade_declined = true'))

# ============================================================================
"== F: the documented turn is the whole turn"
# ============================================================================
# Nothing runs this flow except a turn following go.md, so the doc is the fix.
$goMd = Get-Content -LiteralPath (Join-Path $Repo 'go.md') -Raw
Assert "F1 go.md tells the turn to run the morning refresh" ($goMd -match 'morning-refresh\.ps1')
Assert "F2 and what exit 10 obliges it to do" ($goMd -match 'exit 10')
Assert "F3 and that the refresh is app-only, never an agent update" ($goMd -match 'never the agent')
Assert "F4 go.md points at this acceptance script" ($goMd -match 'morning-refresh\.ps1')

# ============================================================================
"== G: no delivery script may default a parameter from `$PSScriptRoot"
# ============================================================================
# Measured while building this: under `powershell -File <script>` PS 5.1 leaves
# $PSScriptRoot EMPTY while parameter defaults are evaluated, so a
# `Join-Path $PSScriptRoot ...` default throws in the BINDER - before line 1,
# with nothing logged and only a stderr the caller has usually redirected away.
# That is the same evidence-free failure shape T200 exists to keep out of this
# path, and launch-upgrade.ps1 was carrying it too.
foreach ($s in @('morning-refresh.ps1', 'launch-upgrade.ps1', 'upgrade-ghoztty-windows.ps1')) {
    $path = Join-Path $Repo "scripts\$s"
    $text = Get-Content -LiteralPath $path -Raw
    # The param block only: $PSScriptRoot in the BODY is correct and normal.
    $end = $text.IndexOf("`n)")
    $paramBlock = if ($end -gt 0) { $text.Substring(0, $end) } else { $text }
    # Comment lines are dropped first: these param blocks EXPLAIN the trap in
    # prose right where the default used to be, and a naive match would read
    # the warning as the defect.
    $code = ($paramBlock -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Assert "G $s does not evaluate `$PSScriptRoot in a parameter default" `
        ($code -notmatch '\$PSScriptRoot')
}

""
if (-not $Keep) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
