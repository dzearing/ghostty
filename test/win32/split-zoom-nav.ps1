# T77 acceptance: goto_split while a split is zoomed must never focus a
# hidden pane.
#
# Repro (pre-fix): zoom a pane (ctrl+shift+enter), then ctrl+alt+arrow -
# keyboard focus moved to a pane that is not rendered (the zoomed one
# stayed on screen). Mac/GTK honor `split-preserve-zoom`:
#   - default:      navigating away CLEARS the zoom (all panes visible)
#   - `navigation`: the zoom FOLLOWS the navigation target
#
# Two GUI launches assert both config values. Layout: one +split down ->
# pane A (top), pane B (bottom, focused). Zoom B, then ctrl+alt+up:
#   run 1 (default):    2 visible panes, focus on A (visible)
#   run 2 (navigation): 1 visible pane = A (zoom moved), focus on A
# Focused HWND is read with GetGUIThreadInfo (no thread attach needed);
# focus lands via the T48 deferred-SetFocus path, so assertions poll.
#
# A positive control (ctrl+k clear_screen, T55 pattern) runs first in run 1
# so an injection failure aborts instead of reading as a T77 regression.
# -NegativeControl inverts the run-1 zoom expectation and MUST fail; it is
# how a run proves the assertions still discriminate.
#
# T211: this is the harness's proof-of-concept migration. Everything runs on
# a BACKGROUND Win32 desktop via test/win32/lib/TestDesktop.ps1, so it never
# takes the user's foreground - asserted here, not assumed, by watching
# GetForegroundWindow on the interactive desktop for the whole run. The
# SendInput/SetForegroundWindow/CopyFromScreen mechanisms do not work there;
# the harness supplies the replacements (see its header).
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Always isolate the IPC endpoint: the app inherits this env through
# CreateProcessW and so does every `& $exe +...` below, so the user's own
# instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = '-zoomnavtest'
$errlog = Join-Path $env:TEMP 'ghoztty-split-zoom-nav-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Run-Case([string]$label, [string[]]$extraArgs, [bool]$expectZoomFollows, [bool]$control) {
    Kill-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }

    # Mandatory: each section's launch writes a session-layout manifest the
    # next one would restore, so a later section came up with an earlier
    # section's panes (T131's trap, found again 2026-07-29 during T155).
    $launchArgs = @('--session-persistence=false') + $extraArgs
    $sp = @{ Exe = $exe; Arguments = $launchArgs }
    if (-not $ExePath -and $control) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }

    # Isolation, asserted per launch: the window exists on the test desktop
    # (we just found it there) and must NOT be enumerable on the user's.
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        "$label window is NOT enumerable on the interactive desktop"

    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 800

    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    Assert ($panes.Count -eq 2 -and @($panes | Where-Object Visible).Count -eq 2) "$label setup: 2 visible panes"
    if ($panes.Count -ne 2) { Stop-Process -Id $app.Pid -Force; exit 1 }
    $A = $panes | Sort-Object Top | Select-Object -First 1     # top pane
    $B = $panes | Sort-Object Top | Select-Object -Last 1      # bottom pane (focused after split)

    if ($control) {
        # Positive control: ctrl+k reaches binding dispatch (debug log only).
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl -Key K
        if (-not $r) { Write-Host "ABORT: control chord not sent"; Stop-Process -Id $app.Pid -Force; exit 1 }
        Start-Sleep -Milliseconds 300
        if (Test-Path $errlog) {
            if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
                Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T77 verdict'
                Stop-Process -Id $app.Pid -Force; exit 1
            }
            Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
        } else {
            Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
        }
    }

    # Zoom the bottom pane: ctrl+shift+enter.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl,shift -Key Enter
    Assert $r "$label zoom chord delivered"
    Start-Sleep -Milliseconds 500
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    $vis = @($panes | Where-Object Visible)
    Assert ($vis.Count -eq 1 -and $vis[0].Hwnd -eq $B.Hwnd) "$label zoomed: only pane B visible"

    # Navigate up out of the zoom: ctrl+alt+up.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl,alt -Key Up
    Assert $r "$label nav chord delivered"
    Start-Sleep -Milliseconds 500
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    $vis = @($panes | Where-Object Visible)

    if ($expectZoomFollows) {
        Assert ($vis.Count -eq 1 -and $vis[0].Hwnd -eq $A.Hwnd) "$label zoom FOLLOWED navigation: only pane A visible"
    } else {
        Assert ($vis.Count -eq 2) "$label zoom CLEARED on navigation: both panes visible"
    }
    Assert (Wait-TestFocus -Window $top -Expected $A.Hwnd) "$label focus is on pane A"
    $focusedHwnd = Get-TestFocusedWindow -Window $top
    $focused = $panes | Where-Object { $_.Hwnd -eq $focusedHwnd }
    Assert ($focused -and $focused.Visible) "$label focused pane is VISIBLE (the T77 bug)"

    Assert (-not ($app.Process -and $app.Process.HasExited)) "$label no crash"
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. This is the complaint T211 exists to fix, asserted.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    # -NegativeControl inverts run 1's expectation, so a passing run proves the
    # assertion still discriminates rather than being true of everything.
    $run1Follows = [bool]$NegativeControl
    if ($NegativeControl) { Write-Host 'NEGATIVE CONTROL: run 1 asserts zoom FOLLOWS navigation - this run MUST fail' }
    Run-Case 'default' @() $run1Follows $true
    $launched += $script:GhozttyTestDesktopPids
    Run-Case 'navigation' @('--split-preserve-zoom=navigation') $true $false
    $launched += $script:GhozttyTestDesktopPids
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop"
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
