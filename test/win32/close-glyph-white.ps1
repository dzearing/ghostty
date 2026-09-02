# T528 acceptance: the close button's glyph is WHITE on its red fill.
#
# The user's report (2026-08-06): "the close X button in the top right has
# black X on hover while normal windows have white X." Every native Windows 11
# window flips the close glyph to white when the red hover fill appears; ours
# went black, at the single most-looked-at control on the window.
#
# It went black while every contrast floor passed, which is why this needs a
# PIXEL oracle and not just the palette's unit sweep. The old palette resolved
# the foreground with `contrastForeground(danger)` - the better of black and
# white against whatever red came out of the 3:1 lift off the band. On a
# mid-dark band that lift LIGHTENS `#C42B1C` past the point where white clears
# 4.5:1, and black-on-light-red is then the WCAG-correct answer. Two correct
# rules, one wrong button. `chrome_theme.dangerFillOn` now caps the fill's
# luminance so white always reads on it, and `on_danger` is white, full stop.
#
# THE BACKGROUND IS THE POINT. This launches with `--background=#202020` -
# Fluent's dark surface, and the shade a default dark theme really paints -
# because that is a band where the two answers DIFFER. On the `#000000` that
# caption-bar.ps1 uses, `#C42B1C` already clears 3:1 unadjusted and the old
# code picked white too: the arm would pass against the defect. Teeth-checked
# by reverting `resolve` to the searched foreground and re-running, which fails
# the two glyph assertions below.
#
# What it asserts:
#
#   1. The lit close slab fills RED (not a shaded chrome grey).
#   2. Its glyph paints LIGHTER than that fill - a white X antialiases to
#      pinks, so every glyph pixel is brighter than the red under it.
#   3. NO part of the glyph is darker than the fill. That is the half that
#      catches the defect: a black X is the mirror image of a white one and
#      "there is a glyph here" cannot tell them apart.
#
# LIMIT, stated rather than glossed: the lit state is driven by a PRESS
# (WM_NCLBUTTONDOWN/HTCLOSE), not by a hover. `paintCaptionSlab` paints the
# same red fill and the same `on_danger` glyph for both - press only firms the
# red by the shared delta - and a synthesized WM_NCMOUSEMOVE cannot be captured
# here: TrackMouseEvent watches the REAL cursor, so on a background desktop the
# WM_NCMOUSELEAVE lands within a frame and clears the hover before PrintWindow
# runs (T233's lesson). A press LATCHES on purpose and survives the capture.
#
# Runs on the background test desktop (test/win32/lib/TestDesktop.ps1), so it
# never takes the user's foreground. Only touches ghoztty processes running
# from this repo's zig-out.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-closeglyph$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Ok([string]$msg) { $script:pass++; Write-Host "  PASS  $msg" }
function Bad([string]$msg) { $script:fail++; Write-Host "  FAIL  $msg" }
function Check([bool]$cond, [string]$msg) { if ($cond) { Ok $msg } else { Bad $msg } }

$HTMINBUTTON = 8; $HTCLOSE = 20
$WM_NCLBUTTONDOWN = 0x00A1; $WM_NCLBUTTONUP = 0x00A2

function PackPoint([int]$x, [int]$y) {
    return [IntPtr](([int64]($y -band 0xFFFF) -shl 16) -bor [int64]($x -band 0xFFFF))
}

# Rec.709 relative luminance, on 0..1. Only ever compared against itself here.
function Lum($c) {
    return 0.2126 * ($c.R / 255.0) + 0.7152 * ($c.G / 255.0) + 0.0722 * ($c.B / 255.0)
}

