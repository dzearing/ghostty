#!/usr/bin/env bash
#
# Integration tests for IPC single-instance enforcement.
#
# Tests that CLI commands fail hard (exit 1) when no Ghoztty instance is
# running, instead of silently becoming a second window manager (exit 200).
# Also tests the sentinel file mechanism and retry-based recovery.
#
# Usage:
#   ./test/ipc-single-instance.sh [path-to-ghoztty-binary]
#
# If no binary path is given, defaults to the debug app bundle binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOZTTY="${1:-$REPO_DIR/zig-out/Ghoztty-Debug.app/Contents/MacOS/ghoztty}"

UID_NUM="$(id -u)"
SOCK_PATH="${TMPDIR}ghostty-debug-${UID_NUM}.sock"
SENTINEL_PATH="${SOCK_PATH}.reset"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

cleanup() {
    rm -f "$SENTINEL_PATH"
    # Kill any background mock servers we started
    [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Precondition: no debug Ghoztty instance is running on this socket.
# We don't remove the socket — the test should work whether or not it exists.
# --------------------------------------------------------------------------

if [ ! -x "$GHOZTTY" ]; then
    echo "Binary not found: $GHOZTTY"
    echo "Run 'zig build -Doptimize=Debug' first."
    exit 1
fi

printf "\n=== IPC single-instance tests ===\n\n"

# --------------------------------------------------------------------------
# Test 1: +new-window exits with code 1 (not 200) when no instance running
# --------------------------------------------------------------------------
printf "Test 1: +new-window exits 1 when no instance is running\n"

rm -f "$SOCK_PATH" "$SENTINEL_PATH"

EXIT_CODE=0
STDERR_OUTPUT=$("$GHOZTTY" +new-window 2>&1 >/dev/null) || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ]; then
    pass "exit code is 1"
else
    fail "exit code is $EXIT_CODE (expected 1)"
fi

# --------------------------------------------------------------------------
# Test 2: error message is informative
# --------------------------------------------------------------------------
printf "Test 2: error message is informative\n"

if echo "$STDERR_OUTPUT" | grep -q "No running Ghoztty instance found"; then
    pass "stderr explains the problem"
else
    fail "stderr missing expected message: $STDERR_OUTPUT"
fi

if echo "$STDERR_OUTPUT" | grep -q "Launch Ghoztty first"; then
    pass "stderr tells user what to do"
else
    fail "stderr missing recovery hint: $STDERR_OUTPUT"
fi

# --------------------------------------------------------------------------
# Test 3: sentinel file is cleaned up after retries exhaust
# --------------------------------------------------------------------------
printf "Test 3: sentinel file is cleaned up after retries\n"

if [ ! -f "$SENTINEL_PATH" ]; then
    pass "sentinel file does not exist after failure"
else
    fail "sentinel file still exists: $SENTINEL_PATH"
    rm -f "$SENTINEL_PATH"
fi

# --------------------------------------------------------------------------
# Test 4: sentinel file is created during retries
#
# We create a stale socket (one that nobody is listening on) and run
# +new-window in the background. While retries are in progress, we check
# for the sentinel file.
# --------------------------------------------------------------------------
printf "Test 4: sentinel file is created during retry window\n"

rm -f "$SOCK_PATH" "$SENTINEL_PATH"

# Create a stale socket file (bind but don't listen/accept)
python3 -c "
import socket, os, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try: os.unlink('$SOCK_PATH')
except: pass
s.bind('$SOCK_PATH')
# Don't listen — connections will be refused
# Keep the socket alive briefly so the sentinel check can happen
import time; time.sleep(0.2)
s.close()
os.unlink('$SOCK_PATH')
" &
STALE_PID=$!

# Give the stale socket time to bind
sleep 0.1

# Run +new-window in the background (it will retry for ~2.4s)
"$GHOZTTY" +new-window 2>/dev/null &
CMD_PID=$!

# Check for sentinel file during the retry window
SENTINEL_FOUND=false
for i in $(seq 1 10); do
    sleep 0.3
    if [ -f "$SENTINEL_PATH" ]; then
        SENTINEL_FOUND=true
        break
    fi
done

if $SENTINEL_FOUND; then
    pass "sentinel file was created during retries"
else
    fail "sentinel file was never created"
fi

# Wait for the background command to finish
wait "$CMD_PID" 2>/dev/null || true
wait "$STALE_PID" 2>/dev/null || true
rm -f "$SENTINEL_PATH" "$SOCK_PATH"

# --------------------------------------------------------------------------
# Test 5: +split also exits 1 (not just +new-window)
# --------------------------------------------------------------------------
printf "Test 5: +split exits 1 when no instance is running\n"

rm -f "$SOCK_PATH" "$SENTINEL_PATH"

EXIT_CODE=0
"$GHOZTTY" +split 2>/dev/null || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 1 ]; then
    pass "exit code is 1"
else
    fail "exit code is $EXIT_CODE (expected 1)"
fi

rm -f "$SENTINEL_PATH"

# --------------------------------------------------------------------------
# Test 6: recovery via socket reset
#
# Start +new-window (which fails initial connect), then start a mock IPC
# server during the retry window. The CLI should connect on retry and
# succeed.
# --------------------------------------------------------------------------
printf "Test 6: recovery via mock server during retries\n"

rm -f "$SOCK_PATH" "$SENTINEL_PATH"

# Start the mock IPC server after a short delay
python3 -c "
import socket, struct, json, time, os

time.sleep(0.5)

sock_path = '$SOCK_PATH'
try: os.unlink(sock_path)
except: pass

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
os.chmod(sock_path, 0o600)
s.listen(1)
s.settimeout(5.0)

try:
    conn, _ = s.accept()
    # Read 4-byte length prefix
    length_bytes = conn.recv(4)
    if len(length_bytes) == 4:
        length = struct.unpack('>I', length_bytes)[0]
        payload = conn.recv(length)
        # Send success response
        response = json.dumps({'success': True}).encode()
        conn.send(struct.pack('>I', len(response)))
        conn.send(response)
    conn.close()
except socket.timeout:
    pass

s.close()
try: os.unlink(sock_path)
except: pass
" &
MOCK_PID=$!

EXIT_CODE=0
"$GHOZTTY" +new-window 2>/dev/null || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
    pass "CLI recovered via retry and exited 0"
else
    fail "CLI did not recover, exit code: $EXIT_CODE"
fi

wait "$MOCK_PID" 2>/dev/null || true
MOCK_PID=""
rm -f "$SENTINEL_PATH" "$SOCK_PATH"

# --------------------------------------------------------------------------
# Test 7: +close still succeeds silently when no instance (idempotent)
# --------------------------------------------------------------------------
printf "Test 7: +close succeeds when no instance (idempotent)\n"

rm -f "$SOCK_PATH" "$SENTINEL_PATH"

EXIT_CODE=0
"$GHOZTTY" +close --target=nonexistent 2>/dev/null || EXIT_CODE=$?

# +close returns 0 for NoRunningInstance (idempotent)
if [ "$EXIT_CODE" -eq 0 ]; then
    pass "exit code is 0 (idempotent close)"
else
    fail "exit code is $EXIT_CODE (expected 0)"
fi

rm -f "$SENTINEL_PATH"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
printf "\n=== Results: %d passed, %d failed ===\n\n" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
