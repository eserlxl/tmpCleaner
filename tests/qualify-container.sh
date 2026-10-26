#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Qualify the installed tmpCleaner service, timer, journal output, metrics and
# source install/uninstall/reinstall lifecycle in a disposable systemd container.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
image=tmpcleaner-qualify:latest
cid=

cleanup() {
	[ -z "$cid" ] || docker rm -f "$cid" >/dev/null 2>&1 || :
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if ! docker info >/dev/null 2>&1; then
	echo 'SKIP: docker unavailable'
	exit 77
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
	docker build --network host -t "$image" - <<'EOF'
FROM archlinux:latest
RUN pacman -Sy --noconfirm --needed make
EOF
fi

cid=$(docker run -d \
	--network none \
	--cgroupns=private \
	--security-opt writable-cgroups=true \
	-e container=docker \
	--tmpfs /run \
	--tmpfs /run/lock \
	--tmpfs /tmp \
	-v "$here:/src:ro" \
	"$image" /usr/lib/systemd/systemd)

booted=0
i=0
while [ "$i" -lt 60 ]; do
	state=$(docker exec "$cid" systemctl is-system-running 2>/dev/null || :)
	case "$state" in
		running|degraded)
			booted=1
			break
			;;
	esac
	i=$((i + 1))
	sleep 1
done

if [ "$booted" -ne 1 ]; then
	echo "FAIL boot: systemctl is-system-running remained '${state:-unknown}'"
	exit 1
fi

docker exec -i "$cid" sh -eu <<'IN_CONTAINER'
fail=0
pass() {
	printf 'PASS %s\n' "$1"
}
fail_check() {
	printf 'FAIL %s: %s\n' "$1" "$2"
	fail=1
}

cp -R /src /build
cd /build

# (1) make install with default variables installs the binary, units and config
# and leaves tmpcleaner.timer disabled.
if ! out=$(make install 2>&1); then
	fail_check "make install" "$out"
elif [ ! -x /usr/local/bin/tmpcleaner ]; then
	fail_check "make install" "/usr/local/bin/tmpcleaner not installed"
elif [ ! -f /etc/systemd/system/tmpcleaner.service ] || [ ! -f /etc/systemd/system/tmpcleaner.timer ]; then
	fail_check "make install" "systemd units missing under /etc/systemd/system"
elif [ ! -f /etc/tmpcleaner/tmpcleaner.conf ] || [ ! -f /etc/tmpcleaner/tmpcleaner.conf.default ] || [ ! -d /etc/tmpcleaner/tmpcleaner.conf.d ]; then
	fail_check "make install" "configuration files missing under /etc/tmpcleaner"
else
	enabled=$(systemctl is-enabled tmpcleaner.timer 2>/dev/null || :)
	active=$(systemctl is-active tmpcleaner.timer 2>/dev/null || :)
	if [ "$enabled" != disabled ] || [ "$active" = active ]; then
		fail_check "make install" "tmpcleaner.timer state is enabled=$enabled active=$active"
	else
		pass "make install"
	fi
fi

# (2) tmpcleaner --dry-run exits 0.
if out=$(/usr/local/bin/tmpcleaner --dry-run 2>&1); then
	pass "tmpcleaner --dry-run"
else
	fail_check "tmpcleaner --dry-run" "${out:-non-zero exit}"
fi

# (3) Service sandbox, age, protections, journal summary/JSON record and metrics.
# A JSON run prints no prose summary, so a first run without it supplies the
# prose line the journal check below expects.
mkdir -p /etc/systemd/system/tmpcleaner.service.d /var/lib/tmpcleaner-qualify
cat > /etc/systemd/system/tmpcleaner.service.d/qualify.conf <<'DROPIN'
[Service]
Environment=TMPCLEANER_AGE=2s
DROPIN
systemctl daemon-reload
if ! out=$(systemctl start tmpcleaner.service 2>&1); then
	svc_err="initial systemctl start failed: $out"
