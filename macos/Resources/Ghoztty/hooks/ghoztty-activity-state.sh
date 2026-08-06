#!/usr/bin/env bash
# ghoztty-managed
# Mirror "what is this pane doing" into the Ghoztty window activity state,
# which surfaces as the title suffix and the AXWindowActivityState attribute
# (read by ztabby et al).
#
# The whole point of this script is to be the single owner of one priority
# ordering, so nothing can downgrade a state that outranks it:
#
#     needs_input  >  busy  >  idle
#
# needs_input exists to pull a human's eyes to the window, so it outranks
# everything and is never clobbered from below. busy means work is still in
# flight somewhere -- the main loop OR a background subagent that has outlived
# it. idle means genuinely nothing is happening.
#
# Verbs:
#   pause         -> needs_input. Anything blocking on the user: AskUserQuestion,
#                    plan approval, a permission prompt, the idle notification.
#   tool-tick     -> PostToolUse catch-all. On the main thread, undoes a pause.
#                    Inside a subagent, beats that agent's liveness marker.
#   agent-start   -> record a running subagent (SubagentStart).
#   agent-stop    -> clear that subagent (SubagentStop).
#   settle        -> the Stop hook. Decide the final state for the turn.
#   reset         -> forget every tracked agent for this session and re-settle.
#                    Manual escape hatch for a pane stuck on busy.
#   session-start -> drop this session's leftovers at startup.
#
# Always exits 0 and stays silent: a hook that fails must never break the turn.
set -u

verb="${1:-}"

# Which agent invoked us (passed by the generated hook as --runtime=<name>),
# matching the banner script's convention. It namespaces this script's state so
# two runtimes driving the same machine never share marker files, and it names
# the process to look for when deciding whether a marker's owner is still alive.
# Defaults to claude for backward compatibility with an older generated hook.
runtime="claude"
for _arg in "$@"; do
    case "$_arg" in --runtime=*) runtime="${_arg#*=}" ;; esac
done

# Target the PANE ID, not the window name. An auto-named window ("window-7")
# is not in the IPC registry until something walks it (+list, or an explicit
# --target= at creation), so `+set-state --target=$GHOZTTY_WINDOW_NAME` fails
# with "not found in registry" for any window opened with Cmd-N -- and the
# failure is invisible, because these hooks discard stderr. The registry is
# also per-process, so it empties on every app relaunch.
#
# A pane id always resolves: resolveTarget() parses it as a UUID and scans live
# panes directly, no registration required. It is baked into every pane's env
# at spawn and survives session restore.
target="${GHOZTTY_PANE_ID:-${GHOZTTY_WINDOW_NAME:-}}"
[ -n "$target" ] || exit 0

# needs_input is keyed on the pane, because the pane is what the state describes.
marker="/tmp/ghoztty-${runtime}-needsinput-${target}"

# How long a subagent may go without a single tool-lifecycle event before it is
# presumed dead. Must exceed the longest plausible SINGLE tool call, because a
# 40-minute build emits PreToolUse at the start and nothing again until it ends.
stale_min="${GHOZTTY_AGENT_STALE_MIN:-30}"

set_state() { ghoztty +set-state --target="$target" --state="$1" 2>/dev/null; }

# Pull a JSON string field out of the raw payload with bash's own regex engine.
# This runs on the hot path (every tool call of every agent), so it must not
# fork -- a jq per tool call across a fleet of parallel subagents is real cost.
# Accepts several keys so one call reads either runtime's casing.
json_str() {
  local k
  for k in $1; do
    [[ "$2" =~ \"$k\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && { printf '%s' "${BASH_REMATCH[1]}"; return; }
  done
}

# The agent process that owns this hook. Verified empirically for Claude: the
# hook script's direct parent IS the claude process, so $PPID is the owner.
# Walking up as a fallback keeps this correct if that spawn path ever changes,
# and lets the same code serve a runtime that wraps its hooks in a shell.
owner_pid() {
  local p="$PPID" c n=0
  while [ "$n" -lt 4 ] && [ -n "$p" ] && [ "$p" != 1 ]; do
    c="$(ps -o comm= -p "$p" 2>/dev/null)"
    case "${c##*/}" in "$runtime"*) printf '%s' "$p"; return;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; n=$((n+1))
  done
  printf '%s' "$PPID"
}

# pause never touches the payload, so it skips the stdin read entirely.
if [ "$verb" = pause ]; then
  : > "$marker" 2>/dev/null
  set_state needs_input
  exit 0
fi

IFS= read -r -d '' payload 2>/dev/null || true
sid="$(json_str "session_id sessionId" "$payload")"
aid="$(json_str "agent_id agentId" "$payload")"

# One marker file per live subagent, not an integer counter. Parallel subagents
# mean concurrent hook processes, and read-modify-write on a shared counter
# races -- two SubagentStops landing together can lose a decrement and strand
# the pane on busy forever. Distinct files are atomic and need no locking.
#
# Keyed on session_id (verified: a subagent's hooks report the PARENT session
# id, so one directory holds the whole session). The owning agent pid is baked
# into the filename so any later sweep can tell a live agent from a leak.
agent_dir="/tmp/ghoztty-${runtime}-agents-${sid}"

# Drop markers whose owning agent process is gone. This is the exact,
# instant recovery path: it needs no timeout and no guesswork, and it works
# across sessions, so one crashed pane cannot litter /tmp forever. Verified
# necessary -- killing the agent mid-subagent never fires SubagentStop.
reap_dead_owners() {
  local d f pid
  shopt -s nullglob
  for d in "/tmp/ghoztty-${runtime}-agents-"*/; do
    for f in "$d"*; do
      pid="${f##*__}"
      case "$pid" in
        ''|*[!0-9]*) continue ;;                  # unparseable, leave for the age sweep
      esac
      kill -0 "$pid" 2>/dev/null || rm -f "$f" 2>/dev/null
    done
    rmdir "$d" 2>/dev/null
  done
}

case "$verb" in
  tool-tick)
    if [ -n "$aid" ]; then
      # A SUBAGENT's tool call. Beat its liveness marker and stop there.
      #
      # Critically, it must NOT fall through to the resume branch: a background
      # agent chattering away while the main loop waits on an AskUserQuestion
      # would otherwise clear needs_input and drop the pane to busy, burying a
      # question the user still has to answer. Lower states never overwrite it.
      [ -n "$sid" ] || exit 0
      shopt -s nullglob
      for f in "${agent_dir}/${aid}__"*; do : > "$f" 2>/dev/null; done
      exit 0
    fi
    # MAIN thread. Undo an outstanding pause. The marker guard is what keeps
    # this cheap: without it, a catch-all PostToolUse hook is an IPC round-trip
    # per tool for the whole session.
    [ -f "$marker" ] || exit 0
    rm -f "$marker" 2>/dev/null
    set_state busy
    ;;

  agent-start)
    [ -n "$sid" ] && [ -n "$aid" ] || exit 0
    mkdir -p "$agent_dir" 2>/dev/null
    : > "${agent_dir}/${aid}__$(owner_pid)" 2>/dev/null
    ;;

  agent-stop)
    [ -n "$sid" ] && [ -n "$aid" ] || exit 0
    shopt -s nullglob
    for f in "${agent_dir}/${aid}__"*; do rm -f "$f" 2>/dev/null; done
    # Deliberately does NOT set idle. The main loop is re-invoked with the
    # completion notification, and that turn's Stop calls settle -- the one
    # place allowed to decide the pane is done.
    ;;

  session-start)
    # No subagent of THIS session can be alive at session start, so anything
    # here leaked from a kill. Also sweep other sessions' dead owners.
    [ -n "$sid" ] && rm -rf "$agent_dir" 2>/dev/null
    reap_dead_owners
    ;;

  reset)
    [ -n "$sid" ] && rm -rf "$agent_dir" 2>/dev/null
    if [ -f "$marker" ]; then set_state needs_input; else set_state idle; fi
    ;;

  settle)
    # 1. needs_input outranks everything. Re-assert rather than just bailing,
    #    so a dropped IPC call earlier in the turn self-heals here.
    if [ -f "$marker" ]; then
      set_state needs_input
      exit 0
    fi

    # 2. A scheduled wake-up (ScheduleWakeup/CronCreate/Monitor) means this turn
    #    ending is not the work ending. One-shot: consumed here.
    #
    #    Written by the USER's own hook, not by anything Ghoztty installs, so
    #    this is an external contract. The legacy `/tmp/claude-busy-` spelling
    #    is still honored for Claude: it predates this script moving into the
    #    app, and silently dropping it would break a working escape hatch.
    if [ -n "$sid" ]; then
      for busy in "/tmp/ghoztty-${runtime}-busy-${sid}" \
                  $([ "$runtime" = claude ] && printf '%s' "/tmp/claude-busy-${sid}"); do
        if [ -f "$busy" ]; then
          rm -f "$busy" 2>/dev/null
          set_state busy
          exit 0
        fi
      done
    fi

    # 3. Background subagents outlive the main loop going quiet.
    if [ -n "$sid" ] && [ -d "$agent_dir" ]; then
      # Two independent recovery paths, both mid-session:
      #   - owner dead   -> exact, instant (crash, SIGKILL, closed window)
      #   - no heartbeat -> covers a cancelled or wedged agent inside a session
      #     that is still very much alive, where nothing fires SubagentStop.
      reap_dead_owners
      find "$agent_dir" -type f -mmin +"$stale_min" -delete 2>/dev/null
      shopt -s nullglob
      live=("$agent_dir"/*)
      if [ "${#live[@]}" -gt 0 ]; then
        set_state busy
        exit 0
      fi
      rmdir "$agent_dir" 2>/dev/null
    fi

    set_state idle
    ;;
esac

exit 0
