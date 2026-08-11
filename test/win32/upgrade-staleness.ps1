# The delivery must never ship a binary that is not the delivery (tracker T208).
#
# On 2026-07-30 a boundary delivery of T202 ran `launch-upgrade.ps1`, which
# reported `LAUNCH OK`; the upgrade log reported `exe swapped` and `UPGRADE OK`;
# the turn reported the delivery as done. `ghoztty +version` afterwards still
# said `+9968a62d9` - the PREVIOUS delivery's binary. `upgrade-ghoztty-windows.ps1`
# has no build step by design (it copies whatever sits in `zig-out-release`) and
# that precondition was written down nowhere the caller reads.
#
# So there is now a number both ends can compare - the short commit baked into
# the exe by `src/build/GitVersion.zig` - and three gates on it:
#
#   A  pure: reading the commit out of a `+version` payload, and comparing two
#      abbreviations. Carries the 2026-07-30 incident as a permanent oracle.
#   B  the probe against a real binary, including the two ways it can fail.
#   C  launch-upgrade.ps1 refuses to launch a stale staging prefix - and, the
#      half that matters, does not start the upgrade at all when it refuses.
#   D  upgrade-ghoztty-windows.ps1 skips the KILL and the SWAP on stale bits
#      (its own belt-and-braces, and the direct-invocation path), and verifies
#      the installed exe AFTER the swap so `UPGRADE OK` means the right bits are
#      installed rather than "a file copy returned success".
#   E  go.md documents the whole procedure, since the omission there is what
#      made the defect reachable by a turn following instructions exactly.
#
# Hermetic: every install/staging directory is under
# %TEMP%\ghoztty-staleness-<pid>, TEMP is redirected for every child so the
# box's real upgrade log is untouched, no build is ever run, -NoExtraInstalls
# keeps section D away from the real portable/share copies, and -NoDeliver keeps
# section C's launcher from running the T198 delivery step against them. The one shared
# resource it touches is read-only: `+sessions` against the live agent.
#
#   powershell -NoProfile -File test\win32\upgrade-staleness.ps1
param(
    # Only used as a REAL binary that carries SOME commit; never launched as an
    # app. The debug build is deliberate - it is normally a different commit
    # from the release staging prefix, which is exactly the situation under test.
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$PureOnly,
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-staleness-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

. (Join-Path $Repo 'scripts\delivery-version.ps1')

# T199: a stand-in INSTALL dir lives under $root, and the delivery script's job
# ends by launching the app out of one. Arm the teardown so a run that dies
# mid-way still takes its ghoztty processes with it.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-HarnessGhozttyRoot -Root $root | Out-Null

# ============================================================================
"== A: reading and comparing the baked commit (pure)"
# ============================================================================

# Verbatim shape of what `ghoztty +version` prints (captured on the box
# 2026-08-01). Note the pre-release field is the branch and carries hyphens and
# digits of its own, so the commit is the SEMVER BUILD field after the last '+'.
$realPayload = @'
Ghostty 1.4.0-users-dzearing-windows-amd64-+f71f724d0

Version
  - version: 1.4.0-users-dzearing-windows-amd64-+f71f724d0
  - channel: tip
  - update check: off (dev build)
Build Config
  - Zig version   : 0.15.2
  - build mode    : .Debug
  - app runtime   : .win32
Running Instance
  - none detected
'@

AssertEq "A1 the commit comes out of a real payload" 'f71f724d0' (Get-CommitFromVersionText $realPayload)
AssertEq "A2 the banner line alone is enough" 'f71f724d0' `
    (Get-CommitFromVersionText 'Ghostty 1.4.0-users-dzearing-windows-amd64-+f71f724d0')
AssertEq "A3 empty output yields no commit, never a false match" '' (Get-CommitFromVersionText '')
AssertEq "A4 garbage yields no commit instead of throwing" '' (Get-CommitFromVersionText 'not a version at all')
AssertEq "A5 a build with no commit metadata yields no commit" '' `
    (Get-CommitFromVersionText "Version`r`n  - version: 1.4.0`r`n")

# The reason this anchors on the `- version:` line instead of scanning the whole
# document: Build Config is free text, and a line there that happens to look like
# `+<hex>` must not be able to vouch for the binary.
$decoy = "Version`r`n  - version: 1.4.0-branch-+aaaaaaa11`r`nBuild Config`r`n  - some option : x+bbbbbbb22`r`n"
AssertEq "A6 a '+hex' token in Build Config cannot impersonate the version" 'aaaaaaa11' (Get-CommitFromVersionText $decoy)

Assert "A7 abbreviations of different LENGTH still match by prefix" (Test-CommitsMatch 'f71f724' 'f71f724d0')
Assert "A8 case does not matter" (Test-CommitsMatch 'F71F724D0' 'f71f724d0')
Assert "A9 different commits do not match" (-not (Test-CommitsMatch '9968a62d9' 'f1a1c4a24'))
Assert "A10 an unreadable version is NOT a match (unverified must never read as OK)" `
    (-not (Test-CommitsMatch '' 'f1a1c4a24'))
Assert "A11 nor is an unreadable expectation" (-not (Test-CommitsMatch 'f1a1c4a24' ''))
Assert "A12 a too-short abbreviation is refused rather than prefix-matched" (-not (Test-CommitsMatch 'f71' 'f71f724d0'))

# THE INCIDENT, as an oracle: what the installed exe reported on 2026-07-30
# against the commit that delivery was for. Every signal that day said OK.
Assert "A13 INCIDENT ORACLE: installed +9968a62d9 vs delivered f1a1c4a24 is a MISMATCH" `
    (-not (Test-CommitsMatch (Get-CommitFromVersionText 'Ghostty 1.4.0-users-dzearing-windows-amd64-+9968a62d9') 'f1a1c4a24'))

AssertEq "A14 HEAD reads back as a short sha" $true `
    ((Get-RepoHeadCommit -Repo $Repo) -match '^[0-9a-f]{7,40}$')
AssertEq "A15 a directory that is not a repo yields no HEAD" '' (Get-RepoHeadCommit -Repo $env:TEMP)

# --- A16 the zig cache drive --------------------------------------------------
# Found by running the launcher for real, which the sandbox above cannot do: with
# no ZIG_GLOBAL_CACHE_DIR the cache lands on C: while the repo is on D:, a Run
# step cannot express a cross-drive absolute path relative to its child cwd, and
# zig panics in convertPathArg - surfacing as "unable to read results of
# configure phase" under a build-runner stack trace. Every hand-run build here
# exports the variable; a detached delivery child does not inherit that habit.
AssertEq "A16 an unset cache defaults to the REPO's drive, not zig's %LOCALAPPDATA%" 'D:\zig-cache' `
    (Get-ZigGlobalCacheDir -Repo 'D:\git\ghoztty')
AssertEq "A17 a repo on another drive follows it there" 'E:\zig-cache' `
    (Get-ZigGlobalCacheDir -Repo 'E:\somewhere\else')
AssertEq "A18 an explicit setting is never overridden" 'X:\my-own-cache' `
    (Get-ZigGlobalCacheDir -Repo 'D:\git\ghoztty' -Current 'X:\my-own-cache')
$launcherSrc = Get-Content -LiteralPath (Join-Path $Repo 'scripts\launch-upgrade.ps1') -Raw
Assert "A19 and the launcher actually applies it before building" `
    ($launcherSrc -match '\$env:ZIG_GLOBAL_CACHE_DIR\s*=\s*\$zigCache')

if ($PureOnly) {
    ""
    if ($script:failures -eq 0) { "ALL PASS (pure only)" } else { "$($script:failures) FAILURE(S)" }
    exit ($script:failures -gt 0)
}

# ============================================================================
"== B: the probe against a real binary"
# ============================================================================
if (-not (Test-Path -LiteralPath $Exe)) {
    "  FAIL B: -Exe not found: $Exe"; $script:failures++
    exit 1
}
New-Item -ItemType Directory -Force $root | Out-Null

$exeInfo = Resolve-GhozttyExeCommit -Exe $Exe
$exeCommit = $exeInfo.Commit
Assert "B1 the real exe reports a commit ('$exeCommit')" ($exeCommit -match '^[0-9a-f]{7,40}$')
AssertEq "B2 and no reason-it-failed alongside it" '' $exeInfo.Why

$missing = Resolve-GhozttyExeCommit -Exe (Join-Path $root 'no-such.exe')
AssertEq "B3 a missing exe yields no commit" '' $missing.Commit
Assert "B4 and says why" ($missing.Why -match 'not found')

# A binary that runs but says nothing useful: the second failure mode, and the
# one that must not be confused with a match.
$mute = Join-Path $root 'mute.cmd'
Set-Content -LiteralPath $mute -Encoding ascii -Value @('@echo off', 'echo nothing useful here')
$muteInfo = Resolve-GhozttyExeCommit -Exe $mute
AssertEq "B5 output with no version line yields no commit" '' $muteInfo.Commit
Assert "B6 and says which failure it was" ($muteInfo.Why -match 'no version line')

# ============================================================================
"== C: launch-upgrade.ps1 refuses a stale staging prefix"
# ============================================================================
$cRoot = Join-Path $root 'launch'
$cStaging = Join-Path $cRoot 'staging'
New-Item -ItemType Directory -Force (Join-Path $cStaging 'bin') | Out-Null
Copy-Item -LiteralPath $Exe (Join-Path $cStaging 'bin\ghoztty.exe') -Force
$cLog = Join-Path $cRoot 'ghoztty-upgrade.log'
$launcher = Join-Path $Repo 'scripts\launch-upgrade.ps1'
$promptFile = Join-Path $cRoot 'prompt.txt'
[IO.File]::WriteAllText($promptFile, '/reset-context read go.md and go', (New-Object Text.UTF8Encoding($false)))

# The stand-in for the real upgrade script: it logs the marker launch-upgrade
# gates on, so "did the upgrade start?" is answerable without touching anything.
$stubOk = Join-Path $cRoot 'stub-ok.ps1'
Set-Content -LiteralPath $stubOk -Encoding ascii -Value @(
    'param([string]$Staging,[string]$ResumePromptFile,[int]$DelaySeconds,[int]$LoopClaudePid,[string]$ExpectedCommit,[switch]$AllowStaleStaging)',
    '$log = Join-Path $env:TEMP "ghoztty-upgrade.log"',
    'Add-Content $log "$(Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') === upgrade start (stub)"',
    'Add-Content $log "stub expected=[$ExpectedCommit] allowStale=$([bool]$AllowStaleStaging)"',
    'Start-Sleep -Seconds 1'
)

function Invoke-InSandboxTemp([string[]]$Argv, [string]$TempDir, [int]$TimeoutMs = 90000) {
    $savedTemp, $savedTmp = $env:TEMP, $env:TMP
    $env:TEMP, $env:TMP = $TempDir, $TempDir
    try {
        $o = Join-Path $TempDir "child-$([guid]::NewGuid().ToString('N').Substring(0,8)).out"
        $e = "$o.err"
        $p = Start-Process powershell -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e -ArgumentList $Argv
        # Cache .Handle BEFORE the child exits or .ExitCode reads back empty.
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
        return [pscustomobject]@{
            Code = $p.ExitCode
            Out  = (Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue)
            Err  = (Get-Content -LiteralPath $e -Raw -ErrorAction SilentlyContinue)
        }
    } finally { $env:TEMP, $env:TMP = $savedTemp, $savedTmp }
}
function Get-MarkerCount([string]$Log) {
    if (-not (Test-Path -LiteralPath $Log)) { return 0 }
    @(Select-String -LiteralPath $Log -Pattern '=== upgrade start' -SimpleMatch).Count
}

# --- C1 NEGATIVE CONTROL: the staged exe is not the delivery -----------------
# This is 2026-07-30 exactly: a staging prefix left behind by an older build.
$before = Get-MarkerCount $cLog
$stale = Invoke-InSandboxTemp -TempDir $cRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-PromptFile', $promptFile, '-Staging', $cStaging, '-UpgradeScript', $stubOk, '-NoDeliver',
    '-Repo', $Repo, '-SkipBuild', '-ExpectedCommit', 'deadbee0f', '-StartTimeoutSeconds', '10')
Assert "C1 NEGATIVE CONTROL: a stale staging prefix fails the launch (exit $($stale.Code))" ($stale.Code -eq 3)
Assert "C2 and says so in the words a turn would grep for" ($stale.Out -match 'STALE STAGING')
Assert "C3 and names both commits" (($stale.Out -match [regex]::Escape($exeCommit)) -and ($stale.Out -match 'deadbee0f'))
AssertEq "C4 THE HALF THAT MATTERS: no upgrade was started" $before (Get-MarkerCount $cLog)

# --- C5 the same prefix, delivered on purpose --------------------------------
$before = Get-MarkerCount $cLog
$forced = Invoke-InSandboxTemp -TempDir $cRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-PromptFile', $promptFile, '-Staging', $cStaging, '-UpgradeScript', $stubOk, '-NoDeliver',
    '-Repo', $Repo, '-SkipBuild', '-ExpectedCommit', 'deadbee0f', '-AllowStaleStaging', '-StartTimeoutSeconds', '20')
AssertEq "C5 -AllowStaleStaging ships it anyway" 0 $forced.Code
Assert "C6 loudly" ($forced.Out -match 'WARNING')
AssertEq "C7 and the upgrade really started" ($before + 1) (Get-MarkerCount $cLog)
Assert "C8 the expectation is handed DOWN, so the child measures the same number" `
    ((Get-Content -LiteralPath $cLog -Raw) -match 'stub expected=\[deadbee0f\] allowStale=True')

# --- C9 the healthy delivery -------------------------------------------------
$before = Get-MarkerCount $cLog
$fresh = Invoke-InSandboxTemp -TempDir $cRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-PromptFile', $promptFile, '-Staging', $cStaging, '-UpgradeScript', $stubOk, '-NoDeliver',
    '-Repo', $Repo, '-SkipBuild', '-ExpectedCommit', $exeCommit, '-StartTimeoutSeconds', '20')
