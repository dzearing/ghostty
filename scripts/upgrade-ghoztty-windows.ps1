# Upgrade the installed Windows release Ghoztty in place and resume work.
#
# Designed to be launched DETACHED from a Claude Code session running inside
# the very Ghoztty instance being upgraded (nothing in that process tree can
# do the swap while its own GUI is being killed). Launch it in its own console
# and end the turn:
#
#   Start-Process powershell -WindowStyle Hidden -ArgumentList `
#     '-NoProfile','-ExecutionPolicy','Bypass','-File',
#     'D:\git\ghoztty\scripts\upgrade-ghoztty-windows.ps1'
#
# Sequence: wait -> kill release ghoztty processes (install dir only; debug
# zig-out instances untouched) -> swap exe + share\ from the staging prefix
# -> RESUME the loop. Every step is appended to %TEMP%\ghoztty-upgrade.log so
# the resumed session can verify what happened.
#
# T138 - the resume is a decision, not a fixed action. This script was written
# against the pre-session-persistence world, where "killing ghoztty.exe kills
# the session's shell and Claude with it" and so a relaunch was always right.
# Since T89 the agent owns the PTY and is deliberately never killed: the Claude
# session SURVIVES the upgrade and the relaunched app re-attaches its pane. So
# an unconditional `+new-window --command="claude --continue ..."` produced a
# SECOND session on the same transcript, and both sessions picked the same task
# (user-hit 2026-07-28). Now the script stamps the launching Claude BEFORE the
# kill and checks afterwards:
#   survived -> type the prompt into its existing pane (no second session)
#   gone     -> relaunch a window with the resume command, as before
param(
    [string]$Staging = 'D:\git\ghoztty\zig-out-release',
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Ghoztty",
    [string]$WorkingDirectory = 'D:\git\ghoztty',
    # Runs in the relaunched window; --continue resumes the most recent
    # Claude session in WorkingDirectory (i.e. the one this kill orphaned).
    # --continue restores the conversation, NOT the dead process's CLI
    # flags, so launch-mode flags like --dangerously-skip-permissions must
    # be repeated here or the resumed session drops back to prompting.
    # The trailing prompt is REQUIRED: --continue alone restores the
    # conversation and then sits idle waiting for input (observed
    # 2026-07-14 -> "you stopped working"); the starter prompt re-enters
    # the go.md task loop immediately.
    #
    # Do NOT override this with a plain 'claude' — that relaunches a blank
    # session with no continuation and the loop stalls until a human notices
    # (observed 2026-07-15, 2026-07-16, and a ~1.5-day stall on 2026-07-17).
    # A --continue-less override is replaced with the default unless
    # -AllowPlainResume is passed.
    [string]$ResumeCommand = 'claude --dangerously-skip-permissions --continue "read go.md and go"',
    # Typed into a SURVIVING session instead of relaunching one. Empty = derive
    # it from the trailing quoted prompt of $ResumeCommand, so the two paths
    # cannot drift apart.
    [string]$ResumePrompt = '',
    # The Claude that owns the loop, and the pane it lives in. Both are
    # normally inherited from the launching tool shell ($env:CLAUDE_PID /
    # $env:GHOZTTY_PANE_ID); they are parameters so the T138 test can drive
    # the decision with a stand-in process.
    [int]$LoopClaudePid = 0,
    [string]$LoopPaneId = $env:GHOZTTY_PANE_ID,
    [int]$DelaySeconds = 3,
    [switch]$NoResume,
    [switch]$AllowPlainResume,
    # Relaunch even if the launching session survived. Escape hatch for a
    # session that is wedged rather than merely idle.
    [switch]$ForceRelaunch
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'ghoztty-upgrade.log'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content $log }

. (Join-Path $PSScriptRoot 'loop-session.ps1')

Log "=== upgrade start (staging=$Staging)"

# T138: stamp the launching Claude FIRST, before anything can disturb it. Its
# pid alone would not survive the wait (pids are recycled), so record the
# process identity and compare that after the swap.
$loopPid = Resolve-LoopClaudePid -Explicit $LoopClaudePid
$loopStamp = Get-LoopProcStamp $loopPid
if ($loopStamp) {
    Log "loop session: claude pid=$($loopStamp.Pid) started=$($loopStamp.Start) pane=$LoopPaneId"
} else {
    Log "loop session: none found (no CLAUDE_PID, no claude ancestor) - a surviving-session reuse is not possible; will relaunch"
}

