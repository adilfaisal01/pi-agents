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
# The pin checks are shared with selftest.sh, so the two commands cannot disagree.
. "$ROOT/scripts/check-models.sh"

usage() {
	printf 'usage: %s [install|check|uninstall] [--force]\n' "${0##*/}" >&2
	exit 2
}

# A lane whose model this install cannot resolve dispatches nothing. Say so here, where
# the fix is one edit away, rather than at dispatch time as a provider 404.
check_models() {
	if ! command -v pi >/dev/null 2>&1; then
		printf 'FAIL  model ids: pi is not on PATH\n'
		rc=1
		return 0 # under `set -e`: report through rc, do not abort the link check
	fi
	local lane file model
	local pinned=()
	for lane in "${LANES[@]}"; do
		file="$ROOT/agents/$lane.md"
		if [ ! -f "$file" ]; then
			printf 'FAIL  %s: agents/%s.md is missing\n' "$lane" "$lane"
			rc=1
			continue
		fi
		model=$(lane_model "$file" || true)
		if [ -z "$model" ]; then
			printf 'FAIL  %s: no model pinned — the gate will not pick one\n' "$lane"
			rc=1
			continue
		fi
		pinned+=("$(lane_model_lookup "$model")")
		if model_resolves "$model"; then
			printf 'ok    %s: %s resolves\n' "$lane" "$model"
		else
			printf 'FAIL  %s: %s is not in this install'"'"'s model registry\n' "$lane" "$model"
			printf '      set model: in agents/%s.md to a provider/id you have:\n' "$lane"
			printf '        pi --list-models\n'
			rc=1
		fi
	done
	if [ "${#pinned[@]}" -eq 2 ]; then
		single_model_warning "${pinned[0]}" "${pinned[1]}" || true
	fi
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

rc=0

# `check` is read-only; only a link needs the directory to exist.
if [ "$MODE" = install ]; then
	mkdir -p "$AGENT_DIR"
fi

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

# `check` is the pre-flight: links AND the two model ids, because a lane with an id this
# install cannot resolve is the failure a stranger hits first.
if [ "$MODE" = check ]; then
	check_models
fi

exit $rc
