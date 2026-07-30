# T190 acceptance: the Windows menu system - tab-strip button, HMENU host,
# dispatch, state, and keyboard activation.
#
# T189 landed the pure model (commands.zig + menu_bar.zig) and the single
# dispatch entry point; NONE of it was reachable. This script measures the
# reachable half, always by OUTCOME:
#
#   A: the button exists at the right end of the tab strip and opens a menu -
#      and it is a BUTTON, not "anywhere in the strip": clicking left of it
#      hits the "+" (a tab appears) and clicking mid-strip does nothing.
#      Plus a pixel check that the glyph is actually painted, with a blank
#      strip region as its negative control.
#   B: the whole tree is there - walked RECURSIVELY, so a missing submenu
#      cannot hide behind a matching item count.
#   C: choosing a row performs its command, one representative per submenu,
#      asserted by outcome (File>New Tab grows +list; View>Terminal Read-only
#      comes back CHECKED; Window>Zoom Split hides a pane's window).
#   D: state gating is live (Copy, Close Tab, Zoom Split, the split submenus).
#   E: Exit says "(keep sessions)" only with session-persistence on (T89e).
#   F: a rebind relabels its row - the label comes from the LIVE keybind set.
#   G: keyboard activation - F10 and a lone Alt open the menu; alt+<key> does
#      not; and F10 is passed through to a full-screen TUI (alternate screen)
#      instead of opening the menu, then works again on the primary screen.
#
# Menu contents are read from the LIVE popup via MN_GETHMENU + cross-process
# GetMenuItemInfo-family calls (never GetWindowTextW, which reads a cache the
# app never sees). Mouse/keys are PostMessage-driven, so the run needs neither
# foreground nor SendInput except for the one pixel section, which says so.
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

