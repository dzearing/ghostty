# Which surface the viewer's feedback composer runs on, stated rather than
# assumed (T1102).
#
# T934/T936 made a WebView2 page the composer's DEFAULT surface and kept the
# RichEdit as a runtime fallback, reachable with GHOZTTY_COMPOSER_SURFACE. A
# script that drives the composer through window messages -- Send-TestControlText,
# Send-TestControlKey, Get-TestControlText -- can only reach the native control:
# SendInput and CopyFromScreen are dead on the background test desktop (T233),
# and a Chromium window is not addressable by WM_SETTEXT from another process.
#
# When such a script does NOT pin the surface it gets the web page, and the
# RichEdit it reads is hidden and empty. That is not a quiet failure, it is a
# LOUD and MISLEADING one: on 2026-08-22 four scripts reported the composer
# "holds ''" and the report holding zero images, which reads as a broken feature
# and is really the harness typing into a control nobody is looking at. (Worse:
# EN_CHANGE on that dead control mirrors its text back over the pane's buffer,
# so the write also takes the attached pictures out of the report.)
#
# So there are two calls here and both matter:
#
#   Set-ComposerSurface 'richedit'   - ask for the surface this script can drive
#   Wait-ComposerSurface $errlog ... - PROVE the app agreed, in one assertion
#
# The proof exists because asking is not getting: the env var is one of three
# ways the app can end up on the RichEdit, and `richedit(controller-refused)`
# after a WebView2 failure would otherwise be indistinguishable from the pin.
#
# T937 removes the fallback and the env var; when it does, the scripts that call
# Set-ComposerSurface here are exactly the list that has to be re-pointed.

Set-StrictMode -Version Latest

# Pin the composer surface for every ghoztty this script launches. Inherited
# through CreateProcessW, so it must be set before the app starts.
function Set-ComposerSurface {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('richedit', 'web')]
        [string]$Surface
    )
    $env:GHOZTTY_COMPOSER_SURFACE = $Surface
}

# True once the pane's stderr says the composer opened on $Want.
#
# The app logs `viewer feedback composer surface=<what>` from openComposer, with
# `richedit(forced)` / `richedit(no-environment)` / `richedit(controller-refused)`
# naming WHY it is on the control. Matching on the `richedit` stem accepts all
# three, which is right for a script that only needs a native control -- what it
# must never accept is `web`.
function Wait-ComposerSurface {
    param(
        [Parameter(Mandatory = $true)][string]$Log,
        [Parameter(Mandatory = $true)]
        [ValidateSet('richedit', 'web')]
        [string]$Want,
        [int]$TimeoutMs = 15000
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Log) {
            $hit = @(Select-String -Path $Log -Pattern ('composer surface=' + $Want) `
                    -SimpleMatch -ErrorAction SilentlyContinue)
            if ($hit.Count -gt 0) { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# What the app actually reported, for the failure message. Empty when it has not
# said anything yet.
function Get-ComposerSurface {
    param([Parameter(Mandatory = $true)][string]$Log)
    if (-not (Test-Path $Log)) { return '' }
    $hits = @(Select-String -Path $Log -Pattern 'composer surface=(\S+)' -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) { return '' }
    return $hits[-1].Matches[0].Groups[1].Value
}
