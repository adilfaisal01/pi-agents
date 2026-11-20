# forge — spec-first work with an audit trail, as a pi package surface

The [shinro-forge](https://github.com/Shinro-xyz/shinro-forge) intake workflow, re-authored for pi so
it works in **any** repo — not only one whose working directory reaches a forge checkout. The point
is traceability: every decision, build, review and sign-off lands in an append-only trail that a third
party can re-read and re-check without asking the agent anything.

```text
forge/
├── bin/forge-gate                the deterministic tier: start · analyze · ratify · claim · build
│                                 · review · complete · finish · report
├── templates/spec-template.md    the spec + Task-Breakdown schema, normative (nine invariants)
├── skills/
│   ├── clarify/SKILL.md          the one-question-at-a-time ambiguity loop
│   ├── spec-authoring/SKILL.md   stories, FR-NNN, measurable SC-NNN
│   ├── decompose/SKILL.md        the machine-parseable Task Breakdown
│   ├── forge-review/SKILL.md     two-model PR review → the forge's machine-checkable record
│   └── forge-workflow/SKILL.md   bead → worktree → test-first → PR (harness repos)
├── agents/
│   ├── architect.md              writes only under specs/**; never mints beads, never ratifies
│   ├── builder.md                writes only under sandbox/**; opens a PR, never merges
│   ├── spec-reviewer.md          read-only, advisory Gate-A review of a draft spec
│   └── disposition.md            read-only adjudication of the merged review's findings
└── check-gate.sh                 36 adversarial fixtures: nine invariants + every trail refusal
```

## The pipeline

```text
objective → spec → Gate A (human) → numbered tasks → build each → review each → PR
```

`forge` **mode** (`v-model-agents/modes`, `Ctrl+5` / `/mode forge`) drives it. The gate is what makes
each arrow checkable:

| step | command | what it refuses |
| --- | --- | --- |
| scaffold | `forge-gate start <slug>` | an existing spec dir; a slug with no usable characters |
| author | (skills: `spec-authoring`, `clarify`) | — the post-condition is zero `[NEEDS CLARIFICATION]` markers |
| Gate B | `forge-gate analyze <spec>` | any of the nine invariants, FR↔task traceability, a dangling `satisfies` |
| Gate A | `forge-gate ratify <spec>` | **off a TTY** (an agent cannot ratify), a missing `understanding.md`, a spec that fails `analyze` |
| claim | `forge-gate claim <spec> T00N` | unratified spec, a failing `analyze`, an incomplete `depends_on`, a checkout sitting on the integration branch |
| build | `forge-gate build <spec> T00N` | nothing — it *runs* the `dod_tests` selectors and records green/red itself |
| review | `forge-gate review <spec> T00N --verdict … --open-sev12 N` | nothing; it records what the lanes said |
| review (branch) | `forge-gate review <spec> --branch [--post]` | an incomplete branch; `--post` before a PR exists |
| complete | `forge-gate complete <spec> T00N --commit SHA` | no green build, no review, open SEV1/SEV2, a commit that escaped the task's `scope`, **evidence missing from the commit's tree / a symlink / failing `must_match` / hitting `must_not_match`**, an integration branch that cannot fast-forward |
| finish | `forge-gate finish <spec>` | an incomplete task, a failing `analyze --strict`, no branch review, a branch review with open SEV1/SEV2, a missing trail row |
| clean | `forge-gate clean <spec> [--force]` | a dirty worktree, without `--force` |
| audit | `forge-gate report <spec>` | a `records.jsonl` line that is not one JSON object per line |

`specs/NNN-<slug>/` holds `spec.md`, `understanding.md`, `restatement.md`, `records.jsonl` and
`evidence/`. The trail is committed with the work it describes: `finish` copies it onto the PR branch
as a gate-authored commit, so the PR carries the spec and the trail itself.

### Isolation: a worktree per task, never the user's checkout

`claim` creates two git worktrees beside the repo — the forge harness's own rule ("the shared
checkout is never modified directly") applied to a repo without the harness:

```text
<repo>.forge/<slug>/           integration worktree · branch forge/<slug>      ← the PR branch
<repo>.forge/<slug>/<T00N>/    task worktree        · branch forge/<slug>-<T00N> ← where a builder works
```

- The task branch is cut from the integration head, so `T002` physically contains `T001`'s code;
  `claim` refuses a task whose `depends_on` is incomplete, so the order is enforced twice.
- `build` runs the `dod_tests` **in the task worktree**; `complete` fast-forwards the integration
  branch onto the task branch, and refuses if the integration branch moved since the claim.
- Task branches are `forge/<slug>-<T00N>`, **not** `forge/<slug>/<T00N>`: git refuses a ref under a
  name that is already a branch (`cannot lock ref … 'refs/heads/forge/001-x' exists`).
- `clean` removes both, refusing a dirty one unless `--force`; `git worktree list` shows where the
  isolation actually is, which is also what a reviewer can check.
- The user's checkout stays on its own branch with only the untracked `specs/` while the run is in
  flight. Worktree creation refuses a *tracked* change in the checkout (the branch must start from a
  tree someone chose) and ignores untracked files (the spec being authored).

Two properties worth stating plainly, because they are the whole regulatory argument:

- **A human ratifies, an agent cannot.** `ratify` requires a TTY on stdin *and* stdout, so the row
  in the trail can only come from a person at a terminal.
- **Green means the gate ran it.** `build` executes each `dod_tests` selector (`timeout … bash
  <selector>`) and records the exit code; `complete` reads that row. An agent saying "tests pass" is
  not a state the gate can be in.
- **The PR is reviewed before it exists.** The forge ran its reviewer *after* `gh pr create` and
  ignored the outcome; here the whole-branch two-lane review is recorded first (`review --branch`),
  `finish` refuses while SEV1/SEV2 are open, and only then is the PR opened — with the review in its
  body, posted again as a comment, and recorded as a `review-posted` row. Stricter than the original,
  deliberately: nothing is posted that has not been through both lanes.
- **Evidence is checked, not named.** `analyze` only proves an `sc_evidence` path is well-formed and
  in scope; `complete` reads the path out of the task commit and requires it in the tree
  (`missing-from-tree`), as a real file rather than a symlink, and — when the criterion carries
  `must_match` / `must_not_match` — with the committed blob satisfying that ERE. An entry asserting
  existence only completes, and the trail records `evidence-existence-only` so the gap is visible
  rather than implied.

`forge-gate` is python3 stdlib, no network, no model — `bin/` entry, so `npx … forge-gate` works from
an install. Schema and invariants: [`templates/spec-template.md`](templates/spec-template.md);
fixtures: `forge/check-gate.sh` (part of `npm run check`).

## Why there is no `reviewer` here

The forge's single `reviewer` role is retired on this surface (2026-11-19). One model reviewing
a PR cannot make its own agreement evidence; **two lanes on two models can**, and the swarm's
correctness lane already carries the old role's whole mandate in more operational detail. So a
forge review runs `code-review-swarm` and then the **`forge-review`** skill bridges its merged
table to the forge's record: `SEV1–4 → CRITICAL/HIGH/MEDIUM/LOW`, `path:line (symbol) → path:line`,
verdict from the SEV1 count. Both lanes feed the record — a design row that guarantees the next
defect is a real finding, and `disposition` exists to separate it from the noise.

The forge's own `.claude/agents/reviewer.md` is untouched: `.claude/hooks/**` sessions and the
ollama / `claude-fresh` / codex backends of `harness/review-task.sh` keep consuming it. This
retirement is a pi-surface change, and it costs one thing worth naming — a pi-driven forge review
is now three model calls (two lanes + `disposition`) where it used to be one.

## What makes these the *pi* render

The forge keeps a canonical source at `harness/skills/**` and renders it into agent-specific
trees (`harness/skills-sync.sh`). These files are that render for pi, and pi's rendering
differs in substance from the Codex/OpenCode one:

- **`ask_user_question` is named literally.** The neutral render says "the interactive ask
  tool", which only resolves if the session has a tool to point at. Under pi the ask surface
  comes from the `@juicesharp/rpiv-ask-user-question` extension, and a run **without** it has
  no ask tool at all — in that case the phrase has no referent and a model will emit the
  options as prose instead of asking. Naming the tool removes the guess.
- **No hook claims.** The forge's clarify-gate, Stop floor and `PostToolUse` hooks live in
  `.claude/hooks/**` and do not fire under pi. Every sentence in these files that would have
  said "the hook denies X" instead says what is true on pi: what is host-side and
  unfakeable (the `intake.sh spec-review` capture, the TTY-gated `ratify`, Gate B `analyze`,
  the git hooks, the human merge), what the contract itself enforces (a dispatched role gets
  exactly its tool list, and `write_scope` fails the run afterwards if anything outside it
  moved), and what is not enforced at all (the round budget, the ask↔record coupling, the
  Stop floor — hold them yourself).

The pi tiers that would close the rest are designed in
[the port plan](../docs/forge-architect-port-plan.md) and not shipped: an `architect` /
`builder` agent mode (`writeScope`, `writeDeny`, `bash` allowlist in
`<repo>/.pi/agent-modes.json`) for the path rules, and gondolin's mount policy — repo
read-only, `specs/` read-write — for the filesystem ones.

What **is** shipped is the coarse pi belt: the **`forge` agent mode**
(`v-model-agents/modes`, `Ctrl+5` / `/mode forge`). Full tools, unrestricted shell, the machinery
trees denied at `tool_call` (`.claude`, `.codex`, `.agents`, `.pi`, `.github`, `.beads`,
`.harness`, `harness`, `gate`), a guaranteed `subagent`, and a prompt contract that makes a
session work the way the harness works — claim, test-first, reviewed handoff. It is mode-level
geometry, not session-specific: in a forge checkout it commits the task branch and lets the
harness review the PR; elsewhere it presents the diff and the two-model swarm reviews it.
Design: [forge-mode-plan.md](../docs/forge-mode-plan.md).

## What is not here

The skills **use** the forge harness; they do not contain it. They read
`harness/intake-categories.json`, `templates/spec-template.md` and
`harness/targets.config` from the repo they run in, and the floors they defer to
(`intake.sh spec-review`, `ratify`, `analyze`) run on the host. A pi session outside a forge
checkout can hold the protocol but has nothing to run the gates against.

## Role → model

The forge's roles are meant to run on different models, and in this port they already do —
but through three different mechanisms, because they are three different kinds of process:

| role | what it runs as | where its model is set |
| --- | --- | --- |
| `architect` (as the session) | the interactive pi session | the `forge` mode's `model` in an override file: `{"modes":{"forge":{"model":"<provider>/<id>"}}}` — "this session is the architect". The shipped mode carries none, because a package cannot know your providers |
| `architect`, `builder`, `spec-reviewer`, `disposition` (dispatched) | `subagent` child processes | `subagent-models.json` (user `~/.pi/agent/`, project `<repo>/.pi/`), keyed by agent name — see [pi-subagent's README](../pi-subagent/README.md#subagent-modelsjson--a-model-per-role). The agent files stay model-free so the package stays portable |
| `reviewer` (PR review) | `harness/review-task.sh` on the host | `harness/reviewers.config` in the forge repo: `REVIEWER_BACKEND` + `<prefix>_MODEL`, with `SPEC_REVIEW_BACKEND` and `DISPOSITION_BACKEND` splittable. The file argues for a *different family* on the adjudicator |
| the two review lenses (pi path, when the harness does not own review) | `code-review-swarm` lanes | each lane's `model:` frontmatter — two different ids on purpose |

A worked map for the four dispatched roles — cross-provider on purpose, because two models from
one family share blind spots:

```json
{
  "architect": "anthropic/claude-sonnet-4-5",
  "builder": "ollama-cloud/deepseek-v4.1-flash",
  "spec-reviewer": "ollama-cloud/glm-5.3",
  "disposition": "ollama/gpt-oss:120b-cloud"
}
```

That is [`subagent-models.example.json`](subagent-models.example.json), shipped as a template. To
use it, copy it to **one** of the two map paths and edit the ids to ones your install has:

```bash
cp subagent-models.example.json ~/.pi/agent/subagent-models.json            # you, every project
cp subagent-models.example.json <repo>/.pi/subagent-models.json             # this checkout only
```

A file named `*.example.json` is inert — discovery reads `subagent-models.json` and nothing else,
so the template never pins anything by accident. Verify a map before trusting it:

```bash
bash forge/check-role-models.sh   # sample keys == shipped roles, agents stay model-free, ids resolve
```

That check is part of `npm run check`. It needs no model call, and without `pi` on `PATH` it
reports `skip` rather than failing — the same contract as the review lanes' model check. What it
catches is the quiet one: a map key that matches no discovered agent is **silently ignored**, so a
misspelled role (`spec-reviewer` typed as `spec_reviewer`) or the `reviewer` name this port retired
looks like a pin and does nothing.

Ids churn — `mistral-large-4` resolved when the swarm lanes were pinned and did not resolve here a
week later — so re-run the check after a provider update rather than trusting the template's age.

Two consequences worth knowing. An agent whose name is in the map gets `--model`, and an
explicit model **drops the inherited thinking level** — so a pinned role thinks at its
provider's default, not at the dispatcher's level. And the map beats frontmatter by design:
precedence is **project map → user map → frontmatter → dispatcher**, so you can pin a role
for one checkout without touching an installed agent file.

Why not in the mode? A mode's `model` is session-scoped — one model per session. Roles are
dispatch-scoped. Only the role that *is* the session (the architect) belongs there.

## Precedence inside a forge checkout

Skills are resolved by name with the *first* tier winning, and a project tree beats a package tree.
So a pi session whose cwd is inside a forge checkout loads the forge's own `.agents/skills/**` and
**not** the pi render in this directory, and says so in the startup `[Skill warnings]` block:

```text
"clarify" collision:
  ✓ auto (project) <forge>/.agents/skills/clarify/SKILL.md
  ✗ ./forge/skills/clarify/SKILL.md (skipped)
```

That is acceptable rather than broken — the neutral render does work under pi when the ask
extension is installed (verified: the phrase resolved to `ask_user_question` and opened a real
dialog) — but it means the pi render earns its keep everywhere *except* the checkout it was
written for, and a fix to the pi prose will not be what a forge-root session reads. If that
becomes the wrong posture, the move is to retire the redundant project tree upstream, not to
rename skills here.

## Upstream relation

| | |
| --- | --- |
| source of the prose | `shinro-forge/harness/skills/**` (canonical) and `.claude/agents/**` |
| this tree | the pi render, edited here — pi-specific prose diverges deliberately |
| forge's own trees | `.claude/skills/**` and `.agents/skills/**` remain byte-identical to the canonical render, so the Claude and Codex paths are unaffected |

A change that belongs to the **protocol** (a rule, a taxonomy, a format) belongs upstream in
the forge first, then gets re-rendered here. A change that is about **pi's host posture** (what
enforces what, which tool is named) belongs here. Say which one a diff is, or the two copies
drift without anyone deciding to.

Corrected in this render, worth fixing upstream: `spec-authoring` claimed Gate B was still a
future stage and counted "six invariants"; `decompose` already documents Gate B as wired with
nine invariants and `intake.sh analyze`.
