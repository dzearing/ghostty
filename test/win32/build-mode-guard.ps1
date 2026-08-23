# build-mode-guard acceptance (T350): an acceptance run refuses, BEFORE it
# launches or types anything, to drive a build whose endpoints belong to the
# user's installed Ghoztty.
#
#   powershell -NoProfile -File test\win32\build-mode-guard.ps1
#
# Non-interactive and launches nothing: the subject is the gate itself, so the
# release-build cases are played by a stub exe that prints a `+version` banner.
# That is deliberate - the alternative is a ten-minute ReleaseFast build whose
# only contribution is one line of text, and a stub can also play the exe this
# gate must refuse for OTHER reasons (a mode it cannot read at all).
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tmp = Join-Path $env:TEMP "ghoztty-buildmode-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run a scriptblock and return the exception message it threw, or $null.
function Get-Throw($block) {
    try { & $block | Out-Null; return $null } catch { return "$($_.Exception.Message)" }
}

# A stub that answers `+version` the way the real exe does. $Mode = '' prints no
# build-mode line at all (an exe too old to have one, or one that fails).
function New-StubExe($name, $Mode) {
    $path = Join-Path $tmp "$name.cmd"
    $lines = @('@echo off', 'echo Ghostty 1.4.0-stub', 'echo Build Config', 'echo   - Zig version   : 0.15.2')
    if ($Mode) { $lines += "echo   - build mode    : .$Mode" }
    # The Running Instance section carries its own '- mode' line; every stub
    # prints one, so a match that is not anchored on 'build mode' fails here.
    $lines += @('echo   - app runtime   : .win32', 'echo Running Instance', 'echo   - mode    : Debug')
    Set-Content -LiteralPath $path -Value $lines -Encoding ascii
    return $path
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')

# ============================================================================
"== A: the predicate mirrors build_config.is_debug"
# ============================================================================
# Debug and ReleaseSafe derive the -debug endpoints; the other two derive the
# user's. An unreadable mode counts as NOT isolated - refusing a run we cannot
# vouch for is the safe direction.
Assert "A1 Debug is isolated"        (Test-GhozttyIsolatedBuildMode -Mode 'Debug')
Assert "A2 ReleaseSafe is isolated"  (Test-GhozttyIsolatedBuildMode -Mode 'ReleaseSafe')
Assert "A3 ReleaseFast is not"  (-not (Test-GhozttyIsolatedBuildMode -Mode 'ReleaseFast'))
Assert "A4 ReleaseSmall is not" (-not (Test-GhozttyIsolatedBuildMode -Mode 'ReleaseSmall'))
Assert "A5 zig's leading dot is tolerated" (Test-GhozttyIsolatedBuildMode -Mode '.Debug')
Assert "A6 unknown mode is not isolated" (-not (Test-GhozttyIsolatedBuildMode -Mode 'Whatever'))
Assert "A7 absent mode is not isolated"  (-not (Test-GhozttyIsolatedBuildMode -Mode $null))

# ============================================================================
"== B: the mode is read from the exe itself, with no server running"
# ============================================================================
$stubFast  = New-StubExe 'stub-fast'  'ReleaseFast'
$stubDebug = New-StubExe 'stub-debug' 'Debug'
$stubMute  = New-StubExe 'stub-mute'  ''

Assert "B1 reads ReleaseFast" ((Get-GhozttyBuildMode -Exe $stubFast) -eq 'ReleaseFast')
Assert "B2 reads Debug, not the Running Instance line" ((Get-GhozttyBuildMode -Exe $stubDebug) -eq 'Debug')
Assert "B3 no build-mode line reads as null" ($null -eq (Get-GhozttyBuildMode -Exe $stubMute))
Assert "B4 a missing exe reads as null, it does not blow up" `
    ($null -eq (Get-GhozttyBuildMode -Exe (Join-Path $tmp 'no-such-exe.cmd')))

# ============================================================================
"== C: the assert refuses a shared-endpoint build, and says why"
# ============================================================================
$msg = Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast }
Assert "C1 a ReleaseFast exe throws" ($null -ne $msg)
Assert "C2 the message names the mode it found" ($msg -match 'ReleaseFast')
Assert "C3 and the exe it was handed" ($msg -match [regex]::Escape($stubFast))
Assert "C4 and gives the rebuild command" ($msg -match '-Doptimize=Debug')
Assert "C5 and says a pipe suffix does not fix it" ($msg -match 'GHOZTTY_PIPE_SUFFIX does not fix')
Assert "C6 and names the opt-in for a deliberate release run" ($msg -match 'GHOZTTY_TEST_ALLOW_RELEASE')

Assert "C7 a Debug exe passes and returns its mode" `
    ((Assert-GhozttyIsolatedBuild -Exe $stubDebug) -eq 'Debug')
Assert "C8 an unreadable exe is refused too" `
    ($null -ne (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubMute }))

# ============================================================================
"== D: the opt-in is an explicit act, and since T1158 a CHECKED one"
# ============================================================================
# The whole of section D changed shape with T1158. `-Allow` used to return
# unconditionally - it took the caller's word that a release-lineage run was
# safe - and that unchecked return is what let soak.ps1 seed the user's agent
# with pinned sessions for weeks. The opt-in now says "I know this is a release
# build" AND has to show the isolation, or declare that reaching the user's
# endpoints is the point.
$savedSuffix = $env:GHOZTTY_PIPE_SUFFIX
$savedInst = $env:GHOZTTY_AGENT_INSTANCE
$savedLad = $env:LOCALAPPDATA
$realLad = [Environment]::GetFolderPath('LocalApplicationData')

# Every knob off: the state the soak was in for weeks, minus even the suffix.
Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = $realLad

$msgD1 = Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow }
Assert "D1 -Allow alone no longer lets an UNISOLATED release build through" ($null -ne $msgD1)
Assert "D1b and it names all three missing knobs" `
    (($msgD1 -match 'GHOZTTY_PIPE_SUFFIX') -and ($msgD1 -match 'GHOZTTY_AGENT_INSTANCE') -and ($msgD1 -match 'LOCALAPPDATA'))
Assert "D1c and it says which defect it is preventing" ($msgD1 -match 'T1158')

$env:GHOZTTY_TEST_ALLOW_RELEASE = '1'
Assert "D2 GHOZTTY_TEST_ALLOW_RELEASE=1 is held to the same bar" `
    ($null -ne (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast }))
Remove-Item Env:GHOZTTY_TEST_ALLOW_RELEASE -ErrorAction SilentlyContinue
Assert "D3 and with no opt-in at all it refuses for the original reason" `
    ((Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast }) -match 'does NOT use the -debug endpoints')

