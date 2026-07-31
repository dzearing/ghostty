# T202 acceptance: the tab strip's geometry, shape and selection idiom.
#
# The strip used to hand the LAST tab all the remaining width, so a single tab
# spanned the whole window - which flung the close button to the far edge,
# jammed the "+" against the tab, and stretched the selected-tab accent into a
# full-width blue rule under the strip. That rule is gone: a tab is now its
# equal share of the strip clamped to [60, 200] DIP, the selected tab is a
# rounded-top chiclet filled with the CONTENT background (WinUI TabView's
# selection cue - no underline), the "+" travels with the last tab and the "="
# menu button stays pinned right, with a real gap between the groups.
# Measured target: docs/design/win32-tab-strip.md. Geometry: tab_strip_layout.zig.
#
# One hermetic GUI launch (--config-default-files=false, black background,
# --window-show-tab-bar=always so a SINGLE tab still shows the strip - the
# configuration the user screenshotted):
#   1. Client origin + bar height from GetClientRect/ClientToScreen vs the
#      pane child's rect -> DPI scale -> every DIP constant (self-relative, so
#      this holds at any DPI; the pane-banner.ps1 section 6g rule).
#   2. A scanline near the BOTTOM of the strip (below the title baseline) is
#      pure content-black inside the selected chiclet and bar-gray outside it,
#      so one row of pixels yields the selected tab's exact extent.
#   3. That extent is the oracle for tab COUNT too: the selected chiclet's
#      left edge is strip_pad + (index * tab_w), so a click that creates a tab
#      moves it right by exactly one tab width, and a click that creates
#      nothing leaves it put.
#
# Captured with PrintWindow(PW_RENDERFULLCONTENT) rather than a screen grab so
# occlusion and the mouse cursor cannot contaminate the pixels; the cursor is
# still parked off the strip so no tab paints its hover fill.
#
# NEGATIVE CONTROL (mandatory, project standard): flip T202_NEUTERED in
# src/apprt/win32/tab_strip_layout.zig to `true`, rebuild
# `-Dapp-runtime=win32`, re-run. The single-tab-width, width-clamp and
# last-tab->"+" gap assertions must fail; the accent-rule and click/hit-test
# assertions must not.
#
# DPI-aware (PER_MONITOR_AWARE_V2). Only touches ghoztty processes running
# from this repo's zig-out.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-tabstriptest'
}

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class StripDrv {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() { SetProcessDpiAwarenessContext((IntPtr)(-4)); }

    public static IntPtr FindTop(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Visible GhozttyTerminal children: "left,top,right,bottom".
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                lines.Add(r.left + "," + r.top + "," + r.right + "," + r.bottom);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    // "clientScreenX,clientScreenY,clientW,clientH,windowLeft,windowTop"
    public static string Client(IntPtr h) {
        RECT c; GetClientRect(h, out c);
        POINT p; p.x = 0; p.y = 0; ClientToScreen(h, ref p);
        RECT w; GetWindowRect(h, out w);
        return p.x + "," + p.y + "," + (c.right - c.left) + "," + (c.bottom - c.top) + "," + w.left + "," + w.top;
    }

    // Occlusion-proof window capture. Coordinates are WINDOW-relative.
    public static Bitmap Shot(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        var bmp = new Bitmap(Math.Max(r.right - r.left, 1), Math.Max(r.bottom - r.top, 1));
        using (var g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            PrintWindow(h, hdc, 2); // PW_RENDERFULLCONTENT
            g.ReleaseHdc(hdc);
        }
        return bmp;
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1]; i[0].type = 1; i[0].ki.wVk = vk; i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab (the kb-actions.ps1 recipe).
    public static bool GrabForeground(IntPtr top) {
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int a = 0; a < 5 && !fg; a++) {
            IntPtr curFg = GetForegroundWindow(); uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            Key(0x12, false); Key(0x12, true);
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + a * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    public static string CtrlT(IntPtr top) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            if (GetForegroundWindow() != top) return "NOT FOREGROUND";
            Key(0x11, false); Thread.Sleep(20);
            Key(0x54, false); Thread.Sleep(20); Key(0x54, true); Thread.Sleep(20);
            Key(0x11, true); Thread.Sleep(120);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    public static void LClick(IntPtr top, int x, int y) {
        GrabForeground(top);
        SetCursorPos(x, y); Thread.Sleep(140);
        mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); Thread.Sleep(60);
        mouse_event(0x0004, 0, 0, 0, IntPtr.Zero); Thread.Sleep(250);
    }

    public static void Park(int x, int y) { SetCursorPos(x, y); Thread.Sleep(200); }
}
'@

[StripDrv]::BeDpiAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# ---------------------------------------------------------------------------
# Launch. Black background so "content background" is unmistakable in pixels:
# the selected chiclet is (0,0,0) and the strip around it is (20,20,20).
# ---------------------------------------------------------------------------
Kill-RepoInstances
$args = @(
    '--config-default-files=false',
    '--background=#000000',
    '--window-show-tab-bar=always',
    '--session-persistence=false'
)
$proc = Start-Process -FilePath $exe -PassThru -ArgumentList $args
Start-Sleep -Seconds 4
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [StripDrv]::FindTop([uint32]$proc.Id)
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

$c = ([StripDrv]::Client($top)) -split ','
$clientX = [int]$c[0]; $clientY = [int]$c[1]; $clientW = [int]$c[2]
$winLeft = [int]$c[4]; $winTop = [int]$c[5]
# Window-relative client origin, which is what PrintWindow's bitmap uses.
$offX = $clientX - $winLeft
$offY = $clientY - $winTop

$panes = @([StripDrv]::Panes($top))
if ($panes.Count -ne 1) { Write-Host "SETUP FAIL: expected 1 visible pane, got $($panes.Count)"; Stop-Process -Id $proc.Id -Force; exit 1 }
$barH = ([int](($panes[0] -split ',')[1])) - $clientY
Assert ($barH -gt 0) "positive control: the tab bar is visible with a single tab (barH=$barH)"
if ($barH -le 0) { Stop-Process -Id $proc.Id -Force; exit 1 }

# Every constant is derived from the measured bar height, so this holds at any
# DPI (bar_h is 32 DIP by definition - docs/design/win32-tab-strip.md).
$scale   = $barH / 32.0
$maxTabW = [int][math]::Round(200 * $scale)
$btnW    = [int][math]::Round(36 * $scale)
$gap     = [int][math]::Round(8 * $scale)
$padL    = [int][math]::Round(4 * $scale)
$padR    = $padL   # the strip is inset the SAME at both ends
Write-Host "INFO  scale=$scale clientW=$clientW maxTabW=$maxTabW btnW=$btnW gap=$gap pad=$padL"

# Park the cursor well below the strip so nothing paints a hover fill.
[StripDrv]::Park($clientX + 40, $clientY + $barH + 120)

# --- Pixel helpers ---------------------------------------------------------
# A scanline 2px above the strip's bottom: below the title/close baseline, and
# inside the chiclet at full width (its rounding is on the TOP corners only).
function Get-Shot { return [StripDrv]::Shot($top) }

function Selected-Extent($bmp) {
    $y = $offY + $barH - 2
    $left = -1; $right = -1
    for ($x = 0; $x -lt $clientW; $x++) {
        $p = $bmp.GetPixel($offX + $x, $y)
        $dark = ($p.R -lt 10 -and $p.G -lt 10 -and $p.B -lt 10)
        if ($dark -and $left -lt 0) { $left = $x }
        if ($dark) { $right = $x + 1 }
        elseif ($left -ge 0) { break }
    }
    return @($left, $right)
}

# Tab index of the selected tab, read back out of its chiclet's left edge:
# left = padL + index * tabW. The count oracle for every click below.
function Selected-Index([int]$left, [int]$tabW) {
    if ($tabW -le 0) { return -1 }
    return [int][math]::Round(($left - $padL) / $tabW)
}

function Any-Accent-Blue($bmp) {
    # The deleted underline was RGB(0x3D,0x8E,0xF8). Sweep the bottom 3 rows of
    # the whole strip: nothing anywhere may still be painting it.
    for ($dy = 1; $dy -le 3; $dy++) {
        $y = $offY + $barH - $dy
        for ($x = 0; $x -lt $clientW; $x += 2) {
            $p = $bmp.GetPixel($offX + $x, $y)
            if ([math]::Abs($p.R - 0x3D) -le 24 -and [math]::Abs($p.G - 0x8E) -le 24 -and [math]::Abs($p.B - 0xF8) -le 24) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# 1. A single tab does not span the client width
# ---------------------------------------------------------------------------
$bmp = Get-Shot
$ext = Selected-Extent $bmp
$tabLeft = $ext[0]; $tabRight = $ext[1]
$tabW = $tabRight - $tabLeft
Write-Host "INFO  single tab: left=$tabLeft right=$tabRight w=$tabW"
Assert ($tabLeft -ge 0) 'single tab: the selected chiclet is painted in the content background'
Assert ($tabW -gt 0 -and $tabW -lt ($clientW / 2)) "single tab: does NOT span the client width (w=$tabW of $clientW)"
Assert ([math]::Abs($tabW - $maxTabW) -le 3) "single tab: width is clamped to max_tab_w ($tabW vs $maxTabW)"
Assert ([math]::Abs($tabLeft - $padL) -le 2) "single tab: starts at the strip's left inset ($tabLeft vs $padL)"

# ---------------------------------------------------------------------------
# 2. No full-width accent rule under the strip
# ---------------------------------------------------------------------------
Assert (-not (Any-Accent-Blue $bmp)) 'selection: the full-width blue accent rule is gone (no accent pixels in the strip)'
$midStripX = [int](($tabRight + $clientW - 2 * $btnW - $padR) / 2)
$px = $bmp.GetPixel($offX + $midStripX, $offY + $barH - 2)
Assert ($px.R -ge 10 -and $px.R -le 40) "strip: dead space right of the tab is bar background, not tab or accent (R=$($px.R))"

# ---------------------------------------------------------------------------
# 3. There is a real gap between the last tab and the "+", and clicking in
#    that gap does nothing
# ---------------------------------------------------------------------------
$gapX = $tabRight + [int]($gap / 2)
[StripDrv]::LClick($top, $clientX + $gapX, $clientY + [int]($barH / 2))
[StripDrv]::Park($clientX + 40, $clientY + $barH + 120)
Start-Sleep -Milliseconds 400
$bmp.Dispose(); $bmp = Get-Shot
$ext = Selected-Extent $bmp
Assert ((Selected-Index $ext[0] $tabW) -eq 0) "gap: a click between the last tab and the + creates nothing (still 1 tab)"

# ---------------------------------------------------------------------------
# 4. The "+" follows the last tab - and moves right when a tab is added
# ---------------------------------------------------------------------------
$plusX = $tabRight + $gap + [int]($btnW / 2)
[StripDrv]::LClick($top, $clientX + $plusX, $clientY + [int]($barH / 2))
[StripDrv]::Park($clientX + 40, $clientY + $barH + 120)
Start-Sleep -Milliseconds 600
$bmp.Dispose(); $bmp = Get-Shot
$ext = Selected-Extent $bmp
$idx = Selected-Index $ext[0] $tabW
Write-Host "INFO  after + click #1: left=$($ext[0]) right=$($ext[1]) index=$idx"
Assert ($idx -eq 1) "+ : clicking one gap past the last tab creates tab 2 (selected index=$idx)"
Assert (($ext[1] - $ext[0]) -le ($maxTabW + 3)) 'two tabs: still clamped at max_tab_w'

# The second "+" is one tab width further right. If it had stayed pinned where
# it was, this click would land on tab 2 and create nothing.
$tabRight2 = $ext[1]
$plusX2 = $tabRight2 + $gap + [int]($btnW / 2)
Assert ($plusX2 -gt $plusX) "+ : moved right with the new tab ($plusX -> $plusX2)"
[StripDrv]::LClick($top, $clientX + $plusX2, $clientY + [int]($barH / 2))
[StripDrv]::Park($clientX + 40, $clientY + $barH + 120)
Start-Sleep -Milliseconds 600
$bmp.Dispose(); $bmp = Get-Shot
$ext = Selected-Extent $bmp
$idx = Selected-Index $ext[0] $tabW
Assert ($idx -eq 2) "+ : clicking at its NEW position creates tab 3 (selected index=$idx)"

# ---------------------------------------------------------------------------
# 5. Many tabs shrink instead of running off the end of the strip
# ---------------------------------------------------------------------------
$want = [int][math]::Ceiling($clientW / $maxTabW) + 4
for ($i = 0; $i -lt $want; $i++) { [StripDrv]::CtrlT($top) | Out-Null }
[StripDrv]::Park($clientX + 40, $clientY + $barH + 120)
Start-Sleep -Milliseconds 800
$bmp.Dispose(); $bmp = Get-Shot
$ext = Selected-Extent $bmp
$manyW = $ext[1] - $ext[0]
Write-Host "INFO  many tabs: left=$($ext[0]) right=$($ext[1]) w=$manyW"
Assert ($manyW -gt 0 -and $manyW -lt $maxTabW) "many tabs: tab width shrank below max ($manyW < $maxTabW)"
$bandLeft = $clientW - $padR - 2 * $btnW - $gap
Assert ($ext[1] -le $bandLeft) "many tabs: the tab run never reaches the button band ($($ext[1]) <= $bandLeft)"
Assert (-not (Any-Accent-Blue $bmp)) 'many tabs: still no accent rule anywhere in the strip'

# ---------------------------------------------------------------------------
# 6. The menu button is pinned to the right END OF THE STRIP - inset by the
#    same padding the first tab gets on the left, not flush against the window
#    border ("the hamburger button has no gap between it and the border").
#    Clicking one pad in from the edge must therefore MISS it, and clicking
#    the button's centre must hit.
# ---------------------------------------------------------------------------
$edgeX = $clientW - [int]($padR / 2) - 1
[StripDrv]::LClick($top, $clientX + $edgeX, $clientY + [int]($barH / 2))
Start-Sleep -Milliseconds 400
Add-Type -Name MenuFind0 -Namespace T202 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
'@
Assert (([T202.MenuFind0]::FindWindowW('#32768', $null)) -eq [IntPtr]::Zero) 'right inset: the strip does not run flush to the window border (a click in the pad opens nothing)'

$menuX = $clientW - $padR - [int]($btnW / 2)
[StripDrv]::LClick($top, $clientX + $menuX, $clientY + [int]($barH / 2))
Start-Sleep -Milliseconds 500
Add-Type -Name MenuFind -Namespace T202 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
'@
$menuOpen = ([T202.MenuFind]::FindWindowW('#32768', $null) -ne [IntPtr]::Zero)
Assert $menuOpen 'menu button: still pinned to the right edge and still opens its popup'
if ($menuOpen) {
    # Escape it back closed so teardown is clean.
    [StripDrv]::Park($clientX + 40, $clientY + $barH + 120)
    [StripDrv]::LClick($top, $clientX + 40, $clientY + $barH + 200)
}

$bmp.Dispose()
Assert (-not $proc.HasExited) 'no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
