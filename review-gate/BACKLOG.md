# Backlog — advisory findings and known limits

**Self-review is frozen.** The gate reviewing its own code has no natural end: every fix
adds surface, and each round reviews a *different* tree. Round 1 of the change set that
fixed the four false-green blockers raised six more blocking findings, five of them in code
written in the previous hour. That is the tool working, and it is also the point at which
the loop stops being informative.

From here, anything the gate says about itself lands in this file. It gets fixed only if
external use (the gate on a repository that is not this one) makes it matter.

The authoritative list of everything raised is the ledger:
`review-work/<date>.jsonl` in the reviewed repository, readable with `swarm-gate --history`.
Rows below are the ones with a design consequence.

## Advisory rows with a design consequence

| Sev | Where | Finding | Evidence |
|---|---|---|---|
| SEV3 | `--history` / `--note` | They ignore `--ledger`. A normal run honours the override for reads and writes; history reads the work folder instead, so it reports `0 round(s)` when the rounds live in the override file, and a note lands in a different stream. | change set `904c6e35` r1 |
| SEV3 | `main:961` | The "refuse for free" budget check runs *after* `prepare()`, which may invoke `lane-prepare.sh` and materialise worktrees. No model calls are spent, but the refusal is not entirely free. | `904c6e35` r1 |
| SEV3 | budget refusal | It prints the **last round's** locations, which may have moved since. Observed: it named `tests/test_channel.py:387` after those tests had been moved to `tests/test_channel_tick.py`. The text says "after the last round", so it is accurate as history, but it reads as a live worklist. | external use, change set `7b6ce45` r4 |
| SEV3 | `swarm_gate.py:4` | The usage synopsis omits `--work-dir`, `--no-transcripts`, `--history` and `--note`; README documents them. | `904c6e35` r1 |
| SEV4 | `report` | `--dry-run` still prints `recorded: <ledger path>` although nothing was written (no `review-work/` is created), so it reads as if a round had been banked. | `0714f4a2` r1 |
| SEV3 | `main:894` | `shutil.which("pi")` is checked before the `--history`/`--note` early exit, so a read-only command returns 5 ("a lane is unusable") on a machine without `pi`. | `904c6e35` r1 |
| SEV4 | `lane_prompt:140` | The untracked-file list injected into the prompt ignores `--scope`, while `in_scope` filters those same rows out afterwards: the prompt asks for files the verdict then drops. | `904c6e35` r1 |
| SEV4 | `in_scope:359` | Mixes prefix matching with `fnmatch` (whose `*` crosses `/`); `--scope`'s help documents neither. | `904c6e35` r1 |
| SEV4 | `signature`/`norm:377` | `norm()` stopped stripping underscores, so line-prints and signatures written by the previous version cannot match the recomputed forms. The guard and `seen` counts restart across that boundary — a mid-lifecycle artefact, not a live bug, but it means an old ledger is only half-comparable. | `904c6e35` r1 |
| SEV4 | `read_ledger_files:505` | Duplicates `read_prior`'s walk; `render_history` parses every ledger file twice. | `904c6e35` r1 |
| SEV3/4 | `main`, `prepare` | `main()` is a ~190-line body covering parse, resolve, validate, dispatch, policy, payload and ledger; `prepare()` carries five copy-pasted fallback literals differing only in a reason string. | `86b10a2` r2/r3 |
| SEV3 | `main:914` | `read_tree` was called four times per run — **fixed**, kept here as the record of why the snapshot is threaded. | `904c6e35` r1 → fixed in the bounded pass |

Rows recorded under change set `86b10a2` carry locations but no finding text: the ledger
learned to keep the sentences only afterwards. Their full text is in
`review-work/<date>/86b10a2a-r<N>-<lane>.md`.

## Known limits (design, not defects)

1. **`change_set` was the base commit; it is now the (base, HEAD) pair.** The base alone made
   the refusal's advice false: committing does not move the base, so a change set that spent
   its budget could never be re-reviewed. Fixed after external use hit it (change set
   `7b6ce45`, where the amendment commit was refused by its own predecessor's budget).
   Residual: two workstreams on one base *and* one HEAD still share a counter — a conflation,
   but a much narrower one.
2. **Severity is not stable across rounds.** Measured: one lane raised a real SEV2 in round 1
   and reported nothing at that location in round 2, on identical code; another regraded the
   same seam SEV2 → SEV4. That is why a clean round cannot certify an unchanged diff (exit 6)
   and why every blocking row carries provenance rather than a bare severity.
3. **The gate finds defects; it does not prove absence.** It is a detection aid over two
   models with no shared context, not a test suite. Nothing here replaces tests.
4. **`--scope` is enforced on parsed rows, not on the lanes' reading.** A lane may read
   outside the scope; its out-of-scope rows are dropped and reported as dropped.
5. **The loop guard keys on `path:line`, not on the finding.** Two genuinely different
   defects on one line across rounds trip it. That hands the change set to a person, which
   is the direction this gate errs in.
