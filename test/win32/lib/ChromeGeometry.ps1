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
# T205 moved this datum a THIRD time - the tab strip went INTO the caption row -
# and this file was the edit, exactly as predicted. Total cost to the scripts:
# one new argument each (`-StripVisible`), because the datum was in one place.
#
# ---------------------------------------------------------------------------
# MERGED vs STANDALONE (T205) - and why -StripVisible is REQUIRED, not guessed
#
# A window that owns its caption now has TWO possible chrome shapes:
#
#   * MERGED (2+ tabs, or --window-show-tab-bar=always): one row. The band is
#     the STRIP's height (40 DIP), the strip starts at client y = 0, there is
#     no window title, and the tab run stops at a seam one `pad_md` left of the
#     caption's "...". Total chrome above the terminal: 40 DIP.
#   * STANDALONE (one tab, the T234 default): no strip at all. The band is the
#     native 32 DIP Win11 caption height (T496) with the window title in it.
#     Total chrome: 32 DIP.
#
# Those two disagree about the y of EVERY strip pixel and about where the "+"
# may sit, so the helper cannot pick one. It also cannot detect which it is
# looking at: the deciding input is the window's tab COUNT, which lives in the
# app and is not on the HWND. So the caller - which knows what it launched -
# must say, and a caller that does not say gets a throw rather than a plausible
# wrong offset. T259 is the reason that is not negotiable: a script that
# silently modelled the wrong chrome measured last year's geometry and passed.
#
# ---------------------------------------------------------------------------
# PUBLISHED vs DERIVED vs MEASURED - the line this file draws, and why
#
# Three ways to learn where a thing is, in descending order of preference:
#
#   * PUBLISHED (`Get-TestStripRegions`, T231). The app REPORTS the tab strip's
#     hit regions in `+list --json`, in client coordinates, and they are the
#     very rects its hit tests read. **Ask for a click target this way.** It
#     cannot rot, because there is no second copy of the layout to rot against.
#   * DERIVED - a DIP constant resolved the way the Zig modules resolve it
#     (`caption_layout.Metrics`, `tab_strip_layout.Metrics`,
#     `icon_button.Metrics`). A script can restate those exactly, and where it
#     does, a disagreement with the app is a real failure the script must be
#     able to see. Keep this for CONSTANTS (a 4 DIP step, the 28 DIP square),
#     never for a position that depends on the tab run.
#   * MEASURED off a capture (`Get-TestTabExtents`). This is the only one that
#     can prove something is PAINTED, so it stays - but it answers "where is
#     there ink", not "where will a click land", and using it for the latter is
#     what T256/T259 cost.
#
# What forced the split: a tab's WIDTH is not derivable. Since T235 it is the
# measured title plus padding (capped at 50% of the run), so it comes out of
# text metrics a PowerShell script cannot reproduce. T256 learned that the
# expensive way - menu-bar.ps1 modelled "equal share capped at 200 DIP", got
# ~250px against a real ~344px tab, and clicked the "+" inside tab 1. The
# answer then was to MEASURE the run; T231 made the product publish it, which
# is better still: exact, available before the window has a stable capture, and
# unambiguous about what is absent (a tab that did not fit reports `null`, and
# a pixel scan cannot tell that from a tab that painted nothing).
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
#   caption_layout.Metrics.init   caption_h = px(32) standalone (native, T496)
#                                 cap_btn_w = px(46) - one native system slab
#   tab_strip_layout.Metrics.init bar_h     = px(4) + px(4) + target + px(4)
#                                 strip_pad_l = strip_pad_r = tab_gap = px(4)
#                                 group_gap = px(8)   min_tab_w = px(60)
#                                 stripe_h  = max(px(3), 2)
#                                 hairline  = max(px(1), 1)
#   tab_strip_layout.runWidth     client_w - pad_r - btn - gap - btn - gap - pad_l
#                                 ...MINUS the "= " square and one gap only when
#                                 the strip HAS a menu button (T260: it does not
#                                 when the caption's "..." hosts the menu)
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
        $Desktop,
        # T205. $true when this window is showing a tab strip (2+ tabs, or
        # --window-show-tab-bar=always), $false when it is not. REQUIRED on a
        # window that owns its caption - see the MERGED vs STANDALONE note in
        # this file's header for why it cannot be inferred. Ignored on a
        # caption-less window, where the strip is always its own row.
        [object]$StripVisible
    )

    $dpi = [int](Get-TestWindowDpi -Window $Window -Desktop $Desktop)
    $scale = $dpi / 96.0
    $px = { param([double]$dip) Get-TestChromeDip -Dip $dip -Scale $scale }

    $padSm = & $px 4.0            # the 4 DIP spacing step
    $padMd = & $px 8.0            # one step up: separates GROUPS of controls
    $gap = & $px 8.0              # tab_strip_layout group_gap
    $btnPaint = & $px 28.0        # icon_button.Metrics.target - the PAINTED square
    $btnPad = & $px 2.0           # icon_button.Metrics.hit_pad
    $capBtnW = & $px 46.0         # caption_layout.Metrics.cap_btn_w - one native slab (T496)

    # Does this window draw its own caption band (T254)? `Window.customCaption`
    # is `!quick_terminal && decoration != none && (style & WS_CAPTION)`, and
    # both of the first two imply the third - a quick terminal is WS_POPUP and
    # `setDecorations` strips WS_CAPTION - so the style bit answers the whole
    # question, from the OS rather than from what the script thinks it launched.
    $WS_CAPTION = 0x00C00000
    $hasCaption = ((Get-TestWindowStyle -Window $Window -Desktop $Desktop) -band $WS_CAPTION) -ne 0

    # T260: the strip paints its own "menu" button only when there is no
    # caption to host the menu. Same rule as `Window.stripHasMenu`, and the
    # reason the right-anchored band below is conditional.
    $hasStripMenu = -not $hasCaption

    # T205: is the tab run IN the caption band? Only a caption window can
    # merge, and only while it has a strip to merge.
    if ($hasCaption -and $null -eq $StripVisible) {
        throw ("Get-TestChromeMetrics: -StripVisible is required on a window that owns its " +
               "caption. Since T205 the tab run shares the caption ROW, so the strip's origin " +
               "AND the '+'s right limit both depend on whether there is a run: with a strip " +
               "the band is 40 DIP and the strip starts at client y=0; without one there is no " +
               "strip and the band is the native 32 DIP caption with the window title in it. Pass " +
               "-StripVisible `$true for a window showing 2+ tabs (or --window-show-tab-bar=" +
               "always), `$false otherwise. It is not inferred because the deciding input is " +
               "the tab COUNT, which lives in the app and is not on the HWND.")
    }
    # A caption-less window always shows its strip (`auto` is `tab_count > 1 or
    # !customCaption`), and has no band to merge it into either way.
    $stripShown = if ($hasCaption) { [bool]$StripVisible } else { $true }
    $merged = $hasCaption -and $stripShown

    # bar_h is built from the same parts the modules build it from. The
    # standalone caption is the native 32 DIP Win11 caption height (T496) -
    # sized by the platform, not by the app's button square. Merged, the band
    # IS the strip's height - one row, one number, exactly as
    # `caption_layout.Metrics.init(.with_tabs)` does it.
    $barH = 3 * $padSm + $btnPaint
    $captionH = if (-not $hasCaption) { 0 } elseif ($merged) { $barH } else { & $px 32.0 }
    $stripTopClient = if ($merged) { 0 } else { $captionH }
    # Everything above the terminal. NOT `CaptionH + BarH` at any call site:
    # that stopped being the answer the moment the two became one row.
    $chromeH = if ($merged) { $barH } elseif ($stripShown) { $captionH + $barH } else { $captionH }

    # Top of an icon button's PAINTED square inside the STRIP, strip-local.
    # `icon_button.targetBox` centered in the strip's own button band, which is
    # `tab_top_pad`..`bar_h` (NOT 0..bar_h - see tab_strip_layout.buttonHit):
    # the "+", the "=" and a tab's close "x" all land on this row, which is
    # what T204 means by "one frame".
    $stripBtnTop = [int][Math]::Truncate(($padSm + $barH) / 2) - [int][Math]::Truncate($btnPaint / 2)
    # Top of the caption's "..." PAINTED square, band-local. Since T496 this
    # is the APP's button only - the system trio is full-height native slabs
    # with no baseline of their own. Merged, the "..." sits on the strip's own
    # button baseline (one frame with the "+"); standalone it centers in the
    # native band, exactly as `caption_layout.Metrics.init` derives it.
    $capBtnTop = if ($merged) { $stripBtnTop } else { [int][Math]::Truncate(($captionH - $btnPaint) / 2) }

    $cr = Get-TestWindowRect -Window $Window -Client
    $wr = Get-TestWindowRect -Window $Window
    $clientW = $cr.Width

    # Right-anchored button band. This is ANCHORING, not sizing - it is the
    # part of the strip a script may legitimately derive (see the header).
    #
    # Without a strip menu the "+" IS the right-anchored control and takes the
    # slot the menu had, which is exactly what `tab_strip_layout.plusPaintLimit`
    # does. `MenuLeft` is then $null: there is no such button, and a script that
    # clicks one on this window is aiming at nothing (better a $null-arithmetic
    # blow-up than a click that silently lands on empty strip).
    # The caption's own "..." menu button (T234), in client x - the menu host
    # on a caption window, and what `menu-bar.ps1` clicks there. The system
    # trio is three native 46 DIP slabs flush to the window's right edge with
    # zero gaps (T496); the "..." sits one GROUP step (pad_md) left of the
    # minimize slab, exactly as `caption_layout.layout` places it. T205
    # changed no x in this cluster: merging was a VERTICAL change.
    $capCloseL = $clientW - $capBtnW
    $capMinL = $capCloseL - 2 * $capBtnW
    $capOverL = if ($hasCaption) { $capMinL - $padMd - $btnPaint } else { $null }
    # The seam (`caption_layout.Layout.band_left`): the strip paints left of
    # it, the caption right of it, and the "+"'s painted limit lands ON it.
    $bandLeft = if ($merged) { $capOverL - $padMd } else { $null }

    if ($hasStripMenu) {
        $menuLeft = $clientW - $padSm - $btnPaint
        $plusLimit = $menuLeft - $gap - $btnPaint
    } elseif ($merged) {
        # The strip's right end is the seam, not the window edge.
        $menuLeft = $null
        $plusLimit = $bandLeft - $btnPaint
    } else {
        $menuLeft = $null
        $plusLimit = $clientW - $padSm - $btnPaint
    }
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
        # One native caption slab's width (T496). The slab's height is the
        # whole band; its hit box IS its painted rect.
        CapBtnW = $capBtnW

        # --- band heights ----------------------------------------------------
        # 0 when the OS still owns the caption, so a strip-relative y offset by
        # this lands in the strip on BOTH kinds of window.
        CaptionH = $captionH
        BarH = $barH
        HasCaption = $hasCaption
        # T260: is there a "menu" button in the strip at all?
        HasStripMenu = $hasStripMenu
        # T205: is the tab run in the caption band? When it is, `CaptionH` and
        # `BarH` are the SAME row and adding them is a bug.
        Merged = $merged
        StripVisible = $stripShown
        # Everything above the terminal - what a pane's top offset should be.
        ChromeH = $chromeH
        # Band-local top of a caption button's painted square.
        CaptionBtnTop = $capBtnTop
        # Strip-local top of ANY strip icon button's painted square: the "+",
        # the "=", and a tab's close "x". T209 probes glyphs against it.
        StripBtnTop = $stripBtnTop

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
        # The strip's first row, in both spaces that matter. NOT `CaptionH`
        # since T205 - merged, the strip IS the band and starts at 0.
        StripTopClient = $stripTopClient
        StripTop = ($cr.Top - $wr.Top) + $stripTopClient

        # --- right-anchored band, client x -----------------------------------
        # $null on a caption window - the button does not exist there (T260).
        MenuLeft = $menuLeft
        MenuX = if ($null -ne $menuLeft) { $menuLeft + [int]($btnPaint / 2) } else { $null }
        PlusLimit = $plusLimit
        # The right edge of everything the tab run may occupy: the "+"'s own
        # painted limit. The one boundary that means the same thing with and
        # without a menu button, which is why the tab scan below uses it.
        RunRight = $plusLimit
        # The caption's "..." (T234): the menu host on a caption window.
        CaptionOverflowLeft = $capOverL
        CaptionOverflowX = if ($null -ne $capOverL) { $capOverL + [int]($btnPaint / 2) } else { $null }
        # The system trio's slab left edges, client x (T496). $null without a
        # caption, like CaptionOverflowLeft.
        CaptionMinLeft = if ($hasCaption) { $capMinL } else { $null }
        CaptionMaxLeft = if ($hasCaption) { $capMinL + $capBtnW } else { $null }
        CaptionCloseLeft = if ($hasCaption) { $capCloseL } else { $null }
        # T205's seam; $null on a window whose chrome is two rows.
        BandLeft = $bandLeft
        # tab_strip_layout.runWidth: what the 50% proportional cap is half OF,
        # so the script and the layout module mean the same run.
        RunW = $runW
        TabCap = [Math]::Max([int][Math]::Floor($runW / 2), (& $px 60.0))
    }
}

