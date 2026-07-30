# T74 acceptance: unfocused split panes are dimmed by a layered overlay
# honoring `unfocused-split-opacity` and `unfocused-split-fill`.
#
# The win32 apprt shows a click-through WS_EX_LAYERED popup
# (class GhozttyDimOverlay) over every unfocused pane of the active tab's
# split, filled with unfocused-split-fill (default: background color) at
# alpha = (1 - unfocused-split-opacity) * 255 (Mac parity).
#
# Three GUI launches:
#   run 1 (defaults):        split -> exactly one overlay, over the
#                            unfocused pane, alpha 77 (opacity 0.7),
#                            click-through ex-style; focus flip moves the
#                            overlay to the other pane; zoom hides all
#                            overlays, unzoom restores.
#   run 2 (opacity=1):       feature off -> no overlay ever visible.
#   run 3 (opacity=0.5,      alpha 128 + on-screen blend check: a red fill
#          fill=#ff0000,     over a black terminal reads back as dark red
#          background=#000)  at the dimmed pane's center.
#
# Focus lands via the T48 deferred-SetFocus path, so assertions poll.
# A positive control (ctrl+k clear_screen, T55 pattern) runs first in run 1
# so an injection failure aborts instead of reading as a T74 regression.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-dimtest'
}
$errlog = Join-Path $env:TEMP 'ghoztty-split-dim-stderr.log'

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
public class DimDrv {
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
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
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

