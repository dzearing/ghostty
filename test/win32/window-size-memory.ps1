# T85 acceptance: new windows remember the last user-chosen size.
#
# Memory precedence: explicit window-width/height config > remembered
# placement (%LOCALAPPDATA%\ghoztty\window_placement-debug for Debug
# builds) > 800x600 default. Only USER-interactive changes persist:
# drag resizes (WM_EXITSIZEMOVE) and maximize/restore transitions.
# Programmatic resizes (initial_size, reset_window_size) never write it,
# so reset_window_size stays the escape hatch (T66 semantics intact).
#
# Isolation: LOCALAPPDATA is pointed at a throwaway temp dir for every
# launched instance, so this script never touches the real user memory.
#
# Interactive resizes are simulated with the real message sequence a drag
# produces: WM_ENTERSIZEMOVE -> SetWindowPos -> WM_EXITSIZEMOVE (the
# product code reads GetWindowRect at WM_EXITSIZEMOVE, exactly what a
# mouse drag exercises). Maximize/restore transitions go through the real
# WM_SYSCOMMAND path.
#
# NO focus stealing: this script must run while the user works. Instead
# of SendInput chords (which need foreground and are denied/rude when the
# user is active), actions are bound to bare F-keys and delivered with
# PostMessage WM_KEYDOWN/WM_KEYUP to the surface HWND — handleKeyEvent
# reads the VK from wparam and modifiers from GetKeyState (none held in
# the GUI thread's queue), so the binding dispatches without focus.
# Positive control (T55 pattern): f8=toggle_maximize with an IsZoomed
# oracle proves posted-key dispatch works before the reset assert depends
# on it; on failure the script ABORTS (not a T85 verdict).
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
public class WszDrv {
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
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint p, out RECT r, uint winini);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT { public uint length, flags, showCmd; public int ptMinX, ptMinY, ptMaxX, ptMaxY; public RECT rcNormal; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() {
        SetProcessDpiAwarenessContext((IntPtr)(-4)); // PER_MONITOR_AWARE_V2
    }

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

    // "width,height" of the OUTER window rect.
    public static string Outer(IntPtr top) {
        RECT r; GetWindowRect(top, out r);
        return (r.right - r.left) + "," + (r.bottom - r.top);
    }

    public static string Client(IntPtr top) {
        RECT r; GetClientRect(top, out r);
        return (r.right - r.left) + "," + (r.bottom - r.top);
    }

    // Restored (normal) outer size, valid while maximized.
    public static string NormalSize(IntPtr top) {
        var p = new WINDOWPLACEMENT();
        p.length = (uint)Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        GetWindowPlacement(top, ref p);
        return (p.rcNormal.right - p.rcNormal.left) + "," + (p.rcNormal.bottom - p.rcNormal.top);
    }

    public static string WorkArea() {
        RECT r; SystemParametersInfoW(0x0030, 0, out r, 0); // SPI_GETWORKAREA
        return (r.right - r.left) + "," + (r.bottom - r.top);
    }

    // Simulate a user drag-resize: the exact message sequence a real drag
    // produces around the size change.
    public static void DragResize(IntPtr top, int dw, int dh) {
        SendMessageW(top, 0x0231, IntPtr.Zero, IntPtr.Zero); // WM_ENTERSIZEMOVE
        RECT r; GetWindowRect(top, out r);
        SetWindowPos(top, IntPtr.Zero, 0, 0, (r.right - r.left) + dw, (r.bottom - r.top) + dh, 0x0004 | 0x0002);
        Thread.Sleep(100);
        SendMessageW(top, 0x0232, IntPtr.Zero, IntPtr.Zero); // WM_EXITSIZEMOVE
    }

    // Real maximize/restore via the system command path.
    public static void SysMaximize(IntPtr top) { SendMessageW(top, 0x0112, (IntPtr)0xF030, IntPtr.Zero); }
    public static void SysRestore(IntPtr top)  { SendMessageW(top, 0x0112, (IntPtr)0xF120, IntPtr.Zero); }

    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint mapType);

    // Deliver a bare (modifier-less) key press to the surface HWND via
    // posted WM_KEYDOWN/WM_KEYUP. No focus/foreground needed.
    public static void PostKey(IntPtr surface, ushort vk) {
        uint scan = MapVirtualKeyW(vk, 0); // MAPVK_VK_TO_VSC
        IntPtr down = (IntPtr)(1 | (scan << 16));
        IntPtr up = (IntPtr)unchecked((long)(1u | (scan << 16) | 0xC0000000u));
        PostMessageW(surface, 0x0100, (IntPtr)vk, down); // WM_KEYDOWN
        Thread.Sleep(40);
        PostMessageW(surface, 0x0101, (IntPtr)vk, up);   // WM_KEYUP
        Thread.Sleep(60);
    }
}
'@
[WszDrv]::BeDpiAware()

