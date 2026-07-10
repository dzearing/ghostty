#!/usr/bin/env bash
# build-msi.sh — build the per-user Windows MSI for the Ghoztty Remote Agent.
#
# Compiles relay/deploy/msi/ghoztty-agent.wxs with wixl (GNOME msitools) and
# validates the result with msiinfo/msiextract — no Windows box needed.
#
# Usage:
#   relay/deploy/msi/build-msi.sh [path/to/ghoztty-agent.exe]
#                                 [--semver <X.Y.Z>] [--version <stamp>]
#                                 [--build-num <N>] [--relay <url>]
#                                 [--out <path>]
#
# Defaults:
#   exe        zig-out/bin/ghoztty-agent.exe (relative to the repo root)
#   semver     latest git tag (v stripped) — the release version, SAME as the
#              DMG of that release. Drives the output filename
#              (Ghoztty-Agent-<semver>-x64.msi) and ProductVersion.
#   version    $(date +%Y%m%d)-$(git rev-parse --short HEAD) — the agent build
#              stamp. Shown in Apps & Features via the MSI Comments/ARPCOMMENTS
#              fields.
#   build-num  1 — republish counter for the SAME semver (agent-only publishes
#              between releases). Appears in the filename when >1
#              (Ghoztty-Agent-<semver>.N-x64.msi).
#   relay      https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com
#   out        zig-out/bin/Ghoztty-Agent-<semver>[.N]-x64.msi
#
# ProductVersion is derived as X.Y.(Z*100+NN) (e.g. v1.11.0 build 1 → 1.11.1,
# build 2 → 1.11.2; v1.11.1 build 1 → 1.11.101) so ARP DisplayVersion reads as
# the release semver while successive publishes still compare greater. The
# WXS upgrade table replaces ANY installed version regardless (see there for
# why: the pre-semver date scheme compares greater than every semver).
#
# Requires: wixl, msiinfo, msiextract (brew install msitools).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
WXS="$SCRIPT_DIR/ghoztty-agent.wxs"

EXE="$REPO_ROOT/zig-out/bin/ghoztty-agent.exe"
OUT=""
VERSION=""
SEMVER=""
BUILD_NUM=1
RELAY_URL="https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com"

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*)   VERSION="${1#*=}"; shift ;;
    --semver)      SEMVER="${2:?--semver needs a value}"; shift 2 ;;
    --semver=*)    SEMVER="${1#*=}"; shift ;;
    --build-num)   BUILD_NUM="${2:?--build-num needs a value}"; shift 2 ;;
    --build-num=*) BUILD_NUM="${1#*=}"; shift ;;
    --relay)       RELAY_URL="${2:?--relay needs a value}"; shift 2 ;;
    --relay=*)     RELAY_URL="${1#*=}"; shift ;;
    --out)         OUT="${2:?--out needs a value}"; shift 2 ;;
    --out=*)       OUT="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)             EXE="$1"; shift ;;
  esac
done

for tool in wixl msiinfo msiextract; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (brew install msitools)" >&2; exit 1; }
done
[[ -f "$EXE" && -s "$EXE" ]] || { echo "error: agent exe not found or empty: $EXE" >&2; exit 1; }
[[ -f "$WXS" ]] || { echo "error: missing $WXS" >&2; exit 1; }
[[ "$BUILD_NUM" =~ ^[0-9]{1,2}$ && "$BUILD_NUM" -ge 1 ]] \
  || { echo "error: --build-num must be 1..99, got: $BUILD_NUM" >&2; exit 1; }

if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%Y%m%d)-$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
fi

# Release semver: the latest tag, same version the DMG of this release wears.
if [[ -z "$SEMVER" ]]; then
  SEMVER="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
  SEMVER="${SEMVER#v}"
fi
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "error: semver must be X.Y.Z (got: '$SEMVER'); pass --semver or tag the repo" >&2; exit 1; }
IFS=. read -r SV_MAJOR SV_MINOR SV_PATCH <<<"$SEMVER"

# Numeric ProductVersion X.Y.(Z*100+NN): DisplayVersion reads as the release
# semver, successive publishes of the same semver still compare greater.
# (major<=255 minor<=255 build<=65535 → patch<=654 — plenty.)
MSI_VERSION="$(printf '%d.%d.%d' "$SV_MAJOR" "$SV_MINOR" $((SV_PATCH * 100 + BUILD_NUM)))"

# DMG-style artifact name: Ghoztty-Agent-<semver>-x64.msi, with the republish
# counter visible when >1 (same bits ≠ same name).
MSI_BASENAME="Ghoztty-Agent-$SEMVER-x64.msi"
[[ "$BUILD_NUM" -gt 1 ]] && MSI_BASENAME="Ghoztty-Agent-$SEMVER.$BUILD_NUM-x64.msi"
[[ -z "$OUT" ]] && OUT="$REPO_ROOT/zig-out/bin/$MSI_BASENAME"

