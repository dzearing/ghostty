# T41 acceptance: the close confirmation is skipped when the pane's shell is
# IDLE, and still shown when something is running under it.
#
# Why the product change exists: the core decides "a process is still running"
# from `cursorIsAtPrompt`, which is fed by the shell's OSC 133 semantic prompt
# marks. cmd.exe and stock PowerShell emit none, so on Windows the answer was
# ALWAYS "running" - closing a tab that was just cmd.exe sitting at a prompt
# asked for confirmation every time. The Windows-native tiebreaker is the
# process table: a shell with no descendants has nothing to lose.
#
# Both backends are covered, because the user runs the one this script would
# otherwise miss:
#
#   Section A - session-persistence OFF: the pane's shell is a direct child of
#     ghoztty.exe (the `exec` termio backend).
#   Section B - session-persistence ON (the DEFAULT): the shell runs under
#     ghoztty-agent.exe and the app only knows the pid the agent reports (the
#     `remote` backend, local connection). A fix that only handles `exec`
#     leaves every real user pane confirming.
#
# Each section runs the same two cases in ONE window, busy first:
#
#   1. BUSY (`ping -n 100 127.0.0.1` running) + ctrl+w -> the confirm dialog
#      appears. This is also the POSITIVE CONTROL for case 2: it proves the
#      chord reaches the app in this window, so "no dialog" below cannot be
#      "no keystroke". Escape cancels it.
#   2. IDLE (ping stopped, shell back at its prompt) + the SAME chord -> no
#      dialog, and the window actually closes. Both halves are asserted: a
#      swallowed chord also produces no dialog.
#
# Independent oracle for the busy/idle state itself: the shell's descendants
# read straight out of Win32_Process, never from anything the app says. The
# pane's shell pid comes from `ghoztty +list --json`, and is asserted to name a
# LIVE process - on Windows the agent used to report the child's HANDLE value
# there, a number that is a pid in no process at all.
#
# Each section also runs `+list --pid=<a process inside the pane>`, the same
# shell pid read back through its other consumer (this is how a process finds
# its own pane, e.g. /reset-context) - it has no other on-box coverage.
#
# -NegativeControl inverts case 2's verdict (asserts the idle close DOES
# confirm), so a passing run proves the script discriminates.
#
# T217/T218: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1)
# and never takes the user's foreground.
# T267: sets its own window size rather than inheriting whatever the last GUI
# script left in window_placement-debug.
#
#   powershell -NoProfile -File test\win32\close-confirm-idle.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: no exe at $Exe"; exit 1 }

# Isolate the IPC endpoint (inherited through CreateProcessW) so a stray
# instance on the shared pipe cannot answer our +list.
$env:GHOZTTY_PIPE_SUFFIX = '-t41'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses([string[]]$Names) {
    foreach ($name in $Names) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 600
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
    # A restored layout would hand this run the previous run's panes.
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json') -ErrorAction SilentlyContinue
}

# Every live descendant pid of $Root, from the OS process table.
function Get-DescendantPids([int]$Root) {
    $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name
    $byParent = @{}
    foreach ($p in $all) {
        $key = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = @() }
        $byParent[$key] += $p
    }
    $out = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        foreach ($child in $byParent[$cur]) {
            $out += $child
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
    return $out
}

function Wait-Descendants([int]$Root, [bool]$Want, [int]$TimeoutMs = 15000) {
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        $d = @(Get-DescendantPids $Root)
        if ($Want -and $d.Count -gt 0) { return $d }
        if (-not $Want -and $d.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 400
        $waited += 400
    }
    return @(Get-DescendantPids $Root)
}

# The confirm dialog, waited for in either direction.
function Wait-Dialog([int]$gpid, [bool]$appear, [int]$timeoutMs = 3000) {
    if ($appear) { return Wait-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog' -TimeoutMs $timeoutMs }
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 250
            $waited += 250
            continue
        }
        return (Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog')
    }
    return [IntPtr]::Zero
}

# The pane's shell pid, straight from the app. With session-persistence ON this
# is the pid the AGENT reported, which is the half a fix that only knows about
# direct children would get wrong.
function Get-PaneShellPid {
    $json = & $Exe +list --json 2>$null | Out-String
    if (-not $json) { return 0 }
    try { $tree = $json | ConvertFrom-Json } catch { return 0 }
    # {"type":"leaf","terminal":{...}} / {"type":"split","left":...,"right":...}
    $root = if ($tree.PSObject.Properties.Name -contains 'data') { $tree.data } else { $tree }
    foreach ($w in @($root.windows)) {
        foreach ($t in @($w.tabs)) {
            $stack = New-Object System.Collections.Stack
            $stack.Push($t.splits)
            while ($stack.Count -gt 0) {
                $n = $stack.Pop()
                if ($null -eq $n) { continue }
                if ($n.type -eq 'leaf') {
                    if ($n.terminal -and [int]$n.terminal.pid -gt 0) { return [int]$n.terminal.pid }
                } else {
                    if ($n.right) { $stack.Push($n.right) }
                    if ($n.left) { $stack.Push($n.left) }
                }
            }
        }
    }
    return 0
}

