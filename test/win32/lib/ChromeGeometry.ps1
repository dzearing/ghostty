# ChromeGeometry.ps1 - the ONE place an acceptance script learns where the
# win32 chrome is.
#
# Why this file exists (T257). Twice now, one chrome change in one place broke
# a pile of acceptance scripts that each re-derived the same numbers privately:
#
#   * T254 moved the tab strip off client `y = 0` (the caption band became
#     CLIENT area). Cost: 7 failures in tab-strip.ps1, 19 in menu-bar.ps1.
#   * T235 changed what SIZES a tab. Cost: 4 more in menu-bar.ps1 alone.
#
# In both cases the app-side change was one number in one module. The scripts
# were expensive because four of them - tab-strip.ps1, menu-bar.ps1,
# tab-strip-autohide.ps1, tab-color.ps1 - each kept their own copy of the
# caption height, the strip height, the strip's origin, and the right-anchored
# button band. Same measurement, four implementations, four chances to be
# wrong, and they were not even consistent with each other (see ROUNDING).
#
# T205 moves this datum a THIRD time when the tab strip goes into the caption
# row. When it does, this file is the edit.
#
# ---------------------------------------------------------------------------
# DERIVED vs MEASURED - the line this file draws, and why
#
# Everything here is DERIVED from the window's own DPI by the same construction
# the Zig layout modules use, EXCEPT `Get-TestTabRunRight`, which is MEASURED
# off a capture. That split is not arbitrary:
#
#   * Positions and gaps come from DIP constants (`caption_layout.Metrics`,
#     `tab_strip_layout.Metrics`, `icon_button.Metrics`). A script can restate
#     those exactly, and SHOULD - a derived value that disagrees with the app
#     is a real failure the script must be able to see.
#   * A tab's WIDTH does not. Since T235 it is the measured title plus padding
#     (capped at 50% of the run), so it comes out of text metrics that a
#     PowerShell script cannot reproduce. T256 already learned this the
#     expensive way: menu-bar.ps1 modelled "equal share capped at 200 DIP",
#     got ~250px against a real ~344px tab, and clicked the "+" inside tab 1.
#     A script cannot re-derive a width that comes from text metrics, so this
#     file does not offer one - it offers the run's measured right edge.
#
# ---------------------------------------------------------------------------
# ROUNDING - the trap that made the private copies disagree
#
# The layout modules round with Zig's `@round`, which is round-half-AWAY-from-
# zero. PowerShell's `[math]::Round($x)` is BANKER'S rounding (half to even).
# They agree at 100%, 125%, 150% and 200% because nothing lands on .5 there -
# which is exactly why the divergence went unnoticed - and disagree at 112.5%
# DPI, where `4 * 1.125 = 4.5` becomes 4 in PowerShell and 5 in the app.
#
# menu-bar.ps1 got this right (it passed MidpointRounding::AwayFromZero);
# tab-strip.ps1 and tab-color.ps1 did not. `Get-TestChromeDip` below is the
# one rounding, and it matches the app.
#
# ---------------------------------------------------------------------------
# Source of truth for every constant below, verified against the Zig:
#
#   icon_button.Metrics.init      target   = px(28)   hit_pad = px(2)
#   caption_layout.Metrics.init   caption_h = px(4) + target + px(4)
#   tab_strip_layout.Metrics.init bar_h     = px(4) + px(4) + target + px(4)
#                                 strip_pad_l = strip_pad_r = tab_gap = px(4)
#                                 group_gap = px(8)   min_tab_w = px(60)
#                                 stripe_h  = max(px(3), 2)
#                                 hairline  = max(px(1), 1)
#   tab_strip_layout.runWidth     client_w - pad_r - btn - gap - btn - gap - pad_l
#   tab_strip_layout.tabCap       max(runWidth / 2, min_tab_w)

# The layout modules' `px()`: `@intFromFloat(@round(dip * scale))`. Zig's
# `@round` is half-away-from-zero, NOT PowerShell's default banker's rounding.
# Every DIP constant in this file goes through here.
function Get-TestChromeDip {
    param(
        [Parameter(Mandatory = $true)][double]$Dip,
        [Parameter(Mandatory = $true)][double]$Scale
    )
    return [int][Math]::Round($Dip * $Scale, [MidpointRounding]::AwayFromZero)
}

