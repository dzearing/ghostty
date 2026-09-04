# The submission packet, and the proof it is generated rather than remembered
# (T1313).
#
# Defender quarantines our releases as Trojan:Script/Wacatac.C!ml (T1293). The
# remedy is a developer false-positive report to Microsoft, and a determination
# corrects the BYTES it names -- nothing else. T1313 carried that data as a
# hand-typed table naming win-v1.36.2's two hashes; four more releases shipped
# before anyone read it, three of them on one day. A packet that is typed once
# is wrong by the time it is used, so scripts\report-false-positive.ps1 builds
# it from whichever release is current.
#
# The act of filing needs a Microsoft account and stays the user's. What this
# harness asserts is that everything AROUND that act is real:
#
#   A  the packet names the actual binaries a user runs -- the ones inside the
#      portable zip, by name, with their real SHA-256s -- not the archive.
#   B  every attachment is a path that exists on disk, because the portal wants
#      uploads and "attach the file with this hash" is not an instruction.
#   C  the narrative carries the provenance a reviewer asks for: public source,
#      the detection name, and the hashes of what is attached.
#   D  a written packet file lands beside the files, so filing does not require
#      the terminal that generated it to still be open.
#   E  it can say NOASK: no gh and no -AssetDir is the absence of an answer,
#      exit 4, and it must not emit a packet full of blanks. This is the
#      demonstration that the script can decline (go.md, T1133).
#   F  -Record refuses to write nothing, and writes to BOTH cards when given
#      something -- T1313 files it, T1293 closes on the determination.
#   G  parses under PS 5.1, and T1313 points at the script rather than at a
#      table of hashes.
#
# Read-only apart from a temp dir, offline, no network. Runs in a few seconds.
#
#   powershell -NoProfile -File test\win32\false-positive-report.ps1
#   powershell -NoProfile -File test\win32\false-positive-report.ps1 -NegativeControl
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

$packer = Join-Path $Repo 'scripts\report-false-positive.ps1'
$tmp = Join-Path $env:TEMP ("fp-report-test-" + [guid]::NewGuid().ToString('N'))
$assets = Join-Path $tmp 'assets'
$outdir = Join-Path $tmp 'out'
New-Item -ItemType Directory -Path $assets -Force | Out-Null

