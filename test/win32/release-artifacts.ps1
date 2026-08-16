# Every release ships Windows too, and ships BOTH Windows artifacts (T38).
#
# Before this, the Windows terminal was published by hand from this box
# (scripts\publish-windows-release.ps1) and the macOS app was published by a
# tag push. The two drifted exactly as far as you would expect: the Mac
# channel was at v1.28.0 and the Windows channel at win-v1.4.1 - 24 releases
# where a Windows user saw nothing. So the artifacts are now built by
# .github/workflows/release-windows.yml on the SAME tag push that builds the
# DMG, from the same script the on-box path runs.
#
# What this asserts, in the order the release actually happens:
#
#   A  pure/static: the tag trigger cannot diverge from release.yml, the tag
#      the workflow publishes is the one the app's update check scans for,
#      and the artifact NAMES agree across all three places that write them
#      (workflow, shared script, on-box script). Plus: the on-box script
#      PARSES - a UTF-8 em dash in a BOM-less .ps1 decodes to a cp1252 smart
#      quote under PS 5.1 and closed a string, which made the whole publish
#      script unparseable under `powershell -File` from the day it was
#      written until T38. A parse gate is the only thing that catches that.
#   B  live packaging (needs Docker + the msitools-local image): the
#      FILEVERSION rule has exactly one live definition, and the portable ZIP
#      really contains the MSI's payload under a single Ghoztty/ root.
#   C  the documented process points at the automated one.
#   D  -Full only: the whole on-box publish, -DryRun, end to end. Off by
#      default because it runs a multi-minute ReleaseFast build.
#
# Read-only apart from zig-out artifact files and a temp dir; never launches
# the app, never publishes anything (D stops at -DryRun).
#
#   powershell -NoProfile -File test\win32\release-artifacts.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    # Docker not running is a SKIP by default (section B is the only part
    # that needs it); -RequireDocker turns those skips into failures.
    [switch]$RequireDocker,
    [switch]$Full
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Skip($name, $why) {
    if ($RequireDocker) { "  FAIL $name ($why)"; $script:failures++ }
    else { "  SKIP $name ($why)"; $script:skipped++ }
}

$wf = Get-Content -LiteralPath (Join-Path $Repo '.github\workflows\release-windows.yml') -Raw
$macWf = Get-Content -LiteralPath (Join-Path $Repo '.github\workflows\release.yml') -Raw
$shared = Get-Content -LiteralPath (Join-Path $Repo 'dist\windows-installer\build-release-artifacts.sh') -Raw
$zipSh = Get-Content -LiteralPath (Join-Path $Repo 'dist\windows-installer\build-portable-zip.sh') -Raw
$msiSh = Get-Content -LiteralPath (Join-Path $Repo 'dist\windows-installer\build-msi.sh') -Raw
$ps1Path = Join-Path $Repo 'scripts\publish-windows-release.ps1'
$ps1 = Get-Content -LiteralPath $ps1Path -Raw

# ============================================================================
"== A: the release cannot ship one platform (pure)"
# ============================================================================

# A1-A2: the Windows triggers are the macOS triggers PLUS win-v* (T577).
# Until merge-back a Windows release is cut as its own win-v tag on the
# Windows branch (main's tree cannot build one); at merge-back the shared v*
# pattern takes over with nothing rewired. A dropped v* is how "every release
# ships Windows" quietly breaks at merge-back; a dropped win-v* breaks it
# today. A stricter macOS-side pattern is the same disease in the other
# direction, hence per-pattern containment rather than string equality.
function Get-TagPatterns($yaml) {
    $m = [regex]::Match($yaml, '(?ms)^on:.*?tags:\s*\r?\n((?:\s*-\s*"[^"]+"\r?\n)+)')
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '-\s*"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value })
}
$winTags = Get-TagPatterns $wf
$macTags = Get-TagPatterns $macWf
Assert "A1 release.yml has a tag trigger" ($macTags.Count -gt 0)
foreach ($t in $macTags) {
    Assert "A2 Windows trigger carries macOS pattern '$t'" ($winTags -contains $t)
}
Assert "A2b Windows trigger carries win-v*" ($winTags -contains 'win-v*')

# A3-A4: a tag that is not X.Y.Z must fail loudly, not be skipped. The
# version comes from the tag with BOTH shapes normalized: win- stripped
# first, then v -- one combined substitution leaves `win-v1.31.0` untouched
# (the prefix `refs/tags/v` never matches it) and fails the X.Y.Z regex over
# a version that was never malformed.
Assert "A3 non-X.Y.Z tag is an error, not a skip" ($wf -match '::error::Version must be X\.Y\.Z')
Assert "A4 the version is taken from the tag" (
    ($wf -match 'TAG_NAME=\$\{GITHUB_REF#refs/tags/\}') -and
    ($wf -match 'VERSION=\$\{TAG_NAME#win-\}') -and
    ($wf -match 'VERSION=\$\{VERSION#v\}'))