# Non-ASCII menu text is built from code points: this file stays ASCII so no
# editor/shell in the chain can mojibake it (the standing PS5.1 trap).
$EL = [char]0x2026   # HORIZONTAL ELLIPSIS, as used by the "..." menu rows

Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class MenuDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint idItem, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int pos);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() { SetProcessDpiAwarenessContext((IntPtr)(-4)); }

    public static IntPtr FindTop(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindPane(IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Every terminal child of a window, visible or not, and how many of them
    // are visible (the Zoom Split oracle: zooming HIDES the other panes).
    public static int VisiblePanes(IntPtr top) {
        int n = 0;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) n++;
            return true;
        }, IntPtr.Zero);
        return n;
    }

    public static IntPtr MenuWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
            if (sb.ToString() == "#32768" && IsWindowVisible(h)) {
                uint p; GetWindowThreadProcessId(h, out p);
                if (p == pid) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Visible top-level window of a class owned by pid, waited for.
    public static IntPtr WindowOfClass(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls && IsWindowVisible(h)) {
                uint p; GetWindowThreadProcessId(h, out p);
                if (p == pid) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr WaitClass(uint pid, string cls, int ms) {
        for (int t = 0; t < ms; t += 50) {
            IntPtr h = WindowOfClass(pid, cls);
            if (h != IntPtr.Zero) return h;
            Thread.Sleep(50);
        }
        return IntPtr.Zero;
    }

    public static IntPtr WaitMenu(uint pid, int ms) {
        for (int t = 0; t < ms; t += 50) { IntPtr h = MenuWindow(pid); if (h != IntPtr.Zero) return h; Thread.Sleep(50); }
        return IntPtr.Zero;
    }

    public static bool WaitMenuGone(uint pid, int ms) {
        for (int t = 0; t < ms; t += 50) { if (MenuWindow(pid) == IntPtr.Zero) return true; Thread.Sleep(50); }
        return false;
    }

    // Click in the tab strip at (x, y) in CLIENT coords; x < 0 counts back
    // from the right edge.
    public static void ClickStrip(IntPtr top, int x, int y) {
        RECT rc; GetClientRect(top, out rc);
        if (x < 0) x = (rc.right - rc.left) + x;
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        PostMessageW(top, 0x0201, (IntPtr)1, lp); // WM_LBUTTONDOWN
        PostMessageW(top, 0x0202, IntPtr.Zero, lp); // WM_LBUTTONUP
    }

    public static void MoveInStrip(IntPtr top, int x, int y) {
        RECT rc; GetClientRect(top, out rc);
        if (x < 0) x = (rc.right - rc.left) + x;
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        PostMessageW(top, 0x0200, IntPtr.Zero, lp); // WM_MOUSEMOVE
    }

    // Keys into the thread queue: the menu's modal loop and the pane's
    // WndProc both read from it.
    public static void PostKey(IntPtr h, ushort vk) {
        PostMessageW(h, 0x0100, (IntPtr)vk, IntPtr.Zero);          // WM_KEYDOWN
        PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)unchecked((int)0xC0000001)); // WM_KEYUP
    }
    public static void PostSysKeyDown(IntPtr h, ushort vk) {
        PostMessageW(h, 0x0104, (IntPtr)vk, IntPtr.Zero);          // WM_SYSKEYDOWN
    }
    public static void PostSysKeyUp(IntPtr h, ushort vk) {
        PostMessageW(h, 0x0105, (IntPtr)vk, (IntPtr)unchecked((int)0xC0000001)); // WM_SYSKEYUP
    }

    public static void CancelMenu(IntPtr h) {
        IntPtr r; SendMessageTimeoutW(h, 0x001F, IntPtr.Zero, IntPtr.Zero, 2, 2000, out r); // WM_CANCELMODE
    }

    // The live popup's whole tree, one line per row:
    //   "<path>/<label>[\t<accel>][:grayed][:checked]", submenus as "<label> >".
    //
    // GetSubMenu is checked BEFORE the MF_SEPARATOR bit on purpose: for a
    // popup row GetMenuState returns the submenu's ITEM COUNT in the high
    // byte, so any submenu with 8..15 items sets 0x800 and reads as a
    // separator. (That mis-read cost a debugging round on the first run.)
    public static string[] Tree(IntPtr menuWnd) {
        IntPtr result;
        SendMessageTimeoutW(menuWnd, 0x01E1, IntPtr.Zero, IntPtr.Zero, 2, 2000, out result); // MN_GETHMENU
        var acc = new List<string>();
        if (result != IntPtr.Zero) Walk(result, "", acc);
        return acc.ToArray();
    }
    static void Walk(IntPtr menu, string prefix, List<string> acc) {
        int n = GetMenuItemCount(menu);
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            IntPtr sub = GetSubMenu(menu, (int)i);
            if (sub == IntPtr.Zero && (state & 0x800) != 0) { acc.Add(prefix + "---"); continue; }
            var sb = new StringBuilder(160);
            GetMenuStringW(menu, i, sb, 160, 0x400);
            string label = sb.ToString();
            if (sub != IntPtr.Zero) {
                acc.Add(prefix + label + " >");
                Walk(sub, prefix + label + "/", acc);
            } else {
                string flags = "";
                if ((state & 0x3) != 0) flags += ":grayed";  // MF_GRAYED|MF_DISABLED
                if ((state & 0x8) != 0) flags += ":checked"; // MF_CHECKED
                acc.Add(prefix + label + flags);
            }
        }
    }

    // Client-rect origin in screen coords, for the pixel section.
    public static POINT ClientOrigin(IntPtr h) {
        POINT p; p.x = 0; p.y = 0; ClientToScreen(h, ref p); return p;
    }
    public static RECT Client(IntPtr h) { RECT r; GetClientRect(h, out r); return r; }
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);

    static void Key(byte vk, bool up) { keybd_event(vk, 0, up ? 2u : 0u, UIntPtr.Zero); }

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

[MenuDrv]::BeDpiAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

function Start-Gui([string]$label, [string[]]$extraArgs) {
    Kill-RepoInstances
    # A stale debug layout manifest would restore a previous run's windows
    # over the one under test (the T131 lesson).
    Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
    $argList = @('--config-default-files=false') + $extraArgs
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [MenuDrv]::FindTop([uint32]$proc.Id)
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    $pane = [MenuDrv]::FindPane($top)
    if ($pane -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): pane not found"; exit 1 }
    [pscustomobject]@{ Proc = $proc; Top = $top; Pane = $pane; Pid = [uint32]$proc.Id }
}

function List-Json { & $exe +list --json 2>$null | ConvertFrom-Json }

# `+read`'s exit code, with its stderr swallowed. A bare native command that
# writes to stderr is a TERMINATING error under $ErrorActionPreference=Stop
# (PS5.1 wraps each line in a NativeCommandError), and here a FAILING read is
# the measurement, not a fault.
function Read-Exit([string]$name) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $exe +read --name=$name --lines=3 2>&1
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

# Pane text, or '' when the read fails (same stderr caveat as Read-Exit).
function Read-Text([string]$name, [int]$lines = 20) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe +read --name=$name --lines=$lines 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return '' }
        return $out
    } finally { $ErrorActionPreference = $old }
}
function Pane-Name {
    $j = List-Json
    $t = $j.data.windows[0].tabs[0].splits
    if ($t.type -eq 'leaf') { return $t.terminal.name }
    return $t.left.terminal.name
}

