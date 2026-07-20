# T75 acceptance: `focus-follows-mouse` focuses the split under the pointer.
#
# Pre-fix, win32 handleMouseMove only forwarded cursor position; the config
# was accepted and ignored. Mac (SurfaceView mouseMoved) and GTK (surface
# "is_cursor_still" + grabFocus) focus the hovered split on real motion.
#
# Two GUI launches:
#   run 1 (--focus-follows-mouse=true): split down -> A (top), B (bottom,
#     focused). Glide the REAL cursor (SetCursorPos steps) from B into A:
#     focus must move to A with no click; glide back: focus returns to B.
#   run 2 (default off): same layout, same glide -> focus must NOT move;
#     then a real click on A must still focus it (positive control that the
#     cursor genuinely traveled to A, so the no-op wasn't a dead mouse).
# Focused HWND is read with GetGUIThreadInfo; the T48 deferred-SetFocus
# path lands focus asynchronously, so assertions poll.
#
# A keyboard positive control (ctrl+k clear_screen, T55 pattern) runs first
# in run 1 so an injection failure aborts instead of reading as a T75
# regression. Only touches ghoztty processes running from this repo's
# zig-out*.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-ffmtest'
}
$errlog = Join-Path $env:TEMP 'ghoztty-ffm-stderr.log'

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
public class FfmDrv {
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
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
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
    [StructLayout(LayoutKind.Sequential)]
    public struct MINPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", EntryPoint = "SendInput")] public static extern uint SendMouseInput(uint n, MINPUT[] inputs, int size);
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

    // Glide the REAL cursor from (x0,y0) to (x1,y1) in `steps` moves so the
    // window under it receives genuine WM_MOUSEMOVE traffic (SetCursorPos
    // synthesizes mouse-move input at each new position).
    public static void Glide(int x0, int y0, int x1, int y1, int steps) {
        for (int i = 1; i <= steps; i++) {
            SetCursorPos(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps);
            Thread.Sleep(30);
        }
    }

    // Left-click at the current cursor position.
    public static void Click() {
        var i = new MINPUT[2];
        i[0].type = 0; i[0].mi.dwFlags = 0x0002; // MOUSEEVENTF_LEFTDOWN
        i[1].type = 0; i[1].mi.dwFlags = 0x0004; // MOUSEEVENTF_LEFTUP
        SendMouseInput(2, i, Marshal.SizeOf(typeof(MINPUT)));
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab: attach to the current foreground
    // owner's thread + an Alt tap (last-input source), retried - a
    // background process may not steal foreground otherwise.
    public static bool GrabForeground(IntPtr top) {
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            Key(0x12, false); Key(0x12, true); // Alt tap
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
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
        if ([FfmDrv]::FocusedHwnd($top) -eq $expected) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Center($pane) {
    @{ X = [int](($pane.Left + $pane.Right) / 2); Y = [int](($pane.Top + $pane.Bottom) / 2) }
}

function Run-Case([string]$label, [string[]]$extraArgs, [bool]$expectFollow, [bool]$control) {
    Kill-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }

    $sp = @{ FilePath = $exe; PassThru = $true }
    if ($extraArgs.Count) { $sp.ArgumentList = $extraArgs }
    if (-not $ExePath -and $control) { $sp.RedirectStandardError = $errlog }
    $proc = Start-Process @sp
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [FfmDrv]::FindTop([uint32]$proc.Id)
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }

    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 800

    $panes = @(Parse-Panes ([FfmDrv]::Panes($top)))
    Assert ($panes.Count -eq 2 -and @($panes | Where-Object Visible).Count -eq 2) "$label setup: 2 visible panes"
    if ($panes.Count -ne 2) { Stop-Process -Id $proc.Id -Force; exit 1 }
    $A = $panes | Sort-Object Top | Select-Object -First 1     # top pane
    $B = $panes | Sort-Object Top | Select-Object -Last 1      # bottom pane (focused after split)
    $ca = Center $A
    $cb = Center $B

    if ($control) {
        # Positive control: ctrl+k reaches binding dispatch (debug log only).
        $r = [FfmDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11), 0x4B)
        if ($r -ne 'SENT') { Write-Host "ABORT: control chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
        Start-Sleep -Milliseconds 300
        if (Test-Path $errlog) {
            if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
                Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T75 verdict'
                Stop-Process -Id $proc.Id -Force; exit 1
            }
            Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
        } else {
            Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
        }
    }

    # Make the window foreground/active and confirm B has focus (the split
    # focused it). Park the real cursor at B's center so the glide starts
    # from a known in-window position.
    [FfmDrv]::GrabForeground($top) | Out-Null
    if ([FfmDrv]::GetForegroundWindow() -ne $top) {
        Write-Host "ABORT ($label): could not foreground the ghoztty window"
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    [FfmDrv]::SetCursorPos($cb.X, $cb.Y) | Out-Null
    Start-Sleep -Milliseconds 200
    Assert (Wait-Focus $top $B.Hwnd) "$label setup: focus starts on pane B"

    # Glide the real cursor from B's center into A's center. No clicks.
    [FfmDrv]::Glide($cb.X, $cb.Y, $ca.X, $ca.Y, 8)
    Start-Sleep -Milliseconds 300

    if ($expectFollow) {
        Assert (Wait-Focus $top $A.Hwnd) "$label hover moved focus to pane A (no click)"
        # And back again.
        [FfmDrv]::Glide($ca.X, $ca.Y, $cb.X, $cb.Y, 8)
        Assert (Wait-Focus $top $B.Hwnd) "$label hover moved focus back to pane B"
    } else {
        Start-Sleep -Milliseconds 700
        Assert ([FfmDrv]::FocusedHwnd($top) -eq $B.Hwnd) "$label hover did NOT move focus (config off)"
        # Positive control: a real click at the same spot must focus A,
        # proving the cursor genuinely reached pane A.
        [FfmDrv]::Click()
        Assert (Wait-Focus $top $A.Hwnd) "$label click control: click on A focuses A"
    }

    Assert (-not $proc.HasExited) "$label no crash"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

Run-Case 'on ' @('--focus-follows-mouse=true') $true $true
Run-Case 'off' @() $false $false

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
