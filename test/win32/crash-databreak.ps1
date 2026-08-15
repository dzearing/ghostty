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

    - the PROBE parses a real Zig Debug prologue in both of its allocation
      shapes -- plain `sub rsp,X`, and the `__chkstk` probe form a frame over
      4 KB gets (T834) -- including spills routed through a scratch register,
      and same-named overloads picked apart by signature,
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

# A frame over 4 KB, which the compiler allocates with a __chkstk stack probe
# instead of a plain `sub rsp,X`, and which saves two more registers before it
# (T834). That is the shape Page.verifyIntegrity grew into once T443's own
# diagnostics widened it, and the probe refused it until this fixture existed.
# The inline-asm clobber is what forces the `push rsi` / `push rdi` pair
# deterministically -- a big frame alone does not produce them, and those
# pushes are exactly what moves the return-address slot.
@(
    'const std = @import("std");',
    'noinline fn victim(a: u64, b: u64, c: u64) u64 {',
    '    var buf: [700]u64 = undefined;',
    '    var i: usize = 0;',
    '    while (i < buf.len) : (i += 1) buf[i] = a +% i;',
    '    asm volatile ("nop"',
    '        :',
    '        :',
    '        : .{ .rsi = true, .rdi = true });',
    '    return buf[buf.len - 1] +% b *% 3 +% c;',
    '}',
    'pub fn main() !void {',
    '    var sum: u64 = 0;',
    '    var i: u64 = 0;',
    '    while (i < 40) : (i += 1) {',
    '        sum +%= victim(i, 2, 3);',
    '    }',
    '    std.debug.print("sum={x}\n", .{sum});',
    '}'
) | Set-Content -Path (Join-Path $work 'bigframe.zig') -Encoding ASCII

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

# The same staged wild write, but slowly: the T832 mode ATTACHES to a process
# somebody else started, so the fixture has to still be alive when cdb arrives.
# It idles for a beat, then stomps once a tick for long enough that an attach
# lands well before the write.
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
    '    std.Thread.sleep(4 * std.time.ns_per_s);',
    '    var i: u64 = 0;',
    '    var r: u64 = 0;',
    '    while (i < 60) : (i += 1) {',
    '        r +%= victim(0x1234, 2, 3);',
    '        std.Thread.sleep(100 * std.time.ns_per_ms);',
    '    }',
    '    std.debug.print("r={x}\n", .{r});',
    '}'
) | Set-Content -Path (Join-Path $work 'slowstomp.zig') -Encoding ASCII

# The T474/T838 shape: the watched bytes are a HEAP field, not a stack slot.
# Six objects whose first field is a page-aligned pointer -- the same layout as
# Page.memory.ptr -- are checked thousands of times, so the instrument must arm
# on the first four DISTINCT ones and then stop breaking at all. Three writes
# then land on watched addresses, and only one may be reported:
#   - a legitimate re-assignment of objs[0].ptr (a pooled page re-initialised at
#     the same slot), waved through because the value stays plausible;
#   - the same T443-shaped scribble on objs[2], but with its `len` changed
#     first -- that is RECYCLED memory, and the shape guard must reject it. This
#     case is not hypothetical: without the guard the first armed run of the
#     real agent lane reported hyperlink.dupe memcpy-ing a URI into a later
#     page's string_alloc over a freed page's address;
#   - the 4-byte scribble over objs[1].ptr's HIGH half with `len` intact, which
#     is the exact T443 damage and is the one that must be caught.
@(
    'const std = @import("std");',
    'const Obj = struct { ptr: [*]u8, len: usize, tag: u64 };',
    'var bufs: [6][4096]u8 align(4096) = undefined;',
    'var objs: [6]Obj = undefined;',
    'noinline fn check(self: *Obj, a: u64, b: u64) u64 {',
    '    return @intFromPtr(self.ptr) +% self.len +% a +% b;',
    '}',
    'noinline fn unused(self: *Obj, a: u64, b: u64) u64 {',
    '    return @intFromPtr(self.ptr) +% a +% b;',
    '}',
    'noinline fn stomp(p: *u32) void {',
    '    p.* = 0x11a60;',
    '}',
    'pub fn main() !void {',
    '    var sum: u64 = 0;',
    '    for (&objs, 0..) |*o, i| {',
    '        o.* = .{ .ptr = &bufs[i], .len = bufs[i].len, .tag = i };',
    '    }',
    '    var round: usize = 0;',
    '    while (round < 500) : (round += 1) {',
    '        for (&objs) |*o| sum +%= check(o, 2, 3);',
    '    }',
    '    if (objs[0].tag == 12345) sum +%= unused(&objs[0], 1, 2);',
    '    objs[0].ptr = &bufs[0];',
    '    sum +%= check(&objs[0], 2, 3);',
    '    var k: usize = 0;',
    '    while (k < 1100) : (k += 1) objs[3].ptr = &bufs[3];',
    '    objs[2].len = 999;',
    '    const hi2: *u32 = @ptrFromInt(@intFromPtr(&objs[2]) + 4);',
    '    stomp(hi2);',
    '    sum +%= check(&objs[2], 2, 3);',
    '    const hi: *u32 = @ptrFromInt(@intFromPtr(&objs[1]) + 4);',
    '    stomp(hi);',
    '    sum +%= check(&objs[1], 2, 3);',
    '    std.debug.print("sum={x}\n", .{sum});',
    '}'
) | Set-Content -Path (Join-Path $work 'pagewatch.zig') -Encoding ASCII

