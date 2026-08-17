# harness-exitcode-audit acceptance (T197): no script in the suite reads a
# process's ExitCode without having cached its handle first.
#
#   powershell -NoProfile -File test\win32\harness-exitcode-audit.ps1
#
# Non-interactive, launches no Ghoztty and touches no user state: the subject
# is the HARNESS, so this reads .ps1 text and spawns nothing heavier than
# `cmd /c exit`.
#
# Why it exists. `Start-Process -PassThru` + a timed `WaitForExit(ms)` leaves
# `$p.ExitCode` EMPTY unless something touched `$p.Handle` while the child was
# still alive. Every caller that gates on `if ($code -ne 0) { fail }` then
# scores a WORKING CLI as a failure - and a fabricated failure costs more than
# a missed one, because it sends the next session hunting a defect that is not
# there. The trap was written down once (T145, "the harness lied three times"),
# recurred anyway in T147 (six red assertions against a build whose complete
# +list output sat in the redirect file), and was copy-pasted into 28 more
# sites in the meantime. A rule nobody can forget is a rule a script checks.
#
# Section A gives the analyzer teeth against fixtures; section B is the sweep
# that must stay at zero; section C measures the trap itself on this box.
param()

$ErrorActionPreference = 'Continue'
$script:failures = 0
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# isolation: none - a static audit over script TEXT; nothing here launches
# ghoztty or runs a CLI verb, the +list mentions are quoted fixture/commentary
# (T680 meta-check reads this marker).

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\ExitCodeAudit.ps1')

# Count findings for an inline fixture. The leading comma is load-bearing: a
# bare `return @(...)` UNROLLS, so a one-finding result comes back as a scalar
# whose `.Count` is $null and every assertion below silently passes (PS 5.1).
function Findings($lines) { return , @(Get-ExitCodeAuditFindings -Text $lines) }

# ============================================================================
"== A: the analyzer catches the shape it exists for, and only that shape"
# ============================================================================
# A fixture is the literal text of a helper, so these read as the code they
# are judging rather than as regex trivia.

$bad = @(
    'function Run-Cli($argsLine, $out) {',
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c foo"',
    '    if (-not $p.WaitForExit(15000)) { return $null }',
    '    return $p.ExitCode',
    '}'
)
$f = Findings $bad
Assert "A1 the copy-pasted helper is a finding" ($f.Count -eq 1)
Assert "A2 the finding names the never-cached case" (
    $f.Count -eq 1 -and $f[0].Reason -match 'never cached')
Assert "A3 the finding points at the Start-Process line" ($f.Count -eq 1 -and $f[0].Line -eq 2)
Assert "A4 the finding names the variable" ($f.Count -eq 1 -and $f[0].Variable -eq '$p')

$good = @(
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c foo"',
    '    $null = $p.Handle',
    '    if (-not $p.WaitForExit(15000)) { return $null }',
    '    $p.WaitForExit()',
    '    return $p.ExitCode'
)
Assert "A5 handle-first is clean" ((Findings $good).Count -eq 0)

# The preferred shape, and it must never be nagged at: judging the OUTPUT is
# better than judging the exit code, not a lesser workaround for it.
$outputGated = @(
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c foo"',
    '    if (-not $p.WaitForExit(15000)) { return $null }',
    '    return (Get-Content $out -Raw)'
)
Assert "A6 an output-gated site is clean" ((Findings $outputGated).Count -eq 0)

# The timing-dependent middle ground: it works today only because this child
# happens to be slow, which is not the same thing as being correct.
$late = @(
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c foo"',
    '    if (-not $p.WaitForExit(15000)) { return $null }',
    '    $null = $p.Handle',
    '    return $p.ExitCode'
)
$f = Findings $late
Assert "A7 a handle cached AFTER the wait is a finding" ($f.Count -eq 1)
Assert "A8 the finding says which came first" (
    $f.Count -eq 1 -and $f[0].Reason -match 'after \.WaitForExit')

$waited = @(
    '    $p = Start-Process msiexec.exe -ArgumentList $a -Wait -PassThru',
    '    return $p.ExitCode'
)
Assert "A9 -Wait needs no handle and is exempt" ((Findings $waited).Count -eq 0)

$marked = @(
    '    # exitcode-audit: the child is deliberately left running past the read',
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c foo"',
    '    if (-not $p.WaitForExit(15000)) { return $null }',
    '    return $p.ExitCode'
)
Assert "A10 an explicit marker exempts a site" ((Findings $marked).Count -eq 0)

# Nearly every real site in the suite is written across two physical lines, so
# an analyzer that cannot join a backtick continuation sees none of them.
$continued = @(
    '    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden `',
    '        -PassThru -ArgumentList "/c foo"',
    '    if (-not $p.WaitForExit(15000)) { return $null }',
    '    return $p.ExitCode'
)
$f = Findings $continued
Assert "A11 -PassThru on a continued line is still seen" ($f.Count -eq 1)
Assert "A12 a continued site reports its FIRST physical line" ($f.Count -eq 1 -and $f[0].Line -eq 1)

$commented = @(
    '    # $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c foo"',
    '    # return $p.ExitCode'
)
Assert "A13 a commented-out call is not a site" ((Findings $commented).Count -eq 0)

# Killing the child by pid on timeout is not a handle-needing read, so a
# `.Id` touch before the wait must not be mistaken for one.
$idFirst = @(
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c foo"',
    '    if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force; return $null }',
    '    return $p.ExitCode'
)
$f = Findings $idFirst
Assert "A14 .Id does not count as caching the handle" (
    $f.Count -eq 1 -and $f[0].Reason -match 'never cached')

