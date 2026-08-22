# T74 acceptance: unfocused split panes are dimmed by a layered overlay
# honoring `unfocused-split-opacity` and `unfocused-split-fill`.
#
# The win32 apprt shows a click-through WS_EX_LAYERED popup
# (class GhozttyDimOverlay) over every unfocused pane of the active tab's
# split, filled with unfocused-split-fill (default: background color) at
# alpha = (1 - unfocused-split-opacity) * 255 (Mac parity).
#
# Three GUI launches:
#   run 1 (defaults,         split -> exactly one overlay, over the
#          background #101014) unfocused pane, alpha 77 (opacity 0.7),
#                            click-through ex-style, and the overlay PAINTS
#                            the background color; focus flip moves the
#                            overlay to the other pane; zoom hides all
#                            overlays, unzoom restores.
#   run 2 (opacity=1):       feature off -> no overlay ever visible.
#   run 3 (opacity=0.5,      alpha 128, and the overlay paints #ff0000.
#          fill=#ff0000,
#          background=#000)
#
# T225: runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground - asserted here, not assumed.
#
# THE BLEND ASSERTION, and what replaced it (T214 route 1, decided here).
# Run 3 used to sample the COMPOSITED SCREEN with GetDC(NULL)+GetPixel at the
# dimmed pane's centre and assert "red-tinted". There is no composited screen
# off the input desktop (CAPTURE LIMIT), so that oracle had to be re-expressed
# rather than ported. It is NOT a terminal-content probe, which is why route 1
# applies and route 3/4 was not needed: the dim overlay is its own top-level
# window and the app's GUI thread paints it with a solid GDI brush
# (DimOverlay.zig's WM_PAINT/WM_ERASEBKGND FillRect), so PrintWindow reads the
# real fill. Measured on the test desktop 2026-08-01: the overlay captures as
# 255,0,0 under `--unfocused-split-fill=#ff0000` and as 16,16,20 under a
# defaulted fill with `--background=#101014`.
#
# WHAT THE SUBSTITUTE DOES NOT COVER, named rather than quietly dropped: DWM's
# composite of that fill at that alpha over the pane underneath - i.e. what the
# user's eye actually sees. The two INPUTS to the composite are both asserted
# (the painted fill here, the alpha from GetLayeredWindowAttributes), the
# blending of them is Windows' own and is not app logic. The old screen-pixel
# check was in fact the weaker statement of the two: it only asked whether the
# centre pixel leaned red, where this pins the exact configured color.
#
# A uniform fill is 1 distinct color by design, so Get-TestDistinctColors is no
# guard here. The guard is that the SAME probe reads two DIFFERENT colors under
# two different configs (run 1: 16,16,20 / run 3: 255,0,0) - it tracks the
# config rather than passing against a constant - and -NegativeControl inverts
# run 3's expectation to prove it can fail.
#
# Focus lands via the T48 deferred-SetFocus path, so assertions poll.
# A positive control (ctrl+k clear_screen, T55 pattern) runs first in run 1
# so an injection failure aborts instead of reading as a T74 regression.
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
$env:GHOZTTY_PIPE_SUFFIX = '-dimtest'
$errlog = Join-Path $env:TEMP 'ghoztty-split-dim-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The AGENT too (T248): +new-window/+split are idempotent against a PERSISTED
# session, and killing ghoztty.exe does not remove one, so from the second run
# onward a surviving agent would hand this run last run's windows.
function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# Same left/top/right/bottom within a small DPI/rounding slack.
function Rects-Match($a, $b, [int]$slack = 2) {
    ([math]::Abs($a.Left - $b.Left) -le $slack) -and
    ([math]::Abs($a.Top - $b.Top) -le $slack) -and
    ([math]::Abs($a.Right - $b.Right) -le $slack) -and
    ([math]::Abs($a.Bottom - $b.Bottom) -le $slack)
}

function Get-Overlays([int]$procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyDimOverlay')
}

