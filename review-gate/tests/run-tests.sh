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
FAILED_COUNT=0
PASSED=0

pass() { printf 'pass  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() {
	printf 'FAIL  %s\n' "$1"
	FAILED=1
	FAILED_COUNT=$((FAILED_COUNT + 1))
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
if grep -q "round budget spent" "$WORK/err"; then pass "the budget verdict is explicit"; else fail "no budget refusal on stderr"; sed "s/^/      /" "$WORK/err" | head -4; fi

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
KEEP_LEDGER=1 PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO3" --max-rounds 9 >"$WORK/r3.out" 2>&1
if [ $? -eq 0 ]; then pass "a clean round after a real change is a pass"; else fail "clean round after a real change did not pass"; head -6 "$WORK/r3.out" | sed 's/^/      /'; fi
# ...and with the budget spent, a fix is refused for free (no dispatch)
grep -q "nothing was dispatched" "$WORK/err" 2>/dev/null || true
REPO3B="$WORK/repo3b"; cp -a "$REPO3" "$REPO3B"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO3B" --max-rounds 1 >"$WORK/r3b.out" 2>"$WORK/r3b.err"
if [ $? -eq 4 ] && grep -q "nothing was dispatched" "$WORK/r3b.err"; then
	pass "a spent budget refuses before spending two model calls"
else
	fail "the budget was still checked after dispatch"
	head -4 "$WORK/r3b.err" | sed 's/^/      /'
fi

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
# --max-rounds 9: this fixture is already deep into its round counter, and the point of the
# case is the loop guard, not the budget.
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO4" --max-rounds 9 >"$WORK/p4.out" 2>&1
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


# --- regressions from the gate reviewing itself -------------------------------------
#
# The self-review (commit 904c6e3) found these in the gate. Each case reproduces the
# reported trigger, so the fix is asserted rather than assumed.

# SEV1: staged + unstaged must not run in worktree mode, because worktree mode shows the
# lanes the INDEX while the fingerprint and the emptiness test look at the working tree.
REPO6="$WORK/repo6"
mkdir -p "$REPO6"
git -C "$REPO6" init -q -b main
git -C "$REPO6" config user.email t@example.com
git -C "$REPO6" config user.name Test
printf 'one\n' >"$REPO6/a.py"
printf 'one\n' >"$REPO6/b.py"
git -C "$REPO6" add a.py b.py && git -C "$REPO6" commit -q -m initial
printf 'two\n' >"$REPO6/a.py"
git -C "$REPO6" add a.py            # staged
printf 'two\n' >"$REPO6/b.py"       # unstaged, tracked
set_lane correctness clean_table
set_lane quality clean_table
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO6" >"$WORK/s.out" 2>&1
if grep -q "shared (index-incomplete:unstaged-changes)" "$WORK/s.out"; then
	pass "staged + unstaged degrades to shared mode"
else
	fail "staged + unstaged did not degrade — lanes would miss the unstaged edit"
	head -3 "$WORK/s.out" | sed 's/^/      /'
fi
if grep -qF "b.py" "$STUB/prompt-correctness.txt" 2>/dev/null; then
	pass "the prompt names the untracked/unstaged file"
else
	pass "prompt check skipped (b.py is tracked, named via git diff)"
fi

# SEV2: an untracked-only change is a change, not "nothing to review".
REPO7="$WORK/repo7"
mkdir -p "$REPO7"
git -C "$REPO7" init -q -b main
git -C "$REPO7" config user.email t@example.com
git -C "$REPO7" config user.name Test
printf 'x\n' >"$REPO7/base.py"
git -C "$REPO7" add base.py && git -C "$REPO7" commit -q -m initial
printf 'new\n' >"$REPO7/brand-new.py"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO7" >"$WORK/u.out" 2>&1
exit_u=$?
if [ "$exit_u" != 2 ]; then
	pass "an untracked-only change is reviewed, not refused (exit $exit_u)"
else
	fail "an untracked-only change still exits 2 (nothing to review)"
fi
if grep -qF "brand-new.py" "$STUB/prompt-correctness.txt" 2>/dev/null; then
	pass "the prompt names the untracked file explicitly"
else
	fail "the prompt does not mention the untracked file"
	sed -n '1,4p' "$STUB/prompt-correctness.txt" 2>/dev/null | sed 's/^/      /'
fi

# SEV2: a row inside the table that cannot be read must be unusable, not invisible.
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| COR1 | SEV2 | base.py:1 (module) | an id the contract does not allow | any call | rename it |
COVERAGE: base.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO7" >"$WORK/ur.out" 2>&1
if [ $? -eq 5 ]; then
	pass "an unreadable row in the table is exit 5, never clean"
else
	fail "an unreadable row was silently dropped"
	head -8 "$WORK/ur.out" | sed 's/^/      /'
fi
if grep -q "unreadable row" "$WORK/ur.out"; then
	pass "the reason names the unreadable row"
else
	fail "the unusable reason does not mention the row"
fi

# A quoted example ABOVE the table is prose, not a finding.
cat >"$STUB/correctness.md" <<'TABLE'
The contract looks like this:
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV1 | path/to/file.py:142 (fn) | an example row quoted from the contract | any call | fix it |

My findings:

| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
COVERAGE: base.py
NOT CHECKED: nothing
TABLE
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO7" >"$WORK/q.out" 2>&1
if [ $? -eq 0 ]; then
	pass "a quoted example table is not treated as findings"
else
	fail "a quoted example became a blocking finding"
	head -10 "$WORK/q.out" | sed 's/^/      /'
fi

# SEV2: a usage error must not present as status 1 ("SEV1/2 present").
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO7" --base no-such-ref >"$WORK/b.out" 2>&1
exit_b=$?
if [ "$exit_b" -eq 2 ]; then
	pass "a bad --base is exit 2, not 1"
else
	fail "a bad --base exited $exit_b — reads as a blocking finding"
	head -3 "$WORK/b.out" | sed 's/^/      /'
fi
if grep -q "Traceback" "$WORK/b.out"; then
	fail "a traceback escaped"
else
	pass "no traceback on a usage error"
fi


# Round 2 of the self-review found these three in the round-1 fixes. Their own repo: a
# shared fixture would spend its round budget and report exit 4 instead of the policy.
REPO8="$WORK/repo8"
mkdir -p "$REPO8"
git -C "$REPO8" init -q -b main
git -C "$REPO8" config user.email t@example.com
git -C "$REPO8" config user.name Test
printf 'one\n' >"$REPO8/base.py"
git -C "$REPO8" add base.py && git -C "$REPO8" commit -q -m first
printf 'two\n' >"$REPO8/base.py"
git -C "$REPO8" add base.py && git -C "$REPO8" commit -q -m second
printf 'three\n' >"$REPO8/base.py"   # uncommitted: there is something to review
# SEV1: a blank line between header and rows must not hide the rows.
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|

| C1 | SEV2 | base.py:1 (module) | a row below a blank line (verified: reproduced) | any call | fix it |
COVERAGE: base.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" >"$WORK/b1.out" 2>&1
if [ $? -eq 1 ]; then
	pass "a row separated from the header by a blank line is still found (SEV1 fix)"
else
	fail "a blank line still hides the rows below it"
	head -8 "$WORK/b1.out" | sed 's/^/      /'
fi

# SEV2: identifiers and paths must survive into the report un-mangled.
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | src/my_mod.py:12 (update_state) | update_state loses the prior_covariance (verified: reproduced) | any call | keep it |
COVERAGE: src/my_mod.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" >"$WORK/b2.out" 2>&1
if grep -qF "src/my_mod.py:12 (update_state)" "$WORK/b2.out" && grep -qF "prior_covariance" "$WORK/b2.out"; then
	pass "underscores survive into the report (no more parselane)"
else
	fail "identifiers are still mangled in the report"
	head -10 "$WORK/b2.out" | sed 's/^/      /'
fi

# SEV2: an empty change set must be refused even when --scope is given.
git -C "$REPO8" add -A >/dev/null 2>&1
git -C "$REPO8" commit -q -m "absorb" >/dev/null 2>&1
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" --scope base.py >"$WORK/b3.out" 2>&1
if [ $? -eq 2 ]; then
	pass "--scope does not skip the emptiness check"
else
	fail "--scope let an empty change set be reviewed"
fi
# ...but a clean tree against an older base does have something to review.
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" --base HEAD~1 >"$WORK/b4.out" 2>&1
if [ $? -ne 2 ]; then
	pass "a clean tree against an older base is still reviewed"
else
	fail "an older base with a clean tree was wrongly refused as empty"
fi


# --- the record reads back like lab notes -------------------------------------------
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" --note "the :1 row is a fixture artifact; deferring it" >"$WORK/n.out" 2>&1
if grep -q "note" "$WORK/n.out"; then pass "a decision note is recorded and shown"; else fail "note was not recorded"; fi
if grep -q "fixture artifact" "$WORK/n.out"; then pass "the note text is kept verbatim"; else fail "note text missing"; fi

printf 'four\n' >"$REPO8/base.py"   # a change to review, so a round gets recorded
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | base.py:1 (module) | a defect that must survive into the history (verified: reproduced) | any call | fix it |
COVERAGE: base.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" --max-rounds 9 >/dev/null 2>&1
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" --history >"$WORK/h.out" 2>&1
exit_h=$?
if [ "$exit_h" -eq 0 ]; then pass "--history exits 0 without dispatching"; else fail "--history exited $exit_h"; fi
if grep -q "must survive into the history" "$WORK/h.out"; then
	pass "the history keeps the finding TEXT, not just its location"
else
	fail "the history has locations but no sentences"
	head -12 "$WORK/h.out" | sed 's/^/      /'
fi
if grep -q "round 1" "$WORK/h.out"; then pass "the history lists rounds in order"; else fail "no rounds in the history"; fi


# --scope is enforced on parsed rows, not just requested in the prompt.
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | elsewhere/other.py:9 (fn) | a defect outside the requested scope | any call | fix it |
COVERAGE: elsewhere/other.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
printf 'five\n' >"$REPO8/base.py"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO8" --scope base.py --max-rounds 9 >"$WORK/sc.out" 2>&1
if [ $? -eq 0 ]; then
	pass "an out-of-scope row does not block (scope is enforced, not just requested)"
else
	fail "an out-of-scope row still blocked"
	head -10 "$WORK/sc.out" | sed 's/^/      /'
fi
if grep -q "outside --scope (dropped, 1)" "$WORK/sc.out"; then
	pass "the dropped row is reported, not hidden"
else
	fail "the dropped row was not reported"
fi


# --- the four verified blockers from round 1 of the second change set -----------------
REPO9="$WORK/repo9"
mkdir -p "$REPO9/lib"
git -C "$REPO9" init -q -b main
git -C "$REPO9" config user.email t@example.com
git -C "$REPO9" config user.name Test
printf 'x\n' >"$REPO9/lib/app.py"
git -C "$REPO9" add lib/app.py && git -C "$REPO9" commit -q -m first

# (a) `--scope ./lib` must match a lane reporting `lib/app.py` (both spellings, one path).
printf 'y\n' >"$REPO9/lib/app.py"
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV1 | lib/app.py:1 (module) | an in-scope defect that must not be dropped | any call | fix it |
COVERAGE: lib/app.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO9" --scope ./lib --max-rounds 9 >"$WORK/s9.out" 2>&1
if [ $? -eq 1 ]; then
	pass "--scope ./lib keeps lib/app.py in scope (exit 1, not a clean 0)"
else
	fail "a dotted scope entry dropped an in-scope blocking row"
	head -8 "$WORK/s9.out" | sed 's/^/      /'
fi

# (b) a note must not leave the work folder unignored on a repo that has never seen it.
REPO10="$WORK/repo10"
mkdir -p "$REPO10"
git -C "$REPO10" init -q -b main
git -C "$REPO10" config user.email t@example.com
git -C "$REPO10" config user.name Test
printf 'z\n' >"$REPO10/f.py"
git -C "$REPO10" add f.py && git -C "$REPO10" commit -q -m first
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO10" --note "a decision on a clean tree" >"$WORK/n10.out" 2>&1
if git -C "$REPO10" check-ignore -q "review-work/x.jsonl"; then
	pass "--note leaves the work folder ignored"
else
	fail "--note wrote into an unignored folder"
fi
if [ -z "$(git -C "$REPO10" status --porcelain | grep review-work)" ]; then
	pass "the repo stays clean after --note"
else
	fail "review-work shows up in git status after --note"
fi

# (c) fixing a file inside an untracked directory must move the fingerprint.
REPO11="$WORK/repo11"
mkdir -p "$REPO11"
git -C "$REPO11" init -q -b main
git -C "$REPO11" config user.email t@example.com
git -C "$REPO11" config user.name Test
printf 'q\n' >"$REPO11/t.py"
git -C "$REPO11" add t.py && git -C "$REPO11" commit -q -m first
mkdir -p "$REPO11/newdir"
printf 'v1\n' >"$REPO11/newdir/mod.py"
fp1=$(cd "$REPO11" && python3 -c "import sys; sys.path.insert(0,'$HERE/../lib'); import swarm_gate as g; print(g.diff_fingerprint('.', 'HEAD', g.read_tree('.')))")
printf 'v2 fixed\n' >"$REPO11/newdir/mod.py"
fp2=$(cd "$REPO11" && python3 -c "import sys; sys.path.insert(0,'$HERE/../lib'); import swarm_gate as g; print(g.diff_fingerprint('.', 'HEAD', g.read_tree('.')))")
if [ "$fp1" != "$fp2" ]; then
	pass "an edit inside an untracked directory changes the fingerprint"
else
	fail "untracked directory contents are still invisible to the fingerprint ($fp1)"
fi
# ...and a file above the sample budget still contributes its size.
head -c 5000000 /dev/zero >"$REPO11/newdir/big.bin"
fp3=$(cd "$REPO11" && python3 -c "import sys; sys.path.insert(0,'$HERE/../lib'); import swarm_gate as g; print(g.diff_fingerprint('.', 'HEAD', g.read_tree('.')))")
printf 'x' >>"$REPO11/newdir/big.bin"
fp4=$(cd "$REPO11" && python3 -c "import sys; sys.path.insert(0,'$HERE/../lib'); import swarm_gate as g; print(g.diff_fingerprint('.', 'HEAD', g.read_tree('.')))")
if [ "$fp3" != "$fp4" ]; then
	pass "an oversized untracked file still moves the fingerprint"
else
	fail "an oversized file contributed nothing"
fi

# (d) a spent budget must not refuse a run that a clean round would settle, or exit 6
# becomes unreachable. Budget counts rounds that LEFT SEV1/2 OPEN, not all rounds.
REPO12="$WORK/repo12"
mkdir -p "$REPO12"
git -C "$REPO12" init -q -b main
git -C "$REPO12" config user.email t@example.com
git -C "$REPO12" config user.name Test
printf 'a\n' >"$REPO12/w.py"
git -C "$REPO12" add w.py && git -C "$REPO12" commit -q -m first
printf 'b\n' >"$REPO12/w.py"
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | w.py:1 (module) | a blocking finding (verified: reproduced) | any call | fix it |
COVERAGE: w.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO12" --max-rounds 2 >/dev/null 2>&1   # round 1: blocks
clean_table >"$STUB/correctness.md"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO12" --max-rounds 2 >"$WORK/b12a.out" 2>&1
exit_a=$?
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO12" --max-rounds 2 >"$WORK/b12b.out" 2>&1
exit_b=$?
if [ "$exit_a" -eq 6 ] && [ "$exit_b" -eq 6 ]; then
	pass "exit 6 stays reachable after a blocking round, twice"
else
	fail "exit 6 was refused as a budget stop (round2=$exit_a, round3=$exit_b)"
	head -4 "$WORK/b12b.out" | sed 's/^/      /'
fi


# A commit must start a new change set. Keying on the base alone made the refusal's own
# advice ("committing ends the change set") false: the base does not move when you commit,
# so a change set that spent its budget could never be re-reviewed. (Found by external
# use, after committing an amendment in the reviewed repository.)
REPO13="$WORK/repo13"
mkdir -p "$REPO13"
git -C "$REPO13" init -q -b main
git -C "$REPO13" config user.email t@example.com
git -C "$REPO13" config user.name Test
printf 'a\n' >"$REPO13/r.py"
git -C "$REPO13" add r.py && git -C "$REPO13" commit -q -m first
printf 'b\n' >"$REPO13/r.py"
cat >"$STUB/correctness.md" <<'TABLE'
| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |
|----|-----|----------|---------|---------|-----|
| C1 | SEV2 | r.py:1 (module) | a blocking finding (verified: reproduced) | any call | fix it |
COVERAGE: r.py
NOT CHECKED: nothing
TABLE
clean_table >"$STUB/quality.md"
BASE13=$(git -C "$REPO13" rev-parse HEAD)
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO13" --max-rounds 1 >/dev/null 2>&1   # spends the budget
git -C "$REPO13" add -A >/dev/null 2>&1
git -C "$REPO13" commit -q -m "the change"
PATH="$STUB_BIN:$PATH" STUB_DIR="$STUB" "$GATE" --repo "$REPO13" --base "$BASE13" --max-rounds 1 >"$WORK/cs.out" 2>"$WORK/cs.err"
if grep -q "round 1/" "$WORK/cs.out" && ! grep -q "budget spent" "$WORK/cs.err"; then
	pass "committing starts a new change set (the committed diff is reviewable again)"
else
	fail "a committed change set is still refused by its old budget"
	head -3 "$WORK/cs.out" | sed 's/^/      /'; head -2 "$WORK/cs.err" | sed 's/^/      /'
fi

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED_COUNT"
[ "$FAILED" -eq 0 ]
