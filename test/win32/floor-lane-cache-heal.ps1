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
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
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

    # Stringified before Out-String (T883): `6>&1` puts InformationRecords on
    # the pipeline and Out-String FORMATS them to the host's width, so a
    # `CACHE HEAL` line long enough to wrap fails a -match on a host the author
    # never ran. ToString() keeps the message whole everywhere.
    $healOut = Invoke-CacheHeal -Entries $torn 6>&1 | ForEach-Object { $_.ToString() } | Out-String
    Check 'heal deletes the torn entry' (-not (Test-Path $EntryDir)) 'entry dir still exists'
    Check 'heal is loud (CACHE HEAL line names the entry)' ($healOut -match [regex]::Escape($EntryDir)) $healOut

    # a second heal of the same (now missing) entry is a SKIP, not an error
    $healOut2 = Invoke-CacheHeal -Entries $torn 6>&1 | ForEach-Object { $_.ToString() } | Out-String
    Check 'second heal of the same entry is a skip' ($healOut2 -match 'CACHE HEAL SKIP') $healOut2

    # -- 8: Invoke-CacheHeal refuses an entry that is not cache-shaped, even if handed one
    $bogus = [pscustomobject]@{ Entry = (Join-Path $FakeRepo 'src'); File = 'x'; Line = 'y' }
    New-Item -ItemType Directory -Path (Join-Path $FakeRepo 'src') -Force | Out-Null
    $healOut3 = Invoke-CacheHeal -Entries @($bogus) 6>&1 |
        ForEach-Object { $_.ToString() } | Out-String
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

    # -- 10: Test-CacheFileIntact knows the shapes a half-written file takes
    $probeDir = Join-Path $Sandbox 'probe'
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    $whole = Join-Path $probeDir 'whole.zig'
    Set-Content -Path $whole -Value 'pub const x: bool = false;' -Encoding Ascii  # adds the newline
    $empty = Join-Path $probeDir 'empty.zig'
    [System.IO.File]::WriteAllBytes($empty, (New-Object byte[] 0))
    $zeros = Join-Path $probeDir 'zeros.zig'
    [System.IO.File]::WriteAllBytes($zeros, (New-Object byte[] 2036))
    $cut = Join-Path $probeDir 'cut.zig'
    [System.IO.File]::WriteAllText($cut, "pub const x: bool = false;`npub const y")
    Check 'intact file reads as intact' (Test-CacheFileIntact -Path $whole) ''
    Check 'empty file reads as torn' (-not (Test-CacheFileIntact -Path $empty)) ''
    Check 'zero-filled file reads as torn' (-not (Test-CacheFileIntact -Path $zeros)) ''
    Check 'unterminated file reads as torn' (-not (Test-CacheFileIntact -Path $cut)) ''
    Check 'missing file reads as torn' (-not (Test-CacheFileIntact -Path (Join-Path $probeDir 'gone.zig'))) ''

    # -- 11: the T973 shape -- the cache is named ONLY by a declaration note,
    # every error: line points at intact source. Lines are the 2026-08-18
    # win32-lane log verbatim.
    $h11 = '0b3c0f31d02be43a2a65f80447be46bd'
    $e11 = Join-Path $LocalCache "c\$h11"
    New-Item -ItemType Directory -Path $e11 -Force | Out-Null
    # The truncated file still PARSES and is newline-terminated, so only the
    # note rule can see it: this arm fails if the heal leans on the disk check.
    Set-Content -Path (Join-Path $e11 'options.zig') -Value 'pub const flatpak: bool = false;' -Encoding Ascii
    $log = New-Log @(
        "src\build\Config.zig:689:27: error: root source file struct 'options' has no member named 'app_version'"
        '        .version = options.app_version,'
        '                   ~~~~~~~^~~~~~~~~~~~'
        ".zig-cache\c\$h11\options.zig:1:1: note: struct declared here"
        'pub const flatpak: bool = false;'
        'src\build_config.zig:37:39: note: called at comptime here'
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'the 2026-08-18 log names its entry' ($torn.Count -eq 1 -and $torn[0].Entry -ieq $e11) `
        $(if ($torn.Count -ge 1) { "$($torn.Count): $($torn[0].Entry)" } else { '(none)' })
    Check 'and says which rule fired' ($torn.Count -eq 1 -and $torn[0].Reason -eq 'declared-in-cache') `
        $(if ($torn.Count -ge 1) { $torn[0].Reason } else { '(none)' })

    # -- 12: a note that merely PASSES THROUGH intact generated code heals
    # nothing -- otherwise every genuine error with a generated frame in its
    # note chain would cost a rebuild.
    $log = New-Log @(
        "src\apprt\win32\App.zig:12:5: error: expected type 'u8', found 'bool'"
        ".zig-cache\c\$h11\options.zig:4:9: note: called at comptime here"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'a pass-through note on an intact file heals nothing' ($torn.Count -eq 0) "got $($torn.Count)"

    # -- 13: the same pass-through note DOES heal once the file is torn on disk
    [System.IO.File]::WriteAllBytes((Join-Path $e11 'options.zig'), (New-Object byte[] 2036))
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'a torn-on-disk file heals whatever line named it' `
        ($torn.Count -eq 1 -and $torn[0].Reason -eq 'corrupt-on-disk') `
        $(if ($torn.Count -ge 1) { $torn[0].Reason } else { "got $($torn.Count)" })

    # -- 14: a declaration note in REAL SOURCE is still never a heal target
    $log = New-Log @(
        "src\apprt\win32\App.zig:12:5: error: no field named 'nope' in struct 'Surface'"
        'D:\git\ghoztty\src\Surface.zig:40:1: note: struct declared here'
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'a declaration note in source is never detected' ($torn.Count -eq 0) "got $($torn.Count)"

    # -- 15: the /z ZIR store keeps one FILE per hash; that file is the entry
    $h15 = '5c2e7ab90d4f18e3aa71b6c0d9e4f2a1'
    $zFile = Join-Path $LocalCache "z\$h15"
    New-Item -ItemType Directory -Path (Join-Path $LocalCache 'z') -Force | Out-Null
    [System.IO.File]::WriteAllBytes($zFile, (New-Object byte[] 512))
    $log = New-Log @(
        ".zig-cache\z\${h15}:1:1: error: expected type expression, found 'invalid token'"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'a hash-file entry resolves to the file itself' ($torn.Count -eq 1 -and $torn[0].Entry -ieq $zFile) `
        $(if ($torn.Count -ge 1) { $torn[0].Entry } else { '(none)' })
    $healOut4 = Invoke-CacheHeal -Entries $torn 6>&1 | ForEach-Object { $_.ToString() } | Out-String
    Check 'heal deletes a hash-file entry' (-not (Test-Path $zFile)) $healOut4
    Check 'heal names the rule that fired' ($healOut4 -match 'rule: error-in-cache') $healOut4
}
finally {
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this harness been run against the heal library as it now stands?".
# Added by T883: the `cache-heal` row has existed since T494 but nothing here
# ever wrote its stamp, so the row could only be satisfied by hand and read as
# permanently due after any edit. Red leaves the stamp alone (red stays due).
if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard cache-heal -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