# Poll until exactly one visible overlay covers $pane (T48 defers focus, so
# the flip lands asynchronously). Returns the overlay list at success/timeout.
function Wait-OverlayOver([int]$procId, $pane) {
    for ($t = 0; $t -lt 25; $t++) {
        $ov = @(Get-Overlays $procId | Where-Object Visible)
        if ($ov.Count -eq 1 -and (Rects-Match $ov[0] $pane)) { return $ov }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "DEBUG wait timeout: want pane $($pane.Left),$($pane.Top),$($pane.Right),$($pane.Bottom)"
    Get-Overlays $procId | ForEach-Object {
        Write-Host "DEBUG raw overlay: $($_.Hwnd) vis=$($_.Visible) $($_.Left),$($_.Top),$($_.Right),$($_.Bottom)"
    }
    return @(Get-Overlays $procId | Where-Object Visible)
}

# The overlay's OWN painted fill, as "r,g,b" - see the header. $null if the
# capture fails, so the caller can report that rather than score a guess.
#
# SYNCHRONOUS (T943), and this window is the case that route exists for: the
# overlay is WS_EX_LAYERED, which is exactly the shape whose DWM copy tore in
# T835 (one unchanged banner row read 1062 / 1283 / 1179 px across three
# back-to-back captures). Under WM_PRINTCLIENT the overlay paints its own fill
# into our DC before the call returns. The route throws on a window that drew
# nothing rather than returning a blank frame, so a capture taken between the
# overlay becoming visible and its first paint is RETRIED here instead of
# scored as "the overlay painted nothing".
function Get-OverlayFill($overlay) {
    $h = [IntPtr]$overlay.Hwnd
    for ($t = 0; $t -lt 10; $t++) {
        $shot = $null
        try {
            $shot = Get-TestWindowPixels -Window $h -Sync
            $cx = [int](($overlay.Left + $overlay.Right) / 2)
            $cy = [int](($overlay.Top + $overlay.Bottom) / 2)
            $c = Get-TestPixel -Shot $shot -X $cx -Y $cy
            if (-not $c) { return $null }
            return "$($c.R),$($c.G),$($c.B)"
        } catch {
            if ($t -eq 9) {
                Write-Host "DEBUG overlay capture failed: $_"
                return $null
            }
            Start-Sleep -Milliseconds 150
        } finally {
            if ($shot) { Close-TestWindowPixels -Shot $shot }
        }
    }
    return $null
}

function Start-Gui([string]$label, [string[]]$extraArgs, [bool]$control) {
    Stop-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }
    # --session-persistence=false is mandatory, not optional: this script
    # launches a GUI per section, and each launch WRITES a session-layout
    # manifest that the NEXT launch would restore - so section 2 came up with
    # section 1's panes and "2 visible panes" failed. Same trap T131 fixed for
    # pane-banner.ps1's bw window (found again here 2026-07-29 during T155).
    $sp = @{ Exe = $exe; Arguments = (@('--session-persistence=false') + $extraArgs) }
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
    if ($panes.Count -ne 2) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    [pscustomobject]@{ App = $app; Top = $top; Panes = $panes }
}

