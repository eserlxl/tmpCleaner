#!/bin/sh
# Runs tmpcleaner with tmpcleaner.conf retargeted from /tmp to a scratch dir
# under /tmp (in-use detection only looks at /tmp paths). Birth and ctime
# cannot be backdated, so the test drops b/B/c/C from the age-by field and
# keeps the rest as configured.
set -eu
unset TMPCLEANER_AGE TMPCLEANER_FULL_PERCENT TMPCLEANER_FULL_AGE
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
      "$dir/workdir/f" "$dir/krb5cc_1000"
old "$dir/old.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" "$dir/.X0-lock" \
    "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" "$dir/workdir/f" "$dir/krb5cc_1000"
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
carriage="$dir/c${cr}d" tabbed="$dir/t${tab}b" quote="$dir/q\"uote"
touch "$star" "$glob" "$bs" "$newline" "$carriage" "$tabbed" "$quote" "$dir/weirdX"
old "$star" "$glob" "$bs" "$newline" "$carriage" "$tabbed" "$quote" "$dir/weirdX"

# Long-running jobs: one holds files open, one works inside a directory,
# one is an executable started from the directory, one memory-maps a file.
cp /usr/bin/sleep "$dir"
"$dir/sleep" 60 & pids="$pids $!"
# shellcheck disable=SC2217 # sleep only holds these files open for the in-use scan
sleep 60 < "$dir/open a%b.txt" 3<"$star" 4<"$glob" 5<"$bs" 6<"$newline" 7<"$carriage" 8<"$tabbed" 9<"$quote" & pids="$pids $!"
(cd "$dir/workdir" && exec sleep 60) & pids="$pids $!"
libm=$(ldconfig -p | awk '/libm\.so\.6/ { print $NF; exit }')
cp "$libm" "$dir"
LD_PRELOAD="$dir/libm.so.6" sleep 60 & pids="$pids $!"
waited=0
until [ -n "$(find /proc/[0-9]*/cwd -maxdepth 0 -lname "$dir/workdir" 2>/dev/null)" ] && \
      [ -n "$(find /proc/[0-9]*/fd -maxdepth 1 -lname "$dir/open a%b.txt" 2>/dev/null)" ] && \
      [ -n "$(find /proc/[0-9]*/exe -maxdepth 0 -lname "$dir/sleep" 2>/dev/null)" ] && \
      [ -n "$(find /proc/[0-9]*/map_files -maxdepth 1 -lname "$dir/libm.so.6" 2>/dev/null)" ]; do
	if [ "$waited" -ge 100 ]; then
		echo "FAIL: timed out waiting for background jobs"
		exit 1
	fi
	waited=$((waited + 1))
	sleep 0.1
done
old "$dir/sleep"
old "$dir/libm.so.6"

# A process confined to a root under /tmp protects files outside its cwd.
rootfs_running=0
if unshare -r true 2>/dev/null; then
	mkdir -p "$dir/rootfs/bin" "$dir/rootfs/data"
	cp /usr/bin/sleep /usr/bin/env "$dir/rootfs/bin"
	ldd /usr/bin/sleep /usr/bin/env |
		awk '$2 == "=>" && $3 ~ /^\// { print $3 } $1 ~ /^\// && $1 !~ /:$/ { print $1 }' |
		sort -u | while IFS= read -r lib; do
			mkdir -p "$dir/rootfs$(dirname "$lib")"
			cp "$lib" "$dir/rootfs$lib"
		done
	touch "$dir/rootfs/data/state"
	old "$dir/rootfs/data/state"
	unshare -r chroot "$dir/rootfs" /bin/env -C /bin /bin/sleep 60 &
	rootfs_pid=$!
	pids="$pids $rootfs_pid"
	waited=0
	until [ "$(readlink "/proc/$rootfs_pid/root" 2>/dev/null)" = "$dir/rootfs" ] && \
	      [ "$(readlink "/proc/$rootfs_pid/cwd" 2>/dev/null)" = "$dir/rootfs/bin" ]; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for chrooted process"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
	rootfs_running=1
else
	echo "SKIP: rootfs protection (unshare -r is not permitted or unavailable)"
fi

