# Plan: a fifth agent mode — `forge`

> Written 2026-11-19 in plan mode; not yet implemented. Decisions recorded with the user the same
> day: **(a) git carve-out** — in a forge checkout with an active bead, committing to the task
> branch and pushing it is the workflow; everything else keeps the standing no-commit-without-go
> rule. Outside a forge checkout there are no commits at all. **(b) review trigger** — the review
> fires where no harness owns it: in a forge checkout `review-task.sh` owns review and the session
> dispatches nothing; anywhere else the finished change set is reviewed by the two-model swarm
> automatically, on the same rationale as yolo's gate.

## What the mode is

The forge is an autonomous code agent. `forge` mode makes a pi session work like the forge harness
works — claim a task, work test-first in isolation, end the change as a PR-shaped handoff, never
touch its own machinery — **whether or not the checkout has the harness**. It sits alongside
oracle / plan / build / yolo on the same surface (mode = tool set + shell policy + write scope +
prompt contract), because that is the layer pi core has and the one the forge's own floors map onto.

## Resolved unknown (recorded for the port plan)

`mergeConfig` **can** add brand-new modes from `~/.pi/agent/agent-modes.json` or
`<repo>/.pi/agent-modes.json` (unknown names fall to a fallback profile). But an override-added
mode cannot carry a prompt contract: `loadPrompt` resolves `promptFile` inside the extension's own
directory, so an override has nowhere to put its prompt file. A mode with a prompt contract must
ship in the package — which is what this plan does. Port-plan row 4 (an `architect` mode via the
forge repo's layer-3 file) remains viable for path rules only, and is partly superseded: the
machinery denials here apply everywhere the package is installed.

## Steps

| # | what changes | why | how it is checked | may touch |
| --- | --- | --- | --- | --- |
| 1 | `v-model-agents/modes/config.json`: add `forge` to `order` (after `yolo`) and to `modes` — tools `read, grep, find, ls, edit, write, subagent, bash`; `writeDeny` the machinery (`.claude`, `.codex`, `.agents`, `.pi`, `.github`, `.beads`, `.harness`, `harness`, `gate`); `bash: "all"`; `keepExtensions: true`; `promptFile: "prompts/forge.md"`; badge `⚒️ forge`, color reused from the shipped palette | the mode must deny the harness/skill/config trees at `tool_call` (the forge's "never edit the hooks"), allow writing everywhere else (the real boundary is the worktree + the git hooks, not a mode scope), and guarantee `subagent` so the swarm can be dispatched when no harness owns review | shipped config parses and both `order` and `modes.forge` resolve; nothing else in `config.json` moved | `v-model-agents/modes/config.json` |
| 2 | `v-model-agents/modes/prompts/forge.md` — the contract: (1) the loop — in a forge checkout load `forge-workflow` and claim a bead before editing; elsewhere state the change set in one line first; (2) test-first red→green with the repo's own commands; (3) review policy per decision (b); (4) the git carve-out per decision (a), worded narrowly: task branch, active bead, nothing else; (5) never merge — the PR is the handoff; (6) done = `run-task.sh finish` (forge) or diff + verification report (no harness) | the git carve-out is the one place a mode prompt alters standing rules, so it must be explicit, narrow, and read as an exception rather than license; the review policy prevents double-dispatch (harness owns review in the forge) and prevents an unattended handoff of an unreviewed diff (auto-swarm elsewhere) | file exists and is non-empty; `check.sh` asserts the shipped `promptFile` resolves for every mode in `modes` | `v-model-agents/modes/prompts/forge.md` |
| 3 | `v-model-agents/modes/index.ts`: two description strings — the four-name list (`oracle` `plan` `build` `yolo`) gains `forge`; the `Ctrl+1..N` jump loop's `order.slice(0, 4)` → `slice(0, 5)` so `Ctrl+5` = forge | the fifth mode must be reachable by jump, not only by cycle/menu; descriptions are user-facing, so a stale list is a small lie in `/mode` output | `tsc -p tsconfig.json` clean; `Ctrl+5` switches to forge in the selftest | `v-model-agents/modes/index.ts` (two lines + comment) |
| 4 | `v-model-agents/modes/selftest.mjs`: extend `makeRepo()` with a `harness/` fixture file; add assertions — `forge` is in `order` and reachable via `Ctrl+5`; a write to `src/app.py` succeeds; a write to `harness/x.sh` and `.claude/hooks/f.sh` is refused with `[forge]` in the reason; no `dropTools` (edit/write present); a bash command matching nothing safe (e.g. `git commit -am wip`) is **not** blocked (`bash: "all"`) | the selftest is the package's only model-free verifier (38 assertions today); a mode without assertions ships undefined | `node selftest.mjs` → all pass; count grows by the new assertions and the README "N assertions" numbers are updated to match | `v-model-agents/modes/selftest.mjs` |
| 4b | *(found while probing, 2026-11-19)* `writeDeny`'s refusal message was build-specific ("the frozen test surface is locked … a build lane never edits one"), so forge's machinery denial read as if `harness/` were a test surface. Add an optional `writeDenyReason` per mode; forge sets its own, build keeps the shipped wording | a refusal that misdescribes what it protects teaches the agent the wrong rule, and the message is the only thing a model reads about the deny | selftest asserts forge's reason names the machinery and does **not** contain "frozen test surface"; a live TUI probe prints the new wording | `v-model-agents/modes/index.ts` (ModeConfig + the refusal), `config.json`, `modes/README.md` key table |
| 5 | Docs: `v-model-agents/README.md` and `v-model-agents/modes/README.md` — add the `forge` row to both mode tables (`writeScope: everything but the machinery`, `shell: unrestricted`, what it is for), `Ctrl+1..4` → `Ctrl+1..5`, and the selftest count; root `README.md` mode list + `forge/README.md` gain one line naming the mode as the pi tier that makes a session work like the harness; `CHANGELOG.md` new `Unreleased` bullet | the mode is only discoverable if the tables that users actually read list it; the two README files carry the same table today and must not drift | a grep for the stale mode list and the stale `Ctrl+1..4` across the three README files returns nothing; `npm run check` green | `README.md`, `CHANGELOG.md`, `v-model-agents/README.md`, `v-model-agents/modes/README.md`, `forge/README.md`, `docs/forge-architect-port-plan.md` |
| 6 | Port plan cross-entry: move the layer-3 unknown to resolved (override can ADD a mode but cannot give it a prompt contract → the package ships `forge`), and mark row 4's machinery denials as covered on the package tier | the port plan's Unknowns section is the record future steps read before acting | the entry names `mergeConfig`'s behaviour and `loadPrompt`'s constraint exactly | `docs/forge-architect-port-plan.md` |

## Status — implemented 2026-11-19

Steps 1–6 landed, plus step 4b (the `writeDenyReason` fix the live probe surfaced). Verified:

- `bash v-model-agents/modes/check.sh` → tsc clean, **52 assertions, all passed** (was 38).
- `bash scripts/check-package.sh` → manifest publishable, five suites green.
- Live TUI probe (model `ollama-cloud/deepseek-v4.1-flash`, a throwaway git repo with `harness/`):
  `/mode forge` shows the `⚒️ forge` badge; `write src/probe.txt` succeeded (file on disk);
  `write harness/probe.sh` was refused at `tool_call` with
  `[forge] refused: write to 'harness/probe.sh' — this mode may not edit the forge machinery …`.
- `Ctrl+5` is free: pi's `docs/keybindings.md` binds no `ctrl+5`, and `ctrl+1..4` are the
  extension's own jump keys.

### Follow-on: role → model (2026-11-19)

The forge's roles are meant to run on different models, and the mode is not the carrier for
that — a mode's `model` is session-scoped, roles are dispatch-scoped. Landed instead as LOCAL 6 in
`pi-subagent`: `subagent-models.json`, keyed by agent name, in a user layer
(`~/.pi/agent/`) and a project layer (nearest `<dir>/.pi/subagent-models.json`), applied in
`discoverAgents` so discovery, tests and check scripts all see the model that will be used.
Precedence: **project map → user map → the agent's own `model:` frontmatter → the dispatching
session's model**. `forge/agents/*.md` stay model-free, so the package stays portable and
`pi update` cannot clobber a pin you own.

The mode keeps its `model` key for the one role that *is* the session — the architect: set it in
`~/.pi/agent/agent-modes.json` as `{"modes":{"forge":{"model":"<provider>/<id>"}}}`, and the
shipped config keeps carrying no provider ids. Reviewers need nothing new: in a forge checkout
the harness reads `harness/reviewers.config` (`REVIEWER_BACKEND` + `<prefix>_MODEL`, with
`SPEC_REVIEW_BACKEND` / `DISPOSITION_BACKEND` splittable); on the pi path the swarm lanes carry
their own pins. Worked map and the full table: `forge/README.md#role--model`.

Verified: `node pi-subagent/selftest.mjs` → 38 assertions (9 of them new) covering user-layer
pinning, project-beats-user, map-beats-frontmatter, nested-cwd discovery, unknown names, and a
malformed map failing open. Live: a map pinning `spec-reviewer` to a bogus id made the child fail
with pi's own `Model "vendor/nonexistent-model-does-not-exist" not found` (the pin reached
`--model`), and pinning it to a real id made it answer `OK` while the dispatcher stayed on a
different model.

A cross-provider template ships as `forge/subagent-models.example.json` (inert by name — discovery
reads `subagent-models.json` only), with `forge/check-role-models.sh` as a sixth `npm run check`
suite: sample keys == the shipped roles (a key matching no agent is silently ignored, so a
misspelled role looks like a pin), no agent file carries `model:`, and every sample id resolves
here. `skip`, never failure, where `pi` is absent. Live proof of the cross-provider case:
dispatcher on `ollama-cloud/deepseek-v4.1-flash`, `disposition` child on `ollama/gpt-oss:120b-cloud`,
child answered `OK`.

## Verification (what a stranger runs)

```bash
bash v-model-agents/modes/check.sh      # tsc + extended selftest, no pi, no model, no network
bash scripts/check-package.sh           # manifest + tarball + all suites
# and one TUI probe, model ollama-cloud/deepseek-v4.1-flash:
#   /mode forge  → badge ⚒️ forge; write to harness/x.sh refused at tool_call with the
#   [forge] reason; write to src/ succeeds; --agent-mode forge starts a session in it
```

## Assumptions

- **Repo-agnostic.** The shipped `writeDeny` is the machinery set, not a forge-only geometry; in a
  repo without those trees the mode is just autonomous work with a prompt contract. A
  forge-checkout-specific scope (the port-plan row 4 shape) still belongs to the forge's own
  layer-3 file, which wins over the shipped profile.
- **No model pin.** Modes ship no provider ids; `forge` inherits the session's model like
  build/yolo.
- **`Ctrl+5` is free.** pi already binds `Ctrl+1..4`; if the keybinding docs show a conflict the
  jump loop stays at 4 and forge is reachable by cycle/menu/`/mode` only — the plan degrades, it
  does not fail. (Check `docs/keybindings.md` before step 3 lands.)

## Risks

- **The carve-out is a standing-rule exception.** It is worded to the narrow case (forge checkout +
  active bead + task branch). A session drifting to "forge mode authorizes commits" anywhere else
  is the failure mode; the prompt's outside-a-forge clause (no commits, report and stop) is the
  guard, and the git hooks remain the mechanical floor.
- **Cost in non-forge repos.** `forge` inherits yolo's review economics wherever the harness does
  not own review: one swarm per finished change set. That is the user's accepted yolo trade; worth
  saying in the README row rather than burying.
- **`subagent` guaranteed in the tools list.** With `keepExtensions: true` it was already likely
  active; guaranteeing it changes nothing for sessions that never dispatch, and unblocks the
  auto-review contract.

## Not decided here (deliberate)

- An `architect` mode (writeScope `specs/`, read-only elsewhere) stays port-plan row 4 in the
  forge repo's layer-3 file — it is session-geometry, not package surface.
- Gondolin remains the fine belt; this mode is the coarse one, as the port plan already says.
