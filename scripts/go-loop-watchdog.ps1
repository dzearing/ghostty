# Watchdog for the go.md parity loop (tracker T139b).
#
# go.md says outright "Nothing supervises this loop": it perpetuates itself
# only through the /reset-context at the end of every turn, so a single turn
# that ends with a summary instead kills it silently. That has happened twice -
# six dead days (2026-07-21 -> 07-27) and again on 2026-07-28. This script is
# the supervisor: it watches the loop lock's heartbeat (scripts\go-loop-lock.ps1)
# and re-enters the loop when the heartbeat goes stale while tasks remain.
#
# Per tick:
#   0. If a stop has been requested (go-loop-exec.ps1 stop), do nothing at all.
#      This must come first: "tasks remain" is the re-entry trigger, so a
#      requested stop is exactly the state that would otherwise revive the loop.
#   1. If no open task file remains that this seat could work (status todo/
#      in-progress/blocked under docs\design\windows-parity-tasks\, minus
#      seat: mac tasks), do nothing - the loop is finished, not stuck.
#   2. Read the lock. Healthy (owner alive AND a recent sign of life AND a turn
#      that has completed recently) -> do nothing. Since T253 "sign of life" is
#      the newer of the heartbeat and the session transcript's mtime, so a turn
#      that is working beats it without anybody remembering to - see
#      scripts\go-loop-lock.ps1.
#
#      Since T1319 a sign of life is not enough on its own. A signal anything at
#      all can move - including this watchdog's own nudge, and including the
#      keystrokes that type a continuation into the composer and never send it -
#      cannot answer "is the loop WORKING". So the lock's `turn_age_minutes`
#      (which only a completed turn moves) is read too, and a held lock whose
#      turn has not completed inside -TurnStaleMinutes is re-entered anyway. A
#      pane holding UNSENT composer text trips the same wire at the lower
#      -TurnSuspectMinutes, because that is the exact shape that hid a 2h32m
#      stall behind a 31-minute transcript on 2026-09-04 - and since T1370 so
#      does an IDLE Claude TUI, which is what a turn truncated mid-sentence
#      leaves behind and what the composer arm cannot see.
#   3. Otherwise re-enter, choosing the cheapest action that fits:
#        a claude is alive IN THE PANE, pane not producing output
#                              -> send-keys the resume prompt + Enter
#                                 (the turn ended with a report; nudge it).
#                                 The default prompt is RESET-FIRST (T253) so
#                                 that a nudge landing on a session that was
#                                 alive after all costs a context reset, never
#                                 a second task in the same context.
#        pane alive but sitting at a shell prompt
#                              -> send-keys the resume shim + Enter
#        no lock / pane gone   -> +new-window running the resume shim
#      then hold off for -RearmMinutes so a wedged box is not spammed.
#
# "A claude is alive IN THE PANE" is deliberately not "the pid I recorded is
# alive" (T241). A claude relaunched in the pane has a new pid and has not
# claimed the lock yet, so the recorded pid is a corpse while the pane is
# occupied - and on 2026-07-31 that made this script type the shim's PATH into
# a live Claude Code TUI, where it became a chat message. send-keys exit=0,
# nothing re-entered, no error anywhere. So the pane is asked directly
# (scripts\go-loop-pane-probe.ps1), and every typed re-entry is verified by
# reading the pane back afterwards.
#
# It also watches its own source and re-execs when this file or
# loop-session.ps1 changes, so an edit here takes effect without anyone
# remembering to restart a process that has been up for a week.
#
# Run detached so it survives the terminal that started it:
#   Start-Process powershell -WindowStyle Hidden -ArgumentList `
#     '-NoProfile','-ExecutionPolicy','Bypass','-File',
#     'D:\git\ghoztty\scripts\go-loop-watchdog.ps1'
#
# Or register it to autostart (no elevation needed):
#   powershell -NoProfile -File scripts\go-loop-watchdog.ps1 -Install
#   powershell -NoProfile -File scripts\go-loop-watchdog.ps1 -Uninstall
#   powershell -NoProfile -File scripts\go-loop-watchdog.ps1 -Status
#
# -Install registers TWO things, because one of them is not enough (T440). The
# HKCU Run entry starts it at sign-in and that is all it ever does: on
# 2026-08-03 this process died at 09:14 and stayed dead for thirteen hours,
# because nothing between one logon and the next re-runs a Run entry. So
# -Install also creates a per-user scheduled task that re-launches this script
# every -ReviveMinutes. Re-launching is safe to do forever: the single-instance
# mutex makes it a no-op while the watchdog is alive, so the task is a revival
# trigger rather than a second supervisor.
#
# Every action is appended to %TEMP%\ghoztty-go-loop-watchdog.log, and every
# TICK - including the ticks where the right answer is to do nothing - stamps a
# heartbeat into the state file so a reader can tell "supervising quietly" from
# "gone" without reading a log to find out whether the silence-watcher is
# silent.
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$LockPath,
    # One file per task (T479). The old -Tracker parameter pointed at
    # windows-parity-tasks.md, whose state table FROZE on 2026-07-29 when the
    # tasks moved one-per-file - the row count was fiction from then on, and
    # anyone tidying the historical table to zero would have switched this
    # supervisor off forever.
    [string]$TaskDir,
    [string]$GhozttyExe = "$env:LOCALAPPDATA\Programs\Ghoztty\ghoztty.exe",
    # RESET-FIRST, on purpose (T253). This text is typed into a session that may
    # be alive and mid-task: Claude Code QUEUES input received during a turn and
    # delivers it when the turn ends, so a bare "read go.md and go" starts a
    # SECOND task in a context that already holds one - the exact failure the
    # context rule exists to prevent. Phrased this way, a nudge that turns out to
    # be unnecessary costs a context reset instead of a rule violation, and a
    # nudge that was necessary does what step 7 would have done anyway.
    #
    # It deliberately does NOT begin with '/'. A leading slash opens Claude
    # Code's command menu, and the first Enter is then eaten selecting the
    # completion rather than submitting - the reset-context skill has to send
    # Enter twice and read the pane back to work around it, which is far too
    # much ceremony for an unattended safety net.
    [string]$ResumePrompt = 'Before starting any task, run /reset-context read go.md and go',
    # The same text, out of a FILE. Callers whose prompt is caller-authored (the
    # upgrade's resume prompt routinely carries quotes) must use this: passing it
    # as `powershell -File ... -ResumePrompt "<text>"` is the argv hop T210
    # exists to close. Wins over -ResumePrompt when the file is readable.
    [string]$ResumePromptFile,
    [string]$ClaudeCommand = 'claude --dangerously-skip-permissions --continue',
    [string]$WindowTarget = 'main',
    [int]$PollSeconds = 300,
    [int]$StaleMinutes = 45,
    [int]$RearmMinutes = 20,
    # The PROGRESS clock, beside the liveness one above (T1319). -StaleMinutes
    # asks "has anything touched this session lately"; these two ask "has the
    # loop finished a turn lately", which is the question a supervisor is for.
    # Defaults match go-loop-health.ps1's -TurnStaleMinutes so the observer and
    # the actor cannot disagree about what a stalled loop is.
    #
    # -TurnSuspectMinutes is the lower bar that the PANE unlocks: unsent text,
    # or a session with nothing in flight, plus no completed turn is a stalled
    # turn however fresh the transcript looks. Everything downstream still
    # applies - a pane that is producing output is never nudged - so these decide
    # when to LOOK, not when to type.
    [int]$TurnStaleMinutes = 180,
    [int]$TurnSuspectMinutes = 45,
    # The still-producing backstop's sample (T253). It was 5 lines over 8s, which
    # is too thin to tell "wedged" from "compiling": a session between phases, or
    # one whose bottom five lines are a static composer box, read as not
    # producing while the turn was alive. A whole screen over 20s catches the
    # spinner, the elapsed-time counter and any scrolling output, and 20s is free
    # here - the poll interval is 300s.
    [int]$ProbeGapSeconds = 20,
    [int]$ProbeLines = 60,
    [int]$VerifySeconds = 6,    # how long to give a shim'd pane to paint claude
    [string]$LogPath,
    # Overridable for the same reason LockPath and StatePath are: the harness
    # drives this script against the real repo with fixture state.
    [string]$StopPath,
    [string]$StatePath,
    [switch]$Once,          # single tick then exit (used by the acceptance test)
    # Re-enter even though the lock looks healthy (T439). The two gates this
    # skips - "state is held" and the rearm hold-off - both exist to keep the
    # watchdog from interrupting a session that is working. A caller that KNOWS
    # the loop is broken while the lock still looks fine (the upgrade script,
    # whose resume prompt never landed) is the case they get wrong: the lock was
    # beaten minutes ago by the turn that launched the upgrade, so without this
    # the loop stays dead for up to -StaleMinutes. Everything downstream of the
    # gates still applies, including "the pane is still producing output, do not
    # nudge" - -Force says the heartbeat is not evidence, not that nothing is.
    [switch]$Force,
    [switch]$DryRun,        # decide and log, but take no action
    # How often the revival scheduled task re-launches this script (T440). The
    # launch is a no-op whenever the watchdog is already alive, so this is the
    # WORST-CASE dead time after a crash, not a polling cost.
    [int]$ReviveMinutes = 10,
    # Test seam only. The single-instance mutex is global by design; an
    # acceptance script that needs its own short-lived watchdog (hermetic state
    # file, 2s poll) would otherwise be refused by the user's real one.
    [string]$MutexName = 'Global\GhozttyGoLoopWatchdog',
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status         # report autostart + liveness, change nothing
)

