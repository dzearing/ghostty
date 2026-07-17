#!/usr/bin/env bash
# Cut the Azure relay over to brokered OAuth (BFF).
#
# Deploys the new relay binary and adds SESSION_ENC_KEY (generated ON the VM so
# it never transits your laptop or this repo), keeping the existing
# GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / ALLOWED_EMAILS and forcing
# DEV_AUTH=false. The 0007_sessions migration runs automatically on restart.
#
# Run from the repo root on a machine that can SSH to the relay VM:
#   relay/deploy/cutover-brokered-oauth.sh <ssh-user>@ghoztty-relay-dz17575.westus2.cloudapp.azure.com
#
# Rollback: on the VM, restore the printed *.bak.<ts> files and
#   sudo systemctl restart ghoztty-relay
set -euo pipefail

TARGET="${1:?usage: cutover-brokered-oauth.sh <ssh-user>@<host>}"
HOST="${TARGET#*@}"
RELAY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> building relay for linux/amd64 (CGO-free)"
( cd "$RELAY_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/ghoztty-relay.new . )

echo "==> uploading binary to $HOST"
scp /tmp/ghoztty-relay.new "$TARGET:/tmp/ghoztty-relay.new"

echo "==> deploying on $HOST (you may be prompted for your sudo password)"
ssh -t "$TARGET" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
SVC=ghoztty-relay
ENVFILE=/etc/ghoztty-relay.env
BINPATH="$(systemctl show -p ExecStart --value "$SVC" 2>/dev/null | sed -nE 's/.*path=([^ ;]+).*/\1/p')"
: "${BINPATH:=/usr/local/bin/ghoztty-relay}"
echo "   service=$SVC binary=$BINPATH env=$ENVFILE"

ts=$(date +%s)
cp -a "$BINPATH" "${BINPATH}.bak.$ts"
cp -a "$ENVFILE" "${ENVFILE}.bak.$ts"
echo "   backups: ${BINPATH}.bak.$ts  ${ENVFILE}.bak.$ts"

# SESSION_ENC_KEY — generated here, never leaves the box.
if ! grep -q '^SESSION_ENC_KEY=' "$ENVFILE"; then
  printf 'SESSION_ENC_KEY=%s\n' "$(openssl rand -base64 32)" >> "$ENVFILE"
  echo "   added SESSION_ENC_KEY"
else
  echo "   SESSION_ENC_KEY already set (kept)"
fi

# Force DEV_AUTH=false.
if grep -q '^DEV_AUTH=' "$ENVFILE"; then
  sed -i 's/^DEV_AUTH=.*/DEV_AUTH=false/' "$ENVFILE"
else
  echo 'DEV_AUTH=false' >> "$ENVFILE"
fi

# Sanity: the brokered flow needs these (values not printed).
for k in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET ALLOWED_EMAILS; do
  if grep -q "^$k=" "$ENVFILE"; then echo "   $k present"; else echo "   !! $k MISSING — brokered sign-in will answer 503 until it is set"; fi
done

install -m 0755 /tmp/ghoztty-relay.new "$BINPATH"
rm -f /tmp/ghoztty-relay.new
systemctl restart "$SVC"
sleep 2
systemctl is-active "$SVC" >/dev/null && echo "   service active" || { echo "   !! service not active"; journalctl -u "$SVC" -n 30 --no-pager; exit 1; }
echo "   --- recent log ---"
journalctl -u "$SVC" -n 20 --no-pager | grep -Ei 'brokered OAuth|OIDC client auth|listening|level=ERROR' || true
REMOTE

echo "==> external health check"
curl -fsS "https://$HOST/healthz" && echo "  <- healthz OK"
echo "==> cutover complete."
