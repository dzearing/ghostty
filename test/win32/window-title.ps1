# T92 acceptance: three-level title model (window pin -> tab title -> pane
# title), Mac parity.
#
#   S1  OSC baseline: a shell `title X` drives pane + tab + titlebar.
#   S2  Window pin via IPC: +rename pins the titlebar over shell titles;
#       +rename --title="" CLEARS the pin (Mac 9c7665354 parity).
#   S3  ctrl+shift+r (prompt_window_title) opens the "Change Window Title"
#       dialog; commit pins, reopen prefills, empty commit clears.
#   S4  Palette "Change Pane Title": sets a pane title that survives shell
#       OSC updates; empty commit restores the remembered terminal title.
#   S5  Palette "Change Tab Title": pins the tab label against pane-driven
#       updates; empty commit re-derives from the focused pane.
#   S6  Precedence stack: window pin > tab pin > pane title, peeled one
#       level at a time.
#
# Titles are asserted via `+list --json` (window.title = real titlebar
# text incl. the Debug marker; tabs[].title; leaf terminal.title = pane).
# Dialog commits use WM_SETTEXT + posted Enter (the kb-actions.ps1 T50
# pattern); dialog/palette OPENING uses real SendInput chords with the
# T86-hardened foreground grab (attach-to-fg-thread + Alt tap). Only
# touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\window-title.ps1
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-window-title-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class TtlDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
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

    public static IntPtr FindDialog() {
        return FindWindowExW(IntPtr.Zero, IntPtr.Zero, "GhozttyRenameDialog", null);
    }

    // The visible palette popup: a top-level owned window of the same pid
    // using the terminal class (WS_POPUP, so not a child of `top`).
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

    public static IntPtr ChildByClass(IntPtr parent, string cls) {
        IntPtr c = GetWindow(parent, 5); // GW_CHILD
        while (c != IntPtr.Zero) {
            var sb = new StringBuilder(64);
            GetClassNameW(c, sb, 64);
            if (string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase))
                return c;
            c = GetWindow(c, 2); // GW_HWNDNEXT
        }
        return IntPtr.Zero;
    }

    public static string WindowText(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, 512);
        return sb.ToString();
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, StringBuilder sb);
    // WM_GETTEXT is marshaled cross-process for standard controls.
    public static string ControlText(IntPtr h) {
        var sb = new StringBuilder(512);
        SendMessageW(h, 0x000D, (IntPtr)512, sb);
        return sb.ToString();
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Send mods+vk with focus on `surface`, T86-hardened foreground grab:
    // attach to the current foreground owner's thread + an Alt tap, retried
    // (a background process may not steal foreground otherwise).
    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
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
            Thread.Sleep(300);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // Type plain VKs (letters/space/Enter) into `edit` in one attachment
    // burst (the hero-mode.ps1 palette pattern).
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
}
'@

# --- helpers -----------------------------------------------------------------
function Get-State {
    $j = & $exe +list --json | ConvertFrom-Json
    $w = $j.data.windows[0]
    @{ Win = [string]$w.title; Tab = [string]$w.tabs[0].title; Pane = [string]$w.tabs[0].splits.terminal.title }
}
function Wait-Cond([scriptblock]$cond, [int]$ms = 8000) {
    $dl = [DateTime]::Now.AddMilliseconds($ms)
    do {
        if (& $cond) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::Now -lt $dl)
    return $false
}
# Titlebar text = base title + optional " [DEBUG]" marker.
function TitlebarIs([string]$base) {
    (Get-State).Win -match ('^' + [regex]::Escape($base) + '( \[DEBUG\])?$')
}
function Send-Title([string]$t) {
    & $exe +send-keys --target=$script:win "title $t" Enter | Out-Null
}
# Open the title dialog via the command palette: ctrl+shift+p, type the
# filter, Enter. Returns the dialog HWND or IntPtr.Zero.
function Open-DialogViaPalette([string]$filter) {
    $r = [TtlDrv]::Chord($top, $surface, [uint16[]]@(0x11, 0x10), 0x50)  # ctrl+shift+p
    if ($r -ne 'SENT') { Write-Host "  (palette chord: $r)"; return [IntPtr]::Zero }
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $popup -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 20
        $popup = [TtlDrv]::FindPalettePopup([uint32]$proc.Id, $top)
    }
    if ($popup -eq [IntPtr]::Zero) { Write-Host '  (palette popup not found)'; return [IntPtr]::Zero }
    $palEdit = [TtlDrv]::FindWindowExW($popup, [IntPtr]::Zero, 'EDIT', $null)
    if ($palEdit -eq [IntPtr]::Zero) { Write-Host '  (palette edit not found)'; return [IntPtr]::Zero }
    $vks = New-Object System.Collections.Generic.List[uint16]
    foreach ($c in $filter.ToUpperInvariant().ToCharArray()) { $vks.Add([uint16][char]$c) }
    $vks.Add(0x0D)
    $r = [TtlDrv]::TypeKeys($popup, $palEdit, $vks.ToArray())
    if ($r -ne 'SENT') { Write-Host "  (palette typing: $r)"; return [IntPtr]::Zero }
    $dlg = [IntPtr]::Zero
    for ($t = 0; $t -lt 100 -and $dlg -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 20
        $dlg = [TtlDrv]::FindDialog()
    }
    return $dlg
}
# Commit $text through an open title dialog (empty string clears).
function Commit-Dialog([IntPtr]$dlg, [string]$text) {
    $edit = [TtlDrv]::ChildByClass($dlg, 'Edit')
    if ($edit -eq [IntPtr]::Zero) { return $false }
    [TtlDrv]::SendMessageW($edit, 0x000C, [IntPtr]::Zero, $text) | Out-Null  # WM_SETTEXT
    [TtlDrv]::PostMessageW($edit, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001) | Out-Null  # Enter
    Wait-Cond { [TtlDrv]::FindDialog() -eq [IntPtr]::Zero } 3000
}

