<#
.SYNOPSIS
    Ask a second opinion whether a published Windows release is clean (T1312).

.DESCRIPTION
    Every malware verdict this project has ever had came from one engine:
    Windows Defender, on one machine, through a per-machine cloud call. A lone
    machine-learning hit with every other engine clean is what a false positive
    looks like; several independent detections mean the release is compromised
    and has to be pulled. Those two outcomes lead to opposite actions, so the
    question has to be asked of somebody other than Defender.

    This downloads the assets of a published release, hashes them, and asks
    VirusTotal BY HASH - no upload, so a binary that has already been scanned
    costs one request and nothing of ours leaves the box. The portable zip is
    expanded so the binaries the user actually runs (ghoztty.exe, ghoztty.com,
    ghoztty-agent.exe) are asked about by name rather than only as bytes inside
    an archive.

    The verdict is an exit code, because the point is that it can say no:

      0  CLEAN     every asset had a report and detections were within
                   -MaxDetections
      2  UNKNOWN   at least one asset has never been seen by any scanner - the
                   question was asked and the answer is "nobody knows", which
                   is NOT the same as clean
      3  DETECTED  detections above the threshold; the engines are named
      4  NOASK     no API key / no way to ask at all. Distinct from UNKNOWN on
                   purpose: one is an answer, the other is the absence of one
      1  ERROR     something broke

.PARAMETER Tag
    Release tag to verify (default: the newest win-v* release on -Repo).

.PARAMETER AssetDir
    Verify files already on disk instead of downloading a release. The harness
    uses this; so can a pre-publish check of zig-out.

.PARAMETER ResponseDir
    Test hatch: answer queries from <sha256>.json files in this directory
    instead of the network. A file may hold a VirusTotal /api/v3/files body, or
    {"__status": 404} for "never seen".

.EXAMPLE
    powershell -NoProfile -File scripts\verify-release-clean.ps1
    powershell -NoProfile -File scripts\verify-release-clean.ps1 -Tag win-v1.36.2 -Json
    powershell -NoProfile -File scripts\verify-release-clean.ps1 -HashesOnly
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Repo = 'dzearing/ghoztty',
    [string]$AssetDir,
    [string]$ApiKey,
    [string]$KeyFile,
    [int]$MaxDetections = 0,
    [switch]$HashesOnly,
    [string]$ResponseDir,
    [string]$WorkDir,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$EXIT_CLEAN = 0
$EXIT_ERROR = 1
$EXIT_UNKNOWN = 2
$EXIT_DETECTED = 3
$EXIT_NOASK = 4

function Write-Line([string]$Text) {
    if (-not $Quiet) { Write-Host $Text }
}

function Fail([string]$Text) {
    Write-Host "ERROR $Text" -ForegroundColor Red
    exit $EXIT_ERROR
}

# ---------------------------------------------------------------- key lookup
# Where the release secrets live. An env var wins so CI can pass one without
# writing it to disk; the file is the on-box convenience.
function Resolve-ApiKey {
    param([string]$Explicit, [string]$File)

    if ($Explicit) { return @{ key = $Explicit; source = 'parameter' } }
    if ($env:GHOZTTY_VT_API_KEY) {
        return @{ key = $env:GHOZTTY_VT_API_KEY; source = 'env:GHOZTTY_VT_API_KEY' }
    }
    $candidates = @()
    if ($File) { $candidates += $File }
    $candidates += (Join-Path $env:LOCALAPPDATA 'ghoztty\secrets\virustotal.key')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            $text = (Get-Content -LiteralPath $c -Raw).Trim()
            if ($text) { return @{ key = $text; source = $c } }
        }
    }
    return $null
}

