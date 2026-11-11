# review-lanes

Give one lane its own checkout of a commit, and prove the code it ran came from there.

A review lane, a repro lane, a build agent — any process that has to run code that is
*not* the main checkout needs three things: a tree at a specific commit, isolation so its
writes cannot reach the tree under review, and evidence that the code it executed was the
code it was asked about. `git worktree` gives the first two. The third is the whole point
of this tool, because it fails silently:

> A lane runs clean against the **main** tree, because a shared virtualenv, an editable
> install or a console script still pointed there. The finding it should have raised was
> never possible. Every artifact is green; the only wrong thing is a path.

Nothing downstream catches that. So the deliverable is not the worktree — it is the
assertion.

## Usage

```sh
# once per lane: create, provision an environment if needed, assert
eval "$(./bin/review-lanes provision /path/to/repo --name review)"
#   stderr:   ok    mypkg   /path/to/repo.review.wt/src/mypkg/__init__.py
#   stdout:   WORKTREE=...  PYTHONPATH=...  SHA=...

# every round: same worktree, new commit, environment untouched
./bin/review-lanes provision /path/to/repo --name review --base <sha>

# the refusal that matters -> exit 0 inside, exit 1 if it resolved anywhere else
./bin/review-lanes verify "$WORKTREE"

# dispose
./bin/review-lanes remove "$WORKTREE"
```

`--install` provisions a venv *beside* the worktree with an editable install (needs `uv`);
the default is `PYTHONPATH` and no environment of its own.

stdout is `KEY=value` lines only, so a caller can `eval` it. stderr is prose.

Exit codes: `0` provisioned/verified · `1` refused · `2` usage.

## Two rules

**Same depth.** The worktree is a sibling, `<parent>/<repo>.<name>.wt` — never
`<parent>/.wt/<name>`. One directory deeper and every relative path dep breaks: `path =
"../deps/x"` resolves into the wrong place, and a `path = "../../../sibling/crates/…"`
stops resolving at all. That failure surfaces at build time inside a lane, far from the
cause. The self-test asserts a `../` dep still resolves from inside the worktree, and
`provision` refuses a worktree where an `[tool.uv.sources]` or Cargo dependency `path`
does not exist.

**Never share the project.** Dependencies are path-independent and can be shared freely —
one venv, one `uv` cache, one `target/`. The project itself is path-keyed and must not be:
an `__editable__*.pth` and a console script both bake in the directory they were installed
from. Share dependencies; recreate or re-point the project.

Because an editable install is keyed by directory and not by commit, a worktree is
provisioned **once** and detached **many** times — `checkout --detach <sha>` does not
invalidate it.

## Why `find_spec` and not `import`

Resolving a package must not execute it. Real projects pull numpy, mujoco or a compiled
extension at import time, so an assertion that only holds when the whole dependency tree
is installed cannot guard the case that matters. `find_spec` stats the path and returns
`__init__.py` without running anything.

## Vocabulary, and what is not shared

The words are borrowed from the V-model discipline this came out of — *lane*, *pin*,
*base*, *refusal*, *provision once, detach many*. **Nothing load-bearing is.** No import,
no source dependency, no script from another project is named or called; the self-test
fails if the source even mentions one. This is a standalone tool that knows about git and
Python and nothing else about who is calling it.

## What it does not do

- It does not run tests. It gives a lane a tree and proves which tree.
- It does not decide whether a finding is real. (That is an attribution question — the
  same repro run at two commits — and it belongs on top of this, not inside it.)
- It does not clean up after a crashed lane. A dirty worktree is refused by the next
  `provision`; `remove --force` is how you discard it.
- It knows Python packages and Cargo/PEP-735-adjacent `path` deps. A repo with another
  notion of "the project" gets the worktree and skips the assertion, with a note.

## Verification

```sh
./check.sh                      # tests/selftest.sh — throwaway repo, no network, no model
LANES_TEST_INSTALL=1 ./check.sh # + the editable-install path (needs uv and a warm cache)
```
