# New-window working-directory fidelity under session persistence (tracker T144).
#
# User report, 2026-07-29: "it keeps defaulting to windows system32 folder
# (HORRIBLE!) this should never be the default path for opening cmd."
#
# Root cause, MEASURED on the box before the fix (see the task file):
#
#   1. The local session-persistence agent inherits the cwd of whatever started
#      it. The installed release agent is started by the HKCU `Run` autostart
#      entry, so its own cwd really is C:\WINDOWS\system32 - read out of its PEB
#      while the user's release build was running.
#   2. `Surface.zig` deliberately refused to forward the surface's resolved
#      `working-directory` to a remote agent - a rule written for CROSS-MACHINE
#      agents, where a local path may not exist on the remote OS - and applied it
#      to the LOCAL agent too. So an agent-backed OPEN carried NO cwd and the
#      child was spawned wherever the agent happened to be sitting.
#
#      With session-persistence OFF the same window used the exec backend, which
#      chdirs into the resolved working-directory. So the SAME app with the SAME
#      config opened in two different directories depending on a setting that has
#      nothing to do with directories. That invariant is what this script pins
#      down: persistence must not move a pane.
#
# NOTE on why the chord is driven for real in section D: `ghoztty +new-window`
# ALWAYS inserts `--working-directory=<caller's cwd>` when the flag is absent
# (src/cli/new_window.zig), by design - a CLI-opened window belongs where you
# typed. So the CLI can NOT reproduce the user's report, which is about ctrl+n
# inside the GUI. Only the real keybind exercises the defect.
#
# Sections:
#   A  precondition + the defect's oracle. The agent's own cwd IS the launcher's
#      (asserted by reading its PEB, so nothing here can pass vacuously), and the
#      startup window - which nobody passes a directory to - is in HOME, not in
#      the launcher's directory. Also checks the config template got written.
#   B  persistence OFF lands in the SAME place as persistence ON (the invariant).
#   C  `working-directory` in the config file is honored, persistence ON and OFF.
#      This is the escape hatch the user did not have.
#   D  the real ctrl+n: a new window inherits the focused pane's directory
#      (`window-inherit-working-directory`), which the agent path also discarded,
#      and falls back to HOME - never to the agent's cwd.
#   E  a zero-byte config self-heals into the template. That is what the user's
#      box had: the template writer never flushed, and an empty file still
#      counted as "a config exists", so it was never retried and there was
#      nowhere to discover `working-directory` in the first place.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out (never
# the user's real release instance, which uses a different agent lineage, state
# dir, and IPC pipe).
#
#   powershell -NoProfile -File test\win32\new-window-cwd.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-new-window-cwd-$PID"

# The directory the app is LAUNCHED from. It must be one nothing would ever pick
# on purpose, so a leak is visible instead of accidentally correct - and it is
# the user's actual reported directory.
$launcherDir = 'C:\Windows\System32'
# What Config.finalize resolves `working-directory` to on Windows for a GUI
# launch: HOMEDRIVE + HOMEPATH (src/os/homedir.zig homeWindows).
$homeDir = "$env:HOMEDRIVE$env:HOMEPATH"
# The directory a config file / an inheriting pane points at.
$workDir = Join-Path $root 'workdir'

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Norm($p) {
    if ($null -eq $p) { return '' }
    return ($p.Trim().TrimEnd('\').ToLowerInvariant())
}

# ---- native helpers ---------------------------------------------------------
# Two things this script cannot do from PowerShell alone:
#   * read ANOTHER process's current directory (no supported API; the whole
#     premise here is that the AGENT's cwd is the trap, so it is read out of
#     the PEB rather than assumed), and
#   * press a real ctrl+n (the CLI cannot reproduce the reported defect).
$nativeSrc = @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public static class T144 {
    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr info, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    static byte[] Read(IntPtr h, IntPtr addr, int len) {
        byte[] b = new byte[len];
        IntPtr got;
        if (!ReadProcessMemory(h, addr, b, (IntPtr)len, out got)) return null;
        return b;
    }

    /// The process's RTL_USER_PROCESS_PARAMETERS.CurrentDirectory.DosPath.
    public static string CurrentDirectory(int pid) {
        IntPtr h = OpenProcess(0x0410, false, pid);
        if (h == IntPtr.Zero) return "";
        try {
            IntPtr pbi = Marshal.AllocHGlobal(48);
            try {
                int ret;
                if (NtQueryInformationProcess(h, 0, pbi, 48, out ret) != 0) return "";
                IntPtr peb = Marshal.ReadIntPtr(pbi, IntPtr.Size);
                byte[] pp = Read(h, peb + 0x20, 8);
                if (pp == null) return "";
                IntPtr rtl = (IntPtr)BitConverter.ToInt64(pp, 0);
                byte[] us = Read(h, rtl + 0x38, 16);
                if (us == null) return "";
                ushort len = BitConverter.ToUInt16(us, 0);
                byte[] str = Read(h, (IntPtr)BitConverter.ToInt64(us, 8), len);
                if (str == null) return "";
                return Encoding.Unicode.GetString(str);
            } finally { Marshal.FreeHGlobal(pbi); }
        } finally { CloseHandle(h); }
    }

    // ---- window + keyboard ----
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    /// The Ghoztty top-level window of `pid` whose title contains `titlePart`
    /// (empty matches the first one found).
    public static IntPtr FindWindow(uint pid, string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) return true;
            var cls = new StringBuilder(64);
            GetClassNameW(h, cls, 64);
            if (cls.ToString() != "GhozttyWindow") return true;
            if (titlePart.Length > 0) {
                var t = new StringBuilder(512);
                GetWindowTextW(h, t, 512);
                if (t.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) < 0) return true;
            }
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }

    public static string ForegroundClass() {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return "<none>";
        var cls = new StringBuilder(64);
        GetClassNameW(fg, cls, 64);
        return cls.ToString();
    }

    // T86-hardened foreground grab, with the load-bearing already-foreground
    // guard (a SetForegroundWindow storm on a window that is ALREADY foreground
    // is what used to make these harnesses flaky).
    public static bool GrabForeground(IntPtr top) {
        ShowWindow(top, 9); // SW_RESTORE
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            Key(0x12, false); Key(0x12, true); // ALT: unblocks SetForegroundWindow
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    /// ctrl+<vk> to `top`, as real injected keystrokes. Returns "SENT" or the
    /// reason it refused - never a silent no-op, since a swallowed chord would
    /// otherwise read as "the feature is broken".
    public static string Ctrl(IntPtr top, ushort vk) {
        if (!GrabForeground(top)) return "ABORT: foreground owned by " + ForegroundClass();
        Thread.Sleep(120);
        Key(0x11, false);            // VK_CONTROL
        Thread.Sleep(25);
        Key(vk, false); Thread.Sleep(25); Key(vk, true);
        Thread.Sleep(25);
        Key(0x11, true);
        Thread.Sleep(200);
        return "SENT";
    }
}
'@
Add-Type -TypeDefinition $nativeSrc -Language CSharp -ErrorAction SilentlyContinue | Out-Null

# ---- process helpers (zig-out lineage ONLY) ---------------------------------
function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 900
}
function TestProcs($name) {
    return ,@(Get-CimInstance Win32_Process -Filter "Name='$name'" |
        Where-Object { $_.CommandLine -like '*zig-out*' })
}

function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -WorkingDirectory $launcherDir `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# ---- +list helpers ----------------------------------------------------------
function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Get-Tree($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 20
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
# The leading comma matters: PowerShell unrolls a one-element array on return,
# and a lone PSCustomObject has no usable .Count - which silently turned every
# "at least one window" assertion into a failure the first time this ran.
function Windows-Of($tree) {
    if ($null -eq $tree) { return ,@() }
    if ($null -ne $tree.data) { return ,@($tree.data.windows) }
    return ,@($tree.windows)
}
function Pane-In($tree, $target) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
function Target-NotIn($tree, $exclude) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.target -ne $exclude) { return $w.target }
    }
    return $null
}
# Every window's (target, first pane) pair, so a chord-created window can be
# found by diffing against the set that existed before.
function Window-Ids($tree) {
    $ids = @()
    foreach ($w in (Windows-Of $tree)) { $ids += $w.id }
    return ,$ids
}
function Pane-ById($tree, $id) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.id -ne $id) { continue }
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
function Wait-WindowCount($tmp, $tag, $want, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $tree = $null
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tmp $tag
        if ((Windows-Of $tree).Count -ge $want) { return $tree }
        Start-Sleep -Milliseconds 700
    }
    return $tree
}

# ---- "where is this pane REALLY?" -------------------------------------------
# +list reports the cwd the app THINKS a pane has. That is the number in the bug
# report, but it is not proof: ask the shell itself. `cd` with no argument prints
# the current directory in cmd.exe.
function Shell-Cwd($tmp, $tag, $target, $timeoutSec = 30) {
    Run-Cli "+send-keys --target=$target cd Enter" "$tmp\cd-$tag.txt" 15 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        Run-Cli "+read --name=$target --lines=40" "$tmp\read-$tag.txt" 15 | Out-Null
        $lines = @((Out-Text "$tmp\read-$tag.txt") -split "`r?`n" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '^[A-Za-z]:\\[^>]*$') { return $lines[$i] }
        }
    }
    return ''
}

# ---- one hermetic app launch ------------------------------------------------
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

# $configBody is $null for "no config file at all" (the user's state), else the
# contents to write to %LOCALAPPDATA%\ghostty\config.ghostty before launching.
function New-State($name, $configBody) {
    $tmp = Join-Path $root $name
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghostty') | Out-Null
    if ($null -ne $configBody) {
        Set-Content -Path (Join-Path $tmp 'ghostty\config.ghostty') -Value $configBody -Encoding ascii
    }
    return $tmp
}
function Launch($tmp, $persistence, $visible = $false) {
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $style = if ($visible) { 'Normal' } else { 'Minimized' }
    # Start-Process rejects an empty -ArgumentList, so the two flavors are two
    # calls rather than one call with a maybe-empty argument.
    if ($persistence) {
        Start-Process -FilePath $Exe -WindowStyle $style -WorkingDirectory $launcherDir | Out-Null
    } else {
        Start-Process -FilePath $Exe -WindowStyle $style -WorkingDirectory $launcherDir `
            -ArgumentList '--session-persistence=false' | Out-Null
    }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
New-Item -ItemType Directory -Force $workDir | Out-Null

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "HOME resolves (HOMEDRIVE+HOMEPATH)" ((Norm $homeDir) -ne '')
Assert "HOME is not the launcher directory (the test would be vacuous)" `
    ((Norm $homeDir) -ne (Norm $launcherDir))

# ============================================================================
"== A: persistence ON, no config - the startup window is in HOME, not System32"
# ============================================================================
$tmpA = New-State 'a' $null
Launch $tmpA $true
$treeA = Wait-WindowCount $tmpA 'a' 1 60
Assert "A1 the app opened its startup window" ((Windows-Of $treeA).Count -ge 1)

# The precondition, proven rather than assumed: the agent really is sitting in
# the launcher's directory. Without this, A4 could pass because the agent
# happened to be somewhere harmless.
$agents = TestProcs 'ghoztty-agent.exe'
Assert "A2 an agent is running (persistence engaged)" ($agents.Count -ge 1)
$agentCwd = if ($agents.Count -ge 1) { [T144]::CurrentDirectory($agents[0].ProcessId) } else { '' }
AssertEq "A3 the agent inherited the launcher's cwd (the trap is armed)" `
    (Norm $launcherDir) (Norm $agentCwd)

$targetA = Target-NotIn $treeA '___none___'
Assert "A4 the startup window is addressable" ($null -ne $targetA)
$paneA = Pane-In $treeA $targetA
AssertEq "A5 +list reports the startup pane in HOME" (Norm $homeDir) (Norm $paneA.working_directory)
$shellA = Shell-Cwd $tmpA 'a' $targetA 45
AssertEq "A6 the startup pane's SHELL is actually in HOME" (Norm $homeDir) (Norm $shellA)
Assert "A7 the startup pane did NOT inherit the agent's directory" `
    ((Norm $shellA) -ne (Norm $launcherDir))

# The template half of the fix rides on this launch.
$cfgA = Join-Path $tmpA 'ghostty\config.ghostty'
Assert "A8 a config template was created where none existed" (Test-Path $cfgA)
$sizeA = if (Test-Path $cfgA) { (Get-Item $cfgA).Length } else { 0 }
Assert "A9 the template is not zero bytes" ($sizeA -gt 0)
Assert "A10 the template has the documented content" `
    ((Out-Text $cfgA) -match 'configuration file for Ghostty')
Stop-TestProcs

# ============================================================================
"== B: persistence OFF lands in the SAME directory (the invariant)"
# ============================================================================
$tmpB = New-State 'b' $null
Launch $tmpB $false
$treeB = Wait-WindowCount $tmpB 'b' 1 60
Assert "B1 the app opened its startup window" ((Windows-Of $treeB).Count -ge 1)
Assert "B2 no agent is running (persistence is off)" ((TestProcs 'ghoztty-agent.exe').Count -eq 0)
$targetB = Target-NotIn $treeB '___none___'
$shellB = Shell-Cwd $tmpB 'b' $targetB 45
AssertEq "B3 the exec-backed pane is in HOME" (Norm $homeDir) (Norm $shellB)
AssertEq "B4 persistence ON and OFF agree" (Norm $shellA) (Norm $shellB)
Stop-TestProcs

