# T211 acceptance: the shared test-desktop harness itself.
#
# test/win32/lib/TestDesktop.ps1 is what every other GUI acceptance script is
# about to depend on (T212/T213), so it needs its own coverage: a harness that
# silently stops delivering input or silently captures a blank bitmap would
# turn the whole suite green for the wrong reason.
#
# Each mechanism the harness replaces is exercised end-to-end against a real
# ghoztty on a background desktop, and asserted by OUTCOME read back over IPC
# or from the window tree - never by "the call returned true":
#
#   desktop     the window exists on the test desktop and is NOT enumerable on
#               the interactive one, and nothing we launch ever takes
#               foreground there (the user's actual complaint).
#   coords      both Get-TestWindowRect forms are SCREEN space - including
#               -Client, which picks the client RECTANGLE and still returns it
#               positioned on screen - and it is the same space the input
#               takes. T327 (2026-08-20): that was the unwritten assumption
#               under every click in the suite, stated only inside the C#
#               body. Parked off the screen origin with a negative control,
#               so a 0,0-based rect would turn it red.
#   focus       Focus-TestWindow, which replaces the T86 GrabForeground that
#               cannot work off the input desktop.
#   activation  (T568) Set-TestActiveWindow / Clear-TestActiveWindow - the WRITE
#               side of activation, which the harness had no form of at all: it
#               could read who was active but never move it, so "chrome X shows
#               only while this window has the keyboard" was assertable in one
#               direction only. Both shapes are exercised - nobody holding it
#               (focus really reads back 0) and a sibling top-level holding it -
#               and both are read off the input queue, never off a return value.
#   text        Send-TestText into a terminal -> the characters appear in
#               +read, exactly once (posting WM_CHAR as well as WM_KEYDOWN
#               doubles every character; the T207 spike hit that).
#   chords      Send-TestKeys ctrl+shift+t -> a second tab in +list.
#   controls    Send-TestControlText/Key into the rename dialog's EDIT, which
#               is the OPPOSITE convention (standard controls need WM_CHAR,
#               and nothing translates a posted message) -> the window title
#               changes.
#   capture     Get-TestWindowPixels via PrintWindow(PW_RENDERFULLCONTENT),
#               the only capture that survives off the input desktop.
#   limit       and where that capture STOPS: the GhozttyTerminal surface.
#               T214 (2026-08-01) turned the header's prose into three
#               measured assertions - the guard refuses it by class, the
#               forced capture is a flat fill, and the fill does not move when
#               the pane renders. The last two are the negative control for
#               the first: without them the refusal is a superstition.
#               T275 (2026-08-11) added a fourth, and it is a PAIR with those:
#               route 0 (`capture-pane`, the app reading back its own
#               renderer) captures the SAME pane at the SAME moment and sees
#               the text. The limit is unrepealed; what changed is that there
#               is now somewhere to send a probe that hits it.
#               T303 (2026-08-20) widened the guard past the one class it knew:
#               PrintWindow sees GDI, not composition, so EVERY WinUI/XAML
#               window (Task Manager measured flat black 1379x1134, 1 color,
#               reported success) captures as nothing. Three more assertions -
#               the bitmap-level refusal fires on a known-flat surface, its
#               message names the cause and the opt-out, and real chrome still
#               sails through, which is the half that keeps a stricter guard
#               from being a broken one.
#
# `-NegativeControl` inverts the three T303 assertions and the class refusal
# beside them; that run must FAIL. Without it the guards are a superstition -
# an assertion that cannot be made to fail proves nothing about the code it
# claims to cover.
#
# The capture assertion carries its own negative control: the SAME probe runs
# against a light-chrome window and a dark-chrome one and must separate them.
# A blank or stale bitmap cannot pass both.
#
# T213 (2026-08-01): that control used to flip `--window-theme=light|dark`,
# and it stopped separating anything. Since T254/T205 the caption band is
# CLIENT-painted by us and derives from `background` (+20 per channel), not
# from the DWM caption `window-theme` used to restyle - so both halves read the
# SAME meanLum 65-71. Note how it failed: the light half went red while the
# dark half stayed GREEN on the identical pixels, because 71 satisfies "< 100".
# A two-sided control is only a control if both sides are asserted against the
# separation, so the halves now assert the gap between them as well.
# Whether `window-theme` SHOULD still reach the caption is a product question,
# filed as T273 - not something this harness gets to decide by measuring.
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
$env:GHOZTTY_PIPE_SUFFIX = "-harnesstest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

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

function Get-Tree {
    $raw = & $exe +list --json 2>$null
    if (-not $raw) { return $null }
    try { return ($raw -join "`n") | ConvertFrom-Json } catch { return $null }
}

function Get-TabCount {
    $j = Get-Tree
    if (-not $j) { return -1 }
    return @($j.data.windows[0].tabs).Count
}

