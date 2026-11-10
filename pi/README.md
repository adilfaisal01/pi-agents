# The pi apparatus

What actually runs, as opposed to what `docs/` describes.

```
pi/
├── extensions/agent-modes/     the mode switcher: tool sets, shell policy, write scopes,
│   ├── index.ts                model per mode, prompt contract, tracked-tree audit
│   ├── config.json             the shipped profile (order, keybinding, scopes)
│   ├── prompts/                one system-prompt contract per mode
│   ├── tsconfig.json           typecheck only; pi loads the .ts itself
│   ├── prepare-types.sh        links the pi release's types into pi/node_modules
│   └── selftest.mjs            assertions against the real extension, no pi needed
├── extensions/subagent/        the `subagent` tool (vendored from pi, adapted)
│   ├── index.ts                spawns a child pi per agent; write-scope post-check
│   ├── agents.ts               agent discovery + this package's own agents dir
│   ├── UPSTREAM-README.md      provenance: what was vendored and from where
│   └── selftest.mjs            assertions for the LOCAL changes only
└── agents/sysdv.md             the test-author agent, shipped and discovered
```

## Install

This repository is a [pi package](https://pi.dev/docs/packages). Anyone with pi installed
can load it with no clone, no symlinks, and no edit to their pi install:

```bash
pi install git:github.com/<owner>/v-model-agents     # or: pi install npm:pi-v-model-agents
pi -e .                                              # try it for one session, no settings change
```

`package.json` declares both extensions under the `pi` manifest, so pi's package manager
finds them on its own. `pi update --extensions` moves a git install to the latest ref.

`./install.sh` still exists for local development against this checkout (it symlinks the
profile into `~/.pi/agent`, so `git pull` updates it in place and `/reload` picks it up).
It is not the distribution path — do not point a stranger at it.

## Overrides

The package ships a profile that has to be true everywhere, so it carries no model ids
and no provider: a package cannot know which providers you have. Configure your own
without editing inside the package — `pi update` overwrites it.

| precedence | file | scope |
| --- | --- | --- |
| 1 (lowest) | `pi/extensions/agent-modes/config.json` | the shipped profile |
| 2 | `~/.pi/agent/agent-modes.json` | you, every project |
| 3 | `<repo>/.pi/agent-modes.json` | this project, committable |
| 4 (highest) | `$PI_AGENT_MODES_CONFIG` | explicit; CI and the selftest |

Each file is merged **per mode and per key**, so one line gives a mode a model without
restating its tools, scopes, or prompt:

```json
{ "provider": "anthropic", "modes": { "plan": { "model": "claude-sonnet-4-5" }, "build": { "model": "claude-sonnet-4-5" } } }
```

A model id may also carry its provider (`"model": "anthropic/claude-sonnet-4-5"`). If the
id is not available in your install, the switch is kept and a warning says where to set
it — the session does not lose its mode.

## What each layer enforces

| layer | mechanism | cannot be bypassed by |
| --- | --- | --- |
| tool presence | `dropTools` / `tools` → `setActiveTools` | a model can't call a tool absent from its schema |
| write scope | `writeScope` / `writeDeny` on `write`/`edit` `input.path` | prompt injection naming a path |
| shell policy | `bash: none\|safe\|all` + read-only allowlist | "just run the tests" in a read-only mode |
| model per mode | `model` in the mode, applied on switch | forgetting to switch models too |
| prompt contract | `prompts/<mode>.md` appended to the system prompt | (advisory; keep it aligned with the rest) |
| drift audit | tree snapshot around allowed `bash`, appended to the result | a command that quietly rewrites tracked files |
| test lock | `gate/lock-check.sh` against a freeze sha | editing a test to go green |

## config.json

Modes are capability profiles. Keys per mode:

| key | meaning |
| --- | --- |
| `model` | model id applied when entering the mode |
| `tools` | tools the mode guarantees |
| `dropTools` | removed even when `keepExtensions` kept them (e.g. `edit`, `write`) |
| `writeScope` | repo-relative path prefixes it may write; `[]` = none, omitted = any |
| `writeDeny` | prefixes it may never write, even inside `writeScope` |
| `bash` | `none`, `safe` (read-only + execute-class allowlist), `all` |
| `keepExtensions` | keep whatever tools were already active (extension tools included) |
| `promptFile` | system-prompt contract appended for the mode |

Top level: `provider` (optional), `default` (mode for a fresh session), `order` (cycle
order), `cycleKey`.

**`writeScope`/`writeDeny` in the shipped `config.json` are a starting point, not a law.**
They assume a Python-ish repository (`tests/`, `conftest.py`, `pyproject.toml`). Set them
for the repository you are working in — from `<repo>/.pi/agent-modes.json`, which you can
commit.

## The subagent tool (vendored, and why)

`sysdv` has to run in a **separate process** — it must not see the conversation that will
write the implementation — so it needs a tool that spawns one. pi has no built-in one:
the built-in extensions are only `mcp`, `llama.cpp`, `codemode`, and `tool-search`, and
pi ships `subagent` as an **example**. A pi package can install extensions, skills,
prompt templates, and themes — **not** agent definitions — so pointing users at
`~/.pi/agent/agents/sysdv.md` was the only option and it made `pi install` insufficient.

`pi/extensions/subagent/` is pi's example (MIT, `earendil-works`), vendored so the
package is self-contained. Two changes, both marked `LOCAL:` in the source:

| change | why |
| --- | --- |
| a third agent root: this package's own `pi/agents/` | `pi install` alone produces a usable `sysdv`; a user-authored agent of the same name still wins, then the project's |
| `write_scope` frontmatter + a post-check | after a child exits cleanly its worktree is read with `git status`, and the lane **fails** with the offending paths if anything outside the scope moved |
| the child runs with `-ne` | otherwise the child inherits the parent's extensions — including **this** mode guard, which starts it in `oracle` and strips `write`/`edit`. That happened on a real run: sysdv could not write the test it was asked for |

That second one is `docs/01`'s "post-check" layer turned into code instead of a rule in a
README. It is deliberately after the fact: the child owns its own tool list, so the only
truthful check is what the tree looks like when it stops. Two details come from runs that
failed without them: the tree is snapshotted **before** the spawn (so a pre-dirty worktree
is not blamed on the child), and caches are filtered (`__pycache__`, `.pytest_cache`,
`node_modules`, `.venv`, …) because a legitimate lane has to *run* the suite and running it
writes bytecode.

Two cautions:

- **Run one subagent extension, not two.** pi replaces a same-named tool without a
  warning, so installing this alongside another `subagent` package makes the winner
  arbitrary.
- **Upstream will drift.** The vendored copy is 1.5.1's example; re-diff against
  `examples/extensions/subagent/` when you upgrade pi, and keep the `LOCAL:` markers
  greppable.
- **The child inherits no extensions** (`-ne`). That is what keeps the contract
  deterministic, and it also means a child gets no MCP servers, skills, or prompt
  templates. If a lane needs one, pass it through the agent file's `tools` rather than
  re-enabling discovery.

## Verify

```bash
cd pi/extensions/agent-modes && node selftest.mjs   # 37 assertions, no pi required
cd pi/extensions/subagent   && node selftest.mjs    # 25 assertions on the LOCAL changes
./check.sh                                          # both, plus tsc and the gate self-test
```

The subagent selftest is narrow on purpose: it tests the package-relative agent
discovery, the `write_scope` parsing, and the post-check against a real throwaway git
tree. Process spawning and streaming are upstream's and are pi's own test surface.

`selftest.mjs` imports `index.ts` directly (Node ≥ 23 strips types) and drives
`session_start` / `tool_call` / `tool_result` with a fake API and a throwaway git repo.
It asserts the refusals by message, the allowed/refused command lists, and the drift
audit end to end.

## Limits, stated

- **Path scoping covers `write`/`edit` tool calls, not shell redirection.** In a `safe`
  shell the redirect is refused anyway; in `all` it is not. A mode that must be
  structurally unable to write needs `bash: "safe"` or `"none"`.
- **The audit is report-only.** It names the tracked files a command changed and raises a
  toast; nothing is reverted.
- **`keepExtensions: true` includes every extension tool**, including ones that write
  (a skill manager, an MCP filesystem server). Set `keepExtensions: false` if that
  matters more than context.
