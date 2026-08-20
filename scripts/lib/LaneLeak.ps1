<#
.SYNOPSIS
    Find, explain and reap the test binaries a floor lane leaves running after
    it has already reported its verdict (T837).

.DESCRIPTION
    Measured 2026-08-14: the agent lane printed `LANE agent PASS in 191s` and
    stopped writing its log at 14:15:20, while `ghoztty-agent-test.exe` (pid
    4136) and `ghoztty-agent-core-test.exe` (pid 14704) -- both started 14:12:14
    by that lane -- were still alive at 14:40 with their CPU frozen at ~122s.
    Nothing looked for them: floor-lane.ps1 sweeps leaked WebView2 hosts and
    reports `leaked webview hosts swept: N`, and a leaked TEST BINARY was
    invisible to that filter (it is neither an msedgewebview2.exe nor a member
    of the lane's process tree once the tree is gone).

    So the first job here is COUNTING, not cleaning: a leak nobody measures is
    a leak that gets rediscovered by accident every few weeks. Every lane run
    now ends with a `leaked test binaries: N` number, on the same line as the
    webview count, whether or not anything leaked.

    Identity, and why it cannot just be "a test binary is running": the lane's
    process tree is already gone when we look, so parentage is not available.
    A leak is therefore a process that (a) carries one of the lane's test-binary
    names, (b) was NOT running when this lane started, and (c) was created at or
    after this lane started. (b) is what keeps a sweep from reaching into a
    binary somebody else was already running -- including a debugger session a
    human left attached -- and (c) is belt and braces on top of it. The one case
    this cannot separate is a SECOND floor run overlapping this one, which the
    house rules already forbid (go.md step 3: lanes and acceptance scripts run
    sequentially, never overlapped).

    Functions, split so the caller owns the policy and a test can drive each
    one without staging a real 30-minute lane:

      Get-LaneTestProcess    the test binaries alive right now
      Get-LeakedLaneProcess  ...minus the ones that were already there, plus the
                             created-after-the-lane-started rule
      Get-LeakedProcessStack a non-invasive `cdb -pv -p <pid>` stack for one of
                             them, which is what turns "it leaked again" into a
                             named wait
      Get-SelfSpawnedTestPids  the pids in a live tree that are a test binary
                             under a test binary -- the shape of a self-spawn,
                             and the CPU the stall detector must not count
      Test-BuildRunnerCommandLine  did the build runner launch this, or did the
                             code under test launch its own image?
      Invoke-LaneLeakSweep   report each leak loudly, capture its stack, kill it

    Explaining before killing is the point of the ordering: the sweep is
    cleanup, and cleanup that destroys the evidence guarantees the underlying
    bug is still unexplained the next time it happens.
#>

function Get-LaneTestProcess {
    <#
    .SYNOPSIS
        Live processes whose image name is one of the lane's test binaries.
    .OUTPUTS
        One object per process: ProcessId, Name, ExecutablePath, CreationDate,
        CpuSeconds. Empty when nothing matches, which is the normal case.
    #>
    param([Parameter(Mandatory)][string[]]$ExeNames)
    $out = @()
    foreach ($n in $ExeNames) {
        if (-not $n) { continue }
        $procs = Get-CimInstance Win32_Process -Filter "Name='$n'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $cpu = 0.0
            if ($null -ne $p.UserModeTime) {
                $cpu = [math]::Round(([double]$p.UserModeTime + [double]$p.KernelModeTime) / 10000000.0, 1)
            }
            $out += [pscustomobject]@{
                ProcessId       = [int]$p.ProcessId
                ParentProcessId = [int]$p.ParentProcessId
                Name            = [string]$p.Name
                ExecutablePath  = [string]$p.ExecutablePath
                # The command line is what NAMES the leak's cause: the build
                # runner launches a test binary with `--listen=-`, and anything
                # else is the code under test spawning its own image (T933).
                CommandLine     = [string]$p.CommandLine
                CreationDate    = $p.CreationDate
                CpuSeconds      = $cpu
            }
        }
    }
    # Plain return, no comma: callers wrap in @(). A `return ,$out` makes an
    # EMPTY result count as one item at an @() call site (PS 5.1 trap).
    return $out
}

