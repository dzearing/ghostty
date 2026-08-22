# T426 acceptance: the LOCAL AGENT is spawned OUTSIDE the app's job object.
#
# The defect: `LocalAgent.spawnAgent` used a plain CreateProcessW with
# DETACHED_PROCESS, and DETACHED_PROCESS does not leave a job. A child joins its
# parent's job by default, this box's jobs are kill-on-close, and a job teardown
# kills every member at once - the mechanism T524 measured when four relaunch
# guards died with the app before executing one instruction. A daemon that owns
# every persistent PTY, and whose entire reason to exist is outliving the app,
# must not be a member of anything that can kill it on the app's account.
#
# Measured by OUTCOME, not by log scraping: the agent process's own job
# membership, probed with IsProcessInJob against the exact job handle the app
# was jailed in, and then its survival of that job's teardown.
#
#   A: premise - the app under test is up and jailed in a kill-on-close job.
#   B: the agent it then spawns lands OUTSIDE that job.
#   C: ... and SURVIVES the job's teardown (TerminateJobObject), which is the
#      thing the membership test is a proxy for.
#   D: negative control - a process the app spawns WITHOUT the escape (this
#      script's own child, spawned plainly from the jailed app's job) IS in the
#      job and DOES die with it. Without this arm, a job that never kills
#      anything would pass B and C.
#
# Hermetic: a per-run $env:LOCALAPPDATA and a private IPC pipe suffix, and it
# only ever touches ghoztty processes launched from the -Exe under test.
#
#   powershell -NoProfile -File test\win32\agent-job-escape.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-Host "FAIL: exe not found: $Exe" -ForegroundColor Red
    exit 1
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$agentExe = Join-Path (Split-Path -Parent $Exe) 'ghoztty-agent.exe'
if (-not (Test-Path $agentExe)) {
    Write-Host "FAIL: agent not found: $agentExe" -ForegroundColor Red
    exit 1
}

# Only processes started from the exe under test - never the user's installed
# release, which runs from %LOCALAPPDATA%\Programs\Ghoztty and owns their live
# sessions.
function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgents {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $agentExe })
}
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy. It matches the same two exact images the Get-Test* enumerations above
    # do - $Exe and its required sibling agent.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 800)
}

function Wait-NewAgent($excludePids, $timeoutSec = 40) {
    $excludePids = @($excludePids | ForEach-Object { [int]$_ })
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $fresh = @((Get-TestAgents) | Where-Object { $excludePids -notcontains [int]$_.ProcessId })
        if ($fresh.Count -gt 0) { return [int]$fresh[0].ProcessId }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

$jobSig = @'
using System;
using System.Runtime.InteropServices;
public static class T426Job {
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit;
    public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
  }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attrs, string name);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int len);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
}
'@
Add-Type -TypeDefinition $jobSig -ErrorAction SilentlyContinue

# $true / $false / $null when the process is gone or unopenable.
function Test-InJob($procId, $job) {
    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        $inJob = $false
        if (-not [T426Job]::IsProcessInJob($p.Handle, $job, [ref]$inJob)) { return $null }
        return $inJob
    } catch { return $null }
}

$root = Join-Path $env:TEMP "ghoztty-agent-job-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSocket = $env:GHOZTTY_IPC_SOCKET
# A private endpoint so nothing here can reach the user's terminal. The suffix
# OUTRANKS the baked GHOZTTY_IPC_SOCKET inherited from the pane this was started
# in (docs/claude/cli.md, Instance addressability) - clear the baked value too.
$env:GHOZTTY_PIPE_SUFFIX = "-t426-$PID"
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = $root

