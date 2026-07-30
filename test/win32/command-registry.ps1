# T189 acceptance: the command palette runs off the SHARED command registry.
#
# T189 moved the palette's private `palette_entries` array out of Surface.zig
# into `commands.zig`, so the palette and the menu system (T143/T190) render
# one list and dispatch through one path (`Surface.performCommand`). The unit
# tests in the none lane cover the model; this script covers the two things
# only the running app can answer:
#
#   A. a command that was ALREADY in the palette still dispatches after the
#      refactor (regression: the palette is the app's most-used command
#      surface and its dispatch path was rewritten), and
#   B. a command that reached the palette only BECAUSE of the shared registry
#      dispatches too - `Show/Hide All Terminals` (toggle_visibility) had a
#      binding and no palette row before T189.
#
# Both are asserted by OUTCOME, not by reading palette text: a row that is
# absent cannot dispatch, so an outcome is proof of presence as well. A
# negative control (a filter that matches nothing) must dispatch nothing, so
# a passing A/B cannot be "Enter does something no matter what".
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T189 regression.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-command-registry-stderr.log'

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
public class CmdDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
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

    // The top-level window, visible or not (toggle_visibility hides it).
    public static IntPtr FindTopAny(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FirstPane(IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // The palette popup: a visible top-level GhozttyTerminal that is not the
    // window itself (hero-mode.ps1's finder).
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

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab (already-foreground guard included: an
    // unguarded Alt tap self-latches menu mode).
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
            Key(0x12, false); Key(0x12, true);
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
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

    // Type plain VKs (letters/space/Enter) into `edit` in one attachment.
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

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# VK codes for a palette filter string (letters, digits, space only).
function Vks([string]$text) {
    $out = @()
    foreach ($c in $text.ToUpper().ToCharArray()) {
        if ($c -eq ' ') { $out += [uint16]0x20 }
        elseif ($c -match '[A-Z0-9]') { $out += [uint16][int][char]$c }
        else { throw "Vks: unsupported character '$c'" }
    }
    return [uint16[]]$out
}

# Count tabs in the first window reported by `+list --json`.
function Tab-Count {
    $raw = & $exe +list --json 2>$null
    if (-not $raw) { return -1 }
    try { $j = ($raw -join "`n") | ConvertFrom-Json } catch { return -1 }
    $wins = @($j.data.windows)
    if ($wins.Count -eq 0) { return 0 }
    return @($wins[0].tabs).Count
}

# Open the palette, type a filter, press Enter. Returns $true when the whole
# sequence was delivered.
function Invoke-Palette([IntPtr]$top, [IntPtr]$pane, [uint32]$procId, [string]$filter, [string]$label) {
    $r = [CmdDrv]::Chord($top, $pane, [uint16[]]@(0x11, 0x10), 0x50)  # ctrl+shift+p
    if ($r -ne 'SENT') { Write-Host "SKIP ${label}: palette chord not sent ($r)"; return $false }
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $popup -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 20
        $popup = [CmdDrv]::FindPalettePopup($procId, $top)
    }
    Assert ($popup -ne [IntPtr]::Zero) "$label palette opened"
    if ($popup -eq [IntPtr]::Zero) { return $false }
    $edit = [CmdDrv]::FindWindowExW($popup, [IntPtr]::Zero, 'EDIT', $null)
    Assert ($edit -ne [IntPtr]::Zero) "$label palette search box found"
    if ($edit -eq [IntPtr]::Zero) { return $false }
    $keys = @(Vks $filter) + [uint16]0x0D
    $r = [CmdDrv]::TypeKeys($popup, $edit, [uint16[]]$keys)
    Assert ($r -eq 'SENT') "$label filter '$filter' + Enter delivered ($r)"
    Start-Sleep -Milliseconds 800
    return ($r -eq 'SENT')
}

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue

# --session-persistence=false: a restored manifest would hand this run a
# previous section's panes (the T131/T155 trap).
$sp = @{ FilePath = $exe; PassThru = $true; ArgumentList = @('--session-persistence=false') }
if (-not $ExePath) { $sp.RedirectStandardError = $errlog }
$proc = Start-Process @sp
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$pid32 = [uint32]$proc.Id
$top = [CmdDrv]::FindTop($pid32)
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
$pane = [CmdDrv]::FirstPane($top)
if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }

Assert ((Tab-Count) -eq 1) 'setup: one tab'

# --- Positive control: injection reaches binding dispatch ---------------------
$r = [CmdDrv]::Chord($top, $pane, [uint16[]]@(0x11), 0x4B)   # ctrl+k
if ($r -ne 'SENT') { Write-Host "ABORT: control chord not sent ($r)"; Stop-Process -Id $proc.Id -Force; exit 1 }
Start-Sleep -Milliseconds 300
if (Test-Path $errlog) {
    if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
        Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T189 verdict'
        Stop-Process -Id $proc.Id -Force; exit 1
    }
    Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
} else {
    Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
}

