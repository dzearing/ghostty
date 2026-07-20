# Remote-inheritance acceptance (tracker T68): --from-focused + New Window /
# split / tab on a remote window reuse the remote host, against a debug build
# + a loopback ghoztty-agent. Non-interactive except one SendInput chord
# (ctrl+t) driven into the debug window on an idle desktop. Only ever touches
# ghoztty processes running from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\remote-inherit.ps1
#
# Covers: +split --from-focused inherits the parent pane's LIVE cwd through
# the agent (GET_CWD), +split --target on a remote window opens a REMOTE
# session with a remote-native --command (never a local ConPTY pane), ctrl+t
# (new tab keybind) inherits the active pane's command, +new-window
# --from-focused dials the SAME agent (second TCP connection) and inherits,
# --from-focused with a local parent falls through to a local window, and a
# dead agent surfaces the reach error instead of a silent local window.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 47911
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-remote-inherit-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

function Get-ListJson {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    Get-Content "$tmp\list.json" -Raw
}

function Get-PaneNames {
    # Leaf terminals carry "name"; windows carry "target" - a flat regex on
    # "name" yields exactly the pane names.
    $json = Get-ListJson
    $names = @()
    foreach ($m in [regex]::Matches($json, '"name":"([^"]*)"')) {
        if ($m.Groups[1].Value -ne '') { $names += $m.Groups[1].Value }
    }
    $names
}

function Read-Pane($name, $outfile) {
    cmd /c "`"$Exe`" +read --name=$name --lines=40 > `"$tmp\$outfile`" 2>&1" | Out-Null
    Get-Content "$tmp\$outfile" -Raw
}

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class RiDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
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

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
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

    // Send mods+vk to the window (SetFocus(top) forwards to the active
    // surface). Returns "SENT" or an ABORT/failure reason.
    public static string Chord(IntPtr top, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(top);
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

Stop-DebugGhoztty

# Marker directories: cwd inheritance is the remote-vs-local oracle. Only a
# pane that inherited through the agent can start in these (cmd.exe has no
# OSC 7, so there is no local cwd-inherit path to confuse the result).
$root = Join-Path $tmp 't68-root'
$sub = Join-Path $root 't68-sub'
New-Item -ItemType Directory -Force $sub | Out-Null

"== 0: start a loopback agent + a base window"
$env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
$agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Assert "agent is running" (-not $agent.HasExited)

# +new-remote-window needs a running instance; only +new-window auto-launches.
& $Exe +new-window --target=rembase 2>&1 | Out-Null
Assert "base window exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$basePanes = @(Get-PaneNames)

"== 1: open a remote window rooted in the marker dir"
cmd /c "`"$Exe`" +new-remote-window --host=127.0.0.1 --port=$Port --name=rem `"--working-directory=$root`" > `"$tmp\open.txt`" 2>&1"
Assert "open exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$before = @(Get-PaneNames)
# Auto-launch creates a default window before rembase, so base state may be
# 2 panes already; assert the delta, not an absolute count.
Assert "one new pane listed for the remote window" ($before.Count -eq ($basePanes.Count + 1))
$remPane = @($before | Where-Object { $basePanes -notcontains $_ })
Assert "remote pane discovered" ($remPane.Count -eq 1)
$dump = Read-Pane $remPane[0] 'read-parent.txt'
Assert "remote pane starts in marker root" ($dump -like "*t68-root*")

"== 2: cd the parent, +split --from-focused inherits the LIVE cwd"
& $Exe +send-keys --target=rem "cd t68-sub" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
cmd /c "`"$Exe`" +split --from-focused --direction=right > `"$tmp\split1.txt`" 2>&1"
Assert "split --from-focused exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$names = @(Get-PaneNames)
Assert "one new pane after split" ($names.Count -eq ($before.Count + 1))
$newPane = @($names | Where-Object { $before -notcontains $_ })
Assert "new pane discovered" ($newPane.Count -eq 1)
$dump = Read-Pane $newPane[0] 'read-split1.txt'
Assert "split pane inherited the cd'd cwd (remote GET_CWD)" ($dump -like "*t68-sub*")

"== 3: +split --target with a remote-native --command stays remote"
cmd /c "`"$Exe`" +split --target=rem --name=remsplit `"--command=echo t68-split-marker`" > `"$tmp\split2.txt`" 2>&1"
Assert "split --target exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$dump = Read-Pane 'remsplit' 'read-split2.txt'
Assert "explicit command ran through the agent" ($dump -like "*t68-split-marker*")

"== 4: ctrl+t - the new-tab keybind inherits the active pane's command"
$namesBeforeTab = @(Get-PaneNames)
# Raise rem so FindTop's z-order-first enumeration lands on it (idempotent
# +new-window on an existing target focuses it).
& $Exe +new-window --target=rem 2>&1 | Out-Null
Start-Sleep -Seconds 1
$ghz = Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.CommandLine -like '*zig-out*' } | Select-Object -First 1
$top = [RiDrv]::FindTop([uint32]$ghz.ProcessId)
Assert "found the remote window HWND" ($top -ne [IntPtr]::Zero)
$sent = [RiDrv]::Chord($top, @([uint16]0x11), [uint16]0x54) # ctrl+t
Assert "ctrl+t injected ($sent)" ($sent -eq 'SENT')
Start-Sleep -Seconds 3
$namesAfterTab = @(Get-PaneNames)
Assert "new tab pane appeared" ($namesAfterTab.Count -eq ($namesBeforeTab.Count + 1))
$tabPane = @($namesAfterTab | Where-Object { $namesBeforeTab -notcontains $_ })
if ($tabPane.Count -eq 1) {
    $dump = Read-Pane $tabPane[0] 'read-tab.txt'
    # The active pane at ctrl+t was remsplit (last split takes focus), so the
    # tab re-runs its command (Mac WP4 command inheritance).
    Assert "new tab re-ran the parent pane's remote command" ($dump -like "*t68-split-marker*")
} else {
    Assert "new tab pane identified" $false
}

