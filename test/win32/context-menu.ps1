# T102 acceptance: Mac-parity right-click context menu on win32.
#
# Sections:
#   F: WM_CONTEXTMENU (VK_APPS / Shift+F10 path) opens the menu on a virgin
#      pane; full Mac-parity item list with Copy grayed (no selection yet).
#   A: posted right-click opens the menu; right-click ON text pre-selects
#      the word (Mac parity) so Copy enables.
#   B: keyboard selection dispatches — "P" picks Paste and the clipboard
#      sentinel lands in the pane (TrackPopupMenuEx TPM_RETURNCMD wiring).
#   C: "T" toggles Terminal Read-only; reopened menu shows MF_CHECKED;
#      toggling again clears it.
#   D: with SGR mouse reporting active in the pane (ConPTY passthrough of
#      ?1002h/?1006h), a plain right-click is reported to the app (NO menu —
#      the TUI wins, Mac parity) but shift+right-click bypasses the report
#      and opens the menu (works because handleMouseButton reads shift from
#      the message wparam).
#   E: `right-click-action = paste` opt-out — right-click pastes, no menu
#      (the Windows-Terminal-style behavior, as a config choice).
#   G: T129 discoverability — the menu carries "Set Pane Banner..." labeled
#      with its accelerator (Ctrl+Shift+B, NOT the Mac cmd+r), the label
#      tracks the live keybind set (a rebind relabels it), and choosing the
#      row opens the banner editor.
#
# All input is PostMessage-driven (client-coordinate mouse messages with
# crafted MK_* wparam bits), so the script needs neither foreground nor
# SendInput and is immune to the box's GameInputSvc input wedge (T95/T103).
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) {
    $exe = $ExePath
    $env:GHOZTTY_PIPE_SUFFIX = '-ctxmenutest'
}

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Clipboard without the trailing CRLF that PS5.1 Set-Clipboard appends (a
# newline would trip the core's unsafe-paste confirmation instead of
# pasting).
Add-Type -AssemblyName System.Windows.Forms
function Set-ClipText([string]$s) { [System.Windows.Forms.Clipboard]::SetText($s) }

Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class CtxMenuDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint idItem, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll", EntryPoint = "GetWindowRect")] public static extern bool GetWindowRectPub(IntPtr h, out RECT r);
    [DllImport("user32.dll", EntryPoint = "SetCursorPos")] public static extern bool SetCursor(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr inst, IntPtr name);
    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public int ptX, ptY; }
    // With mouse reporting on, ghostty shows the plain arrow over the pane
    // (instead of the I-beam). Match IDC_ARROW exactly so the transient
    // app-starting/wait cursors during child spawn can't false-positive.
    public static bool CursorIsArrow() {
        var ci = new CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci)) return false;
        return ci.hCursor == LoadCursorW(IntPtr.Zero, (IntPtr)32512); // IDC_ARROW
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() { SetProcessDpiAwarenessContext((IntPtr)(-4)); }

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

    public static IntPtr FindPane(IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // The visible popup-menu window (class #32768) owned by pid, or zero.
    public static IntPtr MenuWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "#32768" && IsWindowVisible(h)) {
                uint p; GetWindowThreadProcessId(h, out p);
                if (p == pid) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Visible top-level window of a class owned by pid (T129 uses it to see
    // the banner editor the menu row opens), or zero.
    public static IntPtr WindowOfClass(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
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

    public static void CloseWindow(IntPtr h) {
        PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE
    }

    public static IntPtr WaitMenu(uint pid, int ms) {
        for (int t = 0; t < ms; t += 50) {
            IntPtr h = MenuWindow(pid);
            if (h != IntPtr.Zero) return h;
            Thread.Sleep(50);
        }
        return IntPtr.Zero;
    }

    public static bool WaitMenuGone(uint pid, int ms) {
        for (int t = 0; t < ms; t += 50) {
            if (MenuWindow(pid) == IntPtr.Zero) return true;
            Thread.Sleep(50);
        }
        return false;
    }

    // Post a right-button press at client (x, y); x < 0 means pane center.
    public static void PostRightDown(IntPtr pane, uint mkExtra, int x, int y) {
        RECT rc; GetClientRect(pane, out rc);
        if (x < 0) { x = (rc.right - rc.left) / 2; y = (rc.bottom - rc.top) / 2; }
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        PostMessageW(pane, 0x0204, (IntPtr)(0x0002 | mkExtra), lp); // WM_RBUTTONDOWN
    }

    public static void PostRightUp(IntPtr pane, uint mkExtra) {
        RECT rc; GetClientRect(pane, out rc);
        int x = (rc.right - rc.left) / 2, y = (rc.bottom - rc.top) / 2;
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        PostMessageW(pane, 0x0205, (IntPtr)mkExtra, lp); // WM_RBUTTONUP
    }

    // Post WM_CONTEXTMENU as the keyboard path does (lparam = -1).
    public static void PostKeyboardMenu(IntPtr pane) {
        PostMessageW(pane, 0x007B, pane, (IntPtr)(-1));
    }

    // Post a key while the pane's thread is in the menu modal loop; the
    // loop retrieves queue messages regardless of target hwnd.
    public static void PostKey(IntPtr pane, ushort vk) {
        PostMessageW(pane, 0x0100, (IntPtr)vk, IntPtr.Zero); // WM_KEYDOWN
        PostMessageW(pane, 0x0101, (IntPtr)vk, IntPtr.Zero); // WM_KEYUP
    }

    // Cancel any active menu modal loop on the pane's thread.
    public static void CancelMenu(IntPtr pane) {
        IntPtr result;
        SendMessageTimeoutW(pane, 0x001F, IntPtr.Zero, IntPtr.Zero, 2, 2000, out result); // WM_CANCELMODE
    }

    // Item strings by position; separators come back as "---"; grayed and
    // checked states append ":grayed"/":checked".
    public static string[] MenuItems(IntPtr menuWnd) {
        IntPtr result;
        SendMessageTimeoutW(menuWnd, 0x01E1, IntPtr.Zero, IntPtr.Zero, 2, 2000, out result); // MN_GETHMENU
        IntPtr menu = result;
        if (menu == IntPtr.Zero) return new string[0];
        int n = GetMenuItemCount(menu);
        var items = new List<string>();
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            if ((state & 0x800) != 0) { items.Add("---"); continue; } // MF_SEPARATOR
            var sb = new StringBuilder(128);
            GetMenuStringW(menu, i, sb, 128, 0x400);
            string flags = "";
            if ((state & 0x3) != 0) flags += ":grayed";   // MF_GRAYED|MF_DISABLED
            if ((state & 0x8) != 0) flags += ":checked";  // MF_CHECKED
            items.Add(sb.ToString() + flags);
        }
        return items.ToArray();
    }
}
'@

[CtxMenuDrv]::BeDpiAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

function Start-Gui([string]$label, [string[]]$extraArgs) {
    Kill-RepoInstances
    $sp = @{ FilePath = $exe; PassThru = $true }
    # session-persistence=false (CLI bools take true/false, NOT on/off):
    # agent-backed panes would re-attach stale sessions across the script's
    # force-kills and leave the pane's shell dead/blank (paste has no live
    # pty to echo into; launch restore replaces the -e window). Also drop
    # any stale debug layout manifest so no prior test's layout restores.
    Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
    $sp.ArgumentList = @('--config-default-files=false', '--session-persistence=false') + $extraArgs
    $proc = Start-Process @sp
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [CtxMenuDrv]::FindTop([uint32]$proc.Id)
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    $pane = [CtxMenuDrv]::FindPane($top)
    if ($pane -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): pane not found"; exit 1 }
    $listJson = & $exe +list --json | Out-String
    $paneName = $null
    if ($listJson -match '"name"\s*:\s*"([^"]+)"') { $paneName = $Matches[1] }
    [pscustomobject]@{ Proc = $proc; Top = $top; Pane = $pane; PaneName = $paneName }
}

function Read-Pane([string]$paneName, [int]$lines = 30) {
    & $exe +read --name=$paneName --lines=$lines 2>$null | Out-String
}

function Dump-Items([string[]]$items, [string]$label) {
    Write-Host "      $label items: $($items -join ' | ')"
}

# MenuItems returns "Base[<tab>Accel][:grayed][:checked]" (T129 added the
# accelerator half). Split it back apart so the item-list compare stays about
# labels/flags and the accelerator gets its own assertions.
function Split-Item([string]$s) {
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
    [pscustomobject]@{ Base = $s; Accel = $accel; Flags = $flags; Label = ($s + $flags) }
}

function Split-Items([string[]]$items) { $items | ForEach-Object { Split-Item $_ } }

# Accelerator for a base label, or '' when the row has none / is missing.
function Accel-For($parsed, [string]$base) {
    $row = @($parsed | Where-Object { $_.Base -eq $base })
    if ($row.Count -eq 0) { return $null }
    $row[0].Accel
}

# The Mac surface menu (menu(for:)) + win32's Select All; the exact rows the
# pure context_menu.zig model must produce on a pane with no selection.
#
# Accelerator suffixes are stripped before the compare (see Split-Item);
# section G asserts those separately.
$expected = @(
    'Copy:grayed', 'Paste', 'Select All', '---',
    'Split Right', 'Split Left', 'Split Down', 'Split Up', '---',
    'Reset Terminal', 'Terminal Read-only', '---',
    'Background Color...', '---',
    'Change Tab Title...', 'Change Pane Title...', 'Set Pane Banner...'
)

# ---------------------------------------------------------------------------
# Run 1: sections F, A, B, C (default config).
# ---------------------------------------------------------------------------
$g = Start-Gui 'default' @()
$proc = $g.Proc; $pane = $g.Pane; $paneName = $g.PaneName
$gpid = [uint32]$proc.Id

# F: keyboard path on a virgin pane — no selection exists, so this is the
# deterministic Copy:grayed check plus the full item-list compare.
[CtxMenuDrv]::PostKeyboardMenu($pane)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
Assert ($menuWnd -ne [IntPtr]::Zero) 'F: WM_CONTEXTMENU (VK_APPS path) opens the menu'
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = [CtxMenuDrv]::MenuItems($menuWnd)
    $parsed = @(Split-Items $items)
    Assert ($items.Count -eq $expected.Count) "F: menu has $($expected.Count) rows (got $($items.Count))"
    $mismatch = @()
    for ($i = 0; $i -lt [Math]::Min($parsed.Count, $expected.Count); $i++) {
        if ($parsed[$i].Label -ne $expected[$i]) { $mismatch += "row $i got '$($parsed[$i].Label)' want '$($expected[$i])'" }
    }
    Assert ($mismatch.Count -eq 0) 'F: item order/labels/flags match the Mac surface menu'
    if ($mismatch.Count) { $mismatch | ForEach-Object { Write-Host "      $_" }; Dump-Items $items 'F' }

    # G: the banner row and its self-teaching accelerator (T129).
    $bannerAccel = Accel-For $parsed 'Set Pane Banner...'
    Assert ($null -ne $bannerAccel) 'G: menu carries a "Set Pane Banner..." row'
    Assert ($bannerAccel -eq 'Ctrl+Shift+B') "G: banner row is labeled Ctrl+Shift+B (got '$bannerAccel')"
    # The whole point of the row: the Windows chord is NOT the Mac one.
    Assert ($bannerAccel -notmatch 'Win\+R|Ctrl\+R$') 'G: banner accelerator is not the Mac cmd+r chord'
    # Accelerators are a menu-wide affordance, not a one-off for the banner.
    $withAccel = @($parsed | Where-Object { $_.Accel -ne '' })
    Assert ($withAccel.Count -ge 3) "G: bound items show their chords (got $($withAccel.Count) labeled rows)"
    Write-Host "      G accels: $(($withAccel | ForEach-Object { "$($_.Base)=$($_.Accel)" }) -join ' | ')"
    # An action with no default bind must show a bare label, not an empty tab.
    $unbound = @($parsed | Where-Object { $_.Base -eq 'Background Color...' })
    Assert ($unbound.Count -eq 1 -and $unbound[0].Accel -eq '') 'G: apprt-local row (Background Color...) shows no chord'
}
[CtxMenuDrv]::CancelMenu($pane)
Assert ([CtxMenuDrv]::WaitMenuGone($gpid, 2000)) 'F: WM_CANCELMODE dismisses the menu'

