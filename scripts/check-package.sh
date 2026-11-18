#!/usr/bin/env bash
# check-package.sh — everything the published tarball must be true, checked before it goes.
#
#   bash scripts/check-package.sh          # manifest + tarball + every suite
#   bash scripts/check-package.sh --fast   # manifest + tarball only
#
# `prepublishOnly` runs this, so a package that would install broken cannot reach the
# registry: npm publish re-runs the whole thing and aborts on a non-zero exit.
#
# No network, no model calls.

set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

echo "== manifest and tarball =="
if node scripts/check-manifest.mjs; then
	pass "package.json: resources, bin targets, host peers, packed file list"
else
	fail "package.json: resources, bin targets, host peers, or packed file list"
fi

echo
echo "== suites (none dispatches a model) =="
LOGS=$(mktemp -d)
trap 'rm -rf "$LOGS"' EXIT
run() { # run <name> <script>
	if [ "$FAST" -eq 1 ]; then
		printf '  skip  %s (--fast)\n' "$1"
		return
	fi
	local name log
	name=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')
	log="$LOGS/$name.out"
	if bash "$2" >"$log" 2>&1; then
		pass "$1"
	else
		fail "$1"
		tail -20 "$log" | sed 's/^/        /'
	fi
}

run "v-model-agents: modes + V-model gate" v-model-agents/check.sh
run "code-review-swarm: lanes and their model pins" code-review-swarm/scripts/selftest.sh
run "pi-subagent: the LOCAL changes" pi-subagent/check.sh
run "review-lanes: worktree assertion" review-lanes/check.sh
run "review-gate: stub-lane suite" review-gate/check.sh

echo
if [ "$FAILED" -eq 0 ]; then
	echo "package is publishable"
	exit 0
fi
echo "package checks failed"
exit 1
