<#
.SYNOPSIS
  Run the win32 acceptance suite - many scripts, one verdict table, one
  machine-readable summary.

.DESCRIPTION
  T361. `test\win32\` holds 241 top-level acceptance scripts, 136 of which drive
  a GUI, and every turn runs the two or three it believes it touched. Nothing
  ran the rest, so a change to the shared harness (`lib\TestDesktop.ps1`,
  `lib\ChromeGeometry.ps1`, `lib\CleanSlate.ps1`) was validated against a
  hand-picked sample and the other scripts were found broken by whichever future
  turn happened to open one. T267 asked for the suite "twice back to back, and
  then in reverse order" and that could not be done, because there was no runner
  and no measured runtime.

  WHAT IT DOES. Runs each script as its own `powershell -NoProfile -File` child
  with stdout+stderr redirected to a per-script log, a per-script timeout, and a
  leak sweep between scripts. It scores each run by the suite's own verdict
  contract (`test\win32\lib\TestScore.ps1`):

      exit 0 + "ALL PASS"     => pass
      exit 1 + "N FAILURE(S)" => fail
      exit 2                  => nothing   (ASSERTED NOTHING / TOO LITTLE)
      killed at the timeout   => stall
      anything else           => error     (crash, no verdict line, bad launch)

  THE TIMEOUT IS PER SCRIPT, AND A SCRIPT MAY DECLARE ITS OWN. `-TimeoutSec`
  (600 by default) is the cap for a script that says nothing; a script that
  legitimately runs longer declares it in its own text with a
  `# suite-timeout-sec: <N>` comment and is measured against that instead. That
  declaration is the difference between "this script hung" and "this script is
  a 30-minute soak" - a distinction the one global cap could not make, and did
  not: `soak.ps1` was scored `stall` on every sweep (T1125). `-MaxTimeoutSec`
  bounds every declaration for a deliberately quick pass, and the rows it
  truncates say so.

  It prints one line per script as it goes - never at the end, because a suite
  measured in hours has to be readable while it runs - and writes the same rows
  incrementally to `summary.json`, so a run that is killed half way through
  still leaves the data it bought.

  WHY IT IS SERIAL, AND STAYS SERIAL. The parallel version is not a matter of
  adding workers. Every script here resolves the app under test as
  `<repo>\zig-out\bin\ghoztty.exe` - 91 of them compute that path internally,
  ignoring any `-Exe` a caller might pass - and `lib\CleanSlate.ps1` kills the
  app under test by EXACT ExecutablePath. So two workers running out of one
  zig-out do not merely share state: each one's clean-slate kills the other's
  app, mid-assertion, with no error either of them can attribute. The same is
  true of `%LOCALAPPDATA%\ghoztty\*`, which every script clears at launch.
  Parallelism therefore needs a per-worker exe copy AND a per-worker
  LOCALAPPDATA, which needs every script to honor an injected exe path first -
  a suite-wide change, filed as its own task rather than smuggled in here.
  Until then the honest number is the serial one, and this prints it.

  ORDER INDEPENDENCE is the property T267 could not check: run the suite
  forward, forward again, and reverse, then

      powershell -NoProfile -File scripts\suite-run.ps1 compare -Runs a,b,c

  which reports every script whose verdict was not the same in all three, and
  exits nonzero if there is one. A script that only passes in one order is
  reading state its neighbour left behind.

