<#
.SYNOPSIS
    T460 - the FIRST crash must yield the stack, with no re-run and no
    reproduction.

.DESCRIPTION
    T450 made a crashed lane produce a stack by re-running the test binary
    under cdb. That only ever describes a crash which obliges by happening
    twice: the occurrence that actually failed the lane yields nothing, and an
    intermittent crash (the one this tooling exists for) is diagnosed by trying
    to provoke it again.

    Windows was already writing the evidence. WER's LocalDumps drops a dump of
    the process at the moment it dies -- unattended, on the first crash, at no
    cost to a run that does not crash -- and nothing read it. This script
    proves the reader, against a REAL access violation raised on a background
    thread, because the load-bearing claim is the same one T450 carries: the
    capture holds the thread that did NOT fault as well as the one that did,
    which zig's own handler can never show.

    It also proves the two ways this path could lie, which matter more than the
    happy path:

      * a dump from an EARLIER crash must never be reported as this one's --
        a wrong stack sends the next investigation where the bug has never been
      * a dump with no exception in it (the T48 freeze watchdog writes those of
        a live, wedged process) must not be read as a crash

.OUTPUTS
    One `ALL PASS` / `N FAILURE(S)` / `ASSERTED NOTHING` line last.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$Repo\test\win32\lib\TestScore.ps1"
. "$Repo\scripts\lib\CrashDump.ps1"

$failures = 0
$passes = 0
$script:skipped = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS $Name"; $script:passes++ }
    else { Write-Host "FAIL $Name $Detail"; $script:failures++ }
}

# ------------------------------------------------------ 1. is capture armed?

$cdb = Get-CdbPath
if (-not $cdb) {
    Write-TestAssertedNothing -Reason 'no console cdb.exe on this box, so no dump can be read at all' -Skipped $script:skipped
}

$cfg = Get-WerLocalDumpConfig -ExeName 'ghostty-test.exe'
Check 'the armed state of first-crash capture is answerable' ($null -ne $cfg)
if (-not $cfg.Armed) {
    # Not a skip: with LocalDumps off there is no first-crash capture on this
    # box and every claim below is unmeasurable. Say so as a result.
    Write-Host 'first-crash capture is NOT armed on this box (HKLM LocalDumps missing).'
    Write-TestAssertedNothing -Reason 'WER LocalDumps is not enabled, so no dump exists to read' -Skipped $script:skipped
}
Check 'the dump folder is a real expanded path' `
    ($cfg.DumpFolder -notmatch '%' -and (Split-Path -Qualifier $cfg.DumpFolder)) $cfg.DumpFolder
Check 'the dump type is named, not just numbered' `
    ($cfg.DumpTypeName -in @('mini', 'full', 'custom')) "got '$($cfg.DumpTypeName)'"
Check 'dump type 1 reads as mini' ((Get-WerDumpTypeName -Type 1) -eq 'mini')
Check 'dump type 2 reads as full' ((Get-WerDumpTypeName -Type 2) -eq 'full')
Check 'an unknown dump type is not silently named' ((Get-WerDumpTypeName -Type 9) -eq 'unknown(9)')

# ---------------------------------------------------- 2. build the subjects

$work = Join-Path (Split-Path -Qualifier $Repo) ('\firstchance-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    # CLAUDE.md: the global cache must sit on the repo's drive.
    $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $Repo) '\zig-global-cache')
}

# Debug on purpose: it carries a pdb (source lines) and installs zig's segfault
# handler, so this is the exact shape a real test binary dies in.
@(
    'const std = @import("std");',
    'fn boom() void {',
    '    const p: *volatile u8 = @ptrFromInt(0x10);',
    '    p.* = 1;',
    '}',
    'fn worker() void {',
    '    std.Thread.sleep(150 * std.time.ns_per_ms);',
    '    boom();',
    '}',
    'pub fn main() !void {',
    '    const t = try std.Thread.spawn(.{}, worker, .{});',
    '    t.join();',
    '}'
) | Set-Content -Path (Join-Path $work 'avthread.zig') -Encoding ASCII

@(
    'const std = @import("std");',
    'pub fn main() !void {',
    '    std.Thread.sleep(6 * std.time.ns_per_s);',
    '}'
) | Set-Content -Path (Join-Path $work 'sleeper.zig') -Encoding ASCII

Push-Location $work
$b1 = & zig build-exe avthread.zig 2>&1
$b2 = & zig build-exe sleeper.zig 2>&1
Pop-Location

$avExe = Join-Path $work 'avthread.exe'
$sleepExe = Join-Path $work 'sleeper.exe'
Check 'the threaded crasher built' (Test-Path $avExe) "$b1"
Check 'the sleeping control built' (Test-Path $sleepExe) "$b2"

