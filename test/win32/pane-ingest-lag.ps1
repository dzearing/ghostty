# T1142 acceptance: how far behind its own child does a pane's SCREEN run?
#
#   powershell -NoProfile -File test\win32\pane-ingest-lag.ps1
#   powershell -NoProfile -File test\win32\pane-ingest-lag.ps1 -NegativeControl
#
# THE QUESTION THIS ANSWERS. T1116 measured a pane printing ~350 KB whose bytes
# were all in the agent's ring within 0.9 s while the app's own terminal state -
# what `+read` returns and what the user is looking at - had not moved past the
# first screens minutes later. A pane that shows nothing while it is printing
# reads as a hung terminal, so the question is not academic; but "the screen is
# behind" had never been given a number, and a defect without a number cannot be
# regressed against.
#
# WHAT THE NUMBER TURNED OUT TO BE, and why this script is calibrated the way it
# is. Measured on 2026-08-23 with a 180 KB burst (`type` of 20000 numbered
# lines) and `+read` polled for the highest line number the app had reached:
#
#     build           path     child done   app caught up   app-side rate
#     Debug           agent      1.1 s        12.2 s          ~15 KB/s
#     Debug           local     13.7 s        14.7 s          ~12 KB/s
#     ReleaseFast     agent      2.3 s         2.3 s        child-limited
#     ReleaseFast     agent (4.5 MB burst)     4.5 s / 4.5 s  ~1.0 MB/s
#     ReleaseFast     local (4.5 MB burst)     7.2 s / 7.2 s  ~1.0 MB/s
#     conhost         (4.5 MB, same payload)   2.3 s          ~1.9 MB/s
#
# So the lag is a DEBUG-BUILD shape, not a shipped defect: a release pane tracks
# its child to inside one poll interval at 4.5 MB, and the ~65x gap is Debug
# codegen of the terminal parse path - it reproduces identically on the LOCAL
# (`termio.Exec`) path, which has none of the agent path's ring, slicing or
# priority handoff. What differs between the two paths is only WHO absorbs the
# backlog: the agent's ring takes the whole burst and lets the child run on,
# while a local pane's ConPTY back-pressures the child down to the app's parse
# rate. That difference is the thing a harness author must not assume away - it
# is what made T1116's flood evict its own marker.
#
# The bounds below are therefore REGRESSION bounds against the Debug numbers
# above, with wide headroom. They are not a claim about how fast the product is.
#
# Sections:
#   A. Agent-backed pane (session persistence ON): the burst is absorbed rather
#      than paced by the app, the app's screen does catch up to the last line
#      within a bound, the app-side ingest rate clears a floor, and the pane is
#      still LIVE afterwards.
#   B. Local pane (`--session-persistence=false`, termio.Exec): no ring, so the
#      child is paced by the app and the screen is never far behind it; same
#      rate floor and same liveness.
#   C. The run stayed off the interactive desktop.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1) - every oracle here
# is a CLI round trip over the IPC pipe, which is desktop-independent, so none
# of the capture/injection limits that force a script onto the input desktop
# apply. The renderer still runs and still contends for the same mutex there;
# the numbers in the table above were taken on the input desktop and the harness
# reproduces them off it, so the desktop is not part of what is measured.
#
# -NegativeControl makes both sections hunt for a line number the payload never
# contains, so every catch-up and rate arm must go RED while the setup arms stay
# green. That is the proof this script measures ARRIVAL and not the clock.
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$Lines = 20000,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ingestlag')

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-ingest-lag-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# --- bounds (see the table above) -------------------------------------------
# The app must drain its backlog, not stall: measured 12.2 s (agent) and 0.9 s
# (local) of catch-up after the child finished, on the slowest build we ship a
# harness against.
$catchupBoundSec = 90
# The child must not be paced by the app on the agent path: measured 1.1 s
# against an app that needed 12.2 s. This goes red if the ring starts blocking
# the producer for a burst this size.
$childBoundSec = 20
# A local pane has no ring, so its screen is never far behind its child:
# measured 0.9 s.
$localGapBoundSec = 15
# App-side ingest floor: measured 12-15 KB/s on Debug.
$rateFloor = 4000

