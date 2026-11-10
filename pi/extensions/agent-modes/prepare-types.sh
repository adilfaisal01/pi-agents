#!/usr/bin/env bash
# prepare-types.sh — link the pi release's type packages into this checkout so that
# `tsc -p .` can typecheck the extension.
#
# Types are NOT needed at runtime: pi loads the .ts itself. This is only for editors and
# for `./check.sh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"

VERSION="$(cat "$AGENT_DIR/install/current-version" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
	echo "prepare-types: no managed install at $AGENT_DIR/install" >&2
	echo "prepare-types: set PI_RELEASE_ROOT to a pi node_modules dir, or skip typechecking" >&2
	exit 2
fi

RELEASE="${PI_RELEASE_ROOT:-$AGENT_DIR/install/releases/$VERSION/node_modules}"
if [ ! -d "$RELEASE/@earendil-works" ] || [ ! -d "$RELEASE/@types" ]; then
	echo "prepare-types: $RELEASE does not look like a pi node_modules tree" >&2
	exit 2
fi

mkdir -p "$HERE/node_modules/@earendil-works"

link() { # link <target> <linkpath>
	if [ -e "$2" ] && [ ! -L "$2" ]; then
		mv "$2" "$2.bak.$(date +%Y%m%d_%H%M%S)"
	fi
	ln -sfn "$1" "$2"
}

for p in pi-agent-core pi-ai pi-coding-agent pi-tui; do
	[ -d "$RELEASE/@earendil-works/$p" ] && link "$RELEASE/@earendil-works/$p" "$HERE/node_modules/@earendil-works/$p"
done
link "$RELEASE/@types" "$HERE/node_modules/@types"

echo "prepare-types: linked from $(basename "$(dirname "$RELEASE")") ($VERSION)"