<#
The tab strip's hit regions as the APP publishes them (T231), in CLIENT
coordinates - `+list --json` -> `windows[].chrome.tab_strip`.

This is the answer to "where do I click", and it is the app's own rects rather
than a second implementation of `tab_strip_layout.layout()` in PowerShell. The
re-implementation it replaced rotted twice (a fixed 46px offset that landed
inside the menu button at 125% DPI; then a modelled tab width that stopped
matching when T235 sized tabs to their titles), each time producing failures
against a completely healthy product.

Returns $null when the window shows no tab strip. THROWS when the server does
not report chrome at all - that means a build older than T231, and answering
$null there would read as "this window has no strip", which is the exact
silent-wrong-model failure T259 is about.

Every rect carries Left/Top/Right/Bottom plus Width/Height/CenterX/CenterY, and
a region with nothing to hit is $null: the strip's "=" on a window whose
caption hosts the menu (T260), a tab the strip could not fit, and every region
of a strip that has not painted yet. Because of that last one this POLLS until
the "+" is reported (a strip always lays one out) or -TimeoutMs elapses, so a
caller never has to know that a freshly shown window reports empty regions for
a few frames.

  Band    - where the strip's content may sit: inside both insets, and the
            buttons' own vertical band. Its Right is the strip's right END,
            which on a merged caption row (T205) is the seam, not the window
            edge.
  Tabs    - one entry per tab, in tab order; $null where a tab did not fit.
  TabsRight - the last laid-out tab's right edge (Band.Left when there are none).
  NewTab  - the "+"'s hit box.
  Menu    - the "="'s hit box, or $null (T260).
