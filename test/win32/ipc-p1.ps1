# P1 acceptance (spec Phases P1 / tracker T08): +new-window, +list, +close
# against a debug build. Non-interactive; asserts and exits nonzero on any
# failure. Only ever touches ghoztty processes running from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-p1.ps1
#
# Covers: auto-launch from cold, named-window create, list shape (human +
# json), idempotent focus (no duplicate), inline split + named pane,
# -e direct exec, close pane / close window / close missing, second-instance
# forwarding.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-p1-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: give this run its OWN IPC endpoint before any CLI call. Without it every
# `& $Exe` below inherits the caller pane's baked `$GHOZTTY_IPC_SOCKET` and this
# floor measures the user's INSTALLED release rather than $Exe.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ipcp1')

# T1193: the CLI runs ON THE TEST DESKTOP, not on the user's. `+new-window` is
# the one verb that auto-launches the app, and the window it spawns lands on the
# desktop of the process that spawned it - so this floor, which CLAUDE.md names
# for every change, threw a window across whatever the user was reading on
# essentially every task the loop ran. `Invoke-OnTestDesktop` is `& $Exe` with a
# desktop named in the STARTUPINFO; nothing else about the assertions changed.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# T248: one shared reset instead of a private copy. Exact-exe matching is still
# the rule ('*zig-out*' also matched a detached soak instance running from
# zig-out-release, T53b), and the reset now also kills the sibling agent and
# drops the debug session-layout manifest — a pane from a previous run survives
# an app-only kill twice over, and `+new-window --target=` then FOCUSES it
# instead of running this run's fixture.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

# Every CLI call in this file goes through here. It returns { ExitCode, Output,
# Pid, TimedOut }; the child's stdout and stderr are captured to a file by the
# harness, which is also what the old `cmd /c ... > file` dance was for - a
# GUI-subsystem exe writes zero bytes to a PowerShell `>` redirect (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}

function Get-List {
    return (Ghoz @('+list')).Output
}

