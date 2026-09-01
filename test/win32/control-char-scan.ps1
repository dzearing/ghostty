# T1231 meta-check: no repository text file holds a control character, and the
# check that says so has teeth.
#
# Why: on 2026-09-01 fifteen tracked files were carrying REAL control bytes
# where a Windows path had been written with a backslash escape - some tool
# interpreted `\a`, `\b` and `\f` on the way in and wrote 0x07, 0x08 and 0x0c
# into the file. `zig-out\bin` became `zig-out<0x08>in`; `scripts\floor-lane.ps1`
# became `scripts<0x0c>loor-lane.ps1`; and in scripts\guard-due.ps1's coverage
# table `src\apprt\win32\install_prepare.zig` became `src<0x07>pprt\...`, so that
# guard row could never resolve the file it claimed to cover and nobody could
# see why by looking.
#
# That is the exact shape a check should own: trivially detectable, and
# impossible to see by eye. A reader sees the two halves of the path run
# together and files it as a typo; a script sees a path that quietly does not
# exist and reports it as not-found.
#
# THE RULE. In a tracked file whose extension is in scripts\control-char-scan.ps1's
# allowlist, any byte below 0x20 other than tab / LF / CR - and DEL (0x7f) - is a
# finding. The allowlist is what keeps the libghostty fuzz corpora (extensionless
# fixtures whose whole point is to hold control bytes) out of scope without an
# exclusion list that has to be argued with.
#
# Sections:
#
#   A  the scanner itself bites (synthetic fixtures, both directions)
#   B  the live tree is clean
#   C  the fifteen repaired files hold the path they were MEANT to hold, not
#      merely a printable one
#   D  the gate is wired: parity-tasks.ps1 validate asks the scanner, and the
#      pre-commit hook asks it about staged files
#
# Static scan, no app, no CLI - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\control-char-scan.ps1
#   powershell -NoProfile -File test\win32\control-char-scan.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it only reads files
# and runs the scanner over fixtures under temp\.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

$Scanner = Join-Path $Repo 'scripts\control-char-scan.ps1'

# The scanner is a separate process on purpose: what is under test is the exit
# code a caller sees, not a function this script could hold differently.
function Invoke-Scan([string[]]$ScanPaths) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner -Repo $Repo -Paths $ScanPaths 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}

function Write-Fixture([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::UTF8.GetBytes($Text))
}