New-TestDesktop | Out-Null
$exitCode = 1
try {
    Write-Host "T528 close-button glyph acceptance"
    Write-Host "  exe: $exe"

    $proc = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        # `false`, not `off`: the bool parser takes true/false only and swallows
        # the error, so `=off` silently leaves persistence ON and this run
        # restores the previous one's layout (T137).
        '--session-persistence=false',
        # The band that BROKE - see the header. Not a decoration.
        '--background=#202020',
        # No strip: nothing else in the band should paint near the slabs.
        '--window-show-tab-bar=never'
    )
    $h = Wait-TestWindow -ProcessId $proc.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($h -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2500
    Set-TestWindowSize -Window $h -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1200

    $m = Get-TestChromeMetrics -Window $h -StripVisible $false
    $win = Get-TestWindowRect -Window $h
    $cli = Get-TestWindowRect -Window $h -Client
    $borderX = [int](($win.Width - $cli.Width) / 2)
    $capW = $m.CapBtnW
    $capH = $m.CaptionH
    $closeL = $cli.Width - $capW
    $cx = $win.Left + $borderX + $closeL + [int]($capW / 2)
    $cy = $win.Top + [int]($capH / 2)
    Write-Host "  dpi=$($m.Dpi) scale=$($m.Scale) capBtnW=$capW captionH=$capH"

    # At rest the slab is bare band - the control that says the fill below is
    # the lit state and not something painted there all along.
    $restShot = Get-TestWindowPixels -Window $h -Sync
    if ((Get-TestDistinctColors $restShot) -lt 3) { throw 'SETUP FAIL: captured a mid-paint frame' }
    $rest = Get-TestPixel -Shot $restShot -X ($win.Left + $borderX + $closeL + 3) -Y $cy
    # T363: "bare chrome" is a claim about WHICH SURFACE this pixel is, so it is
    # scored against the band itself - probed mid-width, right of the title text
    # and well left of the buttons, the same column caption-bar.ps1 uses. The
    # literal it replaces (R < 80) restated the chrome color the app DERIVES
    # from the terminal background, so it would go red for a lighter theme that
    # is painting exactly what it should, and it passed for any dark fill.
    $bandRef = Get-TestPixel -Shot $restShot -X ($win.Left + $borderX + [int]($cli.Width / 2)) -Y $cy
    Close-TestWindowPixels $restShot
    $restDelta = if ($null -eq $rest -or $null -eq $bandRef) { 999 } else {
        [Math]::Max([math]::Abs([int]$rest.R - $bandRef.R),
         [Math]::Max([math]::Abs([int]$rest.G - $bandRef.G),
                     [math]::Abs([int]$rest.B - $bandRef.B)))
    }
    Check ($restDelta -le 8) `
        "the resting close slab is bare chrome, not red (rgb $($rest.R),$($rest.G),$($rest.B) vs band $($bandRef.R),$($bandRef.G),$($bandRef.B))"

    Send-TestRawMessage -Window $h -Message $WM_NCLBUTTONDOWN `
        -WParam ([IntPtr]$HTCLOSE) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 500
    $shot = Get-TestWindowPixels -Window $h -Sync

    # The fill, sampled at the slab's left edge where no glyph reaches.
    $fill = Get-TestPixel -Shot $shot -X ($win.Left + $borderX + $closeL + 3) -Y $cy
    $isRed = ($null -ne $fill -and $fill.R -gt 80 -and
        $fill.R -gt ($fill.G + 40) -and $fill.R -gt ($fill.B + 40))
    Check $isRed "the lit close slab fills RED (rgb $($fill.R),$($fill.G),$($fill.B))"

    if ($isRed) {
        $fillLum = Lum $fill
        $lighter = 0; $darker = 0; $darkest = 1.0
        for ($dy = -6; $dy -le 6; $dy++) {
            for ($dx = -9; $dx -le 9; $dx++) {
                $p = Get-TestPixel -Shot $shot -X ($cx + $dx) -Y ($cy + $dy)
                if ($null -eq $p) { continue }
                $l = Lum $p
                if ($l -gt $fillLum + 0.12) { $lighter++ }
                if ($l -lt $fillLum - 0.06) { $darker++ }
                if ($l -lt $darkest) { $darkest = $l }
            }
        }
        Check ($lighter -gt 0) "the lit close glyph paints LIGHTER than its red fill ($lighter px)"
        Check ($darker -eq 0) `
            ("no part of the lit close glyph is DARKER than its fill - a black X is exactly that " +
             "(fill lum $([math]::Round($fillLum,3)), darkest glyph px $([math]::Round($darkest,3)), $darker over the line)")
    } else {
        Bad "glyph contrast could not be measured: the slab never filled red"
    }
    Close-TestWindowPixels $shot

    # Release over MINIMIZE: the codes differ, so the press is cancelled and
    # the window is not closed by the measurement.
    Send-TestRawMessage -Window $h -Message $WM_NCLBUTTONUP `
        -WParam ([IntPtr]$HTMINBUTTON) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 300
    Check (Test-TestWindowExists -Window $h) "the window survived the measurement"

    Write-Host ""
    if ($script:fail -eq 0) {
        Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
        $exitCode = 0
    } else {
        Write-Host "$script:fail FAILURE(S) ($script:pass passed)"
        $exitCode = 1
    }
} catch {
    Write-Host ""
    Write-Host "1 FAILURE(S) - $($_.Exception.Message)"
    $exitCode = 1
} finally {
    if ($proc) { Stop-Process -Id $proc.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
}
exit $exitCode
