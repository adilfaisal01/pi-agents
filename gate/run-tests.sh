#!/usr/bin/env bash
# run-tests.sh — the canonical command for a frozen suite.
#
# Locked with the tests (docs/04): changing this file is a lock-surface change, not a
# build change. The marker selection is spelled out HERE rather than inherited from
# pyproject addopts, because addopts is editable and is the cheapest way to deselect a
# failing category without touching an assertion.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# --override-ini neutralises addopts so the selection below is the only one in effect.
# -p no:cacheprovider keeps the run from writing .pytest_cache into the tree.
exec python3 -m pytest tests/ \
	-p no:cacheprovider \
	--override-ini="addopts=" \
	-m "not integration and not mcp" \
	"$@"
