# tmpCleaner

Deletes entries under `/tmp` that are older than 6 hours. Runs as a systemd
timer: 5 minutes after boot, then every 15 minutes.

The deletion itself is done by `systemd-tmpfiles --clean` with its own rule
file (`tmpcleaner.conf`), the same code your distribution already uses for
`/tmp`. A small wrapper (`tmpcleaner`) adds one thing it lacks: protection for
files that running programs still use.

## What gets deleted

A file is removed only when its access, birth, status-change and modification
times are **all** older than 6 hours. So a file that was recently written or
extracted survives. Reading alone is a weak signal: with the usual `relatime`
mount option the access time moves at most once a day.

A directory is removed when it is empty (after its old contents are gone) and
its birth and modification times are older than 6 hours. Its access time is
ignored, because merely listing a directory (`ls`, a `--dry-run` preview)
renews it. A directory created less than 6 hours ago stays even when empty.

Previews print directories as `Would remove directory`; a preview cannot know
that a directory will still hold a kept file, so a real run may remove fewer.

Never deleted:

- Files a running process holds open, and everything inside a directory a
  running process works in (its current directory). These are collected from
  `/proc` right before each run.
- X11/ICE socket dirs and X lock files (`/tmp/.X11-unix`, `/tmp/.ICE-unix`,
  `/tmp/.X0-lock`, ...)
- systemd `PrivateTmp` dirs of running services (`/tmp/systemd-private-*`)
- Unix sockets that are still in use (listed in `/proc/net/unix`)
- Anything on a different mount below `/tmp`; symlinks are never followed

Only `/tmp` is touched; `/var/tmp` keeps the distribution's defaults.

## Requirements

Linux with systemd (`systemd-tmpfiles`, age-by syntax: systemd >= 250).

## Install

**Preview first.** On a machine that keeps work in `/tmp` (build trees,
snapshots, long-lived tool sessions), the first run can remove a lot. This
lists what would go, without deleting:

```sh
sudo TMPCLEANER_CONF=./tmpcleaner.conf sh ./tmpcleaner --dry-run
```

Anything that must survive even while no program uses it goes into the
exclusion list in `tmpcleaner.conf` (format: `man tmpfiles.d`); the age is
set there too:

```
x /tmp/my-long-job-*
```

Then install; this copies the config to `/etc/tmpcleaner/tmpcleaner.conf`,
the wrapper to `/usr/local/bin/tmpcleaner`, and enables the timer:

```sh
sudo make install
```

Later previews: `sudo tmpcleaner --dry-run`. Status and logs:

```sh
systemctl list-timers tmpcleaner.timer
journalctl -u tmpcleaner.service
```

Change the interval with `sudo systemctl edit tmpcleaner.timer`.

## Uninstall

```sh
sudo make uninstall
```

## Test

```sh
make test
```

Runs the rules against a scratch directory (no root needed), including a file
held open and a directory used by a background process.

## License

MIT
