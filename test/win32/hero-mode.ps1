# Hero-mode TRUE-port oracle (T58 design / T59a acceptance; supersedes the
# T19 static-stand-in oracle).
#
# Drives REAL key chords into the debug build and asserts the T58 layout.
# PHASE 1 (2 panes - both tiles fit on-screen): snapshot pipeline oracle:
#   with a busy loop running in the HIDDEN pane, the debug log shows
#   "hero snap committed" lines and the owner-painted carousel region's
#   pixels CHANGE between shots (thumbnails refreshing from hidden-pane
#   renderer captures).
# PHASE 2 (3 panes): layout + interaction:
#   1. ctrl+shift+space: exactly ONE visible pane (the hero) at ~75%
#      width / full height on the left; every OTHER leaf HIDDEN
#      (IsWindowVisible false) and sized EXACTLY like the hero rect (T58:
#      all leaves stay hero-sized so selection swaps need no reflow); the
#      carousel column contains NO child HWNDs (it is owner-painted).
#   2. ctrl+alt+down moves the selection: a different leaf becomes the
#      single visible pane, at the same hero rect.
#   3. Click a carousel tile: selects that leaf (mouse-up inside tile).
#   3b. ctrl+shift+down/up ALSO navigates (T61: swap_split is intercepted
#       in hero mode instead of silently swapping the hidden tree).
#   4. ctrl+shift+space again restores the exact tree geometry.
#   5. Palette path (T57): ctrl+shift+p -> "hero" -> Enter produces the
#      same hero layout.
# PHASE 3 (T59b - interactions & motion):
#   6. Click-swap ANIMATES: mid-slide every hero HWND is hidden (the
#      region owner-paints sliding snapshots); skipped when the OS
#      reduced-motion setting disables client-area animations.
#   7. Hover + wheel reach the carousel (debug-log oracles); with 5 tiles
#      the strip overflows and the wheel offset is nonzero.
#   8. The divider MARK is design-system compliant (T250): bandPx wide (the
#      same 2 DIP as a split divider), painted with the run's
#      `split-divider-color`, and it changes color under the pointer.
#   9. Divider drag narrows the hero (all leaves re-sized to the new hero
#      rect); double-clicking the divider resets the ratio to 0.25.
#
# T218 batch 6: migrated onto the BACKGROUND test desktop
# (test/win32/lib/TestDesktop.ps1), so the run never takes the user's
# foreground - asserted here, not assumed.
#
# WHY THE CAROUSEL PIXEL ORACLE STILL WORKS AND THE PANE ONE DOES NOT. The
# harness's CAPTURE LIMIT is about the OpenGL terminal surface, which
# PrintWindow returns as a flat fill. The carousel is the other half: it has NO
# child HWNDs, HeroCarousel.paint draws it into the PARENT window's DC inside
# BeginPaint/EndPaint, and every thumbnail refresh goes through InvalidateRect
# (Window.zig, WM_APP_HERO_SNAP) - so what the capture reads is a repaint from
# current state rather than whatever was last drawn there. (This used to say
# "unlike a GetDC paint", citing T233. T252 re-measured that: a GetDC paint IS
# visible to PrintWindow(PW_RENDERFULLCONTENT); what it is not is reproducible,
# which is the actual rule - win32-design-system.md 5b.) The thumbnails themselves are
# renderer output: the pane's own renderer thread captures its GL content into
# a DIB (Surface.heroSnap*) and the GUI thread blits it with GDI. So a changing
# carousel is direct evidence that the hidden panes are really rendering.
#
# WHAT T214 DROPPED HERE, AND WHAT BROUGHT IT BACK. The two
# `Get-PaneColorCount` probes that PrintWindow'd a GhozttyTerminal child and
# required >= 8 distinct colors ("hero pane renders content") were dropped
# rather than weakened: that probe reads the flat fill and would score green
# against a pane that renders nothing, exactly the trap the harness header
# warns about. T275 built the fifth route T214 named - the app handing out its
# OWN renderer's pixels through the debug-only `capture-pane` IPC action, which
# is the same readback these very thumbnails come from - so both probes are
# back in phase 1, asserted on the pane's real glass and on the HIDDEN pane
# specifically. The carousel signature stays: it is the same claim measured on
# the GDI side of the boundary, and two independent oracles for hero mode's
# central promise is not one too many.
#
# A positive control (ctrl+k, T55) runs first so an injection failure is
# distinguishable from a hero regression. Only touches ghoztty processes
# running from this repo's zig-out*.
#
# -NegativeControl flips the toggle-off claim to "the tree came back MUTATED",
# which MUST fail: that geometry is only restored intact after the whole phase-2
# chain (toggle on -> nav -> tile click -> ctrl+shift nav -> toggle off) ran,
# and it is also T61's no-tree-mutation oracle.
#
# -ExePath: test a different build. Release builds emit no debug log, so
# log-based assertions auto-skip (geometry is the verdict).
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Always isolated, not just under -ExePath: the fixtures below are built with
# +split/+send-keys, and both ends inherit this (the CLI from this shell, the
# GUI through the harness's CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-herotest'
$errlog = Join-Path $env:TEMP 'ghoztty-hero-mode-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The app's own reduced-motion gate (SPI_GETCLIENTAREAANIMATION): when the
# user disabled client-area animations, hero swaps are instant and the
# mid-slide oracle must be skipped. A user-profile setting, not a desktop
# one, so it reads the same here as in the app.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class HeroAnim {
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint p, out int v, uint winini);
    public static bool Enabled() {
        int v;
        if (!SystemParametersInfoW(0x1042, 0, out v, 0)) return true;
        return v != 0;
    }
}
'@

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# ---- geometry helpers ------------------------------------------------------

