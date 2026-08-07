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
    [string]$Symbol = 'verifyIntegrity',
    [string]$SignatureFilter = '',
    [long[]]$SlotOffsets = @(),
    [int]$MaxSlots = 4,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 1200,
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

# ------------------------------------------------------------------- run it

function Format-SlotList {
    param($Offsets)
    return (@($Offsets | ForEach-Object { Format-RbpExpression -Offset $_ }) -join ', ')
}

$hit = $null
$crashed = $null
$last = $null
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "databreak: no such exe: $t"
        exit 2
    }
    $r = Invoke-DataBreak -Exe $t -Symbol $Symbol -SignatureFilter $SignatureFilter `
        -SlotOffsets $SlotOffsets -MaxSlots $MaxSlots `
        -Arguments $Arguments -OutDir $OutDir -TimeoutSeconds $TimeoutSeconds -Cdb $Cdb -Repo $Repo `
        -KeepLog:$KeepLog
    if ($r.Error) {
        Write-Host "databreak: $($r.Error)"
        if ($r.Probe -and $r.Probe.RawDisasm.Count -gt 0) {
            Write-Host 'databreak: probe disassembly follows --'
            foreach ($l in $r.Probe.RawDisasm) { Write-Host ('  | ' + $l) }
        }
        exit 2
    }
    if ($ShowProbe) {
        $p = $r.Probe
        Write-Host ("databreak: probe {0}!{1} entry=0x{2:x} frame: sub rsp,0x{3:x} lea rbp,[rsp+0x{4:x}]" -f `
                $p.ModuleName, $p.Symbol, $p.EntryAddress, $p.FrameSub, $p.FrameLea)
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
}
Write-Host ("databreak: no wild write observed -- {0} arm cycle(s), {1} disarm(s), program ran {2}s (cdb exit {3})" -f `
        $last.ArmCount, $last.DisarmCount, $last.Seconds, $last.ExitCode)
exit 0