echo "== build-msi =="
echo "   exe          : $EXE ($(du -h "$EXE" | awk '{print $1}'))"
echo "   semver       : $SEMVER (build-num $BUILD_NUM)"
echo "   agent stamp  : $VERSION"
echo "   msi version  : $MSI_VERSION"
echo "   relay url    : $RELAY_URL"
echo "   out          : $OUT"

mkdir -p "$(dirname "$OUT")"
wixl -a x64 \
  -D "Version=$MSI_VERSION" \
  -D "AgentStamp=$VERSION" \
  -D "RelayUrl=$RELAY_URL" \
  -D "SourceExe=$EXE" \
  -o "$OUT" "$WXS"
[[ -s "$OUT" ]] || { echo "error: wixl produced no output" >&2; exit 1; }

# --- Validation: prove the MSI actually says what we intended. -------------
fail() { echo "VALIDATION FAILED: $*" >&2; exit 1; }
table() { msiinfo export "$OUT" "$1" | tr -d '\r'; }  # msiinfo emits CRLF

# Per-user: ALLUSERS must be absent, MSIINSTALLPERUSER=1 present, and the
# summary-info word count must carry bit 8 ("elevated privileges not required").
PROPS="$(table Property)"
grep -q $'^ALLUSERS\t' <<<"$PROPS" && fail "ALLUSERS set — MSI is not per-user"
grep -q $'^MSIINSTALLPERUSER\t1$' <<<"$PROPS" || fail "MSIINSTALLPERUSER=1 missing"
grep -q $'^ProductVersion\t'"$MSI_VERSION"'$' <<<"$PROPS" || fail "ProductVersion != $MSI_VERSION"
WORDCOUNT="$(msiinfo suminfo "$OUT" | awk '/^Source: /{print $2}')"
(( WORDCOUNT & 8 )) || fail "summary word count $WORDCOUNT lacks bit 8 (would trigger UAC)"

# Upgrade table: one replace-ANY-installed-version row (covers the date-scheme
# → semver ProductVersion transition; see the .wxs), and no downgrade block.
UPGRADE="$(table Upgrade)"
grep -q $'\t255.255.65535\t.*EXISTINGVERSIONFOUND' <<<"$UPGRADE" \
  || fail "Upgrade table lacks the replace-any EXISTINGVERSIONFOUND row"
grep -q "NEWERVERSIONFOUND" <<<"$UPGRADE" && fail "downgrade-block row present — semver MSIs would be rejected on date-versioned installs"
grep -q $'^RemoveExistingProducts\t' < <(table InstallExecuteSequence) \
  || fail "RemoveExistingProducts not scheduled"

# HKCU Run key with the relay URL baked in.
grep -q $'\t1\tSoftware\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run\tGhozttyAgent\t"\[INSTALLDIR\]ghoztty-agent.exe" --relay='"$RELAY_URL"'\t' < <(table Registry) \
  || fail "HKCU Run key row missing or wrong"

# Start Menu shortcut with the same command line.
grep -q $'^AgentStartMenuShortcut\tProgramMenuFolder\tGhoztty Agent\t.*\t\[INSTALLDIR\]ghoztty-agent.exe\t--relay='"$RELAY_URL"'\t' < <(table Shortcut) \
  || fail "Start Menu shortcut row missing or wrong"

# taskkill custom action (type 51 sets the path, type 50+ignore runs it)
# sequenced before InstallValidate.
CA="$(table CustomAction)"
grep -q $'^SetKillAgentCmd\t51\tKILLAGENTCMD\t\[SystemFolder\]taskkill.exe' <<<"$CA" || fail "SetKillAgentCmd CA missing"
grep -q $'^KillAgent\t114\tKILLAGENTCMD\t/F /IM ghoztty-agent.exe' <<<"$CA" || fail "KillAgent CA missing"
SEQ="$(table InstallExecuteSequence)"
KILL_SEQ="$(awk -F'\t' '$1=="KillAgent"{print $3}' <<<"$SEQ")"
VALIDATE_SEQ="$(awk -F'\t' '$1=="InstallValidate"{print $3}' <<<"$SEQ")"
[[ -n "$KILL_SEQ" && -n "$VALIDATE_SEQ" && "$KILL_SEQ" -lt "$VALIDATE_SEQ" ]] \
  || fail "KillAgent ($KILL_SEQ) not sequenced before InstallValidate ($VALIDATE_SEQ)"

