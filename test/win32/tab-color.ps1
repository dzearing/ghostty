# T72 acceptance: tab accent-color tagging (Mac TerminalTabColor parity).
#
# The tab context menu gained a "Tab Color" submenu (None + 9 colors, swatch
# bitmaps, checkmark on current). A tagged tab paints a ~3px accent stripe
# across the top of its tab in the owner-drawn tab bar; the color rides the
# tab through reorders and survives focus changes; "None" clears it.
#
# One hermetic GUI launch (--config-default-files=false, black background):
#   1. ctrl+t makes a second tab -> tab bar appears (positive control; also
#      yields bar height -> DPI scale -> tab widths for pixel sampling).
#   2. Right-click tab 0 -> context menu window (#32768) exists (control).
#   3. Keyboard-drive the menu by first-letter matching: 'T' (unique ->
#      "Tab Color" submenu opens), 'R' (unique -> Red selected).
#   4. Tab 0's top stripe polls to red (255,69,58); tab 1's stays unstriped.
#   5. Left-click tab 1 (activate) -> tab 0 keeps its stripe while inactive.
#   6. Right-click tab 0 -> 'T', 'N' (None) -> stripe cleared.
#
# DPI-aware (PER_MONITOR_AWARE_V2) so GetPixel sees physical pixels — the
# 3px stripe is invisible to virtualized sampling on >100% DPI boxes (the
# hero-mode.ps1 / split-divider.ps1 lesson). Only touches ghoztty processes
# running from this repo's zig-out.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-tabcolortest'
}

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
public class TabDrv {
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
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

    // Tap a key (down+up) into whatever has keyboard focus (menu loop).
    public static void Tap(ushort vk) {
        Key(vk, false); Thread.Sleep(40); Key(vk, true); Thread.Sleep(160);
    }

    public static void RClick(int x, int y) {
        SetCursorPos(x, y); Thread.Sleep(120);
        mouse_event(0x0008, 0, 0, 0, IntPtr.Zero); Thread.Sleep(60);
        mouse_event(0x0010, 0, 0, 0, IntPtr.Zero);
    }