.EXAMPLE
  powershell -NoProfile -File scripts\suite-run.ps1 list
  powershell -NoProfile -File scripts\suite-run.ps1 -Set gui
  powershell -NoProfile -File scripts\suite-run.ps1 -Set gui -Order reverse
  powershell -NoProfile -File scripts\suite-run.ps1 -Resume temp\suite-runs\20260822-021500\summary.json
  powershell -NoProfile -File scripts\suite-run.ps1 compare -Runs run1\summary.json,run2\summary.json
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'list', 'compare')]
    [string]$Action = 'run',

    # Which scripts. gui = drives a window (mentions New-TestDesktop),
    # cli = everything else (static audits, CLI/IPC scripts), all = both.
    [ValidateSet('gui', 'cli', 'all')]
    [string]$Set = 'all',

    # forward | reverse | a comma-separated list of script names, which is
    # also how you re-run exactly what a previous run reported red.
    [string]$Order = 'forward',

    # Comma-separated wildcards against the script name, applied after -Set.
    # Deliberately a single string rather than [string[]]: every script here is
    # invoked with `powershell -File`, where an argument list is parsed as
    # LITERAL text, so `-Include a,b` binds as the one string "a,b" and the
    # second pattern is silently lost. Split here instead of trusting argv.
    [string]$Include,
    [string]$Exclude,

    # Take only the first N of the ordered list (after -Skip). 0 = all.
    [int]$Limit = 0,
    [int]$Skip = 0,

    # Per-script wall-clock cap for a script that does not declare its own.
    # The tree is killed and the script scored `stall`; the suite carries on.
    [int]$TimeoutSec = 600,

    # Upper bound on a script's DECLARED cap (see Get-ScriptTimeout). 0 = the
    # declaration is honoured in full, which is the default: a script that says
    # it needs 45 minutes is believed, because the alternative is scoring it a
    # stall every sweep. This exists for the quick pass - `-MaxTimeoutSec 120`
    # bounds the whole run without having to -Exclude the long scripts by name,
    # and the rows it truncates say so.
    [int]$MaxTimeoutSec = 0,

    # Where the logs and summary.json go. Defaults to a timestamped directory
    # under temp\suite-runs\.
    [string]$OutDir,

    # Continue a previous run: its recorded verdicts are kept and those scripts
    # are not re-run. Point it at that run's summary.json.
    [string]$Resume,

    # compare: two or more summary.json paths (or their directories),
    # comma-separated. Single string for the -File reason above.
    [string]$Runs,

    # Do not kill processes left running out of the repo's zig-out between
    # scripts. Off by default because one leaked instance poisons every script
    # after it - see the leak column in the table.
    [switch]$NoSweep,

    [switch]$DryRun,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

if (-not $Repo) { $Repo = Split-Path $PSScriptRoot -Parent }
$TestRoot = Join-Path $Repo 'test\win32'

