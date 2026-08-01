# T72 acceptance: tab accent-color tagging (Mac TerminalTabColor parity).
#
# The tab context menu gained a "Tab Color" submenu (None + 9 colors, swatch
# bitmaps, checkmark on current). A tagged tab paints a ~3px accent stripe
# across the top of its tab in the owner-drawn tab bar; the color rides the
# tab through reorders and survives focus changes; "None" clears it.
#
# One hermetic GUI launch (--config-default-files=false, black background):
#   1. The strip is up from the first window (T190), so its height is measured
#      directly -> DPI scale -> tab widths for pixel sampling; ctrl+t then
#      makes a second tab (positive control).
#   2. Right-click tab 0 -> context menu window (#32768) exists (control).
#   3. Keyboard-drive the menu by first-letter matching: 'T' (unique ->
#      "Tab Color" submenu opens), 'R' (unique -> Red selected).
#   4. Tab 0's top stripe polls to red (255,69,58); tab 1's stays unstriped.
#   5. Left-click tab 1 (activate) -> tab 0 keeps its stripe while inactive.
#   6. Right-click tab 0 -> 'T', 'N' (None) -> stripe cleared.
#
# T218: migrated onto the BACKGROUND test desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted here, not assumed. What the
# desktop forced to change:
#
#   * The stripe is read out of PrintWindow(PW_RENDERFULLCONTENT) instead of a
#     screen-DC GetPixel strip. The tab bar is GDI-painted CHROME, the half of
#     the CAPTURE LIMIT that survives on a background desktop, so the probe
#     migrates unchanged in coordinates - and every capture is guarded by
#     Get-TestDistinctColors, because a mid-paint flat fill has no red in it
#     and would quietly satisfy both "no stripe" assertions.
#   * Clicks are POSTED, so they name the window that would really have
#     received them: the tab strip is painted and handled by the TOP-LEVEL
#     window (Window.zig), not by a pane child.
#   * Menu keys go through Send-TestControlKey (posts without touching focus).
#     The color submenu is its own '#32768' window, so the second letter is
#     aimed at whichever menu window is frontmost.
#   * The cursor parking is gone: it existed so tab hover chrome could not
#     pollute the sample, and a background desktop has no pointer over the
#     window at all.
#
# -NegativeControl inverts assertion 4 (asserts tab 0 stays UNSTRIPED after
# Red is picked) and MUST fail; it is how a run proves the stripe probe reads
# the real accent color rather than passing on anything.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-tabcolortest'

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

# True if any pixel in the stripe band (clientTop+topPad .. +stripeH-1) at
# screen x matches the target color. Takes its own capture, and refuses to
# score one that has not painted yet - "no red here" is the assertion this
# script makes most often, and a flat fill satisfies it for free.
function Stripe-HasColor([IntPtr]$top, [int]$x, [int]$stripeTop, [int]$stripeH, [int]$tr, [int]$tg, [int]$tb, [int]$tol = 40) {
    for ($t = 0; $t -lt 20; $t++) {
        $shot = Get-TestWindowPixels -Window $top
        try {
            if ((Get-TestDistinctColors -Shot $shot) -lt 8) { Start-Sleep -Milliseconds 150; continue }
            for ($y = $stripeTop; $y -lt ($stripeTop + $stripeH); $y++) {
                $c = Get-TestPixel -Shot $shot -X $x -Y $y
                if ($null -eq $c) { continue }
                if ([math]::Abs($c.R - $tr) -le $tol -and
                    [math]::Abs($c.G - $tg) -le $tol -and
                    [math]::Abs($c.B - $tb) -le $tol) { return $true }
            }
            return $false
        } finally { Close-TestWindowPixels $shot }
    }
    return $false
}

function Dump-Stripe([IntPtr]$top, [int]$x, [int]$stripeTop, [int]$stripeH, [string]$label) {
    $shot = Get-TestWindowPixels -Window $top
    try {
        $px = @()
        for ($y = $stripeTop; $y -lt ($stripeTop + $stripeH); $y++) {
            $c = Get-TestPixel -Shot $shot -X $x -Y $y
            $px += if ($null -eq $c) { 'off' } else { "$($c.R),$($c.G),$($c.B)" }
        }
        Write-Host "DEBUG $label stripe at x=${x}: $($px -join ' | ')"
    } finally { Close-TestWindowPixels $shot }
}

function Get-Menu([int]$gpid) {
    return (Get-TestWindow -ProcessId $gpid -Class '#32768')
}