# --- Setup: fresh debug instance, one window/one pane ------------------------
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $exe } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$proc = Start-Process -FilePath $exe -PassThru -RedirectStandardError $errlog
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [TtlDrv]::FindTop([uint32]$proc.Id)
$surface = [TtlDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: windows not found'; exit 1 }
$listJson = & $exe +list --json | ConvertFrom-Json
$script:win = $listJson.data.windows[0].target
if (-not $script:win) { $script:win = $listJson.data.windows[0].tabs[0].splits.terminal.name }

# --- S1: OSC baseline (positive control for the title plumbing) --------------
Write-Host '== S1: shell OSC title drives pane + tab + titlebar'
Send-Title 'T92OSCA'
Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCA' }) 'S1 pane title tracks shell OSC'
$s = Get-State
Assert ($s.Tab -eq 'T92OSCA') 'S1 tab title follows the focused pane'
Assert (TitlebarIs 'T92OSCA') 'S1 titlebar falls back to the tab title'

# --- S2: window pin via +rename ----------------------------------------------
Write-Host '== S2: +rename pins the titlebar; --title="" clears'
& $exe +rename --target=$script:win --title=T92WINPIN | Out-Null
Assert (Wait-Cond { TitlebarIs 'T92WINPIN' }) 'S2 +rename pins the titlebar'
Send-Title 'T92OSCB'
Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCB' }) 'S2 pane title still tracks shell under the pin'
$s = Get-State
Assert ($s.Tab -eq 'T92OSCB') 'S2 tab title still tracks shell under the pin'
Assert (TitlebarIs 'T92WINPIN') 'S2 window pin beats the shell title'
& $exe +rename --target=$script:win --title= | Out-Null
Assert (Wait-Cond { TitlebarIs 'T92OSCB' }) 'S2 +rename --title="" clears the pin (falls back to tab)'

# --- S3: ctrl+shift+r -> Change Window Title dialog --------------------------
Write-Host '== S3: prompt_window_title dialog (ctrl+shift+r)'
$r = [TtlDrv]::Chord($top, $surface, [uint16[]]@(0x11, 0x10), 0x52)  # ctrl+shift+r
if ($r -ne 'SENT') {
    Write-Host "SKIP S3 (injection unavailable: $r)"
} else {
    $dlg = [IntPtr]::Zero
    for ($t = 0; $t -lt 100 -and $dlg -eq [IntPtr]::Zero; $t++) { Start-Sleep -Milliseconds 20; $dlg = [TtlDrv]::FindDialog() }
    Assert ($dlg -ne [IntPtr]::Zero) 'S3 dialog opens on ctrl+shift+r'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ([TtlDrv]::WindowText($dlg) -eq 'Change Window Title') 'S3 dialog caption is "Change Window Title"'
        Assert (Commit-Dialog $dlg 'T92DLG') 'S3 dialog closes on Enter'
        Assert (Wait-Cond { TitlebarIs 'T92DLG' }) 'S3 dialog commit pins the titlebar'
        # Reopen: prefilled with the pin; empty commit clears it.
        $r = [TtlDrv]::Chord($top, $surface, [uint16[]]@(0x11, 0x10), 0x52)
        $dlg = [IntPtr]::Zero
        for ($t = 0; $t -lt 100 -and $dlg -eq [IntPtr]::Zero; $t++) { Start-Sleep -Milliseconds 20; $dlg = [TtlDrv]::FindDialog() }
        Assert ($dlg -ne [IntPtr]::Zero) 'S3 dialog reopens'
        if ($dlg -ne [IntPtr]::Zero) {
            $edit = [TtlDrv]::ChildByClass($dlg, 'Edit')
            Assert ([TtlDrv]::ControlText($edit) -eq 'T92DLG') 'S3 reopen prefilled with the current pin'
            Assert (Commit-Dialog $dlg '') 'S3 empty commit closes the dialog'
            Assert (Wait-Cond { TitlebarIs 'T92OSCB' }) 'S3 empty commit clears the pin'
        }
    }
}

