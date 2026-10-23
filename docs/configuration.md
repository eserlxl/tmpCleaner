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
- `TMPCLEANER_AGE`: Override duration on every `d` and `D` rule (any modifier) (e.g. `6h`, `30m`).
- `TMPCLEANER_MARKER_AGE`: Expire `.tmpcleaner-keep` protection by marker modification age (e.g. `1h`; default: never).
- `TMPCLEANER_PROTECT_TMPDIR`: Set to `1` to protect live processes' `TMPDIR` directories strictly below `/tmp` when owned by the declaring process's real UID (default: off).
- `TMPCLEANER_REQUIRE_COMPLETE_SCAN`: Set to `1` to refuse cleanup if the `/tmp` inode walk or marker walk is incomplete. Unset or empty keeps the default tolerance; other values stop before cleaning.
- `TMPCLEANER_PREVIEW`: Set to `1` to make cleanup runs use `--dry-run`; unset or empty keeps normal cleanup. Other values stop before cleaning.
- `TMPCLEANER_FULL_PERCENT`: Threshold percentage of `/tmp` usage (1-100); the larger of block and inode usage counts (`-` is 0), and a `df` error aborts the run.
- `TMPCLEANER_FULL_AGE`: Age duration to use when `/tmp` usage meets or exceeds `TMPCLEANER_FULL_PERCENT`.
- `TMPCLEANER_LIST`: Set to `1` for escaped removal logs, `top` for the top-10 per-entry breakdown, or `nul` for raw NUL-separated paths on stdout (real runs only; default: off).
- `TMPCLEANER_SUMMARY`: Set to `json` for one JSON completion record on stderr per real run (unset or empty: usual prose; any other value stops before cleaning).
- `TMPCLEANER_METRICS`: Absolute path of a `*.prom` file for the `node_exporter` textfile collector (real runs only).

A configuration file other than the installed one can be previewed with
`sudo env TMPCLEANER_CONF=/path/to/custom.conf tmpcleaner --dry-run`; an
unreadable file, dangling `*.conf.d` symlink, non-directory `*.conf.d` entry,
unreadable `*.conf.d` directory, or `*.conf` drop-in (including a dangling
symlink) stops the run before cleaning.

## Rehearse timer runs

To watch scheduled runs before allowing deletion, run
`sudo systemctl edit tmpcleaner.service` and add:

```ini
[Service]
Environment=TMPCLEANER_PREVIEW=1
```

