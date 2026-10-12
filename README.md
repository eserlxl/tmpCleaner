# tmpCleaner

Deletes entries under `/tmp` that are older than 6 hours. Runs as a systemd
timer: 5 minutes after boot, then every 15 minutes.

There is no custom daemon code: the work is done by `systemd-tmpfiles --clean`
with its own rule file (`tmpcleaner.conf`), so the deletion logic is the same
battle-tested code your distribution already uses for `/tmp`.

## What gets deleted

An entry is removed only when its access, birth and modification times (plus
status-change time for files) are **all** older than 6 hours. So a file that
was recently written, read or extracted survives.

Never deleted:

- X11/ICE socket dirs and X lock files (`/tmp/.X11-unix`, `/tmp/.ICE-unix`,
  `/tmp/.X0-lock`, ...)
- systemd `PrivateTmp` dirs of running services (`/tmp/systemd-private-*`)
- Unix sockets that are still in use (listed in `/proc/net/unix`)
- Anything on a different mount below `/tmp`; symlinks are never followed

Only `/tmp` is touched; `/var/tmp` keeps the distribution's defaults.

## Requirements

Linux with systemd (`systemd-tmpfiles`, age-by syntax: systemd >= 250).

## Install

```sh
sudo make install     # installs units + config, enables the timer
```

Preview what the next run would delete, without deleting:

```sh
sudo systemd-tmpfiles --clean --dry-run /etc/tmpcleaner/tmpcleaner.conf
```

Status and logs:

```sh
systemctl list-timers tmpcleaner.timer
journalctl -u tmpcleaner.service
```

Change the age or exclusions in `/etc/tmpcleaner/tmpcleaner.conf`
(format: `man tmpfiles.d`). Change the interval with
`sudo systemctl edit tmpcleaner.timer`.

## Uninstall

```sh
sudo make uninstall
```

## Test

```sh
make test
```

Runs the rules against a scratch directory (no root needed).

## License

MIT
