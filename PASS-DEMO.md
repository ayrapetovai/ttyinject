# `pass` (the standard Unix password manager) — demo

`pass` stores each password as a GPG-encrypted file under `~/.password-store`.
Everything below is illustrative: what you type (bold) and what `pass` replies.

## Getting your GPG key ID

`pass init` needs the ID of the GPG key used to encrypt the store. Get it from:

```sh
$ gpg --list-secret-keys --keyid-format=long
sec   rsa3072/ABCD123456789ABC 2024-01-01 [SC]
      F7CE...full-fingerprint...
uid                 [ultimate] Your Name <you@example.com>
```

The key ID for `pass init` is the part after the slash on the `sec` line —
`ABCD123456789ABC` (pass accepts the long ID or the full fingerprint below
it):

```sh
pass init ABCD123456789ABC
```

If `--list-secret-keys` shows nothing, you have no key yet — create one first:

```sh
gpg --full-generate-key    # pick RSA 3072/4096, no expiry ok
```

## 1. Initialize the store

Creates `~/.password-store`, encrypted to your GPG key (`ABCD1234`):

```sh
$ pass init ABCD1234
Password store initialized for ABCD1234.
```

## 2. Store a password

```sh
$ pass insert email/gmail
Enter password for email/gmail: ********   # typed, hidden, stored encrypted
Retype password for email/gmail: ********

$ pass insert --multiline wifi/home
Enter contents: password1
ssid: MyHome
boundary
```

Multi-line entries keep extras (SSID, notes) below the password line.

## 3. Generate one

Random, no typing:

```sh
$ pass generate email/klm 24 -c
The generated password for email/klm is:
  F3rQx9#vB2sLm8KdNpTzW1Yx
Copied email/klm to clipboard. Will clear in 45 seconds.
```

## 4. Browse & retrieve

```sh
$ pass ls
Password Store
├── email
│   ├── gmail
│   └── klm
└── wifi
    └── home

$ pass show email/gmail
hunter2                      # reveals password
user: bob@example.com        # only if stored multi-line

$ pass show email/gmail --type
hunter2                      # password only, no newline

$ pass find otp              # search entries
```

## 5. Rotate / manage

```sh
$ pass edit email/gmail         # opens $EDITOR on the decrypted entry; save -> re-encrypted
$ pass rm wifi/home             # "Are you sure you would like to delete wifi/home? [y/N]"
$ pass mv email/klm personal/klm
$ pass git push                 # if the store is a git repo, history is commits
```

## 6. Tie-in with ttyinject

Type a stored password into the focused terminal (password + Enter, like a real
keypress):

```sh
$ ttyinject -t "$(ttyinject-kitty-tty-resolver)" "$(pass show --type personal/sudo)"
target tty /dev/pts/2, foreground pid 33558
```

## Cheatsheet

| want | command |
|---|---|
| add | `pass insert <name>` |
| random | `pass generate <name> [len]` |
| list | `pass` / `pass ls` |
| view | `pass [show] <name>` |
| copy | `+ -c` |
| edit | `pass edit <name>` |
| delete | `pass rm <name>` |

## 7. Kitty keybinding

Type a chosen entry into the focused window with one shortcut (password +
Enter). Add to `~/.config/kitty/kitty.conf`:

```conf
# ctrl+shift+f2 -> type the stored sudo password into the focused window
map ctrl+shift+f2 launch --type=background --allow-remote-control --cwd=current zsh -c 'exec > "$XDG_RUNTIME_DIR/kitty-inject.log" 2>&1; ttyinject -t "$(ttyinject-kitty-tty-resolver)" "$(pass show --type personal/sudo)"'
```

Notes:

- `pass show --type` emits the password **without** a trailing newline —
  `ttyinject` supplies the Enter, so no double-submit.
- The password is consumed by command substitution, never written or logged
  (the log only gets the tty path). Only the *entry name* is briefly visible
  in the process list.
- First use per boot may trigger a gpg-agent passphrase prompt; afterwards the
  key stays cached, so the shortcut works silently.
- One line per entry if you want several (change the `f2` to `f3`, `f4`, …
  and swap `personal/sudo` for the entry name).

## 8. Why not kitty's built-in `send_text`?

Kitty can type a fixed string into the focused window with
`map ctrl+shift+f2 send_text all yourstring` — functionally equivalent to a
paste (written from the pty master side, so it works in raw-mode prompts like
sudo). But it is a poor fit for real secrets:

- The string is **literal in `kitty.conf`** — stored in plaintext on disk and
  visible in `kitty --show config`, defeating `pass`'s encryption at rest.
- **No dynamic retrieval**: kitty keybindings have no command substitution, so
  each `send_text` binding is one fixed hardcoded password. Rotating means
  editing the config and reloading.
- Every press sends the same secret.

The ttyinject pipeline above is strictly better: the secret never touches the
config and is fetched fresh from the store on every shortcut press.

