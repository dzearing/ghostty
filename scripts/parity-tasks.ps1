<#
.SYNOPSIS
  Query and create Windows-parity tasks stored one-file-per-task under
  docs/design/windows-parity-tasks/.

.DESCRIPTION
  Replaces the single-file state table. Each task is <id>.md with YAML
  frontmatter (id, title, phase, deps, status, commits, seat) plus a Summary
  and optional Details body. One file per task means two agents can add and
  edit tasks concurrently without touching the same file.

  SEATS (T344). A task's `seat:` says which box can actually do it: `win` (the
  Windows box, and the default when the field is absent), `mac` (needs a macOS
  build/run), or `any`. `next` and `list` filter on it so the Windows loop is
  never handed a task whose validation starts "Mac regression build" - which is
  a permanent stall, since `next` is a pure function of the files.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
  scripts\parity-tasks.ps1 list -Status todo
  scripts\parity-tasks.ps1 next
  scripts\parity-tasks.ps1 next -Seat mac
  scripts\parity-tasks.ps1 show T144
  scripts\parity-tasks.ps1 new -Title "Fix the thing" -Phase K -Deps T73,T94
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('list', 'next', 'show', 'new', 'set-status', 'validate')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Id,

    [string]$Status,
    [string]$Phase,
    [string[]]$Deps,
    [string]$Title,
    [string]$Summary,
    [string]$Commit,

    # Which box can do the work: win (default) | mac | any. `list`/`next` treat
    # it as a filter, `new` writes it into the created file.
    [ValidateSet('win', 'mac', 'any', 'all')]
    [string]$Seat,

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

    $seat = & $unquote (& $get 'seat')
    if (-not $seat) { $seat = $DefaultSeat }

    [PSCustomObject]@{
        Id      = & $get 'id'
        Title   = & $unquote (& $get 'title')
        Phase   = & $unquote (& $get 'phase')
        Deps    = & $parseList (& $get 'deps')
        Status  = & $unquote (& $get 'status')
        Commits = & $parseList (& $get 'commits')
        Seat    = $seat
        Path    = $Path
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

# --------------------------------------------------------------- commands ---

switch ($Command) {

    'list' {
        $tasks = Get-AllTasks
        # `list` shows everything unless asked otherwise: it is the human's
        # view of the tracker, where hiding rows by default would be a lie.
        $wantSeat = if ($Seat) { $Seat } else { 'all' }
        if ($Status) { $tasks = $tasks | Where-Object { $_.Status -like "$Status*" } }
        if ($Phase) { $tasks = $tasks | Where-Object { $_.Phase -eq $Phase } }
        $tasks = @($tasks | Where-Object { Test-SeatMatch $_.Seat $wantSeat })
        $tasks | Select-Object `
            Id,
        Status,
        Phase,
        Seat,
        @{ N = 'Deps'; E = { ($_.Deps -join ',') } },
        @{ N = 'Title'; E = { if ($_.Title.Length -gt 70) { $_.Title.Substring(0, 67) + '...' } else { $_.Title } } } |
        Format-Table -AutoSize
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

        $blocked = @()
        foreach ($t in $tasks) {
            if ($t.Status -notmatch '^todo') { continue }
            if (-not (Test-SeatMatch $t.Seat $wantSeat)) { continue }
            $unmet = @()
            foreach ($d in $t.Deps) {
                if (-not $byId.ContainsKey($d)) { continue }   # unknown dep: ignore, don't block
                if (-not (Test-Done $byId[$d].Status)) { $unmet += $d }
            }
            if ($unmet.Count -eq 0) {
                Write-Host ("NEXT: {0} - {1}" -f $t.Id, $t.Title)
                Write-Host ("      phase={0} deps={1} seat={2}" -f $t.Phase, ($t.Deps -join ','), $t.Seat)
                Write-Host ("      file: docs/design/windows-parity-tasks/{0}.md" -f $t.Id)
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
        $json = ConvertTo-Json $Status -Compress
        $new = [regex]::Replace($text, '(?m)^status:\s*.*$', "status: $json", 1)
        if ($Commit) {
            $existing = (ConvertFrom-Frontmatter -Path $path).Commits
            $all = @($existing) + @($Commit)
            $listJson = '[' + (($all | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ', ') + ']'
            $new = [regex]::Replace($new, '(?m)^commits:\s*.*$', "commits: $listJson", 1)
        }
        [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ("{0} -> {1}" -f $tid, $Status)
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
        $phaseJson = 'null'
        if ($Phase) { $phaseJson = ConvertTo-Json $Phase -Compress }

        # `all` is a filter, not a seat a task can hold.
        $seatValue = if ($Seat -and $Seat -ne 'all') { $Seat } else { $DefaultSeat }

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
                    "phase: $phaseJson"
                    "deps: $depsJson"
                    'status: "todo"'
                    'commits: []'
                    ("seat: " + (ConvertTo-Json $seatValue -Compress))
                    '---'
                    ''
                    "# $tid - $Title"
                    ''
                    '## Summary'
                    ''
                    $body
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
            }
            if ($t.Status -notmatch '^(todo|in-progress|done|blocked|skipped)') {
                Write-Host ("ODD STATUS: {0} = '{1}'" -f $t.Id, $t.Status); $problems++
            }
            # A typo'd seat would hide the task from every seat's `next`, which
            # is exactly the silent stall this field exists to end.
            if ($ValidSeats -notcontains $t.Seat) {
                Write-Host ("ODD SEAT: {0} = '{1}' (want one of: {2})" -f $t.Id, $t.Seat, ($ValidSeats -join ', ')); $problems++
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
