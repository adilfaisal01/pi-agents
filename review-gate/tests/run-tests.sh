#!/usr/bin/env bash
# run-tests.sh — the gate's own self-test, with a stub lane runner and no model calls.
#
#   tests/run-tests.sh
#
# What is asserted is the policy and the plumbing, because that is what can be wrong
# silently: a lane that never reported must not read as "clean", the round budget must
# survive a fix, and the loop guard must fire on a signature that survives a round.
# Review quality itself is not assertable here and is not pretended to be.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GATE="$HERE/../bin/swarm-gate"
STUB_BIN="$HERE/stub-bin"
FAILED=0
PASSED=0

pass() { printf 'pass  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() {
	printf 'FAIL  %s\n' "$1"
	FAILED=1
}

# --- fixture -----------------------------------------------------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/swarm-gate-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
printf 'def update(x):\n    return x\n' >"$REPO/ctl.py"
git -C "$REPO" add ctl.py
git -C "$REPO" commit -q -m "initial"

STUB="$WORK/stub"
LEDGER="$WORK/ledger.jsonl"
mkdir -p "$STUB"

clean_table() {
	cat <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
COVERAGE: ctl.py
NOT CHECKED: nothing
EOF
}

sev2_table() {
	cat <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | ctl.py:2 (update) | the prior is overwritten before the gain reads it | update(P=I) for 50 steps | keep the prior covariance |
COVERAGE: ctl.py
NOT CHECKED: nothing
EOF
}

sev1_table_other() {
	cat <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C2 | SEV1 | ctl.py:1 (update) | return value is discarded and the caller dereferences None | update(x=None) | propagate the value |
COVERAGE: ctl.py
NOT CHECKED: nothing
EOF
}

sev3_table() {
	cat <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| Q1 | SEV3 | ctl.py:2 (update) | the branch is fragile if x is a tuple | x=(1,) | guard the type |
COVERAGE: ctl.py
NOT CHECKED: nothing
EOF
}

no_table() {
	cat <<'EOF'
I reviewed ctl.py and it looks reasonable overall. Nothing jumped out at me.
EOF
}

set_lane() { # <lane> <function>
	"$2" >"$STUB/$1.md"
}

dirty() { printf 'def update(x):\n    return x + 1\n' >"$REPO/ctl.py"; }

gate() { # <expected exit> <label> [args...]
	local want=$1 label=$2
	shift 2
	# Each case is independent unless it is deliberately continuing a change set:
	# the round counter is the ledger's, so a leftover ledger silently changes the
	# expected exit (a dedupe case reported round 4/3 before this was made explicit).
	[ "${KEEP_LEDGER:-0}" = 1 ] || rm -f "$LEDGER"
	PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" \
		"$GATE" --repo "$REPO" --ledger "$LEDGER" "$@" >"$WORK/out" 2>"$WORK/err"
	local got=$?
	if [ "$got" = "$want" ]; then
		pass "$label -> exit $got"
	else
		fail "$label -> exit $got (wanted $want)"
		sed 's/^/      /' "$WORK/out" | head -12
		sed 's/^/      err: /' "$WORK/err" | head -5
	fi
}

assert_contains() { # <label> <text>
	if grep -qF -- "$2" "$WORK/out"; then
		pass "$1"
	else
		fail "$1 — output does not contain: $2"
		head -20 "$WORK/out" | sed 's/^/      /'
	fi
}

# --- cases -------------------------------------------------------------------

dirty

set_lane correctness clean_table
set_lane quality clean_table
gate 0 "both lanes clean" --lanes correctness,quality

set_lane correctness sev2_table
set_lane quality clean_table
gate 1 "one SEV2 blocks"
assert_contains "SEV2 row is reported with file:line" "ctl.py:2 (update)"
assert_contains "the verdict names the policy" "sev1/2 present"

set_lane correctness sev3_table
set_lane quality clean_table
gate 0 "SEV3 only does not block"
assert_contains "SEV3 is listed for the user" "your call (SEV3-4)"

set_lane correctness sev2_table
set_lane quality sev2_table
gate 1 "both lanes reporting the same row"
assert_contains "duplicate row is merged, not double counted" "[both]"

set_lane correctness no_table
set_lane quality clean_table
gate 5 "a lane with no table is unusable, never clean"
assert_contains "the unusable lane is named" "no table"