Push-Location $work
foreach ($src in @('stompctl.zig', 'loopctl.zig', 'overload.zig', 'crashctl.zig', 'slowstomp.zig', 'bigframe.zig', 'pagewatch.zig')) {
    $b = & zig build-exe $src 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host ("build failed for {0}: {1}" -f $src, ($b -join ' ')) }
}
Pop-Location
foreach ($exe in @('stompctl.exe', 'loopctl.exe', 'overload.exe', 'crashctl.exe', 'slowstomp.exe', 'bigframe.exe', 'pagewatch.exe')) {
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
    Check 'a small frame is reported as the plain sub shape' `
    ($probe.FrameShape -eq 'sub' -and $probe.ExtraPushes -eq 0) `
    "shape=$($probe.FrameShape) pushes=$($probe.ExtraPushes)"
}

# ------------------------------------- 3b. the >4 KB frame shape (T834)
#
# Past 4 KB the compiler allocates the frame with a __chkstk stack probe and
# saves two more registers first. The probe read only the small-frame shape
# and REFUSED this one, which is what stalled T443's hunt: its own diagnostics
# had grown Page.verifyIntegrity's frame to 0x1020 bytes. The frame facts must
# come out the same, and the extra pushes must move the return-address slot --
# that slot is where the one-shot disarm breakpoint goes, so getting it wrong
# would leave every armed slot live after the function returned.

