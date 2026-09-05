<#
.SYNOPSIS
  Query and create Windows-parity tasks stored one-file-per-task under
  docs/design/windows-parity-tasks/.

.DESCRIPTION
  Replaces the single-file state table. Each task is <id>.md with YAML
  frontmatter (id, title, order, deps, status, commits, seat, priority) plus a Summary
  and optional Details body. One file per task means two agents can add and
  edit tasks concurrently without touching the same file.

  SEATS (T344). A task's `seat:` says which box can actually do it: `win` (the
  Windows box, and the default when the field is absent), `mac` (needs a macOS
  build/run), or `any`. `next` and `list` filter on it so the Windows loop is
  never handed a task whose validation starts "Mac regression build" - which is
  a permanent stall, since `next` is a pure function of the files.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  EVERY STATUS CHANGE IS JOURNALED (T564). `set-status` appends the transition
  ("status: blocked(...) -> todo") to the task's own `## Progress log`, with
  `-SourceNote` naming whoever asked for it. A status flip is what puts work in
  the queue and takes it out, and it used to be the one edit that left no trace:
  on 2026-08-07 a one-click reopen of T443's armed watch was indistinguishable
  from an evidence-backed one, and it also discarded the `blocked(reason)` text.
  The note preserves the old status verbatim, reason included. `-NoNote` opts a
  bulk normalisation pass out; nothing else should.

  UN-BLOCKING NEEDS EVIDENCE (T892). Moving a task OUT of `blocked(...)` is the
  transition that puts work back in front of the loop, and it asserts something
  nobody checked: that the park condition is now satisfied. `set-status`
  therefore refuses that transition without `-SourceNote` saying what was
  checked, and prints the task's `unblock:` text so the caller sees the
  condition they are claiming. Every other transition is untouched.

  IS THIS TASK STILL TRUE? (T404). A todo is a claim about the code made on the
  day it was filed, and nothing re-checked it: T98 was handed out fourteen days
  after T41 had already fixed its defect at the source. `next` now prints the
  filing date and any commits that have touched the files the task itself names
  since, and `stale-scan` asks the same question of the whole queue - ranked by
  a later commit having NAMED the task by id, then oldest first. Both are
  prompts to verify, never verdicts.

.EXAMPLE
  scripts\parity-tasks.ps1 list -Status todo
  scripts\parity-tasks.ps1 stale-scan -Top 40
  scripts\parity-tasks.ps1 next
  scripts\parity-tasks.ps1 next -Seat mac
  scripts\parity-tasks.ps1 show T144
  scripts\parity-tasks.ps1 new -Title "Fix the thing" -Deps T73,T94 -Tags fix,polish
  scripts\parity-tasks.ps1 new -Title "The installer dies" -UserReport -Tags fix
  scripts\parity-tasks.ps1 set-priority T144 -Priority P0 -UserReport
  scripts\parity-tasks.ps1 note T144 -Text "caption_layout re-pinned; next: slab fills"
  scripts\parity-tasks.ps1 set-order T377 -Order 2
  scripts\parity-tasks.ps1 set-order T500 -Order 2.5   # inject without renumbering
  scripts\parity-tasks.ps1 set-tags T503 -Tags infra,docs
  scripts\parity-tasks.ps1 set-tags T503 -Tags polish -Add
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('list', 'next', 'show', 'new', 'set-status', 'set-priority', 'set-order', 'set-tags', 'note', 'ack-stranded', 'stale-scan', 'validate')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Id,

    [string]$Status,

    # Category tags, for reading the tracker at a glance: which tasks are
    # user-facing vs perf vs test-only. `new -Tags fix,polish` writes them;
    # the dashboard shows them on activity cards and in the task detail view.
    # Vocabulary is closed (see $ValidTags) so the same idea cannot be spelled
    # three ways.
    [string[]]$Tags,

    # `set-tags -Add` unions with what the task already carries instead of
    # replacing it, which is the shape triage wants when it recognises one more
    # thing a task is about. Without it `set-tags` writes exactly what you
    # passed, which is the shape a correction wants.
    [switch]$Add,

    # `note` appends one timestamped line to the task's `## Progress log`.
    # The loop journals meaningful steps there (claimed, built, validated,
    # surprises) so a turn that dies mid-task leaves a trail the next turn can
    # resume from instead of a bare "in-progress" and a pile of uncommitted
    # files.
    [string]$Text,

    # Optional session/conversation id stamped into progress notes, so a stale
    # task can be traced back to the conversation that was working it.
    [string]$Session,

    # P0 severe (crash, hang, data loss, a broken feature) | P1 feature work and
    # UX polish | P2 infra and nice-to-have | P3 reviewed and deliberately last.
    # `next` picks P0 before P1 before P2 before P3, which is the whole point of
    # the field: without it the loop worked in id order and shipped whatever had
    # been logged most recently.
    [ValidateSet('P0', 'P1', 'P2', 'P3')]
    [string]$Priority,
    # The work queue's sort key: lowest goes first. Fractional on purpose, so a
    # task can be injected between two others without renumbering the tracker.
    # Absent means unordered, which sorts last.
    [Nullable[double]]$Order,
    [string[]]$Deps,
    [string]$Title,
    [string]$Summary,
    [string]$Commit,

    # Which box can do the work: win (default) | mac | any. `list`/`next` treat
    # it as a filter, `new` writes it into the created file.
    [ValidateSet('win', 'mac', 'any', 'all')]
    [string]$Seat,

    # `next -Claim` marks the task it hands out `in-progress` in the same
    # breath. go.md asked the loop to run `next` and then a separate
    # `set-status`, and a turn that skipped the second command left the
    # dashboard unable to name what was being worked on - which is what the
    # user saw on 2026-08-04 ("why is the loop status not getting updated").
    # Picking a task and claiming it are one act; making them one command is
    # the only version that cannot be half-done. Off by default so `next`
    # stays a read-only question.
    [switch]$Claim,

    # Who or what asked for a `set-status`, in words a reader will understand
    # ("dashboard: Mark unblocked", "daily triage sweep"). It is appended to the
    # transition's progress-log entry. Optional for most transitions, because
    # the transition is journaled either way - this only says whose hand was on
    # it. REQUIRED when a `set-status` moves a task out of `blocked(...)`, where
    # the flip claims a park condition is satisfied and the note is the only
    # place that claim can be checked (T892).
    [string]$SourceNote,

    # Suppress the progress-log entry `set-status` writes. Exists for a bulk
    # normalisation pass that would otherwise stamp a note into two hundred
    # files; it is NOT for ordinary use, because a status flip with no receipt
    # is the exact defect T564 fixed. It is also the bulk hatch past T892's
    # un-block gate, and prints that it was used when it takes it.
    [switch]$NoNote,

    # T1315. This task exists because a USER told us about it - a report in
    # the terminal, a screenshot, "it did the thing again". `new -UserReport`
    # writes `user-report: true` into the file, `set-priority -UserReport`
    # adds it to a task triage discovers came from one, and `set-status done`
    # on such a task files the publish request itself (T1294) so the fix
    # actually reaches the person who reported it instead of waiting for the
    # next daily release. The flag is the whole mechanism: without it, "ask
    # for a release" is a step a turn has to REMEMBER, and the failure mode of
    # forgetting is the user re-reporting a bug we already fixed.
    [switch]$UserReport,

    # Escape hatch so the acceptance script can drive a fixture directory
    # instead of the real tracker (same idea as GHOSTTY_HOST_DEFAULTS).
    [string]$TaskDir,

    # `validate` also asks scripts\guard-due.ps1 whether an acceptance harness
    # has gone unrun since the code it covers changed (T783) - this is the
    # pre-commit gate every turn runs, so it is where that question has teeth.
    # The hatch is for the genuinely stuck case (a harness that cannot run on
    # this box at all); it PRINTS that it was used, so a commit made under it
    # can be explained rather than silently excused.
    [switch]$NoGuardDue,

    # `validate` also asks scripts\git-commit-guard.ps1 whether this branch is
    # ahead of its upstream (T1057) - a commit that never left the box is
    # invisible to the other seat and dies with the box. Same hatch shape as
    # -NoGuardDue, for the genuinely stuck case (no network), and it PRINTS
    # that it was used.
    [switch]$NoPushCheck,

    # `validate` also asks scripts\ci-status.ps1 what the build machine
    # concluded about the commit this branch is sitting on (T1219) - the loop
    # pushes every turn and, until this gate, never read the answer. Same hatch
    # shape as the two above, and it exists because a run can be red for a
    # reason that is not this turn's (a flaky runner, a red commit somebody
    # else pushed, no network); it PRINTS that it was used.
    [switch]$NoCiCheck,

    # `stale-scan` prints the N most-suspect todos (T404). The whole queue is
    # 400+ files, and a sweep that dumps all of them is a re-derivation rather
    # than a report.
    [int]$Top = 25
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
# Whether the CALLER named a task directory, remembered before the default
# fills the parameter in. `validate` needs the distinction: a fixture run is
# somebody testing this script, the default is the loop's pre-commit gate.
$TaskDirGiven = [bool]$TaskDir
if (-not $TaskDir) {
    $TaskDir = Join-Path $RepoRoot 'docs\design\windows-parity-tasks'
}

if (-not (Test-Path $TaskDir)) {
    throw "Task directory not found: $TaskDir"
}

# The seat a file with no `seat:` field belongs to. Absent means win, so the
# field is optional forever and every pre-T344 task file keeps working.
$DefaultSeat = 'win'
$ValidSeats = @('win', 'mac', 'any')

# The priority a `new` task gets when none is given. P1 is "feature work and
# polish", which is what most parity tasks are; something severe or something
# merely nice gets said out loud with -Priority.
#
# P3 is "reviewed, real, and deliberately behind everything else" (T345). It
# exists because that sentence had no spelling: an absent priority sorts last
# too, but it MEANS "nobody has looked at this", which is the opposite claim,
# and `order:` cannot say it either - an unplaced task ranks MaxValue, so any
# number you write pulls the task AHEAD of every unordered one in its band.
# Two authors independently wrote `priority: "P3"` anyway (T499, T551) and it
# was silently blanked to untriaged, which is why an out-of-set value is now a
# validate failure rather than a quiet normalisation.
$DefaultPriority = 'P1'
$ValidPriorities = @('P0', 'P1', 'P2', 'P3')

# The closed tag vocabulary. feature/fix/polish are the user-facing bands;
# perf/test/infra/docs/security are the internal ones. Closed on purpose:
# an open vocabulary grows "tests", "testing" and "test-quality" for one idea,
# and then no filter matches all three.
$ValidTags = @('feature', 'fix', 'polish', 'perf', 'test', 'infra', 'docs', 'security')

