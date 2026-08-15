# T489 acceptance: a mistyped ghoztty CLI flag names itself and fails.
#
# Before T489 the CLI had two different wrong answers to the same typo:
# verbs whose Options struct tracked diagnostics (+list, +sessions) parsed
# the unknown flag into a list nobody ever read and carried on as if it were
# not there (exit 0, wrong behavior, no signal), while verbs with a strict
# Options struct (+show-config, +list-keybinds, ...) propagated
# Error.InvalidField out of the parse and exited 1 with an EMPTY stderr -
# indistinguishable from a crash. `+version` never parsed its args at all.
#
# Now every field-parsing verb reports through one helper
# (cli/args.zig reportCliDiagnostics): the verb, the flag by name, the
# nearest valid flag when the spelling is close, and a --help pointer, then
# exits nonzero. Config keys stay legitimate on the verbs whose command line
# is also read by Config.load (+show-config, +validate-config,
# +list-keybinds, +edit-config, +show-face) - a tolerance, not a hole, and
# unit-tested in the none lane. The forwarding verbs (+close, +split, ...)
# hand their argv to the server by design and are T852's follow-up, not
# covered here.
#
# Exit codes are read through cmd.exe redirection, not a PS 5.1 pipeline:
# $LASTEXITCODE after a native command in a pipeline is not trustworthy here
# (the standing reason on-box oracles gate on OUTPUT).
#
#   powershell -NoProfile -File test\win32\cli-unknown-flag.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# No verb here should ever reach a live instance; isolate the endpoint so
# even the ones that would dial (them failing later is not what's asserted)
# cannot touch the user's session.
$env:GHOZTTY_PIPE_SUFFIX = '-t489flags'
$tmp = Join-Path $env:TEMP "ghoztty-cli-unknown-flag-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# Runs the exe through cmd.exe, returns @{ exit; out } with out holding the
# COMBINED stdout+stderr text.
function Invoke-Verb([string]$argsLine) {
    $outFile = Join-Path $tmp "out.txt"
    cmd /c "`"$Exe`" $argsLine > `"$outFile`" 2>&1"
    $code = $LASTEXITCODE
    $raw = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { $raw = '' }
    return @{ exit = $code; out = $raw }
}

try {

"== 1: +version rejects an unknown flag by name (used to ignore it)"
$r = Invoke-Verb '+version --bogus-flag=1'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "names the flag" ($r.out -match 'unknown flag --bogus-flag')
Assert "names the verb" ($r.out -match '\+version')
Assert "does not print the version document" ($r.out -notmatch 'build mode')

"== 2: +version positive control"
$r = Invoke-Verb '+version'
Assert "exits 0" ($r.exit -eq 0)
Assert "prints the version document" ($r.out -match 'build mode')

"== 3: +list rejects an unknown flag by name (used to ignore it)"
$r = Invoke-Verb '+list --bogus-flag=1'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "names the flag" ($r.out -match 'unknown flag --bogus-flag')

"== 4: a near-miss spelling gets a suggestion"
$r = Invoke-Verb '+list --jsn=true'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "suggests the real flag" ($r.out -match 'did you mean --json\?')

"== 5: +show-config explains itself instead of an empty exit 1"
$r = Invoke-Verb '+show-config --bogus-flag=1'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "names the flag" ($r.out -match 'unknown flag --bogus-flag')
Assert "points at --help" ($r.out -match '--help')

"== 6: +show-config positive control"
$r = Invoke-Verb '+show-config --default'
Assert "exits 0" ($r.exit -eq 0)

"== 7: a config key on a config-loading verb is not an error"
$r = Invoke-Verb '+show-config --default --font-size=13'
Assert "exits 0 (config keys are Config.load's business)" ($r.exit -eq 0)

"== 8: a bad value for a real flag is named"
$r = Invoke-Verb '+show-config --changes-only=maybe'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "names flag and value" ($r.out -match '--changes-only' -and $r.out -match 'invalid value')

"== 9: +sessions rejects an unknown flag by name"
$r = Invoke-Verb '+sessions --bogus-flag=1'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "names the flag" ($r.out -match 'unknown flag --bogus-flag')

"== 10: a strict verb (+list-actions) rejects an unknown flag by name"
$r = Invoke-Verb '+list-actions --bogus-flag=1'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "names the flag" ($r.out -match 'unknown flag --bogus-flag')

"== 11: +explain-config no longer drops a dash argument silently"
$r = Invoke-Verb '+explain-config --bogus-flag=1'
Assert "exits nonzero" ($r.exit -ne 0)
Assert "names the flag" ($r.out -match 'unknown flag --bogus-flag')

"== 12: bare -h prints help (used to exit 1 with nothing)"
$r = Invoke-Verb '-h'
Assert "exits 0" ($r.exit -eq 0)
Assert "prints usage" ($r.out -match 'Available actions')
$r = Invoke-Verb '+help --bogus-flag=1'
Assert "+help still rejects an unknown flag" ($r.exit -ne 0 -and $r.out -match 'unknown flag --bogus-flag')

} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
}

# A green run stamps the covered files (T783) so guard-due can answer "has
# this harness been run against args.zig as it now stands?". Red leaves the
# stamp alone: red stays due.
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard cli-unknown-flag -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Label 'T489 ACCEPTANCE' -Pass $script:passes -Fail $script:failures