# Guard against the resume-arg drop that stalled the loop on 2026-07-17:
# a ResumeCommand without --continue relaunches a blank session that waits
# forever. Substitute the default unless the caller explicitly opted out.
if (-not $NoResume -and -not $AllowPlainResume -and $ResumeCommand -notlike '*--continue*') {
    Log "WARNING: ResumeCommand lacks --continue ('$ResumeCommand'); substituting the default loop resume. Pass -AllowPlainResume to force a plain relaunch."
    $ResumeCommand = 'claude --dangerously-skip-permissions --continue "read go.md and go"'
}

$newExe = Join-Path $Staging 'bin\ghoztty.exe'
$oldExe = Join-Path $InstallDir 'ghoztty.exe'
if (-not (Test-Path $newExe)) { Log "ABORT: staging exe not found: $newExe"; exit 1 }
if (-not (Test-Path $oldExe)) { Log "ABORT: installed exe not found: $oldExe"; exit 1 }

# Let the launching Claude turn finish so the session transcript is flushed
# before its terminal is killed.
Start-Sleep -Seconds $DelaySeconds

# T89h: capture the live session ids BEFORE the kill so we can assert they
# survive the swap. `+sessions` dials the agent directly (not the app), so it
# works on both sides of the GUI kill. No agent/no sessions => skip assert.
#
# T138: this used to read the output line-by-line expecting one object per
# line. `+sessions --json` prints a pretty-printed ARRAY, so every line failed
# to parse and the probe reported 0 sessions on a box with four live ones -
# the assert below had been silently skipping ever since. Parse the payload
# as a whole (ConvertFrom-GhozttySessionsJson tolerates both shapes).
$preSessions = @()
try {
    $preRaw = (& $oldExe +sessions --json 2>$null) | Out-String
    if ($LASTEXITCODE -eq 0 -and $preRaw) { $preSessions = Get-GhozttySessionIds $preRaw }
} catch {}
Log "pre-kill agent sessions: $($preSessions.Count) ($($preSessions -join ', '))"

# Kill only release GUI instances (running from the install dir). Debug/test
# instances under zig-out keep running. NEVER kill ghoztty-agent.exe — it owns
# the persistent session PTYs; killing it is exactly what session persistence
# exists to avoid (T89h). Get-Process 'ghoztty' already matches only the GUI
# process name, but keep an explicit belt-and-braces filter so a future edit
# can't widen this into the agent.
$victims = @(Get-Process ghoztty -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -eq 'ghoztty' -and $_.Path -like "$InstallDir*" })
Log "killing $($victims.Count) release ghoztty process(es): $($victims.Id -join ', ') (ghoztty-agent.exe is never killed)"
$victims | Stop-Process -Force -ErrorAction SilentlyContinue

# Wait for the exe to unlock, then swap. Keep one .bak for rollback.
$swapped = $false
foreach ($try in 1..20) {
    try {
        Copy-Item $oldExe "$oldExe.bak" -Force -ErrorAction Stop
        Copy-Item $newExe $oldExe -Force -ErrorAction Stop
        $swapped = $true
        break
    } catch {
        Log "swap attempt ${try}: $($_.Exception.Message)"
        Start-Sleep -Milliseconds 500
    }
}
if (-not $swapped) { Log 'ABORT: could not replace exe after 20 tries'; exit 1 }
Log 'exe swapped'

# Keep the matching PDB next to the installed exe so freeze/crash dumps are
# symbolizable (T48). Release builds must use -Dstrip=false to produce one.
$newPdb = Join-Path $Staging 'bin\ghoztty.pdb'
if (Test-Path $newPdb) {
    Copy-Item $newPdb (Join-Path $InstallDir 'ghoztty.pdb') -Force
    Log 'pdb copied alongside exe'
} else {
    Log 'WARNING: no ghoztty.pdb in staging (built with strip?); dumps from this build will be unsymbolized'
}

