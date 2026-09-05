<#
.SYNOPSIS
  DOM-level acceptance test for the task dashboard PAGE (T565).

.DESCRIPTION
  test\win32\task-dashboard.ps1 covers the dashboard's HTTP surface, and the
  page's inline script is checked to PARSE - but nothing exercised the 74k of
  JS behind its buttons. A broken control was found by a human clicking it.

  This drives the real page in a real browser, against a stub server, and
  asserts what the clicks actually did:

    - the shell loads, renders, and reports no error;
    - the two-step unblock (T564) ARMS on the first click - posting nothing -
      and only the second click puts the task back in the queue;
    - an armed watch gets the other control (Reopen anyway, not primary);
    - a stale in-progress row resets to to-do;
    - a decision resolves with the option that was clicked, and refuses to
      resolve when neither an option nor a note was given;
    - the tasks table filters, opens a task dialog, and closes it again;
    - the data and digest views render without throwing.

  Why a stub server rather than the real one: the unblock and reset buttons
  POST to /api/status, which REWRITES REAL TASK FILES, and the real payload has
  no guaranteed blocked task, armed watch, stale row or open decision to click.
  The stub (test\win32\lib\dashboard-stub-server.js) serves the real page bytes
  and a payload captured from the real builder (`--once`) with those four
  shapes injected, records POSTs instead of performing them, and hands the
  recording back over /api/_posted. Nothing in the repo is written.

  The page itself is never edited: the stub appends one <script> tag loading
  test\win32\lib\dashboard-dom-selftest.js, so a green run is evidence about
  the shipped page rather than about test code living inside it.

  -NegativeControl is the demonstration that this harness can score red: it
  serves the page with the two-step guard disarmed, and the run MUST fail.

  No GUI, no desktop, no ghoztty processes - node + headless Edge only.
  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  PASS $label" }
    else {
        $script:fail++
        Write-Host "  FAIL $label$(if ($detail) { ' -- ' + $detail })"
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-TestAssertedNothing -Reason 'node is not installed on this box, so the dashboard page cannot be served'
}
$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $edge) {
    Write-TestAssertedNothing -Reason 'Edge is not installed on this box, so the page cannot be driven in a real browser'
}

$dash   = Join-Path $Repo 'scripts\task-dashboard.js'
$page   = Join-Path $Repo 'scripts\task-dashboard.page.html'
$stub   = Join-Path $PSScriptRoot 'lib\dashboard-stub-server.js'
$driver = Join-Path $PSScriptRoot 'lib\dashboard-dom-selftest.js'
foreach ($f in @($dash, $page, $stub, $driver)) {
    if (-not (Test-Path $f)) { Write-TestAssertedNothing -Reason "missing $f" }
}

# --- pick a port that is verifiably FREE ------------------------------------
function Test-PortFree([int]$p) {
    $l = $null
    try {
        $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
        $l.Start()
        return $true
    } catch { return $false }
    finally { if ($l) { $l.Stop() } }
}
if ($Port -eq 0) {
    foreach ($p in 7861..7880) { if (Test-PortFree $p) { $Port = $p; break } }
}
if ($Port -eq 0) {
    Write-TestAssertedNothing -Reason 'no free port in 7861-7880, so the stub server cannot be started'
}
$Base = "http://127.0.0.1:$Port"

function Get-Http([string]$url, [int]$timeoutSec = 30) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec $timeoutSec
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = [string]$r.Content }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return [pscustomobject]@{ Status = -1; Body = $_.Exception.Message } }
        $sr = New-Object System.IO.StreamReader ($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close()
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $body }
    }
}

Write-Host "dashboard DOM acceptance (T565) on port $Port$(if ($NegativeControl) { ' [NEGATIVE CONTROL]' })"

