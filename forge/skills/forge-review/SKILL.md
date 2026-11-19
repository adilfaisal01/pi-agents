---
name: forge-review
description: Review a forge pull request with the two-model code-review-swarm and emit the forge's machine-checkable review record. Runs the correctness and quality lanes on the PR diff, merges them per the swarm's rules, then maps the merged table to the sentinel-bounded JSON block the harness extracts (verdict + findings with id/severity/location/finding/suggested_fix). Use when a task is in review, or when `harness/review-task.sh` needs a pi-driven reviewer backend.
---

# forge-review

The forge's review floor is machine-keyed, and one model's review cannot make its own agreement
evidence. So this skill replaces the single `reviewer` role with the **two-lane
code-review-swarm** (`code-review-swarm/skills/code-review-swarm/SKILL.md`,
`code-review-swarm/agents/review-{correctness,quality}.md`) and then does the one thing the
swarm does not: **emit the forge's record**.

Two artifacts come out of a run, and they are different on purpose:

| artifact | shape | who reads it |
| --- | --- | --- |
| the merged table | `# \| SEV \| LOCATION \| FINDING \| TRIGGER \| LENS \| CONF`, SEV1–SEV4 | the human, the PR comment |
| the record block | `<!-- shinro:review:begin v1 -->` … one JSON object | `harness/review-task.sh`: `.harness/review/<pr>.json`, then `disposition` |

The table is judgment; the block is data. Never let one stand in for the other, and never
hand-write a block whose findings are not in the table.

## 1. Review — run the swarm, do not re-implement it

Follow the swarm skill in full: scope the change once and give both lanes the identical scope
string, prepare per-lane checkouts with `code-review-swarm/scripts/lane-prepare.sh` (degrade to
the shared tree and say so, rather than skipping the review), dispatch `review-correctness` and
`review-quality` in one parallel `subagent` call, then merge under the swarm's rules —
dedupe on the claim and not on wording or class, never treat a lane's silence as a veto, re-severity
yourself, keep every trigger, drop rows with no location or no trigger, account for `COVERAGE`.

Everything that skill says about cost, models, and fallback applies unchanged. If only one lane
is usable, say `single-model fallback` in the header and carry on — the record still gets
written, and it says so.

## 2. Bridge — the deterministic mapping

After the merge, number the surviving rows `F1..FN` in the order the table already has them
(SEV1 first, then by path) and map, mechanically:

| swarm | record | note |
| --- | --- | --- |
| `SEV1` | `CRITICAL` | crash / corruption / wrong result / exploitable |
| `SEV2` | `HIGH` | wrong under a realistic input, or a latent fault on a reachable path |
| `SEV3` | `MEDIUM` | wrong only on an unlikely input, or fragile |
| `SEV4` | `LOW` | correctness-adjacent nit, polish — includes the quality lane's design/naming rows |
| `LOCATION` `path:line (symbol)` | `path:line` | **the symbol moves into the finding sentence**; the harness's location grammar is `path:line` |
| `FINDING` | `finding` | one sentence; append the symbol in parentheses if the row had one |
| `TRIGGER` (one or two cells) | `suggested_fix` | keep the trigger that makes the row actionable, then the smallest fix — see below |
| `verdict` | `CLEAN` no rows · `CONCERNS` rows, no SEV1 · `BLOCK-RECOMMENDED` any SEV1 | mirrors the forge's own rubric |

`suggested_fix` is REQUIRED and non-empty, and the swarm does not merge `FIX` into its table (the
lanes' fix advice is not the table's content). So build the cell from what the run actually holds,
in this order, and never invent one:

1. the lane's `FIX` for the row, verbatim from the lane table you are merging from;
2. else the row's `TRIGGER`, phrased as the smallest change that removes it
   (`"when n == 0"` → `"handle n == 0 explicitly instead of indexing"`);
3. else `"no fix proposed by either lane — see the trigger"` plus the trigger. An honest gap beats
   a fabricated remedy, and `disposition` will adjudicate the row on its merits either way.

Cross-lane merges (`LENS = both`) keep both triggers, joined by `; `. `CONF` does not enter the
record: it grades the review, not the defect, and the forge's schema has no field for it — mention
it only in the PR prose.

## 3. Emit

Emit, as the very last thing in the response, exactly one sentinel-bounded block and nothing after
its closing sentinel:

````markdown
<!-- shinro:review:begin v1 -->

```json
{
  "verdict": "CONCERNS",
  "findings": [
    {
      "id": "F1",
      "severity": "CRITICAL",
      "location": "sandbox/ctl/kf.py:88",
      "finding": "`P` is overwritten before the gain uses the prior, so the covariance never converges (`update`)",
      "suggested_fix": "use the prior `P` in the gain, then update"
    }
  ]
}
```

<!-- shinro:review:end v1 -->
````

Contract, from the harness's side: IDs `F1..FN` unique and sequential; `location` non-empty
`path:line`; `finding` and `suggested_fix` non-empty on every row; `severity` one of
`CRITICAL|HIGH|MEDIUM|LOW|INFO`; `verdict` one of the three above; a `CLEAN` verdict carries
`"findings": []`; exactly one block; nothing after the end sentinel. A missing, duplicated or
malformed block makes the harness record nothing and post a "manual verification required"
notice — the review still happened, but the machine floor did not get its verdict.

Then, before the block, the human-facing report: the swarm header line, the merged table, the
three must-fix bullets, and the disagreements / `NOT CHECKED` / `UNCOVERED` paragraph. Nothing
else. Do not restate the JSON in prose — the block is the same content twice already.

## 4. After the record

`harness/review-task.sh` extracts the block, stamps provenance (backend, model, feature SHA,
timestamp) and writes `.harness/review/<pr>.json`; a second pass feeds those findings to the
`disposition` adjudicator, which CONFIRMS or REBUTS each one against the diff and writes
`.harness/disposition/<pr>.json`. Both are advisory: the deterministic test suite stays the sole
merge authority, and nothing here merges, pushes, or gates.

Do not write either record yourself. If you find yourself editing `.harness/review/**` or
`.harness/disposition/**`, stop — that is the harness's write, and a hand-authored record makes
the floor unfalsifiable.

## Pitfalls

- **Reformatting instead of reviewing.** The bridge is arithmetic on rows a real dispatch
  produced. If the lanes did not run, there is no table — say so and stop; do not synthesise one.
- **A lane's `SEV` copied into the record.** The swarm re-severities during the merge; map from the
  *merged* rows, or the record inherits one lane's scale.
- **Symbols left inside `location`.** `path:line (fn)` is the swarm's grammar; the record's is
  `path:line`. The harness's location check is a string, and a symbol in it degrades to an
  unanchored finding that `disposition` will rightly REBUT.
- **Quality rows dropped.** Both lanes feed the record (decision 2026-11-19). A design row that
  guarantees the next defect is `SEV2` and belongs in the block; a naming nit is `SEV4` and also
  belongs there.
- **Two blocks, or prose after the sentinel.** The harness takes the first well-formed block and
  fails closed on ambiguity.
