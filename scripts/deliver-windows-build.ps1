# Deliver a staged Windows build to install locations 2 and 3, and PROVE it
# landed (tracker T198).
#
# The standing bar is that a user-facing fix reaches all three install
# locations: the installed release (`%LOCALAPPDATA%\Programs\Ghoztty`), the
# Desktop portable, and the network share. Only the FIRST has ever been
# scripted - `upgrade-ghoztty-windows.ps1` does it, and mirrors the binaries
# onward best-effort. Everything else about locations 2 and 3 (the dated
# backups, the share's loose `ghoztty-agent.exe`, and the portable ZIP that
# people actually download) was re-derived from prose in the session log every
# time, by a session that had never done it before.
#
# That costs correctness, not just time, and there are two measurements:
#
#   * T196 (2026-07-30) hand-built the portable zip. It exited 0 and was wrong
#     twice over - rooted at `Ghoztty-portable-x64\Ghoztty\...` instead of
#     `Ghoztty\...` (extracting it the documented way would have double-nested
#     the app directory) and carrying both `.pdb` files, doubling a network
#     download from 20.3 MB to 41.9 MB. Both were caught only because that
#     session happened to diff the new artifact against the one it replaced.
#   * 2026-08-10, found while writing this script: BOTH portable locations were
#     holding a DEBUG `ghoztty.exe` (`+edc526574`, PE subsystem 3 = console)
#     beside a RELEASE `ghoztty.com` (`+213a21f0d`). The morning refresh had
#     logged `extra install '...': ghoztty.exe, ghoztty.com, ...` an hour
#     earlier. The copy reported success; the file on disk was from a different
#     build. Nothing anywhere read the result back.
#
# So the point of this script is not the copy loop - a copy loop is easy. It is
# that every claim it makes is MEASURED afterwards:
#
#   * every delivered file is compared against its staging source (length and
#     modification time; SHA-256 with -DeepVerify),
#   * every delivered `ghoztty.exe`/`ghoztty.com` is asked `+version` and must
#     answer the commit this delivery is for,
#   * their PE subsystem must be GUI/console respectively, which is what
#     separates a release build from a Debug one without trusting a string,
#   * the portable zip is built from an explicit manifest (root entry
#     `Ghoztty\`, no `.pdb`, no `.bak*`) and its entry set is diffed against the
#     artifact it replaces; an unannounced shape change fails the run and the
#     zip is NOT published.
#
# Reachability is not failure: a location that is absent or unreachable (a
# sleeping NAS) is SKIPPED and named in the verdict. A location that is present
# and wrong is a failure - that is the whole distinction the old best-effort
# mirror could not make.
#
# Usage:
#   powershell -NoProfile -File scripts\deliver-windows-build.ps1 [-DryRun]
#   scripts\deliver-windows-build.ps1 -Staging D:\git\ghoztty\zig-out-release
#
# Exit codes: 0 delivered and verified (possibly with skipped locations),
#             1 something was delivered wrong, 2 the run was never viable
#             (bad staging, bad arguments).
[CmdletBinding(PositionalBinding = $false)]
param(
    # What to ship. The release staging prefix; never `zig-out` (Debug).
    [string]$Staging = 'D:\git\ghoztty\zig-out-release',
    # The exe-bearing directory of each portable install, NOT the wrapper
    # folder: both portables nest one level.
    [string[]]$Targets = @(
        'D:\Users\David\Desktop\Ghoztty-portable-x64\Ghoztty',
        '\\homeassistant\share\ghoztty-windows\Ghoztty-portable-x64\Ghoztty'
    ),
    # The share keeps a LOOSE ghoztty-agent.exe beside the zip, which
    # `bootstrap.ps1` and `ghoztty-agent-watcher.ps1` fetch on their own. Empty
    # to skip it.
    [string]$LooseAgentDir = '\\homeassistant\share\ghoztty-windows',
    # The portable archive people download. Empty (or -NoZip) to skip.
    [string]$ZipPath = '\\homeassistant\share\ghoztty-windows\Ghoztty-portable-x64.zip',
    # Which portable directory the zip is built FROM. Empty = the first target
    # that exists, which is the local one, so the zip is not assembled by
    # reading 130 MB back over SMB.
    [string]$ZipSource = '',
    # The top-level directory inside the archive. `Ghoztty`, so unzipping it
    # next to the documented instructions yields `Ghoztty\ghoztty.exe`.
    [string]$ZipRoot = 'Ghoztty',
    # The commit this delivery is for. Empty = read it out of the staged exe.
    [string]$ExpectedCommit = '',
    # Stamp for `.bak-<suffix>` names. Empty = yyyyMMdd-HHmmss.
    [string]$Suffix = '',
    # App and nothing else (T525's morning refresh): the agent is not swapped
    # in any location.
    [switch]$AppOnly,
    # Keep a replaced copy of the executables. Off for the two .pdb files by
    # design - see Get-BackupFileSet.
    [switch]$NoBackup,
    [switch]$BackupAll,
    [switch]$NoZip,
    # SHA-256 every delivered file instead of comparing length + mtime. Correct
    # either way; this reads ~130 MB per location back over the network.
    [switch]$DeepVerify,
    # Accept an entry-set change in the portable zip. Required whenever the
    # shipped file set legitimately changes (adding ghoztty.com did exactly
    # that), and never the default: the failure it guards is a zip that was
    # built from the wrong shape and shipped anyway.
    [switch]$AcceptZipShape,
    # Ship a staging prefix whose ghoztty.exe is not a GUI-subsystem binary,
    # i.e. a Debug build. Loud, and never the default.
    [switch]$AllowDebugStaging,
    # Print what would happen and touch nothing.
    [switch]$DryRun,
    # Delete all but the newest N backup generations in every location. Absent
    # (the default) only REPORTS what a prune would remove: deleting is a
    # user-gated action, so this script offers it rather than doing it.
    [int]$PruneBackups = -1
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'delivery-version.ps1')
. (Join-Path $PSScriptRoot 'delivery-manifest.ps1')

