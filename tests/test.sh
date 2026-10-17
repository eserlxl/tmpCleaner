#!/bin/sh
# Runs tmpcleaner with tmpcleaner.conf retargeted from /tmp to a scratch dir
# under /tmp (in-use detection only looks at /tmp paths). Birth and ctime
# cannot be backdated, so the test drops b/B/c/C from the age-by field and
# keeps the rest as configured.
set -eu
unset TMPCLEANER_AGE TMPCLEANER_FULL_PERCENT TMPCLEANER_FULL_AGE TMPCLEANER_LIST TMPCLEANER_METRICS
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
shmdir=
scope_outside=
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$shimdir" "$bindpoint" "$detachpoint" "$sockalias" "$shmdir" "$scope_outside"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

awk '$1 == "d" { gsub(/[bcBC]/, "", $6) } { print }' "$here/tmpcleaner.conf" |
	sed "s#/tmp#$dir#" > "$conf"
printf '%s' "$(cat "$conf")" > "$conf"

# df, stat, find, mktemp, and systemd-tmpfiles shims: every pressure or
# scan-failure test runs with $shimdir first on PATH. DF_SHIM_OUT holds the
# data line, DF_SHIM_STATUS the exit; STAT_SHIM_FAIL, FIND_SHIM_FAIL,
# MKTEMP_SHIM_FAIL, and CAT_SHIM_FAIL select which step fails; CAT_SHIM_OUT
# answers --cat-config from a file.
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
	# Only the socket check in verify(): the in-use batch prints %n as well.
	verify:*"%d %i %F"*) exit 1 ;;
	verify-killed:*"%d %i %F"*) "$(command -v stat)" -L --cached=always --printf '%d %i %F\0' -- /; kill -KILL \$\$ ;;
	# A batch cut after its sentinel, as an OOM kill would leave it.
	killed:*"%n %F"*) "$(command -v stat)" -L --cached=always --printf '%d %i %n %F\0' -- /; kill -KILL \$\$ ;;
esac
exec "$(command -v stat)" "\$@"
SHIM
cat > "$shimdir/find" <<SHIM
#!/bin/sh
case "\${FIND_SHIM_FAIL:-}:\$*" in
	walk:"/tmp -xdev -printf"*) exit 1 ;;
	walk-killed:"/tmp -xdev -printf"*) "$(command -v find)" /tmp -maxdepth 0 -printf '%i %p\0'; kill -KILL \$\$ ;;
	killed:/proc/self/ns/mnt*) "$(command -v find)" /proc/self/ns/mnt -maxdepth 0 -type l -printf '%p\0%l\0'; kill -KILL \$\$ ;;
esac
exec "$(command -v find)" "\$@"
SHIM
cat > "$shimdir/mktemp" <<SHIM
#!/bin/sh
case "\${MKTEMP_SHIM_FAIL:-}:\$*" in
	primary:-d|both:-d|both:"-d -p /dev/shm") exit 1 ;;
	readonly:-d)
		d=\$("$(command -v mktemp)" -d) || exit 1
		printf '%s\n' "\$d" > "\$MKTEMP_SHIM_PARTIAL"
		mkdir "\$d/excludes"
		printf '%s\n' "\$d"
		exit 0
		;;
esac
exec "$(command -v mktemp)" "\$@"
SHIM
cat > "$shimdir/systemd-tmpfiles" <<SHIM
#!/bin/sh
if [ "\$*" = --cat-config ]; then
	[ -z "\${CAT_SHIM_FAIL:-}" ] || exit 1
	cat "\$CAT_SHIM_OUT"
	exit 0
fi
[ -z "\${CLEAN_SHIM_MARKER:-}" ] || printf '%s\n' "\$*" >> "\$CLEAN_SHIM_MARKER"
[ -z "\${CLEAN_SHIM_DELAY:-}" ] || sleep "\$CLEAN_SHIM_DELAY"
[ -z "\${CLEAN_SHIM_STDOUT:-}" ] || printf '%s\n' "\$CLEAN_SHIM_STDOUT"
[ -z "\${CLEAN_SHIM_STATUS:-}" ] || exit "\$CLEAN_SHIM_STATUS"
if [ -n "\${CLEAN_SHIM_POST_STATUS:-}" ]; then
	"$(command -v systemd-tmpfiles)" "\$@" || exit \$?
	exit "\$CLEAN_SHIM_POST_STATUS"
fi
exec "$(command -v systemd-tmpfiles)" "\$@"
SHIM
cat > "$shimdir/date" <<SHIM
#!/bin/sh
[ -z "\${DATE_SHIM_FAIL:-}" ] || exit 1
[ -z "\${DATE_SHIM_VALUE:-}" ] || { printf '%s\n' "\$DATE_SHIM_VALUE"; exit 0; }
exec "$(command -v date)" "\$@"
SHIM
cat > "$shimdir/awk" <<SHIM
#!/bin/sh
case "\$1" in
	*'getline line < "/proc/self/mountinfo"'*)
		if [ -n "\${MOUNTINFO_SHIM_FILE:-}" ]; then
			program=\$(printf '%s' "\$1" | sed "s@/proc/self/mountinfo@\$MOUNTINFO_SHIM_FILE@g")
			shift; set -- "\$program" "\$@"
		fi ;;
esac
case "\$*" in
	*'elapsed = finish - start'*)
		[ -z "\${DURATION_SHIM_MARKER:-}" ] || : > "\$DURATION_SHIM_MARKER"
		[ -z "\${DURATION_SHIM_FAIL:-}" ] || exit 1 ;;
esac
exec "$(command -v awk)" "\$@"
SHIM
chmod +x "$shimdir/df" "$shimdir/stat" "$shimdir/find" "$shimdir/mktemp" "$shimdir/systemd-tmpfiles" "$shimdir/date" "$shimdir/awk"
dfout=$shimdir/out
catout=$shimdir/cat
printf ' 50%%     -\n' > "$dfout"
printf 'X %s/distro-*\nx "%s/quoted dir"\nx /tmp\nx /tmp/\nx /var/tmp/other\n' "$dir" "$dir" > "$catout"
export DF_SHIM_OUT="$dfout" CAT_SHIM_OUT="$catout"
PATH=$shimdir:$PATH
export PATH
shim() { PATH=$shimdir:$PATH "$@"; }
setdf() { printf '%s\n' "$1" > "$dfout"; DF_SHIM_STATUS=${2:-0}; export DF_SHIM_STATUS; }

old() { touch -d '13 hours ago' "$@"; }
failure_metrics_ok() {
	grep -Fxq 'tmpcleaner_removed_files 0' "$cfg/failure.prom" &&
	grep -Fxq 'tmpcleaner_removed_directories 0' "$cfg/failure.prom" &&
	grep -Fxq 'tmpcleaner_last_exit_status 1' "$cfg/failure.prom" &&
	grep -Fxq "tmpcleaner_pressure_mode_active ${1:-0}" "$cfg/failure.prom" &&
	grep -Eq '^tmpcleaner_last_run_duration_seconds (NaN|[0-9]+[.][0-9][0-9])$' "$cfg/failure.prom" &&
	grep -Eq '^tmpcleaner_last_run_timestamp_seconds [1-9][0-9]*$' "$cfg/failure.prom"
}
mkdir -p "$dir/emptydir" "$dir/freshdir" "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" "$dir/workdir" "$dir/quoted dir"
touch "$dir/old.txt" "$dir/new.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" \
      "$dir/.X0-lock" "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" \
      "$dir/workdir/f" "$dir/krb5cc_1000" "$dir/distro-auth" "$dir/quoted dir/f"
old "$dir/old.txt" "$dir/olddir/f" "$dir/.X11-unix/X0" "$dir/.X0-lock" \
    "$dir/systemd-private-abc/tmp/f" "$dir/open a%b.txt" "$dir/workdir/f" "$dir/krb5cc_1000" "$dir/distro-auth" "$dir/quoted dir/f"
old "$dir/olddir" "$dir/.X11-unix" "$dir/systemd-private-abc/tmp" \
    "$dir/systemd-private-abc" "$dir/workdir" "$dir/quoted dir"

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
"$dir/sleep" infinity & pids="$pids $!"
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
import os, signal, socket, subprocess, sys, time
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
signal.pause()
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
import os, signal, socket, sys, time
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
signal.pause()
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

# Host-namespace sockets cover quote() on "'" and the 200-path verify() batch
# plus remainder even when unshare -rmn is refused.
sockbatch_running=0
if command -v python3 >/dev/null; then
	python3 -c '
import signal, socket, sys
root = sys.argv[1]
paths = [f"{root}/s\x271"] + [f"{root}/b{i}" for i in range(1, 206)]
socks = []
for path in paths:
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(path)
    sock.listen()
    socks.append(sock)
signal.pause()
	' "$dir" &
	sockbatch_pid=$!
	pids="$pids $sockbatch_pid"
	waited=0
	until [ -S "$dir/s'1" ] && [ -S "$dir/b205" ]; do
		if [ "$waited" -ge 100 ]; then
			echo "FAIL: timed out waiting for the host-namespace socket batch"
			exit 1
		fi
		waited=$((waited + 1))
		sleep 0.1
	done
	touch -h -d '13 hours ago' "$dir/s'1" "$dir"/b[0-9]*
	sockbatch_running=1
else
	echo "SKIP: host socket batch (python3 is unavailable)"
fi

# A name holding an invalid UTF-8 byte and a space, held open: under a UTF-8
# locale the escaping must still quote all of it (the run below uses one).
utf8="$dir/u$(printf '\377') x"
touch "$utf8"
old "$utf8"
# shellcheck disable=SC2217 # sleep only holds these files open for the in-use scan
sleep infinity < "$utf8" & pids="$pids $!"
# shellcheck disable=SC2217 # sleep only holds these files open for the in-use scan
sleep infinity < "$dir/open a%b.txt" 3<"$star" 4<"$glob" 5<"$bs" 6<"$newline" 7<"$carriage" 8<"$tabbed" 9<"$quote" & pids="$pids $!"
(cd "$dir/workdir" && exec sleep infinity) & pids="$pids $!"
libm=$(ldconfig -p | awk '/libm\.so\.6/ { print $NF; exit }')
cp "$libm" "$dir"
LD_PRELOAD="$dir/libm.so.6" sleep infinity & pids="$pids $!"
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
	unshare -rm chroot "$dir/rootfs" /bin/env -C /bin /bin/sleep infinity &
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
		LD_PRELOAD="$2/libm.so.6" exec "$2/sleep" infinity < "$2/f"
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
		exec sleep infinity
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
		exec chroot "$2" /bin/env -C /bin /bin/sleep infinity
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
		exec chroot "$2/jail" /bin/env -C /bin /bin/sleep infinity
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
	printf 'tmpcleaner_last_exit_status 0\n' > "$cfg/failure.prom"
	status=0
	# shellcheck disable=SC2016 # arguments are expanded by the inner sh
	unshare -rm sh -c 'mount -t tmpfs tmpfs /proc && TMPCLEANER_CONF=$1 TMPCLEANER_METRICS=$3 sh "$2"' \
		sh "$conf" "$here/tmpcleaner" "$cfg/failure.prom" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 1 ] || ! failure_metrics_ok; then
		echo 'FAIL: a real run without /proc must refresh failure metrics'
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
# With TMPDIR unset, a full /tmp still gets cleaned by falling back to /dev/shm.
if [ "$bind_running" = 1 ]; then
	status=0
	shmdir=$(mktemp -d -p /dev/shm)
	# shellcheck disable=SC2016 # $1 and $2 are expanded by the inner sh
	# The script is copied first: the new tmpfs hides it when the tree lies in /tmp (a makepkg build dir).
	(unset TMPDIR; unshare -rm sh -c '
		cp "$1" "$2/tmpcleaner"
		mount -t tmpfs -o size=64k,nr_inodes=16 tmpfs /tmp
		touch /tmp/stale
		touch -d "13 hours ago" /tmp/stale
		i=0
		while touch "/tmp/f$i" 2>/dev/null; do i=$((i + 1)); done
		printf "d /tmp - - - amM:6h\n" > "$2/full.conf"
		unset TMPDIR
		TMPCLEANER_CONF=$2/full.conf sh "$2/tmpcleaner" 2>/dev/null && [ ! -e /tmp/stale ]
	' sh "$here/tmpcleaner" "$shmdir") || status=$?
	rm -rf "$shmdir"
	shmdir=
	if [ "$status" -ne 0 ]; then
		echo "FAIL: a full /tmp should still be cleaned when TMPDIR is unset"
		fail=1
	fi
fi
# Without unshare, scratch creation still falls back to /dev/shm (and removes
# a partial primary directory when $scratch/excludes cannot be written), and
# aborts when both scratch locations fail.
for mkfail in primary readonly; do
	fbdir=$(mktemp -d "$dir/fb.XXXXXX")
	touch "$fbdir/old"
	old "$fbdir/old"
	sed "s#$dir#$fbdir#" "$conf" > "$cfg/fb.conf"
	rm -f "$cfg/partial"
	status=0
	shim env MKTEMP_SHIM_FAIL="$mkfail" MKTEMP_SHIM_PARTIAL="$cfg/partial" TMPCLEANER_CONF="$cfg/fb.conf" sh "$here/tmpcleaner" 2>/dev/null || status=$?
	if [ "$status" -ne 0 ] || [ -e "$fbdir/old" ]; then
		echo "FAIL: scratch fallback to /dev/shm should clean old files ($mkfail)"
		fail=1
	fi
	if [ "$mkfail" = readonly ]; then
		partial=$(cat "$cfg/partial" 2>/dev/null || :)
		if [ -z "$partial" ] || [ -e "$partial" ]; then
			echo "FAIL: partial primary scratch directory should be removed on fallback"
			rm -rf "$partial"
			fail=1
		fi
	fi
	rm -rf "$fbdir" "$cfg/fb.conf" "$cfg/partial"
done
noscratch=$(mktemp -d "$dir/noscratch.XXXXXX")
touch "$noscratch/old"
old "$noscratch/old"
sed "s#$dir#$noscratch#" "$conf" > "$cfg/noscratch.conf"
status=0
printf 'tmpcleaner_last_exit_status 0\n' > "$cfg/failure.prom"
noscratch_err=$(shim env MKTEMP_SHIM_FAIL=both TMPCLEANER_METRICS=$cfg/failure.prom TMPCLEANER_CONF="$cfg/noscratch.conf" sh "$here/tmpcleaner" 2>&1) || status=$?
if [ "$status" -ne 1 ] || [ ! -e "$noscratch/old" ] ||
	! printf '%s\n' "$noscratch_err" | grep -Fq 'tmpcleaner: cannot create a scratch directory' || ! failure_metrics_ok; then
	echo "FAIL: total scratch failure should exit 1, report error, and keep old files"
	fail=1
fi
status=0
noscratch_check_err=$(shim env MKTEMP_SHIM_FAIL=both TMPCLEANER_CONF="$cfg/noscratch.conf" sh "$here/tmpcleaner" --check "$noscratch/old" 2>&1) || status=$?
if [ "$status" -ne 2 ] || [ ! -e "$noscratch/old" ] ||
	! printf '%s\n' "$noscratch_check_err" | grep -Fq 'tmpcleaner: cannot create a scratch directory'; then
	echo "FAIL: --check on total scratch failure should exit 2, report error, and keep old files"
	fail=1
fi
rm -rf "$noscratch" "$cfg/noscratch.conf"
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
# Raw inventory preserves filename bytes and excludes its own physical scratch
# paths even when TMPDIR reaches them through a symlinked parent.
raw_root=$dir/raw-export
raw_open="$raw_root/open[*]?${nl}"
raw_cwd=$raw_root/cwd
raw_tmp="$raw_root/tmp${nl}"
mkdir -p "$raw_cwd" "$raw_tmp"
printf 'unchanged\n' > "$raw_open"
printf 'unchanged\n' > "$raw_root/closed"
printf 'unchanged\n' > "$raw_root/static"
printf 'd %s - - - 12h\nx %s/static\n' "$raw_root" "$raw_root" > "$cfg/raw.conf"
ln -s "$raw_tmp" "$cfg/raw-tmp"
# shellcheck disable=SC2217 # sleep holds the file open for the in-use scan
(cd "$raw_cwd" && exec sleep infinity < "$raw_open") & raw_pid=$!; pids="$pids $raw_pid"
tries=0
until [ "$(readlink "/proc/$raw_pid/cwd")" = "$raw_cwd" ] && [ "/proc/$raw_pid/fd/0" -ef "$raw_open" ]; do
	tries=$((tries + 1)); [ "$tries" -lt 100 ] || { echo 'FAIL: raw inventory holder did not start'; exit 1; }
	sleep 0.01
done
status=0
TMPDIR=$cfg/raw-tmp TMPCLEANER_CONF=$cfg/raw.conf TMPCLEANER_LIST=nul TMPCLEANER_METRICS=$cfg/raw.prom \
	CLEAN_SHIM_MARKER=$cfg/raw.clean sh "$here/tmpcleaner" --print-in-use0 > "$cfg/raw.out" 2> "$cfg/raw.err" || status=$?
if [ "$status" -ne 0 ] || [ -s "$cfg/raw.err" ] || [ -e "$cfg/raw.prom" ] || [ -e "$cfg/raw.clean" ] ||
	! RAW_OPEN=$raw_open RAW_CWD=$raw_cwd RAW_ROOT=$raw_root LC_ALL=C awk '
		BEGIN { RS = "\0" }
		$0 == ENVIRON["RAW_OPEN"] { opened++ }
		$0 == ENVIRON["RAW_CWD"] { cwd++ }
		$0 == ENVIRON["RAW_ROOT"] "/closed" || $0 == ENVIRON["RAW_ROOT"] "/static" ||
		index($0, ENVIRON["RAW_ROOT"] "/tmp") == 1 { bad++ }
		END { exit !(opened == 1 && cwd == 1 && !bad) }
	' "$cfg/raw.out" || ! LC_ALL=C sort -zcu "$cfg/raw.out" ||
	[ "$(tail -c 1 "$cfg/raw.out" | od -An -tu1 | tr -d ' ')" != 0 ]; then
	echo 'FAIL: raw inventory must be unique sorted NUL records with exact held paths and no synthetic exclusions'
	fail=1
fi
for raw_file in "$raw_open" "$raw_root/closed" "$raw_root/static"; do
	[ "$(cat "$raw_file")" = unchanged ] || { echo 'FAIL: raw inventory changed a fixture file'; fail=1; }
done
kill "$raw_pid"; wait "$raw_pid" 2>/dev/null || :
rm -rf "$raw_root" "$cfg/raw-tmp"
for extra in --dry-run --prefix=/tmp --exclude-prefix=/tmp --print-rules --print-in-use0 --help '' positional; do
	status=0
	TMPCLEANER_CONF=$cfg/missing.conf sh "$here/tmpcleaner" --print-in-use0 "$extra" > "$cfg/raw.out" 2> "$cfg/raw.err" || status=$?
	if [ "$status" -ne 2 ] || [ -s "$cfg/raw.out" ] || ! grep -Fq 'accepts no other arguments' "$cfg/raw.err"; then
		echo 'FAIL: raw inventory must reject extra arguments before reading configuration'
		fail=1
	fi
done
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
printf '%s\n' "$rules" | grep -Fxq "x \"$dir/quoted dir\"" || {
	echo "FAIL: --print-rules should import quoted /tmp exclusion with spaces from --cat-config"
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
low_err=$(shim env TMPCLEANER_METRICS=$cfg/pressure.prom TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF="$cfg/low.conf" sh "$here/tmpcleaner" 2>&1 >/dev/null)
[ "$low_err" = 'tmpcleaner: removed 0 files and 0 directories' ] &&
	grep -Fxq 'tmpcleaner_pressure_mode_active 0' "$cfg/pressure.prom" || {
	echo "FAIL: a real run below the pressure threshold must not log the below-threshold line"
	fail=1
}
for case_ in ' 90%     -' ' 95%     -' ' 50%   95%' ' 95%   50%'; do
	setdf "$case_"
	status=0; high=$(pr 2>/dev/null) || status=$?
	[ "$status" = 0 ] && printf '%s\n' "$high" | grep -Eq "^d $dir - - - amM:30m$" || {
		echo "FAIL: pressure mode should switch to 30m for df line '$case_'"
		fail=1
	}
	status=0
	shim env TMPCLEANER_METRICS=$cfg/pressure.prom TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m \
		TMPCLEANER_CONF="$cfg/low.conf" sh "$here/tmpcleaner" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 0 ] || ! grep -Fxq 'tmpcleaner_pressure_mode_active 1' "$cfg/pressure.prom" ||
		! grep -Fxq 'tmpcleaner_last_exit_status 0' "$cfg/pressure.prom" ||
		! grep -Fxq 'tmpcleaner_removed_files 0' "$cfg/pressure.prom" ||
		! grep -Fxq 'tmpcleaner_removed_directories 0' "$cfg/pressure.prom"; then
		echo "FAIL: pressure metrics must record the selected override ($case_)"
		fail=1
	fi
done
rm -rf "$lowscratch" "$cfg/low.conf"
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
	printf 'tmpcleaner_last_exit_status 0\n' > "$cfg/failure.prom"
	status=0; shim env TMPCLEANER_METRICS=$cfg/failure.prom TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m TMPCLEANER_CONF=$failconf sh "$here/tmpcleaner" >/dev/null 2>&1 || status=$?
	[ "$status" = 1 ] && [ -e "$failscratch/old.txt" ] && failure_metrics_ok || {
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
if [ "$sockbatch_running" = 1 ] && { ! printf '%s\n' "$rules" | grep -Fxq "x \"$dir/s'1\"" ||
	! printf '%s\n' "$rules" | grep -Fxq "x \"$dir/b205\""; }; then
	echo "FAIL: printed rules should exclude the single-quoted socket and a socket past the 200-path flush"
	fail=1
fi
[ -e "$dir/old.txt" ] || {
	echo "FAIL: printing rules should keep old.txt"
	fail=1
}
[ "$fail" = 0 ] || exit 1

status=0
preview=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --dry-run 2>&1) || status=$?
if [ "$status" -ne 0 ] || ! { [ "$(printf '%s\n' "$preview" | grep -c '^tmpcleaner: would remove [0-9]')" = 1 ] &&
	printf '%s\n' "$preview" | grep -Fxq "tmpcleaner: would remove $(printf '%s\n' "$preview" | grep -c '^Would remove "') files and $(printf '%s\n' "$preview" | grep -c '^Would remove directory "') directories"; }; then
	echo "FAIL: preview should exit 0 and announce removal counts"
	fail=1
fi
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
sleep infinity 3<"$argdir/held.txt" & held_pid=$!
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
# A path check can evaluate the same temporary exclusions as a real run.
for exclusion_case in exact ancestor multiple symlink dotdot unrelated in-use; do
	target=$dir/old.txt
	set -- "--exclude-prefix=$target"
	expected_status=1
	expected_err='tmpcleaner: kept by an explicit --exclude-prefix'
	case "$exclusion_case" in
		ancestor) target=$dir/olddir/f; set -- "--exclude-prefix=$dir/olddir" ;;
		multiple) set -- "--exclude-prefix=$dir/new.txt" "--exclude-prefix=$target" ;;
		symlink) set -- "--exclude-prefix=$dir/selflink/old.txt" ;;
		dotdot) set -- "--exclude-prefix=$dir/nonexistent/../old.txt" ;;
		unrelated) set -- "--exclude-prefix=$dir/new.txt"; expected_status=0; expected_err= ;;
		in-use)
			target=$dir/'open a%b.txt'
			set -- "--exclude-prefix=$target"
			expected_err='tmpcleaner: in use by a running process'
			;;
	esac
	status=0
	check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$target" "$@" 2>"$cfg/check.err") || status=$?
	check_err=$(cat "$cfg/check.err")
	if [ "$expected_status" = 0 ]; then expected="would be removed: $target"; else expected="kept: $target"; fi
	if [ "$status" -ne "$expected_status" ] || [ "$check_out" != "$expected" ] ||
		[ "$check_err" != "$expected_err" ] || [ ! -e "$target" ]; then
		echo "FAIL: --check should honor $exclusion_case exclusions without deleting the path or misreporting its holder"
		fail=1
	fi
