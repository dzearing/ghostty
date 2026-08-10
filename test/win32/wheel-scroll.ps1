# Wheel-scroll acceptance (T40): one wheel notch must scroll exactly 3
# lines -- the core's mouse-scroll-multiplier discrete default, which
# matches the Windows 3-lines-per-notch convention (Windows Terminal
# default). Guards against two regressions found while investigating
# T40: dropping to 1 line/notch (raw notch with no multiplier) and
# jumping to 9 (double-applying SPI_GETWHEELSCROLLLINES on top of the
# config default -- see handleMouseWheel in apprt/win32/Surface.zig).
#
# Oracle: a pane enters the alternate screen with alternate-scroll mode
# (ESC[?1049h + ESC[?1007h) and counts arrow-key presses arriving on its
# stdin -- exactly how a TUI like Claude Code experiences the wheel. The
# driver posts real WM_MOUSEWHEEL messages to the surface HWND (delta
# +120 = one notch up, two notches down) and asserts:
#   up-arrows   == 1 * 3
#   down-arrows == 2 * 3
#
# Only touches ghoztty processes running from this repo's zig-out.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WheelDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
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

    // Post one WM_MOUSEWHEEL with the given detent delta (+120 up, -120
    // down) straight to the surface HWND. The handler only reads the
    // delta from wParam, so lParam coords and focus do not matter.
    public static void Notch(IntPtr surface, int delta) {
        IntPtr w = (IntPtr)((long)((uint)((delta & 0xFFFF) << 16)));
        PostMessageW(surface, 0x020A, w, IntPtr.Zero);
    }
}
'@

# The expected lines-per-notch: mouse-scroll-multiplier discrete default.
$wheelLines = 3

# --- Setup: fresh debug instance ---------------------------------------------
# T248: the sibling agent and the debug session-layout manifest go too. This
# script scrolls a pane and counts lines against what it just wrote — a pane
# RESTORED from the previous run arrives with a scrollback nobody here filled.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: a per-run IPC endpoint on top of CleanSlate's T118 unbaking, so this run
# cannot collide with another debug instance (they all share the one derived
# `-debug` endpoint) and cannot fall back onto the user's release if zig-out
# ever holds a non-Debug build.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'wheel')

Reset-GhozttyTestState -Exe $exe -SettleMs 500 | Out-Null
Assert-GhozttyPrivateEndpoint -Exe $exe

# persistence: off. The wheel assertions want the ONE pane this launch opens; a
# restored second window would take the foreground and the scroll would land in
# it (T158).
$proc = Start-Process -FilePath $exe -ArgumentList '--session-persistence=false' -PassThru
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
Assert-GhozttyIsolated -Exe $exe
$top = [WheelDrv]::FindTop([uint32]$proc.Id)
$surface = [WheelDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: windows not found'; exit 1 }

$listJson = & $exe +list --json | ConvertFrom-Json
$pane = $listJson.data.windows[0].tabs[0].splits.terminal.name
if (-not $pane) { Write-Host 'SETUP FAIL: no pane name from +list'; exit 1 }

# --- Counter: alt screen + alternate scroll, counts arrow keys ---------------
$counter = Join-Path $env:TEMP 'ghoztty-wheel-counter.ps1'
@'
$esc = [char]27
[Console]::Write("$esc[?1049h$esc[?1007h")
[Console]::Write("COUNTERREADY")
$up = 0; $down = 0; $rawA = 0; $rawB = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 10) {
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'UpArrow') { $up++ }
        elseif ($k.Key -eq 'DownArrow') { $down++ }
        elseif ($k.KeyChar -eq 'A') { $rawA++ }
        elseif ($k.KeyChar -eq 'B') { $rawB++ }
    } else { Start-Sleep -Milliseconds 10 }
}
[Console]::Write("$esc[?1007l$esc[?1049l")
Write-Output "WHEELCOUNT UP=$($up + $rawA) DOWN=$($down + $rawB)"
'@ | Set-Content -Path $counter -Encoding ascii

& $exe +send-keys --target=$pane "powershell -NoProfile -ExecutionPolicy Bypass -File $counter" Enter | Out-Null

# Wait until the counter is live inside the alt screen.
$ready = $false
for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
    Start-Sleep -Milliseconds 250
    $tail = & $exe +read --name=$pane --lines=10 2>$null
    if ($tail -match 'COUNTERREADY') { $ready = $true }
}
Assert $ready 'counter entered alt screen (COUNTERREADY visible)'
if (-not $ready) { Stop-Process -Id $proc.Id -Force; exit 1 }

# --- Drive: 1 notch up, 2 notches down ---------------------------------------
Start-Sleep -Milliseconds 300
[WheelDrv]::Notch($surface, 120)
Start-Sleep -Milliseconds 300
[WheelDrv]::Notch($surface, -120)
Start-Sleep -Milliseconds 300
[WheelDrv]::Notch($surface, -120)

# Wait for the counter's 10s window to finish and the summary to print.
$result = $null
for ($i = 0; $i -lt 60 -and -not $result; $i++) {
    Start-Sleep -Milliseconds 500
    $tail = & $exe +read --name=$pane --lines=10 2>$null
    $m = $tail | Select-String -Pattern 'WHEELCOUNT UP=(\d+) DOWN=(\d+)'
    if ($m) { $result = $m.Matches[0] }
}

Assert ($null -ne $result) 'counter printed WHEELCOUNT summary'
if ($result) {
    $up = [int]$result.Groups[1].Value
    $down = [int]$result.Groups[2].Value
    Write-Host "Measured: 1 notch up -> $up lines; 2 notches down -> $down lines"
    Assert ($up -eq $wheelLines) "one notch up scrolls 3 lines ($up == $wheelLines)"
    Assert ($down -eq 2 * $wheelLines) "two notches down scroll 6 lines ($down == $(2 * $wheelLines))"
}

# --- Teardown -----------------------------------------------------------------
& $exe +close --target=$pane 2>$null | Out-Null
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $counter -ErrorAction SilentlyContinue

if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) of $($script:pass + $script:fail)"; exit 1 }
