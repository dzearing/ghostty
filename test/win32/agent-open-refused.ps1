# T469 acceptance: an OPEN the agent refuses must fail FAST and say WHY.
#
# The defect: when the local agent would not start a shell for a pane, it simply
# dropped the OPEN. No reply frame existed for "I will not open this", so the
# app's parked RPC sat out its full 10 s timeout and then painted the generic
# bring-up failure - which blames `error.Timeout` and "exhausting a system
# resource". Every refusal therefore looked the same and named none of them, and
# because by-type OPEN RPCs serialize on one mutex, a window of N panes paid the
# 10 s N times, in turn, for panes that were never coming.
#
# The fix is `OPEN_FAILED` (0x06), capability-gated per the agent contract. This
# script scores the two halves of that by OUTCOME - what the pane says, and how
# long it took to say it - never by log scraping:
#
#   C: control. With a normal cap, a second window opens a WORKING pane. Scored
#      FIRST and deliberately: without it, arm A proves nothing about refusals
#      (a build that refused every OPEN would also "pass" A), so read a C
#      failure as a broken harness/build rather than a T469 regression.
#   A: the fix. With the agent capped at ONE live session, the second window's
#      pane must show the cap message in well under 2 s, and must NOT blame a
#      timeout.
#   B: the skew. The SAME binary made to advertise an older HELLO
#      (GHOSTTY_AGENT_SUPPRESS_CAPS=open_failed) must degrade to exactly the
#      pre-T469 behavior - the generic message after the timeout - with no hang
#      and no garbling. This is the "old agent + new app" half of the contract,
#      reproduced on box instead of only in a unit test.
#
# Hermetic: a per-run LOCALAPPDATA, GHOSTTY_LOCAL_AGENT_BIN and IPC pipe suffix,
# run on a BACKGROUND Win32 desktop, and it only ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\agent-open-refused.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-open-refused-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit: reading `.Handle` afterwards
    # yields an EMPTY ExitCode and every `-eq 0` gate scores a working CLI FAIL.
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tag, $timeoutSec = 12) {
    Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" $timeoutSec | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return , @() }
    if ($null -ne $tree.data) { return , @($tree.data.windows) }
    return , @($tree.windows)
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in Windows-Of $tree) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Wait-Leaves($tag, $target, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tag
        if ((All-Leaves $tree).Count -ge $target) { return $tree }
        Start-Sleep -Milliseconds 500
    }
    return (Get-List "$tag-last")
}
function Read-Pane($id, $tag, $lines = 60) {
    Run-CliArgs @('+read', "--name=$id", "--lines=$lines") "$tmp\read-$tag.txt" 12 | Out-Null
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '')
}

# THE liveness oracle for a pane: type a unique marker and read it back TWICE -
# once as the echoed input line, once as the command's output. One occurrence is
# just keystrokes landing in a dead pane's line editor.
function Test-PaneResponsive($id, $tag, $timeoutSec = 40) {
    $marker = "T469x$($tag)x$(Get-Random -Maximum 999999)"
    Run-CliArgs @('+send-keys', "--target=$id", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $txt = (Read-Pane $id "resp-$tag") -replace '\s', ''
        if (([regex]::Matches($txt, [regex]::Escape($marker))).Count -ge 2) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# Open a window and poll its pane until it prints something matching $pattern.
# Returns @{ hit; ms; text } where `ms` is measured from AFTER `+new-window`
# returns - i.e. the PANE's own latency, with the CLI's own process-spawn cost
# left out of the number the 2 s criterion is scored against.
function Measure-PaneMessage($target, $tag, $pattern, $timeoutSec) {
    Run-CliArgs @('+new-window', "--target=$target") "$tmp\open-$tag.txt" 20 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        $last = Read-Pane $target "msg-$tag"
        if ($last -match $pattern) { return @{ hit = $true; ms = [int]$sw.Elapsed.TotalMilliseconds; text = $last } }
        Start-Sleep -Milliseconds 150
    }
    return @{ hit = $false; ms = [int]$sw.Elapsed.TotalMilliseconds; text = $last }
}

function Start-App($title) {
    $script:AppLog = Join-Path $tmp "applog-$title.err.txt"
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @() -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return 0 }
    return [int]$app.Pid
}

