<#
.SYNOPSIS
  Report which acceptance harnesses have not been run since the code they
  cover last changed.

.DESCRIPTION
  T783. On 2026-08-11 b64c3e8aa prefixed every scripts\go-loop-lock.ps1 message
  with an ISO timestamp. 26 assertions in test\win32\go-loop-guard.ps1 anchor on
  the answer's FIRST WORD (^ACQUIRED, ^held, ^stale-dead), so the whole guard
  went red against a lock script that was working perfectly - and nobody noticed
  for a day, because that guard is not in the P1-P3 floor and nothing tied an
  edit of the loop's scripts to it. The loop's supervisor is the one thing whose
  failure nothing else can catch, so its harness going quietly red is the worst
  place in the tree for that gap.

  THE MECHANISM. A green harness run STAMPS the content of every file it covers
  (scripts\guard-due.ps1 update, called by the harness itself). This command
  compares the files on disk against that stamp:

    * every covered file hashes the same as the stamp  => the harness has been
      run against exactly this code. CURRENT, exit 0.
    * any covered file changed, appeared, or vanished  => nothing has run that
      harness against the code as it now stands. DUE, exit 1, naming the files.

  It is a CHANGE gate, not a schedule: a stamp does not go stale with time, and
  a file edited and edited back is not due. The stamp is committed, so it
  travels with the change - a `git pull` that brings in a loop-script edit made
  on another seat reads as DUE here, which is the case a purely local mtime or
  a "did this turn touch it" check cannot see.

  WHAT IT IS NOT. It never runs the harness (that would put a multi-minute
  GUI-launching acceptance script inside whatever called this), and it never
  decides that a harness PASSES - only that one has not been asked. A red
  harness run leaves the stamp alone, so red stays due.

  WIRED INTO (both deliberately different in force):
    * scripts\go-loop-exec.ps1 claim - go.md step 0, every turn. Reports, never
      fails: a claim that can exit nonzero over a stale stamp would wedge the
      loop, which is the disease, not the cure.
    * scripts\parity-tasks.ps1 validate - go.md step 6, before every commit.
      FAILS, because that is the gate with teeth, and the remedy (run the
      harness, or fix what it caught) is the work this exists to cause.

  Acceptance: test\win32\guard-due.ps1.

.EXAMPLE
  powershell -NoProfile -File scripts\guard-due.ps1
  powershell -NoProfile -File scripts\guard-due.ps1 check -Json
  powershell -NoProfile -File scripts\guard-due.ps1 update -Guard go-loop
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'update', 'list')]
    [string]$Action = 'check',

    # Limit to one harness by name. Omitted => every row in the table.
    [string]$Guard,

    [string]$Repo,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