    public static void LClick(int x, int y) {
        SetCursorPos(x, y); Thread.Sleep(120);
        mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); Thread.Sleep(60);
        mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
    }

    public static bool MenuOpen() {
        return FindWindowW("#32768", null) != IntPtr.Zero;
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

[TabDrv]::BeDpiAware()

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

function Pixel-Matches([string]$px, [int]$tr, [int]$tg, [int]$tb, [int]$tol = 40) {
    $c = $px -split ','
    ([math]::Abs([int]$c[0] - $tr) -le $tol) -and
    ([math]::Abs([int]$c[1] - $tg) -le $tol) -and
    ([math]::Abs([int]$c[2] - $tb) -le $tol)
}

# True if any pixel in the stripe band (client top .. +stripeH-1) at x
# matches the target color.
function Stripe-HasColor([int]$x, [int]$clientTop, [int]$stripeH, [int]$tr, [int]$tg, [int]$tb) {
    $strip = [TabDrv]::Strip($x, $clientTop, ($clientTop + $stripeH - 1))
    foreach ($px in $strip) {
        if (Pixel-Matches $px $tr $tg $tb) { return $true }
    }
    return $false
}

function Dump-Stripe([int]$x, [int]$clientTop, [int]$stripeH, [string]$label) {
    $strip = [TabDrv]::Strip($x, $clientTop, ($clientTop + $stripeH - 1))
    Write-Host "DEBUG $label stripe at x=${x}: $($strip -join ' | ')"
}

# Drive the already-open tab context menu to a Tab Color selection via
# menu first-letter matching: 'T' uniquely matches "Tab Color" (opens the
# submenu), then the color's unique first letter selects it. (Arrow-key
# nav via SendInput proved unreliable against the menu modal loop on this
# box; first-letter matching is what worked — diag 2026-07-18.)
function Select-TabColor([uint16]$colorVk) {
    [TabDrv]::Tap(0x54)      # 'T' -> "Tab Color" (unique) opens the submenu
    [TabDrv]::Tap($colorVk)  # unique first letter selects + closes
    Start-Sleep -Milliseconds 400
}

# ---------------------------------------------------------------------------
# Launch (hermetic; black bg so the bar/stripe colors can't come from content)
# ---------------------------------------------------------------------------
Kill-RepoInstances
$sp = @{ FilePath = $exe; PassThru = $true; ArgumentList = @('--config-default-files=false', '--background=#000000') }
$proc = Start-Process @sp
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [TabDrv]::FindTop([uint32]$proc.Id)
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

$panes1 = @(Parse-Panes ([TabDrv]::Panes($top)) | Where-Object Visible)
if ($panes1.Count -ne 1) { Write-Host "SETUP FAIL: expected 1 visible pane, got $($panes1.Count)"; exit 1 }
$paneTop1 = $panes1[0].Top   # client top: no tab bar yet with a single tab

# --- Positive control: ctrl+t creates tab 2 and the tab bar appears -------
# Retry the chord: right after a previous run's teardown another window can
# briefly own the foreground.
$r = ''
for ($a = 0; $a -lt 4; $a++) {
    $r = [TabDrv]::Chord($top, [IntPtr]$panes1[0].Hwnd, [uint16[]]@(0x11), 0x54)
    if ($r -eq 'SENT') { break }
    Start-Sleep -Milliseconds 900
}
if ($r -ne 'SENT') { Write-Host "ABORT: ctrl+t not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
$barH = 0
for ($t = 0; $t -lt 25; $t++) {
    Start-Sleep -Milliseconds 200
    $panes = @(Parse-Panes ([TabDrv]::Panes($top)))
    $vis = @($panes | Where-Object Visible)
    if ($panes.Count -eq 2 -and $vis.Count -eq 1 -and $vis[0].Top -gt $paneTop1) {
        $barH = $vis[0].Top - $paneTop1
        break
    }
}
Assert ($barH -gt 0) "positive control: ctrl+t made a 2nd tab and the tab bar appeared (barH=$barH)"
if ($barH -le 0) { Stop-Process -Id $proc.Id -Force; exit 1 }

# Geometry: scale from barH (= round(32*scale)); tab widths mirror
# paintTabBar (2 tabs: clamp((clientW-36*scale)/2, 60*scale, 200*scale)).
$scale = $barH / 32.0
$vis = @(Parse-Panes ([TabDrv]::Panes($top)) | Where-Object Visible)
$clientLeft = $vis[0].Left
$clientTop = $paneTop1
$clientW = $vis[0].Right - $vis[0].Left
$tabW = [math]::Floor(($clientW - [math]::Round(36 * $scale)) / 2)
$tabW = [math]::Max($tabW, [math]::Round(60 * $scale))
$tabW = [math]::Min($tabW, [math]::Round(200 * $scale))
$stripeH = [math]::Max([math]::Round(3 * $scale), 2)
$tab0x = [int]($clientLeft + [math]::Floor($tabW / 2))
$tab1x = [int]($clientLeft + $tabW + [math]::Floor($tabW / 2))
$barMidY = [int]($clientTop + [math]::Floor($barH / 2))
Write-Host "INFO  scale=$scale tabW=$tabW stripeH=$stripeH clientTop=$clientTop tab0x=$tab0x tab1x=$tab1x"

# Baseline: no stripe anywhere before tagging.
Assert (-not (Stripe-HasColor $tab0x $clientTop $stripeH 255 69 58)) 'baseline: tab 0 has no red stripe'

# ---------------------------------------------------------------------------
# Tag tab 0 red via the context menu
# ---------------------------------------------------------------------------
$opened = $false
for ($a = 0; $a -lt 3; $a++) {
    [TabDrv]::GrabForeground($top) | Out-Null
    [TabDrv]::RClick($tab0x, $barMidY)
    Start-Sleep -Milliseconds 600
    if ([TabDrv]::MenuOpen()) { $opened = $true; break }
}
Assert $opened 'context menu: menu window (#32768) opened on tab right-click'
if (-not $opened) { Stop-Process -Id $proc.Id -Force; exit 1 }
Select-TabColor 0x52   # 'R' -> Red
Assert (-not ([TabDrv]::MenuOpen())) 'context menu: closed after selection'

# Move the cursor off the tab bar so hover chrome is out of the picture.
[TabDrv]::SetCursorPos([int]($clientLeft + 50), [int]($clientTop + $barH + 80)) | Out-Null
Start-Sleep -Milliseconds 300

$red = $false
for ($t = 0; $t -lt 15; $t++) {
    if (Stripe-HasColor $tab0x $clientTop $stripeH 255 69 58) { $red = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert $red 'red: tab 0 shows the red accent stripe'
if (-not $red) { Dump-Stripe $tab0x $clientTop $stripeH 'red' }
Assert (-not (Stripe-HasColor $tab1x $clientTop $stripeH 255 69 58)) 'red: tab 1 (untagged) has no stripe'

# ---------------------------------------------------------------------------
# Persistence: activate tab 1; tab 0 keeps its stripe while inactive
# ---------------------------------------------------------------------------
[TabDrv]::LClick($tab1x, $barMidY)
Start-Sleep -Milliseconds 500
[TabDrv]::SetCursorPos([int]($clientLeft + 50), [int]($clientTop + $barH + 80)) | Out-Null
Start-Sleep -Milliseconds 300
Assert (Stripe-HasColor $tab0x $clientTop $stripeH 255 69 58) 'persist: inactive tab 0 keeps its red stripe'
Assert (-not (Stripe-HasColor $tab1x $clientTop $stripeH 255 69 58)) 'persist: active tab 1 still unstriped'

# ---------------------------------------------------------------------------
# Clear: set tab 0 back to None
# ---------------------------------------------------------------------------
$opened = $false
for ($a = 0; $a -lt 3; $a++) {
    [TabDrv]::GrabForeground($top) | Out-Null
    [TabDrv]::RClick($tab0x, $barMidY)
    Start-Sleep -Milliseconds 600
    if ([TabDrv]::MenuOpen()) { $opened = $true; break }
}
Assert $opened 'clear: context menu opened again'
Select-TabColor 0x4E   # 'N' -> None
[TabDrv]::SetCursorPos([int]($clientLeft + 50), [int]($clientTop + $barH + 80)) | Out-Null
Start-Sleep -Milliseconds 400
$cleared = $false
for ($t = 0; $t -lt 15; $t++) {
    if (-not (Stripe-HasColor $tab0x $clientTop $stripeH 255 69 58)) { $cleared = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert $cleared 'clear: None removes the stripe'
if (-not $cleared) { Dump-Stripe $tab0x $clientTop $stripeH 'clear' }

Assert (-not $proc.HasExited) 'no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
