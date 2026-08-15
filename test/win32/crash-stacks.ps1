<#
.SYNOPSIS
    T450 - a crashing binary must leave a full dump and EVERY thread's
    symbolised stack, automatically.

.DESCRIPTION
    Zig's segfault handler dies in a recursive panic on this box, so a crashed
    test binary prints two lines and no stack -- and even when it works it only
    ever shows the FAULTING thread, which is the victim, not the culprit.

    This script proves the replacement end to end against a REAL access
    violation raised on a BACKGROUND thread, because that is the case that
    matters: the assertion that carries the whole task is that the capture
    contains the main thread's stack too, not just the one that faulted.

.OUTPUTS
    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$Repo\scripts\lib\CrashCatch.ps1"

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL $Name $Detail"; $script:failures++ }
}

# ------------------------------------------------------------------- 1. cdb

$cdb = Get-CdbPath
Check 'a console cdb.exe is found' ($null -ne $cdb) 'none of the known locations had one'
if (-not $cdb) {
    Write-Host '1 FAILURE(S)'
    exit 1
}
Check 'the cdb that was found exists' (Test-Path -LiteralPath $cdb) $cdb

# An explicit override wins, so a box with a different debugger can be pointed
# at it without editing the library.
$env:GHOZTTY_CDB = 'C:\definitely\not\here\cdb.exe'
Check 'GHOZTTY_CDB is ignored when it does not exist' ((Get-CdbPath) -eq $cdb)
Remove-Item Env:\GHOZTTY_CDB -ErrorAction SilentlyContinue
Check 'an -Override path that exists is preferred' ((Get-CdbPath -Override $cdb) -eq $cdb)

# --------------------------------------------------- 2. build the crashers

$work = Join-Path (Split-Path -Qualifier $Repo) ('\crashstacks-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    # CLAUDE.md: the global cache must sit on the repo's drive.
    $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $Repo) '\zig-global-cache')
}

# Debug on purpose: a Debug build carries a pdb, which is what turns the
# captured frames into source lines. It also installs Zig's segfault handler,
# so this is the exact shape that produces "aborting due to recursive panic".
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
    '    std.Thread.sleep(50 * std.time.ns_per_ms);',
    '}'
) | Set-Content -Path (Join-Path $work 'clean.zig') -Encoding ASCII

# T478's two subjects. A Zig panic ends in `int3`, which cdb owns: with no `bpe`
# filter the debugger swallowed it and the run was reported as having completed.
@(
    'const std = @import("std");',
    'fn inner() void {',
    '    @panic("deliberate boom");',
    '}',
    'pub fn main() !void {',
    '    inner();',
    '}'
) | Set-Content -Path (Join-Path $work 'panic.zig') -Encoding ASCII

# And the shape no debugger can explain: a nonzero exit with no exception at
# all. It must not be called clean either.
@(
    'const std = @import("std");',
    'pub fn main() void {',
    '    std.process.exit(26);',
    '}'
) | Set-Content -Path (Join-Path $work 'exit26.zig') -Encoding ASCII

Push-Location $work
$b1 = & zig build-exe avthread.zig 2>&1
$b2 = & zig build-exe clean.zig 2>&1
$b3 = & zig build-exe panic.zig 2>&1
$b4 = & zig build-exe exit26.zig 2>&1
Pop-Location

$avExe = Join-Path $work 'avthread.exe'
$cleanExe = Join-Path $work 'clean.exe'
$panicExe = Join-Path $work 'panic.exe'
$exitExe = Join-Path $work 'exit26.exe'
Check 'the threaded crasher built' (Test-Path $avExe) "$b1"
Check 'the clean control built' (Test-Path $cleanExe) "$b2"
Check 'the panicking crasher built' (Test-Path $panicExe) "$b3"
Check 'the nonzero-exit control built' (Test-Path $exitExe) "$b4"
Check 'the crasher has a pdb beside it' (Test-Path (Join-Path $work 'avthread.pdb'))

# ------------------------------------- 3. what Zig alone can and cannot show

