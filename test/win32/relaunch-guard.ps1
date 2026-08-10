# T421 acceptance: the agent-refresh RELAUNCH GUARD.
#
# The defect, twice reported (T229, then again 2026-08-03): the user confirms
# the mandatory agent-restart dialog, the app ends without a crash record or a
# further log line, and NOTHING brings it back. On 2026-08-03 the box sat with
# no Ghoztty for fourteen minutes until the user launched it by hand.
#
# T229 attacked the cause and could not reproduce it in four shapes. This guards
# the OUTCOME instead: for the seconds the app spends restarting its agent, a
# detached watcher holds its process handle and starts it again if it ends
# early. Measured by OUTCOME - a process that exists, from the right exe,
# answering IPC - never by log scraping.
#
#   A: positive - app dies with the marker present => a NEW app is started from
#      the same exe, and it answers +list. The user's report, inverted.
#   B: negative control - the marker is CLEARED first (a refresh that finished)
#      => the same death relaunches nothing. Without this arm, an
#      always-relaunch bug would pass arm A.
#   C: negative control - the app is still ALIVE when the marker clears => the
#      guard exits on its own rather than lingering to fire later.
#   D: negative control - a malformed spec launches nothing and exits non-zero.
#      A guard that misreads its orders would wait on some unrelated pid.
#   E: the guard process is not a terminal: it opens no window and binds no IPC
#      endpoint, so it can never be mistaken for a second instance.
#   F: T524 - a guard jailed in a kill-on-close job relaunches an app that
#      lands OUTSIDE the job and survives the job's teardown (the production
#      failure was the guard/app dying together in a job teardown).
#
# Arm A/B/D drive the WATCHING half directly (the env var IS the interface).
# The ARMING half is covered end to end by test\win32\agent-upgrade.ps1 arm H
# (H16-H18), which runs a real destructive refresh.
#
# Hermetic: a per-run $env:LOCALAPPDATA and a private IPC pipe suffix, and it
# only ever touches ghoztty processes launched from the -Exe under test.
#
#   powershell -NoProfile -File test\win32\relaunch-guard.ps1
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

# Only processes started from the exe under test. The user's installed release
# runs from %LOCALAPPDATA%\Programs\Ghoztty and must never be matched.
#
# And only THIS RUN's processes. Another session's harness may drive the same
# zig-out exe concurrently (observed live 2026-08-06: a parallel loop session's
# script spawning `+verb` one-shots and `--session-persistence=false` apps
# mid-run), and this suite's own `+list` probes are ghoztty.exe processes for a
# moment too. Neither may count as a stray or a relaunch. Ours are exactly two
# shapes: the BARE exe (a guard, or a guard's relaunch - the guard passes no
# arguments) and apps started with `--title=t421*`/`--title=t524*`.
#
# `, @(...)` so a single match survives the pipeline as an ARRAY - but that only
# holds through an ASSIGNMENT. Piping the call directly (`Get-TestApps | Where`)
# unrolls the wrapper and hands Where-Object the inner array as ONE object,
# whose `.ProcessId` is empty; that read as "a stray process exists" and failed
# a negative control that was in fact passing. Always assign first.
function Test-OursCmdline($cmd) {
    if (-not $cmd) { return $true }  # no cmdline visible: assume ours (bare spawn)
    $t = $cmd.TrimEnd()
    if ($t.EndsWith('ghoztty.exe') -or $t.EndsWith('ghoztty.exe"')) { return $true }
    return ($t -match '--title=t(421|524)')
}
function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe -and (Test-OursCmdline $_.CommandLine) })
}
function Stop-TestApps {
    $apps = Get-TestApps
    foreach ($p in $apps) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
}

