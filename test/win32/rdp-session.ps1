# Remote Desktop session acceptance (tracker T1253).
#
# THE GAP THIS CLOSES. T1249, T1251 and T1252 taught the terminal to explain,
# then survive, a display driver whose OpenGL is below the renderer's floor -
# and all three are proved by PRETENDING. `GHOZTTY_GL_FORCE_VERSION` moves the
# number a context reports and nothing else. The failure the user actually hit
# was a whole environment: reached from a MacBook over Microsoft's Windows App
# on 2026-09-01, where the display driver really is that old, the desktop is
# encoded and shipped over a wire, the DPI and the monitor topology are the
# CLIENT's, and window composition behaves differently. A pass under the seam
# says the fallback path runs. It does not say the terminal is usable there,
# and nobody had ever watched Ghoztty launch inside an RDP session.
#
# So this script asserts nothing at all unless it is running inside one. That
# is the whole design: it is not a test with a skip branch, it is a test whose
# subject IS the session it runs in.
#
# THE CONTRACT it asserts, inside a real remote session:
#
#   A. The session really is remote, and what it is gets WRITTEN DOWN -
#      SM_REMOTESESSION, the client name, the display adapter, the desktop
#      geometry and DPI. Every number below is only as interesting as the
#      environment it was taken in, so the environment is evidence, not
#      preamble.
#   B. Ghoztty LAUNCHES: a `GhozttyWindow` comes up, and the T1177
#      startup-failure dialog does not. The refusal and the window are the two
#      endings of the same condition and only one of them is acceptable here.
#   C. The renderer's own account names the implementation it drew with and the
#      GL the session actually offers - `loaded OpenGL <maj>.<min>
#      renderer="..." vendor="..." impl=system|fallback`. Whichever way it
#      went is a RESULT: on this display `impl=fallback` is the T1251/T1252
#      path doing its job, and `impl=system` means the session's driver clears
#      4.3 on its own. What would be a defect is the app coming up with no
#      account of either.
#   D. `ghoztty +list` answers over the remote session the way it does locally.
#      The named pipe is per-user and session-agnostic by construction, which
#      is a claim nobody had ever run.
#   E. Frame pacing is MEASURED, not asserted. `GHOZTTY_PERF` samples are
#      collected off a pane under a sustained stream and the median fps and
#      worst inter-frame gap are recorded here and in the artifact. The task is
#      explicit that slow-but-working is a result and belongs in a follow-up
#      rather than a red run, so the assertion is that samples EXIST - a run
#      that measured nothing is the failure, a run that measured 12 fps is a
#      finding.
#   F. Session restore behaves: a named window recorded in the manifest comes
#      back under the same name after the app is killed and relaunched. Restore
#      is the feature most likely to be quietly broken by a different desktop,
#      because it puts windows back at coordinates the last session chose.
#
# WHY IT RUNS ON THE INTERACTIVE DESKTOP (the default here, unlike every other
# GUI script in this suite). `lib\TestDesktop.ps1` exists so acceptance never
# takes the user's foreground - but a background desktop is never composited
# and never presented, so frames drawn on it are not shipped over the RDP wire.
# Arm E would then measure a renderer talking to nothing, which is precisely
# the number this script exists to get right. Whoever runs this is deliberately
# sitting in an RDP session watching it, so the foreground is theirs to lend.
# `-BackgroundDesktop` is available for the arms that do not care.
#
# HOW TO GET A SESSION. This box cannot make one for itself: Windows 11 Pro
# serves one interactive session at a time, so an RDP connection from anywhere
# - localhost included - DISCONNECTS the console rather than joining it. It
# takes a second machine:
#
#   1. On this box: Settings > System > Remote Desktop, on. (`qwinsta` should
#      list `rdp-tcp ... Listen`.)
#   2. From the other machine (Microsoft's Windows App on macOS, or mstsc),
#      connect to this box and sign in as the same user.
#   3. In the remote session:
#        powershell -NoProfile -File test\win32\rdp-session.ps1
#
# Run on the console it prints ASSERTED NOTHING and exits 2, which is the
# demonstration that it cannot be satisfied from the wrong place - the same
# reason `gate-negatives.ps1` exists for the loop's gates.
#
#   powershell -NoProfile -File test\win32\rdp-session.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Agent = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$PerfSeconds = 12,
    [switch]$BackgroundDesktop,
    [switch]$SelfTest
)

