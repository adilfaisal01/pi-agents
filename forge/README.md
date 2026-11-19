# forge — the shinro-forge architect workflow, as a pi package surface

Four skills and five role contracts from the
[shinro-forge](https://github.com/Shinro-xyz/shinro-forge) harness, re-authored for pi so the
intake workflow is available from any pi session — not only one whose working directory
happens to reach a forge checkout.

```text
forge/
├── skills/
│   ├── clarify/SKILL.md          the one-question-at-a-time ambiguity loop
│   ├── spec-authoring/SKILL.md   stories, FR-NNN, measurable SC-NNN
│   ├── decompose/SKILL.md        the machine-parseable Task Breakdown
│   ├── forge-review/SKILL.md     two-model PR review → the forge's machine-checkable record
│   └── forge-workflow/SKILL.md   bead → worktree → test-first → PR
└── agents/
    ├── architect.md              writes only under specs/**; never mints beads, never ratifies
    ├── builder.md                writes only under sandbox/**; opens a PR, never merges
    ├── spec-reviewer.md          read-only, advisory Gate-A review of a draft spec
    └── disposition.md            read-only adjudication of the merged review's findings
```

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