# --- S4: palette Change Pane Title -------------------------------------------
Write-Host '== S4: pane title prompt (palette)'
$dlg = Open-DialogViaPalette 'pane ti'
Assert ($dlg -ne [IntPtr]::Zero) 'S4 palette opens the pane-title dialog'
if ($dlg -ne [IntPtr]::Zero) {
    Assert ([TtlDrv]::WindowText($dlg) -eq 'Change Pane Title') 'S4 dialog caption is "Change Pane Title"'
    Assert (Commit-Dialog $dlg 'T92PANE') 'S4 dialog commit'
    Assert (Wait-Cond { (Get-State).Pane -eq 'T92PANE' }) 'S4 pane title set'
    $s = Get-State
    Assert ($s.Tab -eq 'T92PANE') 'S4 tab follows the pane title'
    Assert (TitlebarIs 'T92PANE') 'S4 titlebar follows too'
    # A shell title must NOT displace the user's pane title.
    Send-Title 'T92OSCC'
    Start-Sleep -Seconds 3
    $s = Get-State
    Assert ($s.Pane -eq 'T92PANE') 'S4 user pane title survives shell OSC'
    Assert ($s.Tab -eq 'T92PANE') 'S4 tab keeps the user pane title too'
    # Empty commit restores the REMEMBERED terminal title (OSCC, which
    # arrived while the user title was held).
    $dlg = Open-DialogViaPalette 'pane ti'
    Assert ($dlg -ne [IntPtr]::Zero) 'S4 pane-title dialog reopens'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert (Commit-Dialog $dlg '') 'S4 empty commit'
        Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCC' }) 'S4 clear restores the remembered terminal title'
    }
}

# --- S5: palette Change Tab Title --------------------------------------------
Write-Host '== S5: tab title pin (palette)'
$dlg = Open-DialogViaPalette 'tab ti'
Assert ($dlg -ne [IntPtr]::Zero) 'S5 palette opens the tab-title dialog'
if ($dlg -ne [IntPtr]::Zero) {
    Assert ([TtlDrv]::WindowText($dlg) -eq 'Change Tab Title') 'S5 dialog caption is "Change Tab Title"'
    Assert (Commit-Dialog $dlg 'T92TAB') 'S5 dialog commit'
    Assert (Wait-Cond { (Get-State).Tab -eq 'T92TAB' }) 'S5 tab title pinned'
    $s = Get-State
    Assert ($s.Pane -eq 'T92OSCC') 'S5 pane title untouched by the tab pin'
    Assert (TitlebarIs 'T92TAB') 'S5 titlebar shows the tab pin'
    # Pane-driven updates leave a pinned tab alone.
    Send-Title 'T92OSCD'
    Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCD' }) 'S5 pane title still tracks shell'
    $s = Get-State
    Assert ($s.Tab -eq 'T92TAB') 'S5 tab pin survives shell OSC'
    Assert (TitlebarIs 'T92TAB') 'S5 titlebar keeps the tab pin'
    # Empty commit re-derives the tab title from the focused pane.
    $dlg = Open-DialogViaPalette 'tab ti'
    Assert ($dlg -ne [IntPtr]::Zero) 'S5 tab-title dialog reopens'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert (Commit-Dialog $dlg '') 'S5 empty commit'
        Assert (Wait-Cond { (Get-State).Tab -eq 'T92OSCD' }) 'S5 clear re-derives from the focused pane'
    }
}

# --- S6: precedence stack window > tab > pane --------------------------------
Write-Host '== S6: precedence stack'
$dlg = Open-DialogViaPalette 'pane ti'
if ($dlg -ne [IntPtr]::Zero) { Commit-Dialog $dlg 'T92PPP' | Out-Null }
$dlg = Open-DialogViaPalette 'tab ti'
if ($dlg -ne [IntPtr]::Zero) { Commit-Dialog $dlg 'T92TTT' | Out-Null }
& $exe +rename --target=$script:win --title=T92WWW | Out-Null
Assert (Wait-Cond { TitlebarIs 'T92WWW' }) 'S6 all three set: titlebar = window pin'
$s = Get-State
Assert ($s.Tab -eq 'T92TTT') 'S6 tab = tab pin'
Assert ($s.Pane -eq 'T92PPP') 'S6 pane = pane title'
& $exe +rename --target=$script:win --title= | Out-Null
Assert (Wait-Cond { TitlebarIs 'T92TTT' }) 'S6 window pin cleared -> titlebar = tab pin'
$dlg = Open-DialogViaPalette 'tab ti'
if ($dlg -ne [IntPtr]::Zero) { Commit-Dialog $dlg '' | Out-Null }
Assert (Wait-Cond { TitlebarIs 'T92PPP' }) 'S6 tab pin cleared -> titlebar = pane title'
$s = Get-State
Assert ($s.Tab -eq 'T92PPP') 'S6 tab re-derived from the pane'
Assert (-not $proc.HasExited) 'S6 no crash through the whole sequence'

# --- Teardown ----------------------------------------------------------------
& $exe +close --target=$script:win | Out-Null
Start-Sleep -Seconds 1
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)"; exit 0 }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
