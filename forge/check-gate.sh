#!/usr/bin/env bash
# check-gate.sh — adversarial fixtures for forge-gate. No model, no network, no pi.
#
#   bash forge/check-gate.sh
#
# One failing fixture per validation invariant (the nine in the shipped template), plus the
# spec-level traceability rules and every refusal that guards the audit trail: ratify off a
# TTY, a task claimed before ratification, a completion whose commit escapes the task's scope,
# a malformed records.jsonl line, and `finish` refusing an incomplete trail.
#
# Exit: 0 every fixture behaved, 1 a fixture disagreed, 2 usage/environment.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GATE="$HERE/bin/forge-gate"
[ -x "$GATE" ] || { printf 'check-gate: %s is missing or not executable\n' "$GATE" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'check-gate: git is required\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'check-gate: python3 is required\n' >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

# expect_analyze <name> <expect-exit> <expect-substring|-> [file]
# Runs analyze in $WORK/repo against $WORK/spec/spec.md (or the given file) and asserts.
expect_analyze() {
	local name="$1" want="$2" needle="$3" file="${4:-}"
	local out rc
	if [ -n "$file" ]; then
		out=$("$GATE" analyze "$file" 2>&1); rc=$?
	else
		out=$("$GATE" analyze "$WORK/repo/specs/001-fixture" 2>&1); rc=$?
	fi
	if [ "$rc" != "$want" ]; then
		bad "$name (exit $rc, wanted $want)"
		printf '%s\n' "$out" | sed 's/^/        /'
		return
	fi
	if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
		bad "$name (message did not mention '$needle')"
		printf '%s\n' "$out" | sed 's/^/        /'
		return
	fi
	ok "$name"
}

# --- a throwaway repo, with the branch forge mode is allowed to commit on ---
mkdir -p "$WORK/repo"
cd "$WORK/repo" || exit 2
git init -q .
git config user.email t@example.invalid
git config user.name "fixture"
git config commit.gpgsign false
mkdir -p tests src/evidence
printf '#!/usr/bin/env bash\nexit 0\n' >tests/run.sh
chmod +x tests/run.sh
printf 'value = 1\n' >src/app.py
git add -A
git commit -qm init

echo "== scaffold =="
if "$GATE" start fixture --objective "fixture objective" >/dev/null 2>&1 &&
	[ -f specs/001-fixture/spec.md ] && [ -f specs/001-fixture/records.jsonl ]; then
	ok "start scaffolds spec.md + records.jsonl"
else
	bad "start scaffolds spec.md + records.jsonl"
fi
if grep -q 'forge/001-fixture' specs/001-fixture/spec.md; then
	ok "start pins the branch name in the header"
else
	bad "start pins the branch name in the header"
fi
# A freshly scaffolded spec is a DRAFT: its placeholder FRs are satisfied by nothing.
expect_analyze "a fresh scaffold is not acceptable yet" 1 "satisfied by no task"

# --- fixture spec writer ----------------------------------------------------
# write_spec <defect> — writes specs/001-fixture/spec.md with one seeded defect.
write_spec() {
	python3 - "$1" <<'PY'
import json, sys, pathlib
defect = sys.argv[1]

task = {
    "id": "T001",
    "title": "do the thing",
    "satisfies": ["FR-001", "US1"],
    "priority": "P1",
    "depends_on": [],
    "target_repo": "fixture",
    "definition_of_done": ["a test fails first, then passes"],
    "success_criteria": ["100% of fixtures pass"],
    "scope": ["src/**"],
    "dod_tests": ["tests/run.sh"],
    "sc_evidence": [{"sc": 1, "path": "src/evidence/e1.txt"}],
}
extra = dict(task, id="T002", title="the dependent thing", satisfies=["FR-002"],
             depends_on=["T001"], priority="P2")
third = dict(task, id="T003", title="the third thing", satisfies=["FR-001"],
             depends_on=["T002"], priority="P3")
block = {"spec_version": "forge/v1", "target_repos": ["fixture"], "tasks": [task, extra, third]}

if defect == "missing-key":
    del block["tasks"][0]["scope"]
elif defect == "bad-id":
    block["tasks"][0]["id"] = "T1"
elif defect == "dup-id":
    block["tasks"][1]["id"] = "T001"
elif defect == "bad-priority":
    block["tasks"][0]["priority"] = "P0"
elif defect == "dangling-dep":
    block["tasks"][1]["depends_on"] = ["T009"]
elif defect == "cycle":
    block["tasks"][0]["depends_on"] = ["T002"]
elif defect == "empty-satisfies":
    block["tasks"][0]["satisfies"] = []
elif defect == "bad-target":
    block["tasks"][0]["target_repo"] = "elsewhere"
elif defect == "traversal-scope":
    block["tasks"][0]["scope"] = ["../escape/**"]
elif defect == "vacuous-scope":
    block["tasks"][0]["scope"] = ["**/*"]
    block["tasks"][0]["sc_evidence"] = [{"sc": 1, "path": "src/evidence/e1.txt"}]
elif defect == "bad-selector":
    block["tasks"][0]["dod_tests"] = ["tests/run.sh::case_two"]
elif defect == "evidence-out-of-range":
    block["tasks"][0]["sc_evidence"] = [{"sc": 2, "path": "src/evidence/e1.txt"}]
elif defect == "evidence-uncovored":
    block["tasks"][0]["sc_evidence"] = []
elif defect == "evidence-outside-scope":
    block["tasks"][0]["sc_evidence"] = [{"sc": 1, "path": "docs/e1.txt"}]
elif defect == "unsatisfied-fr":
    pass  # base spec already defines FR-002 and satisfies it; break that instead:
elif defect == "undefined-fr":
    block["tasks"][0]["satisfies"] = ["FR-009", "US1"]
elif defect == "withdrawn-fr":
    pass
elif defect == "missing-evidence":
    block["tasks"][1]["sc_evidence"] = [{"sc": 1, "path": "src/evidence/never-created.txt"}]
elif defect == "untracked-evidence":
    block["tasks"][1]["sc_evidence"] = [{"sc": 1, "path": "src/evidence/e2.txt"}]
elif defect == "must-match":
    block["tasks"][1]["sc_evidence"] = [
        {"sc": 1, "path": "src/evidence/e1.txt", "must_match": "PASS [0-9]+ of [0-9]+"}
    ]
elif defect == "must-not-match":
    block["tasks"][1]["sc_evidence"] = [
        {"sc": 1, "path": "src/evidence/e1.txt", "must_not_match": "PASS"}
    ]
elif defect == "red-selector":
    block["tasks"][0]["dod_tests"] = ["tests/broken.sh"]
elif defect == "no-tasks":
    block["tasks"] = []
elif defect == "ok":
    pass

prose_fr = ["FR-001", "FR-002"]
if defect == "unsatisfied-fr":
    block["tasks"][1]["satisfies"] = ["FR-001"]
    prose_fr = ["FR-001", "FR-002", "FR-003"]
withdrawn = ""
if defect == "withdrawn-fr":
    withdrawn = "- **~~FR-007~~ (withdrawn):** dropped after review."

text = ["# Spec", "", "## Header", "", "- **Objective:** fixture", "- **Target Repo(s):** `fixture`",
        "- **Mode:** `autonomous`", "- **Status:** `draft`", "- **Branch:** `forge/001-fixture`", "",
        "## User Scenarios", "", "### US1 (P1) — the thing", "",
        "- **Independent Test:** the thing works.", "",
        "## Requirements", ""]
for fr in prose_fr:
    text.append(f"- **{fr}:** System **MUST** do the thing. _(US1)_")
if withdrawn:
    text.append(withdrawn)
text += ["", "## Success Criteria", "", "- **SC-001:** 100% of fixtures pass.", "",
         "## Task Breakdown", "", "<!-- shinro:tasks:begin v1 -->", "", "```json",
         json.dumps(block, indent=2), "```", "", "<!-- shinro:tasks:end -->", ""]
pathlib.Path("specs/001-fixture/spec.md").write_text("\n".join(text))
PY
}

echo
echo "== the nine invariants (one failing fixture each) =="
for case in \
	"missing-key|missing required key" \
	"bad-id|must match ^T[0-9]{3}$" \
	"dup-id|duplicate id" \
	"bad-priority|priority" \
	"dangling-dep|does not resolve to a task id" \
	"cycle|cycle" \
	'empty-satisfies|`satisfies` must be a non-empty array' \
	"bad-target|not in target_repos" \
	"traversal-scope|contains '..'" \
	"bad-selector|rejected ::pattern form" \
	"evidence-out-of-range|does not resolve to a 1-based index" \
	'evidence-uncovored|`sc_evidence` must be a non-empty array' \
	"evidence-outside-scope|matched by no scope glob"; do
	name=${case%%|*}
	needle=${case#*|}
	write_spec "$name"
	expect_analyze "invariant: $name" 1 "$needle"
done

echo
echo "== spec-level traceability =="
write_spec unsatisfied-fr
expect_analyze "a prose FR satisfied by no task is rejected" 1 "FR-003: defined in the prose but satisfied by no task"
write_spec undefined-fr
expect_analyze "a satisfies entry that resolves to nothing is rejected" 1 "is not defined in the prose requirements"
write_spec no-tasks
expect_analyze "an empty task array is rejected" 1 '`tasks` must be a non-empty array'

echo
echo "== the good path =="
write_spec ok
expect_analyze "a valid spec is acceptable" 0 "nine invariants"
write_spec withdrawn-fr
expect_analyze "a withdrawn requirement is not a coverage obligation" 0 "nine invariants"
write_spec vacuous-scope
expect_analyze "a vacuous glob is an advisory, not a failure" 0 "scope-breadth-anomaly"

echo
echo "== the gates around the trail =="
# ratify off a TTY: an agent must not be able to sign Gate A.
printf 'ratify\n' | "$GATE" ratify specs/001-fixture >/dev/null 2>&1
if [ $? -eq 1 ]; then ok "ratify refuses without a TTY"; else bad "ratify refuses without a TTY"; fi
if grep -q 'ratified' specs/001-fixture/records.jsonl; then
	bad "a refused ratify wrote a row"
else
	ok "a refused ratify writes no row"
fi

# ratify needs understanding.md beside the spec.
write_spec ok
"$GATE" ratify specs/001-fixture >/dev/null 2>&1
if [ $? -eq 1 ]; then ok "ratify refuses without understanding.md"; else bad "ratify refuses without understanding.md"; fi

# claim before ratification.
write_spec ok
out=$("$GATE" claim specs/001-fixture T001 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'not ratified'; then
	ok "claim refuses before Gate A"
else
	bad "claim refuses before Gate A"; printf '%s\n' "$out" | sed 's/^/        /'
fi

echo
echo "== the trail drives completion =="
# A real ratification through a pty: this is the one row an agent cannot write.
printf '# understanding\n\n## What the FRs will build\n\nthe thing\n' >specs/001-fixture/understanding.md
python3 - "$GATE" <<'PY_RATIFY'
import os, pty, select, sys, time
gate = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(gate, [gate, "ratify", "specs/001-fixture"])
out = b""
deadline = time.time() + 20
sent = False
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        if not sent and b"sign" in out:
            os.write(fd, b"ratify\n")
            sent = True
    elif sent:
        break
try:
    os.close(fd)
except OSError:
    pass
os.waitpid(pid, 0)
sys.exit(0 if b"ratified" in out else 1)
PY_RATIFY
if [ $? -eq 0 ] && grep -q '"event": "ratified"' specs/001-fixture/records.jsonl; then
	ok "a human at a TTY ratifies and the row lands"
else
	bad "a human at a TTY ratifies and the row lands"
fi

# claim: requires the branch guard, an acceptable spec, ratification and a complete dependency.
out=$("$GATE" claim specs/001-fixture T002 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'depends on T001'; then
	ok "claim refuses a task whose dependency is incomplete"
else
	bad "claim refuses a task whose dependency is incomplete"
fi

"$GATE" claim specs/001-fixture T001 --model test/model >/dev/null 2>&1
if [ $? -eq 0 ]; then ok "claim succeeds on the guarded branch"; else bad "claim succeeds on the guarded branch"; fi

# --- worktree isolation ---------------------------------------------------
INTEG="$WORK/repo.forge/001-fixture"
TASK="$INTEG/T001"
if [ -d "$TASK" ] && [ "$(git -C "$TASK" rev-parse --abbrev-ref HEAD)" = "forge/001-fixture-T001" ]; then
	ok "claim created a task worktree on its own branch, outside the checkout"
else
	bad "claim created a task worktree on its own branch, outside the checkout"
fi
WT_LIST=$(git worktree list --porcelain)
case "$WT_LIST" in
*branch\ refs/heads/forge/001-fixture*) WT_ON_INTEG=1 ;;
*) WT_ON_INTEG=0 ;;
esac
if [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] && [ "$WT_ON_INTEG" = 1 ]; then
	ok "the repo checkout stays on main; the integration branch lives in its own worktree"
else
	bad "the repo checkout stays on main; the integration branch lives in its own worktree"
fi
TASK_STATUS=$(git -C "$TASK" status --porcelain)
if [ -n "$TASK_STATUS" ]; then
	bad "the task worktree starts clean"
else
	ok "the task worktree starts clean"
fi

# build: dod_tests are executed by the gate, inside the task worktree.
"$GATE" build specs/001-fixture T001 >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q '"green": true' specs/001-fixture/records.jsonl; then
	ok "build runs dod_tests and records green"
else
	bad "build runs dod_tests and records green"
fi
printf '#!/usr/bin/env bash\nexit 3\n' >"$TASK/tests/broken.sh" && chmod +x "$TASK/tests/broken.sh"
write_spec red-selector
"$GATE" build specs/001-fixture T001 >/dev/null 2>&1
if [ $? -eq 1 ] && grep -q '"green": false' specs/001-fixture/records.jsonl; then
	ok "build records red when a selector fails"
else
	bad "build records red when a selector fails"
fi
rm -f "$TASK/tests/broken.sh"
write_spec ok
"$GATE" build specs/001-fixture T001 >/dev/null 2>&1

# complete: refuses without a review, then with open SEV1/2, then accepts and merges.
printf 'value = 2\n' >"$TASK/src/app.py"
mkdir -p "$TASK/src/evidence" && printf 'all slug cases pass\n' >"$TASK/src/evidence/e1.txt"
git -C "$TASK" add -A >/dev/null 2>&1
git -C "$TASK" commit -qm "T001 inside scope"
INSIDE=$(git -C "$TASK" rev-parse HEAD)
out=$("$GATE" complete specs/001-fixture T001 --commit "$INSIDE" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'never reviewed'; then
	ok "complete refuses a task that was never reviewed"
else
	bad "complete refuses a task that was never reviewed"
fi
"$GATE" review specs/001-fixture T001 --verdict CONCERNS --findings 2 --open-sev12 1 >/dev/null 2>&1
out=$("$GATE" complete specs/001-fixture T001 --commit "$INSIDE" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'open SEV1/SEV2'; then
	ok "complete refuses open SEV1/SEV2 findings"
else
	bad "complete refuses open SEV1/SEV2 findings"
fi
"$GATE" review specs/001-fixture T001 --verdict CLEAN --findings 0 --open-sev12 0 >/dev/null 2>&1
"$GATE" complete specs/001-fixture T001 --commit "$INSIDE" >/dev/null 2>&1
if [ $? -eq 0 ]; then ok "complete accepts an in-scope, reviewed, green task"; else bad "complete accepts an in-scope, reviewed, green task"; fi
if [ "$(git -C "$INTEG" rev-parse HEAD)" = "$INSIDE" ]; then
	ok "complete fast-forwards the integration branch onto the task branch"
else
	bad "complete fast-forwards the integration branch onto the task branch"
fi

# --- evidence verification ------------------------------------------------
# `analyze` proves the paths are well-formed and in scope; only `complete` proves the evidence
# exists in the commit. Each case here breaks one of those and expects a named refusal.
commit_in_task() {
	# commit_in_task <worktree> <message>  → prints the sha
	git -C "$1" add -A >/dev/null 2>&1
	git -C "$1" commit -qm "$2"
	git -C "$1" rev-parse HEAD
}

"$GATE" claim specs/001-fixture T002 >/dev/null 2>&1 || true
TASK2="$INTEG/T002"

write_spec missing-evidence
"$GATE" build specs/001-fixture T002 >/dev/null 2>&1 || true
"$GATE" review specs/001-fixture T002 --verdict CLEAN --findings 0 --open-sev12 0 >/dev/null 2>&1
printf 'x\n' >"$TASK2/src/app.py"
SHA=$(commit_in_task "$TASK2" "T002 without its evidence")
out=$("$GATE" complete specs/001-fixture T002 --commit "$SHA" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'missing-from-tree'; then
	ok "complete refuses evidence that is not in the commit"
else
	bad "complete refuses evidence that is not in the commit"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# present on disk but never committed: the commit is what an auditor reads. The path must be one
# the tree does not already carry from an earlier task, or "in the tree" would be true for the
# wrong reason.
write_spec untracked-evidence
mkdir -p "$TASK2/src/evidence" && printf 'uncommitted\n' >"$TASK2/src/evidence/e2.txt"
printf 'value = 3\n' >"$TASK2/src/app.py"
git -C "$TASK2" add src/app.py >/dev/null 2>&1          # deliberately not the evidence
git -C "$TASK2" commit -qm "T002 with evidence left untracked"
SHA=$(git -C "$TASK2" rev-parse HEAD)
out=$("$GATE" complete specs/001-fixture T002 --commit "$SHA" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'missing-from-tree'; then
	ok "evidence in the worktree but not in the commit is refused"
else
	bad "evidence in the worktree but not in the commit is refused"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# content assertions
write_spec must-match
printf 'value = 4\n' >"$TASK2/src/app.py"
printf 'no numbers here\n' >"$TASK2/src/evidence/e1.txt"
SHA=$(commit_in_task "$TASK2" "T002 evidence without the required pattern")
out=$("$GATE" complete specs/001-fixture T002 --commit "$SHA" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'evidence-content-mismatch'; then
	ok "must_match is enforced against the committed blob"
else
	bad "must_match is enforced against the committed blob"; printf '%s\n' "$out" | sed 's/^/        /'
fi
write_spec must-not-match
printf 'PASS 3 of 3\n' >"$TASK2/src/evidence/e1.txt"
printf 'value = 5\n' >"$TASK2/src/app.py"
SHA=$(commit_in_task "$TASK2" "T002 evidence with a forbidden pattern")
out=$("$GATE" complete specs/001-fixture T002 --commit "$SHA" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'evidence-content-forbidden'; then
	ok "must_not_match is enforced against the committed blob"
else
	bad "must_not_match is enforced against the committed blob"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# a symlink is not evidence
write_spec ok
rm -f "$TASK2/src/evidence/e1.txt"
ln -s ../../tests/run.sh "$TASK2/src/evidence/e1.txt"
printf 'value = 6\n' >"$TASK2/src/app.py"
SHA=$(commit_in_task "$TASK2" "T002 with symlinked evidence")
out=$("$GATE" complete specs/001-fixture T002 --commit "$SHA" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'is a symlink'; then
	ok "symlinked evidence is refused"
else
	bad "symlinked evidence is refused"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# existence-only completes, and the trail says the content was not verified
write_spec ok
rm -f "$TASK2/src/evidence/e1.txt"                     # the symlink from the case above
git -C "$TASK2" checkout -- tests/run.sh              # ... which a printf through had rewritten
mkdir -p "$TASK2/src/evidence" && printf 'real evidence\n' >"$TASK2/src/evidence/e1.txt"
printf 'value = 7\n' >"$TASK2/src/app.py"
SHA=$(commit_in_task "$TASK2" "T002 with existence-only evidence")
out=$("$GATE" complete specs/001-fixture T002 --commit "$SHA" 2>&1)
if [ $? -eq 0 ] && grep -q 'evidence-existence-only' specs/001-fixture/records.jsonl; then
	ok "existence-only evidence completes and is recorded as an advisory"
else
	bad "existence-only evidence completes and is recorded as an advisory"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# a commit on the task branch that escapes the declared scope
write_spec ok
"$GATE" claim specs/001-fixture T003 >/dev/null 2>&1 || true
TASK3="$INTEG/T003"
mkdir -p "$TASK3/docs" && printf 'x\n' >"$TASK3/docs/x.txt"
printf 'value = 8\n' >"$TASK3/src/app.py"
mkdir -p "$TASK3/src/evidence" && printf 'e\n' >"$TASK3/src/evidence/e1.txt"
OUTSIDE=$(commit_in_task "$TASK3" "T003 escapes scope")
"$GATE" build specs/001-fixture T003 >/dev/null 2>&1 || true
"$GATE" review specs/001-fixture T003 --verdict CLEAN --findings 0 --open-sev12 0 >/dev/null 2>&1
out=$("$GATE" complete specs/001-fixture T003 --commit "$OUTSIDE" 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'outside its scope'; then
	ok "complete refuses a commit that escapes the task's scope"
else
	bad "complete refuses a commit that escapes the task's scope"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- the gauntlet: the branch is reviewed before the PR exists ----------------
out=$("$GATE" review specs/001-fixture --branch --verdict CLEAN --findings 0 --open-sev12 0 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'not complete'; then
	ok "the branch review refuses a partial branch"
else
	bad "the branch review refuses a partial branch"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# finish: refuses while a task is incomplete.
out=$("$GATE" finish specs/001-fixture 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'refusing to open a PR'; then
	ok "finish refuses an incomplete trail"
else
	bad "finish refuses an incomplete trail"
fi

# with every task complete but no branch review, `finish` still refuses
write_spec ok
"$GATE" claim specs/001-fixture T003 >/dev/null 2>&1 || true
TASK3="$INTEG/T003"
mkdir -p "$TASK3/src/evidence" && printf 'e\n' >"$TASK3/src/evidence/e1.txt"
printf 'value = 9\n' >"$TASK3/src/app.py"
SHA3=$(commit_in_task "$TASK3" "T003 in scope")
"$GATE" build specs/001-fixture T003 >/dev/null 2>&1
"$GATE" review specs/001-fixture T003 --verdict CLEAN --findings 0 --open-sev12 0 >/dev/null 2>&1
"$GATE" complete specs/001-fixture T003 --commit "$SHA3" >/dev/null 2>&1
out=$("$GATE" finish specs/001-fixture 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'no `spec-reviewed` row'; then
	ok "finish refuses a branch that was never reviewed"
else
	bad "finish refuses a branch that was never reviewed"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# a branch review with open SEV1/2 also blocks the PR
"$GATE" review specs/001-fixture --branch --verdict CONCERNS --findings 3 --open-sev12 1 >/dev/null 2>&1
out=$("$GATE" finish specs/001-fixture 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'left 1 SEV1/SEV2 finding'; then
	ok "finish refuses a branch review with open SEV1/SEV2"
else
	bad "finish refuses a branch review with open SEV1/SEV2"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# a clean branch review is what lets the strict trail pass
"$GATE" review specs/001-fixture --branch --verdict CLEAN --findings 0 --open-sev12 0 >/dev/null 2>&1
if "$GATE" analyze specs/001-fixture --strict >/dev/null 2>&1; then
	ok "a complete trail with a clean branch review passes analyze --strict"
else
	bad "a complete trail with a clean branch review passes analyze --strict"
fi
if "$GATE" report specs/001-fixture | grep -qF '## review'; then
	ok "the report (and therefore the PR body) carries the review"
else
	bad "the report (and therefore the PR body) carries the review"
fi

# review --post refuses while no PR exists (the review happens first, by design)
out=$("$GATE" review specs/001-fixture --branch --post --verdict CLEAN --findings 0 --open-sev12 0 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'no PR has been opened'; then
	ok "posting a review before the PR exists is refused, not silently skipped"
else
	bad "posting a review before the PR exists is refused, not silently skipped"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- end to end: finish pushes, opens the PR and POSTS the review --------------
# A stubbed `gh` records its argv, so the whole finish path is exercised with no network.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
if [ "$1 $2" = "pr create" ]; then echo "https://example.invalid/pr/1"; fi
exit 0
STUB
chmod +x "$WORK/bin/gh"
export GH_STUB_LOG="$WORK/gh.log"
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git" 2>/dev/null || true
PATH="$WORK/bin:$PATH" "$GATE" finish specs/001-fixture >/dev/null 2>&1
if [ $? -eq 0 ]; then ok "finish completes with a remote and gh available"; else bad "finish completes with a remote and gh available"; fi
if grep -q 'pr create' "$WORK/gh.log" 2>/dev/null; then
	ok "finish opens the PR"
else
	bad "finish opens the PR"
fi
if grep -q 'pr comment' "$WORK/gh.log" 2>/dev/null; then
	ok "finish POSTS the review as a PR comment"
else
	bad "finish POSTS the review as a PR comment"
fi
if grep -q '"event": "review-posted"' specs/001-fixture/records.jsonl; then
	ok "the posting is itself recorded in the trail"
else
	bad "the posting is itself recorded in the trail"
fi
REMOTE_LOG=$(git -C "$WORK/remote.git" log --oneline forge/001-fixture 2>/dev/null || true)
case "$REMOTE_LOG" in
*"audit: specs/001-fixture"*) REMOTE_HAS_AUDIT=1 ;;
*) REMOTE_HAS_AUDIT=0 ;;
esac
if [ "$REMOTE_HAS_AUDIT" = 1 ]; then
	ok "the pushed branch carries the audit commit"
else
	bad "the pushed branch carries the audit commit"
fi

# clean: refuses a dirty worktree, then removes them all with --force.
out=$("$GATE" clean specs/001-fixture 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'uncommitted changes'; then
	ok "clean refuses a dirty worktree"
else
	bad "clean refuses a dirty worktree"
fi
"$GATE" clean specs/001-fixture --force >/dev/null 2>&1
if [ ! -d "$TASK" ] && [ ! -d "$INTEG" ]; then
	ok "clean --force removes the spec's worktrees"
else
	bad "clean --force removes the spec's worktrees"
fi

echo
echo "== records.jsonl is parsed, not trusted =="
printf '{"event": "ok"}\nnot json at all\n' >>specs/001-fixture/records.jsonl
out=$("$GATE" report specs/001-fixture 2>&1)
if [ $? -eq 1 ] && printf '%s' "$out" | grep -qF 'not one JSON object per line'; then
	ok "a malformed record line names its line number"
else
	bad "a malformed record line names its line number"
fi


echo
echo "== no second ledger =="
# The portable pipeline records against the spec's own T00N ids; there is no bead CLI, no minted id
# and no converter. `forge-workflow` is the one file that documents the harness path, where beads
# really are the ledger — it is excluded, and checked positively below so the exclusion cannot hide
# a wholesale removal.
SURFACE="$HERE/skills $HERE/agents $HERE/templates"
hits=$(grep -rnE '(^|[^A-Za-z])bd([^A-Za-z]|$)|mint(ing|ed)?[ -]?bead' $SURFACE 2>/dev/null |
	grep -v "forge-workflow/" || true)
if [ -z "$hits" ]; then
	ok "the shipped skills, agents and template name no bead CLI or mint step"
else
	bad "bead-CLI/mint language is back outside forge-workflow"
	printf '%s\n' "$hits" | sed 's/^/        /'
fi
if grep -qi 'bead' "$HERE/skills/forge-workflow/SKILL.md"; then
	ok "forge-workflow still documents the harness path (where beads are the ledger)"
else
	bad "forge-workflow lost its bead-lifecycle text"
fi
if grep -q 'Bridge to' "$HERE/templates/spec-template.md"; then
	bad "the template points at a bead bridge that no longer exists"
else
	ok "the template has no dangling bead-bridge reference"
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "forge-gate: every fixture behaved"
	exit 0
fi
echo "forge-gate: fixtures disagreed"
exit 1
