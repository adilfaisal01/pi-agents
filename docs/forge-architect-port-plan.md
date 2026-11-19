# Porting the shinro-forge Architect workflow to pi

> Status: plan, authored 2026-11-20. Lives on branch **`feat/architect-forge`** of this repo,
> where the port is developed. Supersedes the staging copy that was at
> `shinro-forge/docs/pi-architect-port-scoping.md` (now a pointer to this file).
>
> Sequencing per user decision: **architect skills first**, then the **gondolin workflow**,
> then mechanical completion. Nothing that requires an npm release lands before the gondolin
> container decision.

## Why this repo

The forge's Architect intake workflow is a role + a skill set + an enforcement floor:

- role bodies: `shinro-forge/.claude/agents/{architect,builder,reviewer,spec-reviewer,disposition}.md`
- skills: canonical in `harness/skills/{clarify,spec-authoring,decompose,forge-workflow}`,
  rendered by `harness/skills-sync.sh` into `.claude/skills/` (Claude) and `.agents/skills/`
  (Codex/OpenCode) — agent-neutral prose with `@@ASK_TOOL@@` tokens and `@@variant:<tgt>@@`
  blocks
- enforcement: `.claude/hooks/**` PreToolUse denies, the clarify-budget hook, the Stop floor,
  registered in `.claude/settings.json`
- floors: `harness/intake.sh` — sentinel, the HARNESS-CAPTURED Gate-A spec review, TTY-gated
  `ratify`, convert preflight

Most of what pi needs is a *distribution* problem (role contracts on a package surface) plus a
*container* problem (OS confinement), which is why the work belongs here rather than in the
forge.

## Verified foundations (2026-11-20)