# ------------------------------------------------------------------ vt query
function Get-VtReport {
    param([string]$Sha256, [string]$Key, [string]$CannedDir)

    if ($CannedDir) {
        $path = Join-Path $CannedDir ("{0}.json" -f $Sha256.ToLower())
        if (-not (Test-Path -LiteralPath $path)) {
            return @{ status = 404; body = $null }
        }
        $body = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $status = 200
        if ($body.PSObject.Properties.Name -contains '__status') { $status = [int]$body.__status }
        return @{ status = $status; body = $body }
    }

    $uri = "https://www.virustotal.com/api/v3/files/$Sha256"
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers @{ 'x-apikey' = $Key } `
            -UseBasicParsing -TimeoutSec 60
        return @{ status = 200; body = ($resp.Content | ConvertFrom-Json) }
    } catch {
        $code = 0
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
        }
        if ($code -eq 404) { return @{ status = 404; body = $null } }
        if ($code -eq 401 -or $code -eq 403) { return @{ status = $code; body = $null } }
        if ($code -eq 429) { return @{ status = 429; body = $null } }
        return @{ status = $code; body = $null; error = $_.Exception.Message }
    }
}

# Pull the engines that called it something out of a report body. VirusTotal
# reports every engine including the ones that timed out or did not run, and
# only 'malicious' and 'suspicious' are a claim about the file.
function Get-Detections {
    param($Body)

    $out = @()
    if (-not $Body) { return $out }
    if (-not ($Body.PSObject.Properties.Name -contains 'data')) { return $out }
    $attrs = $Body.data.attributes
    if (-not ($attrs.PSObject.Properties.Name -contains 'last_analysis_results')) { return $out }
    foreach ($p in $attrs.last_analysis_results.PSObject.Properties) {
        $cat = $p.Value.category
        if ($cat -eq 'malicious' -or $cat -eq 'suspicious') {
            $label = $p.Value.result
            if (-not $label) { $label = $cat }
            $out += [pscustomobject]@{ engine = $p.Name; category = $cat; result = $label }
        }
    }
    # No leading comma: the caller wraps in @(), and a `return ,` on top of that
    # hands back an array-of-array that reads as one detection named
    # "System.Object[]" (PS 5.1).
    return ($out | Sort-Object engine)
}

function Get-EngineCount {
    param($Body)
    if (-not $Body) { return 0 }
    if (-not ($Body.PSObject.Properties.Name -contains 'data')) { return 0 }
    $attrs = $Body.data.attributes
    if (-not ($attrs.PSObject.Properties.Name -contains 'last_analysis_results')) { return 0 }
    return @($attrs.last_analysis_results.PSObject.Properties).Count
}

# ------------------------------------------------------------ collect assets
$work = $WorkDir
if (-not $work) {
    $work = Join-Path $env:TEMP ("ghoztty-vt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
$createdWork = $false

$files = @()   # @{ name; path; kind }

# Resolve the key BEFORE downloading ninety megabytes we would then have no way
# to ask about. With -AssetDir the files are already here, so the run carries on
# far enough to print the hashes for a lookup by hand.
$keyInfo = $null
if (-not $ResponseDir -and -not $HashesOnly) {
    $keyInfo = Resolve-ApiKey -Explicit $ApiKey -File $KeyFile
    if (-not $keyInfo -and -not $AssetDir) {
        Write-Line "NOASK no VirusTotal API key."
        Write-Line "  set GHOZTTY_VT_API_KEY, or put the key in"
        Write-Line "  $(Join-Path $env:LOCALAPPDATA 'ghoztty\secrets\virustotal.key')"
        Write-Line "  (a free key at https://www.virustotal.com/gui/my-apikey is enough for hash lookups)"
        exit $EXIT_NOASK
    }
}

try {
    if ($AssetDir) {
        if (-not (Test-Path -LiteralPath $AssetDir)) { Fail "asset dir not found: $AssetDir" }
        $label = "dir:$AssetDir"
        foreach ($f in Get-ChildItem -LiteralPath $AssetDir -File) {
            $files += @{ name = $f.Name; path = $f.FullName; kind = 'asset' }
        }
    } else {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Write-Line "NOASK gh is not on PATH; cannot fetch release assets"
            exit $EXIT_NOASK
        }
        if (-not $Tag) {
            $list = & gh release list --repo $Repo --limit 30 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Line "NOASK could not list releases on $Repo (gh exit $LASTEXITCODE)"
                exit $EXIT_NOASK
            }
            foreach ($line in $list) {
                $m = [regex]::Match($line, '(?<tag>win-v[0-9][^\s]*)')
                if ($m.Success) { $Tag = $m.Groups['tag'].Value; break }
            }
            if (-not $Tag) { Fail "no win-v* release found on $Repo" }
        }
        $label = "$Repo@$Tag"
        if (-not (Test-Path -LiteralPath $work)) {
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            $createdWork = $true
        }
        Write-Line "downloading assets of $Tag ..."
        & gh release download $Tag --repo $Repo --dir $work --clobber 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Line "NOASK could not download assets of $Tag (gh exit $LASTEXITCODE)"
            exit $EXIT_NOASK
        }
        foreach ($f in Get-ChildItem -LiteralPath $work -File) {
            $files += @{ name = $f.Name; path = $f.FullName; kind = 'asset' }
        }
    }

    if ($files.Count -eq 0) { Fail "no files to verify ($label)" }

    # Expand the portable zip: the binaries inside it are what a user runs and
    # what an engine actually flags, so they get asked about by name.
    foreach ($f in @($files)) {
        if ($f.name -notmatch '\.zip$') { continue }
        $dest = Join-Path $work ("expanded-" + [IO.Path]::GetFileNameWithoutExtension($f.name))
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        if (-not $createdWork -and -not (Test-Path -LiteralPath $work)) { $createdWork = $true }
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($f.path, $dest)
        } catch {
            Write-Line "  warn: could not expand $($f.name): $($_.Exception.Message)"
            continue
        }
        # Only the things an engine can have an opinion about. `-Include`
        # without a wildcard in the path is silently ignored under PS 5.1, which
        # turned this into "hash all 300 files in the archive" and would have
        # spent a day's API quota on shell completions and JSON.
        $inners = Get-ChildItem -LiteralPath $dest -Recurse -File |
            Where-Object { $_.Extension -in @('.exe', '.com', '.dll', '.msi', '.sys') }
        foreach ($inner in $inners) {
            $files += @{ name = "$($f.name)!$($inner.Name)"; path = $inner.FullName; kind = 'inner' }
        }
    }

    # ------------------------------------------------------------------ hash
    $rows = @()
    foreach ($f in $files) {
        $sha = (Get-FileHash -LiteralPath $f.path -Algorithm SHA256).Hash.ToLower()
        $rows += [pscustomobject]@{
            name       = $f.name
            kind       = $f.kind
            sha256     = $sha
            status     = 'not-queried'
            engines    = 0
            detections = @()
        }
    }

    if ($HashesOnly) {
        Write-Line "release: $label"
        foreach ($r in $rows) { Write-Line ("  {0}  {1}" -f $r.sha256, $r.name) }
        if ($Json) { $rows | ConvertTo-Json -Depth 6 }
        exit $EXIT_CLEAN
    }

    # ----------------------------------------------------------------- query
    if (-not $ResponseDir) {
        if (-not $keyInfo) {
            Write-Line "NOASK no VirusTotal API key."
            Write-Line "  set GHOZTTY_VT_API_KEY, or put the key in"
            Write-Line "  $(Join-Path $env:LOCALAPPDATA 'ghoztty\secrets\virustotal.key')"
            Write-Line "  (a free key at https://www.virustotal.com/gui/my-apikey is enough for hash lookups)"
            Write-Line "  hashes to look up by hand:"
            foreach ($r in $rows) { Write-Line ("    {0}  {1}" -f $r.sha256, $r.name) }
            exit $EXIT_NOASK
        }
        Write-Line "key source: $($keyInfo.source)"
    }

    $key = $null
    if ($keyInfo) { $key = $keyInfo.key }

    $unknown = @()
    $detected = @()
    foreach ($r in $rows) {
        $rep = Get-VtReport -Sha256 $r.sha256 -Key $key -CannedDir $ResponseDir
        switch ($rep.status) {
            200 {
                $dets = @(Get-Detections -Body $rep.body)
                $r.engines = Get-EngineCount -Body $rep.body
                $r.detections = $dets
                if ($dets.Count -gt $MaxDetections) {
                    $r.status = 'detected'
                    $detected += $r
                } else {
                    $r.status = 'clean'
                }
            }
            404 {
                $r.status = 'never-scanned'
                $unknown += $r
            }
            401 { Write-Line "NOASK VirusTotal rejected the key (401)"; exit $EXIT_NOASK }
            403 { Write-Line "NOASK VirusTotal refused the request (403)"; exit $EXIT_NOASK }
            429 { Write-Line "NOASK VirusTotal rate limit reached (429); try again later"; exit $EXIT_NOASK }
            default {
                $msg = 'no response'
                if ($rep.PSObject.Properties.Name -contains 'error' -and $rep.error) { $msg = $rep.error }
                Write-Line "NOASK could not reach VirusTotal for $($r.name): $msg"
                exit $EXIT_NOASK
            }
        }
    }

    # ---------------------------------------------------------------- report
    Write-Line ""
    Write-Line "release: $label"
    foreach ($r in $rows) {
        $suffix = ''
        if ($r.status -eq 'clean') { $suffix = "0/$($r.engines) engines" }
        elseif ($r.status -eq 'detected') { $suffix = "$($r.detections.Count)/$($r.engines) engines" }
        Write-Line ("  {0,-14} {1} {2}" -f $r.status, $r.name, $suffix)
        foreach ($d in $r.detections) {
            Write-Line ("      {0}: {1} ({2})" -f $d.engine, $d.result, $d.category)
        }
    }
    Write-Line ""

    if ($Json) { $rows | ConvertTo-Json -Depth 6 }

    if ($detected.Count -gt 0) {
        $names = ($detected | ForEach-Object { $_.name }) -join ', '
        Write-Line "DETECTED $($detected.Count) asset(s) flagged above the threshold ($MaxDetections): $names"
        exit $EXIT_DETECTED
    }
    if ($unknown.Count -gt 0) {
        $names = ($unknown | ForEach-Object { $_.name }) -join ', '
        Write-Line "UNKNOWN no scanner has ever seen: $names"
        Write-Line "  this is not a clean verdict - nobody has looked."
        exit $EXIT_UNKNOWN
    }
    Write-Line "CLEAN every asset has a report and no engine flagged it."
    exit $EXIT_CLEAN
} finally {
    if ($createdWork -and -not $WorkDir -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
