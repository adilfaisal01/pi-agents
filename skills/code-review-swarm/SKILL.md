---
name: code-review-swarm
description: Two-model parallel code review. Dispatches a correctness lane and a quality lane as real subagent processes on different models, then merges both into one numbered SEV1-SEV4 table with file:line locations and descriptions.
---

# Code Review Swarm

Two lanes, two models, one context boundary each. The lanes do not see each other, so their
agreement is evidence and their disagreement is a lead. Deliverable: **one numbered table**
— `# | SEV | LOCATION | FINDING | TRIGGER | LENS | CONF` — merged from both lanes.

This is a real parallel dispatch. It is not a single model role-playing two reviewers.

## 1. Scope

Establish before dispatching, and put it verbatim in the lane task:

- Named paths/dirs from the user → review those.
- "Review my changes" → `${git diff --staged}` if non-empty, else `${git diff main...HEAD}`,
  plus the files it touches, plus one read of each touched module's caller.
- Nothing named → ask once, or default to the staged diff and say what you defaulted to.

Give both lanes the identical scope string. A lane reviewing a different code than the other
produces incomparable tables.

## 2. Lanes and models

| Lane | Agent | Lens |
|---|---|---|
| correctness | `review-correctness` | logic, UB, memory, edge cases, races, float error, API misuse |
| quality | `review-quality` | design, convention, naming, duplication, maintainability, testability |

Definitions live in `~/.pi/agent/agents/review-correctness.md` and `review-quality.md`.
Each carries `tools: read, grep, find, ls, bash` and no write tool — a review never edits.

**The model is the `model:` line in those two files.** That line is what reaches
`--model <provider>/<id>` on the child process; nothing in this document can change it, and
it is what the report header names. Read it before writing the header.

**Choosing models.** The `subagent` tool has no per-call model parameter; the model is a
frontmatter field that becomes `--model <provider>/<id>` on the child process.

- Change a default → edit the `model:` line in that agent file. Takes effect on the next
  dispatch, no restart (agent discovery reads the directory per call).
- Different pair for one run → write `~/.pi/agent/agents/review-lane-a.md` and
  `review-lane-b.md` with the same bodies and the models the user named, dispatch against
  those names, then delete them.
- Omit `model:` → the child inherits the dispatching session's model **and** thinking level.
  Explicit `model:` drops the inherited thinking level; that is intentional.
- Discover the exact ids with `pi --list-models` — it fuzzy-matches, so a miss returns
  lookalikes rather than nothing. Ids are provider-qualified: `ollama-cloud/kimi-k3`.

## 3. Dispatch

### 3a. Give each lane its own checkout

```sh
./scripts/lane-prepare.sh prepare     # stdin: MODE= SHA= PARENT= REPO= CWD_CORRECTNESS= CWD_QUALITY=
./scripts/lane-prepare.sh clean       # after the merge
```

The lanes are real processes, but a child inherits your working directory and your
environment. Two lanes then read one mutable tree at different moments, so their
disagreement can mean the tree changed, not that the code is ambiguous — and a repro
written to `/tmp` resolves the package through the inherited venv, against whatever tree
that venv was installed from.

So the change is materialised as a **commit** — the index when the scope is the staged diff,
as a dangling commit that touches nothing; `HEAD` otherwise — and each lane gets its own
worktree at it. Same sha, two trees, and the lanes cannot race each other.

- **`MODE=worktree`** — dispatch with `cwd`, and state the change as `git diff PARENT..SHA`
in that checkout. Identical for both lanes, and no diff text to paste or truncate.
- **`MODE=shared`** — `review-lanes` was not found. Say so in one line, dispatch without
`cwd`, and the ask sends repros to `/tmp` and forbids writes into the working directory. A
shared-tree run is a weaker review; present it as one rather than as equal.

### 3b. One call, parallel mode, `agentScope: "user"`

```js
subagent({
  agentScope: "user",
  tasks: [
    { agent: "review-correctness", cwd: "<CWD_CORRECTNESS>", task: "<scope> + <the ask below>" },
    { agent: "review-quality",     cwd: "<CWD_QUALITY>",     task: "<scope> + <the ask below>" },
  ],
})
```

Omit `cwd` in `MODE=shared`. The ask, appended to the scope, is what makes the tables mergeable:

> Review the change in your working directory: `git diff <PARENT>..<SHA>`, plus the files it
> touches. Report per your output contract: one markdown table, SEV1-SEV4, every row carrying
> `path:line (symbol)` and a concrete TRIGGER. Nothing outside the table except the COVERAGE
> and NOT CHECKED lines. Write scratch files under `review/`. Do not apply fixes.

Each lane declares `write_scope: review`, so a child that writes anywhere else fails the run
and the review is discarded — with a worktree that check is unambiguous, because the tree is
the lane's alone.

### 3c. Tear down

```sh
./scripts/lane-prepare.sh clean
```

Unless an open SEV1 needs its reproduction kept: then say where the worktrees are and leave
them, because the next `prepare` refuses a dirty worktree rather than silently discarding
the evidence.

## 4. Merge

Read both lane tables. Then:

