# Rendering a string so a FAILURE MESSAGE can be read (T648, shared by T672).
#
# The composer scripts compare the WHOLE text of the RichEdit against the exact
# text that should be in it, because a substring needle cannot tell "correct"
# apart from "damaged in a way the author did not picture": an unguarded
# Backspace over an `[Image #1]` chip leaves `[Image #1`, which satisfies
# `-notmatch '\[Image #1\]'` while being precisely the corruption the arm exists
# to catch.
#
# A whole-text comparison is only useful if its failure message is readable, and
# the interesting differences are exactly the ones a console eats: a doubled
# space, a stray CR, a lone surrogate, an emoji the test desktop cannot render.
# So every character outside printable ASCII is shown as `\uXXXX`.
#
#   Assert ($got -ceq $want) "... (got '$(Show-Text $got)', want '$(Show-Text $want)')"

Set-StrictMode -Version Latest

function Show-Text([string]$s) {
    if ($null -eq $s) { return '<null>' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        $n = [int]$c
        if ($n -ge 32 -and $n -lt 127) { [void]$sb.Append($c) }
        else { [void]$sb.AppendFormat('\u{0:X4}', $n) }
    }
    return $sb.ToString()
}
