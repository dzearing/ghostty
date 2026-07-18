# T78 acceptance: window-title-font-family drives the tab bar font.
#
# The DWM caption of a standard-frame window always draws with the system
# caption font, so on Windows this config applies where the app renders
# titles itself: the owner-drawn tab bar (createTabFont in Window.zig).
#
# Oracle: a per-column "lit pixel" signature of the tab-bar strip (tab title
# text + the "+" new-tab glyph, all drawn with tab_font). A different font
# family produces a different glyph raster; the same family reproduces the
# same raster (owner-drawn into a mem DC, so rendering is window-relative
# and deterministic).
#
#   1. Launch A (default font, --window-show-tab-bar=always so a single tab
#      shows the bar) -> bar visible (positive control), signature non-empty.
#   2. Launch B (--window-title-font-family="Times New Roman") -> signature
#      differs from A (the config changes the tab bar raster).
#   3. Launch C (same family, but via --config-file) -> signature matches B
#      (negative control + the config-file path works).
#   4. Edit the config file back to Segoe UI + ctrl+shift+comma reload ->
#      signature changes live without a relaunch (onConfigChange path).
#
# DPI-aware (PER_MONITOR_AWARE_V2) so GetPixel sees physical pixels (the
# tab-color.ps1 lesson). Only touches ghoztty processes from this repo's
# zig-out.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

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
using System.Threading;
using System.Runtime.InteropServices;
public class TFDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() {
        SetProcessDpiAwarenessContext((IntPtr)(-4)); // PER_MONITOR_AWARE_V2
    }

    public static IntPtr FindTop(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Screen coords of the window's client-area origin.
    public static int[] ClientOrigin(IntPtr top) {
        POINT p = new POINT { x = 0, y = 0 };
        ClientToScreen(top, ref p);
        return new int[] { p.x, p.y };
    }

    // First visible GhozttyTerminal child: "hwnd:left,top,right,bottom".
    public static string Pane(IntPtr top) {
        string line = "";
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                line = h.ToInt64() + ":" + r.left + "," + r.top + "," + r.right + "," + r.bottom;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return line;
    }

    // Per-column count of "lit" (text-colored) pixels in the given screen
    // rect: R+G+B > 300 against the dark bar. One GetDC for the whole scan.
    public static int[] ColSig(int x0, int x1, int y0, int y1, int step) {
        var cols = new List<int>();
        IntPtr dc = GetDC(IntPtr.Zero);
        for (int x = x0; x <= x1; x += step) {
            int lit = 0;
            for (int y = y0; y <= y1; y++) {
                uint c = GetPixel(dc, x, y); // COLORREF 0x00BBGGRR
                int sum = (int)(c & 0xFF) + (int)((c >> 8) & 0xFF) + (int)((c >> 16) & 0xFF);
                if (sum > 300) lit++;
            }
            cols.Add(lit);
        }
        ReleaseDC(IntPtr.Zero, dc);
        return cols.ToArray();
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        SetForegroundWindow(top);
        Thread.Sleep(150);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
            foreach (var m in mods) Key(m, false);
            Thread.Sleep(20);
            Key(vk, false); Thread.Sleep(20); Key(vk, true);
            Thread.Sleep(20);
            for (int j = mods.Length - 1; j >= 0; j--) Key(mods[j], true);
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }
}
'@

[TFDrv]::BeDpiAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Launch the GUI with the given extra args; returns geometry + a signature
# sampler closure's inputs. The tab bar is up (always + 1 tab), text row
# sampled with the cursor parked away from hover chrome.
function Launch-Gui([string[]]$extraArgs) {
    $args_ = @('--config-default-files=false', '--background=#000000', '--window-show-tab-bar=always') + $extraArgs
    $proc = Start-Process -FilePath $exe -PassThru -ArgumentList $args_
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { return $null }
    $top = [TFDrv]::FindTop([uint32]$proc.Id)
    if ($top -eq [IntPtr]::Zero) { Stop-Process -Id $proc.Id -Force; return $null }
    $paneLine = [TFDrv]::Pane($top)
    if (-not $paneLine) { Stop-Process -Id $proc.Id -Force; return $null }
    $hw, $r = $paneLine -split ':'
    $c = $r -split ','
    $origin = [TFDrv]::ClientOrigin($top)
    $barH = [int]$c[1] - $origin[1]
    # Park the cursor below the bar so hover chrome can't pollute sampling.
    [TFDrv]::SetCursorPos(([int]$c[0] + 60), ([int]$c[1] + 120)) | Out-Null
    Start-Sleep -Milliseconds 400
    [pscustomobject]@{
        Proc = $proc; Top = $top; Surface = [IntPtr][int64]$hw
        ClientLeft = $origin[0]; ClientTop = $origin[1]; BarH = $barH
    }
}

