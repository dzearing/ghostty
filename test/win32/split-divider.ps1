# T73 acceptance: split divider lines honor `split-divider-color`.
# T94 acceptance (run 2 tail): the divider grab band is ~9 DIP wide with
# SIZENS cursor feedback across it, and a real-input drag starting 4 DIP
# off the line (over the pane surface, past the ~5 DIP visual gap) still
# resizes — proving the WM_NCHITTEST/HTTRANSPARENT fall-through.
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

    // Composited screen pixels in a horizontal strip: "r,g,b" per x (T155).
    public static string[] StripH(int y, int x0, int x1) {
        var lines = new List<string>();
        IntPtr dc = GetDC(IntPtr.Zero);
        for (int x = x0; x <= x1; x++) {
            uint c = GetPixel(dc, x, y);
            lines.Add((c & 0xFF) + "," + ((c >> 8) & 0xFF) + "," + ((c >> 16) & 0xFF));
        }
        ReleaseDC(IntPtr.Zero, dc);
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

    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr inst, IntPtr name);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public int ptX, ptY; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MINPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", EntryPoint = "SendInput")] public static extern uint SendMouseInput(uint n, MINPUT[] inputs, int size);

    static void MouseBtn(bool up) {
        var i = new MINPUT[1];
        i[0].type = 0; // INPUT_MOUSE
        i[0].mi.dwFlags = up ? 4u : 2u; // MOUSEEVENTF_LEFTUP : LEFTDOWN
        SendMouseInput(1, i, Marshal.SizeOf(typeof(MINPUT)));
    }

    // The system cursor currently shown is the vertical-resize arrow.
    public static bool CursorIsSizeNS() {
        var ci = new CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci)) return false;
        return ci.hCursor == LoadCursorW(IntPtr.Zero, (IntPtr)32645); // IDC_SIZENS
    }

    // Park the cursor at (x, y) so WM_SETCURSOR fires for whatever is there.
    public static void Park(int x, int y) {
        SetCursorPos(x, y);
        Thread.Sleep(200);
    }

    // Hardened foreground grab (T86/T25 hero-mode pattern): a background
    // process may not steal foreground, so attach to the current owner's
    // input thread and tap Alt to become the last-input source; retry on
    // a busy desktop.
    public static bool ForceForeground(IntPtr top) {
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

    // Real-input vertical divider drag: press at (x, y0), move to (x, y1)
    // in steps, release. Foreground-guarded like Chord.
    public static string DragV(IntPtr top, int x, int y0, int y1) {
        if (!ForceForeground(top)) return "ABORT: foreground owned by another window";
        SetCursorPos(x, y0);
        Thread.Sleep(150);
        MouseBtn(false);
        Thread.Sleep(100);
        for (int i = 1; i <= 8; i++) {
            SetCursorPos(x, y0 + (y1 - y0) * i / 8);
            Thread.Sleep(40);
        }
        Thread.Sleep(100);
        MouseBtn(true);
        Thread.Sleep(250);
        return "SENT";
    }

    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Shrink the window by (dw, dh) physical px, keeping its origin (T155).
    // Small repeated resizes are what actually accumulated stale divider
    // lines: each one drifts the split position by less than the old gap
    // was wide, so the previous line stayed inside the never-erased gap.
    public static void Shrink(IntPtr h, int dw, int dh) {
        RECT r; GetWindowRect(h, out r);
        SetWindowPos(h, IntPtr.Zero, r.left, r.top,
            (r.right - r.left) - dw, (r.bottom - r.top) - dh,
            0x0004 | 0x0010); // SWP_NOZORDER | SWP_NOACTIVATE
    }

    // Real-input horizontal divider drag (T155), mirror of DragV.
    public static string DragH(IntPtr top, int y, int x0, int x1) {
        if (!ForceForeground(top)) return "ABORT: foreground owned by another window";
        SetCursorPos(x0, y);
        Thread.Sleep(150);
        MouseBtn(false);
        Thread.Sleep(100);
        for (int i = 1; i <= 8; i++) {
            SetCursorPos(x0 + (x1 - x0) * i / 8, y);
            Thread.Sleep(40);
        }
        Thread.Sleep(100);
        MouseBtn(true);
        Thread.Sleep(250);
        return "SENT";
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
        if (!ForceForeground(top)) return "ABORT: foreground owned by another window";
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
    [DivDrv]::ForceForeground($top) | Out-Null
    Start-Sleep -Milliseconds 200
    [pscustomobject]@{ Proc = $proc; Top = $top; Panes = $panes }
}

# Common args: hermetic config, no dim overlays near the gap, black terminal
# so gray/red/blue divider pixels cannot be produced by terminal content.
$common = @('--config-default-files=false', '--background=#000000', '--unfocused-split-opacity=1', '--session-persistence=false')

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
$proc = $g.Proc; $top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1

Assert (Divider-HasColor $A $B 128 128 128) 'default: divider gap has the fallback gray pixel'
if (-not (Divider-HasColor $A $B 128 128 128)) { Dump-Strip $A $B 'default' }

# ---------------------------------------------------------------------------
# T94: grab-band hit target + cursor feedback. The band is ~9 DIP total
# (4.5 DIP each side of the line) while the visual gap is ~5 DIP, so a
# point 4 DIP off the line lies OVER a pane surface — reaching it proves
# the WM_NCHITTEST/HTTRANSPARENT fall-through, not just the parent gap.
# ---------------------------------------------------------------------------
$dpi = [DivDrv]::GetDpiForWindow($top)
$off4 = [int][math]::Round(4 * $dpi / 96)
function Get-DividerLine {
    $panes = @(Parse-Panes ([DivDrv]::Panes($top)) | Where-Object Visible)
    $pa = $panes | Sort-Object Top | Select-Object -First 1
    $pb = $panes | Sort-Object Top | Select-Object -Last 1
    [pscustomobject]@{
        A = $pa; B = $pb
        X = [int](($pa.Left + $pa.Right) / 2)
        Y = [int](($pa.Bottom + $pb.Top) / 2)
    }
}

$d = Get-DividerLine
if (-not [DivDrv]::ForceForeground($top)) {
    Write-Host 'ABORT: foreground owned by another window - hit-target section is not a T94 verdict'
    Stop-Process -Id $proc.Id -Force; exit 1
}

# Cursor feedback across the band (on the line, and 4 DIP either side).
[DivDrv]::Park($d.X, $d.Y)
Assert ([DivDrv]::CursorIsSizeNS()) 'T94: SIZENS cursor on the divider line'
[DivDrv]::Park($d.X, $d.Y + $off4)
Assert ([DivDrv]::CursorIsSizeNS()) 'T94: SIZENS cursor 4 DIP below the line (over the pane)'
[DivDrv]::Park($d.X, $d.Y - $off4)
Assert ([DivDrv]::CursorIsSizeNS()) 'T94: SIZENS cursor 4 DIP above the line (over the pane)'
[DivDrv]::Park($d.X, [int](($d.B.Top + $d.B.Bottom) / 2))
Assert (-not [DivDrv]::CursorIsSizeNS()) 'T94: no SIZENS cursor at pane center (band is bounded)'

# Drag from +4 DIP below the line: divider follows the mouse down.
$before = $d.Y
$r = [DivDrv]::DragV($top, $d.X, $d.Y + $off4, $d.Y + $off4 + 80)
if ($r -ne 'SENT') { Write-Host "ABORT: drag not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
$d = Get-DividerLine
Assert ($d.Y -gt $before + 40) "T94: drag from +4 DIP resized (line $before -> $($d.Y))"

# Drag from -4 DIP above the (moved) line: divider follows the mouse up.
$before = $d.Y
$r = [DivDrv]::DragV($top, $d.X, $d.Y - $off4, $d.Y - $off4 - 80)
if ($r -ne 'SENT') { Write-Host "ABORT: drag not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
$d = Get-DividerLine
Assert ($d.Y -lt $before - 40) "T94: drag from -4 DIP resized (line $before -> $($d.Y))"

Assert (-not $proc.HasExited) 'default: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# T155: exactly ONE divider band, and it is a solid fill.
#
# The old code left a ~5 DIP gap between the panes and stroked a hairline
# down the middle of it, while the parent's WM_ERASEBKGND painted nothing —
# so every ratio change stroked a NEW line and left the OLD one on screen.
# The user's screenshot showed two parallel verticals and a 3-line stack.
#
# Oracle: scan a full scanline ACROSS both panes and count contiguous runs
# of divider-colored pixels. Stale lines show up as extra runs; the 3-edge
# render (pane | parent bg | line | parent bg | pane) shows up as a run
# narrower than the gap it sits in. Both are counted here, after THREE
# drags — one drag is not enough, the reported bug accumulates.
#
# Green is used so no earlier run's red/blue can be mistaken for a band,
# and the terminal background is black so white-on-black text (which can
# antialias to mid-gray) cannot match either.
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
# Screen-pixel control (learned the hard way, 2026-07-29): every count in
# this section comes from GetPixel on the COMPOSITED SCREEN, so an occluded
# or non-foreground window reads as "0 divider pixels" — indistinguishable
# from a product failure unless something proves the window is on screen
# first. The panes are launched with --background=#000000, so a pixel deep
# inside a pane must read near-black. If it does not, the probe is looking at
# some other window and the axis is SKIPPED rather than failed.
function Pane-IsOnScreen($pane) {
    $x = [int]($pane.Left + ($pane.Right - $pane.Left) * 0.5)
    $y = [int]($pane.Top + ($pane.Bottom - $pane.Top) * 0.75)
    $px = ([DivDrv]::Strip($x, $y, $y))[0]
    $c = $px -split ','
    return (([int]$c[0] -le 40) -and ([int]$c[1] -le 40) -and ([int]$c[2] -le 40))
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

# One GUI per axis: a single split each, so a run count of 1 is unambiguous.
function Start-T155Gui([string]$direction) {
    Kill-RepoInstances
    $args155 = $common + @('--split-divider-color=00ff00')
    $p = Start-Process -FilePath $exe -ArgumentList $args155 -PassThru
    Start-Sleep -Seconds 3
    if ($p.HasExited) { return $null }
    $t = [DivDrv]::FindTop([uint32]$p.Id)
    if ($t -eq [IntPtr]::Zero) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; return $null }
    & $exe +split --direction=$direction | Out-Null
    Start-Sleep -Milliseconds 900
    [DivDrv]::ForceForeground($t) | Out-Null
    Start-Sleep -Milliseconds 300
    [pscustomobject]@{ Proc = $p; Top = $t }
}

foreach ($axis in @('down', 'right')) {
    $g = Start-T155Gui $axis
    if ($null -eq $g) { Write-Host "SKIP T155/$axis : GUI did not come up"; continue }
    $bandPx = [math]::Max([int][math]::Round([DivDrv]::GetDpiForWindow($g.Top) / 96.0), 1)
    $panes = @(Parse-Panes ([DivDrv]::Panes($g.Top)) | Where-Object Visible)
    if ($panes.Count -ne 2) {
        Assert $false "T155/$axis setup: 2 visible panes (got $($panes.Count))"
        Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue
        continue
    }

    # Three drags, each landing somewhere new. Every one of them used to
    # leave its old line behind.
    $aborted = $false
    foreach ($delta in 60, -40, 70) {
        $panes = @(Parse-Panes ([DivDrv]::Panes($g.Top)) | Where-Object Visible)
        if ($axis -eq 'down') {
            $pa = $panes | Sort-Object Top | Select-Object -First 1
            $pb = $panes | Sort-Object Top | Select-Object -Last 1
            $lineY = [int](($pa.Bottom + $pb.Top) / 2)
            $x = [int](($pa.Left + $pa.Right) / 2)
            $r = [DivDrv]::DragV($g.Top, $x, $lineY, $lineY + $delta)
        } else {
            $pa = $panes | Sort-Object Left | Select-Object -First 1
            $pb = $panes | Sort-Object Left | Select-Object -Last 1
            $lineX = [int](($pa.Right + $pb.Left) / 2)
            $y = [int](($pa.Top + $pa.Bottom) / 2)
            $r = [DivDrv]::DragH($g.Top, $y, $lineX, $lineX + $delta)
        }
        if ($r -ne 'SENT') { Write-Host "SKIP T155/$axis : drag not sent ($r)"; $aborted = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if ($aborted) { Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue; continue }

    [DivDrv]::ForceForeground($g.Top) | Out-Null
    Start-Sleep -Milliseconds 600
    $panes = @(Parse-Panes ([DivDrv]::Panes($g.Top)) | Where-Object Visible)
    if ($axis -eq 'down') {
        $pa = $panes | Sort-Object Top | Select-Object -First 1
        $pb = $panes | Sort-Object Top | Select-Object -Last 1
        $x = [int](($pa.Left + $pa.Right) / 2)
        $strip = [DivDrv]::Strip($x, ($pa.Top + 4), ($pb.Bottom - 4))
    } else {
        $pa = $panes | Sort-Object Left | Select-Object -First 1
        $pb = $panes | Sort-Object Left | Select-Object -Last 1
        $y = [int](($pa.Top + $pa.Bottom) / 2)
        $strip = [DivDrv]::StripH($y, ($pa.Left + 4), ($pb.Right - 4))
    }
    if (-not (Pane-IsOnScreen $pa)) {
        Write-Host "SKIP T155/$axis (after drags): pane is not on screen - pixel probe would be meaningless"
        Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue
        continue
    }
    $runs = Count-ColorRuns $strip 0 255 0
    $width = Max-RunLength $strip 0 255 0
    Assert ($runs -eq 1) "T155/$axis : exactly ONE divider band after 3 drags (got $runs)"
    Assert ($width -eq $bandPx) "T155/$axis : band is a solid ${bandPx}px fill (got ${width}px)"
    if ($runs -ne 1 -or $width -ne $bandPx) { Dump-Green $strip 'drags' }

    # THE case that actually reproduces the user's report. Drags alone do
    # NOT: a big ratio change moves the line clear of the old gap, so the
    # growing pane covers the stale pixels and the count stays at 1 even on
    # a broken build (measured 2026-07-29 — the first version of this
    # oracle passed pre-fix, which is why this sub-case exists). Repeated
    # SMALL window resizes are the trigger: each drifts the split position
    # by ~2px, less than the old 5 DIP gap, so the previous line survived
    # inside it. Pre-fix this reports 2 runs; post-fix, 1.
    foreach ($i in 1..3) {
        if ($axis -eq 'down') { [DivDrv]::Shrink($g.Top, 0, 4) } else { [DivDrv]::Shrink($g.Top, 4, 0) }
        Start-Sleep -Milliseconds 300
    }
    [DivDrv]::ForceForeground($g.Top) | Out-Null
    Start-Sleep -Milliseconds 600
    $panes = @(Parse-Panes ([DivDrv]::Panes($g.Top)) | Where-Object Visible)
    if ($axis -eq 'down') {
        $pa = $panes | Sort-Object Top | Select-Object -First 1
        $pb = $panes | Sort-Object Top | Select-Object -Last 1
        $strip = [DivDrv]::Strip([int](($pa.Left + $pa.Right) / 2), ($pa.Top + 4), ($pb.Bottom - 4))
    } else {
        $pa = $panes | Sort-Object Left | Select-Object -First 1
        $pb = $panes | Sort-Object Left | Select-Object -Last 1
        $strip = [DivDrv]::StripH([int](($pa.Top + $pa.Bottom) / 2), ($pa.Left + 4), ($pb.Right - 4))
    }
    if (-not (Pane-IsOnScreen $pa)) {
        Write-Host "SKIP T155/$axis (after resizes): pane is not on screen"
        Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue
        continue
    }
    $runs2 = Count-ColorRuns $strip 0 255 0
    $width2 = Max-RunLength $strip 0 255 0
    Assert ($runs2 -eq 1) "T155/$axis : still ONE band after 3 small window resizes (got $runs2)"
    Assert ($width2 -eq $bandPx) "T155/$axis : band still a solid ${bandPx}px fill after resizes (got ${width2}px)"
    if ($runs2 -ne 1 -or $width2 -ne $bandPx) { Dump-Green $strip 'resizes' }

    Assert (-not $g.Proc.HasExited) "T155/$axis : no crash"
    Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue
}

Remove-Item $conf -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
