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
6. **Licence.** None chosen. A practices repo with copy-pastable gate scripts needs a
   decision before it is public.
7. **Does this repo carry the mode/guard implementation?** The path-scope refusal and the
   drift audit currently live in a local agent extension, not here. *Open: vendor the
   guard here as a small reference implementation, or keep it where it runs.*
