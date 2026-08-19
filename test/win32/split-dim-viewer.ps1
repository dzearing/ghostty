# T380 acceptance: a VIEWER pane in a split gets the T74 unfocused-split dim
# overlay, exactly like a terminal pane.
#
# T373 gave viewer panes a real host window (class GhozttyViewer); before T380
# the PaneView viewer arm no-opped show/hideDimOverlay, so in a terminal+viewer
# split the terminal dimmed when unfocused and the viewer never did - the
# viewer always read as the active pane.
#
# One GUI launch, defaults pinned (--background=#101014 -> alpha 77, fill
# 16,16,20 - the same numbers split-dim.ps1 run 1 asserts for terminals):
#
#   1. +split --view=<md>: the new viewer pane is focused, so exactly one
#      overlay is visible and it covers the TERMINAL (already true pre-T380;
#      proves the viewer counts as the focused pane).
#   2. Click the terminal: the overlay must MOVE to the viewer host rect
#      (the T380 behavior), with ex-style/alpha/fill matching the terminal
#      overlay's contract.
#   3. Resize the top window: the overlay re-glues to the viewer's new rect
#      (no stale rect after layout).
#   4. Zoom the terminal (ctrl+shift+enter): all overlays hide. Unzoom: the
#      viewer overlay comes back.
#   5. New tab (ctrl+t): all overlays hide (popups do not follow pane
#      visibility for free). Back to tab 1 (ctrl+1): the viewer overlay
#      returns.
#
# Oracles are the migrated T214 route-1 ones (rects + GetLayeredWindowAttributes
# + PrintWindow fill of the overlay's own window): there is no composited screen
# off the input desktop, and the composite of fill+alpha is Windows' own. See
# split-dim.ps1's header for the full argument.
#
# The focus flip is a posted click (Send-TestMouse): the terminal surface's
# WM_LBUTTONDOWN handler defers SetFocus itself (App.zig), so this works on the
# background test desktop where real input does not exist. -NegativeControl
# inverts the step-2 rect assertion to prove the oracle can fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Always isolate the IPC endpoint: the app inherits this env through
# CreateProcessW and so does every `& $exe +...` below, so the user's own
# instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = '-dimviewtest'
$errlog = Join-Path $env:TEMP 'ghoztty-split-dim-viewer-stderr.log'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The AGENT too (T248): +new-window/+split are idempotent against a PERSISTED
# session, and killing ghoztty.exe does not remove one.
function Stop-RepoInstances {
    foreach ($name in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
}

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
# the flip lands asynchronously). $pane may be a live hwnd holder: the rect is
# re-read each poll, so this also serves the resize step.
function Wait-OverlayOverHwnd([int]$procId, [IntPtr]$paneHwnd) {
    for ($t = 0; $t -lt 25; $t++) {
        $rect = Get-TestWindowRect -Window $paneHwnd
        $ov = @(Get-Overlays $procId | Where-Object Visible)
        if ($ov.Count -eq 1 -and $rect -and (Rects-Match $ov[0] $rect)) { return $ov }
        Start-Sleep -Milliseconds 100
    }
    $rect = Get-TestWindowRect -Window $paneHwnd
    if ($rect) { Write-Host "DEBUG wait timeout: want pane $($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom)" }
    Get-Overlays $procId | ForEach-Object {
        Write-Host "DEBUG raw overlay: $($_.Hwnd) vis=$($_.Visible) $($_.Left),$($_.Top),$($_.Right),$($_.Bottom)"
    }
    return @(Get-Overlays $procId | Where-Object Visible)
}

function Wait-NoOverlays([int]$procId) {
    for ($t = 0; $t -lt 25; $t++) {
        $ov = @(Get-Overlays $procId | Where-Object Visible)
        if ($ov.Count -eq 0) { return $ov }
        Start-Sleep -Milliseconds 100
    }
    return @(Get-Overlays $procId | Where-Object Visible)
}

# The overlay's OWN painted fill, as "r,g,b" (split-dim.ps1's migrated oracle,
# synchronous since T943 - the overlay is layered, which is the shape T835's
# torn capture was measured on; a capture taken before its first paint throws
# and is retried rather than scored).
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

Stop-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there (T211, asserted).
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

# The viewed document. Content is irrelevant to the overlay; a real md file
# keeps the pane on the file-mode path with zero network.
$md = Join-Path $env:TEMP 'ghoztty-dim-viewer.md'
Set-Content -Path $md -Value "# Dim overlay fixture`n`nsome text`n" -Encoding ascii

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: step 2 asserts the overlay stays over the TERMINAL after the terminal is focused - this run MUST fail'
    }

    Remove-Item $errlog -ErrorAction SilentlyContinue
    $sp = @{ Exe = $exe; Arguments = @('--session-persistence=false', '--background=#101014') }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'window is NOT enumerable on the interactive desktop'

    & $exe +split --direction=down "--view=$md" | Out-Null
    Start-Sleep -Milliseconds 800
    $terms = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    $views = @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')
    Assert ($terms.Count -eq 1 -and $views.Count -eq 1) `
        "setup: one terminal + one viewer pane (got $($terms.Count)/$($views.Count))"
    if ($terms.Count -ne 1 -or $views.Count -ne 1) {
        Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
    }
    $term = $terms[0]; $view = $views[0]
    $termH = [IntPtr]$term.Hwnd; $viewH = [IntPtr]$view.Hwnd

    # -----------------------------------------------------------------------
    # 1. The viewer is the focused pane after its split (insertPaneAsSplit
    #    makes it the active pane synchronously): the ONE overlay is over the
    #    terminal. MUST run before any Send-TestKeys - the harness delivers
    #    chords via AttachThreadInput+SetFocus on its target, which is itself
    #    a focus flip.
    # -----------------------------------------------------------------------
    $ov = @(Wait-OverlayOverHwnd $app.Pid $termH)
    Assert ($ov.Count -eq 1) "viewer focused: exactly one visible overlay ($($ov.Count))"
    if ($ov.Count -eq 1) {
        Assert (Rects-Match $ov[0] $term) 'viewer focused: overlay covers the TERMINAL pane'
        Assert (-not (Rects-Match $ov[0] $view)) 'viewer focused: overlay does not cover the viewer'
    }

    # Positive control: a chord posted at the terminal reaches binding dispatch
    # (debug log only) - the zoom/tab steps below depend on it. Side effect,
    # relied on by step 2: delivering it focuses the TERMINAL.
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl -Key K
    if (-not $r) { Write-Host 'ABORT: control chord not sent'; Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    Start-Sleep -Milliseconds 300
    if (Test-Path $errlog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T380 verdict'
            Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # -----------------------------------------------------------------------
    # 2. The terminal now has focus: the overlay must have moved to the
    #    VIEWER - the exact gap T380 closes.
    # -----------------------------------------------------------------------
    $ov = @(Wait-OverlayOverHwnd $app.Pid $viewH)
    $script:negReached = $true
    if ($NegativeControl) {
        Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $term)) `
            'NEGATIVE: overlay stays over the terminal after the terminal took focus'
    } else {
        Assert ($ov.Count -eq 1) "terminal focused: exactly one visible overlay ($($ov.Count))"
        if ($ov.Count -eq 1) {
            Assert (Rects-Match $ov[0] $view) 'terminal focused: overlay covers the VIEWER pane (T380)'
            Assert (-not (Rects-Match $ov[0] $term)) 'terminal focused: overlay does not cover the terminal'
            $la = Get-TestLayeredAttrs -Window ([IntPtr]$ov[0].Hwnd)
            Assert ($la.Ok -and $la.Alpha -eq 77) "viewer overlay: layered alpha is 77 = (1-0.7)*255 (got $($la.Alpha))"
            $ex = Get-TestWindowStyle -Window ([IntPtr]$ov[0].Hwnd) -ExStyle
            Assert (($ex -band 0x80000) -ne 0) 'viewer overlay: WS_EX_LAYERED'
            Assert (($ex -band 0x20) -ne 0) 'viewer overlay: WS_EX_TRANSPARENT (click-through)'
            Assert (($ex -band 0x8000000) -ne 0) 'viewer overlay: WS_EX_NOACTIVATE'
            $fill = Get-OverlayFill $ov[0]
            Assert ($fill -eq '16,16,20') "viewer overlay paints the background color #101014 (got $fill)"
        }
    }

    # -----------------------------------------------------------------------
    # 2b. goto_split down (at the terminal) hands focus to the VIEWER through
    #     the T48 deferred-SetFocus path: the host's WM_SETFOCUS is what runs
    #     T380's updateDimOverlays call, so the overlay must flip back to the
    #     terminal. Then a posted click on the terminal flips it again.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl,alt -Key Down
    Assert $r 'goto-down chord delivered'
    $ov = @(Wait-OverlayOverHwnd $app.Pid $termH)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $term)) `
        'goto_split into the viewer: overlay flips back onto the terminal'

    $cx = [int](($term.Left + $term.Right) / 2)
    $cy = [int](($term.Top + $term.Bottom) / 2)
    $r = Send-TestMouse -Window $top -Target $termH -X $cx -Y $cy
    Assert $r 'terminal click delivered'
    $ov = @(Wait-OverlayOverHwnd $app.Pid $viewH)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $view)) `
        'terminal clicked: overlay back over the viewer'

    # -----------------------------------------------------------------------
    # 3. Resize: the overlay re-glues to the viewer's new rect.
    # -----------------------------------------------------------------------
    $topRect = Get-TestWindowRect -Window $top
    $newW = ($topRect.Right - $topRect.Left) - 120
    $newH = ($topRect.Bottom - $topRect.Top) - 80
    Set-TestWindowSize -Window $top -Width $newW -Height $newH | Out-Null
    $ov = @(Wait-OverlayOverHwnd $app.Pid $viewH)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] (Get-TestWindowRect -Window $viewH))) `
        'resize: overlay re-glued to the viewer pane rect'

    # -----------------------------------------------------------------------
    # 4. Zoom the (focused) terminal: overlays hide; unzoom restores.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl,shift -Key Enter
    Assert $r 'zoom chord delivered'
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "zoomed: no visible overlay ($($ov.Count))"
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl,shift -Key Enter
    Assert $r 'unzoom chord delivered'
    $ov = @(Wait-OverlayOverHwnd $app.Pid $viewH)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] (Get-TestWindowRect -Window $viewH))) `
        'unzoom: overlay restored over the viewer'

    # -----------------------------------------------------------------------
    # 5. Tab switch: overlays are popups, so an inactive tab's must be HIDDEN
    #    by updateDimOverlays, not just occluded.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl -Key T
    Assert $r 'new-tab chord delivered'
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "tab 2 active: no visible overlay ($($ov.Count))"
    # Back to tab 1 via ctrl+1, posted at tab 2's (visible) terminal.
    $t2 = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($t2.Count -ge 1) {
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$t2[0].Hwnd) -Modifiers ctrl -Key '1'
        Assert $r 'goto-tab-1 chord delivered'
        $ov = @(Wait-OverlayOverHwnd $app.Pid $viewH)
        Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] (Get-TestWindowRect -Window $viewH))) `
            'tab 1 active again: overlay returns over the viewer'
    } else {
        Assert $false 'tab 2 terminal pane found for the return chord'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $md -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
