# Single-instance launch acceptance (tracker T1022, building D79's answer).
#
# THE BEHAVIOR. Starting Ghoztty when Ghoztty is already running must not give
# you a second app. The launch loses the race for the IPC endpoint, forwards a
# `new-window` carrying its OWN arguments to the winner, and exits - so you get
# one app, one tray icon, one session list, and a new window, the way the Mac
# app bundle and Windows Terminal both behave. The user chose that in D79 over
# two copies quietly sharing one agent and one saved layout.
#
# WHAT KEEPS SIDE-BY-SIDE DEVELOPMENT WORKING. The endpoint is keyed on the
# build LINEAGE (`ipc_client.endpointPath`: the debug/release suffix, or an
# explicit GHOZTTY_PIPE_SUFFIX), so a debug `zig-out` build and the installed
# release never join each other. Section B proves that with two suffixes rather
# than by launching the user's installed release, which would open a window in
# the terminal they are sitting in - the same reason every other script here
# runs against a private endpoint (lib\Isolation.ps1).
#
# AND THE CON D79 NAMED. Two copies of ONE lineage do join - the installed
# release and the Desktop portable copy share an endpoint by design - so a
# shortcut pointing at one can hand you a window from the other, "which can
# look like the wrong build started". Section C is that con's answer: the
# launch carries its build identity across the handoff, and a MISMATCH earns a
# note (printed to stderr by the CLI) and a desktop balloon. A launch of the
# same build says nothing, because two copies of the same bits are
# indistinguishable and the join is meant to be invisible.
#
# Section C drives the server directly with a hand-framed request
# (lib\PaneCapture.ps1's Invoke-GhozttyIpc -Extra): the `handoff` field is
# written only by a LOSING LAUNCH, so there is no way to ask for another build's
# answer from outside without writing the field. The sender's half - that a real
# handoff carries the field at all - is pinned by unit tests in the `none` lane
# (src\os\ipc_client.zig, "buildRequestWithHandoff").
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: private
# IPC endpoints, per-run $env:LOCALAPPDATA, session persistence OFF (this is
# about instance identity, not restore - T851 owns that), and it only ever kills
# ghoztty / ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\single-instance-join.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-single-instance-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 900
}

# The zig-out app processes alive right now, as pids.
#
# Counted by IMAGE PATH, never by the pid Start-Process hands back: a launch
# from a pane re-execs itself out of the shell's kill-on-close job (T675
# job_escape), so the process we started routinely exits while the app it
# became keeps running. "The second launch exited" is therefore a statement
# about how many apps exist, not about one pid.
function Get-AppPids {
    return @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like '*zig-out*' } |
        ForEach-Object { [int]$_.ProcessId })
}

# The window list over the pipe, so a section can address a SPECIFIC instance
# without moving the harness's own environment around. No `--json`: that flag is
# the CLI's own output formatting and the server has never taken one.
function Get-Windows-On($pipe) {
    $resp = Invoke-GhozttyIpc -Action 'list' -PipeName $pipe -TimeoutMs 12000
    if ($null -eq $resp -or -not $resp.success) { return $null }
    return @($resp.data.windows)
}

function Get-ServerPid($pipe) {
    $resp = Invoke-GhozttyIpc -Action 'version' -PipeName $pipe -TimeoutMs 12000
    if ($null -eq $resp -or -not $resp.success) { return 0 }
    return [int]$resp.data.pid
}

function Wait-WindowCount($pipe, $count, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $wins = @()
    while ((Get-Date) -lt $deadline) {
        $got = Get-Windows-On $pipe
        if ($null -ne $got) {
            $wins = @($got)
            if ($wins.Count -ge $count) { return $wins }
        }
        Start-Sleep -Milliseconds 500
    }
    return $wins
}

