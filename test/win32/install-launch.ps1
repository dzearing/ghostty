# Installing Ghoztty ends with a running terminal, and installs the whole
# product while it is at it (T1176).
#
# Two failures live here, and neither one crashes anything:
#
#   1. The MSI lays down ghoztty.exe but not its siblings. ghoztty.com is what
#      the PATH entry actually resolves (PATHEXT prefers .COM), and
#      ghoztty-agent.exe is what makes panes survive a restart -- a package
#      missing either installs a product that looks fine and is quietly half
#      there. build-msi.sh refuses to package without them and asserts one
#      File-table row per exe; this harness is what makes an edit to those
#      guards ask whether the invariant still holds.
#
#   2. The install finishes and nothing opens. Somebody who just double-clicked
#      an installer should be looking at a terminal, not hunting the Start
#      Menu. The wxs wires a type-51/type-50 custom-action pair that runs the
#      installed exe after InstallFinalize, and build-msi.sh reads that wiring
#      back out of the COMPILED package -- wixl is a pinned third-party
#      compiler whose output has already disagreed with the wxs twice
#      (Environment/@Permanent, empty File.Version), so "the wxs says so" is
#      not evidence that the MSI does.
#
# What this asserts:
#
#   A  the package carries the whole product: preflight refuses a missing
#      twin or agent, the agent gets its own file component, and the
#      File-table patch fails unless all three exes are present exactly once.
#   B  the install ends with a terminal: the launch pair exists, targets the
#      installed exe, runs after InstallFinalize, and is gated so a silent or
#      updater-driven install stays quiet -- plus the build verifies all of
#      that against the compiled MSI rather than the source.
#   C  that build-time gate actually RUNS somewhere: CI builds the MSI on
#      every commit, so a wixl behavior change is red on the commit rather
#      than at the tag.
#
# Every assertion is a predicate over file CONTENT, so -TeethCheck can feed
# each check the mutation it exists to catch and prove it scores red. A gate
# nobody has watched fail is indistinguishable from a gate that cannot fail
# (T1133).
#
# Read-only. Never builds, never installs, never launches the app, needs no
# network and no Docker.
#
# isolation: none - no ghoztty binary is ever run here.
#
#   powershell -NoProfile -File test\win32\install-launch.ps1
#   powershell -NoProfile -File test\win32\install-launch.ps1 -TeethCheck
param(
    [string]$Repo = 'D:\git\ghoztty',
    # Re-run every check against a deliberately broken copy of each surface
    # and assert it goes red. Proves the checks measure what they claim.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function Skip($name, $why) { "  SKIP $name ($why)"; $script:skipped++ }

$paths = [ordered]@{
    msi = 'dist\windows-installer\build-msi.sh'
    rel = 'dist\windows-installer\build-release-artifacts.sh'
    ci  = '.github\workflows\fork-ci.yml'
}

$text = [ordered]@{}
foreach ($k in $paths.Keys) {
    $p = Join-Path $Repo $paths[$k]
    if (-not (Test-Path -LiteralPath $p)) {
        "FATAL: missing $p"
        "1 FAILURE(S)"
        exit 1
    }
    $text[$k] = (Get-Content -LiteralPath $p -Raw)
}

# ---------------------------------------------------------------------------
# The checks. Each takes the content map and returns $true when the installer
# is in the "installs everything, ends with a terminal" shape.
# ---------------------------------------------------------------------------

$checks = [ordered]@{
    # A - the package carries the whole product.
    'A1 packaging refuses a build with no agent exe' =
        { param($t) $t.msi -match '\[\[ -f "\$AGENT_EXE" \]\] \|\|' }
    'A2 packaging refuses a build with no console twin' =
        { param($t) $t.msi -match '\[\[ -f "\$COM_EXE" \]\] \|\|' }
    'A3 the agent gets its own file component' =
        { param($t) $t.msi -match 'emit_file_component\("", agent_exe' }
    'A4 the File-table patch demands all three exes' =
        { param($t)
          $t.msi -match '"ghoztty\.exe": 0' -and
          $t.msi -match '"ghoztty\.com": 0' -and
          $t.msi -match '"ghoztty-agent\.exe": 0' -and
          $t.msi -match 'expected exactly 1 File-table row for each exe' }
    # T1252. The fallback OpenGL implementation is the third sibling with no
    # symptom: a package without it installs a terminal that starts on every
    # machine with working graphics and REFUSES TO START over Remote Desktop,
    # which is the one place nobody packaging it is looking.
    'A5 packaging refuses a build with no fallback OpenGL' =
        { param($t) $t.msi -match '\[\[ -f "\$GL_DIR/opengl32\.dll" \]\] \|\|' }
    'A6 the fallback OpenGL is installed in gl\, never beside the exe' =
        { param($t) $t.msi -match 'emit_dir\(gl, "gl", 14\)' -and
                    $t.msi -notmatch 'emit_file_component\("", gl' }

    # B - the install ends with a running terminal.
    'B1 the wxs declares the launch pair' =
        { param($t)
          $t.msi -match '<CustomAction Id="SetLaunchAppCmd"' -and
          $t.msi -match '<CustomAction Id="LaunchApp"' }
    'B2 the launch targets the installed exe' =
        { param($t) $t.msi -match 'Value="\[INSTALLDIR\]ghoztty\.exe"' }
    'B3 the launch does not block or fail the install' =
        { param($t) $t.msi -match 'Return="asyncNoWait"' }
    'B4 the launch runs after InstallFinalize' =
        { param($t) $t.msi -match '<Custom Action="LaunchApp" After="InstallFinalize">' }
    'B5 a silent or updater-driven install stays quiet' =
        { param($t)
          $cond = ([regex]'<Custom Action="LaunchApp" After="InstallFinalize">([^<]*)</Custom>').Match($t.msi).Groups[1].Value
          $cond -match 'NOT Installed' -and
          $cond -match 'NOT OLDERVERSIONFOUND' -and
          $cond -match 'UILevel &gt; 3' -and
          $cond -match 'LAUNCHAPP = "1"' }
    'B6 LAUNCHAPP=0 is an escape hatch, not an undefined property' =
        { param($t) $t.msi -match '<Property Id="LAUNCHAPP" Value="1"/>' }
    'B7 the build reads the wiring back out of the compiled MSI' =
        { param($t)
          $t.msi -match 'msiinfo export "\$OUT" CustomAction' -and
          $t.msi -match 'msiinfo export "\$OUT" InstallExecuteSequence' }
    'B8 that read-back FAILS the build rather than warning' =
        { param($t) $t.msi -match 'the install would end with no terminal' -and
                    $t.msi -match 'sys\.exit\(1\)' }

    # C - the build-time gate is on a path that actually runs.
    'C1 the shared release script builds the MSI' =
        { param($t) $t.rel -match 'build-msi\.sh' }
    'C2 CI installs the packaging toolchain' =
        { param($t) $t.ci -match 'install-msitools\.sh' }
    'C3 CI builds the MSI on every commit' =
        { param($t) $t.ci -match 'build-release-artifacts\.sh|build-msi\.sh' }
}

# The mutation each check must catch: the surface to poison, the text to find
# and what to put in its place ($null Replace empties the file). A check with
# no mutation listed here is a check that has never been seen to fail, and
# that is a failure of this harness (asserted below).
$mutations = [ordered]@{
    'A1 packaging refuses a build with no agent exe' =
        @{ Key = 'msi'; Find = '[[ -f "$AGENT_EXE" ]] ||'; Replace = 'true ||' }
    'A2 packaging refuses a build with no console twin' =
        @{ Key = 'msi'; Find = '[[ -f "$COM_EXE" ]] ||'; Replace = 'true ||' }
    'A3 the agent gets its own file component' =
        @{ Key = 'msi'; Find = 'emit_file_component("", agent_exe'; Replace = 'pass  # emit_file_component("", skipped_agent' }
    'A4 the File-table patch demands all three exes' =
        @{ Key = 'msi'; Find = '"ghoztty-agent.exe": 0'; Replace = '' }
    'A5 packaging refuses a build with no fallback OpenGL' =
        @{ Key = 'msi'; Find = '[[ -f "$GL_DIR/opengl32.dll" ]] ||'; Replace = 'true ||' }
    'A6 the fallback OpenGL is installed in gl\, never beside the exe' =
        @{ Key = 'msi'; Find = 'emit_dir(gl, "gl", 14)'; Replace = 'emit_file_component("", gl + "/opengl32.dll", 12)' }
    'B1 the wxs declares the launch pair' =
        @{ Key = 'msi'; Find = '<CustomAction Id="LaunchApp"'; Replace = '<!-- LaunchApp removed' }
    'B2 the launch targets the installed exe' =
        @{ Key = 'msi'; Find = 'Value="[INSTALLDIR]ghoztty.exe"'; Replace = 'Value="[INSTALLDIR]ghoztty-agent.exe"' }
    'B3 the launch does not block or fail the install' =
        @{ Key = 'msi'; Find = 'Return="asyncNoWait"'; Replace = 'Return="check"' }
    'B4 the launch runs after InstallFinalize' =
        @{ Key = 'msi'; Find = '<Custom Action="LaunchApp" After="InstallFinalize">'; Replace = '<Custom Action="LaunchApp" After="InstallValidate">' }
    'B5 a silent or updater-driven install stays quiet' =
        @{ Key = 'msi'; Find = 'NOT Installed AND NOT OLDERVERSIONFOUND AND UILevel &gt; 3 AND LAUNCHAPP = "1"'; Replace = 'NOT Installed' }
    'B6 LAUNCHAPP=0 is an escape hatch, not an undefined property' =
        @{ Key = 'msi'; Find = '<Property Id="LAUNCHAPP" Value="1"/>'; Replace = '' }
    'B7 the build reads the wiring back out of the compiled MSI' =
        @{ Key = 'msi'; Find = 'msiinfo export "$OUT" CustomAction'; Replace = 'true # no read-back' }
    'B8 that read-back FAILS the build rather than warning' =
        @{ Key = 'msi'; Find = 'the install would end with no terminal'; Replace = 'warning only' }
    'C1 the shared release script builds the MSI' =
        @{ Key = 'rel'; Find = $null; Replace = $null }
    'C2 CI installs the packaging toolchain' =
        @{ Key = 'ci'; Find = $null; Replace = $null }
    'C3 CI builds the MSI on every commit' =
        @{ Key = 'ci'; Find = $null; Replace = $null }
}

if (-not $TeethCheck) {
    "== install-launch: the shipped tree =="
    foreach ($name in $checks.Keys) {
        Assert $name (& $checks[$name] $text)
    }

    # -----------------------------------------------------------------------
    # E - the build-time read-back, watched failing. Section B proves the
    # verifier is WIRED; this proves it can say no. The code under test is
    # extracted from build-msi.sh itself, so the thing demonstrated here is
    # the thing that ships, and it is fed synthetic CustomAction /
    # InstallExecuteSequence tables instead of a real MSI - which is what
    # makes the demonstration runnable on a box with no Docker and no
    # msitools. Needs a python interpreter and nothing else.
    # -----------------------------------------------------------------------
    "== install-launch: the read-back gate, fed each MSI it must reject =="
    $py = $null
    foreach ($cand in @('python', 'python3', 'py')) {
        $exe = (Get-Command $cand -ErrorAction SilentlyContinue)
        if (-not $exe) { continue }
        # The Windows Store python3 stub exits nonzero and prints an ad.
        $probe = & $cand -V 2>&1
        if ($LASTEXITCODE -eq 0 -and "$probe" -match '^Python 3') { $py = $cand; break }
    }
    if (-not $py) {
        Skip 'E  read-back gate demonstration' 'no python interpreter on PATH'
    } else {
        $verifier = ([regex]'(?ms)^python3 - "\$WORK/CustomAction\.idt".*?\n(.*?)\nPYEOF$').Match($text.msi)
        if (-not $verifier.Success) {
            Assert 'E0 the read-back verifier is extractable from build-msi.sh' $false
        } else {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("install-launch-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp | Out-Null
            try {
                $utf8 = New-Object System.Text.UTF8Encoding($false)
                function Put($name, $body) {
                    $p = Join-Path $tmp $name
                    [System.IO.File]::WriteAllText($p, $body, $utf8)
                    return $p
                }
                $vp = Put 'verify.py' $verifier.Groups[1].Value
                $t = "`t"
                $goodCa = @(
                    "Action${t}Type${t}Source${t}Target",
                    "s72${t}i2${t}S72${t}S255",
                    "CustomAction${t}Action",
                    "SetLaunchAppCmd${t}51${t}LAUNCHAPPCMD${t}[INSTALLDIR]ghoztty.exe",
                    "LaunchApp${t}242${t}LAUNCHAPPCMD${t}",
                    # T1207 added a second pair to the same verifier - the
                    # prepare step that keeps an upgrade from killing live
                    # sessions. A "correctly wired MSI" has to carry it, or E1
                    # is asserting that a package this build would REFUSE is
                    # fine. Its own negatives live in install-prepare.ps1.
                    "SetPrepareInstallDirCmd${t}51${t}PREPAREINSTALLDIRCMD${t}[INSTALLDIR]ghoztty.exe",
                    "PrepareInstallDir${t}114${t}PREPAREINSTALLDIRCMD${t}--install-prepare"
                ) -join "`r`n"
                $cond = 'NOT Installed AND NOT OLDERVERSIONFOUND AND UILevel > 3 AND LAUNCHAPP = "1"'
                $goodSeq = @(
                    "Action${t}Condition${t}Sequence",
                    "s72${t}S255${t}I2",
                    "InstallExecuteSequence${t}Action",
                    "SetPrepareInstallDirCmd${t}${t}1398",
                    "PrepareInstallDir${t}Installed OR OLDERVERSIONFOUND${t}1399",
                    "InstallValidate${t}${t}1400",
                    "InstallFinalize${t}${t}6600",
                    "SetLaunchAppCmd${t}${t}6700",
                    "LaunchApp${t}$cond${t}6710"
                ) -join "`r`n"

                function RunVerifier($caBody, $seqBody) {
                    $ca = Put ("ca-" + [guid]::NewGuid().ToString('N') + '.idt') $caBody
                    $sq = Put ("seq-" + [guid]::NewGuid().ToString('N') + '.idt') $seqBody
                    & $py $vp $ca $sq 2>&1 | Out-Null
                    return $LASTEXITCODE
                }

                Assert 'E1 a correctly wired MSI passes' ((RunVerifier $goodCa $goodSeq) -eq 0)
                Assert 'E2 an MSI with no LaunchApp row is rejected' `
                    ((RunVerifier (($goodCa -split "`r`n" | Where-Object { $_ -notmatch '^LaunchApp' }) -join "`r`n") $goodSeq) -ne 0)
                Assert 'E3 a LaunchApp that blocks msiexec is rejected' `
                    ((RunVerifier ($goodCa -replace "${t}242${t}", "${t}50${t}") $goodSeq) -ne 0)
                Assert 'E4 a launch sequenced before InstallFinalize is rejected' `
                    ((RunVerifier $goodCa ($goodSeq -replace "${t}6710", "${t}6500")) -ne 0)
                Assert 'E5 an upgrade-in-place left ungated is rejected' `
                    ((RunVerifier $goodCa ($goodSeq -replace ' AND NOT OLDERVERSIONFOUND', '')) -ne 0)
                Assert 'E6 a SetLaunchAppCmd that sets nothing is rejected' `
                    ((RunVerifier ($goodCa -replace "${t}51${t}", "${t}19${t}") $goodSeq) -ne 0)
                # Row-scoped: two rows now name [INSTALLDIR]ghoztty.exe, and a
                # blanket replace would move BOTH, so the rejection could no
                # longer be attributed to the launch pair.
                Assert 'E7 a launch pointed at the wrong exe is rejected' `
                    ((RunVerifier ($goodCa -replace "SetLaunchAppCmd\${t}51\${t}LAUNCHAPPCMD\${t}\[INSTALLDIR\]ghoztty\.exe", "SetLaunchAppCmd${t}51${t}LAUNCHAPPCMD${t}[INSTALLDIR]ghoztty-agent.exe") $goodSeq) -ne 0)
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    "== install-launch: every check has a demonstration =="
    $missing = @($checks.Keys | Where-Object { -not $mutations.Contains($_) })
    Assert "D1 no check ships without a mutation (-TeethCheck covers all $($checks.Count))" ($missing.Count -eq 0)
    if ($missing.Count -gt 0) { $missing | ForEach-Object { "       undemonstrated: $_" } }
} else {
    "== install-launch -TeethCheck: each check, fed the state it exists to catch =="
    foreach ($name in $checks.Keys) {
        if (-not $mutations.Contains($name)) {
            "  FAIL $name (no mutation declared)"; $script:failures++; continue
        }
        $m = $mutations[$name]
        # Copy the content map, poison one surface, re-run just this check.
        $poisoned = [ordered]@{}
        foreach ($k in $text.Keys) { $poisoned[$k] = $text[$k] }
        if ($null -eq $m.Find) {
            $poisoned[$m.Key] = ''
        } else {
            if (-not $text[$m.Key].Contains($m.Find)) {
                "  FAIL $name (mutation target not present: $($m.Find))"; $script:failures++; continue
            }
            $poisoned[$m.Key] = $text[$m.Key].Replace($m.Find, $m.Replace)
        }
        $stillPasses = & $checks[$name] $poisoned
        if ($stillPasses) { "  FAIL $name (mutation not caught)"; $script:failures++ }
        else { "  PASS $name (caught)" }
    }
}

# A clean green run stamps the files this harness covers (T783). A run with a
# SKIP did not cover everything, so it does not stamp; the negative control
# deliberately scores red on every check, so it never stamps either.
if ($script:failures -eq 0 -and $script:skipped -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard install-launch -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
