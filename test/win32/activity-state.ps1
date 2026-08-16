# T605 acceptance: the pane activity-state machine (idle/busy/needs_input),
# shipped in-app since T866, proven against MAIN'S OWN ORACLE and against the
# Windows process semantics the vendored script had to fork for.
#
# Three sections:
#
#   A. ORACLE DRIFT - the pristine mirror at
#      test\win32\lib\upstream\test-activity-state.sh must be byte-identical
#      to tip-of-main's scripts/test-activity-state.sh (git blob compare).
#      When main grows the oracle, this goes red until someone re-vendors,
#      exactly like the asset mirrors in hook-json.ps1.
#
#   B. THE ORACLE ITSELF - main's suite run VERBATIM under Git Bash against
#      the live win32 asset (src\apprt\win32\assets\ghoztty\hooks\
#      ghoztty-activity-state.sh): the only edit is the one SCRIPT= line that
#      names the file under test, asserted to be exactly one line. Every case
#      main asserts (the priority ordering, the recovery paths, the legacy
#      busy marker, runtime namespacing) is scored here as one assertion, so
#      transitions "match the Mac oracle case for case" is measured, not
#      claimed. The hooks run under Git Bash in production on Windows, so
#      running the .sh oracle under Git Bash IS the faithful environment.
#
#   C. WINDOWS PROCESS SEMANTICS - what the oracle cannot see, because its
#      pids are all MSYS pids. The production owner of a subagent marker is a
#      NATIVE pid (claude), which MSYS `kill -0` cannot see at all - a live
#      native pid answers "No such process" (measured, the reason the T605
#      fork exists). Driven with real native processes through the real
#      script: a marker written by agent-start carries a real owner pid (not
#      1), survives settle while that owner lives, and is reaped the moment
#      it dies; a marker owned by a live native pid holds the pane busy and
#      one owned by a dead native pid does not; and the kill -0 blindness
#      itself is asserted as a negative control - if a future Git Bash learns
#      native pids, that assertion goes red and the fork can be reassessed.
#
# No app instance and no GUI: the oracle stubs `ghoztty` on PATH, so nothing
# here talks to a real pane or the user's terminal. Runs anywhere.
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Note-Skip([string]$label) {
    $script:skipped++
    Write-Host "SKIP  $label"
}

# Git for Windows bash, NEVER a bare `bash` lookup: from PowerShell that
# resolves to WSL's System32\bash.exe, which has no /d/ paths and no MSYS
# process table. Claude Code's own hooks run under Git Bash, so that is the
# environment these sections must reproduce.
$gitBash = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\usr\bin\bash.exe',
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $gitBash) {
    Write-TestAssertedNothing -Reason 'Git for Windows bash not found; the activity-state machine cannot run on this box at all'
}

$liveScript = Join-Path $repo 'src\apprt\win32\assets\ghoztty\hooks\ghoztty-activity-state.sh'
$mirror = Join-Path $repo 'test\win32\lib\upstream\test-activity-state.sh'
if (-not (Test-Path $liveScript)) { Write-TestAssertedNothing -Reason "no live hook asset at $liveScript" }
if (-not (Test-Path $mirror)) { Write-TestAssertedNothing -Reason "no vendored oracle at $mirror" }

$sandbox = Join-Path $env:TEMP "ghoztty-activity-state-$PID"
if (Test-Path $sandbox) { Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $sandbox | Out-Null

# /d/x/y form, never D:/x/y: these strings land in bash PATH entries, where
# a drive colon would split the entry in two.
function ConvertTo-PosixPath([string]$p) {
    return '/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/')
}

Write-Host ''
Write-Host '--- A. oracle drift vs origin/main ---'

& git -C $repo rev-parse --verify origin/main 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Note-Skip 'origin/main not present in this clone; oracle-vs-main blob compare not possible'
} else {
    $local = (& git -C $repo hash-object $mirror 2>$null | Out-String).Trim()
    $upstream = (& git -C $repo rev-parse 'origin/main:scripts/test-activity-state.sh' 2>$null | Out-String).Trim()
    Assert ($local -and $upstream -and ($local -eq $upstream)) "vendored oracle is byte-identical to origin/main scripts/test-activity-state.sh ($local)"
}

Write-Host ''
Write-Host '--- B. main''s oracle against the live win32 asset ---'

