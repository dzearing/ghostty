<#
.SYNOPSIS
  Open decisions the parity loop needs a human call on, one file per decision
  under docs/design/windows-parity-decisions/.

.DESCRIPTION
  The loop never blocks to ask a question (go.md: investigate, assume, keep
  going). This is the other half of that rule: when the loop makes a call the
  user might want to overturn, it records the call HERE - with the options it
  weighed and what it assumed meanwhile - and carries on. The dashboard shows
  open decisions at the top of the Activity feed; resolving one folds the
  answer back into the linked task.

  So a decision is never a stop-and-wait. It is a receipt for an assumption,
  reviewable later, and reversible while it is still cheap.

  Option format (user directive, 2026-08-05): every option's detail carries
  "Pros: ... Cons: ..." and, where a con can be reduced, "Mitigation: ..."
  naming the extra work that reduces it (file that work as a parity task if
  the option is chosen). Exactly one option's label ends in "(Recommended)":
  the best balance of robustness, performance, user experience, scale over
  time, and stability with the fewest sacrifices. Implementation effort and
  time are never part of that balance - "cheapest" and "fastest" are not
  pros.

  One file per decision, same reasoning as the task files: two agents can file
  concurrently without touching each other's writes, and ids are allocated by
  creating the file atomically.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
  scripts\parity-decisions.ps1 new -Title "Take main's send-keys fix by merge or cherry-pick?" `
      -Task T428 -Assumed "cherry-pick" `
      -Options "Merge origin/main (Recommended)::Pros: branch stays current. Cons: 42 commits of blast radius. Mitigation: full floor lanes plus P1-P3 after the merge;;Cherry-pick 9bac0250f::Pros: minimal diff. Cons: branch keeps drifting from main, and the next conflict is bigger" `
      -Why "The fix is on main only and this branch is 42 behind."

.EXAMPLE
  scripts\parity-decisions.ps1 list -Status open
  scripts\parity-decisions.ps1 show D1
  scripts\parity-decisions.ps1 resolve D1 -Answer 2 -Note "do the full merge"

.EXAMPLE
  scripts\parity-decisions.ps1 validate

  T566. The task files have had a gate since the day they became files
  (parity-tasks.ps1 validate, run before every tracker commit); the decisions
  beside them had none, so a decision with no task link, a status outside
  open/resolved, an option list with no Pros/Cons or a recommendation flag on
  none of its options was only ever found by a human noticing the Activity feed
  rendering it wrong. This applies the same rules to the whole directory, and
  parity-tasks.ps1 validate relays it, so it runs on the same gate.

  The option-format rules (Pros/Cons on every option, exactly one
  "(Recommended)" and it listed first) date from the user's 2026-08-05
  directive. Decisions minted before it are reported as LEGACY OPTIONS and do
  not fail the run - rewriting a resolved decision to satisfy a rule that did
  not exist when it was filed would falsify the record. Every decision filed
  since is held to them.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('list', 'show', 'new', 'resolve', 'validate')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Id,

    [string]$Title,
    [string]$Task,
    [ValidateSet('assumption', 'question', 'blocker')]
    [string]$Kind = 'assumption',
    [string]$Assumed,
    # ";;" splits options, "::" splits the segments of one option. The first
    # segment is the label; each later segment is either "Pros: a | b",
    # "Cons: c | d", "Mitigation: e" (items split on "|"), or - with no such
    # prefix - legacy free-text detail. NOT commas: under -File, PowerShell
    # hands an array parameter over as one string, and labels contain commas.
    #   "Do X (Recommended)::Pros: fast | safe::Cons: complex::Mitigation: design pass first;;Do Y::Pros: simple::Cons: does not scale"
    # Exactly one label should end in "(Recommended)" - see the DESCRIPTION.
    [string]$Options,
    [string]$Why,
    [string]$Status,
    # The chosen option: its 1-based number, or its key (o1, o2, ...).
    [string]$Answer,
    [string]$Note,

    # `validate` prints only the problem lines, no summary and no ALL PASS.
    # parity-tasks.ps1's validate relays those lines under its own headline, so
    # a second verdict line inside them would read as a second gate's answer.
    [switch]$Quiet,

    # Escape hatch so tests can drive a fixture directory.
    [string]$DecisionDir,
    [string]$TaskDir
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $DecisionDir) { $DecisionDir = Join-Path $RepoRoot 'docs\design\windows-parity-decisions' }
if (-not $TaskDir) { $TaskDir = Join-Path $RepoRoot 'docs\design\windows-parity-tasks' }
if (-not (Test-Path $DecisionDir)) { New-Item -ItemType Directory -Force $DecisionDir | Out-Null }

function Read-Text {
    param([string]$Path)
    # -Encoding UTF8 decodes BOM-less UTF-8 correctly; the default reads it as
    # ANSI and mojibakes every em dash in the file.
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Write-Text {
    param([string]$Path, [string]$Content)
    # No BOM: these files are read by node and by git diff.
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function ConvertFrom-DecisionFile {
    param([string]$Path)
    $text = Read-Text $Path
    $obj = [ordered]@{
        Id = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        Title = ''; Task = ''; Kind = 'assumption'; Status = 'open'
        Created = ''; Assumed = ''; Answer = ''; AnsweredAt = ''; Note = ''
        Options = @(); Path = $Path
    }
    $lines = $text -split "`r?`n"
    $inFm = $false; $inOpts = $false; $curList = $null
    foreach ($line in $lines) {
        if ($line -eq '---') {
            if (-not $inFm) { $inFm = $true; continue }
            break
        }
        if (-not $inFm) { continue }
        if ($line -match '^\s*-\s+key:\s*(.+)$' -and $inOpts) {
            $obj.Options += [ordered]@{ key = $Matches[1].Trim(); label = ''; detail = ''; pros = @(); cons = @(); mitigation = @() }
            $curList = $null
            continue
        }
        if ($inOpts -and $line -match '^\s+label:\s*(.+)$' -and $obj.Options.Count -gt 0) {
            $obj.Options[-1].label = ($Matches[1].Trim() | ConvertFrom-Json); $curList = $null; continue
        }
        if ($inOpts -and $line -match '^\s+detail:\s*(.+)$' -and $obj.Options.Count -gt 0) {
            $obj.Options[-1].detail = ($Matches[1].Trim() | ConvertFrom-Json); $curList = $null; continue
        }
        if ($inOpts -and $line -match '^\s+(pros|cons|mitigation):\s*$' -and $obj.Options.Count -gt 0) {
            $curList = $Matches[1]; continue
        }
        if ($inOpts -and $curList -and $line -match '^\s+-\s+(".*")\s*$' -and $obj.Options.Count -gt 0) {
            $obj.Options[-1][$curList] = @($obj.Options[-1][$curList]) + @(($Matches[1] | ConvertFrom-Json))
            continue
        }
        if ($line -match '^options:') { $inOpts = $true; $curList = $null; continue }
        if ($line -match '^([A-Za-z]+):\s*(.*)$') {
            $inOpts = $false
            $k = $Matches[1]; $v = $Matches[2].Trim()
            if ($v -eq 'null' -or $v -eq '') { $v = '' }
            elseif ($v.StartsWith('"')) { $v = ($v | ConvertFrom-Json) }
            switch ($k) {
                'title'      { $obj.Title = $v }
                'task'       { $obj.Task = $v }
                'kind'       { $obj.Kind = $v }
                'status'     { $obj.Status = $v }
                'created'    { $obj.Created = $v }
                'assumed'    { $obj.Assumed = $v }
                'answer'     { $obj.Answer = $v }
                'answeredAt' { $obj.AnsweredAt = $v }
                'note'       { $obj.Note = $v }
            }
        }
    }
    return [pscustomobject]$obj
}

function Get-AllDecisions {
    $out = @()
    foreach ($f in (Get-ChildItem -LiteralPath $DecisionDir -Filter 'D*.md' -File -ErrorAction SilentlyContinue)) {
        $out += (ConvertFrom-DecisionFile $f.FullName)
    }
    return ($out | Sort-Object { [int]([regex]::Match($_.Id, '\d+').Value) })
}

function Get-DecisionPath {
    param([string]$Wanted)
    $norm = $Wanted.Trim()
    if ($norm -notmatch '^[Dd]\d+$') { $norm = 'D' + ($norm -replace '\D', '') }
    $p = Join-Path $DecisionDir ("D" + [regex]::Match($norm, '\d+').Value + '.md')
    if (-not (Test-Path $p)) { throw "no such decision: $Wanted" }
    return $p
}

function ConvertTo-JsonScalar { param($V) return (ConvertTo-Json ([string]$V) -Compress) }

switch ($Command) {

    'list' {
        $rows = Get-AllDecisions
        if ($Status) { $rows = @($rows | Where-Object { $_.Status -eq $Status }) }
        if (@($rows).Count -eq 0) { Write-Host 'no decisions'; return }
        foreach ($d in $rows) {
            $t = if ($d.Task) { $d.Task } else { '-' }
            '{0,-5} {1,-9} {2,-6} {3}' -f $d.Id, $d.Status, $t, $d.Title
        }
        ''
        "$(@($rows).Count) decision(s)."
    }

    'show' {
        if (-not $Id) { throw 'show requires an id.' }
        Read-Text (Get-DecisionPath $Id)
    }

    'new' {
        if (-not $Title) { throw 'new requires -Title.' }

        $optList = @()
        if ($Options) {
            foreach ($chunk in ($Options -split ';;')) {
                $chunk = $chunk.Trim()
                if (-not $chunk) { continue }
                $parts = $chunk -split '::'
                $o = [pscustomobject]@{
                    key = ''; label = $parts[0].Trim(); detail = ''
                    pros = @(); cons = @(); mitigation = @()
                }
                foreach ($seg in ($parts | Select-Object -Skip 1)) {
                    $seg = $seg.Trim()
                    if (-not $seg) { continue }
                    if ($seg -match '^(?i)(pros|cons|mitigation)\s*:\s*(.*)$') {
                        $name = $Matches[1].ToLower()
                        $items = @($Matches[2] -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        $o.$name = @($o.$name) + $items
                    } elseif (-not $o.detail) {
                        $o.detail = $seg
                    } else {
                        $o.detail = $o.detail + ' ' + $seg
                    }
                }
                $optList += $o
            }
            # The recommended option is listed FIRST (user directive,
            # 2026-08-05), wherever it appeared in the argument, and keys are
            # assigned after the sort so o1 is always the recommendation.
            $optList = @($optList | Sort-Object { if ($_.label -match '(?i)\(recommended\)\s*$') { 0 } else { 1 } })
            for ($i = 0; $i -lt $optList.Count; $i++) { $optList[$i].key = "o$($i + 1)" }
            $recCount = @($optList | Where-Object { $_.label -match '(?i)\(recommended\)\s*$' }).Count
            if ($optList.Count -gt 1 -and $recCount -ne 1) {
                Write-Host "warning: $recCount options are flagged (Recommended) - exactly one should be (see go.md step 5b)"
            }
        }

        $max = 0
        foreach ($d in Get-AllDecisions) {
            $n = [int]([regex]::Match($d.Id, '\d+').Value)
            if ($n -gt $max) { $max = $n }
        }

        $created = $null
        for ($n = $max + 1; $n -lt $max + 50; $n++) {
            $did = "D$n"
            $path = Join-Path $DecisionDir "$did.md"
            try {
                $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            } catch {
                continue   # taken, possibly by another agent this second
            }
            try {
                $lines = @(
                    '---'
                    "id: $did"
                    ("title: " + (ConvertTo-JsonScalar $Title))
                    ("task: " + $(if ($Task) { ConvertTo-JsonScalar $Task } else { 'null' }))
                    "kind: `"$Kind`""
                    'status: "open"'
                    ("created: " + (ConvertTo-JsonScalar ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))))
                    ("assumed: " + $(if ($Assumed) { ConvertTo-JsonScalar $Assumed } else { 'null' }))
                )
                if ($optList.Count -gt 0) {
                    $lines += 'options:'
                    foreach ($o in $optList) {
                        $lines += "  - key: $($o.key)"
                        $lines += ("    label: " + (ConvertTo-JsonScalar $o.label))
                        if ($o.detail) { $lines += ("    detail: " + (ConvertTo-JsonScalar $o.detail)) }
                        foreach ($name in 'pros', 'cons', 'mitigation') {
                            if (@($o.$name).Count -gt 0) {
                                $lines += "    ${name}:"
                                foreach ($it in $o.$name) { $lines += ("      - " + (ConvertTo-JsonScalar $it)) }
                            }
                        }
                    }
                } else {
                    $lines += 'options: []'
                }
                $lines += @(
                    'answer: null'
                    'answeredAt: null'
                    'note: null'
                    '---'
                    ''
                    "# $did - $Title"
                    ''
                    '## Why this needs a call'
                    ''
                    $(if ($Why) { $Why } else { 'TODO: what forced the choice, and what each option costs.' })
                    ''
                )
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`r`n"))
                $fs.Write($bytes, 0, $bytes.Length)
                $created = $did
            } finally {
                $fs.Close()
            }
            break
        }
        if (-not $created) { throw 'could not allocate a decision id' }
        Write-Host "created ${created}: docs/design/windows-parity-decisions/$created.md"
    }

    'resolve' {
        if (-not $Id) { throw 'resolve requires an id.' }
        if (-not $Answer -and -not $Note) { throw 'resolve requires -Answer or -Note.' }
        $path = Get-DecisionPath $Id
        $d = ConvertFrom-DecisionFile $path
        if ($d.Status -eq 'resolved') { throw "$($d.Id) is already resolved." }

        # -Answer takes an option key or a 1-based number; a free-text -Note
        # alone is a valid resolution too (the answer was none of the above).
        $chosen = $null
        if ($Answer) {
            if ($Answer -match '^\d+$') {
                $idx = [int]$Answer - 1
                if ($idx -ge 0 -and $idx -lt $d.Options.Count) { $chosen = $d.Options[$idx] }
            }
            if (-not $chosen) { $chosen = $d.Options | Where-Object { $_.key -eq $Answer } | Select-Object -First 1 }
            if (-not $chosen -and $d.Options.Count -gt 0) { throw "no such option: $Answer" }
        }
        $answerKey = if ($chosen) { $chosen.key } else { '' }
        $answerLabel = if ($chosen) { $chosen.label } else { $Note }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $text = Read-Text $path
        $text = $text -replace '(?m)^status:\s*.*$', 'status: "resolved"'
        $text = $text -replace '(?m)^answer:\s*.*$', ("answer: " + (ConvertTo-JsonScalar $answerKey))
        $text = $text -replace '(?m)^answeredAt:\s*.*$', ("answeredAt: " + (ConvertTo-JsonScalar $stamp))
        $text = $text -replace '(?m)^note:\s*.*$', ("note: " + $(if ($Note) { ConvertTo-JsonScalar $Note } else { 'null' }))
        $res = @(
            ''
            '## Resolution'
            ''
            "Chosen: $answerLabel"
        )
        if ($Note) { $res += @('', $Note) }
        $res += @('', "Resolved $stamp.", '')
        Write-Text $path ($text.TrimEnd() + "`r`n" + ($res -join "`r`n"))

        # Fold the answer back into the task, so the decision is visible to
        # whoever picks the task up rather than only in a sibling file.
        if ($d.Task) {
            $tp = Join-Path $TaskDir ("$($d.Task).md")
            if (Test-Path $tp) {
                $tt = Read-Text $tp
                $block = @(
                    ''
                    "### Decision $($d.Id) - $($d.Title)"
                    ''
                    "Resolved $stamp : $answerLabel"
                )
                if ($Note) { $block += @('', $Note) }
                $block += ''
                Write-Text $tp ($tt.TrimEnd() + "`r`n" + ($block -join "`r`n"))
                Write-Host "folded into $($d.Task)"
            } else {
                Write-Host "warning: linked task $($d.Task) not found; resolution kept in $($d.Id) only"
            }
        }
        Write-Host "resolved $($d.Id): $answerLabel"
    }

    'validate' {
        # T566. The same job parity-tasks.ps1 validate does for the task files,
        # for the decisions beside them. A malformed decision has no red test to
        # find it: it renders wrong in the Activity feed, where the only reader
        # is the user we are asking to make the call.
        #
        # The option-format rules arrived with the user's 2026-08-05 directive,
        # so a decision minted before it is reported as LEGACY OPTIONS rather
        # than failed - see the .EXAMPLE above for why we do not rewrite them.
        $LegacyBefore = '2026-08-06'
        $problems = 0
        $legacy = 0
        $count = 0

        foreach ($f in (Get-ChildItem -LiteralPath $DecisionDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
                Sort-Object { [int]([regex]::Match($_.Name, '\d+').Value) })) {
            $name = $f.Name
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
            if ($stem -notmatch '^D\d+$') {
                Write-Host ("ODD FILENAME: {0} is not D<n>.md, so no verb can address it" -f $name)
                $problems++
                continue
            }
            $count++

            $text = Read-Text $f.FullName
            $lines = @($text -split "`r?`n")
            $fmEnd = -1
            if ($lines.Count -gt 0 -and $lines[0].Trim() -eq '---') {
                for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $fmEnd = $i; break } }
            }
            if ($fmEnd -lt 0) {
                Write-Host ("BAD FRONTMATTER: {0} has no --- delimited frontmatter block" -f $name)
                $problems++
                continue
            }

            $d = ConvertFrom-DecisionFile $f.FullName

            # The declared id is read straight out of the frontmatter here, not
            # from $d: every other verb takes a decision's identity from its
            # FILENAME (which is what `show D12` resolves and what the dashboard
            # links), so the parser never looks at the `id:` line - and a file
            # whose two ids disagree is exactly what that arrangement cannot
            # notice on its own.
            $declaredId = ''
            for ($i = 1; $i -lt $fmEnd; $i++) {
                if ($lines[$i] -match '^id:\s*(.+)$') { $declaredId = $Matches[1].Trim().Trim('"'); break }
            }
            if ($declaredId -ne $stem) {
                Write-Host ("ID MISMATCH: {0} declares id={1}" -f $name, $(if ($declaredId) { $declaredId } else { '<none>' }))
                $problems++
            }
            if (-not $d.Title) { Write-Host ("NO TITLE: {0}" -f $name); $problems++ }
            if ($d.Status -ne 'open' -and $d.Status -ne 'resolved') {
                Write-Host ("ODD STATUS: {0} = '{1}' (want open or resolved)" -f $stem, $d.Status); $problems++
            }
            if ($d.Kind -notin @('assumption', 'question', 'blocker')) {
                Write-Host ("ODD KIND: {0} = '{1}' (want assumption, question or blocker)" -f $stem, $d.Kind); $problems++
            }
            if (-not $d.Created) {
                Write-Host ("NO CREATED: {0} carries no created timestamp" -f $stem); $problems++
            }

            # The task link is the whole delivery mechanism: resolve folds the
            # answer into the linked task, so a decision naming none can be
            # answered and the answer reaches nobody.
            if (-not $d.Task) {
                Write-Host ("NO TASK LINK: {0} names no task, so its answer has nowhere to be folded back into" -f $stem)
                $problems++
            }
            elseif (-not (Test-Path -LiteralPath (Join-Path $TaskDir ("$($d.Task).md")))) {
                Write-Host ("DANGLING TASK: {0} -> {1} (no such task file)" -f $stem, $d.Task); $problems++
            }

            $opts = @($d.Options)
            for ($i = 0; $i -lt $opts.Count; $i++) {
                $want = "o$($i + 1)"
                if ($opts[$i].key -ne $want) {
                    Write-Host ("ODD OPTION KEYS: {0} option {1} is keyed '{2}' (want {3}; resolve -Answer takes these)" -f $stem, ($i + 1), $opts[$i].key, $want)
                    $problems++
                }
                if (-not $opts[$i].label) {
                    Write-Host ("NO OPTION LABEL: {0} option {1} has no label" -f $stem, ($i + 1)); $problems++
                }
            }
            if ($opts.Count -eq 0 -and $d.Status -eq 'open') {
                Write-Host ("NO OPTIONS: {0} is open with nothing to choose between" -f $stem); $problems++
            }

            if ($d.Status -eq 'resolved') {
                if (-not $d.Answer -and -not $d.Note) {
                    Write-Host ("RESOLVED WITHOUT ANSWER: {0} is resolved but records neither an answer nor a note" -f $stem)
                    $problems++
                }
                if ($d.Answer -and -not @($opts | Where-Object { $_.key -eq $d.Answer })) {
                    Write-Host ("UNKNOWN ANSWER: {0} answer='{1}' names no option it offers" -f $stem, $d.Answer)
                    $problems++
                }
            }

            # The 2026-08-05 option-format rules.
            $isLegacy = ($d.Created -and [string]::CompareOrdinal($d.Created, $LegacyBefore) -lt 0)
            $styleProblems = @()
            if ($opts.Count -gt 0) {
                $rec = @($opts | Where-Object { $_.label -match '(?i)\(recommended\)\s*$' })
                if ($opts.Count -gt 1 -and $rec.Count -ne 1) {
                    $styleProblems += ("REC COUNT: {0} flags {1} option(s) (Recommended) - want exactly 1 (go.md step 5b)" -f $stem, $rec.Count)
                }
                elseif ($rec.Count -eq 1 -and $opts[0].key -ne $rec[0].key) {
                    $styleProblems += ("REC NOT FIRST: {0} lists the recommended option as {1} - it belongs first" -f $stem, $rec[0].key)
                }
                foreach ($o in $opts) {
                    if (@($o.pros).Count -eq 0) {
                        $styleProblems += ("NO PROS: {0} option {1} lists no Pros - an option without both is a quiz, not a choice" -f $stem, $o.key)
                    }
                    if (@($o.cons).Count -eq 0) {
                        $styleProblems += ("NO CONS: {0} option {1} lists no Cons - an option without both is a quiz, not a choice" -f $stem, $o.key)
                    }
                }
            }
            if ($styleProblems.Count -gt 0) {
                if ($isLegacy) {
                    Write-Host ("LEGACY OPTIONS: {0} predates the 2026-08-05 option format ({1} issue(s)) - reported, not failed" -f $stem, $styleProblems.Count)
                    $legacy++
                } else {
                    foreach ($line in $styleProblems) { Write-Host $line; $problems++ }
                }
            }
        }

        if (-not $Quiet) {
            Write-Host ""
            if ($legacy -gt 0) { Write-Host ("{0} decision(s) predate the option format and were not failed" -f $legacy) }
            if ($problems -eq 0) {
                Write-Host ("ALL PASS ({0} decisions)" -f $count)
            } else {
                Write-Host ("{0} PROBLEM(S) across {1} decisions" -f $problems, $count)
            }
        }
        if ($problems -gt 0) { exit 1 }
        exit 0
    }
}
