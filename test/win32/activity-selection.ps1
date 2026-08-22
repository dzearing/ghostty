# Activity Monitor SELECTION TREATMENT acceptance (T1008).
#
# The user reported the machine chooser's selected row as "a bright purple pill
# with a thick purple outline" beside a screenshot of Windows 11 Settings, whose
# lists mark selection with a quiet neutral fill and a small accent bar at the
# leading edge. T828 fixed it on the chooser and left the Activity Monitor's
# process table - the same kind of surface, a list of selectable rows - painting
# the treatment that was reported: the panel dragged 45 percent toward the accent
# under an accent focus ring. This script asserts the process table now paints
# what the chooser does, out of the same module (`list_selection.zig`).
#
# The unit tests assert the model; this asserts the PIXELS, for the reason
# `chooser-selection.ps1` does: every colour in the old treatment cleared its
# contrast floor and the model tests were green while the panel looked like that.
# What is measured here:
#
#   B. with the row selected and the caret moved off the table, the row carries
#      the DERIVED unemphasized wash of the panel (ColorMath's `Get-Wash`, the
#      same function the Zig side spells `color_math.wash`), its mark is NEUTRAL,
#      and the row has NO outline - every line across it is the fill itself;
#   C. driving the table moves it to the emphasized wash and turns the mark into
#      the user's accent, which clears the 3:1 chrome floor against the fill it
#      sits on and is a narrow BAR, not a stripe down the whole row;
#   D. the accent appears EXACTLY ONCE on that row: the caret rim the table draws
#      over it is neutral ink, not a second accent mark. D is the assertion that
#      would have caught the reported defect.
#
# PINNING THE FOCUS STATE (T988's rule). Which weight the fill carries and
# whether a rim is drawn are both functions of "does the table hold the
# keyboard", so a section that does not say which state it measures is red or
# green by luck. The panel has no `UISF_HIDEFOCUS` equivalent to post at it - its
# table is an owner-drawn region rather than a control, and teaching it Windows'
# focus-visual bit is T1009 - so the state is pinned the way the panel itself
# defines it: B clicks the filter field (the panel loses the keyboard, so the
# table is unemphasized and draws no rim) and C clicks the row (the panel takes
# it back and the table is the focused region). Each section asserts the state it
# claims, from the row's own paint, before it measures anything else.
#
# THE ORACLE reads the row one LINE at a time - the modal colour of a horizontal
# strip - and never scans for "coloured pixels": cell text is drawn with subpixel
# antialiasing whose fringes are as saturated as any accent, so a chroma scan
# over a row would be scoring the font renderer. A modal per line answers what
# the line IS (the fill, or an outline drawn across the whole row), which is what
# every claim here is about; the mark is read from its own column, which sits
# inside the first cell's padding where no glyph can reach.
#
#   powershell -NoProfile -File test\win32\activity-selection.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-t1008'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ColorMath.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$errlog = Join-Path $env:TEMP "ghoztty-t1008-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

# The panel's surface is derived from the terminal background (T308), so it is
# pinned here rather than guessed - and then SAMPLED anyway, so a theme that
# moves it moves the oracle with it.
$PANEL_BG = @(0x1E, 0x1E, 0x1E)
$PANEL_BG_HEX = Format-Rgb $PANEL_BG

# The wash weights, by their Zig names (`list_selection.zig`). DERIVED, never
# pasted as colours: move a weight in the Zig and this script moves with it.
$SELECTION_WASH_UNFOCUSED = 0.10
$SELECTION_WASH_FOCUSED = 0.16

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoProcesses {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

# Round HALF AWAY FROM ZERO, the way Zig's `@round` does.
function Px([double]$dip, [double]$scale) { return [int][math]::Floor($dip * $scale + 0.5) }

function Count-PanelLines {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern 'activity monitor: source=').Count
}

function Get-PanelState {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: source=(\S+) total=(\d+) shown=(\d+) needle="([^"]*)" show_all=(\w+) sort=(\w+)/(\w+) selected=(\d+)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{
        Shown    = [int]$g[3].Value
        Selected = [int]$g[8].Value
    }
}

function Wait-PanelState([int]$sinceCount, [int]$TimeoutMs = 8000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Count-PanelLines) -gt $sinceCount) { return Get-PanelState }
        Start-Sleep -Milliseconds 200
    }
    return Get-PanelState
}

# The most common colour over a grid of a capture's region, in SCREEN
# coordinates. A modal colour - not a single sample - is what makes this robust
# to whatever is drawn on top of the surface being measured.
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
    return @([int]$parts[0], [int]$parts[1], [int]$parts[2])
}

function Get-Chroma([int[]]$c) {
    return (($c | Measure-Object -Maximum).Maximum - ($c | Measure-Object -Minimum).Minimum)
}

function Get-PixelRgb($shot, [int]$x, [int]$y) {
    $p = Get-TestPixel -Shot $shot -X $x -Y $y
    if (-not $p) { return $null }
    return @([int]$p.R, [int]$p.G, [int]$p.B)
}

# The panel's table header band, found the way activity-monitor.ps1 finds it:
# down the panel's trailing edge, which no cell text reaches. Returns
# @(headerY, firstRowY).
function Get-FirstRowY([IntPtr]$Panel, $Client, $Fr, [int[]]$Header, [int[]]$Divider) {
    $shot = Get-TestWindowPixels -Window $Panel -Sync
    try {
        $x = $Client.Right - 20
        $headerY = -1
        for ($y = [int]$Fr.Bottom; $y -lt $Client.Bottom; $y++) {
            $c = Get-PixelRgb $shot $x $y
            if ($c -and (Get-ChannelDistance $c $Header) -eq 0) { $headerY = $y; break }
        }
        if ($headerY -lt 0) { return @(-1, -1) }
        for ($y = $headerY; $y -lt $Client.Bottom; $y++) {
            $c = Get-PixelRgb $shot $x $y
            if (-not $c) { continue }
            if ((Get-ChannelDistance $c $Header) -eq 0) { continue }
            if ((Get-ChannelDistance $c $Divider) -eq 0) { continue }
            return @($headerY, $y)
        }
        return @($headerY, -1)
    } finally { Close-TestWindowPixels -Shot $shot }
}

Write-Host 'T1008 activity monitor selection treatment'
Stop-RepoProcesses
New-TestDesktop | Out-Null

$script:app = $null
try {
    $script:app = Start-OnTestDesktop -Exe $exe `
        -Arguments @('--session-persistence=false', "--background=$PANEL_BG_HEX") -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }

    Write-Host ''
    Write-Host 'A. the panel opens with a table that has rows'
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -eq [IntPtr]::Zero) {
        Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a T1008 verdict'
        exit 1
    }
    $pedit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($pedit -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette edit not found'; exit 1 }
    Send-TestControlText -Control $pedit -Text 'ACTIVITY MONITOR' | Out-Null
    Send-TestControlKey -Control $pedit -Key Enter | Out-Null
    Start-Sleep -Milliseconds 900

    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'the Activity Monitor panel opened'
    if ($panel -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no panel'; exit 1 }

    $filterEdit = Find-TestWindowEx -Parent $panel -Class 'EDIT'
    Assert ($filterEdit -ne [IntPtr]::Zero) 'the filter field is addressable'
    if ($filterEdit -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no filter field'; exit 1 }

    $st = Wait-PanelState 0
    Assert ($null -ne $st -and $st.Shown -ge 1) "the table populated (shown=$(if ($st) { $st.Shown } else { 'no state line' }))"

    # Narrow to the app's own pid: one row makes "the selected row" unambiguous
    # and leaves everything below it bare panel, which is what the background
    # oracle reads.
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text "$($app.Pid)" | Out-Null
    $st = Wait-PanelState $before
    Assert ($null -ne $st -and $st.Shown -ge 1) "the table narrowed to the app's own pid (shown=$(if ($st) { $st.Shown } else { 'none' }))"

    $client = Get-TestWindowRect -Window $panel -Client
    $fr = Get-TestWindowRect -Window $filterEdit
    $scale = (Get-TestWindowDpi -Window $panel) / 96.0

    $bgShot = Get-TestWindowPixels -Window $panel -Sync
    try {
        $distinct = Get-TestDistinctColors -Shot $bgShot
        Assert ($distinct -gt 3) "the capture is a real frame, not a black mid-paint one ($distinct colors)"
    } finally { Close-TestWindowPixels -Shot $bgShot }

    $panelBg = $PANEL_BG
    $header = Get-PanelHeader $panelBg
    $divider = Get-PanelRaised $panelBg
    $rowInfo = Get-FirstRowY $panel $client $fr $header $divider
    $rowY = $rowInfo[1]
    Assert ($rowY -ge 0) 'the first table row was located by its own paint'
    if ($rowY -lt 0) { throw 'no row to measure' }

    # Geometry, in the painter's own DIPs (`activity_layout.rowIndicator`).
    $indicatorX = Px 2 $scale
    $indicatorW = [math]::Max((Px 4 $scale), 1)
    $markBand = $indicatorX + $indicatorW

    # Score one captured frame of the selected row. `$wash` is the weight the
    # fill is expected to carry, `$accented` whether the mark should be the
    # user's accent, `$outlined` whether a focus rim is legitimately drawn on it.
    #
    # The row is read LINE BY LINE, as the modal colour of a horizontal strip
    # rather than as single pixels: a table row is full of cell text whose
    # subpixel-antialiased fringes are as saturated as any accent, and a probe
    # that walked one column would be scoring the font renderer. A modal per line
    # gives the surface the line actually IS - the fill, or an outline drawn
    # across the whole row - which is the thing being claimed about.
    function Measure-Row($shot, [string]$label, [double]$wash, [bool]$accented, [bool]$outlined) {
        # The bare panel, from the empty area below the rows.
        $bg = Get-ModalColor $shot ($client.Left + 40) ($rowY + (Px 60 $scale)) `
            ($client.Right - 40) ($client.Bottom - (Px 40 $scale)) 3
        Assert ($null -ne $bg) "$label - the panel background was sampled"
        if ($null -eq $bg) { return $null }

        # The strip every line is measured over: clear of the indicator mark at
        # the leading edge, and stopping short of the row's trailing edge.
        $stripX0 = $client.Left + $markBand + (Px 24 $scale)
        $stripX1 = [math]::Min(($stripX0 + 400), ($client.Right - (Px 6 $scale)))

        # How far the row runs, found by READING the paint rather than
        # re-deriving the row height here (the T256 rule): down from its top
        # edge until a line is the bare panel again.
        $lines = @()
        $rowBottom = 0
        for ($y = $rowY; $y -lt ($rowY + (Px 60 $scale)); $y++) {
            $c = Get-ModalColor $shot $stripX0 $y $stripX1 ($y + 1) 3
            if ($null -eq $c -or (Get-ChannelDistance $c $bg) -le 2) { $rowBottom = $y; break }
            $lines += , $c
        }
        Assert ($rowBottom -gt ($rowY + (Px 16 $scale))) `
            "$label - the selected row is a full row tall ($($rowBottom - $rowY) px)"
        if ($rowBottom -le ($rowY + (Px 16 $scale))) { return $null }

        # The fill is what MOST of those lines are; an outline, if the state
        # admits one, is the minority that is not.
        $tally = @{}
        foreach ($c in $lines) {
            $k = "$($c[0]),$($c[1]),$($c[2])"
            if ($tally.ContainsKey($k)) { $tally[$k]++ } else { $tally[$k] = 1 }
        }
        $topKey = ($tally.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
        $parts = $topKey -split ','
        $fill = @([int]$parts[0], [int]$parts[1], [int]$parts[2])

        $want = Get-Wash $bg $wash
        Write-Host "      $label panel $(Format-Rgb $bg), row $(Format-Rgb $fill), want $(Format-Rgb $want)"
        Assert ((Get-ChannelDistance $fill $want) -le 2) `
            "$label - the fill IS wash(panel, $wash), not an accent tint"
        Assert ((Get-Chroma $fill) -le ((Get-Chroma $bg) + 4)) `
            "$label - the row adds no colour of its own (chroma $(Get-Chroma $fill) vs the panel's $(Get-Chroma $bg))"

        # --- the mark ---------------------------------------------------------
        # The bar sits inside the first cell's own padding, so every probe here
        # is left of any glyph: `markBand` is 6 DIP and a cell's text starts at
        # `cell_pad`, which is 8.
        $rowLeft = $client.Left
        $rowMidY = [int](($rowY + $rowBottom) / 2)
        $bar = Get-PixelRgb $shot ($rowLeft + $indicatorX + [int]($indicatorW / 2)) $rowMidY
        Assert ($null -ne $bar) "$label - the indicator bar was sampled"
        if ($null -eq $bar) { return $null }

        $barContrast = Get-Contrast $bar $fill
        Assert ($barContrast -ge 2.9) ("$label - the indicator clears the 3:1 chrome floor against the row " +
            "($([math]::Round($barContrast, 2)):1, $(Format-Rgb $bar))")

        $barChroma = Get-Chroma $bar
        if ($accented) {
            Assert ($barChroma -ge 40) `
                "$label - the mark carries the user's accent ($(Format-Rgb $bar), chroma $barChroma)"
        } else {
            Assert ($barChroma -le 12) `
                "$label - the mark is NEUTRAL while the caret is elsewhere ($(Format-Rgb $bar), chroma $barChroma)"
        }

        # It is a bar: a column of it, ending well short of the row's own edges.
        $tall = 0
        for ($y = $rowY; $y -lt $rowBottom; $y++) {
            $c = Get-PixelRgb $shot ($rowLeft + $indicatorX + [int]($indicatorW / 2)) $y
            if ($c -and (Get-ChannelDistance $c $bar) -le 6) { $tall++ }
        }
        Assert ($tall -gt $indicatorW -and $tall -lt ($rowBottom - $rowY)) `
            "$label - the mark is a bar, not a stripe down the whole row (${indicatorW}x$tall in a $($rowBottom - $rowY) row)"

        # ...and the fill runs on both sides of it, so it is a mark ON the row
        # rather than a recoloured leading column.
        foreach ($dx in @(0, $markBand)) {
            $c = Get-PixelRgb $shot ($rowLeft + $dx) $rowMidY
            Assert ($c -and (Get-ChannelDistance $c $fill) -le 2) `
                "$label - the row's fill runs either side of the mark (x offset $dx, $(if ($c) { Format-Rgb $c } else { 'null' }))"
        }

        # --- the perimeter, which is the reported defect ----------------------
        # Any line across the row that is not the fill is an outline. With no
        # focus rim due, there must be none of them at all - a full-perimeter
        # accent border, which is what was reported, shows up here as the row's
        # first and last lines. Where a rim IS due (the caret row while the table
        # holds the keyboard) the claim narrows to what design system 2.2's list
        # amendment allows: the outline is NEUTRAL ink, never a second accent mark.
        $outlines = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ((Get-ChannelDistance $lines[$i] $fill) -gt 6) { $outlines += , @($i, $lines[$i]) }
        }
        $shown = ($outlines | ForEach-Object { "y+$($_[0]) $(Format-Rgb $_[1])" }) -join ', '
        if ($outlined) {
            Assert ($outlines.Count -ge 2) "$label - the caret rim is drawn on the row ($($outlines.Count) lines: $shown)"
            $accentOutline = @($outlines | Where-Object { (Get-Chroma $_[1]) -gt 12 }).Count
            Assert ($accentOutline -eq 0) `
                "$label - the accent appears ONCE on the row: its outline is neutral ink, not a second mark ($shown)"
            foreach ($o in $outlines) {
                Assert ((Get-ChannelDistance $o[1] $bar) -gt 24) `
                    "$label - no line of the row repeats the mark's colour (y+$($o[0]) $(Format-Rgb $o[1]))"
            }
        } else {
            Assert ($outlines.Count -eq 0) `
                "$label - the row has NO outline: every line of it is the fill ($($outlines.Count) differ$(if ($shown) { ": $shown" }))"
        }

        return @{ Fill = $fill; Bar = $bar; RowBottom = $rowBottom }
    }

    Write-Host ''
    Write-Host 'B. a selected row with the caret elsewhere is unemphasized, and its mark is neutral'
    # Select the row, then put the caret in the filter field: the panel's own
    # definition of "the table does not hold the keyboard", pinned below from the
    # state line and from the row's paint rather than assumed.
    $before = Count-PanelLines
    Send-TestMouse -Window $panel -X ($client.Left + 40) -Y ($rowY + 4) -Button left -Action click | Out-Null
    $st = Wait-PanelState $before
    Assert ($null -ne $st -and $st.Selected -eq 1) "clicking a row selects exactly one (selected=$(if ($st) { $st.Selected } else { 'none' }))"

    $fr2 = Get-TestWindowRect -Window $filterEdit
    Send-TestMouse -Window $panel -Target $filterEdit `
        -X ([int](($fr2.Left + $fr2.Right) / 2)) -Y ([int](($fr2.Top + $fr2.Bottom) / 2)) `
        -Button left -Action click | Out-Null
    Start-Sleep -Milliseconds 400
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $filterEdit) 'the caret is in the filter field: the table does NOT hold the keyboard'

    $unfocused = $null
    $shotB = Get-TestWindowPixels -Window $panel -Sync
    try {
        $unfocused = Measure-Row $shotB 'unfocused' $SELECTION_WASH_UNFOCUSED $false $false
    } finally { Close-TestWindowPixels -Shot $shotB }

    Write-Host ''
    Write-Host 'C/D. driving the table emphasizes the row and spends the accent on the mark alone'
    $before = Count-PanelLines
    Send-TestMouse -Window $panel -X ($client.Left + 40) -Y ($rowY + 4) -Button left -Action click | Out-Null
    $st = Wait-PanelState $before
    Assert ($null -ne $st -and $st.Selected -eq 1) "the row is still the selection (selected=$(if ($st) { $st.Selected } else { 'none' }))"
    Assert ((Get-TestFocusedWindow -Window $panel) -ne $filterEdit) 'the caret left the filter field: the table holds the keyboard'

    $focused = $null
    $shotC = Get-TestWindowPixels -Window $panel -Sync
    try {
        $focused = Measure-Row $shotC 'focused' $SELECTION_WASH_FOCUSED $true $true

        # D. The rim the table draws on its caret row: neutral ink, so the row
        # carries exactly one accent mark. Walked down the row's own column from
        # its top edge - the rim is inset a pixel or two, so it is the first
        # thing on that column that is not the fill (read, never re-derived).
        if ($null -ne $focused) {
            $rim = $null
            $rimY = -1
            $col = $client.Right - (Px 20 $scale)
            for ($y = $rowY; $y -lt ($rowY + (Px 8 $scale)); $y++) {
                $c = Get-PixelRgb $shotC $col $y
                if (-not $c) { continue }
                if ((Get-ChannelDistance $c $focused.Fill) -gt 6) { $rim = $c; $rimY = $y; break }
            }
            Assert ($null -ne $rim) "D the caret rim is drawn on the row (y offset $($rimY - $rowY), $(if ($rim) { Format-Rgb $rim } else { 'nothing but fill' }))"
            if ($null -ne $rim) {
                Assert ((Get-Chroma $rim) -le 12) `
                    "D the rim is NEUTRAL ink, not a second accent mark ($(Format-Rgb $rim), chroma $(Get-Chroma $rim))"
                $rimContrast = Get-Contrast $rim $focused.Fill
                Assert ($rimContrast -ge 3.0) `
                    "D the rim reads against the row it sits on ($([math]::Round($rimContrast, 2)):1)"
            }
        }
    } finally { Close-TestWindowPixels -Shot $shotC }

    # The two states are genuinely two: a fix that collapsed them would pass
    # every assertion above one weight at a time.
    if ($null -ne $unfocused -and $null -ne $focused) {
        Assert ((Get-ChannelDistance $unfocused.Fill $focused.Fill) -gt 2) `
            "the emphasized and unemphasized fills are different colours ($(Format-Rgb $unfocused.Fill) vs $(Format-Rgb $focused.Fill))"
        Assert ((Get-Contrast $focused.Fill $PANEL_BG) -gt (Get-Contrast $unfocused.Fill $PANEL_BG)) `
            'the focused selection is the heavier of the two'
    }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the interactive desktop'
} catch {
    Write-Host "FAIL  harness error: $_" -ForegroundColor Red
    $script:fail++
} finally {
    Stop-RepoProcesses
    Remove-TestDesktop
}

# --- stamp (T783) ----------------------------------------------------------
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard activity-selection -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'activity-selection' -MinPass 20
