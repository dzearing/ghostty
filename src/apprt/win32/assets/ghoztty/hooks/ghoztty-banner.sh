#!/bin/bash
# ghoztty-managed
# ghoztty-banner.sh — keep a Ghoztty pane banner current for a coding-agent session.
#
# WINDOWS-VENDORED FORK (T866): byte-for-byte main's copy except that every
# JSON operation runs through `ghoztty +json` (get/merge/encode) instead of a
# shelled-out external JSON tool. A clean Windows box has no such tool, and
# the whole point of the app installing this script is that nothing needs
# manual wiring — `ghoztty` itself is the one dependency that is always
# present wherever this script is installed, on both platforms. The pristine
# upstream copy sits in `../upstream/hooks/`; this fork collapses back into
# it once the same change lands on main (tracked as a mac-seat parity task).
#
# Banner layout: the title as an `## ` h2 heading on its own line (larger than
# the body text), then a key/value table (empty header row so the label column
# stays narrow), then the "Last result" block and PR link below it:
#   ## <title>
#   |  |  |
#   |---|---|
#   | **Goal** | <goal> |
#   | **Bugs fixed** | <bug links> |   # only when the task is a bug fix
#   | **Prompt** | <asked> |
#   | **Status** | <status> · <activity> |
#   **Last result**
#   <did>                     # plain-language summary; may be a multi-line
#                             # checklist ("- [x] item" per line) that a table
#                             # cell can't hold, so it lives below the table
#   **PR** [<url>](<url>)
#
# "Prompt"/"Last result" are model-provided paraphrases (set --asked/--did):
# "Prompt" is a plain-language paraphrase of the user's prompt (not a verbatim
# quote) and is auto-seeded from the raw prompt as a fallback; "Last result"
# names only the actual code fixes/features that landed this turn and is set
# ONLY by the model's explicit --did (never auto-seeded from tool calls, which
# are steps, not results). "Bugs fixed" (--bugs) is set only when the prompt is
# fixing a specific bug, and holds clickable markdown link(s) to the bug(s). The
# PR is a clickable markdown link. Fields persist in a per-tty state file, so
# each call only passes what changed.
# Delivery: ghoztty +set-banner CLI (multi-line + tables) targeting this pane's
# $GHOZTTY_PANE_ID; falls back to a single-line OSC 7778 write to the tty device
# when the pane can't be resolved (the OSC parser drops newlines, so the
# table/multi-line form is CLI-only).
#
# Usage:
#   ghoztty-banner.sh set [--title T] [--goal G] [--status S] [--asked A] [--did D] [--pr URL]
#   ghoztty-banner.sh status <text>     # shorthand for set --status
#   ghoztty-banner.sh activity <text>   # hook-owned suffix (working/idle)
#   ghoztty-banner.sh prompt-hook       # UserPromptSubmit: activity=working + context JSON
#   ghoztty-banner.sh session-start-hook # SessionStart(startup|clear): wipe + clear banner
#   ghoztty-banner.sh stop-hook         # Stop: activity=idle
#   ghoztty-banner.sh clear
#
# Silently no-ops when not running inside Ghoztty.

set -u

# NOTE: the env var value is "ghostty" (the upstream value Ghoztty inherits, set
# in src/Surface.zig / src/termio/Exec.zig), NOT "ghoztty" — do not "fix" this
# spelling to match the project name or every banner silently no-ops.
[ "${TERM_PROGRAM:-}" = "ghostty" ] || exit 0

STATE_DIR="$HOME/.config/ghoztty/banner-state"
mkdir -p "$STATE_DIR"

# Stop-hook PR staleness check: hard time budget for the network call, and how
# long a result is trusted before re-checking (so it doesn't run every turn).
PR_CHECK_TIMEOUT=5
PR_CHECK_TTL=300

# Extract a top-level string field (the first non-empty of the given keys) from
# a JSON object on stdin. `ghoztty +json get` DECODES JSON string escapes
# (\n, \") — unlike a raw substring scan — so values reach the banner as real
# text rather than literal escape sequences. Accepting several keys lets one
# call read either runtime's casing (session_id/sessionId).
jfield() { # key [key2 ...]   (reads stdin)
    ghoztty +json get "$@" 2>/dev/null
}

