# 05 — Build lanes

A build lane is one row's implementation against a frozen suite.

## Write scope

```
writes  = the row's `sources` column  −  the lock surface
```

`sources` is the plan → build contract (`docs/06`). Plan fills it, `wave.sh build` passes
it to the lane, and the lane is refused if anything outside it moved. An empty cell is
not "everything": it is a row nobody scoped, and such a row is not buildable until plan
says what it touches.

The lock surface from `docs/04` is absolute: `tests/**`, any `conftest.py`, the pytest
configuration, `gate/run-tests.sh`. A build lane that writes there is refused, not
warned. A row whose `sources` name the lock surface is refused before the lane starts.

Additional refusals worth making explicit, because each one is a cheaper route to green
than writing correct code:

| attempt | why it must be refused |
| --- | --- |
| new `conftest.py` anywhere | fixtures can override the suite's reality |
| `pytest.ini` / `pyproject.toml` edit | the selector decides what runs |
| a new pytest plugin or autouse fixture | the same, with more steps |
| documented command **in the repo** gaining `-k`, `-x`, `--deselect` | changes what "green" means for everyone |
| `skip`/`xfail` added to a frozen test | green by declaration |
| editing a golden/fixture file under `tests/` | the assertion, relocated |

The distinction on `-k`: the **apparatus** selects the row's tests in a lane
(`run-tests.sh -k "test_a or test_b"`, docs/05 above) because a lane cannot be green on
other rows' work. The **composed gate** runs the whole suite with no selection. What is
refused is a lane narrowing the documented command itself — the repo's `gate/run-tests.sh`
or its CI invocation — so that every future green means less than the last one.

## Working rules

1. **Red first, then green.** Start from the lane's recorded red output — `wave.sh build`
   passes the row's `red_recorded` record into the task file, so the lane begins from the
   failure it has to resolve, not from a summary of it. A lane that begins with a green
   suite has nothing to do.
2. **Green per lane is not done.** Done is the composed gate (`docs/02`).
3. **Shared generated paths serialize.** Two lanes whose changes reach
   a checked-in generated source, a codegen output directory, `.zig-cache/`, or `build/`
   are one lane, or they race. Disjoint *source* paths is not sufficient.
4. **Stop instead of contorting.** If the frozen test is wrong, stop and say which row,
   which assertion, and what the spec should say. Implementing against a wrong test is
   the one outcome that must never look like success.
5. **Report the diff, not the story.** Exit artifact: the row's tests green locally, the
   lock check clean, the files changed, and anything the lane could not satisfy.

## Exit checks

```bash
./gate/lock-check.sh "$PIN"     # exit 0 required
./gate/run-tests.sh -k "<the row's tests>"   # the row green, in the lane
```

Then, and only then, the composed gate runs once for all lanes together:

```bash
./gate/lock-check.sh "$PIN"     # on the composed tree
./gate/run-tests.sh             # no selection: every row, every test
```

Green per lane is not done (`docs/02`). The lane check is scoped to its row because every
lane starts at the pin, where the other rows' tests exist and are still red — a lane that
demanded the whole suite green would be demanding the work of every other lane.

`gate/wave.sh build` runs all of this for you: the lane in its own worktree at the pin,
the lock check, the scope check, and then the serial composed gate. It refuses a lane
that moved the frozen surface, wrote outside its row's `sources`, or did not turn its own
tests green.

## Why the lock is not hostile

The lock is not there because the builder is untrusted. It is there because "make the
test pass" and "make the behaviour right" are indistinguishable from inside the lane,
and the cheapest edit that resolves the difference is the test. The lock removes that
option so the only remaining route is the implementation — which is the work.