# ---------------------------------------------------------------------------
# One CLI verb through cmd.exe with a real redirect (ghoztty.exe is
# GUI-subsystem, so `& $exe ... |` returns nothing), with a bounded wait so a
# wedged server fails the run instead of hanging it.
function Invoke-Ghoztty([string]$argsLine, [int]$timeoutSec = 20) {
    $out = Join-Path $tmp ("cli-{0}.txt" -f (Get-Random))
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # exitcode-audit: cache before any wait (T197)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    $text = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    Remove-Item $out -ErrorAction SilentlyContinue
    if ($null -eq $text) { return '' }
    return $text
}

function Get-BurstPane([string]$target) {
    $json = (Invoke-Ghoztty '+list --json').Trim()
    if (-not $json) { return $null }
    $data = $null
    try { $data = ($json | ConvertFrom-Json).data } catch { return $null }
    foreach ($w in $data.windows) {
        if ($w.target -eq $target) { return $w.tabs[0].splits.terminal.id }
    }
    return $null
}

# The payload: L000001..LNNNNNN, one per line. Numbered so a single `+read
# --lines=4` names exactly how far the app has got, which is what makes this a
# progress curve rather than a done/not-done poll.
$payload = Join-Path $tmp "burst.txt"
$sb = [System.Text.StringBuilder]::new()
for ($i = 1; $i -le $Lines; $i++) { [void]$sb.AppendLine(('L{0:D6}' -f $i)) }
[System.IO.File]::WriteAllText($payload, $sb.ToString())
$payloadBytes = (Get-Item $payload).Length
$bytesPerLine = $payloadBytes / $Lines

# The line the run waits for. Under -NegativeControl it is one PAST the end of
# the payload, so it can never arrive however long the app is given.
$wantLine = if ($NegativeControl) { $Lines + 1 } else { $Lines }

<#
Run one burst in $target's pane and return the timings, or $null if the pane
never came up. Never throws: every arm scoring it must fail rather than end the
run (T1039).
#>
function Measure-Burst([string]$target, [int]$timeoutSec) {
    $paneId = $null
    for ($t = 0; $t -lt 60; $t++) {
        $paneId = Get-BurstPane $target
        if ($paneId) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $paneId) { return $null }

    # Prime: the shell is alive and its echo is reaching the screen, so a burst
    # that never appears is the burst's fault and not the pane's.
    [void](Invoke-Ghoztty "+send-keys --target=$paneId `"echo READY`" Enter")
    $primed = $false
    for ($t = 0; $t -lt 60; $t++) {
        Start-Sleep -Milliseconds 250
        if ((Invoke-Ghoztty "+read --name=$paneId --lines=6") -match 'READY') { $primed = $true; break }
    }
    if (-not $primed) { return [pscustomobject]@{ Pane = $paneId; Primed = $false } }

    # The child stamps a file of its own the moment it has finished WRITING, so
    # "the child is done" is read off the child rather than inferred from the
    # screen - which is the very thing under measurement here.
    $doneFile = Join-Path $tmp "child-done-$target.txt"
    Remove-Item $doneFile -ErrorAction SilentlyContinue
    $cmd = "type $payload & echo x > $doneFile"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void](Invoke-Ghoztty "+send-keys --target=$paneId `"$cmd`" Enter")

    $lastN = 0
    $childDone = $null
    $appDone = $null
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $txt = Invoke-Ghoztty "+read --name=$paneId --lines=4"
        if ($txt) {
            foreach ($m in [regex]::Matches($txt, 'L(\d{6})')) {
                $v = [int]$m.Groups[1].Value
                if ($v -gt $lastN) { $lastN = $v }
            }
        }
        if (-not $childDone -and (Test-Path $doneFile)) {
            $childDone = $sw.Elapsed.TotalSeconds
        }
        if ($lastN -ge $wantLine) { $appDone = $sw.Elapsed.TotalSeconds; break }
        Start-Sleep -Milliseconds 100
    }
    $elapsed = $sw.Elapsed.TotalSeconds

    return [pscustomobject]@{
        Pane      = $paneId
        Primed    = $true
        ChildDone = $childDone
        AppDone   = $appDone
        LastLine  = $lastN
        Elapsed   = $elapsed
        Rate      = if ($elapsed -gt 0) { ($lastN * $bytesPerLine) / $elapsed } else { 0 }
    }
}

function Show-Burst([string]$tag, $r) {
    if ($null -eq $r) { "  ${tag}: pane never appeared"; return }
    if (-not $r.Primed) { "  ${tag}: pane never primed (pane=$($r.Pane))"; return }
    $cd = if ($null -eq $r.ChildDone) { 'never' } else { '{0:N2}s' -f $r.ChildDone }
    $ad = if ($null -eq $r.AppDone) { 'never' } else { '{0:N2}s' -f $r.AppDone }
    "  ${tag}: child done $cd | app reached L$($r.LastLine) at $ad | {0:N0} bytes/s app-side" -f $r.Rate
}

