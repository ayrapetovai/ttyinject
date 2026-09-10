#!/usr/bin/env python3
"""Inject text into a terminal, as if typed. Terminal-agnostic.

The target tty is chosen, first match wins:
  --tty DEV          explicit tty device (e.g. /dev/pts/N). Use this from any
                     host integration that knows the focused window's tty
                     (e.g. a kitty keybinding resolving it via `kitty @ ls`).
  --pattern PAT      tty of the foreground process whose command line matches
                     PAT (pgrep -f).
  (default)          the tty the wrapper itself runs on (own controlling tty).

Usage:
  ttyinject-wrapper [text] [--tty /dev/pts/N]
  ttyinject-wrapper [text] [--pattern vim]
  ttyinject-wrapper [text]                    (own terminal)
"""
import argparse
import os
import stat
import subprocess
import sys

TTYINJECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ttyinject")

parser = argparse.ArgumentParser(
    prog="ttyinject-wrapper",
    description="Inject text into a terminal as if typed.",
)
parser.add_argument("text", nargs="?", default="hello",
                    help="text to inject (default: hello)")
parser.add_argument("--tty", metavar="DEV", default=None,
                    help="target tty device (default: wrapper's own tty)")
parser.add_argument("--pattern", default=None, metavar="PAT",
                    help="target the tty of the foreground process matching this pgrep pattern")
args = parser.parse_args()
text = args.text


def own_tty():
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None
    try:
        return os.ttyname(fd)
    except OSError:
        return None
    finally:
        os.close(fd)


def tty_of_pid(pid):
    try:
        return os.readlink(f"/proc/{pid}/fd/0")
    except OSError:
        return None


def inject(tty):
    try:
        st = os.stat(TTYINJECT)
    except OSError:
        print(f"missing: {TTYINJECT}", file=sys.stderr)
        return 1
    if st.st_uid != 0 or not (st.st_mode & stat.S_ISUID):
        print(f"refusing: {TTYINJECT} must be a setuid-root binary", file=sys.stderr)
        return 1
    print(f"target tty: {tty}", file=sys.stderr)
    return subprocess.run([TTYINJECT, "-t", tty, text]).returncode


tty = args.tty
if not tty and args.pattern:
    try:
        pid = subprocess.run(["pgrep", "-f", args.pattern], capture_output=True,
                             text=True, check=True).stdout.split()[0]
        tty = tty_of_pid(int(pid))
    except Exception:
        tty = None
if not tty:
    tty = own_tty()

if tty:
    sys.exit(inject(tty) or 0)

print("could not determine target tty", file=sys.stderr)
sys.exit(1)