# ---------------------------------------------------------------------------
# The coverage table. One row per harness; adding a row is the whole cost of
# closing this gap for the next harness that grows one.
#
# `Covers` are repo-relative globs. Keep a row to the family the harness is
# ABOUT: a gate that demands a go-loop run every time a shared library moves is
# noise, and noise is how a gate gets ignored. scripts\lib\NativeArgv.ps1 is
# reached transitively from here and is deliberately NOT covered - it has its
# own acceptance (test\win32\cli-argv-fidelity.ps1), which is the same argument
# in the other direction.
# ---------------------------------------------------------------------------
$GuardTable = @(
    [pscustomobject]@{
        Name   = 'go-loop'
        Script = 'test\win32\go-loop-guard.ps1'
        Stamp  = 'test\win32\go-loop-guard.stamp.json'
        Covers = @(
            'scripts\go-loop-*.ps1',
            'scripts\loop-session.ps1',
            'test\win32\go-loop-guard.ps1'
        )
    },
    # Crash evidence is the other thing whose failure nothing else catches: a
    # capture path that has quietly stopped working looks exactly like a lane
    # that did not crash, and is only ever exercised on a day already going
    # badly. scripts\floor-lane.ps1 is deliberately NOT covered - it is edited
    # for reasons that have nothing to do with crash capture (stall detection,
    # lane table), and a gate that fires on those is the noise T783 warns about.
    [pscustomobject]@{
        Name   = 'crash-first-chance'
        Script = 'test\win32\crash-first-chance.ps1'
        Stamp  = 'test\win32\crash-first-chance.stamp.json'
        Covers = @(
            'scripts\lib\CrashDump.ps1',
            'scripts\lib\CrashCatch.ps1',
            'scripts\crash-catch.ps1',
            'test\win32\crash-first-chance.ps1'
        )
    },
    # The cache self-heal (T494) fires only on a torn cache, i.e. on a day
    # already going badly, so a quietly broken detector looks exactly like "no
    # corruption happened". scripts\floor-lane.ps1 itself stays uncovered for
    # the same reason as in the crash rows: its heal wiring is proven by this
    # harness's parse/wiring arms without gating every stall-detector edit.
    [pscustomobject]@{
        Name   = 'cache-heal'
        Script = 'test\win32\floor-lane-cache-heal.ps1'
        Stamp  = 'test\win32\floor-lane-cache-heal.stamp.json'
        Covers = @(
            'scripts\lib\CacheHeal.ps1',
            'test\win32\floor-lane-cache-heal.ps1'
        )
    },
    # The T443 instruments have the same failure profile as the crash captures,
    # in its purest form: T832 exists because both of them measured a condition
    # the defect has never occurred in, and reported "all clear" for months
    # while it was still there. A broken soak or a breakpoint that never arms
    # is indistinguishable from good news, so the harness has to be run against
    # the code as it stands rather than remembered.
    [pscustomobject]@{
        Name   = 'test-binary-soak'
        Script = 'test\win32\test-binary-soak.ps1'
        Stamp  = 'test\win32\test-binary-soak.stamp.json'
        Covers = @(
            'scripts\test-binary-soak.ps1',
            'test\win32\test-binary-soak.ps1'
        )
    },
    [pscustomobject]@{
        Name   = 'crash-databreak'
        Script = 'test\win32\crash-databreak.ps1'
        Stamp  = 'test\win32\crash-databreak.stamp.json'
        Covers = @(
            'scripts\crash-databreak.ps1',
            'scripts\lib\DataBreak.ps1',
            # DataBreak plants its breakpoints THROUGH New-CdbScript, so the
            # filter list and the script's tail are load-bearing here too. T478
            # armed the breakpoint exception and changed that tail; without this
            # row nothing would have asked whether a planted bp still fires.
            'scripts\lib\CrashCatch.ps1',
            'test\win32\crash-databreak.ps1'
        )
    },
    # crash-stacks.ps1 is the acceptance for the catcher ITSELF, and until T478
    # nothing tied it to the library it tests: the `bpe` blind spot -- a Zig
    # panic reported as "ran clean" on 10 runs out of 10 -- went a month without
    # a harness anyone was obliged to run. Overlapping crash-first-chance's
    # coverage is deliberate; the two prove different halves (this one catches a
    # crash live, that one reads the dump Windows already wrote).
    [pscustomobject]@{
        Name   = 'crash-stacks'
        Script = 'test\win32\crash-stacks.ps1'
        Stamp  = 'test\win32\crash-stacks.stamp.json'
        Covers = @(
            'scripts\lib\CrashCatch.ps1',
            'scripts\crash-catch.ps1',
            'test\win32\crash-stacks.ps1'
        )
    },
    # The banner is the one piece of chrome the user reads all day, and its
    # regressions are HORIZONTAL - a column that stops halfway is invisible to
    # every height oracle in the suite, so only pane-banner.ps1's pixel probes
    # can see it. The row was held back while that script was one-run-in-three
    # red; T835 found the flake was in the CAPTURE, not the banner, and with a
    # synchronous capture the script is deterministic enough to gate on.
    [pscustomobject]@{
        Name   = 'pane-banner'
        Script = 'test\win32\pane-banner.ps1'
        Stamp  = 'test\win32\pane-banner.stamp.json'
        Covers = @(
            'src\apprt\win32\BannerOverlay.zig',
            'src\apprt\win32\banner_layout.zig',
            'src\apprt\win32\banner_card.zig',
            'src\apprt\win32\banner_markdown.zig',
            'src\apprt\win32\banner_link.zig',
            'src\apprt\win32\BannerDialog.zig',
            'test\win32\pane-banner.ps1'
        )
    },
    # The loop's own continuation mechanism, and a harness with a history of
    # crying wolf (T483): its section B once flaked 1-in-3, so an edit to it
    # that nobody re-runs is exactly the "trusted from memory" gap T783 closes.
    # The helper it tests lives in the plugin cache OUTSIDE this repo, so the
    # row can only cover the script itself - the D-section arms are what tie
    # the cache copy to its source repo.
    [pscustomobject]@{
        Name   = 'reset-context'
        Script = 'test\win32\reset-context.ps1'
        Stamp  = 'test\win32\reset-context.stamp.json'
        Covers = @(
            'test\win32\reset-context.ps1'
        )
    },
    # The CLI's flag-rejection contract (T489): every field-parsing verb
    # routes its unknown/misvalued flags through args.zig's reporter, and
    # nothing in the P1-P3 floor ever types a MISTYPED flag - a regression
    # here reads as scripts quietly doing the wrong thing, which is the
    # silent-ignore disease the task existed for. The row stays on args.zig
    # (the engine) rather than all of src\cli: per-verb wiring is pinned by
    # the none-lane unit tests the floor already runs.
    [pscustomobject]@{
        Name   = 'cli-unknown-flag'
        Script = 'test\win32\cli-unknown-flag.ps1'
        Stamp  = 'test\win32\cli-unknown-flag.stamp.json'
        Covers = @(
            'src\cli\args.zig',
            'test\win32\cli-unknown-flag.ps1'
        )
    },
    # The window-name env export (T492): panes of AUTO-named windows carry
    # $GHOZTTY_WINDOW_NAME, which nothing in the P1-P3 floor reads back out of
    # a pane's shell. The bake lives inside src\apprt\win32\Surface.zig's init,
    # which is deliberately NOT covered - that file moves for reasons that have
    # nothing to do with env bakes, and a gate that launches a multi-window GUI
    # harness on every Surface edit is the noise T783 warns about. The row
    # covers the script itself (the reset-context precedent).
    [pscustomobject]@{
        Name   = 'window-name-env'
        Script = 'test\win32\window-name-env.ps1'
        Stamp  = 'test\win32\window-name-env.stamp.json'
        Covers = @(
            'test\win32\window-name-env.ps1'
        )
    },
    # Shell-integration detection + the agent argv delivery (T151, T513):
    # detectShell's Windows spellings (.exe suffix, full paths, mixed case)
    # are proven end-to-end only by this harness — the none-lane unit tests
    # pin the table, but nothing else in the floor opens an agent-backed pane
    # and reads the child's command line back. The row stays on
    # shell_integration.zig (the subject) rather than all of src\termio:
    # Exec.zig moves for reasons that have nothing to do with detection.
    [pscustomobject]@{
        Name   = 'agent-shell-integration'
        Script = 'test\win32\agent-shell-integration.ps1'
        Stamp  = 'test\win32\agent-shell-integration.stamp.json'
        Covers = @(
            'src\termio\shell_integration.zig',
            'test\win32\agent-shell-integration.ps1'
        )
    },
    # The GUI launch-command path (T104, T487, T514): -e / --command= / a
    # config `command`, incl. the bare-shell-as-shell-choice forwarding. The
    # row stays on the harness itself: the code under test lives in core
    # src\Surface.zig, which moves for a hundred reasons this 4-minute GUI
    # harness cannot see, so covering it there would wedge every core edit.
    # An edit to the harness (or its assertions) must re-prove itself, which
    # before this row nothing required.
    [pscustomobject]@{
        Name   = 'gui-launch-command'
        Script = 'test\win32\gui-launch-command.ps1'
        Stamp  = 'test\win32\gui-launch-command.stamp.json'
        Covers = @(
            'test\win32\gui-launch-command.ps1'
        )
    },
    # The dashboard (T505): its detached server keeps serving whatever code it
    # was started with, so a page or server edit that broke the app stays "up"
    # and is only ever met by the user. Nothing in the P1-P3 floor touches it.
    # scripts\task-dashboard.ps1 (the pane launcher) is deliberately NOT
    # covered - it moves for pane/viewer reasons the HTTP harness cannot see.
    [pscustomobject]@{
        Name   = 'task-dashboard'
        Script = 'test\win32\task-dashboard.ps1'
        Stamp  = 'test\win32\task-dashboard.stamp.json'
        Covers = @(
            'scripts\task-dashboard.js',
            'scripts\task-dashboard.page.html',
            'test\win32\task-dashboard.ps1'
        )
    }
)

