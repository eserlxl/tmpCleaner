# Command-line reference

Every `tmpcleaner` option, what `--check` reports, and its exit statuses.

## Options

- `-h`, `--help`: Show help and exit (exits 0 even when configuration is missing).
- `--print-rules`: Print the configured rules and generated in-use exclusions without deleting anything (`sudo tmpcleaner --print-rules`). Trailing `--exclude-prefix=PATH` filters add their `x` exclusions to the printed rules; any other trailing argument exits 2 before the configuration is read. It still runs the in-use scan and the exclusion-only rule check, but never cleans.
- `--print-in-use0`: Export unique in-use `/tmp` paths, byte-sorted in the C locale and terminated by NUL, preserving filename bytes. This standalone option rejects every extra argument (exit 2).
- `--print-holders0`: Export unique in-use `/tmp` paths with known holder PIDs as NUL-separated `PATH\0PIDS\0` pairs (where `PIDS` is space-separated), byte-sorted by path in the C locale. This standalone option rejects every extra argument (exit 2).
- `--suggest-exclusions`: Print `# N entries ...` comments and escaped `x` rules for each top-level entry the next run would clean, deletes nothing, and writes no metrics (`sudo tmpcleaner --suggest-exclusions`). This standalone option rejects every extra argument (exit 2); see [How to keep something](what-gets-deleted.md#how-to-keep-something). When the `tmpfiles.d` configuration still gives `/tmp` an age, it also warns on stderr that the distribution's `systemd-tmpfiles-clean.timer` removes older entries, kept ones included; stdout and the exit status are unaffected (see [Scope](what-gets-deleted.md#scope)).
- `--check PATH`: Report whether an existing absolute `/tmp` path would be removed without deleting anything (`sudo tmpcleaner --check /tmp/my-job/file`).
- `--check0`: Judge NUL-terminated `/tmp` paths from standard input in one scan and print `removed\0PATH\0` or `kept\0PATH\0` records without deleting anything (`find /tmp/my-job -print0 | sudo tmpcleaner --check0`).
- `--dry-run`, `--prefix=PATH`, `--exclude-prefix=PATH`: `--dry-run` previews what would be removed without deleting and prints a summary (`tmpcleaner: would remove N files and M directories`, followed by up to 10 top-level `/tmp` entries ordered by descending count then name as `tmpcleaner:   <count> under <path>`, with control bytes in `<path>` printed as `?`) to stderr; `--prefix=PATH` only applies rules with that prefix (passed to `systemd-tmpfiles`); `--exclude-prefix=PATH` (absolute path, `=` form only; parent directories are canonicalized so `..` components and symlinked parents still match) keeps PATH and everything below it, in addition to the in-use protection, and never lets a path that is in use be removed (`sudo tmpcleaner --dry-run --exclude-prefix=/tmp/my-job`); any other argument (for example `--remove`, `--create`, `--purge`, `--boot`, `--root=...`, `--replace=...`, or a positional config file) exits 2 before any config is read or anything is cleaned.

`--check PATH` requires an existing absolute path under `/tmp`. It prints
`would be removed: PATH` (exit 0) or `kept: PATH` (exit 1, only) on stdout, using the
same age, pressure and in-use rules as a real run; when a path is kept, it also
prints one reason line to stderr (`tmpcleaner: in use by a running process: PID ... (...)`
(or without `: PID ...` when no holder PID is known),
`tmpcleaner: holds an in-use path: ...; used by PID ... (...)`
(or without `; used by PID ...` when no holder PID is known),
`tmpcleaner: inside an in-use directory: ...; used by PID ... (...)`,
`tmpcleaner: kept by a .tmpcleaner-keep marker in ...`,
`tmpcleaner: kept by an explicit --exclude-prefix`, or
`tmpcleaner: not old enough, or kept by a configuration rule`). Control bytes in
these paths and in `--check` and `--check0` error messages are printed as `?`. Every error exits 2: invalid
paths or missing arguments, unreadable configuration, invalid `TMPCLEANER_*`
values, missing `/proc`, a failed in-use scan, and a `systemd-tmpfiles` failure
other than 73. Each prints a message. Exit 1 therefore always means "kept". It reads the preview's text, which a
crafted file name can imitate, so it may raise a false "would be removed" but
never a false "kept"; paths containing newlines (LF) or carriage returns (CR),
directories holding such names, and paths whose directories cannot be read
cannot be judged and exit 2.

`--check0` reads NUL-terminated paths from standard input, validates every one
with the same rules as `--check` (any invalid path exits 2 naming it, before any
verdict is printed), runs rule generation and the dry-run preview once, and
prints `removed\0PATH\0` or `kept\0PATH\0` per input path in input order with
`PATH` exactly as given. Kept reasons are not printed (use `--check` for one
path's reason). It requires at least one path on standard input; an empty list
exits 2 before configuration is read. It exits 0 when every path would be removed,
1 when at least one is kept, and 2 on any error.

Checks also exit 2 when any retained cleanup root uses a noncanonical spelling:
`.` or `..` components, duplicate or trailing slashes, or a symlink alias.
Use canonical configured roots for reliable preview matching. Roots removed by
in-use protection or `--exclude-prefix` filtering do not block a check. Other
modes continue to accept these spellings under the usual safety rules.

Append repeated `--exclude-prefix=PATH` options to `--check`, `--check0` or `--print-rules` to check or print with the same
temporary exclusions as a real run, for example
`sudo tmpcleaner --check /tmp/my-job/file --exclude-prefix=/tmp/my-job`.
Exclusions use the same canonicalized, literal paths as other modes. Actual
in-use protection keeps its own reason. Other trailing options, including
`--prefix` and `--dry-run`, are rejected before configuration is read.

In-use paths and explicit exclusions protect contents even when the configuration
cleans the protected directory or a deeper root directly. Rule paths
must be literal absolute paths, unquoted or simply single/double quoted;
`%%` denotes a literal percent. Backslash encodings, other `%` specifiers and
glob patterns in glob-capable rule types stop the run before cleaning (exit 1,
or 2 with `--check`). Directory-root types `d`, `D`, `v`, `q`, `Q`, and `C` may
contain literal glob characters. Existing `x`/`X` rules are preserved.
LF and CRLF record endings and ordinary spaces/tabs are accepted. Any remaining
raw CR, FF or VT byte stops every mode, including in comments or `x`/`X` records;
generated exclusions use encoded paths and remain supported.
Every non-`x`/`X` root must normalize under `/tmp` and resolve inside `/tmp`'s
canonical tree. Outside roots and lexical or symlink escapes stop all modes
before cleanup, including with `--prefix` (exit 1, or 2 with `--check`).
`/tmp` itself must not be a symlink.
Non-`x`/`X` roots at or below nested `/tmp` mountpoints are refused too, including
bind mounts and missing descendants. A parent root such as `/tmp` remains valid,
including when `/tmp` itself is a mount. Unreadable or malformed mount information
stops every mode before cleanup.

A raw inventory can be consumed without decoding tmpfiles rules, for example
`sudo tmpcleaner --print-in-use0 | xargs -0 -r stat --` (or `--print-holders0` for `PATH\0PIDS\0` pairs).
It reports process-held paths, including working directories; configured `x`/`X`
exclusions are not added, and the command's own scratch directory and descendants are omitted.
It validates configuration (including the supported root grammar above) and
`TMPCLEANER_*` values just like `--print-rules`, but never cleans or writes metrics.
Use sufficient privileges to inspect the relevant processes. This is a snapshot
of visible processes and paths, not a promise that they will remain in use.
Scan, filtering or sorting failures exit nonzero with empty stdout.

A failed in-use scan stops every mode before cleaning
(`--print-rules`, `--print-in-use0`, and `--print-holders0` print nothing to stdout; `--dry-run` and the real run exit
non-zero and nothing is removed).
