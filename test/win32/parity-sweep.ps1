<#
.SYNOPSIS
  Acceptance test for scripts\parity-sweep.ps1 (T152).

.DESCRIPTION
  The sweep is a GATE: it decides whether a range of Mac-side history has been
  written down as Windows work. A gate that answers "clean" when it should not
  is worse than no gate at all, so every arm here has a deterministic oracle -
  a fixed six-commit range of real history, and a fixture docs tree this test
  writes itself, so the expected mapped/unmapped split is known exactly rather
  than compared against whatever the live tracker happens to say today.

  Two of the arms exist to check the sweep's teeth rather than its function:
  a nine-character token that shares a commit's first seven characters must
  NOT map it (that is the difference between a sha reference and a hex-shaped
  coincidence), and a "#rrggbbaa" color must not either.

  Arms 8-10 are T685: the watch list now covers the shared src/ core, and the
  two things that keeps honest. 8 proves a commit touching only src/termio/ is
  caught where the old macos/+src/viewer/ default saw nothing. 9 proves a range
  spanning THIS branch reports none of our own commits (the topological guard).
  10 proves a src/apprt/win32/ commit is dropped by the path exclusion even
  when the topological guard cannot see it, so the two mechanisms are tested
  apart rather than covering for each other.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Sweep = Join-Path $RepoRoot 'scripts\parity-sweep.ps1'

# A fixed slice of real history: exactly these six commits touch macos/ or
# src/viewer/ between these two revisions. Frozen on 2026-08-09; if history is
# ever rewritten under it the first arm fails loudly rather than silently
# testing nothing.
$Range = '261de0390b50d8dc23fb2a64d18294f2acea4f25..4a41394b232bab712749b1ccbc8b102cc87800de'
$Expected = @(
    'c182302e3cda342123bcf6998f15bdcaa79494bd'
    'a7f7476e11bc9e5789a12eacde467103931b004a'
    '5bd426ba24cafe176aae03e0cb05223875b4849a'
    '11fe14bc311656974703a2efafb85fb9aeef24fb'
    '2389d318249a47333d7bfad9d05ded7247a44011'
    'dfa54ff3cb428534a235dbfdd68cf438ef5486da'
)

# The watch list as it stood before T685, kept here so an arm can show what the
# widened default now catches that this one did not.
$LegacyPaths = @('macos/', 'src/viewer/')

# T685 oracles, all frozen shas.
#   SharedRange - one commit, eb1876f09, whose only files are src/termio/*.
#   MixedRange  - an old main sha to this branch's tip, which is 481 commits of
#                 BOTH kinds: 294 Mac changes we merged in, and 187 of our own.
#                 A range with only one kind could not tell a guard that
#                 separates the sides from one that zeroes the report.
#   Win32Range  - one commit whose only src/ files are under src/apprt/win32/.
$SharedRange = 'ba76e3f93f04a79ffa56e7523a65b7d37600b543..eb1876f09ce054be8f5095e5e2b49d3e8c6cd64a'
$SharedSha = 'eb1876f09ce054be8f5095e5e2b49d3e8c6cd64a'
$MixedRange = '680a07ed398f064d106b6ea476f43ce0d143d21a..95b3f35b4269e3f83c3de408c55447b5407aabf7'
$MixedIncoming = 'b388bb62c25c8a4564c88aec8e211b2d4fdc6bf0'
$MixedIncomingCount = 294
$MixedLocalCount = 187
$BranchOwnSha = '029ae4b1238c0e7ac8ee729d283b6fe7ec7ec926'
$Win32Range = '839a1b812941901088169c92d512bcd55b2bd7cb..c72220cd7420f720cd2cde1ff9de5d33922ce556'
$Win32Incoming = 'c72220cd7420f720cd2cde1ff9de5d33922ce556'

$script:Failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host ("PASS  {0}" -f $Name)
    }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