# Two location-less rows are two findings, not one: `:0` is not a shared location. This
# came out of the live probe, where a staged artifact was reported without a path.
cat >"$STUB/correctness.md" <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | (no path given) | a committed bytecode artifact bloats every diff | every edit | gitignore it |
| C2 | SEV2 | (repo-level) | no .gitignore exists at all | first generated file | add one |
COVERAGE: repo root
NOT CHECKED: nothing
EOF
set_lane quality clean_table # set_lane would overwrite the heredoc, so write quality directly
clean_table >"$STUB/quality.md"
gate 1 "two location-less rows both block"
rows=$(grep -c "no path:line given" "$WORK/out")
if [ "$rows" = 2 ]; then
	pass "both location-less rows survive dedupe"
else
	fail "location-less rows collapsed into $rows row(s)"
fi

set_lane correctness sev2_table
STUB_FAIL=correctness gate 5 "a failed dispatch is unusable, never clean"

# The loop guard: same change set (HEAD unchanged), same signature, twice.
set_lane correctness sev1_table_other
set_lane quality clean_table
gate 1 "round 1 of the same change set"
KEEP_LEDGER=1 gate 3 "round 2 with the same signature trips the loop guard"
assert_contains "the loop guard explains itself" "loop guard"

# The round budget: same change set, DIFFERENT signature each round, so the signature
# guard stays quiet and only the budget can stop it. --max-rounds is per invocation, so
# every round passes it; the budget is 2, so the third run is the one it refuses.
rm -f "$LEDGER"
set_lane correctness sev2_table
set_lane quality clean_table
gate 1 "budget round 1" --max-rounds 2
printf '| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |\n|----|-----|----------|---------|---------|-----|\n| C9 | SEV2 | ctl.py:3 (update) | a different defect on a different line | x=0 | clamp it |\nCOVERAGE: ctl.py\nNOT CHECKED: nothing\n' >"$STUB/correctness.md"
KEEP_LEDGER=1 gate 1 "budget round 2 (still inside the budget)" --max-rounds 2
printf '| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |\n|----|-----|----------|---------|---------|-----|\n| C4 | SEV2 | ctl.py:4 (update) | a third distinct defect | x=[] | validate it |\nCOVERAGE: ctl.py\nNOT CHECKED: nothing\n' >"$STUB/correctness.md"
KEEP_LEDGER=1 gate 4 "budget round 3 exceeds --max-rounds 2" --max-rounds 2
assert_contains "the budget verdict is explicit" "round budget"

# A clean tree is an empty question, not a pass.
git -C "$REPO" checkout -q -- ctl.py
set_lane correctness clean_table
set_lane quality clean_table
gate 2 "nothing to review is a usage error"

# --json is machine-readable and carries the same verdict.
dirty
set_lane correctness sev2_table
set_lane quality clean_table
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" \
	"$GATE" --repo "$REPO" --ledger "$LEDGER" --json >"$WORK/json.out" 2>"$WORK/json.err"
if python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
assert payload["exit"] == 1, payload["exit"]
assert payload["verdict"] == "sev1/2 present", payload["verdict"]
assert any(f["sev"] == "2" for f in payload["findings"]), payload["findings"]
' "$WORK/json.out" 2>/dev/null; then
	pass "--json carries the verdict and the findings"
else
	fail "--json payload is wrong"
	head -20 "$WORK/json.out" | sed 's/^/      /'
fi

# The ledger is one line per run and keeps the change-set key across rounds.
lines=$(wc -l <"$LEDGER" 2>/dev/null || printf '0')
if [ "$lines" -ge 1 ]; then
	pass "ledger recorded $lines run(s)"
else
	fail "ledger is empty"
fi
if python3 -c '
import json, sys
records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert all("change_set" in r and "round" in r and "verdict" in r for r in records), records
' "$LEDGER" 2>/dev/null; then
	pass "every ledger record carries change_set, round and verdict"
else
	fail "ledger records are malformed"
fi

# --- default storage: review-work/<date>.jsonl, ignored, transcripts kept ----------

REPO2="$WORK/repo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@example.com
git -C "$REPO2" config user.name Test
printf 'def f(x):\n    return x\n' >"$REPO2/lib.py"
git -C "$REPO2" add lib.py
git -C "$REPO2" commit -q -m initial
printf 'def f(x):\n    return x[0]\n' >"$REPO2/lib.py"

set_lane correctness sev2_table
set_lane quality clean_table
# Point the canned rows at this repo's file so the locations stay honest.
sed -i 's/ctl\.py/lib.py/g' "$STUB/correctness.md"

TODAY=$(date +%Y-%m-%d)
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO2" >"$WORK/d.out" 2>"$WORK/d.err"
if [ $? -eq 1 ]; then pass "default run exits 1 on SEV2"; else fail "default run did not exit 1"; fi