# ---------------------------------------------------------------- parsing ---

function ConvertFrom-Frontmatter {
    param([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path)
    if ($text -notmatch '(?s)^---\r?\n(.*?)\r?\n---') { return $null }
    $fm = $Matches[1]

    $get = {
        param($key)
        if ($fm -match "(?m)^$key`:\s*(.*)$") { return $Matches[1].Trim() }
        return ''
    }

    $parseList = {
        param($raw)
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq '[]' -or $raw -eq 'null') { return @() }
        try { return @($raw | ConvertFrom-Json) } catch { return @() }
    }

    $unquote = {
        param($raw)
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq 'null') { return '' }
        try { return [string]($raw | ConvertFrom-Json) } catch { return $raw.Trim('"') }
    }

    # `order:` is a bare number, not a quoted string, so it parses on its own.
    # Anything unparseable is treated as absent rather than as 0 — a typo must
    # not silently promote a task to the head of the queue.
    $parseOrder = {
        param($raw)
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq 'null') { return $null }
        $d = 0.0
        if ([double]::TryParse($raw.Trim(), [ref]$d)) { return $d }
        return $null
    }

    $seat = & $unquote (& $get 'seat')
    if (-not $seat) { $seat = $DefaultSeat }

    # Absent priority means untriaged. It sorts AFTER every band rather than
    # defaulting to the middle: a task nobody has ranked should not outrank one
    # somebody deliberately called P2.
    #
    # An out-of-set value still reads as untriaged for sorting - a garbled band
    # must not seize a queue position - but the RAW text is kept so `validate`
    # can name it. Before T345 the blanking was the whole story, so `P3` looked
    # exactly like a task nobody had triaged and nothing ever said otherwise.
    $priorityRaw = & $unquote (& $get 'priority')
    $priority = $priorityRaw
    if ($priority -notin $ValidPriorities) { $priority = '' }

    [PSCustomObject]@{
        Id           = & $get 'id'
        Title        = & $unquote (& $get 'title')
        Order        = & $parseOrder (& $get 'order')
        Deps         = & $parseList (& $get 'deps')
        Status       = & $unquote (& $get 'status')
        Commits      = & $parseList (& $get 'commits')
        Seat         = $seat
        Priority     = $priority
        PriorityRaw  = $priorityRaw
        TriageReason = & $unquote (& $get 'triage-reason')
        Tags         = & $parseList (& $get 'tags')
        # What has to be TRUE before this task comes back into the queue, in the
        # parker's own words (the dashboard has rendered it on blocked cards
        # since T564's follow-ups). `set-status` reads it so an un-block can
        # restate the condition the caller is claiming is satisfied - see T892.
        Unblock      = & $unquote (& $get 'unblock')
        # T1315. Did a USER report this? A closed user report is not done from
        # where they are standing until the fix has SHIPPED, so `set-status
        # done` on one files a publish request and `validate` fails a closed
        # one that never did. Absent means no, which keeps the field optional
        # forever and every pre-T1315 file valid.
        UserReport   = ((& $unquote (& $get 'user-report')) -match '^(?i:true)$')
        Path         = $Path
    }
}

# Append one timestamped entry to the task's `## Progress log`, creating the
# section (at the end of the file) if it does not exist yet. Entries go at the
# END of the section so the log reads top-down chronologically.
function Add-ProgressNote {
    param([string]$Path, [string]$NoteText, [string]$SessionId)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $who = if ($SessionId) { " [session $SessionId]" } else { '' }
    $entry = "- ${stamp}${who}: $NoteText"
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '(?m)^## Progress log\s*$')
    if ($m.Success) {
        # Insert before the next section heading, or at EOF.
        $after = $text.Substring($m.Index)
        $next = [regex]::Match($after.Substring($m.Length), '(?m)^#{1,3} ')
        $insertAt = if ($next.Success) { $m.Index + $m.Length + $next.Index } else { $text.Length }
        $head = $text.Substring(0, $insertAt).TrimEnd() + "`n"
        $tail = $text.Substring($insertAt)
        if ($next.Success) { $new = $head + $entry + "`n`n" + $tail.TrimStart("`r", "`n") }
        else { $new = $head + $entry + "`n" }
    }
    else {
        $new = $text.TrimEnd() + "`n`n## Progress log`n`n$entry`n"
    }
    [System.IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding $false))
}

# Wrap a long free-text field to a readable width and indent every line, so a
# 900-character `unblock:` condition prints as a block a human can read instead
# of one console line that scrolls sideways. Returns a single multi-line string.
function Format-Indented {
    param([string]$Text, [string]$Indent = '    ', [int]$Width = 74)
    $out = @()
    foreach ($para in ($Text -split "`r?`n")) {
        $line = ''
        foreach ($word in ($para -split '\s+' | Where-Object { $_ -ne '' })) {
            if ($line -eq '') { $line = $word }
            elseif (($line.Length + 1 + $word.Length) -le $Width) { $line = "$line $word" }
            else { $out += ($Indent + $line); $line = $word }
        }
        $out += ($Indent + $line)
    }
    return ($out -join "`n")
}

# Split, trim and validate a -Tags argument (which `-File` invocation hands
# over as one comma-joined string, same as -Deps).
function Get-TagList {
    param([string[]]$Raw)
    $out = @()
    foreach ($t in $Raw) {
        foreach ($piece in ($t -split ',')) {
            $piece = $piece.Trim().ToLowerInvariant()
            if (-not $piece) { continue }
            if ($ValidTags -notcontains $piece) {
                throw "Unknown tag '$piece' (want one of: $($ValidTags -join ', '))"
            }
            $out += $piece
        }
    }
    return $out
}

# Sort key for `order:`. Unordered tasks sort after every ordered one, so
# adding a task never silently jumps the queue.
function Get-OrderRank {
    param($O)
    if ($null -eq $O) { return [double]::MaxValue }
    return [double]$O
}

# Sort key for a priority: P0 first, then P1, P2, the deliberately-parked P3,
# and untriaged last of all. Untriaged stays BEHIND P3 on purpose - "somebody
# looked and put this last" is a stronger claim than "nobody looked yet".
function Get-PriorityRank {
    param([string]$P)
    switch ($P) {
        'P0' { return 0 }
        'P1' { return 1 }
        'P2' { return 2 }
        'P3' { return 3 }
        default { return 9 }
    }
}

# A seat can work its own tasks plus the ones marked `any`. `all` is the
# no-filter escape hatch for a human reading the whole tracker.
function Test-SeatMatch {
    param([string]$TaskSeat, [string]$Wanted)
    if ($Wanted -eq 'all') { return $true }
    return ($TaskSeat -eq $Wanted -or $TaskSeat -eq 'any')
}

function Get-AllTasks {
    $tasks = @()
    foreach ($f in Get-ChildItem -Path $TaskDir -Filter 'T*.md') {
        $t = ConvertFrom-Frontmatter -Path $f.FullName
        if ($null -ne $t -and $t.Id) { $tasks += $t }
    }
    # Sort numerically by the digits, then by any letter suffix (T89 < T89a < T90).
    return $tasks | Sort-Object `
        @{ Expression = { [int]([regex]::Match($_.Id, '\d+').Value) } }, `
        @{ Expression = { $_.Id } }
}

function Get-TaskId {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { throw 'An id is required (e.g. T144).' }
    $v = $Raw.Trim()
    # Suffixed ids are real and load-bearing: T89a, and T89f2 (a split of a split).
    if ($v -notmatch '^[Tt]\d+[a-z]?\d*$') { throw "Not a task id: $Raw" }
    return 'T' + $v.Substring(1)
}

function Get-TaskPath {
    param([string]$TaskId)
    $p = Join-Path $TaskDir "$TaskId.md"
    if (-not (Test-Path $p)) { throw "No such task: $TaskId ($p)" }
    return $p
}

function Test-Done {
    param([string]$StatusValue)
    return ($StatusValue -match '^(done|skipped)')
}

# A dependency on a `skipped(split -> Ta, Tb)` parent is really a dependency on
# ALL of its children: the parent's work moved into them, it did not end (T382).
# Splitting happens BEFORE the work, so the children always have higher ids than
# the tasks that depended on the parent - resolving the parent as "done" offered
# the dependent first, every time. A non-split skip (duplicate, obsolete,
# no-op) still satisfies as before: that work genuinely ended.
#
# The status string is the only place a split is recorded, and its formats vary
# in the wild ("split -> T372, T373", "split into T189 + T190",
# "split T111a/T111b", the T89b-T89i letter-range shorthand), so children are
# extracted as id tokens rather than by parsing one arrow style.
function Get-SplitChildren {
    param([string]$StatusValue)
    if ($StatusValue -notmatch '^skipped\(\s*split\b') { return @() }
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    # Letter ranges expand first: "T89b-T89i" (hyphen, en or em dash - built
    # from [char] codes to keep this file ASCII-only) names every child from
    # b to i, not just its two endpoints.
    $dashClass = '[' + [char]0x2013 + [char]0x2014 + '-]'
    foreach ($m in [regex]::Matches($StatusValue, ('\b[Tt](\d+)([a-z])\s*' + $dashClass + '\s*[Tt]\1([a-z])\b'))) {
        $num = $m.Groups[1].Value
        $from = [int][char]$m.Groups[2].Value[0]
        $to = [int][char]$m.Groups[3].Value[0]
        for ($i = $from; $i -le $to; $i++) { [void]$ids.Add("T$num" + [char]$i) }
    }
    # Then every plain id token, whatever the separators and prose around it.
    foreach ($m in [regex]::Matches($StatusValue, '\b[Tt]\d+[a-z]?\d*\b')) {
        [void]$ids.Add('T' + $m.Value.Substring(1))
    }
    return @($ids)
}

# The still-open leaves a dependency resolves to; empty means satisfied. A
# todo/in-progress/blocked dep is its own open leaf; done is satisfied; skipped
# resolves through its split children, recursively (a split of a split is
# normal: T89f -> T89f1/T89f2). Unknown ids are ignored - same rule as `next`
# has always applied to a dep with no file - and the visited set makes a
# malformed cycle terminate instead of recursing forever.
function Get-OpenDeps {
    param([string]$DepId, [hashtable]$ById, [hashtable]$Visited)
    if ($Visited.ContainsKey($DepId)) { return @() }
    $Visited[$DepId] = $true
    if (-not $ById.ContainsKey($DepId)) { return @() }
    $status = $ById[$DepId].Status
    if (-not (Test-Done $status)) { return @($DepId) }
    $open = @()
    foreach ($c in (Get-SplitChildren $status)) {
        $open += @(Get-OpenDeps -DepId $c -ById $ById -Visited $Visited)
    }
    return $open
}

