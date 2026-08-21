#!/usr/bin/env python3
"""Ask the TERMINAL which DEC private modes are currently set (DECRQM).

Run this INSIDE a pane; it prints one `MODE <n> = set|reset|…` line per argument.

Why it exists: the reboot-scrollback replay (`agent/ring_snapshot.zig`) is the
dead session's RAW byte stream, so every mode the dead program enabled gets
re-enabled in the restored pane — mouse tracking above all, which makes a plain
shell read pointer motion as typed input (`zsh: command not found: 30M35`). Mode
state is invisible in `+read` output, so the only way to assert it from an E2E is
to ask the emulator: `CSI ? <n> $ p` → `CSI ? <n> ; <v> $ y`, v = 1 set, 2 reset.

    python3 vt-mode-probe.py 1000 1002 1003 1006 2004
    python3 vt-mode-probe.py --tag=7 1003        # tag every line, for repeat runs

A `--tag` is echoed on every output line. A caller that probes the SAME pane more
than once needs it: the earlier run's answers are still in the scrollback (and, on
a reboot-restored pane, are replayed back into it), so an untagged reader can
happily parse a stale reply and call it a pass.
"""

import os
import re
import select
import sys
import termios
import tty

# DECRPM: CSI ? <mode> ; <value> $ y
_REPLY = re.compile(rb"\x1b\[\?(\d+);(\d+)\$y")

# https://vt100.net/docs/vt510-rm/DECRPM.html
_VALUES = {
    0: "not-recognized",
    1: "set",
    2: "reset",
    3: "permanently-set",
    4: "permanently-reset",
}


def probe(fd, mode, timeout=2.0):
    """Return the DECRPM value for `mode`, or None if the terminal never answered.

    The reply arrives on the tty as ordinary input, so the terminal has to be in
    raw mode for us to read it before the line discipline (or the shell) does.
    """
    saved = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        os.write(fd, f"\x1b[?{mode}$p".encode())
        buf = b""
        while len(buf) < 64:
            if not select.select([fd], [], [], timeout)[0]:
                break
            chunk = os.read(fd, 32)
            if not chunk:
                break
            buf += chunk
            if buf.endswith(b"y"):
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)

    m = _REPLY.search(buf)
    if not m or int(m.group(1)) != mode:
        return None
    return int(m.group(2))


def main():
    args = sys.argv[1:]
    tag = ""
    if args and args[0].startswith("--tag="):
        tag = args.pop(0)[len("--tag="):] + " "
    modes = [int(a) for a in args] or [1000, 1002, 1003, 1006, 2004]
    try:
        fd = os.open("/dev/tty", os.O_RDWR)
    except OSError as e:
        print(f"{tag}VT-PROBE-ERROR no tty: {e}")
        return 2
    try:
        for mode in modes:
            v = probe(fd, mode)
            state = _VALUES.get(v, "no-reply") if v is not None else "no-reply"
            print(f"{tag}MODE {mode} = {state}")
    finally:
        os.close(fd)
    print(f"{tag}VT-PROBE-DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
