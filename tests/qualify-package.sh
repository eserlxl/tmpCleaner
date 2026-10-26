#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Qualify the AUR package lifecycle (build from working tree via aurgen,
# install, service run, config-preserving reinstall, removal with .pacsave,
# and migration from a source install)
# in a disposable systemd container.
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

if ! command -v aurgen >/dev/null 2>&1; then
	echo 'SKIP: aurgen unavailable'
	exit 77
fi

if ! docker info >/dev/null 2>&1; then
	echo 'SKIP: docker unavailable'
	exit 77
fi

cd "$here"
if ! build_out=$(aurgen --build-only local 2>&1); then
	case "$build_out" in
		*"Missing dependencies"*|*"Failed to install missing dependencies"*)
			printf 'FAIL aurgen build: makepkg would need to install build dependencies:\n%s\n' "$build_out" >&2
			exit 1
			;;
	esac
	printf 'FAIL aurgen build:\n%s\n' "$build_out" >&2
	exit 1
fi

pkgfile=
for candidate in $(cd "$here/aur" && makepkg --packagelist); do
	if [ -f "$candidate" ]; then
		pkgfile=$candidate
		break
	fi
done

if [ -z "$pkgfile" ]; then
	echo 'FAIL aurgen build: built package file not found via makepkg --packagelist in aur/' >&2
	exit 1
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
	-v "$pkgfile:/pkg/linux-tmpcleaner.pkg.tar:ro" \
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

pkg=/pkg/linux-tmpcleaner.pkg.tar

# (1) pacman -U --noconfirm installs /usr/bin/tmpcleaner,
# /usr/lib/systemd/system/tmpcleaner.service and .timer,
# /etc/tmpcleaner/tmpcleaner.conf and the license, the service's ExecStart
# names /usr/bin/tmpcleaner, tmpcleaner.timer is not enabled, and .default is absent.
if ! out=$(pacman -U --noconfirm "$pkg" 2>&1); then
	fail_check "pacman -U install" "$out"
elif [ ! -x /usr/bin/tmpcleaner ]; then
	fail_check "pacman -U install" "/usr/bin/tmpcleaner not installed"
elif [ ! -f /usr/lib/systemd/system/tmpcleaner.service ] || [ ! -f /usr/lib/systemd/system/tmpcleaner.timer ]; then
	fail_check "pacman -U install" "systemd units missing under /usr/lib/systemd/system"
elif [ ! -f /etc/tmpcleaner/tmpcleaner.conf ]; then
	fail_check "pacman -U install" "/etc/tmpcleaner/tmpcleaner.conf missing"
elif [ -e /etc/tmpcleaner/tmpcleaner.conf.default ] || pacman -Qlq linux-tmpcleaner 2>/dev/null | grep -Fxq '/etc/tmpcleaner/tmpcleaner.conf.default'; then
	fail_check "pacman -U install" "/etc/tmpcleaner/tmpcleaner.conf.default is present or packaged"
elif ! pacman -Qlq linux-tmpcleaner 2>/dev/null | grep -Eq '^/usr/share/licenses/linux-tmpcleaner/.+'; then
	fail_check "pacman -U install" "license missing under /usr/share/licenses/linux-tmpcleaner"
elif ! grep -Eq '^ExecStart="?/usr/bin/tmpcleaner"?$' /usr/lib/systemd/system/tmpcleaner.service; then
	fail_check "pacman -U install" "ExecStart in /usr/lib/systemd/system/tmpcleaner.service does not name /usr/bin/tmpcleaner"
else
	lic=$(pacman -Qlq linux-tmpcleaner | grep -E '^/usr/share/licenses/linux-tmpcleaner/.+' | head -n 1)
	enabled=$(systemctl is-enabled tmpcleaner.timer 2>/dev/null || :)
	active=$(systemctl is-active tmpcleaner.timer 2>/dev/null || :)
	if [ ! -f "$lic" ]; then
		fail_check "pacman -U install" "license file $lic missing on disk"
	elif [ "$enabled" = enabled ] || [ "$active" = active ]; then
		fail_check "pacman -U install" "tmpcleaner.timer state is enabled=$enabled active=$active"
	else
		pass "pacman -U install"
	fi