$twoSites = @(
    '    $good = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c a"',
    '    $null = $good.Handle',
    '    $null = $good.WaitForExit(1000); $x = $good.ExitCode',
    '    $bad = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c b"',
    '    $null = $bad.WaitForExit(1000); $y = $bad.ExitCode'
)
$f = Findings $twoSites
Assert "A15 two sites are judged independently" ($f.Count -eq 1)
Assert "A16 the clean one is not the one reported" ($f.Count -eq 1 -and $f[0].Variable -eq '$bad')

# Reusing one variable for two launches is two sites, and the second one's
# handle is its own problem - a cache from the first process does not carry.
$reassigned = @(
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c a"',
    '    $null = $p.Handle',
    '    $null = $p.WaitForExit(1000); $x = $p.ExitCode',
    '    $p = Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c b"',
    '    $null = $p.WaitForExit(1000); $y = $p.ExitCode'
)
$f = Findings $reassigned
Assert "A17 a reassigned variable starts a fresh site" ($f.Count -eq 1 -and $f[0].Line -eq 4)

# ============================================================================
""
"== B: the suite is clean, and stays clean"
# ============================================================================
# Both roots, because the trap does not care which directory it is in: the
# `+list` probe the loop's own resume path runs lives under scripts\, and a
# false "no windows" there stalls the loop rather than reddening a test.
$sweep = @()
foreach ($root in @('test\win32', 'scripts')) {
    $sweep += @(Get-ExitCodeAuditSweep (Join-Path $Repo $root))
}
foreach ($v in $sweep) {
    $rel = $v.Path.Substring($Repo.Length + 1)
    "  VIOLATION $rel`:$($v.Line) $($v.Variable) reads ExitCode at line $($v.ExitLine) - $($v.Reason)"
}
Assert "B1 no unguarded ExitCode read in test\win32 or scripts" ($sweep.Count -eq 0)

# The sweep is only worth anything if it is actually reading the files: a
# glob that matched nothing would report zero violations and look identical.
$scanned = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32') -Recurse -Filter *.ps1 -File).Count
Assert "B2 the sweep really read the suite (>60 scripts)" ($scanned -gt 60)

# The two shapes the fix took, spot-checked where they actually live - so a
# later edit that drops the line is caught by name, not only by the analyzer.
$p1 = Get-Content -LiteralPath (Join-Path $Repo 'test\win32\ipc-p1.ps1') -Raw
Assert "B3 P1's second-instance probe caches the handle" ($p1 -match '\$null = \$second\.Handle')
$live = Get-Content -LiteralPath (Join-Path $Repo 'test\win32\lib\PaneLiveness.ps1') -Raw
Assert "B4 the shared liveness CLI caches the handle" ($live -match '\$null = \$p\.Handle')
$loop = Get-Content -LiteralPath (Join-Path $Repo 'scripts\loop-session.ps1') -Raw
Assert "B5 the loop's +list probe caches the handle" ($loop -match '\$null = \$p\.Handle')

# ============================================================================
""
"== C: the trap is real on this box, measured rather than remembered"
# ============================================================================
# `cmd /c exit 7` is over before PowerShell gets back to us, which is the
# condition the trap needs. Two shapes are run because they behave DIFFERENTLY
# and that difference is the whole reason this went unexplained for two turns:
# a redirecting Start-Process loses the code, a non-redirecting one does not.
#
# Only the CACHED direction is asserted. Asserting the uncached one would be
# asserting that a PowerShell bug still exists, so a future PowerShell that
# fixed it would turn this red - the exact fabricated failure this task is
# about. The numbers are printed instead, which is evidence either way.
$rounds = 5
$probeOut = Join-Path $env:TEMP "ghoztty-exitcode-probe-$PID.txt"
$cachedOk = 0
$lostRedirect = 0
$lostPlain = 0
for ($i = 0; $i -lt $rounds; $i++) {
    $c = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru -ArgumentList '/c exit 7' `
        -RedirectStandardOutput $probeOut -RedirectStandardError "$probeOut.err"
    $null = $c.Handle
    $null = $c.WaitForExit(10000)
    $c.WaitForExit()
    if ($c.ExitCode -eq 7) { $cachedOk++ }

    # exitcode-audit: these two ARE the unguarded shape - they are the measurement.
    $u = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru -ArgumentList '/c exit 7' `
        -RedirectStandardOutput $probeOut -RedirectStandardError "$probeOut.err"
    $null = $u.WaitForExit(10000)
    $code = 'lost'; try { $code = $u.ExitCode } catch { $code = 'lost' }
    if ($code -ne 7) { $lostRedirect++ }

    # exitcode-audit: the no-redirect control, uncached on purpose.
    $n = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru -ArgumentList '/c exit 7'
    $null = $n.WaitForExit(10000)
    $code = 'lost'; try { $code = $n.ExitCode } catch { $code = 'lost' }
    if ($code -ne 7) { $lostPlain++ }
}
Remove-Item $probeOut, "$probeOut.err" -Force -ErrorAction SilentlyContinue
Assert "C1 a cached handle reads the real exit code every time ($cachedOk/$rounds)" (
    $cachedOk -eq $rounds)
"  NOTE uncached + redirected streams lost the code: $lostRedirect/$rounds"
"  NOTE uncached, no redirect,  lost the code: $lostPlain/$rounds"
"  NOTE PowerShell $($PSVersionTable.PSVersion)"

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
