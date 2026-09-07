<#
.SYNOPSIS
    T586 acceptance - an acceptance script that cannot START must not reach the
    tree unnoticed.

.DESCRIPTION
    `chrome-theme.ps1` shipped on 2026-08-07 calling `Test-ExeIsDebugBuild`, a
    function that exists nowhere in this repo, and died at line 299 before its
    first assertion. It stayed that way for a week: nothing runs these scripts
    but a person deciding to, and a script that cannot start looks exactly like
    a script nobody ran.

    Three sections:

      A. The analyzer (`lib\CommandResolveAudit.ps1`) against fixtures, both
         directions - the T586 shape is named, and every way this suite
         legitimately reaches a helper (a local function, a dot-sourced
         `Join-Path $PSScriptRoot` library, an expandable `"$Repo\..."` path, a
         function pulled out of another script by `Invoke-Expression`) resolves
         quietly. An analyzer that reports thirty innocent files is an analyzer
         nobody runs, so the quiet direction is checked as hard as the loud one.

      B. The sweep over `test\win32\*.ps1`. Every command name every acceptance
         script writes down must resolve. This is the assertion with the value;
         A is what makes it trustworthy.

      C. `-TeethCheck` - the negative control. It plants the exact 2026-08-07
         defect (a call to a helper that does not exist) into a real file in
         the suite directory and requires section B's sweep to go RED naming
         it, then removes it. A check never observed failing is not a check.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI and no app - this reads scripts, it does not
    # run them. No IPC endpoint, no user state.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\CommandResolveAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "ghoztty-t586-$PID"
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'lib') | Out-Null
$enc = New-Object Text.UTF8Encoding $false
function Write-Fixture([string]$Rel, [string]$Body) {
    $p = Join-Path $tmp $Rel
    [IO.File]::WriteAllText($p, $Body, $enc)
    $p
}
# The fixtures are read as if $tmp were the repository, so a `$Repo`-rooted
# dot-source in a fixture resolves inside the fixture tree.
function Fixture-Findings([string[]]$Paths) {
    Reset-ResolveAuditCache
    @(Get-CommandResolveFindings -Repo $tmp -Paths $Paths)
}

# ============================================================================
Write-Host '== A: the analyzer, against fixtures'
# ============================================================================

# A1/A2 are the two directions of the defect itself.
$a1 = Write-Fixture 'a1.ps1' @'
function Test-Thing { param($x) $x }
Test-Thing 1
Get-ChildItem -Path .
'@
Assert 'A1 a script that defines what it calls yields nothing' (
    (Fixture-Findings @($a1)).Count -eq 0) (
    ((Fixture-Findings @($a1)) | ForEach-Object { $_.Name }) -join ',')

$a2 = Write-Fixture 'a2.ps1' @'
$exe = 'x'
Test-ExeIsDebugBuild -Exe $exe
'@
$fa2 = Fixture-Findings @($a2)
Assert 'A2 the T586 shape - a helper that exists nowhere - is named' (
    (@($fa2).Count -eq 1) -and ($fa2[0].Name -eq 'Test-ExeIsDebugBuild')) (
    (@($fa2) | ForEach-Object { "$($_.Name)@$($_.Line)" }) -join ',')
Assert 'A3 and it is named at the line that calls it' (
    (@($fa2).Count -eq 1) -and ($fa2[0].Line -eq 2)) (
    "line $(if (@($fa2).Count) { $fa2[0].Line } else { 'none' })")

# A4-A6: the three ways a script in this suite legitimately reaches a helper.
Write-Fixture 'lib\Helpers.ps1' @'
function Get-FixtureHelper { 42 }
'@ | Out-Null
$a4 = Write-Fixture 'a4.ps1' @'
. (Join-Path $PSScriptRoot 'lib\Helpers.ps1')
Get-FixtureHelper
'@
Assert 'A4 a Join-Path $PSScriptRoot dot-source resolves its functions' (
    (Fixture-Findings @($a4)).Count -eq 0) (
    ((Fixture-Findings @($a4)) | ForEach-Object { $_.Name }) -join ',')

$a5 = Write-Fixture 'a5.ps1' @'
$Repo = 'ignored - the analyzer binds this to the repository root'
. "$Repo\lib\Helpers.ps1"
Get-FixtureHelper
'@
Assert 'A5 an expandable "$Repo\..." dot-source resolves its functions' (
    (Fixture-Findings @($a5)).Count -eq 0) (
    ((Fixture-Findings @($a5)) | ForEach-Object { $_.Name }) -join ',')

# The widening: `go-loop-uptime.ps1` pulls `Format-Uptime` out of
# `go-loop-lock.ps1` by regex and Invoke-Expressions it. No static resolver can
# follow that, so a file doing it has every .ps1 path it mentions treated as
# dot-sourced.
$a6 = Write-Fixture 'a6.ps1' @'
$src = Get-Content -Raw (Join-Path $PSScriptRoot 'lib\Helpers.ps1')
$m = [regex]::Match($src, '(?s)function Get-FixtureHelper.*?\n\}')
Invoke-Expression $m.Value
Get-FixtureHelper
'@
Assert 'A6 a function pulled out of another script by regex resolves' (
    (Fixture-Findings @($a6)).Count -eq 0) (
    ((Fixture-Findings @($a6)) | ForEach-Object { $_.Name }) -join ',')

