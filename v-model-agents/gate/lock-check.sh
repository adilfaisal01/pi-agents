#!/usr/bin/env bash
# lock-check.sh — refuse a tree whose frozen test surface moved since the pin.
#
#   ./gate/lock-check.sh <pin-sha> [path ...]
#
# Exit 0 clean · 1 drift (frozen surface changed) · 2 usage/argument error.
#
# The pin is a COMMIT, not a list of test files. A file list forgets the selector
# (pyproject addopts, pytest.ini, conftest.py) and the command itself, and those are
# the cheapest routes to a green that measured nothing.
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: lock-check.sh <pin-sha> [path ...]

  <pin-sha>   commit that froze the test surface (git rev-parse HEAD at the freeze)
  [path ...]  override the lock surface (default: tests/ conftest.py
              pyproject.toml pytest.ini tox.ini setup.cfg gate/run-tests.sh)

exit 0 clean, 1 drift, 2 usage/argument error.
EOF
}

PIN="${1:-}"
[ -n "$PIN" ] || { usage; exit 2; }
shift || true

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "lock-check: not inside a git work tree" >&2
	exit 2
}
cd "$ROOT"

if ! git rev-parse --verify --quiet "${PIN}^{commit}" >/dev/null; then
	echo "lock-check: '$PIN' is not a commit in this repository" >&2
	exit 2
fi
PIN="$(git rev-parse "${PIN}^{commit}")"

if ! git merge-base --is-ancestor "$PIN" HEAD; then
	echo "lock-check: pin ${PIN:0:10} is not an ancestor of HEAD" >&2
	echo "lock-check: history was rewritten or you are on another branch" >&2
	exit 2
fi

if [ "$#" -gt 0 ]; then
	LOCK_PATHS=("$@")
else
	LOCK_PATHS=(tests conftest.py pyproject.toml pytest.ini tox.ini setup.cfg gate/run-tests.sh)
fi

# Only assert on paths that existed at the pin, so a caller can share one default list
# across repositories that do not all use every file.
EXISTING=()
for p in "${LOCK_PATHS[@]}"; do
	if git cat-file -e "${PIN}:${p}" 2>/dev/null; then
		EXISTING+=("$p")
	fi
done

if [ "${#EXISTING[@]}" -eq 0 ]; then
	echo "lock-check: none of the lock paths exist at ${PIN:0:10}: ${LOCK_PATHS[*]}" >&2
	echo "lock-check: check the pin, or pass the lock surface explicitly" >&2
	exit 2
fi

if git diff --quiet "$PIN" -- "${EXISTING[@]}"; then
	echo "lock-check: clean — frozen surface unchanged since ${PIN:0:10}"
	exit 0
fi

echo "lock-check: REFUSED — the frozen test surface changed since ${PIN:0:10}" >&2
echo "lock-check: changed paths:" >&2
git diff --stat "$PIN" -- "${EXISTING[@]}" >&2
echo >&2
echo "lock-check: a build lane may not edit a frozen test. If the SPEC changed, make an" >&2
echo "lock-check: amendment commit that says so, pin it, and rebase onto the new pin." >&2
exit 1
