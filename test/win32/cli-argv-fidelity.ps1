<#
T279 - free text handed to the ghoztty CLI from PowerShell 5.1 must arrive
BYTE-EXACT.

PowerShell 5.1 builds the command line for a native process itself, and its
builder is not the inverse of the CRT parser every C/C++/Zig program uses to
split that line back into argv. Measured with a GetCommandLineW oracle:

  * an argument is wrapped in `"` only when whitespace appears at a position
    preceded by an EVEN number of `"` characters, and
  * an embedded `"` is copied through unescaped.

So a title or a banner - text a program composed, which routinely carries a
quote or ends in a backslash - is silently corrupted at exit 0. The live case:
the loop's own relaunch passed
`--command=claude --dangerously-skip-permissions --continue "read go.md and go"`
and ghoztty received `--command=claude ... --continue read` plus `go.md`, `and`,
`go` as three stray positionals.

There is no escaper that fixes this in general - see scripts/lib/NativeArgv.ps1
for the proof - so the fix is to build the command line ourselves and hand it to
CreateProcess. This script measures that, against the real product.

Sections:
  A. the token quoter, as a pure function (no process)
  B. `+rename --title=` round-trips a hazardous payload byte-for-byte
  C. `+set-banner` round-trips a hazardous payload byte-for-byte
  D. NEGATIVE CONTROLS: the same payloads sent the naive `& $exe "--flag=$text"`
     way must arrive CORRUPTED, and a payload with no quote and no trailing
     backslash must arrive intact BOTH ways. A payload that was never broken
     proves nothing, and a harness that is simply always-red proves less.

  powershell -NoProfile -File test\win32\cli-argv-fidelity.ps1
#>
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\lib\NativeArgv.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

[void](Set-GhozttyTestIsolation -Tag 't279argv')

$transcript = Join-Path $env:TEMP 'ghoztty-t279-argv-last.log'
$target = 't279win'

# Read `+list --json` through Invoke-NativeExact: stdout only, so a stderr line
# can never land inside the JSON. (This script is the one place where using the
# subject under test as the harness is fine - section D re-measures every claim
# through the OLD path as its control.)
function Get-ListJson {
    $r = Invoke-NativeExact -FilePath $Exe -Arguments @('+list', '--json') -TimeoutMs 20000
    if ($r.Code -ne 0) { return $null }
    try { return ConvertFrom-Json $r.Out } catch { return $null }
}

# The window title as the CLI SET it. A debug build appends " [DEBUG]" to every
# window title (T43) and `+list --json` reports the decorated string, so the
# suffix is peeled here rather than folded into each expectation - it belongs to
# the build, not to the payload, and a release run has none to peel.
function Get-WindowTitle {
    $j = Get-ListJson
    if ($null -eq $j) { return $null }
    foreach ($w in @($j.data.windows)) {
        if ($w.target -ne $target) { continue }
        $t = $w.title
        if ($null -eq $t) { return $null }
        if ($t.EndsWith(' [DEBUG]')) { $t = $t.Substring(0, $t.Length - ' [DEBUG]'.Length) }
        return $t
    }
    return $null
}

function Get-PaneBanner([string]$paneId) {
    $j = Get-ListJson
    if ($null -eq $j) { return $null }
    $found = $null
    function Walk($node) {
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            if ($node.terminal.id -eq $paneId) { $script:foundBanner = $node.terminal.banner }
            return
        }
        Walk $node.left
        Walk $node.right
    }
    $script:foundBanner = $null
    foreach ($w in @($j.data.windows)) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) { Walk $t.splits }
    }
    return $script:foundBanner
}

function Get-FirstPaneId {
    $j = Get-ListJson
    if ($null -eq $j) { return $null }
    $script:foundId = $null
    function WalkId($node) {
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            if (-not $script:foundId) { $script:foundId = $node.terminal.id }
            return
        }
        WalkId $node.left
        WalkId $node.right
    }
    foreach ($w in @($j.data.windows)) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) { WalkId $t.splits }
    }
    return $script:foundId
}

# Poll: an IPC reply lands before the window has repainted its title, and a
# fixed sleep is what makes a cold first launch flaky (T379).
function Wait-For([scriptblock]$Probe, [string]$Want, [int]$TimeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $v = & $Probe
        if ($null -ne $v -and $v -ceq $Want) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $v
}

# --- payloads ---------------------------------------------------------------
#
# Each hazardous payload names WHICH half of the PowerShell defect it triggers,
# because the two need different fixes and a test that cannot tell them apart
# would pass on half a repair.
$P_QUOTE = 'a "quoted phrase" mid string'          # embedded quote, even parity
$P_LEAD  = '"leading quoted phrase" then more'     # odd parity: PS declines to wrap
$P_SLASH = 'trailing backslash D:\my dir\'         # closing quote eats the `\`
$P_SAFE  = 'plain safe text'                       # positive control

