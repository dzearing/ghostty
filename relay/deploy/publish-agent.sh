#!/usr/bin/env bash
# publish-agent.sh — publish the Windows agent binary + download site to the
# relay VM.
#
# Uploads (idempotent; safe to re-run):
#   ghoztty-agent.exe            -> /var/www/ghoztty-dl/ghoztty-agent.exe
#   version.json                 -> /var/www/ghoztty-dl/version.json   (generated here)
#   install.ps1                  -> /var/www/ghoztty-dl/install.ps1
#   www/index.html               -> /var/www/ghoztty-www/index.html
#
# WHAT IS NO LONGER HERE (T1175). This script used to build and publish a
# standalone Ghoztty-Agent MSI, plus a stable-URL alias for it, so a Windows
# box could install the agent on its own. Windows ships ONE installer now and
# it carries `ghoztty-agent.exe` as a required sibling of `ghoztty.exe`, so the
# second installer only ever let a new user end up with half a product. The
# `msi/` directory went with it, `install.ps1` is a signpost that keeps the
# hosted one-liner answering, and `www/index.html` points at the product site.
# See docs/design/one-installer-agent-consolidation.md.
#
# The exe and version.json stay because the standalone `--relay` agent's
# self-updater still reads them (`src/remote/agent/self_update.zig`,
# `GET /dl/version.json`); retiring that code path is T550.
#
# version.json schema (FIXED — shared with the agent updater; do not reorder or
# rename fields without changing self_update.zig in the same commit):
#   {"windows-x86_64": {"version": "20260703-c322788", "commit": "<hash>",
#     "sha256": "<hex>", "path": "/dl/ghoztty-agent.exe"}}
#
# Usage:
#   relay/deploy/publish-agent.sh [path/to/ghoztty-agent.exe]
#                                 [--version <string>] [--host <ssh-host>]
#                                 [--if-changed] [--dry-run]
#
# Defaults:
#   exe      zig-out/bin/ghoztty-agent.exe (relative to the repo root)
#   version  $(date +%Y%m%d)-$(git rev-parse --short HEAD)  — same stamp the
#            agent build embeds, so --version is only needed when publishing
#            a binary built from a different commit than HEAD.
#   host     azureuser@ghoztty-relay-dz17575.westus2.cloudapp.azure.com
#
# --if-changed: skip publishing when nothing that goes into the agent or the
#   download site has changed since the currently-DEPLOYED build. The live
#   version.json records the `commit` it was built from; this compares that
#   commit to HEAD over AGENT_PATHS (below) and exits 0 without uploading when
#   the diff is empty. Over-inclusive on purpose (a needless republish is
#   harmless — self-update is idle-gated — but a missed one ships stale bits).
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
IF_CHANGED=0

# Source paths whose changes require re-publishing the agent + site.
# Deliberately broad (over-inclusion just costs an unnecessary, seamless
# self-update; under-inclusion ships stale bits). Relative to the repo root.
AGENT_PATHS=(
  "src/remote"                 # agent + shared remote protocol/transport code
  "src/build/GhosttyAgent.zig" # agent build + version stamping
  "build.zig"                  # agent build wiring
  "relay/deploy"               # install.ps1 signpost, website, this script
)

usage() { sed -n '2,49p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --host)     HOST="${2:?--host needs a value}"; shift 2 ;;
    --host=*)   HOST="${1#*=}"; shift ;;
    --if-changed) IF_CHANGED=1; shift ;;
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

CUR_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%Y%m%d)-$CUR_COMMIT"
fi

DL_BASE="https://${HOST#*@}/dl"
PREV_JSON="$(curl -fsS "$DL_BASE/version.json" 2>/dev/null || true)"

# --if-changed: compare HEAD to the commit the DEPLOYED agent was built from
# (recorded in the live version.json) over AGENT_PATHS. Skip when unchanged.
if [[ "$IF_CHANGED" -eq 1 ]]; then
  PREV_COMMIT="$(printf '%s' "$PREV_JSON" | sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p')"
  # Fallback for manifests published before the `commit` field existed: parse
  # the trailing hash out of the `YYYYMMDD-<hash>` version string.
  if [[ -z "$PREV_COMMIT" ]]; then
    PREV_COMMIT="$(printf '%s' "$PREV_JSON" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"[0-9]\{8\}-\([0-9a-fA-F]*\)".*/\1/p')"
  fi
  if [[ -n "$PREV_COMMIT" ]] && git -C "$REPO_ROOT" cat-file -e "${PREV_COMMIT}^{commit}" 2>/dev/null; then
    if git -C "$REPO_ROOT" diff --quiet "$PREV_COMMIT" HEAD -- "${AGENT_PATHS[@]}"; then
      echo "== publish-agent: no agent/site changes since deployed build ($PREV_COMMIT); skipping publish. =="
      exit 0
    fi
    echo "== publish-agent: changes since deployed build ($PREV_COMMIT):"
    git -C "$REPO_ROOT" diff --name-only "$PREV_COMMIT" HEAD -- "${AGENT_PATHS[@]}" | sed 's/^/     /'
  else
    echo "== publish-agent: no resolvable deployed commit (first publish, or manifest predates the commit field); publishing unconditionally. =="
  fi
fi

SHA256="$(shasum -a 256 "$EXE" | awk '{print $1}')"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ghoztty-publish.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

VERSION_JSON="$STAGE/version.json"
printf '{"windows-x86_64": {"version": "%s", "commit": "%s", "sha256": "%s", "path": "/dl/ghoztty-agent.exe"}}\n' \
  "$VERSION" "$CUR_COMMIT" "$SHA256" > "$VERSION_JSON"

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
UPLOADS=("$EXE" "$VERSION_JSON" "$INSTALL_PS1" "$INDEX_HTML")
run ssh "$HOST" "mkdir -p $REMOTE_STAGE"
run scp "${UPLOADS[@]}" "$HOST:$REMOTE_STAGE/"
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
  echo "           curl -fsS https://${HOST#*@}/dl/install.ps1 | head -5"
  echo "           curl -fsS https://${HOST#*@}/ | head -5"
fi