# -SelfTest runs the whole body on whatever desktop it finds, so the author can
# prove the arms EXECUTE without a second machine. It is deliberately unable to
# produce a pass: the verdict is replaced with SELF-TEST and exit 2, the
# evidence artifact records `sm_remotesession: false`, and the guard stamp is
# never written. Without it the first person to run this from an RDP session
# would be debugging the harness instead of the terminal - and with a green
# path it would be a way to satisfy T1253 from the console, which is the one
# thing this script exists to prevent.

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name"; $script:failures++ }
}

# Everything arm A learns and arms C/E measure, gathered in one object so the
# run leaves a machine-readable record behind as well as a screenful. A number
# nobody wrote down is a number the next reader has to re-earn on a machine
# they may not have.
$script:evidence = [ordered]@{
    taken       = (Get-Date).ToString('s')
    host        = $env:COMPUTERNAME
    session     = [ordered]@{}
    gl          = [ordered]@{}
    perf        = [ordered]@{}
}

$DIALOG_CLASS = 'GhozttyConfirmDialog'

# SM_REMOTESESSION (0x1000) is the OS's own answer to "is this desktop being
# shipped somewhere else". It is the right question rather than $env:SESSIONNAME
# (which a console session on a box with RDP enabled can still answer oddly) or
# $env:CLIENTNAME (empty over some clients, and inherited by child processes).
# All three are recorded; only this one decides.
if (-not ('Ghoztty.RdpProbe' -as [type])) {
    Add-Type -Namespace Ghoztty -Name RdpProbe -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetSystemMetrics(int nIndex);
'@ | Out-Null
}
function Test-RemoteSession { return ([Ghoztty.RdpProbe]::GetSystemMetrics(0x1000) -ne 0) }

$isRemote = Test-RemoteSession
$script:evidence.session = [ordered]@{
    sm_remotesession = $isRemote
    sessionname      = "$env:SESSIONNAME"
    clientname       = "$env:CLIENTNAME"
}

