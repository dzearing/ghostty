<#
.SYNOPSIS
    Run a standing-floor test lane under a watchdog that can tell a SLOW run
    from a WEDGED one, and never returns without an answer (T430).

.DESCRIPTION
    Two of the four standing-floor lanes (`zig build test -Dapp-runtime=win32`
    and `zig build test-agent`) have hung indefinitely with no output and no
    timeout. A hang that cannot be told apart from slowness is worse than a red
    test: a turn either waits forever, or kills its own run and reads the kill
    as a regression it caused.

    This wrapper gives every lane a bounded, diagnosed ending:

      * It sets ZIG_GLOBAL_CACHE_DIR on the repo's own drive before launching,
        because a detached `cmd.exe` does not inherit a `$env:` var set in an
        earlier shell and the resulting failure reads as a corrupt cache
        ("unable to read results of configure phase ... FileNotFound") rather
        than as anything mentioning drives.
      * It logs through cmd.exe redirection (unbuffered), so a killed run still
        has its output on disk. PowerShell's own `*>` buffers, and `Stop-Job`
        discards the buffer -- that is how two earlier hang investigations
        produced zero bytes.
      * It watches CPU, not just the clock. A lane that is *computing* burns
        CPU; a lane that is *wedged* does not. Zero CPU delta across the whole
        process tree for -StallSeconds, with no new log output, is a wedge and
        is reported as one.
      * On a wedge (or the wall-clock cap) it dumps a diagnostic FIRST -- the
        process tree with CPU times, every thread's wait reason, any WebView2
        hosts, and the log tail -- and only then kills the tree.
      * It sweeps leaked `msedgewebview2.exe` hosts, which are invisible to a
        sweep that filters on zig-out/zig-cache paths (that exe lives under
        Program Files). Match on `--webview-exe-name=` instead.

.PARAMETER Lane
    none | win32 | agent | all. Default `all` runs the three zig lanes in
    sequence.

.PARAMETER TimeoutSeconds
    Wall-clock cap per lane run. Default 1800.

.PARAMETER StallSeconds
    Zero-CPU-delta window that counts as wedged. Default 420 -- see the comment
    on the parameter for the measurement that set it.

.PARAMETER Repeat
    Run each lane this many times (T430's validation asks for 10 consecutive
    clean runs). A failing or wedged run stops the repeat.

.OUTPUTS
    One `LANE <name> <RESULT> ...` line per run and a final summary line.
    Exit code: 0 all passed, 1 a lane failed, 2 a lane wedged, 3 a lane hit the
    wall-clock cap.
#>
[CmdletBinding()]
param(
    [ValidateSet('none', 'win32', 'agent', 'all')]
    [string]$Lane = 'all',
    [int]$TimeoutSeconds = 1800,
    # 420s, not 180: the agent lane was measured (2026-08-03) sitting in a
    # LEGITIMATE fully-blocked wait for ~173s -- a Chromium preconnect the test
    # server was reading from, since fixed -- and then finishing green. A
    # threshold that would have called that a wedge is worse than useless: a
    # false STALL is indistinguishable from the bug it is looking for.
    [int]$StallSeconds = 420,
    [int]$SampleSeconds = 5,
    [int]$Repeat = 1,
    [string]$Filter,
    [string]$Repo = 'D:\git\ghoztty',
    [string]$CacheDir,
    [switch]$NoSweep,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Decodes a crashed child's truncated exit code and reads the Windows crash log
# (T444). Without it a lane can end on a bare "exited with error code 5".
. "$PSScriptRoot\lib\CrashDiag.ps1"

# Exit codes, named so a caller does not have to guess.
$EXIT_PASS = 0
$EXIT_FAIL = 1
$EXIT_STALL = 2
$EXIT_TIMEOUT = 3

# ---------------------------------------------------------------- lane table

function Get-LaneArgs {
    param([string]$Name)
    switch ($Name) {
        'none' { return 'test -Dapp-runtime=none' }      # pure logic
        'win32' { return 'test -Dapp-runtime=win32' }     # win32 apprt units
        'agent' { return 'test-agent' }                   # incl. real-pty
    }
    throw "unknown lane: $Name"
}

# Test binaries the zig lanes produce. Used to name the processes in a
# diagnostic and to match the WebView2 hosts they leak.
$TEST_EXE_NAMES = @(
    'ghostty-test.exe',
    'ghoztty-agent-test.exe',
    'ghoztty-agent-core-test.exe'
)

# ------------------------------------------------------------------ helpers

function Resolve-CacheDir {
    param([string]$RepoPath, [string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ZIG_GLOBAL_CACHE_DIR) { return $env:ZIG_GLOBAL_CACHE_DIR }
    # CLAUDE.md: the global cache MUST sit on the repo's drive, or zig 0.15.2's
    # build runner panics in convertPathArg before any test runs.
    $drive = (Split-Path -Qualifier $RepoPath)
    return (Join-Path $drive '\zig-global-cache')
}

function Get-ProcessTree {
    # Every live descendant of $RootPid, plus the root itself. One CIM query,
    # walked in memory: a per-process query per level is far slower and the
    # tree can change under us mid-walk.
    param([int]$RootPid, $Snapshot)
    $byParent = @{}
    foreach ($p in $Snapshot) {
        $key = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
        $null = $byParent[$key].Add($p)
    }
    $out = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootPid)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        $self = $Snapshot | Where-Object { [int]$_.ProcessId -eq $cur }
        foreach ($s in $self) { $null = $out.Add($s) }
        if ($byParent.ContainsKey($cur)) {
            foreach ($c in $byParent[$cur]) { $queue.Enqueue([int]$c.ProcessId) }
        }
    }
    return $out
}