function Get-RepoRelative([string]$full) {
    $rel = $full.Substring($Repo.Length).TrimStart('\', '/')
    return $rel.Replace('\', '/')
}

function Get-CoveredFiles($row) {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $row.Covers) {
        $full = Join-Path $Repo $pattern
        foreach ($f in @(Get-ChildItem -Path $full -File -ErrorAction SilentlyContinue)) {
            $rel = Get-RepoRelative $f.FullName
            if (-not $found.Contains($rel)) { $found.Add($rel) | Out-Null }
        }
    }
    # Ordinal sort so the stamp's key order is the same on every box.
    return @($found.ToArray() | Sort-Object -CaseSensitive)
}

function Get-NormalizedHash([string]$relPath) {
    <#
      SHA-256 of the file's bytes with CRLF folded to LF and any UTF-8 BOM
      dropped. .ps1 carries no `text` attribute in .gitattributes, so the bytes
      on disk depend on the checkout's line-ending settings; hashing them raw
      would report every file as changed on a differently-configured clone, and
      a gate that cries wolf on a fresh clone is a gate nobody reads.
    #>
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Repo $relPath))
    $out = New-Object System.Collections.Generic.List[byte]
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) { continue }
        $out.Add($bytes[$i])
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($out.ToArray())
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
}

