# Hero-mode geometry + pixel oracle (T19 acceptance, T49 regression guard).
#
# Drives REAL key chords into the debug build and asserts pane geometry:
#   1. 3-pane layout renders as a tree (3 visible terminal children).
#   2. ctrl+shift+space toggles hero mode: one pane fills ~75% width at
#      full height on the left, the other two stack in the right column.
#   3. ctrl+alt+down moves the hero selection (big-left HWND changes).
#   4. ctrl+shift+space again restores the exact tree geometry.
#
# Pixel layer (user directive 2026-07-15: "look at its pixels"): each pane
# is filled with a marker line before the toggle; after the toggle every
# pane region is sampled from the actual screen and must show rendered
# content (>= the distinct-color floor — a blank/frozen pane shows only
# background + cursor). Full-window PNGs land in %TEMP% for human review:
#   ghoztty-hero-tree.png / ghoztty-hero-on.png / ghoztty-hero-nav.png
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
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
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

Add-Type -AssemblyName System.Drawing

# Capture a window's OWN content via PrintWindow(PW_RENDERFULLCONTENT) —
# immune to occlusion by other windows, which polluted the first
# CopyFromScreen version of this harness (2026-07-15).
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
# Rendered text gives dozens of colors (antialiasing); a blank or
# never-painted pane gives a handful (bg + cursor). Retries up to
# $settleMs so slow repaints after a relayout don't read as blank.
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

# Fill each pane with a distinct marker (pixel layer needs rendered text).
$listJson = & $exe +list --json | ConvertFrom-Json
$win = $listJson.data.windows[0].target
& $exe +send-keys --target=$win "echo HERO_PANE_A_MARKER" Enter | Out-Null
& $exe +split --direction=down --name=herob | Out-Null
Start-Sleep -Milliseconds 800
& $exe +send-keys --target=herob "echo HERO_PANE_B_MARKER" Enter | Out-Null
& $exe +split --direction=down --name=heroc | Out-Null
Start-Sleep -Milliseconds 800
& $exe +send-keys --target=heroc "echo HERO_PANE_C_MARKER" Enter | Out-Null
Start-Sleep -Milliseconds 800

$tree = Parse-Panes ([HeroDrv]::Panes($top))
$client = [HeroDrv]::ClientSize($top)
Assert ($tree.Count -eq 3) "setup: 3 visible panes in tree layout (got $($tree.Count))"
if ($tree.Count -ne 3) { Stop-Process -Id $proc.Id -Force; exit 1 }

# Focus target for the toggle: the topmost-leftmost pane (leaf 0).
$leaf0 = ($tree | Sort-Object Top, Left | Select-Object -First 1)
$leaf0Hwnd = [IntPtr]$leaf0.Hwnd
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-tree.png')