function Get-TreeCpu {
    param($Tree)
    $total = [uint64]0
    foreach ($p in $Tree) {
        if ($null -ne $p.UserModeTime) { $total += [uint64]$p.UserModeTime }
        if ($null -ne $p.KernelModeTime) { $total += [uint64]$p.KernelModeTime }
    }
    return $total
}

function Get-WebViewHosts {
    # Leaked WebView2 browser processes, keyed by the host exe that created
    # them. They live under Program Files, so a path filter on zig-out or
    # zig-cache never sees them; `--webview-exe-name=` does.
    param([string[]]$ExeNames)
    $hosts = @()
    $all = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue
    foreach ($h in $all) {
        $cl = $h.CommandLine
        if (-not $cl) { continue }
        foreach ($n in $ExeNames) {
            if ($cl -like "*--webview-exe-name=$n*") { $hosts += $h; break }
        }
    }
    return $hosts
}

function Write-Diagnostic {
    <#
        Everything a human needs to tell "this test is slow" from "this test is
        wedged", written before anything is killed. The thread wait reasons are
        the part that survives having no debugger installed: a wedged thread
        names what it is waiting on.
    #>
    param([string]$Reason, $Tree, [string]$LogPath, [int]$ElapsedSeconds)

    Write-Host ""
    Write-Host "=============================================================="
    Write-Host "FLOOR LANE DIAGNOSTIC: $Reason after ${ElapsedSeconds}s"
    Write-Host "=============================================================="

    Write-Host "-- process tree --"
    foreach ($p in $Tree) {
        $cpuSec = 0
        if ($null -ne $p.UserModeTime) {
            $cpuSec = [math]::Round(([double]$p.UserModeTime + [double]$p.KernelModeTime) / 10000000.0, 1)
        }
        Write-Host ("  pid={0,-7} {1,-32} cpu={2,8}s" -f $p.ProcessId, $p.Name, $cpuSec)
    }

    Write-Host "-- threads of the test binaries (state / wait reason) --"
    $anyThreads = $false
    foreach ($p in $Tree) {
        if ($TEST_EXE_NAMES -notcontains $p.Name) { continue }
        $anyThreads = $true
        Write-Host ("  [{0}] pid={1}" -f $p.Name, $p.ProcessId)
        $threads = Get-CimInstance Win32_Thread -Filter "ProcessHandle='$($p.ProcessId)'" -ErrorAction SilentlyContinue
        foreach ($t in $threads) {
            Write-Host ("    tid={0,-7} state={1,-3} waitReason={2,-3} userMs={3}" -f `
                    $t.Handle, $t.ThreadState, $t.ThreadWaitReason, $t.UserModeTime)
        }
    }
    if (-not $anyThreads) { Write-Host "  (no test binary alive in the tree)" }

    $wv = Get-WebViewHosts -ExeNames $TEST_EXE_NAMES
    Write-Host "-- WebView2 hosts owned by test binaries: $($wv.Count) --"
    foreach ($h in $wv) {
        $udd = ''
        if ($h.CommandLine -match '--user-data-dir="([^"]+)"') { $udd = $matches[1] }
        Write-Host ("  pid={0,-7} user-data-dir={1}" -f $h.ProcessId, $udd)
    }

    if (Test-Path $LogPath) {
        Write-Host "-- log tail (40) --"
        Get-Content $LogPath -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "=============================================================="
    Write-Host ""
}

function Stop-Tree {
    param($Tree)
    # Children first: killing the root first orphans the test binaries, and an
    # orphaned test binary keeps its WebView2 hosts alive under a pid nobody is
    # tracking any more.
    $ordered = @($Tree)
    [array]::Reverse($ordered)
    foreach ($p in $ordered) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
    }
}

function Invoke-WebViewSweep {
    param([switch]$Quiet)
    $wv = Get-WebViewHosts -ExeNames $TEST_EXE_NAMES
    foreach ($h in $wv) {
        try { Stop-Process -Id $h.ProcessId -Force -ErrorAction Stop } catch {}
    }
    if (-not $Quiet -and $wv.Count -gt 0) {
        Write-Host "swept $($wv.Count) leaked WebView2 host(s) owned by test binaries"
    }

    # ...and the private profiles those hosts were running under
    # (`webview2.TestProfile`, one per test-binary pid). The test cannot delete
    # its own: the browser process outlives it and holds the files open. Only
    # remove one whose owning pid is gone, so a concurrent run's profile is
    # never pulled out from under it.
    foreach ($d in (Get-ChildItem $env:TEMP -Directory -Filter 'ghoztty-wv2test-*' -ErrorAction SilentlyContinue)) {
        $ownerPid = 0
        if ($d.Name -match '^ghoztty-wv2test-(\d+)$') { $ownerPid = [int]$matches[1] }
        if ($ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) { continue }
        try { Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop } catch {}
    }
    return $wv.Count
}

# ------------------------------------------------------------------- runner

function Invoke-Lane {
    param([string]$Name, [int]$Iteration, [string]$RawCommand)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $log = Join-Path $env:TEMP "floor-lane-$Name-$stamp.log"

    if ($RawCommand) {
        # Self-test: the same watchdog loop over a synthetic command, so the
        # detector is exercised without waiting on a real 30-minute wedge.
        $cmd = "$RawCommand > `"$log`" 2>&1"
        Write-Host "LANE $Name run $Iteration/$Repeat : $RawCommand"
    }
    else {
        $buildArgs = Get-LaneArgs -Name $Name
        if ($Filter) { $buildArgs = "$buildArgs -Dtest-filter=`"$Filter`"" }

        # `set "VAR=value"` -- the quotes are load-bearing: without them cmd folds
        # the space before && into the value and the link step then fails on a path
        # with a stray space, which names neither the variable nor the cause.
        $cmd = "set `"ZIG_GLOBAL_CACHE_DIR=$cacheDir`" && cd /d `"$Repo`" && zig build $buildArgs > `"$log`" 2>&1"
        Write-Host "LANE $Name run $Iteration/$Repeat : zig build $buildArgs"
    }
    Write-Host "  log: $log"

    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -PassThru -WindowStyle Hidden
    # Cache the handle NOW: without it $proc.ExitCode reads empty after the
    # child exits, which is how gating on exit codes fabricates failures.
    $null = $proc.Handle
    $rootPid = $proc.Id

    $started = Get-Date
    $lastCpu = [uint64]0
    $lastLogLen = [int64]0
    $lastProgress = Get-Date
    $result = $null

    while ($true) {
        Start-Sleep -Seconds ([math]::Max(1, $SampleSeconds))

        if ($proc.HasExited) {
            $result = if ($proc.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
            break
        }

        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        $snapshot = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        $tree = Get-ProcessTree -RootPid $rootPid -Snapshot $snapshot
        $cpu = Get-TreeCpu -Tree $tree
        $logLen = 0
        if (Test-Path $log) { $logLen = (Get-Item $log).Length }

        if ($cpu -ne $lastCpu -or $logLen -ne $lastLogLen) {
            $lastProgress = Get-Date
            $lastCpu = $cpu
            $lastLogLen = $logLen
        }

        $stalledFor = [int]((Get-Date) - $lastProgress).TotalSeconds

        if ($elapsed -ge $TimeoutSeconds) {
            Write-Diagnostic -Reason 'WALL-CLOCK CAP' -Tree $tree -LogPath $log -ElapsedSeconds $elapsed
            Stop-Tree -Tree $tree
            $result = 'TIMEOUT'
            break
        }

        if ($stalledFor -ge $StallSeconds) {
            Write-Diagnostic -Reason "WEDGED (no CPU and no output for ${stalledFor}s)" `
                -Tree $tree -LogPath $log -ElapsedSeconds $elapsed
            Stop-Tree -Tree $tree
            $result = 'STALL'
            break
        }
    }

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    $leaked = 0
    if (-not $NoSweep) { $leaked = Invoke-WebViewSweep }

    $tail = ''
    if (Test-Path $log) {
        $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
        if ($lines.Count -gt 0) { $tail = $lines[-1] }
    }

    Write-Host "LANE $Name $result in ${elapsed}s (leaked webview hosts swept: $leaked) | $tail"
    if ($result -eq 'FAIL' -and (Test-Path $log)) {
        Write-Host "-- errors --"
        Select-String -Path $log -Pattern 'error:' -ErrorAction SilentlyContinue |
            Select-Object -First 15 | ForEach-Object { Write-Host "  $($_.Line)" }
        # A lane can fail with nothing but "exited with error code 5" -- which is
        # a CRASHED child, not a silent compiler (T444). Decode the code and name
        # the process that died, so a red lane is never a bare number.
        $null = Write-CrashDiagnostic -Since $started -LogPath $log
    }
    return $result
}

# --------------------------------------------------------------------- main

$cacheDir = Resolve-CacheDir -RepoPath $Repo -Explicit $CacheDir
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
Write-Host "ZIG_GLOBAL_CACHE_DIR=$cacheDir"

if ($SelfTest) {
    # Proves the three verdicts on synthetic commands, so the detector itself is
    # covered without waiting on a real wedge. `waitfor` blocks on a named signal
    # that never arrives: a genuinely blocked wait burning no CPU, which is the
    # shape this watchdog exists to name.
    $StallSeconds = 15
    $SampleSeconds = 5
    $TimeoutSeconds = 120
    $Repeat = 1
    $failures = 0
    $cases = @(
        @{ Name = 'selftest-pass'; Cmd = 'cmd /c exit 0'; Want = 'PASS' },
        @{ Name = 'selftest-fail'; Cmd = 'cmd /c exit 7'; Want = 'FAIL' },
        @{ Name = 'selftest-wedge'; Cmd = 'waitfor /t 600 GhozttyFloorLaneNeverSignalled'; Want = 'STALL' }
    )
    foreach ($c in $cases) {
        $got = Invoke-Lane -Name $c.Name -Iteration 1 -RawCommand $c.Cmd
        if ($got -eq $c.Want) { Write-Host "  PASS $($c.Name): $got" }
        else { Write-Host "  FAIL $($c.Name): wanted $($c.Want), got $got"; $failures++ }
    }
    Write-Host ""
    if ($failures -eq 0) { Write-Host 'ALL PASS'; exit 0 }
    Write-Host "$failures FAILURE(S)"
    exit 1
}

$lanes = if ($Lane -eq 'all') { @('none', 'win32', 'agent') } else { @($Lane) }
$worst = $EXIT_PASS
$summary = @()

foreach ($l in $lanes) {
    for ($i = 1; $i -le $Repeat; $i++) {
        $r = Invoke-Lane -Name $l -Iteration $i
        $summary += "$l#${i}=$r"
        switch ($r) {
            'FAIL' { if ($worst -lt $EXIT_FAIL) { $worst = $EXIT_FAIL } }
            'STALL' { if ($worst -lt $EXIT_STALL) { $worst = $EXIT_STALL } }
            'TIMEOUT' { if ($worst -lt $EXIT_TIMEOUT) { $worst = $EXIT_TIMEOUT } }
        }
        if ($r -ne 'PASS') { break }
    }
}

Write-Host ""
Write-Host "FLOOR SUMMARY: $($summary -join ' ')"
if ($worst -eq $EXIT_PASS) { Write-Host 'ALL LANES PASS' } else { Write-Host 'FLOOR NOT GREEN' }
exit $worst
