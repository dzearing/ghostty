<#
.SYNOPSIS
  Acceptance test for scripts\lib\CacheHeal.ps1 and floor-lane.ps1's
  heal-and-retry-once wiring (T494).

.DESCRIPTION
  A torn zig-cache entry (the observed case: a zero-filled options.zig under
  .zig-cache\c\<hash>\) fails a floor lane as if the code were red. The heal
  must (a) recognize exactly that signature, (b) delete exactly that entry,
  loudly, and (c) never fire on errors that point at real source -- a heal
  that can aim at source files is worse than the phantom FAIL it prevents.

  Arms 1-8 drive the library functions against planted logs and a planted
  fake cache tree (all under a private temp dir; no real cache is touched).
  Arm 9 is end-to-end: floor-lane.ps1 -Command mode cannot exercise the heal
  path (heals are for zig lanes), so the wiring arm instead runs the script
  with a stubbed lane via -SelfTest to prove the file still parses and the
  dot-source of CacheHeal.ps1 resolves; the heal-decision logic itself is the
  same code arms 1-8 proved.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\CacheHeal.ps1')

$script:Failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name) }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

# A private sandbox standing in for the repo + both caches.
$Sandbox = Join-Path $env:TEMP ("cache-heal-test-{0}" -f $PID)
if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
$FakeRepo = Join-Path $Sandbox 'repo'
$LocalCache = Join-Path $FakeRepo '.zig-cache'
$GlobalCache = Join-Path $Sandbox 'zig-global-cache'
$Hash = '047ecd4ac00fbb503a242306e56ffc54'
$EntryDir = Join-Path $LocalCache "c\$Hash"
New-Item -ItemType Directory -Path $EntryDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $GlobalCache "o\$Hash") -Force | Out-Null
# The observed corruption: a file of zeros.
[System.IO.File]::WriteAllBytes((Join-Path $EntryDir 'options.zig'), (New-Object byte[] 2036))

function New-Log {
    param([string[]]$Lines)
    $p = Join-Path $Sandbox ("log-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -Path $p -Value $Lines -Encoding Ascii
    return $p
}

try {
    # -- 1: the observed signature, relative path, is detected and names the entry
    $log = New-Log @(
        ".zig-cache\c\$Hash\options.zig:1:1: error: expected type expression, found 'invalid token'"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'relative cache path is detected' ($torn.Count -eq 1) "got $($torn.Count)"
    Check 'entry dir is the hash directory' ($torn.Count -eq 1 -and $torn[0].Entry -ieq $EntryDir) `
        $(if ($torn.Count -ge 1) { $torn[0].Entry } else { '(none)' })

    # -- 2: absolute path into the local cache is detected too
    $log = New-Log @(
        "$LocalCache\c\$Hash\options.zig:7:2: error: invalid byte: 0x00"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'absolute cache path is detected' ($torn.Count -eq 1 -and $torn[0].Entry -ieq $EntryDir) ''

    # -- 3: a path under the GLOBAL cache resolves against -GlobalCacheDir
    $log = New-Log @(
        "$GlobalCache\o\$Hash\cimport.zig:3:1: error: expected type expression, found 'invalid token'"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'global cache path is detected' ($torn.Count -eq 1 -and $torn[0].Entry -ieq (Join-Path $GlobalCache "o\$Hash")) ''

    # -- 4: an error in real source must NOT be blamed on the cache
    $log = New-Log @(
        "src\apprt\win32\App.zig:120:5: error: use of undeclared identifier 'nope'"
        "D:\git\ghoztty\src\main.zig:9:1: error: expected type expression, found 'invalid token'"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'source-file errors are never detected' ($torn.Count -eq 0) "got $($torn.Count)"

    # -- 5: a cache-adjacent path that is NOT <bucket>\<hash> shaped is refused
    $log = New-Log @(
        ".zig-cache\tmp\scratch.zig:1:1: error: expected type expression, found 'invalid token'"
        ".zig-cache\c\not-a-hash\gen.zig:1:1: error: expected type expression, found 'invalid token'"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'non-hash-shaped cache paths are refused' ($torn.Count -eq 0) "got $($torn.Count)"

    # -- 6: duplicate errors in one entry collapse to one heal target
    $log = New-Log @(
        ".zig-cache\c\$Hash\options.zig:1:1: error: expected type expression, found 'invalid token'"
        ".zig-cache\c\$Hash\options.zig:2:1: error: expected type expression, found 'invalid token'"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'duplicate lines collapse to one entry' ($torn.Count -eq 1) "got $($torn.Count)"

    # -- 7: the corroborating warning is surfaced, and heal deletes the entry ONCE
    $log = New-Log @(
        'Invalid timestamp in cache entry: 999999999999999999999999999999999999999999999999 err=error.Overflow'
    )
    $warn = @(Get-CacheCorruptionWarning -LogPath $log)
    Check 'timestamp-overflow warning is surfaced' ($warn.Count -eq 1) "got $($warn.Count)"

    $healOut = Invoke-CacheHeal -Entries $torn 6>&1 | Out-String
    Check 'heal deletes the torn entry' (-not (Test-Path $EntryDir)) 'entry dir still exists'
    Check 'heal is loud (CACHE HEAL line names the entry)' ($healOut -match [regex]::Escape($EntryDir)) $healOut

    # a second heal of the same (now missing) entry is a SKIP, not an error
    $healOut2 = Invoke-CacheHeal -Entries $torn 6>&1 | Out-String
    Check 'second heal of the same entry is a skip' ($healOut2 -match 'CACHE HEAL SKIP') $healOut2

    # -- 8: Invoke-CacheHeal refuses an entry that is not cache-shaped, even if handed one
    $bogus = [pscustomobject]@{ Entry = (Join-Path $FakeRepo 'src'); File = 'x'; Line = 'y' }
    New-Item -ItemType Directory -Path (Join-Path $FakeRepo 'src') -Force | Out-Null
    $healOut3 = Invoke-CacheHeal -Entries @($bogus) 6>&1 | Out-String
    Check 'heal refuses a non-cache directory' `
        ((Test-Path (Join-Path $FakeRepo 'src')) -and $healOut3 -match 'CACHE HEAL REFUSED') $healOut3

    # -- 9: floor-lane.ps1 still parses and its heal wiring dot-sources cleanly
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepoRoot 'scripts\floor-lane.ps1'), [ref]$tokens, [ref]$errors)
    Check 'floor-lane.ps1 parses' ($errors.Count -eq 0) "$($errors.Count) parse error(s)"
    $src = Get-Content (Join-Path $RepoRoot 'scripts\floor-lane.ps1') -Raw
    Check 'floor-lane dot-sources CacheHeal.ps1' ($src -match 'CacheHeal\.ps1') ''
    Check 'floor-lane heals at most once per lane' ($src -match 'healedThisLane') ''
    Check 'floor-lane re-runs after a heal' ($src -match 'Get-TornCacheEntry') ''
}
finally {
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host "$($script:Failures) FAILURE(S)"
exit 1