if (Test-Path $avExe) {
    $bare = & cmd.exe /c "`"$avExe`"" 2>&1 | Out-String
    # Measured, not assumed: on a SIMPLE access violation Zig's handler works
    # and does print the faulting thread's frames. (The recursive panic T450 was
    # filed over needs a process already damaged enough that the handler faults
    # too, which cannot be staged reliably -- so it is not asserted here.)
    Check 'Zig alone does report the faulting thread on a simple AV' `
    ($bare -match 'avthread\.zig') "got: $($bare -replace '\s+', ' ')"

    # THE GAP, and it is unconditional: Zig's handler only ever walks the thread
    # that faulted. The main thread -- sitting in Thread.join, and in T443 the
    # kind of thread that would be holding the smoking gun -- is simply absent.
    Check 'Zig alone shows ONLY the faulting thread, never the others' `
    ($bare -notmatch 'in main\b') "got: $($bare -replace '\s+', ' ')"
}

# ------------------------------------------------------- 4. catching it live

$outDir = Join-Path $work 'dumps'
$caught = $null
if (Test-Path $avExe) {
    $out = & powershell -NoProfile -File (Join-Path $Repo 'scripts\crash-catch.ps1') `
        -Exe $avExe -OutDir $outDir -TimeoutSeconds 120 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)

    Check 'catching a crash exits 1' ($code -eq 1) "got $code"
    Check 'the exception is named' ($text -match '0xc0000005') "tail: $($text -replace '\s+', ' ')"
    Check 'the fault site is symbolised' ($text -match 'avthread!boom')
    Check 'frames carry source lines' ($text -match 'avthread\.zig @ 4')
    Check 'the dump path is reported' ($text -match 'dump \(all threads, full memory\)')

    $dumps = @(Get-ChildItem $outDir -Filter '*.dmp' -ErrorAction SilentlyContinue)
    Check 'a dump is on disk' ($dumps.Count -ge 1)
    # The backslash-escaping trap: a dump path is handed to cdb inside a quoted
    # command, where backslash is an escape. Get that wrong and `.dump` writes
    # to a mangled name -- or nowhere -- while everything else still looks fine.
    Check 'the dump is a real full dump, not an empty file' `
    ($dumps.Count -ge 1 -and $dumps[0].Length -gt 100KB) "$($dumps[0].Length) bytes"

    # `.err.log` (the debuggee's own stderr) sits beside the transcript, so an
    # unfiltered *.log picks up whichever sorts first and parses as no crash.
    $logs = @(Get-ChildItem $outDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.err.log' })
    Check 'the transcript is on disk' ($logs.Count -ge 1)
    Check "the debuggee's own output is kept beside it" `
    ((@(Get-ChildItem $outDir -Filter '*.err.log' -ErrorAction SilentlyContinue)).Count -ge 1)
    Check 'the cdb script file is cleaned up' ((@(Get-ChildItem $outDir -Filter '*.cdb' -ErrorAction SilentlyContinue)).Count -eq 0)

    if ($logs.Count -ge 1) {
        $caught = Read-CrashCatchLog -LogPath $logs[0].FullName
        Check 'the transcript parses as a crash' ($caught.Crashed)
        Check 'the parsed exception code is the AV' ($caught.ExceptionCode -eq '0xc0000005') "got '$($caught.ExceptionCode)'"

        # THE POINT OF THE TASK: not just the thread that faulted. Zig's own
        # handler could never show the other one, and in T443 the thread that
        # did the damage is exactly the thread that did not fault.
        Check 'more than one thread was captured' ($caught.ThreadCount -ge 2) "got $($caught.ThreadCount)"
        $allText = ($caught.AllStacks -join "`n")
        Check 'the faulting thread is in the capture' ($allText -match 'avthread!boom')
        Check 'the OTHER thread is in the capture too' ($allText -match 'avthread!(main|join)')
        Check 'the capture resolves ghoztty-side source lines' ($caught.SourceLines -ge 2) "got $($caught.SourceLines)"
    }
}

# ------------------------------------------------- 4b. captures do not pile up

