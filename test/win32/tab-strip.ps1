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
#   1. DPI scale from the window itself -> every DIP constant, including the
#      caption band T254 moved into the client area; the strip's height is then
#      the REMAINDER between that band and the pane child's top, so a wrong
#      caption offset fails loudly instead of skewing every measurement (T256).
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
# T209 added the APPEARANCE layer these geometry assertions never had -
# section 2e (the glyphs sit on one frame, each centered in its square),
# section 4b (the tab silhouette: inactive surface, gap, gradient rim, flare,
# antialiasing) and section 4c (the close "x" hot-tracks and acts where it
# paints). Both source-level controls were WIDENED to cover them, because both
# were claiming more than they did: T204_NEUTERED left every glyph exactly
# where the shipped build puts it (`glyphCentered()` was consumed by nobody),
# and T206_NEUTERED left the flare and the antialiasing on.
#
#   * T204_NEUTERED (icon_button.zig) - centering fails; expect section 2b's
#     "+ left and bottom gaps" to fail WITH it, since that gap is measured
#     from the mark and the control is what moves the mark.
#   * T206_NEUTERED (tab_shape.zig) - the four section-4b shape assertions
#     fail; nothing in 1-3 or 5-7 does.
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
    # stderr is captured so section 4c can read the `tab hover ...` debug
    # oracle: a posted hover cannot survive to a pixel capture on this desktop
    # (T233), so the TRIGGER is read from the log and the FILL is probed with a
    # positive control. Empty on a release build, where log.debug is compiled
    # out - that section then skips rather than lying.
    $errlog = Join-Path $env:TEMP 'ghoztty-tabstrip-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false',
        '--background=#000000',
        '--window-show-tab-bar=always',
        '--session-persistence=false'
    )
    Start-Sleep -Seconds 4
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

    # SIZE THE WINDOW. Not cosmetic and not optional (T205): every condition
    # this script sets up is a RATIO of the tab run - "two tabs still get their
    # preferred width", "enough tabs to force a shrink" - and the run is
    # `clientW - 225` at this DPI. Left to the app's default the window came up
    # at 782 client px, the run was 557, and three preferred tabs (281 each) no
    # longer fit: three assertions went red against a correct build.
    #
    # It only surfaced now because the script never set a size and was silently
    # inheriting whatever `window_placement-debug` (T85) remembered from the
    # last GUI script that ran - so its conditions depended on RUN ORDER. That
    # is the same class of hazard as T248's target reuse; see T267.
    Set-TestWindowSize -Window $top -Width 1400 -Height 800 | Out-Null
    Start-Sleep -Milliseconds 1200

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'the window is NOT enumerable on the interactive desktop'

    # T254/T256: the strip no longer begins at client y = 0. The caption band is
    # client area now, so the pane's top is caption + strip, and every y below
    # is measured from `$m.StripTop` rather than from the client's own top.
    #
    # T257: this used to be ~20 lines of private DIP arithmetic, which is how
    # T254 cost this script 7 failures and T235 cost menu-bar.ps1 4 more. It is
    # one call now, and T205 - which moves the strip INTO the caption row -
    # edits lib\ChromeGeometry.ps1, not this script. The metrics come from the
    # window's own DPI by the same construction the layout modules use, so
    # nothing here is a fixed pixel count.
    # -StripVisible $true: this window launches --window-show-tab-bar=always, so
    # since T205 its strip lives IN the caption row and starts at client y = 0.
    $m = Get-TestChromeMetrics -Window $top -StripVisible $true
    $clientX = $m.ClientLeft; $clientY = $m.ClientTop; $clientW = $m.ClientW
    # Window-relative client origin, which is what the capture's bitmap uses.
    $offX = $m.OffX
    $offY = $m.OffY
    $scale = $m.Scale
    $sm    = $m.PadSm
    $sq    = $m.BtnPaint
    $capH  = $m.CaptionH

    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes.Count -ne 1) { Write-Host "SETUP FAIL: expected 1 visible pane, got $($panes.Count)"; exit 1 }
    # MEASURED off the pane's own top, deliberately - the derived `$m.BarH` is
    # what it is checked AGAINST. Comparing a measurement to its construction is
    # the positive control for both numbers at once: a wrong `$capH` shows up
    # here as a wrong `$barH`. (Reading both from the helper would assert the
    # helper against itself and prove nothing.)
    # T205: `StripTopClient`, not `$capH` - merged, the caption band IS the
    # strip's row, so subtracting the band height would land below the strip.
    $barH = $panes[0].Top - $clientY - $m.StripTopClient
    # Window-relative y of the strip's FIRST row, which is what the capture's
    # bitmap is indexed by.
    $stripTop = $m.StripTop
    Assert ($barH -eq $m.BarH) `
        "positive control: the tab bar is visible IN the caption row (stripTop=$($m.StripTopClient) capH=$capH barH=$barH, expected $($m.BarH))"
    if ($barH -le 0) { exit 1 }

    if (-not (Focus-TestWindow -Window $top -Child ([IntPtr]$panes[0].Hwnd))) {
        Write-Host 'SETUP FAIL: could not focus the GUI'; exit 1
    }

    # Everything below is derived from `$scale` above, so it holds at any DPI
    # (see docs/design/win32-design-system.md and docs/design/win32-tab-strip.md).
    # The RETIRED fixed cap (T202's max_tab_w). Kept only so section 7 can
    # assert a long title is no longer pinned to it.
    $maxTabWOld = Get-TestChromeDip -Dip 200.0 -Scale $scale
    # The PAINTED square, which is what every gap is measured against (T232).
    # The hit box is this plus btnPad a side, and is deliberately invisible.
    $btnPaint = $m.BtnPaint
    $btnPad   = $m.BtnPad
    $btnW    = $m.BtnW
    $gap     = $m.Gap
    $padL    = $m.PadL
    $padR    = $m.PadR   # the strip is inset the SAME at both ends
    $minTabW = $m.MinTabW
    # A tab's SLOT includes the inter-tab gap; the drawn chiclet gives it up
    # (tab_strip_layout.zig: drawn_w = this_w - tab_gap), so a chiclet always
    # measures one gap narrower than the slot it sits in. Comparing a measured
    # chiclet against a slot width - which is what this script did before T218 -
    # is off by exactly one gap and fails against a correct strip.
    $tabGap  = $m.TabGap
    # The tab RUN: the client width less both insets and the "+"/"=" band. This
    # is tab_strip_layout.runWidth, and the proportional cap is half of it, so
    # the script and the layout module have to mean the same run.
    $runW    = $m.RunW
    $capW    = $m.TabCap
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
        $y = $stripTop + $barH - 2
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
            $y = $stripTop + $barH - $dy
            for ($x = 0; $x -lt $clientW; $x += 2) {
                $p = $shot.Bitmap.GetPixel($offX + $x, $y)
                if ([math]::Abs($p.R - 0x3D) -le 24 -and [math]::Abs($p.G - 0x8E) -le 24 -and [math]::Abs($p.B - 0xF8) -le 24) { return $true }
            }
        }
        return $false
    }

    # A click on the strip, posted where a real one would land.
    function Strip-Click([int]$cx) {
        [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $cx) -Y ($clientY + $m.StripTopClient + [int]($barH / 2)) -Button left -Action click)
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
    $px = $shot.Bitmap.GetPixel($offX + $midStripX, $stripTop + $barH - 2)
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
    $seamY  = $stripTop + $barH - 1
    $innerY = $stripTop + $barH - 5
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
            $p = $shot.Bitmap.GetPixel($offX + $x, $stripTop + $y)
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
            $p = $shot.Bitmap.GetPixel($offX + $x, $stripTop + $barRow)
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
    # 2e. T209 / T204: the glyphs sit on ONE frame, each centered in its own
    #     square.
    #
    #     T204 shipped the shared button model with its geometry unit-tested
    #     in both lanes and NOTHING asserting that the PAINT uses it. That is
    #     the gap this closes: the pure tests pin `targetBox`, these pin that
    #     the marks actually land in it.
    #
    #     Two independent claims, and they fail for different reasons:
    #       * the "+" and the active tab's close "x" share a vertical center,
    #         which is what "one frame" means and what T205's merged row had
    #         to preserve;
    #       * each mark is centered on BOTH axes of its own painted square,
    #         which is what the user asked for ("centered icons").
    #
    #     NEGATIVE CONTROL: T204_NEUTERED in icon_button.zig makes
    #     `glyphTarget` leading-align every glyph, so the horizontal-centering
    #     assertions fail by ~(square - mark)/2 px while the vertical ones and
    #     everything in sections 1-7 stay green.
    # -----------------------------------------------------------------------
    # The close button's PAINTED square, from `Metrics.closeRect` +
    # `icon_button.targetBox` - the same two steps Window.zig takes. Its y is
    # exact (StripBtnTop is derived, not measured); its x rides on the measured
    # tab edge, hence the wider tolerance on the horizontal claim below.
    $closeHitL = $tabRight - $sm - $btnPaint - $btnPad
    $closeHitR = $tabRight - $sm + $btnPad
    $closeCx = [int][Math]::Truncate(($closeHitL + $closeHitR) / 2)
    $closeSqL = $closeCx - [int][Math]::Truncate($btnPaint / 2)
    $closeSqR = $closeSqL + $btnPaint
    $btnTop = $m.StripBtnTop
    $btnBot = $btnTop + $btnPaint

    # Lit pixels inside that square. The title's box stops `pad_sm` short of
    # the close button's painted left edge, so nothing in here is text.
    $xL = -1; $xR = -1; $xT = -1; $xB = -1
    for ($x = $closeSqL; $x -lt $closeSqR; $x++) {
        for ($y = $btnTop; $y -lt $btnBot; $y++) {
            $p = $shot.Bitmap.GetPixel($offX + $x, $stripTop + $y)
            if (($p.R + $p.G + $p.B) -lt 150) { continue }
            if ($xL -lt 0 -or $x -lt $xL) { $xL = $x }
            if ($x -gt $xR) { $xR = $x }
            if ($xT -lt 0 -or $y -lt $xT) { $xT = $y }
            if ($y -gt $xB) { $xB = $y }
        }
    }
    Assert ($xL -ge 0) 'close x: the active tab paints a close glyph (positive control for 2e)'
    if ($xL -ge 0 -and $mLeft -ge 0) {
        # 1. ONE FRAME. Both centers are measured, so no derived x or y enters
        #    this at all - it is the purest form of the claim.
        $plusCy = ($mTop + $mBot) / 2.0
        $closeCy = ($xT + $xB) / 2.0
        Write-Host "INFO  glyph rows: + cy=$plusCy (y=$mTop..$mBot), x cy=$closeCy (y=$xT..$xB)"
        Assert ([math]::Abs($plusCy - $closeCy) -le 1.0) `
            "T204: the + and the close x share a vertical center ($plusCy vs $closeCy)"

        # 2. CENTERED IN ITS OWN SQUARE. Vertically the square is exact, so 1
        #    px. Horizontally both edges ride on the measured `$tabRight`,
        #    which reads ONE PIXEL SHORT by construction: the tab's last fill
        #    column carries the side rim, and the rim is brighter than the
        #    "is this the chiclet?" threshold. That 1 px moves the centering
        #    delta by 2, so the shipped build sits at +2 and the bound is 3.
        #    The neuter's leading alignment is ~13 px, so it is still nowhere
        #    near this bound.
        $closeDx = ($xL - $closeSqL) - (($closeSqR - 1) - $xR)
        $closeDy = ($xT - $btnTop) - (($btnBot - 1) - $xB)
        Write-Host "INFO  close x centering: dx=$closeDx dy=$closeDy (square x=$closeSqL..$closeSqR y=$btnTop..$btnBot)"
        Assert ([math]::Abs($closeDx) -le 3) "T204: the close x is centered horizontally in its square (dx=$closeDx)"
        Assert ([math]::Abs($closeDy) -le 1) "T204: the close x is centered vertically in its square (dy=$closeDy)"

        $plusSqL = $tabRight + $gap
        $plusSqR = $plusSqL + $btnPaint
        $plusDx = ($mLeft - $plusSqL) - (($plusSqR - 1) - $mRight)
        $plusDy = ($mTop - $btnTop) - (($btnBot - 1) - $mBot)
        Write-Host "INFO  + centering: dx=$plusDx dy=$plusDy (square x=$plusSqL..$plusSqR)"
        Assert ([math]::Abs($plusDx) -le 3) "T204: the + is centered horizontally in its square (dx=$plusDx)"
        Assert ([math]::Abs($plusDy) -le 1) "T204: the + is centered vertically in its square (dy=$plusDy)"
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
    # 4b. T209 / T206: the tab SHAPE, in pixels.
    #
    #     T206 answered the user's report - "inactive tabs should be visible
    #     somewhat and tabs should have gaps in between ... the bottom corners
    #     of the selected tab should curve into the edge ... don't you see how
    #     the edge of the banner has this gradient highlight border? tabs
    #     should too" - with a per-pixel composite, unit-tested and eyeballed
    #     but never asserted on the box. Three tabs are open here, so there is
    #     an inactive tab, a gap, and a selected tab with open strip to its
    #     right, which is every condition the four claims need.
    #
    #     NEGATIVE CONTROL: T206_NEUTERED in tab_shape.zig restores the flat
    #     pre-T206 look - no inactive fill, no rim, no flare, hard edges - so
    #     all four fail together and sections 1-7 do not.
    # -----------------------------------------------------------------------
    Close-TestWindowPixels $shot; $shot = Get-Shot
    $tabs = @(Get-TestTabExtents -Window $top -Shot $shot -Metrics $m)
    Write-Host "INFO  shape: $($tabs.Count) tabs measured"
    if ($tabs.Count -lt 3) {
        # Three tabs are open (section 4 proved it by index), so "fewer than
        # three are MEASURABLE" is not a setup problem - it is assertion 5
        # failing in its bluntest form: an unselected tab that paints nothing
        # is indistinguishable from the strip, which is the pre-T206 world and
        # what T206_NEUTERED restores. Named as such so the control reports the
        # claim rather than a shrug.
        Assert $false ("T206: an inactive tab is invisible against the strip - " +
                       "only $($tabs.Count) of 3 open tabs could be measured at all")
    }
    # NOT `else`. The inactive-surface claim above and the silhouette claims
    # below are independent, and the silhouette ones only need the SELECTED
    # tab - which is measurable in every world, including the one the neuter
    # restores. Running them under an `else` meant the control could only ever
    # show ONE of the four failing, which is precisely the "green because it
    # never got there" shape these assertions exist to avoid.
    if ($tabs.Count -ge 1) {
        $rowY   = $stripTop + $barH - 2      # below the title baseline, inside every chiclet
        $tabTop = $stripTop + $m.TabTopPad   # the tab's own top edge, where the rim is brightest
        $sel = $tabs[$tabs.Count - 1]        # section 4 left the LAST tab selected
        $stripBg = $shot.Bitmap.GetPixel($offX + $m.RunRight - 2, $rowY)
        $selFill = $shot.Bitmap.GetPixel($offX + $sel.Center, $rowY)
        Write-Host "INFO  shape: strip=$($stripBg.R) selected fill=$($selFill.R)"

        if ($tabs.Count -ge 3) {
            $ina = $tabs[0]
            $inaFill = $shot.Bitmap.GetPixel($offX + $ina.Center, $rowY)
            Write-Host "INFO  shape: inactive fill=$($inaFill.R)"

            # 5. AN INACTIVE TAB IS A SURFACE. Pre-T206 it painted nothing at
            #    all, so this delta was exactly zero and the strip read as one
            #    bar with text on it. INACTIVE_LIFT is 0.06 of white over the
            #    strip, ~14 levels on a (20,20,20) bar - so the floor is well
            #    clear of noise and well under the real value.
            $inaDelta = [math]::Abs([int]$inaFill.R - [int]$stripBg.R)
            Assert ($inaDelta -ge 6) `
                "T206: an inactive tab is visibly a surface, not bare strip (delta=$inaDelta)"
            # ...and it is NOT the selected tab's fill either, or the selection
            # cue would be gone in the other direction.
            Assert ([math]::Abs([int]$inaFill.R - [int]$selFill.R) -ge 6) `
                "T206: an inactive tab is distinguishable from the SELECTED tab ($($inaFill.R) vs $($selFill.R))"

            # 7. THE GAP between two adjacent tabs is `tab_gap` of strip.
            $gapW = $tabs[1].Left - $tabs[0].Right
            $gapMid = $shot.Bitmap.GetPixel($offX + $tabs[0].Right + [int]($gapW / 2), $rowY)
            Write-Host "INFO  shape: inter-tab gap=$gapW (tab_gap=$($m.TabGap)) mid=$($gapMid.R)"
            Assert ([math]::Abs($gapW - $m.TabGap) -le 2) `
                "T206: adjacent tabs are separated by tab_gap of strip ($gapW vs $($m.TabGap))"
            Assert ([math]::Abs([int]$gapMid.R - [int]$stripBg.R) -le 4) `
                "T206: the pixels in that gap ARE strip background ($($gapMid.R) vs $($stripBg.R))"
        }

        # 6. THE RIM, and that it is a GRADIENT rather than a border.
        #    `rimAlpha` ramps banner_card's own RIM_TOP (0.28) -> RIM_BOT
        #    (0.04) down the tab's height, so the top edge is a bright hairline
        #    and the same rim near the baseline is nearly gone. Measured as a
        #    max over a short scan so one antialiased pixel neither makes nor
        #    breaks it.
        function Max-Lum($shot, [int]$x0, [int]$x1, [int]$y) {
            $best = -1
            for ($x = $x0; $x -le $x1; $x++) {
                $p = $shot.Bitmap.GetPixel($offX + $x, $y)
                $l = [int]$p.R + $p.G + $p.B
                if ($l -gt $best) { $best = $l }
            }
            return $best
        }
        $selMidY = $stripTop + $m.TabTopPad + [int](($barH - $m.TabTopPad) / 2)
        # Two different pads, and they are not interchangeable. `$arcPad` steps
        # INboard past a top corner's arc so a scan reads the tab's flat part.
        # `$outPad` bounds how far OUTboard a scan may look, and it must stop
        # short of the "+"'s own HIT box, which begins `group_gap - btn_pad`
        # past the tab. A flare reaches `corner_bottom` (7 DIP) but only at
        # the very baseline - it is under 5 px out one row up - so the two
        # never actually collide, while a scan that overruns measures the +
        # button instead of the tab. That is not hypothetical: it fired under
        # the T204 negative control, where the "+" mark moves 13 px left into
        # exactly that band, and turned a healthy flare red.
        $arcPad = $m.CornerR + 4
        $outPad = [Math]::Max([Math]::Min($arcPad, $gap - $btnPad - 1), 4)
        # Top EDGE rim, sampled across the flat middle of the tab's top row -
        # away from both corner arcs.
        $topRim = Max-Lum $shot ($sel.Left + $arcPad) ($sel.Right - $arcPad) $tabTop
        $selFillLum = [int]$selFill.R + $selFill.G + $selFill.B
        $stripLum = [int]$stripBg.R + $stripBg.G + $stripBg.B
        Write-Host "INFO  rim: top edge=$topRim vs fill=$selFillLum strip=$stripLum"
        Assert ($topRim -gt ($selFillLum + 30) -and $topRim -gt ($stripLum + 30)) `
            "T206: the tab's top edge carries a rim brighter than both its fill and the strip (rim=$topRim fill=$selFillLum strip=$stripLum)"
        # The SAME rim, on the tab's right side, at half height and again just
        # above the baseline. Same edge, same construction - only `y` differs,
        # which is exactly what the gradient is a function of.
        $sideHi = Max-Lum $shot ($sel.Right - 2) ($sel.Right + $outPad) $selMidY
        $sideLo = Max-Lum $shot ($sel.Right - 2) ($sel.Right + $outPad) ($stripTop + $barH - 3)
        Write-Host "INFO  rim gradient: side@mid=$sideHi side@baseline=$sideLo"
        Assert ($sideHi -ge ($sideLo + 12)) `
            "T206: the rim FADES down the tab - a gradient, not a border (mid=$sideHi baseline=$sideLo)"

        # 8. THE FLARE. The selected tab's foot curves OUT into the baseline,
        #    so its silhouette is wider at the last row than at its middle.
        #    Measured on the RIGHT side, which faces open strip: the left side
        #    faces a neighbour whose own edge would end the scan early.
        function Right-Edge($shot, [int]$from, [int]$to, [int]$y, $bg) {
            $last = $from - 1
            for ($x = $from; $x -le $to; $x++) {
                $p = $shot.Bitmap.GetPixel($offX + $x, $y)
                if ([math]::Abs([int]$p.R - [int]$bg.R) -gt 8) { $last = $x }
            }
            return $last
        }
        $edgeMid = Right-Edge $shot ($sel.Right - 2) ($sel.Right + $outPad) $selMidY $stripBg
        $edgeBot = Right-Edge $shot ($sel.Right - 2) ($sel.Right + $outPad) ($stripTop + $barH - 1) $stripBg
        Write-Host "INFO  flare: right edge mid=$edgeMid baseline=$edgeBot"
        Assert ($edgeBot -ge ($edgeMid + 3)) `
            "T206: the selected tab FLARES at its baseline ($edgeBot vs $edgeMid at mid-height)"

        # 9. ANTIALIASING on the top-left corner arc. Stated in the task as
        #    "at least one pixel that is neither strip nor fill"; asserted as a
        #    DISTINCT-VALUE COUNT instead, which is the same claim without the
        #    flakiness - the narrow band between fill and strip is ~0.17px wide
        #    in signed-distance terms, so whether a pixel lands in it is luck,
        #    while "how many different values does this corner take" is not.
        #    A GDI region gives exactly two (strip and fill); a hard-edged
        #    region WITH a rim would give three. The composite gives a ramp.
        $arc = @{}
        $arcOther = 0
        for ($x = $sel.Left; $x -le ($sel.Left + $arcPad); $x++) {
            for ($y = $tabTop; $y -le ($tabTop + $arcPad); $y++) {
                $p = $shot.Bitmap.GetPixel($offX + $x, $y)
                $arc[[int]$p.R] = $true
                if ([math]::Abs([int]$p.R - [int]$stripBg.R) -gt 3 -and
                    [math]::Abs([int]$p.R - [int]$selFill.R) -gt 3) { $arcOther++ }
            }
        }
        Write-Host "INFO  corner arc: $($arc.Count) distinct values, $arcOther neither-strip-nor-fill"
        Assert ($arc.Count -ge 5) `
            "T206: the top-left corner arc is ANTIALIASED, not a hard edge ($($arc.Count) distinct values)"
        Assert ($arcOther -ge 1) `
            "T206: the arc holds pixels that are neither strip nor fill ($arcOther)"
    }

    # -----------------------------------------------------------------------
    # 4c. T209 / T204: the close "x" is a real icon button - it lights a
    #     ROUNDED fill on hover, and it acts where it PAINTS.
    #
    #     Pre-T204 it was the odd one out: hover recolored the glyph red and
    #     lit nothing ("why doesn't the x to close a tab have a similar
    #     hover?"). The claim splits in two because the harness cannot hold a
    #     hover (T233): TrackMouseEvent watches the REAL cursor, there is none
    #     on this desktop, and WM_MOUSELEAVE is a POSTED message - so it is
    #     drained before the WM_PAINT the move dirtied, and the hovered frame
    #     may never be painted at all.
    #
    #       * THE TRIGGER - from the `tab hover ...` debug oracle: a move onto
    #         the close button's box sets close=true, a move onto the tab's
    #         title area clears it. That is the hit test agreeing with the
    #         paint geometry, which is assertion 4's other half.
    #       * THE FILL - by pixels, best-effort, with the "+" as the harness's
    #         POSITIVE CONTROL. The "+" has lit a fill since long before T204
    #         and both come from the same posted move, so "+ caught, x not" is
    #         a product defect while "neither caught" is the race and skips.
    # -----------------------------------------------------------------------
    Close-TestWindowPixels $shot; $shot = Get-Shot
    $selNow = @(Get-TestTabExtents -Window $top -Shot $shot -Metrics $m)
    if ($selNow.Count -lt 1) {
        Assert $false 'T204 hover: no measurable tab to hover'
    } else {
        $t3 = $selNow[$selNow.Count - 1]
        $cHitL = $t3.Right - $sm - $btnPaint - $btnPad
        $cHitR = $t3.Right - $sm + $btnPad
        $cCx = [int][Math]::Truncate(($cHitL + $cHitR) / 2)
        $cSqL = $cCx - [int][Math]::Truncate($btnPaint / 2)
        $cSqT = $m.StripBtnTop
        $cCy = $cSqT + [int]($btnPaint / 2)
        $pSqL = $t3.Right + $gap
        $pCx = $pSqL + [int]($btnPaint / 2)
        $pCy = $cCy

        # --- the TRIGGER ----------------------------------------------------
        $hoverLogged = $false
        if (Test-Path $errlog) {
            Clear-Content $errlog -ErrorAction SilentlyContinue
            [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $cCx) -Y ($clientY + $m.StripTopClient + $cCy) -Action move)
            Start-Sleep -Milliseconds 300
            $onClose = @(Select-String -Path $errlog -Pattern 'tab hover .*close=true' -ErrorAction SilentlyContinue)
            $hoverLogged = ($onClose.Count -gt 0)
            if ($hoverLogged) {
                Assert ($onClose.Count -gt 0) 'T204 trigger: a move onto the close button sets close=true'
                Clear-Content $errlog -ErrorAction SilentlyContinue
                [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $t3.Left + 6) -Y ($clientY + $m.StripTopClient + $cCy) -Action move)
                Start-Sleep -Milliseconds 300
                $offClose = @(Select-String -Path $errlog -Pattern 'tab hover .*close=false' -ErrorAction SilentlyContinue)
                Assert ($offClose.Count -gt 0) 'T204 trigger: a move onto the tab title clears it again'
                Clear-Content $errlog -ErrorAction SilentlyContinue
                [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $pCx) -Y ($clientY + $m.StripTopClient + $pCy) -Action move)
                Start-Sleep -Milliseconds 300
                $onPlus = @(Select-String -Path $errlog -Pattern 'tab hover .*plus=true' -ErrorAction SilentlyContinue)
                Assert ($onPlus.Count -gt 0) 'T204 trigger: a move onto the + sets plus=true (the same hit-test path)'
            }
        }
        if (-not $hoverLogged) {
            Write-Host 'SKIP T204 hover trigger: no debug oracle in the log (release build?)'
        }

        # --- the FILL, and that it is ROUNDED --------------------------------
        # `fillRegion` insets the painted square by `inset` (xs) and rounds it
        # by `corner_r`. Two probes per button: the fill's top EDGE at its
        # horizontal center (lit, and clear of the centered mark) and the
        # fill's top-left CORNER pixel (cut away by the radius, so it must
        # stay the un-lit background - that is what separates a rounded fill
        # from a square one).
        $ibInset = Get-TestChromeDip -Dip 2.0 -Scale $scale
        function Probe-Fill($sqL, [int]$cx, [int]$y0) {
            $edgeX = $cx
            $edgeY = $y0 + $ibInset + 1
            $cornX = $sqL + $ibInset
            $cornY = $y0 + $ibInset
            $s = Get-TestWindowPixels -Window $top
            if ((Get-TestDistinctColors -Shot $s) -lt 8) { Close-TestWindowPixels $s; return $null }
            $e = $s.Bitmap.GetPixel($offX + $edgeX, $stripTop + $edgeY)
            $c = $s.Bitmap.GetPixel($offX + $cornX, $stripTop + $cornY)
            Close-TestWindowPixels $s
            return [pscustomobject]@{ Edge = [int]$e.R; Corner = [int]$c.R }
        }
        # Rest readings first, with the pointer parked off both buttons.
        [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $t3.Left + 6) -Y ($clientY + $m.StripTopClient + $cCy) -Action move)
        Start-Sleep -Milliseconds 250
        $restClose = Probe-Fill $cSqL $cCx $cSqT
        $restPlus  = Probe-Fill $pSqL $pCx $cSqT

        # Then race the leave: post the move and capture immediately, over and
        # over. A build with the fill only has to win ONCE; a build without it
        # can never win, however many attempts it gets.
        # A BURST of moves per attempt, not one. The leave is a single posted
        # message; the moves are many, so the queue drains as
        # move...leave...move...move and the LAST thing processed before the
        # (lowest-priority) WM_PAINT is a move - which is the only ordering in
        # which a hovered frame gets painted at all. The capture then has one
        # frame to grab it before the next leave lands.
        function Catch-Fill($sqL, [int]$cx, [int]$hotX, $rest) {
            if ($null -eq $rest) { return $null }
            $best = $null
            for ($i = 0; $i -lt 12; $i++) {
                for ($b = 0; $b -lt 25; $b++) {
                    [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $hotX) -Y ($clientY + $m.StripTopClient + $cCy) -Action move)
                }
                $p = Probe-Fill $sqL $cx $cSqT
                if ($null -eq $p) { continue }
                if ($null -eq $best -or $p.Edge -gt $best.Edge) { $best = $p }
                if ($p.Edge -ge ($rest.Edge + 8)) { return $p }
                [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $t3.Left + 6) -Y ($clientY + $m.StripTopClient + $cCy) -Action move)
            }
            return $best
        }
        $hotPlus  = Catch-Fill $pSqL $pCx $pCx $restPlus
        $hotClose = Catch-Fill $cSqL $cCx $cCx $restClose
        $plusLit  = ($null -ne $hotPlus -and $null -ne $restPlus -and $hotPlus.Edge -ge ($restPlus.Edge + 8))
        Write-Host ("INFO  hover fill: + rest=$(if($restPlus){$restPlus.Edge}) hot=$(if($hotPlus){$hotPlus.Edge}); " +
                    "x rest=$(if($restClose){$restClose.Edge}) hot=$(if($hotClose){$hotClose.Edge})")
        if (-not $plusLit) {
            Write-Host 'SKIP T204 hover fill: the + fill (the positive control) was never caught - the harness lost every race, so the x probe would be meaningless'
        } else {
            Assert ($null -ne $hotClose -and $hotClose.Edge -ge ($restClose.Edge + 8)) `
                "T204: hovering the close x lights a FILL, not just a red glyph (rest=$($restClose.Edge) hot=$($hotClose.Edge))"
            Assert ($hotClose.Corner -lt ($hotClose.Edge - 5)) `
                "T204: that fill is ROUNDED - its corner is cut away (corner=$($hotClose.Corner) edge=$($hotClose.Edge))"
            Assert ($hotPlus.Corner -lt ($hotPlus.Edge - 5)) `
                "T204: the +'s fill is rounded the same way (corner=$($hotPlus.Corner) edge=$($hotPlus.Edge))"
        }

        # --- CLICK-THROUGH at the PAINTED center (assertion 4) ---------------
        # The regression the shared square risks is paint and hit test drifting
        # apart. Section 4 already proved it for the "+"; this is the close
        # button, aimed at the center of the square the pixels above were read
        # from, not at a rect the script derived on its own terms.
        # The oracle is the app's OWN tab list, over IPC. The two obvious local
        # ones both lie in one direction or the other: the pane's child window
        # is torn down on a refcount and can outlive the click by seconds
        # (3 -> 3 against a tab that had already left the strip), and counting
        # painted chiclets is blind under T206_NEUTERED, where an unselected
        # tab paints nothing so the count is 1 before AND after. `+list --json`
        # is neither - it reports the tab array, which is what closing a tab
        # changes.
        function Tab-Count {
            $j = & $exe +list --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -eq $j) { return -1 }
            $w = @($j.data.windows | Where-Object { [int64]$_.id -eq [int64]$top })
            if ($w.Count -eq 0) { return -1 }
            return @($w[0].tabs).Count
        }
        $beforeN = Tab-Count
        [void](Send-TestMouse -Window $top -Target $top -X ($clientX + $cCx) -Y ($clientY + $m.StripTopClient + $cCy) -Button left -Action click)
        $afterN = $beforeN
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 250
            $afterN = Tab-Count
            if ($afterN -ge 0 -and $beforeN -gt 0 -and $afterN -lt $beforeN) { break }
        }
        Assert ($beforeN -gt 0 -and $afterN -ge 0 -and $afterN -lt $beforeN) `
            "T204: a click at the close button's PAINTED center closes that tab ($beforeN -> $afterN tabs)"
    }

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
    # The run's own right limit, from the shared datum: one group gap short of
    # where the "+" may paint. Restating it as "clientW - padR - 2*btn - gap"
    # was a private copy of the button band, and it counted TWO buttons - which
    # stopped being true the moment T260 made the "=" conditional.
    $bandLeft = $m.RunRight - $gap
    Assert ($ext[1] -le $bandLeft) "many tabs: the tab run never reaches the button band ($($ext[1]) <= $bandLeft)"
    Assert (-not (Any-Accent-Blue $shot)) 'many tabs: still no accent rule anywhere in the strip'
    Close-TestWindowPixels $shot

    # -----------------------------------------------------------------------
    # 6. The right-anchored button is pinned to the right END OF THE STRIP -
    #    its PAINTED square inset by the same padding the first tab gets on the
    #    left, not flush against the window border ("the hamburger button has
    #    no gap between it and the border"). Its hit box is allowed to reach
    #    into that pad (T232: a forgiving click target is free precisely
    #    because it is invisible), so the miss is asserted at the outermost
    #    pixel column - past the hit box, which no amount of forgiveness may
    #    cross.
    #
    #    WHICH button that is depends on the window (T260). This one draws its
    #    own caption, so the caption's "..." hosts the menu and the strip's "="
    #    is not painted at all: the "+" inherits the slot, and section 5 has
    #    just filled the strip, so it is sitting at its limit. The assertion is
    #    therefore that the right-most square opens a TAB and NO menu - which
    #    is a stronger statement than the old one, because it fails both if the
    #    inset is wrong and if the retired "=" came back.
    # -----------------------------------------------------------------------
    $tabsBeforeEdge = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal').Count
    Strip-Click ($clientW - 1)
    Start-Sleep -Milliseconds 300
    Assert ((Get-TestWindow -ProcessId $app.Pid -Class '#32768') -eq [IntPtr]::Zero) `
        'right inset: the strip does not run flush to the window border (a click at the edge opens nothing)'
    Assert (@(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal').Count -eq $tabsBeforeEdge) `
        'right inset: ...and not a tab either - the hit box stops short of the border'

    Strip-Click ($clientW - $padR - [int]($btnPaint / 2))
    Start-Sleep -Milliseconds 500
    $menu = Wait-TestPopupMenu -ProcessId $app.Pid -TimeoutMs 1200
    Assert ($menu -eq [IntPtr]::Zero) `
        'T260: the strip carries NO menu button on a window whose caption hosts the menu'
    if ($menu -ne [IntPtr]::Zero) {
        # Escape it back closed so teardown is clean. Send-TestControlKey posts
        # without touching focus; Send-TestKeys would SetFocus and dismiss it
        # by accident, which would score this assertion for free.
        [void](Send-TestControlKey -Control $menu -Key Escape)
        Start-Sleep -Milliseconds 400
    }

    # ...and the "+" is still there and still works, wherever the run left it.
    # MEASURED, not assumed at the limit: under pressure the tabs divide the run
    # evenly and the remainder can leave the "+" most of a tab short of its
    # limit, which is exactly the kind of re-derivation T256/T259 are about.
    $tabsNow = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal').Count
    $runRight = Get-TestTabRunRight -Window $top -Metrics $m
    $plusLeft = [Math]::Min($runRight + $gap, $m.PlusLimit)
    Strip-Click ($plusLeft + [int]($btnPaint / 2))
    Start-Sleep -Milliseconds 500
    Assert (@(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal').Count -gt $tabsNow) `
        'the "+" survives the strip being full and still opens a tab'

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
    # Same size as the first window, for the same reason (above).
    Set-TestWindowSize -Window $top -Width 1400 -Height 800 | Out-Null
    Start-Sleep -Milliseconds 1200

    # Re-derive the geometry for THIS window: the pixel helpers above read
    # these script-scope variables at call time, so reassigning them re-points
    # them at the new instance.
    # Same datum as above, re-measured for THIS window (a different window can
    # be on a different monitor at a different DPI), from the one helper (T257).
    $m = Get-TestChromeMetrics -Window $top -StripVisible $true
    $clientX = $m.ClientLeft; $clientY = $m.ClientTop; $clientW = $m.ClientW
    $offX = $m.OffX
    $offY = $m.OffY
    $panes2 = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes2.Count -lt 1) { Write-Host 'SETUP FAIL: long-title pane not found'; exit 1 }
    $scale = $m.Scale
    $sm    = $m.PadSm
    $sq    = $m.BtnPaint
    $capH  = $m.CaptionH
    $barH  = $panes2[0].Top - $clientY - $m.StripTopClient
    $stripTop = $m.StripTop
    $runW = $m.RunW
    $capW = $m.TabCap
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