$job = [IntPtr]::Zero
try {
    Stop-TestProcs

    # ========================================================================
    Say "== A: the app under test, jailed in a kill-on-close job"
    # ========================================================================
    $job = [T426Job]::CreateJobObject([IntPtr]::Zero, $null)
    $jobInfo = New-Object T426Job+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    # KILL_ON_JOB_CLOSE (0x2000) + BREAKAWAY_OK (0x800): the measured production
    # shape (T524) - members die on teardown, breakaway is permitted.
    $jobInfo.BasicLimitInformation.LimitFlags = 0x2800
    $jobLen = [System.Runtime.InteropServices.Marshal]::SizeOf($jobInfo)
    $jobSet = [T426Job]::SetInformationJobObject($job, 9, [ref]$jobInfo, $jobLen)
    Assert "A0 premise: a kill-on-close job exists" ($job -ne [IntPtr]::Zero -and $jobSet)

    # persistence: on (default) - the pane shell must be the AGENT's child for the job-escape assertion to mean anything.
    $appProc = Start-Process -FilePath $Exe -ArgumentList @('--title=t426a') -PassThru
    $appPid = $appProc.Id
    $ready = $false
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) { break }
        $out = (& $Exe +list 2>$null) | Out-String
        if ($out -match '\S') { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert "A1 premise: the app under test is up and answering IPC" $ready

    $jailed = $false
    if ($ready) {
        [T426Job]::AssignProcessToJobObject($job, $appProc.Handle) | Out-Null
        [T426Job]::IsProcessInJob($appProc.Handle, $job, [ref]$jailed) | Out-Null
    }
    Assert "A2 premise: the app is jailed in the kill-on-close job" $jailed

    # No agent may be running when the measurement starts. The app spawns one at
    # startup - i.e. BEFORE it was jailed - and find-or-spawn would simply adopt
    # that one, which would measure a process nobody spawned from inside the
    # job. Kill it, and the next window makes the jailed app spawn a fresh one.
    foreach ($p in (Get-TestAgents)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    $before = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })
    Assert "A3 premise: no local agent is running before the spawn" ($before.Count -eq 0)

    # ========================================================================
    Say "== B: the agent that jailed app spawns lands OUTSIDE the job"
    # ========================================================================
    # A new window is a new surface, and a persistent surface is what makes the
    # app resolve (and, with no agent alive, spawn) its local agent.
    & $Exe +new-window --target=t426win 2>$null | Out-Null
    $agentPid = Wait-NewAgent $before 40
    Assert "B1 premise: the app spawned a local agent" ($agentPid -ne 0)

    $agentInJob = if ($agentPid -ne 0) { Test-InJob $agentPid $job } else { $null }
    Assert "B2 the agent is NOT a member of the app's job" ($agentInJob -eq $false)

    # ========================================================================
    Say "== C/D: the job's teardown kills its members and not the agent"
    # ========================================================================
    # The negative control: a process spawned into the job with no escape. If
    # the teardown below killed nothing, B2 would pass on a dead job.
    $victim = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'ping -n 60 127.0.0.1 > nul') -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    $victimJailed = $false
    try { [T426Job]::AssignProcessToJobObject($job, $victim.Handle) | Out-Null
          [T426Job]::IsProcessInJob($victim.Handle, $job, [ref]$victimJailed) | Out-Null } catch {}
    Assert "D1 premise: a control process is inside the same job" $victimJailed

    [T426Job]::TerminateJobObject($job, 1) | Out-Null
    [T426Job]::CloseHandle($job) | Out-Null
    $job = [IntPtr]::Zero
    Start-Sleep -Seconds 3

    $victimDead = ($null -eq (Get-Process -Id $victim.Id -ErrorAction SilentlyContinue))
    Assert "D2 the job teardown DID kill its own member (the control)" $victimDead

    $agentAlive = ($agentPid -ne 0) -and
        ($null -ne (Get-Process -Id $agentPid -ErrorAction SilentlyContinue))
    Assert "C1 the local agent SURVIVED the job teardown" $agentAlive
} finally {
    if ($job -ne [IntPtr]::Zero) { [T426Job]::CloseHandle($job) | Out-Null }
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($savedPipe) { $env:GHOZTTY_PIPE_SUFFIX = $savedPipe }
    else { Remove-Item env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    if ($savedSocket) { $env:GHOZTTY_IPC_SOCKET = $savedSocket }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Say ""
if ($script:failures -eq 0) { Say "ALL PASS ($($script:passes) assertions)"; exit 0 }
Say "$($script:failures) FAILURE(S) ($($script:passes) passed)"
exit 1
