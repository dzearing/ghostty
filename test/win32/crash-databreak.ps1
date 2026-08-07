<#
.SYNOPSIS
    T458 - hardware data breakpoints on a function's spilled parameters must
    catch the instruction that writes them, in the act.

.DESCRIPTION
    The T443 corruption zeroes the spilled parameters of a live
    Page.verifyIntegrity frame. `scripts\crash-databreak.ps1` exists to stop
    the program at the moment of such a write and name the writer. This
    script proves the whole recipe against fixtures where the "wild write" is
    staged deliberately:

    - the PROBE parses a real Zig Debug prologue (including spills routed
      through a scratch register, and same-named overloads picked apart by
      signature),
    - the ARM/DISARM cycle runs per call without false positives (200 calls,
      0 hits on a clean function),
    - a write into an armed slot is CAUGHT with the writing instruction and
      the full stack,
    - a crash that never touches an armed slot still gets the T450-style
      crash capture (exit 3, not a silent pass).

.OUTPUTS
    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$Repo\scripts\lib\CrashCatch.ps1"
. "$Repo\scripts\lib\DataBreak.ps1"

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL $Name $Detail"; $script:failures++ }
}

$driver = Join-Path $Repo 'scripts\crash-databreak.ps1'

# ------------------------------------------------------------------- 1. cdb

$cdb = Get-CdbPath
Check 'a console cdb.exe is found' ($null -ne $cdb) 'none of the known locations had one'
if (-not $cdb) {
    Write-Host '1 FAILURE(S)'
    exit 1
}

# --------------------------------------------------- 2. build the fixtures

$work = Join-Path (Split-Path -Qualifier $Repo) ('\databreak-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    # CLAUDE.md: the global cache must sit on the repo's drive.
    $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $Repo) '\zig-global-cache')
}

# A callee scribbles over the caller's frame while it is live -- the staged
# version of the T443 wild write. Zig Debug codegen spills each parameter
# more than once; `&a` aliases a COPY slot, not the canonical first spill,
# which is why the positive test aims the tool with -SlotOffsets.
@(
    'const std = @import("std");',
    'noinline fn stomp(p: *u64) void {',
    '    p.* = 0x4141414141414141;',
    '}',
    'noinline fn victim(a: u64, b: u64, c: u64) u64 {',
    '    stomp(@constCast(&a));',
    '    return a +% b +% c;',
    '}',
    'pub fn main() !void {',
    '    const r = victim(0x1234, 2, 3);',
    '    std.debug.print("r={x}\n", .{r});',
    '}'
) | Set-Content -Path (Join-Path $work 'stompctl.zig') -Encoding ASCII

# A clean function called in a loop: every call must arm and disarm, and
# none may false-positive. The `victim(i, 2, 3)` args flow through a scratch
# register in the prologue (mov rax,rdx; mov [rbp-...],rax), which is the
# spill shape the parser must attribute back to the origin register.
@(
    'const std = @import("std");',
    'noinline fn victim(a: u64, b: u64, c: u64) u64 {',
    '    return a +% b *% 3 +% c;',
    '}',
    'pub fn main() !void {',
    '    var sum: u64 = 0;',
    '    var i: u64 = 0;',
    '    while (i < 200) : (i += 1) {',
    '        sum +%= victim(i, 2, 3);',
    '    }',
    '    std.debug.print("sum={x}\n", .{sum});',
    '}'
) | Set-Content -Path (Join-Path $work 'loopctl.zig') -Encoding ASCII

# Two container-scoped functions with the same bare name: Zig emits both as
# `pick`, exactly like Page.verifyIntegrity vs PageList.verifyIntegrity in
# the real test binary. The probe must refuse the bare name and accept a
# -SignatureFilter.
@(
    'const std = @import("std");',
    'const A = struct {',
    '    noinline fn pick(v: u64, w: u64, x: u64) u64 {',
    '        return v +% w *% 3 +% x;',
    '    }',
    '};',
    'const B = struct {',
    '    noinline fn pick(v: bool) u64 {',
    '        if (v) return 2;',
    '        return 3;',
    '    }',
    '};',
    'pub fn main() !void {',
    '    std.debug.print("{d} {d}\n", .{ A.pick(1, 2, 3), B.pick(true) });',
    '}'
) | Set-Content -Path (Join-Path $work 'overload.zig') -Encoding ASCII

