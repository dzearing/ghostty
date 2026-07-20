# publish-windows-release.ps1 -- build + publish a Windows release (T24).
#
# Publishes the Windows terminal build as a GitHub release on
# dzearing/ghoztty tagged win-v<Version> with the MSI attached. Windows
# releases live beside the Mac vX.Y.Z releases in the same repo; they are
# created with --latest=false so the Mac releases/latest flow (and the Mac
# update path) is untouched. The in-app update check
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
#   2. dist/windows-installer/build-msi.sh --skip-build under Docker
#      (msitools-local image: debian + msitools + wixl + python3 + git;
#      wixl does not run on Windows).
#   3. gh release create win-v<Version> --latest=false + MSI upload.
#
# The tagged commit must already be pushed (run this AFTER the task-boundary
# push). Requires: zig on PATH, Docker Desktop installed, gh authenticated.
#
# Usage:
#   scripts/publish-windows-release.ps1 -Version 1.4.1 [-BuildNum 1]
#       [-NotesFile <path>] [-SkipBuild] [-DryRun]
#
#   -SkipBuild  reuse zig-out\bin\ghoztty.exe + zig-out\share (must already
#               carry the matching version stamp -- the script verifies).
#   -DryRun     build everything, skip the gh release create/upload.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [int]$BuildNum = 1,
    [string]$NotesFile = '',
    [switch]$SkipBuild,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be X.Y.Z (got '$Version')"
}

Set-Location $repo
$hash = (git rev-parse --short HEAD).Trim()
$tag = "win-v$Version"
$stamp = "$(Get-Date -Format yyyyMMdd)-$hash"
$fileVer = "{0}.{1}.{2}.{3}" -f (Get-Date -Format yy), [int](Get-Date -Format MM), [int](Get-Date -Format dd), $BuildNum
$msi = Join-Path $repo "zig-out\Ghoztty-$Version-x64.msi"

Write-Host "== publish $tag (commit $hash, stamp $stamp, FILEVERSION $fileVer) =="

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

# -- 1. native zig build ------------------------------------------------
if (-not $SkipBuild) {
    Write-Host "== zig build (ReleaseFast, x86_64-windows-gnu, semver $Version) =="
    if (-not $env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-cache' }
    # The default install also produces zig-out\bin\ghoztty-agent.exe on
    # Windows (T89h); -Dagent-semver stamps its VERSIONINFO with the release
    # semver so Explorer/Details matches the tag.
    zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast `
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
if (-not (Test-Path $agentExe)) { throw "$agentExe missing — the release must carry the session-persistence agent (T89h)" }
$verOut = Join-Path $env:TEMP 'ghoztty-publish-version.txt'
$p = Start-Process $exe -ArgumentList '+version' -RedirectStandardOutput $verOut -NoNewWindow -PassThru
if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; throw '+version hung' }
$verText = [IO.File]::ReadAllText($verOut)
if ($verText -notmatch [regex]::Escape("$Version+$hash")) {
    throw "built exe does not report $Version+$hash -- got:`n$verText"
}
Write-Host "exe reports $Version+$hash"

# -- 2. MSI under Docker -------------------------------------------------
if (-not (Test-Path $msi) -or -not $SkipBuild) {
    if ((Invoke-Probe { docker info }) -ne 0) {
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
    Write-Host '== build MSI (Docker msitools-local) =='
    $repoUnix = $repo -replace '\\', '/'
    docker run --rm -v "${repoUnix}:/repo" -w /repo msitools-local `
        bash dist/windows-installer/build-msi.sh --skip-build `
        --semver $Version --build-num $BuildNum --version $stamp `
        --out "zig-out/Ghoztty-$Version-x64.msi"
    if ($LASTEXITCODE -ne 0) { throw 'build-msi.sh failed' }
}
if (-not (Test-Path $msi)) { throw "$msi missing after build" }
$msiMB = [math]::Round((Get-Item $msi).Length / 1MB, 1)
Write-Host "MSI: $msi (${msiMB} MB)"

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

Installed builds check this channel and show a notification when a newer
``win-v*`` release appears (notify-only; nothing downloads automatically).
"@
    $notesPath = Join-Path $env:TEMP 'ghoztty-win-release-notes.md'
    [IO.File]::WriteAllText($notesPath, $notes)
    $notesArgs = @('--notes-file', $notesPath)
}
Write-Host "== gh release create $tag =="
gh release create $tag --repo dzearing/ghoztty --target (git rev-parse HEAD).Trim() `
    --title "Ghoztty for Windows v$Version" --latest=false @notesArgs $msi
if ($LASTEXITCODE -ne 0) { throw 'gh release create failed' }
Write-Host "== published https://github.com/dzearing/ghoztty/releases/tag/$tag =="