# Split a comma-separated argument into a real list. See the -Include comment
# above for why every list here arrives as one string.
function Split-List {
    param([string]$Value)
    if (-not $Value) { return @() }
    return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
# Format-Duration lives in scripts\lib so a test can call it: it is the one
# number in this report nobody can check by eye, and its first version was a
# minute wrong.
. (Join-Path $PSScriptRoot 'lib\Duration.ps1')
# T1098: the modal sweep, run beside the leak sweep for the same reason - a
# script can leave something behind that no assertion of its own can see.
#
# Resolved against THIS script's own tree, never against -Repo: the runner's
# acceptance test points -Repo at a throwaway fixture whose test\win32\lib holds
# only its own stubs, and a dependency of the runner is not something a fixture
# is expected to supply.
. (Join-Path $PSScriptRoot '..\test\win32\lib\ModalSweep.ps1')

$IncludeList = Split-List $Include
$ExcludeList = Split-List $Exclude
$RunsList = Split-List $Runs

# ---------------------------------------------------------------- enumeration

<#
The acceptance suite is the set of top-level .ps1 files in test\win32 - NOT
recursive, the same rule the verdict/skip/isolation audits use: `lib\` holds
dot-sourced libraries and `artifacts\` holds fixtures, and neither has a verdict
to score.
#>
<#
A script's own declaration of how long it legitimately needs, read from a
`# suite-timeout-sec: <N>` comment in its text. Returns 0 when it declares
nothing, which means "use the run's -TimeoutSec".

Why a declaration in the script rather than a table in this runner (T1125):
`soak.ps1` runs a 30-minute soak by design and was killed at the 600s cap on
every sweep and scored `stall` - a measurement artefact that read exactly like
the app having hung. The number belongs beside the code that spends it, because
a table here goes stale the moment somebody changes a script's -Minutes default
and nobody edits the runner.

Only the first match counts, and only a positive integer: a garbled declaration
falls back to the run's cap rather than to "no bound", the same rule
ipc_timeout.zig applies to its env var.
#>
function Get-ScriptTimeout {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $m = [regex]::Match($Text, '(?m)^[ \t]*#[ \t]*suite-timeout-sec[ \t]*:[ \t]*(\d+)[ \t]*$')
    if (-not $m.Success) { return 0 }
    $v = 0
    if (-not [int]::TryParse($m.Groups[1].Value, [ref]$v)) { return 0 }
    if ($v -le 0) { return 0 }
    return $v
}

<#
The cap this run will actually enforce on one script: its declaration when it
has one, else the run's -TimeoutSec, and never more than -MaxTimeoutSec when
that is set. Kept separate from Get-ScriptTimeout so the report can say WHICH
of the two a row was measured against.
#>
function Resolve-ScriptTimeout {
    param([int]$Declared, [int]$Default, [int]$Max)
    $t = $(if ($Declared -gt 0) { $Declared } else { $Default })
    if ($Max -gt 0 -and $t -gt $Max) { $t = $Max }
    return $t
}

function Get-SuiteScript {
    param([string]$Root, [string]$SetName, [string[]]$Inc)

    $rows = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File | Sort-Object Name)) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { $text = '' }
        # A GUI script is one that opens a test desktop. That is the property
        # that makes it slow, focus-sensitive and order-sensitive, and it is a
        # single call every such script must make (lib\TestDesktop.ps1).
        $gui = $text -match 'New-TestDesktop'
        $rows += [pscustomobject]@{
            Name     = $f.Name
            Path     = $f.FullName
            Class    = $(if ($gui) { 'gui' } else { 'cli' })
            Lines    = ($text -split "`n").Count
            Declared = (Get-ScriptTimeout -Text $text)
        }
    }

    if ($SetName -ne 'all') { $rows = @($rows | Where-Object { $_.Class -eq $SetName }) }

    if ($Inc) {
        $rows = @($rows | Where-Object {
                $n = $_.Name
                @($Inc | Where-Object { $n -like $_ }).Count -gt 0
            })
    }
    return @($rows)
}

# -Exclude is applied separately: expressing it inside the pipeline above needs
# a nested Where-Object whose $_ shadows the outer one, which is exactly the
# kind of PowerShell subtlety that silently filters nothing.
function Remove-ExcludedScript {
    param([object[]]$Rows, [string[]]$Patterns)
    if (-not $Patterns) { return @($Rows) }
    $keep = @()
    foreach ($r in $Rows) {
        $hit = $false
        foreach ($p in $Patterns) { if ($r.Name -like $p) { $hit = $true; break } }
        if (-not $hit) { $keep += $r }
    }
    return @($keep)
}