# One hermetic GUI launch on the endpoint named by $suffix.
#
# persistence: every launch here passes --session-persistence=false through the
# splat below. This script's subject is instance IDENTITY, not restore - T851
# and the session-* family own that - and a restored layout would make the
# window counts A4/B5 assert on somebody else's panes.
function Launch($suffix, $launchArgs) {
    $saved = $env:GHOZTTY_PIPE_SUFFIX
    $env:GHOZTTY_PIPE_SUFFIX = $suffix
    Start-Process -FilePath $Exe -WindowStyle Minimized `
        -ArgumentList (@('--session-persistence=false') + $launchArgs) | Out-Null
    $env:GHOZTTY_PIPE_SUFFIX = $saved
}

function Leaves($node) {
    $acc = @()
    if ($null -eq $node) { return $acc }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { $acc += Leaves $node.left; $acc += Leaves $node.right }
    return $acc
}
function Window-Dirs($w) {
    $acc = @()
    foreach ($t in @($w.tabs)) { foreach ($l in @(Leaves $t.splits)) { $acc += [string]$l.working_directory } }
    return $acc
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $root

Assert 'ghoztty exe exists in zig-out' (Test-Path $Exe)

# Private IPC endpoint FIRST (T441), then the build-mode + nothing-listening
# pre-flight both asserts make.
[void](Set-GhozttyTestIsolation -Tag 'sijoin')
$suffixA = $env:GHOZTTY_PIPE_SUFFIX
$pipeA = Get-GhozttyPipeName -Suffix $suffixA
Assert-GhozttyPrivateEndpoint -Exe $Exe

if (-not (Test-Path $Exe)) {
    'ABORT: no zig-out build to test.'
    exit 2
}

# ============================================================================
"== A: a second launch of the SAME build joins the app already running"
# ============================================================================
$cwdA = Join-Path $root 'launch-dir'
New-Item -ItemType Directory -Force $cwdA | Out-Null

Launch $suffixA @()
$winsA1 = @(Wait-WindowCount $pipeA 1 45)
Assert 'A1 the first launch came up with a window' ($winsA1.Count -ge 1)
Assert-GhozttyIsolated -Exe $Exe

$pidsA1 = @(Get-AppPids)
Assert 'A2 exactly one app process is running' ($pidsA1.Count -eq 1)
$serverA1 = Get-ServerPid $pipeA
Assert 'A3 that process is the one answering on the endpoint' (
    $serverA1 -ne 0 -and $pidsA1 -contains $serverA1)

# The second launch: same exe, same endpoint, an explicit working directory so
# the window it produces can be told from the first one's.
$marker = Join-Path $root 'handoff-marker.txt'
Launch $suffixA @("--working-directory=$cwdA")
$winsA2 = @(Wait-WindowCount $pipeA ($winsA1.Count + 1) 45)
Assert 'A4 a NEW window appeared after the second launch' (
    $winsA2.Count -eq $winsA1.Count + 1)

# Settle: give a would-be second app time to finish coming up before counting.
# A count taken too early would pass for the wrong reason.
Start-Sleep -Seconds 4
$pidsA2 = @(Get-AppPids)
Assert 'A5 still exactly one app process - the second launch exited' (
    $pidsA2.Count -eq 1)
Assert 'A6 and it is the SAME process, so no tray icon or session client moved' (
    $pidsA2.Count -eq 1 -and $pidsA1.Count -eq 1 -and $pidsA2[0] -eq $pidsA1[0])
Assert 'A7 one instance answers the endpoint, not two' (
    (Get-ServerPid $pipeA) -eq $serverA1)

$dirsA = @()
foreach ($w in $winsA2) { $dirsA += Window-Dirs $w }
Assert "A8 the second launch's --working-directory reached the window it opened" (
    @($dirsA | Where-Object { $_ -and (Split-Path -Leaf $_) -eq 'launch-dir' }).Count -ge 1)

# ...and its COMMAND, which is the half T487 fixed and only unit tests covered.
# No spaces or quotes in the redirect: Start-Process joins argv with spaces and
# re-quotes what it must, and a quoted redirect target survives neither that nor
# cmd's own parse. $env:TEMP has no spaces on this box, which is what makes the
# bare form safe here.
Launch $suffixA @('-e', 'cmd.exe', '/c', "echo T1022OK>$marker")
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline -and -not (Test-Path $marker)) { Start-Sleep -Milliseconds 500 }
Assert "A9 the second launch's -e command ran in the window that opened" (
    (Test-Path $marker) -and ((Get-Content $marker -Raw) -match 'T1022OK'))
Assert 'A10 the command launch did not start an app either' (
    @(Get-AppPids).Count -eq 1)

# ============================================================================
"== B: a launch of a DIFFERENT lineage still starts its own app"
# ============================================================================
# The everyday case this protects is a debug zig-out build beside the installed
# release. Their endpoints differ by the `-debug` suffix; two explicit suffixes
# reproduce exactly that difference without touching the user's terminal.
$suffixB = "$suffixA-b"
$pipeB = Get-GhozttyPipeName -Suffix $suffixB

# Read A's window count NOW rather than deriving it from the counts above: A9's
# `cmd /c echo` pane exits the moment it has written the marker and takes its
# window with it, so an arithmetic expectation would be asserting on a race
# instead of on whether B disturbed A.
$countBeforeB = @(Get-Windows-On $pipeA).Count

Launch $suffixB @()
$winsB = @(Wait-WindowCount $pipeB 1 45)
Assert 'B1 the other-lineage launch came up with its own window' ($winsB.Count -ge 1)

Start-Sleep -Seconds 3
$pidsB = @(Get-AppPids)
Assert 'B2 there are now TWO app processes' ($pidsB.Count -eq 2)

$serverB = Get-ServerPid $pipeB
Assert 'B3 the second endpoint is answered by a different process' (
    $serverB -ne 0 -and $serverB -ne $serverA1)
Assert 'B4 the first instance is still on its own endpoint, untouched' (
    (Get-ServerPid $pipeA) -eq $serverA1)
Assert 'B5 the first instance kept its windows (nothing was adopted)' (
    $countBeforeB -ge 1 -and @(Get-Windows-On $pipeA).Count -eq $countBeforeB)

# ============================================================================
"== C: a handoff from a DIFFERENT build is not silent"
# ============================================================================
$verC = Invoke-GhozttyIpc -Action 'version' -PipeName $pipeA -TimeoutMs 12000
$runningVersion = if ($null -ne $verC -and $verC.success) { [string]$verC.data.version } else { '' }
$runningCommit = if ($null -ne $verC -and $verC.success) { [string]$verC.data.commit } else { '' }
$runningExe = if ($null -ne $verC -and $verC.success) { [string]$verC.data.exe } else { '' }
Assert 'C1 the running instance reports its own build' (
    $runningVersion -ne '' -and $runningExe -ne '')

# A launch that IS this build: the join is invisible, so the reply carries no
# caveat. This is the everyday arm and the one that must never turn noisy.
$same = Invoke-GhozttyIpc -Action 'new-window' -PipeName $pipeA -TimeoutMs 20000 -Extra @{
    handoff = @{ version = $runningVersion; commit = $runningCommit; exe = $runningExe }
}
Assert 'C2 a same-build handoff succeeds' ($null -ne $same -and $same.success)
Assert 'C3 ...and says nothing about it' (
    $null -ne $same -and [string]$same.note -eq '')

# A launch of another build: the window still opens (the user asked for one and
# got one), and the reply explains WHICH copy owns it.
$diff = Invoke-GhozttyIpc -Action 'new-window' -PipeName $pipeA -TimeoutMs 20000 -Extra @{
    handoff = @{
        version = '0.0.0-not-this-build'
        commit  = '0000000'
        exe     = 'D:\somewhere\else\Ghoztty-portable-x64\ghoztty.exe'
    }
}
Assert 'C4 a different-build handoff still opens the window' (
    $null -ne $diff -and $diff.success)
$noteC = if ($null -ne $diff) { [string]$diff.note } else { '' }
Assert 'C5 ...and answers with a caveat instead of silence' ($noteC -ne '')
Assert 'C6 the caveat names the build that actually owns the window' (
    $noteC -match [regex]::Escape($runningVersion))
Assert 'C7 the caveat names the copy the user started' (
    $noteC -match 'Ghoztty-portable-x64')
Assert 'C8 the caveat says what to do about it' (
    $noteC -match 'quit the running instance first')

# The same text is shown as a desktop balloon by the running app
# (App.showLaunchHandoffNotice) - that call is on this path and cannot be read
# back from outside, so the note is the oracle for both.

# A handoff with NO fields at all - an older launcher, whose request omits the
# object entirely - must read as "nothing to say", never as a difference.
$bare = Invoke-GhozttyIpc -Action 'new-window' -PipeName $pipeA -TimeoutMs 20000
Assert 'C9 a launch too old to send a build identity stays silent' (
    $null -ne $bare -and $bare.success -and [string]$bare.note -eq '')

# A launch that ALREADY asked (T1023) still earns the caveat on the reply - the
# CLI and this script read it - but the running app does not repeat it as a
# balloon, which after a dialog the user just answered would be the same fact
# twice. Only the note is readable from here; the balloon's absence is the
# `prompted` branch in IpcHandlers.handoffNote, pinned by the unit tests.
$asked = Invoke-GhozttyIpc -Action 'new-window' -PipeName $pipeA -TimeoutMs 20000 -Extra @{
    handoff = @{
        version  = '0.0.0-not-this-build'
        commit   = '0000000'
        exe      = 'D:\somewhere\else\Ghoztty-portable-x64\ghoztty.exe'
        prompted = $true
    }
}
Assert 'C10 a launch that already asked still gets the caveat on the reply' (
    $null -ne $asked -and $asked.success -and [string]$asked.note -ne '')

# ============================================================================
"== D: a launch of a DIFFERENT build asks before it hands the window over"
# ============================================================================
# T1023, and D79's mitigation ("two DIFFERENT versions still start
# independently") landing where it actually can. The agent's pipe and the saved
# layout are shared on purpose - both have to survive an update, which is the
# one moment the build changes underneath them - so a stale copy cannot become a
# second app without reopening every window twice and fighting over the layout.
# What the mitigation buys the user instead is the CHOICE: the launch names both
# builds and opens nothing until it is answered.
#
# The mismatch is unreachable from outside otherwise - the only exe here is the
# one in zig-out, so both sides of a real handoff report the same build. The
# debug-only GHOZTTY_HANDOFF_VERSION / GHOZTTY_HANDOFF_COMMIT seam makes the
# launch CLAIM another build, which is exactly the input the comparison takes.
# The dialog is answered by posting its own WM_COMMAND (IDOK / IDCANCEL): no
# SendInput, so this arm works on the background test desktop.
if (-not ('GhozttyTestDlg' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GhozttyTestDlg {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
}
'@
}

# [NullString]::Value, never $null: a $null bound to a .NET string parameter
# arrives as "", and FindWindowW then matches only a window whose title is
# empty - which the dialog's never is.
function Find-Prompt {
    return [GhozttyTestDlg]::FindWindowW('GhozttyConfirmDialog', [NullString]::Value)
}
function Wait-Prompt($timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = Find-Prompt
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}
function Answer-Prompt($hwnd, $id) {
    # WM_COMMAND with BN_CLICKED in the high word, the control id in the low
    # word - the shape the dialog's own buttons send.
    [void][GhozttyTestDlg]::PostMessageW($hwnd, 0x0111, [IntPtr]$id, [IntPtr]::Zero)
}
function Wait-PromptGone($timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Find-Prompt) -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# A launch that claims to be another build. Everything else about it is a normal
# launch: same exe, same endpoint, same lineage.
function Launch-AsBuild($suffix, $version, $commit, $mode, $launchArgs) {
    $savedSuffix = $env:GHOZTTY_PIPE_SUFFIX
    $savedVersion = $env:GHOZTTY_HANDOFF_VERSION
    $savedCommit = $env:GHOZTTY_HANDOFF_COMMIT
    $savedMode = $env:GHOZTTY_HANDOFF_PROMPT
    $env:GHOZTTY_PIPE_SUFFIX = $suffix
    $env:GHOZTTY_HANDOFF_VERSION = $version
    $env:GHOZTTY_HANDOFF_COMMIT = $commit
    if ($mode) { $env:GHOZTTY_HANDOFF_PROMPT = $mode } else { $env:GHOZTTY_HANDOFF_PROMPT = $null }
    Start-Process -FilePath $Exe -WindowStyle Minimized `
        -ArgumentList (@('--session-persistence=false') + $launchArgs) | Out-Null
    $env:GHOZTTY_PIPE_SUFFIX = $savedSuffix
    $env:GHOZTTY_HANDOFF_VERSION = $savedVersion
    $env:GHOZTTY_HANDOFF_COMMIT = $savedCommit
    $env:GHOZTTY_HANDOFF_PROMPT = $savedMode
}