# Start the app under test, detached, and wait until it answers its own IPC.
# Returns the pid, or 0.
function Start-TestApp($tag) {
    # persistence: on (default) - the guard path under test is the one a persistent app takes; this script counts PROCESSES, not panes.
    $p = Start-Process -FilePath $Exe -ArgumentList @("--title=$tag") -PassThru
    $appPid = $p.Id
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) { return 0 }
        $out = (& $Exe +list 2>$null) | Out-String
        if ($out -match '\S') { return $appPid }
        Start-Sleep -Milliseconds 500
    }
    return 0
}

# Spawn a guard the way the app does: same exe, the spec in the environment.
# Set on THIS process for the duration of the spawn, exactly like `armImpl`.
function Start-Guard($appPid, $marker) {
    $env:GHOZTTY_RELAUNCH_GUARD = "$appPid|$marker|$Exe"
    try {
        # persistence: on (default) - see Start-TestApp above.
        return (Start-Process -FilePath $Exe -PassThru -WindowStyle Hidden)
    } finally {
        Remove-Item env:GHOZTTY_RELAUNCH_GUARD -ErrorAction SilentlyContinue
    }
}

# $excludePids: every pid that is NOT the relaunch - the dead app AND the
# guard, which is the same bare exe and used to be returned as the "new app"
# in the instant before it exited (a probe against it then read a dead handle).
function Wait-NewApp($excludePids, $timeoutSec = 30) {
    $excludePids = @($excludePids | ForEach-Object { [int]$_ })
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $all = Get-TestApps
        $fresh = @($all | Where-Object { $excludePids -notcontains [int]$_.ProcessId })
        if ($fresh.Count -gt 0) { return [int]$fresh[0].ProcessId }
        Start-Sleep -Milliseconds 500
    }
    return 0
}

