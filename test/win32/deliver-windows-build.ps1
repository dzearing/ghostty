# A delivery to install locations 2 and 3 must be MEASURED, not asserted (T198).
#
# The standing bar is that a user-facing fix reaches all three install
# locations. Only the installed release has ever been scripted; the Desktop
# portable, the network share, the share's loose agent and the portable ZIP were
# re-derived from prose in the session log every time. Two measurements say what
# that costs:
#
#   * T196 (2026-07-30) hand-built the zip. It exited 0 and was wrong twice -
#     rooted at `Ghoztty-portable-x64\Ghoztty\...` instead of `Ghoztty\...`, and
#     carrying both `.pdb` files (20.3 MB -> 41.9 MB over a network share).
#   * 2026-08-10, found while writing the script under test: both portable
#     locations held a DEBUG `ghoztty.exe` (+edc526574, PE subsystem 3) beside a
#     RELEASE `ghoztty.com` (+213a21f0d), an hour after the morning refresh had
#     logged `extra install '...': ghoztty.exe, ghoztty.com, ...`. The copy
#     reported success and the bytes on disk were from another build.
#
# So the arms below are about the CHECKS, not the copy:
#
#   A  pure: the manifest, the zip inclusion rule, the entry-set diff, the
#      backup-generation retention rule. No filesystem.
#   B  the PE subsystem read against real binaries - the one signal that tells a
#      release ghoztty.exe from a Debug one without trusting a version string.
#   C  end-to-end into a sandbox seeded with a DEBUG build, which is the
#      2026-08-10 state: it must be replaced and verified.
#   D  teeth. A staging prefix that is a Debug build is refused; a delivery whose
#      binaries do not answer the expected commit FAILS; a zip whose entry set
#      moved is NOT published.
#   E  the second run is a no-op apart from new backups, and still verifies.
#
# Hermetic: every directory it writes is under the sandbox root, the real
# install locations are never named, and no build is ever run. It reads two real
# binaries (the release staging prefix and the debug zig-out) but only ever
# copies them into the sandbox.
#
#   powershell -NoProfile -File test\win32\deliver-windows-build.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$Staging = 'D:\git\ghoztty\zig-out-release',
    # Only ever used as a real binary that is a DEBUG build. Never launched.
    [string]$DebugBin = 'D:\git\ghoztty\zig-out\bin',
    [switch]$PureOnly,
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-deliver-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

. (Join-Path $Repo 'scripts\delivery-manifest.ps1')
# T680: those +version runs dial the IPC endpoint for their "Running Instance"
# section, and the delivered binaries are RELEASE builds - unsuffixed, that
# query goes to the user's own app. The suffix is inherited by the child
# deliver script, so every read-back stays private. (Set only, no asserts:
# a release build is the SUBJECT here, which the asserts would refuse.)
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'deliver')
# T199: this run delivers real binaries into stand-in install dirs under $root
# and runs them for their +version. Arm the teardown so a run that dies mid-way
# still takes its ghoztty processes with it.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-HarnessGhozttyRoot -Root $root | Out-Null
$deliver = Join-Path $Repo 'scripts\deliver-windows-build.ps1'

# ============================================================================
"== A: what a delivery consists of (pure)"
# ============================================================================

$full = @(Get-DeliveryFileSet)
$app = @(Get-DeliveryFileSet -AppOnly)
Assert "A1 ghoztty.com ships (PATHEXT resolves .COM first, T245)" ($full -contains 'ghoztty.com')
Assert "A2 the agent ships in a full delivery" ($full -contains 'ghoztty-agent.exe')
Assert "A3 -AppOnly ships no agent at all" (-not ($app | Where-Object { $_ -like '*agent*' }))
Assert "A4 -AppOnly still ships the .com" ($app -contains 'ghoztty.com')

$bak = @(Get-BackupFileSet)
Assert "A5 backups keep what you RUN" ($bak -contains 'ghoztty.exe' -and $bak -contains 'ghoztty.com')
Assert "A6 backups skip the .pdb files (85 MB + 11 MB every delivery)" (-not ($bak | Where-Object { $_ -like '*.pdb' }))
Assert "A7 -BackupAll takes everything" ((@(Get-BackupFileSet -All) | Where-Object { $_ -like '*.pdb' }).Count -eq 2)

