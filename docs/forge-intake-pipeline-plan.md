# Plan: forge mode as an intake-first pipeline in any repo

> Written 2026-11-19. Supersedes the "anywhere else: state the change set and work" clause of
> `v-model-agents/modes/prompts/forge.md`. The user's decision, verbatim: **option (a)** — forge
> mode runs the intake path (spec, architect, numbered tasks) *everywhere*, "since the entire point
> of the forge is traceability and auditability for regulation reasons".

## Decisions (user, 2026-11-19)

| fork | decision |
| --- | --- |
| artifact home | `specs/NNN-<slug>/` — identical to the forge's layout, so a spec written here is portable into a harness repo unchanged and the trail is visible in the PR diff |
| commit authority outside a forge checkout | **branch-name guard**: commits only on `forge/<slug>`, only after `forge-gate ratify` landed and `analyze` passes; push + PR only via `forge-gate finish` |
| review depth | correctness lane per task; both lanes + `disposition` on the whole branch before the PR |

## Status — implemented 2026-11-19

Steps 1–3, 5–7 landed; step 4 (a per-dispatch `scope` on `subagent`, LOCAL 7) is **deferred** — see
below. Files: `forge/templates/spec-template.md`, `forge/bin/forge-gate`,
`forge/check-gate.sh`, `v-model-agents/modes/prompts/forge.md`, docs.

`forge-gate` (python3 stdlib, no model, no network) has the verbs `start · analyze · ratify · claim ·
build · review · complete · finish · report`. Design calls made while implementing, each for a stated
reason:

- **`build` runs the tests, not the agent's word.** It executes each `dod_tests` selector
  (`timeout <T> bash <selector>`, stdin `/dev/null`) and records the exit code. "Green" is then a
  recorded fact.
- **`complete` checks the commit, not the claim.** The task commit's changed paths must sit inside the
  task's `scope` (POSIX case-pattern matching, pinned to the template), with this spec's own
  `specs/NNN-<slug>/` exempt so the audit trail can be committed with the work it describes.
- **Latest row wins** for `build` and `review`: a re-run after a fix is the current state, while every
  earlier run stays visible in the trail. (The alternative — any open finding stays open forever —
  makes a clean second pass unable to clear a first one.)
- **`ratify` needs a TTY on stdin *and* stdout**, so the Gate-A row can only come from a person at a
  terminal. A refusal writes nothing.
- **`analyze` never executes anything**, and names the offender in every rejection (`T003: satisfies
  FR-009 is not defined in the prose requirements`).

Verification: `bash forge/check-gate.sh` → **36 fixtures**, all green, including one failing fixture
per invariant, the vacuous-scope advisory, ratify-off-a-pipe, a real pty ratification, claim before
ratification, claim with an incomplete dependency, a red build, an unreviewed completion, open
SEV1/SEV2, a scope escape, `finish` on an incomplete trail, and a malformed `records.jsonl` line.
`bash scripts/check-package.sh` → seven suites green.

### Follow-on: worktree isolation (2026-11-19, same day)

`claim` is now the isolation point, per the user: the architect and the spec are written in the repo
checkout, then each claimed task is worked in its own git worktree, "similarly to the forge".

- `<repo>.forge/<slug>/` — integration worktree on `forge/<slug>` (the PR branch).
- `<repo>.forge/<slug>/<T00N>/` — task worktree on `forge/<slug>-<T00N>`, cut from the integration head.
- `build` runs the selectors in the task worktree; `complete` fast-forwards the integration branch and
  refuses if it moved since the claim; `finish` copies `specs/<slug>/` onto the branch as a
  gate-authored `audit:` commit (so the PR carries the trail); new `clean [--force]` removes the
  worktrees and refuses a dirty one.
- Naming: `forge/<slug>-<T00N>`, not `forge/<slug>/<T00N>` — git refuses a ref under a name that is
  already a branch (`cannot lock ref … 'refs/heads/forge/001-x' exists`). Found by the fixtures, not by
  reading.
- Worktree creation refuses a *tracked* change in the checkout (the branch must start from a chosen
  tree) and ignores untracked files (the spec being authored).