$work    = Join-Path $env:TEMP "dashboard-dom-$PID"
$dataJson = Join-Path $work 'payload.json'
$domFile  = Join-Path $work 'dom.html'
$profile  = Join-Path $work 'edge-profile'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$srv = $null
try {
    # --- the fixture comes from the REAL payload builder --------------------
    # `--once` prints the same object /api/data serves, so the stub cannot be
    # serving a hand-written shape that has drifted from the real one.
    $payload = & $node.Source $dash --once 2>$null
    $payloadText = ($payload -join "`n")
    Assert 'A1 the real builder produced a payload' `
        ($LASTEXITCODE -eq 0 -and $payloadText.Length -gt 1000) "exit=$LASTEXITCODE len=$($payloadText.Length)"
    if ($payloadText.Length -le 1000) { throw 'ABORT: no payload to serve; nothing else can be measured' }
    [System.IO.File]::WriteAllText($dataJson, $payloadText)

    # --- serve it -----------------------------------------------------------
    $stubArgs = @('"' + $stub + '"', '--page', '"' + $page + '"', '--driver', '"' + $driver + '"',
                  '--data', '"' + $dataJson + '"', '--port', $Port)
    if ($NegativeControl) { $stubArgs += @('--break', 'two-step') }
    $srv = Start-Process -FilePath $node.Source -ArgumentList ($stubArgs -join ' ') `
        -WorkingDirectory $Repo -WindowStyle Hidden -PassThru

    $up = $false
    foreach ($i in 1..40) {
        $r = Get-Http "$Base/api/data" 5
        if ($r.Status -eq 200) { $up = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert 'A2 the stub serves the fixture within 10s' $up
    if (-not $up) { throw 'ABORT: stub never came up' }

    $html = (Get-Http "$Base/").Body
    Assert 'A3 the served page is the real page with the driver appended' `
        ($html -match 'function blockedCard\(' -and $html -match 'selftest-dom\.js')

    # --- drive it in a real browser -----------------------------------------
    # --dump-dom prints the DOM after the virtual time budget, which is how the
    # driver's verdict gets back here. A click path is not something an HTTP
    # probe can see; this can.
    & cmd /c "`"$edge`" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir=`"$profile`" --virtual-time-budget=30000 --dump-dom `"$Base/`" > `"$domFile`" 2>nul"
    $dom = if (Test-Path $domFile) { [System.IO.File]::ReadAllText($domFile) } else { '' }

    $verdict = ([regex]::Match($dom, 'T565-DOM-SELFTEST [^<]*')).Value.Trim()
    Assert 'B1 the in-browser driver ran to a verdict' ($verdict -ne '') `
        'no verdict in the dumped DOM - the driver never finished'

    # Every check is reported individually, so a red run names the control that
    # broke rather than only the count.
    $checks = [regex]::Matches($dom, 'CHECK (PASS|FAIL) ([^<]*)')
    Assert 'B2 the driver reported its checks' ($checks.Count -ge 25) "got $($checks.Count)"
    foreach ($m in $checks) {
        $ok = $m.Groups[1].Value -eq 'PASS'
        Assert ("B* " + $m.Groups[2].Value.Trim()) $ok
    }

    # --- the clicks produced real requests, not just DOM text ---------------
    # Read back out of the recorder rather than trusting the page's own account
    # of itself: this is the half of the evidence the browser cannot fake.
    $postedRaw = (Get-Http "$Base/api/_posted").Body
    # PS 5.1's ConvertFrom-Json hands a JSON array back as ONE object, so @()
    # around it counts 1 no matter how many records there are. The extra
    # ForEach-Object is what unrolls it.
    $posts = @()
    try { $posts = @($postedRaw | ConvertFrom-Json | ForEach-Object { $_ }) } catch {}
    Assert 'C1 exactly the three intended requests were made' ($posts.Count -eq 3) `
        "got $($posts.Count): $postedRaw"
    $status = @($posts | Where-Object { $_.url -eq '/api/status' })
    $resolve = @($posts | Where-Object { $_.url -eq '/api/resolve' })
    Assert 'C2 two status flips, both to to-do' `
        ($status.Count -eq 2 -and @($status | Where-Object { $_.body.status -eq 'todo' }).Count -eq 2) `
        "got $($status.Count)"
    Assert 'C3 the unblock named the blocked task' `
        (@($status | Where-Object { $_.body.id -eq 'TX901' }).Count -eq 1)
    Assert 'C4 the reset named the stale task' `
        (@($status | Where-Object { $_.body.id -eq 'TX903' }).Count -eq 1)
    Assert 'C5 the decision resolved with the option that was clicked' `
        ($resolve.Count -eq 1 -and $resolve[0].body.id -eq 'DX90' -and $resolve[0].body.answer -eq 'fade') `
        $postedRaw
} catch {
    $script:fail++
    Write-Host "  FAIL suite aborted: $($_.Exception.Message)"
} finally {
    if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($NegativeControl) {
    # The control passes when the run FAILED: a harness that stays green with
    # the two-step guard disarmed is not measuring the two-step guard.
    $caught = $script:fail -gt 0
    Write-Host ''
    Write-Host "NEGATIVE CONTROL: $($script:fail) failure(s) with the two-step guard disarmed"
    Complete-TestBody
    if ($caught) {
        Write-TestVerdict -Label 'T565 DASHBOARD DOM (negative control)' -Pass 1 -Fail 0 -Skipped 0
    } else {
        Write-TestVerdict -Label 'T565 DASHBOARD DOM (negative control)' -Pass 0 -Fail 1 -Skipped 0
    }
    return
}

# --- stamp (T783) -----------------------------------------------------------
Complete-TestBody
if ($script:fail -eq 0) {
    if ($script:skipped -gt 0) {
        "  stamp NOT updated: $($script:skipped) section(s) skipped, so this run did not cover the whole harness"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard dashboard-dom -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    }
}

Write-TestVerdict -Label 'T565 DASHBOARD DOM' -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
