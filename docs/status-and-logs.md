# Status and logs

Timer status, the per-run summary, Prometheus metrics, scratch space, and the run interval.

```sh
systemctl list-timers tmpcleaner.timer
journalctl -u tmpcleaner.service
```

Each real run logs one summary, including runs that remove nothing:

```text
tmpcleaner: removed 3 files and 2 directories
```

The counts compare listings of the cleaned trees taken just before and just
after the run, including roots selected by `d`, `D`, `e`, `v`, `q`, `Q`, `C`,
`r`, and `R` rules and their modifiers. Removed roots themselves count too;
overlapping roots count each path once, and scratch paths are skipped.
The backend decides which rules apply, including boot-only rules and `r`/`R`
age cleanup (systemd 262 or newer). Names of any shape are counted; anything
another program deletes in that second is counted too. Cleanup roots must follow the
[literal path grammar](cli-reference.md); unsupported encoded or ambiguous
roots stop the run before cleaning. `systemd-tmpfiles` itself logs to
the journal as usual, so warnings keep their severity.

When `TMPCLEANER_METRICS` is set to the absolute path of a `*.prom` file (for
example `/var/lib/node_exporter/textfile_collector/tmpcleaner.prom`), each real
run atomically writes `tmpcleaner_removed_files`,
`tmpcleaner_removed_directories`, `tmpcleaner_last_run_timestamp_seconds`,
`tmpcleaner_last_exit_status`, `tmpcleaner_pressure_mode_active`, and
`tmpcleaner_last_run_duration_seconds` gauges for the Prometheus `node_exporter`
textfile collector. Preview modes (`--dry-run`, `--print-rules`, `--print-in-use0`, `--check`)
never touch the file, and a write failure logs one line to stderr without
changing the run's exit status.

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
Publication uses the shell's exit handler; unhandled termination or `SIGKILL`
can prevent that handler from running and leave the previous file in place.

The service runs with `ProtectSystem=strict`, which leaves only `/tmp`
writable, so the drop-in must also allow the collector directory
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
