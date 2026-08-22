# The upgrade must not FORK the loop (tracker T138).
#
# `upgrade-ghoztty-windows.ps1` was written when killing ghoztty.exe killed the
# Claude session inside it, so it always relaunched `claude --continue` after
# the swap. Session persistence (T89) ended that: the agent owns the PTY, the
# script deliberately never kills it, and the relaunched app RE-ATTACHES the
# pane - so the old session is still there and the relaunch adds a SECOND one
# on the same transcript. Both then pick the same task (user-hit 2026-07-28:
# claude pid 16076 from 08:01 was still alive next to pid 644 started 09:46 by
# the script, and both started building T131).
#
# Sections:
#   A  pure: the resume decision, the prompt derivation, the process-identity
#      guard, and the `+sessions --json` parser. A's parser cases carry the
#      pre-fix oracle: the old line-by-line reader finds 0 sessions in the
#      output the command actually prints, which is why SESSIONS-SURVIVE had
#      been silently skipping since T89h.
#   B  E2E reuse: a live pane plus a live "loop process" -> the script swaps
#      the binaries, brings the app back, types the prompt into the EXISTING
#      pane, and starts nothing new. The headline assert is the fork one:
#      afterwards there is exactly one loop process and no new window.
#   C  E2E relaunch: the loop process is dead -> the old behavior is intact,
#      a window opens running the resume command.
#
# Hermetic: a sandbox install dir + staging dir + LOCALAPPDATA + TEMP under
# %TEMP%\ghoztty-upgrade-nofork-<pid>, so it never touches the user's
# installed release, the real upgrade log, or the real agent. It only ever
# kills processes running out of that sandbox.
#
# The isolation needs one more knob than the other suites: the local agent's
# pipe is `\\.\pipe\ghoztty-agent[-debug]-<USERNAME>`, which is NOT covered by
# a private LOCALAPPDATA. Left alone, this sandbox's app binds (or finds) the
# box's REAL debug agent while reading port.json/sessions.json out of the
# sandbox - a half-isolated state where sessions look dead to `+sessions` and
# restore, and the reuse path can never pass. Overriding $env:USERNAME gives
# the sandbox its own pipe lineage, so no other agent on the box is disturbed
# (the other suites get there by killing every zig-out agent first).
#
#   powershell -NoProfile -File test\win32\upgrade-no-fork.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$PureOnly,
    # Leave the sandbox (and its copy of the upgrade log) on disk for
    # post-mortem instead of deleting it.
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-upgrade-nofork-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

. (Join-Path $Repo 'scripts\loop-session.ps1')

# T199: this script hands the delivery script stand-in INSTALL dirs under its
# own temp roots, and delivering is the job that ENDS by launching the app. Arm
# the teardown for both roots up front so a run that dies mid-way - which is
# exactly when a leak happens - still takes its ghoztty processes with it.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-HarnessGhozttyRoot -Root $root | Out-Null
Register-HarnessGhozttyRoot -Root (Join-Path $env:TEMP "ghoztty-launch-t200-$PID") | Out-Null

# ============================================================================
"== A: the resume decision, in isolation"
# ============================================================================

# --- A1 the `+sessions --json` parser --------------------------------------
# Verbatim shape of what `ghoztty +sessions --json` prints (captured on the box
# 2026-07-29): a pretty-printed ARRAY, not one object per line.
$prettyArray = @'
[
  {
    "id": "59777171fd211b995a94f16163ad83e0",
    "alive": true,
    "attached": true,
    "pid": 732,
    "cwd": null,
    "created_at": 1785370903862
  },
  {
    "id": "95718f1322beebf3f3b45bde63b06ae8",
    "alive": true,
    "attached": true,
    "pid": 792,
    "cwd": "D:\\git\\ghoztty",
    "created_at": 1785372075719
  }
]
'@
$ndjson = '{"id":"aaa","alive":true}' + "`r`n" + '{"id":"bbb","alive":true}'

AssertEq "A1 pretty array yields both session ids" 2 (Get-GhozttySessionIds $prettyArray).Count
AssertEq "A2 pretty array yields the right first id" '59777171fd211b995a94f16163ad83e0' `
    (Get-GhozttySessionIds $prettyArray)[0]
AssertEq "A3 NDJSON still parses (the shape docs/claude/cli.md documents)" 2 (Get-GhozttySessionIds $ndjson).Count
AssertEq "A4 a leading warning line does not defeat the parse" 2 `
    (Get-GhozttySessionIds ("warning: something`r`n" + $prettyArray)).Count
AssertEq "A5 empty output yields no sessions" 0 (Get-GhozttySessionIds '').Count
AssertEq "A6 garbage yields no sessions instead of throwing" 0 (Get-GhozttySessionIds 'not json at all').Count
AssertEq "A7 a single object parses" 1 (Get-GhozttySessionIds '{"id":"solo"}').Count

# The pre-fix oracle: the reader the upgrade script used to have, run over the
# output the command actually prints. It finds nothing - which is exactly what
# "pre-kill agent sessions: 0" meant in the 2026-07-28 log.
$oldParserCount = 0
try {
    $oldParserCount = @($prettyArray -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } |
        ForEach-Object { ($_ | ConvertFrom-Json).id }).Count
} catch { $oldParserCount = 0 }
AssertEq "A8 PRE-FIX ORACLE: the old line-by-line reader found 0 in this output" 0 $oldParserCount

# --- A9 the decision table --------------------------------------------------
AssertEq "A9 -NoResume wins over everything" 'none' `
    (Resolve-LoopResumeAction -NoResume $true -ClaudeAlive $true)
AssertEq "A10 a surviving session is REUSED, not duplicated" 'reuse' `
    (Resolve-LoopResumeAction -ClaudeAlive $true)
AssertEq "A11 a dead session is relaunched (the pre-T138 behavior)" 'relaunch' `
    (Resolve-LoopResumeAction -ClaudeAlive $false)
AssertEq "A12 -ForceRelaunch overrides a surviving session" 'relaunch' `
    (Resolve-LoopResumeAction -ClaudeAlive $true -ForceRelaunch $true)
# T531: -NoResume suppresses the resume TYPING only. When the swap killed a
# running app, the app is restarted (with nothing typed) - the 2026-08-06 09:19
# incident is a -NoResume delivery that killed 2 release processes and left the
# user with no terminal at all.
AssertEq "A12b T531 INCIDENT ORACLE: -NoResume over a killed app RESTARTS it" 'restart-only' `
    (Resolve-LoopResumeAction -NoResume $true -ClaudeAlive $true -KilledApps 2)
AssertEq "A12c -NoResume with nothing killed still does nothing" 'none' `
    (Resolve-LoopResumeAction -NoResume $true -ClaudeAlive $false -KilledApps 0)
