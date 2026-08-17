# Boot resilience for the go.md parity loop (tracker T829).
#
# Measured 2026-08-14: the box rebooted at 08:07 on 08-13 and the loop did not
# run again until 09:16 on 08-14. Twenty-five hours, zero tasks closed. The
# supervisor (scripts\go-loop-watchdog.ps1) was not merely asleep - its process
# did not exist, because BOTH of its revival paths are bound to an interactive
# session: the HKCU Run entry fires at sign-in, and the GhozttyGoLoopWatchdog
# scheduled task runs with LogonType=InteractiveToken, which Task Scheduler
# skips outright while nobody is signed in. T440's "the supervisor has its own
# supervision" does not cover the case where the supervisor's whole SESSION is
# gone.
#
# The uncomfortable fact this script is built around: WITHOUT ELEVATION,
# NOTHING CAN RUN ON THIS BOX WHILE NOBODY IS SIGNED IN. Running code in that
# window needs a SYSTEM service, a task registered with S4U or a stored
# password, or a Run-As-batch right - every one of them an admin operation, and
# a GUI loop could not use the result anyway, since Ghoztty and Claude Code need
# a desktop. So the chain that has to hold is:
#
#   1. the box creates an interactive session by itself      <- the broken link
#   2. a session appearing starts the watchdog IMMEDIATELY
#   3. the watchdog re-enters the loop
#
# Link 1 is the user's Windows sign-in setting, not code. Link 2 and link 3 are
# ours. This script therefore does three things and refuses to pretend it can do
# a fourth:
#
#   check   audit every link and say which one is broken, with the fix for it.
#   install harden links 2/3 as far as an ordinary user can: register the
#           watchdog task with an AT LOGON trigger (so revival is instant rather
#           than up to -ReviveMinutes late), clear the battery gates, and lift
#           the execution time limit. Idempotent.
#   record  MEASURE link 1 rather than infer it, once per boot, and shout when
#           it did not hold.
#
# Why measurement instead of reading the registry: the registry cannot answer
# it. This box has Winlogon\AutoLogonSID set to the user's own SID with
# AutoAdminLogon=0 and no ARSO consent value at all - a state that looks
# configured and is not, and that reads identically whether the last restart
# signed in by itself or sat on the lock screen for a day. The only honest
# answer comes from the box's own history:
#
#   boot   = Win32_OperatingSystem.LastBootUpTime
#   logon  = when explorer.exe started in this session
#
# winlogon.exe starts in session 1 at boot whether or not anybody signs in (it
# is what draws the lock screen), so it proves nothing; the SHELL starting is
# exactly "an interactive desktop now exists". On the outage above those two
# numbers are 08-13 08:07:07 and 08-14 09:16:26, which is the 25 hours, read
# straight off the running box.
#
# The known imprecision, stated rather than hidden: if explorer.exe is killed
# and restarts, the oldest one left is the restart, and the gap reads longer
# than it was. That errs toward reporting an outage that was not one, which is
# the safe direction here - a noisy report gets checked, a missed one is the
# disease this task is about.
#
# `record` appends one row per boot to a ledger (temp\go-loop-boots.jsonl,
# beside the lock) and is idempotent on the boot timestamp, so `claim` can call
# it every turn and the loud block is printed once per reboot rather than once
# per turn. go.md step 0 prints whatever it emits - that is the "loud signal
# instead of silence" this task asked for. It cannot be a signal DURING the
# outage, because during the outage there is no process to send one; it is the
# first thing anyone sees when the loop comes back, and it is a number rather
# than a memory.
#
#   powershell -NoProfile -File scripts\go-loop-boot.ps1 check
#   powershell -NoProfile -File scripts\go-loop-boot.ps1 install
#   powershell -NoProfile -File scripts\go-loop-boot.ps1 record
#
# Exit codes (check): 0 every link this box can hold is holding; 1 a link needs
# a one-time human action (unattended sign-in); 2 a link is broken and
# `install` fixes it here.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'install', 'record', 'uninstall')]
    [string]$Action = 'check',

    [string]$Repo,
    [string]$LedgerPath,
    [string]$WatchdogScript,
    [string]$TaskName = 'GhozttyGoLoopWatchdog',
    [int]$ReviveMinutes = 10,

    # A session that appeared within this long after boot was not waiting for a
    # human. Generous on purpose: ARSO signs in after the update finishes
    # applying, which can take minutes, and a false "a human had to help" is a
    # worse error here than a late true one.
    [int]$UnattendedMinutes = 5,
    # A sign-in gap longer than this is reported as a BOOT OUTAGE rather than a
    # quiet line.
    [int]$OutageMinutes = 30,
    # A record written more than this long after the session started is a
    # BACKFILL - the ledger only learned about that boot later (a fresh
    # checkout, or the first run after this script shipped). Its sign-in gap is
    # still real; its claim lag is not a measurement of the loop, and is marked.
    [int]$FreshMinutes = 60,

    # Test seams. The acceptance harness drives the classifier with known times
    # instead of rebooting the box.
    [datetime]$BootTime,
    [datetime]$LogonTime,
    [switch]$Json,
    [switch]$Quiet          # record: write the ledger, print nothing
)

