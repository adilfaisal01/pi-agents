#!/usr/bin/env bash
# check.sh — everything in this package that can be verified, verified.
#
#   ./check.sh              # typecheck (if tsc is available) + the selftest
#   ./check.sh --no-types   # selftest only
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
RUN_TYPES=1
[ "${1:-}" = "--no-types" ] && RUN_TYPES=0

echo "== types =="
if [ "$RUN_TYPES" = 1 ]; then
	if ./prepare-types.sh 2>/dev/null; then
		if command -v tsc >/dev/null; then
			tsc -p tsconfig.json && echo "  ok    tsc"
		else
			echo "  skip  tsc (typescript not installed)"
		fi
	else
		echo "  skip  tsc (no pi release to link types from)"
	fi
else
	echo "  skip  tsc (--no-types)"
fi

echo
echo "== selftest =="
./prepare-types.sh >/dev/null 2>&1 || true
node selftest.mjs