"== 5: +new-window --from-focused dials the SAME agent"
$connsBefore = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
cmd /c "`"$Exe`" +new-window --from-focused > `"$tmp\neww.txt`" 2>&1"
Assert "new-window --from-focused exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$connsAfter = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
Assert "a second agent connection exists" ($connsAfter.Count -eq ($connsBefore.Count + 1))
$namesAfterWin = @(Get-PaneNames)
$winPane = @($namesAfterWin | Where-Object { $namesAfterTab -notcontains $_ })
Assert "new window's pane discovered" ($winPane.Count -eq 1)
if ($winPane.Count -eq 1) {
    $dump = Read-Pane $winPane[0] 'read-neww.txt'
    # Inherits from rem's active pane (the ctrl+t tab, itself running the
    # marker command) - output proves the window opened on the agent.
    Assert "new window inherited the remote command" ($dump -like "*t68-split-marker*")
}

"== 6: --from-focused with a LOCAL parent falls through to local"
& $Exe +new-window --target=locbase 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $Exe +new-window --target=locbase 2>&1 | Out-Null # idempotent re-call focuses it
Start-Sleep -Seconds 1
$namesBeforeLocal = @(Get-PaneNames)
cmd /c "`"$Exe`" +split --from-focused > `"$tmp\lsplit.txt`" 2>&1"
Assert "local split --from-focused exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$namesAfterLocal = @(Get-PaneNames)
Assert "local from-focused split created a pane" ($namesAfterLocal.Count -eq ($namesBeforeLocal.Count + 1))
$connsLocal = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
Assert "no extra agent connection for the local split" ($connsLocal.Count -eq $connsAfter.Count)
cmd /c "`"$Exe`" +new-window --from-focused > `"$tmp\lneww.txt`" 2>&1"
Assert "local new-window --from-focused exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$namesAfterLocalWin = @(Get-PaneNames)
Assert "local from-focused window created a pane" ($namesAfterLocalWin.Count -eq ($namesAfterLocal.Count + 1))
$connsLocal2 = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
Assert "no extra agent connection for the local window" ($connsLocal2.Count -eq $connsAfter.Count)

"== 7: dead agent surfaces the reach error (no silent local window)"
# Close everything but rem first: frontWindow falls back to the last-created
# window when no ghoztty window owns the foreground (headless-run safety),
# so rem must be the only window left for --from-focused to target it.
& $Exe +close --target=locbase 2>&1 | Out-Null
$list = Get-ListJson
foreach ($m in [regex]::Matches($list, '"target":"(window-\d+)"')) {
    & $Exe +close --target=$($m.Groups[1].Value) 2>&1 | Out-Null
}
Start-Sleep -Seconds 1
Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
cmd /c "`"$Exe`" +new-window --from-focused > `"$tmp\dead.txt`" 2>&1"
Assert "exit nonzero with dead agent" ($LASTEXITCODE -ne 0)
$err = Get-Content "$tmp\dead.txt" -Raw
Assert "error names the remote machine" ($err -like "*remote machine*")
$list = Get-ListJson
Assert "app still alive after failed re-dial" ($list -like '*"success":true*')

"== cleanup"
& $Exe +close --target=rem 2>&1 | Out-Null
Start-Sleep -Seconds 1
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
