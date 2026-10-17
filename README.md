# tmpCleaner

Deletes entries under `/tmp` that are older than 12 hours. Runs as a systemd
timer: 5 minutes after boot, then every 15 minutes.

The deletion itself is done by `systemd-tmpfiles --clean` with its own rule
file (`tmpcleaner.conf`), the same code your distribution already uses for
`/tmp`. A small wrapper (`tmpcleaner`) adds one thing it lacks: protection for
files that running programs still use.

## What gets deleted

A file is removed only when its access, birth, status-change and modification
times are **all** older than 12 hours. So a file that was recently written or
extracted survives. Reading alone is a weak signal: with the usual `relatime`
mount option the access time moves at most once a day.

A directory is removed when it is empty (after its old contents are gone) and
its birth and modification times are older than 12 hours. Its access time is
ignored, because merely listing a directory (`ls`, a `--dry-run` preview)
renews it. A directory created less than 12 hours ago stays even when empty.

Previews print directories as `Would remove directory`; a preview cannot know
that a directory will still hold a kept file, so a real run may remove fewer.

Never deleted:

- Executables of running processes, files a running process holds open,
  memory-mapped files such as loaded libraries, and everything inside a
  directory a running process works in (its current directory) or uses as its
  root directory (chrooted or containerized processes), including files and
  directories reached through bind mounts (a process working in `/tmp` itself
  does not keep all of `/tmp`). The in-use list is
  taken from `/proc` just before each run (a snapshot before cleaning),
  so files opened during a run are not covered and long-lived work belongs in
  the exclusion list.
- X11/ICE socket dirs and X lock files (`/tmp/.X11-unix`, `/tmp/.ICE-unix`,
  `/tmp/.X0-lock`, ...)
- systemd `PrivateTmp` dirs of running services (`/tmp/systemd-private-*`)
- Kerberos ticket caches (`/tmp/krb5cc_*`)
- Unix sockets that are still in use (listed in `/proc/net/unix` of any
  network namespace). Not recognized: a socket bound by a relative name in
  another network namespace, one whose own name forges a line of that table,
  and one whose name no process can reach any more (bound, then chrooted
  away, by the last process of a private mount namespace).
- Anything on a different mount below `/tmp`; symlinks are never followed

Only `/tmp` is touched; `/var/tmp` keeps the distribution's defaults.

## Requirements

Linux with systemd (`systemd-tmpfiles`: systemd >= 249 for the service, >= 256 for `--dry-run` previews and `--check`).
GNU coreutils >= 8.32, GNU findutils, gawk, grep, and sed.

## Install

### Arch Linux (AUR)

Install with an AUR helper (`yay -S linux-tmpcleaner` or `paru -S linux-tmpcleaner`), or build manually:

```sh
git clone https://aur.archlinux.org/linux-tmpcleaner.git && cd linux-tmpcleaner && makepkg -si
```

It conflicts with the unrelated AUR package `tmpcleaner`, which installs a command of the same name.
The package installs `/usr/bin/tmpcleaner`, the systemd units in `/usr/lib/systemd/system`, and `/etc/tmpcleaner/tmpcleaner.conf` (tracked by pacman as a backup file so local edits survive upgrades and new defaults arrive as `.pacnew`). The timer is **not** enabled automatically; preview what would be removed, adjust `/etc/tmpcleaner/tmpcleaner.conf` if needed, then enable the timer:

```sh
sudo tmpcleaner --dry-run
sudo systemctl enable --now tmpcleaner.timer
```

**Migrating from a source install:** remove a previous `make install` first (back up `/etc/tmpcleaner/tmpcleaner.conf`, run `sudo make uninstall`, install the package, then restore the config). Pacman refuses to overwrite untracked files, and units left in `/etc/systemd/system` would shadow the packaged ones in `/usr/lib/systemd/system`.

### From source

**Preview first.** On a machine that keeps work in `/tmp` (build trees,
snapshots, long-lived tool sessions), the first run can remove a lot. Save a
preview of what would go to `preview.txt`, without deleting:

```sh
sudo make preview
```

Add any needed exclusions to `tmpcleaner.conf` (see [Configuration](#configuration)), then install; this copies the config to `/etc/tmpcleaner/tmpcleaner.conf`, the wrapper to `/usr/local/bin/tmpcleaner`, and enables the timer:

```sh
sudo make install
```

`install` runs `install-conf` first: reinstalling upgrades an unedited `/etc/tmpcleaner/tmpcleaner.conf` in place, or keeps an edited config and writes new defaults to `/etc/tmpcleaner/tmpcleaner.conf.new` (using `tmpcleaner.conf.default` to compare; an install from before `.default` existed gets a `.new` once). Run `sudo make install-conf` to update the config alone.

#### Makefile variables and targets

Variables: `PREFIX=/usr/local`, `BINDIR=$(PREFIX)/bin`, `CONFDIR=/etc/tmpcleaner`, `UNITDIR=/etc/systemd/system`, and `DESTDIR=` (staged install; skips `systemctl` calls when non-empty). `install` rewrites `ExecStart=` in the installed service to `$(BINDIR)/tmpcleaner`. `CONFDIR` does not change the wrapper's built-in default path (`/etc/tmpcleaner/tmpcleaner.conf`); if you install with a different `CONFDIR`, set `TMPCLEANER_CONF` in a service drop-in (`sudo systemctl edit tmpcleaner.service`).

Targets: `preview` (dry-run to `preview.txt`), `install`, `install-conf`, `uninstall`, `test`.

## Usage

### Options

- `-h`, `--help`: Show help and exit (exits 0 even when configuration is missing).
- `--print-rules`: Print the configured rules and generated in-use exclusions without deleting anything (`sudo tmpcleaner --print-rules`).
- `--check PATH`: Report whether an existing absolute `/tmp` path would be removed without deleting anything (`sudo tmpcleaner --check /tmp/my-job/file`).
- `--dry-run`, `--prefix=PATH`, `--exclude-prefix=PATH`: `--dry-run` previews; `--prefix=PATH` only applies rules with that prefix (passed to `systemd-tmpfiles`); `--exclude-prefix=PATH` (absolute path, `=` form only; parent directories are canonicalized so `..` components and symlinked parents still match) keeps PATH and everything below it, in addition to the in-use protection, and never lets a path that is in use be removed (`sudo tmpcleaner --dry-run --exclude-prefix=/tmp/my-job`); any other argument (for example `--remove`, `--create`, `--purge`, `--boot`, `--root=...`, `--replace=...`, or a positional config file) exits 2 before any config is read or anything is cleaned.

`--check PATH` requires an existing absolute path under `/tmp`. It prints
`would be removed: PATH` (exit 0) or `kept: PATH` (exit 1, only), using the
same age, pressure and in-use rules as a real run. Every error exits 2: invalid
paths or missing arguments, unreadable configuration, invalid `TMPCLEANER_*`
values, missing `/proc`, a failed in-use scan, and a `systemd-tmpfiles` failure
other than 73. Each prints a message. Exit 1 therefore always means "kept". It reads the preview's text, which a
crafted file name can imitate, so it may raise a false "would be removed" but
never a false "kept"; a directory holding names with newlines, or a path whose
directories cannot be read, cannot be judged and exits 2.

A failed in-use scan stops every mode before `systemd-tmpfiles` runs
(`--print-rules` prints nothing to stdout; `--dry-run` and the real run exit
non-zero and nothing is removed).

### Status and logs

```sh
systemctl list-timers tmpcleaner.timer
journalctl -u tmpcleaner.service
```

Each real run logs one summary, including runs that remove nothing:

```text
tmpcleaner: removed 3 files and 2 directories
```

The counts compare listings of the cleaned trees taken just before and just
after the run, so they are exact for names of any shape; anything another
program deletes in that second is counted too. A `d` path written with escapes
in the configuration (`\x20`, `\"`) is not decoded for these listings, so
removals under it are left out of the counts (cleaning is unaffected). `systemd-tmpfiles` itself logs to
the journal as usual, so warnings keep their severity.

Change the interval with `sudo systemctl edit tmpcleaner.timer`. A run that
takes longer than ten minutes is stopped and logged as failed; the next timer
run starts normally.

## Configuration

Anything that must survive even while no program uses it goes into the
exclusion list in `/etc/tmpcleaner/tmpcleaner.conf` (format: `man tmpfiles.d`);
the age is set there too:

```text
x /tmp/my-long-job-*
```

Service environment settings below go in a unit drop-in via `sudo systemctl edit tmpcleaner.service` (works for both AUR and source installs).

### Environment variables

- `TMPCLEANER_CONF`: Path to configuration file (default: `/etc/tmpcleaner/tmpcleaner.conf`).
- `TMPCLEANER_AGE`: Override duration on every `d` rule (e.g. `6h`, `30m`).
- `TMPCLEANER_FULL_PERCENT`: Threshold percentage of `/tmp` usage (1-100); the larger of block and inode usage counts (`-` is 0), and a `df` error aborts the run.
- `TMPCLEANER_FULL_AGE`: Age duration to use when `/tmp` usage meets or exceeds `TMPCLEANER_FULL_PERCENT`.
- `TMPCLEANER_LIST`: Set to 1 to list removed paths with control bytes and backslashes escaped (default: off).

A configuration file other than the installed one can be previewed with
`sudo env TMPCLEANER_CONF=/path/to/custom.conf tmpcleaner --dry-run`; an
unreadable file stops the run before cleaning.

### Override the age

Set `TMPCLEANER_AGE` to override the duration on every `d` rule (e.g. `6h`, `30m`) while keeping
its age-by letters and the config unchanged. Use a non-negative integer with
an optional unit: `us`, `ms`, `s`, `m`, `min`, `h`, `d`, or `w` (seconds when
omitted). An empty or invalid value stops the run before cleaning; when unset,
the configured ages apply. A rule whose quoted path holds spaces keeps its
configured age, with a warning.

For the service, run `sudo systemctl edit tmpcleaner.service` and add:

```ini
[Service]
Environment=TMPCLEANER_AGE=12h
```

Preview a one-off override without editing the config:

```sh
sudo env TMPCLEANER_AGE=12h tmpcleaner --dry-run
```

### Use a shorter age when /tmp is nearly full

Pressure mode is off by default. Set both `TMPCLEANER_FULL_PERCENT` (threshold
percentage of `/tmp` usage, an integer from 1 to 100) and `TMPCLEANER_FULL_AGE`
(age duration to use when `/tmp` usage meets or exceeds `TMPCLEANER_FULL_PERCENT`,
in the same format as `TMPCLEANER_AGE`) to enable it. With either variable unset,
the usual age applies. When both are set, invalid values stop the run before cleaning.

Run `sudo systemctl edit tmpcleaner.service` and add, for example:

```ini
[Service]
Environment=TMPCLEANER_FULL_PERCENT=90
Environment=TMPCLEANER_FULL_AGE=30m
```

Each run reads `/tmp` usage with `df --output=pcent,ipcent /tmp` and uses the
larger of the block percentage and the inode percentage, so a `/tmp` that runs
out of inodes while block usage stays low still triggers pressure mode. A
filesystem without inode accounting (such as btrfs) prints `-` for inodes, which
counts as 0. At or above the threshold, it overrides every `d` rule's duration,
including `TMPCLEANER_AGE`, and reports
`tmpcleaner: /tmp is N% full (blocks B%, inodes I%), using age X` on stderr.
Below the threshold, the configured age or `TMPCLEANER_AGE` applies.

If `df` fails or its output cannot be parsed, tmpcleaner aborts: it prints `tmpcleaner: cannot read /tmp usage` and exits 1 (2 with `--check`) in every
mode, and nothing is removed.

**The shorter age applies to every unprotected file**, so recent temporary
work can be deleted sooner. In-use protection and configured exclusions
still apply.

### List removed paths

Set `TMPCLEANER_LIST=1` to log each path that disappeared during a real
cleanup, in addition to the summary. Files are logged as
`tmpcleaner: removed: PATH` and directories as
`tmpcleaner: removed directory: PATH`. Control bytes and backslashes in each
path use `\xHH` escapes so a filename cannot start a new journal line.
Unset or empty leaves the usual output unchanged (default: off); any other value stops
the run before cleaning.

For the service, run `sudo systemctl edit tmpcleaner.service` and add:

```ini
[Service]
Environment=TMPCLEANER_LIST=1
```

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

**Warning:** `make uninstall` deletes the whole configuration directory, including
local exclusions; back up `/etc/tmpcleaner/tmpcleaner.conf` first if you edited it.

If `PREFIX`, `BINDIR`, `CONFDIR`, or `UNITDIR` was customized during installation, pass the same values when uninstalling (e.g. `sudo make uninstall CONFDIR=... UNITDIR=...`).

## Test

```sh
make test
```

Runs the rules against a scratch directory (no root needed), including a file
held open and a directory used by a background process.

## License

tmpCleaner is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).
