# Acceptance for `+send-keys --keys-file=` (T210): text a caller did not author
# by hand must reach a pane BYTE-EXACT.
#
#   powershell -NoProfile -File test\win32\ipc-send-keys-fidelity.ps1
#
# The defect this exists for: a resume prompt was handed to `+send-keys` as a
# positional argument, PowerShell 5.1 did not escape its embedded `"` while
# building the native command line, and the prompt reached the pane as a
# fragment of run-together prose. `/reset-context` was never at the start of a
# line, so the reset silently never fired and the session ran to ~250k tokens.
# Everything logged success.
#
# Two things make this script an oracle rather than a demonstration:
#
#   * The capture is BYTE-EXACT, not a screen read. A helper in the pane reads
#     raw console keys and writes them to a file, so nothing normalizes away a
#     dropped quote or a swallowed space. It is written in PowerShell, which the
#     box always has - a capture that needs python would turn into a SKIP, and a
#     SKIP hides an un-run assertion (T219).
#   * Every keys-file case has a POSITIONAL-ARGUMENT negative control with the
#     same payload. Without it a green run cannot distinguish "the fix works"
#     from "this payload was never broken" - which is exactly how the length
#     theory survived: the transport is byte-exact at 10000 characters, so a
#     length ladder alone proves nothing about quoting.
#
# NOT interactive: everything here is IPC (+send-keys / +read), so it needs no
# foreground and does not belong on the T211 test desktop. The window is opened
# with --no-activate for the same reason.
#
# T248: the pane is named per-PID and the app is launched with
# --session-persistence=false after killing the repo's own agent, so a second
# run cannot silently reuse the previous run's pane and measure IT.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-skf-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$pane = "skf$PID"

. (Join-Path $Repo 'scripts\loop-session.ps1')   # New-LoopPromptFile / Test-LoopPromptArrived

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: this run's own IPC endpoint, before any CLI call — otherwise every
# `& $Exe` inherits the caller pane's baked `$GHOZTTY_IPC_SOCKET` and this
# script's whole point (what bytes reach a PTY) is measured on the user's
# installed release, typing its fixtures into their live panes.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'skfid')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Same app+agent kill as before, but exact-exe (a '*zig-out*' CommandLine
# match also catches a detached zig-out-release instance, T53b) and with the
# debug session-layout manifest dropped, which the private copy never did.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}
# T1240: the app and every CLI call run ON THE TEST DESKTOP, not on the user's.
# A bare launch puts its window on the desktop of the process that started it,
# and `+new-window` (the one auto-launching verb) does the same - so this script
# used to throw a window across whatever the user was reading. The transports
# under test are unchanged: `--keys-file` still carries bytes verbatim, and the
# positional-argument negative control is still a command line the child has to
# re-split.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Every CLI call in this file goes through here. It returns { ExitCode, Output,
# Pid, TimedOut }; the child's stdout and stderr are captured to a file by the
# harness, so a GUI-subsystem exe's output arrives (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}
function Read-Pane([int]$lines = 30) {
    return (Ghoz @('+read', "--name=$pane", "--lines=$lines")).Output
}
function Wait-Pane([string]$pat, [int]$sec = 30) {
    $d = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $d) {
        if ((Read-Pane 30) -match $pat) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# The in-pane capture. [Console]::ReadKey($true) takes one raw key without
# echoing it, so the bytes are recorded before any shell, line editor or
# renderer can touch them.
$capture = @'
param([string]$Out, [int]$N, [double]$Secs, [string]$Tag)
$sb = New-Object System.Text.StringBuilder
"READY-$Tag"
$deadline = (Get-Date).AddSeconds($Secs)
while ($sb.Length -lt $N -and (Get-Date) -lt $deadline) {
    if ([Console]::KeyAvailable) { [void]$sb.Append([Console]::ReadKey($true).KeyChar) }
    else { Start-Sleep -Milliseconds 15 }
}
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
"DONE-$Tag $($sb.Length)"
'@
$capPath = Join-Path $tmp 'capture.ps1'
[IO.File]::WriteAllText($capPath, $capture, (New-Object System.Text.UTF8Encoding($false)))

# Run one capture round. -Mode file sends via --keys-file, -Mode argv sends the
# payload as a positional argument (the pre-T210 transport). Returns what
# actually arrived.
$script:round = 0
function Invoke-Capture([string]$payload, [string]$mode) {
    $script:round++
    $tag = "R$($script:round)"
    $out = Join-Path $tmp "cap-$tag.txt"
    Remove-Item $out -ErrorAction SilentlyContinue
    # Ask for MORE bytes than we send, so a payload that arrives too LONG (an
    # argv split that duplicates or injects) is visible instead of being cut to
    # the expected length.
    $want = $payload.Length + 64
    [void](Ghoz @('+send-keys', "--target=$pane", "powershell -NoProfile -File $capPath -Out $out -N $want -Secs 12 -Tag $tag", 'Enter'))
    if (-not (Wait-Pane "READY-$tag" 30)) { return @{ Text = '<never ready>'; Rc = -1 } }
    Start-Sleep -Milliseconds 400
    if ($mode -eq 'file') {
        $pf = New-LoopPromptFile -Text $payload -Tag 'skf'
        $rc = (Ghoz @('+send-keys', "--target=$pane", "--keys-file=$pf")).ExitCode
        Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue
    } else {
        $rc = (Ghoz @('+send-keys', "--target=$pane", $payload)).ExitCode
    }
    Wait-Pane "DONE-$tag" 20 | Out-Null
    Start-Sleep -Milliseconds 300
    $got = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }
    # The capture keeps reading until it has $want bytes or times out, so the
    # pane is at a fresh prompt by the time the next round starts.
    return @{ Text = $got; Rc = $rc }
}

