#!/usr/bin/env bash
#
# End-to-end test for ttyinject.
#
# Spawns a tmux pane running a "reader" loop, lets ttyinject auto-determine
# the target pid, injects text, and checks the reader actually received it
# on stdin.
#
# Needs: tmux, and either the setuid-root binary (4750 root:you) or passwordless sudo
#         (TIOCSTI requires CAP_SYS_ADMIN on kernels >= 6.2).
# Usage: bash test-ttyinject.sh [/path/to/ttyinject]

set -euo pipefail

INJ="${1:-./ttyinject}"
TEST_STRING="HELLO-$$-$(date +%s)"
session="ttytest$$"

command -v tmux >/dev/null || {
  echo "error: tmux required"
  exit 1
}
[ -x "$INJ" ] || {
  echo "error: binary not found: $INJ"
  exit 1
}

# --- privilege wrapper -----------------------------------------------------
RUN=("$INJ")
if [ "$(id -u)" -ne 0 ]; then
  if [ -u "$INJ" ]; then
    echo "using setuid-root binary"
  else
    sudo -n true 2>/dev/null || {
      echo "error: not root, no setuid bit, and no passwordless sudo."
      exit 1
    }
    RUN=(sudo -n "$INJ")
    echo "using passwordless sudo wrapper"
  fi
fi

cleanup() { tmux kill-session -t "$session" 2>/dev/null || true; }
trap cleanup EXIT

# --- start the target ------------------------------------------------------
echo "==> starting target session '$session' (reads a line, echoes it)"
tmux new-session -d -s "$session" \
  'while IFS= read -r line; do printf "GOT:%s\n" "$line"; done'

sleep 1
tty=$(tmux display -pt "$session" -F '#{pane_tty}')
pane_pid=$(tmux display -pt "$session" -F '#{pane_pid}')
echo "==> target tty: $tty   (pane pid: $pane_pid)"

# --- inject ----------------------------------------------------------------
echo "==> injecting: $TEST_STRING"
out=$("${RUN[@]}" -t "$tty" "$TEST_STRING")
echo "    injector: $out" # shows the pid it determined itself

sleep 0.5
cap=$(tmux capture-pane -pt "$session" -p)
echo "==> pane output:"
printf '%s\n' "$cap"

# --- verify ----------------------------------------------------------------
if printf '%s' "$cap" | grep -qF "GOT:$TEST_STRING"; then
  echo "PASS: target received the text on stdin"
else
  echo "FAIL: text not received on target stdin"
  exit 1
fi
