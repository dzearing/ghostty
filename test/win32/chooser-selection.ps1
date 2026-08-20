# Machine-chooser SELECTION TREATMENT acceptance (T828).
#
# The user reported the chooser's selected row as "a bright purple pill with a
# thick purple outline" beside a screenshot of Windows 11 Settings, whose lists
# mark selection with a quiet neutral fill and a small accent bar at the leading
# edge. The row painter now does the same (`chooser_rows.rowPaint`): a neutral
# wash at two weights, the accent spent on ONE 4x16 capsule indicator, and the
# focus rim in neutral ink rather than a second accent ring.
#
# The unit tests in `chooser_rows.zig` assert the model; this script asserts the
# PIXELS, because the defect was never in the numbers - every colour in the old
# treatment cleared its contrast floor and the model tests were green while the
# chooser looked like that. What is measured here:
#
#   B. at open - the list does not hold focus, since the chooser focuses its
#      filter field - the selected row is the DERIVED unemphasized wash of the
#      row background (ColorMath's `Get-Wash`, the same function the Zig side
#      spells `color_math.wash`) and its mark is NEUTRAL, so the accent still
#      means "this is the control you are driving";
#   C. clicking the row moves the list to the emphasized wash and turns the mark
#      into the user's accent, which clears the 3:1 chrome floor against the
#      fill it sits on and is a narrow BAR, not a filled column;
#   D. the pill has no outline in either state: every pixel along its top, right
#      and bottom edges is the fill itself;
#   E. and when Windows says focus visuals are SHOWN (UISF_HIDEFOCUS cleared,
#      which is what keyboard navigation does), the one outline the row is
#      allowed grows inside the pill - the design system's 2.2 focus rim, in
#      NEUTRAL ink rather than a second accent mark.
#
# D is the assertion that would have caught the reported defect (a
# full-perimeter accent border stacked with an accent focus ring), and B/C are
# what keep the fix from drifting back a wash at a time.
#
# C/D and E each PIN the UI-state bit they are claiming about (T988), rather
# than inheriting whatever the harness's own input left behind. D's claim is
# "no outline", the rim IS an outline drawn on purpose, and which one the app
# paints is Windows' call and not the script's - so a section that does not say
# which state it measures is red or green by luck. This one was measured red and
# then green on 2026-08-19 against the same build. (B needs no pin: there the
# list does not hold focus at all, so there is no rim either way.)
#
# The oracles read EDGES and the mark's own column, never a scan for "coloured
# pixels": the row's text is drawn with subpixel antialiasing, whose fringes are
# as saturated as any accent (#80b9ed and #7f5b4e were measured on this fixture's
# own title line), so a chroma scan over the row would score the font renderer.
#
#   powershell -NoProfile -File test\win32\chooser-selection.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-t828'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ColorMath.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# Kill only what this repo built. The installed release (and ITS agent, which
# owns the user's real terminal) is never touched.
function Stop-RepoProcesses {
    foreach ($name in @('ghoztty', 'ghoztty-agent')) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 500
}

# Round HALF AWAY FROM ZERO, the way Zig's `@round` does.
function Px([double]$dip, [double]$scale) { return [int][math]::Floor($dip * $scale + 0.5) }

# The wash weights, by their Zig names (`chooser_rows.zig`). DERIVED, never
# pasted as colours: move the weight in the Zig and this script moves with it.
$SELECTION_WASH_UNFOCUSED = 0.10
$SELECTION_WASH_FOCUSED = 0.16

# Windows' UI-state mechanism (T988). Focus rectangles stay hidden until the
# user navigates by keyboard, and an owner-drawn listbox reads that back as
# `ODS_NOFOCUSRECT` -> `RowState.focus_visible`. Sections C/D and E each pin
# the bit they are making a claim about instead of inheriting whichever state
# the harness's own input happened to leave behind: a posted chord and a real
# one do not agree on it, which is why C/D were intermittently red.
$WM_CHANGEUISTATE = 0x0127
$WM_QUERYUISTATE = 0x0129
$UIS_SET = 1
$UIS_CLEAR = 2
$UISF_HIDEFOCUS = 0x1