$big = Invoke-DataBreakProbe -Exe (Join-Path $work 'bigframe.exe') -Symbol victim
Check 'probe succeeds on a >4 KB frame' $big.Ok $big.Error
if ($big.Ok) {
    Check 'the __chkstk allocation shape is recognised' ($big.FrameShape -eq 'chkstk') "got $($big.FrameShape)"
    Check 'the frame size comes from the __chkstk argument' ($big.FrameSub -gt 4096) `
    ("got 0x{0:x}" -f $big.FrameSub)
    Check 'the callee-saved pushes before it are counted' ($big.ExtraPushes -eq 2) "got $($big.ExtraPushes)"
    Check 'the pushes move the return slot' `
    ($big.RetSlotOffset -eq (8 + (8 * $big.ExtraPushes) + $big.FrameSub - $big.FrameLea)) `
    ("got 0x{0:x}" -f $big.RetSlotOffset)
    Check 'spills are still found past the bigger prologue' ($big.Spills.Count -ge 3) "got $($big.Spills.Count)"
    Check 'the arm point is past the whole prologue' `
    ($big.ArmOffset -gt 0 -and $big.ArmRva -eq ($big.EntryRva + $big.ArmOffset)) "got $($big.ArmOffset)"

    # The frame math, proven rather than asserted: an arm count that matches
    # the disarm count means the one-shot breakpoint on the return-address
    # slot fired every single time.
    $bigOut = Join-Path $work 'dumps-bigframe'
    $out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'bigframe.exe') -Symbol victim -ShowProbe -OutDir $bigOut 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    Check 'a __chkstk frame arms and runs clean' ($code -eq 0) "got $code, tail: $($text -replace '\s+', ' ')"
    Check 'every call armed (40 cycles)' ($text -match '40 arm cycle\(s\)') "tail: $($text -replace '\s+', ' ')"
    Check 'every call disarmed on return' ($text -match '40 disarm\(s\)')
    # A transcript that said "sub rsp,X" for a frame with no such instruction
    # would send the next reader looking for the wrong bytes.
    Check 'the transcript names the allocation shape it read' `
    ($text -match 'frame: 2 push\(es\) \+ mov eax,0x[0-9a-f]+/__chkstk') `
    ($(($out | Select-String -Pattern 'frame:' | Select-Object -First 1) -replace '\s+', ' '))
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

# ------------- 8. the T832 mode: arm a process somebody else launches
#
# The T443 corruption only ever happens under `zig build`, which starts the
# test binary itself -- so the tool has to be able to arm a process it did not
# launch. It ATTACHES (`cdb -p`), which keeps the whole single-process recipe
# intact; following children (`cdb -o`) was tried first and cannot work here,
# for the two reasons the driver's -UnderBuildRunner help records. Proven
# against the same staged wild write in a process this script started
# independently of the debugger.

$slowSlot = $null
$ssp = Invoke-DataBreakProbe -Exe (Join-Path $work 'slowstomp.exe') -Symbol victim
if ($ssp.Ok) {
    # Same shape as stompctl's `victim`, so the same spill is the aliased copy.
    $lastSpill = @($ssp.Spills | Where-Object { $_.Origin -eq 'rdx' } | Select-Object -Last 1)
    if ($lastSpill.Count -eq 1) { $slowSlot = $lastSpill[0].Offset }
}
Check 'the slow-stomp fixture probe finds the copy slot' ($null -ne $slowSlot) "ok=$($ssp.Ok) err=$($ssp.Error)"

if ($null -ne $slowSlot) {
    $attachOut = Join-Path $work 'dumps-attach'
    $victimExe = Join-Path $work 'slowstomp.exe'
    $vp = Start-Process -FilePath $victimExe -PassThru -WindowStyle Hidden
    $null = $vp.Handle
    $r = Invoke-DataBreak -Exe $victimExe -Symbol victim -SlotOffsets $slowSlot -OutDir $attachOut `
        -AttachPid $vp.Id -TimeoutSeconds 180 -Writer { param($s) }
    try { if (-not $vp.HasExited) { Stop-Process -Id $vp.Id -Force -ErrorAction SilentlyContinue } } catch {}

    Check 'attaching to a running process arms it' ($r.ArmCount -gt 0) `
    ("armed=$($r.ArmCount) err=$($r.Error) exit=$($r.ExitCode)")
    Check 'the attached run catches the wild write' $r.Hit "armed=$($r.ArmCount) hit=$($r.Hit)"
    Check 'the attached run names the writer' `
    (($r.WriterSite -match 'slowstomp!stomp') -or (($r.WriterBlock -join ' ') -match 'slowstomp!stomp')) `
    "writer=$($r.WriterSite)"
    Check 'the attached run walks the victim frame' (($r.StackBlock -join ' ') -match 'slowstomp!victim')
    Check 'the attached run dumps' ($r.DumpPath -and (Test-Path -LiteralPath $r.DumpPath))
}
else {
    Check 'attaching to a running process arms it' $false 'no copy slot from the slow-stomp probe'
}

