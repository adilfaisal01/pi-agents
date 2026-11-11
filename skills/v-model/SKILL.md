---
name: v-model
description: Run a change as a V-model wave instead of one agent editing code — sysdv lanes write the tests first in worktrees at the pre-implementation commit, a barrier freezes them by commit sha, build lanes implement against the frozen suite, one composed gate decides. Use when asked to run a v-model / wave / lane / freeze / pin / barrier for a ledger row, to write tests before the implementation exists, or to re-derive a claim from a frozen suite.
disable-model-invocation: true
---

# V-model waves

You are running a change where the tests are authored before the implementation exists,
frozen by commit sha, and then satisfied — by agents that cannot touch what they must
satisfy. You are the operator of that machinery, **not** a participant in it.

All paths below are relative to **the repository you are working in**, not to this skill's
directory. The machinery is two things in that repo:

| path | what it is |
| --- | --- |
| `gate/wave.sh` | both waves, the barrier, and the record trail |
| `gate/lock-check.sh` | refuses a tree whose frozen surface moved since the pin |
| `gate/run-tests.sh` | the canonical test command — this is what "green" means |
| `agents/sysdv.md`, `agents/build.md` | the lane system prompts `wave.sh` reads |
| `ledger.md` | the rows: requirement, design, interface, sources, tests, level, verdict |
| `docs/01`–`docs/07` | why it is shaped this way — read `docs/06` before touching a verdict |

If `gate/` or `agents/` is missing, stop and say so: they are dropped into a target repo
together and committed, because the pin has to contain them.

## The one rule for you

**You do not edit source code in this repo while running a wave.** The lanes edit; you
spawn, read the refusals, and report. If you find yourself wanting to "just fix" a
failing assertion, that is a build lane's job — or a spec amendment (below), which is the
human's call, not yours.

Nothing enforces that on your session. `gate/` enforces it inside the lanes, where it
matters; the parent is disciplined by this file. If you want the wall on yourself, run
the session as `pi --tools read,grep,find,ls,bash`.

## Procedure

1. **Read the rows before running anything.**

   ```bash
   ./gate/wave.sh levels ledger.md     # which levels exist, bottom-up
   ./gate/wave.sh rows ledger.md       # id <TAB> level <TAB> tests
   ```

   Waves run bottom-up: `L3` unit before `L2` before `L1` before `L0`. Show the human the
   rows for the level you are about to run and their `sources` column — that column is
   the build lane's entire write scope, so it is the thing they are actually approving.

2. **Wave 1 — one test author per row, at the pre-implementation commit.**

   ```bash
   ./gate/wave.sh sysdv --ledger ledger.md --level L3 --base <sha> --confirm --width 3 \
       --model <test-author model>
   ```

   `<sha>` is the commit *before* the implementation exists. Each row gets its own
   worktree there and its own `pi` process with `agents/sysdv.md` as its contract. The
   lane is refused unless: nothing outside `tests/**` + test config changed, at least one
   test was created, and the suite is **red** at `<sha>`.

3. **The barrier — compose, require the whole suite red, freeze.**

   ```bash
   PIN=$(./gate/wave.sh freeze --ledger ledger.md --level L3 --base <sha> \
       --root <wave-root> | tail -1)
   ```

   This refuses two lanes claiming one path, refuses a vacuous test passing beside a red
   one, commits the lock surface, anchors the pin at
   `refs/vmodel/pins/<level>-<pin12>`, and prints the sha as its last line. The pin is the
   frozen spec; nothing after this point edits it.

4. **Wave 2 — one build lane per row at the pin, then the composed gate, once.**

   ```bash
   ./gate/wave.sh build --ledger ledger.md --level L3 --pin "$PIN" --confirm --width 3 \
       --model <build model>
   ```

   Lanes start at the pin, where other rows' tests are still red; each lane checks only
   its own rows (`run-tests.sh -k`), and the composed gate runs everything with no
   selection afterwards, serially. **Green per lane is not green composed** — only the
   composed run supports the claim.

5. **Report, per row, from the trail** (append-only, latest line per row wins):

   ```bash
   ./gate/wave.sh records records.jsonl          # every row
   ./gate/wave.sh records records.jsonl R1       # one row
   ```

   Statuses: `red_recorded` → `frozen` → `built_green` → `gate_green`, or `refused` with
   its reason. Report the rows, the pin, which stage each row reached, and the composed
   gate's exit. Say which stage the change stopped at; do not summarise a partial run as
   a delivery.

## What the refusals mean (and what you must not do about them)

| refusal | it means | what you do |
| --- | --- | --- |
| `wrote outside scope` | the lane edited something the row did not scope | discard the lane whole. Do not cherry-pick around it, do not narrow the diff by hand |
| `no test was created` | the lane produced no lockable surface | re-run the lane; a report is not a test |
| `the suite is GREEN at <sha>` | vacuous lane, or the behaviour already exists | find out which; it is a row problem, not a lane problem |
| `composed tree is not the union of the lanes' scoped paths` | two lanes touched one path | re-partition the rows (docs/02 rule 2); do not merge by hand |
| `the frozen surface moved` | a build lane edited a frozen test | discard the lane. A test changes only by amendment |
| `the lane's tests are still red at the pin` | the implementation does not satisfy its own row | the lane reports which assertion and what the spec should say; a wrong frozen test is an **amendment**, never a build edit |

An amendment is a commit **by the human**, stating that the spec changed, with the pin
re-anchored (`docs/04`). You may propose it. You may not make it.

## Do not

- Pass `--confirm` on the human's behalf. It is the acknowledgment that someone read the
  rows, and it is the only thing standing between a wave and a partition nobody checked.
- Pass `--child` in a real run. It is the stub runner the self-tests use to prove the
  orchestration with no model, and it makes a lane "succeed" without doing anything.
- Edit `gate/run-tests.sh`, `tests/**`, or any `conftest.py` — that is the lock surface.
- Raise a verdict past its evidence. `proved` needs a mechanical check that would fail if
  the claim were false; semantic equivalence, cross-host timing, and absence-of-failure
  rows stay `structural` or `declared` (`docs/06`, `docs/07`).
- Present this as independent verification or as a correctness proof. Tests written
  without sight of the implementation are independent *artifacts*; the models need not be
  independent of each other. The README says so; repeat it rather than inflating it.

## Stopping is a valid outcome

A lane that stops and says "this requirement is unmeasurable" or "this frozen test asks
for the wrong thing" is a **successful** lane, not a failed one — the contract in
`docs/05` rule 4 exists precisely so that failure cannot be dressed up as an
implementation. The same holds for you: if the ledger's `sources` is empty, a row names
no tests and no verdict, or the pin cannot be anchored, report it and stop. A wave that
halts with a reason is worth more than one that produces a green nobody can trace.
