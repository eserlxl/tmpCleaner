#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Disposable-copy mutation driver for tmpcleaner's safety guards.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
tab=$(printf '\t')

cases() {
	cat <<'EOF'
in-use-open-file	/proc/[0-9]*/cwd /proc/[0-9]*/fd/*	/proc/[0-9]*/cwd	FAIL: printed rules should exclude the held file
in-use-cwd	/proc/[0-9]*/exe /proc/[0-9]*/cwd	/proc/[0-9]*/exe	FAIL: raw inventory must be unique sorted NUL records with exact held paths and no synthetic exclusions
marker-protection	-name .tmpcleaner-keep -type f "$@" -printf '%h\0'	-name .tmpcleaner-keep -type f "$@" -printf ''	FAIL: protection walk cleanup status or partial marker protection
x-rule-import	$1 ~ /^[xX][!-]*$/ {	$1 ~ /^$/ {	FAIL: --print-rules should import /tmp X rules from --cat-config
strict-scan-refusal	(status == 1 && ENVIRON["TMPCLEANER_REQUIRE_COMPLETE_SCAN"] == "1")) exit 1	(0 && status == 1 && ENVIRON["TMPCLEANER_REQUIRE_COMPLETE_SCAN"] == "1")) exit 1	FAIL: strict partial-walk cleanup must remove nothing and never invoke cleanup
stale-snapshot-refusal	if (scan_age > ENVIRON["LIMIT"] * 100) exit 1	if (0 && scan_age > ENVIRON["LIMIT"] * 100) exit 1	FAIL: stale in-use snapshot must refuse both cleanup output modes without calling the backend
tmpdir-owner-check	((path in path_uid) && id[4] == path_uid[path])	(path in path_uid)	FAIL: TMPDIR must not add protection for a directory owned by another UID
in-use-readdir-race	cmd = "find /tmp -ignore_readdir_race -xdev -printf \"%i %p\\0\" 2>/dev/null"	cmd = "find /tmp -xdev -printf \"%i %p\\0\" 2>/dev/null"	FAIL: find deletion races must not fail strict cleanup, mark the protection walk partial, or invalidate counts
EOF
}

selected() {
	candidate=$1
	shift
	[ "$#" -eq 0 ] && return 0
	for arg do
		[ "$arg" != "$candidate" ] || return 0
	done
	return 1
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cases > "$workdir/cases"

total=0
killed=0
survived=0
errors=0

for arg do
	found=0
	while IFS=$tab read -r name _ _ _; do
		[ -n "$name" ] || continue
		if [ "$name" = "$arg" ]; then
			found=1
			break
		fi
	done < "$workdir/cases"
	if [ "$found" -eq 0 ]; then
		echo "ERROR $arg: unknown mutation case"
		total=$((total + 1))
		errors=$((errors + 1))
	fi
done

(
	cd "$here" &&
	git ls-files -z | xargs -0 cp --parents -t "$workdir" --
)
cp -- "$workdir/tmpcleaner" "$workdir/tmpcleaner.orig"

control_ran=0

while IFS=$tab read -r name old new expect; do
	[ -n "$name" ] || continue
	selected "$name" "$@" || continue
	total=$((total + 1))
	cp -- "$workdir/tmpcleaner.orig" "$workdir/tmpcleaner"
	replace_status=0
	OLD=$old NEW=$new LC_ALL=C awk '
		BEGIN {
			old = ENVIRON["OLD"]
			rep = ENVIRON["NEW"]
			if (old == "") exit 2
		}
		{
			buf = buf $0 "\n"
		}
		END {
			pos = index(buf, old)
			if (!pos) exit 2
			rest = substr(buf, pos + length(old))
			if (index(rest, old)) exit 3
			printf "%s%s%s", substr(buf, 1, pos - 1), rep, rest
		}
	' "$workdir/tmpcleaner.orig" > "$workdir/tmpcleaner.mut" || replace_status=$?
	if [ "$replace_status" -ne 0 ]; then
		echo "ERROR $name: replacement anchor did not match exactly once (status $replace_status)"
		errors=$((errors + 1))
		continue
	fi

	if [ "$control_ran" -eq 0 ]; then
		if ! (cd "$workdir" && sh tests/test.sh) > "$workdir/control.out" 2>&1; then
			cat "$workdir/control.out" >&2
			echo 'test-mutations.sh: control suite failed on unchanged copy' >&2
			exit 1
		fi
		control_ran=1
	fi

	cat "$workdir/tmpcleaner.mut" > "$workdir/tmpcleaner"
	rm -f "$workdir/tmpcleaner.mut"

	suite_status=0
	(cd "$workdir" && sh tests/test.sh) > "$workdir/suite.out" 2>&1 || suite_status=$?
	if [ "$suite_status" -eq 0 ]; then
		echo "SURVIVED $name: suite exited 0 (expected: $expect)"
		survived=$((survived + 1))
	elif grep -Fq -- "$expect" "$workdir/suite.out"; then
		echo "KILLED $name: $expect"
		killed=$((killed + 1))
	else
		echo "ERROR $name: suite exited $suite_status without expected failure: $expect"
		errors=$((errors + 1))
	fi
done < "$workdir/cases"

echo "summary: $killed/$total killed, $survived survived, $errors errors"
[ "$total" -gt 0 ] && [ "$killed" -eq "$total" ] && [ "$survived" -eq 0 ] && [ "$errors" -eq 0 ]
