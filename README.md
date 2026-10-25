# tmpCleaner

[![License: GPL v3+](https://img.shields.io/badge/License-GPLv3%2B-blue.svg)](LICENSE)
[![AUR](https://img.shields.io/aur/version/linux-tmpcleaner)](https://aur.archlinux.org/packages/linux-tmpcleaner)

Deletes entries under `/tmp` that are older than 12 hours. Runs as a systemd
timer: 5 minutes after boot, then every 15 minutes.

The deletion itself is done by `systemd-tmpfiles --clean` with its own rule
file (`tmpcleaner.conf`), the same code your distribution already uses for
`/tmp`. A small wrapper (`tmpcleaner`) adds one thing it lacks: protection for
files that running programs still use.

## Contents

- [Quick start](#quick-start)
- [Install](#install)
- [What gets deleted](#what-gets-deleted)
- [Keeping files](#keeping-files)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

## Quick start

```sh
sudo tmpcleaner --dry-run                     # preview what a run would remove
sudo tmpcleaner --suggest-exclusions | sudo tee -a /etc/tmpcleaner/tmpcleaner.conf.d/50-keep.conf # keep what you need, delete the rest
sudo systemctl enable --now tmpcleaner.timer  # clean every 15 minutes
sudo tmpcleaner --check /tmp/my-job/file      # ask whether one path would be removed
journalctl -u tmpcleaner.service              # one summary line per run
```

Every option is in the [command-line reference](docs/cli-reference.md).

## Install

On Arch Linux, install the [`linux-tmpcleaner`](https://aur.archlinux.org/packages/linux-tmpcleaner)
AUR package (`yay -S linux-tmpcleaner` or `paru -S linux-tmpcleaner`). The
timer is **not** enabled automatically: preview with `sudo tmpcleaner --dry-run`,
keep what you need with `--suggest-exclusions`, then enable it as in the quick
start.

From a checkout, save a preview to `preview.txt`, install, preview the installed
configuration, and enable the timer when ready (`make install` reloads systemd
without enabling the timer):

```sh
sudo make preview
sudo make install
sudo /usr/local/bin/tmpcleaner --dry-run
sudo systemctl enable --now tmpcleaner.timer
```

To enable the timer during installation (the previous default), run
`sudo make install ENABLE_TIMER=1`. Value `0` (default `0`) does not stop an
already running timer.

Linux with systemd >= 249 (>= 256 for the previews: `--dry-run`, `--check`,
`--check0` and `--suggest-exclusions`) and GNU
coreutils >= 8.32 are required. Requirements, Makefile variables, migrating
from a source install to the package, and uninstalling are in
[docs/installation.md](docs/installation.md).

> [!WARNING]
> `sudo make uninstall` keeps `tmpcleaner.conf`, its `.default`/`.new` copies,
> and the `tmpcleaner.conf.d` drop-ins by default (`KEEP_CONFIG=1`); passing
> `KEEP_CONFIG=0` (the previous default) removes them and deletes the local
> exclusions.

## What gets deleted

A file is removed only when its access, birth, status-change and modification
times are **all** older than 12 hours; an empty directory goes once its birth
and modification times are. Only `/tmp` is touched; `/var/tmp` keeps the
distribution's defaults.

> [!WARNING]
> **Preview first.** On a machine that keeps work in `/tmp` (build trees,
> snapshots, long-lived tool sessions), the first run can remove a lot. Files
> in use are protected only by a `/proc` snapshot taken just before each run,
> so long-lived work that is not always open belongs in the exclusion list.

Running executables, open and memory-mapped files, everything under a running
process's current or root directory, live Unix sockets, X11/ICE sockets,
`PrivateTmp` dirs, Kerberos caches, and other mounts below `/tmp` are never
deleted; the full rules are in [docs/what-gets-deleted.md](docs/what-gets-deleted.md).

## Keeping files

Add an `x` rule to `/etc/tmpcleaner/tmpcleaner.conf` (format: `man tmpfiles.d`)
for anything that must survive even while no program uses it:

```text
x /tmp/my-long-job-*
```

`sudo tmpcleaner --suggest-exclusions` prints ready-to-paste `x` rules for
everything the next run would remove, as in the quick start.
A `*.conf` file in `/etc/tmpcleaner/tmpcleaner.conf.d/` works the same and
survives package upgrades (see [docs/configuration.md](docs/configuration.md)).
Without root, a job can instead create a regular `.tmpcleaner-keep` file in its
`/tmp/<dir>` or `/tmp/<dir>/<subdir>` directory and remove it when done.

> [!WARNING]
> Exclusions, `.tmpcleaner-keep` markers and in-use protection apply only to
> tmpCleaner's runs. The distribution's own `systemd-tmpfiles-clean.timer` still
> removes `/tmp` entries older than its own age (10 days on Arch), kept ones
> included. `/tmp` is not long-term storage: keep data that must last longer
> elsewhere.

Age overrides, the opt-in pressure mode (a shorter age when `/tmp` is nearly
full, which applies to **every unprotected file**), and the other service
settings are in [docs/configuration.md](docs/configuration.md).

## Documentation

**User guides**

| Document | Contents |
|----------|----------|
| [docs/installation.md](docs/installation.md) | Requirements, AUR and source installs, Makefile variables and targets, uninstalling |
| [docs/what-gets-deleted.md](docs/what-gets-deleted.md) | Age rules for files and directories, and everything that is never deleted |
| [docs/configuration.md](docs/configuration.md) | Exclusion list, environment variables, age override, pressure mode, removal listing |
| [docs/cli-reference.md](docs/cli-reference.md) | Every option, `--check` verdicts and reasons, exit statuses |
| [docs/status-and-logs.md](docs/status-and-logs.md) | Timer status, run summaries, Prometheus metrics, scratch space, interval |

**Maintainer docs**

| Document | Contents |
|----------|----------|
| [docs/installation.md](docs/installation.md#makefile-variables-and-targets) | AURGen packaging flow and the `lint` target |
| [docs/qualification.md](docs/qualification.md) | Optional disposable systemd container qualification (`tests/qualify-container.sh`) |
| [aur/aurgen.install.yaml](aur/aurgen.install.yaml) | AUR package recipe |
| [tests/test.sh](tests/test.sh) | Test suite run by `make test` |
| [tests/check-package.sh](tests/check-package.sh) | Hermetic smoke checks run by `make check-package` in the AUR package's check() |

## Development

The local gate runs before every push or release:

```sh
make lint            # shellcheck at warning level
make test
aurgen test          # dry-runs every AURGen mode
```

Publishing: edit `aur/aurgen.install.yaml`, tag the release, run `aurgen aur`, test with `aurgen local` or `aurgen test`, and publish with `aurgen aur-deploy`.

`make test` runs the rules against a scratch directory (no root needed), including a file
held open and a directory used by a background process.

`make mutate` runs the guard mutants against a disposable copy (about 6 minutes per case),
is optional before a release, and the mandatory gate stays `sh tests/test.sh && make lint`.

## License

tmpCleaner is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).
