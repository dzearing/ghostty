# msg_hwnd timer-id acceptance (T608): the app's hidden message window has ONE
# timer id space, and every id in it is declared in one file that fails the
# build on a duplicate.
#
#   powershell -NoProfile -File test\win32\msg-timer-ids.ps1
#
# Non-interactive, launches no Ghoztty and touches no user state: the subject is
# SOURCE TEXT plus one `zig test` of the registry, so this reads .zig files and
# starts no app.
#
# isolation: none - a static audit over source text; nothing here launches
# ghoztty or runs a CLI verb (T680 meta-check reads this marker).
#
# WHY IT EXISTS. `SetTimer(hwnd, id, ...)` with an (hwnd, id) pair that already
# exists REPLACES the timer that was there, and `KillTimer` kills whichever one
# it finds. `App.msg_hwnd` is a single process-wide window, so two features that
# pick the same number silently cancel each other - and only while both happen
# to be live, which is the hardest kind of defect to see. T608 was exactly that:
# the quick-terminal slide animation (`QuickTerminal.ANIM_TIMER_ID`) and the
# update balloon's icon-cleanup timer (`App.NOTIF_UPDATE_TIMER_ID`) were both
# id 3, declared in two different files with nothing comparing them. An update
# notification arriving mid-slide stalled the slide, and the cleanup tick was
# then routed to `onAnimationTick`, so the tray icon outlived its balloon.
#
# The fix is a registry (`src\apprt\win32\msg_timer.zig`) whose `comptime`
# block refuses to compile a duplicate. This script is the guard AROUND that
# guard: the registry can only compare the ids it is given, so what has to stay
# true is that nobody declares an msg_hwnd timer id anywhere else.
#
# WHY THE ORACLE IS SOURCE TEXT AND NOT A LIVE SLIDE. The behavior the
# collision broke - a quick-terminal slide finishing while an update balloon is
# up - cannot be observed on this box. The quick terminal is opened by a
# keybind, and SendInput does not land on the background test desktop the
# acceptance suite runs on (T218); the balloon half is worse still, because
# this box draws no toasts at all (ToastEnabled=0, measured in
# notification-click-real.ps1) so the notification cannot be put on screen to
# race. What CAN be proved without either is the property the symptom was made
# of: the two timers no longer share an id, and no future timer can take one
# that is already spoken for. Sections A-D prove that, including that each
# check can fail.
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0

function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

$srcDir = Join-Path $Repo 'src\apprt\win32'
$registryPath = Join-Path $srcDir 'msg_timer.zig'

# The files that arm timers on `App.msg_hwnd`. Adding a fourth is fine - section
# C is what notices it and tells you to put its ids in the registry.
$owners = @('App.zig', 'QuickTerminal.zig', 'RemoteReconnect.zig')

# A timer-id constant, in either house style: `const FOO_TIMER_ID: usize = X;`
# and `const foo_timer_id: usize = X;`.
$declRe = '(?m)^\s*(?:pub\s+)?const\s+(\w*(?i:timer_id)\w*)\s*:\s*usize\s*=\s*([^;]+);'

# An owner file's timer-id declarations that are NOT sourced from the registry.
# The value has to be `msg_timer.<name>`; a bare number is the shape T608 was.
function Get-UnregisteredIds {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bad = @()
    foreach ($m in [regex]::Matches($Text, $declRe)) {
        $value = $m.Groups[2].Value.Trim()
        if ($value -match '^msg_timer\.\w+$') { continue }
        $bad += "$($m.Groups[1].Value) = $value"
    }
    return , $bad
}

# ============================================================================
"== A: the registry declares distinct ids"
# ============================================================================

Assert 'A0 the registry is where this expects it' (Test-Path -LiteralPath $registryPath) $registryPath

$registryText = if (Test-Path -LiteralPath $registryPath) { Get-Content -LiteralPath $registryPath -Raw } else { '' }
$ids = @{}
foreach ($m in [regex]::Matches($registryText, '(?m)^\s*pub\s+const\s+(\w+)\s*:\s*usize\s*=\s*(\d+);')) {
    $ids[$m.Groups[1].Value] = [int]$m.Groups[2].Value
}

# A sweep that finds nothing to sweep is a broken path, not a green result.
Assert "A1 the registry parses ($($ids.Count) ids)" ($ids.Count -ge 14) `
    (($ids.GetEnumerator() | Sort-Object Value | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')

$dupes = @($ids.Values | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Assert 'A2 every declared id is distinct' ($dupes.Count -eq 0) ("repeated: " + ($dupes -join ', '))

# The specific pair T608 was filed about, named so a regression reads as itself.
$qt = $ids['quick_terminal_anim']
$upd = $ids['notif_update']
Assert 'A3 both ids T608 named are declared' ($null -ne $qt -and $null -ne $upd) `
    "quick_terminal_anim=$qt notif_update=$upd"
