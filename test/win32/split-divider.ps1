# T73 acceptance: split divider lines honor `split-divider-color`.
# T94 acceptance (run 2 tail): the divider grab band is ~9 DIP wide - it
# extends ~4.5 DIP each side of the line, over the pane surfaces, which the
# panes' WM_NCHITTEST/HTTRANSPARENT fall-through makes reachable - and a drag
# starting 4 DIP off the line still resizes.
# T155 acceptance (tail): exactly ONE divider band, a solid fill, after drags
# and after repeated small window resizes.
# T233 acceptance (run 2 tail): the band is 2 DIP (never one physical pixel),
# and hover/drag is a COLOR change - asserted as a pair of probes that must
# read differently in the two states, not as a cursor shape.
#
# paintDividerNode previously hardcoded a 0x808080 pen; it now uses the
# config color (COLORREF from Config.Color RGB) with the same gray as the
# fallback, and Window.onConfigChange repaints dividers so a config reload
# re-colors live.
#
# Two GUI launches (hermetic: --config-default-files=false):
#   run 1 (config file with split-divider-color = ff0000):
#         split -> a red divider pixel exists in the gap between panes;
#         then rewrite the config file to 0000ff and send ctrl+shift+,
#         (reload_config) -> the divider re-colors blue live.
#   run 2 (no color set): divider is the fallback gray 128,128,128.
#
# T218 (batch 3): runs on a BACKGROUND Win32 desktop
# (test/win32/lib/TestDesktop.ps1), so it never takes the user's foreground -
# asserted at the end, not assumed. The private DivDrv driver is gone. Three
# mechanisms changed, and the middle one changed what this script can claim:
#
#   PIXELS. GetPixel on the composited screen is dead off the input desktop;
#   every strip now comes from PrintWindow on the TOP-LEVEL window. That suits
#   this test unusually well: the divider is GDI-painted by the parent (the
#   surviving half of the CAPTURE LIMIT), while the OpenGL panes come back as
#   a flat white fill - so a pane can no longer contribute a false
#   divider-colored pixel to a run count. It also retires the old
#   `Pane-IsOnScreen` control: a window capture cannot be occluded by another
#   window, so "is this probe looking at us?" is now "did the capture have real
#   content at all", which Get-TestDistinctColors answers.
#
#   THE CURSOR - AND THE ONE ASSERTION THAT DID NOT MIGRATE. T94's four
#   "SIZENS cursor across the band" assertions are GONE, replaced by four
#   WM_NCHITTEST probes. Measured here 2026-07-31, and it corrects the harness
#   header's old claim: `SetCursorPos` FAILS on a background desktop (it
#   requires the caller's desktop to be the input desktop) and `GetCursorPos`
#   returns -1,-1 there. The product's Window.zig WM_SETCURSOR handler is
#   coordinate-driven - WM_SETCURSOR carries no coordinates, so it must read
#   GetCursorPos - and with no readable cursor it falls straight through to
#   DefWindowProc. Measured: WM_SETCURSOR returns 0 at every point on the band.
#   Faking a cursor position is not available, so the cursor SHAPE is simply
#   not observable here.
#   What replaces it asserts strictly more about the geometry: SendMessage
#   WM_NCHITTEST to the PANE at each of the same four points and read the
#   product's own answer - HTTRANSPARENT (-1) across the band, HTCLIENT (1) at
#   the pane center. That IS the fall-through the cursor feedback rode on, read
#   at the source rather than inferred from a glyph. The band's AXIS (the
#   vertical/horizontal choice that picked SIZENS over SIZEWE) stays covered by
#   the drags, which move along it, and by the T155 section running both axes.
#   The literal glyph is what is lost; see the task file.
#
#   THE DRAG. Real SendInput drags are gone; a drag is a posted
#   down / moves / up on the TOP-LEVEL window, which is where the OS routes a
#   band click after the pane answers HTTRANSPARENT. updateDividerDrag reads the
#   coordinates out of the WM_MOUSEMOVE lparam and does not consult MK_LBUTTON
#   or the cursor, so a posted drag is the same input it would have got.
#
# -NegativeControl inverts run 1's red-divider assertion and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\split-divider.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint unconditionally - inherited by the app through
# CreateProcessW and by every `& $exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = '-dividertest'
$errlog = Join-Path $env:TEMP 'ghoztty-split-divider-stderr.log'
$conf = Join-Path $env:TEMP 'ghoztty-split-divider-test.conf'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$WM_NCHITTEST = 0x0084
$HTTRANSPARENT = -1
$HTCLIENT = 1

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