<#
Where the win32 chrome is, for one window, at its own DPI.

All DIP constants are resolved the way the layout modules resolve them, so a
script that uses these cannot drift from the app by rounding or by restating a
constant slightly wrong.

Coordinate spaces are named, because mixing them is how a click ends up in the
caption (where it drags the window or hits close):

  * `*Client`  - client-relative, what Get-TestWindowRect -Client is in.
  * `StripTop` - WINDOW-relative y of the strip's first row, which is what a
                 Get-TestWindowPixels bitmap is indexed by. `OffX`/`OffY` are
                 the client origin inside that bitmap, so a client x maps to
                 `OffX + x`.

Returns a pscustomobject; unknown members are a typo, not a silent $null, so
prefer reading them straight rather than splatting.
#>
function Get-TestChromeMetrics {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Desktop
    )

    $dpi = [int](Get-TestWindowDpi -Window $Window -Desktop $Desktop)
    $scale = $dpi / 96.0
    $px = { param([double]$dip) Get-TestChromeDip -Dip $dip -Scale $scale }

    $padSm = & $px 4.0            # the 4 DIP spacing step
    $padMd = & $px 8.0            # one step up: separates GROUPS of controls
    $gap = & $px 8.0              # tab_strip_layout group_gap
    $btnPaint = & $px 28.0        # icon_button.Metrics.target - the PAINTED square
    $btnPad = & $px 2.0           # icon_button.Metrics.hit_pad

    # caption_h and bar_h are built from the same two parts the modules build
    # them from, not from a literal 36/40, so `window-decoration = none` (no
    # caption) and any future change show up as a disagreement rather than a
    # coincidence.
    $captionH = 2 * $padSm + $btnPaint
    $barH = 3 * $padSm + $btnPaint

    $cr = Get-TestWindowRect -Window $Window -Client
    $wr = Get-TestWindowRect -Window $Window
    $clientW = $cr.Width

    # Right-anchored button band. This is ANCHORING, not sizing - it is the
    # part of the strip a script may legitimately derive (see the header).
    $menuLeft = $clientW - $padSm - $btnPaint
    $plusLimit = $menuLeft - $gap - $btnPaint
    $runW = $plusLimit - $gap - $padSm

    return [pscustomobject]@{
        Dpi = $dpi
        Scale = $scale

        # --- spacing / button model -----------------------------------------
        PadSm = $padSm
        PadMd = $padMd
        Gap = $gap
        BtnPaint = $btnPaint
        BtnPad = $btnPad
        # The HIT box, which is deliberately larger than the paint and must
        # never be used to measure a gap (design system: gaps are measured
        # between PAINTED edges).
        BtnW = $btnPaint + 2 * $btnPad

        # --- band heights ----------------------------------------------------
        CaptionH = $captionH
        BarH = $barH

        # --- tab strip constants ---------------------------------------------
        PadL = $padSm                       # strip_pad_l
        PadR = $padSm                       # strip_pad_r
        TabGap = $padSm                     # tab_gap
        TabTopPad = $padSm                  # tab_top_pad
        MinTabW = & $px 60.0                # the one width constant T235 kept
        CornerR = & $px 6.0
        TextPad = & $px 8.0
        StripeH = [Math]::Max((& $px 3.0), 2)
        Hairline = [Math]::Max((& $px 1.0), 1)

        # --- geometry ---------------------------------------------------------
        ClientLeft = $cr.Left
        ClientTop = $cr.Top
        ClientW = $clientW
        ClientH = $cr.Height
        # Client origin inside the WINDOW rect - the offset from a client x/y to
        # a Get-TestWindowPixels bitmap index.
        OffX = $cr.Left - $wr.Left
        OffY = $cr.Top - $wr.Top
        # The strip's first row, in both spaces that matter.
        StripTopClient = $captionH
        StripTop = ($cr.Top - $wr.Top) + $captionH

        # --- right-anchored band, client x -----------------------------------
        MenuLeft = $menuLeft
        MenuX = $menuLeft + [int]($btnPaint / 2)
        PlusLimit = $plusLimit
        # tab_strip_layout.runWidth: what the 50% proportional cap is half OF,
        # so the script and the layout module mean the same run.
        RunW = $runW
        TabCap = [Math]::Max([int][Math]::Floor($runW / 2), (& $px 60.0))
    }
}

