# T1033 meta-check: a test\win32 script that LAUNCHES the app must run the
# build-mode pre-flight first - as a CHECKED property, not a remembered rule.
#
# Why: `Assert-GhozttyIsolatedBuild` (lib\BuildMode.ps1) is the only thing that
# stops an acceptance run driving the terminal the user is sitting in. A
# zig-out built without `-Doptimize=Debug` derives the SAME app pipe, agent
# pipe and state directory as their installed release, so every `+new-window`
# opens a window in their session, every kill matches nothing, and the script
# passes while measuring a binary nobody here built (T350 has the field
# report). 51 scripts asked the question. banner-resize-repaint.ps1 launched
# the app without asking, and nothing enumerated who else did - which is the
# hole this scan closes.
#
# WHAT COUNTS AS LAUNCHING THE APP, for a text scan: `Start-Process` on a path
# or variable that this script itself binds to a `ghoztty.exe`. Deliberately
# NOT covered:
#
#   * `Start-OnTestDesktop` - since T1033 the helper runs the pre-flight itself
#     for any exe named ghoztty.exe, which is how ~80 GUI scripts get it. That
#     seam is not assumed either: section B EXERCISES it against stub exes, so
#     a refactor that drops the assert fails here rather than years later.
#   * `ghoztty-agent.exe` launches. The agent's endpoints are build-mode
#     derived too, but its exe prints a build STAMP rather than a mode, so
#     `Get-GhozttyBuildMode` cannot read it and this assert cannot speak for
#     it. Tracked separately (T1036); flagging it here would only teach people
#     to add a claim that checks the wrong binary.
#   * `+verb` CLI calls with no process launch - that is isolation-meta.ps1's
#     property (a private endpoint), which is a different question about the
#     same run.
#
# WHAT COUNTS AS ASKING: a call to any function that reaches the gate -
# `Assert-GhozttyIsolatedBuild` itself, `Reset-GhozttyTestState` (CleanSlate)
# or `Assert-GhozttyPrivateEndpoint` (Isolation) - or an explicit, reviewable
# `# preflight: none - <why>` for a script that launches something the gate
# genuinely cannot vouch for.
#
# Like isolation-meta.ps1 this is a PRESENCE check by design: an execution-order
# check would have to trace PowerShell, and presence catches the class that
# burned us - nobody asked at all - without ever crying wolf. Section A proves
# the scan still bites on synthetic fixtures, so a green run here means the
# scanner works AND the tree is clean.
#
#   powershell -NoProfile -File test\win32\launch-preflight-audit.ps1
#
# Non-interactive; launches nothing real. The release cases are played by stub
# exes that print a `+version` banner, the same trick build-mode-guard.ps1 uses.
#
# isolation: none - every CLI verb in this file is prose or fixture text, and
# the only exe ever run is a stub .cmd in $env:TEMP that echoes a banner. There
# is no endpoint to make private.
param([string]$Repo)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

# Run a scriptblock and return the exception message it threw, or $null.
function Get-Throw($block) {
    try { & $block | Out-Null; return $null } catch { return "$($_.Exception.Message)" }
}

$ClaimPattern = 'Assert-GhozttyIsolatedBuild|Reset-GhozttyTestState|Assert-GhozttyPrivateEndpoint|#\s*preflight:\s*none'

# Every variable this script binds to a path ending in ghoztty.exe. Binding is
# what makes the variable NAME meaningful: $AgentExe and $ClientExe are launched
# the same way and are not the app, so the scan reads assignments rather than
# guessing from names.
function Get-AppExeVariable([string]$Text) {
    $vars = @{}
    foreach ($m in [regex]::Matches($Text, '(?i)\$(\w+)\s*=\s*[^\r\n]*?ghoztty\.exe')) {
        $vars[$m.Groups[1].Value.ToLower()] = $true
    }
    return $vars
}

# The app launches this script performs itself, as human-readable strings.
function Get-RawAppLaunch([string]$Text) {
    $vars = Get-AppExeVariable $Text
    $hits = @()
    $pattern = '(?i)Start-Process\s+(?:-FilePath\s+)?(?:\$(\w+)|''([^'']*ghoztty\.exe)''|"([^"]*ghoztty\.exe)")'
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        if ($m.Groups[1].Success) {
            $n = $m.Groups[1].Value
            if ($vars.ContainsKey($n.ToLower())) { $hits += "Start-Process `$$n" }
        } else {
            $hits += 'Start-Process <ghoztty.exe path>'
        }
    }
    return $hits
}

# $null when the file is fine, else a one-line reason.
function Get-PreflightViolation([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $null }
    $hits = @(Get-RawAppLaunch $text)
    if ($hits.Count -eq 0) { return $null }
    if ($text -match $ClaimPattern) { return $null }
    return "launches the app ($($hits[0])) with no build-mode pre-flight"
}

