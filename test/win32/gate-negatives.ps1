<#
.SYNOPSIS
    T1133 acceptance - every gate the turn runs has been SHOWN to fail.

.DESCRIPTION
    A check that has never been observed saying anything but "fine" is
    indistinguishable from a check that cannot say anything else, and this
    project has been bitten by that three times in a month:

      * T1099 - `upstream-remote.ps1 ensure` printed UPSTREAM OK every morning
        while answering a weaker question than the one it existed to answer,
        and stayed green through an hour and a half in which every sha it
        guards was `git gc` bait.
      * T783  - the go-loop guard sat 26-red for a day because nothing tied a
        `scripts\go-loop-*.ps1` edit to `test\win32\go-loop-guard.ps1`.
      * T1057 - "push after every commit" was a habit for two weeks before it
        was a check, and had to be restated by the user twice.

    The acceptance scripts do not have this problem, and the reason is
    structural: each one carries a `-NegativeControl` (or `-TeethCheck`) mode
    that inverts an assertion so the run MUST score exactly one failure. The
    two gates every turn runs - `go-loop-exec.ps1 claim` and
    `parity-tasks.ps1 validate` - had no equivalent.

    THE RULE THIS FILE ENFORCES:

        A new gate ships with the demonstration that it can fail, or it is not
        a gate.

    Sections:

      A. The REGISTRY, and its completeness. Every condition label the two gate
         scripts emit is discovered from their source text and must be declared
         here as either a `gate` (a red verdict - needs a demonstration), a
         `hatch` (an escape hatch that must announce itself - also needs one),
         or a `status` (an ordinary informational line). A label nobody has
         triaged fails the section, so a gate added tomorrow cannot ship
         undemonstrated. Every gate/hatch row must then name a harness that
         exists and ASSERTS on that label, and every delegated gate must still
         be reachable from `claim`.
      B. `parity-tasks.ps1 validate`, driven RED here: the seven file-shape and
         graph branches nothing else demonstrated, each against its own fixture
         task dir, plus the positive control that a clean fixture is green and
         silent. B8/B9 cover DEP CYCLE, which T1133 added to `validate` because
         a ring of tasks that wait on each other is otherwise invisible: `next`
         skips every member for "unmet deps" forever and each file reads fine.
      C. `go-loop-exec.ps1 claim`, driven RED here against a throwaway repo -
         stranded work, unpushed work and a broken upstream in one run - plus
         the positive control on a clean, pushed, wired repo. Nothing on the
         live box is touched: the claim runs with `-Repo` pointed at the
         fixture, so its lock, its snapshot and its boot record all land in the
         fixture's own `temp\`.
      D. The rule is WRITTEN DOWN: `go.md` states it and names this harness, so
         the next person adding a gate is told rather than expected to know.

    `-NegativeControl` proves this script can score red at all: it adds one
    inverted assertion that a healthy tree MUST fail, so the run ends with
    exactly one failure.

    Non-interactive. Launches no Ghoztty and touches no user state.

    ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'

# isolation: none - no ghoztty binary is run and no CLI verb is invoked. The
# one `claim` run in section C is handed where.exe as its ghoztty stand-in, so
# `+list`/`+rename` reach nothing; every other executable started here is git,
# powershell.exe, or where.exe (T680 meta-check reads this marker).

if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$ExecScript = Join-Path $Repo 'scripts\go-loop-exec.ps1'
$TaskScript = Join-Path $Repo 'scripts\parity-tasks.ps1'
$DueScript = Join-Path $Repo 'scripts\guard-due.ps1'
$Stand = Join-Path $env:SystemRoot 'System32\where.exe'   # the ghoztty stand-in

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

