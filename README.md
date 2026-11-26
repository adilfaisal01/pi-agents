# pi-agents

One workspace for the Pi agent tools: per-mode permissions, a two-model code review, the
`subagent` dispatch tool, a review gate, a lane-provisioning helper, and the shinro-forge
architect workflow (five skills, four role contracts).

| Directory | What it is |
| --- | --- |
| [`v-model-agents/`](v-model-agents/) | Agent modes as a pi package (oracle / plan / build / yolo / forge), plus the optional V-model discipline: rows-and-waves gate, freeze/pin, lock-check |
| [`code-review-swarm/`](code-review-swarm/) | Two-model parallel code review; emits one SEV1–SEV4 table |
| [`pi-subagent/`](pi-subagent/) | The `subagent` tool extension (isolated child `pi` processes, per-agent model pins, a `subagent-models.json` role→model map, a write-scope post-check) |
| [`review-lanes/`](review-lanes/) | Lane provisioning: a checkout at a commit, and proof the code it ran came from there |
| [`review-gate/`](review-gate/) | `swarm-gate`: turns the swarm into an exit code, with a loop guard and a round budget |
| [`forge/`](forge/README.md) | The shinro-forge architect workflow as a pi package surface: the `clarify`, `spec-authoring`, `decompose`, `forge-review` and `forge-workflow` skills, plus the `architect` / `builder` / `spec-reviewer` / `disposition` role contracts |

Four of the five are imported repositories, preserved with their own history (git subtree);
`review-gate/` was written in this tree. Every script derives its own paths, so nothing
depends on where the checkout lives. Provenance and imported commits: [NOTICES.md](NOTICES.md).

## Requirements

- `pi` on `PATH`, with at least one provider configured (the review needs two model ids)
- `bash`, `git`, `python3` for the gate and the self-tests
- `node` ≥ 23 for the mode self-tests (optional — pi loads the extension itself)
- `uv` only for `review-lanes --install`

## Install

### From git — the supported channel

```bash
pi install git:github.com/adilfaisal01/pi-agents@v0.2.1
```

That is one package: both extensions (the modes and the `subagent` tool), both skills, the
`/review` template, the two review lane agents, and the five forge skills with their four
role contracts. It is cloned to
`~/.pi/agent/git/github.com/adilfaisal01/pi-agents` and pinned to the tag — `pi update
--extensions` reconciles the checkout but does not move a configured ref, so changing that
number **is** the upgrade.

The two shell tools live in that checkout. A git install puts nothing on `PATH`, so name
the scripts:

```bash
~/.pi/agent/git/github.com/adilfaisal01/pi-agents/review-gate/bin/swarm-gate
~/.pi/agent/git/github.com/adilfaisal01/pi-agents/review-lanes/bin/review-lanes -h
```

Two things worth knowing after an install:

- **The model pins are files in the installed package** (under
  `…/git/github.com/adilfaisal01/pi-agents/code-review-swarm/agents/`), and moving the ref
  replaces them. For a change that survives an update, copy the two lane files into
  `~/.pi/agent/agents/`, edit them there — the `subagent` tool prefers user agents by name
  — and run `swarm-gate --agents ~/.pi/agent/agents`.
- **`swarm-gate` needs `python3`, `git` and `pi`.** With `pi` off `PATH` it exits `5` before
  any lane is dispatched: the same code the contract reserves for "a lane is unusable",
  reused here for a pre-dispatch refusal — which also blocks `--history` and `--note` (a
  known limit, see `review-gate/BACKLOG.md`). `--dry-run` still plans the lanes without
  `pi`. **`review-lanes` needs `git` and `python3`** — it runs a Python snippet to assert
  where a package resolves from — and `uv` only for `--install`.

### From npm — frozen at 0.1.1

