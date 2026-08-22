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
# Section 3b is the T845 oracle: the same capture taken twelve times over must
# be lit EVERY time and read the SAME value every time. One sample cannot tell a
# reliable seam from a nine-in-ten one, and nine-in-ten is what this was from
# T282 until T845 - the capture asked DWM for a copy of the composited surface,
# which is asynchronous, so about one in ten was a frame from before the hover.
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

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
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
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
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

# ... and the MOMENT is reported too (T845). The app photographs the window
# before the move as well and says whether the move altered a single pixel, so a
# capture that came back un-hovered is a named failure instead of a valid PNG of
# the wrong instant. Asserted here and not only inferred from the pixel probes
# below, because the two are different claims: "these pixels differ from a
# separately-taken rest shot" can be satisfied by two captures of the same
# moment with something else moving, and "the move changed this frame" cannot.
Assert ($hotPlus.Changed) `
    "the capture over the '+' is a frame the move CHANGED, not the resting one (changed=$($hotPlus.Changed))"

# --- 3. THE DISCRIMINATOR: each capture lights ITS OWN control -------------
# -Sync (T835) rather than the default capture: every assertion below is stated
# RELATIVE to this frame, so a torn baseline would move all of them at once.
# That is T941's sweep for the rest of the suite; it is taken here early because
# 3b's stricter oracle is only as trustworthy as the number it compares against.
$rest = Get-TestWindowPixels -Window $top -Sync
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
Assert ($null -ne $hotClose -and $hotClose.Changed) `
    "the capture over the close 'x' is a frame the move CHANGED too (changed=$(if($hotClose){$hotClose.Changed}))"
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

# --- 3b. EVERY capture, not most of them (T845) ----------------------------
# The discriminator above takes ONE hovered capture of each control, and that is
# exactly the shape of assertion T845 slipped through: the capture went through
# `PrintWindow(PW_RENDERFULLCONTENT)`, which is a DWM copy of the composited
# surface and asynchronous, so roughly one capture in ten was of a frame painted
# BEFORE the hover. It reported success and returned a picture; the only thing
# that ever noticed was pane-banner.ps1's fill assertion going red on a build
# where nothing was wrong. A single sample cannot tell a reliable seam from a
# nine-in-ten one, so this samples it repeatedly.
#
# Two oracles, because "lit" alone is the weaker one: every capture must be lit,
# AND they must all read the SAME value. A torn or stale copy shows up in the
# second one even when it happens to catch a lit frame - T835 measured three
# back-to-back captures of an UNCHANGED window disagreeing by 200+ px on where a
# row ended.
$repeatN = 12
$repeatEdges = @()
$repeatFail = 0
$repeatUnchanged = 0
for ($i = 0; $i -lt $repeatN; $i++) {
    $shot = Get-TestHoverCapture -Hwnd $top -X $plusSx -Y $plusSy
    $p = Probe $shot $plusEdgeX $plusCornX
    if ($null -eq $p) { $repeatFail++ } else { $repeatEdges += $p.Edge }
    if ($shot -and -not $shot.Changed) { $repeatUnchanged++ }
    if ($shot) { Close-TestHoverCapture $shot }
}
$repeatDistinct = @($repeatEdges | Sort-Object -Unique)
Write-Host "INFO  repeat hover: $repeatN captures, edges $($repeatDistinct -join '/') (rest=$($restPlus.Edge)), $repeatFail unreadable, $repeatUnchanged unchanged"
Assert ($repeatFail -eq 0 -and $repeatEdges.Count -eq $repeatN) `
    "$repeatN back-to-back hovered captures all came back readable ($repeatFail unreadable)"
Assert ($repeatUnchanged -eq 0) `
    "...and the app reports every one of them as a frame the move CHANGED ($repeatUnchanged came back identical to the un-hovered one)"
Assert ($repeatEdges.Count -gt 0 -and -not ($repeatEdges | Where-Object { $_ -lt ($restPlus.Edge + 8) })) `
    "...and the '+' fill is lit in EVERY one of them, not most (edges $($repeatDistinct -join '/') vs rest=$($restPlus.Edge))"
Assert ($repeatDistinct.Count -eq 1) `
    "...and they all read the SAME value, so the capture is the window's own paint and not a DWM copy of it (distinct: $($repeatDistinct -join '/'))"

# --- 4. The hover does NOT latch -------------------------------------------
# The leave arrives on the next pump, exactly as it does today, so the frame
# after the probe is back at rest. This is the property that makes a capture
# the right shape for this seam: there is no state to leak into the next
# assertion, and no "release" call anyone can forget.
Start-Sleep -Milliseconds 400
$after = Get-TestWindowPixels -Window $top -Sync
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
Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    if ($appPid) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    Kill-RepoInstances
    if ($td) { Remove-TestDesktop $td }
}

# --- stamp (T783, row added by T845) --------------------------------------
# A green run records the content of the capture-hover seam, so
# scripts\guard-due.ps1 can answer "has anybody run this against the code as it
# now stands?". The seam has no in-app symptom when it goes wrong: T845 was a
# capture that returned the UN-hovered frame roughly one run in ten and
# reported success, and what noticed was a DIFFERENT script's fill assertion
# reading a correct build as a dead button. Stamped only on a CLEAN sweep - a
# run with skipped sections proved less than the whole harness claims - and a
# red run leaves the stamp alone on purpose.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    if ($script:skipped -gt 0) {
        Write-Host "  stamp NOT updated: $script:skipped section(s) skipped, so this run did not cover the whole harness"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard hover-capture -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
    }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'hover-capture'
