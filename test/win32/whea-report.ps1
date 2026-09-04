# T452 - the WHEA report reads a noisy box as noisy.
#
# WHY THIS FILE EXISTS. On 2026-08-04, T449 asked whether this box was faulting,
# queried Microsoft-Windows-WHEA-Logger filtered to Error LEVEL, got nothing
# back, and recorded "zero WHEA events in 14 days" as evidence of healthy
# hardware. There were 6369 of them in that window - all Warning level, because
# a CORRECTED hardware error is logged as a warning. A month later the same
# query answers 8020.
#
# So the thing under test is not "does the script run". It is: does a window
# containing nothing but Warning-level corrected errors get REPORTED, does an
# uncorrected one score differently from a corrected one, and does an event id
# the table has never seen get named rather than folded into silence.
#
# The classification arms run off JSON fixtures so they are deterministic on any
# box; the live arms only assert the shape of a real run, since what the real
# event log holds is whatever it holds.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repo 'scripts\whea-report.ps1'

$script:failures = 0
$script:skipped = 0
$script:asserted = 0
function Assert($name, $cond) {
    $script:asserted++
    if ($cond) { Write-Host "  PASS $name" }
    else { Write-Host "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $script)) {
    Write-Host "  FAIL whea-report.ps1 not found at $script"
    "1 FAILURE(S)"; exit 1
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("whea-report-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function New-Fixture([string]$name, $events) {
    $p = Join-Path $tmp "$name.json"
    # -InputObject, never the pipeline: piping an array here makes PS 5.1 emit a
    # NESTED array, and the fixture then reads back as one object with no fields.
    $json = ConvertTo-Json -InputObject @($events) -Depth 6
    if (-not @($events).Count) { $json = '[]' }
    Set-Content -Path $p -Value $json -Encoding utf8
    return $p
}

function Evt([int]$id, [string]$level, [string]$message, [string]$when = '2026-09-01T04:00:00') {
    [pscustomobject]@{
        TimeCreated      = $when
        Id               = $id
        LevelDisplayName = $level
        Message          = $message
    }
}

$aerMessage = @'
A corrected hardware error has occurred.

Component: PCI Express Root Port
Error Source: Advanced Error Reporting (PCI Express)

Primary Bus:Device:Function: 0x0:0x1D:0x0
Secondary Bus:Device:Function: 0x0:0x0:0x0
Primary Device Name:PCI\VEN_8086&DEV_7A30&SUBSYS_88821043&REV_11
Secondary Device Name:
'@

$fatalMessage = @'
A fatal hardware error has occurred.

Component: Memory
Error Source: Machine Check Exception

Primary Bus:Device:Function: 0x0:0x0:0x0
Primary Device Name:PCI\VEN_8086&DEV_0000
'@

function RunJson([string]$fixture, [int]$days = 30) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script `
        -InputPath $fixture -Days $days -Json -NoResolve 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Json = ($out | ConvertFrom-Json) }
}

function RunText([string]$fixture, [int]$days = 30) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script `
        -InputPath $fixture -Days $days -NoResolve 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

""
"A. a window of nothing but Warning-level corrected errors is NOT 'clean'"
# The T449 shape, exactly: every event is a warning, so the level-filtered query
# that produced the wrong answer would see an empty log here.
$warnOnly = New-Fixture 'warn-only' (1..25 | ForEach-Object { Evt 17 'Warning' $aerMessage })
$r = RunJson $warnOnly
Assert 'A1 all 25 warning-level events are counted' ($r.Json.Total -eq 25)
Assert 'A2 they are classified CORRECTED' ($r.Json.Counts.CORRECTED -eq 25)
Assert 'A3 the verdict says CORRECTED, never CLEAN' `
    ($r.Json.Verdict -match 'WHEA CORRECTED' -and $r.Json.Verdict -notmatch 'CLEAN')
Assert 'A4 corrected errors alone exit 0 - a marginal link never gates the loop' ($r.Code -eq 0)
$t = RunText $warnOnly
Assert 'A5 the text report states the per-day rate' ($t.Out -match '/day')
Assert 'A6 and warns in-band about the level-filter trap' ($t.Out -match 'never filtered|Warning')

""
"B. an uncorrected event scores differently, and loudly"
$fatal = New-Fixture 'fatal' @(
    (Evt 17 'Warning' $aerMessage),
    (Evt 18 'Error' $fatalMessage)
)
$r = RunJson $fatal
Assert 'B1 the uncorrected event is counted as UNCORRECTED' ($r.Json.Counts.UNCORRECTED -eq 1)
Assert 'B2 the corrected one is still counted separately' ($r.Json.Counts.CORRECTED -eq 1)
Assert 'B3 the verdict leads with UNCORRECTED' ($r.Json.Verdict -match 'WHEA UNCORRECTED')
Assert 'B4 and it exits 8' ($r.Code -eq 8)

""
"C. an id the table has never seen is NAMED, not swallowed"
# The failure this guards is the one the whole file is about: an unread event
# passing as an absence of events.
$unknown = New-Fixture 'unknown' @((Evt 9999 'Warning' $aerMessage))
$r = RunJson $unknown
Assert 'C1 it lands in UNCLASSIFIED, not CORRECTED' `
    ($r.Json.Counts.UNCLASSIFIED -eq 1 -and $r.Json.Counts.CORRECTED -eq 0)
$t = RunText $unknown
Assert 'C2 the report prints the unclassified id' ($t.Out -match 'id 9999' -and $t.Out -match 'UNCLASSIFIED')
Assert 'C3 an unknown id alone does not claim the machine faulted' ($r.Code -eq 0)

""
"D. a genuinely empty window is the only thing that reads CLEAN"
$empty = New-Fixture 'empty' @()
$r = RunJson $empty
Assert 'D1 zero events verdicts CLEAN' ($r.Json.Verdict -match 'WHEA CLEAN')
Assert 'D2 and exits 0' ($r.Code -eq 0)

""
"E. the error source is grouped and named from the message"
$r = RunJson $warnOnly
$src = @($r.Json.Sources)[0]
Assert 'E1 all events from one root port group into one source' ($src.Count -eq 25)
Assert 'E2 the PCI hardware id is carried through' ($src.Hardware -match 'VEN_8086&DEV_7A30')
Assert 'E3 so is the bus:device:function' ($src.Bdf -eq '0x0:0x1D:0x0')
Assert 'E4 and the component' ($src.Component -match 'PCI Express Root Port')

""
"F. against the real event log"
# Nothing here asserts a count - the box's log is whatever it is. What must hold
# is that a live run produces a verdict and an honest exit code.
# Stringified before Out-String (T883): an ErrorRecord's rendering depends on
# the host's width, so a merged stream read as objects can wrap mid-token.
$live = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Days 7 -Json 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
$liveCode = $LASTEXITCODE
$ok = $false
try { $lj = $live | ConvertFrom-Json; $ok = $true } catch { }
Assert 'F1 a live run emits parseable JSON' $ok
if ($ok) {
    Assert 'F2 it carries a verdict' ([string]$lj.Verdict -match '^WHEA ')
    Assert 'F3 the exit code agrees with the uncorrected count' `
        (($lj.Counts.UNCORRECTED -gt 0 -and $liveCode -eq 8) -or ($lj.Counts.UNCORRECTED -eq 0 -and $liveCode -eq 0))
    Assert 'F4 the totals reconcile with the per-class counts' `
        (($lj.Counts.CORRECTED + $lj.Counts.UNCORRECTED + $lj.Counts.INFORMATIONAL + $lj.Counts.UNCLASSIFIED) -eq $lj.Total)
} else {
    Write-Host "  SKIP F2-F4 (no parseable live output)"; $script:skipped += 3
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this been run against the code as it now stands?". A run with
# skipped arms does not stamp - the question is about coverage, not about
# whether the script exited zero.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard whea-report -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) {
    "ALL PASS ($($script:asserted) assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
    exit 0
} else {
    "$($script:failures) FAILURE(S)"
    exit 1
}
