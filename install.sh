#!/usr/bin/env bash
# install.sh — wire this checkout into a pi installation.
#
#   ./install.sh --dry-run          # show what would change
#   ./install.sh                    # extensions + agents + subagent tool
#   ./install.sh --no-subagent      # skip pi's shipped subagent extension
#
# Everything is a symlink into this checkout, so `git pull` updates the installed
# profile. An existing real directory is moved aside, never overwritten.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}"
DRY=0
DO_EXT=1
DO_AGENTS=1
DO_SUBAGENT=1

for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY=1 ;;
	--no-extensions) DO_EXT=0 ;;
	--no-agents) DO_AGENTS=0 ;;
	--no-subagent) DO_SUBAGENT=0 ;;
	-h | --help)
		sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
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
fi

if [ "$DO_AGENTS" = 1 ]; then
	say "agents:"
	link "$REPO/pi/agents/sysdv.md" "$AGENT_DIR/agents/sysdv.md"
fi

if [ "$DO_SUBAGENT" = 1 ]; then
	say "subagent tool:"
	VERSION="$(cat "$AGENT_DIR/install/current-version" 2>/dev/null || true)"
	SUB="$AGENT_DIR/install/releases/$VERSION/node_modules/@earendil-works/pi-coding-agent/examples/extensions/subagent"
	if [ -z "$VERSION" ]; then
		say "  skip: no managed pi install under $AGENT_DIR/install"
		SUB=""
	fi
	if [ -n "$SUB" ] && [ -d "$SUB" ]; then
		link "$SUB" "$AGENT_DIR/extensions/subagent"
	elif [ -n "$SUB" ]; then
		say "  skip: $SUB not found (copy examples/extensions/subagent/ yourself)"
	fi
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
say "  - the profile's model ids must exist in your provider; edit them in that"
say "    config and re-run this script (the symlink means no re-install is needed"
say "    after a pull, only a new pi session)"
say "  - drop gate/ into each target repo (docs/04-freeze-and-pin.md)"
