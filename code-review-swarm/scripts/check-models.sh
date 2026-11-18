#!/usr/bin/env bash
# Shared model-pin checks for the two review lanes. SOURCED, never executed:
#
#   . "$ROOT/scripts/check-models.sh"
#
# `install.sh check` and `selftest.sh` both ask the same question — "does this install
# have the model each lane pins?" — so there is one implementation of the answer. Two
# copies had already drifted: one stripped a `:<thinking>` suffix before the lookup and
# the other did not, so the two "verify your checkout" commands returned opposite
# verdicts on the same agent file.

# lane_model <agent-file> — the pinned id, without the line ending or trailing space.
# The frontmatter is YAML, but this reads it the way the dispatcher does: the first
# `model:` line between the fences, value verbatim. A `#` comment above it is ignored.
lane_model() {
	awk '
		BEGIN { fence = 0 }
		/^---[[:space:]]*$/ { fence++; next }
		fence == 1 && index($0, "model:") == 1 {
			sub("^model:[[:space:]]*", "")
			print
			exit
		}
	' "$1" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

# lane_model_lookup <model> — the id to search the registry for.
# `provider/id:<level>` is a valid pin: pi strips `:<level>` before resolving, and
# `--list-models` only knows the bare id. Strip the suffix only when it IS a thinking
# level — `ollama-cloud/deepseek-v4-pro:0813` is a model tag, and its base is no id.
lane_model_lookup() {
	case ${1##*:} in
		off | minimal | low | medium | high | xhigh | max) printf '%s' "${1%:*}" ;;
		*) printf '%s' "$1" ;;
	esac
}

# model_resolves <model> — 0 resolvable here, 1 not, 2 pi is not on PATH.
model_resolves() {
	command -v pi >/dev/null 2>&1 || return 2
	local lookup prov want
	lookup=$(lane_model_lookup "$1")
	prov=${lookup%%/*}
	if [ "$prov" = "$lookup" ]; then
		prov=""
		want="$lookup"
	else
		want=${lookup#*/}
	fi
	# Exact match on both columns: --list-models fuzzy-matches, so a substring test would
	# pass on a lookalike (mistral-large vs mistral-large-4) and hide the typo that breaks
	# the dispatch.
	pi --list-models "$lookup" 2>/dev/null | awk -v p="$prov" -v m="$want" '
		NR > 1 && $2 == m && (p == "" || $1 == p) { found = 1 }
		END { exit !found }
	'
}

# single_model_warning <lane-a-model> <lane-b-model> — 0 (and the warning) when both lanes
# pin one model. Two prompts on one model share blind spots, so it is not the review this
# claims to be; a warning rather than a refusal, because a single-model run is a documented
# fallback. Shared, so the two commands cannot announce different policy.
single_model_warning() {
	[ -n "$1" ] && [ "$1" = "$2" ] || return 1
	printf 'WARN  both lanes pin %s — a single-model review, not two independent models\n' "$1"
}
