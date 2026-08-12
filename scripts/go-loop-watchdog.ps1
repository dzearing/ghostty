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
#   1. If the tracker has no remaining todo/in-progress/blocked rows, do
#      nothing - the loop is finished, not stuck.
#   2. Read the lock. Healthy (owner alive AND a recent sign of life) -> do
#      nothing. Since T253 "sign of life" is the newer of the heartbeat and the
#      session transcript's mtime, so a turn that is working beats it without
#      anybody remembering to - see scripts\go-loop-lock.ps1.
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
    [string]$Tracker,
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
if (-not $Tracker) { $Tracker = Join-Path $Repo 'docs\design\windows-parity-tasks.md' }
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
# logon - which is exactly what happened on 2026-08-03 (T440). `/sc ONLOGON`
# needs elevation, but `/sc MINUTE` does not, and this loop must stay
# installable from an ordinary session.
function Get-RunCommand {
    return "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Repo `"$Repo`""
}

# schtasks wants the whole command as ONE /tr argument with its inner quotes
# backslash-escaped; anything else silently loses the arguments after the first
# space (verified on the box before shipping this).
function Get-ReviveTaskCommand {
    return '\"powershell.exe\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden' +
           " -File \`"$PSCommandPath\`" -Repo \`"$Repo\`""
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

    $tr = Get-ReviveTaskCommand
    $out = (& schtasks /create /tn $runValue /tr "$tr" /sc MINUTE /mo $ReviveMinutes /f 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { Log "installed revive task $runValue (every ${ReviveMinutes}m)" }
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

function Get-RemainingTasks {
    if (-not (Test-Path $Tracker)) { return -1 }   # unknown: never blocks re-entry
    $pattern = '^\| T\S+ \|.*\| *(todo|in-progress|blocked)[^|]*\|[^|]*\|\s*$'
    return @(Select-String -Path $Tracker -Pattern $pattern).Count
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
    $remaining = Get-RemainingTasks
    if ($remaining -eq 0) { Log 'idle: no remaining tracker rows'; return 'none' }

    $lock = Get-Lock
    $state = 'free'
    if ($lock -and $lock.state) { $state = $lock.state }
    if ($state -eq 'held' -and -not $Force) {
        Log ("healthy: pane=$($lock.pane_id) pid=$($lock.claude_pid) age=$($lock.age_minutes)m" +
             "(by=$($lock.activity_by)) remaining=$remaining")
        return 'none'
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
        Log "re-entering: nudge live session in pane $paneId (state=$state, occupant=$occupant, remaining=$remaining)"
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
        $gate = Wait-LoopSubmitted `
            -Read { (Invoke-Ghoztty @('+read', "--name=$paneId", '--lines=60')).Out } `
            -Submit { Invoke-Ghoztty (@('+send-keys', "--target=$paneId") + (Get-LoopSubmitArgs)) | Out-Null } `
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
        $r = Invoke-Ghoztty @('+send-keys', "--target=$paneId", (ConvertTo-SendKeysLiteral $shim), 'Enter')
        Log "  send-keys exit=$($r.Code) $($r.Out)"
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

# Single instance: a second watchdog would double every re-entry. This is also
# what makes the revive scheduled task safe to fire every few minutes forever.
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) { Log 'another go-loop watchdog is running; exiting'; exit 0 }

Log "=== go-loop watchdog start (poll=${PollSeconds}s, stale=${StaleMinutes}m, rearm=${RearmMinutes}m, repo=$Repo)"
Write-Health 'start'
while ($true) {
    $action = 'error'
    try { $action = Invoke-Tick } catch { Log "tick error: $_" }
    if ($action -is [array]) { $action = $action[-1] }
    # After the tick, not before: the beacon should mean "a tick completed",
    # so a watchdog wedged inside one goes stale exactly like a dead one.
    try { Write-Health $action } catch { Log "health write failed: $_" }
    Start-Sleep -Seconds $PollSeconds
}
