# T01 acceptance: verify the Windows ctrl-mirror keybinds end-to-end by
# driving REAL key chords into the debug build and asserting GUI state via
# +list/+read/clipboard.
#
# Coverage (the T01 checklist from windows-parity-details.md):
#   ctrl+t        new tab            (tab count via +list)
#   ctrl+1/2/9    goto_tab/last_tab  (tabs[].selected via +list)
#   ctrl+f4       close tab          (T02 binding, used to restore layout)
#   ctrl+d        split right        (leaf count via +list)
#   ctrl+shift+d  split down         (leaf count via +list)
#   ctrl+w        close pane         (leaf count; handles the confirm dialog)
#   ctrl+shift+p  command palette    (popup appears; Escape closes)
#   ctrl+c        SIGINT w/o selection (ping -t interrupted, shell prompt back)
#   ctrl+c        copy WITH selection  (double-click word select -> clipboard)
#   ctrl+v        paste              (clipboard token lands in the pane)
#   ctrl+n        new window         (window count via +list; closed via +close)
#
# Mechanics: SetForegroundWindow + AttachThreadInput + SetFocus then a short
# SendInput burst (same pattern as kb-actions.ps1). Foreground is verified
# immediately before each injection and the test SKIPs (not fails) if another
# window owns it, so keystrokes can never leak into other apps. Run on an
# idle desktop. A positive control (plain typed text must echo in +read)
# runs first so chord failures can't be blamed on the harness.
#
# Only touches ghoztty processes running from this repo's zig-out.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP "ghoztty-keybinds-t01-stderr.log"
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
public class T01Drv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L; public int T; public int R; public int B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MINPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll", EntryPoint = "SendInput")] public static extern uint SendMouseInput(uint n, MINPUT[] inputs, int size);
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

    // The command palette is a visible top-level WS_POPUP window of the
    // terminal class owned by the same pid (see hero-mode.ps1 / T57).
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

    public static IntPtr FindConfirmDialog() {
        return FindWindowExW(IntPtr.Zero, IntPtr.Zero, "GhozttyConfirmDialog", null);
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Send mods+vk to the window's focused control (surface). Passing
    // IntPtr.Zero for `focus` keeps whatever the window last focused
    // (correct after tab/split changes where the surface HWND is new).
    public static string Chord(IntPtr top, IntPtr focus, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        SetForegroundWindow(top);
        Thread.Sleep(150);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            if (focus != IntPtr.Zero) SetFocus(focus);
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

    // Positive control: type plain lowercase VKs into the focused surface.
    public static string TypePlain(IntPtr top, string text) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        SetForegroundWindow(top);
        Thread.Sleep(150);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
            foreach (char c in text) {
                ushort vk = (ushort)char.ToUpperInvariant(c);
                Key(vk, false); Thread.Sleep(8); Key(vk, true); Thread.Sleep(8);
            }
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // Press a key inside an owned popup (palette): focus its edit-ish child
    // path is unnecessary - focus the popup itself and send the VK.
    public static string KeyToPopup(IntPtr popup, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(popup, out pid);
        uint cur = GetCurrentThreadId();
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            IntPtr focused = GetFocus();
            if (focused == IntPtr.Zero) focused = popup;
            SetFocus(focused);
            Thread.Sleep(60);
            Key(vk, false); Thread.Sleep(20); Key(vk, true);
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    static void MouseAt(int sx, int sy, uint flags) {
        int vw = GetSystemMetrics(0), vh = GetSystemMetrics(1);
        var i = new MINPUT[1];
        i[0].type = 0;
        i[0].mi.dx = sx * 65535 / (vw - 1);
        i[0].mi.dy = sy * 65535 / (vh - 1);
        i[0].mi.dwFlags = 0x8001 | flags; // ABSOLUTE|MOVE + flags
        SendMouseInput(1, i, Marshal.SizeOf(typeof(MINPUT)));
    }

    // Double-click at a screen point (word-select in the terminal).
    public static string DoubleClick(IntPtr top, int sx, int sy) {
        SetForegroundWindow(top);
        Thread.Sleep(150);
        if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
        MouseAt(sx, sy, 0);
        Thread.Sleep(80);
        for (int c = 0; c < 2; c++) {
            MouseAt(sx, sy, 0x0002); Thread.Sleep(30);  // LEFTDOWN
            MouseAt(sx, sy, 0x0004); Thread.Sleep(60);  // LEFTUP
        }
        Thread.Sleep(150);
        return "SENT";
    }
}
'@

# --- JSON helpers -------------------------------------------------------------
function Get-ListJson { & $exe +list --json | ConvertFrom-Json }
# Split-tree node shape (list.zig writeNode): leaf nodes are
# {"type":"leaf","terminal":{...}}, split nodes are FLAT:
# {"type":"split","direction":...,"ratio":...,"left":{...},"right":{...}}.
function Count-Leaves($node) {
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-Leaves $node.left) + (Count-Leaves $node.right)
}
function Get-FocusedLeaf($node) {
    if ($node.type -eq 'leaf') {
        if ($node.terminal.focused) { return $node.terminal }
        return $null
    }
    $l = Get-FocusedLeaf $node.left
    if ($null -ne $l) { return $l }
    return (Get-FocusedLeaf $node.right)
}
function Get-AnyLeaf($node) {
    if ($node.type -eq 'leaf') { return $node.terminal }
    return (Get-AnyLeaf $node.left)
}
function Get-PaneName($node) {
    $leaf = Get-FocusedLeaf $node
    if ($null -eq $leaf) { $leaf = Get-AnyLeaf $node }
    return $leaf.name
}
function Get-SelectedTab($win) {
    $sel = $win.tabs | Where-Object { $_.selected } | Select-Object -First 1
    if ($null -eq $sel) { return @($win.tabs)[0] } # fallback; asserted separately
    return $sel
}
# Poll until the selected tab index matches (chord dispatch + list refresh
# are asynchronous); returns the last observed index.
function Wait-SelectedIndex([int]$expect) {
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 150
        $lj = Get-ListJson
        $sel = $lj.data.windows[0].tabs | Where-Object { $_.selected } | Select-Object -First 1
        if ($null -ne $sel -and $sel.index -eq $expect) { return $expect }
    }
    if ($null -eq $sel) { return -1 }
    return $sel.index
}

