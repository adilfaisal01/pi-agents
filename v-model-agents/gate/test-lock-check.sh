#!/usr/bin/env bash
# test-lock-check.sh — self-test for lock-check.sh, in a throwaway repo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { # check <name> <expected-rc> <actual-rc>
	if [ "$3" -eq "$2" ]; then
		printf '  ok    %s\n' "$1"
		pass=$((pass + 1))
	else
		printf '  FAIL  %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

cd "$TMP"
git init -q .
git config user.email test@invalid
git config user.name test
mkdir -p tests gate
printf 'def test_placeholder():\n    assert True\n' >tests/test_a.py
cp "$HERE/run-tests.sh" gate/run-tests.sh
git add -A
git commit -qm "freeze"
PIN="$(git rev-parse HEAD)"

echo "lock-check selftest"

set +e
"$HERE/lock-check.sh" "$PIN" >/dev/null 2>&1
rc=$?
set -e
check "clean tree passes" 0 "$rc"

printf '# tamper\n' >>tests/test_a.py
set +e
"$HERE/lock-check.sh" "$PIN" >/dev/null 2>&1
rc=$?
set -e
check "edited test is refused" 1 "$rc"

set +e
out="$("$HERE/lock-check.sh" "$PIN" 2>&1)"
rc=$?
set -e
case "$out" in
*REFUSED*) check "refusal names the drift" 0 0 ;;
*) check "refusal names the drift" 0 1 ;;
esac
git checkout -q -- tests/test_a.py

printf 'notes\n' >NOTES.md
git add NOTES.md
git commit -qm "unrelated"
set +e
"$HERE/lock-check.sh" "$PIN" >/dev/null 2>&1
rc=$?
set -e
check "unrelated file is ignored" 0 "$rc"

mkdir -p tests/nested
printf 'def test_nested():\n    assert True\n' >tests/nested/test_b.py
git add -A
git commit -qm "new test"
set +e
"$HERE/lock-check.sh" "$PIN" >/dev/null 2>&1
rc=$?
set -e
check "test added after the pin is refused" 1 "$rc"
git reset -q --hard "$PIN"

set +e
"$HERE/lock-check.sh" deadbeef >/dev/null 2>&1
rc=$?
set -e
check "bogus pin is a usage error" 2 "$rc"

set +e
"$HERE/lock-check.sh" >/dev/null 2>&1
rc=$?
set -e
check "missing pin is a usage error" 2 "$rc"

# A pin that is not an ancestor: rewrite the frozen commit on a branch.
git checkout -q -b side "$PIN"
git commit -q --amend -m "rewritten freeze"
set +e
"$HERE/lock-check.sh" "$PIN" >/dev/null 2>&1
rc=$?
set -e
check "non-ancestor pin is a usage error" 2 "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