# Every GhozttyTerminal child of $top, HIDDEN ONES INCLUDED, in the top
# window's CLIENT coordinates (what the T58 layout claims are written in) plus
# the SCREEN coordinates every posted mouse event needs. The harness returns
# screen rects, so the client origin is subtracted here rather than in each
# caller.
#
# Returned with a unary comma: PowerShell unrolls an array on return, so a
# one-element result would arrive as a scalar whose .Count is $null - and
# `$null -eq 1` is a quiet FAIL, not an error (it cost this migration its
# first run).
function Get-Panes([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    return , @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | ForEach-Object {
        [pscustomobject]@{
            Hwnd = $_.Hwnd; Visible = $_.Visible
            Left = $_.Left - $c.Left; Top = $_.Top - $c.Top
            Right = $_.Right - $c.Left; Bottom = $_.Bottom - $c.Top
            Width = $_.Width; Height = $_.Height
        }
    })
}

function Get-ClientSize([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    return @($c.Width, $c.Height)
}

# Client point of $top -> screen point, for the posted mouse events.
function To-Screen([IntPtr]$top, [int]$x, [int]$y) {
    $c = Get-TestWindowRect -Window $top -Client
    # Parenthesised on purpose: in a PowerShell array literal the comma binds
    # tighter than `+`, so @($a + $x, $b + $y) is $a + ($x, $b) + $y.
    return @(($c.Left + $x), ($c.Top + $y))
}

function Get-Visible($panes) { return , @($panes | Where-Object Visible) }

function Rects-Equal($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    $am = @{}; $a | ForEach-Object { $am[$_.Hwnd] = "$($_.Left),$($_.Top),$($_.Right),$($_.Bottom),$($_.Visible)" }
    foreach ($p in $b) {
        if ($am[$p.Hwnd] -ne "$($p.Left),$($p.Top),$($p.Right),$($p.Bottom),$($p.Visible)") { return $false }
    }
    return $true
}
function Same-Rect($a, $b) {
    return ($a.Left -eq $b.Left) -and ($a.Top -eq $b.Top) -and
           ($a.Right -eq $b.Right) -and ($a.Bottom -eq $b.Bottom)
}

# Assert the T58 hero layout and return @{Hero=<pane>; Ok=<bool>}.
function Assert-HeroLayout($panes, $client, [string]$label) {
    $visible = Get-Visible $panes
    $hidden = @($panes | Where-Object { -not $_.Visible })
    $ok = ($visible.Count -eq 1)
    Assert $ok "$label - exactly one visible pane (got $($visible.Count))"
    if (-not $ok) { return @{ Hero = $null; Ok = $false } }
    $hero = $visible[0]
    $geom = ($hero.Width -ge [int](0.6 * $client[0])) -and
            ($hero.Width -le [int](0.85 * $client[0])) -and
            ($hero.Height -ge [int](0.9 * $client[1])) -and
            ($hero.Left -le 2)
    Assert $geom "$label - hero fills ~75% width / full height on the left (w=$($hero.Width) of $($client[0]))"
    $allHeroSized = $true
    foreach ($p in $hidden) { if (-not (Same-Rect $p $hero)) { $allHeroSized = $false } }
    Assert $allHeroSized "$label - all hidden leaves sized exactly like the hero rect (T58: no reflow on swap)"
    return @{ Hero = $hero; Ok = ($geom -and $allHeroSized) }
}

# ---- input helpers ---------------------------------------------------------

# A chord at a terminal surface, then time for the binding to land. Ghoztty
# defers SetFocus through a posted message (T48), so the settle is what makes
# the caller's sample post-binding.
function Send-HeroChord([IntPtr]$top, [IntPtr]$target, [string[]]$mods, [string]$key, [int]$settleMs = 700) {
    $ok = Send-TestKeys -Window $top -Target $target -Modifiers $mods -Key $key
    Start-Sleep -Milliseconds $settleMs
    return $ok
}

# The single visible pane's HWND (hero mode), or Zero.
function Get-HeroHwnd([IntPtr]$top) {
    $v = Get-Visible (Get-Panes $top)
    if ($v.Count -eq 1) { return [IntPtr]$v[0].Hwnd }
    return [IntPtr]::Zero
}

# ---- capture helpers -------------------------------------------------------

# Sampled pixel signature of the top window's region right of client x
# $xMin - i.e. the carousel column. Screen coordinates are resolved to the
# capture's own window coordinates once, then the grid is read straight off
# the bitmap (a per-pixel Get-TestPixel over this many points is minutes, not
# seconds). Returns @{ Sig = <hash>; Colors = <distinct colors sampled> } so
# the caller can score "the capture held real content" as its own assertion -
# a flat fill must never satisfy a pixel oracle (T216).
function Get-RegionSignature([IntPtr]$top, [int]$xMin) {
    $shot = Get-TestWindowPixels -Window $top
    try {
        $s = To-Screen $top $xMin 0
        $x0 = [int]($s[0] - $shot.Left)
        if ($x0 -lt 0) { $x0 = 0 }
        $sb = New-Object System.Text.StringBuilder
        $seen = @{}
        for ($y = 40; $y -lt $shot.Height - 10; $y += 7) {
            for ($x = $x0; $x -lt $shot.Width - 4; $x += 7) {
                $c = $shot.Bitmap.GetPixel($x, $y)
                [void]$sb.Append($c.ToArgb())
                $seen["$($c.R),$($c.G),$($c.B)"] = 1
            }
        }
        return @{ Sig = $sb.ToString().GetHashCode(); Colors = $seen.Count }
    } finally { Close-TestWindowPixels $shot }
}

# split_geometry.bandPx / hero_math's grab band, mirrored in PowerShell (T250).
# [math]::Round is BANKER'S rounding in .NET while Zig's @round is
# half-away-from-zero, and 125% DPI lands exactly on 2 * 1.25 = 2.5 - so the
# naive form expects 2px where the product paints 3 and fails a healthy build
# at the scale most users run.
function Get-ExpectedMarkPx([int]$dpi) {
    [math]::Max([int][math]::Round(2.0 * $dpi / 96.0, [MidpointRounding]::AwayFromZero), 2)
}
function Get-ExpectedGrabPx([int]$dpi) {
    [math]::Max([int][math]::Round(6.0 * $dpi / 96.0, [MidpointRounding]::AwayFromZero), 2)
}

# A horizontal line of "r,g,b" straight across the hero divider band, read off
# a PrintWindow capture of the TOP-LEVEL window - which is exactly where
# HeroCarousel.paint's output lands (see the header: no child HWNDs, painted
# into the parent DC inside BeginPaint/EndPaint). $hero is a client-coordinate
# pane rect; the strip spans a few px either side of the band so a mark that
# drifted off the band still shows up rather than being cropped out of the
# probe. Returns $null when the capture held no real content, so an empty
# capture reads as "this probe is meaningless" and never as "no divider".
function Get-HeroDividerStrip([IntPtr]$top, $hero, [int]$grab, [int]$pad = 4) {
    $shot = Get-TestWindowPixels -Window $top
    try {
        if ((Get-TestDistinctColors -Shot $shot) -lt 8) { return $null }
        $midY = [int](($hero.Top + $hero.Bottom) / 2)
        $s = To-Screen $top ($hero.Right - $pad) $midY
        $x0 = [int]($s[0] - $shot.Left)
        $y = [int]($s[1] - $shot.Top)
        if ($y -lt 0 -or $y -ge $shot.Height) { return $null }
        $out = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt ($grab + 2 * $pad); $i++) {
            $x = $x0 + $i
            if ($x -lt 0 -or $x -ge $shot.Width) { $out.Add('-1,-1,-1'); continue }
            $c = $shot.Bitmap.GetPixel($x, $y)
            $out.Add("$($c.R),$($c.G),$($c.B)")
        }
        return , $out.ToArray()
    } finally { Close-TestWindowPixels $shot }
}

