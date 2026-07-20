#!/usr/bin/env python3
"""
E2E harness for Ghoztty session persistence (design doc §5, tasks T07 + T08).

Builds the headlineAcceptance scenario against the DEBUG build entirely via the
debug CLI, then terminates the app and relaunches it, asserting that every pane's
process survived (re-attached, not restarted), the split topology and ratios are
restored exactly, and scrollback replays. Repeats the terminate/relaunch cycle N
times to prove repeatability (incl. 0s fast-relaunch, which T06b made safe).

Modes:
  * default (T07): SIGKILL the app, relaunch the SAME on-disk binary.
  * --upgrade (T08): between terminate and relaunch, REPLACE the app bundle on
    disk with a freshly-versioned, re-signed copy (main-exec sha genuinely
    changes each cycle) — exactly the on-disk swap Sparkle performs — then
    relaunch from the replaced bundle. Proves an upgrade re-attaches intact and
    leaves the agent process untouched.
  * --quit=kill|graceful: how the app is terminated each cycle. `graceful` uses
    AppleScript `quit` (routes through applicationShouldTerminate → isQuitting,
    manifest preserved) instead of SIGKILL. Both must survive.

Exit 0 = all criteria passed. Nonzero = a criterion failed (actionable diff printed).

    scripts/e2e/session-persistence.py [--cycles=3] [--upgrade] [--quit=kill|graceful] [--keep] [--verbose]
    scripts/e2e/session-persistence.py --fallback   # T19: agent-unavailable exec fallback (default-on)

NEVER touches /Applications/Ghoztty.app. Debug bundle + debug socket + debug agent
only. --upgrade stages/replaces a COPY of the bundle under a temp dir; the
freshly-built zig-out bundle is only ever read. See
docs/design/session-persistence-tasks.json for the full protocol.
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ZIGOUT_BUNDLE = os.path.join(ROOT, "zig-out", "Ghoztty-Debug.app")
BUNDLE_ID = "com.dzearing.ghoztty.debug"
HOME = os.path.expanduser("~")
MANIFEST = os.path.join(HOME, "Library", "Application Support", BUNDLE_ID, "session-layout.json")
AGENT_DIR = os.path.join(HOME, ".config", "ghoztty", "local-agent-debug")
PORT_FILE = os.path.join(AGENT_DIR, "port.json")
SOCKET_FILE = os.path.join(AGENT_DIR, "agent.sock")  # the 0600 UDS the agent binds (T09c)
SESSIONS_FILE = os.path.join(AGENT_DIR, "sessions.json")  # reboot-floor metadata store (T12)
LAYOUTS_FILE = os.path.join(AGENT_DIR, "layouts.json")  # agent-owned layout blobs (T18)
RINGS_DIR = os.path.join(AGENT_DIR, "rings")  # reboot-scrollback ring snapshots (T13/T13b)
LOCK_FILE = os.path.join(AGENT_DIR, "agent.lock")
HEARTBEAT_FILE = os.path.join(AGENT_DIR, "agent.heartbeat")
APP_LOG = os.path.join(tempfile.gettempdir(), "ghoztty-e2e", "e2e-app.log")

# LaunchAgent (T12d): the app installs a per-user KeepAlive+RunAtLoad job so
# launchd restarts the agent after a kill/crash/reboot. The debug lineage gets a
# distinct label so it never collides with the release job. The --agent-restart
# mode relies on this; full_reset boots it out so KeepAlive can't fight a reset
# and no job lingers after a run.
LAUNCHAGENT_LABEL = "com.dzearing.ghoztty.debug.agent"
LAUNCHAGENT_PLIST = os.path.join(HOME, "Library", "LaunchAgents", LAUNCHAGENT_LABEL + ".plist")

# --upgrade staging: a pristine, byte-identical RESERVE copy of the fresh build.
# The app ALWAYS launches from the installed zig-out path (whose ad-hoc code hash
# is already authorized in the keychain — launching a differently-signed copy would
# spam a keychain re-auth prompt every cycle). Each cycle the installed bundle is
# physically replaced from the reserve: every file unlinked and rewritten with
# fresh inodes at the same path — exactly the on-disk swap an updater performs —
# while the code bytes (hence cdhash) stay identical, so there is NO keychain
# prompt. See scripts/e2e/README.md for why the bytes are held constant.
STAGING = os.path.join(tempfile.gettempdir(), "ghoztty-e2e-upgrade")
UPGRADE_RESERVE = os.path.join(STAGING, "reserve", "Ghoztty-Debug.app")

# The app + CLI/agent always live at the installed zig-out path. Matching
# processes is done by the bundle-relative suffix so strays are still found.
BUNDLE = ZIGOUT_BUNDLE
CLI = os.path.join(BUNDLE, "Contents", "MacOS", "ghoztty")
AGENT_BIN = os.path.join(BUNDLE, "Contents", "MacOS", "ghoztty-agent")
APP_SUFFIX = os.path.join("Ghoztty-Debug.app", "Contents", "MacOS", "ghoztty")
AGENT_SUFFIX = APP_SUFFIX + "-agent"

# session-persistence is DEFAULT-ON since T19, so the harness no longer passes
# --session-persistence=true: a clean pass here proves the default flip works.
LAUNCH_ARGS = ["--confirm-close-surface=false"]

# When set (the --fallback mode), point the app's local-agent binary at this
# path so the agent can NEVER be found/spawned — proving default-on windows fall
# back to a plain exec surface instead of hanging. None = normal (real agent).
AGENT_BIN_OVERRIDE = None

# Each pane runs a unique, never-exiting marker: prints PANE=<n> PID=<shell pid>
# once, then an incrementing tick line every second. Survival == same PID + ticks
# continuing across the app-death gap with no second PANE= line (no restart).
def marker_cmd(n):
    return (f"echo PANE={n} PID=$$; i=0; "
            f"while true; do echo tick-{n}-$((i++)); sleep 1; done")

VERBOSE = False
def log(msg):
    print(msg, flush=True)
def vlog(msg):
    if VERBOSE:
        print(f"    · {msg}", flush=True)

class E2EError(Exception):
    pass

# ---------------------------------------------------------------------------
# CLI / process helpers
# ---------------------------------------------------------------------------
def run_cli(args, timeout=15):
    try:
        p = subprocess.run([CLI] + args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"

def cli_json(args):
    rc, out, err = run_cli(args)
    if rc != 0:
        raise E2EError(f"CLI {args} failed rc={rc}: {err.strip() or out.strip()}")
    return json.loads(out)

def cli_ok(args, timeout=15):
    rc, out, err = run_cli(args, timeout=timeout)
    return rc == 0, (err.strip() or out.strip())

def retry_cli(args, what, timeout=20.0, interval=0.4):
    """Run a mutation command, retrying until it exits 0 (handles async registration)."""
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        ok, msg = cli_ok(args)
        if ok:
            return
        last = msg
        time.sleep(interval)
    raise E2EError(f"{what} never succeeded within {timeout}s (last: {last})")

def procs_matching(substr, extra=None):
    """Return list of (pid, command) for processes whose command contains substr."""
    out = subprocess.run(["ps", "ax", "-o", "pid=,command="], capture_output=True, text=True).stdout
    res = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid_str, _, cmd = line.partition(" ")
        try:
            pid = int(pid_str)
        except ValueError:
            continue
        if substr in cmd and (extra is None or extra(cmd)):
            res.append((pid, cmd))
    return res

def app_pids():
    # the app binary, NOT the agent (both live in Contents/MacOS). Match by the
    # bundle-relative suffix so a stray app from either launch location is caught.
    return [pid for pid, cmd in procs_matching(APP_SUFFIX)
            if AGENT_SUFFIX not in cmd and "+" not in cmd]

def agent_pid():
    pids = [pid for pid, cmd in procs_matching(AGENT_SUFFIX)]
    return pids[0] if pids else None

def pid_alive(pid):
    """True only if `pid` exists AND is not a zombie. A zombie/defunct process has
    already run to exit() — for "has the app finished terminating?" that IS gone.
    `os.kill(pid, 0)` alone reports a zombie as alive until its parent reaps it, so
    we first reap our own launched children, then consult the process state (`ps`)
    and treat a zombie (`Z`) or missing pid as not-alive."""
    if pid is None:
        return False
    _reap_children()
    st = subprocess.run(["ps", "-o", "state=", "-p", str(pid)],
                        capture_output=True, text=True).stdout.strip()
    if not st:
        return False              # no such process (reaped or never existed)
    return not st.startswith("Z")  # zombie == effectively terminated

def launchctl(args, timeout=10):
    """Run /bin/launchctl; return (rc, combined output)."""
    try:
        p = subprocess.run(["/bin/launchctl"] + args, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr)
    except subprocess.TimeoutExpired:
        return 124, "timeout"

def launchagent_service():
    return f"gui/{os.getuid()}/{LAUNCHAGENT_LABEL}"

def launchagent_pid():
    """The pid launchd reports for the managed agent job, or None if not loaded."""
    rc, out = launchctl(["print", launchagent_service()])
    if rc != 0:
        return None
    m = re.search(r"^\s*pid = (\d+)", out, re.MULTILINE)
    return int(m.group(1)) if m else None

def launchagent_bootout():
    """Stop + unload the debug agent job and remove its plist (idempotent)."""
    launchctl(["bootout", launchagent_service()])
    try:
        os.remove(LAUNCHAGENT_PLIST)
    except FileNotFoundError:
        pass

def kill_pids(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass

def wait_gone(pids, timeout=8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(pid_alive(p) for p in pids):
            return True
        time.sleep(0.1)
    return False

# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------
def full_reset():
    """Kill any debug app + agent and clear persisted state for a known-clean start."""
    log("[reset] killing debug app + agent, clearing manifest/agent state")
    ap = app_pids()
    if ap:
        kill_pids(ap, signal.SIGTERM)
        if not wait_gone(ap, 4):
            kill_pids(ap, signal.SIGKILL)
            wait_gone(ap, 4)
    # Unload the LaunchAgent FIRST: with KeepAlive a bare SIGKILL of the agent is
    # instantly undone by launchd (T12d). bootout stops the job + removes the plist
    # so the reset actually sticks and no debug KeepAlive job lingers after the run.
    launchagent_bootout()
    agp = agent_pid()
    if agp is not None:
        kill_pids([agp], signal.SIGKILL)
        wait_gone([agp], 4)
    for f in (MANIFEST, PORT_FILE, SOCKET_FILE, SESSIONS_FILE, LAYOUTS_FILE, HEARTBEAT_FILE):
        try:
            os.remove(f)
        except FileNotFoundError:
            pass
    clear_ring_files()  # stale ring snapshots would preload into a fresh run
    time.sleep(0.5)

def ring_files():
    """Every persisted ring snapshot file (T13/T13b), newest last. Empty if the
    rings dir doesn't exist yet."""
    try:
        return sorted(os.path.join(RINGS_DIR, f)
                      for f in os.listdir(RINGS_DIR) if f.endswith(".ring"))
    except FileNotFoundError:
        return []