Verified: 46 gate fixtures, including the worktrees existing where the claim says, the checkout
staying on its own branch, `clean` refusing a dirty worktree, and `complete` refusing a commit that is
not on the task branch. Live end-to-end in a throwaway repo: `start → analyze → pty ratify → claim →
build → review → complete` fast-forwarded `forge/001-slugify` to the task commit with the checkout
untouched on `main`; against a local bare remote, `finish` created `audit: specs/001-slugify (spec +
trail)` (spec + understanding + records), pushed it, and refused only at `gh pr create` (no GitHub
remote) — the one step not proven end-to-end.

### Follow-on: evidence verification (2026-11-19, step 1 of the harness parity list)

The harness's acceptance gate checks that `sc_evidence` is *real*; `forge-gate` only checked its shape.
Now `complete` does the harness's checks against the task commit: `missing-from-tree`, symlink refusal,
`must_match` / `must_not_match` against the committed blob, and an `evidence-existence-only` advisory
recorded in the trail when a criterion asserts nothing. 52 fixtures (was 46).

One fixture earned its keep twice: it wrote through a symlinked evidence file (`ln -s ../../tests/run.sh
src/evidence/e1.txt`, then `printf >`), which rewrote `tests/run.sh` and was then caught by the *scope*
check — a live demonstration of why the symlink refusal exists.

### Follow-on: the PR is reviewed before it exists (2026-11-19, step 2)

The forge's reviewer fired *after* `gh pr create` and its exit was swallowed, so a PR could be posted
unreviewed. Here the whole-branch two-lane review is recorded **first** (`review --branch`), `finish`
refuses while it is missing or has open SEV1/SEV2, and the review then appears three times: in the PR
body, as a posted `gh pr comment`, and as a `review-posted` row. One renderer feeds body, comment and
`report`. `review --branch --post` re-posts after a fix and refuses outright when no PR exists yet.

63 fixtures (was 52), including an end-to-end `finish` against a bare remote with a stubbed `gh`.

Two self-inflicted bugs found while building it, both worth remembering: replacing the
`cmd_review`…`cmd_complete` span silently deleted the evidence helper that sat between them (the
fixture caught it as "no task-complete row", not as a crash, because stderr was discarded), and
`git log | grep -q` under `set -o pipefail` reports failure — `grep -q` exits early, `git` dies of
SIGPIPE, `pipefail` propagates 141. Capture into a variable and match with `case`.

**Still deferred:** LOCAL 7 (`scope` per dispatch on `subagent`). Without it a builder is not
stopped from writing outside its task's scope *during* the run — it is caught at `complete`, which
refuses the task and names the paths. That is later and coarser than a dispatch-time guard, but it is
the same mechanical check, and delaying it kept this change set reviewable.

## The pipeline this must produce

```
objective
  → architect (clarify → spec-authoring)        → specs/NNN-<slug>/spec.md   [draft]
  → Gate A: understanding.md + human ratify    → records.jsonl: ratified{sha}
  → decompose (decompose skill)                → Task Breakdown T001..T0NN  [ready-for-tasks]
  → per task: claim → builder dispatch         → one commit per task + records rows
  → per task: review (lanes) → disposition      → SEV1/SEV2 = 0 recorded
  → all tasks done → branch push → PR          → PR body generated from spec + records
```

Every arrow writes an append-only row. Nothing is "done" because an agent said so; it is done
because a deterministic gate re-read it and a row says so.

## Why the current mode is wrong for this

`prompts/forge.md` says: outside a forge checkout, *state the change set in one line, then work*.
A probe on a blank repo confirmed the behaviour — it asked one stack/scope question, wrote
`slugify.py` + 27 tests, and stopped. Correct per the contract, and **untraceable**: no spec, no
numbered tasks, no record of what was decided or by which model, no human sign-off. For a
regulated artefact that is the failure mode, not the happy path.

## What the forge gives us, and what a bare repo does not have