Assert 'D0 no question is on screen before this section' ((Find-Prompt) -eq [IntPtr]::Zero)

$appsBeforeD = @(Get-AppPids).Count
$countBeforeD = @(Get-Windows-On $pipeA).Count

Launch-AsBuild $suffixA '0.0.0-older-copy' '0000000' $null @()
$dlg = Wait-Prompt 45
Assert 'D1 the launch of a different build put a question on screen' ($dlg -ne [IntPtr]::Zero)
Assert 'D2 ...and opened nothing while it waited for an answer' (
    @(Get-Windows-On $pipeA).Count -eq $countBeforeD)

# Cancel: the user would rather quit the running copy themselves.
Answer-Prompt $dlg 2
Assert 'D3 the question closed when it was answered' (Wait-PromptGone 20)
Start-Sleep -Seconds 4
Assert 'D4 cancelling opened no window in the running app' (
    @(Get-Windows-On $pipeA).Count -eq $countBeforeD)
Assert 'D5 ...and the copy the user started exited rather than becoming a second app' (
    @(Get-AppPids).Count -eq $appsBeforeD)

# Open Window: the same launch, answered the other way.
Launch-AsBuild $suffixA '0.0.0-older-copy' '0000000' $null @()
$dlg2 = Wait-Prompt 45
Assert 'D6 the question comes up again for the next such launch' ($dlg2 -ne [IntPtr]::Zero)
Answer-Prompt $dlg2 1
$winsD = @(Wait-WindowCount $pipeA ($countBeforeD + 1) 45)
Assert 'D7 answering "Open Window" opens one in the app already running' (
    $winsD.Count -eq $countBeforeD + 1)
