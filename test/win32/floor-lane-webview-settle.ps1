<#
.SYNOPSIS
  Acceptance test for scripts\lib\WebViewLane.ps1 and floor-lane.ps1's
  between-lane WebView2 settle (T592).

.DESCRIPTION
  Two of the four floor lanes stand up a REAL WebView2 environment, and
  `-Lane all` used to start the next lane the instant the previous one exited.
  Three times in two days that produced a red floor that was not red code: the
  incoming lane asked for an environment while the outgoing lane's browser tree
  was still tearing down and got hr=0x80004005 for it. Each occurrence cost a
  turn, and a gate that goes red for a scheduling artifact teaches the loop to
  re-run its own floor instead of reading it.

  The behavior under test is three things: WHICH msedgewebview2.exe processes
  belong to a test lane (the browser AND the renderer/GPU children, which carry
  the private profile but not the embedder's exe name), that the wrapper WAITS
  for them rather than returning on Stop-Process, and that a wait which runs out
  is SAID rather than swallowed -- so the next red lane can be read against it.

  Everything runs against a FIXTURE: a private copy of cmd.exe named
  msedgewebview2.exe (the CIM filter matches on the image name, so the fixture
  has to carry it) blocking on a `waitfor` signal that never arrives, with the
  marker under test trailing after a `rem`. That is how the fixture's command
  line carries `ghoztty-wv2test-` or `--webview-exe-name=` without running a
  browser -- a marker cannot go in waitfor's own signal name, which rejects `-`
  and `=`. Nothing here can touch a real WebView2: the user's own viewer panes
  run under `--webview-exe-name=ghoztty.exe` and their own profile, and arm 3 is
  the proof that a process carrying neither test marker is left alone.

  Arms 1-3 are identity, 4-6 the wait (fast, slow, and the give-up), 7 the
  wording, 8 the sweep, 9 the profile-directory prune, 10-11 the wiring in
  floor-lane.ps1, 12 end-to-end through a real lane run.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\WebViewLane.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

$Sandbox = Join-Path $env:TEMP ("wv2-settle-test-{0}" -f $PID)
if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

# The fixture has to BE msedgewebview2.exe: Get-WebViewLaneHost asks CIM for
# that image name, and a test that matched some other name would be testing a
# different function than the one that ships.
$Fixture = Join-Path $Sandbox 'msedgewebview2.exe'
Copy-Item -LiteralPath "$env:SystemRoot\System32\cmd.exe" -Destination $Fixture -Force

# A test-binary name that cannot collide with a real lane's.
$FakeExe = 'ghoztty-wv2settle-fixture.exe'
$Started = @()
$script:FixtureSeq = 0

function Start-Fixture {
    # The marker rides in a trailing `rem`, which is the only place it can go:
    # waitfor's signal name rejects '-' and '=', and those are exactly the
    # characters both markers are made of.
    param([string]$Marker)
    # A signal name per fixture: two `waitfor` processes blocking on the same
    # name is a shape that does not reliably stay blocked, and a fixture that
    # exits early turns an identity arm into a mystery.
    $script:FixtureSeq++
    $signal = "GhozttyWv2SettleFixture$($script:FixtureSeq)"
    $p = Start-Process -FilePath $Fixture `
        -ArgumentList '/c', "waitfor /t 600 $signal > nul & rem $Marker" `
        -PassThru -WindowStyle Hidden
    $null = $p.Handle
    $script:Started += $p
    for ($i = 0; $i -lt 50; $i++) {
        $seen = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
        if ($seen -and $seen.CommandLine) { break }
        Start-Sleep -Milliseconds 100
    }
    return $p
}

function Stop-Fixture {
    # /T: the fixture is a shell with a blocked `waitfor` under it, and killing
    # only the shell would leave that child on the box for ten minutes.
    # Launched rather than called: a native exe's stderr becomes a terminating
    # NativeCommandError under $ErrorActionPreference='Stop' in PS 5.1, and
    # "the process is already gone" is the normal case here, not a failure.
    param($Proc)
    Start-Process -FilePath 'taskkill.exe' -ArgumentList '/T', '/F', '/PID', $Proc.Id `
        -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
}

try {
    # -- 1: the profile marker, which is what the whole browser TREE carries
    $fx1 = Start-Fixture -Marker 'ghoztty-wv2test-999999'
    $seen = @(Get-WebViewLaneHost -ExeNames @($FakeExe))
    Check 'a process carrying the private test profile is found' `
        (@($seen | Where-Object { $_.ProcessId -eq $fx1.Id }).Count -eq 1) "found $($seen.Count)"

    # -- 2: the embedder marker, which only the browser process carries
    $fx2 = Start-Fixture -Marker "--webview-exe-name=$FakeExe"
    $seen = @(Get-WebViewLaneHost -ExeNames @($FakeExe))
    Check 'a browser process named by its embedder exe is found' `
        (@($seen | Where-Object { $_.ProcessId -eq $fx2.Id }).Count -eq 1) "found $($seen.Count)"
    Stop-Fixture $fx1
    Stop-Fixture $fx2

    # -- 3: THE RULE. An msedgewebview2 carrying neither marker is somebody
    # else's -- the user's own viewer panes are exactly this shape, and a sweep
    # that took them would close the panes they are reading this in.
    $fx3 = Start-Fixture -Marker 'GhozttyWv2SettleUnrelated'
    $seen = @(Get-WebViewLaneHost -ExeNames @($FakeExe))
    Check 'an unmarked WebView2 process is NOT claimed by the lane' `
        (@($seen | Where-Object { $_.ProcessId -eq $fx3.Id }).Count -eq 0) "found $($seen.Count)"
    Stop-Fixture $fx3

    # -- 4: nothing to wait for costs nothing, which is the normal case on every
    # lane boundary and the reason this can be unconditional. The fixtures above
    # are down, and arm 3's unmarked one has to be too -- the profile marker is
    # matched whatever exe names are passed, by design: it is what the browser's
    # own crashpad handler carries INSTEAD of the embedder name.
    $fast = Wait-WebViewLaneSettle -ExeNames @($FakeExe) -TimeoutSeconds 5
    Check 'a settle with nothing to wait for returns settled and immediate' `
        ($fast.Settled -and $fast.WaitedMs -lt 400) "settled=$($fast.Settled) waited=$($fast.WaitedMs)ms"

    # -- 5: it actually WAITS. The fixture dies on its own a moment from now;
    # a settle that returned on the Stop-Process (the old shape) would come back
    # before that and report zero wait.
    $fx4 = Start-Fixture -Marker 'ghoztty-wv2test-888888'
    $killer = Start-Job -ScriptBlock {
        param($TargetPid)
        Start-Sleep -Milliseconds 1500
        Start-Process -FilePath 'taskkill.exe' -ArgumentList '/T', '/F', '/PID', $TargetPid -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    } -ArgumentList $fx4.Id
    $slow = Wait-WebViewLaneSettle -ExeNames @($FakeExe) -TimeoutSeconds 30
    Receive-Job $killer -Wait -AutoRemoveJob -ErrorAction SilentlyContinue | Out-Null
    Check 'a settle blocks until the browser process is really gone' `
        ($slow.Settled -and $slow.WaitedMs -ge 1000) "settled=$($slow.Settled) waited=$($slow.WaitedMs)ms"

    # -- 6: the give-up. A wait that runs out must RETURN, not throw and not
    # hang: a lane that refuses to start is worse than one that starts noisy.
    $fx5 = Start-Fixture -Marker 'ghoztty-wv2test-777777'
    $giveUp = Wait-WebViewLaneSettle -ExeNames @($FakeExe) -TimeoutSeconds 1
    Check 'a settle that runs out reports unsettled with a count' `
        ((-not $giveUp.Settled) -and $giveUp.Remaining -ge 1) `
        "settled=$($giveUp.Settled) remaining=$($giveUp.Remaining)"

    # -- 7: the wording. Silence is the normal case and has to stay silent, or
    # the line that matters drowns in the ones that do not.
    Check 'an instant settle prints nothing at all' `
        ((Format-WebViewSettle -Settle $fast) -eq '') (Format-WebViewSettle -Settle $fast)
    $slowLine = Format-WebViewSettle -Settle $slow -Lane 'agent'
    Check 'a real wait is reported with the lane and the duration' `
        ($slowLine -match 'LANE agent' -and $slowLine -match 'waited \d+ms') $slowLine
    $badLine = Format-WebViewSettle -Settle $giveUp -Lane 'win32'
    Check 'a give-up names T592 so the next red lane can be read against it' `
        ($badLine -match 'NOT SETTLED' -and $badLine -match 'T592') $badLine

    # -- 8: the sweep kills AND waits. fx5 is still up from arm 6.
    $swept = Invoke-WebViewLaneSweep -ExeNames @($FakeExe) -TimeoutSeconds 30
    Check 'the sweep reports what it killed' ($swept.Killed -ge 1) "killed=$($swept.Killed)"
    Check 'the sweep does not return until they are gone' `
        ($swept.Settled -and $swept.Remaining -eq 0) `
        "settled=$($swept.Settled) remaining=$($swept.Remaining)"
    Check 'the swept processes really are gone' `
        (@(Get-WebViewLaneHost -ExeNames @($FakeExe)).Count -eq 0)

    # -- 9: the profile prune. A live owner's profile is never touched, which is
    # what keeps a concurrent run's browser from being pulled out from under it.
    $profRoot = Join-Path $Sandbox 'profiles'
    New-Item -ItemType Directory -Path $profRoot -Force | Out-Null
    $deadDir = Join-Path $profRoot 'ghoztty-wv2test-999999'
    $liveDir = Join-Path $profRoot "ghoztty-wv2test-$PID"
    New-Item -ItemType Directory -Path $deadDir -Force | Out-Null
    New-Item -ItemType Directory -Path $liveDir -Force | Out-Null
    $removed = Remove-WebViewLaneProfile -Root $profRoot
    Check 'the profile of a dead test binary is removed' `
        ((-not (Test-Path $deadDir)) -and $removed -ge 1) "removed=$removed"
    Check 'the profile of a LIVE test binary is left alone' (Test-Path $liveDir)

    # -- 10-11: the wiring in floor-lane.ps1
    $floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'
    $src = Get-Content -LiteralPath $floor -Raw
    Check 'floor-lane dot-sources the library' ($src -match 'lib.WebViewLane\.ps1')
    Check 'a lane settles BEFORE it starts, not only after it ends' `
        ($src -match 'Wait-WebViewLaneSettle -ExeNames \$TEST_EXE_NAMES') $null
    Check 'the end-of-lane sweep goes through the waiting version' `
        ($src -match 'Invoke-WebViewLaneSweep -ExeNames \$TEST_EXE_NAMES') $null
    # The settle must not be able to become a silent one: the give-up line is
    # the only thing that explains a red lane behind it.
    Check 'the lane prints whatever the settle had to say' `
        ($src -match 'Format-WebViewSettle -Settle \$settle') $null

    # -- 12: end to end. A lane run with a marked process up, killed while the
    # lane is waiting, must actually report the wait.
    $fx6 = Start-Fixture -Marker 'ghoztty-wv2test-666666'
    $killer2 = Start-Job -ScriptBlock {
        param($TargetPid)
        Start-Sleep -Milliseconds 2000
        Start-Process -FilePath 'taskkill.exe' -ArgumentList '/T', '/F', '/PID', $TargetPid -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    } -ArgumentList $fx6.Id
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor `
        -Command 'cmd /c exit 0' -MinFreeGB 0 -MinCommitFreeGB 0 `
        -ExtraTestExeNames $FakeExe -WebViewSettleSeconds 30 -SampleSeconds 1 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Receive-Job $killer2 -Wait -AutoRemoveJob -ErrorAction SilentlyContinue | Out-Null
    Check 'a real lane run waits for the marked process and says so' `
        ($out -match 'waited \d+ms for the previous lane') $out
    Check 'and the lane still reaches its verdict' ($out -match 'LANE command ') $out

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    foreach ($p in $Started) { try { Stop-Fixture $p } catch {} }
    # A fixture the SWEEP killed took only its shell; the blocked `waitfor`
    # under it is orphaned and would sit on the box for ten minutes. It is
    # named after this harness, so nothing else can be caught by this.
    foreach ($w in @(Get-CimInstance Win32_Process -Filter "Name='waitfor.exe'" -ErrorAction SilentlyContinue)) {
        if ($w.CommandLine -and $w.CommandLine -like '*GhozttyWv2SettleFixture*') {
            try { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard webview-settle -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