# Run the sweep against a fixture docs tree. Returns the captured stdout lines
# plus the exit code; the sweep's exit code IS its verdict, so both matter.
#
# Invoked through -Command rather than -File: PS 5.1's -File parser binds only
# the FIRST value of a multi-value argument and drops the rest silently, so
# "-File ... -Paths macos/ src/viewer/" would sweep macos/ alone and the arm
# that depends on the narrower list would pass for the wrong reason.
function Invoke-Sweep {
    param(
        [string]$DocsPath,
        [string]$Format = 'text',
        [switch]$ShowMapped,
        [string]$UseRange,
        [string[]]$Paths,
        [string]$IncomingRef
    )

    $r = if ($UseRange) { $UseRange } else { $Range }
    $cmd = "& '$Sweep' -Range '$r' -DocsPath '$DocsPath' -Format '$Format' -RepoRoot '$RepoRoot'"
    if ($Paths) {
        $cmd += ' -Paths @(' + (($Paths | ForEach-Object { "'" + $_ + "'" }) -join ',') + ')'
    }
    if ($IncomingRef) { $cmd += " -IncomingRef '$IncomingRef'" }
    if ($ShowMapped) { $cmd += ' -ShowMapped' }

    # Capture through a pipe: powershell.exe is a console binary here, so
    # stdout redirects normally, but $LASTEXITCODE is only trustworthy when the
    # whole stream has been drained (never -First; see go.md).
    $out = & powershell.exe -NoProfile -Command $cmd 2>&1
    return [pscustomobject]@{ Lines = @($out); Exit = $LASTEXITCODE; Text = (@($out) -join "`n") }
}

