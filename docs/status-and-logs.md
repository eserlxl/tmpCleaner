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
`tmpcleaner_removed_directories`, `tmpcleaner_last_run_timestamp_seconds`, and
`tmpcleaner_last_exit_status` gauges for the Prometheus `node_exporter`
textfile collector. Preview modes (`--dry-run`, `--print-rules`, `--print-in-use0`, `--check`)
never touch the file, and a write failure logs one line to stderr without
changing the run's exit status.

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
