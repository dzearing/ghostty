# P3 acceptance (spec Phases P3 / tracker T16): +read, +set-state,
# OSC 7777, +rearrange against a debug build. Non-interactive; exits
# nonzero on any failure. Only touches ghoztty processes from zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-p3.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-p3-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: give this run its OWN IPC endpoint before any CLI call. Without it every
# `& $Exe` below inherits the caller pane's baked `$GHOZTTY_IPC_SOCKET` — this
# floor would measure the user's INSTALLED release, and `+send-keys` would type
# into their live panes.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ipcp3')

# T1193: every CLI call runs ON THE TEST DESKTOP. `+new-window` auto-launches
# the app, and the window lands on the desktop of the process that spawned it -
# so this floor threw a window across the user's screen on every run.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Exact-exe matching is still the rule (T53b); the reset now also kills the
# sibling agent and drops the debug session-layout manifest. This script's
# oracles read pane CONTENT (+read, OSC state), which is exactly what a stale
# focused pane from a previous run would answer with.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}
# Every CLI call goes through here (T1193). The harness captures the child's
# stdout and stderr to a file, which is what the old `cmd /c ... > file` dance
# was for: a GUI-subsystem exe writes zero bytes to a PowerShell `>` (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}
# T1285: a call the run cannot continue without - see lib\FloorFixture.ps1.
. (Join-Path $PSScriptRoot 'lib\FloorFixture.ps1')
function Need([string]$What, [string[]]$GhozArgs) {
    return Need-Ghoz -What $What -GhozArgs $GhozArgs -Exe $Exe
}
function Get-P3Title {
    $m = [regex]::Match((Ghoz @('+list')).Output, '(?m)^Window: "([^"]*)" \[target: p3\]')
    $m.Groups[1].Value
}
function Get-P3Json {
    # T1285: STDOUT alone - a CLI diagnostic sharing the stream is how a slow
    # answer read as a malformed one.
    $j = (Ghoz @('+list', '--json')).StdOut | ConvertFrom-Json
    $j.data.windows | Where-Object { $_.target -eq 'p3' }
}

