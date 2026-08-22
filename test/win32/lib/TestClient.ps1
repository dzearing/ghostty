# TestClient.ps1 - T359. Produce `remote-test-client.exe` on demand, so a tree
# that has only ever run the normal build can still run the acceptance scripts
# that drive a real agent.
#
# Dot-source it and resolve once, EARLY - before a script redirects
# %LOCALAPPDATA% or takes an isolated endpoint, because this shells out to zig:
#
#     . (Join-Path $PSScriptRoot 'lib\TestClient.ps1')
#     $ClientExe = Resolve-RemoteTestClient -ClientExe $ClientExe
#     if (-not $ClientExe) { ... }   # the reason was already printed
#
# WHY THIS EXISTS
#
# `remote-test-client` is an ON-DEMAND build target (`build.zig`: its own
# `zig build remote-test-client` step, reachable from nothing the default
# install step builds). Six acceptance scripts need it - it is the only thing
# on the box that speaks the agent protocol without a GUI - and every one of
# them used to open by asserting the file exists. So a clean tree failed them
# with `FAIL remote-test-client exists`, which reads like the agent failed to
# build rather than "this binary was never asked for". Two of those scripts
# (agent-pipe, agent-user-env) then exit 1 on the spot, and their remaining
# ~30 assertions never run.
#
# Building it here rather than adding it to the default install step is
# deliberate: the default build stays lean, and the prerequisite is declared at
# the point of use by the script that actually needs it - the same shape as the
# delivery launcher building its own staging release instead of assuming one.
#
# Debug, always. The scripts around this one drive `zig-out\bin\ghoztty.exe`,
# which lib\BuildMode.ps1 requires to be a Debug build (endpoint isolation,
# T350); a client built any other way would be the odd one out in the same
# zig-out.

# Dot-sourced into the caller's scope, so it inherits the house setting the
# other libs here take: strict mode off (these scripts test on missing/empty
# values constantly and a StrictMode throw would read as a product failure).
Set-StrictMode -Off

# The one command a human would type. Every message that mentions the missing
# binary quotes THIS, so a precondition failure is always actionable.
function Get-RemoteTestClientBuildCommand {
    return 'zig build remote-test-client -Doptimize=Debug'
}

# The repo root, from this file's location (test\win32\lib -> repo).
function Get-RemoteTestClientRepoRoot {
    param([AllowEmptyString()][AllowNull()][string]$Repo = '')
    if ($Repo) { return $Repo }
    return (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent)
}

# Build the client. Returns $true when zig exits 0 AND the exe is on disk.
#
# ZIG_GLOBAL_CACHE_DIR must sit on the repo's drive or zig 0.15.2 asserts
# instead of explaining itself (T243), so it is derived rather than assumed -
# a test shell rarely has it set.
function Invoke-RemoteTestClientBuild {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$ClientExe
    )

    if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
        $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $Repo) '\zig-global-cache')
    }

    $cmd = Get-RemoteTestClientBuildCommand
    Write-Host "  TestClient: remote-test-client is missing; building it ($cmd)..."

    $ok = $false
    Push-Location $Repo
    try {
        # Stringify each record before Out-String: `2>&1` puts ErrorRecords on
        # the pipeline and the formatter is host-dependent (lib\StderrCaptureAudit).
        $out = (& zig build remote-test-client -Doptimize=Debug 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String)
        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok) {
            Write-Host "  TestClient: the build FAILED (zig exit $LASTEXITCODE). Run it by hand: $cmd"
            foreach ($line in ($out -split "`r?`n" | Where-Object { $_ -match 'error' } | Select-Object -Last 10)) {
                Write-Host "    $line"
            }
        }
    } catch {
        Write-Host "  TestClient: the build could not run: $($_.Exception.Message)"
        Write-Host "  TestClient: run it by hand: $cmd"
        $ok = $false
    } finally {
        Pop-Location
    }

    if ($ok -and -not (Test-Path -LiteralPath $ClientExe)) {
        Write-Host "  TestClient: zig exited 0 but $ClientExe still does not exist."
        return $false
    }
    if ($ok) { Write-Host "  TestClient: built $ClientExe" }
    return $ok
}

# Resolve remote-test-client.exe, building it if it is missing.
#
# Returns the full path when the binary is available, or '' when it is not -
# and in that case the reason and the exact build command have already been
# printed, so a caller can fail with a one-line assertion. Callers that must
# not shell out to zig (a hermetic or offline run) pass -NoBuild.
function Resolve-RemoteTestClient {
    param(
        [AllowEmptyString()][AllowNull()][string]$ClientExe = '',
        [AllowEmptyString()][AllowNull()][string]$Repo = '',
        [switch]$NoBuild
    )

    $root = Get-RemoteTestClientRepoRoot -Repo $Repo

    # Candidates in order: what the caller asked for, then this repo's zig-out.
    # The scripts' `-ClientExe` defaults are absolute D:\git\ghoztty paths, so
    # the second candidate is what makes a clone elsewhere work at all.
    $candidates = @()
    if ($ClientExe) { $candidates += $ClientExe }
    $inRepo = Join-Path $root 'zig-out\bin\remote-test-client.exe'
    if ($candidates -notcontains $inRepo) { $candidates += $inRepo }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }

    $target = $inRepo
    if ($NoBuild) {
        Write-Host "  TestClient: remote-test-client.exe not found. Build it with: $(Get-RemoteTestClientBuildCommand)"
        return ''
    }

    if (Invoke-RemoteTestClientBuild -Repo $root -ClientExe $target) { return $target }
    return ''
}
