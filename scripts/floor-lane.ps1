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
      * It self-heals a torn zig-cache entry (T494): a FAIL whose compile
        errors point into `.zig-cache\` or the global cache is a half-written
        cache file, not red code -- the entry is deleted (loudly, as
        `CACHE HEAL` lines) and the lane re-run ONCE; the re-run's verdict is
        final. See scripts\lib\CacheHeal.ps1.

.PARAMETER Lane
    none | win32 | agent | lib | all. Default `all` runs the four zig lanes in
    sequence.

    `lib` is the odd one out: it BUILDS rather than tests, and it is here
    because nothing else on this box compiles the shared core for the
    msvc-target `lib ghostty` artifact. POSIX-only code can therefore enter
    `src/` and every lane people run stays green -- `zig build
    -Dapp-runtime=none` was red for weeks over four such call sites in
    `src/remote/ssh_transport.zig` (T475), and the test lanes could not see it
    because the tests that reach them `SkipZigTest` on Windows, which stops
    Zig analyzing the bodies. A cached run costs about a second; it only
    compiles anything when the shared core actually moved, which is exactly
    when the canary is worth having.

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
    [ValidateSet('none', 'win32', 'agent', 'lib', 'all')]
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
    # A crashed lane re-runs its test binary under cdb to capture a stack (T450).
    # On by default: the crash it exists for is intermittent, so "remember to
    # pass a flag next time" means the evidence is gone until it happens again.
    [switch]$NoCatch,
    # ONE attempt by default, not two (user, decision D6, 2026-08-04). A red
    # lane may spend ~10 minutes capturing a stack, not ~20: one attempt still
    # catches roughly half of a 50%-flaky crash, and the user would rather have
    # the lane back sooner and catch it on the next red run. `-CatchAttempts 2`
    # when you are hunting a specific intermittent crash and want the odds.
    [int]$CatchAttempts = 1,
    [int]$CatchTimeoutSeconds = 600,
    # Run this command as if it were a lane, instead of a zig lane. The whole
    # watchdog (CPU/stall/timeout) and the whole crash path apply to it, which
    # is what makes the crash wiring testable end to end without staging a real
    # red lane: point it at a binary that dies and watch which evidence path the
    # script takes.
    [string]$Command,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Decodes a crashed child's truncated exit code and reads the Windows crash log
# (T444). Without it a lane can end on a bare "exited with error code 5".
. "$PSScriptRoot\lib\CrashDiag.ps1"
# Re-runs a crashed test binary under cdb for a dump and every thread's stack
# (T450). Zig's own handler dies in a recursive panic, so without this a crash
# leaves no stack at all -- see scripts/lib/CrashCatch.ps1.
. "$PSScriptRoot\lib\CrashCatch.ps1"
# Reads the dump Windows already wrote at the moment of the crash (T460), which
# is the same evidence without the re-run -- and is the ONLY thing that works
# for a crash that does not reproduce.
. "$PSScriptRoot\lib\CrashDump.ps1"
# Recognizes a torn zig-cache entry (a zero-filled generated file failing the
# compile as if the code were red) and deletes exactly that entry, so a lane
# can heal itself and retry once instead of reporting a phantom FAIL (T494).
. "$PSScriptRoot\lib\CacheHeal.ps1"

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
        'lib' { return '-Dapp-runtime=none' }             # compiles lib ghostty
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
    # The caller's cache-heal check (T494) needs the log of the run that just
    # failed; the return value stays a bare verdict string on purpose.
    $script:LastLaneLog = $log

    if ($RawCommand) {
        # Self-test: the same watchdog loop over a synthetic command, so the
        # detector is exercised without waiting on a real 30-minute wedge.
        $cmd = "$RawCommand > `"$log`" 2>&1"
        Write-Host "LANE $Name run $Iteration/$Repeat : $RawCommand"
    }
    else {
        $buildArgs = Get-LaneArgs -Name $Name
        # `lib` runs no tests, so a test filter would only mislead the log line
        # into claiming a filtered run happened.
        if ($Filter -and $Name -ne 'lib') { $buildArgs = "$buildArgs -Dtest-filter=`"$Filter`"" }

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

        # T444 names the crashed process and its fault offset. That is a
        # suspect, not a stack -- and Zig's segfault handler cannot supply one
        # here, because it dies in a recursive panic while walking the stack.
        # So re-run the binary that died under cdb: first-chance, every thread,
        # full dump. The thread that corrupted memory is usually not the thread
        # that faulted, which is the whole reason this is worth the minutes.
        if (-not $NoCatch) { Invoke-LaneCrashCatch -Since $started -LaneLog $log }
    }
    return $result
}

function Invoke-LaneCrashCatch {
    <#
    .SYNOPSIS
        Capture a stack for whichever of OUR test binaries just crashed.
    .DESCRIPTION
        Deliberately narrow: it only fires when the Windows Application log
        recorded a crash in a binary this repo builds. A lane that failed on a
        compile error, or one where the compiler itself died (T451), gets
        nothing and costs nothing.
    #>
    param([Parameter(Mandatory)][datetime]$Since, [string]$LaneLog)

    $cdb = Get-CdbPath
    if (-not $cdb) {
        Write-Host '-- crash stack --'
        Write-Host '  no cdb.exe found, so no stack was captured (scripts\crash-catch.ps1 explains where it is looked for)'
        return
    }
    $ours = @(Get-ProcessCrashEvent -Since $Since | Where-Object { $TEST_EXE_NAMES -contains $_.App })
    if ($ours.Count -eq 0) { return }

    $name = $ours[0].App
    # The lane log names the exact binary zig was running; newest-by-write-time
    # is only the fallback, and it can point at the other lane's copy of the
    # same exe name.
    $exe = $null
    if ($LaneLog) { $exe = Get-FailingTestBinaryFromLog -LogPath $LaneLog -Repo $Repo }
    if ($exe -and ((Split-Path -Leaf $exe) -ne $name)) { $exe = $null }
    if (-not $exe) { $exe = Get-NewestBuiltBinary -Name $name -Repo $Repo }
    if (-not $exe) {
        Write-Host "-- crash stack --"
        Write-Host "  $name crashed but no built copy was found under $Repo\.zig-cache\o"
        return
    }
    # FIRST, the crash that actually happened. Windows wrote a dump of it at
    # the moment it died (WER LocalDumps), so the stack is already on disk --
    # every thread, source lines, seconds to read, and no reproduction needed.
    # The re-run below can only ever describe a DIFFERENT crash, and only when
    # the bug obliges by happening twice (T460).
    # The Application Error event has already been logged by the time we get
    # here, so WER has finished writing; 10s is slack, not a poll budget.
    $dump = Find-WerCrashDump -ExeNames @($name) -Since $Since -WaitSeconds 10
    if ($dump) {
        Write-Host "-- reading the dump Windows wrote when $name died (no re-run) --"
        try {
            $sym = Split-Path -Parent $exe
            $r = Invoke-CrashDumpAnalysis -DumpPath $dump.FullName -SymbolPath $sym `
                -Repo $Repo -LaneLog $LaneLog
            if (Write-CrashDumpStack -Result $r) { return }
            Write-Host '  that dump carried no exception, so the re-run below is the fallback'
        }
        catch {
            Write-Host "  reading the dump failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "-- no dump was written when $name died --"
        $null = Write-WerArmedStatus -ExeNames @($name)
    }

    Write-Host "-- capturing a stack for $name under cdb (up to $CatchAttempts attempt(s); -NoCatch to skip) --"
    try {
        $r = Invoke-CrashCatch -Exe $exe -Attempts $CatchAttempts `
            -TimeoutSeconds $CatchTimeoutSeconds -Repo $Repo
        $null = Write-CrashStack -Result $r
    }
    catch {
        Write-Host "  crash-catch failed: $($_.Exception.Message)"
    }
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

if ($Command) {
    $r = Invoke-Lane -Name 'command' -Iteration 1 -RawCommand $Command
    Write-Host ""
    Write-Host "FLOOR SUMMARY: command=$r"
    switch ($r) {
        'PASS' { exit $EXIT_PASS }
        'STALL' { exit $EXIT_STALL }
        'TIMEOUT' { exit $EXIT_TIMEOUT }
    }
    exit $EXIT_FAIL
}

# `lib` runs first: it is the cheapest lane by far and it is a pure compile, so
# a shared-core break is reported in seconds instead of after two test lanes.
$lanes = if ($Lane -eq 'all') { @('lib', 'none', 'win32', 'agent') } else { @($Lane) }
$worst = $EXIT_PASS
$summary = @()

foreach ($l in $lanes) {
    # At most ONE cache heal per lane per invocation (T494): a FAIL whose
    # compile errors point INTO a zig cache is a torn cache entry, not red
    # code, so delete that entry and re-run once. The re-run's verdict is
    # final -- a genuine failure simply fails again and is reported as such.
    $healedThisLane = $false
    for ($i = 1; $i -le $Repeat; $i++) {
        $r = Invoke-Lane -Name $l -Iteration $i
        if ($r -eq 'FAIL' -and -not $healedThisLane -and $script:LastLaneLog) {
            $torn = @(Get-TornCacheEntry -LogPath $script:LastLaneLog -RepoPath $Repo -GlobalCacheDir $cacheDir)
            if ($torn.Count -gt 0) {
                $healedThisLane = $true
                $warn = @(Get-CacheCorruptionWarning -LogPath $script:LastLaneLog)
                if ($warn.Count -gt 0) {
                    Write-Host "CACHE HEAL corroboration: $($warn.Count) invalid-timestamp warning(s) in the same log"
                }
                $removed = Invoke-CacheHeal -Entries $torn
                Write-Host "LANE $l healed $removed torn cache entr(y/ies); re-running once (a second FAIL is final)"
                $r = Invoke-Lane -Name $l -Iteration $i
            }
        }
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