# A /ma dump of a test binary is ~120 MB, and .dumps\ is gitignored, so nothing
# else would ever notice it growing. Synthetic files: the real thing would take
# a gigabyte and several minutes to stage.
$retDir = Join-Path $work 'retention'
New-Item -ItemType Directory -Path $retDir -Force | Out-Null
foreach ($n in 1..8) {
    $stamp = '2026080{0}-12000{0}-1' -f $n
    foreach ($ext in @('.dmp', '.log', '.err.log')) {
        $f = Join-Path $retDir ("ghostty-test-$stamp$ext")
        Set-Content -LiteralPath $f -Value 'x' -Encoding ASCII
        (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-100 + $n)
    }
}
# The T48 freeze watchdog writes here too, under a different name shape. Both
# must survive: deleting one would destroy evidence for a different bug, and the
# 2026-07-14 deadlock dump in this repo's .dumps\ is 744 MB of it. The
# `-deadlock-` name is the one actually on disk -- the `-hang-` name is what the
# watchdog was documented as writing, so both shapes are pinned here.
$watchdogs = @(
    (Join-Path $retDir 'ghoztty-9056-deadlock-20260714-183552.dmp'),
    (Join-Path $retDir 'ghoztty-1234-hang-20260801-120000.dmp')
)
foreach ($w in $watchdogs) { Set-Content -LiteralPath $w -Value 'x' -Encoding ASCII }

Remove-OldCrashCapture -OutDir $retDir -Keep 3
$leftDumps = @(Get-ChildItem $retDir -Filter 'ghostty-test-*.dmp')
Check 'retention keeps exactly the newest N captures' ($leftDumps.Count -eq 3) "got $($leftDumps.Count)"
Check 'retention keeps the NEWEST, not the oldest' `
    (($leftDumps.Name -join ',') -match '20260808') "got $($leftDumps.Name -join ',')"
Check 'retention drops the transcripts with their dump' `
((@(Get-ChildItem $retDir -Filter 'ghostty-test-*.log')).Count -eq 6) `
"got $((@(Get-ChildItem $retDir -Filter 'ghostty-test-*.log')).Count)"
Check 'retention never touches a watchdog dump' `
((@($watchdogs | Where-Object { Test-Path -LiteralPath $_ })).Count -eq $watchdogs.Count)

# ------------------------------------------ 4c. a Zig panic (T478)

# The regression this section exists for: `crash-catch` was pointed at a test
# binary that panicked on 10 runs out of 10 and reported "ran clean in 17s" for
# every one of them. A false negative in a crash detector reads exactly like
# evidence of a fix.
if (Test-Path $panicExe) {
    # Positive control first: the binary really does die, and with the code the
    # filters were blind to. Without this, a panic that stopped panicking would
    # make the section below pass for the wrong reason.
    & $panicExe *> $null
    Check 'the panic control really does die with STATUS_BREAKPOINT' `
    ($LASTEXITCODE -eq -2147483645) ("got 0x{0:X8}" -f $LASTEXITCODE)

    $panicDir = Join-Path $work 'dumps-panic'
    $pOut = & powershell -NoProfile -File (Join-Path $Repo 'scripts\crash-catch.ps1') `
        -Exe $panicExe -OutDir $panicDir -TimeoutSeconds 120 2>&1
    $pCode = $LASTEXITCODE
    $pText = ($pOut | Out-String)

    Check 'catching a Zig panic exits 1' ($pCode -eq 1) "got $pCode"
    Check 'a Zig panic is NEVER reported as a clean run' `
    ($pText -notmatch 'ran clean|ran to completion') "tail: $($pText -replace '\s+', ' ')"
    Check 'the breakpoint exception is named' ($pText -match '0x80000003') "tail: $($pText -replace '\s+', ' ')"
    Check 'the panic frames carry the panicking function' ($pText -match 'panic!inner')
    Check 'the panic frames carry source lines' ($pText -match 'panic\.zig @ 3')
    Check 'a dump is written for a panic' `
    ((@(Get-ChildItem $panicDir -Filter '*.dmp' -ErrorAction SilentlyContinue)).Count -ge 1)
}

# ------------------------- 4d. arming `bpe` must not disarm planted breakpoints

