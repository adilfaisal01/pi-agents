# Decisions and open questions

Decisions taken, and questions still open. Anything here marked *open* is not enforced by
the documents yet — read it as a known gap, not as a plan.

## Taken

1. **Roles are capability profiles, not personalities.** Two roles that differ only in
   prompt tone are one role. (`docs/01`)
2. **The row is the unit of work and of parallelism.** Stages are serial within a row;
   rows pipeline across lanes. (`docs/02`)
3. **The barrier is compose-then-freeze, not "all lanes finished".** The composed suite
   runs once before the pin. (`docs/04`)
4. **The pin is a commit sha, not a file list.** A file list forgets the selector
   (`addopts`), `conftest.py`, and the command. (`docs/04`)
5. **The canonical test command lives in a locked script** (`gate/run-tests.sh`) with the
   marker selection spelled out explicitly, so the `Makefile` and `pyproject.toml` stay
   editable by build lanes without changing what "green" means. (`docs/04`)
6. **Drift is a refusal with a nonzero exit.** Never a warning on a green run. (`docs/07`)
7. **Amendments are human.** Only a commit from the human, stating that the spec changed,
   revises a frozen test. A build lane never edits a test. (`docs/04`, `docs/05`)
8. **Some claims have no test.** Semantic equivalence, cross-host timing envelopes, and
   absence-of-failure rows stay `structural` or `declared`. (`docs/06`)
9. **Lane width is 3–4**, below the runner's maximum, because each lane is a full agent
   process and a full context. (`docs/02`)
10. **The apparatus is vendored here, not kept in a personal install.** `pi/` is the
    profile: the mode guard with `writeScope`/`writeDeny`, the shell policy, per-mode
    models, the tracked-tree audit, and the `sysdv` subagent definition.
11. **The apparatus is distributed as a pi package.** `package.json` carries the
    `pi-package` keyword and a `pi.extensions` manifest pointing at
    `pi/extensions/agent-modes/index.ts`, so `pi install git:github.com/<owner>/v-model-agents`
    works for anyone with pi, with no clone and no symlink. `install.sh` is demoted to a
    development convenience against this checkout. Consequences: the shipped
    `config.json` carries **no** provider and **no** model ids (a package cannot know
    what a stranger has), and the user configures via layered override files
    (`~/.pi/agent/agent-modes.json`, `<repo>/.pi/agent-modes.json`) rather than editing a
    file inside the package, which `pi update` would overwrite.
12. **The barrier is scripted, and every wall is a refusal.** `gate/wave.sh freeze`
    composes the lanes, requires the whole suite RED at the pre-implementation commit,
    requires a clean collect, refuses two lanes claiming one path before applying
    anything, commits the lock surface with a message naming the rows, and prints the pin
    as its last line. `gate/wave.sh build` then runs one lane per row at the pin and the
    composed gate once, serially. Neither is a model's judgement call. (`docs/04`,
    `docs/05`)
13. **A build lane's own check is scoped to its row.** Every lane starts at the pin,
    where all rows' tests exist and the ones it does not own are still red, so a lane
    cannot be green on the whole suite. The lane runs `run-tests.sh -k "<the row's
    tests>"`; the composed gate runs everything with no selection. Green per lane means
    "this row is satisfied in isolation", never the delivery claim. (`docs/02`, `docs/05`)
14. **The row carries its write scope.** The ledger's `sources` column is the plan →
    build contract: plan fills it, the lane is refused writes outside it, and an empty
    cell is a row nobody scoped (refused, not "anything"). Naming the lock surface in
    `sources` is a refusal too. (`docs/05`, `docs/06`)
15. **Spawning requires the human's confirmation.** `sysdv` and `build` refuse to run
    without `--confirm`, and `plan` authors `ledger.md` in the docs/06 schema as its
    artifact instead of describing a plan in prose. The confirmation is the acknowledgment
    that someone read the rows; it is not a click-through. (`docs/01`)
16. **The record trail is append-only.** Each stage appends one JSON object per row to
    `<ledger dir>/records.jsonl` (single writer per stage, append mode, never rewritten):
    `red_recorded` → `frozen` → `built_green` → `gate_green`, or `refused` with a reason.
    The latest line per id is the current state; every earlier line is the audit trail;
    a malformed line is skipped and counted. The trail does **not** carry the verdict —
    `proved` / `conditional` / `structural` / `declared` stays a judgement in the ledger,
    and the trail is what that judgement cites. (`docs/06`)

## Open

1. **Auto-restore on drift?** When an oracle run changes tracked files, should the gate
   revert them (`git checkout -- <paths>`) or only report? *Current lean: report only.* A
   run that regenerates goldens on purpose would be silently undone, and the report is
   what makes the human decide.
2. **Who certifies the barrier mechanically?** *Answered for the mechanical half:*
   `wave.sh freeze`, `wave.sh build` and `lock-check.sh` refuse on drift, vacuity, scope
   and composition; "are these the right tests" is still the human's judgement. Every
   wall is a refusal with a nonzero exit, never a warning.
3. **Do build lanes get a subagent too, or stay a mode?** *Answered for the scripted
   path:* a build lane is a spawned child like `sysdv` (`pi/agents/build.md`, own
   worktree at the pin, no inherited extensions), because continuity comes from the
   row's recorded red, not from a shared transcript. Interactively, `build` is still a
   mode for a human-driven change.
4. **How is a test's tolerance derived from a requirement?** Nothing here prevents a
   sysDV lane from inventing a tight tolerance the hardware can never meet. *Open:
   probably plan must supply the tolerance in the row, and sysDV may not widen or
   tighten it.*
5. **Hardware queue.** One board/robot means lanes queue, but there is no queue artifact
   yet — only a rule. *Open: a lock file with a holder and an expiry is probably enough;
   nothing specified.*
6. **Licence.** None chosen, but the package manifest claims MIT — decide before publish.
   A practices repo with copy-pastable gate scripts needs the decision before it is
   public.
7. **Does this repo carry the mode/guard implementation?** *Answered: yes.* `pi/` holds
   the guard and `package.json` makes it installable.
8. **How does `sysdv` reach a stranger's pi?** *Answered: vendor pi's subagent example
   (MIT) and adapt it.* pi's built-in extensions are only `mcp`, `llama.cpp`, `codemode`,
   `tool-search` — subagent is an *example* — and a pi package can install
   extensions/skills/prompts/themes but **not** agent definitions. So the package now
   ships `pi/extensions/subagent/` (upstream's two files, `LOCAL:` markers on every
   change) with two adaptations: a third agent-discovery root pointing at the package's
   own `pi/agents/` (so `pi install` alone yields a working `sysdv`, while a user's own
   agent of that name still wins), and a `write_scope` post-check that fails the lane if
   the child wrote outside it. Rejected: a hand-written ~120-line runner (more code to
   own for less capability) and third-party packages (`@mystilleef/pi-subagent` is a
   46k-line framework whose tool takes no `cwd`, so it cannot do the worktree contract).
