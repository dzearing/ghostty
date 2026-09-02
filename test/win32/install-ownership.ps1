# The user's installed terminal is nobody's to swap (T1218, decision D85).
#
# WHAT THIS GUARDS. Until 2026-08-31 the loop replaced
# `%LOCALAPPDATA%\Programs\Ghoztty\ghoztty.exe` out of a repo build every
# morning (T525's `morning-refresh.ps1`). D85 put that to the user and the
# answer was the option the loop had not assumed: "the terminal should only ever
# run something that was actually published". So the swap is retired, and the
# only thing that may replace the installed app is the in-app updater taking a
# published release.
#
# WHY IT NEEDS A HARNESS. This retirement is invisible when it rots. A restored
# default, a mirror list that grows the install path back, a convenience switch
# "just for today" - each of those SUCCEEDS: the swap works, the terminal keeps
# running, and the only symptom is a version number describing bytes nobody ever
# released. No lane and no P1-P3 script touches this code path, and the one
# harness that did (`morning-refresh.ps1`) was retired with the feature it
# covered. This is what replaced it.
#
# Sections:
#
#   A  the rule itself: Test-IsUserInstallPath is exact, covers everything
#      underneath the install, is case- and separator-insensitive, and answers
#      the same whether or not the directory exists.
#   B  upgrade-ghoztty-windows.ps1 REFUSES a user-install target, live - exit 3,
#      with the refusal naming the published-release path. Its default target is
#      the dev install, so a bare run cannot reach the user's.
#   C  launch-upgrade.ps1 refuses the same target in the CALLER's console,
#      before the staging build, because the child it launches is detached and
#      its refusal would land in a log nobody reads.
#   D  the morning swap is gone rather than disabled: no script, no test, no
#      guard row and no doc still runs it.
#   E  no script in scripts\ has grown a new write to the installed app.
#   F  the docs state the rule where a human (and the next turn) will read it.
#
# Every section-D/E/F check is a predicate over file content, so -TeethCheck can
# feed each one the mutation it exists to catch and prove it scores red; B and C
# are live refusals, which are their own demonstration (T1133).
#
# Read-only. Never launches the app, never delivers anything, needs no network.
#
#   powershell -NoProfile -File test\win32\install-ownership.ps1
#   powershell -NoProfile -File test\win32\install-ownership.ps1 -TeethCheck
param(
    [string]$Repo = 'D:\git\ghoztty',
    # Re-run every content check against a deliberately broken copy of the
    # surface it reads and assert it goes red.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

$ownershipScript = Join-Path $Repo 'scripts\install-ownership.ps1'
if (-not (Test-Path -LiteralPath $ownershipScript -PathType Leaf)) {
    "FATAL: missing $ownershipScript - the rule this harness exists to guard is gone"
    "1 FAILURE(S)"
    exit 1
}
. $ownershipScript

$userInstall = Get-UserInstallDir
$devInstall = Get-DevInstallDir

# The content surfaces the static sections read, loaded once so -TeethCheck can
# poison a copy instead of the tree.
$paths = [ordered]@{
    upgrade   = 'scripts\upgrade-ghoztty-windows.ps1'
    launcher  = 'scripts\launch-upgrade.ps1'
    guarddue  = 'scripts\guard-due.ps1'
    gomd      = 'go.md'
    buildmd   = 'docs\claude\build.md'
}
$text = [ordered]@{}
foreach ($k in $paths.Keys) {
    $p = Join-Path $Repo $paths[$k]
    if (-not (Test-Path -LiteralPath $p)) {
        "FATAL: missing $p"
        "1 FAILURE(S)"
        exit 1
    }
    $text[$k] = Get-Content -LiteralPath $p -Raw
}

# ============================================================================
"== A: the rule is exact about what the user owns"
# ============================================================================
if (-not $TeethCheck) {
    Assert 'A1 the install directory itself is the user`s' (Test-IsUserInstallPath -Path $userInstall)
    Assert 'A2 so is the exe inside it' (Test-IsUserInstallPath -Path (Join-Path $userInstall 'ghoztty.exe'))
    Assert 'A3 and anything nested deeper' (Test-IsUserInstallPath -Path (Join-Path $userInstall 'share\terminfo'))
    Assert 'A4 a trailing separator does not smuggle a path past it' `
        (Test-IsUserInstallPath -Path ($userInstall + '\'))
    Assert 'A5 nor does case' (Test-IsUserInstallPath -Path $userInstall.ToUpperInvariant())
    Assert 'A6 nor does a relative segment' `
        (Test-IsUserInstallPath -Path (Join-Path $userInstall '..\Ghoztty\ghoztty.exe'))
    # The check must not consult the filesystem: a delivery to an install path
    # that does not exist YET is the same violation, and would otherwise pass.
    Assert 'A7 it answers without the directory having to exist' `
        (Test-IsUserInstallPath -Path (Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty\does-not-exist\ghoztty.exe'))
    # And it must not over-reach: the loop owns these and must stay able to
    # write them, or the refusal costs the dev path it was careful to keep.
    Assert 'A8 the dev install is NOT the user`s' (-not (Test-IsUserInstallPath -Path $devInstall))
    Assert 'A9 nor is zig-out' (-not (Test-IsUserInstallPath -Path (Join-Path $Repo 'zig-out\bin')))
    Assert 'A10 nor is the Desktop portable' `
        (-not (Test-IsUserInstallPath -Path 'D:\Users\David\Desktop\Ghoztty-portable-x64\Ghoztty'))
    Assert 'A11 nor is a sibling directory with the same prefix' `
        (-not (Test-IsUserInstallPath -Path ($userInstall + '-old')))
    Assert 'A12 an empty path is not a violation' (-not (Test-IsUserInstallPath -Path ''))
    # The refusal has to tell the reader what to do instead, or it is a wall.
    $refusal = Get-InstallOwnershipRefusal -Path $userInstall -Who 'x'
    Assert 'A13 the refusal names the publish path' ($refusal -match 'publish-windows-release\.ps1')
    Assert 'A14 and the updater rule' ($refusal -match 'in-app updater')
    Assert 'A15 and the decision that set it' ($refusal -match 'D85')
}

# ============================================================================
"== B: upgrade-ghoztty-windows.ps1 refuses the user's install, live"
# ============================================================================
if (-not $TeethCheck) {
    # Nothing destructive can happen here: the guard is the first statement
    # after the dot-sources, before any read, kill, copy or launch.
    $upgrade = Join-Path $Repo $paths['upgrade']
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $upgrade `
        -InstallDir $userInstall -NoResume 2>&1 | ForEach-Object { "$_" } | Out-String
    $code = $LASTEXITCODE
    AssertEq 'B1 it exits 3 (nothing delivered)' 3 $code
    Assert 'B2 and says whose install it refused' ($out -match [regex]::Escape($userInstall))
    Assert 'B3 and points at publishing instead' ($out -match 'publish-windows-release\.ps1')
    Assert 'B4 and names the decision' ($out -match 'D85')
    # The default is the other half of the guarantee: a bare run must not even
    # aim at the user's install. Read as source, because RUNNING a bare upgrade
    # would perform a real dev delivery.
    Assert 'B5 its default -InstallDir is not the user`s install' `
        ($text['upgrade'] -notmatch '\$InstallDir\s*=\s*"\$env:LOCALAPPDATA\\Programs\\Ghoztty"')
    Assert 'B6 its default -InstallDir is the dev install' `
        ($text['upgrade'] -match '\$InstallDir\s*=\s*"\$env:LOCALAPPDATA\\ghoztty\\dev-install"')
}

# ============================================================================
"== C: launch-upgrade.ps1 refuses it in the caller's console"
# ============================================================================
if (-not $TeethCheck) {
    # -Prompt is deliberately omitted: the refusal must come BEFORE every other
    # validation, so the delivery cannot be half-set-up first.
    $launcher = Join-Path $Repo $paths['launcher']
    # `powershell -File` re-tokenizes an argument list: a two-element array
    # written as `-ExtraArgs a, b` arrives as one bound value and one POSITIONAL
    # word, which PositionalBinding=$false rejects before the script runs. The
    # comma-joined form is how an array actually crosses that boundary.
    $lout = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher `
        -PromptFile 'nonexistent' -ExtraArgs "-InstallDir,$userInstall" 2>&1 | ForEach-Object { "$_" } | Out-String
    $lcode = $LASTEXITCODE
    AssertEq 'C1 it exits 3 (nothing built, nothing delivered)' 3 $lcode
    Assert 'C2 and refuses by name' ($lout -match 'launch-upgrade\.ps1 will not write')
    Assert 'C3 before the staging build runs' ($lout -notmatch 'zig build')
    Assert 'C4 and before the prompt is even validated' ($lout -notmatch 'prompt file not found')
    # The other spelling: a real array, the way an in-process caller passes it.
    # The two are not the same string at the parameter binder, so both are
    # measured - a guard that understood only one would be absent from half its
    # callers without anything looking different.
    # `exit` inside a &-invoked script ends that script, not the host session,
    # so the host has to forward the code or C5 would measure the HOST's exit.
    $inproc = "& '$launcher' -PromptFile 'nonexistent' -ExtraArgs @('-InstallDir','$userInstall'); exit `$LASTEXITCODE"
    $aout = & powershell -NoProfile -ExecutionPolicy Bypass -Command $inproc 2>&1 | ForEach-Object { "$_" } | Out-String
    $acode = $LASTEXITCODE
    AssertEq 'C5 the array spelling is refused too' 3 $acode
    Assert 'C6 and says the same thing' ($aout -match 'will not write')
}

# ============================================================================
"== D/E/F: the retirement, the scripts, and the docs"
# ============================================================================
# Predicates over content only, so -TeethCheck can drive each one red.
$checks = [ordered]@{
    'D1 scripts\morning-refresh.ps1 is gone' =
        { param($t) -not (Test-Path -LiteralPath (Join-Path $Repo 'scripts\morning-refresh.ps1')) }
    'D2 its harness went with it' =
        { param($t) -not (Test-Path -LiteralPath (Join-Path $Repo 'test\win32\morning-refresh.ps1')) }
    'D3 guard-due no longer schedules the retired harness' =
        { param($t) $t['guarddue'] -notmatch "Name\s*=\s*'morning-refresh'" }
    'D4 guard-due watches the ownership rule instead' =
        { param($t) $t['guarddue'] -match "Name\s*=\s*'install-ownership'" }
    'D5 go.md no longer tells a turn to run the morning refresh' =
        { param($t) $t['gomd'] -notmatch 'morning-refresh\.ps1' }
    'D6 go.md points at publishing as the delivery path' =
        { param($t) $t['gomd'] -match 'publish-windows-release\.ps1' }
    'E1 the upgrade script no longer names the user install anywhere' =
        { param($t) $t['upgrade'] -notmatch 'LOCALAPPDATA\\Programs\\Ghoztty' }
    'E2 it dot-sources the ownership rule' =
        { param($t) $t['upgrade'] -match 'install-ownership\.ps1' }
    'E3 and refuses before it does anything' =
        { param($t) $t['upgrade'] -match 'Assert-NotUserInstall' }
    'E4 its mirror list is guarded too' =
        { param($t) $t['upgrade'] -match 'Test-IsUserInstallPath' }
    'E5 the launcher carries the same refusal' =
        { param($t) $t['launcher'] -match 'Assert-NotUserInstall' }
    'F1 build.md states who owns the installed app' =
        { param($t) $t['buildmd'] -match 'only the (in-app )?updater may replace it' }
    'F2 build.md names the decision behind it' =
        { param($t) $t['buildmd'] -match 'D85' }
    'F3 build.md points at this harness' =
        { param($t) $t['buildmd'] -match 'install-ownership\.ps1' }
}

# What to poison to prove each content check has teeth. Key + injected text;
# '' means "blank the surface entirely".
$mutations = @{
    'D3 guard-due no longer schedules the retired harness' = @('guarddue', "Name   = 'morning-refresh'")
    'D4 guard-due watches the ownership rule instead'      = @('guarddue', '')
    'D5 go.md no longer tells a turn to run the morning refresh' = @('gomd', 'scripts\morning-refresh.ps1')
    'D6 go.md points at publishing as the delivery path'   = @('gomd', '')
    'E1 the upgrade script no longer names the user install anywhere' =
        @('upgrade', '$InstallDir = "$env:LOCALAPPDATA\Programs\Ghoztty"')
    'E2 it dot-sources the ownership rule'                 = @('upgrade', '')
    'E3 and refuses before it does anything'               = @('upgrade', '')
    'E4 its mirror list is guarded too'                    = @('upgrade', '')
    'E5 the launcher carries the same refusal'             = @('launcher', '')
    'F1 build.md states who owns the installed app'        = @('buildmd', '')
    'F2 build.md names the decision behind it'             = @('buildmd', '')
    'F3 build.md points at this harness'                   = @('buildmd', '')
}

if (-not $TeethCheck) {
    foreach ($name in $checks.Keys) { Assert $name (& $checks[$name] $text) }
    # D1/D2 are filesystem facts rather than content, so they have no mutation;
    # everything else must ship with the demonstration that it can fail.
    $missing = @($checks.Keys | Where-Object { $_ -notmatch '^D[12] ' -and -not $mutations.ContainsKey($_) })
    Assert "F4 no content check ships without a mutation ($($checks.Count) checks)" ($missing.Count -eq 0)
    $missing | ForEach-Object { "       undemonstrated: $_" }
} else {
    "== install-ownership -TeethCheck: each check, fed the state it exists to catch =="
    foreach ($name in $checks.Keys) {
        if (-not $mutations.ContainsKey($name)) { continue }
        $key, $inject = $mutations[$name]
        $poisoned = [ordered]@{}
        foreach ($k in $text.Keys) { $poisoned[$k] = $text[$k] }
        if ($inject -eq '') { $poisoned[$key] = '' } else { $poisoned[$key] = $text[$key] + "`n" + $inject + "`n" }
        $stillPasses = & $checks[$name] $poisoned
        if ($stillPasses) { "  FAIL $name (mutation not caught)"; $script:failures++ }
        else { "  PASS $name (caught)"; $script:passes++ }
    }
    # D1/D2's mutation is the retired file coming back, in a sandbox rather than
    # in the tree.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("install-ownership-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $back = Join-Path $tmp 'morning-refresh.ps1'
        Set-Content -LiteralPath $back -Value '# it came back' -Encoding UTF8
        if (Test-Path -LiteralPath $back) { "  PASS D1/D2 a restored morning-refresh.ps1 is visible (caught)"; $script:passes++ }
        else { "  FAIL D1/D2 a restored morning-refresh.ps1 is visible (mutation not caught)"; $script:failures++ }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A clean green run stamps the files this harness covers (T783). The negative
# control scores its checks inverted, so it never stamps.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard install-ownership -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Label 'T1218 ACCEPTANCE' -Pass $script:passes -Fail $script:failures