AssertEq "A12d a killed app changes nothing WITHOUT -NoResume (reuse keeps winning)" 'reuse' `
    (Resolve-LoopResumeAction -ClaudeAlive $true -KilledApps 2)

# --- A13 the prompt derivation ---------------------------------------------
AssertEq "A13 the prompt comes from the resume command's trailing quotes" 'read go.md and go' `
    (Resolve-LoopResumePrompt -ResumeCommand 'claude --dangerously-skip-permissions --continue "read go.md and go"')
AssertEq "A14 an explicit prompt wins" 'do the thing' `
    (Resolve-LoopResumePrompt -ResumeCommand 'claude --continue "read go.md and go"' -Explicit 'do the thing')
AssertEq "A15 an unquoted resume command falls back to the loop prompt" 'read go.md and go' `
    (Resolve-LoopResumePrompt -ResumeCommand 'claude --continue')

# --- A16 process identity ---------------------------------------------------
$sleeper = Start-Process powershell -PassThru -WindowStyle Hidden `
    -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
Start-Sleep -Milliseconds 400
$stamp = Get-LoopProcStamp $sleeper.Id
Assert "A16 a live process stamps with a name and start time" ($stamp -and $stamp.Name -and $stamp.Start)
Assert "A17 the stamped process reads back as alive" (Test-LoopProcAlive $stamp)
AssertEq "A18 an explicit loop pid is taken as-is" $sleeper.Id (Resolve-LoopClaudePid -Explicit $sleeper.Id)

# The pid-reuse guard: same live pid, different start time -> not our process.
$imposter = [pscustomobject]@{ Pid = $stamp.Pid; Name = $stamp.Name; Start = $stamp.Start.AddMinutes(-10) }
Assert "A19 a recycled pid does NOT read as the process we stamped" (-not (Test-LoopProcAlive $imposter))

Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 600
Assert "A20 a dead process reads as dead" (-not (Test-LoopProcAlive $stamp))
AssertEq "A21 a dead loop process decides RELAUNCH" 'relaunch' `
    (Resolve-LoopResumeAction -ClaudeAlive (Test-LoopProcAlive $stamp))

# --- A22 the readiness probe is BOUNDED (T187) ------------------------------
# The loop stalled on 2026-07-30 because the readiness probe ran `+list` with no
# timeout of its own: one blocking call swallowed the whole 60s window without
# the wait loop ever iterating, and a RUNNING app was reported dead. These drive
# `Invoke-GhozttyListJson` with stand-in "ghoztty" executables, so the probe's
# contract is pinned without needing a real app.
$probeDir = Join-Path $env:TEMP "ghoztty-probe-$PID"
New-Item -ItemType Directory -Force $probeDir | Out-Null

# A hang: sleeps far longer than the bound. The probe must give up ON TIME and
# say so - the pre-fix code blocked here indefinitely.
$hangExe = Join-Path $probeDir 'hang.cmd'
Set-Content -Path $hangExe -Encoding ascii -Value @(
    '@echo off',
    'powershell -NoProfile -Command "Start-Sleep -Seconds 30"'
)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$hang = Invoke-GhozttyListJson -Exe $hangExe -WorkingDirectory $probeDir -TimeoutSec 3
$sw.Stop()
AssertEq "A22 a hung +list yields no payload" '' $hang.Json
Assert "A23 it reports the hang instead of a bare failure: $($hang.Why)" ($hang.Why -match 'hung')
Assert "A24 it returned within its bound, not the callee's ($([int]$sw.Elapsed.TotalSeconds)s)" `
    ($sw.Elapsed.TotalSeconds -lt 12)

# A refusal: the shape of "no running instance". The reason must carry the exit
# code AND the first output line, so the log explains itself next time.
$failExe = Join-Path $probeDir 'fail.cmd'
Set-Content -Path $failExe -Encoding ascii -Value @(
    '@echo off',
    'echo No running Ghoztty instance found.',
    'exit /b 1'
)
$fail = Invoke-GhozttyListJson -Exe $failExe -WorkingDirectory $probeDir -TimeoutSec 5
AssertEq "A25 a refusing +list yields no payload" '' $fail.Json
Assert "A26 the reason carries the exit code: $($fail.Why)" ($fail.Why -match 'exit=1')
Assert "A27 the reason carries what it printed" ($fail.Why -match 'No running Ghoztty instance')

# The success shape: exit 0 AND a payload that actually looks like a window list.
$okExe = Join-Path $probeDir 'ok.cmd'
Set-Content -Path $okExe -Encoding ascii -Value @(
    '@echo off',
    'echo {"success":true,"data":{"windows":[]}}'
)
$ok = Invoke-GhozttyListJson -Exe $okExe -WorkingDirectory $probeDir -TimeoutSec 5
Assert "A28 a healthy +list returns its payload" ($ok.Json -match '"windows"')
AssertEq "A29 and reports no reason to keep waiting" '' $ok.Why

# Exit 0 with junk is NOT ready - the old check would also have rejected it, and
# it must stay rejected or the wait returns garbage to the caller.
$junkExe = Join-Path $probeDir 'junk.cmd'
Set-Content -Path $junkExe -Encoding ascii -Value @('@echo off', 'echo hello')
$junk = Invoke-GhozttyListJson -Exe $junkExe -WorkingDirectory $probeDir -TimeoutSec 5
AssertEq "A30 exit 0 without a window list is not ready" '' $junk.Json

Remove-Item -Recurse -Force $probeDir -ErrorAction SilentlyContinue

# ============================================================================
"== L: the launch contract (T200)"
# ============================================================================
# Out of alphabetical order on purpose: L launches nothing real - stub scripts,
# a private log, and (since T208) a COPY of the built exe that is read for its
# baked version and never executed as an app - so it lives above the -PureOnly
# gate and runs on every invocation.
#
# What it pins: the delivery launch cannot fail silently. On 2026-07-30 a
# boundary delivery was launched detached and never ran. `Start-Process
# -ArgumentList @(...)` does not quote its elements, so the multi-word
# -ResumePrompt was re-tokenized into positional arguments and PowerShell
# rejected the bind BEFORE the script's first statement - nothing logged,
# stderr discarded with the hidden window, and the turn reported success.

$lRoot = Join-Path $env:TEMP "ghoztty-launch-t200-$PID"
$lStaging = Join-Path $lRoot 'staging'
$lInstall = Join-Path $lRoot 'install'
foreach ($d in @($lRoot, $lStaging, $lInstall)) { New-Item -ItemType Directory -Force $d | Out-Null }

