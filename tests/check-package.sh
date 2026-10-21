#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Hermetic package-time smoke checks for makepkg check(): every case exits
# before tmpcleaner reads /proc, df or systemd-tmpfiles, so nothing here
# depends on git, network, root, the user's home or live system state.
# The full suite is tests/test.sh (make test).
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
home=$(mktemp -d) || exit 1
trap 'rm -rf "$home"' EXIT
fail=0

run() {
	env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$home" LC_ALL=C "$@" sh "$here/tmpcleaner" "$want_arg" > "$home/out" 2>&1
}
expect() {
	want_rc=$1 want_text=$2 want_arg=$3
	shift 3
	run "$@"
	rc=$?
	if [ "$rc" -ne "$want_rc" ] || ! grep -qF -- "$want_text" "$home/out"; then
		echo "FAIL: tmpcleaner $want_arg ($*): rc $rc, want $want_rc and '$want_text'" >&2
		sed 's/^/  /' "$home/out" >&2
		fail=1
	fi
}

sh -n "$here/tmpcleaner" || { echo "FAIL: tmpcleaner does not parse" >&2; fail=1; }
expect 0 'Usage: tmpcleaner' --help
expect 2 'unsupported argument: --bogus' --bogus
expect 1 "cannot read $home/missing.conf" --print-rules TMPCLEANER_CONF="$home/missing.conf"
expect 1 'invalid TMPCLEANER_AGE: 6 hours' --print-rules TMPCLEANER_CONF="$here/tmpcleaner.conf" TMPCLEANER_AGE='6 hours'
expect 1 'invalid TMPCLEANER_FULL_PERCENT: 101' --print-rules TMPCLEANER_CONF="$here/tmpcleaner.conf" TMPCLEANER_FULL_PERCENT=101

[ "$fail" -eq 0 ] && echo PASS
exit "$fail"