# A5-A6: the tag it publishes is the one installed builds look for. This is a
# contract with shipped binaries (T24), not a naming preference.
$prefix = [regex]::Match(
    (Get-Content -LiteralPath (Join-Path $Repo 'src\apprt\win32\update_check.zig') -Raw),
    'pub const tag_prefix = "([^"]+)"').Groups[1].Value
AssertEq "A5 update_check scans win-v" 'win-v' $prefix
Assert "A6 the workflow publishes that prefix" ($wf -match ('TAG=' + [regex]::Escape($prefix) + '\$VERSION'))
Assert "A7 published with --latest=false (Mac latest flow untouched)" ($wf -match '--latest=false')

# A8-A11: the artifact names. Three writers, one convention: version + arch.
Assert "A8 workflow names both artifacts"  (($wf -match 'Ghoztty-\$VERSION-x64\.msi') -and ($wf -match 'Ghoztty-portable-\$VERSION-x64\.zip'))
Assert "A9 shared script names both"       (($shared -match 'Ghoztty-\$SEMVER-x64\.msi') -and ($shared -match 'Ghoztty-portable-\$SEMVER-x64\.zip'))
Assert "A10 on-box script names both"      (($ps1 -match 'Ghoztty-\$Version-x64\.msi') -and ($ps1 -match 'Ghoztty-portable-\$Version-x64\.zip'))
Assert "A11 build-msi.sh default matches"  ($msiSh -match 'Ghoztty-\$SEMVER-x64\.msi')

# A12: one definition of the artifact set - both publishers call it.
Assert "A12 workflow runs the shared script" ($wf -match 'build-release-artifacts\.sh')
Assert "A13 on-box script runs the shared script" ($ps1 -match 'build-release-artifacts\.sh')

# A14-A15: the agent sibling ships in BOTH layouts (T89h). The MSI has
# enforced this since T89h; the ZIP is new and needs the same gate.
Assert "A14 portable ZIP requires the agent" ($zipSh -match 'ghoztty-agent\.exe not found|must carry the session-persistence agent')
Assert "A15 portable ZIP requires the terminfo sentinel" ($zipSh -match 'ghostty\.terminfo')

# A16-A17: the parse gate, and the trap that made it necessary.
$errs = $null
$null = [System.Management.Automation.PSParser]::Tokenize($ps1, [ref]$errs)
Assert "A16 publish-windows-release.ps1 parses under PS 5.1" (-not $errs -or $errs.Count -eq 0)
$nonAscii = @([regex]::Matches($ps1, '[^\x00-\x7F]'))
Assert "A17 publish-windows-release.ps1 is ASCII (no BOM-less mojibake)" ($nonAscii.Count -eq 0)

