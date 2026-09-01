# TestReachAudit (T1191) - which win32 modules' unit tests the lane ACTUALLY
# runs, measured against which ones have tests at all.
#
# THE RULE:
#
#     Every `src\apprt\win32\*.zig` that contains a `test` block has that test
#     block executed by `zig build test -Dapp-runtime=win32`.
#
# Why the rule needs a sweep rather than a reviewer. Zig only analyzes - and
# therefore only RUNS - the tests of a file whose container is referenced from
# an analyzed one. `src\apprt\win32.zig` carries a hand-written
#
#     test { _ = @import("win32/X.zig"); }
#
# block, and reachability through THAT chain is what pulls a win32 module's
# tests into the lane. Ordinary imports do not: `startup_error.zig` was
# imported and used by `App.zig`, compiled by every lane, carried five unit
# tests, and a deliberately broken assertion inside one of them ran GREEN
# through the full lane and through `-Dtest-filter` both (T1177). Adding one
# line to that list made the identical tree go red. Nothing else in the repo
# measures the difference, so a module added without its line is silently
# uncovered for as long as nobody breaks one of its tests on purpose.
#
# ---------------------------------------------------------------------------
# The oracle is the COMPILED BINARY, not a model of the compiler.
#
# The obvious sweep - "has tests but is not named in `win32.zig`'s list" -
# reports ~130 files and is wrong: a listed module carries its own test-block
# imports, so plenty of unlisted files are reached transitively and do run. The
# next-most-obvious sweep - re-implement Zig's reachability in PowerShell - is
# wrong in a worse way: it would be a MODEL of the rule, and a model that
# drifts from the compiler fails exactly the way this task exists to stop. The
# first draft of it scored all 174 files as unreachable, because `src\main.zig`
# references its entrypoint by IDENTIFIER rather than by a literal `@import`,
# and `refAllDecls(@This())` is a third shape again.
#
# So this asks the compiler instead. Zig names every test after the file it
# came from (`apprt.win32.<module>.test.<name>`), those names are string data
# in the test binary, and a test that was never analyzed contributes no name.
# Scanning the binary for `apprt.win32.<module>.test` therefore answers "which
# modules' tests are in this lane" exactly, with no semantics of Zig's
# re-implemented here. When Zig changes how reachability works, the sweep
# follows for free.
#
# ---------------------------------------------------------------------------
# Scope, stated rather than implied: `src\apprt\win32\*.zig`, non-recursive
# (there are no subdirectories today). The shared core's modules reach the lane
# through their own aggregators and are outside this rule; widening it is a
# matter of adding a namespace here once one of them grows the same list shape.

Set-StrictMode -Version Latest

# Every win32 module that CONTAINS a test block, by module name (the basename
# Zig uses in a test's fully qualified name).
#
# Plain line matching, no comment stripping, and that is not a shortcut: a
# commented-out test reads `// test "x" {` so the `//` already precedes the
# keyword, and a `test` line inside a Zig multiline string is prefixed `\\`.
# Neither can match `^[ \t]*test\b`.
function Get-WinModulesWithTests([string]$Repo) {
    $dir = Join-Path $Repo 'src\apprt\win32'
    $out = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter *.zig -File | Sort-Object Name)) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text -match '(?m)^[ \t]*test\b') {
            [void]$out.Add([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
        }
    }
    return $out
}

# Every module whose tests are present in a compiled test binary, read out of
# the test-name string data. Latin-1 rather than UTF-8 on purpose: this is a
# byte scan of an executable, not text, and Latin-1 is the decoding that maps
# every byte to exactly one char so offsets and ASCII runs survive intact.
# By codepage rather than `[Text.Encoding]::Latin1`, which is .NET 5+ and this
# box's Windows PowerShell 5.1 does not have it.
function Get-WinModulesInTestBinary([string]$ExePath) {
    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $blob = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($blob, 'apprt\.win32\.([A-Za-z0-9_]+)\.(?:test|decltest)')) {
        [void]$seen.Add($m.Groups[1].Value)
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($n in ($seen | Sort-Object)) { [void]$out.Add($n) }
    return $out
}

# Build the win32 test lane and hand back the path of the binary it ran.
#
# `--verbose` prints the run command, which names the cache path of the test
# exe - so the binary this reads is THE binary the lane ran, rather than a
# freshly emitted lookalike or the newest thing in `.zig-cache`. Building via
# the lane's own command also means the sweep cannot pass over a tree that does
# not compile.
#
# The redirect goes through `cmd`, not through PowerShell (T883): the build's
# verbose output is on STDERR, and a PowerShell `2>` / `*>` of a native
# command's stderr formats every line as an ErrorRecord on its way to disk, at
# a width that depends on the host. This function then reads that file as a
# TEXT ORACLE - it is looking for a path inside it - which is exactly the shape
# that rule exists for. `cmd` writes the child's own bytes and PowerShell never
# holds an object, the same proven-good shape `cli-unknown-flag.ps1` uses.
function Resolve-WinTestBinary {
    param([string]$Repo, [string]$LogPath)

    $env:ZIG_GLOBAL_CACHE_DIR = (Get-ZigGlobalCacheDir $Repo)
    $prev = $PWD
    try {
        Set-Location -LiteralPath $Repo
        cmd /c "zig build test -Dapp-runtime=win32 -Doptimize=Debug --verbose > `"$LogPath`" 2>&1"
        $code = $LASTEXITCODE
    } finally { Set-Location -LiteralPath $prev }

    $exe = $null
    foreach ($line in [System.IO.File]::ReadAllLines($LogPath)) {
        $m = [regex]::Match($line, '(?<p>[^ "'']*ghostty-test\.exe)')
        if ($m.Success) { $exe = $m.Groups['p'].Value; break }
    }
    if ($exe -and -not [System.IO.Path]::IsPathRooted($exe)) {
        $exe = [System.IO.Path]::GetFullPath((Join-Path $Repo $exe))
    }
    return [pscustomobject]@{ ExitCode = $code; ExePath = $exe }
}

# The build cache must sit on the repo's drive (T243): Zig 0.15's build runner
# cannot relativize a path across drives and asserts instead of saying so.
function Get-ZigGlobalCacheDir([string]$Repo) {
    $cur = $env:ZIG_GLOBAL_CACHE_DIR
    $drive = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Repo).Path)
    if ($cur -and ([System.IO.Path]::GetPathRoot($cur) -eq $drive)) { return $cur }
    return (Join-Path $drive 'zig-global-cache')
}

# The finding set: modules with tests that the lane never ran. `Missing` is the
# defect; `Extra` is a module named by the binary with no test block on disk,
# which should be impossible and is reported rather than assumed away.
function Get-TestReachFindings {
    param([string[]]$WithTests, [string[]]$InBinary)
    $bin = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $InBinary) { [void]$bin.Add($m) }
    $src = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $WithTests) { [void]$src.Add($m) }

    $missing = New-Object System.Collections.ArrayList
    foreach ($m in $WithTests) { if (-not $bin.Contains($m)) { [void]$missing.Add($m) } }
    $extra = New-Object System.Collections.ArrayList
    foreach ($m in $InBinary) { if (-not $src.Contains($m)) { [void]$extra.Add($m) } }

    return [pscustomobject]@{ Missing = $missing; Extra = $extra }
}
