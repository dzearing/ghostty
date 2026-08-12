# T282 acceptance: the debug-only `capture-hover` IPC action - painting and
# capturing a HOVERED frame off the background test desktop.
#
# WHAT IS BEING PROVED, and why it needs proving. A posted WM_MOUSEMOVE cannot
# survive to the paint it dirties on a desktop with no real cursor: the OS
# posts WM_MOUSELEAVE within a frame (TrackMouseEvent watches the real one) and
# WM_PAINT is the lowest-priority message in the queue, so the leave is drained
# FIRST and the painted frame is the un-hovered one. T209 measured 300 posted
# moves in bursts of 25, interleaved with captures, and never once caught a lit
# fill. So every hover FILL in the win32 chrome was a SKIP (tab-strip's 4c,
# pane-banner's 6g) or a per-site workaround through a state that survives a
# leave (split-divider's DRAG, caption-bar's caption_pressed).
#
# The action moves the whole probe into the app's GUI thread, where hit test,
# move, repaint and capture all happen on ONE stack with no return to the
# message loop - and a posted message is only ever drained by the message loop.
# See src/apprt/win32/ipc_hover.zig for the ordering argument.
#
# THE LOAD-BEARING ORACLE IS SECTION 3, and it is deliberately not "a hovered
# capture is brighter somewhere". TWO controls are probed from TWO captures:
# hovering the "+" must light the "+"'s fill and leave the tab's close "x"
# dark, and hovering the "x" must light the "x"'s and leave the "+"'s dark.
# Nothing that captured an un-hovered frame, a latched hover, or a flat fill
# can produce both of those right answers.
#
# Section 4 asserts the other half of the design: the hover does NOT latch. The
# leave arrives on the next pump exactly as it does today, so a plain capture
# right after a hover capture reads the control at REST - which is what makes
# this a capture rather than a "suppress the leave" flag with a stuck-lit
# failure mode.
#
# -NegativeControl expects the "+" to be lit in the capture taken over the "x",
# which MUST fail: that is exactly the answer a latched or wrongly-attributed
# hover would give, so a green negative control means section 3 discriminates
# nothing.
#
# Runs on the BACKGROUND test desktop and never takes the user's foreground.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolated endpoint: every oracle here is an IPC probe, and both ends inherit
# this (the CLI from this shell, the GUI through the harness's CreateProcessW),
# so they address THIS run's instance and nothing else on the box.
$env:GHOZTTY_PIPE_SUFFIX = '-hovertest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
. (Join-Path $PSScriptRoot 'lib\HoverCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

Kill-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0

try {

# persistence: --session-persistence=false. A restored pane would give this run
# a window it never created, and every rect below comes from that window (T248).
$app = Start-OnTestDesktop -Exe $exe -Arguments @(
    '--config-default-files=false',
    '--background=#000000',
    '--window-show-tab-bar=always',
    '--session-persistence=false')
$appPid = [int]$app.Pid
Start-Sleep -Seconds 4
if ($app.Process -and $app.Process.HasExited) {
    Write-TestAssertedNothing -Reason 'GUI died at launch' -Label 'hover-capture'
}
$top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
if ($top -eq [IntPtr]::Zero) {
    Write-TestAssertedNothing -Reason 'launch window never appeared' -Label 'hover-capture'
}
# Sized for the same reason tab-strip.ps1 sizes: every rect below is a position
# in the tab run, and the run is a function of the client width. Inheriting
# whatever window_placement-debug remembered makes the fixture depend on run
# order (T267).
Set-TestWindowSize -Window $top -Width 1400 -Height 800 | Out-Null
Start-Sleep -Milliseconds 1200

if (-not (Test-HoverCaptureAvailable)) {
    # A release build compiles the seam out and answers "unknown action" - a
    # legitimate skip, but it must be VISIBLE in the verdict (T219) and it must
    # not be scored as a pass (T271).
    Write-TestAssertedNothing -Reason 'capture-hover is not in this build (release?)' -Label 'hover-capture'
}

Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
    'GUI is NOT enumerable on the interactive desktop'

# -StripVisible $true: launched --window-show-tab-bar=always, so since T205 the
# strip lives IN the caption row and starts at client y = 0.
$m = Get-TestChromeMetrics -Window $top -StripVisible $true
$strip = Get-TestStripRegions -Window $top -Exe $exe
if ($null -eq $strip -or $null -eq $strip.NewTab -or @($strip.Tabs).Count -lt 1 -or $null -eq $strip.Tabs[0]) {
    Write-TestAssertedNothing -Reason 'the window reports no laid-out tab strip' -Label 'hover-capture'
}

# The two controls, as the APP publishes them (T231) rather than as a second
# copy of tab_strip_layout in PowerShell.
#   "+"  - its whole hit box is the button.
#   "x"  - the close box inside tab 0, the same derivation tab-strip.ps1 uses:
#          one 28 DIP square inset from the tab's right edge by pad + hit_pad.
$plusHit = $strip.NewTab
$tab0 = $strip.Tabs[0]
$closeL = $tab0.Right - $m.PadSm - $m.BtnPaint - $m.BtnPad
$closeR = $tab0.Right - $m.PadSm + $m.BtnPad
$closeCx = [int][Math]::Truncate(($closeL + $closeR) / 2)

# PAINTED squares (client x), which is what the fill lives in. `fillRegion`
# insets the painted square by 2 DIP and rounds it by 4, so two probes per
# control: the fill's top EDGE at its horizontal center (lit, clear of the
# centered mark) and its top-left CORNER pixel (cut away by the radius, so it
# stays background - that is what separates a rounded fill from a square one).
$inset = Get-TestChromeDip -Dip 2.0 -Scale $m.Scale
$sqTop = $m.StripBtnTop                       # strip-local top of the square
$btnCy = $sqTop + [int]($m.BtnPaint / 2)      # strip-local center row

$plusCx = $plusHit.Left + [int]($m.BtnPaint / 2)
$plusSqL = $plusHit.Left
$closeSqL = $closeCx - [int][Math]::Truncate($m.BtnPaint / 2)

# Screen points to hover (what the action takes) ...
$plusSx = $m.ClientLeft + $plusHit.CenterX
$plusSy = $m.ClientTop + $plusHit.CenterY
$closeSx = $m.ClientLeft + $closeCx
$closeSy = $m.ClientTop + $btnCy
# ... and bitmap indices to probe (what a window-rect capture is indexed by).
$plusEdgeX = $m.OffX + $plusCx
$plusCornX = $m.OffX + $plusSqL + $inset
$closeEdgeX = $m.OffX + $closeCx
$closeCornX = $m.OffX + $closeSqL + $inset
$edgeY = $m.StripTop + $sqTop + $inset + 1
$cornY = $m.StripTop + $sqTop + $inset

function Probe($shot, [int]$edgeX, [int]$cornX) {
    if ($null -eq $shot) { return $null }
    if ((Get-TestDistinctColors -Shot $shot) -lt 8) { return $null }
    $e = $shot.Bitmap.GetPixel($edgeX, $edgeY)
    $c = $shot.Bitmap.GetPixel($cornX, $cornY)
    return [pscustomobject]@{ Edge = [int]$e.R; Corner = [int]$c.R }
}

# --- 1. The mechanism: a hovered capture comes back as a real image --------
$hotPlus = Get-TestHoverCapture -Hwnd $top -X $plusSx -Y $plusSy
Assert ($null -ne $hotPlus) "capture-hover returns an image ($(Get-LastHoverCaptureError))"
if ($null -eq $hotPlus) {
    Write-TestVerdict -Pass $script:pass -Fail ($script:fail + 1) -Skipped $script:skipped -Label 'hover-capture'
}
$wr = Get-TestWindowRect -Window $top
Assert ($hotPlus.Bitmap.Width -eq $hotPlus.Width -and $hotPlus.Bitmap.Height -eq $hotPlus.Height) `
    "decoded PNG matches the reported size ($($hotPlus.Bitmap.Width)x$($hotPlus.Bitmap.Height) vs $($hotPlus.Width)x$($hotPlus.Height))"
Assert ($hotPlus.Width -eq $wr.Width -and $hotPlus.Height -eq $wr.Height) `
    "the capture is the WINDOW rect, like Get-TestWindowPixels ($($hotPlus.Width)x$($hotPlus.Height) vs $($wr.Width)x$($wr.Height))"
Assert ((Get-TestDistinctColors -Shot $hotPlus) -ge 8) `
    "the capture has real chrome in it ($(Get-TestDistinctColors -Shot $hotPlus) distinct colors)"

# --- 2. The ROUTE is reported, and it is the client one for the strip ------
# A probe that landed on the wrong route and a probe that landed on a control
# which did not light look identical in pixels, so the route is asserted rather
# than assumed - the same reason Get-TestMouseRoute exists (T263).
Assert (-not $hotPlus.NonClient) `
    "the '+' routes as CLIENT, so the strip's own WM_MOUSEMOVE hover path is what ran (hit=$($hotPlus.Hit))"

# --- 3. THE DISCRIMINATOR: each capture lights ITS OWN control -------------
$rest = Get-TestWindowPixels -Window $top
$restPlus = Probe $rest $plusEdgeX $plusCornX
$restClose = Probe $rest $closeEdgeX $closeCornX
Close-TestWindowPixels $rest
if ($null -eq $restPlus -or $null -eq $restClose) {
    Write-TestAssertedNothing -Reason 'the resting capture had no chrome to measure' -Label 'hover-capture'
}

$pPlusHot = Probe $hotPlus $plusEdgeX $plusCornX
$pCloseWhilePlus = Probe $hotPlus $closeEdgeX $closeCornX

$hotClose = Get-TestHoverCapture -Hwnd $top -X $closeSx -Y $closeSy
Assert ($null -ne $hotClose) "capture-hover returns an image over the close x ($(Get-LastHoverCaptureError))"
$pCloseHot = Probe $hotClose $closeEdgeX $closeCornX
$pPlusWhileClose = Probe $hotClose $plusEdgeX $plusCornX

Write-Host ("INFO  fills: + rest=$($restPlus.Edge) hot=$(if($pPlusHot){$pPlusHot.Edge}) " +
            "otherhover=$(if($pPlusWhileClose){$pPlusWhileClose.Edge}); " +
            "x rest=$($restClose.Edge) hot=$(if($pCloseHot){$pCloseHot.Edge}) " +
            "otherhover=$(if($pCloseWhilePlus){$pCloseWhilePlus.Edge})")

Assert ($null -ne $pPlusHot -and $pPlusHot.Edge -ge ($restPlus.Edge + 8)) `
    "hovering the '+' lights its FILL in the captured frame (rest=$($restPlus.Edge) hot=$(if($pPlusHot){$pPlusHot.Edge}))"
Assert ($null -ne $pPlusHot -and $pPlusHot.Corner -lt ($pPlusHot.Edge - 5)) `
    "that fill is ROUNDED - its corner is cut away (corner=$(if($pPlusHot){$pPlusHot.Corner}) edge=$(if($pPlusHot){$pPlusHot.Edge}))"
Assert ($null -ne $pCloseHot -and $pCloseHot.Edge -ge ($restClose.Edge + 8)) `
    "hovering the close 'x' lights ITS fill (rest=$($restClose.Edge) hot=$(if($pCloseHot){$pCloseHot.Edge}))"

if ($NegativeControl) {
    # MUST fail: this is the answer a latched hover, a wrongly-attributed one,
    # or a capture of the wrong frame would give.
    Assert ($null -ne $pPlusWhileClose -and $pPlusWhileClose.Edge -ge ($restPlus.Edge + 8)) `
        "NEGATIVE CONTROL: the '+' is lit in the capture taken over the 'x' (edge=$(if($pPlusWhileClose){$pPlusWhileClose.Edge}))"
} else {
    Assert ($null -ne $pPlusWhileClose -and $pPlusWhileClose.Edge -lt ($restPlus.Edge + 8)) `
        "the '+' stays DARK while the 'x' is the hovered one (edge=$(if($pPlusWhileClose){$pPlusWhileClose.Edge}) rest=$($restPlus.Edge))"
    Assert ($null -ne $pCloseWhilePlus -and $pCloseWhilePlus.Edge -lt ($restClose.Edge + 8)) `
        "the 'x' stays DARK while the '+' is the hovered one (edge=$(if($pCloseWhilePlus){$pCloseWhilePlus.Edge}) rest=$($restClose.Edge))"
}

# --- 4. The hover does NOT latch -------------------------------------------
# The leave arrives on the next pump, exactly as it does today, so the frame
# after the probe is back at rest. This is the property that makes a capture
# the right shape for this seam: there is no state to leak into the next
# assertion, and no "release" call anyone can forget.
Start-Sleep -Milliseconds 400
$after = Get-TestWindowPixels -Window $top
$pAfter = Probe $after $plusEdgeX $plusCornX
Close-TestWindowPixels $after
Assert ($null -ne $pAfter -and $pAfter.Edge -lt ($restPlus.Edge + 8)) `
    "the hover is gone by the next frame - nothing latched (edge=$(if($pAfter){$pAfter.Edge}) rest=$($restPlus.Edge))"

# --- 5. Every failure names a different state ------------------------------
$nope = Join-Path $env:TEMP 'ghoztty-hover-nope.png'
Remove-Item $nope -ErrorAction SilentlyContinue

$noHwnd = Invoke-GhozttyIpc -Action 'capture-hover' -Arguments @('--x=1', '--y=1', "--path=$nope")
Assert ($noHwnd -and -not $noHwnd.success -and "$($noHwnd.error)" -like '*--hwnd*') `
    "a missing --hwnd says so (got '$(if ($noHwnd) { $noHwnd.error } else { 'no response' })')"

$noPath = Invoke-GhozttyIpc -Action 'capture-hover' -Arguments @("--hwnd=$([int64]$top)", '--x=1', '--y=1')
Assert ($noPath -and -not $noPath.success -and "$($noPath.error)" -like '*--path is required*') `
    "a missing --path says so (got '$(if ($noPath) { $noPath.error } else { 'no response' })')"

$noXy = Invoke-GhozttyIpc -Action 'capture-hover' -Arguments @("--hwnd=$([int64]$top)", "--path=$nope")
Assert ($noXy -and -not $noXy.success -and "$($noXy.error)" -like '*--x and --y*') `
    "missing coordinates say so (got '$(if ($noXy) { $noXy.error } else { 'no response' })')"

$notWin = Invoke-GhozttyIpc -Action 'capture-hover' -Arguments @('--hwnd=1', '--x=1', '--y=1', "--path=$nope")
Assert ($notWin -and -not $notWin.success -and "$($notWin.error)" -like '*is not a window*') `
    "a handle that is not a window says so (got '$(if ($notWin) { $notWin.error } else { 'no response' })')"

# A window belonging to some OTHER process must be refused rather than probed:
# the ordering guarantee is "sender and target share a thread", and a foreign
# window shares neither. It has to be a REAL window in another process - a
# made-up handle is refused as "not a window" long before the ownership check
# runs, and so is a window on the interactive desktop (handles do not reach
# across desktops), so neither would test this guard at all.
$foreignHwnd = New-TestForeignWindow
if ($foreignHwnd -eq [IntPtr]::Zero) {
    Write-Host 'SKIP  foreign-window refusal: could not create a harness-owned window'
    $script:skipped++
} else {
    $foreign = Invoke-GhozttyIpc -Action 'capture-hover' -Arguments @(
        "--hwnd=$([int64]$foreignHwnd)", '--x=1', '--y=1', "--path=$nope")
    Assert ($foreign -and -not $foreign.success -and "$($foreign.error)" -like '*not to this app*') `
        "another process's window is refused (got '$(if ($foreign) { $foreign.error } else { 'no response' })')"
    [void](Remove-TestForeignWindow -Window $foreignHwnd)
}

Assert (-not (Test-Path $nope)) 'a refused capture writes no file'

Close-TestHoverCapture $hotPlus
if ($hotClose) { Close-TestHoverCapture $hotClose }

# --- 6. The run never took the user's foreground ---------------------------
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "the user's foreground was never taken ($($leaked -join ', '))"

} finally {
    if ($appPid) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    Kill-RepoInstances
    if ($td) { Remove-TestDesktop $td }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'hover-capture'
