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

    A torn entry does not always get NAMED by an `error:` line, which is what
    T973 cost a turn: after the 2026-08-18 reboot a truncated build_options
    `options.zig` under `.zig-cache\c\<hash>\` failed the win32 and agent lanes
    with `error: root source file struct 'options' has no member named
    'app_version'` pointing at intact `src\build\Config.zig`, and named the
    cache only sideways -- on the compiler's `note: struct declared here` line.
    Two more shapes are therefore recognized, both narrower than the
    unconditional error-line rule, because a note only LOCATES a declaration;
    it does not assert that the content there is wrong:

      * a DECLARATION note (`note: struct declared here` and friends) whose
        location is inside a cache entry -- the compiler saying the thing the
        source expected lives in generated content that does not have it;
      * ANY cache-resolving line, error or note, whose file fails an on-disk
        integrity check (missing, empty, zero-filled, or not newline
        terminated -- the shapes a half-written file actually takes).

    Notes that merely pass THROUGH intact generated code (`note: called at
    comptime here`) still heal nothing, so a genuine compile error keeps its
    diagnosis. The cost ceiling is unchanged either way: a wrong heal deletes a
    regenerable entry and the lane fails again on the retry, which the caller
    reports as final.

    Detection and healing are split so the caller (floor-lane.ps1) can decide
    the retry policy and a test can drive the functions against planted logs:

      Get-TornCacheEntry        log -> the cache entry dir(s) blamed, or none
      Get-CacheCorruptionWarning log -> the non-fatal "Invalid timestamp in
                                cache entry ... error.Overflow" lines, which
                                corroborate a torn cache but name no entry
      Test-CacheFileIntact      one cached file -> does it look whole on disk
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
        Cache entries a red lane's log blames for compile errors.
    .OUTPUTS
        One object per distinct entry: Entry (the directory or file to delete),
        File (the corrupt file the compiler named), Reason (which rule fired),
        Line (the log line, as evidence). Empty when the errors point at real
        source, i.e. almost always.
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
        if ($line -notmatch '(?<path>\S[^\s:]*(?::\\[^\s:]*)?):\d+:\d+:\s*(?<kind>error|note):\s*(?<msg>.*)$') { continue }
        $file = $matches['path'] -replace '/', '\'
        $kind = $matches['kind']
        $msg = $matches['msg']
        $resolved = Resolve-CachePath -FilePath $file -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir
        if (-not $resolved) { continue }

        # Why this line is allowed to delete something. An `error:` INSIDE a
        # cache stays unconditional (T494): the code this repo compiles never
        # lives there. A `note:` needs more, since a note only points at where
        # something was declared -- either it is a declaration note (the
        # generated content is what the source expected, and does not match),
        # or the named file is demonstrably torn on disk.
        $reason = $null
        if ($kind -eq 'error') {
            $reason = 'error-in-cache'
        }
        elseif (-not (Test-CacheFileIntact -Path $resolved.FullPath)) {
            $reason = 'corrupt-on-disk'
        }
        elseif ($msg -match '^(?:\S+\s+){0,3}declared here\s*$') {
            $reason = 'declared-in-cache'
        }
        if (-not $reason) { continue }

        $key = $resolved.Entry.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $out += [pscustomobject]@{
            Entry  = $resolved.Entry
            File   = $file
            Reason = $reason
            Line   = $line.Trim()
        }
    }
    # Plain return, no comma: callers wrap in @(). A `, $out` here makes an
    # EMPTY result count as one item at an @() call site (the inner array
    # becomes the element), which read as a phantom detection in testing.
    return $out
}

function Test-CacheFileIntact {
    <#
    .SYNOPSIS
        Does a file the compiler named inside a cache entry look whole?
    .DESCRIPTION
        False for the shapes a half-written file actually takes on this box:
        gone, empty, zero-filled (T494's was a 2036-byte options.zig of pure
        NULs), or not newline terminated -- every generated source zig writes
        ends in a newline, so a missing one means the write stopped early.
        TRUE is the safe answer whenever the file cannot be judged (too large
        to be a generated source, unreadable), because it is a $false here
        that licenses a delete.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $info = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $true }
    if ($info.Length -eq 0) { return $false }
    # Generated sources are kilobytes. Anything huge is not something whose
    # bytes we should be judging, so leave it alone.
    if ($info.Length -gt 8MB) { return $true }
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return $true }
    foreach ($b in $bytes) { if ($b -eq 0) { return $false } }
    if ($bytes[$bytes.Length - 1] -ne 10) { return $false }
    return $true
}

function Resolve-CachePath {
    <#
    .SYNOPSIS
        The deletable cache entry a named file belongs to, plus its full path.
    .DESCRIPTION
        Zig caches are laid out <root>\<bucket>\<hash>...: bucket is a single
        letter ('c' compiler-generated sources, 'o' outputs, 'z' the ZIR
        store), hash is the entry's hex digest. Two shapes exist and both are
        one unit of deletion:

          <root>\<bucket>\<hash>\<file...>   the hash DIRECTORY is deleted --
              removing only the corrupt file would leave the entry's manifest
              saying the entry is intact;
          <root>\<bucket>\<hash>             the hash FILE is the entry itself
              (the /z ZIR store keeps one file per hash), so it is deleted.

        Bucket-letter and hex-hash are both required, so nothing that is not
        hash-addressed content can ever be named.
    .OUTPUTS
        @{ Entry; FullPath } or $null.
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

    # Need at least <root>\<bucket>\<hash> below the root.
    if ($parts.Count -lt $rootIdx + 3) { return $null }
    if ($parts[$rootIdx + 1] -notmatch '^[a-z]$') { return $null }
    if ($parts[$rootIdx + 2] -notmatch '^[0-9a-fA-F]{16,64}$') { return $null }
    return [pscustomobject]@{
        Entry    = ($parts[0..($rootIdx + 2)] -join '\')
        FullPath = $full
    }
}

function Resolve-CacheEntryDir {
    <#
    .SYNOPSIS
        The deletable cache entry a corrupt file belongs to, or $null.
    .DESCRIPTION
        The Entry half of Resolve-CachePath, kept as its own name because that
        is what callers outside this file ask for.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir
    )
    $r = Resolve-CachePath -FilePath $FilePath -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir
    if (-not $r) { return $null }
    return $r.Entry
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
        Every action prints as a `CACHE HEAL` line naming the entry, the rule
        that fired and the compiler line that blamed it, so a heal can never
        silently hide what happened. The tail-shape re-verification is belt and
        braces on top of Resolve-CachePath: this function refuses anything that
        does not end in \<bucket-letter>\<hex-hash> under a *cache* path.
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
        $why = if ($e.PSObject.Properties['Reason'] -and $e.Reason) { $e.Reason } else { 'error-in-cache' }
        Write-Host "CACHE HEAL: deleting torn cache entry $dir"
        Write-Host "  rule: $why"
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
