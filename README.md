# code-review-swarm

Two models review the same code at the same time, each with its own context, and the
results merge into one numbered table:

| # | SEV | LOCATION | FINDING | LENS | CONF |
|---|-----|----------|---------|------|------|
| 1 | SEV1 | `src/ctl/kf.py:88` (`update`) | `P` is overwritten before the gain uses the prior, so the covariance never converges | both (C1, Q4) | high |

- **correctness lane** — logic errors, undefined behaviour, memory faults, edge cases,
  races, floating-point error, API misuse.
- **quality lane** — design, convention, naming, duplication, maintainability,
  testability, error-handling gaps.

Each lane is a separate `pi` process on a separate model. They never see each other, so
agreement is evidence and disagreement is a lead. This is not one model role-playing two
reviewers; the transcripts come from two different providers' completions.

## Why two models rather than two prompts

A single model reviewing the same file twice converges: the second pass inherits the first
pass's framing and its blind spots. Two different models fail differently — a correctness
miss in one is often caught by the other — and the disagreement itself is the signal worth
reading. The lanes are also deliberately non-overlapping in scope, which keeps the merged
table from double-counting one defect as two findings.

## How the orchestration actually happens

The `subagent` tool (pi's example extension, vendored into
[`v-model-agents`](https://github.com/adilfaisal01/v-model-agents)) spawns children:

```
pi --mode json -p --no-session -ne --model <provider>/<id> --tools read,grep,find,ls,bash
```

`-ne` matters: it stops the child from inheriting the parent session's extensions, so a mode
guard loaded in the parent (oracle blocks `write`) cannot silently strip a lane's tools, and
a child cannot re-enter `subagent`. The child's tool list comes from the agent frontmatter,
not from the caller.

Parallel mode is one tool call with a `tasks` array; pi runs the children concurrently and
returns both transcripts.

### Model selection

The `subagent` tool has **no per-call model parameter**. The model is a frontmatter field on
the agent that becomes `--model`:

| Want | Do |
|---|---|
| Change a lane's model | edit `model:` in `agents/<lane>.md` — effective on the next dispatch, no restart |
| A one-off pair | write `~/.pi/agent/agents/review-lane-a.md` / `-b.md` with the models, dispatch, delete |
| Inherit | omit `model:` — child takes the session's model **and** thinking level |

Setting `model:` drops the inherited thinking level. Ids are provider-qualified; find them
with `pi --list-models` (it fuzzy-matches, so a miss returns lookalikes rather than nothing).

## Install

```sh
git clone <this repo> && cd code-review-swarm
scripts/install.sh          # symlinks the two lanes into ~/.pi/agent/agents
scripts/install.sh check    # verifies the links
scripts/selftest.sh         # static checks: frontmatter, model ids, read-only toolsets
scripts/selftest.sh --live  # + a real two-lane dispatch at tests/fixture/
```

The **skill** loads from this package's `skills/` directory if you install the repo as a pi
package (it is one: `keywords: ["pi-package"]`, `pi.skills`). The **agents** cannot: pi has no
package resource for agent definitions, which are only read from `~/.pi/agent/agents` and the
nearest `.pi/agents`. Hence `install.sh` — a symlink, so the checkout stays authoritative and
editing a lane here takes effect immediately.

If you also keep a copy at `~/.pi/agent/skills/code-review-swarm/`, remove it once the
package is installed; `install.sh` warns rather than deleting your file.

## Use

Ask for a review; the skill drives the rest.

```
review the staged diff
review src/tinycalc/ with two models
```

Scope rules the skill applies: named paths win; "my changes" means the staged diff, else
`main...HEAD`; nothing named means ask once or default to the staged diff and say so. Both
lanes get the identical scope string — different scopes produce incomparable tables.

Merge rules: dedupe on site not wording (same file, line ±3, same defect class → one row,
`LENS = both`); silence is not a veto (a lone SEV1 stays SEV1); contradictions stay in the
table marked `DISPUTED`; lane severities are re-normalised and rows renumbered `1..N` by
severity. Lane ids (`C3`, `Q7`) survive as provenance.

Severity: **SEV1** crash/corruption/wrong result/exploitable · **SEV2** wrong on a realistic
input or latent on a reachable path · **SEV3** wrong on an unlikely input, or fragile ·
**SEV4** polish.

### Fallback

If `subagent` is unavailable, an agent name is unknown, or a model is unreachable, the skill
runs both lenses sequentially in one session under the same contracts and labels the header
`single-model fallback`. A fallback is never presented as a two-model run.

## Repository layout

```
agents/review-correctness.md   correctness lane: lens, rules, output contract, model
agents/review-quality.md       quality lane: same, different lens and model
skills/code-review-swarm/      the skill: scope, dispatch, merge, severity, report
scripts/install.sh             symlink lanes into ~/.pi/agent/agents
scripts/selftest.sh            static + --live checks
tests/fixture/buggy.py         8 documented defects, ground truth in fixture/README.md
```

## Verification

`scripts/selftest.sh` asserts the things that can be asserted without pinning model output:
frontmatter complete, every model id resolves in the registry, no lane carries `write`/`edit`,
each lane states the table contract, and — with `--live` — that a real dispatch returns a
`| ID | SEV |` header, at least one finding row citing the fixture, and a `COVERAGE:` line.

Model routing itself was verified by negative probe: a scratch agent frontmattered with
`model: ollama-cloud/definitely-not-a-model` fails with the provider's
`404 model "definitely-not-a-model" not found`, so the field demonstrably reaches the child.

The fixture's ground truth is **not** asserted. Models are not deterministic; a test that
requires finding B5 is a flake generator, not a gate.

## Limitations

- **Cost.** Two pro models over a repo is a large spend. Scope to a diff or a directory.
- **Not a gate.** No assertion on review quality is possible; this finds defects, it does not
  prove absence. Nothing here replaces tests or a type checker.
- **False positives.** Lanes are instructed to state a concrete trigger per finding; a row
  without one is a defect of the review, and `CONF` records whether anyone executed it.
- **Read-only by toolset, not by sandbox.** Lanes get `bash` for `rg`/`git`, and `bash` can
  write. `--tools` omits `write`/`edit` so the model can only write by piping; treat a child
  diff as a review failure and discard it. Use a container or a worktree if that matters.

## Licence

MIT.