function Sort-SuiteOrder {
    param([object[]]$Rows, [string]$Spec)

    $Rows = @($Rows)
    if ($Spec -eq 'forward') { return @($Rows) }
    if ($Spec -eq 'reverse') {
        $out = @($Rows)
        if ($out.Count -gt 1) { [array]::Reverse($out) }
        return @($out)
    }

    # An explicit list. Names not in $Rows are reported rather than dropped:
    # a typo that silently runs 11 of 12 scripts is the failure mode here.
    $wanted = @($Spec -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $byName = @{}
    foreach ($r in $Rows) { $byName[$r.Name] = $r }
    $out = @()
    foreach ($w in $wanted) {
        $key = $w
        if (-not $key.EndsWith('.ps1')) { $key = "$key.ps1" }
        if ($byName.ContainsKey($key)) { $out += $byName[$key] }
        else { throw "-Order names '$w', which is not in the selected set (check -Set/-Include)." }
    }
    return @($out)
}

# ------------------------------------------------------------------- scoring

<#
Score one finished run from its exit code and its log.

The exit code is the authority - the suite's own contract (T221/T271) is that a
script printing failure exits failure - and the verdict LINE is what a human
reads. They are recorded separately on purpose: a script whose two disagree is
a defect this runner should be able to name, not paper over.
#>
function Get-VerdictLine {
    param([string]$LogPath)

    $line = ''
    if (-not $LogPath) { return $line }
    if (Test-Path -LiteralPath $LogPath) {
        $tail = @(Get-Content -LiteralPath $LogPath -Tail 40 -ErrorAction SilentlyContinue)
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $t = $tail[$i].Trim()
            if ($t) { $line = $t; break }
        }
        # Prefer an actual verdict line if one is in the tail but not last
        # (a few scripts print a teardown note after their verdict).
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $t = $tail[$i].Trim()
            if ($t -match 'ALL PASS|FAILURE\(S\)|ASSERTED (NOTHING|TOO LITTLE)|SKIP ALL') { $line = $t; break }
        }
    }
    return $line
}

function Get-RunVerdict {
    param([int]$ExitCode, [string]$LogPath, [bool]$TimedOut, [string]$AltLogPath)

    # STDOUT decides the quoted line, and stderr is only the fallback for a
    # script that said nothing there at all (T1125). The caller hands them in
    # as two files on purpose: stderr is folded onto the END of the log, so
    # scoring one merged file quotes the last stderr line as the verdict - which
    # is how a soak killed 20 minutes into its silent sampling loop was reported
    # as `Waiting for Ghoztty to answer '+list'`, a startup notice printed in its
    # first seconds, and left a hung app as the leading hypothesis for a day.
    $line = Get-VerdictLine -LogPath $LogPath
    if (-not $line) { $line = Get-VerdictLine -LogPath $AltLogPath }

    if ($TimedOut) { return @{ Kind = 'stall'; Line = $line } }

    switch ($ExitCode) {
        0 {
            if ($line -match 'ALL PASS') { return @{ Kind = 'pass'; Line = $line } }
            # Exit 0 with no pass verdict: either a script with no verdict at
            # all, or the fall-through shape T221 exists to catch.
            return @{ Kind = 'error'; Line = $(if ($line) { $line } else { '(exit 0, no verdict line)' }) }
        }
        1 { return @{ Kind = 'fail'; Line = $(if ($line) { $line } else { '(exit 1, no verdict line)' }) } }
        2 { return @{ Kind = 'nothing'; Line = $(if ($line) { $line } else { '(exit 2, no verdict line)' }) } }
        default { return @{ Kind = 'error'; Line = "exit $ExitCode - $line" } }
    }
}

# -------------------------------------------------------------- leak sweeping

<#
Kill anything still running out of the repo's zig-out after a script finishes.

Path-exact and repo-scoped, the same discipline lib\CleanSlate.ps1 uses: the
user's installed Ghoztty lives elsewhere and is never a candidate, and a match
on image NAME alone would take it and its live sessions with it.

The count is reported per script because a leak is itself a finding - the script
that leaks is usually not the script that then fails.
#>
function Invoke-LeakSweep {
    param([string]$ZigOut)

    $prefix = $ZigOut.TrimEnd('\') + '\'
    $killed = 0
    $procs = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                $_.ExecutablePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            })
    } catch { return 0 }

    foreach ($p in $procs) {
        try {
            & taskkill.exe /T /F /PID $p.ProcessId *> $null
            $killed++
        } catch { }
    }
    if ($killed -gt 0) { Start-Sleep -Milliseconds 400 }
    return $killed
}

<#
Report and dismiss any Windows error dialog a script left standing (T1098).

