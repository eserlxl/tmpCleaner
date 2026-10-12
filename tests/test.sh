#!/bin/sh
# Runs tmpcleaner with tmpcleaner.conf retargeted from /tmp to a scratch dir
# under /tmp (in-use detection only looks at /tmp paths). Birth and ctime
# cannot be backdated, so the test ages by mtime only (age-by "mM").
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
conf=$dir.conf
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$dir" "$conf"' EXIT

sed -e "s#/tmp#$dir#" -e 's# 6h$# mM:6h#' "$here/tmpcleaner.conf" > "$conf"

old() { touch -d '7 hours ago' "$@"; }
mkdir -p "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" "$dir/workdir"
touch "$dir/old.txt" "$dir/new.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" \
      "$dir/.X0-lock" "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" \
      "$dir/workdir/f"
old "$dir/old.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" "$dir/.X0-lock" \
    "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" "$dir/workdir/f"
old "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" \
    "$dir/systemd-private-abc" "$dir/workdir"

# Open files with hostile names must protect only themselves: "*" must not
# exclude old.txt, and "we[i]rd?" must not exclude weirdX.
nl='
'
star="$dir/*" glob="$dir/we[i]rd?" bs="$dir/back\\slash*" newline="$dir/new${nl}line"
touch "$star" "$glob" "$bs" "$newline" "$dir/weirdX"
old "$star" "$glob" "$bs" "$newline" "$dir/weirdX"

# Long-running jobs: one holds files open, one works inside a directory.
sleep 60 < "$dir/open a%b.txt" 3<"$star" 4<"$glob" 5<"$bs" 6<"$newline" & pids="$pids $!"
(cd "$dir/workdir" && exec sleep 60) & pids="$pids $!"
until [ -n "$(find /proc/[0-9]*/cwd -maxdepth 0 -lname "$dir/workdir" 2>/dev/null)" ]; do
	sleep 0.1
done

TMPCLEANER_CONF=$conf sh "$here/tmpcleaner"

fail=0
gone() { [ ! -e "$dir/$1" ] || { echo "FAIL: $1 should be deleted"; fail=1; }; }
kept() { [ -e "$dir/$1" ] || { echo "FAIL: $1 should be kept"; fail=1; }; }
gone old.txt; gone olddir; gone weirdX
kept "*"; kept "we[i]rd?"; kept "back\\slash*"; kept "new${nl}line"
kept new.txt; kept .X11-unix/X0; kept .X0-lock; kept systemd-private-abc/tmp/f
kept "open a%b.txt"; kept workdir/f
[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
