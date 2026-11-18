# 07 — Failure modes

Every entry here was observed or is one edit away in a real repo. Symptom, why it passes
review, countermeasure.

## 1. The selector deselects

**Symptom.** The suite is green; two categories never ran.
**Why it passes.** `addopts = "-m 'not integration and not mcp'"` lives in
`pyproject.toml`, not in `tests/`. Editors of tests never see it.
**Countermeasure.** Pin the configuration, not the test directory; state the selection
inside the locked command (`gate/run-tests.sh`), not in an editable ini.

## 2. The fixture redefines reality

**Symptom.** A test passes because `conftest.py` substitutes a fake for the thing under
test.
**Why it passes.** The assertion is honest; the fixture is not part of the assertion.
**Countermeasure.** `conftest.py` at every level is in the lock surface. A new one is
drift.

## 3. The cheapest green

**Symptom.** The build "fixes" a failing test by weakening it.
**Why it passes.** The diff is small and plausible, and it is in the tests.
**Countermeasure.** Structural refusal, not review vigilance: the write is rejected, and
the pin check fails the run.

## 4. Vacuous green

**Symptom.** A test that passes before the implementation exists.
**Why it passes.** It is green, and green is the only thing anyone checks.
**Countermeasure.** Red-first is mandatory per lane; a test green at the
pre-implementation commit is rejected, not merged.

## 5. Parallel lanes race shared generated state

**Symptom.** Two lanes pass alone; the composed build differs run to run.
**Why it passes.** Each lane's log looks clean.
**Countermeasure.** Generated paths rewritten in place (a checked-in generated source, a
codegen output directory, `.zig-cache/`, `build/`) are lane-exclusive: one worktree per
lane, or serialize. "Overwritten by whichever generator ran last" is a race, spelled out
in a comment.

## 6. A suite that was never run whole

**Symptom.** N lanes of tests compose into duplicate fixtures, conflicting conftests, or
node-id collisions.
**Why it passes.** Every lane's own run was green (or red) exactly as intended.
**Countermeasure.** The barrier runs the composed suite once before the freeze.

## 7. Green per lane, red composed

**Symptom.** Each lane satisfies its own tests; the merged tree fails.
**Why it passes.** Two green checkmarks; the composition was never run.
**Countermeasure.** One composed gate, serial, after the merge. This is the only run
that supports the delivery claim.

## 8. Independence theatre

**Symptom.** Three agents "review each other" and agree.
**Why it passes.** The roles have different names and prompts.
**Countermeasure.** Say what is actually independent: the artifact (written without sight
of the implementation) and the evidence source. A different model family is a weak
decorrelation, not verification.

## 9. Empirical parity as a substitute for equivalence

**Symptom.** A green parity run is recorded as proof that a transformed program computes
the same function.
**Why it passes.** The numbers agree to many digits.
**Countermeasure.** The ceiling rule (`docs/06`): that row is `structural` or
`declared`, unless there is a refinement argument with a named trusted base.

## 10. The test author saw the implementation

**Symptom.** Tests encode internal structure — private symbols, call order, exact
floating-point sequences — and break on every legitimate refactor.
**Why it passes.** They pass, and they look thorough.
**Countermeasure.** Author at a worktree where the implementation does not exist, with
the spec and interface snapshot as the only inputs.

## 11. The command is unpinned

**Symptom.** Green from `pytest -k "not slow" -x`.
**Why it passes.** The command is in a chat message, not in a file.
**Countermeasure.** One canonical command, locked, with the selection explicit.

## 12. Locked wrong

**Symptom.** The frozen test asserts a behaviour the spec does not require; the build
either implements wrong behaviour or stalls.
**Why it passes.** The lock works exactly as designed.
**Countermeasure.** An amendment path for the human: a commit that states the spec
changed, a new pin, a rebase. Build lanes stop; they do not contort.

## 13. Drift reported as a warning

**Symptom.** The gate prints a warning about a changed test and exits 0.
**Why it passes.** The run is green and the warning is in the log nobody reads.
**Countermeasure.** Drift is a refusal with a nonzero exit. A warning is a green run with
a footnote.
