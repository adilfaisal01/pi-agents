#!/usr/bin/env bash
# check.sh — typecheck and assert the modes, with no pi session, no model, no network.
#
#   ./check.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== types =="
TYPED=0
if ./prepare-types.sh 2>/dev/null; then
	TYPED=1
else
	echo "  skip  tsc (no pi release to link types from)"
fi
if [ "$TYPED" = 1 ] && command -v tsc >/dev/null; then
	tsc -p tsconfig.json && echo "  ok    tsc"
else
	echo "  skip  tsc (typescript not installed)"
fi

echo
echo "== modes =="
node selftest.mjs