- pi natively discovers project `.agents/skills/` (pi `docs/skills.md:61`), walking from cwd up
  to the repo root. The forge's `.agents/skills/` trees already exist and already use the
  neutral render ("the interactive ask tool" ≈ pi's `ask_user_question`). **Skills need zero
  copies.**
- `harness/intake.sh` floors are actor-neutral bash: the `SPEC_REVIEW_BACKEND` dispatcher
  (intake.sh:986–1023, body source :980–991, frontmatter-stripped by the awk at :983), the
  TTY-gated `cmd_ratify`, and the sentinel/record writes under `.harness/`. A `pi` backend is
  ONE new arm.
- This repo already ships two of the three mechanisms: agent-modes (tool removal, `tool_call`
  path refusal, `writeScope`/`writeDeny`, bash allowlist `none|safe|all`, drift audit, project
  override `<repo>/.pi/agent-modes.json`) and the `pi.agents` package key (pi-subagent reads
  agent-contract dirs from `package.json`).
- gondolin is the OS-confinement tier the forge's honest seam defers — the symlink portal and
  the PTY-wrapper self-ratify vector are closed today only by textual matching.

## Repo topology — what lives where

| lane | where | artifacts |
| --- | --- | --- |
| this branch | `pi-agents`, `feat/architect-forge` | this plan, the four skills (`forge/skills/**`), role contracts (`forge/agents/**`), `package.json` wiring, optional forge-facing extension, G1 probe results |
| forge PRs off `main` | `shinro-forge` | `.pi/agent-modes.json`, the `intake.sh` `pi` backend arm, the G2 gondolin recipe, honest-boundary prose |
| machine only | — | G1 capability probe, recorded into this doc |

## Phase 1 — skills port (first)

**Scope decision (2026-11-19): the skills land in *this* repo, not in the forge.** The first draft of
this phase assumed the forge's `.agents/skills/**` trees could serve pi as-is, verified only. It was
verified — pi does read them (below) — but it is the wrong surface: those trees exist only for a
session whose cwd reaches a forge checkout, which excludes the gondolin guest and every other repo.
So the package **authors the pi render itself** (`forge/skills/**`, `pi.skills`) and the forge's
canonical `harness/skills/**` remains the protocol's source, with pi's prose a deliberate divergence.
`forge/README.md` states which edits belong upstream and which belong here.

| # | what changes | why | how it is checked | status |
| --- | --- | --- | --- | --- |
| 1 | Verification only — no edits | is the forge's existing `.agents/skills/**` tree even discovered by pi? | `pi` at the forge root: startup diagnostics list the four skills; `/skill:clarify` loads; the ask-tool phrasing resolves | **done — PASS** (evidence below) |
| 2 | Author the four skills as pi renders in `forge/skills/**`; wire `pi.skills` + `files` | the workflow must be installable, not cwd-dependent | skills appear in a throwaway dir's startup diagnostics after `pi install <pkg> -l`; `npm run check` green | **done** |
| 3 | Pull Phase 3 row 3 forward: the five role contracts in `forge/agents/**` with pi frontmatter (`tools`, `write_scope`); wire `pi.agents` | skills without roles is half the workflow, and both ship in one release | `declaredAgentDirs` + `discoverAgents` list every ported role; a dispatched agent answers; `npm run check` green | **done** — four roles, not five (see below) |

**Scope change inside row 3 (2026-11-19): the `reviewer` role is retired on the pi surface.** One
model reviewing a PR cannot make its own agreement evidence; two lanes on two models can, and the
swarm's correctness lane already carries the retired role's mandate in more operational detail. So a
pi-driven forge review is `code-review-swarm` (both lenses), bridged by the new **`forge-review`**
skill to the forge's machine record — the harness's Build 2a extracts exactly one
`<!-- shinro:review:begin v1 -->` JSON block (`verdict` + `findings[{id,severity,location,finding,
suggested_fix}]`), while the swarm emits a merged SEV1–SEV4 markdown table. The bridge is
deterministic: `SEV1→CRITICAL … SEV4→LOW`, `path:line (symbol) → path:line` (the symbol moves into
the finding sentence), `CLEAN` / `CONCERNS` / `BLOCK-RECOMMENDED` from the SEV1 count. Both lanes
feed the record and the `disposition` adjudicator (user decision, same date) — a design row that
guarantees the next defect is a real finding, and adjudication is what separates it from noise.

Consequences to keep in view: a pi-driven forge review costs three model calls where it cost one;
`disposition.md`'s input contract now reads the merged table rather than a single reviewer's
`CRITICAL..INFO` list; and Phase 3 row 5's `REVIEWER_BACKEND=pi` arm becomes a pure stdout extractor
precisely because the bridge makes that stdout already well-formed. The forge's own
`.claude/agents/reviewer.md` stays byte-untouched — the Claude path and the ollama / `claude-fresh` /
codex backends keep consuming it.

Do not edit the forge's `harness/skills/**` canonical sources for pi-only concerns — they are
human-PR-tier and the drift-guard byte-compares the rendered trees. A **protocol** change goes
upstream first and is then re-rendered here; a **pi host-posture** change is authored here.

### Phase 1 — verification evidence (measured 2026-11-19, this box)

Probe context: forge working tree `main` @ `767bb98`, pi 1.5.2, model
`ollama-cloud/deepseek-v4.1-flash`, `--no-mcp --no-session`. This harness has no TTY, so the TUI was
driven over a pty (`python3 pty.fork`, keys written to the master); every quotation below is a
settled frame, not a mid-repaint one.

| check | how | observed |
| --- | --- | --- |
| discovery in the forge tree | `pi --tui-mode regular --verbose` at the forge root | `[Skills] / project` lists `.agents/skills/{clarify,decompose,forge-workflow,spec-authoring}/SKILL.md` by absolute path — pi resolved the existing tree, no copies, no `--skill` flags |
| `/skill:clarify` loads | type `/skill:` in the TUI, then submit `/skill:clarify <instruction>` | completion lists all four at project tier (`skill:clarify [p]`, …); the turn renders `[skill] clarify (ctrl+o to expand)` |
| the ask-tool phrasing resolves | with the skill loaded: "ask me the single top-ranked clarifying question using the ask tool the skill names, with 3 options in the skill's option format" | a real `ask_user_question` dialog opened: header chip `scope-intent`, options 1–3 with `(Recommended)` first, the `Type something.` row, the `Enter to select · ↑/↓ · Esc` footer — the skill's *Option format*, rendered by pi's own ask UI |

Baseline drift/test state at the time (nothing in the forge was edited):
`bash harness/skills-sync.sh --check` → exit 0 (no drift); `bash tests/forge-workflow/run.sh` →
`25 passed, 0 failed`.

**Why the pi render names the tool.** `ask_user_question` is not a pi built-in — it ships in the
`@juicesharp/rpiv-ask-user-question` extension. Run pi with `-ne` and the tool is gone: the same
clarify prompt then emitted the three options as plain assistant text (reproduced twice), and a
direct question answered `EXACT_TOOL_NAME: none — my tool list contains only read`. A pi without that
extension has no referent for "the interactive ask tool", and the skill silently turns "asks the
human" into "writes the questions down". Naming the tool costs nothing and removes the guess; the
G2 acceptance item below inherits the consequence (the guest must install the extension).

Unrelated noise in the same startup block a re-check would read: two user-skill warnings
(`use-railway` collides with `~/.pi/agent/skills/use-railway`; its 1041-char description exceeds
pi's 1024 limit). Neither touches the forge skills.

### Phase 1 — what shipped (this repo)

| path | what | verified by |
| --- | --- | --- |
| `forge/skills/{clarify,spec-authoring,decompose,forge-review,forge-workflow}/SKILL.md` | the pi render of the five skills on `pi.skills` | throwaway-dir `pi install <pkg> -l` → startup diagnostics list them under the package |
| `forge/agents/{architect,builder,spec-reviewer,disposition}.md` | pi frontmatter: lowercase `tools`, `write_scope` on the two writing roles; `model` omitted so a dispatch inherits the dispatcher's | `discoverAgents` lists all four (`architect [package] tools=read,grep,find,ls,write,edit,ask_user_question,subagent scope=specs`, …); a dispatched agent answered `OK` |
| `package.json` | `pi.skills`, `pi.agents`, `files`, description, keywords | `node scripts/check-manifest.mjs` + packed-file assertions |
| `forge/README.md` | provenance, the pi-vs-neutral delta, which edits belong upstream | — |
| `README.md`, `CHANGELOG.md` | install surface + an `Unreleased` entry | — |

`npm run check` → manifest publishable, five suites green (modes, swarm, subagent, lanes, gate).

**Found while probing, not fixed here:** the `subagent` tool's description advertises no agent
names, and startup diagnostics do not list agents either — so a pi session cannot discover that
`architect` or `builder` exist unless it is told or it dispatches a name and reads the error. The
plan's own check ("probe lists the new agents") had to become the deterministic `discoverAgents`
dump plus a real dispatch for that reason. Making agents discoverable from the tool surface is a
separate design row, not a Phase 1 blocker.

**Corrected in the pi render, worth fixing upstream:** `spec-authoring` claimed Gate B was still a
future stage and counted "six invariants"; `decompose` documents Gate B as wired
(`harness/intake.sh analyze`, nine invariants). The pi render follows `decompose`.

**Precedence caveat (found while testing the collision, documented in `forge/README.md`).** Inside a
forge checkout the project `.agents/skills/**` tree shadows the package's pi render — pi keeps the
first-discovered skill by name and warns (`"clarify" collision: ✓ auto (project) … ✗ ./forge/skills/…`).
So the pi render serves every session *outside* a forge checkout (the guest, other repos), while a
forge-root session still reads the neutral render — which does work under pi, so this is a posture
question for the forge upstream, not a defect here.

## Phase 2 — gondolin workflow (the container decision)

| # | what changes | why | how it is checked | may touch |
| --- | --- | --- | --- | --- |
| G1 | Nothing (probe). Results recorded in this doc | decide (a) interactive TTY guest session vs per-command sandboxed exec; (b) per-mount ro/rw (repo ro + `specs/` rw) vs one rw mount; (c) persistence across execs; (d) `--vmm krun` on this box (`/dev/kvm` present) | `npx -y @earendil-works/gondolin --help` plus one probe exec answering (a)–(d) from evidence | this doc |
| G2 | Launch recipe — forge PR (new `harness/gondolin-architect.sh`, or docs prose first) | guest mounts: repo **ro**, `specs/` **rw**, `.harness/` **ro**, `.beads/` **ro**, vault **ro** — deny-hook path rules become filesystem physics, including the `.harness/` spec-review record the transcription trap keys on | in-guest: a write to `harness/**` fails EROFS while a write under `specs/` succeeds; `pi` + this package installed in-guest, plus `@juicesharp/rpiv-ask-user-question` and the clarify skill's ask step opening a dialog rather than prose (the Phase 1 finding); PATH export, `git config --global --add safe.directory "*"` + identity, `--rootfs-size` sized | forge harness or docs |
| G3 | Scope decision recorded here | sandbox the architect-intake phase first (sharpest write boundary); builder is a later phase with a materially different mount policy (rw `sandbox/**`, tests, the git floor) | decision + rationale in this doc | this doc |
| G4 | Honest-boundary prose (forge role file + `docs/limitations.md`) | symlink/PTY vectors become guest-closed for sandboxed sessions; in-place sessions keep the documented residual | the prose names both postures and what each leaves open | forge |

Ratify/convert stays host-side: the human runs `intake.sh ratify` outside the guest. The guest
holds no ratify authority and `.harness/` is read-only there regardless.

## Phase 3 — mechanical completion (this branch's payload)

| # | what changes | why | how it is checked | may touch |
| --- | --- | --- | --- | --- |
| 3 | ~~Port the five forge roles to `forge/agents/**`~~ — **moved into Phase 1** (row 3 there): the roles, `pi.agents` and `files` shipped with the skills, in one change set | the role contracts must ship on the npm surface, and half a workflow is worse than none | see the Phase 1 "what shipped" table; the release itself is the runbook step (`npm version patch` → CHANGELOG → publish) and has not been run | `forge/agents/**`, `package.json`, `CHANGELOG.md` |
| 4 | Forge `<repo>/.pi/agent-modes.json`: an `architect` mode (`writeScope: ["specs"]`, writeDeny harness/.claude/.beads/.git/vault, `bash: "safe"`, role prompt) | pi-native replacement for the PreToolUse *path* denials; the coarse belt under gondolin's fine belt | forge session in that mode: a write to `harness/**` refused at `tool_call`, a write under `specs/` succeeds, bash allowlist-gated — mirror `modes/check.sh` assertions. **Partly superseded:** the package now ships a `forge` mode that denies the machinery trees (`harness`, `.claude`, `.beads`, `.harness`, `gate`, …) at `tool_call` everywhere, so this row is now only about the *narrower* `specs/**` write scope | forge `.pi/agent-modes.json` (+ local prompt file — note that a layer-3 mode CANNOT carry one, see Unknowns) |
| 5 | Forge `harness/intake.sh`: a `pi` arm in `run_spec_reviewer` + body source | Gate-A's consensus oracle must be spawnable from a pi session, in-place or in-guest | `SPEC_REVIEW_BACKEND=pi harness/intake.sh spec-review` on a scratch intake writes a well-formed `.harness/intake-spec-review.json`; forge `tests/forge-workflow/run.sh` green | forge `harness/intake.sh` (not a floor-hash input; `lib.sh` is) |
| 6 | End-to-end dry run (forge, scratch state) | prove the loop | `intake.sh start` driven by pi (in-guest if G1 allows) → skills → spec-review (pi backend) → human `ratify` on the host; `draft → ready-for-tasks` with zero `.claude/**` edits | scratch state |
| 7 | Optional, deferred: a forge-facing pi extension for bash command-form denies (ratify wrapper forms, clarify budget) | not expressible in mode config (`bash` is `none|safe|all`) | separate design row; only if gondolin + the harness floors leave a gap that matters | new extension here |

## Unknowns (resolve before their step)

- G1 (a)–(d) — gondolin interactive sessions, mounts, persistence. Phase 2's first action.
- ~~Layer-3 `agent-modes.json`: can it define NEW modes or only override shipped ones?~~ **Resolved
  2026-11-19** (read `v-model-agents/modes/index.ts`): `mergeConfig` DOES add an unknown mode name
  from a layer-2/3 override, falling back to a minimal profile — so a project can define a new mode.
  But `loadPrompt` resolves `promptFile` inside the extension's own directory, so an
  override-defined mode **cannot carry a prompt contract**. Consequence: a mode with a contract
  ships in the package (that is why `forge` is a shipped mode, `docs/forge-mode-plan.md`), while
  row 4's `architect` mode can set path rules only — its prompt has to live somewhere else, or
  the mode ships here too.
- Whether the guest network policy can be narrowed to just the reviewer backend's needs.
- **Agent discoverability (found in Phase 1, not resolved).** The `subagent` tool's description
  advertises no agent names and startup diagnostics list none, so a session cannot learn that
  `architect` or `builder` exist unless told. The Phase 1 checks therefore used the deterministic
  `discoverAgents` dump plus one real dispatch instead of a model answer. Whether to surface the
  agent list on the tool (and where) is its own design row.

## Invariants

- The forge's `.claude/**` trees and the Claude drift-guard stay byte-untouched — the existing
  path keeps working for Claude/Codex sessions.
- The forge's git-native floor (`harness/githooks`) is untouched and stays actor-independent on
  the host: it catches any host-side session regardless of this port.
- Git protocol: nothing is committed or pushed without an explicit `go`; every approved step
  boundary ends with a commit AND a push of that step.
