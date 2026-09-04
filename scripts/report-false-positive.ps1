<#
.SYNOPSIS
    Build the developer false-positive submission packet for a published
    Windows release (T1313).

.DESCRIPTION
    Windows Defender quarantines our releases as Trojan:Script/Wacatac.C!ml
    (T1293). The remedy that reaches every machine is a software-developer
    false-positive report to Microsoft, and that report is about BYTES: a
    determination corrects the files it names and nothing else.

    Which is why the hand-written table in T1313 was the wrong shape. It named
    win-v1.36.2's two hashes, and by the time anyone read it the project had
    published four more releases -- three of them the same day. Filing from a
    stale table corrects a build nobody will download tomorrow.

    So the packet is GENERATED, from whichever release is current at the moment
    somebody sits down to file:

      * the release's own assets, downloaded and expanded, so the binaries a
        user actually runs are attached rather than the archive they arrived in
      * their SHA-256s, computed by verify-release-clean.ps1 -- the same code
        that asks VirusTotal about them, so the two can never disagree about
        what "the bytes" are
      * the build provenance a reviewer asks for: public source, the workflow
        run that produced these files on a clean hosted runner, the commit
      * the free-text paragraph, ready to paste

    The act of filing is NOT automated and cannot be: the portal requires
    signing in with a Microsoft account, and there is no public submission API
    without a tenant. That half stays the user's. This turns it into a
    two-minute form instead of a research task.

.PARAMETER Tag
    Release to build the packet for. Default: the newest win-v* release.

.PARAMETER OutDir
    Where the attachable files land. Default: %TEMP%\ghoztty-fp-<tag>. The
    files are KEPT (the portal wants uploads) and the path is printed.

.PARAMETER AssetDir
    Use files already on disk instead of downloading a release. Offline hatch
    and what the harness drives.

