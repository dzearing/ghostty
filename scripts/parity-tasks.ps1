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

.EXAMPLE
  scripts\parity-tasks.ps1 list -Status todo
  scripts\parity-tasks.ps1 next
  scripts\parity-tasks.ps1 next -Seat mac
  scripts\parity-tasks.ps1 show T144
  scripts\parity-tasks.ps1 new -Title "Fix the thing" -Deps T73,T94 -Tags fix,polish
  scripts\parity-tasks.ps1 note T144 -Text "caption_layout re-pinned; next: slab fills"
  scripts\parity-tasks.ps1 set-order T377 -Order 2
  scripts\parity-tasks.ps1 set-order T500 -Order 2.5   # inject without renumbering
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('list', 'next', 'show', 'new', 'set-status', 'set-priority', 'set-order', 'note', 'ack-stranded', 'validate')]
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

    # Escape hatch so the acceptance script can drive a fixture directory
    # instead of the real tracker (same idea as GHOSTTY_HOST_DEFAULTS).
    [string]$TaskDir,

    # `validate` also asks scripts\guard-due.ps1 whether an acceptance harness
    # has gone unrun since the code it covers changed (T783) - this is the
    # pre-commit gate every turn runs, so it is where that question has teeth.
    # The hatch is for the genuinely stuck case (a harness that cannot run on
    # this box at all); it PRINTS that it was used, so a commit made under it
    # can be explained rather than silently excused.
    [switch]$NoGuardDue
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
        [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
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
            Write-Host "GUARD DUE CHECK SKIPPED (-NoGuardDue): harness staleness was not checked for this commit"
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

        Write-Host ""
        if ($problems -eq 0) {
            Write-Host ("ALL PASS ({0} tasks)" -f @($tasks).Count)
            exit 0
        }
        Write-Host ("{0} PROBLEM(S) across {1} tasks" -f $problems, @($tasks).Count)
        exit 1
    }
}
