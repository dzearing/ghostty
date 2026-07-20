# Hero-mode TRUE-port oracle (T58 design / T59a acceptance; supersedes the
# T19 static-stand-in oracle).
#
# Drives REAL key chords into the debug build and asserts the T58 layout.
# PHASE 1 (2 panes — both tiles fit on-screen): snapshot pipeline oracle:
#   with a busy loop running in the HIDDEN pane, the debug log shows
#   "hero snap committed" lines and the owner-painted carousel region's
#   pixels CHANGE between shots (thumbnails refreshing from hidden-pane
#   renderer captures).
# PHASE 2 (3 panes): layout + interaction:
#   1. ctrl+shift+space: exactly ONE visible pane (the hero) at ~75%
#      width / full height on the left; every OTHER leaf HIDDEN
#      (IsWindowVisible false) and sized EXACTLY like the hero rect (T58:
#      all leaves stay hero-sized so selection swaps need no reflow); the
#      carousel column contains NO child HWNDs (it is owner-painted).
#   2. ctrl+alt+down moves the selection: a different leaf becomes the
#      single visible pane, at the same hero rect.
#   3. Click a carousel tile: selects that leaf (mouse-up inside tile).
#   3b. ctrl+shift+down/up ALSO navigates (T61: swap_split is intercepted
#       in hero mode instead of silently swapping the hidden tree).
#   4. ctrl+shift+space again restores the exact tree geometry.
#   5. Palette path (T57): ctrl+shift+p -> "hero" -> Enter produces the
#      same hero layout.
# PHASE 3 (T59b — interactions & motion):
#   6. Click-swap ANIMATES: mid-slide every hero HWND is hidden (the
#      region owner-paints sliding snapshots); skipped when the OS
#      reduced-motion setting disables client-area animations.
#   7. Hover + wheel reach the carousel (debug-log oracles); with 5 tiles
#      the strip overflows and the wheel offset is nonzero.
#   8. Divider drag narrows the hero (all leaves re-sized to the new hero
#      rect); double-clicking the divider resets the ratio to 0.25.
# The harness makes itself per-monitor-DPI-aware; without it PrintWindow
# captures are CLIPPED on >100% DPI monitors (2026-07-16 lesson).
#
# A positive control (ctrl+k, T55) runs first so an injection failure is
# distinguishable from a hero regression. Only touches ghoztty processes
# running from this repo's zig-out*.
#
# -ExePath: test a different build. Release builds emit no debug log, so
# log-based assertions auto-skip (geometry is the verdict).
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
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT r, uint points);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, UIntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint p, out int v, uint winini);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // Mirrors the app's reduced-motion gate (SPI_GETCLIENTAREAANIMATION):
    // when the user disabled client-area animations, hero swaps are
    // instant and the mid-slide oracle must be skipped.
    public static bool AnimEnabled() {
        int v;
        if (!SystemParametersInfoW(0x1042, 0, out v, 0)) return true;
        return v != 0;
    }

    // Map a client-space point of `from` to screen coords (x, y).
    public static int[] ToScreen(IntPtr from, int x, int y) {
        RECT r; r.left = x; r.top = y; r.right = x; r.bottom = y;
        MapWindowPoints(from, IntPtr.Zero, ref r, 2);
        return new int[] { r.left, r.top };
    }

    // Make this PowerShell process per-monitor-DPI-aware so GetWindowRect/
    // GetClientRect return PHYSICAL pixels and PrintWindow captures the
    // full window. Without this, on a >100% DPI monitor the capture
    // bitmap (sized from virtualized coords) CLIPS the right/bottom of
    // the physically-rendered window — the carousel column was cut off
    // and the thumbnail-refresh pixel oracle went blind (found 2026-07-16).
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

    // ALL GhozttyTerminal children (visible or not) with rects in the top
    // window's client coordinates, as "hwnd:vis:left,top,right,bottom".
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal") {
                RECT r; GetWindowRect(h, out r);
                MapWindowPoints(IntPtr.Zero, top, ref r, 2);
                int vis = IsWindowVisible(h) ? 1 : 0;
                lines.Add(h.ToInt64() + ":" + vis + ":" + r.left + "," + r.top + "," + r.right + "," + r.bottom);
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

    // Find the visible palette popup: a top-level owned window of the same
    // pid using the terminal class (WS_POPUP, so not a child of `top`).
    public static IntPtr FindPalettePopup(uint pid, IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && h != top && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyTerminal") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Type plain VKs (letters/Enter) into `edit` in one attachment burst.
    public static string TypeKeys(IntPtr owner, IntPtr edit, ushort[] vks) {
        uint pid; uint tid = GetWindowThreadProcessId(owner, out pid);
        uint cur = GetCurrentThreadId();
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(edit);
            Thread.Sleep(60);
            foreach (var vk in vks) {
                Key(vk, false); Thread.Sleep(15); Key(vk, true); Thread.Sleep(30);
            }
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // Send mods+vk with focus on `surface`. Returns "SENT" or a reason.
    // Retries the foreground grab a few times: on a busy desktop another
    // window can win the race right after SetForegroundWindow.
    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        bool fg = false;
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            // A background process may not steal foreground: attach to the
            // current foreground owner's input thread for the grab, or the
            // request is silently ignored (unattended box with a browser
            // left focused aborted every chord, T25).
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            // An injected Alt tap makes this process the last-input source,
            // which is the other half of the foreground-permission rules.
            Key(0x12, false); Key(0x12, true);
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
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
            // Let any focus/layout change the binding caused settle while
            // still attached (ghoztty defers SetFocus via a posted
            // message, T48) so callers sample post-binding state.
            Thread.Sleep(450);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }
}
'@