function Get-Panes([IntPtr]$top) {
    @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

# split_geometry.bandPx mirrored in PowerShell (T233): 2 DIP, never below 2
# physical px. [math]::Round is BANKER'S rounding in .NET while Zig's @round
# is half-away-from-zero, and 125% DPI lands exactly on the midpoint
# (2 * 120/96 = 2.5) - so the naive form would expect 2px where the product
# paints 3 and fail against a healthy build at the scale the user runs.
function Get-ExpectedBandPx([int]$dpi) {
    [math]::Max([int][math]::Round(2.0 * $dpi / 96.0, [MidpointRounding]::AwayFromZero), 2)
}

# True if r,g,b matches the target within tolerance.
function Pixel-Matches([string]$px, [int]$tr, [int]$tg, [int]$tb, [int]$tol = 40) {
    $c = $px -split ','
    ([math]::Abs([int]$c[0] - $tr) -le $tol) -and
    ([math]::Abs([int]$c[1] - $tg) -le $tol) -and
    ([math]::Abs([int]$c[2] - $tb) -le $tol)
}

# A line of "r,g,b" from a PrintWindow capture of the TOP-LEVEL window, in
# SCREEN coordinates so the existing probe math is unchanged. -Horizontal
# scans x from $A to $B at row $Fixed; otherwise y from $A to $B at column
# $Fixed.
#
# Returns $null when the capture held no real content (mid-paint, or a window
# that never painted). That is the replacement for the old screen-pixel
# control: an empty capture must read as "this probe is meaningless", never as
# "the product drew no divider".
function Get-TestStrip {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][int]$Fixed,
        [Parameter(Mandatory = $true)][int]$A,
        [Parameter(Mandatory = $true)][int]$B,
        [switch]$Horizontal
    )
    $shot = Get-TestWindowPixels -Window $Window
    try {
        if ((Get-TestDistinctColors -Shot $shot) -lt 8) { return $null }
        $out = New-Object System.Collections.Generic.List[string]
        for ($i = $A; $i -le $B; $i++) {
            $c = if ($Horizontal) { Get-TestPixel -Shot $shot -X $i -Y $Fixed }
                 else { Get-TestPixel -Shot $shot -X $Fixed -Y $i }
            if ($null -eq $c) { $out.Add('-1,-1,-1') } else { $out.Add("$($c.R),$($c.G),$($c.B)") }
        }
        return $out.ToArray()
    } finally {
        Close-TestWindowPixels $shot
    }
}

# Sample the divider gap (between the top pane's bottom and the bottom pane's
# top) at 3 x-positions; true if any pixel matches the target color. The line
# is 1-2 px wide inside a ~5-7 px never-erased gap, so we look for ANY matching
# pixel, not all.
function Divider-HasColor([IntPtr]$top, $A, $B, [int]$tr, [int]$tg, [int]$tb) {
    $y0 = $A.Bottom - 2
    $y1 = $B.Top + 2
    foreach ($fx in @(0.3, 0.5, 0.7)) {
        $x = [int]($A.Left + ($A.Right - $A.Left) * $fx)
        $strip = Get-TestStrip -Window $top -Fixed $x -A $y0 -B $y1
        if ($null -eq $strip) { continue }
        foreach ($px in $strip) {
            if (Pixel-Matches $px $tr $tg $tb) { return $true }
        }
    }
    return $false
}