AssertEq "C9 a staged exe that IS the delivery launches" 0 $fresh.Code
Assert "C10 and reports what it compared" ($fresh.Out -match 'staging freshness')
AssertEq "C11 and the upgrade started" ($before + 1) (Get-MarkerCount $cLog)

# --- C12 an empty staging prefix cannot pass the gate ------------------------
$emptyStaging = Join-Path $cRoot 'empty-staging'
New-Item -ItemType Directory -Force (Join-Path $emptyStaging 'bin') | Out-Null
$before = Get-MarkerCount $cLog
$noExe = Invoke-InSandboxTemp -TempDir $cRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-PromptFile', $promptFile, '-Staging', $emptyStaging, '-UpgradeScript', $stubOk, '-NoDeliver',
    '-Repo', $Repo, '-SkipBuild', '-ExpectedCommit', $exeCommit, '-StartTimeoutSeconds', '10')
Assert "C12 a staging prefix with no exe fails (exit $($noExe.Code))" ($noExe.Code -eq 3)
Assert "C13 and says the installed release was not touched" ($noExe.Out -match 'NOT upgraded')
AssertEq "C14 and started nothing" $before (Get-MarkerCount $cLog)

# ============================================================================
"== D: upgrade-ghoztty-windows.ps1 - skip the swap, then prove the swap"
# ============================================================================
# Every run here passes -NoExtraInstalls: the other two install locations are
# REAL directories on this box and an acceptance script has no business writing
# to the user's desktop or NAS.
$upgrade = Join-Path $Repo 'scripts\upgrade-ghoztty-windows.ps1'
$dRoot = Join-Path $root 'upgrade'
$dStaging = Join-Path $dRoot 'staging'
$dInstall = Join-Path $dRoot 'install'
New-Item -ItemType Directory -Force (Join-Path $dStaging 'bin') | Out-Null
New-Item -ItemType Directory -Force $dInstall | Out-Null
Copy-Item -LiteralPath $Exe (Join-Path $dStaging 'bin\ghoztty.exe') -Force
$dLog = Join-Path $dRoot 'ghoztty-upgrade.log'
$installedExe = Join-Path $dInstall 'ghoztty.exe'

# A sentinel, not a binary: on the stale path it is never executed, and its
# survival byte-for-byte is the assertion that nothing destructive ran.
$sentinel = 'PREVIOUS-INSTALL-DO-NOT-TOUCH'
Set-Content -LiteralPath $installedExe -Encoding ascii -Value $sentinel

# --- D1 stale staging: nothing is killed, nothing is swapped -----------------
$dStaleRun = Invoke-InSandboxTemp -TempDir $dRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
    '-Staging', $dStaging, '-InstallDir', $dInstall, '-WorkingDirectory', $Repo,
    '-ExpectedCommit', 'deadbee0f', '-NoResume', '-NoExtraInstalls', '-DelaySeconds', '0')
$dLogText = Get-Content -LiteralPath $dLog -Raw -ErrorAction SilentlyContinue
AssertEq "D1 a stale delivery exits non-zero" 1 $dStaleRun.Code
Assert "D2 the log names the defect" ($dLogText -match 'STALE STAGING')
Assert "D3 THE POINT: the swap never happened" (-not ($dLogText -match 'exe swapped'))
AssertEq "D4 and the installed exe is untouched" $sentinel `
    ((Get-Content -LiteralPath $installedExe -Raw).Trim())
Assert "D5 the verdict is FAILED, and never the success tag" `
    (($dLogText -match 'UPGRADE FAILED') -and -not ($dLogText -match 'UPGRADE OK'))

# --- D6 fresh staging: the swap happens and is verified ----------------------
Remove-Item -LiteralPath $dLog -Force -ErrorAction SilentlyContinue
$dFreshRun = Invoke-InSandboxTemp -TempDir $dRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
    '-Staging', $dStaging, '-InstallDir', $dInstall, '-WorkingDirectory', $Repo,
    '-ExpectedCommit', $exeCommit, '-NoResume', '-NoExtraInstalls', '-DelaySeconds', '0')
$dLogText = Get-Content -LiteralPath $dLog -Raw -ErrorAction SilentlyContinue
AssertEq "D6 a fresh delivery succeeds" 0 $dFreshRun.Code
Assert "D7 the swap happened" ($dLogText -match 'exe swapped')
Assert "D8 POST-SWAP VERIFY read the installed exe back" ($dLogText -match 'POST-SWAP VERIFY OK')
Assert "D9 and named the commit the user is now running" ($dLogText -match [regex]::Escape($exeCommit))
Assert "D10 the verdict is OK" ($dLogText -match 'UPGRADE OK')
AssertEq "D11 the installed exe really is the staged one" `
    (Get-FileHash -LiteralPath (Join-Path $dStaging 'bin\ghoztty.exe')).Hash `
    (Get-FileHash -LiteralPath $installedExe).Hash
