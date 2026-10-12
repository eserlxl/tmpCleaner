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
  directory a running process works in (its current directory) or uses as its
  root directory (chrooted or containerized processes), including files and
  directories reached through bind mounts. The in-use list is
  taken from `/proc` just before each run (a snapshot before cleaning),
  so files opened during a run are not covered and long-lived work belongs in
  the exclusion list.
- X11/ICE socket dirs and X lock files (`/tmp/.X11-unix`, `/tmp/.ICE-unix`,
  `/tmp/.X0-lock`, ...)
- systemd `PrivateTmp` dirs of running services (`/tmp/systemd-private-*`)
- Kerberos ticket caches (`/tmp/krb5cc_*`)
- Unix sockets that are still in use (listed in `/proc/net/unix`)
- Anything on a different mount below `/tmp`; symlinks are never followed

Only `/tmp` is touched; `/var/tmp` keeps the distribution's defaults.

## Requirements

Linux with systemd (`systemd-tmpfiles`: systemd >= 249 for the service, >= 256 for `--dry-run` previews and `--check`).

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

Reinstalling upgrades an unedited config (`/etc/tmpcleaner/tmpcleaner.conf`)
to the new defaults. An edited config is kept, and the new defaults land in
`/etc/tmpcleaner/tmpcleaner.conf.new` to merge. The last shipped defaults are
kept in `tmpcleaner.conf.default` to tell the two apart; an install made before
that file existed gets a `.new` once.

Later previews: `sudo tmpcleaner --dry-run`. Show the config and generated
in-use exclusions without deleting anything: `sudo tmpcleaner --print-rules`.

Check one path without deleting anything: `sudo tmpcleaner --check /tmp/my-job/file`.
The path must exist and be absolute and under `/tmp`. It prints
`would be removed: PATH` (exit 0) or `kept: PATH` (exit 1), using the same
age, pressure and in-use rules as a real run. Invalid paths or missing arguments
produce a message and exit 2. This is a snapshot; directory results have the
same preview limitation described above.

Status and logs:

```sh
systemctl list-timers tmpcleaner.timer
journalctl -u tmpcleaner.service
```

Each real run logs one summary, including runs that remove nothing:

```text
tmpcleaner: removed 3 files and 2 directories
```

The counts come from a preview of the same rules taken just before the run;
systemd-tmpfiles itself logs to the journal as usual, so warnings keep their
severity. Previews and `--print-rules` keep their usual output.

Change the interval with `sudo systemctl edit tmpcleaner.timer`. A run that
takes longer than ten minutes is stopped and logged as failed; the next timer
run starts normally.

### Override the age

Set `TMPCLEANER_AGE` to override the duration on every `d` rule while keeping
its age-by letters and the config unchanged. Use a non-negative integer with
an optional unit: `us`, `ms`, `s`, `m`, `min`, `h`, `d`, or `w` (seconds when
omitted). An empty or invalid value stops the run before cleaning; when unset,
the configured ages apply.

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

Pressure mode is off by default. Set both `TMPCLEANER_FULL_PERCENT` (an integer
from 1 to 100) and `TMPCLEANER_FULL_AGE` (the same format as `TMPCLEANER_AGE`)
to enable it. With either variable unset, the usual age applies. When both are
set, invalid values stop the run before cleaning.

Run `sudo systemctl edit tmpcleaner.service` and add, for example:

```ini
[Service]
Environment=TMPCLEANER_FULL_PERCENT=90
Environment=TMPCLEANER_FULL_AGE=30m
```

Each run reads `/tmp` usage with `df --output=pcent /tmp`. At or above the
threshold, it overrides every `d` rule's duration, including `TMPCLEANER_AGE`,
and reports `tmpcleaner: /tmp is N% full, using age X` on stderr. Below the
threshold, the configured age or `TMPCLEANER_AGE` applies.

**The shorter age applies to every unprotected file**, so recent temporary
work can be deleted sooner. In-use protection and configured exclusions
still apply.

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
