# ttyinject

Inject text into the stdin of a terminal process, as if typed at its
keyboard. The `ttyinject` binary is **terminal-agnostic**: it targets a tty
(`/dev/pts/N`) directly, with no knowledge of the terminal emulator. The
`ttyinject-wrapper.py` front-end resolves *which* tty to use in a generic way
(own tty, `--tty`, or `--pattern`) and calls the setuid binary.

See also: [PASS-DEMO.md](PASS-DEMO.md) (typing stored passwords from the
`pass` manager) and [SECURITY_REVIEW.md](SECURITY_REVIEW.md) (privilege and
text-leak threat model).

## How it works

`TIOCSTI` pushes characters into a tty's input queue. Since Linux 6.2 the
ioctl requires `CAP_SYS_ADMIN`, so the small C tool (`ttyinject.c`) must run
with root privileges. The Python wrapper does **not** need root — it only
finds the tty and execs the setuid binary, which performs the injection.

The wrapper selects the target tty, first match wins:

| Selection | Description |
|-----------|-------------|
| `--tty /dev/pts/N` | Explicit device. Host integrations that know the focused window's tty pass it here (see kitty below). |
| `--pattern PAT` | tty of the foreground process whose command line matches `PAT` (`pgrep -f`). |
| (none) | The wrapper's **own** controlling tty — it runs inside the terminal it targets. |

## Dependencies

What a machine needs to build, install and run ttyinject. `just check` verifies
all of this and reports each item as ok / warn / fail.

### Kernel

- **Linux** — the tool uses `/proc`, the tty devices and the `TIOCSTI` ioctl.
- **Kernel >= 6.2 recommended**: `TIOCSTI` then requires `CAP_SYS_ADMIN`, so the
  setuid-root binary is strictly required. On older kernels a tty *owner* may
  TIOCSTI into its *own* terminal unprivileged, but typing into **another**
  window's terminal still needs `CAP_SYS_ADMIN`, so the same setuid install
  applies there too.
- **`dev.tty.legacy_tiocsti` must stay `0`** (the default). Setting it to `1`
  reopens `TIOCSTI` for every unprivileged process, system-wide.
- **tty paths**: `/dev/ttyN` (virtual consoles), `/dev/pts/N` (pseudoterminals,
  what terminals use). `/dev/ttyS*` is detected by the resolver but is not a
  window's tty.
- The install directory must **not** sit on a `nosuid` mount, or the setuid bit
  is ignored and injection fails with `Input/output error`.

### Build tools

- `gcc` — compiles `ttyinject.c` (`just build`).
- `just` — task runner (optional; you can run the recipes by hand).
- `sudo` — only `just install`/`just uninstall` use it, to set/remove the
  `4750 root:you` ownership. The `test` recipe also uses `sudo -n` (passwordless).
  `just install` names the group via `whoami`, so the user must belong to a
  group with the same name as the login (the default on most distros); `just
  check` verifies this.

### Runtime tools

- `python3` — runs `ttyinject-wrapper.py` and `ttyinject-kitty-tty-resolver`.
- `kitty` (optional) — only for the shortcut; requires `allow_remote_control
  yes` + `listen_on` in kitty.conf (see below). The binary and wrapper work
  without it.
- `tmux` (optional) — only `just test`.

### Environment variables

| Variable | Used for | Required? |
|----------|----------|-----------|
| `$XDG_BIN_HOME` | Install directory; falls back to `$HOME/.local/bin` | no (has default) |
| `$XDG_RUNTIME_DIR` | kitty rc socket + inject log; must be per-user mode `0700` | yes, for the kitty shortcut |
| `$KITTY_LISTEN_ON` | set by kitty for `--type=background` launches; the resolver inherits it through the socket fd | set automatically |
| `$PATH` | must include the install dir so bare `ttyinject` / `ttyinject-kitty-tty-resolver` calls resolve | for the kitty.conf map |

Tty resolution reads `/proc/<pid>/fd/0` and `/proc/<pid>/stat`: `/proc` must be
mounted and the invoking user must be able to read the *target* process's
`/proc/<pid>` entry. With `hidepid=` mount options, sudo's own
(root-owned) process is not visible — the resolver is normally launched from
your own session, where your processes are always readable.