Same shape as the leak sweep above and for the same reason: what a script leaves
behind is a finding the script's own verdict cannot contain. A modal is the worse
of the two - it does not merely poison the scripts after it, it BLOCKS whoever
raised it until a human clicks OK, on the user's own desktop, during a sweep that
is meant to be unattended. `upgrade-staleness.ps1` raised one on every run for as
long as it has existed and scored ALL PASS each time.

Returns the modal records; the caller turns them red and names the script.
#>
function Invoke-ModalSweep {
    param([string]$ZigOut)
    $modals = @()
    try { $modals = @(Get-StrayModalDialog -ZigOut $ZigOut) } catch { return @() }
    if ($modals.Count -gt 0) {
        # Dismiss before the next script starts: the sweep exists so a stray
        # modal is reported, not so the rest of the suite runs behind it.
        try { $null = Close-StrayModalDialog -Modals $modals } catch { }
    }
    return @($modals)
}

# ------------------------------------------------------------------ one script

function Invoke-SuiteScript {
    param(
        [object]$Script,
        [string]$LogDir,
        [int]$TimeoutSeconds,
        [string]$StdinFile
    )

    $log = Join-Path $LogDir ($Script.Name -replace '\.ps1$', '')
    $outFile = "$log.log"
    $errFile = "$log.err"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $code = -1

    # NOT `$args` - that is an automatic variable, and assigning it inside a
    # function is the kind of quiet breakage PS 5.1 does not report.
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script.Path)
    $p = $null
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
            -WorkingDirectory $Repo -PassThru -NoNewWindow `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -RedirectStandardInput $StdinFile
    } catch {
        $sw.Stop()
        return [pscustomobject]@{
            Verdict = 'error'; Line = "launch failed: $($_.Exception.Message)"
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Exit = -1; Log = $outFile
        }
    }

    # T197: read $p.Handle BEFORE any wait, or ExitCode reads back empty on a
    # redirected child and a working script is scored as broken.
    $null = $p.Handle

    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try { & taskkill.exe /T /F /PID $p.Id *> $null } catch { }
        try { $null = $p.WaitForExit(5000) } catch { }
    } else {
        $p.WaitForExit()
    }
    $sw.Stop()
    try { $code = $p.ExitCode } catch { $code = -1 }
    if ($null -eq $code) { $code = -1 }

    # Scored BEFORE the fold below, from the two streams as separate files
    # (T1125) - see Get-RunVerdict for why the merged file cannot be scored.
    $v = Get-RunVerdict -ExitCode $code -LogPath $outFile -TimedOut $timedOut -AltLogPath $errFile

    # Fold stderr into the log so one file is the whole story, then drop it.
    if ((Test-Path -LiteralPath $errFile) -and (Get-Item -LiteralPath $errFile).Length -gt 0) {
        Add-Content -LiteralPath $outFile -Value "`n--- stderr ---"
        Get-Content -LiteralPath $errFile | Add-Content -LiteralPath $outFile
    }
    Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Verdict = $v.Kind
        Line    = $v.Line
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Exit    = $code
        Log     = $outFile
        Timeout = $TimeoutSeconds
    }
}

# -------------------------------------------------------------------- reporting

$VerdictTag = @{
    pass = 'PASS   '; fail = 'FAIL   '; stall = 'STALL  '
    nothing = 'NOTHING'; error = 'ERROR  '
}