# ---------------------------------------------------------------------------
# THE REGISTRY
# ---------------------------------------------------------------------------
# One row per condition either gate can report.
#
#   Kind   = 'gate'   a red verdict; MUST name a demonstration that drives it
#            'hatch'  an escape hatch that must announce it was used; same bar,
#                     because a hatch that silently stops announcing itself is
#                     a gate that silently stopped existing
#            'status' an ordinary informational line - no demonstration owed
#   Demo   = the acceptance script that constructs the state and asserts on it
#   Marker = the text that must appear on an ASSERTION line in that script
#   Via    = for a condition CLAIM delegates to another script: that script.
#            Those labels never appear in go-loop-exec.ps1's own text, so they
#            are declared by hand - and section A6 then asserts claim really
#            reaches the delegate, so a row cannot outlive its wiring.
$Self = 'test\win32\gate-negatives.ps1'
$Loop = 'test\win32\go-loop-guard.ps1'
$Seat = 'test\win32\parity-tasks-seat.ps1'
$Registry = @(
    # --- go-loop-exec.ps1 claim, its own reports ---------------------------
    [pscustomobject]@{ Label = 'STRANDED WORK'; Kind = 'gate'; Demo = $Loop; Marker = 'STRANDED WORK' }
    [pscustomobject]@{ Label = 'DUPLICATE'; Kind = 'gate'; Demo = $Loop; Marker = 'DUPLICATE execution window' }
    [pscustomobject]@{ Label = 'STAND-DOWN'; Kind = 'gate'; Demo = $Loop; Marker = 'STAND-DOWN' }
    [pscustomobject]@{ Label = 'PRIMARY'; Kind = 'status' }
    [pscustomobject]@{ Label = 'ERROR'; Kind = 'status' }
    [pscustomobject]@{ Label = 'MARKED'; Kind = 'status' }
    [pscustomobject]@{ Label = 'UNMARKED'; Kind = 'status' }
    [pscustomobject]@{ Label = 'EXEC'; Kind = 'status' }
    # The off switch (2026-08-23). STOPPED is a GATE, not a status line: it is a
    # red verdict that ends the turn before a task is picked up, and it earns a
    # demonstration for the same reason STAND-DOWN does - a refusal nobody
    # exercises is a refusal that quietly stops refusing.
    [pscustomobject]@{ Label = 'STOPPED'; Kind = 'gate'; Demo = $Loop; Marker = 'STOPPED by request' }
    [pscustomobject]@{ Label = 'STOP REQUESTED'; Kind = 'status' }
    [pscustomobject]@{ Label = 'RESUMED'; Kind = 'status' }

    # --- what claim DELEGATES ----------------------------------------------
    [pscustomobject]@{ Label = 'GUARD DUE'; Kind = 'gate'; Demo = 'test\win32\guard-due.ps1'
        Marker = 'GUARD DUE go-loop'; Via = 'scripts\guard-due.ps1'
    }
    [pscustomobject]@{ Label = 'UNPUSHED WORK'; Kind = 'gate'; Demo = $Loop
        Marker = 'UNPUSHED WORK'; Via = 'scripts\git-commit-guard.ps1'
    }
    [pscustomobject]@{ Label = 'UPSTREAM PROBLEM'; Kind = 'gate'; Demo = 'test\win32\upstream-remote.ps1'
        Marker = 'UPSTREAM PROBLEM'; Via = 'scripts\upstream-remote.ps1'
    }
    [pscustomobject]@{ Label = 'BOOT OUTAGE'; Kind = 'gate'; Demo = $Loop
        Marker = 'BOOT OUTAGE'; Via = 'scripts\go-loop-boot.ps1'
    }
    [pscustomobject]@{ Label = 'build cache over limit'; Kind = 'gate'; Demo = 'test\win32\build-cache.ps1'
        Marker = 'build cache over limit'; Via = 'scripts\build-cache.ps1'
    }
    # T1219. The build machine's verdict on the commit this branch sits on.
    # CI RED is the gate; the other four verdicts are informational BY DESIGN -
    # an in-progress run is this turn's own push still building, and "nobody has
    # built it yet" is not evidence of breakage.
    [pscustomobject]@{ Label = 'CI RED'; Kind = 'gate'; Demo = $Self
        Marker = 'CI RED'; Via = 'scripts\ci-status.ps1'
    }
    [pscustomobject]@{ Label = 'CI IN PROGRESS'; Kind = 'status'; Via = 'scripts\ci-status.ps1' }
    [pscustomobject]@{ Label = 'CI OK'; Kind = 'status'; Via = 'scripts\ci-status.ps1' }
    [pscustomobject]@{ Label = 'CI UNKNOWN'; Kind = 'status'; Via = 'scripts\ci-status.ps1' }
    [pscustomobject]@{ Label = 'CI NO VERDICT'; Kind = 'status'; Via = 'scripts\ci-status.ps1' }

    # --- parity-tasks.ps1 validate -----------------------------------------
    [pscustomobject]@{ Label = 'BAD FRONTMATTER'; Kind = 'gate'; Demo = $Self; Marker = 'BAD FRONTMATTER' }
    [pscustomobject]@{ Label = 'ID MISMATCH'; Kind = 'gate'; Demo = $Self; Marker = 'ID MISMATCH' }
    [pscustomobject]@{ Label = 'NO TITLE'; Kind = 'gate'; Demo = $Self; Marker = 'NO TITLE' }
    [pscustomobject]@{ Label = 'NO STATUS'; Kind = 'gate'; Demo = $Self; Marker = 'NO STATUS' }
    [pscustomobject]@{ Label = 'ODD STATUS'; Kind = 'gate'; Demo = $Self; Marker = 'ODD STATUS' }
    [pscustomobject]@{ Label = 'DANGLING DEP'; Kind = 'gate'; Demo = $Self; Marker = 'DANGLING DEP' }
    [pscustomobject]@{ Label = 'DEP CYCLE'; Kind = 'gate'; Demo = $Self; Marker = 'DEP CYCLE' }
    [pscustomobject]@{ Label = 'ODD SEAT'; Kind = 'gate'; Demo = $Seat; Marker = 'ODD SEAT' }
    [pscustomobject]@{ Label = 'ODD PRIORITY'; Kind = 'gate'; Demo = $Seat; Marker = 'ODD PRIORITY' }
    [pscustomobject]@{ Label = 'ODD TAG'; Kind = 'gate'; Demo = $Seat; Marker = 'ODD TAG' }
    [pscustomobject]@{ Label = 'NO PROGRESS LOG'; Kind = 'gate'; Demo = $Seat; Marker = 'NO PROGRESS LOG' }
    # T1231. A control character inside a tracked text file: invisible to a
    # reader, and a path that cannot exist to a script. validate emits the
    # headline itself rather than only relaying the scanner's, so this row is a
    # plain gate rather than a delegated one - the condition is reported from
    # validate's own text and demonstrated where the scanner is driven red.
    [pscustomobject]@{ Label = 'CONTROL CHARACTERS'; Kind = 'gate'
        Demo = 'test\win32\control-char-scan.ps1'; Marker = 'CONTROL CHARACTERS'
    }
    [pscustomobject]@{ Label = 'GUARD DUE CHECK SKIPPED'; Kind = 'hatch'; Demo = 'test\win32\guard-due.ps1'
        Marker = 'GUARD DUE CHECK SKIPPED'
    }
    # T1315. A closed USER REPORT that never asked for the release carrying its
    # fix. The gate is validate's; PUBLISH REQUESTED is the ordinary path
    # (set-status files the request itself) and PUBLISH REQUEST FAILED is the
    # loud version of the silence that made this necessary - both demonstrated
    # in section F, because a request that quietly fails to be written is
    # exactly the state the user experiences as "you said you fixed it".
    [pscustomobject]@{ Label = 'UNSHIPPED USER REPORT'; Kind = 'gate'; Demo = $Self
        Marker = 'UNSHIPPED USER REPORT'
    }
    [pscustomobject]@{ Label = 'PUBLISH REQUEST FAILED'; Kind = 'gate'; Demo = $Self
        Marker = 'PUBLISH REQUEST FAILED'
    }
    [pscustomobject]@{ Label = 'PUBLISH REQUESTED'; Kind = 'status' }
    [pscustomobject]@{ Label = 'PUSH CHECK SKIPPED'; Kind = 'hatch'; Demo = $Self; Marker = 'PUSH CHECK SKIPPED' }
    [pscustomobject]@{ Label = 'CI CHECK SKIPPED'; Kind = 'hatch'; Demo = $Self; Marker = 'CI CHECK SKIPPED' }
    # Informational by design. SPLIT DEP is a legitimate queue state (a task
    # waiting on a split parent), STRANDED WORK ACKNOWLEDGED is the ack path
    # succeeding, and the rest belong to other verbs entirely.
    [pscustomobject]@{ Label = 'SPLIT DEP'; Kind = 'status' }
    [pscustomobject]@{ Label = 'STRANDED WORK ACKNOWLEDGED'; Kind = 'status' }
    [pscustomobject]@{ Label = 'ALL PASS'; Kind = 'status' }
    [pscustomobject]@{ Label = 'NEXT'; Kind = 'status' }
    [pscustomobject]@{ Label = 'RESUME'; Kind = 'status' }
    [pscustomobject]@{ Label = 'IN FLIGHT'; Kind = 'status' }
    [pscustomobject]@{ Label = 'TODO'; Kind = 'status' }
)