# The one risk this change carries: DataBreak.ps1 plants `bp0`/`ba` breakpoints
# through New-CdbScript's -PrologCommands, and those are int3 too. cdb matches an
# int3 against its own breakpoint list before it consults the exception filters,
# so both must still work in the SAME run -- the planted breakpoint's command
# file runs, and the panic that follows is still captured.
if ((Test-Path $panicExe) -and $cdb) {
    $bpDir = Join-Path $work 'dumps-bp'
    New-Item -ItemType Directory -Path $bpDir -Force | Out-Null
    $bpScript = Join-Path $bpDir 'bp.cdb'
    $bpLog = Join-Path $bpDir 'bp.log'
    New-CdbScript -DumpPath (Join-Path $bpDir 'bp.dmp') `
        -PrologCommands @('bp0 panic!inner ".echo GHOZTTY-BP-HIT; g"') |
        Set-Content -LiteralPath $bpScript -Encoding ASCII
    Check 'the cdb script arms the breakpoint-exception filter' `
    ((Get-Content -LiteralPath $bpScript -Raw) -match '\bbpe\b')

    $prevSym = $env:_NT_SYMBOL_PATH
    $env:_NT_SYMBOL_PATH = $work
    & $cdb -lines -cf $bpScript $panicExe > $bpLog 2>$null
    $env:_NT_SYMBOL_PATH = $prevSym

    $bpText = (Get-Content -LiteralPath $bpLog -Raw -ErrorAction SilentlyContinue)
    Check 'a planted breakpoint still fires with bpe armed' `
    ($bpText -match '(?m)^\s*(?:\d+:\d+>\s*)?GHOZTTY-BP-HIT\s*$') 'the bp0 command file never ran'
    Check 'the panic is still captured in that same run' `
    ($bpText -match '(?m)^\s*(?:\d+:\d+>\s*)?GHOZTTY-CRASH-BEGIN\s*$')
}

# ----------------------- 4e. how a run ENDED, read out of the transcript (T478)

# Unit-level, on synthetic transcripts: these are the branches that decide
# whether a run is allowed to be called clean, and staging each of them for real
# would take a program per case.
function New-FakeLog {
    param([string]$Name, [string[]]$Body)
    $p = Join-Path $work $Name
    $Body | Set-Content -LiteralPath $p -Encoding ASCII
    return $p
}
$okLog = New-FakeLog 'fake-ok.log' @(
    '0:000> sxe -c ".echo GHOZTTY-CRASH-BEGIN" av; g; .echo GHOZTTY-EXIT-BEGIN; .lastevent; q',
    'GHOZTTY-EXIT-BEGIN',
    'Last event: 1a3c.20f0: Exit process 0:1a3c, code 0',
    'GHOZTTY-EXIT-END'
)
$ok = Read-CrashCatchLog -LogPath $okLog
Check 'a watched exit 0 is clean' ((-not $ok.Crashed) -and (-not $ok.Uncaught) -and $ok.ExitObserved)
Check 'the debuggee exit code is read out' ($ok.DebuggeeExitCode -eq 0) "got '$($ok.DebuggeeExitCode)'"

$hexLog = New-FakeLog 'fake-hex.log' @(
    'GHOZTTY-EXIT-BEGIN',
    'Last event: 1a3c.20f0: Exit process 0:1a3c, code 1a',
    'GHOZTTY-EXIT-END'
)
$hex = Read-CrashCatchLog -LogPath $hexLog
# cdb prints that code in HEX. Reading it as decimal turns exit 26 into exit 1a
# and every decode downstream is then wrong about which crash it was.
Check 'the exit code is read as hex, not decimal' ($hex.DebuggeeExitCode -eq 26) "got '$($hex.DebuggeeExitCode)'"
Check 'a nonzero exit is UNCAUGHT, never clean' ($hex.Uncaught)
Check 'the uncaught detail names the code' ($hex.UncaughtDetail -match '0x0000001A') "got '$($hex.UncaughtDetail)'"

$breakLog = New-FakeLog 'fake-break.log' @(
    'GHOZTTY-EXIT-BEGIN',
    'Last event: 1a3c.20f0: Break instruction exception - code 80000003 (first chance)',
    'GHOZTTY-EXIT-END'
)
$brk = Read-CrashCatchLog -LogPath $breakLog
Check 'a break that no filter claimed is UNCAUGHT' ($brk.Uncaught -and -not $brk.ExitObserved)
Check 'the uncaught detail says the debuggee never exited' ($brk.UncaughtDetail -match 'never exited') "got '$($brk.UncaughtDetail)'"

