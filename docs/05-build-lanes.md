# 05 — Build lanes

A build lane is one row's implementation against a frozen suite.

## Write scope

```
writes  = row source paths  −  lock surface
```

The lock surface from `docs/04` is absolute: `tests/**`, any `conftest.py`, the pytest
configuration, `gate/run-tests.sh`. A build lane that writes there is refused, not
warned.

Additional refusals worth making explicit, because each one is a cheaper route to green
than writing correct code:

| attempt | why it must be refused |
| --- | --- |
| new `conftest.py` anywhere | fixtures can override the suite's reality |
| `pytest.ini` / `pyproject.toml` edit | the selector decides what runs |
| a new pytest plugin or autouse fixture | the same, with more steps |
| documented command gaining `-k`, `-x`, `--deselect` | changes what "green" means |
| `skip`/`xfail` added to a frozen test | green by declaration |
| editing a golden/fixture file under `tests/` | the assertion, relocated |

## Working rules

1. **Red first, then green.** Start from the lane's recorded red output. A lane that
   begins with a green suite has nothing to do.
2. **Green per lane is not done.** Done is the composed gate (`docs/02`).
3. **Shared generated paths serialize.** Two lanes whose changes reach
   `graph_data.zig`, `codegen/emosqp/`, `.zig-cache/`, or `build/` are one lane, or they
   race. Disjoint *source* paths is not sufficient.
4. **Stop instead of contorting.** If the frozen test is wrong, stop and say which row,
   which assertion, and what the spec should say. Implementing against a wrong test is
   the one outcome that must never look like success.
5. **Report the diff, not the story.** Exit artifact: the row's tests green locally, the
   lock check clean, the files changed, and anything the lane could not satisfy.

## Exit checks

```bash
./gate/lock-check.sh "$PIN"     # exit 0 required
./gate/run-tests.sh             # green on the composed tree, not just the lane
```

Then, and only then, the composed gate runs once for all lanes together.

## Why the lock is not hostile

The lock is not there because the builder is untrusted. It is there because "make the
test pass" and "make the behaviour right" are indistinguishable from inside the lane,
and the cheapest edit that resolves the difference is the test. The lock removes that
option so the only remaining route is the implementation — which is the work.