function Write-ResultLine {
    param([object]$Row, [int]$Index, [int]$Total)
    $tag = $VerdictTag[$Row.Verdict]
    if (-not $tag) { $tag = $Row.Verdict }
    $leak = ''
    if ($Row.Leaked -gt 0) { $leak = " [leaked $($Row.Leaked)]" }
    $color = 'Green'
    if ($Row.Verdict -ne 'pass') { $color = 'Red' }
    $msg = ('[{0,3}/{1}] {2} {3,7}  {4,-42} {5}{6}' -f `
            $Index, $Total, $tag, (Format-Duration $Row.Seconds), $Row.Name, $Row.Line, $leak)
    Write-Host $msg -ForegroundColor $color
}

function Save-Summary {
    param([string]$Path, [object]$Meta, [object[]]$Rows)
    $payload = [pscustomobject]@{
        schema  = 'ghoztty-suite-run/1'
        started = $Meta.Started
        set     = $Meta.Set
        order   = $Meta.Order
        timeout = $Meta.TimeoutSec
        maxTimeout = $Meta.MaxTimeoutSec
        repo    = $Meta.Repo
        results = @($Rows)
    }
    $json = $payload | ConvertTo-Json -Depth 6
    # Written through a temp file and moved into place: this is rewritten after
    # every script, and a suite measured in hours WILL be killed - landing on a
    # half-written summary.json would throw away every row it holds.
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Import-Summary {
    param([string]$PathOrDir)
    $p = $PathOrDir
    if (Test-Path -LiteralPath $p -PathType Container) { $p = Join-Path $p 'summary.json' }
    if (-not (Test-Path -LiteralPath $p)) { throw "no summary at '$PathOrDir'" }
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}

# ============================================================== action: list

if ($Action -eq 'list') {
    # @() at every step: PS 5.1 UNROLLS a one-element array on return, and a
    # scalar's .Count is $null - which printed a blank total for a one-script
    # run rather than "1".
    $rows = @(Remove-ExcludedScript -Rows (Get-SuiteScript -Root $TestRoot -SetName $Set -Inc $IncludeList) -Patterns $ExcludeList)
    $rows = @(Sort-SuiteOrder -Rows $rows -Spec $Order)
    if ($Skip -gt 0) { $rows = @($rows | Select-Object -Skip $Skip) }
    if ($Limit -gt 0) { $rows = @($rows | Select-Object -First $Limit) }
    foreach ($r in $rows) {
        $note = $(if ($r.Declared -gt 0) { "  (declares $($r.Declared)s)" } else { '' })
        '{0,-4} {1}{2}' -f $r.Class, $r.Name, $note
    }
    $gui = @($rows | Where-Object { $_.Class -eq 'gui' }).Count
    ''
    "{0} scripts selected ({1} gui, {2} cli) of {3} in $TestRoot" -f `
        $rows.Count, $gui, ($rows.Count - $gui), (Get-ChildItem -LiteralPath $TestRoot -Filter *.ps1 -File).Count
    exit 0
}

# =========================================================== action: compare

if ($Action -eq 'compare') {
    if ($RunsList.Count -lt 2) { throw "compare needs -Runs with two or more comma-separated summary.json paths." }

    $summaries = @()
    foreach ($r in $RunsList) { $summaries += ,(Import-Summary $r) }

    $names = @()
    foreach ($s in $summaries) { foreach ($row in $s.results) { if ($names -notcontains $row.Name) { $names += $row.Name } } }
    $names = @($names | Sort-Object)

    $diffs = 0
    $missing = 0
    "comparing $($RunsList.Count) runs over $($names.Count) scripts"
    ''
    foreach ($n in $names) {
        $verdicts = @()
        foreach ($s in $summaries) {
            $hit = @($s.results | Where-Object { $_.Name -eq $n })
            if ($hit.Count -eq 0) { $verdicts += '(absent)' } else { $verdicts += $hit[0].Verdict }
        }
        $distinct = @($verdicts | Sort-Object -Unique)
        if ($verdicts -contains '(absent)') { $missing++ }
        if ($distinct.Count -gt 1) {
            $diffs++
            Write-Host ('  DIFFER  {0,-42} {1}' -f $n, ($verdicts -join ' | ')) -ForegroundColor Red
        }
    }

    ''
    if ($missing -gt 0) { "  $missing script(s) were not present in every run" }
    if ($diffs -eq 0) {
        Write-Host "SUITE COMPARE STABLE ($($names.Count) scripts, identical verdicts across $($RunsList.Count) runs)" -ForegroundColor Green
        exit 0
    }
    Write-Host "SUITE COMPARE $diffs DIFFERENCE(S) across $($RunsList.Count) runs" -ForegroundColor Red
    exit 1
}

# =============================================================== action: run

# @() at every step - see the note in the list action above.
$rows = @(Remove-ExcludedScript -Rows (Get-SuiteScript -Root $TestRoot -SetName $Set -Inc $IncludeList) -Patterns $ExcludeList)
$rows = @(Sort-SuiteOrder -Rows $rows -Spec $Order)
if ($Skip -gt 0) { $rows = @($rows | Select-Object -Skip $Skip) }
if ($Limit -gt 0) { $rows = @($rows | Select-Object -First $Limit) }
if ($rows.Count -eq 0) { throw "no scripts selected (-Set $Set, -Include $Include)" }

$done = @{}
if ($Resume) {
    $prev = Import-Summary $Resume
    foreach ($r in $prev.results) { $done[$r.Name] = $r }
    if (-not $OutDir) {
        $p = $Resume
        if (Test-Path -LiteralPath $p -PathType Container) { $OutDir = $p }
        else { $OutDir = Split-Path $p -Parent }
    }
}

if (-not $OutDir) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $OutDir = Join-Path $Repo "temp\suite-runs\$stamp"
}
if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
$summaryPath = Join-Path $OutDir 'summary.json'
$stdinFile = Join-Path $OutDir 'stdin.empty'
Set-Content -LiteralPath $stdinFile -Value '' -Encoding ASCII

