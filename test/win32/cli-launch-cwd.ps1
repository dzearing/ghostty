# Launching Ghoztty FROM A SHELL opens the window where you were standing (T506).
#
# On macOS and Linux, `ghostty` typed in a project directory opens there:
# `Config.probableCliEnvironment` says "this looks like a command line", and the
# `working-directory` default resolves to `inherit`. On Windows that function
# returned a hardcoded `false` - upstream calls Windows "not a real supported
# target" - so EVERY Windows launch resolved to `home`, and a user who cd'd into
# a project and typed `ghoztty` landed in `C:\Users\<them>`.
#
# The detection is the interesting part, and this script is what pins it down.
# There are three ways a Windows launch can be a command line, and one way it
# must NOT be:
#
#   A  `ghoztty.com` - the console-subsystem twin PATHEXT resolves a bare
#      `ghoztty` to (T245). It respawns `ghoztty.exe` DETACHED, so the child has
#      no console and a parent that is already exiting; nothing about it is
#      probeable. The twin therefore TELLS it, with GHOZTTY_CLI_LAUNCH=1 on the
#      child's environment. This is the launch a human actually performs.
#   B  the negative control, and the reason the rule is shaped the way it is: a
#      `Start-Process`-style launch gets a console CREATED FOR IT (or none at
#      all), so the console holds exactly one process. That must stay non-CLI -
#      every GUI launch in this suite is that shape, and `new-window-cwd.ps1`
#      A5/A6 assert the startup window is in HOME.
#   C  a console-subsystem build (every Debug build) launched from a shell
#      INHERITS the shell's console, so the console holds two or more processes.
#      That is a command line.
#   D  a GUI-subsystem build (every release build) never inherits a console at
#      all, so it asks whether its PARENT owns one - `AttachConsole
#      (ATTACH_PARENT_PROCESS)`, immediately released. Arm D arms that leg with
#      a DETACHED_PROCESS spawn out of this script's own console-owning host,
#      which is the only way to reach it from a Debug build.
#
#   E  the marker does not leak. It is consumed and cleared on first read, so no
#      pane's shell - and nothing the app or the local agent spawns - inherits an
#      internal variable that would make it read as CLI in turn.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: a private
# IPC endpoint (T441) and a per-run $env:LOCALAPPDATA, so it can neither read the
# user's real config nor drive the terminal they are sitting in. It only ever
# kills ghoztty processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\cli-launch-cwd.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Com = 'D:\git\ghoztty\zig-out\bin\ghoztty.com'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0

$root = Join-Path $env:TEMP "ghoztty-cli-launch-cwd-$PID"
$workDir = Join-Path $root 'workdir'
$homeDir = "$env:HOMEDRIVE$env:HOMEPATH"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Norm($p) {
    if ($null -eq $p -or $p -eq '') { return '' }
    return ($p -replace '/', '\').TrimEnd('\').ToLowerInvariant()
}

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')

# ---- process helpers (zig-out lineage ONLY) ---------------------------------
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
}

# Run a CLI verb through the .com twin. persistence: a CLI verb opens no window,
# so there is no manifest for it to restore from.
function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Com`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}

function First-Terminal($tag) {
    $out = Join-Path $root "list-$tag.json"
    if ($null -eq (Run-Cli '+list --json' $out)) { return $null }
    if (-not (Test-Path $out)) { return $null }
    $tree = $null
    try { $tree = Get-Content $out -Raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $tree) { return $null }
    $wins = if ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    foreach ($w in $wins) {
        foreach ($t in @($w.tabs)) {
            $n = $t.splits
            while ($null -ne $n -and $n.type -eq 'split') { $n = $n.left }
            if ($null -ne $n -and $n.type -eq 'leaf' -and $n.terminal.type -ne 'viewer') {
                return $n.terminal
            }
        }
    }
    return $null
}

# Poll rather than sleep a fixed amount: a cold Debug start on a busy box is slow
# and a fixed wait is either wasteful or flaky.
function Wait-Terminal($tag, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $t = First-Terminal $tag
        if ($null -ne $t -and $null -ne $t.working_directory) { return $t }
        Start-Sleep -Milliseconds 700
    }
    return $null
}

# ---- DETACHED_PROCESS spawn (arm D) -----------------------------------------
# The one launch shape this suite has no helper for, and the only way a Debug
# build reaches the parent-console leg: DETACHED_PROCESS leaves the child with no
# console of its own, while THIS process - which stays alive for the whole arm -
# keeps the console its parent gave it.
$detachSrc = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class T506Spawn {
    [StructLayout(LayoutKind.Sequential)] public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint GetConsoleProcessList(uint[] buf, uint count);

    public const uint DETACHED_PROCESS = 0x00000008;

    // How many processes share THIS process's console. 0 means we have none, in
    // which case arm D cannot be armed at all and says so.
    public static uint ConsoleProcs() {
        uint[] buf = new uint[8];
        return GetConsoleProcessList(buf, (uint)buf.Length);
    }

    public static int StartDetached(string exe, string args, string cwd) {
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        var cmd = new StringBuilder("\"" + exe + "\" " + (args == null ? "" : args));
        if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, DETACHED_PROCESS,
                IntPtr.Zero, cwd, ref si, out pi)) return 0;
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return pi.dwProcessId;
    }
}
'@
Add-Type -TypeDefinition $detachSrc -Language CSharp -ErrorAction SilentlyContinue | Out-Null

# ============================================================================
"== setup"
# ============================================================================
Assert "ghoztty.exe exists in zig-out" (Test-Path $Exe)
Assert "ghoztty.com exists in zig-out (the CLI entry point, T245)" (Test-Path $Com)
Assert "HOME resolves" ((Norm $homeDir) -ne '')
Assert "HOME is not the work directory (the test would be vacuous)" `
    ((Norm $homeDir) -ne (Norm $workDir))

New-Item -ItemType Directory -Force $workDir | Out-Null

# A private endpoint AND a private LOCALAPPDATA. The second is not optional
# here: the user's real config may set `working-directory`, which would answer
# every arm below before the default ever ran.
[void](Set-GhozttyTestIsolation -Tag 'clilaunch')
$env:LOCALAPPDATA = $root
Stop-TestProcs
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: ghoztty.com from a shell in the work directory opens THERE"
# ============================================================================
# The launch a human performs: PATHEXT resolves a bare `ghoztty` to the twin.
# cmd waits for it (console subsystem), and the twin returns as soon as it has
# respawned the detached GUI - so this call completing is the launch, not a
# timeout.
$a = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
    -ArgumentList "/c `"cd /d `"$workDir`" && `"$Com`" --session-persistence=false`""
$null = $a.Handle
[void]$a.WaitForExit(30000)
$paneA = Wait-Terminal 'a'
Assert "A1 the twin launched a GUI with a terminal pane" ($null -ne $paneA)
Assert-GhozttyIsolated -Exe $Exe
AssertEq "A2 the startup pane is in the directory the shell was standing in" `
    (Norm $workDir) (Norm $paneA.working_directory)
Assert "A3 the startup pane is NOT in home (the pre-T506 answer)" `
    ((Norm $paneA.working_directory) -ne (Norm $homeDir))

# ---- E: the marker does not leak into the pane -----------------------------
# Typed for real, and the answer read back - which also proves the pane is a
# live shell rather than a picture of one.
$paneId = $paneA.id
Assert "E0 the startup pane is addressable by id" ($null -ne $paneId -and $paneId -ne '')
if ($null -ne $paneId -and $paneId -ne '') {
    $null = Run-Cli "+send-keys --target=$paneId `"echo T506MARK=[%GHOZTTY_CLI_LAUNCH%]`" Enter" `
        (Join-Path $root 'send.txt')
    $seen = ''
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $ro = Join-Path $root 'read.txt'
        if ($null -ne (Run-Cli "+read --name=$paneId --lines=40" $ro)) {
            $seen = if (Test-Path $ro) { Get-Content $ro -Raw } else { '' }
            if ($seen -match 'T506MARK=\[') { break }
        }
        Start-Sleep -Milliseconds 700
    }
    Assert "E1 the pane answered (it is a live shell, not a restored picture)" `
        ($seen -match 'T506MARK=\[')
    Assert "E2 GHOZTTY_CLI_LAUNCH was cleared before the shell was spawned" `
        ($seen -notmatch 'T506MARK=\[1\]')
}
Stop-TestProcs

# ============================================================================
"== B: a Start-Process launch still opens in HOME (the negative control)"
# ============================================================================
# A console created FOR the child (or none at all) holds one process. Every GUI
# launch in this suite is this shape, and new-window-cwd.ps1 A5/A6 depend on it
# staying non-CLI.
$b = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru -WorkingDirectory $workDir `
    -ArgumentList '--session-persistence=false'
$null = $b.Handle
$paneB = Wait-Terminal 'b'
Assert "B1 the app launched a terminal pane" ($null -ne $paneB)
AssertEq "B2 the startup pane is in HOME, not the launcher's directory" `
    (Norm $homeDir) (Norm $paneB.working_directory)
Stop-TestProcs

# ============================================================================
"== C: launched INTO a shell's console, it opens in that shell's directory"
# ============================================================================
# A Debug build is console-subsystem, so cmd hands it its own console and stays
# attached while it runs. Two processes in one console is the signal.
$c = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
    -ArgumentList "/c `"cd /d `"$workDir`" && `"$Exe`" --session-persistence=false`""
$null = $c.Handle
$paneC = Wait-Terminal 'c'
Assert "C1 the app launched a terminal pane" ($null -ne $paneC)
AssertEq "C2 the startup pane is in the shell's directory" `
    (Norm $workDir) (Norm $paneC.working_directory)
Stop-TestProcs
Stop-Process -Id $c.Id -Force -ErrorAction SilentlyContinue

# ============================================================================
"== D: no console of its own, but a console-owning parent (the release leg)"
# ============================================================================
$consoleProcs = 0
try { $consoleProcs = [T506Spawn]::ConsoleProcs() } catch { $consoleProcs = 0 }
if ($consoleProcs -lt 1) {
    "SKIP  D: this host has no console, so the parent-console leg cannot be armed"
    $script:skipped++
} else {
    $pidD = [T506Spawn]::StartDetached($Exe, '--session-persistence=false', $workDir)
    Assert "D1 the detached launch started" ($pidD -ne 0)
    $paneD = Wait-Terminal 'd'
    Assert "D2 the app launched a terminal pane" ($null -ne $paneD)
    AssertEq "D3 a parent that owns a console makes this a command line" `
        (Norm $workDir) (Norm $paneD.working_directory)
    Stop-TestProcs
}

# ============================================================================
Stop-TestProcs
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) {
    "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
    exit 0
} else {
    "$($script:failures) FAILURE(S)$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
    exit 1
}
