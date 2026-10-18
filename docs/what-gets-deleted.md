# What gets deleted

Will my file be deleted? The age rule, everyday examples, what is never deleted,
and how to protect or check a path before a run.

## The rule

Every run applies one cleaning rule from `tmpcleaner.conf`:

```text
d /tmp - - - abcmBM:12h
```

The letters before `:12h` name the timestamps that must be old: lowercase ones
apply to files, uppercase ones to directories (`man tmpfiles.d`, "Age").

| Entry | Timestamps that must **all** be older than 12 hours | Also required |
|-------|------------------------------------------------------|---------------|
| File | access (`a`), birth (`b`), status change (`c`), modification (`m`) | Not [protected](#never-deleted) |
| Directory | birth (`B`), modification (`M`) | Empty once its old contents are gone; not protected |

A file that was recently written or extracted survives, because its birth and
status-change times are new even when the archive kept old modification times.
Reading alone is a weak signal: with the usual `relatime` mount option the
access time moves at most once a day.

A directory's access time is ignored, because merely listing a directory
(`ls`, a `--dry-run` preview) renews it. A directory created less than 12 hours
ago stays even when empty.

12 hours is the shipped age. `TMPCLEANER_AGE` and the opt-in pressure mode
change it; see [configuration.md](configuration.md).

## Examples

| Case | Verdict | Why |
|------|---------|-----|
| A file downloaded 2 hours ago | Kept | Its birth and modification times are 2 hours old |
| A file extracted 1 hour ago from an archive that stores 3-day-old times | Kept | Its birth and status-change times are 1 hour old |
| A file nobody touched for 3 days | Removed | All four timestamps are 3 days old |
| A 3-day-old file read for the first time 2 hours ago | Kept, for now | Under `relatime` the first read in over a day moves the access time; it goes once that read is 12 hours old |
| A 3-day-old file read every hour | Removed within a day | Under `relatime` the access time moves at most once a day, so it is older than 12 hours for part of each day |
| An empty directory created 1 hour ago | Kept | Its birth time is 1 hour old |
| An empty directory created 2 days ago and not changed since | Removed | Its birth and modification times are 2 days old |
| A 2-day-old directory whose last file was deleted 1 hour ago | Kept | Deleting an entry renews the directory's modification time |
| A 3-day-old file a running process holds open | Kept | It is in use |
| A 3-day-old file in `/tmp/build` while a running shell works there | Kept | Everything under a process's current directory is in use (a process working in `/tmp` itself does not count) |
| A 3-day-old socket a running server listens on | Kept | It is listed in `/proc/net/unix` |
| `/tmp/.X11-unix/X0` | Kept | Excluded by `tmpcleaner.conf` |

## Never deleted

| Category | Examples | Why it is kept |
|----------|----------|----------------|
| Files in use | Executables of running processes, files a running process holds open, memory-mapped files such as loaded libraries | Each one gets its own exclusion, read from `/proc` just before the run |
| Directories in use | Everything inside a directory a running process works in (its current directory) or uses as its root directory (chrooted or containerized processes), including files and directories reached through bind mounts | Same scan; a process working in `/tmp` itself does not keep all of `/tmp` |
| Unix sockets that are still in use | Sockets listed in `/proc/net/unix` of any network namespace | A server may sit idle on its socket longer than the age limit |
| Marked job directories | `/tmp/<a>` or `/tmp/<a>/<b>` holding a regular `.tmpcleaner-keep` file | Scanned before each run so an unprivileged job can keep its directory until it removes the marker (symlinks are ignored) |
| X11/ICE socket dirs and X lock files | `/tmp/.X11-unix`, `/tmp/.ICE-unix`, `/tmp/.XIM-unix`, `/tmp/.font-unix`, `/tmp/.Test-unix`, `/tmp/.X0-lock`, ... | `x` rules in `tmpcleaner.conf` |
| Private service `/tmp` dirs | systemd `PrivateTmp` dirs (`/tmp/systemd-private-*`), `/tmp/snap-private-tmp` | `x` rules in `tmpcleaner.conf` |
| Kerberos ticket caches | `/tmp/krb5cc_*` | MIT Kerberos keeps them here by default; they can outlive the age limit |
| Package and local `tmpfiles.d` exclusions | Any other `/tmp` exclusion (`x` or `X` rule, except a bare `/tmp`) shipped by installed packages or local overrides in `tmpfiles.d` | Read from `systemd-tmpfiles --cat-config` at every run |
| Your exclusions | `x` lines you add to `/etc/tmpcleaner/tmpcleaner.conf` | See [How to keep something](#how-to-keep-something) |
| Other mounts | Anything on a different mount below `/tmp` | Cleaning stays on the `/tmp` filesystem |

### Limits

- The in-use list is taken from `/proc` just before each run (a snapshot
  before cleaning), so files opened during a run are not covered and
  long-lived work belongs in the exclusion list.
- Socket protection does not recognize a socket bound by a relative name in
  another network namespace, one whose own name forges a line of
  `/proc/net/unix`, and one whose name no process can reach any more (bound,
  then chrooted away, by the last process of a private mount namespace).

## Scope

- Only `/tmp` is touched; `/var/tmp` keeps the distribution's defaults.
- Anything on a different mount below `/tmp` is skipped.
- Symlinks are never followed, so nothing outside `/tmp` is reached through one.
- The distribution's own `systemd-tmpfiles-clean.timer` keeps its own `/tmp`
  rules. `tmpcleaner.conf` is not in a `tmpfiles.d` directory, so its rules
  apply only to tmpCleaner's runs.

## How to keep something

Add an `x` line to `/etc/tmpcleaner/tmpcleaner.conf`. It excludes matching paths
and their contents while a parent cleanup rule walks the tree, whatever their
age, and accepts shell globs:

```text
x /tmp/my-long-job-*
```

A separately configured cleanup root at or below the excluded directory can
still clean its contents. For example, `x /tmp/tree/keep` cannot save
`/tmp/tree/keep/old` if a separate `d /tmp/tree/keep ...` rule cleans it. Remove
the conflicting cleanup rule; see [configuration.md](configuration.md).

The next run reads it; nothing needs reloading. Package upgrades keep an edited
config (pacman writes new defaults to `.pacnew`, `make install` to
`tmpcleaner.conf.new`).

To protect a path from the distribution's own cleaner too, put the same line in
a `tmpfiles.d` file instead, for example `/etc/tmpfiles.d/my-long-job.conf`;
tmpCleaner imports `x` and `X` rules under `/tmp` from there at every run.

For a single manual run, `--exclude-prefix=PATH` keeps PATH and everything
below it ([cli-reference.md](cli-reference.md)).

## How to check before it happens

Preview the next run without deleting anything:

```sh
sudo tmpcleaner --dry-run 2>&1 | less
```

The preview goes to stderr, one line per entry, then a summary:

```text
Would remove "/tmp/old-build.log"
Would remove directory "/tmp/old-build"
tmpcleaner: would remove 1 files and 1 directories
```

Run it as root: without root, directories that only root can open are not
listed. From a source checkout, `sudo make preview` saves the same preview to
`preview.txt`.

Previews print directories as `Would remove directory`; a preview cannot know
that a directory will still hold a kept file, so a real run may remove fewer.

To ask about one path, use `--check`; it prints `would be removed: PATH` or
`kept: PATH` and, when kept, the reason:

```sh
sudo tmpcleaner --check /tmp/my-long-job-1/output.log
```

`sudo tmpcleaner --print-rules` shows every rule and in-use exclusion a run
would apply.
