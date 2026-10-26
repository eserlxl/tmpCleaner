# Container qualification

What `tests/qualify-container.sh` proves, how to run and read it, its cost, and the limits of the container environment.

## What it proves

The mandatory unit suite (`tests/test.sh`) runs `tmpcleaner` directly under `PATH` shims with a retargeted scratch directory and birth/ctime age letters stripped. It does not exercise a real `systemd` PID 1 or the installed unit sandbox.

`tests/qualify-container.sh` boots a disposable Arch Linux container with `/usr/lib/systemd/systemd` as PID 1 and verifies five checks end to end:

1. **`make install`**: Installs `/usr/local/bin/tmpcleaner`, `/etc/systemd/system/tmpcleaner.service`, `/etc/systemd/system/tmpcleaner.timer`, `/etc/tmpcleaner/tmpcleaner.conf`, `/etc/tmpcleaner/tmpcleaner.conf.default` and `/etc/tmpcleaner/tmpcleaner.conf.d` with default Makefile variables, reloads `systemd`, and leaves `tmpcleaner.timer` disabled and inactive.
2. **`tmpcleaner --dry-run`**: Runs the installed `/usr/local/bin/tmpcleaner --dry-run` against `/tmp` and exits `0`.
3. **`tmpcleaner.service` run**: Exercises the installed service under its real sandbox (`ProtectSystem=strict`, `ReadWritePaths=/tmp`, `RuntimeDirectory=tmpcleaner`, `Environment=TMPDIR=/run/tmpcleaner`, `ProtectHome=read-only`, `NoNewPrivileges=yes`) and real `abcmBM` timestamp aging (`TMPCLEANER_AGE=2s` via a service drop-in). Verifies that an aged unprotected file is removed while an aged file held open by a background `sleep`, an aged directory protected by `.tmpcleaner-keep`, `/tmp/krb5cc_qualify`, and a newly created file all survive; that the service logs the prose journal summary line and, with `TMPCLEANER_SUMMARY=json`, emits exactly one JSON completion record with `"exit_status":0`; and that `TMPCLEANER_METRICS` writes `tmpcleaner_last_exit_status 0` to `/var/lib/tmpcleaner-qualify/tmpcleaner.prom` through `ReadWritePaths=/var/lib/tmpcleaner-qualify`.
4. **`tmpcleaner.timer`**: Runs `systemctl enable --now tmpcleaner.timer` and verifies that the timer is enabled and listed with a scheduled next elapse in `systemctl list-timers`.
5. **Install/uninstall lifecycle**: Verifies that `make uninstall` disables the timer and removes the binary, units and `/etc/tmpcleaner/tmpcleaner.conf.default` while preserving `/etc/tmpcleaner/tmpcleaner.conf`; that reinstalling an unedited config creates no `.new`; that a subsequent `make install` keeps local edits to `/etc/tmpcleaner/tmpcleaner.conf` and writes `/etc/tmpcleaner/tmpcleaner.conf.new`; and that `make uninstall KEEP_CONFIG=0` removes the binary, units and `/etc/tmpcleaner`.

## How to run it

From the repository root on a host with Docker access:

```sh
sh tests/qualify-container.sh
```

The script prints one `PASS <check>` or `FAIL <check>: <detail>` line per check and exits `0` only when all five checks pass:

```text
PASS make install
PASS tmpcleaner --dry-run
PASS tmpcleaner.service run
PASS tmpcleaner.timer
PASS install/uninstall lifecycle
```

If `docker info` fails, the script prints `SKIP: docker unavailable` and exits `77`.

The checkout is bind-mounted read-only at `/src` and copied to `/build` inside the container, so the host working tree and host `/etc`/`/usr/local` are never modified. An `EXIT`/`INT`/`TERM` trap removes the container on completion or interruption.

## Cost and gate policy

