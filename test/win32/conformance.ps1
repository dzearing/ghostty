# T25 conformance (spec S8 items 1-7): the "definition of replica" checklist
# run end-to-end from a fresh app start, including the docs/claude/cli.md three-pane
# example. Items 8-10 are covered by dedicated runs recorded in spec S9:
# item 8 hero-mode.ps1, item 9 ipc-relay.ps1 (fake-relay E2E; live Mac dial
# is a Mac-seat step), item 10 the skill flows (T17) which this script
# re-executes verbatim.
#
# Windows substitutions (documented in spec S8 evidence): nvim -> Git Bash
# vim, zsh -> powershell, tail -> Git Bash tail. Git's usr\bin is prepended
# to PATH so the docs/claude/cli.md commands resolve verbatim inside panes.
#
#   powershell -NoProfile -File test\win32\conformance.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-conf-$PID"
$work = Join-Path $tmp 'work'
New-Item -ItemType Directory -Force $work | Out-Null
# Panes must resolve vim/tail (the GUI inherits this PATH via auto-launch).
$env:PATH = 'C:\Program Files\Git\usr\bin;' + $env:PATH

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: this run's own IPC endpoint, set before any CLI call. Without it every
# `& $Exe` below inherits the caller pane's baked `$GHOZTTY_IPC_SOCKET` and
# drives the user's INSTALLED release instead of $Exe.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'conf')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# It kills the sibling agent too and drops the debug session-layout manifest,
# so a pane from a previous run cannot be focused in place of the fixture.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}
# T1240: the CLI runs ON THE TEST DESKTOP, not on the user's. `+new-window` is
# the one verb that auto-launches the app, and the window it spawns lands on the
# desktop of the process that spawned it - so this script used to throw a window
# across whatever the user was reading. `Invoke-OnTestDesktop` is `& $Exe` with a
# desktop named in the STARTUPINFO; nothing else about the assertions changed.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Every CLI call in this file goes through here. It returns { ExitCode, Output,
# Pid, TimedOut }; the child's stdout and stderr are captured to a file by the
# harness, which is what the old `cmd /c ... > file` dance was for - a
# GUI-subsystem exe writes zero bytes to a PowerShell `>` redirect (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}
function Get-List {
    return (Ghoz @('+list')).Output
}
function Get-IdeJson {
    $j = (Ghoz @('+list', '--json')).Output | ConvertFrom-Json
    $j.data.windows | Where-Object { $_.target -eq 'ide' }
}
function Get-IdeTitle {
    $m = [regex]::Match((Get-List), '(?m)^Window: "([^"]*)" \[target: ide\]')
    $m.Groups[1].Value
}
function Read-Pane($name, $lines) {
    $text = (Ghoz @('+read', "--name=$name", "--lines=$lines")).Output
    if ($null -eq $text) { return @() }
    return ($text -split "`r?`n")
}

$td = New-TestDesktop

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== S8.1: +new-window --target=ide --command='vim .' from cold (auto-launch)"
$r = Ghoz @('+new-window', '--target=ide', '--command=vim .', "--working-directory=$work")
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 4
Assert-GhozttyIsolated -Exe $Exe
$list = Get-List
Assert "window registered [target: ide]" ($list -match '\[target: ide\]')
# The editor is really running: its pane shows the netrw directory listing.
$ide = Get-IdeJson
$idePane = ($ide | ConvertTo-Json -Depth 15 |
    Select-String -Pattern '"name":\s*"([^"]+)"' -AllMatches).Matches[0].Groups[1].Value
$vimScreen = (Read-Pane $idePane 30) -join "`n"
Assert "vim (netrw) on screen" ($vimScreen -match 'Netrw')
"== S8.1b: re-run focuses, does not duplicate"
$r = Ghoz @('+new-window', '--target=ide')
Assert "exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
Assert "still exactly one ide" (([regex]::Matches((Get-List), '\[target: ide\]')).Count -eq 1)

