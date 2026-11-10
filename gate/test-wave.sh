#!/usr/bin/env bash
# test-wave.sh — self-test for gate/wave.sh in a throwaway repo, with a stub lane runner.
#
#   ./gate/test-wave.sh
#
# No model and no network: the "agent" is a stub script, so what is verified is the
# orchestration — level selection, parallelism cap, worktree isolation, and the three
# per-lane refusals (scope, no-test, green-at-base).
set -euo pipefail

WAVE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wave.sh"
REPO="$(mktemp -d "${TMPDIR:-/tmp}/wave-selftest-XXXXXX")"
STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wave-stubs-XXXXXX")"
WTROOT="$(mktemp -d "${TMPDIR:-/tmp}/wave-wt-XXXXXX")"
mkdir -p "$WTROOT/a" "$WTROOT/b" "$WTROOT/c" "$WTROOT/d" "$WTROOT/e"
failures=0
ok() {
	if [ "$2" = 1 ]; then
		printf '  ok    %s\n' "$1"
	else
		failures=$((failures + 1))
		printf '  FAIL  %s%s\n' "$1" "${3:+ — $3}"
	fi
}

cleanup() {
	git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' |
		tail -n +2 | while read -r w; do git -C "$REPO" worktree remove --force "$w" 2>/dev/null || true; done
	rm -rf "$REPO" "$STUB_DIR" "$WTROOT"
}
trap cleanup EXIT

# --- throwaway repo: a "suite" that is red only once tests/fail.flag exists -----
cd "$REPO"
git init -q .
git config user.email t@invalid
git config user.name t
git config commit.gpgsign false
mkdir -p tests src gate
printf 'value = 1\n' >src/app.py
printf 'def test_existing():\n    assert True\n' >tests/test_existing.py
cat >gate/run-tests.sh <<'SH'
#!/usr/bin/env bash
# Stand-in for the canonical command: exit nonzero (red) iff the lane produced a
# failing test. pytest exits nonzero on failure; this mirrors that, not the reverse.
test ! -f tests/fail.flag
SH
chmod +x gate/run-tests.sh
git add -A
git commit -qm init
BASE="$(git rev-parse HEAD)"

LEDGER="$REPO/ledger.md"
cat >"$LEDGER" <<'MD'
# Ledger

| id | level | requirement | design | interface | tests | evidence | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | L3 | add(a,b) returns a+b | direct sum | none | test_add | run-tests | proved |
| R2 | L3 | sub(a,b) returns a-b | direct difference | none | test_sub | run-tests | proved |
| R3 | L2 | pipeline composes add then sub | sequential | ports unchanged | test_pipeline | run-tests | proved |
MD

# --- stub lanes ---------------------------------------------------------------
cat >"$STUB_DIR/good" <<'SH'
#!/usr/bin/env bash
wt="$1"
printf 'def test_x():\n    assert False\n' >"$wt/tests/test_lane.py"
touch "$wt/tests/fail.flag"
SH
cat >"$STUB_DIR/out-of-scope" <<'SH'
#!/usr/bin/env bash
wt="$1"
printf 'def test_x():\n    assert False\n' >"$wt/tests/test_lane.py"
touch "$wt/tests/fail.flag"
printf 'x = 1\n' >"$wt/src/helper.py"
SH
cat >"$STUB_DIR/no-test" <<'SH'
#!/usr/bin/env bash
: # writes nothing
SH
cat >"$STUB_DIR/green" <<'SH'
#!/usr/bin/env bash
wt="$1"
printf 'def test_x():\n    assert True\n' >"$wt/tests/test_lane.py"
SH
chmod +x "$STUB_DIR"/*

echo "wave selftest"

# --- parsing ------------------------------------------------------------------
ROWS="$("$WAVE" rows "$LEDGER")"
ok "rows extracts id, level, tests" \
	"$([ "$(printf '%s\n' "$ROWS" | head -1)" = "$(printf 'R1\tL3\ttest_add')" ] && echo 1)" \
	"$(printf '%s' "$ROWS" | head -1)"
ok "rows keeps every row" "$([ "$(printf '%s\n' "$ROWS" | wc -l)" -eq 3 ] && echo 1)"
ok "levels are emitted bottom-up (L3 before L2)" \
	"$([ "$("$WAVE" levels "$LEDGER" | paste -sd, -)" = "L3,L2" ] && echo 1)" \
	"$("$WAVE" levels "$LEDGER" | paste -sd, -)"

# The ledger carries a lane-partition table too (docs/02, examples/). Only the first
# table is rows; a second table must not become rows with a blank level.
cat >>"$LEDGER" <<'MD'

## Lane partition

| lane | rows | write scope |
| --- | --- | --- |
| L1 | R1, R2 | src/ |
| L2 | R3 | tests/ |
MD
ok "a second table in the ledger is not part of the rows" \
	"$([ "$(printf '%s\n' "$("$WAVE" rows "$LEDGER")" | wc -l)" -eq 3 ] && echo 1)" \
	"$("$WAVE" rows "$LEDGER" | tr '\t' ' ' | paste -sd';' -)"
ok "the lane table does not pollute the levels" \
	"$([ "$("$WAVE" levels "$LEDGER" | paste -sd, -)" = "L3,L2" ] && echo 1)" \
	"$("$WAVE" levels "$LEDGER" | paste -sd, -)"

# --- a level selects only its rows, and runs them in parallel ------------------
"$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --width 2 --confirm \
	--root "$WTROOT/a" --child "$STUB_DIR/good" --no-records >"$REPO/out-a.txt" 2>&1 || true
ok "both L3 lanes pass" "$([ "$(grep -c '	ok	' "$REPO/out-a.txt" || true)" -eq 2 ] && echo 1)" "$(cat "$REPO/out-a.txt")"
ok "the L2 row is not run in an L3 wave" "$(! grep -q '^R3' "$REPO/out-a.txt" && echo 1)"
ok "each lane got its own worktree" "$([ -d "$WTROOT/a/R1/tests" ] && [ -d "$WTROOT/a/R2/tests" ] && echo 1)"
ok "worktrees are detached at the base commit" \
	"$([ -f "$WTROOT/a/R1/.git" ] && [ "$(git -C "$WTROOT/a/R1" rev-parse HEAD)" = "$BASE" ] && echo 1)"

# --- refusals -----------------------------------------------------------------
"$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --width 1 --confirm \
	--root "$WTROOT/b" --child "$STUB_DIR/out-of-scope" --no-records >"$REPO/out-b.txt" 2>&1 || true
ok "a write outside tests/ is refused" "$(grep -q 'wrote outside scope: src/helper.py' "$REPO/out-b.txt" && echo 1)" "$(cat "$REPO/out-b.txt")"

"$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --width 1 --confirm \
	--root "$WTROOT/c" --child "$STUB_DIR/no-test" --no-records >"$REPO/out-c.txt" 2>&1 || true
ok "a lane that wrote nothing is refused" "$(grep -q 'no test was created' "$REPO/out-c.txt" && echo 1)" "$(cat "$REPO/out-c.txt")"

"$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --width 1 --confirm \
	--root "$WTROOT/d" --child "$STUB_DIR/green" --no-records >"$REPO/out-d.txt" 2>&1 || true
ok "a green-at-base lane is refused as vacuous" "$(grep -q 'GREEN at' "$REPO/out-d.txt" && echo 1)" "$(cat "$REPO/out-d.txt")"

# --- a failing wave exits nonzero --------------------------------------------
if "$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --width 1 --confirm \
	--root "$WTROOT/e" --child "$STUB_DIR/green" --no-records >/dev/null 2>&1; then
	ok "a wave with a failed lane exits nonzero" 0
else
	ok "a wave with a failed lane exits nonzero" 1
fi

# --- spawning lanes requires the human's confirmation -------------------------
if "$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --width 1 \
	--root "$WTROOT/f" --child "$STUB_DIR/good" --no-records >"$REPO/out-f.txt" 2>&1; then
	ok "sysdv without --confirm is refused" 0
else
	ok "sysdv without --confirm is refused" 1
fi
ok "a refused spawn creates no lane worktree" "$([ ! -d "$WTROOT/f/R1" ] && echo 1)"
ok "the refusal names the confirmation rule" "$(grep -q 'confirmed by the human' "$REPO/out-f.txt" && echo 1)"

# --- a deleted wave root can be reused -----------------------------------------
# A wave root is a temp directory: deleting it leaves the worktrees registered but
# missing, and `git worktree add` refuses that until the registration is pruned.
rm -rf "$WTROOT/a"
"$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --confirm --width 2 \
	--root "$WTROOT/a" --child "$STUB_DIR/good" --no-records >"$REPO/out-g.txt" 2>&1 || true
ok "a deleted wave root is reusable" \
	"$([ "$(grep -cE '[[:space:]]ok[[:space:]]' "$REPO/out-g.txt" || true)" -eq 2 ] && echo 1)" \
	"$(cat "$REPO/out-g.txt")"

# --- argument guards ----------------------------------------------------------
if "$WAVE" sysdv --ledger "$LEDGER" --level L9 --base "$BASE" >/dev/null 2>&1; then
	ok "an empty level is a usage error" 0
else
	ok "an empty level is a usage error" 1
fi
if "$WAVE" sysdv --ledger "$LEDGER" --level L3 --base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1; then
	ok "a bogus base commit is a usage error" 0
else
	ok "a bogus base commit is a usage error" 1
fi

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "all passed" || echo "$failures failed")"
[ "$failures" -eq 0 ]