## Files

| File | Purpose |
|------|---------|
| `ttyinject.c` | Setuid-root binary that performs the `TIOCSTI` |
| `ttyinject-wrapper.py` | Terminal-agnostic tty resolution + invocation of `ttyinject` (repo-local, not installed) |
| `ttyinject-kitty-tty-resolver` | Optional kitty glue: prints the focused kitty window's tty for `-t` |
| `ttyinject-check.sh` | Read-only machine check: can this box build/install/run the tool? |
| `test-ttyinject.sh` | tmux-based end-to-end smoke test |
| `justfile` | `just build` / `test` / `check` / `install[-kitty][-all]` / `uninstall[-kitty][-all]` / `clean` |

## Build & install

Prerequisites: `gcc`, `just`, and `sudo` (for the privileged copy).

```sh
just install
```

That single command is all a normal install needs — it runs the `build` step
(`gcc -O2 -o ttyinject ./ttyinject.c`) and copies the built binary into
`$XDG_BIN_HOME/ttyinject` with `4750 root:you`. `$XDG_BIN_HOME` falls back to
`$HOME/.local/bin`; if that directory is new to your shell, log out/in once or
`sudo systemctl --user reload-env` so a newly created dir lands on `PATH`.

`just install` copies:

| Path | Ownership / mode | Purpose |
|------|------------------|---------|
| `$XDG_BIN_HOME/ttyinject` | `root:you` `4750` (setuid, owner+group exec only) | Performs the privileged write |

The business task is separate from the kitty-specific glue, so they install
independently:

```sh
just install-kitty    # opt-in kitty helper -> $XDG_BIN_HOME/ttyinject-kitty-tty-resolver (750 you:you)
just install-all      # both: program + kitty helper in one go
```

| Path | Ownership / mode | Purpose |
|------|------------------|---------|
| `$XDG_BIN_HOME/ttyinject-kitty-tty-resolver` | `you:you` `750` | Prints the focused kitty window's tty for `-t` (only `just install-kitty`) |

Uninstall mirrors install: `just uninstall` (program), `just uninstall-kitty`
(helper), `just uninstall-all` (both). `ttyinject-wrapper.py` is intentionally
**not** installed by any recipe — run it from the repository.

Before installing anywhere, run `just check` to verify the machine (kernel,
mounts, tooling, setuid state) can run it.

### File permissions — important

- `ttyinject` must be `root:you` with setuid bit and **no "others" access**
  (`-rwsr-x---`): `TIOCSTI` needs `CAP_SYS_ADMIN` on kernels ≥ 6.2. Double-check
  `ls -l` shows an `s` and a mode of `4750`. Do **not** put it on a `nosuid`
  mount. Prohibit cross-user execution (`4750`, not `4755`).
- The binary additionally refuses (`ttyinject.c`) to inject into any tty not
  owned by the real uid that invoked it, so even a mis-set install cannot type
  into root's or another user's terminal.
- `ttyinject-kitty-tty-resolver` (and `ttyinject-wrapper.py`, if you run it
  from the repo) must stay runnable **by your user only** (`750`, `you:you`) —
  the kitty shortcut triggers the resolver. Do **not** make them root-owned
  with mode 500, and do **not** leave them world-executable: that would let
  other users drive injections into your windows.

### Security

- `ttyinject` is a setuid-root binary: any uid that can execute it can type
  into any terminal. Keep it `4750 root:you` so only your group can run it.
- The kitty remote-control socket must be a **filesystem** socket in your
  `$XDG_RUNTIME_DIR` (mode `0700`, per-user), where Linux enforces both
  directory and connect permissions — an **abstract** name (`unix:@name`) is
  reachable by any local process and is skipped here for that reason.
- Do **not** enable `dev.tty.legacy_tiocsti=1`: it reopens TIOCSTI for *all*
  unprivileged processes, kernel-wide.

## kitty configuration

Add to `~/.config/kitty/kitty.conf`:

```conf
# Settings for ttyinject
# enable `kitty @ ls` remote control (needs a kitty restart to take effect)
allow_remote_control yes
# filesystem socket in $XDG_RUNTIME_DIR (0700, per-user; no directory to
# create). Each kitty instance auto-suffixes it with -<pid>.
listen_on unix:${XDG_RUNTIME_DIR}/kitty-rc.sock

# ctrl+shift+f1 -> inject "hello" into the current window, no visible flash.
# every press logs the resolver/binary result to $XDG_RUNTIME_DIR/kitty-inject.log
map ctrl+shift+f1 launch --type=background --allow-remote-control --cwd=current zsh -c 'exec > "$XDG_RUNTIME_DIR/kitty-inject.log" 2>&1; ttyinject -t "$(ttyinject-kitty-tty-resolver)" hello'
```

The wrapper contains **no kitty code**. kitty support lives entirely in its
config: the keybinding launches the resolver in the background, and the
`ttyinject-kitty-tty-resolver` helper (installed by `just install-kitty`, or
`just install-all`) asks kitty for the focused window's tty and hands it to the
setuid binary via `-t`. Any other terminal that can resolve its focused tty can
do the same; terminals that can't simply omit `-t` and let the binary use its
own controlling tty (the default).

`--type=background` runs the wrapper without a kitty window, so the shortcut
shows no flash. It needs `--allow-remote-control` because a windowless process
only reaches `kitty @` through the socket kitty hands it. When run this way the
wrapper targets the active window of the focused OS window (what
`ttyinject-kitty-tty-resolver` resolves) instead of an inactive one.

`ttyinject-kitty-tty-resolver` reads the focused window's foreground pid from `kitty @ ls`
and resolves its tty via `/proc/<pid>/fd/0`. Password prompts (sudo, su, ...)
point that fd at the opened `/dev/tty` cdev, so the helper falls back to the
process's controlling-terminal device number from `/proc/<pid>/stat`
(`tty_nr`): `/dev/tty` → the real `/dev/pts/N`.

With several kitty instances running, each instance suffixes its socket with
`-<pid>` (`main.py` appends `-{kitty_pid}` to a config `unix:` listen_on), so
the `listen_on` line above is safe with multiple instances. The launched
helper uses `KITTY_LISTEN_ON` (its own instance), never another one's.

Then **restart kitty** (remote-control/`listen_on` changes require a fresh
instance) and test with:

```sh
kitty @ ls | python3 -m json.tool   # should print the window list
```

With `--type=background` the wrapper has no window of its own, so it targets
the active window of the focused OS window (the one you pressed the shortcut
in, e.g. `cat -n` or `sudo ls`). Because shells read a line only when
complete, a trailing newline is injected after the text.

## Usage

```sh
# with the kitty shortcut (targets the focused window via ttyinject-kitty-tty-resolver)
<ctrl+shift+f1>

# generic wrapper (any terminal):
#   own terminal (run inside the window you want to type into):
./ttyinject-wrapper.py [text]
#   tty of a specific process:
./ttyinject-wrapper.py [text] --pattern vim
#   explicit device:
./ttyinject-wrapper.py [text] --tty /dev/pts/N

# low-level binary (own controlling tty, or target another tty by device)
ttyinject <text>
ttyinject -t /dev/pts/N <text>
```

## Troubleshooting

- `kitty @ ls` → `Remote control is disabled` — `allow_remote_control yes` is
  missing, or kitty wasn't restarted after editing the config.
- `expected error ... / TIOCSTI` + `Input/output error` — `ttyinject` lost its
  setuid bit or is on a `nosuid` filesystem; re-run `just install` and check
  `ls -l` shows `-rwsr-x---`.
- `could not determine target tty` — you ran the wrapper from the *only*
  window (nothing else to target). Use two windows, or use the shortcut.
- Bind the shortcut to command that output logs:
  'exec > "$XDG_RUNTIME_DIR/kitty-inject.log" 2>&1; ttyinject -t "$(ttyinject-kitty-tty-resolver)" hello'

