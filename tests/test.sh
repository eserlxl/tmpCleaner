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
shimdir=$(mktemp -d)
pids=
bindpoint=
detachpoint=
sockalias=
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$shimdir" "$bindpoint" "$detachpoint" "$sockalias"' EXIT

awk '$1 == "d" { gsub(/[bcBC]/, "", $6) } { print }' "$here/tmpcleaner.conf" |
	sed "s#/tmp#$dir#" > "$conf"
printf '%s' "$(cat "$conf")" > "$conf"

# df, stat, find, and systemd-tmpfiles shims: every pressure or scan-failure
# test runs with $shimdir first on PATH. DF_SHIM_OUT holds the data line,
# DF_SHIM_STATUS the exit; STAT_SHIM_FAIL, FIND_SHIM_FAIL, and CAT_SHIM_FAIL
# select which scan step fails; CAT_SHIM_OUT answers --cat-config from a file.
cat > "$shimdir/df" <<'SHIM'
#!/bin/sh
[ "$*" = "--output=pcent,ipcent /tmp" ] || { echo "df shim: unexpected arguments: $*" >&2; exit 64; }
echo 'Use% IUse%'
cat "$DF_SHIM_OUT"
exit "${DF_SHIM_STATUS:-0}"
SHIM
cat > "$shimdir/stat" <<SHIM
#!/bin/sh
case "\${STAT_SHIM_FAIL:-}:\$*" in
	tmp:"-c %d /tmp"|cached:*--cached=always*) exit 1 ;;
esac
exec "$(command -v stat)" "\$@"
SHIM
cat > "$shimdir/find" <<SHIM
#!/bin/sh
case "\${FIND_SHIM_FAIL:-}:\$*" in
	walk:"/tmp -xdev -printf"*) exit 1 ;;
esac
exec "$(command -v find)" "\$@"
SHIM
cat > "$shimdir/systemd-tmpfiles" <<SHIM
#!/bin/sh
if [ "\$*" = --cat-config ]; then
	[ -z "\${CAT_SHIM_FAIL:-}" ] || exit 1
	cat "\$CAT_SHIM_OUT"
	exit 0
fi
exec "$(command -v systemd-tmpfiles)" "\$@"
SHIM
chmod +x "$shimdir/df" "$shimdir/stat" "$shimdir/find" "$shimdir/systemd-tmpfiles"
dfout=$shimdir/out
catout=$shimdir/cat
printf ' 50%%     -\n' > "$dfout"
printf 'X %s/distro-*\nx /tmp\nx /tmp/\nx /var/tmp/other\n' "$dir" > "$catout"
export DF_SHIM_OUT="$dfout" CAT_SHIM_OUT="$catout"
PATH=$shimdir:$PATH
export PATH
shim() { PATH=$shimdir:$PATH "$@"; }
setdf() { printf '%s\n' "$1" > "$dfout"; DF_SHIM_STATUS=${2:-0}; export DF_SHIM_STATUS; }

old() { touch -d '13 hours ago' "$@"; }
mkdir -p "$dir/emptydir" "$dir/freshdir" "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" "$dir/workdir"
touch "$dir/old.txt" "$dir/new.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" \
      "$dir/.X0-lock" "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" \
      "$dir/workdir/f" "$dir/krb5cc_1000" "$dir/distro-auth"
old "$dir/old.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" "$dir/.X0-lock" \
    "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" "$dir/workdir/f" "$dir/krb5cc_1000" "$dir/distro-auth"
old "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" \
    "$dir/systemd-private-abc" "$dir/workdir"