$ErrorActionPreference = 'Continue'

if (-not $LockPath) { $LockPath = Join-Path (Join-Path $Repo 'temp') 'go-loop.lock.json' }
if (-not $TaskDir) { $TaskDir = Join-Path $Repo 'docs\design\windows-parity-tasks' }
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP 'ghoztty-go-loop-watchdog.log' }
if (-not $StatePath) { $StatePath = Join-Path (Join-Path $Repo 'temp') 'go-loop.watchdog.json' }

$lockScript = Join-Path $PSScriptRoot 'go-loop-lock.ps1'
$probeScript = Join-Path $PSScriptRoot 'go-loop-pane-probe.ps1'
. $probeScript      # Get-PaneOccupant / Read-PaneOccupant
# New-LoopPromptFile / Get-LoopPromptNeedle (T210). Functions only, no side
# effects at load.
. (Join-Path $PSScriptRoot 'loop-session.ps1')
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue = 'GhozttyGoLoopWatchdog'

function Log($m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    try { $line | Add-Content $LogPath } catch { }
    # Write-Host, not the pipeline: Invoke-Tick returns its action string and a
    # log line leaking into that stream would make the return value an array.
    Write-Host $line
}

# -ResumePromptFile wins over -ResumePrompt, but only when it actually reads: an
# unreadable or empty file must fall back to the default prompt rather than
# re-enter the loop with an empty message. Which one won is logged, because a
# re-entry that types the wrong prompt is the failure this whole file exists to
# catch.
if ($ResumePromptFile) {
    $fromFile = ''
    try { $fromFile = (Get-Content -LiteralPath $ResumePromptFile -Raw -ErrorAction Stop) } catch { $fromFile = '' }
    if ($fromFile -and $fromFile.Trim()) {
        $ResumePrompt = $fromFile.Trim()
        Log "resume prompt read from file ($($ResumePrompt.Length) chars): $ResumePromptFile"
    } else {
        Log "WARNING: -ResumePromptFile '$ResumePromptFile' is missing or empty; falling back to -ResumePrompt"
    }
}

