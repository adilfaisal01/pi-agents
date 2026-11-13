# review-gate

`swarm-gate` — a review gate over the [`code-review-swarm`](../code-review-swarm) lanes.

The swarm is a second opinion a model has to remember to ask for. This turns it into a
step: when a change set is finished, two models review it, and the result is an exit code
the build loop must act on before it may say "done".

## The loop it exists for

```
plan mode    → plan + todo list
build mode   → works the todos
  todos done → swarm-gate
                 exit 0 → relay SEV3/4 rows → the user decides fix / defer
                 exit 1 → every SEV1-2 row becomes a fix todo → fix → swarm-gate again
                 exit 3 → the same finding survived a round → stop, hand over
                 exit 4 → round budget spent → stop, hand over
                 exit 5 → a lane never reported → not a clean review, say so
user reviews the diff → commit and push stay the user's call
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | no SEV1/SEV2 (SEV3/4 may be listed for the user) |
| 1 | SEV1/SEV2 present — fix and re-run |
| 2 | usage error, or nothing to review (working tree matches `--base`) |
| 3 | loop guard: a SEV1/2 signature survived `--same-signature-limit` rounds |
| 4 | round budget exhausted with SEV1/2 still open |
| 5 | a lane is unusable: dispatch failed, no table, or no `COVERAGE:` line |
| 6 | **clean on an unchanged diff** — the previous round for this change set blocked and the code has not moved since, so this round's silence is the reviewer sampling differently, not a fix |

`5` exists because the difference between "nothing found" and "the reviewer never
reported" is the one thing a gate must not blur.

## Usage

```sh
swarm-gate                                  # review the working tree against HEAD
swarm-gate --scope src/shinro/codegen       # restrict the lanes to a subtree
swarm-gate --lanes correctness              # one lane (cheaper)
swarm-gate --max-rounds 3 --same-signature-limit 2
swarm-gate --json                           # machine-readable verdict for the ledger/CI
swarm-gate --dry-run                        # show the plan; dispatch nothing
swarm-gate --work-dir /tmp/review           # evidence elsewhere
swarm-gate --no-transcripts                 # JSONL only, keep no raw lane output
swarm-gate --history                        # read this change set back: rounds + notes
swarm-gate --note "deferred: the :108 row"  # record a decision beside the rounds
```

Installed on PATH at `~/.local/bin/swarm-gate` (a symlink; the shim resolves its own
symlink, so the checkout stays the single source of truth).

## What it does and does not reuse

Reused, unchanged: the two lane agents (`code-review-swarm/agents/`), their models, their
output contract, and `lane-prepare.sh` for isolated per-lane checkouts.

**Not reused: the skill's merge step.** The merge is model judgment — dedupe on "same
broken invariant ±3 lines", contradiction handling, quality severities mapped onto the
merged scale — and a gate cannot run on a model's opinion of its own output. This reads
each lane's own table and applies a mechanical policy. Consequences, stated rather than
hidden:

- There is no merged `LENS`/`CONF` table here. Rows carry the reporting lane, and are
  merged only when two lanes cite the same `path:line` at the same severity (`[both]`).
- The interactive skill remains the better read of a review. This adds a verdict.

## Staging is part of the contract

`lane-prepare.sh` materialises the **staged index** or `HEAD`. So:

- **staged change** → `MODE=worktree`: two worktrees at the same dangling commit, lanes
  cannot race each other, repros stay inside the checkout.
- **unstaged change** → `MODE=shared (unstaged-change)`: the lanes read your tree, which
  is the honest choice — reviewing `HEAD` would review a tree without the change. The
  isolation is weaker and the header says so.

Stage deliberately: `git add <paths>`, not `git add -A` (which sweeps build artifacts
into the review commit). `--base <ref>` forces shared mode.

## Rounds, signatures, ledger

The change-set key is `HEAD`. The fix loop happens before any commit, so `HEAD` is stable
across rounds — keying on the diff instead would reset the budget on every fix, which is
the one thing it must not do. Committing ends the change set.

- `--max-rounds N` (default 3): the Nth+1 run with SEV1/2 still open exits `4`.
- `--same-signature-limit N` (default 2): a **location** flagged in N consecutive rounds exits
  `3`. The guard keys on `path:line`, not on the finding's wording or severity — dogfooding
  showed the same verified SEV2 at one line reported twice with different phrasing, which a
  sentence hash misses, and one lane regrading a finding SEV2→dropped while the other kept
  reporting it. Two genuinely different defects on one line across rounds would trip it;
  that hands the change set to a human, which is the direction this gate errs in.

## Reading it back later: `review-work/` as notes

A change set is a small notebook, and `--history` prints it without dispatching anything:

```
change set 86b10a2aea  (3 round(s), 1 note(s))
  round 1  exit 1  sev1/2 present  mode shared
    SEV1 review-gate/lib/swarm_gate.py:552 (prepare) [correctness] [verified]
      When anything is staged, prepare chooses worktree mode ...
      trigger: git add ctl.py then edit another tracked file ...
  round 2  exit 1  ...
  note 2026-11-12T23:23:00-0500: the :108 row is the FaultLatch contract; own change set