# The discovery half. Gate messages in both scripts are an ALL-CAPS phrase at
# the head of an emitted string, which is a shape a regex can enumerate - so
# the completeness question is answered from the SOURCE rather than from
# somebody's memory of it.
function Get-EmittedLabels {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $seen = @{}
    foreach ($m in [regex]::Matches($text, '(?:["'']|\("")\s{0,4}([A-Z][A-Z0-9-]+(?: [A-Z0-9/-]+){0,3})(?=[:\s(])')) {
        $seen[$m.Groups[1].Value] = $true
    }
    return @($seen.Keys | Sort-Object)
}

# An "assertion line" is one that calls this suite's scorer under any of its
# three names. Requiring the marker to share a STATEMENT with one is what
# separates a demonstration from a mention in a comment.
#
# Backtick continuations are folded first: an assertion whose condition sits on
# the next line is the ordinary house style here, and a line-at-a-time scan
# would read every one of them as an undemonstrated gate.
function Test-AssertsOn {
    param([string]$Path, [string]$Marker)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $pending = ''
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $joined = $pending + ' ' + $line
        if ($line -match '`\s*$') { $pending = ($joined -replace '`\s*$', ''); continue }
        $pending = ''
        if ($joined -match '\b(Assert|AssertEq|Check)\b' -and $joined -like "*$Marker*") { return $true }
    }
    return $false
}

# --- fixtures ---------------------------------------------------------------
$Sandbox = Join-Path $env:TEMP ("ghoztty-gate-negatives-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null

# Commits carry their identity on the command line, so a box with no user.name
# configured still runs this script.
$Ident = @('-c', 'user.email=t@example.invalid', '-c', 'user.name=t', '-c', 'commit.gpgsign=false')
function Invoke-GitIn {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @Ident @GitArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n").Trim() }
}

# T883: stringify per record rather than formatting a merged stream, so what is
# read back is the command's own text at any host width.
function Invoke-Ps {
    param([string[]]$PsArgs)
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass @PsArgs 2>&1 |
            ForEach-Object { $_.ToString() })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}
function Invoke-Validate {
    param([string]$TaskDir, [string[]]$Extra = @())
    return Invoke-Ps (@('-File', $TaskScript, 'validate', '-TaskDir', $TaskDir) + $Extra)
}

