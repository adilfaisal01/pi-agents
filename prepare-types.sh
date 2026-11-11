#!/usr/bin/env bash
# prepare-types.sh — link the pi release's node_modules into this checkout so that
# `tsc -p .` can typecheck the extension, and so `node selftest.mjs` can resolve
# `@earendil-works/pi-coding-agent`.
#
# Types are NOT needed at runtime: pi loads the .ts itself. This is only for editors and
# for ./check.sh.
#
# The link is one level above nothing — this package IS the extension — so it lands at
# ./node_modules. The selftest resolves pi's packages through it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
TARGET="${PI_TYPES_DIR:-$HERE/node_modules}"

VERSION="$(cat "$AGENT_DIR/install/current-version" 2>/dev/null || true)"
RELEASE="${PI_RELEASE_ROOT:-$AGENT_DIR/install/releases/$VERSION/node_modules}"

if [ ! -d "$RELEASE/@earendil-works" ]; then
	echo "prepare-types: $RELEASE does not look like a pi node_modules tree" >&2
	echo "prepare-types: set PI_RELEASE_ROOT to a pi node_modules dir, or skip typechecking" >&2
	exit 2
fi

if [ -L "$TARGET" ] && [ "$(readlink -f "$TARGET")" = "$(readlink -f "$RELEASE")" ]; then
	echo "prepare-types: already linked from $(basename "$(dirname "$RELEASE")") ($VERSION)"
	exit 0
fi
if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
	echo "prepare-types: $TARGET exists and is not a link — remove it yourself" >&2
	exit 2
fi

ln -sfn "$RELEASE" "$TARGET"
echo "prepare-types: linked from $(basename "$(dirname "$RELEASE")") ($VERSION)"
