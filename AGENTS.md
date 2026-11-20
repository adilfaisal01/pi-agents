# pi-agents — agent and workflow tooling

One repo, per-prefix `git subtree add`: `v-model-agents/`, `code-review-swarm/`,
`pi-subagent/`, `review-lanes/`, `review-gate/`. Also published as npm
`@adilfaisal01/pi-agents` — the release ritual and its traps live OUTSIDE this repo
in `/mnt/E/github-projects/pi-agents-npm-release.md` (publish needs `--otp`).

## Read these before changing anything

These two documents are harness knowledge, not repo knowledge, so they live in the
personal vault (`/mnt/E/obsidian/personal/notes/`) and are pulled when needed
rather than carried in this checkout — `vault-personal` MCP or `rg`:

- `pi-runtime-notes.md` — model config and the ollama-cloud sync, subagent
  frontmatter and model rules, the MCP adapter, the corpus servers, TUI probe
  technique, pi-lens cache behaviour.
- `workflow-and-packaging.md` — v-model-agents rows/waves/freeze/pin, the
  `swarm-gate` exit codes and storage, subtree and npm release traps.
- `CHANGELOG.md` and `NOTICES.md` for what shipped.

## Verify before claiming

`v-model-agents/check.sh`, `code-review-swarm/scripts/selftest.sh [--live]`,
`review-lanes/check.sh`, `review-gate/check.sh` (72 stub cases, no model calls).

## Rules

- Standalone tooling gets its OWN repo; this one stays the workflow-discipline repo.
- Agent `.md` files live in `~/.pi/agent/agents`, not here.
- Settings packages point at three prefixes (review-lanes is a script).