# --- install / uninstall --------------------------------------------------

# Autostart is an HKCU Run entry (the mechanism T89h gave the local agent) PLUS
# a repeating per-user scheduled task. Neither alone is enough: a Run entry
# fires at sign-in only, so a watchdog that dies at 09:14 is gone until the next
# logon - which is exactly what happened on 2026-08-03 (T440).
#
# The task carries BOTH triggers now (T829). `schtasks /sc ONLOGON` does need
# elevation, which is why this was minute-repetition only for a year; the
# ScheduledTasks module registering an AtLogOn trigger for one's OWN account
# does not, measured on the box. So a session appearing revives the watchdog
# immediately instead of up to -ReviveMinutes later, and this loop stays
# installable from an ordinary session.
#
# The command itself is wscript.exe on a generated launcher, not powershell.exe
# (T1192): a Run entry firing powershell at sign-in gets a console before it can
# read -WindowStyle Hidden, and with Windows Terminal as the default terminal
# application that console is a real window that takes focus. go-loop-boot.ps1
# owns the launcher, so the Run entry and the revive task cannot end up with two
# different launch shapes; it prints the command line to use.
function Get-RunCommand {
    $bootScript = Join-Path $PSScriptRoot 'go-loop-boot.ps1'
    $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $bootScript launcher `
        -Repo $Repo -WatchdogScript $PSCommandPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $out -match '^wscript') { return $out }
    # Loud rather than silent: a Run entry is only read at sign-in, so a quiet
    # fallback here would not be noticed until the next reboot.
    Log "WARNING: could not build the windowless launcher ($out); falling back to powershell"
    return "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Repo `"$Repo`""
}

function Test-ReviveTask {
    & schtasks /query /tn $runValue *> $null
    return ($LASTEXITCODE -eq 0)
}

# Ask the single-instance mutex, not the process list: a command-line match on
# the script name also matches the shell that is running -Install right now.
function Test-WatchdogRunning {
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    try {
        if ($m.WaitOne(0)) { $m.ReleaseMutex(); return $false }
        return $true
    } finally { $m.Dispose() }
}

# The long-running watchdog is the invocation with no mode switch; -Install /
# -Uninstall / -Once shells must never be mistaken for it.
function Get-WatchdogProcs {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -like '*go-loop-watchdog.ps1*' -and
        $_.CommandLine -notlike '*-Install*' -and
        $_.CommandLine -notlike '*-Uninstall*' -and
        $_.CommandLine -notlike '*-Status*' -and
        $_.CommandLine -notlike '*-Once*'
    })
}