| forge harness piece | bare repo | portable replacement |
| --- | --- | --- |
| `harness/intake.sh start` scaffolding | absent | the **mode** scaffolds `specs/NNN-<slug>/` from a shipped template |
| `harness/intake.sh analyze` (Gate B, nine invariants + FR↔task) | absent | `forge-gate analyze` (python, offline, fixture-tested) |
| `cmd_ratify` TTY gate + sha256 token | absent | `forge-gate ratify` (TTY-gated, appends a signed-by-who token row) |
| `.harness/*.json` captured verdicts | absent | `specs/NNN-<slug>/records.jsonl` (append-only) |
| `review-task.sh` + `reviewers.config` | absent | the swarm + `forge-review` bridge, per task and at the end |
| `run-task.sh start/finish` (bead claim, branch, PR) | absent | `forge-gate claim` / `forge-gate finish` (branch + records + `gh pr create`) |
| beads (`bd`) | absent **and not wanted** | task ids `T001..` in the breakdown are the ledger; no second id space |

The portable pipeline deliberately **does not** grow a bead database: the spec's numbered tasks
already are stable, reviewable ids, and a second id space is one more thing an auditor has to
reconcile.

## Steps

| # | what changes | why | how it is checked | may touch |
| --- | --- | --- | --- | --- |
| 1 | `forge/templates/spec-template.md` — the pi render of the forge's template: same sections, same nine invariants, same Task-Breakdown block, without `harness/`, `bd`, beads or `.claude` references; add an `## Audit` section naming `records.jsonl` and the ratification row | a spec schema is the audit's spine; it cannot be improvised per run, and a bare repo has no template to read | `forge-gate analyze` reads *this* file as normative; a fixture spec built from it passes, and each of the nine invariants has a named failing fixture | `forge/templates/**` |
| 2 | `forge/bin/forge-gate` (python3, stdlib only, no network, no model) with verbs `start`, `analyze`, `ratify`, `claim`, `finish`, `report`. `start` scaffolds `specs/NNN-<slug>/`; `analyze` runs the nine invariants + bidirectional FR↔task and names the offender; `ratify` refuses outside a TTY, binds `sha256(understanding.md)`, appends the row; `claim`/`finish` write task rows and drive the branch + PR; `report` prints the audit trail | "traceable" must mean *re-runnable by a third party*, not "the agent wrote a nice summary". This is the tier that outlives the session | `forge/check-gate.sh` fixture suite: 9 failing fixtures (one per invariant), 1 passing, ratify refuses on a pipe, `claim` refuses an unratified spec, `finish` refuses a task whose `dod_tests` were never recorded green | `forge/bin/**`, `forge/check-gate.sh` |
| 3 | `records.jsonl` schema (append-only, one JSON object per line, `ts` + `who` + `model` + `event` + payload). Events: `spec-scaffolded`, `asked`, `decided`, `ratified`, `task-claimed`, `build-recorded{tests:cmd,green:true}`, `review-recorded{verdict,findings[]}`, `disposition-recorded[]`, `task-complete`, `pr-opened{url}` | audit rows are the difference between "we think it was reviewed" and "here is the row, its model, and the verdict". Append-only means a later row can never soften an earlier one | `forge-gate report` renders the trail; a spec with a `task-complete` row and no `build-recorded` green row is rejected by `analyze --strict` | `forge/bin/**`, `forge/templates/**` |
| 4 | `pi-subagent` LOCAL 7: an optional per-call `scope` on a dispatch, checked like `write_scope` | a builder's writable surface is a property of the TASK (`scope` in the breakdown), not of the agent file. Without this, "builders take tasks" is unenforceable and the `scope` field is decoration | selftest: a dispatch with `scope: ["src/**"]` that writes `docs/x.md` fails the run, naming the path; a call with no `scope` behaves exactly as today | `pi-subagent/{index.ts,agents.ts,selftest.mjs,README.md}` |
| 5 | `prompts/forge.md` rewritten to the pipeline: the mode is the **architect** (clarify → spec → Gate A), then dispatches `builder` per task with that task's `scope`, then the review, then the PR. No "state the change set and work" shortcut; the shortcut survives only as `--agent-mode forge` + an explicit "one-off, no spec" instruction FROM THE HUMAN, recorded as `waived` in the trail | this is the whole point of the request; the contract must not offer an untraceable path by default | a live probe on a blank repo: the first action is a spec scaffold + a clarify question, not a code write; `forge-gate report` shows the trail | `v-model-agents/modes/prompts/forge.md` |
| 6 | The git carve-out, narrowed by a **branch-name guard**: in forge mode, commits are allowed on a `forge/<slug>` branch only, and only after `ratify` and after `analyze` passes; push + `gh pr create` only from `forge-gate finish`. Everything else keeps the standing rule (no commit, no push, no tag, no rewrite) | "once all done send a PR" needs commit authority, but an unguarded carve-out is how a standing rule quietly dies. A branch prefix + two gate preconditions make the exception mechanical | selftest/live probe: a commit on `main` in forge mode is refused with the reason; a commit on `forge/x` after ratify succeeds; `finish` refuses when the last task has no review row | prompt + `forge-gate`, plus `v-model-agents/modes/*` docs |
| 7 | Docs: `forge/README.md` (the pipeline, the trail, the waiver), `v-model-agents/modes/README.md` (forge mode = the pipeline), root `README.md`, `CHANGELOG.md`, and this plan's Status | the mode's contract is the thing users read before trusting it | the docs name each gate and what it refuses | docs only |

