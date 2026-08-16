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
# Sequence: verify the staged bits ARE the delivery -> wait -> kill release
# ghoztty processes (install dir only; debug zig-out instances untouched) ->
# swap exe + share\ from the staging prefix -> verify the installed exe reports
# the delivered commit -> mirror to the other install locations -> RESUME the
# loop. Every step is appended to %TEMP%\ghoztty-upgrade.log so the resumed
# session can verify what happened.
#
# T208 - this script deliberately does NOT build; it copies whatever is in
# $Staging. That is why both ends are verified against a commit: on 2026-07-30 a
# delivery copied the PREVIOUS delivery's binary and `exe swapped` + `UPGRADE OK`
# both reported success over it. `UPGRADE OK` now means "the installed exe
# answers with the commit this delivery was for", and a stale staging prefix
# skips the swap entirely rather than shipping it.
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
#   -NoResume + a killed app -> restart the app, type nothing (T531: -NoResume
#   suppresses the resume TYPING only; the terminal always comes back)
#
# T200 - the launch itself is a compatibility boundary. `Start-Process
# -ArgumentList @(...)` does NOT quote its elements: they are joined with spaces
# and re-tokenized by this script's own parser, so a multi-word -ResumePrompt is
# shredded into positional arguments. Measured 2026-07-30: a prompt containing a
# bare `-` died in parameter BINDING (before line 1, so nothing could be logged,
# and a detached hidden child discards stderr - the delivery vanished with zero
# evidence); with the hyphen removed the same prompt bound prose to three
# parameters at once ($Staging='Verify', $ResumeCommand='It', $LoopPaneId='did').
# Hence: PositionalBinding=$false so a stray word is a loud error instead of a
# silent mis-bind, -ResumePromptFile so free text never travels through argv at
# all, and scripts/launch-upgrade.ps1 which refuses to believe the launch worked
# until this script's first log line appears.
#
# PositionalBinding=$false, not a bare [CmdletBinding()]: every [string] param
# here is positional by default, so plain CmdletBinding still let the shrapnel
# land - measured, `-Staging x -NoResume aStrayWord` bound aStrayWord to
# $InstallDir and ran. Nothing about this script should ever be passed by
# position.
[CmdletBinding(PositionalBinding = $false)]
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
    # The SAME value, read from a file instead of argv. Prefer this from any
    # caller: a file cannot be re-tokenized, so no quoting, hyphen, %VAR% or
    # newline in the prompt can reach the parameter binder (T200). Wins over
    # -ResumePrompt when both are given.
    [string]$ResumePromptFile = '',
    # The Claude that owns the loop, and the pane it lives in. Both are
    # normally inherited from the launching tool shell ($env:CLAUDE_PID /
    # $env:GHOZTTY_PANE_ID); they are parameters so the T138 test can drive
    # the decision with a stand-in process.
    [int]$LoopClaudePid = 0,
    [string]$LoopPaneId = $env:GHOZTTY_PANE_ID,
    [int]$DelaySeconds = 3,
    # T208: the commit this delivery is supposed to ship. Normally handed down by
    # launch-upgrade.ps1, which has already verified it; empty means "read it
    # from git in $WorkingDirectory". A staged exe that does not carry it is a
    # STALE delivery and the swap is skipped entirely.
    [string]$ExpectedCommit = '',
    [switch]$AllowStaleStaging,
    # Kept in step with the primary install, best-effort, because a fix that
    # only lives in one of the three locations does not exist as far as the user
    # can tell. Never fatal: a sleeping NAS must not fail a delivery.
    # The exe-bearing directory of each, NOT the wrapper folder: both portables
    # nest one level (`Ghoztty-portable-x64\Ghoztty\ghoztty.exe`).
    [string[]]$ExtraInstallDirs = @(
        'D:\Users\David\Desktop\Ghoztty-portable-x64\Ghoztty',
        '\\homeassistant\share\ghoztty-windows\Ghoztty-portable-x64\Ghoztty'
    ),
    [switch]$NoExtraInstalls,
    # Skip typing the resume prompt - and ONLY that (T531). If the swap killed
    # a running app, the freshly installed exe is still restarted; an upgrade
    # must never end with the user's terminal gone.
    [switch]$NoResume,
    [switch]$AllowPlainResume,
    # Relaunch even if the launching session survived. Escape hatch for a
    # session that is wedged rather than merely idle.
    [switch]$ForceRelaunch,
    # T525 - the unattended morning refresh. Deliver the APP and nothing else:
    #
    #   * ghoztty-agent.exe is NOT swapped, in any install location. The user's
    #     directive is that the morning flow must not update the agent at all
    #     ("avoid an agent update because that will shut down the loop"), and
    #     the staged binary keeps until the next deliberate full delivery.
    #   * a deferral marker is written before the app is restarted, so the fresh
    #     app does not raise the mandatory agent-restart confirmation at a
    #     machine nobody is sitting at. Skipping the swap alone cannot achieve
    #     that: on a box that has taken earlier deliveries the on-disk agent is
    #     ALREADY newer than the running one, so the dialog fires regardless of
    #     what this run copies.
    [switch]$AppOnly,
    # Where the marker goes. A parameter only so the acceptance test can watch
    # it being written without touching the real one.
    [string]$DeferMarkerPath = (Join-Path $env:LOCALAPPDATA 'ghoztty\agent-upgrade-defer'),
    # How long the deferral holds. It only has to cover kill -> swap -> app start
    # -> restore -> the app's first agent check; measured worst case to IPC-ready
    # is ~11s (T187). Generous, and self-expiring is the point: a marker that
    # never expired would silence the confirmation on this box forever.
    [int]$DeferMinutes = 20
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'ghoztty-upgrade.log'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content $log }