# An old empty dir that was just listed goes; a just-created empty one stays.
touch -m -d '13 hours ago' "$dir/emptydir"
# An old directory still holding a fresh file: announced by the preview, but kept.
mkdir "$dir/mixed"
touch "$dir/mixed/fresh"
touch -m -d '13 hours ago' "$dir/mixed"
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
# Sockets listening in another network namespace, which systemd-tmpfiles
# cannot see, are still reached through their paths: one with a newline in
# its name, one bound through ".." and one through a bind mount outside /tmp
# that only the binding process sees (another process of the namespace runs
# in our mount namespace). A name that forges a record for a regular file
# must not keep that file.
sock_running=0
nlsock="$dir/sock
nl"
forged="$dir/f
0: 2 0 10000 1 1 1 $dir/victim"
# shellcheck disable=SC2016 # expanded by the inner sh
binder='mount --bind "$1/sockdir" "$2"
MOUNTPOINT=$2 MARKER=$6 exec python3 "$3" "$1/sock" "$4" "$5" "$2/s" "/var/..$1/dotsock"'
if command -v python3 >/dev/null && unshare -rmn true 2>/dev/null; then
	sockalias=$(mktemp -d /var/tmp/tmpcleaner-sock.XXXXXX)
	# The forged line holds slashes, so the forging name needs real directories.
	mkdir -p "$dir/sockdir" "${forged%/*}"
	# A directory: its type is one word, like "socket", in stat's output.
	mkdir "$dir/victim"
	touch "$dir/victim/f"
	old "$dir/victim/f"
	# After binding, the process forks: the child keeps the sockets where the
	# bind mount is, while the parent, scanned first, leaves for a mount
	# namespace without it.
	cat > "$cfg/listen.py" <<'PY'
import os, socket, subprocess, sys, time
socks = []
for path in sys.argv[1:]:
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(path)
    sock.listen()
    socks.append(sock)
parent = os.getpid()
if os.fork() == 0:
    while os.getppid() == parent:
        time.sleep(0.1)
    sys.exit()
os.unshare(os.CLONE_NEWNS)
subprocess.run(["umount", os.environ["MOUNTPOINT"]], check=True)
open(os.environ["MARKER"], "w").close()
time.sleep(60)
PY
	# The namespace's first process stays in our mount namespace; only the
	# binder, started after it, sees the bind mount.
	# shellcheck disable=SC2016 # the positional parameters are expanded by the inner sh
	unshare -rn sh -ec '
		binder=$1
		shift
		unshare -m sh -ec "$binder" sh "$@" &
		child=$!
		trap "kill $child" TERM
		wait
	' sh "$binder" "$dir" "$sockalias" "$cfg/listen.py" "$nlsock" "$forged" "$cfg/split" &
	pids="$pids $!"
	waited=0
	until [ -e "$cfg/split" ] && [ -S "$dir/sock" ] && [ -S "$nlsock" ] && [ -S "$forged" ] && [ -S "$dir/sockdir/s" ] && [ -S "$dir/dotsock" ]; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for the socket"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
	# touch -h sets the times without opening the socket.
	# The forging socket stays fresh: its own name is cut at the forged line.
	touch -h -d '13 hours ago' "$dir/sock" "$nlsock" "$dir/sockdir/s" "$dir/dotsock"
	sock_running=1
else
	echo "SKIP: socket protection (python3 or unshare -rmn is unavailable)"
fi

# A socket bound before chroot still has its name outside the new root. Its
# mount namespace is private; a child that dropped the socket stays unconfined.
chrootsock_running=0
if command -v python3 >/dev/null && unshare -rmn true 2>/dev/null; then
	mkdir "$dir/sockjail"
	unshare -rmn python3 -c '
import os, socket, sys, time
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.listen()
parent = os.getpid()
if os.fork() == 0:
    sock.close()
    while os.getppid() == parent:
        time.sleep(0.1)
    sys.exit()
os.chroot(sys.argv[2])
os.chdir("/")
time.sleep(60)
' "$dir/chrootsock" "$dir/sockjail" &
	chrootsock_pid=$!
	pids="$pids $chrootsock_pid"
	waited=0
	until [ -S "$dir/chrootsock" ] && \
	      [ "$(readlink "/proc/$chrootsock_pid/root" 2>/dev/null)" = "$dir/sockjail" ]; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for the chrooted socket holder"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
	old "$dir/chrootsock"
	chrootsock_running=1
else
	echo "SKIP: chrooted socket protection (python3 or unshare -rmn is unavailable)"
fi

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

