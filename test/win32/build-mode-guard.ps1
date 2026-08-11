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
"== D: the opt-in is an explicit act, not an env that happens to be set"
# ============================================================================
Assert "D1 -Allow lets a release build through" `
    ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast -Allow }))

$env:GHOZTTY_TEST_ALLOW_RELEASE = '1'
Assert "D2 GHOZTTY_TEST_ALLOW_RELEASE=1 does the same" `
    ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast }))
Remove-Item Env:GHOZTTY_TEST_ALLOW_RELEASE -ErrorAction SilentlyContinue
Assert "D3 and clearing it restores the refusal" `
    ($null -ne (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast }))

# A private suffix is NOT an opt-in: the agent pipe is build-mode derived with
# no env override, so a suffixed release run still dials the user's agent.
$savedSuffix = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-bmguard$PID"
Assert "D4 a private pipe suffix is not accepted as one" `
    ($null -ne (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $stubFast }))

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
$msgAllow = Get-Throw { Reset-GhozttyTestState -Exe $stubFast -SettleMs 0 -AllowReleaseBuild }
Assert "E3 -AllowReleaseBuild passes through to it" ($msgAllow -notmatch 'REFUSING TO RUN')
Assert "E3b and the run continues to the next pre-flight" ($msgAllow -match 'not under the repo')

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
$claudeMd = Get-Content -LiteralPath (Join-Path $Repo 'CLAUDE.md') -Raw
$goMd = Get-Content -LiteralPath (Join-Path $Repo 'go.md') -Raw
Assert "G1 CLAUDE.md says Debug is about endpoint isolation" ($claudeMd -match 'endpoint isolation')
Assert "G2 CLAUDE.md points at this script" ($claudeMd -match 'build-mode-guard\.ps1')
Assert "G3 go.md carries the same warning" ($goMd -match 'endpoint isolation')

""
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" } else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