# cdb killed on timeout leaves a transcript that just stops. That is the least
# explainable outcome of all, and the one most easily mistaken for a clean run.
$truncLog = New-FakeLog 'fake-trunc.log' @('ModLoad: 00007ff7`ff790000 panic.exe')
$trunc = Read-CrashCatchLog -LogPath $truncLog
Check 'a transcript with no ending at all is UNCAUGHT' ($trunc.Uncaught)
$missing = Read-CrashCatchLog -LogPath (Join-Path $work 'no-such-transcript.log')
Check 'a missing transcript is UNCAUGHT' ($missing.Uncaught)

# The decode is EXACT here, because the full 32-bit code survives: the low-byte
# table CrashDiag uses would otherwise call a plain `exit(5)` an access violation.
Check 'a real STATUS_BREAKPOINT is decoded by name' `
((Format-DebuggeeExitCode -Code 0x80000003) -match 'STATUS_BREAKPOINT') "got '$(Format-DebuggeeExitCode -Code 0x80000003)'"
Check 'an ordinary exit 5 is NOT called an access violation' `
((Format-DebuggeeExitCode -Code 5) -notmatch 'ACCESS_VIOLATION') "got '$(Format-DebuggeeExitCode -Code 5)'"

# ---------------------- 5-. a nonzero exit with no exception is never "clean"

if (Test-Path $exitExe) {
    $exitDir = Join-Path $work 'dumps-exit'
    $eOut = & powershell -NoProfile -File (Join-Path $Repo 'scripts\crash-catch.ps1') `
        -Exe $exitExe -OutDir $exitDir -TimeoutSeconds 120 2>&1
    $eCode = $LASTEXITCODE
    $eText = ($eOut | Out-String)
    Check 'an unexplained death exits 3' ($eCode -eq 3) "got $eCode"
    Check 'it is reported as UNCAUGHT with the decoded exit code' `
    ($eText -match 'UNCAUGHT \(exit 0x0000001A\)') "tail: $($eText -replace '\s+', ' ')"
    Check 'it is never called a clean run' `
    ($eText -notmatch 'ran clean|ran to completion') "tail: $($eText -replace '\s+', ' ')"
    # The transcript is evidence here, unlike on a genuinely clean attempt.
    Check 'the transcript is kept for an uncaught death' `
    ((@(Get-ChildItem $exitDir -Filter '*.log' -ErrorAction SilentlyContinue)).Count -ge 1)
}

# ------------------------------------- 5. a clean run must not invent a crash

