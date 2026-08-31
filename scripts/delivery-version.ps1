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
# Three traps are handled here once:
#
#   * ghoztty.exe is a GUI-subsystem binary, so `& $exe +version > file` from
#     PowerShell writes ZERO bytes, silently (T245). Every probe below runs
#     through `cmd.exe /c ... > file`, which is the shape that works and is
#     already how `Invoke-GhozttyListJson` reads `+list`.
#   * a probe with no timeout can block forever on a half-open pipe (T187), so
#     the child is waited on with a hard deadline and killed past it.
#   * `+version` answers for TWO binaries, not one (T773). Below its own
#     `Version` block it prints a `Running Instance` block describing whatever
#     Ghoztty is RUNNING, fetched over IPC (`src/cli/version.zig`
#     printRunningInstance, added by T52) - and that block is the only one with
#     a line literally labelled `commit`. A reader who greps for the commit gets
#     the running app's, which is a different binary that a delivery is not
#     shipping. On 2026-08-11 that misread was filed as a P1 "the build bakes a
#     stale commit stamp": a Debug build and a ReleaseFast build both "reported"
#     the same 12-hours-old sha because both had dialed the same installed
#     release. The bake was correct the whole time. See `Get-CommitFromVersionText`.

# The short hash out of a `+version` payload. Pure: no process, no filesystem.
#
# Anchors on the `- version:` line rather than scanning the whole document,
# because the Build Config section below it is free text and a future line there
# could easily contain something `+hex`-shaped. Falls back to the banner line.
#
# That anchor is also what keeps the `Running Instance` block out (T773): its own
# version line is `  - version : <v>` - one space before the colon - so the
# literal `version:` here cannot match it, and its `  - commit  : <sha>` line is
# never looked at. The distinction between "the binary I am shipping" and "the
# app that happens to be running" therefore rests on a single space, which is
# exactly the kind of thing a formatting tidy erases: arms A31-A35 of
# `test\win32\upgrade-staleness.ps1` hold it with a payload whose two sections
# name DIFFERENT commits.
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

# The RELAY SIGN-IN BAKE out of a `+version` payload (tracker T795):
# @{ Known; Configured; ClientId }.
#
# `src/cli/version.zig` prints one of two lines under `Build Config`:
#
#   - relay sign-in : configured (<public google oauth client id>)
#   - relay sign-in : not configured (no google client id baked in)
#
# `Known` is $false for a payload with neither - which is not a failure and must
# never be reported as one: every binary built before T795 answers that way, and
# a delivery has to keep verifying an older exe it is replacing.
#
# Anchored on the list-bullet line for the reason `Get-CommitFromVersionText` is
# (A6): the section is free text, and prose that merely mentions sign-in must not
# be able to vouch for a binary.
function Get-SignInBakeFromVersionText {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $unknown = @{ Known = $false; Configured = $false; ClientId = '' }
    if (-not $Text) { return $unknown }
    $m = [regex]::Match($Text, '(?m)^\s*-\s*relay sign-in\s*:\s*(\S.*?)\s*$')
    if (-not $m.Success) { return $unknown }
    $v = $m.Groups[1].Value
    if ($v -match '^configured\s*\(\s*(\S.*?)\s*\)$') {
        return @{ Known = $true; Configured = $true; ClientId = $Matches[1] }
    }
    if ($v -match '^not configured') {
        return @{ Known = $true; Configured = $false; ClientId = '' }
    }
    # A line in this shape whose value we cannot classify is UNKNOWN rather than
    # unconfigured: guessing would let a future wording change read as "sign-in
    # is broken" in every delivery log at once.
    return $unknown
}

# Do two sign-in bakes describe the same capability? Used to compare a DELIVERED
# binary against the STAGED one, so the claim is "these bytes carry what the
# bytes I copied carry" - the same claim `Test-AgentStampsMatch` makes.
#
# An unknown bake on EITHER side is not a match: a delivered exe with no line
# beside a staged exe that has one means the copy did not land. Callers decide
# what an unknown STAGED bake means (nothing to compare against, so nothing is
# claimed) before getting here.
function Test-SignInBakesMatch {
    param($A, $B)
    if (-not $A -or -not $B) { return $false }
    if (-not $A.Known -or -not $B.Known) { return $false }
    if ($A.Configured -ne $B.Configured) { return $false }
    if (-not $A.Configured) { return $true }
    return ($A.ClientId.Trim() -eq $B.ClientId.Trim())
}

