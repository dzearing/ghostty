# T202 acceptance: the tab strip's geometry, shape and selection idiom.
#
# The strip used to hand the LAST tab all the remaining width, so a single tab
# spanned the whole window - which flung the close button to the far edge,
# jammed the "+" against the tab, and stretched the selected-tab accent into a
# full-width blue rule under the strip. That rule is gone: a tab NEVER takes
# the remainder. The selected tab is a rounded-top chiclet filled with the
# CONTENT background (WinUI TabView's selection cue - no underline), the "+"
# travels with the last tab and the "=" menu button stays pinned right, with a
# real gap between the groups.
#
# T235 replaced the other half of that rule. A tab used to be its equal share
# of the strip clamped to [60, 200] DIP, and the 200 truncated titles while
# most of the strip sat empty (". Fix background p..." on a wide window). A tab
# is now its OWN CONTENT's width, floored at 60 DIP and capped at 50% OF THE
# TAB RUN - a proportion of the container, not a DIP constant - and falls back
# to the equal share only when the preferred widths do not all fit. So this
# script derives its expectations from the MEASURED tab and the measured run;
# the only place 200 DIP still appears is section 7, as the retired constant a
# long title must now be allowed to exceed.
# Measured target: docs/design/win32-tab-strip.md. Geometry: tab_strip_layout.zig.
#
# One hermetic GUI launch (--config-default-files=false, black background,
# --window-show-tab-bar=always so a SINGLE tab still shows the strip - the
# configuration the user screenshotted):
#   1. Client origin + bar height from the client rect vs the pane child's rect
#      -> DPI scale -> every DIP constant (self-relative, so this holds at any
#      DPI; the pane-banner.ps1 section 6g rule).
#   2. A scanline near the BOTTOM of the strip (below the title baseline) is
#      pure content-black inside the selected chiclet and bar-gray outside it,
#      so one row of pixels yields the selected tab's exact extent.
#   3. That extent is the oracle for tab COUNT too: the selected chiclet's
#      left edge is strip_pad + (index * tab_w), so a click that creates a tab
#      moves it right by exactly one tab width, and a click that creates
#      nothing leaves it put.
#
# T218: migrated onto the BACKGROUND test desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted here, not assumed. This
# script was already captured with PrintWindow(PW_RENDERFULLCONTENT), which is
# exactly the capture path that survives off the input desktop (the tab strip
# is GDI-painted CHROME - the half of the CAPTURE LIMIT that migrates), so the
# pixel oracle is unchanged. What did change:
#
#   * Clicks are POSTED at the TOP-LEVEL window, which is what paints and
#     hit-tests the strip. SetCursorPos + mouse_event is refused off the input
#     desktop.
#   * ctrl+t goes through Send-TestKeys, re-resolving the focused surface every
#     time: each new tab is a NEW GhozttyTerminal child, and a chord posted at
#     the previous one is silently dropped (T218 batch 1).
#   * The cursor parking is gone. It existed so no tab painted a hover fill,
#     and a background desktop has no pointer over the window at all.
#   * The menu window is found with Get-TestWindow (desktop-scoped), not
#     FindWindowW, which searches the caller's desktop and would never see it.
#   * Every capture is guarded by Get-TestDistinctColors: a window captured
#     mid-paint comes back solid black, and solid black reads as "the chiclet
#     spans everything" AND "no accent pixels anywhere" - one false FAIL and
#     one false PASS from the same bad frame.
#
# NEGATIVE CONTROL: -NegativeControl inverts the single-tab-width assertion
# (asserts the tab DOES span the client width) and MUST fail. The deeper
# source-level control still stands for the geometry claims: flip T202_NEUTERED
# in src/apprt/win32/tab_strip_layout.zig to `true`, rebuild
# `-Dapp-runtime=win32`, re-run - the single-tab-width, the 50%-of-the-run cap
# and the last-tab->"+" gap assertions must fail; the accent-rule and
# click/hit-test assertions must not. (T235 changed WHAT bounds a tab's width,
# not the neuter: the neuter restores "last tab takes the remainder", which is
# still the rule the cap assertions catch.)
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-tabstriptest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
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
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserts a single tab DOES span the client width - this run MUST fail'
}