if ($Install) {
    $cmd = Get-RunCommand
    Set-ItemProperty -Path $runKey -Name $runValue -Value $cmd
    Log "installed Run entry $runValue -> $cmd"

    # The task's SHAPE lives in one place (T829). It used to be a `schtasks
    # /create /sc MINUTE` right here, which registered the Task Scheduler
    # defaults along with the schedule: battery-gated, 72-hour execution limit,
    # and no logon trigger - so a laptop on battery never revived, the 72-hour
    # limit killed the very watchdog the task had started, and a session
    # appearing waited up to -ReviveMinutes to be noticed. go-loop-boot.ps1
    # owns the shape and reads it back after registering; two owners of one
    # task is how the flags drift apart again.
    $bootScript = Join-Path $PSScriptRoot 'go-loop-boot.ps1'
    $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $bootScript install `
        -Repo $Repo -WatchdogScript $PSCommandPath -TaskName $runValue -ReviveMinutes $ReviveMinutes 2>&1 |
        Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { Log "installed revive task $runValue (at logon + every ${ReviveMinutes}m)" }
    else { Log "WARNING: could not install the revive task (exit $LASTEXITCODE): $out" }

    if (Test-WatchdogRunning) {
        Log "watchdog already running (pid $((Get-WatchdogProcs).ProcessId -join ', '))"
        exit 0
    }
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Repo', $Repo) | Out-Null
    Log 'watchdog started'
    exit 0
}
if ($Uninstall) {
    Remove-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue
    & schtasks /delete /tn $runValue /f *> $null
    Get-WatchdogProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Log "uninstalled Run entry + revive task $runValue and stopped any running watchdog"
    exit 0
}

# --- helpers --------------------------------------------------------------

# How many open tasks THIS seat could still work: files under $TaskDir whose
# frontmatter status is todo/in-progress/blocked(...), minus `seat: "mac"`
# tasks - parity-tasks.ps1 `next` will never hand one of those to this box, so
# they cannot justify re-entering a loop that would find nothing to do (T479).
#
# The status sweep is a whole-file grep on purpose: a body line that happens to
# start with `status: "todo"` (a task quoting the frontmatter format) can only
# INFLATE the count, and an inflated count keeps the supervisor alive - the safe
# direction. The seat check errs the other way (a false mac match deflates), so
# it reads only the frontmatter block of the open files it filters.
function Get-RemainingTasks {
    if (-not (Test-Path $TaskDir)) { return -1 }   # unknown: never blocks re-entry
    $open = @(Select-String -Path (Join-Path $TaskDir 'T*.md') `
            -Pattern '^status:\s*"?(todo|in-progress|blocked)' -List `
            -ErrorAction SilentlyContinue | ForEach-Object Path)
    if ($open.Count -eq 0) {
        # A task dir with no task files at all is a broken checkout, not a
        # finished project: stay "unknown" rather than declaring the loop done.
        if (@(Get-ChildItem -Path $TaskDir -Filter 'T*.md' -ErrorAction SilentlyContinue).Count -eq 0) { return -1 }
        return 0
    }
    $remaining = 0
    foreach ($p in $open) {
        $isMac = $false
        foreach ($line in @(Get-Content -Path $p -TotalCount 40 -ErrorAction SilentlyContinue | Select-Object -Skip 1)) {
            if ($line -match '^---') { break }                       # end of frontmatter
            if ($line -match '^seat:\s*"?mac') { $isMac = $true; break }
        }
        if (-not $isMac) { $remaining++ }
    }
    return $remaining
}

# -NoPaneProbe is load-bearing (T440). `status` now answers "is the loop alive"
# with the PANE's opinion when the recorded pid is dead, which is right for
# every reader - and wrong for this one. "The recorded pid is a corpse but a
# claude is sitting in the pane" is not a healthy loop to the watchdog, it is
# its single most important cue: that is the relaunched-but-idle session (T241,
# T439), and the whole nudge path below exists to re-enter it. Reading it as
# `held` would make the watchdog do nothing in exactly the case it was built
# for. So it asks the pid question here and decides about the pane itself,
# further down, with a probe it can act on.
function Get-Lock {
    $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $lockScript status `
        -Repo $Repo -LockPath $LockPath -StaleMinutes $StaleMinutes -NoPaneProbe -Json 2>&1 | Out-String
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Invoke-Ghoztty($argList) {
    # T279: the command line is built HERE, not by PowerShell 5.1, whose builder
    # copies an embedded `"` through unescaped and drops a trailing `\` into the
    # closing quote. This path carries a generated shim PATH and a pane's
    # `--command=`, both of which can contain either.
    #
    # It also settles T663 for this script: reaching CreateProcess directly
    # captures a GUI-subsystem exe's stdout with no `2>&1` merge, so a stderr
    # line can no longer land inside the `+list --json` this parses.
    $r = Invoke-NativeExact -FilePath (Resolve-GhozttyCliExe $GhozttyExe) -Arguments @($argList)
    return @{ Code = $r.Code; Out = $r.Out.Trim(); Err = $r.Err.Trim() }
}

function Test-PaneExists($paneId) {
    if (-not $paneId) { return $false }
    $r = Invoke-Ghoztty @('+list', '--json')
    if ($r.Code -ne 0) { return $false }
    return ($r.Out -match [regex]::Escape($paneId))
}

# A stale heartbeat with a live claude means the turn ended without a reset -
# unless the session is simply mid-task and slow. Sample the pane twice: output
# that is still moving means it is working, so leave it alone.
#
# Since T253 this is the SECOND line of defence, not the first - the lock's own
# freshness now follows the session transcript, so a working turn rarely reaches
# here at all. It is still widened, because a backstop that cannot tell a
# compiling session from a wedged one is not a backstop (see -ProbeLines).
function Test-PaneProducing($paneId, $gapSeconds = $ProbeGapSeconds, $lines = $ProbeLines) {
    $a = Invoke-Ghoztty @('+read', "--name=$paneId", "--lines=$lines")
    if ($a.Code -ne 0) { return $false }
    Start-Sleep -Seconds $gapSeconds
    $b = Invoke-Ghoztty @('+read', "--name=$paneId", "--lines=$lines")
    if ($b.Code -ne 0) { return $false }
    return ($a.Out -ne $b.Out)
}

# The resume command carries a quoted prompt; sending it through send-keys or
# --command as one argument is exactly the quoting that T138's upgrade script
# got wrong (its log shows `--continue read`, the prompt truncated at the first
# space). A generated .cmd shim sidesteps every layer of quoting.
function New-ResumeShim {
    $path = Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd'
    $body = @(
        '@echo off',
        "cd /d `"$Repo`"",
        "$ClaudeCommand `"$ResumePrompt`""
    ) -join "`r`n"
    Set-Content -Path $path -Value $body -Encoding ascii
    return $path
}

# The lock names a dead pid but the pane holds a live claude (T241): point the
# lock at that claude so the next tick reads `healthy` instead of re-deciding.
# Only when it is unambiguous - guessing an owner is worse than leaving the
# lock stale, because the nudged session rewrites it at go.md step 0 anyway.
function Invoke-Adopt($lock, $paneId) {
    if (-not $lock -or -not $paneId) { return }
    $recorded = $null
    if ($lock.claude_start) {
        try {
            $recorded = [datetime]::Parse($lock.claude_start, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
        } catch { $recorded = $null }
    }
    $cands = @(Get-Process claude -ErrorAction SilentlyContinue | Where-Object {
        $start = $null
        try { $start = $_.StartTime } catch { $start = $null }
        (-not $recorded) -or (-not $start) -or ($start -gt $recorded)
    })
    if ($cands.Count -ne 1) {
        Log "  adopt skipped: $($cands.Count) candidate claude process(es); the nudged session will reclaim the lock itself"
        return
    }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $lockScript adopt `
        -Repo $Repo -LockPath $LockPath -PaneId $paneId -ClaudePid $cands[0].Id 2>&1 | Out-String
    Log "  adopt pid=$($cands[0].Id): $($out.Trim())"
}

function Read-State {
    if (-not (Test-Path $StatePath)) { return $null }
    try { return (Get-Content $StatePath -Raw | ConvertFrom-Json) } catch { return $null }
}

# Merge rather than overwrite: the state file now carries two independent
# stories - the last RE-ENTRY (for the rearm hold-off) and the last TICK (for
# anyone asking whether this process still exists). Writing one must not erase
# the other.
function Update-State($fields) {
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $obj = [ordered]@{}
    $cur = Read-State
    if ($cur) { foreach ($p in $cur.PSObject.Properties) { $obj[$p.Name] = $p.Value } }
    foreach ($k in $fields.Keys) { $obj[$k] = $fields[$k] }
    $tmp = "$StatePath.$PID.tmp"
    ($obj | ConvertTo-Json -Depth 5) | Out-File -FilePath $tmp -Encoding utf8
    Move-Item -Force $tmp $StatePath
}

function Write-State($action) {
    Update-State @{ last_action = $action; last_action_at = (Get-Date).ToString('o') }
}

# The beacon this watchdog is judged by (T440). A supervisor that is doing its
# job writes no actions at all, so "last action" cannot distinguish healthy from
# gone - and the only other evidence was a log that stops, which nobody reads
# until they already suspect. Every tick stamps this instead.
#
# ONLY the long-running daemon writes it. A -Once tick (the acceptance harness,
# and the upgrade script's -Force handoff) is a process that exits seconds
# later; stamping its pid here would report the supervisor as dead moments after
# a handoff that worked.
function Write-Health($tickAction) {
    if ($Once) { return }
    Update-State @{
        watchdog_pid  = $PID
        watchdog_host = $env:COMPUTERNAME
        tick_at       = (Get-Date).ToString('o')
        poll_seconds  = $PollSeconds
        last_tick     = $tickAction
    }
}
function Get-MinutesSinceAction {
    $s = Read-State
    if (-not $s -or -not $s.last_action_at) { return [double]::PositiveInfinity }
    try { return ((Get-Date) - [datetime]::Parse($s.last_action_at, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes }
    catch { return [double]::PositiveInfinity }
}

# --- status ---------------------------------------------------------------

if ($Status) {
    $s = Read-State
    $tickAge = 'never'
    if ($s -and $s.tick_at) {
        try {
            $t = [datetime]::Parse($s.tick_at, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
            $tickAge = '{0:N1}m ago' -f ((Get-Date) - $t).TotalMinutes
        } catch { $tickAge = 'unparseable' }
    }
    $run = (Get-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue)
    $lines = @(
        "running:    $(Test-WatchdogRunning)",
        "pids:       $((Get-WatchdogProcs).ProcessId -join ', ')",
        "last tick:  $tickAge (action=$(if ($s) { $s.last_tick } else { '-' }))",
        "run entry:  $(if ($run) { 'present' } else { 'MISSING' })",
        "revive task:$(if (Test-ReviveTask) { " present (every ${ReviveMinutes}m)" } else { ' MISSING' })",
        "state file: $StatePath"
    )
    $lines
    exit 0
}

# --- one tick -------------------------------------------------------------

function Invoke-Tick {
    # A deliberate stop outranks everything below, including open tasks -
    # "tasks remain" is the watchdog's whole trigger, so without this check a
    # requested stop is precisely the condition that makes it re-enter. Checked
    # first and cheaply, before any lock or pane probe.
    $stop = Get-LoopStop -Repo $Repo -Path $StopPath
    if ($stop) {
        Log ("stopped by request at $($stop.requested_at) by $($stop.requested_by)" +
             $(if ($stop.reason) { " - $($stop.reason)" } else { '' }) +
             '; not re-entering. Clear with go-loop-exec.ps1 resume')
        return 'stopped'
    }

    $remaining = Get-RemainingTasks
    if ($remaining -eq 0) { Log 'idle: no open tasks for this seat'; return 'none' }

    $lock = Get-Lock
    $state = 'free'
    if ($lock -and $lock.state) { $state = $lock.state }

    # The progress clock (T1319). `turn_age_minutes` is the lock's own field -
    # only a completed turn moves it - and it is null on a lock written before
    # T1290, which reads as "unknown" rather than as zero.
    $turnAge = [double]::PositiveInfinity
    if ($lock -and ($lock.PSObject.Properties.Name -contains 'turn_age_minutes') -and
        $null -ne $lock.turn_age_minutes) {
        $turnAge = [double]$lock.turn_age_minutes
    }
    $turnText = if ([double]::IsInfinity($turnAge)) { 'unknown' } else { '{0:N1}m' -f $turnAge }
    # Every decision line carries BOTH clocks and the limit each was measured
    # against. The 2026-09-04 log said `healthy` thirty times and the number it
    # believed - 31.51m of transcript age against a 2h32m turn - could only be
    # reconstructed afterwards by re-deriving it.
    $clocks = ("age=$($lock.age_minutes)m(by=$($lock.activity_by)) " +
               "turn_age=$turnText(limit=${TurnStaleMinutes}m)")

    if ($state -eq 'held' -and -not $Force) {
        # The pane is only read once the turn clock is already elevated: the
        # probe costs an IPC round trip per tick, and unsent text - or an idle
        # session - ten minutes after a turn completed is a user typing or the
        # gap between turns, not a stall. One read answers both questions
        # (T1370).
        # PROBE ON EVERY TICK, DECIDE ON THE SAME BARS (user, 2026-09-07).
        #
        # The read used to be gated on the same threshold the verdict uses, which
        # made the log unable to answer the one question needed to move that
        # threshold. Two idle stalls today were each caught at ~47m, and both had
        # gone quiet about 40m in - so the obvious move is a lower bar. But the
        # evidence for it did not exist and COULD NOT: a pane under 45m was never
        # looked at, and past 45m an idle pane is stalled by definition, so
        # "healthy and idle" was impossible by construction rather than unobserved.
        # Counting it and calling it proof is the circular argument this comment
        # exists to stop someone (me, next time) from making.
        #
        # So: look every tick, change no threshold. After a few days the log can
        # say how often a HEALTHY loop under 45m reads idle - during a 4-minute
        # Start-Sleep, a long build, a background lane - and that is the number
        # that decides whether the bar can come down. `probed=` marks a real
        # observation so a future reader never has to guess again.
        $pane = @{ Composer = ''; Working = 'unknown' }
        $probed = $false
        if ($lock.pane_id) {
            $pane = Read-PaneState -PaneId $lock.pane_id -GhozttyExe $GhozttyExe
            $probed = $true
        }
        # And SAY what it saw. T1319's arm was diagnosed off `limit=180m` alone -
        # the log named the bar it chose but never the observation behind it, so
        # "the composer looked empty" and "the composer was never read" were the
        # same line. Both now appear on every decision (T1370).
        $seen = ("composer=$(if ($pane.Composer) { 'pending' } else { 'none' }) " +
                 "session=$($pane.Working) probed=$probed")
        $verdict = Resolve-LoopStallVerdict -TurnAgeMinutes $turnAge `
            -StaleMinutes $TurnStaleMinutes -SuspectMinutes $TurnSuspectMinutes `
            -ComposerText $pane.Composer -PaneState $pane.Working
        if (-not $verdict.Stalled) {
            Log "healthy: pane=$($lock.pane_id) pid=$($lock.claude_pid) $clocks $seen remaining=$remaining"
            return 'none'
        }
        Log ("STALLED(by=$($verdict.Clock)): the lock reads held but $($verdict.Why) - " +
             "deciding by the turn clock, not the pane pulse ($clocks $seen; T1319)")
    }
    if ($Force) { Log "forced: re-entry requested despite state=$state (caller knows the loop is broken; T439)" }

    $since = Get-MinutesSinceAction
    if ($since -lt $RearmMinutes -and -not $Force) {
        Log ("stale ($state) but rearm not elapsed ({0:N1}m < {1}m); waiting" -f $since, $RearmMinutes)
        return 'none'
    }

    $paneId = ''
    if ($lock) { $paneId = $lock.pane_id }
    $paneAlive = Test-PaneExists $paneId
    $ownerAlive = $false
    if ($lock -and $null -ne $lock.owner_alive) { $ownerAlive = [bool]$lock.owner_alive }

    # T241: ask the PANE who is listening, not the lock. The recorded pid is
    # stale for the whole window between a claude relaunching in the pane and
    # that session running go.md step 0, and typing a shell command into a TUI
    # is a silent no-op.
    $occupant = 'unknown'
    if ($paneAlive) {
        $occupant = Read-PaneOccupant -PaneId $paneId -GhozttyExe $GhozttyExe
        Log "pane $paneId occupant=$occupant (lock owner_alive=$ownerAlive)"
    }

    if ($paneAlive -and ($ownerAlive -or $occupant -eq 'claude')) {
        if (Test-PaneProducing $paneId) {
            Log "stale heartbeat but pane $paneId is still producing output; not nudging"
            return 'none'
        }
        Log "re-entering: nudge live session in pane $paneId (state=$state, occupant=$occupant, $clocks, remaining=$remaining)"
        if ($DryRun) { return 'nudge' }
        # T210: the prompt goes through a file when the exe supports it, never
        # blindly - PowerShell 5.1 does not escape an embedded `"` when it builds
        # a native command line, and +send-keys concatenates its positional
        # arguments with no separator, so a re-tokenized prompt arrives as
        # run-together prose. The default prompt has no quotes, but -ResumePrompt
        # is caller text and this is the loop's safety net.
        #
        # The capability probe is not optional here: this watchdog is a long-lived
        # HKCU Run process driving whichever ghoztty is INSTALLED, which is
        # routinely older than the repo. An exe without the flag would type
        # `--keys-file=C:\...` into the pane - the T241 failure, recreated by its
        # own fix.
        # T562: wipe the composer before typing. The wedge this nudge most
        # often arrives at IS a full composer - a continuation an earlier reset
        # typed and never submitted - and typing on top of it concatenates into
        # one run-together message that clears nothing (the 2026-07-28
        # "nn/clear" failure, which reset-context.sh already guards with the
        # same keystroke).
        $r = Invoke-Ghoztty @('+send-keys', "--target=$paneId", 'C-u')
        Log "  wiped composer exit=$($r.Code) $($r.Out)"
        Start-Sleep -Milliseconds 500
        $keys = New-LoopSendKeysText -Exe $GhozttyExe -Text $ResumePrompt -Tag 'watchdog-nudge'
        if ($keys.Degraded) { Log '  note: this ghoztty predates --keys-file; prompt sent through argv' }
        $r = Invoke-Ghoztty (@('+send-keys', "--target=$paneId") + $keys.Args + @('Enter'))
        Log "  send-keys exit=$($r.Code) $($r.Out)"
        if ($keys.File) { Remove-Item -LiteralPath $keys.File -ErrorAction SilentlyContinue }
        # And VERIFY it was submitted, not merely typed (T562). Exit 0 says the
        # bytes reached the pane; only motion says the session took them. A
        # backstop that leaves the loop at a full composer has not backstopped
        # anything - that is the exact state it was woken up to clear.
        #
        # The watchdog can read the composer, so it hands the gate the direct
        # question rather than the motion proxy (user, 2026-09-06): this pane
        # routinely has a background lane run streaming into it, and motion
        # alone called that "submitted" over a composer that sat unsent for 76
        # minutes.
        $gate = Wait-LoopSubmitted `
            -Read { (Invoke-Ghoztty @('+read', "--name=$paneId", '--lines=60')).Out } `
            -Submit { Invoke-Ghoztty (@('+send-keys', "--target=$paneId") + (Get-LoopSubmitArgs)) | Out-Null } `
            -Composer { (Read-PaneState -PaneId $paneId -GhozttyExe $GhozttyExe).Composer } `
            -Text $ResumePrompt
        if ($gate.Submitted) { Log "  NUDGE SUBMITTED: $($gate.Why)" }
        else { Log "  NUDGE UNSUBMITTED: $($gate.Why)" }
        # The lock still names a dead pid, so every later tick would re-decide
        # from scratch. Hand it the pane's own claude when that is unambiguous.
        if (-not $ownerAlive) { Invoke-Adopt $lock $paneId }
        Write-State 'nudge'
        return 'nudge'
    }

    $shim = New-ResumeShim
    if ($paneAlive) {
        Log "re-entering: no claude in pane $paneId (occupant=$occupant), running the resume shim there (remaining=$remaining)"
        if ($DryRun) { return 'restart-in-pane' }
        # T280: the shim PATH rides the same transport the prompt does - a file,
        # whose bytes `+send-keys` writes verbatim. It used to be a positional
        # argument with every backslash doubled by hand, which worked but left
        # two transports for one kind of text and only one of them safe. The
        # capability probe still decides: against an exe that predates
        # `--keys-file` the helper degrades to the escaped positional, which is
        # exactly what this line used to do unconditionally.
        $keys = New-LoopSendKeysText -Exe $GhozttyExe -Text $shim -Tag 'watchdog-shim'
        if ($keys.Degraded) { Log '  note: this ghoztty predates --keys-file; shim path sent through argv' }
        $r = Invoke-Ghoztty (@('+send-keys', "--target=$paneId") + $keys.Args + @('Enter'))
        Log "  send-keys exit=$($r.Code) $($r.Out)"
        if ($keys.File) { Remove-Item -LiteralPath $keys.File -ErrorAction SilentlyContinue }
        # Verify rather than assume: a shim path that landed in a TUI shows up
        # as text and re-enters nothing, which is the T241 failure exactly.
        Start-Sleep -Seconds $VerifySeconds
        $after = Read-PaneOccupant -PaneId $paneId -GhozttyExe $GhozttyExe
        if ($after -eq 'claude') { Log "  RESTART-IN-PANE OK: pane $paneId is running claude" }
        elseif ($after -eq 'shell') { Log "  RESTART-IN-PANE UNVERIFIED: pane $paneId is still at a shell prompt after ${VerifySeconds}s" }
        else { Log "  RESTART-IN-PANE UNVERIFIED: pane $paneId occupant is $after" }
        Write-State 'restart-in-pane'
        return 'restart-in-pane'
    }

    Log "re-entering: no live loop pane, opening a new window (state=$state, remaining=$remaining)"
    if ($DryRun) { return 'new-window' }
    $r = Invoke-Ghoztty @('+new-window', "--target=$WindowTarget", "--working-directory=$Repo", "--command=$shim")
    Log "  new-window exit=$($r.Code) $($r.Out)"
    Write-State 'new-window'
    return 'new-window'
}

# --- main -----------------------------------------------------------------

if ($Once) {
    $action = Invoke-Tick
    "ACTION $action"
    exit 0
}

# --- self-restart on a script change ---------------------------------------
#
# This process runs for weeks. PowerShell reads a script ONCE, at start, so
# every edit to this file or to loop-session.ps1 is inert until somebody
# remembers to restart it - and nothing anywhere says the running copy is
# stale. That is not hypothetical: on 2026-08-23 a stop check was added here
# and armed, and the watchdog kept opening a window every twenty minutes for a
# full day because the process had been up since 2026-08-18 and was still
# executing the old body. The user saw the loop restarting itself and had no
# way to tell why.
#
# So the process watches its own source. When the bytes change it re-execs and
# lets the replacement pick up where it left off; a watchdog is exactly the
# kind of thing that must not need a human to notice it is out of date.
$WatchedScripts = @($PSCommandPath, (Join-Path $PSScriptRoot 'loop-session.ps1'))

function Get-ScriptStamp {
    # Content hash, not mtime: `git pull` and `git checkout` both rewrite
    # mtimes on files whose content did not change, and a false restart every
    # pull is its own bug.
    $parts = foreach ($f in $WatchedScripts) {
        if (Test-Path -LiteralPath $f) {
            try { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash } catch { 'unreadable' }
        } else { 'missing' }
    }
    return ($parts -join '/')
}

function Restart-Self {
    param([string]$Why)
    Log "$Why; re-executing this watchdog so the change takes effect"
    # Release the single-instance mutex FIRST or the replacement finds it held
    # and exits immediately, leaving no watchdog at all - strictly worse than
    # the stale one we are replacing.
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
           '-File', $PSCommandPath, '-Repo', $Repo)
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden | Out-Null
        Log '  replacement started'
    } catch {
        Log "  replacement FAILED to start: $($_.Exception.Message) - staying up on the old body"
        return $false
    }
    return $true
}