# Open the tab context menu by right-clicking a tab. The click is posted to the
# TOP-LEVEL window, which is what paints and hit-tests the strip.
function Open-TabMenu([int]$gpid, [IntPtr]$top, [int]$x, [int]$y) {
    for ($a = 0; $a -lt 3; $a++) {
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Button right -Action click)
        $menu = Wait-TestPopupMenu -ProcessId $gpid -TimeoutMs 3000
        if ($menu -ne [IntPtr]::Zero) { return $menu }
    }
    return [IntPtr]::Zero
}

# Drive the already-open tab context menu to a Tab Color selection via
# menu first-letter matching: 'T' uniquely matches "Tab Color" (opens the
# submenu), then the color's unique first letter selects it. (Arrow-key
# nav proved unreliable against the menu modal loop on this box; first-letter
# matching is what worked - diag 2026-07-18.)
function Select-TabColor([int]$gpid, [IntPtr]$menu, [string]$colorKey) {
    [void](Send-TestControlKey -Control $menu -Key T)
    Start-Sleep -Milliseconds 350
    # The submenu is a SECOND '#32768' window; aim the color letter at whatever
    # menu window is frontmost now, falling back to the one we opened.
    $sub = Get-Menu $gpid
    if ($sub -eq [IntPtr]::Zero) { $sub = $menu }
    [void](Send-TestControlKey -Control $sub -Key $colorKey)
    Start-Sleep -Milliseconds 500
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserts tab 0 has NO stripe after Red is picked - this run MUST fail'
}

