# T35/T91 acceptance: sticky pane banner — `+set-banner` IPC, OSC 7778,
# banner overlay strip on the glass, `+list` additive `banner` field, the
# ctrl+shift+b "Set Pane Banner" editor dialog, and the T91 markdown
# parity blocks (headings, rules, tables, native checkboxes, collapse).
#
# Oracles:
#   - `+list --json` panes carry an additive `banner` field with the raw
#     markdown source when set (absent otherwise).
#   - A visible GhozttyBannerOverlay popup is glued ABOVE the pane (its
#     bottom meets the pane HWND's top — T101: the strip band is reserved
#     by the window layout, so the grid starts below the banner, never
#     under it) and spans the pane width; its height grows with `\n` line
#     breaks (capped at 10 display lines). Setting/clearing/collapsing a
#     banner moves the pane top by exactly the strip height.
#   - A screen-pixel probe inside the strip is BRIGHTER than the dark pane
#     background while the banner is up and reverts after --clear (proves
#     the strip reaches the glass, not just the data model).
#   - T131 (glass card): the banner is a FLOATING CARD, not a full-width
#     strip. The band's own corners read the pane background EXACTLY (the
#     card is inset by a uniform margin and the window is opaque, so
#     nothing behind the band can bleed through — that see-through was the
#     "text scrolls behind the banner" report), the card interior is the
#     Mac wash `white @ 6%` over the pane background, an elevation shadow
#     darkens the band just under the card, and the composited screen
#     pixel EQUALS the own-DC pixel (proof the window is fully opaque).
#   - A heading is taller than a plain line; an `---` rule line is thinner
#     than a text line; a pipe table renders 3 display rows from 4 source
#     lines (the separator row never renders).
#   - A checked task-list box paints real green pixels (native box), not
#     a plaintext glyph.
#   - A multi-line banner collapses to a first-line sliver on click and
#     expands back on a second click.
#   - OSC 7778 emitted from inside the pane round-trips into +list.
#   - The editor dialog (GhozttyBannerDialog) opens on ctrl+shift+b,
#     commits on ctrl+enter, cancels on Escape.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

Add-Type -AssemblyName System.Drawing

$script:pass = 0
$script:fail = 0