Stop-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. This is the complaint T211 exists to fix, asserted.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: run 3 asserts the overlay paints the DEFAULT background instead of the configured fill - this run MUST fail'
    }

    # -----------------------------------------------------------------------
    # Run 1: defaults (opacity 0.7 -> alpha 77, fill = background).
    # The background is pinned so the "fill defaults to the background color"
    # half is an exact color, and so it differs from run 3's fill.
    # -----------------------------------------------------------------------
    $g = Start-Gui 'default' @('--background=#101014') $true
    $app = $g.App; $top = $g.Top
    $launched += $script:GhozttyTestDesktopPids
    $A = $g.Panes | Sort-Object Top | Select-Object -First 1   # top pane
    $B = $g.Panes | Sort-Object Top | Select-Object -Last 1    # bottom pane (focused after split)

    # Positive control: ctrl+k reaches binding dispatch (debug log only).
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl -Key K
    if (-not $r) { Write-Host 'ABORT: control chord not sent'; Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    Start-Sleep -Milliseconds 300
    if (Test-Path $errlog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T74 verdict'
            Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # @() wraps: PS 5.1 unrolls a one-element function return to a scalar
    # pscustomobject, which has no intrinsic .Count.
    $ov = @(Wait-OverlayOver $app.Pid $A)
    Assert ($ov.Count -eq 1) "default: exactly one visible dim overlay ($($ov.Count))"
    if ($ov.Count -eq 1) {
        Assert (Rects-Match $ov[0] $A) "default: overlay covers the UNFOCUSED (top) pane"
        Assert (-not (Rects-Match $ov[0] $B)) "default: overlay does not cover the focused pane"
        $la = Get-TestLayeredAttrs -Window ([IntPtr]$ov[0].Hwnd)
        Assert ($la.Ok -and $la.Alpha -eq 77) "default: layered alpha is 77 = (1-0.7)*255 (got $($la.Alpha))"
        $ex = Get-TestWindowStyle -Window ([IntPtr]$ov[0].Hwnd) -ExStyle
        # WS_EX_LAYERED(0x80000) + WS_EX_TRANSPARENT(0x20) + WS_EX_NOACTIVATE(0x8000000)
        Assert (($ex -band 0x80000) -ne 0) "default: overlay is WS_EX_LAYERED"
        Assert (($ex -band 0x20) -ne 0) "default: overlay is WS_EX_TRANSPARENT (click-through)"
        Assert (($ex -band 0x8000000) -ne 0) "default: overlay is WS_EX_NOACTIVATE"
        # The fill DEFAULTS to the background color, pinned exactly. Paired
        # with run 3's #ff0000 this is what proves the capture tracks config.
        $fill = Get-OverlayFill $ov[0]
        Assert ($fill -eq '16,16,20') "default: overlay paints the background color #101014 (got $fill)"
    }

    # Focus flip: ctrl+alt+up focuses pane A -> overlay must move to pane B.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl,alt -Key Up
    Assert $r "default: goto-up chord delivered"
    $ov = @(Wait-OverlayOver $app.Pid $B)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $B)) "default: focus flip moved the overlay to pane B"

    # Zoom pane A (now focused): overlays must all hide.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$A.Hwnd) -Modifiers ctrl,shift -Key Enter
    Assert $r "default: zoom chord delivered"
    Start-Sleep -Milliseconds 600
    $ov = @(Get-Overlays $app.Pid | Where-Object Visible)
    Assert ($ov.Count -eq 0) "default: zoomed -> no visible overlay ($($ov.Count))"

    # Unzoom: the dim overlay comes back over the unfocused pane B.
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$A.Hwnd) -Modifiers ctrl,shift -Key Enter
    Assert $r "default: unzoom chord delivered"
    $ov = @(Wait-OverlayOver $app.Pid $B)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $B)) "default: unzoom restored the overlay over pane B"

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'default: no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue

    # -----------------------------------------------------------------------
    # Run 2: opacity=1 disables the feature entirely.
    # -----------------------------------------------------------------------
    $g = Start-Gui 'opacity=1' @('--unfocused-split-opacity=1') $false
    $app = $g.App
    $launched += $script:GhozttyTestDesktopPids
    Start-Sleep -Milliseconds 500
    $ov = @(Get-Overlays $app.Pid | Where-Object Visible)
    Assert ($ov.Count -eq 0) "opacity=1: no visible overlay ($($ov.Count))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'opacity=1: no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue

    # -----------------------------------------------------------------------
    # Run 3: custom opacity + fill; verify alpha and the painted fill.
    # -----------------------------------------------------------------------
    $g = Start-Gui 'custom' @('--unfocused-split-opacity=0.5', '--unfocused-split-fill=#ff0000', '--background=#000000') $false
    $app = $g.App
    $launched += $script:GhozttyTestDesktopPids
    $A = $g.Panes | Sort-Object Top | Select-Object -First 1
    $ov = @(Wait-OverlayOver $app.Pid $A)
    Assert ($ov.Count -eq 1) "custom: one visible overlay"
    if ($ov.Count -eq 1) {
        $la = Get-TestLayeredAttrs -Window ([IntPtr]$ov[0].Hwnd)
        Assert ($la.Ok -and $la.Alpha -eq 128) "custom: layered alpha is 128 = (1-0.5)*255 (got $($la.Alpha))"
        # The migrated oracle (see header), so this is what -NegativeControl
        # inverts: if it cannot fail, the migration proved nothing.
        $fill = Get-OverlayFill $ov[0]
        $want = if ($NegativeControl) { '16,16,20' } else { '255,0,0' }
        $script:negReached = $true
        Assert ($fill -eq $want) "custom: overlay paints the configured fill #ff0000 (want $want, got $fill)"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'custom: no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

# The user's actual complaint, asserted rather than assumed. Runs AFTER the
# cleanup, so it reads the surviving all-pids list - the live one is emptied by
# Remove-TestDesktop and would score against nothing (T217 batch 3).
$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

# A -NegativeControl run that never reached the inverted assertion proves
# nothing, and would otherwise report a clean pass.
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