# Throwaway LOCALAPPDATA so the real user memory is never touched.
$fakeLocal = Join-Path $env:TEMP ("ghoztty-t85-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
$memFile = Join-Path $fakeLocal 'ghoztty\window_placement-debug'

function Read-Mem {
    if (Test-Path $memFile) { (Get-Content $memFile -Raw).Trim() } else { '<absent>' }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Poll until the memory file's content equals $want, return last content.
function Wait-Mem([string]$want, [int]$ms = 4000) {
    $last = ''
    for ($t = 0; $t -lt [int]($ms / 200); $t++) {
        Start-Sleep -Milliseconds 200
        $last = Read-Mem
        if ($last -eq $want) { return $last }
    }
    return $last
}

# Launch with LOCALAPPDATA redirected; sets $script:proc / $script:top.
function Launch([string[]]$configArgs) {
    Kill-RepoInstances
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        $cliArgs = @(
            '--keybind=f9=reset_window_size'
            '--keybind=f8=toggle_maximize'
        ) + $configArgs
        $p = Start-Process -FilePath $exe -ArgumentList $cliArgs -PassThru
    } finally {
        $env:LOCALAPPDATA = $savedLocal
    }
    Start-Sleep -Seconds 3
    if ($p.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $tops = [WszDrv]::Tops([uint32]$p.Id)
    if ($tops.Count -ne 1) { Write-Host "SETUP FAIL: expected 1 top window, got $($tops.Count)"; exit 1 }
    $script:proc = $p
    $script:top = [IntPtr]$tops[0]
}

function Stop-Instance {
    Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
}

# --- Case A: fresh memory -> default, drag-resize persists ----------------
Launch @()
Assert ((Read-Mem) -eq '<absent>') 'A: fresh profile has no memory file'
$init = [WszDrv]::Outer($top)
Assert ($init -eq '800,600') "A: no config + no memory opens at the 800x600 default (got $init)"

[WszDrv]::DragResize($top, 150, 100)
$mem = Wait-Mem '950 700 0'
Assert ($mem -eq '950 700 0') "A: drag-resize persisted '950 700 0' (got '$mem')"
Assert (-not $proc.HasExited) 'A: no crash'
Stop-Instance

# --- Case B: new window opens at the remembered size ----------------------
Launch @()
$outer = [WszDrv]::Outer($top)
Assert ($outer -eq '950,700') "B: relaunch opened at remembered 950,700 (got $outer)"

# Positive control: posted f8 (toggle_maximize) must zoom the window —
# proves posted-key binding dispatch works before Case C's reset assert
# depends on it. Also persists the maximize via the real action path.
$pane = [WszDrv]::Pane($top)
if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane'; exit 1 }
[WszDrv]::PostKey($pane, 0x77)   # VK_F8
$zoomed = $false
for ($t = 0; $t -lt 15; $t++) { Start-Sleep -Milliseconds 200; if ([WszDrv]::IsZoomed($top)) { $zoomed = $true; break } }
if (-not $zoomed) {
    Write-Host 'ABORT: posted f8 did not maximize - key injection/binding broken, not a T85 verdict'
    Stop-Instance; exit 1
}
Write-Host 'OK    positive control: posted f8 maximized the window'
$mem = Wait-Mem '950 700 1'
Assert ($mem -eq '950 700 1') "B: maximize persisted flag + RESTORED size (got '$mem')"
Stop-Instance   # killed while maximized -> memory says maximized

# --- Case C: maximized memory -> opens maximized, restores to normal size -
Launch @()
Assert ([WszDrv]::IsZoomed($top)) 'C: relaunch with maximized memory opened maximized'
$normal = [WszDrv]::NormalSize($top)
Assert ($normal -eq '950,700') "C: restored size underneath is the remembered 950,700 (got $normal)"
[WszDrv]::SysRestore($top)
$mem = Wait-Mem '950 700 0'
Assert ($mem -eq '950 700 0') "C: restore transition persisted maximized=0 (got '$mem')"
$outer = [WszDrv]::Outer($top)
Assert ($outer -eq '950,700') "C: restore returned to 950,700 (got $outer)"

# reset_window_size is the escape hatch: client returns to the 800x600
# default (no config), and the MEMORY FILE is untouched (programmatic).
$pane = [WszDrv]::Pane($top)
if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane (case C)'; exit 1 }
[WszDrv]::PostKey($pane, 0x78)   # VK_F9 = reset_window_size
$client = ''
for ($t = 0; $t -lt 20; $t++) { Start-Sleep -Milliseconds 200; $client = [WszDrv]::Client($top); if ($client -eq '800,600') { break } }
Assert ($client -eq '800,600') "C: reset_window_size still resets to the default client size (got $client)"
$mem = Read-Mem
Assert ($mem -eq '950 700 0') "C: reset did NOT rewrite the memory (got '$mem')"
Assert (-not $proc.HasExited) 'C: no crash'
Stop-Instance

# --- Case D: explicit config wins over the memory -------------------------
# Reference: config size with NO memory.
Remove-Item $memFile -Force
Launch @('--window-width=120', '--window-height=20')
$cfgRef = [WszDrv]::Client($top)
Assert ($cfgRef -ne '800,600') "D: configured 120x20 produces a non-default client ($cfgRef)"
Stop-Instance
# Same config with a very different memory: client must be identical.
Set-Content -Path $memFile -Value '950 700 0' -Encoding Ascii
Launch @('--window-width=120', '--window-height=20')
$cfgMem = [WszDrv]::Client($top)
Assert ($cfgMem -eq $cfgRef) "D: config beat the memory ($cfgMem == $cfgRef)"
Assert (-not $proc.HasExited) 'D: no crash'
Stop-Instance

# --- Case E: remembered size is clamped to the work area ------------------
Set-Content -Path $memFile -Value '25000 25000 0' -Encoding Ascii
Launch @()
$outer = [WszDrv]::Outer($top)
$ow, $oh = ($outer -split ',') | ForEach-Object { [int]$_ }
$wa = [WszDrv]::WorkArea()
$ww, $wh = ($wa -split ',') | ForEach-Object { [int]$_ }
Assert ($ow -le $ww -and $oh -le $wh) "E: oversized memory clamped to work area ($outer <= $wa)"
Assert (-not $proc.HasExited) 'E: no crash'
Stop-Instance

# --- Case F: corrupt memory file falls back to the default ----------------
Set-Content -Path $memFile -Value 'not a placement' -Encoding Ascii
Launch @()
$outer = [WszDrv]::Outer($top)
Assert ($outer -eq '800,600') "F: corrupt memory ignored, default used (got $outer)"
Assert (-not $proc.HasExited) 'F: no crash'
Stop-Instance

Remove-Item -Recurse -Force $fakeLocal -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
