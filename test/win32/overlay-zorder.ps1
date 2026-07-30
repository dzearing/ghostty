# T142 acceptance: the layered overlays defend their z-order.
#
# Every win32 overlay (banner strip, dim overlay, themed scrollbar, resize
# overlay) is a WS_POPUP owned by the pane/window it decorates, so Windows
# keeps it above its OWNER for free — and says nothing about the windows in
# between. Two ways it ends up over other applications, both permanent
# because every reposition used to pass SWP_NOZORDER:
#   1. a stray WS_EX_TOPMOST (we never set it; a T131 verification probe did
#      and never put it back — the filed cause of this task);
#   2. simply being SHOWN while its window is not in front, since
#      SWP_SHOWWINDOW lifts a popup to the top of the non-topmost band.
# Either way the user sees "windows in the background have banners that
# overlap windows in the foreground".
#
# Oracles (z-order is read as an index into the EnumWindows top-down
# enumeration, so "above" and "below" are measured, not inferred):
#   A. healthy: the banner overlay has no topmost bit, sits above its own
#      window, and sits BELOW another window that holds the foreground. This
#      is where the OTHER half of the defect turned up: with no stray bit
#      anywhere, a freshly shown banner popup was already above the
#      foreground window, because SWP_SHOWWINDOW lifts a popup to the top of
#      the band and ownership only pins it above its own window.
#   B. negative control: SetWindowPos(overlay, HWND_TOPMOST) reproduces the
#      filed report — the same overlay now indexes above the foreground
#      window and WindowFromPoint says the banner is what you see there.
#   C. a reposition heals it: bit gone, back below the foreground window,
#      still above its own window, no longer front-most over the band.
#   D. so does an activation change (WM_ACTIVATE), which is when the defect
#      is actually noticed — a window nobody resizes would stay broken.
#   E. a LEGITIMATE topmost owner (toggle_window_float_on_top, the quick
#      terminal) is preserved: Windows propagates the bit to owned popups,
#      and healing must not strip it or the banner would hide behind its own
#      window. This is the case that makes the fix owner-RELATIVE.
#   F. the same healing reaches the dim overlay and the scrollbar popup,
#      which share the helper.
#
# Only touches ghoztty processes running from this repo's zig-out.
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
public class ZDrv {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowLongW(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }

    // Who is visibly on top at this screen point: "<hwnd>:<rootHwnd>:<class>".
    // WindowFromPoint respects the z-order and (unlike a raw screen GetPixel)
    // sees WS_EX_LAYERED popups, so it answers "is the banner in front here?"
    // without depending on any particular pixel color.
    public static string TopAt(int x, int y) {
        POINT p; p.x = x; p.y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) return "0:0:(none)";
        IntPtr root = GetAncestor(h, 2); // GA_ROOT
        var sb = new StringBuilder(64);
        GetClassNameW(h, sb, 64);
        return (long)h + ":" + (long)root + ":" + sb.ToString();
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUTK { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [DllImport("user32.dll", EntryPoint = "SendInput")] public static extern uint SendInputK(uint n, INPUTK[] inputs, int size);

    // Per-monitor-DPI-aware so GetWindowRect and screen samples share one
    // physical-pixel coordinate space (the hero-harness lesson).
    public static void BeDpiAware() { SetProcessDpiAwarenessContext((IntPtr)(-4)); }

    public const int GWL_EXSTYLE = -20;
    public const uint WS_EX_TOPMOST = 0x00000008;

    public static bool IsTopmost(IntPtr h) {
        return (GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
    }
    // Inject the defect (or a legitimate float-on-top owner): exactly what
    // a stray probe does — HWND_TOPMOST, nothing else touched.
    public static void Topmost(IntPtr h, bool on) {
        SetWindowPos(h, (IntPtr)(on ? -1 : -2), 0, 0, 0, 0, 0x0013); // NOSIZE|NOMOVE|NOACTIVATE
    }
    public static void MoveTo(IntPtr h, int x, int y, int cx, int cy) {
        SetWindowPos(h, IntPtr.Zero, x, y, cx, cy, 0x0004 | 0x0010); // NOZORDER|NOACTIVATE
    }

    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    public const uint GW_OWNER = 4;

    // The invariant an overlay must hold: it is above its owner, and nothing
    // FOREIGN is sandwiched between the two. Anything else means the overlay
    // floats over a window that is in front of its own. Returns
    // "<count>:<classes>", or "-1:missing" / "-2:below-owner".
    //
    // Deliberately expressed from ownership data rather than by re-walking
    // the way the product does: this is the specification, not a mirror of
    // the implementation. Other popups owned by the same window (a sibling
    // pane's overlay) are allowed in between; they belong to the same window.
    public static string Between(IntPtr overlay, IntPtr owner) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { if (IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
        int io = list.IndexOf(overlay), iw = list.IndexOf(owner);
        if (io < 0 || iw < 0) return "-1:missing";
        if (io > iw) return "-2:below-owner";
        int n = 0;
        var names = new List<string>();
        for (int i = io + 1; i < iw; i++) {
            if (GetWindow(list[i], GW_OWNER) == owner) continue;
            n++;
            var sb = new StringBuilder(64);
            GetClassNameW(list[i], sb, 64);
            names.Add(sb.ToString());
        }
        return n + ":" + string.Join(",", names);
    }

    // Z-order index of every visible top-level window, top first. -1 when
    // the window is not in the enumeration (hidden).
    public static int ZIndex(IntPtr target) {
        int idx = -1, i = 0;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            if (h == target) { idx = i; return false; }
            i++;
            return true;
        }, IntPtr.Zero);
        return idx;
    }

    // Visible top-level windows of a class for a pid:
    // "left,top,right,bottom,hwnd". includeHidden also reports invisible
    // ones (the scrollbar popup is created hidden until it fades in).
    public static string[] ByClass(uint pid, string cls, bool includeHidden) {
        var lines = new List<string>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            if (!includeHidden && !IsWindowVisible(h)) return true;
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls) {
                RECT r; GetWindowRect(h, out r);
                lines.Add(r.left + "," + r.top + "," + r.right + "," + r.bottom + "," + (long)h);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    // GhozttyTerminal children of a window: "left,top,right,bottom,hwnd".
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                lines.Add(r.left + "," + r.top + "," + r.right + "," + r.bottom + "," + (long)h);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUTK[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInputK(1, i, Marshal.SizeOf(typeof(INPUTK)));
    }

    // T86-hardened foreground grab: attach to the current owner's input
    // thread + an Alt tap (last-input source), retried.
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

[ZDrv]::BeDpiAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}
function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

# The one visible banner overlay in the process (only window A carries a
# banner), as "left,top,right,bottom,hwnd".
function Get-BannerOverlay([uint32]$procId) {
    $all = @([ZDrv]::ByClass($procId, 'GhozttyBannerOverlay', $false))
    if ($all.Count -lt 1) { return $null }
    return $all[0]
}
function Hwnd-Of([string]$row) { return [IntPtr]([int64](($row -split ',')[4])) }

# ---------------------------------------------------------------------------
# Setup: two overlapping windows in one process. A carries a banner; B is
# parked exactly on top of A so "B has the foreground" also means "B covers
# A's banner band", which is what makes the front-most control meaningful.
# Session persistence off so the run starts from a blank layout (T131).
# ---------------------------------------------------------------------------
Kill-RepoInstances
$proc = Start-Process $exe -ArgumentList '--background=#101014', '--session-persistence=false' -PassThru
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$pid32 = [uint32]$proc.Id

& $exe +new-window --target=oz1 | Out-Null
$winA = Wait-Win 'oz1'
if (-not $winA) { Write-Host 'SETUP FAIL: oz1 not registered'; Stop-Process -Id $proc.Id -Force; exit 1 }
$A = [IntPtr]([int64]$winA.id)

& $exe +new-window --target=oz2 | Out-Null
$winB = Wait-Win 'oz2'
if (-not $winB) { Write-Host 'SETUP FAIL: oz2 not registered'; Stop-Process -Id $proc.Id -Force; exit 1 }
$B = [IntPtr]([int64]$winB.id)

[ZDrv]::MoveTo($A, 120, 120, 900, 600) | Out-Null
[ZDrv]::MoveTo($B, 120, 120, 900, 600) | Out-Null
Start-Sleep -Milliseconds 600

& $exe +set-banner --target=oz1 '**T142** z-order probe' | Out-Null
$ov = $null
for ($t = 0; $t -lt 25 -and -not $ov; $t++) { $ov = Get-BannerOverlay $pid32; if (-not $ov) { Start-Sleep -Milliseconds 200 } }
if (-not $ov) { Write-Host 'SETUP FAIL: no banner overlay for oz1'; Stop-Process -Id $proc.Id -Force; exit 1 }
# NOTE: PowerShell variables are case-INSENSITIVE, so a `$OV` for the hwnd is
# the SAME variable as the `$ov` rect row — it silently overwrote the row and
# every geometry-derived probe then read garbage (WindowFromPoint on
# (6685007, ...) answers "nothing there", which looked like a product verdict).
# Hence the distinct names.
$ovHwnd = Hwnd-Of $ov

# Who is visibly in front at the middle of the banner card. B is parked
# exactly over A, so with a healthy z-order this must be B (or one of its
# children) and never the overlay.
function Front-At([string]$row) {
    $r = $row -split ','
    $x = [int]((([int]$r[0]) + ([int]$r[2])) / 2)
    $y = [int]((([int]$r[1]) + ([int]$r[3])) / 2)
    return [ZDrv]::TopAt($x, $y)
}
function Front-Is-Overlay([string]$front, [IntPtr]$overlay) {
    return (($front -split ':')[0] -eq ([int64]$overlay).ToString())
}
function Front-Root([string]$front) { return [IntPtr]([int64](($front -split ':')[1])) }

# Bring B to the front — from here on, A is a BACKGROUND window.
if (-not [ZDrv]::GrabForeground($B)) {
    Write-Host 'ABORT: could not put oz2 in the foreground - no z-order verdict possible'
    Stop-Process -Id $proc.Id -Force; exit 1
}
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------------------
# A. Healthy baseline. This is where the FIRST defect showed up: nobody had
# topmosted anything, and the banner of the background window was already
# above the foreground window, because showing the popup lifted it to the
# top of the band and nothing ever seated it back.
# ---------------------------------------------------------------------------
Assert (-not [ZDrv]::IsTopmost($ovHwnd)) 'A: banner overlay is not topmost to begin with'
$zOv = [ZDrv]::ZIndex($ovHwnd); $zA = [ZDrv]::ZIndex($A); $zB = [ZDrv]::ZIndex($B)
Assert ($zOv -ge 0 -and $zA -ge 0 -and $zB -ge 0) "A: all three windows are in the z-order (ov=$zOv A=$zA B=$zB)"
Assert ($zOv -lt $zA) "A: overlay sits ABOVE its own window (ov=$zOv < A=$zA)"
Assert ($zOv -gt $zB) "A: overlay sits BELOW the foreground window (ov=$zOv > B=$zB)"
$btw = [ZDrv]::Between($ovHwnd, $A)
Assert ($btw -like '0:*') "A: nothing foreign is sandwiched between the overlay and its window ($btw)"

# On-screen control: the front-most window over A's banner band must be the
# foreground window, not A's banner.
$front = Front-At $ov
$frontRootIsB = ((Front-Root $front) -eq $B)
Assert (-not (Front-Is-Overlay $front $ovHwnd)) "A: the banner is not the front-most window over its own band ($front)"
if (-not $frontRootIsB) {
    Write-Host "SKIP front-most control: oz2 is not what covers the band ($front) - the on-screen asserts are skipped"
}

# ---------------------------------------------------------------------------
# B. Reproduce the second defect: a stray probe topmosts the overlay.
# ---------------------------------------------------------------------------
[ZDrv]::Topmost($ovHwnd, $true) | Out-Null
Start-Sleep -Milliseconds 400
Assert ([ZDrv]::IsTopmost($ovHwnd)) 'B: injection took (overlay now carries WS_EX_TOPMOST)'
$btw = [ZDrv]::Between($ovHwnd, $A)
Assert (-not ($btw -like '0:*')) "B: repro - a foreign window is now sandwiched under the banner ($btw)"
if ($frontRootIsB) {
    $front = Front-At $ov
    Assert (Front-Is-Overlay $front $ovHwnd) "B: repro on screen - the banner is now the front-most window over the foreground window ($front)"
}

# ---------------------------------------------------------------------------
# C. A reposition heals it. (Measured, not assumed: topmosting an owned popup
# also raises its OWNER within the band, so B is no longer guaranteed to be in
# front here — which is why the invariant is expressed against A, and the
# "below the foreground window" statement is D's job.)
# ---------------------------------------------------------------------------
# Two lines, so the band height changes and a real layout pass runs.
& $exe +set-banner --target=oz1 "**T142** z-order probe\nsecond line" | Out-Null
$healed = $false
for ($t = 0; $t -lt 25 -and -not $healed; $t++) {
    Start-Sleep -Milliseconds 200
    $healed = (-not [ZDrv]::IsTopmost($ovHwnd))
}
Assert $healed 'C: reposition cleared the stray WS_EX_TOPMOST'
$zOv = [ZDrv]::ZIndex($ovHwnd); $zA = [ZDrv]::ZIndex($A)
Assert ($zOv -lt $zA) "C: overlay still above its own window after healing (ov=$zOv < A=$zA)"
$btw = [ZDrv]::Between($ovHwnd, $A)
Assert ($btw -like '0:*') "C: the sandwiched window is gone - overlay seated back onto its own window ($btw)"

# ---------------------------------------------------------------------------
# D. An activation change heals it too (no layout event at all) — this is the
# moment the user notices, and a window nobody resizes needs it.
# ---------------------------------------------------------------------------
[ZDrv]::Topmost($ovHwnd, $true) | Out-Null
Start-Sleep -Milliseconds 300
if (-not [ZDrv]::IsTopmost($ovHwnd)) {
    Write-Host 'SKIP D: injection did not stick (something repositioned in between)'
} else {
    $okA = [ZDrv]::GrabForeground($A)
    Start-Sleep -Milliseconds 400
    $okB = [ZDrv]::GrabForeground($B)
    Start-Sleep -Milliseconds 600
    if (-not ($okA -and $okB)) {
        Write-Host 'SKIP D: foreground switching failed - not a T142 verdict'
    } else {
        $healed2 = $false
        for ($t = 0; $t -lt 15 -and -not $healed2; $t++) {
            Start-Sleep -Milliseconds 200
            $healed2 = (-not [ZDrv]::IsTopmost($ovHwnd))
        }
        Assert $healed2 'D: window activation cleared the stray WS_EX_TOPMOST'
        $zOv = [ZDrv]::ZIndex($ovHwnd); $zB = [ZDrv]::ZIndex($B)
        Assert ($zOv -gt $zB) "D: overlay below the foreground window after activation heal (ov=$zOv > B=$zB)"
        $ovD = Get-BannerOverlay $pid32
        if ($ovD -and $frontRootIsB) {
            $front = Front-At $ovD
            Assert (-not (Front-Is-Overlay $front $ovHwnd)) "D: the banner no longer shows over the foreground window ($front)"
        }
    }
}

# ---------------------------------------------------------------------------
# E. A LEGITIMATE topmost owner is preserved. toggle_window_float_on_top and
# the quick terminal both topmost the WINDOW; Windows propagates the bit to
# owned popups, so a heal that just cleared the bit would drop the banner
# below its own floating window. The heal is owner-relative for this reason.
# ---------------------------------------------------------------------------
[ZDrv]::Topmost($A, $true) | Out-Null
Start-Sleep -Milliseconds 500
$propagated = [ZDrv]::IsTopmost($ovHwnd)
Assert $propagated 'E: making the owner topmost propagates the bit to its overlay (positive control)'
if ($propagated) {
    & $exe +set-banner --target=oz1 '**T142** floating owner' | Out-Null
    Start-Sleep -Milliseconds 1200
    Assert ([ZDrv]::IsTopmost($ovHwnd)) 'E: reposition PRESERVED the propagated topmost bit (float-on-top not broken)'
    $zOv = [ZDrv]::ZIndex($ovHwnd); $zA = [ZDrv]::ZIndex($A)
    Assert ($zOv -lt $zA) "E: floating window's overlay still above it (ov=$zOv < A=$zA)"
}
[ZDrv]::Topmost($A, $false) | Out-Null
Start-Sleep -Milliseconds 500
& $exe +set-banner --target=oz1 '**T142** grounded owner' | Out-Null
$grounded = $false
for ($t = 0; $t -lt 25 -and -not $grounded; $t++) {
    Start-Sleep -Milliseconds 200
    $grounded = (-not [ZDrv]::IsTopmost($ovHwnd))
}
Assert $grounded 'E: un-floating the owner leaves the overlay non-topmost again'

# ---------------------------------------------------------------------------
# F. The dim overlay and the scrollbar popup share the helper.
# ---------------------------------------------------------------------------
& $exe +split --target=oz1 --direction=down | Out-Null
Start-Sleep -Milliseconds 1200
$dim = @([ZDrv]::ByClass($pid32, 'GhozttyDimOverlay', $false))
if ($dim.Count -lt 1) {
    Write-Host 'SKIP F/dim: no visible dim overlay (unfocused-split-opacity?)'
} else {
    $dimHwnd = Hwnd-Of $dim[0]
    [ZDrv]::Topmost($dimHwnd, $true) | Out-Null
    Start-Sleep -Milliseconds 200
    Assert ([ZDrv]::IsTopmost($dimHwnd)) 'F/dim: injection took'
    # A window resize re-shows every dim overlay through the layout path.
    [ZDrv]::MoveTo($A, 120, 120, 880, 580) | Out-Null
    $dimHealed = $false
    for ($t = 0; $t -lt 25 -and -not $dimHealed; $t++) {
        Start-Sleep -Milliseconds 200
        $dimHealed = (-not [ZDrv]::IsTopmost($dimHwnd))
    }
    Assert $dimHealed 'F/dim: reposition cleared the stray WS_EX_TOPMOST'
}

$sb = @([ZDrv]::ByClass($pid32, 'GhozttyScrollbar', $true))
if ($sb.Count -lt 1) {
    Write-Host 'SKIP F/scrollbar: no scrollbar popup found'
} else {
    $sbHwnd = Hwnd-Of $sb[0]
    [ZDrv]::Topmost($sbHwnd, $true) | Out-Null
    Start-Sleep -Milliseconds 200
    Assert ([ZDrv]::IsTopmost($sbHwnd)) 'F/scrollbar: injection took'
    [ZDrv]::MoveTo($A, 120, 120, 860, 560) | Out-Null
    $sbHealed = $false
    for ($t = 0; $t -lt 25 -and -not $sbHealed; $t++) {
        Start-Sleep -Milliseconds 200
        $sbHealed = (-not [ZDrv]::IsTopmost($sbHwnd))
    }
    Assert $sbHealed 'F/scrollbar: reposition cleared the stray WS_EX_TOPMOST'
}

Assert (-not $proc.HasExited) 'no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