# A18: -First on a native pipeline tears the command down mid-stream (go.md).
# Comment lines are stripped first - the script explains the trap in a
# comment, and matching that would fail the file for documenting itself.
$ps1Code = ($ps1 -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert "A18 no Select-Object -First on a native pipeline" ($ps1Code -notmatch 'Select-Object -First')

# ============================================================================
"== B: packaging (Docker + msitools-local)"
# ============================================================================
$repoUnix = $Repo -replace '\\', '/'
$dockerUp = $false
$prev = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
docker info *> $null
$dockerUp = ($LASTEXITCODE -eq 0)
if ($dockerUp) {
    docker image inspect msitools-local *> $null
    $imageUp = ($LASTEXITCODE -eq 0)
} else { $imageUp = $false }
$ErrorActionPreference = $prev

if (-not $dockerUp) {
    Skip "B1 FILEVERSION single source" 'Docker is not running'
    Skip "B2 portable ZIP layout" 'Docker is not running'
} elseif (-not $imageUp) {
    Skip "B1 FILEVERSION single source" 'msitools-local image missing'
    Skip "B2 portable ZIP layout" 'msitools-local image missing'
} else {
    # B1: the yy.m.d.NN rule has ONE live definition. The on-box script used
    # to restate it in PowerShell; four private copies of a shared datum is
    # how T257's rounding bug survived four scripts.
    $printed = (docker run --rm -v "${repoUnix}:/repo" -w /repo msitools-local `
            bash dist/windows-installer/build-msi.sh --print-file-version --build-num 7 |
        Select-Object -Last 1).Trim()
    $expect = "{0}.{1}.{2}.7" -f [int](Get-Date -Format yy), [int](Get-Date -Format MM), [int](Get-Date -Format dd)
    AssertEq "B1 FILEVERSION single source" $expect $printed
    Assert "B1b on-box script asks for it instead of restating it" ($ps1 -match '--print-file-version')

    # B2: the ZIP really is the MSI's payload, laid out for a human.
    $out = "test-portable-$PID.zip"
    docker run --rm -v "${repoUnix}:/repo" -w /repo msitools-local `
        bash dist/windows-installer/build-portable-zip.sh --semver 9.9.9 `
        --out "zig-out/$out" *> $null
    $zipPath = Join-Path $Repo "zig-out\$out"
    if (-not (Test-Path $zipPath)) {
        Assert "B2 portable ZIP layout" $false
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($zipPath)
        $names = @($za.Entries | ForEach-Object { $_.FullName })
        $za.Dispose()
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        foreach ($need in @('Ghoztty/ghoztty.exe', 'Ghoztty/ghoztty-agent.exe',
                'Ghoztty/share/terminfo/ghostty.terminfo', 'Ghoztty/READ-ME-FIRST.txt')) {
            Assert "B2 portable ZIP has $need" ($names -contains $need)
        }
        $roots = @($names | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
        AssertEq "B3 single Ghoztty/ root" 'Ghoztty' ($roots -join ',')
    }
}

# ============================================================================
"== C: the documented process points at the automated one"
# ============================================================================
$releaseMd = Get-Content -LiteralPath (Join-Path $Repo '.claude\commands\release.md') -Raw
Assert "C1 release.md covers the Windows terminal build" ($releaseMd -match 'release-windows\.yml')
Assert "C2 release.md names both artifacts" (($releaseMd -match '-x64\.msi') -and ($releaseMd -match 'portable-.*-x64\.zip'))

# ============================================================================
"== E: CI proves the release path before release time (T578, pure)"
# ============================================================================
# T577 found that release-windows.yml's cross-compile had never once executed
# before an actual release. fork-ci's windows-cross job closes that: the same
# artifact script, the same msitools install, on every push to the Windows
# branch -- and publishing nothing.
$forkCi = Get-Content -LiteralPath (Join-Path $Repo '.github\workflows\fork-ci.yml') -Raw
$msiInstallPath = Join-Path $Repo 'dist\windows-installer\install-msitools.sh'
$msiInstall = Get-Content -LiteralPath $msiInstallPath -Raw

Assert "E1 fork-ci has a windows-cross job" ($forkCi -match '(?m)^  windows-cross:')
Assert "E2 fork-ci pushes on the Windows branch" ($forkCi -match 'users/dzearing/windows-amd64')
Assert "E3 windows-cross runs the shared artifact script" ($forkCi -match 'build-release-artifacts\.sh')

# E4: ONE msitools install, shared by both workflows. Two inline copies is
# how the release's toolchain and CI's would drift back apart.
Assert "E4 fork-ci installs msitools via the shared script" ($forkCi -match 'install-msitools\.sh')
Assert "E4b release workflow installs msitools via the shared script" ($wf -match 'install-msitools\.sh')
Assert "E4c the shared script pins msitools 0.106" ($msiInstall -match 'MSITOOLS_TAG="\$\{MSITOOLS_TAG:-v0\.106\}"')

# E5: the CI job must never publish. Slice the windows-cross job's own text
# (from its header to end-of-file; it is the last job) so a publish step
# elsewhere in the file cannot mask one added here.
$jobM = [regex]::Match($forkCi, '(?ms)^  windows-cross:.*\z')
Assert "E5 windows-cross publishes nothing" ($jobM.Success -and
    $jobM.Value -notmatch 'gh release' -and
    $jobM.Value -notmatch 'upload-artifact' -and
    $jobM.Value -notmatch 'gh-pages')

# E6: gated on tree content, not branch name -- main's tree has no win32
# frontend, and a branch-name gate would also silence the deliberate-break
# check (a PR from a scratch branch must get the real build).
Assert "E6 windows-cross detects the win32 tree" ($jobM.Success -and
    $jobM.Value -match 'src/apprt/win32')

# E7: the runbook expects CI to have proven the build, not the release.
Assert "E7 release.md points at the windows-cross job" ($releaseMd -match 'windows-cross')

# ============================================================================
if ($Full) {
    "== D: the on-box publish, end to end (-DryRun)"
    # ============================================================================
    $log = Join-Path $env:TEMP "ghoztty-release-artifacts-$PID.log"
    powershell -NoProfile -File (Join-Path $Repo 'scripts\publish-windows-release.ps1') `
        -DryRun -BuildNum 99 *> $log
    $code = $LASTEXITCODE
    $text = Get-Content -LiteralPath $log -Raw
    AssertEq "D1 dry-run publish exits 0" 0 $code
    Assert "D2 version defaulted to the newest macOS tag" ($text -match '-Version defaulted to the newest macOS release tag')
    Assert "D3 exe carries the release semver" ($text -match 'exe reports \d+\.\d+\.\d+\+')
    Assert "D4 MSI produced" ($text -match 'artifact: .*Ghoztty-\d+\.\d+\.\d+-x64\.msi')
    Assert "D5 portable ZIP produced" ($text -match 'artifact: .*Ghoztty-portable-\d+\.\d+\.\d+-x64\.zip')
    Assert "D6 stopped before publishing" ($text -match 'DRY RUN: skipping gh release create')
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this harness been run against the release wiring as it now
# stands?". Red leaves the stamp alone (red stays due), and so does a run
# with skips -- a Docker-less run never looked at the packaging sections it
# would be vouching for.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard release-artifacts -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) { "ALL PASS ($($script:skipped) skipped)" } else { "ALL PASS" }
} else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
