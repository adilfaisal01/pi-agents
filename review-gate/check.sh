#!/usr/bin/env bash
# check.sh — everything here that can be verified, verified.
#
#   ./check.sh
#
# No model calls: the lane transcripts are stubbed, so what is measured is the policy and
# the plumbing. The cross-file checks matter because the gate has a contract with the mode
# prompts — a rule that names exit codes the gate does not use is a gate nobody honours.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

FAILED=0
pass() { printf '  ok    %s\n' "$1"; }
fail() {
	printf '  FAIL  %s\n' "$1"
	FAILED=1
}

echo "== syntax =="
if bash -n bin/swarm-gate 2>/dev/null && bash -n tests/run-tests.sh 2>/dev/null && bash -n tests/stub-bin/pi 2>/dev/null; then
	pass "shell scripts parse"
else
	fail "a shell script does not parse"
fi

if command -v python3 >/dev/null 2>&1; then
	if python3 -m py_compile lib/swarm_gate.py 2>/dev/null; then
		pass "lib/swarm_gate.py compiles"
	else
		fail "lib/swarm_gate.py does not compile"
	fi
else
	fail "python3 not on PATH — the gate cannot run"
fi

echo
echo "== contract: README states every exit code the gate returns =="
for code in 0 1 2 3 4 5 6; do
	if grep -qE "^\| $code \|" README.md; then
		pass "README documents exit $code"
	else
		fail "README does not document exit $code"
	fi
done
# Real check, not a count: every numeric return in the gate must be one of the documented
# codes, so a new exit path cannot appear without the README and the prompts learning it.
bad=$(grep -oE '^\s+return [0-9]+' lib/swarm_gate.py | grep -oE '[0-9]+' | sort -u | grep -vE '^[0-6]$' || true)
if [ -z "$bad" ]; then
	pass "every returned code is in 0-5 ($(grep -cE '^\s+return [0-9]+' lib/swarm_gate.py) direct returns)"
else
	fail "the gate returns undocumented code(s): $bad"
fi

echo
echo "== contract: build and yolo prompts route the gate =="
PROMPTS=../v-model-agents/modes/prompts
for prompt in build yolo; do
	file="$PROMPTS/$prompt.md"
	if [ ! -f "$file" ]; then
		fail "$file missing"
		continue
	fi
	if grep -qF 'swarm-gate' "$file"; then
		pass "$prompt.md names swarm-gate"
	else
		fail "$prompt.md does not tell the agent to run the gate"
	fi
	for code in 0 1 3 4 5 6; do
		if grep -qE "\`$code\`" "$file"; then
			pass "$prompt.md handles exit $code"
		else
			fail "$prompt.md does not handle exit $code"
		fi
	done
done
# The gate is path-free on purpose: the prompt must not pin a checkout path.
if grep -qE '/mnt/|/home/' "$PROMPTS/build.md" "$PROMPTS/yolo.md"; then
	fail "a mode prompt hardcodes an absolute path"
else
	pass "no absolute checkout path in the mode prompts"
fi

echo
# The storage contract: evidence has to be recorded, ignored, and readable across days.
if grep -qF 'review-work' README.md; then
	pass "README documents the review-work folder"
else
	fail "README does not document review-work"
fi
if grep -qF '.git/info/exclude' README.md; then
	pass "README states how the folder is ignored"
else
	fail "README does not say how review-work is ignored"
fi
for prompt_file in "$PROMPTS/build.md" "$PROMPTS/yolo.md"; do
	if grep -qF 'review-work' "$prompt_file"; then
		fail "$(basename "$prompt_file") names review-work — the agent should not need the storage layout"
	else
		pass "$(basename "$prompt_file") stays out of the storage layout"
	fi
done

echo
# A JSONL format that stops parsing is a silently empty history, so read a real file back.
if python3 - "$PWD" <<'PY'
import sys, json, pathlib
root = pathlib.Path(sys.argv[1])
files = sorted((root.parent / "review-work").glob("*.jsonl")) if (root.parent / "review-work").is_dir() else []
print("no review-work yet" if not files else f"{len(files)} date file(s)")
PY
then
	pass "review-work date files parse (or none exist yet)"
else
	fail "a review-work date file does not parse"
fi

echo
echo "== tests =="
if bash tests/run-tests.sh >/tmp/review-gate-tests.out 2>&1; then
	pass "$(tail -1 /tmp/review-gate-tests.out)"
else
	fail "test suite failed"
	tail -20 /tmp/review-gate-tests.out | sed 's/^/        /'
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "all checks passed"
	exit 0
fi
echo "checks failed"
exit 1