# Write a fixture docs tree whose only sha references are the ones given.
function New-FixtureDocs {
    param([string[]]$Shas, [string]$Extra = '')

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("parity-sweep-fixture-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $tasks = Join-Path $root 'windows-parity-tasks'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null

    $body = @('# T900 - fixture', '')
    foreach ($s in $Shas) {
        # Reference each as a 9-character abbreviation, the way the tracker
        # actually writes them.
        $body += ("- ``{0}`` covered by this fixture" -f $s.Substring(0, 9))
    }
    if ($Extra) { $body += ''; $body += $Extra }

    Set-Content -LiteralPath (Join-Path $tasks 'T900.md') -Value ($body -join "`n") -Encoding ASCII
    return $root
}

$created = New-Object System.Collections.ArrayList

try {
    # --- 1. The range itself is what the test thinks it is -------------------
    $none = New-FixtureDocs -Shas @()
    [void]$created.Add($none)
    $r = Invoke-Sweep -DocsPath $none

    Check '1a range yields exactly the six frozen commits' `
        ($r.Text -match 'commits: 6\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '1b nothing referenced => all six unmapped' `
        ($r.Text -match 'unmapped: 6')
    Check '1c an unmapped sweep exits 1 (this is the gate)' `
        ($r.Exit -eq 1) ("exit=" + $r.Exit)
    $allListed = $true
    foreach ($s in $Expected) {
        if ($r.Text -notmatch [regex]::Escape($s.Substring(0, 9))) { $allListed = $false }
    }
    Check '1d every unmapped commit is named in the report' $allListed

    # --- 2. Partial coverage: exactly the remainder is reported --------------
    $mappedThree = $Expected[0..2]
    $partial = New-FixtureDocs -Shas $mappedThree
    [void]$created.Add($partial)
    $r = Invoke-Sweep -DocsPath $partial

    Check '2a three referenced => three mapped' ($r.Text -match 'mapped: 3\s')
    Check '2b three referenced => three unmapped' ($r.Text -match 'unmapped: 3')
    Check '2c still exits 1 while anything is unmapped' ($r.Exit -eq 1) ("exit=" + $r.Exit)

    $unmappedSection = ($r.Text -split 'UNMAPPED \(')[-1]
    $rightOnes = $true
    foreach ($s in $Expected[3..5]) {
        if ($unmappedSection -notmatch [regex]::Escape($s.Substring(0, 9))) { $rightOnes = $false }
    }
    foreach ($s in $mappedThree) {
        if ($unmappedSection -match [regex]::Escape($s.Substring(0, 9))) { $rightOnes = $false }
    }
    Check '2d the unmapped list is exactly the un-referenced three' $rightOnes

    # --- 3. Full coverage is clean and exits 0 -------------------------------
    $full = New-FixtureDocs -Shas $Expected
    [void]$created.Add($full)
    $r = Invoke-Sweep -DocsPath $full

    Check '3a everything referenced => 0 unmapped' ($r.Text -match 'unmapped: 0')
    Check '3b a clean sweep exits 0' ($r.Exit -eq 0) ("exit=" + $r.Exit)
    Check '3c and says so on its last line' ($r.Text -match 'SWEEP CLEAN')

    # --- 4. Teeth: a near-miss token must not map a commit -------------------
    # Same first seven characters, different eighth and ninth. If the sweep
    # keyed on the seven-character bucket alone this would map all six, and the
    # gate would go quiet on exactly the commits it exists to catch.
    $nearMiss = @()
    foreach ($s in $Expected) {
        $seven = $s.Substring(0, 7)
        $eighthNinth = $s.Substring(7, 2)
        $wrong = if ($eighthNinth -eq 'aa') { 'bb' } else { 'aa' }
        $nearMiss += ("- near-miss ``{0}{1}``" -f $seven, $wrong)
    }
    $teeth = New-FixtureDocs -Shas @() -Extra ($nearMiss -join "`n")
    [void]$created.Add($teeth)
    $r = Invoke-Sweep -DocsPath $teeth

    Check '4a a 9-char token sharing only the first 7 does NOT map' `
        ($r.Text -match 'unmapped: 6') ("got: " + (($r.Lines | Where-Object { $_ -match 'unmapped:' }) -join '; '))
    Check '4b and the sweep still fails' ($r.Exit -eq 1)

    # --- 5. Teeth: a hex color must not map a commit -------------------------
    $colors = ($Expected | ForEach-Object { '- color #' + $_.Substring(0, 8) }) -join "`n"
    $colorFixture = New-FixtureDocs -Shas @() -Extra $colors
    [void]$created.Add($colorFixture)
    $r = Invoke-Sweep -DocsPath $colorFixture

    Check '5a "#rrggbbaa" is a color, not a sha reference' ($r.Text -match 'unmapped: 6')

    # --- 6. The markdown block is the pasteable evidence ---------------------
    $r = Invoke-Sweep -DocsPath $partial -Format markdown -ShowMapped

    Check '6a markdown emits the Parity coverage heading' ($r.Text -match '(?m)^## Parity coverage')
    Check '6b it states the range' ($r.Text -match [regex]::Escape('261de0390'))
    Check '6c it carries a Commit/Subject/Filed as table' ($r.Text -match '\|\s*Commit\s*\|\s*Subject\s*\|\s*Filed as\s*\|')
    Check '6d it calls out the unmapped count in bold' ($r.Text -match '\*\*Unmapped: 3\*\*')
    Check '6e -ShowMapped names the file that mapped each commit' ($r.Text -match 'T900')

    # --- 7. JSON is machine-readable and agrees with the text ---------------
    $r = Invoke-Sweep -DocsPath $partial -Format json
    $ok = $false
    $detail = ''
    try {
        $obj = $r.Text | ConvertFrom-Json
        $ok = ($obj.total -eq 6 -and @($obj.mapped).Count -eq 3 -and @($obj.unmapped).Count -eq 3)
        $detail = ("total={0} mapped={1} unmapped={2}" -f $obj.total, @($obj.mapped).Count, @($obj.unmapped).Count)
    }
    catch {
        $detail = "parse failed: $_"
    }
    Check '7a json parses and its counts match the text report' $ok $detail

    # --- 8. T685: the shared core is watched --------------------------------
    # eb1876f09 touches src/termio/ and nothing else. It is exactly the shape
    # that produced T604 (main rewriting shared code underneath this branch),
    # and the pre-T685 default could not see it at all.
    $sharedFixture = New-FixtureDocs -Shas @()
    [void]$created.Add($sharedFixture)

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $SharedRange -Paths $LegacyPaths
    Check '8a the old macos/+src/viewer/ list saw nothing here' `
        ($r.Text -match 'commits: 0\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '8b and therefore reported clean' ($r.Exit -eq 0) ("exit=" + $r.Exit)

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $SharedRange
    Check '8c the default now enumerates the src/termio/ commit' `
        ($r.Text -match 'commits: 1\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '8d unreferenced, it is unmapped and the gate fails' `
        (($r.Text -match 'unmapped: 1') -and $r.Exit -eq 1) ("exit=" + $r.Exit)
    Check '8e the report names it' ($r.Text -match [regex]::Escape($SharedSha.Substring(0, 9)))
    Check '8f the default path list carries both frontend exclusions' `
        (($r.Text -match [regex]::Escape(':(exclude)src/apprt/win32/')) -and `
         ($r.Text -match [regex]::Escape(':(exclude)src/apprt/gtk/')))

    # --- 9. T685: this branch's own commits are never reported ---------------
    # A range holding both sides at once. Without the incoming-side guard,
    # widening the paths would report all 481 - our 187 included - and the gate
    # would be noise within a day. The two counts below must SPLIT the range,
    # which is the claim a single-sided range cannot check.
    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $MixedRange -IncomingRef $MixedIncoming
    Check '9a only the incoming side is enumerated' `
        ($r.Text -match ("commits: {0}\s" -f $MixedIncomingCount)) `
        ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '9b and the branch-local remainder is reported, not silently dropped' `
        ($r.Text -match ("branch-local excluded: {0}\b" -f $MixedLocalCount)) `
        ("got: " + (($r.Lines | Where-Object { $_ -match 'branch-local' }) -join '; '))
    Check '9c one of our own shared-src commits is not in the report' `
        ($r.Text -notmatch [regex]::Escape($BranchOwnSha.Substring(0, 9)))
    Check '9d a Mac-side shared-src commit in the same range IS in it' `
        ($r.Text -match [regex]::Escape($SharedSha.Substring(0, 9)))

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $MixedRange -IncomingRef $MixedIncoming -Format json
    $ok = $false; $detail = ''
    try {
        $obj = $r.Text | ConvertFrom-Json
        $ok = ($obj.excluded_local -eq $MixedLocalCount -and $obj.total -eq $MixedIncomingCount -and `
               $obj.incoming_ref -eq $MixedIncoming)
        $detail = ("excluded_local={0} total={1} incoming_ref={2}" -f $obj.excluded_local, $obj.total, $obj.incoming_ref)
    }
    catch { $detail = "parse failed: $_" }
    Check '9e json carries the exclusion count and the incoming ref' $ok $detail

    # --- 10. T685: src/apprt/win32/ is dropped by PATH, not by topology ------
    # Same commit, but pointed at an incoming ref that reaches it - so the
    # topological guard cannot help and the path exclusion has to. The second
    # half removes the exclusion to prove the arm has teeth.
    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $Win32Range -IncomingRef $Win32Incoming
    Check '10a a win32-only commit is not a Mac change' `
        (($r.Text -match 'commits: 0\s') -and ($r.Text -match 'branch-local excluded: 0')) `
        ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:|branch-local' }) -join '; '))

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $Win32Range -IncomingRef $Win32Incoming -Paths @('src/')
    Check '10b without the exclusion the same commit IS enumerated' `
        ($r.Text -match 'commits: 1\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
}
finally {
    foreach ($d in $created) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'ALL PASS'
    exit 0
}
Write-Host ("{0} FAILURE(S)" -f $script:Failures)
exit 1