```

The ledger keeps each round's **finding text and trigger**, not just its location, because
locations answered "where" and never "what did it say". `--note` appends a human decision
into the same stream, so the round that raised a finding and the judgement about it sit
next to each other. Notes never count as rounds: they must not inflate the budget.

When the budget is spent the gate now refuses **before** dispatching - the last thing paid
for used to be the one thing thrown away - and the refusal names what the last round left
open plus how to read the rest.

## Review evidence: `review-work/`

Everything a run produces lands in an ignored folder beside the code, one file per day:

```
review-work/
  2026-11-13.jsonl              one line per run: change set, round, mode, models,
                                 signatures, verdict, exit, findings[{sev,path,line,lane}]
  2026-11-13/
    293444c7-r1-correctness.md  the lane's raw output, exactly as it printed it
    293444c7-r1-quality.md
    293444c7-r1-quality.err     only when the lane failed
```

- `--work-dir DIR` moves the folder; `--ledger FILE` overrides the JSONL path alone (and
then becomes the read source too, so the round counter keeps working); `--no-transcripts`
keeps the JSONL and drops the raw output.
- **Prior rounds are read across every date file**, not just today's. A fix loop that
crosses midnight would otherwise look at an empty history, restart the round counter and
go quiet on both the budget and the loop guard.
- **The folder is ignored, not merely gitignore-requested.** The gate appends the pattern
to `.git/info/exclude` when it is not already ignored and verifies with `git check-ignore`.
It does that rather than editing a tracked `.gitignore` because the gate runs in
repositories that are not ours; the effect on `git status` is identical and only this
clone sees it. If the pattern cannot be applied the run says so instead of leaving you
with a committable review log.
- The transcripts exist because the parser keeps only table rows: without them a lane that
fails, or that explains itself in prose, leaves nothing to inspect afterwards.

**Known limitation.** Severity is not stable across rounds, and a finding can simply not
repeat (measured: one lane raised a real SEV2 in round 1 and reported nothing at that
location in round 2, on identical code). That is why a clean round cannot certify an
unchanged diff (exit `6`) and why every blocking row carries provenance:

| Label | Meaning |
|---|---|
| `[verified]` | the lane executed a trigger and said so |
| `[repeated xN]` | the same location was flagged in N rounds |
| `[single-sample, unexecuted]` | one lane, one round, nobody ran anything — the class that might be noise. Still reported, still blocking: a false positive costs a look, a false negative ships the defect. |
| `[single-sample]` | same, and the lane did not mark it either way |

## Verification

```sh
review-gate/check.sh        # syntax, prompt contract, and the stub-lane test suite
```

`tests/run-tests.sh` runs the gate against a **stub `pi`** with canned lane transcripts —
no model calls, so the policy, the ledger and the exit codes are deterministic. Review
quality itself is not asserted and is not pretended to be: one live run, in a throwaway
repo, found the planted SEV1 and a genuine SEV2 in 33 s.

## Cost

Two model calls per round (the lanes' own models). `--lanes correctness` halves it;
`--scope` bounds what they read, not the price of the round.

## Limits

- This finds defects; it does not prove absence. Nothing here replaces tests.
- Lanes are instructed to give a concrete trigger per row. A row without one is a defect
  of the review.
- Severity is a judgment. A disputed row belongs in your report, argued, not silently
  dropped.
