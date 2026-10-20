# Installation

Requirements, AUR and source installs, Makefile variables, and uninstalling.

## Requirements

Linux with systemd (`systemd-tmpfiles`: systemd >= 249 for the service, >= 256 for the previews: `--dry-run`, `--check`, `--check0` and `--suggest-exclusions`).
GNU coreutils >= 8.32, GNU findutils, gawk, grep, and sed.

## Install

### Arch Linux (AUR)

Install with an AUR helper (`yay -S linux-tmpcleaner` or `paru -S linux-tmpcleaner`), or build manually:

```sh
git clone https://aur.archlinux.org/linux-tmpcleaner.git && cd linux-tmpcleaner && makepkg -si
```

From a checkout of this repository, `aurgen local` builds and installs a local test package. `aurgen aur` writes the release recipe, with the version taken from the git tag `v<version>`.

It conflicts with the unrelated AUR package `tmpcleaner`, which installs a command of the same name.
The package installs `/usr/bin/tmpcleaner`, the systemd units in `/usr/lib/systemd/system`, `/etc/tmpcleaner/tmpcleaner.conf` (tracked by pacman as a backup file so local edits survive upgrades and new defaults arrive as `.pacnew`), and the drop-in directory `/etc/tmpcleaner/tmpcleaner.conf.d`. The timer is **not** enabled automatically; preview what would be removed, keep what you need (or adjust `/etc/tmpcleaner/tmpcleaner.conf`), then enable the timer:

```sh
sudo tmpcleaner --dry-run
sudo tmpcleaner --suggest-exclusions | sudo tee -a /etc/tmpcleaner/tmpcleaner.conf.d/50-keep.conf
sudo systemctl enable --now tmpcleaner.timer
```

**Migrating from a source install:** remove a previous `make install` first (back up `/etc/tmpcleaner/tmpcleaner.conf` and the `/etc/tmpcleaner/tmpcleaner.conf.d/` drop-ins, which hold your kept paths, run `sudo make uninstall`, install the package, then restore both). Pacman refuses to overwrite untracked files, and units left in `/etc/systemd/system` would shadow the packaged ones in `/usr/lib/systemd/system`.

### From source

**Preview first.** On a machine that keeps work in `/tmp` (build trees,
snapshots, long-lived tool sessions), the first run can remove a lot. Save a
preview of what would go to `preview.txt`, without deleting:

```sh
sudo make preview
```

Add any needed exclusions to `tmpcleaner.conf` (see [Configuration](configuration.md)), then install; this copies the config to `/etc/tmpcleaner/tmpcleaner.conf`, creates the drop-in directory `/etc/tmpcleaner/tmpcleaner.conf.d`, copies the wrapper to `/usr/local/bin/tmpcleaner`, and enables the timer:

```sh
sudo make install
```

For an install-then-preview sequence, defer activation:

```sh
sudo make install ENABLE_TIMER=0
sudo /usr/local/bin/tmpcleaner --dry-run
sudo systemctl enable --now tmpcleaner.timer
```

`ENABLE_TIMER` accepts only `0` or `1` (default `1`). Value `0` still reloads
systemd after installation but does not stop an already running timer.
Staged installs skip all service actions with either value; uninstall still
disables and stops the timer when `DESTDIR` is empty.

`install` runs `install-conf` first: reinstalling upgrades an unedited `/etc/tmpcleaner/tmpcleaner.conf` in place, or keeps an edited config and writes new defaults to `/etc/tmpcleaner/tmpcleaner.conf.new` (using `tmpcleaner.conf.default` to compare; an install from before `.default` existed gets a `.new` once, unless its config already matches the shipped file). Run `sudo make install-conf` to update the config alone.

#### Makefile variables and targets

Variables: `PREFIX=/usr/local`, `BINDIR=$(PREFIX)/bin`, `CONFDIR=/etc/tmpcleaner`, `UNITDIR=/etc/systemd/system`, `ENABLE_TIMER=1`, `KEEP_CONFIG=0`, and `DESTDIR=` (staged install; skips `systemctl` calls when non-empty). `install` rewrites `ExecStart=` in the installed service to `$(BINDIR)/tmpcleaner`. The wrapper's built-in default config is `/etc/tmpcleaner/tmpcleaner.conf`; with a different `CONFDIR`, `install` also adds `Environment="TMPCLEANER_CONF=$(CONFDIR)/tmpcleaner.conf"` to the installed service. `CONFDIR` must be absolute; quotes, backslashes, control bytes and `%` are escaped for systemd.

Quote shell arguments when setting paths containing spaces or punctuation.
Source-install paths cannot contain newlines. `BINDIR` must be absolute and
cannot contain quotes, backslashes or control bytes, which systemd rejects in
executable paths; installation refuses these before copying the binary or units.
Spaces, percent signs and literal dollar signs are supported. GNU make requires
literal dollars in command-line variable values to be doubled, for example
`make install 'BINDIR=/opt/my $$tools/bin'` installs under `/opt/my $tools/bin`.

Targets: `preview` (dry-run to `preview.txt`), `install`, `install-conf`, `uninstall`, `test`;
`lint` runs shellcheck at warning level. To publish the AUR package, edit `aur/aurgen.install.yaml`, tag the release, run `aurgen aur`, test with `aurgen local` or `aurgen test`, and publish with `aurgen aur-deploy`.

## Uninstall

### Arch Linux (AUR)

```sh
sudo systemctl disable --now tmpcleaner.timer
sudo pacman -R linux-tmpcleaner
```

Pacman preserves an edited `/etc/tmpcleaner/tmpcleaner.conf` as `/etc/tmpcleaner/tmpcleaner.conf.pacsave`.

### From source

```sh
sudo make uninstall
```

**Warning:** By default, `make uninstall` removes `tmpcleaner.conf`, its `.default`/`.new`
copies, and the `tmpcleaner.conf.d` drop-ins (the local exclusions), while keeping anything
else in the directory (removing `CONFDIR` itself only when empty); back up your rules first
or pass `KEEP_CONFIG=1` to keep the configuration.

To keep the configuration (`tmpcleaner.conf`, its `.default`/`.new` copies, and
`tmpcleaner.conf.d`), use:

```sh
sudo make uninstall KEEP_CONFIG=1
```

`KEEP_CONFIG` accepts only `0` or `1` (default `0`). It changes only configuration
removal; the binary and units are still removed and the timer is stopped and
disabled. Staged uninstall still skips service actions.

If `PREFIX`, `BINDIR`, `CONFDIR`, or `UNITDIR` was customized during installation, pass the same values when uninstalling (e.g. `sudo make uninstall CONFDIR=... UNITDIR=...`).