# If a close-confirm dialog is up (cmd.exe lacks OSC 133 so process_active
# is always true), approve it by posting BM_CLICK to the OK button.
function Approve-ConfirmDialog {
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Milliseconds 100
        $dlg = [T01Drv]::FindConfirmDialog()
        if ($dlg -ne [IntPtr]::Zero) {
            $ok = [T01Drv]::FindWindowExW($dlg, [IntPtr]::Zero, 'BUTTON', 'OK')
            if ($ok -ne [IntPtr]::Zero) {
                [T01Drv]::PostMessageW($ok, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null # BM_CLICK
                Start-Sleep -Milliseconds 400
                return $true
            }
        }
    }
    return $false
}

# --- Setup: fresh debug instance ---------------------------------------------
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out\*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$proc = Start-Process -FilePath $exe -PassThru -RedirectStandardError $errlog
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [T01Drv]::FindTop([uint32]$proc.Id)
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: window not found'; exit 1 }

$lj = Get-ListJson
$win0 = $lj.data.windows[0]
$pane = (Get-PaneName $win0.tabs[0].splits)

# --- Positive control: plain typed text must echo on the input line ----------
$r = [T01Drv]::TypePlain($top, 'kbtctrl')
if ($r -ne 'SENT') { Write-Host "SKIP ALL: positive control not injectable ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
Start-Sleep -Milliseconds 700
$tail = & $exe +read --name=$pane --lines=5 | Out-String
Assert ($tail -match 'kbtctrl') 'positive control: typed text visible in pane'
[T01Drv]::Chord($top, [IntPtr]::Zero, [uint16[]]@(), 0x1B) | Out-Null # Escape clears line
Start-Sleep -Milliseconds 300

# --- ctrl+t: new tab ----------------------------------------------------------
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x54)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+t: $r" }
else {
    Start-Sleep -Milliseconds 1500
    $lj = Get-ListJson
    $tabs = @($lj.data.windows[0].tabs)
    Assert ($tabs.Count -eq 2) "ctrl+t opens a second tab (got $($tabs.Count))"
    Assert ((Get-SelectedTab $lj.data.windows[0]).index -eq 1) 'ctrl+t selects the new tab'
}

# --- ctrl+1 / ctrl+2 / ctrl+9: tab selection ---------------------------------
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x31)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+1: $r" }
else {
    $got = Wait-SelectedIndex 0
    Assert ($got -eq 0) "ctrl+1 selects tab 1 (got index $got)"
}
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x32)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+2: $r" }
else {
    $got = Wait-SelectedIndex 1
    Assert ($got -eq 1) "ctrl+2 selects tab 2 (got index $got)"
}
[T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x31) | Out-Null
Wait-SelectedIndex 0 | Out-Null
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x39)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+9: $r" }
else {
    $got = Wait-SelectedIndex 1
    Assert ($got -eq 1) "ctrl+9 selects the last tab (got index $got)"
}

