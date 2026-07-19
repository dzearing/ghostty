# T66 acceptance: reset_window_size returns to the CONFIGURED default
# (window-width/height x cell size - Mac returnToDefaultSize parity),
# not a hardcoded 800x600; with no configured size it falls back to
# 800x600. Also guards the T66 semantic fix that `initial_size`
# re-sends are store-only: a font zoom (ctrl+=) recomputes the stored
# default but must NOT live-resize the window; the next reset returns
# to the recomputed (larger-cell) default.
#
# Oracle: GetClientRect of the top-level GhozttyWindow (harness is
# per-monitor-v2 DPI aware so pixels are physical).
#
# NO focus stealing (converted during T85, 2026-07-19): the original
# SendInput chords need foreground, which is denied while the user works
# (the box is in active use - the script ABORTed every run). Actions are
# now bound to bare F-keys and delivered via PostMessage WM_KEYDOWN/UP to
# the surface HWND - handleKeyEvent reads the VK from wparam and mods
# from GetKeyState (none held in the GUI thread's queue), so bindings
# dispatch without focus. Positive control: f8=toggle_maximize with an
# IsZoomed oracle proves posted-key dispatch works; if it fails the
# script ABORTS (not a T66 verdict).
#
# LOCALAPPDATA is redirected to a throwaway dir so the T85 placement
# memory (written by the maximize control) never leaks between tests.
#
# Only touches ghoztty processes running from this repo's zig-out*.
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
public class RszDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
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

    // All visible top-level GhozttyWindow hwnds for a pid.
    public static long[] Tops(uint pid) {
        var found = new List<long>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") found.Add(h.ToInt64());
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // First visible GhozttyTerminal child (chord focus target).
    public static IntPtr Pane(IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // "width,height" of the client area.
    public static string Client(IntPtr top) {
        RECT r; GetClientRect(top, out r);
        return (r.right - r.left) + "," + (r.bottom - r.top);
    }

    // Grow the WINDOW rect by dw x dh, keeping position.
    public static void Resize(IntPtr top, int dw, int dh) {
        RECT r; GetWindowRect(top, out r);
        SetWindowPos(top, IntPtr.Zero, 0, 0, (r.right - r.left) + dw, (r.bottom - r.top) + dh, 0x0004 | 0x0002); // NOZORDER|NOMOVE
    }

    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint mapType);

    // Deliver a bare (modifier-less) key press to the surface HWND via
    // posted WM_KEYDOWN/WM_KEYUP. No focus/foreground needed (T85).
    public static void PostKey(IntPtr surface, ushort vk, int count) {
        uint scan = MapVirtualKeyW(vk, 0); // MAPVK_VK_TO_VSC
        IntPtr down = (IntPtr)(1 | (scan << 16));
        IntPtr up = (IntPtr)unchecked((long)(1u | (scan << 16) | 0xC0000000u));
        for (int n = 0; n < count; n++) {
            PostMessageW(surface, 0x0100, (IntPtr)vk, down); // WM_KEYDOWN
            Thread.Sleep(40);
            PostMessageW(surface, 0x0101, (IntPtr)vk, up);   // WM_KEYUP
            Thread.Sleep(80);
        }
    }
}
'@
[RszDrv]::BeDpiAware()