# The zip rule. T196 shipped both .pdb files; the portable directory also holds
# 62 `.bak-*` files, which is what "zip whatever is there" would have picked up.
Assert "A8 the zip takes the app" (Test-PortableZipIncludes 'ghoztty.exe')
Assert "A9 the zip takes share\ content" (Test-PortableZipIncludes 'share/ghostty/themes/Nord')
Assert "A10 the zip refuses a .pdb (the T196 defect)" (-not (Test-PortableZipIncludes 'ghoztty.pdb'))
Assert "A11 the zip refuses a plain .bak" (-not (Test-PortableZipIncludes 'ghoztty.exe.bak'))
Assert "A12 the zip refuses a dated .bak-*" (-not (Test-PortableZipIncludes 'ghoztty.exe.bak-20260730-t196'))
Assert "A13 the zip refuses a name someone stamped mid-word" (-not (Test-PortableZipIncludes 'ghoztty-agent-jul3.exe.bak'))
Assert "A14 the zip refuses a dotfile at the archive root" (-not (Test-PortableZipIncludes '.gitignore'))
Assert "A14b but a dotfile INSIDE share\ is shipped content, not junk" `
    (Test-PortableZipIncludes 'share/ghostty/shell-integration/zsh/.zshenv')
Assert "A14c the zip refuses an image a delivery had to shove aside" `
    (-not (Test-PortableZipIncludes 'ghoztty.exe.locked-20260810-213000'))

AssertEq "A15 the root prefix is Ghoztty/, not the wrapper folder (the other T196 defect)" `
    'Ghoztty/share/ghostty/themes/Nord' (ConvertTo-ZipEntryName -Root 'Ghoztty' -Relative 'share\ghostty\themes\Nord')

# The diff. .NET Framework's zip writer emits BACKSLASH entry names on Windows,
# which is what the artifact being replaced contains; correcting that to the
# spec's forward slash must not read as a shape change.
$sep = Get-ZipShapeDiff -Old @('Ghoztty\ghoztty.exe', 'Ghoztty\share\') -New @('Ghoztty/ghoztty.exe')
Assert "A16 a separator correction is not a shape change" (-not $sep.Changed)
AssertEq "A17 a directory entry is not counted on either side" 1 $sep.OldCount

$grew = Get-ZipShapeDiff -Old @('Ghoztty/ghoztty.exe') -New @('Ghoztty/ghoztty.exe', 'Ghoztty/ghoztty.com')
Assert "A18 an added file IS a shape change" $grew.Changed
AssertEq "A19 and it is named" 'Ghoztty/ghoztty.com' ($grew.Added -join ',')
$pdb = Get-ZipShapeDiff -Old @('Ghoztty/ghoztty.exe') -New @('Ghoztty/ghoztty.exe', 'Ghoztty/ghoztty.pdb')
Assert "A20 T196's stray .pdb would have been caught here" $pdb.Changed
$nest = Get-ZipShapeDiff -Old @('Ghoztty/ghoztty.exe') -New @('Ghoztty-portable-x64/Ghoztty/ghoztty.exe')
AssertEq "A21 T196's double-nested root shows as 1 added + 1 removed" '1/1' "$($nest.Added.Count)/$($nest.Removed.Count)"

# Backup generations.
AssertEq "A22 a dated backup carries its generation" '20260730-t196' (Get-BackupGeneration 'ghoztty.exe.bak-20260730-t196')
AssertEq "A23 the stampless convention is a generation too" '' (Get-BackupGeneration 'ghoztty.exe.bak')
Assert "A24 a shipped file is not a backup" ($null -eq (Get-BackupGeneration 'ghoztty.exe'))

$names = @(
    'ghoztty.exe.bak-20260801-000000', 'ghoztty.com.bak-20260801-000000',
    'ghoztty.exe.bak-20260802-000000', 'ghoztty.com.bak-20260802-000000',
    'ghoztty.exe.bak-20260803-000000', 'ghoztty.exe', 'share'
)
$doomed = @(Select-StaleBackups -Names $names -Keep 2)
AssertEq "A25 keeping 2 generations drops the oldest generation whole" `
    'ghoztty.com.bak-20260801-000000,ghoztty.exe.bak-20260801-000000' ($doomed -join ',')
Assert "A26 a live file is never selected" (-not ($doomed -contains 'ghoztty.exe'))
AssertEq "A27 keeping more generations than exist deletes nothing" 0 (@(Select-StaleBackups -Names $names -Keep 9).Count)
AssertEq "A28 -PruneBackups 0 takes them all" 5 (@(Select-StaleBackups -Names $names -Keep 0).Count)

