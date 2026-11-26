# pi agent modes

Named modes with their own permissions: each one carries its own tool set, its own shell
policy, its own write scope, its own system-prompt contract, and optionally its own model.

| mode | writes | shell | remote | what it is for |
| --- | --- | --- | --- | --- |
| `oracle` | nothing in the repo | read-only + execute-class + `gh` reads | read | reading, audits, evidence — the default for a fresh session |
| `plan` | `docs/**` and `ledger.md` only | read-only + execute-class + `gh` reads | read | producing a written plan, not a conversation |
| `build` | source, never the test surface | unrestricted | read and write | implementing |
| `yolo` | anything | unrestricted | read and write | experiments; not a delivery mode |
| `forge` | anything but the machinery (`.claude`, `.codex`, `.agents`, `.pi`, `.github`, `.beads`, `.harness`, `harness`, `gate`) | unrestricted | read and write, push/PR only through `forge-gate finish` | autonomous task execution: claim, test-first, reviewed handoff — see [`forge-mode-plan.md`](../docs/forge-mode-plan.md) |

`mcp__github` is in every mode's tool set and `gh`'s read subcommands are on the safe shell
allowlist, so the remote is evidence rather than a separate trip to a browser. `oracle` and
`plan` declare it read-only (`mcpReadOnly`), which the tool-call guard enforces by operation
name — a PR's diff and a merge arrive through the same proxy tool.

`alt+a` cycles, `Ctrl+1..5` jump, `Ctrl+Shift+M` toggles oracle ↔ build. `/mode` opens a
menu, `--agent-mode <name>` starts a session already in one.

A mode is a plugin rather than a skill because permissions are the one thing advice cannot
carry: it removes a tool from the schema, refuses a path at `tool_call`, and gates bash
through an allowlist. Instructions can be ignored; an absent tool cannot be called.

```bash
pi install <this repo>     # the modes are what an install gives you
pi -e <this repo>          # try them for one session, no settings change
```

Everything about the modes — the override layers, every `config.json` key, the keybinding
map, and the limits of what a mode can enforce — is in **[`modes/README.md`](modes/README.md)**.
Verify them with no model and no session: `./modes/check.sh` (tsc + 119 assertions).

## Repo map

The modes are the package. The V-model is optional material in the same repo, not part of
the install.

| path | contents |
| --- | --- |
| `modes/` | the pi package: `index.ts` (the extension), `config.json` (the shipped profile), `prompts/` (one contract per mode), `selftest.mjs`, `check.sh` |
| `skills/v-model/` | **optional** — the V-model skill. Invoke-only; install it only if you want it |
| `gate/` | the V-model's lock: the two waves, the barrier, the pin, the record trail |
| `agents/` | the two lane contracts (`sysdv`, `build`) that `gate/wave.sh` reads |
| `docs/01`–`docs/07` | why the V-model is shaped that way |
| `check.sh` | modes + gate self-tests + the skill's frontmatter, all offline |
| `DECISIONS.md` | what is decided about the V-model, and what is still open |

---

## Optional: the V-model discipline

None of this is installed by `pi install`, and nothing in `modes/` depends on it. It is a
working discipline for changes in which the agent never becomes the author of record:
specs and tests are written **before** the implementation exists, the test surface is
frozen by commit sha, and verification is re-derived by a party that did not produce the
claim. Download it if you want that; a mode is still a mode without it.

Adopt it in one of two ways:

```bash
# 1. invoke the skill from this checkout, for one session
pi --skill <this repo>/skills/v-model

# 2. or make it permanent (any skills directory pi already reads)
ln -s "$PWD/skills/v-model" ~/.pi/agent/skills/v-model
#    then, in the repository you are changing:  /skill:v-model run wave 1 for ledger.md at <sha>
```

The skill is invoke-only (`disable-model-invocation: true`): the model does not reach for it
on its own. Running a change this way is a decision, not a hunch. `gate/` and `agents/` are
copied into the target repository together and committed there — the pin has to contain
them (`docs/04`).

The unit of work is a **row** in a requirement-to-evidence ledger. The unit of parallelism
is also the row. Two waves, one barrier:

```text
lane R1 ─ sysDV ─┐
lane R2 ─ sysDV ─┼─ compose tests/ → full-suite RED run → PIN (commit sha)
lane R3 ─ sysDV ─┘                │
                                  ├─ lane R1 ─ build ─┐
                                  ├─ lane R2 ─ build ─┼─ compose → composed gate (serial)
                                  └─ lane R3 ─ build ─┘
```

- **Wave 1 (parallel):** one `sysdv` lane per row, its own process in its own worktree at
  the pre-implementation commit. Each writes tests for its row and records the red run.
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

## Running a change end to end

Plan authors `ledger.md` (one row per claim, with `sources` as the row's write scope and
`level` for the wave ordering). Then the machinery, three commands:

```bash
# wave 1 — one test author per row, in its own worktree at the pre-implementation commit
./gate/wave.sh sysdv --ledger ledger.md --level L3 --base <sha> --confirm --width 3 \
    --model <test-author model>

# the barrier — compose, require the whole suite RED, commit, print the pin
PIN=$(./gate/wave.sh freeze --ledger ledger.md --level L3 --base <sha> --root <wave-root> | tail -1)

# wave 2 — one build lane per row at the pin, then the composed gate, once
./gate/wave.sh build --ledger ledger.md --level L3 --pin "$PIN" --confirm --width 3 \
    --model <build model>

# what happened, per row — the latest line per row; the earlier lines are the trail
./gate/wave.sh records records.jsonl R1        # default: <ledger dir>/records.jsonl
```

`sysdv` and `build` refuse to spawn lanes without `--confirm`; `freeze` prints the pin as
its last line; every stage appends a record and never rewrites one. `./check.sh` runs the
self-tests for all of it — no model, no network.

`--model` (or `PI_SYSDV_MODEL` / `PI_BUILD_MODEL`) is handed to the `pi` child that runs a
lane, so the test author and the build can be different model families. The package ships
no model ids: it cannot know which providers you have.

## Status of the V-model part

The **gate** is scripted and tested by its own self-tests, which drive a stub lane runner:
no model, no network. Every wall in it is a refusal with a nonzero exit — out-of-scope
write, no test created, green at the pre-implementation commit, a vacuous test beside a red
one, two lanes claiming one path, a composed tree that is not the union of the lanes, a
frozen surface that moved, a lane still red at the pin.

The **skill** is the front door and carries no enforcement. The **parent session** is not
enforced by this material; if you want a wall on your own session, use a mode — `plan` or
`oracle` — from `modes/`, or start the session with `pi --tools read,grep,find,ls,bash`.

What is still open: the `plan` side is a prompt contract, not code, so `ledger.md` is
written by an agent that the gate cannot check; and the hardware queue (`DECISIONS.md`#5)
for steps that need one board or one robot.