done
for arg in --prefix=/tmp --dry-run --remove --help --exclude-prefix --exclude-prefix= --exclude-prefix=relative extra; do
	status=0
	check_err=$(TMPCLEANER_CONF=$dir/missing.conf sh "$here/tmpcleaner" --check "$dir/old.txt" \
		"--exclude-prefix=$dir/old.txt" "$arg" 2>&1) || status=$?
	if [ "$status" -ne 2 ] || [ "$check_err" != "tmpcleaner: unsupported argument: $arg" ] || [ ! -e "$dir/old.txt" ]; then
		echo "FAIL: --check should reject $arg before reading configuration or cleaning"
		fail=1
	fi
done
# Explicit exclusions also suppress independently configured cleanup roots.
for filter_name in keep 'keep[ab]' 'keep%root' "keep' quoted"; do
	for filter_scope in all prefix in-use; do
		filter_root=$(mktemp -d "$dir/root-filter.XXXXXX")
		filter_keep=$filter_root/$filter_name
		mkdir -p "$filter_keep/deep" "$filter_keep-sibling" "$filter_root/keepa"
		touch "$filter_keep/old" "$filter_keep/.hidden" "$filter_keep/deep/old" "$filter_keep/deep/.hidden" \
			"$filter_keep-sibling/old" "$filter_keep-sibling/.hidden" "$filter_root/keepa/old" "$filter_root/keepa/.hidden"
		old "$filter_keep/old" "$filter_keep/.hidden" "$filter_keep/deep/old" "$filter_keep/deep/.hidden" \
			"$filter_keep-sibling/old" "$filter_keep-sibling/.hidden" "$filter_root/keepa/old" "$filter_root/keepa/.hidden"
		rule_keep=$(printf '%s' "$filter_keep" | sed 's/%/%%/g')
		printf 'd %s - - - amM:12h\nd "%s" - - - amM:12h\nd "%s/deep" - - - amM:12h\n' \
			"$filter_root" "$rule_keep" "$rule_keep" > "$cfg/root-filter.conf"
		set --
		[ "$filter_scope" != prefix ] || set -- "--prefix=$filter_root"
		filter_pid=
		if [ "$filter_scope" = in-use ]; then
			(cd "$filter_keep" && exec sleep infinity) & filter_pid=$!
			pids="$pids $filter_pid"
			waited=0
			while [ "$(readlink "/proc/$filter_pid/cwd")" != "$filter_keep" ] && [ "$waited" -lt 100 ]; do
				waited=$((waited + 1)); sleep 0.1
			done
		else
			set -- "$@" "--exclude-prefix=$filter_keep"
		fi
		status=0
		TMPCLEANER_CONF=$cfg/root-filter.conf sh "$here/tmpcleaner" "$@" >/dev/null 2>&1 || status=$?
		if [ "$status" -ne 0 ] || [ ! -e "$filter_keep/old" ] || [ ! -e "$filter_keep/.hidden" ] ||
			[ ! -e "$filter_keep/deep/old" ] || [ ! -e "$filter_keep/deep/.hidden" ] ||
			[ -e "$filter_keep-sibling/old" ] || [ -e "$filter_keep-sibling/.hidden" ] ||
			[ -e "$filter_root/keepa/old" ] || [ -e "$filter_root/keepa/.hidden" ]; then
			echo "FAIL: explicit exclusion must protect exact/deeper roots and keep siblings eligible ($filter_name, $filter_scope)"
			fail=1
		fi
		status=0
		set -- "--exclude-prefix=$filter_keep"
		expected_err='tmpcleaner: kept by an explicit --exclude-prefix'
		if [ "$filter_scope" = in-use ]; then
			set --
			expected_err="tmpcleaner: inside an in-use directory: $filter_keep"
		fi
		check_out=$(TMPCLEANER_CONF=$cfg/root-filter.conf sh "$here/tmpcleaner" --check "$filter_keep/old" \
			"$@" 2>"$cfg/check.err") || status=$?
		if [ "$status" -ne 1 ] || [ "$check_out" != "kept: $filter_keep/old" ] ||
			[ "$(cat "$cfg/check.err")" != "$expected_err" ]; then
			echo "FAIL: --check must honor explicit exclusions of configured roots"
			fail=1
		fi
		[ -z "$filter_pid" ] || { kill "$filter_pid"; wait "$filter_pid" 2>/dev/null || :; }
		rm -rf "$filter_root"
	done
done
# Native whitespace separators must not disguise an exact protected root.
filter_root=$(mktemp -d "$dir/root-filter.XXXXXX")
mkdir "$filter_root/cr" "$filter_root/ff" "$filter_root/vt"
touch "$filter_root/cr/old" "$filter_root/ff/old" "$filter_root/vt/old" "$filter_root/sibling"
old "$filter_root/cr/old" "$filter_root/ff/old" "$filter_root/vt/old" "$filter_root/sibling"
printf 'd %s - - - amM:12h\nd %s/cr\r- - - amM:12h\nd %s/ff\f- - - amM:12h\nd %s/vt\v- - - amM:12h\n\r\n' \
	"$filter_root" "$filter_root" "$filter_root" "$filter_root" > "$cfg/root-filter.conf"
status=0
TMPCLEANER_CONF=$cfg/root-filter.conf sh "$here/tmpcleaner" "--exclude-prefix=$filter_root/cr" \
	"--exclude-prefix=$filter_root/ff" "--exclude-prefix=$filter_root/vt" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 0 ] || [ ! -e "$filter_root/cr/old" ] || [ ! -e "$filter_root/ff/old" ] ||
	[ ! -e "$filter_root/vt/old" ] || [ -e "$filter_root/sibling" ]; then
	echo "FAIL: native CR/FF/VT separators must preserve protected roots and keep siblings eligible"
	fail=1
fi
rm -rf "$filter_root"
# Types other than d must not bypass a prefix, while x/X remain unchanged.
filter_root=$(mktemp -d "$dir/root-filter.XXXXXX")
printf 'd %s - - - amM:12h\nx %s/keep/guard\nX %s/keep/other\n' "$filter_root" "$filter_root" "$filter_root" > "$cfg/root-filter.conf"
for rule_type in D e v q Q C R f; do printf '%s %s/keep/%s - - - 12h\n' "$rule_type" "$filter_root" "$rule_type" >> "$cfg/root-filter.conf"; done
filter_rules=$(TMPCLEANER_CONF=$cfg/root-filter.conf sh "$here/tmpcleaner" --print-rules "--exclude-prefix=$filter_root/keep")
if printf '%s\n' "$filter_rules" | grep -Eq '^[DevqQCRf] ' ||
	! printf '%s\n' "$filter_rules" | grep -Fxq "x $filter_root/keep/guard" ||
	! printf '%s\n' "$filter_rules" | grep -Fxq "X $filter_root/keep/other"; then
	echo "FAIL: explicit exclusions must filter every non-x/X root type"
	fail=1