function Wait-Exit($processPid, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $processPid -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

if (-not (Test-Path $Exe)) {
    Write-Host "FAIL: exe not found: $Exe" -ForegroundColor Red
    exit 1
}

$root = Join-Path $env:TEMP "ghoztty-relaunch-guard-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSocket = $env:GHOZTTY_IPC_SOCKET
# A private endpoint so nothing here can reach the user's terminal. The suffix
# OUTRANKS the baked GHOZTTY_IPC_SOCKET this script inherits from the pane it
# was started in (CLAUDE.md, Instance addressability) - but clear the baked
# value too, so nothing downstream can prefer it.
$env:GHOZTTY_PIPE_SUFFIX = "-t421-$PID"
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = $root

try {
    Stop-TestApps

    # ========================================================================
    Say "== A: the app dies inside the window => the guard brings it back"
    # ========================================================================
    $marker = Join-Path $root 'guard-a.marker'
    Set-Content -LiteralPath $marker -Value 'armed' -Encoding utf8
    $appA = Start-TestApp 't421a'
    Assert "A1 premise: the app under test is up and answering IPC" ($appA -ne 0)
    $guardA = Start-Guard $appA $marker
    Assert "A2 premise: a guard process started" ($null -ne $guardA -and $guardA.Id -gt 0)
    Start-Sleep -Milliseconds 1500

    # THE event: the app ends while the marker says the refresh never finished.
    Stop-Process -Id $appA -Force -ErrorAction SilentlyContinue
    $appA2 = Wait-NewApp @($appA, $guardA.Id) 40
    Assert "A3 a NEW app was started after the death" ($appA2 -ne 0 -and $appA2 -ne $appA)
    # Started, not merely spawned: the whole complaint is that the user had no
    # terminal, so the replacement has to actually be one.
    $listA = ''
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $listA = (& $Exe +list 2>$null) | Out-String
        if ($listA -match '\S') { break }
        Start-Sleep -Milliseconds 500
    }
    Assert "A4 the relaunched app answers +list (it is a real terminal)" ($listA -match '\S')
    Assert "A5 the guard exited once it had relaunched" (Wait-Exit $guardA.Id 20)
    Assert "A6 the marker was cleaned up (no relaunch on the NEXT exit)" `
        (-not (Test-Path $marker))
    Stop-TestApps

    # ========================================================================
    Say "== B: negative control - a cleared marker relaunches nothing"
    # ========================================================================
    $markerB = Join-Path $root 'guard-b.marker'
    Set-Content -LiteralPath $markerB -Value 'armed' -Encoding utf8
    $appB = Start-TestApp 't421b'
    Assert "B1 premise: the app under test is up" ($appB -ne 0)
    $guardB = Start-Guard $appB $markerB
    Start-Sleep -Milliseconds 1500
    # The refresh finished: disarm, THEN end the app (a user quitting normally).
    Remove-Item -LiteralPath $markerB -Force
    Start-Sleep -Milliseconds 1200
    Stop-Process -Id $appB -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 6
    $allB = Get-TestApps
    $strayB = @($allB | Where-Object { $_.ProcessId -ne $appB })
    if ($strayB.Count -gt 0) {
        foreach ($s in $strayB) { Say "    stray: pid=$($s.ProcessId) cmd=$($s.CommandLine)" }
    }
    Assert "B2 NO app was relaunched after a disarmed exit" ($strayB.Count -eq 0)
    Assert "B3 the guard exited on its own" (Wait-Exit $guardB.Id 20)
    Stop-TestApps

    # ========================================================================
    Say "== C: negative control - a disarm while the app LIVES ends the guard"
    # ========================================================================
    # Without this the guard would sit on the handle for its whole 10-minute cap
    # and fire on an exit that has nothing to do with the refresh.
    $markerC = Join-Path $root 'guard-c.marker'
    Set-Content -LiteralPath $markerC -Value 'armed' -Encoding utf8
    $appC = Start-TestApp 't421c'
    Assert "C1 premise: the app under test is up" ($appC -ne 0)
    $guardC = Start-Guard $appC $markerC
    Start-Sleep -Milliseconds 1500
    Assert "C2 premise: the guard is still watching a live app" `
        ($null -ne (Get-Process -Id $guardC.Id -ErrorAction SilentlyContinue))
    Remove-Item -LiteralPath $markerC -Force
    Assert "C3 the guard let go as soon as the marker cleared" (Wait-Exit $guardC.Id 25)
    Assert "C4 the app it was watching is untouched" `
        ($null -ne (Get-Process -Id $appC -ErrorAction SilentlyContinue))
    Stop-TestApps

    # ========================================================================
    Say "== D: negative control - a malformed spec does nothing, loudly"
    # ========================================================================
    $allD = Get-TestApps
    $before = @($allD).Count
    $env:GHOZTTY_RELAUNCH_GUARD = 'this-is-not-a-spec'
    try {
        # persistence: on (default) - see Start-TestApp above.
        $bad = Start-Process -FilePath $Exe -PassThru -WindowStyle Hidden
    } finally {
        Remove-Item env:GHOZTTY_RELAUNCH_GUARD -ErrorAction SilentlyContinue
    }
    Assert "D1 the malformed guard exited promptly" (Wait-Exit $bad.Id 20)
    Start-Sleep -Seconds 3
    $allD2 = Get-TestApps
    Assert "D2 it started no app" (@($allD2).Count -le $before)
    Stop-TestApps

    # ========================================================================
    Say "== E: a guard is not an app - no window, no IPC endpoint"
    # ========================================================================
    $markerE = Join-Path $root 'guard-e.marker'
    Set-Content -LiteralPath $markerE -Value 'armed' -Encoding utf8
    # Watch a pid that will outlive the arm, with no app running at all: if the
    # guard were becoming a terminal, +list would start answering.
    $guardE = Start-Guard $PID $markerE
    Start-Sleep -Seconds 3
    $listE = (& $Exe +list 2>$null) | Out-String
    Assert "E1 the guard answers no IPC (it never became an instance)" `
        (-not ($listE -match '\S'))
    Assert "E2 the guard is still just a watcher" `
        ($null -ne (Get-Process -Id $guardE.Id -ErrorAction SilentlyContinue))
    Remove-Item -LiteralPath $markerE -Force
    Assert "E3 ... and stops when disarmed" (Wait-Exit $guardE.Id 25)
    Stop-TestApps

    # ========================================================================
    Say "== F: T524 - the relaunch ESCAPES a kill-on-close job object"
    # ========================================================================
    # Production shape: this box wraps process trees in kill-on-close job
    # objects (LimitFlags 0x3C00 measured live on 2026-08-06), and a job
    # teardown kills every member at once - which is how four production
    # guards died WITH the app they were watching, before their first
    # instruction. The fix spawns across the job boundary with
    # CREATE_BREAKAWAY_FROM_JOB. Here the GUARD is jailed in such a job and
    # relaunches the dead app from inside it: the replacement must land
    # OUTSIDE the job (F4, the direct membership probe) and survive the job
    # being torn down (F5). Under pre-T524 code the replacement inherits the
    # job and dies with it.
    $jobSig = @'
using System;
using System.Runtime.InteropServices;
public static class T524Job {
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
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
}
'@
    Add-Type -TypeDefinition $jobSig -ErrorAction SilentlyContinue

    $job = [T524Job]::CreateJobObject([IntPtr]::Zero, $null)
    $jobInfo = New-Object T524Job+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    # KILL_ON_JOB_CLOSE (0x2000) + BREAKAWAY_OK (0x800): the measured
    # production shape - members die on teardown, but breakaway is permitted.
    $jobInfo.BasicLimitInformation.LimitFlags = 0x2800
    $jobLen = [System.Runtime.InteropServices.Marshal]::SizeOf($jobInfo)
    $jobSet = [T524Job]::SetInformationJobObject($job, 9, [ref]$jobInfo, $jobLen)
    Assert "F0 premise: a kill-on-close job exists" ($job -ne [IntPtr]::Zero -and $jobSet)

    $markerF = Join-Path $root 'guard-f.marker'
    Set-Content -LiteralPath $markerF -Value 'armed' -Encoding utf8
    $appF = Start-TestApp 't524f'
    Assert "F1 premise: the app under test is up" ($appF -ne 0)
    $guardF = Start-Guard $appF $markerF
    $guardProc = Get-Process -Id $guardF.Id -ErrorAction SilentlyContinue
    $jailed = $false
    if ($guardProc) {
        [T524Job]::AssignProcessToJobObject($job, $guardProc.Handle) | Out-Null
        [T524Job]::IsProcessInJob($guardProc.Handle, $job, [ref]$jailed) | Out-Null
    }
    Assert "F2 premise: the guard is jailed in the kill-on-close job" $jailed
    Start-Sleep -Milliseconds 1500

    Stop-Process -Id $appF -Force -ErrorAction SilentlyContinue
    $appF2 = Wait-NewApp @($appF, $guardF.Id) 40
    Assert "F3 the jailed guard still relaunched the app" ($appF2 -ne 0)
    $escaped = $false
    if ($appF2 -ne 0) {
        try {
            $newProc = Get-Process -Id $appF2 -ErrorAction Stop
            $inJob = $true
            [void][T524Job]::IsProcessInJob($newProc.Handle, $job, [ref]$inJob)
            $escaped = -not $inJob
        } catch {}
    }
    Assert "F4 the relaunched app landed OUTSIDE the job (breakaway)" $escaped

    # Tear the job down the way production does: close its last handle.
    [T524Job]::CloseHandle($job) | Out-Null
    Start-Sleep -Seconds 3
    $survived = ($appF2 -ne 0) -and ($null -ne (Get-Process -Id $appF2 -ErrorAction SilentlyContinue))
    Assert "F5 the relaunched app SURVIVED the job teardown" $survived
    $listF = (& $Exe +list 2>$null) | Out-String
    Assert "F6 ... and still answers +list" ($listF -match '\S')
} finally {
    Stop-TestApps
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