# The target function runs clean, then something ELSE crashes: the armed run
# must still deliver the T450 crash capture rather than reporting a clean
# pass.
@(
    'const std = @import("std");',
    'noinline fn victim(a: u64, b: u64, c: u64) u64 {',
    '    return a +% b +% c;',
    '}',
    'noinline fn boom() void {',
    '    const p: *volatile u8 = @ptrFromInt(0x10);',
    '    p.* = 1;',
    '}',
    'pub fn main() !void {',
    '    _ = victim(1, 2, 3);',
    '    boom();',
    '}'
) | Set-Content -Path (Join-Path $work 'crashctl.zig') -Encoding ASCII

Push-Location $work
foreach ($src in @('stompctl.zig', 'loopctl.zig', 'overload.zig', 'crashctl.zig')) {
    $b = & zig build-exe $src 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host ("build failed for {0}: {1}" -f $src, ($b -join ' ')) }
}
Pop-Location
foreach ($exe in @('stompctl.exe', 'loopctl.exe', 'overload.exe', 'crashctl.exe')) {
    Check "fixture $exe built" (Test-Path (Join-Path $work $exe))
}
if (-not (Test-Path (Join-Path $work 'stompctl.exe'))) {
    Write-Host "$($failures + 1) FAILURE(S)"
    exit 1
}

# ------------------------------------------------- 3. the probe, structurally

$probe = Invoke-DataBreakProbe -Exe (Join-Path $work 'loopctl.exe') -Symbol victim
Check 'probe succeeds on a plain function' $probe.Ok $probe.Error
if ($probe.Ok) {
    Check 'probe finds spills' ($probe.Spills.Count -ge 3) "got $($probe.Spills.Count)"
    Check 'probe arms one slot per origin register' ($probe.ArmedSlots.Count -eq 3) "got $($probe.ArmedSlots.Count)"
    $origins = @($probe.ArmedSlots | ForEach-Object { $_.Origin } | Sort-Object)
    # Three integer args of a non-errorable fn arrive in rdx/r8/r9; a spill
    # routed through a scratch register must still be attributed to them.
    Check 'armed slots are attributed to the three param registers' `
    (($origins -join ',') -eq 'r8,r9,rdx') "got $($origins -join ',')"
    Check 'the arm point is past the prologue' ($probe.ArmOffset -gt 0) "got $($probe.ArmOffset)"
    Check 'the return slot follows from the frame math' `
    ($probe.RetSlotOffset -eq (8 + $probe.FrameSub - $probe.FrameLea)) "got $($probe.RetSlotOffset)"
    Check 'the module base was resolved' ($probe.ModuleBase -gt 0)
    Check 'the arm rva is module-relative' ($probe.ArmRva -eq ($probe.EntryRva + $probe.ArmOffset))
}

# --------------------------------------- 4. same-named overloads (the real
# ghoztty-agent-test.exe has TWO verifyIntegrity functions)