    // Dim overlays are OWNED POPUPS (top-level), not children:
    // "hwnd:visible:alpha:exstyle:left,top,right,bottom" lines.
    public static string[] Overlays(uint pid) {
        var lines = new List<string>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyDimOverlay") {
                RECT r; GetWindowRect(h, out r);
                uint key; byte alpha; uint flags;
                if (!GetLayeredWindowAttributes(h, out key, out alpha, out flags)) alpha = 0;
                int ex = GetWindowLongW(h, -20); // GWL_EXSTYLE
                lines.Add(h.ToInt64() + ":" + (IsWindowVisible(h) ? 1 : 0) + ":" + alpha + ":" + ex + ":" + r.left + "," + r.top + "," + r.right + "," + r.bottom);
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

    // Composited screen pixel as "r,g,b".
    public static string ScreenPixel(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        uint c = GetPixel(dc, x, y); // COLORREF 0x00BBGGRR
        ReleaseDC(IntPtr.Zero, dc);
        return (c & 0xFF) + "," + ((c >> 8) & 0xFF) + "," + ((c >> 16) & 0xFF);
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

function Parse-Overlays([string[]]$lines) {
    $lines | ForEach-Object {
        $hw, $vis, $alpha, $ex, $r = $_ -split ':'
        $c = $r -split ','
        [pscustomobject]@{
            Hwnd = [int64]$hw; Visible = ($vis -eq '1')
            Alpha = [int]$alpha; ExStyle = [int64]$ex
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

# Same left/top/right/bottom within a small DPI/rounding slack.
function Rects-Match($a, $b, [int]$slack = 2) {
    ([math]::Abs($a.Left - $b.Left) -le $slack) -and
    ([math]::Abs($a.Top - $b.Top) -le $slack) -and
    ([math]::Abs($a.Right - $b.Right) -le $slack) -and
    ([math]::Abs($a.Bottom - $b.Bottom) -le $slack)
}

# Poll until exactly one visible overlay covers $pane (T48 defers focus, so
# the flip lands asynchronously). Returns the overlay list at success/timeout.
function Wait-OverlayOver([uint32]$procId, $pane) {
    for ($t = 0; $t -lt 25; $t++) {
        $ov = @(Parse-Overlays ([DimDrv]::Overlays($procId)) | Where-Object Visible)
        if ($ov.Count -eq 1 -and (Rects-Match $ov[0] $pane)) { return $ov }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "DEBUG wait timeout: want pane $($pane.Left),$($pane.Top),$($pane.Right),$($pane.Bottom)"
    [DimDrv]::Overlays($procId) | ForEach-Object { Write-Host "DEBUG raw overlay: $_" }
    return @(Parse-Overlays ([DimDrv]::Overlays($procId)) | Where-Object Visible)
}

function Start-Gui([string]$label, [string[]]$extraArgs, [bool]$control) {
    Kill-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }
    $sp = @{ FilePath = $exe; PassThru = $true }
    # --session-persistence=false is mandatory, not optional: this script
    # launches a GUI per section, and each launch WRITES a session-layout
    # manifest that the NEXT launch would restore — so section 2 came up with
    # section 1's panes and "2 visible panes" failed. Same trap T131 fixed for
    # pane-banner.ps1's bw window (found again here 2026-07-29 during T155).
    $sp.ArgumentList = @('--session-persistence=false') + $extraArgs
    if (-not $ExePath -and $control) { $sp.RedirectStandardError = $errlog }
    $proc = Start-Process @sp
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [DimDrv]::FindTop([uint32]$proc.Id)
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 800
    $panes = @(Parse-Panes ([DimDrv]::Panes($top)))
    Assert ($panes.Count -eq 2 -and @($panes | Where-Object Visible).Count -eq 2) "$label setup: 2 visible panes"
    if ($panes.Count -ne 2) { Stop-Process -Id $proc.Id -Force; exit 1 }
    [pscustomobject]@{ Proc = $proc; Top = $top; Panes = $panes }
}

# ---------------------------------------------------------------------------
# Run 1: defaults (opacity 0.7 -> alpha 77, fill = background).
# ---------------------------------------------------------------------------
$g = Start-Gui 'default' @() $true
$proc = $g.Proc; $top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1   # top pane
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1    # bottom pane (focused after split)

# Positive control: ctrl+k reaches binding dispatch (debug log only).
$r = [DimDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11), 0x4B)
if ($r -ne 'SENT') { Write-Host "ABORT: control chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
Start-Sleep -Milliseconds 300
if (Test-Path $errlog) {
    if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
        Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T74 verdict'
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
} else {
    Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
}

# @() wraps: PS 5.1 unrolls a one-element function return to a scalar
# pscustomobject, which has no intrinsic .Count.
$ov = @(Wait-OverlayOver ([uint32]$proc.Id) $A)
Assert ($ov.Count -eq 1) "default: exactly one visible dim overlay ($($ov.Count))"
if ($ov.Count -eq 1) {
    Assert (Rects-Match $ov[0] $A) "default: overlay covers the UNFOCUSED (top) pane"
    Assert (-not (Rects-Match $ov[0] $B)) "default: overlay does not cover the focused pane"
    Assert ($ov[0].Alpha -eq 77) "default: layered alpha is 77 = (1-0.7)*255 (got $($ov[0].Alpha))"
    # WS_EX_LAYERED(0x80000) + WS_EX_TRANSPARENT(0x20) + WS_EX_NOACTIVATE(0x8000000)
    Assert (($ov[0].ExStyle -band 0x80000) -ne 0) "default: overlay is WS_EX_LAYERED"
    Assert (($ov[0].ExStyle -band 0x20) -ne 0) "default: overlay is WS_EX_TRANSPARENT (click-through)"
    Assert (($ov[0].ExStyle -band 0x8000000) -ne 0) "default: overlay is WS_EX_NOACTIVATE"
}

# Focus flip: ctrl+alt+up focuses pane A -> overlay must move to pane B.
$r = [DimDrv]::Chord($top, [IntPtr]$B.Hwnd, [uint16[]]@(0x11, 0x12), 0x26)
Assert ($r -eq 'SENT') "default: goto-up chord delivered ($r)"
$ov = @(Wait-OverlayOver ([uint32]$proc.Id) $B)
Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $B)) "default: focus flip moved the overlay to pane B"

# Zoom pane A (now focused): overlays must all hide.
$r = [DimDrv]::Chord($top, [IntPtr]$A.Hwnd, [uint16[]]@(0x11, 0x10), 0x0D)
Assert ($r -eq 'SENT') "default: zoom chord delivered ($r)"
Start-Sleep -Milliseconds 600
$ov = @(Parse-Overlays ([DimDrv]::Overlays([uint32]$proc.Id)) | Where-Object Visible)
Assert ($ov.Count -eq 0) "default: zoomed -> no visible overlay ($($ov.Count))"

# Unzoom: the dim overlay comes back over the unfocused pane B.
$r = [DimDrv]::Chord($top, [IntPtr]$A.Hwnd, [uint16[]]@(0x11, 0x10), 0x0D)
Assert ($r -eq 'SENT') "default: unzoom chord delivered ($r)"
$ov = @(Wait-OverlayOver ([uint32]$proc.Id) $B)
Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $B)) "default: unzoom restored the overlay over pane B"

Assert (-not $proc.HasExited) 'default: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2: opacity=1 disables the feature entirely.
# ---------------------------------------------------------------------------
$g = Start-Gui 'opacity=1' @('--unfocused-split-opacity=1') $false
$proc = $g.Proc
Start-Sleep -Milliseconds 500
$ov = @(Parse-Overlays ([DimDrv]::Overlays([uint32]$proc.Id)) | Where-Object Visible)
Assert ($ov.Count -eq 0) "opacity=1: no visible overlay ($($ov.Count))"
Assert (-not $proc.HasExited) 'opacity=1: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 3: custom opacity + fill; verify alpha and the on-screen blend.
# ---------------------------------------------------------------------------
$g = Start-Gui 'custom' @('--unfocused-split-opacity=0.5', '--unfocused-split-fill=#ff0000', '--background=#000000') $false
$proc = $g.Proc; $top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
$ov = @(Wait-OverlayOver ([uint32]$proc.Id) $A)
Assert ($ov.Count -eq 1) "custom: one visible overlay"
if ($ov.Count -eq 1) {
    Assert ($ov[0].Alpha -eq 128) "custom: layered alpha is 128 = (1-0.5)*255 (got $($ov[0].Alpha))"
    # Blend check: red fill at 50% over a black terminal background reads
    # back as dark red. Bring the window to front, sample below the pane
    # center (away from the prompt line at the top).
    [DimDrv]::GrabForeground($top) | Out-Null
    Start-Sleep -Milliseconds 200
    $cx = [int](($A.Left + $A.Right) / 2)
    $cy = [int](($A.Top + $A.Bottom) / 2) + 30
    $px = ([DimDrv]::ScreenPixel($cx, $cy)) -split ','
    $rr = [int]$px[0]; $gg = [int]$px[1]; $bb = [int]$px[2]
    Assert ($rr -ge 60 -and $rr -gt ($gg + 40) -and $rr -gt ($bb + 40)) "custom: dimmed pane pixel is red-tinted (got r=$rr g=$gg b=$bb)"
}
Assert (-not $proc.HasExited) 'custom: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