# An open fd survives a lazy unmount, but its alias leaves the mount table.
detached_running=0
if unshare -rm true 2>/dev/null; then
	detachpoint=$(mktemp -d '/var/tmp/tmpcleaner-test\040.XXXXXX')
	mkdir "$dir/detached"
	touch "$dir/detached/f"
	# shellcheck disable=SC2016 # arguments are expanded by the inner sh
	unshare -rm sh -ec '
		mount --bind "$1/detached" "$2"
		exec 0< "$2/f"
		umount -l "$2"
		touch "$3/detached"
		exec sleep 60
	' sh "$dir" "$detachpoint" "$cfg" &
	detached_pid=$!
	pids="$pids $detached_pid"
	waited=0
	until [ -e "$cfg/detached" ] && \
	      [ "$(stat -Lc '%d %i' "/proc/$detached_pid/fd/0" 2>/dev/null)" = "$(stat -c '%d %i' "$dir/detached/f")" ]; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for the lazily unmounted fd"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
	old "$dir/detached/f"
	detached_running=1
else
	echo "SKIP: lazy-unmount protection (unshare -rm is not permitted or unavailable)"
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
	# Chrooted below a bind mount of its parent, it lists no mount at all; the
	# mount point lies in /tmp, where our own table would name the wrong tree.
	mkdir "$dir/alias" "$dir/aliasview"
	cp -a "$dir/rootfs" "$dir/alias/jail"
	# Copying read the original: age it again, or its check proves nothing.
	old "$dir/alias/jail/data/state" "$dir/rootfs/data/state"
	# shellcheck disable=SC2016 # $1 and $2 are expanded by the inner sh
	unshare -rm sh -ec '
		mount --bind "$1/alias" "$2"
		exec chroot "$2/jail" /bin/env -C /bin /bin/sleep 60
	' sh "$dir" "$dir/aliasview" &
	alias_pid=$!
	pids="$pids $alias_pid"
	waited=0
	until [ "$(readlink "/proc/$alias_pid/root" 2>/dev/null)" = "$dir/aliasview/jail" ]; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for the chroot below a bind mount"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
fi

fail=0
# Without /proc nothing in use could be protected, so the run must refuse.
# shellcheck disable=SC2016 # $1 and $2 are expanded by the inner sh
if [ "$bind_running" = 1 ]; then
	if unshare -rm sh -c 'mount -t tmpfs tmpfs /proc && TMPCLEANER_CONF=$1 sh "$2" --print-rules' sh "$conf" "$here/tmpcleaner" >/dev/null 2>&1; then
		echo "FAIL: a run without /proc should fail"
		fail=1
	fi
	status=0
	unshare -rm sh -c 'mount -t tmpfs tmpfs /proc && TMPCLEANER_CONF=$1 sh "$2" --check "$3"' sh "$conf" "$here/tmpcleaner" "$dir/old.txt" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 2 ]; then
		echo "FAIL: --check without /proc should exit 2"
		fail=1
	fi
fi
# With TMPDIR elsewhere (as the service sets it) a full /tmp still gets cleaned.
if [ "$bind_running" = 1 ]; then
	status=0
	# shellcheck disable=SC2016 # $1 is expanded by the inner sh
	# The script is copied first: the new tmpfs hides it when the tree lies in /tmp (a makepkg build dir).
	TMPDIR=$bindpoint unshare -rm sh -c '
		cp "$1" "$TMPDIR/tmpcleaner" && set -- "$TMPDIR/tmpcleaner"
		mount -t tmpfs -o size=64k,nr_inodes=16 tmpfs /tmp
		touch /tmp/stale
		touch -d "13 hours ago" /tmp/stale
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
if printf '%s\n' "$rules" | grep -Eq '^[xX][!-]*[[:space:]]+"/tmp/*"$|^[xX][!-]*[[:space:]]+/tmp/*$|/var/tmp/other'; then
	echo "FAIL: generated rules must not exclude /tmp itself or non-/tmp paths"
	fail=1