# MAKEWPARAM(action, flags) - the action is the low word, the flags the high.
function UiStateWParam([int]$action, [int]$flags) {
    return [IntPtr]($action -bor ($flags -shl 16))
}

# The most common colour over a grid of a capture's region, in SCREEN
# coordinates. A modal colour - not a single sample - is what makes this robust
# to the text and glyphs drawn on top of the fill being measured.
function Get-ModalColor($shot, [int]$x0, [int]$y0, [int]$x1, [int]$y1, [int]$step) {
    $seen = @{}
    for ($y = $y0; $y -lt $y1; $y += $step) {
        for ($x = $x0; $x -lt $x1; $x += $step) {
            $p = Get-TestPixel -Shot $shot -X $x -Y $y
            if (-not $p) { continue }
            $k = "$($p.R),$($p.G),$($p.B)"
            if ($seen.ContainsKey($k)) { $seen[$k]++ } else { $seen[$k] = 1 }
        }
    }
    if ($seen.Count -eq 0) { return $null }
    $best = ($seen.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1)
    $parts = $best.Key -split ','
    return [pscustomobject]@{
        Rgb   = @([int]$parts[0], [int]$parts[1], [int]$parts[2])
        Count = $best.Value
        Total = ($seen.Values | Measure-Object -Sum).Sum
    }
}

