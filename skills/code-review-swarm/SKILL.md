---
name: code-review-swarm
description: Two-model parallel code review. Dispatches a correctness lane and a quality lane as real subagent processes on different models, then merges both into one numbered SEV1-SEV4 table with file:line locations and descriptions.
---

# Code Review Swarm

Two lanes, two models, one context boundary each. The lanes do not see each other, so their
agreement is evidence and their disagreement is a lead. Deliverable: **one numbered table**
— `# | SEV | LOCATION | FINDING | LENS | CONF` — merged from both lanes.

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

| Lane | Agent | Default model | Lens |
|---|---|---|---|
| correctness | `review-correctness` | `ollama-cloud/deepseek-v4-pro` | logic, UB, memory, edge cases, races, float error, API misuse |
| quality | `review-quality` | `ollama-cloud/kimi-k3` | design, convention, naming, duplication, maintainability, testability |

Definitions live in `~/.pi/agent/agents/review-correctness.md` and `review-quality.md`.
Each carries `tools: read, grep, find, ls, bash` and no write tool — a review never edits.

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

One call, parallel mode, `agentScope: "user"`:

```js
subagent({
  agentScope: "user",
  tasks: [
    { agent: "review-correctness", task: "<scope> + <the ask below>" },
    { agent: "review-quality",     task: "<scope> + <the ask below>" },
  ],
})
```

The ask, appended to the scope, is what makes the tables mergeable:

> Review the scope given. Report per your output contract: one markdown table, SEV1-SEV4, every row
> carrying `path:line (symbol)`. Nothing outside the table except the COVERAGE and NOT
> CHECKED lines. Do not apply fixes.

## 4. Merge

Read both lane tables. Then:

1. **Deduplicate on site, not on wording.** Same file, line within ±3, same defect class →
   one row, `LENS = both`. Two lanes reaching it independently raises `CONF`.
2. **Never treat agreement as truth or disagreement as noise.** A lane's silence is not a
   veto: if correctness says SEV1 and quality said nothing, it stays SEV1 with
   `CONF = high`. A lane that *contradicts* a finding keeps it as `DISPUTED` with both
   arguments in one clause — never silently dropped.
3. **Re-severity yourself.** Lane severities are proposals on different scales. Normalise to
   the table below, then sort SEV1-first, then by path.
4. **Preserve the trigger.** The quality lane's finding often supplies the missing "why it
   matters"; the correctness lane's supplies "when". A row is only usable if it carries one.
5. **Drop nothing the user asked about**, but do drop rows with no location and rows that
   restate the code.

Renumber final rows `1..N`. Lane IDs (`C3`, `Q7`) are provenance only — keep them in a
parenthetical if the run is one someone will act on.

## 5. Severity

| SEV | Meaning |
|---|---|
| **SEV1** | Crash, corruption, wrong result, data loss, or exploitable. Ship-stopper. |
| **SEV2** | Wrong under a realistic input, or a latent fault on a reachable path. Fix this cycle. |
| **SEV3** | Wrong only on an unlikely input, or fragile — the next edit breaks it. |
| **SEV4** | Correctness-adjacent nit, polish, local inconsistency. |

Equivalences, if a lane used another scale: SEV1 = old P0, SEV2 = P1, SEV3 = P2, SEV4 = P3.

`CONF`: `high` both lanes or one lane plus a reproduction you ran or read; `med` one lane,
specific trigger, unexecuted; `low` one lane, plausibility argued from reading only.

## 6. Report

Open with one line: lanes, models, scope, counts per SEV. Then the table. Then, in at most
three bullets, the findings that must be fixed before anything else ships. Then disagreements
and anything under `NOT CHECKED`, in one short paragraph. Nothing else — no prose tour of the
code that was read.

```markdown
**2 lanes · deepseek-v4-pro (correctness) + kimi-k3 (quality) · scope: `src/ctl/` · SEV1 ×1, SEV2 ×3, SEV3 ×2**

| # | SEV | LOCATION | FINDING | LENS | CONF |
|---|---|---|---|---|---|
| 1 | SEV1 | `src/ctl/kf.py:88` (`update`) | `P` is overwritten before the gain uses the prior, so the covariance never converges | both (C1, Q4) | high |
| 2 | SEV2 | `src/ctl/lqr.py:41` (`solve`) | `K` computed with `R` transposed; stable only because `R` is diagonal and symmetric by accident | correctness (C2) | med |
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