# T1133: dependency CYCLES. Nothing else in the tracker can see one. Each file
# in the ring reads perfectly well on its own; `next` skips every member of it
# for "unmet deps" forever, and that skip line is indistinguishable from the
# ordinary case of waiting on work that is genuinely still open. A ring is
# therefore a permanent, silent stall - which is exactly the class of failure
# this gate exists to make loud.
#
# Reported once per ring rather than once per member, keyed on the ring's
# member set, so a two-task cycle is one line and not two. A dep naming an id
# that does not exist is skipped here and owned by DANGLING DEP above.
function Invoke-DepWalk {
    param([string]$Id, [hashtable]$ById, [System.Collections.ArrayList]$Path)
    $script:dcColor[$Id] = 1        # 1 = on the current path, 2 = finished
    [void]$Path.Add($Id)
    foreach ($d in @($ById[$Id].Deps)) {
        if (-not $d -or -not $ById.ContainsKey($d)) { continue }
        if ($script:dcColor[$d] -eq 1) {
            $at = $Path.IndexOf($d)
            if ($at -ge 0) {
                $ring = @($Path[$at..($Path.Count - 1)])
                $key = (@($ring | Sort-Object) -join '>')
                if (-not $script:dcSeen.ContainsKey($key)) {
                    $script:dcSeen[$key] = $true
                    $script:dcCycles = @($script:dcCycles) + , $ring
                }
            }
        }
        elseif ($script:dcColor[$d] -ne 2) {
            Invoke-DepWalk -Id $d -ById $ById -Path $Path
        }
    }
    $Path.RemoveAt($Path.Count - 1)
    $script:dcColor[$Id] = 2
}
function Get-DepCycles {
    param([hashtable]$ById)
    $script:dcColor = @{}
    $script:dcCycles = @()
    $script:dcSeen = @{}
    foreach ($id in @($ById.Keys | Sort-Object)) {
        if ($script:dcColor[$id] -eq 2) { continue }
        Invoke-DepWalk -Id $id -ById $ById -Path (New-Object System.Collections.ArrayList)
    }
    return @($script:dcCycles)
}

# ------------------------------------------------------------- staleness ---
#
# "Is this task still true?" (T404). A todo is a claim about the code made on
# the day it was filed, and nothing re-checks it: T98 was handed out 14 days
# after T41 had already fixed its defect at the source, and the loop spent a
# whole context discovering that. The expensive version of the same shape is a
# task a later fix only PARTLY repaired, where the next agent implements over
# work it never read.
#
# The signal is cheap and it belongs at PICK time, not after the build: how old
# the claim is, and whether anything has touched the files the task itself
# names since it was made. It is a prompt to verify, never a verdict - a task
# whose files moved may still be entirely open, and an untouched one may have
# been fixed somewhere else. `next` prints it for the one task it hands out;
# `stale-scan` prints it for the whole queue so a sweep is a report rather than
# a re-derivation.

# The path prefixes a task body can name that mean "code this task is about".
# Anchored on real top-level directories so ordinary prose ("the src of the
# problem") cannot match, and deliberately NOT including the tracker's own
# docs\design\windows-parity-tasks\ - every task names sibling task files, and
# counting the tracker's own churn would make every task look busy.
$StalePathPattern = '(?<![\w./\\-])((?:src|scripts|test|macos|dist|include|images)[\\/][\w.\\/-]*[\w])'

function Get-RepoRootFor {
    param([string]$Path)
    # Resolved from the TASK DIR, not from $PSScriptRoot, so a fixture task dir
    # living outside any repo answers $null and the whole signal degrades to
    # silence instead of reporting this repo's history against fake tasks.
    try {
        $top = & git -C $Path rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $top) { return $null }
        return ($top | Select-Object -First 1).Trim()
    } catch { return $null }
}

# Code paths a task file names, normalised to repo-relative forward slashes and
# filtered to the ones that actually exist. A path that no longer exists is
# dropped rather than reported: `git log -- <gone>` answers about its deletion,
# which is not the question.
function Get-TaskCodePaths {
    param([string]$Path, [string]$Root)
    if (-not $Root) { return @() }
    $text = [System.IO.File]::ReadAllText($Path)
    $seen = [ordered]@{}
    foreach ($m in [regex]::Matches($text, $StalePathPattern)) {
        $p = $m.Groups[1].Value -replace '\\', '/'
        $p = $p.TrimEnd('.', ',', ')', ':', ';')
        if (-not $p) { continue }
        if ($seen.Contains($p)) { continue }
        # FILES only, never directories. A task that names `test\win32\` names
        # an AREA, and every commit in the repo touches some area: the first
        # cut of this ranked by raw hit count and put seventeen tasks naming
        # `test\win32` at the top with 300+ "touches" each, which is a
        # restatement of how busy the repo is, not a signal about the task.
        if (-not (Test-Path -LiteralPath (Join-Path $Root $p) -PathType Leaf)) { continue }
        $seen[$p] = $true
    }
    return @($seen.Keys)
}

# The day the task was filed: the author date of the commit that ADDED its
# file. Falls back to the file's own mtime when git cannot answer (a task
# created this turn and not yet committed), which is the right answer for a
# fresh file and harmless for an old one.
function Get-TaskFiledDate {
    param([string]$Path, [string]$Root)
    if ($Root) {
        try {
            $lines = @(& git -C $Root log --diff-filter=A --format=%aI -- $Path 2>$null)
            if ($LASTEXITCODE -eq 0 -and $lines.Count -gt 0) {
                $last = $lines[-1]
                if ($last) { return [datetime]::Parse($last.Trim()) }
            }
        } catch { }
    }
    try { return (Get-Item $Path).LastWriteTime } catch { return $null }
}

# Commits since $Since that touched any of $Paths, newest first, as
# "<sha> <date> <subject>" strings.
function Get-TouchingCommits {
    param([string]$Root, [string[]]$Paths, [datetime]$Since, [int]$Limit = 3)
    if (-not $Root -or -not $Paths -or $Paths.Count -eq 0) { return @() }
    $sinceArg = '--since=' + $Since.ToString('yyyy-MM-ddTHH:mm:ss')
    try {
        $out = @(& git -C $Root log $sinceArg '--no-merges' '--format=%aI %h %as %s' '--' @Paths 2>$null)
        if ($LASTEXITCODE -ne 0) { return @() }
    } catch { return @() }
    # `--since` is inclusive to the second, so a commit made in the same second
    # as the filing one comes back with it. Git timestamps have no sub-second
    # resolution, so the boundary has to be re-applied here: strictly AFTER,
    # and a commit that IS the filing commit is not news about the task.
    $kept = @()
    foreach ($line in $out) {
        if (-not $line) { continue }
        $bits = $line.Split(' ', 2)
        $when = try { [datetime]::Parse($bits[0]) } catch { $null }
        if ($when -and $when -le $Since) { continue }
        $kept += $bits[1]
    }
    return @($kept)
}

# One line for `next`, or $null when there is nothing worth saying. Silence is
# the default on purpose: a task filed yesterday whose files nobody touched
# adds a line of noise to every pick for no information.
function Get-StaleSignal {
    param([string]$Path, [string]$Root)
    $filed = Get-TaskFiledDate -Path $Path -Root $Root
    if (-not $filed) { return $null }
    $ageDays = [int][math]::Floor(((Get-Date) - $filed).TotalDays)
    $paths = Get-TaskCodePaths -Path $Path -Root $Root
    $commits = @(Get-TouchingCommits -Root $Root -Paths $paths -Since $filed)
    if ($ageDays -lt 7 -and $commits.Count -eq 0) { return $null }
    return [pscustomobject]@{
        AgeDays = $ageDays
        Filed   = $filed
        Paths   = $paths
        Commits = $commits
    }
}

# --------------------------------------------------------------- commands ---