$tmp = Join-Path $env:TEMP "ghoztty-launchpre-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# A stub that answers `+version` the way the real exe does. $Mode = '' prints no
# build-mode line at all - an exe too old to have one, or one that fails.
function New-StubExe($name, $Mode) {
    $path = Join-Path $tmp "$name.cmd"
    $lines = @('@echo off', 'echo Ghostty 1.4.0-stub', 'echo Build Config')
    if ($Mode) { $lines += "echo   - build mode    : .$Mode" }
    Set-Content -LiteralPath $path -Value $lines -Encoding ascii
    return $path
}

try {

# ---------------------------------------------------------------------------
"== A: the scan itself still bites (synthetic fixtures)"
# ---------------------------------------------------------------------------
$fixDir = Join-Path $tmp 'fixtures'
New-Item -ItemType Directory -Force $fixDir | Out-Null

function New-Fixture($name, [string[]]$lines) {
    $p = Join-Path $fixDir "$name.ps1"
    Set-Content -LiteralPath $p -Encoding ASCII -Value $lines
    return $p
}

$bad = New-Fixture 'bad' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$p = Start-Process -FilePath $exe -PassThru'
)
Assert 'A1 a raw app launch with no pre-flight is flagged' `
    ($null -ne (Get-PreflightViolation $bad))

$asserted = New-Fixture 'asserted' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    'Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null',
    '$p = Start-Process -FilePath $exe -PassThru'
)
Assert 'A2 Assert-GhozttyIsolatedBuild counts as the pre-flight' `
    ($null -eq (Get-PreflightViolation $asserted))

$reset = New-Fixture 'reset' @(
    '$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe''',
    '[void](Reset-GhozttyTestState -Exe $Exe)',
    'Start-Process -FilePath $Exe -WindowStyle Minimized | Out-Null'
)
Assert 'A3 Reset-GhozttyTestState counts (it asserts first)' `
    ($null -eq (Get-PreflightViolation $reset))

$priv = New-Fixture 'priv' @(
    '$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe''',
    'Assert-GhozttyPrivateEndpoint -Exe $Exe',
    'Start-Process $Exe | Out-Null'
)
Assert 'A4 Assert-GhozttyPrivateEndpoint counts (same gate)' `
    ($null -eq (Get-PreflightViolation $priv))

$marked = New-Fixture 'marked' @(
    '# preflight: none - launches a stub, not a build of ours',
    '$exe = Join-Path $stub ''ghoztty.exe''',
    'Start-Process -FilePath $exe | Out-Null'
)
Assert 'A5 an explicit preflight: none marker counts as an answer' `
    ($null -eq (Get-PreflightViolation $marked))

$agent = New-Fixture 'agent' @(
    '$AgentExe = ''D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe''',
    'Start-Process -FilePath $AgentExe -PassThru | Out-Null'
)
Assert 'A6 an agent-only launcher is out of scope (T1036)' `
    ($null -eq (Get-PreflightViolation $agent))

$desk = New-Fixture 'desk' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$app = Start-OnTestDesktop -Exe $exe -Arguments @(''--session-persistence=false'')'
)
Assert 'A7 a Start-OnTestDesktop launch is covered by the helper' `
    ($null -eq (Get-PreflightViolation $desk))

$cmd = New-Fixture 'cmd' @(
    '$p = Start-Process -FilePath cmd.exe -ArgumentList ''/c echo hi'' -PassThru'
)
Assert 'A8 a launch that is not the app needs nothing' `
    ($null -eq (Get-PreflightViolation $cmd))

# ---------------------------------------------------------------------------
"== B: the helper the other ~80 scripts rely on really does ask"
# ---------------------------------------------------------------------------
# Behavioral, not textual: Start-OnTestDesktop is called for real, with stubs
# standing in for the exe. The refusal has to come BEFORE the desktop is
# resolved, which is also why these cases need no test desktop to run.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$stubDir = Join-Path $tmp 'stub'
New-Item -ItemType Directory -Force $stubDir | Out-Null
# Nothing here is runnable, and that is the point: the gate speaks before
# anything is launched, and an exe whose `+version` cannot be read is refused
# for the same reason a ReleaseFast one is - a run we cannot vouch for is
# exactly the run that leaks into the user's terminal.
$stubApp = Join-Path $stubDir 'ghoztty.exe'
$msgUnreadable = Get-Throw { Start-OnTestDesktop -Exe $stubApp }
Assert 'B1 Start-OnTestDesktop refuses an exe it cannot vouch for' `
    ($null -ne $msgUnreadable)
Assert 'B2 and it is the build-mode gate that speaks' `
    ($msgUnreadable -match 'REFUSING TO RUN') "(got: $msgUnreadable)"

