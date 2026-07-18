# T65 acceptance: child-exited UI is the core in-terminal fallback, not a
# modal MessageBox. Runs the debug build with a private config
# (wait-after-command=true, abnormal-command-exit-runtime=5000) via
# XDG_CONFIG_HOME so exits keep the pane open and fast nonzero exits count
# as abnormal deterministically.
#
#   powershell -NoProfile -File test\win32\ipc-child-exited.ps1
#
# Covers: clean exit + wait-after-command shows the press-any-key notice
# (previously showed NOTHING), abnormal exit shows the rich in-terminal
# diagnostic (command + runtime), no #32770 modal dialog exists, and a
# REAL key press (SendInput, kb-actions.ps1 recipe — +send-keys writes to
# the PTY and cannot exercise the close-on-key path) closes the waited pane.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-t65-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

function Get-ListJson {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    try { Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json } catch { $null }
}

# Depth-first first leaf of a splits node.
function Get-FirstLeaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node }
    $l = Get-FirstLeaf $node.left
    if ($null -ne $l) { return $l }
    Get-FirstLeaf $node.right
}

function Get-PaneName($target) {
    $j = Get-ListJson
    if ($null -eq $j) { return $null }
    $win = $j.data.windows | Where-Object { $_.target -eq $target }
    if ($null -eq $win) { return $null }
    (Get-FirstLeaf $win.tabs[0].splits).terminal.name
}

function Read-Pane($name, $lines) {
    cmd /c "`"$Exe`" +read --name=$name --lines=$lines > `"$tmp\read.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\read.txt" -Raw
}

Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public static class T65Drv {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    delegate bool EnumProc(IntPtr h, IntPtr lp);

    public static string ClassName(IntPtr h) {
        var sb = new StringBuilder(64);
        GetClassNameW(h, sb, 64);
        return sb.ToString();
    }

    public static int CountDialogsForPids(uint[] pids) {
        var set = new HashSet<uint>(pids);
        int count = 0;
        EnumWindows((h, lp) => {
            if (!IsWindowVisible(h)) return true;
            if (ClassName(h) != "#32770") return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (set.Contains(pid)) count++;
            return true;
        }, IntPtr.Zero);
        return count;
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Real single-key press into the surface (kb-actions.ps1 recipe:
    // SetForegroundWindow + AttachThreadInput + SetFocus + SendInput).
    // Returns "SENT" or an ABORT/failure reason.
    public static string PressKey(IntPtr top, IntPtr surface, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        SetForegroundWindow(top);
        Thread.Sleep(150);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
            Key(vk, false); Thread.Sleep(20); Key(vk, true);
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }
}
'@

Stop-DebugGhoztty

"== setup: private config (wait-after-command, generous abnormal window)"
$cfgDir = Join-Path $tmp 'xdg\ghostty'
New-Item -ItemType Directory -Force $cfgDir | Out-Null
@(
    'wait-after-command = true'
    'abnormal-command-exit-runtime = 5000'
) | Set-Content -Path (Join-Path $cfgDir 'config') -Encoding ascii
$env:XDG_CONFIG_HOME = Join-Path $tmp 'xdg'

"== 1: clean exit 0 + wait-after-command -> press-any-key notice"
& $Exe +new-window --target=ce0 -e cmd /c exit 0 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 4
$list = Get-ListJson
Assert "window stayed open" ($null -ne ($list.data.windows | Where-Object { $_.target -eq 'ce0' }))
$pane0 = Get-PaneName 'ce0'
Assert "pane discovered" (-not [string]::IsNullOrEmpty($pane0))
$txt0 = Read-Pane $pane0 10
Assert "press-any-key notice shown" ($txt0 -match 'Process exited')

"== 2: abnormal exit 3 -> rich in-terminal diagnostic"
& $Exe +new-window --target=ce3 -e cmd /c exit 3 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$pane3 = Get-PaneName 'ce3'
Assert "pane discovered" (-not [string]::IsNullOrEmpty($pane3))
$txt3 = Read-Pane $pane3 20
Assert "diagnostic header shown" ($txt3 -match 'failed to launch')
Assert "command echoed" ($txt3 -match 'exit 3')
Assert "runtime shown" ($txt3 -match 'Runtime:')

"== 3: no modal dialog anywhere"
$pids = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $Exe } |
    ForEach-Object { [uint32]$_.ProcessId })
Assert "app process running" ($pids.Count -ge 1)
$dialogs = [T65Drv]::CountDialogsForPids($pids)
Assert "no #32770 dialog owned by ghoztty" ($dialogs -eq 0)
& $Exe +list 2>&1 | Out-Null
Assert "IPC responsive" ($LASTEXITCODE -eq 0)

"== 4: real key press closes the waited pane"
$win0 = $list.data.windows | Where-Object { $_.target -eq 'ce0' }
$top0 = [IntPtr][int64]$win0.id
Assert "list id is the top hwnd" ([T65Drv]::ClassName($top0) -eq 'GhozttyWindow')
$surf0 = [T65Drv]::FindWindowExW($top0, [IntPtr]::Zero, 'GhozttyTerminal', $null)
Assert "surface child found" ($surf0 -ne [IntPtr]::Zero)
$r = [T65Drv]::PressKey($top0, $surf0, 0x41)  # plain 'a'
Assert "key injected" ($r -eq 'SENT')
Start-Sleep -Seconds 2
$list = Get-ListJson
Assert "ce0 closed by key press" ($null -eq ($list.data.windows | Where-Object { $_.target -eq 'ce0' }))
Assert "ce3 still open (abnormal path waits)" ($null -ne ($list.data.windows | Where-Object { $_.target -eq 'ce3' }))

"== teardown"
& $Exe +close --target=ce3 2>&1 | Out-Null
Stop-DebugGhoztty
Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS" ; exit 0 }
else { "$script:failures FAILURE(S)" ; exit 1 }
