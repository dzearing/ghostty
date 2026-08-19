# printclient-audit acceptance (T940): every win32 window class that paints
# itself can also paint itself into somebody else's DC.
#
#   powershell -NoProfile -File test\win32\printclient-audit.ps1
#
# Non-interactive, launches no Ghoztty and touches no user state: the subject is
# SOURCE TEXT, so this reads .zig files and spawns nothing.
#
# isolation: none - a static audit over source text; nothing here launches
# ghoztty or runs a CLI verb (T680 meta-check reads this marker).
#
# Why it exists. `Get-TestWindowPixels` captures through
# `PrintWindow(PW_RENDERFULLCONTENT)`, which asks DWM for an ASYNCHRONOUS copy
# of the window's composited surface and returns before the copy has finished.
# T835 measured what that does to an assertion: three back-to-back captures of
# ONE UNCHANGED window read the end of the same table row at 1062, 1283 and
# 1179 px, and a P0 investigation went looking for that in the layout code. The
# cure is `-Sync` - `PrintWindow` with no flags, so the window paints the frame
# itself, synchronously - and it works only on a window whose WndProc answers
# `WM_PRINTCLIENT`.
#
# That makes the handler a TEST-VISIBLE contract with no in-app symptom: delete
# one and the app looks fine while every pixel assertion over that window goes
# back to measuring noise. Nothing at compile time notices, and nothing at run
# time notices either - which is how 65 probes across 34 scripts stayed on the
# torn capture for months (T843). So it is checked here instead: a class that
# handles WM_PAINT and not WM_PRINTCLIENT is a finding, and an exemption has to
# be written down with its reason.
#
# Section A gives the analyzer teeth against fixtures; section B is the sweep
# that must stay at zero.
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0

function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

# A window class "paints itself" if its WndProc has a `w32.WM_PAINT =>` arm, and
# "can pose" if it has a `w32.WM_PRINTCLIENT =>` arm. Matched on the switch arm
# rather than on any mention of the constant, so a comment naming WM_PRINTCLIENT
# - and this file is full of prose that does - never counts as a handler.
function Get-PrintClientFindings {
    param([Parameter(Mandatory = $true)][string]$Text)
    $paints = [regex]::Matches($Text, '(?m)^\s*w32\.WM_PAINT\s*=>').Count
    $prints = [regex]::Matches($Text, '(?m)^\s*w32\.WM_PRINTCLIENT\s*=>').Count
    if ($paints -gt 0 -and $prints -eq 0) { return , @('paints but cannot pose') }
    return , @()
}

# The one class that is exempt, and why. An exemption lives here rather than in
# a comment in the source, so adding one is a visible edit to the audit.
#
# App.zig owns the TERMINAL SURFACE, whose pixels come from the renderer, not
# from GDI - `Get-TestWindowPixels` already refuses to capture it at all
# (T214: PrintWindow returns a flat fill for it off the input desktop, so an
# assertion over that capture passes against nothing). A WM_PRINTCLIENT handler
# there would produce exactly the blank frame the refusal exists to prevent.
$exempt = @{
    'App.zig' = 'the terminal surface is renderer-drawn; Get-TestWindowPixels refuses to capture it (T214)'
}

# ============================================================================
"== A: the analyzer catches the shape it exists for, and only that shape"
# ============================================================================

$bad = @(
    '    switch (msg) {',
    '        w32.WM_PAINT => {',
    '            var ps: w32.PAINTSTRUCT = undefined;',
    '            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;',
    '            defer _ = w32.EndPaint(hwnd, &ps);',
    '            self.paint(hdc);',
    '            return 0;',
    '        },',
    '    }'
) -join "`n"
Assert 'A1 a class that paints and cannot pose is a finding' `
((Get-PrintClientFindings -Text $bad).Count -eq 1)

# Built by hand rather than by patching $bad with `-replace`: in PS 5.1
# `-replace` binds tighter than `-join`, so `$s -replace 'x', @(...) -join "`n"`
# hands the operator the ARRAY (flattened with spaces) and joins afterwards.
# The first draft of this file did exactly that, and it collapsed a multi-line
# fixture onto one line - where the arm no longer starts a line, the analyzer
# saw no WM_PAINT at all, and the assertion failed for a reason that had nothing
# to do with what it was testing.
$goodArm = @(
    '        w32.WM_PRINTCLIENT => {',
    '            if (wparam == 0) return 0;',
    '            self.paint(@ptrFromInt(wparam));',
    '            return 0;',
    '        },'
) -join "`n"
$good = $bad -replace '(?m)^    \}$', ($goodArm + "`n" + '    }')
Assert 'A2 adding the handler clears the finding' `
((Get-PrintClientFindings -Text $good).Count -eq 0) $good

# The trap this analyzer would otherwise fall into: this very file, and several
# of the source files it judges, discuss WM_PRINTCLIENT in prose. A mention is
# not a handler, and scoring it as one would make the sweep permanently green.
$commented = $bad -replace '(?m)^(        w32\.WM_PAINT)', ('        // WM_PRINTCLIENT would go here one day.' + "`n" + '$1')
Assert 'A3 a COMMENT naming WM_PRINTCLIENT is not a handler' `
((Get-PrintClientFindings -Text $commented).Count -eq 1) $commented

# A file with no WndProc at all is not a finding - most of src/apprt/win32 is
# not a window class, and an audit that flagged them all would be ignored.
Assert 'A4 a file that never paints is not a finding' `
((Get-PrintClientFindings -Text 'pub fn helper() void {}').Count -eq 0)

# ============================================================================
"== B: the sweep -- every painting class in src/apprt/win32 can pose"
# ============================================================================

$srcDir = Join-Path $Repo 'src\apprt\win32'
Assert 'B0 the source directory is where this expects it' (Test-Path -LiteralPath $srcDir) $srcDir

$painters = @()
$offenders = @()
$exemptSeen = @()
if (Test-Path -LiteralPath $srcDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Filter '*.zig' -Recurse)) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        if (-not $text) { continue }
        if ([regex]::Matches($text, '(?m)^\s*w32\.WM_PAINT\s*=>').Count -eq 0) { continue }
        $painters += $f.Name
        if ((Get-PrintClientFindings -Text $text).Count -eq 0) { continue }
        if ($exempt.ContainsKey($f.Name)) { $exemptSeen += $f.Name; continue }
        $offenders += $f.Name
    }
}

# A sweep that finds nothing to sweep is not a green result, it is a broken
# path - the failure mode every audit in this suite has to rule out first.
Assert "B1 the sweep found the window classes ($($painters.Count) paint)" ($painters.Count -ge 8) `
    ($painters -join ', ')
Assert 'B2 no class paints itself without being able to pose' ($offenders.Count -eq 0) `
    ("still on the torn capture: " + ($offenders -join ', '))

foreach ($name in $exemptSeen) { "  NOTE exempt: $name -- $($exempt[$name])" }
# An exemption for a file that no longer paints (or no longer exists) is stale
# and would silently excuse a future regression in a file of the same name.
foreach ($name in $exempt.Keys) {
    Assert "B3 the exemption for $name is still live" ($painters -contains $name) `
        'listed as exempt but no longer handles WM_PAINT'
}

"  NOTE painting classes: $($painters -join ', ')"

# --- stamp (T783 / T478) ---------------------------------------------------
# Only a CLEAN run stamps; a red one must stay due.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard printclient-audit -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
