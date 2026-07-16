#!/usr/bin/env python3
"""
E2E harness for Ghoztty session persistence (design doc §5, task T07).

Builds the headlineAcceptance scenario against the DEBUG build entirely via the
debug CLI, then SIGKILLs the app and relaunches the SAME binary, asserting that
every pane's process survived (re-attached, not restarted), the split topology
and ratios are restored exactly, and scrollback replays. Repeats the kill/relaunch
cycle N times to prove repeatability (incl. 0s fast-relaunch, which T06b made safe).

This is the kill -9 variant (T07). The binary-UPGRADE variant is T08 (--upgrade,
to be added there).

Exit 0 = all criteria passed. Nonzero = a criterion failed (actionable diff printed).

    scripts/e2e/session-persistence.py [--cycles=3] [--keep] [--verbose]

NEVER touches /Applications/Ghoztty.app. Debug bundle + debug socket + debug agent
only. See docs/design/session-persistence-tasks.json for the full protocol.
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUNDLE = os.path.join(ROOT, "zig-out", "Ghoztty-Debug.app")
CLI = os.path.join(BUNDLE, "Contents", "MacOS", "ghoztty")
AGENT_BIN = os.path.join(BUNDLE, "Contents", "MacOS", "ghoztty-agent")
BUNDLE_ID = "com.dzearing.ghoztty.debug"
HOME = os.path.expanduser("~")
MANIFEST = os.path.join(HOME, "Library", "Application Support", BUNDLE_ID, "session-layout.json")
AGENT_DIR = os.path.join(HOME, ".config", "ghoztty", "local-agent-debug")
PORT_FILE = os.path.join(AGENT_DIR, "port.json")
LOCK_FILE = os.path.join(AGENT_DIR, "agent.lock")
HEARTBEAT_FILE = os.path.join(AGENT_DIR, "agent.heartbeat")
APP_LOG = "/private/tmp/claude-501/-Users-dzearing-git-ghoztty-session-persistence/07b76f56-4805-41d3-907d-8c54be603961/scratchpad/e2e-app.log"

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
    # the app binary, NOT the agent (both live in Contents/MacOS)
    return [pid for pid, cmd in procs_matching(CLI) if "ghoztty-agent" not in cmd and "+" not in cmd]

def agent_pid():
    pids = [pid for pid, cmd in procs_matching(AGENT_BIN)]
    return pids[0] if pids else None

def pid_alive(pid):
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

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
    for f in (MANIFEST, PORT_FILE, HEARTBEAT_FILE):
        try:
            os.remove(f)
        except FileNotFoundError:
            pass
    time.sleep(0.5)

def launch_app():
    os.makedirs(os.path.dirname(APP_LOG), exist_ok=True)
    logf = open(APP_LOG, "ab")
    logf.write(f"\n\n===== launch {time.strftime('%H:%M:%S')} =====\n".encode())
    logf.flush()
    p = subprocess.Popen([CLI] + LAUNCH_ARGS, stdout=logf, stderr=logf,
                         start_new_session=True)
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
def assert_cycle(baseline, cur, prev, gap, agent_before, agent_after, failures):
    def check(cond, msg):
        if not cond:
            failures.append(msg)

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
    ap.add_argument("--cycles", type=int, default=3, help="kill/relaunch cycles (default 3)")
    ap.add_argument("--keep", action="store_true", help="leave app+windows running at end")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    VERBOSE = args.verbose

    if not os.path.exists(CLI):
        log(f"FATAL: debug CLI not found at {CLI} — build first (zig build -Doptimize=Debug)")
        return 2

    log("=" * 70)
    log("Ghoztty session-persistence E2E — kill -9 survival (T07)")
    log("=" * 70)

    full_reset()
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
    for cycle in range(1, args.cycles + 1):
        log("-" * 70)
        log(f"[cycle {cycle}/{args.cycles}] SIGKILL app, relaunch (0s gap), assert survival")
        pre = snapshot()  # capture tick high-water just before the kill

        pids = app_pids()
        if not pids:
            all_failures.append(f"cycle {cycle}: no app process to kill")
            break
        t_kill = time.time()
        kill_pids(pids, signal.SIGKILL)
        wait_gone(pids, 5)

        launch_app()
        wait_app_ready()
        wait_restored()
        gap = time.time() - t_kill

        agent_after = agent_pid()
        cur = snapshot()

        failures = []
        assert_cycle(baseline, cur, pre, gap, agent_before, agent_after, failures)
        if failures:
            log(f"[cycle {cycle}] FAIL ({gap:.1f}s):")
            for f in failures:
                log(f"    ✗ {f}")
            all_failures.extend(f"cycle {cycle}: {f}" for f in failures)
        else:
            log(f"[cycle {cycle}] PASS  gap={gap:.1f}s  agent={agent_after}  "
                f"ticks {cur['tick']}")
        prev = cur

    log("=" * 70)
    if all_failures:
        log(f"RESULT: FAIL — {len(all_failures)} assertion(s) failed across {args.cycles} cycle(s)")
        rc = 1
    else:
        log(f"RESULT: PASS — {args.cycles}/{args.cycles} kill -9 cycles survived; "
            f"PIDs stable, topology exact, scrollback replayed, agent {agent_before} untouched")
        rc = 0

    if args.keep:
        log("[teardown] --keep: leaving app + windows running")
    else:
        log("[teardown] closing test windows + clearing state")
        for nm in ("A1", "A2", "B1"):
            cli_ok(["+close", f"--target={nm}"])
        full_reset()
    return rc

if __name__ == "__main__":
    try:
        sys.exit(main())
    except E2EError as e:
        log(f"\nHARNESS ERROR: {e}")
        sys.exit(3)
    except KeyboardInterrupt:
        sys.exit(130)
