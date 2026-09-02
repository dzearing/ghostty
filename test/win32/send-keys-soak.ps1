# ON-DEMAND soak for `+send-keys` delivery integrity (T664). NOT part of the
# P1-P3 floor: one pass is minutes long, and its job is to answer a question
# the floor cannot — "can a text run lose bytes, ever?" — by repeating the
# suspect shape a few hundred times instead of once.
#
#   powershell -NoProfile -File test\win32\send-keys-soak.ps1 [-Rounds 40]
#
# The shape under soak is the one report that started this: a `--keys-file`
# text run plus `Enter`, landing a beat after a BARE Enter, into a pane running
# git-bash `read -e` — i.e. what `/reset-context` does to a Claude Code
# composer. Seen once in five runs of test\win32\reset-context.ps1, section B's
# pane received `RC-TEXT[ontinue-marker-B]`: the leading `c` gone.
#
# What makes this an oracle rather than a demonstration:
#
#   * The judge is a RECEIPT FILE the in-pane shell appends every line it read
#     to — outside the pane, so it cannot be confused with what the screen
#     happens to show. A screen read cannot tell a byte that never arrived from
#     a byte the grid lost; a receipt can.
#   * Lines are compared for EQUALITY, not containment. A truncated sentence is
#     still a substring of the intact one, so `Contains` is blind to exactly
#     the leading-byte loss this exists to catch.
#   * Two payloads alternate: the 17-byte marker from the report, and a ~100
#     byte handoff sentence whose framed form crosses the 64-byte pooled write
#     buffer in `termio.Exec.queueWrite` — the only seam in our write path that
#     splits one run across two pty writes.
#   * The gap between the Enter and the payload is RANDOMISED across the window
#     the report described, so a race that needs a particular alignment cannot
#     hide behind one fixed sleep. The seed is fixed, so a run is repeatable.
#
# Measured on 2026-08-10 against d8b4aacda: 315 sends across this and three
# other shapes (fixed-delay, delay sweep, window churn, under a concurrent
# build), zero losses — see docs/design/windows-parity-tasks/T664.md.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$Rounds = 40,
    [int]$MinDelayMs = 80,
    [int]$MaxDelayMs = 1400,
    # Teeth check: expect every payload MINUS its first character - the exact
    # loss this soak exists to catch - so a healthy run goes red. An oracle that
    # cannot be made to fail is decoration.
    [switch]$Break
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) {
    Write-Host 'SKIP: git-bash not found - the readline pane under soak is a bash script'
    exit 1
}
$tmp = Join-Path $env:TEMP "ghoztty-sks-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

$short = 'continue-marker-B'
$long = 'Read C:/Users/David/AppData/Local/Temp/reset-context-cont-4182.txt - it contains your instructions.'
$fShort = Join-Path $tmp 'short.txt'
$fLong = Join-Path $tmp 'long.txt'
[IO.File]::WriteAllText($fShort, $short, (New-Object System.Text.ASCIIEncoding))
[IO.File]::WriteAllText($fLong, $long, (New-Object System.Text.ASCIIEncoding))
$receipt = Join-Path $tmp 'received.txt'

# LF endings, ASCII, no BOM: a BOM would land in front of the shebang.
function Write-Sh([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), (New-Object System.Text.ASCIIEncoding))
}
Write-Sh (Join-Path $tmp 'proxy.sh') @'
#!/bin/bash
# readline input (so the pane edits its line the way a composer does), and
# every submitted line appended to the receipt the soak judges by.
R="$1"
while IFS= read -r -e -p 'rc> ' l; do
  printf '%s\n' "$l" >> "$R"
done
'@

# T1240: the app and every CLI call run ON THE TEST DESKTOP, not on the user's.
# A bare launch puts its window on the desktop of the process that started it,
# and `+new-window` (the one auto-launching verb) does the same - so this soak
# used to throw a window across whatever the user was reading, and then keep it
# there for the whole run. Nothing about the byte-exactness judgement changed.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Every CLI call in this file goes through here. It returns { ExitCode, Output,
# Pid, TimedOut }; the child's stdout and stderr are captured to a file by the
# harness, so a GUI-subsystem exe's output arrives (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}

function To-Unix([string]$p) { (& $bash -lc "cygpath -u '$($p -replace "'", "''")'").Trim() }
function Read-Pane([string]$name, [int]$lines = 8) {
    return (Ghoz @('+read', "--name=$name", "--lines=$lines")).Output
}
function Wait-Pane([string]$name, [string]$pat, [int]$sec = 30) {
    $d = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $d) {
        if ((Read-Pane $name) -match $pat) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'sksoak')
Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
Assert-GhozttyPrivateEndpoint -Exe $Exe

# persistence: off - this soak wants a virgin pane per run, and a restore would
# bring back the previous run's proxy panes to send into.
$td = New-TestDesktop
[void](Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false'))
Start-Sleep -Seconds 4
$win = "sks$PID"
[void](Ghoz @('+new-window', "--target=$win", '--no-activate', "--shell=$bash",
    "--command=bash $(To-Unix (Join-Path $tmp 'proxy.sh')) '$(To-Unix $receipt)'"))
Start-Sleep -Seconds 3
Assert-GhozttyIsolated -Exe $Exe
if (-not (Wait-Pane $win 'rc>' 30)) { 'SETUP FAIL: the proxy never prompted'; exit 1 }

"== soak: $Rounds sends, gap $MinDelayMs-${MaxDelayMs}ms after a bare Enter"
$rand = New-Object System.Random 664
$sent = New-Object System.Collections.ArrayList
for ($i = 1; $i -le $Rounds; $i++) {
    $useLong = ($i % 2 -eq 0)
    [void]$sent.Add($(if ($useLong) { $long } else { $short }))
    [void](Ghoz @('+send-keys', "--target=$win", 'Enter'))
    Start-Sleep -Milliseconds $rand.Next($MinDelayMs, $MaxDelayMs)
    [void](Ghoz @('+send-keys', "--target=$win", "--keys-file=$(if ($useLong) { $fLong } else { $fShort })", 'Enter'))
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 3

# The receipt holds one line per submitted line: an empty one for each bare
# Enter, then the payload. Compare payload lines in order, by EQUALITY.
$lines = @()
if (Test-Path $receipt) { $lines = @(Get-Content $receipt) }
$payloads = @($lines | Where-Object { $_ -ne '' })
$bad = 0
for ($i = 0; $i -lt $sent.Count; $i++) {
    $want = if ($Break) { $sent[$i].Substring(1) } else { $sent[$i] }
    $got = if ($i -lt $payloads.Count) { $payloads[$i] } else { '<missing>' }
    if ($got -ne $want) {
        $bad++
        "  send $($i + 1) MISMATCH"
        "     want: $want"
        "     got : $got"
    }
}
if ($payloads.Count -ne $sent.Count) {
    $bad++
    "  MISMATCH received $($payloads.Count) payload lines, sent $($sent.Count)"
}

"== teardown"
[void](Ghoz @('+close', "--target=$win"))
Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

""
if ($bad -eq 0) {
    "SEND-KEYS SOAK: ALL PASS ($($sent.Count) sends byte-exact)"
    exit 0
} else {
    "SEND-KEYS SOAK: $bad FAILURE(S) of $($sent.Count) sends"
    exit 1
}
