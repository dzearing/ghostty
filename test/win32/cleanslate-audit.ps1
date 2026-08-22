# cleanslate-audit acceptance (T351): one shared kill for the app under test and
# its sibling agent, and no private copies anywhere in the harness.
#
#   powershell -NoProfile -File test\win32\cleanslate-audit.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subject is
# the HARNESS, so this reads .ps1 text and nothing else.
#
# Why it exists. T248 hoisted the pre-fixture reset into lib\CleanSlate.ps1 and
# converted 19 scripts to it. By the time T351 looked, 133 scripts carried a
# private kill again, under six names (Kill-RepoInstances, Stop-TestProcs,
# Stop-RepoInstances, Stop-DebugGhoztty, Stop-AppOnly, Stop-RepoProcesses) and
# four different filters - and four of them had redefined `Stop-RepoGhoztty`
# itself, shadowing the shared one in the same process. A sweep alone would have
# put the count back to zero and left nothing standing between here and the next
# copy, which is exactly the history T248 already has.
#
# A: the analyzer catches the shapes it exists for, and only those shapes.
# B: the sweep - no acceptance script carries an unexplained ghoztty kill.
# C: the shared helper does what the copies were doing, on real processes.
#
# `-TeethCheck` proves section B can go red at all: it synthesizes a violator no
# exemption covers and PASSES only if the assertion turns over. A green sweep
# whose red path nobody has seen is the same claim this script exists to
# distrust.
param([switch]$TeethCheck)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\CleanSlateAudit.ps1')

# The `@()` is load-bearing (PS 5.1): the analyzer's result unrolls, so without
# it a one-finding result arrives as a scalar whose `.Count` is $null and every
# assertion below silently passes.
function Findings($lines) { $r = @(Get-CleanSlateFindings -Text $lines); return , $r }
function KindsOf($lines) { return (Findings $lines | ForEach-Object { $_.Kind }) -join ',' }

# ============================================================================
"== A: the analyzer catches the shapes it exists for, and only those shapes"
# ============================================================================
# Fixtures are the literal text of the copies this task deleted, so they read as
# the code being judged rather than as regex trivia.

$appOnly = @(
    'function Kill-RepoInstances {',
    '    Get-CimInstance Win32_Process -Filter "Name=''ghoztty.exe''" |',
    '        Where-Object { $_.ExecutablePath -like (Join-Path $repo ''zig-out*'') } |',
    '        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }',
    '    Start-Sleep -Milliseconds 500',
    '}')
Assert 'A1 the 30-copy app-only shape is a finding' ((KindsOf $appOnly) -eq 'private-kill')
Assert 'A2 the finding points at the query line' ((Findings $appOnly)[0].Line -eq 2)

$both = @(
    'function Stop-TestProcs {',
    '    foreach ($n in @(''ghoztty.exe'', ''ghoztty-agent.exe'')) {',
    '        Get-CimInstance Win32_Process -Filter "Name=''$n''" |',
    '            Where-Object { $_.CommandLine -like ''*zig-out*'' } |',
    '            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }',
    '    }',
    '}')
Assert 'A3 the app+agent loop shape is a finding' ((KindsOf $both) -eq 'private-kill')

# The rule is about KILLS. Counting or inspecting processes is normal and stays
# silent - several scripts assert on pids they enumerate.
$enumerate = @(
    'function App-Pids {',
    '    return , @(Get-CimInstance Win32_Process -Filter "Name=''ghoztty.exe''" |',
    '        Where-Object { $_.ExecutablePath -eq $Exe } |',
    '        ForEach-Object { $_.ProcessId })',
    '}')
Assert 'A4 an enumeration is not a finding' ((Findings $enumerate).Count -eq 0)

# A kill of something that is not ours is this script's own litter, and local is
# where it belongs.
$litter = @(
    '    Get-CimInstance Win32_Process -Filter "Name=''remote-test-client.exe''" |',
    '        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }')
Assert 'A5 a kill of a non-ghoztty process is not a finding' ((Findings $litter).Count -eq 0)

# The shared call itself, which is what every converted script now holds.
$shared = @(
    'function Kill-RepoInstances {',
    '    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)',
    '}')
Assert 'A6 the shared call is not a finding' ((Findings $shared).Count -eq 0)

# The exemption, and its teeth: a marker with no reason is worse than no marker,
# because it reads as considered.
$exempt = @(
    'function Stop-TestProcs {',
    '    # cleanslate-exempt: matches the t549 fake agents by run marker, not path',
    '    Get-CimInstance Win32_Process -Filter "Name=''ghoztty-agent.exe''" |',
    '        Where-Object { $_.CommandLine -like ''*t549*'' } |',
    '        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }',
    '}')
Assert 'A7 an explained kill is exempt' ((Findings $exempt).Count -eq 0)

$blank = @(
    '    # cleanslate-exempt:',
    '    Get-CimInstance Win32_Process -Filter "Name=''ghoztty.exe''" |',
    '        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }')
Assert 'A8 a reasonless exemption is itself a finding' ((KindsOf $blank) -eq 'empty-exemption')

# Distance matters: a marker six lines up still governs, one further away does
# not - otherwise an exemption at the top of a file would excuse the whole file.
$faraway = @(
    '    # cleanslate-exempt: about something else entirely',
    '    $a = 1', '    $b = 2', '    $c = 3', '    $d = 4', '    $e = 5', '    $f = 6', '    $g = 7',
    '    Get-CimInstance Win32_Process -Filter "Name=''ghoztty.exe''" |',
    '        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }')
Assert 'A9 a distant exemption does not reach the kill' ((KindsOf $faraway) -eq 'private-kill')

# ============================================================================
"== B: the sweep - no acceptance script carries an unexplained ghoztty kill"
# ============================================================================
$scripts = @(Get-CleanSlateAuditScripts -Root $PSScriptRoot)
Assert "B1 the corpus is enumerated ($($scripts.Count) scripts)" ($scripts.Count -gt 100)

$violators = @()
foreach ($s in $scripts) {
    $found = @(Get-CleanSlateFindings -Text (Get-Content $s.FullName))
    if ($found.Count) {
        $violators += [pscustomobject]@{ File = $s.Name; Findings = $found }
    }
}
foreach ($v in $violators) {
    foreach ($f in $v.Findings) {
        "  ---> $($v.File):$($f.Line) [$($f.Kind)] $($f.Text)"
    }
}
Assert "B2 no script carries a private ghoztty kill ($($violators.Count) files)" ($violators.Count -eq 0)

# The shared kill must be reachable from every script that calls it: a converted
# script that forgot the dot-source fails at runtime, not here, and only on the
# path that kills.
$missing = @()
foreach ($s in $scripts) {
    $lines = Get-Content $s.FullName
    # A CALL, not a mention. Comments are dropped because two scripts explain in
    # prose why they keep a private kill; quoted spans are dropped because
    # launch-preflight-audit.ps1 carries the name in a match PATTERN and in a
    # synthesized fixture, and neither invokes anything.
    $calls = @($lines | Where-Object {
        $bare = $_ -replace "'[^']*'", '' -replace '"[^"]*"', ''
        $bare = ($bare -split '#')[0]
        $bare -match '\b(Stop-RepoGhoztty|Reset-GhozttyTestState)\b'
    })
    if (-not $calls.Count) { continue }
    # TestDesktop.ps1 and Isolation.ps1 pull BuildMode in, not CleanSlate; a
    # script that calls the kill must name CleanSlate itself.
    if (($lines -join "`n") -notmatch 'CleanSlate\.ps1') { $missing += $s.Name }
}
Assert "B3 every caller of the shared kill dot-sources it ($($missing -join ', '))" ($missing.Count -eq 0)

# The shape that made this worst: a script redefining the shared name, so the
# private body wins inside that process and the audit above cannot see it.
$shadow = @()
foreach ($s in $scripts) {
    if ((Get-Content $s.FullName -Raw) -match '(?m)^\s*function\s+(Stop-RepoGhoztty|Reset-GhozttyTestState)\b') {
        $shadow += $s.Name
    }
}
Assert "B4 nothing redefines the shared helpers ($($shadow -join ', '))" ($shadow.Count -eq 0)

if ($TeethCheck) {
    $fake = Join-Path $env:TEMP "cleanslate-teeth-$PID.ps1"
    @(
        'function Kill-RepoInstances {',
        '    Get-CimInstance Win32_Process -Filter "Name=''ghoztty.exe''" |',
        '        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }',
        '}') | Set-Content -Path $fake -Encoding UTF8
    $teeth = @(Get-CleanSlateFindings -Text (Get-Content $fake))
    Remove-Item $fake -Force -ErrorAction SilentlyContinue
    Assert 'B5 (teeth) a synthesized violator is caught' ($teeth.Count -eq 1)
}

# ============================================================================
"== C: the shared helper does what the copies were doing, on real processes"
# ============================================================================
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$exe = Join-Path $Repo 'zig-out\bin\ghoztty.exe'
Assert 'C1 the agent path is the exe''s sibling' `
    ((Get-GhozttyAgentPath -Exe $exe) -eq (Join-Path $Repo 'zig-out\bin\ghoztty-agent.exe'))

# The refusal that makes a mistyped -Exe harmless. This is the guarantee every
# private copy lacked: they filtered, they never refused.
$refused = $false
try { Stop-RepoGhoztty -Exe 'C:\Users\Someone\AppData\Local\Programs\Ghoztty\ghoztty.exe' -SettleMs 0 | Out-Null }
catch { $refused = $true }
Assert 'C2 an exe outside the repo is refused outright' $refused

$contradiction = $false
try { Stop-RepoGhoztty -Exe $exe -AppOnly -AgentOnly -SettleMs 0 | Out-Null }
catch { $contradiction = $true }
Assert 'C3 -AppOnly with -AgentOnly is a contradiction, not a silent no-op' $contradiction

# Both scopes the copies had, on the one function. Read off the command rather
# than exercised: this script kills nothing, and a run that took the repo's debug
# app down would be a side effect nobody asked an audit for.
$params = (Get-Command Stop-RepoGhoztty).Parameters
Assert 'C4 the shared kill offers the app-only scope the copies had' ($params.ContainsKey('AppOnly'))
Assert 'C5 and the agent-only scope agent-pipe needed' ($params.ContainsKey('AgentOnly'))
Assert 'C6 -SettleMs is a caller''s choice, not eight hardcoded sleeps' ($params.ContainsKey('SettleMs'))

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this sweep been run against the suite as it now stands?" - which is
# the whole point of putting a corpus rule behind a guard rather than a memory.
# NOT under -TeethCheck: that run writes a violator into $env:TEMP and scores the
# analyzer for finding it, so while it says nothing false about the suite, it also
# never observed a clean one and must not claim to have.
if ($script:failures -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard cleanslate -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) {
    "ALL PASS ($($script:passes) assertions)"
    exit 0
} else {
    "$($script:failures) FAILURE(S) ($($script:passes) passed)"
    exit 1
}
