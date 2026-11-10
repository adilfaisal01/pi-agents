# 02 — Lanes and partition

## The row is the unit of both work and parallelism

The V has real edges: a test derives from a frozen spec; a build derives from the test
surface. Fanning out *stages* — plan, sysDV, build concurrently — destroys the ordering
the V exists to create, because the build appears while the tests are still being
written and the tests then encode the implementation.

Rows are independent. So:

- **Across stages, for one row: serial.** spec → tests → build.
- **Across rows: parallel, pipelined.** `R1→tests1→build1` beside `R2→tests2→build2`.
- **Within a stage: parallel**, bounded and scoped.

## Partition rules

A candidate lane split is legal only if **all four** hold. Failing any one, the rows are
one lane.

1. **Disjoint write paths.** Two lanes editing the same file cannot be merged
   mechanically; the merge becomes a human decision in the middle of an automated wave.
2. **Disjoint interface surface.** For compiled/control systems the interface is the
   C-ABI: port order and shapes, `state_*` layout, manifest fields, pinned hashes. Two
   rows touching the same interface produce test suites that encode contradictory
   assumptions, and no build can satisfy both. **The interface is the hard
   serialization point.**
3. **Disjoint generated-path ownership.** Generated files that are rewritten in place —
   `graph_data.zig`, `codegen/emosqp/`, `.zig-cache/`, `build/` — are shared state. In a
   single checkout they are "overwritten by whichever generator ran last", so a parallel
   wave produces nondeterministic artifacts. Each lane gets its own worktree, or the
   lanes serialize.
4. **No shared scarce device.** One board, one robot, one serial port: hardware steps
   queue on a mutex. Parallelism is for the dev host.

## Fan-out width

- 3–4 lanes in flight, not the maximum.
- Each lane is a full agent process with its own context; a 1T-parameter model at 1M
  context is latency, not free parallelism.
- The cap is a property of the runner (`MAX_PARALLEL_TASKS = 8` in the shipped
  `subagent` example), not a target.

## Waves are levels, and they run bottom-up

A row carries a `level` (docs/06): `L3` unit, `L2` component, `L1` subsystem,
`L0` system. That is the V's right arm — the verification at a level is written at the
same level of abstraction as the claim, by a party that did not write the code — and it
is what makes bottom-up ordering meaningful: you cannot freeze a system-level test while
the unit-level contracts it composes are still moving.

One wave = one level. `gate/wave.sh` runs it:

```bash
./gate/wave.sh rows ledger.md             # id, level, tests
./gate/wave.sh levels ledger.md           # the levels present, bottom-up
./gate/wave.sh sysdv --ledger ledger.md --level L3 --base <pre-implementation-sha> --confirm --width 3
```

Per row, in parallel up to `--width` (3–4 per the rule above):

1. `git worktree add --detach <root>/<id> <base>` — one worktree per lane, so generated
   paths and caches cannot collide (partition rule 3).
2. spawn a `pi` child in that worktree with the row's requirement, design and interface,
   the `sysdv` system prompt, and no inherited extensions.
3. refuse the lane unless: nothing outside `tests/**` + test config changed, at least one
   test was created, and the suite is **red** at `<base>`. A green suite at the
   pre-implementation commit is the vacuity the whole discipline exists to catch.

Then, serially: the barrier (`gate/wave.sh freeze`) composes the lanes' tests, runs the
composed suite red at the same commit, and pins (`gate/lock-check.sh <sha>` is what
re-checks the pin afterwards). Then wave 2 (`gate/wave.sh build --pin <sha>`) runs one
implementation lane per row at the pin, and the composed gate runs once for all lanes
together — that run, and only that run, supports the delivery claim.

```bash
./gate/wave.sh freeze --ledger ledger.md --level L3 --base <sha> --root <wave-root>
#   -> composes, requires RED at <sha>, commits, prints the pin as its last line
./gate/wave.sh build  --ledger ledger.md --level L3 --pin <pin> --confirm --width 3
#   -> lanes at the pin, then the composed gate, serially, once
```

`sysdv` and `build` refuse to spawn lanes without `--confirm`: the requirements are
confirmed by the human (plan authors the ledger) before any lane runs.

`wave.sh` is a script, not an agent call, on purpose: `DECISIONS.md` #2 — scripts
certify, the human judges. The interactive equivalent is the `subagent` tool with a
`cwd` per lane; the difference is that the script also creates the worktree and checks
the three refusals, so a wrong wave fails instead of looking successful.

## The one thing that cannot be parallelized away

The composed gate. Two lanes green individually is the classic integration failure: each
lane's tests are consistent with that lane's assumptions, and the composed tree is the
first place the assumptions meet. The composed run is serial, after the merge, and it is
the only run that supports the delivery claim.

It is also why a build lane's own check is scoped to its row: every lane starts at the
pin, where *every* row's tests exist and the ones it does not own are still red. So the
lane runs `run-tests.sh -k "<the row's tests>"` and the composed gate runs the whole
suite with no selection. Green per lane says "this row is satisfied in isolation"; it is
not, and can never be, the delivery claim.

## Partition record

The lane split is an artifact, not a conversation. It belongs in the plan output:

```markdown
| lane | rows | write scope | interface touched | generated paths | serialized behind |
| --- | --- | --- | --- | --- | --- |
| L1 | R1, R2 | src/shinro/controllers/ | none | none | — |
| L2 | R3 | src/shinro/runtime/ | C-ABI ports | graph_data.zig | L1 (interface) |
| L3 | R4 | tests-only fix | none | none | hardware queue |
```

If two lanes cannot be shown disjoint on columns 3–5, merge them before the wave starts.
Discovering the collision during a wave costs the wave.