# --- ctrl+f4: close tab (T02 binding; restores single-tab layout) ------------
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x73)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+f4: $r" }
else {
    Approve-ConfirmDialog | Out-Null
    Start-Sleep -Milliseconds 800
    $lj = Get-ListJson
    $tabs = @($lj.data.windows[0].tabs)
    Assert ($tabs.Count -eq 1) "ctrl+f4 closes the tab (got $($tabs.Count))"
    # +list must still mark the survivor tab selected (regression oracle:
    # run 1 of this script found selected=false on every tab here).
    Assert (@($tabs | Where-Object { $_.selected }).Count -eq 1) 'surviving tab reports selected=true after tab close'
}

# --- ctrl+d: split right ------------------------------------------------------
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x44)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+d: $r" }
else {
    Start-Sleep -Milliseconds 1500
    $lj = Get-ListJson
    $tab = Get-SelectedTab $lj.data.windows[0]
    Assert ((Count-Leaves $tab.splits) -eq 2) 'ctrl+d creates a right split (2 leaves)'
}

# --- ctrl+shift+d: split down -------------------------------------------------
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11, [uint16]0x10), 0x44)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+shift+d: $r" }
else {
    Start-Sleep -Milliseconds 1500
    $lj = Get-ListJson
    $tab = Get-SelectedTab $lj.data.windows[0]
    Assert ((Count-Leaves $tab.splits) -eq 3) 'ctrl+shift+d creates a down split (3 leaves)'
}

# --- ctrl+w: close pane (twice, back to a single leaf) ------------------------
foreach ($expect in 2, 1) {
    $r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x57)
    if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+w: $r"; break }
    Approve-ConfirmDialog | Out-Null
    Start-Sleep -Milliseconds 800
    $lj = Get-ListJson
    $tab = Get-SelectedTab $lj.data.windows[0]
    Assert ((Count-Leaves $tab.splits) -eq $expect) "ctrl+w closes a pane (down to $expect)"
}
Assert (-not $proc.HasExited) 'no crash after tab/split churn'

# --- ctrl+shift+p: command palette opens; Escape closes ----------------------
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11, [uint16]0x10), 0x50)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+shift+p: $r" }
else {
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 100
        $popup = [T01Drv]::FindPalettePopup([uint32]$proc.Id, $top)
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    Assert ($popup -ne [IntPtr]::Zero) 'ctrl+shift+p opens the command palette popup'
    if ($popup -ne [IntPtr]::Zero) {
        [T01Drv]::KeyToPopup($popup, 0x1B) | Out-Null
        Start-Sleep -Milliseconds 500
        Assert ([T01Drv]::FindPalettePopup([uint32]$proc.Id, $top) -eq [IntPtr]::Zero) 'Escape closes the palette'
    }
}

# Re-resolve the focused pane name for the read/write tests below.
$lj = Get-ListJson
$pane = (Get-PaneName (Get-SelectedTab $lj.data.windows[0]).splits)

# --- ctrl+c without selection: SIGINT ----------------------------------------
# Focus positive control first: a plain typed char must echo, proving the
# chord path still reaches the focused surface after the palette round-trip.
$r = [T01Drv]::TypePlain($top, 'focusok')
Start-Sleep -Milliseconds 700
$tail = & $exe +read --name=$pane --lines=5 | Out-String
Assert ($tail -match 'focusok') 'focus control: typing reaches the pane before SIGINT test'
[T01Drv]::Chord($top, [IntPtr]::Zero, [uint16[]]@(), 0x1B) | Out-Null
Start-Sleep -Milliseconds 300

& $exe +send-keys --target=$pane "ping -t 127.0.0.1" Enter | Out-Null
Start-Sleep -Seconds 3
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x43)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+c-sigint: $r" }
else {
    Start-Sleep -Milliseconds 1200
    & $exe +send-keys --target=$pane "echo SIGINT_RECOVERED" Enter | Out-Null
    Start-Sleep -Seconds 2
    $tail = & $exe +read --name=$pane --lines=10 | Out-String
    $ok = $tail -match 'SIGINT_RECOVERED'
    # KNOWN FAIL until the ConPTY ^C-signal task is fixed: raw 0x03 written
    # to the ConPTY input pipe does not interrupt a running console child
    # (repro: +send-keys C-c against ping -t). Tracked in the parity doc.
    Assert $ok 'ctrl+c without selection interrupts (shell prompt back)'
    if (-not $ok) { Write-Host "  pane tail after ctrl+c:`n$tail" }
}
# Cleanup: if ping survived (the known ^C bug), kill it directly so the
# copy/paste tests below still run against a responsive shell. Only touch
# the loopback ping this test started.
Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '127\.0\.0\.1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