Add-Type -AssemblyName System.Drawing
[HeroDrv]::BeDpiAware()

# Capture a window's OWN content via PrintWindow(PW_RENDERFULLCONTENT) —
# immune to occlusion by other windows.
function Get-WindowBitmap([IntPtr]$hwnd) {
    $r = New-Object HeroDrv+RECT
    [HeroDrv]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    $w = $r.right - $r.left; $h = $r.bottom - $r.top
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [HeroDrv]::PrintWindow($hwnd, $hdc, 2) | Out-Null   # 2 = PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    return $bmp
}

function Save-WindowShot([IntPtr]$top, [string]$path) {
    $bmp = Get-WindowBitmap $top
    if ($null -eq $bmp) { return }
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Distinct-color count of a pane's own rendered content (sampled grid).
function Get-PaneColorCount([long]$hwnd, [int]$floor = 8, [int]$settleMs = 3000) {
    $best = 0
    $deadline = [DateTime]::Now.AddMilliseconds($settleMs)
    do {
        $bmp = Get-WindowBitmap ([IntPtr]$hwnd)
        if ($null -ne $bmp) {
            $colors = New-Object 'System.Collections.Generic.HashSet[int]'
            for ($y = 0; $y -lt $bmp.Height; $y += 3) {
                for ($x = 0; $x -lt $bmp.Width; $x += 3) {
                    [void]$colors.Add($bmp.GetPixel($x, $y).ToArgb())
                }
            }
            $bmp.Dispose()
            if ($colors.Count -gt $best) { $best = $colors.Count }
            if ($best -ge $floor) { return $best }
        }
        Start-Sleep -Milliseconds 400
    } while ([DateTime]::Now -lt $deadline)
    return $best
}

# Sampled pixel signature of the top window's region right of $xMin
# (client coords ~ window-bitmap coords are close enough for a diff oracle;
# the region only needs to be inside the carousel column).
function Get-RegionSignature([IntPtr]$top, [int]$xMin) {
    $bmp = Get-WindowBitmap $top
    if ($null -eq $bmp) { return $null }
    $sb = New-Object System.Text.StringBuilder
    for ($y = 40; $y -lt $bmp.Height - 10; $y += 7) {
        for ($x = $xMin; $x -lt $bmp.Width - 4; $x += 7) {
            [void]$sb.Append($bmp.GetPixel($x, $y).ToArgb())
        }
    }
    $bmp.Dispose()
    return $sb.ToString().GetHashCode()
}

# Rect parsing helpers ---------------------------------------------------------
function Parse-Panes([string[]]$lines) {
    $lines | ForEach-Object {
        $hw, $vis, $r = $_ -split ':'
        $c = $r -split ','
        [pscustomobject]@{
            Hwnd = [int64]$hw
            Visible = ([int]$vis -eq 1)
            Left = [int]$c[0]; Top = [int]$c[1]; Right = [int]$c[2]; Bottom = [int]$c[3]
            Width = [int]$c[2] - [int]$c[0]; Height = [int]$c[3] - [int]$c[1]
        }
    }
}
function Rects-Equal($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    $am = @{}; $a | ForEach-Object { $am[$_.Hwnd] = "$($_.Left),$($_.Top),$($_.Right),$($_.Bottom),$($_.Visible)" }
    foreach ($p in $b) {
        if ($am[$p.Hwnd] -ne "$($p.Left),$($p.Top),$($p.Right),$($p.Bottom),$($p.Visible)") { return $false }
    }
    return $true
}
function Same-Rect($a, $b) {
    return ($a.Left -eq $b.Left) -and ($a.Top -eq $b.Top) -and
           ($a.Right -eq $b.Right) -and ($a.Bottom -eq $b.Bottom)
}

# Assert the T58 hero layout and return @{Hero=<pane>; Ok=<bool>}.
function Assert-HeroLayout($panes, $client, [string]$label) {
    $visible = @($panes | Where-Object Visible)
    $hidden = @($panes | Where-Object { -not $_.Visible })
    $ok = ($visible.Count -eq 1)
    Assert $ok "$label - exactly one visible pane (got $($visible.Count))"
    if (-not $ok) { return @{ Hero = $null; Ok = $false } }
    $hero = $visible[0]
    $geom = ($hero.Width -ge [int](0.6 * $client[0])) -and
            ($hero.Width -le [int](0.85 * $client[0])) -and
            ($hero.Height -ge [int](0.9 * $client[1])) -and
            ($hero.Left -le 2)
    Assert $geom "$label - hero fills ~75% width / full height on the left (w=$($hero.Width) of $($client[0]))"
    $allHeroSized = $true
    foreach ($p in $hidden) { if (-not (Same-Rect $p $hero)) { $allHeroSized = $false } }
    Assert $allHeroSized "$label - all hidden leaves sized exactly like the hero rect (T58: no reflow on swap)"
    return @{ Hero = $hero; Ok = ($geom -and $allHeroSized) }
}

# --- Setup: fresh debug instance with a 3-pane layout ------------------------
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

if ($ExePath) { $proc = Start-Process -FilePath $exe -PassThru }
else { $proc = Start-Process -FilePath $exe -PassThru -RedirectStandardError $errlog }
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [HeroDrv]::FindTop([uint32]$proc.Id)
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

# Two panes first: pane A (markers) + herob running a BUSY LOOP so its
# thumbnail keeps changing while the pane is hidden (snapshot oracle runs
# in this 2-pane phase — with only two tiles both are fully on-screen;
# with three, the busy tile can land below the window since the strip
# centers the SELECTED tile, Mac behavior). The 3rd pane is added later
# for the geometry/nav/click phase.
$listJson = & $exe +list --json | ConvertFrom-Json
$win = $listJson.data.windows[0].target
& $exe +send-keys --target=$win "echo HERO_PANE_A_MARKER" Enter | Out-Null
& $exe +split --direction=down --name=herob | Out-Null
Start-Sleep -Milliseconds 800
# Busy output that works in cmd AND PowerShell panes: one line per second.
& $exe +send-keys --target=herob "ping -t 127.0.0.1" Enter | Out-Null
Start-Sleep -Milliseconds 1200

$pair = Parse-Panes ([HeroDrv]::Panes($top))
$client = [HeroDrv]::ClientSize($top)
Assert ($pair.Count -eq 2) "setup: 2 panes exist (got $($pair.Count))"
$leaf0 = ($pair | Sort-Object Top, Left | Select-Object -First 1)
$leaf0Hwnd = [IntPtr]$leaf0.Hwnd

# --- Positive control: ctrl+k reaches binding dispatch (T55/T47-proven) ------
$haveLog = (Test-Path $errlog)
$r = [HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(0x11), 0x4B)
if ($r -ne 'SENT') { Write-Host "ABORT: control chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
Start-Sleep -Milliseconds 300
if ($haveLog) {
    if (-not (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -Quiet)) {
        Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a hero verdict'
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
} else {
    Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
}

# --- Phase 1 (2 panes): snapshot pipeline oracle ------------------------------
$r = [HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(0x11, 0x10), 0x20)  # ctrl+shift+space
Assert ($r -eq 'SENT') "hero toggle chord delivered ($r)"
Start-Sleep -Milliseconds 800
Assert (-not $proc.HasExited) 'no crash after hero toggle'
if ($haveLog) {
    Assert ((Select-String -Path $errlog -Pattern 'toggle_hero_mode' -Quiet)) 'toggle_hero_mode binding dispatched (log)'
}
$hero1 = Parse-Panes ([HeroDrv]::Panes($top))
$res1 = Assert-HeroLayout $hero1 $client 'hero on (2 panes)'
$big1 = $res1.Hero
if ($null -eq $big1) { Stop-Process -Id $proc.Id -Force; exit 1 }

if ($haveLog) {
    $snapDeadline = [DateTime]::Now.AddSeconds(5)
    $snapSeen = $false
    while (-not $snapSeen -and [DateTime]::Now -lt $snapDeadline) {
        $snapSeen = (Select-String -Path $errlog -Pattern 'hero snap committed' -Quiet)
        if (-not $snapSeen) { Start-Sleep -Milliseconds 300 }
    }
    Assert $snapSeen 'renderer committed hero snapshots (debug log)'
}
# The busy ping in HIDDEN pane "herob" adds a line every ~1s; with two
# tiles both are fully on-screen, so the carousel signature must change
# within a few refresh cycles.
$sigX = $big1.Right + 10
$sig1 = Get-RegionSignature $top $sigX
$sigChanged = $false
for ($t = 0; $t -lt 5 -and -not $sigChanged; $t++) {
    Start-Sleep -Milliseconds 1500
    $sig2 = Get-RegionSignature $top $sigX
    if (($null -ne $sig1) -and ($null -ne $sig2) -and ($sig1 -ne $sig2)) { $sigChanged = $true }
}
Assert $sigChanged 'carousel thumbnails visibly update while a busy TUI runs in a hidden pane'
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-snap.png')

# Toggle off and add the third pane for the geometry/nav/click phase.
$r = [HeroDrv]::Chord($top, [IntPtr]$big1.Hwnd, [uint16[]]@(0x11, 0x10), 0x20)
Assert ($r -eq 'SENT') 'phase-1 un-toggle delivered'
Start-Sleep -Milliseconds 600
& $exe +split --direction=down --name=heroc | Out-Null
Start-Sleep -Milliseconds 800
& $exe +send-keys --target=heroc "echo HERO_PANE_C_MARKER" Enter | Out-Null
Start-Sleep -Milliseconds 800

$tree = Parse-Panes ([HeroDrv]::Panes($top))
Assert ($tree.Count -eq 3) "setup: 3 panes exist (got $($tree.Count))"
Assert (@($tree | Where-Object Visible).Count -eq 3) 'setup: all 3 panes visible in tree layout'
if ($tree.Count -ne 3) { Stop-Process -Id $proc.Id -Force; exit 1 }
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-tree.png')

# --- Phase 2 (3 panes): layout, nav, click, restore ---------------------------
# Focus + toggle from leaf 0 again (the previous hero).
$r = [HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(0x11, 0x10), 0x20)
Assert ($r -eq 'SENT') "hero re-toggle chord delivered ($r)"
Start-Sleep -Milliseconds 800
$hero = Parse-Panes ([HeroDrv]::Panes($top))
Assert ($hero.Count -eq 3) "hero: still 3 panes (got $($hero.Count))"
$res = Assert-HeroLayout $hero $client 'hero on (3 panes)'
$big = $res.Hero
if ($null -eq $big) { Stop-Process -Id $proc.Id -Force; exit 1 }
Assert ($big.Hwnd -eq $leaf0.Hwnd) 'hero seeds from the focused pane (leaf 0 is the hero)'
$ratio = ($client[0] - $big.Right) / [double]$client[0]
Assert ([Math]::Abs($ratio - 0.25) -lt 0.06) ("carousel column is ~25% of client width (got {0:P1})" -f $ratio)

# Pixel layer: the hero pane renders content.
Start-Sleep -Milliseconds 700
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-on.png')
$heroColors = Get-PaneColorCount $big.Hwnd
Assert ($heroColors -ge 8) "hero pane renders content ($heroColors distinct colors, floor 8)"

# --- Navigate: ctrl+alt+down/up moves the hero selection ---------------------
# The carousel strip is ordered by TREE ITERATION ORDER, and prev/next
# clamp at the ends (Mac parity) — the focused pane is NOT necessarily
# first in that order, so pressing "down" from the last tile is a correct
# no-op (this burned a session on 2026-07-16: heroSelect logged
# `req=3 clamped=2 cur=2`). Try down first, then up.
$big2 = $null
foreach ($vk in 0x28, 0x26) {  # VK_DOWN, then VK_UP
    $r = [HeroDrv]::Chord($top, [IntPtr]$big.Hwnd, [uint16[]]@(0x11, 0x12), $vk)
    if ($vk -eq 0x28) { Assert ($r -eq 'SENT') "hero nav chord delivered ($r)" }
    Start-Sleep -Milliseconds 600
    $cand = @((Parse-Panes ([HeroDrv]::Panes($top))) | Where-Object Visible)
    if ($cand.Count -eq 1 -and $cand[0].Hwnd -ne $big.Hwnd) { break }
}
$hero2 = Parse-Panes ([HeroDrv]::Panes($top))
$res2 = Assert-HeroLayout $hero2 $client 'hero nav'
$big2 = $res2.Hero
Assert (($null -ne $big2) -and ($big2.Hwnd -ne $big.Hwnd)) 'ctrl+alt+down/up moved the hero (visible pane changed)'
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-nav.png')
if ($null -ne $big2) {
    $hero2Colors = Get-PaneColorCount $big2.Hwnd
    Assert ($hero2Colors -ge 8) "new hero pane renders content after nav ($hero2Colors distinct colors)"
}

# --- Click a carousel tile selects it (mouse-up inside the tile) -------------
# Tile geometry mirror of hero_math.zig: carousel column right of the
# divider; thumb w = 88% of column, h = w/AR capped at 70% of column
# height; selected tile centered. Clicking one tile-step ABOVE the center
# selects the previous leaf.
if ($null -ne $big2) {
    $carouselLeft = $big2.Right + 8
    $carouselW = $client[0] - $carouselLeft
    $carouselH = $client[1] - $big2.Top
    $ar = $big2.Width / [double]$big2.Height
    $thumbW = [int](0.88 * $carouselW)
    $thumbH = [int]($thumbW / $ar)
    if ($thumbH -gt [int](0.7 * $carouselH)) { $thumbH = [int](0.7 * $carouselH) }
    $cx = $carouselLeft + [int]($carouselW / 2)
    $cy = $big2.Top + [int]($carouselH / 2) - ($thumbH + 8)
    $lparam = [IntPtr](($cy -shl 16) -bor ($cx -band 0xFFFF))
    [HeroDrv]::PostMessageW($top, 0x0201, [UIntPtr]::Zero, $lparam) | Out-Null  # WM_LBUTTONDOWN
    Start-Sleep -Milliseconds 50
    [HeroDrv]::PostMessageW($top, 0x0202, [UIntPtr]::Zero, $lparam) | Out-Null  # WM_LBUTTONUP
    Start-Sleep -Milliseconds 600
    $hero3 = Parse-Panes ([HeroDrv]::Panes($top))
    $vis3 = @($hero3 | Where-Object Visible)
    Assert (($vis3.Count -eq 1) -and ($vis3[0].Hwnd -ne $big2.Hwnd)) 'clicking a carousel tile swaps it into the hero'
}

# --- Navigate: ctrl+shift+down/up ALSO moves the selection (T61) --------------
# ctrl+shift+arrows is bound to swap_split; in hero mode that used to
# spatially SWAP panes in the hidden tree (user report 2026-07-16: the
# selection chased the swapped pane to a surprise tile, and toggle-off
# restored a mutated layout). Hero now intercepts it as prev/next
# navigation. The toggle-off "geometry restored exactly" assertion below
# doubles as the no-tree-mutation oracle: Rects-Equal is per-HWND, so a
# real swap surviving these chords would fail it.
$visCS = @((Parse-Panes ([HeroDrv]::Panes($top))) | Where-Object Visible)
if ($visCS.Count -eq 1) {
    $bigCS = $visCS[0]
    $movedCS = $false
    foreach ($vk in 0x28, 0x26) {  # VK_DOWN, then VK_UP (prev/next clamp at the ends)
        $r = [HeroDrv]::Chord($top, [IntPtr]$bigCS.Hwnd, [uint16[]]@(0x11, 0x10), $vk)
        if ($vk -eq 0x28) { Assert ($r -eq 'SENT') "ctrl+shift nav chord delivered ($r)" }
        Start-Sleep -Milliseconds 600
        $cand = @((Parse-Panes ([HeroDrv]::Panes($top))) | Where-Object Visible)
        if ($cand.Count -eq 1 -and $cand[0].Hwnd -ne $bigCS.Hwnd) { $movedCS = $true; break }
    }
    Assert $movedCS 'ctrl+shift+down/up moves the hero selection (swap_split intercepted, T61)'
} else {
    Assert $false "ctrl+shift nav precondition: exactly one visible pane (got $($visCS.Count))"
}

# --- Toggle hero mode off: exact tree geometry restored -----------------------
$visNow = @((Parse-Panes ([HeroDrv]::Panes($top))) | Where-Object Visible)
$curHero = if ($visNow.Count -ge 1) { [IntPtr]$visNow[0].Hwnd } else { $leaf0Hwnd }
$r = [HeroDrv]::Chord($top, $curHero, [uint16[]]@(0x11, 0x10), 0x20)
Assert ($r -eq 'SENT') "hero un-toggle chord delivered ($r)"
Start-Sleep -Milliseconds 600
Assert (-not $proc.HasExited) 'no crash after hero un-toggle'
$after = Parse-Panes ([HeroDrv]::Panes($top))
Assert (@($after | Where-Object Visible).Count -eq 3) 'all 3 panes visible again after toggle-off'
Assert (Rects-Equal $tree $after) 'tree geometry restored exactly after toggle-off'

# --- Palette path: ctrl+shift+p, type "hero", Enter toggles hero mode --------
$treeNow = Parse-Panes ([HeroDrv]::Panes($top))
$r = [HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(0x11, 0x10), 0x50)  # ctrl+shift+p
if ($r -ne 'SENT') { Write-Host "SKIP palette test: $r" }
else {
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $popup -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 20
        $popup = [HeroDrv]::FindPalettePopup([uint32]$proc.Id, $top)
    }
    Assert ($popup -ne [IntPtr]::Zero) 'palette popup opened via ctrl+shift+p'
    if ($popup -ne [IntPtr]::Zero) {
        $palEdit = [HeroDrv]::FindWindowExW($popup, [IntPtr]::Zero, 'EDIT', $null)
        Assert ($palEdit -ne [IntPtr]::Zero) 'palette search edit found'
        if ($palEdit -ne [IntPtr]::Zero) {
            # H E R O then Enter
            $r = [HeroDrv]::TypeKeys($popup, $palEdit, [uint16[]]@(0x48, 0x45, 0x52, 0x4F, 0x0D))
            Assert ($r -eq 'SENT') "palette keys typed ($r)"
            Start-Sleep -Milliseconds 800
            Assert (-not $proc.HasExited) 'no crash after palette hero toggle'
            $heroP = Parse-Panes ([HeroDrv]::Panes($top))
            $resP = Assert-HeroLayout $heroP $client 'palette hero'
            # Restore via the keybind for symmetric teardown.
            if ($null -ne $resP.Hero) {
                [HeroDrv]::Chord($top, [IntPtr]$resP.Hero.Hwnd, [uint16[]]@(0x11, 0x10), 0x20) | Out-Null
                Start-Sleep -Milliseconds 500
                $afterP = Parse-Panes ([HeroDrv]::Panes($top))
                Assert (Rects-Equal $treeNow $afterP) 'tree geometry restored after palette round-trip'
            }
        }
    }
}

# --- Phase 3 (T59b): interactions & motion ------------------------------------
# Wheel scroll, divider drag + double-click reset, hover chrome, and the
# selection slide (mid-slide every hero HWND is hidden while the region
# owner-paints sliding snapshots). Posted mouse messages are deterministic:
# the WndProc branches only read message coords.
$r = [HeroDrv]::Chord($top, $leaf0Hwnd, [uint16[]]@(0x11, 0x10), 0x20)
Assert ($r -eq 'SENT') "phase-3 hero toggle delivered ($r)"
Start-Sleep -Milliseconds 1200   # let the 150ms heartbeat build snapshot DIBs
$hero4 = Parse-Panes ([HeroDrv]::Panes($top))
$res4 = Assert-HeroLayout $hero4 $client 'phase-3 hero on'
$big4 = $res4.Hero

if ($null -ne $big4) {
    # Shared tile geometry (mirror of hero_math.zig, as in the click test).
    $carouselLeft = $big4.Right + 8
    $carouselW = $client[0] - $carouselLeft
    $carouselH = $client[1] - $big4.Top
    $ar = $big4.Width / [double]$big4.Height
    $thumbW = [int](0.88 * $carouselW)
    $thumbH = [int]($thumbW / $ar)
    if ($thumbH -gt [int](0.7 * $carouselH)) { $thumbH = [int](0.7 * $carouselH) }
    $ccx = $carouselLeft + [int]($carouselW / 2)
    $ccy = $big4.Top + [int]($carouselH / 2)

    # (a) Animated click-swap: poll for the mid-slide state (0 visible
    # panes) right after the selecting mouse-up. Selection is clamped at
    # the strip ends, so try one tile below center, then one above.
    if ([HeroDrv]::AnimEnabled()) {
        $midSlideSeen = $false
        $swapped = $false
        foreach ($step in 1, -1) {
            $cy = $ccy + $step * ($thumbH + 8)
            $lp = [IntPtr](($cy -shl 16) -bor ($ccx -band 0xFFFF))
            [HeroDrv]::PostMessageW($top, 0x0201, [UIntPtr]::Zero, $lp) | Out-Null
            [HeroDrv]::PostMessageW($top, 0x0202, [UIntPtr]::Zero, $lp) | Out-Null
            for ($t = 0; $t -lt 12; $t++) {
                Start-Sleep -Milliseconds 30
                $mid = @((Parse-Panes ([HeroDrv]::Panes($top))) | Where-Object Visible)
                if ($mid.Count -eq 0) { $midSlideSeen = $true }
            }
            Start-Sleep -Milliseconds 500
            $now = @((Parse-Panes ([HeroDrv]::Panes($top))) | Where-Object Visible)
            if ($now.Count -eq 1 -and $now[0].Hwnd -ne $big4.Hwnd) { $swapped = $true; break }
        }
        Assert $midSlideSeen 'selection slide: mid-slide state seen (all hero HWNDs hidden, region owner-painted)'
        Assert $swapped 'selection slide: click-swap completed (new hero visible after the slide)'
    } else {
        Write-Host 'SKIP  slide oracle: OS client-area animations disabled (reduced motion)'
    }

    # (b) Hover chrome: a posted WM_MOUSEMOVE over the carousel sets the
    # hovered tile (debug-log oracle; hover repaint is visual-only).
    $lpHover = [IntPtr](($ccy -shl 16) -bor ($ccx -band 0xFFFF))
    [HeroDrv]::PostMessageW($top, 0x0200, [UIntPtr]::Zero, $lpHover) | Out-Null  # WM_MOUSEMOVE
    Start-Sleep -Milliseconds 250
    if ($haveLog) {
        Assert ((Select-String -Path $errlog -Pattern 'hero hover tile=' -Quiet)) 'hover: carousel tile hover tracked (log)'
    }

    # (c) Wheel over the carousel is consumed by the strip (3 tiles fit ->
    # scroll clamps to 0 but the path logs). Wheel coords are SCREEN coords.
    $scr = [HeroDrv]::ToScreen($top, $ccx, $ccy)
    $lpWheel = [IntPtr](($scr[1] -shl 16) -bor ($scr[0] -band 0xFFFF))
    # Delta -120 in the high word. Decimal literal: PS 5.1 parses the hex
    # 0xFF880000 as a NEGATIVE Int32 and the UInt64 cast throws.
    $wpWheel = [UIntPtr][uint64]4287102976
    [HeroDrv]::PostMessageW($top, 0x020A, $wpWheel, $lpWheel) | Out-Null  # WM_MOUSEWHEEL
    Start-Sleep -Milliseconds 250
    if ($haveLog) {
        Assert ((Select-String -Path $errlog -Pattern 'hero wheel scroll=' -Quiet)) 'wheel: carousel consumed the wheel (log)'
    }

    # (d) With 5 tiles the strip always overflows -> wheel scroll is
    # nonzero. Splitting while hero is active must keep the hero layout.
    & $exe +split --direction=down --name=herod | Out-Null
    Start-Sleep -Milliseconds 500
    & $exe +split --direction=down --name=heroe | Out-Null
    Start-Sleep -Milliseconds 800
    $five = Parse-Panes ([HeroDrv]::Panes($top))
    Assert ($five.Count -eq 5) "phase-3 setup: 5 panes exist (got $($five.Count))"
    $res5 = Assert-HeroLayout $five $client 'hero layout holds after splits while active'
    $big5 = $res5.Hero
    if ($null -ne $big5 -and $haveLog) {
        [HeroDrv]::PostMessageW($top, 0x020A, $wpWheel, $lpWheel) | Out-Null
        Start-Sleep -Milliseconds 250
        $scrollLines = @(Select-String -Path $errlog -Pattern 'hero wheel scroll=(-?\d+)')
        $lastScroll = if ($scrollLines.Count -gt 0) { [int]$scrollLines[-1].Matches[0].Groups[1].Value } else { 0 }
        Assert ($lastScroll -ne 0) "wheel: overflowing strip scrolled (offset $lastScroll)"
    }

    # (e) Divider drag: press in the divider band, drag 150px left, release.
    # The per-tab ratio grows and every leaf lands on the new hero rect.
    if ($null -ne $big5) {
        $midY = [int](($big5.Top + $big5.Bottom) / 2)
        $divX = $big5.Right + 3
        $lpDown = [IntPtr](($midY -shl 16) -bor ($divX -band 0xFFFF))
        $dragX = $divX - 150
        $lpMove = [IntPtr](($midY -shl 16) -bor ($dragX -band 0xFFFF))
        [HeroDrv]::PostMessageW($top, 0x0201, [UIntPtr]::Zero, $lpDown) | Out-Null
        Start-Sleep -Milliseconds 60
        [HeroDrv]::PostMessageW($top, 0x0200, [UIntPtr][uint32]1, $lpMove) | Out-Null  # MK_LBUTTON
        Start-Sleep -Milliseconds 150
        [HeroDrv]::PostMessageW($top, 0x0200, [UIntPtr][uint32]1, $lpMove) | Out-Null  # post-throttle tick
        Start-Sleep -Milliseconds 120
        [HeroDrv]::PostMessageW($top, 0x0202, [UIntPtr]::Zero, $lpMove) | Out-Null
        Start-Sleep -Milliseconds 400
        $dragged = Parse-Panes ([HeroDrv]::Panes($top))
        $visD = @($dragged | Where-Object Visible)
        Assert ($visD.Count -eq 1) 'divider drag: still exactly one visible pane'
        if ($visD.Count -eq 1) {
            $heroD = $visD[0]
            Assert ($heroD.Width -le ($big5.Width - 100)) "divider drag: hero narrowed (was $($big5.Width), now $($heroD.Width))"
            $hiddenD = @($dragged | Where-Object { -not $_.Visible })
            $allSized = ($hiddenD.Count -gt 0) -and -not ($hiddenD | Where-Object { -not (Same-Rect $_ $heroD) })
            Assert $allSized 'divider drag: all hidden leaves re-sized to the new hero rect'

            # (f) Double-click the (moved) divider: ratio resets to the
            # default 0.25 -> the standard hero layout assertions hold again.
            $divX2 = $heroD.Right + 3
            $lpDbl = [IntPtr](($midY -shl 16) -bor ($divX2 -band 0xFFFF))
            [HeroDrv]::PostMessageW($top, 0x0203, [UIntPtr]::Zero, $lpDbl) | Out-Null  # WM_LBUTTONDBLCLK
            Start-Sleep -Milliseconds 60
            [HeroDrv]::PostMessageW($top, 0x0202, [UIntPtr]::Zero, $lpDbl) | Out-Null
            Start-Sleep -Milliseconds 400
            $reset = Parse-Panes ([HeroDrv]::Panes($top))
            $resR = Assert-HeroLayout $reset $client 'divider double-click resets the ratio'
        }
    }

    $artifacts = Join-Path $PSScriptRoot 'artifacts'
    New-Item -ItemType Directory -Force $artifacts | Out-Null
    Save-WindowShot $top (Join-Path $artifacts 'hero-mode-t59b.png')
}

# --- Teardown ----------------------------------------------------------------
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