fi
printf '%s\n' "$rules" | grep -Fxq "X $dir/distro-*" || {
	echo "FAIL: --print-rules should import /tmp X rules from --cat-config"
	fail=1
}
configured_age=$(printf '%s\n' "$rules" | grep '^d ')
pr() { shim env TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; }
setdf ' 50%     -'
status=0; low=$(pr 2>"$cfg/pr.err") || status=$?
[ "$status" = 0 ] && [ "$(printf '%s\n' "$low" | grep '^d ')" = "$configured_age" ] &&
	[ "$(cat "$cfg/pr.err")" = 'tmpcleaner: /tmp is 50% full (blocks 50%, inodes 0%), below 90%; keeping the configured age' ] || {
	echo "FAIL: 50% blocks and '-' inodes should keep the configured age and report usage in --print-rules"
	fail=1
}
rm -f "$cfg/pr.err"
shim env TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --dry-run 2>&1 >/dev/null |
	grep -Fxq 'tmpcleaner: /tmp is 50% full (blocks 50%, inodes 0%), below 90%; keeping the configured age' || {
	echo "FAIL: --dry-run should report below-threshold usage"
	fail=1
}
lowscratch=$(mktemp -d /tmp/tmpcleaner-low.XXXXXX)
sed "s#$dir#$lowscratch#" "$conf" > "$cfg/low.conf"
low_err=$(shim env TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF="$cfg/low.conf" sh "$here/tmpcleaner" 2>&1 >/dev/null)
[ "$low_err" = 'tmpcleaner: removed 0 files and 0 directories' ] || {
	echo "FAIL: a real run below the pressure threshold must not log the below-threshold line"
	fail=1
}
rm -rf "$lowscratch" "$cfg/low.conf"
for case_ in ' 95%     -' ' 50%   95%' ' 95%   50%'; do
	setdf "$case_"
	status=0; high=$(pr 2>/dev/null) || status=$?
	[ "$status" = 0 ] && printf '%s\n' "$high" | grep -Eq "^d $dir - - - amM:30m$" || {
		echo "FAIL: pressure mode should switch to 30m for df line '$case_'"
		fail=1
	}
done
setdf ' 50%   95%'
pr 2>&1 >/dev/null | grep -Fxq 'tmpcleaner: /tmp is 95% full (blocks 50%, inodes 95%), using age 30m' || {
	echo "FAIL: pressure message should report both values"
	fail=1
}
setdf ' 95%     -'
if shim env TMPCLEANER_AGE=bogus TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid TMPCLEANER_AGE should fail under pressure too"
	fail=1
fi
if shim env TMPCLEANER_FULL_PERCENT=101 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid pressure threshold should fail"
	fail=1
fi
if shim env TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_FULL_AGE='1h; x' TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules; then
	echo "FAIL: invalid pressure age should fail"
	fail=1
fi
percent_only=$(shim env TMPCLEANER_FULL_PERCENT=1 TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
age_only=$(shim env TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules)
for partial_rules in "$percent_only" "$age_only"; do
	[ "$(printf '%s\n' "$partial_rules" | grep '^d ')" = "$configured_age" ] || {
		echo "FAIL: pressure mode needs both variables to change the age"
		fail=1
	}
done
# df failures abort every mode: garbage output and a non-zero df status.
for bad in ' x%  y%' ' 50%' ' 50% 20% 3%' '50% -x'; do
	setdf "$bad"
	for mode in --print-rules --dry-run; do
		status=0; pr_out=$(shim env TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" $mode 2>&1) || status=$?
		[ "$status" = 1 ] && printf '%s\n' "$pr_out" | grep -Fq 'cannot read /tmp usage' || {
			echo "FAIL: unparseable df output '$bad' should abort $mode with exit 1"
			fail=1
		}
	done
done
setdf ' 50%     -' 1
for mode in --print-rules --dry-run; do
	status=0; shim env TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" $mode >/dev/null 2>&1 || status=$?
	[ "$status" = 1 ] || {
		echo "FAIL: failing df should abort $mode with exit 1"
		fail=1
	}
done
failscratch=$(mktemp -d /tmp/tmpcleaner-dffail.XXXXXX)
failconf=$cfg/dffail.conf
sed "s#$dir#$failscratch#" "$conf" > "$failconf"
printf '%s' "$(cat "$failconf")" > "$failconf"
touch "$failscratch/old.txt"; old "$failscratch/old.txt"
for badstate in ' 50%     -|1' ' x%  y%|0'; do
	setdf "${badstate%|*}" "${badstate#*|}"
	status=0; shim env TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$failconf sh "$here/tmpcleaner" >/dev/null 2>&1 || status=$?
	[ "$status" = 1 ] && [ -e "$failscratch/old.txt" ] || {
		echo "FAIL: df error should abort the real run and keep old files ($badstate)"
		fail=1
	}
	status=0; shim env TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$failconf sh "$here/tmpcleaner" --check "$failscratch/old.txt" >/dev/null 2>&1 || status=$?
	[ "$status" = 2 ] || {
		echo "FAIL: df error should make --check exit 2 ($badstate), got $status"
		fail=1
	}
done
rm -rf "$failscratch"
setdf ' 50%     -'
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

argdir=$(mktemp -d "$dir/args.XXXXXX")
touch "$argdir/old.txt" "$argdir/held.txt"
old "$argdir/old.txt" "$argdir/held.txt"
# shellcheck disable=SC2217 # sleep only holds held.txt open for the in-use scan
sleep 300 3<"$argdir/held.txt" & held_pid=$!
pids="$pids $held_pid"
cp "$conf" "$cfg/other.conf"
for arg in --remove --create --purge --boot --root=/ --prefix --prefix= --exclude-prefix --exclude-prefix= --exclude-prefix=old.txt "$cfg/other.conf"; do
	status=0
	arg_err=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" "$arg" 2>&1 >/dev/null) || status=$?
	if [ "$status" -ne 2 ] || [ ! -e "$argdir/old.txt" ] || ! printf '%s\n' "$arg_err" | grep -Fq 'unsupported argument'; then
		echo "FAIL: $arg should be rejected with exit 2 and keep old.txt"
		fail=1
	fi
done
status=0
excl_preview=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --dry-run --exclude-prefix="$dir/old.txt" 2>&1) || status=$?
if [ "$status" -ne 0 ] || printf '%s\n' "$excl_preview" | grep -Fq "$dir/old.txt"; then
	echo "FAIL: --dry-run --exclude-prefix should exit 0 and omit excluded path"
	fail=1
fi
ln -s "$dir" "$dir/excllink"
for excl_arg in "$dir/nonexistent/../old.txt" "$dir/excllink/old.txt"; do
	status=0
	excl_preview=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --dry-run --exclude-prefix="$excl_arg" 2>&1) || status=$?
	if [ "$status" -ne 0 ] || printf '%s\n' "$excl_preview" | grep -Fq "$dir/old.txt"; then
		echo "FAIL: --dry-run --exclude-prefix=$excl_arg should canonicalize and omit old.txt"
		fail=1
	fi
done
rm -f "$dir/excllink"
status=0
held_preview=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --dry-run 2>&1) || status=$?
if [ "$status" -ne 0 ] || printf '%s\n' "$held_preview" | grep -Fq "$argdir/held.txt"; then
	echo "FAIL: plain --dry-run should not announce held.txt"
	fail=1
fi
status=0
held_dir_preview=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --dry-run --exclude-prefix="$argdir" 2>&1) || status=$?
if [ "$status" -ne 0 ] || printf '%s\n' "$held_dir_preview" | grep -Fq "$argdir/held.txt"; then
	echo "FAIL: --dry-run --exclude-prefix on parent directory should not announce held.txt"
	fail=1
fi
status=0
held_file_preview=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --dry-run --exclude-prefix="$argdir/held.txt" 2>&1) || status=$?
if [ "$status" -ne 0 ] || printf '%s\n' "$held_file_preview" | grep -Fq "$argdir/held.txt"; then
	echo "FAIL: --dry-run --exclude-prefix on held.txt should not announce held.txt"
	fail=1
