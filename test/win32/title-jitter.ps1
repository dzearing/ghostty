# T60 acceptance: an animated leading glyph must not move the title, the tab,
# or anything laid out from either.
#
# THE BUG. An agent that animates its title - Claude Code, which is what runs
# in every pane on this box - cycles one leading glyph on a timer and leaves
# the rest of the string alone ("* Reviewing the parity backlog", where the *
# is one frame of `. + * ~ x`). Those glyphs are not one width. Measured in
# Segoe UI at the user's 125% with GetTextExtentPoint32W: U+00B7 is 4 px and
# U+2733 is 27 px, a 23 px swing several times a second. Everything after the
# glyph was laid out from its advance, so every frame moved two things - the
# title text slid left/right inside its box, and because a tab asks for the
# width its own title needs (T235), the chiclet and the "+" slid with it.
#
# THE FIX (src/apprt/win32/title_spinner.zig). A title that leads with a
# symbol glyph and a space gets that glyph drawn CENTERED IN A FIXED CELL, and
# the rest of the title starts at the cell's right edge - measured the same way
# it is painted, so `preferredWidth` stops tracking the glyph too.
#
# WHAT THIS SCRIPT MEASURES, and why each control is here:
#
#   Section 1 - the WINDOW TITLE in the caption band (a one-tab window is
#     `.standalone`, so the caption paints a title). The title is driven with
#     `+rename --title=`, which is exact and needs no shell interaction at all.
#     The oracle is an INK PROFILE: one character per client column, '1' if any
#     pixel in the band differs from the band background. Two regions are
#     profiled per frame - the cell, and everything right of it.
#
#       * 1a is the control that makes 1b mean anything: the CELL's profile
#         must DIFFER across frames. If it did not, the frames would be
#         rendering identically (a title that never arrived, a window that
#         never repainted) and "the text does not move" would be true of
#         nothing. This is the T240 lesson - a probe that cannot see the
#         trigger cannot score the fix.
#       * 1b is the fix: the profile RIGHT of the cell must be byte-identical
#         across all eight frames.
#       * 1c is the sensitivity control: an ASCII leading character is NOT a
#         spinner (it has a fixed advance, so it never jittered), so it gets no
#         cell and its text starts somewhere else. Its profile must therefore
#         DIFFER from the spinner frames'. A probe that returned the same
#         string for a genuinely shifted title would pass 1b for free.
#
#   Section 2 - the TAB CHICLET. A second tab makes the strip appear; the tab's
#     title comes from the pane's own shell (`chcp 65001` then cmd's `title`
#     builtin, which is SetConsoleTitleW and is forwarded by ConPTY). Tab
#     extents are read off the strip's pixels by lib\ChromeGeometry.ps1.
#
#       * 2a is the fix: the chiclet's left AND right edges must be identical
#         across all eight frames.
#       * 2b is the control: a LONGER title must still widen the tab. Freezing
#         a tab's width outright would pass 2a and break T235.
#       * The retitle control in between is not decoration. The first version
#         of this script drove the title through a mechanism that silently did
#         nothing, so 2a passed on a tab whose title never changed - a green
#         assertion measuring nothing at all. The titles are now read back
#         from `+list` and asserted to differ.
#
# NEGATIVE CONTROLS, both required and both real:
#   * -NegativeControl inverts 1b and 2a (asserts they DO move) and MUST fail.
#   * Source-level: flip T60_NEUTERED in src/apprt/win32/title_spinner.zig to
#     `true`, rebuild `-Dapp-runtime=win32`, re-run. 1b and 2a must fail;
#     1a, 1c and 2b must NOT. That is the run that proves this script scores
#     the fix rather than the harness. (Recorded in docs/design/
#     windows-parity-tasks/T60.md.)
#
# Runs on the background test desktop (test/win32/lib/TestDesktop.ps1). Both
# oracles are GDI-painted CHROME, which is the half of the CAPTURE LIMIT that
# survives PrintWindow off the input desktop - the terminal surface is never
# captured here.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-t60jitter'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 500
}

# The eight frames Claude Code cycles, by codepoint. Written as numbers, never
# as literal characters: this file stays ASCII (a PS5.1 script re-saved by any
# tool loses non-ASCII to the ANSI codepage), and the numbers are what the
# probe hands the app anyway.
#
# Widths measured in Segoe UI at 125% (20 px em), which is why the extremes
# matter: U+00B7 = 4 px, U+2733 = 27 px.
$frames = @(0x00B7, 0x2217, 0x2722, 0x2726, 0x2733, 0x2734, 0x273B, 0x273D)
$suffix = 'Reviewing the parity backlog'

# One column per client x: '1' when any pixel in the band's rows differs from
# the band background. This is what makes "the text did not move" an exact
# claim instead of a plausible one - a one-pixel shift changes the string.
function Get-InkProfile {
    param($Shot, [int]$X0, [int]$X1, [int]$Y0, [int]$Y1, $Bg)
    $sb = New-Object System.Text.StringBuilder
    for ($x = $X0; $x -lt $X1; $x++) {
        $ch = '0'
        for ($y = $Y0; $y -lt $Y1; $y++) {
            $p = $Shot.Bitmap.GetPixel($x, $y)
            if ([Math]::Abs($p.R - $Bg.R) -gt 24 -or [Math]::Abs($p.G - $Bg.G) -gt 24 -or
                [Math]::Abs($p.B - $Bg.B) -gt 24) { $ch = '1'; break }
        }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

# A capture with real content in it. A capture that came back empty satisfies
# "no ink anywhere" for entirely the wrong reason - one false PASS per frame if
# this is skipped (T216). The capture is -Sync (T941): the window paints the
# frame into our DC before the call returns, so an empty one now means the
# chrome is not there yet rather than that the photo was taken too early.
function Get-PaintedShot {
    param([IntPtr]$Window)
    for ($t = 0; $t -lt 20; $t++) {
        $s = Get-TestWindowPixels -Window $Window -Sync
        if ((Get-TestDistinctColors -Shot $s) -ge 8) { return $s }
        Close-TestWindowPixels $s
        Start-Sleep -Milliseconds 150
    }
    return $null
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserts the title and the tab DO move across spinner frames - this run MUST fail'
}

try {
    # Default tab-bar mode (auto), so the first window has ONE tab and no
    # strip - which is what puts the caption band in `.standalone` and gives
    # section 1 a window title to measure. Section 2 adds the second tab.
    # Black background so the strip's chiclet reads unambiguously in pixels.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        '--background=#000000',
        '--session-persistence=false'
    )
    Start-Sleep -Seconds 4
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

    # Own the window size rather than inheriting whatever window_placement
    # remembered from the last GUI script (T267): every width here is a ratio
    # of the tab run.
    Set-TestWindowSize -Window $top -Width 1400 -Height 800 | Out-Null
    Start-Sleep -Milliseconds 1200

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'the window is NOT enumerable on the interactive desktop'

    # One tab, default tab-bar mode: no strip, so the caption band is
    # `.standalone` and paints the window title. Section 2 adds the second tab.
    $m = Get-TestChromeMetrics -Window $top -StripVisible $false
    $scale = $m.Scale

    # The cell, derived exactly as the app derives it: `createTabFont` asks for
    # a 16 DIP character height (truncated to px), and cellWidth is em * 3/2.
    $em = [int][Math]::Truncate(16.0 * $scale)
    $cell = [int][Math]::Truncate($em * 3 / 2)

    # The caption's title box starts one GROUP gap (pad_md) in from the client
    # edge - caption_layout.layout's `title_l`.
    $titleL = $m.PadMd
    $textL = $titleL + $cell
    $textR = [Math]::Min($textL + 320, $m.ClientW - 4)
    # Rows: inside the band, clear of its top and bottom edges.
    $y0 = $m.OffY + 2
    $y1 = $m.OffY + $m.CaptionH - 2

    Write-Host ("chrome: scale=$scale em=$em cell=$cell titleL=$titleL clientW=$($m.ClientW) captionH=$($m.CaptionH)")

    # The window's registered target, so `+rename` can address it. `+list`
    # auto-registers what it finds, and only this instance answers on
    # GHOZTTY_PIPE_SUFFIX.
    $listJson = & $exe +list --json | Out-String
    $list = $listJson | ConvertFrom-Json
    $target = @($list.data.windows)[0].target
    if (-not $target) { Write-Host 'SETUP FAIL: no window target from +list'; exit 1 }

    function Set-WindowTitle([string]$Text) {
        [void](& $exe +rename "--target=$target" "--title=$Text")
        Start-Sleep -Milliseconds 350
    }

    # -----------------------------------------------------------------------
    # Section 1: the window title in the caption band.
    # -----------------------------------------------------------------------
    $cellProfiles = @()
    $textProfiles = @()
    foreach ($cp in $frames) {
        # Built here rather than in the file so the script stays ASCII.
        Set-WindowTitle ("$([char]$cp) $suffix")
        $shot = Get-PaintedShot -Window $top
        if (-not $shot) { Write-Host 'SETUP FAIL: window never painted real content'; exit 1 }
        try {
            # Band background: sampled from the drag region between the title
            # box's left edge and the window edge, which no glyph reaches.
            $bg = $shot.Bitmap.GetPixel($m.OffX + 1, $m.OffY + [int]($m.CaptionH / 2))
            $cellProfiles += (Get-InkProfile -Shot $shot -X0 ($m.OffX + $titleL) -X1 ($m.OffX + $textL) -Y0 $y0 -Y1 $y1 -Bg $bg)
            $textProfiles += (Get-InkProfile -Shot $shot -X0 ($m.OffX + $textL) -X1 ($m.OffX + $textR) -Y0 $y0 -Y1 $y1 -Bg $bg)
        } finally { Close-TestWindowPixels $shot }
    }

    # 1a - the control. Different frames must LOOK different inside the cell,
    # or nothing below is measuring a spinner at all.
    $distinctCells = @($cellProfiles | Select-Object -Unique).Count
    Assert ($distinctCells -ge 3) `
        "control: the spinner frames really do render differently in the cell ($distinctCells distinct of $($frames.Count))"
    # ...and the title is actually on screen, not an empty band.
    $inked = @($textProfiles | Where-Object { $_ -match '1' }).Count
    Assert ($inked -eq $frames.Count) `
        "control: every frame painted title text right of the cell ($inked/$($frames.Count))"

    # 1b - the fix.
    $distinctText = @($textProfiles | Select-Object -Unique).Count
    if ($NegativeControl) {
        Assert ($distinctText -gt 1) `
            "NEGATIVE CONTROL: the title text past the cell moves across frames ($distinctText distinct)"
    } else {
        Assert ($distinctText -eq 1) `
            "the title text past the cell is pixel-identical across all $($frames.Count) spinner frames ($distinctText distinct)"
    }

    # 1c - the sensitivity control. An ASCII lead is not a spinner, gets no
    # cell, and must therefore land somewhere else.
    Set-WindowTitle ("X $suffix")
    $shot = Get-PaintedShot -Window $top
    if (-not $shot) { Write-Host 'SETUP FAIL: window never painted real content'; exit 1 }
    try {
        $bg = $shot.Bitmap.GetPixel($m.OffX + 1, $m.OffY + [int]($m.CaptionH / 2))
        $asciiProfile = Get-InkProfile -Shot $shot -X0 ($m.OffX + $textL) -X1 ($m.OffX + $textR) -Y0 $y0 -Y1 $y1 -Bg $bg
    } finally { Close-TestWindowPixels $shot }
    Assert ($asciiProfile -ne $textProfiles[0]) `
        'control: the probe DOES see a shifted title (an ASCII lead gets no cell and profiles differently)'

    # Clear the pin so the caption/tab titles follow the panes again.
    Set-WindowTitle ''

    # -----------------------------------------------------------------------
    # Section 2: the tab chiclet.
    # -----------------------------------------------------------------------
    $fw = Get-TestFocusedWindow -Window $top
    if ($fw -eq 0) { Write-Host 'SETUP FAIL: no focused surface for ctrl+t'; exit 1 }
    [void](Send-TestKeys -Window $top -Target ([IntPtr]$fw) -Modifiers ctrl -Key T)
    Start-Sleep -Milliseconds 1500

    $listJson = & $exe +list --json | Out-String
    $list = $listJson | ConvertFrom-Json
    $tabs = @(@($list.data.windows)[0].tabs)
    if ($tabs.Count -lt 2) { Write-Host "SETUP FAIL: expected 2 tabs, got $($tabs.Count)"; exit 1 }
    $paneId = $tabs[1].splits.terminal.id
    if (-not $paneId) { Write-Host 'SETUP FAIL: no pane id for the new tab'; exit 1 }

    $ms = Get-TestChromeMetrics -Window $top -StripVisible $true

    # How the tab title is driven, and why it is THIS way. cmd's `title`
    # builtin is SetConsoleTitleW, which ConPTY forwards to us; measured on
    # this box, it is the mechanism that works. Three that do NOT, so nobody
    # re-derives them: an OSC 0 or OSC 2 written by a nested
    # `powershell -Command` (PS 5.1 does not enable VT processing on its
    # console, so the sequence is buffer text, not a title change), the same
    # written to the raw stdout stream, and `$host.UI.RawUI.WindowTitle` from
    # an interactive PS 5.1 pane. All three left the title untouched.
    #
    # `chcp 65001` first so the UTF-8 bytes of the glyph survive the console
    # input codepage, and --keys-file because those bytes are exactly what has
    # to arrive - a positional argument would be re-tokenized.
    $keysFile = Join-Path $env:TEMP 't60-keys.txt'
    function Send-PaneLine([string]$Text) {
        [System.IO.File]::WriteAllBytes($keysFile, [System.Text.Encoding]::UTF8.GetBytes($Text + "`r"))
        [void](& $exe +send-keys "--target=$paneId" "--keys-file=$keysFile")
        Start-Sleep -Milliseconds 900
    }
    function Get-TabTitle {
        $j = (& $exe +list --json | Out-String) | ConvertFrom-Json
        return @(@($j.data.windows)[0].tabs)[1].title
    }

    Send-PaneLine 'chcp 65001'
    Start-Sleep -Milliseconds 600

    $extents = @()
    $seenTitles = @()
    foreach ($cp in $frames) {
        Send-PaneLine ('title ' + [char]$cp + ' ' + $suffix)
        $seenTitles += (Get-TabTitle)
        $t = @(Get-TestTabExtents -Window $top -Metrics $ms)
        if ($t.Count -lt 2) { Write-Host "SETUP FAIL: expected 2 tab extents, got $($t.Count)"; exit 1 }
        $extents += ("{0},{1}" -f $t[1].Left, $t[1].Right)
    }
    Write-Host ("tab extents: " + ($extents -join ' | '))

    # The control that section 2 cannot do without: the first run of this
    # script drove the title through a mechanism that silently did nothing,
    # and "the tab never moved" was true because the tab never changed. The
    # titles must actually differ, and must actually be the spinner frames.
    $distinctTitles = @($seenTitles | Select-Object -Unique).Count
    Assert ($distinctTitles -eq $frames.Count) `
        "control: each frame really did retitle the tab ($distinctTitles distinct of $($frames.Count))"
    Assert ($seenTitles[0] -like "*$suffix") `
        "control: the tab title is the spinner title we set ('$($seenTitles[0])')"

    $distinctTabs = @($extents | Select-Object -Unique).Count
    if ($NegativeControl) {
        Assert ($distinctTabs -gt 1) `
            "NEGATIVE CONTROL: the tab chiclet resizes across spinner frames ($distinctTabs distinct)"
    } else {
        Assert ($distinctTabs -eq 1) `
            "the tab chiclet keeps its exact extent across all $($frames.Count) spinner frames ($distinctTabs distinct)"
    }

    # 2b - the control. A tab still sizes to its own title (T235); the fix
    # freezes the GLYPH's contribution, not the tab's width.
    Send-PaneLine ('title ' + [char]0x2733 + ' ' + $suffix + ' and then a great deal more title than that')
    $t = @(Get-TestTabExtents -Window $top -Metrics $ms)
    $wider = if ($t.Count -ge 2) { $t[1].Right - $t[1].Left } else { 0 }
    $baseW = [int]($extents[0].Split(',')[1]) - [int]($extents[0].Split(',')[0])
    Assert ($wider -gt $baseW) `
        "control: a longer title still widens the tab, so the width is live ($baseW -> $wider px)"

} finally {
    Kill-RepoInstances
    Remove-TestDesktop -Desktop $td
    Stop-TestForegroundWatch
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
