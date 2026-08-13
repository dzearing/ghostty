#!/usr/bin/env python3
"""
E2E: `+rearrange` on a window that contains a VIEWER pane.

A viewer pane has no terminal surface, and `+rearrange` used to resolve every
name in a layout through `TargetEntry.surfaceView` — which is nil for a viewer
by design. So any layout naming one failed with

    pane '<name>' is no longer alive

about a pane `+list` was reporting one line earlier, which made every window
holding a preview pane permanently un-rearrangeable.

This harness drives the DEBUG build through the debug CLI and asserts the
real-world case from that bug report: three terminals plus a viewer, rearranged
so the viewer becomes full-height on the right. What the unit tests
(`macos/Tests/IPC/RearrangeLayoutTests.swift`) cannot cover is exactly what is
checked here — a layout mixing TERMINAL and viewer panes, and the guarantees
that go with it: the terminal processes survive (same pids, no restart),
scrollback keeps accumulating, focus stays on the pane that had it, the viewer
stays the same pane (same id + url ⇒ its rendered page and scroll position are
untouched), and a pane the layout omits is dropped and unregistered.

    scripts/e2e/rearrange-viewer.py [--keep] [--verbose]

Exit 0 = every criterion passed. Nonzero = a criterion failed (the failing
criteria are printed). NEVER touches /Applications/Ghoztty.app: debug bundle +
debug socket only. Build first: `zig build -Doptimize=Debug`.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

# Run from inside a Ghoztty pane and the CLI would inherit that pane's
# GHOZTTY_IPC_SOCKET — the socket of the app that OWNS the pane, which for a
# release pane is the user's real terminal. Drop it so the debug CLI falls back
# to its own build-flavor derivation. (The app's server side never reads it.)
os.environ.pop("GHOZTTY_IPC_SOCKET", None)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUNDLE = os.path.join(ROOT, "zig-out", "Ghoztty-Debug.app")
CLI = os.path.join(BUNDLE, "Contents", "MacOS", "ghoztty")
BUNDLE_ID = "com.dzearing.ghoztty.debug"

WIN = "rearr-e2e"
WIN2 = "rearr-e2e-other"
TAG = "REARRANGE_E2E"  # unique to this harness, so cleanup can never over-match

VERBOSE = False


def log(msg):
    print(msg, flush=True)


def vlog(msg):
    if VERBOSE:
        print(f"    · {msg}", flush=True)


class E2EError(Exception):
    pass


# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------
def marker_cmd(n):
    # `stty -echo` first: with a live test window under the pointer, an
    # unread tty echoes mouse reports into the pane as garbage.
    return (f"stty -echo; echo {TAG} PANE={n} PID=$$; i=0; "
            f"while true; do echo tick-{n}-$((i++)); sleep 1; done")


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
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        ok, msg = cli_ok(args)
        if ok:
            return
        last = msg
        time.sleep(interval)
    raise E2EError(f"{what} never succeeded within {timeout}s (last: {last})")


def launch_app_if_needed():
    rc, _, _ = run_cli(["+list", "--json"], timeout=5)
    if rc == 0:
        vlog("debug app already running")
        return False
    log("[setup] launching the debug app")
    logf = open(os.path.join(tempfile.gettempdir(), "ghoztty-rearrange-e2e.log"), "ab")
    # GHOSTTY_RELAY_DISABLE: skip the relay-account Keychain read, which an
    # ad-hoc-signed debug build re-prompts for on every rebuild.
    subprocess.Popen([CLI, "--confirm-close-surface=false"], stdout=logf, stderr=logf,
                     start_new_session=True,
                     env=dict(os.environ, GHOSTTY_RELAY_DISABLE="1"))
    deadline = time.time() + 30
    while time.time() < deadline:
        rc, out, _ = run_cli(["+list", "--json"], timeout=5)
        if rc == 0:
            return True
        time.sleep(0.3)
    raise E2EError("debug app did not answer +list --json within 30s")


# ---------------------------------------------------------------------------
# Tree helpers
# ---------------------------------------------------------------------------
def all_windows():
    return cli_json(["+list", "--json"])["data"]["windows"]


def window_tree(target):
    for w in all_windows():
        if w.get("target") == target:
            return w["tabs"][0]["splits"]
    return None


def leaves_of(node):
    if node.get("type") == "leaf":
        return [node["terminal"]]
    return leaves_of(node["left"]) + leaves_of(node["right"])


def leaf_named(node, name):
    for leaf in leaves_of(node):
        if leaf.get("name") == name:
            return leaf
    return None


def shape_of(node):
    """Nested tuple of the topology, leaves as their pane name."""
    if node.get("type") == "leaf":
        return ("L", node["terminal"].get("name"))
    return ("S", node["direction"], round(float(node["ratio"]), 3),
            shape_of(node["left"]), shape_of(node["right"]))


def wait_for_pane(target, name, timeout=20.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        tree = window_tree(target)
        if tree and leaf_named(tree, name):
            return leaf_named(tree, name)
        time.sleep(0.3)
    raise E2EError(f"pane '{name}' never appeared in window '{target}'")


def read_pane(name, lines=2000):
    rc, out, _ = run_cli(["+read", f"--name={name}", f"--lines={lines}"], timeout=15)
    return out if rc == 0 else ""


def last_tick(text, n):
    vals = [int(x) for x in re.findall(rf"tick-{n}-(\d+)", text)]
    return max(vals) if vals else None


def count_markers(text, n):
    return len(re.findall(rf"{TAG} PANE={n} PID=\d+", text))


def marker_pid(text, n):
    """The SHELL's own pid, from the marker it printed once at startup.

    Not `+list`'s `pid`, which is the pane's FOREGROUND process — in a
    `while … sleep 1` loop that is a different pid every second, so comparing
    it across a rearrange proves nothing either way.
    """
    m = re.search(rf"{TAG} PANE={n} PID=(\d+)", text)
    return int(m.group(1)) if m else None


def wait_marker(name, n, timeout=25.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_markers(read_pane(name), n) >= 1:
            return
        time.sleep(0.4)
    raise E2EError(f"pane '{name}' never printed its {TAG} PANE={n} marker")


def pid_alive(pid):
    return subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
def build_fixture(doc):
    """One window: three terminals (t0 the window's own pane, t1, t2) plus a
    viewer pane (v1). t2 is created last, so it holds focus."""
    log(f"[build] window '{WIN}': 3 terminals + 1 viewer ({os.path.basename(doc)})")
    retry_cli(["+new-window", f"--target={WIN}", f"--working-directory={ROOT}",
               f"--command={marker_cmd(0)}"], "new-window")

    retry_cli(["+split", f"--target={WIN}", "--direction=right", "--name=v1",
               f"--working-directory={ROOT}", f"--view={doc}"], "split viewer")
    wait_for_pane(WIN, "v1")

    retry_cli(["+split", "--pane=v1", "--direction=down", "--name=t1",
               f"--working-directory={ROOT}", f"--command={marker_cmd(1)}"], "split t1")
    wait_for_pane(WIN, "t1")

    retry_cli(["+split", "--pane=t1", "--direction=right", "--name=t2",
               f"--working-directory={ROOT}", f"--command={marker_cmd(2)}"], "split t2")
    wait_for_pane(WIN, "t2")

    # The window's own pane is unnamed; +list auto-registers it under its id.
    tree = window_tree(WIN)
    named = {"v1", "t1", "t2"}
    t0 = next(l["name"] for l in leaves_of(tree) if l.get("name") not in named)
    vlog(f"window pane t0 = {t0}")

    log(f"[build] second window '{WIN2}' (a pane in the wrong window)")
    retry_cli(["+new-window", f"--target={WIN2}", f"--working-directory={ROOT}",
               f"--command={marker_cmd(9)}"], "new-window 2")
    deadline = time.time() + 20
    while time.time() < deadline and window_tree(WIN2) is None:
        time.sleep(0.3)
    tree2 = window_tree(WIN2)
    if tree2 is None:
        raise E2EError(f"window '{WIN2}' never appeared in +list")
    other = leaves_of(tree2)[0]["name"]
    vlog(f"other-window pane = {other}")

    for name, n in ((t0, 0), ("t1", 1), ("t2", 2)):
        wait_marker(name, n)
    log("[build] letting ticks accumulate (3s)")
    time.sleep(3)
    return t0, other


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="leave the fixture windows open")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    VERBOSE = args.verbose

    if not os.path.exists(CLI):
        log(f"error: debug CLI not found: {CLI}")
        log("       build it first: zig build -Doptimize=Debug")
        return 2

    workdir = tempfile.mkdtemp(prefix="ghoztty-rearrange-e2e-")
    doc = os.path.join(workdir, "preview.md")
    with open(doc, "w") as f:
        f.write("# preview\n\nA viewer pane, rearranged.\n")

    failures = []

    def check(cond, msg):
        log(("    ✓ " if cond else "    ✗ ") + msg)
        if not cond:
            failures.append(msg)

    launched = launch_app_if_needed()
    try:
        t0, other = build_fixture(doc)

        before = window_tree(WIN)
        v_before = leaf_named(before, "v1")
        text_before = {n: read_pane(nm) for nm, n in ((t0, 0), ("t2", 2))}
        ticks_before = {n: last_tick(text_before[n], n) for n in text_before}
        pids_before = {n: marker_pid(text_before[n], n) for n in text_before}
        focused_before = [l.get("name") for l in leaves_of(before) if l.get("focused")]
        vlog(f"focused before: {focused_before}")
        if focused_before != ["t2"]:
            raise E2EError(f"fixture precondition: expected t2 focused, got {focused_before}")

        # The repro: viewer full-height on the right, two terminals stacked on
        # the left, and t1 (omitted) dropped.
        layout = {"direction": "horizontal", "ratio": 40,
                  "left": {"direction": "vertical", "ratio": 50,
                           "left": {"pane": t0}, "right": {"pane": "t2"}},
                  "right": {"pane": "v1"}}
        log("[test] rearrange: (t0 / t2) | v1   — viewer full-height on the right")
        rc, out, err = run_cli(["+rearrange", f"--target={WIN}",
                                f"--layout={json.dumps(layout)}"])
        detail = (err.strip() or out.strip())
        check(rc == 0, f"mixed terminal+viewer layout succeeds (rc={rc} {detail!r})")
        check("no longer alive" not in detail,
              "no bogus 'no longer alive' for the viewer pane")
        if rc != 0:
            raise E2EError(f"+rearrange failed: {detail}")

        time.sleep(3)  # let ticks accumulate past the rearrange
        after = window_tree(WIN)

        check(shape_of(after) == ("S", "horizontal", 0.4,
                                  ("S", "vertical", 0.5, ("L", t0), ("L", "t2")),
                                  ("L", "v1")),
              f"topology is the requested layout (got {shape_of(after)})")

        v_after = leaf_named(after, "v1")
        check(v_after is not None and v_after["type"] == "viewer",
              "the viewer pane is still a viewer")
        check(v_after and v_after["url"] == v_before["url"],
              f"the viewer still shows {os.path.basename(doc)}")
        check(v_after and v_after["id"] == v_before["id"],
              "the viewer is the SAME pane (id unchanged ⇒ page + scroll intact)")

        for label, n, nm in (("t0", 0, t0), ("t2", 2, "t2")):
            check(leaf_named(after, nm) is not None, f"{label}: still in the tree")
            text = read_pane(nm)
            pid = marker_pid(text, n)
            check(pid is not None and pid == pids_before[n] and pid_alive(pid),
                  f"{label}: same shell still running (pid {pids_before[n]} -> {pid})")
            check(count_markers(text, n) == 1,
                  f"{label}: exactly one {TAG} marker (the shell never restarted)")
            check((last_tick(text, n) or -1) > (ticks_before[n] or -1),
                  f"{label}: scrollback survived and ticks kept advancing")

        focused_after = [l.get("name") for l in leaves_of(after) if l.get("focused")]
        check(focused_after == ["t2"], f"focus stayed on t2 (got {focused_after})")

        check(leaf_named(after, "t1") is None, "the omitted pane t1 is gone from the tree")
        ok, msg = cli_ok(["+read", "--name=t1", "--lines=1"])
        check(not ok and "registry" in msg,
              f"the omitted pane's name is unregistered (got {msg!r})")

        # Negatives: the two error paths a layout can legitimately hit.
        log("[test] error paths")
        ok, msg = cli_ok(["+rearrange", f"--target={WIN}",
                          f"--layout={json.dumps({'pane': 'no-such-pane'})}"])
        check(not ok and "not found in registry" in msg,
              f"an unknown pane name is reported as such (got {msg!r})")

        ok, msg = cli_ok(["+rearrange", f"--target={WIN}",
                          f"--layout={json.dumps({'direction': 'horizontal', 'left': {'pane': 'v1'}, 'right': {'pane': other}})}"])
        check(not ok and "is not in the target window" in msg,
              f"a pane from another window is reported as such (got {msg!r})")

        # A viewer-only layout: the window becomes just the viewer.
        log("[test] viewer-only layout")
        ok, msg = cli_ok(["+rearrange", f"--target={WIN}",
                          f"--layout={json.dumps({'pane': 'v1'})}"])
        check(ok, f"a viewer-only layout succeeds (got {msg!r})")
        time.sleep(1)
        final = window_tree(WIN)
        check(final is not None and shape_of(final) == ("L", "v1"),
              f"the window is now the single viewer pane (got {shape_of(final) if final else None})")

    except E2EError as e:
        log(f"    ! {e}")
        failures.append(str(e))
    finally:
        if args.keep:
            log("[cleanup] --keep: leaving the fixture windows open")
        else:
            log("[cleanup] closing fixture windows")
            for target in (WIN, WIN2):
                cli_ok(["+close", f"--target={target}"], timeout=10)
            time.sleep(1)
            if launched:
                subprocess.run(["osascript", "-e",
                                f'tell application id "{BUNDLE_ID}" to quit'],
                               capture_output=True, timeout=15)
            # Sweep any marker shell still running: one dropped by the layout,
            # and — since a `+close` only ends its agent session once the undo
            # window expires — any pane closed just before the app quit. Last,
            # so the quit can't resurrect one. SIGKILL because the marker runs
            # under `zsh -lic` and an INTERACTIVE shell ignores SIGTERM. The
            # pattern is this harness's own tag, so nothing else can match.
            subprocess.run(["pkill", "-KILL", "-f", TAG], capture_output=True)

    log("")
    if failures:
        log(f"FAILED ({len(failures)}):")
        for f in failures:
            log(f"  - {f}")
        return 1
    log("PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
