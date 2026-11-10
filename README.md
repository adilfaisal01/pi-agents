# V-model for agents

A working discipline for agent-assisted changes in which the agent never becomes the
author of record. Specs and tests are written **before** the implementation exists, the
test surface is frozen by commit sha, and verification is re-derived by a party that did
not produce the claim.

The unit of work is a **row** in a requirement-to-evidence ledger. The unit of
parallelism is also the row. Two waves, one barrier:

```
lane R1 ─ sysDV ─┐
lane R2 ─ sysDV ─┼─ compose tests/ → full-suite RED run → PIN (commit sha)
lane R3 ─ sysDV ─┘                │
                                  ├─ lane R1 ─ build ─┐
                                  ├─ lane R2 ─ build ─┼─ compose → composed gate (serial)
                                  └─ lane R3 ─ build ─┘
```

- **Wave 1 (parallel):** one `sysdv` subagent per lane, in its own worktree at the
  pre-implementation commit. Each writes tests for its row and records the red run.
- **Barrier (serial):** compose the lanes' tests, run the whole suite at the same
  commit, reject vacuous tests, then freeze the surface with a commit sha.
- **Wave 2 (parallel):** build agents work each lane to green against the frozen suite.
  They cannot touch the frozen surface.
- **Composed gate (serial):** merge all lanes and run the gate once. Green per lane is
  not green composed.

## What this is not

- **Not independent verification.** Multiple agents on one model share priors. What is
  independent is the *artifact* (tests written with no sight of the implementation) and
  the *evidence source* (interpreter vs compiled output, gate vs board, fuzzing vs
  fixtures). Diversity of weights reduces correlated blind spots; it does not create
  ground truth.
- **Not a correctness proof.** "The locked suite is green" says the exercised sequences
  behave. It does not establish that a transformed program denotes the same function as
  the original. Rows that make such claims stay `structural` or `declared` (see
  `docs/06-ledger.md`).

## Repo map

| path | contents |
| --- | --- |
| `docs/01-modes-and-capabilities.md` | permission profiles per role: writes, path scope, shell |
| `docs/02-lanes-and-partition.md` | the row as unit of work; partition and serialization rules |
| `docs/03-sysdv-agent.md` | the test-author contract: model, tools, worktree, output record |
| `docs/04-freeze-and-pin.md` | compose-then-freeze; lock surface; the sha pin |
| `docs/05-build-lanes.md` | build write scope, refusals, shared generated paths |
| `docs/06-ledger.md` | row schema and verdict vocabulary |
| `docs/07-failure-modes.md` | the catalogue of ways this passes review wrongly |
| `gate/run-tests.sh` | canonical test command for a frozen suite (locked) |
| `gate/lock-check.sh` | refuses a tree whose frozen test surface moved since the pin |
| `gate/test-lock-check.sh` | self-test for `lock-check.sh` |
| `agents/sysdv.md` | drop-in subagent definition (`~/.pi/agent/agents/`) |
| `examples/ledger-example.md` | a filled ledger for a control/compiler change |
| `DECISIONS.md` | what is decided, and the questions still open |

## Quick start

```bash
# verify the gate script itself
./gate/test-lock-check.sh

# after freezing a suite at commit <sha>
./gate/lock-check.sh <sha>          # exit 0 clean, 1 drift, 2 usage
```

## Status

Design plus the one mechanical piece that can be tested today (`gate/`). The mode
permissions described in `docs/01` are the contract to implement; nothing here patches
an agent runtime.