Assert "D12 the other install locations were left alone" ($dLogText -match 'skipped by request')

# --- D13 the post-swap gate itself, exercised live ---------------------------
# -AllowStaleStaging lets the swap proceed while the delivery is declared to be
# for a commit the staged exe does not carry. The bits then land fine and the
# POST-swap read is what has to catch it - the same read that would have caught
# 2026-07-30 had it existed.
Remove-Item -LiteralPath $dLog -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $installedExe -Encoding ascii -Value $sentinel
$dPostRun = Invoke-InSandboxTemp -TempDir $dRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
    '-Staging', $dStaging, '-InstallDir', $dInstall, '-WorkingDirectory', $Repo,
    '-ExpectedCommit', 'deadbee0f', '-AllowStaleStaging', '-NoResume', '-NoExtraInstalls', '-DelaySeconds', '0')
$dLogText = Get-Content -LiteralPath $dLog -Raw -ErrorAction SilentlyContinue
Assert "D13 the swap was allowed through" ($dLogText -match 'exe swapped')
Assert "D14 but the post-swap read caught the mismatch" ($dLogText -match 'POST-SWAP VERIFY FAILED')
AssertEq "D15 so the run is a FAILURE despite a successful copy" 1 $dPostRun.Code
Assert "D16 and it does not claim success" (-not ($dLogText -match 'UPGRADE OK'))
Assert "D17 nor propagate unverified bits to the other locations" `
    ($dLogText -match 'NOT PROPAGATED')

# ============================================================================
"== E: the documented procedure is the whole procedure"
# ============================================================================
# The omission in go.md is what made this defect reachable by a turn that
# followed instructions exactly, so the doc is part of the fix.
$goMd = Get-Content -LiteralPath (Join-Path $Repo 'go.md') -Raw
Assert "E1 go.md says the launcher builds the staging release" ($goMd -match 'BUILDS the staging release')
Assert "E2 go.md names the failure the gate produces" ($goMd -match 'STALE STAGING')
Assert "E3 go.md still carries the build incantation itself" ($goMd -match '--prefix zig-out-release')
Assert "E4 go.md points at this acceptance script" ($goMd -match 'upgrade-staleness\.ps1')

""
if (-not $Keep) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