- **First run**: Builds `tmpcleaner-qualify:latest` from `archlinux:latest` (installing `make` via `docker build --network host` with a Dockerfile on stdin) if the image is not already cached, then boots the container and sleeps 3 seconds to age fixtures.
- **Cached runs**: Reuses `tmpcleaner-qualify:latest` and runs offline (`--network none`) in roughly 5-10 seconds. To refresh the base image after an Arch update, remove it with `docker rmi tmpcleaner-qualify:latest` and re-run the script.
- **Optional**: Container qualification is optional and outside the mandatory developer gate (`sh tests/test.sh && make lint`). Run it when changing `tmpcleaner.service`, `tmpcleaner.timer`, `Makefile` install/uninstall rules, or journal/metrics integration.

## Container limits

- **Shared host kernel and clock**: The container shares the host kernel, `/proc` uptime, and system clock; kernel-specific behavior and real 12-hour wall-clock elapse are not isolated from the host.
- **No network (`--network none`)**: The running container has no network interfaces; image builds use `docker build --network host` so qualification does not depend on Docker bridge networking.
- **Degraded `systemd` state (`systemd-resolved` failing is expected)**: In an unprivileged `--network none` container (`/usr/lib/systemd/systemd` with `--cgroupns=private --security-opt writable-cgroups=true`), `systemd-resolved.service` fails during boot and `systemctl is-system-running` reports `degraded`. The qualification script accepts `running` or `degraded` once boot settles.

## Package lifecycle

`tests/qualify-package.sh` qualifies the AUR package lifecycle (`linux-tmpcleaner`) in the same disposable `systemd` container (`tmpcleaner-qualify:latest`). On the host it first runs `aurgen --build-only local` from the repository root (without `sudo`), rebuilding `aur/PKGBUILD` and `aur/.SRCINFO` from the tracked working tree and building the package archive with `makepkg` before binding that archive read-only into the container.

The checkout is also bind-mounted read-only at `/src` and copied to `/build` inside the container for the source migration check.

Inside the container it verifies six checks end to end:

1. **`pacman -U install`**: `pacman -U --noconfirm` installs `/usr/bin/tmpcleaner`, `/usr/lib/systemd/system/tmpcleaner.service`, `/usr/lib/systemd/system/tmpcleaner.timer`, `/etc/tmpcleaner/tmpcleaner.conf` and the license file under `/usr/share/licenses/linux-tmpcleaner/`, the installed service's `ExecStart` names `/usr/bin/tmpcleaner`, and `tmpcleaner.timer` is not enabled or active. `/etc/tmpcleaner/tmpcleaner.conf.default` is absent both on disk and in `pacman -Qlq linux-tmpcleaner`. The clean install output contains no source-install warning.
2. **`dry-run and service start`**: `/usr/bin/tmpcleaner --dry-run` exits `0` and `systemctl start tmpcleaner.service` succeeds.
3. **`pacman -U reinstall keeps config`**: After appending a local `x` rule to `/etc/tmpcleaner/tmpcleaner.conf`, reinstalling the package with `pacman -U --noconfirm` preserves that rule via the PKGBUILD `backup` entry.
4. **`pacman -R remove`**: `pacman -R --noconfirm linux-tmpcleaner` removes `/usr/bin/tmpcleaner` and the `systemd` units and leaves the edited configuration as `/etc/tmpcleaner/tmpcleaner.conf.pacsave`.
5. **`source install then package`**: After package removal, runs `make install` from `/build`, appends a local `x` rule to `/etc/tmpcleaner/tmpcleaner.conf`, and runs `make uninstall` with default `KEEP_CONFIG=1`. Installing the package with `pacman -U --noconfirm` then succeeds without filesystem conflicts and preserves the local rule.
6. **`source install left in place`**: Removes the package again with `pacman -R --noconfirm`, runs `make install` from `/build` without uninstalling it, then verifies that `pacman -U --noconfirm` succeeds and prints the source-install warning naming `/usr/local/bin/tmpcleaner`, `/etc/systemd/system/tmpcleaner.service` and `/etc/systemd/system/tmpcleaner.timer`.

Run it from the repository root on a host with `aurgen` and Docker access:

```sh
sh tests/qualify-package.sh
```

Like `tests/qualify-container.sh`, this check is optional and requires both `aurgen` and `docker` (exiting `77` with `SKIP: ...` when either is unavailable). Generated files left under `aur/` are gitignored.