try {
    # -----------------------------------------------------------------------
    # Launch. Black background so "content background" is unmistakable in
    # pixels: the selected chiclet is (0,0,0) and the strip around it is
    # (20,20,20).
    # -----------------------------------------------------------------------
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        '--background=#000000',
        '--window-show-tab-bar=always',
        '--session-persistence=false'
    )
    Start-Sleep -Seconds 4
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'the window is NOT enumerable on the interactive desktop'

    $cr = Get-TestWindowRect -Window $top -Client
    $wr = Get-TestWindowRect -Window $top
    $clientX = $cr.Left; $clientY = $cr.Top; $clientW = $cr.Width
    # Window-relative client origin, which is what the capture's bitmap uses.
    $offX = $clientX - $wr.Left
    $offY = $clientY - $wr.Top

    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes.Count -ne 1) { Write-Host "SETUP FAIL: expected 1 visible pane, got $($panes.Count)"; exit 1 }
    $barH = $panes[0].Top - $clientY
    Assert ($barH -gt 0) "positive control: the tab bar is visible with a single tab (barH=$barH)"
    if ($barH -le 0) { exit 1 }

    if (-not (Focus-TestWindow -Window $top -Child ([IntPtr]$panes[0].Hwnd))) {
        Write-Host 'SETUP FAIL: could not focus the GUI'; exit 1
    }

    # Every constant is derived from the measured bar height, so this holds at
    # any DPI (bar_h is 40 DIP by definition since T232 - it is 4 + 4 + 28 + 4,
    # the shared icon-button square plus its clearances; see
    # docs/design/win32-design-system.md and docs/design/win32-tab-strip.md).
    $scale   = $barH / 40.0
    # The RETIRED fixed cap (T202's max_tab_w). Kept only so section 7 can
    # assert a long title is no longer pinned to it.
    $maxTabWOld = [int][math]::Round(200 * $scale)
    # The PAINTED square, which is what every gap is measured against (T232).
    # The hit box is this plus btnPad a side, and is deliberately invisible.
    $btnPaint = [int][math]::Round(28 * $scale)
    $btnPad   = [int][math]::Round(2 * $scale)
    $btnW    = $btnPaint + 2 * $btnPad
    $gap     = [int][math]::Round(8 * $scale)
    $padL    = [int][math]::Round(4 * $scale)
    $padR    = $padL   # the strip is inset the SAME at both ends
    $minTabW = [int][math]::Round(60 * $scale)
    # A tab's SLOT includes the inter-tab gap; the drawn chiclet gives it up
    # (tab_strip_layout.zig: drawn_w = this_w - tab_gap), so a chiclet always
    # measures one gap narrower than the slot it sits in. Comparing a measured
    # chiclet against a slot width - which is what this script did before T218 -
    # is off by exactly one gap and fails against a correct strip.
    $tabGap  = [int][math]::Round(4 * $scale)
    # The tab RUN: the client width less both insets and the "+"/"=" band. This
    # is tab_strip_layout.runWidth, and the proportional cap is half of it, so
    # the script and the layout module have to mean the same run.
    $runW    = $clientW - $padR - $btnPaint - $gap - $btnPaint - $gap - $padL
    $capW    = [math]::Max([int][math]::Floor($runW / 2), $minTabW)
    Write-Host "INFO  scale=$scale clientW=$clientW runW=$runW cap=$capW (retired maxTabW=$maxTabWOld) btnW=$btnW gap=$gap pad=$padL"

    # --- Pixel helpers -----------------------------------------------------
    # A scanline 2px above the strip's bottom: below the title/close baseline,
    # and inside the chiclet at full width (its rounding is on the TOP corners
    # only). Coordinates below are CLIENT-relative x plus the window-relative
    # client origin, i.e. exactly the pre-migration math.
    function Get-Shot {
        for ($t = 0; $t -lt 20; $t++) {
            $s = Get-TestWindowPixels -Window $top
            if ((Get-TestDistinctColors -Shot $s) -ge 8) { return $s }
            Close-TestWindowPixels $s
            Start-Sleep -Milliseconds 150
        }
        throw 'Get-Shot: the window never captured with real content (flat fill only)'
    }

    # The LONGEST dark run on the scanline, not the first one. The chiclet's
    # rounded left edge antialiases to a dark pixel, a lighter pixel or two,
    # then the fill - so "first dark pixel until the first light one" measured a
    # 1px-wide tab off the capture and failed four assertions against a
    # perfectly healthy strip. (On a screen grab that edge blended differently
    # and the old scan got away with it.) The fill is ~(3,3,3) against a
    # (20,20,20) bar here, hence the <10 threshold rather than pure black.
    function Selected-Extent($shot) {
        $y = $offY + $barH - 2
        $left = -1; $right = -1
        $runStart = -1
        for ($x = 0; $x -le $clientW; $x++) {
            $dark = $false
            if ($x -lt $clientW) {
                $p = $shot.Bitmap.GetPixel($offX + $x, $y)
                $dark = ($p.R -lt 10 -and $p.G -lt 10 -and $p.B -lt 10)
            }
            if ($dark) {
                if ($runStart -lt 0) { $runStart = $x }
            } elseif ($runStart -ge 0) {
                if (($x - $runStart) -gt ($right - $left)) { $left = $runStart; $right = $x }
                $runStart = -1
            }
        }
        return @($left, $right)
    }

    # Tab index of the selected tab, read back out of its chiclet's left edge:
    # left = padL + index * tabW. The count oracle for every click below.
    function Selected-Index([int]$left, [int]$tabW) {
        if ($tabW -le 0) { return -1 }
        return [int][math]::Round(($left - $padL) / $tabW)
    }

    function Any-Accent-Blue($shot) {
        # The deleted underline was RGB(0x3D,0x8E,0xF8). Sweep the bottom 3 rows
        # of the whole strip: nothing anywhere may still be painting it.
        for ($dy = 1; $dy -le 3; $dy++) {
            $y = $offY + $barH - $dy
            for ($x = 0; $x -lt $clientW; $x += 2) {
                $p = $shot.Bitmap.GetPixel($offX + $x, $y)
                if ([math]::Abs($p.R - 0x3D) -le 24 -and [math]::Abs($p.G - 0x8E) -le 24 -and [math]::Abs($p.B - 0xF8) -le 24) { return $true }
            }
        }
        return $false
    }

    # A click on the strip, posted where a real one would land.
    function Strip-Click([int]$cx) {
        [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $cx) -Y ($clientY + [int]($barH / 2)) -Button left -Action click)
        Start-Sleep -Milliseconds 300
    }

    # ctrl+t at the CURRENTLY focused surface: every new tab is a new child.
    function New-Tab {
        $fw = Get-TestFocusedWindow -Window $top
        if ($fw -eq 0) {
            $vis = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
            if ($vis.Count -gt 0) { $fw = $vis[0].Hwnd }
        }
        [void](Send-TestKeys -Window $top -Target ([IntPtr]$fw) -Modifiers ctrl -Key T)
        Start-Sleep -Milliseconds 250
    }

    # -----------------------------------------------------------------------
    # 1. A single tab does not span the client width
    # -----------------------------------------------------------------------
    $shot = Get-Shot
    $ext = Selected-Extent $shot
    $tabLeft = $ext[0]; $tabRight = $ext[1]
    $tabW = $tabRight - $tabLeft
    Write-Host "INFO  single tab: left=$tabLeft right=$tabRight w=$tabW"
    Assert ($tabLeft -ge 0) 'single tab: the selected chiclet is painted in the content background'
    if ($NegativeControl) {
        Assert ($tabW -ge ($clientW / 2)) "NEGATIVE CONTROL: single tab spans the client width (w=$tabW of $clientW)"
    } else {
        Assert ($tabW -gt 0 -and $tabW -lt ($clientW / 2)) "single tab: does NOT span the client width (w=$tabW of $clientW)"
    }
    # T235: the width is the title's, so the script cannot predict it - but it
    # is bounded on both sides, and those bounds are the rule.
    Assert ($tabW -le ($capW - $tabGap + 3)) `
        "single tab: never wider than 50% of the tab run ($tabW <= $capW - $tabGap)"
    Assert ($tabW -ge ($minTabW - $tabGap - 3)) `
        "single tab: never narrower than the floor ($tabW >= $minTabW - $tabGap)"
    Assert ([math]::Abs($tabLeft - $padL) -le 2) "single tab: starts at the strip's left inset ($tabLeft vs $padL)"
    # Slot pitch, which is what a tab INDEX is measured in below. Every tab in
    # this window runs the same shell in the same directory, so they all carry
    # the same title and the run is uniform - which is what lets a left edge be
    # read back as an index at all.
    $slotW = $tabW + $tabGap

    # -----------------------------------------------------------------------
    # 2. No full-width accent rule under the strip
    # -----------------------------------------------------------------------
    Assert (-not (Any-Accent-Blue $shot)) 'selection: the full-width blue accent rule is gone (no accent pixels in the strip)'
    $midStripX = [int](($tabRight + $clientW - $padR - 2 * $btnPaint - $gap) / 2)
    $px = $shot.Bitmap.GetPixel($offX + $midStripX, $offY + $barH - 2)
    Assert ($px.R -ge 10 -and $px.R -le 40) "strip: dead space right of the tab is bar background, not tab or accent (R=$($px.R))"

    # -----------------------------------------------------------------------
    # 2c. T242: the selected chiclet's SEAM row carries no rim.
    #
    #     User report, 2026-07-31: "the active tab seems to have a horizontal
    #     line at the bottom, making it feel disconnected from the pane below."
    #     The whole selection idiom is that the chiclet MERGES into the pane, so
    #     a line across its baseline undoes section 2 above by another means.
    #     Cause: the rim was derived from the baseline-CLIPPED distance field,
    #     so it traced the clip - RIM_BOT (0.04) of white over a (0,0,0) fill is
    #     ~10 levels, across the tab's full width.
    #
    #     Oracle: the strip's LAST row inside the chiclet must be no brighter
    #     than an interior row of the same fill. Sampled at several x so a
    #     single stray pixel neither passes nor fails it.
    # -----------------------------------------------------------------------
    $seamY  = $offY + $barH - 1
    $innerY = $offY + $barH - 5
    $seamMax = 0; $innerMax = 0; $seamAt = -1
    for ($x = $tabLeft + 8; $x -lt $tabRight - 8; $x += 4) {
        $ps = $shot.Bitmap.GetPixel($offX + $x, $seamY)
        $pi = $shot.Bitmap.GetPixel($offX + $x, $innerY)
        $sl = [int]$ps.R + $ps.G + $ps.B
        $il = [int]$pi.R + $pi.G + $pi.B
        if ($sl -gt $seamMax) { $seamMax = $sl; $seamAt = $x }
        if ($il -gt $innerMax) { $innerMax = $il }
    }
    Write-Host "INFO  seam row: max=$seamMax (x=$seamAt) vs interior max=$innerMax"
    Assert ($seamMax -le ($innerMax + 6)) `
        "selection: the chiclet's seam row is the pane's own fill, not a rim (seam=$seamMax interior=$innerMax)"

    # -----------------------------------------------------------------------
    # 2b. T232, in pixels: the "+" glyph's own margins, and its symmetry.
    #
    #     The user's report was "the plus icon has a huge left gap and no
    #     bottom gap ... it looks like its left half of the horizontal line of
    #     the plus is shorter than the right half". Both are measurable off the
    #     capture, and both were true: at 125% the plus square sat 16 px from
    #     the tab and 1 px from the strip's bottom edge, and the mark itself
    #     was a pen stroke, whose trailing pixel `LineTo` drops.
    # -----------------------------------------------------------------------
    # Everything lit inside the "+"'s slot. The menu button is far to the
    # right, so a window this wide cannot catch it in the scan.
    $scanL = $tabRight + 1
    $scanR = [math]::Min($tabRight + $gap + $btnPaint + $gap, $clientW - 1)
    $mLeft = -1; $mRight = -1; $mTop = -1; $mBot = -1
    $rowW = @{}; $colH = @{}
    for ($x = $scanL; $x -le $scanR; $x++) {
        for ($y = 0; $y -lt $barH; $y++) {
            $p = $shot.Bitmap.GetPixel($offX + $x, $offY + $y)
            if (($p.R + $p.G + $p.B) -lt 150) { continue }
            if ($mLeft -lt 0 -or $x -lt $mLeft) { $mLeft = $x }
            if ($x -gt $mRight) { $mRight = $x }
            if ($mTop -lt 0 -or $y -lt $mTop) { $mTop = $y }
            if ($y -gt $mBot) { $mBot = $y }
            if ($rowW.ContainsKey($y)) { $rowW[$y] += 1 } else { $rowW[$y] = 1 }
            if ($colH.ContainsKey($x)) { $colH[$x] += 1 } else { $colH[$x] = 1 }
        }
    }
    Assert ($mLeft -ge 0) 'plus glyph: found lit pixels in the + button slot (positive control for 2b)'
    if ($mLeft -ge 0) {
        $gapLeft = $mLeft - $tabRight       # tab's painted edge -> mark
        $gapBot  = $barH - 1 - $mBot        # mark -> strip's bottom edge
        $gapTop  = $mTop
        Write-Host "INFO  + glyph: x=$mLeft..$mRight y=$mTop..$mBot gapLeft=$gapLeft gapTop=$gapTop gapBot=$gapBot"
        Assert ($gapBot -ge 2) "plus: has a real BOTTOM gap, not 1px (gapBot=$gapBot)"
        # The headline number. Before T232 this pair was 26:11 for the mark and
        # 16:1 for the square it sits in.
        $lo = [math]::Min($gapLeft, $gapBot); $hi = [math]::Max($gapLeft, $gapBot)
        Assert ($hi -le [int]([math]::Ceiling($lo * 1.5))) `
            "plus: left and bottom gaps are within 1.5x of each other ($gapLeft vs $gapBot)"

        # Symmetry: the widest lit row is the "+"'s horizontal bar, the tallest
        # lit column its vertical bar. The two arms of the horizontal bar must
        # be the same length either side of the vertical bar.
        $barRow = ($rowW.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        $stemCol = ($colH.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        $hL = $clientW; $hR = -1
        for ($x = $scanL; $x -le $scanR; $x++) {
            $p = $shot.Bitmap.GetPixel($offX + $x, $offY + $barRow)
            if (($p.R + $p.G + $p.B) -lt 150) { continue }
            if ($x -lt $hL) { $hL = $x }
            if ($x -gt $hR) { $hR = $x }
        }
        # The stem is `stroke_w` wide; take its whole extent so the two arms
        # are measured from the same object.
        $sL = $clientW; $sR = -1
        foreach ($k in $colH.Keys) { if ($colH[$k] -ge ($colH[$stemCol] - 1)) { if ($k -lt $sL) { $sL = $k }; if ($k -gt $sR) { $sR = $k } } }
        $armL = $sL - $hL
        $armR = $hR - $sR
        Write-Host "INFO  + arms: row=$barRow h=$hL..$hR stem=$sL..$sR armL=$armL armR=$armR"
        Assert ([math]::Abs($armL - $armR) -le 1) `
            "plus: the two halves of the horizontal bar are the same length (armL=$armL armR=$armR)"
    }

    # -----------------------------------------------------------------------
    # 3. There is a real gap between the last tab and the "+", and clicking in
    #    that gap does nothing
    # -----------------------------------------------------------------------
    Strip-Click ($tabRight + [int]($gap / 2))
    Close-TestWindowPixels $shot; $shot = Get-Shot
    $ext = Selected-Extent $shot
    Assert ((Selected-Index $ext[0] $slotW) -eq 0) 'gap: a click between the last tab and the + creates nothing (still 1 tab)'

    # -----------------------------------------------------------------------
    # 4. The "+" follows the last tab - and moves right when a tab is added
    # -----------------------------------------------------------------------
    # `$gap` past the tab's PAINTED right edge is the "+"'s painted left edge,
    # so half a painted square further right is its centre.
    $plusX = $tabRight + $gap + [int]($btnPaint / 2)
    Strip-Click $plusX
    Start-Sleep -Milliseconds 300
    Close-TestWindowPixels $shot; $shot = Get-Shot
    $ext = Selected-Extent $shot
    $idx = Selected-Index $ext[0] $slotW
    Write-Host "INFO  after + click #1: left=$($ext[0]) right=$($ext[1]) index=$idx"
    Assert ($idx -eq 1) "+ : clicking one gap past the last tab creates tab 2 (selected index=$idx)"
    # Two tabs of the same title still fit their preferred width, so neither
    # shrank: content sizing, not an equal share of whatever is left.
    Assert ([math]::Abs(($ext[1] - $ext[0]) - $tabW) -le 3) `
        "two tabs: each is still its own content's width ($($ext[1] - $ext[0]) vs $tabW)"

    # The second "+" is one tab width further right. If it had stayed pinned
    # where it was, this click would land on tab 2 and create nothing.
    $tabRight2 = $ext[1]
    $plusX2 = $tabRight2 + $gap + [int]($btnPaint / 2)
    Assert ($plusX2 -gt $plusX) "+ : moved right with the new tab ($plusX -> $plusX2)"
    Strip-Click $plusX2
    Start-Sleep -Milliseconds 300
    Close-TestWindowPixels $shot; $shot = Get-Shot
    $ext = Selected-Extent $shot
    $idx = Selected-Index $ext[0] $slotW
    Assert ($idx -eq 2) "+ : clicking at its NEW position creates tab 3 (selected index=$idx)"

    # -----------------------------------------------------------------------
    # 5. Many tabs shrink instead of running off the end of the strip
    # -----------------------------------------------------------------------
    # T235: "enough tabs" is derived from the MEASURED slot, not from a
    # constant. A content-sized tab can be far narrower than the retired 200
    # DIP cap, in which case ceil(clientW / 200) tabs would not fill the run at
    # all and this section would assert nothing.
    $want = [int][math]::Ceiling($runW / $slotW) + 4
    for ($i = 0; $i -lt $want; $i++) { New-Tab }
    Start-Sleep -Milliseconds 800
    Close-TestWindowPixels $shot; $shot = Get-Shot
    $ext = Selected-Extent $shot
    $manyW = $ext[1] - $ext[0]
    Write-Host "INFO  many tabs: left=$($ext[0]) right=$($ext[1]) w=$manyW (preferred was $tabW)"
    # Shrink only UNDER PRESSURE, and this is the pressure: the same title that
    # got its preferred width above now gets less.
    Assert ($manyW -gt 0 -and $manyW -lt $tabW) "many tabs: tab width shrank below its preferred width ($manyW < $tabW)"
    Assert ($manyW -ge ($minTabW - $tabGap - 3)) "many tabs: never below the floor ($manyW >= $minTabW - $tabGap)"
    $bandLeft = $clientW - $padR - 2 * $btnPaint - $gap
    Assert ($ext[1] -le $bandLeft) "many tabs: the tab run never reaches the button band ($($ext[1]) <= $bandLeft)"
    Assert (-not (Any-Accent-Blue $shot)) 'many tabs: still no accent rule anywhere in the strip'
    Close-TestWindowPixels $shot

    # -----------------------------------------------------------------------
    # 6. The menu button is pinned to the right END OF THE STRIP - its PAINTED
    #    square inset by the same padding the first tab gets on the left, not
    #    flush against the window border ("the hamburger button has no gap
    #    between it and the border"). Its hit box is allowed to reach into that
    #    pad (T232: a forgiving click target is free precisely because it is
    #    invisible), so the miss is asserted at the outermost pixel column -
    #    past the hit box, which no amount of forgiveness may cross.
    # -----------------------------------------------------------------------
    Strip-Click ($clientW - 1)
    Start-Sleep -Milliseconds 300
    Assert ((Get-TestWindow -ProcessId $app.Pid -Class '#32768') -eq [IntPtr]::Zero) `
        'right inset: the strip does not run flush to the window border (a click at the edge opens nothing)'

    Strip-Click ($clientW - $padR - [int]($btnPaint / 2))
    $menu = Wait-TestPopupMenu -ProcessId $app.Pid -TimeoutMs 3000
    Assert ($menu -ne [IntPtr]::Zero) 'menu button: still pinned to the right edge and still opens its popup'
    if ($menu -ne [IntPtr]::Zero) {
        # Escape it back closed so teardown is clean. Send-TestControlKey posts
        # without touching focus; Send-TestKeys would SetFocus and dismiss it
        # by accident, which would score this assertion for free.
        [void](Send-TestControlKey -Control $menu -Key Escape)
        Start-Sleep -Milliseconds 400
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'

    # -----------------------------------------------------------------------
    # 7. T235: a long title GROWS its tab instead of being ellipsized.
    #
    #    The user's report, in pixels: ". Fix background p..." truncated in a
    #    single tab on a wide window with most of the strip empty. Sections 1-6
    #    above cannot see this - every tab in that window carries the SAME
    #    shell-set title, so a fixed cap and a content-derived width are
    #    indistinguishable there. This needs two DIFFERENT titles in one window.
    #
    #    Fresh instance, tab 1 launched with `-e cmd.exe /K title <long token>`
    #    so its title is known and long. Then ctrl+t opens tab 2 on the default
    #    shell (a short title) and TAKES the selection - which is what makes
    #    both widths readable off one capture: the selected chiclet is the only
    #    thing the pixel oracle can measure directly, and tab 1's SLOT is
    #    exactly where tab 2's left edge starts.
    # -----------------------------------------------------------------------
    Kill-RepoInstances
    $longTitle = 'TabTitleLongEnoughToHaveBeenTruncatedByTheOldTwoHundredDipCap'
    $app2 = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        '--background=#000000',
        '--window-show-tab-bar=always',
        '--session-persistence=false',
        '-e', 'cmd.exe', '/K', 'title', $longTitle
    )
    Start-Sleep -Seconds 4
    if ($app2.Process -and $app2.Process.HasExited) { Write-Host 'SETUP FAIL: long-title GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: long-title top window not found'; exit 1 }

    # Re-derive the geometry for THIS window: the pixel helpers above read
    # these script-scope variables at call time, so reassigning them re-points
    # them at the new instance.
    $cr = Get-TestWindowRect -Window $top -Client
    $wr = Get-TestWindowRect -Window $top
    $clientX = $cr.Left; $clientY = $cr.Top; $clientW = $cr.Width
    $offX = $clientX - $wr.Left
    $offY = $clientY - $wr.Top
    $panes2 = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes2.Count -lt 1) { Write-Host 'SETUP FAIL: long-title pane not found'; exit 1 }
    $barH = $panes2[0].Top - $clientY
    $runW = $clientW - $padR - $btnPaint - $gap - $btnPaint - $gap - $padL
    $capW = [math]::Max([int][math]::Floor($runW / 2), $minTabW)
    if (-not (Focus-TestWindow -Window $top -Child ([IntPtr]$panes2[0].Hwnd))) {
        Write-Host 'SETUP FAIL: could not focus the long-title GUI'; exit 1
    }

    $shot = Get-Shot
    $ext = Selected-Extent $shot
    $longW = $ext[1] - $ext[0]
    Write-Host "INFO  long title: left=$($ext[0]) right=$($ext[1]) w=$longW runW=$runW cap=$capW"
    Assert ($ext[0] -ge 0) 'long title: the selected chiclet is painted (positive control for section 7)'
    Assert ($longW -le ($capW - $tabGap + 3)) `
        "long title: still capped at 50% of the run ($longW <= $capW - $tabGap)"

    # Second tab, default shell, short title - and it takes the selection.
    Close-TestWindowPixels $shot
    New-Tab
    Start-Sleep -Milliseconds 600
    $shot = Get-Shot
    $ext2 = Selected-Extent $shot
    $shortW = $ext2[1] - $ext2[0]
    $longSlot = $ext2[0] - $padL
    Write-Host "INFO  short title: left=$($ext2[0]) right=$($ext2[1]) w=$shortW; long slot=$longSlot"
    Assert ($shortW -gt 0) 'two titles: the new short-titled tab is selected and measurable'
    # THE assertion. Under a fixed cap both tabs would be the same width; under
    # content sizing the long one is wider, and it is wider by roughly the
    # difference in the two titles.
    Assert ($longSlot -gt ($shortW + $tabGap)) `
        "T235: the long-titled tab is WIDER than the short-titled one (slot=$longSlot vs $($shortW + $tabGap))"
    Assert ([math]::Abs($longSlot - ($longW + $tabGap)) -le 3) `
        "T235: tab 2's left edge is exactly tab 1's slot ($longSlot vs $($longW + $tabGap))"
    # ... and it is allowed past the retired 200 DIP constant. Only checkable
    # when the proportional cap is the looser of the two; say so when it is not,
    # rather than scoring a pass that asserted nothing.
    if (($capW - $tabGap) -gt ($maxTabWOld - $tabGap)) {
        Assert ($longW -gt ($maxTabWOld - $tabGap)) `
            "T235: the long title is no longer pinned to the retired 200 DIP cap ($longW > $($maxTabWOld - $tabGap))"
    } else {
        Write-Host "INFO  skipped the retired-cap comparison: this window's 50% cap ($capW) is tighter than 200 DIP ($maxTabWOld)"
    }
    Close-TestWindowPixels $shot
    Assert (-not ($app2.Process -and $app2.Process.HasExited)) 'no crash (long-title instance)'
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
