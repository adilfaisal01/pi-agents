#!/usr/bin/env bash
# Link the review lanes into pi's user agent directory.
#
# pi discovers skills from packages, but it has no package resource for agents:
# agent definitions are only read from ~/.pi/agent/agents and the nearest
# .pi/agents. So the lanes ship here as source and get symlinked in, which keeps
# the checkout authoritative and the symlink a pointer rather than a copy.
#
# Usage: scripts/install.sh [install|check|uninstall] [--force]

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
AGENT_DIR="${PI_AGENT_DIR:-$HOME/.pi/agent}/agents"
LANES=(review-correctness review-quality)

usage() {
	printf 'usage: %s [install|check|uninstall] [--force]\n' "${0##*/}" >&2
	exit 2
}

MODE=install
FORCE=0
for arg in "$@"; do
	case $arg in
		install | check | uninstall | status) MODE=$arg ;;
		--force) FORCE=1 ;;
		-h | --help) usage ;;
		*) printf 'unknown argument: %s\n' "$arg" >&2; usage ;;
	esac
done

[ "$MODE" = status ] && MODE=check

mkdir -p "$AGENT_DIR"

rc=0

link_state() {
	# Prints: ok | missing | stale | foreign
	local src=$1 dst=$2
	if [ -L "$dst" ]; then
		if [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
			printf 'ok'
		else
			printf 'stale'
		fi
	elif [ -e "$dst" ]; then
		printf 'foreign'
	else
		printf 'missing'
	fi
}

for lane in "${LANES[@]}"; do
	src="$ROOT/agents/$lane.md"
	dst="$AGENT_DIR/$lane.md"

	if [ ! -f "$src" ]; then
		printf 'FAIL  %s: source missing (%s)\n' "$lane" "$src" >&2
		rc=1
		continue
	fi

	case $MODE in
		check)
			state=$(link_state "$src" "$dst")
			case $state in
				ok) printf 'ok    %s -> %s\n' "$dst" "$(readlink "$dst")" ;;
				missing) printf 'FAIL  %s not linked\n' "$dst"; rc=1 ;;
				stale) printf 'FAIL  %s points elsewhere (%s)\n' "$dst" "$(readlink "$dst")"; rc=1 ;;
				foreign) printf 'WARN  %s is a real file, not a symlink here\n' "$dst"; rc=1 ;;
			esac
			;;
		uninstall)
			if [ -L "$dst" ]; then
				rm -f "$dst"
				printf 'rm    %s\n' "$dst"
			else
				printf 'skip  %s is not a symlink\n' "$dst"
			fi
			;;
		install)
			state=$(link_state "$src" "$dst")
			case $state in
				ok) printf 'ok    %s already linked\n' "$dst" ;;
				missing)
					ln -s "$src" "$dst"
					printf 'link  %s -> %s\n' "$dst" "$src"
					;;
				stale | foreign)
					if [ "$FORCE" -eq 1 ]; then
						rm -f "$dst"
						ln -s "$src" "$dst"
						printf 'relink %s -> %s\n' "$dst" "$src"
					else
						printf 'FAIL  %s exists and is not this checkout; rerun with --force to replace it\n' "$dst" >&2
						rc=1
					fi
					;;
			esac
			;;
	esac
done

# A copy in the user skills dir shadows nothing but loads twice if the package is
# also installed. Flag it rather than deleting someone's edit.
user_skill="${PI_AGENT_DIR:-$HOME/.pi/agent}/skills/code-review-swarm/SKILL.md"
if [ -f "$user_skill" ] && [ "$(readlink -f "$user_skill")" != "$(readlink -f "$ROOT/skills/code-review-swarm/SKILL.md")" ]; then
	printf 'WARN  %s is a separate copy; install this repo as a package and remove it to avoid two skills\n' "$user_skill"
fi

exit $rc