.PARAMETER Record
    Record a submission id (and optionally Microsoft's determination) into
    T1313 and T1293, so step 2 of the task has a home that is not somebody's
    memory. Nothing is downloaded in this mode.

.EXAMPLE
    powershell -NoProfile -File scripts\report-false-positive.ps1
    powershell -NoProfile -File scripts\report-false-positive.ps1 -Tag win-v1.36.2
    powershell -NoProfile -File scripts\report-false-positive.ps1 -Record `
        -SubmissionId 1234567890 -Tag win-v1.36.6
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Repo = 'dzearing/ghoztty',
    [string]$RepoRoot,
    [string]$OutDir,
    [string]$AssetDir,
    [string]$Detection = 'Trojan:Script/Wacatac.C!ml',
    [switch]$Record,
    [string]$SubmissionId,
    [string]$Determination,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$EXIT_OK = 0
$EXIT_ERROR = 1
$EXIT_NOASK = 4      # same vocabulary as verify-release-clean.ps1

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

function Write-Line([string]$Text = '') {
    if (-not $Quiet) { Write-Host $Text }
}

function Fail([string]$Text) {
    Write-Host "ERROR $Text" -ForegroundColor Red
    exit $EXIT_ERROR
}

function Noask([string]$Text) {
    Write-Line "NOASK $Text"
    exit $EXIT_NOASK
}

# The portal. `filesubmission` is the developer entry point and redirects to
# submit.microsoft.com; both are named so a redirect that moves does not leave
# the reader without an address.
$PORTAL = 'https://www.microsoft.com/en-us/wdsi/filesubmission'
$PORTAL_ALT = 'https://submit.microsoft.com/'

# ---------------------------------------------------------------- record mode
# Filing produces two facts that outlive the session: a submission id, and
# later a determination. Both belong in the tracker, and T1293 is the card that
# closes on the second one.
if ($Record) {
    if (-not $SubmissionId -and -not $Determination) {
        Fail "-Record needs -SubmissionId and/or -Determination"
    }
    $tasks = Join-Path $RepoRoot 'scripts\parity-tasks.ps1'
    if (-not (Test-Path -LiteralPath $tasks)) { Fail "not found: $tasks" }

    $parts = @()
    if ($SubmissionId) { $parts += "submission id $SubmissionId" }
    if ($Tag) { $parts += "for $Tag" }
    if ($Determination) { $parts += "determination: $Determination" }
    $text = "Microsoft false-positive report ($Detection): " + ($parts -join '; ') + "."

    foreach ($id in @('T1313', 'T1293')) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tasks note $id -Text $text |
            ForEach-Object { Write-Line "  $_" }
    }
    Write-Line "recorded on T1313 and T1293."
    exit $EXIT_OK
}

# ------------------------------------------------------------- resolve release
$publishedAt = ''
$commit = ''
$runUrl = ''
$downloadPage = ''

if (-not $AssetDir) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Noask "gh is not on PATH; cannot read the release. Use -AssetDir to build a packet from files on disk."
    }
    if (-not $Tag) {
        $list = & gh release list --repo $Repo --limit 30 2>$null
        if ($LASTEXITCODE -ne 0) { Noask "could not list releases on $Repo (gh exit $LASTEXITCODE)" }
        foreach ($line in $list) {
            $m = [regex]::Match($line, '(?<tag>win-v[0-9][^\s]*)')
            if ($m.Success) { $Tag = $m.Groups['tag'].Value; break }
        }
        if (-not $Tag) { Fail "no win-v* release found on $Repo" }
    }

    $viewRaw = & gh release view $Tag --repo $Repo --json tagName,publishedAt 2>$null
    if ($LASTEXITCODE -ne 0) { Noask "could not read release $Tag on $Repo" }
    try {
        $view = ($viewRaw | Out-String) | ConvertFrom-Json
        $publishedAt = [string]$view.publishedAt
    } catch { $publishedAt = '' }

    # The commit the tag points at, and the workflow run that built these
    # bytes. A hosted-runner build from public source is the single most useful
    # thing a reviewer can be handed, and it is the thing nobody remembers to
    # look up at form-filling time.
    $shaRaw = & gh api "repos/$Repo/git/ref/tags/$Tag" --jq '.object.sha' 2>$null
    if ($LASTEXITCODE -eq 0) { $commit = ([string]$shaRaw).Trim() }

    $runsRaw = & gh run list --repo $Repo --workflow release-windows.yml --limit 40 `
        --json databaseId,headBranch,conclusion,url 2>$null
    if ($LASTEXITCODE -eq 0 -and $runsRaw) {
        try {
            foreach ($r in (($runsRaw | Out-String) | ConvertFrom-Json)) {
                if ($r.headBranch -eq $Tag) { $runUrl = [string]$r.url; break }
            }
        } catch { $runUrl = '' }
    }
    $downloadPage = "https://github.com/$Repo/releases/tag/$Tag"
}

$label = if ($AssetDir) { "dir:$AssetDir" } else { $Tag }

# ------------------------------------------------------------------ the bytes
# verify-release-clean.ps1 owns "what are the files and what are their hashes":
# it downloads the assets, expands the portable zip so the binaries a user runs
# are named individually, and skips the ~300 completion/JSON files no engine
# has an opinion about. Calling it rather than re-implementing it is what keeps
# the packet and the scanner check talking about the same bytes.
$checker = Join-Path $RepoRoot 'scripts\verify-release-clean.ps1'
if (-not (Test-Path -LiteralPath $checker)) { Fail "not found: $checker" }

if (-not $OutDir) {
    $slug = if ($Tag) { $Tag } else { 'assets' }
    $OutDir = Join-Path $env:TEMP ("ghoztty-fp-" + $slug)
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$checkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker,
    '-HashesOnly', '-WorkDir', $OutDir)
if ($AssetDir) { $checkArgs += @('-AssetDir', $AssetDir) }
else { $checkArgs += @('-Tag', $Tag, '-Repo', $Repo) }

Write-Line "collecting $label ..."
$checkOut = & powershell @checkArgs 2>&1
$checkExit = $LASTEXITCODE
$checkText = ($checkOut | Out-String)
if ($checkExit -eq $EXIT_NOASK) {
    Write-Line ($checkText.Trim())
    Noask "could not collect the release assets"
}
if ($checkExit -ne 0) {
    Write-Line ($checkText.Trim())
    Fail "hashing failed (exit $checkExit)"
}

# `  <sha>  <name>` per file, exactly as -HashesOnly prints it.
$rows = @()
foreach ($line in ($checkText -split "`r?`n")) {
    $m = [regex]::Match($line, '^\s{2}(?<sha>[0-9a-f]{64})\s\s(?<name>.+?)\s*$')
    if (-not $m.Success) { continue }
    $rows += [pscustomobject]@{
        name   = $m.Groups['name'].Value
        sha256 = $m.Groups['sha'].Value
        path   = ''
    }
}
if ($rows.Count -eq 0) { Fail "no files hashed for $label" }

# Map each hash back to a file on disk, so the packet can say "attach THESE"
# rather than "attach the ones with these hashes". The zip's inner binaries
# live under expanded-*/ in the same work dir.
$onDisk = @{}
$scanRoots = @($OutDir)
# With -AssetDir the top-level assets never move into the work dir; only the
# zip's expanded contents do. Scan both or the packet has hashes it cannot
# point at a file for.
if ($AssetDir) { $scanRoots += $AssetDir }
foreach ($root in $scanRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.Extension -notin @('.exe', '.com', '.dll', '.msi', '.sys', '.zip')) { continue }
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        if (-not $onDisk.ContainsKey($h)) { $onDisk[$h] = $f.FullName }
    }
}
foreach ($r in $rows) {
    if ($onDisk.ContainsKey($r.sha256)) { $r.path = $onDisk[$r.sha256] }
}

# What actually gets attached. A submission is per-file, and the two the user's
# machine deleted are the two that matter; the agent rides along because it is
# in the same archive and has the same no-reputation problem.
$attachOrder = @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')
$attach = @()
foreach ($want in $attachOrder) {
    foreach ($r in $rows) {
        $leaf = ($r.name -split '!')[-1]
        if ($leaf -eq $want -and $r.path) { $attach += $r; break }
    }
}
if ($attach.Count -eq 0) {
    # No named binaries (a synthetic asset dir, or an archive shape that
    # changed): fall back to every executable we found rather than printing a
    # packet with nothing to upload.
    $attach = @($rows | Where-Object { $_.path -and $_.name -match '\.(exe|com)$' })
}

# ------------------------------------------------------------------ narrative
$sb = New-Object System.Text.StringBuilder
function Say([string]$t = '') { [void]$sb.AppendLine($t) }

Say "Ghoztty is an open-source terminal emulator for Windows. It is a fork of"
Say "Ghostty (https://github.com/ghostty-org/ghostty); our source is public at"
Say "https://github.com/$Repo."
Say ""
Say "Microsoft Defender detects the release binaries as $Detection and"
Say "quarantines them, deleting the files after installation. We believe this is"
Say "an incorrect detection. The behaviour a terminal emulator performs by"
Say "design -- creating pseudo-consoles, spawning shells, and reading and"
Say "writing their input and output -- is what we expect a machine-learning"
Say "heuristic to be reacting to."
Say ""
if ($runUrl) {
    Say "These exact files were built in public on a clean GitHub-hosted runner:"
    Say "  build:  $runUrl"
    if ($commit) { Say "  commit: $commit" }
    Say "  source: https://github.com/$Repo"
    Say "The workflow is .github/workflows/release-windows.yml in that repository."
} else {
    Say "The files are built from public source at https://github.com/$Repo by"
    Say "the release-windows.yml GitHub Actions workflow, on a hosted runner."
    if ($commit) { Say "Commit: $commit" }
}
Say ""
Say "The binaries are not code-signed. We understand an unsigned build carries"
Say "no reputation, and that is the most likely reason the heuristic fires."
Say ""
Say "Files, with SHA-256:"
foreach ($r in $attach) {
    Say ("  {0}  {1}" -f ($r.name -split '!')[-1], $r.sha256)
}
if ($downloadPage) {
    Say ""
    Say "Public download: $downloadPage"
}
$narrative = $sb.ToString().TrimEnd()

# -------------------------------------------------------------------- output
if ($Json) {
    [pscustomobject]@{
        tag         = $Tag
        repo        = $Repo
        commit      = $commit
        runUrl      = $runUrl
        publishedAt = $publishedAt
        portal      = $PORTAL
        detection   = $Detection
        outDir      = $OutDir
        attach      = @($attach | ForEach-Object { [pscustomobject]@{ name = ($_.name -split '!')[-1]; sha256 = $_.sha256; path = $_.path } })
        files       = @($rows | ForEach-Object { [pscustomobject]@{ name = $_.name; sha256 = $_.sha256 } })
        narrative   = $narrative
    } | ConvertTo-Json -Depth 6
}

Write-Line ""
Write-Line "FALSE-POSITIVE SUBMISSION PACKET  $label"
if ($publishedAt) { Write-Line "  published  $publishedAt" }
if ($commit) { Write-Line "  commit     $commit" }
if ($runUrl) { Write-Line "  built by   $runUrl" }
Write-Line ""
Write-Line "1. Open $PORTAL"
Write-Line "   (redirects to $PORTAL_ALT). Sign in with a Microsoft account and"
Write-Line "   choose SOFTWARE DEVELOPER -- the developer form is the one whose"
Write-Line "   determination applies to everyone, not just this machine."
Write-Line ""
Write-Line "2. Attach these files. They are already downloaded:"
foreach ($r in $attach) {
    Write-Line ("     {0}" -f $r.path)
    Write-Line ("       sha256 {0}" -f $r.sha256)
}
Write-Line ""
Write-Line "3. Answers:"
Write-Line "     Submission type ........ Software developer"
Write-Line "     Product ................ Microsoft Defender Antivirus"
Write-Line "     Detection name ......... $Detection"
Write-Line "     What are you reporting . Incorrect detection (false positive)"
Write-Line "     Support ticket ......... none"
Write-Line "     Definition version ..... read it on a machine that reproduces the"
Write-Line "                              detection: Get-MpComputerStatus |"
Write-Line "                              Select-Object AntivirusSignatureVersion"
Write-Line ""
Write-Line "4. Paste this into the additional-information box:"
Write-Line ""
foreach ($line in ($narrative -split "`r?`n")) { Write-Line "     $line" }
Write-Line ""
Write-Line "5. When it is submitted, record the id so it is not carried in"
Write-Line "   somebody's memory:"
Write-Line ""
Write-Line "     powershell -NoProfile -File scripts\report-false-positive.ps1 -Record ``"
Write-Line "         -SubmissionId <id> -Tag $Tag"
Write-Line ""
Write-Line "   and again with -Determination ""<what Microsoft concluded>"" when the"
Write-Line "   answer arrives. The determination is what closes T1293; submitting"
Write-Line "   is not."
Write-Line ""

$packetFile = Join-Path $OutDir 'submission-packet.txt'
$header = @()
$header += "FALSE-POSITIVE SUBMISSION PACKET  $label"
if ($publishedAt) { $header += "published: $publishedAt" }
if ($commit) { $header += "commit: $commit" }
if ($runUrl) { $header += "build: $runUrl" }
$header += "portal: $PORTAL"
$header += "detection: $Detection"
$header += ''
$header += 'attach:'
foreach ($r in $attach) { $header += ("  {0}  {1}" -f $r.sha256, $r.path) }
$header += ''
$header += 'additional information:'
$header += ''
($header + ($narrative -split "`r?`n")) -join "`r`n" |
    Set-Content -LiteralPath $packetFile -Encoding ASCII

Write-Line "packet: $packetFile"
Write-Line "files:  $OutDir"
exit $EXIT_OK