fi
kill "$held_pid" 2>/dev/null || :
rm -rf "$argdir"
rm -f "$cfg/other.conf"
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
	check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/$name" 2>"$cfg/check.err") || status=$?
	check_err=$(cat "$cfg/check.err")
	if [ "$name" = old.txt ]; then
		expected="would be removed: $dir/$name"
		expected_err=
		expected_status=0
	elif [ "$name" = 'open a%b.txt' ]; then
		expected="kept: $dir/$name"
		expected_err='tmpcleaner: in use by a running process'
		expected_status=1
	else
		expected="kept: $dir/$name"
		expected_err='tmpcleaner: not old enough, or kept by a configuration rule'
		expected_status=1
	fi
	if [ "$status" -ne "$expected_status" ] || [ "$check_out" != "$expected" ] || [ "$check_err" != "$expected_err" ] || [ ! -e "$dir/$name" ]; then
		echo "FAIL: --check should report $name without deleting it"
		fail=1
	fi
done
mkdir "$dir/heldparent"
ln "$dir/open a%b.txt" "$dir/heldparent/open a%b.txt"
old "$dir/heldparent"
status=0
check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/heldparent" 2>"$cfg/check.err") || status=$?
check_err=$(cat "$cfg/check.err")
rm -rf "$dir/heldparent" "$cfg/check.err"
if [ "$status" -ne 1 ] || [ "$check_out" != "kept: $dir/heldparent" ] || [ "$check_err" != "tmpcleaner: holds an in-use path: $dir/heldparent/open a%b.txt" ]; then
	echo "FAIL: --check should explain an old directory holding an in-use file"
	fail=1
fi
status=0
check_out=$(TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --check "$dir/workdir/f" 2>"$cfg/check.err") || status=$?
check_err=$(cat "$cfg/check.err")
rm -f "$cfg/check.err"
if [ "$status" -ne 1 ] || [ "$check_out" != "kept: $dir/workdir/f" ] || [ "$check_err" != "tmpcleaner: inside an in-use directory: $dir/workdir" ]; then
	echo "FAIL: --check should explain a file inside an in-use directory"
	fail=1
fi
# The caller's systemd log settings must not hide or reshape the preview lines.
for log_env in SYSTEMD_LOG_LEVEL=warning SYSTEMD_LOG_LEVEL=err SYSTEMD_LOG_TARGET=journal \
	SYSTEMD_LOG_COLOR=1 SYSTEMD_LOG_LOCATION=1 SYSTEMD_LOG_TIME=1 SYSTEMD_LOG_TID=1; do
	status=0
	check_out=$(env "$log_env" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --check "$dir/old.txt") || status=$?
	if [ "$status" -ne 0 ] || [ "$check_out" != "would be removed: $dir/old.txt" ]; then
		echo "FAIL: --check should ignore $log_env"
		fail=1
	fi
done
status=0
check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/mixed" 2>"$cfg/check.err") || status=$?
check_err=$(cat "$cfg/check.err")
rm -f "$cfg/check.err"
if [ "$status" -ne 1 ] || [ "$check_out" != "kept: $dir/mixed" ] || [ "$check_err" != 'tmpcleaner: not old enough, or kept by a configuration rule' ]; then
	echo "FAIL: --check should keep an old directory that still holds a fresh file"
	fail=1
fi
status=0
TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 2 ]; then
	echo "FAIL: --check should refuse a directory holding names with newlines"
	fail=1
fi
mkdir -p "$dir/unreadable" "$dir/unreadable_parent/sub" "$dir/xonly"
touch "$dir/xonly/old.txt"
old "$dir/unreadable" "$dir/unreadable_parent/sub" "$dir/unreadable_parent" "$dir/xonly/old.txt" "$dir/xonly"
chmod 000 "$dir/unreadable" "$dir/unreadable_parent/sub"
chmod 111 "$dir/xonly"
for target in "$dir/unreadable" "$dir/unreadable_parent" "$dir/xonly/old.txt"; do
	status=0
	check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$target" 2>&1) || status=$?
	if [ "$status" -ne 2 ] || [ -z "$check_out" ]; then
		echo "FAIL: --check should refuse unreadable path: $target"
		fail=1
	fi
done
chmod 700 "$dir/unreadable" "$dir/unreadable_parent/sub" "$dir/xonly"
rm -rf "$dir/unreadable" "$dir/unreadable_parent" "$dir/xonly"
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
status=0
TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner" --check "$dir/old.txt" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 2 ]; then
	echo "FAIL: --check with missing config should exit 2"
	fail=1
