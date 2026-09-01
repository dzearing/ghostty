<#
.SYNOPSIS
  Fails when a repository text file contains a control character that no text
  file should ever hold (T1231).

.DESCRIPTION
  On 2026-09-01 fifteen tracked files were found carrying real control
  characters where a Windows path had been written with a backslash escape:
  a tool interpreted `\a`, `\b` and `\f` and wrote 0x07, 0x08 and 0x0c into the
  file. `zig-out\bin` became `zig-out<BS>in`; `scripts\floor-lane.ps1` became
  `scripts<FF>loor-lane.ps1`; `src\apprt\win32\install_prepare.zig` inside
  scripts\guard-due.ps1's coverage table became `src<BEL>pprt\...`, so that
  guard row could never resolve the file it claimed to cover.

  This is the exact shape a check should own. The damage is trivially
  detectable and IMPOSSIBLE to see by eye - a reader sees the two halves of the
  path run together and assumes a typo - and in a live path string it is a path
  that quietly does not exist, which nothing reports as anything but not-found.

  What counts as damage: any byte below 0x20 other than tab (0x09), line feed
  (0x0a) and carriage return (0x0d), plus DEL (0x7f).

  Scope: TRACKED files (git ls-files) whose extension is in the allowlist
  below. The allowlist rather than "every text file" is deliberate - the
  libghostty fuzz corpora under test/fuzz-libghostty/corpus/ are extensionless
  fixtures whose whole point is to hold control bytes, and a check that has to
  be argued with about its own exclusions is a check people learn to skip.

.PARAMETER Staged
  Scan the files staged for commit instead of the whole tracked tree. This is
  what the pre-commit hook asks for: it is bounded by the commit rather than the
  repo, so it costs nothing on a two-file commit.

.PARAMETER Paths
  Scan exactly these paths (relative to the repo root, or absolute). Used by
  the acceptance harness to point the scanner at a fixture.

.PARAMETER Repo
  Repository root. Defaults to the parent of this script's directory.

.EXAMPLE
  powershell -NoProfile -File scripts\control-char-scan.ps1
  powershell -NoProfile -File scripts\control-char-scan.ps1 -Staged
  powershell -NoProfile -File scripts\control-char-scan.ps1 -Paths temp\fixture\a.md

.OUTPUTS
  Exit 0 = clean. Exit 1 = at least one control character found (each one is
  printed as file:line:col with the offending line rendered so the invisible
  byte becomes visible). Exit 2 = the scan could not run.
#>
[CmdletBinding()]
param(
    [switch]$Staged,
    [string[]]$Paths,
    [string]$Repo,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Repo)) {
    Write-Host "CONTROL CHAR SCAN: repo not found: $Repo"
    exit 2
}
# Normalize before anything compares against it: the git hook hands this a
# forward-slash path (`D:/git/ghoztty`) and every path built below uses
# backslashes, so without this a finding would be reported as an absolute path
# instead of the repo-relative one a reader can act on.
$Repo = (Resolve-Path -LiteralPath $Repo).ProviderPath

# Extensions whose files are prose or code, and therefore have no business
# holding a control character. Keep this tight: every extension added here is a
# promise that no legitimate file of that kind carries one.
$AllowedExtensions = @(
    '.md', '.ps1', '.psm1', '.psd1', '.zig', '.json', '.sh', '.bash',
    '.yml', '.yaml', '.txt', '.bat', '.cmd', '.toml', '.css', '.js', '.html',
    '.swift', '.c', '.h', '.py'
)

# tab, LF, CR are the three control characters a text file legitimately holds.
$bad = [char[]](@(0..8) + @(11, 12) + @(14..31) + @(127) | ForEach-Object { [char]$_ })

function Get-ScanTargets {
    if ($Paths) {
        return @($Paths | ForEach-Object {
            if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Repo $_ }
        })
    }

    Push-Location $Repo
    try {
        if ($Staged) {
            # Added/copied/modified/renamed only: a deletion has no content to
            # scan and would otherwise report as an unreadable path.
            $listed = & git diff --cached --name-only --diff-filter=ACMR 2>$null
        } else {
            $listed = & git ls-files 2>$null
        }
        if ($LASTEXITCODE -ne 0) { throw "git listing failed in $Repo" }
    } finally {
        Pop-Location
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $listed) {
        if (-not $rel) { continue }
        $ext = [System.IO.Path]::GetExtension($rel)
        if ($AllowedExtensions -notcontains $ext) { continue }
        $out.Add((Join-Path $Repo $rel))
    }
    return $out
}

try {
    $targets = @(Get-ScanTargets)
} catch {
    Write-Host ("CONTROL CHAR SCAN: could not enumerate files - {0}" -f $_.Exception.Message)
    exit 2
}

$findings = New-Object System.Collections.Generic.List[object]

foreach ($path in $targets) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try {
        $text = [System.IO.File]::ReadAllText($path)
    } catch {
        continue
    }
    # IndexOfAny is a native scan, so the common case (no hit) costs one pass
    # over the bytes and nothing else. Only a file that HAS a hit pays for the
    # line/column arithmetic below.
    if ($text.IndexOfAny($bad) -lt 0) { continue }

    $rel = $path
    if ($path.StartsWith($Repo, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $path.Substring($Repo.Length).TrimStart('\', '/')
    }

    $line = 1
    $col = 1
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($ch -eq "`n") { $line++; $col = 1; continue }
        if ($bad -contains $ch) {
            $findings.Add([pscustomobject]@{
                File = $rel
                Line = $line
                Col  = $col
                Code = '0x{0:x2}' -f [int]$ch
            })
        }
        $col++
    }
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host ("CONTROL CHAR SCAN CLEAN: {0} file(s)" -f $targets.Count)
    }
    exit 0
}

Write-Host ("CONTROL CHARACTERS IN {0} FILE(S) - a text file must not hold one (T1231):" -f (@($findings | Select-Object -ExpandProperty File -Unique)).Count)
foreach ($f in $findings) {
    Write-Host ("  {0}:{1}:{2}  {3}" -f $f.File, $f.Line, $f.Col, $f.Code)
}
Write-Host ""
Write-Host "  These are almost always a backslash escape that some tool interpreted:"
Write-Host "  0x07 was '\a', 0x08 was '\b', 0x0c was '\f' - so 'zig-out\bin' is now"
Write-Host "  'zig-out<0x08>in'. Restore the backslash the path was MEANT to have"
Write-Host "  rather than deleting the byte, and never rewrite the whole file from"
Write-Host "  PowerShell to do it (that re-encodes it); patch the one line."
exit 1
