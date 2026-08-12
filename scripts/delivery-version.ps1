# The delivery's BUILD and FRESHNESS helpers (tracker T208).
#
# `upgrade-ghoztty-windows.ps1` has no build step by design - it copies whatever
# is already sitting in `zig-out-release`. That contract was written down
# nowhere the caller reads, so on 2026-07-30 a delivery of T202 shipped the
# PREVIOUS delivery's binary while `LAUNCH OK`, `exe swapped` and `UPGRADE OK`
# all reported success. `ghoztty +version` afterwards still said `+9968a62d9`.
#
# The answer is a number both sides can compare: the short commit baked into the
# exe by `src/build/GitVersion.zig` (semver build metadata, so it appears after
# the last `+`) against `git rev-parse --short HEAD`. This module owns reading
# both and comparing them, so the launcher's pre-flight, the upgrade script's
# pre-swap abort and its post-swap verification cannot drift apart.
#
# Two Windows-specific traps are handled here once:
#
#   * ghoztty.exe is a GUI-subsystem binary, so `& $exe +version > file` from
#     PowerShell writes ZERO bytes, silently (T245). Every probe below runs
#     through `cmd.exe /c ... > file`, which is the shape that works and is
#     already how `Invoke-GhozttyListJson` reads `+list`.
#   * a probe with no timeout can block forever on a half-open pipe (T187), so
#     the child is waited on with a hard deadline and killed past it.

# The short hash out of a `+version` payload. Pure: no process, no filesystem.
#
# Anchors on the `- version:` line rather than scanning the whole document,
# because the Build Config section below it is free text and a future line there
# could easily contain something `+hex`-shaped. Falls back to the banner line.
function Get-CommitFromVersionText {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    $vsn = ''
    if ($Text -match '(?m)^\s*-\s*version:\s*(\S+)\s*$') { $vsn = $Matches[1] }
    elseif ($Text -match '(?m)^\s*Ghostty\s+(\S+)\s*$') { $vsn = $Matches[1] }
    if (-not $vsn) { return '' }
    # Semver build metadata: everything after the LAST '+'. The branch is in the
    # pre-release field ahead of it and can itself contain hyphens and digits.
    if ($vsn -match '\+([0-9a-fA-F]{7,40})$') { return $Matches[1].ToLowerInvariant() }
    return ''
}

# Do two short hashes name the same commit? Abbreviations are compared by
# PREFIX: `git rev-parse --short` and the build's `git log --pretty=%h` both
# honour core.abbrev, but they are not contractually the same LENGTH, and a
# 9-vs-7 mismatch must not read as "stale bits".
#
# Empty on either side is NOT a match: an unreadable version is an unverified
# delivery, and this whole task exists because unverified read as OK.
function Test-CommitsMatch {
    param(
        [AllowEmptyString()][AllowNull()][string]$A,
        [AllowEmptyString()][AllowNull()][string]$B
    )
    if (-not $A -or -not $B) { return $false }
    $a = $A.Trim().ToLowerInvariant()
    $b = $B.Trim().ToLowerInvariant()
    if (-not $a -or -not $b) { return $false }
    $n = [Math]::Min($a.Length, $b.Length)
    if ($n -lt 7) { return $false }
    return ($a.Substring(0, $n) -eq $b.Substring(0, $n))
}

# The BUILD STAMP out of a `ghoztty-agent --version` payload. Pure.
#
# The agent answers a different question in a different shape: one line,
# `ghoztty-agent 20260811-3bbf0eefb` - a `YYYYMMDD-<short hash>` stamp, or the
# literal `dev` when git was unavailable at build time. The authority on that
# shape is `src/remote/agent_build.zig` (`parseVersionOutput`), and this is its
# PowerShell reader: the last whitespace-separated token of the first non-empty
# line, anchored on the `ghoztty-agent` banner so a program that prints anything
# else cannot vouch for itself the way A6's Build Config decoy could not.
#
# Returns '' for output this cannot read. `dev` comes back verbatim - it is a
# real stamp, just not one with a commit in it.
function Get-StampFromAgentVersionText {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    foreach ($raw in ($Text -split "`n")) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -notmatch '^ghoztty-agent\s+(\S.*)$') { return '' }
        $rest = $Matches[1].Trim()
        $tokens = @($rest -split '\s+' | Where-Object { $_ })
        if (-not $tokens.Count) { return '' }
        return $tokens[-1]
    }
    return ''
}

# The short commit inside a stamp, or '' when it carries none (`dev`, or any
# shape we do not recognise). Never guesses: an unreadable half is '' so it
# cannot be compared into a false match.
function Get-CommitFromAgentStamp {
    param([AllowEmptyString()][AllowNull()][string]$Stamp)
    if (-not $Stamp) { return '' }
    if ($Stamp -match '^\d{8}-([0-9a-fA-F]{7,40})$') { return $Matches[1].ToLowerInvariant() }
    return ''
}