# ---------------------------------------------------------------------------
# A synthetic release: the msi, and a portable zip holding the three binaries
# the real archive carries plus the noise it also carries.
# ---------------------------------------------------------------------------
Set-Content -LiteralPath (Join-Path $assets 'Ghoztty-9.9.9-x64.msi') `
    -Value 'not really an msi' -Encoding ASCII
$stage = Join-Path $tmp 'stage'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($n in @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')) {
    Set-Content -LiteralPath (Join-Path $stage $n) -Value "stand-in for $n" -Encoding ASCII
}
New-Item -ItemType Directory -Path (Join-Path $stage 'share') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $stage 'share\ghostty.bash') -Value 'noise' -Encoding ASCII
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, (Join-Path $assets 'Ghoztty-portable-9.9.9-x64.zip'))

# powershell.exe is called by full path: section E runs with a PATH that has
# no gh on it, and a bare `powershell` would then be unresolvable too -- the
# run would fail for the wrong reason and read as the assertion passing.
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-Packer {
    param([string[]]$ExtraArgs, [string]$Path)

    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packer,
        '-RepoRoot', $Repo) + $ExtraArgs
    $saved = $env:PATH
    if ($Path) { $env:PATH = $Path }
    try {
        $out = & $psExe @argsList 2>&1
        return @{ Exit = $LASTEXITCODE; Text = ($out | Out-String) }
    } finally { $env:PATH = $saved }
}

$expectedHashes = @{}
foreach ($n in @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')) {
    $expectedHashes[$n] = (Get-FileHash -LiteralPath (Join-Path $stage $n) -Algorithm SHA256).Hash.ToLower()
}

# ============================================================================
"== A: the packet names the binaries a user runs"
# ============================================================================

$r = Invoke-Packer -ExtraArgs @('-AssetDir', $assets, '-OutDir', $outdir, '-Json', '-Quiet')
AssertEq 'A1 exits 0 on a directory of assets' 0 $r.Exit

$json = $null
try { $json = $r.Text | ConvertFrom-Json } catch { $json = $null }
Assert 'A2 emits parseable json' ($null -ne $json)

$attachNames = @()
if ($json) { $attachNames = @($json.attach | ForEach-Object { $_.name }) }
Assert 'A3 attaches ghoztty.exe' ($attachNames -contains 'ghoztty.exe')
Assert 'A4 attaches ghoztty.com' ($attachNames -contains 'ghoztty.com')
Assert 'A5 attaches ghoztty-agent.exe' ($attachNames -contains 'ghoztty-agent.exe')
# The archive itself is not a submission: an engine flags the binary inside it.
Assert 'A6 does not attach the zip' (-not ($attachNames | Where-Object { $_ -match '\.zip$' }))

$hashOk = $true
if ($json) {
    foreach ($a in $json.attach) {
        if ($expectedHashes.ContainsKey($a.name) -and $expectedHashes[$a.name] -ne $a.sha256) {
            $hashOk = $false
        }
    }
} else { $hashOk = $false }
Assert 'A7 each attachment carries the real SHA-256 of that file' $hashOk

# ============================================================================
"== B: every attachment is a file that exists"
# ============================================================================

$pathsOk = $true
$pathCount = 0
if ($json) {
    foreach ($a in $json.attach) {
        $pathCount++
        if (-not $a.path -or -not (Test-Path -LiteralPath $a.path)) { $pathsOk = $false }
    }
} else { $pathsOk = $false }
Assert 'B1 every attachment has a path on disk' ($pathsOk -and $pathCount -ge 3)

# ============================================================================
"== C: the narrative carries the provenance"
# ============================================================================

$narrative = ''
if ($json) { $narrative = [string]$json.narrative }
Assert 'C1 names the detection' ($narrative -match 'Wacatac')
Assert 'C2 points at the public source' ($narrative -match 'github\.com/dzearing/ghoztty')
Assert 'C3 says the build is unsigned' ($narrative -match 'not code-signed')
$sha = $expectedHashes['ghoztty.exe']
Assert 'C4 carries the hash of what is attached' ($narrative -match [regex]::Escape($sha))

# ============================================================================
"== D: a packet file lands beside the files"
# ============================================================================

$packetFile = Join-Path $outdir 'submission-packet.txt'
Assert 'D1 submission-packet.txt written' (Test-Path -LiteralPath $packetFile)
$packetText = ''
if (Test-Path -LiteralPath $packetFile) { $packetText = Get-Content -LiteralPath $packetFile -Raw }
Assert 'D2 the file names the portal' ($packetText -match 'wdsi/filesubmission')
Assert 'D3 the file carries the attachment hashes' ($packetText -match [regex]::Escape($sha))

# The human-readable run says how to file it, not merely what the bytes are.
$human = Invoke-Packer -ExtraArgs @('-AssetDir', $assets, '-OutDir', $outdir)
Assert 'D4 the printed packet says to choose the developer form' `
    ($human.Text -match '(?i)software developer')
Assert 'D5 the printed packet says how to record the submission id' `
    ($human.Text -match '-Record')

# ============================================================================
"== E: it can decline"
# ============================================================================

# No -AssetDir and no gh on PATH is the absence of an answer, not a packet.
$noGh = Invoke-Packer -ExtraArgs @('-OutDir', (Join-Path $tmp 'nogh')) `
    -Path (Join-Path $env:SystemRoot 'System32')
AssertEq 'E1 no gh and no -AssetDir exits NOASK (4)' 4 $noGh.Exit
Assert 'E2 and prints NOASK' ($noGh.Text -match 'NOASK')
Assert 'E3 and emits no packet' ($noGh.Text -notmatch 'FALSE-POSITIVE SUBMISSION PACKET')

# ============================================================================
"== F: -Record refuses to record nothing"
# ============================================================================

$empty = Invoke-Packer -ExtraArgs @('-Record')
AssertEq 'F1 -Record with no id and no determination is an error' 1 $empty.Exit
Assert 'F2 and says what it needed' ($empty.Text -match 'SubmissionId')

$packerText = Get-Content -LiteralPath $packer -Raw
# T1313 is where a submission is filed; T1293 is the card that closes on the
# determination. A receipt that lands on only one of them is how the other gets
# reopened from stale evidence (T892).
Assert 'F3 -Record writes to both T1313 and T1293' `
    ($packerText -match "@\('T1313',\s*'T1293'\)")

# ============================================================================
"== G: parse and wiring"
# ============================================================================

$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($packer, [ref]$null, [ref]$parseErrors) | Out-Null
AssertEq 'G1 the script parses cleanly under PS 5.1' 0 (@($parseErrors).Count)

# The card has to send its reader at the generator. A task that still carries a
# hand-typed hash table is a task that will be filed from stale bytes.
$card = Get-Content -LiteralPath (Join-Path $Repo 'docs\design\windows-parity-tasks\T1313.md') -Raw
Assert 'G2 T1313 points at report-false-positive.ps1' ($card -match 'report-false-positive\.ps1')

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# A clean green run stamps the covered files (T783).
Complete-TestBody
if (-not $NegativeControl -and $script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard false-positive-report -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