## The trail, concretely

```jsonc
// specs/007-slugify/records.jsonl  (append-only; one object per line)
{"ts":"2026-11-19T20:10:04Z","event":"spec-scaffolded","who":"agent:architect","model":"anthropic/claude-sonnet-4-5","spec":"specs/007-slugify/spec.md"}
{"ts":"...","event":"asked","who":"agent:architect","question":"Stack?","answer":"Python, stdlib only"}
{"ts":"...","event":"ratified","who":"human:adil","sha":"sha256:9f2c…","understanding":"understanding.md"}
{"ts":"...","event":"task-claimed","task":"T001","who":"agent:builder","model":"ollama-cloud/deepseek-v4.1-flash"}
{"ts":"...","event":"build-recorded","task":"T001","command":"python3 -m pytest -q","exit":0,"green":true}
{"ts":"...","event":"review-recorded","task":"T001","verdict":"CONCERNS","findings":[{"id":"F1","sev":"SEV3","location":"slugify.py:141"}]}
{"ts":"...","event":"disposition-recorded","task":"T001","rows":[{"id":"F1","disposition":"CONFIRMED"}]}
{"ts":"...","event":"task-complete","task":"T001","commit":"<sha>"}
{"ts":"...","event":"pr-opened","url":"https://github.com/…/pull/12"}
```

`who` distinguishes `human:<git user>` from `agent:<role>`, and every agent row carries the model
that produced it — which is the other half of why role→model pins matter here.

## Verification (what a stranger runs)

```bash
bash forge/check-gate.sh                     # fixtures: nine invariants, ratify-on-a-pipe refusal, claim-before-ratify refusal
bash scripts/check-package.sh                # manifest + packed tarball + every suite
# live, on a blank repo:
pi --agent-mode forge --tools ...            # /mode forge, "slugify text for URLs"
forge-gate report specs/001-slugify          # the trail: asked → ratified → claims → builds → reviews → task-complete
git log --oneline                            # one commit per task, on forge/001-slugify
gh pr view                                   # body generated from the spec + trail
```

## Risks

- **The gate is the product.** If `forge-gate analyze` is lenient, every downstream claim is
  theatre — the same reason the forge's own `analyze` is "pure string cross-reference, no judgment,
  no leniency". Fixtures must be adversarial (one per invariant, plus a vacuous-glob advisory).
- **Cost.** Per-task review on two lanes plus a final merge review is roughly `2 × tasks + 2` model
  calls. A five-task spec is ~12 calls. Mitigation in the plan below (open question 3).
- **A waiver is a hole.** `forge-gate` must record every waiver with the human's words; a waived
  run is auditable as waived, never silently equivalent to a governed one.
- **Two implementations of the invariants** (the forge's `intake.sh analyze` and `forge-gate
  analyze`) will drift. Cheaper alternative considered and rejected: shelling out to the forge
  harness, which does not exist in the repos this is for.

## Unknowns

- Whether `gh` is the PR tool for every repo this runs in, or whether the PR step should be
  `git push` + a PR URL template the human pastes. (`gh` is present here.)
- Whether per-task commits should be squashed at the end for a clean PR, or kept as the audit
  spine. Keeping them is the traceability argument; a reviewer's diff is noisier.
