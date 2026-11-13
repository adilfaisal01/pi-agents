#!/usr/bin/env bash
# prepare-types.sh — link the pi release's node_modules into this checkout so that
# `tsc -p .` can typecheck the extensions.
#
# Types are NOT needed at runtime: pi loads the .ts itself. This is only for editors and
# for `./check.sh`.
#
# The link is made at the package's own node_modules, so that `tsc -p tsconfig.json` and
# any editor resolves one copy of the pi types — two checkouts typechecking against two
# different copies of the host's types is how a source file starts disagreeing with it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
TARGET="${PI_TYPES_DIR:-$HERE/node_modules}"

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
