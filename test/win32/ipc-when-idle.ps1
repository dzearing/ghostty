# Acceptance for `+send-keys --when-idle` (delayed send) against a debug
# build. Non-interactive; exits nonzero on any failure. Only touches
# ghoztty processes from zig-out.
#
# The contract under test (src/cli/send_keys.zig waitForIdle) — busy is
# marker OR motion; idle needs neither for 3 consecutive 500ms polls:
#   1. static pane, no "esc to interrupt" in the last 10 lines -> send
#      after the ~1s stability window
#   2. marker present -> hold, send when it scrolls away
#   3. marker never clears -> send anyway after --idle-timeout seconds
#   4. no marker but output still streaming -> hold until quiescent
#
#   powershell -NoProfile -File test\win32\ipc-when-idle.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-wi-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# The old filter matched any CommandLine containing 'zig-out', which also
# catches a detached instance running from zig-out-release (T53b); the shared
# one is exact-exe, kills the sibling agent, and drops the debug
# session-layout manifest so a previous run's pane cannot be focused here.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}
function Read-Pane([int]$lines = 10) {
    cmd /c "`"$Exe`" +read --name=wia --lines=$lines > `"$tmp\read.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\read.txt" -Raw
}
# The typed command (`echo X`) sits after a shell prompt; the executed
# output is X at the start of a line. Line-anchored match = it really ran.
function Pane-HasOutput([string]$marker) {
    (Read-Pane 50) -match "(?m)^$([regex]::Escape($marker))\s*$"
}

Stop-DebugGhoztty

"== setup: window + named pane"
& $Exe +new-window --target=wi 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $Exe +split --target=wi --name=wia --direction=right 2>&1 | Out-Null
Start-Sleep -Seconds 2

"== 1: idle pane -> --when-idle sends promptly"
$t0 = Get-Date
& $Exe +send-keys --target=wia --when-idle --idle-timeout=15 "echo WI-PROMPT" Enter 2>&1 | Out-Null
$elapsed = ((Get-Date) - $t0).TotalSeconds
Assert "exit 0" ($LASTEXITCODE -eq 0)
Assert "sent promptly (<5s, took $([math]::Round($elapsed,1))s)" ($elapsed -lt 5)
Start-Sleep -Seconds 2
Assert "text executed" (Pane-HasOutput 'WI-PROMPT')

"== 2: busy marker holds the send until it scrolls out of the window"
& $Exe +send-keys --target=wia "echo WI-BUSY esc to interrupt" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
Assert "marker visible in last 10 lines" ((Read-Pane 10) -match 'esc to interrupt')
$job = Start-Job -ScriptBlock {
    param($exe)
    & $exe +send-keys --target=wia --when-idle --idle-timeout=60 "echo WI-DELAYED" Enter 2>&1 | Out-Null
    $LASTEXITCODE
} -ArgumentList $Exe
Start-Sleep -Seconds 4
Assert "still holding at +4s" ($job.State -eq 'Running')
Assert "text not delivered while busy" (-not (Pane-HasOutput 'WI-DELAYED'))
# Push the marker out of the 10-line poll window (2 lines per echo:
# command + output; \n executes each line, shell-agnostic).
& $Exe +send-keys --target=wia "echo WI-FILL-1\necho WI-FILL-2\necho WI-FILL-3\necho WI-FILL-4\necho WI-FILL-5\necho WI-FILL-6\necho WI-FILL-7\necho WI-FILL-8" Enter 2>&1 | Out-Null
$done = Wait-Job $job -Timeout 30
Assert "released after marker cleared" ($null -ne $done -and $done.State -eq 'Completed')
$rc = Receive-Job $job | Select-Object -Last 1
Assert "delayed send exit 0" ($rc -eq 0)
Remove-Job $job -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Assert "text executed after release" (Pane-HasOutput 'WI-DELAYED')

"== 3: no marker, streaming output -> held until quiescent"
# Printer script avoids shell-specific quoting in the typed line: ~14
# distinct lines over ~7s, then the pane goes static.
Set-Content "$tmp\printer.ps1" '1..14 | ForEach-Object { "tick-$_"; Start-Sleep -Milliseconds 500 }'
& $Exe +send-keys --target=wia "powershell -NoProfile -File $tmp\printer.ps1" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$t0 = Get-Date
& $Exe +send-keys --target=wia --when-idle --idle-timeout=30 "echo WI-QUIET" Enter 2>&1 | Out-Null
$elapsed = ((Get-Date) - $t0).TotalSeconds
Assert "exit 0" ($LASTEXITCODE -eq 0)
Assert "held while streaming (>=3s, took $([math]::Round($elapsed,1))s)" ($elapsed -ge 3)
Assert "released after quiescent (<20s)" ($elapsed -lt 20)
Start-Sleep -Seconds 2
Assert "text executed after quiescent" (Pane-HasOutput 'WI-QUIET')

"== 4: marker never clears -> --idle-timeout releases the send"
& $Exe +send-keys --target=wia "echo WI-BUSY2 esc to interrupt" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
Assert "marker visible again" ((Read-Pane 10) -match 'esc to interrupt')
$t0 = Get-Date
& $Exe +send-keys --target=wia --when-idle --idle-timeout=3 "echo WI-TIMEOUT" Enter 2>&1 | Out-Null
$elapsed = ((Get-Date) - $t0).TotalSeconds
Assert "exit 0" ($LASTEXITCODE -eq 0)
Assert "held for ~timeout (>=2.5s, took $([math]::Round($elapsed,1))s)" ($elapsed -ge 2.5)
Assert "did not hang (<15s)" ($elapsed -lt 15)
Start-Sleep -Seconds 2
Assert "text executed after timeout" (Pane-HasOutput 'WI-TIMEOUT')

"== teardown"
& $Exe +close --target=wi 2>&1 | Out-Null
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) {
    "WHEN-IDLE ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "WHEN-IDLE ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