else
	svc_err=
fi

cat > /etc/systemd/system/tmpcleaner.service.d/qualify.conf <<'DROPIN'
[Service]
Environment=TMPCLEANER_AGE=2s TMPCLEANER_SUMMARY=json TMPCLEANER_METRICS=/var/lib/tmpcleaner-qualify/tmpcleaner.prom
ReadWritePaths=/var/lib/tmpcleaner-qualify
DROPIN
systemctl daemon-reload

rm -rf /tmp/qualify-unprotected /tmp/qualify-open /tmp/qualify-keep /tmp/krb5cc_qualify /tmp/qualify-fresh
printf 'remove-me\n' > /tmp/qualify-unprotected
printf 'held-open\n' > /tmp/qualify-open
sleep 300 < /tmp/qualify-open >/dev/null 2>&1 &
holder_pid=$!
mkdir -p /tmp/qualify-keep
: > /tmp/qualify-keep/.tmpcleaner-keep
printf 'kept-by-marker\n' > /tmp/qualify-keep/file
printf 'kerberos-cache\n' > /tmp/krb5cc_qualify

sleep 3
printf 'fresh\n' > /tmp/qualify-fresh

if [ -n "$svc_err" ]; then
	:
elif ! out=$(systemctl start tmpcleaner.service 2>&1); then
	svc_err="systemctl start failed: $out"
elif [ -e /tmp/qualify-unprotected ]; then
	svc_err="/tmp/qualify-unprotected was not removed"
elif [ ! -f /tmp/qualify-open ]; then
	svc_err="/tmp/qualify-open held open by sleep was removed"
elif [ ! -f /tmp/qualify-keep/.tmpcleaner-keep ] || [ ! -f /tmp/qualify-keep/file ]; then
	svc_err="/tmp/qualify-keep fixture was removed"
elif [ ! -f /tmp/krb5cc_qualify ]; then
	svc_err="/tmp/krb5cc_qualify was removed"
elif [ ! -f /tmp/qualify-fresh ]; then
	svc_err="/tmp/qualify-fresh was removed"
elif [ ! -f /var/lib/tmpcleaner-qualify/tmpcleaner.prom ]; then
	svc_err="metrics file /var/lib/tmpcleaner-qualify/tmpcleaner.prom was not written"
elif ! grep -qx 'tmpcleaner_last_exit_status 0' /var/lib/tmpcleaner-qualify/tmpcleaner.prom; then
	svc_err="metrics file missing 'tmpcleaner_last_exit_status 0'"
else
	journalctl --sync >/dev/null 2>&1 || :
	logs=$(journalctl -u tmpcleaner.service --no-pager -o cat 2>&1 || :)
	if ! printf '%s\n' "$logs" | grep -Eq '^tmpcleaner: [0-9]+ files and [0-9]+ directories disappeared during the run$'; then
		svc_err="missing prose summary line in journal"
	else
		json_count=$(printf '%s\n' "$logs" | grep -c '^{"tmpcleaner":"run","exit_status":0,"failure":null,"removed_files":[1-9][0-9]*,"removed_directories":[0-9][0-9]*,"removed_bytes":[1-9][0-9]*,"counts_available":true}$' || :)
		if [ "$json_count" -ne 1 ]; then
			svc_err="expected 1 JSON completion record with exit_status 0 in journal (got $json_count)"
		fi
	fi
fi

kill "$holder_pid" 2>/dev/null || :
wait "$holder_pid" 2>/dev/null || :
rm -rf /tmp/qualify-unprotected /tmp/qualify-open /tmp/qualify-keep /tmp/krb5cc_qualify /tmp/qualify-fresh
rm -rf /etc/systemd/system/tmpcleaner.service.d /var/lib/tmpcleaner-qualify
systemctl daemon-reload

if [ -z "$svc_err" ]; then
	pass "tmpcleaner.service run"
