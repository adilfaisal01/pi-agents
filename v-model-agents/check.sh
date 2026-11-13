#!/usr/bin/env bash
# check.sh — everything in this repo that can be verified without a model.
#
#   ./check.sh
#
# The modes: typecheck + 38 assertions against the real extension, no pi needed.
# The optional V-model material: the gate's own self-tests, driven by a stub lane runner.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== agent modes =="
./modes/check.sh

echo
echo "== v-model (optional) =="
./gate/test-lock-check.sh
./gate/test-wave.sh
./gate/test-barrier.sh

echo
echo "== v-model skill =="
SKILL=skills/v-model/SKILL.md
[ -f "$SKILL" ] || {
	echo "  FAIL  $SKILL is missing" >&2
	exit 1
}
frontmatter() { awk 'BEGIN{n=0} /^---$/{n++; next} n==1' "$SKILL"; }
for key in name description; do
	frontmatter | grep -qE "^${key}:[[:space:]]*[^[:space:]]" ||
		{ echo "  FAIL  frontmatter has no '$key'" >&2; exit 1; }
done
frontmatter | grep -q '^disable-model-invocation:[[:space:]]*true' ||
	{ echo "  FAIL  the skill must be invoke-only (disable-model-invocation: true)" >&2; exit 1; }
echo "  ok    frontmatter: name, description, invoke-only"
# The procedure tells the agent to run these from the repo it is working in. If either
# disappears the instructions are pointing at nothing, which is worse than a typo.
for path in gate/wave.sh agents/sysdv.md agents/build.md docs/06-ledger.md; do
	[ -e "$path" ] || { echo "  FAIL  the procedure names $path, which does not exist" >&2; exit 1; }
done
echo "  ok    the paths the procedure names exist"
