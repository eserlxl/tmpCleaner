#!/bin/sh
# Applies tmpcleaner.conf to a scratch dir instead of /tmp. Birth and ctime
# cannot be backdated, so the test ages by mtime only (age-by "mM").
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d)
conf=$dir.conf
trap 'rm -rf "$dir" "$conf"' EXIT

sed -e "s#/tmp#$dir#" -e 's# 6h$# mM:6h#' "$here/tmpcleaner.conf" > "$conf"

old() { touch -d '7 hours ago' "$@"; }
mkdir -p "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp"
touch "$dir/old.txt" "$dir/new.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" \
      "$dir/.X0-lock" "$dir/systemd-private-abc/tmp/f"
old "$dir/old.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" "$dir/.X0-lock" \
    "$dir/systemd-private-abc/tmp/f"
old "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" "$dir/systemd-private-abc"

systemd-tmpfiles --clean "$conf"

fail=0
gone() { [ ! -e "$dir/$1" ] || { echo "FAIL: $1 should be deleted"; fail=1; }; }
kept() { [ -e "$dir/$1" ] || { echo "FAIL: $1 should be kept"; fail=1; }; }
gone old.txt; gone olddir
kept new.txt; kept .X11-unix/X0; kept .X0-lock; kept systemd-private-abc/tmp/f
[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