# The name of the pane that has KEYBOARD focus, in the selected tab. Sending
# a pane's shell one thing while typing at another is how the first run of
# section G lied to itself (the zoomed pane was not the one it had switched
# to the alternate screen).
function Walk-Focused($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') {
        if ($node.terminal.focused) { return $node.terminal.name }
        return $null
    }
    $l = Walk-Focused $node.left
    if ($null -ne $l) { return $l }
    return Walk-Focused $node.right
}
function Focused-Pane-Name {
    $j = List-Json
    foreach ($tab in $j.data.windows[0].tabs) {
        if (-not $tab.selected) { continue }
        $n = Walk-Focused $tab.splits
        if ($null -ne $n) { return $n }
    }
    return (Pane-Name)
}
function Tab-Count { @((List-Json).data.windows[0].tabs).Count }

# Open the menu from the tab-strip button and return the live tree.
function Open-Menu($g, [int]$waitMs = 3000) {
    [MenuDrv]::ClickStrip($g.Top, -10, 8)
    $m = [MenuDrv]::WaitMenu($g.Pid, $waitMs)
    if ($m -eq [IntPtr]::Zero) { return $null }
    [MenuDrv]::Tree($m)
}

function Close-Menu($g) {
    [MenuDrv]::PostKey($g.Top, 0x1B) # VK_ESCAPE
    if (-not [MenuDrv]::WaitMenuGone($g.Pid, 1500)) {
        [MenuDrv]::CancelMenu($g.Top)
        [MenuDrv]::WaitMenuGone($g.Pid, 2000) | Out-Null
    }
}

# "path/Label<tab>Accel:flags" -> its parts.
function Split-Row([string]$s) {
    $flags = ''
    $more = $true
    while ($more) {
        $more = $false
        foreach ($f in @(':grayed', ':checked')) {
            if ($s.EndsWith($f)) { $flags = $f + $flags; $s = $s.Substring(0, $s.Length - $f.Length); $more = $true }
        }
    }
    $accel = ''
    $tab = $s.IndexOf("`t")
    if ($tab -ge 0) { $accel = $s.Substring($tab + 1); $s = $s.Substring(0, $tab) }
    [pscustomobject]@{ Path = $s; Accel = $accel; Flags = $flags }
}
function Rows($tree) { @($tree | ForEach-Object { Split-Row $_ }) }
function Row($tree, [string]$path) {
    $r = @(Rows $tree | Where-Object { $_.Path -eq $path })
    if ($r.Count -eq 0) { return $null }
    $r[0]
}
function Row-Flags($tree, [string]$path) {
    $r = Row $tree $path
    if ($null -eq $r) { return '<missing>' }
    $r.Flags
}

# The tree the model says exists (menu_bar.zig `root`), as paths in order.
$expectedTree = @(
    '&File >'
    "&File/&New Window"
    "&File/New &Remote Window"
    "&File/New &Tab"
    '&File/---'
    "&File/Split R&ight"
    "&File/Split &Left"
    "&File/Split &Down"
    "&File/Split &Up"
    '&File/---'
    "&File/&Close Pane"
    "&File/Close Ta&b"
    "&File/Close &Window"
    "&File/Close &All Windows"
    '&File/---'
    "&File/E&xit"
    '&Edit >'
    "&Edit/&Copy"
    "&Edit/&Paste"
    "&Edit/Select &All"
    '&Edit/---'
    "&Edit/&Find$EL"
    "&Edit/Find &Next"
    "&Edit/Find Pre&vious"
    "&Edit/&Hide Find Bar"
    '&Edit/---'
    "&Edit/&Use Selection for Find"
    "&Edit/&Jump to Selection"
    '&View >'
    "&View/&Reset Font Size"
    "&View/&Increase Font Size"
    "&View/&Decrease Font Size"
    '&View/---'
    "&View/Command &Palette"
    '&View/---'
    "&View/Change &Window Title$EL"
    "&View/Change &Tab Title$EL"
    "&View/Change Pan&e Title$EL"
    "&View/Set Pane &Banner$EL"
    '&View/---'
    "&View/Terminal Read-&only"
    '&View/---'
    "&View/&Quick Terminal"
    '&Window >'
    "&Window/Toggle &Full Screen"
    "&Window/Ma&ximize"
    "&Window/Show/&Hide All Terminals"
    '&Window/---'
    "&Window/&Zoom Split"
    "&Window/Toggle Hero &Mode"
    "&Window/Select &Previous Split"
    "&Window/Select &Next Split"
    '&Window/&Select Split >'
    "&Window/&Select Split/Select Split &Above"
    "&Window/&Select Split/Select Split &Below"
    "&Window/&Select Split/Select Split &Left"
    "&Window/&Select Split/Select Split &Right"
    '&Window/S&wap Split >'
    "&Window/S&wap Split/Swap Split &Up"
    "&Window/S&wap Split/Swap Split &Down"
    "&Window/S&wap Split/Swap Split &Left"
    "&Window/S&wap Split/Swap Split &Right"
    '&Window/&Resize Split >'
    "&Window/&Resize Split/&Equalize Splits"
    '&Window/&Resize Split/---'
    "&Window/&Resize Split/Move Divider &Up"
    "&Window/&Resize Split/Move Divider &Down"
    "&Window/&Resize Split/Move Divider &Left"
    "&Window/&Resize Split/Move Divider &Right"
    '&Window/---'
    "&Window/Previous &Tab"
    "&Window/Next Ta&b"
    "&Window/&Last Tab"
    '&Window/---'
    "&Window/Return To &Default Size"
    '&Help >'
    "&Help/Ghoztty &Help"
    '&Help/---'
    "&Help/Check for &Updates$EL"
    "&Help/Install &Claude Code Integration"
    '&Help/---'
    "&Help/&About Ghoztty"
    '---'
    "&Settings"
    "&Reload Configuration"
)