# ============================================================================
"== C: config working-directory is honored, persistence ON and OFF"
# ============================================================================
Assert "C0 the configured directory is neither HOME nor the launcher's" `
    (((Norm $workDir) -ne (Norm $homeDir)) -and ((Norm $workDir) -ne (Norm $launcherDir)))
$body = "working-directory = $workDir"

$tmpC = New-State 'c' $body
Launch $tmpC $true
$treeC = Wait-WindowCount $tmpC 'c' 1 60
Assert "C1 the app opened with a config present" ((Windows-Of $treeC).Count -ge 1)
$targetC = Target-NotIn $treeC '___none___'
$shellC = Shell-Cwd $tmpC 'c' $targetC 45
AssertEq "C2 persistence ON honors the configured working-directory" (Norm $workDir) (Norm $shellC)
Stop-TestProcs

$tmpC2 = New-State 'c2' $body
Launch $tmpC2 $false
$treeC2 = Wait-WindowCount $tmpC2 'c2' 1 60
Assert "C3 the app opened with a config present (persistence off)" ((Windows-Of $treeC2).Count -ge 1)
$targetC2 = Target-NotIn $treeC2 '___none___'
$shellC2 = Shell-Cwd $tmpC2 'c2' $targetC2 45
AssertEq "C4 persistence OFF honors it too" (Norm $workDir) (Norm $shellC2)
AssertEq "C5 both backends agree on the configured directory" (Norm $shellC) (Norm $shellC2)
Assert "C6 the user's config file survived the launch (never templated over)" `
    ((Out-Text (Join-Path $tmpC2 'ghostty\config.ghostty')) -match 'working-directory')
Stop-TestProcs

# ============================================================================
"== D: the real ctrl+n inherits the focused pane's directory"
# ============================================================================
# `+new-window` cannot test this: the CLI always inserts the caller's cwd as
# --working-directory. The user's report is about the keybind, so press it.
$tmpD = New-State 'd' $null
Launch $tmpD $true $true
$treeD0 = Wait-WindowCount $tmpD 'd0' 1 60
Assert "D1 the app opened its startup window" ((Windows-Of $treeD0).Count -ge 1)

# Seed a window that is somewhere specific. The explicit flag is the documented
# CLI behavior and is only used to CREATE the pane ctrl+n will inherit from.
# The title is pinned so the chord can be aimed at THIS window: every pane here
# is `cmd.exe`, so titles are otherwise identical and "focus the right window"
# would be a coin flip.
Run-Cli "+new-window --target=proj --title=PROJWIN --working-directory=$workDir" "$tmpD\proj.txt" 40 | Out-Null
$treeD1 = Wait-WindowCount $tmpD 'd1' 2 40
Assert "D2 the seeded window opened" ($null -ne (Pane-In $treeD1 'proj'))
$shellD1 = Shell-Cwd $tmpD 'd1' 'proj' 45
AssertEq "D3 the seeded pane is where it was asked to be" (Norm $workDir) (Norm $shellD1)

$appPid = (TestProcs 'ghoztty.exe')[0].ProcessId
$before = Window-Ids $treeD1
$hwndProj = [T144]::FindWindow([uint32]$appPid, 'PROJWIN')
Assert "D4 the seeded window was found by its pinned title" ($hwndProj -ne [IntPtr]::Zero)
$sent = [T144]::Ctrl($hwndProj, 0x4E)  # 'N'
Assert "D5 ctrl+n was injected (harness positive control): $sent" ($sent -eq 'SENT')

$treeD2 = Wait-WindowCount $tmpD 'd2' 3 40
Assert "D6 ctrl+n created a window (if not, the chord never landed)" `
    ((Windows-Of $treeD2).Count -ge 3)
$newId = $null
foreach ($id in (Window-Ids $treeD2)) { if ($before -notcontains $id) { $newId = $id } }
Assert "D7 the new window is identifiable" ($null -ne $newId)
$paneD = Pane-ById $treeD2 $newId
Assert "D8 the new window has a pane" ($null -ne $paneD)
$cwdD = if ($null -ne $paneD) { $paneD.working_directory } else { '' }
Assert "D9 ctrl+n did NOT land in the agent's directory" ((Norm $cwdD) -ne (Norm $launcherDir))
AssertEq "D10 ctrl+n inherited the focused pane's directory" (Norm $workDir) (Norm $cwdD)
if ($null -ne $paneD) {
    $shellD2 = Shell-Cwd $tmpD 'd2' $paneD.name 45
    AssertEq "D11 the new pane's SHELL agrees with what +list reported" (Norm $cwdD) (Norm $shellD2)
}
Stop-TestProcs

# ============================================================================
"== E: a zero-byte config self-heals into the template"
# ============================================================================
$tmpE = New-State 'e' $null
$cfgE = Join-Path $tmpE 'ghostty\config.ghostty'
New-Item -ItemType File -Force $cfgE | Out-Null
AssertEq "E1 the config file starts at zero bytes" 0 ((Get-Item $cfgE).Length)
Launch $tmpE $true
Wait-WindowCount $tmpE 'e' 1 60 | Out-Null
Assert "E2 the zero-byte config was replaced by the template" ((Get-Item $cfgE).Length -gt 0)
Assert "E3 the template content is the documented one" `
    ((Out-Text $cfgE) -match 'ghostty.org/docs/config')
Stop-TestProcs

# ---- teardown --------------------------------------------------------------
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) {
    Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
} else {
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
}
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }
