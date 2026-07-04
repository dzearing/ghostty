#!/usr/bin/env bash
# build-msi.sh — build the per-user Windows MSI for the Ghoztty Remote Agent.
#
# Compiles relay/deploy/msi/ghoztty-agent.wxs with wixl (GNOME msitools) and
# validates the result with msiinfo/msiextract — no Windows box needed.
#
# Usage:
#   relay/deploy/msi/build-msi.sh [path/to/ghoztty-agent.exe]
#                                 [--version <stamp>] [--build-num <N>]
#                                 [--relay <url>] [--out <path>]
#
# Defaults:
#   exe        zig-out/bin/ghoztty-agent.exe (relative to the repo root)
#   version    $(date +%Y%m%d)-$(git rev-parse --short HEAD) — the agent build
#              stamp. Shown in Apps & Features via the MSI Comments/ARPCOMMENTS
#              fields; ARP DisplayVersion itself always mirrors the numeric
#              ProductVersion (an MSI engine rule — it cannot hold this stamp).
#   build-num  1 — same-day rebuild counter (bump when publishing twice in a
#              day: same ProductVersion would refuse to install over itself).
#   relay      https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com
#   out        zig-out/bin/ghoztty-agent.msi
#
# ProductVersion is derived as yy.m.dNN (e.g. 26.7.401 = 2026-07-04 build 01)
# so newer builds always compare greater and MSI major upgrades fire.
#
# Requires: wixl, msiinfo, msiextract (brew install msitools).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
WXS="$SCRIPT_DIR/ghoztty-agent.wxs"

EXE="$REPO_ROOT/zig-out/bin/ghoztty-agent.exe"
OUT="$REPO_ROOT/zig-out/bin/ghoztty-agent.msi"
VERSION=""
BUILD_NUM=1
RELAY_URL="https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com"

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*)   VERSION="${1#*=}"; shift ;;
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

# Numeric ProductVersion yy.m.dNN — strictly increasing day over day, and
# --build-num separates same-day rebuilds. (major<=255 minor<=255 build<=65535.)
YY="$(date +%y)"; M="$(date +%-m)"; D="$(date +%-d)"
MSI_VERSION="$(printf '%d.%d.%d%02d' "$YY" "$M" "$D" "$BUILD_NUM")"

echo "== build-msi =="
echo "   exe          : $EXE ($(du -h "$EXE" | awk '{print $1}'))"
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

# Upgrade table: both the remove-older row and the detect-newer row.
UPGRADE="$(table Upgrade)"
grep -q "OLDERVERSIONFOUND" <<<"$UPGRADE" || fail "Upgrade table lacks OLDERVERSIONFOUND row"
grep -q "NEWERVERSIONFOUND" <<<"$UPGRADE" || fail "Upgrade table lacks NEWERVERSIONFOUND row"
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

# Payload: the exe must extract to Programs/Ghoztty Agent/ghoztty-agent.exe.
XT="$(mktemp -d "${TMPDIR:-/tmp}/ghoztty-msi-xt.XXXXXX")"
trap 'rm -rf "$XT"' EXIT
msiextract -C "$XT" "$OUT" >/dev/null
EXPECT="$XT/Programs/Ghoztty Agent/ghoztty-agent.exe"
[[ -f "$EXPECT" ]] || fail "extracted exe not at Programs/Ghoztty Agent/ghoztty-agent.exe"
cmp -s "$EXE" "$EXPECT" || fail "extracted exe differs from input exe"

echo "OK: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
echo "   ProductVersion : $MSI_VERSION (ARP DisplayVersion)"
echo "   agent stamp    : $VERSION (ARP Comments)"
echo "   per-user       : ALLUSERS unset, MSIINSTALLPERUSER=1, no UAC"
echo "   installs to    : %LOCALAPPDATA%\\Programs\\Ghoztty Agent\\"
echo "   autostart      : HKCU Run \"GhozttyAgent\" --relay=$RELAY_URL"
echo "   validated      : Property/Upgrade/Registry/Shortcut/CustomAction tables + payload extraction"
