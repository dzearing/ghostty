# Shared helpers for identifying the go.md loop's Claude session and deciding
# how to resume it (tracker T138).
#
# Dot-source it:
#   . (Join-Path $PSScriptRoot 'loop-session.ps1')
#
# Why this exists: `upgrade-ghoztty-windows.ps1` used to assume that killing
# ghoztty.exe kills the Claude session running inside it. Session persistence
# (T89) ended that - the agent owns the PTY and is deliberately never killed,
# so the session SURVIVES the upgrade and the relaunched app re-attaches it.
# Relaunching `claude --continue` on top of that produces a SECOND session on
# the same transcript, and both pick the same task (user-hit 2026-07-28).
#
# So the resume decision needs one fact: is the Claude that launched the
# upgrade still alive afterwards? These helpers answer that without guessing
# from pane trees (a local-agent pane reports pid 0 / empty working_directory
# in `+list --json`, see T98) and without confusing the loop's session with any
# OTHER Claude the user has open.
#
# NOTE: `go-loop-lock.ps1` dot-sources these too, as of T168 - it used to carry
# its own copy of the pid/stamp resolution. There is now exactly ONE
# implementation of "which claude owns this loop session, and is it still the
# same process?", so a fix to it cannot leave the lock and the upgrade making
# opposite calls about the same session. Anything added here loads into the
# LOCK's process as well: keep this file free of top-level side effects.

# Byte-exact native invocation (T279). Every consumer of this file hands
# generated text - a resume command with a quoted prompt, a window label - to
# `ghoztty.exe`, and PowerShell 5.1's own command-line builder corrupts that
# text silently. Loaded here so there is one copy for the upgrade, the
# watchdog and the lock alike; it defines functions only.
. (Join-Path $PSScriptRoot 'lib\NativeArgv.ps1')

# --- process identity -------------------------------------------------------

# Name + start time of a pid, or $null if it is gone. The start time is what
# makes a later liveness check honest: pids are recycled, so "pid 1234 exists"
# is not "the process I recorded is still running".
function Get-LoopProcStamp {
    param([int]$ProcId)
    if ($ProcId -le 0) { return $null }
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $start = $null
    try { $start = $p.StartTime } catch { $start = $null }
    return [pscustomobject]@{ Pid = $ProcId; Name = $p.ProcessName; Start = $start }
}

# The claude process that owns the calling session:
#   1. an explicit pid (tests, and callers that already know it)
#   2. $env:CLAUDE_PID - set by Claude Code in every tool shell, and inherited
#      by a Start-Process'd detached script, which is exactly our case
#   3. our own ancestry - the fallback for a shell that lost the env var
# Returns 0 when there is no Claude above us (a hand-run upgrade), which is a
# real answer: nothing survived the kill, so relaunching is correct.
function Resolve-LoopClaudePid {
    param([int]$Explicit = 0)
    if ($Explicit -gt 0) { return $Explicit }
    if ($env:CLAUDE_PID) {
        $envPid = 0
        [void][int]::TryParse($env:CLAUDE_PID, [ref]$envPid)
        $stamp = Get-LoopProcStamp $envPid
        if ($stamp -and $stamp.Name -like 'claude*') { return $envPid }
    }
    $walk = $PID
    for ($i = 0; $i -lt 8 -and $walk -gt 0; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$walk" -ErrorAction SilentlyContinue
        if (-not $proc) { break }
        if ($proc.Name -like 'claude*') { return [int]$proc.ProcessId }
        $walk = [int]$proc.ParentProcessId
    }
    return 0
}

# Is the process we stamped earlier still the same live process?
function Test-LoopProcAlive {
    param($Stamp)
    if (-not $Stamp) { return $false }
    $now = Get-LoopProcStamp ([int]$Stamp.Pid)
    if (-not $now) { return $false }
    if ($Stamp.Name -and $now.Name -ne $Stamp.Name) { return $false }
    if ($Stamp.Start -and $now.Start) {
        if ([math]::Abs(($now.Start - $Stamp.Start).TotalSeconds) -gt 2) { return $false }
    }
    return $true
}

# --- `+sessions --json` -----------------------------------------------------