$script:problems = New-Object System.Collections.Generic.List[string]
$script:skipped = New-Object System.Collections.Generic.List[string]

function Say([string]$m) { Write-Host $m }
function Ok([string]$m) { Write-Host "  ok   $m" }
function Bad([string]$m) { Write-Host "  FAIL $m"; $script:problems.Add($m) }
function Skip([string]$m) { Write-Host "  skip $m"; $script:skipped.Add($m) }

function Complete-Delivery {
    $n = $script:problems.Count
    if ($n -gt 0) {
        Say ''
        foreach ($p in $script:problems) { Say "  - $p" }
        Say "DELIVER FAILED: $n problem(s)"
        exit 1
    }
    $tail = if ($script:skipped.Count) { " ($($script:skipped.Count) skipped: $($script:skipped -join '; '))" } else { '' }
    if ($DryRun) { Say "DELIVER DRY RUN: nothing was written across $script:locationCount location(s)$tail"; exit 0 }
    if ($script:locationCount -eq 0) {
        # Never "OK": nothing was reached, so nothing was delivered. Not fatal
        # either - the primary install is a different script's job and must not
        # be held up by a sleeping NAS.
        Say "DELIVER SKIPPED: no install location was reachable$tail"
        exit 0
    }
    Say "DELIVER OK: $script:deliveredCount file(s) verified across $script:locationCount location(s)$tail"
    exit 0
}
$script:deliveredCount = 0
$script:locationCount = 0

if (-not $Suffix) { $Suffix = Get-Date -Format 'yyyyMMdd-HHmmss' }

# ---- the staging prefix must be a real release build ------------------------
if (-not (Test-Path -LiteralPath $Staging -PathType Container)) {
    Say "ABORT: staging directory not found: $Staging"
    exit 2
}
$stagingBin = Join-Path $Staging 'bin'
if (-not (Test-Path -LiteralPath $stagingBin -PathType Container)) {
    Say "ABORT: staging has no bin\ directory: $stagingBin"
    exit 2
}
$stagingShare = Join-Path $Staging 'share'

$fileSet = @(Get-DeliveryFileSet -AppOnly:$AppOnly)
$missing = @($fileSet | Where-Object { -not (Test-Path -LiteralPath (Join-Path $stagingBin $_) -PathType Leaf) })
if ($missing.Count) {
    Say "ABORT: staging is incomplete, missing: $($missing -join ', ')"
    exit 2
}

Say "== staging $Staging (suffix $Suffix$(if ($AppOnly) { ', app-only' })$(if ($DryRun) { ', DRY RUN' }))"

# The Debug-build guard. This is the check that would have stopped 2026-08-10 at
# the source rather than an hour later on two network shares.
foreach ($n in @('ghoztty.exe', 'ghoztty.com')) {
    $want = Get-ExpectedSubsystem $n
    if ($want -eq 0) { continue }
    $got = Get-PeSubsystem (Join-Path $stagingBin $n)
    if ($got -eq $want) { continue }
    $msg = "staging $n has PE subsystem $got, expected $want (a console-subsystem ghoztty.exe is a Debug build)"
    if ($AllowDebugStaging) { Say "  WARNING: $msg - shipping it anyway (-AllowDebugStaging)" }
    else { Say "ABORT: $msg"; exit 2 }
}

$stagedExe = Join-Path $stagingBin 'ghoztty.exe'
$stagedId = Resolve-GhozttyExeCommit -Exe $stagedExe
$expect = if ($ExpectedCommit) { $ExpectedCommit.Trim().ToLowerInvariant() } else { $stagedId.Commit }
if (-not $expect) {
    Say "ABORT: could not read the staged exe's commit, so nothing delivered could be verified"
    exit 2
}
Say "   shipping +$expect"

# T795: what this delivery does to the user's ability to sign in, said out loud
# ONCE, up front. A build with no Google OAuth client id baked in cannot start a
# relay sign-in at all - the machine chooser says so instead of offering a dead
# button (T747) - and that was true of every delivered Windows build for months
# with nothing in any delivery log mentioning it. It is a WARNING and not a
# failure on purpose: the id is build configuration the box may legitimately not
# have (drop it in a git-ignored google-client-id.txt at the repo root, per D72),
# and a delivery must not be held hostage to it.
$script:stagedSignIn = $stagedId.SignIn
if (-not $script:stagedSignIn.Known) {
    Say "   sign-in unreported by the staged exe (a build from before T795); delivered builds cannot be checked for it this run"
} elseif ($script:stagedSignIn.Configured) {
    Say "   sign-in configured ($($script:stagedSignIn.ClientId))"
} else {
    Say "  WARNING: this build has NO google client id baked in, so relay sign-in will be unavailable in every location it reaches (see docs/claude/remote.md)"
}

# T281: the agent ships in the same delivery and was the one binary nothing ever
# read back. It carries no semver - `ghoztty-agent --version` prints a
# `YYYYMMDD-<hash>` BUILD STAMP - so a delivered agent is measured against the
# STAGED agent's stamp: "the bytes over there are the bytes here", which is
# exactly the claim a copy makes and the claim a skipped copy breaks.
$script:stagedAgentStamp = ''
if (-not $AppOnly) {
    $stagedAgentExe = Join-Path $stagingBin 'ghoztty-agent.exe'
    if (Test-Path -LiteralPath $stagedAgentExe -PathType Leaf) {
        $sa = Resolve-GhozttyAgentStamp -Exe $stagedAgentExe
        $script:stagedAgentStamp = $sa.Stamp
        if ($sa.Stamp) { Say "   agent $($sa.Stamp)" }
        else { Say "  note: the staged agent would not report a stamp ($($sa.Why)); delivered agents cannot be verified this run" }
    }
}

# ---- copy + verify one file --------------------------------------------------
#
# Copy-Item preserves the source's length and modification time, so those two
# fields ARE the delivered-file check: on 2026-08-10 the destination kept a
# 46,668,288-byte file stamped 04:18:58 while the source was 32,147,456 stamped
# 05:43:46, and every log line said the copy succeeded.
function Test-SameFile {
    param([string]$Src, [string]$Dst, [switch]$Deep)
    if (-not (Test-Path -LiteralPath $Dst -PathType Leaf)) { return 'the file is not there' }
    $s = Get-Item -LiteralPath $Src
    $d = Get-Item -LiteralPath $Dst
    if ($s.Length -ne $d.Length) { return "length $($d.Length), staging has $($s.Length)" }
    if ($Deep) {
        $hs = (Get-FileHash -LiteralPath $Src -Algorithm SHA256).Hash
        $hd = (Get-FileHash -LiteralPath $Dst -Algorithm SHA256).Hash
        if ($hs -ne $hd) { return "sha256 $($hd.Substring(0,12))..., staging has $($hs.Substring(0,12))..." }
        return ''
    }
    # Two seconds of slack: a copy across SMB can land a FAT-rounded timestamp.
    $delta = [Math]::Abs(($s.LastWriteTimeUtc - $d.LastWriteTimeUtc).TotalSeconds)
    if ($delta -gt 2) {
        return "modified $($d.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))Z, staging says $($s.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))Z"
    }
    return ''
}

function Copy-DeliveredFile {
    param([string]$Src, [string]$Dst, [string[]]$BackupNames)
    $name = Split-Path $Dst -Leaf
    if ($DryRun) { return "would copy $name" }
    try {
        if ((Test-Path -LiteralPath $Dst -PathType Leaf) -and ($BackupNames -contains $name)) {
            Copy-Item -LiteralPath $Dst "$Dst.bak-$Suffix" -Force -ErrorAction Stop
        }
    } catch {
        # A backup that cannot be taken is worth saying out loud, but it is not
        # a reason to withhold the fix from the location.
        Say "  note: could not back up $name ($($_.Exception.Message))"
    }
    try {
        Copy-Item -LiteralPath $Src $Dst -Force -ErrorAction Stop
        return ''
    } catch {
        # A mapped image (a portable instance running from here) can be renamed
        # but not overwritten. Shove it aside and copy onto the empty path.
        try {
            Move-Item -LiteralPath $Dst "$Dst.locked-$Suffix" -Force -ErrorAction Stop
            Copy-Item -LiteralPath $Src $Dst -Force -ErrorAction Stop
            return ''
        } catch {
            return $_.Exception.Message
        }
    }
}

# ---- locations 2 and 3 -------------------------------------------------------
$backupNames = if ($NoBackup) { @() } else { @(Get-BackupFileSet -All:$BackupAll) }