$distinct = ($null -ne $qt -and $null -ne $upd -and $qt -ne $upd)
if ($NegativeControl) {
    # -NegativeControl inverts the assertion this script exists for, and MUST
    # fail: a run that cannot go red proves nothing when it goes green.
    $distinct = -not $distinct
}
Assert 'A4 the quick-terminal animation and the update-balloon cleanup differ' $distinct `
    "quick_terminal_anim=$qt notif_update=$upd"

# ============================================================================
"== B: the analyzer catches the shape T608 was, and only that shape"
# ============================================================================

Assert 'B1 a literal id is a finding' `
((Get-UnregisteredIds -Text 'const ANIM_TIMER_ID: usize = 3;').Count -eq 1)
Assert 'B2 a lowercase literal id is a finding too' `
((Get-UnregisteredIds -Text 'const feedback_timer_id: usize = 3;').Count -eq 1)
Assert 'B3 an id taken from the registry is not a finding' `
((Get-UnregisteredIds -Text 'pub const ANIM_TIMER_ID: usize = msg_timer.quick_terminal_anim;').Count -eq 0)
Assert 'B4 a file with no timer ids is not a finding' `
((Get-UnregisteredIds -Text 'pub fn helper() void {}').Count -eq 0)

# ============================================================================
"== C: the sweep -- every msg_hwnd timer id comes from the registry"
# ============================================================================

$checked = @()
$offenders = @()
foreach ($name in $owners) {
    $path = Join-Path $srcDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        Assert "C0 owner file $name exists" $false $path
        continue
    }
    $checked += $name
    foreach ($finding in (Get-UnregisteredIds -Text (Get-Content -LiteralPath $path -Raw))) {
        $offenders += "$name : $finding"
    }
}
Assert "C1 the sweep read the owner files ($($checked.Count))" ($checked.Count -eq $owners.Count) `
    ($checked -join ', ')
Assert 'C2 no owner declares an msg_hwnd timer id of its own' ($offenders.Count -eq 0) `
    ($offenders -join '; ')

# A FOURTH file arming a timer on msg_hwnd would be outside the list above, so
# the list cannot be the only thing looking. Any file that names `msg_hwnd` in a
# SetTimer/KillTimer call has to be an owner (and is then swept by C2).
$newcomers = @()
foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Filter '*.zig' -Recurse)) {
    if ($owners -contains $f.Name) { continue }
    $text = Get-Content -LiteralPath $f.FullName -Raw
    if (-not $text) { continue }
    if ([regex]::IsMatch($text, '(?s)w32\.(?:Set|Kill)Timer\(\s*[^;]{0,120}?msg_hwnd')) {
        $newcomers += $f.Name
    }
}
Assert 'C3 no unswept file arms a timer on msg_hwnd' ($newcomers.Count -eq 0) `
    ("add to `$owners (and move its ids into msg_timer.zig): " + ($newcomers -join ', '))

# ============================================================================
"== D: the build itself refuses a duplicate"
# ============================================================================

$zig = (Get-Command zig -ErrorAction SilentlyContinue)
if (-not $zig) {
    "  SKIP D: zig is not on PATH, so the compile-time half cannot be exercised here"
    $script:skipped = 1
}
else {
    if (-not $env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-global-cache' }

    $green = (& $zig.Source test $registryPath 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    Assert 'D1 the registry as it stands compiles and its unit test passes' ($LASTEXITCODE -eq 0) `
        ($green -split "`r?`n" | Select-Object -Last 3) -join ' / '

    # NEGATIVE CONTROL for the gate itself (T1133): construct the state the
    # comptime assertion exists to catch and prove it goes red. Done on a COPY,
    # so a killed run cannot leave the repo holding a duplicate.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("msg_timer_dup_" + [guid]::NewGuid().ToString('N') + '.zig')
    try {
        $dupText = $registryText -replace '(?m)^(\s*pub\s+const\s+notif_update\s*:\s*usize\s*=\s*)\d+;', ('${1}' + "$qt;")
        [System.IO.File]::WriteAllText($tmp, $dupText)
        Assert 'D2 the duplicate fixture really is a duplicate' `
        ([regex]::IsMatch($dupText, "(?m)^\s*pub\s+const\s+notif_update\s*:\s*usize\s*=\s*$qt;"))
        $red = (& $zig.Source test $tmp 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        Assert 'D3 a duplicate id fails the compile, naming both offenders' `
        ($LASTEXITCODE -ne 0 -and $red -match 'duplicate App\.msg_hwnd timer id') `
        (($red -split "`r?`n" | Select-Object -First 3) -join ' / ')
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# --- stamp (T783 / T478) ---------------------------------------------------
# Only a CLEAN run stamps; a red one must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard msg-timer-ids -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
