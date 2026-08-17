# T680 meta-check: a test\win32 script that drives the ghoztty CLI must claim
# a private IPC endpoint - as a CHECKED property, not a remembered rule.
#
# Why: every acceptance script here is usually started from one of the user's
# own Ghoztty panes, so `$GHOZTTY_IPC_SOCKET` in its environment names the
# USER'S app, and the CLI prefers that over its own derivation. A script that
# runs a `+verb` with no isolation therefore reads - or drives - the terminal
# the user is sitting in, and grades the wrong build while it is at it. T485
# fixed one such script and asked for the sweep; the sweep found seven more
# (T680). A hand-curated list goes stale the day someone adds a script, so
# this scan runs instead.
#
# What counts as DRIVING the CLI: the script's text contains a `+verb` from
# the CLI surface (+list, +read, +send-keys, ...). What counts as CLAIMING
# isolation, any one of:
#
#   * Set-GhozttyTestIsolation   (lib\Isolation.ps1 - the preferred form:
#                                 per-PID suffix + the throwing asserts)
#   * $env:GHOZTTY_PIPE_SUFFIX = (a hand-rolled suffix; outranks the pane's
#                                 baked endpoint in the CLI's resolution order)
#   * dot-sourcing CleanSlate.ps1 (drops $GHOZTTY_IPC_SOCKET at load, so the
#                                 CLI falls back to this build's derivation)
#   * `# isolation: none - <why>` (an explicit, reviewable opt-out for a
#                                 script whose verbs live in comments or
#                                 fixtures only - say what protects it instead)
#
# This is a PRESENCE check on purpose. An execution-order check would need to
# actually trace PowerShell, and a text-order check ("first verb line vs first
# isolation line") was measured flagging ~13 correct scripts that define a
# Run-Cli helper above their isolation call (T680's Details). Presence catches
# the class that burned us - no isolation anywhere - and never cries wolf, so
# it can afford to run on every change. The scan proves it still BITES on
# every run: section A feeds it a synthetic violator and a synthetic
# compliant script and requires the right verdict on both.
#
#   powershell -NoProfile -File test\win32\isolation-meta.ps1
param([string]$Repo)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

# The CLI surface (CLAUDE.md "CLI at a glance", plus +version). A verb added
# to the product gets added here when its first test is written.
$VerbPattern = '\+(new-window|split|close|rearrange|read|list|sessions|send-keys|set-state|set-banner|reload|new-remote-window|version)\b'
$ClaimPatterns = @(
    'Set-GhozttyTestIsolation',
    'GHOZTTY_PIPE_SUFFIX\s*=',
    'CleanSlate\.ps1',
    '#\s*isolation:\s*none'
)

# Returns $null when the file is fine, else a one-line reason.
function Get-IsolationViolation([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $null }
    if ($text -notmatch $VerbPattern) { return $null }
    foreach ($claim in $ClaimPatterns) {
        if ($text -match $claim) { return $null }
    }
    return 'drives the CLI (+verb) with no isolation claim'
}

# ---------------------------------------------------------------------------
"== A: the scan itself still bites (synthetic fixtures)"
# ---------------------------------------------------------------------------
$fixDir = Join-Path $env:TEMP "ghoztty-isometa-$PID"
New-Item -ItemType Directory -Force $fixDir | Out-Null
try {
    $bad = Join-Path $fixDir 'bad.ps1'
    Set-Content -LiteralPath $bad -Encoding ASCII -Value @(
        '$exe = "D:\somewhere\ghoztty.exe"',
        '& $exe +list --json'
    )
    Assert 'A1 a script with a +verb and no claim is flagged' `
        ($null -ne (Get-IsolationViolation $bad))

    $suffixed = Join-Path $fixDir 'suffixed.ps1'
    Set-Content -LiteralPath $suffixed -Encoding ASCII -Value @(
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture"',
        '& $exe +list --json'
    )
    Assert 'A2 a hand-rolled suffix counts as a claim' `
        ($null -eq (Get-IsolationViolation $suffixed))

    $lib = Join-Path $fixDir 'lib.ps1'
    Set-Content -LiteralPath $lib -Encoding ASCII -Value @(
        '. (Join-Path $PSScriptRoot ''lib\Isolation.ps1'')',
        '[void](Set-GhozttyTestIsolation -Tag ''fixture'')',
        '& $exe +read --name=x'
    )
    Assert 'A3 Set-GhozttyTestIsolation counts as a claim' `
        ($null -eq (Get-IsolationViolation $lib))

    $marked = Join-Path $fixDir 'marked.ps1'
    Set-Content -LiteralPath $marked -Encoding ASCII -Value @(
        '# isolation: none - verbs below are fixture text, nothing is executed',
        '$doc = "run ghoztty +list yourself"'
    )
    Assert 'A4 an explicit isolation: none marker counts as a claim' `
        ($null -eq (Get-IsolationViolation $marked))

    $quiet = Join-Path $fixDir 'quiet.ps1'
    Set-Content -LiteralPath $quiet -Encoding ASCII -Value @(
        'Write-Host "no CLI here at all"'
    )
    Assert 'A5 a verb-free script needs no claim' `
        ($null -eq (Get-IsolationViolation $quiet))
} finally {
    Remove-Item -Recurse -Force $fixDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
"== B: the real tree is clean"
# ---------------------------------------------------------------------------
$self = Split-Path -Leaf $PSCommandPath
$scripts = @(Get-ChildItem (Join-Path $Repo 'test\win32\*.ps1') -File |
    Where-Object { $_.Name -ne $self })
Assert 'B1 the sweep found a plausible number of scripts' ($scripts.Count -ge 50) `
    "(got $($scripts.Count))"

$violations = @()
foreach ($s in $scripts) {
    $why = Get-IsolationViolation $s.FullName
    if ($null -ne $why) { $violations += "$($s.Name): $why" }
}
foreach ($v in $violations) { "  VIOLATION $v" }
Assert 'B2 every script that drives the CLI claims a private endpoint' `
    ($violations.Count -eq 0) "($($violations.Count) violation(s))"

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this scan been run against the test tree as it now stands?".
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard isolation-meta -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
else { "$script:failures FAILURE(S) ($script:passes passed)"; exit 1 }