fi
# Outside fixtures are never passed to a real cleanup backend, even if validation regresses.
scope_base=$here
case "$scope_base" in /tmp|/tmp/*) scope_base=/dev/shm ;; esac
scope_outside=$(mktemp -d "$scope_base/.tmpcleaner-scope.XXXXXX")
printf 'untouched\n' > "$scope_outside/sentinel"
ln -s "$scope_outside" "$filter_root/outside"
for bad_root in "$filter_root/encoded\\x20root" "$filter_root/%T" "$filter_root/glob*" \
	"$scope_outside" "/tmp/..$scope_outside" "$filter_root/outside"; do
	printf 'e "%s" - - - 12h\n' "$bad_root" > "$cfg/root-filter.conf"
	for filter_mode in real dry check rules unfiltered export prefix; do
		case "$filter_mode" in
			real) set -- ;;
			dry) set -- --dry-run ;;
			check) set -- --check "$dir/old.txt" ;;
			rules|unfiltered) set -- --print-rules ;;
			export) set -- --print-in-use0 ;;
			prefix) set -- "--prefix=$bad_root" ;;
		esac
		case "$filter_mode" in unfiltered|export) ;; *) set -- "$@" "--exclude-prefix=$filter_root/keep" ;; esac
		status=0
		CLEAN_SHIM_STATUS=99 CLEAN_SHIM_MARKER=$cfg/filter.clean TMPCLEANER_CONF=$cfg/root-filter.conf sh "$here/tmpcleaner" "$@" \
			>"$cfg/filter.out" 2>"$cfg/filter.err" || status=$?
		expected_status=1
		[ "$filter_mode" != check ] || expected_status=2
		if [ "$status" -ne "$expected_status" ] || [ -s "$cfg/filter.out" ] || [ -e "$cfg/filter.clean" ] ||
			! grep -Fq 'cannot safely interpret rule' "$cfg/filter.err" ||
			[ "$(cat "$scope_outside/sentinel")" != untouched ]; then
			echo "FAIL: $filter_mode must refuse unsafe rule paths before cleaning ($bad_root)"
			fail=1
		fi
	done
done
mkdir "$filter_root/inside"
ln -s "$filter_root/inside" "$filter_root/alias"
printf 'd /tmp - - - 12h\nd %s/inside/../inside - - - 12h\nd %s/alias - - - 12h\nx %s\nX %s/*\n' \
	"$filter_root" "$filter_root" "$scope_outside" "$scope_outside" > "$cfg/root-filter.conf"
if ! TMPCLEANER_CONF=$cfg/root-filter.conf sh "$here/tmpcleaner" --print-rules > "$cfg/filter.out" ||
	! grep -Fxq "x $scope_outside" "$cfg/filter.out" || ! grep -Fxq "X $scope_outside/*" "$cfg/filter.out"; then
	echo 'FAIL: valid /tmp roots and outside x/X exclusions must remain accepted'
	fail=1
fi
rm -rf "$scope_outside" "$filter_root" "$cfg/root-filter.conf" "$cfg/filter.err" "$cfg/filter.out" "$cfg/filter.clean"
scope_outside=
# Nested mount roots cannot bypass the /tmp-only inode index or -xdev walk.
cat > "$cfg/mount-roots.sh" <<'MOUNT_TEST'
set -eu
here=$1 dir=$2 cfg=$3
root=$dir/mount-roots
mkdir -p "$root/tmpfs" "$root/source" "$root/bind-dir"
touch "$root/source/file" "$root/bind-file"
mount --make-rprivate /
# A mount at /tmp itself is allowed; only nested mountpoints are boundaries.
mount --bind /tmp /tmp
mount -t tmpfs tmpfs "$root/tmpfs"
printf 'held\n' > "$root/tmpfs/held"
touch -d '13 hours ago' "$root/tmpfs/held"
exec 3< "$root/tmpfs/held"
mount --bind "$root/source" "$root/bind-dir"
mount --bind "$root/source/file" "$root/bind-file"
escaped="$root/space $(printf '\t\nx')\040"
mkdir "$escaped"
mount -t tmpfs tmpfs "$escaped"
ln -s "$escaped" "$root/escaped-alias"
for path in "$root/tmpfs" "$root/tmpfs/missing/deeper" "$root/bind-dir" "$root/bind-file" "$root/escaped-alias"; do
	printf 'd %s - - - amM:12h\n' "$path" > "$cfg/mount.conf"
	for mode in real dry check rules raw; do
		case "$mode" in
			real) set -- "--prefix=$path" ;;
			dry) set -- --dry-run ;;
			check) set -- --check "$root/tmpfs/held" ;;
			rules) set -- --print-rules ;;
			raw) set -- --print-in-use0 ;;
		esac
		status=0
		CLEAN_SHIM_STATUS=99 CLEAN_SHIM_MARKER=$cfg/mount.clean TMPCLEANER_CONF=$cfg/mount.conf \
			sh "$here/tmpcleaner" "$@" > "$cfg/mount.out" 2> "$cfg/mount.err" || status=$?
		expected=1; [ "$mode" != check ] || expected=2
		[ "$status" -eq "$expected" ] && [ ! -s "$cfg/mount.out" ] && [ ! -e "$cfg/mount.clean" ] &&
			grep -Fq 'cleanup root crosses a nested /tmp mount' "$cfg/mount.err" || {
			cat "$cfg/mount.err"; echo "FAIL: nested mount root must fail before cleanup ($mode: $path)"; exit 1;
		}
	done
done
printf 'd /tmp - - - 12h\nx %s/tmpfs\n' "$root" > "$cfg/mount.conf"
TMPCLEANER_CONF=$cfg/mount.conf sh "$here/tmpcleaner" --print-rules > "$cfg/mount.out"
grep -Fxq "x $root/tmpfs" "$cfg/mount.out"
[ "$(cat "$root/tmpfs/held")" = held ]
MOUNT_TEST
if unshare -rm true 2>/dev/null; then
	if ! unshare -rm sh "$cfg/mount-roots.sh" "$here" "$dir" "$cfg"; then fail=1; fi
else
	echo 'SKIP: nested mount roots (unshare -rm is not permitted or unavailable)'
fi
# Mountinfo read errors, empty files and partial malformed records fail closed.
printf 'd %s - - - 12h\n' "$dir" > "$cfg/mount.conf"
: > "$cfg/mount.empty"
head -n 1 /proc/self/mountinfo > "$cfg/mount.truncated"
printf '1 2 0:1 / /tmp/truncated rw - tmpfs\n' >> "$cfg/mount.truncated"
for mount_info in "$cfg/mount.missing" "$cfg/mount.empty" "$cfg/mount.truncated"; do
	for mode in real dry check rules raw; do
		case "$mode" in
			real) set -- ;;
			dry) set -- --dry-run ;;
			check) set -- --check "$dir/old.txt" ;;
			rules) set -- --print-rules ;;
			raw) set -- --print-in-use0 ;;
		esac
		status=0
		MOUNTINFO_SHIM_FILE=$mount_info CLEAN_SHIM_STATUS=99 CLEAN_SHIM_MARKER=$cfg/mount.clean \
			TMPCLEANER_CONF=$cfg/mount.conf sh "$here/tmpcleaner" "$@" > "$cfg/mount.out" 2> "$cfg/mount.err" || status=$?
		expected=1; [ "$mode" != check ] || expected=2
		if [ "$status" -ne "$expected" ] || [ -s "$cfg/mount.out" ] || [ -e "$cfg/mount.clean" ] ||
			! grep -Fq mountinfo "$cfg/mount.err"; then
			echo "FAIL: mountinfo failure must stop $mode before cleanup ($mount_info)"
			fail=1
		fi
	done
done
rm -rf "$dir/mount-roots"
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
# Control bytes in held children and in-use ancestors are replaced with "?" on stderr.
ctrl_name=$(printf 'c\001\t\r\033\177z')
mkdir "$dir/ctrlparent" "$dir/$ctrl_name"
touch "$dir/ctrlparent/$ctrl_name" "$dir/$ctrl_name/f"
old "$dir/ctrlparent/$ctrl_name" "$dir/ctrlparent" "$dir/$ctrl_name/f" "$dir/$ctrl_name"
# shellcheck disable=SC2217 # sleep only holds the control-byte file open for --check
sleep infinity < "$dir/ctrlparent/$ctrl_name" &
ctrl_fd_pid=$!
pids="$pids $ctrl_fd_pid"
(cd "$dir/$ctrl_name" && exec sleep infinity) &
ctrl_cwd_pid=$!
pids="$pids $ctrl_cwd_pid"
waited=0
until [ "$(readlink "/proc/$ctrl_fd_pid/fd/0" 2>/dev/null)" = "$dir/ctrlparent/$ctrl_name" ] && \
      [ "$(readlink "/proc/$ctrl_cwd_pid/cwd" 2>/dev/null)" = "$dir/$ctrl_name" ]; do
	if [ "$waited" -ge 100 ]; then
		echo "FAIL: timed out waiting for control-byte holders"
		exit 1
	fi
	waited=$((waited + 1))
	sleep 0.1
done
status=0
check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/ctrlparent" 2>"$cfg/check.err") || status=$?
check_err=$(cat "$cfg/check.err")
if [ "$status" -ne 1 ] || [ "$check_out" != "kept: $dir/ctrlparent" ] || [ "$check_err" != "tmpcleaner: holds an in-use path: $dir/ctrlparent/c?????z" ]; then
	echo "FAIL: --check should sanitize control bytes in a held child path"
	fail=1
fi
status=0
check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/$ctrl_name/f" 2>"$cfg/check.err") || status=$?
check_err=$(cat "$cfg/check.err")
if [ "$status" -ne 1 ] || [ "$check_out" != "kept: $dir/c?????z/f" ] || [ "$check_err" != "tmpcleaner: inside an in-use directory: $dir/c?????z" ]; then
	echo "FAIL: --check should sanitize control bytes in an in-use ancestor directory"
	fail=1
fi
esc_name=$(printf 'e\033[2Jx')
touch "$dir/$esc_name"
old "$dir/$esc_name"
check_out=$(TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/$esc_name" 2>/dev/null) || :
if [ "$check_out" != "would be removed: $dir/e?[2Jx" ]; then
	echo "FAIL: --check should mask control bytes in the verdict line"
	fail=1
fi
rm -f -- "$dir/${esc_name:?}"
kill "$ctrl_fd_pid" "$ctrl_cwd_pid" 2>/dev/null || :
wait "$ctrl_fd_pid" "$ctrl_cwd_pid" 2>/dev/null || :
rm -rf "$dir/ctrlparent" "$dir/${ctrl_name:?}" "$cfg/check.err"
# The caller's systemd log settings must not hide or reshape the preview lines.
plain_summary=$(TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --dry-run 2>&1 | grep '^tmpcleaner: would remove') || :
for log_env in SYSTEMD_LOG_LEVEL=warning SYSTEMD_LOG_LEVEL=err SYSTEMD_LOG_TARGET=journal \
	SYSTEMD_LOG_COLOR=1 SYSTEMD_LOG_LOCATION=1 SYSTEMD_LOG_TIME=1 SYSTEMD_LOG_TID=1; do
	status=0
	check_out=$(env "$log_env" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --check "$dir/old.txt") || status=$?
	if [ "$status" -ne 0 ] || [ "$check_out" != "would be removed: $dir/old.txt" ]; then
		echo "FAIL: --check should ignore $log_env"
		fail=1
	fi
	dry_summary=$(env "$log_env" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --dry-run 2>&1 | grep '^tmpcleaner: would remove') || :
	if [ "$dry_summary" != "$plain_summary" ]; then
		echo "FAIL: --dry-run summary should ignore $log_env"
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
for scanfail in STAT_SHIM_FAIL=tmp STAT_SHIM_FAIL=cached STAT_SHIM_FAIL=verify STAT_SHIM_FAIL=killed STAT_SHIM_FAIL=verify-killed FIND_SHIM_FAIL=walk FIND_SHIM_FAIL=killed FIND_SHIM_FAIL=walk-killed CAT_SHIM_FAIL=1; do
	status=0
	shim_rules=$(shim env "$scanfail" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --print-rules 2>/dev/null) || status=$?
	if [ "$status" -ne 1 ] || [ -n "$shim_rules" ]; then
		echo "FAIL: --print-rules should exit 1 with empty stdout when the scan fails ($scanfail)"
		fail=1
	fi
	status=0
	shim env "$scanfail" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" --print-in-use0 > "$cfg/raw.out" 2>/dev/null || status=$?
	if [ "$status" -ne 1 ] || [ -s "$cfg/raw.out" ]; then
		echo "FAIL: --print-in-use0 should exit 1 with empty stdout when the scan fails ($scanfail)"
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
	printf 'tmpcleaner_last_exit_status 0\n' > "$cfg/failure.prom"
	rm -f "$cfg/failed-clean"
	scan_threshold=90 scan_pressure=0
	if [ "$scanfail" = CAT_SHIM_FAIL=1 ]; then scan_threshold=50 scan_pressure=1; fi
	status=0
	shim env "$scanfail" TMPCLEANER_FULL_PERCENT=$scan_threshold TMPCLEANER_FULL_AGE=30m \
		TMPCLEANER_METRICS=$cfg/failure.prom CLEAN_SHIM_MARKER=$cfg/failed-clean TMPCLEANER_CONF="$cfg/scan.conf" sh "$here/tmpcleaner" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 1 ] || [ ! -e "$fresh/old" ] || [ -e "$cfg/failed-clean" ] || ! failure_metrics_ok "$scan_pressure"; then
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
for bad_metrics in relative.prom ./metrics.prom "$cfg/metrics.txt" /.prom "/tmp/bad${nl}.prom"; do
	status=0
	TMPCLEANER_METRICS="$bad_metrics" TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --print-rules >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 1 ]; then
		echo "FAIL: invalid TMPCLEANER_METRICS '$bad_metrics' should exit 1"
		fail=1
	fi
	status=0
	TMPCLEANER_METRICS="$bad_metrics" TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --check "$dir/old.txt" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 2 ]; then
		echo "FAIL: --check with invalid TMPCLEANER_METRICS '$bad_metrics' should exit 2"
		fail=1
	fi
done
# Initialized real-run failures replace stale success even before a scan starts.
printf 'd %%T - - - 12h\n' > "$cfg/metrics-bad-root.conf"
for earlyfail in "TMPCLEANER_CONF=$cfg/missing.conf" TMPCLEANER_AGE=bogus TMPCLEANER_LIST=bogus \
	TMPCLEANER_FULL_PERCENT=101 TMPCLEANER_FULL_AGE=bogus "TMPCLEANER_CONF=$cfg/metrics-bad-root.conf"; do
	printf 'tmpcleaner_last_exit_status 0\n' > "$cfg/failure.prom"
	rm -f "$cfg/failed-clean"
	status=0
	shim env TMPCLEANER_CONF="$conf" TMPCLEANER_FULL_PERCENT=90 TMPCLEANER_FULL_AGE=30m "$earlyfail" \
		TMPCLEANER_METRICS=$cfg/failure.prom CLEAN_SHIM_MARKER=$cfg/failed-clean sh "$here/tmpcleaner" >/dev/null 2>&1 || status=$?
	if [ "$status" -ne 1 ] || [ -e "$cfg/failed-clean" ] || ! failure_metrics_ok; then
		echo "FAIL: initialized real-run failure must refresh metrics without cleaning ($earlyfail)"
		fail=1
	fi
done
printf 'existing metrics bytes\n' > "$cfg/metrics.expected"
for mode in --print-rules --print-in-use0 --dry-run --check; do
	set -- "$mode"
	[ "$mode" != --check ] || set -- --check "$dir/old.txt"
	for previewfail in '' CAT_SHIM_FAIL=1; do
		cp "$cfg/metrics.expected" "$cfg/metrics.prom"
		rm -f "$cfg/duration.called"
		status=0
		# An empty value is accepted as an unset shim failure flag.
		shim env "${previewfail:-CAT_SHIM_FAIL=}" TMPCLEANER_FULL_PERCENT=50 TMPCLEANER_FULL_AGE=30m \
			DURATION_SHIM_MARKER=$cfg/duration.called TMPCLEANER_METRICS=$cfg/metrics.prom TMPCLEANER_CONF="$conf" \
			sh "$here/tmpcleaner" "$@" >/dev/null 2>&1 || status=$?
		if ! cmp -s "$cfg/metrics.expected" "$cfg/metrics.prom" || [ -e "$cfg/duration.called" ]; then
			echo "FAIL: preview must preserve existing metrics ($mode $previewfail, status $status)"
			fail=1
		fi
	done
done
status=0
TMPCLEANER_METRICS=$cfg/metrics.prom TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" --unknown >/dev/null 2>&1 || status=$?
if [ "$status" -ne 2 ] || ! cmp -s "$cfg/metrics.expected" "$cfg/metrics.prom"; then
	echo 'FAIL: rejected CLI usage must not write metrics'
	fail=1
fi
cp "$cfg/metrics.expected" "$cfg/invalid${nl}.prom"
status=0
TMPCLEANER_METRICS="$cfg/invalid${nl}.prom" TMPCLEANER_CONF=$conf sh "$here/tmpcleaner" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 1 ] || ! cmp -s "$cfg/metrics.expected" "$cfg/invalid${nl}.prom"; then
	echo 'FAIL: an invalid metrics path must leave existing metrics untouched'
	fail=1
fi
# Uptime duration covers the delayed backend even with frozen/reversed date
# values, and preserves both successful and failed cleanup statuses.
mkdir "$dir/duration"
printf 'd %s/duration - - - amM:12h\n' "$dir" > "$cfg/duration.conf"
for duration_case in 2000000000:0 2000000000:0 1000000000:42; do
	status=0
	shim env DATE_SHIM_VALUE=${duration_case%:*} CLEAN_SHIM_DELAY=0.2 CLEAN_SHIM_STATUS=${duration_case#*:} \
		TMPCLEANER_CONF=$cfg/duration.conf TMPCLEANER_METRICS=$cfg/duration.prom \
		sh "$here/tmpcleaner" >/dev/null 2> "$cfg/duration.err" || status=$?
	if [ "$status" -ne "${duration_case#*:}" ] ||
		! grep -Fxq "tmpcleaner_last_run_timestamp_seconds ${duration_case%:*}" "$cfg/duration.prom" ||
		! grep -Fxq "tmpcleaner_last_exit_status ${duration_case#*:}" "$cfg/duration.prom" ||
		! LC_ALL=C awk '$1 == "tmpcleaner_last_run_duration_seconds" { found++; if ($2 !~ /^[0-9]+[.][0-9][0-9]$/ || $2 + 0 < 0.20) exit 1 } END { if (found != 1) exit 1 }' "$cfg/duration.prom"; then
		echo 'FAIL: run duration must cover backend delay independently of wall-clock changes'
		fail=1
	fi
done
status=0
shim env DURATION_SHIM_FAIL=1 CLEAN_SHIM_STATUS=42 TMPCLEANER_CONF=$cfg/duration.conf TMPCLEANER_METRICS=$cfg/duration.prom \
	sh "$here/tmpcleaner" >/dev/null 2> "$cfg/duration.err" || status=$?
if [ "$status" -ne 42 ] || ! grep -Fxq 'tmpcleaner_last_run_duration_seconds NaN' "$cfg/duration.prom" ||
	! grep -Fxq 'tmpcleaner_last_exit_status 42' "$cfg/duration.prom" ||
	! grep -Fxq 'tmpcleaner_removed_files 0' "$cfg/duration.prom" ||
	! grep -Fxq 'tmpcleaner_removed_directories 0' "$cfg/duration.prom" ||
	grep -Fq 'cannot write metrics' "$cfg/duration.err"; then
	echo 'FAIL: duration calculation failure must retain other gauges and status without a warning'
	fail=1
fi
rm -f "$cfg/duration.called"
shim env DURATION_SHIM_MARKER=$cfg/duration.called CLEAN_SHIM_STATUS=0 TMPCLEANER_CONF=$cfg/duration.conf \
	sh "$here/tmpcleaner" >/dev/null 2>&1
if [ -e "$cfg/duration.called" ]; then
	echo 'FAIL: metrics-disabled run must not invoke the duration calculation'
	fail=1
fi
rm -rf "$dir/duration"
[ "$fail" = 0 ] || exit 1

run_log=$(env -u LC_ALL LANG=C.UTF-8 TMPCLEANER_LIST=1 TMPCLEANER_METRICS="$cfg/metrics.prom" TMPCLEANER_CONF="$conf" sh "$here/tmpcleaner" 2>&1 >/dev/null)

fail=0
expected_files=$((5 + bind_running + sock_running))
if ! { [ -f "$cfg/metrics.prom" ] &&
	grep -Fxq '# HELP tmpcleaner_removed_files Number of files removed in the last run.' "$cfg/metrics.prom" &&
	grep -Fxq '# TYPE tmpcleaner_removed_files gauge' "$cfg/metrics.prom" &&
	grep -Fxq "tmpcleaner_removed_files $expected_files" "$cfg/metrics.prom" &&
	grep -Fxq '# HELP tmpcleaner_removed_directories Number of directories removed in the last run.' "$cfg/metrics.prom" &&
	grep -Fxq '# TYPE tmpcleaner_removed_directories gauge' "$cfg/metrics.prom" &&
	grep -Fxq 'tmpcleaner_removed_directories 2' "$cfg/metrics.prom" &&
	grep -Fxq '# HELP tmpcleaner_last_run_timestamp_seconds Unix timestamp of the last run completion.' "$cfg/metrics.prom" &&
	grep -Fxq '# TYPE tmpcleaner_last_run_timestamp_seconds gauge' "$cfg/metrics.prom" &&
	grep -Eq '^tmpcleaner_last_run_timestamp_seconds [1-9][0-9]*$' "$cfg/metrics.prom" &&
	grep -Fxq '# HELP tmpcleaner_last_exit_status Exit status of the last run.' "$cfg/metrics.prom" &&
	grep -Fxq '# TYPE tmpcleaner_last_exit_status gauge' "$cfg/metrics.prom" &&
	grep -Fxq 'tmpcleaner_last_exit_status 0' "$cfg/metrics.prom" &&
	grep -Fxq '# HELP tmpcleaner_pressure_mode_active Whether the pressure age override was selected in the last run.' "$cfg/metrics.prom" &&
	grep -Fxq '# TYPE tmpcleaner_pressure_mode_active gauge' "$cfg/metrics.prom" &&
	grep -Fxq 'tmpcleaner_pressure_mode_active 0' "$cfg/metrics.prom" &&
	grep -Fxq '# HELP tmpcleaner_last_run_duration_seconds Elapsed seconds from metrics initialization to publication.' "$cfg/metrics.prom" &&
	grep -Fxq '# TYPE tmpcleaner_last_run_duration_seconds gauge' "$cfg/metrics.prom" &&
	grep -Eq '^tmpcleaner_last_run_duration_seconds [0-9]+[.][0-9][0-9]$' "$cfg/metrics.prom"; }; then
	echo "FAIL: real run should write all gauges matching the summary counts and pressure decision"
	fail=1
fi
rm -f "$cfg/metrics.prom"
if ! { [ "$(printf '%s\n' "$run_log" | grep -c '^tmpcleaner: removed [0-9]')" = 1 ] &&
	printf '%s\n' "$run_log" | grep -Fxq "tmpcleaner: removed $expected_files files and 2 directories"; }; then
	echo "FAIL: real run should log one summary with the expected removal counts"
	fail=1
fi
if ! { [ "$(printf '%s\n' "$run_log" | grep -Fxc "tmpcleaner: removed: $dir/old.txt")" = 1 ] &&
	[ "$(printf '%s\n' "$run_log" | grep -Fxc "tmpcleaner: removed: $dir/old\x0a<0>forged")" = 1 ] &&
	[ "$(printf '%s\n' "$run_log" | grep -c '^tmpcleaner: removed: ')" = "$expected_files" ] &&
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
printf '%s\n' "$help_out" | grep -Fq -- '--print-in-use0' || {
	echo "FAIL: help should mention --print-in-use0"
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
printf '%s\n' "$help_out" | grep -Fq 'TMPCLEANER_METRICS' || {
	echo "FAIL: help should mention TMPCLEANER_METRICS"
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
kept new.txt; kept krb5cc_1000; kept distro-auth; kept "quoted dir/f"; kept "quoted dir"; kept .X11-unix/X0; kept .X0-lock; kept systemd-private-abc/tmp/f
kept "open a%b.txt"; kept workdir/f; kept sleep; kept libm.so.6; kept "${utf8#"$dir"/}"
if [ "$sock_running" = 1 ]; then
	kept sock; kept "${nlsock#"$dir"/}"; kept sockdir/s; kept dotsock; gone victim/f
fi
if [ "$chrootsock_running" = 1 ]; then
	kept chrootsock
fi
if [ "$sockbatch_running" = 1 ]; then
	kept "s'1"; kept b1; kept b200; kept b205
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
				exec sleep infinity < "$1/big/f"
			else
				mount --bind "$1" "$2"
				mount --bind "$1/held" "$2/big"
				exec sleep infinity < "$2/big/f"
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

# Counts, listings and metrics include every age-cleanup type and deduplicate
# overlapping roots. Boot-only rules and static exclusions remain untouched.
count_root=$(mktemp -d "$dir/counts.XXXXXX")
mkdir "$cfg/count-source"
: > "$cfg/count.conf"
: > "$cfg/count.expected"
for count_type in e D v q Q C d- 'd!'; do
	count_path=$count_root/$count_type
	mkdir "$count_path"
	touch "$count_path/old"
	old "$count_path/old"
	if [ "$count_type" = C ]; then
		printf 'C "%s" - - - amM:12h %s\n' "$count_path" "$cfg/count-source" >> "$cfg/count.conf"
	else
		printf "%s '%s' - - - amM:12h\n" "$count_type" "$count_path" >> "$cfg/count.conf"
	fi
	[ "$count_type" = 'd!' ] || printf 'tmpcleaner: removed: %s/old\n' "$count_path" >> "$cfg/count.expected"
done
touch "$count_root/e/kept"
old "$count_root/e/kept"
printf 'x %s/e/kept\n' "$count_root" >> "$cfg/count.conf"
mkdir -p "$count_root/overlap/nested"
touch "$count_root/overlap/nested/old"
old "$count_root/overlap/nested/old"
printf 'd %s/overlap//. - - - amM:12h\nD %s/overlap//nested/. - - - amM:12h\n' "$count_root" "$count_root" >> "$cfg/count.conf"
printf 'tmpcleaner: removed: %s/overlap/nested/old\n' "$count_root" >> "$cfg/count.expected"
count_files=8 count_dirs=0
backend_major=$(systemd-tmpfiles --version | awk 'NR == 1 { print $2 + 0 }')
if [ "$backend_major" -ge 262 ]; then
	touch "$count_root/r"
	mkdir "$count_root/R"
	touch "$count_root/R/old"
	old "$count_root/r" "$count_root/R/old" "$count_root/R"
	printf 'r %s/r - - - amM:12h\nR %s/R - - - amM:12h\n' "$count_root" "$count_root" >> "$cfg/count.conf"
	printf 'tmpcleaner: removed: %s/r\ntmpcleaner: removed: %s/R/old\ntmpcleaner: removed directory: %s/R\n' "$count_root" "$count_root" "$count_root" >> "$cfg/count.expected"
	count_files=10 count_dirs=1
fi
printf 'tmpcleaner: removed %s files and %s directories\n' "$count_files" "$count_dirs" >> "$cfg/count.expected"
status=0
TMPDIR=$count_root/d- TMPCLEANER_CONF=$cfg/count.conf TMPCLEANER_LIST=1 TMPCLEANER_METRICS=$cfg/count.prom \
	sh "$here/tmpcleaner" > "$cfg/count.out" 2> "$cfg/count.log" || status=$?
LC_ALL=C sort "$cfg/count.expected" > "$cfg/count.expected-sorted"
LC_ALL=C sort "$cfg/count.log" > "$cfg/count.actual-sorted"
if [ "$status" -ne 0 ] || [ -s "$cfg/count.out" ] ||
	! cmp -s "$cfg/count.expected-sorted" "$cfg/count.actual-sorted" ||
	! grep -Fxq "tmpcleaner_removed_files $count_files" "$cfg/count.prom" ||
	! grep -Fxq "tmpcleaner_removed_directories $count_dirs" "$cfg/count.prom" ||
	[ ! -e "$count_root/d!/old" ] || [ ! -e "$count_root/e/kept" ]; then
	echo 'FAIL: age-cleanup types must have exact deduplicated counts, listings and metrics'
	fail=1
fi
while IFS= read -r count_line; do
	case "$count_line" in
		'tmpcleaner: removed: '*) count_path=${count_line#'tmpcleaner: removed: '} ;;
		'tmpcleaner: removed directory: '*) count_path=${count_line#'tmpcleaner: removed directory: '} ;;
		*) continue ;;
	esac
	[ ! -e "$count_path" ] || { echo "FAIL: counted fixture still exists: $count_path"; fail=1; }
done < "$cfg/count.expected"
rm -rf "$count_root" "$cfg/count-source"

# Scratch paths are literal even with glob and control bytes inside the cleaned tree.
# The single-quoted root also exercises the removal-count parser.
for scratch_name in . 'scratch[ab]' 'scratch*?' "$(printf 'scratch\001\t\nend')"; do
	dir3=$(mktemp -d "$dir/scratch.XXXXXX")
	scratch_dir=$dir3/$scratch_name
	mkdir -p "$scratch_dir"
	printf "d '%s' - - - amM:0\\n" "$dir3" > "$cfg/conf3"
	touch "$dir3/f"
	status=0
	scratch_log=$(TMPDIR=$scratch_dir TMPCLEANER_AGE=0 TMPCLEANER_CONF=$cfg/conf3 sh "$here/tmpcleaner" 2>&1) || status=$?
	if [ "$status" -ne 0 ] || [ "$scratch_log" != 'tmpcleaner: removed 1 files and 0 directories' ] ||
		[ -e "$dir3/f" ] || [ -n "$(find "$scratch_dir" -mindepth 1 -print -quit)" ]; then
		echo "FAIL: the run must preserve scratch state, count the removed file, and leave no scratch files"
		fail=1
	fi
	rm -rf "$dir3" "$cfg/conf3"
done

# NUL removal listings preserve hostile bytes, directories and overlapping roots.
list_root=$(mktemp -d "$dir/list-nul.XXXXXX")
printf 'd %s - - - amM:12h\nd %s//. - - - amM:12h\n' "$list_root" "$list_root" > "$cfg/list.conf"
touch "$list_root/held"
old "$list_root/held"
# shellcheck disable=SC2217 # sleep holds this file open for protection
sleep infinity < "$list_root/held" & list_pid=$!; pids="$pids $list_pid"
tries=0
until [ "/proc/$list_pid/fd/0" -ef "$list_root/held" ]; do
	tries=$((tries + 1)); [ "$tries" -lt 100 ] || { echo 'FAIL: NUL listing holder did not start'; exit 1; }
	sleep 0.01
done
for list_status in 0 42; do
	: > "$cfg/list.expected"
	for list_name in "line${nl}end" 'back\slash' 'glob[*]?' "$(printf 'control\001\tend')"; do
		touch "$list_root/$list_name"
		old "$list_root/$list_name"
		printf '%s\0' "$list_root/$list_name" >> "$cfg/list.expected"
	done
	mkdir "$list_root/gone-dir"
	old "$list_root/gone-dir"
	printf '%s\0' "$list_root/gone-dir" >> "$cfg/list.expected"
	status=0
	TMPDIR=$list_root TMPCLEANER_CONF=$cfg/list.conf TMPCLEANER_LIST=nul TMPCLEANER_METRICS=$cfg/list.prom \
		CLEAN_SHIM_STDOUT=backend-output CLEAN_SHIM_POST_STATUS=$list_status sh "$here/tmpcleaner" \
		> "$cfg/list.out" 2> "$cfg/list.err" || status=$?
	LC_ALL=C sort -z "$cfg/list.expected" > "$cfg/list.expected-sorted"
	LC_ALL=C sort -z "$cfg/list.out" > "$cfg/list.actual-sorted"
	if [ "$status" -ne "$list_status" ] || ! cmp -s "$cfg/list.expected-sorted" "$cfg/list.actual-sorted" ||
		[ "$(grep -c '^tmpcleaner: removed ' "$cfg/list.err")" -ne 1 ] ||
		! grep -Fxq 'tmpcleaner: removed 4 files and 1 directories' "$cfg/list.err" ||
		! grep -Fxq backend-output "$cfg/list.err" ||
		! grep -Fxq "tmpcleaner_last_exit_status $list_status" "$cfg/list.prom" ||
		! grep -Fxq 'tmpcleaner_removed_files 4' "$cfg/list.prom" ||
		! grep -Fxq 'tmpcleaner_removed_directories 1' "$cfg/list.prom" ||
		[ ! -e "$list_root/held" ] || [ -n "$(find "$list_root" -mindepth 1 ! -name held -print -quit)" ]; then
		echo 'FAIL: NUL listings must export only exact unique disappearances and preserve backend status/metrics'
		fail=1
	fi
done
status=0
TMPCLEANER_CONF=$cfg/list.conf TMPCLEANER_LIST=nul sh "$here/tmpcleaner" > "$cfg/list.out" 2> "$cfg/list.err" || status=$?
if [ "$status" -ne 0 ] || [ -s "$cfg/list.out" ] ||
	[ "$(cat "$cfg/list.err")" != 'tmpcleaner: removed 0 files and 0 directories' ]; then
	echo 'FAIL: empty NUL listing must keep stdout empty and log one summary'
	fail=1
fi
status=0
TMPCLEANER_CONF=$cfg/list.conf TMPCLEANER_LIST=nul CAT_SHIM_FAIL=1 sh "$here/tmpcleaner" \
	> "$cfg/list.out" 2> "$cfg/list.err" || status=$?
if [ "$status" -ne 1 ] || [ -s "$cfg/list.out" ]; then
	echo 'FAIL: a pre-clean failure must not export removals'
	fail=1
fi
# NUL listing selection leaves previews in their normal formats and never cleans.
for list_preview in rules dry check; do
	case "$list_preview" in
		rules) set -- --print-rules ;;
		dry) set -- --dry-run ;;
		check) set -- --check "$list_root/held" ;;
	esac
	status=0
	TMPCLEANER_CONF=$cfg/list.conf TMPCLEANER_LIST=nul CLEAN_SHIM_STDOUT=backend-output sh "$here/tmpcleaner" "$@" \
		> "$cfg/list.out" 2> "$cfg/list.err" || status=$?
	case "$list_preview" in
		rules) [ "$status" -eq 0 ] && grep -Fq "d $list_root " "$cfg/list.out" ;;
		dry) [ "$status" -eq 0 ] && grep -Fxq backend-output "$cfg/list.out" ;;
		check) [ "$status" -eq 1 ] && grep -Fxq "kept: $list_root/held" "$cfg/list.out" ;;
	esac || { echo "FAIL: NUL listing must preserve $list_preview preview output"; fail=1; }
done
kill "$list_pid"; wait "$list_pid" 2>/dev/null || :
rm -rf "$list_root"

# A second run tests that the shipped age rule keeps freshly extracted files
# (birth and ctime stay current even when atime and mtime are backdated).
dir2=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
conf2=$cfg/conf2
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$shimdir" "$bindpoint" "$detachpoint" "$sockalias"' EXIT

sed "s#/tmp#$dir2#" "$here/tmpcleaner.conf" > "$conf2"
touch "$dir2/extracted.txt"
touch -d '13 hours ago' "$dir2/extracted.txt"

run_log=$(TMPCLEANER_CONF=$conf2 sh "$here/tmpcleaner" 2>&1 >/dev/null)
[ "$run_log" = 'tmpcleaner: removed 0 files and 0 directories' ] || {
	echo "FAIL: an unset TMPCLEANER_LIST should log only the usual summary"
	fail=1
}
status=0
mfail_log=$(TMPCLEANER_METRICS="$cfg/missing-dir/metrics.prom" TMPCLEANER_CONF=$conf2 sh "$here/tmpcleaner" 2>&1 >/dev/null) || status=$?
if [ "$status" -ne 0 ] || [ "$(printf '%s\n' "$mfail_log" | wc -l)" -ne 2 ] ||
	! printf '%s\n' "$mfail_log" | grep -Fxq 'tmpcleaner: removed 0 files and 0 directories' ||
	! printf '%s\n' "$mfail_log" | grep -Fq 'cannot write metrics'; then
	echo "FAIL: metrics write failure should keep exit status 0 and log one stderr line"
	fail=1
fi
for writefail in destination timestamp; do
	metric_target=$cfg/missing-dir/metrics.prom
	[ "$writefail" != timestamp ] || metric_target=$cfg/metrics.prom
	for cleanfail in '' CAT_SHIM_FAIL=1; do
		status=0
		mfail_log=$(shim env "${cleanfail:-CAT_SHIM_FAIL=}" "DATE_SHIM_FAIL=$([ "$writefail" != timestamp ] || printf 1)" \
			TMPCLEANER_METRICS=$metric_target TMPCLEANER_CONF=$conf2 sh "$here/tmpcleaner" 2>&1 >/dev/null) || status=$?
		expected_status=0
		[ -z "$cleanfail" ] || expected_status=1
		if [ "$status" -ne "$expected_status" ] ||
			[ "$(printf '%s\n' "$mfail_log" | grep -c 'tmpcleaner: cannot write metrics')" -ne 1 ]; then
			echo "FAIL: metrics failure must warn once and preserve original status ($writefail $cleanfail)"
			fail=1
		fi
	done
done

[ -e "$dir2/extracted.txt" ] || { echo "FAIL: extracted.txt should be kept"; fail=1; }

# The three-way config upgrade that decides whether a reinstall keeps or replaces
# an admin's exclusions.
confdir=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$confdir" "$shimdir" "$bindpoint" "$detachpoint" "$sockalias"' EXIT
confsource=$confdir/source
confdest="$confdir/stage safe"
confpath="$confdest/target [safe]"
mkdir "$confsource"
cp "$here/Makefile" "$here/tmpcleaner.conf" "$confsource"

make -s -C "$confsource" install-conf DESTDIR="$confdest" CONFDIR='/target [safe]' >/dev/null
cmp -s "$confpath/tmpcleaner.conf" "$here/tmpcleaner.conf" || {
	echo "FAIL: initial install should create tmpcleaner.conf matching shipped file"
	fail=1
}
cmp -s "$confpath/tmpcleaner.conf.default" "$here/tmpcleaner.conf" || {
	echo "FAIL: initial install should create tmpcleaner.conf.default matching shipped file"
	fail=1
}

sed '$d' "$here/tmpcleaner.conf" > "$confpath/tmpcleaner.conf"
cp "$confpath/tmpcleaner.conf" "$confpath/tmpcleaner.conf.default"
make -s -C "$confsource" install-conf DESTDIR="$confdest" CONFDIR='/target [safe]' >/dev/null
cmp -s "$confpath/tmpcleaner.conf" "$here/tmpcleaner.conf" || {
	echo "FAIL: unedited upgrade should update tmpcleaner.conf to shipped file"
	fail=1
}
[ ! -e "$confpath/tmpcleaner.conf.new" ] || {
	echo "FAIL: unedited upgrade should not create tmpcleaner.conf.new"
	fail=1
}

printf 'x /tmp/local-rule\n' >> "$confpath/tmpcleaner.conf"
make -s -C "$confsource" install-conf DESTDIR="$confdest" CONFDIR='/target [safe]' >/dev/null
grep -Fxq 'x /tmp/local-rule' "$confpath/tmpcleaner.conf" || {
	echo "FAIL: local rule should survive reinstall"
	fail=1
}
cmp -s "$confpath/tmpcleaner.conf.new" "$here/tmpcleaner.conf" || {
	echo "FAIL: edited reinstall should create tmpcleaner.conf.new matching shipped file"
	fail=1
}
[ -z "$(find "$confsource" -mindepth 1 ! -name Makefile ! -name tmpcleaner.conf -print -quit)" ] || {
	echo "FAIL: config install should not create files in the source directory"
	fail=1
}
rm -rf "$confdir"

# Staged install (package build): honors DESTDIR, PREFIX and UNITDIR, rewrites
# ExecStart in the installed unit, and never invokes systemctl.
staged=$(mktemp -d /tmp/tmpcleaner-test.XXXXXX)
trap 'kill $pids 2>/dev/null || :; rm -rf "$dir" "$cfg" "$dir2" "$staged" "$shimdir" "$bindpoint" "$detachpoint" "$sockalias"' EXIT
staged_dest="$staged/root safe"
staged_units="/usr/lib/systemd units"
mkdir "$staged/fakes"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/systemctl.log"\n' "$staged" > "$staged/fakes/systemctl"
chmod +x "$staged/fakes/systemctl"
PATH="$staged/fakes:$PATH" make -s -C "$here" install DESTDIR="$staged_dest" PREFIX=/usr UNITDIR="$staged_units" >/dev/null
[ -x "$staged_dest/usr/bin/tmpcleaner" ] || {
	echo "FAIL: staged install should install executable /usr/bin/tmpcleaner"
	fail=1
}
if ! grep -Fxq 'ExecStart="/usr/bin/tmpcleaner"' "$staged_dest$staged_units/tmpcleaner.service" ||
	grep -Fq '/usr/local' "$staged_dest$staged_units/tmpcleaner.service"; then
	echo "FAIL: staged install should rewrite ExecStart to /usr/bin/tmpcleaner"
	fail=1
fi
[ -f "$staged_dest$staged_units/tmpcleaner.timer" ] || {
	echo "FAIL: staged install should install tmpcleaner.timer"
	fail=1
}
[ -f "$staged_dest/etc/tmpcleaner/tmpcleaner.conf" ] || {
	echo "FAIL: staged install should install /etc/tmpcleaner/tmpcleaner.conf"
	fail=1
}
[ ! -e "$staged/systemctl.log" ] || {
	echo "FAIL: staged install must not call systemctl"
	fail=1
}
PATH="$staged/fakes:$PATH" make -s -C "$here" uninstall DESTDIR="$staged_dest" PREFIX=/usr UNITDIR="$staged_units" >/dev/null
if [ -e "$staged_dest/usr/bin/tmpcleaner" ] ||
	[ -e "$staged_dest$staged_units/tmpcleaner.service" ] ||
	[ -e "$staged_dest$staged_units/tmpcleaner.timer" ] ||
	[ -e "$staged_dest/etc/tmpcleaner" ]; then
	echo "FAIL: staged uninstall should remove binary, units, and CONFDIR"
	fail=1
fi
[ ! -e "$staged/systemctl.log" ] || {
	echo "FAIL: staged uninstall must not call systemctl"
	fail=1
}

# Spaced uninstall paths stay single operands. Run from an owned directory so
# even the old split relative operands can only reach disposable fixtures.
for uninstall_case in confdir destdir; do
	uninstall_root=$(mktemp -d "$cfg/uninstall.XXXXXX")
	uninstall_work=$uninstall_root/work
	if [ "$uninstall_case" = confdir ]; then
		uninstall_dest=$uninstall_root/stage
		uninstall_conf='/target safe' uninstall_units='/units safe' uninstall_bin='/bin safe'
		uninstall_prefix=$uninstall_dest/target
	else
		uninstall_dest="$uninstall_root/stage safe"
		uninstall_conf=/target uninstall_units=/units uninstall_bin=/bin
		uninstall_prefix=$uninstall_root/stage
	fi
	mkdir -p "$uninstall_dest$uninstall_conf" "$uninstall_dest$uninstall_units" "$uninstall_dest$uninstall_bin" \
		"$uninstall_prefix" "$uninstall_work/safe/target" "$uninstall_work/safe/units" "$uninstall_work/safe/bin" "$uninstall_root/shim"
	touch "$uninstall_dest$uninstall_conf/real.conf" "$uninstall_dest$uninstall_units/tmpcleaner.service" \
		"$uninstall_dest$uninstall_units/tmpcleaner.timer" "$uninstall_dest$uninstall_bin/tmpcleaner" \
		"$uninstall_prefix/unrelated" "$uninstall_work/safe/unrelated" "$uninstall_work/safe/target/unrelated" \
		"$uninstall_work/safe/units/tmpcleaner.service" "$uninstall_work/safe/units/tmpcleaner.timer" "$uninstall_work/safe/bin/tmpcleaner"
	cat > "$uninstall_root/shim/systemctl" <<'SHIM'
#!/bin/sh
: > "$UNINSTALL_SYSTEMCTL_MARKER"
exit 1
SHIM
	chmod +x "$uninstall_root/shim/systemctl"
	status=0
	(cd "$uninstall_work" && PATH="$uninstall_root/shim:$PATH" UNINSTALL_SYSTEMCTL_MARKER=$uninstall_root/systemctl.called \
		make -s -f "$here/Makefile" uninstall DESTDIR="$uninstall_dest" CONFDIR="$uninstall_conf" \
		UNITDIR="$uninstall_units" BINDIR="$uninstall_bin") > "$uninstall_root/log" 2>&1 || status=$?
	if [ "$status" -ne 0 ] || [ -e "$uninstall_dest$uninstall_conf" ] ||
		[ -e "$uninstall_dest$uninstall_units/tmpcleaner.service" ] || [ -e "$uninstall_dest$uninstall_units/tmpcleaner.timer" ] ||
		[ -e "$uninstall_dest$uninstall_bin/tmpcleaner" ] || [ -e "$uninstall_root/systemctl.called" ] ||
		[ ! -e "$uninstall_prefix/unrelated" ] || [ ! -e "$uninstall_work/safe/unrelated" ] ||
		[ ! -e "$uninstall_work/safe/target/unrelated" ] || [ ! -e "$uninstall_work/safe/units/tmpcleaner.service" ] ||
		[ ! -e "$uninstall_work/safe/units/tmpcleaner.timer" ] || [ ! -e "$uninstall_work/safe/bin/tmpcleaner" ]; then
		echo "FAIL: staged uninstall must preserve path boundaries and skip systemctl ($uninstall_case)"
		fail=1
	fi
	rm -rf "$uninstall_root"
done

PATH="$staged/fakes:$PATH" make -s -C "$here" install ENABLE_TIMER=0 \
	DESTDIR="$staged_dest" PREFIX=/usr UNITDIR="$staged_units" >/dev/null
if [ ! -x "$staged_dest/usr/bin/tmpcleaner" ] || [ ! -f "$staged_dest$staged_units/tmpcleaner.service" ] ||
	[ ! -f "$staged_dest$staged_units/tmpcleaner.timer" ] || [ ! -f "$staged_dest/etc/tmpcleaner/tmpcleaner.conf" ] ||
	[ -e "$staged/systemctl.log" ]; then
	echo 'FAIL: staged install with ENABLE_TIMER=0 must install files without service actions'
	fail=1
fi
mkdir "$staged_dest/etc/tmpcleaner/local dir"
printf 'local\000bytes\n' > "$staged_dest/etc/tmpcleaner/local dir/notes"
printf 'pending defaults\n' > "$staged_dest/etc/tmpcleaner/tmpcleaner.conf.new"
cp -a "$staged_dest/etc/tmpcleaner" "$staged/config.expected"
PATH="$staged/fakes:$PATH" make -s -C "$here" uninstall KEEP_CONFIG=1 \
	DESTDIR="$staged_dest" PREFIX=/usr UNITDIR="$staged_units" >/dev/null
if ! diff -r "$staged/config.expected" "$staged_dest/etc/tmpcleaner" >/dev/null ||
	[ -e "$staged_dest/usr/bin/tmpcleaner" ] || [ -e "$staged_dest$staged_units/tmpcleaner.service" ] ||
	[ -e "$staged_dest$staged_units/tmpcleaner.timer" ] || [ -e "$staged/systemctl.log" ]; then
	echo 'FAIL: staged KEEP_CONFIG=1 must preserve the whole config tree and remove binary/units without service actions'
	fail=1
fi

# Invalid executable paths fail generation before installing binary or units.
for bad_bin in "$staged/bad'quote" "$staged/bad\"quote" "$staged/bad\\slash" \
	"$staged/bad${tab}tab" "$staged/bad$(printf '\001')control" "$staged/bad$(printf '\177')delete" \
	"$staged/bad${nl}newline" relative/bin; do
	status=0
	PATH="$staged/fakes:$PATH" make -s -C "$here" install DESTDIR="$staged/refused" BINDIR="$bad_bin" \
		CONFDIR=/conf UNITDIR=/units > "$staged/refused.log" 2>&1 || status=$?
	if [ "$status" -eq 0 ] || [ -e "$staged/refused$bad_bin/tmpcleaner" ] ||
		[ -e "$staged/refused/units/tmpcleaner.service" ] || [ -e "$staged/systemctl.log" ] ||
		! grep -Eq 'BINDIR must be absolute|paths cannot contain newlines' "$staged/refused.log"; then
		echo 'FAIL: unsupported executable path must fail clearly before binary/unit installation'
		fail=1
	fi
done
mkdir "$staged/failing-tools"
printf '#!/bin/sh\nexit 17\n' > "$staged/failing-tools/awk"
chmod +x "$staged/failing-tools/awk"
status=0
PATH="$staged/failing-tools:$staged/fakes:$PATH" make -s -C "$here" install DESTDIR="$staged/generator-failed" \
	BINDIR=/bin CONFDIR=/conf UNITDIR=/units > "$staged/generator-failed.log" 2>&1 || status=$?
if [ "$status" -eq 0 ] || [ -e "$staged/generator-failed/bin/tmpcleaner" ] ||
	[ -e "$staged/generator-failed/units/tmpcleaner.service" ] || [ -e "$staged/systemctl.log" ]; then
	echo 'FAIL: failed unit generator must stop installation before binary/units and service actions'
	fail=1
fi

# Unstaged install/uninstall (empty DESTDIR): invokes systemctl in order and
# honors custom PREFIX, BINDIR, CONFDIR, and UNITDIR without touching source files.
custom_suffix=" '\"\\ %n \$HOME &|;${tab}$(printf '\001')"
custom_bin="$staged/bin %n \$HOME &|;"
custom_conf=$staged/conf$custom_suffix
custom_units=$staged/units$custom_suffix
# GNU make command-line values need each literal dollar doubled.
make_bin=$(printf '%s' "$custom_bin" | sed 's/\$/$$/g')
make_conf=$(printf '%s' "$custom_conf" | sed 's/\$/$$/g')
make_units=$(printf '%s' "$custom_units" | sed 's/\$/$$/g')
PATH="$staged/fakes:$PATH" make -s -C "$here" install \
	PREFIX="$staged/prefix" \
	BINDIR="$make_bin" \
	CONFDIR="$make_conf" \
	UNITDIR="$make_units" >/dev/null
[ -x "$custom_bin/tmpcleaner" ] || {
	echo "FAIL: unstaged install should install executable in custom BINDIR"
	fail=1
}
if command -v systemd-analyze >/dev/null; then
	if ! systemd-analyze verify --man=no "$custom_units/tmpcleaner.service" > "$staged/verify.log" 2>&1; then
		echo 'FAIL: generated service must resolve the literal installed executable'
		cat "$staged/verify.log"
		fail=1
	fi
else
	echo 'SKIP: generated service verification (systemd-analyze unavailable)'
fi
grep -v '^ExecStart=' "$here/tmpcleaner.service" > "$staged/unit.expected"
grep -v '^ExecStart=' "$custom_units/tmpcleaner.service" > "$staged/unit.actual"
if ! cmp -s "$staged/unit.expected" "$staged/unit.actual" ||
	[ "$(stat -c %a "$custom_units/tmpcleaner.service")" != 644 ]; then
	echo 'FAIL: service generation must preserve other lines and installation mode'
	fail=1
fi
[ -f "$custom_units/tmpcleaner.timer" ] || {
	echo "FAIL: unstaged install should install tmpcleaner.timer in custom UNITDIR"
	fail=1
}
[ -f "$custom_conf/tmpcleaner.conf" ] || {
	echo "FAIL: unstaged install should install tmpcleaner.conf in custom CONFDIR"
	fail=1
}
if [ ! -f "$staged/systemctl.log" ] ||
	[ "$(cat "$staged/systemctl.log")" != "$(printf 'daemon-reload\nenable --now tmpcleaner.timer')" ]; then
	echo "FAIL: unstaged install should run daemon-reload then enable --now tmpcleaner.timer"
	fail=1
fi
: > "$staged/systemctl.log"
PATH="$staged/fakes:$PATH" make -s -C "$here" install ENABLE_TIMER=1 \
	BINDIR="$make_bin" CONFDIR="$make_conf" UNITDIR="$make_units" >/dev/null
if [ "$(cat "$staged/systemctl.log")" != "$(printf 'daemon-reload\nenable --now tmpcleaner.timer')" ]; then
	echo 'FAIL: ENABLE_TIMER=1 must retain default activation calls'
	fail=1
fi
printf 'x /tmp/local-install-rule\n' >> "$custom_conf/tmpcleaner.conf"
cp "$custom_conf/tmpcleaner.conf" "$staged/edited.conf"
: > "$staged/systemctl.log"
PATH="$staged/fakes:$PATH" make -s -C "$here" install ENABLE_TIMER=0 \
	BINDIR="$make_bin" CONFDIR="$make_conf" UNITDIR="$make_units" >/dev/null
if [ "$(cat "$staged/systemctl.log")" != daemon-reload ] ||
	[ ! -x "$custom_bin/tmpcleaner" ] || [ ! -f "$custom_units/tmpcleaner.service" ] || [ ! -f "$custom_units/tmpcleaner.timer" ] ||
	! cmp -s "$staged/edited.conf" "$custom_conf/tmpcleaner.conf" ||
	! cmp -s "$here/tmpcleaner.conf" "$custom_conf/tmpcleaner.conf.new"; then
	echo 'FAIL: ENABLE_TIMER=0 must install files, preserve edited config and only reload systemd'
	fail=1
fi
for invalid_timer in '' 2 yes '0 1' '1 0' 00; do
	: > "$staged/systemctl.log"
	status=0
	PATH="$staged/fakes:$PATH" make -s -C "$here" install "ENABLE_TIMER=$invalid_timer" \
		BINDIR="$make_bin" CONFDIR="$make_conf" UNITDIR="$make_units" > "$staged/invalid-timer.log" 2>&1 || status=$?
	if [ "$status" -eq 0 ] || [ -s "$staged/systemctl.log" ] ||
		! grep -Fq 'ENABLE_TIMER must be 0 or 1' "$staged/invalid-timer.log"; then
		echo 'FAIL: invalid ENABLE_TIMER must fail before service actions'
		fail=1
	fi
done
mkdir "$custom_conf/local dir"
printf 'local\000bytes\n' > "$custom_conf/local dir/notes"
cp -a "$custom_conf" "$staged/custom-config.expected"
for invalid_keep in '' 2 yes '0 1' '1 0' 00; do
	: > "$staged/systemctl.log"
	status=0
	PATH="$staged/fakes:$PATH" make -s -C "$here" uninstall "KEEP_CONFIG=$invalid_keep" \
		BINDIR="$make_bin" CONFDIR="$make_conf" UNITDIR="$make_units" > "$staged/invalid-keep.log" 2>&1 || status=$?
	if [ "$status" -eq 0 ] || [ -s "$staged/systemctl.log" ] ||
		[ ! -x "$custom_bin/tmpcleaner" ] || [ ! -f "$custom_units/tmpcleaner.service" ] ||
		[ ! -f "$custom_units/tmpcleaner.timer" ] || ! diff -r "$staged/custom-config.expected" "$custom_conf" >/dev/null ||
		! grep -Fq 'KEEP_CONFIG must be 0 or 1' "$staged/invalid-keep.log"; then
		echo 'FAIL: invalid KEEP_CONFIG must fail before any removal or service action'
		fail=1
	fi
done
: > "$staged/systemctl.log"
PATH="$staged/fakes:$PATH" make -s -C "$here" uninstall KEEP_CONFIG=1 \
	BINDIR="$make_bin" CONFDIR="$make_conf" UNITDIR="$make_units" >/dev/null
if [ -e "$custom_bin/tmpcleaner" ] || [ -e "$custom_units/tmpcleaner.service" ] ||
	[ -e "$custom_units/tmpcleaner.timer" ] || ! diff -r "$staged/custom-config.expected" "$custom_conf" >/dev/null ||
	[ "$(cat "$staged/systemctl.log")" != "$(printf 'disable --now tmpcleaner.timer\ndaemon-reload')" ]; then
	echo 'FAIL: unstaged KEEP_CONFIG=1 must preserve the config tree while removing binary/units and stopping the timer'
	fail=1
fi
: > "$staged/systemctl.log"
PATH="$staged/fakes:$PATH" make -s -C "$here" uninstall \
	ENABLE_TIMER=0 KEEP_CONFIG=0 \
	PREFIX="$staged/prefix" \
	BINDIR="$make_bin" \
	CONFDIR="$make_conf" \
	UNITDIR="$make_units" >/dev/null
if [ -e "$custom_bin/tmpcleaner" ] ||
	[ -e "$custom_units/tmpcleaner.service" ] ||
	[ -e "$custom_units/tmpcleaner.timer" ] ||
	[ -e "$custom_conf" ]; then
	echo "FAIL: unstaged uninstall should remove binary, units, and custom CONFDIR"
	fail=1
fi
if [ ! -f "$staged/systemctl.log" ] ||
	[ "$(cat "$staged/systemctl.log")" != "$(printf 'disable --now tmpcleaner.timer\ndaemon-reload')" ]; then
	echo "FAIL: unstaged uninstall should run disable --now tmpcleaner.timer then daemon-reload"
	fail=1
fi
grep -Fxq 'ExecStart=/usr/local/bin/tmpcleaner' "$here/tmpcleaner.service" || {
	echo "FAIL: install/uninstall must leave source tmpcleaner.service unchanged"
	fail=1
}
rm -rf "$staged"

# Packaging metadata is checked only after successful generation, and failed
# regeneration leaves the last complete file and its mode intact.
srcinfo_root=$(mktemp -d "$cfg/srcinfo.XXXXXX")
mkdir "$srcinfo_root/tools"
printf 'complete metadata\n' > "$srcinfo_root/original"
cp "$srcinfo_root/original" "$srcinfo_root/.SRCINFO"
chmod 644 "$srcinfo_root/.SRCINFO"
cat > "$srcinfo_root/tools/makepkg" <<'SHIM'
#!/bin/sh
[ "$*" = --printsrcinfo ] || exit 64
case "$SRCINFO_CASE" in
	match|match-fail) cat original ;;
	stale) printf 'new complete metadata\n' ;;
	partial-fail) printf 'partial' ;;
esac
case "$SRCINFO_CASE" in *-fail) exit 42 ;; esac
SHIM
chmod +x "$srcinfo_root/tools/makepkg"
for srcinfo_case in match stale match-fail partial-fail; do
	for srcinfo_target in check-srcinfo srcinfo; do
		cp "$srcinfo_root/original" "$srcinfo_root/.SRCINFO"
		status=0
		(cd "$srcinfo_root" && PATH="$srcinfo_root/tools:$PATH" SRCINFO_CASE=$srcinfo_case \
			make -s -f "$here/Makefile" "$srcinfo_target") > "$srcinfo_root/log" 2>&1 || status=$?
		if [ "$srcinfo_case" = match ] || { [ "$srcinfo_case" = stale ] && [ "$srcinfo_target" = srcinfo ]; }; then
			[ "$status" -eq 0 ] || { echo "FAIL: successful metadata generation ($srcinfo_case $srcinfo_target)"; fail=1; }
		else
			[ "$status" -ne 0 ] || { echo "FAIL: metadata check/generator failure was hidden ($srcinfo_case $srcinfo_target)"; fail=1; }
		fi
		if [ "$srcinfo_case" = stale ] && [ "$srcinfo_target" = srcinfo ]; then
			printf 'new complete metadata\n' > "$srcinfo_root/expected"
		else
			cp "$srcinfo_root/original" "$srcinfo_root/expected"
		fi
		if ! cmp -s "$srcinfo_root/expected" "$srcinfo_root/.SRCINFO" ||
			[ "$(stat -c %a "$srcinfo_root/.SRCINFO")" != 644 ] ||
			[ -n "$(find "$srcinfo_root" -maxdepth 1 -name '.SRCINFO.*' -print -quit)" ]; then
			echo "FAIL: metadata contents/mode or temporary-file cleanup ($srcinfo_case $srcinfo_target)"
			fail=1
		fi
		if [ "$srcinfo_case:$srcinfo_target" = stale:check-srcinfo ] &&
			! grep -Fq '.SRCINFO is stale; run make srcinfo' "$srcinfo_root/log"; then
			echo 'FAIL: stale metadata check must retain the update diagnostic'
			fail=1
		fi
	done
done
rm -rf "$srcinfo_root"

[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
