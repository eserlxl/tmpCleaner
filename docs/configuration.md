# Configuration

The exclusion list, service environment variables, age overrides, pressure mode, and removal listings.

Anything that must survive even while no program uses it goes into the
exclusion list in `/etc/tmpcleaner/tmpcleaner.conf` (format: `man tmpfiles.d`);
the age is set there too (`x` and `X` rules for paths under `/tmp` from the
distribution's `tmpfiles.d` files are appended automatically via
`systemd-tmpfiles --cat-config`, except a bare `/tmp`):

```text
x /tmp/my-long-job-*
```

Cleanup rule paths must be literal absolute paths, plain or simply quoted;
`%%` represents a literal percent. Backslash encodings, other `%` specifiers,
and ambiguous glob-capable roots stop every run before cleaning, including
runs without CLI exclusions. See the [supported path grammar](cli-reference.md)
and literal directory-root exceptions.

Service environment settings below go in a unit drop-in via `sudo systemctl edit tmpcleaner.service` (works for both AUR and source installs).

## Environment variables

- `TMPCLEANER_CONF`: Path to configuration file (default: `/etc/tmpcleaner/tmpcleaner.conf`).
- `TMPCLEANER_AGE`: Override duration on every `d` rule (e.g. `6h`, `30m`).
- `TMPCLEANER_FULL_PERCENT`: Threshold percentage of `/tmp` usage (1-100); the larger of block and inode usage counts (`-` is 0), and a `df` error aborts the run.
- `TMPCLEANER_FULL_AGE`: Age duration to use when `/tmp` usage meets or exceeds `TMPCLEANER_FULL_PERCENT`.
- `TMPCLEANER_LIST`: Set to 1 to list removed paths with control bytes and backslashes escaped (default: off).
- `TMPCLEANER_METRICS`: Absolute path of a `*.prom` file for the `node_exporter` textfile collector (real runs only).

A configuration file other than the installed one can be previewed with
`sudo env TMPCLEANER_CONF=/path/to/custom.conf tmpcleaner --dry-run`; an
unreadable file stops the run before cleaning.

## Override the age

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

## Use a shorter age when /tmp is nearly full

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
Below the threshold, the configured age or `TMPCLEANER_AGE` applies; preview
modes (`--print-rules`, `--check`, `--dry-run`) report
`tmpcleaner: /tmp is N% full (blocks B%, inodes I%), below T%; keeping the configured age`
on stderr, while a real run prints nothing extra.

If `df` fails or its output cannot be parsed, tmpcleaner aborts: it prints `tmpcleaner: cannot read /tmp usage` and exits 1 (2 with `--check`) in every
mode, and nothing is removed.

**The shorter age applies to every unprotected file**, so recent temporary
work can be deleted sooner. In-use protection and configured exclusions
still apply.

## List removed paths

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