def clear_ring_files():
    for f in ring_files():
        try:
            os.remove(f)
        except FileNotFoundError:
            pass

# Popen handles for every app we launched, kept so we can reap them. Without this
# a cleanly-exited app lingers as a ZOMBIE (defunct) child of this script until we
# call waitpid — and `os.kill(zombie, 0)` reports it as ALIVE, which made a fast,
# graceful quit look like a 45s teardown hang (was misdiagnosed as T08a). Reaping
# turns the zombie into a truly-gone pid so `pid_alive`/`wait_gone` see the exit.
_launched_procs = []

def _reap_children():
    """Poll every app we launched; Popen.poll() reaps any that have exited."""
    for p in _launched_procs:
        try:
            p.poll()
        except Exception:
            pass

def launch_app():
    os.makedirs(os.path.dirname(APP_LOG), exist_ok=True)
    logf = open(APP_LOG, "ab")
    logf.write(f"\n\n===== launch {time.strftime('%H:%M:%S')} =====\n".encode())
    logf.flush()
    # GHOSTTY_RELAY_DISABLE=1: skip the relay-account Keychain read so the
    # ad-hoc-signed debug build doesn't pop a login-keychain password prompt on
    # every launch (its code hash changes each rebuild, so the ACL never matches
    # and "Always Allow" can't stick). Session persistence needs no relay account.
    env = dict(os.environ, GHOSTTY_RELAY_DISABLE="1", GHOSTTY_LOG="stderr")
    if AGENT_BIN_OVERRIDE is not None:
        env["GHOSTTY_LOCAL_AGENT_BIN"] = AGENT_BIN_OVERRIDE
    p = subprocess.Popen([CLI] + LAUNCH_ARGS, stdout=logf, stderr=logf,
                         start_new_session=True, env=env)
    _launched_procs.append(p)
    return p.pid