if (Test-Path $cleanExe) {
    $cleanOutDir = Join-Path $work 'dumps-clean'
    $out2 = & powershell -NoProfile -File (Join-Path $Repo 'scripts\crash-catch.ps1') `
        -Exe $cleanExe -OutDir $cleanOutDir -TimeoutSeconds 120 2>&1
    $code2 = $LASTEXITCODE
    $text2 = ($out2 | Out-String)
    Check 'a clean run exits 0' ($code2 -eq 0) "got $code2"
    Check 'a clean run says no crash' ($text2 -match 'no crash in') "tail: $($text2 -replace '\s+', ' ')"
    Check 'a clean run writes no dump' `
    ((@(Get-ChildItem $cleanOutDir -Filter '*.dmp' -ErrorAction SilentlyContinue)).Count -eq 0)
    # Attempts that came back clean must not accumulate: with -Attempts 6 that
    # is five useless transcripts burying the one that matters.
    Check 'a clean run leaves no transcript behind' `
    ((@(Get-ChildItem $cleanOutDir -File -ErrorAction SilentlyContinue)).Count -eq 0) `
    ((Get-ChildItem $cleanOutDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ',')
}

# ---------------------------------------------- 6. bad input fails, not hangs

$bad = & powershell -NoProfile -File (Join-Path $Repo 'scripts\crash-catch.ps1') `
    -Exe (Join-Path $work 'no-such-thing.exe') -OutDir $outDir 2>&1
Check 'a missing exe exits 2' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"

$noArgs = & powershell -NoProfile -File (Join-Path $Repo 'scripts\crash-catch.ps1') 2>&1
Check 'no target exits 2 with guidance' ($LASTEXITCODE -eq 2 -and ($noArgs | Out-String) -match '-Lane') "got $LASTEXITCODE"

# ------------------------------------------------- 7. lane binary resolution

foreach ($lane in @('none', 'win32', 'agent')) {
    $bins = @(Get-LaneTestBinary -Lane $lane -Repo $Repo)
    if ($bins.Count -eq 0) {
        Write-Host "SKIP lane '$lane' has no built test binary to resolve"
        $script:skipped++
        continue
    }
    Check "lane '$lane' resolves to a real exe" ((Test-Path -LiteralPath $bins[0]) -and $bins[0] -match '\.exe$') $bins[0]
}

# --------------------------------- 7b. the lane log names the exact binary

# Newest-by-write-time is a guess: `none` and `win32` build the SAME exe name
# into different cache directories, so a lane that hits its build cache would
# send the capture at the other lane's binary. The log is authoritative.
$fakeRepo = Join-Path $work 'fakerepo'
$fakeExeDir = Join-Path $fakeRepo '.zig-cache\o\18abc11b912d836de1edfaecdb8c3016'
New-Item -ItemType Directory -Path $fakeExeDir -Force | Out-Null
$fakeExe = Join-Path $fakeExeDir 'ghostty-test.exe'
Set-Content -LiteralPath $fakeExe -Value 'x' -Encoding ASCII
$laneLog = Join-Path $work 'lane.log'
@(
    "error: while executing test 'terminal.search.screen.test.select prev with history', the following command exited with code 3 (expected exited with code 0):",
    '".\\.zig-cache\\o\\18abc11b912d836de1edfaecdb8c3016\\ghostty-test.exe" "--cache-dir=.\\.zig-cache" --seed=0x6332026c --listen=-'
) | Set-Content -LiteralPath $laneLog -Encoding ASCII

$fromLog = Get-FailingTestBinaryFromLog -LogPath $laneLog -Repo $fakeRepo
Check 'the failing test binary is read out of the lane log' `
($fromLog -eq (Resolve-Path -LiteralPath $fakeExe).Path) "got '$fromLog'"

$noneLog = Join-Path $work 'lane-clean.log'
'error: expected type u8, found u16' | Set-Content -LiteralPath $noneLog -Encoding ASCII
Check 'a log with no command names nothing' ($null -eq (Get-FailingTestBinaryFromLog -LogPath $noneLog -Repo $fakeRepo))

# A path in the log that is no longer on disk must not be returned as if it were.
$goneLog = Join-Path $work 'lane-gone.log'
'".\\.zig-cache\\o\\deadbeef\\ghostty-test.exe" "--cache-dir=.\\.zig-cache"' | Set-Content -LiteralPath $goneLog -Encoding ASCII
Check 'a stale path in the log is rejected' ($null -eq (Get-FailingTestBinaryFromLog -LogPath $goneLog -Repo $fakeRepo))

# --------------------------------------------- 8. the wrapper still runs with it

$laneOut = & powershell -NoProfile -File (Join-Path $Repo 'scripts\floor-lane.ps1') -SelfTest 2>&1
$laneText = ($laneOut | Out-String)
Check 'floor-lane self-test still passes with the catcher wired in' ($laneText -match 'ALL PASS') `
    "tail: $(($laneOut | Select-Object -Last 3) -join ' / ')"

# --------------------------------------------------------------------- cleanup

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

# --- stamp (T783 / T478) ---------------------------------------------------
# A clean green run records the content of every file it covers, so
# scripts\guard-due.ps1 can answer "has anybody run this harness against the
# code as it now stands?". Only a CLEAN sweep stamps: a run with a skipped
# section proved less than the harness claims, and a red run must stay due.
if ($failures -eq 0 -and -not $script:skipped) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard crash-stacks -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

if ($failures -eq 0) { Write-Host "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" } else { Write-Host "$failures FAILURE(S)" }
exit $(if ($failures -eq 0) { 0 } else { 1 })