# --- Positive control: ctrl+k reaches binding dispatch (T47-proven) ----------
# Debug builds prove it via the stderr io-mailbox log; release builds have no
# log, so the control degrades to chord delivery only.
#
# Deliberately NOT ctrl+shift+r: since T50 that opens the real Rename dialog,
# which DISABLES the owner window while open (RenameDialog.zig) — a control
# that leaves it up silently kills every later chord in this script (that was
# T55: "chords not dispatched" was the dialog eating them, not a key-path
# regression). ctrl+k just clears pane 0's primary screen and leaves no UI.
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
Write-Host ("INFO  client={0}x{1} hero=({2},{3})-({4},{5}) carousel0=({6},{7})-({8},{9}) carousel1=({10},{11})-({12},{13})" -f `
    $client[0], $client[1], $big.Left, $big.Top, $big.Right, $big.Bottom, `
    $rest[0].Left, $rest[0].Top, $rest[0].Right, $rest[0].Bottom, `
    $rest[1].Left, $rest[1].Top, $rest[1].Right, $rest[1].Bottom)
# The Mac carousel ratio is 0.25: the hero pane must NOT eat the carousel
# column (caught by pixels 2026-07-15 — floor-only geometry passed while
# the carousel was a sliver).
$ratio = ($client[0] - $rest[0].Left) / [double]$client[0]
Assert ([Math]::Abs($ratio - 0.25) -lt 0.05) ("carousel column is ~25% of client width (got {0:P1})" -f $ratio)

# Pixel layer: every pane must show rendered content in hero layout.
Start-Sleep -Milliseconds 700
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-on.png')
$heroColors = Get-PaneColorCount $big.Hwnd
Assert ($heroColors -ge 8) "hero pane renders content ($heroColors distinct colors, floor 8)"
foreach ($i in 0, 1) {
    $cc = Get-PaneColorCount $rest[$i].Hwnd
    Assert ($cc -ge 8) "carousel pane $i renders content ($cc distinct colors, floor 8)"
}

# --- Navigate: ctrl+alt+down moves the hero selection ------------------------
$r = [HeroDrv]::Chord($top, [IntPtr]$big.Hwnd, [uint16[]]@(0x11, 0x12), 0x28)
Assert ($r -eq 'SENT') "hero nav chord delivered ($r)"
Start-Sleep -Milliseconds 500
$hero2 = Parse-Panes ([HeroDrv]::Panes($top))
$big2 = $hero2 | Sort-Object Width -Descending | Select-Object -First 1
Assert ($big2.Hwnd -ne $big.Hwnd) 'ctrl+alt+down moved the hero (big-left pane changed)'
Start-Sleep -Milliseconds 500
Save-WindowShot $top (Join-Path $env:TEMP 'ghoztty-hero-nav.png')
$hero2Colors = Get-PaneColorCount $big2.Hwnd
Assert ($hero2Colors -ge 8) "new hero pane renders content after nav ($hero2Colors distinct colors)"

# --- Toggle hero mode off: exact tree geometry restored -----------------------
$r = [HeroDrv]::Chord($top, [IntPtr]$big2.Hwnd, [uint16[]]@(0x11, 0x10), 0x20)
Assert ($r -eq 'SENT') "hero un-toggle chord delivered ($r)"
Start-Sleep -Milliseconds 500
Assert (-not $proc.HasExited) 'no crash after hero un-toggle'
$after = Parse-Panes ([HeroDrv]::Panes($top))
Assert (Rects-Equal $tree $after) 'tree geometry restored exactly after toggle-off'

# --- Palette path: ctrl+shift+p, type "hero", Enter toggles hero mode --------
# (T49 real root cause: the win32 palette list was hardcoded and had no
# "Toggle Hero Mode" entry, so the feature was undiscoverable.)
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
            Start-Sleep -Milliseconds 600
            Assert (-not $proc.HasExited) 'no crash after palette hero toggle'
            $heroP = Parse-Panes ([HeroDrv]::Panes($top))
            $bigP = $heroP | Sort-Object Width -Descending | Select-Object -First 1
            $restP = @($heroP | Where-Object { $_.Hwnd -ne $bigP.Hwnd })
            $heroOnP = ($heroP.Count -eq 3) -and
                       ($bigP.Width -ge [int](0.6 * $client[0])) -and
                       ($restP.Count -eq 2) -and
                       ($restP[0].Left -eq $restP[1].Left) -and ($restP[0].Left -gt $bigP.Right - 5)
            Assert $heroOnP 'palette "Toggle Hero Mode" produced hero geometry'
            # Restore via the keybind for symmetric teardown.
            [HeroDrv]::Chord($top, [IntPtr]$bigP.Hwnd, [uint16[]]@(0x11, 0x10), 0x20) | Out-Null
            Start-Sleep -Milliseconds 400
            $afterP = Parse-Panes ([HeroDrv]::Panes($top))
            Assert (Rects-Equal $treeNow $afterP) 'tree geometry restored after palette round-trip'
        }
    }
}

# --- Teardown ----------------------------------------------------------------
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