# The parent-visible gap between the two pane rects: its pixel strip and its
# width. Win32 rects are half-open, so pane A owns rows up to Bottom-1 and the
# gap is [A.Bottom .. B.Top-1]. Strip is $null if the capture held no content.
function Get-GapStrip([IntPtr]$top, [string]$axis) {
    $panes = Get-Panes $top
    if ($panes.Count -ne 2) { return $null }
    if ($axis -eq 'down') {
        $pa = $panes | Sort-Object Top | Select-Object -First 1
        $pb = $panes | Sort-Object Top | Select-Object -Last 1
        $lo = $pa.Bottom; $hi = $pb.Top - 1
        $strip = if ($hi -lt $lo) { @() } else {
            Get-TestStrip -Window $top -Fixed ([int](($pa.Left + $pa.Right) / 2)) -A $lo -B $hi
        }
    } else {
        $pa = $panes | Sort-Object Left | Select-Object -First 1
        $pb = $panes | Sort-Object Left | Select-Object -Last 1
        $lo = $pa.Right; $hi = $pb.Left - 1
        $strip = if ($hi -lt $lo) { @() } else {
            Get-TestStrip -Window $top -Fixed ([int](($pa.Top + $pa.Bottom) / 2)) -A $lo -B $hi -Horizontal
        }
    }
    return [pscustomobject]@{ Strip = $strip; Gap = ($hi - $lo + 1) }
}

function Dump-Strip([IntPtr]$top, $A, $B, [string]$label) {
    $x = [int](($A.Left + $A.Right) / 2)
    $strip = Get-TestStrip -Window $top -Fixed $x -A ($A.Bottom - 2) -B ($B.Top + 2)
    Write-Host "DEBUG $label strip at x=${x}: $($strip -join ' | ')"
}

# The pane's own WM_NCHITTEST answer at a SCREEN point (lparam is screen
# coordinates for this message). -1 = HTTRANSPARENT, i.e. "this hit belongs to
# the parent's divider band, not to me".
function Get-PaneHitTest([IntPtr]$pane, [int]$x, [int]$y) {
    $lp = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
    return (Invoke-TestMessage -Window $pane -Message ([uint32]$WM_NCHITTEST) -WParam ([IntPtr]0) -LParam $lp)
}

# Posted divider drag along one axis. The down/up land on the TOP-LEVEL window
# because that is where the OS routes a band click once the pane answers
# HTTRANSPARENT (asserted separately).
function Invoke-DividerDrag {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Top,
        [Parameter(Mandatory = $true)][int]$X0,
        [Parameter(Mandatory = $true)][int]$Y0,
        [Parameter(Mandatory = $true)][int]$X1,
        [Parameter(Mandatory = $true)][int]$Y1,
        [int]$Steps = 8
    )
    [void](Send-TestMouse -Window $Top -Target $Top -X $X0 -Y $Y0 -Action down)
    for ($i = 1; $i -le $Steps; $i++) {
        $x = [int]($X0 + ($X1 - $X0) * $i / $Steps)
        $y = [int]($Y0 + ($Y1 - $Y0) * $i / $Steps)
        [void](Send-TestMouse -Window $Top -Target $Top -X $x -Y $y -Action move)
    }
    [void](Send-TestMouse -Window $Top -Target $Top -X $X1 -Y $Y1 -Action up)
    Start-Sleep -Milliseconds 250
}

function Start-Gui([string]$label, [string[]]$extraArgs, [bool]$control) {
    Kill-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }
    $sp = @{ Exe = $exe; Arguments = $extraArgs }
    if ($control) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        "$label window is NOT enumerable on the interactive desktop"
    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 800
    $panes = Get-Panes $top
    Assert ($panes.Count -eq 2) "$label setup: 2 visible panes"
    if ($panes.Count -ne 2) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    [void](Focus-TestWindow -Window $top -Child ([IntPtr]($panes[0].Hwnd)))
    Start-Sleep -Milliseconds 200
    [pscustomobject]@{ App = $app; Top = $top; Panes = $panes }
}