# Mean luminance of the window's CAPTION band, via the harness's only working
# capture path. The caption on purpose: PrintWindow on a background desktop
# returns GDI-painted chrome and NOT the OpenGL terminal surface (see the
# harness header), so a probe aimed at the terminal would read a flat fill and
# "pass" against nothing. Since T254 that band is ours, not DWM's, which is
# exactly why it is capturable at all.
function Measure-TitlebarLuminance([IntPtr]$Window) {
    $shot = Get-TestWindowPixels -Window $Window
    try {
        # Parenthesised: in a PowerShell array literal the comma binds tighter
        # than `+`, so unbracketed arithmetic concatenates arrays instead.
        $r = @(($shot.Left + 6), ($shot.Top + 6), ($shot.Left + $shot.Width - 6), ($shot.Top + 34))
        return Get-TestBrightness -Shot $shot -Rect $r -Inset 0 -Step 2
    } finally { Close-TestWindowPixels $shot }
}

# ---------------------------------------------------------------------
# Z. the capability declaration (T1100).
#
# Everything above is about what the background desktop CAN do. This section
# is about the harness saying, before a run starts, what it CANNOT - so a
# script whose oracle needs composited pixels or real input reports a SKIP
# naming the missing capability instead of a red the product has to answer
# for. The T1094 sweep produced a cluster of exactly those reds.
#
# Run BEFORE the desktop is created: these are answers about a desktop, not
# calls into one, and the section must not depend on the fixture below it.
# ---------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'lib\DesktopCapability.ps1')
Write-Host ''
Write-Host '-- Z. desktop capability declaration'

$capBg = @{}
foreach ($n in @('chrome-pixels', 'surface-pixels', 'screen-pixels', 'real-input', 'foreground')) {
    $capBg[$n] = Get-TestDesktopCapability -Name $n
    Write-Host ("  background/{0,-14} available={1} - {2}" -f $n, $capBg[$n].Available, $capBg[$n].Reason)
}
Assert ($capBg['chrome-pixels'].Available) 'chrome pixels ARE declared available on the background desktop'
# The three the desktop cannot do, each measured elsewhere in this file or in
# test-desktop-spike.ps1. Asserted together because the value of the
# declaration is that it is COMPLETE - one capability quietly reading
# available is how a script scores itself against a flat fill.
Assert (-not $capBg['surface-pixels'].Available) 'surface pixels are declared UNAVAILABLE on the background desktop'
Assert (-not $capBg['screen-pixels'].Available) 'screen pixels are declared UNAVAILABLE on the background desktop'
Assert (-not $capBg['real-input'].Available) 'real input is declared UNAVAILABLE on the background desktop'
Assert (-not $capBg['foreground'].Available) 'a foreground window is declared UNAVAILABLE on the background desktop'
# A refusal with no reason is a refusal nobody can act on: the SKIP line a
# script prints is built out of this text.
Assert (@($capBg.Values | Where-Object { -not $_.Reason }).Count -eq 0) 'every capability answer carries a reason'

# The interactive side is PROBED rather than declared - an input lock can take
# real input away on the input desktop too, which is the second half of the
# sweep's reds ('could not take the foreground').
$capFg = Get-TestDesktopCapability -Name real-input -Interactive
Write-Host ("  interactive/real-input available={0} measured={1} - {2}" -f $capFg.Available, $capFg.Measured, $capFg.Reason)
Assert ($capFg.Measured) 'the interactive answer is MEASURED on the box, not assumed'

# A typo must not read as 'available': a silent answer to a question nobody
# asked is how a probe scores itself green against a capability that does not
# exist.
$capThrew = $false
try { $null = Get-TestDesktopCapability -Name 'not-a-capability' } catch { $capThrew = $true }
Assert $capThrew 'an unknown capability name throws instead of reading available'

# THE DEMONSTRATION THAT THE SKIP PATH FIRES. A capability check that has only
# ever said 'available' is indistinguishable from one that cannot say anything
# else, so the missing case is CONSTRUCTED and the whole exit path is driven in
# a child process - Assert-TestDesktopCapability exits, so it cannot be called
# in-process here.
$capProbe = Join-Path $env:TEMP ("ghoztty-cap-probe-$PID.ps1")
$capOut = Join-Path $env:TEMP ("ghoztty-cap-probe-$PID.log")
Set-Content -LiteralPath $capProbe -Encoding ASCII -Value @(
    ". (Join-Path '$PSScriptRoot' 'lib\DesktopCapability.ps1')",
    'Assert-TestDesktopCapability -Name real-input -Interactive',
    "'REACHED THE END'"
)
# Written flat rather than inside a try/finally: a top-level try with no catch
# is an unwind path to a green verdict (body-complete-audit.ps1 rule D), and the
# only state worth unwinding here is one env var that is cleared on the next
# line but one - while an unwind at this depth kills the script outright, which
# prints no verdict at all.
$env:GHOZTTY_TEST_FORCE_MISSING_CAPS = 'real-input'
$pc = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -Wait `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $capProbe) `
    -RedirectStandardOutput $capOut