fail=0
age_rules=$(TMPCLEANER_AGE=8h TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
printf '%s\n' "$age_rules" | grep -Eq "^d $dir - - - amM:8h$" || {
	echo "FAIL: age override should preserve age-by letters and set 8h"
	fail=1
}
# Tabs and trailing whitespace must not leave the old age behind as an extra field.
printf 'd\t%s\t-\t-\t-\tamM:6h \n' "$dir" > "$dir.ws.conf"
ws_rules=$(TMPCLEANER_AGE=8h TMPCLEANER_CONF=$dir.ws.conf sh "$here/tmpcleaner" --print-rules)
[ "$(printf '%s\n' "$ws_rules" | grep -c '^d')" = 1 ] &&
	printf '%s\n' "$ws_rules" | grep -q ' amM:8h$' || {
	echo "FAIL: age override should rewrite tab-separated rules with trailing space"
	fail=1
}
rm -f "$dir.ws.conf"
if TMPCLEANER_AGE='1h; x' TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid age override should fail"
	fail=1
fi
rules=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
pressure_rules=$(TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
printf '%s\n' "$pressure_rules" | grep -Eq "^d $dir - - - amM:30m$" || {
	echo "FAIL: pressure mode should preserve age-by letters and set 30m"
	fail=1
}
if TMPCLEANER_FULL_PERCENT=101 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid pressure threshold should fail"
	fail=1
fi
if TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_FULL_AGE='1h; x' TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid pressure age should fail"
	fail=1
fi
configured_age=$(printf '%s\n' "$rules" | grep '^d ')
percent_only=$(TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
age_only=$(TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
for partial_rules in "$percent_only" "$age_only"; do
	[ "$(printf '%s\n' "$partial_rules" | grep '^d ')" = "$configured_age" ] || {
		echo "FAIL: pressure mode needs both variables to change the age"
		fail=1
	}
done
printf '%s\n' "$rules" | grep -Fxq "x \"$dir/open a%%b.txt\"" || {
	echo "FAIL: printed rules should exclude the held file"
	fail=1
}
[ -e "$dir/old.txt" ] || {
	echo "FAIL: printing rules should keep old.txt"
	fail=1
}
[ "$fail" = 0 ] || exit 1

preview=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --dry-run 2>&1)
echo "$preview" | grep -q 'Would remove.*old\.txt' || {
	echo "FAIL: preview should announce removal of old.txt"
	fail=1
}
[ -e "$dir/old.txt" ] || {
	echo "FAIL: old.txt should still exist"
	fail=1
}
[ "$fail" = 0 ] || exit 1

TMPCLEANER_CONF=$conf sh "$here/tmpcleaner"

fail=0
if TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner"; then
	echo "FAIL: missing config should fail"
	fail=1
fi
help_out=$(TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner" --help) || {
	echo "FAIL: --help should exit 0 without config"
	fail=1
}
if ! TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner" -h >/dev/null; then
	echo "FAIL: -h should exit 0 without config"
	fail=1
fi
printf '%s\n' "$help_out" | grep -Fq -- '--print-rules' || {
	echo "FAIL: help should mention --print-rules"
	fail=1
}
printf '%s\n' "$help_out" | grep -Fq 'TMPCLEANER_AGE' || {
	echo "FAIL: help should mention TMPCLEANER_AGE"
	fail=1
}
gone() { [ ! -e "$dir/$1" ] || { echo "FAIL: $1 should be deleted"; fail=1; }; }
kept() { [ -e "$dir/$1" ] || { echo "FAIL: $1 should be kept"; fail=1; }; }
gone old.txt; gone olddir; gone weirdX; gone emptydir
kept freshdir
kept "*"; kept "we[i]rd?"; kept "back\\slash*"; kept "new${nl}line"
kept "c${cr}d"; kept "t${tab}b"; kept "q\"uote"
kept new.txt; kept krb5cc_1000; kept .X11-unix/X0; kept .X0-lock; kept systemd-private-abc/tmp/f
kept "open a%b.txt"; kept workdir/f; kept sleep; kept libm.so.6
if [ "$rootfs_running" = 1 ]; then
	kept rootfs/data/state
fi

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
