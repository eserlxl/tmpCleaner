# Configuration

The exclusion list, service environment variables, age overrides, pressure mode, and removal listings.

Anything that must survive even while no program uses it goes into the
exclusion list in `/etc/tmpcleaner/tmpcleaner.conf` or a `*.conf` drop-in file
in `/etc/tmpcleaner/tmpcleaner.conf.d` (format: `man tmpfiles.d`);
the age is set there too (`x` and `X` rules for paths under `/tmp` from the
distribution's `tmpfiles.d` files are appended automatically via
`systemd-tmpfiles --cat-config`, except a bare `/tmp`):

```text
x /tmp/my-long-job-*
```

Regular files matching `/etc/tmpcleaner/tmpcleaner.conf.d/*.conf` (or
`$TMPCLEANER_CONF.d/*.conf`) are read after the main file in byte order (`C`
locale), each followed by a newline, so packages and configuration management
tools can install their own exclusions (for example
`/etc/tmpcleaner/tmpcleaner.conf.d/50-my-job.conf`) without editing
`tmpcleaner.conf`. Other filenames and subdirectories in the directory are
ignored, and a missing or empty directory is not an error; a dangling
`*.conf.d` symlink, a non-directory `*.conf.d` entry, an unreadable or
unsearchable `*.conf.d` directory, a dangling `*.conf` symlink, or any other
unreadable or non-regular `*.conf` entry stops the run before cleaning. An
`x`/`X` line that `systemd-tmpfiles` cannot parse stops every mode before
cleaning.

An exclusion applies while a parent cleanup rule traverses the tree. A
separately configured cleanup root at or below the excluded directory can still
clean its contents; remove the conflicting cleanup rule. See [how to keep something](what-gets-deleted.md#how-to-keep-something).

Cleanup roots must remain under `/tmp`: both the normalized literal path and
its resolved target must stay in that tree. Outside roots, `..` escapes and
symlinks leading outside `/tmp` stop every mode before cleanup; custom configs
cannot extend the process scanner's `/tmp` protection to other directories.
Existing `x`/`X` exclusion lines are preserved.
`/tmp` itself must not be a symlink, matching the scanner's literal `/tmp` scope.
Separately configured roots at or below nested `/tmp` mounts are also refused,
including bind mounts and missing descendants. Keep cleanup on the parent
tree, whose traversal skips nested mounts; a mount at `/tmp` itself is supported.
Unreadable or malformed mount information stops the run before cleaning.

Cleanup rule paths must be literal absolute paths, plain or simply quoted;
`%%` represents a literal percent. Backslash encodings, other `%` specifiers,
and ambiguous glob-capable roots stop every run before cleaning, including
runs without CLI exclusions. See the [supported path grammar](cli-reference.md)
and literal directory-root exceptions.
Records may use LF or CRLF endings, with spaces or tabs between fields.
Any other raw carriage return (CR), form feed (FF) or vertical tab (VT) is
rejected, including in comments and `x`/`X` records, before rules are forwarded.
Generated exclusions retain their encoded control-byte paths.

Service environment settings below go in a unit drop-in via `sudo systemctl edit tmpcleaner.service` (works for both AUR and source installs).

## Environment variables

- `TMPCLEANER_CONF`: Path to configuration file (default: `/etc/tmpcleaner/tmpcleaner.conf`; regular files in `$TMPCLEANER_CONF.d/*.conf` are read after it).
- `TMPCLEANER_AGE`: Override duration on every `d` rule (e.g. `6h`, `30m`).
- `TMPCLEANER_FULL_PERCENT`: Threshold percentage of `/tmp` usage (1-100); the larger of block and inode usage counts (`-` is 0), and a `df` error aborts the run.
- `TMPCLEANER_FULL_AGE`: Age duration to use when `/tmp` usage meets or exceeds `TMPCLEANER_FULL_PERCENT`.
- `TMPCLEANER_LIST`: Set to `1` for escaped removal logs, `top` for the top-10 per-entry breakdown, or `nul` for raw NUL-separated paths on stdout (real runs only; default: off).
- `TMPCLEANER_METRICS`: Absolute path of a `*.prom` file for the `node_exporter` textfile collector (real runs only).

A configuration file other than the installed one can be previewed with
`sudo env TMPCLEANER_CONF=/path/to/custom.conf tmpcleaner --dry-run`; an
unreadable file, dangling `*.conf.d` symlink, non-directory `*.conf.d` entry,
unreadable `*.conf.d` directory, or `*.conf` drop-in (including a dangling
symlink) stops the run before cleaning.

## Override the age

Set `TMPCLEANER_AGE` to override the duration on every `d` rule (e.g. `6h`, `30m`) while keeping
its age-by letters and the config unchanged. Use a non-negative integer with
an optional unit: `us`, `ms`, `s`, `m`, `min`, `h`, `d`, or `w` (seconds when
omitted). An empty or invalid value stops the run before cleaning; when unset,
the configured ages apply. A rule whose quoted path holds spaces keeps its
configured age, with a warning.
`d` rules without an age (`-` or omitted) are left as they are.

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
in the same format as `TMPCLEANER_AGE`) to enable it. With only one variable
set, it is ignored with a warning and the usual age applies. Invalid values
always stop the run before cleaning.

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
modes (`--print-rules`, `--print-in-use0`, `--print-holders0`, `--check`,
`--check0`, `--dry-run`) report
`tmpcleaner: /tmp is N% full (blocks B%, inodes I%), below T%; keeping the configured age`
on stderr, while a real run prints nothing extra.

With `TMPCLEANER_METRICS` enabled, `tmpcleaner_pressure_mode_active` records this
decision: `1` if the pressure age override was selected, even if a later step
failed; `0` if no override was selected before exit. See [run metrics](status-and-logs.md).

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
Set `TMPCLEANER_LIST=top` to log up to ten `tmpcleaner:   N under PATH`
lines on stderr right after the summary, grouped by top-level `/tmp` entry
in descending count order (ties broken by path byte order) with control bytes
shown as `?`, matching the `--dry-run` breakdown.
Listings and counts cover every supported age-cleanup rule type, including
removed roots; overlapping configured roots do not duplicate paths. See
[counting and metrics](status-and-logs.md) for details.
Set `TMPCLEANER_LIST=nul` to export the same observed disappearances as exact
path bytes followed by NUL on stdout, without type prefixes. Each path appears
once, including directories; ordering is unspecified. Summary and backend
output go to stderr. Check the exit status: a failed backend can still remove
paths and produce records, and another process's deletions can also appear.
Preview modes keep their usual output and do not export removals.
Unset or empty leaves the usual output unchanged (default: off); values other than `1`, `top` or `nul` stop
the run before cleaning.

For the service, run `sudo systemctl edit tmpcleaner.service` and add:

```ini
[Service]
Environment=TMPCLEANER_LIST=1
```