# A: right-click ON text (the cmd banner on row 0) pre-selects the clicked
# word (Mac parity: right-click-down selects for the menu), enabling Copy.
# The core resolves the word under the REAL cursor (rt getCursorPos), so
# park the physical cursor on the click point first (SetCursorPos is not
# affected by the SendInput wedge).
$wr = New-Object CtxMenuDrv+RECT
[CtxMenuDrv]::GetWindowRectPub($pane, [ref]$wr) | Out-Null
[CtxMenuDrv]::SetCursor($wr.left + 80, $wr.top + 16) | Out-Null
Start-Sleep -Milliseconds 300
[CtxMenuDrv]::PostRightDown($pane, 0, 80, 16)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
Assert ($menuWnd -ne [IntPtr]::Zero) 'A: right-click opens the context menu'
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = [CtxMenuDrv]::MenuItems($menuWnd)
    $parsed = @(Split-Items $items)
    $copyOk = ($parsed.Count -gt 0 -and $parsed[0].Label -eq 'Copy')
    Assert $copyOk 'A: right-click on text selects the word (Copy enabled)'
    if (-not $copyOk) { Dump-Items $items 'A' }
}
[CtxMenuDrv]::CancelMenu($pane)
[CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null

# B: keyboard selection dispatches — "P" = Paste; sentinel reaches the pty.
$sentinel = 'CTXMENU_PASTE_OK_77'
Set-ClipText $sentinel
[CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
Assert ($menuWnd -ne [IntPtr]::Zero) 'B: menu reopens for the paste test'
[CtxMenuDrv]::PostKey($pane, 0x50) # 'P' -> unique match "Paste", executes
Assert ([CtxMenuDrv]::WaitMenuGone($gpid, 2000)) 'B: typing P closes the menu (item executed)'
$pasted = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 250
    if ((Read-Pane $paneName) -match $sentinel) { $pasted = $true; break }
}
Assert $pasted 'B: menu Paste typed the clipboard sentinel into the pane'
[CtxMenuDrv]::CancelMenu($pane)
[CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null

# C: "T" toggles Terminal Read-only; reopened menu shows the check.
[CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
Assert ($menuWnd -ne [IntPtr]::Zero) 'C: menu reopens for the readonly test'
[CtxMenuDrv]::PostKey($pane, 0x54) # 'T' -> unique match "Terminal Read-only"
[CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null
Start-Sleep -Milliseconds 300
[CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
$checked = $false
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = [CtxMenuDrv]::MenuItems($menuWnd)
    $checked = ($items -contains 'Terminal Read-only:checked')
}
Assert $checked 'C: Terminal Read-only shows checked after toggle'
[CtxMenuDrv]::PostKey($pane, 0x54) # toggle back off
[CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null
Start-Sleep -Milliseconds 300
[CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
$unchecked = $false
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = [CtxMenuDrv]::MenuItems($menuWnd)
    $unchecked = ($items -contains 'Terminal Read-only')
}
Assert $unchecked 'C: Terminal Read-only unchecked after second toggle'
[CtxMenuDrv]::CancelMenu($pane)
[CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null

# G: choosing the banner row opens the editor. The row is last, so Up from a
# fresh menu lands on it (no letter key: Select All / the four Splits / Set
# Pane Banner all start with S).
[CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
Assert ($menuWnd -ne [IntPtr]::Zero) 'G: menu reopens for the banner-row test'
[CtxMenuDrv]::PostKey($pane, 0x26) # VK_UP -> last item
[CtxMenuDrv]::PostKey($pane, 0x0D) # VK_RETURN -> execute
Assert ([CtxMenuDrv]::WaitMenuGone($gpid, 2000)) 'G: choosing the banner row closes the menu'
$dlg = [CtxMenuDrv]::WaitClass($gpid, 'GhozttyBannerDialog', 3000)
Assert ($dlg -ne [IntPtr]::Zero) 'G: banner row opens the banner editor (GhozttyBannerDialog)'
if ($dlg -ne [IntPtr]::Zero) {
    [CtxMenuDrv]::CloseWindow($dlg)
    $gone = $false
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 50
        if ([CtxMenuDrv]::WindowOfClass($gpid, 'GhozttyBannerDialog') -eq [IntPtr]::Zero) { $gone = $true; break }
    }
    Assert $gone 'G: banner editor closes again'
}

Assert (-not $proc.HasExited) 'run 1: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2: section D — the pane's command enables mouse reporting the way real
# Windows TUIs do: SetConsoleMode(ENABLE_MOUSE_INPUT), which conhost
# translates into an outward DECSET on the ConPTY. (A raw ?1002h written by
# the child does NOT propagate out of ConPTY — verified 2026-07-20.)
# ---------------------------------------------------------------------------
$inner = @'
$sig='[DllImport("kernel32.dll")]public static extern IntPtr GetStdHandle(int n);[DllImport("kernel32.dll")]public static extern bool GetConsoleMode(IntPtr h,out uint m);[DllImport("kernel32.dll")]public static extern bool SetConsoleMode(IntPtr h,uint m);'
$k=Add-Type -MemberDefinition $sig -Name K -Namespace W -PassThru
$h=$k::GetStdHandle(-10)
$m=0
$k::GetConsoleMode($h,[ref]$m)|Out-Null
$k::SetConsoleMode($h, ($m -bor 0x10 -bor 0x80) -band (-bnot 0x40))|Out-Null
Start-Sleep 120
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
# PS5.1 Start-Process does NOT auto-quote ArgumentList elements containing
# spaces — embed the quotes so --command survives as one argv entry.
$g = Start-Gui 'mouse-reporting' @("`"--command=powershell -NoProfile -EncodedCommand $b64`"")
$proc = $g.Proc; $pane = $g.Pane
$gpid = [uint32]$proc.Id

# The mode lands once the child's Add-Type finishes (a few seconds). Poll
# with plain right-clicks until one is consumed (no menu) — that IS the
# behavior under test; retries just absorb child-startup latency.
$suppressed = $false
for ($try = 0; $try -lt 6; $try++) {
    [CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
    $menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 1500)
    if ($menuWnd -eq [IntPtr]::Zero) { $suppressed = $true; break }
    [CtxMenuDrv]::CancelMenu($pane)
    [CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null
    Start-Sleep -Seconds 2
}
Assert $suppressed 'D: plain right-click is reported to the TUI (no menu)'
[CtxMenuDrv]::PostRightUp($pane, 0)
Start-Sleep -Milliseconds 300

[CtxMenuDrv]::PostRightDown($pane, 0x0004, -1, -1) # MK_SHIFT
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
Assert ($menuWnd -ne [IntPtr]::Zero) 'D: shift+right-click bypasses mouse reporting (menu opens)'
[CtxMenuDrv]::CancelMenu($pane)
[CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null

Assert (-not $proc.HasExited) 'run 2: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 3: section E — right-click-action=paste opt-out (WT-style).
# ---------------------------------------------------------------------------
$g = Start-Gui 'paste-optout' @('--right-click-action=paste')
$proc = $g.Proc; $pane = $g.Pane; $paneName = $g.PaneName
$gpid = [uint32]$proc.Id

$sentinel2 = 'CTXMENU_RCA_PASTE_88'
Set-ClipText $sentinel2
[CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 1500)
Assert ($menuWnd -eq [IntPtr]::Zero) 'E: right-click-action=paste shows no menu'
if ($menuWnd -ne [IntPtr]::Zero) { [CtxMenuDrv]::CancelMenu($pane); [CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null }
[CtxMenuDrv]::PostRightUp($pane, 0)
# The clipboard read can transiently fail (CLIPBRD_E_CANT_OPEN contention
# right after another process wrote it) and the shell may still be settling
# this early in the run — retry the click a few times.
$pasted2 = $false
for ($try = 0; $try -lt 3 -and -not $pasted2; $try++) {
    if ($try -gt 0) {
        [CtxMenuDrv]::PostRightDown($pane, 0, -1, -1)
        Start-Sleep -Milliseconds 300
        [CtxMenuDrv]::PostRightUp($pane, 0)
    }
    for ($t = 0; $t -lt 12; $t++) {
        Start-Sleep -Milliseconds 250
        if ((Read-Pane $paneName) -match $sentinel2) { $pasted2 = $true; break }
    }
}
Assert $pasted2 'E: right-click-action=paste pastes the clipboard'

Assert (-not $proc.HasExited) 'run 3: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 4: section G — the accelerator label is read from the live keybind set,
# not hardcoded. A user bind added after the defaults wins the reverse map, so
# the row must relabel itself (and the banner must still be reachable).
# ---------------------------------------------------------------------------
$g = Start-Gui 'rebind' @('--keybind=ctrl+alt+k=prompt_surface_banner')
$proc = $g.Proc; $pane = $g.Pane
$gpid = [uint32]$proc.Id

[CtxMenuDrv]::PostKeyboardMenu($pane)
$menuWnd = [CtxMenuDrv]::WaitMenu($gpid, 3000)
Assert ($menuWnd -ne [IntPtr]::Zero) 'G: menu opens under the rebind config'
if ($menuWnd -ne [IntPtr]::Zero) {
    $parsed = @(Split-Items ([CtxMenuDrv]::MenuItems($menuWnd)))
    $accel = Accel-For $parsed 'Set Pane Banner...'
    Assert ($accel -eq 'Ctrl+Alt+K') "G: rebinding relabels the row (got '$accel')"
}
[CtxMenuDrv]::CancelMenu($pane)
[CtxMenuDrv]::WaitMenuGone($gpid, 2000) | Out-Null

Assert (-not $proc.HasExited) 'run 4: no crash'
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Kill-RepoInstances

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
