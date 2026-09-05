<#
.SYNOPSIS
    T566 acceptance - scripts\parity-decisions.ps1 validate, driven RED once per
    rule, plus the relay that makes it the loop's gate.

.DESCRIPTION
    The task files have been gated since the day they became files
    (parity-tasks.ps1 validate, which every tracker commit passes through). The
    decisions beside them had nothing: a decision naming no task, a status
    outside open/resolved, an option list with no Pros/Cons or with the
    recommendation flagged on none of its options was found only when a human
    noticed the Activity feed rendering it wrong - and the reader of that feed
    is the user we are asking to make the call.

    Sections:

      A. The positive control. A well-formed fixture decision validates green
         and says so; without this every red below is worthless.
      B. The STRUCTURAL rules, one fixture per branch, each differing from the
         good file in exactly the one way it is measuring: frontmatter, id,
         title, status, kind, created, the task link (absent and dangling),
         the filename, the option keys and labels, an open decision with
         nothing to choose between, and a resolved one whose answer is missing
         or names an option it never offered.
      C. The OPTION FORMAT (user directive, 2026-08-05): exactly one
         "(Recommended)", listed first, and Pros AND Cons on every option. Plus
         the grandfather clause - a decision minted before 2026-08-06 is
         reported as LEGACY OPTIONS and does NOT fail, because rewriting a
         resolved decision to satisfy a rule that postdates it would falsify
         the record.
      D. Round trip through the real minting path: what `new` writes validates
         green, and so does what `resolve` leaves behind. A gate the tool's own
         output cannot pass is a gate that will be switched off.
      E. The RELAY. `parity-tasks.ps1 validate` reports DECISION PROBLEMS and
         exits 1 on a malformed decision directory, and stays green on a good
         one - this is what makes the check the loop's gate rather than a verb
         somebody remembers to run.
      F. Against the REAL decisions directory: validate ALL PASS.

    `-NegativeControl` proves this script can score red at all: it adds one
    inverted assertion that a healthy tree MUST fail, so the run ends with
    exactly one failure.

    Hermetic: every section but F runs against fixture directories under
    $env:TEMP. docs\design\windows-parity-decisions\ is only ever READ. No GUI,
    no ghoztty, no foreground grab - safe on any desktop.

    ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

      powershell -NoProfile -File test\win32\parity-decisions.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'

# isolation: none - no ghoztty binary is run and no CLI verb is invoked. Every
# executable started here is powershell.exe (T680 meta-check reads this marker).

if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$DecScript = Join-Path $Repo 'scripts\parity-decisions.ps1'
$TaskScript = Join-Path $Repo 'scripts\parity-tasks.ps1'
$DueScript = Join-Path $Repo 'scripts\guard-due.ps1'
$RealDecDir = Join-Path $Repo 'docs\design\windows-parity-decisions'

$script:passes = 0
$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:failures++
    }
}
function Say([string]$m) { Write-Host $m }

$Sandbox = Join-Path $env:TEMP ("ghoztty-parity-decisions-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null

# The fixture task directory every decision below links to. One real task file
# is enough: the link check asks whether T1.md exists, nothing more.
$TaskDir = Join-Path $Sandbox 'tasks'
New-Item -ItemType Directory -Force -Path $TaskDir | Out-Null

function Write-Ascii {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}

Write-Ascii (Join-Path $TaskDir 'T1.md') @(
    '---'
    'id: T1'
    'title: "fixture task"'
    'deps: []'
    'status: "todo"'
    'commits: []'
    '---'
    ''
    '# T1 - fixture task'
    ''
)

function Invoke-Ps {
    param([string[]]$PsArgs)
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass @PsArgs 2>&1 |
            ForEach-Object { $_.ToString() })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}

function Invoke-DecValidate {
    param([string]$Dir, [string[]]$Extra = @())
    return Invoke-Ps (@('-File', $DecScript, 'validate', '-DecisionDir', $Dir, '-TaskDir', $TaskDir) + $Extra)
}

