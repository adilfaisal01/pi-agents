# 06 — The ledger

One row per claim. A row is the unit of work, of parallelism, and of verification.

## Schema

```markdown
| id | level | requirement | design | interface | sources | tests | evidence | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | L1 | CTE mean ≤ 0.05 m, max ≤ 0.10 m over 48 s at stride 12 | anchored frame: p' = R(−θ)(p − anchor) | none | src/shinro/controllers/ | test_tracking_cte_bounds | run_tracking --anchor (48 s) | proved |
```

| column | rule |
| --- | --- |
| **level** | the abstraction this row is claimed at: `L3` unit, `L2` component, `L1` subsystem/integration, `L0` system/end-to-end. The test must be written at *this* level, and a wave (`gate/wave.sh`) only runs rows at one level at a time, bottom-up. Two rows at different levels are two rows, not two opinions about one claim. |
| **requirement** | measurable. Inputs, output, tolerance, duration, conditions. Not an adjective. |
| **design** | one line, plus the alternative that was rejected and why. A design with no rejected alternative is an assumption. |
| **interface** | what the change is allowed to touch: C-ABI ports and order, `state_*` layout, manifest fields, pins. `none` is a claim, not a blank. |
| **sources** | the row's **write scope**: source paths or directories a build lane may change (`src/app.py`, `src/runtime/`). This is the plan → build contract — `gate/wave.sh build` passes it to the lane and refuses any write outside it. An empty cell is not "anything"; it is a row nobody scoped, and the lane is refused. Naming the lock surface here is a refusal too. |
| **tests** | node ids on the frozen surface. Every test names its row. A build lane also uses this column to select *its* tests: every lane starts at the pin, where the other rows' tests are still red, so the lane checks `-k` over these ids and the composed gate checks everything. |
| **evidence** | the command a stranger runs. A command that cannot be run from a clean checkout is not evidence. |
| **verdict** | below. |

## Verdict vocabulary

Four values, and the last two are not failures:

| verdict | means | example |
| --- | --- | --- |
| `proved` | a mechanical check that would fail if the claim were false | oracle parity vs the live run at 0.0 |
| `conditional` | proved only under an explicit hypothesis | `add(x, 0) → x` is IEEE-exact but **not** bitwise for `x = −0.0` |
| `structural` | argued from construction, not measured | the optimized graph has the same ports ⇒ the C-ABI is unchanged |
| `declared` | asserted, with the trusted base named | Zig → LLVM → `.so` is out of scope; the row says so |

The purpose of `conditional` and `declared` is to stop a green row from asserting more
than it measured. A ledger where every row is `proved` is a ledger that has stopped
distinguishing between checks and beliefs.

## The ceiling rule

Some claims cannot be discharged by any test:

- **Semantic equivalence** of a transformed program (compiler/codegen: "the optimized
  output computes the same function as the source"). A green suite says the exercised
  sequences agree; it does not say the two programs denote one function.
- **Timing and resource envelopes** measured on one host, asserted about another.
- **Absence of a failure mode** that the suite never provokes.

Those rows stay `structural` or `declared`, or they get a proof obligation of their own.
"Tests pass" is not a verdict.

## Traceability

Three links, all mechanical where possible:

1. **test → row**: the test name or docstring carries the row id.
2. **freeze commit → rows**: the commit message lists the rows it freezes.
3. **build commit → row**: the commit message names the row; the diff is the row's
   write scope.

A row with no test is legitimate (`structural`). A test with no row is not — it is an
assertion nobody asked for, and it will be the first thing a future refactor breaks.

## The trail: an append-only record per row

`gate/wave.sh` writes a JSONL file next to the ledger (`<ledger dir>/records.jsonl`,
overridable with `--records`, disabled with `--no-records`). One object per line,
**appended, never rewritten** — a crashed wave keeps the lines it wrote, a reader never
sees a half-line, and a malformed line is skipped and counted rather than making the
history unreadable.

```json
{"record":"req","id":"R1","requirement":"add(a,b) returns a+b","test_place":"tests/test_add.py::test_add","files_which_cover":["tests/test_add.py"],"status":"red_recorded","stage":"sysdv","level":"L3","evidence":"./gate/run-tests.sh","created_at":"2026-11-11T02:14:03Z","base":"4f2c1ab…","pin":null,"detail":"red at 4f2c1ab"}
```

| field | meaning |
| --- | --- |
| `requirement` | copied from the ledger row, not referenced — a record must still mean something when the ledger has moved on. |
| `test_place` | the node ids from the row's `tests` column. |
| `files_which_cover` | the paths this stage actually touched: test files for `sysdv`, source files for `build`. |
| `stage` | `sysdv`, `freeze`, `build`, or `gate`. |
| `base` / `pin` | the commit the stage ran at, and the pin once one exists. |
| `detail` | for a refusal, the reason; for a red, the red's own line. |

Statuses, in the only order they are legal for one row:

| status | written by | means |
| --- | --- | --- |
| `red_recorded` | `sysdv` | the lane wrote tests and the suite was red at the pre-implementation commit |
| `frozen` | `freeze` | the tests are in the pin; the surface cannot move |
| `built_green` | `build` | the row's own tests are green at the pin, in its worktree |
| `gate_green` | `build` | the composed tree — every lane merged — is green at the pin |
| `refused` | any | a wall stopped the stage; the reason is in `detail`. Durable, not a log line |
| `failed` | any | the stage ran but did not succeed (still red, no result) |

The latest line per `id` is its current state; every earlier line is the audit trail.
Read it with `./gate/wave.sh records <file> [id]`.

**The trail is not the verdict.** `proved` / `conditional` / `structural` / `declared`
stays a judgement in the ledger. The trail is what that judgement cites — including the
refusals, which are the difference between "not done yet" and "never asked".

## Non-claims

Keep them in the document. A ledger that lists what it does **not** establish is worth
more than one that only lists successes:

```markdown
## Not established
- Torque re-enable after recovery is the child's behaviour, not Cake's: the admin
  protocol carries no torque concept. (R7, structural)
- The 48 s envelope was measured on the dev host only; the board has a different
  scheduler. (R1, conditional on host)
```
