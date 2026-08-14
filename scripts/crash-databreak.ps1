<#
.SYNOPSIS
    Catch a wild write in the act: run a program under cdb with hardware data
    breakpoints armed on a function's spilled parameters, and stop at the
    instruction that writes them. T458.

.DESCRIPTION
    The T443/T454 corruption zeroes the spilled incoming parameters of a live
    Page.verifyIntegrity frame -- slots that are written once in the prologue
    and never legitimately touched again. `crash-catch.ps1` shows the wreckage
    after the fact; this tool watches the exact bytes and names the writer.

    Per call of the target function it: breaks after the prologue's spill run,
    arms `ba w8` hardware breakpoints on the canonical spill slots (computed
    from @rbp, so ASLR and stack depth do not matter), plants a one-shot
    breakpoint on the return address that disarms them, and continues. A hit
    inside the armed window prints the writing instruction, every thread's
    stack, and a full minidump. Measured cost: ~2 ms per call of the target.

    The prologue layout (which slots, where to arm, where the return address
    lives) is parsed from a disassembly probe at startup -- nothing is
    hardcoded, so the recipe survives rebuilds. See scripts/lib/DataBreak.ps1
    for the mechanics and the cdb traps this encodes.

.PARAMETER Lane
    Run the newest test binary a zig lane built, instead of naming an exe.
    `agent` covers both agent test binaries and tries them in turn.

.PARAMETER UnderBuildRunner
    Arm against the lane as `zig build` runs it, instead of launching the test
    binary directly. THIS IS THE DEFAULT FOR -Lane, and T832 is why: every
    T443 crash ever observed came from `zig build`, and ~200 direct runs of the
    same binaries -- including the exact one that had just dumped three times
    -- produced zero. `zig build` passes `--listen=-`, so the test runner takes
    `mainServer()` and drives one test per pipe message; a directly-launched
    binary takes `mainTerminal()` and runs them back to back. An instrument
    armed against the second condition can sit there forever and catch nothing.

    Mechanically: the lane is started detached, the script waits for the build
    runner to launch one of the lane's test binaries, and cdb ATTACHES to it
    (`-p`). Everything after that is the single-process recipe unchanged. The
    image path is read off the RUNNING process, so a lane that rebuilds -- or
    a `-Filter`, which builds a different binary -- is armed correctly rather
    than against a stale offset.

    Following children (`cdb -o`) was tried first and does not work here, for
    two measured reasons: `g` returns once per child attach, so a script ending
    in `g; q` quits at the first child, and `bu <module>+<rva>` is rejected
    ("Bp expression contains symbols not qualified with module name") because
    cdb reads a bare module name as a symbol.

.PARAMETER AttachTimeoutSeconds
    How long to wait for the build runner to reach the test step. Default 1200
    -- a cold lane compiles first.

.PARAMETER Standalone
    Launch the test binary directly (the pre-T832 behaviour). Kept for
    rehearsing the tool against a staged wild write, which is what it was
    proven with; it prints a warning naming the condition it measures.

.PARAMETER Filter
    `-Dtest-filter=<x>` for the build-runner lane. For smoke-testing the
    plumbing cheaply; a filtered lane is not a condition T443 reproduces in
    (T443 measured 20 consecutive clean runs of `-Dtest-filter=terminal.`).

.PARAMETER Symbol
    The function whose spilled parameters get armed. Default: verifyIntegrity
    (the T443 victim frame).

.PARAMETER SlotOffsets
    Explicit signed rbp-relative offsets to arm instead of the parsed spill
    slots (at most 4 -- x64 has four debug registers). The probe still
    supplies the arm point and the return slot.

.PARAMETER ShowProbe
    Print the parsed prologue (spills, armed slots, arm point, return slot)
    before running.

.OUTPUTS
    A `-- data breakpoint --` report.
    Exit 0 = ran clean (armed, no wild write observed), 1 = a wild write was
    caught, 2 = could not run (no cdb, no exe, probe failed), 3 = the program
    crashed without touching an armed slot (crash captured a la crash-catch).

.EXAMPLE
    powershell -NoProfile -File scripts\crash-databreak.ps1 -Lane agent
.EXAMPLE
    powershell -NoProfile -File scripts\crash-databreak.ps1 -Exe fixture.exe -Symbol victim -SlotOffsets -8
