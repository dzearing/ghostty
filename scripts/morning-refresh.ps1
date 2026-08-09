# The once-a-morning client refresh (tracker T525).
#
# THE PROBLEM. The user's Ghoztty is the one they work in all day, and it keeps
# running whatever exe it was launched with. Work that shipped days ago reads to
# them as a missing feature: on 2026-08-07 they reported "ctrl-d/ctrl-w don't
# work in the html pane" and "still no address bar" - both already built at HEAD
# and simply undelivered, because no delivery had run since the day before.
#
# THE DIRECTIVE (user, 2026-08-07, refining 2026-08-06):
#
#   "is there a way to update the client without interrupting the agent? I'd
#    love to have the latest bits when i come look at the digest, maybe when a
#    task completes a push and it's after 5am, that should signal that we need
#    to update the latest client code (but avoid an agent update because that
#    will shut down the loop.)"
#
# So the trigger is a PUSH, not a clock: the go loop pushes at every task
# boundary (go.md step 6), and the first such push after 5am local is the signal
# that the day has started and there are bits worth having. A clock alone would
# fire at 5am into whatever half-finished tree happened to be checked out; a
# push is the loop saying "this commit is good".
#
# WHAT IT DOES. Exactly one thing, once a day: run the ordinary delivery in
# -AppOnly mode (see upgrade-ghoztty-windows.ps1), which swaps the app and
# leaves ghoztty-agent.exe alone, restarts the app, lets the panes re-attach to
# the still-running agent, and types the resume prompt back into the loop's own
# pane. The agent is never killed, never restarted, and never asked about - an
# agent update ends the loop, which is the one outcome the directive forbids.
#
# HOW THE CALLER USES IT (go.md step 7):
#
#   powershell -NoProfile -File scripts\morning-refresh.ps1
#
#   exit 0  -> not due. Finish the turn normally with /reset-context.
#   exit 10 -> the refresh is running. END THE TURN NOW and do NOT reset: the
#              delivery types `/reset-context read go.md and go` into this pane
#              itself once the app is back, and a second reset would race it.
#   exit 1  -> it was due and the launch failed. Nothing was delivered; finish
#              the turn normally so the loop is not stalled by a bad delivery.
#
# WATERMARK. One line, the local date of the last refresh, in
# %LOCALAPPDATA%\ghoztty\morning-refresh (durable across reboots, unlike TEMP).
# It is stamped BEFORE the launch on purpose: the failure this must never have
# is a refresh that fails and re-fires on the next push, which would restart the
# user's terminal over and over. One attempt per day. The single exception is a
# launch that PROVABLY delivered nothing (launch-upgrade exit 3 - a build
# failure or a stale staging prefix, both of which abort before the kill); that
# rolls the watermark back so a later push in the same day can try again.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Repo = 'D:\git\ghoztty',
    # One line: the yyyy-MM-dd LOCAL date of the last refresh.
    [string]$WatermarkPath = (Join-Path $env:LOCALAPPDATA 'ghoztty\morning-refresh'),
    # Local hour on/after which a push counts as "the morning". 5, because the
    # digest is written at 5am and the user reads it with coffee.
    [int]$HourLocal = 5,
    # Test seam. Empty = now.
    [string]$Now = '',
    # Decide and print, change nothing, launch nothing.
    [switch]$Check,
    # Ignore the watermark (still stamps it). For a deliberate mid-day refresh.
    [switch]$Force,
    # Typed into the loop's pane after the app is back. The default is what
    # re-enters the go loop; anything without a continuation stalls it.
    [string]$Prompt = '/reset-context read go.md and go',
    # Test seam: go as far as the launch and then report what WOULD have run.
    [switch]$NoLaunch,
    # Empty = the sibling launch-upgrade.ps1. NOT defaulted with $PSScriptRoot
    # here: under `powershell -File <script>` that variable is still empty while
    # parameter defaults are being evaluated, so a Join-Path against it throws
    # before the script's first line runs — which is exactly the shape of
    # failure (nothing logged, only a binder error on a redirected stderr) that
    # T200 exists to keep out of this delivery path. Resolved in the body below,
    # where $PSScriptRoot is populated.
    [string]$LaunchScript = '',
    # Forwarded to launch-upgrade.ps1 (which forwards it to the upgrade script).
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Continue'

