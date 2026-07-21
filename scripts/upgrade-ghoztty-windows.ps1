# Upgrade the installed Windows release Ghoztty in place and resume work.
#
# Designed to be launched DETACHED from a Claude Code session running inside
# the very Ghoztty instance being upgraded (killing ghoztty.exe kills the
# session's shell and Claude with it, so nothing in that process tree can do
# the swap). Launch it in its own console and end the turn:
#
#   Start-Process powershell -WindowStyle Hidden -ArgumentList `
#     '-NoProfile','-ExecutionPolicy','Bypass','-File',
#     'D:\git\ghoztty\scripts\upgrade-ghoztty-windows.ps1'
#
# Sequence: wait -> kill release ghoztty processes (install dir only; debug
# zig-out instances untouched) -> swap exe + share\ from the staging prefix
# -> relaunch a window that resumes the most recent Claude session in the
# repo. Every step is appended to %TEMP%\ghoztty-upgrade.log so the resumed
# session can verify what happened.
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
    [int]$DelaySeconds = 3,
    [switch]$NoResume,
    [switch]$AllowPlainResume
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'ghoztty-upgrade.log'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content $log }

Log "=== upgrade start (staging=$Staging)"

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
$preSessions = @()
try {
    $preRaw = & $oldExe +sessions --json 2>$null
    if ($LASTEXITCODE -eq 0 -and $preRaw) {
        $preSessions = @($preRaw | Where-Object { $_ -match '^\s*\{' } |
            ForEach-Object { ($_ | ConvertFrom-Json).id })
    }
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
        $postRaw = & $oldExe +sessions --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $postRaw) {
            $postSessions = @($postRaw | Where-Object { $_ -match '^\s*\{' } |
                ForEach-Object { ($_ | ConvertFrom-Json).id })
        }
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

if ($NoResume) { Log 'UPGRADE OK (no-resume)'; exit 0 }

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
& $oldExe +new-window --target=main "--working-directory=$WorkingDirectory" "--command=$ResumeCommand" 2>&1 |
    ForEach-Object { Log "relaunch: $_" }
Log "UPGRADE OK (relaunched, resume: $ResumeCommand)"
exit 0
