# pi-subagent

The `subagent` tool for pi, as its own package: dispatch a named agent in a separate `pi`
process, in single, parallel or chain mode.

It is vendored from pi's `examples/extensions/subagent/` (MIT, © earendil-works), which pi
ships as an *example* rather than a built-in — so without something like this, nothing can
dispatch an agent at all. Four local changes are marked `LOCAL:` in the source; upstream
behaviour (modes, streaming, rendering) is untouched so a future upstream diff stays
readable.

| LOCAL | change |
|---|---|
| 1 | a third agent-discovery root — **this package's own `agents/`** — so `pi install` can ship agents |
| 2 | `agentSource` gains `package`, the label for agents found there |
| 3 | a **write-scope post-check**: after a child exits cleanly its worktree is inspected, and the run fails if anything outside the agent's declared `write_scope` moved |
| 4 | the child does not inherit the parent's extensions (`-ne`), so a mode guard loaded here cannot strip the tools the agent declares |

## Why the package agents root

pi reads agent definitions from `~/.pi/agent/agents` and the nearest `.pi/agents` — both
outside a package. So a package that needs an agent ships it here and relies on LOCAL 1 to
discover it. A consumer that keeps its agents somewhere else points
`PI_SUBAGENT_PACKAGE_AGENTS` at that directory instead.

Precedence, lowest first: **package → user (`~/.pi/agent/agents`) → project
(`<nearest>/.pi/agents`)**. Anything a user writes wins by name.

## `write_scope`

```yaml
---
name: test-author
description: writes tests from a spec, never from an implementation
tools: read, grep, find, ls, bash, write, edit
write_scope: tests, conftest.py
---
```

A tool allowlist is not a sandbox: an agent with `bash` can write anywhere. So after a
child exits 0, the run's worktree is compared against the snapshot taken before it started
and any new path outside `write_scope` **fails the run**, naming the paths. Nothing is
reverted — the message tells you to discard the run deliberately rather than cherry-pick
around it. Derived artifacts (bytecode caches, `.pytest_cache`, `node_modules`, `target/`,
egg-info, …) are filtered: a run that executes the suite legitimately produces them.

With no `write_scope` declared the check is inert, by design — an agent that declares
nothing is not silently held to something.

## Use

```sh
pi install git:github.com/<owner>/pi-subagent    # or npm:pi-subagent once published
pi -e .                                          # try it for one session only
```

```js
subagent({
  agentScope: "user",
  tasks: [
    { agent: "review-correctness", cwd: "/tmp/repo.correctness.wt", task: "…" },
    { agent: "review-quality",     cwd: "/tmp/repo.quality.wt",     task: "…" },
  ],
})
```

`cwd` is per task. The child runs `pi --mode json -p --no-session -ne --model … --tools …
--append-system-prompt <agent body> "Task: <task>"`, with its stdout parsed as JSON-lines
for usage, model and stop reason. The parent receives the final text, exit code, stderr and
per-run usage.

## Verification

```sh
./check.sh              # tsc (if available) + the selftest
./check.sh --no-types   # selftest only
```

`selftest.mjs` covers only what this package changed relative to upstream: the package
agents root (with a fixture agent, so it depends on no other project), the `write_scope`
frontmatter, porcelain parsing, and the scope check end to end in a throwaway git tree.
Upstream spawning, streaming and rendering are pi's own to test.

`prepare-types.sh` links the installed pi release's `node_modules` into this checkout so
`tsc` and `node selftest.mjs` can resolve `@earendil-works/*`. Nothing at runtime needs it:
pi loads the `.ts` itself.

## Licence

MIT. `index.ts` and `agents.ts` are derived from pi's example extension (MIT, ©
earendil-works); see `UPSTREAM-README.md`. The `LOCAL:` changes are this package's.