# Legacy install.ps1 cleanup (powershell, type 50+ignore) BEFORE KillAgent —
# the watchdog must die before the agent kill or it respawns the old exe.
grep -q $'^SetLegacyCleanupCmd\t51\tLEGACYCLEANUPCMD\t\[SystemFolder\]WindowsPowerShell' <<<"$CA" || fail "SetLegacyCleanupCmd CA missing"
grep -q $'^LegacyCleanup\t114\tLEGACYCLEANUPCMD\t' <<<"$CA" || fail "LegacyCleanup CA missing or wrong type (want 114 = exe-by-property + continue)"
grep -q "schtasks /Delete /TN GhozttyAgent /F" <<<"$CA" || fail "LegacyCleanup does not delete the legacy scheduled task"
grep -q "launcher.pid" <<<"$CA" || fail "LegacyCleanup does not kill the legacy watchdog"
# wixl's preprocessor eats bare '$' ('$$' escapes it); a mangled command would
# still "run" and silently do nothing. Prove the PowerShell survived intact.
grep -qF '$d=Join-Path $env:LOCALAPPDATA' <<<"$CA" || fail "LegacyCleanup PowerShell mangled (\$ stripped by wixl preprocessor?)"
awk -F'\t' '$1=="LegacyCleanup"{print $4}' <<<"$CA" | grep -q '\[' \
  && fail "LegacyCleanup command contains '[' — MSI Formatted would substitute it as a property"
LEGACY_SEQ="$(awk -F'\t' '$1=="LegacyCleanup"{print $3}' <<<"$SEQ")"
LEGACY_COND="$(awk -F'\t' '$1=="LegacyCleanup"{print $2}' <<<"$SEQ")"
[[ -n "$LEGACY_SEQ" && "$LEGACY_SEQ" -lt "$KILL_SEQ" ]] \
  || fail "LegacyCleanup ($LEGACY_SEQ) not sequenced before KillAgent ($KILL_SEQ)"
[[ "$LEGACY_COND" == "NOT REMOVE" ]] || fail "LegacyCleanup condition != 'NOT REMOVE' (got: '$LEGACY_COND')"

# Launch-after-install (type 50 + async-no-wait = 242) AFTER InstallFinalize,
# skipped on uninstall via NOT Installed.
grep -q $'^SetLaunchAgentCmd\t51\tLAUNCHAGENTCMD\t\[INSTALLDIR\]ghoztty-agent.exe' <<<"$CA" || fail "SetLaunchAgentCmd CA missing"
grep -q $'^LaunchAgent\t242\tLAUNCHAGENTCMD\t--relay='"$RELAY_URL" <<<"$CA" || fail "LaunchAgent CA missing or not asyncNoWait (want type 242)"
LAUNCH_SEQ="$(awk -F'\t' '$1=="LaunchAgent"{print $3}' <<<"$SEQ")"
LAUNCH_COND="$(awk -F'\t' '$1=="LaunchAgent"{print $2}' <<<"$SEQ")"
FINALIZE_SEQ="$(awk -F'\t' '$1=="InstallFinalize"{print $3}' <<<"$SEQ")"
[[ -n "$LAUNCH_SEQ" && -n "$FINALIZE_SEQ" && "$LAUNCH_SEQ" -gt "$FINALIZE_SEQ" ]] \
  || fail "LaunchAgent ($LAUNCH_SEQ) not sequenced after InstallFinalize ($FINALIZE_SEQ)"
[[ "$LAUNCH_COND" == "NOT Installed" ]] || fail "LaunchAgent condition != 'NOT Installed' (got: '$LAUNCH_COND')"

# Payload: the exe must extract to Programs/Ghoztty Agent/ghoztty-agent.exe.
XT="$(mktemp -d "${TMPDIR:-/tmp}/ghoztty-msi-xt.XXXXXX")"
trap 'rm -rf "$XT"' EXIT
msiextract -C "$XT" "$OUT" >/dev/null
EXPECT="$XT/Programs/Ghoztty Agent/ghoztty-agent.exe"
[[ -f "$EXPECT" ]] || fail "extracted exe not at Programs/Ghoztty Agent/ghoztty-agent.exe"
cmp -s "$EXE" "$EXPECT" || fail "extracted exe differs from input exe"

echo "OK: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
echo "   release semver : $SEMVER (filename + ARP DisplayVersion base)"
echo "   ProductVersion : $MSI_VERSION"
echo "   agent stamp    : $VERSION (ARP Comments)"
echo "   per-user       : ALLUSERS unset, MSIINSTALLPERUSER=1, no UAC"
echo "   installs to    : %LOCALAPPDATA%\\Programs\\Ghoztty Agent\\"
echo "   autostart      : HKCU Run \"GhozttyAgent\" --relay=$RELAY_URL"
echo "   post-install   : launches the agent (asyncNoWait); legacy install.ps1 layout retired"
echo "   validated      : Property/Upgrade/Registry/Shortcut/CustomAction tables + payload extraction"
