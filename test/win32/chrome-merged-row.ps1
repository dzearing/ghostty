# T205 acceptance: the tab strip lives INSIDE the caption bar - one chrome row,
# not two.
#
# The user's report, sent with a screenshot of stock Windows Terminal as the
# reference: "ok this is normal terminal and it looks more polished than what
# you've built ... the hamburger icon ... doesn't horizontally align under the
# X above it".
#
# The alignment complaint was the symptom. The cause was that Ghoztty drew a
# caption row AND a separate tab strip row beneath it - two runs of controls
# owned by two layouts, which can only ever *approximate* each other, and the
# approximation drifts with DPI and with the caption button width. It is not
# fixable by nudging x coordinates. The fix is to stop having two rows.
#
# What this asserts, and how - by measured geometry and by live hit tests, in
# the mechanism each oracle actually needs:
#
#   1. ONE ROW. The first pane's top sits `bar_h` below the client top, not
#      `caption_h + bar_h`. That is the whole claim, and it is the terminal's
#      own geometry rather than an opinion about what was painted.
#   2. THE STRIP IS AT THE TOP. Real tab chiclets are found in the band that
#      starts at client y = 0 - measured off a capture, not modelled (T256:
#      a tab's width comes from text metrics a script cannot reproduce).
#   3. ONE BASELINE. At the y where the caption's close button paints, the "+"
#      is also painting: WM_NCHITTEST answers HTCLOSE over close and HTCLIENT
#      over the "+" at the SAME y. Two rows cannot produce that answer.
#   4. THE STRIP STILL OWNS ITS CLICKS. A point over a tab answers HTCLIENT -
#      if the merged band answered HTCAPTION there, every tab would drag the
#      window instead of switching tabs - and a posted click on tab 1 really
#      does change the selection.
#   5. THE WINDOW STILL DRAGS. The empty band between the "+" and the "..."
#      answers HTCAPTION. A one-row chrome with no drag region is unusable,
#      and it is the reason the "..." stays right-anchored rather than
#      following the tabs.
#   6. NOTHING IN THE CAPTION LOST ITS MEANING. "..." -> HTSYSMENU, maximize ->
#      HTMAXBUTTON (the code the Snap Layouts flyout watches - a merged row is
#      exactly where that gets silently deleted), close -> HTCLOSE, and the
#      window's top edge still answers HTTOP* so it can still be resized.
#   7. MAXIMIZED, THE ROW IS STILL THERE AND STILL WHOLE. The classic custom
#      frame bug is a band clipped off the top of the screen when maximized;
#      the pane offset and the close button's hit test are both re-checked in
#      that state.
#
# Hit tests rather than synthetic mouse input on purpose: this runs on the
# background test desktop (T211), where SendInput is dead and TrackMouseEvent
# watches a cursor that is not there (T233). WM_NCHITTEST is what Windows
# itself asks before it decides whether a press drags, resizes or clicks, so
# asking the app the same question is the mechanism-appropriate oracle - and it
# is the one that would catch a merged row that swallowed its own tabs.
#
# NEGATIVE CONTROL: -NegativeControl inverts section 1 (asserts the chrome is
# still TWO rows) and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-mergedrowtest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Ok([string]$m) { $script:pass++; Write-Host "  PASS  $m" }
function Bad([string]$m) { $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Check([bool]$c, [string]$m) { if ($c) { Ok $m } else { Bad $m } }

# win32 hit-test codes (win32.zig).
$HTCLIENT = 1; $HTCAPTION = 2; $HTSYSMENU = 3
$HTMAXBUTTON = 9; $HTCLOSE = 20; $HTTOP = 12; $HTTOPLEFT = 13; $HTTOPRIGHT = 14
$WM_NCHITTEST = 0x0084

function PackPoint([int]$x, [int]$y) {
    return [IntPtr](([int64]($y -band 0xFFFF) -shl 16) -bor [int64]($x -band 0xFFFF))
}
function HitAt($h, [int]$sx, [int]$sy) {
    return [int](Invoke-TestMessage -Window $h -Message $WM_NCHITTEST -LParam (PackPoint $sx $sy))
}

function Kill-App($w) {
    if ($null -eq $w) { return }
    Stop-Process -Id $w.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
}

New-TestDesktop | Out-Null
$exitCode = 1
$app = $null
try {
    Write-Host 'T205 merged chrome row acceptance'
    Write-Host "  exe: $exe"
    if ($NegativeControl) {
        Write-Host '  NEGATIVE CONTROL: asserts the chrome is still TWO rows - this run MUST fail'
    }

    # --window-show-tab-bar=always so the merged state exists at one tab too:
    # this script is about the ROW, not about the autohide rule
    # (tab-strip-autohide.ps1 owns that, including the transition between the
    # two states). Black background so a chiclet reads against the strip.
    # --session-persistence=false: a stale layout manifest would restore a
    # previous run's window over the one under test (T131/T248).
    Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
    # ...and the WINDOW PLACEMENT memory (T85), which is a separate file and a
    # separate trap. Section 7 maximizes the window, `savePlacement` records
    # "maximized" on the way out, and the NEXT debug window - this script's or
    # any sibling's - opens maximized. That is not hypothetical: it happened on
    # this script's second run and turned the "top edge still resizes"
    # assertion red, because a maximized window has no resize edge and its
    # client top is `sysFrameY` BELOW its window top. Cleared before the launch
    # and again in `finally`, so a script that maximizes leaves no trace (the
    # T248 lesson, in a file T248 did not name).
    #
    # T267 generalized the pre-launch half: Start-OnTestDesktop now clears this
    # file before every ghoztty launch, so the line below is redundant and kept
    # only as local documentation of the trap. The `finally` copy is NOT
    # redundant - it keeps this script's maximize out of the developer's next
    # hand-launched debug window, which no test helper is around to clear.
    Remove-Item "$env:LOCALAPPDATA\ghoztty\window_placement-debug" -Force -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        '--session-persistence=false',
        '--confirm-close-surface=false',
        '--background=#000000',
        '--window-show-tab-bar=always'
    )
    $h = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($h -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2500
    Set-TestWindowSize -Window $h -Width 1200 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1200

    Check (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'the window is NOT enumerable on the interactive desktop'

    # -StripVisible $true: --window-show-tab-bar=always, so this window's band
    # is the merged row. Every number below comes from lib\ChromeGeometry.ps1,
    # which derives them the way the layout modules do (T257).
    $m = Get-TestChromeMetrics -Window $h -StripVisible $true
    $win = Get-TestWindowRect -Window $h
    $cli = Get-TestWindowRect -Window $h -Client
    Write-Host ("  dpi=$($m.Dpi) scale=$($m.Scale) barH=$($m.BarH) chromeH=$($m.ChromeH) " +
                "stripTop=$($m.StripTopClient) bandLeft=$($m.BandLeft) capBtnTop=$($m.CaptionBtnTop)")
    function ClientX([int]$cx) { return $cli.Left + $cx }
    function ClientY([int]$cy) { return $cli.Top + $cy }

    # --- 1. ONE row -----------------------------------------------------------
    $panes = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes.Count -lt 1) { throw 'SETUP FAIL: no visible pane' }
    $paneOff = $panes[0].Top - $cli.Top
    # What the chrome would cost if the strip still sat UNDER a caption band -
    # i.e. what this measurement returned before T205. Named so the failure
    # message says which world the app is in rather than just quoting a number.
    $twoRows = $m.BarH + (2 * $m.PadSm + $m.BtnPaint)
    if ($NegativeControl) {
        Check ($paneOff -eq $twoRows) `
            "NEGATIVE CONTROL: the chrome is still two rows (pane offset $paneOff = caption + strip $twoRows)"
    } else {
        Check ($paneOff -eq $m.ChromeH) `
            "ONE chrome row: the pane starts bar_h below the client top (offset $paneOff, expected $($m.ChromeH), two rows would be $twoRows)"
    }
    Check ($m.StripTopClient -eq 0) `
        "the strip's origin is the window's own top, not a caption height (stripTopClient $($m.StripTopClient))"

    # --- 2. the tabs really are painted in that band --------------------------
    # MEASURED, never modelled: since T235 a tab's width is its measured title
    # plus padding, which a PowerShell script cannot reproduce (T256/T259).
    $tabs = @(Get-TestTabExtents -Window $h -Metrics $m)
    Check ($tabs.Count -ge 1) `
        "a real tab chiclet is painted in the caption row ($($tabs.Count) found by scanning it)"
    if ($tabs.Count -ge 1) {
        # A tab must not run past the seam: right of it is the caption's half
        # of the row, and a chiclet there would be painting over the buttons.
        Check ($tabs[$tabs.Count - 1].Right -le $m.BandLeft) `
            "the tab run stops at the seam ($($tabs[$tabs.Count - 1].Right) <= bandLeft $($m.BandLeft))"
    }

    # --- 3. ONE baseline ------------------------------------------------------
    # The y where the caption buttons paint. If the strip's controls were on a
    # different row, one of these two answers has to change.
    $btnY = ClientY ($m.CaptionBtnTop + [int]($m.BtnPaint / 2))
    $closeX = ClientX ($m.ClientW - $m.PadSm - [int]($m.BtnPaint / 2))
    $plusLeft = if ($tabs.Count -ge 1) {
        [Math]::Min($tabs[$tabs.Count - 1].Right + $m.Gap, $m.PlusLimit)
    } else { $m.PadL }
    $plusX = ClientX ($plusLeft + [int]($m.BtnPaint / 2))
    $hitClose = HitAt $h $closeX $btnY
    $hitPlus = HitAt $h $plusX $btnY
    Check ($hitClose -eq $HTCLOSE) `
        "at the caption buttons' own y, close answers HTCLOSE (got $hitClose)"
    Check ($hitPlus -eq $HTCLIENT) `
        "...and at the SAME y the strip's '+' is client area, so both paint on one baseline (got $hitPlus)"

    # --- 4. the strip still owns its clicks -----------------------------------
    # Deliberately near the band's BOTTOM: the top rows are the window's resize
    # edge (section 6), exactly as they are on a stock frame.
    $tabY = ClientY ($m.BarH - 3)
    if ($tabs.Count -ge 1) {
        $hitTab = HitAt $h (ClientX $tabs[0].Center) $tabY
        Check ($hitTab -eq $HTCLIENT) `
            "a point over tab 1 answers HTCLIENT, so it selects instead of dragging the window (got $hitTab)"

        # ...and the tab owns its rows all the way to the TOP (T266). Measured
        # 2026-08-06 against a live WindowsTerminal.exe 1.24: WT's tab island
        # answers HTCLIENT from the window's very top row at a tab's x, so a
        # tab is never a resize target — the top edge lives in the empty drag
        # band (full sys-frame thickness for us, both sides probed here) and
        # the corners. Note WT's own top-level window DOES answer HTTOP over
        # its tab run; that answer is unreachable under the island child, which
        # is exactly the mismeasurement an earlier cut of this section shipped.
        $border = Get-TestResizeBorder -Dpi $m.Dpi -BarH $m.BarH -PadSm $m.PadSm
        $tabX = ClientX $tabs[0].Center
        $hitTabTop = HitAt $h $tabX (ClientY 0)
        $hitTabEdge = HitAt $h $tabX (ClientY ($border - 1))
        Check ($hitTabTop -eq $HTCLIENT) `
            "the window's very top row over tab 1 belongs to the tab, not the frame (got $hitTabTop)"
        Check ($hitTabEdge -eq $HTCLIENT) `
            "...and so does the row where the frame used to end (y=$($border - 1), got $hitTabEdge)"
        # The empty band right of the strip keeps the full frame: last frame
        # row resizes, first row past it drags the window.
        $emptyX = ClientX ($m.BandLeft - 2)
        $hitEmptyEdge = HitAt $h $emptyX (ClientY ($border - 1))
        $hitEmptyBelow = HitAt $h $emptyX (ClientY $border)
        Check ($hitEmptyEdge -eq $HTTOP) `
            "the system frame's LAST row over the empty band still resizes (y=$($border - 1), border=$border, got $hitEmptyEdge)"
        Check ($hitEmptyBelow -eq $HTCAPTION) `
            "one row below the frame the empty band drags the window (y=$border, got $hitEmptyBelow)"
    }
    # ...and the functional half: a second tab, then a posted click on tab 1
    # brings its pane back. A hit test alone would pass against a band that
    # routed the click to the client and then dropped it.
    if (Focus-TestWindow -Window $h -Child ([IntPtr]$panes[0].Hwnd)) {
        [void](Send-TestKeys -Window $h -Target ([IntPtr]$panes[0].Hwnd) -Modifiers ctrl -Key T)
        $two = $false
        for ($t = 0; $t -lt 30; $t++) {
            Start-Sleep -Milliseconds 200
            if ((@(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal')).Count -ge 2) { $two = $true; break }
        }
        Check $two 'setup: a second tab exists, so there is a selection to change'
        if ($two) {
            Start-Sleep -Milliseconds 600
            $tabs2 = @(Get-TestTabExtents -Window $h -Metrics $m)
            Check ($tabs2.Count -ge 2) "two tabs are painted in the merged row ($($tabs2.Count) found)"
            $visBefore = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)
            if ($tabs2.Count -ge 2 -and $visBefore.Count -ge 1) {
                [void](Send-TestMouse -Window $h -Target $h `
                        -X (ClientX $tabs2[0].Center) -Y $tabY -Button left -Action click)
                $switched = $false
                for ($t = 0; $t -lt 25; $t++) {
                    Start-Sleep -Milliseconds 200
                    $visNow = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)
                    if ($visNow.Count -ge 1 -and $visNow[0].Hwnd -ne $visBefore[0].Hwnd) { $switched = $true; break }
                }
                Check $switched `
                    'clicking tab 1 in the caption row really switches to it - the row is not just painted there'
            }
        }
    } else {
        Bad 'the click half could not run (no focusable pane)'
    }

    # --- 5/6. drag region, and everything the caption still means -------------
    # Halfway between the "+"'s painted right edge and the "..." - the empty
    # middle of a merged row, which is the only drag handle the window has left.
    #
    # RE-MEASURED here, not reused from section 3: section 4 added a tab, and
    # the "+" TRAVELS with the last tab (T202). The first run of this script
    # aimed at the one-tab "+" position and read HTCLIENT, because by then the
    # two-tab run had grown past it - a stale measurement, not a product bug,
    # and the same class of mistake T256/T259 cost two scripts.
    $tabsNow = @(Get-TestTabExtents -Window $h -Metrics $m)
    $plusNow = if ($tabsNow.Count -ge 1) {
        [Math]::Min($tabsNow[$tabsNow.Count - 1].Right + $m.Gap, $m.PlusLimit)
    } else { $plusLeft }
    $dragX = ClientX ([int](($plusNow + $m.BtnPaint + $m.CaptionOverflowLeft) / 2))
    $hitDrag = HitAt $h $dragX $btnY
    Check ($hitDrag -eq $HTCAPTION) `
        "the empty band between the '+' and the '...' still drags the window (got $hitDrag)"

    $hitOver = HitAt $h (ClientX $m.CaptionOverflowX) $btnY
    $maxL = $m.ClientW - $m.PadSm - $m.BtnPaint - ($m.BtnPaint + $m.PadSm)
    $hitMax = HitAt $h (ClientX ($maxL + [int]($m.BtnPaint / 2))) $btnY
    # The top-edge probe aims at the EMPTY band ($dragX), not the window's
    # midpoint: since T266 the tabs own their full height (measured WT
    # parity), so a midpoint that lands on the tab run answers HTCLIENT by
    # design and the resize edge lives beside the tabs and in the corners.
    $hitTop = HitAt $h $dragX ($win.Top + 1)
    Check ($hitOver -eq $HTSYSMENU) "the '...' still answers HTSYSMENU (got $hitOver)"
    Check ($hitMax -eq $HTMAXBUTTON) `
        "maximize still answers HTMAXBUTTON, so Snap Layouts survives the merge (got $hitMax)"
    Check (($hitTop -eq $HTTOP) -or ($hitTop -eq $HTTOPLEFT) -or ($hitTop -eq $HTTOPRIGHT)) `
        "the window's top edge still resizes even with tabs in that row (probed the empty band, got $hitTop)"

    # --- 7. maximized: the row is not clipped off the screen ------------------
    # The classic custom-frame bug. A maximized window's frame hangs off every
    # edge of the monitor, so a band drawn at client y = 0 without the extra
    # top padding is simply unreachable - and with the tabs in it now, that
    # would take the whole tab run with it.
    # Through the real WM_SYSCOMMAND path, not ShowWindow: SC_MAXIMIZE is what
    # the maximize button posts, and it is the path WM_NCCALCSIZE's maximized
    # branch runs on.
    [void](Send-TestSysCommand -Window $h -Command maximize)
    $zoomed = $false
    for ($t = 0; $t -lt 25; $t++) {
        Start-Sleep -Milliseconds 200
        if (Test-TestWindowZoomed -Window $h) { $zoomed = $true; break }
    }
    Check $zoomed 'setup: the window maximized'
    Start-Sleep -Milliseconds 800
    $cliZ = Get-TestWindowRect -Window $h -Client
    $mZ = Get-TestChromeMetrics -Window $h -StripVisible $true
    $panesZ = @(Get-TestChildWindows -Window $h -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panesZ.Count -ge 1) {
        Check (($panesZ[0].Top - $cliZ.Top) -eq $mZ.ChromeH) `
            "maximized, the chrome is still exactly one row ($($panesZ[0].Top - $cliZ.Top), expected $($mZ.ChromeH))"
    } else {
        Bad 'maximized: no visible pane to measure'
    }
    $tabsZ = @(Get-TestTabExtents -Window $h -Metrics $mZ)
    Check ($tabsZ.Count -ge 1) `
        "maximized, the tabs are still painted and not clipped off the top ($($tabsZ.Count) found)"
    $hitCloseZ = HitAt $h ($cliZ.Left + $mZ.ClientW - 2) ($cliZ.Top + $mZ.CaptionBtnTop + 2)
    Check ($hitCloseZ -eq $HTCLOSE) `
        "maximized, the top-right corner is still close, not empty band (got $hitCloseZ)"

    Write-Host ''
    if ($script:fail -eq 0) {
        Write-Host "ALL PASS ($script:pass assertions)"
        $exitCode = 0
    } else {
        Write-Host "$script:fail FAILURE(S) ($script:pass passed)"
        $exitCode = 1
    }
} catch {
    Write-Host ''
    Write-Host "1 FAILURE(S) - $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Kill-App $app
    # Leave no maximized placement behind for the next debug window (see the
    # launch above). After Kill-App, so the app cannot rewrite it on exit.
    Remove-Item "$env:LOCALAPPDATA\ghoztty\window_placement-debug" -Force -ErrorAction SilentlyContinue
    Remove-TestDesktop
}
exit $exitCode
