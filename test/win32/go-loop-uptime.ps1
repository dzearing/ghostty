# go-loop uptime formatting (user, 2026-08-11: every heartbeat must say how long
# the loop has been running).
#
# WHY THIS FILE EXISTS. `Format-Uptime` was written with `[int]$t.TotalDays`,
# and PowerShell's [int] cast ROUNDS rather than truncates. A loop up for
# 1d 12h 14m has TotalDays = 1.51, so it printed "2d 12h 14m" - a whole day
# added to the single number the function exists to report. It was invisible for
# the first 36 hours because the cast only crosses over past the half-day mark,
# and then it announced a day of uptime that had not happened (caught live at
# 2026-08-12 20:36, when a 1d 10h reading became 2d 12h two hours later).
#
# The rule: only the LEADING unit is computed from a Total*, and it must be
# floored. Every trailing component (`$t.Hours`, `$t.Minutes`) is already a
# truncated remainder and is safe.
#
# The function is dot-sourced out of the real script by regex rather than
# copied, so this asserts the shipping code and cannot drift from it.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$lockScript = Join-Path $repo 'scripts\go-loop-lock.ps1'

$script:failures = 0
$script:skipped = 0
# Counted, never hand-written into the verdict: a literal count is a number
# nobody re-checks, and this file's first draft claimed 14 while running 11.
$script:asserted = 0
function Assert($name, $cond) {
    $script:asserted++
    if ($cond) { Write-Host "  PASS $name" }
    else { Write-Host "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $lockScript)) {
    Write-Host "SKIP go-loop-lock.ps1 not found at $lockScript"; $script:skipped++
    "1 FAILURE(S)"; exit 1
}

# Lift just the function out. Running the script itself would take the real
# lock, which is the last thing a test may do on a box with a live loop.
$src = Get-Content $lockScript -Raw
$m = [regex]::Match($src, '(?s)function Format-Uptime.*?\n\}')
if (-not $m.Success) {
    Write-Host '  FAIL Format-Uptime not found in go-loop-lock.ps1'
    "1 FAILURE(S)"; exit 1
}
Invoke-Expression $m.Value

""
"A. the leading unit truncates, it never rounds"
# 1d 12h 14m is the exact reading that was misreported. 1d 23h 59m is the worst
# case: rounding would call it 2d while the trailing components still say 23h.
Assert 'a day and a half is 1d, not 2d' ((Format-Uptime (1*1440 + 12*60 + 14)) -eq '1d 12h 14m')
Assert 'one minute short of two days is still 1d' ((Format-Uptime (1*1440 + 23*60 + 59)) -eq '1d 23h 59m')
Assert 'an hour and three quarters is 1h, not 2h' ((Format-Uptime 105) -eq '1h 45m')
Assert 'fifty-nine and a half minutes is 59m, not 60m' ((Format-Uptime 59.9) -eq '59m')

""
"B. the unit boundaries"
Assert 'under an hour reports minutes alone' ((Format-Uptime 5) -eq '5m')
Assert 'exactly an hour crosses to the hour form' ((Format-Uptime 60) -eq '1h 00m')
Assert 'exactly a day crosses to the day form' ((Format-Uptime 1440) -eq '1d 00h 00m')
Assert 'just past two days reads 2d' ((Format-Uptime (2*1440 + 1)) -eq '2d 00h 01m')

""
"C. degenerate inputs"
Assert 'zero is 0m, not blank' ((Format-Uptime 0) -eq '0m')
# A clock that moved backwards (NTP, a DST step) must not print a negative
# uptime; the loop is not un-running.
Assert 'a negative duration clamps to 0m' ((Format-Uptime -30) -eq '0m')

""
"D. it never disagrees with the raw minutes it was given"
# The formatted string and uptime_minutes are read side by side in the health
# line, so they must describe the same instant. Re-derive the total from the
# printed components and require it back within a minute.
$bad = 0
foreach ($mins in @(1, 61, 599, 1439, 1440, 2174, 4321, 10079)) {
    $s = Format-Uptime $mins
    $total = 0
    if ($s -match '^(\d+)d (\d+)h (\d+)m$') { $total = [int]$Matches[1]*1440 + [int]$Matches[2]*60 + [int]$Matches[3] }
    elseif ($s -match '^(\d+)h (\d+)m$')    { $total = [int]$Matches[1]*60 + [int]$Matches[2] }
    elseif ($s -match '^(\d+)m$')           { $total = [int]$Matches[1] }
    else { $bad++; continue }
    if ([math]::Abs($total - $mins) -ge 1) { $bad++; Write-Host "    $mins min rendered '$s' (re-reads as $total)" }
}
Assert 'every rendering re-reads as the minutes it was given' ($bad -eq 0)

""
if ($script:failures -eq 0) {
    "ALL PASS ($($script:asserted) assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
    exit 0
} else {
    "$($script:failures) FAILURE(S)"
    exit 1
}