# The driver defaults a lane to the build runner, and says which condition a
# standalone run measures -- the whole point of T832.
$out = & powershell -NoProfile -File $driver -Lane none -Exe (Join-Path $work 'loopctl.exe') `
    -Symbol victim -Standalone -OutDir (Join-Path $work 'dumps-warn') 2>&1
$text = ($out | Out-String)
Check 'a standalone lane run warns it is not the T443 condition' `
($text -match 'mode = STANDALONE' -and $text -match 'NEVER been observed in this condition' -and $text -match 'T832') `
    ($text -replace '\s+', ' ')
Check 'the standalone caveat is repeated in the verdict' ($text -match 'mode=standalone')

# ---------------- 8b. -WatchPages: a heap field, armed once, never disarmed
#
# T474/T838. The per-call shape arms and disarms around every call of the
# target: against the real Page.verifyIntegrity that is 335,878 round trips at
# ~2 ms, and the lane timed out mid-run having measured nothing. The damaged
# bytes are a heap field, so this mode arms on the object instead and then gets
# out of the way. What has to be true, and is checked here rather than asserted:
# the arm count is the number of WATCHED OBJECTS (not the number of calls), the
# entry breakpoint really is disabled afterwards, an ordinary write to a watched
# address does not stop the run, and the T443-shaped scribble does.

$pwOut = Join-Path $work 'dumps-pagewatch'
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'pagewatch.exe') -Symbol check `
    -WatchPages -WatchCount 4 -ShowProbe -OutDir $pwOut 2>&1
$code = $LASTEXITCODE
$text = ($out | Out-String)

Check 'a page-watch hit exits 1' ($code -eq 1) "got $code, tail: $($text -replace '\s+', ' ')"
Check 'the mode announces what it is blind to' `
($text -match 'PAGE-WATCH' -and $text -match 'four debug registers') ($text -replace '\s+', ' ')
Check 'the object pointer slot is named in the probe' `
($text -match 'object pointer read from: @rbp') ($text -replace '\s+', ' ')
# 3000+ calls of `check`, four arm cycles: the whole point of the redesign.
Check 'it arms per object, not per call' ($text -match '4 address\(es\) armed') `
    ($(($out | Select-String -Pattern 'address\(es\) armed|data breakpoint hit' | Select-Object -First 1) -replace '\s+', ' '))
# And then gets out of the way: without this the per-call cost the redesign
# exists to remove would still be paid for the rest of the run.
Check 'the entry breakpoint is disabled once full' ($text -match 'entry breakpoint disabled') `
    ($(($out | Select-String -Pattern 'address\(es\) armed' | Select-Object -First 1) -replace '\s+', ' '))
# An address that outlives its page can be recycled into memory something writes
# constantly. objs[3] is written 1100 times with a perfectly plausible pointer;
# at ~2 ms a break that is a run that never finishes, so the breakpoint must be
# dropped and the drop must be visible in the verdict.
Check 'an address that goes hot is dropped and counted' ($text -match '1 dropped as hot') `
    ($(($out | Select-String -Pattern 'address\(es\) armed' | Select-Object -First 1) -replace '\s+', ' '))
Check 'the T443-shaped scribble is caught' ($text -match 'implausible pointer was written') `
    ($text -replace '\s+', ' ')
Check 'the writer is named' ($text -match 'pagewatch!stomp') ($text -replace '\s+', ' ')
Check 'the writing instruction is shown' ($text -match 'mov\s+dword ptr \[\w+\],')
Check 'the watched address is reported' ($text -match 'watched address = [0-9a-f]+')
# The reported object is the one whose length is still 4096 -- objs[1]. If the
# shape guard were not doing its job the run would have stopped one write
# earlier, on objs[2], whose length had been changed to 999 (0x3e7) first.
Check 'recycled memory is rejected, the intact page is reported' `
($text -match '00000000.00001000' -and $text -notmatch '00000000.000003e7') `
    ($(($out | Select-String -Pattern '^\s+\|\s+[0-9a-f]{8}.[0-9a-f]{8}\s+[0-9a-f]' | Select-Object -First 1) -replace '\s+', ' '))
