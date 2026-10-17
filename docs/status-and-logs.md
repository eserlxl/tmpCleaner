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
after the run, so they are exact for names of any shape; anything another
program deletes in that second is counted too. A `d` path written with escapes
in the configuration (`\x20`, `\"`) is not decoded for these listings, so
removals under it are left out of the counts (cleaning is unaffected). `systemd-tmpfiles` itself logs to
the journal as usual, so warnings keep their severity.

When `TMPCLEANER_METRICS` is set to the absolute path of a `*.prom` file (for
example `/var/lib/node_exporter/textfile_collector/tmpcleaner.prom`), each real
run atomically writes `tmpcleaner_removed_files`,
`tmpcleaner_removed_directories`, `tmpcleaner_last_run_timestamp_seconds`, and
`tmpcleaner_last_exit_status` gauges for the Prometheus `node_exporter`
textfile collector. Preview modes (`--dry-run`, `--print-rules`, `--check`)
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
