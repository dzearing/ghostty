# The upgrade's resume must wait for the pane and retry (tracker T439).
#
# What went wrong: delivering T428 on 2026-08-03, the swap and all three install
# locations verified OK, and then the resume typed its prompt into a pane that
# had re-attached one second earlier. The arrival gate never saw the prompt come
# back intact, the run exited 1, and the loop was dead. The same shape had
# already failed at 09:04 and 10:44 that day - three deliveries, one cause.
#
# The cause is that `+list --json` presence was the ONLY readiness gate. A pane
# is listed the moment restore builds its surface, while the agent is still
# replaying the session ring into it. `--when-idle` does not cover the gap
# either: it returns as soon as two consecutive reads match, and a pane whose
# content has not arrived yet reads as empty, unchanged, and therefore idle.
#
# Sections (all pure - no app, no pane, no upgrade run):
#   A  Wait-LoopPaneReady: what counts as ready, and the pre-fix oracle showing
#      why an empty pane is the most convincing "idle" of all.
#   B  Send-LoopPromptVerified: one miss is retried, the composer is cleared
#      between attempts, and a prompt that never arrives is never submitted.
#   C  the watchdog handoff: -Force overrides a healthy-looking lock, and
#      -ResumePromptFile keeps caller text off argv.
#   D  the upgrade script is wired to all of it - including T438's framed
#      submit, since the gate above is what forces the submit into a second
#      call that no CLI-side framing can reach.
#
#   powershell -NoProfile -File test\win32\upgrade-resume-readiness.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$PureOnly
)

$ErrorActionPreference = 'Continue'
$script:failures = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

. (Join-Path $Repo 'scripts\loop-session.ps1')

# A reader that hands out one canned tail per call and then repeats the last
# one forever - the shape of a pane whose replay finishes and then holds still.
function New-Reader([string[]]$Frames) {
    $box = [pscustomobject]@{ I = 0; Frames = $Frames }
    return @{
        Box  = $box
        Read = {
            $f = $box.Frames
            $i = $box.I
            $box.I = $i + 1
            if ($f.Count -eq 0) { return '' }
            if ($i -ge $f.Count) { return $f[$f.Count - 1] }
            return $f[$i]
        }.GetNewClosure()
    }
}

# ============================================================================
"== A: Wait-LoopPaneReady"
# ============================================================================

# A1-A2: the exact 2026-08-03 shape. The pane is empty for a while (surface
# built, ring not replayed), then history lands over several reads, then it
# holds still. Ready must not be declared until the holding-still part.
$replaying = @('', '', '', 'line one', 'line one line two', 'line one line two line three',
    'settled', 'settled', 'settled')
$r = New-Reader $replaying
$res = Wait-LoopPaneReady -ReadTail $r.Read -MaxPolls 20 -StableReads 3 -PollMs 0
Assert 'A1 a pane that settles is eventually ready' $res.Ready
AssertEq 'A2 ready is not declared before the content stops changing' 9 $res.Polls

# A3: the PRE-FIX ORACLE. An all-empty pane is unchanged on every single read,
# so a stability-only test (which is what `--when-idle` is) calls it idle
# immediately. Requiring non-empty is the whole difference.
$r = New-Reader @('', '', '', '', '', '', '', '')
$res = Wait-LoopPaneReady -ReadTail $r.Read -MaxPolls 8 -StableReads 3 -PollMs 0
Assert 'A3 PRE-FIX ORACLE: an un-replayed (empty) pane is NOT ready' (-not $res.Ready)
Assert 'A4 and the reason says so' ($res.Why -match 'no text')

# A5: a pane that never stops changing is not ready either, and says why.
$frames = 1..10 | ForEach-Object { "output line $_" }
$r = New-Reader $frames
$res = Wait-LoopPaneReady -ReadTail $r.Read -MaxPolls 6 -StableReads 3 -PollMs 0
Assert 'A5 a pane still producing output is not ready' (-not $res.Ready)
Assert 'A6 and the reason distinguishes it from an empty pane' ($res.Why -match 'never settled')

# A7: an already-quiet pane (the common case - the app came back long ago) is
# ready as soon as it has been read $StableReads times, not later.
$r = New-Reader @('claude prompt here')
$res = Wait-LoopPaneReady -ReadTail $r.Read -MaxPolls 20 -StableReads 3 -PollMs 0
Assert 'A7 an already-quiet pane is ready' $res.Ready
AssertEq 'A8 in exactly StableReads reads' 3 $res.Polls

# A9: a reader that throws must not take the script with it, and must not be
# mistaken for a settled pane.
$res = Wait-LoopPaneReady -ReadTail { throw 'pipe not up yet' } -MaxPolls 4 -StableReads 3 -PollMs 0
Assert 'A9 a throwing reader is handled as not-ready' (-not $res.Ready)