$zigOut = Join-Path $Repo 'zig-out'

$meta = [pscustomobject]@{
    Started = (Get-Date).ToString('o'); Set = $Set; Order = $Order
    TimeoutSec = $TimeoutSec; MaxTimeoutSec = $MaxTimeoutSec; Repo = $Repo
}

"suite-run: $($rows.Count) script(s), set=$Set order=$Order timeout=${TimeoutSec}s"
"  out: $OutDir"
$declared = @($rows | Where-Object { $_.Declared -gt 0 })
if ($declared.Count -gt 0) {
    $shown = @($declared | ForEach-Object {
            $cap = Resolve-ScriptTimeout -Declared $_.Declared -Default $TimeoutSec -Max $MaxTimeoutSec
            $note = $(if ($cap -lt $_.Declared) { " capped from $($_.Declared)s" } else { '' })
            "$($_.Name) ${cap}s$note"
        })
    "  per-script timeout: $($shown -join ', ')"
}
if ($Resume) { "  resuming: $($done.Count) already recorded" }
''

if ($DryRun) {
    foreach ($r in $rows) {
        $cap = Resolve-ScriptTimeout -Declared $r.Declared -Default $TimeoutSec -Max $MaxTimeoutSec
        '  would run {0,-4} {1,-42} timeout {2}s' -f $r.Class, $r.Name, $cap
    }
    exit 0
}

