#!/usr/bin/env bash
#
# Unit tests for macos/Resources/Ghoztty/hooks/ghoztty-banner.sh
#
# Self-contained: each test runs the banner script under a throwaway $HOME with
# a stub `ghoztty` (that records the banner text it is handed) and asserts the
# state file / emitted envelope. Run directly:
#
#   ./test/ghoztty-banner.sh
#
# Exits non-zero if any assertion fails. Requires jq (the script hard-requires
# it); skips cleanly when jq is absent.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BANNER="$HERE/../macos/Resources/Ghoztty/hooks/ghoztty-banner.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed"
    exit 0
fi
[ -f "$BANNER" ] || { echo "FAIL: banner script not found at $BANNER"; exit 1; }

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
# assert_eq desc expected actual
assert_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi; }
# assert_has / assert_hasnt desc haystack needle  (literal substring)
assert_has()   { case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing [$3] in [$2])";; esac; }
assert_hasnt() { case "$2" in *"$3"*) bad "$1 (found [$3] in [$2])";; *) ok "$1";; esac; }

setup() {
    TMP=$(mktemp -d)
    export HOME="$TMP" TERM_PROGRAM=ghostty GHOZTTY_PANE_ID=TESTPANE
    mkdir -p "$TMP/bin"
    # Stub ghoztty: record the text passed to +set-banner (arg 3 unless --clear).
    cat > "$TMP/bin/ghoztty" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "+set-banner" ] && [ "${3:-}" != "--clear" ] && [ -n "${3:-}" ]; then
    printf '%s' "$3" > "$HOME/last-banner.txt"
fi
exit 0
STUB
    chmod +x "$TMP/bin/ghoztty"
    export PATH="$TMP/bin:$PATH"
}
teardown() { rm -rf "$TMP"; }
state()  { cat "$TMP"/.config/ghoztty/banner-state/*.json 2>/dev/null; }
sfield() { state | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null; }
banner() { cat "$TMP/last-banner.txt" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== source-gate + jq parsing (both runtime casings) =="
setup
bash "$BANNER" set --title "OldTask" >/dev/null 2>&1
assert_eq "set records title" "OldTask" "$(sfield title)"
# Copilot-shaped payload (camelCase sessionId) with source=resume keeps banner.
printf '{"sessionId":"s1","source":"resume"}' | bash "$BANNER" session-start-hook --runtime=copilot >/dev/null 2>&1
assert_eq "resume keeps title (copilot camelCase)" "OldTask" "$(sfield title)"
# source=new wipes.
printf '{"sessionId":"s1","source":"new"}' | bash "$BANNER" session-start-hook --runtime=copilot >/dev/null 2>&1
assert_eq "new wipes title (copilot)" "" "$(sfield title)"
# Claude-shaped payload (snake_case session_id), source=startup wipes.
bash "$BANNER" set --title "T2" >/dev/null 2>&1
printf '{"session_id":"s2","source":"startup"}' | bash "$BANNER" session-start-hook --runtime=claude >/dev/null 2>&1
assert_eq "startup wipes title (claude snake_case)" "" "$(sfield title)"
teardown

# ---------------------------------------------------------------------------
echo "== prompt-hook additionalContext envelope per runtime =="
setup
out=$(printf '{"prompt":"hi","session_id":"s","source":""}' | bash "$BANNER" prompt-hook --runtime=copilot)
flat=$(printf '%s' "$out" | jq -e 'has("additionalContext") and (has("hookSpecificOutput")|not)' >/dev/null 2>&1 && echo 1 || echo 0)
assert_eq "copilot emits FLAT additionalContext" "1" "$flat"
out=$(printf '{"prompt":"hi","session_id":"s","source":"startup"}' | bash "$BANNER" prompt-hook --runtime=claude)
nested=$(printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | type=="string"' >/dev/null 2>&1 && echo 1 || echo 0)
assert_eq "claude emits NESTED hookSpecificOutput" "1" "$nested"
teardown

# ---------------------------------------------------------------------------
echo "== jq decodes JSON escapes (no literal \\n leaks; head -n1 works) =="
setup
printf '{"prompt":"line one\\nline two \\"q\\"","sessionId":"s"}' | bash "$BANNER" prompt-hook --runtime=copilot >/dev/null 2>&1
assert_eq "asked is first decoded line only" "line one" "$(sfield asked)"
assert_hasnt "asked has no literal backslash-n" "$(sfield asked)" '\n'
teardown

# ---------------------------------------------------------------------------
echo "== injection: crafted PR / asked cannot forge a clickable link =="
setup
bash "$BANNER" set --title T --pr "https://github.com/o/r/pull/1" >/dev/null 2>&1
assert_has "valid PR renders as a link" "$(banner)" "[https://github.com/o/r/pull/1](https://github.com/o/r/pull/1)"
bash "$BANNER" set --title T --pr "x](https://evil.example/phish" >/dev/null 2>&1
assert_hasnt "crafted PR does not forge a link" "$(banner)" "x](https://evil.example/phish"
bash "$BANNER" set --title T --asked "[click](https://evil.example)" >/dev/null 2>&1
assert_hasnt "markdown in asked is escaped, not a link" "$(banner)" "[click](https://evil.example)"
teardown

# ---------------------------------------------------------------------------
echo "== state self-heals from corruption (no permanent blank wedge) =="
setup
bash "$BANNER" set --title First >/dev/null 2>&1
sf=$(ls "$TMP"/.config/ghoztty/banner-state/*.json 2>/dev/null | head -1)
printf 'not json{{{' > "$sf"          # corrupt it
bash "$BANNER" set --title Second >/dev/null 2>&1
valid=$(state | jq -e '.title=="Second"' >/dev/null 2>&1 && echo 1 || echo 0)
assert_eq "merge resets corrupt state and applies update" "1" "$valid"
# No fixed shared temp file is left behind.
assert_eq "no fixed .json.tmp temp file" "" "$(ls "$TMP"/.config/ghoztty/banner-state/*.json.tmp 2>/dev/null)"
teardown

# ---------------------------------------------------------------------------
echo "== concurrent merges keep the state file valid JSON =="
setup
bash "$BANNER" set --title Base >/dev/null 2>&1
for i in 1 2 3 4 5 6; do bash "$BANNER" set --status "s$i" >/dev/null 2>&1 & done
wait
valid=$(state | jq empty >/dev/null 2>&1 && echo 1 || echo 0)
assert_eq "state is valid JSON after concurrent writes" "1" "$valid"
teardown

echo
if [ "$fails" -eq 0 ]; then
    echo "PASS: all ghoztty-banner tests passed"
    exit 0
fi
echo "FAIL: $fails assertion(s) failed"
exit 1
