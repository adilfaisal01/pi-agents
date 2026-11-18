# pi-agents

One workspace for five Pi agent tools: per-mode permissions, a two-model code review, the
`subagent` dispatch tool, a review gate, and a lane-provisioning helper.

| Directory | What it is |
| --- | --- |
| [`v-model-agents/`](v-model-agents/) | Agent modes as a pi package (oracle / plan / build / yolo), plus the optional V-model discipline: rows-and-waves gate, freeze/pin, lock-check |
| [`code-review-swarm/`](code-review-swarm/) | Two-model parallel code review; emits one SEV1–SEV4 table |
| [`pi-subagent/`](pi-subagent/) | The `subagent` tool extension (isolated child `pi` processes, per-agent model pins) |
| [`review-lanes/`](review-lanes/) | Lane provisioning: a checkout at a commit, and proof the code it ran came from there |
| [`review-gate/`](review-gate/) | `swarm-gate`: turns the swarm into an exit code, with a loop guard and a round budget |

Four of the five are imported repositories, preserved with their own history (git subtree);
`review-gate/` was written in this tree. Every script derives its own paths, so nothing
depends on where the checkout lives. Provenance and imported commits: [NOTICES.md](NOTICES.md).

## Requirements

- `pi` on `PATH`, with at least one provider configured (the review needs two model ids)
- `bash`, `git`, `python3` for the gate and the self-tests
- `node` ≥ 23 for the mode self-tests (optional — pi loads the extension itself)
- `uv` only for `review-lanes --install`

## Install

### From npm

The whole workspace ships as one package:

```bash
pi install npm:@adilfaisal01/pi-agents
```

That is both extensions (the modes and the `subagent` tool), both skills, the `/review`
template, and the two review lane agents. The two shell tools come with it as `bin`
entries:

```bash
npx -y @adilfaisal01/pi-agents swarm-gate        # review the current change set
npx -y @adilfaisal01/pi-agents review-lanes -h   # provision one lane's checkout
```

The package carries the `pi-package` keyword, so it is eligible for the
[Pi package gallery](https://pi.dev/packages).

Two things worth knowing after an npm install:

- **The model pins are files in the installed package** (under
  `…/node_modules/@adilfaisal01/pi-agents/code-review-swarm/agents/`), and reinstalling
  replaces them. For a change that survives an update, copy the two lane files into
  `~/.pi/agent/agents/`, edit them there — the `subagent` tool prefers user agents by name
  — and run `swarm-gate --agents ~/.pi/agent/agents`.
- **`swarm-gate` needs `python3`, `git` and `pi`.** With `pi` off `PATH` it exits `5` before
  any lane is dispatched: the same code the contract reserves for "a lane is unusable",
  reused here for a pre-dispatch refusal — which also blocks `--history` and `--note` (a
  known limit, see `review-gate/BACKLOG.md`). `--dry-run` still plans the lanes without
  `pi`. **`review-lanes` needs `git` and `python3`** — it runs a Python snippet to assert
  where a package resolves from — and `uv` only for `--install`.

### From a checkout

Pi packages:

```bash
pi install "$PWD/v-model-agents"        # the modes (oracle / plan / build / yolo)
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

## Verifying a checkout

Everything below runs without dispatching a model:

```bash
bash v-model-agents/check.sh                 # modes typecheck + assertions, then the V-model gate self-tests
bash code-review-swarm/scripts/selftest.sh   # frontmatter, lane contracts, both model ids resolve
bash review-lanes/check.sh                   # syntax + lane self-test in a throwaway repo
bash review-gate/check.sh                    # stub-lane suite: policy, exit codes, ledger, cross-file contracts
```

None of them dispatches a model. `selftest.sh` and `install.sh check` ask
`pi --list-models` whether each lane's id resolves: a registry query, no provider request,
though pi may still refresh its own catalogue (set `PI_OFFLINE=1` for a strictly offline
run). Both need `pi` on `PATH` and both fail until you have set the two models above.
`--live` is the one flag that dispatches the lanes, and that costs two model calls.