$agentRun = $null
$localRun = $null

try {
    "== setup: {0} lines, {1:N0} bytes; waiting for L{2:D6}{3}" -f `
        $Lines, $payloadBytes, $wantLine, $(if ($NegativeControl) { ' (NEGATIVE CONTROL - never emitted)' } else { '' })

    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    New-TestDesktop | Out-Null

    # --- Section A: agent-backed pane ---------------------------------------
    # persistence: ON deliberately - the agent-backed path IS section A's
    # subject, and Reset-GhozttyTestState above cleared the manifest so nothing
    # is restored into it.
    "== A: agent-backed pane (session persistence on)"
    $appA = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=true') `
        -StdErr (Join-Path $tmp 'appA.err')
    Start-Sleep -Seconds 4
    [void](Invoke-Ghoztty '+new-window --target=ingestA' 60)
    Assert-GhozttyIsolated -Exe $Exe

    $agentRun = Measure-Burst 'ingestA' ($catchupBoundSec + 30)
    Show-Burst 'A' $agentRun

    Assert 'A1 the agent-backed pane came up and its shell echoes' ($null -ne $agentRun -and $agentRun.Primed)
    Assert "A2 the burst was ABSORBED, not paced by the app (child finished within ${childBoundSec}s)" (
        $null -ne $agentRun -and $null -ne $agentRun.ChildDone -and $agentRun.ChildDone -le $childBoundSec)
    Assert "A3 the app's screen caught up to the last line within ${catchupBoundSec}s" (
        $null -ne $agentRun -and $null -ne $agentRun.AppDone -and $agentRun.AppDone -le $catchupBoundSec)
    Assert "A4 app-side ingest rate is at least $rateFloor bytes/s" (
        $null -ne $agentRun -and $null -ne $agentRun.AppDone -and $agentRun.Rate -ge $rateFloor)
    Assert 'A5 the pane is still LIVE after the burst' (
        $null -ne $agentRun -and $agentRun.Pane -and (Test-PaneLive -Exe $Exe -Target $agentRun.Pane -Tmp $tmp))

    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null

    # --- Section B: local pane ----------------------------------------------
    "== B: local pane (termio.Exec, no agent ring)"
    $appB = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') `
        -StdErr (Join-Path $tmp 'appB.err')
    Start-Sleep -Seconds 4
    [void](Invoke-Ghoztty '+new-window --target=ingestB' 60)

    $localRun = Measure-Burst 'ingestB' ($catchupBoundSec + 30)
    Show-Burst 'B' $localRun

    Assert 'B1 the local pane came up and its shell echoes' ($null -ne $localRun -and $localRun.Primed)
    Assert "B2 the app's screen caught up to the last line within ${catchupBoundSec}s" (
        $null -ne $localRun -and $null -ne $localRun.AppDone -and $localRun.AppDone -le $catchupBoundSec)
    Assert "B3 with no ring the screen is never far behind the child (gap under ${localGapBoundSec}s)" (
        $null -ne $localRun -and $null -ne $localRun.AppDone -and $null -ne $localRun.ChildDone -and
        ($localRun.AppDone - $localRun.ChildDone) -le $localGapBoundSec)
    Assert "B4 app-side ingest rate is at least $rateFloor bytes/s" (
        $null -ne $localRun -and $null -ne $localRun.AppDone -and $localRun.Rate -ge $rateFloor)
    Assert 'B5 the pane is still LIVE after the burst' (
        $null -ne $localRun -and $localRun.Pane -and (Test-PaneLive -Exe $Exe -Target $localRun.Pane -Tmp $tmp))

    Assert 'C1 the run never took the interactive desktop' (
        -not (Test-TestDesktopLeak -ProcessId $appB.Pid))

    Complete-TestBody   # T1039: last statement of the try body, before the stamp
} finally {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
    Remove-TestDesktop
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of the ingest path this harness covers, so
# scripts\guard-due.ps1 can answer "has anything measured pane ingest against
# the code as it now stands?". A red run - including the negative control -
# leaves the stamp alone.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-ingest-lag -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'PANE-INGEST-LAG' -Pass $script:passes -Fail $script:failures
