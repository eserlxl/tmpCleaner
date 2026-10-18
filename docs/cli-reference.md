# Command-line reference

Every `tmpcleaner` option, what `--check` reports, and its exit statuses.

## Options

- `-h`, `--help`: Show help and exit (exits 0 even when configuration is missing).
- `--print-rules`: Print the configured rules and generated in-use exclusions without deleting anything (`sudo tmpcleaner --print-rules`).
- `--print-in-use0`: Export unique in-use `/tmp` paths, byte-sorted in the C locale and terminated by NUL, preserving filename bytes. This standalone option rejects every extra argument (exit 2).
- `--check PATH`: Report whether an existing absolute `/tmp` path would be removed without deleting anything (`sudo tmpcleaner --check /tmp/my-job/file`).
- `--dry-run`, `--prefix=PATH`, `--exclude-prefix=PATH`: `--dry-run` previews what would be removed without deleting and prints a summary (`tmpcleaner: would remove N files and M directories`) to stderr; `--prefix=PATH` only applies rules with that prefix (passed to `systemd-tmpfiles`); `--exclude-prefix=PATH` (absolute path, `=` form only; parent directories are canonicalized so `..` components and symlinked parents still match) keeps PATH and everything below it, in addition to the in-use protection, and never lets a path that is in use be removed (`sudo tmpcleaner --dry-run --exclude-prefix=/tmp/my-job`); any other argument (for example `--remove`, `--create`, `--purge`, `--boot`, `--root=...`, `--replace=...`, or a positional config file) exits 2 before any config is read or anything is cleaned.

`--check PATH` requires an existing absolute path under `/tmp`. It prints
`would be removed: PATH` (exit 0) or `kept: PATH` (exit 1, only) on stdout, using the
same age, pressure and in-use rules as a real run; when a path is kept, it also
prints one reason line to stderr (`tmpcleaner: in use by a running process`,
`tmpcleaner: holds an in-use path: ...`,
`tmpcleaner: inside an in-use directory: ...`,
`tmpcleaner: kept by an explicit --exclude-prefix`, or
`tmpcleaner: not old enough, or kept by a configuration rule`). Control bytes in
these paths are printed as `?`. Every error exits 2: invalid
paths or missing arguments, unreadable configuration, invalid `TMPCLEANER_*`
values, missing `/proc`, a failed in-use scan, and a `systemd-tmpfiles` failure
other than 73. Each prints a message. Exit 1 therefore always means "kept". It reads the preview's text, which a
crafted file name can imitate, so it may raise a false "would be removed" but
never a false "kept"; paths containing newlines (LF) or carriage returns (CR),
directories holding such names, and paths whose directories cannot be read
cannot be judged and exit 2.

Checks also exit 2 when any retained cleanup root uses a noncanonical spelling:
`.` or `..` components, duplicate or trailing slashes, or a symlink alias.
Use canonical configured roots for reliable preview matching. Roots removed by
in-use protection or `--exclude-prefix` filtering do not block a check. Other
modes continue to accept these spellings under the usual safety rules.

Append repeated `--exclude-prefix=PATH` options to check a path with the same
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
`sudo tmpcleaner --print-in-use0 | xargs -0 -r stat --`.
It reports process-held paths, including working directories; configured `x`/`X`
exclusions are not added, and the command's own scratch directory and descendants are omitted.
It validates configuration (including the supported root grammar above) and
`TMPCLEANER_*` values just like `--print-rules`, but never cleans or writes metrics.
Use sufficient privileges to inspect the relevant processes. This is a snapshot
of visible processes and paths, not a promise that they will remain in use.
Scan, filtering or sorting failures exit nonzero with empty stdout.

A failed in-use scan stops every mode before cleaning
(`--print-rules` and `--print-in-use0` print nothing to stdout; `--dry-run` and the real run exit
non-zero and nothing is removed).
