<#
.SYNOPSIS
    Run a built test binary N times and report how many runs CRASHED. T473.

.DESCRIPTION
    The T443 corruption lands on roughly half of runs, which makes every
    single-run result worthless: "it passed" and "it is fixed" look identical.
    Every claim about that signal therefore needs a run count behind it, and
    this is the thing that produces one.

    It runs the LANE, through `zig build`, and separates the three outcomes
    that a bare exit code smears together. Running the binary straight out of
    .zig-cache is cheaper and was the original behaviour, but T832 measured
    what that costs: the T443 corruption has never once been observed in a
    directly-launched process (~200 runs, 0 crashes -- including the exact
    binary that had dumped three times that morning), against 5 aborts in 26
    build-runner lane runs on the same box on 2026-08-14. `zig build` passes
    `--listen=-`, so `lib/compiler/test_runner.zig` takes `mainServer()` and
    drives one test per pipe message instead of `mainTerminal()`'s back-to-back
    loop -- a different scheduling pattern and a different set of stack
    leftovers under every test. So a standalone soak can report "all clear"
    indefinitely while the defect is still there; it is still available behind
    `-Mode standalone`, and it says so in its own output.

    The three outcomes:

      CRASH   - the process died on an exception. `std.process.Child` truncates
                a Windows exit code to a byte, so this is recognised from the
                stderr signature AND the low-byte NTSTATUS decode, then
                confirmed against the Windows `Application Error` log.
      FAIL    - the tests ran and some failed. A real red test, not a crash.
      PASS    - clean.

    Comparing two configurations (a control arm and a suspect arm) is the whole
    point: pass -Label so the two summaries are told apart in a transcript.

.PARAMETER Lane
    Which lane to soak. In build-runner mode this is the `zig build` target;
    in standalone mode it selects the newest test binary that lane built
    (`agent` covers both agent test binaries, soaking each in turn).

.PARAMETER Mode
    build-runner (the default whenever -Lane is given) repeats the lane through
    `zig build`, which is the only condition T443 has ever been seen in.
    standalone runs the built exe directly -- faster, and structurally unable
    to reproduce T443; it prints a warning saying so. -Exe is always
    standalone, because a bare exe has no lane to build.

.PARAMETER NoCatch
    Build-runner mode only: pass -NoCatch to floor-lane.ps1, so a crashed run
    is not re-run under cdb. Skips a couple of minutes per crash when the crash
    RATE is what is being measured rather than any single stack.

.PARAMETER Concurrency
    Standalone mode only. Run this many copies of the binary AT THE SAME TIME
    per round (default 1, which is the original sequential behaviour). Lane
    runs are never overlapped (T401): a lane starved by another lane wedges,
    and a wedge is not a data point.

    This is not a speed knob, it is the experiment. Every T443 crash was
    observed under `zig build` / `floor-lane.ps1`, which has several test
    processes and compiles in flight at once; every clean run -- 47 of them,
    including the byte-identical binary that produced the 07:13 dump -- was a
    single process on an idle box. A signal that needs the machine
    oversubscribed to appear cannot be soaked for one process at a time, which
    is how 47 runs of a "50% flaky" crash came back green and told us nothing.

.PARAMETER LoadWorkers
    Build-runner mode only. Hold N CPU/allocation-churning worker processes on
    the box for the whole soak, so the lane runs on a BUSY machine.

    This is the other half of the -Concurrency experiment, and it exists
    because T443's two variables were never crossed. Load was tested only in
    standalone mode (32 copies of the crash-day binary at once, 0 crashes) --
    the condition the defect has never once occurred in. The build runner was
    tested only on a quiesced box (15 sequential agent-lane runs on 2026-08-14,
    0 crashes). Yet every abort that task has ever recorded arrived while
    something ELSE was compiling or testing on the box: 5 in 26 runs the same
    morning, then nothing once it went quiet. `build-runner x loaded` is the
    cell with all the sightings in it and no measurement.

    The workers are ordinary processes burning CPU and churning 4 MB
    allocations -- they cannot touch the lane's memory, so what they vary is
    scheduling and memory-manager timing, which is what a latent race needs.
    They self-expire on a deadline as well as being killed at the end, so an
    interrupted soak cannot leave the box loaded.

    -LoadKind chooses WHAT the workers do; see it for the compile-shaped load,
    which is the shape the sightings actually had.

.PARAMETER LoadKind
    What each load worker does. The default `cpu` is the spin+allocate body
    described under -LoadWorkers. The other two run a REAL COMMAND in a loop,
    because CPU load is not the condition T443 was ever seen in:

      build   - each worker loops a cold `zig build` of a test lane, so the box
                carries compiler processes, page faults, disk and heap-manager
                traffic, not just cycles. Every sighting arrived while another
                compile+test lane was running; 16 spin workers cost the measured
                lane only ~13% wall clock (192s -> 217s) and produced 0 crashes
                in 8 runs (T443 turn 6), which is why this exists. Each worker
                gets a PRIVATE local cache and prefix (the build manifest and
                its locks are the hazard) and shares the already-populated
                global package cache, so it compiles this repo's source rather
                than rebuilding freetype on every pass.
      command - each worker loops the command line given by -LoadCommand.

    Both write one line per completed iteration, and the count lands in the
    summary: a load claim nobody measured is exactly what T832 had to unwind.

