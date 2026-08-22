# T199 acceptance: a harness never leaves a live ghoztty behind in its own
# scratch directory.
#
#   powershell -NoProfile -File test\win32\harness-process-leak.ps1
#
# THE DEFECT THIS GUARDS. On 2026-07-29 a debugging run pointed the delivery
# script at a stand-in install dir (`%TEMP%\gh-dbg2\install`). Delivering is
# exactly the job that ENDS by launching the app, so the run left a live GUI
# ghoztty behind - windows, message loop, possibly an IPC pipe instance. It was
# found by eye NINETEEN HOURS later while taking the pre-state for an unrelated
# delivery. A stray file is litter; a stray app is an oracle problem, because
# every later process or pipe assertion on this box has to answer "is that
# ghoztty mine or the leak's?".
#
# The reason no existing helper covered it: lib\CleanSlate.ps1's
# Stop-RepoGhoztty REFUSES any exe outside the repo, by design, so a stand-in
# install dir is precisely what it cannot clean up. lib\HarnessLeak.ps1 is the
# missing counterpart, and this script is its teeth.
#
# WHAT IS ASSERTED
#
#   A (safety)   the root check refuses what it must - an empty root, a
#                relative root, %TEMP% itself, a drive root, the user's install
#                dir - and accepts a proper scratch root under TEMP or the repo.
#   B (live)     a REAL ghoztty GUI launched from a scratch install dir is
#                found by path, is invisible to the repo-scoped teardown (the
#                gap), and is killed by Stop-HarnessGhoztty.
#   C (failure)  a harness that dies MID-RUN still tears down: a child that
#                registers its root, launches, then throws leaves nothing.
#   D (teeth)    the same child WITHOUT the registration leaks - so C is a
#                measurement, not a tautology.
#   E (sweep)    right now, on this box, no ghoztty process is running out of
#                %TEMP% at all. This is the standing arm that must stay at zero;
#                a failure names the pid, the path and the age in hours.
#
# Hermetic: a per-run scratch root, a private IPC pipe suffix and a private
# LOCALAPPDATA for section B, the GUI on the BACKGROUND test desktop, and every
# kill filtered on ExecutablePath under this run's own root.
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# TestDesktop FIRST: both libraries arm a PowerShell.Exiting handler, and the
# order they load in must not matter (it did until T199 made that guard a flag).
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

$root = Join-Path $env:TEMP "ghoztty-harness-leak-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
# This script's own scratch is registered too: it launches a real app below, so
# it is exactly the kind of harness the helper exists for.
Register-HarnessGhozttyRoot -Root $root | Out-Null

