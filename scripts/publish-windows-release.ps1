# publish-windows-release.ps1 -- build + publish a Windows release (T24).
#
# NOTE (T38): the NORMAL path is now CI. Pushing a vX.Y.Z tag runs
# .github/workflows/release-windows.yml, which builds the same artifacts and
# publishes the same win-v<Version> release, so every macOS release ships
# the Windows build with it. This script is the on-box manual path -- a
# Windows-only publish between releases, or a re-publish when CI is
# unavailable. Both call the SAME
# dist/windows-installer/build-release-artifacts.sh, so they cannot drift.
#
# Publishes the Windows terminal build as a GitHub release on
# dzearing/ghoztty tagged win-v<Version> with the MSI + portable ZIP
# attached. Windows releases live beside the Mac vX.Y.Z releases in the same
# repo; they are created with --latest=false so the Mac releases/latest flow
# (and the Mac update path) is untouched. The in-app update check
# (src/apprt/win32/App.zig + update_check.zig) scans the releases list for
# the newest win-v tag, so publishing here is what makes installed builds
# offer the update.
#
# Flow (on-box, Windows):
#   1. Native zig build: ReleaseFast x86_64-windows-gnu win32 apprt, stamped
#      with -Dversion-string=<Version>+<short-hash> (exe semver == tag
#      semver, so the update compare is exact), -Dwindows-update-check=true
#      (only channel builds phone home), and a strictly-increasing
#      -Dwindows-file-version (MSI upgrade ordering, T23).
#   2. dist/windows-installer/build-release-artifacts.sh --skip-build under
#      Docker (msitools-local image: debian + msitools + wixl + python3 +
#      git; wixl does not run on Windows) -> MSI + portable ZIP.
#   3. gh release create win-v<Version> --latest=false + both uploads.
#
# The tagged commit must already be pushed (run this AFTER the task-boundary
# push). Requires: zig on PATH, Docker Desktop installed, gh authenticated.
#
# Usage:
#   scripts/publish-windows-release.ps1 [-Version 1.4.1] [-BuildNum 1]
#       [-NotesFile <path>] [-SkipBuild] [-DryRun]
#
#   -Version    defaults to the newest vX.Y.Z tag in the repo, so a Windows
#               publish tracks the macOS release version by default (T38:
#               "same version, one process").
#   -SkipBuild  reuse zig-out\bin\ghoztty.exe + zig-out\share (must already
#               carry the matching version stamp -- the script verifies).
#   -DryRun     build everything, skip the gh release create/upload.
param(
    [string]$Version = '',
    [int]$BuildNum = 1,
    [string]$NotesFile = '',
    [switch]$SkipBuild,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if (-not $Version) {
    # Track the macOS release version by default (T38). `git tag` sorts
    # lexically, so ask git for version ordering explicitly.
    # NOT `| Select-Object -First 1`: -First tears the pipeline down under a
    # still-running native command. Take the element instead.
    $tags = @(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname)
    $Version = if ($tags.Count) { $tags[0] -replace '^v', '' } else { '' }
    if (-not $Version) { throw "no vX.Y.Z tag found -- pass -Version explicitly" }
    Write-Host "-Version defaulted to the newest macOS release tag: $Version"
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be X.Y.Z (got '$Version')"
}

$hash = (git rev-parse --short HEAD).Trim()
$tag = "win-v$Version"
$stamp = "$(Get-Date -Format yyyyMMdd)-$hash"
$msi = Join-Path $repo "zig-out\Ghoztty-$Version-x64.msi"
$zip = Join-Path $repo "zig-out\Ghoztty-portable-$Version-x64.zip"

Write-Host "== publish $tag (commit $hash, stamp $stamp) =="

# -- preflight ----------------------------------------------------------
# The release tag points at HEAD; it must exist on the remote.
$remoteHas = git branch -r --contains HEAD 2>$null
if (-not $remoteHas) {
    throw "HEAD is not on any remote branch -- push first (the release tag must point at a pushed commit)"
}
# Probe natives that talk on stderr with EAP relaxed: under Stop, PS 5.1
# wraps their stderr in a terminating NativeCommandError.
function Invoke-Probe([scriptblock]$block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { & $block *> $null } finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}
if ((Invoke-Probe { gh release view $tag --repo dzearing/ghoztty --json tagName }) -eq 0) {
    throw "release $tag already exists -- bump -Version"
}

# Docker is needed for both the FILEVERSION query and the packaging, so make
# it ready up front rather than halfway through a 10-minute publish.
function Assert-DockerReady {
    if ((Invoke-Probe { docker info }) -eq 0) { return }
    Write-Host '== starting Docker Desktop =='
    Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe' | Out-Null
    $deadline = (Get-Date).AddSeconds(120)
    $up = 1
    do {
        Start-Sleep -Seconds 5
        $up = Invoke-Probe { docker info }
    } until ($up -eq 0 -or (Get-Date) -gt $deadline)
    if ($up -ne 0) { throw 'Docker did not become ready in 120s' }
}
$repoUnix = $repo -replace '\\', '/'
function Invoke-InImage {
    # NOT $Args: that shadows the automatic variable of the same name.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$DockerArgs)
    docker run --rm -v "${repoUnix}:/repo" -w /repo msitools-local @DockerArgs
}

Assert-DockerReady

# -- 1. native zig build ------------------------------------------------
# The FILEVERSION rule lives in build-msi.sh (--print-file-version); asking
# for it keeps this script from carrying a second copy of the formula that
# could drift from the one the MSI is stamped with.
$fileVer = (Invoke-InImage bash dist/windows-installer/build-msi.sh `
        --print-file-version --build-num $BuildNum | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or $fileVer -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "could not read FILEVERSION from build-msi.sh (got '$fileVer')"
}
Write-Host "FILEVERSION $fileVer"

if (-not $SkipBuild) {
    Write-Host "== zig build (ReleaseFast, x86_64-windows-gnu, semver $Version) =="
    if (-not $env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-cache' }
    # The default install also produces zig-out\bin\ghoztty-agent.exe on
    # Windows (T89h); -Dagent-semver stamps its VERSIONINFO with the release
    # semver so Explorer/Details matches the tag. -Dstrip=false keeps the
    # shipped build's crash dumps debuggable (docs/claude/build.md); the CI path in
    # build-release-artifacts.sh passes the same set.
    zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast `
        -Dstrip=false `
        "-Dwindows-file-version=$fileVer" `
        "-Dversion-string=$Version+$hash" `
        "-Dagent-semver=$Version" `
        "-Dwindows-update-check=true"
    if ($LASTEXITCODE -ne 0) { throw "zig build failed" }
}

# Verify the exe actually carries the release semver (catches a stale
# zig-out under -SkipBuild and any stamping regression).
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { throw "$exe missing" }
# Session persistence needs the agent sibling in every shipped layout (T89h);
# build-msi.sh also hard-requires it, but fail here first with a clear message.
$agentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
# ASCII only: this file has no BOM, so PS 5.1 reads it as ANSI. A UTF-8 em
# dash decodes to ...94 = a cp1252 smart quote, which CLOSES the string and
# makes the whole script unparseable under `powershell -File` (it was, from
# the day it was written until T38).
if (-not (Test-Path $agentExe)) { throw "$agentExe missing -- the release must carry the session-persistence agent (T89h)" }
$verOut = Join-Path $env:TEMP 'ghoztty-publish-version.txt'
$p = Start-Process $exe -ArgumentList '+version' -RedirectStandardOutput $verOut -NoNewWindow -PassThru
if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; throw '+version hung' }
$verText = [IO.File]::ReadAllText($verOut)
if ($verText -notmatch [regex]::Escape("$Version+$hash")) {
    throw "built exe does not report $Version+$hash -- got:`n$verText"
}
Write-Host "exe reports $Version+$hash"