# A10: only the normalized text is compared, so a cursor or box border that
# repaints in place does not read as a pane still replaying.
$r = New-Reader @("| settled  >", "|  settled >", "|   settled  >")
$res = Wait-LoopPaneReady -ReadTail $r.Read -MaxPolls 6 -StableReads 3 -PollMs 0
Assert 'A10 cosmetic repaints do not count as changes' $res.Ready

# ============================================================================
"== B: Send-LoopPromptVerified"
# ============================================================================

$prompt = '/reset-context verify the delivery, then read go.md and go'

# B1-B4: the first attempt misses entirely (the pane was not ready), the second
# lands. The old one-shot gate exited 1 here - this is the T439 regression.
$script:sends = 0
$script:clears = 0
$res = Send-LoopPromptVerified -Text $prompt `
    -SendText { $script:sends++; return $true } `
    -ReadTail { if ($script:sends -ge 2) { return "box $prompt box" } else { return 'still replaying' } } `
    -Clear { $script:clears++ } `
    -Attempts 3 -ReadsPerAttempt 2 -PollMs 0
Assert 'B1 a first-attempt miss is retried, not fatal' $res.Arrived
AssertEq 'B2 it took two attempts' 2 $res.Attempts
AssertEq 'B3 the text was sent twice' 2 $script:sends
AssertEq 'B4 the composer was cleared before the retry' 1 $script:clears

# B5-B7: a prompt that never arrives is never reported as arrived, and the
# composer is left clean so the watchdog's next nudge cannot concatenate onto a
# fragment.
$script:sends = 0
$script:clears = 0
$res = Send-LoopPromptVerified -Text $prompt `
    -SendText { $script:sends++; return $true } `
    -ReadTail { return 'nothing like the prompt' } `
    -Clear { $script:clears++ } `
    -Attempts 3 -ReadsPerAttempt 2 -PollMs 0
Assert 'B5 a prompt that never arrives is not reported as arrived' (-not $res.Arrived)
AssertEq 'B6 every attempt was made' 3 $res.Attempts
Assert 'B7 the composer is cleared on the way out' ($script:clears -ge 3)

# B8-B9: the happy path costs exactly one send and no clear.
$script:sends = 0
$script:clears = 0
$res = Send-LoopPromptVerified -Text $prompt `
    -SendText { $script:sends++; return $true } `
    -ReadTail { return "> $prompt" } `
    -Clear { $script:clears++ } `
    -Attempts 3 -ReadsPerAttempt 4 -PollMs 0
Assert 'B8 an immediate arrival is one attempt' ($res.Arrived -and $res.Attempts -eq 1)
AssertEq 'B9 and nothing is cleared' 0 $script:clears

# B10-B11: a send that fails outright is retried too, and never verified as
# arrived just because the tail happens to contain the text.
$script:sends = 0
$res = Send-LoopPromptVerified -Text $prompt `
    -SendText { $script:sends++; return ($script:sends -ge 3) } `
    -ReadTail { if ($script:sends -ge 3) { return "> $prompt" } else { return '' } } `
    -Clear { } `
    -Attempts 3 -ReadsPerAttempt 2 -PollMs 0
Assert 'B10 a failing send is retried' ($res.Arrived -and $res.Attempts -eq 3)
AssertEq 'B11 the failing sends were not counted as arrivals' 3 $script:sends

# B12: the prompt is matched through the same normalization the pane wraps it
# with, so a long prompt broken across the input box still verifies.
$long = '/reset-context ' + ('word ' * 40) + 'then read go.md and go'
$wrapped = "|  " + (($long -split ' ') -join "  `r`n| ") + " >"
$res = Send-LoopPromptVerified -Text $long `
    -SendText { return $true } -ReadTail { return $wrapped } -Clear { } `
    -Attempts 1 -ReadsPerAttempt 1 -PollMs 0
Assert 'B12 a prompt wrapped by the input box still verifies' $res.Arrived

# ============================================================================
"== C: the watchdog handoff"
# ============================================================================

$dog = Join-Path $Repo 'scripts\go-loop-watchdog.ps1'
$root = Join-Path $env:TEMP "ghoztty-resume-ready-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$lock = Join-Path $root 'go-loop.lock.json'
$state = Join-Path $root 'watchdog.json'
$log = Join-Path $root 'watchdog.log'
$tracker = Join-Path $root 'tracker.md'
@(
    '| ID | Task | Phase | Deps | Status | Commits |',
    '|----|------|-------|------|--------|---------|',
    '| T999 | something left to do | K | - | todo | - |'
) -join "`r`n" | Out-File -FilePath $tracker -Encoding ascii

