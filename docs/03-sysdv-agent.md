# 03 — The sysDV subagent

`sysdv` writes the tests that the build must satisfy. It runs as a **subagent**: a
separate agent process with its own context and its own model, so it cannot inherit the
implementation intent from the conversation that will produce the build.

## Input contract

Hand it exactly three things. Nothing else:

1. The row(s): requirement, design note, interface description — from the ledger.
2. The interface snapshot: header/manifest/port list as it exists at the
   pre-implementation commit.
3. The worktree path where it will work.

**Not** the plan transcript, **not** the diff, **not** "here is roughly how I would do
it". Any of those re-couples the test author to the implementation.

## Runtime contract

| | |
| --- | --- |
| cwd | its own `git worktree add` at the **pre-implementation commit** |
| writes | `tests/**` and test configuration only |
| shell | read + execute, because it must run the suite |
| model | a model **different from the build's** |

The worktree is the load-bearing part. At a commit where the implementation does not
exist, "tests derived from the spec" is a property of the tree rather than a promise.
The model choice adds blind-spot diversity; it is not independence.

Suggested model roles (adjust to what the provider actually serves):

| role | model family | why |
| --- | --- | --- |
| plan | planner-family | decomposition, interface reasoning |
| sysDV | a family **not** used by build | decorrelates failure modes |
| build | builder-family | implementation throughput |

The shipped `sysdv.md` deliberately carries **no** `model:` line. A package cannot know
which providers you have, and a hardcoded default would silently break the rule above by
inheriting the parent's model. Set it where the agent file lives, or in a copy under
`~/.pi/agent/agents/sysdv.md` (which wins over the shipped one).

## Output contract

Not prose. A record the gate can read:

```markdown
| test | row | command | first result | why red is right |
| --- | --- | --- | --- | --- |
| test_tracking_cte_bounds | R1 | gate/run-tests.sh -k tracking | 1 failed, 4 passed | NameError: no implementation at C0 |
```

Plus the files themselves. The parent's post-check:

```bash
git -C <worktree> diff --name-only        # must be ⊆ tests/** + test config
git -C <worktree> status --porcelain      # untracked test files must be listed explicitly
```

Anything outside the scope: discard the whole lane run, do not cherry-pick around it.

**The post-check is code, not discipline.** `pi/extensions/subagent/` reads that
`git status` itself when the child exits, compares it against the `write_scope` in the
agent's frontmatter, and fails the lane with the offending paths. A lane that wrote
source cannot report success. Derived artifacts are filtered (a lane must run the suite,
and running it writes caches) and the tree is snapshotted before the child starts, so a
worktree that was already dirty is not blamed on it. What it still cannot see: a child
handed the wrong `cwd`, or a write **outside** the worktree — `sysdv` has an unrestricted
shell, so `pip install` into user site-packages is possible and is not caught here.

## Rejection rules (apply per lane, before the barrier)

| condition | verdict |
| --- | --- |
| test **passes** at the pre-implementation commit | **reject** — vacuous, or it tests something else |
| test cannot even be collected without the implementation | **reject** — an import-time dependency on the thing under test makes the test unable to be red for a stated reason |
| writes outside `tests/**` | **reject the run** |
| no recorded red output | **reject** — a test that was never red has unknown strength |
| test asserts an implementation detail (private symbol, internal call order) | **reject** — it will fight every legitimate refactor |
| tolerance not stated (`"tracks the trajectory"`) | **reject** — freeze an unmeasurable claim and the build can never satisfy it honestly |

## Anti-patterns

- **Writing tests after the code.** The single most reliable way to get a suite that
  encodes the bug. The worktree exists to make this impossible, not discouraged.
- **Same model for sysDV and build.** Correlated blind spots; the suite and the
  implementation will agree on the same wrong assumption.
- **Letting sysDV run the build.** It may run tests that fail; it may not make them pass.
- **Accepting a chat summary as the record.** Prose is not checkable at the barrier.