# Composited screen pixel as "r,g,b" via CopyFromScreen — unlike a raw
# GetPixel on the screen DC, this captures layered (WS_EX_LAYERED) windows,
# which the banner overlay is.
function Get-ScreenPx([int]$x, [int]$y) {
    $bmp = New-Object System.Drawing.Bitmap(1, 1)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size(1, 1)))
    $g.Dispose()
    $c = $bmp.GetPixel(0, 0)
    $bmp.Dispose()
    return "$($c.R),$($c.G),$($c.B)"
}
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
public class BannerDrv {
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
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Temporarily float a window above everything (or put it back) so a
    // screen sample cannot be polluted by unrelated desktop windows.
    public static void Topmost(IntPtr h, bool on) {
        SetWindowPos(h, (IntPtr)(on ? -1 : -2), 0, 0, 0, 0, 0x0013); // NOSIZE|NOMOVE|NOACTIVATE
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    // Per-monitor-DPI-aware so GetWindowRect and screen samples share one
    // physical-pixel coordinate space (the T59a hero-harness lesson: an
    // unaware process gets virtualized rects and every point sample lands
    // off the 31px strip on a >100% DPI monitor).
    public static void BeDpiAware() {
        SetProcessDpiAwarenessContext((IntPtr)(-4)); // PER_MONITOR_AWARE_V2
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUTK { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [DllImport("user32.dll", EntryPoint = "SendInput")] public static extern uint SendInputK(uint n, INPUTK[] inputs, int size);

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

    // Visible top-level windows of a class for a pid:
    // "left,top,right,bottom,hwnd".
    public static string[] ByClass(uint pid, string cls) {
        var lines = new List<string>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) return true;
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

    // Pixel from a window's OWN surface (client coords) — for layered
    // windows this reads the painted content regardless of z-order.
    public static string OwnPixel(IntPtr h, int x, int y) {
        IntPtr dc = GetDC(h);
        uint c = GetPixel(dc, x, y);
        ReleaseDC(h, dc);
        return (c & 0xFF) + "," + ((c >> 8) & 0xFF) + "," + ((c >> 16) & 0xFF);
    }

    // Count clearly-green pixels (native checked-box stroke) in a client
    // rect of the window's own surface. One GetDC for the whole scan.
    public static int ScanGreen(IntPtr h, int x0, int y0, int x1, int y1) {
        IntPtr dc = GetDC(h);
        int hits = 0;
        for (int y = y0; y < y1; y++) {
            for (int x = x0; x < x1; x++) {
                uint c = GetPixel(dc, x, y); // COLORREF 0x00BBGGRR
                int r = (int)(c & 0xFF), g = (int)((c >> 8) & 0xFF), b = (int)((c >> 16) & 0xFF);
                if (g - r > 60 && g - b > 60) hits++;
            }
        }
        ReleaseDC(h, dc);
        return hits;
    }

    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

    // Post a synthetic left-click (WM_LBUTTONUP is what the banner strip
    // acts on) at client coords — foreground-independent and exact.
    public static void ClickClient(IntPtr h, int x, int y) {
        PostMessageW(h, 0x0202, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF)));
    }

    // Visible GhozttyTerminal children of a top-level: same line format.
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                lines.Add(r.left + "," + r.top + "," + r.right + "," + r.bottom);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    public static string ScreenPixel(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        uint c = GetPixel(dc, x, y); // COLORREF 0x00BBGGRR
        ReleaseDC(IntPtr.Zero, dc);
        return (c & 0xFF) + "," + ((c >> 8) & 0xFF) + "," + ((c >> 16) & 0xFF);
    }

    public static void Key(ushort vk, bool up) {
        var i = new INPUTK[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInputK(1, i, Marshal.SizeOf(typeof(INPUTK)));
    }

    public static void Chord(ushort[] mods, ushort vk) {
        foreach (var m in mods) { Key(m, false); Thread.Sleep(20); }
        Key(vk, false); Thread.Sleep(20); Key(vk, true);
        for (int i = mods.Length - 1; i >= 0; i--) { Thread.Sleep(20); Key(mods[i], true); }
    }

    // T86-hardened foreground grab: attach to the current foreground
    // owner's thread + an Alt tap (last-input source), retried - a
    // background process may not steal foreground otherwise.
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

    public static string Foreground(IntPtr top) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        AttachThreadInput(cur, tid, false);
        if (GetForegroundWindow() != top) return "NOT FOREGROUND";
        return "OK";
    }
}
'@

[BannerDrv]::BeDpiAware()

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
    foreach ($w in $data.windows) {
        if ($target -like 'id:*') { if ($w.id -eq $target.Substring(3)) { return $w } }
        elseif ($w.target -eq $target) { return $w }
    }
    return $null
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

# Poll for a pane banner: window $target, leaf index $i, expected exact
# value (or 'NONE' for absent). Returns the observed value or '(absent)'.
function Wait-Banner($target, [int]$i, [string]$expect) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) {
            $leaves = @(Get-Leaves $w.tabs[0].splits)
            if ($leaves.Count -gt $i) {
                $b = $leaves[$i].banner
                if ($expect -eq 'NONE' -and -not $b) { return '(absent)' }
                if ($b -ceq $expect) { return $b }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    $w = Get-Win $target
    if ($w) {
        $leaves = @(Get-Leaves $w.tabs[0].splits)
        if ($leaves.Count -gt $i -and $leaves[$i].banner) { return $leaves[$i].banner }
    }
    return '(absent)'
}

# Live pane rect #$i of window $top, sorted top-then-left so index is
# geometric (0 = topmost pane), or $null.
function Get-Pane([IntPtr]$top, [int]$i = 0) {
    $panes = @([BannerDrv]::Panes($top)) | Sort-Object { [int](($_ -split ',')[1]) }, { [int](($_ -split ',')[0]) }
    if (@($panes).Count -le $i) { return $null }
    return @($panes)[$i]
}

# The banner overlay glued ABOVE live pane #$i (same left edge; overlay
# BOTTOM meets the pane's current top — T101 reserves the strip band above
# the terminal, so the grid starts below the banner, never under it), or
# $null. Queries the pane fresh: the pane top moves as strips come and go.
function Get-Overlay([uint32]$procId, [IntPtr]$top, [int]$i = 0) {
    $p = Get-Pane $top $i
    if (-not $p) { return $null }
    $c = $p -split ','
    foreach ($o in @([BannerDrv]::ByClass($procId, 'GhozttyBannerOverlay'))) {
        $r = $o -split ','
        if ([math]::Abs([int]$r[0] - [int]$c[0]) -le 2 -and
            [math]::Abs([int]$r[3] - [int]$c[1]) -le 2) { return $o }
    }
    return $null
}

Kill-RepoInstances

# Pinned dark background so the card pixel oracles are stable, and session
# persistence OFF so the run starts from a BLANK layout. Without that, the
# previous run's layout restores — including its own `bw` window with the
# `bp1` split still in it — and `+new-window --target=bw` idempotently
# focuses that stale window instead of making a fresh one, so every banner
# lands on the restored split's focused pane and pane 0 reads empty. That
# made run 1 pass and runs 2..N fail identically (T131).
# (`=false`, not `=off`: the CLI bool parser takes true/false only — `off`
# is silently rejected and the default `true` stays in force.)
$proc = Start-Process $exe -ArgumentList '--background=#101014', '--session-persistence=false' -PassThru
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$pid32 = [uint32]$proc.Id
& $exe +new-window --target=bw | Out-Null
$bwWin = $null
for ($t = 0; $t -lt 25 -and -not $bwWin; $t++) {
    $bwWin = Get-Win 'bw'
    if (-not $bwWin) { Start-Sleep -Milliseconds 200 }
}
if (-not $bwWin) { Write-Host 'SETUP FAIL: bw window not registered'; exit 1 }
# Window ids are the decimal HWND, so the glass probes target exactly the
# window hosting the 'bw' pane (not the initial launch window).
$top = [IntPtr]([int64]$bwWin.id)

# Pre-banner pane snapshot for the T101 band asserts: the pane HWND must
# shrink from the top by exactly the strip height once a banner is up.
$panePre = $null
for ($t = 0; $t -lt 20 -and -not $panePre; $t++) { $panePre = Get-Pane $top 0; if (-not $panePre) { Start-Sleep -Milliseconds 200 } }
if (-not $panePre) { Write-Host 'SETUP FAIL: no pane HWND in bw'; exit 1 }

# --- 1. +set-banner sets the model (additive +list field) -----------------
& $exe +set-banner --target=bw "**PR #123** - ready [view](https://example.com/pr/123)" | Out-Null
$b = Wait-Banner 'bw' 0 '**PR #123** - ready [view](https://example.com/pr/123)'
Assert ($b -ceq '**PR #123** - ready [view](https://example.com/pr/123)') "+set-banner: +list reports banner source (got $b)"

# --- 2. overlay strip on the glass: glued above the pane, full width ------
$panes = @([BannerDrv]::Panes($top))
Assert ($panes.Count -ge 1) "pane HWND found ($($panes.Count))"
$ov = $null
for ($t = 0; $t -lt 20 -and -not $ov; $t++) { $ov = Get-Overlay $pid32 $top; if (-not $ov) { Start-Sleep -Milliseconds 200 } }
Assert ($null -ne $ov) 'overlay visible and glued above the pane (bottom meets grid top)'
$paneRect = Get-Pane $top 0
$oneLineH = 0
if ($ov) {
    $r = $ov -split ','; $c = $paneRect -split ','
    $oneLineH = [int]$r[3] - [int]$r[1]
    Assert (([int]$r[2] - [int]$r[0]) -eq ([int]$c[2] - [int]$c[0])) 'overlay spans the pane width'
    # Band = card (2x padding + one line) + 2x the card's outer margin
    # (T131), so the sane bound is looser than the pre-card strip's.
    Assert ($oneLineH -gt 0 -and $oneLineH -lt 120) "one-line band height sane ($oneLineH px)"
}

# --- 2b. T101: the strip band is RESERVED — grid starts below the banner ---
# The pane HWND top moved down by exactly the strip height (vs the
# pre-banner snapshot) and the pane bottom is unchanged: the terminal
# genuinely shrank into the band below the strip instead of being covered.
if ($ov) {
    $c = $paneRect -split ','; $pre = $panePre -split ','
    Assert (([int]$c[1] - [int]$pre[1]) -eq $oneLineH) "pane top moved down by the strip height ($($pre[1]) -> $($c[1]), strip $oneLineH)"
    Assert (([int]$c[3]) -eq ([int]$pre[3])) 'pane bottom unchanged (terminal shrank, not shifted)'
} else { $script:fail += 2 }

# --- 3. T131 glass card: floating, opaque, exact wash fill ---------------
# The band is the pane background with a rounded card floating a uniform
# margin inside it. Oracles are pinned to #101014: the card fill is Mac's
# `white @ 6%` composite = rgb(30,30,34), the band is rgb(16,16,20).
if ($ov) {
    # Composited check: park the whole window in the topmost band at a
    # fixed spot so no unrelated desktop window (browser, console) can
    # pollute the sample. The move also exercises reposition tracking
    # (WM_MOVE -> updatePaneBanners re-glues the strip).
    [BannerDrv]::SetWindowPos($top, [IntPtr](-1), 100, 100, 0, 0, 0x0051) | Out-Null
    Start-Sleep -Milliseconds 900
    $paneRect = Get-Pane $top 0
    $ov = Get-Overlay $pid32 $top
    Assert ($null -ne $ov) 'overlay re-glued above the pane after a window move'
    if ($ov) {
        $r = $ov -split ','
        $ovH = [IntPtr]([int64]$r[4])
        $ow = [int]$r[2] - [int]$r[0]
        # Sample low in the card, where neither specular ramp is in play
        # (the sheen has faded, the bottom darkening starts at 75%).
        $cardY = [int]($oneLineH * 0.72)
        $sx = [int]$r[0] + [int]($ow * 0.9)
        $sy = [int]$r[1] + $cardY
        $stripPx = Get-ScreenPx $sx $sy
        $sp = $stripPx -split ','
        $okBand = ([math]::Abs([int]$sp[0] - 30) -le 3) -and
            ([math]::Abs([int]$sp[1] - 30) -le 3) -and
            ([math]::Abs([int]$sp[2] - 34) -le 3)
        Assert $okBand "composited card is the white@6% wash (got $stripPx, want ~30,30,34)"

        # The band's own top-left corner is OUTSIDE the card: it must read
        # the pane background EXACTLY. A translucent overlay (the pre-T131
        # strip) leaks whatever is behind the band through here — that is
        # the "text scrolls behind the banner" bug, and it fails this.
        $cornerPx = Get-ScreenPx ([int]$r[0] + 2) ([int]$r[1] + 2)
        Assert ($cornerPx -eq '16,16,20') "band corner is the pane background, opaque (got $cornerPx)"

        # Own-DC reads pin the exact painted pixels. NOTE: must run AFTER
        # the composited samples — GetDC on a layered window can knock its
        # surface out of the DWM composite until the next repaint.
        $own = [BannerDrv]::OwnPixel($ovH, [int]($ow * 0.9), $cardY)
        Assert ($own -eq $stripPx) "card is fully opaque: composited pixel == own-DC pixel ($stripPx vs $own)"
        $ownCorner = [BannerDrv]::OwnPixel($ovH, 2, 2)
        Assert ($ownCorner -eq '16,16,20') "card is inset by a margin on every side (corner $ownCorner)"

        # Elevation shadow: somewhere in the bottom margin the band is
        # DARKER than the bare pane background (the margin is DPI-scaled,
        # so scan it rather than pinning one row).
        $darkest = 999
        $shadowPx = ''
        for ($dy = 2; $dy -le 14; $dy++) {
            $s = [BannerDrv]::OwnPixel($ovH, [int]($ow / 2), $oneLineH - $dy)
            $parts = $s -split ','
            $sum = [int]$parts[0] + [int]$parts[1] + [int]$parts[2]
            if ($sum -lt $darkest) { $darkest = $sum; $shadowPx = $s }
        }
        Assert ($darkest -lt 52) "elevation shadow darkens the band under the card (darkest $shadowPx vs bg 16,16,20)"
    } else {
        $script:fail += 5
    }
} else {
    $script:fail += 6
}

# --- 4. multi-line: \n grows the strip; 10-line display cap ---------------
& $exe +set-banner --target=bw "line1\nline2\nline3" | Out-Null
$b = Wait-Banner 'bw' 0 "line1`nline2`nline3"
Assert ($b -ceq "line1`nline2`nline3") 'multi-line: +list carries real newlines'
$ov3 = Get-Overlay $pid32 $top
$threeLineH = 0
if ($ov3) { $r = $ov3 -split ','; $threeLineH = [int]$r[3] - [int]$r[1] }
Assert ($threeLineH -gt $oneLineH + 10) "3-line strip taller than 1-line ($oneLineH -> $threeLineH px)"

# 12 source lines must clamp to 10 display lines: between 9 and 10 lines'
# height (a 2-line pair adds $twoLines px = 2 * (line height + block gap)).
& $exe +set-banner --target=bw "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl" | Out-Null
Start-Sleep -Milliseconds 800
$ovCap = Get-Overlay $pid32 $top
$capH = 0
if ($ovCap) { $r = $ovCap -split ','; $capH = [int]$r[3] - [int]$r[1] }
$twoLines = $threeLineH - $oneLineH
Assert ($capH -gt ($oneLineH + 4 * $twoLines) -and $capH -le ($oneLineH + 4.5 * $twoLines + 8)) "12-line source capped at 10 display lines ($capH px)"

# --- 5. --clear removes model + glass, reverts the pixel ------------------
$paneWithCap = (Get-Pane $top 0) -split ','   # capped banner still up (T101)
& $exe +set-banner --target=bw --clear | Out-Null
$b = Wait-Banner 'bw' 0 'NONE'
Assert ($b -eq '(absent)') '--clear: banner absent from +list'
Start-Sleep -Milliseconds 500
Assert ($null -eq (Get-Overlay $pid32 $top)) '--clear: overlay gone'
Assert (@([BannerDrv]::ByClass($pid32, 'GhozttyBannerOverlay')).Count -eq 0) '--clear: no overlay windows remain on the glass'
# T101: the vacated strip band went back to the terminal.
$paneCleared = (Get-Pane $top 0) -split ','
Assert (([int]$paneWithCap[1] - [int]$paneCleared[1]) -eq $capH) "--clear: grid grew back by the strip height ($capH px)"

# --- 6. empty text equals clear; clearing when clear succeeds -------------
& $exe +set-banner --target=bw "again" | Out-Null
$null = Wait-Banner 'bw' 0 'again'
& $exe +set-banner --target=bw "" | Out-Null
$b = Wait-Banner 'bw' 0 'NONE'
Assert ($b -eq '(absent)') 'empty text clears'
& $exe +set-banner --target=bw --clear | Out-Null
Assert ($LASTEXITCODE -eq 0) 'clearing an already-clear banner succeeds'

# --- 6b. T91: heading renders taller than a plain text line ----------------
& $exe +set-banner --target=bw "# Big title" | Out-Null
$null = Wait-Banner 'bw' 0 '# Big title'
$ovH = Get-Overlay $pid32 $top
$headH = 0
if ($ovH) { $r = $ovH -split ','; $headH = [int]$r[3] - [int]$r[1] }
Assert ($headH -gt ($oneLineH + 4)) "h1 heading strip taller than plain line ($oneLineH -> $headH px)"

# --- 6c. T91: --- thematic break renders as a thin rule row ----------------
# text + rule + text sits between a 2-line and a 3-line text banner: the
# rule row is a 1px line, thinner than a text line.
& $exe +set-banner --target=bw "top\n---\nbottom" | Out-Null
$null = Wait-Banner 'bw' 0 "top`n---`nbottom"
$ovR = Get-Overlay $pid32 $top
$hrH = 0
if ($ovR) { $r = $ovR -split ','; $hrH = [int]$r[3] - [int]$r[1] }
$twoLineH = $oneLineH + [int]($twoLines / 2)
Assert ($hrH -gt $twoLineH -and $hrH -lt $threeLineH) "hr row is thinner than a text row ($twoLineH < $hrH < $threeLineH)"

# --- 6d. T91: pipe table renders (separator row dropped) -------------------
& $exe +set-banner --target=bw "| Job | State |\n|---|---:|\n| lint | ok |\n| tests | **3 failed** |" | Out-Null
$null = Wait-Banner 'bw' 0 "| Job | State |`n|---|---:|`n| lint | ok |`n| tests | **3 failed** |"
$ovT = Get-Overlay $pid32 $top
$tblH = 0
if ($ovT) { $r = $ovT -split ','; $tblH = [int]$r[3] - [int]$r[1] }
# 4 source lines -> 3 display rows (header + 2 body; separator dropped):
# taller than 2 text lines, no taller than ~3 text lines + header divider.
Assert ($tblH -gt $twoLineH -and $tblH -le ($threeLineH + 10)) "table: 4 source lines render 3 rows ($tblH px)"
Assert (-not $proc.HasExited) 'table banner: GUI alive after paint'

# --- 6e. T91: checked task-list box paints native green --------------------
& $exe +set-banner --target=bw "[x] done\n[ ] todo" | Out-Null
$null = Wait-Banner 'bw' 0 "[x] done`n[ ] todo"
Start-Sleep -Milliseconds 400
$ovC = Get-Overlay $pid32 $top
if ($ovC) {
    $r = $ovC -split ','
    $ovhH = [IntPtr]([int64]$r[4])
    # First list row's marker gutter sits just inside the card's 12dip
    # padding, which is itself one 12dip card margin in from the band edge
    # (T131) — so scan from the band origin out past both.
    $green = [BannerDrv]::ScanGreen($ovhH, 5, 5, 80, 80)
    Assert ($green -ge 3) "checked box paints green check pixels ($green found)"
    # Force a repaint so the own-DC read doesn't leave a stale composite.
    & $exe +set-banner --target=bw "[x] done\n[ ] todo" | Out-Null
} else {
    $script:fail++
    Write-Host 'FAIL  checkbox overlay not found' -ForegroundColor Red
}

# --- 6f. T91: multi-line banner collapses on click, expands on click -------
& $exe +set-banner --target=bw "head\nrow2\nrow3" | Out-Null
$null = Wait-Banner 'bw' 0 "head`nrow2`nrow3"
Start-Sleep -Milliseconds 400
$ovE = Get-Overlay $pid32 $top
if ($ovE) {
    $r = $ovE -split ','
    $expandH = [int]$r[3] - [int]$r[1]
    $paneExp = (Get-Pane $top 0) -split ','
    $ovhH = [IntPtr]([int64]$r[4])
    $midX = [int](([int]$r[2] - [int]$r[0]) / 2)
    [BannerDrv]::ClickClient($ovhH, $midX, [int]($oneLineH / 2))
    $collapseH = $expandH
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 150
        $ov2 = Get-Overlay $pid32 $top
        if ($ov2) { $r2 = $ov2 -split ','; $collapseH = [int]$r2[3] - [int]$r2[1] }
        if ($collapseH -lt $expandH) { break }
    }
    Assert ($collapseH -lt ($expandH - 20) -and $collapseH -gt 20) "click collapses the banner ($expandH -> $collapseH px)"
    # T101: the terminal band grew by exactly the collapsed delta (the
    # Get-Overlay matcher already proves the strip re-glued above the
    # moved pane top; this pins the magnitude).
    $paneCol = (Get-Pane $top 0) -split ','
    Assert ((([int]$paneExp[1]) - ([int]$paneCol[1])) -eq ($expandH - $collapseH)) "collapse gave the band back to the grid ($expandH -> $collapseH strip, pane top $($paneExp[1]) -> $($paneCol[1]))"
    [BannerDrv]::ClickClient($ovhH, $midX, [int]($collapseH / 2))
    $reH = $collapseH
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 150
        $ov2 = Get-Overlay $pid32 $top
        if ($ov2) { $r2 = $ov2 -split ','; $reH = [int]$r2[3] - [int]$r2[1] }
        if ($reH -eq $expandH) { break }
    }
    Assert ($reH -eq $expandH) "second click expands back ($collapseH -> $reH px)"
} else {
    $script:fail += 2
    Write-Host 'FAIL  collapse overlay not found' -ForegroundColor Red
}
& $exe +set-banner --target=bw --clear | Out-Null
$null = Wait-Banner 'bw' 0 'NONE'