Remove-Item Env:GHOZTTY_TEST_FORCE_MISSING_CAPS -ErrorAction SilentlyContinue
$capText = ''
if (Test-Path -LiteralPath $capOut) { $capText = (Get-Content -LiteralPath $capOut -Raw) }
if ($null -eq $capText) { $capText = '' }
Write-Host "  forced-missing probe: exit $($pc.ExitCode) text=$($capText.Trim())"
Assert ($capText -match 'SKIP ALL: real-input is not available here') `
    'a missing capability prints SKIP ALL naming the capability'
# Exit 0 on purpose: nothing failed. The runner scores the LINE, and
# scripts\suite-run.ps1 section S is the other end of this contract.
Assert ($pc.ExitCode -eq 0) "and exits 0 (got $($pc.ExitCode))"
Assert ($capText -notmatch 'REACHED THE END') 'and stops the run rather than carrying on'

# The other half, and the one that keeps the check from being a blanket skip:
# with the capability present the assert is silent and the body runs.
Set-Content -LiteralPath $capProbe -Encoding ASCII -Value @(
    ". (Join-Path '$PSScriptRoot' 'lib\DesktopCapability.ps1')",
    'Assert-TestDesktopCapability -Name chrome-pixels',
    "'REACHED THE END'"
)
$pc2 = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -Wait `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $capProbe) `
    -RedirectStandardOutput $capOut
$capText2 = ''
if (Test-Path -LiteralPath $capOut) { $capText2 = (Get-Content -LiteralPath $capOut -Raw) }
if ($null -eq $capText2) { $capText2 = '' }
Assert (($pc2.ExitCode -eq 0) -and ($capText2 -match 'REACHED THE END') -and ($capText2 -notmatch 'SKIP ALL')) `
    'a capability that IS available lets the run continue, silently'
Remove-Item -LiteralPath $capProbe, $capOut -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------
# C. the capture CONTENT FLOOR (T1128).
#
# Get-TestCaptureContent is what lets a script assert "this is a picture of
# something" instead of discovering months later that its saved screenshot had
# quietly lost two thirds of its bytes. A floor that has only ever been seen
# saying "fine" is indistinguishable from one that cannot say anything else, so
# both sides are constructed here from synthetic bitmaps: no desktop, no app,
# no timing - just the arithmetic, which is the part a caller trusts.
#
# The real committed screenshot is the third case, and the one that matters:
# hero-mode.ps1's floor must clear a window whose terminal glass PrintWindow
# could not read, because that is a documented limit and not a regression.
# ---------------------------------------------------------------------
Write-Host ''
Write-Host '-- C. capture content floor'
Add-Type -AssemblyName System.Drawing
function New-FakeShot($bmp) {
    [pscustomobject]@{ Bitmap = $bmp; Width = $bmp.Width; Height = $bmp.Height; Left = 0; Top = 0 }
}

# The floor is READ OUT OF hero-mode.ps1 rather than restated here. A
# demonstration that carries its own copy of the number stops demonstrating the
# gate the moment somebody tunes the gate.
$heroSrc = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hero-mode.ps1'))
$mD = [regex]::Match($heroSrc, '\$script:shotFloorDistinct\s*=\s*(\d+)')
$mT = [regex]::Match($heroSrc, '\$script:shotFloorTopShare\s*=\s*([\d.]+)')
Assert ($mD.Success -and $mT.Success) 'hero-mode.ps1 still declares the content floor in one place'
$floorD = if ($mD.Success) { [int]$mD.Groups[1].Value } else { 8 }
$floorT = if ($mT.Success) { [double]$mT.Groups[1].Value } else { 0.90 }
Write-Host "  floor read from hero-mode.ps1: $floorD distinct / $floorT top share"
function Test-Floor($c) { return ($c.Distinct -ge $floorD -and $c.TopShare -le $floorT) }

$flat = New-Object System.Drawing.Bitmap 400, 300
$g = [System.Drawing.Graphics]::FromImage($flat)
$g.Clear([System.Drawing.Color]::FromArgb(32, 34, 40)); $g.Dispose()
$flatC = Get-TestCaptureContent -Shot (New-FakeShot $flat)
Write-Host "  flat fill: distinct=$($flatC.Distinct) topShare=$([math]::Round($flatC.TopShare,3))"
Assert ($flatC.Distinct -eq 1 -and $flatC.TopShare -eq 1.0) `
    "a flat fill scores 1 distinct / 1.0 top share (got $($flatC.Distinct) / $($flatC.TopShare))"
Assert (-not (Test-Floor $flatC)) `
    "and is BELOW hero-mode.ps1's floor of $floorD distinct / $([math]::Round($floorT * 100))% top share (the gate fires)"