# ===========================================================================
# Run 1: sections A, B, C, D, G (session-persistence off).
# ===========================================================================
$g = Start-Gui 'main' @('--session-persistence=false')

# --- A: the button ---------------------------------------------------------
$tree = Open-Menu $g
Assert ($null -ne $tree) 'A: clicking the right end of the tab strip opens the menu'
Close-Menu $g

# It is a button, not "the strip": mid-strip is dead space, and the rect just
# left of it is still the "+".
$tabsBefore = Tab-Count
[MenuDrv]::ClickStrip($g.Top, 200, 8)
$m = [MenuDrv]::WaitMenu($g.Pid, 1200)
Assert ($m -eq [IntPtr]::Zero) 'A: clicking mid-strip does NOT open the menu'
if ($m -ne [IntPtr]::Zero) { Close-Menu $g }

[MenuDrv]::ClickStrip($g.Top, -46, 8)   # one button-width left of the "="
Start-Sleep -Milliseconds 900
$m = [MenuDrv]::WaitMenu($g.Pid, 300)
Assert ($m -eq [IntPtr]::Zero) 'A: the "+" button did not open the menu'
if ($m -ne [IntPtr]::Zero) { Close-Menu $g }
$tabsAfterPlus = Tab-Count
Assert ($tabsAfterPlus -eq $tabsBefore + 1) "A: the rect left of the menu button is still the + (tabs $tabsBefore -> $tabsAfterPlus)"

# --- A(pixels): the glyph is painted --------------------------------------
# Everything else here is hit-testing; this is the only assertion that the
# button is VISIBLE. Needs the foreground, so it is skipped (not failed) if
# the box refuses to hand it over.
if ([MenuDrv]::GrabForeground($g.Top)) {
    Start-Sleep -Milliseconds 400
    $org = [MenuDrv]::ClientOrigin($g.Top)
    $cr = [MenuDrv]::Client($g.Top)
    $cw = $cr.right - $cr.left
    function Ink([int]$xClient, [int]$w, [int]$h) {
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($org.x + $xClient, $org.y + 2, 0, 0, (New-Object System.Drawing.Size($w, $h)))
        $gfx.Dispose()
        $counts = @{}
        for ($yy = 0; $yy -lt $h; $yy++) { for ($xx = 0; $xx -lt $w; $xx++) {
            $c = $bmp.GetPixel($xx, $yy).ToArgb()
            if ($counts.ContainsKey($c)) { $counts[$c]++ } else { $counts[$c] = 1 }
        } }
        # The rect's own most-common color is the bar background; anything
        # far from it is ink.
        $modal = ($counts.GetEnumerator() | Sort-Object -Property Value -Descending)[0]
        $base = [System.Drawing.Color]::FromArgb($modal.Key)
        $ink = 0
        for ($yy = 0; $yy -lt $h; $yy++) { for ($xx = 0; $xx -lt $w; $xx++) {
            $p = $bmp.GetPixel($xx, $yy)
            if ([Math]::Abs($p.R - $base.R) -gt 24 -or [Math]::Abs($p.G - $base.G) -gt 24 -or [Math]::Abs($p.B - $base.B) -gt 24) { $ink++ }
        } }
        $bmp.Dispose()
        $ink
    }
    $btnInk = Ink ($cw - 36) 34 26
    $blankInk = Ink ([int]($cw / 2)) 34 26
    Assert ($btnInk -gt 8) "A: the menu button paints a glyph ($btnInk ink pixels)"
    Assert ($blankInk -le 2) "A: blank strip control has no ink ($blankInk pixels) - the probe measures ink"
} else {
    Write-Host 'SKIP A(pixels): could not take the foreground'
}

