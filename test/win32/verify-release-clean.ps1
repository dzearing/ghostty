# A second opinion on the release, and the proof it can say no (T1312).
#
# Every malware verdict this project has ever had came from Windows Defender,
# on one machine, through a per-machine cloud call. T1293 turns on whether that
# detection was a false positive, and the two possible answers -- one engine
# guessing versus several engines agreeing -- lead to opposite actions: a note
# on the website, or pulling the release. scripts\verify-release-clean.ps1 is
# how the question gets asked of somebody other than Defender: hash every
# published asset, ask VirusTotal by hash, name the engines.
#
# The reason this harness exists rather than a one-off run: a checker that has
# only ever been observed saying "clean" is indistinguishable from a checker
# that cannot say anything else (go.md, T1133). So every verdict here is
# constructed from a canned response and the exit code is asserted.
#
# What this asserts:
#
#   A  hashing: -HashesOnly over a directory of files prints a real SHA-256 per
#      file and expands a zip so the binaries a user actually runs are named,
#      not just the archive they arrived in.
#   B  CLEAN: canned reports with every engine harmless -> exit 0.
#   C  DETECTED: a fabricated multi-engine response -> exit 3, and the engines
#      are named in the output. This is the demonstration that the gate can
#      fail; without it the check is decorative.
#   D  UNKNOWN: an asset no scanner has ever seen -> exit 2, NOT a clean pass.
#      This is the silent-pass hole the task named.
#   E  NOASK: no API key -> exit 4, distinct from every verdict above, and the
#      word CLEAN never appears.
#   F  threshold: one detection under -MaxDetections 1 -> exit 0, so a single
#      known false positive can be tolerated deliberately rather than by the
#      checker being blind.
#   G  parses under PS 5.1, and the release readback really calls it.
#
# Read-only, offline, no network. Runs in about a second.
#
#   powershell -NoProfile -File test\win32\verify-release-clean.ps1
#   powershell -NoProfile -File test\win32\verify-release-clean.ps1 -NegativeControl
param(
    [string]$Repo = 'D:\git\ghoztty',
    # Proof this harness can score red: breaks the expectations on purpose.
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:skipped = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($NegativeControl) { $cond = -not $cond }
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    $ok = ($expected -eq $actual)
    if ($NegativeControl) { $ok = -not $ok }
    if ($ok) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

$checker = Join-Path $Repo 'scripts\verify-release-clean.ps1'
$tmp = Join-Path $env:TEMP ("vt-clean-test-" + [guid]::NewGuid().ToString('N'))
$assets = Join-Path $tmp 'assets'
$responses = Join-Path $tmp 'responses'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
New-Item -ItemType Directory -Path $responses -Force | Out-Null

# ---------------------------------------------------------------------------
# A synthetic "release": one file standing in for the MSI, and a zip holding
# the three binaries the real portable archive carries.
# ---------------------------------------------------------------------------
Set-Content -LiteralPath (Join-Path $assets 'Ghoztty-9.9.9-x64.msi') `
    -Value 'not really an msi' -Encoding ASCII

$stage = Join-Path $tmp 'stage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($n in @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')) {
    Set-Content -LiteralPath (Join-Path $stage $n) -Value "stand-in for $n" -Encoding ASCII
}
# The real portable archive also carries ~300 shell-completion, syntax and JSON
# files. No engine has an opinion about those, and asking about them anyway
# spends a free key's whole daily quota on text -- so they must not be asked
# about, and A5 is what says so.
New-Item -ItemType Directory -Path (Join-Path $stage 'share') -Force | Out-Null
foreach ($n in @('ghostty.bash', 'ghostty.fish', '1.13.0.json', 'READ-ME-FIRST.txt')) {
    Set-Content -LiteralPath (Join-Path $stage "share\$n") -Value 'noise' -Encoding ASCII
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, (Join-Path $assets 'Ghoztty-portable-9.9.9-x64.zip'))

function Invoke-Checker {
    param([string[]]$ExtraArgs, [hashtable]$Env)

    $saved = @{}
    if ($Env) {
        foreach ($k in $Env.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $Env[$k])
        }
    }
    try {
        $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker,
            '-AssetDir', $assets) + $ExtraArgs
        $out = & powershell @argsList 2>&1
        return @{ Exit = $LASTEXITCODE; Text = ($out | Out-String) }
    } finally {
        if ($Env) {
            foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }
}

# The three hashes the checker will ask about, computed the same way it does.
function Get-AssetHashes {
    $r = Invoke-Checker -ExtraArgs @('-HashesOnly')
    $map = @{}
    foreach ($line in ($r.Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s{2}(?<sha>[0-9a-f]{64})\s\s(?<name>.+?)\s*$')
        if ($m.Success) { $map[$m.Groups['name'].Value] = $m.Groups['sha'].Value }
    }
    return $map
}

# A VirusTotal /api/v3/files body, as much of one as the checker reads.
function Write-Response {
    param([string]$Sha, [int]$Malicious, [int]$Engines = 70, [string[]]$Names)

    $results = [ordered]@{}
    $i = 0
    while ($i -lt $Engines) {
        $engine = "Engine$i"
        if ($Names -and $i -lt $Names.Count) { $engine = $Names[$i] }
        if ($i -lt $Malicious) {
            $results[$engine] = [ordered]@{ category = 'malicious'; result = 'Trojan:Win32/Wacatac.B!ml' }
        } else {
            $results[$engine] = [ordered]@{ category = 'harmless'; result = $null }
        }
        $i++
    }
    $body = [ordered]@{
        data = [ordered]@{
            attributes = [ordered]@{
                last_analysis_stats   = [ordered]@{ malicious = $Malicious; harmless = ($Engines - $Malicious) }
                last_analysis_results = $results
            }
        }
    }
    ConvertTo-Json -InputObject $body -Depth 8 |
        Set-Content -LiteralPath (Join-Path $responses "$Sha.json") -Encoding ASCII
}

function Clear-Responses {
    Get-ChildItem -LiteralPath $responses -File | Remove-Item -Force
}

# ============================================================================
"== A: hashing and what gets asked about"
# ============================================================================

$hashes = Get-AssetHashes
AssertEq 'A1 four things hashed (msi, zip, and the 3 binaries inside it)' 5 $hashes.Count
Assert 'A2 the msi is hashed' ($hashes.Keys -contains 'Ghoztty-9.9.9-x64.msi')
Assert 'A3 the binaries inside the zip are named individually' (
    ($hashes.Keys | Where-Object { $_ -like '*!ghoztty.exe' }).Count -eq 1 -and
    ($hashes.Keys | Where-Object { $_ -like '*!ghoztty.com' }).Count -eq 1 -and
    ($hashes.Keys | Where-Object { $_ -like '*!ghoztty-agent.exe' }).Count -eq 1
)
$msiHash = (Get-FileHash -LiteralPath (Join-Path $assets 'Ghoztty-9.9.9-x64.msi') -Algorithm SHA256).Hash.ToLower()
AssertEq 'A4 the hash is the real SHA-256 of the file' $msiHash $hashes['Ghoztty-9.9.9-x64.msi']
Assert 'A5 the archive noise is not asked about' (
    ($hashes.Keys | Where-Object { $_ -match '\.(bash|fish|json|txt)$' }).Count -eq 0
)

# ============================================================================
"== B: every engine harmless -> CLEAN"
# ============================================================================

Clear-Responses
foreach ($sha in $hashes.Values) { Write-Response -Sha $sha -Malicious 0 }
$r = Invoke-Checker -ExtraArgs @('-ResponseDir', $responses)
AssertEq 'B1 exit 0' 0 $r.Exit
Assert 'B2 says CLEAN' ($r.Text -match 'CLEAN every asset has a report')
Assert 'B3 reports the engine count it based that on' ($r.Text -match '0/70 engines')

# ============================================================================
"== C: several engines agree -> DETECTED (the gate can fail)"
# ============================================================================

Clear-Responses
foreach ($sha in $hashes.Values) { Write-Response -Sha $sha -Malicious 0 }
Write-Response -Sha $hashes['Ghoztty-portable-9.9.9-x64.zip!ghoztty.exe'] -Malicious 3 `
    -Names @('Microsoft', 'Kaspersky', 'ESET-NOD32')
$r = Invoke-Checker -ExtraArgs @('-ResponseDir', $responses)
AssertEq 'C1 exit 3' 3 $r.Exit
Assert 'C2 says DETECTED' ($r.Text -match 'DETECTED 1 asset')
Assert 'C3 names the engines that flagged it' (
    $r.Text -match 'Microsoft:' -and $r.Text -match 'Kaspersky:' -and $r.Text -match 'ESET-NOD32:'
)
Assert 'C4 does not also claim CLEAN' (-not ($r.Text -match 'CLEAN every asset'))
# 3/70, not 1/70: the count is how many engines AGREED, and a PS 5.1 array
# unroll once collapsed all three into a single detection called
# "System.Object[]" while still exiting 3, which would have read as a pass.
Assert 'C5 counts every engine that agreed, not one' ($r.Text -match '3/70 engines')

# ============================================================================
"== D: nobody has ever scanned it -> UNKNOWN, not a silent pass"
# ============================================================================

Clear-Responses
foreach ($sha in $hashes.Values) { Write-Response -Sha $sha -Malicious 0 }
Remove-Item -LiteralPath (Join-Path $responses ("{0}.json" -f $hashes['Ghoztty-9.9.9-x64.msi'])) -Force
$r = Invoke-Checker -ExtraArgs @('-ResponseDir', $responses)
AssertEq 'D1 exit 2' 2 $r.Exit
Assert 'D2 says UNKNOWN and names the asset' ($r.Text -match 'UNKNOWN no scanner has ever seen.*Ghoztty-9\.9\.9-x64\.msi')
Assert 'D3 spells out that this is not clean' ($r.Text -match 'nobody has looked')
Assert 'D4 does not claim CLEAN' (-not ($r.Text -match 'CLEAN every asset'))

# An explicit 404 body reads the same way as a missing one.
Clear-Responses
foreach ($sha in $hashes.Values) { Write-Response -Sha $sha -Malicious 0 }
'{ "__status": 404 }' | Set-Content -LiteralPath (Join-Path $responses ("{0}.json" -f $hashes['Ghoztty-9.9.9-x64.msi'])) -Encoding ASCII
$r = Invoke-Checker -ExtraArgs @('-ResponseDir', $responses)
AssertEq 'D5 an explicit 404 is UNKNOWN too' 2 $r.Exit

# ============================================================================
"== E: no key -> NOASK, which is not a verdict"
# ============================================================================

# No -ResponseDir, and the key sources emptied: env cleared, and the on-box key
# file path redirected at a directory that holds nothing.
$r = Invoke-Checker -ExtraArgs @('-KeyFile', (Join-Path $tmp 'no-such.key')) `
    -Env @{ GHOZTTY_VT_API_KEY = ''; LOCALAPPDATA = $tmp }
AssertEq 'E1 exit 4' 4 $r.Exit
Assert 'E2 says NOASK' ($r.Text -match 'NOASK no VirusTotal API key')
Assert 'E3 does not claim CLEAN' (-not ($r.Text -match 'CLEAN every asset'))
Assert 'E4 prints the hashes so the question can be asked by hand' ($r.Text -match '[0-9a-f]{64}\s\s.*ghoztty\.exe')
Assert 'E5 names where to put a key' ($r.Text -match 'GHOZTTY_VT_API_KEY')

# ============================================================================
"== F: a tolerated single detection"
# ============================================================================

Clear-Responses
foreach ($sha in $hashes.Values) { Write-Response -Sha $sha -Malicious 0 }
Write-Response -Sha $hashes['Ghoztty-portable-9.9.9-x64.zip!ghoztty.exe'] -Malicious 1 -Names @('Microsoft')
$r = Invoke-Checker -ExtraArgs @('-ResponseDir', $responses, '-MaxDetections', '1')
AssertEq 'F1 one detection under a threshold of 1 -> exit 0' 0 $r.Exit
$r = Invoke-Checker -ExtraArgs @('-ResponseDir', $responses)
AssertEq 'F2 the same response with the default threshold -> exit 3' 3 $r.Exit

# ============================================================================
"== G: parse and wiring"
# ============================================================================

$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($checker, [ref]$null, [ref]$parseErrors) | Out-Null
AssertEq 'G1 checker parses cleanly under PS 5.1' 0 (@($parseErrors).Count)

# The readback: daily-publish reconciles a tagged release against the API, and
# that is where the scanner question belongs -- asked on every release rather
# than the one time somebody remembered.
$publish = Get-Content -LiteralPath (Join-Path $Repo 'scripts\daily-publish.ps1') -Raw
Assert 'G2 the release readback calls the checker' ($publish -match 'verify-release-clean\.ps1')

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# A clean green run stamps the covered files (T783).
Complete-TestBody
if (-not $NegativeControl -and $script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard verify-release-clean -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
