# T476 - the zig self-hosted-backend crash reduction stays true.
#
# WHY THIS FILE EXISTS. T476 reduced "ghostty-test cannot be compiled with
# `-Dtest-llvm=false`" down to fifteen lines that touch no ghoztty source at
# all: `test\zig-repro\t476-selfhosted-backend`. A reduction is only worth
# keeping if it is still the same question the original asked, and if somebody
# finds out when the answer changes. Both of those rot silently:
#
#   * the reduction pins ghoztty's `src\build\uucode_config.zig`, and the crash
#     needs THAT config - a trimmed one compiles clean. If the real config
#     moves and the copy does not, the reduction quietly stops describing the
#     build it came from.
#   * the whole point of `-Dtest-llvm` is that it comes OUT when the compiler
#     is fixed, and nothing was ever going to notice a zig upgrade that fixed
#     it. Section C is that noticing: it fails when the repro compiles clean,
#     because a clean compile is the signal to drop the knob and delete the
#     directory.
#
# Section C needs a scratch copy on the cache's drive (zig 0.15.2 asserts when
# the project and ZIG_GLOBAL_CACHE_DIR are on different drives), and it takes a
# minute or two the first time it generates uucode's tables. `-SkipCompile`
# runs A and B alone.
[CmdletBinding()]
param(
    [switch]$SkipCompile,
    [string]$ScratchRoot
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$reproDir = Join-Path $repo 'test\zig-repro\t476-selfhosted-backend'

$script:failures = 0
$script:skipped = 0
$script:asserted = 0
function Assert($name, $cond) {
    $script:asserted++
    if ($cond) { Write-Host "  PASS $name" }
    else { Write-Host "  FAIL $name"; $script:failures++ }
}

""
"A. the reduction is on disk and self-contained"
$files = @('README.md', 'build.zig', 'build.zig.zon', 'src\main.zig', 'src\uucode_config.zig')
foreach ($f in $files) {
    Assert "$f is present" (Test-Path (Join-Path $reproDir $f))
}
if ($script:failures) { "$($script:failures) FAILURE(S)"; exit 1 }

$main = Get-Content (Join-Path $reproDir 'src\main.zig') -Raw
# The reduction must not grow a ghoztty import: the whole claim it makes is
# "this is not ghoztty's code".
Assert 'the test root imports nothing but std and uucode' (
    ([regex]::Matches($main, '@import\("([^"]+)"\)') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -notin @('std', 'uucode') }).Count -eq 0)
Assert 'the test root still calls uucode case folding' ($main -match 'uucode\.get\(\s*\.case_folding_full')

$build = Get-Content (Join-Path $reproDir 'build.zig') -Raw
# use_llvm = false IS the subject. A repro that quietly went back to the LLVM
# backend would compile clean for the wrong reason and read as "fixed".
Assert 'the repro still selects the self-hosted backend' ($build -match '\.use_llvm\s*=\s*false')
Assert 'the repro still points uucode at the copied config' ($build -match 'build_config_path')

$zon = Get-Content (Join-Path $reproDir 'build.zig.zon') -Raw
$repoZon = Get-Content (Join-Path $repo 'build.zig.zon') -Raw
$mRepro = [regex]::Match($zon, 'uucode-[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9_-]+')
$mRepo = [regex]::Match($repoZon, 'uucode-[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9_-]+')
Assert 'the repro pins the same uucode the repo pins' (
    $mRepro.Success -and $mRepo.Success -and $mRepro.Value -eq $mRepo.Value)

""
"B. the pinned uucode config has not drifted from the shipping one"
$copy = Join-Path $reproDir 'src\uucode_config.zig'
$real = Join-Path $repo 'src\build\uucode_config.zig'
$copyHash = (Get-FileHash -Algorithm SHA256 $copy).Hash
$realHash = (Get-FileHash -Algorithm SHA256 $real).Hash
if ($copyHash -ne $realHash) {
    Write-Host "    copy $copyHash"
    Write-Host "    real $realHash"
    Write-Host "    refresh it: Copy-Item src\build\uucode_config.zig $copy -Force"
}
Assert 'the copied uucode_config.zig is byte for byte the shipping one' ($copyHash -eq $realHash)

""
"C. the compiler bug is still there"
if ($SkipCompile) {
    Write-Host '  SKIP -SkipCompile was passed'
    $script:skipped++
} else {
    $zig = Get-Command zig -ErrorAction SilentlyContinue
    $cache = $env:ZIG_GLOBAL_CACHE_DIR
    if (-not $zig) {
        Write-Host '  SKIP zig is not on PATH'
        $script:skipped++
    } elseif (-not $cache) {
        Write-Host '  SKIP ZIG_GLOBAL_CACHE_DIR is unset (see docs/claude/build.md)'
        $script:skipped++
    } else {
        # Same drive as the cache, or zig 0.15.2 asserts in its build runner
        # rather than saying so - the trap build.zig refuses up front.
        if (-not $ScratchRoot) {
            $ScratchRoot = Join-Path (Split-Path -Qualifier $cache) '\ghoztty-t476-repro'
        }
        if (Test-Path $ScratchRoot) { Remove-Item -Recurse -Force $ScratchRoot }
        New-Item -ItemType Directory -Force $ScratchRoot | Out-Null
        Copy-Item -Recurse -Force (Join-Path $reproDir '*') $ScratchRoot

        $log = Join-Path $ScratchRoot 'build.log'
        Push-Location $ScratchRoot
        try {
            & cmd /c "zig build -Dtarget=native-native-msvc -Dcpu=baseline > `"$log`" 2>&1"
            $code = $LASTEXITCODE
        } finally { Pop-Location }

        $text = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
        # `zig build` reports the compiler's NTSTATUS truncated to a byte
        # (T444): 5 is 0xC0000005, 3 is 0x80000003. Either means zig.exe died.
        $died = $code -ne 0 -and $text -match 'exited with error code (3|5)'
        if ($code -eq 0) {
            Write-Host '  the self-hosted backend COMPILED THIS CLEAN.'
            Write-Host '  That is the fix landing. Next steps:'
            Write-Host '    1. re-run ghoztty: zig build -Dapp-runtime=win32 -Demit-test-exe -Dtest-llvm=false'
            Write-Host '    2. if that is clean too, drop -Dtest-llvm from build.zig'
            Write-Host '    3. delete test\zig-repro\t476-selfhosted-backend and this harness'
        } elseif (-not $died) {
            Write-Host "  the repro failed for some OTHER reason (exit $code); last lines:"
            ($text -split "`n" | Select-Object -Last 5) | ForEach-Object { Write-Host "    $_" }
        }
        Assert 'the reduction still kills the compiler (see the notes above if not)' $died
    }
}

# --- stamp (T783) ---------------------------------------------------------
# Only a CLEAN sweep stamps: a `-SkipCompile` run proved the copy has not
# drifted but not that the bug is still there, which is half the question this
# row exists to ask.
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) {
        "  stamp NOT updated: $($script:skipped) section(s) skipped, so this run did not cover the whole harness"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard zig-repro-t476 -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    }
}

""
if ($script:failures -eq 0) {
    "ALL PASS ($($script:asserted) assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
    exit 0
} else {
    "$($script:failures) FAILURE(S)"
    exit 1
}