$td = New-TestDesktop

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== setup: app + named pane (no persistence, no activation)"
[void](Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false'))
Start-Sleep -Seconds 4
[void](Ghoz @('+new-window', "--target=$pane", '--no-activate'))
Start-Sleep -Seconds 3
Assert "pane $pane exists" ((Ghoz @('+list')).Output -match [regex]::Escape($pane))
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe

# The real 2026-07-30 shape: a slash command, a quoted phrase, a prose tail.
$real = '/reset-context settle the "DWM/PrintWindow" capture question first, it decides the shape of the whole task. Then read go.md and go'

"== 1: the field payload arrives byte-exact via --keys-file"
$r = Invoke-Capture $real 'file'
Assert "exit 0" ($r.Rc -eq 0)
Assert "byte-exact ($($r.Text.Length) of $($real.Length) chars)" ($r.Text -ceq $real)
Assert "starts with the slash command (a reset that is not at the start never fires)" ($r.Text.StartsWith('/reset-context '))

"== 2: NEGATIVE CONTROL - the same payload via a positional argument is mangled"
$r2 = Invoke-Capture $real 'argv'
Assert "argv transport does NOT deliver it intact" (-not ($r2.Text -ceq $real))
"     argv got $($r2.Text.Length) of $($real.Length) chars: $($r2.Text.Substring(0, [Math]::Min(60, $r2.Text.Length)))"

"== 3: quotes, percent signs, plus, a -Flag and a trailing backslash"
$spicy = 'quoted "one" and "two", pct %LOCALAPPDATA%, plus +, dash -Flag, tab-looking \t, dir C:\Users\tom\'
$r = Invoke-Capture $spicy 'file'
Assert "exit 0" ($r.Rc -eq 0)
Assert "byte-exact ($($r.Text.Length) of $($spicy.Length) chars)" ($r.Text -ceq $spicy)
Assert "literal backslash-t survived as two characters (no escape processing)" ($r.Text.Contains('\t'))
Assert "trailing backslash survived" ($r.Text.EndsWith('\'))

"== 4: NEGATIVE CONTROL - the same payload via a positional argument"
$r4 = Invoke-Capture $spicy 'argv'
Assert "argv transport does NOT deliver it intact" (-not ($r4.Text -ceq $spicy))
"     argv got $($r4.Text.Length) of $($spicy.Length) chars: $($r4.Text.Substring(0, [Math]::Min(60, $r4.Text.Length)))"

"== 5: a long prompt is not the problem - 1400 chars with quotes, byte-exact"
$long = '/reset-context '
while ($long.Length -lt 1400) { $long += 'verify the "delivery" and then continue; T208 and T209 come after. ' }
$long = $long.Substring(0, 1400)
$r = Invoke-Capture $long 'file'
Assert "exit 0" ($r.Rc -eq 0)
Assert "byte-exact ($($r.Text.Length) of 1400 chars)" ($r.Text -ceq $long)

"== 6: named keys and escapes still work alongside --keys-file"
# The file's bytes are verbatim; the positional Enter after it is still a CR.
$plain = 'no-quotes-here'
$pf = New-LoopPromptFile -Text $plain -Tag 'skf-order'
$out = Join-Path $tmp 'cap-order.txt'
Remove-Item $out -ErrorAction SilentlyContinue
[void](Ghoz @('+send-keys', "--target=$pane", "powershell -NoProfile -File $capPath -Out $out -N $($plain.Length + 1) -Secs 12 -Tag ORD", 'Enter'))
Assert "capture ready" (Wait-Pane 'READY-ORD' 30)
Start-Sleep -Milliseconds 400
$r = Ghoz @('+send-keys', "--target=$pane", "--keys-file=$pf", 'Enter')
Assert "exit 0" ($r.ExitCode -eq 0)
Wait-Pane 'DONE-ORD' 20 | Out-Null
Start-Sleep -Milliseconds 300
$ord = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }
Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue
Assert "file bytes then CR, in that order" ($ord -ceq ($plain + "`r"))

"== 7: an unreadable --keys-file fails loudly instead of sending nothing"
$r = Ghoz @('+send-keys', "--target=$pane", "--keys-file=$tmp\does-not-exist.txt")
$err = $r.Output
Assert "exit nonzero" ($r.ExitCode -ne 0)
Assert "names the path and the reason" ($err -match 'keys-file' -and $err -match 'FileNotFound')

"== 8: the upgrade gate's own oracle sees an intact prompt in a pane tail"
# This is the production check from upgrade-ghoztty-windows.ps1: type the prompt
# WITHOUT Enter, then confirm it arrived before submitting. Verified against the
# pane's rendered tail, wrapping and all.
$gate = 'gate probe: /reset-context read go.md and go'
$pf = New-LoopPromptFile -Text $gate -Tag 'skf-gate'
[void](Ghoz @('+send-keys', "--target=$pane", "--keys-file=$pf"))
Start-Sleep -Seconds 2
$tail = Read-Pane 30
Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue
Assert "Test-LoopPromptArrived sees the typed prompt" (Test-LoopPromptArrived -Tail $tail -Text $gate)
Assert "and does NOT see a prompt that was never typed" (-not (Test-LoopPromptArrived -Tail $tail -Text 'gate probe: a different prompt entirely'))
[void](Ghoz @('+send-keys', "--target=$pane", 'C-c'))

"== teardown"
[void](Ghoz @('+close', "--target=$pane"))
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

""
if ($script:failures -eq 0) {
    "SEND-KEYS FIDELITY ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "SEND-KEYS FIDELITY ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
