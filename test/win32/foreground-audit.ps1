<#
.SYNOPSIS
    T272 acceptance - an acceptance script that takes the user's foreground must
    be declared interactive-by-design, and the declaration must be true.

.DESCRIPTION
    Three sections:

      A. The declaration parser (`lib\ForegroundAudit.ps1`) against fixtures:
         a well-formed marker is read, a malformed one is named rather than
         silently dropped, and prose around the markers is ignored.

      B. The grab-site detector, both directions. The interesting half is what
         is NOT a finding: two thirds of this suite MENTIONS `SendInput` in a
         header explaining that it is dead on a background desktop, and reading
         those as violations would push 22 innocent scripts onto the exception
         list - the same rot from the other direction.

      C. The sweep over `test\win32\*.ps1`: every grab site is declared, and
         every declaration still names a script that grabs.

    `-TeethCheck` proves the section-C assertion can fail: it writes a real
    violator into the swept directory (a script with a live `SendInput`, on no
    list) and requires the sweep to find it. Run it after any change to the
    analyzer.

.NOTES
    # persistence: launches no GUI - this scores scripts, it does not run them.

    # foreground-audit: this script's fixtures are string literals holding the
    # very P/Invokes it detects (`[Drv]::SendInput(...)`), so it NAMES every
    # watched API without calling one. It takes no foreground: it launches
    # nothing, and section C's planted violator is deleted in a finally block.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Suite = Join-Path $Repo 'test\win32'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ForegroundAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

# ===========================================================================
Write-Host ''
Write-Host '== A: the declaration list, parsed out of the harness header'
# ===========================================================================

$declFixture = @(
    '# ESCAPE HATCH: -Interactive skips the desktop entirely.'
    '#'
    '# @input-desktop-exception: alpha.ps1 -- (T1) the injection timing IS the measurement.'
    '# @input-desktop-exception: beta.ps1 -- (T2) the subject is a real right-click.'
    '# prose about SendInput being dead here, which is not a declaration.'
)
$d = @(Get-ForegroundAuditDeclarations -Text $declFixture)
AssertEq 'A1 both marker lines are read' 2 @($d | Where-Object { -not $_.Malformed }).Count
AssertEq 'A2 the script name is captured' 'alpha.ps1' $d[0].Script
AssertEq 'A3 the reason is captured whole' '(T1) the injection timing IS the measurement.' $d[0].Reason
AssertEq 'A4 the marker line number is reported' 3 $d[0].Line

$badFixture = @(
    '# @input-desktop-exception: gamma.ps1'
    '# @input-desktop-exception: -- a reason with no script'
)
$bad = @(Get-ForegroundAuditDeclarations -Text $badFixture)
AssertEq 'A5 a declaration with no reason is malformed, not dropped' 2 @($bad | Where-Object { $_.Malformed }).Count

# The harness header is the real list; if this is empty the whole check is off.
$live = @(Get-ForegroundAuditDeclarations -Path (Join-Path $Suite 'lib\TestDesktop.ps1'))
Assert 'A6 the live harness header declares at least one exception' (@($live | Where-Object { -not $_.Malformed }).Count -ge 1)
AssertEq 'A7 and none of its declarations are malformed' 0 @($live | Where-Object { $_.Malformed }).Count

# ===========================================================================
Write-Host ''
Write-Host '== B: what is and is not a grab site'
# ===========================================================================

function SiteCount([string[]]$Text) { return @(Get-ForegroundAuditSites -Text $Text).Count }

Assert 'B1 a live P/Invoke call is a grab site' ((SiteCount @(
    '$null = [Drv]::SetForegroundWindow($hwnd)'
)) -ge 1)

Assert 'B2 so is a P/Invoke declared inside an Add-Type here-string' ((SiteCount @(
    'Add-Type @'''
    'public class Drv {'
    '  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int cb);'
    '}'
    ''''
)) -ge 1)

AssertEq 'B3 a PowerShell comment mentioning it is NOT a grab site' 0 (SiteCount @(
    '# SendInput is BLOCKED on a background desktop; posted messages replace it.'
    '# SetForegroundWindow fails there too.'
    'Send-TestKeys -Window $top -Key T'
))

AssertEq 'B4 nor is a C# comment inside an embedded here-string' 0 (SiteCount @(
    'Add-Type @'''
    'public class Drv {'
    '  // SendInput is dead off the input desktop - posted messages instead.'
    '  /* SetCursorPos too */'
    '  public static void Post() { }'
    '}'
    ''''
))

$sites = @(Get-ForegroundAuditSites -Text @(
    'Add-Type @'''
    'public class Drv {'
    '  public static void A() { }'
    '  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);'
    '}'
    ''''
))
AssertEq 'B5 a here-string site reports the line the call is really on' 4 $sites[0].Line

Assert 'B6 a hardcoded -Interactive is a grab site' ((SiteCount @(
    '$td = New-TestDesktop -Interactive'
)) -ge 1)

AssertEq 'B7 but forwarding the debug switch is not' 0 (SiteCount @(
    '$td = New-TestDesktop -Interactive:$Interactive'
))

# The analyzer as a whole, driven off an injected declaration list.
$decl = @([pscustomobject]@{ Script = 'declared.ps1'; Reason = 'because'; Line = 9; Malformed = $false })
$tmp = Join-Path $env:TEMP "ghoztty-t272-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null
Set-Content -LiteralPath (Join-Path $tmp 'declared.ps1') -Encoding ascii `
    -Value '$null = [Drv]::SendInput(1, $i, 40)'
Set-Content -LiteralPath (Join-Path $tmp 'undeclared.ps1') -Encoding ascii `
    -Value '$null = [Drv]::SetForegroundWindow($hwnd)'
Set-Content -LiteralPath (Join-Path $tmp 'migrated.ps1') -Encoding ascii `
    -Value '# SendInput is dead here; posted messages replace it.'
$files = @(Get-ChildItem -LiteralPath $tmp -Filter *.ps1 -File | ForEach-Object { $_.FullName })

$f = @(Get-ForegroundAuditFindings -Files $files -Declared $decl)
AssertEq 'B8 the undeclared grabber is the only finding' 1 $f.Count
AssertEq 'B9 and it is named as undeclared' 'undeclared' $f[0].Kind
Assert 'B10 naming the script' ($f[0].Path -match 'undeclared\.ps1')

$stale = @([pscustomobject]@{ Script = 'migrated.ps1'; Reason = 'was'; Line = 9; Malformed = $false }) + $decl
$f = @(Get-ForegroundAuditFindings -Files $files -Declared $stale)
Assert 'B11 a declaration for a script that no longer grabs is named stale' (@($f | Where-Object { $_.Kind -eq 'stale-declaration' }).Count -eq 1)

$f = @(Get-ForegroundAuditFindings -Files $files -Declared @(
    [pscustomobject]@{ Script = ''; Reason = 'junk'; Line = 3; Malformed = $true }))
Assert 'B12 a malformed declaration is a finding' (@($f | Where-Object { $_.Kind -eq 'malformed-declaration' }).Count -ge 1)

$f = @(Get-ForegroundAuditFindings -Files $files -Declared @())
Assert 'B13 an empty declaration list is a finding, not a free pass' (@($f | Where-Object { $_.Kind -eq 'malformed-declaration' }).Count -ge 1)

# The narrow marker, for a file that NAMES the APIs without calling them.
Assert 'B14 the stated-intent marker exempts a file that only names the APIs' (
    Test-ForegroundAuditExempt -Text @('# foreground-audit: the fixtures are strings', '[Drv]::SendInput(1)'))
Assert 'B15 and a file without it is not exempt' (
    -not (Test-ForegroundAuditExempt -Text @('# just a comment', '[Drv]::SendInput(1)')))

$marked = Join-Path $tmp 'marked.ps1'
Set-Content -LiteralPath $marked -Encoding ascii -Value @(
    '# foreground-audit: a fixture, not a call'
    '$fixture = ''$null = [Drv]::SendInput(1, $i, 40)'''
)
$f = @(Get-ForegroundAuditFindings -Files @($marked) -Declared $decl)
AssertEq 'B16 a marked file is not swept as an undeclared grabber' 0 @($f | Where-Object { $_.Kind -eq 'undeclared' }).Count

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# ===========================================================================
Write-Host ''
Write-Host '== C: the sweep over the acceptance suite'
# ===========================================================================

$planted = $null
if ($TeethCheck) {
    # A real file in the real swept directory, not a synthesized finding: the
    # claim under test is that the SWEEP notices, which a hand-made object would
    # not exercise.
    $planted = Join-Path $Suite 'zz-foreground-audit-teeth.ps1'
    Set-Content -LiteralPath $planted -Encoding ascii -Value @(
        '# planted by foreground-audit.ps1 -TeethCheck; deleted at the end of the run.'
        '$null = [Drv]::SendInput(1, $inputs, 40)'
    )
    Write-Host '  TEETH CHECK: a real undeclared grabber is in the swept directory'
}

try {
    $sweep = @(Get-ForegroundAuditSweep $Suite)
} finally {
    if ($planted) { Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue }
}

$hardKinds = Get-ForegroundAuditHardKinds
$hard = @($sweep | Where-Object { $hardKinds -contains $_.Kind })

if ($TeethCheck) {
    Assert 'C1 goes red when an undeclared foreground grab is added' (
        @($hard | Where-Object { $_.Path -match 'zz-foreground-audit-teeth' }).Count -eq 1)
} else {
    Assert 'C1 every foreground grab in the suite is declared, and every declaration is live' ($hard.Count -eq 0)
    foreach ($h in $hard) {
        Write-Host "       $(Split-Path $h.Path -Leaf):$($h.Line) $($h.Kind) - $($h.Detail)"
    }
}

# A sweep that read no files would report zero violations and look identical to
# a clean one - the exact shape T271 exists for.
$scanned = @(Get-ChildItem -LiteralPath $Suite -Filter *.ps1 -File).Count
Assert 'C2 the sweep read the whole suite' ($scanned -gt 100)

# And it must still be finding the declared exceptions, or the detector has
# gone blind and C1 is green for the wrong reason.
$declaredNames = @(Get-ForegroundAuditDeclarations -Path (Join-Path $Suite 'lib\TestDesktop.ps1') |
    Where-Object { -not $_.Malformed } | ForEach-Object { $_.Script })
$stillGrabbing = 0
foreach ($n in $declaredNames) {
    $p = Join-Path $Suite $n
    if ((Test-Path -LiteralPath $p) -and (@(Get-ForegroundAuditSites -Path $p).Count -gt 0)) { $stillGrabbing++ }
}
AssertEq 'C3 every declared exception is still a real grabber' $declaredNames.Count $stillGrabbing
Write-Host "  ($($declaredNames.Count) script(s) declared interactive-by-design: $($declaredNames -join ', '))"

Write-Host ''
Write-TestVerdict -Label 'T272 ACCEPTANCE' -Pass $script:pass -Fail $script:fail -MinPass 18
