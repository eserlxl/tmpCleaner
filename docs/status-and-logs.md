# Status and logs

Timer status, the per-run summary, Prometheus metrics, scratch space, and the run interval.

```sh
systemctl list-timers tmpcleaner.timer
journalctl -u tmpcleaner.service
journalctl -p warning -u tmpcleaner.service
```

Each real run logs one summary, including runs that remove nothing:

```text
tmpcleaner: 3 files and 2 directories disappeared during the run
```

The counts compare listings of the cleaned trees taken just before and just
after the run, including roots selected by `d`, `D`, `e`, `v`, `q`, `Q`, `C`,
`r`, and `R` rules and their modifiers. Removed roots themselves count too;
overlapping roots count each path once, and scratch paths are skipped.
The backend decides which rules apply, including boot-only rules and `r`/`R`
age cleanup (systemd 262 or newer). Names of any shape are counted; anything
another program deletes in that second is counted too. The line counts
disappearances, so it is not proof that tmpcleaner deleted a given path.
Cleanup roots must follow the
[literal path grammar](cli-reference.md); unsupported encoded or ambiguous
roots stop the run before cleaning. When `JOURNAL_STREAM` matches stderr,
`tmpcleaner` prefixes its own warnings with `<4>` and errors with `<3>` so
`journalctl -p warning -u tmpcleaner.service` shows only warnings and errors;
`systemd-tmpfiles` itself logs to the journal as usual, so warnings keep their
severity.

`TMPCLEANER_LIST=1` adds escaped path records on stderr. `TMPCLEANER_LIST=nul`
instead exports each path observed to disappear once as raw bytes plus NUL on
stdout, including directories, without type prefixes or an ordering guarantee.
The summary and backend output stay on stderr in this mode. These are observed
disappearances, including other processes' deletions, rather than proof that
tmpcleaner deleted each path. Inspect the exit status: a failed cleanup can
still export paths it removed before failing. Preview output is unchanged.

When `TMPCLEANER_METRICS` is set to the absolute path of a `*.prom` file (for
example `/var/lib/node_exporter/textfile_collector/tmpcleaner.prom`), each real
run atomically writes `tmpcleaner_removed_files`,
`tmpcleaner_removed_directories`, `tmpcleaner_removed_bytes`,
`tmpcleaner_protected_paths`, `tmpcleaner_marked_directories`,
`tmpcleaner_last_run_timestamp_seconds`,
`tmpcleaner_last_success_timestamp_seconds`, `tmpcleaner_last_exit_status`,
`tmpcleaner_pressure_mode_active`, and `tmpcleaner_last_run_duration_seconds`
gauges for the Prometheus `node_exporter` textfile collector. Preview modes
(`--dry-run`, `--print-rules`, `--print-in-use0`, `--print-holders0`, `--check`,
`--check0`, `--suggest-exclusions`) never touch the file, and a write failure
logs one line to stderr without changing the run's exit status.

`tmpcleaner_removed_bytes` is the summed apparent byte size (`find` `%s`) of
non-directory entries observed to disappear during the run, or `0` when the
run fails before cleanup counts are obtained.

`tmpcleaner_protected_paths` is the number of unique in-use `/tmp` paths the
last run protected from cleanup (excluding the scratch directory and its
descendants, as `--print-in-use0` reports), or `0` when the run failed before
the in-use scan.

`tmpcleaner_marked_directories` is the number of `/tmp` directories
`.tmpcleaner-keep` markers kept in the last run, or `0` when the run failed
before the scan. A value that keeps growing means markers were left behind,
listed with `find /tmp -mindepth 2 -maxdepth 3 -name .tmpcleaner-keep`.
With `TMPCLEANER_MARKER_AGE` set, only markers modified within that duration
count; expired markers no longer protect their directories. Jobs can renew
protection by touching the marker; see
[marker expiry](configuration.md#expire-abandoned-markers).

`tmpcleaner_last_success_timestamp_seconds` is the Unix completion timestamp of
the last real run that exited `0`. Failed runs carry forward the previous value
from an existing metrics file, or write `0` when no prior successful timestamp
is recorded.

```yaml
groups:
  - name: tmpcleaner
    rules:
      - alert: TmpcleanerStalled
        expr: time() - tmpcleaner_last_success_timestamp_seconds > 3600 and tmpcleaner_last_success_timestamp_seconds > 0
        for: 15m
```

The 3600 threshold allows four cycles of the 15-minute timer interval before
alerting, while a value of `0` means the cleaner has never succeeded since
metrics were enabled (`tmpcleaner_last_success_timestamp_seconds == 0 and
tmpcleaner_last_exit_status != 0`).

`tmpcleaner_pressure_mode_active` is `1` when the run selected the pressure age
override, including when a later step failed. It is `0` when no override was
selected, including disabled pressure mode and failures before that decision.
This records the decision, not whether any paths were removed.

`tmpcleaner_last_run_duration_seconds` uses `/proc/uptime` to measure elapsed
time from metrics initialization to publication, including failed attempts.
It excludes writing the metrics file and scratch teardown. Values have two
decimal places and are independent of wall-clock changes; unavailable or
invalid timing produces `NaN` while other gauges are still published.
Previews and runs without metrics do not sample duration. This interval does
not exactly match the service's `TimeoutStartSec` interval.

Metrics publication is armed after CLI and metrics-path validation and preview
classification, before scratch creation. Real runs that fail after that point
(including configuration, pressure, scratch or in-use scan failures) replace
stale success metrics with their nonzero exit status and zero removals when
cleanup counts were not obtained. Successful cleanup retains its measured
counts. Invalid CLI usage or an invalid metrics path leaves metrics untouched.
All preview modes preserve an existing metrics file even when they fail.
Publication uses the shell's exit handler: `SIGHUP`, `SIGINT`, and `SIGTERM`
publish exit status `129`, `130`, and `143`, while `SIGKILL` leaves the
previous file in place.

The service runs with `ProtectSystem=strict`, which leaves only `/tmp`
and the runtime directory `/run/tmpcleaner` writable, so the drop-in must also
allow the collector directory
(`sudo systemctl edit tmpcleaner.service`):

```ini
[Service]
Environment=TMPCLEANER_METRICS=/var/lib/node_exporter/textfile_collector/tmpcleaner.prom
ReadWritePaths=/var/lib/node_exporter/textfile_collector
```

The service sets `RuntimeDirectory=tmpcleaner` and `Environment=TMPDIR=/run/tmpcleaner`
so its scratch files live outside `/tmp` and a full `/tmp` still gets cleaned.
For manual runs where `TMPDIR` is unset, `tmpcleaner` falls back to a private
scratch directory under `/dev/shm` when `/tmp` is full.

Change the interval with `sudo systemctl edit tmpcleaner.timer`. A run that
takes longer than ten minutes is stopped and logged as failed; the next timer
run starts normally.