else
	fail_check "tmpcleaner.service run" "$svc_err"
fi

# (4) systemctl enable --now tmpcleaner.timer enables it and lists a next elapse.
if ! out=$(systemctl enable --now tmpcleaner.timer 2>&1); then
	fail_check "tmpcleaner.timer" "$out"
else
	enabled=$(systemctl is-enabled tmpcleaner.timer 2>/dev/null || :)
	timers=$(systemctl list-timers --all --no-pager tmpcleaner.timer 2>&1 || :)
	if [ "$enabled" != enabled ]; then
		fail_check "tmpcleaner.timer" "is-enabled reported '$enabled'"
	elif ! printf '%s\n' "$timers" | grep -q 'tmpcleaner\.timer' || printf '%s\n' "$timers" | grep 'tmpcleaner\.timer' | grep -q '^n/a '; then
		fail_check "tmpcleaner.timer" "not listed with a next elapse: $timers"
	else
		pass "tmpcleaner.timer"
	fi
fi

# (5) make uninstall removes .default and keeps config, make install over an unedited config leaves
# no tmpcleaner.conf.new, make install preserves edited config and writes
# tmpcleaner.conf.new, and make uninstall KEEP_CONFIG=0 removes config.
lifecycle_err=
if ! out=$(make uninstall 2>&1); then
	lifecycle_err="make uninstall failed: $out"
elif [ -e /usr/local/bin/tmpcleaner ] || [ -e /etc/systemd/system/tmpcleaner.service ] || [ -e /etc/systemd/system/tmpcleaner.timer ]; then
	lifecycle_err="make uninstall left binary or units behind"
elif [ ! -f /etc/tmpcleaner/tmpcleaner.conf ]; then
	lifecycle_err="make uninstall removed /etc/tmpcleaner/tmpcleaner.conf"
elif [ -e /etc/tmpcleaner/tmpcleaner.conf.default ]; then
	lifecycle_err="make uninstall left /etc/tmpcleaner/tmpcleaner.conf.default behind"
elif ! out=$(make install 2>&1); then
	lifecycle_err="unedited reinstall failed: $out"
elif [ -e /etc/tmpcleaner/tmpcleaner.conf.new ]; then
	lifecycle_err="unedited reinstall created /etc/tmpcleaner/tmpcleaner.conf.new"
else
	printf '\nx /tmp/qualify-local-keep\n' >> /etc/tmpcleaner/tmpcleaner.conf
	if ! out=$(make install 2>&1); then
		lifecycle_err="reinstall failed: $out"
	elif ! grep -qx 'x /tmp/qualify-local-keep' /etc/tmpcleaner/tmpcleaner.conf; then
		lifecycle_err="reinstall overwrote edited /etc/tmpcleaner/tmpcleaner.conf"
	elif [ ! -f /etc/tmpcleaner/tmpcleaner.conf.new ] || [ "$(sha256sum < /build/tmpcleaner.conf)" != "$(sha256sum < /etc/tmpcleaner/tmpcleaner.conf.new)" ]; then
		lifecycle_err="reinstall did not write /etc/tmpcleaner/tmpcleaner.conf.new matching shipped config"
	elif ! out=$(make uninstall KEEP_CONFIG=0 2>&1); then
		lifecycle_err="make uninstall KEEP_CONFIG=0 failed: $out"
	elif [ -e /usr/local/bin/tmpcleaner ] || [ -e /etc/systemd/system/tmpcleaner.service ] || [ -e /etc/systemd/system/tmpcleaner.timer ] || [ -e /etc/tmpcleaner ]; then
		lifecycle_err="make uninstall KEEP_CONFIG=0 left installed files or /etc/tmpcleaner behind"
	fi
fi

if [ -z "$lifecycle_err" ]; then
	pass "install/uninstall lifecycle"
else
	fail_check "install/uninstall lifecycle" "$lifecycle_err"
fi

exit "$fail"
IN_CONTAINER