# --- 6g. T123: table columns size to the PANE, not a fixed 360pt cap -------
# The banner used to size every table column at min(natural, 360px), so a
# value wider than 360 wrapped on a pane with hundreds of px to spare, and
# narrowing the pane never rewrapped it. Every oracle here is the BAND
# HEIGHT, which is the number of display rows the table produced — a
# self-relative measure that needs no pixel constants.
$oneRow = [int]($twoLines / 2)   # one text row incl. its row gap
# Wide value: naturally ~2x the old 360px cap, but comfortably inside a
# 1400px pane. Short value: the same table with a one-word value.
$longVal = 'ready to merge after the final review pass lands on main'
$tblLong = "| Goal | Value |\n|---|---|\n| ship | $longVal |"
$tblShort = "| Goal | Value |\n|---|---|\n| ship | ok |"
function Get-BandH([string]$text) {
    & $exe +set-banner --target=bw $text | Out-Null
    $null = Wait-Banner 'bw' 0 ($text -replace '\\n', "`n")
    Start-Sleep -Milliseconds 700
    $o = Get-Overlay $pid32 $top
    if (-not $o) { return 0 }
    $r = $o -split ','
    return [int]$r[3] - [int]$r[1]
}

# Wide pane: the long value must NOT wrap - it fits, so it gets its natural
# width and the table is the same height as the short-value one.
[BannerDrv]::SetWindowPos($top, [IntPtr](-1), 100, 100, 1400, 700, 0x0040) | Out-Null
Start-Sleep -Milliseconds 900
$wideShortH = Get-BandH $tblShort
$wideLongH = Get-BandH $tblLong
$paneWide = (Get-Pane $top 0) -split ','
$wideW = [int]$paneWide[2] - [int]$paneWide[0]
Assert ($wideShortH -gt 0 -and $wideLongH -gt 0) "wide pane: banner measured ($wideShortH / $wideLongH px)"
Assert ($wideLongH -eq $wideShortH) "wide pane: a >360px value does not wrap (short $wideShortH == long $wideLongH px)"