# The one permitted edit: the SCRIPT= line that names the file under test.
# Everything else runs byte-for-byte as main wrote it.
$oracleLines = [System.IO.File]::ReadAllText($mirror) -split "`n"
$patched = 0
for ($i = 0; $i -lt $oracleLines.Count; $i++) {
    if ($oracleLines[$i] -match '^SCRIPT=') {
        $oracleLines[$i] = 'SCRIPT="' + (ConvertTo-PosixPath $liveScript) + '"'
        $patched++
    }
}
Assert ($patched -eq 1) "oracle names its subject on exactly one SCRIPT= line ($patched patched)"
$oraclePath = Join-Path $sandbox 'test-activity-state.sh'
[System.IO.File]::WriteAllText($oraclePath, ($oracleLines -join "`n"))

$oracleOut = & $gitBash (ConvertTo-PosixPath $oraclePath)
$oracleRc = $LASTEXITCODE
$okLines = @($oracleOut | Where-Object { $_ -match '^ok\s' })
$failLines = @($oracleOut | Where-Object { $_ -match '^FAIL\s' })
foreach ($l in $okLines) { Assert $true "oracle: $($l -replace '^ok\s+\d+\s+', '')" }
foreach ($l in $failLines) {
    Assert $false "oracle: $l"
    $oracleOut | Write-Host
}
$summary = @($oracleOut | Where-Object { $_ -match '^\d+ passed, \d+ failed$' }) | Select-Object -Last 1
Assert ([bool]$summary -and $summary -match '^16 passed, 0 failed$') "oracle summary is '16 passed, 0 failed' (got '$summary')"
Assert ($oracleRc -eq 0) "oracle exits 0 (got $oracleRc)"

Write-Host ''
Write-Host '--- C. Windows process semantics (native pids) ---'

# A real native process to stand in for the agent: alive first, then dead.
$sleeper = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', 'Start-Sleep 240' -WindowStyle Hidden -PassThru
$null = $sleeper.Handle
$sleeperPid = $sleeper.Id

# The negative control that documents WHY the fork exists: MSYS kill -0
# cannot see a live native process. If this ever goes red, Git Bash learned
# native pids and the T605 fork can be reassessed.
& $gitBash -c "kill -0 $sleeperPid 2>/dev/null"
Assert ($LASTEXITCODE -ne 0) "MSYS kill -0 cannot see live native pid $sleeperPid (the fork's reason; red means the fork may be collapsible)"

# Everything below drives the REAL script under --runtime=t605: its state
# lives under /tmp/ghoztty-t605-*, so it can never touch a real agent
# session's markers, and the ghoztty stub records every published state.
$bin = Join-Path $sandbox 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
[System.IO.File]::WriteAllText((Join-Path $bin 'ghoztty'), "#!/bin/bash`nfor a in `"`$@`"; do case `"`$a`" in --state=*) printf '%s\n' `"`${a#--state=}`" >> `"`$GHOZTTY_TEST_LOG`" ;; esac; done`nexit 0`n")

$stateLog = Join-Path $sandbox 'states.log'
$posixScript = ConvertTo-PosixPath $liveScript
$posixSandbox = ConvertTo-PosixPath $sandbox
$sid = "t605-$PID"
$agentDir = "/tmp/ghoztty-t605-agents-$sid"

# Driver 1, ONE bash: agent-start then settle. The script resolves the
# marker's owner over the NATIVE tree, so the owner it records is this
# driver's own bash (no ancestor is named t605*), which is alive when settle
# runs: expect busy, and a marker whose pid is real (never the PPID=1 MSYS
# fallback the fork replaces).
$driver1 = @(
    '#!/bin/bash',
    'set -u',
    "export PATH=`"$posixSandbox/bin:`$PATH`"",
    "export GHOZTTY_TEST_LOG=`"$posixSandbox/states.log`"",
    'export GHOZTTY_PANE_ID="t605-pane"',
    "chmod +x `"$posixSandbox/bin/ghoztty`"",
    'rm -rf /tmp/ghoztty-t605-* 2>/dev/null',
    "printf '%s' '{`"session_id`":`"$sid`",`"agent_id`":`"agent-w`"}' | bash `"$posixScript`" agent-start --runtime=t605",
    "ls `"$agentDir`" > `"$posixSandbox/markers.txt`" 2>/dev/null",
    "printf '%s' '{`"session_id`":`"$sid`",`"hook_event_name`":`"Stop`"}' | bash `"$posixScript`" settle --runtime=t605"
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $sandbox 'driver1.sh'), $driver1 + "`n")
& $gitBash (ConvertTo-PosixPath (Join-Path $sandbox 'driver1.sh'))