# The stub with a readable ReleaseFast banner, to prove B1/B2 are not passing
# merely because the file is missing: this one runs and still gets refused.
$fastNamed = New-StubExe 'ghoztty.exe' 'ReleaseFast'
Assert 'B3 the stub really does report ReleaseFast' `
    ((Get-GhozttyBuildMode -Exe $fastNamed) -eq 'ReleaseFast')
Assert 'B4 and a readable release build is refused too' `
    ((Get-Throw { Assert-GhozttyIsolatedBuild -Exe $fastNamed }) -match 'REFUSING TO RUN')

# Past the gate, the next thing to complain is the desktop - which is how these
# prove the gate let them through rather than that it never ran.
#
# T1158: -AllowReleaseBuild is no longer a free pass. A release-lineage run has
# to hold all three isolating knobs, so the pass-through is shown from a
# sandboxed state - and B5z first shows that the launcher cannot be used to
# smuggle a PARTLY isolated release run past the tightened gate, which is the
# state soak.ps1 was in when it seeded the user's agent with pinned sessions.
$savedB5Suffix = $env:GHOZTTY_PIPE_SUFFIX
$savedB5Inst = $env:GHOZTTY_AGENT_INSTANCE
$savedB5Lad = $env:LOCALAPPDATA

$env:GHOZTTY_PIPE_SUFFIX = "-lpa$PID"
Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
$msgPartial = Get-Throw { Start-OnTestDesktop -Exe $stubApp -AllowReleaseBuild }
Assert 'B5z -AllowReleaseBuild does not excuse a partly-isolated release run' `
    ($msgPartial -match 'REFUSING TO RUN') "(got: $msgPartial)"
Assert 'B5y and the refusal names the knob that is missing' `
    ($msgPartial -match 'GHOZTTY_AGENT_INSTANCE is unset') "(got: $msgPartial)"

$env:GHOZTTY_AGENT_INSTANCE = "lpa$PID"
$env:LOCALAPPDATA = Join-Path $stubDir 'sandbox-lad'
$msgAllow = Get-Throw { Start-OnTestDesktop -Exe $stubApp -AllowReleaseBuild }
Assert 'B5 -AllowReleaseBuild reaches the gate and passes through once isolated' `
    ($msgAllow -match 'No test desktop') "(got: $msgAllow)"

if ($null -eq $savedB5Suffix) { Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
else { $env:GHOZTTY_PIPE_SUFFIX = $savedB5Suffix }
if ($null -eq $savedB5Inst) { Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
else { $env:GHOZTTY_AGENT_INSTANCE = $savedB5Inst }
$env:LOCALAPPDATA = $savedB5Lad

$msgAgent = Get-Throw { Start-OnTestDesktop -Exe (Join-Path $stubDir 'ghoztty-agent.exe') }
Assert 'B6 a non-app launch is not gated on the app''s build mode' `
    ($msgAgent -match 'No test desktop') "(got: $msgAgent)"

# ---------------------------------------------------------------------------
"== C: the real tree is clean"
# ---------------------------------------------------------------------------
$self = Split-Path -Leaf $PSCommandPath
# lib\ is swept too: no helper there launches the app today (they launch cmd.exe
# as a pane payload), and a future one that does would otherwise be the one
# place the sweep could not see.
$scripts = @(Get-ChildItem (Join-Path $Repo 'test\win32\*.ps1') -File |
    Where-Object { $_.Name -ne $self }) +
    @(Get-ChildItem (Join-Path $Repo 'test\win32\lib\*.ps1') -File)
Assert 'C1 the sweep found a plausible number of scripts' ($scripts.Count -ge 50) `
    "(got $($scripts.Count))"

$launchers = 0
$violations = @()
foreach ($s in $scripts) {
    $text = Get-Content -LiteralPath $s.FullName -Raw -ErrorAction SilentlyContinue
    if (@(Get-RawAppLaunch $text).Count -gt 0) { $launchers++ }
    $why = Get-PreflightViolation $s.FullName
    if ($null -ne $why) { $violations += "$($s.Name): $why" }
}
"  ($launchers script(s) launch the app themselves)"
foreach ($v in $violations) { "  VIOLATION $v" }
Assert 'C2 every script that launches the app runs the pre-flight first' `
    ($violations.Count -eq 0) "($($violations.Count) violation(s))"
# The scan is worthless if it stops finding the launches: a regex that matches
# nothing would report a clean tree forever.
Assert 'C3 the scan still recognises real launches' ($launchers -ge 5) `
    "(found $launchers)"

} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this scan been run against the test tree as it now stands?".
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard launch-preflight -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
else { "$script:failures FAILURE(S) ($script:passes passed)"; exit 1 }