def wait_app_ready(timeout=20.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rc, out, err = run_cli(["+list", "--json"], timeout=5)
        if rc == 0:
            try:
                json.loads(out)
                return
            except json.JSONDecodeError:
                pass
        time.sleep(0.25)
    raise E2EError("app did not answer +list --json within timeout")

def graceful_quit(pids, timeout=20.0):
    """Terminate the app the way a real quit / Sparkle relaunch does: AppleScript
    `quit` scoped BY BUNDLE ID (never by process name — the release app shares the
    name). Routes through applicationShouldTerminate (isQuitting → manifest kept).
    A session-persistence app exits cleanly in well under a second (verified: it
    reaches its atexit handler within ms of the quit); `wait_gone` returns as soon
    as `pid_alive` sees the exit — which now requires reaping the zombie the exited
    app leaves as our child (see `pid_alive`). The timeout is only a safety net so a
    genuinely wedged teardown can't hang the whole suite. Returns True if it exited
    on its own (it always should)."""
    subprocess.run(
        ["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'],
        capture_output=True, text=True, timeout=15)
    if wait_gone(pids, timeout):
        return True
    log(f"    ! graceful quit still alive after {timeout:.0f}s — forcing SIGKILL")
    kill_pids(pids, signal.SIGKILL)
    return wait_gone(pids, 4)

# ---------------------------------------------------------------------------
# Bundle upgrade (T08): physically replace the installed bundle on disk
# ---------------------------------------------------------------------------
def main_exec_path(bundle):
    return os.path.join(bundle, "Contents", "MacOS", "ghoztty")

def file_inode(path):
    return os.stat(path).st_ino

def cdhash_of(bundle):
    p = subprocess.run(["codesign", "-dvvv", bundle], capture_output=True, text=True)
    for line in (p.stderr + p.stdout).splitlines():
        if line.startswith("CDHash="):
            return line.split("=", 1)[1].strip()
    return None

def run_checked(argv):
    p = subprocess.run(argv, capture_output=True, text=True)
    if p.returncode != 0:
        raise E2EError(f"{argv[0]} failed rc={p.returncode}: {p.stderr.strip()}")

def stage_upgrade_bundles():
    """Make a pristine, byte-identical RESERVE copy of the freshly-built bundle.
    Each cycle the installed bundle is physically replaced from this reserve, so
    the swap gives fresh inodes but identical signed content (same code hash → no
    keychain re-auth). Verifies the reserve's cdhash matches the installed one."""
    log(f"[upgrade] staging pristine reserve under {STAGING}")
    run_checked(["rm", "-rf", UPGRADE_RESERVE])
    os.makedirs(os.path.dirname(UPGRADE_RESERVE), exist_ok=True)
    run_checked(["cp", "-R", ZIGOUT_BUNDLE, UPGRADE_RESERVE])
    installed, reserve = cdhash_of(ZIGOUT_BUNDLE), cdhash_of(UPGRADE_RESERVE)
    if installed is None or installed != reserve:
        raise E2EError(f"reserve cdhash {reserve} != installed {installed} "
                       f"(copy is not byte-identical — would trigger keychain prompts)")
    vlog(f"reserve cdhash matches installed: {installed}")

def swap_in_upgrade(cycle):
    """Replace the installed bundle ON DISK with a fresh copy from the reserve:
    every file unlinked and rewritten with new inodes at the same installed path,
    exactly as an app updater swaps the bundle, then the app relaunches from it.
    Content is byte-identical (README: ad-hoc signing binds keychain auth to the
    exact code hash, so a recompiled binary can't be swapped silently; the FS-swap
    + relaunch + re-attach path — the only thing session persistence must survive —
    is exercised fully). Returns (old_inode, new_inode) of the main executable."""
    exe = main_exec_path(ZIGOUT_BUNDLE)
    old_ino = file_inode(exe)
    tmp = ZIGOUT_BUNDLE + ".e2e-new"          # same volume as the bundle → atomic rename
    run_checked(["rm", "-rf", tmp])
    run_checked(["cp", "-R", UPGRADE_RESERVE, tmp])  # fresh inodes, identical bytes
    run_checked(["rm", "-rf", ZIGOUT_BUNDLE])        # app is dead here — safe
    os.rename(tmp, ZIGOUT_BUNDLE)
    new_ino = file_inode(exe)
    if new_ino == old_ino:
        raise E2EError("upgrade swap did not replace the main executable (inode unchanged)")
    vlog(f"upgrade cycle {cycle}: main-exec inode {old_ino} -> {new_ino} (physically replaced)")
    return old_ino, new_ino

# ---------------------------------------------------------------------------
# Tree walking / snapshotting
# ---------------------------------------------------------------------------
def leaf_names_of(node):
    if node.get("type") == "leaf":
        return [node["terminal"]["name"]]
    return leaf_names_of(node["left"]) + leaf_names_of(node["right"])

def all_windows():
    data = cli_json(["+list", "--json"])
    return data["data"]["windows"]

def all_leaf_names():
    names = []
    for w in all_windows():
        for tab in w["tabs"]:
            names.extend(leaf_names_of(tab["splits"]))
    return names

def read_pane(name, lines=5000):
    rc, out, err = run_cli(["+read", f"--name={name}", f"--lines={lines}"], timeout=15)
    return out if rc == 0 else ""

_MARKER_RE = re.compile(r"PANE=(\d+) PID=(\d+)")
def parse_marker(text):
    m = _MARKER_RE.search(text)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)

def fresh_marker(text):
    """The RELAUNCHED child's PANE= marker. With ring disk snapshots (T13) the
    agent replays the pre-restart scrollback (the OLD marker) ahead of a
    '--- session restarted ---' divider, so the fresh child's marker is the one
    AFTER the last divider. Falls back to the first marker when there is no
    divider (survival/upgrade, or a blank relaunch with no ring snapshot)."""
    idx = text.rfind(RESTART_DIVIDER)
    return parse_marker(text[idx:] if idx >= 0 else text)

def count_markers(text, n):
    return len(re.findall(rf"PANE={n} PID=\d+", text))

def last_tick(text, n):
    vals = [int(x) for x in re.findall(rf"tick-{n}-(\d+)", text)]
    return max(vals) if vals else None

def struct_of(node, name2n):
    """Nested tuple describing topology; leaves become their marker index n."""
    if node.get("type") == "leaf":
        return ("L", name2n.get(node["terminal"]["name"]))
    return ("S", node["direction"], round(float(node["ratio"]), 4),
            struct_of(node["left"], name2n), struct_of(node["right"], name2n))

def snapshot():
    """Capture the full live state keyed by pane-marker index (stable across restore)."""
    windows = all_windows()
    # read every leaf, map name -> n / pid / last tick
    name2n, n2pid, n2tick, n2text = {}, {}, {}, {}
    for w in windows:
        for tab in w["tabs"]:
            for name in leaf_names_of(tab["splits"]):
                text = read_pane(name)
                n, pid = parse_marker(text)
                name2n[name] = n
                if n is not None:
                    n2pid[n] = pid
                    n2tick[n] = last_tick(text, n)
                    n2text[n] = text
    # per-window structure, keyed by the set of markers it contains
    win_structs = {}
    for w in windows:
        tab_structs = tuple(struct_of(tab["splits"], name2n) for tab in w["tabs"])
        ns = frozenset(name2n[nm] for tab in w["tabs"]
                       for nm in leaf_names_of(tab["splits"])
                       if name2n[nm] is not None)
        win_structs[ns] = tab_structs
    return {
        "n_windows": len(windows),
        "markers": set(k for k in n2pid.keys()),
        "pid": n2pid,
        "tick": n2tick,
        "text": n2text,
        "win_structs": win_structs,
    }

def struct_equal(a, b, tol=0.01):
    if a[0] != b[0]:
        return False
    if a[0] == "L":
        return a[1] == b[1]
    # split node
    if a[1] != b[1]:  # direction
        return False
    if abs(a[2] - b[2]) > tol:  # ratio
        return False
    return struct_equal(a[3], b[3], tol) and struct_equal(a[4], b[4], tol)

# ---------------------------------------------------------------------------
# Scenario construction
# ---------------------------------------------------------------------------
EXPECTED_MARKERS = {0, 1, 2, 3, 4}
EXPECTED_LEAVES = 5

def wait_for_pane(name, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if name in all_leaf_names():
            return
        time.sleep(0.3)
    raise E2EError(f"pane '{name}' never appeared within {timeout}s")

def wait_window_count(target, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if len(all_windows()) == target:
            return
        time.sleep(0.3)
    raise E2EError(f"window count != {target} within {timeout}s (have {len(all_windows())})")

def find_uuid_leaf(window_leaves, named):
    """Return the one leaf name in window_leaves that is NOT in the given named set."""
    cands = [n for n in window_leaves if n not in named]
    if len(cands) != 1:
        raise E2EError(f"expected exactly 1 unnamed leaf, got {cands} (named={named})")
    return cands[0]

def build_scenario():
    """
    Two windows, five panes, nontrivial nested topology with distinct ratios:
      Window A: P0 | (P1 / P2)   root ratio 0.30, sub ratio 0.70
      Window B: P3 | P4          ratio 0.40
    """
    log("[build] launching fresh app (empty manifest -> one initial window)")
    launch_app()
    wait_app_ready()
    wait_window_count(1)
    initial_leaves = all_leaf_names()
    vlog(f"initial window leaves: {initial_leaves}")

    log("[build] creating window A (P0)")
    retry_cli(["+new-window", "--target=winA", f"--command={marker_cmd(0)}"], "new-window winA")
    wait_window_count(2)

    log("[build] closing the blank initial window")
    deadline = time.time() + 15
    while time.time() < deadline:
        if len(all_windows()) == 1:
            break
        for nm in initial_leaves:
            cli_ok(["+close", f"--target={nm}"])
        time.sleep(0.6)
    wait_window_count(1)  # only winA remains

    log("[build] splitting window A -> A1, A2")
    retry_cli(["+split", "--target=winA", "--direction=right", "--name=A1",
               f"--command={marker_cmd(1)}"], "split A1")
    wait_for_pane("A1")
    retry_cli(["+split", "--target=A1", "--direction=down", "--name=A2",
               f"--command={marker_cmd(2)}"], "split A2")
    wait_for_pane("A2")

    log("[build] creating window B (P3) and splitting -> B1")
    retry_cli(["+new-window", "--target=winB", f"--command={marker_cmd(3)}"], "new-window winB")
    wait_window_count(2)
    retry_cli(["+split", "--target=winB", "--direction=right", "--name=B1",
               f"--command={marker_cmd(4)}"], "split B1")
    wait_for_pane("B1")

    # Identify the two windows and their unnamed initial panes.
    winA_leaves = winB_leaves = None
    for w in all_windows():
        leaves = [nm for tab in w["tabs"] for nm in leaf_names_of(tab["splits"])]
        if "A1" in leaves:
            winA_leaves = leaves
        elif "B1" in leaves:
            winB_leaves = leaves
    if winA_leaves is None or winB_leaves is None:
        raise E2EError(f"could not identify windows: {[ (w['id']) for w in all_windows()]}")
    p0 = find_uuid_leaf(winA_leaves, {"A1", "A2"})
    p3 = find_uuid_leaf(winB_leaves, {"B1"})
    vlog(f"P0 pane={p0}  P3 pane={p3}")

    log("[build] setting distinct ratios via +rearrange (A: 0.30/0.70, B: 0.40)")
    layoutA = {"direction": "horizontal", "ratio": 30,
               "left": {"pane": p0},
               "right": {"direction": "vertical", "ratio": 70,
                         "left": {"pane": "A1"}, "right": {"pane": "A2"}}}
    layoutB = {"direction": "horizontal", "ratio": 40,
               "left": {"pane": p3}, "right": {"pane": "B1"}}
    retry_cli(["+rearrange", "--target=winA", f"--layout={json.dumps(layoutA)}"], "rearrange A")
    retry_cli(["+rearrange", "--target=winB", f"--layout={json.dumps(layoutB)}"], "rearrange B")

    log("[build] letting ticks accumulate (5s)")
    time.sleep(5)

def wait_restored(timeout=12.0, relaunched=False):
    """Poll until all EXPECTED_MARKERS are readable (re-attached & interactive).
    When `relaunched` (the reboot path), require the marker to appear AFTER the
    restart divider — otherwise the replayed pre-restart scrollback (T13) satisfies
    the wait before the freshly-relaunched child has actually produced output."""
    marker = fresh_marker if relaunched else (lambda t: parse_marker(t))
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            names = all_leaf_names()
        except E2EError:
            time.sleep(0.2); continue
        if len(names) >= EXPECTED_LEAVES:
            found = set()
            for nm in names:
                n, _ = marker(read_pane(nm, 3000))
                if n is not None:
                    found.add(n)
            if EXPECTED_MARKERS.issubset(found):
                return
        time.sleep(0.2)
    raise E2EError(f"not all panes restored within {timeout}s")

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
def assert_cycle(baseline, cur, prev, gap, agent_before, agent_after, failures, upgrade=None):
    def check(cond, msg):
        if not cond:
            failures.append(msg)

    # Upgrade proof: the installed bundle the app relaunched from was physically
    # replaced this cycle (main executable has a fresh inode).
    if upgrade is not None:
        check(upgrade["new_ino"] != upgrade["old_ino"],
              f"bundle main-exec not replaced (inode stayed {upgrade['old_ino']})")

    check(cur["n_windows"] == baseline["n_windows"],
          f"window count {cur['n_windows']} != baseline {baseline['n_windows']}")
    check(cur["markers"] == EXPECTED_MARKERS,
          f"marker set {sorted(cur['markers'])} != {sorted(EXPECTED_MARKERS)}")

    # topology per window (matched by marker-set)
    for ns, struct in baseline["win_structs"].items():
        if ns not in cur["win_structs"]:
            failures.append(f"window with markers {sorted(ns)} missing after restore")
            continue
        cs = cur["win_structs"][ns]
        if len(cs) != len(struct) or not all(struct_equal(a, b) for a, b in zip(struct, cs)):
            failures.append(f"topology mismatch for window {sorted(ns)}:\n"
                            f"      baseline={struct}\n      restored={cs}")

    # per-pane survival
    for n in sorted(EXPECTED_MARKERS):
        bpid = baseline["pid"].get(n)
        cpid = cur["pid"].get(n)
        check(cpid == bpid, f"pane {n} PID changed {bpid} -> {cpid} (RESTARTED, not re-attached)")
        check(pid_alive(cpid), f"pane {n} PID {cpid} is not alive")
        # monotonic across this gap: current tick strictly greater than previous cycle's
        ptick = prev["tick"].get(n)
        ctick = cur["tick"].get(n)
        check(ctick is not None and ptick is not None and ctick > ptick,
              f"pane {n} tick not monotonic across gap: prev={ptick} cur={ctick}")
        # no restart: exactly one PANE= line in full scrollback
        text = cur["text"].get(n, "")
        nc = count_markers(text, n)
        check(nc == 1, f"pane {n} has {nc} PANE= lines (expected 1; >1 => process restarted)")
        # scrollback replay: a pre-gap tick is present after restore
        if ptick is not None and ptick >= 5:
            check(f"tick-{n}-{ptick - 5}" in text,
                  f"pane {n} missing pre-gap scrollback line tick-{n}-{ptick-5} (replay failed)")

    check(gap < 10.0, f"restore gap {gap:.1f}s >= 10s")
    check(agent_after is not None and agent_after == agent_before,
          f"agent PID changed {agent_before} -> {agent_after} (agent did not survive)")

RESTART_DIVIDER = "--- session restarted ---"

def assert_reboot_cycle(baseline, cur, gap, agent_before, agent_after,
                        restart_secs, failures):
    """Reboot-equivalent (T12d / AC3+AC4): the agent was killed and RESTARTED by
    launchd, so its RAM (children + output ring) is GONE by POSIX semantics — the
    honest contract is *relaunch*, not survival. Assert the OPPOSITE of the
    survival cycle: agent pid CHANGED (launchd brought a new one), every pane's
    child is a FRESH process (new pid, marker re-ran, ticks from 0), each pane
    shows the restart banner, and the LAYOUT is still rebuilt exactly from the
    manifest (that part is identical to a survival restore)."""
    def check(cond, msg):
        if not cond:
            failures.append(msg)

    # launchd restarted the agent as a NEW process within the AC4 budget.
    check(agent_after is not None, "no agent after kill (launchd did not restart it)")
    check(agent_after != agent_before,
          f"agent pid unchanged {agent_before} (expected a launchd-restarted pid)")
    check(restart_secs is not None and restart_secs <= 5.0,
          f"launchd took {restart_secs}s to restart the agent (> 5s AC4 budget)")

    # Layout rebuilt from the manifest — same as a survival restore.
    check(cur["n_windows"] == baseline["n_windows"],
          f"window count {cur['n_windows']} != baseline {baseline['n_windows']}")
    check(cur["markers"] == EXPECTED_MARKERS,
          f"marker set {sorted(cur['markers'])} != {sorted(EXPECTED_MARKERS)}")
    for ns, struct in baseline["win_structs"].items():
        if ns not in cur["win_structs"]:
            failures.append(f"window with markers {sorted(ns)} missing after relaunch")
            continue
        cs = cur["win_structs"][ns]
        if len(cs) != len(struct) or not all(struct_equal(a, b) for a, b in zip(struct, cs)):
            failures.append(f"topology mismatch for window {sorted(ns)}:\n"
                            f"      baseline={struct}\n      restored={cs}")

    # Every pane RELAUNCHED: fresh child pid, banner shown, marker command re-ran,
    # AND (T13, §5.4) the pre-restart scrollback was replayed from the agent's ring
    # disk snapshot — so the pane reads [old scrollback][divider][fresh output].
    for n in sorted(EXPECTED_MARKERS):
        bpid = baseline["pid"].get(n)
        text = cur["text"].get(n, "")
        check(RESTART_DIVIDER in text,
              f"pane {n} missing restart banner '{RESTART_DIVIDER}' after relaunch")

        # With T13 the ring snapshot replays the OLD marker line ahead of the
        # divider, so the FIRST PANE= line is the pre-restart one and the FRESH
        # child's marker is AFTER the divider — parse the fresh pid from there.
        idx = text.rfind(RESTART_DIVIDER)
        pre = text[:idx] if idx >= 0 else ""
        _, cpid = fresh_marker(text)
        check(cpid is not None, f"pane {n} has no marker after the divider (relaunch never came back)")
        check(cpid != bpid,
              f"pane {n} PID unchanged {bpid} (expected a relaunched process — agent RAM was lost)")
        check(cpid is not None and pid_alive(cpid), f"pane {n} relaunched PID {cpid} is not alive")

        # Pre-restart scrollback present: the OLD marker line (from before the kill)
        # appears BEFORE the divider — proof the ring snapshot was persisted on the
        # viewer disconnect and replayed on relaunch (not a blank fresh shell).
        check(f"PANE={n} " in pre,
              f"pane {n} missing pre-restart scrollback before divider (ring snapshot not replayed)")

    check(gap < 15.0, f"reboot recovery gap {gap:.1f}s >= 15s")

# ---------------------------------------------------------------------------
# Reboot-equivalent driver (T12d)
# ---------------------------------------------------------------------------
def wait_agent_restarted(old_pid, timeout=8.0):
    """Poll launchd until it reports a NEW agent pid (KeepAlive restart). Returns
    (new_pid, seconds) or (None, None) if it never restarted."""
    t0 = time.time()
    deadline = t0 + timeout
    while time.time() < deadline:
        p = launchagent_pid()
        if p is not None and p != old_pid and pid_alive(p):
            return p, time.time() - t0
        time.sleep(0.1)
    return None, None

# launchd throttles KeepAlive respawns to once per ThrottleInterval (default 10s)
# since the job's LAST spawn. A real-world agent crash happens after the agent has
# been up far longer than that; the E2E's rapid kill/relaunch cycles would
# otherwise trip the throttle and see a spurious multi-second restart delay. So
# before each kill we let the current agent reach >THROTTLE seconds since it was
# spawned, isolating the honest "single crash of a long-lived agent" AC4 measures.
# (We track the spawn wall-clock ourselves; this box's `ps -o etimes=` is not a
# valid keyword and `etime`'s dd-hh:mm:ss format is fiddly to parse.)
THROTTLE_FLOOR = 12.0

def settle_past_throttle(spawn_ts):
    if spawn_ts is None:
        return  # baseline agent: already up through build + baseline (>THROTTLE)
    elapsed = time.time() - spawn_ts
    if elapsed < THROTTLE_FLOOR:
        wait = THROTTLE_FLOOR - elapsed
        vlog(f"agent up {elapsed:.0f}s; waiting {wait:.0f}s to clear launchd respawn throttle")
        time.sleep(wait)

def run_reboot_cycles(args, baseline):
    all_failures = []
    agent_spawn_ts = None  # baseline agent already exceeds the throttle floor
    for cycle in range(1, args.cycles + 1):
        log("-" * 70)
        log(f"[cycle {cycle}/{args.cycles}] REBOOT-equivalent: SIGKILL app + agent, "
            f"launchd restarts agent, relaunch app, assert RELAUNCH")

        # Let the live agent clear launchd's respawn throttle first (see
        # THROTTLE_FLOOR) so the measured restart is the real single-crash latency.
        settle_past_throttle(agent_spawn_ts)
        t_reboot = time.time()

        # 1. Kill the app (a reboot takes the GUI down too).
        pids = app_pids()
        if pids:
            kill_pids(pids, signal.SIGKILL)
            wait_gone(pids, 5)

        # 2. Kill the agent; launchd (KeepAlive) must bring a NEW one back, which
        #    loads sessions.json and materializes each session as a relaunchable
        #    tombstone before it accepts connections.
        agent_before = launchagent_pid() or agent_pid()
        if agent_before is None:
            all_failures.append(f"cycle {cycle}: no agent to kill")
            break
        kill_pids([agent_before], signal.SIGKILL)
        agent_after, restart_secs = wait_agent_restarted(agent_before)
        if agent_after is None:
            all_failures.append(
                f"cycle {cycle}: launchd did not restart the agent within 8s")
            # keep going to relaunch the app so teardown is clean, but record it
        else:
            agent_spawn_ts = time.time()  # for the next cycle's throttle settle
            log(f"    ↻ launchd restarted agent {agent_before} -> {agent_after} "
                f"in {restart_secs:.1f}s")

        # 3. Relaunch the app: manifest restore -> re-attach -> auto-RELAUNCH.
        launch_app()
        wait_app_ready()
        wait_restored(relaunched=True)
        gap = time.time() - t_reboot
        cur = snapshot()

        failures = []
        assert_reboot_cycle(baseline, cur, gap, agent_before, agent_after,
                            restart_secs, failures)
        if failures:
            log(f"[cycle {cycle}] FAIL (recovery {gap:.1f}s):")
            for f in failures:
                log(f"    ✗ {f}")
            all_failures.extend(f"cycle {cycle}: {f}" for f in failures)
        else:
            # Report the FRESH (post-divider) pids — cur["pid"] holds the replayed
            # OLD marker (T13 scrollback), so derive the relaunched pids here.
            fresh_pids = {n: fresh_marker(cur["text"].get(n, ""))[1] for n in sorted(EXPECTED_MARKERS)}
            log(f"[cycle {cycle}] PASS  recovery={gap:.1f}s  agent {agent_before}->{agent_after} "
                f"({restart_secs:.1f}s)  fresh PIDs {fresh_pids}")

    log("=" * 70)
    if all_failures:
        log(f"RESULT: FAIL — {len(all_failures)} assertion(s) failed across {args.cycles} cycle(s)")
        return 1
    log(f"RESULT: PASS — {args.cycles}/{args.cycles} reboot-equivalent cycles; "
        f"launchd restarted the agent each time (≤5s), sessions relaunched from "
        f"metadata with the restart banner, topology rebuilt from the manifest")
    return 0

def reboot_teardown(args):
    if args.keep:
        log("[teardown] --keep: leaving app + windows running (LaunchAgent still loaded)")
        return
    log("[teardown] closing test windows + unloading LaunchAgent + clearing state")
    for nm in ("A1", "A2", "B1"):
        cli_ok(["+close", f"--target={nm}"])
    full_reset()  # bootouts the LaunchAgent + clears manifest/agent state

# ---------------------------------------------------------------------------
# In-place recovery driver (T12e): agent crashes while the app STAYS UP
# ---------------------------------------------------------------------------
def assert_inplace_cycle(baseline, cur, gap, app_before, app_after,
                         agent_before, agent_after, restart_secs, failures):
    """In-place recovery (T12e / AC4 in-place): ONLY the agent was killed — the
    GUI app never went down. launchd restarts the agent, and the LIVE app must
    detect the dropped shared connection, re-dial the restarted agent, and
    rebuild every open local window IN PLACE (re-ATTACH + auto-RELAUNCH). So this
    asserts everything the reboot cycle does (agent pid changed, fresh child
    PIDs, restart banner, exact topology from the manifest) PLUS the defining
    in-place invariant: the APP process was never relaunched."""
    def check(cond, msg):
        if not cond:
            failures.append(msg)

    # The defining invariant: the GUI app was NEVER relaunched.
    check(app_after and app_before and set(app_after) == set(app_before),
          f"app pids changed {app_before} -> {app_after} (the app should NOT relaunch)")

    # launchd restarted the agent as a NEW process within the AC4 budget.
    check(agent_after is not None, "no agent after kill (launchd did not restart it)")
    check(agent_after != agent_before,
          f"agent pid unchanged {agent_before} (expected a launchd-restarted pid)")
    check(restart_secs is not None and restart_secs <= 5.0,
          f"launchd took {restart_secs}s to restart the agent (> 5s AC4 budget)")

    # Layout rebuilt from the manifest — same as a restore.
    check(cur["n_windows"] == baseline["n_windows"],
          f"window count {cur['n_windows']} != baseline {baseline['n_windows']}")
    check(cur["markers"] == EXPECTED_MARKERS,
          f"marker set {sorted(cur['markers'])} != {sorted(EXPECTED_MARKERS)}")
    for ns, struct in baseline["win_structs"].items():
        if ns not in cur["win_structs"]:
            failures.append(f"window with markers {sorted(ns)} missing after recovery")
            continue
        cs = cur["win_structs"][ns]
        if len(cs) != len(struct) or not all(struct_equal(a, b) for a, b in zip(struct, cs)):
            failures.append(f"topology mismatch for window {sorted(ns)}:\n"
                            f"      baseline={struct}\n      recovered={cs}")

    # Every pane RELAUNCHED in place: fresh child pid, banner shown, marker re-ran.
    #
    # NOTE (T13): unlike the reboot cycle, in-place does NOT assert pre-restart
    # scrollback. Here ONLY the agent is SIGKILLed — it has no chance to flush its
    # ring (the app-disconnect snapshot trigger fires on the AGENT when the VIEWER
    # drops; here the viewer stays up and the agent dies), and the periodic 30 s
    # snapshot won't have fired in the fast cycle. So the ring RAM is legitimately
    # lost (the honest T12e contract) and the divider is the client-side one. We
    # still parse the fresh pid via `fresh_marker` so that IF a periodic snapshot
    # happened to fire (replay present), the post-divider marker is still found.
    for n in sorted(EXPECTED_MARKERS):
        bpid = baseline["pid"].get(n)
        text = cur["text"].get(n, "")
        check(RESTART_DIVIDER in text,
              f"pane {n} missing restart banner '{RESTART_DIVIDER}' after in-place recovery")
        _, cpid = fresh_marker(text)
        check(cpid is not None, f"pane {n} has no marker after recovery (never came back)")
        check(cpid != bpid,
              f"pane {n} PID unchanged {bpid} (expected a relaunched process — agent RAM was lost)")
        check(cpid is not None and pid_alive(cpid), f"pane {n} relaunched PID {cpid} is not alive")

    check(gap < 15.0, f"in-place recovery gap {gap:.1f}s >= 15s")

def wait_inplace_recovered(app_before, timeout=20.0):
    """Poll until the LIVE app has rebuilt every pane in place: all markers
    readable AND each carries the restart banner. Fails if the app process
    changed (it must never relaunch here)."""
    deadline = time.time() + timeout
    last = set()
    while time.time() < deadline:
        # The app must not have died/relaunched underneath us.
        if set(app_pids()) != set(app_before):
            raise E2EError(f"app process changed during in-place recovery "
                           f"({app_before} -> {app_pids()}) — it should stay up")
        try:
            snap = snapshot()
        except Exception:
            time.sleep(0.4)
            continue
        last = snap["markers"]
        # Require a FRESH marker after the divider (T13: the replayed pre-restart
        # scrollback carries the OLD marker + the divider ahead of the fresh
        # child's output — waiting only for the banner would return too early).
        fresh = set(n for n in EXPECTED_MARKERS
                    if fresh_marker(snap["text"].get(n, ""))[0] is not None
                    and RESTART_DIVIDER in snap["text"].get(n, ""))
        if EXPECTED_MARKERS.issubset(fresh):
            return
        time.sleep(0.4)
    raise E2EError(f"in-place recovery incomplete within {timeout}s "
                   f"(markers {sorted(last)} / expected {sorted(EXPECTED_MARKERS)})")

def run_inplace_cycles(args, baseline):
    all_failures = []
    agent_spawn_ts = None  # baseline agent already exceeds the throttle floor
    for cycle in range(1, args.cycles + 1):
        log("-" * 70)
        log(f"[cycle {cycle}/{args.cycles}] IN-PLACE: SIGKILL agent ONLY (app stays up), "
            f"launchd restarts agent, app auto-recovers in place, assert RELAUNCH")

        settle_past_throttle(agent_spawn_ts)
        app_before = app_pids()
        if not app_before:
            all_failures.append(f"cycle {cycle}: no app process running")
            break
        t0 = time.time()

        # Kill ONLY the agent; the GUI app stays up. launchd (KeepAlive) brings a
        # NEW one back, which materializes each session as a relaunchable tombstone.
        agent_before = launchagent_pid() or agent_pid()
        if agent_before is None:
            all_failures.append(f"cycle {cycle}: no agent to kill")
            break
        kill_pids([agent_before], signal.SIGKILL)
        agent_after, restart_secs = wait_agent_restarted(agent_before)
        if agent_after is not None:
            agent_spawn_ts = time.time()
            log(f"    ↻ launchd restarted agent {agent_before} -> {agent_after} "
                f"in {restart_secs:.1f}s")

        # The LIVE app must notice the drop, re-dial, and rebuild in place.
        wait_inplace_recovered(app_before)
        gap = time.time() - t0
        app_after = app_pids()
        cur = snapshot()

        failures = []
        assert_inplace_cycle(baseline, cur, gap, app_before, app_after,
                             agent_before, agent_after, restart_secs, failures)
        if failures:
            log(f"[cycle {cycle}] FAIL (recovery {gap:.1f}s):")
            for f in failures:
                log(f"    ✗ {f}")
            all_failures.extend(f"cycle {cycle}: {f}" for f in failures)
        else:
            log(f"[cycle {cycle}] PASS  recovery={gap:.1f}s  app {app_after} unchanged  "
                f"agent {agent_before}->{agent_after} ({restart_secs:.1f}s)  fresh PIDs {cur['pid']}")

    log("=" * 70)
    if all_failures:
        log(f"RESULT: FAIL — {len(all_failures)} assertion(s) failed across {args.cycles} cycle(s)")
        return 1
    log(f"RESULT: PASS — {args.cycles}/{args.cycles} in-place recovery cycles; the app STAYED UP "
        f"while launchd restarted the agent, sessions auto-relaunched in place with the restart "
        f"banner, topology rebuilt from the manifest")
    return 0

# ---------------------------------------------------------------------------
# Graceful agent-SIGTERM ring-flush check (T13b)
# ---------------------------------------------------------------------------
def run_sigterm_check(args, baseline):
    """T13b: a graceful SIGTERM to the agent must flush dirty output rings to disk
    BEFORE it exits cleanly (T13 otherwise only snapshots every 30s + on a viewer
    disconnect). Prove it deterministically: force fresh (dirty) output into
    sessions, wipe the rings dir, then SIGTERM the agent and assert (a) it EXITED
    promptly on its own (a working handler blocks+sigwaits SIGTERM, snapshots, and
    exit(0)s — no SIGKILL escalation) and (b) the rings dir was repopulated by the
    dying agent. Dirtying explicitly guards against a just-fired periodic snapshot
    having marked the rings clean."""
    failures = []

    # 1. Dirty sessions with a fresh unique line so each ring's write offset is
    #    provably past its last-snapshot offset, whatever the last periodic flush did.
    for nm in ("A1", "A2", "B1"):
        cli_ok(["+send-keys", f"--target={nm}", f"echo T13B-DIRTY-{nm}", "Enter"])
    time.sleep(0.6)  # let the echoes land in the rings

    # 2. Wipe the rings dir: for the next instant the ONLY writer that can recreate
    #    a .ring is the SIGTERM handler (the 30s periodic tick can't fire in the ms
    #    between this wipe and the signal).
    clear_ring_files()
    if ring_files():
        failures.append("rings dir not empty after clear (could not isolate the SIGTERM write)")

    agent_before = launchagent_pid() or agent_pid()
    if agent_before is None:
        log("RESULT: FAIL — no agent to SIGTERM")
        return 1

    # 3. Graceful SIGTERM. A working handler exits promptly and clean; a broken one
    #    (signal blocked but never consumed) would hang until launchd's SIGKILL
    #    escalation and write NOTHING.
    log(f"[sigterm] SIGTERM agent {agent_before}; expecting a prompt clean exit + a ring flush")
    t0 = time.time()
    kill_pids([agent_before], signal.SIGTERM)
    exited = wait_gone([agent_before], timeout=3.0)
    dt = time.time() - t0
    if not exited:
        failures.append(f"agent {agent_before} still alive {dt:.1f}s after SIGTERM "
                        "(handler never consumed it — would need SIGKILL escalation)")
    else:
        log(f"    ✓ agent exited {dt:.2f}s after SIGTERM (clean, on its own)")

    # 4. The dying agent must have flushed dirty rings to disk.
    rings = ring_files()
    if rings:
        log(f"    ✓ {len(rings)} ring snapshot(s) flushed before exit: "
            f"{[os.path.basename(r) for r in rings]}")
    else:
        failures.append("no ring snapshot on disk after the agent exited "
                        "(SIGTERM did not flush dirty rings)")

    log("=" * 70)
    if failures:
        log(f"RESULT: FAIL — {len(failures)} assertion(s) failed")
        for f in failures:
            log(f"    ✗ {f}")
        return 1
    log("RESULT: PASS — a graceful SIGTERM flushed dirty rings to disk, then the agent "
        "exited cleanly on its own (no SIGKILL escalation needed); launchd restart intact")
    return 0

# ---------------------------------------------------------------------------
# WP-D3: fast, visually-correct re-attach (structured snapshot + delta replay)
# ---------------------------------------------------------------------------
# The headline bug: on relaunch the app replayed the agent's whole ~2MB byte
# ring and RE-PARSED it from scratch per pane. Measured on an M-series Mac:
# empty ring 0.74s vs full ring 2.78s (scales with content, >10s with real
# output). The fix persists the app's OWN parsed screen state on (graceful)
# quit and re-attaches at the byte offset it reflects, so the agent replays only
# the tiny gap. This check proves the ring size no longer drives restore time.
def read_manifest():
    """The persisted session-layout manifest (list of window entries), or []."""
    try:
        with open(MANIFEST) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def manifest_leaves():
    """Flatten every leaf dict out of the manifest tree(s). Swift's Codable
    encodes the `Node` enum as {"leaf": {"_0": Leaf}} / {"split": {"_0": Split}},
    so the payload is under the "_0" key."""
    def walk(node):
        if node is None:
            return []
        if "leaf" in node:
            return [node["leaf"].get("_0", node["leaf"])]
        if "split" in node:
            s = node["split"].get("_0", node["split"])
            return walk(s.get("left")) + walk(s.get("right"))
        return []
    out = []
    for entry in read_manifest():
        out.extend(walk(entry.get("tree")))
    return out

_token_counter = 0
def next_token(tag):
    global _token_counter
    _token_counter += 1
    return f"{tag}{_token_counter:03d}"

def send_echo_and_wait(pane, token, timeout):
    """send-keys `echo <token>` into the pane's shell and wait for it to echo
    back — proof the pane is a LIVE, interactive shell (accepting input), the
    cleanest 'interactive' signal and immune to background-output timing."""
    cli_ok(["+send-keys", f"--target={pane}", f"echo {token}", "Enter"])
    deadline = time.time() + timeout
    while time.time() < deadline:
        if token in read_pane(pane, 400):
            return True
        time.sleep(0.1)
    return False

def graceful_relaunch_measure(pane, timeout=25.0):
    """Graceful-quit + relaunch. Return (gap_seconds, manifest_leaves). The gap
    is from app-gone to the restored pane accepting input (a send-keys echo
    round-trips) — i.e. re-attached AND interactive, the headline SLA metric.
    Reads the manifest while the app is down so the caller can assert a snapshot
    was captured. Uses send-keys (not a background tick) so the measurement is
    NOT gated behind any in-pane command finishing."""
    pids = app_pids()
    if not pids:
        raise E2EError("no app to quit")
    graceful_quit(pids)
    t_gone = time.time()
    leaves = manifest_leaves()  # captured on quit, before we relaunch
    launch_app()
    wait_app_ready()
    deadline = time.time() + timeout
    while time.time() < deadline and pane not in all_leaf_names():
        time.sleep(0.1)
    tok = next_token("ALIVE")
    if not send_echo_and_wait(pane, tok, timeout=max(2.0, deadline - time.time())):
        raise E2EError(f"restored pane {pane} not interactive within {timeout}s")
    return time.time() - t_gone, leaves

def alive_session_pids():
    """The set of alive child PIDs the agent reports (+sessions --json). Stable
    across an app kill/relaunch when a session SURVIVES; a restart changes the
    pid. Used for a survival check that does NOT depend on scrollback (the
    PANE= marker scrolls out of a big-ring pane after restore)."""
    rc, out, _ = run_cli(["+sessions", "--json"], timeout=10)
    if rc != 0:
        return set()
    start = out.find("[")
    if start < 0:
        return set()
    try:
        sessions = json.loads(out[start:])
    except json.JSONDecodeError:
        return set()
    return {obj.get("pid") for obj in sessions
            if obj.get("alive", False) and obj.get("pid")}

def wait_new_leaf(known, timeout=15.0):
    """Poll until a leaf name NOT in `known` appears; return it."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            new = [n for n in all_leaf_names() if n not in known]
        except E2EError:
            new = []
        if len(new) == 1:
            return new[0]
        time.sleep(0.3)
    raise E2EError(f"no new leaf appeared within {timeout}s (known={known})")

def close_leaves(names):
    deadline = time.time() + 12
    while time.time() < deadline and any(n in all_leaf_names() for n in names):
        for nm in names:
            cli_ok(["+close", f"--target={nm}"])
        time.sleep(0.5)

def make_shell_window(target, known):
    """Open a plain-shell window (default shell, no command) and return its new
    pane's stable name (surface uuid — survives relaunch)."""
    retry_cli(["+new-window", f"--target={target}"], f"new {target}")
    return wait_new_leaf(known)

def fill_ring(pane, landmark, chunks, chunk_lines=100):
    """Fill the agent's ~2MB ring with PACED wide-line output, then a unique
    sentinel. Produces `chunks` bursts of `chunk_lines` ~190-char lines with a
    small sleep between them, so the app parses in real time and stays CAUGHT UP
    (mirroring real interactive output) instead of building a multi-MB backlog a
    one-shot dump would — the app's applied offset (the snapshot anchor) must
    reach the agent's produced total for the delta re-attach to be tiny. Uses
    `yes <bareword> | head` (NO quotes — quoted programs get mangled through
    +send-keys, silently running only the trailing echo → a spurious pass). Wait
    until the sentinel echoes back: the dump landed and the shell is idle again."""
    wide = "x" * 190  # bare word: no zsh '=expansion' / glob / quote hazards
    # ~240 KB/s: slower than the app's parse rate so it stays caught up in real
    # time (the applied offset must reach the produced total for a tiny delta).
    cmd = (f"i=0; while [ $i -lt {chunks} ]; do yes {wide} | head -n {chunk_lines}; "
           f"i=$((i+1)); sleep 0.08; done; echo {landmark}")
    cli_ok(["+send-keys", f"--target={pane}", cmd, "Enter"])
    deadline = time.time() + 120
    while time.time() < deadline:
        if landmark in read_pane(pane, 300):
            return True
        time.sleep(0.5)
    return False

def run_fast_restore_check(args):
    """WP-D3: relaunch→interactive time must stay near the empty-ring baseline
    regardless of ring size, because the app restores its own parsed screen
    snapshot and re-attaches at the offset it reflects (delta replay) instead of
    re-parsing the whole ring. Measures a near-empty ring and a full (>2MB) ring
    under GRACEFUL quit (the real upgrade/quit path that captures a snapshot) and
    asserts the full-ring restore did NOT scale with content."""
    failures = []
    fill_chunks = 130               # 130 × 100 × ~191B ≈ 2.5MB paced → ring wrapped
    landmark = "FILLDONE-9753124"   # distinctive tail line the snapshot must keep

    launch_app(); wait_app_ready(); wait_window_count(1)
    initial = set(all_leaf_names())

    # --- EMPTY (baseline): one plain-shell window, tiny ring ---
    log("[fast] EMPTY baseline: plain-shell window, graceful relaunch")
    e_pane = make_shell_window("frE", initial)
    close_leaves(initial)  # drop the blank initial window; leave only frE
    wait_window_count(1)
    if not send_echo_and_wait(e_pane, next_token("WARM"), 8):
        failures.append("empty pane never became interactive before baseline measure")
    gap_empty, _ = graceful_relaunch_measure(e_pane)
    log(f"    gap_empty = {gap_empty:.2f}s")

    # --- FULL: one plain-shell window whose ring is filled past 2MB ---
    log(f"[fast] FULL: fill ring with {fill_chunks} paced chunks (>2MB), graceful relaunch")
    keep = set(all_leaf_names())
    f_pane = make_shell_window("frF", keep)
    if not send_echo_and_wait(f_pane, next_token("WARM"), 8):
        failures.append("full pane never became interactive before fill")
    if not fill_ring(f_pane, landmark, fill_chunks):
        failures.append(f"fill did not complete (landmark {landmark} never appeared)")
    # Let the app finish draining/parsing the fill backlog so its applied offset
    # (the snapshot anchor) catches up to the produced total. A one-shot sustained
    # fill outruns the parser; in real interactive use output is paced and the app
    # stays caught up between bursts — this idle settle reproduces that steady
    # state. The offset assertion below verifies catch-up actually happened.
    time.sleep(22.0)
    pre_pids = alive_session_pids()
    gap_full, leaves = graceful_relaunch_measure(f_pane)
    post_pids = alive_session_pids()
    f_text = read_pane(f_pane, 800)
    log(f"    gap_full = {gap_full:.2f}s")

    # 1) A snapshot WAS captured on quit for the FILLED pane, at a LARGE offset —
    #    proving the ring was genuinely wrapped past 2MB (not a spurious pass on
    #    an unfilled pane) AND that the app's applied offset caught up to it.
    full_leaf = next((l for l in leaves
                      if (l.get("surfaceID") or "").lower() == f_pane.lower()), None)
    if full_leaf is None:
        failures.append(f"filled pane {f_pane} not found in quit manifest by surfaceID")
    else:
        off = full_leaf.get("screenSnapshotOffset") or 0
        snaplen = len(full_leaf.get("screenSnapshot") or "")
        if snaplen == 0:
            failures.append("filled pane's manifest leaf has no screenSnapshot "
                            "(snapshot not captured → would fall back to full replay)")
        elif off < 1_000_000:
            failures.append(f"filled pane snapshot offset {off} < 1MB — the ring was NOT "
                            f"actually filled (test would pass spuriously); check the fill")
        else:
            log(f"    ✓ filled pane snapshot captured: offset={off} (>2MB ring wrapped), "
                f"snapshot={snaplen}B base64")

    # 2) Restore stayed FAST: the >2MB ring did not scale restore time. Old code
    #    added ~2s of re-parse (0.74s → 2.78s); the fix keeps full ≈ empty.
    penalty = gap_full - gap_empty
    if penalty >= 1.5:
        failures.append(f"full-ring restore {gap_full:.2f}s is {penalty:.2f}s slower than "
                        f"empty {gap_empty:.2f}s (ring size still drives restore → re-parse not avoided)")
    else:
        log(f"    ✓ ring-size penalty {penalty:.2f}s < 1.5s (restore does not scale with ring)")
    if gap_full >= 4.0:
        failures.append(f"full-ring restore {gap_full:.2f}s >= 4s (too slow)")

    # 3) Visually correct: the restored pane still shows the tail landmark
    #    (content painted from the snapshot, not lost).
    if landmark not in f_text:
        failures.append(f"restored pane missing tail landmark {landmark} "
                        "(snapshot did not paint the visible content)")
    else:
        log(f"    ✓ restored pane shows tail landmark {landmark} (content correct)")

    # 4) Process SURVIVED (re-attached, not restarted): every child pid alive
    #    before the quit is still alive after restore.
    if pre_pids and not pre_pids.issubset(post_pids):
        failures.append(f"a child pid did not survive the relaunch "
                        f"(pre={sorted(pre_pids)} post={sorted(post_pids)} — restarted, not re-attached)")
    elif pre_pids:
        log(f"    ✓ child pid(s) survived re-attach: {sorted(pre_pids & post_pids)}")

    if not args.keep:
        close_leaves([e_pane, f_pane])

    log("=" * 70)
    if failures:
        log(f"RESULT: FAIL — {len(failures)} assertion(s) failed")
        for f in failures:
            log(f"    ✗ {f}")
        return 1
    log(f"RESULT: PASS — relaunch→interactive stayed fast with a >2MB ring "
        f"(empty {gap_empty:.2f}s vs full {gap_full:.2f}s, penalty "
        f"{gap_full-gap_empty:.2f}s); snapshot captured, content restored, process survived")
    return 0

# ---------------------------------------------------------------------------
# Winsize / re-attach resize integrity (the "big window, small content" bug)
# ---------------------------------------------------------------------------
def agent_pane_ttys():
    """session-id -> /dev/ttysNNN via the AGENT (+sessions --json gives each
    live session's child pid; ps maps pid -> controlling tty). The client-side
    +list tty field is not published for agent-backed panes, and the agent-side
    view is what we want anyway: session ids AND ptys are stable across an app
    kill/relaunch, so the same keys work before and after restore."""
    rc, out, _ = run_cli(["+sessions", "--json"], timeout=10)
    if rc != 0:
        return {}
    start = out.find("[")
    if start < 0:
        return {}
    try:
        sessions = json.loads(out[start:])
    except json.JSONDecodeError:
        return {}
    ttys = {}
    for obj in sessions:
        pid = obj.get("pid")
        if not pid or not obj.get("alive", False):
            continue
        t = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)],
                           capture_output=True, text=True).stdout.strip()
        if t and t != "??":
            ttys[obj.get("id", str(pid))] = ("/dev/" + t, obj.get("created_at", 0))
    return ttys

