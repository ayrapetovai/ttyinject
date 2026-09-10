#!/usr/bin/env bash
#
# ttyinject-check.sh -- verify this machine can build, install and run
# ttyinject. Read-only: builds and installs nothing.
#
# Usage:  bash ttyinject-check.sh        (or: just check)
# Exit:   0 = ready  1 = at least one fatal problem (warnings are non-fatal)
#
# Covers: kernel/TIOCSTI policy, /proc, install-dir mount (nosuid), build
# tools, runtime tools, the setuid state of the binary, $XDG_RUNTIME_DIR and a
# controlling terminal.

set -u

FAILS=0
WARNS=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ ok ]   %s\n' "$*"; }
warn() { printf '  [ warn ] %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  [ FAIL ] %s\n' "$*"; FAILS=$((FAILS + 1)); }
hdr()  { printf '\n== %s ==\n' "$*"; }

version_ge() { # $1 current "X.Y", $2 minimum "X.Y"
  local cmaj cmin mmaj mmin
  cmaj=${1%%.*}; mmaj=${2%%.*}
  cmin=${1#*.}; cmin=${cmin%%.*}
  mmin=${2#*.}; mmin=${mmin%%.*}
  [ "$cmaj" -gt "$mmaj" ] && return 0
  [ "$cmaj" -lt "$mmaj" ] && return 1
  [ "$cmin" -ge "$mmin" ]
}

hdr "OS & kernel"
case "$(uname -s)" in
  Linux) ok "Linux: $(uname -sr)" ;;
  *)     fail "not Linux: $(uname -s)" ;;
esac

KER=$(printf '%s' "$(uname -r)" | sed 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/')
if version_ge "$KER" "6.2"; then
  ok "kernel >= 6.2 -- TIOCSTI needs CAP_SYS_ADMIN, setuid-root binary required"
else
  warn "kernel < 6.2 -- only your own tty is TIOCSTI-owner-scoped; cross-window injection still needs CAP_SYS_ADMIN (setuid)"
fi

if sysctl -n dev.tty.legacy_tiocsti 2>/dev/null | grep -q '^1$'; then
  warn "dev.tty.legacy_tiocsti=1 -- TIOCSTI is open to all unprivileged processes, system-wide security risk"
else
  ok "dev.tty.legacy_tiocsti unset/0 (default locking behaviour)"
fi

hdr "Filesystem & /proc"
if [ -r /proc/self/stat ]; then
  ok "/proc readable (needed for /proc/<pid>/stat and fd/0)"
else
  fail "/proc not readable (tty resolution cannot work)"
fi

bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
hdr "Install dir: $bin_home"
if [ -d "$bin_home" ]; then
  opts=$(findmnt -no OPTIONS -T "$bin_home" 2>/dev/null | tr ',' '\n')
  if [ -n "$opts" ]; then
    if printf '%s\n' "$opts" | grep -qx nosuid; then
      fail "$bin_home sits on a nosuid mount -- the setuid bit will be ignored"
    else
      ok "$bin_home mount allows setuid"
    fi
  else
    warn "cannot inspect mount options (findmnt missing); setuid may silently not work"
  fi
else
  warn "$bin_home does not exist yet (just install creates it)"
fi
case ":$PATH:" in
  *":$bin_home:"*) ok "$bin_home is on PATH" ;;
  *) warn "$bin_home is not on PATH -- bare 'ttyinject' calls will not resolve" ;;
esac

hdr "Build tools"
if command -v gcc >/dev/null 2>&1; then ok "gcc: $(command -v gcc)"; else fail "gcc missing (just build needs it)"; fi
if command -v just >/dev/null 2>&1; then ok "just: $(command -v just)"; else warn "just missing -- run the justfile recipes manually"; fi

hdr "Runtime tools"
if command -v python3 >/dev/null 2>&1; then ok "python3: $(command -v python3)"; else warn "python3 missing -- ttyinject-wrapper.py and the kitty resolver need it"; fi
if command -v tmux >/dev/null 2>&1; then ok "tmux present"; else warn "tmux missing -- 'just test' will not run"; fi
if command -v kitty >/dev/null 2>&1; then ok "kitty present"; else warn "kitty not found -- skip install-kitty and the kitty shortcut (program still works)"; fi

hdr "Binary"
BIN=./ttyinject
if [ -x "$BIN" ]; then
  ok "./ttyinject is built (setuid is applied to the installed copy by 'just install')"
else
  warn "no executable ./$BIN -- run 'just build' first"
fi

installed="$bin_home/ttyinject"
if [ -e "$installed" ]; then
  own=$(stat -c %U "$installed" 2>/dev/null || echo unknown)
  grp=$(stat -c %G "$installed" 2>/dev/null || echo unknown)
  mode=$(stat -c %A "$installed" 2>/dev/null || echo unknown)
  if [ "$own" = root ] && printf '%s' "$mode" | grep -q 's' && [ "$grp" = "$(id -un)" ]; then
    ok "$installed is setuid root ($mode, group $grp)"
  else
    fail "$installed is not 'setuid root, group you' (currently $own:$grp $mode) -- re-run 'just install'"
  fi
else
  warn "no installed $installed -- 'just install' copies it there as setuid root"
fi

hdr "Environment"
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  if [ -d "$XDG_RUNTIME_DIR" ]; then
    m=$(stat -c %a "$XDG_RUNTIME_DIR" 2>/dev/null || echo unknown)
    [ "$m" = 700 ] && ok "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR (mode 700)" \
                    || warn "XDG_RUNTIME_DIR mode is $m, want 700 (per-user protection)"
  else
    warn "XDG_RUNTIME_DIR is set but the directory does not exist: $XDG_RUNTIME_DIR"
  fi
else
  warn "XDG_RUNTIME_DIR unset -- kitty rc socket and inject log lose per-user protection"
fi

hdr "Controlling terminal"
mytty=$(tty 2>/dev/null || true)
if [ -n "$mytty" ]; then
  resolved=$(readlink /proc/self/fd/0 2>/dev/null || echo "$mytty")
  ok "own controlling tty: $resolved (own-tty mode works)"
else
  warn "no controlling tty in this session -- own-tty mode won't work here; use --tty /dev/pts/N"
fi

printf '\n'
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: ready (%s warning(s))\n' "$WARNS"
  exit 0
fi
printf 'RESULT: %s fatal problem(s) found, %s warning(s)\n' "$FAILS" "$WARNS"
exit 1