function Dog([string[]]$extra) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dog,
        '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $state,
        '-Tracker', $tracker, '-LogPath', $log, '-Once', '-DryRun') + $extra
    $out = & powershell @a 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

# A lock that looks perfectly healthy: this shell is alive and the heartbeat is
# now. That is exactly the state the upgrade leaves behind when its resume
# fails - the launching turn beat the lock minutes earlier.
$stamp = (Get-Process -Id $PID)
@{
    pane_id      = 'PANE-T439'
    claude_pid   = $PID
    claude_name  = $stamp.ProcessName
    claude_start = $stamp.StartTime.ToString('o')
    heartbeat    = (Get-Date).ToString('o')
    turn         = 1
    reason       = 'test'
} | ConvertTo-Json | Set-Content $lock -Encoding ascii

$r = Dog @()
Assert 'C1 PRE-FIX ORACLE: a healthy lock produces no re-entry' ($r.Out -match 'ACTION none')
Assert 'C2 and the tick reports it as healthy' ($r.Out -match 'healthy: pane=PANE-T439')

$r = Dog @('-Force')
Assert 'C3 -Force re-enters despite the healthy lock' ($r.Out -notmatch 'ACTION none')
Assert 'C4 and says the re-entry was forced' ($r.Out -match 'forced:')

# The rearm hold-off is the second gate -Force has to clear: the watchdog
# records its own last action, and a re-entry minutes ago would otherwise make
# it sit out this one.
@{ action = 'nudge'; at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $state -Encoding ascii
$r = Dog @('-Force')
Assert 'C5 -Force also clears the rearm hold-off' ($r.Out -notmatch 'rearm not elapsed')

# -ResumePromptFile: caller text with quotes must survive, because
# `powershell -File ... -ResumePrompt "<text>"` is the argv hop T210 closed.
$pf = Join-Path $root 'prompt.txt'
'/reset-context run "ghoztty +version" and confirm it reports +abc1234. Then read go.md and go' |
    Set-Content $pf -Encoding ascii -NoNewline
$r = Dog @('-Force', '-ResumePromptFile', $pf)
Assert 'C6 -ResumePromptFile is read' ($r.Out -match 'resume prompt read from file')
Assert 'C7 and the quoted text is not truncated at the first quote' ($r.Out -match '90 chars|9[0-9] chars')

$r = Dog @('-Force', '-ResumePromptFile', (Join-Path $root 'does-not-exist.txt'))
Assert 'C8 a missing prompt file warns and falls back' ($r.Out -match 'missing or empty')
Assert 'C9 and the tick still runs' ($r.Out -match 'ACTION ')

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
"== D: the upgrade script is wired to all of it"
# ============================================================================
# Source assertions, not behavior: the E2E that exercises the reuse path lives
# in upgrade-no-fork.ps1 section B, and what is cheap to lose here is the
# WIRING - a later edit that drops the readiness gate or the retry would still
# pass every behavioral test above.
$src = Get-Content (Join-Path $Repo 'scripts\upgrade-ghoztty-windows.ps1') -Raw

Assert 'D1 the reuse path waits for the pane before typing' `
    ($src -match 'Wait-LoopPaneReady -ReadTail')
Assert 'D2 the type-and-verify cycle is the retrying one' `
    ($src -match 'Send-LoopPromptVerified -Text')
Assert 'D3 PRE-FIX ORACLE: the one-shot 12-read gate is gone' `
    (-not ($src -match '\$echoed = \$false'))
Assert 'D4 a failed resume hands off to the watchdog immediately' `
    ($src -match 'Invoke-WatchdogNow -Why')
Assert 'D5 the handoff refuses to run unless the lock is held by THIS pane' `
    ($src -match "lock\.pane_id -ne \`$LoopPaneId")
Assert 'D6 the handoff passes the prompt by file, never on the command line' `
    ($src -match "'-ResumePromptFile', \`$PromptFile")

# T438: the gate forces the submit into a second call, and the CLI can only
# frame a text run when the SAME call carries the key run after it. So the
# submitting call has to bring a text run of its own - a bare `Enter` there is
# the defect, not the fix.
$submit = Get-LoopSubmitArgs
Assert 'D7 the submit carries a text run before the key' `
    ($submit.Count -eq 2 -and $submit[0] -eq ' ' -and $submit[1] -eq 'Enter')
Assert 'D8 the reuse path submits through Get-LoopSubmitArgs' `
    ($src -match 'Get-LoopSubmitArgs')
Assert 'D9 PRE-FIX ORACLE: the bare `Enter` submit is gone' `
    (-not ($src -match '\+send-keys "--target=\$LoopPaneId" Enter'))

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
