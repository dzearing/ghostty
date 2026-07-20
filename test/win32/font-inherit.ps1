# T76 acceptance: `window-inherit-font-size` — a new split/window must
# inherit the focused pane's LIVE (ctrl+= zoomed) font size when the
# option is on (default), and snap back to the configured font-size when
# it is off.
#
# Oracle: grid columns reported by `mode con` inside each pane. All test
# panes are full-window-width down-splits, so same font <=> same column
# count; a bigger font <=> fewer columns. The new-window path (different
# pixel width) is asserted via estimated cell width = pane_px_width/cols.
#
# Positive control: the ctrl+= zoom itself — if columns do not shrink
# after 6 chords, input injection is broken and the script ABORTS (not a
# T76 verdict), per the T55 pattern.
#
# Two GUI launches: default (inherit on) and --window-inherit-font-size=false.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-fontinherittest'
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
public class FontDrv {
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
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

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

    // Visible GhozttyTerminal children: "hwnd:left,top,right,bottom" lines.
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                lines.Add(h.ToInt64() + ":" + r.left + "," + r.top + "," + r.right + "," + r.bottom);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
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
    // background process may not steal foreground otherwise (e.g. when a
    // browser owns foreground, or the previous run's window is closing).
    static bool GrabForeground(IntPtr top) {
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

    // Press ctrl+<vk> `count` times with the target pane focused.
    public static string Chord(IntPtr top, IntPtr surface, ushort vk, int count) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        if (!GrabForeground(top)) return "ABORT: foreground owned by another window";
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
            for (int n = 0; n < count; n++) {
                Key(0x11, false);
                Thread.Sleep(20);
                Key(vk, false); Thread.Sleep(20); Key(vk, true);
                Thread.Sleep(20);
                Key(0x11, true);
                Thread.Sleep(80);
            }
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }
}
'@

function Parse-Panes([string[]]$lines) {
    $lines | ForEach-Object {
        $hw, $r = $_ -split ':'
        $c = $r -split ','
        [pscustomobject]@{
            Hwnd = [int64]$hw
            Left = [int]$c[0]; Top = [int]$c[1]; Right = [int]$c[2]; Bottom = [int]$c[3]
            Width = [int]$c[2] - [int]$c[0]
        }
    }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Run `mode con` in a named pane and return the Columns value for THIS
# probe. The end marker is typed with a cmd caret (T76^DONE...) so the
# literal marker string exists only in the OUTPUT, never in the echoed
# command line; the columns value is the last "Columns:" before it.
$script:probeN = 0
function Get-Cols([string]$pane) {
    $script:probeN++
    $marker = "T76DONE$($script:probeN)"
    $typed = "mode con & echo T76^DONE$($script:probeN)"
    & $exe +send-keys --target=$pane $typed Enter 2>$null | Out-Null
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 250
        $txt = & $exe +read --name=$pane --lines=40 2>$null | Out-String
        $idx = $txt.LastIndexOf($marker)
        if ($idx -ge 0) {
            $m = [regex]::Matches($txt.Substring(0, $idx), 'Columns:\s*(\d+)')
            if ($m.Count -gt 0) { return [int]$m[$m.Count - 1].Groups[1].Value }
        }
    }
    return -1
}

function Run-Case([string]$label, [string[]]$extraArgs, [bool]$expectInherit) {
    Kill-RepoInstances

    $sp = @{ FilePath = $exe; PassThru = $true }
    if ($extraArgs.Count) { $sp.ArgumentList = $extraArgs }
    $proc = Start-Process @sp
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $tops = [FontDrv]::Tops([uint32]$proc.Id)
    if ($tops.Count -ne 1) { Write-Host "SETUP FAIL ($label): expected 1 top window, got $($tops.Count)"; exit 1 }
    $top = [IntPtr]$tops[0]

    # Pane t76a: full-width down-split running cmd (mode con needs cmd).
    & $exe +split --direction=down --name=t76a --shell=cmd "--command=echo ready-a" 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200
    $panes = @(Parse-Panes ([FontDrv]::Panes($top)))
    Assert ($panes.Count -eq 2) "$label setup: 2 panes after split"
    if ($panes.Count -ne 2) { Stop-Process -Id $proc.Id -Force; exit 1 }
    $paneA = $panes | Sort-Object Top | Select-Object -Last 1   # bottom = t76a

    $colsBefore = Get-Cols 't76a'
    Assert ($colsBefore -gt 0) "$label t76a default columns readable ($colsBefore)"
    if ($colsBefore -le 0) { Stop-Process -Id $proc.Id -Force; exit 1 }

    # Zoom t76a: ctrl+= x6 (increase_font_size). Columns must shrink —
    # this doubles as the input-injection positive control.
    $r = [FontDrv]::Chord($top, [IntPtr]$paneA.Hwnd, 0xBB, 6)
    if ($r -ne 'SENT') { Write-Host "ABORT: zoom chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
    Start-Sleep -Milliseconds 800
    $colsZoom = Get-Cols 't76a'
    if ($colsZoom -le 0 -or $colsZoom -ge $colsBefore) {
        Write-Host "ABORT: ctrl+= did not shrink columns ($colsBefore -> $colsZoom) - injection/zoom broken, not a T76 verdict"
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    Write-Host "OK    positive control: ctrl+= zoom shrank columns ($colsBefore -> $colsZoom)"

    # New SPLIT from the zoomed pane: same full width, so inherit on
    # means identical columns; inherit off means the default columns.
    & $exe +split --target=t76a --name=t76b --direction=down --shell=cmd "--command=echo ready-b" 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200
    $colsB = Get-Cols 't76b'
    Assert ($colsB -gt 0) "$label t76b columns readable ($colsB)"
    if ($expectInherit) {
        Assert ($colsB -eq $colsZoom) "$label split INHERITED zoomed font (cols $colsB == zoomed $colsZoom)"
    } else {
        Assert ($colsB -eq $colsBefore) "$label split kept CONFIG font (cols $colsB == default $colsBefore)"
    }

    # New WINDOW from the zoomed focus chain (focused pane is t76b, which
    # itself inherited in run 1). Different pixel width, so compare
    # estimated cell width = pane_px_width / cols.
    & $exe +new-window --target=t76w --shell=cmd "--command=echo ready-w" 2>$null | Out-Null
    $newTop = [IntPtr]::Zero
    for ($t = 0; $t -lt 25; $t++) {
        Start-Sleep -Milliseconds 200
        $tops = [FontDrv]::Tops([uint32]$proc.Id)
        $other = @($tops | Where-Object { $_ -ne $top.ToInt64() })
        if ($other.Count -eq 1) { $newTop = [IntPtr]$other[0]; break }
    }
    Assert ($newTop -ne [IntPtr]::Zero) "$label new window opened"
    if ($newTop -eq [IntPtr]::Zero) { Stop-Process -Id $proc.Id -Force; exit 1 }

    $listJson = & $exe +list --json 2>$null | ConvertFrom-Json
    $win = $listJson.data.windows | Where-Object { $_.target -eq 't76w' }
    $paneW = $win.tabs[0].splits.terminal.name
    Assert ($null -ne $paneW -and $paneW) "$label new-window pane name via +list ($paneW)"
    $colsW = Get-Cols $paneW
    Assert ($colsW -gt 0) "$label t76w columns readable ($colsW)"

    # Cell-width estimates. Pane A keeps full window width through the
    # down-splits; measure fresh rects now.
    $panesNow = @(Parse-Panes ([FontDrv]::Panes($top)))
    $widthA = ($panesNow | Where-Object { $_.Hwnd -eq $paneA.Hwnd }).Width
    $wPanes = @(Parse-Panes ([FontDrv]::Panes($newTop)))
    Assert ($wPanes.Count -eq 1) "$label new window has 1 pane"
    $widthW = $wPanes[0].Width
    $cellBefore = $widthA / $colsBefore
    $cellZoom = $widthA / $colsZoom
    $cellW = $widthW / $colsW
    $msg = "cellpx before={0:N2} zoom={1:N2} newwin={2:N2}" -f $cellBefore, $cellZoom, $cellW
    if ($expectInherit) {
        Assert ([math]::Abs($cellW / $cellZoom - 1) -le 0.08) "$label new window INHERITED zoomed font ($msg)"
        Assert ($cellW / $cellBefore -ge 1.15) "$label new window font is clearly bigger than config default ($msg)"
    } else {
        Assert ([math]::Abs($cellW / $cellBefore - 1) -le 0.08) "$label new window kept CONFIG font ($msg)"
    }

    Assert (-not $proc.HasExited) "$label no crash"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}

Run-Case 'inherit-on'  @() $true
Run-Case 'inherit-off' @('--window-inherit-font-size=false') $false

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