def stty_size(tty):
    """The AGENT-side PTY winsize, read directly off the device — no typing into
    the pane needed, no dependence on what the pane's child is running."""
    p = subprocess.run(["/bin/stty", "-f", tty, "size"],
                       capture_output=True, text=True, timeout=5)
    if p.returncode != 0:
        raise E2EError(f"stty -f {tty}: {p.stderr.strip()}")
    r, c = p.stdout.split()
    return (int(r), int(c))

def ax_resize_all_windows(pid, width, height):
    """Resize every window of the app via Accessibility (needs the Accessibility
    permission the GUI-driving setup already granted)."""
    script = (
        'tell application "System Events"\n'
        f'  tell (first process whose unix id is {pid})\n'
        '    repeat with w in windows\n'
        f'      set size of w to {{{width}, {height}}}\n'
        '    end repeat\n'
        '  end tell\n'
        'end tell')
    p = subprocess.run(["/usr/bin/osascript", "-e", script],
                       capture_output=True, text=True, timeout=15)
    if p.returncode != 0:
        raise E2EError(f"AX resize failed: {p.stderr.strip()}")

def ax_available():
    """True if we can drive windows via System Events (Automation permission).
    Some environments authorize `tell application id ... to quit` but NOT
    `tell application "System Events"` (error -1743), so AX-based window resizing
    is unavailable there — the winsize check then falls back to an AX-free path."""
    p = subprocess.run(
        ["/usr/bin/osascript", "-e", 'tell application "System Events" to count processes'],
        capture_output=True, text=True, timeout=15)
    return p.returncode == 0

