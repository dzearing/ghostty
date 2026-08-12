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
#   2b. The private restatement of the caption run's four x's AGREES with
#      lib\ChromeGeometry.ps1's published ones (T264). See CaptionGeom's header
#      for why the restatement is kept rather than deleted.
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
# LIMIT, stated rather than glossed: sections 4-5 click at a POINT and let the
# harness route it - since T263 Send-TestMouse asks the window the same
# WM_NCHITTEST Windows asks and posts the message family that answer names, so
# the hit code is no longer hand-picked here and a button that MOVED now fails
# these sections. What is still synthesized is the delivery itself: these are
# posted messages, not a real pointer (T240's lesson - a script that
# synthesizes the trigger cannot validate the trigger). The part that cannot be
# faked at all is sections 1-2: those are PAINTED pixels from a live window,
# and the caption band does not exist unless WM_NCCALCSIZE actually worked.
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

# Where the caption's controls are, in this window, right now: the system trio
# is three NATIVE 46 DIP slabs flush to the client's right edge with zero gaps
# (T496), and T234's "..." is the app's 28 DIP square one GROUP step (pad_md)
# left of the minimize slab. Same arithmetic as caption_layout.layout,
# deliberately restated from the DIP constants rather than read out of the
# binary - section 2 is what checks that derivation against real pixels.
#
# T264 - WHICH WAY THIS WENT, AND WHY. `lib\ChromeGeometry.ps1` publishes these
# same four x's (`CaptionCloseLeft`/`CaptionMaxLeft`/`CaptionMinLeft`/
# `CaptionOverflowLeft`, added in T260), so from T260 on this was the SECOND
# derivation of one datum in one test tree - the exact shape T257 spent a task
# deleting four times over. The choice was to read them out of the module and
# keep one hand-written cross-check, or to keep the restatement and assert it
# AGREES. Kept, and asserted (section 2b):
#
#   * The cross-check is the whole reason the copy exists. Section 2 measures
#     PAINTED pixels against these numbers, and if the numbers came from the
#     module then a module that drifted would move the probe points with it and
#     keep passing - the derivation would no longer be checked by anything.
#   * A restatement that is never compared is a latent divergence (T256: a
#     script measuring last release's layout and reporting a healthy product as
#     broken). Comparing it turns the duplicate into an oracle, which is the
#     one form of duplication that pays for itself.
#
# So: this function stays hand-derived from the DIP constants, and section 2b
# fails loudly the moment it and the module disagree by even a pixel.
#
# Re-derived per call because section 5 relaunches the window: button x's are
# measured from the RIGHT edge, so a stale window rect aims every click at the
# wrong place.
function CaptionGeom($h) {
    $m = Get-TestChromeMetrics -Window $h -StripVisible $false
    $win = Get-TestWindowRect -Window $h
    $cli = Get-TestWindowRect -Window $h -Client
    # The left/right frame survives NCCALCSIZE; only the top was reclaimed. So
    # the client's x origin inside the WINDOW rect is half the width lost.
    $borderX = [int](($win.Width - $cli.Width) / 2)
    $capW = $m.CapBtnW
    # GHOZTTY_TEST_CAPTION_SKEW is the teeth-check for section 2b (T264): it
    # shifts THIS restatement by N px so it disagrees with the module's
    # published x's by exactly that much - the same observable state as the
    # module's own derivation drifting a pixel, which is the failure 2b exists
    # to catch. Deliberately small enough that nothing else moves: one px
    # inside a 46 DIP slab still hit-tests, clicks and paints identically, so a
    # skewed run goes red in 2b and nowhere else. Unset in every real run.
    $skew = 0
    if ($env:GHOZTTY_TEST_CAPTION_SKEW) { $skew = [int]$env:GHOZTTY_TEST_CAPTION_SKEW }
    $closeL = $cli.Width - $capW + $skew
    $maxL = $closeL - $capW
    $minL = $maxL - $capW
    $overL = $minL - $m.PadMd - $m.BtnPaint
    # Off the CLIENT origin, not the window's: maximized, the frame hangs above
    # the monitor (rect top is -sysFrameY) while the band still starts at the
    # client's first row - so a window-relative y aims the restore click at the
    # sky. Restored, the two are the same point (section 1 asserts exactly
    # that), so this costs nothing there.
    $cy = $cli.Top + [int]($m.CaptionH / 2)
    $x = { param($left, $w) $cli.Left + $left + [int]($w / 2) }
    [pscustomobject]@{
        M = $m; Win = $win; Cli = $cli; BorderX = $borderX
        CapW = $capW; Btn = $m.BtnPaint; PadMd = $m.PadMd
        OverL = $overL; MinL = $minL; MaxL = $maxL; CloseL = $closeL; Cy = $cy
        PtOver  = @((& $x $overL $m.BtnPaint), $cy)
        PtMin   = @((& $x $minL $capW), $cy)
        PtMax   = @((& $x $maxL $capW), $cy)
        PtClose = @((& $x $closeL $capW), $cy)
        # The drag band: left of the title, well clear of every button.
        PtDrag  = @(($win.Left + $borderX + 40), $cy)
    }
}