# A virgin state dir per arm: LOCALAPPDATA carries both the session-layout
# manifest and the agent's sessions.json, so sharing one across arms means arm
# N+1 restores arm N's windows before its own setup runs.
function Reset-State($arm) {
    $script:tmp = Join-Path $root "run-$arm"
    New-Item -ItemType Directory -Force (Join-Path $script:tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $script:tmp
}

# ============================================================================
# Setup
# ============================================================================
$null = Assert-GhozttyIsolatedBuild -Exe $Exe

Stop-TestProcs
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$saved = @{
    lad  = $env:LOCALAPPDATA
    bin  = $env:GHOSTTY_LOCAL_AGENT_BIN
    pipe = $env:GHOZTTY_PIPE_SUFFIX
    cap  = $env:GHOSTTY_AGENT_MAX_SESSIONS
    supp = $env:GHOSTTY_AGENT_SUPPRESS_CAPS
}
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# Isolate the IPC endpoint: every `+list` / `+read` / `+send-keys` below is an
# oracle, and a user instance answering the shared pipe would answer them about
# somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-openrefused'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

# ============================================================================
Say "== C: control - with a normal cap a second window opens a WORKING pane"
# ============================================================================
Reset-State 'control'
$env:GHOSTTY_AGENT_MAX_SESSIONS = $null
$env:GHOSTTY_AGENT_SUPPRESS_CAPS = $null

$appPid = Start-App 'control'
Assert "C the GUI came up" ($appPid -ne 0)
if ($appPid -ne 0) {
    $null = Wait-Leaves 'c0' 1 60
    Run-CliArgs @('+new-window', '--target=t469ok') "$tmp\open-c.txt" 20 | Out-Null
    $tree = Wait-Leaves 'c1' 2 60
    $leaves = All-Leaves $tree
    Assert "C a second pane exists" ($leaves.Count -ge 2)
    # The wedge's fingerprint is a pane reporting `running` with pid 0. Every
    # pane here must have a real child, or arm A's refusal means nothing.
    $bad = @($leaves | Where-Object { $null -eq $_.pid -or [int]$_.pid -eq 0 })
    Assert "C every pane has a real child (pid != 0)" ($bad.Count -eq 0)
    Assert "C the second pane takes input and echoes it back" (Test-PaneResponsive 't469ok' 'c')
}
Stop-TestProcs

# ============================================================================
Say "== A: a refused OPEN says why, fast"
# ============================================================================
Reset-State 'refused'
# ONE live session is the whole budget, so the app's own first pane takes it and
# the next window's OPEN is refused by `SessionTable.create` itself - the
# genuine `error.TooManySessions` path, not a fault injected beside it. The
# app spawns the agent with an inherited environment block, which is how this
# reaches a process the script never launches.
$env:GHOSTTY_AGENT_MAX_SESSIONS = '1'
$env:GHOSTTY_AGENT_SUPPRESS_CAPS = $null

$appPid = Start-App 'refused'
Assert "A the GUI came up" ($appPid -ne 0)
if ($appPid -ne 0) {
    $null = Wait-Leaves 'a0' 1 60
    # 12 s, not 2: the assertion is on the MEASURED latency below. A deadline at
    # the pass threshold could only ever report "no message", which would not
    # tell a reader whether the message was late or absent.
    $r = Measure-PaneMessage 't469refused' 'a' 'could not start a shell' 12
    Assert "A the refused pane says it could not start a shell" $r.hit
    if ($r.hit) {
        Say "   (message appeared after $($r.ms) ms)"
        # The whole point of the protocol half: not the 10 s the old path took.
        Assert "A it appeared in under 2 s (got $($r.ms) ms)" ($r.ms -lt 2000)
        # And the whole point of the wording half: the REASON, not the symptom.
        Assert "A it names the cap as the reason" ($r.text -match 'maximum number')
        Assert "A it tells the user what to do about it" ($r.text -match 'Close some panes')
        Assert "A it carries the agent's own counts" ($r.text -match 'live=1/1')
        Assert "A it no longer blames a timeout" ($r.text -notmatch 'Timeout')
        Assert "A it no longer blames a system resource" ($r.text -notmatch 'exhausting a system resource')
    }
}
Stop-TestProcs

# ============================================================================
Say "== B: skew - an agent that never advertises open_failed degrades cleanly"
# ============================================================================
Reset-State 'skew'
$env:GHOSTTY_AGENT_MAX_SESSIONS = '1'
# The same binary, made to advertise the HELLO of an agent that predates 0x06.
# The app must NOT be sent an opcode it would treat as a fatal framing error,
# and must fall back to exactly what it did before this task.
$env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'open_failed'

$appPid = Start-App 'skew'
Assert "B the GUI came up" ($appPid -ne 0)
if ($appPid -ne 0) {
    $null = Wait-Leaves 'b0' 1 60
    # The old path: silence, then the client's own 10 s timeout, then the
    # generic paint. Allowed 30 s so a slow box reads as slow, not as a hang.
    $r = Measure-PaneMessage 't469skew' 'b' 'non-functional' 30
    Assert "B the pane still comes up with the pre-T469 message (no hang)" $r.hit
    if ($r.hit) {
        Say "   (fallback message appeared after $($r.ms) ms)"
        # Proof it really took the OLD road rather than the new one: this arm is
        # the timeout path, so it must be slow AND must not carry the new text.
        Assert "B it took the timeout road (>= 5 s, got $($r.ms) ms)" ($r.ms -ge 5000)
        Assert "B it is the generic message, not the T469 one" ($r.text -notmatch 'could not start a shell')
    }
    # Nothing garbled the link: the app is still answering IPC about its windows.
    $tree = Get-List 'b-final'
    Assert "B the connection survived the skew (+list still answers)" `
        ((All-Leaves $tree).Count -ge 1)
}

} finally {
    Stop-TestProcs
    Stop-TestForegroundWatch
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    $env:GHOSTTY_AGENT_MAX_SESSIONS = $saved.cap
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $saved.supp
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host "ALL PASS ($script:passes checks)" -ForegroundColor Green; exit 0 }
Write-Host "$script:failures FAILURE(S) ($script:passes passed)" -ForegroundColor Red
exit 1