$ErrorActionPreference = 'Continue'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $LedgerPath) { $LedgerPath = Join-Path (Join-Path $Repo 'temp') 'go-loop-boots.jsonl' }
if (-not $WatchdogScript) { $WatchdogScript = Join-Path $PSScriptRoot 'go-loop-watchdog.ps1' }
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# Captured HERE, not inside the getters: $PSBoundParameters is per-scope, so a
# function asking it about a SCRIPT parameter always gets "no" and every test
# seam would silently fall through to the live box.
$script:HasBootTime = $PSBoundParameters.ContainsKey('BootTime')
$script:HasLogonTime = $PSBoundParameters.ContainsKey('LogonTime')

# The one-time human action that closes link 1. Printed by `check` and by the
# outage block, because a diagnosis nobody can act on is just a nicer silence.
# It is deliberately the SETTINGS path and not a registry write: the consent
# lives in HKLM (an admin write), the Settings toggle brokers it for an ordinary
# user, and turning on a machine's automatic sign-in is the owner's call to make
# knowingly, not something a loop script should do to somebody's desktop.
$SignInFix = @(
    'fix: Settings > Accounts > Sign-in options > "Use my sign-in info to automatically',
    '     finish setting up my device after an update or restart"  ->  On',
    '     (no admin needed; covers the Windows Update restarts that caused this)'
)

function Fmt-Span([double]$minutes) {
    if ([double]::IsNaN($minutes) -or [double]::IsInfinity($minutes)) { return 'unknown' }
    if ($minutes -lt 1) { return '{0:N0}s' -f ($minutes * 60) }
    if ($minutes -lt 60) { return '{0:N0}m' -f $minutes }
    $h = [math]::Floor($minutes / 60)
    $m = [math]::Round($minutes - ($h * 60))
    if ($h -lt 24) { return "${h}h ${m}m" }
    $d = [math]::Floor($h / 24)
    return "${d}d $($h - $d * 24)h ${m}m"
}

# --- the two facts ---------------------------------------------------------

function Get-BootTime {
    if ($script:HasBootTime) { return $BootTime }
    try { return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { return $null }
}

# "An interactive desktop exists" = the shell is running in THIS session. Not
# winlogon.exe, which starts at boot to draw the lock screen and would report
# every unattended reboot as a successful sign-in.
function Get-LogonTime {
    if ($script:HasLogonTime) { return $LogonTime }
    try {
        $sid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).SessionId
        $shells = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            Where-Object { $_.SessionId -eq $sid } | ForEach-Object { $_.CreationDate })
        if ($shells.Count -eq 0) { return $null }
        return ($shells | Sort-Object)[0]
    } catch { return $null }
}

# --- the ledger ------------------------------------------------------------

function Read-Ledger {
    if (-not (Test-Path -LiteralPath $LedgerPath)) { return @() }
    $rows = @()
    foreach ($line in @(Get-Content -LiteralPath $LedgerPath -ErrorAction SilentlyContinue)) {
        if (-not $line.Trim()) { continue }
        try { $rows += ($line | ConvertFrom-Json) } catch { }
    }
    return $rows
}

function Add-LedgerRow($row) {
    $dir = Split-Path -Parent $LedgerPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    ($row | ConvertTo-Json -Depth 4 -Compress) | Add-Content -LiteralPath $LedgerPath -Encoding utf8
}

# One row per boot. The key is the boot timestamp to the second: two records for
# one boot would double-count the downtime and re-print the loud block forever.
function Get-BootKey($t) {
    if (-not $t) { return '' }
    return ([datetime]$t).ToString('yyyy-MM-ddTHH:mm:ss')
}

# --- the scheduled task ----------------------------------------------------

function Get-ReviveTask {
    try { return (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) } catch { return $null }
}