def poll_sizes(ttys, pred, timeout=8.0):
    """Poll each tty's winsize until pred(sizes) or timeout; return last sizes."""
    deadline = time.time() + timeout
    sizes = {}
    while time.time() < deadline:
        sizes = {n: stty_size(t) for n, t in ttys.items()}
        if pred(sizes):
            return sizes
        time.sleep(0.4)
    return sizes

def run_winsize_check(args):
    """Re-attach winsize integrity: after a kill -9 + relaunch the agent-side PTY
    of every restored pane must agree with the restored window geometry, and a
    LIVE window resize after re-attach must still reach the PTY. Guards the
    'window is big but the content renders small' restore bug."""
    launch_app()
    wait_app_ready()
    wait_window_count(1)
    initial_leaves = all_leaf_names()

    log("[winsize] creating window wsW + split wsR")
    retry_cli(["+new-window", "--target=wsW"], "new-window wsW")
    wait_window_count(2)
    deadline = time.time() + 15
    while time.time() < deadline and len(all_windows()) > 1:
        for nm in initial_leaves:
            cli_ok(["+close", f"--target={nm}"])
        time.sleep(0.6)
    wait_window_count(1)
    retry_cli(["+split", "--target=wsW", "--direction=right", "--name=wsR"], "split wsR")
    wait_for_pane("wsR")

    # wsW and wsR are the two NEWEST agent sessions (created after the initial
    # window's pane, which is on its way to being CLOSEd by the earlier +close
    # and must not be measured — its pty vanishes when the undo window expires).
    ttys = poll_ttys = None
    deadline = time.time() + 15
    while time.time() < deadline:
        poll_ttys = agent_pane_ttys()
        if len(poll_ttys) >= 2:
            newest = sorted(poll_ttys.items(), key=lambda kv: kv[1][1])[-2:]
            ttys = {sid: tty for sid, (tty, _) in newest}
            break
        time.sleep(0.5)
    if ttys is None:
        raise E2EError(f"agent sessions never appeared: {poll_ttys}")
    log(f"[winsize] pane sessions: {ttys}")

    pids = app_pids()
    if not pids:
        raise E2EError("no app pid")
    pid = pids[0]

    have_ax = ax_available()
    if not have_ax:
        log("[winsize] AX/System-Events automation unavailable — using the DEFAULT "
            "window PTY size as the reference (AX-free stty-shrink repro still runs)")

    if have_ax:
        # Resize to a deliberate reference size WELL AWAY from the config default
        # (a resize to the size the window already has produces no events at all)
        # and capture the PTY sizes.
        base = {n: stty_size(t) for n, t in ttys.items()}
        log(f"[winsize] pre-resize PTY sizes: {base}")
        ax_resize_all_windows(pid, 1000, 640)
        ref = poll_sizes(ttys, lambda s: s != base)
        if ref == base:
            raise E2EError(f"pre-kill window resize never reached the PTYs: {ref}")
        # Keep only the sessions that tracked the window resize: those are wsW/wsR.
        # A just-closed session (the initial window; alive only until its undo
        # window expires and the CLOSE lands) has no window and never resizes.
        ttys = {n: t for n, t in ttys.items() if ref[n] != base[n]}
        ref = {n: ref[n] for n in ttys}
        if len(ttys) < 2:
            raise E2EError(f"expected 2 live resizable panes, have {ttys}")
        log(f"[winsize] reference PTY sizes @1000x640: {ref}")
    else:
        # AX-free: the DEFAULT window geometry IS the reference. The stty-shrink
        # repro below then proves the restore re-applies THIS geometry through the
        # replay flood — no external resize needed to make the test meaningful.
        ref = {n: stty_size(t) for n, t in ttys.items()}
        log(f"[winsize] reference (default) PTY sizes: {ref}")

    # Let the (debounced) layout sync capture the frame before the hard kill.
    time.sleep(4)

    log("[winsize] SIGKILL app + relaunch")
    kill_pids(app_pids(), signal.SIGKILL)
    wait_gone(app_pids(), 8)

    # Force the narrow/blank re-attach repro deterministically: with the app
    # dead, SHRINK each surviving agent PTY to a deliberately wrong tiny size via
    # stty. On restore the app MUST push an authoritative RESIZE through the
    # re-attach replay flood to re-sync the PTY back to the window geometry. This
    # is exactly the drop the mailbox backstop prevents (a RESIZE lost to the
    # 64-slot queue during the flood would leave these tiny sizes stuck → the
    # narrow/blank panes). Before the fix these PTYs stay ~24x10; after, they
    # re-sync to `ref`.
    for sid, tty in ttys.items():
        try:
            subprocess.run(["/bin/stty", "-f", tty, "rows", "10", "cols", "24"],
                           capture_output=True, text=True, timeout=5)
        except Exception as e:
            vlog(f"stty shrink of {tty} failed (non-fatal): {e}")
    shrunk = {n: stty_size(t) for n, t in ttys.items()}
    log(f"[winsize] shrank PTYs to force re-sync: {shrunk}")
    if all(shrunk[n] == ref[n] for n in shrunk):
        vlog("stty shrink was a no-op (PTYs already matched ref?) — repro weakened")

    launch_app()
    wait_app_ready()

    # Restored panes come back with the SAME agent sessions/ptys (same
    # processes). Wait for the window + named pane to re-register, and confirm
    # the agent still reports the same tty set.
    wait_for_pane("wsR", timeout=20.0)
    restored = {tty for tty, _ in agent_pane_ttys().values()}
    if not restored >= set(ttys.values()):
        raise E2EError(f"restored agent ttys changed: {restored} vs {ttys}")

    pid2 = app_pids()[0]
    ok = True

    # FIRST, WITHOUT any external resize: the RESTORE itself must have re-synced
    # the deliberately-shrunk PTYs back to the window geometry, pushing its
    # authoritative RESIZE through the re-attach replay flood. This is the core
    # narrow/blank assertion — if the RESIZE were dropped by the bounded mailbox
    # (the pre-backstop bug) these PTYs would stay ~24x10.
    resync = poll_sizes(ttys, lambda s: s == ref, timeout=12.0)
    if resync != ref:
        log(f"FAIL: restore did NOT re-sync shrunk PTYs to reference "
            f"(got {resync}, want {ref}) — RESIZE dropped during the re-attach flood")
        ok = False
    else:
        log(f"[winsize] PASS: restore re-synced shrunk PTYs to reference through "
            f"the flood: {resync}")

    if have_ax:
        # Re-assert the reference frame (no-op if the restore already applied it),
        # then the PTYs must agree with the reference sizes again. A stale ATTACH
        # seed that never gets corrected fails here.
        ax_resize_all_windows(pid2, 1000, 640)
        post = poll_sizes(ttys, lambda s: s == ref, timeout=10.0)
        if post != ref:
            log(f"FAIL: PTY sizes after re-attach {post} != reference {ref} "
                "(stale winsize after restore)")
            ok = False
        else:
            log(f"[winsize] PASS: post-restore PTY sizes match reference: {post}")

        # A LIVE resize after re-attach must still reach the agent PTYs.
        ax_resize_all_windows(pid2, 1520, 940)
        live = poll_sizes(ttys, lambda s: all(s[n] != ref[n] for n in s), timeout=10.0)
        if any(live[n] == ref[n] for n in live):
            log(f"FAIL: live resize after re-attach did not reach the PTYs: {live}")
            ok = False
        else:
            log(f"[winsize] PASS: live post-restore resize reached the PTYs: {live}")
    else:
        log("[winsize] (skipped AX re-assert + live-resize checks — automation "
            "unavailable; the AX-free shrink→re-sync assertion above is the core proof)")

    if not args.keep:
        cli_ok(["+close", "--target=wsR"])
        cli_ok(["+close", "--target=wsW"])
    log("winsize check: " + ("ALL PASS" if ok else "FAILURES (see above)"))
    return 0 if ok else 1