$amb = Invoke-DataBreakProbe -Exe (Join-Path $work 'overload.exe') -Symbol pick
Check 'a bare ambiguous symbol is refused' (-not $amb.Ok)
Check 'the refusal names -SignatureFilter and the candidates' `
($amb.Error -match 'SignatureFilter' -and $amb.Error -match 'bool') "got: $($amb.Error)"
# The bool overload is so small its prologue is a frameless `push rax`,
# which the probe refuses by design -- so the filter aims at the u64 one.
# (That refusal is itself a documented limit: leaf functions without a
# standard frame cannot be armed by this recipe.)
$one = Invoke-DataBreakProbe -Exe (Join-Path $work 'overload.exe') -Symbol pick -SignatureFilter 'int64'
Check 'a -SignatureFilter picks one overload' $one.Ok $one.Error
$none = Invoke-DataBreakProbe -Exe (Join-Path $work 'overload.exe') -Symbol pick -SignatureFilter 'no-such-sig'
Check 'a filter matching nothing is an error, not a guess' (-not $none.Ok)

# ----------------------------- 5. clean loop: arm per call, no false positive

$loopOut = Join-Path $work 'dumps-loop'
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'loopctl.exe') -Symbol victim -OutDir $loopOut 2>&1
$code = $LASTEXITCODE
$text = ($out | Out-String)
Check 'a clean run exits 0' ($code -eq 0) "got $code"
Check 'every call armed (200 cycles)' ($text -match '200 arm cycle\(s\)') "tail: $($text -replace '\s+', ' ')"
Check 'every call disarmed on return' ($text -match '200 disarm\(s\)')
Check 'a clean run leaves nothing behind' `
((@(Get-ChildItem $loopOut -File -ErrorAction SilentlyContinue)).Count -eq 0) `
((Get-ChildItem $loopOut -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ',')

# ------------------------------------------------ 6. the hit, end to end

$hitOut = Join-Path $work 'dumps-hit'
# Zig Debug spills a parameter more than once and `&a` aliases the LAST copy;
# the canonical slots are clean in this fixture, so the run aims at the copy
# slot explicitly. The arming machinery (ba + one-shot disarm + report) is
# identical for parsed and overridden slots.
$copySlot = $null
$sp = Invoke-DataBreakProbe -Exe (Join-Path $work 'stompctl.exe') -Symbol victim
if ($sp.Ok) {
    $last = @($sp.Spills | Where-Object { $_.Origin -eq 'rdx' } | Select-Object -Last 1)
    if ($last.Count -eq 1) { $copySlot = $last[0].Offset }
}
Check 'the stomp fixture probe finds the copy slot' ($null -ne $copySlot)
if ($null -ne $copySlot) {
    $out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'stompctl.exe') -Symbol victim `
        -SlotOffsets $copySlot -OutDir $hitOut 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    Check 'a wild write exits 1' ($code -eq 1) "got $code"
    Check 'the writer function is named' ($text -match 'stompctl!stomp') "tail: $($text -replace '\s+', ' ')"
    Check 'the writing instruction is shown' ($text -match 'mov\s+qword ptr \[rdx\],rax')
    Check 'the victim frame is in the stack' ($text -match 'stompctl!victim')
    Check 'the caller is in the stack too' ($text -match 'stompctl!main')
    Check 'frames carry source lines' ($text -match 'stompctl\.zig @ \d+')
    $dumps = @(Get-ChildItem $hitOut -Filter '*.dmp' -ErrorAction SilentlyContinue)
    Check 'a full dump is on disk' ($dumps.Count -ge 1 -and $dumps[0].Length -gt 100KB) `
    ($(if ($dumps.Count -ge 1) { "$($dumps[0].Length) bytes" } else { 'none' }))
    Check 'the transcript is kept' ((@(Get-ChildItem $hitOut -Filter '*.log' -ErrorAction SilentlyContinue)).Count -ge 1)
    Check 'the cdb helper files are cleaned up' `
    ((@(Get-ChildItem $hitOut -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(cdb|txt)$' })).Count -eq 0)
}

# -------------------------- 7. a crash that never touches an armed slot

$crashOut = Join-Path $work 'dumps-crash'
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'crashctl.exe') -Symbol victim -OutDir $crashOut 2>&1
$code = $LASTEXITCODE
$text = ($out | Out-String)
Check 'a crash without a hit exits 3' ($code -eq 3) "got $code"
Check 'the crash is still captured (T450 path)' ($text -match '0xc0000005') "tail: $($text -replace '\s+', ' ')"
Check 'the crash names the faulting site' ($text -match 'crashctl!boom')
Check 'the armed cycles before the crash are reported' ($text -match '1 arm cycle\(s\)')

# ---------------------------------------------- 8. bad input fails, not hangs

$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'no-such.exe') 2>&1
Check 'a missing exe exits 2' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'loopctl.exe') -Symbol noSuchFn 2>&1
Check 'an unknown symbol exits 2' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"
$out = & powershell -NoProfile -File $driver 2>&1
Check 'no target exits 2 with guidance' ($LASTEXITCODE -eq 2 -and ($out | Out-String) -match '-Lane') "got $LASTEXITCODE"

# --------------------------------------------------------------------- cleanup

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$failures FAILURE(S)" }
exit $(if ($failures -eq 0) { 0 } else { 1 })