$fixtureDir = Join-Path $Repo ("temp\control-char-scan-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

try {
    # -----------------------------------------------------------------------
    "== A: the scanner bites, and only on real damage"
    # -----------------------------------------------------------------------
    $clean = Join-Path $fixtureDir 'clean.md'
    Write-Fixture $clean "A path written correctly: ``zig-out\bin\ghoztty.exe``.`r`n`tIndented with a tab.`r`n"
    $r = Invoke-Scan @($clean)
    Assert 'A1 a clean file exits 0' ($r.Code -eq 0) "(exit $($r.Code))"
    Assert 'A2 tab, CR and LF are not findings' ($r.Text -notmatch '0x09|0x0d|0x0a')

    # The three bytes the damage actually produced, one file each, so a scanner
    # that only knew about one of them cannot pass this section.
    $cases = @(
        @{ Name = 'bel.md'; Byte = 7;  Code = '0x07'; Text = "test\win32{0}gent-handoff.ps1" },
        @{ Name = 'bs.md';  Byte = 8;  Code = '0x08'; Text = "zig-out{0}in\ghoztty.exe" },
        @{ Name = 'ff.ps1'; Byte = 12; Code = '0x0c'; Text = "scripts{0}loor-lane.ps1" }
    )
    foreach ($c in $cases) {
        $p = Join-Path $fixtureDir $c.Name
        Write-Fixture $p ("prefix " + ($c.Text -f [char][int]$c.Byte) + " suffix`r`n")
        $r = Invoke-Scan @($p)
        Assert ("A3 {0} is reported" -f $c.Code) ($r.Code -eq 1) "(exit $($r.Code))"
        Assert ("A4 {0} is named in the report" -f $c.Code) ($r.Text -match [regex]::Escape($c.Code))
        Assert ("A5 {0} report names the file" -f $c.Code) ($r.Text -match [regex]::Escape($c.Name))
    }

    # Line and column, so a finding is actionable without opening the file.
    $multi = Join-Path $fixtureDir 'multi.md'
    Write-Fixture $multi ("line one`nline two`nab" + [char]8 + "cd`n")
    $r = Invoke-Scan @($multi)
    Assert 'A6 the finding carries line:col' ($r.Text -match 'multi\.md:3:3\s+0x08') "($($r.Text.Trim()))"

    # DEL is in scope too - it is not a printable character and no source file
    # here has a use for one.
    $del = Join-Path $fixtureDir 'del.txt'
    Write-Fixture $del ("x" + [char]127 + "y`n")
    $r = Invoke-Scan @($del)
    Assert 'A7 DEL (0x7f) is reported' ($r.Code -eq 1 -and $r.Text -match '0x7f') "(exit $($r.Code))"

    # The headline a caller greps for. It is the label parity-tasks.ps1 validate
    # re-emits as its own gate line, and test\win32\gate-negatives.ps1's registry
    # points at THIS assertion as the demonstration that it can fire.
    Assert 'A8 the report leads with CONTROL CHARACTERS' ($r.Text -match 'CONTROL CHARACTERS')

    # -----------------------------------------------------------------------
    ""
    "== B: the live tree is clean"
    # -----------------------------------------------------------------------
    $live = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner -Repo $Repo 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    $liveCode = $LASTEXITCODE
    Assert 'B1 a full tracked-tree scan exits 0' ($liveCode -eq 0) `
        ("(exit $liveCode) " + (($live -split "`r?`n" | Select-Object -First 8) -join ' / '))
    Assert 'B2 the scan actually looked at files' ($live -match 'CLEAN: (\d+) file') $live
    if ($live -match 'CLEAN: (\d+) file') {
        # A scan that enumerated a handful of files is a broken enumeration
        # reporting success, which is the failure mode a clean exit code hides.
        Assert 'B3 the scan covered the repo, not a corner' ([int]$Matches[1] -gt 1000) "($($Matches[1]) files)"
    }

    # -----------------------------------------------------------------------
    ""
    "== C: the repaired files say what they were meant to say"
    # -----------------------------------------------------------------------
    # Making the byte printable is not the fix - restoring the path IS. Each of
    # these is the text the damaged span had to have started as, checked against
    # an undamaged twin elsewhere in the tree where one exists.
    $expected = @(
        @{ File = 'scripts\suite-run.ps1';            Needle = 'confirm -Resume temp\suite-runs\fwd1' },
        @{ File = 'test\win32\agent-autostart.ps1';   Needle = 'lives at zig-out-release\bin INSIDE' },
        @{ File = 'test\win32\suite-run.ps1';         Needle = '<fixture>\zig-out\bin\ghoztty.exe' },
        @{ File = 'docs\design\windows-parity-log.md'; Needle = '<repo>\zig-out\bin\ghoztty.exe' },
        @{ File = 'docs\design\windows-parity-tasks\T1001.md'; Needle = 'test\win32\agent-handoff.ps1' },
        @{ File = 'docs\design\windows-parity-tasks\T1092.md'; Needle = '<repo>\zig-out\bin\ghoztty.exe' },
        @{ File = 'docs\design\windows-parity-tasks\T1094.md'; Needle = 'temp\suite-runs\fwd1\summary.json' },
        @{ File = 'docs\design\windows-parity-tasks\T1172.md'; Needle = 'scripts\floor-lane.ps1 -Lane all' },
        @{ File = 'docs\design\windows-parity-tasks\T1251.md'; Needle = 'zig-out\bin\ghoztty.exe' },
        @{ File = 'docs\design\windows-parity-tasks\T1252.md'; Needle = 'zig-out\bin\gl\' },
        @{ File = 'docs\design\windows-parity-tasks\T188.md';  Needle = 'scripts\floor-lane.ps1 -Lane all' },
        @{ File = 'docs\design\windows-parity-tasks\T308.md';  Needle = 'scripts\floor-lane.ps1 -Lane all' },
        @{ File = 'docs\design\windows-parity-tasks\T851.md';  Needle = "roster's attached flag" },
        @{ File = 'docs\design\windows-parity-tasks\T935.md';  Needle = 'scripts\floor-lane.ps1' },
        @{ File = 'docs\design\windows-parity-tasks\T974.md';  Needle = 'scripts\floor-lane.ps1 -Lane all' }
    )
    foreach ($e in $expected) {
        $p = Join-Path $Repo $e.File
        $text = ''
        if (Test-Path -LiteralPath $p) { $text = [System.IO.File]::ReadAllText($p) }
        Assert ("C1 {0} carries '{1}'" -f $e.File, $e.Needle) ($text.Contains($e.Needle))
    }

    # -----------------------------------------------------------------------
    ""
    "== D: the gate is wired where a commit has to pass it"
    # -----------------------------------------------------------------------
    # The scanner existing is not the gate. Two callers make it one: the loop's
    # pre-commit validate, and the git hook - which is what covers the OTHER
    # window sharing this working tree, since it never runs validate.
    $tasks = [System.IO.File]::ReadAllText((Join-Path $Repo 'scripts\parity-tasks.ps1'))
    Assert 'D1 parity-tasks.ps1 validate runs the scanner' ($tasks -match 'control-char-scan\.ps1')

    $hook = Join-Path $Repo 'scripts\githooks\pre-commit'
    $hookText = ''
    if (Test-Path -LiteralPath $hook) { $hookText = [System.IO.File]::ReadAllText($hook) }
    Assert 'D2 the pre-commit hook runs the scanner over staged files' `
        ($hookText -match 'control-char-scan\.ps1' -and $hookText -match '\-Staged')

    # And the scanner answers the staged question at all - a -Staged mode that
    # threw would make the hook a no-op nobody would notice.
    $stagedOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner -Repo $Repo -Staged 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Assert 'D3 -Staged runs and scores itself' ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) `
        "(exit $LASTEXITCODE) $stagedOut"

    # -----------------------------------------------------------------------
    ""
    "== E: validate is DRIVEN red, not merely wired"
    # -----------------------------------------------------------------------
    # A gate that has never been observed saying anything but "fine" is
    # indistinguishable from one that cannot say anything else. Point the gate
    # at a fixture git tree holding one damaged file and read validate's own
    # output back.
    $fixtureRepo = Join-Path $fixtureDir 'repo'
    $fixtureTasks = Join-Path $fixtureRepo 'docs\design\windows-parity-tasks'
    New-Item -ItemType Directory -Force -Path $fixtureTasks | Out-Null
    # cmd does the redirecting, so git's ordinary chatter on stderr cannot
    # arrive as a terminating NativeCommandError under -ErrorAction Stop, and
    # autocrlf is off so the fixture on disk is the bytes written here.
    Push-Location $fixtureRepo
    try {
        & cmd /c "git init -q > NUL 2>&1"
        & cmd /c "git config core.autocrlf false > NUL 2>&1"
        Write-Fixture (Join-Path $fixtureRepo 'damaged.md') ("path zig-out" + [char]8 + "in here`n")
        & cmd /c "git add -A > NUL 2>&1"
    } finally { Pop-Location }

    # A minimal well-formed task file, so validate has something to parse and
    # the only problem in the run is the one under test.
    $t = @(
        '---', 'id: T1', 'title: "fixture"', 'order: null', 'deps: []',
        'status: "todo"', 'commits: []', 'seat: "win"', 'priority: "P2"',
        'triage-reason: "fixture"', 'tags: ["infra"]', '---', '',
        '# T1 - fixture', '', '## Summary', '', 'fixture.'
    )
    [System.IO.File]::WriteAllText((Join-Path $fixtureTasks 'T1.md'), ($t -join "`r`n"))

    $env:GHOZTTY_CONTROL_CHAR_REPO = $fixtureRepo
    try {
        $vOut = & powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Repo 'scripts\parity-tasks.ps1') validate -TaskDir $fixtureTasks 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
        $vCode = $LASTEXITCODE
    } finally {
        Remove-Item Env:\GHOZTTY_CONTROL_CHAR_REPO -ErrorAction SilentlyContinue
    }
    Assert 'E1 validate reports CONTROL CHARACTERS over a damaged tree' `
        ($vOut -match 'CONTROL CHARACTERS') $vOut
    Assert 'E2 ...and scores it as a problem' ($vCode -ne 0) "(exit $vCode)"
    Assert 'E3 ...naming the file and the byte' `
        ($vOut -match 'damaged\.md' -and $vOut -match '0x08')

    # And the same fixture with the damage repaired comes back quiet, so E1 is
    # measuring the control character rather than the fixture's mere existence.
    Write-Fixture (Join-Path $fixtureRepo 'damaged.md') "path zig-out\bin here`n"
    $env:GHOZTTY_CONTROL_CHAR_REPO = $fixtureRepo
    try {
        $vOut2 = & powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Repo 'scripts\parity-tasks.ps1') validate -TaskDir $fixtureTasks 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
    } finally {
        Remove-Item Env:\GHOZTTY_CONTROL_CHAR_REPO -ErrorAction SilentlyContinue
    }
    Assert 'E4 a repaired fixture is not reported' ($vOut2 -notmatch 'CONTROL CHARACTERS') $vOut2

    # -----------------------------------------------------------------------
    # Negative control: the scan must be able to go RED against a REAL tracked
    # file, not only against section A's fixtures. Plant one 0x08 in a live doc,
    # run the full tree scan, and assert - INVERTED - that it stays clean. A
    # working scanner fails that assertion, so a healthy repo scores exactly
    # 1 FAILURE here; a scanner whose enumeration quietly stopped covering the
    # tree would pass it and be caught. The probe file is restored either way.
    # -----------------------------------------------------------------------
    if ($NegativeControl) {
        ""
        "NEGATIVE CONTROL: asserting a planted control character is NOT found - a working scan MUST fail this"
        $probe = Join-Path $Repo 'docs\design\windows-parity-tasks\T1231.md'
        $original = [System.IO.File]::ReadAllBytes($probe)
        $code = 0
        try {
            $planted = $original + [System.Text.Encoding]::UTF8.GetBytes(("`nzig-out" + [char]8 + "in`n"))
            [System.IO.File]::WriteAllBytes($probe, $planted)
            & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner -Repo $Repo -Quiet 2>&1 |
                ForEach-Object { $_.ToString() } | Out-Null
            $code = $LASTEXITCODE
        } finally {
            [System.IO.File]::WriteAllBytes($probe, $original)
        }
        Assert 'N1 a planted control character goes unreported (inverted)' ($code -eq 0) `
            "(exit $code, and 1 is the healthy answer)"
        $restored = [System.IO.File]::ReadAllBytes($probe)
        Assert 'N2 the probe file is restored byte for byte' `
            (@(Compare-Object $original $restored -SyncWindow 0).Count -eq 0)
    }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $fixtureDir -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this scan been run against the tree as it now stands?".
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard control-char-scan -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
else { "$script:failures FAILURE(S) ($script:passes passed)"; exit 1 }