function Get-LeakedLaneProcess {
    <#
    .SYNOPSIS
        The test binaries THIS lane started and did not take with it.
    .PARAMETER ExcludePids
        The pids that already carried a test-binary name before the lane
        launched. Anything on this list is somebody else's process and is never
        reported or killed, however long it has been running.
    .PARAMETER Since
        When the lane launched. A matching process created before this is not
        ours even if its pid was recycled into existence a moment later.
    .PARAMETER SkewSeconds
        Slack on -Since, because Win32_Process.CreationDate and Get-Date are
        read from different clocks and a binary launched in the same second as
        the lane must not be excluded by a few hundred milliseconds.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ExeNames,
        [int[]]$ExcludePids = @(),
        [datetime]$Since,
        [int]$SkewSeconds = 5
    )
    $exclude = @{}
    # Same null rule as the tree parameters (T982): a caller whose "pids that
    # were already running" sample found none passes an unrolled $null, and
    # `[int]$null` is 0 -- which would quietly put the idle process on the
    # exclude list instead of leaving it empty.
    foreach ($p in @($ExcludePids)) { if ($null -eq $p) { continue }; $exclude[[int]$p] = $true }
    $cutoff = $null
    if ($PSBoundParameters.ContainsKey('Since')) { $cutoff = $Since.AddSeconds(-$SkewSeconds) }

    $out = @()
    foreach ($p in @(Get-LaneTestProcess -ExeNames $ExeNames)) {
        if ($exclude.ContainsKey($p.ProcessId)) { continue }
        if ($cutoff -and $p.CreationDate -and $p.CreationDate -lt $cutoff) { continue }
        $out += $p
    }
    return $out
}

function Test-BuildRunnerCommandLine {
    <#
    .SYNOPSIS
        Was this test binary launched by the ZIG BUILD RUNNER, or by something
        else?
    .DESCRIPTION
        The build runner speaks to a test binary over stdin/stdout and always
        passes `--listen=-`. Every other command line on a test binary image is
        the code under test spawning its OWN exe -- which inside a test build is
        the test runner, not the product (T933). An empty/unreadable command
        line is treated as the build runner's: a leak is reported either way,
        and only the EXPLANATION line differs, so the uncertain case must not
        accuse.
    #>
    param([string]$CommandLine)
    if (-not $CommandLine) { return $true }
    return ($CommandLine -like '*--listen=-*')
}