$marker = ''
if (Test-Path (Join-Path $sandbox 'markers.txt')) {
    $marker = ((Get-Content (Join-Path $sandbox 'markers.txt') -ErrorAction SilentlyContinue) | Select-Object -First 1)
}
$ownerPid = if ($marker -match '__(\d+)$') { $Matches[1] } else { '' }
Assert ($marker -like 'agent-w__*') "agent-start wrote one marker for the subagent (got '$marker')"
Assert ($ownerPid -and $ownerPid -ne '1') "marker owner is a real pid, not the PPID=1 MSYS fallback (got '$ownerPid')"
$states = @(Get-Content $stateLog -ErrorAction SilentlyContinue)
Assert (($states -join ',') -eq 'busy') "settle holds the pane busy while the marker's owner lives (got '$($states -join ',')')"

# Driver 2, a NEW bash after driver 1's death: the recorded owner is now a
# dead native pid, so settle must reap the marker instantly and go idle -
# the exact "killed session recovers" path, with native semantics.
$driver2 = @(
    '#!/bin/bash',
    'set -u',
    "export PATH=`"$posixSandbox/bin:`$PATH`"",
    "export GHOZTTY_TEST_LOG=`"$posixSandbox/states.log`"",
    'export GHOZTTY_PANE_ID="t605-pane"',
    "printf '%s' '{`"session_id`":`"$sid`",`"hook_event_name`":`"Stop`"}' | bash `"$posixScript`" settle --runtime=t605"
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $sandbox 'driver2.sh'), $driver2 + "`n")
& $gitBash (ConvertTo-PosixPath (Join-Path $sandbox 'driver2.sh'))
$states = @(Get-Content $stateLog -ErrorAction SilentlyContinue)
Assert (($states -join ',') -eq 'busy,idle') "a dead owner is reaped instantly by the next settle (got '$($states -join ',')')"
& $gitBash -c "test -e '$agentDir/$marker'"
Assert ($LASTEXITCODE -ne 0) 'the dead-owner marker file is gone after the reap'

# A marker owned by a LIVE native pid (the sleeper) holds the pane busy -
# the assertion that was impossible before the fork, because kill -0 read
# every native owner as dead.
$sid2 = "t605-live-$PID"
$agentDir2 = "/tmp/ghoztty-t605-agents-$sid2"
$driver3 = @(
    '#!/bin/bash',
    'set -u',
    "export PATH=`"$posixSandbox/bin:`$PATH`"",
    "export GHOZTTY_TEST_LOG=`"$posixSandbox/states.log`"",
    'export GHOZTTY_PANE_ID="t605-pane"',
    "mkdir -p `"$agentDir2`"",
    ": > `"$agentDir2/agent-n__$sleeperPid`"",
    "printf '%s' '{`"session_id`":`"$sid2`",`"hook_event_name`":`"Stop`"}' | bash `"$posixScript`" settle --runtime=t605"
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $sandbox 'driver3.sh'), $driver3 + "`n")
& $gitBash (ConvertTo-PosixPath (Join-Path $sandbox 'driver3.sh'))
$states = @(Get-Content $stateLog -ErrorAction SilentlyContinue)
Assert (($states -join ',') -eq 'busy,idle,busy') "a live NATIVE owner pid holds the pane busy (got '$($states -join ',')')"

# Kill the sleeper: the same marker must now read as dead and settle idles.
Stop-Process -Id $sleeperPid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
$driver3b = @(
    '#!/bin/bash',
    'set -u',
    "export PATH=`"$posixSandbox/bin:`$PATH`"",
    "export GHOZTTY_TEST_LOG=`"$posixSandbox/states.log`"",
    'export GHOZTTY_PANE_ID="t605-pane"',
    "printf '%s' '{`"session_id`":`"$sid2`",`"hook_event_name`":`"Stop`"}' | bash `"$posixScript`" settle --runtime=t605"
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $sandbox 'driver3b.sh'), $driver3b + "`n")
& $gitBash (ConvertTo-PosixPath (Join-Path $sandbox 'driver3b.sh'))
$states = @(Get-Content $stateLog -ErrorAction SilentlyContinue)
Assert (($states -join ',') -eq 'busy,idle,busy,idle') "a dead NATIVE owner pid is reaped and the pane idles (got '$($states -join ',')')"

# Cleanup: the t605 namespace and the sandbox.
& $gitBash -c 'rm -rf /tmp/ghoztty-t605-* 2>/dev/null'
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

# --- stamp (T783) ----------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard activity-state -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
} elseif ($script:fail -eq 0) {
    Write-Host "  stamp NOT updated: $script:skipped section(s) skipped, so this run did not cover the whole harness"
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'activity-state' -MinPass 20