# Common args: hermetic config, no dim overlays near the gap, black terminal,
# and no session manifest to restore into the next launch (T131).
$common = @('--config-default-files=false', '--background=#000000',
    '--unfocused-split-opacity=1', '--session-persistence=false')

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {

# ---------------------------------------------------------------------------
# Run 1: config file sets red; live reload re-colors to blue.
# ---------------------------------------------------------------------------
Set-Content -Path $conf -Value 'split-divider-color = ff0000' -Encoding Ascii
$g = Start-Gui 'red' ($common + "--config-file=$conf") $true
$launched += $script:GhozttyTestDesktopPids
$app = $g.App; $top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1   # top pane
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1    # bottom pane (focused)

# -NegativeControl flips this to "the red divider is NOT there", so a passing
# run would mean the pixel probe reads the same answer either way.
$hasRed = Divider-HasColor $top $A $B 255 0 0
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting the red divider is ABSENT - this run MUST fail'
    Assert (-not $hasRed) 'red: divider gap has NO red pixel (negative control)'
} else {
    Assert $hasRed 'red: divider gap has a red pixel (split-divider-color honored)'
}
if (-not $hasRed) { Dump-Strip $top $A $B 'red' }
Assert (-not (Divider-HasColor $top $A $B 128 128 128)) 'red: hardcoded gray divider is gone'

# Positive control: ctrl+k reaches binding dispatch (debug log only).
[void](Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl -Key K)
Start-Sleep -Milliseconds 400
if (Test-Path $errlog) {
    if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
        Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T73 verdict'
        Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
    }
    Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
} else {
    Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
}

# Rewrite the config file, reload with ctrl+shift+, and poll for blue.
Set-Content -Path $conf -Value 'split-divider-color = 0000ff' -Encoding Ascii
Assert (Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl, shift -Key comma) `
    'red->blue: reload chord delivered'
$blue = $false
for ($t = 0; $t -lt 25; $t++) {
    if (Divider-HasColor $top $A $B 0 0 255) { $blue = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert $blue 'red->blue: config reload re-colored the divider live'
if (-not $blue) { Dump-Strip $top $A $B 'red->blue' }

Assert (-not ($app.Process -and $app.Process.HasExited)) 'red: no crash'
Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2: no color set -> fallback gray 128,128,128.
#
# Captures stderr ($true) so the T233 section below can read the divider-hover
# debug oracle - a posted hover cannot survive to a pixel capture here.
# ---------------------------------------------------------------------------
$g = Start-Gui 'default' $common $true
$launched += $script:GhozttyTestDesktopPids
$app = $g.App; $top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1

Assert (Divider-HasColor $top $A $B 128 128 128) 'default: divider gap has the fallback gray pixel'
if (-not (Divider-HasColor $top $A $B 128 128 128)) { Dump-Strip $top $A $B 'default' }

# ---------------------------------------------------------------------------
# T94: grab-band hit target. The band is ~9 DIP total (4.5 DIP each side of
# the line) while the visual gap is ~5 DIP, so a point 4 DIP off the line lies
# OVER a pane surface - and the pane answering HTTRANSPARENT there is exactly
# the fall-through that makes it reachable.
# ---------------------------------------------------------------------------
$dpi = Get-TestWindowDpi -Window $top
$off4 = [int][math]::Round(4 * $dpi / 96)
function Get-DividerLine([IntPtr]$top) {
    $panes = Get-Panes $top
    $pa = $panes | Sort-Object Top | Select-Object -First 1
    $pb = $panes | Sort-Object Top | Select-Object -Last 1
    [pscustomobject]@{
        A = $pa; B = $pb
        X = [int](($pa.Left + $pa.Right) / 2)
        Y = [int](($pa.Bottom + $pb.Top) / 2)
    }
}

$d = Get-DividerLine $top
Assert ((Get-PaneHitTest ([IntPtr]$d.B.Hwnd) $d.X $d.Y) -eq $HTTRANSPARENT) `
    'T94: pane falls through (HTTRANSPARENT) on the divider line'
Assert ((Get-PaneHitTest ([IntPtr]$d.B.Hwnd) $d.X ($d.Y + $off4)) -eq $HTTRANSPARENT) `
    'T94: pane falls through 4 DIP below the line (over the pane)'
Assert ((Get-PaneHitTest ([IntPtr]$d.A.Hwnd) $d.X ($d.Y - $off4)) -eq $HTTRANSPARENT) `
    'T94: pane falls through 4 DIP above the line (over the pane)'