. (Join-Path $PSScriptRoot 'loop-session.ps1')
. (Join-Path $PSScriptRoot 'delivery-version.ps1')

# Log an Invoke-NativeExact result the way the `& $exe ... 2>&1 | ForEach Log`
# shape used to (T279): one line per line of output, stdout and stderr alike.
function Log-NativeResult($tag, $r) {
    foreach ($stream in @($r.Out, $r.Err)) {
        if (-not $stream) { continue }
        foreach ($line in ($stream -split "`r?`n")) {
            if ($line.Trim()) { Log "${tag}: $($line.Trim())" }
        }
    }
    if ($r.TimedOut) { Log "${tag}: TIMED OUT" }
}

Log "=== upgrade start (staging=$Staging)"

# T208: the delivery's verdict is decided in two places (before the swap, and
# after it) and reported in ONE place, so `UPGRADE OK` cannot appear over a
# delivery that did not happen. Every exit below goes through this.
$script:deliveryFailure = ''
# T525: did a live app answer IPC after the restart, and what commit is on disk?
# Goal 2 of the morning refresh is that the reboot is VERIFIED rather than
# assumed, and the two halves of that evidence are produced far apart - the
# commit read-back happens right after the swap, the "a window is up" proof only
# once the resume path has waited for the app. Collected here so the verdict is
# one greppable line instead of a correlation exercise across the log.
$script:appAnswered = $false
$script:installedCommit = ''
function Complete-Upgrade([string]$note) {
    if ($AppOnly) {
        if ($script:appAnswered) {
            Log ("APP-REFRESH OK: the restarted app answered +list, and $oldExe reports " +
                "'$(if ($script:installedCommit) { $script:installedCommit } else { '<unread>' })' (agent untouched)")
        } else {
            Log 'APP-REFRESH UNVERIFIED: no live instance answered +list during this run, so nothing here proves a window came back on the new build'
        }
    }
    if ($script:deliveryFailure) {
        # Deliberately does not spell the success tag - a log grep for
        # "UPGRADE OK" must never match a failure line.
        Log "UPGRADE FAILED: $($script:deliveryFailure) ($note)"
        exit 1
    }
    Log "UPGRADE OK ($note)"
    exit 0
}

# T200: the full resolved parameter set, so a mis-bind is READABLE in the log
# instead of inferred from a weird `pane=` value three lines down.
if ($ResumePromptFile) {
    if (-not (Test-Path -LiteralPath $ResumePromptFile -PathType Leaf)) {
        Log "ABORT: -ResumePromptFile not found: $ResumePromptFile"
        exit 1
    }
    # -Raw, then trim only the trailing newline the writer added: a prompt may
    # legitimately contain blank lines and leading spaces.
    $ResumePrompt = [IO.File]::ReadAllText($ResumePromptFile) -replace '\r?\n\z', ''
    Log "resume prompt read from file ($($ResumePrompt.Length) chars): $ResumePromptFile"
}
Log ("params: install=[{0}] wd=[{1}] pane=[{2}] loopPid={3} delay={4} noResume={5} force={6} expect=[{7}] allowStale={8} appOnly={9} resumeCmd=[{10}] resumePrompt=[{11}]" -f `
    $InstallDir, $WorkingDirectory, $LoopPaneId, $LoopClaudePid, $DelaySeconds, `
    [bool]$NoResume, [bool]$ForceRelaunch, $ExpectedCommit, [bool]$AllowStaleStaging, `
    [bool]$AppOnly, $ResumeCommand, $ResumePrompt)

# Both of these are consumed by destructive steps (the kill is scoped to
# $InstallDir, the swap reads $Staging). A mis-bound value must stop the run
# here, not point the kill at some other tree.
foreach ($pair in @(@{ n = 'Staging'; v = $Staging }, @{ n = 'InstallDir'; v = $InstallDir })) {
    if (-not (Test-Path -LiteralPath $pair.v -PathType Container)) {
        Log "ABORT: -$($pair.n) is not an existing directory: $($pair.v)"
        exit 1
    }
}

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

# T663: $oldExe is the GUI-subsystem binary and PowerShell cannot capture its
# stdout, so every verb whose ANSWER this script reads goes through the console
# twin instead. $oldExe stays the thing we copy over, verify and LAUNCH.
# Re-resolved after the swap, because the .com may only exist in the new build.
$cliExe = Resolve-GhozttyCliExe $oldExe
Log ("cli reader: $cliExe" + $(if ($cliExe -eq $oldExe) { ' (no .com sibling - readers rely on 2>&1)' } else { '' }))

# ---- T208: is the staged binary actually this tree? -------------------------
#
# launch-upgrade.ps1 checks this before it launches; this is the same check at
# the last moment before anything destructive, for the direct-invocation path
# and as the belt to that braces. It runs BEFORE the kill on purpose.
#
# On a mismatch the swap is SKIPPED but the resume still runs. Refusing to ship
# stale bits is the point; stalling the loop is not - that is the failure mode
# the whole T200/T208 family exists to prevent, and a silent stall costs more
# than a delivery that has to be re-run. The log says FAILED and the exit code
# is 1, so nothing downstream can read this as a successful delivery.
$expected = $ExpectedCommit
if (-not $expected) {
    $expected = Get-RepoHeadCommit -Repo $WorkingDirectory
    Log "expected commit not supplied; read HEAD in ${WorkingDirectory}: '$expected'"
}
$stagedInfo = Resolve-GhozttyExeCommit -Exe $newExe
Log "staging freshness: staged=$($stagedInfo.Commit) expected=$expected$(if ($stagedInfo.Why) { " (staged probe: $($stagedInfo.Why))" })"
$stale = $false
if (-not $expected) {
    Log 'WARNING: no expected commit (no -ExpectedCommit and git could not be read); the staged binary is UNVERIFIED. Proceeding.'
} elseif (-not (Test-CommitsMatch $stagedInfo.Commit $expected)) {
    if ($AllowStaleStaging) {
        Log "WARNING: staged exe carries '$($stagedInfo.Commit)' but expected '$expected'; shipping anyway (-AllowStaleStaging)."
    } else {
        $stale = $true
        $script:deliveryFailure = "STALE STAGING: $newExe carries '$($stagedInfo.Commit)' but the delivery is for '$expected'"
        Log "STALE STAGING: $newExe carries '$($stagedInfo.Commit)', expected '$expected'. SKIPPING the kill and the swap - the installed release is untouched. Rebuild the staging prefix (zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix $Staging) and deliver again. The resume below still runs so the loop is not stalled."
    }
}

# >>>>> the destructive region. Everything from here to `} # <<<<< end of the
# destructive region` kills processes and overwrites the installed release, and
# is skipped wholesale when the staged bits are not the ones being delivered.
# Deliberately NOT re-indented: this guard was added around code that predates
# it (T208), and an indentation-only diff over 120 lines hides the one line that
# changed behaviour.
# T531: defined OUTSIDE the destructive region so the resume decision can ask
# "did this run kill a running app?" even on the stale path, where the region
# (and the kill inside it) never executes.
$victims = @()

