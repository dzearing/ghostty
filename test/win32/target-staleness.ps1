# T248 acceptance: a reused `--target` name must not silently probe a pane
# left over from a PREVIOUS run.
#
#   powershell -NoProfile -File test\win32\target-staleness.ps1
#
# `+new-window --target=<name>` is idempotent by design (an existing target is
# FOCUSED, not recreated), session persistence is on by default, and the agent
# outlives the app. So from the second run onward an acceptance script that
# reuses a target name can focus last run's pane - fixture never executed,
# oracle reading last run's screen, every assertion green.
#
# This script is the executable form of that claim. It runs one fixture twice
# under two different hygienes and asserts the two disagree:
#
#   POSITIVE CONTROL - kill the app only (the old hygiene) and re-issue the
#     same target with a DIFFERENT fixture. The stale pane comes back and the
#     new fixture never runs. If this stops reproducing, the test has stopped
#     testing anything and says so rather than passing quietly.
#
#   THE FIX - Reset-GhozttyTestState (kill app + agent, drop the debug restore
#     manifest) and re-issue the same target again. Now the new fixture runs.
#
# It also asserts the aim check that would have caught the whole class in one
# line: the app answering our IPC must BE the exe under test.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-t248-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: a per-run IPC endpoint on top of CleanSlate's T118 unbaking. This script
# is ABOUT stale targets, and every debug script sharing one derived `-debug`
# endpoint is the largest source of them.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'tstale')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Target and pane names are run-unique so a leftover from an interrupted run
# can never be mistaken for this run's fixture - the third part of the T248
# fix, applied to the script that documents it.
$target = "t248w$PID"

function Find-Leaf($node) {
    if (-not $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    $l = Find-Leaf $node.left
    if ($l) { return $l }
    return Find-Leaf $node.right
}

# The window's own pane has no registered name of its own (`--name` on
# +new-window names a SPLIT), so resolve it through +list, which auto-registers
# every pane it discovers under its stable pane id.
function Get-TargetPaneId {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    $raw = if (Test-Path "$tmp\list.json") { Get-Content "$tmp\list.json" -Raw } else { '' }
    if ($raw -notmatch '"success":true') { return $null }
    $doc = $raw | ConvertFrom-Json
    foreach ($w in $doc.data.windows) {
        if ($w.target -ne $target) { continue }
        foreach ($t in $w.tabs) {
            $leaf = Find-Leaf $t.splits
            if ($leaf) { return $leaf.id }
        }
    }
    return $null
}

function Read-Pane {
    $id = Get-TargetPaneId
    if (-not $id) { return '<no pane for target>' }
    cmd /c "`"$Exe`" +read --name=$id --lines=40 > `"$tmp\read.txt`" 2>&1" | Out-Null
    if (Test-Path "$tmp\read.txt") { Get-Content "$tmp\read.txt" -Raw } else { '' }
}

function New-Fixture($marker) {
    # `cmd /K echo <marker>` leaves the marker on screen and the shell alive,
    # so the pane is a persistable session for the agent to hold onto.
    & $Exe +new-window --target=$target -e cmd /K echo $marker 2>&1 | Out-Null
    $code = $LASTEXITCODE
    Start-Sleep -Seconds 5
    return $code
}

try {
    "== 0: clean slate, then run fixture A"
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1500 | Out-Null
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    Assert "fixture A launched" ((New-Fixture 'T248-MARKER-A') -eq 0)
    Assert "driving the build under test" ((Assert-GhozttyUnderTest -Exe $Exe) -eq $Exe)
    Assert-GhozttyIsolated -Exe $Exe
    $a = Read-Pane
    Assert "pane shows marker A" ($a -match 'T248-MARKER-A')

    "== 1: POSITIVE CONTROL - app-only kill leaves the pane restorable"
    Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 2000 | Out-Null
    Assert "fixture B launched against the same target" ((New-Fixture 'T248-MARKER-B') -eq 0)
    $b = Read-Pane
    $stale = ($b -match 'T248-MARKER-A') -and ($b -notmatch 'T248-MARKER-B')
    # Not a FAIL when it does not reproduce - it is the premise of the test,
    # and a premise that has quietly stopped holding must be visible rather
    # than dressed up as a pass (a green-and-empty probe is the failure mode
    # T205 named).
    if ($stale) {
        "  CONTROL ok: stale pane came back, fixture B never ran"
    } else {
        "  CONTROL NOT REPRODUCED: app-only kill no longer resurrects the pane."
        "  The fix below is then untestable here - investigate before trusting a PASS."
        $script:failures++
    }

    "== 2: THE FIX - full reset makes the same target run the new fixture"
    Reset-GhozttyTestState -Exe $Exe -SettleMs 2000 | Out-Null
    Assert "fixture C launched" ((New-Fixture 'T248-MARKER-C') -eq 0)
    $c = Read-Pane
    Assert "pane shows marker C" ($c -match 'T248-MARKER-C')
    Assert "pane does NOT show marker A" ($c -notmatch 'T248-MARKER-A')
    Assert "pane does NOT show marker B" ($c -notmatch 'T248-MARKER-B')

    "== 3: the guards fire (the app from step 2 is still up)"
    # (a) mismatch: an app IS answering, but it is not the exe we claim to be
    #     testing. This is the shape of the real defect - a zig-out holding a
    #     RELEASE build shares the endpoint with the user's installed Ghoztty,
    #     so `+list` answers from an install nobody here built (observed for
    #     real 2026-08-02, before this script existed).
    Assert-GhozttyUnderTest -Exe $Exe | Out-Null   # precondition: ours is up
    $caught = $false
    try { Assert-GhozttyUnderTest -Exe (Join-Path (Split-Path $Exe) 'not-the-build-under-test.exe') | Out-Null }
    catch { $caught = $true }
    Assert "aim check rejects a server that is not the exe under test" $caught

    # (b) a path outside the repo is never killable, however it got here.
    $guarded = $false
    try { Stop-RepoGhoztty -Exe (Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty\ghoztty.exe') -SettleMs 0 | Out-Null }
    catch { $guarded = $true }
    Assert "Stop-RepoGhoztty refuses an installed exe" $guarded

    "== 4: after a reset the manifest is gone, so a cold launch restores nothing"
    $manifest = Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json'
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1200 | Out-Null
    Assert "debug session-layout manifest removed" (-not (Test-Path $manifest))
} finally {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

""
if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }
