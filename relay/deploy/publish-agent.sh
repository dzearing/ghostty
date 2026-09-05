#!/usr/bin/env bash
# publish-agent.sh — publish the relay VM's download signpost and landing page.
#
# Uploads (idempotent; safe to re-run):
#   install.ps1                  -> /var/www/ghoztty-dl/install.ps1
#   www/index.html               -> /var/www/ghoztty-www/index.html
#
# WHAT IS NO LONGER HERE. This script used to publish a whole second way to get
# Ghoztty onto a Windows box, and it has been dismantled in two steps:
#
#   T1175 removed the standalone Ghoztty-Agent MSI (and its `msi/` directory and
#   stable-URL alias). Windows ships ONE installer, and it carries
#   `ghoztty-agent.exe` as a required sibling of `ghoztty.exe`, so the second
#   installer only ever let a new user end up with half a product.
#
#   T550 removed `ghoztty-agent.exe` and `version.json`. They outlived the MSI
#   only because the agent's own self-updater read them (`GET /dl/version.json`,
#   then swap the exe in place). That code is gone: the agent binary is owned by
#   the Ghoztty install and moves with it, so an agent that could replace itself
#   would be fighting the app's own updater. Nothing reads either file now, and
#   publishing a Windows binary nobody consumes is a download surface with no
#   purpose.
#
# What is left is a SIGNPOST: `install.ps1` keeps the old hosted one-liner
# ANSWERING (it installs nothing and names the product site), and
# `www/index.html` points at the product site. See
# docs/design/one-installer-agent-consolidation.md.
#
# Usage:
#   relay/deploy/publish-agent.sh [--host <ssh-host>] [--if-changed] [--dry-run]
#
# Defaults:
#   host     azureuser@ghoztty-relay-dz17575.westus2.cloudapp.azure.com
#
# --if-changed: skip publishing when nothing that goes into the download site
#   has changed since the currently-DEPLOYED copy. The deployed install.ps1
#   carries the commit it was published from (`# published-from: <hash>`, added
#   here at upload time); this compares that commit to HEAD over SITE_PATHS
#   (below) and exits 0 without uploading when the diff is empty.
#
# Requires: ssh access to the VM as a sudo-capable user. Caddy must already
# route /dl/* and / per relay/deploy/Caddyfile.example.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

HOST="azureuser@ghoztty-relay-dz17575.westus2.cloudapp.azure.com"
DL_DIR="/var/www/ghoztty-dl"
WWW_DIR="/var/www/ghoztty-www"

DRY_RUN=0
IF_CHANGED=0

# Source paths whose changes require re-publishing the download site.
SITE_PATHS=(
  "relay/deploy"               # install.ps1 signpost, website, this script
)

usage() { sed -n '2,42p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)     HOST="${2:?--host needs a value}"; shift 2 ;;
    --host=*)   HOST="${1#*=}"; shift ;;
    --if-changed) IF_CHANGED=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

INSTALL_PS1="$SCRIPT_DIR/install.ps1"
INDEX_HTML="$SCRIPT_DIR/www/index.html"

[[ -f "$INSTALL_PS1" ]] || { echo "error: missing $INSTALL_PS1" >&2; exit 1; }
[[ -f "$INDEX_HTML"  ]] || { echo "error: missing $INDEX_HTML" >&2; exit 1; }

CUR_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

DL_BASE="https://${HOST#*@}/dl"

# --if-changed: compare HEAD to the commit the DEPLOYED signpost was published
# from over SITE_PATHS. Skip when unchanged.
if [[ "$IF_CHANGED" -eq 1 ]]; then
  PREV_PS1="$(curl -fsS "$DL_BASE/install.ps1" 2>/dev/null || true)"
  PREV_COMMIT="$(printf '%s' "$PREV_PS1" | sed -n 's/^#[[:space:]]*published-from:[[:space:]]*\([0-9a-fA-F]*\).*/\1/p' | head -1)"
  if [[ -n "$PREV_COMMIT" ]] && git -C "$REPO_ROOT" cat-file -e "${PREV_COMMIT}^{commit}" 2>/dev/null; then
    if git -C "$REPO_ROOT" diff --quiet "$PREV_COMMIT" HEAD -- "${SITE_PATHS[@]}"; then
      echo "== publish-agent: no site changes since the deployed copy ($PREV_COMMIT); skipping publish. =="
      exit 0
    fi
    echo "== publish-agent: changes since the deployed copy ($PREV_COMMIT):"
    git -C "$REPO_ROOT" diff --name-only "$PREV_COMMIT" HEAD -- "${SITE_PATHS[@]}" | sed 's/^/     /'
  else
    echo "== publish-agent: no resolvable deployed commit (first publish, or a copy predating the stamp); publishing unconditionally. =="
  fi
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ghoztty-publish.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Stamp the signpost with the commit it was published from, so --if-changed has
# something to compare against on the next run.
STAGED_PS1="$STAGE/install.ps1"
{ echo "# published-from: $CUR_COMMIT"; cat "$INSTALL_PS1"; } > "$STAGED_PS1"

echo "== publish-agent =="
echo "   commit   : $CUR_COMMIT"
echo "   host     : $HOST"

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
UPLOADS=("$STAGED_PS1" "$INDEX_HTML")
run ssh "$HOST" "mkdir -p $REMOTE_STAGE"
run scp "${UPLOADS[@]}" "$HOST:$REMOTE_STAGE/"
run ssh "$HOST" "
  set -eu
  sudo install -d -m 755 $DL_DIR $WWW_DIR
  sudo install -m 644 $REMOTE_STAGE/install.ps1        $DL_DIR/install.ps1
  sudo install -m 644 $REMOTE_STAGE/index.html         $WWW_DIR/index.html
  rm -rf $REMOTE_STAGE
"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "OK (dry-run): nothing uploaded."
else
  echo "OK: published the download signpost from $CUR_COMMIT."
  echo "   verify: curl -fsS https://${HOST#*@}/dl/install.ps1 | head -5"
  echo "           curl -fsS https://${HOST#*@}/ | head -5"
fi