try {
    # -----------------------------------------------------------------------
    # Launch (hermetic; black bg so the bar/stripe colors can't come from
    # content). --session-persistence=false: each launch would otherwise write
    # a layout manifest that the next one restores (T131).
    #
    # --window-show-tab-bar=always is REQUIRED since T234 (T259): `auto` now
    # hides the strip at one tab, so the single-tab positive control below
    # would otherwise be measuring the caption band. This script is about tab
    # COLORS, not about the autohide rule - tab-strip-autohide.ps1 owns that.
    # -----------------------------------------------------------------------
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false', '--background=#000000', '--session-persistence=false',
        '--window-show-tab-bar=always'
    )
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'the window is NOT enumerable on the interactive desktop'

    $panes1 = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes1.Count -ne 1) { Write-Host "SETUP FAIL: expected 1 visible pane, got $($panes1.Count)"; exit 1 }

    # The strip is up from the FIRST window since T190 (on Windows `auto` shows
    # it because the strip is also the app's menu host), so the bar height is
    # measured here rather than inferred from a jump when a second tab appears.
    # The pre-migration script derived it from that jump and would fail against
    # today's product for a reason that has nothing to do with tab colors.
    #
    # T259 half 1 - the ORIGIN moved. Since T254 the caption band is CLIENT
    # area, so `paneTop - clientTop` is `caption_h + bar_h`, not `bar_h`. This
    # line reported 45 at this box's 1.25 scale (exactly caption_h) while the
    # strip is 50, and the loose 20..80 band let that pass. The caption height
    # is subtracted now, and the check is exact against the derived bar_h.
    $m = Get-TestChromeMetrics -Window $top
    $clientTop = $m.ClientTop
    $stripTopScreen = $clientTop + $m.CaptionH
    $barH = $panes1[0].Top - $stripTopScreen
    Assert ($barH -eq $m.BarH) `
        "positive control: the tab bar is visible with a single tab (capH=$($m.CaptionH) barH=$barH, expected $($m.BarH))"
    if ($barH -le 0) { exit 1 }

    # --- Positive control: ctrl+t creates tab 2 ----------------------------
    if (-not (Focus-TestWindow -Window $top -Child ([IntPtr]$panes1[0].Hwnd))) {
        Write-Host 'SETUP FAIL: could not focus the GUI'; exit 1
    }
    [void](Send-TestKeys -Window $top -Target ([IntPtr]$panes1[0].Hwnd) -Modifiers ctrl -Key T)
    $twoTabs = $false
    for ($t = 0; $t -lt 25; $t++) {
        Start-Sleep -Milliseconds 200
        $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
        $vis = @($panes | Where-Object Visible)
        if ($panes.Count -eq 2 -and $vis.Count -eq 1) { $twoTabs = $true; break }
    }
    Assert $twoTabs 'positive control: ctrl+t made a 2nd tab'
    if (-not $twoTabs) { exit 1 }

    # Geometry.
    #
    # T259 half 2 - a tab's WIDTH is not derivable. This block used to take the
    # scale from `barH / 40` (1.125 instead of 1.25, because barH was really
    # caption_h) and then rebuild the tab width from T202's RETIRED rule: an
    # equal share of the run clamped to [60, 200] DIP. T235 retired that - a tab
    # is its measured title plus padding now - so `tab0x`/`tab1x` pointed at the
    # wrong columns and every right-click landed on empty strip.
    #
    # So the tabs are MEASURED off a capture (the lesson T256 taught
    # menu-bar.ps1), and everything else comes from the one shared helper. The
    # scale never comes from a chrome height again.
    # The T72 stripe rides the chiclet, which starts tab_top_pad down from the
    # strip top. See docs/design/win32-tab-strip.md and win32-design-system.md.
    $scale = $m.Scale
    $stripeH = $m.StripeH
    $stripeTop = [int]($stripTopScreen + $m.TabTopPad)
    $barMidY = [int]($stripTopScreen + [math]::Floor($barH / 2))

    $tabs = @(Get-TestTabExtents -Window $top -Metrics $m)
    Assert ($tabs.Count -eq 2) "positive control: both tab chiclets are measurable off the strip (found $($tabs.Count))"
    if ($tabs.Count -lt 2) { exit 1 }
    # Extents are CLIENT x; the probes below are in SCREEN x.
    $tab0x = [int]($m.ClientLeft + $tabs[0].Center)
    $tab1x = [int]($m.ClientLeft + $tabs[1].Center)
    Write-Host "INFO  scale=$scale stripeH=$stripeH stripeTop=$stripeTop tab0=[$($tabs[0].Left),$($tabs[0].Right)) tab1=[$($tabs[1].Left),$($tabs[1].Right)) tab0x=$tab0x tab1x=$tab1x"

    # Baseline: no stripe anywhere before tagging.
    Assert (-not (Stripe-HasColor $top $tab0x $stripeTop $stripeH 255 69 58)) 'baseline: tab 0 has no red stripe'

    # -----------------------------------------------------------------------
    # Tag tab 0 red via the context menu
    # -----------------------------------------------------------------------
    $menu = Open-TabMenu $app.Pid $top $tab0x $barMidY
    Assert ($menu -ne [IntPtr]::Zero) 'context menu: menu window (#32768) opened on tab right-click'
    if ($menu -eq [IntPtr]::Zero) { exit 1 }
    Select-TabColor $app.Pid $menu 'R'   # 'R' -> Red
    Assert ((Get-Menu $app.Pid) -eq [IntPtr]::Zero) 'context menu: closed after selection'

    $red = $false
    for ($t = 0; $t -lt 15; $t++) {
        if (Stripe-HasColor $top $tab0x $stripeTop $stripeH 255 69 58) { $red = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if ($NegativeControl) {
        Assert (-not $red) 'NEGATIVE CONTROL: tab 0 shows NO red accent stripe after picking Red'
    } else {
        Assert $red 'red: tab 0 shows the red accent stripe'
    }
    if (-not $red) { Dump-Stripe $top $tab0x $stripeTop $stripeH 'red' }
    Assert (-not (Stripe-HasColor $top $tab1x $stripeTop $stripeH 255 69 58)) 'red: tab 1 (untagged) has no stripe'

    # -----------------------------------------------------------------------
    # Persistence: activate tab 1; tab 0 keeps its stripe while inactive
    # -----------------------------------------------------------------------
    [void](Send-TestMouse -Window $top -Target $top -X $tab1x -Y $barMidY -Button left -Action click)
    Start-Sleep -Milliseconds 500
    Assert (Stripe-HasColor $top $tab0x $stripeTop $stripeH 255 69 58) 'persist: inactive tab 0 keeps its red stripe'
    Assert (-not (Stripe-HasColor $top $tab1x $stripeTop $stripeH 255 69 58)) 'persist: active tab 1 still unstriped'

    # -----------------------------------------------------------------------
    # Clear: set tab 0 back to None
    # -----------------------------------------------------------------------
    $menu = Open-TabMenu $app.Pid $top $tab0x $barMidY
    Assert ($menu -ne [IntPtr]::Zero) 'clear: context menu opened again'
    if ($menu -ne [IntPtr]::Zero) { Select-TabColor $app.Pid $menu 'N' }   # 'N' -> None
    $cleared = $false
    for ($t = 0; $t -lt 15; $t++) {
        if (-not (Stripe-HasColor $top $tab0x $stripeTop $stripeH 255 69 58)) { $cleared = $true; break }
        Start-Sleep -Milliseconds 200
    }
    Assert $cleared 'clear: None removes the stripe'
    if (-not $cleared) { Dump-Stripe $top $tab0x $stripeTop $stripeH 'clear' }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
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