# --- A. A pre-existing palette command still dispatches -----------------------
# "New Tab" shipped in the palette long before T189; after the refactor it
# resolves through commands.registry -> Surface.performCommand. Outcome: a
# second tab.
if (Invoke-Palette $top $pane $pid32 'NEW TAB' 'A') {
    Assert (-not $proc.HasExited) 'A no crash dispatching a registry command'
    Assert ((Tab-Count) -eq 2) 'A pre-existing command "New Tab" dispatched (2 tabs)'
}

# --- B. Negative control: a filter that matches nothing does nothing ----------
# Runs BEFORE the visibility test, which leaves the window hidden. Without
# this, A and C could both pass on an app that ran *something* on Enter.
$before = Tab-Count
if (Invoke-Palette $top $pane $pid32 'ZZZZ' 'B') {
    Assert (-not $proc.HasExited) 'B no crash on an empty filter'
    Assert ((Tab-Count) -eq $before) "B empty filter dispatched nothing (still $before tabs)"
    # Enter with nothing selected returns before the close, so the palette
    # STAYS OPEN for the user to fix their filter (Surface.handlePaletteKey ->
    # executePaletteSelection, unchanged by T189 and what VS Code and Windows
    # Terminal both do). Asserted so a future "close on Enter" change has to
    # be a decision rather than a silent one.
    $stillOpen = ([CmdDrv]::FindPalettePopup($pid32, $top) -ne [IntPtr]::Zero)
    Assert $stillOpen 'B palette stays open when the filter matches nothing'
    # Close it so the next section opens a palette rather than toggling one.
    $popup = [CmdDrv]::FindPalettePopup($pid32, $top)
    if ($popup -ne [IntPtr]::Zero) {
        $edit = [CmdDrv]::FindWindowExW($popup, [IntPtr]::Zero, 'EDIT', $null)
        if ($edit -ne [IntPtr]::Zero) { [CmdDrv]::TypeKeys($popup, $edit, [uint16[]]@(0x1B)) | Out-Null }
        Start-Sleep -Milliseconds 300
        Assert ([CmdDrv]::FindPalettePopup($pid32, $top) -eq [IntPtr]::Zero) 'B Escape closes the palette'
    }
}

# --- C. A command that only the shared registry put in the palette ------------
# `Show/Hide All Terminals` (toggle_visibility) had a binding and NO palette
# row before T189. Outcome: the window is hidden. Asserted last because it
# leaves the app with nothing on screen to type into.
$pane2 = [CmdDrv]::FirstPane($top)
if ($pane2 -eq [IntPtr]::Zero) { $pane2 = $pane }
if (Invoke-Palette $top $pane2 $pid32 'HIDE ALL' 'C') {
    $hidden = $false
    for ($t = 0; $t -lt 30 -and -not $hidden; $t++) {
        Start-Sleep -Milliseconds 100
        $hidden = -not [CmdDrv]::IsWindowVisible([CmdDrv]::FindTopAny($pid32))
    }
    Assert (-not $proc.HasExited) 'C app alive after Show/Hide All Terminals'
    Assert $hidden 'C new registry command "Show/Hide All Terminals" dispatched (window hidden)'
    Assert ([CmdDrv]::IsWindow([CmdDrv]::FindTopAny($pid32))) 'C window hidden, not destroyed'
}

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