# T208: the launcher now verifies that the staged exe carries the commit being
# delivered, so reaching its launch mechanics at all needs a REAL binary in the
# prefix. $lStaging stays deliberately empty (the upgrade script's own
# staging-exe-missing abort is asserted below); this second prefix is the one the
# launcher gets. -SkipBuild + -ExpectedCommit drive the gate without a build -
# the gate itself is the subject of test\win32\upgrade-staleness.ps1, not of this
# suite, which is about the launch hop.
. (Join-Path $Repo 'scripts\delivery-version.ps1')
Assert "L0 the built exe is present (L stages a copy of it)" (Test-Path -LiteralPath $Exe)
$lStagingReal = Join-Path $lRoot 'staging-real'
New-Item -ItemType Directory -Force (Join-Path $lStagingReal 'bin') | Out-Null
Copy-Item -LiteralPath $Exe (Join-Path $lStagingReal 'bin\ghoztty.exe') -Force
$lStagedCommit = (Resolve-GhozttyExeCommit -Exe (Join-Path $lStagingReal 'bin\ghoztty.exe')).Commit
$lFresh = @('-SkipBuild', '-ExpectedCommit', $lStagedCommit)
$lLog = Join-Path $lRoot 'ghoztty-upgrade.log'
$launcher = Join-Path $Repo 'scripts\launch-upgrade.ps1'

# Every child here writes to the sandbox's own upgrade log, never the box's.
function Invoke-InSandboxTemp([string[]]$Argv, [int]$TimeoutMs = 40000) {
    $savedTemp, $savedTmp = $env:TEMP, $env:TMP
    $env:TEMP, $env:TMP = $lRoot, $lRoot
    try {
        $o = Join-Path $lRoot "child-$([guid]::NewGuid().ToString('N').Substring(0,8)).out"
        $e = "$o.err"
        $p = Start-Process powershell -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e -ArgumentList $Argv
        # Cache .Handle BEFORE the child exits or .ExitCode reads back empty
        # (the trap that fabricated six failures in the T147 harness).
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
        return [pscustomobject]@{
            Code   = $p.ExitCode
            Out    = (Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue)
            Err    = (Get-Content -LiteralPath $e -Raw -ErrorAction SilentlyContinue)
        }
    } finally { $env:TEMP, $env:TMP = $savedTemp, $savedTmp }
}
function Get-LMarkerCount {
    if (-not (Test-Path -LiteralPath $lLog)) { return 0 }
    @(Select-String -LiteralPath $lLog -Pattern '=== upgrade start' -SimpleMatch).Count
}
function Get-LLog { Get-Content -LiteralPath $lLog -Raw -ErrorAction SilentlyContinue }

$upgradeScript = Join-Path $Repo 'scripts\upgrade-ghoztty-windows.ps1'
# Hostile on purpose: a bare `-` (an empty parameter name - this is the exact
# token that killed the real delivery), an apostrophe, quotes, %VARS%,
# parentheses, and a slash command at the front.
$hostile = "/reset-context Verify (1) the log, (2) +version. It did not take - investigate %TEMP%\ghoztty-upgrade.log before moving on; the agent's pid `"27568`" is the tell. Then read go.md and go"

# --- L1 PRE-FIX ORACLE: the same prompt through argv still gets shredded -----
# Not a regression test of the fix - a permanent demonstration of WHY the fix is
# a file. No amount of care in this script can make argv safe for free text.
$before = Get-LMarkerCount
$viaArgv = Invoke-InSandboxTemp @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript,
    '-Staging', $lStaging, '-InstallDir', $lInstall, '-NoResume', '-ResumePrompt', $hostile)
Assert "L1 PRE-FIX ORACLE: a hostile prompt through argv fails (exit $($viaArgv.Code))" ($viaArgv.Code -ne 0)
AssertEq "L2 PRE-FIX ORACLE: and the script never ran, so nothing was logged" $before (Get-LMarkerCount)

# The quieter half of the same disease, and the reason PositionalBinding=$false
# matters: prose WITHOUT a bare `-` used to bind cleanly to real parameters
# ($Staging='Verify', $LoopPaneId='did') and the script carried on with them.
# Now it is refused by name.
$before = Get-LMarkerCount
$sneaky = Invoke-InSandboxTemp @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript,
    '-Staging', $lStaging, '-InstallDir', $lInstall, '-NoResume',
    '-ResumePrompt', 'Verify the delivery. It did not take, investigate.')
Assert "L3 PRE-FIX ORACLE: prose that once bound SILENTLY is now rejected (exit $($sneaky.Code))" ($sneaky.Code -ne 0)
Assert "L3b the rejection names a word from the prose" ($sneaky.Err -match 'the' -or $sneaky.Err -match 'positional')
AssertEq "L3c and it never reached the script body" $before (Get-LMarkerCount)

# --- L4 the fix: the prompt travels as a file -------------------------------
$promptFile = Join-Path $lRoot 'prompt.txt'
[IO.File]::WriteAllText($promptFile, $hostile, (New-Object Text.UTF8Encoding($false)))
$before = Get-LMarkerCount
# A staging DIRECTORY that exists but holds no bin\ghoztty.exe: the script gets
# far enough to read and log the prompt, then aborts before anything is killed.
$viaFile = Invoke-InSandboxTemp @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript,
    '-Staging', $lStaging, '-InstallDir', $lInstall, '-NoResume', '-ResumePromptFile', $promptFile)
$lLogText = Get-LLog
AssertEq "L4 the script ran and logged its start" ($before + 1) (Get-LMarkerCount)
Assert "L5 it reported reading the prompt from the file" ($lLogText -match 'resume prompt read from file')
Assert "L6 the prompt round-tripped byte-for-byte, hyphen and quotes included" `
    ($lLogText -match [regex]::Escape("resumePrompt=[$hostile]"))
Assert "L7 the character count in the log matches the source" `
    ($lLogText -match "resume prompt read from file \($($hostile.Length) chars\)")
Assert "L8 it aborted on the empty staging dir instead of killing anything" `
    ($lLogText -match 'ABORT: staging exe not found')

# --- L9 a stray positional argument is LOUD, not silently bound -------------
# Pre-fix, `Verify` bound to $Staging and `did` to $LoopPaneId while the script
# carried on. [CmdletBinding()] makes that a hard error.
$before = Get-LMarkerCount
$stray = Invoke-InSandboxTemp @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript,
    '-Staging', $lStaging, '-NoResume', 'anUnexpectedPositionalArgument')
Assert "L9 a stray positional argument is rejected (exit $($stray.Code))" ($stray.Code -ne 0)
Assert "L10 the error names the argument it refused" ($stray.Err -match 'anUnexpectedPositionalArgument')
AssertEq "L11 and it never reached the script body" $before (Get-LMarkerCount)

# --- L12 a mis-bound directory aborts before anything destructive -----------
$before = Get-LMarkerCount
$badDir = Invoke-InSandboxTemp @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript,
    '-Staging', (Join-Path $lRoot 'no-such-dir'), '-InstallDir', $lInstall, '-NoResume')
Assert "L12 a non-existent -Staging aborts (exit $($badDir.Code))" ($badDir.Code -ne 0)
Assert "L13 and says which parameter was wrong" ((Get-LLog) -match 'ABORT: -Staging is not an existing directory')
$badInstall = Invoke-InSandboxTemp @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgradeScript,
    '-Staging', $lStaging, '-InstallDir', (Join-Path $lRoot 'no-such-install'), '-NoResume')
