# pi-agents

One workspace for the Pi agent tooling that used to live in four separate repositories.

Each top-level directory is an imported repository, preserved with its own history
(git subtree). Subdirectories are not reorganised: every script inside them derives
its own paths, so nothing in this tree depends on where it is checked out.

| Directory | What it is | Origin |
| --- | --- | --- |
| [`v-model-agents/`](v-model-agents/) | Agent workflow discipline: modes (oracle/plan/build/yolo), rows-and-waves gate, freeze/pin, lock-check | `adilfaisal01/v-model-agents` |
| [`code-review-swarm/`](code-review-swarm/) | Two-model parallel code review; emits one SEV1–SEV4 table | `adilfaisal01/code-review-swarm` |
| [`pi-subagent/`](pi-subagent/) | The `subagent` tool extension (isolated child `pi` processes, per-agent model pins) | `adilfaisal01/pi-subagent`, diverged from upstream |
| [`review-lanes/`](review-lanes/) | Lane provisioning helper plus its `check.sh` | `adilfaisal01/review-lanes` |

Provenance, imported commits, and the `pi-subagent` upstream note are in [NOTICES.md](NOTICES.md).

## Pi wiring

Pi loads three of these directly from `~/.pi/agent/settings.json` (`packages`), by path:

```jsonc
"../../../../mnt/E/github-projects/pi-agents/v-model-agents",
"../../../../mnt/E/github-projects/pi-agents/code-review-swarm",
"../../../../mnt/E/github-projects/pi-agents/pi-subagent"
```

`review-lanes/` is not a Pi package; it is invoked as a script.

Agent definitions (`review-correctness.md`, `review-quality.md`) live in
`~/.pi/agent/agents/`, outside this repo, because Pi resolves them from the agent
directory rather than from a package.

## Verifying a checkout

Everything here is verifiable without a model call:

```bash
bash v-model-agents/check.sh              # modes typecheck + assertions, then the gate self-tests
bash code-review-swarm/scripts/selftest.sh  # static lane checks; add --live to dispatch both lanes
bash review-lanes/check.sh                # syntax check + lane self-test in a throwaway repo
```