# A real click, at a POINT. Send-TestMouse asks the window the same
# WM_NCHITTEST Windows asks and delivers the WM_NC* pair the caption band
# actually receives (T263), so this is no longer a synthesized message pair
# with a hand-picked hit code - the app decides what is under each point.
# Two points, because press-then-release-elsewhere is a gesture this script
# asserts: down at $downPt, up at $upPt.
function ClickCaption($h, [int[]]$downPt, [int[]]$upPt) {
    [void](Send-TestMouse -Window $h -Target $h -X $downPt[0] -Y $downPt[1] -Action down)
    Start-Sleep -Milliseconds 120
    [void](Send-TestMouse -Window $h -Target $h -X $upPt[0] -Y $upPt[1] -Action up)
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
    # Layout from CaptionGeom (see the arithmetic there); what this section
    # adds is the check that the derivation matches PAINTED pixels.
    $geo = CaptionGeom $h
    $capW = $geo.CapW
    $padMd = $geo.PadMd
    $closeL = $geo.CloseL
    $maxL = $geo.MaxL
    $minL = $geo.MinL
    $overL = $geo.OverL
    $cy = $geo.Cy
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

    # --- 2b. the restatement AGREES with ChromeGeometry (T264) ---------------
    # `CaptionGeom` derives the caption run's four x's from the DIP constants
    # itself; `lib\ChromeGeometry.ps1` publishes the same four. Keeping both is
    # deliberate (see CaptionGeom's header) - what is NOT allowed is keeping
    # both without comparing them, which is how a script ends up measuring a
    # layout the product moved away from and calling a healthy build broken.
    #
    # Compared against `$geo.M` rather than the module read at line ~179: same
    # call, same window rect, so a difference here can only be the arithmetic.
    $gm = $geo.M
    Check ($closeL -eq $gm.CaptionCloseLeft) `
        "restated close x agrees with ChromeGeometry ($closeL vs $($gm.CaptionCloseLeft))"
    Check ($maxL -eq $gm.CaptionMaxLeft) `
        "restated maximize x agrees with ChromeGeometry ($maxL vs $($gm.CaptionMaxLeft))"
    Check ($minL -eq $gm.CaptionMinLeft) `
        "restated minimize x agrees with ChromeGeometry ($minL vs $($gm.CaptionMinLeft))"
    Check ($overL -eq $gm.CaptionOverflowLeft) `
        "restated '...' x agrees with ChromeGeometry ($overL vs $($gm.CaptionOverflowLeft))"
    # The band height the pixel scan in section 1 was measured against is the
    # module's too, so state that it is the same number the click points are
    # centered on rather than leaving two 32 DIP constants to drift apart.
    Check ($geo.M.CaptionH -eq $expectCapH) `
        "the click points center on the same band height section 1 scanned ($($geo.M.CaptionH) vs $expectCapH)"

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
    # and it cannot appear unless the press was routed as WM_NCLBUTTONDOWN,
    # reached `handleNcLButtonDown` and matched a button rect - which is the
    # whole chain a plain client click at the same point misses (T263).
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
    [void](Send-TestMouse -Window $h -Target $h -X $geo.PtMin[0] -Y $geo.PtMin[1] -Action down)
    Start-Sleep -Milliseconds 400
    $pressC = FillShade $h $win $borderX $minL $capW $padSm
    Check ($null -ne $pressC -and $pressC.R -ge ($restC.R + 15)) `
        "a press on minimize lights its fill (rest $($restC.R) -> pressed $($pressC.R))"
    # Released over the DRAG region, not over minimize: that is the cancel
    # path, so it un-lights the button AND changes no window state - which is
    # what keeps this assertion readable. (Releasing on the button itself
    # would post SC_MINIMIZE and the next capture would be of a -32000 icon
    # stub, i.e. no pixels at all.)
    [void](Send-TestMouse -Window $h -Target $h -X $geo.PtDrag[0] -Y $geo.PtDrag[1] -Action up)
    Start-Sleep -Milliseconds 500
    $afterC = FillShade $h $win $borderX $minL $capW $padSm
    Check ($null -ne $afterC -and $afterC.R -le ($restC.R + 6)) `
        "a release off the button un-lights it and cancels (back to $($afterC.R), rest $($restC.R))"

    # --- 5. the ACTIONS ------------------------------------------------------
    # A caption button's job ends at posting WM_SYSCOMMAND; whether the window
    # then minimizes is DefWindowProc's business, not ours. This section used
    # to be guarded by an ABORT and SKIPPED wholesale, because a plain
    # WM_CLOSE - which has nothing to do with T254 - sometimes did not close
    # the window here, and the desktop was blamed for it.
    #
    # T255 measured it: nothing about the desktop is involved. The window was
    # DISABLED, by the app's own close-confirmation dialog. ConfirmDialog.show
    # calls EnableWindow(owner, FALSE) for the length of its message loop, and
    # DefWindowProc discards every WM_SYSCOMMAND for a disabled window - so
    # SC_MINIMIZE/SC_MAXIMIZE/SC_CLOSE become no-ops while it is up, and a
    # second WM_CLOSE only re-enters confirmCloseIfNeeded and raises another.
    # Hit testing and painting keep working throughout, which is what made it
    # look like a wedge instead of a block. On the interactive desktop you
    # would simply see the dialog; here nobody does.
    #
    # So the control still runs FIRST (it is destructive, and a relaunched
    # window carries the assertions), but a window that does not close is now
    # INTERROGATED rather than treated as an unknowable desktop: the one thing
    # that can block it is named, answered, and reported as a failure. This
    # window's shell is an idle cmd.exe with no descendants, so
    # confirmCloseIfNeeded should not prompt at all - a dialog here is a
    # finding about the product, not a reason to stop testing.
    Send-TestRawMessage -Window $h -Message 0x0010 -WParam ([IntPtr]0) -LParam ([IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 1800
    # -Answer ok: let a surprise confirmation PROCEED, so the close the control
    # asked for still happens and the section below runs on a clean relaunch.
    $blocker = Clear-TestModalBlocker -Window $h -Answer ok
    if ($blocker -ne 'none') { Start-Sleep -Milliseconds 1500 }
    Check ($blocker -eq 'none') `
        "the control close raised no modal dialog on an idle shell (got '$blocker')"
    Check (-not (Test-TestWindowExists -Window $h)) `
        "positive control: a plain WM_CLOSE closes the window, so window state IS adjudicable here (T255)"

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
    # New window, new rect: re-derive the button points before aiming at them.
    $geo = CaptionGeom $h

    # Every click below is an ordinary Send-TestMouse at a POINT. That the
    # minimize point is the minimize BUTTON was established by section 3's hit
    # tests, so a failure here is about the action, not about the aim.
    ClickCaption $h $geo.PtMin $geo.PtMin
    # WS_MINIMIZE, not the rect: the -32000,-32000 caption stub is
    # Explorer's arrangement, and this desktop has no Explorer - an iconic
    # window here parks at a real on-screen rect (measured: 0,2066 199x34),
    # so a rect oracle calls a working minimize broken.
    $minStyle = Get-TestWindowStyle -Window $h
    Check (($minStyle -band 0x20000000) -ne 0) "minimize click iconified the window (WS_MINIMIZE set)"
    Send-TestSysCommand -Window $h -Command 'restore' | Out-Null
    Start-Sleep -Milliseconds 700

    ClickCaption $h $geo.PtMax $geo.PtMax
    $zoomed = Test-TestWindowZoomed -Window $h
    Check $zoomed "maximize click maximized the window"

    # --- 6. maximized, the caption is still on screen ------------------------
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

    # Maximized, the window rect moved (and its frame now hangs off the
    # monitor), so the buttons are somewhere else: re-derive before aiming.
    $geo = CaptionGeom $h
    ClickCaption $h $geo.PtMax $geo.PtMax
    Check (-not (Test-TestWindowZoomed -Window $h)) "a second maximize click restored the window"

    $geo = CaptionGeom $h
    ClickCaption $h $geo.PtClose $geo.PtMin
    Check (Test-TestWindowExists -Window $h) `
        "a close PRESS released over minimize does not close the window"

    ClickCaption $h $geo.PtClose $geo.PtClose
    Start-Sleep -Milliseconds 900
    # Same interrogation as the control: if the close did not take, say WHAT
    # held it rather than leaving a bare "closed the window" failure to guess at.
    $endBlocker = Clear-TestModalBlocker -Window $h -Answer ok
    if ($endBlocker -ne 'none') { Start-Sleep -Milliseconds 1500 }
    Check ($endBlocker -eq 'none') "the close click raised no modal dialog (got '$endBlocker')"
    Check (-not (Test-TestWindowExists -Window $h)) "close click closed the window"

    Write-Host ""
    if ($script:fail -eq 0) {
        Write-Host "ALL PASS ($script:pass assertions)"
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