# Signature across the single tab (title text region) + the "+" button.
# 1 tab: tabW = clamp(clientW-36s, 60s, 200s) = 200s on any normal window.
function Get-Signature($g) {
    $scale = $g.BarH / 32.0
    $tabW = [math]::Round(200 * $scale)
    $plusW = [math]::Round(36 * $scale)
    $x0 = $g.ClientLeft + [math]::Round(10 * $scale)   # text pad
    $x1 = $g.ClientLeft + $tabW + $plusW - 2           # through the + glyph
    $y0 = $g.ClientTop + 4
    $y1 = $g.ClientTop + $g.BarH - 5                   # skip accent-stripe rows
    [TFDrv]::ColSig([int]$x0, [int]$x1, [int]$y0, [int]$y1, 2)
}

function Sig-Diff([int[]]$a, [int[]]$b) {
    $n = [math]::Min($a.Count, $b.Count)
    $d = 0
    for ($i = 0; $i -lt $n; $i++) { $d += [math]::Abs($a[$i] - $b[$i]) }
    $d + [math]::Abs($a.Count - $b.Count) * 10
}

$VK_CTRL = [uint16]0x11; $VK_SHIFT = [uint16]0x10; $VK_OEM_COMMA = [uint16]0xBC

# ---------------------------------------------------------------------------
# Launch A: default font
# ---------------------------------------------------------------------------
Kill-RepoInstances
$a = Launch-Gui @()
if ($null -eq $a) { Write-Host 'SETUP FAIL: launch A died'; exit 1 }
Assert ($a.BarH -ge 20 -and $a.BarH -le 80) "positive control: tab bar visible with 1 tab + always (barH=$($a.BarH))"
$sigA = Get-Signature $a
$litA = ($sigA | Measure-Object -Sum).Sum
Assert ($litA -gt 20) "default font: tab bar draws text (lit=$litA)"
Stop-Process -Id $a.Proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------------------
# Launch B: Times New Roman via CLI
# ---------------------------------------------------------------------------
$b = Launch-Gui @('--window-title-font-family=Times New Roman')
if ($null -eq $b) { Write-Host 'SETUP FAIL: launch B died'; exit 1 }
Assert ($b.BarH -eq $a.BarH) "bar height unchanged by font family (barH=$($b.BarH))"
$sigB = Get-Signature $b
$dAB = Sig-Diff $sigA $sigB
Assert ($dAB -ge 25) "font family changes the tab bar raster (diff A-vs-B=$dAB)"
Stop-Process -Id $b.Proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------------------
# Launch C: same family via --config-file, then live reload back to Segoe UI
# ---------------------------------------------------------------------------
$conf = Join-Path $env:TEMP 'ghoztty-titlefont-test.conf'
Set-Content -Path $conf -Value 'window-title-font-family = Times New Roman' -Encoding ascii
$c = Launch-Gui @("--config-file=$conf")
if ($null -eq $c) { Write-Host 'SETUP FAIL: launch C died'; Remove-Item $conf -ErrorAction SilentlyContinue; exit 1 }
$sigC = Get-Signature $c
$dBC = Sig-Diff $sigB $sigC
Assert ($dBC -le 15) "same family reproduces the raster / config-file path works (diff B-vs-C=$dBC)"

Set-Content -Path $conf -Value 'window-title-font-family = Segoe UI' -Encoding ascii
$r = ''
for ($t = 0; $t -lt 4; $t++) {
    $r = [TFDrv]::Chord($c.Top, $c.Surface, @($VK_CTRL, $VK_SHIFT), $VK_OEM_COMMA)
    if ($r -eq 'SENT') { break }
    Start-Sleep -Milliseconds 900
}
Assert ($r -eq 'SENT') "reload chord injected ($r)"
$reloaded = $false
$dCD = 0
for ($t = 0; $t -lt 15; $t++) {
    Start-Sleep -Milliseconds 300
    $sigD = Get-Signature $c
    $dCD = Sig-Diff $sigC $sigD
    if ($dCD -ge 25) { $reloaded = $true; break }
}
Assert $reloaded "config reload re-fonts the tab bar live (diff C-vs-D=$dCD)"
if ($reloaded) {
    $dAD = Sig-Diff $sigA $sigD
    Assert ($dAD -le 15) "reloaded Segoe UI matches the default raster (diff A-vs-D=$dAD)"
}

Assert (-not $c.Proc.HasExited) 'no crash'
Stop-Process -Id $c.Proc.Id -Force -ErrorAction SilentlyContinue
Remove-Item $conf -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