# A sign-in bake as one short phrase for a log line.
function Format-SignInBake {
    param($Bake)
    if (-not $Bake -or -not $Bake.Known) { return 'unreported (built before T795)' }
    if (-not $Bake.Configured) { return 'NOT configured' }
    return "configured ($($Bake.ClientId))"
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

# Is the file at $Path a Windows program image? @{ Ok; Why } - Why is empty when
# Ok (tracker T1098).
#
# This is a PRECONDITION for launching it, not a nicety. `CreateProcess` on a
# file that carries an `.exe` name and is not a PE image fails with
# ERROR_BAD_EXE_FORMAT, and the Windows loader answers that with a SYSTEM-MODAL
# dialog - `Unsupported 16-Bit Application` - on whatever desktop the caller is
# on, which on this box is the user's own. The probe below then waits for a human
# to click OK. Seen live on 2026-08-22 during an acceptance sweep, on the exact
# path the delivery's own read-back check walks: T281's `AGENT VERIFY` exists
# BECAUSE a delivery can leave a wrong or damaged agent on disk, and a truncated
# copy is that same accident.
#
# Reading four bytes is also better evidence than a launch: a file with no PE
# header cannot in principle be the binary that was staged, so there is nothing
# a `--version` run could add.
#
# Checks only what CreateProcess itself needs to find: `MZ`, then a plausible
# `e_lfanew` at 0x3C pointing at `PE\0\0`. Machine type and bitness are
# deliberately NOT checked - a wrong-architecture binary is a real (and
# different) failure that the version read-back reports on its own.
function Test-PortableExecutable {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -lt 64) {
            return @{ Ok = $false; Why = "not a Windows program: only $($fs.Length) bytes, too short for a PE header" }
        }
        $head = New-Object byte[] 64
        $read = $fs.Read($head, 0, 64)
        if ($read -lt 64) {
            return @{ Ok = $false; Why = 'not a Windows program: could not read the first 64 bytes' }
        }
        if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) {
            return @{ Ok = $false; Why = 'not a Windows program: no MZ signature (the file is not an executable image)' }
        }
        $lfanew = [System.BitConverter]::ToInt32($head, 0x3C)
        if ($lfanew -lt 4 -or ($lfanew + 4) -gt $fs.Length) {
            return @{ Ok = $false; Why = "not a Windows program: PE header offset $lfanew is outside the file" }
        }
        $null = $fs.Seek($lfanew, [System.IO.SeekOrigin]::Begin)
        $sig = New-Object byte[] 4
        $read = $fs.Read($sig, 0, 4)
        if ($read -lt 4 -or $sig[0] -ne 0x50 -or $sig[1] -ne 0x45 -or $sig[2] -ne 0 -or $sig[3] -ne 0) {
            return @{ Ok = $false; Why = 'not a Windows program: no PE signature (a DOS-era or truncated image)' }
        }
        return @{ Ok = $true; Why = '' }
    } catch {
        return @{ Ok = $false; Why = "could not read the file to check it is a program: $($_.Exception.Message)" }
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# Belt and braces for the same failure (T1098): tell Windows to RETURN the error
# rather than raise a message box, for this process and everything it starts.
# SEM_FAILCRITICALERRORS suppresses the critical-error handler dialog and
# SEM_NOOPENFILEERRORBOX the file-not-found one; child processes inherit the
# mode, so `cmd.exe` and whatever it launches are covered too.
#
# The PE gate above is the fix; this is what catches the variants nobody has met
# yet - a corrupt image that passes the header check, a missing DLL, a device
# that is not ready.
function Set-GhozttyQuietErrorMode {
    if (-not ('Ghoztty.NativeErrorMode' -as [type])) {
        Add-Type -Namespace Ghoztty -Name NativeErrorMode -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetErrorMode(uint uMode);
'@ -ErrorAction SilentlyContinue
    }
    if (-not ('Ghoztty.NativeErrorMode' -as [type])) { return $null }
    $SEM_FAILCRITICALERRORS = 0x0001
    $SEM_NOOPENFILEERRORBOX = 0x8000
    try {
        $previous = [Ghoztty.NativeErrorMode]::SetErrorMode($SEM_FAILCRITICALERRORS -bor $SEM_NOOPENFILEERRORBOX)
        return $previous
    } catch { return $null }
}

function Restore-GhozttyErrorMode {
    param($Previous)
    if ($null -eq $Previous) { return }
    if (-not ('Ghoztty.NativeErrorMode' -as [type])) { return }
    try { $null = [Ghoztty.NativeErrorMode]::SetErrorMode([uint32]$Previous) } catch { }
}

# One BOUNDED version probe. Returns @{ Text; Why; NotExecutable } and never
# throws. `NotExecutable` is $true only for the one failure that is a VERDICT
# rather than a missing answer: the file is there and is not a program (T1098),
# so no launch was attempted and none could have helped.
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
        return @{ Text = ''; Why = "exe not found: $Exe"; NotExecutable = $false }
    }
    # Only image extensions are gated. `cmd.exe /c` runs a `.cmd`/`.bat` as a
    # batch script without ever asking the loader for an image, so demanding a
    # PE header there would reject something that genuinely runs - and the test
    # fixtures that stand in for "a program that answers the wrong thing" are
    # exactly that shape.
    if ([System.IO.Path]::GetExtension($Exe) -in @('.exe', '.com', '.scr')) {
        $pe = Test-PortableExecutable -Path $Exe
        if (-not $pe.Ok) {
            return @{ Text = ''; Why = $pe.Why; NotExecutable = $true }
        }
    }
    $out = Join-Path $env:TEMP ("ghoztty-vsnprobe-{0}-{1}.txt" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    # Both callers want the identity of the FILE on disk, and nothing else in
    # this module ever reads the `Running Instance` block - but `+version`
    # produces it by dialing whatever app is running, bounded by T755's 30s
    # default, which outlives the probe deadline below. So a busy or wedged app
    # would turn "read this binary's stamp" into "the delivery cannot verify
    # itself", over a question the answer does not depend on. Bound that one
    # query hard: a timeout there costs a `- query failed` line the parsers skip
    # past, and `+version` still exits 0 carrying its own version.
    $prevIpcTimeout = $env:GHOZTTY_IPC_TIMEOUT_MS
    $env:GHOZTTY_IPC_TIMEOUT_MS = '2000'
    $prevErrorMode = Set-GhozttyQuietErrorMode
    try {
        $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
            -ArgumentList "/c `"`"$Exe`" $VersionArg > `"$out`" 2>&1`""
        # Cache the handle before the child can exit, or .ExitCode reads back
        # empty exactly when we most want to report it.
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            # /T: the answer is written by a GRANDCHILD (cmd.exe -> the binary),
            # so killing cmd alone leaves whatever wedged still wedged.
            & taskkill.exe /T /F /PID $p.Id *> $null
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return @{ Text = ''; Why = "$VersionArg hung past ${TimeoutSec}s"; NotExecutable = $false }
        }
        $t = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { '' }
        if ($t) { return @{ Text = $t; Why = ''; NotExecutable = $false } }
        return @{ Text = ''; Why = "exit=$($p.ExitCode), no output"; NotExecutable = $false }
    } catch {
        return @{ Text = ''; Why = "probe threw: $($_.Exception.Message)"; NotExecutable = $false }
    } finally {
        Restore-GhozttyErrorMode -Previous $prevErrorMode
        if ($null -eq $prevIpcTimeout) {
            Remove-Item Env:\GHOZTTY_IPC_TIMEOUT_MS -ErrorAction SilentlyContinue
        } else {
            $env:GHOZTTY_IPC_TIMEOUT_MS = $prevIpcTimeout
        }
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

# The commit baked into an exe: @{ Commit; Why; SignIn }. Commit is '' when it
# could not be read, and Why then says which of the two failures it was - a probe
# that did not run, or output with no version line in it. Both are worth
# distinguishing in a delivery log; neither is ever silently treated as a match.
#
# `SignIn` is the relay sign-in bake out of the SAME probe (T795): asking a
# second time would double every delivery's process spawns to answer a question
# the first payload already contained.
function Resolve-GhozttyExeCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [int]$TimeoutSec = 20
    )
    $r = Invoke-GhozttyVersionText -Exe $Exe -TimeoutSec $TimeoutSec
    $commit = Get-CommitFromVersionText $r.Text
    $why = if ($commit) { '' } elseif ($r.Why) { $r.Why } else { "no version line in the output of '$Exe +version'" }
    return @{
        Commit        = $commit
        Why           = $why
        SignIn        = (Get-SignInBakeFromVersionText $r.Text)
        NotExecutable = [bool]$r.NotExecutable
    }
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
    return @{
        Stamp         = $stamp
        Commit        = (Get-CommitFromAgentStamp $stamp)
        Why           = $why
        NotExecutable = [bool]$r.NotExecutable
    }
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
    # String concatenation, NOT Join-Path: Join-Path resolves the drive and
    # THROWS for one this session has no PSDrive for ("Cannot find drive. A
    # drive with the name 'E' does not exist"), which returned '' and would
    # have put the zig cache on C: while the repo sat on the missing drive -
    # the exact cross-drive panic this helper exists to prevent. Naming a path
    # is not the same as visiting it.
    return ($root.TrimEnd('\', '/') + '\zig-cache')
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

# The newest PUBLISHED Windows release version, from the repo's `win-v*` tags
# (T1217). '' when there is no such tag or git is unavailable.
#
# Why the loop's own delivery needs this: a script-built staging exe carries the
# repo's `build.zig.zon` version (1.4.0), and that exe is delivered OVER the
# user's installed release. The MSI pipeline stamps a real semver
# (`-Dversion-string=<semver>+<hash>`); the script path did not, so the user's
# terminal reported 1.4.0 and - once the update check became location-aware -
# would have compared 1.4.0 against `win-v1.35.0` and offered a DOWNGRADE.
# Stamping the newest published version keeps the delivered build "up to date"
# against what is on the site, and it takes the NEXT release the moment one is
# published. The `+<hash>` half stays HEAD's, so the staleness gate above still
# reads the commit these bytes were built from.
#
# Ordering is by semver, not by tag creation date or string sort: `win-v1.9.0`
# must not outrank `win-v1.10.0`.
# The pure half: pick the newest X.Y.Z out of a list of tag names. '' when the
# list holds no `win-v<X.Y.Z>` tag at all. Anything else in the list - a `v*`
# release tag, `win-v1.4.1-rc1`, a branch name that wandered in - is ignored
# rather than guessed at.
function Select-NewestWindowsVersion {
    param([AllowNull()][object[]]$Tags)
    if (-not $Tags) { return '' }
    $best = $null
    $bestText = ''
    foreach ($t in $Tags) {
        $name = "$t".Trim()
        if ($name -notmatch '^win-v(\d+)\.(\d+)\.(\d+)$') { continue }
        # PS 5.1: [version] with three parts compares numerically (Build = 3rd),
        # which is the whole point - a string sort puts 1.9.0 above 1.10.0.
        $v = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        if ($null -eq $best -or $v -gt $best) {
            $best = $v
            $bestText = "$($v.Major).$($v.Minor).$($v.Build)"
        }
    }
    return $bestText
}

function Get-PublishedWindowsVersion {
    param([Parameter(Mandatory = $true)][string]$Repo)
    try {
        $tags = @(& git -C $Repo tag --list 'win-v*' 2>$null)
        if ($LASTEXITCODE -ne 0) { return '' }
    } catch { return '' }
    return (Select-NewestWindowsVersion -Tags $tags)
}
