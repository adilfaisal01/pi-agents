#!/usr/bin/env bash
# check.sh — everything in this repo that can be verified, verified.
#
#   ./check.sh            # gate self-test + extension typecheck + extension selftest
#   ./check.sh --no-types  # skip tsc (no pi install / no typescript)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
RUN_TYPES=1
[ "${1:-}" = "--no-types" ] && RUN_TYPES=0

echo "== gate =="
./gate/test-lock-check.sh

echo
echo "== extension =="
EXT=pi/extensions/agent-modes
if [ "$RUN_TYPES" = 1 ]; then
	if "$EXT/prepare-types.sh" 2>/dev/null; then
		if command -v tsc >/dev/null; then
			(cd "$EXT" && tsc -p tsconfig.json) && echo "  ok    tsc"
		else
			echo "  skip  tsc (typescript not installed)"
		fi
	else
		echo "  skip  tsc (no pi release to link types from)"
	fi
fi
node "$EXT/selftest.mjs"
