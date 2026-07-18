# T73 acceptance: split divider lines honor `split-divider-color`.
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
# A positive control (ctrl+k clear_screen, T55 pattern) runs before the
# reload chord so an injection failure aborts instead of reading as a T73
# regression. Only touches ghoztty processes running from this repo's
# zig-out. Dimming is disabled (--unfocused-split-opacity=1) so overlays
# are out of the picture.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-dividertest'
}
$errlog = Join-Path $env:TEMP 'ghoztty-split-divider-stderr.log'
$conf = Join-Path $env:TEMP 'ghoztty-split-divider-test.conf'

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
public class DivDrv {
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
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // Per-monitor-DPI-aware so GetWindowRect/GetPixel use physical pixels;
    // without this a 1-2 px divider line is invisible to virtualized
    // sampling on >100% DPI monitors (hero-mode.ps1 2026-07-16 lesson).
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

    // ALL GhozttyTerminal children: "hwnd:visible:left,top,right,bottom".
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal") {
                RECT r; GetWindowRect(h, out r);
                lines.Add(h.ToInt64() + ":" + (IsWindowVisible(h) ? 1 : 0) + ":" + r.left + "," + r.top + "," + r.right + "," + r.bottom);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    // Composited screen pixels in a vertical strip: "r,g,b" per y.
    public static string[] Strip(int x, int y0, int y1) {
        var lines = new List<string>();
        IntPtr dc = GetDC(IntPtr.Zero);
        for (int y = y0; y <= y1; y++) {
            uint c = GetPixel(dc, x, y); // COLORREF 0x00BBGGRR
            lines.Add((c & 0xFF) + "," + ((c >> 8) & 0xFF) + "," + ((c >> 16) & 0xFF));
        }
        ReleaseDC(IntPtr.Zero, dc);
        return lines.ToArray();
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

[DivDrv]::BeDpiAware()

function Parse-Panes([string[]]$lines) {
    $lines | ForEach-Object {
        $hw, $vis, $r = $_ -split ':'
        $c = $r -split ','
        [pscustomobject]@{
            Hwnd = [int64]$hw; Visible = ($vis -eq '1')
            Left = [int]$c[0]; Top = [int]$c[1]; Right = [int]$c[2]; Bottom = [int]$c[3]
        }
    }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# True if r,g,b matches the target within tolerance.
function Pixel-Matches([string]$px, [int]$tr, [int]$tg, [int]$tb, [int]$tol = 40) {
    $c = $px -split ','
    ([math]::Abs([int]$c[0] - $tr) -le $tol) -and
    ([math]::Abs([int]$c[1] - $tg) -le $tol) -and
    ([math]::Abs([int]$c[2] - $tb) -le $tol)
}

# Sample the divider gap (between the top pane's bottom and the bottom
# pane's top) at 3 x-positions; true if any pixel matches the target color.
# The line is 1-2 px wide inside a ~5-7 px never-erased gap, so we look for
# ANY matching pixel, not all.
function Divider-HasColor($A, $B, [int]$tr, [int]$tg, [int]$tb) {
    $y0 = $A.Bottom - 2
    $y1 = $B.Top + 2
    foreach ($fx in @(0.3, 0.5, 0.7)) {
        $x = [int]($A.Left + ($A.Right - $A.Left) * $fx)
        $strip = [DivDrv]::Strip($x, $y0, $y1)
        foreach ($px in $strip) {
            if (Pixel-Matches $px $tr $tg $tb) { return $true }
        }
    }
    return $false
}

function Dump-Strip($A, $B, [string]$label) {
    $x = [int](($A.Left + $A.Right) / 2)
    $strip = [DivDrv]::Strip($x, ($A.Bottom - 2), ($B.Top + 2))
    Write-Host "DEBUG $label strip at x=${x}: $($strip -join ' | ')"
}

function Start-Gui([string]$label, [string[]]$extraArgs, [bool]$control) {
    Kill-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }
    $sp = @{ FilePath = $exe; PassThru = $true }
    if ($extraArgs.Count) { $sp.ArgumentList = $extraArgs }
    if (-not $ExePath -and $control) { $sp.RedirectStandardError = $errlog }
    $proc = Start-Process @sp
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [DivDrv]::FindTop([uint32]$proc.Id)
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 800
    $panes = @(Parse-Panes ([DivDrv]::Panes($top)) | Where-Object Visible)
    Assert ($panes.Count -eq 2) "$label setup: 2 visible panes"
    if ($panes.Count -ne 2) { Stop-Process -Id $proc.Id -Force; exit 1 }
    [DivDrv]::SetForegroundWindow($top) | Out-Null
    Start-Sleep -Milliseconds 500
    [pscustomobject]@{ Proc = $proc; Top = $top; Panes = $panes }
}

# Common args: hermetic config, no dim overlays near the gap, black terminal
# so gray/red/blue divider pixels cannot be produced by terminal content.
$common = @('--config-default-files=false', '--background=#000000', '--unfocused-split-opacity=1')

# ---------------------------------------------------------------------------
# Run 1: config file sets red; live reload re-colors to blue.
# ---------------------------------------------------------------------------
Set-Content -Path $conf -Value 'split-divider-color = ff0000' -Encoding Ascii
$g = Start-Gui 'red' ($common + "--config-file=$conf") $true
$proc = $g.Proc; $top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1   # top pane
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1    # bottom pane (focused)

Assert (Divider-HasColor $A $B 255 0 0) 'red: divider gap has a red pixel (split-divider-color honored)'
if (-not (Divider-HasColor $A $B 255 0 0)) { Dump-Strip $A $B 'red' }
Assert (-not (Divider-HasColor $A $B 128 128 128)) 'red: hardcoded gray divider is gone'

# Positive control: ctrl+k reaches binding dispatch (debug log only).
$r = [DivDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11), 0x4B)
if ($r -ne 'SENT') { Write-Host "ABORT: control chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
Start-Sleep -Milliseconds 300
if (Test-Path $errlog) {
    if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
        Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T73 verdict'
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
} else {
    Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
}

# Rewrite the config file, reload with ctrl+shift+, (VK_OEM_COMMA), and
# poll for the divider to turn blue.
Set-Content -Path $conf -Value 'split-divider-color = 0000ff' -Encoding Ascii
$r = [DivDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11, 0x10), 0xBC)
Assert ($r -eq 'SENT') "red->blue: reload chord delivered ($r)"
$blue = $false
for ($t = 0; $t -lt 25; $t++) {
    if (Divider-HasColor $A $B 0 0 255) { $blue = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert $blue 'red->blue: config reload re-colored the divider live'
if (-not $blue) { Dump-Strip $A $B 'red->blue' }

Assert (-not $proc.HasExited) 'red: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2: no color set -> fallback gray 128,128,128.
# ---------------------------------------------------------------------------
$g = Start-Gui 'default' $common $false
$proc = $g.Proc
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1

Assert (Divider-HasColor $A $B 128 128 128) 'default: divider gap has the fallback gray pixel'
if (-not (Divider-HasColor $A $B 128 128 128)) { Dump-Strip $A $B 'default' }
Assert (-not $proc.HasExited) 'default: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Remove-Item $conf -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