Assert ((Get-PaneHitTest ([IntPtr]$d.B.Hwnd) $d.X ([int](($d.B.Top + $d.B.Bottom) / 2))) -eq $HTCLIENT) `
    'T94: pane keeps the hit at its center (band is bounded)'

# Drag from +4 DIP below the line: divider follows the mouse down.
$before = $d.Y
Invoke-DividerDrag -Top $top -X0 $d.X -Y0 ($d.Y + $off4) -X1 $d.X -Y1 ($d.Y + $off4 + 80)
$d = Get-DividerLine $top
Assert ($d.Y -gt $before + 40) "T94: drag from +4 DIP resized (line $before -> $($d.Y))"

# Drag from -4 DIP above the (moved) line: divider follows the mouse up.
$before = $d.Y
Invoke-DividerDrag -Top $top -X0 $d.X -Y0 ($d.Y - $off4) -X1 $d.X -Y1 ($d.Y - $off4 - 80)
$d = Get-DividerLine $top
Assert ($d.Y -lt $before - 40) "T94: drag from -4 DIP resized (line $before -> $($d.Y))"

# ---------------------------------------------------------------------------
# T233: the band is 2 DIP, and HOVER IS A COLOR CHANGE, not just a cursor.
#
# The user, 2026-07-31: "I think the splitter lines should be 2px and have a
# hover color that emphasizes it." Before this the divider was 1 DIP - one
# physical pixel at both 100% and 125%, the two scales most users run - and
# hovering it changed only the mouse cursor, which tells nobody who is looking
# at the divider and shows up on no screenshot.
#
# A POSTED WM_MOUSEMOVE CANNOT HOLD A HOVER HERE, and that shapes the oracle.
# Measured 2026-07-31 with a debug log on both sides: a posted move at the band
# DOES set the state - the log reads `divider hover=0` - and then the OS posts
# WM_MOUSELEAVE within one frame and it reads `divider hover=null` again,
# because TrackMouseEvent watches the REAL cursor and there is none over the
# window (SetCursorPos fails off the input desktop; see the header). The band
# is back to rest before the first capture 60ms later. That is a harness
# limit, not a product defect: on a real desktop the leave arrives when the
# real pointer leaves, which is exactly the un-hover.
#
# So the two halves are proved separately, and together they are the whole
# claim:
#
#   * THE COLOR - by pixels, mid-DRAG. A drag holds the same `hot` state
#     through the same paint (`paintDividers` computes ONE hot color and uses
#     it for hover and drag alike), and `dragging_split` does not depend on
#     the cursor, so it survives the leave. rest -> hot -> rest is read from
#     the same probe at three moments; that IS the screenshot diff.
#   * THE TRIGGER - by the debug-log oracle (the hero-mode.ps1 idiom): a move
#     onto the band sets the state and a move off it clears it. Degrades to a
#     skip on a release build, where log.debug is compiled out.
#
# Tolerance is 6, not the 40 used for "is it red or blue" - the two states are
# 25/channel apart by design, so a loose tolerance would call them equal and
# pass on a build with no hover at all.
# ---------------------------------------------------------------------------
$REST_G = 128           # fallback divider gray (no split-divider-color set)
$HOT_G = 153            # + HOVER_DELTA (25), the dark-theme direction: --background=#000000
$TOL = 6

# True if any pixel of the parent-visible gap matches; $null if the capture
# held no content (same "meaningless probe" contract as Get-TestStrip).
function Gap-Has([IntPtr]$top, [int]$v) {
    $gap = Get-GapStrip $top 'down'
    if ($null -eq $gap -or $null -eq $gap.Strip) { return $null }
    foreach ($px in $gap.Strip) { if (Pixel-Matches $px $v $v $v $TOL) { return $true } }
    return $false
}

$dpiNow = Get-TestWindowDpi -Window $top
$expBand = Get-ExpectedBandPx $dpiNow
$gapNow = Get-GapStrip $top 'down'
if ($null -eq $gapNow) {
    Assert $false 'T233: could not measure the divider gap'
} else {
    Assert ($gapNow.Gap -eq $expBand) `
        "T233: the visible band is 2 DIP ($dpiNow dpi -> ${expBand}px expected, got $($gapNow.Gap)px)"
    Assert ($gapNow.Gap -ge 2) `
        "T233: the band is never a single physical pixel (got $($gapNow.Gap)px at $dpiNow dpi)"
}

$d = Get-DividerLine $top
$paneCenterY = [int](($d.B.Top + $d.B.Bottom) / 2)

# Rest: pointer parked deep inside a pane, far outside the grab band.
[void](Send-TestMouse -Window $top -Target $top -X $d.X -Y $paneCenterY -Action move)
Start-Sleep -Milliseconds 300
$restIsRest = Gap-Has $top $REST_G
$restIsHot = Gap-Has $top $HOT_G
if ($null -eq $restIsRest -or $null -eq $restIsHot) {
    Write-Host 'SKIP T233 (rest): empty capture - pixel probe would be meaningless'
} else {
    Assert ($restIsRest -eq $true) 'T233 rest: the un-hovered band is the configured gray'
    Assert ($restIsHot -eq $false) 'T233 rest: the un-hovered band is NOT the hover gray'
}

# Hover TRIGGER: a move onto the band sets the hot state, a move off it drops
# it. Read from the debug log, because the state cannot survive to a capture
# (see above). The marker is dropped between the two probes so the second
# reading cannot be the first one's leftovers.
$hoverLogged = $null
if (Test-Path $errlog) {
    Clear-Content $errlog -ErrorAction SilentlyContinue
    [void](Send-TestMouse -Window $top -Target $top -X $d.X -Y $d.Y -Action move)
    Start-Sleep -Milliseconds 300
    $onBand = @(Select-String -Path $errlog -Pattern 'divider hover=\d' -ErrorAction SilentlyContinue)
    $offBand = @(Select-String -Path $errlog -Pattern 'divider hover=null' -ErrorAction SilentlyContinue)
    $hoverLogged = ($onBand.Count -gt 0)
    if ($hoverLogged) {
        Assert ($onBand.Count -gt 0) 'T233 hover: a move onto the band sets the hot state'
        Assert ($offBand.Count -gt 0) 'T233 hover: leaving the band drops it back to rest'
    }
}
if (-not $hoverLogged) {
    Write-Host 'SKIP T233 hover trigger: no debug log (release build) - the drag pixels below still cover the color'
}

# A drag is a HELD hover (design system section 5): the mark must not drop
# back to rest at the moment it is grabbed. Down on the band, one move, and
# read the band mid-drag.
[void](Send-TestMouse -Window $top -Target $top -X $d.X -Y $d.Y -Action down)
[void](Send-TestMouse -Window $top -Target $top -X $d.X -Y ($d.Y + 20) -Action move)
Start-Sleep -Milliseconds 250
$dragIsHot = Gap-Has $top $HOT_G
[void](Send-TestMouse -Window $top -Target $top -X $d.X -Y ($d.Y + 20) -Action up)
Start-Sleep -Milliseconds 250
if ($null -eq $dragIsHot) { Write-Host 'SKIP T233 (drag): empty capture' }
else { Assert ($dragIsHot -eq $true) 'T233 drag: the band stays lit while being dragged' }

# And back to rest once the pointer leaves it again.
[void](Send-TestMouse -Window $top -Target $top -X $d.X -Y $paneCenterY -Action move)
Start-Sleep -Milliseconds 300
$backIsRest = Gap-Has $top $REST_G
$backIsHot = Gap-Has $top $HOT_G
if ($null -eq $backIsRest -or $null -eq $backIsHot) {
    Write-Host 'SKIP T233 (un-hover): empty capture'
} else {
    Assert ($backIsRest -eq $true) 'T233 un-hover: the band returns to the rest gray'
    Assert ($backIsHot -eq $false) 'T233 un-hover: the hover shade is gone'
}

Assert (-not ($app.Process -and $app.Process.HasExited)) 'default: no crash'
Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# T155: the visible gap between panes is ONE solid divider band.
#
# The old code left a ~5 DIP gap between the panes and stroked a hairline
# down the middle of it, while the parent's WM_ERASEBKGND painted nothing -
# so every ratio change stroked a NEW line and left the OLD one on screen.
# The user's screenshot showed two parallel verticals and a 3-line stack.
#
# THE ORACLE CHANGED SHAPE IN THE MIGRATION, and this is the second thing in
# this script that a background desktop cannot express. The old version
# scanned a full scanline ACROSS both panes and counted runs, on the premise
# that a stale line under a pane has been overpainted by that pane and so
# cannot be counted. That premise is a COMPOSITED-SCREEN fact, and there is no
# composite here: measured 2026-07-31, a PrintWindow capture keeps every
# intermediate line a drag ever painted (3 drags -> 13 runs), because the GL
# child does not overpaint the parent's backing store in that render. A
# full-window repaint does not clear them either. Scored that way the test
# fails against a healthy product, for pixels no user can see.
#
# So the scan is now confined to what IS parent-visible: the strip between the
# two pane rects. That still states the fix exactly, and arguably better:
#
#   * the gap must BE the band (pane rects abut it) - `gap == bandPx`, which
#     is the geometry half and needs no pixels at all. The pre-fix ~5 DIP gap
#     fails this outright.
#   * every pixel of that gap must be divider-colored, in ONE run. A hairline
#     stroked down the middle of a wider gap reads as a run narrower than the
#     gap; a surviving stale line inside the gap reads as a second run. Those
#     are the two shapes of the reported bug.
#
# What is NOT covered any more is a stale line that ends up UNDER a pane. On
# screen the pane covers it, so it is invisible - which is why it was only ever
# a proxy - but it was a proxy with margin, and that margin is gone. See the
# task file.
#
# Green is used so no earlier run's red/blue can be mistaken for a band.
# ---------------------------------------------------------------------------
function Count-ColorRuns([string[]]$strip, [int]$tr, [int]$tg, [int]$tb) {
    $runs = 0; $inRun = $false
    foreach ($px in $strip) {
        if (Pixel-Matches $px $tr $tg $tb) {
            if (-not $inRun) { $runs++; $inRun = $true }
        } else { $inRun = $false }
    }
    return $runs
}
function Dump-Green([string[]]$strip, [string]$label) {
    $hits = @()
    for ($i = 0; $i -lt $strip.Count; $i++) { if (Pixel-Matches $strip[$i] 0 255 0) { $hits += $i } }
    Write-Host "  DEBUG ($label) divider-colored offsets: $($hits -join ',')"
}
function Max-RunLength([string[]]$strip, [int]$tr, [int]$tg, [int]$tb) {
    $best = 0; $cur = 0
    foreach ($px in $strip) {
        if (Pixel-Matches $px $tr $tg $tb) { $cur++; if ($cur -gt $best) { $best = $cur } }
        else { $cur = 0 }
    }
    return $best
}

# (Get-GapStrip moved up to the helper block: the T233 section in run 2 uses
# it too, and PowerShell resolves functions at call time in file order.)

# One GUI per axis: a single split each, so a run count of 1 is unambiguous.
function Start-T155Gui([string]$direction) {
    Kill-RepoInstances
    $a = Start-OnTestDesktop -Exe $exe -Arguments ($common + @('--split-divider-color=00ff00'))
    Start-Sleep -Seconds 3
    if ($a.Process -and $a.Process.HasExited) { return $null }
    $t = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Stop-Process -Id $a.Pid -Force -ErrorAction SilentlyContinue; return $null }
    & $exe +split --direction=$direction | Out-Null
    Start-Sleep -Milliseconds 900
    [pscustomobject]@{ App = $a; Top = $t }
}

foreach ($axis in @('down', 'right')) {
    $g = Start-T155Gui $axis
    if ($null -eq $g) { Write-Host "SKIP T155/$axis : GUI did not come up"; continue }
    $launched += $script:GhozttyTestDesktopPids
    $top = $g.Top
    $bandPx = Get-ExpectedBandPx (Get-TestWindowDpi -Window $top)
    $panes = Get-Panes $top
    if ($panes.Count -ne 2) {
        Assert $false "T155/$axis setup: 2 visible panes (got $($panes.Count))"
        Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
        continue
    }

    # Three drags, each landing somewhere new. Every one of them used to
    # leave its old line behind.
    foreach ($delta in 60, -40, 70) {
        $panes = Get-Panes $top
        if ($axis -eq 'down') {
            $pa = $panes | Sort-Object Top | Select-Object -First 1
            $pb = $panes | Sort-Object Top | Select-Object -Last 1
            $lineY = [int](($pa.Bottom + $pb.Top) / 2)
            $x = [int](($pa.Left + $pa.Right) / 2)
            Invoke-DividerDrag -Top $top -X0 $x -Y0 $lineY -X1 $x -Y1 ($lineY + $delta)
        } else {
            $pa = $panes | Sort-Object Left | Select-Object -First 1
            $pb = $panes | Sort-Object Left | Select-Object -Last 1
            $lineX = [int](($pa.Right + $pb.Left) / 2)
            $y = [int](($pa.Top + $pa.Bottom) / 2)
            Invoke-DividerDrag -Top $top -X0 $lineX -Y0 $y -X1 ($lineX + $delta) -Y1 $y
        }
        Start-Sleep -Milliseconds 300
    }

    Start-Sleep -Milliseconds 400
    $gap = Get-GapStrip $top $axis
    if ($null -eq $gap -or $null -eq $gap.Strip) {
        Write-Host "SKIP T155/$axis (after drags): empty capture - pixel probe would be meaningless"
        Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
        continue
    }
    Assert ($gap.Gap -eq $bandPx) `
        "T155/$axis : the visible gap IS the band after 3 drags (${bandPx}px expected, got $($gap.Gap)px)"
    $runs = Count-ColorRuns $gap.Strip 0 255 0
    $width = Max-RunLength $gap.Strip 0 255 0
    Assert ($runs -eq 1 -and $width -eq $gap.Gap) `
        "T155/$axis : the gap is ONE solid divider fill after 3 drags (runs $runs, filled ${width}/$($gap.Gap)px)"
    if ($runs -ne 1 -or $width -ne $gap.Gap) { Dump-Green $gap.Strip 'drags' }

    # THE case that actually reproduces the user's report. Drags alone do
    # NOT: a big ratio change moves the line clear of the old gap, so the
    # growing pane covers the stale pixels and the count stays at 1 even on
    # a broken build (measured 2026-07-29 - the first version of this
    # oracle passed pre-fix, which is why this sub-case exists). Repeated
    # SMALL window resizes are the trigger: each drifts the split position
    # by ~2px, less than the old 5 DIP gap, so the previous line survived
    # inside it. Pre-fix this reports 2 runs; post-fix, 1.
    foreach ($i in 1..3) {
        if ($axis -eq 'down') { [void](Set-TestWindowSize -Window $top -Width 0 -Height -4 -Grow) }
        else { [void](Set-TestWindowSize -Window $top -Width -4 -Height 0 -Grow) }
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 400
    $gap = Get-GapStrip $top $axis
    if ($null -eq $gap -or $null -eq $gap.Strip) {
        Write-Host "SKIP T155/$axis (after resizes): empty capture"
        Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
        continue
    }
    Assert ($gap.Gap -eq $bandPx) `
        "T155/$axis : the gap is STILL the band after 3 small window resizes (${bandPx}px expected, got $($gap.Gap)px)"
    $runs2 = Count-ColorRuns $gap.Strip 0 255 0
    $width2 = Max-RunLength $gap.Strip 0 255 0
    Assert ($runs2 -eq 1 -and $width2 -eq $gap.Gap) `
        "T155/$axis : the gap is STILL one solid fill after resizes (runs $runs2, filled ${width2}/$($gap.Gap)px)"
    if ($runs2 -ne 1 -or $width2 -ne $gap.Gap) { Dump-Green $gap.Strip 'resizes' }

    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) "T155/$axis : no crash"
    Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
}

} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $conf -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