# -- 2. MSI + portable ZIP under Docker ----------------------------------
# Same script CI runs (T38), so the artifact SET is defined once. wixl does
# not run on Windows, hence the msitools-local image (debian + msitools +
# wixl + python3 + git).
Write-Host '== build MSI + portable ZIP (Docker msitools-local) =='
Invoke-InImage bash dist/windows-installer/build-release-artifacts.sh --skip-build `
    --semver $Version --build-num $BuildNum --stamp $stamp
if ($LASTEXITCODE -ne 0) { throw 'build-release-artifacts.sh failed' }

foreach ($artifact in @($msi, $zip)) {
    if (-not (Test-Path $artifact)) { throw "$artifact missing after build" }
    $mb = [math]::Round((Get-Item $artifact).Length / 1MB, 1)
    Write-Host "artifact: $artifact (${mb} MB)"
}

# -- 3. GitHub release ----------------------------------------------------
if ($DryRun) {
    Write-Host "== DRY RUN: skipping gh release create $tag =="
    exit 0
}
$notesArgs = @()
if ($NotesFile) {
    $notesArgs = @('--notes-file', $NotesFile)
} else {
    $notes = @"
Windows build of Ghoztty $Version (commit $hash).

**Install:** download ``Ghoztty-$Version-x64.msi`` and run it (per-user, no
admin). Upgrades an existing install in place -- close Ghoztty first.

**Portable:** ``Ghoztty-portable-$Version-x64.zip`` needs no installer --
unzip it and run ``Ghoztty\ghoztty.exe``.

Installed builds check this channel and show a notification when a newer
``win-v*`` release appears (notify-only; nothing downloads automatically).
"@
    $notesPath = Join-Path $env:TEMP 'ghoztty-win-release-notes.md'
    [IO.File]::WriteAllText($notesPath, $notes)
    $notesArgs = @('--notes-file', $notesPath)
}
Write-Host "== gh release create $tag =="
gh release create $tag --repo dzearing/ghoztty --target (git rev-parse HEAD).Trim() `
    --title "Ghoztty for Windows v$Version" --latest=false @notesArgs $msi $zip
if ($LASTEXITCODE -ne 0) { throw 'gh release create failed' }
Write-Host "== published https://github.com/dzearing/ghoztty/releases/tag/$tag =="
