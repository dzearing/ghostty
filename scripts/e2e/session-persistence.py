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
LOCK_FILE = os.path.join(AGENT_DIR, "agent.lock")
HEARTBEAT_FILE = os.path.join(AGENT_DIR, "agent.heartbeat")
APP_LOG = os.path.join(tempfile.gettempdir(), "ghoztty-e2e", "e2e-app.log")

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

LAUNCH_ARGS = ["--session-persistence=true", "--confirm-close-surface=false"]

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
    agp = agent_pid()
    if agp is not None:
        kill_pids([agp], signal.SIGKILL)
        wait_gone([agp], 4)
    for f in (MANIFEST, PORT_FILE, SOCKET_FILE, HEARTBEAT_FILE):
        try:
            os.remove(f)
        except FileNotFoundError:
            pass
    time.sleep(0.5)

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
    p = subprocess.Popen([CLI] + LAUNCH_ARGS, stdout=logf, stderr=logf,
                         start_new_session=True)
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

def wait_restored(timeout=12.0):
    """Poll until all EXPECTED_MARKERS are readable (re-attached & interactive)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            names = all_leaf_names()
        except E2EError:
            time.sleep(0.2); continue
        if len(names) >= EXPECTED_LEAVES:
            found = set()
            for nm in names:
                n, _ = parse_marker(read_pane(nm, 3000))
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument("--cycles", type=int, default=3, help="terminate/relaunch cycles (default 3)")
    ap.add_argument("--upgrade", action="store_true",
                    help="replace the app bundle on disk between terminate and relaunch (T08)")
    ap.add_argument("--quit", choices=("kill", "graceful"), default="kill",
                    help="how to terminate the app each cycle (default kill = SIGKILL)")
    ap.add_argument("--keep", action="store_true", help="leave app+windows running at end")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    VERBOSE = args.verbose

    if not os.path.exists(CLI):
        log(f"FATAL: debug CLI not found at {CLI} — build first (zig build -Doptimize=Debug)")
        return 2

    mode = ("binary UPGRADE (T08)" if args.upgrade else "kill -9 survival (T07)")
    log("=" * 70)
    log(f"Ghoztty session-persistence E2E — {mode}, quit={args.quit}")
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
