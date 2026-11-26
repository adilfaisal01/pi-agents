#!/usr/bin/env bash
# check-role-models.sh — keep the shipped role→model sample honest.
#
#   bash forge/check-role-models.sh
#
# Three things are checked, all offline except the last:
#
#   1. the sample parses, and its keys are EXACTLY the roles this package ships. A key that
#      matches no discovered agent is silently ignored by discovery, so a typo in a map is a
#      false sense of pinning — that is the failure this catches.
#   2. no `forge/agents/*.md` carries a `model:` line. The agents ship model-free on purpose:
#      a model in an installed package file is replaced by `pi update`, and the map exists so
#      that pins live somewhere the user owns.
#   3. when `pi` is on PATH, every id in the sample resolves in this install (`--list-models`).
#      Without pi this reports SKIP and exits 0 — a runner that cannot answer the question must
#      not fail the package.
#
# Exit: 0 ok (or skipped), 1 a check failed, 2 usage/environment.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SAMPLE="$ROOT/subagent-models.example.json"
AGENTS="$ROOT/agents"

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
skip() { printf '  skip  %s\n' "$1"; }

[ -f "$SAMPLE" ] || { printf 'check-role-models: missing %s\n' "$SAMPLE" >&2; exit 2; }
[ -d "$AGENTS" ] || { printf 'check-role-models: missing %s\n' "$AGENTS" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'check-role-models: jq is required\n' >&2; exit 2; }

echo "== role → model sample =="

if ! jq -e 'type == "object"' "$SAMPLE" >/dev/null 2>&1; then
	fail "the sample is a JSON object"
	printf '\nrole-model checks failed\n'
	exit 1
fi
pass "the sample is a JSON object"

# 1. keys == the roles shipped next to it.
shipped=$(for f in "$AGENTS"/*.md; do
	awk '
		BEGIN { fence = 0 }
		/^---[[:space:]]*$/ { fence++; next }
		fence == 1 && index($0, "name:") == 1 { sub("^name:[[:space:]]*", ""); print; exit }
	' "$f"
done | sort)
mapkeys=$(jq -r 'keys_unsorted | .[]' "$SAMPLE" | sort)

if [ "$shipped" = "$mapkeys" ]; then
	pass "sample keys are exactly the shipped roles ($(printf '%s' "$mapkeys" | tr '\n' ' ' | sed 's/ $//'))"
else
	fail "sample keys differ from the shipped roles"
	printf '        shipping: %s\n' "$(printf '%s' "$shipped" | tr '\n' ' ')"
	printf '        sample:   %s\n' "$(printf '%s' "$mapkeys" | tr '\n' ' ')"
fi

# Values must look like a provider-qualified id. A bare id is legal for pi, but a map is the
# place where the provider is the whole point (two providers, two blind spots).
bare=$(jq -r 'to_entries[] | select(.value | test("/") | not) | .key' "$SAMPLE")
if [ -z "$bare" ]; then
	pass "every entry is provider-qualified (provider/id)"
else
	fail "entries without a provider: $(printf '%s' "$bare" | tr '\n' ' ')"
fi

# 2. the agents stay model-free.
pinned=$(grep -l '^model:' "$AGENTS"/*.md 2>/dev/null || true)
if [ -z "$pinned" ]; then
	pass "no forge agent pins a model (portable across \`pi update\`)"
else
	fail "an agent file pins a model: $(printf '%s' "$pinned" | tr '\n' ' ')"
fi

# 3. the ids resolve here, but only where the answer can be trusted. PI_MODEL_CHECK=skip says
#    the caller's install has no model registry (the publish workflow sets it for a runner);
#    without pi, or with an empty registry, the question cannot be answered either. A runner
#    that cannot answer must not fail the package — and a registry full of ids this install
#    never had must not fail it either, which is what a credential-less runner looks like.
if [ "${PI_MODEL_CHECK:-}" = "skip" ]; then
	skip "sample ids resolve (PI_MODEL_CHECK=skip)"
	printf '\nrole-model checks passed\n'
	exit 0
fi
if ! command -v pi >/dev/null 2>&1; then
	skip "sample ids resolve (pi is not on PATH)"
	printf '\nrole-model checks %s\n' "$([ "$FAILED" -eq 0 ] && echo passed || echo failed)"
	[ "$FAILED" -eq 0 ] || exit 1
	exit 0
fi

available=$(pi --list-models 2>/dev/null | awk 'NR > 1 { print $1 "/" $2 }')
[ -n "$available" ] || { skip "sample ids resolve (no model registry answered)"; exit 0; }

while IFS= read -r entry; do
	role=${entry%%=*}
	model=${entry#*=}
	if printf '%s\n' "$available" | grep -Fxq -- "$model"; then
		pass "resolves here: $role → $model"
	else
		fail "does not resolve here: $role → $model (set an id your install has)"
	fi
done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$SAMPLE")

printf '\nrole-model checks %s\n' "$([ "$FAILED" -eq 0 ] && echo passed || echo failed)"
[ "$FAILED" -eq 0 ] || exit 1
