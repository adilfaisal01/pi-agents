#!/usr/bin/env bash
# check.sh — everything in this repo that can be verified, verified.
#
#   ./check.sh             # gate self-test + typecheck + both extension selftests
#   ./check.sh --no-types  # skip tsc (no pi install / no typescript)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
RUN_TYPES=1
[ "${1:-}" = "--no-types" ] && RUN_TYPES=0

echo "== gate =="
./gate/test-lock-check.sh
./gate/test-wave.sh

TYPED=0
if [ "$RUN_TYPES" = 1 ]; then
	echo
	echo "== types =="
	if pi/extensions/agent-modes/prepare-types.sh 2>/dev/null; then
		TYPED=1
	else
		echo "  skip  tsc (no pi release to link types from)"
	fi
fi

for EXT in pi/extensions/agent-modes pi/extensions/subagent; do
	echo
	echo "== extension: ${EXT#pi/extensions/} =="
	if [ "$TYPED" = 1 ]; then
		if command -v tsc >/dev/null; then
			(cd "$EXT" && tsc -p tsconfig.json) && echo "  ok    tsc"
		else
			echo "  skip  tsc (typescript not installed)"
		fi
	fi
	node "$EXT/selftest.mjs"
done