Reload the unit and enable the timer:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now tmpcleaner.timer
journalctl -u tmpcleaner
```

Read the journal for a few days to see what each run would remove. Each run
prints a preview notice and the usual `--dry-run` paths and counts, without
removing anything, writing metrics or emitting a JSON completion record.
Manual runs can use `sudo env TMPCLEANER_PREVIEW=1 tmpcleaner` too.
Explicit `--dry-run`, help, `--print-*`, `--suggest-exclusions`, `--check` and
`--check0` keep their existing behavior without an extra notice.

When ready, remove the `Environment=TMPCLEANER_PREVIEW=1` line using
`sudo systemctl edit tmpcleaner.service`, then run
`sudo systemctl daemon-reload`. Subsequent timer runs perform normal cleanup.

## Override the age

Set `TMPCLEANER_AGE` to override the duration on every `d` and `D` rule (any modifier) (e.g. `6h`, `30m`) while keeping
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

## Expire abandoned markers

Set `TMPCLEANER_MARKER_AGE` to a positive integer of at most six digits
followed by `m`, `min`, `h`, `d`, or `w` (whole minutes or larger units), for
example `1h`; zero and longer numbers are invalid. Only markers
modified within that duration protect their directories. A long-running job
can renew protection by touching its `.tmpcleaner-keep` file before it expires.
Expired markers no longer exclude the directory; the usual cleanup age and
other protections still apply. This affects real runs and all previews and
checks. Unset preserves markers regardless of age; an empty or invalid value
stops the run before cleaning.

For the service, run `sudo systemctl edit tmpcleaner.service` and add:

```ini
[Service]
Environment=TMPCLEANER_MARKER_AGE=1h
```

## Protect live jobs' TMPDIR directories

Set `TMPCLEANER_PROTECT_TMPDIR=1` to keep a directory and everything below it
when a live process declares it as `TMPDIR`, even if none of its files are
open, provided the directory is owned by the declaring process's real UID.
Each run reads NUL-separated process environments from `/proc` and
resolves the directory inside that process's root, matching it by device and
inode like a working directory. Unreadable environments or real UIDs are
silently skipped; a directory owned by another UID adds no TMPDIR protection.
Only absolute paths strictly below `/tmp` qualify; bare `/tmp` (including
spellings such as `/tmp/.`), relative paths, paths escaping `/tmp`, missing
paths and non-directories add no protection. When the process exits, the next
scan adds no protection from its `TMPDIR`; the usual age and other protections
still apply.

Unset or empty keeps the default behavior. Any value other than `1` or empty
stops the run before cleaning. For the service, add a drop-in with
`sudo systemctl edit tmpcleaner.service`:

```ini
[Service]
Environment=TMPCLEANER_PROTECT_TMPDIR=1
```

## Require complete protection walks

Set `TMPCLEANER_REQUIRE_COMPLETE_SCAN=1` to reject find status 1 from either
the `/tmp` inode walk or the `.tmpcleaner-keep` marker walk. An unreadable or
vanished subtree can otherwise hide an in-use path or marker. The run stops
before cleaning with `cannot apply path protections; nothing was removed`
and exits 1 (2 with `--check` or `--check0`). This also applies to previews.
Tolerance of vanished `/proc` entries is unchanged.

Unset or empty preserves the default tolerance of partial walks. Any other
value stops before cleaning. For the service, add a drop-in with
`sudo systemctl edit tmpcleaner.service`:

```ini
[Service]
Environment=TMPCLEANER_REQUIRE_COMPLETE_SCAN=1
```

## Refuse cleanup with a stale in-use snapshot

Set `TMPCLEANER_MAX_SCAN_AGE` to a positive integer number of seconds of at
most six digits, for example `30`. Unset or empty leaves cleanup unchanged;
zero, longer numbers and other values stop the run before cleaning with
`invalid TMPCLEANER_MAX_SCAN_AGE`.

For real cleanup, tmpcleaner reads the first field of `/proc/uptime` just
before the in-use scan and again immediately before invoking cleanup. This
includes the scan itself and the walk that snapshots the cleanup trees. If
the elapsed time exceeds the limit, it exits 1 without cleaning and reports
`tmpcleaner: in-use snapshot is <n>s old (limit <m>s); nothing was removed`.
Elapsed seconds include fractional seconds; exactly the limit is allowed.
Unreadable or invalid uptime also refuses cleanup (`?s` means age unknown).
All preview modes, including `TMPCLEANER_PREVIEW=1`, ignore the age limit;
the setting is still validated.

For the service, run `sudo systemctl edit tmpcleaner.service` and add:

```ini
[Service]
Environment=TMPCLEANER_MAX_SCAN_AGE=30
```

Choose a limit above the usual scan and snapshot time. A slow or large tree
can otherwise prevent cleanup on every run. This bounds snapshot age at
cleanup start; it does not protect files opened after the scan. See
[protection limits](what-gets-deleted.md#limits).

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
counts as 0. At or above the threshold, it overrides the duration of every `d` and `D` rule,
including `TMPCLEANER_AGE`, and reports
`tmpcleaner: /tmp is N% full (blocks B%, inodes I%), using age X` on stderr.
Below the threshold, the configured age or `TMPCLEANER_AGE` applies; preview
modes (`--print-rules`, `--print-in-use0`, `--print-holders0`, `--check`,
`--check0`, `--suggest-exclusions`, `--dry-run`) report
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
lines on stderr right after the prose summary (before the completion record
with `TMPCLEANER_SUMMARY=json`), grouped by top-level `/tmp` entry
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

## Emit JSON completion records

Set `TMPCLEANER_SUMMARY=json` to replace the prose disappearance summary with
one fixed-schema JSON line on stderr per real run, including failed runs:

```json
{"tmpcleaner":"run","exit_status":0,"removed_files":3,"removed_directories":2,"counts_available":true}
```

`tmpcleaner` is always `"run"`; `exit_status`, `removed_files`, and
`removed_directories` are integers, and `counts_available` is a boolean.
Failed runs use zero counts and `counts_available:false`, including failures
before cleanup and backend failures after partial deletion. Successful runs
with unavailable counts also use zeros and `false`; measured zero removals
use `true`. Exit statuses stay unchanged. All preview modes emit no completion
record. Unset or empty preserves prose output; other values stop before cleaning.

For journal collectors, add this service drop-in with
`sudo systemctl edit tmpcleaner.service`:

```ini
[Service]
Environment=TMPCLEANER_SUMMARY=json
```

No collector-directory write access is needed. See
[status and logs](status-and-logs.md) for counting semantics and signal handling.