# The knobs, added ONE AT A TIME. Each is still the dangerous partial state, and
# the gate must name exactly what is still missing rather than round up to
# "fine".
$env:GHOZTTY_PIPE_SUFFIX = "-bmguard$PID"
$msgD4 = Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow }
Assert "D4 a private pipe suffix alone is not accepted as isolation" ($null -ne $msgD4)
Assert "D4b and the suffix is no longer listed as missing" ($msgD4 -notmatch 'GHOZTTY_PIPE_SUFFIX is unset')
Assert "D4c while the agent knob still is - this is the soak's exact state" `
    ($msgD4 -match 'GHOZTTY_AGENT_INSTANCE is unset')

$env:GHOZTTY_AGENT_INSTANCE = "bmguard$PID"
$msgD5 = Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow }
Assert "D5 two of the three is still refused" ($null -ne $msgD5)
Assert "D5b and the one it names is the file half" ($msgD5 -match 'LOCALAPPDATA is still the user')

$env:LOCALAPPDATA = Join-Path $tmp 'sandbox-lad'
Assert "D6 all three knobs plus -Allow is accepted" `
    ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow }))
Assert "D6b and it returns the mode it read" `
    ((Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow) -eq 'ReleaseFast')

# The declared opt-out, for a script whose SUBJECT is the user's installed build
# (an upgrade or delivery test). It must carry a reason: an unexplained opt-out
# is precisely the state T1158 was.
$env:LOCALAPPDATA = $realLad
Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
Assert "D7 -UserEndpoints without -Reason is refused" `
    ($null -ne (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow -UserEndpoints }))
Assert "D7b -UserEndpoints with a reason is accepted" `
    ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow -UserEndpoints -Reason 'delivery test' }))

# A DEBUG build under -Allow needs none of this: its endpoints are already not
# the user's, which is the only question the gate asks.
Assert "D8 a Debug exe under -Allow passes with no knobs at all" `
    ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubDebug -Allow }))

# --- Get-GhozttyReleaseSandboxGaps, asked directly ---------------------------
Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
Assert "D9 gaps names all three when nothing is set" `
    ((Get-GhozttyReleaseSandboxGaps).Count -eq 3)
$env:GHOZTTY_PIPE_SUFFIX = "-bmguard$PID"
$env:GHOZTTY_AGENT_INSTANCE = "bmguard$PID"
$env:LOCALAPPDATA = Join-Path $tmp 'sandbox-lad'
Assert "D9b and none when all three are" ((Get-GhozttyReleaseSandboxGaps).Count -eq 0)
$env:LOCALAPPDATA = $realLad + '\'
Assert "D9c a trailing separator does not read as a different directory" `
    (((Get-GhozttyReleaseSandboxGaps) -join '|') -match 'LOCALAPPDATA is still the user')

# --- Set-GhozttyTestIsolation -ReleaseSandbox closes all three in one call ----
Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = $realLad
[void](Set-GhozttyTestIsolation -Tag 'bmguard' -ReleaseSandbox -Quiet -SandboxRoot (Join-Path $tmp 'iso-sandbox'))
Assert "D10 -ReleaseSandbox closes every gap in one call" ((Get-GhozttyReleaseSandboxGaps).Count -eq 0)
Assert "D10b the agent lineage stays inside agent_lineage.max_len (24)" `
    ($env:GHOZTTY_AGENT_INSTANCE.Length -le 24)
Assert "D10c and it is run-unique, so two runs never share a lineage" `
    ($env:GHOZTTY_AGENT_INSTANCE -match "$PID`$")
[void](Set-GhozttyTestIsolation -Tag 'a-very-long-harness-name-indeed' -ReleaseSandbox -Quiet `
    -SandboxRoot (Join-Path $tmp 'iso-sandbox2'))
Assert "D10d an over-long tag is trimmed rather than pushed past the cap" `
    ($env:GHOZTTY_AGENT_INSTANCE.Length -le 24 -and $env:GHOZTTY_AGENT_INSTANCE -match "$PID`$")

# Hand section E the partial state it is written against: a release exe with a
# private suffix and nothing else, which is what -AllowReleaseBuild has to be
# able to opt out of.
if ($null -eq $savedInst) { Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
else { $env:GHOZTTY_AGENT_INSTANCE = $savedInst }
$env:LOCALAPPDATA = $savedLad
$env:GHOZTTY_PIPE_SUFFIX = "-bmguard$PID"

# ============================================================================
"== E: the gate is wired into the paths a script actually calls"
# ============================================================================
# Reset-GhozttyTestState is the first thing an acceptance script runs, and
# Assert-GhozttyPrivateEndpoint is the first thing an isolated one runs. Both
# must refuse before a window is opened - so both are checked with a stub that
# does not even live under the repo: the throw has to come from the build-mode
# gate, ahead of every other pre-flight.
$msgReset = Get-Throw { Reset-GhozttyTestState -Exe $stubFast -SettleMs 0 }
Assert "E1 Reset-GhozttyTestState refuses a release exe" ($null -ne $msgReset)
Assert "E2 and it is the build-mode gate that speaks first" ($msgReset -match 'REFUSING TO RUN')
# -AllowReleaseBuild must reach the gate. The stub still dies afterwards - it
# does not live under the repo, and Stop-RepoGhoztty refuses that outright - so
# the evidence is WHICH pre-flight speaks: the next one, not this one.
#
# T1158: what reaches the gate is now HELD to something, so the pass-through has
# to be shown from a sandboxed state. Section D left the partial one behind on
# purpose, and E3z below is the half that matters most - the wrapper cannot be
# used to smuggle an unisolated release run past the tightened gate.
$msgPartial = Get-Throw { Reset-GhozttyTestState -Exe $stubFast -SettleMs 0 -AllowReleaseBuild }
Assert "E3z -AllowReleaseBuild does NOT excuse a partly-isolated release run" `
    ($msgPartial -match 'REFUSING TO RUN')
Assert "E3y and the wrapper's refusal names the knob that is missing" `
    ($msgPartial -match 'GHOZTTY_AGENT_INSTANCE is unset')

$savedEInst = $env:GHOZTTY_AGENT_INSTANCE
$savedELad = $env:LOCALAPPDATA
$env:GHOZTTY_AGENT_INSTANCE = "bmguardE$PID"
$env:LOCALAPPDATA = Join-Path $tmp 'sandbox-lad-e'
$msgAllow = Get-Throw { Reset-GhozttyTestState -Exe $stubFast -SettleMs 0 -AllowReleaseBuild }
Assert "E3 -AllowReleaseBuild passes through to it once the run is isolated" ($msgAllow -notmatch 'REFUSING TO RUN')
Assert "E3b and the run continues to the next pre-flight" ($msgAllow -match 'not under the repo')
if ($null -eq $savedEInst) { Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
else { $env:GHOZTTY_AGENT_INSTANCE = $savedEInst }
$env:LOCALAPPDATA = $savedELad

$msgIso = Get-Throw { Assert-GhozttyPrivateEndpoint -Exe $stubFast }
Assert "E4 Assert-GhozttyPrivateEndpoint refuses a release exe" ($null -ne $msgIso)
Assert "E5 and it is the same gate" ($msgIso -match 'REFUSING TO RUN')

if ($savedSuffix) { $env:GHOZTTY_PIPE_SUFFIX = $savedSuffix }
else { Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }

# ============================================================================
"== F: positive control - the real build under test is unaffected"
# ============================================================================
# Without this the whole file could pass while the gate rejects everything.
if (Test-Path $Exe) {
    $realMode = Get-GhozttyBuildMode -Exe $Exe
    Assert "F1 zig-out reports a build mode" ($null -ne $realMode)
    Assert "F2 and it is the isolated kind ($realMode)" (Test-GhozttyIsolatedBuildMode -Mode $realMode)
    Assert "F3 so the gate lets it through" `
        ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $Exe }))
} else {
    "  SKIP F: $Exe not built"
    $script:skipped++
}

# ============================================================================
"== G: the reason -Doptimize=Debug is not optional is written down"
# ============================================================================
# The trap is reachable by anyone who builds without that flag, so the note
# belongs next to the build command, not only in the guard that catches it.
$buildDoc = Get-Content -LiteralPath (Join-Path $Repo 'docs\claude\build.md') -Raw
$goMd = Get-Content -LiteralPath (Join-Path $Repo 'go.md') -Raw
Assert "G1 docs/claude/build.md says Debug is about endpoint isolation" ($buildDoc -match 'endpoint isolation')
Assert "G2 docs/claude/build.md points at this script" ($buildDoc -match 'build-mode-guard\.ps1')
Assert "G3 go.md carries the same warning" ($goMd -match 'endpoint isolation')

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this gate been run against the code as it now stands?". Added with
# T1158, whose defect lived in the file this script grades and which nothing was
# obliged to notice.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard build-mode -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" } else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
