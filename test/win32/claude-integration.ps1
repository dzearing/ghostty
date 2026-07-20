# T71 acceptance: Claude Code integration setup — first-run offer + palette
# entry (win32 port of Mac ClaudeCodeIntegration.swift / AppDelegate+Setup).
#
# Covered:
#   1. First run (claude present, plugin absent, no answer on file) -> the
#        "Set Up Claude Code Integration?" dialog appears with Set Up /
#        Not Now buttons; Escape (=Not Now) declines: no claude invocation,
#        state file records "declined".
#   2. Relaunch with the declined state -> NO dialog (declining remembered).
#   3. Fresh state, prompt accepted via Enter (Set Up is the default) ->
#        the stub claude gets `plugin marketplace add` + `plugin install`
#        with the exact ids, state records "accepted", and first-run
#        success stays silent (no outcome dialog).
#   4. Palette entry: ctrl+shift+p -> "claude" -> Enter reruns the flow and
#        REPORTS the outcome ("Claude Code Integration Ready"), two more
#        stub invocations land in the log.
#   5. claude missing (override points at a nonexistent exe): launch shows
#        no prompt and burns nothing (no state file, so a later claude
#        install still gets the offer); the palette entry says
#        "Claude Code Not Found".
#
# The claude CLI is a stub .cmd (GHOZTTY_CLAUDE_EXE) that logs its args and
# answers per CLAUDE_STUB_MODE, so the box's real claude config is never
# touched. State/plugins-registry paths are redirected via
# GHOZTTY_CLAUDE_STATE_DIR / GHOZTTY_CLAUDE_PLUGINS_JSON; the config is
# isolated via XDG_CONFIG_HOME (the T69 pattern).
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
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class ClaudeDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() {
        SetProcessDpiAwarenessContext((IntPtr)(-4)); // PER_MONITOR_AWARE_V2
    }

    public static IntPtr FindClass(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindChild(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // The visible palette popup: a top-level (owned, WS_POPUP) window of
    // the same pid using the terminal class — not a child of `top`.
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

    public static string WindowText(IntPtr h) {
        var sb = new StringBuilder(256);
        GetWindowTextW(h, sb, 256);
        return sb.ToString();
    }

    // Captions of all BUTTON children, in z-order.
    public static string[] ButtonTexts(IntPtr top) {
        var texts = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "Button" || sb.ToString() == "BUTTON") {
                var tb = new StringBuilder(128);
                GetWindowTextW(h, tb, 128);
                texts.Add(tb.ToString());
            }
            return true;
        }, IntPtr.Zero);
        return texts.ToArray();
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Press(ushort vk) {
        Key(vk, false); Thread.Sleep(30); Key(vk, true);
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

    // Send mods+vk with focus on `surface`. Returns "SENT" or a reason.
    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        if (!GrabForeground(top)) return "ABORT: could not foreground";
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground lost";
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
[ClaudeDrv]::BeDpiAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Wait for a visible window of $cls in $gpid (or its disappearance).
function Wait-Class([uint32]$gpid, [string]$cls, [bool]$appear, [int]$tries = 30) {
    for ($t = 0; $t -lt $tries; $t++) {
        $d = [ClaudeDrv]::FindClass($gpid, $cls)
        $vis = ($d -ne [IntPtr]::Zero)
        if ($vis -eq $appear) { return $d }
        Start-Sleep -Milliseconds 100
    }
    if ($appear) { return [IntPtr]::Zero } else { return $d }
}

# ---------------------------------------------------------------- fixtures
$base = Join-Path $env:TEMP 'ghoztty-t71'
Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $base | Out-Null

# Isolated config home (T69 pattern) so the box's real config never leaks.
$cfgHome = Join-Path $base 'xdg'
New-Item -ItemType Directory -Force (Join-Path $cfgHome 'ghostty') | Out-Null
Set-Content -Path (Join-Path $cfgHome 'ghostty\config') -Value "# empty`n" -Encoding ascii

# Stub claude CLI: logs argument lines, answers per CLAUDE_STUB_MODE.
$stubLog = Join-Path $base 'stub.log'
$stub = Join-Path $base 'claude.cmd'
@"
@echo off
>> "$stubLog" echo %*
if /i "%CLAUDE_STUB_MODE%"=="fail" (
  echo Error: stub failure
  exit /b 1
)
if /i "%CLAUDE_STUB_MODE%"=="already" (
  echo already installed
  exit /b 0
)
echo Installed
exit /b 0
"@ | Set-Content -Path $stub -Encoding ascii

# Plugins registry WITHOUT any ghoztty plugin (so the prompt is offered).
$pluginsJson = Join-Path $base 'installed_plugins.json'
Set-Content -Path $pluginsJson -Value '{"version":2,"plugins":{}}' -Encoding ascii

$MARKETPLACE = 'dzearing/ghoztty-claude-plugin'
$PLUGIN = 'ghoztty@ghoztty-claude-plugin'

function Launch-Gui([string]$stateDir, [string]$claudeExe, [string]$stubMode) {
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_CLAUDE_SETUP = 'force'
    $env:GHOZTTY_CLAUDE_EXE = $claudeExe
    $env:GHOZTTY_CLAUDE_STATE_DIR = $stateDir
    $env:GHOZTTY_CLAUDE_PLUGINS_JSON = $pluginsJson
    $env:CLAUDE_STUB_MODE = $stubMode
    $env:CLAUDE_STUB_LOG = $stubLog
    try { $proc = Start-Process -FilePath $exe -PassThru }
    finally {
        'XDG_CONFIG_HOME', 'GHOZTTY_CLAUDE_SETUP', 'GHOZTTY_CLAUDE_EXE',
        'GHOZTTY_CLAUDE_STATE_DIR', 'GHOZTTY_CLAUDE_PLUGINS_JSON',
        'CLAUDE_STUB_MODE', 'CLAUDE_STUB_LOG' | ForEach-Object {
            Remove-Item "Env:$_" -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = [ClaudeDrv]::FindClass([uint32]$proc.Id, 'GhozttyWindow')
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; Stop-Process -Id $proc.Id -Force; exit 1 }
    return @{ Proc = $proc; Top = $top }
}

# Open the palette, type "claude", Enter. Returns $true when everything
# was injected (palette opening doubles as the chord positive control).
function Invoke-PaletteClaude($g) {
    $surface = [ClaudeDrv]::FindChild($g.Top, 'GhozttyTerminal')
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: surface not found'; return $false }
    $r = [ClaudeDrv]::Chord($g.Top, $surface, [uint16[]]@(0x11, 0x10), 0x50)  # ctrl+shift+p
    if ($r -ne 'SENT') { Write-Host "SETUP FAIL: palette chord not injected ($r)"; return $false }
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $popup -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 20
        $popup = [ClaudeDrv]::FindPalettePopup([uint32]$g.Proc.Id, $g.Top)
    }
    if ($popup -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette popup did not open'; return $false }
    $edit = [ClaudeDrv]::FindWindowExW($popup, [IntPtr]::Zero, 'EDIT', $null)
    if ($edit -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette edit not found'; return $false }
    # C L A U D E then Enter
    $r = [ClaudeDrv]::TypeKeys($popup, $edit, [uint16[]]@(0x43, 0x4C, 0x41, 0x55, 0x44, 0x45, 0x0D))
    if ($r -ne 'SENT') { Write-Host "SETUP FAIL: palette keys not typed ($r)"; return $false }
    return $true
}

function Get-StubLines {
    if (-not (Test-Path $stubLog)) { return @() }
    return @(Get-Content $stubLog | Where-Object { $_.Trim() -ne '' })
}

# Poll until the stub log holds $count lines (claude runs are async).
function Wait-StubLines([int]$count, [int]$tries = 150) {
    for ($t = 0; $t -lt $tries; $t++) {
        $lines = Get-StubLines
        if ($lines.Count -ge $count) { return $lines }
        Start-Sleep -Milliseconds 100
    }
    return (Get-StubLines)
}

$VK_ESCAPE = [uint16]0x1B
$VK_RETURN = [uint16]0x0D

Kill-RepoInstances

# ---------------------------------------------------------------- case 1:
# first run -> prompt with Set Up / Not Now; Escape declines, no CLI run.
$state1 = Join-Path $base 'state1'
$g = Launch-Gui $state1 $stub 'ok'
$gpid = [uint32]$g.Proc.Id

$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 80
Assert ($dlg -ne [IntPtr]::Zero) 'first run shows the Set Up Claude Code Integration prompt'
if ($dlg -eq [IntPtr]::Zero) { Stop-Process -Id $gpid -Force; exit 1 }

Assert ([ClaudeDrv]::WindowText($dlg) -eq 'Set Up Claude Code Integration?') 'prompt title is Set Up Claude Code Integration?'
$btns = [ClaudeDrv]::ButtonTexts($dlg)
Assert (($btns -contains 'Set Up') -and ($btns -contains 'Not Now')) "buttons are Set Up / Not Now (got: $($btns -join ', '))"

[ClaudeDrv]::Press($VK_ESCAPE)
$gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
Assert ($gone -eq [IntPtr]::Zero) 'Escape (Not Now) dismisses the prompt'
Start-Sleep -Milliseconds 500
Assert ((Get-StubLines).Count -eq 0) 'declining runs no claude command'
$stateFile = Join-Path $state1 'claude_setup'
Assert ((Test-Path $stateFile) -and ((Get-Content $stateFile -Raw).Trim() -eq 'declined')) 'state file records declined'
Assert (-not $g.Proc.HasExited) 'app keeps running after declining'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------- case 2:
# relaunch with the declined answer -> no prompt (case 1 proved this env
# shows one when unanswered, so the negative is trustworthy).
$g = Launch-Gui $state1 $stub 'ok'
$gpid = [uint32]$g.Proc.Id
$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 40
Assert ($dlg -eq [IntPtr]::Zero) 'declined answer is remembered: no prompt on relaunch'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------- case 3:
# fresh state, accept via Enter -> both claude commands run, silent success.
$state3 = Join-Path $base 'state3'
$g = Launch-Gui $state3 $stub 'ok'
$gpid = [uint32]$g.Proc.Id

$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 80
Assert ($dlg -ne [IntPtr]::Zero) 'fresh state shows the prompt again'
if ($dlg -eq [IntPtr]::Zero) { Stop-Process -Id $gpid -Force; exit 1 }
[ClaudeDrv]::Press($VK_RETURN)  # Set Up is the Enter default
$gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
Assert ($gone -eq [IntPtr]::Zero) 'Enter (Set Up) dismisses the prompt'

$lines = Wait-StubLines 2
Assert ($lines.Count -eq 2) "accepting runs exactly two claude commands (got $($lines.Count))"
Assert (@($lines | Where-Object { $_ -match [regex]::Escape("plugin marketplace add $MARKETPLACE") }).Count -eq 1) 'marketplace add ran with the exact id'
Assert (@($lines | Where-Object { $_ -match [regex]::Escape("plugin install $PLUGIN") }).Count -eq 1) 'plugin install ran with the exact id'

$stateFile3 = Join-Path $state3 'claude_setup'
$stateOk = $false
for ($t = 0; $t -lt 30 -and -not $stateOk; $t++) {
    if ((Test-Path $stateFile3) -and ((Get-Content $stateFile3 -Raw).Trim() -eq 'accepted')) { $stateOk = $true }
    Start-Sleep -Milliseconds 100
}
Assert $stateOk 'state file records accepted'

# First-run success is silent: no outcome dialog shows up afterwards.
Start-Sleep -Milliseconds 1500
Assert (([ClaudeDrv]::FindClass($gpid, 'GhozttyConfirmDialog')) -eq [IntPtr]::Zero) 'first-run success shows no outcome dialog'

# ---------------------------------------------------------------- case 4:
# palette entry reruns the flow and reports the outcome (same instance).
if (Invoke-PaletteClaude $g) {
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 200
    Assert ($dlg -ne [IntPtr]::Zero) 'palette install reports an outcome dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ([ClaudeDrv]::WindowText($dlg) -eq 'Claude Code Integration Ready') 'palette outcome title is Claude Code Integration Ready'
        [ClaudeDrv]::Press($VK_ESCAPE)
        $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
        Assert ($gone -eq [IntPtr]::Zero) 'outcome dialog dismisses'
    }
    $lines = Wait-StubLines 4
    Assert ($lines.Count -eq 4) "palette run adds two more claude commands (got $($lines.Count))"
} else {
    Assert $false 'palette claude flow injectable'
}
Assert (-not $g.Proc.HasExited) 'app alive after palette flow'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------- case 5:
# claude missing: no prompt, nothing burned; palette says Not Found.
$state5 = Join-Path $base 'state5'
$g = Launch-Gui $state5 (Join-Path $base 'no-such-claude.exe') 'ok'
$gpid = [uint32]$g.Proc.Id
$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 40
Assert ($dlg -eq [IntPtr]::Zero) 'no claude CLI: no first-run prompt'
Assert (-not (Test-Path (Join-Path $state5 'claude_setup'))) 'no claude CLI: prompt not burned (no state file)'

if (Invoke-PaletteClaude $g) {
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 100
    Assert ($dlg -ne [IntPtr]::Zero) 'palette install without claude reports a dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ([ClaudeDrv]::WindowText($dlg) -eq 'Claude Code Not Found') 'outcome title is Claude Code Not Found'
        [ClaudeDrv]::Press($VK_ESCAPE)
        $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
        Assert ($gone -eq [IntPtr]::Zero) 'not-found dialog dismisses'
    }
} else {
    Assert $false 'palette claude flow injectable (no-claude case)'
}
Assert (-not (Test-Path (Join-Path $state5 'claude_setup'))) 'not-found leaves no state file'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue

Kill-RepoInstances
Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S), $script:pass pass" }
