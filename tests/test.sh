#!/bin/sh
# Runs tmpcleaner with tmpcleaner.conf retargeted from /tmp to a scratch dir
# under /tmp (in-use detection only looks at /tmp paths). Birth and ctime
# cannot be backdated, so the test drops b/B/c/C from the age-by field and
# keeps the rest as configured.
set -eu
unset TMPCLEANER_AGE TMPCLEANER_FULL_PERCENT TMPCLEANER_FULL_AGE TMPCLEANER_LIST
here=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
# Fixture configs live in a private directory, never at a guessable /tmp path.
cfg=$(mktemp -d)
conf=$cfg/conf
pids=
bindpoint=
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$bindpoint"' EXIT

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
# An old directory still holding a fresh file: announced by the preview, but kept.
mkdir "$dir/mixed"
touch "$dir/mixed/fresh"
touch -m -d '7 hours ago' "$dir/mixed"
touch -a "$dir/emptydir"

# Open files with hostile names must protect only themselves: "*" must not
# exclude old.txt, and "we[i]rd?" must not exclude weirdX.
nl='
'
cr=$(printf '\r') tab=$(printf '\t')
star="$dir/*" glob="$dir/we[i]rd?" bs="$dir/back\\slash*" newline="$dir/new${nl}line"
carriage="$dir/c${cr}d" tabbed="$dir/t${tab}b" quote="$dir/q\"uote"
forged="$dir/old${nl}<0>forged"
# Directory names that make the preview print a fake line for "$dir/ghost",
# a path that never exists (a name cannot hold "/", so the chain spells it).
ghostly="$dir/q\"${nl}Would remove \"$dir/ghost"
mkdir -p "${ghostly%/*}"
touch "$star" "$glob" "$bs" "$newline" "$carriage" "$tabbed" "$quote" "$dir/weirdX" "$forged" "$ghostly"
old "$star" "$glob" "$bs" "$newline" "$carriage" "$tabbed" "$quote" "$dir/weirdX" "$forged" "$ghostly"

# Long-running jobs: one holds files open, one works inside a directory,
# one is an executable started from the directory, one memory-maps a file.
cp /usr/bin/sleep "$dir"
"$dir/sleep" 60 & pids="$pids $!"
# A name holding an invalid UTF-8 byte and a space, held open: under a UTF-8
# locale the escaping must still quote all of it (the run below uses one).
utf8="$dir/u$(printf '\377') x"
touch "$utf8"
old "$utf8"
# shellcheck disable=SC2217 # sleep only holds these files open for the in-use scan
sleep 60 < "$utf8" & pids="$pids $!"
# shellcheck disable=SC2217 # sleep only holds these files open for the in-use scan
sleep 60 < "$dir/open a%b.txt" 3<"$star" 4<"$glob" 5<"$bs" 6<"$newline" 7<"$carriage" 8<"$tabbed" 9<"$quote" & pids="$pids $!"
(cd "$dir/workdir" && exec sleep 60) & pids="$pids $!"
libm=$(ldconfig -p | awk '/libm\.so\.6/ { print $NF; exit }')
cp "$libm" "$dir"
LD_PRELOAD="$dir/libm.so.6" sleep 60 & pids="$pids $!"
waited=0
until [ -n "$(find /proc/[0-9]*/cwd -maxdepth 0 -lname "$dir/workdir" 2>/dev/null)" ] && \
      [ -n "$(find /proc/[0-9]*/fd -maxdepth 1 -lname "$dir/open a%b.txt" 2>/dev/null)" ] && \
      [ -n "$(find /proc/[0-9]*/fd -maxdepth 1 -lname "$utf8" 2>/dev/null)" ] && \
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
if unshare -rm true 2>/dev/null; then
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
	unshare -rm chroot "$dir/rootfs" /bin/env -C /bin /bin/sleep 60 &
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

