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
  Arm 9 proves floor-lane.ps1 still parses and dot-sources the library.

  Arms 16-22 cover T1436, the other shape: a half-extracted FETCHED PACKAGE,
  which is reported by the cache layer rather than the compiler and so carries
  no `:line:col:` for the rules above to match. Arm 20 is the integrity scan
  that answers the same question WITHOUT a failing build, arm 21 is its
  reachability from the claim's cache report, and arm 22 is genuinely end to
  end: floor-lane.ps1 -Command drives a real process that fails while the torn
  package exists and passes once it is gone, so a PASS is proof the lane healed
  and re-ran. (Arm 9 could not do that until T1436 lifted the heal policy out
  of the lane loop into a function -Command mode also runs.)

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
    # =====================================================================
    # T1436: a torn FETCHED PACKAGE. The 2026-09-07 outage -- every build and
    # all four floor lanes red at once -- came through a shape none of the
    # arms above can see: no `:line:col:`, and an entry under `p\` whose name
    # is a package hash rather than a hex digest. Fixtures below reproduce the
    # real package directory's contents exactly (four AppleDouble sidecars,
    # AUTHORS.txt and OFL.txt, and no `fonts/`), which is what is still sitting
    # on the box as `<hash>.torn-20260907`.
    # =====================================================================

    $PkgAnon = 'N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x'
    $PkgNamed = 'libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs'

    function New-TornPackageDir {
        param([string]$Root, [string]$Name)
        $d = Join-Path $Root "p\$Name"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        foreach ($f in '._.', '._AUTHORS.txt', '._fonts', '._OFL.txt', 'AUTHORS.txt', 'OFL.txt') {
            Set-Content -Path (Join-Path $d $f) -Value 'x' -Encoding Ascii
        }
        return $d
    }

    # -- 16: the real error line names the PACKAGE directory, both name shapes
    foreach ($pkg in @($PkgAnon, $PkgNamed)) {
        $pd = New-TornPackageDir -Root $GlobalCache -Name $pkg
        $log = New-Log @(
            "error: failed to check cache: '$pd\fonts\ttf\JetBrainsMono-Regular.ttf' file_hash FileNotFound"
        )
        $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
        Check "torn package is detected ($($pkg.Substring(0,6))...)" ($torn.Count -eq 1) "got $($torn.Count)"
        Check "and the entry is the package dir, not the file ($($pkg.Substring(0,6))...)" `
            ($torn.Count -eq 1 -and $torn[0].Entry -ieq $pd) `
            $(if ($torn.Count -ge 1) { $torn[0].Entry } else { '(none)' })
        Check "and says which rule fired ($($pkg.Substring(0,6))...)" `
            ($torn.Count -eq 1 -and $torn[0].Reason -eq 'torn-package') `
            $(if ($torn.Count -ge 1) { $torn[0].Reason } else { '(none)' })
    }

    # -- 17: NEGATIVE CONTROL -- the same line naming a path outside any cache
    # heals nothing. This is the arm that says the rule is about the cache and
    # not about the words "failed to check cache".
    $log = New-Log @(
        "error: failed to check cache: 'D:\git\ghoztty\src\font\res\JetBrainsMono-Regular.ttf' file_hash FileNotFound"
        "error: failed to check cache: 'C:\Users\someone\Downloads\thing.ttf' file_hash FileNotFound"
    )
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    Check 'a fetch-check line outside the cache heals nothing' ($torn.Count -eq 0) "got $($torn.Count)"

    # -- 18: NEGATIVE CONTROL -- a directory under `p\` whose name is not a
    # package hash is refused. The set-aside copy this box makes by hand is the
    # live example, and deleting one of those would destroy the evidence.
    foreach ($bad in @("$PkgAnon.torn-20260907", 'tmp', 'not-a-hash')) {
        $bd = Join-Path $GlobalCache "p\$bad"
        New-Item -ItemType Directory -Path $bd -Force | Out-Null
        $log = New-Log @("error: failed to check cache: '$bd\fonts\x.ttf' file_hash FileNotFound")
        $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
        Check "a non-package dir under p\ is refused ($bad)" ($torn.Count -eq 0) "got $($torn.Count)"
    }
    Check 'Test-PackageEntryName accepts the anonymous hash' (Test-PackageEntryName -Name $PkgAnon) ''
    Check 'Test-PackageEntryName accepts a named hash' (Test-PackageEntryName -Name $PkgNamed) ''
    Check 'Test-PackageEntryName rejects the set-aside copy' `
        (-not (Test-PackageEntryName -Name "$PkgAnon.torn-20260907")) ''

    # -- 19: the heal deletes the package directory, and refuses a p-bucket
    # path that is not package-shaped even when handed one directly.
    $pd = Join-Path $GlobalCache "p\$PkgAnon"
    $log = New-Log @("error: failed to check cache: '$pd\fonts\ttf\x.ttf' file_hash FileNotFound")
    $torn = @(Get-TornCacheEntry -LogPath $log -RepoPath $FakeRepo -GlobalCacheDir $GlobalCache)
    $healOut5 = Invoke-CacheHeal -Entries $torn 6>&1 | ForEach-Object { $_.ToString() } | Out-String
    Check 'heal deletes the torn package directory' (-not (Test-Path $pd)) $healOut5
    Check 'heal names the torn-package rule' ($healOut5 -match 'rule: torn-package') $healOut5
    $bogusPkg = [pscustomobject]@{
        Entry  = (Join-Path $GlobalCache 'p\not-a-hash')
        File   = 'x'; Reason = 'torn-package'; Line = 'y'
    }
    $healOut6 = Invoke-CacheHeal -Entries @($bogusPkg) 6>&1 | ForEach-Object { $_.ToString() } | Out-String
    Check 'heal refuses a p-bucket dir that is not package-shaped' `
        ((Test-Path $bogusPkg.Entry) -and $healOut6 -match 'CACHE HEAL REFUSED') $healOut6

    # -- 20: Get-TornPackage -- the integrity question, asked WITHOUT a build.
    $ScanCache = Join-Path $Sandbox 'scan-cache'
    $tornPkg = New-TornPackageDir -Root $ScanCache -Name $PkgAnon
    $emptyPkg = Join-Path $ScanCache "p\$PkgNamed"
    New-Item -ItemType Directory -Path $emptyPkg -Force | Out-Null
    $found = @(Get-TornPackage -GlobalCacheDir $ScanCache)
    Check 'the scan finds both suspect packages' ($found.Count -eq 2) "got $($found.Count)"
    Check 'and names the orphan sidecar' `
        (@($found | Where-Object { $_.Reason -eq 'orphan-sidecar' -and $_.Entry -ieq $tornPkg }).Count -eq 1) `
        (($found | ForEach-Object { "$($_.Reason):$($_.Entry)" }) -join '; ')
    Check 'and names the empty package' `
        (@($found | Where-Object { $_.Reason -eq 'empty-package' -and $_.Entry -ieq $emptyPkg }).Count -eq 1) ''

    # NEGATIVE CONTROL for the scan: an intact package (including the `._.`
    # root sidecar, which ships in three of this box's real packages and names
    # no sibling) and a non-package directory are both left alone.
    $CleanCache = Join-Path $Sandbox 'clean-cache'
    $good = Join-Path $CleanCache "p\$PkgAnon"
    New-Item -ItemType Directory -Path (Join-Path $good 'fonts') -Force | Out-Null
    foreach ($f in '._.', '._fonts', '._OFL.txt', 'OFL.txt') {
        Set-Content -Path (Join-Path $good $f) -Value 'x' -Encoding Ascii
    }
    New-Item -ItemType Directory -Path (Join-Path $CleanCache 'p\tmp') -Force | Out-Null
    Check 'an intact package (with a ._. root sidecar) is not flagged' `
        ((@(Get-TornPackage -GlobalCacheDir $CleanCache)).Count -eq 0) `
        ((@(Get-TornPackage -GlobalCacheDir $CleanCache) | ForEach-Object { "$($_.Reason):$($_.Detail)" }) -join '; ')
    Check 'a cache with no p\ at all scans clean' `
        ((@(Get-TornPackage -GlobalCacheDir (Join-Path $Sandbox 'no-such-cache'))).Count -eq 0) ''

    # -- 21: the claim's cache report can tell "big" from "torn". build-cache
    # `check` is what go-loop-exec.ps1 claim runs (as `sweep`), so this is the
    # reachability arm for that goal.
    $bcScript = Join-Path $RepoRoot 'scripts\build-cache.ps1'
    $bcTorn = & powershell -NoProfile -ExecutionPolicy Bypass -File $bcScript check `
        -Repo $FakeRepo -CacheDir $ScanCache -MinFreeGB 0 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'build-cache check reports a torn package' ($bcTorn -match 'BUILD CACHE TORN: 2 fetched package') $bcTorn
    Check 'and names the entry to delete' ($bcTorn -match [regex]::Escape($tornPkg)) $bcTorn
    $bcClean = & powershell -NoProfile -ExecutionPolicy Bypass -File $bcScript check `
        -Repo $FakeRepo -CacheDir $CleanCache -MinFreeGB 0 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'a healthy cache prints no torn line' ($bcClean -notmatch 'BUILD CACHE TORN') $bcClean

    # -- 22: end to end. floor-lane runs a command that fails exactly the way
    # 2026-09-07 failed while the package directory exists, and succeeds once
    # it is gone -- so a PASS here is proof the lane healed and re-ran rather
    # than reporting a bare FAIL. This is the arm arm 9 could not be.
    $E2ECache = Join-Path $Sandbox 'e2e-cache'
    $e2ePkg = New-TornPackageDir -Root $E2ECache -Name $PkgAnon
    $failScript = Join-Path $Sandbox 'e2e-fail.ps1'
    @(
        "if (Test-Path '$e2ePkg') {"
        "  Write-Host `"error: failed to check cache: '$e2ePkg\fonts\ttf\JetBrainsMono-Regular.ttf' file_hash FileNotFound`""
        "  exit 1"
        "}"
        "Write-Host 'rebuilt clean'"
        "exit 0"
    ) | Set-Content -Path $failScript -Encoding Ascii
    $laneOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\floor-lane.ps1') `
        -Command "powershell -NoProfile -File $failScript" -CacheDir $E2ECache -MinFreeGB 0 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'floor-lane heals the torn package it was handed' (-not (Test-Path $e2ePkg)) $laneOut
    Check 'floor-lane says it healed and re-ran' ($laneOut -match 'healed 1 torn cache entr') $laneOut
    Check 'and the re-run passes, so the lane is not a bare FAIL' ($laneOut -match 'FLOOR SUMMARY: command=PASS') $laneOut

    Complete-TestBody  # T1039: the run reached the end of its body
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
