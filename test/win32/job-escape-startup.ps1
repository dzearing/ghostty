# T675 acceptance: the APP escapes a hostile kill-on-close job at startup.
#
# The defect: an app launched from inside a Ghoztty pane is a member of the
# AGENT's process-global PTY job (kill-on-close, no breakaway - the shape
# measured in T268). The destructive agent refresh terminates the agent, the
# agent's death closes that job's last handle, and the teardown kills the app
# mid-refresh - the T229/T421/T426 family of unexplained deaths. The fix: at
# startup the app probes its own job and, finding itself inside a kill-on-close
# job, respawns its command line OUTSIDE it (job_spawn's escape tiers) and
# exits; the escaped twin carries on as the app.
#
# This script reproduces the FIELD SHAPE - the app launched from a process that
# is already inside the hostile job, so the app inherits membership at creation
# (every earlier repro attempt jailed the app after launch, which the startup
# probe cannot see and does not claim to fix):
#
#   A: premise - a kill-on-close job with the field's exact flags (0x2000,
#      breakaway forbidden), a launcher jailed in it, and proof that the
#      launcher's plain children inherit membership (the control).
#   B: the app launched by that jailed launcher detects the job, respawns, and
#      the surviving twin is NOT a member - probed with IsProcessInJob against
#      the exact job handle, plus the jailed process's own log trail.
#   C: the job's teardown (TerminateJobObject - what the agent's death does)
#      kills the jailed control and NOT the escaped twin, which is the outcome
#      the membership probe is a proxy for.
#
# Needs the interactive desktop: breakaway is forbidden (field shape), so the
# escape rides the shell-parent hop, and GetShellWindow() answers nothing on a
# background test desktop (T674 tracks a headless tier). SKIPs there, loudly.
#
# Hermetic: a per-run $env:LOCALAPPDATA and a private IPC pipe suffix, and it
# only ever touches ghoztty processes launched from the -Exe under test.
#
#   powershell -NoProfile -File test\win32\job-escape-startup.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

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

$jobSig = @'
using System;
using System.Runtime.InteropServices;
public static class T675Job {
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
  [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
}
'@
Add-Type -TypeDefinition $jobSig -ErrorAction SilentlyContinue

# The escape under test rides the shell-parent hop (breakaway is forbidden in
# the field shape this jail reproduces). No shell window means no hop - a
# SKIP, not a failure, and T674 is the task that makes this unconditional.
if ([T675Job]::GetShellWindow() -eq [IntPtr]::Zero) {
    Say "SKIP: no shell window on this desktop; the shell-parent escape tier cannot run here (see T674)"
    Say ""
    Say "ALL PASS (0 assertions, skipped)"
    exit 0
}

# $true / $false / $null when the process is gone or unopenable.
function Test-InJob($procId, $job) {
    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        $inJob = $false
        if (-not [T675Job]::IsProcessInJob($p.Handle, $job, [ref]$inJob)) { return $null }
        return $inJob
    } catch { return $null }
}

function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgents {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $agentExe })
}
function Stop-TestProcs {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgents)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

