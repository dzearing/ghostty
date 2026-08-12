# T755 acceptance: a CLI verb whose peer never answers gives up and says why.
#
# THE DEFECT, measured on 2026-08-11 and not inferred. `ipc-p1.ps1` was
# launched at 11:48:28; at 12:22 - 34 minutes later - a `ghoztty.exe +list`
# child started at 11:48:29 was still alive with 0.06s of CPU. Blocked, not
# spinning. The app it addressed had auto-launched in the same second and was
# alive and rendering.
#
# The shape is structural, not a fluke: the win32 IPC server reads the request
# on a listener thread and then marshals it to the GUI thread with NO timeout
# (`IpcServer.serveOne` -> `pending.done.wait()`). A GUI thread that is busy -
# a cold start, a session restore - or wedged is indistinguishable, from the
# client side, from one that will answer in a moment. And a synchronous
# `ReadFile` on a named pipe cannot be interrupted, so the client had no way
# out at all: no output, no error, no exit. Ctrl-C or nothing.
#
# WHAT IS ASSERTED HERE, against a fake server that accepts, reads the request
# and answers nothing (`ipc-fake-server.ps1 -Wedge`) - a peer that is wedged by
# construction, so nothing here depends on timing luck:
#
#   A. The bound fires. A wedged peer + a 2s bound = a nonzero exit inside a
#      few seconds, with a message naming the verb, what it was waiting for,
#      and the env var that buys more time.
#   B. Slow is not dead. Before it gives up, the CLI says out loud that it is
#      still waiting - so a genuinely slow start reads as slow rather than as
#      a hung terminal.
#   C. The control: a peer that DOES answer is untouched by any of this. It
#      returns its JSON, exit 0, with neither the notice nor the timeout - so
#      A is measuring the wedge and not the bound firing on everything.
#   D. The opt-out works. `GHOZTTY_IPC_TIMEOUT_MS=0` restores the old
#      wait-forever behavior for a caller who genuinely wants it.
#   E. A typo does NOT restore it. An unparseable value falls back to the
#      30s default and still gives up - the one way a bound can silently
#      un-fix itself.
#
# persistence: launches no Ghoztty instance at all. Every section drives the
# CLI against a fake pipe server on a private suffix, so there is no GUI whose
# session persistence could be on or off.
#
#   powershell -NoProfile -File test\win32\ipc-timeout.ps1
param(
    [string]$Com = 'D:\git\ghoztty\zig-out\bin\ghoztty.com',
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

if (-not (Test-Path $Com)) {
    Write-Host "SETUP: $Com not found - build the CLI twin first"
    Write-TestAssertedNothing -Label 'T755 ACCEPTANCE' -Reason "$Com not found"
}

$fake = Join-Path $PSScriptRoot 'ipc-fake-server.ps1'
$suffix = "-t755-$PID"
$pipeName = "ghoztty$suffix-$env:USERNAME"
$script:servers = @()

function Start-FakeServer {
    param([switch]$Wedge)
    $a = @('-NoProfile', '-File', $fake, '-Suffix', $suffix)
    if ($Wedge) { $a += '-Wedge' }
    $p = Start-Process powershell -ArgumentList $a -PassThru -WindowStyle Hidden
    $null = $p.Handle   # T197: cache before any wait, or ExitCode reads empty
    $script:servers += $p

    # Wait for the pipe to actually exist. Enumerating the pipe filesystem is
    # the reliable read here; Test-Path on a \\.\pipe\ leaf is not.
    foreach ($try in 1..100) {
        $names = [System.IO.Directory]::GetFiles('\\.\pipe\')
        if ($names -match [regex]::Escape($pipeName)) { return $p }
        Start-Sleep -Milliseconds 50
    }
    return $null
}

# Run the CLI with a HARD wall-clock cap of its own.
#
# Without this, a regression of the very property under test - the bound going
# away again - would HANG this script instead of failing it, and a suite that
# hangs is the failure mode T755 is about. So the harness never waits on the
# subject indefinitely either: the cap is far above every bound asserted here,
# and blowing it is itself a reportable answer (`TimedOut`).
function Invoke-BoundedCli {
    param([string[]]$CliArgs, [int]$CapMs)

    $stem = Join-Path $env:TEMP "ghoztty-t755-$PID-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # persistence: this launches a CLI VERB, not a GUI instance - it opens no
    # window and starts no shell, so there is no session for persistence to be
    # on or off for. The endpoint it dials is a fake pipe server, never an app.
    $p = Start-Process $Com -ArgumentList $CliArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$stem.out" -RedirectStandardError "$stem.err"
    $null = $p.Handle   # T197: cache before any wait, or ExitCode reads empty
    $timedOut = -not $p.WaitForExit($CapMs)
    if ($timedOut) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    else { $p.WaitForExit() }
    $sw.Stop()

    $text = (Read-SharedText "$stem.out") + (Read-SharedText "$stem.err")
    Remove-Item "$stem.out", "$stem.err" -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Code     = $(if ($timedOut) { $null } else { $p.ExitCode })
        Out      = $text
        TimedOut = $timedOut
        Ms       = $sw.ElapsedMilliseconds
    }
}

function Read-SharedText([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object IO.StreamReader($fs)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Stop-Servers {
    foreach ($p in $script:servers) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    $script:servers = @()
}

# Every CLI call in this script aims at the fake server, never at a real
# instance (the user's or a test's).
$env:GHOZTTY_PIPE_SUFFIX = $suffix

try {

"== A: a wedged peer is answered with a message, not an indefinite block"
$env:GHOZTTY_IPC_TIMEOUT_MS = '2000'
$srv = Start-FakeServer -Wedge
if (-not $srv) {
    Assert "fake wedged server bound $pipeName" $false
} else {
    $r = Invoke-BoundedCli -CliArgs @('+list', '--json') -CapMs 30000
    Assert "gives up on its own (took $($r.Ms)ms, bound 2000ms)" (-not $r.TimedOut)
    Assert "waited for the bound rather than failing instantly" ($r.Ms -ge 1500)
    Assert "exits nonzero" ($r.Code -ne 0)
    Assert "says it timed out" ($r.Out -match 'Timed out')
    Assert "names the verb it was running" ($r.Out -match '\+list')
    Assert "names what it was waiting for" ($r.Out -match 'get a response from')
    Assert "names the way to wait longer" ($r.Out -match 'GHOZTTY_IPC_TIMEOUT_MS')
}
Stop-Servers

"== B: before giving up, it says it is still waiting"
# The notice is fixed at 5s (ipc_timeout.notice_ms), so the bound has to be
# longer than that for both halves to be observable in one run.
$env:GHOZTTY_IPC_TIMEOUT_MS = '8000'
$srv = Start-FakeServer -Wedge
if (-not $srv) {
    Assert "fake wedged server bound $pipeName (B)" $false
} else {
    $r = Invoke-BoundedCli -CliArgs @('+list', '--json') -CapMs 30000
    Assert "prints the still-waiting notice" ($r.Out -match "Waiting for Ghoztty to answer '\+list'")
    Assert "notice does not replace the failure" ($r.Out -match 'Timed out')
    Assert "kept waiting past the notice (took $($r.Ms)ms, bound 8000ms)" ($r.Ms -ge 7000)
    Assert "still stopped at the bound" (-not $r.TimedOut)
}
Stop-Servers

"== C: control - a peer that answers is untouched by the bound"
$env:GHOZTTY_IPC_TIMEOUT_MS = '2000'
$srv = Start-FakeServer
if (-not $srv) {
    Assert "fake replying server bound $pipeName" $false
} else {
    $r = Invoke-BoundedCli -CliArgs @('+list', '--json') -CapMs 30000
    Assert "exits 0" ($r.Code -eq 0)
    Assert "returns the server's payload" ($r.Out -match '"windows"')
    Assert "answers well inside the bound ($($r.Ms)ms)" ($r.Ms -lt 2000)
    Assert "prints no timeout message" ($r.Out -notmatch 'Timed out')
    Assert "prints no waiting notice" ($r.Out -notmatch 'Waiting for Ghoztty')
}
Stop-Servers

"== D: GHOZTTY_IPC_TIMEOUT_MS=0 restores the wait-forever behavior"
$env:GHOZTTY_IPC_TIMEOUT_MS = '0'
$srv = Start-FakeServer -Wedge
if (-not $srv) {
    Assert "fake wedged server bound $pipeName (D)" $false
} else {
    $errFile = Join-Path $env:TEMP "ghoztty-t755-forever-$PID.txt"
    # persistence: a CLI verb against the fake server, as above - no GUI, no
    # session. This one is started rather than run to completion because the
    # claim under test is that it does NOT finish.
    $cli = Start-Process $Com -ArgumentList '+list', '--json' -PassThru `
        -WindowStyle Hidden -RedirectStandardError $errFile `
        -RedirectStandardOutput "$errFile.out"
    $null = $cli.Handle   # T197: cache before any wait
    Start-Sleep -Seconds 9
    $alive = -not $cli.HasExited
    Assert "still waiting after 9s with the bound opted out" $alive
    # ...and it is waiting OUT LOUD: the notice fires even when nothing will
    # ever time out, which is exactly when a user needs to be told. The CLI
    # still holds this file open, so it has to be read with sharing - a plain
    # Get-Content returns nothing here and would score a working notice as
    # missing.
    $errText = Read-SharedText $errFile
    Assert "an unbounded wait still announces itself" ($errText -match 'Waiting for Ghoztty')
    if ($alive) { Stop-Process -Id $cli.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $errFile, "$errFile.out" -Force -ErrorAction SilentlyContinue
}
Stop-Servers

"== E: an unparseable value falls back to the default bound, never to forever"
# The failure mode this rules out: a typo in the env var silently reinstating
# the 34-minute hang the bound exists to remove. The default is 30s, so this
# section is deliberately the slow one.
$env:GHOZTTY_IPC_TIMEOUT_MS = 'banana'
$srv = Start-FakeServer -Wedge
if (-not $srv) {
    Assert "fake wedged server bound $pipeName (E)" $false
} else {
    $r = Invoke-BoundedCli -CliArgs @('+list', '--json') -CapMs 90000
    $sec = [int]($r.Ms / 1000)
    Assert "a garbage bound still gives up (took ${sec}s)" ($r.Out -match 'Timed out')
    Assert "and exits nonzero" ($r.Code -ne 0)
    Assert "at the 30s default, not at some tiny value" ($r.Ms -ge 25000)
    Assert "and not much later than that" ((-not $r.TimedOut) -and ($r.Ms -lt 60000))
    Assert "the message quotes the default" ($r.Out -match '30\.0s')
}
Stop-Servers

} finally {
    Stop-Servers
    Remove-Item Env:\GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOZTTY_IPC_TIMEOUT_MS -ErrorAction SilentlyContinue
}

""
Write-TestVerdict -Label 'T755 ACCEPTANCE' -Pass $script:passes -Fail $script:failures