<#
Every painted tab chiclet's extent, in CLIENT x, as an array of
`{ Left, Right, Center }` (Right exclusive) - MEASURED, never modelled (see
this file's header for why a width cannot be derived).

Scans a row near the strip's BOTTOM: inside a chiclet at its full width (the
chiclet's rounding is on the TOP corners only) and below the "+" glyph's
extent, so nothing between the last tab and the menu button can be mistaken
for one. Chiclets are the runs that are NOT strip background; the `tab_gap`
between two tabs is background, which is what separates them. The SELECTED
chiclet is a different shade from an unselected one and both differ from the
strip, so this finds every tab regardless of which is selected.

Deliberately generic about count and width: this is what lets a script click
tab N without knowing what the shell called it (T235 made a tab's width its
measured title, and T259 is what happens to a script that models it instead).

Returns an empty array when the strip has no tabs or the window never paints.
Always index it as `@(...)` - a single-element result unrolls in PowerShell.

Pass -Shot to reuse a capture you already have; otherwise one is taken (and
disposed) here, retrying until the window paints real content - PrintWindow on
a freshly shown window returns a flat fill for a few frames.
#>
function Get-TestTabExtents {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Shot,
        $Metrics,
        $Desktop
    )

    $m = $Metrics
    if (-not $m) { $m = Get-TestChromeMetrics -Window $Window -Desktop $Desktop }

    $rowY = $m.StripTop + $m.BarH - 2
    $out = @()

    $shot = $Shot
    $owned = $false
    if (-not $shot) {
        for ($t = 0; $t -lt 20; $t++) {
            $s = Get-TestWindowPixels -Window $Window -Desktop $Desktop
            if ((Get-TestDistinctColors -Shot $s) -ge 8) { $shot = $s; $owned = $true; break }
            Close-TestWindowPixels $s
            Start-Sleep -Milliseconds 150
        }
    }
    if (-not $shot) { return $out }

    try {
        # The strip background, sampled in the gap left of the menu button -
        # strip that can belong to no tab.
        $bg = $shot.Bitmap.GetPixel($m.OffX + $m.MenuLeft - 2, $rowY)
        $runStart = -1
        # Runs to MenuLeft inclusive-exclusive so a run touching the right end
        # is still closed off.
        for ($x = $m.PadL; $x -le $m.MenuLeft; $x++) {
            $isTab = $false
            if ($x -lt $m.MenuLeft) {
                $p = $shot.Bitmap.GetPixel($m.OffX + $x, $rowY)
                $isTab = ([Math]::Abs($p.R - $bg.R) -gt 8 -or [Math]::Abs($p.G - $bg.G) -gt 8 -or
                          [Math]::Abs($p.B - $bg.B) -gt 8)
            }
            if ($isTab) {
                if ($runStart -lt 0) { $runStart = $x }
            } elseif ($runStart -ge 0) {
                # Antialiasing on a chiclet's rounded edge can leave a 1-2px
                # sliver; a real tab is at least min_tab_w wide.
                if (($x - $runStart) -ge [int]($m.MinTabW / 2)) {
                    $out += [pscustomobject]@{
                        Left = $runStart
                        Right = $x
                        Center = $runStart + [int](($x - $runStart) / 2)
                    }
                }
                $runStart = -1
            }
        }
    } finally {
        if ($owned) { Close-TestWindowPixels $shot }
    }

    return $out
}

<#
The last tab's painted right edge, in CLIENT x, exclusive.

Falls back to `PadL` (an empty run) when there are no tabs or the window never
captures with real content, which is what a strip with no tabs measures - the
"+" then sits at the run's start.
#>
function Get-TestTabRunRight {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Shot,
        $Metrics,
        $Desktop
    )

    $m = $Metrics
    if (-not $m) { $m = Get-TestChromeMetrics -Window $Window -Desktop $Desktop }

    $tabs = @(Get-TestTabExtents -Window $Window -Shot $Shot -Metrics $m -Desktop $Desktop)
    if ($tabs.Count -eq 0) { return $m.PadL }
    return $tabs[$tabs.Count - 1].Right
}