function Get-SelfSpawnedTestPids {
    <#
    .SYNOPSIS
        The pids in a lane's process tree that are a test binary launched BY a
        test binary -- plus everything under them.
    .DESCRIPTION
        The build runner launches each test binary directly, so a test binary
        whose ANCESTOR is also a test binary is never a legitimate step of the
        lane: it is the code under test spawning its own image (T933). That
        distinction is what keeps the stall detector honest. The detector calls
        any CPU in the tree "progress", so a self-spawned copy of the suite --
        which burns a core running every test again, and hosts a tree of
        WebView2 children while it does -- reads as a lane that is working. It
        is the opposite: the lane is waiting, and the noise is the bug.

        Descendants are included because the copy's own children (its shells,
        its WebView2 hosts) are its CPU too, and counting them would leave the
        detector fooled by the same run through a different process.
    .PARAMETER Tree
        Process objects carrying ProcessId, ParentProcessId and Name -- e.g.
        floor-lane.ps1's Get-ProcessTree output, or a CIM snapshot.

        $null is accepted and means the same thing as an empty tree (T982).
        `Mandatory` on its own REFUSES null, and a caller cannot always tell it
        is passing one: a PS 5.1 function returning an empty collection unrolls
        it to $null on the way out, so a sample that found no processes -- a
        tree whose root exited a millisecond ago, or a CIM query that came back
        empty on a loaded box -- arrives here as null and used to abort the
        whole floor run with a binding exception instead of failing one lane.
        A watchdog that dies on the sample it took is worse than no watchdog.
    .PARAMETER ExeNames
        The lane's test-binary image names.
    .OUTPUTS
        [int[]] pids. Empty (the normal case) when nothing self-spawned.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Tree,
        [Parameter(Mandatory)][string[]]$ExeNames
    )
    $names = @{}
    foreach ($n in @($ExeNames)) { if ($n) { $names[$n.ToLowerInvariant()] = $true } }

    $byPid = @{}
    $kids = @{}
    foreach ($p in @($Tree)) {
        if ($null -eq $p) { continue }
        $id = [int]$p.ProcessId
        $byPid[$id] = $p
        $par = [int]$p.ParentProcessId
        if (-not $kids.ContainsKey($par)) { $kids[$par] = New-Object System.Collections.ArrayList }
        $null = $kids[$par].Add($id)
    }

    function Test-IsTestBinary($proc) {
        if ($null -eq $proc) { return $false }
        $n = [string]$proc.Name
        if (-not $n) { return $false }
        return $names.ContainsKey($n.ToLowerInvariant())
    }

    # Roots: a test binary with a test-binary ancestor INSIDE this tree.
    $roots = @()
    foreach ($id in @($byPid.Keys)) {
        if (-not (Test-IsTestBinary $byPid[$id])) { continue }
        $cur = [int]$byPid[$id].ParentProcessId
        $guard = 0
        while ($byPid.ContainsKey($cur) -and $guard -lt 64) {
            if (Test-IsTestBinary $byPid[$cur]) { $roots += [int]$id; break }
            $cur = [int]$byPid[$cur].ParentProcessId
            $guard++
        }
    }

    # ...and everything under each root.
    $out = @{}
    foreach ($r in $roots) {
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([int]$r)
        while ($queue.Count -gt 0) {
            $cur = [int]$queue.Dequeue()
            if ($out.ContainsKey($cur)) { continue }
            $out[$cur] = $true
            if ($kids.ContainsKey($cur)) {
                foreach ($c in $kids[$cur]) { $queue.Enqueue([int]$c) }
            }
        }
    }
    $ids = @()
    foreach ($k in @($out.Keys)) { $ids += [int]$k }
    return $ids
}

function Get-LeakedProcessStack {
    <#
    .SYNOPSIS
        Every thread's stack for a leaked process, without killing it.
    .DESCRIPTION
        `cdb -pv -p <pid>` attaches NON-INVASIVELY: the target is not stopped,
        not modified and not owned by the debugger, so a hung process can be
        read and left exactly as it was for anything else that wants to look.
        `~*k` is the whole point -- a leaked binary with frozen CPU is waiting
        on something, and the wait names the bug.
    .OUTPUTS
        The transcript path on success, $null when no stack could be taken
        (no cdb, attach refused, or the process died first).
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$CdbPath,
        [Parameter(Mandatory)][string]$OutDir,
        [string]$SymbolPath,
        [int]$TimeoutSeconds = 90
    )
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $OutDir "lane-leak-$ProcessId-$stamp.log"

    # -pv attach, run every thread's stack, quit. `q` after a non-invasive
    # attach detaches; it does not kill the target (which the caller does
    # itself, deliberately, once the evidence is on disk).
    $argList = @('-pv', '-p', "$ProcessId", '-lines')
    if ($SymbolPath) { $argList += @('-y', "`"$SymbolPath`"") }
    $argList += @('-c', '"~*k; q"')

    try {
        $p = Start-Process -FilePath $CdbPath -ArgumentList ($argList -join ' ') `
            -RedirectStandardOutput $log -NoNewWindow -PassThru
        $null = $p.Handle
    }
    catch {
        return $null
    }
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
        return $null
    }
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    # A refused attach still writes a transcript, so judge on content: a real
    # capture always contains at least one thread header.
    $body = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
    if (-not $body -or $body -notmatch '(?m)^\s*#?\s*\d+\s+Id:') { return $null }
    return $log
}

