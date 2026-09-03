# publish-windows-tag.ps1 -- publish a Windows release by pushing its tag (T1292).
#
# THE PROBLEM THIS EXISTS FOR. The other publish path,
# scripts\publish-windows-release.ps1, builds the MSI on this box with wixl
# inside the msitools Docker image. wixl does not run on Windows, so that path
# needs Docker Desktop -- and Docker Desktop is deliberately kept DOWN on this
# machine (its WSL2 backend once took 28 GB and buried the box), which is why
# every script here says starting it is the user's call. The daily publish was
# wired to that path, so it asked every evening for a precondition it was never
# allowed to satisfy, logged a polite SKIP, and shipped nothing. Between
# 2026-08-31 and 2026-09-03 nineteen tasks closed and the user was still
# downloading win-v1.36.0.
#
# THE PATH THAT ALREADY WORKS. .github\workflows\release-windows.yml builds the
# same artifacts on ubuntu-latest, installing msitools from source -- no Docker,
# no local wixl -- and creates the win-v<Version> release with the MSI and the
# portable ZIP attached. It fires on a `win-v*` tag push. That is how
# win-v1.35.0 and win-v1.36.0 were published. So the publish this box can always
# do is: put the tag on the commit and push it.
#
# WHAT THIS DOES, therefore, is small on purpose: check that the version is
# publishable, tag HEAD, push the tag to ORIGIN, and print where to watch. The
# artifacts are CI's job. Nothing here builds, packages, or uploads, which is
# the entire reason it can run on a box with no Docker and no release
# toolchain.
#
#   scripts\publish-windows-tag.ps1 -Version 1.36.2
#   scripts\publish-windows-tag.ps1 -Version 1.36.2 -DryRun   # everything but the push
#
# It is interface-compatible with publish-windows-release.ps1 for the arguments
# daily-publish.ps1 passes (-Version, -DryRun), so the two are interchangeable
# behind that script's -PublishScript seam.
#
# ORIGIN, ALWAYS, BY NAME. This repo has `upstream` (ghostty-org/ghostty) as a
# remote and this branch's work is never offered to it (CLAUDE.md, D80). A bare
# `git push --tags` or a `gh` call without --repo can resolve there. Every
# command below names `origin` or `dzearing/ghoztty` explicitly.
#
# Acceptance: test\win32\daily-publish.ps1 (section H).
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Version,
    # Everything except the push: useful to see the refusals fire.
    [switch]$DryRun,
    [string]$Remote = 'origin',
    # Test seam. Empty = the repo this script lives in.
    [string]$Repo = ''
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
Set-Location $Repo

function Fail([string]$m) { Write-Host "publish-windows-tag: $m"; exit 1 }

if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "Version must be X.Y.Z (got '$Version')" }
$tag = "win-v$Version"

# Probe natives that talk on stderr without letting PS 5.1 turn their stderr
# into a terminating error.
function Invoke-Probe([scriptblock]$block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { & $block *> $null } finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}

$hash = (git rev-parse HEAD 2>$null)
if (-not $hash) { Fail 'could not read HEAD' }
$hash = $hash.Trim()
$short = (git rev-parse --short HEAD).Trim()

# The tag must point at a commit the remote already has: CI checks the tag out
# and builds it, and a tag on a local-only commit is a release of code nobody
# else can see. This is the same rule publish-windows-release.ps1 enforces.
$remoteHas = @(git branch -r --contains HEAD 2>$null)
if (-not $remoteHas.Count) {
    Fail "HEAD ($short) is not on any remote branch -- push the branch first; a release tag must point at a pushed commit"
}

# Refuse a tag that exists anywhere. Locally is the cheap check; on the remote
# is the one that matters, because a tag push that is not a fast-forward is
# rejected and would read as a mysterious publish failure.
if ((Invoke-Probe { git rev-parse -q --verify "refs/tags/$tag" }) -eq 0) {
    Fail "$tag already exists locally -- pick a higher version (daily-publish.ps1 derives one from the releases that exist)"
}
$remoteTag = @(git ls-remote --tags $Remote "refs/tags/$tag" 2>$null) | Where-Object { $_ }
if ($remoteTag.Count) {
    Fail "$tag already exists on $Remote -- pick a higher version"
}

Write-Host "== publish $tag by tag push (commit $short, remote $Remote) =="

if ($DryRun) {
    Write-Host "== DRY RUN: would tag $short as $tag and push it to $Remote =="
    exit 0
}

# Annotated, so the tag carries who/when and shows up in `git tag -n`.
git tag -a $tag -m "Ghoztty for Windows v$Version ($short)" $hash
if ($LASTEXITCODE -ne 0) { Fail "could not create tag $tag" }

git push $Remote "refs/tags/${tag}:refs/tags/${tag}"
if ($LASTEXITCODE -ne 0) {
    # Leave no local tag behind on a failed push: the next attempt would then
    # trip the "already exists locally" refusal above and never retry.
    git tag -d $tag | Out-Null
    Fail "could not push $tag to $Remote -- local tag removed so the next attempt can retry"
}

Write-Host "== pushed $tag ($short) to $Remote =="
Write-Host "   Release (Windows) builds the MSI + portable ZIP and creates the release:"
Write-Host "   https://github.com/dzearing/ghoztty/actions/workflows/release-windows.yml"
Write-Host "   https://github.com/dzearing/ghoztty/releases/tag/$tag"
exit 0