function Launch-Gui([string[]]$ExtraArgs) {
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $ExtraArgs
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    Set-TestWindowSize -Window $top -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 400
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

# One section: launch, make the shell busy, confirm the dialog appears, let the
# shell go idle, and close again.
function Invoke-Section([string]$Label, [string[]]$ExtraArgs) {
    Write-Host ""
    Write-Host "== $Label =="

    $g = Launch-Gui $ExtraArgs
    if (-not $g) { Write-Host "SETUP FAIL: $Label GUI did not come up"; $script:fail++; return }
    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) "$Label window is NOT on the interactive desktop"

    $shell = Get-PaneShellPid
    if ($shell -le 0) {
        # Not a product verdict for T41's dialog rule, but the section's whole
        # oracle rests on it - and with persistence ON it is the same code path
        # the fix uses, so say so loudly rather than skipping quietly.
        Write-Host "SETUP FAIL: $Label +list reported no shell pid for the pane"
        $script:fail++
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return
    }
    # The pid must name a LIVE process, or every descendant answer below is a
    # confident zero about nothing - which is exactly how a fix that returns a
    # meaningless pid would look green here.
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$shell" -ErrorAction SilentlyContinue
    Assert ($null -ne $proc) "$Label shell pid $shell names a live process"
    if ($proc) { Write-Host "       shell = $($proc.Name) ppid=$($proc.ParentProcessId)" }

    $idle0 = @(Get-DescendantPids $shell)
    Assert ($idle0.Count -eq 0) "$Label a fresh shell has no descendants (found $($idle0.Count))"

    # ---------------------------------------------------------------- busy
    Send-TestText -Window $g.Top -Target $g.Surface -Text 'ping -n 100 127.0.0.1' | Out-Null
    Send-TestKeys -Window $g.Top -Target $g.Surface -Key Enter | Out-Null
    # @(): a PS 5.1 function's array return UNROLLS, so a single descendant
    # would arrive as a bare object whose .Count is $null.
    $busy = @(Wait-Descendants $shell $true)
    Assert ($busy.Count -gt 0) "$Label ping is running under the shell ($($busy.Count) descendants)"
    if ($busy.Count -eq 0) {
        Write-Host "SETUP FAIL: $Label could not make the shell busy"
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return
    }

    # Same shell pid, read back through the OTHER consumer of it: a process
    # running inside the pane must be able to find its own pane by pid. This is
    # what `/reset-context` uses, and with session-persistence ON it answered
    # "no pane" for years - the app read a pid the agent never had (see B/agent).
    $probe = [int]$busy[0].ProcessId
    $match = (& $Exe +list --pid=$probe 2>$null | Out-String).Trim()
    Assert ($match -and $match.Length -gt 0) "$Label +list --pid finds the pane from a process inside it ('$match')"

    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null
    $dlg = Wait-Dialog $g.Pid $true 5000
    Assert ($dlg -ne [IntPtr]::Zero) "$Label busy shell: ctrl+w opens the confirm dialog"
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        $gone = Wait-Dialog $g.Pid $false
        Assert ($gone -eq [IntPtr]::Zero) "$Label Escape dismisses the busy confirm"
        Assert (Test-TestWindowVisible -Window $g.Top) "$Label window survives the cancelled close"
    }

    # ---------------------------------------------------------------- idle
    # Ctrl+C the ping and wait for the process table to agree it is gone.
    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key C | Out-Null
    $left = @(Wait-Descendants $shell $false)
    Assert ($left.Count -eq 0) "$Label ctrl+c leaves the shell with no descendants (found $($left.Count))"
    if ($left.Count -ne 0) {
        Write-Host "SETUP FAIL: $Label shell never went idle: $(($left | ForEach-Object { $_.Name }) -join ',')"
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return
    }
    Start-Sleep -Milliseconds 500

    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null
    $dlg = Wait-Dialog $g.Pid $true 2500
    $closed = $false
    for ($t = 0; $t -lt 40 -and -not $closed; $t++) {
        Start-Sleep -Milliseconds 100
        $closed = (-not (Test-TestWindowExists -Window $g.Top)) -or (-not (Test-TestWindowVisible -Window $g.Top))
    }

    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: asserting the IDLE close still confirms - this run MUST fail"
        Assert ($dlg -ne [IntPtr]::Zero) "$Label idle shell: ctrl+w opens the confirm dialog (inverted)"
    } else {
        Assert ($dlg -eq [IntPtr]::Zero) "$Label idle shell: ctrl+w opens NO confirm dialog"
    }
    # The chord must have DONE something: no dialog plus an open window is a
    # swallowed keystroke, not a skipped confirmation.
    Assert $closed "$Label idle shell: the last pane closed without confirming"

    if ($dlg -ne [IntPtr]::Zero) { Send-TestControlKey -Control $dlg -Key Escape | Out-Null }
    Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-AgentState
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Invoke-Section 'A/exec' @('--session-persistence=false')
    Stop-RepoProcesses @('ghoztty')
    Reset-AgentState
    Invoke-Section 'B/agent' @('--session-persistence=true')
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    $fgSeen = @(Stop-TestForegroundWatch)
    $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground'
    Remove-TestDesktop $td
}

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass checks)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
