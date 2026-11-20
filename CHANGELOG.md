# Changelog

## [Unreleased]

- **The shinro-forge architect workflow ships with the package** (`forge/`): the `clarify`,
  `spec-authoring`, `decompose`, `forge-review` and `forge-workflow` skills on `pi.skills`, and
  the `architect` / `builder` / `spec-reviewer` / `disposition` role contracts on `pi.agents`.
  A pi session gets the intake workflow without sitting inside a forge
  checkout.
- **The forge's single `reviewer` role is retired on this surface.** A pi-driven forge review is
  now the two-model code-review-swarm, with the new `forge-review` skill bridging its merged
  SEV1–SEV4 table into the sentinel-bounded JSON block `harness/review-task.sh` extracts
  (`SEV1→CRITICAL … SEV4→LOW`, `path:line (symbol) → path:line`, verdict from the SEV1 count).
  Both lanes feed the record and the `disposition` adjudicator, whose input contract now reads
  the merged table. Cost: three model calls per reviewed PR where it used to be one. The forge's
  own `.claude/agents/reviewer.md` is untouched, so the Claude path and the ollama /
  `claude-fresh` / codex backends are unaffected.
- **These are pi renders, not copies.** `ask_user_question` is named literally (the neutral
  render's "the interactive ask tool" has no referent in a pi run without the ask
  extension), and every sentence that claimed a `.claude/hooks/**` gate enforces something
  now says what actually does: the host-side harness floors, the contract's own tool list
  and `write_scope` post-check, and — named as unenforced — the round budget, the
  ask↔record coupling and the Stop floor.
- `spec-authoring`'s stale Gate-B note was corrected to match `decompose` (Gate B is wired,
  `intake.sh analyze`, nine invariants).
- **A fifth agent mode, `forge`** (`v-model-agents/modes`): autonomous task execution alongside
  oracle / plan / build / yolo. Full tools plus a guaranteed `subagent`, unrestricted shell, and a
  `writeDeny` over the machinery trees (`.claude`, `.codex`, `.agents`, `.pi`, `.github`, `.beads`,
  `.harness`, `harness`, `gate`) refused at `tool_call`. Reachable by `Ctrl+5`, cycle, or `/mode`.
  Its prompt contract is the one place a standing rule changes, and narrowly: in a forge checkout
  with an active bead it commits and pushes the **task branch** without asking (a human merges);
  everywhere else it presents the diff and waits. Review follows the same split — the harness owns
  it in a forge checkout, the two-model swarm runs automatically anywhere else. Selftest grew from
  38 to 52 assertions. Design and decisions: `docs/forge-mode-plan.md`.
- **`forge` mode now runs the intake pipeline, and `forge-gate` is its deterministic tier.** The
  mode's contract is no longer "state the change set and work" outside a harness checkout — it is
  `objective → spec → Gate A (human) → numbered tasks → build each → review each → PR`, which is the
  traceability the forge exists for. New in `forge/`: `templates/spec-template.md` (the pi render of
  the spec + Task-Breakdown schema, nine invariants, normative) and `bin/forge-gate`
  (`start · analyze · ratify · claim · build · review · complete · finish · report`, python3 stdlib,
  no model, no network). The properties that carry the regulatory argument: `ratify` requires a TTY on
  stdin **and** stdout, so an agent cannot produce the Gate-A row; `build` executes each task's
  `dod_tests` selectors and records the exit code, so "green" is something the gate ran, not something
  an agent said; `complete` refuses an unreviewed task, a latest review with open SEV1/SEV2, or a
  commit that escaped the task's declared `scope` (its own `specs/NNN-<slug>/` audit paths exempt).
  Commits are allowed only on a `forge/<slug>` branch, only after `ratify` + `analyze`, and push/PR
  only via `forge-gate finish`. `forge/check-gate.sh` adds 36 adversarial fixtures (one per invariant,
  plus every refusal) as a seventh `npm run check` suite. Deferred, stated in the plan: a per-dispatch
  `scope` on `subagent` (LOCAL 7) — the gate enforces scope at completion today.
- **A `subagent-models.json` template** (`forge/subagent-models.example.json`): a
  cross-provider map for the four dispatched forge roles, plus `forge/check-role-models.sh` — a
  sixth `npm run check` suite, no model call, `skip` rather than failure where `pi` is absent. It
  asserts three things: the sample's keys are exactly the shipped roles (a map key that matches no
  agent is **silently ignored**, so a misspelled or retired role looks like a pin and does
  nothing), no `forge/agents/*.md` carries a `model:` line (the agents stay model-free, so
  `pi update` cannot clobber a pin the user owns), and every sample id resolves in this install.
  The sample is itself inert — discovery reads `subagent-models.json`, never `*.example.json`.
- **A role→model map for the subagent tool** (`pi-subagent`, LOCAL 6): `subagent-models.json`,
  keyed by agent name, in two layers — user (`~/.pi/agent/`) and project (nearest
  `<dir>/.pi/subagent-models.json`, walking up from the child's cwd). Precedence: project map →
  user map → the agent's own `model:` frontmatter → the dispatching session's model. Applied in
  `discoverAgents`, and each agent reports `modelSource`, so discovery, tests and a check script
  all see the model that will be used. This is what lets the forge's roles run on different
  models without editing installed agent files (which `pi update` replaces). Selftest: 38
  assertions, 9 of them new.

## [0.1.1] - 2026-11-18

- **Publishing moved to GitHub Actions.** `.github/workflows/publish.yml` publishes on a
  `v*` tag push, using OIDC trusted publishing when the `NPM_TOKEN` secret is unset and a
  granular token when it is set. Actions are pinned to commit SHAs; the job refuses a tag
  that disagrees with `package.json` and skips a version already on the registry.
- **The model-pin check no longer requires a model registry.** `code-review-swarm`'s
  selftest reports each lane's pin as `skip` on a runner without `pi`, instead of failing —
  a skip, not a pass, so a real typo still fails. `pi` is now required only for `--live`.
- Publishing the package now runs the full check first (`prepublishOnly` →
  `scripts/check-package.sh`): manifest, packed tarball, and all five suites.

## [0.1.0] - 2026-11-18

First published version, as one package holding the five tools that used to be separate
repositories.

- **Agent modes** (`v-model-agents/modes`): `oracle` / `plan` / `build` / `yolo`, each with
  its own tool set, shell policy, write scope and prompt contract. Ships no model ids; set
  them in `~/.pi/agent/agent-modes.json`.
- **Code review swarm** (`code-review-swarm`): two lanes on two models, one SEV1–SEV4
  table, `/review` template, per-lane checkouts via `review-lanes`.
- **Subagent tool** (`pi-subagent`): isolated child `pi` processes with per-agent model
  pins, a write-scope post-check, and — new in this release — `pi.agents` in the package
  manifest, so one package can ship an extension and its agent definitions.
- **Review gate** (`review-gate`): `swarm-gate` turns the two lanes into an exit code, with
  a loop guard and a round budget. 72 stub-lane cases, no model calls.
- **Lane provisioning** (`review-lanes`): a worktree at a commit, plus an assertion that the
  package resolved from inside it.

`swarm-gate` and `review-lanes` are installed as `bin` entries. Both need `python3` (the
gate) or `git` (the lanes), and bash.