# T89h: swap ghoztty-agent.exe too, WITHOUT killing the running agent. A
# running exe's file can be RENAMED (the image stays mapped), just not
# overwritten — so move the old one aside and copy the new one in. The old
# agent keeps running with every PTY attached (lazy upgrade, as on Mac); the
# next cold start — reboot autostart or find-or-spawn after it exits — picks
# up the new binary.
$newAgent = Join-Path $Staging 'bin\ghoztty-agent.exe'
$oldAgent = Join-Path $InstallDir 'ghoztty-agent.exe'
if (Test-Path $newAgent) {
    try {
        if (Test-Path $oldAgent) {
            if (Test-Path "$oldAgent.bak") {
                # The .bak may be the mapped image of the still-running
                # previous agent: undeletable, but renameable. Try delete,
                # fall back to shoving it to a dated name (observed
                # 2026-07-20 16:10: Remove-Item failed silently, Move-Item
                # hit 'already exists', and the agent swap was skipped).
                try { Remove-Item "$oldAgent.bak" -Force -ErrorAction Stop }
                catch {
                    Move-Item "$oldAgent.bak" ("$oldAgent.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force -ErrorAction Stop
                }
            }
            Move-Item $oldAgent "$oldAgent.bak" -Force -ErrorAction Stop
        }
        Copy-Item $newAgent $oldAgent -Force -ErrorAction Stop
        Log 'agent exe swapped (running agent untouched; new binary on next agent start)'
        $newAgentPdb = Join-Path $Staging 'bin\ghoztty-agent.pdb'
        if (Test-Path $newAgentPdb) {
            Copy-Item $newAgentPdb (Join-Path $InstallDir 'ghoztty-agent.pdb') -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Log "WARNING: agent exe swap failed: $($_.Exception.Message)"
    }
} else {
    Log 'no ghoztty-agent.exe in staging; kept existing'
}

$stagingShare = Join-Path $Staging 'share'
if (Test-Path $stagingShare) {
    robocopy $stagingShare (Join-Path $InstallDir 'share') /MIR /NFL /NDL /NJH /NJS | Out-Null
    Log "share\ mirrored (robocopy exit $LASTEXITCODE)"
} else {
    Log 'no share\ in staging; kept existing'
}

# T89h: assert the agent's sessions survived the GUI kill + exe swap. The
# relaunched app re-attaches to exactly these ids (T89f2), so a shrunken set
# here means the upgrade lost someone's shell — log it loudly.
if ($preSessions.Count -gt 0) {
    $postSessions = @()
    try {
        $postRaw = (& $oldExe +sessions --json 2>$null) | Out-String
        if ($LASTEXITCODE -eq 0 -and $postRaw) { $postSessions = Get-GhozttySessionIds $postRaw }
    } catch {}
    $lost = @($preSessions | Where-Object { $postSessions -notcontains $_ })
    if ($lost.Count -eq 0) {
        Log "SESSIONS-SURVIVE OK: all $($preSessions.Count) session(s) still owned by the agent"
    } else {
        Log "SESSIONS-SURVIVE FAIL: lost $($lost.Count) of $($preSessions.Count) session(s): $($lost -join ', ')"
    }
} else {
    Log 'SESSIONS-SURVIVE SKIP: no agent sessions before the kill'
}

# T138: the resume DECISION. Made here, once, and logged with the evidence
# behind it so a forked or stalled loop can be diagnosed from the log alone.
$claudeAlive = Test-LoopProcAlive $loopStamp
$action = Resolve-LoopResumeAction -NoResume:([bool]$NoResume) `
    -ClaudeAlive:$claudeAlive -ForceRelaunch:([bool]$ForceRelaunch)
Log ("resume decision: $action (loop claude pid=$loopPid alive=$claudeAlive " +
     "pane=$LoopPaneId force=$([bool]$ForceRelaunch))")

if ($action -eq 'none') { Log 'UPGRADE OK (no-resume)'; exit 0 }

# Scrub Claude-harness env vars before the relaunch. This script is
# normally Start-Process'd from a Claude Code tool shell, whose env
# carries NO_COLOR=1 and per-session CLAUDE_* markers; the +new-window
# below auto-launches the GUI, which would inherit them and pass them to
# EVERY future pane's shell (found live 2026-07-14: all Claude panes
# rendered black-and-white because the GUI held NO_COLOR=1).
$scrub = @('NO_COLOR', 'FORCE_COLOR', 'GIT_TERMINAL_PROMPT', 'CLAUDECODE', 'CLAUDE_PID', 'AI_AGENT') +
    @(Get-ChildItem env: | Where-Object { $_.Name -like 'CLAUDE_CODE_*' } | ForEach-Object Name)
foreach ($v in $scrub) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
Log "relaunch env scrubbed: $($scrub -join ', ')"

# Auto-launches the freshly installed exe (the pipe owner died with the kill).
#
# Set this PROCESS's cwd to the repo first. `--working-directory` alone is not
# enough on the auto-launch path: 2026-07-27 23:36 the relaunched pane came up
# in C:\Windows\System32 (this script's own cwd when Start-Process'd), so
# `claude --continue` found no session there and stopped dead on Claude Code's
# "Is this a project you trust?" prompt. Nothing was waiting to answer it, and
# the loop stayed dead for 7h20m until a human noticed. The dropped flag is a
# product bug in its own right (filed as T132); this is the belt to its braces.
try { Set-Location -LiteralPath $WorkingDirectory -ErrorAction Stop } catch {
    Log "WARNING: could not cd to $WorkingDirectory ($($_.Exception.Message)); relaunch may land in the wrong cwd"
}

# T187 - every probe call is BOUNDED. `& $oldExe +list --json` has no timeout of
# its own, and a client that connects to a bound-but-not-yet-accepting pipe can
# block: one such call used to swallow `Wait-Instance`'s whole window without the
# loop ever iterating, and the deadline then reported the app as DEAD. Running it
# as a child with a hard wait makes the deadline mean what it says.
function Get-ListJson([int]$callTimeoutSec = 10) {
    return (Invoke-GhozttyListJson -Exe $oldExe -WorkingDirectory $WorkingDirectory -TimeoutSec $callTimeoutSec)
}

# Wait for the instance to answer IPC. `$appProc` is the process this script
# started, when it started one: while THAT is alive, "the app did not come back
# up" is simply false, so a live process buys the longer deadline. Measured
# worst case for time-to-IPC-ready is ~11s (T187: 451ms with a healthy agent,
# 10.7s with the agent suspended outright), so these bounds are far above it.
function Wait-Instance([int]$timeoutSec, $appProc = $null) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $polls = 0
    $lastWhy = ''
    while ((Get-Date) -lt $deadline) {
        $r = Get-ListJson
        if ($r.Json) {
            if ($polls -gt 0) { Log "instance answered +list after $polls failed poll(s) (last: $lastWhy)" }
            return $r.Json
        }
        $polls++
        # Log the first failure and then every ~15s, so a recurrence explains
        # itself off the log instead of being re-diagnosed from scratch.
        if ($r.Why -ne $lastWhy -or ($polls % 20) -eq 0) {
            Log "instance probe $polls not ready: $($r.Why)"
            $lastWhy = $r.Why
        }
        if ($appProc -and $appProc.HasExited) {
            Log "instance probe: the process we started (pid=$($appProc.Id)) EXITED with $($appProc.ExitCode)"
            return ''
        }
        Start-Sleep -Milliseconds 750
    }
    Log "instance probe: gave up after ${timeoutSec}s and $polls poll(s); last: $lastWhy"
    return ''
}

# ---- reuse: the launching session outlived the kill ------------------------
# Its pane is still owned by the agent, so the relaunched app re-attaches it
# (T89f2) and the session is sitting idle at its prompt. Type the prompt into
# THAT pane; starting a second `claude --continue` on the same transcript is
# the T138 fork.
if ($action -eq 'reuse') {
    $prompt = Resolve-LoopResumePrompt -ResumeCommand $ResumeCommand -Explicit $ResumePrompt

    # The GUI died with the kill even though the session did not; bring it back
    # WITHOUT +new-window (which would open a window we do not want).
    $listJson = (Get-ListJson).Json
    if (-not $listJson) {
        Log 'reuse: no running instance; starting the freshly installed exe'
        $appProc = Start-Process -FilePath $oldExe -WorkingDirectory $WorkingDirectory -PassThru
        # 180s, not 60s: the deadline exists to catch an app that never starts,
        # and the cost of calling a LIVE app dead is a stalled loop (2026-07-30).
        $listJson = Wait-Instance 180 $appProc
    }
    if (-not $listJson) {
        # Say WHICH of the two it is. They need different responses, and the old
        # message asserted the first while the truth was the second (2026-07-30).
        $state = if ($appProc -and -not $appProc.HasExited) {
            "pid=$($appProc.Id) is ALIVE but never answered +list (IPC unreachable, not a dead app)"
        } elseif ($appProc) {
            "pid=$($appProc.Id) EXITED with $($appProc.ExitCode)"
        } else {
            'no instance and none was started'
        }
        Log "RESUME-REUSE FAIL: $state; the session is alive but headless. NOT relaunching (that would fork the loop) - the go-loop watchdog covers the stall."
        exit 1
    }

    if (-not $LoopPaneId) {
        Log 'RESUME-REUSE PARTIAL: no pane id for the surviving session (script was not launched from a Ghoztty pane), so the prompt cannot be typed. App is up and the session re-attached; NOT relaunching.'
        Log "UPGRADE OK (reuse, no pane id; claude pid=$loopPid still alive)"
        exit 0
    }

    # Wait for restore to re-attach the pane before typing into it.
    $paneBack = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ($listJson -and $listJson.IndexOf($LoopPaneId, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $paneBack = $true; break
        }
        Start-Sleep -Milliseconds 750
        $listJson = (Get-ListJson).Json
    }
    if (-not $paneBack) {
        Log "RESUME-REUSE PARTIAL: pane $LoopPaneId never re-appeared in +list; claude pid=$loopPid is still alive so NOT relaunching (a relaunch here is exactly the T138 fork)."
        exit 1
    }
    Log "reuse: pane $LoopPaneId re-attached"

    # --when-idle: the session may still be finishing the turn that launched
    # this script. Polling for idle beats racing it.
    & $oldExe +send-keys "--target=$LoopPaneId" --when-idle "--idle-timeout=60" $prompt Enter 2>&1 |
        ForEach-Object { Log "reuse send-keys: $_" }
    $sendOk = ($LASTEXITCODE -eq 0)
    if (-not $sendOk) {
        Log "RESUME-REUSE FAIL: +send-keys to $LoopPaneId exited $LASTEXITCODE; the session is alive but was not nudged (watchdog will re-enter)."
    }

    # Confirm the prompt actually landed in the pane rather than assuming it.
    $echoed = $false
    for ($i = 0; $i -lt 8 -and $sendOk; $i++) {
        Start-Sleep -Milliseconds 900
        try {
            $tail = (& $oldExe +read "--name=$LoopPaneId" --lines=40 2>$null) | Out-String
            if ($tail -and $tail.IndexOf($prompt, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $echoed = $true; break }
        } catch {}
    }
    if ($echoed) { Log "RESUME-REUSE OK: prompt '$prompt' delivered to pane $LoopPaneId (claude pid=$loopPid, no second session)" }
    elseif ($sendOk) { Log "RESUME-REUSE SENT: prompt '$prompt' sent to pane $LoopPaneId but was not seen in the pane tail (the TUI may have consumed it); no second session was started" }
    Log "UPGRADE OK (reused claude pid=$loopPid in pane $LoopPaneId)"
    exit 0
}

# ---- relaunch: nothing survived the kill -----------------------------------
#
# T138: `+new-window --target=main` is IDEMPOTENT - an existing `main` is
# FOCUSED, and the --command is never run. Session restore brings back the
# registered IPC names (T89f2), so on a persistence box the relaunch lands on
# a restored `main` and silently does nothing: the loop stalls with a window
# that looks perfectly healthy. Measured on the pre-T138 script 2026-07-29 -
# it logged "UPGRADE OK (relaunched...)" while the resume command had not run
# at all. When the name is already taken, type the resume command into that
# window instead (its pane is the loop's own shell, relaunched by the agent),
# and only fall back to a fresh window if that fails.
#
# Bring the app up FIRST and let restore settle, rather than letting
# `+new-window` auto-launch it. Otherwise this decision races the restore: the
# app is still down when we look, so `main` "does not exist", and the request
# lands on an app that registers `main` a moment later - the outcome then
# depends on which side wins, which is exactly the kind of intermittent the
# 2026-07-28 fork was.
$relaunched = $false
$listBefore = (Get-ListJson).Json
if (-not $listBefore) {
    Log 'relaunch: no running instance; starting the freshly installed exe before resuming'
    Start-Process -FilePath $oldExe -WorkingDirectory $WorkingDirectory | Out-Null
    $listBefore = Wait-Instance 60
    # Restore rebuilds windows (and their IPC names) a beat after the pipe
    # comes up; give it that beat before deciding.
    Start-Sleep -Seconds 3
    $listBefore = (Get-ListJson).Json
}
function Count-Windows($json) {
    if (-not $json) { return 0 }
    return ([regex]::Matches($json, '"tabs"\s*:')).Count
}
$before = Count-Windows $listBefore
if ($listBefore -match '"target"\s*:\s*"main"') {
    Log 'relaunch: a window is ALREADY registered as "main" (restored) - +new-window will focus it and run nothing'
}

# Whether the name is taken is decided by the app, not by our snapshot, so
# verify the OUTCOME: a resume that ran opened a window. If none appeared, the
# request was swallowed by an existing target and the loop would stall - retry
# under a name nothing can already own.
& $oldExe +new-window --target=main "--working-directory=$WorkingDirectory" "--command=$ResumeCommand" 2>&1 |
    ForEach-Object { Log "relaunch: $_" }
for ($i = 0; $i -lt 14; $i++) {
    Start-Sleep -Milliseconds 750
    if ((Count-Windows (Get-ListJson).Json) -gt $before) { $relaunched = $true; break }
}
if ($relaunched) {
    Log "RELAUNCH-WINDOW OK: a new window is running the resume command (windows $before -> $($before + 1))"
} else {
    $alt = 'main-' + (Get-Date -Format 'HHmmss')
    Log "relaunch: no new window appeared - an existing 'main' was focused instead of created; retrying as $alt"
    & $oldExe +new-window "--target=$alt" "--working-directory=$WorkingDirectory" "--command=$ResumeCommand" 2>&1 |
        ForEach-Object { Log "relaunch: $_" }
    for ($i = 0; $i -lt 14; $i++) {
        Start-Sleep -Milliseconds 750
        if ((Count-Windows (Get-ListJson).Json) -gt $before) { $relaunched = $true; break }
    }
    if ($relaunched) { Log "RELAUNCH-WINDOW OK: resumed in a new window named $alt" }
}
if (-not $relaunched) { Log 'RELAUNCH FAIL: no window is running the resume command; the loop is STALLED until the watchdog re-enters' }

# VERIFY the relaunch instead of assuming it. A pane in the wrong directory
# looks identical to a healthy one from here, and that invisibility is what
# made the stall above cost hours rather than seconds.
#
# T138: `+list --json` reports an EMPTY working_directory for agent-backed
# panes (T98), so on a session-persistence box this check could only ever log
# UNKNOWN. Fall back to the agent's own view - `+sessions --json` carries the
# real cwd - restricted to sessions created in the last two minutes so an old
# session in the same repo cannot vouch for a pane that landed elsewhere.
$landed = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 750
    try {
        $raw = & $oldExe +list --json 2>$null | Out-String
        if ($raw -match '"working_directory"\s*:\s*"([^"]+)"') { $landed = $Matches[1] -replace '\\\\', '\' }
    } catch {}
    if (-not $landed) {
        try {
            $sraw = (& $oldExe +sessions --json 2>$null) | Out-String
            $cutoff = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToUnixTimeMilliseconds()
            $fresh = @(ConvertFrom-GhozttySessionsJson $sraw |
                Where-Object { $_.cwd -and $_.created_at -and [int64]$_.created_at -ge $cutoff })
            if ($fresh.Count -gt 0) { $landed = [string]$fresh[-1].cwd }
        } catch {}
    }
    if ($landed) { break }
}
if (-not $landed) {
    Log 'RELAUNCH-CWD UNKNOWN: no pane working_directory reported; check the new window by hand'
} elseif ($landed.TrimEnd('\') -ieq $WorkingDirectory.TrimEnd('\')) {
    Log "RELAUNCH-CWD OK: $landed"
} else {
    Log "RELAUNCH-CWD FAIL: pane landed in '$landed', expected '$WorkingDirectory' -- the resumed session will not find its conversation and the loop is STALLED (see T132)"
}
Log "UPGRADE OK (relaunched, resume: $ResumeCommand)"
exit 0
