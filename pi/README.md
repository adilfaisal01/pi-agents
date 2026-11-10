# The pi apparatus

What actually runs, as opposed to what `docs/` describes.

```
pi/
├── extensions/agent-modes/     the mode switcher: tool sets, shell policy, write scopes,
│   ├── index.ts                model per mode, prompt contract, tracked-tree audit
│   ├── config.json             the shipped profile (order, keybinding, scopes)
│   ├── prompts/                one system-prompt contract per mode
│   ├── tsconfig.json           typecheck only; pi loads the .ts itself
│   ├── prepare-types.sh        links the pi release's types into ./node_modules
│   └── selftest.mjs            assertions against the real extension, no pi needed
└── agents/sysdv.md             subagent definition (needs a subagent tool — see below)
```

## Install

This repository is a [pi package](https://pi.dev/docs/packages). Anyone with pi installed
can load it with no clone, no symlinks, and no edit to their pi install:

```bash
pi install git:github.com/<owner>/v-model-agents     # or: pi install npm:pi-v-model-agents
pi -e .                                              # try it for one session, no settings change
```

`package.json` declares the extension under the `pi` manifest, so pi's package manager
finds `pi/extensions/agent-modes/index.ts` on its own. `pi update --extensions` moves a
git install to the latest ref.

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

## Verify

```bash
cd pi/extensions/agent-modes && node selftest.mjs   # 37 assertions, no pi required
./check.sh                                          # + tsc + gate self-test
```

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