.PARAMETER LoadCommand
    The command line a `command`-kind worker loops. Giving it implies
    -LoadKind command.

    A load command MUST NOT share the measured lane's zig cache. A second
    `zig build` in this repo takes the same cache manifest locks, so it can
    stall -- or be stalled by -- the lane whose timing is being measured, and a
    wedged lane is not a data point (T401). A `zig build` load command without
    an explicit `--cache-dir` is therefore refused rather than run; `-LoadKind
    build` composes the isolated form for you.

.PARAMETER LoadWorkDir
    Scratch root for command/build workers: one `w<N>` directory each, holding
    the generated worker script, its log, its iteration file and (build kind)
    its private zig cache. Defaults to a directory on the REPO'S DRIVE, because
    zig 0.15.2 asserts when a global cache lives on a different drive than the
    build's cwd (T243). Private build caches are removed when the soak ends;
    logs are kept.

.PARAMETER LoadDryRun
    Compose the load, print what each worker would run, and exit without
    starting a worker or a round. For checking an isolation flag before
    spending an hour of soak on it.

.OUTPUTS
    A per-run table and a final one-line summary:
        SOAK <label>: mode=M runs=N pass=P fail=F crash=C  crash-rate=C/N (xx%)
    In build-runner mode the summary also carries `load=N:<kind>` and, for a
    command-shaped load, `load-iters=N` -- because a run count that does not
    name its condition is what T832 had to throw away, and a load nobody
    measured is a condition nobody can check.
    Exit 0 = no crashes, 1 = at least one crash, 2 = could not run.

.EXAMPLE
    powershell -NoProfile -File scripts\test-binary-soak.ps1 -Lane agent -Runs 10