`npm:@adilfaisal01/pi-agents` still installs, at **0.1.1**, which is what the
[Pi package gallery](https://pi.dev/packages) would list. Nothing newer goes there: the
registry's OTP and trusted-publisher policy turned every release into a manual ritual, and
a git tag does the same job without one. Treat npm as history; the tag above is the
version this repo is at.

### From a checkout

Pi packages:

```bash
pi install "$PWD/v-model-agents"        # the modes (oracle / plan / build / yolo / forge)
pi install "$PWD/code-review-swarm"     # the skill + /review template
pi install "$PWD/pi-subagent"           # the subagent tool the lanes dispatch through
code-review-swarm/scripts/install.sh    # symlink the two lane agents into ~/.pi/agent/agents
```

`pi install` records the declaration in `~/.pi/agent/settings.json`. Pass a path you are
happy to keep: `"$PWD/v-model-agents"` becomes an absolute entry. Pi also accepts a
relative local path, resolved from the settings file that contains it — absolute is just
the form that cannot be misread when the file moves.

Agent definitions are the exception: pi has no package resource for them, which is why
`install.sh` symlinks `review-correctness.md` and `review-quality.md` into
`~/.pi/agent/agents/` (override the directory with `PI_AGENT_DIR`).

Scripts, not packages — symlink them onto `PATH`:

```bash
ln -s "$PWD/review-lanes/bin/review-lanes" ~/.local/bin/review-lanes
ln -s "$PWD/review-gate/bin/swarm-gate"    ~/.local/bin/swarm-gate
```

Both shims resolve their own symlink, so the checkout stays the single source of truth.

## Set the two review models

The review lanes pin `model: <provider>/<id>` in
`code-review-swarm/agents/review-{correctness,quality}.md`, and the ids shipped there are
examples from one setup. A package cannot know which providers you have, and the tooling
refuses to guess: `review-gate` errors on a lane with no pinned model, and a child process
handed an id you do not have fails with the provider's `404 model … not found`. Do this
once, before the first review:

```bash
pi --list-models | head -20                                    # provider/id pairs you have
$EDITOR code-review-swarm/agents/review-correctness.md         # the model: line
$EDITOR code-review-swarm/agents/review-quality.md             # a second, different id
code-review-swarm/scripts/install.sh check                     # fails until both resolve
```

Two *different* ids is the point: two prompts on one model share blind spots. Both checks
warn — rather than fail, since a single-model run is a documented fallback — when the two
lanes pin the same id.

## Optional: a todo tool

This workspace does not bundle one, and **no prompt here consults a list**: yolo mode runs
`swarm-gate` "when the change is finished", whether or not a todo exists. A todo tool is
per-session scratch space the model writes to — not a trigger.

It is still the natural place to keep the fix items the gate hands back — `review-gate`'s
README turns every SEV1/SEV2 row into a *fix todo* on exit `1` — and that list is easier to
follow when the model has somewhere to write it.

If you don't already have one,
[`@juicesharp/rpiv-todo`](https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-todo)
(MIT, third-party, not vendored here) gives the model a `todo` tool, rendered as a live
overlay that survives `/reload` and compaction:

```bash
pi install npm:@juicesharp/rpiv-todo
```

It is not part of `@adilfaisal01/pi-agents`, so the install above does not pull it in, and
installing it changes nothing on its own — you (or a prompt you write) drive the loop, and
the gate fires on a finished change either way.

## The forge architect workflow

`forge/` carries the shinro-forge intake workflow on the package surface, so a pi session gets
it without sitting inside a forge checkout:

**The pipeline is the point:** `objective → spec → Gate A (human) → numbered tasks → build each →
review each → one PR`, with an append-only `specs/NNN-<slug>/records.jsonl` beside it. `forge-gate`
(`forge/bin/`, a `bin` entry) is the deterministic tier: it scaffolds the spec, runs the nine
invariants, refuses a ratification off a TTY, executes each task's `dod_tests` itself, checks a
task's commit against its declared `scope`, and refuses the PR while any of that is missing. Design:
[`docs/forge-intake-pipeline-plan.md`](docs/forge-intake-pipeline-plan.md).

- **Skills** (`forge/skills/`): `clarify` (the one-question-at-a-time loop that bounds
  *questions*, never coverage), `spec-authoring` (stories, FR-NNN, measurable SC-NNN),
  `decompose` (the machine-parseable Task Breakdown), `forge-review` (two-model PR review,
  bridged to the forge's machine-checkable record), `forge-workflow` (bead → worktree →
  test-first → PR in a harness checkout).
- **Role contracts** (`forge/agents/`, read by the `subagent` tool via `pi.agents`):
  `architect` (writes only under `specs/`, never ratifies), `builder` (only under `sandbox/`,
  never merges), and the read-only `spec-reviewer` and `disposition`.

There is no `reviewer` here, deliberately: one model reviewing a PR cannot make its own
agreement evidence, so a forge PR review is the **code-review-swarm** — two lanes, two
models — with `forge-review` turning the merged SEV1–SEV4 table into the sentinel-bounded
JSON block the harness extracts for `.harness/review/<pr>.json` and the `disposition`
adjudicator. Both lanes feed it; quality findings are normalised, not filtered out.

**The roles run on different models.** A dispatched role's model comes from
`subagent-models.json` (user + project layers, keyed by agent name) so the agent files stay
portable; the architect *as the session* takes the `forge` mode's `model` from an override file;
and a PR review takes its model from the forge's own `harness/reviewers.config` when the harness
owns it, or from the swarm lanes when it does not. [forge/README.md](forge/README.md#role--model)
has the table and a worked map.

These are the **pi render** of the forge's skills and roles, and pi's rendering is a real
difference, not a formatting one: `ask_user_question` is named literally, and every claim
that a hook enforces something is replaced by what actually enforces it here. The forge's
`.claude/hooks/**` gates do **not** fire under pi — neither do its `Stop` and `PostToolUse`
hooks. What does hold is host-side (the harness floors: `intake.sh spec-review`'s captured
verdict, the TTY-gated `ratify`, Gate B `analyze`; the git hooks; the human merge) plus two
pi-shaped facts: a dispatched role gets exactly the tools and `write_scope` in its contract,
and a headless pi run has no ask tool at all. The pi tiers that would close the rest — an
`architect`/`builder` agent mode and gondolin's mounts — are planned, not shipped
([the port plan](docs/forge-architect-port-plan.md)).

The skills read `harness/intake-categories.json` and `templates/spec-template.md` from the
repo they are used in; they ship the protocol, not the harness. Provenance and the relation
to the forge's own copies: [forge/README.md](forge/README.md).

## Verifying a checkout

Everything below runs without dispatching a model:

```bash
bash v-model-agents/check.sh                 # modes typecheck + assertions, then the V-model gate self-tests
bash code-review-swarm/scripts/selftest.sh   # frontmatter, lane contracts, both model ids resolve
bash review-lanes/check.sh                   # syntax + lane self-test in a throwaway repo
bash review-gate/check.sh                    # stub-lane suite: policy, exit codes, ledger, cross-file contracts
bash forge/check-role-models.sh              # the role→model sample: keys match the shipped roles, ids resolve
bash forge/check-gate.sh                     # 36 gate fixtures: nine invariants, ratify-off-a-TTY, scope escapes
bash scripts/check-package.sh                # everything above, plus manifest and packed-tarball checks
```

None of them dispatches a model. `selftest.sh` and `install.sh check` ask
`pi --list-models` whether each lane's id resolves: a registry query, no provider request,
though pi may still refresh its own catalogue (set `PI_OFFLINE=1` for a strictly offline
run). Both need `pi` on `PATH` and both fail until you have set the two models above.
`--live` is the one flag that dispatches the lanes, and that costs two model calls.