# --- B: the whole tree -----------------------------------------------------
$tree = Open-Menu $g
Assert ($null -ne $tree) 'B: menu opens for the tree walk'
if ($null -ne $tree) {
    $paths = @(Rows $tree | ForEach-Object { $_.Path })
    Assert ($paths.Count -eq $expectedTree.Count) "B: tree has $($expectedTree.Count) rows (got $($paths.Count))"
    $bad = @()
    for ($i = 0; $i -lt [Math]::Min($paths.Count, $expectedTree.Count); $i++) {
        if ($paths[$i] -ne $expectedTree[$i]) { $bad += "row $i got '$($paths[$i])' want '$($expectedTree[$i])'" }
    }
    Assert ($bad.Count -eq 0) 'B: every submenu, row and separator matches the model, in order'
    if ($bad.Count) { $bad | Select-Object -Last 12 | ForEach-Object { Write-Host "      $_" } }

    # Accelerators come from the live keybind set, menu-wide.
    $withAccel = @(Rows $tree | Where-Object { $_.Accel -ne '' })
    Assert ($withAccel.Count -ge 10) "B: bound rows carry their chord ($($withAccel.Count) labeled rows)"
    $newTab = Row $tree "&File/New &Tab"
    Assert ($null -ne $newTab -and $newTab.Accel -eq 'Ctrl+T') "B: File>New Tab is labeled Ctrl+T (got '$($newTab.Accel)')"
    # A command with no binding behind it must show a bare label, never the
    # placeholder action's chord.
    $remote = Row $tree "&File/New &Remote Window"
    Assert ($null -ne $remote -and $remote.Accel -eq '') "B: New Remote Window (no binding) shows no chord (got '$($remote.Accel)')"
    $about = Row $tree "&Help/&About Ghoztty"
    Assert ($null -ne $about -and $about.Accel -eq '') "B: About (no binding) shows no chord (got '$($about.Accel)')"
}

# --- D: state gating, single pane / two tabs -------------------------------
if ($null -ne $tree) {
    Assert ((Row-Flags $tree "&Edit/&Copy") -eq ':grayed') 'D: Copy is grayed with no selection'
    Assert ((Row-Flags $tree "&Window/&Zoom Split") -eq ':grayed') 'D: Zoom Split is grayed in a single-pane tab'
    Assert ((Row-Flags $tree "&Window/&Select Split/Select Split &Left") -eq ':grayed') 'D: Select Split rows are grayed in a single-pane tab'
    Assert ((Row-Flags $tree "&Window/&Resize Split/Move Divider &Up") -eq ':grayed') 'D: Move Divider rows are grayed in a single-pane tab'
    # Run 1 opened a second tab in section A, so the tab rows are live.
    Assert ((Row-Flags $tree "&File/Close Ta&b") -eq '') 'D: Close Tab is enabled with two tabs'
    Assert ((Row-Flags $tree "&Window/Previous &Tab") -eq '') 'D: tab cycling is enabled with two tabs'
    # E(off): the Exit row only advertises session keeping when it is on.
    Assert ($null -ne (Row $tree "&File/E&xit")) 'E: Exit reads plain "E&xit" with session-persistence off'
}
Close-Menu $g

# --- C: Edit>Select All dispatches, and Copy then enables ------------------
[MenuDrv]::ClickStrip($g.Top, -10, 8)
$m = [MenuDrv]::WaitMenu($g.Pid, 3000)
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the Select All dispatch'
[MenuDrv]::PostKey($g.Top, 0x45) # 'E' -> Edit submenu
Start-Sleep -Milliseconds 300
[MenuDrv]::PostKey($g.Top, 0x41) # 'A' -> Select All
Assert ([MenuDrv]::WaitMenuGone($g.Pid, 2500)) 'C: choosing Select All closes the menu'
Start-Sleep -Milliseconds 600
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&Edit/&Copy") -eq '') 'C/D: Copy is enabled after menu>Edit>Select All (dispatch AND live state)'
Close-Menu $g

