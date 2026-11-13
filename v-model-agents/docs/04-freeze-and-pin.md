# 04 — Freeze and pin

The barrier between the two waves. It is mechanical: compose, run, reject, pin.

## Why the pin is a commit, not a file list

A list of test files is not the test suite. The **selector** decides what runs, and the
selector usually lives outside `tests/`:

```toml
# pyproject.toml
[tool.pytest.ini_options]
testpaths = ["tests"]
addopts  = "-m 'not integration and not mcp'"     # <- deselects two categories
```

A build lane that edits `addopts` goes green without changing a single assertion.
`tests/conftest.py` can redefine fixtures; the runner command can add `-k`. So the lock
surface is:

| locked path | why |
| --- | --- |
| `tests/**` | the assertions |
| `conftest.py` (any level) | fixtures can redefine reality |
| `pyproject.toml`, `pytest.ini`, `tox.ini`, `setup.cfg` | the selector |
| `gate/run-tests.sh` | the canonical command |

**The pin is the sha of the commit that contains all of them.** A sha covers files the
list forgets — including a new `conftest.py` in a subdirectory.

## Procedure

```bash
# 0. every lane's tests are back in the compose tree, at the pre-implementation commit C0
git log --oneline -1                      # == C0

# 1. the whole suite, once, as a whole
./gate/run-tests.sh || true               # every new test must fail, for its stated reason
./gate/run-tests.sh --collect-only -q     # zero collection errors, no duplicate node ids

# 2. reject lanes per docs/03 (vacuous green, out of scope, no red record, unstated tolerance)

# 3. freeze
git add tests conftest.py pyproject.toml gate/run-tests.sh
git commit -m "(test): freeze spec <id> — tests for R1..R3, red at C0"
PIN=$(git rev-parse HEAD)
```

The commit message states the rows. A test commit that does not name rows is not a
freeze, it is a pile of tests.

## The scripted barrier

Steps 0–3 are `wave.sh freeze`, and it refuses rather than warns at each of them:

```bash
./gate/wave.sh freeze --ledger ledger.md --level L3 --base <C0> --root <wave-root>
```

| wall | refusal |
| --- | --- |
| every lane at the level finished ok | `lane R2 did not finish ok: …` |
| no two lanes claim one path | `two lanes claim the same path` — the merge is a human decision, so it never reaches a merge |
| the composed tree is exactly the union of the scoped paths | `the composed tree is not the union of the lanes' scoped paths` |
| the composed suite is RED at C0 | `the composed suite is GREEN at <C0> — every new test must be red there` |
| the composed suite collects cleanly | `the composed suite does not collect cleanly` |

On success it commits the lock surface with a message naming the rows, appends a
`frozen` record per row (`docs/06`), and prints the pin sha as its **last line** so the
next stage can take it directly:

```bash
PIN=$(./gate/wave.sh freeze ... | tail -1)
```

## The gate

```bash
./gate/lock-check.sh "$PIN"
```

- exit `0` — the frozen surface is byte-identical to the pin
- exit `1` — drift; prints the offending paths and the diff
- exit `2` — usage error (bad pin, pin not an ancestor, no lock paths at the pin)

Run it in the build lanes' exit path and in the composed gate. A drift is a **refusal**,
never a warning: a warning is a green run with a footnote, which is the failure mode this
whole document exists to prevent.

## Landing the pin

The freeze commit is created on a **detached worktree** under the wave root, and the wave
root is a temp directory. Two consequences, both the human's:

1. **The pin is anchored by a ref.** `freeze` runs
   `git update-ref refs/vmodel/pins/<level>-<pin12> <pin>`, so cleaning `$TMPDIR` cannot
   leave the commit unreferenced and let a later `git gc` collect the frozen spec out of
   existence. The ref is also the name to land from.
2. **The tests reach `main` by a merge.** The apparatus does not commit anything to your
   branch — `docs/DECISIONS #2`: scripts certify, the human judges. Landing is:

```bash
git merge --no-ff "$(git rev-parse refs/vmodel/pins/L3-638fa694ef8a)" \
	-m "test: land the frozen L3 spec (pin 638fa69)"
```

Land the pin **before** amending the ledger, or `main` and the pin diverge and the merge
stops being a fast-forward. Nothing breaks when they diverge — the pin is still an
ancestor-or-sibling commit that `lock-check.sh` can verify — but a merge commit is noise
the human has to explain later.

The build half is the same shape and the same rule: `build` applies each lane's diff to
`<root>/compose` and runs the composed gate there, but it **never commits**. Committing
the implementation is the moment a human says "this is what satisfies the row", which is
exactly the judgement the apparatus is built to leave in place.

## Amendments

A locked test may change. It may not change *silently*, and it may not change inside a
build lane. The only legal path:

1. A commit authored by the human, whose message states **the spec changed** and why.
2. A new pin. The old pin stays in the ledger row's history.
3. The build lane rebases onto the new pin.

Without this path, "locked" means "frozen wrong", and the build lane's only honest move
is to stop. Say that in the build prompt: stopping is a valid outcome; implementing
against a wrong test is not.

Run against the amended pin, and anchor it the same way freeze does:

```bash
git update-ref refs/vmodel/pins/L2-amend-$(git rev-parse --short=12 HEAD) HEAD
./gate/wave.sh build --ledger ledger.md --level L2 --pin "$(git rev-parse HEAD)" --confirm
```

`build` only needs a commit that contains the frozen surface, so the amendment commit is
a valid pin. The old pin stays in the trail: its `frozen` record is still there, and the
`built_green` records name the new one — which is what lets a reviewer see that the spec
moved before the code existed.

One thing worth expecting: the build lane is **supposed** to stop here. A lane that
reports "these two assertions cannot both hold, here is the rule you did not state" is a
successful run, and its refusal is a record, not lost log output.

## What the pin does not cover

- **Behaviour outside the suite.** The pin freezes what the tests claim, not whether the
  claims are sufficient. Completeness is the ledger's job (`docs/06`).
- **Claims that no test can discharge** — semantic equivalence of a transformed program,
  timing envelopes measured on hardware, anything asserted about a different machine.
  Those rows cannot be `proved` by a green suite, whatever the pin says.