function Invoke-LaneLeakSweep {
    <#
    .SYNOPSIS
        Report every leaked lane test binary, explain it, then reap it.
    .DESCRIPTION
        Loud by construction, in the shape of the CACHE HEAL lines: one
        `LANE LEAK` line per process naming what it is, when it started, how
        much CPU it has burned and how long it has outlived its lane, then
        either the stack that was captured or why there is none, then whether
        it was killed. A leak that is only ever a number in a summary line is
        one nobody can act on.
    .PARAMETER NoKill
        Report and explain, leave the processes alone (floor-lane's -NoSweep).
    .OUTPUTS
        Found / Swept / Stacks, so the caller can put the count on its own
        summary line.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Leaked,
        [string]$CdbPath,
        [string]$OutDir,
        [int]$StackTimeoutSeconds = 90,
        [switch]$NoStack,
        [switch]$NoKill
    )
    # Null is an empty leak set, not a leak (T982): an empty result unrolls to
    # $null on the way out of a PS 5.1 function, and `@($null)` is a ONE-element
    # array holding null -- so counting it straight would report a phantom leak
    # with no pid, on exactly the runs where nothing leaked.
    $found = @(@($Leaked) | Where-Object { $null -ne $_ })
    $swept = 0
    $stacks = @()
    if ($found.Count -eq 0) {
        return [pscustomobject]@{ Found = 0; Swept = 0; Stacks = @() }
    }

    $now = Get-Date
    foreach ($p in $found) {
        $age = ''
        if ($p.CreationDate) {
            $mins = [int]([math]::Round(($now - $p.CreationDate).TotalMinutes))
            $age = " started=$($p.CreationDate.ToString('HH:mm:ss')) age=${mins}m"
        }
        Write-Host ("LANE LEAK: {0} pid={1} still running after the lane's verdict (cpu={2}s{3})" -f `
                $p.Name, $p.ProcessId, $p.CpuSeconds, $age)
        if ($p.PSObject.Properties['CommandLine']) {
            if ($p.CommandLine) { Write-Host "  launched as: $($p.CommandLine)" }
            if (-not (Test-BuildRunnerCommandLine -CommandLine $p.CommandLine)) {
                # The whole diagnosis, on the line where the leak is reported:
                # this copy was started by the code under test, which inside a
                # test build means the test runner was spawned as if it were the
                # product (T933, src/os/self_exe.zig).
                Write-Host '  SELF-SPAWN: the code under test launched its own image (no --listen=-, so this is not the build runner)'
            }
        }

        if (-not $NoStack -and $CdbPath -and $OutDir) {
            $sym = $null
            if ($p.ExecutablePath) { $sym = Split-Path -Parent $p.ExecutablePath }
            $stack = Get-LeakedProcessStack -ProcessId $p.ProcessId -CdbPath $CdbPath `
                -OutDir $OutDir -SymbolPath $sym -TimeoutSeconds $StackTimeoutSeconds
            if ($stack) {
                Write-Host "  stack (all threads, non-invasive): $stack"
                $stacks += $stack
            }
            else {
                Write-Host '  no stack: the non-invasive attach produced none (process gone, or attach refused)'
            }
        }
        elseif (-not $NoStack) {
            Write-Host '  no stack: no cdb.exe found (scripts\crash-catch.ps1 explains where it is looked for)'
        }

        if ($NoKill) {
            Write-Host '  left running (-NoSweep)'
            continue
        }
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $swept++
            Write-Host '  swept'
        }
        catch {
            Write-Host "  could not stop it: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Found = $found.Count; Swept = $swept; Stacks = $stacks }
}