Check 'the victim frame is in the stack' ($text -match 'pagewatch!main')
$pwDumps = @(Get-ChildItem $pwOut -Filter '*.dmp' -ErrorAction SilentlyContinue)
Check 'a full dump is on disk' ($pwDumps.Count -ge 1 -and $pwDumps[0].Length -gt 100KB) `
($(if ($pwDumps.Count -ge 1) { "$($pwDumps[0].Length) bytes" } else { 'none' }))
Check 'the cdb helper files are cleaned up' `
((@(Get-ChildItem $pwOut -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(cdb|txt)$' })).Count -eq 0)

# The gate, proven from the other side: aim the same run at a field offset whose
# contents are NOT a plausible aligned pointer (`tag`, at +16, which holds a
# small index) and nothing arms. That is what stops a wrong -SelfSlotOffset from
# silently watching junk bytes and reporting a clean run.
$gateOut = Join-Path $work 'dumps-pagewatch-gate'
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'pagewatch.exe') -Symbol check `
    -WatchPages -FieldOffset 16 -OutDir $gateOut 2>&1
$code = $LASTEXITCODE
$text = ($out | Out-String)
Check 'a field that is not a pointer arms nothing' `
($code -eq 0 -and $text -match 'no candidate slot held an object the gates accept') `
    "got $code, tail: $($text -replace '\s+', ' ')"
# "the gates rejected everything" and "the function was never called" are
# different bugs with the same symptom, and a verdict that hedged between them
# sent one armed lane run against a binary that never calls the target.
Check 'the refusal says the target DID run' `
($text -match "'check' ran, but" -and $text -notmatch 'NEVER CALLED') ($text -replace '\s+', ' ')
Check 'the refusal lists every slot it tried' `
($text -match 'tried: @rbp-0x10, @rbp-0x8, @rbp') ($text -replace '\s+', ' ')
Check 'the refusal says how to aim it' ($text -match '-SelfSlotOffset') ($text -replace '\s+', ' ')

# The other half of that distinction: a target that is compiled in but never
# called. This is not hypothetical -- the first armed run of the real thing
# attached to ghoztty-agent-test.exe, where Page.verifyIntegrity is never
# called, and spent three minutes reporting a clean lane.
$neverOut = Join-Path $work 'dumps-pagewatch-never'
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'pagewatch.exe') -Symbol unused `
    -WatchPages -OutDir $neverOut 2>&1
$code = $LASTEXITCODE
$text = ($out | Out-String)
Check 'a target that is never called says so' `
($code -eq 0 -and $text -match 'NEVER CALLED' -and $text -match 'measured nothing at all') `
    "got $code, tail: $($text -replace '\s+', ' ')"

# ---------------------------------------------- 9. bad input fails, not hangs

$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'no-such.exe') 2>&1
Check 'a missing exe exits 2' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'loopctl.exe') -Symbol noSuchFn 2>&1
Check 'an unknown symbol exits 2' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"
$out = & powershell -NoProfile -File $driver 2>&1
Check 'no target exits 2 with guidance' ($LASTEXITCODE -eq 2 -and ($out | Out-String) -match '-Lane') "got $LASTEXITCODE"
$out = & powershell -NoProfile -File $driver -Exe (Join-Path $work 'loopctl.exe') -UnderBuildRunner 2>&1
Check '-UnderBuildRunner without a lane exits 2' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"
$out = & powershell -NoProfile -File $driver -Lane none -UnderBuildRunner -Standalone 2>&1
Check 'the two modes cannot both be asked for' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE"

# --------------------------------------------------------------------- cleanup

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

# --- stamp (T783 / T478) ---------------------------------------------------
# This harness has a guard row but never stamped itself, so the only way it
# could ever go green in `guard-due check` was somebody remembering to run
# `guard-due update` by hand -- which is the remembering T783 exists to remove.
# Only a CLEAN run stamps; a red one must stay due.
if ($failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard crash-databreak -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

if ($failures -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$failures FAILURE(S)" }
exit $(if ($failures -eq 0) { 0 } else { 1 })