.EXAMPLE
    # The condition every T443 sighting was actually in: the agent lane
    # measured while two isolated `zig build test` loops churn the box.
    powershell -NoProfile -File scripts\test-binary-soak.ps1 -Lane agent -Runs 10 `
        -LoadWorkers 2 -LoadKind build -Label T443-compileload
.EXAMPLE
    powershell -NoProfile -File scripts\test-binary-soak.ps1 -Exe .\zig-out\bin\x.exe -Runs 10
#>
[CmdletBinding()]
param(
    [ValidateSet('none', 'win32', 'agent')][string]$Lane,
    [string]$Exe,
    [ValidateSet('auto', 'build-runner', 'standalone')][string]$Mode = 'auto',
    [switch]$NoCatch,
    [string]$Filter = '',
    # Soak this command as if it were a lane (floor-lane.ps1 -Command). The
    # whole build-runner path -- watchdog, crash scan, classification -- runs
    # over it, which is how the mode is testable end to end without staging a
    # real intermittent crash. Same reason floor-lane grew -Command.
    [string]$LaneCommand = '',
    [string[]]$Arguments = @(),
    [int]$Runs = 10,
    [ValidateRange(1, 64)][int]$Concurrency = 1,
    [ValidateRange(0, 64)][int]$LoadWorkers = 0,
    [ValidateSet('cpu', 'build', 'command')][string]$LoadKind = 'cpu',
    [string]$LoadCommand = '',
    [string]$LoadWorkDir = '',
    [switch]$LoadDryRun,
    [string]$Label = '',
    [int]$TimeoutSeconds = 900,
    [string]$OutDir = "$env:TEMP\ghoztty-soak",
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\CrashCatch.ps1"
. "$PSScriptRoot\lib\CrashDiag.ps1"

# ------------------------------------------------------------- what to run

if (-not $Exe -and -not $Lane -and -not $LaneCommand) {
    Write-Host 'soak: pass -Lane <none|win32|agent> or -Exe <path>.'
    exit 2
}
if ($Exe -and $Mode -eq 'build-runner') {
    Write-Host 'soak: -Exe has no lane to build; use -Lane for build-runner mode.'
    exit 2
}
if ($LaneCommand -and $Mode -eq 'standalone') {
    Write-Host 'soak: -LaneCommand is a build-runner fixture; it has no standalone form.'
    exit 2
}

# The default is the condition the defect occurs in, not the cheap one (T832).
$mode = $Mode
if ($mode -eq 'auto') { $mode = if ($Exe) { 'standalone' } else { 'build-runner' } }
# floor-lane names a -Command run 'command', not after a lane.
$laneName = if ($LaneCommand) { 'command' } else { $Lane }

# Load is a build-runner instrument. Standalone already has -Concurrency for
# oversubscription, and it is the condition T443 has never occurred in, so
# loading it harder measures nothing new.
if (($LoadWorkers -gt 0 -or $LoadCommand -or $LoadKind -ne 'cpu') -and $mode -eq 'standalone') {
    Write-Host 'soak: -LoadWorkers is build-runner only (standalone has -Concurrency); ignoring it.'
    $LoadWorkers = 0
    $LoadKind = 'cpu'
    $LoadCommand = ''
}

# ------------------------------------------------------------ what the load IS
#
# The load knob started as CPU spinners, which is the one shape T443 has been
# measured NOT to reproduce under (0 crashes in 8 loaded runs, against 5 in 26
# unloaded-but-busy ones the same morning). Every sighting had another COMPILE
# AND TEST LANE on the box, so the load has to be able to take a command's
# shape, not just a CPU's.
if ($LoadCommand -and $LoadKind -eq 'cpu') { $LoadKind = 'command' }
if ($LoadKind -eq 'command' -and -not $LoadCommand) {
    Write-Host 'soak: -LoadKind command needs -LoadCommand "<command line>".'
    exit 2
}
if ($LoadKind -ne 'cpu' -and $LoadWorkers -eq 0) {
    # A command-shaped load with no workers is a silent no-op; one is the
    # shape the sightings had anyway (one other lane, not sixteen).
    $LoadWorkers = 1
}
# A second `zig build` in this repo shares the measured lane's cache manifest
# locks, so it can stall the very thing being timed -- and a wedged lane is not
# a data point (T401). The load must be discardable; the lane must not be.
if ($LoadKind -eq 'command' -and $LoadCommand -match 'zig\s+build' -and $LoadCommand -notmatch '--cache-dir') {
    Write-Host 'soak: a `zig build` load command must pass its own --cache-dir (and --global-cache-dir),'
    Write-Host '      or it takes the cache locks of the lane being measured and can wedge it (T401).'
    Write-Host '      Use -LoadKind build, which composes the isolated command per worker.'
    exit 2
}

# Private caches must sit on the REPO'S drive: zig 0.15.2 cannot make a cache
# path on one drive relative to a cwd on another and asserts instead (T243).
if (-not $LoadWorkDir) {
    $qual = Split-Path -Qualifier $Repo -ErrorAction SilentlyContinue
    $LoadWorkDir = if ($qual) { Join-Path ($qual + '\') 'ghoztty-soak-load' } else { Join-Path $OutDir 'load' }
}

$targets = @()
if ($mode -eq 'standalone') {
    if ($Exe) { $targets = @((Resolve-Path -LiteralPath $Exe).Path) }
    else {
        $targets = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
        if ($targets.Count -eq 0) {
            Write-Host "soak: nothing built for lane '$Lane' under $Repo\.zig-cache\o -- run the lane once first."
            exit 2
        }
    }
    # Only for OUR test binaries: a fixture exe has no build runner to be the
    # wrong side of, and a warning that cries wolf stops being read.
    $warnStandalone = [bool]$Lane -or
        (@($targets | Where-Object { (Split-Path -Leaf $_) -match '^(ghostty-test|ghoztty-agent(-core)?-test)\.exe$' }).Count -gt 0)
    if ($warnStandalone) {
        Write-Host 'soak: MODE=standalone -- the test binary is launched directly (mainTerminal).'
        Write-Host '      T443 has NEVER been observed in this condition: ~200 direct runs across that'
        Write-Host '      task with 0 crashes, including the exact binary that had dumped three times'
        Write-Host '      that morning, against 5 aborts in 26 build-runner lane runs on 2026-08-14.'
        Write-Host '      A green soak here is not evidence about T443. See T832; drop -Mode to use'
        Write-Host '      the build runner.'
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tag = if ($Label) { $Label } else { 'soak' }

# Stderr signatures that mean "the process died", not "a test failed". Zig's
# own segfault handler dies in a recursive panic on this box (T450), so the
# second line is as common as the first.
$crashPatterns = @(
    'Segmentation fault',
    'recursive panic',
    'General protection exception',
    'Illegal instruction',
    'Stack overflow',
    # A Zig panic aborts the process; the test runner never gets to report a
    # result for it. Four of the five 2026-08-14 T443 aborts arrived this way
    # ("thread 12188 panic: page map metadata pointer corrupted"), so a list
    # that only knows about faults classifies the signal it exists for as a
    # red test.
    'thread \d+ panic:'
)

# Extra signatures that only a lane transcript can carry: `zig build` names a
# crashed test command in its own words, and T444's decode turns the truncated
# NTSTATUS back into one.
$laneCrashPatterns = $crashPatterns + @(
    'the following test command crashed',
    'Access violation',
    'exited with error code (3|5)\b',
    'GHOZTTY-CRASH-BEGIN'
)

$totals = [ordered]@{ pass = 0; fail = 0; crash = 0; hang = 0 }
$rows = @()

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "soak: no such exe: $t"
        exit 2
    }
    $exeName = Split-Path -Leaf $t
    Write-Host ''
    Write-Host "soak: $exeName"
    Write-Host "      $t"
    Write-Host "      $Runs run(s), label='$tag'"

    # cmd.exe redirection, not PowerShell's: PS 5.1 wraps a native command's
    # stderr in ErrorRecords and can flip $? on a clean exit.
    $argLine = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '

    $started = 0
    while ($started -lt $Runs) {
        $batch = [math]::Min($Concurrency, $Runs - $started)
        if ($Concurrency -gt 1) {
            Write-Host ("  -- round: {0} concurrent, runs {1}-{2} --" -f $batch, ($started + 1), ($started + $batch))
        }

        $pending = @()
        for ($k = 1; $k -le $batch; $k++) {
            $idx = $started + $k
            $log = Join-Path $OutDir ("{0}-{1}-{2:d2}.log" -f $tag, $stamp, $idx)
            # ONE string, not an array: Start-Process does not quote the
            # elements of -ArgumentList, so an array is re-tokenised on spaces
            # (the T200 trap). The doubled outer quote is cmd's own /c rule --
            # it strips the first and last quote of the remainder.
            $cmdLine = '/c ""' + $t + '" ' + $argLine + ' > "' + $log + '" 2>&1"'
            $p = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -PassThru -WindowStyle Hidden
            # Touch .Handle BEFORE the child can exit, or PS 5.1 hands back an
            # EMPTY ExitCode later and every crash silently classifies as PASS.
            $null = $p.Handle
            $pending += [pscustomobject]@{
                Index = $idx; Log = $log; Proc = $p; Since = (Get-Date)
                Sw    = [System.Diagnostics.Stopwatch]::StartNew(); TimedOut = $false
            }
        }

        foreach ($e in $pending) {
            if (-not $e.Proc.WaitForExit($TimeoutSeconds * 1000)) {
                $e.TimedOut = $true
                try { $e.Proc.Kill() } catch {}
                try { $null = $e.Proc.WaitForExit(10000) } catch {}
            }
            $e.Sw.Stop()
        }

        $started += $batch

        foreach ($e in $pending) {
        $i = $e.Index
        $log = $e.Log
        $since = $e.Since
        # Wall time from launch to observed exit. Under -Concurrency this is
        # measured per process, so it is real elapsed time, not a share of it.
        $sw = $e.Sw
        $code = if ($e.TimedOut) { -1 } else { $e.Proc.ExitCode }

        $tail = ''
        if (Test-Path -LiteralPath $log) {
            $tail = (Get-Content -LiteralPath $log -Tail 40 -ErrorAction SilentlyContinue) -join "`n"
        }
        $sig = $false
        foreach ($p in $crashPatterns) { if ($tail -match $p) { $sig = $true; break } }

        # A nonzero code whose low byte decodes to a fatal NTSTATUS is a crash
        # SUSPICION on its own (a program really can exit(5)); the event log is
        # what turns it into evidence.
        # [array], and NOT `$cand = if (...) { @(...) }`: PowerShell 5.1 unrolls
        # the array an `if` expression produces, so a ONE-element result lands as
        # a bare object whose `.Count` is $null -- and `$null -gt 0` is false, so
        # every single-candidate crash silently classified as a red test.
        [array]$cand = @()
        if ($code -ne 0 -and -not $e.TimedOut) { $cand = @(Get-NtStatusCandidate -Code $code) }
        [array]$evt = @()
        if ($code -ne 0 -and -not $e.TimedOut -and ($sig -or $cand.Count -gt 0)) {
            # WER writes the `Application Error` record ASYNCHRONOUSLY, a second
            # or two after the process is already gone. Querying immediately
            # finds nothing and the run gets filed as a red test instead of a
            # crash -- which is the single worst mistake this script could make,
            # since the whole point is counting crashes. Give it a moment.
            foreach ($try in 1..4) {
                [array]$evt = @(Get-ProcessCrashEvent -Since $since.AddSeconds(-2) -NameLike $exeName)
                if ($evt.Count -gt 0) { break }
                Start-Sleep -Milliseconds 750
            }
        }

        $verdict = 'PASS'
        $note = ''
        if ($e.TimedOut) {
            $verdict = 'HANG'
            $totals.hang++
            $note = "no exit within ${TimeoutSeconds}s; killed"
        }
        elseif ($code -eq 0) {
            $totals.pass++
        }
        elseif ($sig -or $evt.Count -gt 0 -or $cand.Count -gt 0) {
            $verdict = 'CRASH'
            $totals.crash++
            if ($evt.Count -gt 0) {
                $note = "$($evt[-1].ExceptionCode) $($evt[-1].ExceptionName) $($evt[-1].Module)+$($evt[-1].FaultOffset)"
            }
            elseif ($cand.Count -gt 0) {
                $note = "exit $code -> $($cand[0].Hex) $($cand[0].Name) (no event record; suspicion only)"
            }
            else { $note = "exit $code" }
        }
        else {
            $verdict = 'FAIL'
            $totals.fail++
            $note = "exit $code"
            $failLine = ($tail -split "`n" | Where-Object { $_ -match 'passed;|error:' } | Select-Object -Last 1)
            if ($failLine) { $note += " | " + $failLine.Trim() }
        }

        # The victim test is the last one zig named before it died -- the single
        # most useful field in a crash run, and it is only in the log.
        $victim = ''
        if ($verdict -eq 'CRASH') {
            $v = ($tail -split "`n" | Where-Object { $_ -match '^\s*\d+/\d+\s+\S' } | Select-Object -Last 1)
            if ($v) { $victim = $v.Trim() }
        }

        $rows += [pscustomobject]@{
            Run     = $i
            Exe     = $exeName
            Verdict = $verdict
            Seconds = [int]$sw.Elapsed.TotalSeconds
            Note    = $note
            Victim  = $victim
            Log     = $log
        }
        $line = "  run {0,2}/{1}: {2,-5} {3,4}s" -f $i, $Runs, $verdict, [int]$sw.Elapsed.TotalSeconds
        if ($note) { $line += "  $note" }
        Write-Host $line
        if ($victim) { Write-Host "            victim: $victim" }
        }
    }
}