# ---- the decision, pure --------------------------------------------------
#
# Separated from every side effect so the acceptance test can drive all four
# arms without a clock, a watermark file, or a delivery.
function Test-MorningRefreshDue {
    param(
        [Parameter(Mandatory)][datetime]$Now,
        # The watermark's contents, or '' / $null when there is no watermark.
        [string]$LastDate = '',
        [int]$HourLocal = 5,
        [switch]$Force
    )
    $today = $Now.ToString('yyyy-MM-dd')
    $last = if ($LastDate) { $LastDate.Trim() } else { '' }
    if ($Force) {
        return [pscustomobject]@{ Due = $true; Today = $today; Why = "forced (last=$(if ($last) { $last } else { 'never' }))" }
    }
    if ($Now.Hour -lt $HourLocal) {
        return [pscustomobject]@{ Due = $false; Today = $today; Why = "before ${HourLocal}:00 local (it is $($Now.ToString('HH:mm')))" }
    }
    if ($last -eq $today) {
        return [pscustomobject]@{ Due = $false; Today = $today; Why = "already refreshed today ($today)" }
    }
    # A watermark from the FUTURE is not a reason to refuse forever (a clock
    # change, a restored profile). It is also not today, so it does not block.
    return [pscustomobject]@{
        Due   = $true
        Today = $today
        Why   = "first push at/after ${HourLocal}:00 today (last refresh: $(if ($last) { $last } else { 'never' }))"
    }
}

# Dot-sourced by the test for the function above; running it then must not
# deliver anything.
if ($env:GHOZTTY_MORNING_REFRESH_DOTSOURCE -eq '1') { return }

if (-not $LaunchScript) { $LaunchScript = Join-Path $PSScriptRoot 'launch-upgrade.ps1' }

$log = Join-Path $env:TEMP 'ghoztty-morning-refresh.log'
function Log($m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    $line | Add-Content $log
    Write-Host $line
}

$now = if ($Now) { [datetime]::Parse($Now) } else { Get-Date }
$last = ''
if (Test-Path -LiteralPath $WatermarkPath) {
    try { $last = ([IO.File]::ReadAllText($WatermarkPath) -split "`n")[0].Trim() } catch { $last = '' }
}

$d = Test-MorningRefreshDue -Now $now -LastDate $last -HourLocal $HourLocal -Force:$Force
if (-not $d.Due) {
    Log "NOT DUE: $($d.Why)"
    exit 0
}

# The reuse path needs a pane to type the resume prompt into. Without one the
# delivery restarts the app and then logs RESUME-REUSE PARTIAL, leaving the loop
# sitting at an empty prompt until the watchdog notices - so refuse here, where
# it costs a stale client for a day, rather than there, where it costs the loop.
if (-not $env:GHOZTTY_PANE_ID) {
    Log "NOT DUE: $($d.Why), but there is no `$GHOZTTY_PANE_ID - this is not a Ghoztty pane, so the resume could not be typed back. Not refreshing."
    exit 0
}

Log "DUE: $($d.Why); pane=$env:GHOZTTY_PANE_ID"

if ($Check) {
    Log 'CHECK ONLY: not stamping, not launching'
    exit 10
}

# Stamp FIRST. See the header: a refresh that fails and re-fires on every push
# restarts the user's terminal in a loop, which is far worse than one stale day.
$stamped = $false
try {
    $dir = Split-Path -Parent $WatermarkPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($WatermarkPath, "$($d.Today)`n", (New-Object Text.UTF8Encoding($false)))
    $stamped = $true
    Log "watermark stamped: $($d.Today) -> $WatermarkPath"
} catch {
    Log "WARNING: could not stamp the watermark $WatermarkPath ($($_.Exception.Message)); refusing to launch, because an unstamped refresh would re-fire on the next push"
    exit 1
}

if ($NoLaunch) {
    Log "NO-LAUNCH: would have run $LaunchScript -AppOnly with prompt [$Prompt]"
    exit 10
}

if (-not (Test-Path -LiteralPath $LaunchScript -PathType Leaf)) {
    Log "LAUNCH FAILED: $LaunchScript not found"
    exit 1
}

# In-process, so -Prompt binds as ONE string. Every reason for that is in
# launch-upgrade.ps1's header; the short version is that Start-Process does not
# quote its arguments and a multi-word prompt is shredded before the child's
# first line runs.
Log "launching the app-only delivery: $LaunchScript"
& $LaunchScript -Prompt $Prompt -Repo $Repo -ExtraArgs (@('-AppOnly') + $ExtraArgs)
$code = $LASTEXITCODE

if ($code -eq 0) {
    Log 'LAUNCH OK: the app-only refresh is running. END THE TURN - it will reset this pane itself.'
    exit 10
}

# Exit 3 from launch-upgrade means it aborted BEFORE anything destructive (build
# failure, or a staging prefix that is not this tree). Nothing was delivered and
# nothing was killed, so a later push today may legitimately try again.
if ($code -eq 3 -and $stamped) {
    try {
        if ($last) { [IO.File]::WriteAllText($WatermarkPath, "$last`n", (New-Object Text.UTF8Encoding($false))) }
        else { Remove-Item -LiteralPath $WatermarkPath -Force -ErrorAction Stop }
        Log "LAUNCH REFUSED (exit 3, nothing delivered); watermark rolled back to '$(if ($last) { $last } else { '<none>' })' so a later push can retry"
    } catch {
        Log "LAUNCH REFUSED (exit 3); could not roll the watermark back ($($_.Exception.Message)) - no retry today"
    }
    exit 1
}

Log "LAUNCH FAILED (exit $code): nothing was delivered. Finish the turn normally; the client stays on its current build today."
exit 1