if (-not $isRemote -and -not $SelfTest) {
    Write-Host ''
    Write-Host '  This box is on its CONSOLE desktop, so there is nothing here to measure.'
    Write-Host '  See the header of this script for how to reach it from another machine;'
    Write-Host '  Windows 11 Pro will not give this box a second session by itself.'
    Write-Host ''
    Complete-TestBody
    Write-TestAssertedNothing -Label 'rdp-session' `
        -Reason 'not running inside a Remote Desktop session (SM_REMOTESESSION is 0)'
}

if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: $Exe not found - build it first"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-rdp-session-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPerf = $env:GHOZTTY_PERF

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 'rdp')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null

# -Interactive unless the caller opted out: see the header for why this script
# inverts the suite's default.
# -SelfTest always uses the background desktop: it is not measuring
# presentation, and it must not take the user's foreground to prove it parses.
$td = New-TestDesktop -Interactive:(-not ($BackgroundDesktop -or $SelfTest))

# An endless `type` of a few MB, the same load generator soak.ps1 uses, so the
# fps numbers this run reports are comparable with the ones taken locally.
$streamFile = Join-Path $root 'stream.txt'
$block = [System.Text.StringBuilder]::new()
1..500 | ForEach-Object { [void]$block.AppendLine('rdp-stream-payload ' + ('x' * 60) + " $_") }
$sw = [System.IO.StreamWriter]::new($streamFile, $false)
1..40 | ForEach-Object { $sw.Write($block.ToString()) }
$sw.Close()

function Wait-Manifest($tmp, $predicate, $timeoutSec = 30) {
    $path = Join-Path $tmp 'ghoztty\session-layout-debug.json'
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            try {
                $m = Get-Content $path -Raw | ConvertFrom-Json
                if (& $predicate $m) { return $m }
            } catch { }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# `+list --json` answers `{ data: { windows: [ { target, tabs: [...] } ] } }`.
# The raw text is returned alongside the targets because arm E asks about a
# SPLIT's name, which lives down in the tab's split tree rather than at window
# level, and the question there is only "is that pane still in the answer".
function Get-ListDoc {
    $raw = (& $Exe +list --json 2>$null | Out-String).Trim()
    $targets = @()
    if ($raw) {
        try {
            $doc = $raw | ConvertFrom-Json
            if ($doc.data) {
                $targets = @(@($doc.data.windows) | ForEach-Object { [string]$_.target } |
                    Where-Object { $_ })
            }
        } catch { }
    }
    return [pscustomobject]@{ Raw = $raw; Targets = $targets }
}
function Get-ListNames { return @((Get-ListDoc).Targets) }

try {
    # ========================================================================
    Write-Host '== A: the session this run is measuring'
    # ========================================================================
    Assert 'A1 SM_REMOTESESSION says this desktop is remote' $isRemote

    $video = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    $script:evidence.session.video_controllers = $video
    Assert 'A2 the session names a display adapter' ($video.Count -gt 0)

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $screens = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        "$($_.DeviceName) $($_.Bounds.Width)x$($_.Bounds.Height)"
    })
    $script:evidence.session.screens = $screens
    Assert 'A3 the session has at least one screen with a nonzero size' `
        (@([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Width -gt 0 }).Count -gt 0)

    Write-Host "  session: client='$env:CLIENTNAME' adapters=[$($video -join '; ')] screens=[$($screens -join '; ')]"

    # ========================================================================
    Write-Host '== B: Ghoztty launches here'
    # ========================================================================
    $tmp = Join-Path $root 'app'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $Agent
    $env:GHOZTTY_PERF = '1'

    $errLog = Join-Path $root 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errLog
    $win = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    Assert 'B1 a terminal window came up in the remote session' ($win -ne [IntPtr]::Zero)
    Assert 'B2 and no startup-failure dialog was raised' `
        (@(Get-TestWindows -ProcessId $app.Pid -Class $DIALOG_CLASS -AllowHidden).Count -eq 0)

    # ========================================================================
    Write-Host '== C: what it drew with, in its own words'
    # ========================================================================
    # A debug build logs to stderr rather than to the file sink, so the
    # renderer's account is read out of the child's captured stderr.
    Start-Sleep -Milliseconds 1200
    $text = if (Test-Path $errLog) { Get-Content $errLog -Raw } else { '' }
    $m = [regex]::Match($text,
        'loaded OpenGL (?<maj>\d+)\.(?<min>\d+) renderer="(?<r>[^"]*)" vendor="(?<v>[^"]*)" impl=(?<i>\w+)')
    Assert 'C1 the renderer reported the context it loaded' $m.Success
    if ($m.Success) {
        $script:evidence.gl = [ordered]@{
            version  = "$($m.Groups['maj'].Value).$($m.Groups['min'].Value)"
            renderer = $m.Groups['r'].Value
            vendor   = $m.Groups['v'].Value
            impl     = $m.Groups['i'].Value
            fell_back = ($text -match 'OpenGL implementation: fallback')
        }
        Write-Host "  GL: $($script:evidence.gl.version) renderer='$($script:evidence.gl.renderer)' vendor='$($script:evidence.gl.vendor)' impl=$($script:evidence.gl.impl)"
    }
    # C2 is deliberately an OR, not a preference. Either ending is correct
    # here; what is not correct is a window that came up with no account of
    # which implementation is behind it.
    Assert 'C2 and named the implementation as system or fallback' `
        ($m.Success -and $m.Groups['i'].Value -in @('system', 'fallback'))
    # C3 is the T1251/T1252 half: IF it fell back, the log has to say so in the
    # words the loader prints, so a reader can tell a fallback from a system
    # context that merely reported an odd renderer string.
    Assert 'C3 a fallback, if taken, is stated by the loader as well as the renderer' `
        (-not $m.Success -or
         ($m.Groups['i'].Value -ne 'fallback') -or
         ($text -match 'OpenGL implementation: fallback'))

    # ========================================================================
    Write-Host '== D: the CLI answers over the remote session'
    # ========================================================================
    # `.ToString()` before Out-String (T883): a merged stream carries
    # ErrorRecords, and Out-String would format them with the host's width.
    $listRaw = (& $Exe +list --json 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    $listCode = $LASTEXITCODE
    Assert "D1 +list --json exited 0 (got $listCode)" ($listCode -eq 0)
    $names = Get-ListNames
    Assert "D2 and reported the live window (names: $($names -join ', '))" ($names.Count -ge 1)

    # ========================================================================
    Write-Host "== E: frame pacing over the wire ($PerfSeconds s under load)"
    # ========================================================================
    & $Exe +split --target=window-1 --name=rdp-stream --direction=right --shell=cmd `
        "--command=for /l %i in (1,1,2000000) do @type $streamFile" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $before = if (Test-Path $errLog) { (Get-Item $errLog).Length } else { 0 }
    Start-Sleep -Seconds $PerfSeconds
    $after = if (Test-Path $errLog) { Get-Content $errLog -Raw } else { '' }
    $slice = if ($after.Length -gt $before) { $after.Substring([int]$before) } else { '' }

    $fps = @(); $gaps = @()
    foreach ($line in ($slice -split "`r?`n")) {
        if ($line -match 'perf (?:pane=(\S+) )?fps=(\d+) max_gap_ms=(\d+)') {
            $fps += [int]$Matches[2]; $gaps += [int]$Matches[3]
        }
    }
    # The assertion is that a MEASUREMENT happened. T1253 is explicit that
    # slow-but-working is a result and belongs in a follow-up task, so a low
    # number is recorded and reported, never scored red - but a run that
    # collected no samples at all measured nothing and must say so.
    Assert "E1 renderer telemetry produced samples (got $($fps.Count))" ($fps.Count -gt 0)
    if ($fps.Count -gt 0) {
        $sorted = $fps | Sort-Object
        $median = $sorted[[int]([math]::Floor($sorted.Count / 2))]
        $worst = ($gaps | Measure-Object -Maximum).Maximum
        $script:evidence.perf = [ordered]@{
            samples          = $fps.Count
            median_fps       = $median
            min_fps          = $sorted[0]
            max_fps          = $sorted[-1]
            worst_gap_ms     = $worst
            window_seconds   = $PerfSeconds
        }
        Write-Host "  pacing: $($fps.Count) samples, median $median fps (min $($sorted[0]), max $($sorted[-1])), worst frame gap ${worst}ms"
    }
    Assert 'E2 and the streaming pane is still there to have produced them' `
        ((Get-ListDoc).Raw -match 'rdp-stream')

    & $Exe +close --target=rdp-stream 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800

    # ========================================================================
    Write-Host '== F: session restore behaves here'
    # ========================================================================
    & $Exe +new-window --target=rdp-restore 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $mf = Wait-Manifest $tmp {
        param($mm)
        @(@($mm.windows) | ForEach-Object { [string]$_.ipc_name }) -contains 'rdp-restore'
    }
    Assert 'F1 the manifest recorded the named window' ($null -ne $mf)

    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 1200)
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $Agent
    $relaunch = Start-OnTestDesktop -Exe $Exe
    [void](Wait-TestWindow -ProcessId $relaunch.Pid -Class 'GhozttyWindow' -TimeoutMs 40000)
    $post = @()
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $post = Get-ListNames
        if ($post -contains 'rdp-restore') { break }
        Start-Sleep -Milliseconds 700
    }
    Assert "F2 it came back under the same name after a relaunch (got: $($post -join ', '))" `
        ($post -contains 'rdp-restore')

    # LAST statement of the top-level try (T1039): an unwind from anywhere
    # above must not be able to reach the verdict as if the run had finished.
    Complete-TestBody
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($savedPerf) { $env:GHOZTTY_PERF = $savedPerf }
    else { Remove-Item env:GHOZTTY_PERF -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 800)

    # The artifact is written even on a red run: a session that failed is
    # exactly the one whose environment somebody will want to read.
    $artDir = Join-Path $PSScriptRoot 'artifacts'
    New-Item -ItemType Directory -Force $artDir | Out-Null
    # A self-test's numbers were taken on the wrong desktop, so they are
    # written under their own name: the file a reader reaches for must never
    # turn out to be console noise wearing the evidence file's name.
    $artName = 'rdp-session.json'
    if ($SelfTest) { $artName = 'rdp-session-selftest.json' }
    $artifact = Join-Path $artDir $artName
    $script:evidence | ConvertTo-Json -Depth 6 | Set-Content -Encoding ascii $artifact
    Write-Host ''
    Write-Host "  evidence written to $artifact"

    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

if ($SelfTest) {
    Write-Host ''
    Write-Host "rdp-session: SELF-TEST ($($script:passes) passed, $($script:failures) failed) - the body ran; nothing about Remote Desktop was proved" `
        -ForegroundColor Yellow
    exit 2
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0 -and $script:passes -gt 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard rdp-session -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'rdp-session' -MinPass 12