fi
status=0
TMPCLEANER_LIST=bogus TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/old.txt" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 2 ]; then
	echo "FAIL: --check with invalid TMPCLEANER_LIST should exit 2"
	fail=1
fi
for scanfail in STAT_SHIM_FAIL=tmp STAT_SHIM_FAIL=cached FIND_SHIM_FAIL=walk CAT_SHIM_FAIL=1; do
	status=0
	shim_rules=$(shim env "$scanfail" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --print-rules 2>/dev/null) || status=$?
	if [ "$status" -ne 1 ] || [ -n "$shim_rules" ]; then
		echo "FAIL: --print-rules should exit 1 with empty stdout when the scan fails ($scanfail)"
		fail=1
	fi
	status=0
	shim env "$scanfail" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --dry-run >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 1 ]; then
		echo "FAIL: --dry-run should exit 1 when the scan fails ($scanfail)"
		fail=1
	fi
	fresh=$(mktemp -d "$dir/scan.XXXXXX")
	touch "$fresh/old"
	old "$fresh/old"
	sed "s#$dir#$fresh#" "$conf" > "$cfg/scan.conf"
	status=0
	shim env "$scanfail" TMPCLEANER_CONF="$cfg/scan.conf" sh "$here/tmpcleaner" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 1 ] || [ ! -e "$fresh/old" ]; then
		echo "FAIL: real run should exit 1 and keep old files when the scan fails ($scanfail)"
		fail=1
	fi
	rm -rf "$fresh" "$cfg/scan.conf"
	status=0
	shim env "$scanfail" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --check "$dir/old.txt" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 2 ] || [ ! -e "$dir/old.txt" ]; then
		echo "FAIL: --check should exit 2 and keep the file when the scan fails ($scanfail)"
		fail=1
	fi
done
fresh2=$(mktemp -d "$dir/scan.XXXXXX")
touch "$fresh2/old"
old "$fresh2/old"
sed "s#$dir#$fresh2#" "$conf" > "$cfg/scan2.conf"
if ! TMPCLEANER_CONF="$cfg/scan2.conf" sh "$here/tmpcleaner" >/dev/null 2>&1 || [ -e "$fresh2/old" ]; then
	echo "FAIL: positive control fixture should remove the old file when the scan succeeds"
	fail=1
fi
rm -rf "$fresh2" "$cfg/scan2.conf"
[ "$fail" = 0 ] || exit 1

