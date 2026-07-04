#!/usr/bin/env bash
# publish-agent.sh — publish the Windows agent + download site to the relay VM.
#
# Uploads (idempotent; safe to re-run):
#   ghoztty-agent.exe  -> /var/www/ghoztty-dl/ghoztty-agent.exe
#   version.json       -> /var/www/ghoztty-dl/version.json   (generated here)
#   install.ps1        -> /var/www/ghoztty-dl/install.ps1
#   www/index.html     -> /var/www/ghoztty-www/index.html
#
# version.json schema (consumed by the landing pages and the agent updater):
#   {"windows-x86_64": {"version": "20260703-c322788", "sha256": "<hex>", "path": "/dl/ghoztty-agent.exe"}}
#
# Usage:
#   relay/deploy/publish-agent.sh [path/to/ghoztty-agent.exe]
#                                 [--version <string>] [--host <ssh-host>] [--dry-run]
#
# Defaults:
#   exe      zig-out/bin/ghoztty-agent.exe (relative to the repo root)
#   version  $(date +%Y%m%d)-$(git rev-parse --short HEAD)  — same stamp the
#            agent build embeds, so --version is only needed when publishing
#            a binary built from a different commit than HEAD.
#   host     azureuser@ghoztty-relay-dz17575.westus2.cloudapp.azure.com
#
# Requires: ssh access to the VM as a sudo-capable user. Caddy must already
# route /dl/* and / per relay/deploy/Caddyfile.example.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

HOST="azureuser@ghoztty-relay-dz17575.westus2.cloudapp.azure.com"
DL_DIR="/var/www/ghoztty-dl"
WWW_DIR="/var/www/ghoztty-www"

EXE="$REPO_ROOT/zig-out/bin/ghoztty-agent.exe"
VERSION=""
DRY_RUN=0

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --host)     HOST="${2:?--host needs a value}"; shift 2 ;;
    --host=*)   HOST="${1#*=}"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)          EXE="$1"; shift ;;
  esac
done

INSTALL_PS1="$SCRIPT_DIR/install.ps1"
INDEX_HTML="$SCRIPT_DIR/www/index.html"

[[ -f "$EXE" && -s "$EXE" ]] || { echo "error: agent exe not found or empty: $EXE" >&2; exit 1; }
[[ -f "$INSTALL_PS1" ]] || { echo "error: missing $INSTALL_PS1" >&2; exit 1; }
[[ -f "$INDEX_HTML"  ]] || { echo "error: missing $INDEX_HTML" >&2; exit 1; }

if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%Y%m%d)-$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
fi

SHA256="$(shasum -a 256 "$EXE" | awk '{print $1}')"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ghoztty-publish.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
VERSION_JSON="$STAGE/version.json"
printf '{"windows-x86_64": {"version": "%s", "sha256": "%s", "path": "/dl/ghoztty-agent.exe"}}\n' \
  "$VERSION" "$SHA256" > "$VERSION_JSON"

echo "== publish-agent =="
echo "   exe      : $EXE ($(du -h "$EXE" | awk '{print $1}'))"
echo "   version  : $VERSION"
echo "   sha256   : $SHA256"
echo "   host     : $HOST"
echo "   manifest : $(cat "$VERSION_JSON")"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "   dry-run  : $*"
  else
    echo "   run      : $*"
    "$@"
  fi
}

# Stage on the VM under a unique dir, then sudo-install into place (atomic
# enough for our purposes: `install` replaces each file in one step).
REMOTE_STAGE="ghoztty-publish.$$"
run ssh "$HOST" "mkdir -p $REMOTE_STAGE"
run scp "$EXE" "$VERSION_JSON" "$INSTALL_PS1" "$INDEX_HTML" "$HOST:$REMOTE_STAGE/"
run ssh "$HOST" "
  set -eu
  sudo install -d -m 755 $DL_DIR $WWW_DIR
  sudo install -m 644 $REMOTE_STAGE/$(basename "$EXE") $DL_DIR/ghoztty-agent.exe
  sudo install -m 644 $REMOTE_STAGE/version.json       $DL_DIR/version.json
  sudo install -m 644 $REMOTE_STAGE/install.ps1        $DL_DIR/install.ps1
  sudo install -m 644 $REMOTE_STAGE/index.html         $WWW_DIR/index.html
  rm -rf $REMOTE_STAGE
"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "OK (dry-run): nothing uploaded. version.json rendered above."
else
  echo "OK: published agent $VERSION."
  echo "   verify: curl -fsS https://${HOST#*@}/dl/version.json"
  echo "           curl -fsSI https://${HOST#*@}/dl/ghoztty-agent.exe | head -5"
  echo "           curl -fsS https://${HOST#*@}/ | head -5"
fi