# Single instance: a second watchdog would double every re-entry. This is also
# what makes the revive scheduled task safe to fire every few minutes forever.
#
# The wait retries briefly rather than failing instantly: a self-restart hands
# the mutex from parent to child, and a child that gave up on the first try
# would leave the box with no watchdog at all.
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$got = $false
foreach ($attempt in 1..10) {
    if ($mutex.WaitOne(0)) { $got = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $got) { Log 'another go-loop watchdog is running; exiting'; exit 0 }

Log "=== go-loop watchdog start (poll=${PollSeconds}s, stale=${StaleMinutes}m, rearm=${RearmMinutes}m, repo=$Repo)"
Write-Health 'start'
$ScriptStamp = Get-ScriptStamp
Log "  watching own source ($($WatchedScripts.Count) files) for changes"
while ($true) {
    $now = Get-ScriptStamp
    if ($now -ne $ScriptStamp) {
        if (Restart-Self -Why 'own source changed on disk') { exit 0 }
        # Start-Process failed: keep running the old body rather than dying,
        # but re-stamp so the failure is logged once and not every poll.
        $ScriptStamp = $now
    }

    $action = 'error'
    try { $action = Invoke-Tick } catch { Log "tick error: $_" }
    if ($action -is [array]) { $action = $action[-1] }
    # After the tick, not before: the beacon should mean "a tick completed",
    # so a watchdog wedged inside one goes stale exactly like a dead one.
    try { Write-Health $action } catch { Log "health write failed: $_" }
    Start-Sleep -Seconds $PollSeconds
}