# T379: wait for a +list pattern instead of sleeping a fixed interval. The
# FIRST launch of a just-replaced exe is cold (Defender scans the new file,
# nothing is cached) and can exceed any fixed sleep that warm runs meet -- the
# original 2s sleep is exactly how this floor failed once per rebuild and then
# passed forever. Polls resolve as soon as the pattern shows, so warm runs get
# FASTER, and the timeout only spends itself on a run that would have failed.
function Wait-ListMatch([string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $l = Get-List
        if ($l -match $Pattern) { return $l }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $l
}

# T379: every PASS/FAIL line is teed to a transcript file so a red run keeps
# its evidence. Callers summarise with `| Select-Object -Last 1` by design,
# which used to discard exactly the lines that said WHAT failed; the trailer
# now names this file, so the summary still points at the details.
$transcript = Join-Path $env:TEMP 'ghoztty-ipc-p1-last.log'

$td = New-TestDesktop

& {

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 1: +new-window auto-launch from cold, all basic flags"
$r = Ghoz @('+new-window', '--target=p1win', '--title=P1Title', '--command=echo p1-marker')
Assert "exit 0" ($r.ExitCode -eq 0)
$list = Wait-ListMatch '\[target: p1win\]'
Assert-GhozttyIsolated -Exe $Exe
Assert "window registered under target" ($list -match '\[target: p1win\]')
Assert "title override shows" ($list -match 'P1Title')

"== 2: idempotent re-create focuses, no duplicate"
$r = Ghoz @('+new-window', '--target=p1win')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
$list = Get-List
Assert "still exactly one p1win" (([regex]::Matches($list, '\[target: p1win\]')).Count -eq 1)

"== 3: inline split + named pane + explicit cwd"
$r = Ghoz @('+new-window', '--target=p1ide', '--split=down', '--split-command=echo split-pane', '--name=p1term', '--working-directory=C:\Windows')
Assert "exit 0" ($r.ExitCode -eq 0)
# Wait on the cwd (the last field to settle: it is served from the pane's
# cached pwd, T111b); when it shows, the window and pane rows are there too.
$list = Wait-ListMatch ([regex]::Escape('C:\Windows'))
Assert "second window registered" ($list -match '\[target: p1ide\]')
Assert "named pane registered" ($list -match '\[name: p1term\]')
Assert "cwd honored" ($list -match [regex]::Escape('C:\Windows'))

"== 4: -e direct exec"
$r = Ghoz @('+new-window', '--target=p1exec', '-e', 'cmd', '/K', 'echo', 'p1-direct')
Assert "exit 0" ($r.ExitCode -eq 0)
$list = Wait-ListMatch '\[target: p1exec\]'
Assert "exec window registered" ($list -match '\[target: p1exec\]')

"== 5: json shape"
$json = $null
try { $json = (Ghoz @('+list', '--json')).Output | ConvertFrom-Json } catch {}
Assert "json parses" ($null -ne $json)
Assert "success true" ($json.success -eq $true)
Assert "windows array present" ($null -ne $json.data.windows)
$p1ide = $json.data.windows | Where-Object { $_.target -eq 'p1ide' }
Assert "split node shape" ($p1ide.tabs[0].splits.type -eq 'split' -and
    $p1ide.tabs[0].splits.left.type -eq 'leaf' -and
    $null -ne $p1ide.tabs[0].splits.ratio)
# working_directory is served from the pane's CACHED pwd (T111b) so that
# +list never takes a terminal lock. Assert the FIELD, not just that the path
# appears somewhere in the human tree -- the older text assert above also
# matches the cmd.exe title, so it would pass on an empty working_directory.
$p1leaf = $p1ide.tabs[0].splits.left.terminal
Assert "leaf reports working_directory" (
    $null -ne $p1leaf -and $p1leaf.working_directory -match 'Windows')

"== 6: +close named pane"
$r = Ghoz @('+close', '--target=p1term')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
$list = Get-List
Assert "pane gone" (-not ($list -match '\[name: p1term\]'))
Assert "window still there" ($list -match '\[target: p1ide\]')

"== 7: +close windows"
$r = Ghoz @('+close', '--target=p1ide')
Assert "close window exit 0" ($r.ExitCode -eq 0)
[void](Ghoz @('+close', '--target=p1exec'))
Start-Sleep -Seconds 1
$list = Get-List
Assert "p1ide gone" (-not ($list -match '\[target: p1ide\]'))

"== 8: +close missing target is silent success"
$r = Ghoz @('+close', '--target=does-not-exist')
Assert "exit 0" ($r.ExitCode -eq 0)

"== 9: second GUI launch forwards new-window and exits"
$before = ([regex]::Matches((Get-List), '(?m)^Window:')).Count
# persistence: n/a - this launch forwards its new-window to the live instance and exits; it restores nothing.
$second = Invoke-OnTestDesktop -Exe $Exe -TimeoutSec 15
Assert "second instance exited" (-not $second.TimedOut)
if (-not $second.TimedOut) { Assert "exit code 0" ($second.ExitCode -eq 0) }
Start-Sleep -Seconds 2
$after = ([regex]::Matches((Get-List), '(?m)^Window:')).Count
Assert "window count grew" ($after -eq ($before + 1))

"== teardown"
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

} 2>&1 | Tee-Object -FilePath $transcript

""
# The verdict goes through the shared scorer (T271), which refuses to call a
# run with zero passing assertions a pass; -NoExit is how the failure trailer
# still reaches the transcript.
Complete-TestBody  # T1039: the run reached the end of its body
$verdict = Write-TestVerdict -Label 'P1 ACCEPTANCE' -Pass $script:passes -Fail $script:failures -NoExit
if ($verdict.Code -ne 0) { Add-Content $transcript $verdict.Line }
exit $verdict.Code
