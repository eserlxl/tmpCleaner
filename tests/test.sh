#!/bin/sh
# Runs tmpcleaner with tmpcleaner.conf retargeted from /tmp to a scratch dir
# under /tmp (in-use detection only looks at /tmp paths). Birth and ctime
# cannot be backdated, so the test drops b/B/c/C from the age-by field and
# keeps the rest as configured.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
conf=$dir.conf
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$dir" "$conf"' EXIT

awk '$1 == "d" { gsub(/[bcBC]/, "", $6) } { print }' "$here/tmpcleaner.conf" |
	sed "s#/tmp#$dir#" > "$conf"
printf '%s' "$(cat "$conf")" > "$conf"

old() { touch -d '7 hours ago' "$@"; }
mkdir -p "$dir/emptydir" "$dir/freshdir" "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" "$dir/workdir"
touch "$dir/old.txt" "$dir/new.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" \
      "$dir/.X0-lock" "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" \
      "$dir/workdir/f"
old "$dir/old.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" "$dir/.X0-lock" \
    "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" "$dir/workdir/f"
old "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" \
    "$dir/systemd-private-abc" "$dir/workdir"

# An old empty dir that was just listed goes; a just-created empty one stays.
touch -m -d '7 hours ago' "$dir/emptydir"
touch -a "$dir/emptydir"

# Open files with hostile names must protect only themselves: "*" must not
# exclude old.txt, and "we[i]rd?" must not exclude weirdX.
nl='
'
cr=$(printf '\r') tab=$(printf '\t')
star="$dir/*" glob="$dir/we[i]rd?" bs="$dir/back\\slash*" newline="$dir/new${nl}line"
carriage="$dir/c${cr}d" tabbed="$dir/t${tab}b"
touch "$star" "$glob" "$bs" "$newline" "$carriage" "$tabbed" "$dir/weirdX"
old "$star" "$glob" "$bs" "$newline" "$carriage" "$tabbed" "$dir/weirdX"

# Long-running jobs: one holds files open, one works inside a directory,
# one is an executable started from the directory.
cp /usr/bin/sleep "$dir"
"$dir/sleep" 60 & pids="$pids $!"
sleep 60 < "$dir/open a%b.txt" 3<"$star" 4<"$glob" 5<"$bs" 6<"$newline" 7<"$carriage" 8<"$tabbed" & pids="$pids $!"
(cd "$dir/workdir" && exec sleep 60) & pids="$pids $!"
waited=0
until [ -n "$(find /proc/[0-9]*/cwd -maxdepth 0 -lname "$dir/workdir" 2>/dev/null)" ] && \
      [ -n "$(find /proc/[0-9]*/fd -maxdepth 1 -lname "$dir/open a%b.txt" 2>/dev/null)" ] && \
      [ -n "$(find /proc/[0-9]*/exe -maxdepth 0 -lname "$dir/sleep" 2>/dev/null)" ]; do
	if [ "$waited" -ge 100 ]; then
		echo "FAIL: timed out waiting for background jobs"
		exit 1
	fi
	waited=$((waited + 1))
	sleep 0.1
done
old "$dir/sleep"

TMPCLEANER_CONF=$conf sh "$here/tmpcleaner"

fail=0
if TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner"; then
	echo "FAIL: missing config should fail"
	fail=1
fi
gone() { [ ! -e "$dir/$1" ] || { echo "FAIL: $1 should be deleted"; fail=1; }; }
kept() { [ -e "$dir/$1" ] || { echo "FAIL: $1 should be kept"; fail=1; }; }
gone old.txt; gone olddir; gone weirdX; gone emptydir
kept freshdir
kept "*"; kept "we[i]rd?"; kept "back\\slash*"; kept "new${nl}line"
kept "c${cr}d"; kept "t${tab}b"
kept new.txt; kept .X11-unix/X0; kept .X0-lock; kept systemd-private-abc/tmp/f
kept "open a%b.txt"; kept workdir/f; kept sleep

# A second run tests that the shipped age rule keeps freshly extracted files
# (birth and ctime stay current even when atime and mtime are backdated).
dir2=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
conf2=$dir2.conf
trap 'kill $pids 2>/dev/null; rm -rf "$dir" "$conf" "$dir2" "$conf2"' EXIT

sed "s#/tmp#$dir2#" "$here/tmpcleaner.conf" > "$conf2"
touch "$dir2/extracted.txt"
touch -d '7 hours ago' "$dir2/extracted.txt"

TMPCLEANER_CONF=$conf2 sh "$here/tmpcleaner"

[ -e "$dir2/extracted.txt" ] || { echo "FAIL: extracted.txt should be kept"; fail=1; }

[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