& {

"== 0: setup"
Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== A: the token quoter is the CRT's inverse (pure)"
Assert "A1 a plain token is not wrapped" ((ConvertTo-NativeArgToken 'plain') -ceq 'plain')
Assert "A2 whitespace forces a wrapper" ((ConvertTo-NativeArgToken 'a b') -ceq '"a b"')
Assert "A3 the empty string keeps its wrapper" ((ConvertTo-NativeArgToken '') -ceq '""')
Assert "A4 an embedded quote is escaped" ((ConvertTo-NativeArgToken 'a "b" c') -ceq '"a \"b\" c"')
Assert "A5 a quote with no whitespace still forces a wrapper" ((ConvertTo-NativeArgToken 'a"b') -ceq '"a\"b"')
Assert "A6 a trailing backslash run is doubled" ((ConvertTo-NativeArgToken 'a b\') -ceq '"a b\\"')
Assert "A7 backslashes before a quote are doubled, elsewhere left alone" (
    (ConvertTo-NativeArgToken 'a\b\\"c') -ceq '"a\b\\\\\"c"')
Assert "A8 a lone backslash needs no wrapper" ((ConvertTo-NativeArgToken 'a\b') -ceq 'a\b')
Assert "A9 the command line joins tokens with one space" (
    (ConvertTo-NativeCommandLine @('+rename', '--title=a b')) -ceq '+rename "--title=a b"')

"== 0b: launch the instance under test"
# persistence: off - this run asserts on a window it creates itself, and a
# restored pane from an earlier run would answer the title/banner reads.
$app = Start-Process -FilePath $Exe -WindowStyle Minimized -PassThru `
    -ArgumentList @('--session-persistence=false', '--title=t279-argv-fidelity')
$null = $app.Handle   # T197 habit: cache the handle before any wait
Start-Sleep -Seconds 2

$r = Invoke-NativeExact -FilePath $Exe -Arguments @('+new-window', "--target=$target") -TimeoutMs 30000
Assert "0b +new-window exit 0" ($r.Code -eq 0)
$paneId = $null
for ($i = 0; $i -lt 30; $i++) {
    $paneId = Get-FirstPaneId
    if ($paneId) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $paneId) {
    Write-Host "  SKIP whole run: the fixture window '$target' never appeared in +list --json"
    $script:skipped++
} else {
    Assert "0b the fixture window has a pane" ($paneId.Length -gt 0)

    # --- B: +rename --title ------------------------------------------------
    "== B: +rename --title= round-trips byte-for-byte"
    foreach ($case in @(
        @{ Name = 'embedded quote';  Text = $P_QUOTE },
        @{ Name = 'leading quote';   Text = $P_LEAD },
        @{ Name = 'trailing slash';  Text = $P_SLASH },
        @{ Name = 'safe control';    Text = $P_SAFE }
    )) {
        $r = Invoke-NativeExact -FilePath $Exe -Arguments @(
            '+rename', "--target=$target", "--title=$($case.Text)") -TimeoutMs 20000
        $got = Wait-For { Get-WindowTitle } $case.Text
        Assert "B [$($case.Name)] exit 0" ($r.Code -eq 0)
        Assert "B [$($case.Name)] title is byte-exact" ($got -ceq $case.Text)
    }

    # --- C: +set-banner ----------------------------------------------------
    "== C: +set-banner round-trips byte-for-byte"
    foreach ($case in @(
        @{ Name = 'embedded quote';  Text = $P_QUOTE },
        @{ Name = 'leading quote';   Text = $P_LEAD },
        @{ Name = 'trailing slash';  Text = $P_SLASH },
        @{ Name = 'safe control';    Text = $P_SAFE }
    )) {
        $r = Invoke-NativeExact -FilePath $Exe -Arguments @(
            '+set-banner', "--target=$paneId", $case.Text) -TimeoutMs 20000
        $got = Wait-For { Get-PaneBanner $paneId } $case.Text
        Assert "C [$($case.Name)] exit 0" ($r.Code -eq 0)
        Assert "C [$($case.Name)] banner is byte-exact" ($got -ceq $case.Text)
    }

    # --- D: negative + positive controls -----------------------------------
    #
    # The old transport, verbatim, against the same live product. Without this
    # section every assertion above could be passing because the payloads were
    # never at risk - which is exactly how T210's length theory survived a day.
    "== D: the naive `& `$exe `"--flag=`$text`" transport still corrupts (control)"
    foreach ($case in @(
        @{ Name = 'embedded quote'; Text = $P_QUOTE },
        @{ Name = 'leading quote';  Text = $P_LEAD },
        @{ Name = 'trailing slash'; Text = $P_SLASH }
    )) {
        $t = $case.Text
        & $Exe +rename "--target=$target" "--title=$t" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        $got = Get-WindowTitle
        Assert "D [$($case.Name)] naive +rename corrupts the title (got <$got>)" ($got -cne $t)

        & $Exe +set-banner "--target=$paneId" "$t" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        $gotB = Get-PaneBanner $paneId
        Assert "D [$($case.Name)] naive +set-banner corrupts the banner (got <$gotB>)" ($gotB -cne $t)
    }

    "== D2: a payload with no quote and no trailing backslash survives BOTH ways"
    & $Exe +rename "--target=$target" "--title=$P_SAFE" 2>&1 | Out-Null
    $got = Wait-For { Get-WindowTitle } $P_SAFE
    Assert "D2 naive +rename is intact for safe text" ($got -ceq $P_SAFE)
    & $Exe +set-banner "--target=$paneId" "$P_SAFE" 2>&1 | Out-Null
    $gotB = Wait-For { Get-PaneBanner $paneId } $P_SAFE
    Assert "D2 naive +set-banner is intact for safe text" ($gotB -ceq $P_SAFE)
}

"== teardown"
Invoke-NativeExact -FilePath $Exe -Arguments @('+close', "--target=$target") -TimeoutMs 20000 | Out-Null
Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null

} 2>&1 | Tee-Object -FilePath $transcript

""
Complete-TestBody  # T1039: the run reached the end of its body
$verdict = Write-TestVerdict -Label 'T279 ARGV FIDELITY' -Pass $script:passes -Fail $script:failures `
    -Skipped $script:skipped -NoExit
if ($verdict.Code -ne 0) { Add-Content $transcript $verdict.Line }
exit $verdict.Code
