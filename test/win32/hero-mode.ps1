# Hero-mode geometry oracle (T19 acceptance, T49 regression guard).
#
# Drives REAL key chords into the debug build and asserts pane geometry:
#   1. 3-pane layout renders as a tree (3 visible terminal children).
#   2. ctrl+shift+space toggles hero mode: one pane fills ~75% width at
#      full height on the left, the other two stack in the right column.
#   3. ctrl+alt+down moves the hero selection (big-left HWND changes).
#   4. ctrl+shift+space again restores the exact tree geometry.
#
# A positive control (ctrl+shift+r, proven by kb-actions.ps1 / T44) runs
# first so an injection failure is distinguishable from a hero regression;
# it is verified via the Debug build's stderr binding-dispatch log line
# (the rename EDIT itself is killed by focus churn too fast to poll from
# PowerShell in a multi-pane window). Control fails -> ABORT (environment),
# control passes but hero fails -> real bug.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
# -ExePath: test a different build (e.g. zig-out-release\bin\ghoztty.exe).
# A non-default exe gets an isolated pipe (GHOZTTY_PIPE_SUFFIX) so the run
# never talks to the installed release instance. Release builds emit no
# debug log, so the log-based assertions auto-skip (geometry is the verdict).
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-herotest'
}
$errlog = Join-Path $env:TEMP "ghoztty-hero-mode-stderr.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

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
public class HeroDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT r, uint points);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
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

    // Visible GhozttyTerminal children with rects in the top window's
    // client coordinates, as "hwnd:left,top,right,bottom" lines.
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                MapWindowPoints(IntPtr.Zero, top, ref r, 2);
                lines.Add(h.ToInt64() + ":" + r.left + "," + r.top + "," + r.right + "," + r.bottom);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    public static int[] ClientSize(IntPtr top) {
        RECT r; GetClientRect(top, out r);
        return new int[] { r.right - r.left, r.bottom - r.top };
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Send mods+vk with focus on `surface`. Returns "SENT" or a reason.
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

# Rect parsing helpers ---------------------------------------------------------
function Parse-Panes([string[]]$lines) {
    $lines | ForEach-Object {
        $hw, $r = $_ -split ':'
        $c = $r -split ','
        [pscustomobject]@{
            Hwnd = [int64]$hw
            Left = [int]$c[0]; Top = [int]$c[1]; Right = [int]$c[2]; Bottom = [int]$c[3]
            Width = [int]$c[2] - [int]$c[0]; Height = [int]$c[3] - [int]$c[1]
        }
    }
}
function Rects-Equal($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    $am = @{}; $a | ForEach-Object { $am[$_.Hwnd] = "$($_.Left),$($_.Top),$($_.Right),$($_.Bottom)" }
    foreach ($p in $b) {
        if ($am[$p.Hwnd] -ne "$($p.Left),$($p.Top),$($p.Right),$($p.Bottom)") { return $false }
    }
    return $true
}

# --- Setup: fresh debug instance with a 3-pane layout ------------------------
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# GUI-subsystem (release) exes reject stderr redirection pairing oddly in
# some hosts; redirect only for the Console-subsystem debug build.
if ($ExePath) { $proc = Start-Process -FilePath $exe -PassThru }
else { $proc = Start-Process -FilePath $exe -PassThru -RedirectStandardError $errlog }
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [HeroDrv]::FindTop([uint32]$proc.Id)
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

& $exe +split --direction=down --name=herob | Out-Null
Start-Sleep -Milliseconds 800
& $exe +split --direction=down --name=heroc | Out-Null
Start-Sleep -Milliseconds 800

$tree = Parse-Panes ([HeroDrv]::Panes($top))
$client = [HeroDrv]::ClientSize($top)
Assert ($tree.Count -eq 3) "setup: 3 visible panes in tree layout (got $($tree.Count))"
if ($tree.Count -ne 3) { Stop-Process -Id $proc.Id -Force; exit 1 }

# Focus target for the toggle: the topmost-leftmost pane (leaf 0).
$leaf0 = ($tree | Sort-Object Top, Left | Select-Object -First 1)
$leaf0Hwnd = [IntPtr]$leaf0.Hwnd

# --- Positive control: ctrl+shift+r reaches binding dispatch (T44-proven) ----
# Debug builds prove it via the stderr binding-dispatch log; release builds
# have no log, so the control degrades to chord delivery only.
$haveLog = (Test-Path $errlog)
$r = [HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(0x11, 0x10), 0x52)
if ($r -ne 'SENT') { Write-Host "ABORT: control chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
Start-Sleep -Milliseconds 300
if ($haveLog) {
    if (-not (Select-String -Path $errlog -Pattern 'prompt_surface_title' -Quiet)) {
        Write-Host 'ABORT: positive control failed (prompt_surface_title never dispatched) - injection broken, not a hero verdict'
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    Write-Host 'OK    positive control: injection reaches bindings (prompt_surface_title dispatched)'
} else {
    Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
}
[HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(), 0x1B) | Out-Null   # Escape cancels any rename edit
Start-Sleep -Milliseconds 300

# --- Toggle hero mode on ------------------------------------------------------
$r = [HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(0x11, 0x10), 0x20)  # ctrl+shift+space
Assert ($r -eq 'SENT') "hero toggle chord delivered ($r)"
Start-Sleep -Milliseconds 500
Assert (-not $proc.HasExited) 'no crash after hero toggle'
if ($haveLog) {
    Assert ((Select-String -Path $errlog -Pattern 'toggle_hero_mode' -Quiet)) 'toggle_hero_mode binding dispatched (log)'
}

$hero = Parse-Panes ([HeroDrv]::Panes($top))
Assert ($hero.Count -eq 3) "hero: still 3 visible panes (got $($hero.Count))"
$big = $hero | Sort-Object Width -Descending | Select-Object -First 1
$rest = @($hero | Where-Object { $_.Hwnd -ne $big.Hwnd })
$heroOn = ($big.Width -ge [int](0.6 * $client[0])) -and
          ($big.Height -ge [int](0.9 * $client[1])) -and
          ($rest.Count -eq 2) -and
          ($rest[0].Left -gt $big.Right - 5) -and ($rest[1].Left -gt $big.Right - 5) -and
          ($rest[0].Left -eq $rest[1].Left) -and
          ([Math]::Abs($rest[0].Top - $rest[1].Top) -gt 10)
Assert $heroOn 'hero geometry: big full-height left pane + two stacked right-column panes'
Assert ($big.Hwnd -eq $leaf0.Hwnd) 'hero seeds from the focused pane (leaf 0 is the hero)'

# --- Navigate: ctrl+alt+down moves the hero selection ------------------------
$r = [HeroDrv]::Chord($top, [IntPtr]$big.Hwnd, [uint16[]]@(0x11, 0x12), 0x28)
Assert ($r -eq 'SENT') "hero nav chord delivered ($r)"
Start-Sleep -Milliseconds 500
$hero2 = Parse-Panes ([HeroDrv]::Panes($top))
$big2 = $hero2 | Sort-Object Width -Descending | Select-Object -First 1
Assert ($big2.Hwnd -ne $big.Hwnd) 'ctrl+alt+down moved the hero (big-left pane changed)'

# --- Toggle hero mode off: exact tree geometry restored -----------------------
$r = [HeroDrv]::Chord($top, [IntPtr]$big2.Hwnd, [uint16[]]@(0x11, 0x10), 0x20)
Assert ($r -eq 'SENT') "hero un-toggle chord delivered ($r)"
Start-Sleep -Milliseconds 500
Assert (-not $proc.HasExited) 'no crash after hero un-toggle'
$after = Parse-Panes ([HeroDrv]::Panes($top))
Assert (Rects-Equal $tree $after) 'tree geometry restored exactly after toggle-off'

# --- Teardown ----------------------------------------------------------------
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
