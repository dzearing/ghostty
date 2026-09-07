<#
Counting a JSON array that might not be there (T617).

THE TRAP. In PowerShell 5.1, `$null.anything` is `$null` rather than an error,
and `@($null)` is a ONE-ELEMENT array holding $null. So the idiom every fixture
here reaches for -

    @($rec.session_ids).Count

- answers **1** when `$rec` is `$null`. Not 0, not an error: 1. A record that
does not exist counts as one thing.

WHAT THAT COST. `chooser-restore-all-remote.ps1` looked its fixture record up by
a key another task had re-keyed away, so `$rec` was $null on every run from
2026-08-02. Its failure message printed "the window's blob claims 1 session id",
which is a plausible, specific CAPTURE defect - so the red read as a product bug
in the agent's layout store rather than as a broken oracle, and the store had
held a correct three-id blob the whole time. Six days, and the tracker recorded
the script as green because nothing had re-run it (T617's other half).

THE ANSWER. Absent is 0, a collection counts its elements, and anything else is
one thing:

    Get-CountOrZero $rec.session_ids        # 0 when $rec or the field is absent
    Get-CountOrZero @(1, 2, 3)              # 3
    Get-CountOrZero 'hello'                 # 1, not 5 - a string is one value
    Get-CountOrZero @()                     # 0

Use it anywhere a count is READ BACK OUT of JSON, a store, or an IPC reply -
that is, anywhere the thing being counted might legitimately not exist. For an
array you built yourself two lines up, plain `.Count` is fine and clearer.

The companion is for the message rather than the assertion: a count of 0 and a
record that is missing entirely are different findings, and printing "0" for
both re-creates the same ambiguity one step along.

    Format-CountOrAbsent $rec.session_ids   # '3', or '<absent>' when it is $null
#>

<#
.SYNOPSIS
  Number of elements in $Value: 0 when it is $null, its own count when it is a
  collection, 1 otherwise.
#>
function Get-CountOrZero {
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][object]$Value)

    if ($null -eq $Value) { return 0 }

    # A string is IEnumerable over its characters, so it has to be answered
    # before the collection branch or 'hello' counts as 5.
    if ($Value -is [string]) { return 1 }

    # ICollection covers arrays, ArrayList, Hashtable and the generic lists, and
    # its own .Count is the cheap and correct answer.
    if ($Value -is [System.Collections.ICollection]) { return $Value.Count }

    if ($Value -is [System.Collections.IEnumerable]) {
        $n = 0
        foreach ($x in $Value) { $n++ }
        return $n
    }

    return 1
}

<#
.SYNOPSIS
  $Value's count as text for an assertion message, or '<absent>' when the value
  itself is $null - so "there were none" and "there was no record" do not print
  the same.
#>
function Format-CountOrAbsent {
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][object]$Value,
        [string]$AbsentText = '<absent>'
    )
    if ($null -eq $Value) { return $AbsentText }
    return ([string](Get-CountOrZero $Value))
}