function Get-TaskFacts($task) {
    $f = [ordered]@{
        present     = $false
        enabled     = $false
        atLogon     = $false
        repeats     = $false
        batteryGate = $true
        timeLimited = $true
        whenAvail   = $false
    }
    if (-not $task) { return $f }
    $f.present = $true
    $f.enabled = ($task.State -ne 'Disabled')
    foreach ($t in @($task.Triggers)) {
        $cls = ''
        if ($t.CimClass) { $cls = [string]$t.CimClass.CimClassName }
        if ($cls -eq 'MSFT_TaskLogonTrigger') { $f.atLogon = $true }
        if ($t.Repetition -and $t.Repetition.Interval) { $f.repeats = $true }
    }
    $s = $task.Settings
    if ($s) {
        $f.batteryGate = ([bool]$s.DisallowStartIfOnBatteries -or [bool]$s.StopIfGoingOnBatteries)
        $lim = [string]$s.ExecutionTimeLimit
        $f.timeLimited = -not ($lim -eq '' -or $lim -eq 'PT0S')
        $f.whenAvail = [bool]$s.StartWhenAvailable
    }
    return $f
}

# The task shape link 2 needs, in one place so `install` and the watchdog's own
# -Install cannot drift apart. Two triggers, not one: AT LOGON makes revival
# immediate the moment a session exists (including one Windows created by
# itself), and the repetition is the every-N-minutes crash net T440 added. The
# battery flags are Task Scheduler's defaults and are wrong for a supervisor -
# a laptop on battery would simply never revive - and the absent
# ExecutionTimeLimit defaults to 72 hours, which silently kills the watchdog
# process the task itself started.
function Install-ReviveTask {
    $cmd = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatchdogScript`" -Repo `"$Repo`""
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $cmd
    $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
    # A start boundary in the past with a repetition interval is the supported
    # way to say "every N minutes, forever, starting now".
    $every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(-1) `
        -RepetitionInterval (New-TimeSpan -Minutes $ReviveMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atLogon, $every) `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
}

# --- actions ---------------------------------------------------------------

if ($Action -eq 'install') {
    try {
        Install-ReviveTask
        "INSTALLED $TaskName (at logon + every ${ReviveMinutes}m, no battery gate, no time limit)"
    } catch {
        "ERROR could not register $TaskName : $($_.Exception.Message)"
        exit 2
    }
    $f = Get-TaskFacts (Get-ReviveTask)
    # Read it back. A Register-ScheduledTask that returns without throwing and
    # leaves a trigger off is exactly the shape of failure this project keeps
    # paying for elsewhere (see the delivery verifier).
    if (-not $f.atLogon) { '  WARNING the at-logon trigger did not stick'; exit 2 }
    "  verified: atLogon=$($f.atLogon) repeats=$($f.repeats) batteryGate=$($f.batteryGate) timeLimited=$($f.timeLimited)"
    exit 0
}

if ($Action -eq 'uninstall') {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; "UNINSTALLED $TaskName" }
    catch { "no task $TaskName to remove" }
    exit 0
}

$boot = Get-BootTime
$logon = Get-LogonTime
$signIn = [double]::NaN
if ($boot -and $logon) { $signIn = ([datetime]$logon - [datetime]$boot).TotalMinutes }
$unattended = ((-not [double]::IsNaN($signIn)) -and $signIn -le $UnattendedMinutes)

if ($Action -eq 'record') {
    $key = Get-BootKey $boot
    if (-not $key) { if (-not $Quiet) { '  (boot record skipped: LastBootUpTime unavailable)' }; exit 0 }
    $seen = @(Read-Ledger | Where-Object { $_.boot -eq $key })
    if ($seen.Count -gt 0) { exit 0 }      # already recorded: silent by design

    $now = Get-Date
    $claimLag = [double]::NaN
    if ($logon) { $claimLag = ($now - [datetime]$logon).TotalMinutes }
    $backfilled = ((-not [double]::IsNaN($claimLag)) -and $claimLag -gt $FreshMinutes)

    Add-LedgerRow ([ordered]@{
        boot        = $key
        logon       = if ($logon) { ([datetime]$logon).ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
        signInMin   = if ([double]::IsNaN($signIn)) { $null } else { [math]::Round($signIn, 1) }
        unattended  = $unattended
        claimLagMin = if ([double]::IsNaN($claimLag)) { $null } else { [math]::Round($claimLag, 1) }
        backfilled  = $backfilled
        recordedAt  = $now.ToString('o')
    })

    if ($Quiet) { exit 0 }
    if ([double]::IsNaN($signIn)) {
        "  boot $key recorded (sign-in time unknown)"
        exit 0
    }
    if ($unattended) {
        "  boot ${key}: the box signed in by itself after $(Fmt-Span $signIn) - the loop revived unattended"
        exit 0
    }
    "  BOOT OUTAGE: the box rebooted $key and no desktop existed for $(Fmt-Span $signIn) - the loop"
    "    could not run at all in that window; it waited for a human to sign in."
    if ($backfilled) { "    (first record for this boot, written $(Fmt-Span $claimLag) after sign-in)" }
    foreach ($l in $SignInFix) { "    $l" }
    '    detail: powershell -NoProfile -File scripts\go-loop-boot.ps1 check'
    exit 0
}

# --- check -----------------------------------------------------------------

$task = Get-ReviveTask
$tf = Get-TaskFacts $task
$runEntry = [bool](Get-ItemProperty -Path $runKey -Name $TaskName -ErrorAction SilentlyContinue)

$dogRunning = $false
try {
    $m = New-Object System.Threading.Mutex($false, 'Global\GhozttyGoLoopWatchdog')
    try { if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $dogRunning = $true } } finally { $m.Dispose() }
} catch { }