# A7: names that are not static command names at all. (The fixture deliberately
# writes `--some-flag` rather than a `+verb`: this script drives no CLI, and a
# `+verb` anywhere in its text is what `isolation-meta.ps1` reads as one that
# does and has not claimed a private endpoint.)
$a7 = Write-Fixture 'a7.ps1' @'
$exe = 'C:\x\ghoztty.exe'
& $exe --some-flag
& "$PSScriptRoot\stub.ps1"
.\relative.ps1
Get-Command Test-NotACall -ErrorAction SilentlyContinue
'@
Assert 'A7 an invoked variable, a path, and a NAME PASSED AS DATA are not calls' (
    (Fixture-Findings @($a7)).Count -eq 0) (
    ((Fixture-Findings @($a7)) | ForEach-Object { $_.Name }) -join ',')

# A8: the second live shape - a pasted-twice if/elseif chain, where the second
# `elseif` parses as a COMMAND. Zero parse errors, and a run that throws.
$a8 = Write-Fixture 'a8.ps1' @'
if ($a) {
    'one'
} elseif ($b) {
    'two'
} else {
    'three'
} elseif ($b) {
    'four'
} else {
    'five'
}
'@
$fa8 = Fixture-Findings @($a8)
Assert 'A8 a stray elseif - the pasted-chain shape - is named' (
    @(@($fa8) | Where-Object { $_.Name -eq 'elseif' }).Count -eq 1) (
    (@($fa8) | ForEach-Object { $_.Name }) -join ',')

# A9: an external program the suite is allowed to name resolves from the fixed
# list, not from this box's PATH - otherwise the verdict changes machine to
# machine for reasons that have nothing to do with the code.
$a9 = Write-Fixture 'a9.ps1' @'
git status
zig build
gh release list
'@
Assert 'A9 a known external program resolves' (
    (Fixture-Findings @($a9)).Count -eq 0) (
    ((Fixture-Findings @($a9)) | ForEach-Object { $_.Name }) -join ',')
Assert 'A10 the externals list is fixed rather than read off PATH' (
    (Get-CommandResolveExternals).Count -ge 20 -and
    ((Get-CommandResolveExternals) -contains 'git'))

# A11: the stated-intent exemption.
$a11 = Write-Fixture 'a11.ps1' @'
# resolve-audit: a fixture proving the marker suppresses the file
Test-ExeIsDebugBuild
'@
Assert 'A11 a # resolve-audit: marker drops the file from the sweep' (
    (Fixture-Findings @($a11)).Count -eq 0) (
    ((Fixture-Findings @($a11)) | ForEach-Object { $_.Name }) -join ',')

# A12: an empty analyzer input must not read as a clean file. The first cut of
# this library parsed '' for every script and reported zero of everything,
# which is indistinguishable from a suite with nothing wrong.
$a12ast = Get-ResolveAuditAst -Path $a2
Assert 'A12 the analyzer parses the FILE when no text is passed' (
    $a12ast.Extent.Text.Length -gt 0) "len $($a12ast.Extent.Text.Length)"

# ============================================================================
Write-Host ''
Write-Host '== B: the sweep over test\win32\*.ps1'
# ============================================================================

Reset-ResolveAuditCache
$roots = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File |
    ForEach-Object { $_.FullName })
$sweep = @(Get-CommandResolveFindings -Repo $Repo -Paths $roots)

Assert 'B1 the sweep actually looked at the suite' ($roots.Count -ge 200) `
    "$($roots.Count) scripts"
Assert 'B2 every command name in every acceptance script resolves' (
    $sweep.Count -eq 0)
foreach ($f in $sweep) {
    Write-Host "      $($f.File):$($f.Line) -> $($f.Name)" -ForegroundColor Red
}

# A library no root dot-sources is never read by section B. That is a
# consequence of auditing libraries through their consumers (the header says
# why), and it is reported rather than assumed empty.
$orphans = @(Get-UnreachableAuditLibraries -Repo $Repo -Roots $roots)
Assert 'B3 no lib\*.ps1 sits outside every root''s reach' ($orphans.Count -eq 0) `
    ($orphans -join ', ')

# ============================================================================
if ($TeethCheck) {
    Write-Host ''
    Write-Host '== C: teeth - the sweep must go red on a planted violator'
    # ========================================================================
    $planted = Join-Path $PSScriptRoot 'zz-t586-teeth-fixture.ps1'
    try {
        [IO.File]::WriteAllText($planted, @'
# A synthesized violator (T586 teeth check). If this file is still here, a
# teeth run did not clean up after itself - delete it.
$exe = 'x'
Test-ExeIsDebugBuild -Exe $exe
'@, $enc)
        Reset-ResolveAuditCache
        $teethRoots = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File |
            ForEach-Object { $_.FullName })
        $teeth = @(Get-CommandResolveFindings -Repo $Repo -Paths $teethRoots)
        $named = @($teeth | Where-Object {
            $_.File -like '*zz-t586-teeth-fixture.ps1' -and
            $_.Name -eq 'Test-ExeIsDebugBuild' })
        Assert 'C1 the sweep names the planted unresolvable call' (@($named).Count -eq 1) `
            ("found: " + (@($teeth) | ForEach-Object { "$($_.File):$($_.Name)" }) -join ', ')
        Assert 'C2 and it fails the run rather than merely mentioning it' (
            @($teeth).Count -gt 0)
    } finally {
        Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue
    }
    Assert 'C3 the planted violator is removed again' (
        -not (Test-Path -LiteralPath $planted))
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run deliberately plants a violator.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard command-resolve -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'COMMAND RESOLVE AUDIT' -MinPass 14