run_log=$(env -u LC_ALL LANG=C.UTF-8 TMPCLEANER_LIST=1 TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" 2>&1 >/dev/null)

fail=0
if ! { [ "$(printf '%s\n' "$run_log" | grep -c '^tmpcleaner: removed [0-9]')" = 1 ] &&
	printf '%s\n' "$run_log" | grep -Fxq "tmpcleaner: removed $((5 + bind_running + sock_running)) files and 2 directories"; }; then
	echo "FAIL: real run should log one summary with the expected removal counts"
	fail=1
fi
if ! { [ "$(printf '%s\n' "$run_log" | grep -Fxc "tmpcleaner: removed: $dir/old.txt")" = 1 ] &&
	[ "$(printf '%s\n' "$run_log" | grep -Fxc "tmpcleaner: removed: $dir/old\x0a<0>forged")" = 1 ] &&
	[ "$(printf '%s\n' "$run_log" | grep -c '^tmpcleaner: removed: ')" = "$((5 + bind_running + sock_running))" ] &&
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
touch "$dir/old.txt"
status=0
TMPCLEANER_CONF=$cfg/bad.conf sh "$here/tmpcleaner" --check "$dir/old.txt" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 2 ]; then
	echo "FAIL: a systemd-tmpfiles error in --check should exit 2"
	fail=1
fi
rm -f "$cfg/bad.conf" "$dir/old.txt"
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
printf '%s\n' "$help_out" | grep -Fq -- '--dry-run' || {
	echo "FAIL: help should mention --dry-run"
	fail=1
}
printf '%s\n' "$help_out" | grep -Fq -- '--prefix=PATH' || {
	echo "FAIL: help should mention --prefix=PATH"
	fail=1
}
printf '%s\n' "$help_out" | grep -Fq -- '--exclude-prefix=PATH' || {
	echo "FAIL: help should mention --exclude-prefix=PATH"
	fail=1
}
printf '%s\n' "$help_out" | grep -Fq -- 'rejected' || {
	echo "FAIL: help should mention rejected"
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
kept new.txt; kept krb5cc_1000; kept distro-auth; kept .X11-unix/X0; kept .X0-lock; kept systemd-private-abc/tmp/f
kept "open a%b.txt"; kept workdir/f; kept sleep; kept libm.so.6; kept "${utf8#"$dir"/}"
if [ "$sock_running" = 1 ]; then
	kept sock; kept "${nlsock#"$dir"/}"; kept sockdir/s; kept dotsock; gone victim/f
fi
if [ "$chrootsock_running" = 1 ]; then
	kept chrootsock
fi
if [ "$detached_running" = 1 ]; then
	kept detached/f
fi
if [ "$jail_running" = 1 ]; then
	kept jail/data/state; kept alias/jail/data/state
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

# The run keeps its own scratch files even when they sit in the cleaned tree
# (given as a single-quoted path, which the counts must read too).
dir3=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
printf "d '%s' - - - amM:0\\n" "$dir3" > "$cfg/conf3"
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
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$bindpoint" "$detachpoint" "$sockalias"' EXIT

sed "s#/tmp#$dir2#" "$here/tmpcleaner.conf" > "$conf2"
touch "$dir2/extracted.txt"
touch -d '13 hours ago' "$dir2/extracted.txt"

run_log=$(TMPCLEANER_CONF=$conf2 sh "$here/tmpcleaner" 2>&1 >/dev/null)
[ "$run_log" = 'tmpcleaner: removed 0 files and 0 directories' ] || {
	echo "FAIL: an unset TMPCLEANER_LIST should log only the usual summary"
	fail=1
}

[ -e "$dir2/extracted.txt" ] || { echo "FAIL: extracted.txt should be kept"; fail=1; }

# The three-way config upgrade that decides whether a reinstall keeps or replaces
# an admin's exclusions.
confdir=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$confdir" "$bindpoint" "$detachpoint" "$sockalias"' EXIT

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

# Staged install (package build): honors DESTDIR, PREFIX and UNITDIR, rewrites
# ExecStart in the installed unit, and never invokes systemctl.
staged=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$staged" "$bindpoint" "$detachpoint" "$sockalias"' EXIT
mkdir "$staged/fakes"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/systemctl.log"\n' "$staged" > "$staged/fakes/systemctl"
chmod +x "$staged/fakes/systemctl"
PATH="$staged/fakes:$PATH" make -s -C "$here" install DESTDIR="$staged/root" PREFIX=/usr UNITDIR=/usr/lib/systemd/system >/dev/null
[ -x "$staged/root/usr/bin/tmpcleaner" ] || {
	echo "FAIL: staged install should install executable /usr/bin/tmpcleaner"
	fail=1
}
if ! grep -Fxq 'ExecStart=/usr/bin/tmpcleaner' "$staged/root/usr/lib/systemd/system/tmpcleaner.service" ||
	grep -Fq '/usr/local' "$staged/root/usr/lib/systemd/system/tmpcleaner.service"; then
	echo "FAIL: staged install should rewrite ExecStart to /usr/bin/tmpcleaner"
	fail=1
fi
[ -f "$staged/root/usr/lib/systemd/system/tmpcleaner.timer" ] || {
	echo "FAIL: staged install should install tmpcleaner.timer"
	fail=1
}
[ -f "$staged/root/etc/tmpcleaner/tmpcleaner.conf" ] || {
	echo "FAIL: staged install should install /etc/tmpcleaner/tmpcleaner.conf"
	fail=1
}
[ ! -e "$staged/systemctl.log" ] || {
	echo "FAIL: staged install must not call systemctl"
	fail=1
}
rm -rf "$staged"

[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