function Write-Ascii {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}
# A well-formed task file, with one field optionally dropped or overridden, so
# each fixture below differs from a GOOD file in exactly the one way it is
# measuring.
function New-TaskFile {
    param(
        [string]$Dir, [string]$Id, [string]$Deps = '', [string]$Status = 'todo',
        [string]$DeclaredId, [switch]$NoTitle, [switch]$NoStatus
    )
    $fm = @('---')
    $fm += ("id: {0}" -f $(if ($DeclaredId) { $DeclaredId } else { $Id }))
    if (-not $NoTitle) { $fm += ("title: `"fixture {0}`"" -f $Id) }
    $fm += ("deps: [{0}]" -f $Deps)
    if (-not $NoStatus) { $fm += ("status: `"{0}`"" -f $Status) }
    $fm += @('commits: []', 'seat: "win"', '---', '', ("# {0} - fixture" -f $Id), '', '## Progress log', '')
    Write-Ascii (Join-Path $Dir "$Id.md") $fm
}
# One directory per case: a fixture holding several defects at once could not
# tell "validate names THIS one" from "validate names SOMETHING".
function New-CaseDir {
    param([string]$Name)
    $d = Join-Path $Sandbox "tasks-$Name"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    New-TaskFile -Dir $d -Id 'T10'          # the healthy neighbour
    return $d
}

try {

    # =======================================================================
    Say ''
    Say 'A. the registry: every condition either gate reports is triaged, and every gate has a demonstration'
    # =======================================================================

    $declared = @{}
    foreach ($row in $Registry) { $declared[$row.Label] = $row }
    Check 'A0 the registry has rows at all' ($declared.Count -ge 25) "declared $($declared.Count)"

    $discovered = @{}
    foreach ($p in @($ExecScript, $TaskScript)) {
        foreach ($l in (Get-EmittedLabels $p)) { $discovered[$l] = $p }
    }
    Say ("    discovered {0} label(s) across go-loop-exec.ps1 + parity-tasks.ps1" -f $discovered.Count)
    Check 'A1 discovery found the gate vocabulary (premise: the scan still works)' `
        ($discovered.Count -ge 25) "found $($discovered.Count)"

    # THE POINT OF THE SECTION. A label neither declared a gate nor declared
    # informational is a condition nobody triaged - which is how a check that
    # cannot fail gets shipped.
    $undeclared = @($discovered.Keys | Where-Object { -not $declared.ContainsKey($_) } | Sort-Object)
    Check 'A2 every label the two gates emit is declared here' ($undeclared.Count -eq 0) `
        ("undeclared: " + ($undeclared -join ', '))

    # ...and the other direction: a row whose label no longer appears in either
    # script is a demonstration guarding nothing.
    $rotted = @($Registry | Where-Object { -not $_.Via -and -not $discovered.ContainsKey($_.Label) } |
            ForEach-Object { $_.Label } | Sort-Object)
    Check 'A3 no registry row outlived the label it describes' ($rotted.Count -eq 0) `
        ("no longer emitted: " + ($rotted -join ', '))

    $needDemo = @($Registry | Where-Object { $_.Kind -eq 'gate' -or $_.Kind -eq 'hatch' })
    Check 'A4 the registry classifies most conditions as gates, not status lines' `
        ($needDemo.Count -ge 15) "gates+hatches: $($needDemo.Count)"

    $noFile = @(); $noAssert = @()
    foreach ($row in $needDemo) {
        $abs = Join-Path $Repo $row.Demo
        if (-not (Test-Path -LiteralPath $abs)) { $noFile += ("{0} -> {1}" -f $row.Label, $row.Demo); continue }
        if (-not (Test-AssertsOn -Path $abs -Marker $row.Marker)) {
            $noAssert += ("{0} -> {1}" -f $row.Label, $row.Demo)
        }
    }
    Check 'A5 every gate names a demonstration file that exists' ($noFile.Count -eq 0) ($noFile -join '; ')
    Check 'A6 ...and that file ASSERTS on the label (not merely mentions it)' ($noAssert.Count -eq 0) `
        ($noAssert -join '; ')

    # A delegated row describes something CLAIM surfaces through another
    # script. If claim stops running that script the condition stops being
    # reported, and the row would still look satisfied - so the wiring is
    # asserted too.
    $execText = [System.IO.File]::ReadAllText($ExecScript, [System.Text.Encoding]::UTF8)
    $unwired = @()
    foreach ($row in @($Registry | Where-Object { $_.Via })) {
        $leaf = Split-Path $row.Via -Leaf
        if ($execText -notmatch [regex]::Escape($leaf)) { $unwired += ("{0} via {1}" -f $row.Label, $leaf) }
    }
    Check 'A7 every delegated gate is still reachable from claim' ($unwired.Count -eq 0) ($unwired -join '; ')

    # The teeth for A2 and A6. This section is itself a gate, so it owes the
    # same demonstration it demands of everything else: a tomorrow-gate is
    # synthesized into a copy of the claim script and must come back
    # UNDECLARED, and a marker that only appears in prose must not count as a
    # demonstration. Without these two, "every label is declared" could be
    # satisfied by a scan that had quietly stopped finding labels.
    $teethDir = Join-Path $Sandbox 'teeth'
    New-Item -ItemType Directory -Force -Path $teethDir | Out-Null
    $teethExec = Join-Path $teethDir 'go-loop-exec.ps1'
    Copy-Item -LiteralPath $ExecScript -Destination $teethExec -Force
    Add-Content -LiteralPath $teethExec -Value '            "  TOMORROW GATE: a condition nobody triaged"'
    $teethLabels = @(Get-EmittedLabels $teethExec)
    Check 'A8 a gate added tomorrow is DISCOVERED by the scan' `
        ($teethLabels -contains 'TOMORROW GATE') ("found: " + ($teethLabels -join ', '))
    Check 'A9 ...and comes back undeclared, which is what fails A2' `
        (-not $declared.ContainsKey('TOMORROW GATE'))

    $proseOnly = Join-Path $teethDir 'prose-only.ps1'
    Write-Ascii $proseOnly @('# a comment that merely MENTIONS GATE the label', 'Check ''x'' $true')
    Check 'A10 a label that only appears in prose is not a demonstration' `
        (-not (Test-AssertsOn -Path $proseOnly -Marker 'MENTIONS GATE'))

    # =======================================================================
    Say ''
    Say 'B. parity-tasks.ps1 validate, driven RED - one fixture per branch'
    # =======================================================================

    # The positive control first: if a clean fixture did not pass, every red
    # below would be worthless.
    $clean = New-CaseDir 'clean'
    New-TaskFile -Dir $clean -Id 'T11' -Deps '"T10"'
    $r = Invoke-Validate $clean
    Check 'B0 a clean fixture validates green' ($r.Code -eq 0 -and $r.Text -match 'ALL PASS') `
        "exit=$($r.Code): $($r.Text)"

    $d = New-CaseDir 'frontmatter'
    Write-Ascii (Join-Path $d 'T21.md') @('# T21 - no frontmatter at all', '', 'body only.')
    $r = Invoke-Validate $d
    Check 'B1 a file with no frontmatter fails, and is named' `
        ($r.Code -ne 0 -and $r.Text -match 'BAD FRONTMATTER: T21\.md') "exit=$($r.Code): $($r.Text)"

    $d = New-CaseDir 'idmismatch'
    New-TaskFile -Dir $d -Id 'T22' -DeclaredId 'T99'
    $r = Invoke-Validate $d
    Check 'B2 a file whose id disagrees with its name fails' `
        ($r.Code -ne 0 -and $r.Text -match 'ID MISMATCH: T22\.md declares id=T99') "exit=$($r.Code): $($r.Text)"

    $d = New-CaseDir 'notitle'
    New-TaskFile -Dir $d -Id 'T23' -NoTitle
    $r = Invoke-Validate $d
    Check 'B3 a titleless task fails' ($r.Code -ne 0 -and $r.Text -match 'NO TITLE: T23\.md') `
        "exit=$($r.Code): $($r.Text)"

    $d = New-CaseDir 'nostatus'
    New-TaskFile -Dir $d -Id 'T24' -NoStatus
    $r = Invoke-Validate $d
    Check 'B4 a statusless task fails' ($r.Code -ne 0 -and $r.Text -match 'NO STATUS: T24\.md') `
        "exit=$($r.Code): $($r.Text)"

    $d = New-CaseDir 'oddstatus'
    New-TaskFile -Dir $d -Id 'T25' -Status 'wibble'
    $r = Invoke-Validate $d
    Check 'B5 a status outside the set fails, and the value is quoted back' `
        ($r.Code -ne 0 -and $r.Text -match "ODD STATUS: T25 = 'wibble'") "exit=$($r.Code): $($r.Text)"

    $d = New-CaseDir 'dangling'
    New-TaskFile -Dir $d -Id 'T26' -Deps '"T404"'
    $r = Invoke-Validate $d
    Check 'B6 a dep naming a task that does not exist fails' `
        ($r.Code -ne 0 -and $r.Text -match 'DANGLING DEP: T26 -> T404') "exit=$($r.Code): $($r.Text)"

    # T1133's own addition to validate. A ring is the one tracker defect where
    # every file reads correctly on its own, so it is checked over the graph.
    $d = New-CaseDir 'cycle'
    New-TaskFile -Dir $d -Id 'T27' -Deps '"T28"'
    New-TaskFile -Dir $d -Id 'T28' -Deps '"T27"'
    $r = Invoke-Validate $d
    Check 'B7 a two-task dependency ring fails' `
        ($r.Code -ne 0 -and $r.Text -match 'DEP CYCLE: T27 -> T28 -> T27') "exit=$($r.Code): $($r.Text)"
    Check 'B8 ...reported once for the ring, not once per member' `
        (@([regex]::Matches($r.Text, 'DEP CYCLE:')).Count -eq 1) $r.Text

    $d = New-CaseDir 'selfdep'
    New-TaskFile -Dir $d -Id 'T29' -Deps '"T29"'
    $r = Invoke-Validate $d
    Check 'B9 a task that depends on itself fails' `
        ($r.Code -ne 0 -and $r.Text -match 'DEP CYCLE: T29 -> T29') "exit=$($r.Code): $($r.Text)"

    # A ring further down a chain must be found from any entry point, not only
    # when the walk happens to start inside it.
    $d = New-CaseDir 'deepcycle'
    New-TaskFile -Dir $d -Id 'T30' -Deps '"T31"'
    New-TaskFile -Dir $d -Id 'T31' -Deps '"T32"'
    New-TaskFile -Dir $d -Id 'T32' -Deps '"T31"'
    $r = Invoke-Validate $d
    Check 'B10 a ring reached through a chain is still found' `
        ($r.Code -ne 0 -and $r.Text -match 'DEP CYCLE: T31 -> T32 -> T31') "exit=$($r.Code): $($r.Text)"

    # The escape hatch must say it was used - the whole reason a hatch is
    # allowed is that the commit made under it can be explained afterwards.
    $d = New-CaseDir 'hatch'
    $env:GHOZTTY_UNPUSHED_REPO = $Repo
    try {
        $r = Invoke-Validate $d @('-NoPushCheck')
    }
    finally { Remove-Item Env:GHOZTTY_UNPUSHED_REPO -ErrorAction SilentlyContinue }
    Check 'B11 -NoPushCheck announces itself rather than passing quietly' `
        ($r.Text -match 'PUSH CHECK SKIPPED') $r.Text

    # =======================================================================
    Say ''
    Say 'C. go-loop-exec.ps1 claim, driven RED against a throwaway repo'
    # =======================================================================

    # `ensure` fetches when upstream/main does not resolve, and a fixture with a
    # bare `upstream` remote would drag GitHub into an acceptance run. Wiring
    # the ref and the fetch stamp by hand means the claim below is offline-safe
    # AND still reaches a real verdict from the delegate.
    function Set-UpstreamOffline {
        param([string]$At)
        $url = 'https://github.com/ghostty-org/ghostty.git'
        [void](Invoke-GitIn $At @('remote', 'add', 'upstream', $url))
        $head = (Invoke-GitIn $At @('rev-parse', 'HEAD')).Text
        [void](Invoke-GitIn $At @('update-ref', 'refs/remotes/upstream/main', $head))
        $gitDir = (Invoke-GitIn $At @('rev-parse', '--git-dir')).Text
        if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $At $gitDir }
        Write-Ascii (Join-Path $gitDir 'ghoztty-upstream-fetch.json') `
        @('{', ('  "lastFetch": "{0}",' -f (Get-Date).ToString('o')),
            '  "remote": "upstream",', ('  "url": "{0}"' -f $url), '}')
    }
    function New-RepoFixture {
        param([string]$Name)
        $at = Join-Path $Sandbox $Name
        New-Item -ItemType Directory -Force -Path $at | Out-Null
        [void](Invoke-GitIn $at @('init', '-q', '.'))
        Write-Ascii (Join-Path $at '.gitignore') @('temp/')
        [void](Invoke-GitIn $at @('add', '.gitignore'))
        [void](Invoke-GitIn $at @('commit', '-qm', 'fixture'))
        Set-UpstreamOffline $at
        return $at
    }
    function Invoke-Claim {
        param([string]$At, [string]$Pane)
        return Invoke-Ps @('-File', $ExecScript, 'claim', '-Repo', $At, '-PaneId', $Pane,
            '-GhozttyExe', $Stand, '-NoClose', '-NoSelfClose')
    }

    $red = New-RepoFixture 'repo-red'
    Write-Ascii (Join-Path $red 'orphan.txt') @('a dead turn left this behind')
    $r = Invoke-Claim $red 'GATE-NEG-RED-0001'
    Check 'C0 the claim still exits 0 - it REPORTS, it must never wedge the loop' ($r.Code -eq 0) `
        "exit=$($r.Code)"
    Check 'C1 a dirty tree at claim is reported as stranded work, by path' `
        ($r.Text -match 'STRANDED WORK: 1 path' -and $r.Text -match 'orphan\.txt') $r.Text
    Check 'C2 a branch with no upstream is reported as unpushed' `
        ($r.Text -match 'UNPUSHED WORK') $r.Text
    Check 'C3 a repo whose upstream wiring cannot be verified reports a problem' `
        ($r.Text -match 'UPSTREAM PROBLEM') $r.Text
    Check 'C4 the claim never claims the tree is clean while it is not' `
        ($r.Text -notmatch 'tree clean at claim') $r.Text

    # The teeth for C1: what claim REPORTS, validate must FAIL on. This is the
    # two-ended arrangement the loop depends on, measured end to end.
    $env:GHOZTTY_STRANDED_REPO = $red
    try {
        $r2 = Invoke-Validate (New-CaseDir 'stranded')
    }
    finally { Remove-Item Env:GHOZTTY_STRANDED_REPO -ErrorAction SilentlyContinue }
    Check 'C5 validate then FAILS on the same stranded path' `
        ($r2.Code -ne 0 -and $r2.Text -match 'STRANDED WORK' -and $r2.Text -match 'orphan\.txt') `
        "exit=$($r2.Code): $($r2.Text)"

    # The positive control: a clean, pushed repo must produce the green lines,
    # or the reds above prove only that the claim always complains.
    $green = New-RepoFixture 'repo-green'
    $bare = Join-Path $Sandbox 'origin.git'
    [void](Invoke-GitIn $Sandbox @('init', '-q', '--bare', $bare))
    [void](Invoke-GitIn $green @('remote', 'add', 'origin', $bare))
    $branch = (Invoke-GitIn $green @('rev-parse', '--abbrev-ref', 'HEAD')).Text
    [void](Invoke-GitIn $green @('push', '-q', '-u', 'origin', $branch))
    $r = Invoke-Claim $green 'GATE-NEG-GREEN-0001'
    Check 'C6 a clean tree claims clean' ($r.Text -match 'tree clean at claim') $r.Text
    Check 'C7 a pushed branch claims push clean' ($r.Text -match 'push clean') $r.Text
    Check 'C8 ...and neither red line appears over a healthy repo' `
        ($r.Text -notmatch 'STRANDED WORK' -and $r.Text -notmatch 'UNPUSHED WORK') $r.Text

    # =======================================================================
    Say ''
    Say 'E. the CI verdict (T1219): reported by claim, FAILED ON by validate'
    # =======================================================================

    # The payloads are `gh run list --json ...` shaped, so the parsing and the
    # verdict below are the script's real ones - only the transport is replaced.
    # This is the whole reason a red CI can be demonstrated on a box whose CI is
    # green: the alternative is pushing a broken commit to find out.
    $CiScript = Join-Path $Repo 'scripts\ci-status.ps1'
    $ciDir = Join-Path $Sandbox 'ci'
    New-Item -ItemType Directory -Force -Path $ciDir | Out-Null
    function New-CiPayload {
        param([string]$Name, [string[]]$Lines)
        $path = Join-Path $ciDir "$Name.json"
        Write-Ascii $path $Lines
        return $path
    }
    function Invoke-Ci {
        param([string]$Payload, [string[]]$Extra = @())
        return Invoke-Ps (@('-File', $CiScript, 'check', '-Sha', 'fixture01',
                '-Branch', 'fixture-branch', '-RunsJsonFile', $Payload) + $Extra)
    }

    $ciRed = New-CiPayload 'red' @(
        '[{"conclusion":"skipped","databaseId":1,"headSha":"fixture01","status":"completed",',
        '  "url":"u1","workflowName":"Nix"},',
        ' {"conclusion":"failure","databaseId":2,"headSha":"fixture01","status":"completed",',
        '  "url":"https://example.invalid/runs/2","workflowName":"Fork CI",',
        '  "jobs":[{"name":"windows-cross","conclusion":"failure"},',
        '          {"name":"lint","conclusion":"success"}]}]')
    $ciProg = New-CiPayload 'in-progress' @(
        '[{"conclusion":"","databaseId":3,"headSha":"fixture01","status":"in_progress",',
        '  "url":"u3","workflowName":"Fork CI"}]')
    $ciOk = New-CiPayload 'ok' @(
        '[{"conclusion":"success","databaseId":4,"headSha":"fixture01","status":"completed",',
        '  "url":"u4","workflowName":"Fork CI"}]')
    $ciOther = New-CiPayload 'other-sha' @(
        '[{"conclusion":"failure","databaseId":5,"headSha":"someoneelse","status":"completed",',
        '  "url":"u5","workflowName":"Fork CI"}]')

    $r = Invoke-Ci $ciRed
    Check 'E0 a failing run scores CI RED, naming the workflow and the run' `
        ($r.Code -eq 8 -and $r.Text -match 'CI RED' -and $r.Text -match 'Fork CI' -and
        $r.Text -match 'runs/2') "exit=$($r.Code): $($r.Text)"
    Check 'E1 ...and names the job that failed, not just the run' `
        ($r.Text -match 'failing job: windows-cross') $r.Text
    Check 'E2 ...and does not name a job that passed' ($r.Text -notmatch 'failing job: lint') $r.Text

    $r = Invoke-Ci $ciRed @('-Quiet')
    Check 'E3 -Quiet still speaks when the verdict is red' `
        ($r.Code -eq 8 -and $r.Text -match 'CI RED') "exit=$($r.Code): $($r.Text)"

    # The three verdicts that must NOT fail, or the gate stops the loop at every
    # boundary over its own in-flight build.
    $r = Invoke-Ci $ciProg
    Check 'E4 a run still going is reported and does NOT fail' `
        ($r.Code -eq 0 -and $r.Text -match 'CI IN PROGRESS') "exit=$($r.Code): $($r.Text)"
    $r = Invoke-Ci $ciOther
    Check 'E5 a red run for a DIFFERENT commit is not this branch head verdict' `
        ($r.Code -eq 0 -and $r.Text -match 'CI UNKNOWN') "exit=$($r.Code): $($r.Text)"
    $r = Invoke-Ci $ciOk @('-Quiet')
    Check 'E6 a green run is silent under -Quiet and exits 0' `
        ($r.Code -eq 0 -and -not ($r.Text -match 'CI ')) "exit=$($r.Code): $($r.Text)"

    # The teeth: what the script concludes, VALIDATE must fail on - the same
    # two-ended arrangement measured for stranded work in C5.
    $env:GHOZTTY_CI_RUNS_JSON = $ciRed
    $env:GHOZTTY_CI_SHA = 'fixture01'
    try {
        $r = Invoke-Validate (New-CaseDir 'ci-red')
        $rHatch = Invoke-Validate (New-CaseDir 'ci-hatch') @('-NoCiCheck')
        $env:GHOZTTY_CI_RUNS_JSON = $ciProg
        $rProg = Invoke-Validate (New-CaseDir 'ci-prog')
    }
    finally {
        Remove-Item Env:GHOZTTY_CI_RUNS_JSON -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_CI_SHA -ErrorAction SilentlyContinue
    }
    Check 'E7 validate FAILS on a red run, and says which workflow and run' `
        ($r.Code -ne 0 -and $r.Text -match 'CI RED' -and $r.Text -match 'runs/2') `
        "exit=$($r.Code): $($r.Text)"
    Check 'E8 the hatch is a hatch: -NoCiCheck passes and ANNOUNCES itself' `
        ($rHatch.Code -eq 0 -and $rHatch.Text -match 'CI CHECK SKIPPED') `
        "exit=$($rHatch.Code): $($rHatch.Text)"
    Check 'E9 an in-progress run does not fail validate' `
        ($rProg.Code -eq 0 -and $rProg.Text -notmatch 'CI RED') "exit=$($rProg.Code): $($rProg.Text)"

    # And the report side, end to end: claim surfaces the verdict at the top of
    # the turn. A7 proves claim still runs the delegate; this proves the text a
    # human reads actually carries the bad news.
    $env:GHOZTTY_CI_RUNS_JSON = $ciRed
    $env:GHOZTTY_CI_SHA = 'fixture01'
    try { $rClaim = Invoke-Claim $green 'GATE-NEG-GREEN-0001' }
    finally {
        Remove-Item Env:GHOZTTY_CI_RUNS_JSON -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_CI_SHA -ErrorAction SilentlyContinue
    }
    Check 'E10 claim REPORTS CI RED at the top of the turn' `
        ($rClaim.Text -match 'CI RED') $rClaim.Text
    Check 'E11 ...and still exits 0, because a claim must never wedge the loop' `
        ($rClaim.Code -eq 0) "exit=$($rClaim.Code)"

    # =======================================================================
    Say ''
    Say 'F. T1315: closing a task the user reported asks for the release that carries the fix'
    # =======================================================================
    #
    # T1294 made a same-day publish possible and left the ASKING to a turn's
    # memory. This section measures that it is no longer remembered: the
    # request is filed by the close itself, it is NOT filed for an ordinary
    # task, and a close that failed to file one is caught rather than passing
    # quietly. The last arm is the one that matters - from where the user
    # sits, a fix nobody published and a fix nobody made are the same thing.

    $fDir = Join-Path $Sandbox 'tasks-userreport'
    New-Item -ItemType Directory -Force -Path $fDir | Out-Null
    $fReq = Join-Path $Sandbox 'publish-request'
    function Invoke-Task { param([string[]]$A) return Invoke-Ps (@('-File', $TaskScript) + $A + @('-TaskDir', $fDir)) }

    Invoke-Task @('new', '-Title', 'the installer dies silently', '-UserReport', '-Tags', 'fix') | Out-Null
    Invoke-Task @('new', '-Title', 'an ordinary infra chore', '-Tags', 'infra') | Out-Null
    $fReported = Join-Path $fDir 'T1.md'
    $fOrdinary = Join-Path $fDir 'T2.md'
    Check 'F0 new -UserReport records that a user asked for this' `
        ((Test-Path -LiteralPath $fReported) -and
        ([System.IO.File]::ReadAllText($fReported) -match '(?m)^user-report:\s*true\s*$')) `
        'T1.md carries no user-report flag'
    Check 'F1 ...and an ordinary task does not carry the flag' `
        ((Test-Path -LiteralPath $fOrdinary) -and
        ([System.IO.File]::ReadAllText($fOrdinary) -notmatch '(?m)^user-report:')) `
        'T2.md was flagged as a user report'

    # The arm where it does NOT fire: closing an ordinary task must not mint a
    # release request, or the one-a-day cadence becomes publish-per-commit.
    $env:GHOZTTY_PUBLISH_REQUEST_PATH = $fReq
    try {
        $rOrd = Invoke-Task @('set-status', 'T2', '-Status', 'done')
        $ordWrote = Test-Path -LiteralPath $fReq
        $rRep = Invoke-Task @('set-status', 'T1', '-Status', 'done')
        $repWrote = Test-Path -LiteralPath $fReq
        $reqText = if ($repWrote) { [System.IO.File]::ReadAllText($fReq) } else { '' }
    }
    finally { Remove-Item Env:GHOZTTY_PUBLISH_REQUEST_PATH -ErrorAction SilentlyContinue }

    Check 'F2 closing an ordinary task files no publish request' `
        ((-not $ordWrote) -and $rOrd.Text -notmatch 'PUBLISH REQUESTED') "$($rOrd.Text)"
    Check 'F3 closing a user report scores PUBLISH REQUESTED' `
        ($rRep.Text -match 'PUBLISH REQUESTED') "$($rRep.Text)"
    Check 'F4 ...and the request names the task, so the digest can quote it' `
        ($repWrote -and $reqText -match 'T1' -and $reqText -match 'installer dies') $reqText
    Check 'F5 ...and the receipt lands in the task progress log' `
        ([System.IO.File]::ReadAllText($fReported) -match '(?mi)^-.*publish request filed') `
        'no receipt in T1.md'

    # The gate with teeth. A hand-edited status, a retro-flag, or a request
    # that could not be written all end here.
    $gDir = New-CaseDir 'userreport-unshipped'
    Write-Ascii (Join-Path $gDir 'T20.md') @(
        '---', 'id: T20', 'title: "a closed report nobody published"', 'deps: []',
        'status: "done"', 'commits: []', 'seat: "win"', 'user-report: true', '---',
        '', '# T20 - fixture', '', '## Progress log', '', '- 2026-09-04 00:00: status: todo -> done'
    )
    $rGate = Invoke-Validate $gDir
    Check 'F6 validate FAILS with UNSHIPPED USER REPORT, naming the task' `
        ($rGate.Code -ne 0 -and $rGate.Text -match 'UNSHIPPED USER REPORT' -and $rGate.Text -match 'T20') `
        "exit=$($rGate.Code): $($rGate.Text)"
    # The receipt is what clears it, so a report that WAS published stops
    # failing without anyone editing the gate.
    Invoke-Ps @('-File', $TaskScript, 'note', 'T20', '-Text', 'publish request filed: T20 by hand', '-TaskDir', $gDir) | Out-Null
    $rGate3 = Invoke-Validate $gDir
    Check 'F7 ...and a recorded publish request clears it' `
        ($rGate3.Code -eq 0 -and $rGate3.Text -notmatch 'UNSHIPPED USER REPORT') `
        "exit=$($rGate3.Code): $($rGate3.Text)"

    # A request that cannot be written must be LOUD. The sandbox path is given
    # a parent that is a FILE, so daily-publish.ps1 cannot create the directory
    # it needs and answers non-zero - the shape of a request silently lost.
    $blockFile = Join-Path $Sandbox 'not-a-dir'
    Write-Ascii $blockFile @('this is a file, not a directory')
    $env:GHOZTTY_PUBLISH_REQUEST_PATH = (Join-Path $blockFile 'req')
    try {
        Invoke-Task @('new', '-Title', 'another user report', '-UserReport') | Out-Null
        $rFail = Invoke-Task @('set-status', 'T3', '-Status', 'done')
    }
    finally { Remove-Item Env:GHOZTTY_PUBLISH_REQUEST_PATH -ErrorAction SilentlyContinue }
    Check 'F8 a request that cannot be written scores PUBLISH REQUEST FAILED' `
        ($rFail.Text -match 'PUBLISH REQUEST FAILED') "$($rFail.Text)"
    Check 'F9 ...and leaves no receipt, so validate refuses the close' `
        ((Invoke-Validate $fDir).Code -ne 0) 'validate passed a close whose request was lost'

    # Retro-flagging: triage learns a filed task came from a user report.
    Invoke-Task @('new', '-Title', 'filed before anybody said who asked') | Out-Null
    $rFlag = Invoke-Task @('set-priority', 'T4', '-Priority', 'P0', '-UserReport')
    Check 'F10 set-priority -UserReport flags a task triage recognises' `
        ([System.IO.File]::ReadAllText((Join-Path $fDir 'T4.md')) -match '(?m)^user-report:\s*true\s*$') `
        "$($rFlag.Text)"

    # =======================================================================
    Say ''
    Say 'D. the rule is written down where the next gate author will read it'
    # =======================================================================

    $goPath = Join-Path $Repo 'go.md'
    Check 'D0 go.md is where it is expected' (Test-Path -LiteralPath $goPath)
    $goText = ''
    if (Test-Path -LiteralPath $goPath) {
        $goText = [System.IO.File]::ReadAllText($goPath, [System.Text.Encoding]::UTF8)
    }
    Check 'D1 go.md states the rule' `
        ($goText -match 'ships with the demonstration that it can fail') "go.md does not state it"
    Check 'D2 ...and names this harness, so the rule has somewhere to point' `
        ($goText -match 'gate-negatives\.ps1') "go.md does not name test\win32\gate-negatives.ps1"

    if ($NegativeControl) {
        Say ''
        Say 'NEGATIVE CONTROL: asserting the registry is EMPTY - a wired tree MUST fail this'
        Check 'N1 the registry declares no conditions (inverted)' ($declared.Count -eq 0) `
            "declared $($declared.Count)"
    }

    Complete-TestBody  # T1039: the run reached the end of its body
}
catch {
    # A crash mid-run must be scored, not fallen through: an unwind that
    # reached the verdict with the failure count untouched is the exact shape
    # this whole harness exists to distrust.
    Write-Host ("FAIL  harness crashed: {0}" -f $_.Exception.Message)
    Write-Host ("    at {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    $script:failures++
}
finally {
    Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783). A run with a red
# assertion - or the -NegativeControl run, which is red by construction -
# deliberately leaves the stamp alone.
if ($script:failures -eq 0 -and -not $NegativeControl -and (Test-Path -LiteralPath $DueScript)) {
    Invoke-Ps @('-File', $DueScript, 'update', '-Guard', 'gate-negatives', '-Repo', $Repo) |
        ForEach-Object { $_.Text } | ForEach-Object { if ($_) { "  $_" } }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -MinPass 25