#>
function Get-TestStripRegions {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        # The ghoztty CLI to ask. Explicit, because a script that asked the
        # `ghoztty` on PATH would be interrogating the user's installed release
        # about a window this build owns.
        [Parameter(Mandatory = $true)][string]$Exe,
        [int]$TimeoutMs = 5000
    )

    $want = [int64]$Window
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $sawWindow = $false
    while ($true) {
        # A native command writing to stderr is a TERMINATING error under
        # $ErrorActionPreference=Stop (PS5.1 wraps each line in a
        # NativeCommandError), and +list is chatty on a busy box.
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $raw = & $Exe +list --json 2>$null | Out-String } finally { $ErrorActionPreference = $old }

        $j = $null
        if ($raw -and $raw.Trim()) { $j = $raw | ConvertFrom-Json }
        if ($j -and $j.data -and $j.data.windows) {
            foreach ($w in $j.data.windows) {
                if ([int64]$w.id -ne $want) { continue }
                $sawWindow = $true
                if (-not ($w.PSObject.Properties.Name -contains 'chrome')) {
                    throw ("Get-TestStripRegions: this ghoztty reports no 'chrome' in +list --json. " +
                           "That is a build older than T231, not a window without a strip - rebuild " +
                           "with 'zig build -Dapp-runtime=win32 -Doptimize=Debug' rather than " +
                           "treating the absence as an answer.")
                }
                if ($null -eq $w.chrome.tab_strip) { return $null }
                $r = $w.chrome.tab_strip
                if ($null -ne $r.new_tab -or (Get-Date) -ge $deadline) {
                    return [pscustomobject]@{
                        Dpi = [int]$w.chrome.dpi
                        Scale = [double]$w.chrome.dpi / 96.0
                        Band = ConvertTo-TestChromeRect $r.band
                        Tabs = @($r.tabs | ForEach-Object { ConvertTo-TestChromeRect $_ })
                        TabsRight = $(
                            $last = $null
                            foreach ($t in $r.tabs) { if ($null -ne $t) { $last = $t } }
                            if ($null -ne $last) { [int]$last.right } else { [int]$r.band.left }
                        )
                        NewTab = ConvertTo-TestChromeRect $r.new_tab
                        Menu = ConvertTo-TestChromeRect $r.menu
                    }
                }
            }
        }
        if ((Get-Date) -ge $deadline) {
            if (-not $sawWindow) {
                throw ("Get-TestStripRegions: window $want is not in +list --json after ${TimeoutMs}ms " +
                       "(is -Exe the build that owns it?)")
            }
            return $null
        }
        Start-Sleep -Milliseconds 150
    }
}

# One published rect as a probe-friendly object, or $null for a region with
# nothing to hit. Centers are integers because every click site takes one.
function ConvertTo-TestChromeRect($r) {
    if ($null -eq $r) { return $null }
    $l = [int]$r.left; $t = [int]$r.top; $rt = [int]$r.right; $b = [int]$r.bottom
    return [pscustomobject]@{
        Left = $l; Top = $t; Right = $rt; Bottom = $b
        Width = $rt - $l; Height = $b - $t
        CenterX = $l + [int](($rt - $l) / 2)
        CenterY = $t + [int](($b - $t) / 2)
    }
}

<#
Every painted tab chiclet's extent, in CLIENT x, as an array of
`{ Left, Right, Center }` (Right exclusive) - MEASURED off a capture.

**Since T231 this is for assertions about the PAINT, not for click targets.**
`Get-TestStripRegions` reports the app's own tab rects exactly and needs no
capture; what this adds is the only thing a report cannot say - that something
was actually drawn there. Reach for it when "an inactive tab is visible against
the strip" is the claim, and for nothing else. A scan cannot tell a tab that
did not fit from one that painted nothing, and it is 1-2px generous either way
(chiclet antialiasing).

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
    # -StripVisible $true: asking where the tabs are only makes sense on a
    # window that has a strip, so the answer is not a guess here.
    if (-not $m) { $m = Get-TestChromeMetrics -Window $Window -Desktop $Desktop -StripVisible $true }

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
        # The strip background, sampled just left of the "+"'s painted limit -
        # strip that can belong to no tab, whether or not a menu button follows
        # it (T260). The tab run ends one `group_gap` before this, so these
        # pixels are background in every layout the module can produce.
        $bg = $shot.Bitmap.GetPixel($m.OffX + $m.RunRight - 2, $rowY)
        $runStart = -1
        # Runs to RunRight inclusive-exclusive so a run touching the right end
        # is still closed off.
        for ($x = $m.PadL; $x -le $m.RunRight; $x++) {
            $isTab = $false
            if ($x -lt $m.RunRight) {
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
The last tab's painted right edge, in CLIENT x, exclusive - MEASURED, with the
same caveat as `Get-TestTabExtents`: since T231, prefer
`(Get-TestStripRegions ...).TabsRight`, which is the app's own answer.

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
    # -StripVisible $true: asking where the tabs are only makes sense on a
    # window that has a strip, so the answer is not a guess here.
    if (-not $m) { $m = Get-TestChromeMetrics -Window $Window -Desktop $Desktop -StripVisible $true }

    $tabs = @(Get-TestTabExtents -Window $Window -Shot $Shot -Metrics $m -Desktop $Desktop)
    if ($tabs.Count -eq 0) { return $m.PadL }
    return $tabs[$tabs.Count - 1].Right
}

<#
Thickness of the top resize band in physical px, exactly as
`caption_layout.resizeBorder` derives it: the window-DPI
`SM_CYSIZEFRAME + SM_CXPADDEDBORDER`, clamped to half the band, floor 1.
`-PadSm` is the 4 DIP step (the module's fallback for a 0/negative metric).

T266 measured the reference (live WindowsTerminal.exe 1.24, 2026-08-06, 125%):
over a TAB, WT's island child answers HTCLIENT from the very top row — a tab
is never a resize target — while WT's drag-bar child gives the EMPTY band an
HTTOP edge. `chrome-merged-row` §4 therefore asserts HTCLIENT at a tab's top
and uses this count for the boundary probes over the empty band, where we keep
the full stock-frame metric.
#>
function Get-TestResizeBorder {
    param(
        [Parameter(Mandatory = $true)][int]$Dpi,
        [Parameter(Mandatory = $true)][int]$BarH,
        [Parameter(Mandatory = $true)][int]$PadSm
    )
    if (-not ('GhozttyTestSysMetrics' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class GhozttyTestSysMetrics {
    [DllImport("user32.dll")] public static extern int GetSystemMetricsForDpi(int index, uint dpi);
}
'@
    }
    $frame = [GhozttyTestSysMetrics]::GetSystemMetricsForDpi(33, $Dpi) +
             [GhozttyTestSysMetrics]::GetSystemMetricsForDpi(92, $Dpi)
    if ($frame -le 0) { $frame = [Math]::Max($PadSm, 1) }
    return [Math]::Max(1, [Math]::Min($frame, [int][Math]::Truncate($BarH / 2)))
}

# ---------------------------------------------------------------------------
# The machine chooser's session roster (T318, hoisted here in T319)
# ---------------------------------------------------------------------------
#
# Same rule as the tab strip above, for the same reason: `chooser-sessions.ps1`
# derived this privately, and the moment a SECOND script needed to click the
# same Kill button there were two copies of one datum - which is exactly the
# shape T257 spent a task deleting four times over. It lives here now.
#
# Everything on this path is a pure DIP constant out of `chooser_layout.layout`
# and `chooser_sessions.rowLayout`; nothing comes from text metrics, which is
# the only reason it can be re-derived at all rather than measured (T256).
function Get-TestChooserRosterGeometry {
    param(
        [Parameter(Mandatory = $true)][double]$Scale
    )
    $s = $Scale
    $margin = Get-TestChromeDip 16 $s
    $gap = Get-TestChromeDip 8 $s
    $controlH = Get-TestChromeDip 28 $s
    $clientW = Get-TestChromeDip 840 $s
    $clientH = Get-TestChromeDip 540 $s

    $avatarD = Get-TestChromeDip 32 $s
    $emailH = (Get-TestChromeDip 12 $s) + (Get-TestChromeDip 4 $s)
    $linkH = (Get-TestChromeDip 14 $s) + (Get-TestChromeDip 4 $s)
    $stackGap = Get-TestChromeDip 2 $s
    # T602: the selected machine's identity stack (subtitle-role name over a
    # caption count) lives in the band and is its tallest tenant.
    $titleH = (Get-TestChromeDip 20 $s) + (Get-TestChromeDip 4 $s)
    $subtitleH = (Get-TestChromeDip 12 $s) + (Get-TestChromeDip 4 $s)
    $identityH = $titleH + $stackGap + $subtitleH
    $accountH = [math]::Max(
        [math]::Max([math]::Max($avatarD, $emailH + $stackGap + $linkH), $identityH),
        $controlH)
    $headerDividerY = $gap + $accountH + $gap

    $cancelTop = $clientH - $margin - $controlH
    $footerDividerY = $cancelTop - $margin
    $bodyTop = $headerDividerY + 1
    $bodyBottom = $footerDividerY

    $masterW = Get-TestChromeDip 260 $s
    $detailLeft = $masterW + 1
    # T602: the detail pane begins at its action row (vertical padding 12); the
    # session-list column headers take one caption line box under it, then the
    # roster after a 4 DIP hair.
    $actionTop = $bodyTop + (Get-TestChromeDip 12 $s)
    $headerTop = $actionTop + $controlH + (Get-TestChromeDip 12 $s)
    $headerH = $subtitleH

    $left = $detailLeft + $margin
    $right = $clientW - $margin
    $top = $headerTop + $headerH + (Get-TestChromeDip 4 $s)
    $bottom = $bodyBottom - $margin

    # First card: padded on all sides, its Kill button a 28 DIP painted square
    # against the trailing padding, centred on the title's line box.
    $padX = Get-TestChromeDip 12 $s
    $padY = Get-TestChromeDip 8 $s
    $cardTitleH = (Get-TestChromeDip 14 $s) + (Get-TestChromeDip 4 $s)
    $killW = Get-TestChromeDip 28 $s
    $killX = $right - $padX - [int]([math]::Floor($killW / 2))
    $killY = $top + $padY + [int]([math]::Floor($cardTitleH / 2))

    # The per-session CPU meter's column (T462), when the machine's agent can
    # serve the pushed stream: the 24 DIP bar sits after the card padding, the
    # 12 DIP liveness-dot column and the 8 DIP text gap, centred on the title's
    # line box. A BAND rather than a point, because which row is the busy one
    # depends on session creation order - a scan across the band answers "is any
    # meter drawn" without pinning a row.
    $meterLeft = $left + $padX + (Get-TestChromeDip 12 $s) + (Get-TestChromeDip 8 $s)

    # The session-list column headers (T602): the CPU zone rides the meter
    # column the rows reserve (present only when the machine's agent serves the
    # stream — the local agent does), the Name zone the text column after it.
    $cpuColW = (Get-TestChromeDip 24 $s) + (Get-TestChromeDip 4 $s) + (Get-TestChromeDip 28 $s)
    $cpuZoneLeft = $left + $padX + (Get-TestChromeDip 12 $s) + (Get-TestChromeDip 8 $s)
    $nameZoneLeft = $cpuZoneLeft + $cpuColW + (Get-TestChromeDip 8 $s)

    return [pscustomobject]@{
        Left  = $left; Top = $top; Right = $right; Bottom = $bottom
        KillX = $killX; KillY = $killY
        # A point INSIDE the first card's fill and clear of every mark: one
        # scale-step in from the card's left edge, on the title's line.
        CardX = $left + (Get-TestChromeDip 4 $s)
        CardY = $top + $padY + [int]([math]::Floor($cardTitleH / 2))
        MeterLeft = $meterLeft
        MeterRight = $meterLeft + (Get-TestChromeDip 24 $s)
        # Header click points (T602), mid-line in each zone.
        HeaderY = $headerTop + [int]([math]::Floor($headerH / 2))
        CpuHeaderX = $cpuZoneLeft + (Get-TestChromeDip 8 $s)
        NameHeaderX = $nameZoneLeft + (Get-TestChromeDip 8 $s)
    }
}