fi

# (2) tmpcleaner --dry-run exits 0 and systemctl start tmpcleaner.service succeeds.
if ! out=$(/usr/bin/tmpcleaner --dry-run 2>&1); then
	fail_check "dry-run and service start" "tmpcleaner --dry-run failed: ${out:-non-zero exit}"
elif ! out=$(systemctl start tmpcleaner.service 2>&1); then
	fail_check "dry-run and service start" "systemctl start tmpcleaner.service failed: $out"
else
	pass "dry-run and service start"
fi

# (3) After appending a local x rule to /etc/tmpcleaner/tmpcleaner.conf,
# reinstalling the same package with pacman -U --noconfirm keeps that rule.
printf '\nx /tmp/qualify-package-keep\n' >> /etc/tmpcleaner/tmpcleaner.conf
if ! out=$(pacman -U --noconfirm "$pkg" 2>&1); then
	fail_check "pacman -U reinstall keeps config" "$out"
elif ! grep -qx 'x /tmp/qualify-package-keep' /etc/tmpcleaner/tmpcleaner.conf; then
	fail_check "pacman -U reinstall keeps config" "reinstall overwrote edited /etc/tmpcleaner/tmpcleaner.conf"
else
	pass "pacman -U reinstall keeps config"
fi

# (4) pacman -R --noconfirm linux-tmpcleaner removes the binary and units and
# leaves the edited config as /etc/tmpcleaner/tmpcleaner.conf.pacsave.
if ! out=$(pacman -R --noconfirm linux-tmpcleaner 2>&1); then
	fail_check "pacman -R remove" "$out"
elif [ -e /usr/bin/tmpcleaner ] || [ -e /usr/lib/systemd/system/tmpcleaner.service ] || [ -e /usr/lib/systemd/system/tmpcleaner.timer ]; then
	fail_check "pacman -R remove" "binary or systemd units left behind after removal"
elif [ -e /etc/tmpcleaner/tmpcleaner.conf ]; then
	fail_check "pacman -R remove" "/etc/tmpcleaner/tmpcleaner.conf still present after removal"
elif [ ! -f /etc/tmpcleaner/tmpcleaner.conf.pacsave ]; then
	fail_check "pacman -R remove" "/etc/tmpcleaner/tmpcleaner.conf.pacsave was not written"
elif ! grep -qx 'x /tmp/qualify-package-keep' /etc/tmpcleaner/tmpcleaner.conf.pacsave; then
	fail_check "pacman -R remove" "/etc/tmpcleaner/tmpcleaner.conf.pacsave missing local rule"
else
	pass "pacman -R remove"
fi

# (5) A source install followed by default uninstall leaves an edited config
# that pacman -U --noconfirm preserves without filesystem conflicts.
cp -R /src /build
cd /build
if pacman -Q linux-tmpcleaner >/dev/null 2>&1; then
	fail_check "source install then package" "package still installed before source install"
elif ! out=$(make install 2>&1); then
	fail_check "source install then package" "make install failed: $out"
else
	printf '\nx /tmp/qualify-source-keep\n' >> /etc/tmpcleaner/tmpcleaner.conf
	if ! out=$(make uninstall 2>&1); then
		fail_check "source install then package" "make uninstall failed: $out"
	elif ! out=$(pacman -U --noconfirm "$pkg" 2>&1); then
		fail_check "source install then package" "$out"
	elif ! grep -qx 'x /tmp/qualify-source-keep' /etc/tmpcleaner/tmpcleaner.conf; then
		fail_check "source install then package" "package install overwrote source config's local rule"
	else
		pass "source install then package"
	fi
fi

exit "$fail"
IN_CONTAINER
