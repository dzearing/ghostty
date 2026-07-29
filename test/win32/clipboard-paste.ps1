# T154 acceptance: ctrl+v must PASTE when the clipboard holds text, and must
# FALL THROUGH to the pane (as a raw ^V) when it does not.
#
# Why this matters: Claude Code (and other TUIs) read images off the system
# clipboard themselves when they receive ^V. Before T154 the Windows
# ctrl-mirror block bound ctrl+v with a plain put() and no `performable`
# flag, so ghoztty swallowed the chord unconditionally, pasted nothing (no
# CF_UNICODETEXT on an image-only clipboard) and the TUI never saw the key.
#
# Oracle: a tiny PowerShell probe runs INSIDE the pane and blocks on
# [Console]::ReadKey($true), then prints the character code it received.
# That distinguishes the three outcomes precisely:
#   text clipboard  + ctrl+v       -> probe sees the token's FIRST char (paste)
#   image clipboard + ctrl+v       -> probe sees 22 (0x16 = ^V, fall-through)
#   image clipboard + ctrl+shift+v -> probe sees 22 (already performable)
# A swallowed chord shows up as the probe never printing at all.
#
# Mechanics mirror keybinds-t01.ps1: T86-hardened foreground grab +
# AttachThreadInput + SendInput, with foreground re-verified immediately
# before each injection so keystrokes can never leak into another app (the
# test SKIPs rather than fails in that case). A positive control runs first
# so a chord failure cannot be blamed on the harness.
#
# Only touches ghoztty processes running from this repo's zig-out.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP 'ghoztty-clipboard-paste-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class ClipDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // The terminal SURFACE is a GhozttyTerminal child of the GhozttyWindow
    // top-level. Keystrokes only reach the shell when that child holds
    // keyboard focus; a window that was raised programmatically (never
    // clicked) can be foreground with focus still on the frame, which
    // silently swallows every injected key.
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

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab (see keybinds-t01.ps1).
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

    public static string Chord(IntPtr top, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            IntPtr paneH = FirstPane(top);
            if (paneH != IntPtr.Zero) SetFocus(paneH);
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

    public static string TypePlain(IntPtr top, string text) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            IntPtr paneH = FirstPane(top);
            if (paneH != IntPtr.Zero) SetFocus(paneH);
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
}
'@

# --- clipboard helpers --------------------------------------------------------
# powershell.exe is STA by default, which System.Windows.Forms.Clipboard
# requires. Bail loudly rather than producing confusing failures if not.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'SETUP FAIL: run under an STA host (powershell.exe, not -MTA)'
    exit 1
}