# ------------------------------- 3. the first crash, read without a re-run

$outDir = Join-Path $work 'dumps'
$analysis = $null
if (Test-Path $avExe) {
    $t0 = Get-Date
    # ONE run. Not "until it crashes" -- the whole claim is that one occurrence
    # is enough, which is what an intermittent crash only ever gives you.
    $null = & cmd.exe /c "`"$avExe`" > nul 2>&1"
    $found = Find-WerCrashDump -ExeNames @('avthread.exe') -Since $t0 -WaitSeconds 30
    Check 'Windows kept a dump of the first crash, unasked' ($null -ne $found) `
        "nothing matching avthread.exe.*.dmp appeared in $($cfg.DumpFolder)"

    if ($found) {
        $read0 = Get-Date
        $analysis = Invoke-CrashDumpAnalysis -DumpPath $found.FullName -SymbolPath $work -OutDir $outDir
        $readSeconds = [int]((Get-Date) - $read0).TotalSeconds

        Check 'the dump reads as a crash' ($analysis.Crashed)
        Check 'the crash is attributed to the dump, not to a re-run' ($analysis.Source -eq 'wer') "got '$($analysis.Source)'"
        # The cost this task exists to remove: T450's path re-runs the binary,
        # which is minutes on a test binary and impossible on a crash that does
        # not reproduce.
        Check 'reading it costs seconds, not a re-run' ($readSeconds -le 60) "took ${readSeconds}s"

        $allText = ($analysis.AllStacks -join "`n")
        Check 'more than one thread was captured' ($analysis.ThreadCount -ge 2) "got $($analysis.ThreadCount)"
        Check 'the faulting frame survived the handler' ($allText -match 'avthread!boom') 'no boom frame'
        # THE POINT: zig's own handler only ever walks the thread that faulted.
        Check 'the OTHER thread is in the capture too' ($allText -match 'avthread!(main|join)')
        Check 'frames carry source lines' ($analysis.SourceLines -ge 2) "got $($analysis.SourceLines)"

        # The recorded exception is the handler aborting, NOT the access
        # violation -- a reader told only "0x80000003 break instruction" would
        # chase a breakpoint that never existed.
        Check 'the handler-abort exception is recognised for what it is' ($analysis.HandlerAbort) `
            "code=$($analysis.ExceptionCode)"
        $block = @()
        $null = Write-CrashDumpStack -Result $analysis -MaxFrames 4 -Writer { param($s) $script:block += $s }
        $blockText = ($block -join "`n")
        Check 'the printed block says the evidence needed no re-run' ($blockText -match 'no re-run')
        Check 'the printed block warns that the fault is further down' ($blockText -match 'further down this stack')
        Check 'the printed block names the exception in words' ($blockText -match 'Break instruction|Access violation') `
            "got: $($block[1])"

        # WER rotates its own folder (DumpCount); the repo copy is what the
        # harness's retention bounds and what a follow-up query opens.
        Check 'the dump is kept in the output directory' ($analysis.DumpWritten -and (Test-Path -LiteralPath $analysis.DumpPath))
        Check 'the kept dump uses the retention name shape' `
            ((Split-Path -Leaf $analysis.DumpPath) -match '-\d{8}-\d{6}-\d+\.dmp$') (Split-Path -Leaf $analysis.DumpPath)
        Check 'the transcript with every thread is kept beside it' `
            ($analysis.LogPath -and (Test-Path -LiteralPath $analysis.LogPath))
    }
}

# ------------------------------------------- 4. it must not invent evidence

if (Test-Path $avExe) {
    # A dump from before the run that is asking is a DIFFERENT crash. Reporting
    # it is worse than reporting nothing.
    $stale = Find-WerCrashDump -ExeNames @('avthread.exe') -Since (Get-Date).AddMinutes(10) -WaitSeconds 1
    Check 'a dump older than the run is never returned' ($null -eq $stale) "leaked $($stale.FullName)"
}

$never = Find-WerCrashDump -ExeNames @('ghoztty-no-such-binary.exe') -Since (Get-Date).AddHours(-24) -WaitSeconds 1
Check 'a binary that never crashed yields nothing' ($null -eq $never)

if (Test-Path $sleepExe) {
    $t1 = Get-Date
    $sleepProc = Start-Process -FilePath $sleepExe -PassThru -WindowStyle Hidden
    $null = $sleepProc.Handle
    Start-Sleep -Milliseconds 700

    # A dump of a LIVE process -- exactly what the T48 freeze watchdog writes.
    # It parses fine and contains no exception; reading it as a crash would
    # manufacture a stack for a bug that never happened.
    Add-Type -ErrorAction SilentlyContinue @'
using System;
using System.Runtime.InteropServices;
public static class GhozttyFcDump {
    [DllImport("Dbghelp.dll", SetLastError = true)]
    public static extern bool MiniDumpWriteDump(IntPtr hProcess, uint pid, IntPtr hFile,
        int dumpType, IntPtr exceptionParam, IntPtr userStreamParam, IntPtr callbackParam);
}
'@
    $hangDump = Join-Path $work 'sleeper-hang.dmp'
    $fs = [IO.File]::Create($hangDump)
    $ok = [GhozttyFcDump]::MiniDumpWriteDump($sleepProc.Handle, [uint32]$sleepProc.Id, $fs.SafeFileHandle.DangerousGetHandle(), 0x2, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $fs.Close()
    Check 'a live-process dump could be staged' ($ok -and (Get-Item $hangDump).Length -gt 10KB) `
        "err $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"

    if ($ok) {
        # Asked of the file, because cdb cannot answer it: it reports a
        # breakpoint off the current context for a dump with no exception at
        # all, which is byte-identical in its output to a real abort.
        Check 'a live-process dump carries no exception stream' `
            (-not (Test-MinidumpHasException -Path $hangDump))
        if ($found) {
            Check 'a real crash dump does carry one' (Test-MinidumpHasException -Path $found.FullName)
        }
        $notADump = Join-Path $work 'notadump.dmp'
        Set-Content -LiteralPath $notADump -Value 'this is not a minidump' -Encoding ASCII
        Check 'a file that is not a minidump is not read as a crash' `
            (-not (Test-MinidumpHasException -Path $notADump))
        Check 'a dump that does not exist is not read as a crash' `
            (-not (Test-MinidumpHasException -Path (Join-Path $work 'ghost.dmp')))

        $hangOut = Join-Path $work 'dumps-hang'
        $h = Invoke-CrashDumpAnalysis -DumpPath $hangDump -SymbolPath $work -OutDir $hangOut
        Check 'a dump with no exception is NOT reported as a crash' (-not $h.Crashed) `
            "code='$($h.ExceptionCode)'"
        Check 'nothing is kept from a dump that is not a crash' `
            ((@(Get-ChildItem $hangOut -File -ErrorAction SilentlyContinue)).Count -eq 0)
        $hb = @()
        $null = Write-CrashDumpStack -Result $h -Writer { param($s) $script:hb += $s }
        Check 'and it says so instead of printing a stack' (($hb -join "`n") -match 'did not parse as a crash')
    }
    try { Stop-Process -Id $sleepProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    # A killed process is not a crash either: nothing may appear for it.
    Start-Sleep -Milliseconds 500
    $killed = Find-WerCrashDump -ExeNames @('sleeper.exe') -Since $t1 -WaitSeconds 2
    Check 'a process that was killed leaves no crash dump' ($null -eq $killed) "leaked $($killed.FullName)"
}

# ----------------------------------------------------------- 5. the CLI path

if ($analysis -and $analysis.Crashed) {
    $cliLog = Join-Path $work 'cli.log'
    cmd.exe /c "powershell -NoProfile -File `"$Repo\scripts\crash-catch.ps1`" -FromDump `"$($analysis.OriginalDump)`" -OutDir `"$work\dumps-cli`" > `"$cliLog`" 2>&1" | Out-Null
    $cliCode = $LASTEXITCODE
    $cliText = (Get-Content $cliLog -Raw -ErrorAction SilentlyContinue)
    Check 'crash-catch -FromDump reports a captured crash (exit 1)' ($cliCode -eq 1) "got $cliCode"
    Check 'crash-catch -FromDump prints the stack block' ($cliText -match 'crash stack')
    Check 'crash-catch -FromDump ran nothing' ($cliText -match 'no re-run')
}

$missLog = Join-Path $work 'miss.log'
cmd.exe /c "powershell -NoProfile -File `"$Repo\scripts\crash-catch.ps1`" -FromDump `"$work\nope.dmp`" > `"$missLog`" 2>&1" | Out-Null
Check 'a dump that does not exist exits 2' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"

$statLog = Join-Path $work 'status.log'
cmd.exe /c "powershell -NoProfile -File `"$Repo\scripts\crash-catch.ps1`" -Status > `"$statLog`" 2>&1" | Out-Null
$statCode = $LASTEXITCODE
$statText = (Get-Content $statLog -Raw -ErrorAction SilentlyContinue)
Check '-Status exits 0 when capture is armed' ($statCode -eq 0) "got $statCode"
Check '-Status names where the dumps land' ($statText -match [regex]::Escape($cfg.DumpFolder))

# ------------------------------------------- 6. the lane takes the fast path

# End to end through floor-lane's own crash path, with the crasher named like a
# test binary so the lane recognises it as ours. The claim under test is the
# ORDER: the dump that already exists is read, and the ~10-minute re-run is not
# reached at all.
$laneCrasher = Join-Path $work 'ghostty-test.exe'
$builtTest = Get-NewestBuiltBinary -Name 'ghostty-test.exe' -Repo $Repo
if ((Test-Path $avExe) -and $builtTest) {
    Copy-Item -LiteralPath $avExe -Destination $laneCrasher -Force
    Copy-Item -LiteralPath (Join-Path $work 'avthread.pdb') -Destination (Join-Path $work 'ghostty-test.pdb') -Force -ErrorAction SilentlyContinue
    $laneLog = Join-Path $work 'lane.log'
    cmd.exe /c "powershell -NoProfile -File `"$Repo\scripts\floor-lane.ps1`" -Command `"$laneCrasher`" -StallSeconds 60 -TimeoutSeconds 180 > `"$laneLog`" 2>&1" | Out-Null
    $laneText = (Get-Content $laneLog -Raw -ErrorAction SilentlyContinue)
    Check 'the lane sees the crash as a failure' ($laneText -match 'LANE command FAIL') `
        "tail: $(($laneText -split "`n" | Select-Object -Last 2) -join ' / ')"
    Check 'the lane reads the dump Windows already wrote' ($laneText -match 'no re-run') `
        "tail: $(($laneText -split "`n" | Select-Object -Last 3) -join ' / ')"
    Check 'the lane does NOT re-run the binary under cdb' ($laneText -notmatch 'capturing a stack for') `
        'the re-run path was reached even though a dump existed'

    # The same run with first-crash capture disabled, which is what a box
    # without LocalDumps looks like. It must fall back to T450's re-run --
    # otherwise the assertion above passes on a lane that captures nothing at
    # all, and the fallback rots unnoticed.
    $fbLog = Join-Path $work 'lane-nower.log'
    cmd.exe /c "set GHOZTTY_CRASH_NO_WER=1&& powershell -NoProfile -File `"$Repo\scripts\floor-lane.ps1`" -Command `"$laneCrasher`" -StallSeconds 60 -TimeoutSeconds 180 -CatchTimeoutSeconds 120 > `"$fbLog`" 2>&1" | Out-Null
    $fbText = (Get-Content $fbLog -Raw -ErrorAction SilentlyContinue)
    Check 'with capture disabled the lane says so' ($fbText -match 'NOT ARMED') `
        "tail: $(($fbText -split "`n" | Select-Object -Last 3) -join ' / ')"
    Check 'with capture disabled the lane falls back to the re-run' ($fbText -match 'capturing a stack for') `
        'neither path produced a capture'
    Check 'the fallback still yields a stack' ($fbText -match 'crash stack')

    # The by-hand entry point, against the crash those runs just left behind:
    # "what killed the lane last time", with nothing re-run.
    $lastLog = Join-Path $work 'last.log'
    cmd.exe /c "powershell -NoProfile -File `"$Repo\scripts\crash-catch.ps1`" -Last -Lane none -SinceHours 1 -OutDir `"$work\dumps-last`" > `"$lastLog`" 2>&1" | Out-Null
    $lastCode = $LASTEXITCODE
    $lastText = (Get-Content $lastLog -Raw -ErrorAction SilentlyContinue)
    Check 'crash-catch -Last reads the lane binary''s last crash (exit 1)' ($lastCode -eq 1) `
        "got $lastCode; tail: $(($lastText -split "`n" | Select-Object -Last 2) -join ' / ')"
    Check 'crash-catch -Last ran nothing' ($lastText -match 'no re-run')
}
else {
    Write-Host 'SKIP lane end-to-end: no built ghostty-test.exe to resolve against'
    $script:skipped++
}

# --------------------------------------- 7. the wrapper still runs with it

$selfOut = & powershell -NoProfile -File (Join-Path $Repo 'scripts\floor-lane.ps1') -SelfTest 2>&1
Check 'floor-lane self-test still passes with the reader wired in' (($selfOut | Out-String) -match 'ALL PASS') `
    "tail: $(($selfOut | Select-Object -Last 3) -join ' / ')"

# --------------------------------------------------------------------- cleanup

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

# --- stamp (T783) ---------------------------------------------------------
# A clean green run records the content of every file it covers, so
# scripts\guard-due.ps1 can answer "has anything run this harness against the
# code as it now stands?". Only a CLEAN sweep stamps: a run with a skipped
# section proved less than the harness claims, and a red run must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard crash-first-chance -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $passes -Fail $failures -Skipped $script:skipped -MinPass 20