function Get-LiveMap($row) {
    $map = [ordered]@{}
    foreach ($rel in (Get-CoveredFiles $row)) { $map[$rel] = Get-NormalizedHash $rel }
    return $map
}

function Read-Stamp($row) {
    $path = Join-Path $Repo $row.Stamp
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Get-StampMap($stamp) {
    $map = [ordered]@{}
    if ($null -eq $stamp -or $null -eq $stamp.files) { return $map }
    foreach ($p in $stamp.files.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

function Get-GuardState($row) {
    <#
      The whole decision, as data: Kind ('current' | 'due'), Findings (one per
      file that moved), plus what the stamp said. Pure apart from reading files,
      so `check`, `-Json` and the acceptance script all read the same answer.
    #>
    $live = Get-LiveMap $row
    $stamp = Read-Stamp $row
    $stamped = Get-StampMap $stamp

    # A row whose coverage matches NO file in this tree is not applicable here:
    # there is nothing that could have changed, so it cannot be due. That is the
    # normal case whenever the gate is pointed at a foreign tree -- which is
    # exactly what this gate's own acceptance script does, with a fixture repo
    # shaped like ONE row. Without this, adding a second row to the table made
    # eight of its arms fail over an exit code that had nothing to do with them,
    # and every future row would do it again.
    #
    # It is reported, never silent: a row whose globs are a typo says so as
    # `GUARD N/A`, which is a different sentence from `GUARD CURRENT` and cannot
    # be mistaken for one.
    if ($live.Count -eq 0 -and $null -eq $stamp) {
        return [pscustomobject]@{
            Name = $row.Name; Script = $row.Script; Stamp = $row.Stamp
            Kind = 'n/a'; Reason = 'no-covered-files'; Findings = @()
            Files = @(); StampedAt = ''; StampedCommit = ''
        }
    }
    # A plain array, not a generic List: PowerShell 5.1's enumerable binder
    # throws "Argument types do not match" on @(<empty List[object]>), which is
    # exactly the CURRENT case - the one this gate reports most often.
    $findings = @()

    if ($null -eq $stamp) {
        return [pscustomobject]@{
            Name = $row.Name; Script = $row.Script; Stamp = $row.Stamp
            Kind = 'due'; Reason = 'no-stamp'; Findings = @()
            Files = @($live.Keys); StampedAt = ''; StampedCommit = ''
        }
    }

    foreach ($rel in $live.Keys) {
        if (-not $stamped.Contains($rel)) {
            $findings += [pscustomobject]@{ Kind = 'new'; Path = $rel }
        } elseif ($stamped[$rel] -ne $live[$rel]) {
            $findings += [pscustomobject]@{ Kind = 'changed'; Path = $rel }
        }
    }
    foreach ($rel in @($stamped.Keys)) {
        if (-not $live.Contains($rel)) {
            $findings += [pscustomobject]@{ Kind = 'removed'; Path = $rel }
        }
    }

    $kind = if ($findings.Count -gt 0) { 'due' } else { 'current' }
    $reason = if ($findings.Count -gt 0) { 'covered-files-changed' } else { '' }
    return [pscustomobject]@{
        Name = $row.Name; Script = $row.Script; Stamp = $row.Stamp
        Kind = $kind; Reason = $reason; Findings = $findings
        Files = @($live.Keys)
        StampedAt = [string]$stamp.generated
        StampedCommit = [string]$stamp.commit
    }
}

function Write-Stamp($row) {
    <#
      Rewrite the stamp only when the file MAP actually moved. A green harness
      run that changed nothing must leave a clean working tree behind it -
      otherwise every run of the harness produces a diff, and a diff nobody
      means is a diff nobody reads.
    #>
    $live = Get-LiveMap $row
    $existing = Get-StampMap (Read-Stamp $row)
    $same = ($existing.Count -eq $live.Count)
    if ($same) {
        foreach ($k in $live.Keys) {
            if (-not $existing.Contains($k) -or $existing[$k] -ne $live[$k]) { $same = $false; break }
        }
    }
    if ($same) { return [pscustomobject]@{ Written = $false; Files = @($live.Keys) } }

    $commit = ''
    try { $commit = (& git -C $Repo rev-parse --short HEAD 2>$null | Out-String).Trim() } catch { $commit = '' }

    $files = [ordered]@{}
    foreach ($k in $live.Keys) { $files[$k] = $live[$k] }
    $doc = [ordered]@{
        guard     = $row.Name
        script    = $row.Script.Replace('\', '/')
        generated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        commit    = $commit
        files     = $files
    }
    $json = ($doc | ConvertTo-Json -Depth 5)
    $path = Join-Path $Repo $row.Stamp
    # UTF-8 without a BOM, LF endings: *.json is `text eol=lf` in .gitattributes.
    [System.IO.File]::WriteAllText($path, ($json -replace "`r`n", "`n") + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Written = $true; Files = @($live.Keys) }
}

$rows = @($GuardTable)
if ($Guard) {
    $rows = @($GuardTable | Where-Object { $_.Name -eq $Guard })
    if ($rows.Count -eq 0) {
        Write-Host ("ERROR unknown guard '{0}' (known: {1})" -f $Guard, (($GuardTable | ForEach-Object { $_.Name }) -join ', '))
        exit 2
    }
}

switch ($Action) {

    'list' {
        foreach ($row in $rows) {
            "{0}  {1}" -f $row.Name, $row.Script
            foreach ($rel in (Get-CoveredFiles $row)) { "    $rel" }
        }
        exit 0
    }

    'update' {
        $wrote = 0
        foreach ($row in $rows) {
            $r = Write-Stamp $row
            if ($r.Written) {
                "STAMPED {0} ({1} files) -> {2}" -f $row.Name, @($r.Files).Count, $row.Stamp
                $wrote++
            } else {
                "STAMP UNCHANGED {0} ({1} files)" -f $row.Name, @($r.Files).Count
            }
        }
        exit 0
    }

    'check' {
        $states = @(foreach ($row in $rows) { Get-GuardState $row })
        if ($Json) {
            # An array, always - a single-row table must not collapse to an object.
            ConvertTo-Json -Depth 6 -InputObject @($states)
            exit ([int](@($states | Where-Object { $_.Kind -eq 'due' }).Count -gt 0))
        }
        $due = 0
        foreach ($s in $states) {
            if ($s.Kind -eq 'n/a') {
                "GUARD N/A {0}: nothing in this tree matches its coverage" -f $s.Name
                continue
            }
            if ($s.Kind -eq 'current') {
                $stampedAt = if ($s.StampedAt) { $s.StampedAt.Substring(0, [Math]::Min(10, $s.StampedAt.Length)) } else { '?' }
                "GUARD CURRENT {0} ({1} files, stamped {2}{3})" -f $s.Name, @($s.Files).Count, $stampedAt,
                    $(if ($s.StampedCommit) { " from $($s.StampedCommit)" } else { '' })
                continue
            }
            $due++
            if ($s.Reason -eq 'no-stamp') {
                "GUARD DUE {0}: no stamp - {1} has never recorded a green run over this code" -f $s.Name, $s.Script
            } else {
                "GUARD DUE {0}: {1} has not been run since these changed:" -f $s.Name, $s.Script
                foreach ($f in $s.Findings) { "    {0,-8} {1}" -f $f.Kind, $f.Path }
            }
            "  run: powershell -NoProfile -File {0}" -f $s.Script
        }
        exit ([int]($due -gt 0))
    }
}