if [ -f "$REPO2/review-work/$TODAY.jsonl" ]; then
	pass "ledger defaults to review-work/$TODAY.jsonl"
else
	fail "no review-work/$TODAY.jsonl"
	ls -la "$REPO2" | sed 's/^/      /'
fi

if python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$REPO2/review-work/$TODAY.jsonl" 2>/dev/null; then
	pass "every line in the date file is valid JSON"
else
	fail "date file is not valid JSONL"
fi

if git -C "$REPO2" check-ignore -q "review-work/$TODAY.jsonl"; then
	pass "review-work is gitignored (index stays clean)"
else
	fail "review-work is not ignored — it would be committable"
fi
if [ -z "$(git -C "$REPO2" status --porcelain | grep review-work)" ]; then
	pass "review-work does not appear in git status"
else
	fail "review-work shows up in git status"
fi

if [ -f "$REPO2/review-work/$TODAY/$TODAY-0-r1-correctness.md" ] || ls "$REPO2/review-work/$TODAY"/*correctness*.md >/dev/null 2>&1; then
	pass "lane transcript is kept for the run"
else
	fail "no lane transcript written"
	ls -R "$REPO2/review-work" 2>/dev/null | sed 's/^/      /'
fi
if grep -q 'the prior is overwritten' "$REPO2/review-work/$TODAY"/*correctness*.md 2>/dev/null; then
	pass "transcript holds the lane's own words, not just the parsed row"
else
	fail "transcript does not contain the raw lane output"
fi

# A fix loop that crosses midnight must not reset its counters. Move today's records to
# an older date file so the OLD file is the only source of prior rounds: reading just
# today's file would report round 1 and exit 1, reading across dates trips the guard.
SHA2=$(git -C "$REPO2" rev-parse HEAD)
sig=$(python3 - "$REPO2/review-work/$TODAY.jsonl" <<'PY'
import json, sys
rec = [json.loads(l) for l in open(sys.argv[1]) if l.strip()][-1]
print(rec["signatures"][0] if rec.get("signatures") else "")
PY
)
if [ -n "$sig" ]; then
	pass "the run recorded a SEV1/2 signature"
else
	fail "no signature recorded — the loop guard has nothing to compare"
fi
mv "$REPO2/review-work/$TODAY.jsonl" "$REPO2/review-work/2001-01-01.jsonl"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO2" >"$WORK/cross.out" 2>&1
exit_cross=$?
if [ "$exit_cross" -eq 3 ]; then
	pass "a prior round in another date file still trips the loop guard"
else
	fail "cross-date prior was ignored — the round counter reset (exit $exit_cross)"
	head -6 "$WORK/cross.out" | sed 's/^/      /'
fi
if grep -qF "round 2" "$WORK/cross.out"; then
	pass "the round number counts rounds from the earlier date file"
else
	fail "the round number did not continue across dates"
fi

# --- exit 6: a clean round on an unchanged diff is not a fix -----------------------

REPO3="$WORK/repo3"
mkdir -p "$REPO3"
git -C "$REPO3" init -q -b main
git -C "$REPO3" config user.email t@example.com
git -C "$REPO3" config user.name Test
printf 'def f(x):\n    return x\n' >"$REPO3/m.py"
git -C "$REPO3" add m.py
git -C "$REPO3" commit -q -m initial
printf 'def f(x):\n    return x[0]\n' >"$REPO3/m.py"

run3() { # <expected exit> <label>
	local want=$1 label=$2 got
	PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO3" >"$WORK/r3.out" 2>&1
	got=$?
	if [ "$got" = "$want" ]; then pass "$label -> exit $got"; else fail "$label -> exit $got (wanted $want)"; head -8 "$WORK/r3.out" | sed 's/^/      /'; fi
}

cat >"$STUB/correctness.md" <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | m.py:2 (f) | indexing a scalar raises (verified: f(1) raises TypeError) | f(1) | guard the type |
COVERAGE: m.py
NOT CHECKED: nothing
EOF
clean_table >"$STUB/quality.md"
run3 1 "round 1 blocks"

# Nothing changes and the lanes find nothing: the reviewer sampled differently. Refuse it.
clean_table >"$STUB/correctness.md"
run3 6 "round 2 clean on an UNCHANGED diff is refused (exit 6)"
if grep -qF "not reproducible" "$WORK/r3.out"; then pass "the refusal says why"; else fail "no reason printed"; fi

# A third clean round on the same unchanged diff stays refused, it does not decay to 0.
run3 6 "round 3 still refuses the unchanged diff"

# Now the code actually changes: a clean round is a real result.
printf 'def f(x):\n    return x if not isinstance(x, int) else x[0]\n' >"$REPO3/m.py"
run3 0 "a clean round after a real change is a pass"

# --- provenance: a label, never a dismissal ----------------------------------------

REPO4="$WORK/repo4"
mkdir -p "$REPO4"
git -C "$REPO4" init -q -b main
git -C "$REPO4" config user.email t@example.com
git -C "$REPO4" config user.name Tests
printf 'a=1\n' >"$REPO4/p.py"
git -C "$REPO4" add p.py && git -C "$REPO4" commit -q -m initial
printf 'a=2\n' >"$REPO4/p.py"

provenance_of() { # <label> <expected-substring>
	if grep -qF -- "$2" "$WORK/p.out"; then pass "$1"; else fail "$1 — no '$2'"; head -14 "$WORK/p.out" | sed 's/^/      /'; fi
}

cat >"$STUB/correctness.md" <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV1 | p.py:1 (module) | an executed defect (verified: ran it, it raised) | ran it and it raised | fix it |
| C2 | SEV2 | p.py:2 (module) | an argued defect, nobody ran it (UNVERIFIED) | a caller that may exist | fix it |
COVERAGE: p.py
NOT CHECKED: nothing
EOF
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO4" >"$WORK/p.out" 2>&1
provenance_of "a row the lane executed is labelled verified" "[verified]"
provenance_of "a row nobody executed is labelled single-sample, unexecuted" "[single-sample, unexecuted]"

# A finding reported in two rounds must be labelled as repeated, not single-sample.
cat >"$STUB/correctness.md" <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | p.py:2 (module) | the same argued defect twice (UNVERIFIED) | a caller that may exist | fix it |
COVERAGE: p.py
NOT CHECKED: nothing
EOF
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO4" >"$WORK/p2.out" 2>&1
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO4" >"$WORK/p3.out" 2>&1
# Three runs of the same location: rounds 2 and 3 must both say repeated, and the count
# must be the number of rounds the LOCATION was flagged in (not the sentence).
if grep -qF "[repeated x3]" "$WORK/p3.out"; then
	pass "a finding seen in a second round is labelled repeated"
else
	fail "a repeated finding was not labelled"
	head -12 "$WORK/p3.out" | sed 's/^/      /'
fi
# The guard must trip on a REWORDED finding at the same location — the case dogfooding
# found the sentence-hash guard missing.
cat >"$STUB/correctness.md" <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | p.py:2 (module) | completely different wording for the same spot (UNVERIFIED) | same caller | fix it |
COVERAGE: p.py
NOT CHECKED: nothing
EOF
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO4" >"$WORK/p4.out" 2>&1
exit_reword=$?
if [ "$exit_reword" -eq 3 ]; then
	pass "a reworded finding at the same location still trips the loop guard"
else
	fail "reworded repeat at the same location was not caught (exit $exit_reword)"
	head -10 "$WORK/p4.out" | sed 's/^/      /'
fi

# A ledger written BEFORE the lineprints field must still count: the guard derives the
# locations from the findings each record already carries. (Live: rounds 1-2 of a real
# change set predated the field and the guard stayed quiet on a thrice-flagged line.)
REPO5="$WORK/repo5"
mkdir -p "$REPO5"
git -C "$REPO5" init -q -b main
git -C "$REPO5" config user.email t@example.com
git -C "$REPO5" config user.name Test
printf 'x=1\n' >"$REPO5/q.py"
git -C "$REPO5" add q.py && git -C "$REPO5" commit -q -m initial
printf 'x=2\n' >"$REPO5/q.py"
LEGACY="$WORK/legacy.jsonl"
SHA5=$(git -C "$REPO5" rev-parse HEAD)
printf '{"change_set": "%s", "round": 1, "verdict": "sev1/2 present", "exit": 1, "diff_sha": "d", "findings": [{"sev": "2", "path": "q.py", "line": 1, "lane": "correctness"}]}\n' "$SHA5" >"$LEGACY"
cat >"$STUB/correctness.md" <<'EOF'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | q.py:1 (module) | a fresh wording for the same flagged location | any call | fix it |
COVERAGE: q.py
NOT CHECKED: nothing
EOF
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO5" --ledger "$LEGACY" >"$WORK/legacy.out" 2>&1
exit_legacy=$?
if [ "$exit_legacy" -eq 3 ]; then
	pass "a pre-lineprints ledger still feeds the loop guard (derived from findings)"
else
	fail "legacy ledger was ignored by the guard (exit $exit_legacy)"
	head -8 "$WORK/legacy.out" | sed 's/^/      /'
fi

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
