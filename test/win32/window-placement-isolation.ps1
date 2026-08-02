# T267 acceptance: a GUI script's window geometry does not depend on run order.
#
# THE DEFECT. Every GUI script clears session-layout-debug.json before it
# launches (the T131 lesson) and NONE of them cleared the OTHER debug state
# file - %LOCALAPPDATA%\ghoztty\window_placement-debug, the T85 memory of the
# last window's outer size and maximized flag. A script that never calls
# Set-TestWindowSize therefore opened at whatever the LAST debug window was
# left at, including maximized, so its SETUP was a function of what ran before
# it. Nothing fails when that goes wrong; the geometry is simply different.
# It cost two red runs against a build that was behaving correctly
# (chrome-merged-row.ps1's own second run, then three tab-strip.ps1
# assertions once that was clean).
#
# THE FIX, and what this script guards: Start-OnTestDesktop deletes the file
# before every ghoztty.exe launch (Clear-TestWindowPlacement), with
# -KeepWindowPlacement as the opt-out for the two scripts whose SUBJECT is
# that memory (window-size-memory.ps1, reset-window-size.ps1).
#
# ORACLE, and why it is two cases. A single "the window was not maximized"
# assertion is green for entirely the wrong reason if the poison is inert -
# the same empty-rather-than-absent trap as T214/T303. So the poison is proved
# to BITE first:
#
#   A) -KeepWindowPlacement -> poison honored: window maximized, file survives.
#   B) default              -> poison cleared: window normal,   file gone.
#
# A is the positive control for B. Only the pair says the clear is doing work.
#
# The poison is written to the DEBUG file only, which no release build and
# therefore no installed Ghoztty ever reads, and it is removed in `finally`.
#
# T217: runs on a BACKGROUND Win32 desktop, so it never takes the user's
# foreground - asserted at the end, not assumed.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW) so a launch can
# never find - or forward to - the user's instance.
$env:GHOZTTY_PIPE_SUFFIX = '-t267placement'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# A tiny MAXIMIZED placement: the exact shape that broke chrome-merged-row's
# second run. Format is "<width> <height> <maximized>" (window_memory.zig).
$poison = '300 250 1'
$wp = Join-Path $env:LOCALAPPDATA 'ghoztty\window_placement-debug'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    foreach ($case in @(
            @{ Name = '-KeepWindowPlacement'; Keep = $true;  WantZoomed = $true },
            @{ Name = 'default';              Keep = $false; WantZoomed = $false })) {

        Reset-GhozttyTestState -Exe $exe | Out-Null
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $wp) | Out-Null
        Set-Content -Path $wp -Value $poison -Encoding Ascii
        Assert ((Get-Content $wp -Raw).Trim() -eq $poison) `
            "$($case.Name): poison written"

        # session-persistence=false: a persisted session would restore a LAYOUT
        # whose geometry competes with the placement memory under test (T248).
        $cliArgs = @('--config-default-files=false', '--session-persistence=false')
        $app = if ($case.Keep) {
            Start-OnTestDesktop -Exe $exe -Arguments $cliArgs -KeepWindowPlacement
        } else {
            Start-OnTestDesktop -Exe $exe -Arguments $cliArgs
        }
        Start-Sleep -Seconds 3
        if ($app.Process -and $app.Process.HasExited) {
            Write-Host "SETUP FAIL: GUI died at launch ($($case.Name))"; exit 1
        }
        $top = Wait-TestWindow -ProcessId ([int]$app.Pid) -Class 'GhozttyWindow'
        if ($top -eq [IntPtr]::Zero) {
            Write-Host "SETUP FAIL: top window not found ($($case.Name))"; exit 1
        }
        Assert (-not (Test-TestDesktopLeak -ProcessId ([int]$app.Pid))) `
            "$($case.Name): GUI is NOT enumerable on the interactive desktop"

        $zoomed = [bool](Test-TestWindowZoomed -Window $top)
        Assert ($zoomed -eq $case.WantZoomed) `
            "$($case.Name): window opened maximized = $zoomed (want $($case.WantZoomed))"

        $left = Test-Path $wp
        Assert ($left -eq $case.Keep) `
            "$($case.Name): placement file survived the launch = $left (want $($case.Keep))"
    }
}
finally {
    Reset-GhozttyTestState -Exe $exe | Out-Null
    # Never leave the poison behind: it would size the next debug window a
    # developer opens by hand, which is the very failure this script is about.
    Remove-Item $wp -Force -ErrorAction SilentlyContinue
    Remove-TestDesktop
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) `
    'no test-desktop app ever became foreground on the interactive desktop'

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
