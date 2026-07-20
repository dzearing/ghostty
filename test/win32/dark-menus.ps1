# T79 acceptance: context menus (TrackPopupMenuEx) must match the app
# theme. Pre-fix, both the terminal surface menu and the tab-bar menu drew
# with the classic LIGHT menu palette even on dark chrome.
#
# The fix routes `window-theme` through the undocumented uxtheme ordinals
# (SetPreferredAppMode #135 + FlushMenuThemes #136) at app init / config
# reload / WM_SETTINGCHANGE.
#
# Two GUI launches assert both directions:
#   run 1: --window-theme=dark  -> both menus render DARK  (avg lum < 90)
#   run 2: --window-theme=light -> both menus render LIGHT (avg lum > 160)
#
# Menus are found as visible '#32768' (menu-class) windows in the GUI's
# pid, opened by REAL right-clicks (SetCursorPos + SendInput, foreground
# verified) — the surface menu via a click in the pane, the tab-bar menu
# via a click in the tab strip (window-show-tab-bar=always keeps it
# visible with one tab). The interior is screenshotted (8px inset skips
# the shadow/rounded border) and averaged. A menu that never appears is a
# SETUP FAIL (injection broken), not a theme verdict.
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-darkmenutest'
}

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class MenuDrv {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public MOUSEKEYBD u; }
    // Union of MOUSEINPUT and KEYBDINPUT on x64: the IntPtr at offset 24
    // forces 8-alignment so INPUT is the required 40 bytes.
    [StructLayout(LayoutKind.Explicit, Size = 32)]
    public struct MOUSEKEYBD {
        [FieldOffset(0)] public int dx;
        [FieldOffset(4)] public int dy;
        [FieldOffset(8)] public uint mouseData;
        [FieldOffset(12)] public uint mouseFlags;
        [FieldOffset(16)] public uint time;
        [FieldOffset(24)] public IntPtr extra;
        [FieldOffset(0)] public ushort wVk;
        [FieldOffset(2)] public ushort wScan;
        [FieldOffset(4)] public uint kbFlags;
    }
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static IntPtr FindClass(uint pid, string cls, bool topOnly) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindChild(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static void Mouse(uint flags) {
        var i = new INPUT[1];
        i[0].type = 0; // INPUT_MOUSE
        i[0].u.mouseFlags = flags;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void RightClickAt(int x, int y) {
        SetCursorPos(x, y);
        Thread.Sleep(80);
        Mouse(0x0008); // RIGHTDOWN
        Thread.Sleep(40);
        Mouse(0x0010); // RIGHTUP
    }

    public static void PressEscape() {
        var i = new INPUT[1];
        i[0].type = 1; i[0].u.wVk = 0x1B;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        i[0].u.kbFlags = 2; // KEYUP
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1; i[0].u.wVk = vk;
        i[0].u.kbFlags = up ? 2u : 0u;
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
}
'@
[void][MenuDrv]::SetProcessDPIAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Average brightness (0-255) of the interior of a screen rect,
# 8px inset, sampled on a 4px grid.
function Get-RectBrightness([MenuDrv+RECT]$r) {
    $w = $r.right - $r.left - 16
    $h = $r.bottom - $r.top - 16
    if ($w -le 0 -or $h -le 0) { return -1 }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.left + 8, $r.top + 8, 0, 0, $bmp.Size)
    $g.Dispose()
    $sum = 0.0; $n = 0
    for ($y = 0; $y -lt $h; $y += 4) {
        for ($x = 0; $x -lt $w; $x += 4) {
            $c = $bmp.GetPixel($x, $y)
            $sum += (0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B)
            $n++
        }
    }
    $bmp.Dispose()
    if ($n -eq 0) { return -1 }
    return [int]($sum / $n)
}

# Right-click at a screen point, wait for a '#32768' menu window in $pid,
# measure its interior brightness, Escape it closed. Returns -1 if no
# menu appeared.
function Measure-Menu([uint32]$gpid, [int]$sx, [int]$sy) {
    [MenuDrv]::RightClickAt($sx, $sy)
    $menu = [IntPtr]::Zero
    for ($t = 0; $t -lt 25; $t++) {
        Start-Sleep -Milliseconds 100
        $menu = [MenuDrv]::FindClass($gpid, '#32768', $true)
        if ($menu -ne [IntPtr]::Zero) { break }
    }
    if ($menu -eq [IntPtr]::Zero) { return -1 }
    Start-Sleep -Milliseconds 250   # let the menu finish painting
    $r = New-Object MenuDrv+RECT
    [void][MenuDrv]::GetWindowRect($menu, [ref]$r)
    $b = Get-RectBrightness $r
    [MenuDrv]::PressEscape()
    Start-Sleep -Milliseconds 300
    return $b
}

function Run-Case([string]$label, [string]$themeArg, [bool]$expectDark) {
    Kill-RepoInstances
    $proc = Start-Process -FilePath $exe -PassThru -ArgumentList @(
        $themeArg, '--window-show-tab-bar=always'
    )
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [MenuDrv]::FindClass([uint32]$proc.Id, 'GhozttyWindow', $true)
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    $surface = [MenuDrv]::FindChild($top, 'GhozttyTerminal')
    if ($surface -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): surface not found"; exit 1 }

    [void][MenuDrv]::GrabForeground($top)
    if ([MenuDrv]::GetForegroundWindow() -ne $top) {
        Write-Host "SETUP FAIL ($label): could not foreground the GUI"; Stop-Process -Id $proc.Id -Force; exit 1
    }

    # --- Surface context menu: right-click the middle of the pane.
    $sr = New-Object MenuDrv+RECT
    [void][MenuDrv]::GetWindowRect($surface, [ref]$sr)
    $b = Measure-Menu ([uint32]$proc.Id) ([int](($sr.left + $sr.right) / 2)) ([int](($sr.top + $sr.bottom) / 2))
    if ($b -lt 0) {
        Write-Host "SETUP FAIL ($label): surface menu never appeared (injection broken, not a theme verdict)"
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    if ($expectDark) { Assert ($b -lt 90) "$label surface menu is dark (avg $b < 90)" }
    else { Assert ($b -gt 160) "$label surface menu is light (avg $b > 160)" }

    # --- Tab-bar context menu: right-click inside the tab strip. The tab
    # bar is at the top of the CLIENT area (always visible via config).
    # y=12 device px sits inside the bar at any DPI scale >= 100%.
    $pt = New-Object MenuDrv+POINT; $pt.x = 60; $pt.y = 12
    [void][MenuDrv]::ClientToScreen($top, [ref]$pt)
    $b = Measure-Menu ([uint32]$proc.Id) $pt.x $pt.y
    if ($b -lt 0) {
        Write-Host "SETUP FAIL ($label): tab-bar menu never appeared (injection broken, not a theme verdict)"
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    if ($expectDark) { Assert ($b -lt 90) "$label tab-bar menu is dark (avg $b < 90)" }
    else { Assert ($b -gt 160) "$label tab-bar menu is light (avg $b > 160)" }

    Assert (-not $proc.HasExited) "$label no crash"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

Run-Case 'dark' '--window-theme=dark' $true
Run-Case 'light' '--window-theme=light' $false

Kill-RepoInstances
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
