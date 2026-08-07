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
    [ValidateSet('list', 'next', 'show', 'new', 'set-status', 'set-priority', 'set-order', 'note', 'validate')]
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
    # UX polish | P2 infra and nice-to-have. `next` picks P0 before P1 before
    # P2, which is the whole point of the field: without it the loop worked in
    # id order and shipped whatever had been logged most recently.
    [ValidateSet('P0', 'P1', 'P2')]
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
    # transition's progress-log entry. Optional, because the transition is
    # journaled either way - this only says whose hand was on it.
    [string]$SourceNote,

    # Suppress the progress-log entry `set-status` writes. Exists for a bulk
    # normalisation pass that would otherwise stamp a note into two hundred
    # files; it is NOT for ordinary use, because a status flip with no receipt
    # is the exact defect T564 fixed.
    [switch]$NoNote,

    # Escape hatch so the acceptance script can drive a fixture directory
    # instead of the real tracker (same idea as GHOSTTY_HOST_DEFAULTS).
    [string]$TaskDir
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
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
$DefaultPriority = 'P1'
$ValidPriorities = @('P0', 'P1', 'P2')

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

    # Absent priority means untriaged. It sorts AFTER P2 rather than defaulting
    # to the middle: a task nobody has ranked should not outrank one somebody
    # deliberately called P2.
    $priority = & $unquote (& $get 'priority')
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
        TriageReason = & $unquote (& $get 'triage-reason')
        Tags         = & $parseList (& $get 'tags')
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

# Sort key for a priority: P0 first, untriaged last.
function Get-PriorityRank {
    param([string]$P)
    switch ($P) {
        'P0' { return 0 }
        'P1' { return 1 }
        'P2' { return 2 }
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
        # Queue order, so `list` reads the same way `next` picks.
        $tasks = @($tasks | Sort-Object `
            @{ Expression = { Get-OrderRank $_.Order } }, `
            @{ Expression = { Get-PriorityRank $_.Priority } }, `
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

        # ORDER FIRST, then priority, then id.
        #
        # `order:` is the answer to "what next" - one number, so there is one
        # head of the queue rather than forty things sharing a band. Priority
        # stays as the band a human reads and filters on, and as the fallback
        # for anything not yet placed; id remains the last tiebreaker so the
        # ordering is total and deterministic no matter how little is filled in.
        #
        # Before any of this the selector walked the files in id order, so the
        # loop worked whatever had been logged earliest and a crash filed
        # yesterday queued behind two hundred older nice-to-haves (user,
        # 2026-08-04).
        $ordered = $tasks | Sort-Object `
        @{ Expression = { Get-OrderRank $_.Order } }, `
        @{ Expression = { Get-PriorityRank $_.Priority } }, `
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
        if (-not $Priority) { throw 'set-priority requires -Priority (P0|P1|P2).' }
        $path = Get-TaskPath $tid
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
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
        Write-Host ("{0} -> {1}" -f $tid, $Priority)
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

        Write-Host ""
        if ($problems -eq 0) {
            Write-Host ("ALL PASS ({0} tasks)" -f @($tasks).Count)
            exit 0
        }
        Write-Host ("{0} PROBLEM(S) across {1} tasks" -f $problems, @($tasks).Count)
        exit 1
    }
}