function Pixel-Matches([string]$px, [int]$tr, [int]$tg, [int]$tb, [int]$tol = 12) {
    $c = $px -split ','
    ([math]::Abs([int]$c[0] - $tr) -le $tol) -and
    ([math]::Abs([int]$c[1] - $tg) -le $tol) -and
    ([math]::Abs([int]$c[2] - $tb) -le $tol)
}

# Longest run of consecutive pixels matching the target, and where it starts.
function Get-ColorRun([string[]]$strip, [int]$tr, [int]$tg, [int]$tb) {
    $best = 0; $bestAt = -1; $run = 0; $at = -1
    for ($i = 0; $i -lt $strip.Count; $i++) {
        if (Pixel-Matches $strip[$i] $tr $tg $tb) {
            if ($run -eq 0) { $at = $i }
            $run++
            if ($run -gt $best) { $best = $run; $bestAt = $at }
        } else { $run = 0 }
    }
    return @{ Length = $best; Start = $bestAt }
}

function Save-WindowShot([IntPtr]$top, [string]$path) {
    $shot = Get-TestWindowPixels -Window $top
    try { $shot.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { Close-TestWindowPixels $shot }
}

# ---------------------------------------------------------------------------

Kill-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {

# --- Setup: fresh debug instance with a 3-pane layout ------------------------
# session-persistence=false: a persisted session survives the force-kills this
# script brackets itself with, and the panes would re-attach LAST run's shells
# (T248).
# split-divider-color is set here for the T250 probe in phase 3: the hero
# divider must honor the SAME config key the split divider next to it does, and
# a distinctive orange is the only way to tell "honored the config" apart from
# "happened to paint a gray". It clears the 3:1 chrome floor against the
# darkened carousel band, so `dividerPaint` paints it verbatim.
$app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
    '--config-default-files=false', '--session-persistence=false',
    '--split-divider-color=c86400')
$gpid = [int]$app.Pid
$launched += $gpid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = Wait-TestWindow -ProcessId $gpid -Class 'GhozttyWindow'
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
# Control the window this script's conditions are ratios OF (T267). Most T58
# layout assertions are ratios of the client size and survive any placement;
# the ABSOLUTE ones underneath do not - the divider drag moves a fixed 150 px
# and then requires the hero to have narrowed by >= 100, and the carousel
# pixel signature samples from y = 40 to Height - 10. On a small or maximized
# window those change meaning.
Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
Start-Sleep -Milliseconds 500
Assert (-not (Test-TestDesktopLeak -ProcessId $gpid)) `
    'GUI is NOT enumerable on the interactive desktop'

# Two panes first: pane A (markers) + herob running a BUSY LOOP so its
# thumbnail keeps changing while the pane is hidden (snapshot oracle runs
# in this 2-pane phase - with only two tiles both are fully on-screen;
# with three, the busy tile can land below the window since the strip
# centers the SELECTED tile, Mac behavior). The 3rd pane is added later
# for the geometry/nav/click phase.
$listJson = & $exe +list --json | ConvertFrom-Json
$win = $listJson.data.windows[0].target
& $exe +send-keys --target=$win "echo HERO_PANE_A_MARKER" Enter | Out-Null
& $exe +split --direction=down --name=herob | Out-Null
Start-Sleep -Milliseconds 800
# Busy output that works in cmd AND PowerShell panes: one line per second.
& $exe +send-keys --target=herob "ping -t 127.0.0.1" Enter | Out-Null
Start-Sleep -Milliseconds 1200

$pair = Get-Panes $top
$client = Get-ClientSize $top
Assert ($pair.Count -eq 2) "setup: 2 panes exist (got $($pair.Count))"
$leaf0 = ($pair | Sort-Object Top, Left | Select-Object -First 1)
$leaf0Hwnd = [IntPtr]$leaf0.Hwnd

# --- Positive control: ctrl+k reaches binding dispatch (T55/T47-proven) ------
$haveLog = (Test-Path $errlog)
$r = Send-HeroChord $top $leaf0Hwnd @('ctrl') 'K' 400
if (-not $r) { Write-Host 'ABORT: control chord not sent'; exit 1 }
if ($haveLog) {
    if (-not (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -Quiet)) {
        Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a hero verdict'
        exit 1
    }
    Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
} else {
    Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
}

# --- Phase 1 (2 panes): snapshot pipeline oracle ------------------------------
$r = Send-HeroChord $top $leaf0Hwnd @('ctrl', 'shift') 'Space' 900
Assert $r 'hero toggle chord delivered'
Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash after hero toggle'
if ($haveLog) {
    Assert ((Select-String -Path $errlog -Pattern 'toggle_hero_mode' -Quiet)) 'toggle_hero_mode binding dispatched (log)'
}
$hero1 = Get-Panes $top
$res1 = Assert-HeroLayout $hero1 $client 'hero on (2 panes)'
$big1 = $res1.Hero
if ($null -eq $big1) { Write-Host 'ABORT: no hero pane'; exit 1 }

if ($haveLog) {
    $snapDeadline = [DateTime]::Now.AddSeconds(5)
    $snapSeen = $false
    while (-not $snapSeen -and [DateTime]::Now -lt $snapDeadline) {
        $snapSeen = (Select-String -Path $errlog -Pattern 'hero snap committed' -Quiet)
        if (-not $snapSeen) { Start-Sleep -Milliseconds 300 }
    }
    Assert $snapSeen 'renderer committed hero snapshots (debug log)'
}
# The busy ping in HIDDEN pane "herob" adds a line every ~1s; with two
# tiles both are fully on-screen, so the carousel signature must change
# within a few refresh cycles.
$sigX = $big1.Right + 10
$sig1 = Get-RegionSignature $top $sigX
Assert ($sig1.Colors -ge 4) "carousel capture holds real content ($($sig1.Colors) distinct colors, floor 4)"
$sigChanged = $false
for ($t = 0; $t -lt 5 -and -not $sigChanged; $t++) {
    Start-Sleep -Milliseconds 1500
    $sig2 = Get-RegionSignature $top $sigX
    if ($sig1.Sig -ne $sig2.Sig) { $sigChanged = $true }
}
Assert $sigChanged 'carousel thumbnails visibly update while a busy TUI runs in a hidden pane'
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-snap.png')

# The two `Get-PaneColorCount` probes T214 dropped, RESTORED (T275) - now
# against the pane's own pixels rather than a PrintWindow flat fill. The claim
# is the one hero mode is built on: a pane keeps rendering while it is HIDDEN,
# which is why its carousel thumbnail is worth looking at.
$heroShot = Get-TestPaneCapture -Target $win
Assert ($null -ne $heroShot -and (Get-TestPaneColorCount -Shot $heroShot) -ge 8) `
    "hero pane renders content ($(if ($heroShot) { "$(Get-TestPaneColorCount -Shot $heroShot) distinct colors" } else { Get-LastPaneCaptureError }))"
if ($heroShot) { Close-TestPaneCapture $heroShot }

$hiddenShot = Get-TestPaneCapture -Target 'herob'
Assert ($null -ne $hiddenShot -and (Get-TestPaneColorCount -Shot $hiddenShot) -ge 8) `
    "HIDDEN pane renders content ($(if ($hiddenShot) { "$(Get-TestPaneColorCount -Shot $hiddenShot) distinct colors" } else { Get-LastPaneCaptureError }))"
if ($hiddenShot) { Close-TestPaneCapture $hiddenShot }

# Toggle off and add the third pane for the geometry/nav/click phase.
$r = Send-HeroChord $top ([IntPtr]$big1.Hwnd) @('ctrl', 'shift') 'Space'
Assert $r 'phase-1 un-toggle delivered'
& $exe +split --direction=down --name=heroc | Out-Null
Start-Sleep -Milliseconds 800
& $exe +send-keys --target=heroc "echo HERO_PANE_C_MARKER" Enter | Out-Null
Start-Sleep -Milliseconds 800

$tree = Get-Panes $top
Assert ($tree.Count -eq 3) "setup: 3 panes exist (got $($tree.Count))"
Assert ((Get-Visible $tree).Count -eq 3) 'setup: all 3 panes visible in tree layout'
if ($tree.Count -ne 3) { Write-Host 'ABORT: 3-pane fixture not built'; exit 1 }

# --- Phase 2 (3 panes): layout, nav, click, restore ---------------------------
# Focus + toggle from leaf 0 again (the previous hero).
$r = Send-HeroChord $top $leaf0Hwnd @('ctrl', 'shift') 'Space' 900
Assert $r 'hero re-toggle chord delivered'
$hero = Get-Panes $top
Assert ($hero.Count -eq 3) "hero: still 3 panes (got $($hero.Count))"
$res = Assert-HeroLayout $hero $client 'hero on (3 panes)'
$big = $res.Hero
if ($null -eq $big) { Write-Host 'ABORT: no hero pane'; exit 1 }
Assert ($big.Hwnd -eq $leaf0.Hwnd) 'hero seeds from the focused pane (leaf 0 is the hero)'
$ratio = ($client[0] - $big.Right) / [double]$client[0]
Assert ([Math]::Abs($ratio - 0.25) -lt 0.06) ("carousel column is ~25% of client width (got {0:P1})" -f $ratio)

# The carousel column owns no child HWNDs - it is owner-painted (T58). Every
# leaf sits in the hero rect, so nothing may extend into the column.
$inColumn = @($hero | Where-Object { $_.Right -gt ($big.Right + 4) })
Assert ($inColumn.Count -eq 0) "carousel column contains no child HWNDs (got $($inColumn.Count))"

# --- Navigate: ctrl+alt+down/up moves the hero selection ---------------------
# The carousel strip is ordered by TREE ITERATION ORDER, and prev/next
# clamp at the ends (Mac parity) - the focused pane is NOT necessarily
# first in that order, so pressing "down" from the last tile is a correct
# no-op (this burned a session on 2026-07-16: heroSelect logged
# `req=3 clamped=2 cur=2`). Try down first, then up.
foreach ($k in 'Down', 'Up') {
    $r = Send-HeroChord $top ([IntPtr]$big.Hwnd) @('ctrl', 'alt') $k
    if ($k -eq 'Down') { Assert $r 'hero nav chord delivered' }
    $cand = Get-Visible (Get-Panes $top)
    if ($cand.Count -eq 1 -and $cand[0].Hwnd -ne $big.Hwnd) { break }
}
$hero2 = Get-Panes $top
$res2 = Assert-HeroLayout $hero2 $client 'hero nav'
$big2 = $res2.Hero
Assert (($null -ne $big2) -and ($big2.Hwnd -ne $big.Hwnd)) 'ctrl+alt+down/up moved the hero (visible pane changed)'

# --- Click a carousel tile selects it (mouse-up inside the tile) -------------
# Tile geometry mirror of hero_math.zig: carousel column right of the
# divider; thumb w = 88% of column, h = w/AR capped at 70% of column
# height; selected tile centered. Clicking one tile-step ABOVE the center
# selects the previous leaf.
if ($null -ne $big2) {
    $carouselLeft = $big2.Right + 8
    $carouselW = $client[0] - $carouselLeft
    $carouselH = $client[1] - $big2.Top
    $ar = $big2.Width / [double]$big2.Height
    $thumbW = [int](0.88 * $carouselW)
    $thumbH = [int]($thumbW / $ar)
    if ($thumbH -gt [int](0.7 * $carouselH)) { $thumbH = [int](0.7 * $carouselH) }
    $cx = $carouselLeft + [int]($carouselW / 2)
    $cy = $big2.Top + [int]($carouselH / 2) - ($thumbH + 8)
    $s = To-Screen $top $cx $cy
    # Posted at the TOP-LEVEL window: the carousel has no child HWND of its
    # own, so that is the window a real click there would be routed to.
    [void](Send-TestMouse -Window $top -Target $top -X $s[0] -Y $s[1])
    Start-Sleep -Milliseconds 700
    $vis3 = Get-Visible (Get-Panes $top)
    Assert (($vis3.Count -eq 1) -and ($vis3[0].Hwnd -ne $big2.Hwnd)) 'clicking a carousel tile swaps it into the hero'
}

# --- Navigate: ctrl+shift+down/up ALSO moves the selection (T61) --------------
# ctrl+shift+arrows is bound to swap_split; in hero mode that used to
# spatially SWAP panes in the hidden tree (user report 2026-07-16: the
# selection chased the swapped pane to a surprise tile, and toggle-off
# restored a mutated layout). Hero now intercepts it as prev/next
# navigation. The toggle-off "geometry restored exactly" assertion below
# doubles as the no-tree-mutation oracle: Rects-Equal is per-HWND, so a
# real swap surviving these chords would fail it.
$visCS = Get-Visible (Get-Panes $top)
if ($visCS.Count -eq 1) {
    $bigCS = $visCS[0]
    $movedCS = $false
    foreach ($k in 'Down', 'Up') {
        $r = Send-HeroChord $top ([IntPtr]$bigCS.Hwnd) @('ctrl', 'shift') $k
        if ($k -eq 'Down') { Assert $r 'ctrl+shift nav chord delivered' }
        $cand = Get-Visible (Get-Panes $top)
        if ($cand.Count -eq 1 -and $cand[0].Hwnd -ne $bigCS.Hwnd) { $movedCS = $true; break }
    }
    Assert $movedCS 'ctrl+shift+down/up moves the hero selection (swap_split intercepted, T61)'
} else {
    Assert $false "ctrl+shift nav precondition: exactly one visible pane (got $($visCS.Count))"
}

# --- Toggle hero mode off: exact tree geometry restored -----------------------
$curHero = Get-HeroHwnd $top
if ($curHero -eq [IntPtr]::Zero) { $curHero = $leaf0Hwnd }
$r = Send-HeroChord $top $curHero @('ctrl', 'shift') 'Space'
Assert $r 'hero un-toggle chord delivered'
Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash after hero un-toggle'
$after = Get-Panes $top
Assert ((Get-Visible $after).Count -eq 3) 'all 3 panes visible again after toggle-off'
$restored = Rects-Equal $tree $after
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: the toggle-off is expected to return a MUTATED tree - this run MUST fail'
    Assert (-not $restored) 'tree geometry restored exactly after toggle-off'
} else {
    Assert $restored 'tree geometry restored exactly after toggle-off'
}

# --- Palette path: ctrl+shift+p, type "hero", Enter toggles hero mode --------
# The old script wrapped this in a SKIP branch for a lost foreground grab;
# posted input cannot abort, so the section always runs now (T218 batch 1).
$treeNow = Get-Panes $top
$r = Send-HeroChord $top $leaf0Hwnd @('ctrl', 'shift') 'P' 400
Assert $r 'palette chord delivered'
$popup = [IntPtr]::Zero
for ($t = 0; $t -lt 50 -and $popup -eq [IntPtr]::Zero; $t++) {
    Start-Sleep -Milliseconds 100
    $popup = Get-TestWindow -ProcessId $gpid -Class 'GhozttyTerminal'
}
Assert ($popup -ne [IntPtr]::Zero) 'palette popup opened via ctrl+shift+p'
if ($popup -ne [IntPtr]::Zero) {
    $palEdit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    Assert ($palEdit -ne [IntPtr]::Zero) 'palette search edit found'
    if ($palEdit -ne [IntPtr]::Zero) {
        # A standard EDIT needs WM_CHAR, which nothing generates for a posted
        # key - Send-TestControlText is the harness path for that.
        [void](Send-TestControlText -Control $palEdit -Text 'hero')
        Start-Sleep -Milliseconds 250
        [void](Send-TestControlKey -Control $palEdit -Key Enter)
        Start-Sleep -Milliseconds 900
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash after palette hero toggle'
        $heroP = Get-Panes $top
        $resP = Assert-HeroLayout $heroP $client 'palette hero'
        # Restore via the keybind for symmetric teardown.
        if ($null -ne $resP.Hero) {
            [void](Send-HeroChord $top ([IntPtr]$resP.Hero.Hwnd) @('ctrl', 'shift') 'Space')
            $afterP = Get-Panes $top
            Assert (Rects-Equal $treeNow $afterP) 'tree geometry restored after palette round-trip'
        }
    }
}

# --- Phase 3 (T59b): interactions & motion ------------------------------------
# Wheel scroll, divider drag + double-click reset, hover chrome, and the
# selection slide (mid-slide every hero HWND is hidden while the region
# owner-paints sliding snapshots). Posted mouse messages are deterministic:
# the WndProc branches only read message coords.
$r = Send-HeroChord $top $leaf0Hwnd @('ctrl', 'shift') 'Space' 1300
Assert $r 'phase-3 hero toggle delivered'
$hero4 = Get-Panes $top
$res4 = Assert-HeroLayout $hero4 $client 'phase-3 hero on'
$big4 = $res4.Hero

if ($null -ne $big4) {
    # Shared tile geometry (mirror of hero_math.zig, as in the click test).
    $carouselLeft = $big4.Right + 8
    $carouselW = $client[0] - $carouselLeft
    $carouselH = $client[1] - $big4.Top
    $ar = $big4.Width / [double]$big4.Height
    $thumbW = [int](0.88 * $carouselW)
    $thumbH = [int]($thumbW / $ar)
    if ($thumbH -gt [int](0.7 * $carouselH)) { $thumbH = [int](0.7 * $carouselH) }
    $ccx = $carouselLeft + [int]($carouselW / 2)
    $ccy = $big4.Top + [int]($carouselH / 2)
    $ccs = To-Screen $top $ccx $ccy

    # (a) Animated click-swap: poll for the mid-slide state (0 visible
    # panes) right after the selecting mouse-up. Selection is clamped at
    # the strip ends, so try one tile below center, then one above.
    if ([HeroAnim]::Enabled()) {
        $midSlideSeen = $false
        $swapped = $false
        foreach ($step in 1, -1) {
            $cy = $ccy + $step * ($thumbH + 8)
            $s = To-Screen $top $ccx $cy
            [void](Send-TestMouse -Window $top -Target $top -X $s[0] -Y $s[1] -HoldMs 10)
            for ($t = 0; $t -lt 12; $t++) {
                Start-Sleep -Milliseconds 30
                $mid = Get-Visible (Get-Panes $top)
                if ($mid.Count -eq 0) { $midSlideSeen = $true }
            }
            Start-Sleep -Milliseconds 500
            $now = Get-Visible (Get-Panes $top)
            if ($now.Count -eq 1 -and $now[0].Hwnd -ne $big4.Hwnd) { $swapped = $true; break }
        }
        Assert $midSlideSeen 'selection slide: mid-slide state seen (all hero HWNDs hidden, region owner-painted)'
        Assert $swapped 'selection slide: click-swap completed (new hero visible after the slide)'
    } else {
        Write-Host 'SKIP  slide oracle: OS client-area animations disabled (reduced motion)'
        $script:skipped++
    }

    # (b) Hover chrome: a posted WM_MOUSEMOVE over the carousel sets the
    # hovered tile (debug-log oracle; hover repaint is visual-only).
    [void](Send-TestMouse -Window $top -Target $top -X $ccs[0] -Y $ccs[1] -Action move)
    Start-Sleep -Milliseconds 250
    if ($haveLog) {
        Assert ((Select-String -Path $errlog -Pattern 'hero hover tile=' -Quiet)) 'hover: carousel tile hover tracked (log)'
    }

    # (c) Wheel over the carousel is consumed by the strip (3 tiles fit ->
    # scroll clamps to 0 but the path logs). The harness packs WM_MOUSEWHEEL's
    # lparam in SCREEN coordinates, which is what that message carries.
    [void](Send-TestMouse -Window $top -Target $top -X $ccs[0] -Y $ccs[1] -Action wheel -Delta -120)
    Start-Sleep -Milliseconds 250
    if ($haveLog) {
        Assert ((Select-String -Path $errlog -Pattern 'hero wheel scroll=' -Quiet)) 'wheel: carousel consumed the wheel (log)'
    }

    # (d) With 5 tiles the strip always overflows -> wheel scroll is
    # nonzero. Splitting while hero is active must keep the hero layout.
    & $exe +split --direction=down --name=herod | Out-Null
    Start-Sleep -Milliseconds 500
    & $exe +split --direction=down --name=heroe | Out-Null
    Start-Sleep -Milliseconds 800
    $five = Get-Panes $top
    Assert ($five.Count -eq 5) "phase-3 setup: 5 panes exist (got $($five.Count))"
    $res5 = Assert-HeroLayout $five $client 'hero layout holds after splits while active'
    $big5 = $res5.Hero
    if ($null -ne $big5 -and $haveLog) {
        [void](Send-TestMouse -Window $top -Target $top -X $ccs[0] -Y $ccs[1] -Action wheel -Delta -120)
        Start-Sleep -Milliseconds 250
        $scrollLines = @(Select-String -Path $errlog -Pattern 'hero wheel scroll=(-?\d+)')
        $lastScroll = if ($scrollLines.Count -gt 0) { [int]$scrollLines[-1].Matches[0].Groups[1].Value } else { 0 }
        Assert ($lastScroll -ne 0) "wheel: overflowing strip scrolled (offset $lastScroll)"
    }

    # (e0) The divider MARK itself (T250), read off a PrintWindow capture:
    #   * it is `split_geometry.bandPx` wide - the same 2 DIP the split divider
    #     next to it is. It used to compute its own 1 DIP, which rounds to a
    #     single physical pixel at 100% and 125%, so one window showed two
    #     dividers of two widths.
    #   * it is the user's `split-divider-color` (the orange this run launched
    #     with), not a color derived from the band. A themed divider was themed
    #     on one side of the window and not the other.
    #   * it CHANGES under the pointer, so the grab affordance still reads.
    # Runs before (e), which moves the divider.
    if ($null -ne $big5) {
        $dpi = Get-TestWindowDpi -Window $top
        $markPx = Get-ExpectedMarkPx $dpi
        $grabPx = Get-ExpectedGrabPx $dpi
        $midY0 = [int](($big5.Top + $big5.Bottom) / 2)

        # Pointer parked well inside the hero pane: divider at REST.
        $sAway = To-Screen $top ([int]($big5.Left + $big5.Width / 2)) $midY0
        [void](Send-TestMouse -Window $top -Target $top -X $sAway[0] -Y $sAway[1] -Action move)
        Start-Sleep -Milliseconds 250
        $rest = Get-HeroDividerStrip $top $big5 $grabPx
        Assert ($null -ne $rest) 'divider mark: capture held real content'
        if ($null -ne $rest) {
            $run = Get-ColorRun $rest 200 100 0
            Assert ($run.Length -gt 0) `
                "divider mark: painted with split-divider-color c86400 (strip: $($rest -join ' '))"
            Assert ($run.Length -eq $markPx) `
                "divider mark: ${markPx}px wide at ${dpi} dpi (got $($run.Length))"

            # HOT: the same strip while the band is GRABBED. Hero mode paints
            # the accent here (Mac parity, HeroModeView.swift:117), and a drag
            # is a held hover so the two states paint identically.
            #
            # Probed mid-DRAG rather than mid-hover on purpose: a POSTED
            # WM_MOUSEMOVE cannot hold a hover on the background test desktop -
            # TrackMouseEvent watches the real cursor, so WM_MOUSELEAVE wipes
            # the state within a frame (T233's lesson). A posted button-down
            # holds. The divider has not moved yet (no move event between the
            # down and the capture), so the mark is still at $run.Start.
            $sOn = To-Screen $top ([int]($big5.Right + $grabPx / 2)) $midY0
            [void](Send-TestMouse -Window $top -Target $top -X $sOn[0] -Y $sOn[1] -Action move)
            Start-Sleep -Milliseconds 150
            if ($haveLog) {
                $hv = @(Select-String -Path $errlog -Pattern 'hero divider hover=true')
                Assert ($hv.Count -gt 0) 'divider hover: the pointer lit the divider (log)'
            }
            [void](Send-TestMouse -Window $top -Target $top -X $sOn[0] -Y $sOn[1] -Action down)
            Start-Sleep -Milliseconds 300
            $hot = Get-HeroDividerStrip $top $big5 $grabPx
            [void](Send-TestMouse -Window $top -Target $top -X $sOn[0] -Y $sOn[1] -Action up)
            Start-Sleep -Milliseconds 300
            if ($null -eq $hot) {
                Assert $false 'divider grabbed: capture held real content'
            } else {
                $stillRest = $false
                for ($i = $run.Start; $i -lt ($run.Start + $run.Length); $i++) {
                    if (Pixel-Matches $hot[$i] 200 100 0) { $stillRest = $true }
                }
                Assert (-not $stillRest) `
                    "divider grabbed: the mark changed color (hot strip: $($hot -join ' '))"
            }
            # Back to rest, so (e)'s drag starts from the state it expects.
            [void](Send-TestMouse -Window $top -Target $top -X $sAway[0] -Y $sAway[1] -Action move)
            Start-Sleep -Milliseconds 150
        }
    }

    # (e) Divider drag: press in the divider band, drag 150px left, release.
    # The per-tab ratio grows and every leaf lands on the new hero rect.
    # heroUpdateDividerDrag reads the WM_MOUSEMOVE lparam only - no MK_LBUTTON,
    # no cursor - so a posted down / moves / up is the same input a real drag
    # delivers, and the two moves straddle the 80ms leaf-resize throttle.
    if ($null -ne $big5) {
        $midY = [int](($big5.Top + $big5.Bottom) / 2)
        $divX = $big5.Right + 3
        $dragX = $divX - 150
        $sDown = To-Screen $top $divX $midY
        $sMove = To-Screen $top $dragX $midY
        [void](Send-TestMouse -Window $top -Target $top -X $sDown[0] -Y $sDown[1] -Action down)
        Start-Sleep -Milliseconds 60
        [void](Send-TestMouse -Window $top -Target $top -X $sMove[0] -Y $sMove[1] -Action move)
        Start-Sleep -Milliseconds 150
        [void](Send-TestMouse -Window $top -Target $top -X $sMove[0] -Y $sMove[1] -Action move)
        Start-Sleep -Milliseconds 120
        [void](Send-TestMouse -Window $top -Target $top -X $sMove[0] -Y $sMove[1] -Action up)
        Start-Sleep -Milliseconds 500
        $dragged = Get-Panes $top
        $visD = Get-Visible $dragged
        Assert ($visD.Count -eq 1) 'divider drag: still exactly one visible pane'
        if ($visD.Count -eq 1) {
            $heroD = $visD[0]
            Assert ($heroD.Width -le ($big5.Width - 100)) "divider drag: hero narrowed (was $($big5.Width), now $($heroD.Width))"
            $hiddenD = @($dragged | Where-Object { -not $_.Visible })
            $allSized = ($hiddenD.Count -gt 0) -and -not ($hiddenD | Where-Object { -not (Same-Rect $_ $heroD) })
            Assert $allSized 'divider drag: all hidden leaves re-sized to the new hero rect'

            # (f) Double-click the (moved) divider: ratio resets to the
            # default 0.25 -> the standard hero layout assertions hold again.
            # GhozttyWindow IS CS_DBLCLKS, so the harness posts the real
            # down/up/DBLCLK/up the OS would deliver here.
            $sDbl = To-Screen $top ($heroD.Right + 3) $midY
            [void](Send-TestMouse -Window $top -Target $top -X $sDbl[0] -Y $sDbl[1] -Action doubleclick)
            Start-Sleep -Milliseconds 500
            $reset = Get-Panes $top
            $resR = Assert-HeroLayout $reset $client 'divider double-click resets the ratio'
        }
    }

    $artifacts = Join-Path $PSScriptRoot 'artifacts'
    New-Item -ItemType Directory -Force $artifacts | Out-Null
    Save-WindowShot $top (Join-Path $artifacts 'hero-mode-t59b.png')
}

} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live list: this runs AFTER Remove-TestDesktop
    # has emptied that one, and comparing against an empty set is an assertion
    # that passes because it checked nothing.
    $launched = @(@($launched) + @(Get-TestLaunchedPids) | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