# Parse whatever `ghoztty +sessions --json` printed into session objects.
#
# The upgrade script used to read this line-by-line, expecting one JSON object
# per line (which is what docs/claude/cli.md describes). The command actually prints a
# pretty-printed ARRAY, so every line failed to parse and the pre-kill probe
# reported "0 sessions" on a box with four live ones - which is why the
# sessions-survive assert had been silently skipping since T89h.
#
# Accepts: pretty array, single object, NDJSON, empty, and leading non-JSON
# noise (a warning line ahead of the payload). Returns @() on anything else
# rather than throwing - this is a diagnostic probe, not a gate.
function ConvertFrom-GhozttySessionsJson {
    param([string]$Text)
    if (-not $Text) { return @() }
    $trimmed = $Text.Trim()
    if (-not $trimmed) { return @() }

    # Whole-payload parse first: handles the real (array) shape and a single
    # object. Skip any leading noise before the first '[' or '{'.
    $start = ($trimmed.IndexOfAny([char[]]@('[', '{')))
    if ($start -ge 0) {
        try {
            $parsed = $trimmed.Substring($start) | ConvertFrom-Json
            if ($null -ne $parsed) { return @($parsed) }
        } catch {}
    }

    # NDJSON fallback: one complete object per line.
    $out = @()
    foreach ($line in ($trimmed -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l.StartsWith('{')) { continue }
        try { $out += ($l | ConvertFrom-Json) } catch {}
    }
    return @($out)
}

function Get-GhozttySessionIds {
    param([string]$Text)
    return @(ConvertFrom-GhozttySessionsJson $Text |
        Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'id' -and $_.id } |
        ForEach-Object { [string]$_.id })
}

# --- the resume decision ----------------------------------------------------

# Pure: given what we know after the swap, how should the loop be resumed?
#
#   'none'     -> caller asked for no resume
#   'reuse'    -> the launching Claude outlived the kill; type the prompt into
#                 its pane instead of starting a second one
#   'relaunch' -> nothing survived (or the caller forced it); open a window
#                 running the resume command, the pre-T138 behavior
function Resolve-LoopResumeAction {
    param(
        [bool]$NoResume = $false,
        [bool]$ClaudeAlive = $false,
        [bool]$ForceRelaunch = $false
    )
    if ($NoResume) { return 'none' }
    if ($ForceRelaunch) { return 'relaunch' }
    if ($ClaudeAlive) { return 'reuse' }
    return 'relaunch'
}