# All JSON here — payload fields, the per-pane state file, the context
# envelope — runs on `ghoztty +json`, so the one thing this script needs is a
# ghoztty new enough to have the verb. An older CLI cannot track the banner,
# and it must SAY so instead of exiting 0 invisibly: a silent exit is how a
# dead banner hook went unnoticed on Windows (there, the tty gate below was
# the cause; on a box with an old CLI the symptom is identical and the user
# has nothing to go on). Announced once per pane, in the banner itself. The
# probe result is cached positively, so the common case pays it once ever.
if [ ! -f "$STATE_DIR/.json-ok" ]; then
    if printf '' | ghoztty +json encode >/dev/null 2>&1; then
        : > "$STATE_DIR/.json-ok" 2>/dev/null
    else
        _nojson_pane="${GHOZTTY_PANE_ID:-}"
        if [ -n "$_nojson_pane" ]; then
            _nojson_flag="$STATE_DIR/nojson-$_nojson_pane"
            if [ ! -f "$_nojson_flag" ]; then
                : > "$_nojson_flag" 2>/dev/null
                ghoztty +set-banner --target="$_nojson_pane" \
                    "## Status banner inactive\nThe \`ghoztty\` CLI on PATH is too old to track this session's banner.\nUpgrade Ghoztty and start a new session." \
                    >/dev/null 2>&1 || true
            fi
        fi
        exit 0
    fi
fi

