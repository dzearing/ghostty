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
# NOTE: `go-loop-lock.ps1` carries its own copy of the pid/stamp resolution it
# needs for the lock file. Converging the two is filed as its own task rather
# than folded in here, so this change cannot destabilize the loop lock.

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
# per line (which is what CLAUDE.md describes). The command actually prints a
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
