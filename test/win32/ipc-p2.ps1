# P2 acceptance (spec Phases P2 / tracker T12): +split, +rename, +send-keys
# against a debug build. Non-interactive; exits nonzero on any failure.
# Only ever touches ghoztty processes running from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-p2.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-p2-$PID"
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
[void](Set-GhozttyTestIsolation -Tag 'ipcp2')

# T1193: every CLI call runs ON THE TEST DESKTOP. `+new-window` auto-launches
# the app, and the window lands on the desktop of the process that spawned it -
# so this floor threw a window across the user's screen on every run.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Exact-exe matching is still the rule (T53b); the reset now also kills the
# sibling agent and drops the debug session-layout manifest, so a pane this
# script created in a PREVIOUS run cannot be focused in place of the fixture.
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
function Get-List {
    return (Ghoz @('+list')).Output
}
function Get-IdeJson {
    # T1285: the JSON comes off STDOUT alone. Sharing one stream with the CLI's
    # diagnostics is how a 5s "Waiting for Ghoztty to answer" notice turned a
    # slow answer into "Invalid JSON primitive: Waiting."
    $j = (Ghoz @('+list', '--json')).StdOut | ConvertFrom-Json
    $j.data.windows | Where-Object { $_.target -eq 'p2ide' }
}

# T379: poll +list until a pattern shows, so the FIRST launch of a
# just-replaced exe (cold: Defender scan, no cache) cannot outrun a fixed
# sleep. Warm runs resolve on the first poll.
function Wait-ListMatch([string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $l = Get-List
        if ($l -match $Pattern) { return $l }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $l
}

# T379: tee every PASS/FAIL line to a transcript so a red run keeps its
# evidence past a `| Select-Object -Last 1` summary; the trailer names it.
$transcript = Join-Path $env:TEMP 'ghoztty-ipc-p2-last.log'

$td = New-TestDesktop

& {

Invoke-FloorBody {

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 1: three-pane layout by name (docs/claude/cli.md example shape)"
[void](Need 'the p2ide fixture window' @('+new-window', '--target=p2ide'))
# Cold-launch guard first (T379); the settle sleep after it stays, because the
# later +send-keys sections need the pane's shell up, not just the window row.
Need-Listed 'the p2ide fixture window' '\[target: p2ide\]' (Wait-ListMatch '\[target: p2ide\]')
Start-Sleep -Seconds 3
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe
$r = Ghoz @('+split', '--target=p2ide', '--name=p2term', '--direction=down')
Assert "split 1 exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
$r = Ghoz @('+split', '--target=p2ide', '--name=p2logs', '--direction=right')
Assert "split 2 exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "p2term registered" ($list -match '\[name: p2term\]')
Assert "p2logs registered" ($list -match '\[name: p2logs\]')
$ide = Get-IdeJson
$ideText = $ide | ConvertTo-Json -Depth 15
Assert "3 leaves in p2ide" (([regex]::Matches($ideText, '"type":\s*"leaf"')).Count -eq 3)

"== 2: idempotent +split --name (no new pane)"
$r = Ghoz @('+split', '--target=p2ide', '--name=p2term', '--direction=down')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
$ideText = Get-IdeJson | ConvertTo-Json -Depth 15
Assert "still 3 leaves" (([regex]::Matches($ideText, '"type":\s*"leaf"')).Count -eq 3)

"== 3: +split --pane targeting"
$r = Ghoz @('+split', '--pane=p2term', '--direction=right', '--name=p2deep', '--percent=30')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
$ideText = Get-IdeJson | ConvertTo-Json -Depth 15
Assert "p2deep created" ($ideText -match 'p2deep')
Assert "percent ratio applied" ($ideText -match '0\.7')

"== 4: +send-keys executes (shell title change observable via +list)"
$r = Ghoz @('+send-keys', '--target=p2term', 'title P2-SENT-OK', 'Enter')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
Assert "command ran in pane" ((Get-List) -match 'P2-SENT-OK')

"== 5: +send-keys escapes (\n) and C-c accepted"
[void](Ghoz @('+send-keys', '--target=p2term', 'title P2-ESCAPED\n'))
Start-Sleep -Seconds 2
Assert "escape-run title" ((Get-List) -match 'P2-ESCAPED')
$r = Ghoz @('+send-keys', '--target=p2term', 'C-c')
Assert "C-c exit 0" ($r.ExitCode -eq 0)

"== 6: +send-keys missing target errors"
$r = Ghoz @('+send-keys', '--target=p2ghost', 'x')
Assert "nonzero exit" ($r.ExitCode -ne 0)

"== 7: +rename override wins over terminal titles"
$r = Ghoz @('+rename', '--target=p2ide', '--title=P2-OVERRIDE')
Assert "rename exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
# Debug builds append a " [DEBUG]" marker inside the quoted title.
Assert "window title is override" ((Get-List) -match 'Window: "P2-OVERRIDE( \[DEBUG\])?"')
[void](Ghoz @('+send-keys', '--target=p2term', 'title P2-SHELL-FIGHTS\n'))
Start-Sleep -Seconds 2
$list = Get-List
Assert "override still wins" ($list -match 'Window: "P2-OVERRIDE( \[DEBUG\])?"')
Assert "tab title tracks shell" ($list -match 'P2-SHELL-FIGHTS')

"== 8: +rename missing target errors"
$r = Ghoz @('+rename', '--target=p2ghost', '--title=x')
Assert "nonzero exit" ($r.ExitCode -ne 0)

}  # Invoke-FloorBody - teardown below runs whether or not the body stopped early

"== teardown"
[void](Ghoz @('+close', '--target=p2ide'))
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

} 2>&1 | Tee-Object -FilePath $transcript

""
# The verdict goes through the shared scorer (T271), which refuses to call a
# run with zero passing assertions a pass; -NoExit is how the failure trailer
# still reaches the transcript.
Complete-TestBody  # T1039: the run reached the end of its body
$verdict = Write-TestVerdict -Label 'P2 ACCEPTANCE' -Pass $script:passes -Fail $script:failures -NoExit
if ($verdict.Code -ne 0) { Add-Content $transcript $verdict.Line }
exit $verdict.Code