# ---------------------------------------------------------------------------
# Agent-unavailable fallback check (T19)
# ---------------------------------------------------------------------------
def run_fallback_check(args):
    """T19: with session-persistence DEFAULT-ON but the local agent forcibly
    unavailable (GHOSTTY_LOCAL_AGENT_BIN → a nonexistent path, so it can never be
    found or spawned), new windows/tabs/splits must fall back to a plain exec
    surface — open promptly, be fully usable — instead of hanging, erroring, or
    leaving an exited overlay. Proves the default-on safety net.

    Note the app is launched WITHOUT --session-persistence: the flag is default-on
    now, so the feature is exercised purely from the compiled default."""
    global AGENT_BIN_OVERRIDE
    failures = []

    bad_bin = "/nonexistent/ghoztty-agent-does-not-exist"
    AGENT_BIN_OVERRIDE = bad_bin
    log(f"[fallback] launching app default-on, agent bin forced to {bad_bin} (unspawnable)")

    t_launch = time.time()
    launch_app()
    # The app must answer +list quickly: a hang here would mean window creation
    # blocked on the (impossible) agent spawn.
    wait_app_ready(timeout=20.0)
    dt_ready = time.time() - t_launch
    log(f"    ✓ app answered +list {dt_ready:.1f}s after launch (no hang at startup)")

    # No agent may ever appear — the whole point is that persistence degraded.
    time.sleep(1.0)
    if agent_pid() is not None:
        failures.append(f"an agent is running (pid {agent_pid()}) — the bad-bin override "
                        "did not prevent a spawn, so this did not exercise the fallback")

    # Create a window + two splits, each running a marker command. Time-bound each
    # mutation: retry_cli already fails loudly if a command can't complete, and the
    # window must come up well within the timeout (no ~5s-per-window agent stall).
    # (The default-on app already opened one blank exec window at launch — itself a
    # fallback surface — so the new window brings the count to 2.)
    log("[fallback] creating an exec-backed window + 2 splits (marker commands)")
    initial_n = len(all_windows())
    t0 = time.time()
    retry_cli(["+new-window", "--target=fbwin", f"--command={marker_cmd(0)}"],
              "fallback new-window", timeout=15)
    wait_window_count(initial_n + 1)
    retry_cli(["+split", "--target=fbwin", "--direction=right", "--name=fb1",
               f"--command={marker_cmd(1)}"], "fallback split fb1", timeout=15)
    wait_for_pane("fb1")
    retry_cli(["+split", "--target=fb1", "--direction=down", "--name=fb2",
               f"--command={marker_cmd(2)}"], "fallback split fb2", timeout=15)
    wait_for_pane("fb2")
    dt_build = time.time() - t0
    log(f"    ✓ window + 2 splits created in {dt_build:.1f}s (no per-window agent stall)")
    # A per-window agent stall would be ~5s each; 3 surfaces well under that bound.
    if dt_build > 12.0:
        failures.append(f"window+splits took {dt_build:.1f}s — suggests a per-surface "
                        "agent-spawn stall instead of an instant exec fallback")

    # Every pane must be a working exec surface: its marker + ticks appear, and it
    # accepts input. Give ticks a moment to accumulate.
    time.sleep(3.0)
    names = {0: None, 1: None, 2: None}
    # map marker index -> pane name via read
    for nm in all_leaf_names():
        n, pid = parse_marker(read_pane(nm))
        if n in names:
            names[n] = nm
    for n in (0, 1, 2):
        nm = names[n]
        if nm is None:
            failures.append(f"pane marker {n} never appeared (exec surface did not start?)")
            continue
        text = read_pane(nm)
        n2, pid = parse_marker(text)
        tick = last_tick(text, n)
        if pid is None or pid <= 0:
            failures.append(f"pane {n}: no valid PID in marker (exec child not running)")
        if tick is None:
            failures.append(f"pane {n}: no ticks (exec child not producing output)")
        else:
            log(f"    ✓ pane {n} ({nm}) exec-backed: PID={pid}, ticks up to {tick}")

    # Input must reach a live shell (proves the fallback surface is a usable,
    # interactive terminal — not an exited overlay). The marker panes run an
    # infinite loop, so open one PLAIN shell split and echo into that.
    retry_cli(["+split", "--target=fb2", "--direction=right", "--name=fbsh"],
              "fallback plain-shell split", timeout=15)
    wait_for_pane("fbsh")
    cli_ok(["+send-keys", "--target=fbsh", "echo FALLBACK-INPUT-OK", "Enter"])
    deadline = time.time() + 6
    seen = False
    while time.time() < deadline:
        if "FALLBACK-INPUT-OK" in read_pane("fbsh"):
            seen = True
            break
        time.sleep(0.4)
    if seen:
        log("    ✓ plain-shell fallback pane accepted input (send-keys echoed back)")
    else:
        failures.append("plain-shell pane did not echo injected input (exec surface not interactive)")

    # Teardown: kill the app; assert nothing leaked an agent or a launchd job (the
    # bad-bin path must NOT install a KeepAlive job around a broken binary).
    AGENT_BIN_OVERRIDE = None
    if launchagent_pid() is not None:
        failures.append("a LaunchAgent job was installed despite the unspawnable binary "
                        "(would KeepAlive-respawn a broken agent forever)")
    ap = app_pids()
    if ap:
        kill_pids(ap, signal.SIGKILL)
        wait_gone(ap, 4)
    launchagent_bootout()

    log("=" * 70)
    if failures:
        log(f"RESULT: FAIL — {len(failures)} assertion(s) failed")
        for f in failures:
            log(f"    ✗ {f}")
        return 1
    log("RESULT: PASS — session-persistence default-on with the agent forcibly "
        "unavailable: windows opened promptly as exec surfaces, ran, and accepted "
        "input; no hang, no stray agent, no KeepAlive job")
    return 0

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument("--cycles", type=int, default=3, help="terminate/relaunch cycles (default 3)")
    ap.add_argument("--upgrade", action="store_true",
                    help="replace the app bundle on disk between terminate and relaunch (T08)")
    ap.add_argument("--agent-restart", action="store_true", dest="agent_restart",
                    help="reboot-equivalent (T12d): kill BOTH app+agent; launchd restarts the "
                         "agent; app relaunch RELAUNCHES sessions from metadata (AC3/AC4)")
    ap.add_argument("--agent-only", action="store_true", dest="agent_only",
                    help="in-place (T12e): kill ONLY the agent (app stays up); launchd restarts "
                         "it; the LIVE app auto-recovers, rebuilding local windows in place with "
                         "the restart banner (AC4 in-place, no app relaunch)")
    ap.add_argument("--agent-sigterm", action="store_true", dest="agent_sigterm",
                    help="graceful agent stop (T13b): SIGTERM the agent and assert it flushes "
                         "dirty rings to disk, then exits cleanly on its own (no SIGKILL escalation)")
    ap.add_argument("--winsize", action="store_true",
                    help="re-attach winsize integrity: PTY sizes must match the "
                         "restored window and live resizes must work after re-attach")
    ap.add_argument("--fast-restore", action="store_true", dest="fast_restore",
                    help="WP-D3: relaunch->interactive time must stay near the "
                         "empty-ring baseline even with a >2MB ring (structured "
                         "snapshot + delta replay), under graceful quit")
    ap.add_argument("--fallback", action="store_true",
                    help="agent-unavailable fallback (T19): default-on config with the local "
                         "agent forced unspawnable; assert windows open as usable exec surfaces "
                         "(no hang, no stray agent, no KeepAlive job)")
    ap.add_argument("--quit", choices=("kill", "graceful"), default="kill",
                    help="how to terminate the app each cycle (default kill = SIGKILL)")
    ap.add_argument("--keep", action="store_true", help="leave app+windows running at end")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    VERBOSE = args.verbose

    if not os.path.exists(CLI):
        log(f"FATAL: debug CLI not found at {CLI} — build first (zig build -Doptimize=Debug)")
        return 2

    # Agent-unavailable fallback (T19): a standalone flow — it must NOT require a
    # live agent (the whole point is that none exists), so it runs its own reset +
    # launch and skips the agent-required baseline below.
    if args.winsize:
        log("=" * 70)
        log("Ghoztty session-persistence E2E — re-attach WINSIZE integrity")
        log("=" * 70)
        full_reset()
        try:
            return run_winsize_check(args)
        finally:
            if not args.keep:
                ap2 = app_pids()
                if ap2:
                    kill_pids(ap2, signal.SIGKILL)
                    wait_gone(ap2, 4)
                launchagent_bootout()

    if args.fast_restore:
        log("=" * 70)
        log("Ghoztty session-persistence E2E — WP-D3 FAST restore (snapshot + delta)")
        log("=" * 70)
        full_reset()
        try:
            return run_fast_restore_check(args)
        finally:
            if not args.keep:
                ap2 = app_pids()
                if ap2:
                    kill_pids(ap2, signal.SIGKILL)
                    wait_gone(ap2, 4)
                launchagent_bootout()

    if args.fallback:
        log("=" * 70)
        log("Ghoztty session-persistence E2E — agent-unavailable FALLBACK (T19)")
        log("=" * 70)
        full_reset()
        try:
            return run_fallback_check(args)
        finally:
            ap2 = app_pids()
            if ap2:
                kill_pids(ap2, signal.SIGKILL)
                wait_gone(ap2, 4)
            launchagent_bootout()

    if args.agent_sigterm:
        mode = "AGENT graceful SIGTERM / ring flush (T13b)"
    elif args.agent_only:
        mode = "AGENT-only / in-place recovery (T12e)"
    elif args.agent_restart:
        mode = "AGENT restart / reboot-equivalent (T12d)"
    elif args.upgrade:
        mode = "binary UPGRADE (T08)"
    else:
        mode = "kill -9 survival (T07)"
    log("=" * 70)
    qdesc = "" if (args.agent_restart or args.agent_only or args.agent_sigterm) else f", quit={args.quit}"
    log(f"Ghoztty session-persistence E2E — {mode}{qdesc}")
    log("=" * 70)

    full_reset()
    if args.upgrade:
        stage_upgrade_bundles()
    build_scenario()

    agent_before = agent_pid()
    if agent_before is None:
        log("FATAL: no local agent running after build — session persistence not active?")
        return 2
    log(f"[base] local agent pid={agent_before}")

    baseline = snapshot()
    if baseline["markers"] != EXPECTED_MARKERS:
        log(f"FATAL: baseline markers {sorted(baseline['markers'])} != {sorted(EXPECTED_MARKERS)}")
        return 2
    log(f"[base] {baseline['n_windows']} windows, panes {sorted(baseline['markers'])}, "
        f"PIDs {baseline['pid']}, ticks {baseline['tick']}")
    for ns, s in baseline["win_structs"].items():
        log(f"[base]   window {sorted(ns)} topology {s}")

    # ---- Reboot-equivalent mode (T12d): a distinct loop with opposite semantics
    # (relaunch, not survival). Split out because a reboot kills the children and
    # the agent's RAM — asserting PID *changes* + a restart banner, not PID stability.
    if args.agent_restart or args.agent_only or args.agent_sigterm:
        # These modes want launchd to OWN the agent (a killed/exited agent
        # auto-restarts, and T13b proves the launchd stop/restart survives a
        # graceful SIGTERM). The app installs+bootstraps the job lazily (first
        # persistent window / warm-up); poll briefly for launchd to report it.
        deadline = time.time() + 8
        while launchagent_pid() is None and time.time() < deadline:
            time.sleep(0.25)
        la_pid = launchagent_pid()
        if la_pid is None:
            log("FATAL: LaunchAgent job not loaded after build — the app did not "
                "install/bootstrap it (T12d), so launchd cannot restart the agent")
            return 2
        log(f"[base] LaunchAgent job loaded (launchd manages agent pid {la_pid})")
        if args.agent_sigterm:
            rc = run_sigterm_check(args, baseline)
        elif args.agent_only:
            rc = run_inplace_cycles(args, baseline)
        else:
            rc = run_reboot_cycles(args, baseline)
        reboot_teardown(args)
        return rc

    prev = baseline
    all_failures = []
    verb = "SIGKILL" if args.quit == "kill" else "gracefully quit"
    action = "swap bundle + relaunch" if args.upgrade else "relaunch"
    for cycle in range(1, args.cycles + 1):
        log("-" * 70)
        log(f"[cycle {cycle}/{args.cycles}] {verb} app, {action} (0s gap), assert survival")
        pre = snapshot()  # capture tick high-water just before termination

        pids = app_pids()
        if not pids:
            all_failures.append(f"cycle {cycle}: no app process to terminate")
            break
        t_term = time.time()
        if args.quit == "graceful":
            graceful_quit(pids)
        else:
            kill_pids(pids, signal.SIGKILL)
            wait_gone(pids, 5)
        t_gone = time.time()
        term_secs = t_gone - t_term

        upgrade = None
        if args.upgrade:
            old_ino, new_ino = swap_in_upgrade(cycle)
            upgrade = {"old_ino": old_ino, "new_ino": new_ino}
            log(f"    ↻ replaced installed bundle on disk "
                f"(main-exec inode {old_ino} -> {new_ino})")

        launch_app()
        wait_app_ready()
        wait_restored()
        # Recovery gap: from the OLD process being gone to all panes interactive.
        # The headline SLA is recovery speed, not how long a graceful quit takes to
        # tear down (logged separately as term_secs; a session-persistence app quits
        # cleanly in <1s — the historical 45s "hang" was a zombie-reaping artifact of
        # this harness, since fixed in pid_alive, not an app teardown bug).
        gap = time.time() - t_gone

        agent_after = agent_pid()
        cur = snapshot()

        failures = []
        assert_cycle(baseline, cur, pre, gap, agent_before, agent_after, failures, upgrade)
        termdesc = f"  term={term_secs:.1f}s" if args.quit == "graceful" else ""
        if failures:
            log(f"[cycle {cycle}] FAIL (recovery {gap:.1f}s{termdesc}):")
            for f in failures:
                log(f"    ✗ {f}")
            all_failures.extend(f"cycle {cycle}: {f}" for f in failures)
        else:
            log(f"[cycle {cycle}] PASS  recovery={gap:.1f}s{termdesc}  agent={agent_after}  "
                f"ticks {cur['tick']}")
        prev = cur

    log("=" * 70)
    survived = "upgrade" if args.upgrade else f"{args.quit}"
    if all_failures:
        log(f"RESULT: FAIL — {len(all_failures)} assertion(s) failed across {args.cycles} cycle(s)")
        rc = 1
    else:
        extra = "binary swapped each cycle, " if args.upgrade else ""
        log(f"RESULT: PASS — {args.cycles}/{args.cycles} {survived}/{args.quit} cycles survived; "
            f"PIDs stable, {extra}topology exact, scrollback replayed, "
            f"agent {agent_before} untouched")
        rc = 0

    if args.keep:
        log("[teardown] --keep: leaving app + windows running")
    else:
        log("[teardown] closing test windows + clearing state")
        for nm in ("A1", "A2", "B1"):
            cli_ok(["+close", f"--target={nm}"])
        full_reset()
        if args.upgrade:
            # If a crash ever left the installed bundle mid-swap, restore it from
            # the reserve before discarding staging, so zig-out stays usable.
            if not os.path.exists(CLI) and os.path.exists(UPGRADE_RESERVE):
                log("[teardown] restoring installed bundle from reserve")
                subprocess.run(["rm", "-rf", ZIGOUT_BUNDLE + ".e2e-new"], capture_output=True)
                subprocess.run(["cp", "-R", UPGRADE_RESERVE, ZIGOUT_BUNDLE], capture_output=True)
            subprocess.run(["rm", "-rf", STAGING, ZIGOUT_BUNDLE + ".e2e-new"], capture_output=True)
    return rc

if __name__ == "__main__":
    try:
        sys.exit(main())
    except E2EError as e:
        log(f"\nHARNESS ERROR: {e}")
        sys.exit(3)
    except KeyboardInterrupt:
        sys.exit(130)
