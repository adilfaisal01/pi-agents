# code-review-swarm

Two models review the same code at the same time, each with its own context, and the
results merge into one numbered table:

| # | SEV | LOCATION | FINDING | TRIGGER | LENS | CONF |
|---|-----|----------|---------|---------|------|------|
| 1 | SEV1 | `src/ctl/kf.py:88` (`update`) | `P` is overwritten before the gain uses the prior, so the covariance never converges | `update(P=I, H=I)` for 50 steps: `trace(P)` stays at `n_x` instead of shrinking | both (C1, Q4) | high |

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

The `subagent` tool ([`pi-subagent`](https://github.com/adilfaisal01/pi-subagent), a
standalone package forked from pi's example extension) spawns children:

```
pi --mode json -p --no-session -ne --model <provider>/<id> --tools read,grep,find,ls,bash
```

`-ne` matters: it stops the child from inheriting the parent session's extensions, so
whatever the parent has loaded cannot silently strip a lane's tools, and a child cannot
re-enter `subagent`. The child's tool list comes from the agent frontmatter, not from the
caller. Nothing here reads a mode, a role, or any config beyond the two agent files.

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

## Isolation: each lane gets its own checkout

A subagent child inherits the parent's working directory (`resolveAgent(ctx.cwd, …)`) and its
whole environment. Two lanes then read one mutable tree at different moments — so their
disagreement can mean the tree changed, not that the code is ambiguous — and a repro written
to `/tmp` resolves the package through the inherited venv, against whatever tree that venv
was installed from.

`scripts/lane-prepare.sh prepare` closes both gaps:

- The scope is **materialised as a commit**. When it is the staged diff there is nothing to
  check out — the index is not a commit — so `git write-tree` + `git commit-tree` produce a
  dangling commit holding exactly the index. HEAD, the index, the branch and the stash list
  are untouched. Otherwise the commit is `HEAD`.
- Each lane gets a same-depth worktree at that commit, via
  [`review-lanes`](https://github.com/adilfaisal01/review-lanes), which refuses unless
  `import <pkg>` resolves *inside* the worktree. Same sha, two trees.
- A lane may write only under `review/` (`write_scope` in its frontmatter, enforced by the
  dispatcher's post-check after the run). With separate trees that check is unambiguous —
  in a shared tree, one lane's write would be attributed to the other.

`MODE=shared` means `review-lanes` was not found: the review still runs, in your tree, with
`/tmp` for repros, and the two tables are no longer guaranteed to describe the same code.
Report it as the weaker review it is.

```sh
./scripts/lane-prepare.sh prepare   # MODE= SHA= PARENT= CWD_CORRECTNESS= CWD_QUALITY=
./scripts/lane-prepare.sh clean     # the next prepare refuses a dirty worktree, by design
```

## Install

```sh
git clone <this repo> && cd code-review-swarm
scripts/install.sh          # symlinks the two lanes into ~/.pi/agent/agents
scripts/install.sh check    # verifies the links
scripts/selftest.sh         # static checks: frontmatter, model ids, write_scope, contracts
scripts/selftest.sh --live  # + a real two-lane dispatch at tests/fixture/
scripts/lane-prepare.sh prepare   # scope -> sha -> one worktree per lane (needs review-lanes)
```

The **skill** and the **`/review` prompt template** load from this package's `skills/` and
`prompts/` directories once the repo is installed as a pi package (it is one:
`keywords: ["pi-package"]`, `pi.skills`, `pi.prompts`). The **agents** cannot: pi has no
package resource for agent definitions, which are only read from `~/.pi/agent/agents` and the
nearest `.pi/agents`. Hence `install.sh` — a symlink, so the checkout stays authoritative and
editing a lane here takes effect immediately.

Installing the package makes the checkout the single source of truth for the skill, so remove
any copy at `~/.pi/agent/skills/code-review-swarm/`; `install.sh` warns rather than deleting
it for you.

## Invoke it

Three ways in, in increasing explicitness:

| Entry | How |
|---|---|
| Skill, model-driven | just ask — *"review the staged diff"*, *"review src/ctl with two models"*. Pi lists the skill in the system prompt and loads it when the request matches. |
| `/review [scope]` | prompt template shipped in this package. Expands to the skill's procedure with the scope filled in; no arguments means the staged diff. |
| `/skill:code-review-swarm [scope]` | forces the skill body into context even if the model would not have picked it. Works even with `enableSkillCommands` off. |

`/reload` picks up a changed template or skill in an active session; a new session picks
them up on start. Run `/review` with no argument to review whatever is staged.

## Use

Ask for a review, or type `/review`; the skill drives the rest.

```
review the staged diff
review src/tinycalc/ with two models
```

Scope rules the skill applies: named paths win; "my changes" means the staged diff, else
`main...HEAD`; nothing named means ask once or default to the staged diff and say so. Both
lanes get the identical scope string — different scopes produce incomparable tables.

Merge rules: dedupe on the claim, not on wording or class (same statement ±3 lines **and**
the same broken invariant → one row, `LENS = both`; two distinct defects on adjacent lines
stay two rows); silence is not a veto (a lone SEV1 stays SEV1); contradictions stay in the
table marked `DISPUTED`; quality severities are mapped onto the merged scale rather than
copied; every file in scope must appear in a lane's `COVERAGE:` line or be listed under
`UNCOVERED:`; and the table holds lane rows only — a third opinion is a labelled
`dispatcher note`, not a row. Lane ids (`C3`, `Q7`) survive as provenance.

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
prompts/review.md              `/review [scope]` prompt template
scripts/install.sh             symlink lanes into ~/.pi/agent/agents
scripts/lane-prepare.sh        scope -> commit -> one worktree per lane; `clean` discards
scripts/selftest.sh            static + --live checks (LANE_CWD=<worktree> runs a lane in one)
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
- **Writes.** Lanes carry no `write`/`edit` tool, and with a prepared worktree they declare
  `write_scope: review`, so a child that writes anywhere else fails the run and the review is
  discarded. In `MODE=shared` that check has nothing sound to compare, so it is toolset-only —
  use a container or a worktree if it matters.

## Licence

MIT.
