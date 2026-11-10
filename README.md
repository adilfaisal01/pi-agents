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

`pi/` is the apparatus that runs (a pi mode guard, packaged as a [pi
package](https://pi.dev/docs/packages)); `docs/` is why it is shaped that way;
`gate/` is the lock.

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
| `pi/` | the apparatus that runs: `extensions/agent-modes/` (modes, write scopes, shell policy, drift audit) and `agents/sysdv.md` |
| `install.sh` | symlink the apparatus into `~/.pi/agent` (local development only) |
| `package.json` | the pi manifest that makes `pi install` work |
| `check.sh` | gate self-test + extension typecheck + extension selftest |
| `examples/ledger-example.md` | a filled ledger for a control/compiler change |
| `DECISIONS.md` | what is decided, and the questions still open |

## Quick start

Anyone with pi installed can load the apparatus directly — no clone, no symlink:

```bash
pi install git:github.com/<owner>/v-model-agents   # or npm:pi-v-model-agents once published
pi -e .                                            # try it for one session only

# configure your own models and write scopes without editing the package
$EDITOR ~/.pi/agent/agent-modes.json               # or <repo>/.pi/agent-modes.json
```

The package ships no model ids on purpose — a package cannot know which providers you
have. `pi/README.md` documents the override layers and every config key.

Working on this repository itself:

```bash
./install.sh --dry-run      # what install.sh would link into ~/.pi/agent (dev path)
./check.sh                  # gate self-test + tsc + extension selftest (all verifiable)

# verify the gate script itself, standalone
./gate/test-lock-check.sh

# after freezing a suite at commit <sha>
./gate/lock-check.sh <sha>          # exit 0 clean, 1 drift, 2 usage
```

## Status

Docs plus the apparatus: the mode guard (`pi/extensions/agent-modes/`) enforces write
scopes, shell policy, per-mode models and the tracked-tree audit, and is covered by
`selftest.mjs`. The gate (`gate/`) is tested by its own self-test. Still open: the lane
orchestration itself (a prompt contract for `plan`, not code), delivery of the `sysdv`
subagent (pi ships no built-in subagent tool, and a pi package cannot install agent
definitions — see `DECISIONS.md`), and the hardware queue (`DECISIONS.md`#5).
