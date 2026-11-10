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

## Open

1. **Auto-restore on drift?** When an oracle run changes tracked files, should the gate
   revert them (`git checkout -- <paths>`) or only report? *Current lean: report only.* A
   run that regenerates goldens on purpose would be silently undone, and the report is
   what makes the human decide.
2. **Who certifies the barrier mechanically?** The composed-red run and the pin check are
   scriptable; "are these the right tests" is not. *Current lean: scripts certify, the
   human judges, no agent certifies.*
3. **Do build lanes get a subagent too, or stay a mode?** A mode shares the transcript
   with plan; a subagent isolates but doubles the orchestration. *Current lean: build is a
   mode (it needs continuity with its own red output), sysDV is a subagent (it must not
   have continuity).*
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
8. **How does `sysdv` reach a stranger's pi?** pi's built-in extensions are only
   `mcp`, `llama.cpp`, `codemode`, `tool-search` — subagent is an *example*, not built in,
   and a pi package can install extensions/skills/prompts/themes but **not** agent
   definitions. So `pi/agents/sysdv.md` alone installs nothing. *Open, two options:*
   (a) the package ships its own minimal runner that spawns `pi --print --mode json
   --no-session --tools … --append-system-prompt agents/sysdv.md` and then verifies the
   child's `git diff --name-only` ⊆ `tests/**` — self-contained, and it closes the hole
   where `keepExtensions` lets a read-only mode delegate a write; (b) vendor pi's MIT
   subagent example (two files, ~48 KB, upstream-coupled) and document the
   `~/.pi/agent/agents/` copy step.
