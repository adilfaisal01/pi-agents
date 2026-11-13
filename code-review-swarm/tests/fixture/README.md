# Self-test fixture

`buggy.py` is intentionally defective. It is not imported by anything; the
self-test points both review lanes at it and asserts only that the contract is
honoured (a `| ID | SEV | …` table, at least one finding, a `COVERAGE:` line).

The list below is ground truth for a human reading a lane's output. It is **not**
asserted: models are not deterministic, and an assertion that "the model must
find B5" would just be a flake generator.

| ID | SEV | Location | Defect | Trigger |
|----|-----|----------|--------|---------|
| B1 | SEV1 | `total` | `range(len(prices) - 1)` drops the last item | `total([10, 20])` returns `21.5`, not `32.25` |
| B2 | SEV3 | `total` | mutable default `discount=[]` shared across calls | second call subtracts the first call's subtotal |
| B3 | SEV2 | `total` | the discount is `discount[0]`, i.e. the first subtotal ever computed | any call after the first is off by the first subtotal |
| B4 | SEV2 | `load` | file handle never closed; leaks on a `json` error | repeated `load()` calls exhaust descriptors |
| B5 | SEV1 | `average` | divides by `len(data)` (number of keys) not `len(data["values"])`; `ZeroDivisionError` on `{}` | `average({"values": [1, 2]})` → `3.0` instead of `1.5` |
| B6 | SEV2 | `parse_int` | `ValueError` escapes to the caller uncaught; no bound or sign policy | `parse_int("abc")` raises instead of returning a documented error |
| B7 | SEV3 | `slice_top` | `n == 0` yields the whole list instead of an empty one (`[-0:]`) | `slice_top([3, 1, 2], 0)` returns all three |
| B8 | SEV2 | `main` | no validation of `argv`; `float()` raises on the first bad token, uncaught | `./buggy.py 1 x` prints a traceback |

The `report`/`main` pair also carries a quality-lane target: `total` is called
twice in `main`, once for its side effect on the mutable default and once for the
returned value, so `main`'s output depends on how many times it has been called
before.
