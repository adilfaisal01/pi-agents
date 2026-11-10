#!/usr/bin/env bash
# prepare-types.sh — link the pi release's node_modules into this checkout so that
# `tsc -p .` can typecheck the extensions.
#
# Types are NOT needed at runtime: pi loads the .ts itself. This is only for editors and
# for `./check.sh`.
#
# The link is made at pi/node_modules (one level above the extensions), not inside an
# extension directory, so that every extension in this package resolves the same copy —
# Node's resolution walks upward, and two extensions typechecking against two different
# copies of the pi types is how a vendored file starts disagreeing with its host.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
TARGET="${PI_TYPES_DIR:-$HERE/../../node_modules}"

VERSION="$(cat "$AGENT_DIR/install/current-version" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
	echo "prepare-types: no managed install at $AGENT_DIR/install" >&2
	echo "prepare-types: set PI_RELEASE_ROOT to a pi node_modules dir, or skip typechecking" >&2
	exit 2
fi

RELEASE="${PI_RELEASE_ROOT:-$AGENT_DIR/install/releases/$VERSION/node_modules}"
if [ ! -d "$RELEASE/@earendil-works" ]; then
	echo "prepare-types: $RELEASE does not look like a pi node_modules tree" >&2
	exit 2
fi

if [ -L "$TARGET" ] && [ "$(readlink -f "$TARGET")" = "$(readlink -f "$RELEASE")" ]; then
	echo "prepare-types: already linked from $(basename "$(dirname "$RELEASE")") ($VERSION)"
	exit 0
fi
if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
	mv "$TARGET" "$TARGET.bak.$(date +%Y%m%d_%H%M%S)"
fi

ln -sfn "$RELEASE" "$TARGET"
echo "prepare-types: linked from $(basename "$(dirname "$RELEASE")") ($VERSION)"