$script:caseN = 0
function New-CaseDir {
    param([string]$Name)
    $script:caseN++
    $d = Join-Path $Sandbox ("{0:d2}-{1}" -f $script:caseN, $Name)
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# A well-formed decision file, with any one field overridden so each fixture
# differs from a GOOD file in exactly the way it is measuring. $Options is
# emitted verbatim, which is how the option-shape cases are written.
function New-DecisionFile {
    param(
        [string]$Dir,
        [string]$Id = 'D1',
        [string]$DeclaredId,
        [string]$Title = 'Should the banner fade out when it collapses?',
        [string]$Task = 'T1',
        [string]$Kind = 'assumption',
        [string]$Status = 'resolved',
        [string]$Created = '2026-08-20T10:00:00Z',
        [string]$Answer = 'o1',
        [string]$Note = 'null',
        [string[]]$Options,
        [switch]$NoTitle,
        [switch]$NoCreated,
        [switch]$NoFrontmatter
    )
    if (-not $DeclaredId) { $DeclaredId = $Id }
    if (-not $PSBoundParameters.ContainsKey('Options')) {
        $Options = @(
            'options:'
            '  - key: o1'
            '    label: "Fade it out (Recommended)"'
            '    pros:'
            '      - "Matches what Mac does, so the two builds feel the same"'
            '    cons:'
            '      - "One more animation to keep smooth on a busy pane"'
            '  - key: o2'
            '    label: "Snap it away"'
            '    pros:'
            '      - "Nothing to keep smooth"'
            '    cons:'
            '      - "Reads as a glitch next to the Mac build"'
        )
    }
    $lines = @('---', "id: $DeclaredId")
    if (-not $NoTitle) { $lines += ("title: " + (ConvertTo-Json $Title -Compress)) }
    $lines += @(
        ("task: " + $(if ($Task) { ConvertTo-Json $Task -Compress } else { 'null' }))
        "kind: `"$Kind`""
        "status: `"$Status`""
    )
    if (-not $NoCreated) { $lines += ("created: " + (ConvertTo-Json $Created -Compress)) }
    $lines += 'assumed: "carried on with the fade"'
    $lines += $Options
    $lines += @(
        ("answer: " + $(if ($Answer) { ConvertTo-Json $Answer -Compress } else { 'null' }))
        'answeredAt: "2026-08-21T10:00:00Z"'
        "note: $Note"
        '---'
        ''
        "# $Id - $Title"
        ''
        '## Why this needs a call'
        ''
        'Mac fades; win32 has no equivalent, so the translation is a choice.'
        ''
    )
    if ($NoFrontmatter) { $lines = @("# $Id - $Title", '', 'no frontmatter at all') }
    Write-Ascii (Join-Path $Dir "$Id.md") $lines
}

# One good decision plus one fixture that breaks a single rule: the run must be
# RED, and must name the rule.
function Test-Red {
    param([string]$Case, [string]$Label, [scriptblock]$Build)
    $d = New-CaseDir $Case
    New-DecisionFile -Dir $d -Id 'D1'
    & $Build $d
    $r = Invoke-DecValidate $d
    Check ("{0} reports {1}" -f $Case, $Label) `
        ($r.Code -eq 1 -and $r.Text -match [regex]::Escape($Label)) "exit=$($r.Code): $($r.Text)"
}

Reset-TestBody

try {

    # =======================================================================
    Say ''
    Say 'A. the positive control - a well-formed decision directory is green'
    # =======================================================================

    $clean = New-CaseDir 'clean'
    New-DecisionFile -Dir $clean -Id 'D1'
    New-DecisionFile -Dir $clean -Id 'D2' -Status 'open' -Answer '' -Created '2026-09-01T10:00:00Z'
    $r = Invoke-DecValidate $clean
    Check 'A1 a clean fixture validates green' ($r.Code -eq 0 -and $r.Text -match 'ALL PASS') `
        "exit=$($r.Code): $($r.Text)"
    Check 'A2 ...and counts what it looked at' ($r.Text -match 'ALL PASS \(2 decisions\)') $r.Text
    Check 'A3 -Quiet prints no verdict line, for the relay to wrap' `
        ((Invoke-DecValidate $clean @('-Quiet')).Text.Trim() -eq '') "got: $((Invoke-DecValidate $clean @('-Quiet')).Text)"

    # =======================================================================
    Say ''
    Say 'B. the structural rules, driven RED - one fixture per branch'
    # =======================================================================

    Test-Red 'B1' 'BAD FRONTMATTER' { param($d) New-DecisionFile -Dir $d -Id 'D2' -NoFrontmatter }
    Test-Red 'B2' 'ID MISMATCH' { param($d) New-DecisionFile -Dir $d -Id 'D2' -DeclaredId 'D7' }
    Test-Red 'B3' 'NO TITLE' { param($d) New-DecisionFile -Dir $d -Id 'D2' -NoTitle }
    Test-Red 'B4' 'ODD STATUS' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Status 'pending' }
    Test-Red 'B5' 'ODD KIND' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Kind 'idea' }
    Test-Red 'B6' 'NO CREATED' { param($d) New-DecisionFile -Dir $d -Id 'D2' -NoCreated }
    Test-Red 'B7' 'NO TASK LINK' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Task '' }
    Test-Red 'B8' 'DANGLING TASK' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Task 'T999' }
    Test-Red 'B9' 'ODD FILENAME' { param($d) Write-Ascii (Join-Path $d 'notes.md') @('# loose notes') }
    Test-Red 'B10' 'ODD OPTION KEYS' { param($d)
        New-DecisionFile -Dir $d -Id 'D2' -Options @(
            'options:'
            '  - key: o1'
            '    label: "Fade it out (Recommended)"'
            '    pros:'
            '      - "Matches Mac"'
            '    cons:'
            '      - "One more animation"'
            '  - key: o3'
            '    label: "Snap it away"'
            '    pros:'
            '      - "Nothing to keep smooth"'
            '    cons:'
            '      - "Reads as a glitch"'
        )
    }
    Test-Red 'B11' 'NO OPTION LABEL' { param($d)
        New-DecisionFile -Dir $d -Id 'D2' -Options @(
            'options:'
            '  - key: o1'
            '    pros:'
            '      - "Matches Mac"'
            '    cons:'
            '      - "One more animation"'
        )
    }
    Test-Red 'B12' 'NO OPTIONS' { param($d)
        New-DecisionFile -Dir $d -Id 'D2' -Status 'open' -Answer '' -Options @('options: []')
    }
    Test-Red 'B13' 'RESOLVED WITHOUT ANSWER' { param($d)
        New-DecisionFile -Dir $d -Id 'D2' -Answer ''
    }
    Test-Red 'B14' 'UNKNOWN ANSWER' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Answer 'o7' }

    # A resolved decision that records only a free-text note is a legitimate
    # resolution (the answer was none of the above), so it must NOT be caught
    # by B13 - the rule is "no answer AND no note", not "no answer".
    $noteOnly = New-CaseDir 'note-only'
    New-DecisionFile -Dir $noteOnly -Id 'D1' -Answer '' -Note '"neither - we did the third thing"'
    $r = Invoke-DecValidate $noteOnly
    Check 'B15 a note-only resolution is a resolution, not a problem' `
        ($r.Code -eq 0) "exit=$($r.Code): $($r.Text)"

    # =======================================================================
    Say ''
    Say 'C. the option format (user directive 2026-08-05), and its grandfather clause'
    # =======================================================================

    $twoRec = @(
        'options:'
        '  - key: o1'
        '    label: "Fade it out (Recommended)"'
        '    pros:'
        '      - "Matches Mac"'
        '    cons:'
        '      - "One more animation"'
        '  - key: o2'
        '    label: "Snap it away (Recommended)"'
        '    pros:'
        '      - "Nothing to keep smooth"'
        '    cons:'
        '      - "Reads as a glitch"'
    )
    $recSecond = @(
        'options:'
        '  - key: o1'
        '    label: "Snap it away"'
        '    pros:'
        '      - "Nothing to keep smooth"'
        '    cons:'
        '      - "Reads as a glitch"'
        '  - key: o2'
        '    label: "Fade it out (Recommended)"'
        '    pros:'
        '      - "Matches Mac"'
        '    cons:'
        '      - "One more animation"'
    )
    $noPros = @(
        'options:'
        '  - key: o1'
        '    label: "Fade it out (Recommended)"'
        '    cons:'
        '      - "One more animation"'
        '  - key: o2'
        '    label: "Snap it away"'
        '    pros:'
        '      - "Nothing to keep smooth"'
        '    cons:'
        '      - "Reads as a glitch"'
    )
    $noCons = @(
        'options:'
        '  - key: o1'
        '    label: "Fade it out (Recommended)"'
        '    pros:'
        '      - "Matches Mac"'
        '  - key: o2'
        '    label: "Snap it away"'
        '    pros:'
        '      - "Nothing to keep smooth"'
        '    cons:'
        '      - "Reads as a glitch"'
    )

    Test-Red 'C1' 'REC COUNT' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Options $twoRec }
    Test-Red 'C2' 'REC NOT FIRST' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Options $recSecond }
    Test-Red 'C3' 'NO PROS' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Options $noPros }
    Test-Red 'C4' 'NO CONS' { param($d) New-DecisionFile -Dir $d -Id 'D2' -Options $noCons }

    # No recommendation at all is the same defect as two of them: the user is
    # handed a list with no steer.
    $noRec = New-CaseDir 'no-rec'
    New-DecisionFile -Dir $noRec -Id 'D1' -Options @(
        'options:'
        '  - key: o1'
        '    label: "Fade it out"'
        '    pros:'
        '      - "Matches Mac"'
        '    cons:'
        '      - "One more animation"'
        '  - key: o2'
        '    label: "Snap it away"'
        '    pros:'
        '      - "Nothing to keep smooth"'
        '    cons:'
        '      - "Reads as a glitch"'
    )
    $r = Invoke-DecValidate $noRec
    Check 'C5 an option list with NO recommendation is caught too' `
        ($r.Code -eq 1 -and $r.Text -match 'REC COUNT') "exit=$($r.Code): $($r.Text)"

    # The grandfather clause. Same file, same defects, minted before the
    # directive: reported as legacy, and green.
    $legacy = New-CaseDir 'legacy'
    New-DecisionFile -Dir $legacy -Id 'D1' -Created '2026-08-04T10:00:00Z' -Options $noPros
    $r = Invoke-DecValidate $legacy
    Check 'C6 a pre-2026-08-06 decision is reported as LEGACY OPTIONS' ($r.Text -match 'LEGACY OPTIONS') $r.Text
    Check 'C7 ...and is NOT failed - we do not rewrite the record' ($r.Code -eq 0) "exit=$($r.Code): $($r.Text)"

    # ...but the structural rules still apply to it. A legacy file is excused
    # its option FORMAT, not its wiring.
    $legacyBroken = New-CaseDir 'legacy-broken'
    New-DecisionFile -Dir $legacyBroken -Id 'D1' -Created '2026-08-04T10:00:00Z' -Task 'T999'
    $r = Invoke-DecValidate $legacyBroken
    Check 'C8 a legacy file is still held to the structural rules' `
        ($r.Code -eq 1 -and $r.Text -match 'DANGLING TASK') "exit=$($r.Code): $($r.Text)"

    # =======================================================================
    Say ''
    Say 'D. round trip - what new and resolve write must pass their own gate'
    # =======================================================================

    $mint = New-CaseDir 'mint'
    $r = Invoke-Ps @('-File', $DecScript, 'new', '-DecisionDir', $mint, '-TaskDir', $TaskDir,
        '-Title', 'Should the collapsed banner keep its icon?', '-Task', 'T1',
        '-Assumed', 'kept the icon',
        '-Options', 'Keep it (Recommended)::Pros: the pane still says what it is::Cons: two more pixels of chrome;;Drop it::Pros: the narrowest possible strip::Cons: a collapsed banner is unidentifiable',
        '-Why', 'Mac keeps it; the win32 strip is shorter, so it is a real choice.')
    Check 'D1 new mints a decision' ($r.Code -eq 0 -and $r.Text -match 'created D1') "exit=$($r.Code): $($r.Text)"
    $r = Invoke-DecValidate $mint
    Check 'D2 ...and what it wrote validates green' ($r.Code -eq 0 -and $r.Text -match 'ALL PASS') `
        "exit=$($r.Code): $($r.Text)"

    $r = Invoke-Ps @('-File', $DecScript, 'resolve', 'D1', '-DecisionDir', $mint, '-TaskDir', $TaskDir,
        '-Answer', 'o1', '-Note', 'keep the icon')
    Check 'D3 resolve answers it' ($r.Code -eq 0 -and $r.Text -match 'resolved D1') "exit=$($r.Code): $($r.Text)"
    $r = Invoke-DecValidate $mint
    Check 'D4 ...and the resolved file validates green' ($r.Code -eq 0 -and $r.Text -match 'ALL PASS') `
        "exit=$($r.Code): $($r.Text)"

    # =======================================================================
    Say ''
    Say 'E. the relay - parity-tasks.ps1 validate is where this gate has teeth'
    # =======================================================================

    $bad = New-CaseDir 'relay-bad'
    New-DecisionFile -Dir $bad -Id 'D1' -Task 'T999'

    $env:GHOZTTY_DECISION_DIR = $bad
    try {
        $r = Invoke-Ps @('-File', $TaskScript, 'validate', '-TaskDir', $TaskDir)
        Check 'E1 validate reports DECISION PROBLEMS' `
            ($r.Code -eq 1 -and $r.Text -match 'DECISION PROBLEMS') "exit=$($r.Code): $($r.Text)"
        Check 'E2 ...and relays the rule that fired, not just a headline' `
            ($r.Text -match 'DANGLING TASK') $r.Text
        Check 'E3 ...and names the verb that answers it directly' `
            ($r.Text -match 'parity-decisions\.ps1 validate') $r.Text

        $env:GHOZTTY_DECISION_DIR = $clean
        $r = Invoke-Ps @('-File', $TaskScript, 'validate', '-TaskDir', $TaskDir)
        Check 'E4 a good decision directory leaves validate green and silent' `
            ($r.Code -eq 0 -and $r.Text -notmatch 'DECISION PROBLEMS') "exit=$($r.Code): $($r.Text)"
    } finally {
        Remove-Item Env:\GHOZTTY_DECISION_DIR -ErrorAction SilentlyContinue
    }

    # And a fixture task run with no env override must not reach out to the
    # real decisions directory - the same rule the guard-due and control-char
    # checks follow.
    $r = Invoke-Ps @('-File', $TaskScript, 'validate', '-TaskDir', $TaskDir)
    Check 'E5 a plain fixture run does not drag the real decisions in' `
        ($r.Text -notmatch 'DECISION PROBLEMS') $r.Text

    # =======================================================================
    Say ''
    Say 'F. the real decisions directory'
    # =======================================================================

    $r = Invoke-Ps @('-File', $DecScript, 'validate')
    Check 'F1 the real decisions directory validates green' `
        ($r.Code -eq 0 -and $r.Text -match 'ALL PASS') "exit=$($r.Code): $($r.Text)"
    Check 'F2 ...and every decision was actually looked at' `
        ($r.Text -match 'ALL PASS \((\d+) decisions\)' -and [int]$Matches[1] -ge 90) $r.Text
    $realCount = @(Get-ChildItem -LiteralPath $RealDecDir -Filter 'D*.md' -File).Count
    Check 'F3 ...all of them' `
        ($r.Text -match ("ALL PASS \({0} decisions\)" -f $realCount)) "on disk: $realCount; said: $($r.Text)"

    if ($NegativeControl) {
        Say ''
        Say 'NEGATIVE CONTROL: asserting a clean directory is RED - a wired tree MUST fail this'
        $r = Invoke-DecValidate $clean
        Check 'N1 a clean fixture fails validate (inverted)' ($r.Code -eq 1) "exit=$($r.Code)"
    }

    Complete-TestBody
}
catch {
    Write-Host ("FAIL  harness crashed: {0}" -f $_.Exception.Message)
    Write-Host ("    at {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    $script:failures++
}
finally {
    Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783). A red run - and the
# -NegativeControl run, which is red by construction - leaves the stamp alone.
if ($script:failures -eq 0 -and -not $NegativeControl -and (Test-Path -LiteralPath $DueScript)) {
    Invoke-Ps @('-File', $DueScript, 'update', '-Guard', 'parity-decisions', '-Repo', $Repo) |
        ForEach-Object { $_.Text } | ForEach-Object { if ($_) { "  $_" } }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -MinPass 25
