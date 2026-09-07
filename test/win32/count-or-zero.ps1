<#
.SYNOPSIS
  Acceptance test for test\win32\lib\CountOrZero.ps1 (T617).

.DESCRIPTION
  The helper exists because of one PowerShell 5.1 behavior: `$null.field` is
  $null rather than an error, and `@($null)` is a ONE-element array - so
  `@($rec.session_ids).Count` answers 1 for a record that does not exist. That
  turned a broken fixture oracle into a plausible product-defect message
  ("the window's blob claims 1 session id") and cost six days of a script being
  red while the tracker recorded it green.

  So the first arm here is a NEGATIVE CONTROL: it asserts that the naive idiom
  really does answer 1 on this interpreter. Without it the rest of the file
  could pass on a runtime where the trap does not exist, and would then be
  testing nothing - the helper would look correct for the wrong reason and the
  next fixture author would have no evidence the hazard is real.

  Pure logic: no exe, no window, no agent. Runs anywhere.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\count-or-zero.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\CountOrZero.ps1')

try {
    # --- A. the hazard is real on this interpreter -------------------------
    ''
    '-- A. negative control: the trap this helper exists for'

    $absent = $null
    # Deliberately the WRONG idiom. If this ever stops answering 1, the helper's
    # reason for existing has changed and this file should be re-read, not
    # quietly kept green.
    $naive = @($absent.session_ids).Count
    Assert 'A1 the naive @($null.field).Count really does answer 1' ($naive -eq 1) "answered $naive"

    $naiveEmpty = @(@().session_ids).Count
    Assert 'A2 and it is not an accident of THIS null - an empty result does it too' `
        ($naiveEmpty -eq 1) "answered $naiveEmpty"

    # --- B. Get-CountOrZero -----------------------------------------------
    ''
    '-- B. Get-CountOrZero'

    Assert 'B1 an absent record counts 0, not 1' `
        ((Get-CountOrZero $absent.session_ids) -eq 0) "got $(Get-CountOrZero $absent.session_ids)"
    Assert 'B2 a bare $null counts 0' ((Get-CountOrZero $null) -eq 0) ''
    Assert 'B3 an empty array counts 0' ((Get-CountOrZero @()) -eq 0) ''
    Assert 'B4 a three-element array counts 3' ((Get-CountOrZero @(1, 2, 3)) -eq 3) ''
    # The one-element case is the other half of the same PS 5.1 trap: an array
    # of one UNROLLS, so a helper that trusted `.Count` on what it was handed
    # would read $null here.
    Assert 'B5 a one-element array counts 1' ((Get-CountOrZero @('only')) -eq 1) ''
    Assert 'B6 a scalar counts 1' ((Get-CountOrZero 42) -eq 1) ''
    Assert 'B7 a string is ONE value, not its characters' ((Get-CountOrZero 'hello') -eq 1) `
        "got $(Get-CountOrZero 'hello')"
    Assert 'B8 an empty string is still one value' ((Get-CountOrZero '') -eq 1) ''
    Assert 'B9 a hashtable counts its entries' ((Get-CountOrZero @{ a = 1; b = 2 }) -eq 2) ''
    $list = New-Object System.Collections.ArrayList
    $null = $list.Add('x'); $null = $list.Add('y')
    Assert 'B10 a non-array collection counts its elements' ((Get-CountOrZero $list) -eq 2) ''

    # The shape it is actually reached for: a record parsed back out of JSON.
    $rec = '{"key":"k","session_ids":["a","b","c"]}' | ConvertFrom-Json
    Assert 'B11 a JSON record''s array counts its elements' ((Get-CountOrZero $rec.session_ids) -eq 3) ''
    $recNoField = '{"key":"k"}' | ConvertFrom-Json
    Assert 'B12 a JSON record MISSING the field counts 0' `
        ((Get-CountOrZero $recNoField.session_ids) -eq 0) "got $(Get-CountOrZero $recNoField.session_ids)"
    $recEmpty = '{"session_ids":[]}' | ConvertFrom-Json
    Assert 'B13 a JSON record with an EMPTY array counts 0' `
        ((Get-CountOrZero $recEmpty.session_ids) -eq 0) ''
    $recOne = '{"session_ids":["a"]}' | ConvertFrom-Json
    Assert 'B14 a JSON record with ONE id counts 1' ((Get-CountOrZero $recOne.session_ids) -eq 1) ''

    # --- C. Format-CountOrAbsent ------------------------------------------
    ''
    '-- C. Format-CountOrAbsent: absent and empty must not print the same'

    Assert 'C1 an absent record prints <absent>' `
        ((Format-CountOrAbsent $absent.session_ids) -eq '<absent>') `
        (Format-CountOrAbsent $absent.session_ids)
    Assert 'C2 an EMPTY array prints 0, not <absent>' `
        ((Format-CountOrAbsent $recEmpty.session_ids) -eq '0') `
        (Format-CountOrAbsent $recEmpty.session_ids)
    Assert 'C3 a populated array prints its count' `
        ((Format-CountOrAbsent $rec.session_ids) -eq '3') (Format-CountOrAbsent $rec.session_ids)
    Assert 'C4 the absent text can be spelled for the caller''s message' `
        ((Format-CountOrAbsent $absent.foo -AbsentText '<no record>') -eq '<no record>') ''

    # --- D. the original failure, reconstructed ----------------------------
    ''
    '-- D. the 2026-08-02 masquerade cannot be written again'

    # Verbatim shape of the assertion that lied: look a record up by a key that
    # no longer exists, then report how many session ids it holds.
    $store = @(
        [pscustomobject]@{ key = 'uuid-1'; session_ids = @('a', 'b', 'c') }
    )
    $found = @($store | Where-Object { $_.key -eq 't336-multi' }) | Select-Object -First 1
    Assert 'D1 the lookup really finds nothing' ($null -eq $found) ''
    Assert 'D2 the old message would have claimed one session id' `
        ((@($found.session_ids).Count) -eq 1) ''
    Assert 'D3 the helper reports it as absent instead' `
        ((Format-CountOrAbsent $found.session_ids) -eq '<absent>') `
        (Format-CountOrAbsent $found.session_ids)
    Assert 'D4 and the assertion itself no longer passes for a missing record' `
        ((Get-CountOrZero $found.session_ids) -ne 3) ''

    Complete-TestBody
}
finally {
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the helper as it now stands?". Red leaves the stamp
# alone: red stays due.
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard count-or-zero -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T617 COUNT-OR-ZERO' -Pass $script:passes -Fail $script:failures
