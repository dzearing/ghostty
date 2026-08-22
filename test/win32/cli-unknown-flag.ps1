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
# unit-tested in the none lane.
#
# T852 closed the other half: the FORWARDING verbs (+close, +split,
# +new-window, ...) collect their whole command line and hand it to the
# running instance, whose parser ignores an argument it does not recognize
# ON PURPOSE - that tolerance is the app<->CLI compatibility contract. So a
# typo reached the server, was dropped, and left the verb doing something
# else at exit 0. Each of those verbs now carries an explicit flag allowlist
# in src\cli\verb_flags.zig; sections 13-18 cover them.
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
$env:GHOZTTY_PIPE_SUFFIX = "-t489flags$PID"
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

# --- T852: the forwarding verbs -------------------------------------------
#
# These hand their argv to the running instance. None of the command lines
# below may reach one: `+new-window` is the only verb that AUTO-LAUNCHES the
# app when none is running, so it is never given a command line that survives
# to the IPC call (a stray GUI is not a test result).

$forwarding = @(
    @{ verb = '+close';             typo = '--targt=x';     near = '--target' }
    @{ verb = '+rename';            typo = '--titel=y';     near = '--title' }
    @{ verb = '+rearrange';         typo = '--layot={}';    near = '--layout' }
    @{ verb = '+read';              typo = '--nme=x';       near = '--name' }
    @{ verb = '+set-banner';        typo = '--clr';         near = '--clear' }
    @{ verb = '+set-state';         typo = '--stat=busy';   near = '--state' }
    @{ verb = '+reload';            typo = '--targt=x';     near = '--target' }
    @{ verb = '+split';             typo = '--dirction=r';  near = '--direction' }
    @{ verb = '+new-window';        typo = '--targt=x';     near = '--target' }
    @{ verb = '+new-remote-window'; typo = '--hst=box';     near = '--host' }
)

"== 13: every forwarding verb rejects an unknown flag by name"
foreach ($f in $forwarding) {
    $r = Invoke-Verb "$($f.verb) --bogus-flag=1"
    Assert "$($f.verb) exits nonzero" ($r.exit -ne 0)
    Assert "$($f.verb) names verb and flag" ($r.out -match "\$($f.verb): unknown flag --bogus-flag")
    Assert "$($f.verb) points at --help" ($r.out -match "ghoztty \$($f.verb) --help")
}

"== 14: a near-miss on a forwarding verb gets a suggestion"
foreach ($f in $forwarding) {
    $r = Invoke-Verb "$($f.verb) $($f.typo)"
    Assert "$($f.verb) suggests $($f.near)" ($r.out -match "did you mean $($f.near)\?")
}

# The sentinel control. Every flag the verb really accepts is listed FIRST,
# then one flag that certainly is not. The checker records the FIRST unknown
# flag it sees, so the message naming the sentinel - and only the sentinel -
# is proof that everything ahead of it was accepted. It also fails before the
# IPC call, which is what keeps +new-window from launching anything.
"== 15: every documented flag of every forwarding verb is still accepted"
$accepted = @(
    @{ verb = '+close';     flags = '--target=x' }
    @{ verb = '+rename';    flags = '--target=x --title=y' }
    @{ verb = '+rearrange'; flags = '--target=x --layout={}' }
    @{ verb = '+read';      flags = '--name=x --lines=5' }
    @{ verb = '+set-banner'; flags = '--target=x --clear' }
    @{ verb = '+set-state'; flags = '--target=x --state=busy' }
    @{ verb = '+reload';    flags = '--target=x' }
    @{ verb = '+split'; flags = '--target=x --name=n --pane=p --direction=right --split=right --percent=40 --split-percent=40 --from-focused --view=README.md --command=pwsh --split-command=pwsh --shell=bash --env=A=B --color=#abc --working-directory=D:\git\ghoztty' }
    @{ verb = '+new-window'; flags = '--class=com.x --target=x --name=n --title=t --command=pwsh --view=README.md --working-directory=D:\git\ghoztty --shell=bash --env=A=B --color=#abc --split-color=#abc --split=right --direction=right --split-command=pwsh --split-percent=40 --percent=40 --no-activate --from-focused --cwd-implicit' }
    @{ verb = '+new-remote-window'; flags = '--host=h --port=1 --relay=r --device=d --token=t --name=n --title=t --working-directory=/tmp --shell=/bin/sh --command=ls --no-activate' }
)
foreach ($a in $accepted) {
    $r = Invoke-Verb "$($a.verb) $($a.flags) --zzz-sentinel=1"
    Assert "$($a.verb) exits nonzero on the sentinel" ($r.exit -ne 0)
    Assert "$($a.verb) names ONLY the sentinel (all real flags accepted)" `
        ($r.out -match 'unknown flag --zzz-sentinel')
}

# The other direction: a clean command line gets past the flag layer and
# fails at the IPC call instead, which is the pre-T852 behavior for anything
# spelled right. +new-window is absent on purpose (it would auto-launch).
"== 16: a correct command line still reaches the server"
$reaches = @(
    @{ verb = '+rename';    flags = '--target=x --title=y' }
    @{ verb = '+read';      flags = '--name=x --lines=5' }
    @{ verb = '+set-banner'; flags = '--target=x --clear' }
    @{ verb = '+set-state'; flags = '--target=x --state=busy' }
    @{ verb = '+reload';    flags = '--target=x' }
    @{ verb = '+rearrange'; flags = '--target=x --layout={}' }
    @{ verb = '+split';     flags = '--target=x --direction=right' }
)
foreach ($a in $reaches) {
    $r = Invoke-Verb "$($a.verb) $($a.flags)"
    Assert "$($a.verb) is not a flag error" ($r.out -notmatch 'unknown flag')
    Assert "$($a.verb) reports no running instance" ($r.out -match 'running Ghoztty instance')
}
$r = Invoke-Verb '+close --target=x'
Assert "+close stays idempotent with no instance (exit 0)" ($r.exit -eq 0 -and $r.out -notmatch 'unknown flag')

"== 17: +set-banner text after a bare -- is text, not a flag typo"
$r = Invoke-Verb '+set-banner --target=x -- "--- build failed ---"'
Assert "no flag error for dashed banner text" ($r.out -notmatch 'unknown flag')
Assert "it reached the server" ($r.out -match 'running Ghoztty instance')
$r = Invoke-Verb '+set-banner --target=x "--- build failed ---"'
Assert "without the -- it IS a flag error (the escape hatch is required)" `
    ($r.exit -ne 0 -and $r.out -match 'unknown flag')

"== 18: the -e command tail and single-dash arguments are never checked"
$r = Invoke-Verb '+split --name=x -e pwsh -NoLogo --not-a-ghoztty-flag'
Assert "the -e tail is not flag-checked" ($r.out -notmatch 'unknown flag')
Assert "it reached the server" ($r.out -match 'running Ghoztty instance')
$r = Invoke-Verb '+set-banner --target=x -la'
Assert "a single-dash argument stays banner text" ($r.out -notmatch 'unknown flag')

# `args.parse` only looks for --help at the FRONT. Past that it lands in the
# allowlist, where "unknown flag --help" would be a worse answer than help.
"== 19: --help past the first position still prints help"
$r = Invoke-Verb '+split --target=x --help'
Assert "+split prints its help" ($r.exit -eq 0 -and $r.out -match 'split pane')
Assert "it is not reported as an unknown flag" ($r.out -notmatch 'unknown flag')
$r = Invoke-Verb '+set-banner --target=x -- --help'
Assert "after a bare -- it is banner text, not help" `
    ($r.out -notmatch 'unknown flag' -and $r.out -match 'running Ghoztty instance')
Complete-TestBody  # T1039: the run reached the end of its body

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