1. **Deduplicate on the claim, not on wording or on class.** Two rows merge only when they
   sit on the same statement (or within ±3 lines) **and** assert the same broken invariant.
   The same site is necessary, not sufficient: two distinct defects on adjacent lines stay
   two rows — `tests/fixture/buggy.py` carries `discount=[]` and `discount[0]` three lines
   apart. Class names are lane-local vocabularies (each contract excludes the other lane's),
   so they must never be the merge key. A cross-lane merge sets `LENS = both` and raises
   `CONF`.
2. **Never treat agreement as truth or disagreement as noise.** A lane's silence is not a
   veto: if correctness says SEV1 and quality said nothing, it stays SEV1 with
   `CONF = high`. A lane that *contradicts* a finding keeps it as `DISPUTED` with both
   arguments in one clause — never silently dropped.
3. **Re-severity yourself.** Lane severities are proposals on different scales. Normalise to
   the table below, then sort SEV1-first, then by path.
4. **Carry the trigger.** Both lanes emit one and they are not the same thing: correctness
   gives the input or interleaving that breaks it now, quality gives the future change or
   usage that makes it cost someone time. When two rows merge, keep both in one cell. A row
   without a trigger is not a finding — drop it.
5. **Drop nothing the user asked about**, but do drop rows with no location, rows with no
   trigger, and rows that restate the code.
6. **Account for the scope.** Every file in the scope string must appear in at least one
   lane's `COVERAGE:` line. Files in neither go under `UNCOVERED:` after the table, and the
   report must not claim the scope was reviewed. This is set arithmetic on data you already
   hold — a floor on what was read, not proof that it was understood.
7. **The table contains lane rows only.** Anything you noticed yourself is not a finding: if
   it matters, put it in one line after the table prefixed `dispatcher note:`. A third
   opinion inside the table is indistinguishable from a lane's and breaks the premise.

Renumber final rows `1..N`. Lane IDs (`C3`, `Q7`) are provenance only — keep them in a
parenthetical if the run is one someone will act on. `FIX` is not merged: it is the lanes'
advice, not the table's content, and the reader decides the fix.

## 5. Severity

| SEV | Meaning |
|---|---|
| **SEV1** | Crash, corruption, wrong result, data loss, or exploitable. Ship-stopper. |
| **SEV2** | Wrong under a realistic input, or a latent fault on a reachable path. Fix this cycle. |
| **SEV3** | Wrong only on an unlikely input, or fragile — the next edit breaks it. |
| **SEV4** | Correctness-adjacent nit, polish, local inconsistency. |

Equivalences, if a lane used another scale: SEV1 = old P0, SEV2 = P1, SEV3 = P2, SEV4 = P3.

A quality finding arrives on the quality lane's own scale. Map it, do not copy it: a name
that lies about a public contract, or a design that guarantees a defect → SEV2. Duplication
that will drift, hidden coupling, a missing seam → SEV3. Naming, convention, layout,
testability → SEV4. A missing check at a trust boundary that can actually be triggered is a
correctness claim — SEV2, with a trigger.

`CONF`: `high` both lanes or one lane plus a reproduction you ran or read; `med` one lane,
specific trigger, unexecuted; `low` one lane, plausibility argued from reading only.

## 6. Report

Open with one line: lanes, their models (read from each agent's `model:` line), scope, counts
per SEV. Then the table. Then, in at most three bullets, the findings that must be fixed
before anything else ships. Then disagreements, anything under `NOT CHECKED`, and any
`UNCOVERED:` files, in one short paragraph. Nothing else — no prose tour of the code that was
read.

```markdown
**2 lanes · mimo-v2.6-flash (correctness) + kimi-k3 (quality) · scope: `src/ctl/` · SEV1 ×1, SEV2 ×3, SEV3 ×2**

| # | SEV | LOCATION | FINDING | TRIGGER | LENS | CONF |
|---|---|---|---|---|---|---|
| 1 | SEV1 | `src/ctl/kf.py:88` (`update`) | `P` is overwritten before the gain uses the prior, so the covariance never converges | `update(P=I, H=I)` for 50 steps: `trace(P)` stays at `n_x` instead of shrinking | both (C1, Q4) | high |
| 2 | SEV2 | `src/ctl/lqr.py:41` (`solve`) | `K` computed with `R` transposed; stable only because `R` is diagonal and symmetric by accident | `solve(R=diag([1, 2]))`: the second column of `K` differs from the analytic gain | correctness (C2) | med |
```

## 7. Fallback

If the `subagent` tool is absent, an agent name is unknown, or a model is unreachable, say so
in one line and run the two lenses **sequentially in this session** under the same output
contracts and the same merge rules, labelling the header `single-model fallback`. Never
present a fallback as a two-model run, and never fabricate a second lane's table.

## Pitfalls

- Lanes writing to the repo. They have no write tool; if a child produced a diff anyway, stop
  and discard, do not merge the review.
- Different scope per lane → incomparable tables, false disagreement.
- Cost: a whole-repo review on two pro models is a large spend. Default to the staged diff,
  and name the directories when the user means a directory.
- A lane that returns prose instead of the table has broken its contract: re-dispatch that
  lane once with the contract restated, then extract the rows yourself. Do not reformat by
  inventing rows.
- Large files: cap at the 15 most consequential per lane, as the contracts instruct. A 200-row
  table is not a better review.
