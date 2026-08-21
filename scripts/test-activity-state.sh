#!/usr/bin/env bash
# Tests for macos/Resources/Ghoztty/hooks/ghoztty-activity-state.sh.
#
# The script's whole job is a priority ordering (needs_input > busy > idle) and
# a set of recovery paths for subagents that never reported back. Both are the
# kind of thing that looks right and silently isn't: a pane wrongly stuck on
# busy is only visible minutes later, and a buried needs_input is visible only
# as "why did nobody answer me". So every transition is asserted here rather
# than eyeballed in a live session.
#
# Method: a stub `ghoztty` earlier on PATH appends each --state= value to a log,
# so a case is just "drive these hooks, expect exactly this state sequence".
# Nothing here talks to a real pane or a real agent session -- the pane target
# and session ids are fakes scoped to this run's pid, so the suite is safe to
# run while you are working and re-runnable without cleanup.
#
# Lives in scripts/ rather than beside the script it tests: everything under
# Resources/Ghoztty/ is copied wholesale into the app bundle, and a test harness
# is not something to ship to users.
#
# Usage: bash scripts/test-activity-state.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/macos/Resources/Ghoztty/hooks/ghoztty-activity-state.sh"
[ -f "$SCRIPT" ] || { echo "cannot find $SCRIPT"; exit 1; }

TMP="$(mktemp -d)"
PANE="test-pane-$$"

# The script namespaces its state by runtime, defaulting to claude when the
# generated hook passes no --runtime=. The harness drives that default.
PREFIX="/tmp/ghoztty-claude"
MARKER="${PREFIX}-needsinput-${PANE}"
export GHOZTTY_TEST_LOG="$TMP/states.log"

# The stub stands in for the IPC call. Recording only --state= is deliberate:
# the assertions are about which state was published, not how it was addressed.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ghoztty" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    --state=*) printf '%s\n' "${arg#--state=}" >> "$GHOZTTY_TEST_LOG" ;;
  esac
done
exit 0
STUB
chmod +x "$TMP/bin/ghoztty"
export PATH="$TMP/bin:$PATH"

cleanup() {
  rm -rf "$TMP" "$MARKER"
  rm -rf /tmp/ghoztty-*-agents-test-$$-* 2>/dev/null
  rm -f /tmp/ghoztty-*-busy-test-$$-* /tmp/claude-busy-test-$$-* 2>/dev/null
}
trap cleanup EXIT

passed=0
failed=0
sid=""

# Each case gets its own session id so a stray marker can never leak sideways
# into the next assertion.
begin() {
  case_name="$1"
  sid="test-$$-$(( ${case_n:-0} + 1 ))"
  case_n=$(( ${case_n:-0} + 1 ))
  rm -rf "${PREFIX}-agents-${sid}" "$MARKER" "${PREFIX}-busy-${sid}" "/tmp/claude-busy-${sid}"
  : > "$GHOZTTY_TEST_LOG"
}

# Real payloads from the main thread carry no agent_id at all; that absence is
# the only thing distinguishing them from a subagent's, so the fixtures mirror
# it exactly rather than sending an empty string.
main_payload()  { printf '{"session_id":"%s","hook_event_name":"%s"}' "$sid" "${1:-PostToolUse}"; }
agent_payload() { printf '{"session_id":"%s","agent_id":"%s","agent_type":"general-purpose"}' "$sid" "$1"; }

hook() { printf '%s' "${2-}" | GHOZTTY_PANE_ID="$PANE" bash "$SCRIPT" "$1"; }

expect_states() {
  local expected="$1" actual
  actual="$(cat "$GHOZTTY_TEST_LOG")"
  if [ "$actual" = "$expected" ]; then
    passed=$(( passed + 1 ))
    printf 'ok   %2d  %s\n' "$case_n" "$case_name"
  else
    failed=$(( failed + 1 ))
    printf 'FAIL %2d  %s\n' "$case_n" "$case_name"
    printf '        expected: %s\n' "$(printf '%s' "$expected" | tr '\n' ',')"
    printf '        actual:   %s\n' "$(printf '%s' "$actual" | tr '\n' ',')"
  fi
}

fail_case() {
  failed=$(( failed + 1 ))
  printf 'FAIL %2d  %s\n' "$case_n" "$case_name"
  printf '        %s\n' "$1"
}

# A pid that has already exited and been reaped, for the dead-owner path.
dead_pid() { ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }

# BSD and GNU touch disagree on how to name a past time, and this suite has to
# run on both, so try the macOS form first and fall back.
backdate() {
  local ts
  ts="$(date -v-"$2"M +%Y%m%d%H%M 2>/dev/null)" || ts="$(date -d "$2 minutes ago" +%Y%m%d%H%M)"
  touch -t "$ts" "$1"
}


begin "idle when nothing is running"
hook settle "$(main_payload Stop)"
expect_states "idle"


begin "busy while a background agent is live"
hook agent-start "$(agent_payload agent-a)"
hook settle "$(main_payload Stop)"
expect_states "busy"


begin "needs_input beats a live background agent"
hook agent-start "$(agent_payload agent-a)"
hook pause
hook settle "$(main_payload Stop)"
expect_states "needs_input
needs_input"


begin "a subagent tool-tick does NOT clear needs_input"
hook pause
hook agent-start "$(agent_payload agent-a)"
hook tool-tick "$(agent_payload agent-a)"
hook settle "$(main_payload Stop)"
if [ ! -f "$MARKER" ]; then
  fail_case "subagent tool-tick removed the needs_input marker"
else
  expect_states "needs_input
needs_input"
fi


begin "a main-thread tool-tick DOES clear needs_input"
hook pause
hook tool-tick "$(main_payload)"
hook settle "$(main_payload Stop)"
expect_states "needs_input
busy
idle"


begin "idle only after the last agent stops"
hook agent-start "$(agent_payload agent-a)"
hook agent-start "$(agent_payload agent-b)"
hook settle "$(main_payload Stop)"
hook agent-stop "$(agent_payload agent-a)"
hook settle "$(main_payload Stop)"
hook agent-stop "$(agent_payload agent-b)"
hook settle "$(main_payload Stop)"
expect_states "busy
busy
idle"


begin "a dead owner pid is reaped instantly"
mkdir -p "${PREFIX}-agents-${sid}"
: > "${PREFIX}-agents-${sid}/agent-a__$(dead_pid)"
hook settle "$(main_payload Stop)"
expect_states "idle"


begin "a live owner pid is NOT over-reaped"
mkdir -p "${PREFIX}-agents-${sid}"
: > "${PREFIX}-agents-${sid}/agent-a__$$"
hook settle "$(main_payload Stop)"
expect_states "busy"


# The stale sweep is what covers an agent that was cancelled or wedged inside a
# still-living session, where nothing ever fires SubagentStop. Both of the next
# two cases use this process's own (very much alive) pid, so the outcome can
# only be attributed to the heartbeat, never to the owner-liveness path.
begin "a heartbeat rescues a marker past the stale window"
mkdir -p "${PREFIX}-agents-${sid}"
: > "${PREFIX}-agents-${sid}/agent-a__$$"
backdate "${PREFIX}-agents-${sid}/agent-a__$$" 5
GHOZTTY_AGENT_STALE_MIN=1 hook tool-tick "$(agent_payload agent-a)"
GHOZTTY_AGENT_STALE_MIN=1 hook settle "$(main_payload Stop)"
expect_states "busy"


begin "no heartbeat past the stale window is pruned"
mkdir -p "${PREFIX}-agents-${sid}"
: > "${PREFIX}-agents-${sid}/agent-a__$$"
backdate "${PREFIX}-agents-${sid}/agent-a__$$" 5
GHOZTTY_AGENT_STALE_MIN=1 hook settle "$(main_payload Stop)"
expect_states "idle"


begin "reset clears a pane stuck on busy"
hook agent-start "$(agent_payload agent-a)"
hook settle "$(main_payload Stop)"
hook reset "$(main_payload)"
hook settle "$(main_payload Stop)"
expect_states "busy
idle
idle"


begin "reset preserves needs_input"
hook pause
hook agent-start "$(agent_payload agent-a)"
hook reset "$(main_payload)"
expect_states "needs_input
needs_input"


begin "the ScheduleWakeup busy marker still works, and is one-shot"
touch "${PREFIX}-busy-${sid}"
hook settle "$(main_payload Stop)"
hook settle "$(main_payload Stop)"
expect_states "busy
idle"


# The plugin this script came from used /tmp/claude-busy-<sid>, and users wrote
# their own hooks against that name. Dropping it silently would break a working
# escape hatch, so the legacy spelling is still honored for Claude.
begin "the legacy claude-busy marker is still honored"
touch "/tmp/claude-busy-${sid}"
hook settle "$(main_payload Stop)"
hook settle "$(main_payload Stop)"
expect_states "busy
idle"


# State is namespaced per runtime so two agents driving the same machine cannot
# read each other's markers -- a Copilot agent-start must not make a Claude pane
# report busy.
begin "runtime namespacing keeps two agents' state apart"
printf '%s' "$(agent_payload agent-a)" | GHOZTTY_PANE_ID="$PANE" bash "$SCRIPT" agent-start --runtime=copilot
hook settle "$(main_payload Stop)"
rm -rf "/tmp/ghoztty-copilot-agents-${sid}"
expect_states "idle"


# Outside Ghoztty there is no pane to describe, so the correct behaviour is to
# do nothing at all -- no IPC, and no /tmp state left behind for a pane that
# does not exist.
begin "total silence when no pane id is set"
env -u GHOZTTY_PANE_ID -u GHOZTTY_WINDOW_NAME bash "$SCRIPT" pause </dev/null
printf '%s' "$(agent_payload agent-a)" | env -u GHOZTTY_PANE_ID -u GHOZTTY_WINDOW_NAME bash "$SCRIPT" agent-start
printf '%s' "$(main_payload Stop)" | env -u GHOZTTY_PANE_ID -u GHOZTTY_WINDOW_NAME bash "$SCRIPT" settle
if [ -e "${PREFIX}-agents-${sid}" ]; then
  fail_case "created ${PREFIX}-agents-${sid} with no pane to describe"
else
  expect_states ""
fi


echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