# --- ctrl+c WITH selection: copy (no SIGINT) ---------------------------------
# Fill the screen with solid X-runs so a double-click anywhere mid-screen
# word-selects a run of X characters.
& $exe +send-keys --target=$pane "cls" Enter | Out-Null
Start-Sleep -Milliseconds 800
$xline = 'X' * 120
for ($i = 0; $i -lt 10; $i++) {
    & $exe +send-keys --target=$pane "echo $xline" Enter | Out-Null
}
Start-Sleep -Seconds 2
Set-Clipboard -Value 'T01_CLIP_SENTINEL'
$rc = New-Object T01Drv+RECT
[T01Drv]::GetWindowRect($top, [ref]$rc) | Out-Null
$cx = [int](($rc.L + $rc.R) / 2)
$cy = [int](($rc.T + $rc.B) / 2)
$r = [T01Drv]::DoubleClick($top, $cx, $cy)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+c-copy: $r" }
else {
    Start-Sleep -Milliseconds 400
    $r2 = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x43)
    Start-Sleep -Milliseconds 700
    $clip = (Get-Clipboard -Raw -ErrorAction SilentlyContinue) -join ''
    $ok = $clip -match 'X{20}'
    Assert $ok 'ctrl+c with selection copies to clipboard'
    if (-not $ok) {
        $clipShow = if ($clip.Length -gt 80) { $clip.Substring(0, 80) + '...' } else { $clip }
        Write-Host "  clipboard after copy: [$clipShow]"
        $tail = & $exe +read --name=$pane --lines=8 | Out-String
        Write-Host "  pane tail: $($tail -replace 'X{10,}', 'X...X')"
    }
    # The copy path must NOT have interrupted the shell: the input line is
    # still empty and the shell still responds.
    & $exe +send-keys --target=$pane "echo COPY_NO_SIGINT" Enter | Out-Null
    Start-Sleep -Seconds 2
    $tail = & $exe +read --name=$pane --lines=5 | Out-String
    Assert ($tail -match 'COPY_NO_SIGINT') 'shell alive after copy'
}

# --- ctrl+v: paste ------------------------------------------------------------
Set-Clipboard -Value 'T01_PASTE_TOKEN'
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x56)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+v: $r" }
else {
    Start-Sleep -Milliseconds 1000
    $tail = & $exe +read --name=$pane --lines=5 | Out-String
    $ok = $tail -match 'T01_PASTE_TOKEN'
    Assert $ok 'ctrl+v pastes clipboard text onto the input line'
    if (-not $ok) { Write-Host "  pane tail after paste: $tail" }
    [T01Drv]::Chord($top, [IntPtr]::Zero, [uint16[]]@(), 0x1B) | Out-Null
}

# --- ctrl+n: new window -------------------------------------------------------
$r = [T01Drv]::Chord($top, [IntPtr]::Zero, @([uint16]0x11), 0x4E)
if ($r -like 'ABORT*') { Write-Host "SKIP ctrl+n: $r" }
else {
    $wins = @()
    for ($t = 0; $t -lt 30; $t++) {
        Start-Sleep -Milliseconds 200
        $lj = Get-ListJson
        $wins = @($lj.data.windows)
        if ($wins.Count -eq 2) { break }
    }
    Assert ($wins.Count -eq 2) "ctrl+n opens a second window (got $($wins.Count))"
    if ($wins.Count -eq 2) {
        # Close the new window (the one that is not window 0) via IPC.
        $newWin = $wins | Where-Object { $_.id -ne $win0.id } | Select-Object -First 1
        $newPane = (Get-PaneName $newWin.tabs[0].splits)
        & $exe +close --target=$newPane | Out-Null
        Start-Sleep -Milliseconds 1000
        $lj = Get-ListJson
        Assert (@($lj.data.windows).Count -eq 1) 'new window closed via +close'
    }
}
Assert (-not $proc.HasExited) 'no crash at end of run'

# --- Teardown ----------------------------------------------------------------
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }

