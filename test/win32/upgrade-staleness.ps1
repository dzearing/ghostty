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
    # Section E's subject (T281). Same deal: never launched as an agent, only
    # asked `--version`. Its stamp is normally a DIFFERENT build from -Exe, which
    # is exactly why a delivered agent is measured against the STAGED agent
    # rather than against the app's commit.
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$PureOnly,
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$script:skipped = 0
$root = Join-Path $env:TEMP "ghoztty-staleness-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

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

# --- A20 the AGENT's own version shape (T281) ---------------------------------
# A different program with a different CLI and a different answer: one line,
# `ghoztty-agent <YYYYMMDD>-<short hash>`. Captured on the box 2026-08-12.
AssertEq "A20 the stamp comes out of a real agent payload" '20260811-3bbf0eefb' `
    (Get-StampFromAgentVersionText "ghoztty-agent 20260811-3bbf0eefb`n")
AssertEq "A21 a CRLF payload reads the same" '20260811-3bbf0eefb' `
    (Get-StampFromAgentVersionText "ghoztty-agent 20260811-3bbf0eefb`r`n")
AssertEq "A22 a git-less build's stamp survives verbatim" 'dev' `
    (Get-StampFromAgentVersionText 'ghoztty-agent dev')
AssertEq "A23 empty output yields no stamp" '' (Get-StampFromAgentVersionText '')
# Anchored on the banner for A6's reason: a program that prints something else
# must not be able to vouch for itself. The B-section stub prints exactly this.
AssertEq "A24 output from some other program yields no stamp" '' `
    (Get-StampFromAgentVersionText 'nothing useful here')
AssertEq "A25 the commit is the half after the date" '3bbf0eefb' (Get-CommitFromAgentStamp '20260811-3bbf0eefb')
AssertEq "A26 a dev stamp carries no commit, and never guesses one" '' (Get-CommitFromAgentStamp 'dev')
Assert "A27 identical stamps match" (Test-AgentStampsMatch '20260811-3bbf0eefb' '20260811-3BBF0EEFB')
Assert "A28 THE 2026-07-20 ORACLE: a months-old agent left by a skipped swap is a MISMATCH" `
    (-not (Test-AgentStampsMatch '20260720-9968a62d9' '20260811-3bbf0eefb'))
Assert "A29 an unread stamp is NOT a match (unverified must never read as OK)" `
    (-not (Test-AgentStampsMatch '' '20260811-3bbf0eefb'))
# Two `dev` stamps are equal strings and that is all this can say. It is the
# staged-vs-installed comparison, so equality really is the claim being made.
Assert "A30 stamps are exact, not prefix-matched the way abbreviated commits are" `
    (-not (Test-AgentStampsMatch '20260811-3bbf0ee' '20260811-3bbf0eefb'))

# --- A31-A35: the OTHER binary in the same document (T773) --------------------
# `+version` answers for two binaries. Under its own `Version` block it prints a
# `Running Instance` block describing whatever Ghoztty is RUNNING, fetched over
# IPC - and that block owns the only line literally labelled `commit`. Every
# delivery gate here must read the block that describes the FILE it was handed.
#
# This is not a hypothetical: on 2026-08-11 the two blocks were read as one and
# filed as a P1 ("a freshly built binary bakes a stale commit stamp"). A Debug
# build and a ReleaseFast build appeared to agree on a 12-hours-old sha because
# both had dialed the same installed release; the bake was correct throughout.
# The fixture below is that day's shape, with the two blocks deliberately naming
# DIFFERENT commits so a reader that confuses them cannot pass.
$twoBinaries = @'
Ghostty 1.4.0-users-dzearing-windows-amd64-+2699f0dd5

Version
  - version: 1.4.0-users-dzearing-windows-amd64-+2699f0dd5
  - channel: tip
  - update check: off (dev build)
Build Config
  - Zig version   : 0.15.2
  - build mode    : .Debug
  - app runtime   : .win32
Running Instance
  - version : 1.4.0-users-dzearing-windows-amd64-+2929e42c0
  - commit  : 2929e42c0
  - mode    : ReleaseFast
  - runtime : win32
  - exe     : C:\Users\David\AppData\Local\Programs\Ghoztty\ghoztty.exe
  - pid     : 50828
'@

AssertEq "A31 THE 2026-08-11 ORACLE: the probed binary's commit wins, not the running app's" `
    '2699f0dd5' (Get-CommitFromVersionText $twoBinaries)
Assert "A32 and the running app's commit is never mistaken for it" `
    ((Get-CommitFromVersionText $twoBinaries) -ne '2929e42c0')
# The whole separation is one space (`version:` vs `version :`). Pin it from the
# other side too, so a formatting tidy that closes that gap fails HERE rather
# than by shipping the wrong binary under a green delivery log.
AssertEq "A33 a Running Instance line ALONE reads as no version at all" '' `
    (Get-CommitFromVersionText "Running Instance`r`n  - version : 1.4.0-branch-+2929e42c0`r`n  - commit  : 2929e42c0`r`n")
# The banner fallback describes the probed binary too, so a payload whose own
# `Version` block is missing must still never fall through to the running app.
AssertEq "A34 the banner fallback also names the probed binary" '2699f0dd5' `
    (Get-CommitFromVersionText "Ghostty 1.4.0-b-+2699f0dd5`r`nRunning Instance`r`n  - version : 1.4.0-b-+2929e42c0`r`n  - commit  : 2929e42c0`r`n")
# `+version` when nothing is running: the same document minus the decoy, which
# is the shape the pre-T773 fixture (A1) already covered - restated here so the
# pair reads as one comparison rather than two unrelated arms.
AssertEq "A35 no running instance changes nothing about the answer" '2699f0dd5' `
    (Get-CommitFromVersionText "Version`r`n  - version: 1.4.0-b-+2699f0dd5`r`nRunning Instance`r`n  - none detected`r`n")

if ($PureOnly) {
    ""
    Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped -Label 'pure only'
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

# --- B7 the same probe against a real AGENT binary (T281) ---------------------
$haveAgent = Test-Path -LiteralPath $AgentExe -PathType Leaf
if (-not $haveAgent) {
    "  SKIP B7-B10 and E: no agent binary at $AgentExe (build one with 'zig build agent')"
    $script:skipped++
} else {
    $agentInfo = Resolve-GhozttyAgentStamp -Exe $AgentExe
    Assert "B7 the real agent reports a stamp ('$($agentInfo.Stamp)')" ($agentInfo.Stamp -match '^(dev|\d{8}-[0-9a-f]{7,40})$')
    AssertEq "B8 and no reason-it-failed alongside it" '' $agentInfo.Why
    $missingAgent = Resolve-GhozttyAgentStamp -Exe (Join-Path $root 'no-such-agent.exe')
    AssertEq "B9 a missing agent yields no stamp" '' $missingAgent.Stamp
    # The same stub, asked the agent's question: a binary that runs and answers
    # something else must read as unverified rather than as a match.
    $muteAgent = Resolve-GhozttyAgentStamp -Exe $mute
    AssertEq "B10 output from a program that is not the agent yields no stamp" '' $muteAgent.Stamp
}

# --- B11-B13: the stamp actually tracks the tree (T773) -----------------------
# Every gate in this file compares a baked commit against HEAD, so all of them
# are only as good as the bake. T773 suspected the bake had frozen (it had not -
# see A31), but nothing here could have told the difference, so these arms make
# the invariant checkable instead of assumed.
#
# B11 is the mechanism: `src/build/GitVersion.zig` bakes the output of exactly
# this `git log` line at CONFIGURE time, so if it ever stops naming HEAD - a
# GIT_* variable in the build environment, a stale index, a caching build
# runner - every "read the commit back" check in the delivery starts comparing
# a number to itself and passing.
$gitLogHead = ''
try { $gitLogHead = (& git -C $Repo -c log.showSignature=false log --pretty=format:%h -n 1 2>$null | Out-String).Trim() } catch { $gitLogHead = '' }
$repoHead = Get-RepoHeadCommit -Repo $Repo
Assert "B11 the git line GitVersion.detect bakes names HEAD ('$gitLogHead' vs '$repoHead')" `
    (Test-CommitsMatch $gitLogHead $repoHead)

# B12/B13: the exe's stamp must name a real commit ON this branch. A frozen or
# garbled stamp that named nothing (or something unreachable) would sail past
# every prefix comparison in section A.
$exeCommitType = ''
try { $exeCommitType = (& git -C $Repo cat-file -t $exeCommit 2>$null | Out-String).Trim() } catch { $exeCommitType = '' }
AssertEq "B12 the exe's baked commit is a real commit object in this repo" 'commit' $exeCommitType
& git -C $Repo merge-base --is-ancestor $exeCommit HEAD 2>$null
$exeIsAncestor = ($LASTEXITCODE -eq 0)
Assert "B13 and it is reachable from HEAD, not some other branch's" `
    ($exeIsAncestor -or (Test-CommitsMatch $exeCommit $repoHead))

# What is deliberately NOT asserted here: that $Exe's stamp equals HEAD. It is
# the obvious artifact-level freeze check and it cannot be written honestly from
# this side. A file's mtime says when it was installed, not what the tree held
# then, so "built from an older tree" (the defect) and "the tree moved under a
# perfectly good binary" (a `git pull`, and both seats push to this branch) are
# indistinguishable - and the second is routine. A run that turned it red would
# be fabricating a failure about a healthy build, which is the T197 lesson.
# Freshness of a SHIPPED artifact is enforced where the answer matters and the
# tree is known clean: launch-upgrade's STALE STAGING gate, in section C below.

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
# T281: this staging prefix has no agent in it, so the run must claim nothing
# about one - a SKIP, distinct from both a pass and a silence.
Assert "D12b a delivery with no staged agent says so instead of vouching for one" `
    ($dLogText -match 'AGENT VERIFY SKIP: no ghoztty-agent\.exe in staging')

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
"== E: the AGENT binary is read back too (T281)"
# ============================================================================
# T208 gave the delivery a number both ends can compare and then checked exactly
# ONE of the three binaries it ships. The agent is the one with a failure mode
# already on the record: on 2026-07-20 16:10 the rename-aside dance failed
# (`Remove-Item` silently, then `Move-Item` onto an existing name), the swap was
# SKIPPED, a months-old agent stayed on disk - and the run reported UPGRADE OK.
#
# The negative control below reproduces that exactly, by holding the `.bak` open
# with FileShare.None so it can be neither deleted nor renamed.
if (-not $haveAgent) {
    # Deliberately not a second SKIP site: one missing binary is one skip, and
    # the B line above already names this section. Counting it twice would make
    # the verdict overstate what was dropped, which is the same defect T219 is
    # about from the other side.
    "  (E: dropped with B7-B10 above - no agent binary)"
} else {
    $eRoot = Join-Path $root 'agent'
    $eStaging = Join-Path $eRoot 'staging'
    $eInstall = Join-Path $eRoot 'install'
    New-Item -ItemType Directory -Force (Join-Path $eStaging 'bin') | Out-Null
    New-Item -ItemType Directory -Force $eInstall | Out-Null
    Copy-Item -LiteralPath $Exe (Join-Path $eStaging 'bin\ghoztty.exe') -Force
    Copy-Item -LiteralPath $AgentExe (Join-Path $eStaging 'bin\ghoztty-agent.exe') -Force
    $eLog = Join-Path $eRoot 'ghoztty-upgrade.log'
    $eInstalledExe = Join-Path $eInstall 'ghoztty.exe'
    $eInstalledAgent = Join-Path $eInstall 'ghoztty-agent.exe'
    $stagedStamp = (Resolve-GhozttyAgentStamp -Exe (Join-Path $eStaging 'bin\ghoztty-agent.exe')).Stamp
    Assert "E1 the staged agent reports a stamp ('$stagedStamp')" `
        ($stagedStamp -match '^(dev|\d{8}-[0-9a-f]{7,40})$')

    # --- E2 the healthy delivery: the swap happens and is PROVEN -------------
    Set-Content -LiteralPath $eInstalledExe -Encoding ascii -Value $sentinel
    Set-Content -LiteralPath $eInstalledAgent -Encoding ascii -Value $sentinel
    $eOk = Invoke-InSandboxTemp -TempDir $eRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Staging', $eStaging, '-InstallDir', $eInstall, '-WorkingDirectory', $Repo,
        '-ExpectedCommit', $exeCommit, '-NoResume', '-NoExtraInstalls', '-DelaySeconds', '0')
    $eLogText = Get-Content -LiteralPath $eLog -Raw -ErrorAction SilentlyContinue
    AssertEq "E2 a delivery that carries an agent succeeds" 0 $eOk.Code
    Assert "E3 the agent swap happened" ($eLogText -match 'agent exe swapped')
    Assert "E4 AGENT VERIFY read the installed agent back" ($eLogText -match 'AGENT VERIFY OK')
    Assert "E5 and named the stamp now on disk" ($eLogText -match [regex]::Escape($stagedStamp))
    AssertEq "E6 the installed agent really is the staged one" `
        (Get-FileHash -LiteralPath (Join-Path $eStaging 'bin\ghoztty-agent.exe')).Hash `
        (Get-FileHash -LiteralPath $eInstalledAgent).Hash
    Assert "E7 the verdict is OK" ($eLogText -match 'UPGRADE OK')

    # --- E8 NEGATIVE CONTROL: the swap is skipped, exactly as on 2026-07-20 --
    Remove-Item -LiteralPath $eLog -Force -ErrorAction SilentlyContinue
    $eBak = "$eInstalledAgent.bak"
    if (-not (Test-Path -LiteralPath $eBak)) { Set-Content -LiteralPath $eBak -Encoding ascii -Value $sentinel }
    # A stale agent on disk, the way a box that has taken earlier deliveries has.
    Set-Content -LiteralPath $eInstalledAgent -Encoding ascii -Value $sentinel
    $lock = [IO.File]::Open($eBak, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $eSkip = Invoke-InSandboxTemp -TempDir $eRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
            '-Staging', $eStaging, '-InstallDir', $eInstall, '-WorkingDirectory', $Repo,
            '-ExpectedCommit', $exeCommit, '-NoResume', '-NoExtraInstalls', '-DelaySeconds', '0')
    } finally { $lock.Close(); $lock.Dispose() }
    $eLogText = Get-Content -LiteralPath $eLog -Raw -ErrorAction SilentlyContinue
    Assert "E8 the swap really could not happen" ($eLogText -match 'agent exe swap failed')
    AssertEq "E9 THE POINT: the stale agent is still the one on disk" $sentinel `
        ((Get-Content -LiteralPath $eInstalledAgent -Raw).Trim())
    Assert "E10 the read-back caught it" ($eLogText -match 'AGENT VERIFY FAILED')
    AssertEq "E11 so the run is a FAILURE, not an UPGRADE OK over a skipped swap" 1 $eSkip.Code
    Assert "E12 and it does not claim success" (-not ($eLogText -match 'UPGRADE OK'))
    Assert "E13 nor propagate unverified bits onward" ($eLogText -match 'NOT PROPAGATED')
    # The app half still landed - that is what makes this a distinct verdict
    # rather than a general "the delivery broke".
    Assert "E14 while the exe half is still reported as fine" ($eLogText -match 'POST-SWAP VERIFY OK')

    # --- E15 -AppOnly: an older agent on disk is the CONTRACT, not a defect --
    # T525's morning refresh deliberately swaps no agent. If this verified
    # anything, the unattended daily refresh would fail every single morning.
    Remove-Item -LiteralPath $eLog -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $eInstalledAgent -Encoding ascii -Value $sentinel
    $eApp = Invoke-InSandboxTemp -TempDir $eRoot -Argv @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Staging', $eStaging, '-InstallDir', $eInstall, '-WorkingDirectory', $Repo,
        '-ExpectedCommit', $exeCommit, '-NoResume', '-NoExtraInstalls', '-DelaySeconds', '0',
        '-AppOnly', '-DeferMarkerPath', (Join-Path $eRoot 'defer'))
    $eLogText = Get-Content -LiteralPath $eLog -Raw -ErrorAction SilentlyContinue
    Assert "E15 -AppOnly says it swapped no agent" ($eLogText -match 'AGENT VERIFY SKIP: -AppOnly')
    AssertEq "E16 and the run still succeeds over a legitimately older agent" 0 $eApp.Code
    AssertEq "E17 which is still sitting there untouched" $sentinel `
        ((Get-Content -LiteralPath $eInstalledAgent -Raw).Trim())
}

# ============================================================================
"== F: the documented procedure is the whole procedure"
# ============================================================================
# The omission in go.md is what made this defect reachable by a turn that
# followed instructions exactly, so the doc is part of the fix.
$goMd = Get-Content -LiteralPath (Join-Path $Repo 'go.md') -Raw
Assert "F1 go.md says the launcher builds the staging release" ($goMd -match 'BUILDS the staging release')
Assert "F2 go.md names the failure the gate produces" ($goMd -match 'STALE STAGING')
Assert "F3 go.md still carries the build incantation itself" ($goMd -match '--prefix zig-out-release')
Assert "F4 go.md points at this acceptance script" ($goMd -match 'upgrade-staleness\.ps1')

""
if (-not $Keep) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