function Wait-File($path, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# The app under test still holds its stderr file open.
function Read-AppLog($path) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object System.IO.StreamReader($fs)).ReadToEnd() }
        finally { $fs.Close() }
    } catch { '' }
}
function Wait-LogMatch($path, $pattern, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-AppLog $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

$root = Join-Path $env:TEMP "ghoztty-t675-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSocket = $env:GHOZTTY_IPC_SOCKET
$env:GHOZTTY_PIPE_SUFFIX = "-t675-$PID"
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = $root

$goFile = Join-Path $root 'go.marker'
$victimPidFile = Join-Path $root 'victim.pid'
$appPidFile = Join-Path $root 'app.pid'
$errFile = Join-Path $root 'app.err.txt'
$launcherPs1 = Join-Path $root 'launcher.ps1'

$job = [IntPtr]::Zero
try {
    Stop-TestProcs

    # ========================================================================
    Say "== A: a jailed launcher whose children inherit the kill-on-close job"
    # ========================================================================
    $job = [T675Job]::CreateJobObject([IntPtr]::Zero, $null)
    $jobInfo = New-Object T675Job+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    # KILL_ON_JOB_CLOSE (0x2000) and NOTHING else: the agent PTY job's exact
    # measured shape (T268) - members die on teardown, breakaway is forbidden,
    # so tier 1 is refused and the escape must ride the shell-parent hop.
    $jobInfo.BasicLimitInformation.LimitFlags = 0x2000
    $jobLen = [System.Runtime.InteropServices.Marshal]::SizeOf($jobInfo)
    $jobSet = [T675Job]::SetInformationJobObject($job, 9, [ref]$jobInfo, $jobLen)
    Assert "A0 premise: a kill-on-close job exists (flags 0x2000, no breakaway)" `
        ($job -ne [IntPtr]::Zero -and $jobSet)

    # The launcher waits for the go marker so it can be jailed BEFORE it
    # spawns anything - its children then inherit membership at creation,
    # which is exactly how a pane shell adopts the app in the field.
    #
    # It is created via WMI (Win32_Process.Create - the child belongs to
    # WmiPrvSE, outside every job THIS script sits in) so that after the
    # assignment below it is in EXACTLY ONE job, the jail. Launched plainly it
    # would nest the jail inside whatever job the test runner lives in, and
    # the app's NULL-handle flags query answers for the FIRST job a process
    # joined - the runner's, not the jail - which is a harness artifact the
    # field does not have (a pane shell's only job is the agent's PTY job).
    # WMI also means no environment inheritance, so the launcher sets the
    # hermetic environment itself. It also carries GHOZTTY_PANE_ID, as every
    # real pane shell does - the lineage signal the startup probe trusts when
    # a nested compat job answers the flags query in front of the killer
    # (this box compat-jails GUI launches, so the artifact is reproduced here
    # whether or not the field has it).
    @"
`$env:LOCALAPPDATA = '$root'
`$env:GHOZTTY_PIPE_SUFFIX = '-t675-$PID'
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
`$env:GHOZTTY_PANE_ID = 'T675-ACCEPTANCE-PANE'
Remove-Item env:GHOZTTY_NO_STARTUP_ESCAPE -ErrorAction SilentlyContinue
while (-not (Test-Path '$goFile')) { Start-Sleep -Milliseconds 200 }
`$victim = Start-Process -FilePath cmd.exe -ArgumentList '/c','ping -n 120 127.0.0.1 > nul' -WindowStyle Hidden -PassThru
Set-Content -Path '$victimPidFile' -Value `$victim.Id
`$app = Start-Process -FilePath '$Exe' -ArgumentList '--title=t675' -RedirectStandardError '$errFile' -PassThru
Set-Content -Path '$appPidFile' -Value `$app.Id
"@ | Set-Content -Path $launcherPs1 -Encoding ascii

    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPs1`""
    }
    $launcherPid = if ($created.ReturnValue -eq 0) { [int]$created.ProcessId } else { 0 }
    $launcherJailed = $false
    if ($launcherPid -ne 0) {
        try {
            $launcherProc = Get-Process -Id $launcherPid -ErrorAction Stop
            [T675Job]::AssignProcessToJobObject($job, $launcherProc.Handle) | Out-Null
            [T675Job]::IsProcessInJob($launcherProc.Handle, $job, [ref]$launcherJailed) | Out-Null
        } catch {}
    }
    Assert "A1 premise: the launcher is jailed in the job (and only in it)" $launcherJailed

    New-Item -ItemType File -Path $goFile -Force | Out-Null

    $victimSeen = Wait-File $victimPidFile 20
    $victimPid = if ($victimSeen) { [int](Get-Content $victimPidFile | Select-Object -First 1) } else { 0 }
    Start-Sleep -Milliseconds 300
    Assert "A2 control: a plain child of the jailed launcher inherits membership" `
        ($victimPid -ne 0 -and (Test-InJob $victimPid $job) -eq $true)

    # ========================================================================
    Say "== B: the app launched from inside the job escapes it at startup"
    # ========================================================================
    $appSeen = Wait-File $appPidFile 20
    $origPid = if ($appSeen) { [int](Get-Content $appPidFile | Select-Object -First 1) } else { 0 }
    Assert "B1 premise: the jailed launcher started the app" ($origPid -ne 0)

    Assert "B2 the jailed app DETECTED the kill-on-close job" `
        (Wait-LogMatch $errFile 'startup escape: this process is inside a kill-on-close job' 30)
    Assert "B3 ... and respawned itself outside it, naming the tier" `
        (Wait-LogMatch $errFile 'startup escape: respawned as pid \d+ \((breakaway|shell-parent)\)' 30)

    $twinPid = 0
    if ((Read-AppLog $errFile) -match 'startup escape: respawned as pid (\d+)') {
        $twinPid = [int]$Matches[1]
    }
    $twinProc = $null
    if ($twinPid -ne 0) {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $twinProc = Get-Process -Id $twinPid -ErrorAction SilentlyContinue
            if ($twinProc) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    Assert "B4 the escaped twin is alive and is the exe under test" `
        ($null -ne $twinProc -and $twinProc.Path -eq $Exe)
    Assert "B5 the twin is NOT a member of the hostile job" `
        ((Test-InJob $twinPid $job) -eq $false)

    $origGone = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Process -Id $origPid -ErrorAction SilentlyContinue)) { $origGone = $true; break }
        Start-Sleep -Milliseconds 300
    }
    Assert "B6 the jailed original exited after handing off" $origGone

    # ========================================================================
    Say "== C: the job's teardown kills its members and not the twin"
    # ========================================================================
    [T675Job]::TerminateJobObject($job, 1) | Out-Null
    [T675Job]::CloseHandle($job) | Out-Null
    $job = [IntPtr]::Zero
    Start-Sleep -Seconds 3

    Assert "C1 the teardown DID kill the jailed control" `
        ($null -eq (Get-Process -Id $victimPid -ErrorAction SilentlyContinue))
    Assert "C2 the escaped app SURVIVED the teardown that used to kill it" `
        ($twinPid -ne 0 -and $null -ne (Get-Process -Id $twinPid -ErrorAction SilentlyContinue))
} finally {
    if ($job -ne [IntPtr]::Zero) { [T675Job]::CloseHandle($job) | Out-Null }
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($savedPipe) { $env:GHOZTTY_PIPE_SUFFIX = $savedPipe }
    else { Remove-Item env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    if ($savedSocket) { $env:GHOZTTY_IPC_SOCKET = $savedSocket }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Say ""
if ($script:failures -eq 0) {
    # A green run stamps the covered files (T783) so guard-due can answer "has
    # this harness been run against the code as it now stands?". Red leaves
    # the stamp alone (red stays due), and the SKIP path above never gets
    # here (a run that proved nothing must not stamp).
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard job-escape-startup -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    Say "ALL PASS ($($script:passes) assertions)"
    exit 0
}
Say "$($script:failures) FAILURE(S) ($($script:passes) passed)"
exit 1
