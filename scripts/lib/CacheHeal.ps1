<#
.SYNOPSIS
    Recognize a torn zig-cache entry in a red lane's log and delete exactly
    that entry, so the lane can be retried once instead of reported as a code
    failure (T494).

.DESCRIPTION
    A half-written cache file (a crash or power blip mid-write) makes the
    compiler choke on garbage: the observed case was a 2036-byte options.zig of
    ZEROS under .zig-cache\c\<hash>\, failing the `none` lane with
    "error: expected type expression, found 'invalid token'" as if the change
    under test were red. The signature is recognizable -- a compile `error:`
    whose FILE LOCATION sits inside a zig cache directory -- because the code
    this repo compiles never lives there; only generated/cached artifacts do.

    Detection and healing are split so the caller (floor-lane.ps1) can decide
    the retry policy and a test can drive the functions against planted logs:

      Get-TornCacheEntry        log -> the cache entry dir(s) blamed, or none
      Get-CacheCorruptionWarning log -> the non-fatal "Invalid timestamp in
                                cache entry ... error.Overflow" lines, which
                                corroborate a torn cache but name no entry
      Invoke-CacheHeal          delete the named entries, loudly

    Safety over eagerness: an entry is only ever named when the path resolves
    to <cache-root>\<single-letter-bucket>\<hex-hash>, and Invoke-CacheHeal
    re-verifies that shape before deleting. A mis-parsed compiler line can
    therefore never aim the delete at source, and a genuine compile error in
    generated-but-correct cache content simply fails again on the retry, which
    the caller reports as final.
#>

function Get-TornCacheEntry {
    <#
    .SYNOPSIS
        Cache entry directories a red lane's log blames for compile errors.
    .OUTPUTS
        One object per distinct entry: Entry (the directory to delete), File
        (the corrupt file the compiler named), Line (the log line, as
        evidence). Empty when the errors point at real source, i.e. almost
        always.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir
    )
    if (-not (Test-Path $LogPath)) { return @() }
    $seen = @{}
    $out = @()
    foreach ($line in @(Get-Content $LogPath -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '(?<path>\S[^\s:]*(?::\\[^\s:]*)?):\d+:\d+:\s*error:') { continue }
        $file = $matches['path'] -replace '/', '\'
        $entry = Resolve-CacheEntryDir -FilePath $file -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir
        if (-not $entry) { continue }
        $key = $entry.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $out += [pscustomobject]@{ Entry = $entry; File = $file; Line = $line.Trim() }
    }
    # Plain return, no comma: callers wrap in @(). A `, $out` here makes an
    # EMPTY result count as one item at an @() call site (the inner array
    # becomes the element), which read as a phantom detection in testing.
    return $out
}

function Resolve-CacheEntryDir {
    <#
    .SYNOPSIS
        The deletable cache entry a corrupt file belongs to, or $null.
    .DESCRIPTION
        Zig caches are laid out <root>\<bucket>\<hash>\...: bucket is a single
        letter ('c' compiler-generated sources, 'o' outputs), hash is the
        entry's hex digest. The HASH directory is the unit of deletion --
        removing only the corrupt file would leave the entry's manifest saying
        the entry is intact. Both shapes are required, so nothing that is not
        hash-addressed content can ever be named.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir
    )
    $full = $FilePath
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $RepoPath $full }
    try { $full = [System.IO.Path]::GetFullPath($full) } catch { return $null }

    $parts = $full -split '\\'
    $rootIdx = -1
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -ieq '.zig-cache') { $rootIdx = $i; break }
    }
    if ($rootIdx -lt 0 -and $GlobalCacheDir) {
        $gc = $GlobalCacheDir.TrimEnd('\')
        if ($full.Length -gt $gc.Length -and
            $full.Substring(0, $gc.Length + 1) -ieq ($gc + '\')) {
            $rootIdx = ($gc -split '\\').Count - 1
        }
    }
    if ($rootIdx -lt 0) { return $null }

    # Need <root>\<bucket>\<hash>\<file...> below the root.
    if ($parts.Count -lt $rootIdx + 4) { return $null }
    if ($parts[$rootIdx + 1] -notmatch '^[a-z]$') { return $null }
    if ($parts[$rootIdx + 2] -notmatch '^[0-9a-fA-F]{16,64}$') { return $null }
    return ($parts[0..($rootIdx + 2)] -join '\')
}

function Get-CacheCorruptionWarning {
    <#
    .SYNOPSIS
        The non-fatal corruption signature: overflowed cache timestamps.
    .DESCRIPTION
        "Invalid timestamp in cache entry: 999... err=error.Overflow" is the
        same torn cache seen from a lane that survived it. It names no entry,
        so it corroborates a heal decision rather than driving one.
    #>
    param([Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-Path $LogPath)) { return @() }
    return @(Select-String -Path $LogPath -Pattern 'Invalid timestamp in cache entry' `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.Line.Trim() })
}

function Invoke-CacheHeal {
    <#
    .SYNOPSIS
        Delete the torn cache entries, loudly. Returns how many were removed.
    .DESCRIPTION
        Every action prints as a `CACHE HEAL` line naming the entry and the
        compiler line that blamed it, so a heal can never silently hide what
        happened. The tail-shape re-verification is belt and braces on top of
        Resolve-CacheEntryDir: this function refuses anything that does not
        end in \<bucket-letter>\<hex-hash> under a *cache* path.
    #>
    param([Parameter(Mandatory)]$Entries)
    $healed = 0
    foreach ($e in @($Entries)) {
        $dir = [string]$e.Entry
        if ($dir -notmatch '(?i)cache[^\\]*\\[a-z]\\[0-9a-f]{16,64}$') {
            Write-Host "CACHE HEAL REFUSED: '$dir' is not <cache>\<bucket>\<hash>"
            continue
        }
        if (-not (Test-Path $dir)) {
            Write-Host "CACHE HEAL SKIP: $dir is already gone"
            continue
        }
        Write-Host "CACHE HEAL: deleting torn cache entry $dir"
        Write-Host "  blamed by: $($e.Line)"
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
            $healed++
        }
        catch {
            Write-Host "  CACHE HEAL FAILED to delete: $($_.Exception.Message)"
        }
    }
    return $healed
}