# --- C: File>New Tab dispatches -------------------------------------------
$before = Tab-Count
[MenuDrv]::ClickStrip($g.Top, -10, 8)
$m = [MenuDrv]::WaitMenu($g.Pid, 3000)
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the New Tab dispatch'
[MenuDrv]::PostKey($g.Top, 0x46) # 'F' -> File submenu
Start-Sleep -Milliseconds 300
[MenuDrv]::PostKey($g.Top, 0x54) # 'T' -> New Tab
Assert ([MenuDrv]::WaitMenuGone($g.Pid, 2500)) 'C: choosing New Tab closes the menu'
$grew = $false
for ($t = 0; $t -lt 20; $t++) { Start-Sleep -Milliseconds 250; if ((Tab-Count) -gt $before) { $grew = $true; break } }
Assert $grew "C: File>New Tab opened a tab ($before -> $(Tab-Count))"

# --- C: View>Terminal Read-only round-trips through the check state --------
[MenuDrv]::ClickStrip($g.Top, -10, 8)
$m = [MenuDrv]::WaitMenu($g.Pid, 3000)
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the read-only toggle'
[MenuDrv]::PostKey($g.Top, 0x56) # 'V' -> View
Start-Sleep -Milliseconds 300
[MenuDrv]::PostKey($g.Top, 0x4F) # 'o' -> Terminal Read-only
[MenuDrv]::WaitMenuGone($g.Pid, 2500) | Out-Null
Start-Sleep -Milliseconds 500
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&View/Terminal Read-&only") -eq ':checked') 'C: View>Terminal Read-only performs and comes back CHECKED'
Close-Menu $g
# ...and off again, so the rest of the run types normally.
[MenuDrv]::ClickStrip($g.Top, -10, 8)
[MenuDrv]::WaitMenu($g.Pid, 3000) | Out-Null
[MenuDrv]::PostKey($g.Top, 0x56)
Start-Sleep -Milliseconds 300
[MenuDrv]::PostKey($g.Top, 0x4F)
[MenuDrv]::WaitMenuGone($g.Pid, 2500) | Out-Null
Start-Sleep -Milliseconds 400
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&View/Terminal Read-&only") -eq '') 'C: a second choice clears the check'
Close-Menu $g

# --- C/D: Window>Zoom Split, with a real split ----------------------------
$paneName = Pane-Name
& $exe +split --target=$paneName --direction=right 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panesBefore = [MenuDrv]::VisiblePanes($g.Top)
Assert ($panesBefore -ge 2) "C: the tab has two panes to zoom (visible=$panesBefore)"
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&Window/&Zoom Split") -eq '') 'D: Zoom Split is ENABLED once the tab has two panes'
Close-Menu $g
[MenuDrv]::ClickStrip($g.Top, -10, 8)
[MenuDrv]::WaitMenu($g.Pid, 3000) | Out-Null
[MenuDrv]::PostKey($g.Top, 0x57) # 'W' -> Window
Start-Sleep -Milliseconds 300
[MenuDrv]::PostKey($g.Top, 0x5A) # 'Z' -> Zoom Split
Assert ([MenuDrv]::WaitMenuGone($g.Pid, 2500)) 'C: choosing Zoom Split closes the menu'
$zoomed = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 250
    if ([MenuDrv]::VisiblePanes($g.Top) -lt $panesBefore) { $zoomed = $true; break }
}
Assert $zoomed "C: Window>Zoom Split hid the other pane ($panesBefore -> $([MenuDrv]::VisiblePanes($g.Top)) visible)"

# --- G: keyboard activation ------------------------------------------------
$pane = [MenuDrv]::FindPane($g.Top)
[MenuDrv]::PostSysKeyDown($pane, 0x79) # VK_F10
[MenuDrv]::PostSysKeyUp($pane, 0x79)
$m = [MenuDrv]::WaitMenu($g.Pid, 3000)
Assert ($m -ne [IntPtr]::Zero) 'G: F10 opens the menu'
Close-Menu $g

[MenuDrv]::PostSysKeyDown($pane, 0x12) # VK_MENU down
Start-Sleep -Milliseconds 150
[MenuDrv]::PostSysKeyUp($pane, 0x12)   # ...and up, with nothing between
$m = [MenuDrv]::WaitMenu($g.Pid, 3000)
Assert ($m -ne [IntPtr]::Zero) 'G: a lone Alt press opens the menu'
Close-Menu $g

