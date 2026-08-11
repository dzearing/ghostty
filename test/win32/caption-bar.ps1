# T254 acceptance: the window draws its OWN caption bar.
#
# Until T254 every window was a plain WS_OVERLAPPEDWINDOW and the caption -
# title, minimize, maximize, close - was drawn by DWM, in the non-client area,
# in another process's composition pass. T78/T203 only ever asked DWM to
# restyle its own caption (DWMWA_CAPTION_COLOR & co.), which is not the same
# thing as owning it: there was no DC to draw a button into. WM_NCCALCSIZE now
# hands the caption band to the CLIENT area, which is what makes T234's "..."
# button and T205's in-titlebar tabs possible at all.
#
# That change also makes the caption TESTABLE for the first time: it is client
# pixels now, so PrintWindow captures it. The DWM caption it replaces never
# appeared in a capture at all.
#
# What this script asserts, and how:
#
#   1. The band is OURS. The client area's top edge is the window's top edge
#      (NCCALCSIZE consumed the frame's caption), and a column down the middle
#      of the window is chrome-colored for exactly the native 32 DIP caption
#      height (T496) before it turns into terminal background. Scanned, not
#      assumed - the first non-chrome row IS the measured band height.
#   2. The buttons PAINT where caption_layout.zig says they do: a bright
#      glyph pixel at the center of each native 46 DIP slab and of the "..."'s
#      square, bare chrome at rest on the slabs (native buttons light only on
#      hover/press), and the GROUP gap between the "..." and the minimize slab
#      is plain chrome (which is what catches a cluster laid out at the wrong
#      scale - a button would smear across it).
#   3. WM_NCHITTEST answers correctly, INCLUDING HTMAXBUTTON. That code is not
#      decoration: the Snap Layouts flyout is triggered by the OS watching for
#      it, so a maximize button that answers HTCLIENT silently deletes a
#      Windows 11 feature. This is a real SendMessage - the same question
#      Windows itself asks - not a synthesized answer.
#   4. Each button ACTS: minimize iconifies, maximize/restore toggles, close
#      closes. Driven with the WM_NCLBUTTONDOWN/UP pair Windows sends after
#      its own hit test.
#   5. Press-then-slide-off CANCELS. A press on close released over minimize
#      must not close the window - the thing every native button does, and the
#      thing that makes a mis-aimed close recoverable.
#   6. Maximized, the caption is ON SCREEN. This is the classic custom-titlebar
#      bug: without the SM_CYSIZEFRAME + SM_CXPADDEDBORDER inset in
#      WM_NCCALCSIZE the whole button row sits above the monitor's top edge,
#      the window looks perfectly fine, and the controls are simply
#      unreachable.
#
# LIMIT, stated rather than glossed: sections 3-5 post the messages the OS
# would post. They prove our handlers are right; they do not prove Windows
# routes a real pointer to them (T240's lesson - a script that synthesizes the
# trigger cannot validate the trigger). The part that cannot be faked is
# section 1-2: those are PAINTED pixels from a live window, and the caption
# band does not exist at all unless WM_NCCALCSIZE actually worked.
#
# NEGATIVE CONTROL: -NegativeControl inverts section 1's band-height assertion
# (asserts the band is ABSENT, i.e. the window's top row is already terminal
# background) and MUST fail.
#
# Runs on the background test desktop (test/win32/lib/TestDesktop.ps1), so it
# never takes the user's foreground. Only touches ghoztty processes running
# from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-captiontest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Ok([string]$msg) { $script:pass++; Write-Host "  PASS  $msg" }
function Bad([string]$msg) { $script:fail++; Write-Host "  FAIL  $msg" }
function Check([bool]$cond, [string]$msg) { if ($cond) { Ok $msg } else { Bad $msg } }

# win32 hit-test codes (win32.zig).
$HTCAPTION = 2; $HTSYSMENU = 3; $HTMINBUTTON = 8; $HTMAXBUTTON = 9; $HTTOP = 12
$HTTOPLEFT = 13; $HTTOPRIGHT = 14; $HTCLOSE = 20
$WM_NCHITTEST = 0x0084; $WM_NCLBUTTONDOWN = 0x00A1; $WM_NCLBUTTONUP = 0x00A2

# lparam for a mouse/hit-test message: screen point packed lo=x, hi=y.
function PackPoint([int]$x, [int]$y) {
    return [IntPtr](([int64]($y -band 0xFFFF) -shl 16) -bor [int64]($x -band 0xFFFF))
}