# ---------------------------------------------------------------------------
Say '== A: the root check refuses what it must'
# ---------------------------------------------------------------------------
function Test-Refused([string]$Root) {
    try { Assert-HarnessScratchRoot -Root $Root | Out-Null; return $false }
    catch { return $true }
}
Assert (Test-Refused '') 'A1 an empty root is refused (a blank root kills everything)'
Assert (Test-Refused 'relative\path') 'A2 a relative root is refused'
Assert (Test-Refused $env:TEMP) 'A3 %TEMP% ITSELF is refused - a scratch root is a dir UNDER it'
Assert (Test-Refused 'C:\') 'A4 a drive root is refused'
Assert (Test-Refused (Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty')) `
    "A5 the user's install dir is refused"
Assert (-not (Test-Refused $root)) 'A6 a proper scratch root under %TEMP% is accepted'
Assert (-not (Test-Refused (Join-Path $repo 'zig-out\t199-scratch'))) `
    'A7 a scratch root under the repo is accepted too'
Assert ((Stop-HarnessGhoztty -Root $root) -eq 0) 'A8 tearing down an empty root is 0, not an error'

# ---------------------------------------------------------------------------
Say '== B: a real GUI launched from a scratch install dir'
# ---------------------------------------------------------------------------
$bRoot = Join-Path $root 'b'
$bInstall = Join-Path $bRoot 'install'
$bLocal = Join-Path $bRoot 'localappdata'
New-Item -ItemType Directory -Force $bInstall | Out-Null
New-Item -ItemType Directory -Force $bLocal | Out-Null
Register-HarnessGhozttyRoot -Root $bRoot | Out-Null
$bExe = Join-Path $bInstall 'ghoztty.exe'
Copy-Item -LiteralPath $exe -Destination $bExe -Force

$savedLocal = $env:LOCALAPPDATA
$savedSuffix = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-t199leak$PID"
$env:LOCALAPPDATA = $bLocal
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
try {
    # persistence: OFF - this arm is about the process, not about sessions, and
    # a persistent pane would drag an agent into a directory nobody cleans.
    $app = Start-OnTestDesktop -Exe $bExe -Arguments @('--session-persistence=false') `
        -StdErr (Join-Path $bRoot 'app.err.txt')
    $hwnd = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Assert ($hwnd -ne [IntPtr]::Zero) 'B1 the scratch-dir app came up with a window'

    $found = @(Get-HarnessGhozttyProcess -Root $bRoot)
    Assert ($found.Count -ge 1) "B2 the leak is found BY PATH under the scratch root ($($found.Count))"
    Assert (@($found | Where-Object { $_.ProcessId -eq $app.Pid }).Count -eq 1) `
        'B3 and the process it found is the one we launched'

    # The gap this helper fills, stated as an assertion: the repo-scoped
    # teardown every other script uses cannot even look here.
    Assert (-not (Test-UnderRepo $bExe)) 'B4 the repo-scoped teardown is blind to it (not under the repo)'
    $repoRefused = $false
    try { Stop-RepoGhoztty -Exe $bExe -SettleMs 0 | Out-Null } catch { $repoRefused = $true }
    Assert $repoRefused 'B5 Stop-RepoGhoztty REFUSES it rather than silently missing it'
    Assert (@(Get-HarnessGhozttyProcess -Root $bRoot).Count -ge 1) 'B6 so it is still running after that refusal'

    $killed = Stop-HarnessGhoztty -Root $bRoot -SettleMs 900
    Assert ($killed -ge 1) "B7 Stop-HarnessGhoztty killed it ($killed)"
    Assert (@(Get-HarnessGhozttyProcess -Root $bRoot).Count -eq 0) 'B8 and nothing is left under the scratch root'
} finally {
    $env:LOCALAPPDATA = $savedLocal
    if ($null -eq $savedSuffix) { Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_PIPE_SUFFIX = $savedSuffix }
    Remove-TestDesktop
}
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # The control first: "nothing became foreground" is worth nothing from a
    # watcher that never sampled at all.
    Assert ($fgSeen.Count -gt 0) 'B9 the foreground watcher actually sampled (control)'
    $fgLeaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
    Assert ($fgLeaked.Count -eq 0) 'B10 the scratch-dir app never became foreground on the real desktop'
}

# ---------------------------------------------------------------------------
Say '== C/D: the failure path, and the control that proves it is measured'
# ---------------------------------------------------------------------------
# The stand-in is a COPY OF cmd.exe named ghoztty.exe: C and D are about the
# teardown mechanism (does it run when the harness dies?), and the mechanism
# matches on image name plus ExecutablePath, which a copy satisfies exactly.
# Using the real GUI here would add a window and an IPC endpoint to a test that
# measures neither - section B is where the real app is on trial.
$childScript = Join-Path $root 'child.ps1'
$childBody = @'
param([string]$Lib, [string]$Root, [string]$FakeExe, [int]$Register)
. $Lib
$install = Split-Path -Parent $FakeExe
New-Item -ItemType Directory -Force $install | Out-Null
Copy-Item -LiteralPath "$env:SystemRoot\System32\cmd.exe" -Destination $FakeExe -Force
if ($Register -eq 1) { Register-HarnessGhozttyRoot -Root $Root | Out-Null }
# persistence: n/a - this is a copy of cmd.exe wearing the name, not the app.
Start-Process -FilePath $FakeExe -ArgumentList '/c', 'ping -n 120 127.0.0.1 > nul' `
    -WindowStyle Hidden | Out-Null
Start-Sleep -Milliseconds 800
throw 'deliberate mid-run failure (this is the point of the test)'
'@
Set-Content -LiteralPath $childScript -Value $childBody -Encoding ASCII

function Invoke-LeakChild([string]$Root, [int]$Register) {
    $fake = Join-Path $Root 'install\ghoztty.exe'
    $p = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript,
        '-Lib', (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1'),
        '-Root', $Root, '-FakeExe', $fake, '-Register', "$Register")
    # exitcode-audit: the oracle is the process table below, not this exit code;
    # the child is EXPECTED to die of a throw.
    $null = $p.Handle
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch {} }
    Start-Sleep -Milliseconds 700
}

$cRoot = Join-Path $root 'c'
Register-HarnessGhozttyRoot -Root $cRoot | Out-Null
Invoke-LeakChild -Root $cRoot -Register 1
$cLeft = @(Get-HarnessGhozttyProcess -Root $cRoot)
Assert ($cLeft.Count -eq 0) "C1 a registered root is torn down even when the harness THROWS ($($cLeft.Count) left)"

$dRoot = Join-Path $root 'd'
Register-HarnessGhozttyRoot -Root $dRoot | Out-Null
Invoke-LeakChild -Root $dRoot -Register 0
$dLeft = @(Get-HarnessGhozttyProcess -Root $dRoot)
Assert ($dLeft.Count -ge 1) "D1 TEETH: without the registration the same run leaks ($($dLeft.Count) left)"
$dKilled = Stop-HarnessGhoztty -Root $dRoot -SettleMs 700
Assert ($dKilled -ge 1) "D2 and the helper cleans up a leak it did not create ($dKilled)"
Assert (@(Get-HarnessGhozttyProcess -Root $dRoot).Count -eq 0) 'D3 nothing left under the control root'

# ---------------------------------------------------------------------------
Say '== E: the standing sweep - nothing on this box runs ghoztty out of %TEMP%'
# ---------------------------------------------------------------------------
# Zero is the only acceptable answer, and it can be, because nobody runs their
# terminal out of a temp directory. Anything here was put there by a harness.
$leaks = @(Get-LeakedGhozttyProcess)
if ($leaks.Count -gt 0) {
    foreach ($l in $leaks) {
        Say ("      leaked: pid=$($l.ProcessId) age=$($l.AgeHours)h $($l.ExecutablePath)")
    }
}
Assert ($leaks.Count -eq 0) "E1 no ghoztty process is running out of %TEMP% ($($leaks.Count) found)"

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)" }
else { Say "$script:fail FAILURE(S) ($script:pass passed)" }
if ($script:fail -gt 0) { exit 1 }
exit 0
