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
#   B  live packaging: the FILEVERSION rule has exactly one live definition
#      (MSI half - needs Docker and the msitools-local image), and the portable
#      ZIP really contains the MSI's payload under a single Ghoztty/ root, twin
#      included (ZIP half - needs only bash + python3, so it runs here).
#   C  the documented process points at the automated one.
#   D  -Full only: the whole on-box publish, -DryRun, end to end. Off by
#      default because it runs a multi-minute ReleaseFast build.
#
# Read-only apart from zig-out artifact files and a temp dir; never launches
# the app, never publishes anything (D stops at -DryRun).
#
# isolation: none - no ghoztty binary is ever run here. The packaging sections
# BUILD artifacts and read their bytes back (entry sets, PE headers), which
# needs no endpoint at all; the CLI verbs that appear below are quoted inside
# comments explaining what a user's broken `ghoztty +list` looked like.
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

# A14b-A15c: the console twin ships in BOTH layouts too (T1052). It did not,
# for as long as either artifact has existed: `ghoztty.com` is the binary a
# shell actually runs (PATHEXT prefers .COM, and the GUI ghoztty.exe is not
# waited for), so every downloaded install answered `ghoztty +list` with
# silence while every install this repo's own delivery script made was whole.
# These are text assertions on the two build scripts, so they hold on a box
# with no Docker and no zig-out - which is exactly the box the gap survived on.
Assert "A14b portable ZIP stages the console twin" ($zipSh -match 'cp "\$COM_EXE" "\$ROOT/ghoztty\.com"')
Assert "A14c portable ZIP requires the console twin" ($zipSh -match 'COM_EXE" \]\] \|\|')
Assert "A14d portable ZIP validates the packaged twin is console-subsystem" (
    ($zipSh -match 'Ghoztty/ghoztty\.com') -and ($zipSh -match 'subsystem != 3'))
Assert "A15b MSI requires the console twin" ($msiSh -match 'COM_EXE" \]\] \|\|')
Assert "A15c MSI emits a component for the console twin" ($msiSh -match 'emit_file_component\("", com_exe, 12\)')
# Unversioned in the File table means Windows Installer falls back to the
# created/modified-date rule and can leave last release's CLI beside a fresh
# app; the twin carries ghoztty.exe's version resource, so it takes the same row.
Assert "A15d MSI versions the console twin like its siblings" ($msiSh -match 'want = \{[^}]*"ghoztty\.com": 0')

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

# A19: the on-box script ASKS build-msi.sh for the yy.m.d.NN rule instead of
# restating it (four private copies of a shared datum is how T257's rounding
# bug survived four scripts). This is a regex over the script's own text and
# needs no Docker; it lived inside section B's Docker branch until T898, which
# meant a Docker-less run silently stopped covering publish-windows-release.ps1
# while the guard row that watches it went on being stamped.
Assert "A19 on-box script asks for the FILEVERSION rule instead of restating it" ($ps1 -match '--print-file-version')

# ============================================================================
"== B: packaging (the artifacts are really built and read back)"
# ============================================================================
$repoUnix = $Repo -replace '\\', '/'
$dockerUp = $false
$prev = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
docker info *> $null
$dockerUp = ($LASTEXITCODE -eq 0)
if ($dockerUp) {
    # `:latest` explicitly: docker 29.x stopped defaulting the tag for
    # `image inspect` (it still does for `run`), so the bare name reports the
    # image missing on a box that has it - which under -RequireDocker scores a
    # RED B1 instead of running the check. Measured 2026-08-21 on docker 29.7.2.
    docker image inspect msitools-local:latest *> $null
    $imageUp = ($LASTEXITCODE -eq 0)
} else { $imageUp = $false }
$ErrorActionPreference = $prev

# -- B1: the MSI half. wixl/msitools is Linux-only tooling, so this one
# genuinely needs Docker and the msitools-local image, and SKIPs without them.
if (-not $dockerUp) {
    Skip "B1 FILEVERSION single source" 'Docker is not running'
} elseif (-not $imageUp) {
    Skip "B1 FILEVERSION single source" 'msitools-local image missing'
} else {
    # The yy.m.d.NN rule has ONE live definition. The on-box script used to
    # restate it in PowerShell; four private copies of a shared datum is how
    # T257's rounding bug survived four scripts.
    $printed = (docker run --rm -v "${repoUnix}:/repo" -w /repo msitools-local `
            bash dist/windows-installer/build-msi.sh --print-file-version --build-num 7 |
        Select-Object -Last 1).Trim()
    $expect = "{0}.{1}.{2}.7" -f [int](Get-Date -Format yy), [int](Get-Date -Format MM), [int](Get-Date -Format dd)
    AssertEq "B1 FILEVERSION single source" $expect $printed
}

# -- B2-B4: the portable ZIP half. This needs bash + python3 and NOTHING else
# (build-portable-zip.sh says so in its own header, so it runs the same on a CI
# runner, on macOS and inside the msitools image) - yet until T1052 it was
# nested inside the Docker branch above, so on this box, where Docker is
# deliberately never started, the only check that reads a real artifact back
# was permanently SKIPped. That is how both artifacts shipped for months
# without ghoztty.com and nothing went red. Git Bash is the local runner;
# Docker is the fallback; a SKIP now means neither exists.
function Get-BashPath {
    foreach ($p in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $cand = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $null
}
# The stock Windows `python3` is the Microsoft Store alias, which prints an ad
# and exits non-zero; the real interpreter here is usually named `python`. A
# one-line shim on PATH lets the unmodified build script run rather than
# teaching it about this box.
function ConvertTo-MsysPath([string]$Path) {
    # D:\a\b -> /d/a/b, which is what a Git Bash PATH entry and an exec target
    # both need. cygpath would do it, but it is one more process to find.
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLower() + $Matches[2] }
    return $p
}
function New-Python3Shim([string]$WorkDir) {
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $py) { return $null }
    $shimDir = Join-Path $WorkDir 'shim'
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
    $body = "#!/bin/sh`nexec `"" + (ConvertTo-MsysPath $py.Source) + "`" `"`$@`"`n"
    [IO.File]::WriteAllText((Join-Path $shimDir 'python3'), $body, (New-Object Text.UTF8Encoding $false))
    return $shimDir
}

$zipRel = "zig-out/test-portable-$PID.zip"
$zipPath = Join-Path $Repo ("zig-out\test-portable-$PID.zip")
$work = Join-Path ([IO.Path]::GetTempPath()) "release-artifacts-$PID"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$builtZip = $false
$zipWhy = ''
$bash = Get-BashPath
if (-not (Test-Path -LiteralPath (Join-Path $Repo 'zig-out\bin\ghoztty.exe'))) {
    $zipWhy = 'zig-out/bin/ghoztty.exe missing (build first)'
} elseif ($bash) {
    $shim = New-Python3Shim $work
    $prefix = ''
    if ($shim) { $prefix = 'export PATH="' + (ConvertTo-MsysPath $shim) + ':$PATH"; ' }
    $cmd = $prefix + "cd '$repoUnix' && bash dist/windows-installer/build-portable-zip.sh --semver 9.9.9 --out '$zipRel'"
    $log = Join-Path $work 'zip-build.log'
    & $bash -c $cmd *> $log
    $builtZip = (Test-Path -LiteralPath $zipPath)
    if (-not $builtZip) { $zipWhy = "local build failed, see $log" }
} elseif ($imageUp) {
    docker run --rm -v "${repoUnix}:/repo" -w /repo msitools-local `
        bash dist/windows-installer/build-portable-zip.sh --semver 9.9.9 `
        --out $zipRel *> $null
    $builtZip = (Test-Path -LiteralPath $zipPath)
    if (-not $builtZip) { $zipWhy = 'docker build produced no ZIP' }
} else {
    $zipWhy = 'no Git Bash and no msitools-local image'
}

if (-not $builtZip) {
    Skip "B2 portable ZIP layout" $zipWhy
    Skip "B4 portable ZIP console twin is console-subsystem" $zipWhy
} else {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $names = @($za.Entries | ForEach-Object { $_.FullName })
    # The twin is only worth shipping if it IS the console flip: a plain copy
    # of the GUI exe under a .com name is worse than nothing, because PATHEXT
    # prefers it and the shell still will not wait for it (T245/T1052).
    $comEntry = $za.Entries | Where-Object { $_.FullName -eq 'Ghoztty/ghoztty.com' }
    $comOut = Join-Path $work 'ghoztty.com'
    if ($comEntry) { [IO.Compression.ZipFileExtensions]::ExtractToFile($comEntry, $comOut, $true) }
    $za.Dispose()
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    foreach ($need in @('Ghoztty/ghoztty.exe', 'Ghoztty/ghoztty.com', 'Ghoztty/ghoztty-agent.exe',
            'Ghoztty/share/terminfo/ghostty.terminfo', 'Ghoztty/READ-ME-FIRST.txt')) {
        Assert "B2 portable ZIP has $need" ($names -contains $need)
    }
    $roots = @($names | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    AssertEq "B3 single Ghoztty/ root" 'Ghoztty' ($roots -join ',')

    # 3 = console. ghoztty.exe's own subsystem is deliberately NOT asserted
    # here: it is 2 for a release build and 3 for the Debug build this box is
    # required to keep in zig-out, so it says nothing about packaging.
    . (Join-Path $Repo 'scripts\delivery-manifest.ps1')
    if (Test-Path -LiteralPath $comOut) {
        AssertEq "B4 portable ZIP console twin is console-subsystem" 3 (Get-PeSubsystem $comOut)
    } else {
        Assert "B4 portable ZIP console twin is console-subsystem" $false
    }
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

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
"== F: a published build can sign in (T795, pure)"
# ============================================================================
# The macOS job has baked the public Google OAuth client id from a repository
# secret since T93. The Windows job never passed one, and the CI runner has no
# git-ignored google-client-id.txt to fall back to - so every published MSI and
# portable ZIP shipped with relay sign-in UNAVAILABLE while the DMG built from
# the same tag worked. Nothing could see it: the id is build configuration, so a
# green release and a correct release looked identical.
$macBuild = [regex]::Match($macWf, '(?ms)^      - name: Build macOS app.*?(?=^      - name: )')
$winBuild = [regex]::Match($wf, '(?ms)^      - name: Build Windows artifacts.*?(?=^      - name: )')
Assert "F1 the macOS job still bakes the client id (the standard being matched)" `
    ($macBuild.Success -and $macBuild.Value -match '-Dgoogle-client-id')
Assert "F2 the Windows build step takes the client id from a secret" `
    ($winBuild.Success -and $winBuild.Value -match 'GOOGLE_CLIENT_ID:\s*\$\{\{\s*secrets\.GOOGLE_CLIENT_ID\s*\}\}')
# The SAME secret on both seats, by name. Two clients baked with two ids sign in
# to two Google projects, which is a divergence no test of either seat alone can
# see (CLAUDE.md: the CLI/feature surface is identical on both platforms).
$macSecret = [regex]::Match($macBuild.Value, 'GOOGLE_CLIENT_ID:\s*\$\{\{\s*secrets\.(\w+)\s*\}\}')
$winSecret = [regex]::Match($winBuild.Value, 'GOOGLE_CLIENT_ID:\s*\$\{\{\s*secrets\.(\w+)\s*\}\}')
Assert "F3 both seats bake the same repository secret" `
    ($macSecret.Success -and $winSecret.Success -and
     $macSecret.Groups[1].Value -eq $winSecret.Groups[1].Value)
Assert "F4 the shared artifact script passes it to zig build" `
    ($shared -match '-Dgoogle-client-id=\$GOOGLE_CLIENT_ID')
# Load-bearing: an explicit `-Dgoogle-client-id=""` SATISFIES the build option
# and short-circuits src/build/Config.zig's fallback to a git-ignored
# google-client-id.txt, which is how an on-box release build gets one (D72). So
# the flag must be conditional, not always-present-and-sometimes-empty.
Assert "F5 and only when the environment actually has one" `
    ($shared -match '(?m)^\s*if \[\[ -n "\$\{GOOGLE_CLIENT_ID:-\}" \]\]; then')
Assert "F6 a build with no id says so instead of shipping quietly" `
    ($shared -match 'sign-in unavailable')
# The OBSERVABLE half of T795 - the version report printing the bake, and the
# delivery reading it back per location - is pinned where it belongs and against
# real binaries rather than by regex: arms A36-A48/B1b of upgrade-staleness.ps1
# and section F of deliver-windows-build.ps1. (Deliberately not spelled with the
# literal verb: isolation-meta.ps1 scans comments too, and a static harness that
# names one reads as a script that drives the CLI without a private endpoint.)

# ============================================================================
if ($Full) {
    "== D: the on-box publish, end to end (-DryRun)"
    # ============================================================================
    $log = Join-Path $env:TEMP "ghoztty-release-artifacts-$PID.log"
    # Stringified into the log rather than `*> $log` (T883): D2-D6 below are
    # text oracles, and a PowerShell file redirection formats the child's
    # merged streams through the host on the way to disk - wrapped to the
    # buffer width, or blank in a host that cannot format at all.
    powershell -NoProfile -File (Join-Path $Repo 'scripts\publish-windows-release.ps1') `
        -DryRun -BuildNum 99 2>&1 | ForEach-Object { $_.ToString() } |
        Set-Content -LiteralPath $log -Encoding utf8
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
# stands?". Red leaves both stamps alone: red stays due.
#
# THREE STAMPS, THREE BARS (T898, split by T1052). One bar for all of them is
# what left this harness's guard permanently due on a box where Docker is
# deliberately kept down -- an edit to fork-ci.yml could not be cleared by any
# run, twelve turns filed a duplicate task about it, and every commit in
# between used `-NoGuardDue`. Each row is stamped by the evidence that actually
# covers its files, and by nothing weaker.
#
#   release-artifacts (wiring)     stamped by any run with zero FAILURES.
#     Sections A, C, E and F prove the workflows, the shared artifact and
#     msitools scripts, the on-box publish script and this harness end to end,
#     and not one of them touches Docker. A skipped section B says nothing
#     about them.
#   release-artifacts-zip          stamped when section B actually BUILT a ZIP
#     and read its entry set back -- which needs bash + python3 and no Docker,
#     so it happens on any box with git installed. This is the row that would
#     have caught a payload missing ghoztty.com; while it was welded to the
#     Docker bar below, nothing on this box could go red over it (T1052).
#   release-artifacts-packaging    stamped only by a run with zero skips too.
#     Its file (build-msi.sh) is only really proved by section B compiling it
#     under the msitools-local image, so a Docker-less run must not vouch for
#     it. That row staying due while Docker is down is the honest answer, not a
#     wedge: it names one file nobody edits often.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard release-artifacts -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    if ($builtZip) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard release-artifacts-zip -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    } else {
        "  ZIP stamp NOT updated (section B could not build a portable ZIP: $zipWhy)"
    }
    if ($script:skipped -eq 0) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard release-artifacts-packaging -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    } else {
        "  packaging stamp NOT updated ($($script:skipped) section(s) skipped; re-run with Docker up)"
    }
}

""
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) { "ALL PASS ($($script:skipped) skipped)" } else { "ALL PASS" }
} else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
