#!/usr/bin/env bash
# install.sh — wire this checkout into a pi installation (development only).
#
#   ./install.sh --dry-run          # show what would change
#   ./install.sh                    # both extensions, symlinked
#   ./install.sh --no-extensions    # nothing
#
# The distribution path is `pi install git:github.com/<owner>/v-model-agents`;
# this script is for working on the checkout itself. Everything is a symlink, so
# `git pull` updates the installed profile and `/reload` picks it up. An existing
# real directory is moved aside, never overwritten.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
DRY=0
DO_EXT=1

for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY=1 ;;
	--no-extensions) DO_EXT=0 ;;
	-h | --help)
		sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "install: unknown argument '$arg'" >&2
		exit 2
		;;
	esac
done

say() { printf '%s\n' "$*"; }
run() {
	if [ "$DRY" = 1 ]; then say "  would: $*"; else "$@"; fi
}

link() { # link <target> <linkpath>
	local target="$1" dest="$2"
	if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$target")" ]; then
		say "  ok: $dest"
		return
	fi
	if [ -e "$dest" ] && [ ! -L "$dest" ]; then
		local bak="$dest.bak.$(date +%Y%m%d_%H%M%S)"
		say "  backup: $dest -> $bak"
		run mv "$dest" "$bak"
	fi
	run mkdir -p "$(dirname "$dest")"
	run ln -sfn "$target" "$dest"
	if [ "$DRY" = 1 ]; then
		say "  would link: $dest -> $target"
	else
		say "  link: $dest -> $target"
	fi
}

say "install: $REPO -> $AGENT_DIR"
[ -d "$AGENT_DIR" ] || {
	say "install: $AGENT_DIR does not exist — is pi installed?" >&2
	exit 2
}

if [ "$DO_EXT" = 1 ]; then
	say "extensions:"
	link "$REPO/pi/extensions/agent-modes" "$AGENT_DIR/extensions/agent-modes"
	link "$REPO/pi/extensions/subagent" "$AGENT_DIR/extensions/subagent"
fi

if [ "$DRY" = 1 ]; then
	say ""
	say "dry run: nothing changed"
	exit 0
fi

say ""
say "next:"
say "  - start pi; a new session enters the default mode from"
say "    pi/extensions/agent-modes/config.json"
say "  - the shipped profile has no model ids and no provider. Set yours in"
say "    ~/.pi/agent/agent-modes.json (or <repo>/.pi/agent-modes.json), per mode:"
say "      { \"provider\": \"…\", \"modes\": { \"plan\": { \"model\": \"…\" } } }"
say "    the symlink means a new pi session is enough — no re-install"
say "  - drop gate/ into each target repo (docs/04-freeze-and-pin.md)"