Start-Sleep -Seconds 4
Assert 'D8 ...still without starting a second app' (
    @(Get-AppPids).Count -eq $appsBeforeD)

# A SAME-build launch is never asked - that is the everyday case and the one
# that must stay invisible.
$countBeforeSame = @(Get-Windows-On $pipeA).Count
Launch $suffixA @()
$winsSame = @(Wait-WindowCount $pipeA ($countBeforeSame + 1) 45)
Assert 'D9 a same-build launch is never asked, it just opens its window' (
    $winsSame.Count -eq $countBeforeSame + 1 -and (Find-Prompt) -eq [IntPtr]::Zero)

# And a launch told to skip the question keeps the old behaviour exactly, so a
# scripted launch of a mismatched build can never block on a modal dialog.
$countBeforeJoin = @(Get-Windows-On $pipeA).Count
Launch-AsBuild $suffixA '0.0.0-older-copy' '0000000' 'join' @()
$winsJoin = @(Wait-WindowCount $pipeA ($countBeforeJoin + 1) 45)
Assert 'D10 GHOZTTY_HANDOFF_PROMPT=join hands off without asking' (
    $winsJoin.Count -eq $countBeforeJoin + 1)
Assert 'D11 ...and put no question on screen' ((Find-Prompt) -eq [IntPtr]::Zero)

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# --- stamp (T783) -----------------------------------------------------------
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard single-instance-join -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:passes -Fail $script:failures
