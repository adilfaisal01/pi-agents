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
