# Prototype status

State: **functional prototype**, frozen against self-review. Advisory findings and design
limits live in [BACKLOG.md](BACKLOG.md); this file is what has been *established* and what
has not.

## Proven

| Claim | Evidence |
|---|---|
| The policy over lane output is mechanical, not a model judging itself | 72 cases in `tests/run-tests.sh` with a stub `pi`: no model calls, deterministic exit codes, ledger shape, provenance labels |
| A lane that never reported cannot read as clean | exit `5` for a failed dispatch, a missing table, a missing `COVERAGE:` line, or a row inside the table that will not parse; each has a case |
| A clean round cannot certify an unchanged diff | exit `6`; deterministic cases for both directions (refused on an unchanged diff, `0` after a real change) |
| The round budget refuses *before* spending two model calls | live: `0.15 s` and "nothing was dispatched", against ~50-70 s for a dispatch |
| The loop guard keys on location, not wording | live: exit `3` naming `src/pkg/channel.py:108`, a finding that had been reported three times in different words |
| Findings can be verified independently of the reviewer | live: the `channel.py:108` row was reproduced by hand — the tick-ordering fault it named was observed directly — before being believed |
| A change set reads back as a record | `--history` prints every round with finding text, trigger and provenance, plus `--note` decisions; the ledger keeps sentences, not only locations |
| It runs on a repository that is not itself | external use: three change sets, nine rounds, tree left clean (`review-work/` ignored via `.git/info/exclude`) |
| The prompt rule fires in a live session | change set `7b6ce45`: the gate ran when the todo list completed, exit `1` became fix todos, the re-run was gated again, and the third blocking round produced exit `4` which stopped the loop instead of raising the budget. Nothing was committed. The rule now lives in **yolo.md only** — build mode asks for the review by hand, so a watched session does not pay two model calls per completed change set. |
| A commit starts a new change set | an amendment commit was refused by its predecessor's spent budget until the key became the (base, HEAD) pair; the same command then dispatched as round 1 and exited 0 |
| It catches things the agent did not know it had done | the same run flagged that a test file it had touched is inside a drift gate's frozen surface, so the change would have been refused by that repo's own gate — a process violation, not a code defect, found by a reviewer with no context |

## Assumed, not proven

1. **The trigger, partially.** `build.md` says to run the gate when the todo list completes.
   Observed in a live session: the rule is in the loaded prompt, the gate ran on completion,
   exit `1` became fix todos, the loop re-ran, and exit `4` stopped it. The residual is that
   the same agent wrote the rule and followed it; whether a **fresh** session (different
   model, no memory of having authored it) reaches for the gate is unobserved. Watch it on
   the next task started from a clean context.
2. **Exit `6` in the wild.** Proven deterministically; not observed naturally. Every one of
the six live rounds recorded for that `channel.py` change set came back with SEV1/2 (five
blocking, one of them the loop guard), so no clean sample on an unchanged diff ever
occurred to produce a `6`.
3. **Severity stability.** Measured unstable: the same location regraded SEV2 → SEV4, and one
   lane dropped a verified SEV2 on a re-run of identical code. Exit `6` and provenance exist
   because of this; they do not remove it.
4. **Cost.** ~40-90 s and two model calls per round on the configured lanes. `--lanes
   correctness` halves it; `--scope` bounds what is read, not the price of a round.

## Known limits

Observed while stopping on a spent budget: the refusal prints the *last round's*
locations, which may have moved since — it named `tests/test_channel.py:387` after those
tests had been moved to `tests/test_channel_tick.py`. Read the refusal as "these were open
at the last round", not as "these exist now".

See [BACKLOG.md](BACKLOG.md#known-limits-design-not-defects): the change-set key is the
(base, HEAD) pair (two workstreams sharing both still share counters), the gate finds defects
rather than proving absence, `--scope` filters rows rather than the lanes' reading, and the loop guard
trips on a shared line even when the defects differ.

## Use

```sh
git add <paths>            # stage deliberately; isolated lanes review the index
swarm-gate                 # review the working tree against HEAD
swarm-gate --history       # read the change set back: rounds + decisions
swarm-gate --note "…"      # record a decision beside the rounds
```

Exit codes: `0` no SEV1/2 · `1` SEV1/2 present · `2` usage or nothing to review ·
`3` loop guard · `4` round budget · `5` a lane is unusable · `6` clean on an unchanged diff.

## Freeze

Self-review is frozen (see BACKLOG.md). The gate reviewing its own code produced a new set of
plausible defects every round, most of them in the previous round's fixes; that loop has no
natural end and is not what the tool is for. Further work is driven by external use.
