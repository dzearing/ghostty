# P3 acceptance (spec Phases P3 / tracker T16): +read, +set-state,
# OSC 7777, +rearrange against a debug build. Non-interactive; exits
# nonzero on any failure. Only touches ghoztty processes from zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-p3.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-p3-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: give this run its OWN IPC endpoint before any CLI call. Without it every
# `& $Exe` below inherits the caller pane's baked `$GHOZTTY_IPC_SOCKET` — this
# floor would measure the user's INSTALLED release, and `+send-keys` would type
# into their live panes.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ipcp3')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Exact-exe matching is still the rule (T53b); the reset now also kills the
# sibling agent and drops the debug session-layout manifest. This script's
# oracles read pane CONTENT (+read, OSC state), which is exactly what a stale
# focused pane from a previous run would answer with.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}
function Get-P3Title {
    cmd /c "`"$Exe`" +list > `"$tmp\list.txt`" 2>&1" | Out-Null
    $m = [regex]::Match((Get-Content "$tmp\list.txt" -Raw), '(?m)^Window: "([^"]*)" \[target: p3\]')
    $m.Groups[1].Value
}
function Get-P3Json {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    $j = Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json
    $j.data.windows | Where-Object { $_.target -eq 'p3' }
}

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== setup: window + named panes"
& $Exe +new-window --target=p3 2>&1 | Out-Null
Start-Sleep -Seconds 3
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe
& $Exe +split --target=p3 --name=p3a --direction=right 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $Exe +split --target=p3 --name=p3b --direction=down 2>&1 | Out-Null
Start-Sleep -Seconds 2

"== 1: +read echoes back known strings byte-accurate"
& $Exe +send-keys --target=p3a "echo P3-READ-MARKER" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
cmd /c "`"$Exe`" +read --name=p3a --lines=5 > `"$tmp\read.txt`" 2>&1"
Assert "read exit 0" ($LASTEXITCODE -eq 0)
Assert "marker line exact" ((Get-Content "$tmp\read.txt") -contains 'P3-READ-MARKER')

"== 2: +read missing pane errors"
& $Exe +read --name=p3ghost 2>&1 | Out-Null
Assert "nonzero exit" ($LASTEXITCODE -ne 0)

"== 3: +set-state states + aggregation + title suffix"
& $Exe +set-state --target=p3 --state=busy 2>&1 | Out-Null
Start-Sleep -Seconds 1
# NOTE: debug builds append a " [DEBUG]" title marker after the activity
# suffix (added 2026-07-13), so these anchors allow it.
Assert "window busy suffix" ((Get-P3Title) -match '\(busy\)( \[DEBUG\])?$')
& $Exe +set-state --target=p3a --state=needs_input 2>&1 | Out-Null
Start-Sleep -Seconds 1
Assert "needs_input outranks busy" ((Get-P3Title) -match '\(needs_input\)( \[DEBUG\])?$')
& $Exe +set-state --target=p3a --state=idle 2>&1 | Out-Null
Start-Sleep -Seconds 1
Assert "back to busy" ((Get-P3Title) -match '\(busy\)( \[DEBUG\])?$')
& $Exe +set-state --target=p3 --state=idle 2>&1 | Out-Null
Start-Sleep -Seconds 1
Assert "suffix cleared" (-not ((Get-P3Title) -match '\(busy\)|\(needs_input\)'))
& $Exe +set-state --target=p3 --state=bogus 2>&1 | Out-Null
Assert "invalid state errors" ($LASTEXITCODE -ne 0)

"== 4: OSC 7777 round-trip from inside a pane"
$oscBusy = "powershell -NoProfile -Command `"[console]::Write([char]27+']7777;busy'+[char]7)`""
& $Exe +send-keys --target=p3a $oscBusy Enter 2>&1 | Out-Null
Start-Sleep -Seconds 6
Assert "OSC busy set" ((Get-P3Title) -match '\(busy\)( \[DEBUG\])?$')
$oscIdle = "powershell -NoProfile -Command `"[console]::Write([char]27+']7777;idle'+[char]7)`""
& $Exe +send-keys --target=p3a $oscIdle Enter 2>&1 | Out-Null
Start-Sleep -Seconds 6
Assert "OSC idle cleared" (-not ((Get-P3Title) -match '\(busy\)'))

"== 5: +rearrange rebuilds tree, closes unnamed pane"
$layout = '{"direction":"horizontal","ratio":30,"left":{"pane":"p3a"},"right":{"pane":"p3b"}}'
# PS 5.1 native-arg passing eats embedded quotes; escape them for Win32.
& $Exe +rearrange --target=p3 ('--layout=' + ($layout -replace '"','\"')) 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$w = Get-P3Json
$s = $w.tabs[0].splits
Assert "2 leaves after" (([regex]::Matches(($w | ConvertTo-Json -Depth 15), '"type":\s*"leaf"')).Count -eq 2)
Assert "root horizontal ratio 0.3" ($s.direction -eq 'horizontal' -and [math]::Abs($s.ratio - 0.3) -lt 0.01)
Assert "children p3a/p3b" ($s.left.terminal.name -eq 'p3a' -and $s.right.terminal.name -eq 'p3b')

"== 6: +rearrange error paths"
$dup = '{"direction":"horizontal","left":{"pane":"p3a"},"right":{"pane":"p3a"}}'
& $Exe +rearrange --target=p3 ('--layout=' + ($dup -replace '"','\"')) 2>&1 | Out-Null
Assert "duplicate errors" ($LASTEXITCODE -ne 0)
$missing = '{"pane":"nope"}'
& $Exe +rearrange --target=p3 ('--layout=' + ($missing -replace '"','\"')) 2>&1 | Out-Null
Assert "unknown pane errors" ($LASTEXITCODE -ne 0)

"== teardown"
& $Exe +close --target=p3 2>&1 | Out-Null
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) {
    "P3 ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "P3 ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