foreach ($dir in $Targets) {
    if (-not $dir) { continue }
    Say ''
    Say "== $dir"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Skip "$dir is not present"
        continue
    }
    $script:locationCount++
    $failedHere = $false

    foreach ($n in $fileSet) {
        $src = Join-Path $stagingBin $n
        $dst = Join-Path $dir $n
        $err = Copy-DeliveredFile -Src $src -Dst $dst -BackupNames $backupNames
        if ($DryRun) { Say "  dry  $err"; continue }
        if ($err) { Bad "$dir\$n could not be written: $err"; $failedHere = $true; continue }
        $why = Test-SameFile -Src $src -Dst $dst -Deep:$DeepVerify
        if ($why) { Bad "$dir\$n did not land: $why"; $failedHere = $true; continue }
        $script:deliveredCount++
        Ok $n
    }

    # share\ is a tree, not a file; /MIR so a file main deleted goes away here
    # too. /R:1 /W:1 so an unreachable share fails in seconds, not minutes.
    if (Test-Path -LiteralPath $stagingShare -PathType Container) {
        if ($DryRun) {
            Say "  dry  would mirror share\"
        } else {
            $rc = 0
            robocopy $stagingShare (Join-Path $dir 'share') /MIR /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
            $rc = $LASTEXITCODE
            # robocopy: < 8 is success (0 nothing to do, 1 copied, 2 extras, 3 both).
            if ($rc -lt 8) { Ok "share\ (robocopy $rc)" } else { Bad "$dir\share could not be mirrored (robocopy $rc)"; $failedHere = $true }
        }
    }

    if ($DryRun) { continue }

    # The semantic proof. A matching length and mtime says the bytes arrived;
    # `+version` says the bytes are the build this delivery is for, and the
    # subsystem says it is a release build rather than a Debug one.
    foreach ($n in @('ghoztty.exe', 'ghoztty.com')) {
        $exe = Join-Path $dir $n
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $want = Get-ExpectedSubsystem $n
        $sub = Get-PeSubsystem $exe
        if ($want -ne 0 -and $sub -ne $want) {
            Bad "$dir\$n has PE subsystem $sub, expected $want"
            $failedHere = $true
        }
        $got = Resolve-GhozttyExeCommit -Exe $exe
        if (-not $got.Commit) { Bad "$dir\$n could not be asked its version ($($got.Why))"; $failedHere = $true; continue }
        if (Test-CommitsMatch $got.Commit $expect) { Ok "$n reports +$($got.Commit)" }
        else { Bad "$dir\$n reports +$($got.Commit) but this delivery is +$expect"; $failedHere = $true }

        # T795: and it carries the sign-in capability the staged bytes carry.
        # Only ever compared against STAGING - "the same build" is the claim a
        # copy makes - so a staging prefix that reports nothing (pre-T795)
        # asserts nothing here rather than failing every location.
        if ($script:stagedSignIn.Known) {
            if (Test-SignInBakesMatch $got.SignIn $script:stagedSignIn) {
                if ($got.SignIn.Configured) { Ok "$n sign-in $(Format-SignInBake $got.SignIn)" }
            } else {
                Bad "$dir\$n sign-in is $(Format-SignInBake $got.SignIn) but staging is $(Format-SignInBake $script:stagedSignIn)"
                $failedHere = $true
            }
        }
    }

    # The same read for the agent (T281). Present-and-wrong is a failure here for
    # the reason it is for the exe: this location was reached, so a stale binary
    # in it is a delivery that did not happen, not an unreachable NAS.
    if ($script:stagedAgentStamp) {
        $agentThere = Join-Path $dir 'ghoztty-agent.exe'
        if (Test-Path -LiteralPath $agentThere -PathType Leaf) {
            $ga = Resolve-GhozttyAgentStamp -Exe $agentThere
            if (Test-AgentStampsMatch $ga.Stamp $script:stagedAgentStamp) { Ok "ghoztty-agent.exe reports $($ga.Stamp)" }
            elseif ($ga.Stamp) { Bad "$dir\ghoztty-agent.exe reports $($ga.Stamp) but staging has $($script:stagedAgentStamp)"; $failedHere = $true }
            else { Bad "$dir\ghoztty-agent.exe could not be asked its version ($($ga.Why))"; $failedHere = $true }
        }
    }

    if (-not $failedHere) { Say "   verified" }
}

# ---- the share's loose ghoztty-agent.exe -------------------------------------
if ($LooseAgentDir -and -not $AppOnly) {
    Say ''
    Say "== loose agent in $LooseAgentDir"
    if (-not (Test-Path -LiteralPath $LooseAgentDir -PathType Container)) {
        Skip "$LooseAgentDir is not reachable"
    } else {
        $src = Join-Path $stagingBin 'ghoztty-agent.exe'
        $dst = Join-Path $LooseAgentDir 'ghoztty-agent.exe'
        if ($DryRun) {
            Say '  dry  would refresh ghoztty-agent.exe'
        } else {
            $err = Copy-DeliveredFile -Src $src -Dst $dst -BackupNames @('ghoztty-agent.exe')
            if ($err) { Bad "$dst could not be written: $err" }
            else {
                $why = Test-SameFile -Src $src -Dst $dst -Deep:$DeepVerify
                if ($why) { Bad "$dst did not land: $why" }
                elseif (-not $script:stagedAgentStamp) { $script:deliveredCount++; Ok 'ghoztty-agent.exe (stamp unverifiable, see note above)' }
                else {
                    # T281: the semantic half. The share's loose agent is what
                    # bootstrap.ps1 and ghoztty-agent-watcher.ps1 fetch, so a
                    # stale one here reaches boxes this delivery never touched.
                    $ga = Resolve-GhozttyAgentStamp -Exe $dst
                    if (Test-AgentStampsMatch $ga.Stamp $script:stagedAgentStamp) { $script:deliveredCount++; Ok "ghoztty-agent.exe reports $($ga.Stamp)" }
                    elseif ($ga.Stamp) { Bad "$dst reports $($ga.Stamp) but staging has $($script:stagedAgentStamp)" }
                    else { Bad "$dst could not be asked its version ($($ga.Why))" }
                }
            }
        }
    }
} elseif ($LooseAgentDir -and $AppOnly) {
    Skip 'the loose share agent (-AppOnly)'
}

# ---- the portable zip --------------------------------------------------------
if ($NoZip -or -not $ZipPath) {
    Skip 'the portable zip (-NoZip)'
} elseif ($AppOnly) {
    # The archive is built FROM a portable directory, and under -AppOnly that
    # directory keeps whatever agent it already had. Publishing it would ship a
    # new app beside an old agent as a matched pair, which is a claim nobody
    # made. The zip is a full-delivery artifact; the morning refresh is not one.
    Skip 'the portable zip (-AppOnly ships no agent, so the archive would pair a new app with an old one)'
} else {
    Say ''
    Say "== portable zip $ZipPath"
    $zipSrc = $ZipSource
    if (-not $zipSrc) { $zipSrc = @($Targets | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })[0] }
    if (-not $zipSrc) {
        Skip 'the portable zip (no portable directory to build it from)'
    } elseif (-not (Test-Path -LiteralPath (Split-Path $ZipPath -Parent) -PathType Container)) {
        Skip "the portable zip ($(Split-Path $ZipPath -Parent) is not reachable)"
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

        # The shape being replaced, read BEFORE anything is written.
        $oldEntries = @()
        $oldSize = 0
        if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
            $oldSize = (Get-Item -LiteralPath $ZipPath).Length
            try {
                $z = [IO.Compression.ZipFile]::OpenRead($ZipPath)
                try { $oldEntries = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
            } catch { Say "  note: could not read the zip being replaced ($($_.Exception.Message)); its shape cannot be diffed" }
        }

        # Built LOCALLY, always: assembling 130 MB of entries by reading a
        # network share would take minutes and fail halfway on a sleeping NAS.
        $tmpZip = Join-Path $env:TEMP "ghoztty-portable-$Suffix.zip"
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue

        $srcRoot = (Resolve-Path -LiteralPath $zipSrc).Path.TrimEnd('\')
        $files = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($srcRoot.Length + 1)
                if (Test-PortableZipIncludes $rel) { [pscustomobject]@{ Full = $_.FullName; Entry = (ConvertTo-ZipEntryName -Root $ZipRoot -Relative $rel) } }
            })
        $newEntries = @($files | ForEach-Object { $_.Entry })
        $diff = Get-ZipShapeDiff -Old $oldEntries -New $newEntries

        Say "   from $srcRoot -> $($files.Count) entr(ies) (was $($diff.OldCount))"
        # Capped: a first build (or a wrong root prefix) renames EVERY entry, and
        # 566 lines of diff is not a signal anyone reads. The counts are the
        # signal; the first few names say which kind of change it is.
        if ($diff.Changed -and $diff.OldCount -gt 0) {
            $shown = 0
            foreach ($a in $diff.Added) { if ($shown -ge 12) { break }; Say "   + $a"; $shown++ }
            $shown = 0
            foreach ($r in $diff.Removed) { if ($shown -ge 12) { break }; Say "   - $r"; $shown++ }
            if ($diff.Added.Count -gt 12 -or $diff.Removed.Count -gt 12) {
                Say "   ... $($diff.Added.Count) added, $($diff.Removed.Count) removed in total"
            }
        }

        if ($diff.Changed -and -not $AcceptZipShape -and $diff.OldCount -gt 0) {
            Bad ("the portable zip's entry set changed ($($diff.Added.Count) added, $($diff.Removed.Count) removed) and nothing was published; " +
                're-run with -AcceptZipShape if the change is intended')
        } elseif ($DryRun) {
            Say '  dry  would build and publish the zip'
        } else {
            $built = $false
            try {
                $archive = [IO.Compression.ZipFile]::Open($tmpZip, 'Create')
                try {
                    foreach ($f in $files) {
                        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.Full, $f.Entry, [IO.Compression.CompressionLevel]::Optimal)
                    }
                } finally { $archive.Dispose() }
                $built = $true
            } catch { Bad "the portable zip could not be built: $($_.Exception.Message)" }

            if ($built) {
                try {
                    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
                        Copy-Item -LiteralPath $ZipPath "$ZipPath.bak-$Suffix" -Force -ErrorAction Stop
                    }
                    Copy-Item -LiteralPath $tmpZip $ZipPath -Force -ErrorAction Stop
                    $newSize = (Get-Item -LiteralPath $ZipPath).Length
                    # Read the PUBLISHED artifact back, not the local one: the
                    # copy that matters is the one over the network.
                    $pub = @()
                    $z = [IO.Compression.ZipFile]::OpenRead($ZipPath)
                    try { $pub = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
                    $back = Get-ZipShapeDiff -Old $newEntries -New $pub
                    if ($back.Changed) {
                        Bad "the published zip does not match what was built ($($back.Added.Count) added, $($back.Removed.Count) removed)"
                    } else {
                        $pct = if ($oldSize -gt 0) { [math]::Round((($newSize - $oldSize) / $oldSize) * 100, 1) } else { 0 }
                        Ok ("published {0:N1} MB ({1} entries, {2}{3}% vs the artifact it replaced)" -f ($newSize / 1MB), $back.NewCount, $(if ($pct -ge 0) { '+' } else { '' }), $pct)
                        $script:deliveredCount++
                    }
                } catch { Bad "the portable zip could not be published: $($_.Exception.Message)" }
            }
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- backup retention: offered, never done -----------------------------------
Say ''
Say '== backups'
$backupDirs = @($Targets) + @($LooseAgentDir)
# Only where this run actually WROTE. -NoZip used to leave the zip's directory
# in the list, so a run that had been told to stay away from the share still
# enumerated it - and with -PruneBackups would have deleted there.
if ($ZipPath -and -not $NoZip) { $backupDirs += (Split-Path $ZipPath -Parent) }
$backupDirs = @($backupDirs | Where-Object { $_ } | Select-Object -Unique)
foreach ($dir in $backupDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $baks = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $null -ne (Get-BackupGeneration $_.Name) })
    if (-not $baks.Count) { continue }
    $mb = [math]::Round((($baks | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
    $gens = @($baks | ForEach-Object { Get-BackupGeneration $_.Name } | Sort-Object -Unique)
    if ($PruneBackups -lt 0) {
        Say ("   $dir : $($baks.Count) file(s) / $($gens.Count) generation(s) / ${mb} MB" +
            " - prune with -PruneBackups <keep>")
        continue
    }
    $doomed = @(Select-StaleBackups -Names @($baks | ForEach-Object { $_.Name }) -Keep $PruneBackups)
    if (-not $doomed.Count) { Say "   $dir : nothing to prune (keeping $PruneBackups generation(s))"; continue }
    $freed = [math]::Round((($baks | Where-Object { $doomed -contains $_.Name } | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
    if ($DryRun) { Say "   $dir : would delete $($doomed.Count) file(s), freeing ${freed} MB"; continue }
    $gone = 0
    foreach ($n in $doomed) {
        try { Remove-Item -LiteralPath (Join-Path $dir $n) -Force -ErrorAction Stop; $gone++ } catch {
            Say "   note: could not delete $n ($($_.Exception.Message))"
        }
    }
    Say "   $dir : deleted $gone of $($doomed.Count) file(s), freed ~${freed} MB"
}

Say ''
Complete-Delivery
