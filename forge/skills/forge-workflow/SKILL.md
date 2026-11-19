---
name: forge-workflow
description: Run a task through the shinro-forge lifecycle — claim a bead, work test-first in an isolated git worktree, then finish to open a PR for human review. Use when starting, working on, or finishing a bead/task in the forge harness. WHAT/WHY, never HOW.
---

# forge-workflow

The task-lifecycle procedure for the shinro-forge harness. This is the single source of truth for
**how a task flows** (the _procedure_); the standing **hard rules** (never push `main`, no
`--no-verify`, vault read-only, sandbox confinement, never edit the hooks) live in the target repo's
`AGENTS.md` and are enforced by its deny floor and git hooks regardless of which agent is driving.

## The lifecycle

- **One task → one git worktree + branch (isolation).** The shared checkout is never modified directly.
- **Work is a bead.** Claim a _ready_ bead before starting (`./harness/run-task.sh start <bead-id>` —
  fails closed if it's missing, not ready, or already claimed; `start --new "<desc>"` is the only
  create path). `finish` sets the bead `in_review` and opens the PR; the **human merge** closes it
  (mechanical reconcile via `run-task.sh sync`) — **never `bd close` by hand**. `kill-switch.sh`
  releases the claim back to ready.
- **The oversight board is auto-projected.** `start`/`finish`/`sync`/kill-switch re-project Beads onto
  the read-only board (#3) — best-effort, never a gate; never write the board by hand.
- **Test-first:** write a failing test, then code, until green. You cannot declare a task done while
  tests are red — `run-task.sh finish` re-checks green on the host before it pushes anything.
- **Formatting and linting are the target's commands**, read from `harness/targets.config` — never
  hardcoded, and never assumed to have run. Under Claude Code a `PostToolUse` hook applies them on
  every write; under pi nothing does, so run them yourself before `finish`.
- A run ends by **opening a pull request** — never by merging. You open it; a human merges it.

## What the pi posture does and does not add

The forge's deny floor and Stop gate are `.claude/hooks/**` and do not fire under pi. What still holds
is host-side and actor-independent: `run-task.sh` fails closed on a missing/claimed bead and refuses to
finish red, the git hooks apply to any session that commits or pushes, and the human merge stays the only
way a task closes. Path confinement for a pi session is the concern of the `architect`/`builder` agent
modes (`<repo>/.pi/agent-modes.json`) and, past that, of gondolin's mount policy — both planned in
`pi-agents/docs/forge-architect-port-plan.md`, neither shipped. Until they are, staying inside your
task's write surface is discipline, and a `write_scope` on the agent contract is a post-hoc check, not a
live deny.