# Narrow pane: the SAME banner must reflow - more rows, taller band. Before
# the fix the columns were pinned at 360px and this height never moved.
[BannerDrv]::SetWindowPos($top, [IntPtr](-1), 100, 100, 520, 700, 0x0040) | Out-Null
Start-Sleep -Milliseconds 900
$narrowLongH = Get-BandH $tblLong
$paneNarrow = (Get-Pane $top 0) -split ','
$narrowW = [int]$paneNarrow[2] - [int]$paneNarrow[0]
Assert ($narrowW -lt $wideW - 500) "the pane really shrank ($wideW -> $narrowW px): the banner is no minimum width"
Assert ($narrowLongH -gt $wideLongH) "narrow pane: the table reflowed taller ($wideLongH -> $narrowLongH px)"
# A wrapped line INSIDE a cell adds the bare line height, while $oneRow is
# a line height plus the 8/20 inter-block gap - so a real extra display
# line is always more than 60% of $oneRow, at any DPI. That separates a
# genuine rewrap from a rounding wobble without hard-coding pixels.
Assert (($narrowLongH - $wideLongH) -ge [int]($oneRow * 0.6)) "narrow pane: reflow added a whole display line (+$($narrowLongH - $wideLongH) px, row ~$oneRow px)"

# A long UNBROKEN token has no space to wrap at, so it must break
# mid-string; before the fix it took one over-wide line and clipped.
$blob = 'A' * 90
$narrowBlobH = Get-BandH "| K | V |\n|---|---|\n| x | $blob |"
Assert ($narrowBlobH -gt ($wideShortH + $oneRow - 4)) "narrow pane: a 90-char unbroken token breaks mid-string ($narrowBlobH px vs 1-row $wideShortH px)"

# A cell is capped at 3 display lines: 4x the text must not make the band
# any taller than 2x did.
$sentence = 'the quick brown fox jumps over the lazy dog and keeps on running '
$cap2 = Get-BandH ("| K | V |\n|---|---|\n| x | " + ($sentence * 2).Trim() + " |")
$cap8 = Get-BandH ("| K | V |\n|---|---|\n| x | " + ($sentence * 8).Trim() + " |")
Assert ($cap8 -eq $cap2) "cell capped at 3 wrapped lines: 4x the text is the same height ($cap2 vs $cap8 px)"
# 3 lines instead of 1 is +2 display lines, each smaller than $oneRow.
Assert ($cap8 -le ($wideShortH + 2 * $oneRow)) "capped cell stays within header + 3 lines ($cap8 px, 1-row $wideShortH px, row ~$oneRow px)"
Assert (-not $proc.HasExited) 'reflow section: GUI alive'

& $exe +set-banner --target=bw --clear | Out-Null
$null = Wait-Banner 'bw' 0 'NONE'
[BannerDrv]::SetWindowPos($top, [IntPtr](-1), 100, 100, 1100, 700, 0x0040) | Out-Null
Start-Sleep -Milliseconds 900

# --- 7. per-pane: named split pane gets its own banner ---------------------
& $exe +split --target=bw --name=bp1 --direction=down | Out-Null
Start-Sleep -Seconds 1
& $exe +set-banner --target=bp1 "split banner" | Out-Null
$b = Wait-Banner 'bw' 1 'split banner'
Assert ($b -ceq 'split banner') "pane target: split pane banner set (got $b)"
# T101: the strip band reserves the top of the SPLIT pane's slot too
# (geometric pane index 1 = the lower pane of the down-split).
$ovS = $null
for ($t = 0; $t -lt 15 -and -not $ovS; $t++) { $ovS = Get-Overlay $pid32 $top 1; if (-not $ovS) { Start-Sleep -Milliseconds 200 } }
Assert ($null -ne $ovS) 'split pane: strip glued above the split pane (T101 band inside a split slot)'
$b = Wait-Banner 'bw' 0 'NONE'
Assert ($b -eq '(absent)') 'pane target: first pane untouched'

# window target applies to the window's focused pane (the new split).
& $exe +set-banner --target=bw "focused pane banner" | Out-Null
$b = Wait-Banner 'bw' 1 'focused pane banner'
Assert ($b -ceq 'focused pane banner') "window target hits the focused pane (got $b)"
& $exe +set-banner --target=bp1 --clear | Out-Null

# --- 8. markdown link renders (overlay still paints with styles) ----------
# (Rendering correctness is pinned by the banner_markdown unit tests; here
# we only prove a styled multi-run banner paints without crashing.)
& $exe +set-banner --target=bw "**b** *i* __u__ ``c`` [l](https://x.io)" | Out-Null
Start-Sleep -Milliseconds 800
Assert (-not $proc.HasExited) 'styled banner: GUI alive after paint'
& $exe +set-banner --target=bw --clear | Out-Null

# --- 9. OSC 7778 round-trip from inside the pane ---------------------------
# Spaces in the payload are built with [char]32: PS 5.1 mangles embedded
# quotes when spawning natives, splitting spaced args, and +send-keys
# concatenates positionals without separators.
$oscSet = "powershell -NoProfile -Command `"[console]::Write([char]27+']7778;osc'+[char]32+'banner'+[char]32+'works'+[char]7)`""
& $exe +send-keys --target=bp1 $oscSet Enter 2>&1 | Out-Null
$b = Wait-Banner 'bw' 1 'osc banner works'
Assert ($b -ceq 'osc banner works') "OSC 7778 sets the banner (got $b)"
$oscClear = "powershell -NoProfile -Command `"[console]::Write([char]27+']7778;'+[char]7)`""
& $exe +send-keys --target=bp1 $oscClear Enter 2>&1 | Out-Null
$b = Wait-Banner 'bw' 1 'NONE'
Assert ($b -eq '(absent)') 'OSC 7778 empty text clears'

# --- 10. unknown target errors ---------------------------------------------
$eap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $exe +set-banner --target=nosuch "x" 2>$null | Out-Null
$ErrorActionPreference = $eap
Assert ($LASTEXITCODE -ne 0) 'unknown target: nonzero exit'

# --- 11. editor dialog: ctrl+shift+b opens, ctrl+enter commits, esc cancels
$fg = [BannerDrv]::Foreground($top)
if ($fg -ne 'OK') {
    Write-Host "SKIP  editor section: cannot foreground window ($fg)"
    $script:fail++
} else {
    & $exe +set-banner --target=bw "prefill" | Out-Null
    $null = Wait-Banner 'bw' 1 'prefill'  # focused pane is still bp1's slot
    [BannerDrv]::Chord(@(0x11, 0x10), 0x42)  # ctrl+shift+b
    $dlg = @()
    for ($t = 0; $t -lt 20; $t++) {
        $dlg = @([BannerDrv]::ByClass($pid32, 'GhozttyBannerDialog'))
        if ($dlg.Count -ge 1) { break }
        Start-Sleep -Milliseconds 150
    }
    Assert ($dlg.Count -ge 1) 'ctrl+shift+b opens the banner editor'
    if ($dlg.Count -ge 1) {
        # Prefill is select-all; typing 'x' replaces it. Ctrl+Enter saves.
        [BannerDrv]::Key(0x58, $false); [BannerDrv]::Key(0x58, $true)  # 'x'
        Start-Sleep -Milliseconds 150
        [BannerDrv]::Chord(@(0x11), 0x0D)  # ctrl+enter
        $b = Wait-Banner 'bw' 1 'x'
        Assert ($b -ceq 'x') "editor commit: banner replaced (got $b)"
        Assert (@([BannerDrv]::ByClass($pid32, 'GhozttyBannerDialog')).Count -eq 0) 'editor closed after commit'

        # Escape cancels without applying.
        [BannerDrv]::Chord(@(0x11, 0x10), 0x42)
        Start-Sleep -Milliseconds 600
        [BannerDrv]::Key(0x59, $false); [BannerDrv]::Key(0x59, $true)  # 'y'
        Start-Sleep -Milliseconds 150
        [BannerDrv]::Key(0x1B, $false); [BannerDrv]::Key(0x1B, $true)  # esc
        Start-Sleep -Milliseconds 400
        $b = Wait-Banner 'bw' 1 'x'
        Assert ($b -ceq 'x') "editor cancel: banner unchanged (got $b)"
        Assert (@([BannerDrv]::ByClass($pid32, 'GhozttyBannerDialog')).Count -eq 0) 'editor closed after cancel'
    }
}

# --- 12. app alive, +list responsive ---------------------------------------
Assert (-not $proc.HasExited) 'GUI process alive after all scenarios'
$json = (& $exe +list --json 2>$null | Out-String).Trim()
Assert ($json -match '"success":true') '+list still responds'

Kill-RepoInstances

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