function Parse-WH([string]$s) {
    $c = $s -split ','
    @([int]$c[0], [int]$c[1])
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Throwaway LOCALAPPDATA: keeps the T85 placement memory out of real state.
$script:fakeLocal = Join-Path $env:TEMP ("ghoztty-t66-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $script:fakeLocal | Out-Null

# Poll until the client area equals "w,h" (exact) or times out; returns
# the last observed "w,h".
function Wait-Client([IntPtr]$top, [string]$want, [int]$ms = 4000) {
    $last = ''
    for ($t = 0; $t -lt [int]($ms / 200); $t++) {
        Start-Sleep -Milliseconds 200
        $last = [RszDrv]::Client($top)
        if ($last -eq $want) { return $last }
    }
    return $last
}

# Sets $script:proc / $script:top (returning an array trips PS unwrap
# rules with multiple-assignment).
function Launch([string[]]$configArgs) {
    Kill-RepoInstances
    $cliArgs = @(
        '--keybind=f9=reset_window_size'
        '--keybind=f8=toggle_maximize'
        '--keybind=f7=increase_font_size:1'
    ) + $configArgs
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $script:fakeLocal
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $cliArgs -PassThru
    } finally {
        $env:LOCALAPPDATA = $savedLocal
    }
    Start-Sleep -Seconds 3
    if ($p.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $tops = [RszDrv]::Tops([uint32]$p.Id)
    if ($tops.Count -ne 1) { Write-Host "SETUP FAIL: expected 1 top window, got $($tops.Count)"; exit 1 }
    $script:proc = $p
    $script:top = [IntPtr]$tops[0]
}

# --- Case A: configured window-width/height ------------------------------
# 120x20 cells is far from any cell-size multiple that lands on exactly
# 800x600 px, so "initial != 800x600" is a meaningful assert.
Launch @('--window-width=120', '--window-height=20')
$pane = [RszDrv]::Pane($top)
if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane'; exit 1 }

$init = [RszDrv]::Client($top)
$initW, $initH = Parse-WH $init
Write-Host "INFO  configured initial client = $init"
Assert ($initW -gt 0 -and $initH -gt 0) "cfg: initial client size readable ($init)"
Assert (-not ($initW -eq 800 -and $initH -eq 600)) 'cfg: configured size is not the 800x600 fallback'

# Positive control: posted f8 must maximize (posted-key dispatch works).
[RszDrv]::PostKey($pane, 0x77, 1)   # VK_F8
$zoomed = $false
for ($t = 0; $t -lt 15; $t++) { Start-Sleep -Milliseconds 200; if ([RszDrv]::IsZoomed($top)) { $zoomed = $true; break } }
if (-not $zoomed) {
    Write-Host 'ABORT: posted f8 did not maximize - key injection/binding broken, not a T66 verdict'
    Stop-Process -Id $proc.Id -Force; exit 1
}
Write-Host 'OK    positive control: posted f8 maximized the window'
[RszDrv]::PostKey($pane, 0x77, 1)   # restore
Start-Sleep -Milliseconds 600
Assert (-not [RszDrv]::IsZoomed($top)) 'cfg: posted f8 again restored the window'

# Resize away from the default, then reset must return EXACTLY to it.
[RszDrv]::Resize($top, 240, 130)
Start-Sleep -Milliseconds 400
$stretched = [RszDrv]::Client($top)
Assert ($stretched -ne $init) "cfg: manual resize changed the client area ($init -> $stretched)"
[RszDrv]::PostKey($pane, 0x78, 1)   # VK_F9 = reset_window_size
$after = Wait-Client $top $init
Assert ($after -eq $init) "cfg: reset returned to configured size ($after == $init), not 800x600"

# Font zoom: initial_size re-sends are STORE-ONLY - the window must not
# live-resize - but reset afterwards goes to the recomputed default.
[RszDrv]::PostKey($pane, 0x76, 3)   # VK_F7 = increase_font_size x3
Start-Sleep -Milliseconds 900
$afterZoom = [RszDrv]::Client($top)
Assert ($afterZoom -eq $init) "cfg: font zoom did not live-resize the window ($afterZoom == $init)"
[RszDrv]::PostKey($pane, 0x78, 1)   # VK_F9 = reset_window_size
Start-Sleep -Milliseconds 1200
$reset2 = [RszDrv]::Client($top)
$r2W, $r2H = Parse-WH $reset2
Assert ($r2W -gt $initW -and $r2H -gt $initH) "cfg: reset after zoom used the RECOMPUTED default ($reset2 > $init)"

Assert (-not $proc.HasExited) 'cfg: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# --- Case B: no configured size -> 800x600 fallback ----------------------
Launch @()
$pane = [RszDrv]::Pane($top)
if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane (case B)'; exit 1 }

[RszDrv]::Resize($top, 220, 140)
Start-Sleep -Milliseconds 400
$before = [RszDrv]::Client($top)
[RszDrv]::PostKey($pane, 0x78, 1)   # VK_F9 = reset_window_size
$after = Wait-Client $top '800,600'
Assert ($after -eq '800,600') "fallback: reset with no configured size went to 800x600 (was $before, got $after)"
Assert (-not $proc.HasExited) 'fallback: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Remove-Item -Recurse -Force $script:fakeLocal -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }

