# Freeze watchdog for the installed Windows release Ghoztty (T48 safeguard).
#
# Polls release ghoztty.exe processes (install dir only; debug zig-out
# instances are ignored). If a process's UI stops responding for
# HangSeconds consecutive seconds, the watchdog:
#   1. writes a full minidump to DumpDir (evidence for T48),
#   2. kills the hung process,
#   3. relaunches a window that resumes the most recent Claude session
#      (same flow as upgrade-ghoztty-windows.ps1).
#
# Run detached so it survives the terminal it was started from:
#
#   Start-Process powershell -WindowStyle Hidden -ArgumentList `
#     '-NoProfile','-ExecutionPolicy','Bypass','-File',
#     'D:\git\ghoztty\scripts\watchdog-ghoztty-windows.ps1'
#
# Every action is appended to %TEMP%\ghoztty-watchdog.log.
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Ghoztty",
    [string]$DumpDir = 'D:\git\ghoztty\.dumps',
    [string]$WorkingDirectory = 'D:\git\ghoztty',
    [string]$ResumeCommand = 'claude --dangerously-skip-permissions --continue',
    [int]$PollSeconds = 3,
    [int]$HangSeconds = 15,
    [int]$MaxDumps = 4,        # newest hang dumps kept; older ones deleted
    [switch]$NoResume,
    [switch]$NoRestart         # dump only; leave the hung process alone
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'ghoztty-watchdog.log'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content $log }

# Single instance: bail if another watchdog is already running.
$mutex = New-Object System.Threading.Mutex($false, 'Global\GhozttyFreezeWatchdog')
if (-not $mutex.WaitOne(0)) { Log 'another watchdog instance is running; exiting'; exit 0 }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GhozttyDump {
    [DllImport("Dbghelp.dll", SetLastError = true)]
    public static extern bool MiniDumpWriteDump(
        IntPtr hProcess, uint processId, IntPtr hFile, int dumpType,
        IntPtr exceptionParam, IntPtr userStreamParam, IntPtr callbackParam);
}
"@

# MiniDumpWithFullMemory | WithHandleData | WithUnloadedModules | WithThreadInfo
$DumpType = 0x2 -bor 0x4 -bor 0x20 -bor 0x1000

function Write-HangDump($proc) {
    New-Item -ItemType Directory -Force $DumpDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $DumpDir "ghoztty-$($proc.Id)-hang-$stamp.dmp"
    $file = [System.IO.File]::Create($path)
    try {
        $ok = [GhozttyDump]::MiniDumpWriteDump(
            $proc.Handle, [uint32]$proc.Id, $file.SafeFileHandle.DangerousGetHandle(),
            $DumpType, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    } finally { $file.Close() }
    if ($ok) {
        Log "dump written: $path ($([int]((Get-Item $path).Length / 1MB)) MB)"
        # Rotate: keep the newest $MaxDumps hang dumps (manual deadlock dumps untouched).
        Get-ChildItem $DumpDir -Filter 'ghoztty-*-hang-*.dmp' |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $MaxDumps |
            ForEach-Object { Log "rotating out old dump: $($_.Name)"; Remove-Item $_.FullName -Force }
        return $path
    }
    Log "MiniDumpWriteDump FAILED for pid $($proc.Id) (err $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    return $null
}

Log "=== watchdog start (poll=${PollSeconds}s, hang=${HangSeconds}s, install=$InstallDir)"
$strikes = @{}   # pid -> consecutive non-responding polls
$needed = [Math]::Max(1, [Math]::Ceiling($HangSeconds / $PollSeconds))

while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $procs = @(Get-Process ghoztty -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$InstallDir*" })

    # Forget exited pids.
    foreach ($id in @($strikes.Keys)) {
        if ($procs.Id -notcontains $id) { $strikes.Remove($id) }
    }

    foreach ($p in $procs) {
        $p.Refresh()
        # Responding uses SendMessageTimeout on the main window; a process
        # with no window yet reports true, which is what we want.
        if ($p.Responding) { $strikes[$p.Id] = 0; continue }

        $strikes[$p.Id] = 1 + $(if ($strikes.ContainsKey($p.Id)) { $strikes[$p.Id] } else { 0 })
        Log "pid $($p.Id) not responding (strike $($strikes[$p.Id])/$needed)"
        if ($strikes[$p.Id] -lt $needed) { continue }

        Log "pid $($p.Id) hung for >= ${HangSeconds}s; capturing dump"
        Write-HangDump $p | Out-Null
        if ($NoRestart) { $strikes[$p.Id] = 0; continue }

        Log "killing hung pid $($p.Id)"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $strikes.Remove($p.Id)
        Start-Sleep -Seconds 2

        if (-not $NoResume) {
            # Scrub Claude-harness env vars so the auto-launched GUI (and
            # thus every future pane shell) doesn't inherit them — a
            # watchdog started from a Claude tool shell carries NO_COLOR=1
            # etc., which turned all Claude panes black-and-white (see
            # upgrade-ghoztty-windows.ps1, same scrub).
            $scrub = @('NO_COLOR', 'FORCE_COLOR', 'GIT_TERMINAL_PROMPT', 'CLAUDECODE', 'CLAUDE_PID', 'AI_AGENT') +
                @(Get-ChildItem env: | Where-Object { $_.Name -like 'CLAUDE_CODE_*' } | ForEach-Object Name)
            foreach ($v in $scrub) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
            Log "relaunch env scrubbed: $($scrub -join ', ')"

            $exe = Join-Path $InstallDir 'ghoztty.exe'
            & $exe +new-window --target=main "--working-directory=$WorkingDirectory" "--command=$ResumeCommand" 2>&1 |
                ForEach-Object { Log "relaunch: $_" }
            Log "relaunched with resume: $ResumeCommand"
        }
    }
}