[MenuDrv]::PostSysKeyDown($pane, 0x12)
Start-Sleep -Milliseconds 100
# A non-printing key: a letter here would be typed at the shell prompt and
# would then swallow the next command the script sends (which is exactly how
# the alternate-screen check below silently skipped on its first run).
[MenuDrv]::PostKey($pane, 0x25)        # VK_LEFT while Alt is down
Start-Sleep -Milliseconds 100
[MenuDrv]::PostSysKeyUp($pane, 0x12)
$m = [MenuDrv]::WaitMenu($g.Pid, 1500)
Assert ($m -eq [IntPtr]::Zero) 'G: alt+<key> does NOT open the menu (alt stays a modifier)'
if ($m -ne [IntPtr]::Zero) { Close-Menu $g }

# F10 belongs to a full-screen TUI. Those run on the ALTERNATE screen, so
# that is the discriminator: switch the pane to it and F10 must pass through.
# It has to be the FOCUSED pane - that is the one F10 is delivered to.
$paneName = Focused-Pane-Name
# Clear whatever the earlier key probes left on the prompt line before
# typing a command that has to actually run.
& $exe +send-keys --target=$paneName C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
# The child switches BOTH ways itself and prints a marker on its way out.
# Do not use ^C plus "+read works again" as the return oracle: a killed child
# does not necessarily leave the alternate screen, and +read's failure means
# "nothing to read", which is not the same question.
$marker = 'MENUBAR_PRIMARY_OK_41'
$inner = '[Console]::Write((-join @([char]27,"[?1049h"))); Start-Sleep 12; ' +
         '[Console]::Write((-join @([char]27,"[?1049l"))); Write-Host "' + $marker + '"'
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
& $exe +send-keys --target=$paneName "powershell -NoProfile -EncodedCommand $b64" Enter 2>&1 | Out-Null
# On the alternate screen there is no scrollback for +read to return, which
# is the cheapest proof the switch landed.
$onAlt = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 400
    if ((Read-Exit $paneName) -ne 0) { $onAlt = $true; break }
}
if ($onAlt) {
    $pane = [MenuDrv]::FindPane($g.Top)
    [MenuDrv]::PostSysKeyDown($pane, 0x79)
    [MenuDrv]::PostSysKeyUp($pane, 0x79)
    $m = [MenuDrv]::WaitMenu($g.Pid, 2000)
    Assert ($m -eq [IntPtr]::Zero) 'G: F10 is passed through on the alternate screen (no menu)'
    if ($m -ne [IntPtr]::Zero) { Close-Menu $g }

    # The marker is printed AFTER the child switches back, so seeing it in
    # the pane is positive proof the primary screen is live again.
    $backOnPrimary = $false
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 500
        if ((Read-Text $paneName 20) -match $marker) { $backOnPrimary = $true; break }
    }
    Assert $backOnPrimary 'G: the pane is back on the primary screen (its own marker is visible)'
    if ($backOnPrimary) {
        [MenuDrv]::PostSysKeyDown($pane, 0x79)
        [MenuDrv]::PostSysKeyUp($pane, 0x79)
        $m = [MenuDrv]::WaitMenu($g.Pid, 3000)
        Assert ($m -ne [IntPtr]::Zero) 'G: F10 opens the menu again on the primary screen (it is the screen, not a dead key)'
        Close-Menu $g
    }
} else {
    Write-Host 'SKIP G(alt screen): the pane never switched to the alternate screen'
}

# --- A(reflow): the button survives the strip filling up ------------------
# Tabs stop shrinking at their minimum width (60pt), so past a point they
# overrun the strip and anything drawn AFTER the last tab lands off-screen -
# which used to cost only the "+" and would now cost the whole menu. The
# count is computed from this window, not guessed: at 96 DPI and a 1810px
# client, 21 tabs still fit and would have proved nothing.
# Last in the run, because it leaves the window full of tabs.
$dpi = [MenuDrv]::GetDpiForWindow($g.Top)
$scale = $dpi / 96.0
$cw = ([MenuDrv]::Client($g.Top)).right
$btnW = [Math]::Round(36.0 * $scale)
$minTabW = [Math]::Round(60.0 * $scale)
$needTabs = [int][Math]::Floor(($cw - 2 * $btnW) / $minTabW) + 4
Write-Host "      A(reflow): client=$cw dpi=$dpi -> opening $needTabs tabs (min tab ${minTabW}px)"
$have = Tab-Count
while ((Tab-Count) -lt $needTabs -and $have -lt $needTabs + 8) {
    [MenuDrv]::ClickStrip($g.Top, -($btnW + 10), 8)
    $have++
    Start-Sleep -Milliseconds 250
}
$manyTabs = Tab-Count
Assert ($manyTabs -ge $needTabs) "A: opened $manyTabs tabs, past the $needTabs that overrun the strip"
$tree = Open-Menu $g 4000
Assert ($null -ne $tree) 'A: the menu button is still reachable with the strip overrun by tabs'
if ($null -ne $tree) { Close-Menu $g }