"== S8.2: three-pane docs/claude/cli.md layout (term shell, logs tail -f)"
Set-Content -Path (Join-Path $work 'app.log') -Value 'CONF-SEED' -Encoding Ascii
$r = Ghoz @('+split', '--target=ide', '--name=term', '--direction=down', '--command=powershell')
Assert "term split exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
$r = Ghoz @('+split', '--target=ide', '--name=logs', '--direction=right', '--command=tail -f app.log')
Assert "logs split exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 3
$list = Get-List
Assert "term registered" ($list -match '\[name: term\]')
Assert "logs registered" ($list -match '\[name: logs\]')
Assert "3 leaves in ide" (([regex]::Matches((Get-IdeJson | ConvertTo-Json -Depth 15), '"type":\s*"leaf"')).Count -eq 3)

"== S8.3: +read --name=logs --lines=5 is byte-accurate"
# cmd's appender shares the file with tail -f's open handle; Add-Content
# does not (denied while msys tail holds the file).
1..7 | ForEach-Object { cmd /c "echo CONF-LINE-$_>>`"$work\app.log`"" }
Start-Sleep -Seconds 3
$read = @(Read-Pane 'logs' 5)
while ($read.Count -gt 0 -and $read[-1] -eq '') { $read = $read[0..($read.Count - 2)] }
$expected = 3..7 | ForEach-Object { "CONF-LINE-$_" }
Assert "exactly 5 lines" ($read.Count -eq 5)
Assert "last 5 lines byte-accurate" (($read -join '|') -eq ($expected -join '|'))

"== S8.4: +send-keys executes, C-c interrupts, escapes expand"
$r = Ghoz @('+send-keys', '--target=term', 'echo hi', 'Enter')
Assert "send exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
Assert "'hi' executed" ((Read-Pane 'term' 10) -contains 'hi')
[void](Ghoz @('+send-keys', '--target=term', 'ping -t 127.0.0.1', 'Enter'))
Start-Sleep -Seconds 3
[void](Ghoz @('+send-keys', '--target=term', 'C-c'))
Start-Sleep -Seconds 2
[void](Ghoz @('+send-keys', '--target=term', 'echo AFTER-INT', 'Enter'))
Start-Sleep -Seconds 2
Assert "C-c interrupted ping (prompt back)" ((Read-Pane 'term' 10) -contains 'AFTER-INT')
# \t + \n expansion: a reader pane compares the received line to a<TAB>b.
Set-Content -Path "$tmp\tabchk.ps1" -Encoding Ascii -Value @'
$x = [Console]::In.ReadLine()
if ($x -eq ('a' + [char]9 + 'b')) { 'TAB-EXPANDED-OK' } else { "TAB-FAIL:[$x]" }
'@
[void](Ghoz @('+split', '--target=ide', '--name=tabchk', '--direction=down', "--command=powershell -NoProfile -File $tmp\tabchk.ps1"))
Start-Sleep -Seconds 3
[void](Ghoz @('+send-keys', '--target=tabchk', 'a\tb\n'))
Start-Sleep -Seconds 2
Assert "a\tb\n expanded" ((Read-Pane 'tabchk' 10) -contains 'TAB-EXPANDED-OK')

"== S8.5: +set-state aggregation + OSC 7777"
[void](Ghoz @('+set-state', '--target=ide', '--state=busy'))
Start-Sleep -Seconds 1
Assert "busy suffix" ((Get-IdeTitle) -match '\(busy\)( \[DEBUG\])?$')
[void](Ghoz @('+set-state', '--target=term', '--state=needs_input'))
Start-Sleep -Seconds 1
Assert "needs_input beats busy" ((Get-IdeTitle) -match '\(needs_input\)( \[DEBUG\])?$')
[void](Ghoz @('+set-state', '--target=term', '--state=idle'))
Start-Sleep -Seconds 1
Assert "back to busy" ((Get-IdeTitle) -match '\(busy\)( \[DEBUG\])?$')
[void](Ghoz @('+set-state', '--target=ide', '--state=idle'))
Start-Sleep -Seconds 1
Assert "idle clears" (-not ((Get-IdeTitle) -match '\(busy\)|\(needs_input\)'))
# OSC 7777 from inside a pane (tabchk sits at a cmd prompt now).
$osc = "powershell -NoProfile -Command `"[console]::Write([char]27+']7777;needs_input'+[char]7)`""
[void](Ghoz @('+send-keys', '--target=tabchk', $osc, 'Enter'))
Start-Sleep -Seconds 6
Assert "OSC needs_input set" ((Get-IdeTitle) -match '\(needs_input\)( \[DEBUG\])?$')
$osc = "powershell -NoProfile -Command `"[console]::Write([char]27+']7777;idle'+[char]7)`""
[void](Ghoz @('+send-keys', '--target=tabchk', $osc, 'Enter'))
Start-Sleep -Seconds 6
Assert "OSC idle clears" (-not ((Get-IdeTitle) -match '\(needs_input\)'))

"== S8.6: +rename / +rearrange / +list per docs/claude/cli.md"
$r = Ghoz @('+rename', '--target=ide', '--title=CONF-OVERRIDE')
Assert "rename exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
Assert "title override wins" ((Get-IdeTitle) -match '^CONF-OVERRIDE( \[DEBUG\])?$')
$layout = '{"direction":"horizontal","ratio":30,"left":{"pane":"term"},"right":{"pane":"logs"}}'
$r = Ghoz @('+rearrange', '--target=ide', ('--layout=' + ($layout -replace '"','\"')))
Assert "rearrange exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 2
$ide = Get-IdeJson
$s = $ide.tabs[0].splits
Assert "2 leaves after rearrange" (([regex]::Matches(($ide | ConvertTo-Json -Depth 15), '"type":\s*"leaf"')).Count -eq 2)
Assert "root horizontal ratio 0.3" ($s.direction -eq 'horizontal' -and [math]::Abs($s.ratio - 0.3) -lt 0.01)
Assert "human tree lists panes" ((Get-List) -match '(?m)^Window: "CONF-OVERRIDE')

"== S8.7: second GUI launch forwards to first instance"
$before = ([regex]::Matches((Get-List), '(?m)^Window:')).Count
# persistence: n/a - this launch forwards its new-window to the live instance and exits; it restores nothing.
$second = Invoke-OnTestDesktop -Exe $Exe -TimeoutSec 15
Assert "second instance exited" (-not $second.TimedOut)
if (-not $second.TimedOut) { Assert "exit code 0" ($second.ExitCode -eq 0) }
Start-Sleep -Seconds 2
Assert "window forwarded (count +1)" (([regex]::Matches((Get-List), '(?m)^Window:')).Count -eq ($before + 1))

"== S8.6b: +close tears down each target; missing target exits 0"
$r = Ghoz @('+close', '--target=logs')
Assert "close logs exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
$list = Get-List
Assert "logs gone" (-not ($list -match '\[name: logs\]'))
Assert "ide window remains" ($list -match '\[target: ide\]')
[void](Ghoz @('+close', '--target=term'))
Start-Sleep -Seconds 1
$r = Ghoz @('+close', '--target=ide')
Assert "close window exit 0" ($r.ExitCode -eq 0)
Start-Sleep -Seconds 1
Assert "ide gone" (-not ((Get-List) -match '\[target: ide\]'))
$r = Ghoz @('+close', '--target=does-not-exist')
Assert "close missing exits 0" ($r.ExitCode -eq 0)

"== teardown"
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

""
if ($script:failures -eq 0) {
    "T25 CONFORMANCE (spec S8 items 1-7): ALL PASS"
    exit 0
} else {
    "T25 CONFORMANCE: $script:failures FAILURE(S)"
    exit 1
}

