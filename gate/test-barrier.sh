#!/usr/bin/env bash
# test-barrier.sh — self-test for the barrier: `wave.sh freeze`, `wave.sh build`, records.
#
#   ./gate/test-barrier.sh
#
# No model and no network: stub sysDV lanes write tests, stub build lanes write source.
# What is verified is the barrier itself — compose refuses two lanes claiming one path,
# the composed suite must be RED at the base, the pin covers the frozen surface, a build
# lane that moves a frozen test is refused, and the composed gate is the only green that
# supports the claim.
set -euo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAVE="$GATE/wave.sh"
LOCK_CHECK="$GATE/lock-check.sh"
REPO="$(mktemp -d "${TMPDIR:-/tmp}/barrier-selftest-XXXXXX")"
STUB="$(mktemp -d "${TMPDIR:-/tmp}/barrier-stubs-XXXXXX")"
WT="$(mktemp -d "${TMPDIR:-/tmp}/barrier-wt-XXXXXX")"
RECORDS="$REPO/records.jsonl"
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
	rm -rf "$REPO" "$STUB" "$WT"
}
trap cleanup EXIT

# --- throwaway repo -----------------------------------------------------------
# The "suite" is red iff a test names a function (`# expects: <name>`) that no file
# under src/ defines. That is the shape of the real thing: red at the base commit
# because the implementation does not exist, green only once the build lane writes it.
cd "$REPO"
git init -q .
git config user.email t@invalid
git config user.name t
git config commit.gpgsign false
mkdir -p tests src gate docs
printf '# no functions yet\n' >src/app.py
printf 'def test_placeholder():\n    assert True\n' >tests/test_placeholder.py
cp "$LOCK_CHECK" gate/lock-check.sh
chmod +x gate/lock-check.sh
cat >gate/run-tests.sh <<'SH'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)"
sel=""
verbose=0
while [ $# -gt 0 ]; do
	case "$1" in
	--collect-only) exit 0 ;;
	-k) sel="${2:-}"; shift 2 ;;
	-v) verbose=1; shift ;;
	*) shift ;;
	esac
done
# `-k "test_add or test_sub"` is the apparatus selecting one row's tests, so the stub
# honours it the same way pytest does: only the named tests are in this run.
names=""
[ -n "$sel" ] && names="$(printf '%s' "$sel" | sed 's/test_//g; s/ or /|/g')"
rc=0
for t in tests/test_*.py; do
	[ -f "$t" ] || continue
	if [ -n "$names" ] && ! grep -Eq "def test_(${names})\\(" "$t"; then continue; fi
	# `# vacuous: yes` is a test that passes at the base commit on purpose, so the
	# barrier's per-test vacuity check has something to catch.
	if grep -qx '# vacuous: yes' "$t"; then
		[ "$verbose" = 1 ] && printf '%s::test_vacuous PASSED\n' "$t"
		continue
	fi
	while IFS= read -r sym; do
		[ -n "$sym" ] || continue
		if grep -rq "^def ${sym}(" src/; then
			[ "$verbose" = 1 ] && printf '%s::test_%s PASSED\n' "$t" "$sym"
		else
			[ "$verbose" = 1 ] && printf '%s::test_%s FAILED\n' "$t" "$sym"
			rc=1
		fi
	done < <(sed -n 's/^# expects: //p' "$t")
done
exit $rc
SH
chmod +x gate/run-tests.sh
git add -A
git commit -qm init
BASE="$(git rev-parse HEAD)"

ledger() { # ledger <file> <rows-markdown>
	{
		printf '# Ledger\n\n'
		printf '| id | level | requirement | design | interface | sources | tests | evidence | verdict |\n'
		printf '| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
		printf '%s\n' "$2"
	} >"$1"
}

LEDGER="$REPO/ledger.md"
ledger "$LEDGER" '| R1 | L3 | add(a,b) returns a+b | direct sum | none | src/app.py | tests/test_R1.py::test_add | ./gate/run-tests.sh | proved |
| R2 | L3 | sub(a,b) returns a-b | direct difference | none | src/math.py | tests/test_R2.py::test_sub | ./gate/run-tests.sh | proved |'