Assert (-not $g.Proc.HasExited) 'run 1: no crash'
Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Run 2: section E - Exit advertises session keeping when persistence is on.
# ===========================================================================
$g = Start-Gui 'persistence-on' @('--session-persistence=true')
$tree = Open-Menu $g
Assert ($null -ne $tree) 'E: menu opens with session-persistence on'
if ($null -ne $tree) {
    $plain = Row $tree "&File/E&xit"
    $keep = Row $tree "&File/E&xit (keep sessions)"
    Assert ($null -ne $keep) 'E: Exit reads "E&xit (keep sessions)" with session-persistence on'
    Assert ($null -eq $plain) 'E: ...and the plain Exit row is gone (one row, relabeled)'
}
Close-Menu $g
Assert (-not $g.Proc.HasExited) 'run 2: no crash'
# Close via the window so the agent ENDS this run's session (T89e close intent)
# instead of leaving it to re-attach into a later test.
[MenuDrv]::CancelMenu($g.Top)
Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Run 3: section F - a rebind relabels its row.
# ===========================================================================
$g = Start-Gui 'rebind' @('--session-persistence=false', '--keybind=ctrl+alt+k=prompt_surface_banner')
$tree = Open-Menu $g
Assert ($null -ne $tree) 'F: menu opens under the rebind config'
if ($null -ne $tree) {
    $banner = Row $tree "&View/Set Pane &Banner$EL"
    Assert ($null -ne $banner -and $banner.Accel -eq 'Ctrl+Alt+K') "F: rebinding relabels the row (got '$($banner.Accel)')"
}
Close-Menu $g
Assert (-not $g.Proc.HasExited) 'run 3: no crash'

# --- C: File>Close Window, the row that destroys the window that owns the
# menu. `Window.close()` calls DestroyWindow synchronously and `onDestroy`
# frees the Window allocation, so anything the host touches after dispatch is
# a use-after-free. This is the assertion for that: the app must go away
# cleanly, not abort.
[MenuDrv]::ClickStrip($g.Top, -10, 8)
$m = [MenuDrv]::WaitMenu($g.Pid, 3000)
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the Close Window dispatch'
[MenuDrv]::PostKey($g.Top, 0x46) # 'F' -> File
Start-Sleep -Milliseconds 300
[MenuDrv]::PostKey($g.Top, 0x57) # 'W' -> Close &Window
# A pane with a live shell counts as a running process, so the close path
# asks first (Window.confirmCloseIfNeeded). Take the affirmative - and note
# that this makes the assertion stronger, since the dispatch now runs a modal
# dialog before it destroys the window that owns the menu.
$confirm = [MenuDrv]::WaitClass($g.Pid, 'GhozttyConfirmDialog', 3000)
if ($confirm -ne [IntPtr]::Zero) {
    Write-Host '      C: close confirmation shown, accepting'
    # Enter alone CANCELS by design (MB_DEFBUTTON2 parity - an accidental
    # Enter must never approve a close), and posted keys do not move the
    # dialog's focus cross-process. Post the OK command the dialog's own
    # WM_COMMAND handler reads (IDOK), which is what a click on Close does.
    [MenuDrv]::PostMessageW($confirm, 0x0111, [IntPtr]1, [IntPtr]::Zero) | Out-Null
}
$windowGone = $false
for ($t = 0; $t -lt 40; $t++) {
    Start-Sleep -Milliseconds 250
    if ([MenuDrv]::FindTop($g.Pid) -eq [IntPtr]::Zero) { $windowGone = $true; break }
}
Assert $windowGone 'C: File>Close Window destroyed the window that owns the menu'
Start-Sleep -Milliseconds 800
# The app does not exit with its last window (`quit-after-last-window-closed`
# is off), so "still answering IPC" is the liveness check - and it is the one
# that matters here, because the Window allocation was freed underneath the
# menu host.
if ($g.Proc.HasExited) {
    Assert ($g.Proc.ExitCode -eq 0) "C: ...and the app exited cleanly (code $($g.Proc.ExitCode))"
} else {
    $healthy = $false
    try { $healthy = (List-Json).success -eq $true } catch { $healthy = $false }
    Assert $healthy 'C: ...and the app is still healthy afterwards (answers +list)'
}

Stop-Process -Id $g.Proc.Id -Force -ErrorAction SilentlyContinue
Kill-RepoInstances

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
