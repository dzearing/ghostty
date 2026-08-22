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
# T217: the GUI half runs on a BACKGROUND Win32 desktop
# (test/win32/lib/TestDesktop.ps1), so it never takes the user's foreground -
# asserted at the end, not assumed. Notes on the mechanics:
#
#   * Every app launch goes through Start-OnTestDesktop, which passes the
#     launcher directory as the child's cwd exactly as -WorkingDirectory did -
#     which matters here more than anywhere, since System32 IS the trap.
#   * Section D no longer hunts for the window by its pinned title. `+list
#     --json`'s window `id` IS the hwnd (IpcHandlers.zig formats
#     @intFromPtr(hwnd)), so the seeded window is addressed by its NAME and the
#     hwnd is confirmed with Get-TestWindowClass. The --title=PROJWIN pin stays
#     as documentation of which window is which in a +list dump.
#   * A posted chord must be aimed at the SURFACE: GhozttyWindow hands
#     WM_KEYDOWN to DefWindowProc and only forwards FOCUS to the active pane.
#   * The PEB reader below stays - reading another process's cwd is not a GUI
#     mechanism and the test desktop changes nothing about it.
#
#   powershell -NoProfile -File test\win32\new-window-cwd.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
# Isolate the IPC endpoint (inherited through CreateProcessW) so a stray
# instance answering the shared pipe cannot serve this run's +list.
$env:GHOZTTY_PIPE_SUFFIX = "-nwcwdtest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
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

# Write-Host, not the pipeline: these are called from inside functions that
# RETURN something (Launch), and a pipeline-emitted line would be part of the
# return value.
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name" } else { Write-Host "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name" }
    else { Write-Host "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Norm($p) {
    if ($null -eq $p) { return '' }
    return ($p.Trim().TrimEnd('\').ToLowerInvariant())
}

# ---- native helper ----------------------------------------------------------
# One thing this script cannot do from PowerShell alone: read ANOTHER process's
# current directory. There is no supported API, and the whole premise here is
# that the AGENT's cwd is the trap - so it is read out of the PEB rather than
# assumed. (Pressing ctrl+n used to live here too; that is the harness's job
# now.)
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
}
'@
Add-Type -TypeDefinition $nativeSrc -Language CSharp -ErrorAction SilentlyContinue | Out-Null

# ---- process helpers (zig-out lineage ONLY) ---------------------------------
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
}
function TestProcs($name) {
    return ,@(Get-CimInstance Win32_Process -Filter "Name='$name'" |
        Where-Object { $_.CommandLine -like '*zig-out*' })
}

function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -WorkingDirectory $launcherDir `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
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
# A window's `id`, which IS its hwnd (IpcHandlers.zig formats @intFromPtr), so a
# named window can be addressed directly instead of guessed at by z-order or
# by title text.
function Window-IdOf($tree, $target) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.target -eq $target) { return $w.id }
    }
    return $null
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
# Poll +list until the named window's first pane reports the wanted
# working_directory (T185: the live value can lag a `cd` by one poll).
# Returns the last value seen either way, so the assertion message names it.
function Wait-PaneCwd($tmp, $tag, $target, $want, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = ''
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tmp "$tag-$i"
        $i++
        $pane = Pane-In $tree $target
        if ($null -ne $pane) {
            $last = $pane.working_directory
            if ((Norm $last) -eq (Norm $want)) { return $last }
        }
        Start-Sleep -Milliseconds 700
    }
    return $last
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
# The launcher directory is passed as the child's cwd, which is the whole point:
# it is inherited by the app and (with persistence on) by the agent it spawns.
function Launch($tmp, $persistence) {
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $extra = if ($persistence) { @() } else { @('--session-persistence=false') }
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $extra -WorkingDirectory $launcherDir
    Start-Sleep -Milliseconds 500
    Assert "launch $($app.Pid) is NOT enumerable on the interactive desktop" `
        (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    return $app
}

Stop-TestProcs
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
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
$appA = Launch $tmpA $true
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
$appB = Launch $tmpB $false
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
$appC = Launch $tmpC $true
$treeC = Wait-WindowCount $tmpC 'c' 1 60
Assert "C1 the app opened with a config present" ((Windows-Of $treeC).Count -ge 1)
$targetC = Target-NotIn $treeC '___none___'
$shellC = Shell-Cwd $tmpC 'c' $targetC 45
AssertEq "C2 persistence ON honors the configured working-directory" (Norm $workDir) (Norm $shellC)
Stop-TestProcs

$tmpC2 = New-State 'c2' $body
$appC2 = Launch $tmpC2 $false
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
$appD = Launch $tmpD $true
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

$before = Window-Ids $treeD1
# `+list --json`'s window id IS the hwnd, so the seeded window is addressed by
# NAME - no title hunting, no z-order guessing about which cmd.exe is which.
$idProj = Window-IdOf $treeD1 'proj'
Assert "D4 the seeded window is addressable by name in +list" ($null -ne $idProj)
$hwndProj = if ($null -ne $idProj) { [IntPtr][int64]$idProj } else { [IntPtr]::Zero }
Assert "D4b the +list window id really is a GhozttyWindow" `
    ((Get-TestWindowClass -Window $hwndProj) -eq 'GhozttyWindow')

# The chord must go to the SURFACE: the window hands WM_KEYDOWN to
# DefWindowProc and only forwards FOCUS on. Focus first, then ask the app which
# pane it considers active - that is the one whose directory ctrl+n inherits.
Focus-TestWindow -Window $hwndProj | Out-Null
Start-Sleep -Milliseconds 300
$surfD = [IntPtr](Get-TestFocusedWindow -Window $hwndProj)
Assert "D4c the window forwarded focus to a terminal surface" `
    (($surfD -ne [IntPtr]::Zero) -and ((Get-TestWindowClass -Window $surfD) -eq 'GhozttyTerminal'))
$sent = Send-TestKeys -Window $hwndProj -Target $surfD -Modifiers ctrl -Key N
Assert "D5 ctrl+n was injected (harness positive control)" $sent

$treeD2 = Wait-WindowCount $tmpD 'd2' 3 40
# -NegativeControl inverts D10, the load-bearing claim (a new window inherits
# the focused pane's directory), so a passing run proves the assertion
# discriminates rather than being true of any directory.
Assert "D6 ctrl+n created a window (if not, the chord never landed)" `
    ((Windows-Of $treeD2).Count -ge 3)
$newId = $null
foreach ($id in (Window-Ids $treeD2)) { if ($before -notcontains $id) { $newId = $id } }
Assert "D7 the new window is identifiable" ($null -ne $newId)
$paneD = Pane-ById $treeD2 $newId
Assert "D8 the new window has a pane" ($null -ne $paneD)
$cwdD = if ($null -ne $paneD) { $paneD.working_directory } else { '' }
Assert "D9 ctrl+n did NOT land in the agent's directory" ((Norm $cwdD) -ne (Norm $launcherDir))
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting ctrl+n lands in the LAUNCHER dir - this run MUST fail'
    AssertEq "D10 ctrl+n inherited the focused pane's directory (inverted)" (Norm $launcherDir) (Norm $cwdD)
} else {
    AssertEq "D10 ctrl+n inherited the focused pane's directory" (Norm $workDir) (Norm $cwdD)
}
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
$appE = Launch $tmpE $true
Wait-WindowCount $tmpE 'e' 1 60 | Out-Null
Assert "E2 the zero-byte config was replaced by the template" ((Get-Item $cfgE).Length -gt 0)
Assert "E3 the template content is the documented one" `
    ((Out-Text $cfgE) -match 'ghostty.org/docs/config')
Stop-TestProcs

# ============================================================================
"== F: +list and ctrl+n track a cmd pane's LIVE directory (T185)"
# ============================================================================
# cmd.exe never reports OSC 7 (it has no prompt hook), so the app's cached pwd
# used to stay frozen at the pane's STARTING directory forever - `+list`
# answered with where the pane began, and ctrl+n reopened there, no matter
# where the user had `cd`ed. The fix reads the shell PROCESS's real cwd (PEB)
# whenever no OSC 7 was ever seen. cd somewhere else; both consumers follow.
$workDir2 = Join-Path $root 'workdir2'
New-Item -ItemType Directory -Force $workDir2 | Out-Null
Assert "F0 the second directory differs from the first (non-vacuous)" `
    ((Norm $workDir2) -ne (Norm $workDir))
$tmpF = New-State 'f' $null
$appF = Launch $tmpF $true
$treeF0 = Wait-WindowCount $tmpF 'f0' 1 60
Assert "F1 the app opened its startup window" ((Windows-Of $treeF0).Count -ge 1)

Run-Cli "+new-window --target=livewin --title=LIVEWIN --working-directory=$workDir" "$tmpF\livewin.txt" 40 | Out-Null
$treeF1 = Wait-WindowCount $tmpF 'f1' 2 40
Assert "F2 the seeded window opened" ($null -ne (Pane-In $treeF1 'livewin'))
$cwdF1 = Wait-PaneCwd $tmpF 'f1b' 'livewin' $workDir 30
AssertEq "F3 +list reports the starting directory before any cd" (Norm $workDir) (Norm $cwdF1)

# The user moves. No OSC 7 will ever announce this - only the process knows.
Run-Cli "+send-keys --target=livewin `"cd /d $workDir2`" Enter" "$tmpF\cd-f.txt" 15 | Out-Null
$cwdF2 = Wait-PaneCwd $tmpF 'f2' 'livewin' $workDir2 30
AssertEq "F4 +list follows the cd (live process cwd, not the frozen seed)" `
    (Norm $workDir2) (Norm $cwdF2)

# And ctrl+n from that pane lands where the user IS, not where the pane began.
$treeF2 = Get-Tree $tmpF 'f3'
$beforeF = Window-Ids $treeF2
$idLive = Window-IdOf $treeF2 'livewin'
Assert "F5 the live window is addressable by name in +list" ($null -ne $idLive)
$hwndLive = if ($null -ne $idLive) { [IntPtr][int64]$idLive } else { [IntPtr]::Zero }
Focus-TestWindow -Window $hwndLive | Out-Null
Start-Sleep -Milliseconds 300
$surfF = [IntPtr](Get-TestFocusedWindow -Window $hwndLive)
Assert "F6 the window forwarded focus to a terminal surface" `
    (($surfF -ne [IntPtr]::Zero) -and ((Get-TestWindowClass -Window $surfF) -eq 'GhozttyTerminal'))
$sentF = Send-TestKeys -Window $hwndLive -Target $surfF -Modifiers ctrl -Key N
Assert "F7 ctrl+n was injected (harness positive control)" $sentF

$treeF4 = Wait-WindowCount $tmpF 'f4' 3 40
Assert "F8 ctrl+n created a window" ((Windows-Of $treeF4).Count -ge 3)
$newIdF = $null
foreach ($id in (Window-Ids $treeF4)) { if ($beforeF -notcontains $id) { $newIdF = $id } }
Assert "F9 the new window is identifiable" ($null -ne $newIdF)
$paneF = Pane-ById $treeF4 $newIdF
Assert "F10 the new window has a pane" ($null -ne $paneF)
$cwdF3 = if ($null -ne $paneF) { $paneF.working_directory } else { '' }
AssertEq "F11 ctrl+n inherited the LIVE directory, not the starting one" `
    (Norm $workDir2) (Norm $cwdF3)
if ($null -ne $paneF) {
    $shellF = Shell-Cwd $tmpF 'f5' $paneF.name 45
    AssertEq "F12 the new pane's SHELL agrees with what +list reported" `
        (Norm $workDir2) (Norm $shellF)
}
Stop-TestProcs

# ---- teardown --------------------------------------------------------------
Remove-TestDesktop
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) {
    Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
} else {
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
}
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run by
    # now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

""
if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }
