# parity-tasks split-dep acceptance (tracker T382): a dependency on a
# `skipped(split -> ...)` parent is a dependency on ALL of its children, so
# `next` must never offer a task whose real prerequisites are still open, and
# `validate` must say so out loud when a dep resolves through an open split.
#
# Why: splitting a task before starting it is the standing answer to the
# context rule, and the children always get HIGHER ids than the tasks that
# depended on the parent - so "skipped counts as resolved" offered the
# dependent first, every time (T90e was offered while T374/T375 were todo).
#
# Sections:
#   A. A split parent with an open child does NOT satisfy a dependent; the
#      blocked report names the open child, not the parent. With every child
#      done, the dependent is offered.
#   B. Splits resolve recursively - a split of a split (the T89f -> T89f1/T89f2
#      shape) blocks through both levels.
#   C. The status formats found in the real tracker all parse: the JSON-escaped
#      arrow ("-\u003e"), "split into A + B", slash separators, prose after each
#      id, and the T10b-T10d letter-range shorthand (en dash).
#   D. A NON-split skip (duplicate, obsolete) still satisfies, exactly as
#      before - that work genuinely ended.
#   E. A malformed cycle terminates instead of recursing forever.
#   F. `validate` prints an informational SPLIT DEP line for a live task whose
#      dep resolves through an open split, and still exits 0 (a task waiting on
#      a split is a legitimate queue state, not a broken file).
#   G. The real tracker still validates.
#
# Hermetic: sections A-F run against a fixture task dir under $env:TEMP via
# `-TaskDir`; docs\design\windows-parity-tasks\ is only ever READ (section G).
# No GUI, no foreground grab - safe on any desktop.
#
#   powershell -NoProfile -File test\win32\parity-tasks-split-deps.ps1
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0

$taskScript = Join-Path $Repo 'scripts\parity-tasks.ps1'
$realDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
$fixture = Join-Path $env:TEMP "ghoztty-parity-split-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Task-Run {
    param([string[]]$CmdArgs, [string]$Dir = $fixture)
    $out = & powershell -NoProfile -File $taskScript @CmdArgs -TaskDir $Dir 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

# Write one fixture task file. $StatusLine is emitted VERBATIM when given, so a
# test can reproduce the exact bytes the real tracker holds (e.g. the
# JSON-escaped arrow `-\u003e` that set-status wrote into T90d.md).
function New-FixtureTask {
    param(
        [string]$Id,
        [string]$Status = 'todo',
        [string]$StatusLine = '',
        [string]$Deps = '[]'
    )
    if (-not $StatusLine) { $StatusLine = ('status: ' + (ConvertTo-Json $Status -Compress)) }
    $lines = @(
        '---'
        "id: $Id"
        ("title: " + (ConvertTo-Json "fixture $Id" -Compress))
        "deps: $Deps"
        $StatusLine
        'commits: []'
        '---'
        ''
        "# $Id - fixture"
        ''
    )
    $path = Join-Path $fixture "$Id.md"
    [System.IO.File]::WriteAllText($path, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
}

function Reset-Fixture {
    if (Test-Path $fixture) { Remove-Item -Recurse -Force $fixture }
    New-Item -ItemType Directory -Force $fixture | Out-Null
}

# --- A. an open split child blocks the dependent ------------------------------
'A. a split parent with an open child does not satisfy a dependent'
# The dependent (T3) has a LOWER id than the open child (T5) - the real-world
# shape, since splitting mints children after the dependent was filed. That is
# also what lands T3 in the blocked report: `next` only reports todos it
# scanned before the winner.
Reset-Fixture
New-FixtureTask -Id 'T1' -Status 'skipped(split -> T2, T5)'
New-FixtureTask -Id 'T2' -Status 'done'
New-FixtureTask -Id 'T3' -Deps '["T1"]'        # depended on the parent
New-FixtureTask -Id 'T5'                       # todo: the open child

$r = Task-Run @('next')
Assert 'next offers the open child T5, not the dependent T3' ($r.Out -match 'NEXT: T5\b')
Assert 'next reports T3 as blocked' ($r.Out -match 'Skipped 1 earlier todo')
Assert 'the blocked report names the OPEN CHILD, not just the parent' ($r.Out -match 'T3\(needs T1\[open: T5\]\)')

& powershell -NoProfile -File $taskScript set-status T5 -Status done -TaskDir $fixture | Out-Null
$r = Task-Run @('next')
Assert 'with every child done, the dependent is offered' ($r.Out -match 'NEXT: T3\b')

# --- B. a split of a split resolves recursively -------------------------------
""
'B. splits resolve recursively'
Reset-Fixture
New-FixtureTask -Id 'T1' -Status 'skipped(split -> T2, T3)'
New-FixtureTask -Id 'T2' -Status 'done'
New-FixtureTask -Id 'T3' -Status 'skipped(split -> T5, T6)'   # split of a split
New-FixtureTask -Id 'T4' -Deps '["T1"]'
New-FixtureTask -Id 'T5' -Status 'done'
New-FixtureTask -Id 'T6'                       # open grandchild

$r = Task-Run @('next')
Assert 'an open GRANDCHILD blocks the dependent' ($r.Out -match 'NEXT: T6\b')
Assert 'the blocked report names the grandchild' ($r.Out -match 'T4\(needs T1\[open: T6\]\)')

& powershell -NoProfile -File $taskScript set-status T6 -Status done -TaskDir $fixture | Out-Null
$r = Task-Run @('next')
Assert 'with the grandchild done, the dependent is offered' ($r.Out -match 'NEXT: T4\b')

# --- C. real-world status formats all parse -----------------------------------
""
'C. the status formats in the real tracker all parse'
# C1: the JSON-escaped arrow, byte-for-byte what set-status wrote into T90d.md.
Reset-Fixture
New-FixtureTask -Id 'T1' -StatusLine 'status: "skipped(split -\u003e T2 COM floor+probe+env, T3 host window+controller)"'
New-FixtureTask -Id 'T2' -Status 'done'
New-FixtureTask -Id 'T3'
New-FixtureTask -Id 'T4' -Deps '["T1"]'
$r = Task-Run @('next')
Assert 'JSON-escaped arrow + prose after ids: dependent blocked' ($r.Out -match 'NEXT: T3\b' -and $r.Out -notmatch 'NEXT: T4\b')

# C2: "split into A + B".
Reset-Fixture
New-FixtureTask -Id 'T1' -Status 'skipped(split into T2 + T3)'
New-FixtureTask -Id 'T2' -Status 'done'
New-FixtureTask -Id 'T3'
New-FixtureTask -Id 'T4' -Deps '["T1"]'
$r = Task-Run @('next')
Assert '"split into A + B": dependent blocked' ($r.Out -match 'NEXT: T3\b' -and $r.Out -notmatch 'NEXT: T4\b')

# C3: slash separators (the T334/T335/T336 shape).
Reset-Fixture
New-FixtureTask -Id 'T1' -Status 'skipped(split -> T2/T3)'
New-FixtureTask -Id 'T2' -Status 'done'
New-FixtureTask -Id 'T3'
New-FixtureTask -Id 'T4' -Deps '["T1"]'
$r = Task-Run @('next')
Assert 'slash separators: dependent blocked' ($r.Out -match 'NEXT: T3\b' -and $r.Out -notmatch 'NEXT: T4\b')

# C4: the letter-range shorthand with an en dash (the T89b-T89i shape). The
# range names every child, so the MIDDLE child - never written out - must
# still block. The dash is built from a char code to keep this file ASCII.
Reset-Fixture
$enDash = [string][char]0x2013
New-FixtureTask -Id 'T1' -StatusLine ('status: ' + (ConvertTo-Json ("skipped(split " + $enDash + "> T10b" + $enDash + "T10d)") -Compress))
New-FixtureTask -Id 'T10b' -Status 'done'
New-FixtureTask -Id 'T10c'                     # mid-range child, never named
New-FixtureTask -Id 'T10d' -Status 'done'
New-FixtureTask -Id 'T4' -Deps '["T1"]'
$r = Task-Run @('next')
Assert 'a letter range expands: the unnamed middle child blocks' ($r.Out -match 'NEXT: T10c\b' -and $r.Out -notmatch 'NEXT: T4\b')
Assert 'the blocked report names the middle child' ($r.Out -match 'T4\(needs T1\[open: T10c\]\)')

# --- D. non-split skips still satisfy ----------------------------------------
""
'D. duplicate/obsolete skips still satisfy'
Reset-Fixture
New-FixtureTask -Id 'T1' -Status 'skipped(duplicate -> T3)'
New-FixtureTask -Id 'T2' -Status 'skipped(obsolete -> T3 - covered there)'
New-FixtureTask -Id 'T3'                       # open, but NOT a split child
New-FixtureTask -Id 'T4' -Deps '["T1","T2"]'
$r = Task-Run @('next')
# T3 has a lower id, so it heads the queue either way; prove T4 is not blocked
# by claiming T3 out of the way and asking again.
& powershell -NoProfile -File $taskScript set-status T3 -Status blocked -TaskDir $fixture | Out-Null
$r = Task-Run @('next')
Assert 'a non-split skip satisfies even with its target open' ($r.Out -match 'NEXT: T4\b')

# --- E. a malformed cycle terminates ------------------------------------------
""
'E. a malformed split cycle terminates'
Reset-Fixture
New-FixtureTask -Id 'T1' -Status 'skipped(split -> T2)'
New-FixtureTask -Id 'T2' -Status 'skipped(split -> T1)'    # nonsense, but must not hang
New-FixtureTask -Id 'T3' -Deps '["T1"]'
$r = Task-Run @('next')
Assert 'next terminates on a split cycle' ($null -ne $r.Code)
Assert 'and still answers' ($r.Out -match 'NEXT: T3\b')

# --- F. validate says it out loud, informationally ----------------------------
""
'F. validate prints SPLIT DEP and still passes'
Reset-Fixture
New-FixtureTask -Id 'T1' -Status 'skipped(split -> T2, T3)'
New-FixtureTask -Id 'T2' -Status 'done'
New-FixtureTask -Id 'T3'
New-FixtureTask -Id 'T4' -Deps '["T1"]'
$r = Task-Run @('validate')
Assert 'validate names the task, the split parent and the open children' ($r.Out -match 'SPLIT DEP: T4 -> T1 .*open children: T3')
Assert 'validate still exits 0 (informational, not a problem)' ($r.Code -eq 0 -and $r.Out -match 'ALL PASS')

# A DONE dependent is history, not a misroute - no line for it.
& powershell -NoProfile -File $taskScript set-status T4 -Status done -TaskDir $fixture | Out-Null
$r = Task-Run @('validate')
Assert 'a done dependent draws no SPLIT DEP line' ($r.Out -notmatch 'SPLIT DEP:')

# --- G. the real tracker ------------------------------------------------------
""
'G. the real tracker'
$r = Task-Run @('validate') $realDir
Assert 'the real tracker validates' ($r.Code -eq 0 -and $r.Out -match 'ALL PASS')
$r = Task-Run @('next') $realDir
Assert 'next on the real tracker still answers' ($r.Out -match '(NEXT|RESUME|IN FLIGHT): T\d')

# --- teardown ---------------------------------------------------------------
if (Test-Path $fixture) { Remove-Item -Recurse -Force $fixture }

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