# --- stubs --------------------------------------------------------------------
# sysDV lane: one test file per row, naming the function the row asks for.
cat >"$STUB/sysdv-good" <<'SH'
#!/usr/bin/env bash
wt="$1"; task="$2"
row="$(sed -n 's/^Row: //p' "$task" | head -1)"
case "$row" in
R1) sym=add ;;
R2) sym=sub ;;
*) sym=thing ;;
esac
printf '# expects: %s\ndef test_%s():\n    assert %s(1, 1) is not None\n' "$sym" "$sym" "$sym" >"$wt/tests/test_$row.py"
SH
# Both lanes claim the same test path — a partition failure, not a merge conflict.
cat >"$STUB/sysdv-collide" <<'SH'
#!/usr/bin/env bash
wt="$1"; task="$2"
row="$(sed -n 's/^Row: //p' "$task" | head -1)"
case "$row" in
R2) sym=sub ;;
*) sym=add ;;
esac
printf '# expects: %s\ndef test_%s():\n    assert %s(1, 1)\n' "$sym" "$sym" "$sym" >"$wt/tests/test_shared.py"
SH
# Build lane: implement the row in its declared write scope.
cat >"$STUB/build-good" <<'SH'
#!/usr/bin/env bash
wt="$1"; task="$2"
row="$(sed -n 's/^Row: //p' "$task" | head -1)"
scope="$(sed -n 's/^Write scope: //p' "$task" | head -1 | awk '{print $1}')"
case "$row" in
R1) sym=add; op='+' ;;
R2) sym=sub; op='-' ;;
*) sym=thing; op='+' ;;
esac
# A directory scope (`src/`, or `src` once the trail slash is stripped) means the
# lane may create files under it.
case "$scope" in
*/) dest="${scope}impl.py" ;;
*) if [ -d "$wt/$scope" ]; then dest="$scope/impl.py"; else dest="$scope"; fi ;;
esac
printf '\ndef %s(a, b):\n    return a %s b\n' "$sym" "$op" >>"$wt/$dest"
SH
# Build lane that edits the frozen test — the cheapest route to green, and refused.
cat >"$STUB/build-drift" <<'SH'
#!/usr/bin/env bash
wt="$1"; task="$2"
row="$(sed -n 's/^Row: //p' "$task" | head -1)"
scope="$(sed -n 's/^Write scope: //p' "$task" | head -1 | awk '{print $1}')"
case "$row" in
R1) sym=add; op='+' ;;
*) sym=sub; op='-' ;;
esac
printf '\ndef %s(a, b):\n    return a %s b\n' "$sym" "$op" >>"$wt/$scope"
printf '\n# make it pass\n' >>"$wt/tests/test_$row.py"
SH
# Build lane that also writes outside its row's sources.
cat >"$STUB/build-outside" <<'SH'
#!/usr/bin/env bash
wt="$1"; task="$2"
row="$(sed -n 's/^Row: //p' "$task" | head -1)"
scope="$(sed -n 's/^Write scope: //p' "$task" | head -1 | awk '{print $1}')"
case "$row" in
R1) sym=add; op='+' ;;
*) sym=sub; op='-' ;;
esac
printf '\ndef %s(a, b):\n    return a %s b\n' "$sym" "$op" >>"$wt/$scope"
printf 'import os\n' >"$wt/src/outside.py"
SH
chmod +x "$STUB"/*

echo "barrier selftest"

# --- wave 1: sysDV lanes, red at the base ------------------------------------
"$WAVE" sysdv --ledger "$LEDGER" --level L3 --base "$BASE" --confirm --width 2 \
	--root "$WT/sysdv" --child "$STUB/sysdv-good" >"$REPO/a1.txt" 2>&1 || true
ok "wave 1: both lanes are red at the base" \
	"$([ "$(grep -c '	ok	' "$REPO/a1.txt" || true)" -eq 2 ] && echo 1)" "$(cat "$REPO/a1.txt")"
ok "wave 1 appended a red record per row" \
	"$([ "$(grep -c 'red_recorded' "$RECORDS" || true)" -eq 2 ] && echo 1)"
ok "the recorded red names the base commit" \
	"$(grep -q "\"base\":\"$BASE\"" "$RECORDS" && echo 1)"
ok "the recorded red carries the row's requirement" \
	"$(grep -q 'add(a,b) returns a+b' "$RECORDS" && echo 1)"

# --- the barrier: freeze ------------------------------------------------------
"$WAVE" freeze --ledger "$LEDGER" --level L3 --base "$BASE" --root "$WT/sysdv" \
	>"$REPO/a2.txt" 2>&1 || true
PIN="$(tail -1 "$REPO/a2.txt")"
ok "freeze prints the pin as its last line" \
	"$([ "$(git -C "$REPO" cat-file -t "$PIN" 2>/dev/null || true)" = commit ] && echo 1)" "$(cat "$REPO/a2.txt")"
ok "the pin contains both lanes' tests" \
	"$(git -C "$REPO" cat-file -e "$PIN:tests/test_R1.py" 2>/dev/null &&
		git -C "$REPO" cat-file -e "$PIN:tests/test_R2.py" 2>/dev/null && echo 1)"
ok "the pin is a child of the pre-implementation commit" \
	"$([ "$(git -C "$REPO" rev-parse "$PIN^")" = "$BASE" ] && echo 1)"
ok "the freeze commit names the rows it freezes" \
	"$(git -C "$REPO" log -1 --format=%s "$PIN" | grep -q 'R1,R2' && echo 1)" \
	"$(git -C "$REPO" log -1 --format=%s "$PIN")"
ok "the pin covers the canonical command" \
	"$(git -C "$REPO" cat-file -e "$PIN:gate/run-tests.sh" 2>/dev/null && echo 1)"
ok "lock-check is clean at the pin" \
	"$(cd "$WT/sysdv/compose" && ./gate/lock-check.sh "$PIN" >/dev/null 2>&1 && echo 1)"
ok "freeze recorded the pin for both rows" \
	"$([ "$(grep -c "\"pin\":\"$PIN\"" "$RECORDS" || true)" -eq 2 ] && echo 1)"

# --- wave 2: locked build lanes + the composed gate ---------------------------
"$WAVE" build --ledger "$LEDGER" --level L3 --pin "$PIN" --confirm --width 2 \
	--root "$WT/build" --child "$STUB/build-good" >"$REPO/a3.txt" 2>&1 || true
ok "wave 2: both lanes are green at the pin" \
	"$([ "$(grep -c '	ok	' "$REPO/a3.txt" || true)" -eq 2 ] && echo 1)" "$(cat "$REPO/a3.txt")"
ok "the composed gate ran once, serially, and went green" \
	"$(grep -q 'composed gate green' "$REPO/a3.txt" && echo 1)"
ok "the composed tree contains both lanes' source changes" \
	"$(grep -q 'def add' "$WT/build/compose/src/app.py" 2>/dev/null &&
		grep -q 'def sub' "$WT/build/compose/src/math.py" 2>/dev/null && echo 1)"
ok "the composed tree's frozen surface is unchanged" \
	"$(cd "$WT/build/compose" && ./gate/lock-check.sh "$PIN" >/dev/null 2>&1 && echo 1)"

# --- the trail is append-only and readable -----------------------------------
"$WAVE" records "$RECORDS" >"$REPO/a4.txt" 2>"$REPO/a4.err"
ok "records shows the latest state per row, not one line per event" \
	"$([ "$(wc -l <"$REPO/a4.txt")" -eq 2 ] && echo 1)" "$(cat "$REPO/a4.txt")"
ok "the latest record is gate_green" \
	"$([ "$(grep -c 'gate_green' "$REPO/a4.txt" || true)" -eq 2 ] && echo 1)" "$(cat "$REPO/a4.txt")"
LINES_BEFORE="$(grep -c '' "$RECORDS" || true)"
printf 'this is not json\n' >>"$RECORDS"
"$WAVE" records "$RECORDS" >"$REPO/a5.txt" 2>"$REPO/a5.err"
ok "a malformed line is skipped and counted, not fatal" \
	"$(grep -q 'skipped 1 malformed' "$REPO/a5.err" && echo 1)" "$(cat "$REPO/a5.err")"
ok "the trail still reads after a malformed line" \
	"$([ "$(grep -c 'gate_green' "$REPO/a5.txt" || true)" -eq 2 ] && echo 1)"

# --- refusals -----------------------------------------------------------------
# A build lane that edits a frozen test. lock-check runs in the lane's exit path.
"$WAVE" build --ledger "$LEDGER" --level L3 --pin "$PIN" --confirm --width 1 \
	--root "$WT/drift" --child "$STUB/build-drift" >"$REPO/b1.txt" 2>&1 || true
ok "a build lane that edits a frozen test is refused" \
	"$(grep -q 'the frozen surface moved' "$REPO/b1.txt" && echo 1)" "$(cat "$REPO/b1.txt")"
ok "the drift refusal leaves a record behind" \
	"$(grep -q '"status":"refused".*"stage":"build"' "$RECORDS" && echo 1)"

# A build lane that writes outside its row's sources.
"$WAVE" build --ledger "$LEDGER" --level L3 --pin "$PIN" --confirm --width 1 \
	--root "$WT/scope" --child "$STUB/build-outside" >"$REPO/b2.txt" 2>&1 || true
ok "a build lane that writes outside its sources is refused" \
	"$(grep -q 'wrote outside the row sources: src/outside.py' "$REPO/b2.txt" && echo 1)" "$(cat "$REPO/b2.txt")"

# A row with no `sources` column, and a row whose sources name the lock surface.
LEDGER_NOSCOPE="$REPO/ledger-noscope.md"
ledger "$LEDGER_NOSCOPE" '| R1 | L3 | add(a,b) returns a+b | direct sum | none |  | tests/test_R1.py::test_add | ./gate/run-tests.sh | proved |
| R2 | L3 | sub(a,b) returns a-b | direct difference | none | tests/ | tests/test_R2.py::test_sub | ./gate/run-tests.sh | proved |'
"$WAVE" build --ledger "$LEDGER_NOSCOPE" --level L3 --pin "$PIN" --confirm --width 1 \
	--root "$WT/noscope" --child "$STUB/build-good" >"$REPO/b3.txt" 2>&1 || true
ok "a row with no sources is refused" \
	"$(grep -q 'no sources column' "$REPO/b3.txt" && echo 1)" "$(cat "$REPO/b3.txt")"
ok "a row whose sources name the lock surface is refused" \
	"$(grep -q 'sources include the frozen surface' "$REPO/b3.txt" && echo 1)"

# Two sysDV lanes claiming one path: refused before anything is applied.
LEDGER_COLLIDE="$REPO/ledger-collide.md"
ledger "$LEDGER_COLLIDE" '| R1 | L3 | add(a,b) returns a+b | direct sum | none | src/app.py | tests/test_shared.py::test_add | ./gate/run-tests.sh | proved |
| R2 | L3 | sub(a,b) returns a-b | direct difference | none | src/math.py | tests/test_shared.py::test_sub | ./gate/run-tests.sh | proved |'
"$WAVE" sysdv --ledger "$LEDGER_COLLIDE" --level L3 --base "$BASE" --confirm --width 2 \
	--root "$WT/collide" --child "$STUB/sysdv-collide" --no-records >"$REPO/b4.txt" 2>&1 || true
"$WAVE" freeze --ledger "$LEDGER_COLLIDE" --level L3 --base "$BASE" \
	--root "$WT/collide" --no-records >"$REPO/b5.txt" 2>&1 || true
ok "compose refuses two lanes claiming the same path" \
	"$(grep -q 'two lanes claim the same path' "$REPO/b5.txt" && echo 1)" "$(cat "$REPO/b5.txt")"
ok "the collision is named, with the lanes that claimed it" \
	"$(grep -q 'tests/test_shared.py  <-  R1 R2' "$REPO/b5.txt" && echo 1)" "$(cat "$REPO/b5.txt")"
ok "a refused compose applies nothing" "$([ ! -d "$WT/collide/compose" ] && echo 1)"

# A composed suite that is GREEN at the base. The lane result is hand-written here on
# purpose: this tests the barrier's own wall, not sysDV's.
LEDGER_VACUOUS="$REPO/ledger-vacuous.md"
ledger "$LEDGER_VACUOUS" '| R1 | L3 | vacuous row | none | none | src/app.py | tests/test_vacuous.py::test_vacuous | ./gate/run-tests.sh | proved |'
git -C "$REPO" worktree add -q --detach "$WT/vacuous/R1" "$BASE"
printf 'def test_vacuous():\n    assert True\n' >"$WT/vacuous/R1/tests/test_vacuous.py"
printf 'R1\tok\tred at %s\n' "${BASE:0:12}" >"$WT/vacuous/R1.result"
"$WAVE" freeze --ledger "$LEDGER_VACUOUS" --level L3 --base "$BASE" \
	--root "$WT/vacuous" --no-records >"$REPO/b6.txt" 2>&1 || true
ok "freeze refuses a composed suite that is GREEN at the base" \
	"$(grep -q 'GREEN at' "$REPO/b6.txt" && echo 1)" "$(cat "$REPO/b6.txt")"

# A lane that ships one vacuously-passing test beside a genuinely red neighbour. The
# suite is red, so the suite-level wall passes; the per-test wall is what refuses it.
LEDGER_MIXED="$REPO/ledger-mixed.md"
ledger "$LEDGER_MIXED" '| R1 | L3 | red row | none | none | src/app.py | tests/test_real.py::test_add | ./gate/run-tests.sh | proved |
| R2 | L3 | vacuous row | none | none | src/math.py | tests/test_vacuous.py::test_vacuous | ./gate/run-tests.sh | proved |'
mkdir -p "$WT/mixed"
git -C "$REPO" worktree add -q --detach "$WT/mixed/R1" "$BASE"
git -C "$REPO" worktree add -q --detach "$WT/mixed/R2" "$BASE"
printf '# expects: add\ndef test_add():\n    assert add(1, 1)\n' >"$WT/mixed/R1/tests/test_real.py"
printf '# vacuous: yes\ndef test_vacuous():\n    assert True\n' >"$WT/mixed/R2/tests/test_vacuous.py"
printf 'R1\tok\tred at %s\n' "${BASE:0:12}" >"$WT/mixed/R1.result"
printf 'R2\tok\tred at %s\n' "${BASE:0:12}" >"$WT/mixed/R2.result"
"$WAVE" freeze --ledger "$LEDGER_MIXED" --level L3 --base "$BASE" \
	--root "$WT/mixed" --no-records >"$REPO/b7.txt" 2>&1 || true
ok "freeze refuses a vacuously-passing test beside a red one" \
	"$(grep -q 'does not fail at' "$REPO/b7.txt" && echo 1)" "$(cat "$REPO/b7.txt")"
ok "the vacuity refusal names the file, not the whole lane" \
	"$(grep -q 'tests/test_vacuous.py' "$REPO/b7.txt" && echo 1)"

# Spawning build lanes needs the same confirmation as sysDV.
if "$WAVE" build --ledger "$LEDGER" --level L3 --pin "$PIN" --width 1 \
	--root "$WT/noconfirm" --child "$STUB/build-good" --no-records >/dev/null 2>&1; then
	ok "build without --confirm is refused" 0
else
	ok "build without --confirm is refused" 1
fi

# A directory source written with the trailing slash docs/06 uses (`src/`), plus the
# composed gate's whole point: this lane is green alone and the composed tree is not,
# because R2 is unimplemented. Green per lane is not green composed.
LEDGER_SLASH="$REPO/ledger-slash.md"
ledger "$LEDGER_SLASH" '| R1 | L3 | add(a,b) returns a+b | direct sum | none | src/ | tests/test_R1.py::test_add | ./gate/run-tests.sh | proved |'
"$WAVE" build --ledger "$LEDGER_SLASH" --level L3 --pin "$PIN" --confirm --width 1 \
	--root "$WT/slash" --child "$STUB/build-good" >"$REPO/c1.txt" 2>&1 || true
ok "a directory source with a trailing slash accepts writes under it" \
	"$(grep -qE '^R1[[:space:]]+ok' "$REPO/c1.txt" && echo 1)" "$(cat "$REPO/c1.txt")"
ok "the composed gate refuses while another row is still unimplemented" \
	"$(grep -q 'the composed suite is red' "$REPO/c1.txt" && echo 1)" "$(cat "$REPO/c1.txt")"

# --- the pin is a wall, not a suggestion --------------------------------------
# A later build cannot silently widen the frozen surface: lock-check is what makes the
# pin a sha over the tests, and it must still be clean after all of the above.
ok "the pin is still clean at the end of the run" \
	"$(cd "$WT/build/compose" && ./gate/lock-check.sh "$PIN" >/dev/null 2>&1 && echo 1)"
ok "the trail only grew" "$([ "$(grep -c '' "$RECORDS" || true)" -gt "$LINES_BEFORE" ] && echo 1)"

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "all passed" || echo "$failures failed")"
[ "$failures" -eq 0 ]