# T379: poll +list until a pattern shows, so the FIRST launch of a
# just-replaced exe (cold: Defender scan, no cache) cannot outrun a fixed
# sleep. Warm runs resolve on the first poll.
function Wait-ListMatch([string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $l = (Ghoz @('+list')).Output
        if ($l -match $Pattern) { return $l }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $l
}

# T379: tee every PASS/FAIL line to a transcript so a red run keeps its
# evidence past a `| Select-Object -Last 1` summary; the trailer names it.
$transcript = Join-Path $env:TEMP 'ghoztty-ipc-p3-last.log'

$td = New-TestDesktop

& {

Invoke-FloorBody {

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== setup: window + named panes"
[void](Need 'the p3 fixture window' @('+new-window', '--target=p3'))
# Cold-launch guard first (T379); the settle sleep after it stays, because the
# +send-keys sections need the pane's shell up, not just the window row.
Need-Listed 'the p3 fixture window' '\[target: p3\]' (Wait-ListMatch '\[target: p3\]')
Start-Sleep -Seconds 3
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe
[void](Need 'the p3a fixture pane' @('+split', '--target=p3', '--name=p3a', '--direction=right'))
Start-Sleep -Seconds 1
[void](Need 'the p3b fixture pane' @('+split', '--target=p3', '--name=p3b', '--direction=down'))
Start-Sleep -Seconds 2

"== 1: +read echoes back known strings byte-accurate"
[void](Ghoz @('+send-keys', '--target=p3a', 'echo P3-READ-MARKER', 'Enter'))
Start-Sleep -Seconds 2
$r = Ghoz @('+read', '--name=p3a', '--lines=5')
Assert "read exit 0" ($r.ExitCode -eq 0)
Assert "marker line exact" (($r.Output -split "`r?`n") -contains 'P3-READ-MARKER')

"== 2: +read missing pane errors"
$r = Ghoz @('+read', '--name=p3ghost')
Assert "nonzero exit" ($r.ExitCode -ne 0)

"== 3: +set-state states + aggregation + title suffix"
[void](Ghoz @('+set-state', '--target=p3', '--state=busy'))
Start-Sleep -Seconds 1
# NOTE: debug builds append a " [DEBUG]" title marker after the activity
# suffix (added 2026-07-13), so these anchors allow it.
Assert "window busy suffix" ((Get-P3Title) -match '\(busy\)( \[DEBUG\])?$')
[void](Ghoz @('+set-state', '--target=p3a', '--state=needs_input'))
Start-Sleep -Seconds 1
Assert "needs_input outranks busy" ((Get-P3Title) -match '\(needs_input\)( \[DEBUG\])?$')
[void](Ghoz @('+set-state', '--target=p3a', '--state=idle'))
Start-Sleep -Seconds 1
Assert "back to busy" ((Get-P3Title) -match '\(busy\)( \[DEBUG\])?$')
[void](Ghoz @('+set-state', '--target=p3', '--state=idle'))
Start-Sleep -Seconds 1
Assert "suffix cleared" (-not ((Get-P3Title) -match '\(busy\)|\(needs_input\)'))
$r = Ghoz @('+set-state', '--target=p3', '--state=bogus')
Assert "invalid state errors" ($r.ExitCode -ne 0)

"== 4: OSC 7777 round-trip from inside a pane"
$oscBusy = "powershell -NoProfile -Command `"[console]::Write([char]27+']7777;busy'+[char]7)`""
[void](Ghoz @('+send-keys', '--target=p3a', $oscBusy, 'Enter'))
Start-Sleep -Seconds 6
Assert "OSC busy set" ((Get-P3Title) -match '\(busy\)( \[DEBUG\])?$')
$oscIdle = "powershell -NoProfile -Command `"[console]::Write([char]27+']7777;idle'+[char]7)`""
[void](Ghoz @('+send-keys', '--target=p3a', $oscIdle, 'Enter'))
Start-Sleep -Seconds 6
Assert "OSC idle cleared" (-not ((Get-P3Title) -match '\(busy\)'))

"== 5: +rearrange rebuilds tree, closes unnamed pane"
$layout = '{"direction":"horizontal","ratio":30,"left":{"pane":"p3a"},"right":{"pane":"p3b"}}'
# PS 5.1 native-arg passing eats embedded quotes; escape them for Win32.
$r = Ghoz @('+rearrange', '--target=p3', ('--layout=' + ($layout -replace '"','\"')))
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
$w = Get-P3Json
$s = $w.tabs[0].splits
Assert "2 leaves after" (([regex]::Matches(($w | ConvertTo-Json -Depth 15), '"type":\s*"leaf"')).Count -eq 2)
Assert "root horizontal ratio 0.3" ($s.direction -eq 'horizontal' -and [math]::Abs($s.ratio - 0.3) -lt 0.01)
Assert "children p3a/p3b" ($s.left.terminal.name -eq 'p3a' -and $s.right.terminal.name -eq 'p3b')

"== 6: +rearrange error paths"
$dup = '{"direction":"horizontal","left":{"pane":"p3a"},"right":{"pane":"p3a"}}'
$r = Ghoz @('+rearrange', '--target=p3', ('--layout=' + ($dup -replace '"','\"')))
Assert "duplicate errors" ($r.ExitCode -ne 0)
$missing = '{"pane":"nope"}'
$r = Ghoz @('+rearrange', '--target=p3', ('--layout=' + ($missing -replace '"','\"')))
Assert "unknown pane errors" ($r.ExitCode -ne 0)

}  # Invoke-FloorBody - teardown below runs whether or not the body stopped early

"== teardown"
[void](Ghoz @('+close', '--target=p3'))
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

} 2>&1 | Tee-Object -FilePath $transcript

""
# The verdict goes through the shared scorer (T271), which refuses to call a
# run with zero passing assertions a pass; -NoExit is how the failure trailer
# still reaches the transcript.
Complete-TestBody  # T1039: the run reached the end of its body
$verdict = Write-TestVerdict -Label 'P3 ACCEPTANCE' -Pass $script:passes -Fail $script:failures -NoExit
if ($verdict.Code -ne 0) { Add-Content $transcript $verdict.Line }
exit $verdict.Code
