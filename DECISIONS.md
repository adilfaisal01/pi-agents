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
    models, the tracked-tree audit, and the `sysdv` subagent definition. *(Superseded by
    #17: the guard moved to `modes/` in this repo (as the package) and the subagent tool is
    deleted; `gate/` and `agents/` are still vendored here.)*
11. **The apparatus is distributed as a pi package.** `package.json` carries the
    `pi-package` keyword and a `pi.extensions` manifest pointing at
    `pi/extensions/agent-modes/index.ts`, so `pi install git:github.com/<owner>/v-model-agents`
    works for anyone with pi, with no clone and no symlink. `install.sh` is demoted to a
    development convenience against this checkout. Consequences: the shipped
    `config.json` carries **no** provider and **no** model ids (a package cannot know
    what a stranger has), and the user configures via layered override files
    (`~/.pi/agent/agent-modes.json`, `<repo>/.pi/agent-modes.json`) rather than editing a
    file inside the package, which `pi update` would overwrite. *(Superseded by #17:
    `pi.extensions` is now `pi.skills`, there is no `config.json` to layer, and
    `install.sh` is deleted — the package ships one skill and no executable hooks.)*
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
17. **The discipline is a skill; the mode guard is its own package.** The
    apparatus shipped two pi extensions: a mode guard for the parent session (845 lines)
    and a vendored `subagent` tool (1395 lines). Neither was load-bearing. `gate/wave.sh`
    already spawned its own lanes — `pi --mode json -p --no-session -ne --tools …
    --append-system-prompt <the agents/ body>` — and already did the scope, red and
    composition checks itself, with a `--child` stub for the self-tests. The subagent
    tool was called by nothing; the mode guard only ever protected **your** session, and
    it had already caused a real failure (a child inherited it, started in `oracle`, and
    lost `write`, which is why `-ne` is in the spawn). What replaces them: a skill
    (`skills/v-model/SKILL.md`, `disable-model-invocation: true`) that a human invokes as
    `/skill:v-model`, and `--model` / `PI_SYSDV_MODEL` / `PI_BUILD_MODEL` on the lane
    process in place of per-mode model config. The mode guard itself is not deleted but
    **in its own directory, as the package**: `modes/` is a self-contained pi package
    (`index.ts` + `config.json` + `prompts/` + its own `selftest.mjs` and `check.sh`), and
    the repo-root `package.json` points at it — so `pi install <this repo>` gives you the
    modes and nothing else, while this discipline is optional material that is not part of
    the install. The modes have no dependency on the gate, the agents, or the docs, and
    their 38 assertions run on their own (`./modes/check.sh`). The coupling was one file:
    the shipped `writeDeny` listed `gate/run-tests.sh`, and the `plan` prompt quoted
    `gate/wave.sh`; both are now generic, with the discipline-specific paths left to a
    project-level `<repo>/.pi/agent-modes.json`. What is lost, deliberately: nothing stops
    the **parent** session from editing source — the skill is advice, and the refusals
    live where the process is owned. A user who wants the wall starts `pi --tools
    read,grep,find,ls,bash`. The 62 extension assertions go with the code they tested;
    `check.sh` now runs the 73 gate assertions plus the skill's frontmatter and the paths
    its procedure names. (`docs/01`, `README`)

## Open

1. **Auto-restore on drift?** When a run changes tracked files, should the gate
   revert them (`git checkout -- <paths>`) or only report? *Current lean: report only.* A
   run that regenerates goldens on purpose would be silently undone, and the report is
   what makes the human decide. *Moot after #17* for the parent session: nothing watches
   your tree any more, so this is only a question for the lanes, which are checked on
   return rather than reverted.
2. **Who certifies the barrier mechanically?** *Answered for the mechanical half:*
   `wave.sh freeze`, `wave.sh build` and `lock-check.sh` refuse on drift, vacuity, scope
   and composition; "are these the right tests" is still the human's judgement. Every
   wall is a refusal with a nonzero exit, never a warning.
3. **Do build lanes get a subagent too, or stay a mode?** *Answered for the scripted
   path:* a build lane is a spawned child like `sysdv` (`agents/build.md`, own
   worktree at the pin, no inherited extensions), because continuity comes from the
   row's recorded red, not from a shared transcript. *Re-answered by #17:* there is no
   interactive mode left to fall back on; the scripted path is the only path.
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
7. **Does this repo carry the mode/guard implementation?** *Answered: yes, then no.* `pi/`
   carried the guard and the subagent tool. #17 deletes the subagent tool and moves the
   guard to `modes/` in this repo (as the package); the repo also carries a skill, a
   scripted gate, and two lane contracts, none of which the modes depend on.
8. **How does `sysdv` reach a stranger's pi?** *Answered, then simplified by #17.* The
   original answer vendored pi's `subagent` example (MIT) so `pi install` alone yielded a
   working `sysdv`. It is not needed: the lane is a plain `pi` child that `gate/wave.sh`
   spawns with `--tools` and `--append-system-prompt agents/sysdv.md`, so the shipped
   package has no executable hooks at all. Superseded reasoning, kept because it is the
   reason `-ne` and the explicit tool list are in the spawn: pi's built-in extensions are
   only `mcp`, `llama.cpp`, `codemode`, `tool-search` — subagent is an *example* — and a
   pi package can install extensions/skills/prompts/themes but **not** agent definitions.
