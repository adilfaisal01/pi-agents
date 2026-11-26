# pi-agents — agent and workflow tooling

One repo, per-prefix `git subtree add`: `v-model-agents/`, `code-review-swarm/`,
`pi-subagent/`, `review-lanes/`, `review-gate/`.

**Distributed as a git tag**, not a registry: consumers install
`pi install git:github.com/adilfaisal01/pi-agents@vX.Y.Z`, so a release is a version bump,
a `(docs): changelog for X.Y.Z` commit, a `vX.Y.Z` tag and a push — nothing else. The npm
package `@adilfaisal01/pi-agents` is frozen at 0.1.1; its ritual and its traps are history in
`/mnt/E/github-projects/pi-agents-npm-release.md`, and `.github/workflows/publish.yml` is
dispatch-only.

## Read these before changing anything

These two documents are harness knowledge, not repo knowledge, so they live in the
personal vault (`/mnt/E/obsidian/personal/notes/`) and are pulled when needed
rather than carried in this checkout — `vault-personal` MCP or `rg`:

- `pi-runtime-notes.md` — model config and the ollama-cloud sync, subagent
  frontmatter and model rules, the MCP adapter, the corpus servers, TUI probe
  technique, pi-lens cache behaviour.
- `workflow-and-packaging.md` — v-model-agents rows/waves/freeze/pin, the
  `swarm-gate` exit codes and storage, subtree traps, and the retired npm release.
- `CHANGELOG.md` and `NOTICES.md` for what shipped.

## Verify before claiming

`v-model-agents/check.sh`, `code-review-swarm/scripts/selftest.sh [--live]`,
`review-lanes/check.sh`, `review-gate/check.sh` (72 stub cases, no model calls).

## Rules

- Standalone tooling gets its OWN repo; this one stays the workflow-discipline repo.
- Agent `.md` files live in `~/.pi/agent/agents`, not here.
- Settings packages point at three prefixes (review-lanes is a script).