function Set-TextClipboard([string]$text) {
    for ($t = 0; $t -lt 10; $t++) {
        try {
            [System.Windows.Forms.Clipboard]::Clear()
            [System.Windows.Forms.Clipboard]::SetText($text)
            return $true
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}

# An IMAGE with NO text format at all - this is the screenshot case that
# T154 is about (GetClipboardData(CF_UNICODETEXT) returns null).
function Set-ImageOnlyClipboard {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Red)
    $g.Dispose()
    try {
        for ($t = 0; $t -lt 10; $t++) {
            try {
                [System.Windows.Forms.Clipboard]::Clear()
                [System.Windows.Forms.Clipboard]::SetImage($bmp)
                return $true
            } catch { Start-Sleep -Milliseconds 200 }
        }
    } finally { $bmp.Dispose() }
    return $false
}

# --- the in-pane probe --------------------------------------------------------
# Blocks on ReadKey and prints the raw character code it received. Written
# to TEMP so no quoting has to survive +send-keys.
$probe = Join-Path $env:TEMP 'ghoztty-clip-probe.ps1'
@'
param([string]$Tag)
[Console]::Out.Write("PROBE_READY_" + $Tag + "`r`n")
$k = [Console]::ReadKey($true)
[Console]::Out.Write("PROBE_" + $Tag + "_CHAR=" + [int]$k.KeyChar + "`r`n")
'@ | Set-Content -Path $probe -Encoding ASCII

function Read-Tail([int]$lines = 20) {
    return (& $exe +read --name=$script:pane --lines=$lines | Out-String)
}

function Wait-Text([string]$pattern, [int]$timeoutSec = 12) {
    for ($t = 0; $t -lt $timeoutSec * 5; $t++) {
        Start-Sleep -Milliseconds 200
        $tail = Read-Tail
        if ($tail -match $pattern) { return $tail }
    }
    return $null
}

# Start the probe and wait until it is actually blocked in ReadKey.
function Start-Probe([string]$tag) {
    & $exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
    Start-Sleep -Milliseconds 600
    & $exe +send-keys --target=$script:pane "powershell -NoProfile -File $probe -Tag $tag" Enter | Out-Null
    $seen = Wait-Text "PROBE_READY_$tag"
    if ($null -eq $seen) { return $false }
    Start-Sleep -Milliseconds 500   # ReadKey is entered right after the print
    return $true
}

# Unblock a probe that never received a key, and get back to a prompt.
function Stop-Probe {
    & $exe +send-keys --target=$script:pane 'q' | Out-Null
    Start-Sleep -Milliseconds 400
    & $exe +send-keys --target=$script:pane Enter | Out-Null
    Start-Sleep -Milliseconds 800
}

# --- Setup: fresh debug instance ---------------------------------------------
# --session-persistence=false so a restore cannot hand back a previous run's
# window (the T131 lesson).
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out\*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$outlog = Join-Path $env:TEMP 'ghoztty-clipboard-paste-stdout.log'
# Redirect BOTH streams: a GUI child that inherits this script's stdout pipe
# keeps it open after the script exits and hangs the caller's pipeline (the
# trap documented in the T86 harness notes).
$proc = Start-Process -FilePath $exe -ArgumentList '--session-persistence=false' -PassThru `
    -RedirectStandardError $errlog -RedirectStandardOutput $outlog

# Every early exit must take the GUI with it: a surviving child keeps the
# redirect handles open and hangs whatever pipeline invoked this script.
function Die([string]$msg) {
    Write-Host $msg
    if ($null -ne $script:proc -and -not $script:proc.HasExited) {
        Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

function Get-AnyLeaf($node) {
    if ($node.type -eq 'leaf') { return $node.terminal }
    return (Get-AnyLeaf $node.left)
}
# The window id in +list --json IS the decimal HWND, so the chord driver
# targets exactly the instance we launched (FindTop-by-class is unreliable:
# GhozttyTerminal is the PANE class, not the top-level's).
$lj = $null
for ($t = 0; $t -lt 25 -and $null -eq $lj; $t++) {
    $lj = & $exe +list --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $lj -or @($lj.data.windows).Count -eq 0) { $lj = $null; Start-Sleep -Milliseconds 300 }
}
if ($null -eq $lj) { Die 'SETUP FAIL: no window in +list' }
$win0 = $lj.data.windows[0]
$top = [IntPtr]([int64]$win0.id)
$script:pane = (Get-AnyLeaf $win0.tabs[0].splits).name
if ([string]::IsNullOrEmpty($script:pane)) { Die 'SETUP FAIL: no pane name' }
Write-Host "pane=$script:pane top=$top"

# --- Positive control: typed text must echo ----------------------------------
& $exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
Start-Sleep -Milliseconds 600
$r = [ClipDrv]::TypePlain($top, 'clipctl')
if ($r -like 'ABORT*' -or $r -like 'ATTACH*') {
    Write-Host "SKIP ALL: harness cannot drive keys ($r)"
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    exit 0
}
$tail = Wait-Text 'clipctl' 8
if ($null -eq $tail) {
    # A box that cannot deliver SendInput at all (the GameInputSvc wedge)
    # would otherwise report every chord case as a product failure.
    Write-Host 'SKIP ALL: positive control failed - injected keys never reached the pane'
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    exit 0
}
Assert $true 'positive control: typed keys reach the pane'
& $exe +send-keys --target=$script:pane C-c | Out-Null
Start-Sleep -Milliseconds 600

# --- Harness sanity: the clipboard fixtures are what we claim -----------------
Assert (Set-TextClipboard 'ZQTOKEN') 'harness: text clipboard set'
Assert ([System.Windows.Forms.Clipboard]::ContainsText()) 'harness: text clipboard reports text'
Assert (Set-ImageOnlyClipboard) 'harness: image clipboard set'
Assert ([System.Windows.Forms.Clipboard]::ContainsImage()) 'harness: image clipboard reports an image'
Assert (-not [System.Windows.Forms.Clipboard]::ContainsText()) 'harness: image clipboard has NO text format'

# --- A: text clipboard + ctrl+v -> pastes (probe sees the token, not ^V) ------
Set-TextClipboard 'ZQTOKEN' | Out-Null
if (-not (Start-Probe 'A')) {
    Write-Host 'SKIP A: probe never became ready'
} else {
    $r = [ClipDrv]::Chord($top, @([uint16]0x11), 0x56)   # ctrl+v
    if ($r -like 'ABORT*') { Write-Host "SKIP A: $r" }
    else {
        $tail = Wait-Text 'PROBE_A_CHAR=(\d+)' 10
        $code = if ($tail -match 'PROBE_A_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
        Assert ($code -eq 90) "A: ctrl+v with text on the clipboard pastes (probe char=$code, want 90 'Z')"
        Assert ($code -ne 22) "A: ctrl+v does NOT leak a stray ^V when the paste succeeds"
    }
    Stop-Probe
}

# --- B: image-only clipboard + ctrl+v -> falls through as ^V ------------------
# THE T154 CASE. Pre-fix this fails with code=-1: ghoztty swallows the chord.
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'B')) {
    Write-Host 'SKIP B: probe never became ready'
} else {
    $r = [ClipDrv]::Chord($top, @([uint16]0x11), 0x56)   # ctrl+v
    if ($r -like 'ABORT*') { Write-Host "SKIP B: $r" }
    else {
        $tail = Wait-Text 'PROBE_B_CHAR=(\d+)' 10
        $code = if ($tail -match 'PROBE_B_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
        Assert ($code -eq 22) "B: ctrl+v with an image-only clipboard reaches the pane as ^V (probe char=$code, want 22)"
    }
    Stop-Probe
}

# --- C: image-only clipboard + ctrl+shift+v -> already falls through ----------
# The shared cross-platform binding has always carried performable=true; this
# is the control that proves the diagnosis is about the FLAG, not the chord.
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'C')) {
    Write-Host 'SKIP C: probe never became ready'
} else {
    $r = [ClipDrv]::Chord($top, @([uint16]0x11, [uint16]0x10), 0x56)  # ctrl+shift+v
    if ($r -like 'ABORT*') { Write-Host "SKIP C: $r" }
    else {
        $tail = Wait-Text 'PROBE_C_CHAR=(\d+)' 10
        $code = if ($tail -match 'PROBE_C_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
        Assert ($code -eq 22) "C: ctrl+shift+v with an image-only clipboard reaches the pane as ^V (probe char=$code, want 22)"
    }
    Stop-Probe
}

# --- D: text clipboard + ctrl+v at a normal prompt still pastes the text ------
# Section A proves the FIRST character; this proves the whole string lands on
# the input line (i.e. the paste path itself is untouched by the flag).
Set-TextClipboard 'ZQ_FULL_PASTE_TOKEN' | Out-Null
& $exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
Start-Sleep -Milliseconds 800
$r = [ClipDrv]::Chord($top, @([uint16]0x11), 0x56)
if ($r -like 'ABORT*') { Write-Host "SKIP D: $r" }
else {
    $tail = Wait-Text 'ZQ_FULL_PASTE_TOKEN' 10
    Assert ($null -ne $tail) 'D: ctrl+v pastes the full clipboard text onto the input line'
    & $exe +send-keys --target=$script:pane C-c | Out-Null
    Start-Sleep -Milliseconds 500
}

Assert (-not $proc.HasExited) 'no crash at end of run'

# --- Teardown ----------------------------------------------------------------
Set-TextClipboard '' | Out-Null
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $probe -ErrorAction SilentlyContinue
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
