# T397 acceptance: a VIEWER pane gets a real carousel tile in hero mode.
#
# The bug this closes. `HeroCarousel.geometry` counts every leaf, so a viewer
# always occupied a tile slot and was always selectable - but the paint loop
# narrowed through `PaneView.surface()` and skipped anything that was not a
# terminal. The slot was therefore painted with NOTHING: a hole in the strip
# where a tile should be, which is neither participation nor exclusion. Mac
# settled the same question the other way it once had ("every pane
# participates: terminals and viewers alike", HeroModeView.swift), so win32
# participates too and this script is the oracle for it.
#
# Two claims, deliberately separable, because they can fail independently:
#
#   A. THE HOLE. Every tile - the viewer's included - is PAINTED: its border
#      ring exists (a light gray stroke that only `paintTile` draws) and its
#      interior is not the carousel band's backdrop. This holds even when a
#      pane has produced no picture yet, which is the state every pane is in
#      for the first frames of its life.
#   B. THE PICTURE. The viewer tile shows the PAGE: several distinct colors
#      inside the tile, and the debug log carries a `kind=viewer` snapshot
#      commit. That is the `ICoreWebView2::CapturePreview` -> GDI+ decode
#      path end to end, on a pane whose host window is HIDDEN (hero mode
#      hides every non-selected leaf while keeping the controller visible).
#
# Plus C: arrow navigation lands on the viewer coherently - ctrl+alt+down
# makes the VIEWER the single visible pane at the hero rect, which is what
# "selectable" has to mean now that the tile is real.
#
# Oracles are PrintWindow reads of the TOP window, which is the one capture
# route that works for the carousel: it has no child HWNDs of its own and
# `HeroCarousel.paint` draws into whatever DC the window is handed, so it is
# reached by the capture (hero-mode.ps1's header has the full argument). Since
# T941 that is the SYNCHRONOUS capture: the window repaints the carousel into
# the harness's DC on demand, rather than the harness reading a DWM copy. Tile rects are computed here as a mirror of
# hero_math.zig, the same way hero-mode.ps1's click step does.
#
# -NegativeControl inverts claim A to "the viewer tile is bare band backdrop",
# which MUST fail on a fixed build - that is the pre-T397 behavior.
#
# Runs on the background test desktop. Only touches ghoztty processes running
# from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = '-heroviewtest'
$errlog = Join-Path $env:TEMP 'ghoztty-hero-viewer-tile-stderr.log'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# Every leaf of the active tab, both kinds, in the top window's CLIENT
# coordinates. `Get-Panes` in hero-mode.ps1 only enumerates GhozttyTerminal,
# which is exactly the blind spot this script exists to cover.
#
# Unary comma on the return: PowerShell unrolls an array on return, so a
# one-element result would arrive as a scalar whose .Count is $null.
function Get-Leaves([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    $all = @()
    foreach ($cls in @('GhozttyTerminal', 'GhozttyViewer')) {
        $all += @(Get-TestChildWindows -Window $top -Class $cls | ForEach-Object {
            [pscustomobject]@{
                Hwnd = $_.Hwnd; Kind = $cls; Visible = $_.Visible
                Left = $_.Left - $c.Left; Top = $_.Top - $c.Top
                Right = $_.Right - $c.Left; Bottom = $_.Bottom - $c.Top
                Width = $_.Width; Height = $_.Height
            }
        })
    }
    return , @($all)
}

function Get-ClientSize([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    return @($c.Width, $c.Height)
}

# Tile rects around the SELECTED tile, mirroring hero_math.zig (splitRects ->
# tileLayout -> stripTop -> tileRect) at scale 1.0. Client coordinates.
#
# Indexed by OFFSET from the selection, not by leaf index, and deliberately so.
# The strip is built from `SplitTree.iterator()`, which walks the node ARRAY,
# while `+list --json` walks the tree structurally — the two orders disagree
# for a `--direction=down` split, and a test that assumed either one would be
# asserting the wrong tile. What the selection-relative form pins is the thing
# this task is actually about: the selected tile is centered, and its
# neighbour slot is a painted tile rather than a hole.
function Get-TileRects($hero, $client, [int]$fromOffset, [int]$toOffset) {
    $bandW = 6
    $carLeft = $hero.Right + $bandW
    $carW = $client[0] - $carLeft
    $carTop = $hero.Top
    $carH = $client[1] - $carTop
    $ar = $hero.Width / [double]$hero.Height
    $tw = 0.88 * $carW
    $th = $tw / $ar
    if ($th -gt (0.70 * $carH)) {
        $th = 0.70 * $carH
        $tw = $th * $ar
        if ($tw -gt (0.88 * $carW)) { $tw = 0.88 * $carW; $th = $tw / $ar }
    }
    $tw = [int][Math]::Round($tw); $th = [int][Math]::Round($th)
    $gap = 8
    $mid = $carTop + [int][Math]::Truncate($carH / 2)
    # The selected tile is centered vertically; every other slot is a whole
    # tile + gap away from it.
    $selTop = $mid - [int][Math]::Truncate($th / 2)
    $x = $carLeft + [int][Math]::Truncate(($carW - $tw) / 2)
    $rects = @{}
    for ($off = $fromOffset; $off -le $toOffset; $off++) {
        $y = $selTop + $off * ($th + $gap)
        $rects[$off] = [pscustomobject]@{
            Left = $x; Top = $y; Right = $x + $tw; Bottom = $y + $th
        }
    }
    return $rects
}

# Sample a tile's pixels off one window capture. Returns the distinct color
# count INSIDE the tile plus the brightest pixel found on its border ring -
# the border is a 110,110,110 stroke that only `paintTile` draws, so it is
# what tells a painted tile from a hole in the band.
function Measure-Tile($shot, [IntPtr]$top, $tile) {
    $c = Get-TestWindowRect -Window $top -Client
    # Client -> capture-bitmap coordinates.
    $ox = $c.Left - $shot.Left
    $oy = $c.Top - $shot.Top
    $seen = @{}
    $inset = 3
    for ($y = $tile.Top + $inset; $y -lt $tile.Bottom - $inset; $y += 5) {
        for ($x = $tile.Left + $inset; $x -lt $tile.Right - $inset; $x += 5) {
            $px = $x + $ox; $py = $y + $oy
            if ($px -lt 0 -or $py -lt 0 -or $px -ge $shot.Width -or $py -ge $shot.Height) { continue }
            $col = $shot.Bitmap.GetPixel($px, $py)
            $seen["$($col.R),$($col.G),$($col.B)"] = 1
        }
    }
    # Border ring: a few rows down each vertical edge, scanned +-2px so a
    # rounding disagreement with hero_math costs nothing.
    $bright = 0
    $ys = @()
    for ($y = $tile.Top + 10; $y -lt $tile.Bottom - 10; $y += 9) { $ys += $y }
    foreach ($y in $ys) {
        # Parenthesised on purpose: in a PowerShell array literal the comma
        # binds tighter than `-`/`+`, so `@($a - 1, $a)` is `$a - (1, $a)`.
        foreach ($x in @(($tile.Left - 1), ($tile.Left), ($tile.Left + 1), ($tile.Right - 2), ($tile.Right - 1), ($tile.Right))) {
            $px = $x + $ox; $py = $y + $oy
            if ($px -lt 0 -or $py -lt 0 -or $px -ge $shot.Width -or $py -ge $shot.Height) { continue }
            $col = $shot.Bitmap.GetPixel($px, $py)
            if ($col.R -gt $bright) { $bright = $col.R }
        }
    }
    return @{ Colors = $seen.Count; BorderMax = $bright }
}

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

# The viewed document. Real markdown so the pane takes the file-mode path with
# zero network, and enough contrast that a captured thumbnail is obviously not
# a flat fill.
$md = Join-Path $env:TEMP 'ghoztty-hero-viewer-tile.md'
Set-Content -Path $md -Encoding ascii -Value @'
# Hero tile fixture

Body text for the thumbnail, long enough that a scaled-down capture still
carries several distinct greys rather than one flat fill.

| column | value |
|---|---|
| alpha | 1 |
| beta | 2 |

- first bullet
- second bullet
- third bullet
'@

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "the viewer tile is bare band backdrop" - this run MUST fail'
    }

    $sp = @{ Exe = $exe; Arguments = @('--config-default-files=false', '--session-persistence=false', '--background=#101014') }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'GUI is NOT enumerable on the interactive desktop'

    & $exe +split --direction=down "--view=$md" | Out-Null
    Start-Sleep -Seconds 3
    $leaves = Get-Leaves $top
    $terms = @($leaves | Where-Object { $_.Kind -eq 'GhozttyTerminal' })
    $views = @($leaves | Where-Object { $_.Kind -eq 'GhozttyViewer' })
    Assert ($terms.Count -eq 1 -and $views.Count -eq 1) `
        "setup: one terminal + one viewer leaf (got $($terms.Count)/$($views.Count))"
    if ($terms.Count -ne 1 -or $views.Count -ne 1) {
        Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
    }
    $termH = [IntPtr]$terms[0].Hwnd
    $viewH = [IntPtr]$views[0].Hwnd

    $haveLog = (Test-Path $errlog)
    # Positive control: a chord posted at the terminal reaches binding
    # dispatch. Without this a hero verdict cannot be told from dead input.
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl -Key K
    if (-not $r) { Write-Host 'ABORT: control chord not sent'; Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T397 verdict'
            Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # --- Enter hero mode (the terminal is focused, so it is the hero) --------
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl, shift -Key Space
    Assert $r 'hero toggle chord delivered'
    Start-Sleep -Milliseconds 1200
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash after hero toggle'

    $client = Get-ClientSize $top
    $leaves = Get-Leaves $top
    $visible = @($leaves | Where-Object Visible)
    Assert ($visible.Count -eq 1) "hero on: exactly one visible leaf (got $($visible.Count))"
    if ($visible.Count -ne 1) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    $hero = $visible[0]
    Assert ($hero.Kind -eq 'GhozttyTerminal') 'hero on: the focused TERMINAL is the hero pane'
    Assert (($hero.Width -ge [int](0.6 * $client[0])) -and ($hero.Left -le 2)) `
        "hero on: hero fills ~75% width on the left (w=$($hero.Width) of $($client[0]))"
    # T58: every leaf is hero-sized, viewers included, so a selection swap
    # needs no reflow. This is also what makes the tile aspect ratio right.
    $hidden = @($leaves | Where-Object { -not $_.Visible })
    $allHeroSized = $true
    foreach ($p in $hidden) {
        if ($p.Left -ne $hero.Left -or $p.Top -ne $hero.Top -or
            $p.Right -ne $hero.Right -or $p.Bottom -ne $hero.Bottom) { $allHeroSized = $false }
    }
    Assert $allHeroSized 'hero on: the hidden VIEWER leaf is sized exactly like the hero rect'

    # Give the capture chain time: the browser process encodes a full-page PNG
    # and the GUI thread decodes it, and the first request only goes out on the
    # 150ms heartbeat after hero mode engaged.
    Start-Sleep -Seconds 3

    # --- Claim A: every tile is painted -------------------------------------
    $tiles = Get-TileRects $hero $client -1 1
    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        $mSel = Measure-Tile $shot $top $tiles[0]
        $mUp = Measure-Tile $shot $top $tiles[-1]
        $mDown = Measure-Tile $shot $top $tiles[1]
        $shot.Bitmap.Save((Join-Path $env:TEMP 'ghoztty-hero-viewer-tile.png'),
            [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { Close-TestWindowPixels -Shot $shot }

    Write-Host ("      selected tile (terminal): colors=$($mSel.Colors) borderMax=$($mSel.BorderMax)")
    Write-Host ("      slot above:               colors=$($mUp.Colors) borderMax=$($mUp.BorderMax)")
    Write-Host ("      slot below:               colors=$($mDown.Colors) borderMax=$($mDown.BorderMax)")

    # The band backdrop here is background * 0.7 = 11,11,14, and the tile
    # placeholder is 16,16,16 - both far below 60. Any pixel above that on the
    # ring is a border stroke, and a border stroke means paintTile ran.
    Assert ($mSel.BorderMax -ge 60) "terminal tile is painted (border stroke found, max R=$($mSel.BorderMax))"

    # Exactly one neighbour slot is occupied - the viewer's - and which side it
    # is on is the strip's iteration order, which this script does not pin.
    $upPainted = ($mUp.BorderMax -ge 60)
    $downPainted = ($mDown.BorderMax -ge 60)
    if ($NegativeControl) {
        Assert (-not ($upPainted -or $downPainted)) `
            'NEGATIVE: the viewer slot is bare band backdrop (no border stroke)'
    } else {
        Assert ($upPainted -xor $downPainted) `
            "viewer tile is painted, not a hole (above=$($mUp.BorderMax) below=$($mDown.BorderMax), exactly one must be a tile)"
    }
    $mView = if ($upPainted) { $mUp } else { $mDown }
    $viewerOffset = if ($upPainted) { -1 } else { 1 }

    # --- Claim B: the viewer tile shows the page ----------------------------
    Assert ($mSel.Colors -ge 4) "terminal tile carries real content ($($mSel.Colors) distinct colors, floor 4)"
    Assert ($mView.Colors -ge 4) "viewer tile carries the PAGE, not just a placeholder ($($mView.Colors) distinct colors, floor 4)"
    if ($haveLog) {
        Assert ((Select-String -Path $errlog -Pattern 'hero snap committed .*kind=viewer' -Quiet)) `
            'CapturePreview -> GDI+ decode committed a viewer thumbnail (debug log)'
    }

    # --- Claim C: the viewer is selectable and lands coherently -------------
    # Toward the viewer's slot, whichever side of the selection it sits on.
    $navKey = if ($viewerOffset -lt 0) { 'Up' } else { 'Down' }
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl, alt -Key $navKey
    Assert $r "ctrl+alt+$navKey delivered (toward the viewer's slot)"
    Start-Sleep -Milliseconds 1500
    $leaves = Get-Leaves $top
    $visible = @($leaves | Where-Object Visible)
    Assert ($visible.Count -eq 1) "after nav: exactly one visible leaf (got $($visible.Count))"
    if ($visible.Count -eq 1) {
        Assert ($visible[0].Kind -eq 'GhozttyViewer') 'after nav: the VIEWER is now the hero pane'
        Assert (($visible[0].Left -eq $hero.Left) -and ($visible[0].Right -eq $hero.Right) -and
                ($visible[0].Top -eq $hero.Top) -and ($visible[0].Bottom -eq $hero.Bottom)) `
            'after nav: the viewer occupies the same hero rect the terminal did'
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash after selecting the viewer'

    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
} finally {
    Stop-RepoInstances
    if ($td) { Remove-TestDesktop -Desktop $td }
    Remove-Item $md -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) checks)"; exit 0 }
Write-Host "$($script:fail) FAILURE(S) of $($script:pass + $script:fail) checks" -ForegroundColor Red
exit 1