# One BOUNDED version probe. Returns @{ Text; Why } and never throws.
#
# `-VersionArg` is what the binary is asked: `+version` for ghoztty.exe, but
# `--version` for ghoztty-agent.exe, which is a different program with its own
# CLI and its own answer shape.
function Invoke-GhozttyVersionText {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [int]$TimeoutSec = 20,
        [string]$VersionArg = '+version'
    )
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        return @{ Text = ''; Why = "exe not found: $Exe" }
    }
    $out = Join-Path $env:TEMP ("ghoztty-vsnprobe-{0}-{1}.txt" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
            -ArgumentList "/c `"`"$Exe`" $VersionArg > `"$out`" 2>&1`""
        # Cache the handle before the child can exit, or .ExitCode reads back
        # empty exactly when we most want to report it.
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return @{ Text = ''; Why = "$VersionArg hung past ${TimeoutSec}s" }
        }
        $t = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { '' }
        if ($t) { return @{ Text = $t; Why = '' } }
        return @{ Text = ''; Why = "exit=$($p.ExitCode), no output" }
    } catch {
        return @{ Text = ''; Why = "probe threw: $($_.Exception.Message)" }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

# The commit baked into an exe: @{ Commit; Why }. Commit is '' when it could not
# be read, and Why then says which of the two failures it was - a probe that did
# not run, or output with no version line in it. Both are worth distinguishing in
# a delivery log; neither is ever silently treated as a match.
function Resolve-GhozttyExeCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [int]$TimeoutSec = 20
    )
    $r = Invoke-GhozttyVersionText -Exe $Exe -TimeoutSec $TimeoutSec
    $commit = Get-CommitFromVersionText $r.Text
    $why = if ($commit) { '' } elseif ($r.Why) { $r.Why } else { "no version line in the output of '$Exe +version'" }
    return @{ Commit = $commit; Why = $why }
}

# The build stamp of an agent binary ON DISK: @{ Stamp; Commit; Why } (tracker
# T281).
#
# The delivery ships THREE binaries and until this existed it read exactly one
# of them back. The agent is the one with a live failure mode already on the
# record: the swap renames the running agent's image aside and copies the new
# one in, and on 2026-07-20 that dance failed (`Remove-Item` silently, then
# `Move-Item` on an existing name) - so the swap was skipped, a months-old agent
# stayed on disk, and the run still said `UPGRADE OK`.
#
# `Stamp` is the whole `YYYYMMDD-<hash>`, because THAT is what a delivered agent
# is compared against: the stamp of the agent in staging. Comparing commits
# instead would demand that the staged agent and the staged app carry the same
# one, which is a different (and weaker) claim - a staging prefix is built in one
# go, but zig-out routinely holds two binaries from two builds.
function Resolve-GhozttyAgentStamp {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [int]$TimeoutSec = 20
    )
    $r = Invoke-GhozttyVersionText -Exe $Exe -TimeoutSec $TimeoutSec -VersionArg '--version'
    $stamp = Get-StampFromAgentVersionText $r.Text
    $why = if ($stamp) { '' } elseif ($r.Why) { $r.Why } else { "no 'ghoztty-agent <stamp>' line in the output of '$Exe --version'" }
    return @{ Stamp = $stamp; Commit = (Get-CommitFromAgentStamp $stamp); Why = $why }
}

# Do two agent stamps name the same build? Exact, case-insensitive, and empty on
# either side is never a match - an unread stamp is an unverified delivery, which
# is the standard this whole family exists to enforce.
#
# Deliberately NOT prefix-tolerant the way Test-CommitsMatch is: both stamps here
# are produced by the same `--version` printer, so a length difference is a real
# difference rather than two abbreviations of one commit.
function Test-AgentStampsMatch {
    param(
        [AllowEmptyString()][AllowNull()][string]$A,
        [AllowEmptyString()][AllowNull()][string]$B
    )
    if (-not $A -or -not $B) { return $false }
    return ($A.Trim().ToLowerInvariant() -eq $B.Trim().ToLowerInvariant())
}

# Where zig's GLOBAL cache must live to build $Repo, given whatever the
# environment already says ($Current, normally $env:ZIG_GLOBAL_CACHE_DIR).
#
# An explicit setting always wins - this only fills in a default, and the default
# is NOT zig's own. Zig puts the global cache under %LOCALAPPDATA% (drive C:);
# with the repo on D: the build dies:
#
#   thread N panic: reached unreachable code
#     std\Build\Step\Run.zig:662 in convertPathArg
#       assert(!std.fs.path.isAbsolute(child_cwd_rel));
#   error: unable to read results of configure phase from '.zig-cache\tmp\...'
#
# A Run step rewrites absolute paths as child-cwd-relative, and a path rooted on
# another drive HAS no relative form - so the assert fires and the real error is
# buried under a build-runner stack trace. Measured on the box 2026-08-01, and it
# is why every hand-run build here exports the variable first. A detached
# delivery child inherits the launching tool shell's environment, where it is
# usually absent, so the launcher must not rely on the caller having done it.
function Get-ZigGlobalCacheDir {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [AllowEmptyString()][AllowNull()][string]$Current = ''
    )
    if ($Current) { return $Current }
    $root = ''
    try { $root = [IO.Path]::GetPathRoot($Repo) } catch { $root = '' }
    if (-not $root) { return '' }
    return (Join-Path $root 'zig-cache')
}

# `git rev-parse --short HEAD` in $Repo, or '' if git or the repo is unavailable.
function Get-RepoHeadCommit {
    param([Parameter(Mandatory = $true)][string]$Repo)
    try {
        $sha = (& git -C $Repo rev-parse --short HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { return '' }
        if ($sha -match '^[0-9a-fA-F]{7,40}$') { return $sha.ToLowerInvariant() }
        return ''
    } catch { return '' }
}
