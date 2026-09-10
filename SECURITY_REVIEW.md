# Security review — `ttyinject.c` + `ttyinject-kitty-tty-resolver`

Deployment facts verified: `ttyinject` = `-rwsr-x--- root:login` (4750), `resolver` = `750 user login:login`, group `user login` (gid 1001) contains only login, `$XDG_RUNTIME_DIR` = `/run/user/1000` mode 0700, kitty socket `srwxr-xr-x` but unreachable (0700 parent). `~/.local/bin` is world-rx but not world-writable.

## 1. Can a non-root user gain root? — No

- **Execution gate**: other users can't even exec `ttyinject` (no "others" bit). Only root/user/group-user.
- **Cross-user injection is refused at the core**: after `open()`, `fstat` compares `st.st_uid != getuid()` (ttyinject.c:162) and aborts. This is the load-bearing defense against the classic TIOCSTI escalation (typing commands into root's shell). It works even if the binary were misdeployed 4755: an attacker could only inject into a tty owned by *their own* real uid — their own terminal, where typing isn't privilege.
- **`getuid()` (real uid) is the right check**, not euid (which is 0).
- **No TOCTOU**: the owner check runs on the already-open fd (fstat, not a re-walked path), so symlink swaps between open and check are impossible.
- **Nothing to pivot into**: the binary only `open`s a device path, `fstat`s, `tcgetpgrp`s, runs TIOCSTI ioctls, prints. No `exec*`, no `system()`, no file writes, no env/conf reads.
- **Target fd opened `O_NOCTTY`** — the setuid process never adopts the target terminal as its controlling terminal.
- Buffers/parsing (`readlink` capped at 255+NUL, `snprintf`, `sscanf`) are bounded; `%s` is used correctly (dev/text are *arguments*, never format strings). The `fg` pid from the `/proc` scan is only cosmetic — injection doesn't use it.

Mitigations that *don't* exist but aren't needed: ttyinject can't read anything from others' terminals, so it can't steal root's input either.

## 2. Can a non-root user obtain the sent text? — No

Every channel for the injected payload is closed:
- **tty input queue** (where TIOCSTI bytes land): readable only by whoever holds an fd to the pty *slave*. The slave node is owned by user and mode ~`0620` — other users can't open it. The master side belongs to user's kitty process.
- **argv of `ttyinject`** (the text is `argv[3]`): `/proc/<pid>/cmdline` of a setuid-root process fails `ptrace_may_access(PTRACE_MODE_READ_FSCREDS)` for any non-root reader — kernel-enforced, so `ps`/`/proc` scraping by other users yields nothing.
- **Log**: `kitty-inject.log` sits inside the 0700 runtime dir (couldn't be reached even with `0644`), and it only ever records the tty path + foreground pid — never the injected text.
- **Kitty RC socket**: no write permission on the socket *and* no path traversal through `$XDG_RUNTIME_DIR`. Even if a hostile client could forge the focused window, the tty it hands `ttyinject` must pass the owner check — so injection always lands in user's own terminal, readable only by user/root.

Net: a non-root local user (1) cannot execute the privileged path, (2) cannot redirect it to a root-owned tty, and (3) has no way to read the injected text. The design's defense-in-depth — restrictive `4750` → fd-owner check → protected socket/log — holds.

## Optional hardening (low priority)
- Resolver: pin `kitty` to an absolute path (`/usr/bin/kitty`) instead of PATH lookup (`ttyinject-kitty-tty-resolver:20`), trimming any path surprises in the kitty-spawned background env.
- The resolver could `os.getuid()`-own the socket path — already implicit via `$XDG_RUNTIME_DIR`.
