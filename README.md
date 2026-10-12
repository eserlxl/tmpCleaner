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

- Executables of running processes, files a running process holds open,
  memory-mapped files such as loaded libraries, and everything inside a
  directory a running process works in (its current directory). The in-use
  list is taken from `/proc` just before each run (a snapshot before cleaning),
  so files opened during a run are not covered and long-lived work belongs in
  the exclusion list.
- X11/ICE socket dirs and X lock files (`/tmp/.X11-unix`, `/tmp/.ICE-unix`,
  `/tmp/.X0-lock`, ...)
- systemd `PrivateTmp` dirs of running services (`/tmp/systemd-private-*`)
- Unix sockets that are still in use (listed in `/proc/net/unix`)
- Anything on a different mount below `/tmp`; symlinks are never followed

Only `/tmp` is touched; `/var/tmp` keeps the distribution's defaults.

## Requirements

Linux with systemd (`systemd-tmpfiles`: systemd >= 249 for the service, >= 256 for `--dry-run` previews).

## Install

**Preview first.** On a machine that keeps work in `/tmp` (build trees,
snapshots, long-lived tool sessions), the first run can remove a lot. Save a
preview of what would go to `preview.txt`, without deleting:

```sh
sudo make preview
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

Reinstalling keeps the installed config (`/etc/tmpcleaner/tmpcleaner.conf`).
When it has been edited and differs from shipped defaults, the new defaults
land in `/etc/tmpcleaner/tmpcleaner.conf.new` to merge.

Later previews: `sudo tmpcleaner --dry-run`. Show the config and generated
in-use exclusions without deleting anything: `sudo tmpcleaner --print-rules`.
Status and logs:

```sh
systemctl list-timers tmpcleaner.timer
journalctl -u tmpcleaner.service
```

Change the interval with `sudo systemctl edit tmpcleaner.timer`.

### See what was deleted

By default, `systemd-tmpfiles` logs removals only at debug level, so
`journalctl -u tmpcleaner.service` shows just warnings. To log every removal to
the journal, add an opt-in drop-in with `sudo systemctl edit tmpcleaner.service`:

```ini
[Service]
Environment=SYSTEMD_LOG_LEVEL=debug
LogFilterPatterns=^Removing
LogFilterPatterns=[Ff]ail|[Ee]rror
```

Allow patterns in `LogFilterPatterns` are extended regular expressions and are
OR-ed together. Note that `LogFilterPatterns` needs systemd >= 253 (older
versions would log all debug output) and that a first run on a busy `/tmp` logs
thousands of lines.

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

tmpCleaner is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).