if (-not $stale) {

# T525: arm the deferral BEFORE the kill, not after the swap.
#
# The app can come back up by two different routes below (the reuse path starts
# it, or an already-running instance answers), and on a fast box the restore's
# agent check runs within a second of the process starting. Writing the marker
# first means there is no ordering in which the app can reach that check before
# the marker exists. It is not cleaned up on the way out: expiry is the release
# mechanism, so a delivery that dies halfway cannot leave the confirmation
# silenced.
if ($AppOnly) {
    try {
        $markerDir = Split-Path -Parent $DeferMarkerPath
        if ($markerDir -and -not (Test-Path -LiteralPath $markerDir)) {
            New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        }
        $deadline = [int64]([DateTimeOffset]::UtcNow.AddMinutes($DeferMinutes).ToUnixTimeSeconds())
        # No BOM: the app parses the first line as a decimal integer, and a
        # U+FEFF in front of it reads as garbage (which is safe - it declines to
        # defer - but silently defeats the whole point). Set-Content in PS 5.1
        # would write one.
        $body = "$deadline`n# ghoztty app-only delivery; the agent-restart confirmation is deferred until this UTC unix time`n"
        [IO.File]::WriteAllText($DeferMarkerPath, $body, (New-Object Text.UTF8Encoding($false)))
        Log "APP-ONLY: agent-upgrade confirmation deferred until $deadline (+$DeferMinutes min) via $DeferMarkerPath"
    } catch {
        # Not fatal. The cost is a dialog on an unattended box, which is the
        # thing being fixed - but a delivery that refused to ship over it would
        # leave the user on a stale client instead, which is worse.
        Log "WARNING: APP-ONLY: could not write the deferral marker $DeferMarkerPath ($($_.Exception.Message)); the agent-restart confirmation may appear unattended"
    }
}

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
    # T663: through $oldExe (GUI subsystem) this captured nothing, so the probe
    # reported 0 sessions on every run and the survive-assert below never fired.
    $preRaw = (& $cliExe +sessions --json 2>$null) | Out-String
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

# T245: ghoztty.com, the console-subsystem twin of ghoztty.exe (what makes
# PowerShell '>' redirection of CLI verbs work), ships as a required sibling.
# It is never a long-lived process (CLI verbs exit; a GUI launch through it
# respawns ghoztty.exe and exits), so the plain copy that just worked for the
# exe works here too. Missing from staging = an old staging build; log and
# keep going rather than failing a delivery that predates the twin.
$newCom = Join-Path $Staging 'bin\ghoztty.com'
$oldCom = Join-Path $InstallDir 'ghoztty.com'
if (Test-Path $newCom) {
    try {
        Copy-Item $newCom $oldCom -Force -ErrorAction Stop
        Log 'ghoztty.com swapped'
    } catch {
        Log "WARNING: ghoztty.com swap failed: $($_.Exception.Message)"
    }
} else {
    Log 'no ghoztty.com in staging; kept existing (pre-T245 staging build?)'
}

# T663: re-resolve now that the swap is done. An install that had no console
# twin before this delivery has one after it, and everything that READS a CLI
# answer from here on - the post-swap session probe, the pane readiness gate,
# the arrival gate - depends on which binary it asks.
$prevCli = $cliExe
$cliExe = Resolve-GhozttyCliExe $oldExe
if ($cliExe -ne $prevCli) { Log "cli reader: now $cliExe" }

# T89h: swap ghoztty-agent.exe too, WITHOUT killing the running agent. A
# running exe's file can be RENAMED (the image stays mapped), just not
# overwritten — so move the old one aside and copy the new one in. The old
# agent keeps running with every PTY attached (lazy upgrade, as on Mac); the
# next cold start — reboot autostart or find-or-spawn after it exits — picks
# up the new binary.
#
# T525: skipped wholesale in -AppOnly mode. Swapping it here is what makes the
# freshly restarted app find a bundled agent newer than the running one and ask
# to restart it - an interruption on an unattended box, and one that would end
# the very sessions the morning refresh exists to preserve. The staged binary is
# not lost: the next deliberate (attended) delivery ships it.
$newAgent = Join-Path $Staging 'bin\ghoztty-agent.exe'
$oldAgent = Join-Path $InstallDir 'ghoztty-agent.exe'
if ($AppOnly) {
    Log 'APP-ONLY: ghoztty-agent.exe NOT swapped (staged for the next full delivery); the running agent and its sessions are untouched'
} elseif (Test-Path $newAgent) {
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
        $postRaw = (& $cliExe +sessions --json 2>$null) | Out-String
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

# ---- T208: prove the RIGHT BITS are installed, not just that a copy returned -
#
# `exe swapped` only means Copy-Item did not throw. What the delivery promised is
# that the installed exe now answers with this tree's commit, so read it back and
# say which one it is. This is the line a later turn greps when it wants to know
# what the user is actually running.
$installedInfo = Resolve-GhozttyExeCommit -Exe $oldExe
$script:installedCommit = $installedInfo.Commit
$want = if ($expected) { $expected } else { $stagedInfo.Commit }
if (-not $installedInfo.Commit) {
    Log "POST-SWAP VERIFY UNKNOWN: could not read the installed exe's commit ($($installedInfo.Why)); wanted '$want'"
} elseif (Test-CommitsMatch $installedInfo.Commit $want) {
    Log "POST-SWAP VERIFY OK: $oldExe now reports '$($installedInfo.Commit)'"
} else {
    $script:deliveryFailure = "POST-SWAP VERIFY FAILED: $oldExe reports '$($installedInfo.Commit)' but the delivery is for '$want'"
    Log "POST-SWAP VERIFY FAILED: $oldExe reports '$($installedInfo.Commit)', wanted '$want'. The copy returned success and did NOT take - this run is NOT a successful delivery."
}

# ---- T281: the agent binary is held to the same standard --------------------
#
# `agent exe swapped` above means Move-Item + Copy-Item did not throw, and that
# branch has a WARNING path where NEITHER ran: on 2026-07-20 the `.bak` was the
# still-mapped image of the running agent - undeletable, and the fallback rename
# hit 'already exists' - so the swap was skipped and a months-old agent stayed on
# disk while the run still reported UPGRADE OK. Two of the three binaries this
# delivery ships were trusted to a Copy-Item return, which is the exact standard
# T208 exists to reject.
#
# The claim measured here is "the agent on disk is the one from staging", so it
# is compared against the STAGED agent's stamp and not against the delivery's
# commit: the agent's `--version` prints a build stamp, not a semver, and
# demanding that the staged agent and the staged app carry the same commit is a
# different (and weaker) claim than the one being made.
#
# What is deliberately NOT asserted: the RUNNING agent's build. It is expected to
# be older - that is the lazy-upgrade contract, and the whole reason the swap
# never kills it.
$script:stagedAgentStamp = ''
if ($AppOnly) {
    Log 'AGENT VERIFY SKIP: -AppOnly swapped no agent, so the installed one is legitimately older'
} elseif (-not (Test-Path $newAgent)) {
    Log 'AGENT VERIFY SKIP: no ghoztty-agent.exe in staging, so this run claimed nothing about it'
} else {
    $stagedAgent = Resolve-GhozttyAgentStamp -Exe $newAgent
    $script:stagedAgentStamp = $stagedAgent.Stamp
    $installedAgent = Resolve-GhozttyAgentStamp -Exe $oldAgent
    if (-not $stagedAgent.Stamp) {
        Log ("AGENT VERIFY UNKNOWN: the STAGED agent would not report a stamp ($($stagedAgent.Why)); " +
            'there is no number to compare the installed one against')
    } elseif (Test-AgentStampsMatch $installedAgent.Stamp $stagedAgent.Stamp) {
        Log "AGENT VERIFY OK: $oldAgent now reports '$($installedAgent.Stamp)'"
    } else {
        $got = if ($installedAgent.Stamp) { "'$($installedAgent.Stamp)'" } else { "nothing readable ($($installedAgent.Why))" }
        # Never clobber an earlier verdict: the exe's failure is the one the
        # delivery is named for, and both lines are in the log either way.
        if (-not $script:deliveryFailure) {
            $script:deliveryFailure = "AGENT VERIFY FAILED: $oldAgent reports $got but staging has '$($stagedAgent.Stamp)'"
        }
        Log ("AGENT VERIFY FAILED: $oldAgent reports $got, staging has '$($stagedAgent.Stamp)'. " +
            'The agent swap did not take - the running agent keeps its sessions, but the binary the NEXT agent start ' +
            'would pick up is the old one. This run is NOT a successful delivery.')
    }
}

# ---- the other install locations --------------------------------------------
#
# The standing bar is that a fix lands everywhere the user might launch from;
# the log shows those copies made BY HAND after every delivery, which is the same
# staleness risk as this task's, with no automation at all. Best-effort by
# design: a sleeping NAS or a running portable instance holding its exe open
# must never fail (or slow) the delivery that already succeeded.
if ($script:deliveryFailure) {
    Log 'extra install locations: NOT PROPAGATED - the primary install did not verify, so there is nothing worth copying onward'
} elseif ($NoExtraInstalls) {
    Log 'extra install locations: skipped by request (-NoExtraInstalls)'
} else {
    foreach ($dir in $ExtraInstallDirs) {
        if (-not $dir) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            Log "extra install '$dir': not present, skipped"
            continue
        }
        try {
            # Same set the primary swap maintains, plus ghostty-vt.dll only where
            # the target already has one (the portable ships it; the installed
            # release does not - this is not the place to invent new layout).
            # T525: -AppOnly means app, everywhere. A portable copy that got a
            # newer agent would hand the same unattended dialog to whoever
            # launches it next, and "app-only except over there" is the kind of
            # per-location divergence this repo does not ship.
            $names = if ($AppOnly) {
                @('ghoztty.exe', 'ghoztty.com', 'ghoztty.pdb')
            } else {
                @('ghoztty.exe', 'ghoztty.com', 'ghoztty.pdb', 'ghoztty-agent.exe', 'ghoztty-agent.pdb')
            }
            if (Test-Path -LiteralPath (Join-Path $dir 'ghostty-vt.dll')) { $names += 'ghostty-vt.dll' }
            $copied = @()
            foreach ($n in $names) {
                $src = Join-Path $Staging "bin\$n"
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $dst = Join-Path $dir $n
                try {
                    # A mapped image can be renamed but not overwritten, so shove
                    # a live one aside rather than failing the whole location.
                    if (Test-Path -LiteralPath $dst) {
                        try { Copy-Item $src $dst -Force -ErrorAction Stop; $copied += $n; continue }
                        catch {
                            Move-Item $dst ("$dst.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force -ErrorAction Stop
                        }
                    }
                    Copy-Item $src $dst -Force -ErrorAction Stop
                    $copied += $n
                } catch {
                    Log "extra install '$dir': $n FAILED ($($_.Exception.Message))"
                }
            }
            if (Test-Path -LiteralPath $stagingShare) {
                # /R:1 /W:1 so an unreachable share fails in seconds, not minutes.
                robocopy $stagingShare (Join-Path $dir 'share') /MIR /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
                $copied += "share\(robocopy $LASTEXITCODE)"
            }
            Log "extra install '$dir': $($copied -join ', ')"

            # T281: and read the location back. Until this existed the line above
            # was the whole record - a list of file NAMES that were ATTEMPTED,
            # which says nothing about what is on disk. On 2026-08-10 both
            # portable locations were found holding a Debug ghoztty.exe an hour
            # after a refresh had logged exactly such a list.
            #
            # A mismatch here is a WARNING naming the location, never a failure:
            # these copies are best-effort by design (a sleeping NAS, a portable
            # instance holding its own exe open) and the primary install has
            # already verified. Silence is the only outcome that was wrong.
            $mirrorExe = Join-Path $dir 'ghoztty.exe'
            if (($copied -contains 'ghoztty.exe') -and $want) {
                $got = Resolve-GhozttyExeCommit -Exe $mirrorExe -TimeoutSec 30
                if (Test-CommitsMatch $got.Commit $want) {
                    Log "extra install '$dir': VERIFIED ghoztty.exe reports '$($got.Commit)'"
                } elseif ($got.Commit) {
                    Log "WARNING: extra install '$dir': ghoztty.exe reports '$($got.Commit)' but the delivery is for '$want'"
                } else {
                    Log "WARNING: extra install '$dir': ghoztty.exe could not be asked its version ($($got.Why))"
                }
            }
            $mirrorAgent = Join-Path $dir 'ghoztty-agent.exe'
            if (($copied -contains 'ghoztty-agent.exe') -and $script:stagedAgentStamp) {
                $gotAgent = Resolve-GhozttyAgentStamp -Exe $mirrorAgent -TimeoutSec 30
                if (Test-AgentStampsMatch $gotAgent.Stamp $script:stagedAgentStamp) {
                    Log "extra install '$dir': VERIFIED ghoztty-agent.exe reports '$($gotAgent.Stamp)'"
                } elseif ($gotAgent.Stamp) {
                    Log "WARNING: extra install '$dir': ghoztty-agent.exe reports '$($gotAgent.Stamp)' but staging has '$($script:stagedAgentStamp)'"
                } else {
                    Log "WARNING: extra install '$dir': ghoztty-agent.exe could not be asked its version ($($gotAgent.Why))"
                }
            }
        } catch {
            Log "extra install '$dir': FAILED ($($_.Exception.Message))"
        }
    }
}

} # <<<<< end of the destructive region (T208; opened at `if (-not $stale)`)

# T138: the resume DECISION. Made here, once, and logged with the evidence
# behind it so a forked or stalled loop can be diagnosed from the log alone.
$claudeAlive = Test-LoopProcAlive $loopStamp
$action = Resolve-LoopResumeAction -NoResume:([bool]$NoResume) `
    -ClaudeAlive:$claudeAlive -ForceRelaunch:([bool]$ForceRelaunch) `
    -KilledApps $victims.Count
Log ("resume decision: $action (loop claude pid=$loopPid alive=$claudeAlive " +
     "pane=$LoopPaneId force=$([bool]$ForceRelaunch) killedApps=$($victims.Count))")

# 'none' means -NoResume AND nothing was killed: there is no terminal to bring
# back and no prompt to type, so the delivery is complete. When the swap DID
# kill a running app, the action is 'restart-only' and is handled below, after
# the probe helpers exist (T531).
if ($action -eq 'none') { Complete-Upgrade 'no-resume' }

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
    $r = Invoke-GhozttyListJson -Exe $cliExe -WorkingDirectory $WorkingDirectory -TimeoutSec $callTimeoutSec
    # A single answered +list is the whole of "a live app is up on the new exe";
    # recorded once, here, because every caller below has a different reason for
    # asking and none of them is the reporting site (T525).
    if ($r.Json) { $script:appAnswered = $true }
    return $r
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

# ---- restart-only: -NoResume, but the swap killed a running app (T531) -----
# -NoResume suppresses the resume TYPING, never the app restart. On 2026-08-06
# 09:19 the two were one flag: an interactive delivery used -NoResume to keep
# the prompt out of a busy loop pane, the run killed 2 release processes,
# swapped, logged "UPGRADE OK (no-resume)" - and the user's terminal vanished
# and stayed gone. An upgrade's contract is that the terminal comes back
# (T421/T524 called exactly this outcome, from a different cause, the worst
# possible shape). A true no-restart mode would be its own explicitly named
# flag; no caller has ever wanted one.
if ($action -eq 'restart-only') {
    $listJson = (Get-ListJson).Json
    if ($listJson) {
        # Something already brought an instance up (e.g. the T421 relaunch
        # guard); a second Start-Process here would double the windows.
        Log 'restart-only: an instance is already answering +list; not starting another'
        Complete-Upgrade 'no-resume, app already up'
    }
    Log "restart-only: the swap killed $($victims.Count) running app(s); starting the freshly installed exe (resume typing stays skipped)"
    $appProc = Start-Process -FilePath $oldExe -WorkingDirectory $WorkingDirectory -PassThru
    # Cache the handle now, or the EXITED branch below reads an empty code
    # (test\win32\lib\ExitCodeAudit.ps1).
    $null = $appProc.Handle
    $listJson = Wait-Instance 180 $appProc
    if ($listJson) {
        Log "relaunched app pid $($appProc.Id)"
        Complete-Upgrade 'no-resume, app relaunched'
    }
    # Say WHICH failure it is - they need different responses (same distinction
    # as the reuse path, 2026-07-30).
    $state = if ($appProc -and -not $appProc.HasExited) {
        "pid=$($appProc.Id) is ALIVE but never answered +list (IPC unreachable, not a dead app)"
    } else {
        "pid=$($appProc.Id) EXITED with $($appProc.ExitCode)"
    }
    Log "NO-RESUME RELAUNCH FAIL: $state; the app the swap killed was not brought back"
    exit 1
}

# Hand the stall to the watchdog NOW instead of leaving it for the heartbeat to
# go stale (tracker T439).
#
# The turn that launched this script is long gone by the time the resume runs -
# `launch-upgrade.ps1` only waits for the first log line - so a failure here is
# not observed by anyone. The watchdog is the supervisor, but its own gates are
# written for a session that stopped on its own: the lock is still HELD with a
# fresh heartbeat (the launching turn beat it minutes ago), so its next tick
# reports "healthy" and the loop stays dead until the heartbeat ages out, up to
# 45 minutes later. This is the one caller that KNOWS the loop is broken while
# the lock still looks fine, so it says so with -Force and the watchdog re-enters
# on the spot.
#
# The prompt goes by FILE, never on the command line: it is caller text that
# routinely contains quotes, and `powershell -File ... -ResumePrompt "<text>"`
# is the exact argv hop T210 exists to close.
function Invoke-WatchdogNow {
    param([string]$Why = '', [string]$PromptFile = '')
    $wd = Join-Path $PSScriptRoot 'go-loop-watchdog.ps1'
    if (-not (Test-Path $wd)) { Log "  watchdog handoff SKIPPED: $wd not found"; return }

    # Only hand off when the lock is HELD BY THIS PANE. That is the exact state
    # this exists for - a live session whose heartbeat is fresh and whose resume
    # nevertheless failed - and requiring it structurally rules out the
    # dangerous neighbour: with no lock and no pane, a forced tick falls through
    # to `+new-window --command="claude --continue"`, which is the T138 fork.
    # An upgrade run in a sandbox (the acceptance suite) has no such lock, so it
    # skips here rather than opening a window.
    $lockScript = Join-Path $PSScriptRoot 'go-loop-lock.ps1'
    $lock = $null
    if (Test-Path $lockScript) {
        try {
            $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $lockScript status `
                -Repo $WorkingDirectory -Json 2>&1 | Out-String
            $lock = $raw | ConvertFrom-Json
        } catch { $lock = $null }
    }
    if (-not $lock -or $lock.state -ne 'held' -or $lock.pane_id -ne $LoopPaneId) {
        $st = if ($lock) { "state=$($lock.state) pane=$($lock.pane_id)" } else { 'no lock' }
        Log "  watchdog handoff SKIPPED: the loop lock is not held by this pane ($st); leaving re-entry to the watchdog's own schedule"
        return
    }

    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wd,
        '-Repo', $WorkingDirectory, '-GhozttyExe', $oldExe, '-Once', '-Force')
    if ($PromptFile -and (Test-Path $PromptFile)) { $a += @('-ResumePromptFile', $PromptFile) }
    Log "  watchdog handoff: re-entering now ($Why)"
    try {
        $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList $a
        $null = $p.Handle   # before the wait, or ExitCode logs empty (test\win32\lib\ExitCodeAudit.ps1)
        if ($p.WaitForExit(120000)) { Log "  watchdog handoff: exited $($p.ExitCode) (see ghoztty-go-loop-watchdog.log)" }
        else { Log '  watchdog handoff: still running after 120s; left to finish on its own' }
    } catch {
        Log "  watchdog handoff FAILED: $($_.Exception.Message)"
    }
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
        # Cache the handle now: the "EXITED with <code>" branch below is how a
        # dead app is told from an unreachable one, and without this it reports
        # an empty code (test\win32\lib\ExitCodeAudit.ps1).
        $null = $appProc.Handle
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
        Complete-Upgrade "reuse, no pane id; claude pid=$loopPid still alive"
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

    # T439: being IN `+list` is not being ready to receive. The pane's surface
    # exists the moment restore builds it, but the agent is still replaying the
    # session ring into it and the TUI has not repainted - and on 2026-08-03
    # this line was logged 0-1s after the app was started, three deliveries in a
    # row, each followed by RESUME-REUSE FAIL 10-16s later. Wait for the pane to
    # stop changing before typing into it. `--when-idle` cannot substitute: an
    # un-replayed pane reads as empty and unchanged, which is exactly what it
    # calls idle.
    # T663: through $oldExe this read ZERO bytes every time - the pane was
    # always "produced no text", and the gate below always missed - so the
    # reader is the console twin.
    $ready = Wait-LoopPaneReady -ReadTail { (& $cliExe +read "--name=$LoopPaneId" --lines=40 2>$null) | Out-String }
    # Not fatal. A pane that never settles may just be one whose session is
    # printing, and the arrival gate below is the real evidence either way -
    # refusing to type here would trade a recoverable miss for a certain stall.
    if ($ready.Ready) { Log "reuse: pane ready ($($ready.Why))" }
    else { Log "WARNING: reuse: pane $LoopPaneId not settled ($($ready.Why)); typing anyway - the arrival gate below is what protects the run" }

    # T210: the prompt goes through a FILE, never argv - this was the LAST argv
    # hop in the whole delivery. T200 moved the launch onto -ResumePromptFile and
    # the identical defect survived one hop downstream, right here. See the
    # `New-LoopPromptFile` header in loop-session.ps1 for the measurements.
    # The exe is the one the swap just installed, so it normally HAS the flag.
    # Normally is not always: a stale staging build (T208's whole subject) would
    # leave an older exe here, and an exe without the flag types
    # `--keys-file=C:\...` into the pane as text. So ask, and say which transport
    # was used - a degraded send is exactly when the gate below matters most.
    $keys = New-LoopSendKeysText -Exe $cliExe -Text $prompt -Tag 'upgrade-resume'
    $promptFile = $keys.File
    if ($keys.Degraded) {
        Log "WARNING: $cliExe does not support +send-keys --keys-file, so the prompt is going through argv where PowerShell can mangle its quotes (T210). The arrival gate below is what protects the run."
    }

    # Type the prompt, VERIFY it, and only then submit it.
    #
    # T210: the old order was send-prompt-and-Enter-together, then look for the
    # prompt in the tail, then log "the TUI may have consumed it" and report
    # UPGRADE OK anyway. On 2026-07-30 that message WAS the symptom - the prompt
    # had been shredded on the way in, the reset never fired, and the session ran
    # to ~250k. A delivery step that reports OK while its real effect did not
    # happen is the expensive kind (T200, T208, this).
    #
    # Checking BEFORE the Enter is what makes the gate trustworthy. After a
    # submit the evidence is racing the session: `/reset-context` clears the pane
    # on purpose, so a fast reset erases the very text we would be looking for
    # and a correct delivery would fail its own check. Unsubmitted text just sits
    # in the input box.
    #
    # --when-idle: the session may still be finishing the turn that launched
    # this script. Polling for idle beats racing it.
    # Compare through Get-LoopPromptNeedle: the input box wraps the prompt, so
    # the tail holds the same characters with newlines and box borders injected.
    # Without that normalization a long prompt can never match - which is the
    # other reason the old check was written as a shrug.
    $want = Get-LoopPromptNeedle $prompt
    # T439: retry the whole type-and-verify cycle. One miss is not evidence the
    # send is impossible, it is usually evidence the pane was not ready yet, and
    # the old one-shot gate turned that into a dead loop three times in one day.
    # The composer is cleared between attempts so attempt N+1 cannot append to
    # attempt N's fragment.
    $verified = Send-LoopPromptVerified -Text $prompt `
        -SendText {
            & $cliExe +send-keys "--target=$LoopPaneId" --when-idle "--idle-timeout=60" @($keys.Args) 2>&1 |
                ForEach-Object { Log "reuse send-keys: $_" }
            return ($LASTEXITCODE -eq 0)
        } `
        -ReadTail { (& $cliExe +read "--name=$LoopPaneId" --lines=40 2>$null) | Out-String } `
        -Clear {
            & $cliExe +send-keys "--target=$LoopPaneId" Escape 2>&1 | ForEach-Object { Log "reuse clear: $_" }
        } `
        -Log { param($m) Log $m }
    if (-not $verified.Arrived) {
        # Do not submit a fragment: a half-arrived prompt is a chat message, and
        # a leftover fragment would concatenate with the watchdog's next nudge.
        # (Send-LoopPromptVerified has already cleared the composer.)
        #
        # Deliberately does not spell the success tag: a log grep for it must
        # never match a failure line (the acceptance test's E4 caught exactly
        # that when this message said "NOT UPGRADE OK").
        Log "RESUME-REUSE FAIL: the prompt did not arrive intact in pane $LoopPaneId after $($verified.Attempts) attempt(s) / $($verified.Reads) read(s) - it is NOT being submitted, and this run is NOT a successful upgrade. Wanted: '$want'"
        if ($promptFile) { Log "  prompt file kept for diagnosis: $promptFile" }
        Invoke-WatchdogNow -Why 'the resume prompt never arrived intact' -PromptFile $promptFile
        exit 1
    }
    Log "reuse: prompt verified in pane $LoopPaneId ($($verified.Why))"

    # Submit it - and NOT with a bare `Enter` (T438). The gate above is why this
    # is a second call at all, and a second call is exactly what T428's framing
    # cannot reach: the CLI frames a text run only when the same call also
    # carries the key run after it. So the submitting call brings its own
    # throwaway text run. See Get-LoopSubmitArgs in loop-session.ps1 for why a
    # single space is the payload that cannot turn a verified prompt into a
    # fragment.
    $submit = Get-LoopSubmitArgs
    & $cliExe +send-keys "--target=$LoopPaneId" @($submit) 2>&1 | ForEach-Object { Log "reuse submit: $_" }
    if ($LASTEXITCODE -ne 0) {
        Log "RESUME-REUSE FAIL: the prompt arrived intact in pane $LoopPaneId but the submit exited $LASTEXITCODE, so it was never submitted."
        Invoke-WatchdogNow -Why 'the prompt arrived but the Enter failed' -PromptFile $promptFile
        exit 1
    }
    # ...and then check that the SESSION took it, not just that the CLI exited 0
    # (T562). Three consecutive deliveries (08-04/05/06) logged RESUME-REUSE OK
    # over a prompt sitting unsubmitted in the composer, because a zero exit
    # code is the last thing this path knew how to ask about. Motion is the
    # evidence; another submit is the cure.
    $gate = Wait-LoopSubmitted `
        -Read { (& $cliExe +read "--name=$LoopPaneId" --lines=60 2>&1 | Out-String).Trim() } `
        -Submit { & $cliExe +send-keys "--target=$LoopPaneId" @(Get-LoopSubmitArgs) 2>&1 | ForEach-Object { Log "reuse re-submit: $_" } } `
        -Text $prompt
    if (-not $gate.Submitted) {
        Log "RESUME-REUSE FAIL: $($gate.Why) - pane $LoopPaneId is holding the prompt, so the loop is NOT running."
        if ($promptFile) { Log "  prompt file kept for diagnosis: $promptFile" }
        Invoke-WatchdogNow -Why 'the prompt was typed but never submitted' -PromptFile $promptFile
        exit 1
    }
    Log "reuse: submission verified ($($gate.Why))"
    if ($promptFile) { Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue }
    Log "RESUME-REUSE OK: prompt '$prompt' delivered AND submitted to pane $LoopPaneId (verified in the pane before Enter; claude pid=$loopPid, no second session)"
    Complete-Upgrade "reused claude pid=$loopPid in pane $LoopPaneId"
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
#
# T279: this goes through Invoke-NativeExact, not `& $cliExe ...`. $ResumeCommand
# carries a QUOTED prompt (`claude --continue "read go.md and go"`), and
# PowerShell 5.1 copies an embedded `"` onto the command line without escaping
# it - measured, the child used to receive
# `--command=claude ... --continue read` plus `go.md`, `and`, `go` as three
# stray positionals, so the relaunched session came up with no loop prompt at
# exit 0. Building the command line ourselves is the only total fix; see
# scripts/lib/NativeArgv.ps1 for why no escaper exists.
$relaunchTarget = 'main'
$rl = Invoke-NativeExact -FilePath $cliExe -Arguments @(
    '+new-window', '--target=main',
    "--working-directory=$WorkingDirectory",
    "--command=$ResumeCommand"
)
Log-NativeResult 'relaunch' $rl
for ($i = 0; $i -lt 14; $i++) {
    Start-Sleep -Milliseconds 750
    if ((Count-Windows (Get-ListJson).Json) -gt $before) { $relaunched = $true; break }
}
if ($relaunched) {
    Log "RELAUNCH-WINDOW OK: a new window is running the resume command (windows $before -> $($before + 1))"
} else {
    $alt = 'main-' + (Get-Date -Format 'HHmmss')
    $relaunchTarget = $alt
    Log "relaunch: no new window appeared - an existing 'main' was focused instead of created; retrying as $alt"
    $rl = Invoke-NativeExact -FilePath $cliExe -Arguments @(
        '+new-window', "--target=$alt",
        "--working-directory=$WorkingDirectory",
        "--command=$ResumeCommand"
    )
    Log-NativeResult 'relaunch' $rl
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
# T166: `+list --json` now reports the real working_directory for agent-backed
# panes (the app threads the agent-recorded cwd through OPEN and ATTACHED), so
# read the RELAUNCHED window's own pane, by name. The old shape - first
# non-empty wd anywhere in the list, then the T138 `+sessions --json` fallback
# - predates that: it could only vouch for "some pane somewhere", which once
# most panes report a cwd could be a DIFFERENT window's and mis-grade the
# guard in either direction.
function Get-PaneWd($json, $target) {
    if (-not $json) { return $null }
    try { $tree = $json | ConvertFrom-Json } catch { return $null }
    $windows = if ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    foreach ($w in $windows) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) {
            $node = $t.splits
            while ($null -ne $node -and $node.type -eq 'split') { $node = $node.left }
            if ($null -ne $node -and $node.type -eq 'leaf' -and $node.terminal.working_directory) {
                return [string]$node.terminal.working_directory
            }
        }
    }
    return $null
}
$landed = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 750
    $landed = Get-PaneWd (Get-ListJson).Json $relaunchTarget
    if ($landed) { break }
}
if (-not $landed) {
    Log 'RELAUNCH-CWD UNKNOWN: no pane working_directory reported; check the new window by hand'
} elseif ($landed.TrimEnd('\') -ieq $WorkingDirectory.TrimEnd('\')) {
    Log "RELAUNCH-CWD OK: $landed"
} else {
    Log "RELAUNCH-CWD FAIL: pane landed in '$landed', expected '$WorkingDirectory' -- the resumed session will not find its conversation and the loop is STALLED (see T132)"
}
Complete-Upgrade "relaunched, resume: $ResumeCommand"