# NEAR-uniform rather than uniform, and this is the case the whole floor is
# for: three small blocks of color on an otherwise flat field. That is enough
# for Test-TestCaptureUniform to answer "not uniform" - it asks only whether
# every sample MATCHES - so the binary check passes it through, and only a
# measure of HOW MUCH is there catches it.
$near = New-Object System.Drawing.Bitmap 400, 300
$g = [System.Drawing.Graphics]::FromImage($near)
$g.Clear([System.Drawing.Color]::FromArgb(32, 34, 40))
$i = 0
foreach ($c in @([System.Drawing.Color]::Red, [System.Drawing.Color]::Lime, [System.Drawing.Color]::Blue)) {
    $br = New-Object System.Drawing.SolidBrush $c
    $g.FillRectangle($br, (20 + $i * 90), 40, 34, 34)
    $br.Dispose()
    $i++
}
$g.Dispose()
$nearShot = New-FakeShot $near
$nearC = Get-TestCaptureContent -Shot $nearShot
Write-Host "  near-uniform: distinct=$($nearC.Distinct) topShare=$([math]::Round($nearC.TopShare,3))"
Assert (-not (Test-TestCaptureUniform -Shot $nearShot)) `
    'the binary uniform check passes a near-uniform capture through (which is why the floor exists)'
Assert (-not (Test-Floor $nearC)) `
    "and the content floor still fires on it ($($nearC.Distinct) distinct, top $([math]::Round($nearC.TopShare * 100))%)"

# The positive half: a busy bitmap clears the floor, so the gate is not simply
# refusing everything.
$busy = New-Object System.Drawing.Bitmap 400, 300
$g = [System.Drawing.Graphics]::FromImage($busy)
for ($y = 0; $y -lt 300; $y += 4) {
    for ($x = 0; $x -lt 400; $x += 4) {
        $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(
            ($x % 200) + 20, ($y % 180) + 30, (($x + $y) % 150) + 40))
        $g.FillRectangle($br, $x, $y, 4, 4)
        $br.Dispose()
    }
}
$g.Dispose()
$busyC = Get-TestCaptureContent -Shot (New-FakeShot $busy)
Write-Host "  busy: distinct=$($busyC.Distinct) topShare=$([math]::Round($busyC.TopShare,3))"
Assert (Test-Floor $busyC) `
    "a bitmap with real content clears the floor ($($busyC.Distinct) distinct, top $([math]::Round($busyC.TopShare * 100))%)"

# And the committed screenshot itself, which is the calibration this floor was
# set from: the hero window with its terminal glass flat-filled must PASS.
$refPng = Join-Path $PSScriptRoot 'artifacts\hero-mode-t59b.png'
if (Test-Path -LiteralPath $refPng) {
    $refBmp = [System.Drawing.Bitmap]::FromFile($refPng)
    $refC = Get-TestCaptureContent -Shot (New-FakeShot $refBmp)
    Write-Host "  committed hero screenshot: distinct=$($refC.Distinct) topShare=$([math]::Round($refC.TopShare,3))"
    Assert (Test-Floor $refC) `
        "the committed hero screenshot clears the floor ($($refC.Distinct) distinct, top $([math]::Round($refC.TopShare * 100))%)"
    $refBmp.Dispose()
} else {
    Assert $false "the committed hero screenshot is missing ($refPng)"
}

# --- the thin-band capture (T1282) ------------------------------------------
# A MAXIMIZED ghoztty window, to scale: 3858x2118, black terminal glass over
# almost all of it (PrintWindow cannot read that surface - documented limit),
# and the 40 px caption band across the top, which is the ONLY GDI-painted
# region and the one caption-bar.ps1 section 6 measures.
#
# The old count-bounded grid stepped 160x88 px here and put not one sample row
# inside the band, so `Get-TestWindowPixels` threw "the capture is UNIFORM" on a
# capture that was perfectly good - the red read as a caption regression for as
# long as anyone believed it. Both halves are asserted: the guard must pass this
# shot, AND the old grid must be shown to have missed it, or the fix is a number
# nobody can tell from the one it replaced.
$band = New-Object System.Drawing.Bitmap 3858, 2118
$g = [System.Drawing.Graphics]::FromImage($band)
$g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0))
$br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(20, 20, 20))
$g.FillRectangle($br, 9, 9, 3840, 40)   # client origin 9,9; 40 px band (32 DIP @ 1.25)
$br.Dispose(); $g.Dispose()
$bandShot = New-FakeShot $band
Assert (-not (Test-TestCaptureUniform -Shot $bandShot)) `
    'the uniform guard PASSES a maximized-window capture whose only painted region is the 40 px caption band'
Assert (Test-TestCaptureUniform -Shot $bandShot -MaxStep 100000) `
    'and the count-bounded grid it replaced called that same capture UNIFORM (the red T1282 re-attributed)'