# ------------------------------------------------------ build-runner rounds
#
# One `zig build <lane>` per round, driven through floor-lane.ps1 so a round
# inherits its watchdog (a wedged lane is reported as a wedge rather than
# waited on forever) and its crash capture, instead of this script growing a
# second copy of both. Sequential by construction -- T401: an overlapped lane
# starves and wedges, and a wedge is not a data point.

# A background load worker: CPU burn plus 4 MB allocation churn. It cannot
# reach the lane's memory -- what it varies is scheduling and memory-manager
# timing, which is the whole point (see -LoadWorkers). The deadline is a
# safety net so a soak that is killed rather than finished cannot leave the
# box loaded for the next person.
function Start-SoakLoadWorkers {
    param([int]$Count, [int]$Seconds, [string]$PsExe)
    $body = '$d=(Get-Date).AddSeconds(' + $Seconds + ');$x=1;' +
    'while((Get-Date) -lt $d){for($i=0;$i -lt 300000;$i++){$x=($x*31+7)%1000003};' +
    '$b=New-Object byte[] 4194304;$b[0]=1;$b[4194303]=2;$b=$null}'
    $procs = @()
    for ($w = 0; $w -lt $Count; $w++) {
        try {
            $p = Start-Process -FilePath $PsExe `
                -ArgumentList ('-NoProfile -Command "' + $body + '"') `
                -PassThru -WindowStyle Hidden
            # PS 5.1: cache .Handle before the child can exit, or ExitCode and
            # HasExited come back empty later (the T473 trap).
            $null = $p.Handle
            $procs += $p
        }
        catch {}
    }
    return , $procs
}