switch ($Command) {

    'list' {
        $tasks = Get-AllTasks
        # `list` shows everything unless asked otherwise: it is the human's
        # view of the tracker, where hiding rows by default would be a lie.
        $wantSeat = if ($Seat) { $Seat } else { 'all' }
        if ($Status) { $tasks = $tasks | Where-Object { $_.Status -like "$Status*" } }
        if ($Priority) { $tasks = $tasks | Where-Object { $_.Priority -eq $Priority } }
        $tasks = @($tasks | Where-Object { Test-SeatMatch $_.Seat $wantSeat })
        # Queue order, so `list` reads the same way `next` picks. Priority
        # first, then order - see the long note in `next`. These two sorts must
        # stay identical: a list that disagrees with the selector is how a
        # human "verifies" the queue and is shown something the loop will not
        # actually do.
        $tasks = @($tasks | Sort-Object `
            @{ Expression = { Get-PriorityRank $_.Priority } }, `
            @{ Expression = { Get-OrderRank $_.Order } }, `
            @{ Expression = { [int]([regex]::Match($_.Id, '\d+').Value) } }, `
            @{ Expression = { $_.Id } })
        # Rendered at a FIXED width, not the host's. Format-Table truncates to
        # the console window, and it does it silently: in a 62-column pane this
        # table stopped after Status, so Seat, Deps and Title - the three
        # columns a human filters on - simply were not there, and adding Ord
        # made it one column worse. `Out-String -Width` is the only lever that
        # detaches the layout from whatever pane the loop happens to run in.
        $rendered = $tasks | Select-Object `
            @{ N = 'Ord'; E = { if ($null -ne $_.Order) { $_.Order } else { '--' } } },
        Id,
        @{ N = 'Pri'; E = { if ($_.Priority) { $_.Priority } else { '--' } } },
        # Capped like Title. A `skipped(<reason>)` status runs to 166 characters
        # here, and -AutoSize sizes the column to the longest VALUE, so one such
        # row shoved Title off the right edge of every other row. The head of a
        # status is the part that classifies it; the reason lives in the file.
        @{ N = 'Status'; E = { if ($_.Status.Length -gt 24) { $_.Status.Substring(0, 21) + '...' } else { $_.Status } } },
        Seat,
        @{ N = 'Deps'; E = { ($_.Deps -join ',') } },
        @{ N = 'Title'; E = { if ($_.Title.Length -gt 70) { $_.Title.Substring(0, 67) + '...' } else { $_.Title } } } |
        Format-Table -AutoSize | Out-String -Width 200
        Write-Host $rendered.TrimEnd()
        Write-Host ""
        Write-Host ("{0} task(s)." -f @($tasks).Count)
    }

    'next' {
        $tasks = Get-AllTasks
        $byId = @{}
        foreach ($t in $tasks) { $byId[$t.Id] = $t }

        # The selector runs on ONE box, so it defaults to that box's seat.
        $wantSeat = if ($Seat) { $Seat } else { $DefaultSeat }

        # Scan the WHOLE list for the other seat's todos, not just the ones
        # ahead of the pick: the point of the line below is to show that the
        # other seat has a queue, and that answer must not depend on where in
        # the file order this seat's next task happens to sit.
        $otherSeat = @()
        foreach ($t in $tasks) {
            if ($t.Status -notmatch '^todo') { continue }
            if (-not (Test-SeatMatch $t.Seat $wantSeat)) {
                $otherSeat += ("{0}({1})" -f $t.Id, $t.Seat)
            }
        }

        # PRIORITY FIRST, then order, then id (D55; user, 2026-08-12: "fix the
        # queuing and task recording to use priority for figuring out what to
        # prioritize!! This is critical").
        #
        # `priority:` is what the work is WORTH; `order:` is only the sequence
        # within a band. Sorting by order first inverted that, and it did it
        # invisibly, because an unplaced task ranks MaxValue: a P0 with no
        # `order:` sorted behind every positioned P2 on the board. On
        # 2026-08-11 that left three P0s the user had reported by hand sitting
        # `todo` for a full day while twenty-four P2 test-harness tasks closed
        # in front of them, and it took hand-sorting the queue on three
        # consecutive mornings to work around it.
        #
        # The consequence that makes this the right way round: a task filed
        # with nothing but a priority is placed correctly the moment it is
        # filed. Under the old rule it needed a hand-assigned position to be
        # reachable at all, so the queue only worked as well as the last person
        # who remembered to renumber it - and 70 open P1s carried no position.
        #
        # `order:` keeps its job inside the band: it is how triage sequences
        # the P0s against each other, and `set-order` still injects between two
        # of them without renumbering. What it can no longer do is outrank
        # importance. Id remains the last tiebreaker, so the ordering is total
        # and deterministic no matter how little is filled in.
        $ordered = $tasks | Sort-Object `
        @{ Expression = { Get-PriorityRank $_.Priority } }, `
        @{ Expression = { Get-OrderRank $_.Order } }, `
        @{ Expression = { [int]([regex]::Match($_.Id, '\d+').Value) } }, `
        @{ Expression = { $_.Id } }

        # ONE agent works this queue at a time, so any task already marked
        # in-progress when a turn starts is a STALE claim: the turn that made
        # it either died mid-task (crash, reboot, reset) or forgot to close it
        # out. Handing out fresh work while that hangs would strand the
        # half-done work in the tree - two bluescreens on 2026-08-05 left
        # T496/T497 exactly there, in-progress with no agent and a pile of
        # uncommitted changes nobody was told about (user, 2026-08-05).
        # `next -Claim` therefore RESUMES the stale task instead of picking a
        # new one; plain `next` stays a read-only question and only reports.
        $inflight = @($ordered | Where-Object { $_.Status -match '^in-progress' -and (Test-SeatMatch $_.Seat $wantSeat) })
        if ($inflight.Count -gt 0) {
            if ($Claim) {
                $t = $inflight[0]
                Write-Host ("RESUME: {0} - {1}" -f $t.Id, $t.Title)
                $pri = if ($t.Priority) { $t.Priority } else { 'untriaged' }
                $ord = if ($null -ne $t.Order) { $t.Order } else { 'unordered' }
                Write-Host ("      order={0} priority={1} seat={2} (stale in-progress; one agent runs at a time, so nobody is on it)" -f $ord, $pri, $t.Seat)
                Write-Host  "      Reassess before working: read its '## Progress log' and check git status/diff"
                Write-Host  "      for its files. Then either resume it as this turn's task, or record why not"
                Write-Host ("      (note {0} -Text ...) and set it back: set-status {0} -Status todo" -f $t.Id)
                if ($inflight.Count -gt 1) {
                    Write-Host ("      also in flight: " + (($inflight | Select-Object -Skip 1 | ForEach-Object { $_.Id }) -join ', ') + " (next turns get these)")
                }
                Write-Host ("      file: docs/design/windows-parity-tasks/{0}.md" -f $t.Id)
                Add-ProgressNote -Path $t.Path -SessionId $Session -NoteText 'stale in-progress claim picked up by a new turn; reassessing from this log and git status before resuming.'
                exit 0
            }
            Write-Host ("IN FLIGHT: " + (($inflight | ForEach-Object { $_.Id }) -join ', ') + " - in-progress with no agent on it; 'next -Claim' will resume it before offering new work.")
        }

        $blocked = @()
        foreach ($t in $ordered) {
            if ($t.Status -notmatch '^todo') { continue }
            if (-not (Test-SeatMatch $t.Seat $wantSeat)) { continue }
            $unmet = @()
            foreach ($d in $t.Deps) {
                # Resolves through skipped(split ...) parents (T382): a dep is
                # met only when its transitive leaves are done. Unknown deps
                # are still ignored, not blocking - Get-OpenDeps owns that rule.
                $open = @(Get-OpenDeps -DepId $d -ById $byId -Visited @{})
                if ($open.Count -eq 0) { continue }
                # Name the real blockers: "T90d[open: T374+T375]" says the
                # split parent is waiting on those children, not on itself.
                if ($open.Count -eq 1 -and $open[0] -eq $d) { $unmet += $d }
                else { $unmet += ("{0}[open: {1}]" -f $d, ($open -join '+')) }
            }
            if ($unmet.Count -eq 0) {
                Write-Host ("NEXT: {0} - {1}" -f $t.Id, $t.Title)
                $pri = if ($t.Priority) { $t.Priority } else { 'untriaged' }
                $ord = if ($null -ne $t.Order) { $t.Order } else { 'unordered' }
                Write-Host ("      order={0} priority={1} deps={2} seat={3}" -f $ord, $pri, ($t.Deps -join ','), $t.Seat)
                if ($t.TriageReason) { Write-Host ("      why: {0}" -f $t.TriageReason) }
                Write-Host ("      file: docs/design/windows-parity-tasks/{0}.md" -f $t.Id)
                # "Is this still true?" asked BEFORE the build, not after it
                # (T404).
                $stale = Get-StaleSignal -Path $t.Path -Root (Get-RepoRootFor $TaskDir)
                if ($stale) {
                    Write-Host ("      filed {0} ({1}d ago); {2} commit(s) since touched its files" -f `
                            $stale.Filed.ToString('yyyy-MM-dd'), $stale.AgeDays, $stale.Commits.Count)
                    foreach ($c in ($stale.Commits | Select-Object -First 3)) { Write-Host ("        {0}" -f $c) }
                    if ($stale.Commits.Count -gt 0) {
                        Write-Host "      CHECK FIRST: confirm the defect still reproduces - it may already be fixed."
                    }
                }
                if ($Claim) {
                    $claimText = [System.IO.File]::ReadAllText($t.Path, [System.Text.Encoding]::UTF8)
                    $claimed = [regex]::Replace($claimText, '(?m)^status:\s*.*$', 'status: "in-progress"', 1)
                    [System.IO.File]::WriteAllText($t.Path, $claimed, (New-Object System.Text.UTF8Encoding $false))
                    Write-Host ("      CLAIMED: {0} is now in-progress" -f $t.Id)
                    # The first progress-log entry. If this turn dies, the next
                    # one finds at least when the work started and by whom.
                    Add-ProgressNote -Path $t.Path -SessionId $Session -NoteText 'claimed; work starting.'
                }
                if ($blocked.Count -gt 0) {
                    Write-Host ""
                    Write-Host ("Skipped {0} earlier todo(s) with unmet deps: {1}" -f $blocked.Count, ($blocked -join ', '))
                }
                # Loud, never silent: a task filtered out by seat is somebody
                # else's queue, not a task that vanished.
                if ($otherSeat.Count -gt 0) {
                    Write-Host ("Skipped {0} todo(s) for another seat (this seat={1}): {2}" -f $otherSeat.Count, $wantSeat, ($otherSeat -join ', '))
                }
                exit 0
            }
            $blocked += ("{0}(needs {1})" -f $t.Id, ($unmet -join ','))
        }
        Write-Host ("No ready task for seat={0}: every todo has unmet deps, is another seat's, or nothing is todo." -f $wantSeat)
        if ($blocked.Count -gt 0) { Write-Host ("Blocked: {0}" -f ($blocked -join ', ')) }
        if ($otherSeat.Count -gt 0) { Write-Host ("Other seat: {0}" -f ($otherSeat -join ', ')) }
        exit 1
    }

    'show' {
        $tid = Get-TaskId $Id
        Get-Content -Path (Get-TaskPath $tid) -Raw
    }

    'set-status' {
        $tid = Get-TaskId $Id
        if (-not $Status) { throw 'set-status requires -Status.' }
        $path = Get-TaskPath $tid
        $text = [System.IO.File]::ReadAllText($path)
        # Read the OLD status before overwriting it: the transition is what the
        # progress log records, and a `blocked(reason)` head is where the reason
        # lives. The dashboard's buttons write a bare `todo`, so without this
        # the reason is simply gone (T564).
        $before = ConvertFrom-Frontmatter -Path $path
        $was = if ($before) { [string]$before.Status } else { '' }

        # UN-BLOCKING NEEDS EVIDENCE (T892). Leaving a `blocked(...)` state is
        # the one transition that puts work back in front of the loop on the
        # strength of a claim nobody checked: the park recorded a condition,
        # and a bare `set-status <id> -Status todo` asserts it is met while
        # saying nothing about it. That happened twice on T443's armed watch
        # (2026-08-16 09:26, and D27's earlier reopen) and both times the next
        # turn spent its context re-verifying the same watch and re-parking it.
        # T564 made the transition visible; this makes it answerable. The gate
        # is only on the way OUT of blocked - a re-park, a claim, a close all
        # stay as cheap as they were.
        $isUnblock = ($was -match '^blocked') -and ($Status -notmatch '^blocked')
        if ($isUnblock) {
            if ($NoNote) {
                # Same shape as -NoGuardDue: the hatch stays open for a bulk
                # normalisation pass, and says out loud that it was used, so a
                # flip made under it can be explained rather than looking like
                # an evidence-backed one.
                Write-Host ("      WARNING: -NoNote bypassed the un-block evidence gate (T892) for {0}; no receipt was written." -f $tid)
            }
            elseif ([string]::IsNullOrWhiteSpace($SourceNote)) {
                $msg = @()
                $msg += ("{0}: un-blocking needs evidence. It is {1}, and moving it to '{2}' claims that park condition is satisfied." -f $tid, $was, $Status)
                if ($before -and $before.Unblock) {
                    $msg += '  Its unblock condition reads:'
                    $msg += (Format-Indented -Text $before.Unblock -Indent '    ')
                }
                else {
                    $msg += '  It records no `unblock:` condition, so say what you checked in your own words.'
                }
                $msg += ''
                $msg += ('  Re-run with -SourceNote "<what you checked and what it showed>", e.g.')
                $msg += ('    set-status {0} -Status {1} -SourceNote "powercfg PROCTHROTTLEMAX reads 99; boost is off"' -f $tid, $Status)
                $msg += '  (-NoNote is for a bulk normalisation pass only, and prints that it was used.)'
                # Printed rather than thrown: this message is several lines of
                # text a human is meant to READ, and a throw buries it under
                # PowerShell's exception furniture. Exit 2 keeps it distinct
                # from a plain usage error.
                $msg | ForEach-Object { Write-Host $_ }
                exit 2
            }
        }

        $json = ConvertTo-Json $Status -Compress
        $new = [regex]::Replace($text, '(?m)^status:\s*.*$', "status: $json", 1)
        if ($Commit) {
            $existing = if ($before) { $before.Commits } else { @() }
            $all = @($existing) + @($Commit)
            $listJson = '[' + (($all | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ', ') + ']'
            $new = [regex]::Replace($new, '(?m)^commits:\s*.*$', "commits: $listJson", 1)
        }
        [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ("{0} -> {1}" -f $tid, $Status)

        # Journal the transition. A status change is the single most consequential
        # edit anyone makes to a task - it is what puts work into the queue and
        # takes it out - and until T564 it was the only edit that left no trace
        # at all. On 2026-08-07 that let a one-click reopen of T443's armed watch
        # look exactly like an evidence-backed one, and the loop spent a turn
        # re-deriving a park it had already recorded.
        if (-not $NoNote -and $was -ne $Status) {
            $from = if ($was) { $was } else { '(none)' }
            $line = "status: {0} -> {1}" -f $from, $Status
            if ($SourceNote) { $line += (" (by {0})" -f $SourceNote) }
            if ($Commit) { $line += (" [commit {0}]" -f $Commit) }
            Add-ProgressNote -Path $path -SessionId $Session -NoteText $line
            Write-Host ("      journaled: {0}" -f $line)
        }

        # T1315: closing a task the USER reported asks for the release that
        # carries the fix, here, rather than leaving it as a step a turn has to
        # remember. T1294 made the same-day publish possible and left the
        # asking to discipline; on 2026-09-03 that cost the user a second
        # download of the same broken installer and a second report of a bug
        # already fixed. A closed user report is not done from where they are
        # standing until the fix has shipped, so the close and the request are
        # one act. The receipt goes in the progress log, and `validate` fails a
        # closed user report that has none - so a request that could not be
        # written is loud instead of silent.
        if ($Status -eq 'done' -and $before -and $before.UserReport) {
            $pubScript = Join-Path $PSScriptRoot 'daily-publish.ps1'
            $reason = "{0}: {1}" -f $tid, $(if ($before.Title) { $before.Title } else { 'a task the user reported' })
            # A fixture task dir is somebody testing this script; it must not
            # write the real box's publish request. GHOZTTY_PUBLISH_REQUEST_PATH
            # is how the acceptance harness points the write at its own sandbox
            # and reads it back. Unset in every real run.
            $reqPath = [string]$env:GHOZTTY_PUBLISH_REQUEST_PATH
            if ($TaskDirGiven -and -not $reqPath) {
                Write-Host ("      (fixture task dir: no publish request filed for {0})" -f $tid)
            }
            elseif (-not (Test-Path -LiteralPath $pubScript)) {
                Write-Host ("PUBLISH REQUEST FAILED: {0} is a user report and {1} is missing - ask for the release by hand" -f $tid, $pubScript)
            }
            else {
                $reqArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pubScript, '-Request', '-Reason', $reason)
                if ($reqPath) { $reqArgs += @('-RequestPath', $reqPath) }
                $reqOut = & powershell.exe @reqArgs 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0) {
                    Add-ProgressNote -Path $path -SessionId $Session -NoteText ("publish request filed: {0}" -f $reason)
                    Write-Host ("PUBLISH REQUESTED: {0} - step 6.5's daily-publish run ships this fix today, whatever the day's watermark says" -f $reason)
                }
                else {
                    Write-Host ("PUBLISH REQUEST FAILED: {0} is a user report but the request was not recorded - run: daily-publish.ps1 -Request -Reason `"{1}`"" -f $tid, $reason)
                    foreach ($line in ($reqOut -split "`r?`n")) { if ($line.Trim()) { Write-Host ("  " + $line.TrimEnd()) } }
                }
            }
        }

        # Restate what the parker asked for, at the moment somebody says it is
        # satisfied (T892). The condition is written down precisely so it can be
        # checked, and the one place it was never shown was the command that
        # ends the wait - T857's is machine-checkable (`powercfg
        # PROCTHROTTLEMAX` must read 99) and the reopen that skipped it read 100.
        if ($isUnblock -and $before -and $before.Unblock) {
            Write-Host  "      unblock condition you are claiming is satisfied:"
            Write-Host (Format-Indented -Text $before.Unblock -Indent '        ')
        }
    }

    'set-order' {
        $tid = Get-TaskId $Id
        if ($null -eq $Order) { throw 'set-order requires -Order (a number; decimals are fine).' }
        $path = Get-TaskPath $tid
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        # Invariant culture: a machine with a comma decimal separator would
        # otherwise write "order: 2,5", which reads back as absent.
        $num = ([double]$Order).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        if ($text -match '(?m)^order:\s*.*$') {
            $new = [regex]::Replace($text, '(?m)^order:\s*.*$', "order: $num", 1)
        }
        else {
            $new = [regex]::Replace($text, '(?m)^(title:\s*.*)$', "`$1`norder: $num", 1)
        }
        [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ("{0} -> order {1}" -f $tid, $num)
    }

    # Tags were introduced by T502 on `new` alone, so the only way to give an
    # already-filed task a category was to hand-edit its frontmatter - which is
    # why several hundred tasks carried none and the dashboard's category
    # filter simply could not see them (T503). This is that missing verb: the
    # same closed vocabulary `new -Tags` validates against, applied to a task
    # that already exists.
    'set-tags' {
        $tid = Get-TaskId $Id
        $tagList = Get-TagList $Tags
        if ($tagList.Count -eq 0) {
            throw "set-tags requires -Tags (one or more of: $($ValidTags -join ', '))."
        }
        $path = Get-TaskPath $tid
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

        # Read what is there now so the line this prints names the change
        # rather than only its result - a bulk backfill is read as a diff.
        $old = @()
        $om = [regex]::Match($text, '(?m)^tags:\s*\[(.*)\]\s*$')
        if ($om.Success) {
            foreach ($piece in ($om.Groups[1].Value -split ',')) {
                $piece = $piece.Trim().Trim('"').Trim()
                if ($piece) { $old += $piece }
            }
        }

        $final = @()
        if ($Add) { foreach ($t in $old) { if ($final -notcontains $t) { $final += $t } } }
        foreach ($t in $tagList) { if ($final -notcontains $t) { $final += $t } }

        $tagsJson = '[' + (($final | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ', ') + ']'
        if ($om.Success) {
            $new = [regex]::Replace($text, '(?m)^tags:\s*\[.*\]\s*$', "tags: $tagsJson", 1)
        }
        elseif ($text -match '(?m)^tags:\s*.*$') {
            $new = [regex]::Replace($text, '(?m)^tags:\s*.*$', "tags: $tagsJson", 1)
        }
        elseif ($text -match '(?m)^priority:\s*.*$') {
            # Where `new` puts it, so a backfilled file is shaped like a fresh
            # one and a reader is not hunting for the field.
            $new = [regex]::Replace($text, '(?m)^(priority:\s*.*)$', "`$1`ntags: $tagsJson", 1)
        }
        elseif ($text -match '(?m)^seat:\s*.*$') {
            $new = [regex]::Replace($text, '(?m)^(seat:\s*.*)$', "`$1`ntags: $tagsJson", 1)
        }
        else {
            $new = [regex]::Replace($text, '(?m)^(status:\s*.*)$', "`$1`ntags: $tagsJson", 1)
        }
        if ($new -eq $text) {
            Write-Host ("{0} -> tags {1} (unchanged)" -f $tid, ($final -join ','))
            break
        }
        [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
        $wasText = if ($old.Count) { $old -join ',' } else { 'none' }
        Write-Host ("{0} -> tags {1} (was {2})" -f $tid, ($final -join ','), $wasText)
    }

    'set-priority' {
        $tid = Get-TaskId $Id
        if (-not $Priority) { throw 'set-priority requires -Priority (P0|P1|P2|P3).' }
        $path = Get-TaskPath $tid
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        # Read the OLD priority before overwriting it, so the journal below can
        # name what changed rather than only what it became.
        $oldPriority = 'untriaged'
        $om = [regex]::Match($text, '(?m)^priority:\s*"?(P\d)"?\s*$')
        if ($om.Success) { $oldPriority = $om.Groups[1].Value }
        $json = ConvertTo-Json $Priority -Compress
        if ($text -match '(?m)^priority:\s*.*$') {
            $new = [regex]::Replace($text, '(?m)^priority:\s*.*$', "priority: $json", 1)
        }
        else {
            # A file written before priorities existed has no line to replace,
            # so put one directly under status: where every triaged file has it.
            $new = [regex]::Replace($text, '(?m)^(status:\s*.*)$', "`$1`npriority: $json", 1)
        }
        if ($Summary) {
            $why = ConvertTo-Json $Summary -Compress
            if ($new -match '(?m)^triage-reason:\s*.*$') {
                $new = [regex]::Replace($new, '(?m)^triage-reason:\s*.*$', "triage-reason: $why", 1)
            }
            else {
                $new = [regex]::Replace($new, '(?m)^(priority:\s*.*)$', "`$1`ntriage-reason: $why", 1)
            }
        }
        # T1315: re-triage is where somebody realises a task came from a user
        # report - the report arrives as a sentence in the terminal and the
        # task gets filed from it minutes later, often by a different hand. The
        # flag is additive on purpose: this cannot un-set it, because "actually
        # nobody reported this" is not a thing triage discovers.
        $flagged = $false
        if ($UserReport -and $new -notmatch '(?m)^user-report:\s*true\s*$') {
            if ($new -match '(?m)^user-report:\s*.*$') {
                $new = [regex]::Replace($new, '(?m)^user-report:\s*.*$', 'user-report: true', 1)
            }
            else {
                $new = [regex]::Replace($new, '(?m)^(priority:\s*.*)$', "`$1`nuser-report: true", 1)
            }
            $flagged = $true
        }
        [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
        if ($flagged) {
            Add-ProgressNote -Path $path -SessionId $Session -NoteText 'user-report: true (closing this task now asks for the release that carries the fix)'
            Write-Host ("      {0} is a user report: closing it will file a publish request" -f $tid)
        }
        # Journalled for the same reason `set-status` is (T564): since D55 the
        # priority IS the queue position, so re-prioritising a task moves what
        # the loop does next - and a re-triage that changed the head of the
        # queue used to leave no trace of what it displaced or why. Skipped when
        # nothing moved, so a bulk normalisation pass does not write 200 entries
        # saying P1 -> P1.
        if ($oldPriority -ne $Priority -and -not $NoNote) {
            $why = if ($SourceNote) { " ($SourceNote)" } elseif ($Summary) { " ($Summary)" } else { '' }
            Add-ProgressNote -Path $path -NoteText "priority: $oldPriority -> $Priority$why" -SessionId $Session
        }
        Write-Host ("{0} -> {1} (was {2})" -f $tid, $Priority, $oldPriority)
    }

    'new' {
        if (-not $Title) { throw 'new requires -Title.' }

        # Under `-File`, PowerShell hands `-Deps T01,T155` over as ONE string, so
        # split every element on commas rather than trusting the array binding.
        $depList = @()
        foreach ($d in $Deps) {
            foreach ($piece in ($d -split ',')) {
                $piece = $piece.Trim()
                if ($piece) { $depList += (Get-TaskId $piece) }
            }
        }
        $depsJson = '[]'
        if ($depList.Count -gt 0) {
            $depsJson = '[' + (($depList | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ', ') + ']'
        }
        # A new task is UNORDERED unless told otherwise: it joins the tail of
        # the queue rather than silently landing wherever a default put it.
        $orderJson = 'null'
        if ($null -ne $Order) {
            $orderJson = ([double]$Order).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }

        # `all` is a filter, not a seat a task can hold.
        $seatValue = if ($Seat -and $Seat -ne 'all') { $Seat } else { $DefaultSeat }
        $priorityValue = if ($Priority) { $Priority } else { $DefaultPriority }

        $tagList = Get-TagList $Tags
        $tagsJson = '[]'
        if ($tagList.Count -gt 0) {
            $tagsJson = '[' + (($tagList | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ', ') + ']'
        }

        # Allocate the next free id by CREATING the file atomically. A racing
        # agent that picked the same number loses the CreateNew and we retry,
        # so two sessions can never mint the same id.
        $max = 0
        foreach ($t in Get-AllTasks) {
            $n = [int]([regex]::Match($t.Id, '\d+').Value)
            if ($n -gt $max) { $max = $n }
        }

        $created = $null
        for ($n = $max + 1; $n -lt $max + 50; $n++) {
            $tid = "T$n"
            $path = Join-Path $TaskDir "$tid.md"
            try {
                $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            }
            catch {
                continue   # taken (possibly by the other agent, this second)
            }
            try {
                $body = if ($Summary) { $Summary } else { 'TODO: describe the defect or gap, the evidence, the fix, and the validation.' }
                $lines = @(
                    '---'
                    "id: $tid"
                    ("title: " + (ConvertTo-Json $Title -Compress))
                    "order: $orderJson"
                    "deps: $depsJson"
                    'status: "todo"'
                    'commits: []'
                    ("seat: " + (ConvertTo-Json $seatValue -Compress))
                    ("priority: " + (ConvertTo-Json $priorityValue -Compress))
                    "tags: $tagsJson"
                )
                # Written only when true (T1315): an absent field already means
                # "not a user report", and stamping `user-report: false` into
                # every task file would make the one that matters harder to see.
                if ($UserReport) { $lines += 'user-report: true' }
                $lines += @(
                    '---'
                    ''
                    "# $tid - $Title"
                    ''
                    '## Summary'
                    ''
                    $body
                    ''
                    # Every task carries validation criteria from birth: the
                    # observable checks that prove it is done. The turn that
                    # lands it ticks them and records HOW each was verified.
                    '## Validation criteria'
                    ''
                    '- [ ] TODO: the observable checks that prove this is done, ticked with evidence of how each was validated.'
                    ''
                )
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
                $fs.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $fs.Close()
            }
            $created = $tid
            break
        }

        if (-not $created) { throw 'Could not allocate a task id.' }
        Write-Host ("created {0}: docs/design/windows-parity-tasks/{0}.md" -f $created)
    }

    'note' {
        $tid = Get-TaskId $Id
        if (-not $Text) { throw 'note requires -Text.' }
        $path = Get-TaskPath $tid
        Add-ProgressNote -Path $path -SessionId $Session -NoteText $Text
        Write-Host ("{0}: progress note added" -f $tid)
    }

    'ack-stranded' {
        # T847: hand the stranded paths snapshotted at claim time to an OPEN
        # task, so validate stops failing on them without the gate going quiet.
        # The handoff is journaled into the task, which is what makes it a
        # receipt rather than a mute: whoever picks the task up sees exactly
        # which paths it owes.
        $tid = Get-TaskId $Id
        $t = ConvertFrom-Frontmatter -Path (Get-TaskPath $tid)
        if ($null -eq $t) { throw "ack-stranded: cannot read $tid." }
        if (Test-Done $t.Status) { throw "ack-stranded: $tid is closed ($($t.Status)); the ack must name a task that will actually resolve the paths." }
        $strandedRepo = $RepoRoot
        if ($env:GHOZTTY_STRANDED_REPO) { $strandedRepo = $env:GHOZTTY_STRANDED_REPO }
        $strandedPath = Join-Path (Join-Path $strandedRepo 'temp') 'go-loop.stranded.json'
        if (-not (Test-Path -LiteralPath $strandedPath)) { throw "ack-stranded: no stranded-work snapshot at $strandedPath (nothing to acknowledge)." }
        $snap = Get-Content -LiteralPath $strandedPath -Raw | ConvertFrom-Json
        $snap | Add-Member -NotePropertyName ackTask -NotePropertyValue $tid -Force
        $snap | Add-Member -NotePropertyName ackPaths -NotePropertyValue @($snap.paths) -Force
        ($snap | ConvertTo-Json -Depth 4) | Out-File -FilePath $strandedPath -Encoding utf8
        Add-ProgressNote -Path (Get-TaskPath $tid) -SessionId $Session -NoteText (
            "took over stranded working-tree paths (dirty since before this turn's claim): " + (@($snap.paths) -join ', '))
        Write-Host ("{0} now owns {1} stranded path(s); validate passes while it stays open" -f $tid, @($snap.paths).Count)
    }

    'stale-scan' {
        # The sweep, as a report (T404). Ranks this seat's open todos by how
        # much the code they name has moved since they were filed, so "which of
        # these 400 claims about the code might already be false?" is one
        # command instead of four hundred greps.
        #
        # ONE git pass for the whole queue. Per-task `git log` calls were the
        # obvious shape and cost ~400 process spawns; this walks the history
        # once with --name-only and intersects in memory.
        $root = Get-RepoRootFor $TaskDir
        if (-not $root) {
            Write-Host "stale-scan: $TaskDir is not inside a git repository, so there is no history to ask."
            exit 1
        }
        $wantSeat = if ($Seat) { $Seat } else { $DefaultSeat }
        $todos = @(Get-AllTasks | Where-Object {
                $_.Status -match '^todo' -and (Test-SeatMatch $_.Seat $wantSeat)
            })
        if ($todos.Count -eq 0) { Write-Host "stale-scan: no open todos for seat=$wantSeat."; exit 0 }

        # Every task's filed date in ONE pass. Per-task `git log` was the
        # obvious shape and made the scan unusable: 400 process spawns took
        # longer than reading the tasks by hand, which is the thing this
        # command exists to replace.
        $marker = '::C::'
        $taskRel = 'docs/design/windows-parity-tasks'
        $filedByFile = @{}
        $addLog = @(& git -C $root log --diff-filter=A '--name-only' ("--format=$marker%aI") '--' $taskRel 2>$null)
        $when = $null
        foreach ($line in $addLog) {
            if ($null -eq $line) { continue }
            if ($line.StartsWith($marker)) {
                $when = try { [datetime]::Parse($line.Substring($marker.Length)) } catch { $null }
                continue
            }
            $f = $line.Trim()
            if (-not $f -or -not $when) { continue }
            # Newest first, so the LAST write for a path is the commit that
            # first added it - the same rule Get-TaskFiledDate applies.
            $filedByFile[[System.IO.Path]::GetFileName($f)] = $when
        }

        $rows = @()
        $earliest = $null
        foreach ($t in $todos) {
            $filed = $filedByFile[[System.IO.Path]::GetFileName($t.Path)]
            if (-not $filed) { $filed = (Get-Item $t.Path).LastWriteTime }
            $paths = Get-TaskCodePaths -Path $t.Path -Root $root
            if ($filed -and (-not $earliest -or $filed -lt $earliest)) { $earliest = $filed }
            $exact = @{}
            foreach ($p in $paths) { $exact[$p] = $true }
            $rows += [pscustomobject]@{
                Task = $t; Filed = $filed; Paths = $paths; Exact = $exact
                Hits = @(); Mentions = @()
            }
        }
        if (-not $earliest) { $earliest = (Get-Date).AddYears(-5) }

        # Inverted index: changed-file -> the rows that named it. The obvious
        # loop (every changed file against every row) is ~20k lines x 400 rows
        # and takes minutes in PS 5.1; this is one hash lookup per line.
        $byPath = @{}
        foreach ($r in $rows) {
            foreach ($p in $r.Exact.Keys) {
                if (-not $byPath.ContainsKey($p)) { $byPath[$p] = New-Object System.Collections.ArrayList }
                [void]$byPath[$p].Add($r)
            }
        }

        $log = @(& git -C $root log ('--since=' + $earliest.ToString('yyyy-MM-ddTHH:mm:ss')) `
                '--no-merges' '--name-only' ("--format=$marker%h %aI %as %s") 2>$null)
        $curSha = $null; $curWhen = $null; $curLine = $null
        foreach ($line in $log) {
            if ($null -eq $line) { continue }
            if ($line.StartsWith($marker)) {
                $rest = $line.Substring($marker.Length)
                $bits = $rest.Split(' ', 4)
                $curSha = $bits[0]
                $curWhen = try { [datetime]::Parse($bits[1]) } catch { $null }
                $curLine = "{0} {1} {2}" -f $bits[0], $bits[2], $bits[3]
                continue
            }
            if (-not $line.Trim()) { continue }
            if (-not $curWhen) { continue }
            $f = $line.Trim() -replace '\\', '/'
            if (-not $byPath.ContainsKey($f)) { continue }
            foreach ($r in $byPath[$f]) {
                if (-not $r.Filed -or $curWhen -le $r.Filed) { continue }
                if ($r.Hits -notcontains $curLine) { $r.Hits += $curLine }
            }
        }

        # The HIGH-PRECISION signal, and the reason the report is worth reading
        # at all (T404). A commit that NAMES an open task's id, made after that
        # task was filed, is somebody having already dealt with it - a
        # follow-up that fixed it in passing, a split that absorbed it, a
        # revert. `touched=` alone cannot carry the report: ranked by it, the
        # top of the list is whichever hub file the repo is busiest in
        # (seventeen guard-due tasks, because everyone edits guard-due.ps1),
        # which says nothing about any one task.
        #
        # A second pass rather than a wider format on the first: --name-only
        # and %b both emit bare lines after the header, and there is no way to
        # tell a body line from a path once they are mixed.
        $rowById = @{}
        foreach ($r in $rows) { $rowById[$r.Task.Id] = $r }
        $msgLog = @(& git -C $root log ('--since=' + $earliest.ToString('yyyy-MM-ddTHH:mm:ss')) `
                '--no-merges' ("--format=$marker%h %aI %as %s%n%b") 2>$null)
        $curWhen = $null; $curLine = $null; $curIds = $null
        $flush = {
            if ($curLine -and $curIds) {
                foreach ($id in $curIds.Keys) {
                    $r = $rowById[$id]
                    if (-not $r -or -not $r.Filed -or $curWhen -le $r.Filed) { continue }
                    if ($r.Mentions -notcontains $curLine) { $r.Mentions += $curLine }
                }
            }
        }
        foreach ($line in $msgLog) {
            if ($null -eq $line) { continue }
            if ($line.StartsWith($marker)) {
                & $flush
                $rest = $line.Substring($marker.Length)
                $bits = $rest.Split(' ', 4)
                $curWhen = try { [datetime]::Parse($bits[1]) } catch { $null }
                $curLine = "{0} {1} {2}" -f $bits[0], $bits[2], $bits[3]
                $curIds = @{}
            }
            if (-not $curIds) { continue }
            foreach ($m in [regex]::Matches($line, '\bT\d+\b')) { $curIds[$m.Value] = $true }
        }
        & $flush

        $now = Get-Date
        # Mentions first, then oldest first. Age is the tiebreaker rather than
        # the hit count on purpose: among tasks nobody has named, the one whose
        # claim about the code is oldest is the one most likely to have gone
        # false, and hit count only measures how busy its files are.
        $ranked = @($rows | Where-Object { $_.Hits.Count -gt 0 -or $_.Mentions.Count -gt 0 } | Sort-Object `
            @{ Expression = { $_.Mentions.Count }; Descending = $true }, `
            @{ Expression = { $_.Filed } })
        $named = @($ranked | Where-Object { $_.Mentions.Count -gt 0 }).Count
        Write-Host ("stale-scan: {0} open todo(s) for seat={1}. {2} were NAMED by a later commit; {3} name code that has moved since they were filed." -f `
                $todos.Count, $wantSeat, $named, $ranked.Count)
        Write-Host "Each line is a PROMPT TO VERIFY, not a verdict - the defect may still be entirely open."
        Write-Host ""
        foreach ($r in ($ranked | Select-Object -First $Top)) {
            $age = if ($r.Filed) { [int][math]::Floor(($now - $r.Filed).TotalDays) } else { 0 }
            $pri = if ($r.Task.Priority) { $r.Task.Priority } else { '--' }
            Write-Host ("{0,-7} {1}  age={2,4}d  named={3,2}  touched={4,3}  {5}" -f `
                    $r.Task.Id, $pri, $age, $r.Mentions.Count, $r.Hits.Count, $r.Task.Title)
            foreach ($h in ($r.Mentions | Select-Object -First 3)) { Write-Host ("     named by {0}" -f $h) }
        }
        if ($ranked.Count -gt $Top) {
            Write-Host ""
            Write-Host ("... {0} more; -Top {1} to see them all." -f ($ranked.Count - $Top), $ranked.Count)
        }
    }

    'validate' {
        $tasks = Get-AllTasks
        $byId = @{}
        $problems = 0

        foreach ($f in Get-ChildItem -Path $TaskDir -Filter 'T*.md') {
            $t = ConvertFrom-Frontmatter -Path $f.FullName
            if ($null -eq $t) {
                Write-Host ("BAD FRONTMATTER: {0}" -f $f.Name); $problems++; continue
            }
            $expected = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ($t.Id -ne $expected) {
                Write-Host ("ID MISMATCH: {0} declares id={1}" -f $f.Name, $t.Id); $problems++
            }
            if (-not $t.Title) { Write-Host ("NO TITLE: {0}" -f $f.Name); $problems++ }
            if (-not $t.Status) { Write-Host ("NO STATUS: {0}" -f $f.Name); $problems++ }
            $byId[$t.Id] = $t
        }

        foreach ($t in $tasks) {
            foreach ($d in $t.Deps) {
                if (-not $byId.ContainsKey($d)) {
                    Write-Host ("DANGLING DEP: {0} -> {1}" -f $t.Id, $d); $problems++
                }
                elseif ($t.Status -match '^(todo|in-progress)') {
                    # A dep satisfied only on paper - a skipped(split) parent
                    # whose children are still open - is the misroute T382
                    # exists to end. Said out loud, but informational: a task
                    # waiting on a split is a legitimate queue state, not a
                    # broken file, so it must not fail the tracker.
                    if ((Test-Done $byId[$d].Status)) {
                        $open = @(Get-OpenDeps -DepId $d -ById $byId -Visited @{})
                        if ($open.Count -gt 0) {
                            Write-Host ("SPLIT DEP: {0} -> {1} resolves through a split with open children: {2} (next will not offer {0} until they are done)" -f $t.Id, $d, ($open -join ', '))
                        }
                    }
                }
            }
            if ($t.Status -notmatch '^(todo|in-progress|done|blocked|skipped)') {
                Write-Host ("ODD STATUS: {0} = '{1}'" -f $t.Id, $t.Status); $problems++
            }
            # A typo'd seat would hide the task from every seat's `next`, which
            # is exactly the silent stall this field exists to end.
            if ($ValidSeats -notcontains $t.Seat) {
                Write-Host ("ODD SEAT: {0} = '{1}' (want one of: {2})" -f $t.Id, $t.Seat, ($ValidSeats -join ', ')); $problems++
            }
            # Priority is optional (untriaged is a real state), but a value
            # outside the set is not: it reads as untriaged, so a deliberate
            # ranking silently becomes "nobody looked at this" and the task
            # sorts behind every band. Two files carried `P3` for weeks that
            # way before T345 went looking (T499, T551).
            if ($t.PriorityRaw -and $ValidPriorities -notcontains $t.PriorityRaw) {
                Write-Host ("ODD PRIORITY: {0} = '{1}' (want one of: {2}) - it is being read as untriaged" -f $t.Id, $t.PriorityRaw, ($ValidPriorities -join ', ')); $problems++
            }
            # Tags are optional (the pre-tag tracker has none), but a tag
            # outside the vocabulary is a typo that no filter will ever match.
            foreach ($tag in $t.Tags) {
                if ($ValidTags -notcontains $tag) {
                    Write-Host ("ODD TAG: {0} = '{1}' (want one of: {2})" -f $t.Id, $tag, ($ValidTags -join ', ')); $problems++
                }
            }
            # An in-progress task with no progress log is unresumable if its
            # turn dies - which is the whole reason the log exists.
            if ($t.Status -match '^in-progress') {
                $bodyText = [System.IO.File]::ReadAllText($t.Path, [System.Text.Encoding]::UTF8)
                if ($bodyText -notmatch '(?m)^## Progress log\s*$') {
                    Write-Host ("NO PROGRESS LOG: {0} is in-progress with no '## Progress log' section (add one: parity-tasks.ps1 note {0} -Text ...)" -f $t.Id); $problems++
                }
            }
            # T1315: a closed USER REPORT that never asked for a release. The
            # receipt is written by `set-status done` itself, so in ordinary
            # operation this never fires; what it catches is the three ways the
            # asking can go missing - a status hand-edited in the file, a
            # request write that failed, and a task retro-flagged with
            # `set-priority -UserReport` after it was already closed. All three
            # end the same way from where the user sits: they reported a bug,
            # we fixed it, and no build they can install carries the fix.
            if ($t.UserReport -and $t.Status -eq 'done') {
                $bodyText = [System.IO.File]::ReadAllText($t.Path, [System.Text.Encoding]::UTF8)
                if ($bodyText -notmatch '(?mi)^-.*publish request') {
                    Write-Host ("UNSHIPPED USER REPORT: {0} is a closed user report with no publish request in its progress log - the reporter has no build carrying this fix" -f $t.Id)
                    Write-Host ("  (ask for it: scripts\daily-publish.ps1 -Request -Reason `"{0}: <what was fixed>`", then: parity-tasks.ps1 note {0} -Text `"publish request filed: ...`")" -f $t.Id)
                    $problems++
                }
            }
        }

        # A ring of tasks that wait on each other (T1133). Checked over the
        # whole graph rather than per task, because a cycle is a property of
        # the graph and no single file in it looks wrong.
        foreach ($ring in @(Get-DepCycles -ById $byId)) {
            $shown = @($ring) + @($ring)[0]
            Write-Host ("DEP CYCLE: {0} - nothing in this ring can ever be offered by next" -f ($shown -join ' -> ')); $problems++
        }

        # An acceptance harness that has gone unrun since the code it covers
        # changed (T783). Reported apart from the task-file problems above
        # because it is a different kind of news - the tracker is fine, the
        # HARNESS is unmeasured - but it counts the same, because this is the
        # gate go.md runs before every commit and a warning nobody must act on
        # is what let the go-loop guard sit 26-red for a day.
        $dueScript = Join-Path $PSScriptRoot 'guard-due.ps1'
        if ($TaskDirGiven) {
            # A fixture run is somebody testing the tracker, not the loop's
            # pre-commit gate; it has no business failing over the repo's
            # harness stamps.
        }
        elseif ($NoGuardDue) {
            # T1189: name what is being excused. "SKIPPED" alone made the hatch
            # unreadable after the fact - a turn excusing a harness that cannot
            # run on this box at all and a turn excusing a harness that is RED
            # produced the identical line, which is how a routine override stops
            # carrying information. The check itself is local hashing, so asking
            # anyway costs nothing but the answer.
            Write-Host "GUARD DUE CHECK SKIPPED (-NoGuardDue): harness staleness was not enforced for this commit"
            if (Test-Path -LiteralPath $dueScript) {
                $guardRepo = $RepoRoot
                if ($env:GHOZTTY_GUARD_DUE_REPO) { $guardRepo = $env:GHOZTTY_GUARD_DUE_REPO }
                $skipOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $dueScript check -Repo $guardRepo 2>&1 | Out-String
                $excused = @($skipOut -split "`r?`n" | Where-Object { $_ -match '^GUARD DUE' })
                if ($excused.Count -gt 0) {
                    foreach ($line in $excused) { Write-Host ("  excused: {0}" -f $line.Trim()) }
                    Write-Host "  (say which of these cannot run here, and why, in the commit body)"
                } else {
                    Write-Host "  nothing was actually due - the hatch was not needed"
                }
            }
        }
        elseif (Test-Path -LiteralPath $dueScript) {
            # GHOZTTY_GUARD_DUE_REPO points the staleness question at a fixture
            # tree, so test\win32\guard-due.ps1 can measure that this gate has
            # teeth without renaming files in the real repo to make it fire.
            # Unset in every real run.
            $guardRepo = $RepoRoot
            if ($env:GHOZTTY_GUARD_DUE_REPO) { $guardRepo = $env:GHOZTTY_GUARD_DUE_REPO }
            $dueOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $dueScript check -Repo $guardRepo 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                foreach ($line in ($dueOut -split "`r?`n")) { if ($line.Trim()) { Write-Host $line } }
                Write-Host "  (an unrun harness is a problem here: run it, or fix what it catches, before committing)"
                $problems++
            }
        }

        # T1231: a control character inside a repository text file. It is here
        # rather than in a lint nobody runs because the damage is INVISIBLE:
        # `zig-out\bin` written as `zig-out<0x08>in` reads as a typo to a human
        # and is a path that cannot exist to a script, and fifteen files sat in
        # that state - one of them scripts\guard-due.ps1's own coverage table,
        # where the broken path silently disabled a guard row. Skipped for
        # -TaskDir fixture runs for the same reason the guard-due check is -
        # unless GHOZTTY_CONTROL_CHAR_REPO is set, which is the harness pointing
        # this gate at a fixture tree so it can be driven RED without planting
        # damage in the real repo. Unset in every real run.
        if (-not $TaskDirGiven -or $env:GHOZTTY_CONTROL_CHAR_REPO) {
            $ccScript = Join-Path $PSScriptRoot 'control-char-scan.ps1'
            $ccRepo = $RepoRoot
            if ($env:GHOZTTY_CONTROL_CHAR_REPO) { $ccRepo = $env:GHOZTTY_CONTROL_CHAR_REPO }
            if (Test-Path -LiteralPath $ccScript) {
                $ccOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $ccScript -Repo $ccRepo -Quiet 2>&1 | Out-String
                if ($LASTEXITCODE -eq 1) {
                    Write-Host "CONTROL CHARACTERS: a tracked text file holds a byte no text file should (T1231)"
                    foreach ($line in ($ccOut -split "`r?`n")) { if ($line.Trim()) { Write-Host ("  " + $line.TrimEnd()) } }
                    $problems++
                }
            }
        }

        # T847: stranded work - paths that were already dirty when this turn
        # claimed the loop (snapshotted by go-loop-exec.ps1 claim, which owns
        # the rationale). Failing here is what makes the claim-time report a
        # gate rather than a line nobody must act on: 2,600 lines of a dead
        # turn's work sat uncommitted for two days while validate passed every
        # commit that landed around it. Resolution is any of: commit the
        # stranded paths (their own commit), revert them, or hand them to a
        # filed task with `ack-stranded <Tid>` - the ack holds while that task
        # is open, so the loop keeps moving without the gate going quiet.
        # GHOZTTY_STRANDED_REPO points the check at a fixture tree for the
        # acceptance harness; unset in every real run. Skipped for -TaskDir
        # fixture runs for the same reason the guard-due check is - unless the
        # env override is set, which is the harness explicitly testing THIS
        # gate (a fixture task dir plus a fixture repo is the only way to
        # exercise the ack path without leaning on the real tracker's state).
        if (-not $TaskDirGiven -or $env:GHOZTTY_STRANDED_REPO) {
            $strandedRepo = $RepoRoot
            if ($env:GHOZTTY_STRANDED_REPO) { $strandedRepo = $env:GHOZTTY_STRANDED_REPO }
            $strandedPath = Join-Path (Join-Path $strandedRepo 'temp') 'go-loop.stranded.json'
            if (Test-Path -LiteralPath $strandedPath) {
                $snap = $null
                try { $snap = Get-Content -LiteralPath $strandedPath -Raw | ConvertFrom-Json } catch { }
                if ($snap -and $snap.paths) {
                    $nowDirty = @(& git -C $strandedRepo status --porcelain 2>$null |
                        Where-Object { $_ } | ForEach-Object { $_.Substring(3) })
                    $still = @($snap.paths | Where-Object { $nowDirty -contains $_ })
                    $ackPaths = @()
                    $ackId = [string]$snap.ackTask
                    if ($ackId -and $byId.ContainsKey($ackId) -and -not (Test-Done $byId[$ackId].Status)) {
                        $ackPaths = @($snap.ackPaths)
                    }
                    $unacked = @($still | Where-Object { $ackPaths -notcontains $_ })
                    if ($still.Count -eq 0) {
                        # All resolved; the snapshot has served its purpose.
                        Remove-Item -LiteralPath $strandedPath -Force -ErrorAction SilentlyContinue
                    } elseif ($unacked.Count -gt 0) {
                        Write-Host ("STRANDED WORK: {0} path(s) were already dirty when this turn claimed the loop and still are:" -f $unacked.Count)
                        foreach ($p in @($unacked | Select-Object -First 8)) { Write-Host ("  {0}" -f $p) }
                        if ($unacked.Count -gt 8) { Write-Host ("  ... and {0} more" -f ($unacked.Count - 8)) }
                        Write-Host "  (a dead turn's work must not strand again: commit it as its own change, revert it, or file a task for it and run: parity-tasks.ps1 ack-stranded <Tid>)"
                        $problems++
                    } else {
                        Write-Host ("STRANDED WORK ACKNOWLEDGED: {0} path(s) are {1}'s to resolve (not blocking while it is open)" -f $still.Count, $ackId)
                    }
                }
            }
        }

        # T1057: unpushed work. The rule ("push immediately after EVERY commit",
        # go.md step 4) predates this gate by two weeks and had to be restated
        # by the user on 2026-08-21, which is the tell that an honour-system
        # rule is not a rule. This is the same division of labour as the two
        # checks above - go-loop-exec.ps1's claim REPORTS it at the top of the
        # turn, and this gate, the one every commit passes through, FAILS on it
        # - so the loop cannot narrate a finished task over a commit that only
        # exists here. GHOZTTY_UNPUSHED_REPO points the question at a fixture
        # tree for the acceptance harness; unset in every real run.
        $pushScript = Join-Path $PSScriptRoot 'git-commit-guard.ps1'
        if ($TaskDirGiven -and -not $env:GHOZTTY_UNPUSHED_REPO) {
            # A fixture run is somebody testing the tracker, not the loop's
            # pre-commit gate (same reason as the guard-due check above).
        }
        elseif ($NoPushCheck) {
            Write-Host "PUSH CHECK SKIPPED (-NoPushCheck): nobody checked whether this branch is ahead of its upstream"
        }
        elseif (Test-Path -LiteralPath $pushScript) {
            $pushRepo = $RepoRoot
            if ($env:GHOZTTY_UNPUSHED_REPO) { $pushRepo = $env:GHOZTTY_UNPUSHED_REPO }
            $pushOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $pushScript unpushed -Repo $pushRepo -Quiet 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                foreach ($line in ($pushOut -split "`r?`n")) { if ($line.Trim()) { Write-Host $line } }
                $problems++
            }
        }

        # T1219: is the branch this commit is landing on actually building?
        # The loop pushes on every turn (the gate above makes sure of it) and a
        # build machine answers within minutes; nothing read that answer until
        # this line, so fork-ci sat red for ten hours on 2026-08-31 with the
        # failure that later killed a release. Reported by
        # go-loop-exec.ps1's claim at the top of the turn, FAILED ON here - the
        # same division of labour as stranded and unpushed work above. An
        # in-progress run is not a failure: every turn's own push is still
        # building at this point, and gating on it would stop the loop dead at
        # each boundary for no information. GHOZTTY_CI_RUNS_JSON /
        # GHOZTTY_CI_SHA point the question at a fixture payload for the
        # acceptance harness; unset in every real run.
        $ciScript = Join-Path $PSScriptRoot 'ci-status.ps1'
        if ($TaskDirGiven -and -not $env:GHOZTTY_CI_RUNS_JSON) {
            # A fixture run is somebody testing the tracker, not the loop's
            # pre-commit gate (same reason as the guard-due check above).
        }
        elseif ($NoCiCheck) {
            Write-Host "CI CHECK SKIPPED (-NoCiCheck): nobody checked whether the build machine is green on this branch"
        }
        elseif (Test-Path -LiteralPath $ciScript) {
            $ciOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $ciScript check -Repo $RepoRoot -Quiet 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                foreach ($line in ($ciOut -split "`r?`n")) { if ($line.Trim()) { Write-Host $line } }
                $problems++
            }
        }

        Write-Host ""
        if ($problems -eq 0) {
            Write-Host ("ALL PASS ({0} tasks)" -f @($tasks).Count)
            exit 0
        }
        Write-Host ("{0} PROBLEM(S) across {1} tasks" -f $problems, @($tasks).Count)
        exit 1
    }
}