$band.Dispose()

$flat.Dispose(); $near.Dispose(); $busy.Dispose()

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    # ---------------------------------------------------------------------
    # A. desktop + focus + input, on a LIGHT window (also the bright half of
    #    the capture control).
    # ---------------------------------------------------------------------
    # `--background=ffffff` is the input the caption band actually derives from
    # (Window.paintCaption: bg + 20 per channel). Deliberately NOT
    # `--window-theme=light`, which no longer reaches it - see the header.
    # `--foreground=101010` is load-bearing for the route-0 assertion below and
    # for nothing else: the default foreground is white, so a `--background=
    # ffffff` window renders white on white and its glass really IS one color.
    # Route 0 said so, which is the correct answer and a useless control - the
    # comparison it has to make is against a pane with visible text in it.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--session-persistence=false', '--background=ffffff', '--foreground=101010',
        '--window-show-tab-bar=always')
    $launched += $app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Assert ($top -ne [IntPtr]::Zero) 'Wait-TestWindow finds the window ON the test desktop'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no window'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'the window is NOT enumerable on the interactive desktop'

    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    Assert ($pane -ne [IntPtr]::Zero) 'Get-TestChildWindow finds the terminal surface'

    $r = Get-TestWindowRect -Window $top
    Assert ($r.Width -gt 100 -and $r.Height -gt 100) "Get-TestWindowRect returns a real rect ($($r.Width)x$($r.Height))"

    # --- coords: BOTH rect forms are SCREEN space, and it is the same space
    #     the input takes (T327). Every click in this suite is a screen point
    #     built from one of these rects, so "-Client returns a screen-positioned
    #     client rect" is the assumption under all 147 of them - and it was only
    #     ever written down inside the C# body, where no caller reads it. A
    #     client rect that came back 0,0-based would send every one of those
    #     clicks one client origin up and to the left, which is a silent MISS:
    #     the post succeeds and the assertion after it fails against a working
    #     feature (T318 paid for that once).
    #
    #     Parked off the screen origin first, so the two spaces are far apart
    #     and the check can actually fail. The negative control below is what
    #     proves that: the same offsets read as client-relative land nowhere.
    $homeRect = Get-TestWindowRect -Window $top
    [void](Set-TestWindowPos -Window $top -X 220 -Y 160)
    Start-Sleep -Milliseconds 400
    $wr = Get-TestWindowRect -Window $top
    $cr = Get-TestWindowRect -Window $top -Client
    Assert ($wr.Left -ge 200 -and $wr.Top -ge 140) `
        "coords setup: the window parked off the screen origin ($($wr.Left),$($wr.Top))"
    Assert ($cr.Left -ge $wr.Left -and $cr.Top -ge $wr.Top -and
            $cr.Right -le $wr.Right -and $cr.Bottom -le $wr.Bottom) `
        "-Client returns the client rect INSIDE the window rect, i.e. in the same space ($($cr.Left),$($cr.Top))"
    Assert ($cr.Left -ge 200) `
        "-Client is screen-positioned, not 0,0-based (Left=$($cr.Left))"
    # And it is the space the INPUT takes: Get-TestMouseRoute asks the window
    # the same question Send-TestMouse asks before every post.
    $inClient = Get-TestMouseRoute -Window $top -X ($cr.Left + 8) -Y ($cr.Top + 8)
    Assert ($inClient.Code -ne 0) `
        "a point built off the client rect hit-tests ON the window (code $($inClient.Code))"
    $asIfClient = Get-TestMouseRoute -Window $top -X 8 -Y 8
    Assert ($asIfClient.Code -eq 0) `
        'negative control: the same offset read as CLIENT-relative hit-tests nowhere (HTNOWHERE)'
    [void](Set-TestWindowPos -Window $top -X $homeRect.Left -Y $homeRect.Top)
    Start-Sleep -Milliseconds 400

    # --- focus: what replaces GrabForeground off the input desktop.
    Assert (Focus-TestWindow -Window $top -Child $pane) 'Focus-TestWindow reports focus taken'
    Assert ((Get-TestFocusedWindow -Window $top) -eq ([int64]$pane)) `
        'Get-TestFocusedWindow agrees the pane holds focus'

    # --- text into a TERMINAL: WM_KEYDOWN only. Doubling is the failure mode
    #     to watch for, so it is asserted directly.
    $token = 'harness-ok-42'
    Send-TestText -Window $top -Target $pane -Text "echo $token" | Out-Null
    Send-TestKeys -Window $top -Target $pane -Key Enter | Out-Null
    Start-Sleep -Milliseconds 1200
    $paneName = $null
    $j = Get-Tree
    if ($j) { $paneName = $j.data.windows[0].tabs[0].splits.terminal.name }
    $paneText = ''
    if ($paneName) { $paneText = (& $exe +read --name=$paneName --lines=20 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String) }
    Assert ($paneText -match [regex]::Escape($token)) "Send-TestText delivered '$token' to the terminal"
    Assert (-not ($paneText -match 'hhaarrnneessss')) 'Send-TestText did NOT double characters (no WM_CHAR)'

    # --- THE CAPTURE LIMIT, measured rather than asserted from the header
    #     (T214). The pane has just echoed a token, so it is definitely
    #     rendering content. Three assertions, in the order that makes the
    #     trap visible:
    #
    #       1. the guard refuses the capture BY CLASS, before anything can be
    #          measured - a flat fill is a valid bitmap, so there is nothing to
    #          detect after the fact;
    #       2. -AllowTerminalSurface gets through, and what comes back is a
    #          flat fill on a pane full of text;
    #       3. it is the SAME flat fill after more text renders.
    #
    #     (2) and (3) are the negative control for (1): they prove the refusal
    #     guards a real limit. They are also the trap itself, stated as a
    #     measurement - a probe here does not fail loudly, it passes against
    #     nothing.
    $refused = $false
    try { Get-TestWindowPixels -Window $pane | Out-Null }
    catch { $refused = ($_.Exception.Message -match 'GhozttyTerminal') }
    if ($NegativeControl) { $refused = -not $refused }
    Assert $refused 'Get-TestWindowPixels REFUSES the GhozttyTerminal surface by class'

    # --- THE SAME LIMIT, ONE CLASS WIDER (T303). The class refusal above knows
    #     one window. Every WinUI/XAML window captures as the same flat fill and
    #     no class list predicts them, so the SECOND guard reads the bitmap: a
    #     non-trivial capture that is one color over its whole interior throws,
    #     after retrying long enough to rule out a window that had not painted.
    #     Fixture: this pane, which -AllowTerminalSurface lets past the class
    #     refusal and which is known-flat forever - the permanent half of the
    #     failure, measured rather than simulated. The two switches are separate
    #     on purpose, which is what makes this fixture possible at all.
    $uniformRefused = $false
    $uniformMsg = ''
    try { Get-TestWindowPixels -Window $pane -AllowTerminalSurface -UniformTimeoutMs 300 | Out-Null }
    catch { $uniformMsg = $_.Exception.Message; $uniformRefused = ($uniformMsg -match 'UNIFORM') }
    if ($uniformRefused) {
        Write-Host "capture: uniform guard fired - $($uniformMsg.Substring(0, [math]::Min(120, $uniformMsg.Length)))..."
    }
    if ($NegativeControl) { $uniformRefused = -not $uniformRefused }
    Assert $uniformRefused 'Get-TestWindowPixels REFUSES a UNIFORM capture (the WinUI/DirectComposition class of empty)'

    $uniformMentions = ($uniformMsg -match 'DirectComposition') -and ($uniformMsg -match 'AllowUniform')
    if ($NegativeControl) { $uniformMentions = -not $uniformMentions }
    Assert $uniformMentions 'the uniform refusal names DirectComposition and the -AllowUniform opt-out'

    #     ...and the other side of the control, which is the half that would
    #     make this guard worse than nothing: real GDI chrome must sail through
    #     it. A guard that also refuses the captures the suite depends on is not
    #     a stricter harness, it is a broken one.
    $chromeOk = $false
    $chromeErr = ''
    try {
        $chromeShot = Get-TestWindowPixels -Window $top -Sync
        try { $chromeOk = ((Get-TestDistinctColors -Shot $chromeShot) -ge 8) }
        finally { Close-TestWindowPixels $chromeShot }
    } catch { $chromeErr = $_.Exception.Message }
    if ($chromeErr) { Write-Host "capture: chrome window threw - $chromeErr" }
    if ($NegativeControl) { $chromeOk = -not $chromeOk }
    Assert $chromeOk 'the uniform guard does NOT refuse a real ghoztty chrome window'

    $shot = Get-TestWindowPixels -Window $pane -AllowTerminalSurface -AllowUniform
    try {
        $surfColors = Get-TestDistinctColors -Shot $shot
        $surfLum = Get-TestBrightness -Shot $shot
    } finally { Close-TestWindowPixels $shot }
    Write-Host "capture: terminal surface distinct=$surfColors meanLum=$surfLum"
    Assert ($surfColors -le 2) `
        "the terminal surface captures as a FLAT FILL ($surfColors distinct colors on a pane that just echoed '$token')"

    Send-TestText -Window $top -Target $pane -Text 'echo ZZZZZZZZZZZZZZZZ' | Out-Null
    Send-TestKeys -Window $top -Target $pane -Key Enter | Out-Null
    Start-Sleep -Milliseconds 1200
    $shot2 = Get-TestWindowPixels -Window $pane -AllowTerminalSurface -AllowUniform
    try {
        $surfColors2 = Get-TestDistinctColors -Shot $shot2
        $surfLum2 = Get-TestBrightness -Shot $shot2
    } finally { Close-TestWindowPixels $shot2 }
    Write-Host "capture: terminal surface after more output distinct=$surfColors2 meanLum=$surfLum2"
    Assert (($surfColors2 -le 2) -and ([math]::Abs($surfLum2 - $surfLum) -le 1)) `
        "the flat fill does not move when the terminal renders (distinct=$surfColors2 meanLum=$surfLum2 vs $surfLum)"

    #       4. ROUTE 0 SEES WHAT PRINTWINDOW CANNOT (T275). Same pane, same
    #          moment: `capture-pane` has the pane's own renderer read back its
    #          offscreen target, and that capture is full of the text the flat
    #          fill above could not see. This is the pair that keeps both facts
    #          true at once - the PrintWindow limit is real and unrepealed, and
    #          there is now a way around it that does not go through PrintWindow
    #          at all. Without it, a future reader has only the refusal and no
    #          idea what to do instead.
    if ($paneName) {
        $route0 = Get-TestPaneCapture -Target $paneName
        $route0Colors = if ($route0) { Get-TestPaneColorCount -Shot $route0 } else { 0 }
        if ($route0) { Close-TestPaneCapture $route0 }
        Write-Host "capture: route 0 (capture-pane) distinct=$route0Colors"
        Assert ($route0Colors -ge 8) `
            "route 0 reads the SAME pane as real content ($route0Colors distinct colors, vs $surfColors2 through PrintWindow)"
    } else {
        Write-Host 'SKIP  route 0 comparison: the pane has no registered name to capture'
        $script:skipped++
    }

    # --- a modifier CHORD: ctrl+shift+t must add a tab.
    Assert ((Get-TabCount) -eq 1) 'setup: one tab before the chord'
    Send-TestKeys -Window $top -Target $pane -Modifiers ctrl,shift -Key T | Out-Null
    Start-Sleep -Milliseconds 1000
    Assert ((Get-TabCount) -eq 2) 'Send-TestKeys ctrl+shift+t fired its keybind (2 tabs)'

    # --- capture, bright half.
    $lightLum = Measure-TitlebarLuminance $top
    Write-Host "capture: light-chrome caption meanLum=$lightLum"
    Assert ($lightLum -gt 150) "Get-TestWindowPixels returns REAL chrome for a light-chrome window (meanLum=$lightLum)"

    # --- standard controls: the rename dialog's EDIT. Opposite convention to
    #     the terminal - WM_CHAR, because nothing translates a posted message.
    $title = 'HarnessTitle'
    Send-TestKeys -Window $top -Target $pane -Modifiers ctrl,shift -Key R | Out-Null
    $dlg = [IntPtr]::Zero
    for ($t = 0; $t -lt 40 -and $dlg -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 100
        $dlg = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyRenameDialog'
    }
    Assert ($dlg -ne [IntPtr]::Zero) 'ctrl+shift+r opened the rename dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        $edit = Find-TestWindowEx -Parent $dlg -Class 'EDIT'
        Assert ($edit -ne [IntPtr]::Zero) 'rename dialog EDIT found'
        if ($edit -ne [IntPtr]::Zero) {
            # No ctrl+A first: a modifier chord does NOT survive into a
            # standard control this way. The app TranslateMessage's dialog
            # messages, and translation reads the queue's own key state rather
            # than the state we set for the posted message - so ctrl+a arrives
            # as a literal 'a'. The new text is therefore appended, which is
            # all this assertion needs.
            Send-TestControlText -Control $edit -Text $title | Out-Null
            Start-Sleep -Milliseconds 200
            Send-TestControlKey -Control $edit -Key Enter | Out-Null
            Start-Sleep -Milliseconds 700
            $wt = Get-TestWindowText -Window $top
            Assert ($wt -match [regex]::Escape($title)) `
                "Send-TestControlText typed into a standard control (window title now '$wt')"
        }
    }

    # --- activation, the WRITE side (T568). Everything above moves focus
    #     WITHIN one window; this moves it between windows, and takes it away
    #     entirely. Without it a whole class of chrome claim - "X shows only
    #     while this window has the keyboard" - is assertable in one direction
    #     only, which is why T289 shipped the Activity Monitor's focus ring with
    #     its disappearance half unmeasured.
    #
    #     Asserted by OUTCOME off the input queue, never from the call's return:
    #     GetGUIThreadInfo is the same read Get-TestFocusedWindow/
    #     Get-TestActiveWindow already trust.
    Assert (Focus-TestWindow -Window $top -Child $pane) 'activation setup: the pane holds the keyboard'
    Assert (Clear-TestActiveWindow -Window $top) 'Clear-TestActiveWindow reports the keyboard relinquished'
    Start-Sleep -Milliseconds 300
    $focusNone = Get-TestFocusedWindow -Window $top
    Assert ($focusNone -eq 0) "and the window's GUI thread really holds NO focus (got $focusNone)"
    Assert (Set-TestActiveWindow -Window $top) 'Set-TestActiveWindow reports the window activated again'
    Start-Sleep -Milliseconds 300
    Assert ((Get-TestActiveWindow -Window $top) -eq ([int64]$top)) 'and the queue agrees that window is ACTIVE'
    Assert ((Get-TestFocusedWindow -Window $top) -ne 0) 'and the keyboard is back on it'

    # And it MOVES between two top-level windows of the same GUI thread - the
    # shape a user makes by clicking the window behind. Note what cannot be
    # asserted here and why: both windows share one input queue, so
    # Get-TestFocusedWindow reads the same value for either. ACTIVE is the
    # per-window fact, which is exactly why Get-TestActiveWindow exists.
    & $exe +new-window 2>&1 | Out-Null
    $second = [IntPtr]::Zero
    for ($t = 0; $t -lt 40 -and $second -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 150
        $second = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow') |
            Where-Object { [int64]$_.Hwnd -ne [int64]$top } |
            ForEach-Object { [IntPtr]$_.Hwnd } | Select-Object -First 1
        if ($null -eq $second) { $second = [IntPtr]::Zero }
    }
    Assert ($second -ne [IntPtr]::Zero) 'activation: a second top-level window exists to move to'
    if ($second -ne [IntPtr]::Zero) {
        Assert (Set-TestActiveWindow -Window $top) 'activation: the first window takes the keyboard'
        Start-Sleep -Milliseconds 300
        Assert ((Get-TestActiveWindow -Window $second) -eq ([int64]$top)) `
            'the SECOND window agrees the first is active (one queue, one active window)'
        Assert (Set-TestActiveWindow -Window $second) 'activation: the second window takes it'
        Start-Sleep -Milliseconds 300
        $activeNow = Get-TestActiveWindow -Window $top
        Assert ($activeNow -eq ([int64]$second)) `
            "activation really MOVED to the other top-level window (active=$activeNow)"
        Assert ($activeNow -ne ([int64]$top)) `
            'negative control: the first window is no longer the active one'
        Send-TestWindowClose -Window $second | Out-Null
        Start-Sleep -Milliseconds 700
        [void](Focus-TestWindow -Window $top -Child $pane)
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'app alive through the whole harness run'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ---------------------------------------------------------------------
    # B. capture NEGATIVE CONTROL: the same probe on a dark window must land
    #    on the other side of the threshold. A blank (all-black) or stale
    #    bitmap cannot pass both halves.
    # ---------------------------------------------------------------------
    $app2 = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--session-persistence=false', '--background=000000', '--window-show-tab-bar=always')
    $launched += $app2.Pid
    Start-Sleep -Seconds 3
    $top2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow'
    Assert ($top2 -ne [IntPtr]::Zero) 'second launch: window found on the test desktop'
    if ($top2 -ne [IntPtr]::Zero) {
        $darkLum = Measure-TitlebarLuminance $top2
        Write-Host "capture: dark-chrome caption meanLum=$darkLum"
        Assert ($darkLum -ge 0 -and $darkLum -lt 100) `
            "capture reads dark chrome as dark (dark meanLum=$darkLum)"
        # The SEPARATION, asserted in its own right. Without this, two halves
        # reading the SAME number can still both be green - which is exactly
        # how the retired window-theme control survived (both sides ~71).
        Assert (($lightLum - $darkLum) -ge 100) `
            "capture SEPARATES the two chromes (light $lightLum - dark $darkLum >= 100)"
    }
    Stop-Process -Id $app2.Pid -Force -ErrorAction SilentlyContinue
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'nothing the harness launched ever became foreground on the interactive desktop'
}

# --- stamp (T783, wired here by T303) --------------------------------------
# A clean green run RECORDS the content of lib\TestDesktop.ps1 and this script,
# so scripts\guard-due.ps1 can answer "has anybody run this against the library
# as it now stands?". Stamped only on a run with no failures AND no skips - a
# skipped section proved less than the whole harness claims - and never on a
# -NegativeControl run, whose whole point is that it fails. Red stays due.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard test-desktop -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# One scorer owns the wording AND the exit code (T271), so a run that skipped a
# section says so in the line anybody reads (T219) and a run that asserted
# nothing cannot report a pass.
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