# What a command/build worker would run, per worker index. Build kind composes
# a FULLY ISOLATED zig build: its own local cache, global cache and prefix, so
# it shares no lock and no output with the lane being measured.
function Get-SoakLoadWorkerSpec {
    param([string]$Kind, [int]$Index, [string]$WorkDir, [string]$Repo, [string]$Command)
    $dir = Join-Path $WorkDir ("w{0}" -f $Index)
    $cache = Join-Path $dir 'zig-cache'
    if ($Kind -eq 'build') {
        # A DIFFERENT lane than the one usually measured, and a real one: the
        # point is a compiler and a test binary on the box, not a no-op. The
        # local cache is wiped each iteration (below) or the second iteration
        # is a cache hit and the load quietly stops being a load.
        #
        # LOCAL cache private, GLOBAL cache shared, deliberately. The local
        # cache is where the build manifest and its locks live -- that is the
        # hazard, and it is isolated. The global cache is a content-addressed
        # store of fetched packages that is already populated, so sharing it
        # means the worker compiles OUR source (the shape the sightings had)
        # instead of rebuilding freetype and harfbuzz from scratch on every
        # iteration, which is slower, noisier, and not the load being asked for.
        $glob = if ($env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR }
        else {
            $q = Split-Path -Qualifier $Repo -ErrorAction SilentlyContinue
            if ($q) { Join-Path ($q + '\') 'zig-global-cache' } else { '' }
        }
        $cmd = 'zig build test -Dapp-runtime=none' +
        ' --cache-dir "' + $cache + '"'
        if ($glob) { $cmd += ' --global-cache-dir "' + $glob + '"' }
        $cmd += ' --prefix "' + (Join-Path $dir 'zig-out') + '"'
    }
    else { $cmd = $Command; $cache = '' }
    return [pscustomobject]@{
        Index = $Index; Dir = $dir; Command = $cmd; WipeCache = $cache
        Script = (Join-Path $dir 'worker.ps1'); Log = (Join-Path $dir 'worker.log')
        Iter = (Join-Path $dir 'iterations.txt')
    }
}

# Loop a real command until the deadline. Written to a FILE and launched with
# -File rather than assembled as a -Command one-liner: a build command carries
# quoted paths, and re-quoting those through two layers is the exact trap that
# has bitten this repo repeatedly (T200).
function Start-SoakCommandWorkers {
    param([int]$Count, [int]$Seconds, [string]$PsExe, [string]$Kind,
        [string]$WorkDir, [string]$Repo, [string]$Command, [int]$FirstIndex = 0)
    $deadline = (Get-Date).AddSeconds($Seconds).ToString('o')
    $procs = @()
    for ($w = 0; $w -lt $Count; $w++) {
        $spec = Get-SoakLoadWorkerSpec -Kind $Kind -Index ($FirstIndex + $w) -WorkDir $WorkDir -Repo $Repo -Command $Command
        New-Item -ItemType Directory -Force -Path $spec.Dir | Out-Null
        $body = @(
            '$ErrorActionPreference = ''Continue''',
            ('$deadline = [datetime]''' + $deadline + ''''),
            ('$wipe = ''' + $spec.WipeCache + ''''),
            ('$cmd = ''' + ($spec.Command -replace "'", "''") + ''''),
            ('$log = ''' + $spec.Log + ''''),
            ('$iter = ''' + $spec.Iter + ''''),
            ('Set-Location -LiteralPath ''' + $Repo + ''''),
            'while ((Get-Date) -lt $deadline) {',
            '    if ($wipe) { Remove-Item -LiteralPath $wipe -Recurse -Force -ErrorAction SilentlyContinue }',
            # STARTED is written before the command, not only DONE after it: a
            # build-kind iteration can legitimately outlive the whole soak, and
            # a load measured only by completions would report the heaviest
            # load available as no load at all.
            '    Add-Content -LiteralPath $iter -Value ((Get-Date).ToString(''o'') + " start")',
            '    $sw = [System.Diagnostics.Stopwatch]::StartNew()',
            '    & $env:ComSpec /c $cmd *>> $log',
            '    $sw.Stop()',
            '    Add-Content -LiteralPath $iter -Value ((Get-Date).ToString(''o'') + " exit=$LASTEXITCODE $([int]$sw.Elapsed.TotalSeconds)s")',
            '}'
        ) -join "`r`n"
        Set-Content -LiteralPath $spec.Script -Value $body -Encoding ASCII
        try {
            $p = Start-Process -FilePath $PsExe `
                -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $spec.Script + '"') `
                -WorkingDirectory $Repo -PassThru -WindowStyle Hidden
            # PS 5.1: cache .Handle before the child can exit (the T473 trap).
            $null = $p.Handle
            $procs += $p
        }
        catch {}
    }
    return , $procs
}

# Started and completed iterations, so `load=2:build` can be read with the work
# it actually did behind it rather than as a claim -- and so a build whose
# single iteration outlasts the soak (the normal case for the heaviest load
# this script offers) is not mistaken for no load at all.
function Get-SoakLoadIterations {
    param([string]$WorkDir, [int]$Count)
    $started = 0
    $done = 0
    for ($w = 0; $w -lt $Count; $w++) {
        $f = Join-Path (Join-Path $WorkDir ("w{0}" -f $w)) 'iterations.txt'
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ($line -match '\bstart$') { $started++ }
            elseif ($line -match '\bexit=') { $done++ }
        }
    }
    return [pscustomobject]@{ Started = $started; Completed = $done }
}

# Kill the worker AND anything it launched. A command worker's zig build is a
# grandchild, and killing only the worker orphans a compiler that then loads
# the box for the NEXT soak -- which would corrupt the very measurement this
# knob exists to make.
function Stop-SoakLoadWorkers {
    param($Procs)
    foreach ($p in @($Procs)) {
        try { if (-not $p.HasExited) { Stop-SoakProcessTree -Id $p.Id } } catch {}
    }
}

function Stop-SoakProcessTree {
    param([int]$Id, [int]$Depth = 0)
    if ($Depth -gt 6) { return }
    $kids = @()
    try {
        $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)
    }
    catch {}
    foreach ($k in $kids) { Stop-SoakProcessTree -Id ([int]$k.ProcessId) -Depth ($Depth + 1) }
    try { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue } catch {}
}

function Get-SoakLoadAlive {
    param($Procs)
    $n = 0
    foreach ($p in @($Procs)) {
        try { if (-not $p.HasExited) { $n++ } } catch {}
    }
    return $n
}

if ($mode -eq 'build-runner') {
    $laneScript = Join-Path $PSScriptRoot 'floor-lane.ps1'
    if (-not (Test-Path -LiteralPath $laneScript)) {
        Write-Host "soak: floor-lane.ps1 is not next to this script ($laneScript)."
        exit 2
    }
    # A lane run plus a cdb crash capture can outlast the standalone default.
    $roundTimeout = [math]::Max($TimeoutSeconds, 2400)
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }

    Write-Host ''
    if ($LaneCommand) { Write-Host "soak: build-runner, staged command: $LaneCommand" }
    else { Write-Host "soak: build-runner, lane '$Lane' (zig build)" }
    Write-Host "      $Runs round(s), label='$tag'"
    if ($Concurrency -gt 1) {
        Write-Host "      -Concurrency $Concurrency ignored here: lane runs are never overlapped (T401)"
    }

    # Held for the whole soak rather than per round, because the condition
    # being reproduced is "the box was busy", which in the sightings included
    # the build as well as the test run.
    $loadProcs = @()
    $loadDeadline = [math]::Min(14400, ($Runs * $roundTimeout) + 600)

    # One worker per slot index, so a top-up restarts the SLOT (same directory,
    # same private cache, same iteration file) rather than growing a new one.
    function Start-SoakLoadSlot {
        param([int]$Index)
        if ($LoadKind -eq 'cpu') {
            return @(Start-SoakLoadWorkers -Count 1 -Seconds $loadDeadline -PsExe $psExe)
        }
        return @(Start-SoakCommandWorkers -Count 1 -FirstIndex $Index -Seconds $loadDeadline `
                -PsExe $psExe -Kind $LoadKind -WorkDir $LoadWorkDir -Repo $Repo -Command $LoadCommand)
    }

    if ($LoadKind -ne 'cpu') {
        Write-Host "      load kind=$LoadKind, scratch: $LoadWorkDir"
        for ($w = 0; $w -lt [math]::Max(1, $LoadWorkers); $w++) {
            $spec = Get-SoakLoadWorkerSpec -Kind $LoadKind -Index $w -WorkDir $LoadWorkDir -Repo $Repo -Command $LoadCommand
            Write-Host "      worker $w runs: $($spec.Command)"
            if ($w -eq 0 -and $LoadWorkers -gt 1 -and $LoadKind -eq 'command') {
                Write-Host "      (all $LoadWorkers workers run the same command)"
                break
            }
        }
    }
    if ($LoadDryRun) {
        if ($LoadKind -eq 'cpu') {
            Write-Host "      load kind=cpu: $LoadWorkers spin+allocate worker(s), no command"
        }
        Write-Host ''
        Write-Host "soak: -LoadDryRun -- composed the load and started nothing. No rounds run."
        exit 0
    }

    if ($LoadWorkers -gt 0) {
        # This soak's count must be THIS soak's: a slot directory is reused
        # across runs (and by a top-up), so a leftover iteration file would
        # credit today's load with yesterday's work.
        if ($LoadKind -ne 'cpu') {
            for ($w = 0; $w -lt $LoadWorkers; $w++) {
                $spec = Get-SoakLoadWorkerSpec -Kind $LoadKind -Index $w -WorkDir $LoadWorkDir -Repo $Repo -Command $LoadCommand
                foreach ($f in @($spec.Iter, $spec.Log)) {
                    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        $loadSlots = @()
        for ($w = 0; $w -lt $LoadWorkers; $w++) {
            $procs = @(Start-SoakLoadSlot -Index $w)
            foreach ($p in $procs) { $loadSlots += [pscustomobject]@{ Index = $w; Proc = $p } }
        }
        $loadProcs = @($loadSlots | ForEach-Object { $_.Proc })
        Write-Host ("      -LoadWorkers ${LoadWorkers}: " +
            "$(Get-SoakLoadAlive $loadProcs) worker(s) holding the box busy")
    }

    for ($i = 1; $i -le $Runs; $i++) {
        # A worker that died (or hit its own deadline) would quietly turn a
        # loaded soak into a quiesced one halfway through, and the summary
        # would still claim the load. Top up instead -- by slot, so a command
        # worker comes back on its own directory and its iteration count keeps
        # accumulating.
        if ($LoadWorkers -gt 0) {
            foreach ($slot in @($loadSlots)) {
                $dead = $false
                try { $dead = $slot.Proc.HasExited } catch { $dead = $true }
                if (-not $dead) { continue }
                $again = @(Start-SoakLoadSlot -Index $slot.Index)
                if ($again.Count -gt 0) { $slot.Proc = $again[0] }
            }
            $loadProcs = @($loadSlots | ForEach-Object { $_.Proc })
        }

        $log = Join-Path $OutDir ("{0}-{1}-{2:d2}.log" -f $tag, $stamp, $i)
        $laneArgs = '-NoProfile -File "' + $laneScript + '" -Repeat 1'
        if ($LaneCommand) { $laneArgs += ' -Command "' + $LaneCommand + '"' }
        else { $laneArgs += ' -Lane ' + $Lane }
        if ($NoCatch) { $laneArgs += ' -NoCatch' }
        if ($Filter) { $laneArgs += ' -Filter "' + $Filter + '"' }
        # ONE string, and cmd's own doubled-outer-quote rule -- as above.
        $cmdLine = '/c ""' + $psExe + '" ' + $laneArgs + ' > "' + $log + '" 2>&1"'

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -PassThru -WindowStyle Hidden
        $null = $p.Handle
        $timedOut = $false
        if (-not $p.WaitForExit($roundTimeout * 1000)) {
            $timedOut = $true
            try { $p.Kill() } catch {}
            try { $null = $p.WaitForExit(10000) } catch {}
        }
        $sw.Stop()
        $code = if ($timedOut) { -1 } else { $p.ExitCode }

        # floor-lane's transcript names the lane log it wrote; the test output
        # (and the crash text) is in there, not in the transcript.
        $txt = ''
        $laneLog = ''
        $laneResult = ''
        if (Test-Path -LiteralPath $log) {
            $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
            $txt = $lines -join "`n"
            foreach ($l in $lines) {
                if ($l -match '^\s*log:\s*(\S.*)$') { $laneLog = $matches[1].Trim() }
                if ($l -match ('^LANE\s+' + [regex]::Escape($laneName) + '\s+(\w+)\s+in\s+')) { $laneResult = $matches[1] }
            }
        }

        $sig = $false
        foreach ($pat in $laneCrashPatterns) { if ($txt -match $pat) { $sig = $true; break } }
        if (-not $sig -and $laneLog -and (Test-Path -LiteralPath $laneLog)) {
            # Select-String, not Get-Content: a lane log is thousands of test
            # lines and this runs once per pattern per round.
            foreach ($pat in $laneCrashPatterns) {
                if (@(Select-String -LiteralPath $laneLog -Pattern $pat -List -ErrorAction SilentlyContinue).Count -gt 0) {
                    $sig = $true; break
                }
            }
        }

        $verdict = 'PASS'
        $note = ''
        if ($timedOut) {
            $verdict = 'HANG'; $totals.hang++
            $note = "no exit within ${roundTimeout}s; killed"
        }
        elseif ($code -eq 0) { $totals.pass++ }
        elseif ($laneResult -eq 'STALL' -or $laneResult -eq 'TIMEOUT' -or $code -eq 2 -or $code -eq 3) {
            $verdict = 'HANG'; $totals.hang++
            $note = "floor-lane reported $laneResult"
        }
        elseif ($sig) {
            $verdict = 'CRASH'; $totals.crash++
            $hitLine = ''
            foreach ($pat in $laneCrashPatterns) {
                $h = @($txt -split "`n" | Where-Object { $_ -match $pat } | Select-Object -First 1)
                if ($h.Count -eq 1) { $hitLine = $h[0].Trim(); break }
                if ($laneLog -and (Test-Path -LiteralPath $laneLog)) {
                    $h = @(Select-String -LiteralPath $laneLog -Pattern $pat -List -ErrorAction SilentlyContinue)
                    if ($h.Count -ge 1) { $hitLine = $h[0].Line.Trim(); break }
                }
            }
            $note = if ($hitLine) { $hitLine } else { "exit $code" }
        }
        else {
            $verdict = 'FAIL'; $totals.fail++
            $note = "exit $code"
            $failLine = ($txt -split "`n" | Where-Object { $_ -match 'error:|passed;' } | Select-Object -First 1)
            if ($failLine) { $note += ' | ' + $failLine.Trim() }
        }

        $victim = ''
        if ($verdict -eq 'CRASH' -and $laneLog -and (Test-Path -LiteralPath $laneLog)) {
            $v = @(Select-String -LiteralPath $laneLog -Pattern '^\s*\d+/\d+\s+\S' -ErrorAction SilentlyContinue |
                    Select-Object -Last 1)
            if ($v.Count -eq 1) { $victim = $v[0].Line.Trim() }
        }

        $rows += [pscustomobject]@{
            Run     = $i
            Exe     = "lane:$laneName"
            Verdict = $verdict
            Seconds = [int]$sw.Elapsed.TotalSeconds
            Note    = $note
            Victim  = $victim
            Log     = $log
        }
        $line = "  run {0,2}/{1}: {2,-5} {3,4}s" -f $i, $Runs, $verdict, [int]$sw.Elapsed.TotalSeconds
        if ($note) { $line += "  $note" }
        Write-Host $line
        if ($victim) { Write-Host "            victim: $victim" }
        if ($laneLog) { Write-Host "            lane log: $laneLog" }
    }

    if ($LoadWorkers -gt 0) {
        $loadAliveEnd = Get-SoakLoadAlive $loadProcs
        Stop-SoakLoadWorkers $loadProcs
        if ($LoadKind -ne 'cpu') {
            $it = Get-SoakLoadIterations -WorkDir $LoadWorkDir -Count $LoadWorkers
            $loadIters = $it.Completed
            $loadStarted = $it.Started
        }
        Write-Host ''
        $loadLine = "  load: $LoadWorkers worker(s) requested, $loadAliveEnd still running at the end"
        if ($LoadKind -ne 'cpu') { $loadLine += ", $loadIters iteration(s) completed of $loadStarted started" }
        Write-Host $loadLine
        # A worker that never STARTED an iteration is a load that was not
        # applied -- say so, rather than let a green soak imply a condition it
        # never had. The T832 lesson, applied to the knob instead of the mode.
        # A worker that started one and is still in it is the OPPOSITE case: a
        # cold `zig build` of a whole lane routinely outlasts the soak, and
        # counting only completions would report the heaviest load on offer as
        # none at all.
        if ($LoadKind -ne 'cpu' -and $loadStarted -eq 0) {
            Write-Host "  load: WARNING no worker even started an iteration -- this soak was effectively UNLOADED."
            Write-Host "        check $LoadWorkDir\w0\worker.log"
        }
        elseif ($LoadKind -ne 'cpu' -and $loadIters -eq 0) {
            Write-Host "  load: 0 completed, $loadStarted in flight at the end -- the load ran throughout and"
            Write-Host "        no iteration finished inside the soak, which is normal for -LoadKind build."
        }
        # The private build caches are multi-gigabyte and belong to nobody; the
        # logs and iteration files stay, because they are the evidence.
        if ($LoadKind -eq 'build') {
            for ($w = 0; $w -lt $LoadWorkers; $w++) {
                $spec = Get-SoakLoadWorkerSpec -Kind $LoadKind -Index $w -WorkDir $LoadWorkDir -Repo $Repo -Command $LoadCommand
                foreach ($d in @($spec.WipeCache, (Join-Path $spec.Dir 'zig-out'))) {
                    if (Test-Path -LiteralPath $d) {
                        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            Write-Host "  load: private build caches under $LoadWorkDir removed; worker logs kept"
        }
    }
}

$n = $rows.Count
$rate = if ($n -gt 0) { [math]::Round(100.0 * $totals.crash / $n) } else { 0 }
Write-Host ''
$conc = if ($mode -eq 'build-runner') { 1 } else { $Concurrency }
$summary = "SOAK {0}: mode={7} runs={1} concurrency={6} pass={2} fail={3} crash={4}  crash-rate={4}/{1} ({5}%)" -f `
    $tag, $n, $totals.pass, $totals.fail, $totals.crash, $rate, $conc, $mode
if ($totals.hang -gt 0) { $summary += "  hang=$($totals.hang)" }
# The condition, in the line that gets pasted into a task file. A soak number
# that does not name its condition is the mistake T832 had to unwind.
if ($mode -eq 'build-runner') {
    $summary += "  load=$LoadWorkers"
    # The KIND is part of the condition: 16 CPU spinners and 1 concurrent
    # compile are not the same box, and T443 has a measured 0/8 under the
    # first. A pasted `load=16` that does not say which is the ambiguity T832
    # had to unwind, one level down.
    if ($LoadWorkers -gt 0) { $summary += ":$LoadKind" }
    if ($LoadKind -ne 'cpu' -and $LoadWorkers -gt 0) { $summary += " load-iters=$loadIters started=$loadStarted" }
}
Write-Host $summary
if ($mode -eq 'standalone' -and $warnStandalone) {
    Write-Host '  NOTE: standalone -- see the warning above; this says nothing about T443 (T832).'
}
Write-Host "  logs: $OutDir"

# A hang is not a crash, but it is emphatically not a clean run either -- the
# whole point of this script is that "it exited 0" is the only thing allowed to
# read as green.
if ($totals.crash -gt 0 -or $totals.hang -gt 0) { exit 1 }
exit 0