if ($PureOnly) {
    ""
    if ($script:failures -eq 0) { "ALL PASS" } else { "$script:failures FAILURE(S)" }
    exit ([int]($script:failures -gt 0))
}

# ============================================================================
""
"== B: telling a release build from a Debug one"
# ============================================================================

$relExe = Join-Path $Staging 'bin\ghoztty.exe'
$relCom = Join-Path $Staging 'bin\ghoztty.com'
$dbgExe = Join-Path $DebugBin 'ghoztty.exe'
AssertEq "B1 a release ghoztty.exe is GUI subsystem" 2 (Get-PeSubsystem $relExe)
AssertEq "B2 its .com twin is console subsystem (T245)" 3 (Get-PeSubsystem $relCom)
AssertEq "B3 a DEBUG ghoztty.exe is console subsystem - the 2026-08-10 tell" 3 (Get-PeSubsystem $dbgExe)
AssertEq "B4 a file that is not a PE reads 0, never a wrong answer" 0 (Get-PeSubsystem (Join-Path $Repo 'go.md'))
AssertEq "B5 a missing file reads 0" 0 (Get-PeSubsystem (Join-Path $root 'nope.exe'))
AssertEq "B6 the expectation is per-binary" '2/3/0' `
    ("{0}/{1}/{2}" -f (Get-ExpectedSubsystem 'ghoztty.exe'), (Get-ExpectedSubsystem 'ghoztty.com'), (Get-ExpectedSubsystem 'ghostty-vt.dll'))

# ============================================================================
""
"== C: end to end into a sandbox seeded with a DEBUG build"
# ============================================================================

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
$p1 = Join-Path $root 'desktop\Ghoztty'
$p2 = Join-Path $root 'share-portable\Ghoztty'
$shareRoot = Join-Path $root 'share'
New-Item -ItemType Directory -Force -Path $p1, $p2, $shareRoot | Out-Null

# Seed p1 exactly as the box was found on 2026-08-10: a debug ghoztty.exe.
Copy-Item (Join-Path $DebugBin 'ghoztty.exe') (Join-Path $p1 'ghoztty.exe') -Force
Set-Content (Join-Path $p1 'READ-ME-FIRST.txt') 'portable' -Encoding ascii
Set-Content (Join-Path $p2 'READ-ME-FIRST.txt') 'portable' -Encoding ascii
$zipPath = Join-Path $shareRoot 'Ghoztty-portable-x64.zip'

# $Extra is a HASHTABLE, not an array: splatted array elements are always bound
# POSITIONALLY, so `@('-NoZip')` reaches a [CmdletBinding(PositionalBinding=$false)]
# script as a positional argument and the bind is rejected before line 1 - which
# reads here as the script exiting 2, i.e. a gate firing that never ran.
function Invoke-Deliver {
    param([hashtable]$Extra = @{})
    $out = & $deliver -Staging $Staging -Targets @($p1, $p2) -LooseAgentDir $shareRoot `
        -ZipPath $zipPath @Extra *>&1 | ForEach-Object { "$_" }
    return @{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Last = @($out)[-1] }
}

$r = Invoke-Deliver
AssertEq "C1 the delivery succeeds" 0 $r.Code
Assert "C2 and says so on its last line" ($r.Last -like 'DELIVER OK:*')
AssertEq "C3 the seeded DEBUG exe was replaced by the release one" 2 (Get-PeSubsystem (Join-Path $p1 'ghoztty.exe'))
Assert "C4 every shipped file landed in both locations" (
    (@(Get-DeliveryFileSet) | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $p1 $_)) -or -not (Test-Path -LiteralPath (Join-Path $p2 $_))
    }).Count -eq 0)