# The prompt to type into a surviving session, derived from the resume command
# so the two can never disagree: `claude ... --continue "read go.md and go"`
# resumes with exactly the text a reused session is sent.
function Resolve-LoopResumePrompt {
    param([string]$ResumeCommand, [string]$Explicit = '')
    if ($Explicit) { return $Explicit }
    if ($ResumeCommand) {
        $m = [regex]::Match($ResumeCommand, '"([^"]+)"\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return 'read go.md and go'
}

# --- typing text into a pane (tracker T210) ---------------------------------
#
# NEVER hand generated text to `+send-keys` as a positional argument.
# PowerShell 5.1 does not escape an embedded `"` when it builds a native command
# line, so an argument containing one reaches the child with its quotes
# stripped, re-tokenized and concatenated without separators, or broken outright
# - and `+send-keys` concatenates its positional arguments with NO separator, so
# a re-tokenized prompt arrives as run-together prose. Measured on box
# 2026-08-01: `/reset-context settle the "DWM/PrintWindow" question ...` arrived
# 2 chars short with both quotes gone; a prompt with several quoted runs exited
# 1; and a trailing `\` breaks the child's argv outright. LENGTH is not a factor
# - the transport is byte-exact at 1222, 2500, 5000 and 10000 characters.
#
# So: write the text to a file and pass `--keys-file=<path>`, which the CLI
# sends verbatim (src/cli/send_keys.zig). Same reasoning as T200's
# -ResumePromptFile, one hop further down the pipeline.

# A BOM-less UTF-8 file holding exactly $Text - no trailing newline, because
# `--keys-file` sends the bytes verbatim and a stray CR submits the prompt.
function New-LoopPromptFile {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Tag = 'prompt'
    )
    $path = Join-Path $env:TEMP ("ghoztty-{0}-{1}-{2}.txt" -f $Tag, $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Which binary to run for a CLI verb whose OUTPUT or EXIT CODE is read (T663).
#
# `ghoztty.exe` is a GUI-subsystem binary, and PowerShell decides whether to
# wait for a native command - and whether its stdout can be captured at all -
# from that subsystem field. So this, the shape every reader here used:
#
#     (& $exe +read "--name=$pane" --lines=40 2>$null) | Out-String
#
# returns ZERO bytes with an EMPTY $LASTEXITCODE, silently. Measured 2026-08-10
# against a live pane: 0 characters through ghoztty.exe, 2856 through its
# ghoztty.com sibling, same pane, same second. That one line is why the
# upgrade's arrival gate had never once seen a prompt come back - it was reading
# nothing at all, for every prompt, since the gate was written. `2>&1` happens
# to force the wait (PowerShell has to build a pipeline for the merge), which is
# why the send-keys calls next door worked and the readers did not; but it also
# merges stderr into the data, which a `--json` reader cannot carry.
#
# T245 shipped `ghoztty.com` for exactly this: the same binary with the
# optional-header Subsystem WORD flipped to console, installed as a REQUIRED
# sibling of `ghoztty.exe`. Prefer it whenever it is on disk. An install that
# predates T245 has none, and there the caller's own `2>&1` is the only thing
# that works - so the fallback is the .exe rather than a hard failure, and the
# call sites keep their `2>&1` on the paths that must survive an old install.
function Resolve-GhozttyCliExe {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Exe)
    if (-not $Exe) { return $Exe }
    if ([System.IO.Path]::GetExtension($Exe) -ne '.exe') { return $Exe }
    $com = [System.IO.Path]::ChangeExtension($Exe, '.com')
    if (Test-Path -LiteralPath $com) { return $com }
    return $Exe
}

# Does THIS exe understand `--keys-file`? Ask it, never assume.
#
# The scripts run against whichever ghoztty is INSTALLED, which is routinely an
# older build than the repo - the watchdog especially, since it is a long-lived
# HKCU Run process. An exe that predates the flag treats `--keys-file=C:\...` as
# ordinary TEXT and types the path into the pane, which is the T241 failure
# exactly: a path lands in a Claude Code prompt box, exit 0, nothing re-enters.
# Measured 2026-08-01: the installed release at the moment this shipped
# (+96fbe40c7) did NOT support it, so the probe is load-bearing on day one, not
# a future-proofing gesture.
#
# `+send-keys --help` prints the action's doc comment and exits 0 without
# touching a pane, so it is a side-effect-free capability probe. Same rule as the
# app/agent HELLO handshake in CLAUDE.md: detect capability at RUNTIME, never at
# compile time, and degrade rather than corrupt.
$script:LoopKeysFileSupport = @{}
function Test-LoopKeysFileSupported {
    param([Parameter(Mandatory = $true)][string]$Exe)
    if ($script:LoopKeysFileSupport.ContainsKey($Exe)) { return $script:LoopKeysFileSupport[$Exe] }
    $ok = $false
    try {
        $help = (& $Exe +send-keys --help 2>&1 | Out-String)
        $ok = ($help -match 'keys-file')
    } catch { $ok = $false }
    $script:LoopKeysFileSupport[$Exe] = $ok
    return $ok
}

# The ONE named case where a file is genuinely impossible (tracker T280), and
# therefore the only place this escaper is allowed to be called from.
#
# `+send-keys` processes backslash escapes (\n, \t, \r, \e, \\) inside its
# POSITIONAL text arguments, so a Windows path is not safe to hand it raw:
# %TEMP% under a user called "tom" makes a shim path C:\Users\tom\... and the
# pane receives a TAB where \t was. Caught 2026-07-31 building the T241 negative
# control, whose own temp dir was ...\Temp\t241-negctl\ - the pane ran
# "C:\Users\David\AppData\Local\Temp241-negctl\fake-tui.cmd" and cmd said
# "cannot find the path". Doubling every backslash makes it arrive verbatim.
#
# T210's `--keys-file=` retired that problem at the transport instead: bytes go
# verbatim, no key notation and no escape processing, so nothing needs doubling.
# What it cannot retire is an exe that PREDATES the flag - and these scripts run
# against whichever ghoztty is INSTALLED, the watchdog especially (a long-lived
# HKCU Run process). That skew is the named case: argv is the only transport
# left, and on argv the escaping is still required.
#
# It is deliberately NOT exported as a call-site helper. Two transports for one
# kind of text is how a caller picks the unsafe one; callers ask
# New-LoopSendKeysText for the transport and it decides.
function ConvertTo-SendKeysLiteral {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('\', '\\')
}

# The `+send-keys` argument(s) that carry $Text to a pane: the safe transport
# when the exe has it, the old one when it does not. Returns Args (splat into the
# call), File (delete it afterwards; '' if none) and Degraded (true = the text is
# on argv, escaped rather than verbatim, and its quotes are at risk - say so in
# the log).
function New-LoopSendKeysText {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Tag = 'prompt'
    )
    if (Test-LoopKeysFileSupported -Exe $Exe) {
        $p = New-LoopPromptFile -Text $Text -Tag $Tag
        return @{ Args = @("--keys-file=$p"); File = $p; Degraded = $false }
    }
    return @{ Args = @((ConvertTo-SendKeysLiteral $Text)); File = ''; Degraded = $true }
}

# The `+send-keys` arguments that SUBMIT a prompt already sitting in a pane's
# composer (tracker T438).
#
# NOT `Enter` on its own, and the reason is the whole of T428: a bare CR is only
# unambiguously a keypress when the receiving TUI can see where pasted text
# ended. `+send-keys` states that boundary by framing a TEXT run as a bracketed
# paste (ESC[200~ ... ESC[201~) and writing the KEY run bare after it - but it
# can only do that when ONE call carries both runs. A boundary the CLI cannot
# see is a boundary it cannot encode.
#
# The upgrade's reuse path deliberately types the prompt, VERIFIES it arrived,
# and only then submits (T210: a half-arrived prompt becomes a chat message, and
# a post-submit check races /reset-context clearing the pane). So the prompt
# itself cannot ride along in the submitting call - and decision D4 ruled that a
# lone `--keys-file=` run stays unframed, so the typing call cannot frame itself
# either. The submitting call has to bring its own text run.
#
# One space is the smallest text that makes the call a mixed text+key send,
# which is what earns the frame. Every way it can go wrong is harmless:
#
#   * frame honoured    -> a space is appended, the CR is a keypress, submitted.
#   * pane has 2004 off -> ` ` `\r` unframed: exactly today's bytes plus a space.
#   * paste ignored     -> the verified prompt is submitted unchanged.
#
# Trailing whitespace means nothing to the session receiving the prompt, so
# nothing here can turn a verified prompt into a FRAGMENT. That is the property
# the alternatives lack: holding back the prompt's last character (gate the
# head, frame the tail) submits a truncated prompt if the tail is dropped, and
# backspace-then-retype eats a real character if the retype is.
function Get-LoopSubmitArgs {
    return @(' ', 'Enter')
}

# Did the prompt we typed actually get SUBMITTED? (tracker T562)
#
# `send-keys` exiting 0 means the bytes reached the pane. It does NOT mean the
# TUI acted on them, and every link in this chain used to stop at the exit
# code: on 2026-08-07 the loop sat all night at a full composer holding an
# unsubmitted `read go.md and go` while the delivery logs read OK, and the cure
# a human applied was one Enter.
#
# The only external evidence that a session took the prompt is MOTION. A Claude
# Code that is answering repaints - spinner, elapsed timer, streaming text -
# every second; an idle composer is static. That is the same property
# `--when-idle` is built on, so it is measured behaviour rather than a hope.
#
# Being ON SCREEN proves nothing either way, and mistaking it for proof is the
# actual defect: a composer holding an unsubmitted prompt looks exactly like a
# prompt that was just echoed. So a pane that will not move WHILE THE PROMPT IS
# STILL THERE is the suspect state, and it gets the submit pressed again,
# bounded, with every attempt reported to the caller.
#
# Two details are load-bearing:
#
#   * the baseline is taken AFTER a settle, because the paste painting is
#     itself motion and would read as the answer;
#   * the baseline is then FROZEN. Re-reading it after each press absorbs the
#     very repaint the press caused - the pane answers in milliseconds, the new
#     baseline already contains the answer, and the gate concludes "still not
#     moving" over a pane it just woke up. (Measured: it made every happy-path
#     run of test\win32\reset-context.ps1 fail.)
#
# I/O is injected so the decision is testable without a pane: -Read returns the
# pane tail, -Submit presses the submit again.
function Wait-LoopSubmitted {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Read,
        [Parameter(Mandatory = $true)][scriptblock]$Submit,
        [AllowEmptyString()][string]$Text = '',
        [int]$SettleSeconds = 2,
        [int]$WatchSeconds = 6,
        [int]$MaxSubmits = 2
    )
    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
    $base = [string](& $Read)
    $onscreen = (Test-LoopPromptArrived -Tail $base -Text $Text)
    $attempts = 0
    while ($true) {
        for ($i = 0; $i -lt $WatchSeconds; $i++) {
            Start-Sleep -Seconds 1
            $cur = [string](& $Read)
            if (-not $onscreen) { $onscreen = (Test-LoopPromptArrived -Tail $cur -Text $Text) }
            if ($cur -ne $base) {
                $why = if ($attempts) { "the pane moved after $attempts extra submit(s)" } else { 'the pane moved on its own' }
                return @{ Submitted = $true; Attempts = $attempts; Why = $why }
            }
        }
        # Nothing on screen and nothing moving means nothing landed - another
        # Enter cannot submit a prompt that was never typed, and pressing one
        # would only paper over the real failure.
        if (-not $onscreen) {
            return @{ Submitted = $false; Attempts = $attempts; Why = 'the pane never moved and the prompt is not on screen - nothing landed to submit' }
        }
        if ($attempts -ge $MaxSubmits) {
            return @{ Submitted = $false; Attempts = $attempts; Why = "the prompt is on screen but the pane never moved after $attempts extra submit(s) - it looks TYPED BUT NOT SUBMITTED" }
        }
        $attempts++
        & $Submit
    }
}

# Reduce a prompt (or a pane tail) to what the two can be compared on.
#
# A TUI wraps the prompt inside its input box, so the tail holds the same
# characters with newlines, box borders and a prompt marker injected - an exact
# IndexOf can never match a prompt longer than the pane is wide, which is why
# the old echo check "failed" routinely and was therefore written as a shrug
# instead of a gate. Both sides go through THIS function, so a prompt that
# itself contains `|` or `>` still matches.
#
# Box-drawing borders are matched by RANGE, never by literal glyph: PS 5.1
# mojibakes non-ASCII in a BOM-less script file (T241), so a literal box
# character in this source would not survive.
function Get-LoopPromptNeedle {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return (((($Text -replace '[^\x20-\x7E]', ' ') -replace '[|>]', ' ') -replace '\s+', ' ').Trim())
}

# Did $Text arrive in $Tail?
function Test-LoopPromptArrived {
    param(
        [AllowEmptyString()][string]$Tail,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $needle = Get-LoopPromptNeedle $Text
    if (-not $needle) { return $false }
    if (-not $Tail) { return $false }
    return ((Get-LoopPromptNeedle $Tail).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# Wait until a pane is ready to RECEIVE typed input (tracker T439).
#
# Presence in `+list --json` is NOT readiness. A re-attached pane appears there
# the moment its surface exists, while the agent is still replaying the
# session's ring into it and the TUI has not repainted. The upgrade's reuse path
# used `+list` presence as its only gate and then typed - measured three times
# on 2026-08-03, each run logging "pane re-attached" 0-1s after the app was
# started and RESUME-REUSE FAIL 10-16s later. `--when-idle` does not cover this
# either: it returns as soon as two consecutive reads match, and a pane whose
# content has not been replayed yet reads as empty, unchanged and therefore
# perfectly "idle" (src/cli/send_keys.zig waitForIdle).
#
# Ready = the tail is NON-EMPTY and UNCHANGED across $StableReads consecutive
# reads. Non-empty rules out "nothing has been replayed yet" - the state that
# reads as most stable of all. Stability rules out a replay in flight.
#
# $ReadTail is injected so this is testable without a pane; it returns the
# pane's rendered tail (or throws / returns empty, which counts as not ready).
# The loop is bounded by POLL COUNT rather than a clock so a test can run it
# with -PollMs 0. Returns @{ Ready; Why; Polls; Tail }.
function Wait-LoopPaneReady {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ReadTail,
        [int]$MaxPolls = 60,
        [int]$StableReads = 3,
        [int]$PollMs = 700
    )
    $prev = $null
    $stable = 0
    $last = ''
    for ($i = 1; $i -le $MaxPolls; $i++) {
        $tail = ''
        try { $tail = [string](& $ReadTail) } catch { $tail = '' }
        if ($null -eq $tail) { $tail = '' }
        $last = $tail
        # Compare through the same normalization the arrival gate uses, so a
        # repainting cursor or a shifting box border is not mistaken for the
        # replay still running.
        $norm = Get-LoopPromptNeedle $tail
        if (-not $norm) { $stable = 0 }
        elseif ($null -ne $prev -and $prev -eq $norm) { $stable++ }
        else { $stable = 1 }
        $prev = $norm
        if ($stable -ge $StableReads) {
            return @{ Ready = $true; Why = "tail settled after $i read(s)"; Polls = $i; Tail = $tail }
        }
        if ($PollMs -gt 0) { Start-Sleep -Milliseconds $PollMs }
    }
    $why = if ($last) { "tail never settled in $MaxPolls read(s)" } else { "pane produced no text in $MaxPolls read(s)" }
    return @{ Ready = $false; Why = $why; Polls = $MaxPolls; Tail = $last }
}

# Type $Text into a pane and confirm it ARRIVED, retrying the whole cycle
# (tracker T439).
#
# The gate itself is T210's and is not negotiable: never submit text that was
# not read back intact, because a half-arrived prompt becomes a chat message and
# a leftover fragment concatenates with whatever is typed next. What T439 adds
# is that ONE missed cycle is not evidence the send is impossible - it is
# usually evidence the pane was not ready yet - so the cycle is retried, with
# the composer cleared in between so attempt N+1 cannot append to attempt N's
# fragment.
#
# All three effects are injected so this is testable without a pane:
#   $SendText  type the text; return $true when the send itself succeeded
#   $ReadTail  the pane's rendered tail
#   $Clear     clear the composer (Escape) between attempts and after a miss
# Returns @{ Arrived; Attempts; Reads; Why; Tail }. Submitting is the caller's
# job: this function deliberately never presses Enter.
function Send-LoopPromptVerified {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$SendText,
        [Parameter(Mandatory = $true)][scriptblock]$ReadTail,
        [Parameter(Mandatory = $true)][scriptblock]$Clear,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [int]$Attempts = 3,
        [int]$ReadsPerAttempt = 12,
        [int]$PollMs = 700,
        [scriptblock]$Log = $null
    )
    $say = { param($m) if ($Log) { & $Log $m } }
    $reads = 0
    $tail = ''
    for ($a = 1; $a -le $Attempts; $a++) {
        if ($a -gt 1) {
            & $say "resume send: attempt $a of $Attempts (clearing the composer first)"
            try { [void](& $Clear) } catch { }
        }
        $sent = $false
        try { $sent = [bool](& $SendText) } catch { $sent = $false }
        if (-not $sent) {
            & $say "resume send: attempt $a - the send itself failed"
            continue
        }
        for ($i = 0; $i -lt $ReadsPerAttempt; $i++) {
            if ($PollMs -gt 0) { Start-Sleep -Milliseconds $PollMs }
            $reads++
            try { $tail = [string](& $ReadTail) } catch { $tail = '' }
            if ($null -eq $tail) { $tail = '' }
            if (Test-LoopPromptArrived -Tail $tail -Text $Text) {
                return @{ Arrived = $true; Attempts = $a; Reads = $reads; Why = "arrived on attempt $a"; Tail = $tail }
            }
        }
        & $say "resume send: attempt $a - the prompt did not read back intact after $ReadsPerAttempt read(s)"
    }
    # Leave nothing behind: an unverified fragment sitting in the composer is
    # what the watchdog's next nudge would concatenate onto.
    try { [void](& $Clear) } catch { }
    return @{ Arrived = $false; Attempts = $Attempts; Reads = $reads; Why = "never read back intact in $Attempts attempt(s)"; Tail = $tail }
}

# One BOUNDED `ghoztty +list --json` probe (tracker T187).
#
# Why this is not just `& $exe +list --json`: that call has no timeout of its
# own, and a client that connects to a bound-but-not-yet-accepting pipe can
# block. The upgrade script's readiness loop only checked its deadline BETWEEN
# calls, so one blocking probe swallowed the whole 60s window without the loop
# ever iterating - and the app was then reported as dead while it was running
# fine (2026-07-30: the loop stalled until a human pinged it). Running the CLI
# as a child with a hard wait is what makes a deadline mean what it says.
#
# Returns a hashtable: Json (the payload, or '') and Why (why not, for the log).
# Never throws.
function Invoke-GhozttyListJson {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$WorkingDirectory = $PWD.Path,
        [int]$TimeoutSec = 10
    )
    $out = Join-Path $env:TEMP ("ghoztty-listprobe-{0}-{1}.json" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
            -WorkingDirectory $WorkingDirectory `
            -ArgumentList "/c `"`"$Exe`" +list --json > `"$out`" 2>&1`""
        # Before any wait: touched later, ExitCode reads back EMPTY and this
        # probe reports "no windows" over a complete answer sitting in $out.
        # See test\win32\lib\ExitCodeAudit.ps1.
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return @{ Json = ''; Why = "+list hung past ${TimeoutSec}s" }
        }
        $t = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
        if ($p.ExitCode -eq 0 -and $t -match '"windows"') { return @{ Json = $t; Why = '' } }
        $first = ($t -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        return @{ Json = ''; Why = "exit=$($p.ExitCode) out='$first'" }
    } catch {
        return @{ Json = ''; Why = "probe threw: $($_.Exception.Message)" }
    } finally {
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }
}