#>
[CmdletBinding()]
param(
    [ValidateSet('none', 'win32', 'agent')][string]$Lane,
    [string]$Exe,
    [switch]$UnderBuildRunner,
    [switch]$Standalone,
    [string]$Filter = '',
    [string]$Symbol = 'verifyIntegrity',
    [string]$SignatureFilter = '',
    [long[]]$SlotOffsets = @(),
    [int]$MaxSlots = 4,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 1200,
    # How long to wait for the build runner to reach the test step. Generous:
    # a cold lane compiles first, and a timeout here reads as "no crash".
    [int]$AttachTimeoutSeconds = 1200,
    [string]$OutDir,
    [string]$Cdb,
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$ShowProbe,
    [switch]$KeepLog
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\CrashCatch.ps1"
. "$PSScriptRoot\lib\DataBreak.ps1"

$cdbPath = Get-CdbPath -Override $Cdb
if (-not $cdbPath) {
    Write-Host 'databreak: no cdb.exe found.'
    Write-Host '  Looked for the Store WinDbg console debugger at'
    Write-Host ('  ' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe'))
    Write-Host '  Install WinDbg from the Store, or set $env:GHOZTTY_CDB to a cdb.exe.'
    exit 2
}
Write-Host "databreak: cdb = $cdbPath"

# --------------------------------------------------------------- what to run

$targets = @()
if ($Exe) { $targets = @($Exe) }
elseif ($Lane) {
    $targets = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
    if ($targets.Count -eq 0) {
        Write-Host "databreak: nothing built for lane '$Lane' under $Repo\.zig-cache\o -- run the lane once first."
        exit 2
    }
    Write-Host ("databreak: lane $Lane -> " + (($targets | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
}
else {
    Write-Host 'databreak: pass -Lane <none|win32|agent> or -Exe <path>.'
    exit 2
}

# ------------------------------------------------------------------ the mode

if ($UnderBuildRunner -and $Standalone) {
    Write-Host 'databreak: -UnderBuildRunner and -Standalone are mutually exclusive.'
    exit 2
}
if ($UnderBuildRunner -and -not $Lane) {
    Write-Host 'databreak: -UnderBuildRunner needs -Lane (there is no build step for a bare -Exe).'
    exit 2
}
# Default to the condition the defect actually occurs in (T832). -Exe has no
# lane to build, so it can only ever be standalone.
$underBuild = if ($Standalone) { $false } elseif ($UnderBuildRunner) { $true } else { [bool]$Lane }

$laneProc = $null
$laneLog = ''
if ($underBuild) {
    if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
        Write-Host 'databreak: zig.exe is not on PATH, so the build runner cannot be armed against.'
        exit 2
    }
    $laneArgs = switch ($Lane) {
        'none' { 'test -Dapp-runtime=none' }
        'win32' { 'test -Dapp-runtime=win32' }
        'agent' { 'test-agent' }
    }
    if ($Filter) { $laneArgs += (' -Dtest-filter="' + $Filter + '"') }
    Write-Host "databreak: mode = build-runner (zig build $laneArgs), attaching to the test binary it starts"
}
elseif ($Lane -or (@($targets | Where-Object { (Split-Path -Leaf $_) -match '^(ghostty-test|ghoztty-agent(-core)?-test)\.exe$' }).Count -gt 0)) {
    # Only for OUR test binaries: a fixture exe has no build runner to be the
    # wrong side of, and a warning that cries wolf stops being read.
    Write-Host 'databreak: mode = STANDALONE -- the binary is launched directly (mainTerminal).'
    Write-Host '           T443 has NEVER been observed in this condition (~200 runs, 0 crashes,'
    Write-Host '           against 5 aborts in 26 build-runner lane runs on 2026-08-14). A clean'
    Write-Host '           result here is not evidence about T443. See T832; use -UnderBuildRunner.'
}

# ------------------------------------------------------------------- run it

function Format-SlotList {
    param($Offsets)
    return (@($Offsets | ForEach-Object { Format-RbpExpression -Offset $_ }) -join ', ')
}

function Stop-LaneTree {
    <#
    .SYNOPSIS
        Tear down the detached `zig build` wrapper and everything under it.
    .DESCRIPTION
        cdb kills the test binary it attached to when it quits, which makes the
        lane fail and unwind on its own -- but a wedged compile or a second
        test binary would otherwise be left running against the next arm.
        taskkill /T because Stop-Process orphans the tree below cmd.exe.
    #>
    param($Proc)
    if (-not $Proc) { return }
    if ($Proc.HasExited) { return }
    & taskkill.exe /PID $Proc.Id /T /F *> $null
}

function Start-Lane {
    <#
    .SYNOPSIS
        Run the lane detached, the way floor-lane.ps1 does, and return the
        cmd.exe wrapper so it can be torn down afterwards.
    #>
    # NOT $Args: that is a PowerShell automatic variable, and a parameter of
    # that name silently never binds -- the lane then runs a bare `zig build`.
    param([string]$LaneArgLine, [string]$LogPath)
    $cache = $env:ZIG_GLOBAL_CACHE_DIR
    if (-not $cache) {
        # CLAUDE.md / T243: the global cache must sit on the repo's own drive,
        # or the build runner asserts instead of saying so. A detached cmd.exe
        # does not inherit a $env: set in an earlier shell, so it is set here.
        $cache = Join-Path (Split-Path -Qualifier $Repo) '\zig-global-cache'
    }
    # Through a .cmd FILE, not an argument: the lane line carries embedded
    # quotes (`-Dtest-filter="x"`), and Start-Process re-quotes an argument
    # list on its way to the child, which mangles them into a cmd that exits
    # before it runs anything -- an empty log and "the lane never started a
    # test binary". A file has no quoting layer to get wrong.
    $bat = [IO.Path]::ChangeExtension($LogPath, '.cmd')
    @(
        '@echo off',
        "set `"ZIG_GLOBAL_CACHE_DIR=$cache`"",
        "cd /d `"$Repo`"",
        "zig build $LaneArgLine"
    ) | Set-Content -LiteralPath $bat -Encoding ASCII
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', "`"$bat`"") -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $LogPath -RedirectStandardError ([IO.Path]::ChangeExtension($LogPath, '.err.log'))
    $null = $p.Handle
    return $p
}

function Wait-ForLaneTestProcess {
    <#
    .SYNOPSIS
        Wait for the build runner to start one of the lane's test binaries.
    .DESCRIPTION
        Matched on process NAME, and the image path is then read back off the
        RUNNING process. That is deliberate: the lane may rebuild, and a path
        picked out of .zig-cache beforehand would then name a binary nobody is
        running -- which is how an armed run measures nothing and still reports
        clean.
    #>
    param([string[]]$Names, [int]$TimeoutSeconds, $LaneProc)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($n in $Names) {
            $c = @(Get-Process -Name $n -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path } | Sort-Object StartTime | Select-Object -First 1)
            if ($c.Count -eq 1) { return $c[0] }
        }
        if ($LaneProc -and $LaneProc.HasExited) { return $null }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

$hit = $null
$crashed = $null
$last = $null

if ($underBuild) {
    $laneLog = Join-Path $env:TEMP ("databreak-lane-$Lane-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Write-Host "databreak: lane log: $laneLog"
    $laneProc = Start-Lane -LaneArgLine $laneArgs -LogPath $laneLog
    $names = @($targets | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)
    Write-Host ("databreak: waiting up to ${AttachTimeoutSeconds}s for one of: " + ($names -join ', '))
    $victimProc = Wait-ForLaneTestProcess -Names $names -TimeoutSeconds $AttachTimeoutSeconds -LaneProc $laneProc
    if (-not $victimProc) {
        Write-Host 'databreak: the lane never started a test binary (compile failure, or it finished first).'
        Write-Host "           read $laneLog"
        Stop-LaneTree -Proc $laneProc
        exit 2
    }
    $targets = @($victimProc.Path)
    Write-Host ("databreak: attaching to {0} pid {1}" -f (Split-Path -Leaf $victimProc.Path), $victimProc.Id)
}

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "databreak: no such exe: $t"
        exit 2
    }
    $attachPid = if ($underBuild) { $victimProc.Id } else { 0 }
    $r = Invoke-DataBreak -Exe $t -Symbol $Symbol -SignatureFilter $SignatureFilter `
        -SlotOffsets $SlotOffsets -MaxSlots $MaxSlots `
        -Arguments $Arguments -OutDir $OutDir -TimeoutSeconds $TimeoutSeconds -Cdb $Cdb -Repo $Repo `
        -AttachPid $attachPid -KeepLog:$KeepLog
    if ($r.Error) {
        Write-Host "databreak: $($r.Error)"
        if ($r.Probe -and $r.Probe.RawDisasm.Count -gt 0) {
            Write-Host 'databreak: probe disassembly follows --'
            foreach ($l in $r.Probe.RawDisasm) { Write-Host ('  | ' + $l) }
        }
        Stop-LaneTree -Proc $laneProc
        exit 2
    }
    if ($ShowProbe) {
        $p = $r.Probe
        # Say which allocation shape was read, and how many callee-saved
        # registers sit under the frame: a transcript that always printed
        # "sub rsp,X" would misdescribe a __chkstk frame (T834), and the push
        # count is what the return slot is computed from.
        $frameDesc = $(if ($p.FrameShape -eq 'chkstk') {
                'mov eax,0x{0:x}/__chkstk' -f $p.FrameSub
            }
            else { 'sub rsp,0x{0:x}' -f $p.FrameSub })
        if ($p.ExtraPushes -gt 0) { $frameDesc = ('{0} push(es) + ' -f $p.ExtraPushes) + $frameDesc }
        Write-Host ("databreak: probe {0}!{1} entry=0x{2:x} frame: {3} lea rbp,[rsp+0x{4:x}]" -f `
                $p.ModuleName, $p.Symbol, $p.EntryAddress, $frameDesc, $p.FrameLea)
        foreach ($s in $p.Spills) {
            Write-Host ("  spill {0} <- {1} (origin {2})" -f (Format-RbpExpression -Offset $s.Offset), $s.Reg, $s.Origin)
        }
        Write-Host ("  armed: {0}" -f (Format-SlotList -Offsets $r.ArmedOffsets))
        Write-Host ("  arm point: {0}!{1}+0x{2:x} (= {0}+0x{3:x}); return slot: {4}" -f `
                $p.ModuleName, $p.Symbol, $p.ArmOffset, $p.ArmRva, (Format-RbpExpression -Offset $p.RetSlotOffset))
    }
    $last = $r
    if ($r.Hit) { $hit = $r; break }
    if ($r.Crashed) { $crashed = $r; break }
}

# cdb has exited, so whatever it was attached to is gone; unwind the rest of
# the lane rather than leaving a compile or a second test binary running.
Stop-LaneTree -Proc $laneProc
if ($underBuild -and $laneLog) { Write-Host "databreak: lane transcript: $laneLog" }

if ($hit) {
    Write-Host '-- data breakpoint hit --'
    Write-Host ("  a write to an armed slot of {0}!{1} was caught in the act" -f $hit.Probe.ModuleName, $hit.Probe.Symbol)
    Write-Host ("  armed: {0}; victim frame rbp = {1}" -f (Format-SlotList -Offsets $hit.ArmedOffsets), $hit.VictimRbp)
    if ($hit.WriterSite) { Write-Host ("  writer (one instruction past the write): " + $hit.WriterSite) }
    if ($hit.LastTest) { Write-Host ("  running at the time: " + $hit.LastTest) }
    Write-Host '  writing instruction (last line of the backward disassembly):'
    foreach ($l in @($hit.WriterBlock | Where-Object { $_ -match '\S' } | Select-Object -First 12)) {
        Write-Host ('  | ' + $l.TrimEnd())
    }
    Write-Host '  writer stack:'
    foreach ($l in @($hit.StackBlock | Where-Object { $_ -match '\S' } | Select-Object -First 14)) {
        Write-Host ('  | ' + $l.TrimEnd())
    }
    if ($hit.DumpPath) { Write-Host ('  dump (all threads, full memory): ' + $hit.DumpPath) }
    Write-Host ('  transcript: ' + $hit.LogPath)
    exit 1
}

if ($crashed) {
    Write-Host ("databreak: the program crashed without touching an armed slot ({0} arm cycle(s))" -f $crashed.ArmCount)
    $null = Write-CrashStack -Result ([pscustomobject]@{
            Crashed       = $true
            Attempt       = 1
            Attempts      = 1
            ExceptionCode = $crashed.CrashResult.ExceptionCode
            ExceptionName = $crashed.CrashResult.ExceptionName
            FaultSite     = $crashed.CrashResult.FaultSite
            ThreadCount   = $crashed.CrashResult.ThreadCount
            SourceLines   = $crashed.CrashResult.SourceLines
            LastTest      = $crashed.LastTest
            DumpPath      = $crashed.DumpPath
            LogPath       = $crashed.LogPath
            FaultingStack = $crashed.CrashResult.FaultingStack
            AllStacks     = $crashed.CrashResult.AllStacks
            ExitCode      = $crashed.ExitCode
            Seconds       = $crashed.Seconds
        })
    exit 3
}

if ($last.ArmCount -eq 0) {
    Write-Host ("databreak: WARNING -- the entry breakpoint never fired; '{0}' was never called (wrong symbol, or a filtered run that does not reach it)" -f $Symbol)
    if ($underBuild) {
        Write-Host '           under the build runner this also means the deferred breakpoint never resolved --'
        Write-Host '           check that the lane actually rebuilt/ran the probed binary rather than a cached one.'
    }
}
$modeName = if ($underBuild) { 'build-runner' } else { 'standalone' }
Write-Host ("databreak: no wild write observed (mode={4}) -- {0} arm cycle(s), {1} disarm(s), program ran {2}s (cdb exit {3})" -f `
        $last.ArmCount, $last.DisarmCount, $last.Seconds, $last.ExitCode, $modeName)
if (-not $underBuild -and $Lane) {
    Write-Host '           reminder: standalone is not a condition T443 has ever reproduced in (T832).'
}
exit 0