Assert "C5 share\ was mirrored" (Test-Path -LiteralPath (Join-Path $p1 'share\ghostty\themes\Nord'))
Assert "C6 the share's loose agent was refreshed" (Test-Path -LiteralPath (Join-Path $shareRoot 'ghoztty-agent.exe'))
Assert "C7 the portable zip was published" (Test-Path -LiteralPath $zipPath)

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
function Get-ZipNames([string]$p) {
    $z = [IO.Compression.ZipFile]::OpenRead($p)
    try { return @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
}
$zipNames = @(Get-ZipNames $zipPath)
Assert "C8 the zip is rooted at Ghoztty/, not the wrapper folder" `
    (($zipNames | Where-Object { $_ -notlike 'Ghoztty/*' }).Count -eq 0)
Assert "C9 the zip carries no .pdb" (($zipNames | Where-Object { $_ -like '*.pdb' }).Count -eq 0)
Assert "C10 the zip carries no .bak" (($zipNames | Where-Object { $_ -like '*.bak*' }).Count -eq 0)
Assert "C11 the zip carries the .com the shell actually runs" ($zipNames -contains 'Ghoztty/ghoztty.com')
Assert "C12 the zip carries share\" (($zipNames | Where-Object { $_ -like 'Ghoztty/share/*' }).Count -gt 100)

# ============================================================================
""
"== D: teeth - every gate must be able to say no"
# ============================================================================

# D1/D2: a Debug staging prefix is refused outright. This is the check that
# would have stopped 2026-08-10 at the source instead of on two network shares.
$fakeStaging = Join-Path $root 'debug-staging'
New-Item -ItemType Directory -Force -Path (Join-Path $fakeStaging 'bin') | Out-Null
foreach ($n in @(Get-DeliveryFileSet)) {
    $src = Join-Path $DebugBin $n
    if (Test-Path -LiteralPath $src) { Copy-Item $src (Join-Path $fakeStaging "bin\$n") -Force }
}
Copy-Item (Join-Path $DebugBin 'ghoztty.exe') (Join-Path $fakeStaging 'bin\ghoztty.com') -Force
$p3 = Join-Path $root 'debug-target\Ghoztty'
New-Item -ItemType Directory -Force -Path $p3 | Out-Null
$out = & $deliver -Staging $fakeStaging -Targets @($p3) -LooseAgentDir '' -NoZip *>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
AssertEq "D1 a Debug staging prefix is refused before anything is written" 2 $code
Assert "D2 and it says which binary gave it away" (($out -join "`n") -match 'PE subsystem .*Debug build')
Assert "D3 nothing was copied into the target" (-not (Test-Path -LiteralPath (Join-Path $p3 'ghoztty.exe')))

# D4/D5: the delivered binaries must answer the commit the delivery is FOR.
# Same real staging, a commit it cannot be carrying.
$r = Invoke-Deliver -Extra @{ ExpectedCommit = 'deadbee'; NoZip = $true }
AssertEq "D4 a delivery whose bits report another commit FAILS" 1 $r.Code
Assert "D5 and says so on its last line" ($r.Last -like 'DELIVER FAILED:*')
Assert "D6 naming the commit it got instead" ($r.Text -match 'reports \+[0-9a-f]{7,} but this delivery is \+deadbee')

# D7-D9: an entry-set change stops the zip from being published.
$stray = Join-Path $p1 'STRAY-FILE.txt'
Set-Content $stray 'this was not in the artifact being replaced' -Encoding ascii
$before = (Get-Item -LiteralPath $zipPath).LastWriteTimeUtc
$r = Invoke-Deliver
AssertEq "D7 an unannounced zip shape change fails the run" 1 $r.Code
Assert "D8 and the zip on disk was NOT replaced" ((Get-Item -LiteralPath $zipPath).LastWriteTimeUtc -eq $before)
Assert "D9 the new entry is named in the output" ($r.Text -match 'STRAY-FILE\.txt')

$r = Invoke-Deliver -Extra @{ AcceptZipShape = $true }
AssertEq "D10 -AcceptZipShape is how a deliberate change ships" 0 $r.Code
Assert "D11 and the zip now carries it" ((Get-ZipNames $zipPath) -contains 'Ghoztty/STRAY-FILE.txt')
Remove-Item -LiteralPath $stray -Force

# D12b: -AppOnly ships no agent, so it must not publish an archive that pairs a
# new app with whatever agent the portable directory happened to have.
$zipStamp = (Get-Item -LiteralPath $zipPath).LastWriteTimeUtc
$r = Invoke-Deliver -Extra @{ AppOnly = $true }
AssertEq "D12a -AppOnly still delivers the app" 0 $r.Code
Assert "D12b and leaves the portable zip alone" ((Get-Item -LiteralPath $zipPath).LastWriteTimeUtc -eq $zipStamp)
Assert "D12c saying why" ($r.Text -match 'AppOnly ships no agent')
Assert "D12d and skips the share's loose agent for the same reason" ($r.Text -match 'loose share agent')

# D12: an absent location is skipped, never a failure - a sleeping NAS must not
# fail a delivery that otherwise worked.
$out = & $deliver -Staging $Staging -Targets @((Join-Path $root 'no-such-place')) `
    -LooseAgentDir '' -NoZip *>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
AssertEq "D12 an unreachable location exits 0" 0 $code
Assert "D13 but never claims OK" (@($out)[-1] -like 'DELIVER SKIPPED:*')

# ============================================================================
""
"== E: re-run - a no-op apart from new backups, still verified"
# ============================================================================

$r = Invoke-Deliver -Extra @{ AcceptZipShape = $true }
AssertEq "E1 the second run succeeds" 0 $r.Code
Assert "E2 and still verifies every location" ($r.Last -like 'DELIVER OK:*')
$baks = @(Get-ChildItem -LiteralPath $p1 -File | Where-Object { $null -ne (Get-BackupGeneration $_.Name) })
Assert "E3 it left dated backups behind" ($baks.Count -gt 0)
Assert "E4 and no .pdb among them" (($baks | Where-Object { $_.Name -like '*.pdb.bak*' }).Count -eq 0)

# The retention offer: reported by default, acted on only when asked.
$out = & $deliver -Staging $Staging -Targets @($p1) -LooseAgentDir '' -NoZip *>&1 | ForEach-Object { "$_" }
Assert "E5 backups are OFFERED for pruning, never pruned by default" (($out -join "`n") -match 'prune with -PruneBackups')
$gensBefore = @($baks | ForEach-Object { Get-BackupGeneration $_.Name } | Sort-Object -Unique).Count
$out = & $deliver -Staging $Staging -Targets @($p1) -LooseAgentDir '' -NoZip -PruneBackups 1 *>&1 | ForEach-Object { "$_" }
$gensAfter = @(Get-ChildItem -LiteralPath $p1 -File |
    ForEach-Object { Get-BackupGeneration $_.Name } | Where-Object { $null -ne $_ } | Sort-Object -Unique).Count
Assert "E6 -PruneBackups keeps only what it was asked to" ($gensAfter -le 2 -and $gensBefore -ge 1)

# ============================================================================
""
"== F: what the delivery says about relay sign-in (T795)"
# ============================================================================
# A build with no Google OAuth client id baked in cannot start a relay sign-in
# at all; the machine chooser says so rather than offering a dead button (T747).
# Every delivered Windows build was in that state for months and no delivery log
# mentioned it once, because the id is build configuration - so a delivery that
# silently disabled sign-in and one that enabled it produced identical output.
#
# The arms below are about the REPORT. The comparator itself has its teeth in
# arms A36-A48 of upgrade-staleness.ps1, where a mismatch can be constructed:
# here the delivered file is by definition the copy of the staged one, so a
# forced disagreement would have to be faked rather than measured.
. (Join-Path $Repo 'scripts\delivery-version.ps1')
$stagedBake = (Resolve-GhozttyExeCommit -Exe (Join-Path $Staging 'bin\ghoztty.exe')).SignIn
$r = Invoke-Deliver -Extra @{ AcceptZipShape = $true }
AssertEq "F2 the delivery still succeeds" 0 $r.Code
# The invariant that holds whatever staging happens to carry, and the one thing
# that was missing for months: a delivery is never SILENT about sign-in. Which
# of the three sentences it prints is asserted below, against the state the
# staged binary actually reports - a staging prefix built before T795 prints no
# line of its own and must read as unreported, not as broken.
Assert "F1 the run says something about sign-in, in one of the three known phrasings ($(Format-SignInBake $stagedBake))" `
    ($r.Text -match 'sign-in configured|NO google client id baked in|sign-in unreported by the staged exe')
if ($stagedBake.Known -and -not $stagedBake.Configured) {
    # Today's real state on this box: no google-client-id.txt exists, so the
    # warning is what a human would need to see to know sign-in is off.
    Assert "F3 a build that cannot sign in WARNS, in words that name the fix" `
        ($r.Text -match 'NO google client id baked in' -and $r.Text -match 'relay sign-in will be unavailable')
} elseif ($stagedBake.Configured) {
    Assert "F3 a configured build names the id it is shipping" `
        ($r.Text -match [regex]::Escape($stagedBake.ClientId))
    Assert "F3b and every verified location reports it back" ($r.Text -match 'sign-in configured')
} else {
    Assert "F3 a pre-T795 staging build says it cannot be checked" `
        ($r.Text -match 'sign-in unreported by the staged exe')
}

# ============================================================================
if (-not $Keep) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }

# A clean green FULL run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has anybody proved the delivery still measures what it claims,
# against the code as it now stands?". Red leaves the stamp alone, and so does
# -PureOnly, which exits above without ever having run a delivery.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard deliver-verify -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$script:failures FAILURE(S)" }
exit ([int]($script:failures -gt 0))
