# T48 regression: deferred SetFocus (release GUI deadlock).
#
# The release GUI froze because SetFocus was called synchronously inside a
# WndProc (mouse-button / focus-forward handlers). SetFocus runs the IME/CTF
# activation cascade inline, which does a synchronous SendMessage that
# re-enters our WindowProc; on that nested, non-pumping stack the GUI thread
# could Condition.wait() forever (see docs/design/t48-deadlock-dump-analysis.md).
# The fix posts WM_APP_SETFOCUS and performs the real SetFocus at the top of
# the message loop instead.
#
# This test drives the EXACT fixed path without needing foreground focus:
# it PostMessage's real WM_LBUTTONDOWN/UP into each terminal surface HWND
# (-> surfaceWndProc mouse handler -> deferSetFocus). It asserts:
#   1. Deferred focus actually MOVES real GUI focus to the clicked pane
#      (read cross-thread via GetGUIThreadInfo().hwndFocus).
#   2. Under rapid click churn + heavy terminal output (the deadlock's
#      load shape), the GUI thread stays RESPONSIVE: SendMessageTimeout
#      (SMTO_ABORTIFHUNG) returns before timeout and +list still answers
#      (the IPC listener lives on the GUI thread, so a hung thread = no reply).
#
# Non-interactive; only ever touches ghoztty processes from the repo zig-out.
#   powershell -NoProfile -File test\win32\focus-defer.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $Exe)) { $Exe = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'zig-out\bin\ghoztty.exe' }

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # Kill any orphaned flood shell from the click-storm phase.
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
        Where-Object { $_.CommandLine -like '*FD-LOAD*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class FocusDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr res);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public int cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO gti);

    const uint WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, WM_NULL = 0x0000;
    const uint SMTO_ABORTIFHUNG = 0x0002, SMTO_BLOCK = 0x0001;

    static bool IsClass(IntPtr h, string cls) {
        var sb = new StringBuilder(64); GetClassNameW(h, sb, 64); return sb.ToString() == cls;
    }
    public static IntPtr FindTop(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && IsClass(h, "GhozttyWindow")) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // Terminal surface child HWNDs (GhozttyTerminal), in z-order.
    public static IntPtr[] FindSurfaces(IntPtr top) {
        var list = new System.Collections.Generic.List<IntPtr>();
        EnumChildWindows(top, (h, l) => { if (IsClass(h, "GhozttyTerminal")) list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    // One real left click at a valid client point (10,10).
    public static void Click(IntPtr surface) {
        IntPtr lp = (IntPtr)((10) | (10 << 16));
        PostMessageW(surface, WM_LBUTTONDOWN, IntPtr.Zero, lp);
        PostMessageW(surface, WM_LBUTTONUP, IntPtr.Zero, lp);
    }
    // Click a pane, then wait up to timeoutMs for the GUI thread's real
    // keyboard focus to land on it (proves the deferred SetFocus fired).
    public static bool ClickAndFocused(IntPtr top, IntPtr surface, int timeoutMs) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        Click(surface);
        for (int t = 0; t < timeoutMs; t += 15) {
            Thread.Sleep(15);
            var gti = new GUITHREADINFO(); gti.cbSize = Marshal.SizeOf(gti);
            if (GetGUIThreadInfo(tid, ref gti) && gti.hwndFocus == surface) return true;
        }
        return false;
    }
    // Hammer clicks round-robin across all panes.
    public static void ClickStorm(IntPtr[] surfaces, int rounds) {
        for (int r = 0; r < rounds; r++)
            foreach (var s in surfaces) Click(s);
    }
    // True if the GUI thread pumps a WM_NULL within timeoutMs (not hung).
    public static bool Responsive(IntPtr top, uint timeoutMs) {
        IntPtr res;
        IntPtr ok = SendMessageTimeoutW(top, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG | SMTO_BLOCK, timeoutMs, out res);
        return ok != IntPtr.Zero;
    }
}
'@

Stop-DebugGhoztty
$tmp = Join-Path $env:TEMP "ghoztty-focus-defer-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
function Get-List { cmd /c "`"$Exe`" +list > `"$tmp\list.txt`" 2>&1" | Out-Null; Get-Content "$tmp\list.txt" -Raw }

Write-Host "== build a 3-pane window"
& $Exe +new-window --target=fdwin 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $Exe +split --target=fdwin --name=fdb --direction=down 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $Exe +split --target=fdwin --name=fdc --direction=right 2>&1 | Out-Null
Start-Sleep -Seconds 2

$proc = Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.CommandLine -like '*zig-out*' } | Select-Object -First 1
Assert ($null -ne $proc) "debug ghoztty running"
$pid32 = [uint32]$proc.ProcessId
$top = [FocusDrv]::FindTop($pid32)
Assert ($top -ne [IntPtr]::Zero) "found GhozttyWindow top HWND"
$surfaces = [FocusDrv]::FindSurfaces($top)
Assert ($surfaces.Count -ge 3) "found >=3 terminal surface HWNDs (got $($surfaces.Count))"

Write-Host "== deferred focus moves real GUI focus to each clicked pane"
# Click each pane in turn; the deferred SetFocus (posted from the mouse
# WndProc, run at loop top) must land real keyboard focus on that HWND.
$allMoved = $true
foreach ($s in $surfaces) {
    if (-not [FocusDrv]::ClickAndFocused($top, $s, 1500)) { $allMoved = $false }
}
Assert $allMoved "click -> deferred SetFocus focuses each pane"
# And it is not a one-shot: bounce focus back to the first pane.
Assert ([FocusDrv]::ClickAndFocused($top, $surfaces[0], 1500)) "focus bounces back to first pane"

Write-Host "== responsive baseline (before load)"
Assert ([FocusDrv]::Responsive($top, 3000)) "GUI thread pumps WM_NULL (idle)"

Write-Host "== rapid click churn under heavy terminal output"
# Flood one pane with output (the deadlock's load shape), then storm the
# mouse WndProc SetFocus path across all panes. Pre-fix, a re-entrant
# IME/CTF SetFocus on this stack could wedge the GUI thread here.
& $Exe +send-keys --target=fdb "for /L %i in (1,1,150000) do @echo FD-LOAD-%i" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
[FocusDrv]::ClickStorm($surfaces, 500)   # 500 * 3 panes = 1500 focus changes

Write-Host "== still responsive after the storm"
$resp = $false
for ($i = 0; $i -lt 5; $i++) { if ([FocusDrv]::Responsive($top, 3000)) { $resp = $true; break }; Start-Sleep -Milliseconds 200 }
Assert $resp "GUI thread still pumps WM_NULL after click storm"

# The IPC listener runs ON the GUI thread; a reply within timeout proves the
# thread is pumping messages (a hang would leave +list stuck / pipe-busy).
$ipcOk = $false
$job = Start-Job { param($e) & $e +list } -ArgumentList $Exe
if (Wait-Job $job -Timeout 8) { Receive-Job $job | Out-Null; if ($job.State -eq 'Completed') { $ipcOk = $true } }
Remove-Job $job -Force -ErrorAction SilentlyContinue
Assert $ipcOk "+list answers within 8s (GUI-thread IPC listener alive)"

# Focus still controllable after the storm (thread not wedged mid-dispatch).
Assert ([FocusDrv]::ClickAndFocused($top, $surfaces[0], 2000)) "focus still moves after storm"

Write-Host "== teardown"
# Direct kill (not IPC +close): the flood keeps the GUI-thread IPC listener
# busy, so an IPC teardown would just wait on it. Stop-DebugGhoztty also
# reaps the orphaned FD-LOAD flood shell.
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) assertions)"; exit 0 }
else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red; exit 1 }
