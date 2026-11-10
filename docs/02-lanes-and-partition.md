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

## The one thing that cannot be parallelized away

The composed gate. Two lanes green individually is the classic integration failure: each
lane's tests are consistent with that lane's assumptions, and the composed tree is the
first place the assumptions meet. The composed run is serial, after the merge, and it is
the only run that supports the delivery claim.

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