Assert "L14 a non-existent -InstallDir aborts too (the kill is scoped to it)" ($badInstall.Code -ne 0)
Assert "L15 and says so" ((Get-LLog) -match 'ABORT: -InstallDir is not an existing directory')

# --- L16 the launcher gates on OUTPUT, not on Start-Process returning -------
# A stub that exits before logging is the negative control for the whole point
# of launch-upgrade.ps1: this is what a silently-dead delivery looks like.
$stubDead = Join-Path $lRoot 'stub-dead.ps1'
Set-Content -LiteralPath $stubDead -Encoding ascii -Value @(
    'param([string]$Staging,[string]$ResumePromptFile,[int]$DelaySeconds,[int]$LoopClaudePid)',
    '[Console]::Error.WriteLine("stub: died before logging")',
    'exit 3'
)
# -PromptFile, not -Prompt: across a command line the launcher's own -Prompt is
# subject to the very shredding it exists to prevent. Writing this test the
# other way is what proved it (the free text bound 'arg' to -LoopClaudePid).
$dead = Invoke-InSandboxTemp (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-PromptFile', $promptFile, '-Staging', $lStagingReal, '-UpgradeScript', $stubDead,
    '-StartTimeoutSeconds', '6') + $lFresh)
Assert "L16 NEGATIVE CONTROL: a child that dies before logging fails the launch (exit $($dead.Code))" ($dead.Code -eq 1)
Assert "L17 it says the upgrade did NOT happen" ($dead.Out -match 'LAUNCH FAILED')
Assert "L18 it surfaces the child's stderr instead of swallowing it" ($dead.Out -match 'died before logging')

# The healthy shape: a stub that logs the marker the way the real script does.
$stubOk = Join-Path $lRoot 'stub-ok.ps1'
Set-Content -LiteralPath $stubOk -Encoding ascii -Value @(
    'param([string]$Staging,[string]$ResumePromptFile,[int]$DelaySeconds,[int]$LoopClaudePid)',
    '$log = Join-Path $env:TEMP "ghoztty-upgrade.log"',
    'Add-Content $log "$(Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') === upgrade start (stub)"',
    'Add-Content $log "stub read prompt: $([IO.File]::ReadAllText($ResumePromptFile))"',
    'Start-Sleep -Seconds 2'
)
$before = Get-LMarkerCount
$live = Invoke-InSandboxTemp (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-PromptFile', $promptFile, '-Staging', $lStagingReal, '-UpgradeScript', $stubOk,
    '-StartTimeoutSeconds', '20') + $lFresh)
AssertEq "L19 a child that logs its start reports LAUNCH OK" 0 $live.Code
Assert "L20 and says so on stdout" ($live.Out -match 'LAUNCH OK')
AssertEq "L21 the marker really is in the log" ($before + 1) (Get-LMarkerCount)
Assert "L22 the hostile prompt reached the child intact through the file" `
    ((Get-LLog) -match [regex]::Escape("stub read prompt: $hostile"))

# --- L23 the launcher refuses to put free text on a command line ------------
# A path with a space is the realistic way a whitespace-bearing element reaches
# $argv. This one must be driven IN-PROCESS - which is also the documented way
# to call the launcher - because across a command line the spaces would be
# shredded before the guard could ever see them (writing it the other way is
# what proved the point: the launcher rejected the bind, exit 1, not the guard).
$spacedDir = Join-Path $lRoot 'staging with spaces'
New-Item -ItemType Directory -Force $spacedDir | Out-Null
$savedTemp, $savedTmp = $env:TEMP, $env:TMP
$env:TEMP, $env:TMP = $lRoot, $lRoot
try {
    # NOT `*> file` (T883's class): Fail-Launch's [Console]::Error copy
    # bypasses PS streams entirely and, measured 2026-08-16, the Write-Host
    # copy never reaches the redirect file either, so the capture read '' and
    # L24 failed against a refusal that was in fact printed. Merging every
    # stream and stringifying record-by-record keeps the text on any host.
    $wsText = (& $launcher -PromptFile $promptFile -Staging $spacedDir -UpgradeScript $stubOk *>&1 |
        ForEach-Object { "$_" } | Out-String)
    $wsCode = $LASTEXITCODE
} finally { $env:TEMP, $env:TMP = $savedTemp, $savedTmp }
Assert "L23 an argv element containing whitespace is refused (exit $wsCode)" ($wsCode -eq 2)
Assert "L24 and it explains why (re-tokenization)" ($wsText -match 're-tokenized')

# The same in-process call with a clean staging dir is the documented happy
# path, and the only one where -Prompt (free text, no file) is safe.
$okOut = Join-Path $lRoot 'inproc.out'
$before = Get-LMarkerCount
$env:TEMP, $env:TMP = $lRoot, $lRoot
try {
    & $launcher -Prompt $hostile -Staging $lStagingReal -UpgradeScript $stubOk -StartTimeoutSeconds 20 `
        -SkipBuild -ExpectedCommit $lStagedCommit *> $okOut
    $okCode = $LASTEXITCODE
} finally { $env:TEMP, $env:TMP = $savedTemp, $savedTmp }
AssertEq "L27 the documented in-process call with free text succeeds" 0 $okCode
Assert "L28 and the free text survived without a file of the caller's own" `
    ((Get-LLog) -match [regex]::Escape("stub read prompt: $hostile"))
AssertEq "L29 it really started something (a new marker)" ($before + 1) (Get-LMarkerCount)

# And the launcher's own binding is hardened the same way: free text through
# argv must be REFUSED, never half-bound to -LoopClaudePid.
$before = Get-LMarkerCount
$launcherShred = Invoke-InSandboxTemp @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-Prompt', 'some free text that will be shredded', '-Staging', $lStaging, '-UpgradeScript', $stubOk)
Assert "L25 the launcher rejects a shredded -Prompt instead of half-binding it" ($launcherShred.Code -ne 0)
AssertEq "L26 and it did not start an upgrade off a mangled command line" $before (Get-LMarkerCount)

if (-not $Keep) { Remove-Item -Recurse -Force $lRoot -ErrorAction SilentlyContinue }

# ============================================================================
"== M: the PANE-transport contract (T210)"
# ============================================================================
# L covers the LAUNCH hop; this is the hop after it. The prompt reached the
# upgrade script intact via -ResumePromptFile and was then handed to
# `+send-keys` as a positional argument, where PowerShell 5.1's native-command
# quoting shredded it: the pane got run-together prose, `/reset-context` was not
# at the start of a line, the reset silently never fired, and the session ran to
# ~250k. So the same rule applies one hop down - a file, never argv.

$mPrompt = '/reset-context settle the "DWM/PrintWindow" question. Then read go.md and go'

# --- M1 New-LoopPromptFile writes the bytes EXACTLY -------------------------
$mFile = New-LoopPromptFile -Text $mPrompt -Tag 'nofork-m'
$mBytes = [IO.File]::ReadAllBytes($mFile)
$mBack = [IO.File]::ReadAllText($mFile)
Assert "M1 the prompt file round-trips byte-for-byte, quotes included" ($mBack -ceq $mPrompt)
AssertEq "M2 no trailing newline (a stray CR would submit the prompt early)" $mPrompt.Length $mBytes.Length
Assert "M3 no BOM (the CLI sends the bytes verbatim, BOM included)" `
    (-not ($mBytes.Length -ge 3 -and $mBytes[0] -eq 0xEF -and $mBytes[1] -eq 0xBB -and $mBytes[2] -eq 0xBF))
