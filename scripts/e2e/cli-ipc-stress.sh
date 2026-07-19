#!/usr/bin/env bash
#
# CLI IPC stress / crash-regression guard.
#
# Reproduces (and guards against the regression of) the intermittent
# memory-corruption crash in short-lived `ghoztty` CLI invocations, where the
# per-command scratch `ArenaAllocator` was shared, unsynchronized, with the
# `remote.connection.Connection`'s reader/writer/heartbeat threads. That data
# race corrupted the arena and produced a wild read/write (SIGSEGV/SIGBUS) in
# `rpcCall` / `failPendingRpcs` roughly 1-2% of the time.
#
# `+sessions` is the only CLI command that dials the local agent directly and
# stands up a threaded `Connection`, so it is the tightest reproducer. It
# requires a running local agent (session-persistence = on). Before the fix this
# loop crashes within tens-to-hundreds of iterations; after the fix it runs
# clean indefinitely.
#
# Usage:
#   scripts/e2e/cli-ipc-stress.sh [ITERATIONS] [PATH_TO_ghoztty_BINARY]
#
# Defaults: 5000 iterations, the debug binary in ./zig-out.
# Exit code: 0 if no crash, 1 if any invocation died on a signal.

set -u

ITERATIONS="${1:-5000}"
BIN="${2:-./zig-out/Ghoztty-Debug.app/Contents/MacOS/ghoztty}"

if [ ! -x "$BIN" ]; then
  echo "error: ghoztty binary not found/executable: $BIN" >&2
  echo "       build it first: zig build -Doptimize=Debug" >&2
  exit 2
fi

# Sanity: the agent must be up, otherwise every run short-circuits before it
# ever dials (and the race can't reproduce).
if ! "$BIN" +sessions >/dev/null 2>&1; then
  echo "error: '$BIN +sessions' failed on a warmup run — is the local agent running?" >&2
  echo "       (session-persistence must be on and an agent alive)" >&2
  exit 2
fi

crashes=0
for i in $(seq 1 "$ITERATIONS"); do
  "$BIN" +sessions >/dev/null 2>&1
  rc=$?
  # A signal-terminated child reports 128+signo. SIGSEGV=139, SIGBUS=138.
  if [ "$rc" -gt 128 ]; then
    crashes=$((crashes + 1))
    echo "iter $i: CRASH — signal $((rc - 128)) (rc=$rc)"
  fi
  if [ $((i % 500)) -eq 0 ]; then
    echo "...$i/$ITERATIONS done, crashes=$crashes"
  fi
done

echo "TOTAL crashes=$crashes / $ITERATIONS"
[ "$crashes" -eq 0 ]