$ledger = @(Read-Ledger)
$outages = @($ledger | Where-Object { $_.unattended -eq $false -and $null -ne $_.signInMin })
$lostMin = 0.0
foreach ($o in $outages) { $lostMin += [double]$o.signInMin }

# Link 1's verdict comes from the ledger when it has ever seen a boot, and from
# THIS boot otherwise. Never from the registry: see the header.
$link1 = 'unknown'
if ($ledger.Count -gt 0) {
    $last = $ledger[-1]
    if ($last.unattended -eq $true) { $link1 = 'unattended' }
    elseif ($null -ne $last.signInMin) { $link1 = 'waited-for-human' }
} elseif (-not [double]::IsNaN($signIn)) {
    $link1 = if ($unattended) { 'unattended' } else { 'waited-for-human' }
}

$broken = @()      # fixable here, by `install`
$needsHuman = @()  # the one-time Windows setting

if (-not $tf.present) { $broken += "the revive task $TaskName is not registered" }
else {
    if (-not $tf.enabled) { $broken += "the revive task $TaskName is disabled" }
    if (-not $tf.atLogon) { $broken += 'the revive task has no AT LOGON trigger: revival waits up to ' + $ReviveMinutes + 'm after a session appears' }
    if (-not $tf.repeats) { $broken += 'the revive task does not repeat: a watchdog that dies stays dead' }
    if ($tf.batteryGate) { $broken += 'the revive task is battery-gated: on battery it never starts' }
    if ($tf.timeLimited) { $broken += 'the revive task has an execution time limit: it kills the watchdog it started' }
}
if (-not $runEntry) { $broken += "the HKCU Run entry $TaskName is missing (watchdog -Install adds it)" }
if ($link1 -ne 'unattended') {
    $needsHuman += 'the box does not sign in by itself after a restart, so a reboot with nobody at the keyboard stops the loop until somebody arrives'
}

$verdict = 'ok'
$code = 0
if ($link1 -ne 'unattended') { $verdict = 'needs-human'; $code = 1 }
if ($broken.Count -gt 0) { $verdict = 'broken'; $code = 2 }

if ($Json) {
    [ordered]@{
        verdict        = $verdict
        boot           = Get-BootKey $boot
        logon          = if ($logon) { ([datetime]$logon).ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
        sign_in_minutes = if ([double]::IsNaN($signIn)) { $null } else { [math]::Round($signIn, 1) }
        unattended_signin = $unattended
        link1          = $link1
        task           = $tf
        run_entry      = $runEntry
        watchdog       = $dogRunning
        boots_recorded = $ledger.Count
        outages        = $outages.Count
        lost_minutes   = [math]::Round($lostMin, 1)
        broken         = $broken
        needs_human    = $needsHuman
    } | ConvertTo-Json -Depth 5
    exit $code
}

"BOOT REVIVAL $($verdict.ToUpper())"
"  1. session after a reboot : $link1$(if (-not [double]::IsNaN($signIn)) { "  (this boot: desktop $(Fmt-Span $signIn) after power-on)" })"
"  2. starts at logon        : $(if ($tf.atLogon) { 'yes' } else { 'NO - up to ' + $ReviveMinutes + 'm late' })  |  repeats: $(if ($tf.repeats) { "every ${ReviveMinutes}m" } else { 'NO' })  |  run entry: $(if ($runEntry) { 'present' } else { 'MISSING' })"
"  3. watchdog running       : $dogRunning"
"  history: $($ledger.Count) boot(s) recorded, $($outages.Count) with no unattended sign-in, $(Fmt-Span $lostMin) of loop downtime"
foreach ($b in $broken) { "  BROKEN  $b" }
if ($broken.Count -gt 0) { '  fix: powershell -NoProfile -File scripts\go-loop-boot.ps1 install' }
foreach ($n in $needsHuman) { "  NEEDS A HUMAN  $n" }
if ($needsHuman.Count -gt 0) { foreach ($l in $SignInFix) { "  $l" } }
exit $code