function Launch-Gui($errlog) {
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--window-width=100', '--window-height=30') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

Write-Host 'T828 chooser selection treatment'
Stop-RepoProcesses
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t828-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

try {
    Write-Host ''
    Write-Host 'A. the chooser opens with its list selected'
    $g = Launch-Gui $errlog
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    $chooser = [IntPtr]::Zero
    if (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N) {
        $chooser = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }

    # `Get-ChooserControl` answers with the control's SCREEN rect (its
    # `Children` helper reads `GetWindowRect`), which is the space
    # `Get-TestPixel` addresses, so the list rect is used as it comes back.
    $list = Get-ChooserList -Chooser $chooser
    Assert ($null -ne $list) 'the machine list control is addressable'
    if ($null -eq $list) { Write-Host 'SETUP FAIL: no list control'; exit 1 }

    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $lr = $list

    # Geometry, in the row painter's own DIPs (`chooser_rows.rowMetrics`).
    $fillInsetX = Px 4 $scale         # row edge -> pill
    $fillInsetY = [int]((Px 2 $scale) / 2)
    $indicatorX = $fillInsetX + (Px 2 $scale)
    $indicatorW = [math]::Max((Px 4 $scale), 1)
    $markBand = $indicatorX + $indicatorW
    $midX = [int]($lr.Width / 2)

    # Score one captured frame. `$wash` is the weight the fill is expected to
    # carry, `$accented` whether the mark should be the user's accent.
    function Measure-Row($shot, [string]$label, [double]$wash, [bool]$accented) {
        # The unselected background: the column wash, from the empty space below
        # the only row this fixture has (no relay configured -> one row,
        # "Local", which draws no status dot by construction).
        $bg = Get-ModalColor $shot ($lr.Left + $fillInsetX + 2) ($lr.Bottom - (Px 60 $scale)) `
            ($lr.Right - $fillInsetX - 2) ($lr.Bottom - 2) 3
        Assert ($null -ne $bg) "$label - the row background was sampled"
        if ($null -eq $bg) { return }

        # The pill's own fill, read on its top edge line, which no text or glyph
        # can reach.
        $fillPx = Get-TestPixel -Shot $shot -X ($lr.Left + $midX) -Y ($lr.Top + $fillInsetY)
        Assert ($null -ne $fillPx) "$label - the selected pill was sampled"
        if ($null -eq $fillPx) { return }
        $fill = @([int]$fillPx.R, [int]$fillPx.G, [int]$fillPx.B)

        $want = Get-Wash $bg.Rgb $wash
        Write-Host "     $label row bg $(Format-Rgb $bg.Rgb), pill $(Format-Rgb $fill), want $(Format-Rgb $want)"
        Assert ((Get-ChannelDistance $fill $want) -le 2) `
            "$label - the fill IS wash(row bg, $wash), not an accent tint"

        $fillChroma = ($fill | Measure-Object -Maximum).Maximum - ($fill | Measure-Object -Minimum).Minimum
        $bgChroma = ($bg.Rgb | Measure-Object -Maximum).Maximum - ($bg.Rgb | Measure-Object -Minimum).Minimum
        Assert ($fillChroma -le $bgChroma + 4) `
            "$label - the pill adds no colour of its own (chroma $fillChroma vs the row's $bgChroma)"

        # Where the row ends: found by reading down the pill rather than by
        # re-deriving a row height here (the T256 rule - a datum that the paint
        # already carries is measured, never restated). Read down the pill's
        # trailing column, which the row's text never reaches; the middle does,
        # and a subpixel-antialiased glyph would end the scan on the title line.
        $probeX = $lr.Width - $fillInsetX - (Px 8 $scale)
        $rowBottom = 0
        for ($y = $fillInsetY; $y -lt ($lr.Height - 1); $y++) {
            $p = Get-TestPixel -Shot $shot -X ($lr.Left + $probeX) -Y ($lr.Top + $y)
            if (-not $p -or (Get-ChannelDistance @([int]$p.R, [int]$p.G, [int]$p.B) $fill) -gt 2) { $rowBottom = $y; break }
        }
        Assert ($rowBottom -ge (Px 40 $scale)) "$label - the selected row is a full row tall ($rowBottom px)"
        if ($rowBottom -lt (Px 40 $scale)) { return }

        # --- the mark ---------------------------------------------------------
        $barPx = Get-TestPixel -Shot $shot -X ($lr.Left + $indicatorX + [int]($indicatorW / 2)) `
            -Y ($lr.Top + [int]($rowBottom / 2))
        Assert ($null -ne $barPx) "$label - the indicator bar was sampled"
        if ($null -eq $barPx) { return }
        $bar = @([int]$barPx.R, [int]$barPx.G, [int]$barPx.B)
        $barContrast = Get-Contrast $bar $fill
        Assert ($barContrast -ge 2.9) ("$label - the indicator clears the 3:1 chrome floor against the pill " +
            "($([math]::Round($barContrast, 2)):1, $(Format-Rgb $bar))")

        $barChroma = ($bar | Measure-Object -Maximum).Maximum - ($bar | Measure-Object -Minimum).Minimum
        if ($accented) {
            Assert ($barChroma -ge 40) `
                "$label - the mark carries the user's accent ($(Format-Rgb $bar), chroma $barChroma)"
        } else {
            Assert ($barChroma -le 12) `
                "$label - the mark is NEUTRAL while the caret is elsewhere ($(Format-Rgb $bar), chroma $barChroma)"
        }

        # It is a bar: a column of it, and the fill immediately on either side.
        $tall = 0
        for ($y = $fillInsetY; $y -lt $rowBottom; $y++) {
            $p = Get-TestPixel -Shot $shot -X ($lr.Left + $indicatorX + [int]($indicatorW / 2)) -Y ($lr.Top + $y)
            if ($p -and (Get-ChannelDistance @([int]$p.R, [int]$p.G, [int]$p.B) $bar) -le 6) { $tall++ }
        }
        Assert ($tall -gt $indicatorW -and $tall -lt $rowBottom) `
            "$label - the mark is a bar, not a stripe down the whole row (${indicatorW}x$tall in a $rowBottom row)"
        # Parenthesized per element: in PS 5.1 the comma binds TIGHTER than `+`,
        # so `@($a + 1, $b + 2)` is `$a + (1, $b) + 2` and dies on array addition.
        foreach ($x in @(($fillInsetX + 1), ($markBand + (Px 2 $scale)))) {
            $p = Get-TestPixel -Shot $shot -X ($lr.Left + $x) -Y ($lr.Top + [int]($rowBottom / 2))
            Assert ($p -and (Get-ChannelDistance @([int]$p.R, [int]$p.G, [int]$p.B) $fill) -le 2) `
                "$label - the pill's fill runs either side of the mark (x=$x)"
        }

        # --- the perimeter, which is the reported defect ----------------------
        # A border of ANY colour fails here, and the accent border plus accent
        # focus ring that was reported would fail it on three edges at once.
        $edges = 0
        $bad = 0
        $firstBad = ''
        $probes = @()
        # The pill is a ROUNDED rect, so its corner pixels are legitimately the
        # row behind it; the edge runs stop a radius short of them.
        $radius = Px 4 $scale
        for ($x = $markBand + (Px 8 $scale); $x -lt ($lr.Width - $fillInsetX - $radius); $x += 3) {
            $probes += , @($x, $fillInsetY)        # top edge
            $probes += , @($x, ($rowBottom - 1))   # bottom edge
        }
        $rightEdge = $lr.Width - $fillInsetX - 1
        for ($y = (Px 8 $scale); $y -lt ($rowBottom - (Px 8 $scale)); $y += 3) {
            $probes += , @($rightEdge, $y)   # right edge
        }
        foreach ($pr in $probes) {
            $p = Get-TestPixel -Shot $shot -X ($lr.Left + $pr[0]) -Y ($lr.Top + $pr[1])
            if (-not $p) { continue }
            $edges++
            if ((Get-ChannelDistance @([int]$p.R, [int]$p.G, [int]$p.B) $fill) -gt 6) {
                $bad++
                if ($firstBad -eq '') { $firstBad = "x=$($pr[0]) y=$($pr[1]) $(Format-Rgb @([int]$p.R, [int]$p.G, [int]$p.B))" }
            }
        }
        Assert ($edges -gt 40) "$label - the perimeter was actually probed ($edges points)"
        Assert ($bad -eq 0) `
            "$label - the pill has NO outline: every edge pixel is the fill ($bad of $edges differ$(if ($firstBad) { ", first at $firstBad" }))"
    }

    Write-Host ''
    Write-Host 'B. at open the selection is unemphasized, and its mark is neutral'
    $shot = Get-TestWindowPixels -Window $chooser -Sync
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "the capture is a real frame, not a black mid-paint one ($distinct colors)"
        Measure-Row $shot 'unfocused' $SELECTION_WASH_UNFOCUSED $false
    } finally { Close-TestWindowPixels -Shot $shot }

    Write-Host ''
    Write-Host 'C/D. clicking the row emphasizes it and spends the accent on the mark'
    # Pointer-driven, so focus visuals are hidden - Windows' own convention, and
    # the state D's "no outline anywhere on the perimeter" claim belongs to. The
    # rim IS an outline, drawn on purpose (design system 2.2), so D can only be honest about
    # a state that names whether the rim is showing; before T988 it named
    # neither and went red whenever a real keyboard chord had cleared the bit.
    $null = Invoke-TestMessage -Window $chooser -Message $WM_CHANGEUISTATE `
        -WParam (UiStateWParam $UIS_SET $UISF_HIDEFOCUS)
    Start-Sleep -Milliseconds 250
    $uiState = [int](Invoke-TestMessage -Window ([IntPtr]$lr.Hwnd) -Message $WM_QUERYUISTATE)
    Assert (($uiState -band $UISF_HIDEFOCUS) -ne 0) `
        "the list is in the pointer-driven state: focus visuals hidden (UI state 0x$('{0:x}' -f $uiState))"

    # Posted to the LIST, not to the dialog: a click the dialog receives never
    # reaches the listbox's own focus handling, and the row would stay
    # unemphasized while the script believed it had clicked it.
    Send-TestMouse -Window ([IntPtr]$lr.Hwnd) -X ($lr.Left + $midX) -Y ($lr.Top + (Px 20 $scale)) `
        -Button left -Action click | Out-Null
    Start-Sleep -Milliseconds 500

    $fillFocused = $null
    $shot2 = Get-TestWindowPixels -Window $chooser -Sync
    try {
        Measure-Row $shot2 'focused' $SELECTION_WASH_FOCUSED $true
        $fp = Get-TestPixel -Shot $shot2 -X ($lr.Left + $midX) -Y ($lr.Top + $fillInsetY)
        if ($fp) { $fillFocused = @([int]$fp.R, [int]$fp.G, [int]$fp.B) }
    } finally { Close-TestWindowPixels -Shot $shot2 }

    Write-Host ''
    Write-Host 'E. once Windows says focus visuals are shown, the rim appears - in NEUTRAL ink'
    # The other half of the same bit. `rowPaint` draws the 2.2 focus rim only when
    # `focus_visible`, and T828's amendment is that it is drawn in
    # `chrome_theme.textOn` and not in the accent: the row already spends the
    # accent on its indicator, and two accent marks on one control is the
    # doubled purple outline that was reported. Nothing measured the rim's
    # PIXELS until now - the unit tests assert the colour model, and C/D only
    # ever saw the state where it is not drawn.
    $null = Invoke-TestMessage -Window $chooser -Message $WM_CHANGEUISTATE `
        -WParam (UiStateWParam $UIS_CLEAR $UISF_HIDEFOCUS)
    Start-Sleep -Milliseconds 350
    $uiState2 = [int](Invoke-TestMessage -Window ([IntPtr]$lr.Hwnd) -Message $WM_QUERYUISTATE)
    Assert (($uiState2 -band $UISF_HIDEFOCUS) -eq 0) `
        "the list is in the keyboard-driven state: focus visuals shown (UI state 0x$('{0:x}' -f $uiState2))"
    Assert ($null -ne $fillFocused) 'the emphasized fill was carried over from C'

    if ($null -ne $fillFocused -and ($uiState2 -band $UISF_HIDEFOCUS) -eq 0) {
        $shot3 = Get-TestWindowPixels -Window $chooser -Sync
        try {
            # Walk down the pill's own column from its top edge. The rim is
            # inset a pixel or two inside the pill (`focus_path_inset`), so it
            # is the first thing on that column that is not the fill - found by
            # reading, never by re-deriving the inset here (the T256 rule).
            $rim = $null
            $rimY = -1
            for ($y = $fillInsetY; $y -lt ($fillInsetY + (Px 8 $scale)); $y++) {
                $p = Get-TestPixel -Shot $shot3 -X ($lr.Left + $midX) -Y ($lr.Top + $y)
                if (-not $p) { continue }
                $c = @([int]$p.R, [int]$p.G, [int]$p.B)
                if ((Get-ChannelDistance $c $fillFocused) -gt 6) { $rim = $c; $rimY = $y; break }
            }
            Assert ($null -ne $rim) "the focus rim is drawn inside the pill (y=$rimY, $(if ($rim) { Format-Rgb $rim } else { 'nothing but fill' }))"
            if ($null -ne $rim) {
                $rimChroma = ($rim | Measure-Object -Maximum).Maximum - ($rim | Measure-Object -Minimum).Minimum
                Assert ($rimChroma -le 12) `
                    "the rim is NEUTRAL ink, not a second accent mark ($(Format-Rgb $rim), chroma $rimChroma)"
                $rimContrast = Get-Contrast $rim $fillFocused
                Assert ($rimContrast -ge 3.0) `
                    "the rim reads against the pill it sits in ($([math]::Round($rimContrast, 2)):1)"
            }
        } finally { Close-TestWindowPixels -Shot $shot3 }
    }

    Send-TestControlKey -Control $chooser -Key Escape | Out-Null
    Start-Sleep -Milliseconds 300
} catch {
    # A throw here used to leave the verdict reading ALL PASS over the handful
    # of assertions that had run before it - the exact shape the exit-code audit
    # exists to stop.
    Write-Host "  FAIL harness error: $_" -ForegroundColor Red
    $script:fail++
} finally {
    Stop-RepoProcesses
    Remove-TestDesktop
}

# --- stamp (T783) ----------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-selection -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'chooser-selection' -MinPass 20