$results = @()
$i = 0
$suiteSw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($r in $rows) {
    $i++
    if ($done.ContainsKey($r.Name)) {
        $prevRow = $done[$r.Name]
        $results += $prevRow
        Write-Host ('[{0,3}/{1}] {2} {3,7}  {4,-42} (from resume)' -f `
                $i, $rows.Count, $VerdictTag[$prevRow.Verdict], (Format-Duration $prevRow.Seconds), $r.Name) -ForegroundColor DarkGray
        continue
    }

    $cap = Resolve-ScriptTimeout -Declared $r.Declared -Default $TimeoutSec -Max $MaxTimeoutSec
    $run = Invoke-SuiteScript -Script $r -LogDir $OutDir -TimeoutSeconds $cap -StdinFile $stdinFile

    $leaked = 0
    if (-not $NoSweep) { $leaked = Invoke-LeakSweep -ZigOut $zigOut }

    # T1098: a stray modal is a FAILURE of the script that raised it, not a note
    # beside its PASS. The verdict is overwritten deliberately - a run that hung
    # a system-modal dialog on the user's desktop did not pass, whatever its own
    # assertions counted.
    $modalLines = @()
    if (-not $NoSweep) {
        $modals = @(Invoke-ModalSweep -ZigOut $zigOut)
        if ($modals.Count -gt 0) { $modalLines = @(Format-StrayModalDialog -Modals $modals) }
    }

    $verdict = $run.Verdict
    $line = $run.Line
    if ($modalLines.Count -gt 0) {
        $verdict = 'fail'
        $line = "stray modal dialog raised: $($modalLines -join '; ')"
    }

    $row = [pscustomobject]@{
        Name    = $r.Name
        Class   = $r.Class
        Verdict = $verdict
        Line    = $line
        Seconds = $run.Seconds
        Exit    = $run.Exit
        Leaked  = $leaked
        Modals  = $modalLines.Count
        Log     = (Split-Path $run.Log -Leaf)
        Index   = $i
        # The cap this row was measured against, and whether the script asked
        # for it. A `stall` is only readable next to the number it hit - and the
        # number is read back from the call that enforced it, not recomputed
        # here, so the two cannot drift.
        Timeout  = $run.Timeout
        Declared = $r.Declared
    }
    $results += $row
    Write-ResultLine -Row $row -Index $i -Total $rows.Count

    # Written after EVERY script: a suite measured in hours is going to be
    # killed sooner or later, and the rows it already bought must survive it.
    Save-Summary -Path $summaryPath -Meta $meta -Rows $results
}

$suiteSw.Stop()
Save-Summary -Path $summaryPath -Meta $meta -Rows $results

$byKind = @{}
foreach ($k in @('pass', 'fail', 'stall', 'nothing', 'error')) {
    $byKind[$k] = @($results | Where-Object { $_.Verdict -eq $k }).Count
}
$red = $results.Count - $byKind['pass']

''
'---- suite summary ----------------------------------------------------------'
"  scripts      : $($results.Count)"
"  pass         : $($byKind['pass'])"
"  fail         : $($byKind['fail'])"
"  stall        : $($byKind['stall'])"
"  asserted-none: $($byKind['nothing'])"
"  error        : $($byKind['error'])"
"  wall clock   : $(Format-Duration $suiteSw.Elapsed.TotalSeconds)"
$totalScript = 0.0
foreach ($x in $results) { $totalScript += $x.Seconds }
if ($results.Count -gt 0) {
    "  per script   : mean $(Format-Duration ($totalScript / $results.Count)), total $(Format-Duration $totalScript)"
}
$leaks = @($results | Where-Object { $_.Leaked -gt 0 })
if ($leaks.Count -gt 0) {
    "  leaked procs : $($leaks.Count) script(s) left a zig-out process running"
}
$modalRows = @($results | Where-Object { $_.Modals -gt 0 })
if ($modalRows.Count -gt 0) {
    "  stray modals : $($modalRows.Count) script(s) raised a Windows dialog (dismissed, scored as failures)"
}
''
'  slowest:'
foreach ($x in @($results | Sort-Object Seconds -Descending | Select-Object -First 8)) {
    '    {0,8}  {1}' -f (Format-Duration $x.Seconds), $x.Name
}
if ($red -gt 0) {
    ''
    '  not green:'
    foreach ($x in @($results | Where-Object { $_.Verdict -ne 'pass' })) {
        '    {0,-8} {1,-42} {2}' -f $x.Verdict, $x.Name, $x.Line
    }
}
''
"  summary: $summaryPath"
''

if ($red -eq 0) {
    Write-Host "SUITE ALL PASS ($($results.Count) scripts, $(Format-Duration $suiteSw.Elapsed.TotalSeconds))" -ForegroundColor Green
    exit 0
}
Write-Host "SUITE $red FAILURE(S) of $($results.Count) scripts ($(Format-Duration $suiteSw.Elapsed.TotalSeconds))" -ForegroundColor Red
exit 1