function HitAt($h, [int]$sx, [int]$sy) {
    return [int](Invoke-TestMessage -Window $h -Message $WM_NCHITTEST -LParam (PackPoint $sx $sy))
}

# The DOWN/UP pair Windows posts after its own hit test resolves to a button.
function ClickCaption($h, [int]$downCode, [int]$upCode) {
    Send-TestRawMessage -Window $h -Message $WM_NCLBUTTONDOWN -WParam ([IntPtr]$downCode) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 120
    Send-TestRawMessage -Window $h -Message $WM_NCLBUTTONUP -WParam ([IntPtr]$upCode) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 400
}

New-TestDesktop | Out-Null
$exitCode = 1
try {
    Write-Host "T254 caption bar acceptance"
    Write-Host "  exe: $exe"

    $proc = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        # `false`, not the documented `off`: the bool parser takes true/false
        # only and swallows the error, so `=off` silently leaves persistence ON
        # and this run restores the previous one's layout (T137).
        '--session-persistence=false',
        '--background=#000000',
        # No strip: the row under the caption must be TERMINAL background, or
        # the band's bottom edge has no color boundary to scan for (the strip
        # shades from the same base and would be indistinguishable).
        '--window-show-tab-bar=never'
    )
    $h = Wait-TestWindow -ProcessId $proc.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($h -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2500
    Set-TestWindowSize -Window $h -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1200

    # T257: the DIP constants come from lib\ChromeGeometry.ps1 now, the same
    # helper tab-strip.ps1 and tab-color.ps1 read. The oracle below is unchanged
    # and is what keeps that helper honest: `$expectCapH` is DERIVED, the band
    # is MEASURED off the pixels, and this script asserts they agree. That is
    # the one place the derivation is checked against reality.
    # -StripVisible $false: this window launches with `--window-show-tab-bar=
    # never`, so the band is STANDALONE - the native 32 DIP caption row with
    # the title in it, which is what every assertion below measures (T205/T496).
    $m = Get-TestChromeMetrics -Window $h -StripVisible $false
    $dpi = $m.Dpi
    $scale = $m.Scale
    $win = Get-TestWindowRect -Window $h
    $cli = Get-TestWindowRect -Window $h -Client
    # The left/right frame survives NCCALCSIZE; only the top was reclaimed. So
    # the client's x origin inside the WINDOW rect is half the width lost.
    $borderX = [int](($win.Width - $cli.Width) / 2)
    $padSm = $m.PadSm
    $btn = $m.BtnPaint
    $expectCapH = $m.CaptionH
    Write-Host "  dpi=$dpi scale=$scale window=$($win.Width)x$($win.Height) client=$($cli.Width)x$($cli.Height) borderX=$borderX expectCapH=$expectCapH"

    $shot = Get-TestWindowPixels -Window $h
    $distinct = Get-TestDistinctColors $shot
    if ($distinct -lt 3) { throw "SETUP FAIL: captured a mid-paint frame (distinct=$distinct)" }

    # --- 1. the band is ours, and it is exactly the native 32 DIP ------------
    # Scan a column well left of the buttons and right of the title text.
    $probeClientX = [int]($cli.Width / 2)
    $probeX = $win.Left + $borderX + $probeClientX
    # The first row that is NOT the caption's chrome color. Deliberately not
    # "the first BLACK row": the pane below is a child HWND rendered by the
    # GPU, and PrintWindow brings it back blank white, not as terminal
    # background. What the band's bottom edge actually is, is the boundary
    # where chrome stops.
    $chrome = Get-TestPixel -Shot $shot -X $probeX -Y ($win.Top + 2)
    $firstNonChrome = -1
    for ($y = 0; $y -lt 200; $y++) {
        $c = Get-TestPixel -Shot $shot -X $probeX -Y ($win.Top + $y)
        if ($null -eq $c) { break }
        $d = [math]::Abs($c.R - $chrome.R) + [math]::Abs($c.G - $chrome.G) + [math]::Abs($c.B - $chrome.B)
        if ($d -gt 24) { $firstNonChrome = $y; break }
    }
    $firstBlack = $firstNonChrome
    if ($NegativeControl) {
        Check ($firstBlack -eq 0) "NEGATIVE CONTROL: no caption band (first terminal row at y=0, got $firstBlack)"
    } else {
        Check ($firstBlack -eq $expectCapH) "caption band is $expectCapH px tall (native 32 DIP, T496); measured $firstBlack"
    }
    $capTop = Get-TestPixel -Shot $shot -X $probeX -Y ($win.Top + 2)
    Check ($null -ne $capTop -and $capTop.R -gt 8 -and $capTop.R -lt 60) `
        "the window's TOP row is client chrome, not a DWM caption (rgb $($capTop.R),$($capTop.G),$($capTop.B))"

    # --- 2. the buttons paint where the layout module says -------------------
    # The system trio is three NATIVE 46 DIP slabs flush to the window's right
    # edge with zero gaps (T496); T234's "..." is the app's 28 DIP square one
    # GROUP step (pad_md) left of the minimize slab. Same arithmetic as
    # caption_layout.layout, deliberately restated here from the DIP constants
    # rather than read out of the binary.
    $capW = $m.CapBtnW
    $padMd = $m.PadMd
    $closeL = $cli.Width - $capW
    $maxL = $closeL - $capW
    $minL = $maxL - $capW
    $overL = $minL - $padMd - $btn
    $cy = $win.Top + [int]($expectCapH / 2)
    $names = @('overflow', 'minimize', 'maximize', 'close')
    $lefts = @($overL, $minL, $maxL, $closeL)
    $widths = @($btn, $capW, $capW, $capW)
    for ($i = 0; $i -lt 4; $i++) {
        $cx = $win.Left + $borderX + $lefts[$i] + [int]($widths[$i] / 2)
        # A glyph pixel: brighter than the ~20-level chrome. Scanned over a
        # small window around the button's center, not one row: the icon-font
        # glyphs (T497) are antialiased, and a 1 px mark like ChromeMinimize's
        # bar can straddle two rows at partial alpha - sampling exactly one
        # row reads ~110 on both and misses a glyph that is plainly there.
        $lit = 0
        for ($dy = -4; $dy -le 4; $dy++) {
            for ($dx = -8; $dx -le 8; $dx++) {
                $c = Get-TestPixel -Shot $shot -X ($cx + $dx) -Y ($cy + $dy)
                if ($null -ne $c -and $c.R -gt 100) { $lit++ }
            }
        }
        Check ($lit -gt 0) "$($names[$i]) button paints a glyph in its center"
    }
    # At REST a native slab is bare band background - no permanent fill. The
    # seam between the minimize and maximize slabs is glyph-free chrome, so a
    # slab painted with a resting fill (or at the wrong size) shows up here.
    $gapX = $win.Left + $borderX + $maxL - 1
    $gapC = Get-TestPixel -Shot $shot -X $gapX -Y $cy
    Check ($null -ne $gapC -and $gapC.R -lt 60) "the resting slabs are bare chrome at the min/max seam"
    # ...and the GROUP gap that separates our button from the system trio. If
    # "..." were laid out like a fourth slab, its paint would reach into this
    # column.
    $groupX = $win.Left + $borderX + $minL - [int]($padMd / 2)
    $groupC = Get-TestPixel -Shot $shot -X $groupX -Y $cy
    Check ($null -ne $groupC -and $groupC.R -lt 60) `
        "the '...' is one GROUP step clear of the minimize slab, not jammed against it"
    Close-TestWindowPixels $shot

    # --- 3. WM_NCHITTEST, including the Snap Layouts code --------------------
    $bandY = $win.Top + $expectCapH - 2
    $hitOver = HitAt $h ($win.Left + $borderX + $overL + [int]($btn / 2)) $bandY
    $hitMin = HitAt $h ($win.Left + $borderX + $minL + [int]($capW / 2)) $bandY
    $hitMax = HitAt $h ($win.Left + $borderX + $maxL + [int]($capW / 2)) $bandY
    $hitClose = HitAt $h ($win.Left + $borderX + $closeL + [int]($capW / 2)) $bandY
    $hitDrag = HitAt $h ($win.Left + $borderX + 40) $bandY
    $hitTop = HitAt $h ($win.Left + [int]($win.Width / 2)) ($win.Top + 1)
    # The CLIENT area's top-right corner. Past it is the window's right sizing
    # border, which WM_NCCALCSIZE left with the OS on purpose.
    $hitCorner = HitAt $h ($win.Left + $borderX + $cli.Width - 1) ($win.Top + $expectCapH - 2)
    Check ($hitOver -eq $HTSYSMENU) "hit test over the '...' -> HTSYSMENU (got $hitOver)"
    Check ($hitMin -eq $HTMINBUTTON) "hit test over minimize -> HTMINBUTTON (got $hitMin)"
    Check ($hitMax -eq $HTMAXBUTTON) "hit test over maximize -> HTMAXBUTTON, which is what Snap Layouts watches (got $hitMax)"
    Check ($hitClose -eq $HTCLOSE) "hit test over close -> HTCLOSE (got $hitClose)"
    Check ($hitDrag -eq $HTCAPTION) "hit test over the title area -> HTCAPTION, so the window still drags (got $hitDrag)"
    Check (($hitTop -eq $HTTOP) -or ($hitTop -eq $HTTOPLEFT) -or ($hitTop -eq $HTTOPRIGHT)) `
        "the reclaimed top border still resizes -> HTTOP* (got $hitTop)"
    Check ($hitCorner -eq $HTCLOSE) "the top-right corner lands on close, not on empty band (got $hitCorner)"

    # --- 4. a press REACHES our handler and lights the button ----------------
    # The oracle is the PRESSED FILL, which is a painted pixel: the shared
    # icon-button treatment shades the chrome by 25 for `pressed`, so a
    # 20,20,20 band becomes 45,45,45 under the button and stays 20,20,20 in
    # the gap beside it. Nothing else in the window paints that value there,
    # and it cannot appear unless WM_NCLBUTTONDOWN was routed to
    # `handleNcLButtonDown` and matched a button rect.
    # Sampled inside the slab but OFF the glyph: the slab's fill covers the
    # band's full height (T496), so its top rows light with the press while
    # the centered 10 DIP mark stays well below them. Probing the glyph row
    # instead would read the mark and fail against a build that is behaving
    # correctly.
    function FillShade($h, $win, $borderX, $left, $w, $padSm) {
        $shot2 = Get-TestWindowPixels -Window $h
        $x = $win.Left + $borderX + $left + [int]($w / 2)
        $y = $win.Top + $padSm + 4
        $c = Get-TestPixel -Shot $shot2 -X $x -Y $y
        Close-TestWindowPixels $shot2
        return $c
    }
    $restC = FillShade $h $win $borderX $minL $capW $padSm
    Send-TestRawMessage -Window $h -Message $WM_NCLBUTTONDOWN -WParam ([IntPtr]$HTMINBUTTON) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 400
    $pressC = FillShade $h $win $borderX $minL $capW $padSm
    Check ($null -ne $pressC -and $pressC.R -ge ($restC.R + 15)) `
        "a press on minimize lights its fill (rest $($restC.R) -> pressed $($pressC.R))"
    # Released over the DRAG region, not over minimize: that is the cancel
    # path, so it un-lights the button AND changes no window state - which is
    # what keeps this assertion readable. (Releasing on the button itself
    # would post SC_MINIMIZE and the next capture would be of a -32000 icon
    # stub, i.e. no pixels at all.)
    Send-TestRawMessage -Window $h -Message $WM_NCLBUTTONUP -WParam ([IntPtr]$HTCAPTION) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 500
    $afterC = FillShade $h $win $borderX $minL $capW $padSm
    Check ($null -ne $afterC -and $afterC.R -le ($restC.R + 6)) `
        "a release off the button un-lights it and cancels (back to $($afterC.R), rest $($restC.R))"

    # --- 5. the ACTIONS, guarded by a positive control -----------------------
    # A caption button's job ends at posting WM_SYSCOMMAND; whether the window
    # then minimizes is DefWindowProc's business, not ours. On this background
    # test desktop it is not anybody's business: a plain WM_CLOSE - which has
    # nothing to do with T254 - does not close a Ghoztty window there either.
    # So the desktop is asked first, the window-size-memory.ps1 ABORT idiom:
    # a control that fails means "this desktop cannot adjudicate", not "T254
    # is broken". Filed as its own task rather than papered over.
    # The control runs against THIS window and it runs FIRST, because it is
    # destructive: if a plain WM_CLOSE closes it, the desktop can adjudicate
    # window-state changes and a relaunched window carries the assertions; if
    # it does not, nothing about SC_* is decidable here and the section is
    # SKIPPED with its reason, not silently passed.
    Send-TestRawMessage -Window $h -Message 0x0010 -WParam ([IntPtr]0) -LParam ([IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 1800
    $canAdjudicate = -not (Test-TestWindowExists -Window $h)
    if ($canAdjudicate) {
        # The first INSTANCE outlives its last window on purpose
        # (`quit-after-last-window-closed` defaults to false off Linux, the
        # Mac idiom), and it still owns the debug IPC pipe - so a relaunch
        # would single-instance-forward its new-window to the dying process
        # and exit, and Wait-TestWindow (which filters by the NEW pid) would
        # report no window. Stop the windowless first instance before
        # relaunching; it is the exact pid this script started.
        Stop-Process -Id $proc.Pid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 600
        $proc2 = Start-OnTestDesktop -Exe $exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--background=#000000', '--window-show-tab-bar=never'
        )
        $h = Wait-TestWindow -ProcessId $proc2.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
        if ($h -eq [IntPtr]::Zero) { throw 'SETUP FAIL: relaunch for the action section produced no window' }
        Start-Sleep -Milliseconds 2500
        Set-TestWindowSize -Window $h -Width 1100 -Height 700 | Out-Null
        Start-Sleep -Milliseconds 1000
    }
    if (-not $canAdjudicate) {
        $script:skipped++
        Write-Host "  SKIP  window-state actions: this window ignores even a plain WM_CLOSE on"
        Write-Host "        this desktop, so SC_MINIMIZE/SC_MAXIMIZE/SC_CLOSE cannot be"
        Write-Host "        adjudicated here. The press/release half IS asserted above. T255."
    } else {
        ClickCaption $h $HTMINBUTTON $HTMINBUTTON
        # WS_MINIMIZE, not the rect: the -32000,-32000 caption stub is
        # Explorer's arrangement, and this desktop has no Explorer - an iconic
        # window here parks at a real on-screen rect (measured: 0,2066 199x34),
        # so a rect oracle calls a working minimize broken.
        $minStyle = Get-TestWindowStyle -Window $h
        Check (($minStyle -band 0x20000000) -ne 0) "minimize click iconified the window (WS_MINIMIZE set)"
        Send-TestSysCommand -Window $h -Command 'restore' | Out-Null
        Start-Sleep -Milliseconds 700

        ClickCaption $h $HTMAXBUTTON $HTMAXBUTTON
        $zoomed = Test-TestWindowZoomed -Window $h
        Check $zoomed "maximize click maximized the window"

        # --- 6. maximized, the caption is still on screen --------------------
        if ($zoomed) {
            # A maximized window's FRAME legitimately hangs off every monitor
            # edge (rect top is -sysFrameY); what must be on screen is the
            # CLIENT area, whose top row is the caption band's first row -
            # that is exactly what the WM_NCCALCSIZE maximized inset exists
            # to guarantee, and what these two assert.
            $mw = Get-TestWindowRect -Window $h
            $mcli = Get-TestWindowRect -Window $h -Client
            $work = Get-TestWorkArea
            Check ($mcli.Top -ge $work.Top) `
                "maximized: the caption row is on screen (client top $($mcli.Top) vs work top $($work.Top))"
            # Scan from the CLIENT top, not the window top: the rows above it
            # are the off-screen frame, which PrintWindow renders black, and
            # counting them measured the frame instead of the band.
            $mshot = Get-TestWindowPixels -Window $h
            $mProbe = $mw.Left + [int]($mw.Width / 2)
            $mChrome = Get-TestPixel -Shot $mshot -X $mProbe -Y ($mcli.Top + 2)
            $mEdge = -1
            for ($y = 0; $y -lt 200; $y++) {
                $c = Get-TestPixel -Shot $mshot -X $mProbe -Y ($mcli.Top + $y)
                if ($null -eq $c) { break }
                $d = [math]::Abs($c.R - $mChrome.R) + [math]::Abs($c.G - $mChrome.G) + [math]::Abs($c.B - $mChrome.B)
                if ($d -gt 24) { $mEdge = $y; break }
            }
            Close-TestWindowPixels $mshot
            Check ($mEdge -ge $expectCapH) `
                "maximized: the whole caption band is painted on screen (band bottom $mEdge >= $expectCapH)"
        } else {
            Bad "maximized: caption-on-screen check could not run"
        }

        ClickCaption $h $HTMAXBUTTON $HTMAXBUTTON
        Check (-not (Test-TestWindowZoomed -Window $h)) "a second maximize click restored the window"

        ClickCaption $h $HTCLOSE $HTMINBUTTON
        Check (Test-TestWindowExists -Window $h) `
            "a close PRESS released over minimize does not close the window"

        ClickCaption $h $HTCLOSE $HTCLOSE
        Start-Sleep -Milliseconds 900
        Check (-not (Test-TestWindowExists -Window $h)) "close click closed the window"
    }

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
    Remove-TestDesktop
}
exit $exitCode
