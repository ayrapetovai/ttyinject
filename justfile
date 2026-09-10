# Build only, do not install, do not test
build:
  gcc -O2 -o ttyinject ./ttyinject.c

# Build and test (requires root and tmux), do not install
test: build
  sudo ./test-ttyinject.sh

# Verify this machine can build, install and run ttyinject (read-only)
check:
  ./ttyinject-check.sh

# Remove all build results (binaries too)
clean:
  rm -rf ./ttyinject ./ttyinject.o
  rm -rf __pycache__

# Install dir; falls back to ~/.local/bin when $XDG_BIN_HOME is unset
XDG_BIN_HOME := env_var_or_default('XDG_BIN_HOME', '')
bin_home := if XDG_BIN_HOME != '' { XDG_BIN_HOME } else { "$HOME/.local/bin" }

# Build and install the setuid-root program only
install: build
  sudo install -o root -g `whoami` -m 4750 ./ttyinject "{{bin_home}}/ttyinject"

# Install the optional kitty tty-resolution helper (needs kitty remote control)
install-kitty:
  install -m 750 ./ttyinject-kitty-tty-resolver "{{bin_home}}/ttyinject-kitty-tty-resolver"

# Install everything: program + kitty helper (never the wrapper)
install-all: install install-kitty

# Uninstall the setuid-root program
uninstall:
  sudo rm "{{bin_home}}/ttyinject"

# Uninstall the kitty tty-resolution helper
uninstall-kitty:
  rm "{{bin_home}}/ttyinject-kitty-tty-resolver"

# Uninstall everything
uninstall-all: uninstall uninstall-kitty

