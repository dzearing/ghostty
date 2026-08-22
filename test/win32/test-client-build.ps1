# remote-test-client on-demand build acceptance (tracker T359): the acceptance
# scripts that drive a real agent produce their own client binary, so a tree
# that has only ever run `zig build -Dapp-runtime=win32` still runs them.
#
# THE PROBLEM THIS COVERS
#
# `remote-test-client` is an on-demand build target - `build.zig` gives it its
# own `zig build remote-test-client` step and nothing the default install step
# builds reaches it. Six acceptance scripts need it (it is the only thing here
# that speaks the agent protocol without a GUI) and every one of them opened by
# asserting the file exists. On a clean tree that reads as `FAIL
# remote-test-client exists`, which looks like the agent failed to build rather
# than "this binary was never asked for" - and two of the six exit 1 on the
# spot, so their remaining assertions never run.
#
# lib\TestClient.ps1 is the fix: resolve, and build it if it is missing.
#
#   powershell -NoProfile -File test\win32\test-client-build.ps1
#
# Sections: A the helper's contract, B the fast path never shells out to zig,
# C -NoBuild reports instead of building, D the real repair (the client is
# deleted and the helper puts it back), E every consumer is wired to it.
#
# Hermetic: launches no ghoztty and no agent, and the only file it touches
# outside its temp dir is zig-out\bin\remote-test-client.exe - which section D
# moves aside and restores if the rebuild fails.
param(
    [switch]$SkipBuild   # sections A/B/C/E only (no zig shell-out)
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tmp = Join-Path $env:TEMP "ghoztty-t359-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

$lib = Join-Path $PSScriptRoot 'lib\TestClient.ps1'
$clientExe = Join-Path $repo 'zig-out\bin\remote-test-client.exe'

# --- A: the helper's contract ----------------------------------------------
Write-Host ''
Write-Host 'A. lib\TestClient.ps1 exists and exports the resolve/build contract'

Assert 'A1 lib\TestClient.ps1 exists' (Test-Path $lib)
if (-not (Test-Path $lib)) {
    Complete-TestBody
    Write-TestVerdict -Pass $script:passes -Fail $script:failures
    return
}
. $lib

Assert 'A2 Resolve-RemoteTestClient is defined' ($null -ne (Get-Command Resolve-RemoteTestClient -ErrorAction SilentlyContinue))
Assert 'A3 Get-RemoteTestClientBuildCommand is defined' ($null -ne (Get-Command Get-RemoteTestClientBuildCommand -ErrorAction SilentlyContinue))

# The command a human would type, quoted verbatim by every message about a
# missing client: a precondition that cannot be acted on is half a message.
$cmd = Get-RemoteTestClientBuildCommand
Assert "A4 build command is the exact step ($cmd)" ($cmd -eq 'zig build remote-test-client -Doptimize=Debug')

# --- B: the fast path -------------------------------------------------------
Write-Host ''
Write-Host 'B. an existing client is returned as-is (no zig shell-out)'

# A stand-in file, not the real client: if the fast path ever stops short-
# circuiting, zig would be asked to build - and here that would take seconds
# and still not produce THIS path, so the assertion below would fail rather
# than quietly pass on a slow run.
$fake = Join-Path $tmp 'stand-in-client.exe'
Set-Content -LiteralPath $fake -Value 'not a real client' -Encoding ascii
$sw = [Diagnostics.Stopwatch]::StartNew()
$resolved = Resolve-RemoteTestClient -ClientExe $fake
$sw.Stop()
Assert 'B1 an existing -ClientExe is returned unchanged' ($resolved -eq $fake)
Assert "B2 it answered without building ($($sw.ElapsedMilliseconds) ms)" ($sw.ElapsedMilliseconds -lt 2000)

# --- C: -NoBuild reports rather than builds ---------------------------------
Write-Host ''
Write-Host 'C. -NoBuild answers empty instead of shelling out'

# $tmp is a repo with no zig-out at all, so BOTH candidates are missing.
$missing = Join-Path $tmp 'nope\remote-test-client.exe'
$sw = [Diagnostics.Stopwatch]::StartNew()
$noBuild = Resolve-RemoteTestClient -ClientExe $missing -Repo $tmp -NoBuild
$sw.Stop()
Assert 'C1 -NoBuild returns empty when the client is missing' ([string]::IsNullOrEmpty($noBuild))
Assert "C2 -NoBuild did not build ($($sw.ElapsedMilliseconds) ms)" ($sw.ElapsedMilliseconds -lt 2000)

# --- D: the real repair -----------------------------------------------------
Write-Host ''
Write-Host 'D. a deleted client is rebuilt by the helper (the T359 symptom)'

if ($SkipBuild) {
    Write-Host '  (skipped by -SkipBuild)'
} else {
    $backup = Join-Path $tmp 'remote-test-client.exe.bak'
    $had = Test-Path -LiteralPath $clientExe
    if ($had) { Move-Item -LiteralPath $clientExe -Destination $backup -Force }

    Assert 'D1 the client is gone before the helper runs' (-not (Test-Path -LiteralPath $clientExe))

    $built = Resolve-RemoteTestClient
    Assert 'D2 the helper answered with a path' (-not [string]::IsNullOrEmpty($built))
    Assert 'D3 the client is back on disk' ($built -and (Test-Path -LiteralPath $built))
    Assert 'D4 it is the zig-out client' ($built -eq $clientExe)

    # A real PE, not a zero-byte artifact of a half-finished build.
    $isPe = $false
    if ($built -and (Test-Path -LiteralPath $built)) {
        $head = Get-Content -LiteralPath $built -Encoding Byte -TotalCount 2 -ErrorAction SilentlyContinue
        $isPe = ($head.Count -eq 2 -and $head[0] -eq 0x4D -and $head[1] -eq 0x5A)
    }
    Assert 'D5 the rebuilt client is a PE image' $isPe

    # Only restore when the rebuild failed - a successful one IS the client now.
    if (-not (Test-Path -LiteralPath $clientExe) -and (Test-Path -LiteralPath $backup)) {
        Move-Item -LiteralPath $backup -Destination $clientExe -Force
        Write-Host '  (rebuild failed; the previous client was restored)'
    }
}

# --- E: every consumer is wired to the helper -------------------------------
Write-Host ''
Write-Host 'E. every script that needs the client resolves it through the helper'

# The discriminator is the zig-out PATH, not the image name: cleanslate-audit
# and lib\FakeAgentRelay mention `remote-test-client.exe` as a process name and
# in prose, and neither one launches it.
$consumers = Get-ChildItem (Join-Path $PSScriptRoot '*.ps1') -File |
    Where-Object { $_.Name -ne 'test-client-build.ps1' } |
    Where-Object { (Get-Content $_.FullName -Raw) -match 'zig-out\\bin\\remote-test-client\.exe' }

Assert "E1 found the client's consumers ($($consumers.Count))" ($consumers.Count -ge 6)
foreach ($c in $consumers) {
    $text = Get-Content $c.FullName -Raw
    $wired = ($text -match "lib\\TestClient\.ps1") -and ($text -match 'Resolve-RemoteTestClient')
    Assert "E2 $($c.Name) resolves through lib\TestClient.ps1" $wired
}

# The shape this replaced: a bare existence assert with no way to act on it.
$stale = $consumers | Where-Object {
    (Get-Content $_.FullName -Raw) -match 'remote-test-client exists'
}
Assert 'E3 no consumer still asserts bare existence' ($stale.Count -eq 0)
foreach ($s in $stale) { Write-Host "    stale precondition in $($s.Name)" }

# --- cleanup ----------------------------------------------------------------
Write-Host ''
Write-Host '== cleanup'
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# --- stamp (T783) -----------------------------------------------------------
# A green run records this harness's own content so scripts\guard-due.ps1 can
# answer "has anyone run test-client-build against the code as it now stands?".
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $SkipBuild) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard test-client -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:passes -Fail $script:failures