# Walk up the process tree until we find an ancestor with a controlling tty.
# (The hook shell and the Bash-tool shell have no tty; the agent process does.)
find_tty() {
    local pid=$$ t
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$t" ] && [ "$t" != "??" ]; then
            echo "$t"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

# A tty is NOT required — it is only one of the two ways to reach this pane, and
# on Windows it is never available: an agent-backed (session-persistence) pane
# has no /dev tty at all, and MSYS `ps` reports none for the hook shell or any
# of its ancestors, so this used to `exit 0` before $GHOZTTY_PANE_ID was ever
# consulted and every banner hook silently no-opped. Bail only when BOTH ways
# are gone.
TTY_NAME=$(find_tty) || TTY_NAME=""

# This pane's ghoztty-owned id: baked into the pane's env at spawn, inherited by
# hook shells, and accepted directly by every --target. It is authoritative and
# stable for the pane's whole life — including across a session-persistence
# restore, which allocates a FRESH pty. The tty is not: a restore can hand this
# pane a different tty, or hand this tty to a different pane, which is what used
# to aim a session's banner at a SIBLING pane. Targeting uses this; the state
# file stays tty-keyed so that a plugin upgrade never splits a running session's
# state between two files (its in-process hooks keep running the old script
# until the session restarts).
PANE_ID="${GHOZTTY_PANE_ID:-}"

# Neither route to this pane exists: nothing to target, nothing to write to.
[ -n "$TTY_NAME" ] || [ -n "$PANE_ID" ] || exit 0

# State is keyed by tty where there is one (a plugin upgrade must not split a
# running session's state between two files), and by pane id where there isn't
# — the id is stable for the pane's whole life, so it keys just as well.
if [ -n "$TTY_NAME" ]; then
    STATE_FILE="$STATE_DIR/$TTY_NAME.json"
else
    STATE_FILE="$STATE_DIR/pane-$PANE_ID.json"
fi

read_field() { # field
    [ -f "$STATE_FILE" ] && ghoztty +json get "$1" --file="$STATE_FILE" 2>/dev/null
}

# Merge key/value pairs into the state file. The native merge carries the same
# guarantees the old in-script dance provided: serialized against concurrent
# writers via the `$STATE_FILE.lock` mkdir mutex (the script is invoked BOTH by
# event hooks and directly by the agent against the same pane — and an older
# installed copy of this script may still race it on the same protocol), a
# unique same-directory temp published by an atomic rename, and a self-heal
# that resets a corrupt/unreadable state file to `{}` instead of wedging the
# banner blank forever.
state_merge() { # k1 v1 [k2 v2 ...]
    ghoztty +json merge "$STATE_FILE" "$@" >/dev/null 2>&1
    return 0
}

# Strip control characters that would corrupt an OSC sequence or IPC payload.
sanitize() {
    printf '%s' "$1" | tr -d '\000-\037' | tr -d '\177'
}

# Escape unescaped pipes so a value can't break out of its table cell.
esc_cell() {
    printf '%s' "$1" | sed 's/|/\\|/g'
}

# Render a PR URL as a clickable markdown link whose visible text is the URL.
pr_link() {
    printf '[%s](%s)' "$1" "$1"
}

# Escape markdown-active characters so untrusted text (e.g. the auto-seeded
# prompt paraphrase) can't inject a clickable link or emphasis into the banner.
# The banner renderer treats backslash as an escape, so `\[` renders a literal [.
esc_md() {
    printf '%s' "$1" | sed 's/[][()`*_~\\]/\\&/g'
}

# True only for a plain http(s) URL containing no characters that could break
# out of a markdown ()/[] link — guards the PR link against a crafted --pr value.
valid_url() {
    case "$1" in http://*|https://*) ;; *) return 1 ;; esac
    case "$1" in *[\ \"\<\>\`\(\)\[\]]*) return 1 ;; esac
    return 0
}

# Render the PR field as a clickable link ONLY when it is a safe URL, otherwise
# as plain escaped text — a crafted value can never forge a link.
pr_render() {
    if valid_url "$1"; then pr_link "$1"; else esc_md "$1"; fi
}

# Run a command with a hard time budget so a hung network call can't stall the
# hook on the agent's turn-end hot path. Prefers coreutils `timeout`/`gtimeout`,
# falls back to perl's alarm (always present on macOS; the timer survives exec
# and kills the child), and as a last resort runs unbounded.
with_timeout() { # seconds cmd...
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}

send_osc() { # single-line text
    [ -n "$TTY_NAME" ] || return 0
    printf '\033]7778;%s\007' "$1" > "/dev/$TTY_NAME" 2>/dev/null
}

# The "keep the banner current" instruction handed to the model as
# additionalContext by the prompt-hook. Single-quoted heredoc: the backticks,
# apostrophes and literal `\n` sequences are meant to reach the model verbatim
# (`ghoztty +json encode` JSON-encodes them for whichever envelope the runtime
# needs).
banner_help() {
    cat <<'EOF'
This session runs in a Ghoztty pane with a persistent status banner. Keep it current: run `~/.config/ghoztty/hooks/ghoztty-banner.sh set --title '<short task title>' --goal '<current goal>' --status '<one-line progress note>' [--asked '<plain-language paraphrase of the user's last prompt, NOT a verbatim quote>'] [--did '<the actual code fix/feature that landed>'] [--bugs '<markdown link(s) to the bug(s) being fixed>'] [--pr <url>]` when a task starts, whenever the goal/status meaningfully changes, and when a PR is created. --asked shows as 'Prompt' and --did as 'Last result'; keep both as short human-readable paraphrases (never raw tool names or quotes). IMPORTANT: --did is for ACTUAL fixes/features applied to the code, set it only once real changes have landed — never for exploration, reads, or intermediate tool calls (those are steps, not results); leave it alone until then. When more than one fix landed, pass a checklist with one item per line using \n, e.g. --did '- [x] Renamed Last prompt to Prompt\n- [x] Stopped auto-seeding Last result from tool calls'. When the prompt is fixing a specific bug (an issue link, a bug id, or a clearly identified defect), set --bugs to a clickable markdown link to it, e.g. --bugs '[#123](https://github.com/org/repo/issues/123)' (comma-separate multiple); it shows as a 'Bugs fixed' row under Goal. Omit --bugs entirely when the task is not a bug fix. Fields persist between calls, so pass only what changed.
EOF
}

# Resolve the pane this session runs in. $GHOZTTY_PANE_ID is authoritative and
# needs no lookup, so it wins outright. Older app builds don't bake it: those
# fall back to `+list --tty` every time. (The upstream script kept a cached
# name validated against the pane's current tty; the validation filter was the
# one JSON query too structural for `+json get`, and the cache only ever paid
# for itself on legacy builds — so the fork trades that one IPC round-trip per
# render, on legacy builds only, for a resolve that can never be stale.)
resolve_pane() {
    if [ -n "$PANE_ID" ]; then
        echo "$PANE_ID"
        return 0
    fi
    command -v ghoztty >/dev/null 2>&1 || return 1
    local pane
    pane=$(ghoztty +list --tty="$TTY_NAME" 2>/dev/null) && [ -n "$pane" ] || return 1
    echo "$pane"
}

render() {
    # One `+json get --each` reads every field in a single spawn (the state
    # values are sanitize()d single-line strings, so line-per-field is safe);
    # eight separate reads would put ~1s of process spawns on the hook path.
    local title="" goal="" status="" activity="" asked="" did="" pr="" bugs=""
    if [ -f "$STATE_FILE" ]; then
        {
            IFS= read -r title
            IFS= read -r goal
            IFS= read -r status
            IFS= read -r activity
            IFS= read -r asked
            IFS= read -r did
            IFS= read -r pr
            IFS= read -r bugs
        } < <(ghoztty +json get --each title goal status activity asked did pr bugs --file="$STATE_FILE" 2>/dev/null)
    fi

    # Nothing meaningful set yet (only activity): don't paint a banner.
    if [ -z "$title$goal$status$asked$did$pr$bugs" ]; then
        return 0
    fi

    # Display the activity sentence-cased ("Working"/"Idle") regardless of the
    # lowercase token stored in the state file.
    local statline="$status"
    if [ -n "$activity" ]; then
        local act_disp="$(printf '%s' "${activity:0:1}" | tr '[:lower:]' '[:upper:]')${activity:1}"
        [ -n "$statline" ] && statline="$statline · $act_disp" || statline="$act_disp"
    fi

    local pane
    if pane=$(resolve_pane) && [ -n "$pane" ]; then
        # CLI path ("\n" converted to newlines by the IPC server): the title
        # is the table's bold header cell so its divider sits flush beneath
        # it — no blank header row, no paragraph gap.
        local rows=""
        add_row() { # label value
            [ -n "$2" ] || return 0
            rows="$rows\n| **$1** | $(esc_cell "$2") |"
        }
        add_row "Goal" "$goal"
        add_row "Bugs fixed" "$bugs"
        add_row "Prompt" "$(esc_md "$asked")"
        add_row "Status" "$statline"

        # Title as an `## ` h2 heading on its own line above the table, so it
        # reads larger than the body. The table keeps an empty header row so
        # its label column stays as narrow as the labels.
        local text=""
        [ -n "$title" ] && text="## $title"
        if [ -n "$rows" ]; then
            [ -n "$text" ] && text="$text\n"
            text="$text|  |  |\n|---|---|$rows"
        fi
        # "Last result" lives below the table as its own block: it may be a
        # multi-line checklist/bullet list (items joined with \n by the model),
        # which a single-line table cell can't hold. Its own `\n` line breaks
        # survive to the renderer; esc_cell only neutralizes a stray `|`.
        if [ -n "$did" ]; then
            [ -n "$text" ] && text="$text\n"
            text="$text**Last result**\n$(esc_cell "$did")"
        fi
        if [ -n "$pr" ]; then
            [ -n "$text" ] && text="$text\n"
            text="$text**PR** $(pr_render "$pr")"
        fi
        ghoztty +set-banner --target="$pane" "$text" >/dev/null 2>&1 && return 0
    fi

    # OSC fallback: single line (no newlines/tables), bold title + labels.
    local line="" sep=" · "
    [ -n "$title" ] && line="**$title**"
    add_seg() { # label value
        [ -n "$2" ] || return 0
        [ -n "$line" ] && line="$line$sep"
        line="$line**$1:** $2"
    }
    add_seg "Goal" "$goal"
    add_seg "Bugs fixed" "$bugs"
    add_seg "Prompt" "$(esc_md "$asked")"
    add_seg "Status" "$statline"
    add_seg "Last result" "$did"
    [ -n "$pr" ] && { [ -n "$line" ] && line="$line$sep"; line="$line**PR:** $(pr_render "$pr")"; }
    send_osc "$line"
}

cmd="${1:-}"
shift 2>/dev/null || true

# Which agent invoked us (passed by the generated hook as --runtime=<name>).
# Selects the additionalContext envelope the prompt-hook emits and unifies the
# session-start wipe decision across runtimes. Defaults to claude for backward
# compatibility with hooks generated before this flag existed.
runtime="claude"
for _arg in "$@"; do
    case "$_arg" in --runtime=*) runtime="${_arg#*=}" ;; esac
done

case "$cmd" in
set)
    pairs=()
    newtitle=""; newtitle_set=0; pr_set=0; did_set=0; bugs_set=0
    while [ $# -gt 0 ]; do
        case "$1" in
        --title)  newtitle=$(sanitize "${2:-}"); newtitle_set=1; pairs+=(title "$newtitle"); shift 2 ;;
        --goal)   pairs+=(goal "$(sanitize "${2:-}")"); shift 2 ;;
        --status) pairs+=(status "$(sanitize "${2:-}")"); shift 2 ;;
        --asked)  pairs+=(asked "$(sanitize "${2:-}")"); shift 2 ;;
        --did)    did_set=1; pairs+=(did "$(sanitize "${2:-}")"); shift 2 ;;
        --bugs)   bugs_set=1; pairs+=(bugs "$(sanitize "${2:-}")"); shift 2 ;;
        --pr)     pr_set=1; pairs+=(pr "$(sanitize "${2:-}")"); shift 2 ;;
        --title=*)  newtitle=$(sanitize "${1#*=}"); newtitle_set=1; pairs+=(title "$newtitle"); shift ;;
        --goal=*)   pairs+=(goal "$(sanitize "${1#*=}")"); shift ;;
        --status=*) pairs+=(status "$(sanitize "${1#*=}")"); shift ;;
        --asked=*)  pairs+=(asked "$(sanitize "${1#*=}")"); shift ;;
        --did=*)    did_set=1; pairs+=(did "$(sanitize "${1#*=}")"); shift ;;
        --bugs=*)   bugs_set=1; pairs+=(bugs "$(sanitize "${1#*=}")"); shift ;;
        --pr=*)     pr_set=1; pairs+=(pr "$(sanitize "${1#*=}")"); shift ;;
        *) shift ;;
        esac
    done
    # A changed title means a new task: drop fields that would otherwise
    # linger from the previous one (a stale PR link, the old "Last result", a
    # prior bug reference), but never clobber a value passed explicitly in this
    # same call.
    if [ "$newtitle_set" = 1 ] && [ "$newtitle" != "$(read_field title)" ]; then
        [ "$pr_set" = 1 ]   || pairs+=(pr "")
        [ "$did_set" = 1 ]  || pairs+=(did "")
        [ "$bugs_set" = 1 ] || pairs+=(bugs "")
    fi
    # A newly-set PR should be verified promptly, not suppressed by the previous
    # PR's TTL — clear the last-checked stamp whenever the PR field is touched.
    [ "$pr_set" = 1 ] && pairs+=(pr_checked_at "")
    [ ${#pairs[@]} -gt 0 ] && state_merge "${pairs[@]}"
    render
    ;;
status)
    state_merge status "$(sanitize "${1:-}")"
    render
    ;;
activity)
    state_merge activity "$(sanitize "${1:-}")"
    render
    ;;
prompt-hook)
    # Seed "You asked" with the raw prompt (first line, truncated) as a
    # default the model refines into a paraphrase during the turn.
    input=$(cat)
    asked=$(printf '%s' "$input" | jfield prompt | head -n1)
    asked=$(printf '%s' "$asked" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-500)
    asked=$(sanitize "$asked")
    [ ${#asked} -gt 100 ] && asked="${asked:0:97}..."

    # A new ask starts fresh: clear "What I did" so the previous turn's work
    # isn't shown until something new actually happens this turn.
    pairs=(activity "working" did "")
    [ -n "$asked" ] && pairs+=(asked "$asked")

    # The state file is keyed by tty, so a fresh agent session starting in a
    # pane inherits the PREVIOUS session's task fields (title/goal/status/pr).
    # Detect a new session by its id and wipe the stale task identity, so a
    # fresh context begins with a blank banner instead of another session's
    # task. A resumed session keeps its id, so its banner is preserved.
    session=$(printf '%s' "$input" | jfield session_id sessionId)
    if [ -n "$session" ] && [ "$session" != "$(read_field session)" ]; then
        pairs+=(session "$session" title "" goal "" status "" pr "" bugs "")
    fi

    state_merge "${pairs[@]}"
    render
    # Tell the model to keep the banner current, delivered as additionalContext.
    # Claude processes UserPromptSubmit output as a NESTED hookSpecificOutput
    # envelope; Copilot processes it only as a FLAT {"additionalContext":...}
    # object (verified against a live Copilot hook — the nested form is silently
    # dropped, which is why the Copilot banner never populated). `ghoztty +json
    # encode` (guaranteed present past the gate above) escapes the text; the
    # envelope shapes themselves are fixed strings.
    ctx=$(banner_help | ghoztty +json encode 2>/dev/null)
    [ -n "$ctx" ] || ctx='""'
    if [ "$runtime" = copilot ]; then
        printf '{"additionalContext":%s}\n' "$ctx"
    else
        printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ctx"
    fi
    ;;
session-start-hook)
    # Fires on SessionStart. A fresh launch (source=startup), `/clear`
    # (source=clear), or a brand-new session (source=new) begins a new task in
    # this pane, so wipe the previous session's task identity AND clear the
    # on-screen banner immediately — don't wait for the next prompt to blank
    # stale data. `resume`/`compact` continue the SAME task, so their banner is
    # left untouched. Claude restricts this hook to a `startup|clear` matcher
    # upstream; Copilot cannot express a matcher, so the decision is made here
    # from the `source` field (normalized through for Copilot, native for
    # Claude) — the two runtimes then behave identically.
    input=$(cat)
    session=$(printf '%s' "$input" | jfield session_id sessionId)
    source=$(printf '%s' "$input" | jfield source)
    case "$source" in
    resume|compact)
        # Same task continues in this pane: keep the live banner, just record
        # the session id so the prompt-hook doesn't treat it as new.
        [ -n "$session" ] && state_merge session "$session"
        ;;
    *)
        pane=$(resolve_pane)
        [ -n "$pane" ] && ghoztty +set-banner --target="$pane" --clear >/dev/null 2>&1
        # Reset task fields; record the new id so the prompt-hook doesn't
        # re-wipe on this session's first prompt.
        pairs=(title "" goal "" status "" asked "" did "" pr "" bugs "" activity "")
        [ -n "$session" ] && pairs+=(session "$session")
        state_merge "${pairs[@]}"
        ;;
    esac
    ;;
stop-hook)
    state_merge activity "idle"
    render
    # Best-effort: drop a PR link once it's no longer open (closed/merged), so
    # the banner never shows a stale PR. This is a network call on the turn-end
    # hot path, so it is BOUNDED by a hard timeout and THROTTLED to at most once
    # per TTL (recorded in the state file). GitHub + gh only; the `--` and the
    # https-scheme guard keep an attacker-influenced $pr from becoming a gh flag.
    # Silent on any failure (no gh, not authed, non-GitHub host, network error).
    pr=$(read_field pr)
    if [ -n "$pr" ] && command -v gh >/dev/null 2>&1; then
        now=$(date +%s 2>/dev/null || echo 0)
        last=$(read_field pr_checked_at)
        if [ "$now" = 0 ] || [ -z "$last" ] || [ "$((now - last))" -ge "$PR_CHECK_TTL" ]; then
            case "$pr" in
            https://*github.com/*)
                state_merge pr_checked_at "$now"
                state=$(with_timeout "$PR_CHECK_TIMEOUT" gh pr view --json state -q .state -- "$pr" 2>/dev/null)
                if [ -n "$state" ] && [ "$state" != "OPEN" ]; then
                    state_merge pr ""
                    render
                fi
                ;;
            esac
        fi
    fi
    ;;
clear)
    pane=$(resolve_pane)
    rm -f "$STATE_FILE"
    [ -n "$pane" ] && ghoztty +set-banner --target="$pane" --clear >/dev/null 2>&1
    send_osc ""
    ;;
*)
    echo "usage: ghoztty-banner.sh set|status|activity|prompt-hook|session-start-hook|stop-hook|clear" >&2
    exit 2
    ;;
esac
exit 0
