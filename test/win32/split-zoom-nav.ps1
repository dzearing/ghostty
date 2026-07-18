# T77 acceptance: goto_split while a split is zoomed must never focus a
# hidden pane.
#
# Repro (pre-fix): zoom a pane (ctrl+shift+enter), then ctrl+alt+arrow —
# keyboard focus moved to a pane that is not rendered (the zoomed one
# stayed on screen). Mac/GTK honor `split-preserve-zoom`:
#   - default:      navigating away CLEARS the zoom (all panes visible)
#   - `navigation`: the zoom FOLLOWS the navigation target
#
# Two GUI launches assert both config values. Layout: one +split down →
# pane A (top), pane B (bottom, focused). Zoom B, then ctrl+alt+up:
#   run 1 (default):    2 visible panes, focus on A (visible)
#   run 2 (navigation): 1 visible pane = A (zoom moved), focus on A
# Focused HWND is read with GetGUIThreadInfo (no thread attach needed);
# focus lands via the T48 deferred-SetFocus path, so assertions poll.
#
# A positive control (ctrl+k clear_screen, T55 pattern) runs first in run 1
# so an injection failure aborts instead of reading as a T77 regression.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-zoomnavtest'
}
$errlog = Join-Path $env:TEMP 'ghoztty-split-zoom-nav-stderr.log'

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
public class ZoomDrv {
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
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public uint cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

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

    // ALL GhozttyTerminal children (visible or not):
    // "hwnd:visible:left,top,right,bottom" lines.
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

    public static long FocusedHwnd(IntPtr top) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        var info = new GUITHREADINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
        if (!GetGUIThreadInfo(tid, ref info)) return 0;
        return info.hwndFocus.ToInt64();
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

# Poll until the window's focused HWND equals $expected (T48 defers focus).
function Wait-Focus([IntPtr]$top, [int64]$expected) {
    for ($t = 0; $t -lt 20; $t++) {
        if ([ZoomDrv]::FocusedHwnd($top) -eq $expected) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Run-Case([string]$label, [string[]]$extraArgs, [bool]$expectZoomFollows, [bool]$control) {
    Kill-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }

    $sp = @{ FilePath = $exe; PassThru = $true }
    if ($extraArgs.Count) { $sp.ArgumentList = $extraArgs }
    if (-not $ExePath -and $control) { $sp.RedirectStandardError = $errlog }
    $proc = Start-Process @sp
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [ZoomDrv]::FindTop([uint32]$proc.Id)
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }

    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 800

    $panes = @(Parse-Panes ([ZoomDrv]::Panes($top)))
    Assert ($panes.Count -eq 2 -and @($panes | Where-Object Visible).Count -eq 2) "$label setup: 2 visible panes"
    if ($panes.Count -ne 2) { Stop-Process -Id $proc.Id -Force; exit 1 }
    $A = $panes | Sort-Object Top | Select-Object -First 1     # top pane
    $B = $panes | Sort-Object Top | Select-Object -Last 1      # bottom pane (focused after split)

    if ($control) {
        # Positive control: ctrl+k reaches binding dispatch (debug log only).
        $r = [ZoomDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11), 0x4B)
        if ($r -ne 'SENT') { Write-Host "ABORT: control chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
        Start-Sleep -Milliseconds 300
        if (Test-Path $errlog) {
            if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
                Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T77 verdict'
                Stop-Process -Id $proc.Id -Force; exit 1
            }
            Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
        } else {
            Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
        }
    }

    # Zoom the bottom pane: ctrl+shift+enter.
    $r = [ZoomDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11, 0x10), 0x0D)
    Assert ($r -eq 'SENT') "$label zoom chord delivered ($r)"
    Start-Sleep -Milliseconds 500
    $panes = @(Parse-Panes ([ZoomDrv]::Panes($top)))
    $vis = @($panes | Where-Object Visible)
    Assert ($vis.Count -eq 1 -and $vis[0].Hwnd -eq $B.Hwnd) "$label zoomed: only pane B visible"

    # Navigate up out of the zoom: ctrl+alt+up.
    $r = [ZoomDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11, 0x12), 0x26)
    Assert ($r -eq 'SENT') "$label nav chord delivered ($r)"
    Start-Sleep -Milliseconds 500
    $panes = @(Parse-Panes ([ZoomDrv]::Panes($top)))
    $vis = @($panes | Where-Object Visible)

    if ($expectZoomFollows) {
        Assert ($vis.Count -eq 1 -and $vis[0].Hwnd -eq $A.Hwnd) "$label zoom FOLLOWED navigation: only pane A visible"
    } else {
        Assert ($vis.Count -eq 2) "$label zoom CLEARED on navigation: both panes visible"
    }
    Assert (Wait-Focus $top $A.Hwnd) "$label focus is on pane A"
    $focused = $panes | Where-Object { $_.Hwnd -eq [ZoomDrv]::FocusedHwnd($top) }
    Assert ($focused -and $focused.Visible) "$label focused pane is VISIBLE (the T77 bug)"

    Assert (-not $proc.HasExited) "$label no crash"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

Run-Case 'default' @() $false $true
Run-Case 'navigation' @('--split-preserve-zoom=navigation') $true $false

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
