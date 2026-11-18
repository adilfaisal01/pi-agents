# Provenance

This repository was created on 2026-11-13 by merging four existing repositories with
`git subtree add`, so each directory keeps its original commit history, authorship and
dates. No source file was modified by the merge.

| Prefix | Source | Imported commit |
| --- | --- | --- |
| `v-model-agents/` | `git@github.com:adilfaisal01/v-model-agents.git` | `243e0ae4d7533c9cd5193a9f81fe97f641b388f1` |
| `code-review-swarm/` | `git@github.com:adilfaisal01/code-review-swarm.git` | `92f2068ca6616a81486e74b4ba4a6309b25b146e` |
| `pi-subagent/` | `git@github.com:adilfaisal01/pi-subagent.git` | `0be758400ef0c4513fc70b964c0336ebed84f132` |
| `review-lanes/` | `git@github.com:adilfaisal01/review-lanes.git` | `a18432603c6b2df644b7ffbed50fa98a43b9ab41` |

`review-gate/` was written in this workspace rather than imported, so its history is the
workspace's own. The original repositories remain in place untouched; this repository is
the workspace going forward.

## Third-party notes

`pi-subagent/` is a fork/divergence of an upstream Pi extension example. Its upstream
README is kept in-tree as `pi-subagent/UPSTREAM-README.md`; licence terms are in the
original files. Everything else here is original work by Adil Faisal unless a file says
otherwise.

## History commands

Each import is a merge commit whose second parent is the source repository's tip, so
original history is reachable by SHA. Note that a path-scoped `git log -- <prefix>/`
shows only the join commit and `git log --follow` does not cross a subtree merge: the
imported commits contain the files at their original root paths, not under the prefix.

```bash
# The four imported tips, by the SHAs in the table above
git log --oneline 243e0ae    # v-model-agents
git log --oneline 92f2068    # code-review-swarm
git log --oneline 0be7584    # pi-subagent
git log --oneline a184326    # review-lanes

# Same thing structurally: second parent of each join commit = imported tip
git log --oneline a156b25^2  # v-model-agents
git log --oneline 033756d^2  # code-review-swarm
git log --oneline c1ff905^2  # pi-subagent
git log --oneline 1db67d5^2  # review-lanes

# Whole workspace, newest first
git log --oneline
```