# The same files reached through a bind mount outside /tmp stay protected.
bind_running=0
if unshare -rm true 2>/dev/null; then
	bindpoint=$(mktemp -d '/var/tmp/tmpcleaner-test\040.XXXXXX')
	mkdir -p "$dir/work/cwd"
	# Copy from the originals: reading $dir/sleep or $dir/libm.so.6 would renew
	# their access time and hide whether the direct cases are really protected.
	cp /usr/bin/sleep "$libm" "$dir/work"
	touch "$dir/work/f" "$dir/work/unused" "$dir/work/cwd/f"
	# shellcheck disable=SC2016 # $1 and $2 are expanded by the inner sh
	unshare -rm sh -ec '
		mount --bind "$1/work" "$2"
		cd "$2/cwd"
		LD_PRELOAD="$2/libm.so.6" exec "$2/sleep" 60 < "$2/f"
	' sh "$dir" "$bindpoint" &
	bind_pid=$!
	pids="$pids $bind_pid"
	waited=0
	until [ "$(readlink "/proc/$bind_pid/fd/0" 2>/dev/null)" = "$bindpoint/f" ] && \
	      [ "$(readlink "/proc/$bind_pid/cwd" 2>/dev/null)" = "$bindpoint/cwd" ] && \
	      [ "$(readlink "/proc/$bind_pid/exe" 2>/dev/null)" = "$bindpoint/sleep" ] && \
	      readlink /proc/"$bind_pid"/map_files/* 2>/dev/null | grep -Fxq "$bindpoint/libm.so.6"; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for bind-mounted process"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
	old "$dir/work/f" "$dir/work/unused" "$dir/work/cwd/f" \
	    "$dir/work/sleep" "$dir/work/libm.so.6" "$dir/work/cwd" "$dir/work"
	bind_running=1
else
	echo "SKIP: bind-mount protection (unshare -rm is not permitted or unavailable)"
fi

# A process chrooted onto a bind mount of a /tmp tree, alone in its namespace,
# lists only that mount, relative to its root.
jail_running=0
if [ "$rootfs_running" = 1 ] && [ "$bind_running" = 1 ]; then
	cp -a "$dir/rootfs" "$dir/jail"
	old "$dir/jail/data/state"
	mkdir "$bindpoint/jail"
	# shellcheck disable=SC2016 # $1 and $2 are expanded by the inner sh
	unshare -rm sh -ec '
		mount --bind "$1/jail" "$2"
		exec chroot "$2" /bin/env -C /bin /bin/sleep 60
	' sh "$dir" "$bindpoint/jail" &
	jail_pid=$!
	pids="$pids $jail_pid"
	waited=0
	until [ "$(readlink "/proc/$jail_pid/root" 2>/dev/null)" = "$bindpoint/jail" ]; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for the bind-mounted chroot"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
	jail_running=1
fi

fail=0
# Without /proc nothing in use could be protected, so the run must refuse.
if [ "$bind_running" = 1 ] &&
	unshare -rm sh -c 'mount -t tmpfs tmpfs /proc && TMPCLEANER_CONF=$1 sh "$2" --print-rules' sh "$conf" "$here/tmpcleaner" >/dev/null 2>&1; then
	echo "FAIL: a run without /proc should fail"
	fail=1
fi
# With TMPDIR elsewhere (as the service sets it) a full /tmp still gets cleaned.
if [ "$bind_running" = 1 ]; then
	status=0
	# shellcheck disable=SC2016 # $1 is expanded by the inner sh
	TMPDIR=$bindpoint unshare -rm sh -c '
		mount -t tmpfs -o size=64k,nr_inodes=16 tmpfs /tmp
		touch /tmp/stale
		touch -d "7 hours ago" /tmp/stale
		i=0
		while touch "/tmp/f$i" 2>/dev/null; do i=$((i + 1)); done
		printf "d /tmp - - - amM:6h\n" > "$TMPDIR/full.conf"
		TMPCLEANER_CONF=$TMPDIR/full.conf sh "$1" 2>/dev/null && [ ! -e /tmp/stale ]
	' sh "$here/tmpcleaner" || status=$?
	if [ "$status" -ne 0 ]; then
		echo "FAIL: a full /tmp should still be cleaned when TMPDIR lies elsewhere"
		fail=1
	fi
fi
age_rules=$(TMPCLEANER_AGE=8h TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
printf '%s\n' "$age_rules" | grep -Eq "^d $dir - - - amM:8h$" || {
	echo "FAIL: age override should preserve age-by letters and set 8h"
	fail=1
}
# Tabs and trailing whitespace must not leave the old age behind as an extra field.
# The override sets the age field itself: a short rule gains it, and a
# trailing argument field is left alone.
for rule in "d $dir|d $dir - - - 8h" "d $dir - - - amM:6h -|d $dir - - - amM:8h -" \
	"d $dir - - - ~amM:6h|d $dir - - - ~amM:8h"; do
	printf '%s\n' "${rule%%|*}" > "$cfg/short.conf"
	got=$(TMPCLEANER_AGE=8h TMPCLEANER_CONF=$cfg/short.conf sh "$here/tmpcleaner" --print-rules | grep '^d ')
	[ "$got" = "${rule#*|}" ] || {
		echo "FAIL: age override should set field 6 of: ${rule%%|*}"
		fail=1
	}
done
printf 'd\t%s\t-\t-\t-\tamM:6h \n' "$dir" > "$cfg/ws.conf"
ws_rules=$(TMPCLEANER_AGE=8h TMPCLEANER_CONF=$cfg/ws.conf sh "$here/tmpcleaner" --print-rules)
if ! { [ "$(printf '%s\n' "$ws_rules" | grep -c '^d')" = 1 ] &&
	printf '%s\n' "$ws_rules" | grep -q ' amM:8h$'; }; then
	echo "FAIL: age override should rewrite tab-separated rules with trailing space"
	fail=1
fi
rm -f "$cfg/ws.conf"
if TMPCLEANER_AGE='1h; x' TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid age override should fail"
	fail=1
fi
rules=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
for list in 0 2 yes "1${nl}"; do
	status=0
	TMPCLEANER_LIST="$list" TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 1 ]; then
		echo "FAIL: invalid TMPCLEANER_LIST should exit 1"
		fail=1
	fi
done
empty_list_rules=$(TMPCLEANER_LIST='' TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
# Generated exclusions follow whatever other processes on the host hold open,
# so compare only the configured rules.
[ "$(printf '%s\n' "$empty_list_rules" | grep -v '^x "')" = "$(printf '%s\n' "$rules" | grep -v '^x "')" ] || {
	echo "FAIL: empty TMPCLEANER_LIST should leave rules unchanged"
	fail=1
}
if printf '%s\n' "$rules" | grep -Eq '^x "/tmp/*"$'; then
	echo "FAIL: generated rules must not exclude /tmp itself"
	fail=1
fi
pressure_rules=$(TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
printf '%s\n' "$pressure_rules" | grep -Eq "^d $dir - - - amM:30m$" || {
	echo "FAIL: pressure mode should preserve age-by letters and set 30m"
	fail=1
}
if TMPCLEANER_AGE=bogus TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid TMPCLEANER_AGE should fail under pressure too"
	fail=1
fi
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

# Through a symlinked parent directory --check must still find the real path.
ln -s "$dir" "$dir/selflink"
status=0
check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/selflink/old.txt") || status=$?
if [ "$status" -ne 0 ]; then
	echo "FAIL: --check should resolve a symlinked parent directory"
	fail=1
fi
for name in old.txt 'open a%b.txt' new.txt; do
	status=0
	check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/$name") || status=$?
	if [ "$name" = old.txt ]; then
		expected="would be removed: $dir/$name"
		expected_status=0
	else
		expected="kept: $dir/$name"
		expected_status=1
	fi
	if [ "$status" -ne "$expected_status" ] || [ "$check_out" != "$expected" ] || [ ! -e "$dir/$name" ]; then
		echo "FAIL: --check should report $name without deleting it"
		fail=1
	fi
done
status=0
check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/mixed") || status=$?
if [ "$status" -ne 1 ] || [ "$check_out" != "kept: $dir/mixed" ]; then
	echo "FAIL: --check should keep an old directory that still holds a fresh file"
	fail=1
fi
status=0
TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 2 ]; then
	echo "FAIL: --check should refuse a directory holding names with newlines"
	fail=1
fi
for path in '' old.txt / /tmp "$dir/missing" "$dir/../.." "$newline"; do
	status=0
	check_out=$(TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner" --check "$path" 2>&1) || status=$?
	if [ "$status" -ne 2 ] || [ -z "$check_out" ]; then
		echo "FAIL: --check should reject invalid path: $path before checking config"
		fail=1
	fi
done
status=0
check_out=$(TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner" --check 2>&1) || status=$?
if [ "$status" -ne 2 ] || [ -z "$check_out" ]; then
	echo "FAIL: --check should reject a missing path before checking config"
	fail=1
fi
[ "$fail" = 0 ] || exit 1

run_log=$(env -u LC_ALL LANG=C.UTF-8 TMPCLEANER_LIST=1 TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" 2>&1 >/dev/null)

fail=0
if ! { [ "$(printf '%s\n' "$run_log" | grep -c '^tmpcleaner: removed [0-9]')" = 1 ] &&
	printf '%s\n' "$run_log" | grep -Fxq "tmpcleaner: removed $((5 + bind_running)) files and 2 directories"; }; then
	echo "FAIL: real run should log one summary with the expected removal counts"
	fail=1
fi
if ! { [ "$(printf '%s\n' "$run_log" | grep -Fxc "tmpcleaner: removed: $dir/old.txt")" = 1 ] &&
	[ "$(printf '%s\n' "$run_log" | grep -Fxc "tmpcleaner: removed: $dir/old\x0a<0>forged")" = 1 ] &&
	[ "$(printf '%s\n' "$run_log" | grep -c '^tmpcleaner: removed: ')" = "$((5 + bind_running))" ] &&
	[ "$(printf '%s\n' "$run_log" | grep -c '^tmpcleaner: removed directory: ')" = 2 ]; }; then
	echo "FAIL: listing should log every removed path once with newlines escaped"
	fail=1
fi
if printf '%s\n' "$run_log" | grep -Fxq "tmpcleaner: removed: $dir/open a%b.txt" ||
	printf '%s\n' "$run_log" | grep -Fxq "tmpcleaner: removed directory: $dir/workdir"; then
	echo "FAIL: listing should not log held files or kept directories as removed"
	fail=1
fi
if printf '%s\n' "$run_log" | grep -Fq "removed: $dir/ghost"; then
	echo "FAIL: a crafted name must not list a path that never existed"
	fail=1
fi
if printf '%s\n' "$run_log" | grep -q '^<'; then
	echo "FAIL: a filename must not forge a journal line"
	fail=1
fi
if printf '%s\n' "$run_log" | grep -q 'Removing'; then
	echo "FAIL: removal debug lines should not leak into the log"
	fail=1
fi
printf 'd relative-path - - - 1h\n' > "$cfg/bad.conf"
if TMPCLEANER_CONF=$cfg/bad.conf sh "$here/tmpcleaner" 2>/dev/null; then
	echo "FAIL: a systemd-tmpfiles error should make tmpcleaner fail"
	fail=1
fi
rm -f "$cfg/bad.conf"
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
printf '%s\n' "$help_out" | grep -Fq -- '--check PATH' || {
	echo "FAIL: help should mention --check PATH"
	fail=1
}
printf '%s\n' "$help_out" | grep -Fq 'TMPCLEANER_AGE' || {
	echo "FAIL: help should mention TMPCLEANER_AGE"
	fail=1
}
printf '%s\n' "$help_out" | grep -Fq 'TMPCLEANER_LIST' || {
	echo "FAIL: help should mention TMPCLEANER_LIST"
	fail=1
}
gone() { [ ! -e "$dir/$1" ] || { echo "FAIL: $1 should be deleted"; fail=1; }; }
kept() { [ -e "$dir/$1" ] || { echo "FAIL: $1 should be kept"; fail=1; }; }
gone old.txt; gone olddir; gone weirdX; gone emptydir
kept mixed/fresh
gone "old${nl}<0>forged"
kept freshdir
kept "*"; kept "we[i]rd?"; kept "back\\slash*"; kept "new${nl}line"
kept "c${cr}d"; kept "t${tab}b"; kept "q\"uote"
kept new.txt; kept krb5cc_1000; kept .X11-unix/X0; kept .X0-lock; kept systemd-private-abc/tmp/f
kept "open a%b.txt"; kept workdir/f; kept sleep; kept libm.so.6; kept "${utf8#"$dir"/}"
if [ "$jail_running" = 1 ]; then
	kept jail/data/state
fi
if [ "$rootfs_running" = 1 ]; then
	kept rootfs/data/state
fi
if [ "$bind_running" = 1 ]; then
	kept work; kept work/f; kept work/cwd/f; kept work/sleep; kept work/libm.so.6
	gone work/unused
	# Aliases at /tmp paths and nested binds must protect only the backing file.
	for mode in direct nested; do
		mkdir -p "$dir/held" "$dir/big"
		touch "$dir/held/f" "$dir/big/f"
		old "$dir/held/f" "$dir/big/f" "$dir/held" "$dir/big"
		# shellcheck disable=SC2016 # arguments are expanded by the inner sh
		unshare -rm sh -ec '
			if [ "$3" = direct ]; then
				mount --bind "$1/held" "$1/big"
				exec sleep 60 < "$1/big/f"
			else
				mount --bind "$1" "$2"
				mount --bind "$1/held" "$2/big"
				exec sleep 60 < "$2/big/f"
			fi
		' sh "$dir" "$bindpoint" "$mode" &
		alias_pid=$!
		pids="$pids $alias_pid"
		if [ "$mode" = direct ]; then
			alias_path=$dir/big/f
		else
			alias_path=$bindpoint/big/f
		fi
		waited=0
		until [ "$(readlink "/proc/$alias_pid/fd/0" 2>/dev/null)" = "$alias_path" ]; do
			if [ "$waited" -ge 100 ]; then
				echo "FAIL: timed out waiting for $mode bind-mounted process"
				exit 1
			fi
			waited=$((waited + 1))
			sleep 0.1
		done
		TMPCLEANER_CONF=$conf sh "$here/tmpcleaner"
		gone big/f; kept held/f
		kill "$alias_pid"
		wait "$alias_pid" 2>/dev/null || :
	done
fi

# The run keeps its own scratch files even when they sit in the cleaned tree.
dir3=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
printf 'd %s - - - amM:0\n' "$dir3" > "$cfg/conf3"
touch "$dir3/f"
status=0
scratch_log=$(TMPDIR=$dir3 TMPCLEANER_AGE=0 TMPCLEANER_CONF=$cfg/conf3 sh "$here/tmpcleaner" 2>&1) || status=$?
if [ "$status" -ne 0 ] || ! printf '%s\n' "$scratch_log" | grep -Fxq 'tmpcleaner: removed 1 files and 0 directories'; then
	echo "FAIL: the run must not remove its own scratch files"
	fail=1
fi
rm -rf "$dir3" "$cfg/conf3"

# A second run tests that the shipped age rule keeps freshly extracted files
# (birth and ctime stay current even when atime and mtime are backdated).
dir2=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
conf2=$cfg/conf2
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$bindpoint"' EXIT

sed "s#/tmp#$dir2#" "$here/tmpcleaner.conf" > "$conf2"
touch "$dir2/extracted.txt"
touch -d '7 hours ago' "$dir2/extracted.txt"

run_log=$(TMPCLEANER_CONF=$conf2 sh "$here/tmpcleaner" 2>&1 >/dev/null)
[ "$run_log" = 'tmpcleaner: removed 0 files and 0 directories' ] || {
	echo "FAIL: an unset TMPCLEANER_LIST should log only the usual summary"
	fail=1
}

[ -e "$dir2/extracted.txt" ] || { echo "FAIL: extracted.txt should be kept"; fail=1; }

# The three-way config upgrade that decides whether a reinstall keeps or replaces
# an admin's exclusions.
confdir=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$confdir" "$bindpoint"' EXIT

make -s -C "$here" install-conf CONFDIR="$confdir" >/dev/null
cmp -s "$confdir/tmpcleaner.conf" "$here/tmpcleaner.conf" || {
	echo "FAIL: initial install should create tmpcleaner.conf matching shipped file"
	fail=1
}
cmp -s "$confdir/tmpcleaner.conf.default" "$here/tmpcleaner.conf" || {
	echo "FAIL: initial install should create tmpcleaner.conf.default matching shipped file"
	fail=1
}

sed '$d' "$here/tmpcleaner.conf" > "$confdir/tmpcleaner.conf"
cp "$confdir/tmpcleaner.conf" "$confdir/tmpcleaner.conf.default"
make -s -C "$here" install-conf CONFDIR="$confdir" >/dev/null
cmp -s "$confdir/tmpcleaner.conf" "$here/tmpcleaner.conf" || {
	echo "FAIL: unedited upgrade should update tmpcleaner.conf to shipped file"
	fail=1
}
[ ! -e "$confdir/tmpcleaner.conf.new" ] || {
	echo "FAIL: unedited upgrade should not create tmpcleaner.conf.new"
	fail=1
}

printf 'x /tmp/local-rule\n' >> "$confdir/tmpcleaner.conf"
make -s -C "$here" install-conf CONFDIR="$confdir" >/dev/null
grep -Fxq 'x /tmp/local-rule' "$confdir/tmpcleaner.conf" || {
	echo "FAIL: local rule should survive reinstall"
	fail=1
}
cmp -s "$confdir/tmpcleaner.conf.new" "$here/tmpcleaner.conf" || {
	echo "FAIL: edited reinstall should create tmpcleaner.conf.new matching shipped file"
	fail=1
}
rm -rf "$confdir"

[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