Remove-Item -LiteralPath $mFile -ErrorAction SilentlyContinue

# --- M4 the pane-tail oracle ------------------------------------------------
# A TUI wraps the prompt inside its input box, so the tail holds the same
# characters with newlines, box borders and a marker injected. An exact IndexOf
# can never match a prompt longer than the pane is wide - which is why the old
# echo check "failed" on healthy deliveries and was written as a shrug rather
# than a gate.
$wrapped = @'
| /reset-context settle the "DWM/PrintWindow" question. Then    |
| read go.md and go                                             |
'@
Assert "M4 a prompt wrapped across input-box lines still matches" `
    (Test-LoopPromptArrived -Tail $wrapped -Text $mPrompt)
Assert "M5 PRE-FIX ORACLE: a plain IndexOf does NOT match the same tail" `
    ($wrapped.IndexOf($mPrompt, [StringComparison]::OrdinalIgnoreCase) -lt 0)

# The mangling the gate has to catch: this is the 2026-07-30 field text, the
# TAIL of the prompt with its head gone and its words run together.
$mangled = "come after.read go.md and go"
Assert "M6 THE GATE: the mangled field text does NOT satisfy the check" `
    (-not (Test-LoopPromptArrived -Tail $mangled -Text $mPrompt))
Assert "M7 quotes stripped by argv re-tokenization does NOT satisfy it either" `
    (-not (Test-LoopPromptArrived -Tail ($mPrompt -replace '"', '') -Text $mPrompt))
Assert "M8 an empty tail does not satisfy it" (-not (Test-LoopPromptArrived -Tail '' -Text $mPrompt))
Assert "M9 an empty prompt is never 'arrived' (a no-op send must not read as OK)" `
    (-not (Test-LoopPromptArrived -Tail $wrapped -Text ''))

# Both sides go through the same reduction, so a prompt that itself contains the
# characters the reduction drops still matches.
Assert "M10 a prompt containing | and > still matches its own echo" `
    (Test-LoopPromptArrived -Tail 'D:\x> run a | b > out.txt' -Text 'run a | b > out.txt')
Assert "M11 and a DIFFERENT command in the same tail does not" `
    (-not (Test-LoopPromptArrived -Tail 'D:\x> run a | b > out.txt' -Text 'run c | d > out.txt'))

# --- M12 the send site uses the file transport ------------------------------
# Grep the script, because this is the one property no unit can observe: the
# argument that carries the prompt must be a --keys-file=, and the prompt must
# not appear as a bare positional argument anywhere near +send-keys.
$upgradeSrc = Get-Content -LiteralPath $upgradeScript -Raw
Assert "M12 the reuse path picks its transport with New-LoopSendKeysText" `
    ($upgradeSrc -match 'New-LoopSendKeysText[^\r\n]*-Text \$prompt')
Assert "M13 and no longer passes `$prompt through argv unconditionally" `
    (-not ($upgradeSrc -match '\+send-keys[^\r\n]*\s\$prompt(\s|")'))
# The shrug's own log tag, not the prose around it: the explanation of WHY it
# was wrong quotes the old message, so a grep for the message would match the
# comment that documents its removal.
Assert "M14 the RESUME-REUSE SENT shrug branch is gone" `
    (-not ($upgradeSrc -match "Log `"RESUME-REUSE SENT"))
Assert "M15 a prompt that did not arrive is a FAIL, not an UPGRADE OK" `
    ($upgradeSrc -match 'RESUME-REUSE FAIL: the prompt did not arrive intact')

$watchdogSrc = Get-Content -LiteralPath (Join-Path $Repo 'scripts\go-loop-watchdog.ps1') -Raw
Assert "M16 the watchdog's nudge picks its transport with New-LoopSendKeysText" `
    ($watchdogSrc -match 'New-LoopSendKeysText')
Assert "M17 and no longer passes `$ResumePrompt through argv unconditionally" `
    (-not ($watchdogSrc -match "'\+send-keys'[^\r\n]*\`$ResumePrompt"))

# --- M18 the capability probe -----------------------------------------------
# The flag is useless - worse, actively harmful - if the exe on the box predates
# it: an older `+send-keys` treats `--keys-file=C:\...` as ordinary TEXT and
# types the PATH into the pane, which is the T241 failure recreated by its own
# fix. These scripts drive whichever ghoztty is INSTALLED, and the watchdog is a
# long-lived Run-key process, so "the exe is my build" is never a safe
# assumption. Measured when this shipped: the installed release did not support
# the flag.
Assert "M18 the built exe advertises --keys-file, so the probe can see it" `
    (Test-LoopKeysFileSupported -Exe $Exe)
$notAnExe = Join-Path $env:TEMP "t210-not-an-exe-$PID.txt"
[IO.File]::WriteAllText($notAnExe, 'not an executable')
Assert "M19 an exe that cannot answer the probe reads as UNSUPPORTED, not as a crash" `
    (-not (Test-LoopKeysFileSupported -Exe $notAnExe))
Remove-Item -LiteralPath $notAnExe -ErrorAction SilentlyContinue

$supported = New-LoopSendKeysText -Exe $Exe -Text $mPrompt -Tag 'nofork-m18'
Assert "M20 a supporting exe gets the file transport" `
    ($supported.Args.Count -eq 1 -and $supported.Args[0] -like '--keys-file=*')
Assert "M21 and it is not flagged degraded" (-not $supported.Degraded)
Assert "M22 the file it names holds the prompt verbatim" `
    ([IO.File]::ReadAllText($supported.File) -ceq $mPrompt)
Remove-Item -LiteralPath $supported.File -ErrorAction SilentlyContinue

$degraded = New-LoopSendKeysText -Exe 'C:\no-such-ghoztty-t210.exe' -Text $mPrompt -Tag 'nofork-m19'
Assert "M23 a non-supporting exe falls back to argv rather than typing the flag" `
    ($degraded.Args.Count -eq 1 -and $degraded.Args[0] -ceq $mPrompt)
Assert "M24 the fallback SAYS it is degraded so the log can too" $degraded.Degraded
AssertEq "M25 and it leaves no file to clean up" '' $degraded.File

if ($PureOnly) {
    ""
    Write-TestVerdict -Pass $script:passes -Fail $script:failures
}

# ============================================================================
# E2E scaffolding: a complete sandbox install the script can upgrade.
# ============================================================================
$installDir = Join-Path $root 'install'
$stagingDir = Join-Path $root 'staging'
$workDir = Join-Path $root 'work'
$stateDir = Join-Path $root 'state'
$tempDir = Join-Path $root 'temp'
$sandboxExe = Join-Path $installDir 'ghoztty.exe'
$upgrade = Join-Path $Repo 'scripts\upgrade-ghoztty-windows.ps1'
$upgradeLog = Join-Path $tempDir 'ghoztty-upgrade.log'

# The agent takes a per-user, per-lineage single-instance guard (a named
# mutex), so a debug agent already running on the box makes the sandbox's own
# agent exit 183 - "another instance is already running" - and the sandbox
# silently runs WITHOUT session persistence, which no amount of private state
# can fix. Clear the debug lineage first, exactly as the other suites do.
# Matched on `local-agent-debug` in the command line, so the user's RELEASE
# agent (`local-agent`, holding their real panes) is never a candidate.
function Stop-DebugLineage {
    # cleanslate-exempt: also takes this run's SANDBOX copy under $root, which the
    # shared kill (exact-exe on the repo zig-out) cannot see
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and (
                $_.ExecutablePath -like '*zig-out*' -or
                $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase))
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # cleanslate-exempt: matched on the debug STATE dir, so the user's release
    # agent - same image name, holding their real panes - is never a candidate
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*local-agent-debug*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

# Only ever touch processes running out of the sandbox.
function Stop-SandboxProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        # cleanslate-exempt: the sandbox copy under $root only - never the repo build
        Get-CimInstance Win32_Process -Filter "Name='$n'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 900
}
# The resume command writes a file. A file is a durable oracle - a process
# check can miss a command that already exited, and "did the relaunch run?" has
# to be answerable minutes later.
function New-ResumeCommand($markerFile) { return "cmd /c echo started > $markerFile" }
function Run-Sandbox($argsLine, $out, $timeoutSec = 30) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru -WorkingDirectory $workDir `
        -ArgumentList "/c `"`"$sandboxExe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }
function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Get-Tree($tag) {
    $f = Join-Path $root "list-$tag.json"
    if ((Run-Sandbox '+list --json' $f 25) -ne 0) { return $null }
    try { return (Out-Text $f | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function Pane-In($tree, $target) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
function Wait-Windows($tag, $count, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $tree = $null
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tag
        if ((Windows-Of $tree).Count -ge $count) { return $tree }
        Start-Sleep -Milliseconds 800
    }
    return $tree
}
# Run the upgrade script synchronously against the sandbox, from a launcher
# directory it must not leak (the T132 trap), and keep its log per section.
# Every argument with whitespace is quoted: -ArgumentList joins the array with
# spaces, so an unquoted 'cmd /c echo ...' silently becomes four arguments and
# -ResumeCommand ends up as 'cmd'.
function Invoke-Upgrade($tag, $extraArgs, $timeoutSec = 300) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upgrade,
        '-Staging', $stagingDir, '-InstallDir', $installDir,
        '-WorkingDirectory', $workDir, '-DelaySeconds', '1') + $extraArgs
    $quoted = $a | ForEach-Object {
        $s = [string]$_
        if ($s -match '[\s&<>|]') { '"' + $s + '"' } else { $s }
    }
    Remove-Item $upgradeLog -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru `
        -WorkingDirectory 'C:\Windows\System32' -ArgumentList $quoted
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    $code = $null
    if ($p.WaitForExit($timeoutSec * 1000)) { $code = $p.ExitCode }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path $upgradeLog) { Copy-Item $upgradeLog (Join-Path $root "upgrade-$tag.log") -Force }
    return $code
}

Stop-DebugLineage
Stop-SandboxProcs
foreach ($d in @($installDir, (Join-Path $stagingDir 'bin'), $workDir, $tempDir,
                 (Join-Path $stateDir 'ghoztty\local-agent-debug'))) {
    New-Item -ItemType Directory -Force $d | Out-Null
}
Assert "B0a the built exe exists" (Test-Path $Exe)
Assert "B0b the built agent exists" (Test-Path $AgentExe)
Copy-Item $Exe $installDir -Force
Copy-Item $AgentExe $installDir -Force
Copy-Item $Exe (Join-Path $stagingDir 'bin') -Force
Copy-Item $AgentExe (Join-Path $stagingDir 'bin') -Force

$savedLocalAppData = $env:LOCALAPPDATA
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedUser = $env:USERNAME
$savedSuffix = $env:GHOZTTY_PIPE_SUFFIX
$env:LOCALAPPDATA = $stateDir
$env:TEMP = $tempDir
$env:TMP = $tempDir
$env:GHOSTTY_LOCAL_AGENT_BIN = (Join-Path $installDir 'ghoztty-agent.exe')
$env:USERNAME = "nofork$PID"   # own agent pipe lineage; see the header
# T441 - the load-bearing one, and the USERNAME override above is NOT a
# substitute for it. USERNAME only moves the DERIVED endpoint, and derivation is
# the LAST of three sources: `$GHOZTTY_PIPE_SUFFIX` (a caller aiming on purpose)
# beats the pane's baked `$GHOZTTY_IPC_SOCKET`, which beats derivation
# (src/os/ipc_client.zig clientEndpointPathFrom). Run from one of the user's own
# Ghoztty panes - which is how this suite is always run - every CLI call here
# inherits the user's baked endpoint and drives the user's INSTALLED release.
# Measured 2026-08-03: sections B and E typed their fixture prompts, and E1's
# `powershell -File ...\swallow.ps1`, into the loop's live Claude pane, where
# they arrived as chat messages.
$env:GHOZTTY_PIPE_SUFFIX = "-nofork$PID"

try {
    # ========================================================================
    "== B: a surviving session is REUSED, not forked"
    # ========================================================================
    $codeB = Run-Sandbox "+new-window --target=main --working-directory=$workDir" `
        (Join-Path $root 'new-window.txt') 60
    Assert "B1 the sandbox instance launched and took a window" ($codeB -eq 0)
    $treeB = Wait-Windows 'b0' 1 60
    $paneB = Pane-In $treeB 'main'
    Assert "B2 the loop's pane exists and is addressable" ($null -ne $paneB -and $paneB.id)
    $paneId = if ($paneB) { [string]$paneB.id } else { '' }
    $windowsBefore = (Windows-Of $treeB).Count

    # T441 - the isolation assert, and it comes BEFORE anything is typed. Every
    # later section drives `$paneId` with `+send-keys`, including a line that
    # starts a process; if the instance answering is the user's, those land in
    # the user's terminal. The caller's own pane is the tell: it can only be in
    # this tree if we are talking to the app the caller is sitting in.
    $callerPane = $env:GHOZTTY_PANE_ID
    [void](Get-Tree 'b0iso')
    $isoRaw = Out-Text (Join-Path $root 'list-b0iso.json')
    $leak = $callerPane -and ($isoRaw -match [regex]::Escape($callerPane))
    Assert "B2a the answering instance is the SANDBOX, not the caller's own app" (-not $leak)
    if ($leak) {
        "  ABORTING: the sandbox is not isolated; refusing to type into a live pane"
        throw 'isolation check failed'
    }

    # Guard against a silently non-persistent sandbox: without an agent the
    # pane dies with the app, "no fork" would pass for the wrong reason, and
    # this whole section would be theatre.
    $portFile = Join-Path $stateDir 'ghoztty\local-agent-debug\port.json'
    $agentUp = $false
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Path $portFile) { $agentUp = $true; break }
        Start-Sleep -Milliseconds 800
    }
    Assert "B2b the sandbox pane really is agent-backed (port.json written)" $agentUp

    # The stand-in for the loop's claude: a live process the script is told to
    # treat as the launching session. Using a stand-in (rather than a real
    # `claude`) is what makes the decision testable - the script's own
    # -LoopClaudePid parameter exists for exactly this.
    $loop = Start-Process powershell -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 600'
    Start-Sleep -Milliseconds 400
    Assert "B3 the stand-in loop process is running" ($null -ne (Get-Process -Id $loop.Id -ErrorAction SilentlyContinue))

    # If the script relaunches, THIS is what it would run. Nothing in the reuse
    # path may run it - the marker file must never appear.
    $markerB = Join-Path $root 'relaunched-b.marker'
    # T210: a HOSTILE prompt, and it travels by file on both hops. The old
    # single-token 'T138-REUSE-PROMPT' could not fail - it has no quotes, so argv
    # delivered it intact and the E2E was blind to the defect that mattered.
    # -ResumePromptFile for the parameter hop (L1 proves argv cannot carry this),
    # and the script's own --keys-file for the pane hop.
    $promptB = 'T210-REUSE settle the "capture" question, then read go.md and go'
    $promptFileB = Join-Path $root 'prompt-b.txt'
    [IO.File]::WriteAllText($promptFileB, $promptB, (New-Object Text.UTF8Encoding($false)))
    $codeU = Invoke-Upgrade 'b' @('-LoopClaudePid', $loop.Id, '-LoopPaneId', $paneId,
        '-ResumePromptFile', $promptFileB, '-AllowPlainResume',
        '-ResumeCommand', (New-ResumeCommand $markerB))
    AssertEq "B4 the upgrade script exited 0" 0 $codeU

    $logB = Out-Text (Join-Path $root 'upgrade-b.log')
    Assert "B5 the script decided to REUSE the surviving session" ($logB -match 'resume decision: reuse')
    Assert "B6 the surviving session was recorded before the kill" ($logB -match 'loop session: claude pid=')
    Assert "B7 it never ran the relaunch command" (-not ($logB -match 'relaunch:'))
    Assert "B8 THE FORK ASSERT: nothing new was started for the resume" (-not (Test-Path $markerB))
    Assert "B9 the loop process is still the same one, still alive" `
        ($null -ne (Get-Process -Id $loop.Id -ErrorAction SilentlyContinue))

    # The `+sessions --json` probe: pre-fix this logged 0 sessions and the
    # assert skipped, on a box that had live ones.
    Assert "B10 the pre-kill session probe SAW the agent's sessions" `
        ($logB -match 'pre-kill agent sessions: [1-9]')
    Assert "B11 the sessions-survive assert ran and passed" ($logB -match 'SESSIONS-SURVIVE OK')

    $treeB2 = Wait-Windows 'b1' 1 90
    $paneB2 = Pane-In $treeB2 'main'
    Assert "B12 the app came back with the loop's window re-attached" ($null -ne $paneB2)
    AssertEq "B13 it is the SAME pane (re-attached, not recreated)" $paneId ([string]$paneB2.id)
    AssertEq "B14 no extra window was opened" $windowsBefore (Windows-Of $treeB2).Count

    # The prompt must actually reach the pane, INTACT. The pane runs cmd.exe, so
    # typed characters echo at its prompt - proof of delivery, not of intent.
    $tail = ''
    for ($i = 0; $i -lt 12; $i++) {
        Run-Sandbox "+read --name=$paneId --lines=60" (Join-Path $root 'read-b.txt') 25 | Out-Null
        $tail = Out-Text (Join-Path $root 'read-b.txt')
        if (Test-LoopPromptArrived -Tail $tail -Text $promptB) { break }
        Start-Sleep -Milliseconds 900
    }
    Assert "B15 the resume prompt was typed into the SURVIVING pane, quotes and all" `
        (Test-LoopPromptArrived -Tail $tail -Text $promptB)
    Assert "B15b the quotes really survived (the pre-T210 argv hop dropped them)" `
        ($tail -match '"capture"')
    # T210: OK now MEANS verified. There is no SENT-but-unseen outcome any more -
    # that branch reported UPGRADE OK over a delivery that had not happened.
    Assert "B16 the script logged the delivery as verified" `
        ($logB -match 'RESUME-REUSE OK: .*delivered AND submitted')
    Assert "B16b it verified BEFORE submitting (after a submit the evidence races the session)" `
        ($logB -match 'verified in the pane before Enter')
    Assert "B16c and it never took the old 'sent but not seen' branch" `
        (-not ($logB -match 'RESUME-REUSE SENT'))

    # ========================================================================
    "== E: THE GATE - a prompt that does not arrive is not UPGRADE OK (T210)"
    # ========================================================================
    # The negative control for B16. Without it, "the gate is a gate" rests on a
    # source grep: M15 proves the FAIL branch is written, not that it is
    # reachable or that it stops the OK. So put the pane in the exact state the
    # field failure produced - the send succeeds and the text does not appear -
    # and require the script to fail.
    #
    # A swallow process is how to produce that state honestly:
    # [Console]::ReadKey($true) consumes a key WITHOUT echoing it, so
    # `+send-keys` reports success and the pane tail never shows the prompt.
    # That is precisely the old branch's premise ("the TUI may have consumed
    # it") - which used to end in UPGRADE OK.
    $swallowPath = Join-Path $workDir 'swallow.ps1'
    [IO.File]::WriteAllText($swallowPath, @'
"SWALLOW-READY"
$deadline = (Get-Date).AddSeconds(240)
while ((Get-Date) -lt $deadline) {
    if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } else { Start-Sleep -Milliseconds 15 }
}
'@, (New-Object Text.UTF8Encoding($false)))
    Run-Sandbox "+send-keys --target=$paneId `"powershell -NoProfile -File $swallowPath`" Enter" `
        (Join-Path $root 'send-swallow.txt') 30 | Out-Null
    $swallowUp = $false
    for ($i = 0; $i -lt 20; $i++) {
        Run-Sandbox "+read --name=$paneId --lines=20" (Join-Path $root 'read-swallow.txt') 25 | Out-Null
        if ((Out-Text (Join-Path $root 'read-swallow.txt')) -match 'SWALLOW-READY') { $swallowUp = $true; break }
        Start-Sleep -Milliseconds 700
    }
    Assert "E1 the pane is swallowing input without echoing it" $swallowUp

    $promptE = 'T210-GATE this prompt will be swallowed, so the run must FAIL'
    $promptFileE = Join-Path $root 'prompt-e.txt'
    [IO.File]::WriteAllText($promptFileE, $promptE, (New-Object Text.UTF8Encoding($false)))
    $markerE = Join-Path $root 'relaunched-e.marker'
    $codeE = Invoke-Upgrade 'e' @('-LoopClaudePid', $loop.Id, '-LoopPaneId', $paneId,
        '-ResumePromptFile', $promptFileE, '-AllowPlainResume',
        '-ResumeCommand', (New-ResumeCommand $markerE))
    $logE = Out-Text (Join-Path $root 'upgrade-e.log')
    Assert "E2 the upgrade script exited NONZERO (was: exit 0 with UPGRADE OK)" ($codeE -ne 0)
    Assert "E3 and said the prompt did not arrive" `
        ($logE -match 'RESUME-REUSE FAIL: the prompt did not arrive intact')
    # Matched on the success TAG (`UPGRADE OK (<reason>)`), which every one of the
    # script's five success sites emits, rather than the bare words: a failure
    # message that mentions them would otherwise satisfy this by accident, and
    # the first version of this assert did exactly that.
    Assert "E4 THE GATE ASSERT: it did NOT report UPGRADE OK" (-not ($logE -match 'UPGRADE OK \('))
    Assert "E5 the +send-keys itself succeeded, so the GATE is what failed the run" `
        (-not ($logE -match 'RESUME-REUSE FAIL: \+send-keys'))
    Assert "E6 it did not fork a session to compensate" (-not (Test-Path $markerE))
    Assert "E7 the loop process is still the same one, still alive" `
        ($null -ne (Get-Process -Id $loop.Id -ErrorAction SilentlyContinue))

    # Free the pane again for C/D.
    Run-Sandbox "+send-keys --target=$paneId C-c" (Join-Path $root 'send-swallow-stop.txt') 30 | Out-Null
    Start-Sleep -Seconds 2

    # ========================================================================
    "== C: with nothing left alive, the relaunch behavior is intact"
    # ========================================================================
    Stop-Process -Id $loop.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
    Assert "C1 the loop process is gone" ($null -eq (Get-Process -Id $loop.Id -ErrorAction SilentlyContinue))

    # `+new-window --target=main` focuses an existing 'main' instead of
    # creating one, so clear it: the relaunch case is "nothing survived".
    Run-Sandbox '+close --target=main' (Join-Path $root 'close-main.txt') 30 | Out-Null
    Start-Sleep -Seconds 2

    $markerC = Join-Path $root 'relaunched-c.marker'
    $codeC = Invoke-Upgrade 'c' @('-LoopClaudePid', $loop.Id, '-LoopPaneId', $paneId,
        '-AllowPlainResume', '-ResumeCommand', (New-ResumeCommand $markerC))
    AssertEq "C2 the upgrade script exited 0" 0 $codeC

    $logC = Out-Text (Join-Path $root 'upgrade-c.log')
    Assert "C3 the script decided to RELAUNCH" ($logC -match 'resume decision: relaunch')
    Assert "C4 it reported the dead loop process as the reason" ($logC -match 'alive=False')
    Assert "C5 it ran the relaunch" ($logC -match 'UPGRADE OK \(relaunched')

    $started = $false
    for ($i = 0; $i -lt 25; $i++) {
        if (Test-Path $markerC) { $started = $true; break }
        Start-Sleep -Milliseconds 900
    }
    Assert "C6 the resume command actually ran in the new window" $started

    # ========================================================================
    "== D: a relaunch onto a RESTORED window still resumes"
    # ========================================================================
    # C left a window registered as 'main' and the loop process is still dead -
    # the state a persistence box is always in after a restore, since restore
    # brings the IPC names back with it. `+new-window --target=main` FOCUSES an
    # existing target and never runs its --command, so the pre-T138 script
    # logged a successful relaunch while starting nothing at all (measured
    # 2026-07-29: exit 0, "UPGRADE OK (relaunched...)", resume command never
    # ran). A silent stall is the same class of failure as a fork.
    $treeD = Wait-Windows 'd0' 1 60
    Assert "D1 a window is still registered as 'main' (the restored-name case)" `
        ($null -ne (Pane-In $treeD 'main'))

    $markerD = Join-Path $root 'relaunched-d.marker'
    $codeD = Invoke-Upgrade 'd' @('-LoopClaudePid', $loop.Id, '-LoopPaneId', $paneId,
        '-AllowPlainResume', '-ResumeCommand', (New-ResumeCommand $markerD))
    AssertEq "D2 the upgrade script exited 0" 0 $codeD
    $logD = Out-Text (Join-Path $root 'upgrade-d.log')
    # It must VERIFY that a window is running the resume command rather than
    # assume the request took effect - whether the restored app has already
    # re-registered 'main' when the request lands is a race, so the outcome
    # check is the only honest one.
    Assert "D3 it verified that a window is running the resume command" `
        ($logD -match 'RELAUNCH-WINDOW OK')

    $ranD = $false
    for ($i = 0; $i -lt 25; $i++) {
        if (Test-Path $markerD) { $ranD = $true; break }
        Start-Sleep -Milliseconds 900
    }
    Assert "D4 the resume command ran anyway (no silent stall)" $ranD
    Assert "D5 the script did not claim success without running it" `
        (-not ($logD -match 'RELAUNCH FAIL'))
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    # ---- teardown ----------------------------------------------------------
    Stop-SandboxProcs
    if ($loop) { Stop-Process -Id $loop.Id -Force -ErrorAction SilentlyContinue }
    $env:USERNAME = $savedUser
    if ($null -eq $savedSuffix) { Remove-Item Env:\GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_PIPE_SUFFIX = $savedSuffix }
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    if ($null -eq $savedAgentBin) { Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    else { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    if ($Keep) { "  (sandbox kept: $root)" }
    else { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
}

# --- stamp (T783/T531) ------------------------------------------------------
# A green FULL run records the content of every file this harness covers, so
# scripts\guard-due.ps1 can answer "has anything run it against the code as it
# now stands?". -PureOnly exits above and never reaches here, so a partial run
# cannot stamp. Red leaves the stamp alone on purpose - red must stay due.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard upgrade-no-fork -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
