# T150 acceptance: a runtime background change is accessibility-safe.
#
# The T67 script (window-color.ps1) proves the BACKGROUND reaches the glass.
# This one proves the colors DERIVED from it do -- which is a different
# claim and needs a different oracle, because none of it is visible in
# `+list --json`: the derived foreground, the regenerated 256-color palette,
# and the renderer's draw-time contrast floor all only exist as pixels.
#
# Oracle: `lib/paint-blocks.ps1` fills the pane with three bands, one per
# content class, and the probe reads back the color the renderer actually
# chose. Measured against the known background, every band must clear its
# floor from docs/design/win32-design-system.md 2.3.
#
#   band 1  default foreground     -> >= 4.5:1  (text floor)
#   band 2  256-color index 250    -> >= 3.0:1  (only a palette 16-255
#                                    regeneration can move it; stock
#                                    #bcbcbc on a light bg is ~1.2:1)
#   band 3  truecolor 230,230,230  -> >= 2.7:1  (no palette reaches it;
#                                    only the renderer minimum-contrast
#                                    pass can, at a nominal 3.0)
#
# Bands 1-2 are FULL BLOCK cells, which paint the whole cell. Band 3 is
# TEXT on purpose: `renderer/cell.zig:noMinContrast` exempts blocks and
# every other graphics element from the contrast pass, so a block band
# there would read back its raw color and call a working renderer broken.
#
# Plus the mid-grey regression: on #777777 the foreground must be BLACK
# (4.76:1). Rec.601 lightness calls that background "dark" and picks white,
# which measures 4.42:1 -- under the floor, and the exact hole T150 closes.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$paint = Join-Path $PSScriptRoot 'lib\paint-blocks.ps1'

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class ContrastDrv {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    // The single visible GhozttyTerminal child of a window, as
    // "left,top,right,bottom" (these panes are never split here).
    public static string Pane(IntPtr top) {
        string found = null;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                found = r.left + "," + r.top + "," + r.right + "," + r.bottom;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Composited screen pixel as "r,g,b".
    public static string ScreenPixel(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        uint c = GetPixel(dc, x, y); // COLORREF 0x00BBGGRR
        ReleaseDC(IntPtr.Zero, dc);
        return (c & 0xFF) + "," + ((c >> 8) & 0xFF) + "," + ((c >> 16) & 0xFF);
    }
}
'@

# Kill the repo's app AND its agent. The agent is not optional here: it
# outlives the app by design, so a session named `ccl` from an earlier run
# is still alive, and `+new-window --target=ccl` is idempotent -- it FOCUSES
# that stale pane instead of running the fixture in a new one. The probe
# then reads last run's pixels and every assertion passes without the build
# under test having drawn anything.
function Kill-RepoInstances {
    foreach ($name in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
}

# --- WCAG contrast, the same math the Zig side asserts on ----------------
function Wcag-Chan([double]$c) {
    if ($c -le 0.04045) { return $c / 12.92 }
    return [math]::Pow(($c + 0.055) / 1.055, 2.4)
}
function Wcag-Lum([int]$r, [int]$g, [int]$b) {
    return 0.2126 * (Wcag-Chan ($r / 255.0)) +
           0.7152 * (Wcag-Chan ($g / 255.0)) +
           0.0722 * (Wcag-Chan ($b / 255.0))
}
function Wcag-Ratio([string]$px, [string]$hex) {
    $p = $px -split ','
    $l1 = Wcag-Lum ([int]$p[0]) ([int]$p[1]) ([int]$p[2])
    $l2 = Wcag-Lum ([Convert]::ToInt32($hex.Substring(1, 2), 16)) `
                   ([Convert]::ToInt32($hex.Substring(3, 2), 16)) `
                   ([Convert]::ToInt32($hex.Substring(5, 2), 16))
    $hi = [math]::Max($l1, $l2); $lo = [math]::Min($l1, $l2)
    return ($hi + 0.05) / ($lo + 0.05)
}

# The window object registered under $target, or $null.
function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    foreach ($w in ($json | ConvertFrom-Json).data.windows) {
        if ($w.target -eq $target) { return $w }
    }
    return $null
}

# Open a window running the fixture. Returns its HWND, or $null.
function New-PaintedWindow([string]$target, [string]$hex, [string]$step) {
    Remove-Item $step -ErrorAction SilentlyContinue
    & $exe +new-window --target=$target --color=$hex `
        -e powershell -NoProfile -ExecutionPolicy Bypass -File $paint -Out $step | Out-Null

    for ($t = 0; $t -lt 60; $t++) {
        Start-Sleep -Milliseconds 500
        $w = Get-Win $target
        if (-not $w) { continue }
        $hwnd = [IntPtr][int64]$w.id
        if ([ContrastDrv]::Pane($hwnd)) { return $hwnd }
    }
    return $null
}

# Block until the fixture reports it has painted $name, then return the
# foreground color it drew. Deleting the step file releases the fixture into
# the next step, so this must be called once per step, in order.
#
# The probe samples a PATCH rather than one pixel and keeps the sample
# furthest from the background: the truecolor step is antialiased text,
# where a single coordinate can land between strokes and report the
# background as the answer. On the solid block steps every sample is the
# same color, so the patch scan is a no-op.
function Read-Step([IntPtr]$hwnd, [string]$name, [string]$step, [string]$hex) {
    $ready = $false
    for ($t = 0; $t -lt 120; $t++) {
        if ((Test-Path $step) -and (Get-Content $step -Raw).Trim() -eq $name) { $ready = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) { return $null }

    # The fixture reports after writing, but the PIXELS land a frame later.
    Start-Sleep -Milliseconds 700

    $c = [ContrastDrv]::Pane($hwnd) -split ','
    $left = [int]$c[0]; $top = [int]$c[1]; $right = [int]$c[2]; $bottom = [int]$c[3]
    $x0 = [int](($left + $right) / 2)
    $y0 = [int](($top + $bottom) / 2)

    $best = $null; $bestRatio = -1
    for ($dy = 0; $dy -lt 24; $dy++) {
        for ($dx = 0; $dx -lt 24; $dx++) {
            $px = [ContrastDrv]::ScreenPixel(($x0 + $dx), ($y0 + $dy))
            $r = Wcag-Ratio $px $hex
            if ($r -gt $bestRatio) { $bestRatio = $r; $best = $px }
        }
    }

    Remove-Item $step -ErrorAction SilentlyContinue
    return $best
}

Kill-RepoInstances

# Run-unique so a leftover file from an earlier run can never be mistaken
# for this run's fixture reporting in.
$step1 = Join-Path $env:TEMP "ghoztty-t150-$PID-step1.txt"
$step2 = Join-Path $env:TEMP "ghoztty-t150-$PID-step2.txt"

# Persistence off for the same reason the agent gets killed above: this
# test is about what the renderer draws right now, and a restored pane
# brings back a previous run's screen.
$proc = Start-Process $exe -ArgumentList '--background=#101014', '--session-persistence=off' -PassThru
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

# --- 1. light background: every content class stays readable --------------
$LIGHT = '#f0f0f0'
$h1 = New-PaintedWindow 'ccl' $LIGHT $step1
Assert ($null -ne $h1) 'light bg: painted window came up'

if ($h1) {
    $px = Read-Step $h1 'foreground' $step1 $LIGHT
    Assert ($null -ne $px) 'light bg: fixture painted the foreground step'
    if ($px) {
        $r = Wcag-Ratio $px $LIGHT
        Assert ($r -ge 4.5) "light bg: default foreground clears the 4.5:1 text floor (got $([math]::Round($r,2)):1 at $px)"
    }

    $px = Read-Step $h1 'palette256' $step1 $LIGHT
    Assert ($null -ne $px) 'light bg: fixture painted the 256-color step'
    if ($px) {
        $r = Wcag-Ratio $px $LIGHT
        Assert ($r -ge 3.0) "light bg: 256-color index 250 is regenerated for the new bg (got $([math]::Round($r,2)):1 at $px)"
        # Stock index 250 is #bcbcbc; if the ramp were untouched this probe
        # would read it back almost exactly.
        $stock = Wcag-Ratio '188,188,188' $LIGHT
        Assert ($r -gt $stock + 1.0) "light bg: index 250 actually moved off the stock ramp (stock $([math]::Round($stock,2)):1)"
    }

    $px = Read-Step $h1 'truecolor' $step1 $LIGHT
    Assert ($null -ne $px) 'light bg: fixture painted the truecolor step'
    if ($px) {
        $r = Wcag-Ratio $px $LIGHT
        Assert ($r -ge 2.7) "light bg: truecolor is lifted by the renderer contrast floor (got $([math]::Round($r,2)):1 at $px)"
    }

    & $exe +close --target=ccl | Out-Null
    Start-Sleep -Milliseconds 800
}

# --- 2. mid-grey background: the foreground takes the better side ---------
# #777777 is where Rec.601 lightness and WCAG contrast disagree.
$GREY = '#777777'
$h2 = New-PaintedWindow 'ccg' $GREY $step2
Assert ($null -ne $h2) 'mid-grey bg: painted window came up'

if ($h2) {
    $px = Read-Step $h2 'foreground' $step2 $GREY
    Assert ($null -ne $px) 'mid-grey bg: fixture painted the foreground step'
    if ($px) {
        $p = $px -split ','
        $r = Wcag-Ratio $px $GREY
        Assert ($r -ge 4.5) "mid-grey bg: foreground clears the 4.5:1 text floor (got $([math]::Round($r,2)):1 at $px)"
        Assert ([int]$p[0] -lt 128 -and [int]$p[1] -lt 128 -and [int]$p[2] -lt 128) `
            "mid-grey bg: foreground is the dark side, not the Rec.601 white (got $px)"
    }

    & $exe +close --target=ccg | Out-Null
    Start-Sleep -Milliseconds 500
}

# --- 3. app survived ------------------------------------------------------
Assert (-not $proc.HasExited) 'GUI process alive after all scenarios'
$json = (& $exe +list --json 2>$null | Out-String).Trim()
Assert ($json -match '"success":true') '+list still responds'

Kill-RepoInstances
Remove-Item $step1, $step2 -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
